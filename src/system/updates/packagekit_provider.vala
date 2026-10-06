using GLib;

namespace Singularity.Updates {

    public class PackageKitProvider : Provider {
        public const string BUS_NAME = "org.freedesktop.PackageKit";
        public const string OBJECT_PATH = "/org/freedesktop/PackageKit";
        private const string IFACE = "org.freedesktop.PackageKit";
        private const string OFFLINE_IFACE = "org.freedesktop.PackageKit.Offline";
        private const string TX_IFACE = "org.freedesktop.PackageKit.Transaction";
        private const uint64 FILTER_NONE = 1 << 1;
        private const uint64 FLAG_ONLY_TRUSTED = 1 << 1;
        private const uint64 FLAG_ONLY_DOWNLOAD = 1 << 3;
        private const uint INFO_SECURITY = 8;
        private const uint EXIT_SUCCESS = 1;
        private const uint ROLE_UPDATE_PACKAGES = 22;
        private const uint ROLE_UPGRADE_SYSTEM = 29;

        private DBusConnection? conn = null;
        private string[] update_ids = {};

        public override string kind {
            get { return "packagekit"; }
        }

        public override async bool probe() {
            if (!(yield Backend.service_present(BusType.SYSTEM, BUS_NAME))) return false;
            try {
                conn = yield Bus.get(BusType.SYSTEM);
                string backend = yield get_string_property(IFACE, "BackendName");
                name = _("System Packages");
                description = backend != ""
                    ? _("Updated through PackageKit, using %s").printf(backend)
                    : _("Updated through PackageKit");
                current_version = HardwareInfo.os_name();
                can_download = true;
                can_schedule = true;
                can_unschedule = true;
                has_history = true;
                yield read_offline_state();
                yield read_last_check();
                return true;
            } catch (Error e) {
                warning("Updates: PackageKit is not usable: %s", e.message);
                return false;
            }
        }

        private async string get_string_property(string iface, string property) throws Error {
            var reply = yield conn.call(BUS_NAME, OBJECT_PATH, "org.freedesktop.DBus.Properties", "Get",
                new Variant("(ss)", iface, property), new VariantType("(v)"), DBusCallFlags.NONE, 10000, null);
            Variant value;
            reply.get("(v)", out value);
            return value.is_of_type(VariantType.STRING) ? value.get_string() : "";
        }

        private async bool get_bool_property(string iface, string property) {
            try {
                var reply = yield conn.call(BUS_NAME, OBJECT_PATH, "org.freedesktop.DBus.Properties", "Get",
                    new Variant("(ss)", iface, property), new VariantType("(v)"), DBusCallFlags.NONE, 10000, null);
                Variant value;
                reply.get("(v)", out value);
                return value.is_of_type(VariantType.BOOLEAN) && value.get_boolean();
            } catch (Error e) {
                return false;
            }
        }

        private async void read_offline_state() {
            bool triggered = yield get_bool_property(OFFLINE_IFACE, "UpdateTriggered");
            bool prepared = yield get_bool_property(OFFLINE_IFACE, "UpdatePrepared");
            if (!triggered && !prepared) {
                state = State.IDLE;
                return;
            }
            try {
                var reply = yield conn.call(BUS_NAME, OBJECT_PATH, OFFLINE_IFACE, "GetPrepared", null,
                    new VariantType("(as)"), DBusCallFlags.NONE, 10000, null);
                var ids = reply.get_child_value(0);
                string[] prepared_ids = {};
                _packages.clear();
                for (size_t i = 0; i < ids.n_children(); i++) {
                    string id = ids.get_child_value(i).get_string();
                    prepared_ids += id;
                    _packages.add(package_from_id(id, "", false));
                }
                update_ids = prepared_ids;
            } catch (Error e) {
                debug("Updates: GetPrepared failed: %s", e.message);
            }
            state = triggered ? State.SCHEDULED : State.READY;
        }

        private async void read_last_check() {
            try {
                var reply = yield conn.call(BUS_NAME, OBJECT_PATH, IFACE, "GetTimeSinceAction",
                    new Variant("(u)", (uint) 13), new VariantType("(u)"), DBusCallFlags.NONE, 10000, null);
                uint seconds;
                reply.get("(u)", out seconds);
                if (seconds > 0 && seconds < uint32.MAX) {
                    last_check = get_real_time() / 1000000 - seconds;
                }
            } catch (Error e) {
                debug("Updates: GetTimeSinceAction failed: %s", e.message);
            }
        }

