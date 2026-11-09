using GLib;

namespace Singularity.Profiles {

    public const int FORMAT_VERSION = 1;

    public enum ConditionKind {
        TIME,
        WIFI,
        SCREEN,
        DEVICE,
        FULLSCREEN,
        GAME,
        PRESENTING,
        KEY,
        BATTERY;

        public string to_id() {
            switch (this) {
                case TIME: return "time";
                case WIFI: return "wifi";
                case SCREEN: return "screen";
                case DEVICE: return "device";
                case FULLSCREEN: return "fullscreen";
                case GAME: return "game";
                case PRESENTING: return "presenting";
                case KEY: return "key";
                default: return "battery";
            }
        }

        public static bool from_id(string id, out ConditionKind kind) {
            kind = TIME;
            switch (id) {
                case "time": kind = TIME; return true;
                case "wifi": kind = WIFI; return true;
                case "screen": kind = SCREEN; return true;
                case "device": kind = DEVICE; return true;
                case "fullscreen": kind = FULLSCREEN; return true;
                case "game": kind = GAME; return true;
                case "presenting": kind = PRESENTING; return true;
                case "key": kind = KEY; return true;
                case "battery": kind = BATTERY; return true;
            }
            return false;
        }
    }

    public class Facts : Object {
        public DateTime now { get; set; default = new DateTime.now_local(); }
        public string wifi_ssid { get; set; default = ""; }
        public string[] screens { get; set; default = {}; }
        public string[] devices { get; set; default = {}; }
        public bool fullscreen { get; set; default = false; }
        public bool game { get; set; default = false; }
        public bool presenting { get; set; default = false; }
        public bool key_present { get; set; default = false; }
        public string key_owner { get; set; default = ""; }
        public bool on_battery { get; set; default = false; }
        public int battery_percent { get; set; default = 100; }

        public static bool list_contains(string[] list, string needle) {
            string n = needle.strip().casefold();
            if (n == "") return list.length > 0;
            foreach (string item in list) {
                if (item.casefold().contains(n)) return true;
            }
            return false;
        }
    }

    public class Condition : Object {
        public const int ALL_DAYS = 0x7f;

        public ConditionKind kind { get; set; default = ConditionKind.TIME; }
        public int days { get; set; default = ALL_DAYS; }
        public int start_minute { get; set; default = 9 * 60; }
        public int end_minute { get; set; default = 18 * 60; }
        public string match { get; set; default = ""; }
        public int below_percent { get; set; default = 20; }

        public Condition(ConditionKind kind) {
            this.kind = kind;
        }

        public bool has_day(int day_of_week) {
            return (days & (1 << (day_of_week - 1))) != 0;
        }

        public bool covers(DateTime time) {
            if (days == 0) return false;
            int minute = time.get_hour() * 60 + time.get_minute();
            int today = time.get_day_of_week();
            if (start_minute == end_minute) return has_day(today);
            if (start_minute < end_minute) {
                return has_day(today) && minute >= start_minute && minute < end_minute;
            }
            if (minute >= start_minute) return has_day(today);
            int yesterday = today == 1 ? 7 : today - 1;
            return minute < end_minute && has_day(yesterday);
        }

        public bool holds(Facts f) {
            switch (kind) {
                case ConditionKind.TIME: return covers(f.now);
                case ConditionKind.WIFI: return f.wifi_ssid != "" && (match == "" || f.wifi_ssid == match);
                case ConditionKind.SCREEN: return Facts.list_contains(f.screens, match);
                case ConditionKind.DEVICE: return Facts.list_contains(f.devices, match);
                case ConditionKind.FULLSCREEN: return f.fullscreen;
                case ConditionKind.GAME: return f.game;
                case ConditionKind.PRESENTING: return f.presenting;
                case ConditionKind.KEY: return f.key_present && (match == "" || f.key_owner == match);
                default: return f.on_battery && f.battery_percent <= below_percent;
            }
        }

        public static string format_minute(int minute) {
            return "%02d:%02d".printf(minute / 60, minute % 60);
        }

