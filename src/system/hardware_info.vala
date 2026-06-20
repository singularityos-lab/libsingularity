using GLib;

namespace Singularity {

    public class HardwareInfo {

        public static string? os_release(string key) {
            try {
                string content;
                FileUtils.get_contents("/etc/os-release", out content);
                foreach (string line in content.split("\n")) {
                    if (line.has_prefix(key + "=")) {
                        return line.substring(key.length + 1).replace("\"", "").strip();
                    }
                }
            } catch (Error e) {}
            return null;
        }

        public static string os_name() {
            string? v = os_release("PRETTY_NAME");
            return (v != null && v != "") ? v : "Linux";
        }

        public static string hardware_model() {
            try {
                string content;
                if (FileUtils.get_contents("/sys/devices/virtual/dmi/id/product_name", out content)) {
                    return content.strip();
                }
            } catch (Error e) {}
            return "Unknown Model";
        }

        public static string processor() {
            try {
                string content;
                FileUtils.get_contents("/proc/cpuinfo", out content);
                foreach (string line in content.split("\n")) {
                    if (line.has_prefix("model name")) {
                        return line.split(":")[1].strip();
                    }
                }
            } catch (Error e) {}
            return "Unknown Processor";
        }

        public static string memory() {
            try {
                string content;
                FileUtils.get_contents("/proc/meminfo", out content);
                foreach (string line in content.split("\n")) {
                    if (line.has_prefix("MemTotal:")) {
                        string val = line.split(":")[1].strip().split(" ")[0];
                        int64 kb = int64.parse(val);
                        return "%.1f GiB".printf(kb / 1024.0 / 1024.0);
                    }
                }
            } catch (Error e) {}
            return "Unknown Memory";
        }

        public static string disk() {
            try {
                var file = File.new_for_path("/");
                var info = file.query_filesystem_info(FileAttribute.FILESYSTEM_SIZE, null);
                uint64 size = info.get_attribute_uint64(FileAttribute.FILESYSTEM_SIZE);
                return "%.1f GB".printf(size / 1000.0 / 1000.0 / 1000.0);
            } catch (Error e) {}
            return "Unknown";
        }

        public static string kernel() {
            try {
                string content;
                FileUtils.get_contents("/proc/version", out content);
                return content.split(" ")[2];
            } catch (Error e) {}
            return "Unknown";
        }

        public static string firmware() {
            try {
                string content;
                if (FileUtils.get_contents("/sys/class/dmi/id/bios_version", out content)) {
                    return content.strip();
                }
            } catch (Error e) {}
            return "Unknown";
        }

        public static string graphics() {
            try {
                string vendor_id;
                if (FileUtils.get_contents("/sys/class/drm/card0/device/vendor", out vendor_id)) {
                    vendor_id = vendor_id.strip();
                    if (vendor_id == "0x8086") return "Intel Graphics";
                    if (vendor_id == "0x10de") return "NVIDIA Graphics";
                    if (vendor_id == "0x1002") return "AMD Graphics";
                    return "Unknown GPU (" + vendor_id + ")";
                }
            } catch (Error e) {}
            return "Unknown Graphics";
        }
    }
}
