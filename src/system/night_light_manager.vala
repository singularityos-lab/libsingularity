namespace Singularity {

    public interface GammaBackend : GLib.Object {
        public abstract void set_night_light(int temperature);
        public abstract void reset_night_light();
    }

    public class NightLightManager : GLib.Object {
        public signal void changed();
        public bool enabled { get; private set; default = false; }
        public GammaBackend? backend { get; set; }

        private const int TEMP_WARM = 4000;
        private static NightLightManager? _instance;

        public static NightLightManager get_default() {
            if (_instance == null) _instance = new NightLightManager();
            return _instance;
        }

        public void toggle() {
            if (enabled) disable(); else enable();
        }

        public void enable() {
            if (enabled) return;
            if (backend != null) backend.set_night_light(TEMP_WARM);
            enabled = true;
            changed();
        }

        public void disable() {
            if (!enabled) return;
            if (backend != null) backend.reset_night_light();
            enabled = false;
            changed();
        }
    }
}
