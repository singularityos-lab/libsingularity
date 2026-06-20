using GLib;

namespace Singularity {

    public class SessionManager : Object {
        private static SessionManager? _instance = null;

        public static SessionManager get_default() {
            if (_instance == null) {
                _instance = new SessionManager();
            }
            return _instance;
        }

        /**
         * Emitted right before the session ends (logout / shutdown / reboot)
         * so listeners (SessionRecovery) can snapshot open windows. Handlers
         * run synchronously, so keep them quick.
         */
        public signal void session_ending();

        public void lock_screen() {
            // 1. Native singularity-lockscreen (ext-session-lock-v1 + PAM)
            string? lockscreen = find_singularity_binary("singularity-lockscreen");
            if (lockscreen != null) {
                try {
                    Process.spawn_command_line_async(lockscreen);
                    return;
                } catch (Error e) {
                    warning("singularity-lockscreen failed: %s", e.message);
                }
            }

            // 2. loginctl – works when a screen-lock handler is registered.
            try {
                Process.spawn_command_line_async("loginctl lock-session");
                return;
            } catch (Error e) {
                warning("loginctl lock-session failed: %s", e.message);
            }

            // 3. org.freedesktop.ScreenSaver.Lock D-Bus call.
            try {
                var bus = Bus.get_sync(BusType.SESSION);
                bus.call_sync(
                    "org.freedesktop.ScreenSaver",
                    "/org/freedesktop/ScreenSaver",
                    "org.freedesktop.ScreenSaver",
                    "Lock",
                    null,
                    null,
                    DBusCallFlags.NONE,
                    5000
                );
                return;
            } catch (Error e) {
                debug("SessionManager: ScreenSaver.Lock unavailable, falling back to an external locker: %s", e.message);
            }

            // 4. Fallback external lockers.
            string[] lockers = { "swaylock", "gtklock", "hyprlock", "waylock" };
            foreach (var locker in lockers) {
                string? found = GLib.Environment.find_program_in_path(locker);
                if (found != null) {
                    try {
                        Process.spawn_command_line_async(found);
                        return;
                    } catch (Error e) {
                        warning("%s failed: %s", found, e.message);
                    }
                }
            }

            warning("lock_screen: no working lock mechanism found");
        }

        private string? find_singularity_binary(string name) {
            string? found = GLib.Environment.find_program_in_path(name);
            if (found != null) return found;
            string self = GLib.Environment.get_prgname() ?? "";
            string? dir = GLib.Path.get_dirname(self);
            string path = GLib.Path.build_filename(dir, name);
            if (GLib.FileUtils.test(path, GLib.FileTest.IS_EXECUTABLE)) return path;
            string[] extra = {
                GLib.Path.build_filename(GLib.Environment.get_home_dir(), ".local", "singularity", "bin", name),
                "/opt/singularity/bin/" + name,
                "/usr/lib/singularity/" + name,
                "/usr/bin/" + name
            };
            foreach (var p in extra) {
                if (GLib.FileUtils.test(p, GLib.FileTest.IS_EXECUTABLE)) return p;
            }
            return null;
        }

        public void logout() {
            session_ending();
            try {
                var bus = Bus.get_sync(BusType.SYSTEM);
                bus.call_sync(
                    "org.freedesktop.login1",
                    "/org/freedesktop/login1/session/self",
                    "org.freedesktop.login1.Session",
                    "Terminate",
                    null,
                    null,
                    DBusCallFlags.NONE,
                    5000
                );
            } catch (Error e) {
                warning("Failed to logout: %s", e.message);
            }
        }

        public void shutdown() {
            session_ending();
            try {
                var bus = Bus.get_sync(BusType.SYSTEM);
                bus.call_sync(
                    "org.freedesktop.login1",
                    "/org/freedesktop/login1",
                    "org.freedesktop.login1.Manager",
                    "PowerOff",
                    new Variant("(b)", true),
                    null,
                    DBusCallFlags.NONE,
                    5000
                );
            } catch (Error e) {
                warning("Failed to shutdown: %s", e.message);
            }
        }

        public void reboot() {
            session_ending();
            try {
                var bus = Bus.get_sync(BusType.SYSTEM);
                bus.call_sync(
                    "org.freedesktop.login1",
                    "/org/freedesktop/login1",
                    "org.freedesktop.login1.Manager",
                    "Reboot",
                    new Variant("(b)", true),
                    null,
                    DBusCallFlags.NONE,
                    5000
                );
            } catch (Error e) {
                warning("Failed to reboot: %s", e.message);
            }
        }

        public void suspend() {
            try {
                var bus = Bus.get_sync(BusType.SYSTEM);
                bus.call_sync(
                    "org.freedesktop.login1",
                    "/org/freedesktop/login1",
                    "org.freedesktop.login1.Manager",
                    "Suspend",
                    new Variant("(b)", true),
                    null,
                    DBusCallFlags.NONE,
                    5000
                );
            } catch (Error e) {
                warning("Failed to suspend: %s", e.message);
            }
        }
    }
}
