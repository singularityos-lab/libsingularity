namespace Singularity.Startup {

    public class Observer : Object {
        private const int64 STALL_US = 50000;
        private const int64 QUIET_US = 1500000;
        private const int64 LIMIT_US = 30000000;
        private const uint PROBE_MS = 4;
        private const uint SAMPLE_MS = 100;
        private const int USER_HZ = 100;

        private static Observer? instance = null;

        public bool enabled { get; private set; default = false; }
        public bool settled { get; private set; default = false; }

        private string? path = null;
        private string origin_kind = "construct";
        private int64 origin = 0;
        private int64 last_probe = 0;
        private int64 first_paint = -1;
        private int64 presented = -1;
        private int64 last_paint = -1;
        private int64 first_frame = -1;
        private int64 stall_total = 0;
        private int64 stall_max = 0;
        private int paints = 0;
        private int64 phase_mark = 0;
        private int64 layout_total = 0;
        private int64 layout_max = 0;
        private int64 paint_total = 0;
        private int64 paint_max = 0;
        private int64 first_layout = -1;
        private int64 first_render = -1;
        private uint probe_source = 0;
        private uint sample_source = 0;
        private int64[] cpu_window = {};
        private int64 cpu_at_last_change = 0;
        private Gdk.FrameClock? first_clock = null;
        private bool plan_pending = false;
        private Json.Node? plan_report = null;
        private Json.Builder events = new Json.Builder();
        private Json.Builder stalls = new Json.Builder();

        public signal void finished(string report);

        public static Observer get_default() {
            if (instance == null) instance = new Observer();
            return instance;
        }

        private Observer() {
            events.begin_array();
            stalls.begin_array();
            origin = GLib.get_monotonic_time();
            path = Environment.get_variable("SINGULARITY_STARTUP_TRACE");
            if (path == null || path == "") return;
            enabled = true;
            string? t0 = Environment.get_variable("SINGULARITY_STARTUP_T0");
            int64 launched = 0;
            if (t0 != null && int64.try_parse(t0, out launched) && launched > 0 && launched / 1000 <= origin) {
                origin = launched / 1000;
                origin_kind = "launch";
            }
            last_probe = GLib.get_monotonic_time();
            probe_source = Timeout.add_full(Priority.HIGH, PROBE_MS, probe);
            sample_source = Timeout.add(SAMPLE_MS, sample);
            mark("observer");
        }

        public int64 elapsed_us() {
            return GLib.get_monotonic_time() - origin;
        }

        public void mark(string name, string? detail = null) {
            if (!enabled || settled) return;
            events.begin_object();
            events.set_member_name("name");
            events.add_string_value(name);
            events.set_member_name("ms");
            events.add_double_value(elapsed_us() / 1000.0);
            if (detail != null) {
                events.set_member_name("detail");
                events.add_string_value(detail);
            }
            events.end_object();
        }

        internal void expect_plan() {
            plan_pending = true;
        }

        internal void attach(Boot boot) {
            plan_pending = false;
            if (!enabled || settled) return;
            plan_report = boot.report_node();
        }

        public void watch(Gtk.Application app) {
            if (!enabled) return;
            app.startup.connect(() => mark("startup-end"));
            app.activate.connect(() => mark("activate-begin"));
            app.activate.connect_after(() => mark("activate-end"));
            app.open.connect(() => mark("open-begin"));
            app.open.connect_after(() => mark("open-end"));
            foreach (var w in app.get_windows()) watch_window(w);
            app.window_added.connect(watch_window);
        }

        private void watch_window(Gtk.Window window) {
            if (settled) return;
            mark("window-added", window.get_type().name());
            if (window.get_realized()) watch_clock(window);
            else ((Gtk.Widget) window).realize.connect(() => watch_clock(window));
            ((Gtk.Widget) window).map.connect(() => mark("window-mapped", window.get_type().name()));
        }

        private void watch_clock(Gtk.Window window) {
            var clock = window.get_frame_clock();
            if (clock == null) return;
            clock.before_paint.connect_after(() => phase_mark = get_monotonic_time());
            clock.update.connect_after(() => phase_mark = get_monotonic_time());
            clock.layout.connect_after(() => {
                if (settled) return;
                int64 now = get_monotonic_time();
                int64 spent = now - phase_mark;
                layout_total += spent;
                if (spent > layout_max) layout_max = spent;
                if (first_layout < 0) first_layout = spent;
                phase_mark = now;
            });
            clock.paint.connect_after(() => {
                if (settled) return;
                int64 now = get_monotonic_time();
                int64 spent = now - phase_mark;
                paint_total += spent;
                if (spent > paint_max) paint_max = spent;
                if (first_render < 0) first_render = spent;
                phase_mark = now;
            });
            clock.after_paint.connect(() => painted(clock));
        }

        private void painted(Gdk.FrameClock clock) {
            if (settled) return;
            int64 now = elapsed_us();
            paints++;
            last_paint = now;
            if (first_paint < 0) {
                first_paint = now;
                first_frame = clock.get_frame_counter();
                first_clock = clock;
                mark("first-paint");
            }
            if (presented < 0 && first_clock != null) {
                var timings = first_clock.get_timings(first_frame);
                if (timings != null && timings.get_complete() && timings.get_presentation_time() > 0) {
                    presented = timings.get_presentation_time() - origin;
                    mark("first-presented");
                }
            }
        }

        private bool probe() {
            int64 now = GLib.get_monotonic_time();
            int64 gap = now - last_probe - PROBE_MS * 1000;
            last_probe = now;
            if (gap >= STALL_US) {
                stall_total += gap;
                if (gap > stall_max) stall_max = gap;
                stalls.begin_object();
                stalls.set_member_name("at_ms");
                stalls.add_double_value((now - gap - origin) / 1000.0);
                stalls.set_member_name("ms");
                stalls.add_double_value(gap / 1000.0);
                stalls.end_object();
            }
            return Source.CONTINUE;
        }

        private bool sample() {
            int64 now = elapsed_us();
            int64 cpu = cpu_us();
            cpu_window += cpu;
            int quiet_samples = (int) (QUIET_US / (SAMPLE_MS * 1000));
            if (cpu_window.length > quiet_samples) cpu_window = cpu_window[cpu_window.length - quiet_samples - 1 : cpu_window.length];
            bool idle_cpu = cpu_window.length > quiet_samples && cpu_window[cpu_window.length - 1] - cpu_window[0] < QUIET_US / 20;
            if (!idle_cpu) cpu_at_last_change = now;
            bool quiet_paint = last_paint >= 0 && now - last_paint >= QUIET_US;
            if ((quiet_paint && idle_cpu && !plan_pending) || now >= LIMIT_US) finish(now >= LIMIT_US);
            return settled ? Source.REMOVE : Source.CONTINUE;
        }

        private static int64 cpu_us() {
            try {
                string stat;
                FileUtils.get_contents("/proc/self/stat", out stat);
                var fields = stat.substring(stat.last_index_of(")") + 2).split(" ");
                return (int64.parse(fields[11]) + int64.parse(fields[12])) * 1000000 / USER_HZ;
            } catch (Error e) {
                return 0;
            }
        }

        private static int64 peak_rss_kb() {
            try {
                string status;
                FileUtils.get_contents("/proc/self/status", out status);
                foreach (var line in status.split("\n")) {
                    if (line.has_prefix("VmHWM:")) return int64.parse(line.substring(6).strip().split(" ")[0]);
                }
            } catch (Error e) {
            }
            return 0;
        }

        private void finish(bool limit) {
            if (settled) return;
            mark("settled");
            settled = true;
            if (probe_source != 0) Source.remove(probe_source);
            probe_source = 0;
            events.end_array();
            stalls.end_array();
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("app");
            b.add_string_value(GLib.Application.get_default() != null ? GLib.Application.get_default().application_id ?? "" : "");
            b.set_member_name("origin");
            b.add_string_value(origin_kind);
            b.set_member_name("first_paint_ms");
            b.add_double_value(first_paint / 1000.0);
            b.set_member_name("first_presented_ms");
            b.add_double_value(presented / 1000.0);
            b.set_member_name("last_paint_ms");
            b.add_double_value(last_paint / 1000.0);
            b.set_member_name("cpu_quiet_ms");
            b.add_double_value(cpu_at_last_change / 1000.0);
            b.set_member_name("paints");
            b.add_int_value(paints);
            b.set_member_name("layout_total_ms");
            b.add_double_value(layout_total / 1000.0);
            b.set_member_name("layout_max_ms");
            b.add_double_value(layout_max / 1000.0);
            b.set_member_name("first_layout_ms");
            b.add_double_value(first_layout / 1000.0);
            b.set_member_name("render_total_ms");
            b.add_double_value(paint_total / 1000.0);
            b.set_member_name("render_max_ms");
            b.add_double_value(paint_max / 1000.0);
            b.set_member_name("first_render_ms");
            b.add_double_value(first_render / 1000.0);
            b.set_member_name("cpu_ms");
            b.add_double_value(cpu_us() / 1000.0);
            b.set_member_name("peak_rss_kb");
            b.add_int_value(peak_rss_kb());
            b.set_member_name("stall_total_ms");
            b.add_double_value(stall_total / 1000.0);
            b.set_member_name("stall_max_ms");
            b.add_double_value(stall_max / 1000.0);
            b.set_member_name("hit_limit");
            b.add_boolean_value(limit);
            if (plan_report != null) {
                b.set_member_name("plan");
                b.add_value(plan_report);
            }
            b.set_member_name("events");
            b.add_value(events.get_root());
            b.set_member_name("stalls");
            b.add_value(stalls.get_root());
            b.end_object();
            var gen = new Json.Generator();
            gen.set_root(b.get_root());
            string report = gen.to_data(null);
            try {
                var stream = File.new_for_path(path).append_to(FileCreateFlags.NONE);
                stream.write_all((report + "\n").data, null);
                stream.close();
            } catch (Error e) {
                warning("startup trace: %s", e.message);
            }
            finished(report);
        }
    }
}
