namespace Singularity.Notes {

    public class Note : Object {
        public string id { get; set; default = ""; }
        public string folder { get; set; default = ""; }
        public bool pinned { get; set; default = false; }
        public int64 created { get; set; default = 0; }
        public int64 modified { get; set; default = 0; }
        public string body { get; set; default = ""; }

        internal string? origin = null;

        public Note(string id) {
            Object(id: id);
        }

        public static string new_id() {
            return Uuid.string_random();
        }

        public string title {
            owned get { return title_of(body); }
        }

        public string snippet {
            owned get { return snippet_of(body); }
        }

        public static string strip_markup(string line) {
            string s = line.strip();
            if (s.has_prefix("<!--") && s.has_suffix("-->")) return "";
            while (s.has_prefix("#")) s = s.substring(1);
            s = s.strip();
            if (s.has_prefix("- [ ] ") || s.has_prefix("- [x] ") || s.has_prefix("- [X] ")) s = s.substring(6);
            else if (s.has_prefix("- ") || s.has_prefix("* ")) s = s.substring(2);
            try {
                s = new Regex("!\\[([^\\]]*)\\]\\([^)]*\\)").replace(s, -1, 0, "");
                s = new Regex("\\[([^\\]]*)\\]\\([^)]*\\)").replace(s, -1, 0, "\\1");
                s = new Regex("(\\*\\*|__)(.+?)\\1").replace(s, -1, 0, "\\2");
                s = new Regex("(\\*|_)(.+?)\\1").replace(s, -1, 0, "\\2");
                s = new Regex("\\[![A-Za-z0-9_-]+\\] ?").replace(s, -1, 0, "");
                s = new Regex("</?(u|s|del|mark|span|a|sup|sub)( [^>]*)?>").replace(s, -1, 0, "");
            } catch (RegexError e) {
            }
            return s.strip();
        }

        public static string title_of(string body) {
            foreach (string line in body.split("\n")) {
                string t = strip_markup(line);
                if (t != "") return t;
            }
            return "";
        }

        public static string snippet_of(string body) {
            bool seen_title = false;
            var parts = new StringBuilder();
            foreach (string line in body.split("\n")) {
                string t = strip_markup(line);
                if (t == "") continue;
                if (!seen_title) {
                    seen_title = true;
                    continue;
                }
                if (parts.len > 0) parts.append(" ");
                parts.append(t);
                if (parts.len > 160) break;
            }
            return parts.str;
        }

        public bool matches(string query) {
            string q = query.strip().casefold();
            if (q == "") return true;
            string hay = (strip_body(body) + "\n" + folder).casefold();
            foreach (string term in q.split(" ")) {
                if (term == "") continue;
                if (!hay.contains(term)) return false;
            }
            return true;
        }

        private static string strip_body(string body) {
            var sb = new StringBuilder();
            foreach (string line in body.split("\n")) {
                sb.append(strip_markup(line));
                sb.append("\n");
            }
            return sb.str;
        }

        public Note copy() {
            var n = new Note(id);
            n.folder = folder;
            n.pinned = pinned;
            n.created = created;
            n.modified = modified;
            n.body = body;
            n.origin = origin;
            return n;
        }

        public bool same_version(Note other) {
            return origin == other.origin;
        }

        public static string conflicted_copy_body(string content) {
            string[] lines = content.split("\n", 2);
            string first = lines.length > 0 ? lines[0] : "";
            string head = first.strip() == "" ? _("Conflicted Copy") : first + " " + _("(Conflicted Copy)");
            return lines.length > 1 ? head + "\n" + lines[1] : head;
        }

        public static string format_time(int64 seconds) {
            var dt = new DateTime.from_unix_utc(seconds);
            return dt.format("%Y-%m-%dT%H:%M:%SZ");
        }

        public static int64 parse_time(string text) {
            var dt = new DateTime.from_iso8601(text.strip(), new TimeZone.utc());
            return dt != null ? dt.to_unix() : 0;
        }

        public string serialize() {
            var sb = new StringBuilder();
            sb.append("---\n");
            if (folder != "") sb.append("folder: %s\n".printf(folder.replace("\n", " ")));
            if (pinned) sb.append("pinned: true\n");
            if (created != 0) sb.append("created: %s\n".printf(format_time(created)));
            if (modified != 0) sb.append("modified: %s\n".printf(format_time(modified)));
            sb.append("---\n");
            sb.append(body);
            return sb.str;
        }

        public static Note parse(string id, string text) {
            var note = new Note(id);
            string rest = text;
            if (text.has_prefix("---\n")) {
                int end = text.index_of("\n---\n", 3);
                int end_eof = -1;
                if (end < 0 && text.has_suffix("\n---")) end_eof = text.length - 4;
                if (end >= 0 || end_eof >= 0) {
                    int stop = end >= 0 ? end : end_eof;
                    string header = text.substring(4, int.max(0, stop - 4 + 1));
                    rest = end >= 0 ? text.substring(end + 5) : "";
                    foreach (string line in header.split("\n")) {
                        int colon = line.index_of(":");
                        if (colon <= 0) continue;
                        string key = line.substring(0, colon).strip().down();
                        string val = line.substring(colon + 1).strip();
                        switch (key) {
                            case "folder": note.folder = val; break;
                            case "pinned": note.pinned = val == "true" || val == "yes" || val == "1"; break;
                            case "created": note.created = parse_time(val); break;
                            case "modified": note.modified = parse_time(val); break;
                            default: break;
                        }
                    }
                }
            }
            note.body = rest;
            return note;
        }
    }
}
