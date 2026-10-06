namespace Singularity.Accounts {

    /**
     * Local state of a synchronised item.
     */
    public enum SyncState {
        /** Same as the server copy last seen. */
        CLEAN,
        /** Created locally, not uploaded yet. */
        NEW,
        /** Changed locally, not uploaded yet. */
        MODIFIED,
        /** Deleted locally, not deleted on the server yet. */
        DELETED;

        public string to_id() {
            switch (this) {
                case NEW: return "new";
                case MODIFIED: return "modified";
                case DELETED: return "deleted";
                default: return "clean";
            }
        }

        public static SyncState from_id(string id) {
            switch (id) {
                case "new": return NEW;
                case "modified": return MODIFIED;
                case "deleted": return DELETED;
                default: return CLEAN;
            }
        }
    }

    /**
     * One item of a SyncedCollection.
     */
    public class SyncItem : Object {
        /** UID of the event, task or contact. */
        public string uid { get; set; }
        /** Server address, or an empty string before the first upload. */
        public string href { get; set; default = ""; }
        /** Server version tag last seen. */
        public string etag { get; set; default = ""; }
        /** iCalendar or vCard text. */
        public string data { get; set; default = ""; }
        /** Local state. */
        public SyncState state { get; set; default = SyncState.CLEAN; }

        public SyncItem(string uid) {
            Object(uid: uid);
        }
    }

    /**
     * A local mirror of a RemoteCollection with two-way sync.
     *
     * Apps read items() and write with put() and remove(); both work
     * offline. sync() uploads local changes first (If-Match on the last
     * seen tag), then downloads what changed on the server, skipping the
     * download when the collection tag (getctag) did not move. When both
     * sides changed the same item, the server copy wins and the local edit
     * is dropped; a local edit of an item deleted on the server recreates
     * it. The mirror lives in a JSON file so edits survive restarts.
     *
     * Several processes (the shell, Calendar, Tasks) may use the same
     * mirror at once. Every change is a read-modify-write of the file under
     * an exclusive lock, so no process overwrites the edits of another, and
     * only one process syncs a collection at a time: the others wait for
     * the running sync and then only upload what is still pending. After
     * watch(), changes written by other processes are loaded and announced
     * with changed().
     */
    public class SyncedCollection : Object {
        /** Identifier of the account the collection belongs to. */
        public string account_id { get; construct; }
        /** The server side collection. */
        public RemoteCollection remote { get; construct; }
        /** What the collection holds. */
        public ContentKind kind { get; construct; }
        /** Path of the JSON mirror. */
        public string path { get; construct; }

        /** True while a sync runs. */
        public bool syncing { get; private set; default = false; }
        /** True when the last sync failed because the server could not be reached. */
        public bool offline { get; private set; default = false; }
        /** Message of the last sync failure, or an empty string. */
        public string last_error { get; private set; default = ""; }
        /** Unix time of the last successful sync, or 0. */
        public int64 last_sync { get; private set; default = 0; }
        /** Number of local edits dropped because the server copy changed too. */
        public int conflicts { get; private set; default = 0; }

        /** Emitted when items changed, locally, after a sync or in another process. */
        public signal void changed();
        /** Emitted when a sync ends. */
        public signal void sync_finished(bool success);

        private Gee.HashMap<string, SyncItem> table = new Gee.HashMap<string, SyncItem>();
        private string tag = "";
        private string stamp = "";
        private uint sync_source;
        private bool again;
        private MirrorLock data_lock;
        private MirrorLock sync_lock;
        private FileMonitor? monitor;
        private uint refresh_source;

        /**
         * @param account_id Account identifier.
         * @param remote     Server side collection.
         * @param kind       Content kind.
         * @param directory  Directory for the JSON mirror.
         */
        public SyncedCollection(string account_id, RemoteCollection remote, ContentKind kind, string directory) {
            string file = Checksum.compute_for_string(ChecksumType.SHA1, remote.id) + ".json";
            Object(account_id: account_id, remote: remote, kind: kind, path: Path.build_filename(directory, file));
            data_lock = MirrorLock.for_path(path + ".lock");
            sync_lock = MirrorLock.for_path(path + ".sync");
            reload();
        }

        /** Display name of the collection. */
        public string name {
            get { return remote.name; }
        }

        /** Colour of the collection, or an empty string. */
        public string color {
            get { return remote.color; }
        }

        /** True when local edits are not allowed. */
        public bool read_only {
            get { return remote.read_only; }
        }

        /** Items that are not deleted. */
        public Gee.List<SyncItem> items() {
            var result = new Gee.ArrayList<SyncItem>();
            foreach (var item in table.values) if (item.state != SyncState.DELETED) result.add(item);
            return result;
        }

        /** Returns an item that is not deleted, or null. */
        public SyncItem? get_item(string uid) {
            var item = table[uid];
            return item != null && item.state != SyncState.DELETED ? item : null;
        }

        /** Number of local changes not uploaded yet. */
        public int pending_changes() {
            int n = 0;
            foreach (var item in table.values) if (item.state != SyncState.CLEAN) n++;
            return n;
        }

        /**
         * Creates or replaces an item locally and schedules a sync.
         *
         * @param uid  UID inside the data.
         * @param data iCalendar or vCard text.
         */
        public void put(string uid, string data) {
            begin_edit();
            var item = table[uid];
            if (item == null) {
                item = new SyncItem(uid);
                item.state = SyncState.NEW;
                table[uid] = item;
            } else if (item.state == SyncState.CLEAN || item.state == SyncState.DELETED) {
                item.state = item.href == "" ? SyncState.NEW : SyncState.MODIFIED;
            }
            item.data = data;
            end_edit();
            changed();
            schedule_sync();
        }

        /** Deletes an item locally and schedules a sync. */
        public void remove(string uid) {
            begin_edit();
            var item = table[uid];
            if (item == null) {
                end_edit();
                return;
            }
            if (item.href == "") table.unset(uid);
            else item.state = SyncState.DELETED;
            end_edit();
            changed();
            schedule_sync();
        }

        /** Runs sync() after `delay_ms` milliseconds, merging repeated calls. */
        public void schedule_sync(uint delay_ms = 1200) {
            if (sync_source != 0) Source.remove(sync_source);
            sync_source = Timeout.add(delay_ms, () => {
                sync_source = 0;
                sync.begin();
                return Source.REMOVE;
            });
        }

        /** Stops a scheduled sync. */
        public void cancel_scheduled() {
            if (sync_source != 0) Source.remove(sync_source);
            sync_source = 0;
        }

        /**
         * Follows the mirror file, so edits and syncs made by other
         * processes are loaded and announced with changed().
         */
        public void watch() {
            if (monitor != null) return;
            try {
                DirUtils.create_with_parents(Path.get_dirname(path), 0700);
                monitor = File.new_for_path(path).monitor_file(FileMonitorFlags.WATCH_MOVES, null);
                monitor.changed.connect(() => queue_refresh());
            } catch (Error e) {
                warning("accounts: cannot watch %s: %s", path, e.message);
            }
        }

        /** Stops following the mirror file. */
        public void unwatch() {
            if (monitor != null) monitor.cancel();
            monitor = null;
            if (refresh_source != 0) Source.remove(refresh_source);
            refresh_source = 0;
        }

        private void queue_refresh() {
            if (refresh_source != 0) return;
            refresh_source = Timeout.add(100, () => {
                refresh_source = 0;
                refresh();
                return Source.REMOVE;
            });
        }

        /**
         * Loads the mirror again when another process changed it.
         *
         * @return true when the items changed; changed() was emitted then.
         */
        public bool refresh() {
            if (!reload()) return false;
            changed();
            return true;
        }

        /**
         * Uploads local changes and downloads server changes.
         *
         * When another process is syncing the same collection, waits for it
         * first.
         *
         * @return true on success.
         */
        public async bool sync(Cancellable? cancellable = null) {
            if (orphaned()) return false;
            if (syncing) {
                again = true;
                return false;
            }
            syncing = true;
            if (!yield sync_lock.acquire_async(cancellable)) {
                syncing = false;
                return false;
            }
            refresh();
            bool ok = true;
            string new_tag = tag;
            try {
                bool pushed = yield push(cancellable);
                string before = "";
                try {
                    before = yield remote.get_tag(cancellable);
                } catch (AccountsError.NETWORK e) {
                    throw e;
                } catch (AccountsError.NEEDS_REAUTH e) {
                    throw e;
                } catch (Error e) {
                    before = "";
                }
                if (before == "" || before != tag || pushed || needs_refetch()) {
                    yield pull(cancellable);
                    if (pushed && before != "") {
                        try {
                            before = yield remote.get_tag(cancellable);
                        } catch (Error e) {
                            before = "";
                        }
                    }
                }
                new_tag = before;
                offline = false;
                last_error = "";
            } catch (AccountsError.NETWORK e) {
                ok = false;
                offline = true;
                last_error = e.message;
            } catch (Error e) {
                ok = false;
                offline = false;
                last_error = e.message;
            }
            begin_edit();
            if (ok) {
                tag = new_tag;
                last_sync = get_real_time() / 1000000;
            }
            end_edit();
            sync_lock.release();
            syncing = false;
            changed();
            sync_finished(ok);
            if (again) {
                again = false;
                schedule_sync(100);
            }
            return ok;
        }

        private bool needs_refetch() {
            foreach (var item in table.values) if (item.state == SyncState.CLEAN && item.etag == "") return true;
            return false;
        }

        private bool attached(SyncItem item) {
            return table[item.uid] == item;
        }

        private async bool push(Cancellable? cancellable) throws Error {
            bool pushed = false;
            foreach (var item in table.values.to_array()) {
                if (item.state == SyncState.CLEAN || !attached(item)) continue;
                if (remote.read_only) {
                    begin_edit();
                    if (attached(item) && item.state != SyncState.CLEAN) {
                        if (item.href == "") table.unset(item.uid);
                        else {
                            item.state = SyncState.CLEAN;
                            item.etag = "";
                        }
                    }
                    end_edit();
                    continue;
                }
                string sent = item.data;
                string href = item.href;
                string etag = item.etag;
                try {
                    switch (item.state) {
                        case SyncState.NEW:
                            var created = yield remote.create(item.uid, sent, cancellable);
                            begin_edit();
                            adopt_created(item, sent, created);
                            end_edit();
                            break;
                        case SyncState.MODIFIED:
                            RemoteItem? updated = null;
                            try {
                                updated = yield remote.update(href, etag, sent, cancellable);
                            } catch (AccountsError.NOT_FOUND e) {
                                updated = null;
                            }
                            if (updated == null) {
                                var recreated = yield remote.create(item.uid, sent, cancellable);
                                begin_edit();
                                adopt_created(item, sent, recreated);
                                end_edit();
                                break;
                            }
                            begin_edit();
                            if (attached(item)) {
                                if (updated.href != "") item.href = updated.href;
                                item.etag = updated.etag;
                                settle(item, sent, updated.data);
                            }
                            end_edit();
                            break;
                        case SyncState.DELETED:
                            yield remote.remove(href, etag, cancellable);
                            begin_edit();
                            if (attached(item)) {
                                if (item.state == SyncState.DELETED) {
                                    table.unset(item.uid);
                                } else {
                                    item.href = "";
                                    item.etag = "";
                                    item.state = SyncState.NEW;
                                }
                            }
                            end_edit();
                            break;
                        default:
                            break;
                    }
                    pushed = true;
                } catch (AccountsError.CONFLICT e) {
                    conflicts++;
                    begin_edit();
                    if (attached(item)) {
                        item.state = SyncState.CLEAN;
                        item.etag = "";
                    }
                    end_edit();
                    pushed = true;
                } catch (AccountsError.NETWORK e) {
                    throw e;
                } catch (AccountsError.NEEDS_REAUTH e) {
                    throw e;
                } catch (Error e) {
                    throw e;
                }
            }
            return pushed;
        }

        private void settle(SyncItem item, string sent, string server_data) {
            if (item.data != sent) {
                item.state = SyncState.MODIFIED;
                return;
            }
            item.state = SyncState.CLEAN;
            if (server_data != "") item.data = server_data;
        }

        private void adopt_created(SyncItem item, string sent, RemoteItem r) {
            if (!attached(item)) {
                var current = table[item.uid];
                if (current == null) {
                    item.href = r.href;
                    item.etag = r.etag;
                    item.state = SyncState.DELETED;
                    table[item.uid] = item;
                } else if (current.href == "") {
                    current.href = r.href;
                    current.etag = r.etag;
                    current.state = SyncState.MODIFIED;
                }
                return;
            }
            item.href = r.href;
            item.etag = r.etag;
            settle(item, sent, r.data);
            string uid = r.data != "" ? Component.find_uid(r.data) : "";
            if (uid != "" && uid != item.uid) {
                table.unset(item.uid);
                item.uid = uid;
                table[uid] = item;
            }
        }

        private async void pull(Cancellable? cancellable) throws Error {
            var index = yield remote.list_index(cancellable);
            var known = new Gee.HashMap<string, SyncItem>();
            foreach (var item in table.values) if (item.href != "") known[item.href] = item;
            var wanted = new Gee.ArrayList<string>();
            foreach (var entry in index.entries) {
                var item = known[entry.key];
                if (item == null) {
                    wanted.add(entry.key);
                } else if (item.state == SyncState.CLEAN && (item.etag == "" || item.etag != entry.value)) {
                    wanted.add(entry.key);
                }
            }
            Gee.List<RemoteItem> fetched = wanted.size > 0 ? yield remote.fetch(wanted, cancellable) : new Gee.ArrayList<RemoteItem>();
            begin_edit();
            foreach (var item in table.values.to_array()) {
                if (item.href != "" && item.state == SyncState.CLEAN && !index.has_key(item.href)) table.unset(item.uid);
            }
            var by_href = new Gee.HashMap<string, SyncItem>();
            foreach (var item in table.values) if (item.href != "") by_href[item.href] = item;
            foreach (var r in fetched) {
                var existing = by_href[r.href];
                if (existing != null && existing.state != SyncState.CLEAN) continue;
                if (existing != null && existing.etag == r.etag && existing.data == r.data) continue;
                string uid = Component.find_uid(r.data);
                if (uid == "") uid = r.href;
                if (existing != null && existing.uid != uid) table.unset(existing.uid);
                var other = table[uid];
                SyncItem item;
                if (other != null && other != existing && other.state != SyncState.NEW && other.href != "" && other.href != r.href) {
                    uid = r.href;
                    item = existing ?? new SyncItem(uid);
                } else if (other != null && other != existing) {
                    item = other;
                } else {
                    item = existing ?? new SyncItem(uid);
                }
                item.uid = uid;
                item.href = r.href;
                item.etag = r.etag;
                item.data = r.data;
                item.state = SyncState.CLEAN;
                table[uid] = item;
            }
            end_edit();
        }

        private void begin_edit() {
            data_lock.acquire();
            reload();
        }

        private void end_edit() {
            save();
            data_lock.release();
        }

        private bool reload() {
            string text = "";
            try {
                FileUtils.get_contents(path, out text);
            } catch (Error e) {
                text = "";
            }
            string now = text != "" ? Checksum.compute_for_string(ChecksumType.SHA1, text) : "";
            if (now == stamp) return false;
            stamp = now;
            var seen = new Gee.HashSet<string>();
            bool diff = false;
            if (now != "") {
                try {
                    var parser = new Json.Parser();
                    parser.load_from_data(text);
                    var root = parser.get_root();
                    if (root != null && root.get_node_type() == Json.NodeType.OBJECT) {
                        var o = root.get_object();
                        tag = o.has_member("tag") ? o.get_string_member("tag") : "";
                        int64 synced_at = o.has_member("last-sync") ? o.get_int_member("last-sync") : 0;
                        if (synced_at != last_sync) last_sync = synced_at;
                        if (o.has_member("items")) {
                            foreach (var node in o.get_array_member("items").get_elements()) {
                                var io = node.get_object();
                                string uid = io.get_string_member("uid");
                                seen.add(uid);
                                var item = table[uid];
                                if (item == null) {
                                    item = new SyncItem(uid);
                                    table[uid] = item;
                                    diff = true;
                                }
                                string href = io.get_string_member("href");
                                string etag = io.get_string_member("etag");
                                string data = io.get_string_member("data");
                                var state = SyncState.from_id(io.get_string_member("state"));
                                if (item.href != href || item.etag != etag || item.data != data || item.state != state) {
                                    item.href = href;
                                    item.etag = etag;
                                    item.data = data;
                                    item.state = state;
                                    diff = true;
                                }
                            }
                        }
                    }
                } catch (Error e) {
                    warning("accounts: cannot read %s: %s", path, e.message);
                    return false;
                }
            } else {
                tag = "";
            }
            foreach (string uid in table.keys.to_array()) {
                if (!seen.contains(uid)) {
                    table.unset(uid);
                    diff = true;
                }
            }
            return diff;
        }

        private bool orphaned() {
            var manager = Manager.get_default();
            return manager.available && manager.get_account(account_id) == null;
        }

        private void save() {
            if (orphaned()) return;
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("descriptor");
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(remote.to_descriptor());
            b.add_value(node);
            b.set_member_name("tag").add_string_value(tag);
            b.set_member_name("last-sync").add_int_value(last_sync);
            b.set_member_name("items").begin_array();
            foreach (var item in table.values) {
                b.begin_object();
                b.set_member_name("uid").add_string_value(item.uid);
                b.set_member_name("href").add_string_value(item.href);
                b.set_member_name("etag").add_string_value(item.etag);
                b.set_member_name("data").add_string_value(item.data);
                b.set_member_name("state").add_string_value(item.state.to_id());
                b.end_object();
            }
            b.end_array();
            b.end_object();
            var gen = new Json.Generator();
            gen.set_root(b.get_root());
            string text = gen.to_data(null);
            string sum = Checksum.compute_for_string(ChecksumType.SHA1, text);
            if (sum == stamp) return;
            try {
                DirUtils.create_with_parents(Path.get_dirname(path), 0700);
                FileUtils.set_contents_full(path, text, -1, FileSetContentsFlags.CONSISTENT, 0600);
                stamp = sum;
            } catch (Error e) {
                warning("accounts: cannot write %s: %s", path, e.message);
            }
        }

        /** Deletes the local mirror file. */
        public void forget() {
            cancel_scheduled();
            unwatch();
            FileUtils.unlink(path);
            stamp = "";
            data_lock.discard();
            sync_lock.discard();
        }
    }
}
