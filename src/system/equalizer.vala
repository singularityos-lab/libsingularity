using GLib;

namespace Singularity {

    [CCode (cname = "SINGULARITY_SYSCONFDIR")]
    extern const string EQUALIZER_SYSCONFDIR;

    public errordomain EqualizerError {
        NOT_AVAILABLE,
        FAILED
    }

    public class EqualizerPreset : Object {
        public string id { get; construct; }
        public string name { get; construct; }
        public double[] gains;

        public EqualizerPreset(string id, string name, double[] gains) {
            Object(id: id, name: name);
            this.gains = gains;
        }
    }

    namespace EqualizerBands {
        public const int COUNT = 10;
        public const double MIN_GAIN = -12.0;
        public const double MAX_GAIN = 12.0;
        public const double PEAK_Q = 1.41;
        public const double SHELF_Q = 0.71;
        public const string NODE_PREFIX = "singularity-eq-";

        public int frequency(int band) {
            int[] freqs = { 31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 };
            return freqs[band.clamp(0, COUNT - 1)];
        }

        public string label(int band) {
            int f = frequency(band);
            if (f >= 1000) return "%dk".printf(f / 1000);
            return f.to_string();
        }

        public string filter_label(int band) {
            if (band == 0) return "bq_lowshelf";
            if (band == COUNT - 1) return "bq_highshelf";
            return "bq_peaking";
        }

        public double q(int band) {
            return (band == 0 || band == COUNT - 1) ? SHELF_Q : PEAK_Q;
        }

        public double clamp_gain(double gain) {
            if (gain.is_nan()) return 0.0;
            return Math.round(gain.clamp(MIN_GAIN, MAX_GAIN) * 10.0) / 10.0;
        }

        public double[] normalize(double[]? gains) {
            var result = new double[COUNT];
            for (int i = 0; i < COUNT; i++) {
                result[i] = (gains != null && i < gains.length) ? clamp_gain(gains[i]) : 0.0;
            }
            return result;
        }

        public double preamp(double[] gains) {
            double peak = 0.0;
            foreach (double g in normalize(gains)) peak = double.max(peak, g);
            return peak > 0.0 ? -peak : 0.0;
        }

        public bool is_flat(double[] gains) {
            foreach (double g in normalize(gains)) {
                if (g != 0.0) return false;
            }
            return true;
        }

