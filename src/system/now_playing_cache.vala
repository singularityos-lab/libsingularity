using GLib;

namespace Singularity {

    public class NowPlayingCache : Object {
        private const int MAX_ART_BYTES = 16 * 1024 * 1024;
        private static NowPlayingCache? _instance = null;
        public static NowPlayingCache get_default() {
            if (_instance == null) _instance = new NowPlayingCache();
            return _instance;
        }

        private DBusConnection? connection = null;
        private string? current_player_name = null;
        private uint _name_watch_id = 0;
        private uint _properties_watch_id = 0;
        private string? _last_art_url = null;
        private string _cache_path;
        private string _cache_dir;
        private Soup.Session? _soup = null;

        public string title { get; private set; default = ""; }
        public string artist { get; private set; default = ""; }
        public string app_id { get; private set; default = ""; }
        public bool playing { get; private set; default = false; }
        public string cover_path { get; private set; default = ""; }
        public uint cover_serial { get; private set; default = 0; }
        public bool active { get { return current_player_name != null; } }

        public signal void changed();

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
                        disconnect_player();
                        current_player_name = null;
                        clear_cache();
                        reset_state();
                        find_player.begin();
                    }
                });

            find_player.begin();
        }

        private async void find_player() {
            var bus = connection;
            if (bus == null) return;
            try {
                var result = yield bus.call(
                    "org.freedesktop.DBus", "/org/freedesktop/DBus",
                    "org.freedesktop.DBus", "ListNames", null,
                    new VariantType("(as)"), DBusCallFlags.NONE, 1000, null);
                VariantIter iter;
                result.get("(as)", out iter);
                string? best_name = null;
                string? name;
                while (iter.next("s", out name)) {
                    if (name == null) continue;
                    if (!name.has_prefix("org.mpris.MediaPlayer2.")) continue;
                    if (best_name == null) best_name = name;
                    if (yield player_is_playing(name)) {
                        best_name = name;
                        break;
                    }
                }
                if (best_name != null) connect_to_player(best_name);
            } catch (Error e) { }
        }

        private async bool player_is_playing(string name) {
            var bus = connection;
            if (bus == null) return false;
            try {
                var result = yield bus.call(name, "/org/mpris/MediaPlayer2",
                    "org.freedesktop.DBus.Properties", "Get",
                    new Variant("(ss)", "org.mpris.MediaPlayer2.Player",
                        "PlaybackStatus"),
                    new VariantType("(v)"), DBusCallFlags.NONE, 500, null);
                return result.get_child_value(0).get_variant().get_string()
                    == "Playing";
            } catch (Error e) {
                return false;
            }
        }

        private void connect_to_player(string name) {
            var bus = connection;
            if (bus == null || name == current_player_name) return;
            disconnect_player();
            current_player_name = name;
            _last_art_url = null;
            _properties_watch_id = bus.signal_subscribe(name,
                "org.freedesktop.DBus.Properties", "PropertiesChanged",
                "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player",
                DBusSignalFlags.NONE,
                (conn, sender, path, iface, sig, parameters) => {
                    refresh.begin(name);
                });
            load_identity.begin(name);
            refresh.begin(name);
        }

        private void reset_state() {
            title = "";
            artist = "";
            app_id = "";
            playing = false;
            cover_path = "";
            changed();
        }

        private async void load_identity(string name) {
            var bus = connection;
            if (bus == null) return;
            string entry = "";
            try {
                var result = yield bus.call(name, "/org/mpris/MediaPlayer2",
                    "org.freedesktop.DBus.Properties", "Get",
                    new Variant("(ss)", "org.mpris.MediaPlayer2", "DesktopEntry"),
                    new VariantType("(v)"), DBusCallFlags.NONE, 1000, null);
                var v = result.get_child_value(0).get_variant();
                if (v.is_of_type(VariantType.STRING)) entry = v.get_string();
            } catch (Error e) { }
            if (name != current_player_name) return;
            app_id = entry;
            changed();
        }

        private async void refresh(string name) {
            var bus = connection;
            if (bus == null || name != current_player_name) return;
            try {
                var result = yield bus.call(name, "/org/mpris/MediaPlayer2",
                    "org.freedesktop.DBus.Properties", "GetAll",
                    new Variant("(s)", "org.mpris.MediaPlayer2.Player"),
                    new VariantType("(a{sv})"), DBusCallFlags.NONE, 1000, null);
                if (name != current_player_name) return;
                var props = result.get_child_value(0);
                var status = props.lookup_value("PlaybackStatus", VariantType.STRING);
                bool now_playing = status != null && status.get_string() == "Playing";
                var metadata = props.lookup_value("Metadata", null);
                string new_title = "";
                string new_artist = "";
                if (metadata != null) {
                    var t = metadata.lookup_value("xesam:title", VariantType.STRING);
                    if (t != null) new_title = t.get_string();
                    var a = metadata.lookup_value("xesam:artist", null);
                    if (a != null && a.is_of_type(VariantType.STRING_ARRAY)) new_artist = string.joinv(", ", a.get_strv());
                    else if (a != null && a.is_of_type(VariantType.STRING)) new_artist = a.get_string();
                    update_art(metadata);
                }
                if (now_playing != playing || new_title != title || new_artist != artist) {
                    playing = now_playing;
                    title = new_title;
                    artist = new_artist;
                    changed();
                }
            } catch (Error e) { }
        }

        public async void play_pause() {
            yield control("PlayPause");
        }

        public async void next() {
            yield control("Next");
        }

        public async void previous() {
            yield control("Previous");
        }

        private async void control(string method) {
            var bus = connection;
            if (bus == null || current_player_name == null) return;
            try {
                yield bus.call(current_player_name, "/org/mpris/MediaPlayer2",
                    "org.mpris.MediaPlayer2.Player", method, null, null,
                    DBusCallFlags.NONE, 1000, null);
            } catch (Error e) {
                warning("NowPlayingCache: %s failed: %s", method, e.message);
            }
        }

        private void disconnect_player() {
            if (_properties_watch_id != 0 && connection != null) {
                connection.signal_unsubscribe(_properties_watch_id);
                _properties_watch_id = 0;
            }
        }

        private void update_art(Variant metadata) {
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
                load_cover();
            } catch (Error e) {
                clear_cache();
            }
        }

        private async void download_remote(string url) {
            if (_soup == null) _soup = new Soup.Session();
            try {
                var msg = new Soup.Message("GET", url);
                var stream = yield _soup.send_async(msg, Priority.DEFAULT, null);
                var body = new ByteArray();
                var chunk = new uint8[65536];
                ssize_t n;
                while ((n = yield stream.read_async(chunk, Priority.DEFAULT, null)) > 0) {
                    if (body.len + n > MAX_ART_BYTES) break;
                    body.append(chunk[0:(int) n]);
                }
                yield stream.close_async(Priority.DEFAULT, null);
                if (msg.status_code != 200 || body.len == 0 || n > 0) return;
                FileUtils.set_data(_cache_path, body.data);
                load_cover();
            } catch (Error e) { }
        }

        private void clear_cache() {
            FileUtils.unlink(_cache_path);
            if (cover_path != "") {
                cover_path = "";
                changed();
            }
        }

        private void load_cover() {
            cover_path = _cache_path;
            cover_serial++;
            changed();
        }
    }
}
