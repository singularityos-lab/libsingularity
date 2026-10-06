namespace Singularity.Print {

    public enum ExtraKind {
        SWITCH,
        CHOICE,
        NUMBER,
        NOTE
    }

    public class ExtraSetting : Object {
        public string key { get; construct; }
        public ExtraKind kind { get; construct; }
        public string title { get; construct; }
        public string subtitle { get; set; default = ""; }
        public string[] choice_ids = {};
        public string[] choice_labels = {};
        public double min { get; set; }
        public double max { get; set; default = 100; }
        public double step { get; set; default = 1; }
        public int digits { get; set; }
        public Variant? value { get; set; }
        public Variant? default_value { get; set; }
        public bool reflow { get; set; default = true; }
        public string depends_key { get; set; default = ""; }
        public string[] depends_values = {};

        public ExtraSetting(string key, ExtraKind kind, string title) {
            Object(key: key, kind: kind, title: title);
        }

        public bool accepts(Variant v) {
            switch (kind) {
                case ExtraKind.SWITCH:
                    return v.is_of_type(VariantType.BOOLEAN);
                case ExtraKind.CHOICE:
                    return v.is_of_type(VariantType.STRING) && v.get_string() in choice_ids;
                case ExtraKind.NUMBER:
                    return v.is_of_type(VariantType.DOUBLE);
                default:
                    return false;
            }
        }

        public int choice_index() {
            if (kind != ExtraKind.CHOICE || value == null) return 0;
            string id = value.get_string();
            for (int i = 0; i < choice_ids.length; i++) if (choice_ids[i] == id) return i;
            return 0;
        }
    }

    public class ExtraOptions : Object {
        public string title { get; set; default = ""; }
        public string description { get; set; default = ""; }

        private Gee.ArrayList<ExtraSetting> list = new Gee.ArrayList<ExtraSetting>();

        public signal void changed(string key, bool reflow);

        public ExtraOptions(string title, string description = "") {
            Object(title: title, description: description);
        }

        public Gee.List<ExtraSetting> items {
            owned get { return list.read_only_view; }
        }

        public ExtraSetting? find(string key) {
            foreach (var o in list) if (o.key == key) return o;
            return null;
        }

        private ExtraSetting add(string key, ExtraKind kind, string title, string? subtitle) {
            var existing = find(key);
            if (existing != null) list.remove(existing);
            var o = new ExtraSetting(key, kind, title);
            if (subtitle != null) o.subtitle = subtitle;
            list.add(o);
            return o;
        }

        public ExtraSetting add_switch(string key, string title, string? subtitle, bool active) {
            var o = add(key, ExtraKind.SWITCH, title, subtitle);
            o.default_value = new Variant.boolean(active);
            o.value = o.default_value;
            return o;
        }

        public ExtraSetting add_choice(string key, string title, string[] ids, string[] labels, string active) {
            var o = add(key, ExtraKind.CHOICE, title, null);
            o.choice_ids = ids;
            o.choice_labels = labels.length == ids.length ? labels : ids;
            string start = active in ids ? active : (ids.length > 0 ? ids[0] : "");
            o.default_value = new Variant.string(start);
            o.value = o.default_value;
            return o;
        }

        public ExtraSetting add_number(string key, string title, string? subtitle, double min, double max,
                                      double step, double current, int digits = 0) {
            var o = add(key, ExtraKind.NUMBER, title, subtitle);
            o.min = min;
            o.max = max;
            o.step = step;
            o.digits = digits;
            o.default_value = new Variant.double(current.clamp(min, max));
            o.value = o.default_value;
            return o;
        }

        public ExtraSetting add_note(string key, string title, string text) {
            var o = add(key, ExtraKind.NOTE, title, text);
            o.reflow = false;
            return o;
        }

        public void show_when(string key, string depends_key, string[] values) {
            var o = find(key);
            if (o == null) return;
            o.depends_key = depends_key;
            o.depends_values = values;
        }

        public bool is_visible(string key) {
            var o = find(key);
            if (o == null) return false;
            if (o.depends_key == "") return true;
            var d = find(o.depends_key);
            if (d == null || d.value == null || !is_visible(d.key)) return false;
            string current;
            if (d.kind == ExtraKind.SWITCH) current = d.value.get_boolean() ? "true" : "false";
            else if (d.kind == ExtraKind.CHOICE) current = d.value.get_string();
            else current = "%g".printf(d.value.get_double());
            return current in o.depends_values;
        }

        public bool get_bool(string key) {
            var o = find(key);
            return o != null && o.kind == ExtraKind.SWITCH && o.value != null && o.value.get_boolean();
        }

        public string get_choice(string key) {
            var o = find(key);
            return o != null && o.kind == ExtraKind.CHOICE && o.value != null ? o.value.get_string() : "";
        }

        public double get_number(string key) {
            var o = find(key);
            return o != null && o.kind == ExtraKind.NUMBER && o.value != null ? o.value.get_double() : 0;
        }

        public bool set_value(string key, Variant v) {
            var o = find(key);
            if (o == null || !o.accepts(v)) return false;
            Variant next = o.kind == ExtraKind.NUMBER ? new Variant.double(v.get_double().clamp(o.min, o.max)) : v;
            if (o.value != null && o.value.equal(next)) return false;
            o.value = next;
            changed(key, o.reflow);
            return true;
        }

        public void set_bool(string key, bool v) {
            set_value(key, new Variant.boolean(v));
        }

        public void set_choice(string key, string id) {
            set_value(key, new Variant.string(id));
        }

        public void set_number(string key, double v) {
            set_value(key, new Variant.double(v));
        }

        public void reset() {
            foreach (var o in list) o.value = o.default_value;
        }

        public void store(HashTable<string, Variant> into) {
            foreach (var o in list) {
                if (o.kind == ExtraKind.NOTE || o.value == null) continue;
                into.insert(o.key, o.value);
            }
        }

        public void restore(HashTable<string, Variant> from) {
            foreach (var o in list) {
                var v = from.lookup(o.key);
                if (v == null || !o.accepts(v)) continue;
                o.value = o.kind == ExtraKind.NUMBER ? new Variant.double(v.get_double().clamp(o.min, o.max)) : v;
            }
        }
    }
}
