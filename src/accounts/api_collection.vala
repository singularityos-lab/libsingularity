namespace Singularity.Accounts {

    /**
     * The JSON web APIs a collection can live behind.
     */
    public enum ApiKind {
        /** Microsoft Graph calendar events. */
        GRAPH_EVENTS,
        /** Microsoft Graph personal contacts. */
        GRAPH_CONTACTS,
        /** Microsoft To Do tasks. */
        GRAPH_TODO,
        /** Google Tasks. */
        GOOGLE_TASKS;

        public string to_id() {
            switch (this) {
                case GRAPH_EVENTS: return "graph-events";
                case GRAPH_CONTACTS: return "graph-contacts";
                case GRAPH_TODO: return "graph-todo";
                default: return "google-tasks";
            }
        }

        public static bool try_parse(string id, out ApiKind result) {
            switch (id) {
                case "graph-events": result = GRAPH_EVENTS; return true;
                case "graph-contacts": result = GRAPH_CONTACTS; return true;
                case "graph-todo": result = GRAPH_TODO; return true;
                case "google-tasks": result = GOOGLE_TASKS; return true;
                default: result = GOOGLE_TASKS; return false;
            }
        }

        public bool is_graph() {
            return this != GOOGLE_TASKS;
        }
    }

    /**
     * A calendar, contact folder or task list behind Microsoft Graph or
     * Google Tasks, exposed as iCalendar or vCard items through Converters.
     */
    public class ApiRemoteCollection : Object, RemoteCollection {
        private HttpClient http;
        private string base_url;
        private string remote_id;
        private string _name;
        private string _color;
        private bool _read_only;
        private ApiKind api;
        private string _id;
        private Gee.HashMap<string, Json.Object> listed = new Gee.HashMap<string, Json.Object>();

        public string id { get { return _id; } }
        public string name { get { return _name; } }
        public string color { get { return _color; } }
        public bool read_only { get { return _read_only; } }

        /**
         * @param http      Client of the account capability.
         * @param base_url  API root such as https://graph.microsoft.com/v1.0/ or https://tasks.googleapis.com/tasks/v1/.
         * @param remote_id Calendar, list or folder id ("contacts" for the default contact folder).
         */
        public ApiRemoteCollection(HttpClient http, string base_url, ApiKind api, string remote_id, string name, string color, bool read_only) {
            this.http = http;
            this.base_url = base_url.has_suffix("/") ? base_url : base_url + "/";
            this.api = api;
            this.remote_id = remote_id;
            this._id = api.to_id() + ":" + remote_id;
            this._name = name;
            this._color = color;
            this._read_only = read_only;
        }

        public Json.Object to_descriptor() {
            var o = new Json.Object();
            o.set_string_member("type", api.to_id());
            o.set_string_member("base", base_url);
            o.set_string_member("remote-id", remote_id);
            o.set_string_member("name", _name);
            o.set_string_member("color", _color);
            o.set_boolean_member("read-only", _read_only);
            return o;
        }

        private static string esc(string s) {
            return Uri.escape_string(s, null, false);
        }

        private string list_url() {
            switch (api) {
                case ApiKind.GRAPH_EVENTS: return base_url + "me/calendars/" + esc(remote_id) + "/events?$top=100";
                case ApiKind.GRAPH_CONTACTS:
                    return remote_id == "contacts" ? base_url + "me/contacts?$top=100" : base_url + "me/contactFolders/" + esc(remote_id) + "/contacts?$top=100";
                case ApiKind.GRAPH_TODO: return base_url + "me/todo/lists/" + esc(remote_id) + "/tasks?$top=100";
                default: return base_url + "lists/" + esc(remote_id) + "/tasks?showCompleted=true&showHidden=true&maxResults=100";
            }
        }

        private string create_url() {
            switch (api) {
                case ApiKind.GRAPH_EVENTS: return base_url + "me/calendars/" + esc(remote_id) + "/events";
                case ApiKind.GRAPH_CONTACTS:
                    return remote_id == "contacts" ? base_url + "me/contacts" : base_url + "me/contactFolders/" + esc(remote_id) + "/contacts";
                case ApiKind.GRAPH_TODO: return base_url + "me/todo/lists/" + esc(remote_id) + "/tasks";
                default: return base_url + "lists/" + esc(remote_id) + "/tasks";
            }
        }

        private string item_url(string item) {
            switch (api) {
                case ApiKind.GRAPH_EVENTS: return base_url + "me/events/" + esc(item);
                case ApiKind.GRAPH_CONTACTS: return base_url + "me/contacts/" + esc(item);
                case ApiKind.GRAPH_TODO: return base_url + "me/todo/lists/" + esc(remote_id) + "/tasks/" + esc(item);
                default: return base_url + "lists/" + esc(remote_id) + "/tasks/" + esc(item);
            }
        }

        private static string str(Json.Object o, string name) {
            if (!o.has_member(name)) return "";
            var n = o.get_member(name);
            return n.get_node_type() == Json.NodeType.VALUE && n.get_value().type() == typeof(string) ? n.get_string() : "";
        }

        private string etag_of(Json.Object o) {
            if (api.is_graph()) {
                string e = str(o, "@odata.etag");
                return e != "" ? e : str(o, "changeKey");
            }
            return str(o, "etag");
        }

        private string to_text(Json.Object o) {
            switch (api) {
                case ApiKind.GRAPH_EVENTS: return Converters.graph_event_to_ical(o);
                case ApiKind.GRAPH_CONTACTS: return Converters.graph_contact_to_vcard(o);
                case ApiKind.GRAPH_TODO: return Converters.graph_todo_to_ical(o);
                default: return Converters.google_task_to_ical(o);
            }
        }

        private Json.Object from_text(string data) throws Error {
            switch (api) {
                case ApiKind.GRAPH_EVENTS: return Converters.ical_event_to_graph(data);
                case ApiKind.GRAPH_CONTACTS: return Converters.vcard_to_graph_contact(data);
                case ApiKind.GRAPH_TODO: return Converters.ical_todo_to_graph(data);
                default: return Converters.ical_todo_to_google(data);
            }
        }

        private HashTable<string, string> headers(string? if_match) {
            var h = new HashTable<string, string>(str_hash, str_equal);
            if (api.is_graph()) h.insert("Prefer", "outlook.timezone=\"UTC\"");
            if (if_match != null && if_match != "") h.insert("If-Match", if_match);
            return h;
        }

        private static Bytes json_bytes(Json.Object o) {
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(o);
            var gen = new Json.Generator();
            gen.set_root(node);
            return new Bytes(gen.to_data(null).data);
        }

        public async string get_tag(Cancellable? cancellable = null) throws Error {
            return "";
        }

        public async Gee.Map<string, string> list_index(Cancellable? cancellable = null) throws Error {
            var index = new Gee.HashMap<string, string>();
            listed.clear();
            string? next = list_url();
            int pages = 0;
            while (next != null && pages++ < 200) {
                var response = yield http.send_ok("GET", next, null, null, headers(null), cancellable);
                var root = response.json_object();
                string array_name = api.is_graph() ? "value" : "items";
                if (root.has_member(array_name) && root.get_member(array_name).get_node_type() == Json.NodeType.ARRAY) {
                    foreach (var node in root.get_array_member(array_name).get_elements()) {
                        if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                        var o = node.get_object();
                        string item = str(o, "id");
                        if (item == "") continue;
                        if (!api.is_graph() && o.has_member("deleted") && o.get_boolean_member("deleted")) continue;
                        index[item] = etag_of(o);
                        listed[item] = o;
                    }
                }
                next = null;
                if (api.is_graph()) {
                    string link = str(root, "@odata.nextLink");
                    if (link != "") next = link;
                } else {
                    string token = str(root, "nextPageToken");
                    if (token != "") next = list_url() + "&pageToken=" + esc(token);
                }
            }
            return index;
        }

        public async Gee.List<RemoteItem> fetch(Gee.Collection<string> hrefs, Cancellable? cancellable = null) throws Error {
            var result = new Gee.ArrayList<RemoteItem>();
            foreach (string item in hrefs) {
                Json.Object? o = listed[item];
                if (o == null) {
                    var response = yield http.send("GET", item_url(item), null, null, headers(null), cancellable);
                    if (response.status == 404 || response.status == 410) continue;
                    HttpClient.check(response, "GET");
                    o = response.json_object();
                }
                result.add(new RemoteItem(item, etag_of(o), to_text(o)));
            }
            return result;
        }

        public async RemoteItem create(string uid, string data, Cancellable? cancellable = null) throws Error {
            var body = from_text(data);
            var response = yield http.send_ok("POST", create_url(), "application/json", json_bytes(body), headers(null), cancellable);
            var o = response.json_object();
            listed[str(o, "id")] = o;
            return new RemoteItem(str(o, "id"), etag_of(o), to_text(o));
        }

        public async RemoteItem update(string href, string etag, string data, Cancellable? cancellable = null) throws Error {
            var body = from_text(data);
            var response = yield http.send_ok("PATCH", item_url(href), "application/json", json_bytes(body), headers(etag), cancellable);
            var o = response.json_object();
            listed[href] = o;
            return new RemoteItem(href, etag_of(o), to_text(o));
        }

        public async void remove(string href, string etag, Cancellable? cancellable = null) throws Error {
            var response = yield http.send("DELETE", item_url(href), null, null, headers(etag), cancellable);
            if (response.status == 404 || response.status == 410) return;
            HttpClient.check(response, "DELETE");
            listed.unset(href);
        }
    }
}
