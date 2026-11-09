using GLib;

namespace Singularity.Profiles {

    public const string AREA_INTERFACE = "dev.sinty.ProfileArea1";
    public const string AREA_PATH_PREFIX = "/dev/sinty/ProfileArea/";

    [DBus (name = "dev.sinty.ProfileArea1")]
    public interface AreaService : Object {
        public abstract string describe() throws GLib.Error;
        public abstract HashTable<string, string> snapshot(string[] keys) throws GLib.Error;
        public abstract void apply(HashTable<string, string> values) throws GLib.Error;
        public signal void changed(string[] keys);
    }

    [DBus (name = "dev.sinty.ProfileArea1")]
    public interface AreaProxy : Object {
        public abstract async string describe() throws GLib.Error;
        public abstract async HashTable<string, string> snapshot(string[] keys) throws GLib.Error;
        public abstract async void apply(HashTable<string, string> values) throws GLib.Error;
        public signal void changed(string[] keys);
    }

    public enum OptionKind {
        BOOLEAN,
        INTEGER,
        NUMBER,
        TEXT,
        CHOICE,
        STRUCTURED;

        public string to_id() {
            switch (this) {
                case BOOLEAN: return "boolean";
                case INTEGER: return "integer";
                case NUMBER: return "number";
                case TEXT: return "text";
                case CHOICE: return "choice";
                default: return "structured";
            }
        }

        public static OptionKind from_id(string id) {
            switch (id) {
                case "boolean": return BOOLEAN;
                case "integer": return INTEGER;
                case "number": return NUMBER;
                case "text": return TEXT;
                case "choice": return CHOICE;
                default: return STRUCTURED;
            }
        }
    }

    public class Choice : Object {
        public string value { get; set; default = ""; }
        public string label { get; set; default = ""; }

        public Choice(string value, string label) {
            this.value = value;
            this.label = label;
        }
    }

    public class Option : Object {
        public string key { get; set; default = ""; }
        public string label { get; set; default = ""; }
        public string subtitle { get; set; default = ""; }
        public OptionKind kind { get; set; default = OptionKind.BOOLEAN; }
        public double min { get; set; default = 0; }
        public double max { get; set; default = 100; }
        public bool read_only { get; set; default = false; }
        public Gee.ArrayList<Choice> choices { get; private set; default = new Gee.ArrayList<Choice>(); }

        public Option(string key, string label, OptionKind kind) {
            this.key = key;
            this.label = label;
            this.kind = kind;
        }

        public Option with_range(double min, double max) {
            this.min = min;
            this.max = max;
            return this;
        }

        public Option with_subtitle(string subtitle) {
            this.subtitle = subtitle;
            return this;
        }

        public Option add_choice(string value, string label) {
            choices.add(new Choice(value, label));
            return this;
        }

        public string? label_for(string json) {
            var node = parse_value(json);
            if (kind == OptionKind.CHOICE && node.get_value_type() == typeof(string)) {
                string v = node.get_string();
                foreach (var c in choices) {
                    if (c.value == v) return c.label;
                }
                return v;
            }
            return null;
        }

        public void build(Json.Builder b) {
            b.begin_object();
            b.set_member_name("key"); b.add_string_value(key);
            b.set_member_name("label"); b.add_string_value(label);
            b.set_member_name("subtitle"); b.add_string_value(subtitle);
            b.set_member_name("kind"); b.add_string_value(kind.to_id());
            b.set_member_name("min"); b.add_double_value(min);
            b.set_member_name("max"); b.add_double_value(max);
            b.set_member_name("read-only"); b.add_boolean_value(read_only);
            b.set_member_name("choices");
            b.begin_array();
            foreach (var c in choices) {
                b.begin_object();
                b.set_member_name("value"); b.add_string_value(c.value);
                b.set_member_name("label"); b.add_string_value(c.label);
                b.end_object();
            }
            b.end_array();
            b.end_object();
        }

        public static Option? from_json(Json.Object o) {
            if (!o.has_member("key")) return null;
            var opt = new Option(o.get_string_member("key"),
                o.has_member("label") ? o.get_string_member("label") : o.get_string_member("key"),
                OptionKind.from_id(o.has_member("kind") ? o.get_string_member("kind") : ""));
            if (o.has_member("subtitle")) opt.subtitle = o.get_string_member("subtitle");
            if (o.has_member("min")) opt.min = o.get_double_member("min");
            if (o.has_member("max")) opt.max = o.get_double_member("max");
            if (o.has_member("read-only")) opt.read_only = o.get_boolean_member("read-only");
            if (o.has_member("choices")) {
                o.get_array_member("choices").foreach_element((a, i, n) => {
                    if (n.get_node_type() != Json.NodeType.OBJECT) return;
                    var co = n.get_object();
                    opt.add_choice(co.has_member("value") ? co.get_string_member("value") : "",
                        co.has_member("label") ? co.get_string_member("label") : "");
                });
            }
            return opt;
        }
    }

    public class AreaInfo : Object {
        public string id { get; set; default = ""; }
        public string label { get; set; default = ""; }
        public string icon_name { get; set; default = ""; }
        public Gee.ArrayList<Option> options { get; private set; default = new Gee.ArrayList<Option>(); }

