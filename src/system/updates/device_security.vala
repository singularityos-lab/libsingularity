using GLib;

namespace Singularity.Firmware {

    public class SecurityAttr : Object {
        public const uint64 FLAG_SUCCESS = 1 << 0;
        public const uint64 FLAG_OBSOLETED = 1 << 1;
        public const uint64 FLAG_MISSING_DATA = 1 << 2;
        public const uint64 FLAG_RUNTIME_ISSUE = 1 << 10;
        public const uint64 FLAG_ACTION_CONTACT_OEM = 1 << 11;
        public const uint64 FLAG_ACTION_CONFIG_FW = 1 << 12;
        public const uint64 FLAG_ACTION_CONFIG_OS = 1 << 13;

        public string appstream_id { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string summary { get; set; default = ""; }
        public string fwupd_description { get; set; default = ""; }
        public uint level { get; set; default = 0; }
        public uint result { get; set; default = 0; }
        public uint64 flags { get; set; default = 0; }

        public bool success {
            get { return (flags & FLAG_SUCCESS) != 0; }
        }

        public bool obsoleted {
            get { return (flags & FLAG_OBSOLETED) != 0; }
        }

        public bool failing {
            get {
                if (success || obsoleted) return false;
                if ((flags & FLAG_MISSING_DATA) != 0) return false;
                return level > 0 || (flags & FLAG_RUNTIME_ISSUE) != 0;
            }
        }

        public string title {
            owned get {
                string? known = known_title(appstream_id);
                if (known != null) return known;
                if (name != "") return name;
                if (summary != "") return summary;
                return appstream_id;
            }
        }

        public string explanation {
            owned get {
                string? known = known_explanation(appstream_id);
                if (known != null) return known;
                if (fwupd_description != "") return Client.markup_to_text(fwupd_description);
                if (summary != "" && summary != title) return summary;
                return _("Reported by the firmware security check.");
            }
        }

        public string result_text {
            owned get {
                switch (result) {
                    case 2: return _("Not enabled.");
                    case 4: return _("Not valid.");
                    case 6: return _("Not locked.");
                    case 8: return _("Not encrypted.");
                    case 9: return _("Tainted.");
                    case 12: return _("Not found.");
                    case 14: return _("Not supported.");
                }
                return _("Not in place.");
            }
        }

        public string advice {
            owned get {
                if ((flags & FLAG_ACTION_CONFIG_FW) != 0) return _("Change this in the firmware setup of your computer.");
                if ((flags & FLAG_ACTION_CONFIG_OS) != 0) return _("Change this in the operating system configuration.");
                if ((flags & FLAG_ACTION_CONTACT_OEM) != 0) return _("Only the maker of your computer can fix this.");
                return "";
            }
        }

        public static SecurityAttr from_variant(Variant dict) {
            var attr = new SecurityAttr();
            attr.appstream_id = Client.lookup_string(dict, "AppstreamId");
            attr.name = Client.lookup_string(dict, "Name");
            attr.summary = Client.lookup_string(dict, "Summary");
            attr.fwupd_description = Client.lookup_string(dict, "Description");
            Variant? level = dict.lookup_value("HsiLevel", VariantType.UINT32);
            if (level != null) attr.level = level.get_uint32();
            Variant? result = dict.lookup_value("HsiResult", VariantType.UINT32);
            if (result != null) attr.result = result.get_uint32();
            Variant? flags = dict.lookup_value("Flags", VariantType.UINT64);
            if (flags != null) attr.flags = flags.get_uint64();
            return attr;
        }

        public static string? known_title(string id) {
            switch (id) {
                case "org.fwupd.hsi.Uefi.SecureBoot": return _("Secure Boot");
                case "org.fwupd.hsi.Tpm.Version20": return _("TPM 2.0");
                case "org.fwupd.hsi.Tpm.ReconstructionPcr0": return _("TPM Boot Measurements");
                case "org.fwupd.hsi.Tpm.EmptyPcr": return _("TPM Measurement Registers");
                case "org.fwupd.hsi.Iommu": return _("IOMMU Protection");
                case "org.fwupd.hsi.Kernel.Lockdown": return _("Kernel Lockdown");
                case "org.fwupd.hsi.Kernel.Tainted": return _("Trusted Kernel");
                case "org.fwupd.hsi.Kernel.Swap": return _("Encrypted Swap");
                case "org.fwupd.hsi.EncryptedRam": return _("Encrypted Memory");
                case "org.fwupd.hsi.SuspendToRam": return _("Suspend to RAM");
                case "org.fwupd.hsi.SuspendToIdle": return _("Suspend to Idle");
                case "org.fwupd.hsi.Uefi.Pk": return _("Platform Key");
                case "org.fwupd.hsi.Uefi.Db": return _("Secure Boot Keys");
                case "org.fwupd.hsi.Uefi.BootserviceVars": return _("Firmware Variables");
                case "org.fwupd.hsi.Uefi.MemoryProtection": return _("Firmware Memory Protection");
                case "org.fwupd.hsi.Spi.Bioswe":
                case "org.fwupd.hsi.Spi.Ble":
                case "org.fwupd.hsi.Spi.SmmBwp":
                case "org.fwupd.hsi.Amd.SpiWriteProtection":
                    return _("Firmware Write Protection");
                case "org.fwupd.hsi.Spi.Descriptor": return _("Flash Descriptor Lock");
                case "org.fwupd.hsi.Amd.SpiReplayProtection": return _("Firmware Replay Protection");
                case "org.fwupd.hsi.Amd.RollbackProtection": return _("Firmware Rollback Protection");
                case "org.fwupd.hsi.Amd.PlatformSecureBoot": return _("Platform Secure Boot");
                case "org.fwupd.hsi.IntelCet.Enabled":
                case "org.fwupd.hsi.IntelCet.Active":
                    return _("Control-Flow Protection");
                case "org.fwupd.hsi.IntelSmap": return _("Supervisor Access Prevention");
                case "org.fwupd.hsi.PlatformDebugEnabled":
                case "org.fwupd.hsi.PlatformDebugLocked":
                    return _("Hardware Debugging Lock");
                case "org.fwupd.hsi.PlatformFusing": return _("Production Fusing");
                case "org.fwupd.hsi.Mei.ManufacturingMode": return _("Management Engine Manufacturing Mode");
                case "org.fwupd.hsi.Mei.OverrideStrap": return _("Management Engine Override");
                case "org.fwupd.hsi.Mei.Version": return _("Management Engine Version");
                case "org.fwupd.hsi.Mei.KeyManifest": return _("Management Engine Key Manifest");
                case "org.fwupd.hsi.Fwupd.Plugins": return _("Firmware Check Plugins");
                case "org.fwupd.hsi.Fwupd.Attestation": return _("Firmware Attestation");
                case "org.fwupd.hsi.Fwupd.Updates": return _("Firmware Updates");
                case "org.fwupd.hsi.BiosCapsuleUpdates": return _("Capsule Updates");
                case "org.fwupd.hsi.PrebootDma": return _("Pre-boot DMA Protection");
                case "org.fwupd.hsi.SupportedCpu": return _("Supported Processor");
            }
            if (id.has_prefix("org.fwupd.hsi.IntelBootguard.")) return _("Boot Guard");
            return null;
        }

        public static string? known_explanation(string id) {
            switch (id) {
                case "org.fwupd.hsi.Uefi.SecureBoot":
                    return _("Only signed boot loaders and kernels can start, so malware cannot load before the system.");
                case "org.fwupd.hsi.Tpm.Version20":
                    return _("A TPM 2.0 chip keeps encryption keys safe and records how the computer started.");
                case "org.fwupd.hsi.Tpm.ReconstructionPcr0":
                case "org.fwupd.hsi.Tpm.EmptyPcr":
                    return _("The TPM measured the firmware as it started, so tampering can be detected.");
                case "org.fwupd.hsi.Iommu":
                    return _("Devices you plug in can only reach the memory they are allowed to use.");
                case "org.fwupd.hsi.Kernel.Lockdown":
                    return _("Nobody, not even an administrator, can change the running kernel.");
                case "org.fwupd.hsi.Kernel.Tainted":
                    return _("The kernel runs only signed, unmodified code.");
                case "org.fwupd.hsi.Kernel.Swap":
                    return _("Memory written to disk is encrypted, or no swap is used.");
                case "org.fwupd.hsi.EncryptedRam":
                    return _("Memory is encrypted, so it cannot be read by someone with physical access.");
                case "org.fwupd.hsi.SuspendToRam":
                    return _("Deep sleep keeps memory powered and exposed. Suspending to idle is safer.");
                case "org.fwupd.hsi.SuspendToIdle":
                    return _("The computer sleeps in a mode that keeps its protections active.");
                case "org.fwupd.hsi.Uefi.Pk":
                case "org.fwupd.hsi.Uefi.Db":
                    return _("Secure Boot uses real keys from the maker, not publicly known test keys.");
                case "org.fwupd.hsi.Uefi.BootserviceVars":
                    return _("Firmware settings cannot be read or changed after the system has started.");
                case "org.fwupd.hsi.Uefi.MemoryProtection":
                    return _("The firmware keeps its code and data in protected memory.");
                case "org.fwupd.hsi.Spi.Bioswe":
                case "org.fwupd.hsi.Spi.Ble":
                case "org.fwupd.hsi.Spi.SmmBwp":
                case "org.fwupd.hsi.Amd.SpiWriteProtection":
                    return _("The chip that holds the firmware cannot be rewritten by the running system.");
                case "org.fwupd.hsi.Spi.Descriptor":
                    return _("The regions of the firmware chip are locked against changes.");
                case "org.fwupd.hsi.Amd.SpiReplayProtection":
                case "org.fwupd.hsi.Amd.RollbackProtection":
                    return _("Older firmware with known problems cannot be installed again.");
                case "org.fwupd.hsi.Amd.PlatformSecureBoot":
                    return _("The processor checks the firmware signature before running it.");
                case "org.fwupd.hsi.IntelCet.Enabled":
                case "org.fwupd.hsi.IntelCet.Active":
                case "org.fwupd.hsi.IntelSmap":
                    return _("The processor blocks common ways of hijacking running programs.");
                case "org.fwupd.hsi.PlatformDebugEnabled":
                case "org.fwupd.hsi.PlatformDebugLocked":
                case "org.fwupd.hsi.PlatformFusing":
                    return _("Factory debugging features are locked, as they should be on a finished product.");
                case "org.fwupd.hsi.Mei.ManufacturingMode":
                case "org.fwupd.hsi.Mei.OverrideStrap":
                case "org.fwupd.hsi.Mei.KeyManifest":
                    return _("The Management Engine is locked and uses the maker's production keys.");
                case "org.fwupd.hsi.Mei.Version":
                    return _("The Management Engine firmware has no known security problems.");
                case "org.fwupd.hsi.Fwupd.Plugins":
                case "org.fwupd.hsi.Fwupd.Attestation":
                    return _("The firmware security check can inspect this computer completely.");
                case "org.fwupd.hsi.Fwupd.Updates":
                case "org.fwupd.hsi.BiosCapsuleUpdates":
                    return _("The system firmware can be updated when the maker fixes problems.");
                case "org.fwupd.hsi.PrebootDma":
                    return _("Devices cannot read memory while the computer is starting.");
                case "org.fwupd.hsi.SupportedCpu":
                    return _("The firmware security check knows how to inspect this processor.");
            }
            if (id.has_prefix("org.fwupd.hsi.IntelBootguard.")) {
                return _("The processor checks that the firmware comes from the maker before running it.");
            }
            return null;
        }
    }
}

namespace Singularity {

