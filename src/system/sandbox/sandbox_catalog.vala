using GLib;

namespace Singularity.Sandbox {

    public class CatalogEntry {
        public Group group;
        public string context_key;
        public string key;

        public CatalogEntry(Group group, string context_key, string key) {
            this.group = group;
            this.context_key = context_key;
            this.key = key;
        }
    }

    public class Catalog : Object {
        public static CatalogEntry[] toggles() {
            return {
                new CatalogEntry(Group.NETWORK, "shared", "network"),
                new CatalogEntry(Group.NETWORK, "shared", "ipc"),
                new CatalogEntry(Group.DEVICES, "devices", "dri"),
                new CatalogEntry(Group.DEVICES, "devices", "input"),
                new CatalogEntry(Group.DEVICES, "devices", "usb"),
                new CatalogEntry(Group.DEVICES, "devices", "kvm"),
                new CatalogEntry(Group.DEVICES, "devices", "all"),
                new CatalogEntry(Group.FEATURES, "features", "bluetooth"),
                new CatalogEntry(Group.FEATURES, "features", "devel"),
                new CatalogEntry(Group.SOCKETS, "sockets", "wayland"),
                new CatalogEntry(Group.SOCKETS, "sockets", "x11"),
                new CatalogEntry(Group.SOCKETS, "sockets", "fallback-x11"),
                new CatalogEntry(Group.SOCKETS, "sockets", "pulseaudio"),
                new CatalogEntry(Group.SOCKETS, "sockets", "cups"),
                new CatalogEntry(Group.SOCKETS, "sockets", "pcsc"),
                new CatalogEntry(Group.SOCKETS, "sockets", "ssh-auth"),
                new CatalogEntry(Group.SOCKETS, "sockets", "gpg-agent"),
                new CatalogEntry(Group.SOCKETS, "sockets", "session-bus"),
                new CatalogEntry(Group.SOCKETS, "sockets", "system-bus")
            };
        }

        public static string[] standard_filesystems() {
            return { "home", "xdg-documents", "xdg-download", "xdg-music", "xdg-pictures", "xdg-videos" };
        }

        public static bool is_known(string context_key, string key) {
            foreach (var entry in toggles()) {
                if (entry.context_key == context_key && entry.key == key) return true;
            }
            return false;
        }

        public static Group group_for(string context_key) {
            switch (context_key) {
                case "shared": return Group.NETWORK;
                case "devices": return Group.DEVICES;
                case "features": return Group.FEATURES;
                case "filesystems": return Group.FILES;
                default: return Group.SOCKETS;
            }
        }

        public static string context_key_for(Group group) {
            switch (group) {
                case Group.NETWORK: return "shared";
                case Group.DEVICES: return "devices";
                case Group.FEATURES: return "features";
                case Group.FILES: return "filesystems";
                default: return "sockets";
            }
        }

        public static string group_title(Group group) {
            switch (group) {
                case Group.FILES: return _("Files and Folders");
                case Group.NETWORK: return _("Network");
                case Group.DEVICES: return _("Devices");
                case Group.SOCKETS: return _("Display, Sound and Services");
                case Group.FEATURES: return _("Features");
                case Group.SESSION_BUS: return _("Session Services");
                case Group.SYSTEM_BUS: return _("System Services");
                default: return _("Environment");
            }
        }

        public static string label(string context_key, string key) {
            switch (key) {
                case "network": return _("Network");
                case "ipc": return _("Shared Memory With Other Apps");
                case "dri": return _("Graphics Acceleration");
                case "input": return _("Game Controllers and Input Devices");
                case "usb": return _("USB Devices");
                case "kvm": return _("Virtualization");
                case "all": return _("All Devices");
                case "shm": return _("Shared Memory");
                case "bluetooth": return _("Bluetooth");
                case "devel": return _("Debugging Tools");
                case "multiarch": return _("Run 32-bit Programs");
                case "canbus": return _("CAN Bus");
                case "wayland": return _("Wayland Display");
                case "x11": return _("X11 Display");
                case "fallback-x11": return _("X11 When Wayland Is Missing");
                case "pulseaudio": return _("Sound and Microphone");
                case "cups": return _("Printing");
                case "pcsc": return _("Smart Cards");
                case "ssh-auth": return _("SSH Keys");
                case "gpg-agent": return _("GPG Keys");
                case "session-bus": return _("All Session Services");
                case "system-bus": return _("All System Services");
                case "gpu": return _("Graphics Acceleration");
                case "camera": return _("Cameras");
            }
            return key;
        }

        public static string detail(string context_key, string key) {
            switch (key) {
                case "network": return _("Connect to the internet and local networks");
                case "all": return _("Every device, including cameras and webcams");
                case "x11": return _("Can see other X11 windows and keystrokes");
                case "session-bus": return _("Talk to every service in your session");
                case "system-bus": return _("Talk to every service of the system");
                case "pulseaudio": return _("Play sound and record from microphones");
            }
            return "";
        }

        public static string describe_filesystem(string filesystem) {
            string name = FlatpakContext.name_of(filesystem);
            string mode = "";
            int colon = filesystem.last_index_of(":");
            if (colon > 0 && !filesystem.has_prefix("!")) mode = filesystem.substring(colon + 1);
            string label;
            switch (name) {
                case "host": label = _("All Files"); break;
                case "host-os": label = _("System Files"); break;
                case "host-etc": label = _("System Settings Files"); break;
                case "home": label = _("Home Folder"); break;
                case "xdg-download": label = _("Downloads"); break;
                case "xdg-documents": label = _("Documents"); break;
                case "xdg-pictures": label = _("Pictures"); break;
                case "xdg-music": label = _("Music"); break;
                case "xdg-videos": label = _("Videos"); break;
                case "xdg-desktop": label = _("Desktop"); break;
                case "xdg-public-share": label = _("Public"); break;
                case "xdg-templates": label = _("Templates"); break;
                case "xdg-config": label = _("App Settings Folder"); break;
                case "xdg-cache": label = _("Cache Folder"); break;
                case "xdg-data": label = _("App Data Folder"); break;
                case "xdg-run": label = _("Runtime Folder"); break;
                default: label = name; break;
            }
            if (mode == "ro") return _("%s, read only").printf(label);
            if (mode == "create") return _("%s, can create").printf(label);
            return label;
        }
    }
}
