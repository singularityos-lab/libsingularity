using GLib;

namespace Singularity {

    public class NowPlayingCache : Object {
        [DBus (name = "org.freedesktop.DBus")]
        private interface DBusNames : Object {
            public abstract string[] ListNames () throws GLib.Error;
        }

        private static NowPlayingCache? _instance = null;
        public static NowPlayingCache get_default() {
            if (_instance == null) _instance = new NowPlayingCache();
            return _instance;
        }

        private DBusConnection? connection = null;
        private GLib.DBusProxy? player_proxy = null;
        private string? current_player_name = null;
        private uint _name_watch_id = 0;
        private string? _last_art_url = null;
        private string _cache_path;
        private string _cache_dir;
        private Soup.Session? _soup = null;

        construct {
            _cache_dir = GLib.Path.build_filename(
                GLib.Environment.get_user_cache_dir(), "singularity");
            _cache_path = GLib.Path.build_filename(_cache_dir, "now-playing-cover");
            GLib.DirUtils.create_with_parents(_cache_dir, 0700);
            setup.begin();
        }

        private async void setup() {
            try {
                connection = yield Bus.get(BusType.SESSION, null);
            } catch (Error e) {
                warning("NowPlayingCache: cannot get session bus: %s", e.message);
                return;
            }

            _name_watch_id = connection.signal_subscribe(
                "org.freedesktop.DBus", "org.freedesktop.DBus",
                "NameOwnerChanged", "/org/freedesktop/DBus", null,
                DBusSignalFlags.NONE,
                (conn, sender, obj_path, iface, sig, pars) => {
                    string? name      = (string?) pars.get_child_value(0);
                    string? new_owner = (string?) pars.get_child_value(2);
                    if (name == null || !name.has_prefix("org.mpris.MediaPlayer2.")) return;
                    if (new_owner != null && new_owner != "") {
                        connect_to_player(name);
                    } else if (name == current_player_name) {
                        current_player_name = null;
                        player_proxy = null;
                        clear_cache();
                        find_player();
                    }
                });

            find_player();
        }

        private void find_player() {
            try {
                var dbus = Bus.get_proxy_sync<DBusNames>(
                    BusType.SESSION, "org.freedesktop.DBus", "/org/freedesktop/DBus");
                string[] names = dbus.ListNames();
                string? best_name = null;
                foreach (string name in names) {
                    if (!name.has_prefix("org.mpris.MediaPlayer2.")) continue;
                    if (best_name == null) best_name = name;
                    try {
                        var p = new GLib.DBusProxy.for_bus_sync(
                            BusType.SESSION, DBusProxyFlags.NONE, null,
                            name, "/org/mpris/MediaPlayer2",
                            "org.mpris.MediaPlayer2.Player", null);
                        var st = p.get_cached_property("PlaybackStatus");
                        if (st != null && st.get_string() == "Playing") {
                            best_name = name;
                            break;
                        }
                    } catch (Error e) { continue; }
                }
                if (best_name != null) connect_to_player(best_name);
            } catch (Error e) { }
        }

        private void connect_to_player(string name) {
            try {
                var proxy = new GLib.DBusProxy.for_bus_sync(
                    BusType.SESSION, DBusProxyFlags.NONE, null,
                    name, "/org/mpris/MediaPlayer2",
                    "org.mpris.MediaPlayer2.Player", null);
                player_proxy = proxy;
                current_player_name = name;
                _last_art_url = null;
                proxy.g_properties_changed.connect(() => update_art());
                update_art();
            } catch (Error e) {
                warning("NowPlayingCache: connect to %s failed: %s", name, e.message);
            }
        }

        private void update_art() {
            if (player_proxy == null) return;
            var metadata = player_proxy.get_cached_property("Metadata");
            if (metadata == null) return;
            string art_url = "";
            var art_v = metadata.lookup_value("mpris:artUrl", null);
            if (art_v != null && art_v.is_of_type(VariantType.STRING))
                art_url = art_v.get_string();

            if (art_url == _last_art_url) return;
            _last_art_url = art_url;

            if (art_url == "") {
                clear_cache();
            } else if (art_url.has_prefix("file://")) {
                string src = Uri.unescape_string(art_url.substring(7));
                copy_local(src);
            } else if (art_url.has_prefix("http://") || art_url.has_prefix("https://")) {
                download_remote.begin(art_url);
            } else {
                clear_cache();
            }
        }

        private void copy_local(string src_path) {
            try {
                var src = File.new_for_path(src_path);
                var dst = File.new_for_path(_cache_path);
                src.copy(dst, FileCopyFlags.OVERWRITE, null, null);
            } catch (Error e) {
                clear_cache();
            }
        }

        private async void download_remote(string url) {
            if (_soup == null) _soup = new Soup.Session();
            try {
                var msg = new Soup.Message("GET", url);
                var bytes = yield _soup.send_and_read_async(msg, Priority.DEFAULT, null);
                if (msg.status_code != 200 || bytes == null) return;
                FileUtils.set_data(_cache_path, bytes.get_data());
            } catch (Error e) { }
        }

        private void clear_cache() {
            FileUtils.unlink(_cache_path);
        }
    }
}
