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
            return model_from(
                "/sys/devices/virtual/dmi/id/product_name",
                "/sys/firmware/devicetree/base/model"
            );
        }

        internal static string model_from(string dmi_path, string dt_path) {
            string? dmi = read_trimmed(dmi_path);
            if (dmi != null && dmi != "") return dmi;
            // DEVICE-FIX(arm64): Arm boards have no DMI and name themselves only in the devicetree; without it they show Unknown Model
            string? dt = read_trimmed(dt_path);
            if (dt != null && dt != "") return dt;
            return "Unknown Model";
        }

        private static string? read_trimmed(string path) {
            try {
                string content;
                if (FileUtils.get_contents(path, out content)) {
                    return content.strip();
                }
            } catch (Error e) {}
            return null;
        }

        public static string processor() {
            return processor_from("/proc/cpuinfo", "/sys/devices/soc0");
        }

        internal static string processor_from(string cpuinfo_path, string soc_path) {
            string content;
            try {
                if (!FileUtils.get_contents(cpuinfo_path, out content)) content = "";
            } catch (Error e) {
                content = "";
            }
            foreach (string line in content.split("\n")) {
                if (line.has_prefix("model name")) {
                    return line.split(":", 2)[1].strip();
                }
            }
            // DEVICE-FIX(arm64): Arm /proc/cpuinfo has no model name; without the SoC and core fallback every Arm board shows Unknown Processor
            string? soc = soc_name(soc_path);
            string? cores = arm_cores(content);
            if (soc != null && cores != null) return soc + " (" + cores + ")";
            if (soc != null) return soc;
            if (cores != null) return cores;
            return "Unknown Processor";
        }

        private static string? soc_name(string soc_path) {
            string? family = read_trimmed(Path.build_filename(soc_path, "family"));
            string? machine = read_trimmed(Path.build_filename(soc_path, "machine"));
            if (machine == null || machine == "") return null;
            if (family == null || family == "" || machine.down().contains(family.down())) return machine;
            return family + " " + machine;
        }

        private static string? arm_core_name(string implementer, string part) {
            if (implementer != "0x41") return null;
            switch (part) {
                case "0xc07": return "Cortex-A7";
                case "0xc0f": return "Cortex-A15";
                case "0xd03": return "Cortex-A53";
                case "0xd04": return "Cortex-A35";
                case "0xd05": return "Cortex-A55";
                case "0xd07": return "Cortex-A57";
                case "0xd08": return "Cortex-A72";
                case "0xd09": return "Cortex-A73";
                case "0xd0a": return "Cortex-A75";
                case "0xd0b": return "Cortex-A76";
                case "0xd0c": return "Neoverse-N1";
                case "0xd0d": return "Cortex-A77";
                case "0xd40": return "Neoverse-V1";
                case "0xd41": return "Cortex-A78";
                case "0xd44": return "Cortex-X1";
                case "0xd46": return "Cortex-A510";
                case "0xd47": return "Cortex-A710";
                case "0xd48": return "Cortex-X2";
                case "0xd49": return "Neoverse-N2";
                case "0xd4d": return "Cortex-A715";
                case "0xd4e": return "Cortex-X3";
                case "0xd80": return "Cortex-A520";
                case "0xd81": return "Cortex-A720";
                case "0xd82": return "Cortex-X4";
            }
            return null;
        }

        private static string? arm_cores(string cpuinfo) {
            var order = new GenericArray<string>();
            var counts = new HashTable<string, int>(str_hash, str_equal);
            string implementer = "";
            int total = 0;
            foreach (string raw in cpuinfo.split("\n")) {
                string[] kv = raw.split(":", 2);
                if (kv.length != 2) continue;
                string key = kv[0].strip();
                string val = kv[1].strip();
                if (key == "CPU implementer") {
                    implementer = val;
                } else if (key == "CPU part") {
                    total++;
                    string name = arm_core_name(implementer, val) ?? "";
                    if (!counts.contains(name)) order.add(name);
                    counts[name] = counts[name] + 1;
                }
            }
            if (total == 0) return null;
            string[] parts = {};
            for (int i = 0; i < order.length; i++) {
                if (order[i] == "") continue;
                parts += "%d \u00d7 %s".printf(counts[order[i]], order[i]);
            }
            if (parts.length == 0 || counts.contains("")) {
                return total == 1 ? "1 core" : "%d cores".printf(total);
            }
            return string.joinv(" + ", parts);
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
            uint64 total = disks_from_sys("/sys/block");
            if (total > 0) return "%.1f GB".printf(total / 1000.0 / 1000.0 / 1000.0);
            try {
                var file = File.new_for_path(Environment.get_home_dir());
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

        internal static uint64 disks_from_sys(string sys_block) {
            uint64 total = 0;
            try {
                var dir = Dir.open(sys_block);
                string? name;
                while ((name = dir.read_name()) != null) {
                    if (name.has_prefix("loop") || name.has_prefix("ram") || name.has_prefix("zram")
                        || name.has_prefix("dm-") || name.has_prefix("sr") || name.has_prefix("md")
                        || name.has_prefix("fd") || name.has_prefix("nbd")) continue;
                    string base_path = Path.build_filename(sys_block, name);
                    string content;
                    if (FileUtils.get_contents(Path.build_filename(base_path, "removable"), out content)
                        && content.strip() == "1") continue;
                    if (!FileUtils.get_contents(Path.build_filename(base_path, "size"), out content)) continue;
                    uint64 sectors = 0;
                    if (!uint64.try_parse(content.strip(), out sectors)) continue;
                    total += sectors * 512;
                }
            } catch (Error e) {}
            return total;
        }

        private static string? virtual_gpu(string vendor_id) {
            switch (vendor_id) {
                case "0x1af4": return "VirtIO GPU";
                case "0x15ad": return "VMware SVGA";
                case "0x1234": return "QEMU Standard VGA";
                case "0x1414": return "Microsoft Hyper-V Video";
                case "0x80ee": return "VirtualBox Graphics";
                case "0x1b36": return "QXL Paravirtual Graphics";
            }
            return null;
        }

        internal static string graphics_from_drm(string drm_path) {
            bool intel = false;
            bool nvidia = false;
            bool amd = false;
            string? unknown = null;

            try {
                var dir = Dir.open(drm_path);
                string? name;
                while ((name = dir.read_name()) != null) {
                    if (!is_drm_card(name)) continue;

                    string vendor_id;
                    string vendor_path = Path.build_filename(
                        drm_path, name, "device", "vendor"
                    );
                    if (!FileUtils.test(vendor_path, FileTest.EXISTS)) continue;
                    if (!FileUtils.get_contents(vendor_path, out vendor_id)) continue;
                    vendor_id = vendor_id.strip();
                    if (vendor_id == "0x8086") intel = true;
                    else if (vendor_id == "0x10de") nvidia = true;
                    else if (vendor_id == "0x1002") amd = true;
                    else if (unknown == null) unknown = vendor_id;
                }
            } catch (Error e) {}

            if (intel && nvidia) return "Intel + NVIDIA Graphics";
            if (intel && amd) return "Intel + AMD Graphics";
            if (amd && nvidia) return "AMD + NVIDIA Graphics";
            if (nvidia) return "NVIDIA Graphics";
            if (amd) return "AMD Graphics";
            if (intel) return "Intel Graphics";
            if (unknown != null) return virtual_gpu(unknown) ?? "Unknown GPU (" + unknown + ")";
            return "Unknown Graphics";
        }

        internal static string? soc_gpu(string drivers_path) {
            string[] drivers = { "adreno", "msm_gpu", "panfrost", "panthor", "lima", "v3d", "vc4-drm", "etnaviv", "gk20a", "gp10b", "gv11b", "powervr" };
            foreach (string driver in drivers) {
                string dir = Path.build_filename(drivers_path, driver);
                Dir d;
                try {
                    d = Dir.open(dir);
                } catch (Error e) {
                    continue;
                }
                string? dev;
                while ((dev = d.read_name()) != null) {
                    string? name = gpu_from_compatible(
                        read_string_list(Path.build_filename(dir, dev, "of_node", "compatible"))
                    );
                    if (name != null) return name;
                }
            }
            return null;
        }

        private static string[] read_string_list(string path) {
            string[] list = {};
            uint8[] data;
            try {
                if (!FileUtils.get_data(path, out data)) return list;
            } catch (Error e) {
                return list;
            }
            var cur = new StringBuilder();
            foreach (uint8 b in data) {
                if (b == 0) {
                    if (cur.len > 0) list += cur.str;
                    cur.truncate(0);
                } else {
                    cur.append_c((char) b);
                }
            }
            if (cur.len > 0) list += cur.str;
            return list;
        }

        internal static string? gpu_from_compatible(string[] compatible) {
            bool adreno = false;
            foreach (string c in compatible) {
                if (c == "qcom,adreno") {
                    adreno = true;
                } else if (c.has_prefix("qcom,adreno-")) {
                    adreno = true;
                    string id = c.substring(12);
                    if (id.contains(".")) {
                        string model = id.split(".")[0];
                        if (model.length >= 3 && model[0].isdigit()) return "Qualcomm Adreno " + model;
                    } else if (id.length == 8 && id[0] == '0') {
                        uint64 v;
                        unowned string rest;
                        if (uint64.try_parse(id, out v, out rest, 16) && rest == "") {
                            return "Qualcomm Adreno %u%u%u".printf(
                                (uint) ((v >> 24) & 0xff), (uint) ((v >> 16) & 0xff), (uint) ((v >> 8) & 0xff)
                            );
                        }
                    }
                } else if (c.has_prefix("arm,mali-")) {
                    string model = c.substring(9);
                    if (model.length > 1 && (model[0] == 't' || model[0] == 'g') && model[1].isdigit()) {
                        return "Arm Mali-" + model.up();
                    }
                    return "Arm Mali";
                } else if (c.has_prefix("brcm,") && (c.contains("v3d") || c.contains("vc4") || c.contains("vc5"))) {
                    return "Broadcom VideoCore";
                } else if (c.has_prefix("nvidia,") && (c.contains("gk20a") || c.contains("gm20b") || c.contains("gp10b") || c.contains("gv11b"))) {
                    return "NVIDIA Tegra Graphics";
                } else if (c.has_prefix("vivante,")) {
                    return "Vivante GPU";
                } else if (c.has_prefix("img,img-")) {
                    return "Imagination PowerVR";
                }
            }
            return adreno ? "Qualcomm Adreno" : null;
        }

        private static bool is_drm_card(string name) {
            if (!name.has_prefix("card") || name.length == 4) return false;
            for (int i = 4; i < name.length; i++) {
                if (!name[i].isdigit()) return false;
            }
            return true;
        }

        public static string graphics() {
            string drm = graphics_from_drm("/sys/class/drm");
            if (drm != "Unknown Graphics") return drm;
            // DEVICE-FIX(arm64): SoC GPUs are platform devices with no PCI vendor id; without reading the bound GPU driver's devicetree node they show Unknown Graphics
            return soc_gpu("/sys/bus/platform/drivers") ?? drm;
        }
    }
}
