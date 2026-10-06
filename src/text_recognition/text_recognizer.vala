namespace Singularity.TextRecognition {

    public errordomain RecognitionError {
        UNAVAILABLE,
        FAILED
    }

    public abstract class Engine : Object {
        public abstract string name { owned get; }
        public abstract bool available { get; }
        public abstract async string[] list_languages(Cancellable? cancellable = null) throws Error;
        public abstract async string recognize_tsv(string image_path, string[] languages, Cancellable? cancellable = null) throws Error;

        protected static async string run(string[] argv, string[]? env, Cancellable? cancellable) throws Error {
            var launcher = new SubprocessLauncher(SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            if (env != null) {
                foreach (var pair in env) {
                    int eq = pair.index_of_char('=');
                    if (eq > 0) launcher.setenv(pair.substring(0, eq), pair.substring(eq + 1), true);
                }
            }
            var proc = launcher.spawnv(argv);
            string? stdout_text = null;
            string? stderr_text = null;
            yield proc.communicate_utf8_async(null, cancellable, out stdout_text, out stderr_text);
            if (!proc.get_if_exited() || proc.get_exit_status() != 0) {
                string detail = (stderr_text ?? "").strip();
                throw new RecognitionError.FAILED("%s: %s", argv[0], detail != "" ? detail : _("exited with an error"));
            }
            return stdout_text ?? "";
        }
    }

    public class TesseractEngine : Engine {
        public string program { get; construct; }
        public string? data_dir { get; construct; }
        private string? resolved = null;

        public TesseractEngine(string program = "tesseract", string? data_dir = null) {
            Object(program: program, data_dir: data_dir);
        }

        construct {
            resolved = Path.is_absolute(program)
                ? (FileUtils.test(program, FileTest.IS_EXECUTABLE) ? program : null)
                : Environment.find_program_in_path(program);
        }

        public override string name { owned get { return "Tesseract"; } }

        public override bool available { get { return resolved != null; } }

        private string[]? env() {
            if (data_dir == null || data_dir == "") return null;
            return { "TESSDATA_PREFIX=" + data_dir };
        }

        public override async string[] list_languages(Cancellable? cancellable = null) throws Error {
            if (resolved == null) throw new RecognitionError.UNAVAILABLE(_("Tesseract is not installed"));
            string[] argv = { resolved, "--list-langs" };
            if (data_dir != null && data_dir != "") argv = { resolved, "--tessdata-dir", data_dir, "--list-langs" };
            string output = yield run(argv, env(), cancellable);
            string[] langs = {};
            foreach (var line in output.split("\n")) {
                string l = line.strip();
                if (l == "" || l.has_prefix("List of") || l == "osd" || l == "equ" || l.contains(" ")) continue;
                langs += l;
            }
            return langs;
        }

        public override async string recognize_tsv(string image_path, string[] languages, Cancellable? cancellable = null) throws Error {
            if (resolved == null) throw new RecognitionError.UNAVAILABLE(_("Tesseract is not installed"));
            string[] argv = { resolved, image_path, "stdout" };
            if (data_dir != null && data_dir != "") {
                argv += "--tessdata-dir";
                argv += data_dir;
            }
            if (languages.length > 0) {
                argv += "-l";
                argv += string.joinv("+", languages);
            }
            argv += "--psm";
            argv += "3";
            argv += "tsv";
            return yield run(argv, env(), cancellable);
        }
    }

    public class CommandEngine : Engine {
        public string command { get; construct; }
        public string languages_command { get; construct; }

        public CommandEngine(string command, string languages_command = "") {
            Object(command: command, languages_command: languages_command);
        }

        public override string name { owned get { return _("Text Recognition Service"); } }

        public override bool available {
            get {
                string[] argv;
                try {
                    if (!GLib.Shell.parse_argv(command, out argv) || argv.length == 0) return false;
                } catch (ShellError e) {
                    return false;
                }
                return Path.is_absolute(argv[0]) ? FileUtils.test(argv[0], FileTest.IS_EXECUTABLE) : Environment.find_program_in_path(argv[0]) != null;
            }
        }

        private string[] expand(string line, string image_path, string[] languages) throws Error {
            string[] parsed;
            GLib.Shell.parse_argv(line, out parsed);
            string[] argv = {};
            foreach (var arg in parsed) {
                argv += arg.replace("%f", image_path).replace("%l", string.joinv("+", languages));
            }
            return argv;
        }

        public override async string[] list_languages(Cancellable? cancellable = null) throws Error {
            if (languages_command == "") return {};
            string output = yield run(expand(languages_command, "", {}), null, cancellable);
            string[] langs = {};
            foreach (var line in output.split("\n")) {
                if (line.strip() != "") langs += line.strip();
            }
            return langs;
        }

        public override async string recognize_tsv(string image_path, string[] languages, Cancellable? cancellable = null) throws Error {
            return yield run(expand(command, image_path, languages), null, cancellable);
        }
    }

    public class Config : Object {
        public string engine { get; set; default = "auto"; }
        public string tesseract { get; set; default = "tesseract"; }
        public string data_dir { get; set; default = ""; }
        public string command { get; set; default = ""; }
        public string languages_command { get; set; default = ""; }
        public string install_hint { get; set; default = ""; }

        public const string GROUP = "Text Recognition";
        public const string FILE_NAME = "text-recognition.conf";

        public static Config load() {
            var config = new Config();
            string[] dirs = Environment.get_system_config_dirs();
            for (int i = dirs.length - 1; i >= 0; i--) {
                config.merge(Path.build_filename(dirs[i], "singularity", FILE_NAME));
            }
            config.merge(Path.build_filename(Environment.get_user_config_dir(), "singularity", FILE_NAME));
            return config;
        }

        public void merge(string path) {
            var file = new KeyFile();
            try {
                file.load_from_file(path, KeyFileFlags.NONE);
            } catch (Error e) {
                return;
            }
            engine = read(file, "Engine", engine);
            tesseract = read(file, "Tesseract", tesseract);
            data_dir = read(file, "DataDir", data_dir);
            command = read(file, "Command", command);
            languages_command = read(file, "LanguagesCommand", languages_command);
            try {
                install_hint = file.get_locale_string(GROUP, "InstallHint", null);
            } catch (Error e) {
            }
        }

        private static string read(KeyFile file, string key, string fallback) {
            try {
                return file.get_string(GROUP, key).strip();
            } catch (Error e) {
                return fallback;
            }
        }

        public Engine? create_engine() {
            switch (engine) {
                case "none":
                    return null;
                case "command":
                    return command != "" ? new CommandEngine(command, languages_command) : null;
                case "tesseract":
                    return new TesseractEngine(tesseract, data_dir != "" ? data_dir : null);
                default:
                    if (command != "") {
                        var custom = new CommandEngine(command, languages_command);
                        if (custom.available) return custom;
                    }
                    return new TesseractEngine(tesseract, data_dir != "" ? data_dir : null);
            }
        }
    }

    public class Recognizer : Object {
        private static Recognizer? instance = null;
        private string[]? cached_languages = null;
        private GLib.Settings? settings = null;

        public Engine? engine { get; private set; }
        public Config config { get; construct; }

        public const string LANGUAGES_KEY = "text-recognition-languages";

        public signal void languages_changed();

        public static Recognizer get_default() {
            if (instance == null) instance = new Recognizer(Config.load());
            return instance;
        }

        public Recognizer(Config config) {
            Object(config: config);
            engine = config.create_engine();
            string schema_id = Singularity.Runtime.desktop_settings_schema;
            var source = SettingsSchemaSource.get_default();
            var schema = source != null ? source.lookup(schema_id, true) : null;
            if (schema != null && schema.has_key(LANGUAGES_KEY)) {
                settings = new GLib.Settings(schema_id);
                settings.changed[LANGUAGES_KEY].connect(() => languages_changed());
            }
        }

        public Recognizer.with_engine(Engine? engine) {
            Object(config: new Config());
            this.engine = engine;
        }

        public bool available {
            get { return engine != null && engine.available; }
        }

        public string install_hint {
            owned get {
                if (config.install_hint != "") return config.install_hint;
                return _("Install a text recognition engine such as Tesseract with your software manager, then open the image again.");
            }
        }

        public async string[] installed_languages(Cancellable? cancellable = null) {
            if (cached_languages != null) return cached_languages;
            if (!available) return {};
            try {
                cached_languages = yield engine.list_languages(cancellable);
            } catch (Error e) {
                warning("Text recognition: %s", e.message);
                cached_languages = {};
            }
            return cached_languages;
        }

        public string[] chosen_languages() {
            return settings != null ? settings.get_strv(LANGUAGES_KEY) : new string[0];
        }

        public void set_chosen_languages(string[] languages) {
            if (settings != null) settings.set_strv(LANGUAGES_KEY, languages);
        }

        public bool can_choose_languages {
            get { return settings != null; }
        }

        public async string[] active_languages(Cancellable? cancellable = null) {
            string[] installed = yield installed_languages(cancellable);
            string[] chosen = {};
            foreach (var lang in chosen_languages()) {
                if (lang in installed || installed.length == 0) chosen += lang;
            }
            if (chosen.length > 0) return chosen;
            return Languages.automatic(installed);
        }

        public async RecognizedText recognize_texture(Gdk.Texture texture, Cancellable? cancellable = null) throws Error {
            if (!available) throw new RecognitionError.UNAVAILABLE(install_hint);
            string[] langs = yield active_languages(cancellable);
            int w = texture.get_width();
            int h = texture.get_height();
            double scale = int.max(w, h) < 2400 ? 2.0 : 1.0;
            string path;
            int fd = FileUtils.open_tmp("singularity-ocr-XXXXXX.png", out path);
            FileUtils.close(fd);
            try {
                yield write_scaled(texture, path, scale);
                string tsv = yield engine.recognize_tsv(path, langs, cancellable);
                var result = RecognizedText.from_tsv(tsv, scale, 20);
                result.image_width = w;
                result.image_height = h;
                result.languages = string.joinv("+", langs);
                return result;
            } finally {
                FileUtils.unlink(path);
            }
        }

        public async RecognizedText recognize_file(File file, Cancellable? cancellable = null) throws Error {
            var texture = Gdk.Texture.from_file(file);
            return yield recognize_texture(texture, cancellable);
        }

        private static async void write_scaled(Gdk.Texture texture, string path, double scale) throws Error {
            if (scale == 1.0) {
                if (!texture.save_to_png(path)) throw new RecognitionError.FAILED(_("Could not prepare the image"));
                return;
            }
            var bytes = texture.save_to_png_bytes();
            var stream = new MemoryInputStream.from_bytes(bytes);
            var pixbuf = yield new Gdk.Pixbuf.from_stream_async(stream, null);
            var scaled = pixbuf.scale_simple((int) (pixbuf.width * scale), (int) (pixbuf.height * scale), Gdk.InterpType.BILINEAR);
            scaled.savev(path, "png", {}, {});
        }
    }

    namespace Languages {
        private const string[] TABLE = {
            "en", "eng", N_("English"), "it", "ita", N_("Italian"), "de", "deu", N_("German"),
            "fr", "fra", N_("French"), "es", "spa", N_("Spanish"), "pt", "por", N_("Portuguese"),
            "nl", "nld", N_("Dutch"), "sv", "swe", N_("Swedish"), "da", "dan", N_("Danish"),
            "fi", "fin", N_("Finnish"), "nb", "nor", N_("Norwegian"), "no", "nor", N_("Norwegian"),
            "pl", "pol", N_("Polish"), "cs", "ces", N_("Czech"), "sk", "slk", N_("Slovak"),
            "sl", "slv", N_("Slovenian"), "hu", "hun", N_("Hungarian"), "ro", "ron", N_("Romanian"),
            "bg", "bul", N_("Bulgarian"), "ru", "rus", N_("Russian"), "uk", "ukr", N_("Ukrainian"),
            "el", "ell", N_("Greek"), "tr", "tur", N_("Turkish"), "ar", "ara", N_("Arabic"),
            "he", "heb", N_("Hebrew"), "fa", "fas", N_("Persian"), "hi", "hin", N_("Hindi"),
            "ja", "jpn", N_("Japanese"), "zh", "chi_sim", N_("Chinese, Simplified"), "zh_TW", "chi_tra", N_("Chinese, Traditional"),
            "ko", "kor", N_("Korean"), "vi", "vie", N_("Vietnamese"), "th", "tha", N_("Thai"),
            "id", "ind", N_("Indonesian"), "ca", "cat", N_("Catalan"), "hr", "hrv", N_("Croatian"),
            "sr", "srp", N_("Serbian"), "lt", "lit", N_("Lithuanian"), "lv", "lav", N_("Latvian"),
            "et", "est", N_("Estonian"), "ga", "gle", N_("Irish"), "cy", "cym", N_("Welsh"),
            "eu", "eus", N_("Basque"), "gl", "glg", N_("Galician"), "la", "lat", N_("Latin")
        };

        public string display_name(string code) {
            for (int i = 0; i + 2 < TABLE.length; i += 3) {
                if (TABLE[i + 1] == code) return _(TABLE[i + 2]);
            }
            return code;
        }

        public string? code_for_locale(string locale) {
            string l = locale.split(".")[0].split("@")[0];
            for (int i = 0; i + 2 < TABLE.length; i += 3) {
                if (TABLE[i] == l) return TABLE[i + 1];
            }
            string lang = l.split("_")[0];
            for (int i = 0; i + 2 < TABLE.length; i += 3) {
                if (TABLE[i] == lang) return TABLE[i + 1];
            }
            return null;
        }

        public string[] automatic(string[] installed) {
            string[] result = {};
            foreach (var name in Intl.get_language_names()) {
                string? code = code_for_locale(name);
                if (code == null || code in result) continue;
                if (installed.length > 0 && !(code in installed)) continue;
                result += code;
            }
            if (!("eng" in result) && (installed.length == 0 || "eng" in installed)) result += "eng";
            if (result.length == 0 && installed.length > 0) result += installed[0];
            return result;
        }
    }
}
