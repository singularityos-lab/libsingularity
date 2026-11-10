namespace Singularity {

    /**
     * Per process GPU usage read from DRM fdinfo.
     *
     * Every DRM client exposes cumulative busy time per engine and its
     * memory in /proc/<pid>/fdinfo. A client shared by several file
     * descriptors or processes is counted once, for the lowest pid that
     * holds it. Usage is the busiest engine's share of the sampling
     * interval. Works with drivers that implement DRM fdinfo (i915, xe,
     * amdgpu, nouveau, msm, panfrost, v3d and others).
     */
    public class ProcessGpuUsage : Object {
        public struct Client {
            public string key;
            public Gee.HashMap<string, uint64?> engines;
            public Gee.HashMap<string, uint64?> capacity;
            public uint64 memory;
        }

        private Gee.HashMap<string, uint64?> previous = new Gee.HashMap<string, uint64?>();
        private int64 previous_time = 0;
        private Gee.HashMap<int, double?> busy_by_pid = new Gee.HashMap<int, double?>();
        private Gee.HashMap<int, uint64?> memory_by_pid = new Gee.HashMap<int, uint64?>();
        private DrmFdIndex index = new DrmFdIndex();

        public string proc_root { get; set; default = "/proc"; }

        public double busy(int pid) {
            return busy_by_pid.has_key(pid) ? busy_by_pid.get(pid) : 0;
        }

        public uint64 memory(int pid) {
            return memory_by_pid.has_key(pid) ? memory_by_pid.get(pid) : 0;
        }

        public bool has_clients() {
            return memory_by_pid.size > 0 || busy_by_pid.size > 0;
        }

        public static bool parse_fdinfo(string text, out Client client) {
            client = Client();
            client.engines = new Gee.HashMap<string, uint64?>();
            client.capacity = new Gee.HashMap<string, uint64?>();
            client.memory = 0;
            string pdev = "";
            string id = "";
            uint64 resident = 0;
            uint64 legacy = 0;
            foreach (string line in text.split("\n")) {
                int colon = line.index_of(":");
                if (colon <= 0) continue;
                string name = line.substring(0, colon).strip();
                string value = line.substring(colon + 1).strip();
                if (name == "drm-pdev") {
                    pdev = value;
                } else if (name == "drm-client-id") {
                    id = value;
                } else if (name.has_prefix("drm-engine-capacity-")) {
                    client.capacity.set(name.substring(20), uint64.parse(value));
                } else if (name.has_prefix("drm-engine-")) {
                    client.engines.set(name.substring(11), uint64.parse(value.split(" ")[0]));
                } else if (name.has_prefix("drm-resident-")) {
                    resident += bytes(value);
                } else if (name == "drm-memory-vram" || name == "drm-memory-gtt") {
                    legacy += bytes(value);
                }
            }
            if (id == "") return false;
            client.key = pdev + "/" + id;
            client.memory = resident > 0 ? resident : legacy;
            return true;
        }

        private static uint64 bytes(string value) {
            string[] parts = value.split(" ");
            uint64 number = uint64.parse(parts[0]);
            if (parts.length < 2) return number;
            switch (parts[1]) {
                case "KiB": return number * 1024;
                case "MiB": return number * 1024 * 1024;
                case "GiB": return number * 1024 * 1024 * 1024;
                default: return number;
            }
        }

        public void sample() {
            int64 now = get_monotonic_time() * 1000;
            int64 elapsed = previous_time > 0 ? now - previous_time : 0;
            var seen = new Gee.HashMap<string, int>();
            var clients = new Gee.HashMap<string, Client?>();
            try {
                var dir = Dir.open(proc_root);
                string? entry;
                var pids = new Gee.ArrayList<int>();
                while ((entry = dir.read_name()) != null) {
                    if (entry[0].isdigit()) pids.add(int.parse(entry));
                }
                pids.sort((a, b) => a - b);
                index.begin();
                foreach (int pid in pids) collect(pid, seen, clients);
                index.finish();
            } catch (FileError e) {
                return;
            }

            var busy_now = new Gee.HashMap<int, double?>();
            var memory_now = new Gee.HashMap<int, uint64?>();
            var current = new Gee.HashMap<string, uint64?>();
            foreach (var entry in clients.entries) {
                string key = entry.key;
                Client client = entry.value;
                int pid = seen.get(key);
                uint64 total = memory_now.has_key(pid) ? memory_now.get(pid) : 0;
                memory_now.set(pid, total + client.memory);
                double peak = 0;
                foreach (var engine in client.engines.entries) {
                    string engine_key = key + "/" + engine.key;
                    uint64 ns = engine.value;
                    current.set(engine_key, ns);
                    if (!previous.has_key(engine_key) || elapsed <= 0) continue;
                    uint64 before = previous.get(engine_key);
                    if (ns < before) continue;
                    uint64 capacity = client.capacity.has_key(engine.key) ? client.capacity.get(engine.key) : 1;
                    double share = (double) (ns - before) / (double) elapsed / (double) uint64.max(capacity, 1);
                    peak = double.max(peak, share);
                }
                double sum = busy_now.has_key(pid) ? busy_now.get(pid) : 0;
                busy_now.set(pid, double.min(sum + peak * 100.0, 100.0));
            }
            previous = current;
            previous_time = now;
            busy_by_pid = busy_now;
            memory_by_pid = memory_now;
        }

        private void collect(int pid, Gee.HashMap<string, int> seen, Gee.HashMap<string, Client?> clients) {
            string[]? drm = index.lookup(Path.build_filename(proc_root, pid.to_string(), "fd"), pid.to_string());
            if (drm == null) return;
            foreach (string drm_fd in drm) {
                string text;
                try {
                    FileUtils.get_contents(Path.build_filename(proc_root, pid.to_string(), "fdinfo", drm_fd), out text);
                } catch (FileError e) {
                    continue;
                }
                Client client;
                if (!parse_fdinfo(text, out client) || seen.has_key(client.key)) continue;
                seen.set(client.key, pid);
                clients.set(client.key, client);
            }
        }
    }

    internal class DrmFdIndex {
        private const uint FULL_SCAN_EVERY = 6;
        private const uint IDLE_SCAN_EVERY = 30;
        private Gee.HashMap<string, FdScan> scans = new Gee.HashMap<string, FdScan>();
        private Gee.HashMap<string, FdScan> live = new Gee.HashMap<string, FdScan>();

        private class FdScan {
            public uint count;
            public uint64 sum;
            public uint reused;
            public string[] drm = {};
        }

        public void begin() {
            live = new Gee.HashMap<string, FdScan>();
        }

        public void finish() {
            scans = live;
        }

        public string[]? lookup(string fd_path, string key) {
            FdScan? idle = scans.get(key);
            if (idle != null && idle.drm.length == 0 && idle.reused < IDLE_SCAN_EVERY) {
                idle.reused++;
                live.set(key, idle);
                return idle.drm;
            }
            Dir fds;
            try {
                fds = Dir.open(fd_path);
            } catch (FileError e) {
                return null;
            }
            var scan = new FdScan();
            string? fd;
            while ((fd = fds.read_name()) != null) {
                scan.count++;
                scan.sum += uint64.parse(fd);
            }
            FdScan? cached = scans.get(key);
            if (cached != null && cached.reused < FULL_SCAN_EVERY && cached.count == scan.count
                    && cached.sum == scan.sum && all_drm(fd_path, cached.drm)) {
                scan.drm = cached.drm;
                scan.reused = cached.reused + 1;
            } else {
                fds.rewind();
                while ((fd = fds.read_name()) != null) {
                    if (is_drm(fd_path, fd)) scan.drm += fd;
                }
            }
            if (cached == null && scan.drm.length == 0) scan.reused = key.hash() % IDLE_SCAN_EVERY;
            live.set(key, scan);
            return scan.drm;
        }

        private static bool is_drm(string fd_path, string fd) {
            try {
                return FileUtils.read_link(Path.build_filename(fd_path, fd)).has_prefix("/dev/dri/");
            } catch (FileError e) {
                return false;
            }
        }

        private static bool all_drm(string fd_path, string[] fds) {
            foreach (string fd in fds) {
                if (!is_drm(fd_path, fd)) return false;
            }
            return true;
        }
    }

    /**
     * Per process network throughput from the kernel's TCP counters.
     *
     * Reads the byte counters of every TCP socket from sock_diag through
     * the system core, together with the process holding it, without extra
     * privileges for the user's own processes. Rates are the growth of those
     * counters between samples. UDP traffic has no per socket counters and
     * is not included.
     */
    public class ProcessNetworkUsage : Object {
        public struct Socket {
            public string key;
            public int pid;
            public uint64 sent;
            public uint64 received;
        }

        private Gee.HashMap<string, Socket?> previous = new Gee.HashMap<string, Socket?>();
        private int64 previous_time = 0;
        private Gee.HashMap<int, double?> sent_by_pid = new Gee.HashMap<int, double?>();
        private Gee.HashMap<int, double?> received_by_pid = new Gee.HashMap<int, double?>();
        private bool busy = false;

        public signal void updated();

        public double sent_rate(int pid) {
            return sent_by_pid.has_key(pid) ? sent_by_pid.get(pid) : 0;
        }

        public double received_rate(int pid) {
            return received_by_pid.has_key(pid) ? received_by_pid.get(pid) : 0;
        }

        [Version (deprecated = true, replacement = "ProcessNetworkUsage.collect")]
        public static Socket[] parse(string output) {
            Socket[] sockets = {};
            string[] lines = output.split("\n");
            for (int i = 0; i < lines.length; i++) {
                string line = lines[i];
                if (line == "" || line[0] == ' ' || line[0] == '\t') continue;
                string[] fields = {};
                foreach (string part in line.split(" ")) {
                    if (part != "") fields += part;
                }
                if (fields.length < 5) continue;
                int pid = pid_of(line);
                if (pid <= 0) continue;
                Socket socket = Socket();
                socket.key = fields[3] + " " + fields[4];
                socket.pid = pid;
                if (i + 1 < lines.length && lines[i + 1].length > 0
                        && (lines[i + 1][0] == ' ' || lines[i + 1][0] == '\t')) {
                    socket.sent = counter(lines[i + 1], "bytes_sent:");
                    socket.received = counter(lines[i + 1], "bytes_received:");
                    i++;
                }
                sockets += socket;
            }
            return sockets;
        }

        private static int pid_of(string line) {
            int index = line.index_of("pid=");
            if (index < 0) return 0;
            return int.parse(line.substring(index + 4));
        }

        private static uint64 counter(string line, string name) {
            int index = line.index_of(name);
            if (index < 0) return 0;
            return uint64.parse(line.substring(index + name.length));
        }

        public static Socket[] collect() {
            Socket[] sockets = {};
            SintySystem.SocketList list;
            if (SintySystem.proc_sockets(SintySystem.SocketFlags.TCP, out list) != 0) return sockets;
            for (size_t i = 0; i < list.count(); i++) {
                unowned SintySystem.Socket? s = list.at(i);
                if (s.pid <= 0) continue;
                Socket socket = Socket();
                socket.key = "%s:%u %s:%u".printf((string) s.local, s.local_port, (string) s.remote, s.remote_port);
                socket.pid = s.pid;
                socket.sent = s.bytes_sent;
                socket.received = s.bytes_received;
                sockets += socket;
            }
            return sockets;
        }

        public void sample() {
            if (busy) return;
            busy = true;
            new Thread<bool>("network-usage", () => {
                var sockets = collect();
                Idle.add(() => {
                    busy = false;
                    apply(sockets);
                    return Source.REMOVE;
                });
                return true;
            });
        }

        public void apply(Socket[] sockets) {
            int64 now = get_monotonic_time();
            double seconds = previous_time > 0 ? (now - previous_time) / 1000000.0 : 0;
            var sent = new Gee.HashMap<int, double?>();
            var received = new Gee.HashMap<int, double?>();
            var current = new Gee.HashMap<string, Socket?>();
            foreach (var socket in sockets) {
                current.set(socket.key, socket);
                if (!previous.has_key(socket.key) || seconds <= 0) continue;
                Socket before = previous.get(socket.key);
                if (socket.sent >= before.sent) {
                    double total = sent.has_key(socket.pid) ? sent.get(socket.pid) : 0;
                    sent.set(socket.pid, total + (socket.sent - before.sent) / seconds);
                }
                if (socket.received >= before.received) {
                    double total = received.has_key(socket.pid) ? received.get(socket.pid) : 0;
                    received.set(socket.pid, total + (socket.received - before.received) / seconds);
                }
            }
            previous = current;
            previous_time = now;
            sent_by_pid = sent;
            received_by_pid = received;
            updated();
        }
    }
}
