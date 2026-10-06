using GLib;

namespace Singularity {

    [DBus (name = "org.freedesktop.UPower.PowerProfiles")]
    public interface PowerProfilesProxy : Object {
        public abstract string active_profile { owned get; set; }
    }

    public class PowerProfilesBackend {
        public string bus_name;
        public string object_path;
        public string interface_name;

        public PowerProfilesBackend(string bus_name, string object_path, string interface_name) {
            this.bus_name = bus_name;
            this.object_path = object_path;
            this.interface_name = interface_name;
        }

        public static PowerProfilesBackend[] known() {
            return {
                new PowerProfilesBackend("org.freedesktop.UPower.PowerProfiles",
                    "/org/freedesktop/UPower/PowerProfiles", "org.freedesktop.UPower.PowerProfiles"),
                new PowerProfilesBackend("net.hadess.PowerProfiles",
                    "/net/hadess/PowerProfiles", "net.hadess.PowerProfiles")
            };
        }
    }

    public class PowerProfilesManager : Object {
        private const int PROBE_TIMEOUT_MS = 3000;

        private static PowerProfilesManager? _instance = null;
        private DBusConnection? connection = null;
        private PowerProfilesBackend? backend = null;
        private GLib.DBusProxy? proxy = null;
        private uint[] watches = {};
        private bool probing = false;

        public bool available { get; private set; default = false; }
        public string active_profile { get; private set; default = "balanced"; }
        public string? service_name { get { return backend != null ? backend.bus_name : null; } }
        public signal void profile_changed();

        public static PowerProfilesManager get_default() {
            if (_instance == null) _instance = new PowerProfilesManager();
            return _instance;
        }

        public PowerProfilesManager() {
            init.begin();
        }

        ~PowerProfilesManager() {
            foreach (uint id in watches) Bus.unwatch_name(id);
        }

        private async void init() {
            try {
                connection = yield Bus.get(BusType.SYSTEM);
            } catch (Error e) {
                warning("PowerProfilesManager: no system bus: %s", e.message);
                return;
            }
            foreach (var candidate in PowerProfilesBackend.known()) {
                watches += Bus.watch_name_on_connection(connection, candidate.bus_name, BusNameWatcherFlags.NONE,
                    () => probe.begin(),
                    () => {
                        if (backend != null && backend.bus_name == candidate.bus_name) probe.begin();
                    });
            }
            yield probe();
        }

        private async void probe() {
            if (connection == null || probing) return;
            probing = true;
            PowerProfilesBackend? found = null;
            string? profile = null;
            foreach (var candidate in PowerProfilesBackend.known()) {
                profile = yield read_active_profile(candidate);
                if (profile != null) {
                    found = candidate;
                    break;
                }
            }
            probing = false;
            if (found == null) {
                set_unavailable();
                return;
            }
            if (backend == null || backend.bus_name != found.bus_name || proxy == null) {
                backend = found;
                try {
                    proxy = yield new GLib.DBusProxy(connection, DBusProxyFlags.DO_NOT_AUTO_START, null,
                        found.bus_name, found.object_path, found.interface_name, null);
                    proxy.g_properties_changed.connect(on_properties_changed);
                } catch (Error e) {
                    proxy = null;
                }
            }
            active_profile = profile;
            if (!available) available = true;
            profile_changed();
        }

        private async string? read_active_profile(PowerProfilesBackend candidate) {
            try {
                var reply = yield connection.call(candidate.bus_name, candidate.object_path,
                    "org.freedesktop.DBus.Properties", "Get",
                    new Variant("(ss)", candidate.interface_name, "ActiveProfile"),
                    new VariantType("(v)"), DBusCallFlags.NONE, PROBE_TIMEOUT_MS, null);
                Variant inner;
                reply.get("(v)", out inner);
                if (!inner.is_of_type(VariantType.STRING)) return null;
                string value = inner.get_string();
                return value != "" ? value : null;
            } catch (Error e) {
                return null;
            }
        }

        private void set_unavailable() {
            bool was = available;
            backend = null;
            proxy = null;
            available = false;
            if (was) profile_changed();
        }

        private void on_properties_changed(Variant changed, string[] invalidated) {
            var value = changed.lookup_value("ActiveProfile", VariantType.STRING);
            if (value != null) {
                active_profile = value.get_string();
                profile_changed();
            } else if ("ActiveProfile" in invalidated) {
                probe.begin();
            }
        }

        public void set_profile(string profile) {
            if (!available || backend == null) return;
            string previous = active_profile;
            active_profile = profile;
            profile_changed();
            set_profile_async.begin(profile, previous);
        }

        private async void set_profile_async(string profile, string previous) {
            var target = backend;
            try {
                yield connection.call(target.bus_name, target.object_path,
                    "org.freedesktop.DBus.Properties", "Set",
                    new Variant("(ssv)", target.interface_name, "ActiveProfile", new Variant.string(profile)),
                    null, DBusCallFlags.NONE, -1, null);
            } catch (Error e) {
                warning("PowerProfilesManager: set_profile failed: %s", e.message);
                string? real = yield read_active_profile(target);
                active_profile = real ?? previous;
                profile_changed();
            }
        }
    }
}
