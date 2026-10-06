namespace Singularity.Core {

    public class WebKitSockets : Object {

        public static bool webkit_loaded () {
            var self = Module.open (null, ModuleFlags.LAZY);
            if (self == null) return false;
            void* symbol;
            return self.symbol ("webkit_get_major_version", out symbol) && symbol != null;
        }

        public static int clear_stale_bus_proxies (string? runtime_dir = null) {
            string dir = Path.build_filename (runtime_dir ?? Environment.get_user_runtime_dir (), "webkitgtk");
            int removed = 0;
            Dir d;
            try {
                d = Dir.open (dir);
            } catch (FileError e) {
                return 0;
            }
            string? name;
            while ((name = d.read_name ()) != null) {
                if (!name.has_prefix ("bus-proxy-")) continue;
                string path = Path.build_filename (dir, name);
                if (FileUtils.test (path, FileTest.IS_DIR)) continue;
                Socket? sock = null;
                try {
                    sock = new Socket (SocketFamily.UNIX, SocketType.STREAM, SocketProtocol.DEFAULT);
                    sock.connect (new UnixSocketAddress (path));
                } catch (Error e) {
                    if (e is IOError.CONNECTION_REFUSED && FileUtils.unlink (path) == 0) removed++;
                }
                if (sock != null) {
                    try {
                        sock.close ();
                    } catch (Error e) {
                    }
                }
            }
            return removed;
        }
    }
}
