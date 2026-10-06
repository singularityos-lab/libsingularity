using GLib;

namespace Singularity.Privacy {

    public class Grant : Object {
        public string category { get; set; default = ""; }
        public string app_id { get; set; default = ""; }
        public string key { get; set; default = ""; }
        public string title { get; set; default = ""; }
        public string detail { get; set; default = ""; }
        public bool has_switch { get; set; default = false; }
        public bool active { get; set; default = false; }
        public bool can_remove { get; set; default = true; }
        public int64 last_used { get; set; default = 0; }

        public Grant(string category, string app_id, string key = "") {
            Object(category: category, app_id: app_id, key: key);
            title = Apps.display_name(app_id);
        }
    }

    public abstract class Source : Object {
        public string category { get; construct; }

        public signal void changed();

        public abstract async Grant[] load();
        public virtual async bool set_allowed(Grant grant, bool allowed) {
            return false;
        }
        public abstract async bool remove(Grant grant);

        public virtual bool needs_store {
            get { return true; }
        }

        public async Grant[] for_app(string[] app_ids) {
            Grant[] result = {};
            foreach (var grant in yield load()) {
                if (grant.app_id in app_ids) result += grant;
            }
            return result;
        }

        public static string[] categories() {
            return { "camera", "microphone", "location", "screenshot", "screencast", "background", "autostart",
                     "shortcuts", "notifications" };
        }

        public static Source create(string category) {
            switch (category) {
                case "camera": return new StoreSource(category, PermissionStore.TABLE_DEVICES, "camera");
                case "microphone": return new StoreSource(category, PermissionStore.TABLE_DEVICES, "microphone");
                case "location": return new StoreSource(category, PermissionStore.TABLE_LOCATION, "location", true);
                case "screenshot": return new StoreSource(category, PermissionStore.TABLE_SCREENSHOT, "screenshot");
                case "background": return new StoreSource(category, PermissionStore.TABLE_BACKGROUND, "background");
                case "notifications": return new StoreSource(category, PermissionStore.TABLE_NOTIFICATIONS, "notification");
                case "screencast": return new TokenSource(category, PermissionStore.TABLE_SCREENCAST);
                case "autostart": return new AutostartSource();
                default: return new ShortcutsSource();
            }
        }
    }

    public class Apps : Object {
        public static string display_name(string app_id) {
            if (app_id == "") return _("Unknown App");
            var sandboxed = Sandbox.Backends.get_default().cached_app(app_id);
            if (sandboxed != null) return sandboxed.display_name;
            var info = new DesktopAppInfo(app_id + ".desktop");
            return info != null ? info.get_display_name() : app_id;
        }

        public static Icon icon(string app_id) {
            var sandboxed = Sandbox.Backends.get_default().cached_app(app_id);
            if (sandboxed != null && sandboxed.icon != null) return sandboxed.icon;
            var info = new DesktopAppInfo(app_id + ".desktop");
            if (info != null && info.get_icon() != null) return info.get_icon();
            return new ThemedIcon("application-x-executable");
        }

        public static string ago(int64 then_usec, int64 now_usec) {
            if (then_usec <= 0 || then_usec > now_usec) return "";
            int64 minutes = (now_usec - then_usec) / 60000000;
            if (minutes < 1) return _("Used just now");
            if (minutes < 60) return ngettext("Used %d minute ago", "Used %d minutes ago", (ulong) minutes).printf((int) minutes);
            int64 hours = minutes / 60;
            if (hours < 24) return ngettext("Used %d hour ago", "Used %d hours ago", (ulong) hours).printf((int) hours);
            int64 days = hours / 24;
            return ngettext("Used %d day ago", "Used %d days ago", (ulong) days).printf((int) days);
        }
    }

    public class StoreSource : Source {
        public string table { get; construct; }
        public string item_id { get; construct; }
        public bool location { get; construct; }

        private PermissionStore store;

        public StoreSource(string category, string table, string item_id, bool location = false) {
            Object(category: category, table: table, item_id: item_id, location: location);
            store = PermissionStore.get_default();
            store.changed.connect((t, id) => {
                if (t == table) changed();
            });
        }

