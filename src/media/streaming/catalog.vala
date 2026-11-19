namespace Singularity.Streaming {

    public enum CatalogState {
        LOADING,
        READY,
        OFFLINE
    }

    public class WatchEntry : Object {
        public Title title { get; construct; }
        public string platform_id { get; construct; }
        public int64 opened { get; set; default = 0; }

        public WatchEntry(Title title, string platform_id) {
            Object(title: title, platform_id: platform_id);
        }

        public Offer? offer() {
            var o = title.offer_on(platform_id);
            if (o != null) return o;
            var platform = Platform.lookup(platform_id);
            return platform != null ? new Offer(platform) : null;
        }
    }

    public class Catalog : Object {
        private const int64 IMAGE_LIMIT = 8 * 1024 * 1024;
        private const int HISTORY_SIZE = 20;
        private const int FEATURED = 5;
        private const int64 REFRESH_AFTER = 6 * TimeSpan.HOUR;

        private static Catalog? _default = null;

        private Soup.Session _session;
        private Config _config;
        private Backend _backend;
        private GenericArray<Title> _featured = new GenericArray<Title>();
        private GenericArray<WatchEntry> _history = new GenericArray<WatchEntry>();
        private int64 _refreshed_at = 0;
        private bool _refreshing = false;

        public CatalogState state { get; private set; default = CatalogState.LOADING; }

        public signal void featured_changed();
        public signal void history_changed();

        public static Catalog get_default() {
            if (_default == null) _default = new Catalog();
            return _default;
        }

        private Catalog() {
            _session = new Soup.Session();
            _session.timeout = 15;
            _session.user_agent = "Singularity";
            _config = Config.from_locale();
            _backend = new JustWatchBackend(_session);
            load_featured_cache();
            load_history();
            if (_featured.length > 0) state = CatalogState.READY;
        }

        public Config config { get { return _config; } }

        public Backend backend { get { return _backend; } }

        public GenericArray<Title> featured { get { return _featured; } }

        public GenericArray<WatchEntry> history { get { return _history; } }

        public void refresh() {
            if (_refreshing) return;
            if (_refreshed_at != 0 && GLib.get_monotonic_time() - _refreshed_at < REFRESH_AFTER) return;
            _refreshing = true;
            if (_featured.length == 0) state = CatalogState.LOADING;
            _backend.featured.begin(_config, FEATURED, null, (obj, res) => {
                _refreshing = false;
                try {
                    var titles = _backend.featured.end(res);
                    _refreshed_at = GLib.get_monotonic_time();
                    if (titles.length == 0 && _featured.length > 0) return;
                    _featured = titles;
                    state = CatalogState.READY;
                    save_featured_cache();
                    featured_changed();
                } catch (Error e) {
                    warning("streaming catalog: %s", e.message);
                    if (_featured.length == 0) state = CatalogState.OFFLINE;
                }
            });
        }

        public void record(Title title, Platform platform) {
            for (uint i = 0; i < _history.length; i++) {
                var e = _history[i];
                if (e.title.id != title.id) continue;
                var moved = new WatchEntry(title, platform.id);
                moved.opened = GLib.get_real_time() / TimeSpan.SECOND;
                _history.remove_index(i);
                _history.insert(0, moved);
                save_history();
                history_changed();
                return;
            }
            var entry = new WatchEntry(title, platform.id);
            entry.opened = GLib.get_real_time() / TimeSpan.SECOND;
            _history.insert(0, entry);
            if (_history.length > HISTORY_SIZE) _history.remove_range(HISTORY_SIZE, _history.length - HISTORY_SIZE);
            save_history();
            history_changed();
        }

        public async Gdk.Texture? image(string uri, int width, int height, Cancellable? cancellable = null) {
            string key = Checksum.compute_for_string(ChecksumType.SHA256, uri);
            var file = File.new_for_path(Path.build_filename(cache_dir(), "images", key));
            if (!file.query_exists()) {
                try {
                    var message = new Soup.Message("GET", uri);
                    if (message == null) return null;
                    var bytes = yield Singularity.HttpBody.read(_session, message, IMAGE_LIMIT, Priority.LOW, cancellable);
                    if (message.status_code != 200) return null;
                    DirUtils.create_with_parents(file.get_parent().get_path(), 0700);
                    var tmp = File.new_for_path(file.get_path() + ".part");
                    yield tmp.replace_contents_async(bytes.get_data(), null, false, FileCreateFlags.PRIVATE, cancellable, null);
                    tmp.move(file, FileCopyFlags.OVERWRITE);
                } catch (Error e) {
                    return null;
                }
            }
            try {
                return yield Singularity.Async.load_cover(file, width, height, Singularity.Async.Qos.USER, cancellable);
            } catch (Error e) {
                return null;
            }
        }

        private static string cache_dir() {
            return Path.build_filename(Environment.get_user_cache_dir(), "singularity", "streaming");
        }

        private static string history_path() {
            return Path.build_filename(Environment.get_user_data_dir(), "singularity", "streaming", "history.json");
        }

        private void load_featured_cache() {
            var root = read_json(Path.build_filename(cache_dir(), "featured.json"));
            if (root == null || !root.has_member("titles")) return;
            if (root.get_string_member_with_default("backend", "") != _backend.id
                    || root.get_string_member_with_default("country", "") != _config.country
                    || root.get_string_member_with_default("language", "") != _config.language) return;
            foreach (var node in root.get_array_member("titles").get_elements()) {
                if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                var t = title_from_json(node.get_object());
                if (t != null) _featured.add(t);
            }
        }

        private void save_featured_cache() {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("backend").add_string_value(_backend.id);
            b.set_member_name("country").add_string_value(_config.country);
            b.set_member_name("language").add_string_value(_config.language);
            b.set_member_name("titles").begin_array();
            foreach (var t in _featured) title_to_json(b, t);
            b.end_array();
            b.end_object();
            write_json(Path.build_filename(cache_dir(), "featured.json"), b);
        }

        private void load_history() {
            var root = read_json(history_path());
            if (root == null || !root.has_member("entries")) return;
            foreach (var node in root.get_array_member("entries").get_elements()) {
                if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                var o = node.get_object();
                if (!o.has_member("title") || o.get_member("title").get_node_type() != Json.NodeType.OBJECT) continue;
                var t = title_from_json(o.get_object_member("title"));
                string platform = o.get_string_member_with_default("platform", "");
                if (t == null || Platform.lookup(platform) == null) continue;
                var e = new WatchEntry(t, platform);
                e.opened = o.get_int_member_with_default("opened", 0);
                _history.add(e);
                if (_history.length >= HISTORY_SIZE) break;
            }
        }

        private void save_history() {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("entries").begin_array();
            foreach (var e in _history) {
                b.begin_object();
                b.set_member_name("platform").add_string_value(e.platform_id);
                b.set_member_name("opened").add_int_value(e.opened);
                b.set_member_name("title");
                title_to_json(b, e.title);
                b.end_object();
            }
            b.end_array();
            b.end_object();
            write_json(history_path(), b);
        }

        private static void title_to_json(Json.Builder b, Title t) {
            b.begin_object();
            b.set_member_name("id").add_string_value(t.id);
            b.set_member_name("kind").add_string_value(t.kind.to_id());
            b.set_member_name("name").add_string_value(t.name);
            b.set_member_name("overview").add_string_value(t.overview);
            if (t.backdrop_uri != null) b.set_member_name("backdrop").add_string_value(t.backdrop_uri);
            if (t.poster_uri != null) b.set_member_name("poster").add_string_value(t.poster_uri);
            b.set_member_name("year").add_int_value(t.year);
            b.set_member_name("offers").begin_array();
            foreach (var o in t.offers) {
                b.begin_object();
                b.set_member_name("platform").add_string_value(o.platform.id);
                if (o.url != null) b.set_member_name("url").add_string_value(o.url);
                if (o.logo_uri != null) b.set_member_name("logo").add_string_value(o.logo_uri);
                b.end_object();
            }
            b.end_array();
            b.end_object();
        }

        private static Title? title_from_json(Json.Object o) {
            string id = o.get_string_member_with_default("id", "");
            string name = o.get_string_member_with_default("name", "");
            if (id == "" || name == "") return null;
            var t = new Title(id, TitleKind.parse(o.get_string_member_with_default("kind", "movie")));
            t.name = name;
            t.overview = o.get_string_member_with_default("overview", "");
            string backdrop = o.get_string_member_with_default("backdrop", "");
            if (backdrop != "") t.backdrop_uri = backdrop;
            string poster = o.get_string_member_with_default("poster", "");
            if (poster != "") t.poster_uri = poster;
            t.year = (int) o.get_int_member_with_default("year", 0);
            if (o.has_member("offers") && o.get_member("offers").get_node_type() == Json.NodeType.ARRAY) {
                foreach (var node in o.get_array_member("offers").get_elements()) {
                    if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                    var p = Platform.lookup(node.get_object().get_string_member_with_default("platform", ""));
                    if (p == null) continue;
                    var offer = new Offer(p);
                    string url = node.get_object().get_string_member_with_default("url", "");
                    if (url != "") offer.url = url;
                    string logo = node.get_object().get_string_member_with_default("logo", "");
                    if (logo != "") offer.logo_uri = logo;
                    t.offers.add(offer);
                }
            }
            return t;
        }

        private static Json.Object? read_json(string path) {
            var parser = new Json.Parser();
            try {
                parser.load_from_file(path);
            } catch (Error e) {
                return null;
            }
            var root = parser.get_root();
            return root != null && root.get_node_type() == Json.NodeType.OBJECT ? root.get_object() : null;
        }

        private static void write_json(string path, Json.Builder b) {
            var gen = new Json.Generator();
            gen.root = b.get_root();
            try {
                DirUtils.create_with_parents(Path.get_dirname(path), 0700);
                FileUtils.set_contents(path, gen.to_data(null));
            } catch (Error e) {
                warning("streaming catalog: %s", e.message);
            }
        }
    }
}
