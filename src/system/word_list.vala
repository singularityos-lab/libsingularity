namespace Singularity {

    public struct SwipeKey {
        public unichar codepoint;
        public double x;
        public double y;
    }

    public class WordList : Object {
        public const string DATA_DIR = "/usr/share/sinty/words";

        private static Gee.HashMap<string, WordList>? lists = null;
        private SintySystem.Words? words;

        public string language { get; construct; }

        public bool loaded {
            get { return words != null; }
        }

        public static WordList? for_language(string tag) {
            if (lists == null) lists = new Gee.HashMap<string, WordList>();
            string? file = resolve(tag);
            if (file == null) return null;
            if (!lists.has_key(file)) {
                var list = new WordList(file);
                if (!list.loaded) return null;
                lists[file] = list;
            }
            return lists[file];
        }

        public static string[] available_languages() {
            string[] result = {};
            try {
                var dir = Dir.open(DATA_DIR);
                string? name;
                while ((name = dir.read_name()) != null) {
                    if (name.has_suffix(".words")) result += name.substring(0, name.length - 6);
                }
            } catch (FileError e) {
            }
            return result;
        }

        private static string? resolve(string tag) {
            string clean = tag.strip().replace("-", "_");
            int dot = clean.index_of_char('.');
            if (dot >= 0) clean = clean.substring(0, dot);
            int at = clean.index_of_char('@');
            if (at >= 0) clean = clean.substring(0, at);
            if (clean == "" || clean == "C" || clean == "POSIX") return null;
            var parts = clean.split("_");
            string lang = parts[0].down();
            string[] candidates = {};
            if (parts.length > 1) candidates += lang + "_" + parts[1].up();
            candidates += lang;
            foreach (string name in available_languages()) {
                if (name.has_prefix(lang + "_")) candidates += name;
            }
            foreach (string candidate in candidates) {
                string path = Path.build_filename(DATA_DIR, candidate + ".words");
                if (FileUtils.test(path, FileTest.IS_REGULAR)) return path;
            }
            return null;
        }

        private WordList(string path) {
            Object(language: Path.get_basename(path).replace(".words", ""));
            words = SintySystem.Words.open(path);
        }

        public bool contains(string word) {
            return words != null && words.contains(word);
        }

        public string[] complete(string prefix, int max = 3) {
            if (words == null || prefix == "") return {};
            var buf = new void*[max];
            return collect(buf, words.complete(prefix, buf, max));
        }

        public string[] correct(string word, int max = 3) {
            if (words == null || word == "") return {};
            var buf = new void*[max];
            return collect(buf, words.correct(word, buf, max));
        }

        public string[] swipe(SwipeKey[] keys, double[] points, int max = 4) {
            if (words == null || keys.length < 2 || points.length < 4) return {};
            var native_keys = new SintySystem.WordsKey[keys.length];
            for (int i = 0; i < keys.length; i++) {
                native_keys[i].codepoint = (uint32) keys[i].codepoint.tolower();
                native_keys[i].x = (float) keys[i].x;
                native_keys[i].y = (float) keys[i].y;
            }
            var xy = new float[points.length / 2 * 2];
            for (int i = 0; i < xy.length; i++) xy[i] = (float) points[i];
            var buf = new void*[max];
            int n = words.swipe(native_keys, xy, xy.length / 2, buf, max);
            return collect(buf, n);
        }

        private static string[] collect(void*[] buf, int n) {
            string[] result = {};
            for (int i = 0; i < n && i < buf.length; i++) result += ((string) buf[i]).dup();
            return result;
        }
    }
}
