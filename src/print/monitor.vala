namespace Singularity.Print {

    /**
     * Follows jobs and printers by polling the spooler over IPP, which
     * every backend answers. Emits `job_finished` once per watched job
     * and `printer_attention` when a printer starts needing the user,
     * such as running out of paper, jamming or running low on supplies.
     */
    public class PrintMonitor : Object {
        public signal void job_finished(JobInfo job, string printer_name);
        public signal void printer_attention(Printer printer, string reason);
        public signal void printers_updated(Gee.List<Printer> printers);

        public uint job_interval { get; set; default = 2; }
        public uint printer_interval { get; set; default = 20; }

        private class Watched : Object {
            public string printer;
            public int id;
            public string title;
        }

        private Gee.HashMap<int, Watched> watched = new Gee.HashMap<int, Watched>();
        private Gee.HashMap<string, string> last_reason = new Gee.HashMap<string, string>();
        private uint job_timer;
        private uint printer_timer;
        private bool polling;

        public void start() {
            if (printer_timer != 0) return;
            poll_printers.begin();
            printer_timer = Timeout.add_seconds(printer_interval, () => {
                poll_printers.begin();
                return Source.CONTINUE;
            });
        }

        public void stop() {
            if (printer_timer != 0) Source.remove(printer_timer);
            if (job_timer != 0) Source.remove(job_timer);
            printer_timer = job_timer = 0;
        }

        public bool has_jobs {
            get { return watched.size > 0; }
        }

        public void watch(string printer, int job_id, string title) {
            var w = new Watched();
            w.printer = printer;
            w.id = job_id;
            w.title = title;
            watched[job_id] = w;
            if (job_timer == 0) {
                job_timer = Timeout.add_seconds(job_interval, () => {
                    poll_jobs.begin();
                    if (watched.size == 0) {
                        job_timer = 0;
                        return Source.REMOVE;
                    }
                    return Source.CONTINUE;
                });
            }
        }

        private async void poll_jobs() {
            if (polling || watched.size == 0) return;
            polling = true;
            var backend = PrinterBackend.get_default();
            var printers = new Gee.HashSet<string>();
            foreach (var w in watched.values) printers.add(w.printer);
            foreach (var name in printers) {
                try {
                    var active = yield backend.list_jobs(name, false);
                    var done = yield backend.list_jobs(name, true);
                    var ids = new Gee.HashSet<int>();
                    foreach (var j in active) ids.add(j.id);
                    foreach (var j in done) {
                        if (!watched.has_key(j.id) || ids.contains(j.id)) continue;
                        if (!j.state.finished()) continue;
                        var w = watched[j.id];
                        watched.unset(j.id);
                        if (j.title == "" || j.title == _("Untitled Document")) j.title = w.title;
                        job_finished(j, name);
                    }
                } catch (Error e) {
                    debug("Job poll failed: %s", e.message);
                }
            }
            polling = false;
        }

        private async void poll_printers() {
            Gee.List<Printer> list;
            try {
                list = yield PrinterBackend.get_default().list_printers();
            } catch (Error e) {
                return;
            }
            printers_updated(list);
            foreach (var p in list) {
                string reason = p.attention_reason() ?? "";
                if (reason == "" && p.low_supplies) reason = low_supply_text(p);
                string before = last_reason.has_key(p.name) ? last_reason[p.name] : "";
                last_reason[p.name] = reason;
                if (reason != "" && reason != before) printer_attention(p, reason);
            }
        }

        public static string low_supply_text(Printer p) {
            string[] names = {};
            foreach (var m in p.markers) if (m.low) names += m.name;
            if (names.length == 0) return _("Supplies are low");
            return _("%s is low").printf(string.joinv(", ", names));
        }
    }
}
