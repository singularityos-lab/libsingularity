namespace Singularity.Accounts {

    public class SintyCloudDrive : Object, CloudDrive {
        private Account _account;
        private HttpClient http;
        private string base_url;

        public Account account { get { return _account; } }
        public string root_id { get { return "/"; } }

        public SintyCloudDrive(Account account, HttpClient http, string base_url) {
            _account = account;
            this.http = http;
            this.base_url = base_url.has_suffix("/") ? base_url.substring(0, base_url.length - 1) : base_url;
        }

        internal static string normalize(string id) throws Error {
            string[] parts = {};
            foreach (string part in id.split("/")) {
                if (part == "" || part == ".") continue;
                if (part == ".." || part.contains("\\") || part.contains("\r") || part.contains("\n"))
                    throw new AccountsError.INVALID(_("Invalid path %s").printf(id));
                parts += part;
            }
            return "/" + string.joinv("/", parts);
        }

        internal static string parent_of(string id) {
            int slash = id.last_index_of("/");
            return slash > 0 ? id.substring(0, slash) : "/";
        }

        internal static string child_of(string folder, string name) throws Error {
            if (name == "" || name.contains("/")) throw new AccountsError.INVALID(_("Invalid name %s").printf(name));
            return normalize(folder + "/" + name);
        }

        private string url_of(string api, string id) throws Error {
            string[] segs = {};
            foreach (string seg in normalize(id).substring(1).split("/")) segs += Uri.escape_string(seg, null, false);
            return "%s/api/v1/%s/%s".printf(base_url, api, string.joinv("/", segs));
        }

        internal static CloudEntry entry_of(Json.Object o, string id) throws Error {
            var e = new CloudEntry();
            e.id = id;
            e.parent_id = id == "/" ? "" : parent_of(id);
            e.name = id == "/" ? "" : id.substring(id.last_index_of("/") + 1);
            e.is_folder = o.has_member("dir") && o.get_boolean_member("dir");
            e.size = e.is_folder ? -1 : (o.has_member("size") ? o.get_int_member("size") : -1);
            string modified = CloudDrive.page_string(o, "modified");
            if (modified != "") e.modified = new DateTime.from_iso8601(modified, new TimeZone.utc());
            e.etag = CloudDrive.page_string(o, "etag");
            if (!e.is_folder) {
                if (e.etag != "") CloudDrive.require_strong_etag(e.etag);
                e.content_type = CloudDrive.guess_type(e.name);
            }
            return e;
        }

        public async Gee.List<CloudEntry> list(string folder_id, Cancellable? cancellable = null) throws Error {
            string folder = normalize(folder_id);
            var response = yield http.send_ok("GET", url_of("files", folder), null, null, null, cancellable);
            var o = response.json_object();
            var result = new Gee.ArrayList<CloudEntry>();
            foreach (var node in CloudDrive.page_array(o, "entries").get_elements()) {
                if (node.get_node_type() != Json.NodeType.OBJECT) throw new AccountsError.PROTOCOL(_("The server sent an invalid folder listing"));
                var item = node.get_object();
                result.add(entry_of(item, child_of(folder, CloudDrive.page_string(item, "name", true))));
            }
            return result;
        }

        public async CloudEntry stat(string id, Cancellable? cancellable = null) throws Error {
            string path = normalize(id);
            var response = yield http.send_ok("GET", url_of("info", path), null, null, null, cancellable);
            return entry_of(response.json_object(), path);
        }

        public async void download_to(CloudEntry entry, OutputStream output, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            if (entry.is_folder) throw new IOError.IS_DIRECTORY(_("%s is a folder").printf(entry.name));
            var response = yield http.receive("GET", url_of("files", entry.id), output, null, entry.size, progress, cancellable);
            HttpClient.check(response, "Download");
        }

        public async void download(CloudEntry entry, File destination, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            yield CloudDrive.save_to_file(this, entry, destination, cancellable, progress);
        }

        private async CloudEntry put(string id, File source, string? expected_etag, Cancellable? cancellable, TransferProgress? progress) throws Error {
            int64 size = yield CloudDrive.size_of(source, cancellable);
            var headers = expected_etag != null ? CloudDrive.headers("If-Match", expected_etag) : null;
            var response = yield http.send_file("PUT", url_of("files", id), "application/octet-stream", new UploadSource(source, 0, size),
                headers, true, progress, cancellable);
            HttpClient.check(response, expected_etag != null ? "Conditional replacement" : "Upload");
            var entry = entry_of(response.json_object(), normalize(id));
            if (entry.etag == "") throw new AccountsError.PROTOCOL(_("The server did not acknowledge the upload with an entity tag"));
            return entry;
        }

        public async CloudEntry upload(string folder_id, string name, File source, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            return yield put(child_of(folder_id, name), source, null, cancellable, progress);
        }

        public async CloudEntry replace(CloudEntry entry, File source, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            if (entry.is_folder) throw new IOError.INVALID_ARGUMENT(_("A directory cannot be replaced with a file"));
            return yield put(entry.id, source, null, cancellable, progress);
        }

        public async CloudEntry replace_if_match(CloudEntry entry, File source, string expected_etag, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            CloudDrive.require_strong_etag(expected_etag);
            if (entry.is_folder) throw new IOError.INVALID_ARGUMENT(_("A directory cannot be replaced with a file"));
            return yield put(entry.id, source, expected_etag, cancellable, progress);
        }

        private async CloudEntry move_to(CloudEntry entry, string target, Cancellable? cancellable) throws Error {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("from").add_string_value(normalize(entry.id));
            b.set_member_name("to").add_string_value(target);
            b.end_object();
            var gen = new Json.Generator();
            gen.set_root(b.get_root());
            yield http.send_ok("POST", base_url + "/api/v1/move", "application/json", new Bytes(gen.to_data(null).data), null, cancellable);
            return yield stat(target, cancellable);
        }

        public async CloudEntry rename(CloudEntry entry, string new_name, Cancellable? cancellable = null) throws Error {
            return yield move_to(entry, child_of(parent_of(normalize(entry.id)), new_name), cancellable);
        }

        public async CloudEntry move(CloudEntry entry, string folder_id, string? new_name = null, Cancellable? cancellable = null) throws Error {
            return yield move_to(entry, child_of(folder_id, new_name ?? entry.name), cancellable);
        }

        public async void delete(CloudEntry entry, Cancellable? cancellable = null) throws Error {
            if (normalize(entry.id) == "/") throw new AccountsError.INVALID(_("The top folder cannot be deleted"));
            yield http.send_ok("DELETE", url_of("files", entry.id), null, null, null, cancellable);
        }

        public async CloudEntry create_folder(string parent_id, string name, Cancellable? cancellable = null) throws Error {
            string id = child_of(parent_id, name);
            yield http.send_ok("POST", url_of("folders", id), null, null, null, cancellable);
            return yield stat(id, cancellable);
        }

        public async CloudQuota? quota(Cancellable? cancellable = null) throws Error {
            var response = yield http.send_ok("GET", base_url + "/api/v1/me", null, null, null, cancellable);
            var o = response.json_object();
            var q = new CloudQuota();
            q.used = o.has_member("used") ? o.get_int_member("used") : 0;
            q.total = o.has_member("quota") && o.get_int_member("quota") > 0 ? o.get_int_member("quota") : -1;
            return q;
        }
    }
}
