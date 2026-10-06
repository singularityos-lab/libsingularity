namespace Singularity.Accounts {

    /**
     * One content line of an iCalendar (RFC 5545) or vCard (RFC 6350)
     * object: NAME;PARAM=VALUE:value.
     */
    public class ContentLine : Object {
        /** Upper case property name, without any group prefix. */
        public string name { get; set; }
        /** Raw value, still escaped. */
        public string value { get; set; default = ""; }
        /** Group prefix of vCard lines (item1.EMAIL), or an empty string. */
        public string group { get; set; default = ""; }
        /** Parameters with upper case names. */
        public Gee.HashMap<string, string> parameters = new Gee.HashMap<string, string>();

        public ContentLine(string name, string value = "") {
            Object(name: name.up(), value: value);
        }

        /** The value with TEXT escaping removed. */
        public string text {
            owned get { return unescape_text(value); }
        }

        /** Returns a parameter, or null. */
        public string? param(string key) {
            return parameters[key.up()];
        }

        /** Parses one unfolded line, or returns null when it has no colon. */
        public static ContentLine? parse(string line) {
            int colon = -1;
            bool quoted = false;
            for (int i = 0; i < line.length; i++) {
                char c = line[i];
                if (c == '"') quoted = !quoted;
                else if (c == ':' && !quoted) { colon = i; break; }
            }
            if (colon <= 0) return null;
            string head = line.substring(0, colon);
            var result = new ContentLine("X", line.substring(colon + 1));
            var parts = split_params(head);
            string full = parts[0];
            int dot = full.index_of(".");
            if (dot > 0) {
                result.group = full.substring(0, dot);
                full = full.substring(dot + 1);
            }
            result.name = full.up();
            for (int i = 1; i < parts.length; i++) {
                int eq = parts[i].index_of("=");
                if (eq <= 0) {
                    result.parameters["TYPE"] = parts[i];
                    continue;
                }
                string v = parts[i].substring(eq + 1);
                if (v.has_prefix("\"") && v.has_suffix("\"") && v.length >= 2) v = v.substring(1, v.length - 2);
                result.parameters[parts[i].substring(0, eq).up()] = v;
            }
            return result;
        }

        private static string[] split_params(string head) {
            string[] parts = {};
            var sb = new StringBuilder();
            bool quoted = false;
            for (int i = 0; i < head.length; i++) {
                char c = head[i];
                if (c == '"') quoted = !quoted;
                if (c == ';' && !quoted) {
                    parts += sb.str;
                    sb.truncate(0);
                } else {
                    sb.append_c(c);
                }
            }
            parts += sb.str;
            return parts;
        }

        /** Serialises the line, folded at 75 octets. */
        public string to_string() {
            var sb = new StringBuilder();
            if (group != "") sb.append(group).append_c('.');
            sb.append(name);
            foreach (var entry in parameters.entries) {
                string v = entry.value;
                if (v.contains(":") || v.contains(";") || v.contains(",")) {
                    if (entry.key != "TYPE") v = "\"" + v + "\"";
                }
                sb.append_c(';').append(entry.key).append_c('=').append(v);
            }
            sb.append_c(':').append(value);
            return fold(sb.str);
        }

        /** Folds a line at 75 octets without splitting UTF-8 sequences. */
        public static string fold(string line) {
            if (line.length <= 75) return line + "\r\n";
            var sb = new StringBuilder();
            int count = 0;
            int i = 0;
            while (i < line.length) {
                int next = i + 1;
                while (next < line.length && (line[next] & 0xC0) == 0x80) next++;
                int len = next - i;
                if (count + len > 75) {
                    sb.append("\r\n ");
                    count = 1;
                }
                sb.append_len(line.offset(i), len);
                count += len;
                i = next;
            }
            sb.append("\r\n");
            return sb.str;
        }

        /** Escapes TEXT values (backslash, comma, semicolon, newline). */
        public static string escape_text(string text) {
            return text.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\r\n", "\\n").replace("\n", "\\n");
        }

        /** Removes TEXT escaping. */
        public static string unescape_text(string value) {
            var sb = new StringBuilder();
            for (int i = 0; i < value.length; i++) {
                char c = value[i];
                if (c == '\\' && i + 1 < value.length) {
                    char n = value[++i];
                    if (n == 'n' || n == 'N') sb.append_c('\n');
                    else sb.append_c(n);
                } else {
                    sb.append_c(c);
                }
            }
            return sb.str;
        }
    }

    /**
     * An iCalendar or vCard component (VCALENDAR, VEVENT, VTODO, VCARD...)
     * with its lines and nested components, preserving unknown properties.
     */
    public class Component : Object {
        /** Upper case component name. */
        public string name { get; set; }
        /** Lines in document order. */
        public Gee.ArrayList<ContentLine> lines = new Gee.ArrayList<ContentLine>();
        /** Nested components. */
        public Gee.ArrayList<Component> children = new Gee.ArrayList<Component>();

        public Component(string name) {
            Object(name: name.up());
        }

        /** Unfolds the text and parses the first top-level component, or returns null. */
        public static Component? parse(string text) {
            var all = parse_all(text);
            return all.size > 0 ? all[0] : null;
        }

        /** Parses every top-level component in the text. */
        public static Gee.List<Component> parse_all(string text) {
            var result = new Gee.ArrayList<Component>();
            var stack = new Gee.ArrayList<Component>();
            foreach (string raw in unfold(text)) {
                var line = ContentLine.parse(raw);
                if (line == null) continue;
                if (line.name == "BEGIN") {
                    var c = new Component(line.value.strip());
                    if (stack.size > 0) stack[stack.size - 1].children.add(c);
                    stack.add(c);
                } else if (line.name == "END") {
                    if (stack.size == 0) continue;
                    var c = stack.remove_at(stack.size - 1);
                    if (stack.size == 0) result.add(c);
                } else if (stack.size > 0) {
                    stack[stack.size - 1].lines.add(line);
                }
            }
            return result;
        }

        /** Joins folded lines (RFC 5545 section 3.1). */
        public static string[] unfold(string text) {
            string[] out_lines = {};
            var sb = new StringBuilder();
            bool have = false;
            foreach (string l in text.replace("\r\n", "\n").replace("\r", "\n").split("\n")) {
                if ((l.has_prefix(" ") || l.has_prefix("\t")) && have) {
                    sb.append(l.substring(1));
                    continue;
                }
                if (have) out_lines += sb.str;
                sb.truncate(0);
                sb.append(l);
                have = true;
            }
            if (have && sb.len > 0) out_lines += sb.str;
            return out_lines;
        }

        /** First line with the name, or null. */
        public ContentLine? get_line(string line_name) {
            string n = line_name.up();
            foreach (var l in lines) if (l.name == n) return l;
            return null;
        }

        /** Every line with the name. */
        public Gee.List<ContentLine> get_lines(string line_name) {
            string n = line_name.up();
            var result = new Gee.ArrayList<ContentLine>();
            foreach (var l in lines) if (l.name == n) result.add(l);
            return result;
        }

        /** Unescaped text of the first line with the name, or an empty string. */
        public string get_text(string line_name) {
            var l = get_line(line_name);
            return l != null ? l.text : "";
        }

        /** Raw value of the first line with the name, or an empty string. */
        public string get_value(string line_name) {
            var l = get_line(line_name);
            return l != null ? l.value : "";
        }

        /** Removes every line with the name. */
        public void remove(string line_name) {
            string n = line_name.up();
            var keep = new Gee.ArrayList<ContentLine>();
            foreach (var l in lines) if (l.name != n) keep.add(l);
            lines = keep;
        }

        /** Replaces every line with the name by one raw value and returns it. */
        public ContentLine set_value(string line_name, string raw_value) {
            var existing = get_line(line_name);
            if (existing != null) {
                remove(line_name);
            }
            var l = new ContentLine(line_name, raw_value);
            lines.add(l);
            return l;
        }

        /** Replaces every line with the name by one escaped text value. */
        public ContentLine set_text(string line_name, string text) {
            return set_value(line_name, ContentLine.escape_text(text));
        }

        /** Adds a line without removing others. */
        public ContentLine add_value(string line_name, string raw_value) {
            var l = new ContentLine(line_name, raw_value);
            lines.add(l);
            return l;
        }

        /** First nested component with the name, or null. */
        public Component? get_child(string child_name) {
            string n = child_name.up();
            foreach (var c in children) if (c.name == n) return c;
            return null;
        }

        /** Serialises the component with CRLF line endings. */
        public string to_string() {
            var sb = new StringBuilder();
            sb.append("BEGIN:").append(name).append("\r\n");
            foreach (var l in lines) sb.append(l.to_string());
            foreach (var c in children) sb.append(c.to_string());
            sb.append("END:").append(name).append("\r\n");
            return sb.str;
        }

        /**
         * Returns the UID of the first VEVENT or VTODO inside a VCALENDAR,
         * or of a VCARD, or an empty string.
         */
        public static string find_uid(string text) {
            var root = parse(text);
            if (root == null) return "";
            if (root.name == "VCARD") return root.get_text("UID");
            foreach (var c in root.children) {
                if (c.name == "VEVENT" || c.name == "VTODO" || c.name == "VJOURNAL") {
                    string uid = c.get_text("UID");
                    if (uid != "") return uid;
                }
            }
            return root.get_text("UID");
        }
    }
}
