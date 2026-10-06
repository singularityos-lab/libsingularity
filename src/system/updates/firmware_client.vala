using GLib;

namespace Singularity.Firmware {

    public class Release : Object {
        public string version { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string summary { get; set; default = ""; }
        public string notes { get; set; default = ""; }
        public string uri { get; set; default = ""; }
        public string checksum { get; set; default = ""; }
        public string remote_id { get; set; default = ""; }
        public uint64 size { get; set; default = 0; }
        public uint urgency { get; set; default = 0; }

        public static Release from_variant(Variant dict) {
            var release = new Release();
            release.version = Client.lookup_string(dict, "Version");
            release.name = Client.lookup_string(dict, "Name");
            release.summary = Client.lookup_string(dict, "Summary");
            release.notes = Client.markup_to_text(Client.lookup_string(dict, "Description"));
            release.remote_id = Client.lookup_string(dict, "RemoteId");
            release.uri = Client.lookup_string(dict, "Uri");
            Variant? locations = dict.lookup_value("Locations", VariantType.STRING_ARRAY);
            if (locations != null && locations.n_children() > 0) release.uri = locations.get_child_value(0).get_string();
            Variant? checksum = dict.lookup_value("Checksum", VariantType.STRING);
            if (checksum != null) {
                release.checksum = checksum.get_string();
            } else {
                Variant? checksums = dict.lookup_value("Checksum", VariantType.STRING_ARRAY);
                if (checksums != null && checksums.n_children() > 0) {
                    release.checksum = checksums.get_child_value(checksums.n_children() - 1).get_string();
                }
            }
            Variant? size = dict.lookup_value("Size", VariantType.UINT64);
            if (size != null) release.size = size.get_uint64();
            Variant? urgency = dict.lookup_value("Urgency", VariantType.UINT32);
            if (urgency != null) release.urgency = urgency.get_uint32();
            return release;
        }
    }

    public class Device : Object {
        public const uint64 FLAG_INTERNAL = 1 << 0;
        public const uint64 FLAG_UPDATABLE = 1 << 1;
        public const uint64 FLAG_REQUIRE_AC = 1 << 3;
        public const uint64 FLAG_LOCKED = 1 << 4;
        public const uint64 FLAG_NEEDS_REBOOT = 1 << 8;
        public const uint64 FLAG_NEEDS_SHUTDOWN = 1 << 17;

        public string id { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string vendor { get; set; default = ""; }
        public string version { get; set; default = ""; }
        public string summary { get; set; default = ""; }
        public string plugin { get; set; default = ""; }
        public string update_error { get; set; default = ""; }
        public uint64 flags { get; set; default = 0; }
        public uint update_state { get; set; default = 0; }
        public string[] icons = {};
        public Gee.ArrayList<Release> upgrades = new Gee.ArrayList<Release>();

        public bool updatable {
            get { return (flags & FLAG_UPDATABLE) != 0; }
        }

        public bool needs_restart {
            get { return (flags & (FLAG_NEEDS_REBOOT | FLAG_NEEDS_SHUTDOWN)) != 0 || update_state == 4; }
        }

        public bool requires_ac {
            get { return (flags & FLAG_REQUIRE_AC) != 0; }
        }

        public Release? latest {
            owned get { return upgrades.size > 0 ? upgrades[0] : null; }
        }

        public static Device from_variant(Variant dict) {
            var device = new Device();
            device.id = Client.lookup_string(dict, "DeviceId");
            device.name = Client.lookup_string(dict, "Name");
            device.vendor = Client.lookup_string(dict, "Vendor");
            device.version = Client.lookup_string(dict, "Version");
            device.summary = Client.lookup_string(dict, "Summary");
            device.plugin = Client.lookup_string(dict, "Plugin");
            device.update_error = Client.lookup_string(dict, "UpdateError");
            Variant? flags = dict.lookup_value("Flags", VariantType.UINT64);
            if (flags != null) device.flags = flags.get_uint64();
            Variant? state = dict.lookup_value("UpdateState", VariantType.UINT32);
            if (state != null) device.update_state = state.get_uint32();
            Variant? icons = dict.lookup_value("Icon", VariantType.STRING_ARRAY);
            if (icons != null) device.icons = icons.get_strv();
            return device;
        }
    }

