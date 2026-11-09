namespace Singularity {

    public class EdidFacts : Object {
        public string id { get; private set; default = ""; }
        public bool emissive { get; private set; default = false; }

        public static EdidFacts parse(uint8[] edid) {
            var facts = new EdidFacts();
            if (edid.length < 18) return facts;
            uint64 hash = 0xcbf29ce484222325ULL;
            for (int i = 8; i < 18; i++) {
                hash ^= edid[i];
                hash *= 0x100000001b3ULL;
            }
            facts.id = "%016llx".printf(hash);
            facts.emissive = name_says_oled(edid) || hdr_black_level_is_emissive(edid);
            return facts;
        }

        public static EdidFacts for_connector(string drm_name) {
            uint8[] data;
            try {
                FileUtils.get_data("/sys/class/drm/%s/edid".printf(drm_name), out data);
            } catch (Error e) {
                data = {};
            }
            return parse(data);
        }

        private static bool name_says_oled(uint8[] edid) {
            if (edid.length < 128) return false;
            for (int d = 54; d + 18 <= 126; d += 18) {
                if (edid[d] != 0 || edid[d + 1] != 0 || (edid[d + 3] != 0xFC && edid[d + 3] != 0xFE)) continue;
                var text = new StringBuilder();
                for (int i = d + 5; i < d + 18 && edid[i] != 0x0A; i++) text.append_c((char) edid[i]);
                if (text.str.up().contains("OLED")) return true;
            }
            return false;
        }

        private static bool hdr_black_level_is_emissive(uint8[] edid) {
            for (int block = 128; block + 128 <= edid.length; block += 128) {
                if (edid[block] != 0x02) continue;
                int end = block + edid[block + 2];
                int at = block + 4;
                while (at < end && at < block + 127) {
                    int tag = edid[at] >> 5;
                    int len = edid[at] & 0x1f;
                    if (tag == 7 && len >= 6 && edid[at + 1] == 0x06) {
                        double max_nits = 50.0 * Math.pow(2.0, edid[at + 4] / 32.0);
                        double min_nits = max_nits * Math.pow(edid[at + 6] / 255.0, 2.0) / 100.0;
                        return edid[at + 4] != 0 && min_nits < 0.01;
                    }
                    at += len + 1;
                }
            }
            return false;
        }
    }

    public enum BrightnessMethod {
        BACKLIGHT,
        DDC,
        SOFTWARE;

        public string to_label() {
            switch (this) {
                case BACKLIGHT: return _("Backlight");
                case DDC: return _("Monitor Control (DDC/CI)");
                default: return _("Dimming in Software");
            }
        }
    }

    public delegate void SoftwareBrightnessFunc(string connector, double fraction);

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
        public BrightnessMethod method { get; internal set; default = BrightnessMethod.SOFTWARE; }
        public string edid_id { get; internal set; default = ""; }
        public bool emissive { get; internal set; default = false; }
        public bool saves_energy { get { return method != BrightnessMethod.SOFTWARE || emissive; } }
        public signal void changed();

        public const double SOFTWARE_FLOOR = 0.15;

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
            } else {
                BrightnessManager.get_default().dim(connector, software_fraction(hardware));
            }
            BrightnessManager.get_default().remember(this, hardware);
        }

        public static double software_fraction(double hardware) {
            return SOFTWARE_FLOOR + (1.0 - SOFTWARE_FLOOR) * hardware.clamp(0.0, 100.0) / 100.0;
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
        private Gee.HashMap<string, double?> remembered = new Gee.HashMap<string, double?>();
        private Gee.HashMap<string, double?> pending_dim = new Gee.HashMap<string, double?>();
        private SoftwareBrightnessFunc? software_func = null;
        private uint save_source = 0;
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
            load_remembered();
            detect_backlight();
            read_current();
            watch_for_external_changes();
            probe_external_displays();
        }

        /** Every display whose brightness can be controlled, internal panel first. */
        public Gee.List<DisplayBrightness> displays {
            owned get { return _displays.read_only_view; }
        }

        public DisplayBrightness? primary {
            get { return panel ?? (_displays.size > 0 ? _displays[0] : null); }
        }

        public void set_software_backend(owned SoftwareBrightnessFunc func) {
            software_func = (owned) func;
            foreach (var entry in pending_dim.entries) software_func(entry.key, entry.value);
            pending_dim.clear();
        }

        internal void dim(string connector, double fraction) {
            if (software_func != null) software_func(connector, fraction);
            else pending_dim[connector] = fraction;
        }

        public void reset_software() {
            foreach (var display in _displays) {
                if (display.method != BrightnessMethod.SOFTWARE) continue;
                display.update_from_hardware(100.0);
                remember(display, 100.0);
            }
            changed();
        }

        private static string store_path() {
            return Path.build_filename(Environment.get_user_state_dir(), "singularity", "brightness");
        }

        private void load_remembered() {
            string text;
            try {
                FileUtils.get_contents(store_path(), out text);
            } catch (Error e) {
                return;
            }
            foreach (string line in text.split("\n")) {
                string[] f = line.split(" ");
                if (f.length >= 2) remembered[f[0]] = double.parse(f[1]) / 10.0;
            }
        }

        internal void remember(DisplayBrightness display, double hardware) {
            string key = display.edid_id != "" ? display.edid_id : display.connector;
            remembered[key] = hardware;
            var system = new StringBuilder();
            foreach (var d in _displays) {
                string k = d.edid_id != "" ? d.edid_id : d.connector;
                if (!remembered.has_key(k)) continue;
                string m = d.method == BrightnessMethod.BACKLIGHT ? "backlight" : d.method == BrightnessMethod.DDC ? "ddc" : "software";
                uint value = d.method == BrightnessMethod.SOFTWARE
                    ? (uint) (DisplayBrightness.software_fraction(remembered[k]) * 1000.0 + 0.5)
                    : (uint) (remembered[k] * 10.0 + 0.5);
                system.append("%s %u %s\n".printf(k, value, m));
            }
            string snapshot = system.str;
            if (save_source != 0) Source.remove(save_source);
            save_source = Timeout.add(600, () => {
                save_source = 0;
                save(snapshot);
                return Source.REMOVE;
            });
        }

        private void save(string system_lines) {
            var local = new StringBuilder();
            foreach (var entry in remembered.entries)
                local.append("%s %u\n".printf(entry.key, (uint) (entry.value * 10.0 + 0.5)));
            try {
                DirUtils.create_with_parents(Path.get_dirname(store_path()), 0700);
                FileUtils.set_contents(store_path(), local.str);
            } catch (Error e) {
                debug("BrightnessManager: cannot save levels: %s", e.message);
            }
            Bus.get.begin(BusType.SYSTEM, null, (o, r) => {
                try {
                    var bus = Bus.get.end(r);
                    bus.call.begin("dev.sinty.Brightness", "/dev/sinty/Brightness", "dev.sinty.Brightness1", "Store",
                        new Variant("(s)", system_lines), null, DBusCallFlags.NO_AUTO_START, 3000, null);
                } catch (Error e) {
                }
            });
        }

        private void restore(DisplayBrightness display) {
            string key = display.edid_id != "" ? display.edid_id : display.connector;
            if (!remembered.has_key(key)) {
                if (display.method == BrightnessMethod.SOFTWARE) display.update_from_hardware(100.0);
                return;
            }
            double hardware = remembered[key];
            display.set_level(DisplayBrightness.hardware_to_level(hardware, display.min_percent, display.max_percent));
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
            panel.method = BrightnessMethod.BACKLIGHT;
            var facts = EdidFacts.for_connector(drm_name_for(connector));
            panel.edid_id = facts.id;
            panel.emissive = facts.emissive;
            try {
                string max_str;
                FileUtils.get_contents("/sys/class/backlight/%s/max_brightness".printf(backlight_name), out max_str);
                panel.backlight_max = int.parse(max_str.strip());
                if (panel.backlight_max <= 0) panel.backlight_max = 100;
            } catch (Error e) {
                warning("BrightnessManager: cannot read max_brightness for %s: %s", backlight_name, e.message);
            }
            apply_stored_limits(panel);
            _displays.add(panel);
            connect_primary();
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

        private static string drm_name_for(string connector) {
            try {
                var dir = Dir.open("/sys/class/drm", 0);
                string? name;
                while ((name = dir.read_name()) != null) {
                    if (name.has_prefix("card") && name.has_suffix("-" + connector)) return name;
                }
            } catch (Error e) {
            }
            return "";
        }

        private ulong primary_handler = 0;
        private DisplayBrightness? primary_bound = null;

        private void connect_primary() {
            var p = primary;
            if (p == primary_bound) return;
            if (primary_bound != null && primary_handler != 0) primary_bound.disconnect(primary_handler);
            primary_bound = p;
            primary_handler = 0;
            if (p == null) return;
            primary_handler = p.changed.connect(() => {
                brightness = p.percent;
                changed();
            });
            brightness = p.percent;
            changed();
        }

        private void probe_external_displays() {
            var candidates = new Gee.HashMap<string, string>();
            var connected = new Gee.HashMap<string, string>();
            try {
                var dir = Dir.open("/sys/class/drm", 0);
                string? name;
                while ((name = dir.read_name()) != null) {
                    int dash = name.index_of("-");
                    if (!name.has_prefix("card") || dash < 0) continue;
                    string connector = name.substring(dash + 1);
                    if (panel != null && connector == panel.connector) continue;
                    string status;
                    try {
                        FileUtils.get_contents("/sys/class/drm/%s/status".printf(name), out status);
                    } catch (Error e) {
                        continue;
                    }
                    if (status.strip() != "connected") continue;
                    connected[connector] = name;
                    try {
                        string bus = Path.get_basename(FileUtils.read_link("/sys/class/drm/%s/ddc".printf(name)));
                        candidates[connector] = "/dev/" + bus;
                    } catch (Error e) {
                    }
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
                    update_external_displays(connected, devices, maxima, currents);
                    return Source.REMOVE;
                });
                return true;
            });
        }

        private void update_external_displays(Gee.HashMap<string, string> connected,
                                              Gee.HashMap<string, string> devices,
                                              Gee.HashMap<string, uint> maxima,
                                              Gee.HashMap<string, uint> currents) {
            bool changed_any = false;
            foreach (var display in _displays.to_array()) {
                if (display.internal_panel) continue;
                bool gone = !connected.has_key(display.connector);
                bool method_changed = (display.method == BrightnessMethod.DDC) != devices.has_key(display.connector);
                if (gone || method_changed) {
                    _displays.remove(display);
                    changed_any = true;
                }
            }
            foreach (var entry in connected.entries) {
                var display = for_connector(entry.key);
                bool fresh = display == null;
                if (fresh) {
                    display = new DisplayBrightness(entry.key, false);
                    var facts = EdidFacts.for_connector(entry.value);
                    display.edid_id = facts.id;
                    display.emissive = facts.emissive;
                    if (devices.has_key(entry.key)) {
                        display.ddc = new Ddc(devices[entry.key]);
                        display.method = BrightnessMethod.DDC;
                    } else {
                        display.method = BrightnessMethod.SOFTWARE;
                    }
                    apply_stored_limits(display);
                    _displays.add(display);
                    changed_any = true;
                }
                if (display.method == BrightnessMethod.DDC) {
                    display.ddc_max = (uint16) maxima[entry.key];
                    display.update_from_hardware(currents[entry.key] * 100.0 / display.ddc_max);
                }
                if (fresh) restore(display);
            }
            if (changed_any) {
                connect_primary();
                displays_changed();
            }
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

        /** Sets the 0-100 level of the primary display, within its brightness limits. */
        public void set_level(double percent) {
            var p = primary;
            if (p == null) return;
            p.set_level(percent.clamp(p.method == BrightnessMethod.BACKLIGHT ? 1.0 : 0.0, 100.0));
        }

        public void step_up() {
            set_level(brightness + 10.0);
        }

        public void step_down() {
            set_level(brightness - 10.0);
        }
    }
}
