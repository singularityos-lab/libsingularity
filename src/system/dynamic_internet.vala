namespace Singularity {

    public enum InternetUplinkKind {
        ETHERNET,
        WIFI,
        MOBILE,
        OTHER
    }

    public class InternetUplink : Object {
        public string id { get; construct; }
        public string interface_name { get; construct; }
        public string display_name { get; construct; }
        public InternetUplinkKind kind { get; construct; }
        public bool primary { get; set; }
        public bool reachable { get; set; }
        public bool captive { get; set; }
        public bool metered { get; set; }
        public int latency_ms { get; set; default = -1; }
        public int loss_percent { get; set; default = 100; }
        public int score { get; set; }

        internal int successes { get; set; }
        internal int failures { get; set; }

        public InternetUplink(string id, string interface_name, string display_name,
                              InternetUplinkKind kind) {
            Object(id: id, interface_name: interface_name,
                display_name: display_name, kind: kind);
        }
    }

    public interface DynamicInternetBackend : Object {
        public abstract string name { owned get; }
        public signal void changed();
        public abstract async Gee.List<InternetUplink> probe(Cancellable? cancellable)
            throws Error;
        public abstract async void prefer(string uplink_id, Cancellable? cancellable)
            throws Error;
        public abstract async void reset(Cancellable? cancellable) throws Error;
    }

    public class DynamicInternetPolicy : Object {
        public const int HARD_FAILURES = 2;
        public const int HEALTHY_SAMPLES = 3;
        public const int SWITCH_MARGIN = 80;
        public const int64 MIN_DWELL_USEC = 20 * TimeSpan.SECOND;

        public static int score(InternetUplink uplink) {
            if (!uplink.reachable || uplink.captive) return -1000;
            int value = 1000 - uplink.loss_percent * 4;
            if (uplink.latency_ms >= 0) value -= int.min(500, uplink.latency_ms * 2);
            if (uplink.metered) value -= 200;
            return value;
        }

        public static bool should_switch(InternetUplink current, InternetUplink candidate,
                                         int64 last_switch_at, int64 now) {
            if (candidate.id == current.id || !candidate.reachable || candidate.captive)
                return false;
            if (current.failures >= HARD_FAILURES && candidate.successes >= 1)
                return true;
            return candidate.successes >= HEALTHY_SAMPLES
                && candidate.score >= current.score + SWITCH_MARGIN
                && now - last_switch_at >= MIN_DWELL_USEC;
        }
    }

    public class DynamicInternetManager : Object {
        private const uint PROBE_SECONDS = 3;

        public bool enabled { get; private set; default = false; }
        public string backend_name { get; private set; default = ""; }
        public string preferred_id { get; private set; default = ""; }
        public string status { get; private set; default = "Off"; }
        public string last_error { get; private set; default = ""; }
        public bool has_backend { get { return backend != null; } }

        public signal void changed();

        private DynamicInternetBackend? backend;
        private Gee.ArrayList<InternetUplink> uplinks = new Gee.ArrayList<InternetUplink>();
        private HashTable<string, InternetUplink> history =
            new HashTable<string, InternetUplink>(str_hash, str_equal);
        private uint probe_source;
        private ulong backend_changed_id;
        private bool probing;
        private bool switching;
        private int64 last_switch_at;
        private Cancellable? cancellable;
        private Cancellable? switch_cancellable;

        public void set_backend(DynamicInternetBackend value) {
            if (backend == value) return;
            stop_timer();
            if (backend != null && backend_changed_id != 0)
                backend.disconnect(backend_changed_id);
            backend = value;
            backend_name = value.name;
            backend_changed_id = value.changed.connect(on_backend_changed);
            if (enabled) start();
            changed();
        }

        public void set_fallback_backend(DynamicInternetBackend value) {
            if (backend == null) set_backend(value);
        }

        public void set_active(bool value) {
            if (enabled == value) return;
            enabled = value;
            last_error = "";
            if (enabled) {
                start();
            } else {
                stop_timer();
                preferred_id = "";
                status = "Off";
                if (switching && switch_cancellable != null)
                    switch_cancellable.cancel();
                else if (backend != null)
                    reset_backend.begin(backend);
                changed();
            }
        }

        public Gee.List<InternetUplink> get_uplinks() {
            return uplinks.read_only_view;
        }

        public void refresh() {
            if (enabled) probe.begin();
        }

        private void start() {
            if (backend == null) {
                status = "Waiting for a network backend";
                changed();
                return;
            }
            status = "Checking connections";
            probe.begin();
            if (probe_source == 0) {
                probe_source = Timeout.add_seconds(PROBE_SECONDS, () => {
                    probe.begin();
                    return Source.CONTINUE;
                });
            }
            changed();
        }

        private void stop_timer() {
            if (probe_source != 0) {
                Source.remove(probe_source);
                probe_source = 0;
            }
            if (cancellable != null) cancellable.cancel();
            cancellable = null;
            probing = false;
        }

        private void on_backend_changed() {
            if (enabled) probe.begin();
        }

        private async void reset_backend(DynamicInternetBackend value) {
            try {
                yield value.reset(null);
            } catch (Error e) {
                last_error = e.message;
                changed();
            }
        }

        private async void probe() {
            if (!enabled || backend == null || probing || switching) return;
            probing = true;
            cancellable = new Cancellable();
            try {
                var observations = yield backend.probe(cancellable);
                if (!enabled) return;
                update_observations(observations);
                choose_preferred();
                last_error = "";
            } catch (IOError.CANCELLED e) {
            } catch (Error e) {
                last_error = e.message;
                status = "Could not check connections";
                changed();
            } finally {
                probing = false;
                cancellable = null;
            }
        }

        private void update_observations(Gee.List<InternetUplink> observations) {
            var next = new Gee.ArrayList<InternetUplink>();
            foreach (var observed in observations) {
                var previous = history[observed.id];
                if (previous != null) {
                    observed.successes = observed.reachable ? previous.successes + 1 : 0;
                    observed.failures = observed.reachable ? 0 : previous.failures + 1;
                    if (observed.latency_ms >= 0 && previous.latency_ms >= 0)
                        observed.latency_ms = (previous.latency_ms * 3 + observed.latency_ms) / 4;
                    observed.loss_percent = observed.reachable
                        ? (previous.loss_percent * 3) / 4
                        : int.min(100, previous.loss_percent + 25);
                } else {
                    observed.successes = observed.reachable ? 1 : 0;
                    observed.failures = observed.reachable ? 0 : 1;
                    observed.loss_percent = observed.reachable ? 0 : 100;
                }
                observed.score = DynamicInternetPolicy.score(observed);
                history[observed.id] = observed;
                next.add(observed);
                if (observed.primary) preferred_id = observed.id;
            }
            uplinks = next;
            changed();
        }

        private void choose_preferred() {
            InternetUplink? current = null;
            InternetUplink? best = null;
            foreach (var uplink in uplinks) {
                if (uplink.primary) current = uplink;
                if (uplink.captive || !uplink.reachable) continue;
                if (best == null || uplink.score > best.score) best = uplink;
            }

            if (best == null) {
                status = uplinks.size == 0 ? "No active connections" : "No connection has internet access";
                changed();
                return;
            }

            if (current == null) {
                if (best.successes >= 1) switch_to.begin(best);
                return;
            }

            preferred_id = current.id;
            status = describe(current);
            if (DynamicInternetPolicy.should_switch(current, best, last_switch_at,
                    get_monotonic_time())) {
                switch_to.begin(best);
            } else {
                changed();
            }
        }

        private async void switch_to(InternetUplink uplink) {
            if (!enabled || backend == null || switching) return;
            switching = true;
            var active_backend = backend;
            switch_cancellable = new Cancellable();
            status = "Switching to %s".printf(uplink.display_name);
            changed();
            try {
                yield active_backend.prefer(uplink.id, switch_cancellable);
                preferred_id = uplink.id;
                last_switch_at = get_monotonic_time();
                status = describe(uplink);
                last_error = "";
            } catch (IOError.CANCELLED e) {
            } catch (Error e) {
                last_error = e.message;
                status = "Could not switch connections";
            }
            switching = false;
            switch_cancellable = null;
            if (!enabled) yield reset_backend(active_backend);
            changed();
        }

        private static string describe(InternetUplink uplink) {
            if (uplink.latency_ms >= 0)
                return "%s, %d ms".printf(uplink.display_name, uplink.latency_ms);
            return uplink.display_name;
        }
    }
}
