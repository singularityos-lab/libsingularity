namespace Singularity.TextRecognition {

    public class TextWord : Object {
        public string text { get; set; default = ""; }
        public double x { get; set; }
        public double y { get; set; }
        public double width { get; set; }
        public double height { get; set; }
        public double confidence { get; set; }
        public int index { get; set; }
        public int line { get; set; }
        public int offset { get; set; }

        public bool contains(double px, double py, double slack = 0) {
            return px >= x - slack && px <= x + width + slack && py >= y - slack && py <= y + height + slack;
        }

        public double distance_to(double px, double py) {
            double dx = px < x ? x - px : (px > x + width ? px - x - width : 0);
            double dy = py < y ? y - py : (py > y + height ? py - y - height : 0);
            return Math.sqrt(dx * dx + dy * dy);
        }
    }

    public class TextLine : Object {
        public Gee.ArrayList<TextWord> words { get; private set; default = new Gee.ArrayList<TextWord>(); }
        public string text { get; set; default = ""; }
        public int block { get; set; }
        public int paragraph { get; set; }
        public double x { get; set; }
        public double y { get; set; }
        public double width { get; set; }
        public double height { get; set; }

        internal void finish() {
            var builder = new StringBuilder();
            double x1 = double.MAX, y1 = double.MAX, x2 = -double.MAX, y2 = -double.MAX;
            foreach (var word in words) {
                if (builder.len > 0) builder.append_c(' ');
                word.offset = (int) builder.len;
                builder.append(word.text);
                x1 = double.min(x1, word.x);
                y1 = double.min(y1, word.y);
                x2 = double.max(x2, word.x + word.width);
                y2 = double.max(y2, word.y + word.height);
            }
            text = builder.str;
            x = x1;
            y = y1;
            width = x2 - x1;
            height = y2 - y1;
        }
    }

    public enum DataKind {
        LINK,
        EMAIL,
        PHONE,
        DATE;

        public string to_label() {
            switch (this) {
                case LINK: return _("Link");
                case EMAIL: return _("Email");
                case DATE: return _("Date");
                default: return _("Phone Number");
            }
        }

        public string icon_name() {
            switch (this) {
                case LINK: return "web-browser-symbolic";
                case EMAIL: return "mail-send-symbolic";
                case DATE: return "x-office-calendar-symbolic";
                default: return "call-start-symbolic";
            }
        }
    }

    public class DetectedData : Object {
        public DataKind kind { get; set; }
        public string text { get; set; default = ""; }
        public string uri { get; set; default = ""; }
        public int first_word { get; set; }
        public int last_word { get; set; }
        public int64 when { get; set; }
        public bool timed { get; set; }
    }

    public class TextRange : Object {
        public int first { get; set; }
        public int last { get; set; }

        public TextRange(int first, int last) {
            Object(first: first, last: last);
        }
    }

    public class RecognizedText : Object {
        public Gee.ArrayList<TextLine> lines { get; private set; default = new Gee.ArrayList<TextLine>(); }
        public Gee.ArrayList<TextWord> words { get; private set; default = new Gee.ArrayList<TextWord>(); }
        public int image_width { get; set; }
        public int image_height { get; set; }
        public string languages { get; set; default = ""; }

        public bool is_empty {
            get { return words.size == 0; }
        }

        public string text {
            owned get { return words.size == 0 ? "" : text_between(0, words.size - 1); }
        }

        public static RecognizedText from_tsv(string tsv, double scale = 1.0, double min_confidence = 0) {
            var result = new RecognizedText();
            TextLine? current = null;
            string current_key = "";
            foreach (var raw in tsv.split("\n")) {
                string row = raw.replace("\r", "");
                if (row == "" || row.has_prefix("level")) continue;
                string[] cols = row.split("\t");
                if (cols.length < 12) continue;
                if (int.parse(cols[0]) == 1) {
                    if (result.image_width == 0) {
                        result.image_width = (int) Math.round(int.parse(cols[8]) / scale);
                        result.image_height = (int) Math.round(int.parse(cols[9]) / scale);
                    }
                    continue;
                }
                if (int.parse(cols[0]) != 5) continue;
                string text = string.joinv("\t", cols[11:cols.length]).strip();
                double confidence = double.parse(cols[10]);
                if (text == "" || confidence < min_confidence) continue;
                string key = "%s.%s.%s.%s".printf(cols[1], cols[2], cols[3], cols[4]);
                if (current == null || key != current_key) {
                    current = new TextLine();
                    current.block = int.parse(cols[2]);
                    current.paragraph = int.parse(cols[3]);
                    current_key = key;
                    result.lines.add(current);
                }
                var word = new TextWord();
                word.text = text;
                word.x = double.parse(cols[6]) / scale;
                word.y = double.parse(cols[7]) / scale;
                word.width = double.parse(cols[8]) / scale;
                word.height = double.parse(cols[9]) / scale;
                word.confidence = confidence;
                word.line = result.lines.size - 1;
                word.index = result.words.size;
                current.words.add(word);
                result.words.add(word);
            }
            foreach (var line in result.lines) line.finish();
            return result;
        }

        public string text_between(int first, int last) {
            if (words.size == 0) return "";
            int a = int.min(first, last).clamp(0, words.size - 1);
            int b = int.max(first, last).clamp(0, words.size - 1);
            var builder = new StringBuilder();
            for (int i = a; i <= b; i++) {
                var word = words[i];
                if (i > a) builder.append_c(words[i - 1].line == word.line ? ' ' : '\n');
                builder.append(word.text);
            }
            return builder.str;
        }

        public int word_at(double x, double y, double slack = 2) {
            foreach (var word in words) {
                if (word.contains(x, y, slack)) return word.index;
            }
            return -1;
        }

        public int nearest_word(double x, double y) {
            int best = -1;
            double best_distance = double.MAX;
            foreach (var line in lines) {
                if (y < line.y - line.height * 0.5 || y > line.y + line.height * 1.5) continue;
                foreach (var word in line.words) {
                    double d = word.distance_to(x, y);
                    if (d < best_distance) {
                        best_distance = d;
                        best = word.index;
                    }
                }
            }
            if (best >= 0) return best;
            foreach (var word in words) {
                double d = word.distance_to(x, y);
                if (d < best_distance) {
                    best_distance = d;
                    best = word.index;
                }
            }
            return best;
        }

        public Gee.List<TextRange> find(string query) {
            var found = new Gee.ArrayList<TextRange>();
            string needle = query.strip().casefold();
            if (needle == "") return found;
            foreach (var line in lines) {
                string hay = line.text.casefold();
                int from = 0;
                while (true) {
                    int at = hay.index_of(needle, from);
                    if (at < 0) break;
                    var range = range_for(line, at, at + needle.length);
                    if (range != null) found.add(range);
                    from = at + int.max(1, needle.length);
                }
            }
            return found;
        }

        private TextRange? range_for(TextLine line, int start, int end) {
            int first = -1, last = -1;
            foreach (var word in line.words) {
                int w_start = word.offset;
                int w_end = word.offset + word.text.length;
                if (w_end > start && w_start < end) {
                    if (first < 0) first = word.index;
                    last = word.index;
                }
            }
            return first < 0 ? null : new TextRange(first, last);
        }

        public Gee.List<DetectedData> detect_data() {
            var found = new Gee.ArrayList<DetectedData>();
            foreach (var line in lines) {
                scan(line, DataKind.EMAIL, EMAIL_PATTERN, found);
                scan(line, DataKind.LINK, LINK_PATTERN, found);
                scan_dates(line, found);
                scan(line, DataKind.PHONE, PHONE_PATTERN, found);
            }
            found.sort((a, b) => a.first_word - b.first_word);
            return found;
        }

        private const string EMAIL_PATTERN = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}";
        private const string LINK_PATTERN = "(?:https?://|www\\.)[^\\s<>\"']+|\\b[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.(?:com|org|net|dev|io|it|de|fr|es|uk|eu|app|gov|edu|info|co)(?:/[^\\s<>\"']*)?\\b";
        private const string PHONE_PATTERN = "(?<![\\w.])\\+?\\(?\\d[\\d\\s().-]{6,}\\d(?![\\w.])";

        private void scan(TextLine line, DataKind kind, string pattern, Gee.List<DetectedData> found) {
            Regex regex;
            try {
                regex = new Regex(pattern, RegexCompileFlags.OPTIMIZE);
            } catch (RegexError e) {
                return;
            }
            MatchInfo info;
            if (!regex.match(line.text, 0, out info)) return;
            do {
                int start, end;
                if (!info.fetch_pos(0, out start, out end)) continue;
                string value = info.fetch(0);
                value = trim_trailing(value);
                end = start + value.length;
                if (overlaps(found, line, start, end)) continue;
                if (kind == DataKind.PHONE && !valid_phone(value)) continue;
                if (kind == DataKind.LINK && value.contains("@")) continue;
                var range = range_for(line, start, end);
                if (range == null) continue;
                var data = new DetectedData();
                data.kind = kind;
                data.text = value;
                data.uri = uri_for(kind, value);
                data.first_word = range.first;
                data.last_word = range.last;
                found.add(data);
            } while (next_match(info));
        }

        private const string MONTHS = "january|february|march|april|may|june|july|august|september|october|november|december|gennaio|febbraio|marzo|aprile|maggio|giugno|luglio|agosto|settembre|ottobre|novembre|dicembre|sept|jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec|gen|mag|giu|lug|ago|set|ott|dic";
        private const string TIME_PATTERN = "^\\s*(?:,|at|alle|ore|@)?\\s*(\\d{1,2})(?:[:.](\\d{2}))?\\s*(?:([ap])\\.?m\\b\\.?)?";

        private void scan_dates(TextLine line, Gee.List<DetectedData> found) {
            string[] patterns = {
                "\\b(\\d{4})-(\\d{1,2})-(\\d{1,2})\\b",
                "\\b(\\d{1,2})[/.](\\d{1,2})[/.](\\d{4}|\\d{2})\\b",
                "\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?(" + MONTHS + ")\\b\\.?(?:,?\\s+(\\d{4})\\b)?",
                "\\b(" + MONTHS + ")\\b\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?\\b(?:,?\\s+(\\d{4})\\b)?"
            };
            for (int kind = 0; kind < patterns.length; kind++) {
                Regex regex;
                try {
                    regex = new Regex(patterns[kind], RegexCompileFlags.CASELESS | RegexCompileFlags.OPTIMIZE);
                } catch (RegexError e) {
                    continue;
                }
                MatchInfo info;
                if (!regex.match(line.text, 0, out info)) continue;
                do {
                    int start, end;
                    if (!info.fetch_pos(0, out start, out end)) continue;
                    int day, month, year;
                    if (!date_parts(kind, info, out day, out month, out year)) continue;
                    int hour = -1, minute = 0;
                    int extra = time_after(line.text.substring(end), out hour, out minute);
                    end += extra;
                    if (overlaps(found, line, start, end)) continue;
                    var range = range_for(line, start, end);
                    if (range == null) continue;
                    var now = new DateTime.now_local();
                    if (year < 0) {
                        year = now.get_year();
                        DateTime? end_of_day = new DateTime.local(year, month, day, 23, 59, 0);
                        if (end_of_day != null && end_of_day.compare(now) < 0) year++;
                    }
                    DateTime? at = new DateTime.local(year, month, day, hour >= 0 ? hour : 0, minute, 0);
                    if (at == null) continue;
                    var data = new DetectedData();
                    data.kind = DataKind.DATE;
                    data.text = line.text.substring(start, end - start).strip();
                    data.when = at.to_unix();
                    data.timed = hour >= 0;
                    data.first_word = range.first;
                    data.last_word = range.last;
                    found.add(data);
                } while (next_match(info));
            }
        }

        private static int month_number(string name) {
            string m = name.down();
            string[] en = { "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
            string[] it = { "gen", "feb", "mar", "apr", "mag", "giu", "lug", "ago", "set", "ott", "nov", "dic" };
            for (int i = 0; i < 12; i++) {
                if (m.has_prefix(en[i]) || m.has_prefix(it[i])) return i + 1;
            }
            return 0;
        }

        private static bool date_parts(int kind, MatchInfo info, out int day, out int month, out int year) {
            day = 0;
            month = 0;
            year = -1;
            string? y = null;
            switch (kind) {
                case 0:
                    year = int.parse(info.fetch(1));
                    month = int.parse(info.fetch(2));
                    day = int.parse(info.fetch(3));
                    break;
                case 1:
                    int a = int.parse(info.fetch(1)), b = int.parse(info.fetch(2));
                    bool month_first = a <= 12 && (b > 12 || (Intl.setlocale(LocaleCategory.TIME, null) ?? "").has_prefix("en_US"));
                    day = month_first ? b : a;
                    month = month_first ? a : b;
                    y = info.fetch(3);
                    break;
                case 2:
                    day = int.parse(info.fetch(1));
                    month = month_number(info.fetch(2));
                    y = info.fetch(3);
                    break;
                default:
                    month = month_number(info.fetch(1));
                    day = int.parse(info.fetch(2));
                    y = info.fetch(3);
                    break;
            }
            if (y != null && y != "") {
                year = int.parse(y);
                if (y.length == 2) year += 2000;
            }
            if (month < 1 || month > 12 || day < 1) return false;
            return Date.valid_dmy((DateDay) day, (DateMonth) month, (DateYear) (year > 0 ? year : 2024));
        }

        private static int time_after(string rest, out int hour, out int minute) {
            hour = -1;
            minute = 0;
            Regex regex;
            try {
                regex = new Regex(TIME_PATTERN, RegexCompileFlags.CASELESS);
            } catch (RegexError e) {
                return 0;
            }
            MatchInfo info;
            if (!regex.match(rest, 0, out info)) return 0;
            string mins = info.fetch(2) ?? "";
            string half = (info.fetch(3) ?? "").down();
            if (mins == "" && half == "") return 0;
            int h = int.parse(info.fetch(1));
            int m = mins == "" ? 0 : int.parse(mins);
            if (half == "p" && h < 12) h += 12;
            if (half == "a" && h == 12) h = 0;
            if (h > 23 || m > 59) return 0;
            hour = h;
            minute = m;
            int s, e;
            info.fetch_pos(0, out s, out e);
            return e;
        }

        private static bool next_match(MatchInfo info) {
            try {
                return info.next();
            } catch (RegexError e) {
                return false;
            }
        }

        private bool overlaps(Gee.List<DetectedData> found, TextLine line, int start, int end) {
            var range = range_for(line, start, end);
            if (range == null) return false;
            foreach (var data in found) {
                if (range.first <= data.last_word && range.last >= data.first_word) return true;
            }
            return false;
        }

        private static string trim_trailing(string value) {
            string v = value;
            while (v.length > 0 && ".,;:!?)]}".index_of_char(v[v.length - 1]) >= 0) {
                v = v.substring(0, v.length - 1);
            }
            return v;
        }

        private static bool valid_phone(string value) {
            int digits = 0;
            for (int i = 0; i < value.length; i++) {
                if (value[i].isdigit()) digits++;
            }
            if (digits < 7 || digits > 15) return false;
            if (!value.has_prefix("+") && !value.contains(" ") && !value.contains("-") && !value.contains("(") && digits > 11) return false;
            return true;
        }

        public static string uri_for(DataKind kind, string value) {
            switch (kind) {
                case DataKind.EMAIL:
                    return "mailto:" + value;
                case DataKind.PHONE:
                    var builder = new StringBuilder("tel:");
                    for (int i = 0; i < value.length; i++) {
                        if (value[i].isdigit() || (i == 0 && value[i] == '+')) builder.append_c(value[i]);
                    }
                    return builder.str;
                default:
                    if (value.has_prefix("http://") || value.has_prefix("https://")) return value;
                    return "https://" + value;
            }
        }
    }
}
