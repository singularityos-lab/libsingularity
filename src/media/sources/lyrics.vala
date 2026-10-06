namespace Singularity.MediaSources {

    public class LyricLine : Object {
        public int64 time_ms { get; construct; }
        public string text { get; construct; }

        public LyricLine(int64 time_ms, string text) {
            Object(time_ms: time_ms, text: text);
        }
    }

    public class Lyrics : Object {
        public bool synced { get; set; default = false; }
        public bool instrumental { get; set; default = false; }
        public string plain { get; set; default = ""; }
        public string attribution { get; set; default = ""; }
        public Gee.ArrayList<LyricLine> lines { get; private set; default = new Gee.ArrayList<LyricLine>(); }

        public static Lyrics from_plain(string text) {
            var l = new Lyrics();
            l.plain = text;
            foreach (unowned string line in text.split("\n")) l.lines.add(new LyricLine(-1, line.strip()));
            return l;
        }

        public static Lyrics parse_lrc(string text) {
            var l = new Lyrics();
            int64 offset = 0;
            var plain = new StringBuilder();
            foreach (unowned string raw in text.split("\n")) {
                string line = raw.strip();
                if (line == "") continue;
                int64[] times = {};
                int pos = 0;
                while (pos < line.length && line[pos] == '[') {
                    int close = line.index_of_char(']', pos);
                    if (close < 0) break;
                    string tag = line.substring(pos + 1, close - pos - 1);
                    int64 t;
                    if (parse_time(tag, out t)) {
                        times += t;
                    } else if (tag.has_prefix("offset:")) {
                        int64 o;
                        if (int64.try_parse(tag.substring(7).strip(), out o)) offset = o;
                    }
                    pos = close + 1;
                }
                string body = line.substring(pos).strip();
                foreach (int64 t in times) l.lines.add(new LyricLine(int64.max(0, t - offset), body));
                if (times.length > 0) {
                    if (plain.len > 0) plain.append_c('\n');
                    plain.append(body);
                }
            }
            l.lines.sort((a, b) => a.time_ms < b.time_ms ? -1 : (a.time_ms > b.time_ms ? 1 : 0));
            l.synced = l.lines.size > 0;
            l.plain = plain.str;
            return l;
        }

        private static bool parse_time(string tag, out int64 ms) {
            ms = 0;
            int colon = tag.index_of_char(':');
            if (colon <= 0) return false;
            int64 minutes;
            if (!int64.try_parse(tag.substring(0, colon), out minutes)) return false;
            string rest = tag.substring(colon + 1).replace(",", ".");
            double seconds;
            if (!double.try_parse(rest, out seconds)) return false;
            ms = minutes * 60000 + (int64) Math.round(seconds * 1000);
            return true;
        }

        public int index_at(int64 position_ms) {
            if (!synced) return -1;
            int found = -1;
            for (int i = 0; i < lines.size; i++) {
                if (lines[i].time_ms <= position_ms) found = i;
                else break;
            }
            return found;
        }
    }
}
