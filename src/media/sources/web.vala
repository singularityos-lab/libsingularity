namespace Singularity.MediaSources {

    public class WebReply : Object {
        public uint status { get; construct; }
        public Bytes body { get; construct; }
        public Soup.MessageHeaders headers { get; construct; }

        public WebReply(uint status, Bytes body, Soup.MessageHeaders headers) {
            Object(status: status, body: body, headers: headers);
        }

        public string text() {
            if (body.get_size() == 0) return "";
            var sb = new StringBuilder.sized(body.get_size() + 1);
            sb.append_len((string) body.get_data(), (ssize_t) body.get_size());
            return sb.str;
        }

        public Json.Node json() throws Error {
            var parser = new Json.Parser();
            parser.load_from_data(text(), -1);
            var root = parser.get_root();
            if (root == null) throw new MediaError.PROTOCOL("Empty answer");
            return root.copy();
        }

        public int retry_after() {
            string? v = headers.get_one("Retry-After");
            int64 s = -1;
            if (v != null && int64.try_parse(v.strip(), out s) && s >= 0) return (int) s;
            return -1;
        }
    }

    public class Web : Object {
        public static async WebReply request(Soup.Session session, string method, string url, HashTable<string, string>? headers = null,
                                             string? content_type = null, Bytes? body = null, Cancellable? cancellable = null) throws Error {
            Soup.Message msg;
            try {
                msg = new Soup.Message.from_uri(method, Uri.parse(url, UriFlags.ENCODED));
            } catch (UriError e) {
                throw new MediaError.PROTOCOL("Invalid address %s", url);
            }
            if (headers != null) headers.foreach((k, v) => msg.request_headers.replace(k, v));
            if (msg.request_headers.get_one("Accept") == null) msg.request_headers.replace("Accept", "application/json");
            if (body != null) msg.set_request_body_from_bytes(content_type ?? "application/octet-stream", body);
            Bytes data;
            try {
                data = yield session.send_and_read_async(msg, Priority.DEFAULT, cancellable);
            } catch (IOError.CANCELLED e) {
                throw e;
            } catch (Error e) {
                throw new MediaError.NETWORK("%s", e.message);
            }
            return new WebReply(msg.status_code, data, msg.response_headers);
        }

        public static void check(WebReply reply, string what) throws MediaError {
            uint s = reply.status;
            if (s >= 200 && s < 300) return;
            if (s == 401 || s == 403) throw new MediaError.AUTH_FAILED("%s refused the request (HTTP %u)", what, s);
            if (s == 404) throw new MediaError.NOT_FOUND("%s has no such item", what);
            if (s == 429) {
                int wait = reply.retry_after();
                if (wait >= 0) throw new MediaError.RATE_LIMITED("%s asks to wait %d seconds", what, wait);
                throw new MediaError.RATE_LIMITED("%s asks to wait before the next request", what);
            }
            if (s >= 500) throw new MediaError.NETWORK("%s is not answering (HTTP %u)", what, s);
            throw new MediaError.PROTOCOL("%s answered HTTP %u", what, s);
        }

        public static async Json.Node get_json(Soup.Session session, string url, HashTable<string, string>? headers, string what, Cancellable? cancellable) throws Error {
            var reply = yield request(session, "GET", url, headers, null, null, cancellable);
            check(reply, what);
            return reply.json();
        }

        public static string query(HashTable<string, string> parameters) {
            var keys = new Gee.ArrayList<string>();
            foreach (var k in parameters.get_keys()) keys.add(k);
            keys.sort();
            var sb = new StringBuilder();
            foreach (var k in keys) {
                if (sb.len > 0) sb.append_c('&');
                sb.append(Uri.escape_string(k, null, false));
                sb.append_c('=');
                sb.append(Uri.escape_string(parameters.lookup(k), null, false));
            }
            return sb.str;
        }

        public static string str(Json.Object? o, string key, string fallback = "") {
            if (o == null || !o.has_member(key)) return fallback;
            var n = o.get_member(key);
            if (n.get_node_type() != Json.NodeType.VALUE) return fallback;
            var t = n.get_value_type();
            if (t == typeof(string)) return n.get_string() ?? fallback;
            if (t == typeof(int64)) return n.get_int().to_string();
            if (t == typeof(double)) return n.get_double().to_string();
            if (t == typeof(bool)) return n.get_boolean() ? "true" : "false";
            return fallback;
        }

        public static int64 num(Json.Object? o, string key, int64 fallback = 0) {
            if (o == null || !o.has_member(key)) return fallback;
            var n = o.get_member(key);
            if (n.get_node_type() != Json.NodeType.VALUE) return fallback;
            var t = n.get_value_type();
            if (t == typeof(int64)) return n.get_int();
            if (t == typeof(double)) return (int64) n.get_double();
            if (t == typeof(string)) {
                int64 v;
                if (int64.try_parse(n.get_string(), out v)) return v;
            }
            return fallback;
        }

        public static bool flag(Json.Object? o, string key, bool fallback = false) {
            if (o == null || !o.has_member(key)) return fallback;
            var n = o.get_member(key);
            if (n.get_node_type() != Json.NodeType.VALUE) return fallback;
            if (n.get_value_type() == typeof(bool)) return n.get_boolean();
            return fallback;
        }

        public static Json.Object? obj(Json.Object? o, string key) {
            if (o == null || !o.has_member(key)) return null;
            var n = o.get_member(key);
            return n.get_node_type() == Json.NodeType.OBJECT ? n.get_object() : null;
        }

        public static Json.Array? arr(Json.Object? o, string key) {
            if (o == null || !o.has_member(key)) return null;
            var n = o.get_member(key);
            return n.get_node_type() == Json.NodeType.ARRAY ? n.get_array() : null;
        }
    }
}