    public class Remote : Object {
        public string id { get; set; default = ""; }
        public string title { get; set; default = ""; }
        public string uri { get; set; default = ""; }
        public bool enabled { get; set; default = false; }
        public uint kind { get; set; default = 0; }
        public uint64 modified { get; set; default = 0; }

        public bool downloads {
            get { return kind == 1 && uri != ""; }
        }

        public static Remote from_variant(Variant dict) {
            var remote = new Remote();
            remote.id = Client.lookup_string(dict, "RemoteId");
            remote.title = Client.lookup_string(dict, "Title");
            remote.uri = Client.lookup_string(dict, "Uri");
            Variant? flags = dict.lookup_value("Flags", VariantType.UINT64);
            if (flags != null) remote.enabled = (flags.get_uint64() & 1) != 0;
            Variant? enabled = dict.lookup_value("Enabled", VariantType.BOOLEAN);
            if (enabled != null) remote.enabled = enabled.get_boolean();
            Variant? kind = dict.lookup_value("Type", VariantType.UINT32);
            if (kind != null) remote.kind = kind.get_uint32();
            Variant? modified = dict.lookup_value("ModificationTime", VariantType.UINT64);
            if (modified != null) remote.modified = modified.get_uint64();
            return remote;
        }
    }

    public class Client : Object {
        public const string BUS_NAME = "org.freedesktop.fwupd";
        public const string OBJECT_PATH = "/";
        public const string IFACE = "org.freedesktop.fwupd";

        private static Client? _instance = null;
        private DBusConnection? conn = null;
        private uint subscription = 0;

        public bool available { get; private set; default = false; }
        public string daemon_version { get; private set; default = ""; }
        public string host_security_id { get; private set; default = ""; }
        public bool pending_reboot { get; private set; default = false; }

        public signal void changed();

        public static Client get_default() {
            if (_instance == null) _instance = new Client();
            return _instance;
        }

        public async bool probe() {
            if (available) return true;
            if (!(yield Singularity.Updates.Backend.service_present(BusType.SYSTEM, BUS_NAME))) return false;
            try {
                conn = yield Bus.get(BusType.SYSTEM);
                yield read_properties();
                subscription = conn.signal_subscribe(BUS_NAME, IFACE, null, OBJECT_PATH, null, DBusSignalFlags.NONE,
                    (c, sender, path, iface, signal_name, parameters) => {
                        if (signal_name == "Changed" || signal_name.has_prefix("Device")) changed();
                    });
                available = true;
                return true;
            } catch (Error e) {
                warning("Firmware: fwupd is not usable: %s", e.message);
                return false;
            }
        }

        public async void read_properties() throws Error {
            var reply = yield conn.call(BUS_NAME, OBJECT_PATH, "org.freedesktop.DBus.Properties", "GetAll",
                new Variant("(s)", IFACE), new VariantType("(a{sv})"), DBusCallFlags.NONE, 15000, null);
            var props = reply.get_child_value(0);
            daemon_version = lookup_string(props, "DaemonVersion");
            host_security_id = lookup_string(props, "HostSecurityId");
            Variant? reboot = props.lookup_value("PendingReboot", VariantType.BOOLEAN);
            pending_reboot = reboot != null && reboot.get_boolean();
        }

        public static string lookup_string(Variant dict, string key) {
            Variant? value = dict.lookup_value(key, VariantType.STRING);
            return value != null ? value.get_string() : "";
        }