        public static Package package_from_id(string package_id, string summary, bool security) {
            string[] parts = package_id.split(";");
            string pkg_name = parts.length > 0 ? parts[0] : package_id;
            string version = parts.length > 1 ? parts[1] : "";
            return new Package(pkg_name, version, summary, security);
        }

        private async PkTransaction start() throws Error {
            var reply = yield conn.call(BUS_NAME, OBJECT_PATH, IFACE, "CreateTransaction", null,
                new VariantType("(o)"), DBusCallFlags.NONE, 10000, null);
            string path;
            reply.get("(o)", out path);
            var tx = new PkTransaction(conn, path);
            try {
                yield conn.call(BUS_NAME, path, TX_IFACE, "SetHints",
                    new Variant.tuple({ new Variant.strv({ "interactive=true" }) }),
                    null, DBusCallFlags.NONE, 10000, null);
            } catch (Error e) {
                debug("Updates: SetHints failed: %s", e.message);
            }
            return tx;
        }

        public override async void check() throws Error {
            if (conn == null) throw new IOError.NOT_CONNECTED(_("PackageKit is not available"));
            state = State.CHECKING;
            progress = -1;
            last_error = "";
            changed();
            try {
                var refresh = yield start();
                refresh.percentage.connect(on_percentage);
                yield refresh.run("RefreshCache", new Variant("(b)", false));

                var tx = yield start();
                var found = new Gee.ArrayList<Package>();
                var ids = new Gee.ArrayList<string>();
                tx.package.connect((info, id, summary) => {
                    ids.add(id);
                    found.add(package_from_id(id, summary, info == INFO_SECURITY));
                });
                yield tx.run("GetUpdates", new Variant("(t)", FILTER_NONE));
                update_ids = ids.to_array();
                _packages.clear();
                _packages.add_all(found);
                last_check = get_real_time() / 1000000;
                progress = -1;
                available_version = "";
                state = found.size > 0 ? State.AVAILABLE : State.UP_TO_DATE;
                changed();
            } catch (Error e) {
                fail(e);
                throw e;
            }
        }

        private void on_percentage(uint value) {
            progress = value <= 100 ? value / 100.0 : -1;
            changed();
        }

        public override async void download() throws Error {
            if (conn == null) throw new IOError.NOT_CONNECTED(_("PackageKit is not available"));
            if (update_ids.length == 0) throw new IOError.NOT_FOUND(_("There are no updates to download"));
            state = State.DOWNLOADING;
            progress = 0;
            last_error = "";
            changed();
            try {
                var tx = yield start();
                tx.percentage.connect(on_percentage);
                yield tx.run("UpdatePackages", new Variant.tuple({ new Variant.uint64(FLAG_ONLY_TRUSTED | FLAG_ONLY_DOWNLOAD), new Variant.strv(update_ids) }));
                progress = -1;
                state = State.READY;
                changed();
            } catch (Error e) {
                fail(e);
                throw e;
            }
        }

        public override async void schedule() throws Error {
            if (conn == null) throw new IOError.NOT_CONNECTED(_("PackageKit is not available"));
            try {
                yield conn.call(BUS_NAME, OBJECT_PATH, OFFLINE_IFACE, "Trigger", new Variant("(s)", "reboot"),
                    null, DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, -1, null);
                state = State.SCHEDULED;
                changed();
            } catch (Error e) {
                fail(e);
                throw e;
            }
        }

        public override async void unschedule() throws Error {
            if (conn == null) throw new IOError.NOT_CONNECTED(_("PackageKit is not available"));
            yield conn.call(BUS_NAME, OBJECT_PATH, OFFLINE_IFACE, "Cancel", null,
                null, DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, -1, null);
            state = State.READY;
            changed();
        }

        public override async Gee.List<HistoryEntry> history() throws Error {
            var list = new Gee.ArrayList<HistoryEntry>();
            if (conn == null) return list;
            var tx = yield start();
            tx.old_transaction.connect((timespec, succeeded, role, data) => {
                if (role != ROLE_UPDATE_PACKAGES && role != ROLE_UPGRADE_SYSTEM) return;
                list.add(history_entry(timespec, succeeded, role, data));
            });
            yield tx.run("GetOldTransactions", new Variant("(u)", (uint) 50));
            list.sort((a, b) => a.time > b.time ? -1 : (a.time < b.time ? 1 : 0));
            return list;
        }

