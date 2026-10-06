namespace Singularity.Accounts {

    internal const int64 CLOUD_CHUNK_SIZE = 10 * 1024 * 1024;
    internal const int64 CLOUD_SIMPLE_UPLOAD_LIMIT = 4 * 1024 * 1024;

    /**
     * A file or folder in an online account's storage.
     */
    public class CloudEntry : Object {
        /** Opaque identifier inside the drive (a path for WebDAV, an id otherwise). */
        public string id { get; set; default = ""; }
        /** Identifier of the parent folder, or an empty string when unknown. */
        public string parent_id { get; set; default = ""; }
        /** File name. */
        public string name { get; set; default = ""; }
        /** True for folders. */
        public bool is_folder { get; set; default = false; }
        /** Size in bytes, or -1 when unknown. */
        public int64 size { get; set; default = -1; }
        /** Last modification time, or null. */
        public DateTime? modified { get; set; default = null; }
        /** Media type, or an empty string. */
        public string content_type { get; set; default = ""; }
        /** Version tag, or an empty string. */
        public string etag { get; set; default = ""; }
        /**
         * For documents that only exist in the provider's own format (Google
         * Docs), the media type they are exported to when downloaded.
         */
        public string export_type { get; set; default = ""; }

        /** Icon for the content type, with the generic fallbacks of the type. */
        public GLib.Icon gicon {
            owned get {
                if (is_folder) return new ThemedIcon("folder");
                string type = content_type != "" ? content_type : ContentType.guess(name, null, null);
                var icon = ContentType.get_icon(type) as ThemedIcon;
                if (icon == null) return new ThemedIcon("text-x-generic");
                icon.append_name("text-x-generic");
                return icon;
            }
        }

        /** Themed icon name matching the content type. */
        public string icon_name {
            owned get {
                if (is_folder) return "folder";
                string type = content_type != "" ? content_type : ContentType.guess(name, null, null);
                var icon = ContentType.get_icon(type) as ThemedIcon;
                return icon != null && icon.names.length > 0 ? icon.names[0] : "text-x-generic";
            }
        }
    }

    /**
     * Storage use of an online account.
     */
    public class CloudQuota : Object {
        /** Bytes in use. */
        public int64 used { get; set; default = 0; }
        /** Total bytes the account can hold, or -1 when unlimited or unknown. */
        public int64 total { get; set; default = -1; }

        /** Bytes still free, or -1 when unknown. */
        public int64 free {
            get { return total >= 0 ? int64.max(0, total - used) : -1; }
        }
    }

    /**
     * Files of an online account: WebDAV (Nextcloud, ownCloud, generic),
     * Google Drive or OneDrive, behind one interface.
     */
    public interface CloudDrive : Object {
        /** The account the drive belongs to. */
        public abstract Account account { get; }
        /** Identifier of the top folder. */
        public abstract string root_id { get; }

        /** Lists a folder. */
        public abstract async Gee.List<CloudEntry> list(string folder_id, Cancellable? cancellable = null) throws Error;
        /** Returns one entry. */
        public abstract async CloudEntry stat(string id, Cancellable? cancellable = null) throws Error;
        /**
         * Writes the content of a file to a stream as it arrives, without
         * keeping it in memory. The stream is not closed.
         */
        public abstract async void download_to(CloudEntry entry, OutputStream output, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error;
        /**
         * Downloads a file to a local path, streaming it. An existing file
         * at the path is only replaced once the download is complete.
         */
        public abstract async void download(CloudEntry entry, File destination, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error;
        /**
         * Uploads a local file into a folder, replacing a file with the same
         * name. The file is streamed; large files go up in resumable or
         * chunked sessions where the provider has them.
         */
        public abstract async CloudEntry upload(string folder_id, string name, File source, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error;
        /** Replaces the content of an existing file, streaming it like upload(). */
        public abstract async CloudEntry replace(CloudEntry entry, File source, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error;
        public virtual async CloudEntry replace_if_match(CloudEntry entry, File source, string expected_etag, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            require_strong_etag(expected_etag);
            throw new IOError.NOT_SUPPORTED(_("This provider does not support an atomic conditional replacement"));
        }
        /** Renames a file or folder. */
        public abstract async CloudEntry rename(CloudEntry entry, string new_name, Cancellable? cancellable = null) throws Error;
        /**
         * Moves a file or folder into another folder, optionally renaming it
         * on the way.
         *
         * @param entry     What to move.
         * @param folder_id The folder it goes into.
         * @param new_name  The new name, or null to keep the name.
         */
        public abstract async CloudEntry move(CloudEntry entry, string folder_id, string? new_name = null, Cancellable? cancellable = null) throws Error;
        /** Deletes a file or folder. */
        public abstract async void delete(CloudEntry entry, Cancellable? cancellable = null) throws Error;
        /** Creates a folder. */
        public abstract async CloudEntry create_folder(string parent_id, string name, Cancellable? cancellable = null) throws Error;

        /**
         * Storage used and available in the account, or null when the
         * provider does not report it.
         */
        public virtual async CloudQuota? quota(Cancellable? cancellable = null) throws Error {
            return null;
        }

        /**
         * Returns the drive of an account with the files capability, or null
         * when the account has none.
         */
        public static CloudDrive? for_account(Account account) {
            if (!account.has_capability(Capability.FILES)) return null;
            string api = account.get_endpoint("files-api") ?? (account.get_endpoint("webdav") != null ? "webdav" : "");
            var http = new HttpClient(account, Capability.FILES);
            switch (api) {
                case "webdav": {
                    string? root = account.get_endpoint("webdav");
                    if (root == null) return null;
                    return new WebDavDrive(account, http, root);
                }
                case "google-drive":
                    return new GoogleDrive(account, http,
                        account.get_endpoint("google-drive") ?? "https://www.googleapis.com/drive/v3/",
                        account.get_endpoint("google-drive-upload") ?? "https://www.googleapis.com/upload/drive/v3/");
                case "onedrive":
                    return new OneDrive(account, http, account.get_endpoint("graph") ?? "https://graph.microsoft.com/v1.0/");
                default:
                    return null;
            }
        }

        public static async CloudDrive? for_app_data(Account account, Cancellable? cancellable = null) throws Error {
            if (cancellable != null) cancellable.set_error_if_cancelled();
            if (!account.has_capability(Capability.FILES)) throw new AccountsError.INVALID(_("Enable Files for this account before syncing Browser data"));
            if (!account.healthy) throw new AccountsError.NEEDS_REAUTH(_("Sign in to this account again before syncing Browser data"));
            string api = account.get_endpoint("files-api") ?? (account.get_endpoint("webdav") != null ? "webdav" : "");
            var http = new HttpClient(account, Capability.FILES);
            switch (api) {
                case "google-drive":
                    if (account.auth != "oauth2") throw new AccountsError.INVALID(_("Google application data requires a signed-in Google account"));
                    return new GoogleDrive.app_data(account, http,
                        account.get_endpoint("google-drive") ?? "https://www.googleapis.com/drive/v3/",
                        account.get_endpoint("google-drive-upload") ?? "https://www.googleapis.com/upload/drive/v3/");
                case "onedrive": {
                    if (account.auth != "oauth2") throw new AccountsError.INVALID(_("OneDrive application data requires a signed-in Microsoft account"));
                    var drive = new OneDrive.app_data(account, http, account.get_endpoint("graph") ?? "https://graph.microsoft.com/v1.0/");
                    yield drive.initialize_app_data(cancellable);
                    return drive;
                }
                case "webdav": {
                    string? root = account.get_endpoint("webdav");
                    if (root == null || (account.auth != "password" && account.auth != "oauth2")) throw new AccountsError.INVALID(_("This account has no signed-in WebDAV storage"));
                    if (!root.has_suffix("/")) root += "/";
                    var parent = new WebDavDrive.app_data(account, http, root);
                    string folder = parent.root_id + ".singularity-browser/";
                    CloudEntry entry;
                    try {
                        entry = yield parent.stat(folder, cancellable);
                    } catch (AccountsError.NOT_FOUND e) {
                        entry = yield parent.create_folder(parent.root_id, ".singularity-browser", cancellable);
                    }
                    if (!entry.is_folder || entry.id != folder) throw new AccountsError.PROTOCOL(_("The Browser data folder is not a directory"));
                    return new WebDavDrive.app_data(account, http, root + ".singularity-browser/");
                }
                default:
                    return null;
            }
        }

        internal static void require_strong_etag(string etag) throws Error {
            if (etag.length < 2 || !etag.has_prefix("\"") || !etag.has_suffix("\""))
                throw new IOError.INVALID_ARGUMENT(_("A strong quoted entity tag is required"));
            for (int i = 1; i < etag.length - 1; i++) {
                uint8 c = etag.data[i];
                if (c < 0x21 || c == 0x7f || c == '"') throw new IOError.INVALID_ARGUMENT(_("Invalid entity tag"));
            }
        }

        internal static string page_string(Json.Object object, string name, bool required = false) throws Error {
            if (!object.has_member(name)) {
                if (!required) return "";
                throw new AccountsError.PROTOCOL(_("The server response is missing %s").printf(name));
            }
            var node = object.get_member(name);
            if (node.get_node_type() != Json.NodeType.VALUE || node.get_value().type() != typeof(string))
                throw new AccountsError.PROTOCOL(_("The server response has an invalid %s").printf(name));
            string value = node.get_string();
            if (required && (value == "" || value != value.strip())) throw new AccountsError.PROTOCOL(_("The server response has an invalid %s").printf(name));
            return value;
        }

        internal static Json.Array page_array(Json.Object object, string name) throws Error {
            if (!object.has_member(name) || object.get_member(name).get_node_type() != Json.NodeType.ARRAY)
                throw new AccountsError.PROTOCOL(_("The server response has an invalid %s").printf(name));
            return object.get_array_member(name);
        }

        internal static string next_page(string expected, string next) throws Error {
            var base_uri = Uri.parse(expected, UriFlags.ENCODED);
            var actual = Uri.parse(next, UriFlags.ENCODED);
            if (HttpClient.origin_of(expected) != HttpClient.origin_of(next) || actual.get_path() != base_uri.get_path()
                || actual.get_userinfo() != null || actual.get_fragment() != null)
                throw new AccountsError.PROTOCOL(_("The next page is outside the account's application folder"));
            return next;
        }

        /** Guesses the media type of a file from its name. */
        public static string guess_type(string name) {
            bool uncertain;
            return ContentType.get_mime_type(ContentType.guess(name, null, out uncertain)) ?? "application/octet-stream";
        }

        internal static async void save_to_file(CloudDrive drive, CloudEntry entry, File destination, Cancellable? cancellable, TransferProgress? progress) throws Error {
            bool existed = destination.query_exists(null);
            var output = yield destination.replace_async(null, false, FileCreateFlags.REPLACE_DESTINATION, Priority.DEFAULT, cancellable);
            try {
                yield drive.download_to(entry, output, cancellable, progress);
                yield output.close_async(Priority.DEFAULT, cancellable);
            } catch (Error e) {
                var abort = new Cancellable();
                abort.cancel();
                try {
                    output.close(abort);
                } catch (Error ignored) {
                }
                if (!existed) {
                    try {
                        destination.delete(null);
                    } catch (Error ignored) {
                    }
                }
                throw e;
            }
        }

        internal static async int64 size_of(File file, Cancellable? cancellable) throws Error {
            var info = yield file.query_info_async(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE, Priority.DEFAULT, cancellable);
            return info.get_size();
        }

        internal static HashTable<string, string> headers(string first_key, string first_value, ...) {
            var table = new HashTable<string, string>(str_hash, str_equal);
            table.insert(first_key, first_value);
            var args = va_list();
            while (true) {
                string? key = args.arg();
                if (key == null) break;
                string value = args.arg();
                table.insert(key, value);
            }
            return table;
        }
    }

    /**
     * A WebDAV folder tree; ids are decoded absolute paths.
     */
    public class WebDavDrive : Object, CloudDrive {
        private Account _account;
        private DavClient dav;
        private string root_url;
        private string _root_id;
        private bool app_data_only = false;

        public Account account { get { return _account; } }
        public string root_id { get { return _root_id; } }

        public WebDavDrive(Account account, HttpClient http, string root_url) {
            _account = account;
            dav = new DavClient(http);
            this.root_url = root_url.has_suffix("/") ? root_url : root_url + "/";
            _root_id = DavRemoteCollection.key_of(this.root_url, this.root_url);
        }

        public WebDavDrive.app_data(Account account, HttpClient http, string root_url) {
            this(account, http, root_url);
            app_data_only = true;
        }

        private string url_of(string id) throws Error {
            if (app_data_only) {
                if (!id.has_prefix(_root_id)) throw new AccountsError.INVALID(_("The path is outside the Browser data folder"));
                foreach (string part in id.substring(_root_id.length).split("/")) {
                    if (part == "." || part == ".." || part.contains("\\") || part.contains("%") || part.contains("\r") || part.contains("\n"))
                        throw new AccountsError.INVALID(_("Invalid Browser data path"));
                }
            }
            string[] segs = {};
            foreach (string seg in id.split("/")) segs += Uri.escape_string(seg, "@:!$&'()*+,;=", false);
            return HttpClient.resolve(root_url, string.joinv("/", segs));
        }

        private static string parent_of(string id) {
            string trimmed = id.has_suffix("/") ? id.substring(0, id.length - 1) : id;
            int slash = trimmed.last_index_of("/");
            return slash >= 0 ? trimmed.substring(0, slash + 1) : "/";
        }

        private const string PROPS = """<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:displayname/><d:getcontentlength/><d:getlastmodified/><d:getcontenttype/><d:getetag/></d:prop></d:propfind>""";

        private CloudEntry entry_of(DavResponse r) throws Error {
            var e = new CloudEntry();
            e.id = DavRemoteCollection.key_of(root_url, r.href);
            e.is_folder = r.is_type(NS_DAV, "collection");
            if (e.is_folder && !e.id.has_suffix("/")) e.id += "/";
            if (app_data_only) {
                string absolute = HttpClient.resolve(root_url, r.href);
                var uri = Uri.parse(absolute, UriFlags.ENCODED);
                if (HttpClient.origin_of(absolute) != HttpClient.origin_of(root_url)
                    || uri.get_userinfo() != null || uri.get_query() != null || uri.get_fragment() != null)
                    throw new AccountsError.PROTOCOL(_("The server returned a file outside the Browser data folder"));
                url_of(e.id);
            }
            e.parent_id = parent_of(e.id);
            e.name = DavClient.last_segment(e.id);
            string size = r.text(NS_DAV, "getcontentlength");
            e.size = size != "" ? int64.parse(size) : -1;
            e.content_type = r.text(NS_DAV, "getcontenttype");
            if (e.content_type == "" && !e.is_folder) e.content_type = CloudDrive.guess_type(e.name);
            e.etag = r.text(NS_DAV, "getetag");
            string modified = r.text(NS_DAV, "getlastmodified");
            if (modified != "") e.modified = parse_http_date(modified);
            return e;
        }

        /** Parses an RFC 1123 date as used by getlastmodified. */
        public static DateTime? parse_http_date(string text) {
            string[] months = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
            var parts = text.strip().split(" ");
            if (parts.length < 5) return null;
            int month = 0;
            for (int i = 0; i < 12; i++) if (parts[2] == months[i]) month = i + 1;
            var hms = parts[4].split(":");
            if (month == 0 || hms.length < 3) return null;
            return new DateTime.utc(int.parse(parts[3]), month, int.parse(parts[1]), int.parse(hms[0]), int.parse(hms[1]), double.parse(hms[2]));
        }

        public async Gee.List<CloudEntry> list(string folder_id, Cancellable? cancellable = null) throws Error {
            var result = new Gee.ArrayList<CloudEntry>();
            string folder = folder_id.has_suffix("/") ? folder_id : folder_id + "/";
            var ms = yield dav.propfind(url_of(folder), "1", PROPS, cancellable);
            foreach (var r in ms.responses) {
                var e = entry_of(r);
                if (e.id == folder || e.id + "/" == folder) continue;
                result.add(e);
            }
            return result;
        }

        public async CloudEntry stat(string id, Cancellable? cancellable = null) throws Error {
            var ms = yield dav.propfind(url_of(id), "0", PROPS, cancellable);
            if (ms.responses.size == 0) throw new AccountsError.NOT_FOUND(_("%s was not found").printf(id));
            return entry_of(ms.responses[0]);
        }

        public async void download_to(CloudEntry entry, OutputStream output, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            yield dav.http.receive("GET", url_of(entry.id), output, null, entry.size, progress, cancellable);
        }

        public async void download(CloudEntry entry, File destination, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            yield CloudDrive.save_to_file(this, entry, destination, cancellable, progress);
        }

        public async CloudEntry upload(string folder_id, string name, File source, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            string folder = folder_id.has_suffix("/") ? folder_id : folder_id + "/";
            string id = folder + name;
            yield put_file(id, CloudDrive.guess_type(name), source, cancellable, progress);
            return yield stat(id, cancellable);
        }

        public async CloudEntry replace(CloudEntry entry, File source, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            yield put_file(entry.id, entry.content_type != "" ? entry.content_type : CloudDrive.guess_type(entry.name), source, cancellable, progress);
            return yield stat(entry.id, cancellable);
        }

        public async CloudEntry replace_if_match(CloudEntry entry, File source, string expected_etag, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            CloudDrive.require_strong_etag(expected_etag);
            string destination = url_of(entry.id);
            if (entry.is_folder) throw new IOError.INVALID_ARGUMENT(_("A directory cannot be replaced with a file"));
            int64 size = yield CloudDrive.size_of(source, cancellable);
            string type = entry.content_type != "" ? entry.content_type : CloudDrive.guess_type(entry.name);
            var response = yield dav.http.send_file("PUT", destination, type, new UploadSource(source, 0, size),
                CloudDrive.headers("If-Match", expected_etag), true, progress, cancellable);
            HttpClient.check(response, "Conditional replacement");
            string? tag = response.header("ETag");
            if (tag == null) throw new AccountsError.PROTOCOL(_("The server did not acknowledge the replacement with an entity tag"));
            CloudDrive.require_strong_etag(tag);
            return new CloudEntry() { id = entry.id, parent_id = entry.parent_id, name = entry.name,
                size = size, content_type = type, etag = tag };
        }

        /**
         * Address of the Nextcloud chunked upload area for this drive, or
         * null when the drive is not a Nextcloud files folder.
         */
        public string? uploads_url() {
            try {
                var re = new Regex("^(.*/remote\\.php/dav/)files/([^/]+)/$");
                MatchInfo info;
                if (!re.match(root_url, 0, out info)) return null;
                return info.fetch(1) + "uploads/" + info.fetch(2) + "/";
            } catch (RegexError e) {
                return null;
            }
        }

        private async void put_file(string id, string content_type, File source, Cancellable? cancellable, TransferProgress? progress) throws Error {
            int64 size = yield CloudDrive.size_of(source, cancellable);
            string? uploads = uploads_url();
            if (size > CLOUD_CHUNK_SIZE && uploads != null) {
                if (yield put_chunked(uploads, id, content_type, source, size, cancellable, progress)) return;
            }
            var response = yield dav.http.send_file("PUT", url_of(id), content_type, new UploadSource(source, 0, size), null, true, progress, cancellable);
            HttpClient.check(response, "PUT");
        }

        private async bool put_chunked(string uploads, string id, string content_type, File source, int64 size,
                                       Cancellable? cancellable, TransferProgress? progress) throws Error {
            string destination = url_of(id);
            string transfer = uploads + "singularity-" + Uuid.string_random().replace("-", "") + "/";
            var started = yield dav.http.send("MKCOL", transfer, null, null, CloudDrive.headers("Destination", destination), cancellable);
            if (started.status == 404 || started.status == 405 || started.status == 403 || started.status == 501) return false;
            HttpClient.check(started, "MKCOL");
            try {
                int64 offset = 0;
                int part = 0;
                while (offset < size) {
                    int64 n = int64.min(CLOUD_CHUNK_SIZE, size - offset);
                    part++;
                    int64 base_offset = offset;
                    var response = yield dav.http.send_file("PUT", transfer + "%05d".printf(part), "application/octet-stream",
                        new UploadSource(source, offset, n),
                        CloudDrive.headers("Destination", destination, "OC-Total-Length", size.to_string()), true,
                        (done, total) => {
                            if (progress != null) progress(base_offset + done, size);
                        }, cancellable);
                    HttpClient.check(response, "PUT");
                    offset += n;
                }
                var assembled = yield dav.http.send("MOVE", transfer + ".file", null, null,
                    CloudDrive.headers("Destination", destination, "OC-Total-Length", size.to_string(), "Overwrite", "T"), cancellable);
                HttpClient.check(assembled, "MOVE");
            } catch (Error e) {
                try {
                    yield dav.http.send("DELETE", transfer, null, null, null, null);
                } catch (Error ignored) {
                }
                throw e;
            }
            return true;
        }

        public async CloudEntry move(CloudEntry entry, string folder_id, string? new_name = null, Cancellable? cancellable = null) throws Error {
            string folder = folder_id.has_suffix("/") ? folder_id : folder_id + "/";
            string target = folder + (new_name ?? entry.name) + (entry.is_folder ? "/" : "");
            yield dav.move(url_of(entry.id), url_of(target), false, cancellable);
            return yield stat(target, cancellable);
        }

        public async CloudEntry rename(CloudEntry entry, string new_name, Cancellable? cancellable = null) throws Error {
            string target = parent_of(entry.id) + new_name + (entry.is_folder ? "/" : "");
            yield dav.move(url_of(entry.id), url_of(target), false, cancellable);
            return yield stat(target, cancellable);
        }

        public async CloudQuota? quota(Cancellable? cancellable = null) throws Error {
            const string BODY = """<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:quota-used-bytes/><d:quota-available-bytes/></d:prop></d:propfind>""";
            var ms = yield dav.propfind(url_of(_root_id), "0", BODY, cancellable);
            if (ms.responses.size == 0) return null;
            string used = ms.responses[0].text(NS_DAV, "quota-used-bytes");
            string available = ms.responses[0].text(NS_DAV, "quota-available-bytes");
            if (used == "" && available == "") return null;
            var q = new CloudQuota();
            q.used = used != "" ? int64.parse(used) : 0;
            int64 avail = available != "" ? int64.parse(available) : -1;
            q.total = avail >= 0 ? q.used + avail : -1;
            return q;
        }

        public async void delete(CloudEntry entry, Cancellable? cancellable = null) throws Error {
            yield dav.delete(url_of(entry.id), null, cancellable);
        }

        public async CloudEntry create_folder(string parent_id, string name, Cancellable? cancellable = null) throws Error {
            string parent = parent_id.has_suffix("/") ? parent_id : parent_id + "/";
            string id = parent + name + "/";
            yield dav.mkcol(url_of(id), cancellable);
            return yield stat(id, cancellable);
        }
    }

    /**
     * Google Drive (API v3); ids are Drive file ids and "root" is the top.
     */
    public class GoogleDrive : Object, CloudDrive {
        private Account _account;
        private HttpClient http;
        private string api;
        private string upload_api;
        private bool app_data_only = false;
        private Gee.HashSet<string> app_folders = new Gee.HashSet<string>();
        private Gee.HashSet<string> app_entries = new Gee.HashSet<string>();

        public Account account { get { return _account; } }
        public string root_id { get { return app_data_only ? "appDataFolder" : "root"; } }

        private const string FIELDS = "id,name,mimeType,size,modifiedTime,md5Checksum,parents";
        private const string FOLDER_TYPE = "application/vnd.google-apps.folder";

        public GoogleDrive(Account account, HttpClient http, string api, string upload_api) {
            _account = account;
            this.http = http;
            this.api = api.has_suffix("/") ? api : api + "/";
            this.upload_api = upload_api.has_suffix("/") ? upload_api : upload_api + "/";
        }

        public GoogleDrive.app_data(Account account, HttpClient http, string api, string upload_api) {
            this(account, http, api, upload_api);
            app_data_only = true;
            app_folders.add("appDataFolder");
        }

        private void app_folder(string id) throws Error {
            if (app_data_only && !app_folders.contains(id)) throw new AccountsError.INVALID(_("The folder is outside application data"));
        }

        private async Gee.List<CloudEntry> list_app_data(string folder_id, string? name, Cancellable? cancellable) throws Error {
            app_folder(folder_id);
            string filter = "'%s' in parents and trashed = false".printf(folder_id.replace("\\", "\\\\").replace("'", "\\'"));
            if (name != null) filter += " and name = '%s'".printf(name.replace("\\", "\\\\").replace("'", "\\'"));
            string first = api + "files?spaces=appDataFolder&q=" + esc(filter)
                + "&fields=" + esc("nextPageToken,files(" + FIELDS + ")") + "&pageSize=200";
            string next = first;
            var pages = new Gee.HashSet<string>();
            var ids = new Gee.HashSet<string>();
            var result = new Gee.ArrayList<CloudEntry>();
            while (next != "") {
                if (!pages.add(next)) throw new AccountsError.PROTOCOL(_("The server repeated an application-data page"));
                var response = yield http.send_ok("GET", next, null, null, null, cancellable);
                var object = response.json_object();
                foreach (var node in CloudDrive.page_array(object, "files").get_elements()) {
                    if (node.get_node_type() != Json.NodeType.OBJECT) throw new AccountsError.PROTOCOL(_("The server returned an invalid file"));
                    var file = node.get_object();
                    string id = CloudDrive.page_string(file, "id", true);
                    if (!ids.add(id) || id == "root" || id == "appDataFolder") throw new AccountsError.PROTOCOL(_("The server repeated an application-data file"));
                    var entry = entry_of(file);
                    entry.parent_id = folder_id;
                    result.add(entry);
                }
                string token = CloudDrive.page_string(object, "nextPageToken");
                next = token != "" ? first + "&pageToken=" + esc(token) : "";
            }
            if (cancellable != null) cancellable.set_error_if_cancelled();
            foreach (var entry in result) {
                app_entries.add(entry.id);
                if (entry.is_folder) app_folders.add(entry.id);
            }
            return result;
        }

        private void app_entry(string id) throws Error {
            if (app_data_only && !app_entries.contains(id)) throw new AccountsError.INVALID(_("The file is outside the discovered application data"));
        }

        private static string esc(string s) {
            return Uri.escape_string(s, null, false);
        }

        /** Media type a Google native document is exported to, or an empty string. */
        public static string export_type_for(string mime) {
            switch (mime) {
                case "application/vnd.google-apps.document": return "application/vnd.oasis.opendocument.text";
                case "application/vnd.google-apps.spreadsheet": return "application/vnd.oasis.opendocument.spreadsheet";
                case "application/vnd.google-apps.presentation": return "application/vnd.oasis.opendocument.presentation";
                case "application/vnd.google-apps.drawing": return "image/svg+xml";
                default: return "";
            }
        }

        private static string extension_for(string export_type) {
            switch (export_type) {
                case "application/vnd.oasis.opendocument.text": return ".odt";
                case "application/vnd.oasis.opendocument.spreadsheet": return ".ods";
                case "application/vnd.oasis.opendocument.presentation": return ".odp";
                case "image/svg+xml": return ".svg";
                default: return "";
            }
        }

        private CloudEntry entry_of(Json.Object o) throws Error {
            if (app_data_only) {
                string id = CloudDrive.page_string(o, "id", true);
                CloudDrive.page_string(o, "name");
                CloudDrive.page_string(o, "mimeType");
                CloudDrive.page_string(o, "md5Checksum");
                CloudDrive.page_string(o, "modifiedTime");
                if (o.has_member("parents")) {
                    foreach (var parent in CloudDrive.page_array(o, "parents").get_elements()) {
                        if (parent.get_node_type() != Json.NodeType.VALUE || parent.get_value().type() != typeof(string))
                            throw new AccountsError.PROTOCOL(_("The server returned an invalid file parent"));
                        if (!app_folders.contains(parent.get_string())) throw new AccountsError.PROTOCOL(_("The server returned a file outside application data"));
                    }
                }
                if (o.has_member("size")) {
                    var size = o.get_member("size");
                    if (size.get_node_type() != Json.NodeType.VALUE || (size.get_value().type() != typeof(string) && size.get_value().type() != typeof(int64)))
                        throw new AccountsError.PROTOCOL(_("The server returned an invalid file size"));
                    int64 bytes = 0;
                    if ((size.get_value().type() == typeof(string) && !int64.try_parse(size.get_string(), out bytes))
                        || (size.get_value().type() == typeof(string) ? bytes : size.get_int()) < 0)
                        throw new AccountsError.PROTOCOL(_("The server returned an invalid file size"));
                }
                if (id == "root" || id == "appDataFolder") throw new AccountsError.PROTOCOL(_("The server returned a file outside application data"));
            }
            var e = new CloudEntry();
            e.id = o.get_string_member("id");
            e.name = o.has_member("name") ? o.get_string_member("name") : e.id;
            string mime = o.has_member("mimeType") ? o.get_string_member("mimeType") : "";
            e.is_folder = mime == FOLDER_TYPE;
            e.content_type = e.is_folder ? "inode/directory" : mime;
            e.export_type = export_type_for(mime);
            if (e.export_type != "") {
                e.content_type = e.export_type;
                if (!e.name.has_suffix(extension_for(e.export_type))) e.name += extension_for(e.export_type);
            }
            if (o.has_member("size")) {
                var n = o.get_member("size");
                e.size = n.get_value().type() == typeof(string) ? int64.parse(n.get_string()) : n.get_int();
            }
            if (o.has_member("modifiedTime")) e.modified = new DateTime.from_iso8601(o.get_string_member("modifiedTime"), null);
            if (o.has_member("md5Checksum")) e.etag = o.get_string_member("md5Checksum");
            if (o.has_member("parents") && o.get_array_member("parents").get_length() > 0) {
                e.parent_id = o.get_array_member("parents").get_string_element(0);
            }
            return e;
        }

        public async Gee.List<CloudEntry> list(string folder_id, Cancellable? cancellable = null) throws Error {
            if (app_data_only) return yield list_app_data(folder_id, null, cancellable);
            var result = new Gee.ArrayList<CloudEntry>();
            string q = esc("'%s' in parents and trashed = false".printf(folder_id.replace("'", "\\'")));
            string page = "";
            for (int n = 0; n < 100; n++) {
                string url = api + "files?q=" + q + "&fields=" + esc("nextPageToken,files(" + FIELDS + ")") + "&pageSize=200&orderBy=folder,name";
                if (page != "") url += "&pageToken=" + esc(page);
                var response = yield http.send_ok("GET", url, null, null, null, cancellable);
                var root = response.json_object();
                if (root.has_member("files")) {
                    foreach (var node in root.get_array_member("files").get_elements()) {
                        var e = entry_of(node.get_object());
                        if (e.parent_id == "") e.parent_id = folder_id;
                        result.add(e);
                    }
                }
                page = root.has_member("nextPageToken") ? root.get_string_member("nextPageToken") : "";
                if (page == "") break;
            }
            return result;
        }

        public async CloudEntry stat(string id, Cancellable? cancellable = null) throws Error {
            app_entry(id);
            var response = yield http.send_ok("GET", api + "files/" + esc(id) + "?fields=" + esc(FIELDS), null, null, null, cancellable);
            return entry_of(response.json_object());
        }

        public async void download_to(CloudEntry entry, OutputStream output, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            app_entry(entry.id);
            string url = entry.export_type != ""
                ? api + "files/" + esc(entry.id) + "/export?mimeType=" + esc(entry.export_type)
                : api + "files/" + esc(entry.id) + "?alt=media";
            yield http.receive("GET", url, output, null, entry.export_type != "" ? -1 : entry.size, progress, cancellable);
        }

        public async void download(CloudEntry entry, File destination, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            yield CloudDrive.save_to_file(this, entry, destination, cancellable, progress);
        }

        private static Bytes json_bytes(Json.Object o) {
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(o);
            var gen = new Json.Generator();
            gen.set_root(node);
            return new Bytes(gen.to_data(null).data);
        }

        public async CloudEntry upload(string folder_id, string name, File source, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            if (app_data_only) {
                var matching = yield list_app_data(folder_id, name, cancellable);
                if (matching.size > 1) throw new AccountsError.CONFLICT(_("Several application-data files have this name"));
                if (matching.size == 1) {
                    if (matching[0].is_folder || matching[0].export_type != "") throw new AccountsError.CONFLICT(_("This application-data name is already used"));
                    return yield replace(matching[0], source, cancellable, progress);
                }
            } else {
                string q = esc("'%s' in parents and name = '%s' and trashed = false".printf(folder_id.replace("'", "\\'"), name.replace("'", "\\'")));
                var found = yield http.send_ok("GET", api + "files?q=" + q + "&fields=" + esc("files(" + FIELDS + ")"), null, null, null, cancellable);
                var root = found.json_object();
                if (root.has_member("files") && root.get_array_member("files").get_length() > 0) {
                    var existing = entry_of(root.get_array_member("files").get_object_element(0));
                    if (!existing.is_folder && existing.export_type == "") return yield replace(existing, source, cancellable, progress);
                }
            }
            var meta = new Json.Object();
            meta.set_string_member("name", name);
            var parents = new Json.Array();
            parents.add_string_element(folder_id);
            meta.set_array_member("parents", parents);
            var uploaded = yield resumable("POST", upload_api + "files?uploadType=resumable&fields=" + esc(FIELDS), meta, CloudDrive.guess_type(name), source, cancellable, progress);
            if (app_data_only) app_entries.add(uploaded.id);
            return uploaded;
        }

        public async CloudEntry replace(CloudEntry entry, File source, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            app_entry(entry.id);
            return yield resumable("PATCH", upload_api + "files/" + esc(entry.id) + "?uploadType=resumable&fields=" + esc(FIELDS), new Json.Object(),
                entry.content_type != "" ? entry.content_type : CloudDrive.guess_type(entry.name), source, cancellable, progress);
        }

        private static int64 received_until(HttpResponse r) {
            string? range = r.header("Range");
            if (range == null) return 0;
            int dash = range.last_index_of("-");
            return dash >= 0 ? int64.parse(range.substring(dash + 1)) + 1 : 0;
        }

        private async CloudEntry resumable(string method, string url, Json.Object meta, string content_type, File source,
                                           Cancellable? cancellable, TransferProgress? progress) throws Error {
            int64 size = yield CloudDrive.size_of(source, cancellable);
            var started = yield http.send_ok(method, url, "application/json; charset=UTF-8", json_bytes(meta),
                CloudDrive.headers("X-Upload-Content-Type", content_type, "X-Upload-Content-Length", size.to_string()), cancellable);
            string? session = started.header("Location");
            if (session == null) throw new AccountsError.PROTOCOL(_("The server did not start the upload"));
            if (app_data_only) CloudDrive.next_page(url, session);
            if (size == 0) {
                if (progress != null) progress(0, 0);
                var empty_done = yield http.send_ok("PUT", session, content_type, new Bytes(null), CloudDrive.headers("Content-Range", "bytes */0"), cancellable);
                return entry_of(empty_done.json_object());
            }
            int64 offset = 0;
            int stalled = 0;
            if (progress != null) progress(0, size);
            while (true) {
                int64 n = int64.min(CLOUD_CHUNK_SIZE, size - offset);
                int64 base_offset = offset;
                var response = yield http.send_file("PUT", session, content_type, new UploadSource(source, offset, n),
                    CloudDrive.headers("Content-Range", "bytes %lld-%lld/%lld".printf(offset, offset + n - 1, size)), true,
                    (done, total) => {
                        if (progress != null) progress(base_offset + done, size);
                    }, cancellable);
                if (response.status == 308) {
                    int64 next = received_until(response);
                    stalled = next > offset ? 0 : stalled + 1;
                    if (stalled > 3) throw new AccountsError.PROTOCOL(_("The upload to %s does not advance").printf(HttpClient.host_of(session)));
                    offset = next;
                    continue;
                }
                HttpClient.check(response, "PUT");
                return entry_of(response.json_object());
            }
        }

        public async CloudEntry rename(CloudEntry entry, string new_name, Cancellable? cancellable = null) throws Error {
            app_entry(entry.id);
            var meta = new Json.Object();
            meta.set_string_member("name", new_name);
            var response = yield http.send_ok("PATCH", api + "files/" + esc(entry.id) + "?fields=" + esc(FIELDS), "application/json", json_bytes(meta), null, cancellable);
            return entry_of(response.json_object());
        }

        public async CloudEntry move(CloudEntry entry, string folder_id, string? new_name = null, Cancellable? cancellable = null) throws Error {
            app_entry(entry.id);
            app_folder(folder_id);
            string old_parent = entry.parent_id;
            if (old_parent == "") old_parent = (yield stat(entry.id, cancellable)).parent_id;
            var meta = new Json.Object();
            if (new_name != null) meta.set_string_member("name", new_name);
            string url = api + "files/" + esc(entry.id) + "?addParents=" + esc(folder_id) + "&fields=" + esc(FIELDS);
            if (old_parent != "" && old_parent != folder_id) url += "&removeParents=" + esc(old_parent);
            var response = yield http.send_ok("PATCH", url, "application/json", json_bytes(meta), null, cancellable);
            var moved = entry_of(response.json_object());
            if (moved.parent_id == "" || moved.parent_id == old_parent) moved.parent_id = folder_id;
            return moved;
        }

        public async CloudQuota? quota(Cancellable? cancellable = null) throws Error {
            var response = yield http.send_ok("GET", api + "about?fields=" + esc("storageQuota"), null, null, null, cancellable);
            var root = response.json_object();
            if (!root.has_member("storageQuota")) return null;
            var sq = root.get_object_member("storageQuota");
            var q = new CloudQuota();
            q.used = sq.has_member("usage") ? int64.parse(sq.get_string_member("usage")) : 0;
            q.total = sq.has_member("limit") ? int64.parse(sq.get_string_member("limit")) : -1;
            return q;
        }

        public async void delete(CloudEntry entry, Cancellable? cancellable = null) throws Error {
            app_entry(entry.id);
            var response = yield http.send("DELETE", api + "files/" + esc(entry.id), null, null, null, cancellable);
            if (response.status == 404) return;
            HttpClient.check(response, "DELETE");
        }

        public async CloudEntry create_folder(string parent_id, string name, Cancellable? cancellable = null) throws Error {
            app_folder(parent_id);
            var meta = new Json.Object();
            meta.set_string_member("name", name);
            meta.set_string_member("mimeType", FOLDER_TYPE);
            var parents = new Json.Array();
            parents.add_string_element(parent_id);
            meta.set_array_member("parents", parents);
            var response = yield http.send_ok("POST", api + "files?fields=" + esc(FIELDS), "application/json", json_bytes(meta), null, cancellable);
            var created = entry_of(response.json_object());
            if (app_data_only) {
                if (!created.is_folder) throw new AccountsError.PROTOCOL(_("The server did not create a directory"));
                app_entries.add(created.id);
                app_folders.add(created.id);
            }
            return created;
        }
    }

    /**
     * OneDrive through Microsoft Graph; ids are drive item ids and "root" is the top.
     */
    public class OneDrive : Object, CloudDrive {
        private Account _account;
        private HttpClient http;
        private string api;
        private bool app_data_only = false;
        private string app_root = "approot";
        private Gee.HashSet<string> app_folders = new Gee.HashSet<string>();
        private Gee.HashSet<string> app_entries = new Gee.HashSet<string>();

        public Account account { get { return _account; } }
        public string root_id { get { return app_data_only ? app_root : "root"; } }

        public OneDrive(Account account, HttpClient http, string api) {
            _account = account;
            this.http = http;
            this.api = api.has_suffix("/") ? api : api + "/";
        }

        public OneDrive.app_data(Account account, HttpClient http, string api) {
            this(account, http, api);
            app_data_only = true;
        }

        internal async void initialize_app_data(Cancellable? cancellable) throws Error {
            var response = yield http.send_ok("GET", api + "me/drive/special/approot", null, null, null, cancellable);
            var object = response.json_object();
            app_root = CloudDrive.page_string(object, "id", true);
            if (app_root == "root" || !object.has_member("folder") || object.get_member("folder").get_node_type() != Json.NodeType.OBJECT)
                throw new AccountsError.PROTOCOL(_("The account did not return an application folder"));
            app_folders.add(app_root);
        }

        private void app_entry(string id) throws Error {
            if (app_data_only && !app_entries.contains(id)) throw new AccountsError.INVALID(_("The file is outside the discovered application data"));
        }

        private static string esc(string s) {
            return Uri.escape_string(s, null, false);
        }

        private string item(string id) {
            return id == "root" ? api + "me/drive/root" : api + "me/drive/items/" + esc(id);
        }

        private CloudEntry entry_of(Json.Object o) throws Error {
            if (app_data_only) {
                string id = CloudDrive.page_string(o, "id", true);
                CloudDrive.page_string(o, "name");
                CloudDrive.page_string(o, "eTag");
                CloudDrive.page_string(o, "lastModifiedDateTime");
                foreach (string member in new string[] { "folder", "file", "parentReference" }) {
                    if (o.has_member(member) && o.get_member(member).get_node_type() != Json.NodeType.OBJECT)
                        throw new AccountsError.PROTOCOL(_("The server returned invalid file metadata"));
                }
                if (o.has_member("file")) CloudDrive.page_string(o.get_object_member("file"), "mimeType");
                if (o.has_member("parentReference")) CloudDrive.page_string(o.get_object_member("parentReference"), "id");
                if (o.has_member("parentReference")) {
                    string parent = CloudDrive.page_string(o.get_object_member("parentReference"), "id", true);
                    if (!app_folders.contains(parent)) throw new AccountsError.PROTOCOL(_("The server returned a file outside application data"));
                }
                if (o.has_member("size") && (o.get_member("size").get_node_type() != Json.NodeType.VALUE || o.get_member("size").get_value().type() != typeof(int64)))
                    throw new AccountsError.PROTOCOL(_("The server returned an invalid file size"));
                if (o.has_member("size") && o.get_int_member("size") < 0) throw new AccountsError.PROTOCOL(_("The server returned an invalid file size"));
                if (id == "root" || id == app_root) throw new AccountsError.PROTOCOL(_("The server returned a file outside application data"));
            }
            var e = new CloudEntry();
            e.id = o.get_string_member("id");
            e.name = o.has_member("name") ? o.get_string_member("name") : e.id;
            e.is_folder = o.has_member("folder");
            if (o.has_member("file")) {
                var f = o.get_object_member("file");
                if (f.has_member("mimeType")) e.content_type = f.get_string_member("mimeType");
            }
            if (e.is_folder) e.content_type = "inode/directory";
            else if (e.content_type == "") e.content_type = CloudDrive.guess_type(e.name);
            if (o.has_member("size")) e.size = o.get_int_member("size");
            if (o.has_member("lastModifiedDateTime")) e.modified = new DateTime.from_iso8601(o.get_string_member("lastModifiedDateTime"), null);
            if (o.has_member("eTag")) e.etag = o.get_string_member("eTag");
            if (o.has_member("parentReference")) {
                var p = o.get_object_member("parentReference");
                if (p.has_member("id")) e.parent_id = p.get_string_member("id");
            }
            return e;
        }

        public async Gee.List<CloudEntry> list(string folder_id, Cancellable? cancellable = null) throws Error {
            if (app_data_only) return yield list_app_data(folder_id, cancellable);
            var result = new Gee.ArrayList<CloudEntry>();
            string? next = item(folder_id) + "/children?$top=200";
            for (int n = 0; n < 100 && next != null; n++) {
                var response = yield http.send_ok("GET", next, null, null, null, cancellable);
                var root = response.json_object();
                if (root.has_member("value")) {
                    foreach (var node in root.get_array_member("value").get_elements()) result.add(entry_of(node.get_object()));
                }
                next = root.has_member("@odata.nextLink") ? root.get_string_member("@odata.nextLink") : null;
            }
            return result;
        }

        private async Gee.List<CloudEntry> list_app_data(string folder_id, Cancellable? cancellable) throws Error {
            if (!app_folders.contains(folder_id)) throw new AccountsError.INVALID(_("The folder is outside application data"));
            string expected = item(folder_id) + "/children";
            string next = expected + "?$top=200";
            var pages = new Gee.HashSet<string>();
            var ids = new Gee.HashSet<string>();
            var result = new Gee.ArrayList<CloudEntry>();
            while (next != "") {
                if (!pages.add(next)) throw new AccountsError.PROTOCOL(_("The server repeated an application-data page"));
                var response = yield http.send_ok("GET", next, null, null, null, cancellable);
                var object = response.json_object();
                foreach (var node in CloudDrive.page_array(object, "value").get_elements()) {
                    if (node.get_node_type() != Json.NodeType.OBJECT) throw new AccountsError.PROTOCOL(_("The server returned an invalid file"));
                    var file = node.get_object();
                    string id = CloudDrive.page_string(file, "id", true);
                    if (!ids.add(id) || id == "root" || id == app_root) throw new AccountsError.PROTOCOL(_("The server repeated an application-data file"));
                    var entry = entry_of(file);
                    entry.parent_id = folder_id;
                    result.add(entry);
                }
                string link = CloudDrive.page_string(object, "@odata.nextLink");
                next = link != "" ? CloudDrive.next_page(expected, link) : "";
            }
            if (cancellable != null) cancellable.set_error_if_cancelled();
            foreach (var entry in result) {
                app_entries.add(entry.id);
                if (entry.is_folder) app_folders.add(entry.id);
            }
            return result;
        }

        public async CloudEntry stat(string id, Cancellable? cancellable = null) throws Error {
            app_entry(id);
            var response = yield http.send_ok("GET", item(id), null, null, null, cancellable);
            return entry_of(response.json_object());
        }

        public async void download_to(CloudEntry entry, OutputStream output, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            app_entry(entry.id);
            yield http.receive("GET", item(entry.id) + "/content", output, null, entry.size, progress, cancellable);
        }

        public async void download(CloudEntry entry, File destination, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            yield CloudDrive.save_to_file(this, entry, destination, cancellable, progress);
        }

        public async CloudEntry upload(string folder_id, string name, File source, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            if (app_data_only && !app_folders.contains(folder_id)) throw new AccountsError.INVALID(_("The folder is outside application data"));
            var uploaded = yield send_content(item(folder_id) + ":/" + esc(name) + ":", CloudDrive.guess_type(name), source, cancellable, progress);
            if (app_data_only) app_entries.add(uploaded.id);
            return uploaded;
        }

        public async CloudEntry replace(CloudEntry entry, File source, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            app_entry(entry.id);
            return yield send_content(item(entry.id), entry.content_type != "" ? entry.content_type : CloudDrive.guess_type(entry.name), source, cancellable, progress);
        }

        private static Bytes json_bytes(Json.Object o) {
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(o);
            var gen = new Json.Generator();
            gen.set_root(node);
            return new Bytes(gen.to_data(null).data);
        }

        private async CloudEntry send_content(string target, string content_type, File source, Cancellable? cancellable, TransferProgress? progress) throws Error {
            int64 size = yield CloudDrive.size_of(source, cancellable);
            if (size <= CLOUD_SIMPLE_UPLOAD_LIMIT) {
                var simple = yield http.send_file("PUT", target + "/content", content_type, new UploadSource(source, 0, size), null, true, progress, cancellable);
                HttpClient.check(simple, "PUT");
                return entry_of(simple.json_object());
            }
            var conflict = new Json.Object();
            conflict.set_string_member("@microsoft.graph.conflictBehavior", "replace");
            var request = new Json.Object();
            request.set_object_member("item", conflict);
            var created = yield http.send_ok("POST", target + "/createUploadSession", "application/json", json_bytes(request), null, cancellable);
            var info = created.json_object();
            if (!info.has_member("uploadUrl")) throw new AccountsError.PROTOCOL(_("The server did not start the upload"));
            string session = info.get_string_member("uploadUrl");
            try {
                int64 offset = 0;
                if (progress != null) progress(0, size);
                while (true) {
                    int64 n = int64.min(CLOUD_CHUNK_SIZE, size - offset);
                    int64 base_offset = offset;
                    var response = yield http.send_file("PUT", session, "application/octet-stream", new UploadSource(source, offset, n),
                        CloudDrive.headers("Content-Range", "bytes %lld-%lld/%lld".printf(offset, offset + n - 1, size)), false,
                        (done, total) => {
                            if (progress != null) progress(base_offset + done, size);
                        }, cancellable);
                    if (response.status == 202) {
                        offset += n;
                        if (offset >= size) throw new AccountsError.PROTOCOL(_("The server did not finish the upload"));
                        continue;
                    }
                    HttpClient.check(response, "PUT");
                    return entry_of(response.json_object());
                }
            } catch (Error e) {
                try {
                    yield http.send("DELETE", session, null, null, null, null);
                } catch (Error ignored) {
                }
                throw e;
            }
        }

        public async CloudEntry rename(CloudEntry entry, string new_name, Cancellable? cancellable = null) throws Error {
            app_entry(entry.id);
            var meta = new Json.Object();
            meta.set_string_member("name", new_name);
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(meta);
            var gen = new Json.Generator();
            gen.set_root(node);
            var response = yield http.send_ok("PATCH", item(entry.id), "application/json", new Bytes(gen.to_data(null).data), null, cancellable);
            return entry_of(response.json_object());
        }

        public async CloudEntry move(CloudEntry entry, string folder_id, string? new_name = null, Cancellable? cancellable = null) throws Error {
            app_entry(entry.id);
            if (app_data_only && !app_folders.contains(folder_id)) throw new AccountsError.INVALID(_("The folder is outside application data"));
            string parent = folder_id == "root" ? (yield stat("root", cancellable)).id : folder_id;
            var reference = new Json.Object();
            reference.set_string_member("id", parent);
            var meta = new Json.Object();
            meta.set_object_member("parentReference", reference);
            if (new_name != null) meta.set_string_member("name", new_name);
            var response = yield http.send_ok("PATCH", item(entry.id), "application/json", json_bytes(meta), null, cancellable);
            var moved = entry_of(response.json_object());
            if (moved.parent_id == "") moved.parent_id = folder_id;
            return moved;
        }

        public async CloudQuota? quota(Cancellable? cancellable = null) throws Error {
            var response = yield http.send_ok("GET", api + "me/drive", null, null, null, cancellable);
            var root = response.json_object();
            if (!root.has_member("quota")) return null;
            var o = root.get_object_member("quota");
            var q = new CloudQuota();
            q.used = o.has_member("used") ? o.get_int_member("used") : 0;
            q.total = o.has_member("total") ? o.get_int_member("total") : -1;
            return q;
        }

        public async void delete(CloudEntry entry, Cancellable? cancellable = null) throws Error {
            app_entry(entry.id);
            var response = yield http.send("DELETE", item(entry.id), null, null, null, cancellable);
            if (response.status == 404) return;
            HttpClient.check(response, "DELETE");
        }

        public async CloudEntry create_folder(string parent_id, string name, Cancellable? cancellable = null) throws Error {
            if (app_data_only && !app_folders.contains(parent_id)) throw new AccountsError.INVALID(_("The folder is outside application data"));
            var meta = new Json.Object();
            meta.set_string_member("name", name);
            meta.set_object_member("folder", new Json.Object());
            meta.set_string_member("@microsoft.graph.conflictBehavior", "rename");
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(meta);
            var gen = new Json.Generator();
            gen.set_root(node);
            var response = yield http.send_ok("POST", item(parent_id) + "/children", "application/json", new Bytes(gen.to_data(null).data), null, cancellable);
            var created = entry_of(response.json_object());
            if (app_data_only) {
                if (!created.is_folder) throw new AccountsError.PROTOCOL(_("The server did not create a directory"));
                app_entries.add(created.id);
                app_folders.add(created.id);
            }
            return created;
        }
    }
}
