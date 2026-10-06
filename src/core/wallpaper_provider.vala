using GLib;
using Gee;

namespace Singularity {

    public errordomain WallpaperOcsError { INVALID }

    /** A single browsable category, market, or collection offered by a provider. */
    public class WallpaperProviderChoice : Object {
        public string id;
        public string name;
        public WallpaperProviderChoice(string id, string name) { this.id = id; this.name = name; }
    }

    /** A single wallpaper offered by a WallpaperProvider, ready to display or import. */
    public class WallpaperItem : Object {
        // Provider that owns the item. A provider may expose a second
        // identity axis (for example a network name) in provider_id while
        // still handling the item through its own plugin.
        public string owner_id = "";
        public string provider_id = "";
        public string id = "";
        public string name = "";
        public string author = "";
        public string license = "";
        public string preview = "";
        public string full_res_url = "";
        public string attribution = "";
        public string page_url = "";
        public string creator_url = "";
        public string license_url = "";
        public int width = 0;
        public int height = 0;
        // Tags emitted per item by the OCS browse response (JSON array of
        // plain strings, possibly empty). Parsed leniently: absent field or
        // explicit empty array both become an empty list, matching how the
        // other optional string fields default to "". A value that is not
        // an array of strings is a parse error, consistent with the other
        // shape checks in this class.
        public string[] tags = {};
        // Bing/local-provider fields. Defaults keep the OCS shape unchanged:
        // every OCS item has an empty thumbnail_path (the Soup thumbnail
        // path uses item.preview, a remote URL), is not pinned, and has no
        // market. Providers that only ever serve local files (Bing's own
        // archive, the built-in Singularity provider) set thumbnail_path
        // to a real filesystem path instead of a remote preview URL.
        public string thumbnail_path = "";
        /**
         * A local image the browser applies directly with
         * `LocalWallpaper.apply`, without `import_item` or a wallpaper pack.
         */
        public string local_path = "";
        public bool pinned = false;
        public string market = "";
        public string archive_date = "";
        public string bing_image_id = "";
        // Canonical identity. For OCS this is "provider:numeric_id"; for Bing
        // it is "provider:market:Bing-image-id", falling back to archive date
        // for metadata written by older helpers. Keeping `key` stable
        // across both item kinds means add_card / filter_cards / the imports
        // map do not need a parallel data path.
        public string key { owned get { return provider_id + ":" + id; } }
    }

    // JSON from a helper process is untrusted. Check types before Json-GLib
    // getters, which otherwise emit criticals (fatal in the GLib.Test harness).
    public class WallpaperOcs : Object {
        private const int TAG_CHARACTER_LIMIT = 64;

