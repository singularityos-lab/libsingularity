using GLib;

namespace Singularity.Updates {

    public class AtomicProvider : Provider {
        public const string IFACE = "dev.sinty.UpdateProvider1";

        private Config config;
        private DBusConnection? conn = null;
        private uint subscription = 0;

        public override string kind {
            get { return "atomic"; }
        }

        public AtomicProvider(Config config) {
            this.config = config;
        }

        ~AtomicProvider() {
            if (conn != null && subscription != 0) conn.signal_unsubscribe(subscription);
        }

        public override async bool probe() {
            if (!(yield Backend.service_present(config.atomic_bus_type(), config.atomic_bus_name))) return false;
            try {
                conn = yield Bus.get(config.atomic_bus_type());
                var reply = yield conn.call(config.atomic_bus_name, config.atomic_object_path,
                    "org.freedesktop.DBus.Properties", "GetAll", new Variant("(s)", IFACE),
                    new VariantType("(a{sv})"), DBusCallFlags.NONE, 10000, null);
                apply(reply.get_child_value(0), true);
                subscription = conn.signal_subscribe(config.atomic_bus_name, "org.freedesktop.DBus.Properties",
                    "PropertiesChanged", config.atomic_object_path, IFACE, DBusSignalFlags.NONE,
                    (c, sender, path, iface, signal_name, parameters) => {
                        apply(parameters.get_child_value(1), false);
                    });
                return true;
            } catch (Error e) {
                warning("Updates: %s does not answer as an update provider: %s", config.atomic_bus_name, e.message);
                return false;
            }
        }

        public void apply(Variant props, bool initial) {
            string? text;
            if ((text = lookup_string(props, "Name")) != null && text != "") name = text;
            if (config.atomic_name != "") name = config.atomic_name;
            if (name == "") name = _("System Image");
            if ((text = lookup_string(props, "CurrentVersion")) != null) current_version = text;
            if (current_version == "") current_version = HardwareInfo.os_name();
            if ((text = lookup_string(props, "State")) != null) state = State.parse(text);
            if ((text = lookup_string(props, "AvailableVersion")) != null) available_version = text;
            if ((text = lookup_string(props, "ReleaseNotes")) != null) release_notes = text;
            if ((text = lookup_string(props, "LastError")) != null) last_error = text;
            Variant? value = props.lookup_value("DownloadSize", VariantType.UINT64);
            if (value != null) download_size = value.get_uint64();
            value = props.lookup_value("Progress", VariantType.DOUBLE);
            if (value != null) progress = value.get_double();
            value = props.lookup_value("LastCheck", VariantType.INT64);
            if (value != null) last_check = value.get_int64();
            value = props.lookup_value("Capabilities", VariantType.STRING_ARRAY);
            if (value != null || initial) {
                string[] caps = value != null ? value.get_strv() : new string[] { "download", "unschedule", "history" };
                can_download = "download" in caps;
                can_unschedule = "unschedule" in caps;
                has_history = "history" in caps;
                can_schedule = true;
            }
            description = _("Updated as a whole system image. Your files and apps stay as they are.");
            if (!initial) changed();
        }

        private static string? lookup_string(Variant props, string key) {
            Variant? value = props.lookup_value(key, VariantType.STRING);
            return value != null ? value.get_string() : null;
        }

        private async void invoke(string method, State busy) throws Error {
            if (conn == null) throw new IOError.NOT_CONNECTED(_("The update service is not available"));
            if (busy != State.UNKNOWN) {
                state = busy;
                last_error = "";
                changed();
            }
            try {
                yield conn.call(config.atomic_bus_name, config.atomic_object_path, IFACE, method, null,
                    null, DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, int.MAX, null);
                yield refresh();
            } catch (Error e) {
                DBusError.strip_remote_error(e);
                var failure = new IOError.FAILED(e.message);
                yield refresh();
                if (state != State.ERROR) fail(failure);
                throw failure;
            }
        }

        private async void refresh() {
            try {
                var reply = yield conn.call(config.atomic_bus_name, config.atomic_object_path,
                    "org.freedesktop.DBus.Properties", "GetAll", new Variant("(s)", IFACE),
                    new VariantType("(a{sv})"), DBusCallFlags.NONE, 10000, null);
                apply(reply.get_child_value(0), false);
            } catch (Error e) {
                debug("Updates: refreshing provider state failed: %s", e.message);
            }
        }

        public override async void check() throws Error {
            yield invoke("Check", State.CHECKING);
        }

        public override async void download() throws Error {
            yield invoke("Download", State.DOWNLOADING);
        }

        public override async void schedule() throws Error {
            yield invoke("Schedule", can_download ? State.UNKNOWN : State.DOWNLOADING);
        }

        public override async void unschedule() throws Error {
            yield invoke("Unschedule", State.UNKNOWN);
        }

        public override async Gee.List<HistoryEntry> history() throws Error {
            var list = new Gee.ArrayList<HistoryEntry>();
            if (conn == null || !has_history) return list;
            var reply = yield conn.call(config.atomic_bus_name, config.atomic_object_path, IFACE, "GetHistory", null,
                new VariantType("(a(sxbs))"), DBusCallFlags.NONE, 30000, null);
            var items = reply.get_child_value(0);
            for (size_t i = 0; i < items.n_children(); i++) {
                string version, summary;
                int64 time;
                bool success;
                items.get_child_value(i).get("(sxbs)", out version, out time, out success, out summary);
                string title = success ? _("Updated to %s").printf(version) : _("Update to %s Failed").printf(version);
                list.add(new HistoryEntry(title, summary, time, success));
            }
            list.sort((a, b) => a.time > b.time ? -1 : (a.time < b.time ? 1 : 0));
            return list;
        }
    }
}