        public static HistoryEntry history_entry(string timespec, bool succeeded, uint role, string data) {
            var names = new Gee.ArrayList<string>();
            foreach (string line in data.split("\n")) {
                string[] fields = line.split("\t");
                if (fields.length < 2) continue;
                string pkg = fields[1].split(";")[0];
                if (pkg != "" && !names.contains(pkg)) names.add(pkg);
            }
            string title = role == ROLE_UPGRADE_SYSTEM ? _("System Upgrade")
                : ngettext("%d Package Updated", "%d Packages Updated", names.size).printf(names.size);
            if (!succeeded) title = role == ROLE_UPGRADE_SYSTEM ? _("System Upgrade Failed") : _("Update Failed");
            string[] shown = {};
            foreach (string pkg in names) {
                if (shown.length == 6) break;
                shown += pkg;
            }
            string detail = string.joinv(", ", shown);
            if (names.size > shown.length) detail = _("%s and %d more").printf(detail, names.size - shown.length);
            int64 time = 0;
            var parsed = new DateTime.from_iso8601(timespec, new TimeZone.utc());
            if (parsed != null) time = parsed.to_unix();
            return new HistoryEntry(title, detail, time, succeeded);
        }
    }

    internal class PkTransaction : Object {
        private DBusConnection conn;
        private string path;
        private uint[] subscriptions = {};
        private bool finished = false;
        private uint exit_code = 0;
        private string error_text = "";
        private SourceFunc? waiting = null;

        public signal void package(uint info, string package_id, string summary);
        public signal void percentage(uint value);
        public signal void old_transaction(string timespec, bool succeeded, uint role, string data);

        public PkTransaction(DBusConnection conn, string path) {
            this.conn = conn;
            this.path = path;
            subscriptions += conn.signal_subscribe(PackageKitProvider.BUS_NAME, "org.freedesktop.PackageKit.Transaction",
                null, path, null, DBusSignalFlags.NONE, on_signal);
            subscriptions += conn.signal_subscribe(PackageKitProvider.BUS_NAME, "org.freedesktop.DBus.Properties",
                "PropertiesChanged", path, null, DBusSignalFlags.NONE, on_properties);
        }

        private void on_signal(DBusConnection c, string? sender, string object_path, string iface, string signal_name, Variant parameters) {
            switch (signal_name) {
                case "Package":
                    uint info;
                    string id, summary;
                    parameters.get("(uss)", out info, out id, out summary);
                    package(info, id, summary);
                    break;
                case "Packages":
                    var items = parameters.get_child_value(0);
                    for (size_t i = 0; i < items.n_children(); i++) {
                        uint info;
                        string id, summary;
                        items.get_child_value(i).get("(uss)", out info, out id, out summary);
                        package(info, id, summary);
                    }
                    break;
                case "Transaction":
                    string timespec = parameters.get_child_value(1).get_string();
                    bool succeeded = parameters.get_child_value(2).get_boolean();
                    uint role = parameters.get_child_value(3).get_uint32();
                    string data = parameters.get_child_value(5).get_string();
                    old_transaction(timespec, succeeded, role, data);
                    break;
                case "ErrorCode":
                    uint code;
                    string details;
                    parameters.get("(us)", out code, out details);
                    error_text = details;
                    break;
                case "Finished":
                    uint runtime;
                    parameters.get("(uu)", out exit_code, out runtime);
                    finished = true;
                    if (waiting != null) Idle.add((owned) waiting);
                    break;
            }
        }

        private void on_properties(DBusConnection c, string? sender, string object_path, string iface, string signal_name, Variant parameters) {
            var changed = parameters.get_child_value(1);
            Variant? value = changed.lookup_value("Percentage", VariantType.UINT32);
            if (value != null) percentage(value.get_uint32());
        }

        public async void run(string method, Variant? args) throws Error {
            try {
                yield conn.call(PackageKitProvider.BUS_NAME, path, "org.freedesktop.PackageKit.Transaction", method, args,
                    null, DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, -1, null);
                if (!finished) {
                    waiting = run.callback;
                    yield;
                }
            } finally {
                foreach (uint id in subscriptions) conn.signal_unsubscribe(id);
                subscriptions = {};
            }
            if (exit_code == 3) throw new IOError.CANCELLED(_("The update was cancelled"));
            if (exit_code != 1) {
                throw new IOError.FAILED(error_text != "" ? error_text : _("PackageKit could not finish the request"));
            }
        }
    }
}