        public static Json.Object object_node(Json.Node? node) throws Error {
            if (node == null || node.get_node_type() != Json.NodeType.OBJECT)
                throw new WallpaperOcsError.INVALID("Expected a JSON object");
            return node.get_object();
        }
        public static Json.Object document(string data, bool schema = true) throws Error {
            var parser = new Json.Parser();
            parser.load_from_data(data);
            var obj = object_node(parser.get_root());
            if (schema) {
                var node = obj.get_member("schema");
                if (node == null || node.get_value_type() != typeof(int64) || node.get_int() != 1)
                    throw new WallpaperOcsError.INVALID("Unsupported OCS response schema");
            }
            return obj;
        }
        public static string text(Json.Object obj, string field, bool required = true) throws Error {
            var node = obj.get_member(field);
            if (node == null || node.is_null()) {
                if (!required) return "";
                throw new WallpaperOcsError.INVALID("Missing OCS field: " + field);
            }
            if (node.get_value_type() != typeof(string))
                throw new WallpaperOcsError.INVALID("Invalid OCS field: " + field);
            string value = node.get_string();
            if (required && value.strip() == "")
                throw new WallpaperOcsError.INVALID("Empty OCS field: " + field);
            return value;
        }
        public static Json.Array array(Json.Object obj, string field) throws Error {
            var node = obj.get_member(field);
            if (node == null || node.get_node_type() != Json.NodeType.ARRAY)
                throw new WallpaperOcsError.INVALID("Invalid OCS list: " + field);
            return node.get_array();
        }
        // Tags are emitted as a JSON array of strings. Absent field or empty
        // array both collapse to an empty list; anything else (non-array, or
        // any non-string element) is rejected so a malformed response cannot
        // silently degrade the filter UI.
        public static string[] tag_array(Json.Object obj, string field) throws Error {
            var node = obj.get_member(field);
            if (node == null || node.is_null()) return {};
            if (node.get_node_type() != Json.NodeType.ARRAY)
                throw new WallpaperOcsError.INVALID("Invalid OCS list: " + field);
            var arr = node.get_array();
            var result = new Gee.ArrayList<string>();
            foreach (var element in arr.get_elements()) {
                if (element == null || element.get_value_type() != typeof(string))
                    throw new WallpaperOcsError.INVALID("Invalid OCS tag entry: " + field);
                var sanitized = new StringBuilder();
                int index = 0;
                int characters = 0;
                unichar c = 0;
                string raw = element.get_string();
                while (characters < TAG_CHARACTER_LIMIT && raw.get_next_char(ref index, out c)) {
                    var type = c.type();
                    if (type == UnicodeType.FORMAT ||
                        (type == UnicodeType.CONTROL && !c.isspace())) continue;
                    sanitized.append_unichar(c);
                    characters++;
                }
                string t = sanitized.str.strip();
                if (t != "" && !result.contains(t)) result.add(t);
            }
            return result.to_array();
        }
        public static int optional_int(Json.Object obj, string field) throws Error {
            var node = obj.get_member(field);
            if (node == null || node.is_null()) return 0;
            if (node.get_value_type() != typeof(int64) || node.get_int() < 0 || node.get_int() > int.MAX)
                throw new WallpaperOcsError.INVALID("Invalid OCS field: " + field);
            return (int) node.get_int();
        }
        public static bool numeric_id(string id) {
            if (id.length == 0) return false;
            foreach (char c in id.to_utf8()) if (c < '0' || c > '9') return false;
            return true;
        }
        public static bool provider_id(string id) {
            return id == "pling" || id == "opendesktop" || id == "kde-look" || id == "gnome-look";
        }
        public static ArrayList<WallpaperProviderChoice> providers(string data) throws Error {
            var obj = object_node(document(data).get_member("providers"));
            var result = new ArrayList<WallpaperProviderChoice>();
            foreach (string id in obj.get_members()) {
                if (!provider_id(id)) throw new WallpaperOcsError.INVALID("Unknown OCS provider: " + id);
                text(object_node(obj.get_member(id)), "base");
                // opendesktop.org is the former name of pling.com. Both API
                // hosts currently expose the same catalog, so showing both
                // only duplicates every result. Keep accepting the legacy id
                // for existing provenance, but expose the current Pling
                // service once in the provider picker.
                if (id == "opendesktop") continue;
                result.add(new WallpaperProviderChoice(id, id));
            }
            result.sort((a, b) => strcmp(a.id, b.id));
            return result;
        }
        public static ArrayList<WallpaperProviderChoice> categories(string data, string provider) throws Error {
            var entries = array(document(data), "entries");
            var seen = new HashSet<string>();
            var result = new ArrayList<WallpaperProviderChoice>();
            foreach (var node in entries.get_elements()) {
                var entry = object_node(node);
                string reference = text(entry, "ref");
                string network = reference.split(":")[0];
                if (!reference.has_prefix(network + ":"))
                    throw new WallpaperOcsError.INVALID("Invalid OCS category reference");
                if (provider == "ocs" ? (!provider_id(network) || network == "opendesktop") : network != provider) continue;
                string id = reference.substring(network.length + 1);
                if (!numeric_id(id)) throw new WallpaperOcsError.INVALID("Invalid OCS category identity");
                var usable = entry.get_member("usable");
                if (usable == null || usable.get_value_type() != typeof(bool))
                    throw new WallpaperOcsError.INVALID("Invalid OCS category usability");
                // The UI exposes all OCS networks as one synthetic "ocs"
                // provider.  Preserve the real network in that provider's
                // choice id so its browse call can address the helper's
                // actual provider grammar.  The helper deliberately does not
                // accept "ocs" as a provider name.
                string choice_id = provider == "ocs" ? reference : id;
                if (!usable.get_boolean() || !seen.add(choice_id)) continue;
                string name = text(entry, "display_name", false);
                if (name == "") name = text(entry, "name");
                result.add(new WallpaperProviderChoice(choice_id, name));
            }
            result.sort((a, b) => a.name.collate(b.name));
            return result;
        }
        public static ArrayList<WallpaperItem> items(string data, string provider, string category) throws Error {
            var obj = document(data);
            if (text(obj, "provider") != provider || text(obj, "category") != category)
                throw new WallpaperOcsError.INVALID("OCS response does not match the requested category");
            var result = new ArrayList<WallpaperItem>();
            var seen = new HashSet<string>();
            foreach (var node in array(obj, "items").get_elements()) {
                var entry = object_node(node);
                var item = new WallpaperItem();
                item.owner_id = provider;
                item.provider_id = text(entry, "provider");
                item.id = text(entry, "id");
                if ((provider != "ocs" && item.provider_id != provider) || !provider_id(item.provider_id) || !numeric_id(item.id))
                    throw new WallpaperOcsError.INVALID("Invalid OCS item identity");
                item.name = text(entry, "name");
                item.author = text(entry, "author", false);
                item.license = text(entry, "license", false);
                item.preview = text(entry, "preview", false);
                item.page_url = text(entry, "detailpage", false);
                var download = entry.get_member("download");
                if (download != null && !download.is_null())
                    item.full_res_url = text(object_node(download), "url", false);
                item.tags = tag_array(entry, "tags");
                if (seen.add(item.key)) result.add(item);
            }
            return result;
        }
    }

