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

        private static FormFactor? _default = null;

        private GLib.Settings? _settings = null;

        public FormFactorKind kind { get; private set; default = FormFactorKind.DESKTOP; }

        public string preference { get; private set; default = AUTO; }

        public bool forced { get; private set; default = false; }

        public bool configurable {
            get { return _settings != null && !forced; }
        }

        public signal void changed(FormFactorKind previous);

        public static FormFactor get_default() {
            if (_default == null) _default = new FormFactor();
            return _default;
        }

        construct {
            FormFactorKind env_kind;
            if (FormFactorKind.try_parse(GLib.Environment.get_variable(ENV), out env_kind)) {
                forced = true;
                preference = env_kind.to_id();
                kind = env_kind;
                return;
            }
            var source = GLib.SettingsSchemaSource.get_default();
            string schema_id = Runtime.desktop_settings_schema;
            var schema = source != null ? source.lookup(schema_id, true) : null;
            if (schema == null || !schema.has_key(KEY)) return;
            _settings = new GLib.Settings(schema_id);
            _settings.changed[KEY].connect(() => reload());
            reload();
        }

        private void reload() {
            string value = _settings.get_string(KEY);
            preference = value;
            FormFactorKind next;
            if (!FormFactorKind.try_parse(value, out next)) next = FormFactorKind.DESKTOP;
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

        public static void apply_css_class(Gtk.Widget widget) {
            var ff = get_default();
            sync_css_class(widget, ff.kind);
            ulong id = ff.changed.connect(() => sync_css_class(widget, ff.kind));
            widget.destroy.connect(() => ff.disconnect(id));
        }

        private static void sync_css_class(Gtk.Widget widget, FormFactorKind kind) {
            foreach (var k in FormFactorKind.all()) widget.remove_css_class("form-" + k.to_id());
            widget.add_css_class("form-" + kind.to_id());
        }
    }
}
