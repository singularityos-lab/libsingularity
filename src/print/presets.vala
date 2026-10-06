namespace Singularity.Print {

    /**
     * Named print presets shared by every application, and the last used
     * settings of each application, in one key file under the user's
     * configuration directory.
     */
    public class PresetStore : Object {
        public string path { get; construct; }

        public signal void changed();

        private static PresetStore? instance;

        public PresetStore(string path) {
            Object(path: path);
        }

        public static PresetStore get_default() {
            if (instance == null)
                instance = new PresetStore(Path.build_filename(Environment.get_user_config_dir(),
                                                               "singularity", "printing.ini"));
            return instance;
        }

        private KeyFile load() {
            var kf = new KeyFile();
            try {
                kf.load_from_file(path, KeyFileFlags.NONE);
            } catch (Error e) {
            }
            return kf;
        }

        private void store(KeyFile kf) throws Error {
            DirUtils.create_with_parents(Path.get_dirname(path), 0700);
            kf.save_to_file(path);
        }

        public string[] list_presets() {
            string[] names = {};
            foreach (var g in load().get_groups()) {
                if (g.has_prefix("preset:")) names += g.substring(7);
            }
            return names;
        }

        public void save_preset(string name, JobOptions options) throws Error {
            var kf = load();
            kf.set_string("preset:" + name, "options", options.to_variant(false).print(true));
            store(kf);
            changed();
        }

        public void delete_preset(string name) throws Error {
            var kf = load();
            if (kf.has_group("preset:" + name)) kf.remove_group("preset:" + name);
            store(kf);
            changed();
        }

        public JobOptions? load_preset(string name) {
            return read(load(), "preset:" + name);
        }

        public void remember(string app_id, JobOptions options) {
            var kf = load();
            kf.set_string("last:" + app_id, "options", options.to_variant(false).print(true));
            try {
                store(kf);
            } catch (Error e) {
                warning("Cannot save print settings: %s", e.message);
            }
        }

        public JobOptions? last_used(string app_id) {
            return read(load(), "last:" + app_id);
        }

        private JobOptions? read(KeyFile kf, string group) {
            try {
                var text = kf.get_string(group, "options");
                var v = Variant.parse(VariantType.VARDICT, text);
                var o = new JobOptions();
                o.apply(v);
                return o;
            } catch (Error e) {
                return null;
            }
        }
    }
}