    public enum SecureBootState {
        UNKNOWN,
        ENABLED,
        DISABLED,
        SETUP_MODE,
        UNSUPPORTED
    }

    public enum EncryptionState {
        UNKNOWN,
        ENCRYPTED,
        NOT_ENCRYPTED
    }

    public class DeviceSecurity : Object {
        private const string EFI_GLOBAL = "8be4df61-93ca-11d2-aa0d-00e098032b8c";
        private const uint FS_IOC_GETFLAGS = 0x80086601U;
        private const long FS_ENCRYPT_FL = 0x800;

        public string root { get; construct; default = ""; }

        public bool tpm_present { get; private set; default = false; }
        public string tpm_version { get; private set; default = ""; }
        public SecureBootState secure_boot { get; private set; default = SecureBootState.UNKNOWN; }
        public EncryptionState encryption { get; private set; default = EncryptionState.UNKNOWN; }
        public string encryption_method { get; private set; default = ""; }
        public string encryption_scope { get; private set; default = ""; }

        public DeviceSecurity(string root = "") {
            Object(root: root);
        }

        private string path(string p) {
            return root + p;
        }

        private string? read_text(string p) {
            try {
                string content;
                FileUtils.get_contents(path(p), out content);
                return content.strip();
            } catch (Error e) {
                return null;
            }
        }

