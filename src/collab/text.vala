namespace Singularity.Collab {

    public class Text : Shared {
        private class Item {
            public int64 ts;
            public string site;
            public string ch;
            public bool deleted;

            public string key() {
                return "%lld@%s".printf(ts, site);
            }
        }

        private Gee.ArrayList<Item> items = new Gee.ArrayList<Item>();
        private Gee.HashSet<string> seen_deletes = new Gee.HashSet<string>();

        public signal void inserted(int offset, string text, string author);
        public signal void removed(int offset, int length, string author);

        public Text(string initial = "") {
            Object();
            int64 ts = 0;
            unichar c;
            int i = 0;
            while (initial.get_next_char(ref i, out c)) {
                var it = new Item();
                it.ts = ++ts;
                it.site = "";
                it.ch = c.to_string();
                items.add(it);
            }
        }

        public string to_string() {
            var sb = new StringBuilder();
            foreach (var it in items) if (!it.deleted) sb.append(it.ch);
            return sb.str;
        }

        public int length {
            get {
                int n = 0;
                foreach (var it in items) if (!it.deleted) n++;
                return n;
            }
        }

        private int index_of_visible(int offset) {
            if (offset <= 0) return -1;
            int seen = 0;
            for (int i = 0; i < items.size; i++) {
                if (items[i].deleted) continue;
                seen++;
                if (seen == offset) return i;
            }
            return items.size - 1;
        }

        private int visible_before(int index) {
            int n = 0;
            for (int i = 0; i < index && i < items.size; i++) if (!items[i].deleted) n++;
            return n;
        }

        private int find(int64 ts, string site) {
            for (int i = 0; i < items.size; i++) {
                if (items[i].ts == ts && items[i].site == site) return i;
            }
            return -2;
        }

        private static bool greater(int64 ts, string site, Item other) {
            if (ts != other.ts) return ts > other.ts;
            return strcmp(site, other.site) > 0;
        }

        public void insert(int offset, string text) {
            if (text == "") return;
            int at = index_of_visible(offset);
            int64 after_ts = at >= 0 ? items[at].ts : 0;
            string after_site = at >= 0 ? items[at].site : "";
            var chars = new Json.Array();
            int pos = at + 1;
            unichar c;
            int i = 0;
            int64 first = 0;
            while (text.get_next_char(ref i, out c)) {
                var it = new Item();
                it.ts = tick();
                if (first == 0) first = it.ts;
                it.site = site;
                it.ch = c.to_string();
                items.insert(pos++, it);
                chars.add_string_element(it.ch);
            }
            var o = new Json.Object();
            o.set_string_member("k", "i");
            o.set_int_member("at", after_ts);
            o.set_string_member("as", after_site);
            o.set_int_member("t", first);
            o.set_string_member("s", site);
            o.set_array_member("c", chars);
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(o);
            queue(node);
        }

        public void delete(int offset, int length) {
            if (length <= 0) return;
            var ids = new Json.Array();
            int seen = 0;
            int removed_count = 0;
            for (int i = 0; i < items.size && removed_count < length; i++) {
                if (items[i].deleted) continue;
                if (seen >= offset) {
                    items[i].deleted = true;
                    var id = new Json.Array();
                    id.add_int_element(items[i].ts);
                    id.add_string_element(items[i].site);
                    ids.add_array_element(id);
                    removed_count++;
                } else {
                    seen++;
                }
            }
            var o = new Json.Object();
            o.set_string_member("k", "d");
            o.set_array_member("ids", ids);
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(o);
            queue(node);
        }

        protected override void apply(Json.Node node, string author) {
            if (node.get_node_type() != Json.NodeType.OBJECT) return;
            var o = node.get_object();
            string k = o.get_string_member_with_default("k", "");
            if (k == "i") apply_insert(o, author);
            else if (k == "d") apply_delete(o, author);
        }

        private void apply_insert(Json.Object o, string author) {
            int64 after_ts = o.get_int_member_with_default("at", 0);
            string after_site = o.get_string_member_with_default("as", "");
            int64 ts = o.get_int_member_with_default("t", 0);
            string from = o.get_string_member_with_default("s", "");
            var chars = o.get_array_member("c");
            if (chars == null || chars.get_length() == 0) return;
            if (find(ts, from) >= 0) return;
            int prev = after_ts == 0 && after_site == "" ? -1 : find(after_ts, after_site);
            if (prev == -2) return;
            int pos = prev + 1;
            while (pos < items.size && greater(items[pos].ts, items[pos].site, new_item(ts, from))) pos++;
            int start_visible = visible_before(pos);
            var sb = new StringBuilder();
            for (uint i = 0; i < chars.get_length(); i++) {
                var it = new_item(ts + i, from);
                it.ch = chars.get_string_element(i);
                if (seen_deletes.remove(it.key())) it.deleted = true;
                items.insert(pos + (int) i, it);
                if (!it.deleted) sb.append(it.ch);
                observe(it.ts);
            }
            if (sb.len > 0) inserted(start_visible, sb.str, author);
        }

        private Item new_item(int64 ts, string site) {
            var it = new Item();
            it.ts = ts;
            it.site = site;
            it.ch = "";
            return it;
        }

        private void apply_delete(Json.Object o, string author) {
            var ids = o.get_array_member("ids");
            if (ids == null) return;
            for (uint i = 0; i < ids.get_length(); i++) {
                var id = ids.get_array_element(i);
                if (id == null || id.get_length() < 2) continue;
                int64 ts = id.get_int_element(0);
                string from = id.get_string_element(1);
                int idx = find(ts, from);
                if (idx < 0) {
                    seen_deletes.add("%lld@%s".printf(ts, from));
                    continue;
                }
                if (items[idx].deleted) continue;
                int offset = visible_before(idx);
                items[idx].deleted = true;
                removed(offset, 1, author);
            }
        }

        public string snapshot() {
            var arr = new Json.Array();
            foreach (var it in items) {
                var a = new Json.Array();
                a.add_int_element(it.ts);
                a.add_string_element(it.site);
                a.add_string_element(it.ch);
                a.add_boolean_element(it.deleted);
                arr.add_array_element(a);
            }
            var o = new Json.Object();
            o.set_array_member("items", arr);
            return encode(o);
        }

        public void load(string snapshot) {
            var o = decode(snapshot);
            if (o == null || !o.has_member("items")) return;
            items.clear();
            var arr = o.get_array_member("items");
            for (uint i = 0; i < arr.get_length(); i++) {
                var a = arr.get_array_element(i);
                var it = new_item(a.get_int_element(0), a.get_string_element(1));
                it.ch = a.get_string_element(2);
                it.deleted = a.get_boolean_element(3);
                observe(it.ts);
                items.add(it);
            }
        }
    }
}