        public static string markup_to_text(string markup) {
            if (markup.strip() == "") return "";
            var text = new StringBuilder();
            int i = 0;
            while (i < markup.length) {
                int open = markup.index_of_char('<', i);
                if (open < 0) {
                    text.append(markup.substring(i));
                    break;
                }
                text.append(markup.substring(i, open - i));
                int close = markup.index_of_char('>', open);
                if (close < 0) break;
                string tag = markup.substring(open + 1, close - open - 1).strip().down();
                if (tag == "li") text.append("\n• ");
                else if (tag == "p" || tag == "/p" || tag == "ul" || tag == "ol" || tag == "/ul" || tag == "/ol") text.append("\n");
                i = close + 1;
            }
            string result = text.str.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"")
                .replace("&apos;", "'").replace("&amp;", "&");
            var lines = new Gee.ArrayList<string>();
            bool blank = false;
            foreach (string raw in result.split("\n")) {
                string line = string.joinv(" ", raw.strip().split_set(" \t"));
                while (line.contains("  ")) line = line.replace("  ", " ");
                if (line == "") {
                    if (lines.size > 0 && !blank) blank = true;
                    continue;
                }
                if (blank && !line.has_prefix("•")) lines.add("");
                blank = false;
                lines.add(line);
            }
            return string.joinv("\n", lines.to_array());
        }

        public static int hsi_level(string host_security_id) {
            if (!host_security_id.has_prefix("HSI:")) return -1;
            string rest = host_security_id.substring(4);
            if (rest.length == 0 || !rest[0].isdigit()) return -1;
            return rest[0] - '0';
        }

        public static bool hsi_has_runtime_issue(string host_security_id) {
            if (!host_security_id.has_prefix("HSI:") || host_security_id.length < 6) return false;
            return host_security_id[5] == '!';
        }

        private void ensure() throws Error {
            if (conn == null || !available) throw new IOError.NOT_CONNECTED(_("The firmware update service is not available"));
        }

        public async Gee.ArrayList<Device> devices() throws Error {
            ensure();
            var list = new Gee.ArrayList<Device>();
            var reply = yield conn.call(BUS_NAME, OBJECT_PATH, IFACE, "GetDevices", null,
                new VariantType("(aa{sv})"), DBusCallFlags.NONE, 30000, null);
            var items = reply.get_child_value(0);
            for (size_t i = 0; i < items.n_children(); i++) {
                var device = Device.from_variant(items.get_child_value(i));
                if (device.id == "" || device.name == "") continue;
                if (device.updatable) yield load_upgrades(device);
                list.add(device);
            }
            list.sort((a, b) => {
                bool a_up = a.upgrades.size > 0;
                bool b_up = b.upgrades.size > 0;
                if (a_up != b_up) return a_up ? -1 : 1;
                return strcmp(a.name.collate_key(), b.name.collate_key());
            });
            return list;
        }

        private async void load_upgrades(Device device) {
            try {
                var reply = yield conn.call(BUS_NAME, OBJECT_PATH, IFACE, "GetUpgrades", new Variant("(s)", device.id),
                    new VariantType("(aa{sv})"), DBusCallFlags.NONE, 30000, null);
                var items = reply.get_child_value(0);
                for (size_t i = 0; i < items.n_children(); i++) {
                    device.upgrades.add(Release.from_variant(items.get_child_value(i)));
                }
            } catch (Error e) {
                string? remote = DBusError.get_remote_error(e);
                if (remote == null || !(remote.has_suffix(".NothingToDo") || remote.has_suffix(".NotFound")
                        || remote.has_suffix(".NotSupported"))) {
                    debug("Firmware: GetUpgrades %s failed: %s", device.id, e.message);
                }
            }
        }

        public async Gee.ArrayList<Remote> remotes() throws Error {
            ensure();
            var list = new Gee.ArrayList<Remote>();
            var reply = yield conn.call(BUS_NAME, OBJECT_PATH, IFACE, "GetRemotes", null,
                new VariantType("(aa{sv})"), DBusCallFlags.NONE, 15000, null);
            var items = reply.get_child_value(0);
            for (size_t i = 0; i < items.n_children(); i++) list.add(Remote.from_variant(items.get_child_value(i)));
            return list;
        }

