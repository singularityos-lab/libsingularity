namespace Singularity.Animation {

    [DBus (name = "dev.sinty.MotionDebug")]
    public class MotionDebug : Object {

        public const string OBJECT_PATH = "/dev/sinty/MotionDebug";

        private static MotionDebug? _exported = null;

        public static void export_if_requested() {
            if (_exported != null || GLib.Environment.get_variable("SINGULARITY_MOTION_DEBUG") != "1") return;
            try {
                var connection = GLib.Bus.get_sync(GLib.BusType.SESSION);
                var service = new MotionDebug();
                connection.register_object(OBJECT_PATH, service);
                _exported = service;
            } catch (Error e) {
                warning("Motion debug not exported: %s", e.message);
            }
        }

        public void use_manual_clock() throws GLib.Error {
            var motion = Singularity.Motion.get_default();
            if (!motion.manual_clock) motion.use_manual_clock(GLib.get_monotonic_time());
        }

        public void use_frame_clock() throws GLib.Error {
            Singularity.Motion.get_default().use_frame_clock();
        }

        public void advance(uint ms, uint hz) throws GLib.Error {
            Singularity.Motion.get_default().advance(ms, hz);
        }

        public uint active_count() throws GLib.Error {
            return Singularity.Motion.get_default().active_count;
        }

        public bool capture(string type_name, string png_path) throws GLib.Error {
            var toplevels = Gtk.Window.get_toplevels();
            for (uint i = 0; i < toplevels.get_n_items(); i++) {
                var window = toplevels.get_item(i) as Gtk.Window;
                if (window == null || !window.get_mapped()) continue;
                if (type_name != "" && window.get_type().name() != type_name) continue;
                var target = window.get_child() ?? (Gtk.Widget) window;
                return Singularity.Motion.capture(target, png_path);
            }
            return false;
        }
    }
}
