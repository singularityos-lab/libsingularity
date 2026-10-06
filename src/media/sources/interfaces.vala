namespace Singularity.MediaSources {

    public interface MediaHost : Object {
        public signal void accounts_changed();
        public signal void visibility_changed();

        public abstract string app_id { owned get; }
        public abstract MediaKind kinds { get; }
        public abstract string user_agent { owned get; }
        public abstract Soup.Session session { get; }
        public abstract bool network_available { get; }
        public abstract bool window_visible { get; }

        public abstract string cache_dir(string source_id);
        public abstract string? get_value(string source_id, string key);
        public abstract void set_value(string source_id, string key, string? value);
        public abstract Gee.List<Singularity.Accounts.Account> accounts(Singularity.Accounts.Capability capability);
        public abstract void show_message(string source_id, string message);
        public abstract void open_external(string uri);
    }

    public interface MediaSource : Object {
        public signal void changed();

        public abstract string id { owned get; }
        public abstract string title { owned get; }
        public abstract string icon_name { owned get; }
        public abstract MediaKind kinds { get; }
        public abstract SourceFeatures features { get; }
        public abstract string? account_capability { owned get; }

        public abstract void activate(MediaHost host);
        public abstract void deactivate();
    }

    public interface SourceAvailability : Object {
        public abstract bool available { get; }
        public abstract string unavailable_reason { owned get; }

        public static bool is_available(MediaSource source) {
            var a = source as SourceAvailability;
            return a == null || a.available;
        }
    }

    public interface Browsable : Object {
        public abstract async MediaPage browse(string? node, string? token, Cancellable? cancellable) throws Error;
    }

    public interface Searchable : Object {
        public abstract async MediaPage search(string query, MediaKind kinds, string? token, Cancellable? cancellable) throws Error;
    }

    public class Playback : Object {
        private HashTable<string, string> _headers = new HashTable<string, string>(str_hash, str_equal);

        public PlaybackKind kind { get; construct; }
        public string uri { get; set; default = ""; }
        public string mime_type { get; set; default = ""; }
        public int64 start_ms { get; set; default = 0; }
        public EmbeddedPlayer? embed { get; set; default = null; }
        public RemotePlayer? remote { get; set; default = null; }

        public Playback(PlaybackKind kind) {
            Object(kind: kind);
        }

        public static Playback stream(string uri) {
            var p = new Playback(PlaybackKind.STREAM);
            p.uri = uri;
            return p;
        }

        public static Playback external(string uri) {
            var p = new Playback(PlaybackKind.EXTERNAL);
            p.uri = uri;
            return p;
        }

        public static Playback embedded(EmbeddedPlayer player) {
            var p = new Playback(PlaybackKind.EMBED);
            p.embed = player;
            return p;
        }

        public static Playback remote_control(RemotePlayer player) {
            var p = new Playback(PlaybackKind.REMOTE);
            p.remote = player;
            return p;
        }

        public void set_header(string name, string value) {
            _headers.insert(name, value);
        }

        public string? get_header(string name) {
            return _headers.lookup(name);
        }

        public string[] get_header_names() {
            string[] names = {};
            foreach (var k in _headers.get_keys()) names += k;
            return names;
        }
    }

    public interface PlaybackResolver : Object {
        public abstract async Playback resolve(MediaItem item, Cancellable? cancellable) throws Error;
    }

    public class RemoteDevice : Object {
        public string id { get; construct; }
        public string name { get; construct; }
        public string device_type { get; set; default = "computer"; }
        public bool active { get; set; default = false; }
        public bool restricted { get; set; default = false; }
        public int volume { get; set; default = -1; }

        public RemoteDevice(string id, string name) {
            Object(id: id, name: name);
        }
    }

    public interface RemotePlayer : Object {
        public signal void state_changed();

        public abstract PlaybackState state { get; }
        public abstract MediaItem? current { owned get; }
        public abstract int64 position_ms { get; }
        public abstract int64 duration_ms { get; }
        public abstract double volume { get; }
        public abstract RemoteDevice? device { owned get; }

        public abstract async Gee.List<RemoteDevice> devices(Cancellable? cancellable) throws Error;
        public abstract async void transfer(string device_id, bool play) throws Error;
        public abstract async void play_item(MediaItem item, MediaItem? context) throws Error;
        public abstract async void resume() throws Error;
        public abstract async void pause() throws Error;
        public abstract async void next() throws Error;
        public abstract async void previous() throws Error;
        public abstract async void seek(int64 position_ms) throws Error;
        public abstract async void set_volume(double volume) throws Error;
        public abstract void set_active(bool active);
    }

    public interface LocalReceiver : Object {
        public signal void receiver_changed();
        public signal void sign_in_needed(string url);

        public abstract bool installed { get; }
        public abstract bool running { get; }
        public abstract bool signed_in { get; }
        public abstract string device_name { owned get; }
        public abstract string pcm_path { owned get; }
        public abstract int sample_rate { get; }
        public abstract int channels { get; }
        public abstract string status_text { owned get; }

        public abstract void start();
        public abstract void stop();
    }

    public interface RemoteQueue : Object {
        public abstract async void add_to_queue(MediaItem item) throws Error;
    }

    public interface EmbeddedPlayer : Object {
        public signal void state_changed();
        public signal void ended();
        public signal void failed(string message);

        public abstract Gtk.Widget widget { get; }
        public abstract int min_width { get; }
        public abstract int min_height { get; }
        public abstract PlaybackState state { get; }
        public abstract int64 position_ms { get; }
        public abstract int64 duration_ms { get; }
        public abstract double volume { get; }

        public abstract void load(MediaItem item, int64 start_ms);
        public abstract void play();
        public abstract void pause();
        public abstract void seek(int64 position_ms);
        public abstract void set_volume(double volume);
        public abstract void stop();
    }

    public interface Scrobbler : Object {
        public abstract bool enabled { get; }
        public abstract async void now_playing(MediaItem item, Cancellable? cancellable) throws Error;
        public abstract async void listened(MediaItem item, int64 played_ms, DateTime started, Cancellable? cancellable) throws Error;

        public static bool counts_as_listen(int64 duration_ms, int64 played_ms) {
            if (duration_ms > 0 && duration_ms < 30000) return false;
            if (played_ms >= 240000) return true;
            return duration_ms > 0 && played_ms * 2 >= duration_ms;
        }
    }

    public interface MetadataProvider : Object {
        public abstract async Lyrics? lyrics(MediaItem item, Cancellable? cancellable) throws Error;
        public abstract async MediaItem? enrich(MediaItem item, Cancellable? cancellable) throws Error;
    }
}
