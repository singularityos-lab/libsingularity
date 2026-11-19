namespace Singularity.Streaming {

    public class JustWatchBackend : Object, Backend {
        private const string API = "https://apis.justwatch.com/graphql";
        private const string IMAGES = "https://images.justwatch.com";
        private const int64 LIMIT = 4 * 1024 * 1024;
        private const int CANDIDATES = 40;
        private const string QUERY = "query($c:Country!,$l:Language!,$n:Int!){popularTitles(country:$c,first:$n){edges{node{id objectType content(country:$c,language:$l){title shortDescription originalReleaseYear posterUrl backdrops{backdropUrl}} offers(country:$c,platform:WEB){monetizationType standardWebURL package{clearName technicalName icon}}}}}}";

        private Soup.Session _session;

        public JustWatchBackend(Soup.Session session) {
            _session = session;
        }

        public string id { owned get { return "justwatch"; } }
        public string name { owned get { return "JustWatch"; } }

        public async GenericArray<Title> featured(Config config, int limit, Cancellable? cancellable) throws Error {
            var root = yield post(config, CANDIDATES, cancellable);
            var installed = new GenericArray<Title>();
            var available = new GenericArray<Title>();
            var popular = root.get_object_member("popularTitles");
            if (popular == null || !popular.has_member("edges")) return installed;
            foreach (var edge in popular.get_array_member("edges").get_elements()) {
                if (edge.get_node_type() != Json.NodeType.OBJECT) continue;
                var node = edge.get_object().get_object_member("node");
                if (node == null) continue;
                var title = parse_title(node);
                if (title == null || title.offers.length == 0) continue;
                if (title.best_offer().platform.installed) installed.add(title);
                else available.add(title);
            }
            for (uint i = 0; i < available.length; i++) installed.add(available[i]);
            if (installed.length > limit) installed.remove_range(limit, installed.length - limit);
            return installed;
        }

        private Title? parse_title(Json.Object node) {
            string id = node.get_string_member_with_default("id", "");
            string type = node.get_string_member_with_default("objectType", "");
            if (id == "" || (type != "MOVIE" && type != "SHOW")) return null;
            var content = node.get_object_member("content");
            if (content == null) return null;
            string name = content.get_string_member_with_default("title", "");
            string overview = content.get_string_member_with_default("shortDescription", "") ?? "";
            string? backdrop = null;
            if (content.has_member("backdrops") && content.get_member("backdrops").get_node_type() == Json.NodeType.ARRAY) {
                foreach (var b in content.get_array_member("backdrops").get_elements()) {
                    if (b.get_node_type() != Json.NodeType.OBJECT) continue;
                    backdrop = string_member(b.get_object(), "backdropUrl");
                    if (backdrop != null) break;
                }
            }
            if (name == "" || backdrop == null) return null;
            var title = new Title("justwatch:" + id, type == "SHOW" ? TitleKind.SERIES : TitleKind.MOVIE);
            title.name = name;
            title.overview = strip_markup(overview);
            title.backdrop_uri = image(backdrop, "s1920");
            string? poster = string_member(content, "posterUrl");
            if (poster != null) title.poster_uri = image(poster, "s332");
            title.year = (int) content.get_int_member_with_default("originalReleaseYear", 0);
            if (node.has_member("offers") && node.get_member("offers").get_node_type() == Json.NodeType.ARRAY) {
                foreach (var o in node.get_array_member("offers").get_elements()) {
                    if (o.get_node_type() == Json.NodeType.OBJECT) add_offer(title, o.get_object());
                }
            }
            return title;
        }

        private void add_offer(Title title, Json.Object o) {
            string type = o.get_string_member_with_default("monetizationType", "");
            if (type != "FLATRATE" && type != "FREE" && type != "ADS") return;
            string? url = string_member(o, "standardWebURL");
            var package = o.get_object_member("package");
            if (package == null) return;
            var platform = platform_for(package.get_string_member_with_default("technicalName", ""), url);
            if (platform == null || title.offer_on(platform.id) != null) return;
            var offer = new Offer(platform);
            offer.url = url;
            string? icon = string_member(package, "icon");
            if (icon != null) offer.logo_uri = image(icon, "s100");
            title.offers.add(offer);
        }

        public static Platform? platform_for(string technical_name, string? url) {
            string? id = null;
            switch (technical_name) {
                case "netflix": case "netflixbasicwithads": id = "netflix"; break;
                case "amazonprimevideo": case "amazonprimevideowithads": case "amazonprime": case "primevideo": id = "primevideo"; break;
                case "disneyplus": id = "disneyplus"; break;
                case "appletvplus": case "appletv": id = "appletv"; break;
                case "max": case "hbomax": case "maxamazonchannel": id = "max"; break;
                case "youtube": case "youtubefree": case "youtubepremium": id = "youtube"; break;
                case "crunchyroll": id = "crunchyroll"; break;
                case "raiplay": id = "raiplay"; break;
                case "mediasetinfinity": case "mediasetplay": case "mediasetinfinityplus": id = "mediasetinfinity"; break;
                case "dazn": id = "dazn"; break;
                case "plutotv": id = "plutotv"; break;
                case "plex": case "plexplayer": id = "plex"; break;
            }
            if (id != null) return Platform.lookup(id);
            return url != null ? Platform.for_uri(url) : null;
        }

        private static string image(string path, string profile) {
            return IMAGES + path.replace("{profile}", profile).replace("{format}", "jpg");
        }

        private static string strip_markup(string text) {
            try {
                return new Regex("<[^>]*>").replace(text, -1, 0, "").strip();
            } catch (RegexError e) {
                return text.strip();
            }
        }

        private async Json.Object post(Config config, int count, Cancellable? cancellable) throws Error {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("query").add_string_value(QUERY);
            b.set_member_name("variables").begin_object();
            b.set_member_name("c").add_string_value(config.country);
            b.set_member_name("l").add_string_value(config.language);
            b.set_member_name("n").add_int_value(count);
            b.end_object();
            b.end_object();
            var gen = new Json.Generator();
            gen.root = b.get_root();
            var message = new Soup.Message("POST", API);
            message.set_request_body_from_bytes("application/json", new Bytes(gen.to_data(null).data));
            message.request_headers.append("Accept", "application/json");
            Bytes body;
            try {
                body = yield Singularity.HttpBody.read(_session, message, LIMIT, Priority.LOW, cancellable);
            } catch (IOError.CANCELLED e) {
                throw e;
            } catch (Error e) {
                throw new StreamingError.NETWORK(e.message);
            }
            if (message.status_code != 200) throw new StreamingError.NETWORK("Catalog answered %u".printf(message.status_code));
            var parser = new Json.Parser();
            parser.load_from_data((string) body.get_data(), (ssize_t) body.get_size());
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) throw new StreamingError.PROTOCOL("Unexpected answer");
            var data = root.get_object().get_object_member("data");
            if (data == null || !data.has_member("popularTitles")) throw new StreamingError.PROTOCOL("Unexpected answer");
            return data;
        }

        private static string? string_member(Json.Object o, string key) {
            if (!o.has_member(key)) return null;
            var node = o.get_member(key);
            if (node.get_node_type() != Json.NodeType.VALUE || node.get_value_type() != typeof(string)) return null;
            string v = node.get_string();
            return v != "" ? v : null;
        }
    }
}
