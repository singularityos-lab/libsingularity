namespace Singularity {

    public class Haptics : Object {
        private static Haptics? _instance = null;
        private GLib.Settings? settings = null;

        public bool available { get; private set; default = false; }

        public static Haptics get_default() {
            if (_instance == null) _instance = new Haptics();
            return _instance;
        }

        private Haptics() {
            available = SintySystem.haptic_available();
            var source = SettingsSchemaSource.get_default();
            var schema = source != null ? source.lookup("dev.sinty.desktop", true) : null;
            if (schema != null && schema.has_key("keyboard-haptic-feedback")) {
                settings = new GLib.Settings("dev.sinty.desktop");
            }
        }

        public bool keys_enabled {
            get { return settings == null || settings.get_boolean("keyboard-haptic-feedback"); }
        }

        public void key() {
            if (available && keys_enabled) SintySystem.haptic_key();
        }

        public void pulse(uint ms, uint16 strength) {
            if (available) SintySystem.haptic_pulse((uint32) ms, strength);
        }
    }
}
