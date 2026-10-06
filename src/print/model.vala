namespace Singularity.Print {

    public enum PrinterStatus {
        READY,
        PRINTING,
        PAUSED,
        OFFLINE,
        ATTENTION,
        REJECTING;

        public string label() {
            switch (this) {
                case PRINTING: return _("Printing");
                case PAUSED: return _("Paused");
                case OFFLINE: return _("Offline");
                case ATTENTION: return _("Needs Attention");
                case REJECTING: return _("Not Accepting Jobs");
                default: return _("Ready");
            }
        }

        public string css_class() {
            switch (this) {
                case PRINTING: return "printing";
                case PAUSED: return "paused";
                case OFFLINE: return "offline";
                case ATTENTION: return "attention";
                case REJECTING: return "paused";
                default: return "ready";
            }
        }
    }

    public enum PrinterKind {
        GENERIC,
        LASER,
        INKJET,
        LABEL,
        PRINTER_3D,
        MULTIFUNCTION,
        NETWORK,
        PDF;

        public string icon_name() {
            switch (this) {
                case LASER: return "printer-laser";
                case INKJET: return "printer-inkjet";
                case LABEL: return "printer-label";
                case PRINTER_3D: return "printer-3d";
                case MULTIFUNCTION: return "printer-scanner";
                case NETWORK: return "printer-network";
                case PDF: return "printer-pdf";
                default: return "printer";
            }
        }

        public static PrinterKind guess(string make_model, string info, string uri) {
            string text = (make_model + " " + info).down();
            if (text.contains("label") || text.contains("zebra") || text.contains("dymo") || text.contains("ql-"))
                return LABEL;
            if (text.contains("3d") || text.contains("prusa") || text.contains("bambu") || text.contains("ender"))
                return PRINTER_3D;
            if (text.contains("mfp") || text.contains("mfc") || text.contains("all-in-one") || text.contains("scan")
                || text.contains("multifunction") || text.contains("officejet") || text.contains("workforce"))
                return MULTIFUNCTION;
            if (text.contains("laser") || text.contains("mono") || text.contains("toner"))
                return LASER;
            if (text.contains("inkjet") || text.contains("photo") || text.contains("deskjet") || text.contains("pixma")
                || text.contains("envy") || text.contains("stylus") || text.contains("ecotank"))
                return INKJET;
            return GENERIC;
        }
    }

    /**
     * A consumable reported by the printer through the IPP marker-*
     * attributes: toner, ink, drum or waste.
     */
    public class Marker : Object {
        public string name { get; set; default = ""; }
        public string color { get; set; default = "#808080"; }
        public int level { get; set; default = -1; }
        public int low_level { get; set; default = 10; }
        public int high_level { get; set; default = 100; }
        public string marker_type { get; set; default = ""; }

        public bool known {
            get { return level >= 0 && level <= 100; }
        }

        public bool low {
            get { return known && marker_type != "waste-ink" && marker_type != "waste-toner" && level <= low_level; }
        }

        public Gdk.RGBA rgba() {
            var c = Gdk.RGBA();
            string hex = color.strip();
            int start = hex.index_of("#");
            if (start >= 0 && hex.length >= start + 7) hex = hex.substring(start, 7);
            if (!c.parse(hex)) c.parse("#808080");
            return c;
        }
    }

    /**
     * A print queue as the spooler reports it.
     */
    public class Printer : Object {
        public string name { get; set; default = ""; }
        public string info { get; set; default = ""; }
        public string location { get; set; default = ""; }
        public string make_model { get; set; default = ""; }
        public string device_uri { get; set; default = ""; }
        public string printer_uri { get; set; default = ""; }
        public int state { get; set; default = 3; }
        public string[] state_reasons { get; set; default = {}; }
        public string state_message { get; set; default = ""; }
        public bool is_default { get; set; }
        public bool accepting { get; set; default = true; }
        public bool shared { get; set; }
        public bool remote { get; set; }
        public bool temporary { get; set; }
        public int queued_jobs { get; set; }
        public int printer_type { get; set; }
        public Gee.ArrayList<Marker> markers { get; set; default = new Gee.ArrayList<Marker>(); }

        public bool is_pdf {
            get { return name == PDF_PRINTER; }
        }

        public string display_name {
            owned get { return info != "" ? info : name.replace("_", " "); }
        }

        public PrinterKind kind {
            get {
                if (is_pdf) return PrinterKind.PDF;
                var k = PrinterKind.guess(make_model, info, device_uri);
                if (k == PrinterKind.GENERIC && (remote || device_uri.has_prefix("ipp") || device_uri.has_prefix("dnssd")))
                    return PrinterKind.NETWORK;
                return k;
            }
        }

        public string icon_name {
            owned get { return kind.icon_name(); }
        }

        public bool has_reason(string prefix) {
            foreach (var r in state_reasons) if (r.has_prefix(prefix)) return true;
            return false;
        }

        public bool offline {
            get {
                if (has_reason("offline") || has_reason("connecting-to-device") || has_reason("timed-out")
                    || has_reason("shutdown")) return true;
                string m = state_message.down();
                return state == 4 && (m.contains("unable to connect") || m.contains("waiting for printer")
                                      || m.contains("not responding") || m.contains("unable to locate")
                                      || m.contains("will retry"));
            }
        }

        public bool low_supplies {
            get {
                foreach (var m in markers) if (m.low) return true;
                return has_reason("marker-supply-low") || has_reason("toner-low") || has_reason("ink-low");
            }
        }

        public PrinterStatus status {
            get {
                if (is_pdf) return PrinterStatus.READY;
                if (offline) return PrinterStatus.OFFLINE;
                if (state == 5) return PrinterStatus.PAUSED;
                if (attention_reason() != null) return PrinterStatus.ATTENTION;
                if (!accepting) return PrinterStatus.REJECTING;
                if (state == 4) return PrinterStatus.PRINTING;
                return PrinterStatus.READY;
            }
        }

        public string? attention_reason() {
            foreach (var r in state_reasons) {
                string key = r.replace("-error", "").replace("-warning", "").replace("-report", "");
                switch (key) {
                    case "media-empty": case "media-needed": return _("Out of paper");
                    case "media-jam": return _("Paper jam");
                    case "cover-open": case "door-open": return _("A cover is open");
                    case "toner-empty": case "marker-supply-empty": return _("Out of toner or ink");
                    case "input-tray-missing": return _("A paper tray is missing");
                    case "output-area-full": return _("Output tray is full");
                    case "paused": case "none": case "offline": break;
                    default:
                        if (r.has_suffix("-error")) return state_message != "" ? state_message : r;
                        break;
                }
            }
            return null;
        }

        public string status_text() {
            if (is_pdf) return _("Saves a PDF document");
            var reason = attention_reason();
            if (reason != null) return reason;
            if (status == PrinterStatus.READY && low_supplies) return _("Ready, supplies low");
            return status.label();
        }

        public const string PDF_PRINTER = "singularity-save-as-pdf";

        public static Printer save_as_pdf() {
            var p = new Printer();
            p.name = PDF_PRINTER;
            p.info = _("Save as PDF");
            return p;
        }
    }

    public class MediaSize : Object {
        public string keyword { get; construct; }
        public double width_mm { get; construct; }
        public double height_mm { get; construct; }

        public MediaSize(string keyword, double width_mm, double height_mm) {
            Object(keyword: keyword, width_mm: width_mm, height_mm: height_mm);
        }

        public string label() {
            return Media.label(keyword, width_mm, height_mm);
        }
    }

    /**
     * An option that the printer offers beyond the standard set, shown
     * in the Advanced group of the dialog.
     */
    public class ExtraOption : Object {
        public string name { get; construct; }
        public string[] values { get; set; default = {}; }
        public string default_value { get; set; default = ""; }
        public string tag { get; set; default = "keyword"; }

        public ExtraOption(string name) {
            Object(name: name);
        }

        public string label() {
            return Options.humanize(name);
        }
    }

    /**
     * What a destination can do, from Get-Printer-Attributes.
     */
    public class PrinterCapabilities : Object {
        public Gee.ArrayList<MediaSize> media { get; set; default = new Gee.ArrayList<MediaSize>(); }
        public string media_default { get; set; default = ""; }
        public string[] sides { get; set; default = {"one-sided"}; }
        public string sides_default { get; set; default = "one-sided"; }
        public string[] color_modes { get; set; default = {"monochrome"}; }
        public string color_default { get; set; default = ""; }
        public int[] qualities = {};
        public int quality_default { get; set; default = 4; }
        public string[] sources { get; set; default = {}; }
        public string source_default { get; set; default = ""; }
        public string[] media_types { get; set; default = {}; }
        public string media_type_default { get; set; default = ""; }
        public string[] output_bins { get; set; default = {}; }
        public string[] formats { get; set; default = {}; }
        public int copies_max { get; set; default = 999; }
        public int[] margins_mm100 = {};
        public Gee.ArrayList<ExtraOption> extras { get; set; default = new Gee.ArrayList<ExtraOption>(); }

        public bool supports_color {
            get {
                foreach (var m in color_modes) if (m == "color" || m == "auto") return true;
                return false;
            }
        }

        public bool supports_duplex {
            get { return sides.length > 1; }
        }

        public MediaSize? find_media(string keyword) {
            foreach (var m in media) if (m.keyword == keyword) return m;
            return null;
        }

        public static PrinterCapabilities for_pdf() {
            var caps = new PrinterCapabilities();
            foreach (var k in Media.COMMON) {
                var m = Media.from_keyword(k);
                if (m != null) caps.media.add(m);
            }
            caps.media_default = Media.default_keyword();
            caps.color_modes = {"color", "monochrome"};
            caps.color_default = "color";
            caps.sides = {"one-sided"};
            return caps;
        }
    }

    public enum JobState {
        PENDING = 3,
        HELD = 4,
        PROCESSING = 5,
        STOPPED = 6,
        CANCELED = 7,
        ABORTED = 8,
        COMPLETED = 9;

        public string label() {
            switch (this) {
                case PENDING: return _("Waiting");
                case HELD: return _("Held");
                case PROCESSING: return _("Printing");
                case STOPPED: return _("Stopped");
                case CANCELED: return _("Cancelled");
                case ABORTED: return _("Failed");
                case COMPLETED: return _("Completed");
                default: return _("Unknown");
            }
        }

        public bool finished() {
            return this == CANCELED || this == ABORTED || this == COMPLETED;
        }
    }

    public class JobInfo : Object {
        public int id { get; set; }
        public string title { get; set; default = ""; }
        public string printer { get; set; default = ""; }
        public string user { get; set; default = ""; }
        public JobState state { get; set; default = JobState.PENDING; }
        public string[] reasons { get; set; default = {}; }
        public string state_message { get; set; default = ""; }
        public int pages_done { get; set; }
        public int pages_total { get; set; }
        public int64 created { get; set; }
        public int64 completed { get; set; }
        public int size_kb { get; set; }
    }

    /**
     * A printer found on the network or attached locally that has no
     * queue yet. It becomes a printer only after the user confirms.
     */
    public class DiscoveredPrinter : Object {
        public string uri { get; set; default = ""; }
        public string key { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string make_model { get; set; default = ""; }
        public string location { get; set; default = ""; }
        public bool driverless { get; set; }
        public string source { get; set; default = "network"; }

        public string icon_name {
            owned get {
                var k = PrinterKind.guess(make_model, name, uri);
                return k == PrinterKind.GENERIC ? "printer-network" : k.icon_name();
            }
        }
    }
}
