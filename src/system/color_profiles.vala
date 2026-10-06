namespace Singularity {

    public errordomain ColorProfileError {
        INVALID,
        FAILED
    }

    public class ColorProfile : GLib.Object {
        public string path { get; construct; }
        public string title { get; construct; }
        public bool user { get; construct; }

        public ColorProfile(string path, string title, bool user) {
            Object(path: path, title: title, user: user);
        }
    }

    public interface ColorProfileBackend : GLib.Object {
        public abstract string backend_name { get; }
        public abstract async Gee.List<ColorProfile> list_profiles();
        public abstract async string? get_assigned(string display_key);
        public abstract async void assign(string display_key, string vendor, string model, string serial,
                                          string? path) throws GLib.Error;
        public abstract async void register_profile(string path) throws GLib.Error;
    }

    public class ColorProfiles : GLib.Object {
        public const string SETTINGS_KEY = "output-color-profiles";
        public const string CONFIG_NAME = "color.conf";

        public ColorProfileBackend backend { get; private set; }
        public string? calibrate_command { get; private set; }

        private static ColorProfiles? _instance;
        public signal void changed();

        public static ColorProfiles get_default() {
            if (_instance == null) _instance = new ColorProfiles();
            return _instance;
        }

        construct {
            var conf = load_config();
            string choice = read_conf(conf, "Profiles", "Backend", "auto");
            GLib.DBusConnection? bus = null;
            if (choice != "files") {
                try {
                    bus = GLib.Bus.get_sync(GLib.BusType.SYSTEM);
                } catch (GLib.Error e) {
                    bus = null;
                }
            }
            if (bus != null && (choice == "colord" || ColordProfileBackend.available(bus))) {
                backend = new ColordProfileBackend(bus);
            } else {
                backend = new FileProfileBackend();
            }
            string command = read_conf(conf, "Calibrate", "Command", "auto");
            if (command == "auto") {
                calibrate_command = GLib.Environment.find_program_in_path("displaycal") != null ? "displaycal" : null;
            } else if (command != "") {
                string[] argv;
                try {
                    GLib.Shell.parse_argv(command, out argv);
                    calibrate_command = GLib.Environment.find_program_in_path(argv[0]) != null ? command : null;
                } catch (GLib.ShellError e) {
                    calibrate_command = null;
                }
            }
            message("ColorProfiles: backend %s, calibration %s", backend.backend_name, calibrate_command ?? "none");
        }

        public static GLib.KeyFile? load_config() {
            var dirs = new Gee.ArrayList<string>();
            dirs.add(GLib.Environment.get_user_config_dir());
            foreach (var d in GLib.Environment.get_system_config_dirs()) dirs.add(d);
            dirs.add("/etc");
            foreach (var d in dirs) {
                var kf = new GLib.KeyFile();
                try {
                    if (kf.load_from_file(GLib.Path.build_filename(d, "singularity", CONFIG_NAME), GLib.KeyFileFlags.NONE))
                        return kf;
                } catch (GLib.Error e) {
                }
            }
            return null;
        }

        private static string read_conf(GLib.KeyFile? kf, string group, string key, string fallback) {
            if (kf == null) return fallback;
            try {
                return kf.get_string(group, key).strip();
            } catch (GLib.Error e) {
                return fallback;
            }
        }

        public static string display_key(string? vendor, string? model, string? serial, string connector) {
            string key = "%s %s %s".printf(vendor ?? "", model ?? "", serial ?? "").strip();
            while (key.contains("  ")) key = key.replace("  ", " ");
            return key != "" ? key : connector;
        }

        public static bool is_display_profile(uint8[] data) {
            if (data.length < 128) return false;
            if (data[36] != 'a' || data[37] != 'c' || data[38] != 's' || data[39] != 'p') return false;
            return data[12] == 'm' && data[13] == 'n' && data[14] == 't' && data[15] == 'r';
        }

        public static string profile_title(uint8[] data, string fallback) {
            if (data.length < 132) return fallback;
            uint32 count = read_be32(data, 128);
            for (uint32 i = 0; i < count && 132 + (i + 1) * 12 <= data.length; i++) {
                size_t entry = 132 + i * 12;
                if (data[entry] != 'd' || data[entry + 1] != 'e' || data[entry + 2] != 's' || data[entry + 3] != 'c') continue;
                uint32 offset = read_be32(data, entry + 4);
                uint32 size = read_be32(data, entry + 8);
                if (offset + size > data.length || size < 12) return fallback;
                string? title = null;
                if (data[offset] == 'd' && data[offset + 1] == 'e' && data[offset + 2] == 's' && data[offset + 3] == 'c') {
                    uint32 len = read_be32(data, offset + 8);
                    if (len > 1 && offset + 12 + len <= data.length) {
                        var sb = new StringBuilder();
                        for (uint32 k = 0; k < len - 1; k++) sb.append_c((char) data[offset + 12 + k]);
                        title = sb.str;
                    }
                } else if (data[offset] == 'm' && data[offset + 1] == 'l' && data[offset + 2] == 'u' && data[offset + 3] == 'c') {
                    uint32 records = read_be32(data, offset + 8);
                    if (records > 0 && offset + 28 <= data.length) {
                        uint32 len = read_be32(data, offset + 20);
                        uint32 start = read_be32(data, offset + 24);
                        if (offset + start + len <= data.length) {
                            var sb = new StringBuilder();
                            for (uint32 k = 0; k + 1 < len; k += 2) {
                                unichar c = (data[offset + start + k] << 8) | data[offset + start + k + 1];
                                if (c != 0) sb.append_unichar(c);
                            }
                            title = sb.str;
                        }
                    }
                }
                if (title != null && title.strip() != "" && title.validate()) return title.strip();
                return fallback;
            }
            return fallback;
        }

        private static uint32 read_be32(uint8[] data, size_t at) {
            return ((uint32) data[at] << 24) | ((uint32) data[at + 1] << 16) | ((uint32) data[at + 2] << 8) | data[at + 3];
        }

        public static string user_profile_dir() {
            return GLib.Path.build_filename(GLib.Environment.get_user_data_dir(), "icc");
        }

        public static string[] profile_dirs() {
            string[] dirs = { user_profile_dir() };
            foreach (var d in GLib.Environment.get_system_data_dirs()) dirs += GLib.Path.build_filename(d, "color", "icc");
            dirs += "/var/lib/colord/icc";
            return dirs;
        }

        public static Gee.List<ColorProfile> scan_dirs(string[] dirs) {
            var list = new Gee.ArrayList<ColorProfile>();
            var seen = new Gee.HashSet<string>();
            bool first = true;
            foreach (var dir in dirs) {
                scan_dir(GLib.File.new_for_path(dir), first, list, seen, 0);
                first = false;
            }
            list.sort((a, b) => a.title.collate(b.title));
            return list;
        }

        private static void scan_dir(GLib.File dir, bool user, Gee.List<ColorProfile> list, Gee.Set<string> seen, int depth) {
            if (depth > 2) return;
            try {
                var en = dir.enumerate_children("standard::name,standard::type", GLib.FileQueryInfoFlags.NONE);
                GLib.FileInfo info;
                while ((info = en.next_file()) != null) {
                    var child = dir.get_child(info.get_name());
                    if (info.get_file_type() == GLib.FileType.DIRECTORY) {
                        scan_dir(child, user, list, seen, depth + 1);
                        continue;
                    }
                    string lower = info.get_name().down();
                    if (!lower.has_suffix(".icc") && !lower.has_suffix(".icm")) continue;
                    uint8[] data;
                    try {
                        if (!child.load_contents(null, out data, null)) continue;
                    } catch (GLib.Error e) {
                        continue;
                    }
                    if (!is_display_profile(data)) continue;
                    string path = child.get_path();
                    if (seen.contains(path)) continue;
                    seen.add(path);
                    list.add(new ColorProfile(path, profile_title(data, info.get_name()), user));
                }
            } catch (GLib.Error e) {
            }
        }

        public async ColorProfile import_profile(GLib.File source) throws GLib.Error {
            uint8[] data;
            yield source.load_contents_async(null, out data, null);
            if (!is_display_profile(data))
                throw new ColorProfileError.INVALID(_("This file is not a display color profile"));
            string dir = user_profile_dir();
            GLib.DirUtils.create_with_parents(dir, 0755);
            string name = source.get_basename() ?? "profile.icc";
            string lower = name.down();
            if (!lower.has_suffix(".icc") && !lower.has_suffix(".icm")) name += ".icc";
            var target = GLib.File.new_for_path(GLib.Path.build_filename(dir, name));
            if (!target.equal(source)) {
                yield target.replace_contents_async(data, null, false, GLib.FileCreateFlags.REPLACE_DESTINATION, null, null);
            }
            try {
                yield backend.register_profile(target.get_path());
            } catch (GLib.Error e) {
                warning("ColorProfiles: %s could not register %s: %s", backend.backend_name, target.get_path(), e.message);
            }
            changed();
            return new ColorProfile(target.get_path(), profile_title(data, name), true);
        }

        public async void assign(string display_key, string vendor, string model, string serial, string? path) throws GLib.Error {
            yield backend.assign(display_key, vendor, model, serial, path);
            store_assignment(display_key, path);
            changed();
        }

        public static string? stored_assignment(string display_key) {
            var settings = new GLib.Settings("dev.sinty.desktop");
            if (!settings.settings_schema.has_key(SETTINGS_KEY)) return null;
            string? path = null;
            var iter = settings.get_value(SETTINGS_KEY).iterator();
            string k, v;
            while (iter.next("{ss}", out k, out v)) {
                if (k == display_key) path = v;
            }
            return path;
        }

        public static void store_assignment(string display_key, string? path) {
            var settings = new GLib.Settings("dev.sinty.desktop");
            if (!settings.settings_schema.has_key(SETTINGS_KEY)) return;
            var builder = new GLib.VariantBuilder(new GLib.VariantType("a{ss}"));
            var iter = settings.get_value(SETTINGS_KEY).iterator();
            string k, v;
            while (iter.next("{ss}", out k, out v)) {
                if (k != display_key) builder.add("{ss}", k, v);
            }
            if (path != null && path != "") builder.add("{ss}", display_key, path);
            settings.set_value(SETTINGS_KEY, builder.end());
        }
    }

    public class FileProfileBackend : GLib.Object, ColorProfileBackend {
        public string backend_name { get { return "files"; } }

        public async Gee.List<ColorProfile> list_profiles() {
            return ColorProfiles.scan_dirs(ColorProfiles.profile_dirs());
        }

        public async string? get_assigned(string display_key) {
            return ColorProfiles.stored_assignment(display_key);
        }

        public async void assign(string display_key, string vendor, string model, string serial, string? path) throws GLib.Error {
        }

        public async void register_profile(string path) throws GLib.Error {
        }
    }

    public class ColordProfileBackend : GLib.Object, ColorProfileBackend {
        private const string NAME = "org.freedesktop.ColorManager";
        private const string MANAGER_PATH = "/org/freedesktop/ColorManager";
        private GLib.DBusConnection bus;

        public string backend_name { get { return "colord"; } }

        public ColordProfileBackend(GLib.DBusConnection bus) {
            this.bus = bus;
        }

        public static bool available(GLib.DBusConnection bus) {
            try {
                var reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "NameHasOwner", new GLib.Variant("(s)", NAME), new GLib.VariantType("(b)"), GLib.DBusCallFlags.NONE, 2000);
                bool owned;
                reply.get("(b)", out owned);
                if (owned) return true;
                var names = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "ListActivatableNames", null, new GLib.VariantType("(as)"), GLib.DBusCallFlags.NONE, 2000);
                foreach (var n in names.get_child_value(0).get_strv()) {
                    if (n == NAME) return true;
                }
            } catch (GLib.Error e) {
            }
            return false;
        }

        private async GLib.Variant call(string path, string iface, string method, GLib.Variant? args, string? reply_type) throws GLib.Error {
            return yield bus.call(NAME, path, iface, method, args,
                reply_type != null ? new GLib.VariantType(reply_type) : null, GLib.DBusCallFlags.NONE, 10000);
        }

        private async GLib.Variant? property(string path, string iface, string name) {
            try {
                var reply = yield call(path, "org.freedesktop.DBus.Properties", "Get", new GLib.Variant("(ss)", iface, name), "(v)");
                return reply.get_child_value(0).get_variant();
            } catch (GLib.Error e) {
                return null;
            }
        }

        public async Gee.List<ColorProfile> list_profiles() {
            var list = new Gee.ArrayList<ColorProfile>();
            var seen = new Gee.HashSet<string>();
            string user_dir = ColorProfiles.user_profile_dir();
            try {
                var reply = yield call(MANAGER_PATH, "org.freedesktop.ColorManager", "GetProfiles", null, "(ao)");
                var iter = reply.get_child_value(0).iterator();
                string obj;
                while (iter.next("o", out obj)) {
                    var kind = yield property(obj, "org.freedesktop.ColorManager.Profile", "Kind");
                    if (kind != null && kind.get_string() != "display-device") continue;
                    var file = yield property(obj, "org.freedesktop.ColorManager.Profile", "Filename");
                    var title = yield property(obj, "org.freedesktop.ColorManager.Profile", "Title");
                    if (file == null || file.get_string() == "" || seen.contains(file.get_string())) continue;
                    seen.add(file.get_string());
                    string t = title != null && title.get_string() != "" ? title.get_string() : GLib.Path.get_basename(file.get_string());
                    if (t == GLib.Path.get_basename(file.get_string())) {
                        uint8[] data;
                        try {
                            if (GLib.File.new_for_path(file.get_string()).load_contents(null, out data, null))
                                t = ColorProfiles.profile_title(data, t);
                        } catch (GLib.Error e) {
                        }
                    }
                    list.add(new ColorProfile(file.get_string(), t, file.get_string().has_prefix(user_dir)));
                }
            } catch (GLib.Error e) {
                warning("ColorProfiles: colord GetProfiles failed: %s", e.message);
            }
            foreach (var p in ColorProfiles.scan_dirs({ user_dir })) {
                if (!seen.contains(p.path)) list.add(p);
            }
            list.sort((a, b) => a.title.collate(b.title));
            return list;
        }

        private static string device_id(string display_key) {
            var sb = new StringBuilder("singularity-");
            foreach (char c in display_key.to_utf8()) sb.append_c(c.isalnum() ? c : '_');
            return sb.str;
        }

        private async string? find_device(string display_key) {
            try {
                var reply = yield call(MANAGER_PATH, "org.freedesktop.ColorManager", "FindDeviceById",
                    new GLib.Variant("(s)", device_id(display_key)), "(o)");
                string path;
                reply.get("(o)", out path);
                return path;
            } catch (GLib.Error e) {
                return null;
            }
        }

        private async string ensure_device(string display_key, string vendor, string model, string serial) throws GLib.Error {
            string? existing = yield find_device(display_key);
            if (existing != null) return existing;
            var props = new GLib.VariantBuilder(new GLib.VariantType("a{ss}"));
            props.add("{ss}", "Kind", "display");
            props.add("{ss}", "Mode", "physical");
            props.add("{ss}", "Colorspace", "rgb");
            if (vendor != "") props.add("{ss}", "Vendor", vendor);
            if (model != "") props.add("{ss}", "Model", model);
            if (serial != "") props.add("{ss}", "Serial", serial);
            var reply = yield call(MANAGER_PATH, "org.freedesktop.ColorManager", "CreateDevice",
                new GLib.Variant("(ss@a{ss})", device_id(display_key), "disk", props.end()), "(o)");
            string path;
            reply.get("(o)", out path);
            return path;
        }

        private async string? find_profile(string file) {
            try {
                var reply = yield call(MANAGER_PATH, "org.freedesktop.ColorManager", "FindProfileByFilename",
                    new GLib.Variant("(s)", file), "(o)");
                string path;
                reply.get("(o)", out path);
                return path;
            } catch (GLib.Error e) {
                return null;
            }
        }

        public async string? get_assigned(string display_key) {
            string? device = yield find_device(display_key);
            if (device == null) return ColorProfiles.stored_assignment(display_key);
            var profiles = yield property(device, "org.freedesktop.ColorManager.Device", "Profiles");
            if (profiles == null || profiles.n_children() == 0) return null;
            string first = profiles.get_child_value(0).get_string();
            var file = yield property(first, "org.freedesktop.ColorManager.Profile", "Filename");
            return file != null ? file.get_string() : null;
        }

        public async void register_profile(string path) throws GLib.Error {
            if ((yield find_profile(path)) != null) return;
            var fd_list = new GLib.UnixFDList();
            int fd = Posix.open(path, Posix.O_RDONLY);
            if (fd < 0) throw new ColorProfileError.FAILED("cannot open %s".printf(path));
            int index = fd_list.append(fd);
            Posix.close(fd);
            var props = new GLib.VariantBuilder(new GLib.VariantType("a{ss}"));
            props.add("{ss}", "Filename", path);
            string id = "icc-" + GLib.Checksum.compute_for_string(GLib.ChecksumType.MD5, path);
            yield bus.call_with_unix_fd_list(NAME, MANAGER_PATH, "org.freedesktop.ColorManager", "CreateProfileWithFd",
                new GLib.Variant("(ssh@a{ss})", id, "disk", index, props.end()), new GLib.VariantType("(o)"),
                GLib.DBusCallFlags.NONE, 10000, fd_list, null, null);
        }

        public async void assign(string display_key, string vendor, string model, string serial, string? path) throws GLib.Error {
            string device = yield ensure_device(display_key, vendor, model, serial);
            var current = yield property(device, "org.freedesktop.ColorManager.Device", "Profiles");
            if (path == null || path == "") {
                if (current != null) {
                    for (size_t i = 0; i < current.n_children(); i++) {
                        yield call(device, "org.freedesktop.ColorManager.Device", "RemoveProfile",
                            new GLib.Variant("(o)", current.get_child_value(i).get_string()), null);
                    }
                }
                return;
            }
            string? profile = yield find_profile(path);
            if (profile == null) {
                yield register_profile(path);
                profile = yield find_profile(path);
            }
            if (profile == null) throw new ColorProfileError.FAILED("colord does not know %s".printf(path));
            bool attached = false;
            if (current != null) {
                for (size_t i = 0; i < current.n_children(); i++) {
                    if (current.get_child_value(i).get_string() == profile) attached = true;
                }
            }
            if (!attached) {
                yield call(device, "org.freedesktop.ColorManager.Device", "AddProfile",
                    new GLib.Variant("(so)", "hard", profile), null);
            }
            yield call(device, "org.freedesktop.ColorManager.Device", "MakeProfileDefault",
                new GLib.Variant("(o)", profile), null);
        }
    }
}
