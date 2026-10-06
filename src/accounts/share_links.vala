namespace Singularity.Accounts {

    public enum LinkAccess {
        VIEW,
        EDIT;

        public string to_id() {
            return this == EDIT ? "edit" : "view";
        }

        public static LinkAccess from_id(string id) {
            return id == "edit" ? EDIT : VIEW;
        }

        public string label() {
            return this == EDIT ? _("Can Edit") : _("View Only");
        }
    }

    public class SharedLink : Object {
        public string account_id { get; construct; }
        public string entry_id { get; construct; }
        public string share_id { get; construct; }
        public string url { get; construct; }
        public LinkAccess access { get; construct; }
        public DateTime? expires { get; construct; }

        public SharedLink(string account_id, string entry_id, string share_id, string url, LinkAccess access, DateTime? expires) {
            Object(account_id: account_id, entry_id: entry_id, share_id: share_id, url: url, access: access, expires: expires);
        }
    }

    public interface LinkSharing : Object {
        public abstract Account account { get; }
        public abstract bool supports_expiry { get; }
        public abstract bool supports_edit { get; }

        public abstract async SharedLink create_link(CloudEntry entry, LinkAccess access, DateTime? expires = null, Cancellable? cancellable = null) throws Error;
        public abstract async void remove_link(SharedLink link, Cancellable? cancellable = null) throws Error;

        public static LinkSharing? for_account(Account account) {
            if (!account.has_capability(Capability.FILES)) return null;
            var http = new HttpClient(account, Capability.FILES);
            switch (account.get_endpoint("files-api") ?? "") {
                case "google-drive":
                    return new GoogleDriveLinks(account, http, account.get_endpoint("google-drive") ?? "https://www.googleapis.com/drive/v3/");
                case "onedrive":
                    return new OneDriveLinks(account, http, account.get_endpoint("graph") ?? "https://graph.microsoft.com/v1.0/");
                case "webdav":
                    if (account.provider != "nextcloud" && account.provider != "owncloud") return null;
                    string? root = account.get_endpoint("webdav");
                    if (root == null || account.server == "") return null;
                    return new OcsLinks(account, http, account.server, root);
                default:
                    return null;
            }
        }

        internal static Bytes json_bytes(Json.Builder b) {
            var gen = new Json.Generator();
            gen.set_root(b.get_root());
            return new Bytes(gen.to_data(null).data);
        }
    }

    public class GoogleDriveLinks : Object, LinkSharing {
        private Account _account;
        private HttpClient http;
        private string api;

        public Account account { get { return _account; } }
        public bool supports_expiry { get { return false; } }
        public bool supports_edit { get { return true; } }

        public GoogleDriveLinks(Account account, HttpClient http, string api) {
            _account = account;
            this.http = http;
            this.api = api.has_suffix("/") ? api : api + "/";
        }

        private static string esc(string s) {
            return Uri.escape_string(s, null, false);
        }

        public async SharedLink create_link(CloudEntry entry, LinkAccess access, DateTime? expires = null, Cancellable? cancellable = null) throws Error {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("role").add_string_value(access == LinkAccess.EDIT ? "writer" : "reader");
            b.set_member_name("type").add_string_value("anyone");
            b.set_member_name("allowFileDiscovery").add_boolean_value(false);
            b.end_object();
            var created = yield http.send_ok("POST", api + "files/" + esc(entry.id) + "/permissions?fields=id,role,type",
                "application/json", LinkSharing.json_bytes(b), null, cancellable);
            string permission = created.json_object().get_string_member("id");
            var file = yield http.send_ok("GET", api + "files/" + esc(entry.id) + "?fields=" + esc("id,webViewLink"), null, null, null, cancellable);
            var o = file.json_object();
            if (!o.has_member("webViewLink")) throw new AccountsError.PROTOCOL(_("The server did not return a link"));
            return new SharedLink(account.id, entry.id, permission, o.get_string_member("webViewLink"), access, null);
        }

        public async void remove_link(SharedLink link, Cancellable? cancellable = null) throws Error {
            var response = yield http.send("DELETE", api + "files/" + esc(link.entry_id) + "/permissions/" + esc(link.share_id), null, null, null, cancellable);
            if (response.status == 404) return;
            HttpClient.check(response, "DELETE");
        }
    }

    public class OneDriveLinks : Object, LinkSharing {
        private Account _account;
        private HttpClient http;
        private string api;

        public Account account { get { return _account; } }
        public bool supports_expiry { get { return true; } }
        public bool supports_edit { get { return true; } }

        public OneDriveLinks(Account account, HttpClient http, string api) {
            _account = account;
            this.http = http;
            this.api = api.has_suffix("/") ? api : api + "/";
        }

        private string item(string id) {
            return id == "root" ? api + "me/drive/root" : api + "me/drive/items/" + Uri.escape_string(id, null, false);
        }

        public async SharedLink create_link(CloudEntry entry, LinkAccess access, DateTime? expires = null, Cancellable? cancellable = null) throws Error {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("type").add_string_value(access == LinkAccess.EDIT ? "edit" : "view");
            b.set_member_name("scope").add_string_value("anonymous");
            if (expires != null) b.set_member_name("expirationDateTime").add_string_value(expires.to_utc().format("%Y-%m-%dT%H:%M:%SZ"));
            b.end_object();
            var response = yield http.send_ok("POST", item(entry.id) + "/createLink", "application/json", LinkSharing.json_bytes(b), null, cancellable);
            var o = response.json_object();
            if (!o.has_member("link") || !o.get_object_member("link").has_member("webUrl")) {
                throw new AccountsError.PROTOCOL(_("The server did not return a link"));
            }
            DateTime? until = null;
            if (o.has_member("expirationDateTime")) until = new DateTime.from_iso8601(o.get_string_member("expirationDateTime"), new TimeZone.utc());
            return new SharedLink(account.id, entry.id, o.get_string_member("id"), o.get_object_member("link").get_string_member("webUrl"), access, until);
        }

        public async void remove_link(SharedLink link, Cancellable? cancellable = null) throws Error {
            var response = yield http.send("DELETE", item(link.entry_id) + "/permissions/" + Uri.escape_string(link.share_id, null, false), null, null, null, cancellable);
            if (response.status == 404) return;
            HttpClient.check(response, "DELETE");
        }
    }

    public class OcsLinks : Object, LinkSharing {
        private Account _account;
        private HttpClient http;
        private string server;
        private string root_path;

        public Account account { get { return _account; } }
        public bool supports_expiry { get { return true; } }
        public bool supports_edit { get { return true; } }

        public OcsLinks(Account account, HttpClient http, string server, string webdav_root) {
            _account = account;
            this.http = http;
            this.server = server.has_suffix("/") ? server.substring(0, server.length - 1) : server;
            string root = webdav_root.has_suffix("/") ? webdav_root : webdav_root + "/";
            root_path = DavRemoteCollection.key_of(root, root);
        }

        public string path_of(string entry_id) {
            string path = entry_id.has_prefix(root_path) ? entry_id.substring(root_path.length) : entry_id;
            while (path.has_prefix("/")) path = path.substring(1);
            if (path.has_suffix("/")) path = path.substring(0, path.length - 1);
            return "/" + path;
        }

        private HashTable<string, string> headers() {
            var h = new HashTable<string, string>(str_hash, str_equal);
            h.insert("OCS-APIRequest", "true");
            h.insert("Accept", "application/json");
            return h;
        }

        private static Json.Object ocs_data(HttpResponse response, string what) throws Error {
            Json.Object root;
            try {
                root = response.json_object();
            } catch (Error e) {
                HttpClient.check(response, what);
                throw e;
            }
            var ocs = root.has_member("ocs") ? root.get_object_member("ocs") : null;
            if (ocs == null) throw new AccountsError.PROTOCOL(_("The server sent an unexpected answer"));
            var meta = ocs.get_object_member("meta");
            int64 code = meta != null && meta.has_member("statuscode") ? meta.get_int_member("statuscode") : 0;
            if (code != 100 && code != 200) {
                string message = meta != null && meta.has_member("message") && !meta.get_null_member("message") ? meta.get_string_member("message") : "";
                if (code == 404) throw new AccountsError.NOT_FOUND(message != "" ? message : _("%s: not found on the server").printf(what));
                if (code == 403 || code == 997) throw new AccountsError.AUTH_FAILED(message != "" ? message : _("%s: the server does not allow this").printf(what));
                throw new AccountsError.PROTOCOL(message != "" ? message : _("%s failed with HTTP %u").printf(what, response.status));
            }
            var data = ocs.get_member("data");
            if (data == null || data.get_node_type() != Json.NodeType.OBJECT) return new Json.Object();
            return data.get_object();
        }

        private static string form(string key, string value) {
            return Uri.escape_string(key, null, false) + "=" + Uri.escape_string(value, null, false);
        }

        public async SharedLink create_link(CloudEntry entry, LinkAccess access, DateTime? expires = null, Cancellable? cancellable = null) throws Error {
            string[] fields = {
                form("path", path_of(entry.id)),
                form("shareType", "3"),
                form("permissions", access == LinkAccess.EDIT ? (entry.is_folder ? "15" : "3") : "1")
            };
            if (expires != null) fields += form("expireDate", expires.format("%Y-%m-%d"));
            var response = yield http.send("POST", server + "/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json",
                "application/x-www-form-urlencoded", new Bytes(string.joinv("&", fields).data), headers(), cancellable);
            var data = ocs_data(response, "POST");
            if (!data.has_member("url")) throw new AccountsError.PROTOCOL(_("The server did not return a link"));
            string id = data.get_member("id").get_value_type() == typeof(string) ? data.get_string_member("id") : data.get_int_member("id").to_string();
            DateTime? until = null;
            if (data.has_member("expiration") && !data.get_null_member("expiration")) {
                string text = data.get_string_member("expiration");
                if (text.length >= 10) {
                    var parts = text.substring(0, 10).split("-");
                    if (parts.length == 3) until = new DateTime.local(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]), 0, 0, 0);
                }
            }
            return new SharedLink(account.id, entry.id, id, data.get_string_member("url"), access, until);
        }

        public async void remove_link(SharedLink link, Cancellable? cancellable = null) throws Error {
            var response = yield http.send("DELETE", server + "/ocs/v2.php/apps/files_sharing/api/v1/shares/" + Uri.escape_string(link.share_id, null, false) + "?format=json",
                null, null, headers(), cancellable);
            if (response.status == 404) return;
            ocs_data(response, "DELETE");
        }
    }
}
