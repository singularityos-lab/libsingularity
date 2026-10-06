namespace Singularity.Accounts {

    /**
     * Finds the calendars, task lists and address books of an account and
     * rebuilds them from their cached descriptors.
     */
    namespace Collections {

        private string endpoint_or(Account account, string key, string fallback) {
            string? v = account.get_endpoint(key);
            return v != null && v != "" ? v : fallback;
        }

        /** The API an account uses for a content kind: "caldav", "carddav", "graph", "google" or "". */
        public string api_for(Account account, ContentKind kind) {
            switch (kind) {
                case ContentKind.EVENTS: return endpoint_or(account, "calendar-api", account.get_endpoint("caldav") != null ? "caldav" : "");
                case ContentKind.TASKS: return endpoint_or(account, "tasks-api", account.get_endpoint("caldav") != null ? "caldav" : "");
                default: return endpoint_or(account, "contacts-api", account.get_endpoint("carddav") != null ? "carddav" : "");
            }
        }

        private string str(Json.Object o, string name) {
            if (!o.has_member(name)) return "";
            var n = o.get_member(name);
            return n.get_node_type() == Json.NodeType.VALUE && n.get_value().type() == typeof(string) ? n.get_string() : "";
        }

        private string page_string(Json.Object o, string name, bool required = false) throws AccountsError {
            if (!o.has_member(name)) {
                if (!required) return "";
                throw new AccountsError.PROTOCOL(_("The server response has no %s").printf(name));
            }
            var node = o.get_member(name);
            if (node.get_node_type() != Json.NodeType.VALUE || node.get_value().type() != typeof(string)) {
                throw new AccountsError.PROTOCOL(_("The server response has an invalid %s").printf(name));
            }
            string value = node.get_string();
            if (required && (value.strip() == "" || value != value.strip())) {
                throw new AccountsError.PROTOCOL(_("The server response has an invalid %s").printf(name));
            }
            return value;
        }

        private Json.Array page_array(Json.Object o, string name) throws AccountsError {
            if (!o.has_member(name) || o.get_member(name).get_node_type() != Json.NodeType.ARRAY) {
                throw new AccountsError.PROTOCOL(_("The server response has an invalid %s").printf(name));
            }
            return o.get_array_member(name);
        }

        private string next_graph_page(string url, string next) throws Error {
            var expected = Uri.parse(url, UriFlags.ENCODED);
            var actual = Uri.parse(next, UriFlags.ENCODED);
            if (HttpClient.origin_of(url) != HttpClient.origin_of(next) || actual.get_path() != expected.get_path()
                || actual.get_userinfo() != null || actual.get_fragment() != null) {
                throw new AccountsError.PROTOCOL(_("The next page is outside the account's collection address"));
            }
            return next;
        }

        public async RemoteCollection create(Account account, ContentKind kind, string name, Cancellable? cancellable = null) throws Error {
            string api = api_for(account, kind);
            if (kind != ContentKind.TASKS || (api != "google" && api != "graph")) {
                throw new AccountsError.INVALID(_("This account cannot create task lists"));
            }
            if (!account.has_capability(kind.capability()) || !account.healthy || name.strip() == "") {
                throw new AccountsError.INVALID(_("Choose a signed-in task account and a list name"));
            }
            string base_url = api == "google" ? endpoint_or(account, "google-tasks", "https://tasks.googleapis.com/tasks/v1/")
                : endpoint_or(account, "graph", "https://graph.microsoft.com/v1.0/");
            if (!base_url.has_suffix("/")) base_url += "/";
            var body = new Json.Object();
            body.set_string_member(api == "google" ? "title" : "displayName", name.strip());
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(body);
            var gen = new Json.Generator();
            gen.set_root(node);
            var http = new HttpClient(account, kind.capability());
            var response = yield http.send("POST", base_url + (api == "google" ? "users/@me/lists" : "me/todo/lists"),
                "application/json", new Bytes(gen.to_data(null).data), null, cancellable);
            if (response.status >= 400 && response.status < 500 && response.status != 403 && response.status != 404
                && response.status != 409 && response.status != 412) {
                throw new AccountsError.INVALID(_("The server rejected list creation with HTTP %u").printf(response.status));
            }
            HttpClient.check(response, "Create task list");
            var result = response.json_object();
            string id = page_string(result, "id", true);
            string title = page_string(result, api == "google" ? "title" : "displayName");
            return new ApiRemoteCollection(http, base_url, api == "google" ? ApiKind.GOOGLE_TASKS : ApiKind.GRAPH_TODO,
                id, title != "" ? title : name.strip(), "", false);
        }

        /**
         * Lists the collections of an account for a content kind. Calendars
         * that only hold events are skipped for tasks and the other way round.
         */
        public async Gee.List<RemoteCollection> discover(Account account, ContentKind kind, Cancellable? cancellable = null) throws Error {
            var result = new Gee.ArrayList<RemoteCollection>();
            var http = new HttpClient(account, kind.capability());
            string api = api_for(account, kind);
            switch (api) {
                case "caldav":
                case "carddav": {
                    bool books = kind == ContentKind.CONTACTS;
                    string? start = account.get_endpoint(books ? "carddav" : "caldav");
                    if (start == null) throw new AccountsError.INVALID(_("The account has no server address for this"));
                    var dav = new DavClient(http);
                    foreach (var info in yield dav.discover(start, books, cancellable)) {
                        if (!books && !(kind.component() in info.components)) continue;
                        result.add(new DavRemoteCollection(dav, info.url, info.name, info.color, info.read_only, kind));
                    }
                    break;
                }
                case "graph": {
                    string base_url = endpoint_or(account, "graph", "https://graph.microsoft.com/v1.0/");
                    if (!base_url.has_suffix("/")) base_url += "/";
                    if (kind == ContentKind.CONTACTS) {
                        result.add(new ApiRemoteCollection(http, base_url, ApiKind.GRAPH_CONTACTS, "contacts", _("Contacts"), "", false));
                        break;
                    }
                    string url = base_url + (kind == ContentKind.EVENTS ? "me/calendars" : "me/todo/lists");
                    string next = url;
                    var pages = new Gee.HashSet<string>();
                    var ids = new Gee.HashSet<string>();
                    while (next != "") {
                        if (!pages.add(next)) throw new AccountsError.PROTOCOL(_("The server repeated a collection page"));
                        var response = yield http.send_ok("GET", next, null, null, null, cancellable);
                        var root = response.json_object();
                        foreach (var node in page_array(root, "value").get_elements()) {
                            if (node.get_node_type() != Json.NodeType.OBJECT) throw new AccountsError.PROTOCOL(_("The server returned an invalid collection"));
                            var o = node.get_object();
                            string id = page_string(o, "id", true);
                            if (!ids.add(id)) throw new AccountsError.PROTOCOL(_("The server repeated a collection"));
                            if (kind == ContentKind.EVENTS) {
                                string color = page_string(o, "hexColor");
                                if (o.has_member("canEdit") && (o.get_member("canEdit").get_node_type() != Json.NodeType.VALUE
                                    || o.get_member("canEdit").get_value().type() != typeof(bool))) {
                                    throw new AccountsError.PROTOCOL(_("The server returned invalid collection permissions"));
                                }
                                bool can_edit = !o.has_member("canEdit") || o.get_boolean_member("canEdit");
                                result.add(new ApiRemoteCollection(http, base_url, ApiKind.GRAPH_EVENTS, id, page_string(o, "name", true), color, !can_edit));
                            } else {
                                result.add(new ApiRemoteCollection(http, base_url, ApiKind.GRAPH_TODO, id, page_string(o, "displayName", true), "", false));
                            }
                        }
                        string link = page_string(root, "@odata.nextLink");
                        next = link != "" ? next_graph_page(url, link) : "";
                    }
                    break;
                }
                case "ews": {
                    if (kind != ContentKind.EVENTS) break;
                    string? ews = account.get_endpoint("ews");
                    if (ews != null) result.add(new EwsRemoteCollection(http, ews, _("Calendar")));
                    break;
                }
                case "google": {
                    if (kind != ContentKind.TASKS) break;
                    string base_url = endpoint_or(account, "google-tasks", "https://tasks.googleapis.com/tasks/v1/");
                    if (!base_url.has_suffix("/")) base_url += "/";
                    string url = base_url + "users/@me/lists?maxResults=100";
                    string next = url;
                    var pages = new Gee.HashSet<string>();
                    var ids = new Gee.HashSet<string>();
                    while (next != "") {
                        if (!pages.add(next)) throw new AccountsError.PROTOCOL(_("The server repeated a collection page"));
                        var response = yield http.send_ok("GET", next, null, null, null, cancellable);
                        var root = response.json_object();
                        foreach (var node in page_array(root, "items").get_elements()) {
                            if (node.get_node_type() != Json.NodeType.OBJECT) throw new AccountsError.PROTOCOL(_("The server returned an invalid collection"));
                            var o = node.get_object();
                            string id = page_string(o, "id", true);
                            if (!ids.add(id)) throw new AccountsError.PROTOCOL(_("The server repeated a collection"));
                            result.add(new ApiRemoteCollection(http, base_url, ApiKind.GOOGLE_TASKS, id, page_string(o, "title", true), "", false));
                        }
                        string token = page_string(root, "nextPageToken");
                        next = token != "" ? url + "&pageToken=" + Uri.escape_string(token, null, false) : "";
                    }
                    break;
                }
                default:
                    break;
            }
            return result;
        }

        /** Rebuilds a collection from RemoteCollection.to_descriptor(), without network access. */
        public RemoteCollection? from_descriptor(Account account, ContentKind kind, Json.Object d) {
            string type = str(d, "type");
            string name = str(d, "name");
            string color = str(d, "color");
            bool read_only = d.has_member("read-only") && d.get_boolean_member("read-only");
            var http = new HttpClient(account, kind.capability());
            if (type == "dav") {
                return new DavRemoteCollection(new DavClient(http), str(d, "url"), name, color, read_only, kind);
            }
            if (type == "ews") {
                return new EwsRemoteCollection(http, str(d, "url"), name);
            }
            ApiKind api;
            if (ApiKind.try_parse(type, out api)) {
                return new ApiRemoteCollection(http, str(d, "base"), api, str(d, "remote-id"), name, color, read_only);
            }
            return null;
        }
    }

    /**
     * The synchronised collections of one account for one content kind.
     *
     * The list is restored from disk at once, so an app can show cached
     * items offline, and refresh() updates it from the server.
     */
    public class CollectionSet : Object {
        /** The account. */
        public Account account { get; construct; }
        /** What the collections hold. */
        public ContentKind kind { get; construct; }
        /** Directory holding the mirrors. */
        public string directory { get; construct; }
        /** Message of the last failed discovery, or an empty string. */
        public string last_error { get; private set; default = ""; }

        /** Emitted when collections were added or removed. */
        public signal void collections_changed();
        /** Emitted when the items of a collection changed. */
        public signal void changed(SyncedCollection collection);

        private Gee.ArrayList<SyncedCollection> list = new Gee.ArrayList<SyncedCollection>();
        private uint timer;
        private ulong network_handler;
        private bool watching;
        private FileMonitor? index_monitor;
        private uint index_source;
        private uint revision;

        /** Directory where the mirrors of an account are kept. */
        public static string account_directory(string account_id) {
            return Path.build_filename(Environment.get_user_data_dir(), "singularity", "accounts", account_id);
        }

        public CollectionSet(Account account, ContentKind kind) {
            Object(account: account, kind: kind, directory: Path.build_filename(account_directory(account.id), kind.to_id()));
            load_index();
        }

        /** The collections currently known. */
        public Gee.List<SyncedCollection> collections {
            owned get { return list.read_only_view; }
        }

        private string index_path() {
            return Path.build_filename(directory, "collections.json");
        }

        private bool load_index() {
            if (!FileUtils.test(index_path(), FileTest.EXISTS)) return false;
            bool touched = false;
            try {
                var parser = new Json.Parser();
                parser.load_from_file(index_path());
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.ARRAY) return false;
                var ids = new Gee.HashSet<string>();
                foreach (var node in root.get_array().get_elements()) {
                    if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                    var remote = Collections.from_descriptor(account, kind, node.get_object());
                    if (remote == null) continue;
                    ids.add(remote.id);
                    if (find(remote.id) == null) {
                        add(remote);
                        touched = true;
                    }
                }
                foreach (var c in list.to_array()) {
                    if (ids.contains(c.remote.id)) continue;
                    c.unwatch();
                    list.remove(c);
                    touched = true;
                }
            } catch (Error e) {
                warning("accounts: cannot read %s: %s", index_path(), e.message);
            }
            return touched;
        }

        private void save_index(Gee.List<RemoteCollection> remotes) throws Error {
            var array = new Json.Array();
            foreach (var remote in remotes) array.add_object_element(remote.to_descriptor());
            var node = new Json.Node(Json.NodeType.ARRAY);
            node.set_array(array);
            var gen = new Json.Generator();
            gen.set_root(node);
            string text = gen.to_data(null);
            try {
                string current;
                if (FileUtils.get_contents(index_path(), out current) && current == text) return;
            } catch (Error e) {
            }
            DirUtils.create_with_parents(directory, 0700);
            FileUtils.set_contents_full(index_path(), text, -1, FileSetContentsFlags.CONSISTENT | FileSetContentsFlags.DURABLE, 0600);
        }

        public SyncedCollection add_created(RemoteCollection remote) throws Error {
            var existing = find(remote.id);
            if (existing != null) return existing;
            var remotes = new Gee.ArrayList<RemoteCollection>();
            foreach (var c in list) remotes.add(c.remote);
            remotes.add(remote);
            save_index(remotes);
            var added = add(remote);
            revision++;
            collections_changed();
            return added;
        }

        public async SyncedCollection create(string name, Cancellable? cancellable = null) throws Error {
            var remote = yield Collections.create(account, kind, name, cancellable);
            return add_created(remote);
        }

        private SyncedCollection add(RemoteCollection remote) {
            var c = new SyncedCollection(account.id, remote, kind, directory);
            c.changed.connect(() => changed(c));
            list.add(c);
            if (watching) c.watch();
            return c;
        }

        /** Returns the collection with the RemoteCollection.id, or null. */
        public SyncedCollection? find(string remote_id) {
            foreach (var c in list) if (c.remote.id == remote_id) return c;
            return null;
        }

        /**
         * Discovers the collections on the server, adds new ones, drops the
         * ones that disappeared, then syncs every collection. When the server
         * cannot be reached the cached collections stay.
         */
        public async void refresh(Cancellable? cancellable = null) {
            try {
                uint started = revision;
                var found = yield Collections.discover(account, kind, cancellable);
                if (cancellable != null) cancellable.set_error_if_cancelled();
                if (started != revision) throw new IOError.BUSY(_("The collection list changed during discovery; try again"));
                save_index(found);
                var ids = new Gee.HashSet<string>();
                bool touched = false;
                foreach (var remote in found) {
                    ids.add(remote.id);
                    if (find(remote.id) == null) {
                        add(remote);
                        touched = true;
                    }
                }
                foreach (var c in list.to_array()) {
                    if (!ids.contains(c.remote.id)) {
                        list.remove(c);
                        c.forget();
                        touched = true;
                    }
                }
                revision++;
                last_error = "";
                if (touched) collections_changed();
            } catch (Error e) {
                last_error = e.message;
                return;
            }
            yield sync_all(cancellable);
        }

        /** Syncs every collection in turn. */
        public async void sync_all(Cancellable? cancellable = null) {
            foreach (var c in list.to_array()) yield c.sync(cancellable);
        }

        /**
         * Syncs every `interval` seconds and whenever the network comes back,
         * and follows the changes other processes make to the mirrors.
         */
        public void start_auto_sync(uint interval = 300) {
            stop_auto_sync();
            timer = Timeout.add_seconds(interval, () => {
                sync_all.begin();
                return Source.CONTINUE;
            });
            network_handler = NetworkMonitor.get_default().network_changed.connect((available) => {
                if (available) sync_all.begin();
            });
            watch();
        }

        /** Stops automatic syncing. */
        public void stop_auto_sync() {
            if (timer != 0) Source.remove(timer);
            timer = 0;
            if (network_handler != 0) NetworkMonitor.get_default().disconnect(network_handler);
            network_handler = 0;
            foreach (var c in list) c.cancel_scheduled();
            unwatch();
        }

        /**
         * Follows the mirrors and the list of collections, so what other
         * processes add, sync or edit shows up here too.
         */
        public void watch() {
            if (watching) return;
            watching = true;
            foreach (var c in list) c.watch();
            try {
                DirUtils.create_with_parents(directory, 0700);
                index_monitor = File.new_for_path(index_path()).monitor_file(FileMonitorFlags.WATCH_MOVES, null);
                index_monitor.changed.connect(() => {
                    if (index_source != 0) return;
                    index_source = Timeout.add(100, () => {
                        index_source = 0;
                        if (load_index()) collections_changed();
                        return Source.REMOVE;
                    });
                });
            } catch (Error e) {
                warning("accounts: cannot watch %s: %s", index_path(), e.message);
            }
        }

        /** Stops following the mirrors. */
        public void unwatch() {
            if (!watching) return;
            watching = false;
            foreach (var c in list) c.unwatch();
            if (index_monitor != null) index_monitor.cancel();
            index_monitor = null;
            if (index_source != 0) Source.remove(index_source);
            index_source = 0;
        }
    }

    /**
     * Keeps one CollectionSet per account that has a capability switched
     * on, following accounts as they are added, changed and removed.
     *
     * {{{
     * var tracker = new CollectionTracker(ContentKind.EVENTS);
     * tracker.set_added.connect((cs) => show(cs));
     * tracker.set_removed.connect((cs) => hide(cs));
     * tracker.start.begin();
     * }}}
     */
    public class CollectionTracker : Object {
        /** What the tracked collections hold. */
        public ContentKind kind { get; construct; }
        private Gee.HashMap<string, CollectionSet> sets = new Gee.HashMap<string, CollectionSet>();
        private bool started;
        private static Gee.HashMap<string, CollectionTracker>? shared_trackers;

        /**
         * Returns the tracker of a content kind shared by the whole process,
         * started on the first call, so widgets and plugins of one process
         * do not each sync the same collections.
         */
        public static CollectionTracker get_shared(ContentKind kind) {
            if (shared_trackers == null) shared_trackers = new Gee.HashMap<string, CollectionTracker>();
            var existing = shared_trackers[kind.to_id()];
            if (existing != null) return existing;
            var tracker = new CollectionTracker(kind);
            shared_trackers[kind.to_id()] = tracker;
            tracker.start.begin();
            return tracker;
        }

        /** True once the accounts are loaded and the sets exist. */
        public bool ready { get; private set; default = false; }

        /** Emitted when an account starts offering the content. */
        public signal void set_added(CollectionSet cs);
        /** Emitted when an account was removed or its capability switched off. */
        public signal void set_removed(CollectionSet cs);
        /** Emitted when collections were added to or removed from a set. */
        public signal void collections_changed(CollectionSet cs);
        /** Emitted when the items of a collection changed. */
        public signal void changed(CollectionSet cs, SyncedCollection collection);

        public CollectionTracker(ContentKind kind) {
            Object(kind: kind);
        }

        /** The current sets. */
        public Gee.Collection<CollectionSet> get_sets() {
            return sets.values.read_only_view;
        }

        /** Returns the set of an account, or null. */
        public CollectionSet? get_set(string account_id) {
            return sets[account_id];
        }

        /** Loads the accounts, creates the sets and refreshes them from the servers. */
        public async void start() {
            if (started) return;
            started = true;
            var manager = Manager.get_default();
            manager.account_added.connect((a) => update(a));
            manager.account_changed.connect((a) => update(a));
            manager.account_removed.connect((a) => drop(a.id));
            manager.reloaded.connect(() => {
                foreach (var id in sets.keys.to_array()) if (manager.get_account(id) == null) drop(id);
                foreach (var a in manager.get_accounts()) update(a);
            });
            yield manager.load();
            foreach (var a in manager.get_accounts()) update(a);
            ready = true;
        }

        private void update(Account account) {
            bool wanted = account.has_capability(kind.capability());
            var existing = sets[account.id];
            if (!wanted) {
                if (existing != null) drop(account.id);
                return;
            }
            if (existing != null) return;
            var cs = new CollectionSet(account, kind);
            cs.collections_changed.connect(() => collections_changed(cs));
            cs.changed.connect((c) => changed(cs, c));
            sets[account.id] = cs;
            set_added(cs);
            cs.start_auto_sync();
            cs.refresh.begin();
        }

        private void drop(string id) {
            var cs = sets[id];
            if (cs == null) return;
            cs.stop_auto_sync();
            sets.unset(id);
            set_removed(cs);
        }

        /** Refreshes every set now. */
        public async void refresh_all() {
            foreach (var cs in sets.values.to_array()) yield cs.refresh();
        }
    }
}
