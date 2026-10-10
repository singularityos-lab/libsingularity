namespace Singularity.Collab {

    public class Document : Shared {
        private class Entry {
            public string? value;
            public int64 ts;
            public string site;
        }

        private Gee.HashMap<string, Entry> entries = new Gee.HashMap<string, Entry>();

        public signal void changed(string key, string? value, string author);

        public Document() {
            Object();
        }

        public string? get(string key) {
            var e = entries[key];
            return e != null ? e.value : null;
        }

        public Gee.List<string> keys() {
            var list = new Gee.ArrayList<string>();
            foreach (var e in entries.entries) if (e.value.value != null) list.add(e.key);
            list.sort();
            return list;
        }

        public Gee.Map<string, string> values() {
            var map = new Gee.HashMap<string, string>();
            foreach (var e in entries.entries) if (e.value.value != null) map[e.key] = e.value.value;
            return map;
        }

        public void set(string key, string? value) {
            var cur = entries[key];
            if (cur != null && cur.value == value) return;
            if (cur == null && value == null) return;
            var e = new Entry();
            e.value = value;
            e.ts = tick();
            e.site = site;
            entries[key] = e;
            queue(op(key, e));
        }

        public void remove(string key) {
            set(key, null);
        }

        public int update(Gee.Map<string, string> current) {
            int n = 0;
            foreach (var e in current.entries) {
                var cur = entries[e.key];
                if (cur == null || cur.value != e.value) {
                    set(e.key, e.value);
                    n++;
                }
            }
            foreach (var e in entries.entries.to_array()) {
                if (e.value.value != null && !current.has_key(e.key)) {
                    set(e.key, null);
                    n++;
                }
            }
            return n;
        }

        private static Json.Node op(string key, Entry e) {
            var a = new Json.Array();
            a.add_string_element(key);
            if (e.value != null) a.add_string_element(e.value);
            else a.add_null_element();
            a.add_int_element(e.ts);
            a.add_string_element(e.site);
            var node = new Json.Node(Json.NodeType.ARRAY);
            node.set_array(a);
            return node;
        }

        private static bool newer(int64 ts, string site, Entry? cur) {
            if (cur == null) return true;
            if (ts != cur.ts) return ts > cur.ts;
            return strcmp(site, cur.site) > 0;
        }

        protected override void apply(Json.Node node, string author) {
            if (node.get_node_type() != Json.NodeType.ARRAY) return;
            var a = node.get_array();
            if (a.get_length() < 4) return;
            string key = a.get_string_element(0);
            var vnode = a.get_element(1);
            string? value = vnode.is_null() ? null : vnode.get_string();
            int64 ts = a.get_int_element(2);
            string from = a.get_string_element(3);
            observe(ts);
            var cur = entries[key];
            if (!newer(ts, from, cur)) return;
            var e = new Entry();
            e.value = value;
            e.ts = ts;
            e.site = from;
            entries[key] = e;
            changed(key, value, author);
        }

        public string snapshot() {
            var o = new Json.Object();
            foreach (var e in entries.entries) {
                var a = new Json.Array();
                if (e.value.value != null) a.add_string_element(e.value.value);
                else a.add_null_element();
                a.add_int_element(e.value.ts);
                a.add_string_element(e.value.site);
                o.set_array_member(e.key, a);
            }
            return encode(o);
        }

        public void load(string snapshot) {
            entries.clear();
            var o = decode(snapshot);
            if (o == null) return;
            foreach (string key in o.get_members()) {
                var a = o.get_array_member(key);
                if (a == null || a.get_length() < 3) continue;
                var e = new Entry();
                var vnode = a.get_element(0);
                e.value = vnode.is_null() ? null : vnode.get_string();
                e.ts = a.get_int_element(1);
                e.site = a.get_string_element(2);
                observe(e.ts);
                entries[key] = e;
            }
        }

        public void load_values(Gee.Map<string, string> values) {
            entries.clear();
            foreach (var v in values.entries) {
                var e = new Entry();
                e.value = v.value;
                e.ts = 0;
                e.site = "";
                entries[v.key] = e;
            }
        }
    }
}