        public static int parse_minute(string text, int fallback) {
            string[] parts = text.strip().split(":");
            if (parts.length != 2) return fallback;
            int h = int.parse(parts[0]);
            int m = int.parse(parts[1]);
            if (h < 0 || h > 23 || m < 0 || m > 59) return fallback;
            return h * 60 + m;
        }

        public void build(Json.Builder b) {
            b.begin_object();
            b.set_member_name("type"); b.add_string_value(kind.to_id());
            switch (kind) {
                case ConditionKind.TIME:
                    b.set_member_name("days"); b.add_int_value(days);
                    b.set_member_name("start"); b.add_string_value(format_minute(start_minute));
                    b.set_member_name("end"); b.add_string_value(format_minute(end_minute));
                    break;
                case ConditionKind.BATTERY:
                    b.set_member_name("below"); b.add_int_value(below_percent);
                    break;
                case ConditionKind.WIFI:
                case ConditionKind.SCREEN:
                case ConditionKind.DEVICE:
                case ConditionKind.KEY:
                    b.set_member_name("match"); b.add_string_value(match);
                    break;
                default:
                    break;
            }
            b.end_object();
        }

        public static Condition? from_json(Json.Object o) {
            if (!o.has_member("type")) return null;
            ConditionKind kind;
            if (!ConditionKind.from_id(o.get_string_member("type"), out kind)) return null;
            var c = new Condition(kind);
            if (o.has_member("days")) c.days = (int) o.get_int_member("days") & ALL_DAYS;
            if (o.has_member("start")) c.start_minute = parse_minute(o.get_string_member("start"), c.start_minute);
            if (o.has_member("end")) c.end_minute = parse_minute(o.get_string_member("end"), c.end_minute);
            if (o.has_member("match")) c.match = o.get_string_member("match");
            if (o.has_member("below")) c.below_percent = ((int) o.get_int_member("below")).clamp(1, 100);
            return c;
        }
    }

    public class Rule : Object {
        public Gee.ArrayList<Condition> conditions { get; private set; default = new Gee.ArrayList<Condition>(); }
        public bool enabled { get; set; default = true; }

        public int specificity {
            get { return conditions.size; }
        }

        public bool holds(Facts f) {
            if (!enabled || conditions.size == 0) return false;
            foreach (var c in conditions) {
                if (!c.holds(f)) return false;
            }
            return true;
        }

        public void build(Json.Builder b) {
            b.begin_object();
            b.set_member_name("enabled"); b.add_boolean_value(enabled);
            b.set_member_name("conditions");
            b.begin_array();
            foreach (var c in conditions) c.build(b);
            b.end_array();
            b.end_object();
        }

        public static Rule from_json(Json.Object o) {
            var r = new Rule();
            if (o.has_member("enabled")) r.enabled = o.get_boolean_member("enabled");
            if (o.has_member("conditions")) {
                o.get_array_member("conditions").foreach_element((a, i, n) => {
                    if (n.get_node_type() != Json.NodeType.OBJECT) return;
                    var c = Condition.from_json(n.get_object());
                    if (c != null) r.conditions.add(c);
                });
            }
            return r;
        }
    }