        public async Gee.ArrayList<SecurityAttr> security_attrs() throws Error {
            ensure();
            var list = new Gee.ArrayList<SecurityAttr>();
            var reply = yield conn.call(BUS_NAME, OBJECT_PATH, IFACE, "GetHostSecurityAttrs", null,
                new VariantType("(aa{sv})"), DBusCallFlags.NONE, 30000, null);
            var items = reply.get_child_value(0);
            for (size_t i = 0; i < items.n_children(); i++) list.add(SecurityAttr.from_variant(items.get_child_value(i)));
            yield read_properties();
            return list;
        }

        public async Gee.ArrayList<Singularity.Updates.HistoryEntry> history() throws Error {
            ensure();
            var list = new Gee.ArrayList<Singularity.Updates.HistoryEntry>();
            Variant reply;
            try {
                reply = yield conn.call(BUS_NAME, OBJECT_PATH, IFACE, "GetHistory", null,
                    new VariantType("(aa{sv})"), DBusCallFlags.NONE, 30000, null);
            } catch (Error e) {
                string? remote = DBusError.get_remote_error(e);
                if (remote != null && remote.has_suffix(".NothingToDo")) return list;
                throw e;
            }
            var items = reply.get_child_value(0);
            for (size_t i = 0; i < items.n_children(); i++) {
                list.add(history_entry(items.get_child_value(i)));
            }
            list.sort((a, b) => a.time > b.time ? -1 : (a.time < b.time ? 1 : 0));
            return list;
        }

        public static Singularity.Updates.HistoryEntry history_entry(Variant dict) {
            var device = Device.from_variant(dict);
            string version = device.version;
            Variant? release = dict.lookup_value("Release", new VariantType("aa{sv}"));
            if (release != null && release.n_children() > 0) {
                string release_version = lookup_string(release.get_child_value(0), "Version");
                if (release_version != "") version = release_version;
            }
            int64 time = 0;
            Variant? modified = dict.lookup_value("Modified", VariantType.UINT64);
            if (modified != null) time = (int64) modified.get_uint64();
            if (time == 0) {
                Variant? created = dict.lookup_value("Created", VariantType.UINT64);
                if (created != null) time = (int64) created.get_uint64();
            }
            bool failed = device.update_state == 3 || device.update_state == 5;
            string title = failed ? _("%s Update Failed").printf(device.name) : _("%s Updated").printf(device.name);
            string detail = version != "" ? _("Version %s").printf(version) : "";
            if (device.update_state == 4) detail = _("%s, waiting for a restart").printf(detail);
            if (failed && device.update_error != "") detail = device.update_error;
            return new Singularity.Updates.HistoryEntry(title, detail, time, !failed);
        }

        public async int refresh_metadata(Cancellable? cancellable = null) throws Error {
            ensure();
            int refreshed = 0;
            Error? last = null;
            foreach (var remote in yield remotes()) {
                if (!remote.enabled || !remote.downloads) continue;
                try {
                    var data = yield Fetch.to_cache(remote.uri, cancellable);
                    var signature = yield Fetch.to_cache(remote.uri + ".jcat", cancellable);
                    yield call_with_fds("UpdateMetadata", remote.id, { data, signature }, null);
                    refreshed++;
                } catch (Error e) {
                    warning("Firmware: refreshing %s failed: %s", remote.id, e.message);
                    last = e;
                }
            }
            if (refreshed == 0 && last != null) throw last;
            return refreshed;
        }

        public async void install(Device device, Release release, Cancellable? cancellable = null) throws Error {
            ensure();
            if (release.uri == "") throw new IOError.NOT_FOUND(_("This firmware has no download location"));
            var file = yield Fetch.to_cache(release.uri, cancellable);
            if (release.checksum != "") Fetch.verify(file, release.checksum);
            var options = new VariantBuilder(new VariantType("a{sv}"));
            options.add("{sv}", "reason", new Variant.string("user-action"));
            yield call_with_fds("Install", device.id, { file }, options.end());
            yield read_properties();
        }