        public void read_all(string? home = null) {
            read_tpm();
            read_secure_boot();
            read_encryption(home ?? Environment.get_home_dir());
        }

        public void read_tpm() {
            tpm_present = FileUtils.test(path("/sys/class/tpm/tpm0"), FileTest.EXISTS);
            tpm_version = "";
            if (!tpm_present) return;
            string? major = read_text("/sys/class/tpm/tpm0/tpm_version_major");
            if (major == "2") tpm_version = "2.0";
            else if (major == "1") tpm_version = "1.2";
            else if (FileUtils.test(path("/dev/tpmrm0"), FileTest.EXISTS)
                     || FileUtils.test(path("/sys/class/tpmrm/tpmrm0"), FileTest.EXISTS)) tpm_version = "2.0";
        }

        private int efi_flag(string variable) {
            uint8[] data;
            try {
                FileUtils.get_data(path("/sys/firmware/efi/efivars/%s-%s".printf(variable, EFI_GLOBAL)), out data);
            } catch (Error e) {
                return -1;
            }
            if (data.length < 5) return -1;
            return data[4];
        }

        public void read_secure_boot() {
            if (!FileUtils.test(path("/sys/firmware/efi"), FileTest.IS_DIR)) {
                secure_boot = SecureBootState.UNSUPPORTED;
                return;
            }
            int enabled = efi_flag("SecureBoot");
            int setup = efi_flag("SetupMode");
            if (enabled == 1) secure_boot = SecureBootState.ENABLED;
            else if (setup == 1) secure_boot = SecureBootState.SETUP_MODE;
            else if (enabled == 0) secure_boot = SecureBootState.DISABLED;
            else secure_boot = SecureBootState.UNKNOWN;
        }