    // Bing is not a JSON-over-OCS feed; it talks to its own helper with its
    // own command grammar. Its command and response shapes are kept here,
    // out of WallpaperOcs.providers(), so the OCS parser remains strictly
    // about OCS data. WallpaperBing shares WallpaperProviderChoice so a category
    // chip row can render markets the same way it renders OCS categories,
    // and shares WallpaperItem so the rest of a browser (add_card,
    // filter_cards, thumbnails) keeps a single code path. The Bing-only
    // fields on WallpaperItem (thumbnail_path, pinned, market) default to
    // empty/false for OCS items and are populated by items() below.
    public class WallpaperBing : Object {
        // The synthetic provider id used by every Bing item. Hard-coded so
        // the same string shows up in tests, any browser, and any future
        // call site that needs to recognise Bing.
        public const string PROVIDER_ID = "bing";
        // The pseudo-market id for Bing's de-duplicated combined view.
        //
        // Bing serves the SAME photograph to several regional markets on a
        // given day, so a gallery that merges one listing per market shows
        // the same picture many times over. The helper maintains a
        // content-hashed (sha256, not filename or date) de-duplicated view;
        // `list --consolidated` exposes it to a browser as one row per
        // unique photograph.
        public const string CONSOLIDATED_ID = "consolidated";
        // The helper's `markets` command prints TSV, NOT JSON: one
        // "<market-code>\t<Human Name>" per line. A category chip row
        // expects an ArrayList<WallpaperProviderChoice> just like the OCS
        // categories() does, so we parse the TSV into the same shape.
        // Tolerates trailing whitespace, blank lines, and lines with no tab
        // (those are skipped, not treated as errors -- the helper's real
        // output is well-formed, but the parser is the safety belt).
        public static ArrayList<WallpaperProviderChoice> markets(string data) throws Error {
            var result = new ArrayList<WallpaperProviderChoice>();
            var seen = new HashSet<string>();
            foreach (var raw in data.split("\n")) {
                string line = raw.strip();
                if (line == "") continue;
                int tab = line.index_of("\t");
                if (tab < 0) continue;
                string id = line.substring(0, tab).strip();
                string name = line.substring(tab + 1).strip();
                if (id == "" || name == "") continue;
                if (!seen.add(id)) continue;
                result.add(new WallpaperProviderChoice(id, name));
            }
            result.sort((a, b) => a.name.collate(b.name));
            return result;
        }
        // If markets() found the combined pseudo-market, return a list holding
        // only it; otherwise null, meaning "browse the markets as given".
        //
        // The combined view is a view OVER every market, not one more market
        // beside them, and a browser crawls one listing per choice and
        // merges everything into a single grid -- so offering both would put
        // the de-duplicated set and the raw per-market sets in the same grid
        // and restore precisely the duplication the combined view exists to
        // remove. Split out here so the rule is testable without spawning
        // the helper.
        public static ArrayList<WallpaperProviderChoice>? combined_view(ArrayList<WallpaperProviderChoice> choices) {
            foreach (var choice in choices) {
                if (choice.id != CONSOLIDATED_ID) continue;
                var only = new ArrayList<WallpaperProviderChoice>();
                only.add(choice);
                return only;
            }
            return null;
        }
        // The helper's `list <market>` command returns a JSON ARRAY (no
        // schema/items wrapper, unlike the OCS helper). Each element carries:
        //   provider, date, market, path, caption, copyright,
        //   thumbnail_path, pinned
        // Parse the array into the shared WallpaperItem shape. `id` on the
        // item is set to "<market>:<Bing image id>" so the existing key=
        // "provider:id" formula produces a unique, stable identity per Bing
        // archived image. Tags: Bing has no per-image tags; the field stays
        // empty so filter_cards does not need to special-case anything.
        public static ArrayList<WallpaperItem> items(string data) throws Error {
            var parser = new Json.Parser();
            parser.load_from_data(data);
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.ARRAY)
                throw new WallpaperOcsError.INVALID("Expected a Bing list array");
            var arr = root.get_array();
            var result = new ArrayList<WallpaperItem>();
            var seen = new HashSet<string>();
            foreach (var node in arr.get_elements()) {
                if (node == null || node.get_node_type() != Json.NodeType.OBJECT)
                    throw new WallpaperOcsError.INVALID("Invalid Bing list entry");
                var entry = node.get_object();
                var item = new WallpaperItem();
                item.owner_id = PROVIDER_ID;
                item.provider_id = PROVIDER_ID;
                // Provider field is required and must equal "bing"; this
                // catches a helper that ever emits mixed provider types in
                // the same list.
                if (WallpaperOcs.text(entry, "provider") != PROVIDER_ID)
                    throw new WallpaperOcsError.INVALID("Bing list entry has unexpected provider");
                item.market = WallpaperOcs.text(entry, "market");
                item.archive_date = WallpaperOcs.text(entry, "date");
                item.bing_image_id = WallpaperOcs.text(entry, "image_id", false);
                item.name = WallpaperOcs.text(entry, "caption", false);
                // Composite id keeps item.key unique across markets; this id
                // is purely the identity for add_card / the imports map.
                item.id = item.market + ":" + (item.bing_image_id != "" ? item.bing_image_id : item.archive_date);
                item.author = WallpaperOcs.text(entry, "copyright", false);
                item.license = ""; // Bing does not emit a license field; honest default.
                item.preview = ""; // No remote preview URL for Bing -- the
                                   // thumbnail_path is loaded locally below.
                item.thumbnail_path = WallpaperOcs.text(entry, "thumbnail_path", false);
                var pin = entry.get_member("pinned");
                if (pin == null || pin.get_value_type() != typeof(bool))
                    throw new WallpaperOcsError.INVALID("Invalid Bing pinned field");
                item.pinned = pin.get_boolean();
                // Empty tags stays empty; do NOT synthesise a market-as-tag
                // here -- a market name is not a wallpaper tag, it is a
                // filter axis via the chip row, which already uses
                // categories.
                if (seen.add(item.key)) result.add(item);
            }
            return result;
        }
    }

    // Openverse/Unsplash are photo search APIs. Their
    // helper emits a normalized envelope while retaining per-image licensing
    // and links.
    public class WallpaperOpenverse : Object {
        public static ArrayList<WallpaperItem> items(string data, string expected_provider = "") throws Error {
            var obj = WallpaperOcs.document(data);
            var result = new ArrayList<WallpaperItem>();
            var seen = new HashSet<string>();
            foreach (var node in WallpaperOcs.array(obj, "items").get_elements()) {
                var entry = WallpaperOcs.object_node(node);
                var item = new WallpaperItem();
                item.provider_id = WallpaperOcs.text(entry, "provider");
                item.owner_id = item.provider_id;
                item.id = WallpaperOcs.text(entry, "id");
                if ((item.provider_id != "openverse" && item.provider_id != "unsplash") ||
                    (expected_provider != "" && item.provider_id != expected_provider) ||
                    (item.provider_id == "openverse" && !Uuid.string_is_valid(item.id)) ||
                    (item.provider_id == "unsplash" && (item.id == "" || item.id.length > 64 ||
                     new Regex("[^A-Za-z0-9_-]").match(item.id))))
                    throw new WallpaperOcsError.INVALID("Invalid stock photo identity");
                item.name = WallpaperOcs.text(entry, "name", false);
                item.author = WallpaperOcs.text(entry, "author", false);
                item.preview = WallpaperOcs.text(entry, "preview");
                item.full_res_url = WallpaperOcs.text(entry, "url", false);
                item.license = WallpaperOcs.text(entry, "license") + " " + WallpaperOcs.text(entry, "license_version", false);
                item.attribution = WallpaperOcs.text(entry, "attribution", false);
                item.page_url = WallpaperOcs.text(entry, "page_url", false);
                item.creator_url = WallpaperOcs.text(entry, "creator_url", false);
                item.license_url = WallpaperOcs.text(entry, "license_url", false);
                item.tags = WallpaperOcs.tag_array(entry, "tags");
                item.width = WallpaperOcs.optional_int(entry, "width");
                item.height = WallpaperOcs.optional_int(entry, "height");
                if (seen.add(item.key)) result.add(item);
            }
            return result;
        }
    }

    /** Result of one WallpaperProvider.browse() call. */
    public class WallpaperProviderResult : Object {
        public ArrayList<WallpaperItem> items = new ArrayList<WallpaperItem>();
        public int page_count = 1;
        public bool stale = false;
        public string warning = "";
    }

    /**
     * A source of wallpapers shown in the wallpaper browser.
     *
     * The built-in "singularity" provider (local collections already
     * installed on disk) is always active and is never a plugin. Every
     * other provider (OCS networks, Bing, stock photo search, ...) is
     * registered by a plugin from its `activate()` via
     * `PluginContext.add_wallpaper_provider()`, and is therefore inactive
     * until the user explicitly enables that plugin -- see
     * `WallpaperProviderRegistry`.
     */
    public interface WallpaperProvider : Object {
        public abstract string id { get; }
        public abstract string display_name { owned get; }
        public abstract bool requires_credentials { get; }
        public abstract bool supports_search { get; }
        public abstract async ArrayList<WallpaperProviderChoice> choices(string category_index,
            Cancellable? cancel) throws Error;
        public abstract async WallpaperProviderResult browse(string choice_id, string query,
            int page, bool force_refresh, Cancellable? cancel) throws Error;
        public abstract async string import_item(WallpaperItem item, Cancellable? cancel) throws Error;
    }

    /**
     * Base class for a WallpaperProvider backed by an external helper
     * process. Runs the helper as an async subprocess with a hard timeout
     * and cooperative cancellation; plugins implementing a network-backed
     * provider (an OCS network, Bing, a stock photo search, ...) build on
     * this instead of reimplementing subprocess plumbing.
     */
    public abstract class WallpaperHelperProvider : Object {
        protected string helper;

        protected WallpaperHelperProvider(string helper) {
            this.helper = helper;
        }

        protected async string command(string[] argv, Cancellable? cancel, uint timeout,
            bool force_refresh = false, string? input = null) throws Error {
            var launcher = new SubprocessLauncher(SubprocessFlags.STDIN_PIPE |
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            if (force_refresh) launcher.setenv("SINGULARITY_WALLPAPER_REFRESH", "1", true);
            var process = launcher.spawnv(argv);
            bool timed_out = false;
            uint timer = Timeout.add_seconds(timeout, () => {
                timed_out = true;
                stop_helper(process);
                return Source.REMOVE;
            });
            ulong cancel_handler = 0;
            if (cancel != null) {
                cancel_handler = cancel.cancelled.connect(() => stop_helper(process));
                if (cancel.is_cancelled()) stop_helper(process);
            }
            string output;
            string errors;
            try {
                yield process.communicate_utf8_async(input, null, out output, out errors);
            } catch (Error e) {
                stop_helper(process);
                yield process.wait_async(null);
                throw e;
            } finally {
                if (!timed_out) Source.remove(timer);
                if (cancel_handler != 0) cancel.disconnect(cancel_handler);
            }
            if (cancel != null) cancel.set_error_if_cancelled();
            if (timed_out) throw new IOError.TIMED_OUT("Wallpaper request timed out. Try again.");
            if (!process.get_successful()) {
                string detail = errors.strip();
                if (detail.length > 300) detail = detail.substring(0, 300).make_valid();
                throw new IOError.FAILED(detail != "" ? detail : "Wallpaper helper failed.");
            }
            return output;
        }

        private static void stop_helper(Subprocess process) {
            if (process.get_if_exited()) return;
            process.send_signal(9); // SIGKILL
            process.force_exit();
        }
    }

    /**
     * Global registry of wallpaper providers. Same shape as
     * VpnProviderRegistry / SearchProviderRegistry: the built-in
     * "singularity" provider is added directly at startup; every other
     * provider is registered through PluginContext by a plugin (the
     * signals are funnelled here in main), and stays out of this list
     * entirely until that plugin is enabled. The wallpaper browser
     * subscribes to `changed` to refresh its provider tabs and reads
     * `list()` / `lookup()`.
     */
    public class WallpaperProviderRegistry : Object {
        private static WallpaperProviderRegistry? _instance = null;
        public static WallpaperProviderRegistry get_default() {
            if (_instance == null) _instance = new WallpaperProviderRegistry();
            return _instance;
        }

        /** Emitted whenever a provider is registered or unregistered. */
        public signal void changed();

        private ArrayList<WallpaperProvider> providers = new ArrayList<WallpaperProvider>();

        public void add(WallpaperProvider provider) {
            foreach (var existing in providers) if (existing.id == provider.id) return; // dedup by id
            providers.add(provider);
            changed();
        }

        public void remove(WallpaperProvider provider) {
            for (int i = 0; i < providers.size; i++) {
                if (providers[i] == provider) {
                    providers.remove_at(i);
                    changed();
                    return;
                }
            }
        }

        public Gee.List<WallpaperProvider> list() { return providers; }

        public WallpaperProvider? lookup(string id) {
            foreach (var provider in providers) if (provider.id == id) return provider;
            return null;
        }
    }

    /**
     * Applies local images, such as photos, as the desktop wallpaper
     * directly: the image stays where it is and no wallpaper pack is made.
     */
    public class LocalWallpaper : Object {
        private const string KEY = "background-picture-uri";

        /**
         * Sets the regular file at `path` as the wallpaper.
         *
         * @return false when the file is missing or the desktop settings are unavailable.
         */
        public static bool apply(string path) {
            var settings = Core.safe_settings(Runtime.desktop_settings_schema);
            if (settings == null || !settings.settings_schema.has_key(KEY)) return false;
            if (!FileUtils.test(path, FileTest.IS_REGULAR)) return false;
            settings.delay();
            settings.set_string(KEY, File.new_for_path(path).get_uri());
            clear_attribution(settings);
            settings.apply();
            return true;
        }

        /** Whether the wallpaper is the image at `path`. */
        public static bool is_active(string path) {
            var settings = Core.safe_settings(Runtime.desktop_settings_schema);
            if (settings == null || !settings.settings_schema.has_key(KEY)) return false;
            return settings.get_string(KEY) == File.new_for_path(path).get_uri();
        }

        /**
         * Goes back to the default wallpaper when the current one is a local
         * file that no longer exists, for example a removed favourite.
         *
         * @return true when the wallpaper was reset.
         */
        public static bool fall_back_if_missing() {
            var settings = Core.safe_settings(Runtime.desktop_settings_schema);
            if (settings == null || !settings.settings_schema.has_key(KEY)) return false;
            string uri = settings.get_string(KEY);
            if (uri == "") return false;
            string? path = File.new_for_uri(uri).get_path();
            if (path == null || FileUtils.test(path, FileTest.EXISTS)) return false;
            settings.delay();
            settings.reset(KEY);
            clear_attribution(settings);
            settings.apply();
            return true;
        }

        private static void clear_attribution(GLib.Settings settings) {
            foreach (unowned string key in new string[] { "background-attribution-title", "background-attribution-author" }) {
                if (settings.settings_schema.has_key(key)) settings.set_string(key, "");
            }
        }
    }
}
