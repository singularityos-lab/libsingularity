namespace Singularity {

    public class AppActions : Object {
        public static async void activate(string app_id, string action, Variant? parameter = null, bool start = true) {
            Variant[] values = {};
            if (parameter != null) values += new Variant.variant(parameter);
            var param = new Variant.array(VariantType.VARIANT, values);
            var platform = new VariantBuilder(VariantType.VARDICT);
            var args = new Variant("(s@av@a{sv})", action, param, platform.end());
            string path = "/" + app_id.replace(".", "/").replace("-", "_");
            try {
                var bus = yield GLib.Bus.get(BusType.SESSION);
                try {
                    yield bus.call(app_id, path, "org.freedesktop.Application", "ActivateAction", args, null,
                        start ? DBusCallFlags.NONE : DBusCallFlags.NO_AUTO_START, 5000);
                    return;
                } catch (Error e) {
                    if (!(e is DBusError.SERVICE_UNKNOWN) && !(e is DBusError.NAME_HAS_NO_OWNER)) throw e;
                    if (!start) return;
                }
                var info = ShareTargets.find_app_info(app_id);
                if (info == null) {
                    warning("%s is not running and has no desktop entry", app_id);
                    return;
                }
                bool appeared = false;
                bool resumed = false;
                SourceFunc resume = activate.callback;
                uint watch = Bus.watch_name_on_connection(bus, app_id, BusNameWatcherFlags.NONE, () => {
                    if (resumed) return;
                    resumed = true;
                    appeared = true;
                    resume();
                }, null);
                uint timeout = Timeout.add_seconds(15, () => {
                    if (!resumed) {
                        resumed = true;
                        resume();
                    }
                    return Source.REMOVE;
                });
                info.launch(null, Gdk.Display.get_default()?.get_app_launch_context());
                yield;
                Bus.unwatch_name(watch);
                if (appeared) {
                    Source.remove(timeout);
                    yield bus.call(app_id, path, "org.freedesktop.Application", "ActivateAction", args, null, DBusCallFlags.NONE, 5000);
                } else {
                    warning("%s did not start", app_id);
                }
            } catch (Error e) {
                warning("%s.%s failed: %s", app_id, action, e.message);
            }
        }
    }
}
