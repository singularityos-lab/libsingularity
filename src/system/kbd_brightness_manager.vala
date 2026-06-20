namespace Singularity {

    public class KbdBrightnessManager : Object {
        private static KbdBrightnessManager? _instance = null;

        public double brightness { get; private set; default = 0.0; }
        public bool available { get; private set; default = false; }
        public int levels { get; private set; default = 3; }  // number of steps incl. off
        public signal void changed();

        private string? led_name = null;
        private int max_brightness = 1;

        public static KbdBrightnessManager get_default() {
            if (_instance == null) _instance = new KbdBrightnessManager();
            return _instance;
        }

        public KbdBrightnessManager() {
            detect_led();
            if (available) read_current();
        }

        private void detect_led() {
            try {
                var dir = Dir.open("/sys/class/leds", 0);
                string? name;
                while ((name = dir.read_name()) != null) {
                    if ("kbd_backlight" in name || "keyboard" in name.down()) {
                        led_name = name;
                        break;
                    }
                }
            } catch (Error e) {
                // No keyboard LED is normal on most machines; not an error.
                debug("KbdBrightnessManager: no /sys/class/leds (%s)", e.message);
            }
            if (led_name == null) return;
            try {
                string s;
                FileUtils.get_contents("/sys/class/leds/%s/max_brightness".printf(led_name), out s);
                max_brightness = int.parse(s.strip());
                if (max_brightness <= 0) max_brightness = 1;
                levels = max_brightness + 1;  // e.g. max=2, 3 levels: 0,1,2
                available = true;
            } catch (Error e) {
                warning("KbdBrightnessManager: cannot read max_brightness for %s: %s", led_name, e.message);
            }
        }

        private void read_current() {
            if (led_name == null) return;
            try {
                string s;
                FileUtils.get_contents("/sys/class/leds/%s/brightness".printf(led_name), out s);
                int cur = int.parse(s.strip());
                brightness = (cur * 100.0) / max_brightness;
            } catch (Error e) {
                warning("KbdBrightnessManager: cannot read brightness for %s: %s", led_name, e.message);
            }
        }

        public void set_level(double percent) {
            if (led_name == null) return;
            percent = percent.clamp(0.0, 100.0);
            uint32 raw = (uint32)((percent / 100.0) * max_brightness).clamp(0, max_brightness);
            try {
                var bus = Bus.get_sync(BusType.SYSTEM);
                bus.call_sync(
                    "org.freedesktop.login1",
                    "/org/freedesktop/login1/session/auto",
                    "org.freedesktop.login1.Session",
                    "SetBrightness",
                    new Variant("(ssu)", "leds", led_name, raw),
                    null, DBusCallFlags.NONE, -1, null
                );
                brightness = percent;
                changed();
            } catch (Error e) {
                warning("KbdBrightnessManager: SetBrightness failed: %s", e.message);
            }
        }

        public void step_up() {
            double step = 100.0 / max_brightness;
            set_level((brightness + step).clamp(0.0, 100.0));
        }

        public void step_down() {
            double step = 100.0 / max_brightness;
            set_level((brightness - step).clamp(0.0, 100.0));
        }

        public void toggle() {
            set_level(brightness > 0 ? 0.0 : 100.0);
        }
    }
}