        private async void call_with_fds(string method, string id, File[] files, Variant? options) throws Error {
            var fds = new UnixFDList();
            var args = new Variant[] { new Variant.string(id) };
            foreach (var file in files) {
                int fd = Posix.open(file.get_path(), Posix.O_RDONLY | Posix.O_CLOEXEC);
                if (fd < 0) throw new IOError.FAILED(_("Cannot open %s").printf(file.get_path()));
                int index = fds.append(fd);
                Posix.close(fd);
                args += new Variant.handle(index);
            }
            if (options != null) args += options;
            yield conn.call_with_unix_fd_list(BUS_NAME, OBJECT_PATH, IFACE, method, new Variant.tuple(args),
                null, DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, fds, null);
            foreach (var file in files) {
                try {
                    file.delete();
                } catch (Error e) {
                    debug("Firmware: cannot remove %s: %s", file.get_path(), e.message);
                }
            }
        }
    }

    public class Fetch : Object {
        public const int64 MAX_BYTES = 256 * 1024 * 1024;

        public static async File to_cache(string uri, Cancellable? cancellable) throws Error {
            string dir = Path.build_filename(Environment.get_user_cache_dir(), "singularity", "firmware");
            DirUtils.create_with_parents(dir, 0700);
            string base_name = Path.get_basename(uri.split("?")[0]);
            if (base_name == "" || base_name == "/") base_name = "download";
            var dest = File.new_for_path(Path.build_filename(dir,
                "%s-%s".printf(Checksum.compute_for_string(ChecksumType.SHA256, uri).substring(0, 12), base_name)));
            if (uri.has_prefix("file://") || uri.has_prefix("/")) {
                var source = uri.has_prefix("/") ? File.new_for_path(uri) : File.new_for_uri(uri);
                yield source.copy_async(dest, FileCopyFlags.OVERWRITE, Priority.DEFAULT, cancellable, null);
                return dest;
            }
            if (!uri.has_prefix("https://") && !uri.has_prefix("http://")) {
                throw new IOError.NOT_SUPPORTED(_("Unsupported download location %s").printf(uri));
            }
            var session = new Soup.Session();
            session.user_agent = "singularity-firmware";
            session.timeout = 300;
            var message = new Soup.Message("GET", uri);
            if (message == null) throw new IOError.INVALID_ARGUMENT(_("Invalid download location %s").printf(uri));
            var input = yield session.send_async(message, Priority.DEFAULT, cancellable);
            if (message.status_code != Soup.Status.OK) {
                throw new IOError.FAILED(_("The download failed: %u %s").printf(message.status_code, message.reason_phrase ?? ""));
            }
            var output = yield dest.replace_async(null, false, FileCreateFlags.PRIVATE, Priority.DEFAULT, cancellable);
            uint8[] buffer = new uint8[65536];
            int64 total = 0;
            while (true) {
                ssize_t read = yield input.read_async(buffer, Priority.DEFAULT, cancellable);
                if (read <= 0) break;
                total += read;
                if (total > MAX_BYTES) {
                    yield output.close_async(Priority.DEFAULT, null);
                    throw new IOError.FAILED(_("The download is larger than expected"));
                }
                size_t written;
                yield output.write_all_async(buffer[0:read], Priority.DEFAULT, cancellable, out written);
            }
            yield output.close_async(Priority.DEFAULT, cancellable);
            return dest;
        }

        public static void verify(File file, string expected) throws Error {
            ChecksumType type;
            switch (expected.length) {
                case 40: type = ChecksumType.SHA1; break;
                case 64: type = ChecksumType.SHA256; break;
                case 128: type = ChecksumType.SHA512; break;
                default: return;
            }
            var checksum = new Checksum(type);
            var stream = file.read();
            uint8[] buffer = new uint8[65536];
            ssize_t read;
            while ((read = stream.read(buffer)) > 0) checksum.update(buffer, read);
            stream.close();
            if (checksum.get_string().down() != expected.down()) {
                throw new IOError.FAILED(_("The downloaded firmware failed the checksum"));
            }
        }
    }
}
