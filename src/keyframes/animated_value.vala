namespace Singularity.Keyframes {

    public enum Interpolation {
        HOLD,
        LINEAR,
        BEZIER,
        EASE_IN,
        EASE_OUT,
        EASE_IN_OUT;

        public string key() {
            switch (this) {
                case HOLD: return "hold";
                case BEZIER: return "bezier";
                case EASE_IN: return "ease-in";
                case EASE_OUT: return "ease-out";
                case EASE_IN_OUT: return "ease-in-out";
                default: return "linear";
            }
        }

        public string label() {
            switch (this) {
                case HOLD: return _("Hold");
                case BEZIER: return _("Bezier");
                case EASE_IN: return _("Ease In");
                case EASE_OUT: return _("Ease Out");
                case EASE_IN_OUT: return _("Ease In and Out");
                default: return _("Linear");
            }
        }

        public static Interpolation from_key(string key) {
            switch (key) {
                case "hold": return HOLD;
                case "bezier": return BEZIER;
                case "ease-in": return EASE_IN;
                case "ease-out": return EASE_OUT;
                case "ease-in-out": return EASE_IN_OUT;
                default: return LINEAR;
            }
        }

        public static Interpolation[] all() {
            return { LINEAR, HOLD, BEZIER, EASE_IN, EASE_OUT, EASE_IN_OUT };
        }
    }

    public class Keyframe : Object {
        public int64 time;
        public double value;
        public Interpolation interpolation = Interpolation.LINEAR;
        public double out_x = 1.0 / 3.0;
        public double out_y = 0;
        public double in_x = 1.0 / 3.0;
        public double in_y = 0;

        public Keyframe(int64 time, double value, Interpolation interpolation = Interpolation.LINEAR) {
            this.time = time;
            this.value = value;
            this.interpolation = interpolation;
        }

        public Keyframe copy() {
            var k = new Keyframe(time, value, interpolation);
            k.out_x = out_x;
            k.out_y = out_y;
            k.in_x = in_x;
            k.in_y = in_y;
            return k;
        }
    }

    public class AnimatedValue : Object {
        public double value;
        public Gee.ArrayList<Keyframe> keys = new Gee.ArrayList<Keyframe>();

        public AnimatedValue(double value = 0) {
            this.value = value;
        }

        public bool animated {
            get { return keys.size > 0; }
        }

        public AnimatedValue copy() {
            var a = new AnimatedValue(value);
            foreach (var k in keys) a.keys.add(k.copy());
            return a;
        }

        public bool equals(AnimatedValue other) {
            if (value != other.value || keys.size != other.keys.size) return false;
            for (int i = 0; i < keys.size; i++) {
                var a = keys[i];
                var b = other.keys[i];
                if (a.time != b.time || a.value != b.value || a.interpolation != b.interpolation) return false;
            }
            return true;
        }

        public int index_at(int64 time) {
            for (int i = 0; i < keys.size; i++) if (keys[i].time == time) return i;
            return -1;
        }

        public void set_key(int64 time, double v, Interpolation interpolation = Interpolation.LINEAR) {
            int i = index_at(time);
            if (i >= 0) {
                keys[i].value = v;
                keys[i].interpolation = interpolation;
                return;
            }
            var k = new Keyframe(time, v, interpolation);
            int at = 0;
            while (at < keys.size && keys[at].time < time) at++;
            keys.insert(at, k);
        }

        public void set_at(int64 time, double v) {
            if (!animated) {
                value = v;
                return;
            }
            int i = index_at(time);
            var interpolation = Interpolation.LINEAR;
            if (i < 0) {
                for (int j = keys.size - 1; j >= 0; j--) {
                    if (keys[j].time <= time) {
                        interpolation = keys[j].interpolation;
                        break;
                    }
                }
            } else {
                interpolation = keys[i].interpolation;
            }
            set_key(time, v, interpolation);
        }

        public bool remove_key(int64 time) {
            int i = index_at(time);
            if (i < 0) return false;
            if (keys.size == 1) value = keys[0].value;
            keys.remove_at(i);
            return true;
        }

        public void clear_keys() {
            if (keys.size > 0) value = at(keys[0].time);
            keys.clear();
        }

        public void move_key(int64 from, int64 to) {
            int i = index_at(from);
            if (i < 0 || from == to) return;
            var k = keys.remove_at(i);
            int j = index_at(to);
            if (j >= 0) keys.remove_at(j);
            k.time = to;
            int at = 0;
            while (at < keys.size && keys[at].time < to) at++;
            keys.insert(at, k);
        }

        public void shift(int64 delta) {
            foreach (var k in keys) k.time += delta;
        }

        public int64 previous_key(int64 time) {
            int64 result = int64.MIN;
            foreach (var k in keys) if (k.time < time) result = k.time;
            return result;
        }

        public int64 next_key(int64 time) {
            foreach (var k in keys) if (k.time > time) return k.time;
            return int64.MAX;
        }

        public double at(int64 time) {
            if (keys.size == 0) return value;
            if (time <= keys[0].time) return keys[0].value;
            var last = keys[keys.size - 1];
            if (time >= last.time) return last.value;
            for (int i = 0; i < keys.size - 1; i++) {
                var a = keys[i];
                var b = keys[i + 1];
                if (time < a.time || time >= b.time) continue;
                double span = (double) (b.time - a.time);
                double s = span <= 0 ? 1 : (time - a.time) / span;
                return a.value + (b.value - a.value) * shape(a, b, s);
            }
            return last.value;
        }

        public static double shape(Keyframe a, Keyframe b, double s) {
            switch (a.interpolation) {
                case Interpolation.HOLD: return 0;
                case Interpolation.LINEAR: return s;
                case Interpolation.EASE_IN: return cubic(0.42, 0, 1, 1, s);
                case Interpolation.EASE_OUT: return cubic(0, 0, 0.58, 1, s);
                case Interpolation.EASE_IN_OUT: return cubic(0.42, 0, 0.58, 1, s);
                default: return cubic(a.out_x, a.out_y, 1 - b.in_x, 1 - b.in_y, s);
            }
        }

        public static double cubic(double x1, double y1, double x2, double y2, double s) {
            x1 = x1.clamp(0, 1);
            x2 = x2.clamp(0, 1);
            double lo = 0, hi = 1, u = s;
            for (int i = 0; i < 40; i++) {
                double x = bezier(x1, x2, u);
                if ((x - s).abs() < 1e-7) break;
                if (x < s) lo = u; else hi = u;
                u = (lo + hi) / 2;
            }
            return bezier(y1, y2, u);
        }

        private static double bezier(double p1, double p2, double u) {
            double v = 1 - u;
            return 3 * v * v * u * p1 + 3 * v * u * u * p2 + u * u * u;
        }

        public double integral(int64 from, int64 to, int steps = 0) {
            if (to <= from) return 0;
            if (!animated) return value * (to - from);
            int n = steps > 0 ? steps : (int) int64.min(4096, int64.max(16, (to - from) / 1000000));
            double sum = 0;
            double dt = (double) (to - from) / n;
            for (int i = 0; i < n; i++) {
                int64 t = from + (int64) ((i + 0.5) * dt);
                sum += at(t) * dt;
            }
            return sum;
        }

        public Json.Node to_json() {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("value");
            b.add_double_value(value);
            if (keys.size > 0) {
                b.set_member_name("keys");
                b.begin_array();
                foreach (var k in keys) {
                    b.begin_object();
                    b.set_member_name("t");
                    b.add_int_value(k.time);
                    b.set_member_name("v");
                    b.add_double_value(k.value);
                    b.set_member_name("i");
                    b.add_string_value(k.interpolation.key());
                    if (k.interpolation == Interpolation.BEZIER) {
                        b.set_member_name("h");
                        b.begin_array();
                        b.add_double_value(k.out_x);
                        b.add_double_value(k.out_y);
                        b.add_double_value(k.in_x);
                        b.add_double_value(k.in_y);
                        b.end_array();
                    }
                    b.end_object();
                }
                b.end_array();
            }
            b.end_object();
            return b.get_root();
        }

        public static AnimatedValue from_json(Json.Node? node, double fallback = 0) {
            var a = new AnimatedValue(fallback);
            if (node == null) return a;
            if (node.get_node_type() == Json.NodeType.VALUE) {
                a.value = node.get_double();
                return a;
            }
            if (node.get_node_type() != Json.NodeType.OBJECT) return a;
            var o = node.get_object();
            if (o.has_member("value")) a.value = o.get_double_member("value");
            if (o.has_member("keys")) {
                o.get_array_member("keys").foreach_element((arr, i, element) => {
                    if (element.get_node_type() != Json.NodeType.OBJECT) return;
                    var ko = element.get_object();
                    var k = new Keyframe(ko.get_int_member_with_default("t", 0), ko.get_double_member_with_default("v", 0),
                        Interpolation.from_key(ko.get_string_member_with_default("i", "linear")));
                    if (ko.has_member("h")) {
                        var h = ko.get_array_member("h");
                        if (h.get_length() == 4) {
                            k.out_x = h.get_double_element(0);
                            k.out_y = h.get_double_element(1);
                            k.in_x = h.get_double_element(2);
                            k.in_y = h.get_double_element(3);
                        }
                    }
                    int at = 0;
                    while (at < a.keys.size && a.keys[at].time < k.time) at++;
                    if (at < a.keys.size && a.keys[at].time == k.time) a.keys[at] = k;
                    else a.keys.insert(at, k);
                });
            }
            return a;
        }
    }
}