        public void read_encryption(string home) {
            encryption = EncryptionState.UNKNOWN;
            encryption_method = "";
            encryption_scope = "";
            var mounts = read_mounts();
            if (mounts.size == 0) return;
            string? root_method = method_for(mounts, "/");
            string home_mount = mount_point_for(mounts, home);
            string? home_method = home_mount != "/" ? method_for(mounts, home_mount) : root_method;
            if (home_method == null && home_has_fscrypt(home)) home_method = "fscrypt";
            if (root_method != null) {
                encryption = EncryptionState.ENCRYPTED;
                encryption_method = root_method;
                encryption_scope = "system";
            } else if (home_method != null) {
                encryption = EncryptionState.ENCRYPTED;
                encryption_method = home_method;
                encryption_scope = "home";
            } else {
                encryption = EncryptionState.NOT_ENCRYPTED;
            }
        }

        private class Mount {
            public string point;
            public string device;
            public string fstype;
            public string source;
        }

        private Gee.ArrayList<Mount> read_mounts() {
            var list = new Gee.ArrayList<Mount>();
            string? content = read_text("/proc/self/mountinfo");
            if (content == null) return list;
            foreach (string line in content.split("\n")) {
                string[] halves = line.split(" - ");
                if (halves.length < 2) continue;
                string[] left = halves[0].split(" ");
                string[] right = halves[1].split(" ");
                if (left.length < 5 || right.length < 2) continue;
                var m = new Mount();
                m.device = left[2];
                m.point = left[4].replace("\\040", " ");
                m.fstype = right[0];
                m.source = right[1];
                list.add(m);
            }
            return list;
        }

        private string mount_point_for(Gee.ArrayList<Mount> mounts, string target) {
            string best = "/";
            foreach (var m in mounts) {
                if (m.point == "/") continue;
                if ((target == m.point || target.has_prefix(m.point + "/")) && m.point.length > best.length) best = m.point;
            }
            return best;
        }

        private string? method_for(Gee.ArrayList<Mount> mounts, string point) {
            Mount? found = null;
            foreach (var m in mounts) {
                if (m.point == point) found = m;
            }
            if (found == null) return null;
            if (found.fstype == "ecryptfs") return "eCryptfs";
            if (found.fstype == "fuse.gocryptfs") return "gocryptfs";
            string? method = block_method(found.device, 0);
            if (method == null && found.source.has_prefix("/dev/")) {
                string? device = device_for_source(found.source);
                if (device != null) method = block_method(device, 0);
            }
            return method;
        }

        private string? device_for_source(string source) {
            string name = Path.get_basename(source);
            string? direct = read_text("/sys/class/block/%s/dev".printf(name));
            if (direct != null) return direct;
            try {
                var dir = Dir.open(path("/sys/class/block"));
                string? entry;
                while ((entry = dir.read_name()) != null) {
                    if (read_text("/sys/class/block/%s/dm/name".printf(entry)) == name) {
                        return read_text("/sys/class/block/%s/dev".printf(entry));
                    }
                }
            } catch (FileError e) {
            }
            return null;
        }

        private string? block_method(string majmin, int depth) {
            if (depth > 8) return null;
            string base_dir = "/sys/dev/block/%s".printf(majmin);
            string? uuid = read_text(base_dir + "/dm/uuid");
            if (uuid != null && uuid.has_prefix("CRYPT-")) {
                if (uuid.has_prefix("CRYPT-LUKS")) return "LUKS";
                if (uuid.has_prefix("CRYPT-BITLK")) return "BitLocker";
                return "dm-crypt";
            }
            try {
                var dir = Dir.open(path(base_dir + "/slaves"));
                string? entry;
                while ((entry = dir.read_name()) != null) {
                    string? dev = read_text(base_dir + "/slaves/" + entry + "/dev");
                    if (dev == null) continue;
                    string? method = block_method(dev, depth + 1);
                    if (method != null) return method;
                }
            } catch (FileError e) {
            }
            return null;
        }

        private bool home_has_fscrypt(string home) {
            if (root != "") return false;
            int fd = Posix.open(home, Posix.O_RDONLY);
            if (fd < 0) return false;
            long flags = 0;
            int rc = Posix.ioctl(fd, (int) FS_IOC_GETFLAGS, &flags);
            Posix.close(fd);
            return rc == 0 && (flags & FS_ENCRYPT_FL) != 0;
        }
    }
}
