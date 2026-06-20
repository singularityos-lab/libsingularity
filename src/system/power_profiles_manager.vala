using GLib;

namespace Singularity {

    [DBus (name = "org.freedesktop.UPower.PowerProfiles")]
    public interface PowerProfilesProxy : Object {
        public abstract string active_profile { owned get; set; }
    }

    public class PowerProfilesManager : Object {
        private static PowerProfilesManager? _instance = null;
        private PowerProfilesProxy? proxy = null;

        public bool available { get; private set; default = false; }
        public string active_profile { get; private set; default = "balanced"; }
        public signal void profile_changed();

        public static PowerProfilesManager get_default() {
            if (_instance == null) _instance = new PowerProfilesManager();
            return _instance;
        }

        public PowerProfilesManager() {
            init.begin();
        }

        private async void init() {
            try {
                proxy = yield Bus.get_proxy<PowerProfilesProxy>(
                    BusType.SYSTEM,
                    "org.freedesktop.UPower.PowerProfiles",
                    "/org/freedesktop/UPower/PowerProfiles"
                );
                active_profile = proxy.active_profile;
                available = true;

                proxy.notify["active-profile"].connect(() => {
                    active_profile = proxy.active_profile;
                    profile_changed();
                });

                profile_changed();
            } catch (Error e) {
                warning("PowerProfilesManager: service not available: %s", e.message);
                available = false;
            }
        }

        public void set_profile(string profile) {
            if (proxy == null) return;
            // Optimistic update so the UI (the cycle tile, the settings row)
            // reacts immediately, then reconcile with the daemon.
            string previous = active_profile;
            active_profile = profile;
            profile_changed();
            set_profile_async.begin(profile, previous);
        }

        // Write ActiveProfile and wait for the daemon's reply. On success the
        // daemon emits PropertiesChanged, which keeps active_profile correct;
        // on failure (for example a denied profile or polkit refusal) revert the
        // optimistic value to the daemon's real state instead of leaving a lie.
        private async void set_profile_async(string profile, string previous) {
            try {
                var conn = yield Bus.get(BusType.SYSTEM);
                yield conn.call(
                    "org.freedesktop.UPower.PowerProfiles",
                    "/org/freedesktop/UPower/PowerProfiles",
                    "org.freedesktop.DBus.Properties",
                    "Set",
                    new Variant("(ssv)",
                        "org.freedesktop.UPower.PowerProfiles",
                        "ActiveProfile",
                        new Variant.string(profile)),
                    null, DBusCallFlags.NONE, -1, null);
            } catch (Error e) {
                warning("PowerProfilesManager: set_profile failed: %s", e.message);
                active_profile = (proxy != null) ? proxy.active_profile : previous;
                profile_changed();
            }
        }
    }
}
