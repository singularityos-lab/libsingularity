namespace Singularity.Accounts {

    /**
     * Progress of a transfer.
     *
     * @param done  Bytes sent or received so far.
     * @param total Size of the whole transfer, or -1 when unknown.
     */
    public delegate void TransferProgress(int64 done, int64 total);

    /**
     * A request body read from a range of a local file. It is opened again
     * for every attempt, so a request can be sent again after a redirect or
     * a refreshed token without holding the data in memory.
     */
    public class UploadSource : Object {
        /** The file the body is read from. */
        public File file { get; construct; }
        /** First byte of the range. */
        public int64 offset { get; construct; }
        /** Number of bytes in the range. */
        public int64 length { get; construct; }

        public UploadSource(File file, int64 offset, int64 length) {
            Object(file: file, offset: offset, length: length);
        }

        /** Opens a stream over the range. */
        public InputStream open(Cancellable? cancellable = null) throws Error {
            var stream = file.read(cancellable);
            if (offset > 0) stream.seek(offset, SeekType.SET, cancellable);
            return new RangeInputStream(stream, length);
        }
    }

    private class RangeInputStream : InputStream {
        private InputStream source;
        private int64 remaining;

        public RangeInputStream(InputStream source, int64 length) {
            this.source = source;
            remaining = length;
        }

        public override ssize_t read(uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (remaining <= 0) return 0;
            size_t want = buffer.length;
            if ((int64) want > remaining) want = (size_t) remaining;
            ssize_t n = source.read(buffer[0:want], cancellable);
            if (n > 0) remaining -= n;
            return n;
        }

        public override bool close(Cancellable? cancellable = null) throws IOError {
            return source.close(cancellable);
        }
    }

    /**
     * The answer to an HttpClient request.
     */
    public class HttpResponse : Object {
        /** HTTP status code. */
        public uint status { get; construct; }
        /** Response body, possibly empty. */
        public Bytes body { get; construct; }
        /** Response headers. */
        public Soup.MessageHeaders headers { get; construct; }
        /** Final address after redirects. */
        public string url { get; construct; }

        public HttpResponse(uint status, Bytes body, Soup.MessageHeaders headers, string url) {
            Object(status: status, body: body, headers: headers, url: url);
        }

        /** True for 2xx statuses. */
        public bool ok {
            get { return status >= 200 && status < 300; }
        }

        /** Body as UTF-8 text. */
        public string text() {
            return bytes_to_string(body);
        }

        /** Converts bytes to a string, stopping at the first NUL byte. */
        public static string bytes_to_string(Bytes bytes) {
            if (bytes.get_size() == 0) return "";
            var sb = new StringBuilder.sized(bytes.get_size() + 1);
            sb.append_len((string) bytes.get_data(), (ssize_t) bytes.get_size());
            return sb.str;
        }

        /** Returns a response header, or null. */
        public string? header(string name) {
            return headers.get_one(name);
        }

        /** Parses the body as JSON and returns the root object. */
        public Json.Object json_object() throws Error {
            var parser = new Json.Parser();
            parser.load_from_data(text());
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) {
                throw new AccountsError.PROTOCOL(_("The server sent an unexpected answer"));
            }
            return root.get_object();
        }
    }

    /**
     * Sends HTTP requests on behalf of one capability of an account.
     *
     * It adds the account's credentials, retries once with a fresh token when
     * an OAuth server answers 401, follows redirects for every method (DAV
     * discovery needs PROPFIND to be redirected) and keeps credentials on the
     * original host only. A second rejection is reported to the accounts
     * service, which marks the account as needing attention.
     */
    public class HttpClient : Object {
        /** The account whose credentials are used. */
        public Account account { get; construct; }
        /** The capability the requests belong to. */
        public Capability capability { get; construct; }
        /** The underlying session, shared by every request of this client. */
        public Soup.Session session { get; private set; }

        public HttpClient(Account account, Capability capability) {
            Object(account: account, capability: capability);
            session = new Soup.Session();
            session.user_agent = "Singularity/1.0";
            session.timeout = 60;
            session.add_feature_by_type(typeof(Soup.AuthNTLM));
        }

        /**
         * Sends a request and returns the response whatever its status,
         * except for authentication failures, which throw.
         *
         * @param method       HTTP method.
         * @param url          Absolute address.
         * @param content_type Type of `body`, or null.
         * @param body         Request body, or null.
         * @param headers      Extra request headers, or null.
         * @param cancellable  Optional cancellable.
         */
        public async HttpResponse send(string method, string url, string? content_type = null, Bytes? body = null,
                                       HashTable<string, string>? headers = null, Cancellable? cancellable = null) throws Error {
            var creds = yield account.get_credentials(capability);
            var response = yield send_once(method, url, content_type, body, headers, creds, cancellable);
            if (response.status == 401 && creds.is_token) {
                creds = yield account.get_credentials(capability, true);
                response = yield send_once(method, url, content_type, body, headers, creds, cancellable);
            }
            if (response.status == 401) {
                yield account.report_problem(capability, "reauth");
                throw new AccountsError.NEEDS_REAUTH(_("%s rejected the saved credentials. Sign in again in Settings.").printf(account.display_name));
            }
            return response;
        }

        private bool accept_invalid_tls() {
            return account.get_endpoint("tls-accept-invalid") == "true";
        }

        private async HttpResponse send_once(string method, string url, string? content_type, Bytes? body,
                                            HashTable<string, string>? headers, AccountCredentials creds,
                                            Cancellable? cancellable) throws Error {
            string current = url;
            string current_method = method;
            string origin = origin_of(url);
            for (int hop = 0; hop < 6; hop++) {
                Soup.Message msg;
                try {
                    var parsed = Uri.parse(current, UriFlags.ENCODED);
                    if (parsed.get_path() == "") {
                        parsed = Uri.build(UriFlags.ENCODED, parsed.get_scheme(), parsed.get_userinfo(), parsed.get_host(), parsed.get_port(), "/", parsed.get_query(), parsed.get_fragment());
                    }
                    msg = new Soup.Message.from_uri(current_method, parsed);
                } catch (UriError e) {
                    throw new AccountsError.INVALID(_("The address %s is not valid").printf(current));
                }
                msg.add_flags(Soup.MessageFlags.NO_REDIRECT);
                if (origin_of(current) == origin) {
                    string? auth = creds.authorization_header();
                    if (auth != null) {
                        msg.request_headers.replace("Authorization", auth);
                    } else {
                        string user = creds.username;
                        string pass = creds.secret;
                        msg.authenticate.connect((a, retrying) => {
                            if (retrying) return false;
                            a.authenticate(user, pass);
                            return true;
                        });
                    }
                }
                if (headers != null) headers.foreach((k, v) => msg.request_headers.replace(k, v));
                if (body != null) msg.set_request_body_from_bytes(content_type, body);
                if (accept_invalid_tls()) msg.accept_certificate.connect(() => true);
                Bytes data;
                try {
                    data = yield session.send_and_read_async(msg, Priority.DEFAULT, cancellable);
                } catch (IOError.CANCELLED e) {
                    throw new AccountsError.CANCELLED(e.message);
                } catch (Error e) {
                    throw new AccountsError.NETWORK(_("Could not reach %s: %s").printf(host_of(current), e.message));
                }
                uint status = msg.status_code;
                if (status == 301 || status == 302 || status == 303 || status == 307 || status == 308) {
                    string? location = msg.response_headers.get_one("Location");
                    if (location == null) return new HttpResponse(status, data, msg.response_headers, current);
                    current = resolve(current, location);
                    if (status == 303) current_method = "GET";
                    continue;
                }
                return new HttpResponse(status, data, msg.response_headers, current);
            }
            throw new AccountsError.PROTOCOL(_("Too many redirects from %s").printf(host_of(url)));
        }

        private Soup.Message prepare(string method, string current, string origin, AccountCredentials? creds,
                                     HashTable<string, string>? headers) throws AccountsError {
            Soup.Message msg;
            try {
                var parsed = Uri.parse(current, UriFlags.ENCODED);
                if (parsed.get_path() == "") {
                    parsed = Uri.build(UriFlags.ENCODED, parsed.get_scheme(), parsed.get_userinfo(), parsed.get_host(), parsed.get_port(), "/", parsed.get_query(), parsed.get_fragment());
                }
                msg = new Soup.Message.from_uri(method, parsed);
            } catch (UriError e) {
                throw new AccountsError.INVALID(_("The address %s is not valid").printf(current));
            }
            msg.add_flags(Soup.MessageFlags.NO_REDIRECT);
            if (creds != null && origin_of(current) == origin) {
                string? auth = creds.authorization_header();
                if (auth != null) {
                    msg.request_headers.replace("Authorization", auth);
                } else {
                    string user = creds.username;
                    string pass = creds.secret;
                    msg.authenticate.connect((a, retrying) => {
                        if (retrying) return false;
                        a.authenticate(user, pass);
                        return true;
                    });
                }
            }
            if (headers != null) headers.foreach((k, v) => msg.request_headers.replace(k, v));
            if (accept_invalid_tls()) msg.accept_certificate.connect(() => true);
            return msg;
        }

        private static bool is_redirect(uint status) {
            return status == 301 || status == 302 || status == 303 || status == 307 || status == 308;
        }

        private static async Bytes read_small(InputStream input, Cancellable? cancellable) {
            var buffer = new ByteArray();
            try {
                while (buffer.len < 1024 * 1024) {
                    var chunk = yield input.read_bytes_async(65536, Priority.DEFAULT, cancellable);
                    if (chunk.get_size() == 0) break;
                    buffer.append(chunk.get_data());
                }
                yield input.close_async(Priority.DEFAULT, null);
            } catch (Error e) {
            }
            return ByteArray.free_to_bytes(buffer);
        }

        private async AccountCredentials? reject(AccountCredentials? creds, bool retried) throws Error {
            if (creds != null && creds.is_token && !retried) return yield account.get_credentials(capability, true);
            yield account.report_problem(capability, "reauth");
            throw new AccountsError.NEEDS_REAUTH(_("%s rejected the saved credentials. Sign in again in Settings.").printf(account.display_name));
        }

        private AccountsError transfer_error(Error e, string url) {
            if (e is IOError.CANCELLED || e is AccountsError.CANCELLED) return new AccountsError.CANCELLED(e.message);
            if (e is AccountsError) return (AccountsError) e;
            return new AccountsError.NETWORK(_("Could not reach %s: %s").printf(host_of(url), e.message));
        }

        /**
         * Sends a request and writes the body of a successful answer to
         * `output` as it arrives, without keeping it in memory. Throws like
         * send_ok() for other statuses.
         *
         * @param method      HTTP method, usually GET.
         * @param url         Absolute address.
         * @param output      Where the body goes; it is not closed.
         * @param headers     Extra request headers, or null.
         * @param expected    Size to report when the server sends no length, or -1.
         * @param progress    Called as the body arrives, or null.
         * @param cancellable Optional cancellable.
         * @return The response, with an empty body.
         */
        public async HttpResponse receive(string method, string url, OutputStream output, HashTable<string, string>? headers = null,
                                          int64 expected = -1, TransferProgress? progress = null, Cancellable? cancellable = null) throws Error {
            var creds = yield account.get_credentials(capability);
            bool retried = false;
            string current = url;
            string origin = origin_of(url);
            for (int hop = 0; hop < 8; hop++) {
                var msg = prepare(method, current, origin, creds, headers);
                InputStream input;
                try {
                    input = yield session.send_async(msg, Priority.DEFAULT, cancellable);
                } catch (Error e) {
                    throw transfer_error(e, current);
                }
                uint status = msg.status_code;
                if (is_redirect(status) && msg.response_headers.get_one("Location") != null) {
                    yield read_small(input, null);
                    current = resolve(current, msg.response_headers.get_one("Location"));
                    continue;
                }
                if (status == 401) {
                    yield read_small(input, null);
                    creds = yield reject(creds, retried);
                    retried = true;
                    current = url;
                    continue;
                }
                if (status < 200 || status >= 300) {
                    var failed = new HttpResponse(status, yield read_small(input, cancellable), msg.response_headers, current);
                    check(failed, method);
                }
                int64 length = msg.response_headers.get_content_length();
                int64 total = length > 0 ? length : expected;
                int64 done = 0;
                if (progress != null) progress(0, total);
                try {
                    while (true) {
                        var chunk = yield input.read_bytes_async(128 * 1024, Priority.DEFAULT, cancellable);
                        if (chunk.get_size() == 0) break;
                        size_t written;
                        yield output.write_all_async(chunk.get_data(), Priority.DEFAULT, cancellable, out written);
                        done += (int64) chunk.get_size();
                        if (progress != null) progress(done, total);
                    }
                    yield input.close_async(Priority.DEFAULT, null);
                } catch (Error e) {
                    throw transfer_error(e, current);
                }
                if (length > 0 && done != length) {
                    throw new AccountsError.NETWORK(_("The download from %s stopped before the end").printf(host_of(current)));
                }
                return new HttpResponse(status, new Bytes(null), msg.response_headers, current);
            }
            throw new AccountsError.PROTOCOL(_("Too many redirects from %s").printf(host_of(url)));
        }

        /**
         * Sends a request whose body is read from a range of a file while it
         * goes out, and returns the answer whatever its status, like send().
         *
         * @param method       HTTP method.
         * @param url          Absolute address.
         * @param content_type Type of the body, or null.
         * @param body         The body.
         * @param headers      Extra request headers, or null.
         * @param authorize    False for pre-authorized upload addresses, which must not get the account credentials.
         * @param progress     Called as the body goes out, with the bytes of this request, or null.
         * @param cancellable  Optional cancellable.
         */
        public async HttpResponse send_file(string method, string url, string? content_type, UploadSource body,
                                            HashTable<string, string>? headers = null, bool authorize = true,
                                            TransferProgress? progress = null, Cancellable? cancellable = null) throws Error {
            AccountCredentials? creds = authorize ? yield account.get_credentials(capability) : null;
            bool retried = false;
            string current = url;
            string origin = origin_of(url);
            for (int hop = 0; hop < 8; hop++) {
                var msg = prepare(method, current, origin, creds, headers);
                InputStream stream;
                try {
                    stream = body.open(cancellable);
                } catch (Error e) {
                    throw transfer_error(e, current);
                }
                msg.set_request_body(content_type, stream, (ssize_t) body.length);
                int64 sent = 0;
                ulong wrote = 0;
                if (progress != null) {
                    progress(0, body.length);
                    wrote = msg.wrote_body_data.connect((chunk) => {
                        sent += chunk;
                        progress(sent, body.length);
                    });
                }
                Bytes data;
                try {
                    data = yield session.send_and_read_async(msg, Priority.DEFAULT, cancellable);
                } catch (Error e) {
                    if (wrote != 0) msg.disconnect(wrote);
                    throw transfer_error(e, current);
                }
                if (wrote != 0) msg.disconnect(wrote);
                uint status = msg.status_code;
                if (is_redirect(status) && msg.response_headers.get_one("Location") != null) {
                    current = resolve(current, msg.response_headers.get_one("Location"));
                    continue;
                }
                if (status == 401 && authorize) {
                    creds = yield reject(creds, retried);
                    retried = true;
                    current = url;
                    continue;
                }
                return new HttpResponse(status, data, msg.response_headers, current);
            }
            throw new AccountsError.PROTOCOL(_("Too many redirects from %s").printf(host_of(url)));
        }

        /** Sends a request and throws unless the status is 2xx. */
        public async HttpResponse send_ok(string method, string url, string? content_type = null, Bytes? body = null,
                                          HashTable<string, string>? headers = null, Cancellable? cancellable = null) throws Error {
            var response = yield send(method, url, content_type, body, headers, cancellable);
            check(response, method);
            return response;
        }

        /**
         * Throws the matching AccountsError for a failed response: CONFLICT
         * for 409 and 412, NOT_FOUND for 404 and 410, PROTOCOL otherwise.
         */
        public static void check(HttpResponse response, string what) throws AccountsError {
            if (response.ok) return;
            switch (response.status) {
                case 404:
                case 410:
                    throw new AccountsError.NOT_FOUND(_("%s: not found on the server").printf(what));
                case 409:
                case 412:
                    throw new AccountsError.CONFLICT(_("%s: the item changed on the server").printf(what));
                case 403:
                    throw new AccountsError.AUTH_FAILED(_("%s: the server does not allow this").printf(what));
                default:
                    throw new AccountsError.PROTOCOL(_("%s failed with HTTP %u").printf(what, response.status));
            }
        }

        /** Resolves `reference` against `base_url`. */
        public static string resolve(string base_url, string reference) {
            if (reference.has_prefix("http://") || reference.has_prefix("https://")) return reference;
            try {
                return Uri.resolve_relative(base_url, reference, UriFlags.ENCODED);
            } catch (UriError e) {
                return reference;
            }
        }

        /** Scheme, host and port of an address. */
        public static string origin_of(string url) {
            try {
                var u = Uri.parse(url, UriFlags.ENCODED);
                return "%s://%s:%d".printf(u.get_scheme(), (u.get_host() ?? "").down(), u.get_port());
            } catch (UriError e) {
                return url;
            }
        }

        /** Host name of an address, for messages. */
        public static string host_of(string url) {
            try {
                return Uri.parse(url, UriFlags.ENCODED).get_host() ?? url;
            } catch (UriError e) {
                return url;
            }
        }
    }
}
