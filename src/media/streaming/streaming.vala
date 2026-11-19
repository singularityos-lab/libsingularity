namespace Singularity.Streaming {

    public errordomain StreamingError {
        NETWORK,
        PROTOCOL
    }

    public enum TitleKind {
        MOVIE,
        SERIES;

        public string to_id() {
            return this == SERIES ? "series" : "movie";
        }

        public static TitleKind parse(string id) {
            return id == "series" ? SERIES : MOVIE;
        }
    }

    public class Platform : Object {
        public string id { get; construct; }
        public string name { get; construct; }
        public string home { get; construct; }

        private string[] _hosts;
        private static GenericArray<Platform>? _all = null;

        public Platform(string id, string name, string home, string[] hosts) {
            Object(id: id, name: name, home: home);
            _hosts = hosts;
        }

        public string app_id {
            owned get { return Singularity.AppLinks.web_app_id(id); }
        }

        public bool installed {
            get { return Singularity.AppLinks.installed(app_id); }
        }

        public bool serves(string uri) {
            string? host = null;
            try {
                host = Uri.parse(uri, UriFlags.NONE).get_host();
            } catch (UriError e) {
                return false;
            }
            if (host == null) return false;
            host = host.down();
            foreach (string h in _hosts) {
                if (host == h || host.has_suffix("." + h)) return true;
            }
            return false;
        }

        public static GenericArray<Platform> all() {
            if (_all != null) return _all;
            _all = new GenericArray<Platform>();
            _all.add(new Platform("netflix", "Netflix", "https://www.netflix.com", { "netflix.com" }));
            _all.add(new Platform("primevideo", "Prime Video", "https://www.primevideo.com", { "primevideo.com" }));
            _all.add(new Platform("disneyplus", "Disney+", "https://www.disneyplus.com", { "disneyplus.com" }));
            _all.add(new Platform("appletv", "Apple TV+", "https://tv.apple.com", { "tv.apple.com" }));
            _all.add(new Platform("max", "Max", "https://play.max.com", { "max.com", "hbomax.com" }));
            _all.add(new Platform("youtube", "YouTube", "https://www.youtube.com", { "youtube.com" }));
            _all.add(new Platform("crunchyroll", "Crunchyroll", "https://www.crunchyroll.com", { "crunchyroll.com" }));
            _all.add(new Platform("raiplay", "RaiPlay", "https://www.raiplay.it", { "raiplay.it" }));
            _all.add(new Platform("mediasetinfinity", "Mediaset Infinity", "https://mediasetinfinity.mediaset.it", { "mediasetinfinity.mediaset.it", "mediasetinfinity.it" }));
            _all.add(new Platform("dazn", "DAZN", "https://www.dazn.com", { "dazn.com" }));
            _all.add(new Platform("plutotv", "Pluto TV", "https://pluto.tv", { "pluto.tv" }));
            _all.add(new Platform("plex", "Plex", "https://app.plex.tv", { "plex.tv" }));
            return _all;
        }

        public static Platform? lookup(string id) {
            foreach (var p in all()) {
                if (p.id == id) return p;
            }
            return null;
        }

        public static Platform? for_uri(string uri) {
            foreach (var p in all()) {
                if (p.serves(uri)) return p;
            }
            return null;
        }
    }

    public class Offer : Object {
        public Platform platform { get; construct; }
        public string? url { get; set; default = null; }
        public string? logo_uri { get; set; default = null; }

        public Offer(Platform platform) {
            Object(platform: platform);
        }

        public string link() {
            return url != null && platform.serves(url) ? url : platform.home;
        }
    }

    public class Title : Object {
        public string id { get; construct; }
        public TitleKind kind { get; construct; }
        public string name { get; set; default = ""; }
        public string overview { get; set; default = ""; }
        public string? backdrop_uri { get; set; default = null; }
        public string? poster_uri { get; set; default = null; }
        public int year { get; set; default = 0; }
        public GenericArray<Offer> offers { get; set; default = new GenericArray<Offer>(); }

        public Title(string id, TitleKind kind) {
            Object(id: id, kind: kind);
        }

        public Offer? best_offer() {
            foreach (var o in offers) {
                if (o.platform.installed) return o;
            }
            return offers.length > 0 ? offers[0] : null;
        }

        public Offer? offer_on(string platform_id) {
            foreach (var o in offers) {
                if (o.platform.id == platform_id) return o;
            }
            return null;
        }
    }

    public interface Backend : Object {
        public abstract string id { owned get; }
        public abstract string name { owned get; }

        public abstract async GenericArray<Title> featured(Config config, int limit, Cancellable? cancellable) throws Error;
    }

    public class Config : Object {
        public string country { get; private set; default = "US"; }
        public string language { get; private set; default = "en"; }

        public static Config from_locale() {
            var c = new Config();
            foreach (string name in Intl.get_language_names()) {
                string tag = name.split(".")[0].split("@")[0];
                string[] parts = tag.split("_");
                if (parts.length != 2 || parts[0].length != 2 || parts[1].length != 2) continue;
                c.language = parts[0].down();
                c.country = parts[1].up();
                break;
            }
            return c;
        }
    }
}
