namespace Singularity {

    public class SealedLog : Object {
        public const string DEFAULT_SOCKET = "/run/sealedlog/socket";
        public const string DEFAULT_DICTIONARY = "/usr/share/sealedlog/components";
        private const uint8 CODE_LOCAL = 32;
        private const int MAX_ARGS = 3;

        public string component { get; private set; }
        private uint8 number;
        private string family;
        private string socket_path;

        private SealedLog (string component, uint8 number, string family, string socket_path) {
            this.component = component;
            this.number = number;
            this.family = family;
            this.socket_path = socket_path;
        }

        public static SealedLog? open (string component) {
            return open_at (component, DEFAULT_DICTIONARY, DEFAULT_SOCKET);
        }

        public static SealedLog? open_at (string component, string dictionary, string socket_path) {
            uint8 number;
            string family;
            if (!builtin (component, out number, out family) && !lookup (dictionary, component, out number, out family)) {
                return null;
            }
            return new SealedLog (component, number, family, socket_path);
        }

        public bool log (string event, uint64[] args = {}) {
            int code = code_of (event);
            if (code < 0) {
                return false;
            }
            var record = new ByteArray ();
            int count = int.min (args.length, MAX_ARGS);
            record.append ({ number, (uint8) code, (uint8) count });
            append_uvarint (record, 0);
            for (int i = 0; i < count; i++) {
                append_uvarint (record, args[i]);
            }
            try {
                var socket = new Socket (SocketFamily.UNIX, SocketType.DATAGRAM, SocketProtocol.DEFAULT);
                socket.send_to (new UnixSocketAddress (socket_path), record.data);
                socket.close ();
                return true;
            } catch (Error e) {
                return false;
            }
        }

        public int code_of (string event) {
            string[] shared = { "", "start", "ready", "stop", "fail", "crash", "restart", "timeout", "denied", "warn" };
            for (int i = 1; i < shared.length; i++) {
                if (shared[i] == event) {
                    return i;
                }
            }
            string[] local = family_events (family);
            for (int i = 0; i < local.length; i++) {
                if (local[i] == event) {
                    return CODE_LOCAL + i;
                }
            }
            return -1;
        }

        private static string[] family_events (string family) {
            switch (family) {
                case "loader":
                    return { "boot-start", "slot-chosen", "trial", "signature-bad", "rollback-refused", "slot-missing",
                             "chainload", "chainload-fail", "fallback", "halted", "recovery", "chooser", "measured", "unlock-armed" };
                case "kernel":
                    return { "stage", "root-mounted", "init-started", "init-exit", "panic", "oops", "watchdog",
                             "suspend", "resume", "thermal", "tpm-launch", "driver-fail" };
                case "init":
                    return { "target", "unit-fail", "unit-restart", "shutdown" };
                case "ota":
                    return { "staged", "promoted", "rollback", "healthy", "download-fail", "verify-fail", "reboot",
                             "live-applied", "live-rollback" };
                case "session":
                    return { "login", "login-fail", "logout", "lock", "app-crash", "first-frame", "disk-error",
                             "battery-critical" };
                case "boot":
                    return { "diagnosis", "data-check", "data-repair" };
                default:
                    return {};
            }
        }

        private static bool builtin (string component, out uint8 number, out string family) {
            switch (component) {
                case "loader": number = 1; family = "loader"; return true;
                case "kernel-linux": number = 2; family = "kernel"; return true;
                case "kernel-early": number = 3; family = "kernel"; return true;
                case "atom-init": number = 5; family = "boot"; return true;
                case "atomd": number = 6; family = "ota"; return true;
                case "updated": number = 7; family = "ota"; return true;
                case "sealedlogd": number = 21; family = "-"; return true;
                default: number = 0; family = "-"; return false;
            }
        }

        private static bool lookup (string dictionary, string component, out uint8 number, out string family) {
            number = 0;
            family = "-";
            string text;
            try {
                FileUtils.get_contents (dictionary, out text);
            } catch (FileError e) {
                return false;
            }
            foreach (unowned string line in text.split ("\n")) {
                string[] fields = Regex.split_simple ("\\s+", line.strip ());
                if (fields.length < 3 || fields[0].has_prefix ("#") || fields[1] != component) {
                    continue;
                }
                uint64 value;
                if (!uint64.try_parse (fields[0], out value) || value == 0 || value > 255) {
                    return false;
                }
                number = (uint8) value;
                family = fields[2];
                return true;
            }
            return false;
        }

        private static void append_uvarint (ByteArray buffer, uint64 value) {
            while (value >= 0x80) {
                buffer.append ({ (uint8) (value | 0x80) });
                value >>= 7;
            }
            buffer.append ({ (uint8) value });
        }
    }
}
