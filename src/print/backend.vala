namespace Singularity.Print {

    [Flags]
    public enum BackendFeature {
        NONE = 0,
        ADD_URI = 1 << 0,
        ADD_DISCOVERED = 1 << 1,
        REMOVE = 1 << 2,
        SET_DEFAULT = 1 << 3,
        PAUSE = 1 << 4,
        SHARE = 1 << 5,
        EDIT_INFO = 1 << 6,
        DEFAULT_OPTIONS = 1 << 7,
        LEGACY_DRIVER = 1 << 8,
        HOLD_JOBS = 1 << 9,
        COMPLETED_JOBS = 1 << 10
    }

    public class LegacyDriver : Object {
        public string id { get; set; default = ""; }
        public string make_model { get; set; default = ""; }
        public string make { get; set; default = ""; }
    }

    /**
     * The print system seam. Everything that reads printers and jobs or
     * submits documents speaks the IPP dialect libcups uses on the CUPS
     * socket, so any spooler answering it works unchanged. Administrative
     * operations differ between spoolers and live in subclasses:
     * `CupsBackend` uses the CUPS IPP extensions, `TorchioBackend` uses
     * the torchio command line, which asks the ush portal whenever a
     * trust decision is needed. `features` tells the interface which
     * actions to offer.
     */
    public abstract class PrinterBackend : Object {
        public abstract string id { get; }
        public abstract BackendFeature features { get; }

        public signal void printers_changed();

        private static PrinterBackend? instance;

        public bool can(BackendFeature feature) {
            return (features & feature) == feature;
        }

        /**
         * The backend for this session. `SINGULARITY_PRINT_BACKEND` may
         * force "cups" or "torchio"; otherwise Torchio is used when its
         * command is installed.
         */
        public static PrinterBackend get_default() {
            if (instance != null) return instance;
            string? forced = Environment.get_variable("SINGULARITY_PRINT_BACKEND");
            if (forced == "torchio" || (forced == null && Environment.find_program_in_path("torchio") != null))
                instance = new TorchioBackend();
            else
                instance = new CupsBackend();
            return instance;
        }

        public static string queue_uri(string name) {
            return "ipp://localhost/printers/" + Uri.escape_string(name, null, false);
        }

        protected const string[] PRINTER_ATTRS = {
            "printer-name", "printer-info", "printer-location", "printer-make-and-model",
            "printer-state", "printer-state-reasons", "printer-state-message",
            "printer-is-accepting-jobs", "printer-is-shared", "printer-type", "device-uri",
            "printer-uri-supported", "marker-names", "marker-colors", "marker-levels",
            "marker-types", "marker-low-levels", "marker-high-levels", "queued-job-count",
            "printer-is-temporary"
        };

        protected const string[] CAPS_ATTRS = {
            "media-supported", "media-default", "media-ready", "sides-supported", "sides-default",
            "print-color-mode-supported", "print-color-mode-default", "print-quality-supported",
            "print-quality-default", "media-source-supported", "media-type-supported",
            "output-bin-supported", "document-format-supported", "copies-supported",
            "media-bottom-margin-supported", "media-top-margin-supported",
            "media-left-margin-supported", "media-right-margin-supported",
            "job-creation-attributes-supported", "printer-make-and-model", "printer-info",
            "marker-names", "marker-colors", "marker-levels", "marker-types",
            "marker-low-levels", "marker-high-levels", "printer-state", "printer-state-reasons",
            "all"
        };

        private const string[] HANDLED = {
            "copies", "sides", "print-color-mode", "print-quality", "media", "media-col",
            "media-source", "media-type", "multiple-document-handling", "page-ranges",
            "number-up", "orientation-requested", "job-name", "job-priority", "job-hold-until",
            "job-sheets", "print-scaling", "page-delivery", "number-up-layout", "page-border",
            "job-account-id", "job-accounting-user-id", "job-password", "job-password-encryption",
            "output-bin", "printer-resolution", "fit-to-page", "mirror", "print-content-optimize",
            "overrides", "pages-per-subset", "x-image-position", "y-image-position",
            "x-image-shift", "y-image-shift", "x-side1-image-shift", "x-side2-image-shift",
            "y-side1-image-shift", "y-side2-image-shift", "presentation-direction-number-up",
            "job-error-action", "job-message-to-operator", "job-delay-output-until",
            "job-retain-until", "job-phone-number", "job-recipient-name", "job-sheet-message",
            "document-password", "print-rendering-intent", "finishings-col", "job-pages-per-set",
            "confirmation-sheet-print", "cover-back", "cover-front", "separator-sheets",
            "insert-sheet", "imposition-template", "proof-print", "print-accuracy",
            "print-objects", "print-base", "print-supports", "materials-col", "platform-temperature",
            "feed-orientation", "multiple-object-handling"
        };

        public virtual async Gee.List<Printer> list_printers() throws Error {
            var req = new IppRequest(IppOperation.CUPS_GET_PRINTERS).user().requested(PRINTER_ATTRS);
            var resp = yield req.send();
            if (resp.status == 0x0406) return new Gee.ArrayList<Printer>();
            resp.check();
            string? default_name = yield default_printer();
            var list = new Gee.ArrayList<Printer>();
            foreach (var g in resp.groups_of("printer")) {
                var p = printer_from(g);
                if (p.name == "") continue;
                p.is_default = p.name == default_name || (p.printer_type & 0x20000) != 0;
                list.add(p);
            }
            list.sort((a, b) => {
                if (a.is_default != b.is_default) return a.is_default ? -1 : 1;
                return a.display_name.collate(b.display_name);
            });
            return list;
        }

        public virtual async string? default_printer() {
            try {
                var resp = yield new IppRequest(IppOperation.CUPS_GET_DEFAULT).requested({"printer-name"}).send();
                if (!resp.ok) return null;
                var g = resp.first("printer");
                return g != null ? g.str("printer-name") : null;
            } catch (Error e) {
                return null;
            }
        }

        public virtual async Printer? get_printer(string name) throws Error {
            var req = new IppRequest(IppOperation.GET_PRINTER_ATTRIBUTES).printer_uri(queue_uri(name))
                .user().requested(PRINTER_ATTRS);
            req.resource = "/printers/" + name;
            var resp = yield req.send();
            resp.check();
            var g = resp.first("printer");
            if (g == null) return null;
            var p = printer_from(g);
            if (p.name == "") p.name = name;
            p.is_default = (yield default_printer()) == name;
            return p;
        }

        public static Printer printer_from(IppGroup g) {
            var p = new Printer();
            p.name = g.str("printer-name") ?? "";
            p.info = g.str("printer-info") ?? "";
            p.location = g.str("printer-location") ?? "";
            p.make_model = g.str("printer-make-and-model") ?? "";
            p.device_uri = g.str("device-uri") ?? "";
            p.printer_uri = g.str("printer-uri-supported") ?? "";
            p.state = g.integer("printer-state", 3);
            p.state_reasons = g.strs("printer-state-reasons");
            p.state_message = g.str("printer-state-message") ?? "";
            p.accepting = g.boolean("printer-is-accepting-jobs", true);
            p.shared = g.boolean("printer-is-shared", false);
            p.temporary = g.boolean("printer-is-temporary", false);
            p.queued_jobs = g.integer("queued-job-count", 0);
            p.printer_type = g.integer("printer-type", 0);
            p.remote = (p.printer_type & 0x0002) != 0;
            p.markers = markers_from(g);
            return p;
        }

        public static Gee.ArrayList<Marker> markers_from(IppGroup g) {
            var list = new Gee.ArrayList<Marker>();
            var names = g.strs("marker-names");
            var colors = g.strs("marker-colors");
            var levels = g.ints("marker-levels");
            var types = g.strs("marker-types");
            var lows = g.ints("marker-low-levels");
            var highs = g.ints("marker-high-levels");
            for (int i = 0; i < names.length; i++) {
                var m = new Marker();
                m.name = names[i];
                if (i < colors.length) m.color = colors[i];
                if (i < levels.length) m.level = levels[i];
                if (i < types.length) m.marker_type = types[i];
                if (i < lows.length && lows[i] > 0) m.low_level = lows[i];
                if (i < highs.length && highs[i] > 0) m.high_level = highs[i];
                list.add(m);
            }
            return list;
        }

        public virtual async PrinterCapabilities capabilities(string name) throws Error {
            if (name == Printer.PDF_PRINTER) return PrinterCapabilities.for_pdf();
            var req = new IppRequest(IppOperation.GET_PRINTER_ATTRIBUTES).printer_uri(queue_uri(name))
                .user().requested(CAPS_ATTRS);
            req.resource = "/printers/" + name;
            var resp = yield req.send();
            resp.check();
            var g = resp.first("printer");
            if (g == null) throw new PrintError.NOT_FOUND(_("Printer not found"));
            return capabilities_from(g);
        }

        /**
         * Queries a device directly, for example before adding it or to
         * read supply levels that the spooler does not relay.
         */
        public virtual async IppGroup? probe(string uri) throws Error {
            string target = uri;
            if (target.has_prefix("dnssd://")) throw new PrintError.UNSUPPORTED(_("Resolve the address first"));
            var req = new IppRequest(IppOperation.GET_PRINTER_ATTRIBUTES).printer_uri(target)
                .user().requested(CAPS_ATTRS);
            req.uri = target;
            var resp = yield req.send();
            resp.check();
            return resp.first("printer");
        }

        /**
         * Reads supply levels from the device itself when the spooler
         * has none yet, for example before the first job of a queue.
         */
        public virtual async void fill_markers(Printer p) {
            if (p.markers.size > 0) return;
            if (!p.device_uri.has_prefix("ipp://") && !p.device_uri.has_prefix("ipps://")) return;
            try {
                var g = yield probe(p.device_uri);
                if (g != null) p.markers = markers_from(g);
            } catch (Error e) {
                debug("No supply levels for %s: %s", p.name, e.message);
            }
        }

        public static PrinterCapabilities capabilities_from(IppGroup g) {
            var caps = new PrinterCapabilities();
            foreach (var k in g.strs("media-supported")) {
                if (k.has_prefix("custom_min") || k.has_prefix("custom_max")) continue;
                var m = Media.from_keyword(k);
                if (m != null) caps.media.add(m);
            }
            if (caps.media.size == 0) {
                foreach (var k in Media.COMMON) {
                    var m = Media.from_keyword(k);
                    if (m != null) caps.media.add(m);
                }
            }
            caps.media_default = g.str("media-default") ?? Media.default_keyword();
            var sides = g.strs("sides-supported");
            if (sides.length > 0) caps.sides = sides;
            caps.sides_default = g.str("sides-default") ?? "one-sided";
            var colors = g.strs("print-color-mode-supported");
            if (colors.length > 0) caps.color_modes = colors;
            caps.color_default = g.str("print-color-mode-default") ?? "";
            caps.qualities = g.ints("print-quality-supported");
            caps.quality_default = g.integer("print-quality-default", 4);
            caps.sources = g.strs("media-source-supported");
            caps.media_types = g.strs("media-type-supported");
            caps.output_bins = g.strs("output-bin-supported");
            caps.formats = g.strs("document-format-supported");
            int[] margins = {};
            foreach (var key in new string[] {"media-bottom-margin-supported", "media-top-margin-supported",
                                              "media-left-margin-supported", "media-right-margin-supported"}) {
                var list = g.ints(key);
                int min = int.MAX;
                foreach (var v in list) min = int.min(min, v);
                if (list.length > 0) margins += min;
            }
            caps.margins_mm100 = margins;
            var copies = g.raw("copies-supported");
            if (copies != null && copies.is_of_type(new VariantType("(ii)"))) {
                int lo, hi;
                copies.get("(ii)", out lo, out hi);
                caps.copies_max = int.max(1, hi);
            }
            foreach (var attr in g.strs("job-creation-attributes-supported")) {
                if (attr in HANDLED || attr.has_suffix("-col") || attr.has_suffix("-actual")) continue;
                var values = g.strs(attr + "-supported");
                if (values.length < 2) continue;
                var opt = new ExtraOption(attr);
                opt.values = values;
                opt.default_value = g.str(attr + "-default") ?? values[0];
                caps.extras.add(opt);
            }
            if (caps.output_bins.length > 1) {
                var opt = new ExtraOption("output-bin");
                opt.values = caps.output_bins;
                opt.default_value = g.str("output-bin-default") ?? caps.output_bins[0];
                caps.extras.insert(0, opt);
            }
            return caps;
        }

        public virtual async Gee.List<JobInfo> list_jobs(string? printer, bool completed) throws Error {
            var req = new IppRequest(IppOperation.GET_JOBS)
                .printer_uri(printer != null ? queue_uri(printer) : "ipp://localhost/")
                .user()
                .operation_attr("keyword", "which-jobs", completed ? "completed" : "not-completed")
                .requested({"job-id", "job-name", "job-state", "job-state-reasons", "job-state-message",
                            "job-printer-uri", "job-originating-user-name", "job-media-sheets-completed",
                            "job-impressions-completed", "job-impressions", "time-at-creation",
                            "time-at-completed", "job-k-octets"});
            req.resource = printer != null ? "/printers/" + printer : "/";
            var resp = yield req.send();
            if (resp.status == 0x0406) return new Gee.ArrayList<JobInfo>();
            resp.check();
            var list = new Gee.ArrayList<JobInfo>();
            foreach (var g in resp.groups_of("job")) {
                var j = new JobInfo();
                j.id = g.integer("job-id");
                j.title = g.str("job-name") ?? _("Untitled Document");
                j.state = (JobState) g.integer("job-state", 3);
                j.reasons = g.strs("job-state-reasons");
                j.state_message = g.str("job-state-message") ?? "";
                string uri = g.str("job-printer-uri") ?? "";
                j.printer = uri.contains("/") ? Uri.unescape_string(uri.substring(uri.last_index_of("/") + 1)) ?? "" : (printer ?? "");
                j.user = g.str("job-originating-user-name") ?? "";
                j.pages_done = g.integer("job-impressions-completed", g.integer("job-media-sheets-completed"));
                j.pages_total = g.integer("job-impressions");
                j.created = g.time("time-at-creation");
                j.completed = g.time("time-at-completed");
                j.size_kb = g.integer("job-k-octets");
                if (j.id > 0) list.add(j);
            }
            list.sort((a, b) => b.id - a.id);
            return list;
        }

        public virtual async int submit(string printer, string document, string title, JobOptions options,
                                        PrinterCapabilities? caps, string format = "application/pdf") throws Error {
            var req = new IppRequest(IppOperation.PRINT_JOB).printer_uri(queue_uri(printer)).user()
                .operation_attr("name", "job-name", title != "" ? title : _("Untitled Document"))
                .operation_attr("mimeMediaType", "document-format", format);
            options.add_job_attributes(req, caps);
            req.resource = "/printers/" + printer;
            req.document_path = document;
            var resp = yield req.send();
            resp.check();
            var g = resp.first("job");
            return g != null ? g.integer("job-id") : 0;
        }

        protected async void job_operation(IppOperation op, int job_id) throws Error {
            var req = new IppRequest(op).operation_attr("uri", "job-uri", "ipp://localhost/jobs/%d".printf(job_id)).user();
            req.resource = "/jobs/";
            var resp = yield req.send();
            resp.check();
        }

        public virtual async void cancel_job(int job_id) throws Error {
            yield job_operation(IppOperation.CANCEL_JOB, job_id);
        }

        public virtual async void hold_job(int job_id) throws Error {
            yield job_operation(IppOperation.HOLD_JOB, job_id);
        }

        public virtual async void release_job(int job_id) throws Error {
            yield job_operation(IppOperation.RELEASE_JOB, job_id);
        }

        public abstract async void add_printer(string name, string uri, string info, string location,
                                               string? driver = null) throws Error;
        public abstract async void add_discovered(DiscoveredPrinter device, string name) throws Error;
        public abstract async void remove_printer(string name) throws Error;
        public abstract async void set_default(string name) throws Error;
        public abstract async void set_paused(string name, bool paused) throws Error;
        public abstract async void set_shared(string name, bool shared) throws Error;
        public abstract async void set_info(string name, string info, string location) throws Error;
        public abstract async void set_default_options(string name, JobOptions options) throws Error;
        public abstract async Gee.List<DiscoveredPrinter> discover(Cancellable? cancellable = null) throws Error;

        public virtual async Gee.List<LegacyDriver> legacy_drivers() throws Error {
            throw new PrintError.UNSUPPORTED(_("This print service does not use legacy drivers"));
        }

        public static string sanitize_name(string display) {
            var b = new StringBuilder();
            foreach (var c in display.to_ascii().to_utf8()) {
                if (c.isalnum() || c == '-' || c == '.') b.append_c(c);
                else if (b.len > 0 && b.str[b.len - 1] != '_') b.append_c('_');
            }
            string s = b.str;
            while (s.has_suffix("_")) s = s.substring(0, s.length - 1);
            return s == "" ? "Printer" : s.substring(0, int.min(s.length, 120));
        }
    }

    /**
     * CUPS administration through its IPP extension operations. Local
     * administrators are authorised by CUPS itself through the socket
     * peer credentials; everyone else gets `PrintError.NOT_AUTHORIZED`.
     */
    public class CupsBackend : PrinterBackend {
        public override string id { get { return "cups"; } }

        public override BackendFeature features {
            get {
                return BackendFeature.ADD_URI | BackendFeature.ADD_DISCOVERED | BackendFeature.REMOVE
                    | BackendFeature.SET_DEFAULT | BackendFeature.PAUSE | BackendFeature.SHARE
                    | BackendFeature.EDIT_INFO | BackendFeature.DEFAULT_OPTIONS | BackendFeature.LEGACY_DRIVER
                    | BackendFeature.HOLD_JOBS | BackendFeature.COMPLETED_JOBS;
            }
        }

        private IppRequest admin(IppOperation op, string name) {
            var req = new IppRequest(op).printer_uri(queue_uri(name)).user();
            req.resource = "/admin/";
            return req;
        }

        private async void run(IppRequest req) throws Error {
            var resp = yield req.send();
            resp.check();
            printers_changed();
        }

        public override async void add_printer(string name, string uri, string info, string location,
                                               string? driver = null) throws Error {
            var req = admin(IppOperation.CUPS_ADD_MODIFY_PRINTER, name);
            req.operation_attr("name", "ppd-name", driver ?? "everywhere");
            req.printer_attr("uri", "device-uri", uri);
            if (info != "") req.printer_attr("text", "printer-info", info);
            if (location != "") req.printer_attr("text", "printer-location", location);
            req.printer_attr("boolean", "printer-is-accepting-jobs", true);
            req.printer_attr("enum", "printer-state", 3);
            yield run(req);
        }

        public override async void add_discovered(DiscoveredPrinter device, string name) throws Error {
            yield add_printer(sanitize_name(name), device.uri, name, device.location, null);
        }

        public override async void remove_printer(string name) throws Error {
            yield run(admin(IppOperation.CUPS_DELETE_PRINTER, name));
        }

        public override async void set_default(string name) throws Error {
            yield run(admin(IppOperation.CUPS_SET_DEFAULT, name));
        }

        public override async void set_paused(string name, bool paused) throws Error {
            yield run(admin(paused ? IppOperation.PAUSE_PRINTER : IppOperation.RESUME_PRINTER, name));
            if (!paused) {
                try {
                    yield run(admin(IppOperation.CUPS_ACCEPT_JOBS, name));
                } catch (Error e) {
                }
            }
        }

        public override async void set_shared(string name, bool shared) throws Error {
            var req = admin(IppOperation.CUPS_ADD_MODIFY_PRINTER, name);
            req.printer_attr("boolean", "printer-is-shared", shared);
            yield run(req);
        }

        public override async void set_info(string name, string info, string location) throws Error {
            var req = admin(IppOperation.CUPS_ADD_MODIFY_PRINTER, name);
            req.printer_attr("text", "printer-info", info);
            req.printer_attr("text", "printer-location", location);
            yield run(req);
        }

        public override async void set_default_options(string name, JobOptions options) throws Error {
            var req = admin(IppOperation.CUPS_ADD_MODIFY_PRINTER, name);
            if (options.media != "") req.printer_attr("keyword", "media-default", options.media);
            req.printer_attr("keyword", "sides-default", options.duplex.keyword());
            req.printer_attr("keyword", "print-color-mode-default", options.grayscale ? "monochrome" : "color");
            req.printer_attr("enum", "print-quality-default", options.quality);
            yield run(req);
        }

        public override async Gee.List<DiscoveredPrinter> discover(Cancellable? cancellable = null) throws Error {
            var req = new IppRequest(IppOperation.CUPS_GET_DEVICES).user()
                .operation_attr("integer", "timeout", 6)
                .operation_attr("name", "exclude-schemes", new string[] {"file", "cups-pdf", "serial", "parallel", "beh", "hp", "hpfax"});
            var resp = yield req.send(cancellable);
            var list = new Gee.ArrayList<DiscoveredPrinter>();
            if (resp.status == 0x0406) return list;
            resp.check();
            var seen = new Gee.HashSet<string>();
            foreach (var g in resp.groups) {
                string uri = g.str("device-uri") ?? "";
                if (uri == "" || !uri.contains(":/") || seen.contains(uri)) continue;
                string cls = g.str("device-class") ?? "";
                if (cls == "file") continue;
                seen.add(uri);
                var d = new DiscoveredPrinter();
                d.uri = uri;
                d.key = uri;
                d.name = g.str("device-info") ?? uri;
                d.make_model = g.str("device-make-and-model") ?? "";
                d.location = g.str("device-location") ?? "";
                string id = g.str("device-id") ?? "";
                d.driverless = uri.has_prefix("ipp") || uri.contains("_ipp") || id.contains("URF:")
                    || id.contains("PDF") || d.make_model.down().contains("everywhere");
                d.source = uri.has_prefix("usb") ? "usb" : "network";
                list.add(d);
            }
            list.sort((a, b) => {
                if (a.driverless != b.driverless) return a.driverless ? -1 : 1;
                return a.name.collate(b.name);
            });
            return list;
        }

        public override async Gee.List<LegacyDriver> legacy_drivers() throws Error {
            var req = new IppRequest((IppOperation) 0x400C).user()
                .requested({"ppd-name", "ppd-make-and-model", "ppd-make"});
            var resp = yield req.send();
            resp.check();
            var list = new Gee.ArrayList<LegacyDriver>();
            foreach (var g in resp.groups) {
                string name = g.str("ppd-name") ?? "";
                if (name == "" || name == "everywhere" || name == "raw") continue;
                var d = new LegacyDriver();
                d.id = name;
                d.make_model = g.str("ppd-make-and-model") ?? name;
                d.make = g.str("ppd-make") ?? "";
                list.add(d);
            }
            list.sort((a, b) => a.make_model.collate(b.make_model));
            return list;
        }
    }

    /**
     * Torchio, the rootless per-user spooler. It answers the libcups IPP
     * dialect on its CUPS socket, so reading and printing go through the
     * shared IPP code; configuration goes through the torchio command,
     * and adding a discovered printer is confirmed by the user through
     * the ush portal on the daemon side.
     */
    public class TorchioBackend : PrinterBackend {
        public override string id { get { return "torchio"; } }

        public override BackendFeature features {
            get {
                return BackendFeature.ADD_URI | BackendFeature.ADD_DISCOVERED | BackendFeature.REMOVE
                    | BackendFeature.SET_DEFAULT;
            }
        }

        private async string torchio(string[] args, Cancellable? cancellable = null) throws Error {
            string[] argv = {"torchio"};
            foreach (var a in args) argv += a;
            var proc = new Subprocess.newv(argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            string? out_text, err_text;
            yield proc.communicate_utf8_async(null, cancellable, out out_text, out err_text);
            if (!proc.get_if_exited() || proc.get_exit_status() != 0) {
                string msg = (err_text ?? "").strip();
                if (msg.contains("denied") || msg.contains("deny"))
                    throw new PrintError.NOT_AUTHORIZED(msg);
                throw new PrintError.FAILED(msg != "" ? msg : _("The print service reported an error"));
            }
            printers_changed();
            return out_text ?? "";
        }

        public override async void add_printer(string name, string uri, string info, string location,
                                               string? driver = null) throws Error {
            yield torchio({"printer", "add", sanitize_name(name != "" ? name : info), uri});
        }

        public override async void add_discovered(DiscoveredPrinter device, string name) throws Error {
            yield torchio({"discover", "add", device.key, sanitize_name(name)});
        }

        public override async void remove_printer(string name) throws Error {
            yield torchio({"printer", "rm", name});
        }

        public override async void set_default(string name) throws Error {
            yield torchio({"printer", "default", name});
        }

        public override async void set_paused(string name, bool paused) throws Error {
            throw new PrintError.UNSUPPORTED(_("Pausing is not available with this print service"));
        }

        public override async void set_shared(string name, bool shared) throws Error {
            throw new PrintError.UNSUPPORTED(_("Sharing is managed by the print service"));
        }

        public override async void set_info(string name, string info, string location) throws Error {
            throw new PrintError.UNSUPPORTED(_("Renaming is not available with this print service"));
        }

        public override async void set_default_options(string name, JobOptions options) throws Error {
            throw new PrintError.UNSUPPORTED(_("Default options are not available with this print service"));
        }

        public override async Gee.List<DiscoveredPrinter> discover(Cancellable? cancellable = null) throws Error {
            var text = yield torchio({"discover"}, cancellable);
            var list = new Gee.ArrayList<DiscoveredPrinter>();
            var regex = new Regex("\\s{2,}");
            foreach (var line in text.split("\n")) {
                if (line.has_prefix("KEY") || line.strip() == "" || line.has_prefix("no printers")
                    || line.has_prefix("confirm")) continue;
                var cols = regex.split(line.strip());
                if (cols.length < 3) continue;
                var d = new DiscoveredPrinter();
                d.key = cols[0];
                d.name = cols[1];
                d.uri = cols[2];
                d.driverless = true;
                list.add(d);
            }
            return list;
        }
    }
}
