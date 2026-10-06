namespace Singularity.SharingHost {

    public class MediaServer : Object {
        public const uint PORT = 8200;

        public string? program { get; construct; }
        public string state_dir { get; construct; }
        public bool active { get; private set; default = false; }
        public string error { get; private set; default = ""; }

        private Subprocess? process = null;

        public bool available {
            get { return program != null; }
        }

        public string backend {
            owned get { return program != null ? "rygel" : ""; }
        }

        public MediaServer (string? program, string state_dir) {
            Object (program: program, state_dir: state_dir);
        }

        public static string[] default_folders () {
            string[] folders = {};
            UserDirectory[] dirs = { UserDirectory.MUSIC, UserDirectory.PICTURES, UserDirectory.VIDEOS };
            string[] names = { "Music", "Pictures", "Videos" };
            for (int i = 0; i < dirs.length; i++) {
                string? path = Environment.get_user_special_dir (dirs[i]);
                if (path == null || path == Environment.get_home_dir ())
                    path = Path.build_filename (Environment.get_home_dir (), names[i]);
                if (FileUtils.test (path, FileTest.IS_DIR)) folders += path;
            }
            return folders;
        }

        public static string rygel_config (string[] folders, string name) {
            var sb = new StringBuilder ();
            sb.append ("[general]\nupnp-enabled=true\nport=%u\nlog-level=*:3\n\n".printf (PORT));
            sb.append ("[MediaExport]\nenabled=true\ntitle=%s\nuris=%s\n\n".printf (name, string.joinv (";", folders)));
            sb.append ("[Tracker]\nenabled=false\n\n[Tracker3]\nenabled=false\n\n[Playbin]\nenabled=false\n");
            return sb.str;
        }

        public void start (string[] folders, string name) {
            if (program == null || process != null) return;
            string conf = Path.build_filename (state_dir, "rygel.conf");
            try {
                DirUtils.create_with_parents (state_dir, 0700);
                FileUtils.set_contents (conf, rygel_config (folders.length > 0 ? folders : default_folders (), name));
                process = new Subprocess.newv ({ program, "--config", conf }, SubprocessFlags.NONE);
                active = true;
                error = "";
                var watched = process;
                watched.wait_async.begin (null, (obj, res) => {
                    if (process != watched) return;
                    process = null;
                    active = false;
                    error = _("The media server stopped.");
                });
            } catch (Error e) {
                error = e.message;
                active = false;
            }
        }

        public void stop () {
            if (process != null) {
                var p = process;
                process = null;
                p.send_signal (15);
            }
            active = false;
        }
    }
}