        public AreaInfo(string id, string label, string icon_name) {
            this.id = id;
            this.label = label;
            this.icon_name = icon_name;
        }

        public Option? find(string key) {
            foreach (var o in options) {
                if (o.key == key) return o;
            }
            return null;
        }

        public void build(Json.Builder b) {
            b.begin_object();
            b.set_member_name("id"); b.add_string_value(id);
            b.set_member_name("label"); b.add_string_value(label);
            b.set_member_name("icon"); b.add_string_value(icon_name);
            b.set_member_name("options");
            b.begin_array();
            foreach (var o in options) o.build(b);
            b.end_array();
            b.end_object();
        }

        public string to_data() {
            var b = new Json.Builder();
            build(b);
            return to_text(b.get_root(), false);
        }

        public static AreaInfo? from_json(Json.Object o) {
            if (!o.has_member("id")) return null;
            var info = new AreaInfo(o.get_string_member("id"),
                o.has_member("label") ? o.get_string_member("label") : o.get_string_member("id"),
                o.has_member("icon") ? o.get_string_member("icon") : "");
            if (o.has_member("options")) {
                o.get_array_member("options").foreach_element((a, i, n) => {
                    if (n.get_node_type() != Json.NodeType.OBJECT) return;
                    var opt = Option.from_json(n.get_object());
                    if (opt != null) info.options.add(opt);
                });
            }
            return info;
        }

        public static AreaInfo? from_data(string data) {
            try {
                var parser = new Json.Parser();
                parser.load_from_data(data);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return null;
                return from_json(root.get_object());
            } catch (Error e) {
                return null;
            }
        }
    }

    public delegate string? ReadValue(string key);
    public delegate void WriteValue(string key, string json);

    public class Area : Object, AreaService {
        public AreaInfo info { get; private set; }
        private ReadValue? _read = null;
        private WriteValue? _write = null;
        private Gee.HashMap<string, GLib.Settings> _bound = new Gee.HashMap<string, GLib.Settings>();
        private Gee.HashMap<string, string> _bound_keys = new Gee.HashMap<string, string>();
        private uint _registration = 0;
        private DBusConnection? _connection = null;

        public Area(string id, string label, string icon_name) {
            info = new AreaInfo(id, label, icon_name);
        }

        public void handlers(owned ReadValue read, owned WriteValue write) {
            _read = (owned) read;
            _write = (owned) write;
        }

        public Option add(Option option) {
            info.options.add(option);
            return option;
        }

        public Option bind_setting(GLib.Settings settings, string settings_key, Option option) {
            info.options.add(option);
            _bound[option.key] = settings;
            _bound_keys[option.key] = settings_key;
            settings.changed[settings_key].connect(() => notify_changed({ option.key }));
            return option;
        }

        public void notify_changed(string[] keys) {
            changed(keys);
        }

        public string describe() throws GLib.Error {
            return info.to_data();
        }

        public HashTable<string, string> snapshot(string[] keys) throws GLib.Error {
            var out_values = new HashTable<string, string>(str_hash, str_equal);
            string[] wanted = keys;
            if (wanted.length == 0) {
                foreach (var o in info.options) wanted += o.key;
            }
            foreach (string key in wanted) {
                string? v = read_value(key);
                if (v != null) out_values[key] = v;
            }
            return out_values;
        }

        public void apply(HashTable<string, string> values) throws GLib.Error {
            values.foreach((key, json) => {
                var opt = info.find(key);
                if (opt == null || opt.read_only) return;
                write_value(key, json);
            });
        }

        private string? read_value(string key) {
            if (_bound.has_key(key)) {
                var v = _bound[key].get_value(_bound_keys[key]);
                return to_text(Json.gvariant_serialize(v), false);
            }
            return _read != null ? _read(key) : null;
        }

        private void write_value(string key, string json) {
            if (_bound.has_key(key)) {
                var settings = _bound[key];
                string skey = _bound_keys[key];
                var type = settings.get_value(skey).get_type_string();
                try {
                    var v = Json.gvariant_deserialize(parse_value(json), type);
                    if (v != null) settings.set_value(skey, v);
                } catch (Error e) {
                    warning("profiles: bad value for %s.%s: %s", info.id, key, e.message);
                }
                return;
            }
            if (_write != null) _write(key, json);
        }

        public string object_path {
            owned get { return AREA_PATH_PREFIX + path_segment(info.id); }
        }

        public bool export(DBusConnection connection) {
            unexport();
            try {
                _registration = connection.register_object(object_path, (AreaService) this);
                _connection = connection;
                return true;
            } catch (IOError e) {
                warning("profiles: could not export area %s: %s", info.id, e.message);
                return false;
            }
        }

        public void unexport() {
            if (_registration != 0 && _connection != null) _connection.unregister_object(_registration);
            _registration = 0;
            _connection = null;
        }

        public static string path_segment(string id) {
            var sb = new StringBuilder();
            foreach (char c in id.to_utf8()) {
                if (c.isalnum()) sb.append_c(c);
                else sb.append_c('_');
            }
            return sb.len > 0 ? sb.str : "_";
        }
    }
}
