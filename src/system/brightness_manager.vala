namespace Singularity {

    /**
     * Brightness of one connected display: the internal panel through its
     * backlight, or an external monitor through DDC/CI.
     *
     * The user-facing level runs 0-100 and is mapped into the display's
     * minimum and maximum brightness limits before it reaches the hardware.
     */
    public class DisplayBrightness : Object {
        public string connector { get; construct; }
        public bool internal_panel { get; construct; }
        public double percent { get; private set; default = 50.0; }
        public double min_percent { get; private set; default = 0.0; }
        public double max_percent { get; private set; default = 100.0; }
        public signal void changed();

        internal string? backlight_name = null;
        internal int backlight_max = 100;
        internal Ddc? ddc = null;
        internal uint16 ddc_max = 100;

        internal DisplayBrightness(string connector, bool internal_panel) {
            Object(connector: connector, internal_panel: internal_panel);
        }

        internal static double hardware_to_level(double hardware, double min, double max) {
            if (max - min < 1.0) return 100.0;
            return ((hardware - min) * 100.0 / (max - min)).clamp(0.0, 100.0);
        }

        internal static double level_to_hardware(double level, double min, double max) {
            return min + level.clamp(0.0, 100.0) * (max - min) / 100.0;
        }

        internal void apply_limits(double min, double max) {
            min_percent = min.clamp(0.0, 99.0);
            max_percent = max.clamp(min_percent + 1.0, 100.0);
        }

        internal void update_from_hardware(double hardware_percent) {
            double previous = percent;
            percent = hardware_to_level(hardware_percent, min_percent, max_percent);
            if (percent != previous) changed();
        }

        /** Sets the 0-100 level, mapped into the display's brightness limits. */
        public void set_level(double percent) {
            double hardware = level_to_hardware(percent, min_percent, max_percent);
            this.percent = percent.clamp(0.0, 100.0);
            changed();
            if (backlight_name != null) {
                write_backlight(hardware);
            } else if (ddc != null) {
                uint16 raw = (uint16) (hardware * ddc_max / 100.0 + 0.5);
                var bus = ddc;
                new Thread<bool>("ddc-set", () => bus.set_vcp(Ddc.VCP_BRIGHTNESS, raw));
            }
        }

        /** Stores new minimum and maximum brightness percentages for this display. */
        public void set_limits(double min, double max) {
            BrightnessManager.get_default().store_limits(connector, min, max);
        }

        private void write_backlight(double hardware) {
            uint32 raw = (uint32) ((hardware / 100.0) * backlight_max).clamp(1, backlight_max);
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
            } catch (Error e) {
                warning("BrightnessManager: SetBrightness failed: %s", e.message);
            }
        }
    }

    public class BrightnessManager : Object {
        private static BrightnessManager? _instance = null;
        private const string LIMITS_KEY = "display-brightness-limits";

        public double brightness { get; private set; default = 50.0; }
        public signal void changed();
        public signal void displays_changed();

        private Gee.ArrayList<DisplayBrightness> _displays = new Gee.ArrayList<DisplayBrightness>();
        private DisplayBrightness? panel = null;
        private GUdev.Client? udev_client = null;
        private GLib.Settings? settings = null;

        public static BrightnessManager get_default() {
            if (_instance == null) _instance = new BrightnessManager();
            return _instance;
        }

        public BrightnessManager() {
            var source = SettingsSchemaSource.get_default();
            var schema = source != null ? source.lookup("dev.sinty.desktop", true) : null;
            if (schema != null && schema.has_key(LIMITS_KEY)) {
                settings = new GLib.Settings("dev.sinty.desktop");
                settings.changed[LIMITS_KEY].connect(reload_limits);
            }
            detect_backlight();
            read_current();
            watch_for_external_changes();
            probe_external_displays();
        }

        /** Every display whose brightness can be controlled, internal panel first. */
        public Gee.List<DisplayBrightness> displays {
            owned get { return _displays.read_only_view; }
        }

        public DisplayBrightness? for_connector(string connector) {
            foreach (var display in _displays) {
                if (display.connector == connector) return display;
            }
            return null;
        }

        private void watch_for_external_changes() {
            udev_client = new GUdev.Client({ "backlight", "drm" });
            udev_client.uevent.connect((action, device) => {
                if (device.get_subsystem() == "drm") {
                    probe_external_displays();
                    return;
                }
                if (panel == null || device.get_name() != panel.backlight_name) return;
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
                debug("BrightnessManager: no /sys/class/backlight (%s)", e.message);
            }
            string? backlight_name = null;
            foreach (var c in candidates) {
                if ("intel" in c || "amdgpu" in c || "nvidia" in c) { backlight_name = c; break; }
            }
            if (backlight_name == null && candidates.length > 0)
                backlight_name = candidates[0];
            if (backlight_name == null) return;

            string connector = "panel";
            try {
                string target = FileUtils.read_link("/sys/class/backlight/%s/device".printf(backlight_name));
                string base_name = Path.get_basename(target);
                int dash = base_name.index_of("-");
                if (base_name.has_prefix("card") && dash > 0) connector = base_name.substring(dash + 1);
            } catch (FileError e) {
                debug("BrightnessManager: backlight %s has no connector link", backlight_name);
            }
            panel = new DisplayBrightness(connector, true);
            panel.backlight_name = backlight_name;
            try {
                string max_str;
                FileUtils.get_contents("/sys/class/backlight/%s/max_brightness".printf(backlight_name), out max_str);
                panel.backlight_max = int.parse(max_str.strip());
                if (panel.backlight_max <= 0) panel.backlight_max = 100;
            } catch (Error e) {
                warning("BrightnessManager: cannot read max_brightness for %s: %s", backlight_name, e.message);
            }
            apply_stored_limits(panel);
            panel.changed.connect(() => {
                brightness = panel.percent;
                changed();
            });
            _displays.add(panel);
        }

        private void read_current() {
            if (panel == null) return;
            try {
                string cur_str;
                FileUtils.get_contents("/sys/class/backlight/%s/brightness".printf(panel.backlight_name), out cur_str);
                int cur = int.parse(cur_str.strip());
                panel.update_from_hardware((cur * 100.0) / panel.backlight_max);
                brightness = panel.percent;
            } catch (Error e) {
                warning("BrightnessManager: cannot read brightness for %s: %s", panel.backlight_name, e.message);
            }
        }

        private void probe_external_displays() {
            var candidates = new Gee.HashMap<string, string>();
            try {
                var dir = Dir.open("/sys/class/drm", 0);
                string? name;
                while ((name = dir.read_name()) != null) {
                    int dash = name.index_of("-");
                    if (!name.has_prefix("card") || dash < 0) continue;
                    string connector = name.substring(dash + 1);
                    if (panel != null && connector == panel.connector) continue;
                    string status;
                    FileUtils.get_contents("/sys/class/drm/%s/status".printf(name), out status);
                    if (status.strip() != "connected") continue;
                    string bus = Path.get_basename(FileUtils.read_link("/sys/class/drm/%s/ddc".printf(name)));
                    candidates[connector] = "/dev/" + bus;
                }
            } catch (Error e) {
                debug("BrightnessManager: drm scan stopped: %s", e.message);
            }
            new Thread<bool>("ddc-probe", () => {
                var devices = new Gee.HashMap<string, string>();
                var maxima = new Gee.HashMap<string, uint>();
                var currents = new Gee.HashMap<string, uint>();
                foreach (var entry in candidates.entries) {
                    uint16 current, maximum;
                    var ddc = new Ddc(entry.value);
                    if (ddc.get_vcp(Ddc.VCP_BRIGHTNESS, out current, out maximum)) {
                        devices[entry.key] = entry.value;
                        maxima[entry.key] = maximum;
                        currents[entry.key] = current;
                    }
                }
                Idle.add(() => {
                    update_external_displays(devices, maxima, currents);
                    return Source.REMOVE;
                });
                return true;
            });
        }

        private void update_external_displays(Gee.HashMap<string, string> devices,
                                              Gee.HashMap<string, uint> maxima,
                                              Gee.HashMap<string, uint> currents) {
            bool changed_any = false;
            foreach (var display in _displays.to_array()) {
                if (!display.internal_panel && !devices.has_key(display.connector)) {
                    _displays.remove(display);
                    changed_any = true;
                }
            }
            foreach (var entry in devices.entries) {
                var display = for_connector(entry.key);
                if (display == null) {
                    display = new DisplayBrightness(entry.key, false);
                    display.ddc = new Ddc(entry.value);
                    apply_stored_limits(display);
                    _displays.add(display);
                    changed_any = true;
                }
                display.ddc_max = (uint16) maxima[entry.key];
                display.update_from_hardware(currents[entry.key] * 100.0 / display.ddc_max);
            }
            if (changed_any) displays_changed();
        }

        private void apply_stored_limits(DisplayBrightness display) {
            double min = 0.0, max = 100.0;
            if (settings != null) {
                var limits = settings.get_value(LIMITS_KEY);
                Variant? entry = limits.lookup_value(display.connector, new VariantType("(dd)"));
                if (entry != null) entry.get("(dd)", out min, out max);
            }
            display.apply_limits(min, max);
        }

        private void reload_limits() {
            foreach (var display in _displays) {
                double hardware = DisplayBrightness.level_to_hardware(display.percent, display.min_percent, display.max_percent);
                apply_stored_limits(display);
                display.update_from_hardware(hardware);
            }
        }

        internal void store_limits(string connector, double min, double max) {
            if (settings == null) return;
            var builder = new VariantBuilder(new VariantType("a{s(dd)}"));
            var current = settings.get_value(LIMITS_KEY);
            var iter = current.iterator();
            string key;
            double lo, hi;
            while (iter.next("{s(dd)}", out key, out lo, out hi)) {
                if (key != connector) builder.add("{s(dd)}", key, lo, hi);
            }
            builder.add("{s(dd)}", connector, min.clamp(0.0, 99.0), max.clamp(1.0, 100.0));
            settings.set_value(LIMITS_KEY, builder.end());
        }

        /** Sets the 0-100 level of the internal panel, within its brightness limits. */
        public void set_level(double percent) {
            if (panel == null) return;
            panel.set_level(percent.clamp(1.0, 100.0));
        }

        public void step_up() {
            set_level((brightness + 10.0).clamp(1.0, 100.0));
        }

        public void step_down() {
            set_level((brightness - 10.0).clamp(1.0, 100.0));
        }
    }
}
