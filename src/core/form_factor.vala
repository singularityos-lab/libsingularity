namespace Singularity {

    public enum FormFactorKind {
        DESKTOP,
        TABLET,
        PHONE,
        TV,
        WATCH;

        public string to_id() {
            switch (this) {
                case TABLET: return "tablet";
                case PHONE: return "phone";
                case TV: return "tv";
                case WATCH: return "watch";
                default: return "desktop";
            }
        }

        public static bool try_parse(string? id, out FormFactorKind kind) {
            switch ((id ?? "").strip().down()) {
                case "desktop": kind = DESKTOP; return true;
                case "tablet": kind = TABLET; return true;
                case "phone": kind = PHONE; return true;
                case "tv": kind = TV; return true;
                case "watch": kind = WATCH; return true;
                default: kind = DESKTOP; return false;
            }
        }

        public bool is_touch_first() {
            return this == TABLET || this == PHONE || this == WATCH;
        }

        public bool is_handheld() {
            return this == PHONE || this == WATCH;
        }

        public bool is_full_screen() {
            return this != DESKTOP;
        }

        public static FormFactorKind[] all() {
            return { DESKTOP, TABLET, PHONE, TV, WATCH };
        }
    }

    public class FormFactor : Object {

        public const string KEY = "form-factor";
        public const string ENV = "SINTY_FORM_FACTOR";
        public const string AUTO = "auto";
        public const string OUTPUTS_KEY = "output-form-factors";
        public const string OUTPUTS_ENV = "SINTY_OUTPUT_FORM_FACTORS";
        public const string SHELL_MONITOR_KEY = "shell-monitor";

        private const double WATCH_MAX_INCHES = 2.2;
        private const double PHONE_MAX_INCHES = 7.5;
        private const double TABLET_MAX_INCHES = 13.5;
        private const double TV_MIN_INCHES = 32.0;

        private const string CORE_NAME = "dev.sinty.Core1";
        private const string CORE_PATH = "/dev/sinty/Core1";

        private static FormFactor? _default = null;

        private GLib.Settings? _settings = null;

        public FormFactorKind kind { get; private set; default = FormFactorKind.DESKTOP; }

        public string preference { get; private set; default = AUTO; }

        public bool forced { get; private set; default = false; }

        public bool configurable {
            get { return _settings != null && !forced; }
        }

        private HashTable<string, string> _outputs = new HashTable<string, string>(str_hash, str_equal);
        private bool _outputs_forced = false;
        private bool _watching_monitors = false;
        private DBusConnection? _core_bus = null;
        private string _core_form = "";

        public signal void changed(FormFactorKind previous);

        public signal void outputs_changed();

        public static FormFactor get_default() {
            if (_default == null) _default = new FormFactor();
            return _default;
        }

        construct {
            string? env_outputs = GLib.Environment.get_variable(OUTPUTS_ENV);
            if (env_outputs != null) {
                _outputs_forced = true;
                foreach (string pair in env_outputs.split(",")) {
                    string[] kv = pair.split("=", 2);
                    if (kv.length == 2) _outputs.insert(kv[0].strip(), kv[1].strip());
                }
            }
            FormFactorKind env_kind;
            bool env_forced = FormFactorKind.try_parse(GLib.Environment.get_variable(ENV), out env_kind);
            if (env_forced) {
                forced = true;
                preference = env_kind.to_id();
                kind = env_kind;
            }
            var source = GLib.SettingsSchemaSource.get_default();
            string schema_id = Runtime.desktop_settings_schema;
            var schema = source != null ? source.lookup(schema_id, true) : null;
            if (schema == null || !schema.has_key(KEY)) return;
            _settings = new GLib.Settings(schema_id);
            if (!env_forced) {
                _settings.changed[KEY].connect(() => reload());
                reload();
                watch_core.begin();
            }
            if (!_outputs_forced && schema.has_key(OUTPUTS_KEY)) {
                _settings.changed[OUTPUTS_KEY].connect(() => {
                    reload_outputs();
                    outputs_changed();
                });
                reload_outputs();
            }
            if (schema.has_key(SHELL_MONITOR_KEY)) {
                _settings.changed[SHELL_MONITOR_KEY].connect(() => outputs_changed());
            }
        }

        private void reload_outputs() {
            _outputs.remove_all();
            var iter = _settings.get_value(OUTPUTS_KEY).iterator();
            string connector;
            string id;
            while (iter.next("{ss}", out connector, out id)) _outputs.insert(connector, id);
        }

        private void watch_monitors() {
            if (_watching_monitors) return;
            var display = Gdk.Display.get_default();
            if (display == null) return;
            _watching_monitors = true;
            display.get_monitors().items_changed.connect(() => outputs_changed());
        }

        public bool outputs_configurable {
            get { return _settings != null && !_outputs_forced && _settings.settings_schema.has_key(OUTPUTS_KEY); }
        }

        public static bool is_main(Gdk.Monitor monitor) {
            var main = main_monitor();
            return main == null || main == monitor;
        }

        public static Gdk.Monitor? main_monitor() {
            var display = Gdk.Display.get_default();
            if (display == null) return null;
            var monitors = display.get_monitors();
            uint n = monitors.get_n_items();
            if (n == 0) return null;
            var ff = get_default();
            string wanted = "";
            if (ff._settings != null && ff._settings.settings_schema.has_key(SHELL_MONITOR_KEY)) {
                wanted = ff._settings.get_string(SHELL_MONITOR_KEY);
            }
            for (uint i = 0; i < n; i++) {
                var m = (Gdk.Monitor) monitors.get_item(i);
                if (wanted != "" && m.get_connector() == wanted) return m;
            }
            return (Gdk.Monitor) monitors.get_item(0);
        }

        private static bool is_internal_connector(string connector) {
            return connector.has_prefix("eDP") || connector.has_prefix("LVDS") || connector.has_prefix("DSI");
        }

        public static FormFactorKind detect(Gdk.Monitor monitor) {
            string connector = monitor.get_connector() ?? "";
            if (is_internal_connector(connector)) return FormFactorKind.DESKTOP;
            int w = monitor.get_width_mm();
            int h = monitor.get_height_mm();
            if (w <= 0 || h <= 0) return FormFactorKind.DESKTOP;
            double inches = Math.sqrt((double) w * w + (double) h * h) / 25.4;
            if (inches < WATCH_MAX_INCHES) return FormFactorKind.WATCH;
            if (inches < PHONE_MAX_INCHES) return FormFactorKind.PHONE;
            if (inches < TABLET_MAX_INCHES) return FormFactorKind.TABLET;
            if (inches >= TV_MIN_INCHES && connector.has_prefix("HDMI")) return FormFactorKind.TV;
            return FormFactorKind.DESKTOP;
        }

        public string output_preference(string connector) {
            return _outputs.lookup(connector) ?? AUTO;
        }

        public FormFactorKind for_monitor(Gdk.Monitor? monitor) {
            watch_monitors();
            if (monitor == null || is_main(monitor)) return kind;
            FormFactorKind chosen;
            if (FormFactorKind.try_parse(output_preference(monitor.get_connector() ?? ""), out chosen)) return chosen;
            return detect(monitor);
        }

        public bool choose_for_output(string connector, string id) {
            if (!outputs_configurable || connector == "") return false;
            FormFactorKind parsed;
            if (id != AUTO && !FormFactorKind.try_parse(id, out parsed)) return false;
            var builder = new VariantBuilder(new VariantType("a{ss}"));
            _outputs.foreach((k, v) => {
                if (k != connector) builder.add("{ss}", k, v);
            });
            if (id != AUTO) builder.add("{ss}", connector, id);
            return _settings.set_value(OUTPUTS_KEY, builder.end());
        }

        public static FormFactorKind at(Gdk.Monitor? monitor) {
            return get_default().for_monitor(monitor);
        }

        public static Gdk.Monitor? monitor_of(Gtk.Widget widget) {
            var native = widget.get_native();
            var surface = native != null ? native.get_surface() : null;
            if (surface == null) return null;
            return surface.get_display().get_monitor_at_surface(surface);
        }

        public static FormFactorKind of_widget(Gtk.Widget widget) {
            return at(monitor_of(widget));
        }

        private async void watch_core() {
            try {
                _core_bus = yield Bus.get(BusType.SYSTEM);
            } catch (Error e) {
                return;
            }
            _core_bus.signal_subscribe(CORE_NAME, "org.freedesktop.DBus.Properties", "PropertiesChanged", CORE_PATH, null,
                DBusSignalFlags.NONE, () => read_core_form.begin());
            yield read_core_form();
        }

        private async void read_core_form() {
            Variant reply;
            try {
                reply = yield _core_bus.call(CORE_NAME, CORE_PATH, "org.freedesktop.DBus.Properties", "Get",
                    new Variant("(ss)", CORE_NAME, "Form"), new VariantType("(v)"), DBusCallFlags.NO_AUTO_START, -1);
            } catch (Error e) {
                return;
            }
            var value = reply.get_child_value(0).get_variant();
            if (!value.is_of_type(VariantType.STRING) || value.get_string() == _core_form) return;
            _core_form = value.get_string();
            if (_settings != null) reload();
        }

        private void reload() {
            string value = _settings.get_string(KEY);
            preference = value;
            FormFactorKind next;
            if (!FormFactorKind.try_parse(value, out next)) next = _core_form == "tv" ? FormFactorKind.TV : FormFactorKind.DESKTOP;
            if (next == kind) return;
            var previous = kind;
            kind = next;
            changed(previous);
        }

        public bool choose(string id) {
            if (!configurable) return false;
            FormFactorKind parsed;
            if (id != AUTO && !FormFactorKind.try_parse(id, out parsed)) return false;
            return _settings.set_string(KEY, id);
        }

        public static FormFactorKind current() {
            return get_default().kind;
        }

        public static void apply_css_class(Gtk.Widget widget, Gdk.Monitor? monitor = null) {
            var ff = get_default();
            Gdk.Monitor? fixed_monitor = monitor;
            Gdk.Surface? watched = null;
            ulong enter_id = 0;
            sync_css_class(widget, ff.for_monitor(fixed_monitor ?? monitor_of(widget)));
            ulong changed_id = ff.changed.connect(() => sync_css_class(widget, ff.for_monitor(fixed_monitor ?? monitor_of(widget))));
            ulong outputs_id = ff.outputs_changed.connect(() => sync_css_class(widget, ff.for_monitor(fixed_monitor ?? monitor_of(widget))));
            if (fixed_monitor == null) {
                widget.realize.connect_after(() => {
                    var native = widget.get_native();
                    var surface = native != null ? native.get_surface() : null;
                    if (surface == null || surface == watched) return;
                    if (watched != null && enter_id != 0) watched.disconnect(enter_id);
                    watched = surface;
                    enter_id = surface.enter_monitor.connect((m) => sync_css_class(widget, ff.for_monitor(m)));
                    sync_css_class(widget, ff.for_monitor(monitor_of(widget)));
                });
            }
            widget.destroy.connect(() => {
                ff.disconnect(changed_id);
                ff.disconnect(outputs_id);
                if (watched != null && enter_id != 0) watched.disconnect(enter_id);
            });
        }

        private static void sync_css_class(Gtk.Widget widget, FormFactorKind kind) {
            foreach (var k in FormFactorKind.all()) widget.remove_css_class("form-" + k.to_id());
            widget.add_css_class("form-" + kind.to_id());
        }
    }
}
