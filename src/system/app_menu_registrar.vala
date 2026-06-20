using GLib;

namespace Singularity {

    [DBus (name = "org.freedesktop.DBus")]
    interface DBusProxy : Object {
        [DBus (name = "GetConnectionUnixProcessID")]
        public abstract uint get_connection_unix_process_id (string name) throws GLib.Error;
    }

    [DBus (name = "com.canonical.AppMenu.Registrar")]
    public class AppMenuRegistrar : Object {
        private HashTable<uint32, string> window_bus_map;
        private HashTable<uint32, string> window_path_map;
        private HashTable<string, string> app_bus_map; // app_name -> bus_name
        private HashTable<string, string> app_path_map; // app_name -> object_path

        public AppMenuRegistrar() {
            window_bus_map = new HashTable<uint32, string>(direct_hash, direct_equal);
            window_path_map = new HashTable<uint32, string>(direct_hash, direct_equal);
            app_bus_map = new HashTable<string, string>(str_hash, str_equal);
            app_path_map = new HashTable<string, string>(str_hash, str_equal);
        }

        public void register_window(uint32 windowId, GLib.ObjectPath objectPath, GLib.BusName sender) {
            message("Registrar: RegisterWindow(%u, %s) from %s", windowId, objectPath, sender);

            window_bus_map.insert(windowId, sender);
            window_path_map.insert(windowId, objectPath);

            // Try to resolve the application name from the sender
            try {
                DBusProxy dbus_proxy = Bus.get_proxy_sync(BusType.SESSION, "org.freedesktop.DBus", "/org/freedesktop/DBus");
                uint pid = dbus_proxy.get_connection_unix_process_id(sender);

                string cmdline;
                if (FileUtils.get_contents("/proc/%u/cmdline".printf(pid), out cmdline)) {
                    string app_name = Path.get_basename(cmdline);
                    message("Registrar: Identified app '%s' for sender %s (PID %u)", app_name, sender, pid);
                    app_bus_map.insert(app_name, sender);
                    app_path_map.insert(app_name, objectPath);
                }
            } catch (GLib.Error e) {
                warning("Registrar: Failed to resolve PID/Name for %s: %s", sender, e.message);
            }

            menu_registered(windowId, sender, objectPath);
        }

        public void unregister_window(uint32 windowId) {
            message("Registrar: UnregisterWindow(%u)", windowId);
            window_bus_map.remove(windowId);
            window_path_map.remove(windowId);
        }

        public string? get_bus_for_app(string app_name) {
            return app_bus_map.get(app_name);
        }

        public string? get_path_for_app(string app_name) {
            return app_path_map.get(app_name);
        }

        // Look up by the X11 window XID the app passed to RegisterWindow. This
        // is the reliable key: process-name resolution breaks for sandboxed
        // apps, which all resolve to "xdg-dbus-proxy" (#82).
        public string? get_bus_for_window(uint32 windowId) {
            return window_bus_map.get(windowId);
        }

        public string? get_path_for_window(uint32 windowId) {
            return window_path_map.get(windowId);
        }

        public signal void menu_registered(uint32 windowId, string busName, string objectPath);
    }
}