        public EqualizerPreset[] presets() {
            return {
                new EqualizerPreset("flat", _("Flat"), { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
                new EqualizerPreset("bass", _("Bass Boost"), { 6, 5, 4, 2, 0, 0, 0, 0, 0, 0 }),
                new EqualizerPreset("treble", _("Treble Boost"), { 0, 0, 0, 0, 0, 1, 2, 4, 5, 6 }),
                new EqualizerPreset("vocal", _("Vocal"), { -2, -2, -1, 1, 3, 4, 3, 1, 0, -1 }),
                new EqualizerPreset("loudness", _("Loudness"), { 5, 4, 2, 0, -1, 0, 0, 2, 4, 5 })
            };
        }

        public EqualizerPreset? find_preset(string id) {
            foreach (var p in presets()) {
                if (p.id == id) return p;
            }
            return null;
        }

        public string match_preset(double[] gains) {
            var norm = normalize(gains);
            foreach (var p in presets()) {
                bool same = true;
                for (int i = 0; i < COUNT; i++) {
                    if (Math.fabs(p.gains[i] - norm[i]) > 0.05) {
                        same = false;
                        break;
                    }
                }
                if (same) return p.id;
            }
            return "custom";
        }

        public string node_name(string device) {
            string sum = Checksum.compute_for_string(ChecksumType.SHA256, device);
            return NODE_PREFIX + sum.substring(0, 12);
        }

        public string number(double value, string format = "%.1f") {
            char[] buf = new char[double.DTOSTR_BUF_SIZE];
            string result = value.format(buf, format).dup();
            return result;
        }

        public string format_gain(double gain) {
            double g = clamp_gain(gain);
            if (g == 0.0) return _("0 dB");
            return _("%s dB").printf((g > 0 ? "+" : "") + number(g));
        }

        public string quote(string text) {
            var sb = new StringBuilder("\"");
            unichar c;
            int i = 0;
            while (text.get_next_char(ref i, out c)) {
                if (c == '"' || c == '\\') sb.append_c('\\');
                if (c == '\n' || c == '\r') continue;
                sb.append_unichar(c);
            }
            sb.append_c('"');
            return sb.str;
        }

        public string control_params(double[] gains) {
            var norm = normalize(gains);
            var sb = new StringBuilder("{ params = [ ");
            sb.append_printf("\"eq_preamp:Gain\" %s ", number(preamp(norm)));
            for (int i = 0; i < COUNT; i++) {
                sb.append_printf("\"eq_band_%d:Gain\" %s ", i + 1, number(norm[i]));
            }
            sb.append("] }");
            return sb.str;
        }

        public string filter_chain_conf(string node, string description, string target, double[] gains) {
            var norm = normalize(gains);
            var sb = new StringBuilder();
            sb.append("context.properties = {\n    log.level = 0\n}\n");
            sb.append("context.spa-libs = {\n    audio.convert.* = audioconvert/libspa-audioconvert\n    support.* = support/libspa-support\n}\n");
            sb.append("context.modules = [\n");
            sb.append("    { name = libpipewire-module-rt flags = [ ifexists nofail ] }\n");
            sb.append("    { name = libpipewire-module-protocol-native }\n");
            sb.append("    { name = libpipewire-module-client-node }\n");
            sb.append("    { name = libpipewire-module-adapter }\n");
            sb.append("    { name = libpipewire-module-filter-chain\n        args = {\n");
            sb.append_printf("            node.description = %s\n", quote(description));
            sb.append_printf("            media.name = %s\n", quote(description));
            sb.append("            filter.graph = {\n                nodes = [\n");
            sb.append_printf("                    { type = builtin name = eq_preamp label = bq_highshelf control = { \"Freq\" = 0.0 \"Q\" = 1.0 \"Gain\" = %s } }\n",
                number(preamp(norm)));
            for (int i = 0; i < COUNT; i++) {
                sb.append_printf("                    { type = builtin name = eq_band_%d label = %s control = { \"Freq\" = %d.0 \"Q\" = %s \"Gain\" = %s } }\n",
                    i + 1, filter_label(i), frequency(i), number(q(i), "%.2f"), number(norm[i]));
            }
            sb.append("                ]\n                links = [\n");
            sb.append("                    { output = \"eq_preamp:Out\" input = \"eq_band_1:In\" }\n");
            for (int i = 1; i < COUNT; i++) {
                sb.append_printf("                    { output = \"eq_band_%d:Out\" input = \"eq_band_%d:In\" }\n", i, i + 1);
            }
            sb.append("                ]\n            }\n");
            sb.append("            audio.channels = 2\n            audio.position = [ FL FR ]\n");
            sb.append_printf("            capture.props = {\n                node.name = %s\n                media.class = Audio/Sink\n            }\n",
                quote(node));
            sb.append_printf("            playback.props = {\n                node.name = %s\n                node.passive = true\n                target.object = %s\n                node.target = %s\n                node.dont-reconnect = true\n            }\n",
                quote(node + ".output"), quote(target), quote(target));
            sb.append("        }\n    }\n]\n");
            return sb.str;
        }
    }

    public class EqualizerProfile : Object {
        public string device { get; set; default = ""; }
        public bool enabled { get; set; default = false; }
        public string preset { get; set; default = "flat"; }
        public double[] gains = new double[EqualizerBands.COUNT];

        public EqualizerProfile(string device) {
            Object(device: device);
        }

        public EqualizerProfile copy() {
            var p = new EqualizerProfile(device);
            p.enabled = enabled;
            p.preset = preset;
            p.gains = EqualizerBands.normalize(gains);
            return p;
        }
    }

    public class EqualizerStore : Object {
        private KeyFile keyfile = new KeyFile();
        public string path { get; construct; }

        public EqualizerStore(string? path = null) {
            Object(path: path ?? Path.build_filename(Environment.get_user_config_dir(), "singularity", "equalizer.ini"));
            if (FileUtils.test(this.path, FileTest.IS_REGULAR)) {
                try {
                    keyfile.load_from_file(this.path, KeyFileFlags.NONE);
                } catch (Error e) {
                    warning("Equalizer: cannot read %s: %s", this.path, e.message);
                    keyfile = new KeyFile();
                }
            }
        }

        public EqualizerProfile get_profile(string device) {
            var p = new EqualizerProfile(device);
            if (!keyfile.has_group(device)) return p;
            try {
                if (keyfile.has_key(device, "Enabled")) p.enabled = keyfile.get_boolean(device, "Enabled");
                if (keyfile.has_key(device, "Preset")) p.preset = keyfile.get_string(device, "Preset");
                if (keyfile.has_key(device, "Gains")) {
                    string[] parts = keyfile.get_string(device, "Gains").split(";");
                    var values = new double[EqualizerBands.COUNT];
                    for (int i = 0; i < EqualizerBands.COUNT && i < parts.length; i++) {
                        values[i] = double.parse(parts[i].strip());
                    }
                    p.gains = EqualizerBands.normalize(values);
                }
            } catch (Error e) {
                warning("Equalizer: bad entry for %s: %s", device, e.message);
            }
            return p;
        }

        public void put_profile(EqualizerProfile profile) {
            string device = profile.device;
            keyfile.set_boolean(device, "Enabled", profile.enabled);
            keyfile.set_string(device, "Preset", profile.preset);
            string[] parts = {};
            foreach (double g in EqualizerBands.normalize(profile.gains)) parts += EqualizerBands.number(g);
            keyfile.set_string(device, "Gains", string.joinv(";", parts));
        }

        public void save() throws Error {
            DirUtils.create_with_parents(Path.get_dirname(path), 0700);
            keyfile.save_to_file(path);
        }
    }

    public class EqualizerConfig : Object {
        public const string FILE_NAME = "singularity/equalizer.conf";
        private KeyFile keyfile = new KeyFile();

        public EqualizerConfig() {
            string[] dirs = {};
            foreach (unowned string dir in Environment.get_system_config_dirs()) dirs += dir;
            dirs += EQUALIZER_SYSCONFDIR;
            foreach (string dir in dirs) {
                string path = Path.build_filename(dir, FILE_NAME);
                if (!FileUtils.test(path, FileTest.IS_REGULAR)) continue;
                try {
                    keyfile.load_from_file(path, KeyFileFlags.NONE);
                    return;
                } catch (Error e) {
                    warning("EqualizerConfig: cannot read %s: %s", path, e.message);
                    keyfile = new KeyFile();
                }
            }
        }

        public string get_string(string key, string fallback) {
            try {
                if (keyfile.has_key("Equalizer", key)) return keyfile.get_string("Equalizer", key).strip();
            } catch (Error e) {
            }
            return fallback;
        }
    }

    public interface EqualizerBackend : Object {
        public abstract string name { get; }
        public abstract async bool probe();
        public abstract async void apply(string device, string description, double[] gains) throws Error;
        public abstract async void update(string device, double[] gains) throws Error;
        public abstract async void remove(string device);
        public abstract string? sink_for(string device);
        public abstract bool owns_sink(string sink_name);
    }

    internal async bool equalizer_run(string[] argv, int timeout_ms, out string output) {
        output = "";
        try {
            var proc = new Subprocess.newv(argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
            var cancel = new Cancellable();
            bool fired = false;
            uint timer = Timeout.add(timeout_ms, () => {
                fired = true;
                proc.force_exit();
                cancel.cancel();
                return Source.REMOVE;
            });
            string? out_text = null;
            yield proc.communicate_utf8_async(null, cancel, out out_text, null);
            if (!fired) Source.remove(timer);
            output = out_text ?? "";
            return proc.get_if_exited() && proc.get_exit_status() == 0;
        } catch (Error e) {
            debug("Equalizer: %s failed: %s", argv[0], e.message);
            return false;
        }
    }

    public class PipeWireEqualizerBackend : Object, EqualizerBackend {
        private HashTable<string, Subprocess> chains = new HashTable<string, Subprocess>(str_hash, str_equal);
        private HashTable<string, string> descriptions = new HashTable<string, string>(str_hash, str_equal);

        public string name { get { return "pipewire"; } }

        private string state_dir() {
            return Path.build_filename(Environment.get_user_runtime_dir(), "singularity", "equalizer");
        }

        public async bool probe() {
            if (Environment.find_program_in_path("pipewire") == null) return false;
            if (Environment.find_program_in_path("pw-cli") == null) return false;
            string output;
            bool ok = yield equalizer_run({ "pw-cli", "info", "0" }, 3000, out output);
            return ok && output.contains("id: 0");
        }

        public string? sink_for(string device) {
            return EqualizerBands.node_name(device);
        }

        public bool owns_sink(string sink_name) {
            return sink_name.has_prefix(EqualizerBands.NODE_PREFIX);
        }

        private void stop_stale(string node) {
            string pid_path = Path.build_filename(state_dir(), node + ".pid");
            string conf_path = Path.build_filename(state_dir(), node + ".conf");
            string text;
            try {
                if (!FileUtils.get_contents(pid_path, out text)) return;
            } catch (Error e) {
                return;
            }
            int pid = int.parse(text.strip());
            if (pid <= 1) return;
            string cmdline;
            try {
                size_t len;
                FileUtils.get_contents("/proc/%d/cmdline".printf(pid), out cmdline, out len);
                for (size_t i = 0; i < len; i++) {
                    if (cmdline.data[i] == 0) cmdline.data[i] = ' ';
                }
            } catch (Error e) {
                return;
            }
            if (cmdline.contains(conf_path)) Posix.kill((Posix.pid_t) pid, Posix.Signal.TERM);
        }

        public async void apply(string device, string description, double[] gains) throws Error {
            string node = EqualizerBands.node_name(device);
            if (chains.contains(device)) {
                yield update(device, gains);
                return;
            }
            DirUtils.create_with_parents(state_dir(), 0700);
            stop_stale(node);
            string conf_path = Path.build_filename(state_dir(), node + ".conf");
            descriptions.insert(device, description);
            FileUtils.set_contents(conf_path, EqualizerBands.filter_chain_conf(node, description, device, gains));
            var proc = new Subprocess.newv({ "pipewire", "-c", conf_path },
                SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
            chains.insert(device, proc);
            string? id = proc.get_identifier();
            if (id != null) FileUtils.set_contents(Path.build_filename(state_dir(), node + ".pid"), id);
            proc.wait_async.begin(null, (o, r) => {
                try {
                    proc.wait_async.end(r);
                } catch (Error e) {
                }
                if (chains.lookup(device) == proc) chains.remove(device);
            });
        }

        public async void update(string device, double[] gains) throws Error {
            double[] values = EqualizerBands.normalize(gains);
            string params = EqualizerBands.control_params(values);
            string node = EqualizerBands.node_name(device);
            string conf_path = Path.build_filename(state_dir(), node + ".conf");
            if (FileUtils.test(conf_path, FileTest.IS_REGULAR)) {
                string desc = descriptions.lookup(device) ?? device;
                FileUtils.set_contents(conf_path, EqualizerBands.filter_chain_conf(node, desc, device, values));
            }
            string id = yield find_node_id(node);
            if (id == "") throw new EqualizerError.FAILED("equalizer node %s not found", node);
            string output;
            bool ok = yield equalizer_run({ "pw-cli", "set-param", id, "Props", params }, 3000, out output);
            if (!ok) throw new EqualizerError.FAILED("pw-cli set-param failed");
        }

        public static string parse_node_id(string listing, string node) {
            string current = "";
            foreach (string raw in listing.split("\n")) {
                string line = raw.strip();
                if (line.has_prefix("id ")) {
                    string rest = line.substring(3);
                    int comma = rest.index_of(",");
                    current = comma > 0 ? rest.substring(0, comma).strip() : rest.strip();
                } else if (line.has_prefix("node.name = ")) {
                    string value = line.substring(12).strip();
                    if (value.has_prefix("\"") && value.has_suffix("\"") && value.length >= 2) {
                        value = value.substring(1, value.length - 2);
                    }
                    if (value == node && current != "") return current;
                }
            }
            return "";
        }

        private async string find_node_id(string node) {
            string output;
            if (!(yield equalizer_run({ "pw-cli", "ls", "Node" }, 3000, out output))) return "";
            return parse_node_id(output, node);
        }

        public async void remove(string device) {
            string node = EqualizerBands.node_name(device);
            var proc = chains.lookup(device);
            if (proc != null) {
                chains.remove(device);
                proc.send_signal(Posix.Signal.TERM);
            }
            stop_stale(node);
            FileUtils.unlink(Path.build_filename(state_dir(), node + ".pid"));
            FileUtils.unlink(Path.build_filename(state_dir(), node + ".conf"));
        }

        public void remove_all() {
            foreach (var proc in chains.get_values()) proc.send_signal(Posix.Signal.TERM);
            chains.remove_all();
        }
    }

    public class CommandEqualizerBackend : Object, EqualizerBackend {
        public string command { get; construct; }

        public CommandEqualizerBackend(string command) {
            Object(command: command);
        }

        public string name { get { return "command"; } }

        private string[] argv(string verb, string device, double[]? gains) {
            string[] args = {};
            try {
                Shell.parse_argv(command, out args);
            } catch (Error e) {
                args = { command };
            }
            args += verb;
            if (device != "") args += device;
            if (gains != null) {
                args += EqualizerBands.number(EqualizerBands.preamp(gains));
                foreach (double g in EqualizerBands.normalize(gains)) args += EqualizerBands.number(g);
            }
            return args;
        }

        public async bool probe() {
            string output;
            return yield equalizer_run(argv("probe", "", null), 3000, out output);
        }

        public async void apply(string device, string description, double[] gains) throws Error {
            string output;
            if (!(yield equalizer_run(argv("apply", device, gains), 5000, out output))) {
                throw new EqualizerError.FAILED("%s apply failed", command);
            }
        }

        public async void update(string device, double[] gains) throws Error {
            yield apply(device, device, gains);
        }

        public async void remove(string device) {
            string output;
            yield equalizer_run(argv("remove", device, null), 5000, out output);
        }

        public string? sink_for(string device) {
            return null;
        }

        public bool owns_sink(string sink_name) {
            return false;
        }
    }

    public class EqualizerManager : Object {
        private static EqualizerManager? _instance = null;
        private EqualizerBackend? backend = null;
        private EqualizerStore store;
        private AudioManager audio;
        private string running_device = "";
        private string pending_route = "";
        private bool busy = false;
        private bool dirty = false;

        public bool ready { get; private set; default = false; }
        public bool available { get; private set; default = false; }
        public string backend_name { get; private set; default = "none"; }
        public string output_device { get; private set; default = ""; }
        public string output_description { get; private set; default = ""; }
        public signal void changed();

        public static EqualizerManager get_default() {
            if (_instance == null) _instance = new EqualizerManager();
            return _instance;
        }

        public EqualizerManager() {
            store = new EqualizerStore();
            audio = AudioManager.get_default();
            audio.devices_changed.connect(() => on_audio_changed());
            audio.state_changed.connect(() => on_audio_changed());
            init.begin();
        }

        public static EqualizerBackend? backend_for(string choice, string command) {
            switch (choice) {
                case "none": return null;
                case "command": return command != "" ? new CommandEqualizerBackend(command) : null;
                default: return new PipeWireEqualizerBackend();
            }
        }

        private async void init() {
            var config = new EqualizerConfig();
            string choice = config.get_string("Backend", "auto");
            backend = backend_for(choice, config.get_string("Command", ""));
            if (backend != null && (yield backend.probe())) {
                available = true;
                backend_name = backend.name;
            } else {
                backend = null;
            }
            ready = true;
            on_audio_changed();
            changed();
        }

        public bool is_virtual(string sink_name) {
            return backend != null && backend.owns_sink(sink_name);
        }

        private string default_sink_name(out string description) {
            description = "";
            foreach (var s in audio.sinks) {
                if (s.index == audio.default_sink_index) {
                    description = s.description;
                    return s.name;
                }
            }
            return "";
        }

        private string describe(string device) {
            foreach (var s in audio.sinks) {
                if (s.name == device) return s.description;
            }
            return device;
        }

        public string routed_default() {
            string desc;
            string name = default_sink_name(out desc);
            if (name != "" && is_virtual(name) && running_device != "") return running_device;
            return name;
        }

        private void on_audio_changed() {
            string desc;
            string current = default_sink_name(out desc);
            if (current == "") return;
            if (pending_route != "" && sink_exists(pending_route)) {
                string route = pending_route;
                pending_route = "";
                if (current != route) audio.set_default_sink(route);
                return;
            }
            string real = current;
            if (is_virtual(current)) real = running_device != "" ? running_device : owner_of(current);
            if (real == "") return;
            if (real != output_device) {
                output_device = real;
                output_description = describe(real);
                changed();
            } else if (output_description != describe(real)) {
                output_description = describe(real);
                changed();
            }
            sync.begin();
        }

        private string owner_of(string virtual_sink) {
            foreach (var s in audio.sinks) {
                if (!is_virtual(s.name) && backend.sink_for(s.name) == virtual_sink) return s.name;
            }
            return "";
        }

        private bool sink_exists(string name) {
            foreach (var s in audio.sinks) {
                if (s.name == name) return true;
            }
            return false;
        }

        public EqualizerProfile profile_for(string device) {
            return store.get_profile(device);
        }

        public bool is_active() {
            return running_device != "";
        }

        public bool is_equalizing(string sink_name) {
            return running_device != "" && running_device == sink_name;
        }

        public void save_profile(EqualizerProfile profile) {
            store.put_profile(profile);
            try {
                store.save();
            } catch (Error e) {
                warning("Equalizer: cannot save: %s", e.message);
            }
            if (profile.device == running_device && profile.enabled && backend != null) {
                var gains = EqualizerBands.normalize(profile.gains);
                backend.update.begin(profile.device, gains, (o, r) => {
                    try {
                        backend.update.end(r);
                    } catch (Error e) {
                        warning("Equalizer: live update failed: %s", e.message);
                    }
                });
            } else {
                sync.begin();
            }
            changed();
        }

        private async void sync() {
            if (!ready) return;
            if (busy) {
                dirty = true;
                return;
            }
            busy = true;
            do {
                dirty = false;
                yield sync_once();
            } while (dirty);
            busy = false;
        }

        private async void sync_once() {
            string device = output_device;
            if (backend == null || device == "") return;
            var profile = store.get_profile(device);
            bool want = profile.enabled;
            if (running_device != "" && (!want || running_device != device)) {
                string old = running_device;
                string desc;
                string current = default_sink_name(out desc);
                if (is_virtual(current) && sink_exists(old)) audio.set_default_sink(old);
                running_device = "";
                yield backend.remove(old);
                changed();
            }
            if (!want || running_device == device) return;
            try {
                yield backend.apply(device, _("%s with Equalizer").printf(describe(device)), EqualizerBands.normalize(profile.gains));
                running_device = device;
                string? sink = backend.sink_for(device);
                if (sink != null) {
                    pending_route = sink;
                    int attempts = 0;
                    Timeout.add(300, () => {
                        audio.refresh();
                        attempts++;
                        if (attempts >= 20) pending_route = "";
                        return pending_route != "" && running_device == device;
                    });
                }
                changed();
            } catch (Error e) {
                warning("Equalizer: cannot start for %s: %s", device, e.message);
            }
        }

        public void shutdown() {
            var pw = backend as PipeWireEqualizerBackend;
            string desc;
            string current = default_sink_name(out desc);
            if (running_device != "" && is_virtual(current) && sink_exists(running_device)) {
                audio.set_default_sink(running_device);
            }
            if (pw != null) pw.remove_all();
            running_device = "";
        }
    }
}