    public class Profile : Object {
        public string id { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string icon_name { get; set; default = "focus-custom-symbolic"; }
        public bool builtin { get; set; default = false; }
        public string shortcut { get; set; default = ""; }
        public bool announce { get; set; default = true; }
        public Gee.ArrayList<Rule> rules { get; private set; default = new Gee.ArrayList<Rule>(); }

        private Gee.TreeMap<string, Gee.TreeMap<string, string>> _values = new Gee.TreeMap<string, Gee.TreeMap<string, string>>();

        public Profile(string id, string name, string icon_name, bool builtin = false) {
            this.id = id;
            this.name = name;
            this.icon_name = icon_name;
            this.builtin = builtin;
        }

        public string[] areas() {
            string[] out_areas = {};
            foreach (var e in _values.entries) {
                if (e.value.size > 0) out_areas += e.key;
            }
            return out_areas;
        }

        public Gee.Map<string, string> values_for(string area) {
            var m = _values[area];
            return m != null ? m.read_only_view : new Gee.TreeMap<string, string>().read_only_view;
        }

        public string? get_value(string area, string key) {
            var m = _values[area];
            return m != null ? m[key] : null;
        }

        public void set_value(string area, string key, string json) {
            var m = _values[area];
            if (m == null) {
                m = new Gee.TreeMap<string, string>();
                _values[area] = m;
            }
            m[key] = json;
        }

        public void unset_value(string area, string key) {
            var m = _values[area];
            if (m == null) return;
            m.unset(key);
            if (m.size == 0) _values.unset(area);
        }

        public void clear_area(string area) {
            _values.unset(area);
        }

        public int count_values() {
            int n = 0;
            foreach (var m in _values.values) n += m.size;
            return n;
        }

        public int best_specificity(Facts f) {
            int best = 0;
            foreach (var r in rules) {
                if (r.holds(f) && r.specificity > best) best = r.specificity;
            }
            return best;
        }

        public Rule? matching_rule(Facts f) {
            Rule? best = null;
            foreach (var r in rules) {
                if (r.holds(f) && (best == null || r.specificity > best.specificity)) best = r;
            }
            return best;
        }

        public void build(Json.Builder b) {
            b.begin_object();
            b.set_member_name("id"); b.add_string_value(id);
            b.set_member_name("name"); b.add_string_value(name);
            b.set_member_name("icon"); b.add_string_value(icon_name);
            b.set_member_name("builtin"); b.add_boolean_value(builtin);
            b.set_member_name("shortcut"); b.add_string_value(shortcut);
            b.set_member_name("announce"); b.add_boolean_value(announce);
            b.set_member_name("settings");
            b.begin_object();
            foreach (var area in _values.entries) {
                b.set_member_name(area.key);
                b.begin_object();
                foreach (var kv in area.value.entries) {
                    b.set_member_name(kv.key);
                    b.add_value(parse_value(kv.value));
                }
                b.end_object();
            }
            b.end_object();
            b.set_member_name("rules");
            b.begin_array();
            foreach (var r in rules) r.build(b);
            b.end_array();
            b.end_object();
        }

        public string to_data() {
            var b = new Json.Builder();
            build(b);
            return to_text(b.get_root(), false);
        }

        public static Profile? from_json(Json.Object o) {
            if (!o.has_member("id")) return null;
            string id = o.get_string_member("id").strip();
            if (id == "") return null;
            var p = new Profile(id,
                o.has_member("name") ? o.get_string_member("name") : id,
                o.has_member("icon") ? o.get_string_member("icon") : "focus-custom-symbolic",
                o.has_member("builtin") && o.get_boolean_member("builtin"));
            if (o.has_member("shortcut")) p.shortcut = o.get_string_member("shortcut");
            if (o.has_member("announce")) p.announce = o.get_boolean_member("announce");
            if (o.has_member("settings") && o.get_member("settings").get_node_type() == Json.NodeType.OBJECT) {
                var settings = o.get_object_member("settings");
                settings.foreach_member((so, area, node) => {
                    if (node.get_node_type() != Json.NodeType.OBJECT) return;
                    node.get_object().foreach_member((ao, key, vnode) => {
                        p.set_value(area, key, to_text(vnode, false));
                    });
                });
            }
            if (o.has_member("rules")) {
                o.get_array_member("rules").foreach_element((a, i, n) => {
                    if (n.get_node_type() == Json.NodeType.OBJECT) p.rules.add(Rule.from_json(n.get_object()));
                });
            }
            return p;
        }

        public static Profile? from_data(string data) {
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

    public string to_text(Json.Node node, bool pretty) {
        var gen = new Json.Generator();
        gen.pretty = pretty;
        gen.set_root(node);
        return gen.to_data(null);
    }

    public Json.Node parse_value(string json) {
        try {
            var parser = new Json.Parser();
            parser.load_from_data(json);
            var root = parser.get_root();
            if (root != null) return root.copy();
        } catch (Error e) {
        }
        var n = new Json.Node(Json.NodeType.VALUE);
        n.set_string(json);
        return n;
    }

    public string value_text(Json.Node node) {
        return to_text(node, false);
    }

    public string bool_value(bool v) {
        return v ? "true" : "false";
    }

    public string string_value(string v) {
        var n = new Json.Node(Json.NodeType.VALUE);
        n.set_string(v);
        return to_text(n, false);
    }

    public string int_value(int64 v) {
        return v.to_string();
    }

    public string double_value(double v) {
        var n = new Json.Node(Json.NodeType.VALUE);
        n.set_double(v);
        return to_text(n, false);
    }

    public bool same_value(string? a, string? b) {
        if (a == null || b == null) return a == b;
        if (a == b) return true;
        return parse_value(a).equal(parse_value(b));
    }

    public class Selection : Object {
        public Profile? profile { get; construct; }
        public Rule? rule { get; construct; }
        public bool manual { get; construct; }

        public Selection(Profile? profile, Rule? rule, bool manual) {
            Object(profile: profile, rule: rule, manual: manual);
        }
    }

    public class ProfileSet : Object {
        public Gee.ArrayList<Profile> profiles { get; private set; default = new Gee.ArrayList<Profile>(); }

        public Profile? find(string id) {
            foreach (var p in profiles) {
                if (p.id == id) return p;
            }
            return null;
        }

        public string unique_id(string name) {
            var sb = new StringBuilder();
            foreach (char c in name.down().to_utf8()) {
                if (c.isalnum()) sb.append_c(c);
                else if (sb.len > 0 && sb.str[sb.len - 1] != '-') sb.append_c('-');
            }
            string slug = sb.str;
            while (slug.has_suffix("-")) slug = slug.substring(0, slug.length - 1);
            string base_id = slug != "" ? "custom-" + slug : "custom";
            string candidate = base_id;
            int n = 2;
            while (find(candidate) != null) candidate = "%s-%d".printf(base_id, n++);
            return candidate;
        }

        public Selection choose(string manual_id, string suppressed_id, Facts facts) {
            if (manual_id != "") {
                var manual = find(manual_id);
                if (manual != null) return new Selection(manual, null, true);
            }
            Profile? best = null;
            Rule? best_rule = null;
            foreach (var p in profiles) {
                if (p.id == suppressed_id) continue;
                var r = p.matching_rule(facts);
                if (r == null) continue;
                if (best_rule == null || r.specificity > best_rule.specificity) {
                    best = p;
                    best_rule = r;
                }
            }
            return new Selection(best, best_rule, false);
        }

        public string to_data() {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("version"); b.add_int_value(FORMAT_VERSION);
            b.set_member_name("profiles");
            b.begin_array();
            foreach (var p in profiles) p.build(b);
            b.end_array();
            b.end_object();
            return to_text(b.get_root(), true);
        }

        public static ProfileSet? from_data(string data) {
            try {
                var parser = new Json.Parser();
                parser.load_from_data(data);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return null;
                var obj = root.get_object();
                if (obj.has_member("version") && obj.get_int_member("version") > FORMAT_VERSION) return null;
                var set = new ProfileSet();
                if (obj.has_member("profiles")) {
                    obj.get_array_member("profiles").foreach_element((a, i, n) => {
                        if (n.get_node_type() != Json.NodeType.OBJECT) return;
                        var p = Profile.from_json(n.get_object());
                        if (p != null && set.find(p.id) == null) set.profiles.add(p);
                    });
                }
                return set;
            } catch (Error e) {
                return null;
            }
        }

        public static ProfileSet defaults() {
            var set = new ProfileSet();

            var work = new Profile("work", "Work", "focus-work-symbolic", true);
            work.set_value(Areas.NOTIFICATIONS, "rules", notifications_rules(false, true, true, false));
            var work_rule = new Rule();
            var hours = new Condition(ConditionKind.TIME);
            hours.days = 0x1f;
            hours.start_minute = 9 * 60;
            hours.end_minute = 18 * 60;
            work_rule.conditions.add(hours);
            work_rule.enabled = false;
            work.rules.add(work_rule);
            set.profiles.add(work);

            var evening = new Profile("evening", "Evening", "weather-clear-night-symbolic", true);
            evening.set_value(Areas.APPEARANCE, "dark-mode", "true");
            evening.set_value(Areas.APPEARANCE, "night-light", "true");
            evening.set_value(Areas.NOTIFICATIONS, "rules", notifications_rules(true, true, true, false));
            var evening_rule = new Rule();
            var evening_time = new Condition(ConditionKind.TIME);
            evening_time.start_minute = 20 * 60;
            evening_time.end_minute = 23 * 60;
            evening_rule.conditions.add(evening_time);
            evening_rule.enabled = false;
            evening.rules.add(evening_rule);
            set.profiles.add(evening);

            var game = new Profile("game", "Game", "input-gaming-symbolic", true);
            game.set_value(Areas.NOTIFICATIONS, "rules", notifications_rules(false, true, false, true));
            game.set_value(Areas.ENERGY, "mode", string_value("performance"));
            var game_rule = new Rule();
            game_rule.conditions.add(new Condition(ConditionKind.GAME));
            game.rules.add(game_rule);
            set.profiles.add(game);

            var present = new Profile("presentation", "Presentation", "x-office-presentation-symbolic", true);
            present.set_value(Areas.NOTIFICATIONS, "rules", notifications_rules(false, false, false, true));
            present.set_value(Areas.SYSTEM, "keep-awake", "true");
            var present_rule = new Rule();
            present_rule.conditions.add(new Condition(ConditionKind.PRESENTING));
            present.rules.add(present_rule);
            set.profiles.add(present);

            var sleep = new Profile("sleep", "Sleep", "focus-sleep-symbolic", true);
            sleep.set_value(Areas.NOTIFICATIONS, "rules", notifications_rules(false, true, true, true));
            sleep.set_value(Areas.APPEARANCE, "dark-mode", "true");
            sleep.set_value(Areas.APPEARANCE, "night-light", "true");
            var sleep_rule = new Rule();
            var night = new Condition(ConditionKind.TIME);
            night.start_minute = 23 * 60;
            night.end_minute = 7 * 60;
            sleep_rule.conditions.add(night);
            sleep_rule.enabled = false;
            sleep.rules.add(sleep_rule);
            set.profiles.add(sleep);

            return set;
        }

        public static string notifications_rules(bool time_sensitive, bool repeated_calls, bool badges, bool mute_sounds) {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("silence"); b.add_boolean_value(true);
            b.set_member_name("allow-time-sensitive"); b.add_boolean_value(time_sensitive);
            b.set_member_name("allow-repeated-calls"); b.add_boolean_value(repeated_calls);
            b.set_member_name("show-badges"); b.add_boolean_value(badges);
            b.set_member_name("mute-sounds"); b.add_boolean_value(mute_sounds);
            b.set_member_name("apps"); b.begin_array(); b.end_array();
            b.set_member_name("people"); b.begin_array(); b.end_array();
            b.end_object();
            return to_text(b.get_root(), false);
        }
    }

    namespace Areas {
        public const string NOTIFICATIONS = "notifications";
        public const string APPS = "apps";
        public const string APPEARANCE = "appearance";
        public const string DISPLAY = "display";
        public const string ENERGY = "energy";
        public const string AUDIO = "audio";
        public const string BLUETOOTH = "bluetooth";
        public const string VPN = "vpn";
        public const string PRINTER = "printer";
        public const string SYSTEM = "system";
        public const string DOCK = "dock";
        public const string LAUNCHER = "launcher";
        public const string WIDGETS = "widgets";
        public const string AGENT = "agent";
        public const string STATE = "state";
        public const string APP_PREFIX = "app:";
    }
}
