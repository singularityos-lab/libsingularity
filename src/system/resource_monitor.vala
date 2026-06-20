using GLib;

namespace Singularity {

    public class ResourceMonitor : Object {
        private uint _timer_id = 0;
        private uint _cooldown_id = 0;
        private bool _mem_alert_active = false;
        private bool _cpu_alert_active = false;

        private const int CHECK_INTERVAL_SEC = 5;
        private const int COOLDOWN_SEC = 120;

        private const double MEM_WARNING_PCT = 0.85;
        private const double MEM_CRITICAL_PCT = 0.95;
        private const double CPU_SPIKE_PCT = 90.0;

        private int64 _prev_idle = 0;
        private int64 _prev_total = 0;

        public ResourceMonitor() {}

        public void start() {
            if (_timer_id != 0) return;
            _prev_idle = 0;
            _prev_total = 0;
            _timer_id = Timeout.add_seconds(CHECK_INTERVAL_SEC, check_resources);
            check_resources();
        }

        public void stop() {
            if (_timer_id != 0) {
                Source.remove(_timer_id);
                _timer_id = 0;
            }
        }

        private bool check_resources() {
            check_memory();
            check_cpu();
            return Source.CONTINUE;
        }

        private void check_memory() {
            int64 mem_total = 0;
            int64 mem_available = 0;
            var f = FileStream.open("/proc/meminfo", "r");
            if (f == null) return;
            string? line;
            while ((line = f.read_line()) != null) {
                if (line.has_prefix("MemTotal:")) {
                    mem_total = parse_kb(line);
                } else if (line.has_prefix("MemAvailable:")) {
                    mem_available = parse_kb(line);
                }
                if (mem_total > 0 && mem_available > 0) break;
            }
            if (mem_total == 0) return;
            double used_pct = 1.0 - (double)mem_available / (double)mem_total;
            if (used_pct >= MEM_CRITICAL_PCT && !_mem_alert_active) {
                _mem_alert_active = true;
                send_alert("Critical Memory Usage",
                    "Memory at %.0f%% used. Applications may become unstable.".printf(used_pct * 100),
                    "dialog-warning");
                start_mem_cooldown();
            } else if (used_pct >= MEM_WARNING_PCT && !_mem_alert_active) {
                _mem_alert_active = true;
                send_alert("High Memory Usage",
                    "Memory at %.0f%% used. Consider closing unused applications.".printf(used_pct * 100),
                    "dialog-information");
                start_mem_cooldown();
            }
        }

        private void check_cpu() {
            int64 idle = 0, total = 0;
            var f = FileStream.open("/proc/stat", "r");
            if (f == null) return;
            string? line = f.read_line();
            if (line == null || !line.has_prefix("cpu ")) return;
            // The aggregate "cpu" line is padded with TWO spaces, so a plain
            // split(" ") yields an empty token that shifts every field by
            // one (idle ends up holding `system`, wildly inflating the
            // computed load). Collect non-empty numeric tokens instead, and
            // sum ALL of them for the true total (idle = idle + iowait).
            int64[] vals = {};
            foreach (var p in line.split(" ")) {
                if (p == "" || p == "cpu") continue;
                vals += int64.parse(p);
            }
            // Fields: user nice system idle iowait irq softirq steal ...
            if (vals.length < 5) return;
            idle = vals[3] + vals[4]; // idle + iowait counts as not-busy
            total = 0;
            foreach (var v in vals) total += v;
            if (_prev_total == 0) {
                _prev_idle = idle;
                _prev_total = total;
                return;
            }
            int64 d_idle = idle - _prev_idle;
            int64 d_total = total - _prev_total;
            _prev_idle = idle;
            _prev_total = total;
            if (d_total == 0) return;
            double cpu_pct = ((double)(d_total - d_idle) / (double)d_total) * 100.0;
            cpu_pct = cpu_pct.clamp(0.0, 100.0);

            // Require the spike to persist across two consecutive samples
            // (~10s) before alerting - a single 100% blip from a build or
            // app launch shouldn't page the user.
            if (cpu_pct >= CPU_SPIKE_PCT) _cpu_spike_streak++;
            else _cpu_spike_streak = 0;

            if (_cpu_spike_streak >= 2 && !_cpu_alert_active) {
                _cpu_alert_active = true;
                send_alert("High CPU Usage",
                    "CPU at %.0f%%. This may indicate a runaway process.".printf(cpu_pct),
                    "dialog-information");
                start_cpu_cooldown();
            }
        }
        private int _cpu_spike_streak = 0;

        public signal void alert(string summary, string body, string icon);

        private void send_alert(string summary, string body, string icon) {
            alert(summary, body, icon);
        }

        private void start_mem_cooldown() {
            if (_cooldown_id != 0) Source.remove(_cooldown_id);
            _cooldown_id = Timeout.add_seconds(COOLDOWN_SEC, () => {
                _cooldown_id = 0;
                _mem_alert_active = false;
                return Source.REMOVE;
            });
        }

        private void start_cpu_cooldown() {
            if (_cpu_cooldown_id != 0) Source.remove(_cpu_cooldown_id);
            _cpu_cooldown_id = Timeout.add_seconds(COOLDOWN_SEC, () => {
                _cpu_cooldown_id = 0;
                _cpu_alert_active = false;
                return Source.REMOVE;
            });
        }

        private uint _cpu_cooldown_id = 0;

        private static int64 parse_kb(string line) {
            string[] parts = line.split(" ", 0);
            for (int i = 1; i < parts.length; i++) {
                if (parts[i].length > 0) return int64.parse(parts[i]);
            }
            return 0;
        }
    }
}