        public override async Grant[] load() {
            Grant[] result = {};
            int64 now = get_monotonic_time();
            foreach (var permission in yield store.lookup(table, item_id)) {
                var grant = new Grant(category, permission.app_id);
                grant.has_switch = true;
                grant.active = permission.allowed;
                if (location) {
                    int64 used = 0;
                    if (permission.values.length > 1) int64.try_parse(permission.values[1], out used);
                    if (used > 0 && used <= now) grant.last_used = get_real_time() - (now - used);
                    string recent = grant.active ? Apps.ago(used, now) : "";
                    grant.detail = recent != "" ? recent : (grant.active ? _("Allowed") : _("Denied"));
                } else {
                    grant.detail = grant.active ? _("Allowed") : _("Denied");
                }
                result += grant;
            }
            return result;
        }

        public override async bool set_allowed(Grant grant, bool allowed) {
            string[] values;
            if (location) values = { allowed ? "EXACT" : "NONE", "0" };
            else values = { allowed ? "yes" : "no" };
            return yield store.set_permission(table, item_id, grant.app_id, values);
        }

        public override async bool remove(Grant grant) {
            return yield store.delete_permission(table, item_id, grant.app_id);
        }
    }

    public class TokenSource : Source {
        public string table { get; construct; }

        private PermissionStore store;

        public TokenSource(string category, string table) {
            Object(category: category, table: table);
            store = PermissionStore.get_default();
            store.changed.connect((t, id) => {
                if (t == table) changed();
            });
        }

        public override async Grant[] load() {
            var counts = new HashTable<string, int>(str_hash, str_equal);
            var tokens = new HashTable<string, string>(str_hash, str_equal);
            foreach (string id in yield store.list(table)) {
                foreach (var permission in yield store.lookup(table, id)) {
                    counts.insert(permission.app_id, counts.lookup(permission.app_id) + 1);
                    string previous = tokens.lookup(permission.app_id) ?? "";
                    tokens.insert(permission.app_id, previous == "" ? id : previous + "\n" + id);
                }
            }
            Grant[] result = {};
            foreach (string app_id in counts.get_keys()) {
                var grant = new Grant(category, app_id, tokens.lookup(app_id));
                int n = counts.lookup(app_id);
                grant.detail = ngettext("Can restore %d saved session without asking",
                    "Can restore %d saved sessions without asking", (ulong) n).printf(n);
                result += grant;
            }
            return result;
        }

        public override async bool remove(Grant grant) {
            bool ok = true;
            foreach (string id in grant.key.split("\n")) {
                if (id != "" && !(yield store.delete_permission(table, id, grant.app_id))) ok = false;
            }
            return ok;
        }
    }

    public class AutostartSource : Source {
        private FileMonitor? monitor = null;

        public string dir {
            owned get { return Path.build_filename(Environment.get_user_config_dir(), "autostart"); }
        }

        public override bool needs_store {
            get { return false; }
        }

        public AutostartSource() {
            Object(category: "autostart");
            try {
                monitor = File.new_for_path(dir).monitor_directory(FileMonitorFlags.NONE);
                monitor.changed.connect(() => changed());
            } catch (Error e) {
                monitor = null;
            }
        }

        public static string? portal_app_id(KeyFile file) {
            foreach (string key in new string[] { "X-XDP-Autostart", "X-Flatpak" }) {
                try {
                    string value = file.get_string("Desktop Entry", key).strip();
                    if (value != "") return value;
                } catch (Error e) {
                }
            }
            return null;
        }

        public override async Grant[] load() {
            Grant[] result = {};
            try {
                var directory = Dir.open(dir);
                string? name;
                while ((name = directory.read_name()) != null) {
                    if (!name.has_suffix(".desktop")) continue;
                    string path = Path.build_filename(dir, name);
                    var file = new KeyFile();
                    try {
                        file.load_from_file(path, KeyFileFlags.NONE);
                    } catch (Error e) {
                        continue;
                    }
                    string? app_id = portal_app_id(file);
                    if (app_id == null) continue;
                    var grant = new Grant(category, app_id, path);
                    grant.detail = _("Starts when you log in");
                    result += grant;
                }
            } catch (FileError e) {
            }
            return result;
        }

        public override async bool remove(Grant grant) {
            bool ok = FileUtils.unlink(grant.key) == 0;
            changed();
            return ok;
        }
    }

