namespace Singularity.MediaSources {

    public class AppMediaHost : Object, MediaHost {
        private string _app_id;
        private MediaKind _kinds;
        private string _user_agent;
        private Soup.Session _session;
        private KeyFile _values = new KeyFile();
        private string _values_path;
        private Gtk.Window? _window = null;
        private bool _accounts_loading = false;

        public signal void message(string source_id, string text);

        public string app_id { owned get { return _app_id; } }
        public MediaKind kinds { get { return _kinds; } }
        public string user_agent { owned get { return _user_agent; } }
        public Soup.Session session { get { return _session; } }
        public bool network_available { get { return NetworkMonitor.get_default().network_available; } }
        public bool window_visible { get { return _window != null && _window.visible && !_window.is_suspended(); } }

        public AppMediaHost(string app_id, MediaKind kinds, string user_agent) {
            _app_id = app_id;
            _kinds = kinds;
            _user_agent = user_agent;
            _session = new Soup.Session();
            _session.user_agent = user_agent;
            _session.timeout = 30;
            _values_path = Path.build_filename(Environment.get_user_config_dir(), app_id, "sources.ini");
            try {
                _values.load_from_file(_values_path, KeyFileFlags.NONE);
            } catch (Error e) {
            }
            var manager = Singularity.Accounts.Manager.get_default();
            manager.account_added.connect(() => accounts_changed());
            manager.account_removed.connect(() => accounts_changed());
            manager.account_changed.connect(() => accounts_changed());
            manager.reloaded.connect(() => accounts_changed());
            NetworkMonitor.get_default().network_changed.connect(() => accounts_changed());
        }

        public void attach_window(Gtk.Window window) {
            _window = window;
            window.notify["visible"].connect(() => visibility_changed());
            window.notify["suspended"].connect(() => visibility_changed());
        }

        public async void load_accounts() {
            if (_accounts_loading) return;
            _accounts_loading = true;
            yield Singularity.Accounts.Manager.get_default().load();
            _accounts_loading = false;
            accounts_changed();
        }

        public string cache_dir(string source_id) {
            string dir = Path.build_filename(Environment.get_user_cache_dir(), _app_id, "sources", source_id);
            DirUtils.create_with_parents(dir, 0700);
            return dir;
        }

        public string? get_value(string source_id, string key) {
            try {
                return _values.get_string(source_id, key);
            } catch (KeyFileError e) {
                return null;
            }
        }

        public void set_value(string source_id, string key, string? value) {
            try {
                if (value == null) _values.remove_key(source_id, key);
                else _values.set_string(source_id, key, value);
            } catch (KeyFileError e) {
            }
            try {
                DirUtils.create_with_parents(Path.get_dirname(_values_path), 0700);
                FileUtils.set_contents_full(_values_path, _values.to_data(), -1, FileSetContentsFlags.CONSISTENT, 0600);
            } catch (Error e) {
                warning("%s: %s", _app_id, e.message);
            }
        }

        public Gee.List<Singularity.Accounts.Account> accounts(Singularity.Accounts.Capability capability) {
            return Singularity.Accounts.Manager.get_default().get_accounts_for(capability);
        }

        public void show_message(string source_id, string message) {
            this.message(source_id, message);
        }

        public void open_external(string uri) {
            var launcher = new Gtk.UriLauncher(uri);
            launcher.launch.begin(_window, null, (o, r) => {
                try {
                    launcher.launch.end(r);
                } catch (Error e) {
                    warning("%s: %s", _app_id, e.message);
                }
            });
        }
    }
}
