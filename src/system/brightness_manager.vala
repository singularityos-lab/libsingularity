namespace Singularity {

    public class BrightnessManager : Object {
        private static BrightnessManager? _instance = null;

        public double brightness { get; private set; default = 50.0; }
        public signal void changed();

        private string? backlight_name = null;
        private int max_brightness = 100;
        private GUdev.Client? udev_client = null;

        public static BrightnessManager get_default() {
            if (_instance == null) _instance = new BrightnessManager();
            return _instance;
        }

        public BrightnessManager() {
            detect_backlight();
            read_current();
            watch_for_external_changes();
        }

        // Keep the cached level in sync when brightness changes outside this
        // manager (hardware keys handled by the firmware, other tools). logind
        // exposes no brightness property to subscribe to and sysfs does not
        // emit inotify events, so the standard path is a udev subsystem monitor.
        private void watch_for_external_changes() {
            if (backlight_name == null) return;
            udev_client = new GUdev.Client({ "backlight" });
            udev_client.uevent.connect((action, device) => {
                if (device.get_name() != backlight_name) return;
                if (action == "change" || action == "add" || action == "online") {
                    double previous = brightness;
                    read_current();
                    if (brightness != previous) changed();
                }
            });
        }

        private void detect_backlight() {
            string[] candidates = {};
            try {
                var dir = Dir.open("/sys/class/backlight", 0);
                string? name;
                while ((name = dir.read_name()) != null)
                    candidates += name;
            } catch (Error e) {
                // No backlight class is normal on desktops; not an error.
                debug("BrightnessManager: no /sys/class/backlight (%s)", e.message);
            }
            // Prefer non-acpi (intel_backlight > acpi_video0 > anything)
            foreach (var c in candidates) {
                if ("intel" in c || "amdgpu" in c || "nvidia" in c) { backlight_name = c; break; }
            }
            if (backlight_name == null && candidates.length > 0)
                backlight_name = candidates[0];
            if (backlight_name == null) return;
            try {
                string max_str;
                FileUtils.get_contents("/sys/class/backlight/%s/max_brightness".printf(backlight_name), out max_str);
                max_brightness = int.parse(max_str.strip());
                if (max_brightness <= 0) max_brightness = 100;
            } catch (Error e) {
                warning("BrightnessManager: cannot read max_brightness for %s: %s", backlight_name, e.message);
            }
        }

        private void read_current() {
            if (backlight_name == null) return;
            try {
                string cur_str;
                FileUtils.get_contents("/sys/class/backlight/%s/brightness".printf(backlight_name), out cur_str);
                int cur = int.parse(cur_str.strip());
                brightness = (cur * 100.0) / max_brightness;
            } catch (Error e) {
                warning("BrightnessManager: cannot read brightness for %s: %s", backlight_name, e.message);
            }
        }

        // Set 0-100 percent via logind (no root required)

        public void set_level(double percent) {
            if (backlight_name == null) return;
            percent = percent.clamp(1.0, 100.0);
            uint32 raw = (uint32)((percent / 100.0) * max_brightness).clamp(1, max_brightness);
            try {
                var bus = Bus.get_sync(BusType.SYSTEM);
                bus.call_sync(
                    "org.freedesktop.login1",
                    "/org/freedesktop/login1/session/auto",
                    "org.freedesktop.login1.Session",
                    "SetBrightness",
                    new Variant("(ssu)", "backlight", backlight_name, raw),
                    null, DBusCallFlags.NONE, -1, null
                );
                brightness = percent;
                changed();
            } catch (Error e) {
                warning("BrightnessManager: SetBrightness failed: %s", e.message);
            }
        }

        public void step_up() {
            set_level((brightness + 10.0).clamp(1.0, 100.0));
        }

        public void step_down() {
            set_level((brightness - 10.0).clamp(1.0, 100.0));
        }
    }
}