    public class ShortcutsSource : Source {
        public const string KEY = "portal-global-shortcuts";

        private GLib.Settings? settings = null;

        public override bool needs_store {
            get { return false; }
        }

        public ShortcutsSource() {
            Object(category: "shortcuts");
            var source = SettingsSchemaSource.get_default();
            var schema = source != null ? source.lookup("dev.sinty.desktop", true) : null;
            if (schema == null || !schema.has_key(KEY)) return;
            settings = new GLib.Settings("dev.sinty.desktop");
            settings.changed[KEY].connect(() => changed());
        }

        public override async Grant[] load() {
            Grant[] result = {};
            if (settings == null) return result;
            var iter = settings.get_value(KEY).iterator();
            string app_id, id, description, accelerator;
            while (iter.next("(ssss)", out app_id, out id, out description, out accelerator)) {
                var grant = new Grant(category, app_id, id);
                grant.title = description != "" ? description : id;
                grant.detail = accelerator != ""
                    ? "%s, %s".printf(Apps.display_name(app_id), accelerator)
                    : _("%s, no key assigned").printf(Apps.display_name(app_id));
                result += grant;
            }
            return result;
        }

        public override async bool remove(Grant grant) {
            if (settings == null) return false;
            var builder = new VariantBuilder(new VariantType("a(ssss)"));
            var iter = settings.get_value(KEY).iterator();
            string app_id, id, description, accelerator;
            while (iter.next("(ssss)", out app_id, out id, out description, out accelerator)) {
                if (app_id == grant.app_id && id == grant.key) continue;
                builder.add("(ssss)", app_id, id, description, accelerator);
            }
            return settings.set_value(KEY, builder.end());
        }
    }

    public class UsageEntry : Object {
        public string app_id { get; construct; }
        public string category { get; construct; }
        public int64 when { get; construct; }

        public UsageEntry(string app_id, string category, int64 when) {
            Object(app_id: app_id, category: category, when: when);
        }
    }

    public class Usage : Object {
        public const string FILE_NAME = "privacy-usage.ini";
        public const int64 KEEP_USEC = 7 * TimeSpan.DAY;

        private static Usage? _default = null;
        private string path;
        private KeyFile file = new KeyFile();

        public signal void changed();

        public static Usage get_default() {
            if (_default == null) {
                _default = new Usage(Path.build_filename(Environment.get_user_state_dir(), "singularity", FILE_NAME));
            }
            return _default;
        }

        public Usage(string path) {
            this.path = path;
            try {
                file.load_from_file(path, KeyFileFlags.NONE);
            } catch (Error e) {
            }
        }

        public void record(string app_id, string category, int64 when = 0) {
            if (app_id == "" || category == "") return;
            int64 stamp = when > 0 ? when : get_real_time();
            int64 previous = 0;
            try {
                previous = file.get_int64(app_id, category);
            } catch (Error e) {
            }
            if (stamp <= previous) return;
            file.set_int64(app_id, category, stamp);
            save();
            changed();
        }

        public UsageEntry[] recent(int64 now = 0, int64 window = KEEP_USEC) {
            int64 current = now > 0 ? now : get_real_time();
            UsageEntry[] result = {};
            foreach (string app_id in file.get_groups()) {
                try {
                    foreach (string category in file.get_keys(app_id)) {
                        int64 when = file.get_int64(app_id, category);
                        if (current - when <= window) result += new UsageEntry(app_id, category, when);
                    }
                } catch (Error e) {
                }
            }
            for (int i = 1; i < result.length; i++) {
                var entry = result[i];
                int j = i - 1;
                while (j >= 0 && result[j].when < entry.when) {
                    result[j + 1] = result[j];
                    j--;
                }
                result[j + 1] = entry;
            }
            return result;
        }

        public int64 last_used(string app_id, string category) {
            try {
                return file.get_int64(app_id, category);
            } catch (Error e) {
                return 0;
            }
        }

        private void save() {
            try {
                DirUtils.create_with_parents(Path.get_dirname(path), 0700);
                FileUtils.set_contents(path, file.to_data());
            } catch (Error e) {
                warning("Privacy: cannot save %s: %s", path, e.message);
            }
        }
    }
}
