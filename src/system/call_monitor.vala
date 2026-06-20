using GLib;

namespace Singularity {

    public class CallMonitor : Object {
        public bool voice_active { get; private set; default = false; }
        public signal void changed();

        public AudioManager audio_manager { get; construct; }

        private DBusConnection? sys_bus = null;
        private bool use_ofono = false;
        private GenericArray<string> calls = new GenericArray<string>();

        public CallMonitor(AudioManager audio_manager) {
            Object(audio_manager: audio_manager);
        }

        construct {
            setup.begin();
        }

        private async void setup() {
            try {
                sys_bus = yield Bus.get(BusType.SYSTEM, null);
            } catch (Error e) {
                sys_bus = null;
            }

            if (sys_bus != null && yield ofono_has_modems()) {
                use_ofono = true;
                subscribe_ofono();
                yield refresh_ofono_calls();
            } else {
                use_ofono = false;
                wire_hfp_fallback();
            }
        }

        private async bool ofono_has_modems() {
            try {
                var r = yield sys_bus.call("org.ofono", "/", "org.ofono.Manager",
                    "GetModems", null, new VariantType("(a(oa{sv}))"),
                    DBusCallFlags.NONE, 2000, null);
                return r.get_child_value(0).n_children() > 0;
            } catch (Error e) {
                return false;
            }
        }

        private void subscribe_ofono() {
            sys_bus.signal_subscribe("org.ofono", "org.ofono.VoiceCallManager",
                "CallAdded", null, null, DBusSignalFlags.NONE,
                (c, s, p, i, sig, pars) => {
                    string path = pars.get_child_value(0).get_string();
                    add_call(path);
                });
            sys_bus.signal_subscribe("org.ofono", "org.ofono.VoiceCallManager",
                "CallRemoved", null, null, DBusSignalFlags.NONE,
                (c, s, p, i, sig, pars) => {
                    string path = pars.get_child_value(0).get_string();
                    remove_call(path);
                });
        }

        private async void refresh_ofono_calls() {
            try {
                var r = yield sys_bus.call("org.ofono", "/", "org.ofono.Manager",
                    "GetModems", null, new VariantType("(a(oa{sv}))"),
                    DBusCallFlags.NONE, 2000, null);
                var modems = r.get_child_value(0);
                for (size_t i = 0; i < modems.n_children(); i++) {
                    string modem_path = modems.get_child_value(i).get_child_value(0).get_string();
                    var cr = yield sys_bus.call("org.ofono", modem_path,
                        "org.ofono.VoiceCallManager", "GetCalls", null,
                        new VariantType("(a(oa{sv}))"), DBusCallFlags.NONE, 2000, null);
                    var cl = cr.get_child_value(0);
                    for (size_t j = 0; j < cl.n_children(); j++)
                        add_call(cl.get_child_value(j).get_child_value(0).get_string());
                }
            } catch (Error e) { }
            recompute_ofono();
        }

        private void add_call(string path) {
            for (int i = 0; i < calls.length; i++)
                if (calls.get(i) == path) return;
            calls.add(path);
            recompute_ofono();
        }

        private void remove_call(string path) {
            for (int i = 0; i < calls.length; i++) {
                if (calls.get(i) == path) { calls.remove_index(i); break; }
            }
            recompute_ofono();
        }

        private void recompute_ofono() {
            set_active(calls.length > 0);
        }

        private void wire_hfp_fallback() {
            var audio = audio_manager;
            audio.devices_changed.connect(recompute_hfp);
            recompute_hfp();
        }

        private void recompute_hfp() {
            var audio = audio_manager;
            bool active = false;
            unowned List<AudioManager.AudioDevice?> l = audio.sources;
            while (l != null) {
                if (l.data != null && l.data.name != null && l.data.name.has_prefix("bluez_input")) {
                    active = true;
                    break;
                }
                l = l.next;
            }
            set_active(active);
        }

        private void set_active(bool v) {
            if (v == voice_active) return;
            voice_active = v;
            changed();
        }
    }
}
