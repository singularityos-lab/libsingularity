namespace Singularity {

    public class AppLink : Object {
        public GLib.DesktopAppInfo app { get; construct; }
        public string? uri { get; construct; }
        public bool in_store { get; construct; }

        public AppLink(GLib.DesktopAppInfo app, string? uri, bool in_store) {
            Object(app: app, uri: uri, in_store: in_store);
        }

        public GLib.List<GLib.File> files() {
            var list = new GLib.List<GLib.File>();
            if (uri != null) list.append(GLib.File.new_for_uri(uri));
            return list;
        }

        public bool launch(GLib.AppLaunchContext? context = null) {
            var uris = new GLib.List<string>();
            if (uri != null) uris.append(uri);
            try {
                return app.launch_uris(uris, context);
            } catch (Error e) {
                warning("app link: %s", e.message);
                return false;
            }
        }
    }

    public class AppLinks {
        public const string STORE_ID = "dev.sinty.store";
        public const string STORE_SCHEME = "appstream";
        public const string WEB_APP_PREFIX = "dev.sinty.browser.WebApp_";

        public static string web_app_id(string catalog_id) {
            return WEB_APP_PREFIX + catalog_id;
        }

        public static GLib.DesktopAppInfo? find(string app_id) {
            string id = app_id.has_suffix(".desktop") ? app_id : app_id + ".desktop";
            var info = new GLib.DesktopAppInfo(id);
            if (info != null) return info;
            string path = Path.build_filename(Environment.get_user_data_dir(), "applications", id);
            if (!FileUtils.test(path, FileTest.EXISTS)) return null;
            return new GLib.DesktopAppInfo.from_filename(path);
        }

        public static bool installed(string app_id) {
            return find(app_id) != null;
        }

        public static string store_page_uri(string app_id) {
            string id = app_id.has_suffix(".desktop") ? app_id.substring(0, app_id.length - 8) : app_id;
            return STORE_SCHEME + "://" + id;
        }

        public static string? store_page_id(string uri) {
            string prefix = STORE_SCHEME + "://";
            if (!uri.has_prefix(prefix)) return null;
            string id = uri.substring(prefix.length);
            while (id.has_suffix("/")) id = id.substring(0, id.length - 1);
            if (id.has_suffix(".desktop")) id = id.substring(0, id.length - 8);
            return id != "" ? Uri.unescape_string(id) : null;
        }

        public static AppLink? resolve(string app_id, string? uri = null) {
            var app = find(app_id);
            if (app != null) return new AppLink(app, uri != null && app.supports_uris() ? uri : null, false);
            return store_page(app_id);
        }

        public static AppLink? store_page(string app_id) {
            var store = find(STORE_ID);
            if (store == null) return null;
            return new AppLink(store, store.supports_uris() ? store_page_uri(app_id) : null, true);
        }
    }
}
