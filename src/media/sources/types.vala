namespace Singularity.MediaSources {

    public const int API_VERSION = 1;

    public errordomain MediaError {
        NOT_FOUND,
        NEEDS_ACCOUNT,
        NOT_CONFIGURED,
        AUTH_FAILED,
        NETWORK,
        RATE_LIMITED,
        UNSUPPORTED,
        PROTOCOL
    }

    [Flags]
    public enum MediaKind {
        AUDIO,
        VIDEO;

        public static MediaKind parse(string text) {
            MediaKind kinds = 0;
            foreach (unowned string part in text.split(";")) {
                string p = part.strip().down();
                if (p == "audio" || p == "music") kinds |= AUDIO;
                else if (p == "video" || p == "videos") kinds |= VIDEO;
            }
            return kinds;
        }
    }

    public enum ItemKind {
        TRACK,
        ALBUM,
        ARTIST,
        PLAYLIST,
        VIDEO,
        CHANNEL,
        EPISODE,
        FOLDER,
        GENRE,
        STATION;

        public string to_id() {
            switch (this) {
                case TRACK: return "track";
                case ALBUM: return "album";
                case ARTIST: return "artist";
                case PLAYLIST: return "playlist";
                case VIDEO: return "video";
                case CHANNEL: return "channel";
                case EPISODE: return "episode";
                case GENRE: return "genre";
                case STATION: return "station";
                default: return "folder";
            }
        }

        public static bool try_parse(string id, out ItemKind result) {
            foreach (var k in all()) {
                if (k.to_id() == id) {
                    result = k;
                    return true;
                }
            }
            result = FOLDER;
            return false;
        }

        public static ItemKind[] all() {
            return { TRACK, ALBUM, ARTIST, PLAYLIST, VIDEO, CHANNEL, EPISODE, FOLDER, GENRE, STATION };
        }

        public bool is_container() {
            return this != TRACK && this != VIDEO && this != EPISODE;
        }
    }

    [Flags]
    public enum SourceFeatures {
        BROWSE,
        SEARCH,
        PLAY,
        REMOTE,
        EMBED,
        SCROBBLE,
        METADATA,
        LYRICS,
        ISOLATED
    }

    public enum PlaybackKind {
        STREAM,
        EMBED,
        REMOTE,
        EXTERNAL
    }

    public enum PlaybackState {
        STOPPED,
        PLAYING,
        PAUSED,
        BUFFERING
    }

    public class MediaItem : Object {
        private HashTable<string, string> _extra = new HashTable<string, string>(str_hash, str_equal);

        public string id { get; construct; }
        public string source_id { get; construct; }
        public ItemKind kind { get; construct; }
        public string title { get; set; default = ""; }
        public string subtitle { get; set; default = ""; }
        public string artist { get; set; default = ""; }
        public string album { get; set; default = ""; }
        public int track_number { get; set; default = 0; }
        public int year { get; set; default = 0; }
        public int64 duration_ms { get; set; default = 0; }
        public string image_url { get; set; default = ""; }
        public string external_url { get; set; default = ""; }
        public string external_label { get; set; default = ""; }
        public string attribution { get; set; default = ""; }
        public string stream_uri { get; set; default = ""; }
        public bool playable { get; set; default = true; }
        public bool browsable { get; set; default = false; }

        public MediaItem(string source_id, string id, ItemKind kind, string title = "") {
            Object(source_id: source_id, id: id, kind: kind, title: title, browsable: kind.is_container(), playable: !kind.is_container());
        }

        public string key {
            owned get { return source_id + ":" + id; }
        }

        public string? get_extra(string name) {
            return _extra.lookup(name);
        }

        public void set_extra(string name, string? value) {
            if (value == null) _extra.remove(name);
            else _extra.insert(name, value);
        }

        public string[] get_extra_keys() {
            string[] keys = {};
            foreach (var k in _extra.get_keys()) keys += k;
            return keys;
        }

        public MediaItem copy() {
            var c = new MediaItem(source_id, id, kind, title);
            c.subtitle = subtitle;
            c.artist = artist;
            c.album = album;
            c.track_number = track_number;
            c.year = year;
            c.duration_ms = duration_ms;
            c.image_url = image_url;
            c.external_url = external_url;
            c.external_label = external_label;
            c.attribution = attribution;
            c.stream_uri = stream_uri;
            c.playable = playable;
            c.browsable = browsable;
            foreach (var k in _extra.get_keys()) c.set_extra(k, _extra.lookup(k));
            return c;
        }

        public string display_duration() {
            if (duration_ms <= 0) return "";
            int64 secs = duration_ms / 1000;
            if (secs >= 3600) return "%d:%02d:%02d".printf((int) (secs / 3600), (int) (secs / 60 % 60), (int) (secs % 60));
            return "%d:%02d".printf((int) (secs / 60), (int) (secs % 60));
        }
    }

    public class MediaPage : Object {
        public string title { get; set; default = ""; }
        public string? next_token { get; set; default = null; }
        public int total { get; set; default = -1; }
        public string notice { get; set; default = ""; }
        public string action_label { get; set; default = ""; }
        public string action_uri { get; set; default = ""; }
        public Gee.ArrayList<MediaItem> items { get; private set; default = new Gee.ArrayList<MediaItem>(); }

        public MediaPage(string title = "") {
            Object(title: title);
        }

        public void add(MediaItem item) {
            items.add(item);
        }

        public bool has_more {
            get { return next_token != null && next_token != ""; }
        }
    }

    public class Paging : Object {
        public static int offset_of(string? token) {
            if (token == null || token == "") return 0;
            int64 v;
            if (int64.try_parse(token, out v) && v > 0) return (int) v;
            return 0;
        }

        public static string? next_of(int offset, int count, int total) {
            int next = offset + count;
            if (count <= 0 || (total >= 0 && next >= total)) return null;
            return next.to_string();
        }
    }
}
