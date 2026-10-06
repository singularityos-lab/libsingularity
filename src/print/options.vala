namespace Singularity.Print {

    public enum RangeMode {
        ALL,
        CURRENT,
        SELECTION,
        CUSTOM
    }

    public enum Duplex {
        ONE_SIDED,
        LONG_EDGE,
        SHORT_EDGE;

        public string keyword() {
            switch (this) {
                case LONG_EDGE: return "two-sided-long-edge";
                case SHORT_EDGE: return "two-sided-short-edge";
                default: return "one-sided";
            }
        }

        public static Duplex from_keyword(string k) {
            if (k == "two-sided-long-edge") return LONG_EDGE;
            if (k == "two-sided-short-edge") return SHORT_EDGE;
            return ONE_SIDED;
        }
    }

    public enum MarginsMode {
        DEFAULT,
        NONE,
        MINIMUM,
        CUSTOM
    }

    public enum OutputFormat {
        PDF,
        PNG
    }

    /**
     * Everything the user chose in the print dialog. Serialises to a
     * dictionary for presets and "last used" settings, and maps to IPP
     * job attributes and to Gtk.PrintSettings.
     */
    public class JobOptions : Object {
        public string printer { get; set; default = ""; }
        public int copies { get; set; default = 1; }
        public bool collate { get; set; default = true; }
        public RangeMode range_mode { get; set; default = RangeMode.ALL; }
        public string ranges { get; set; default = ""; }
        public PageSet page_set { get; set; default = PageSet.ALL; }
        public bool reverse { get; set; }
        public bool landscape { get; set; }
        public string media { get; set; default = ""; }
        public ScaleMode scale_mode { get; set; default = ScaleMode.FIT; }
        public int scale { get; set; default = 100; }
        public int pages_per_sheet { get; set; default = 1; }
        public NupOrder nup_order { get; set; default = NupOrder.LEFT_RIGHT_TOP_BOTTOM; }
        public bool borders { get; set; }
        public Duplex duplex { get; set; default = Duplex.ONE_SIDED; }
        public bool grayscale { get; set; }
        public int quality { get; set; default = 4; }
        public string media_source { get; set; default = ""; }
        public string media_type { get; set; default = ""; }
        public MarginsMode margins { get; set; default = MarginsMode.DEFAULT; }
        public double margin_top { get; set; default = 10; }
        public double margin_bottom { get; set; default = 10; }
        public double margin_left { get; set; default = 10; }
        public double margin_right { get; set; default = 10; }
        public bool booklet { get; set; }
        public string watermark { get; set; default = ""; }
        public int watermark_opacity { get; set; default = 15; }
        public string header { get; set; default = ""; }
        public string footer { get; set; default = ""; }
        public OutputFormat output_format { get; set; default = OutputFormat.PDF; }
        public string output_path { get; set; default = ""; }
        public HashTable<string, string> extras = new HashTable<string, string>(str_hash, str_equal);
        public HashTable<string, Variant> app_options = new HashTable<string, Variant>(str_hash, str_equal);

        private const string[] TRANSIENT = {"range-mode", "ranges", "output-path", "copies"};

        public bool duplexed {
            get { return duplex != Duplex.ONE_SIDED || booklet; }
        }

        public JobOptions copy() {
            var o = new JobOptions();
            o.apply(to_variant(true));
            return o;
        }

        public Variant to_variant(bool include_transient = false) {
            var b = new VariantBuilder(VariantType.VARDICT);
            foreach (var spec in get_class().list_properties()) {
                if (!include_transient && spec.name in TRANSIENT) continue;
                if ((spec.flags & ParamFlags.WRITABLE) == 0) continue;
                var val = Value(spec.value_type);
                get_property(spec.name, ref val);
                Variant? v = null;
                if (spec.value_type == typeof(string)) v = new Variant.string(val.get_string() ?? "");
                else if (spec.value_type == typeof(int)) v = new Variant.int32(val.get_int());
                else if (spec.value_type == typeof(bool)) v = new Variant.boolean(val.get_boolean());
                else if (spec.value_type == typeof(double)) v = new Variant.double(val.get_double());
                else if (spec.value_type.is_enum()) v = new Variant.int32(val.get_enum());
                if (v != null) b.add("{sv}", spec.name, v);
            }
            var ex = new VariantBuilder(new VariantType("a{ss}"));
            extras.foreach((k, v) => ex.add("{ss}", k, v));
            b.add("{sv}", "extras", ex.end());
            var ao = new VariantBuilder(VariantType.VARDICT);
            app_options.foreach((k, v) => ao.add("{sv}", k, v));
            b.add("{sv}", "app-options", ao.end());
            return b.end();
        }

        public void apply(Variant dict) {
            if (!dict.is_of_type(VariantType.VARDICT)) return;
            var iter = dict.iterator();
            string key;
            Variant v;
            while (iter.next("{sv}", out key, out v)) {
                if (key == "extras") {
                    if (v.is_of_type(new VariantType("a{ss}"))) {
                        extras.remove_all();
                        var it = v.iterator();
                        string ek, ev;
                        while (it.next("{ss}", out ek, out ev)) extras.insert(ek, ev);
                    }
                    continue;
                }
                if (key == "app-options") {
                    if (v.is_of_type(VariantType.VARDICT)) {
                        app_options.remove_all();
                        var it = v.iterator();
                        string ak;
                        Variant av;
                        while (it.next("{sv}", out ak, out av)) app_options.insert(ak, av);
                    }
                    continue;
                }
                var spec = get_class().find_property(key);
                if (spec == null || (spec.flags & ParamFlags.WRITABLE) == 0) continue;
                var val = Value(spec.value_type);
                if (spec.value_type == typeof(string) && v.is_of_type(VariantType.STRING)) val.set_string(v.get_string());
                else if (spec.value_type == typeof(int) && v.is_of_type(VariantType.INT32)) val.set_int(v.get_int32());
                else if (spec.value_type == typeof(bool) && v.is_of_type(VariantType.BOOLEAN)) val.set_boolean(v.get_boolean());
                else if (spec.value_type == typeof(double) && v.is_of_type(VariantType.DOUBLE)) val.set_double(v.get_double());
                else if (spec.value_type.is_enum() && v.is_of_type(VariantType.INT32)) val.set_enum(v.get_int32());
                else continue;
                set_property(key, val);
            }
        }

        public void apply_defaults(PrinterCapabilities caps) {
            if (media == "" || caps.find_media(media) == null) {
                string? match = null;
                if (media != "") match = Media.best_match(media, caps.media);
                if (match == null) match = caps.media_default;
                if (match == null || match == "") match = Media.default_keyword();
                media = match;
            }
            if (!caps.supports_duplex) duplex = Duplex.ONE_SIDED;
            if (!caps.supports_color) grayscale = true;
            if (media_source != "" && !(media_source in caps.sources)) media_source = "";
            if (media_type != "" && !(media_type in caps.media_types)) media_type = "";
        }

        public void geometry(out double width_pt, out double height_pt) {
            var m = Media.from_keyword(media != "" ? media : Media.default_keyword())
                ?? Media.from_keyword("iso_a4_210x297mm");
            double w = m.width_mm * 72.0 / 25.4;
            double h = m.height_mm * 72.0 / 25.4;
            width_pt = landscape ? h : w;
            height_pt = landscape ? w : h;
        }

        public void margins_pt(PrinterCapabilities? caps, out double top, out double bottom,
                               out double left, out double right) {
            double k = 72.0 / 25.4;
            switch (margins) {
                case MarginsMode.NONE:
                    top = bottom = left = right = 0;
                    return;
                case MarginsMode.MINIMUM:
                    double min_mm = 3;
                    if (caps != null && caps.margins_mm100.length > 0) {
                        int biggest = 0;
                        foreach (var v in caps.margins_mm100) biggest = int.max(biggest, v);
                        min_mm = biggest / 100.0;
                    }
                    top = bottom = left = right = min_mm * k;
                    return;
                case MarginsMode.CUSTOM:
                    top = margin_top * k;
                    bottom = margin_bottom * k;
                    left = margin_left * k;
                    right = margin_right * k;
                    return;
                default:
                    top = bottom = 12.7 * k;
                    left = right = 12.7 * k;
                    return;
            }
        }

        /**
         * IPP job template attributes for the submitted, already
         * imposed document. Page selection, n-up and orientation are
         * applied before submission, so only device options remain.
         */
        public IppRequest add_job_attributes(IppRequest req, PrinterCapabilities? caps) {
            req.job_attr("integer", "copies", copies);
            if (copies > 1)
                req.job_attr("keyword", "multiple-document-handling",
                             collate ? "separate-documents-collated-copies" : "separate-documents-uncollated-copies");
            if (caps == null || caps.supports_duplex)
                req.job_attr("keyword", "sides", booklet ? "two-sided-short-edge" : duplex.keyword());
            if (caps == null || caps.color_modes.length > 0)
                req.job_attr("keyword", "print-color-mode", grayscale ? "monochrome" : "color");
            if (caps == null || caps.qualities.length == 0 || quality in caps.qualities)
                req.job_attr("enum", "print-quality", quality);
            if (media != "") {
                if (media_source != "" || media_type != "") {
                    var col = new VariantBuilder(VariantType.VARDICT);
                    var m = Media.from_keyword(media);
                    if (m != null) {
                        var size = new VariantBuilder(VariantType.VARDICT);
                        size.add("{sv}", "x-dimension", new Variant.int32((int) Math.round(m.width_mm * 100)));
                        size.add("{sv}", "y-dimension", new Variant.int32((int) Math.round(m.height_mm * 100)));
                        col.add("{sv}", "media-size", size.end());
                    }
                    if (media_source != "") col.add("{sv}", "media-source", new Variant.string(media_source));
                    if (media_type != "") col.add("{sv}", "media-type", new Variant.string(media_type));
                    req.job_attr("collection", "media-col", col.end());
                } else {
                    req.job_attr("keyword", "media", media);
                }
            }
            extras.foreach((k, v) => {
                if (v == "") return;
                int64 n;
                if (int64.try_parse(v, out n)) req.job_attr("integer", k, (int) n);
                else req.job_attr("keyword", k, v);
            });
            return req;
        }

        /**
         * Maps to Gtk.PrintSettings, the form the print portal returns to
         * applications that render the document themselves.
         */
        public Gtk.PrintSettings to_gtk_settings() {
            var s = new Gtk.PrintSettings();
            s.set_printer(printer);
            s.set_n_copies(copies);
            s.set_collate(collate);
            s.set_reverse(reverse);
            s.set_use_color(!grayscale);
            s.set_orientation(landscape ? Gtk.PageOrientation.LANDSCAPE : Gtk.PageOrientation.PORTRAIT);
            s.set_duplex(duplex == Duplex.LONG_EDGE ? Gtk.PrintDuplex.HORIZONTAL
                         : duplex == Duplex.SHORT_EDGE ? Gtk.PrintDuplex.VERTICAL : Gtk.PrintDuplex.SIMPLEX);
            s.set_number_up(pages_per_sheet);
            s.set_number_up_layout((Gtk.NumberUpLayout) nup_order_to_gtk());
            s.set_page_set(page_set == PageSet.ODD ? Gtk.PageSet.ODD
                           : page_set == PageSet.EVEN ? Gtk.PageSet.EVEN : Gtk.PageSet.ALL);
            s.set_scale(scale_mode == ScaleMode.CUSTOM ? scale : 100);
            s.set_quality(quality >= 5 ? Gtk.PrintQuality.HIGH : quality <= 3 ? Gtk.PrintQuality.DRAFT
                          : Gtk.PrintQuality.NORMAL);
            if (media_source != "") s.set_default_source(media_source);
            if (media_type != "") s.set_media_type(media_type);
            if (media != "") s.set_paper_size(Media.paper_size(media));
            switch (range_mode) {
                case RangeMode.CURRENT: s.set_print_pages(Gtk.PrintPages.CURRENT); break;
                case RangeMode.SELECTION: s.set_print_pages(Gtk.PrintPages.SELECTION); break;
                case RangeMode.CUSTOM:
                    s.set_print_pages(Gtk.PrintPages.RANGES);
                    Gtk.PageRange[] list = {};
                    foreach (var part in ranges.replace(" ", "").split(",")) {
                        if (part == "") continue;
                        var r = Gtk.PageRange();
                        string[] ab = part.split("-");
                        r.start = int.parse(ab[0]) - 1;
                        r.end = ab.length > 1 && ab[1] != "" ? int.parse(ab[1]) - 1 : (ab.length > 1 ? int.MAX / 2 : r.start);
                        list += r;
                    }
                    s.set_page_ranges(list);
                    break;
                default: s.set_print_pages(Gtk.PrintPages.ALL); break;
            }
            if (output_path != "") {
                s.set(Gtk.PRINT_SETTINGS_OUTPUT_URI, File.new_for_path(output_path).get_uri());
                s.set(Gtk.PRINT_SETTINGS_OUTPUT_FILE_FORMAT, "pdf");
            }
            extras.foreach((k, v) => s.set("cups-" + k, v));
            return s;
        }

        public void from_gtk_settings(Gtk.PrintSettings s) {
            if (s.get_printer() != null) printer = s.get_printer();
            if (s.has_key(Gtk.PRINT_SETTINGS_N_COPIES)) copies = int.max(1, s.get_n_copies());
            if (s.has_key(Gtk.PRINT_SETTINGS_COLLATE)) collate = s.get_collate();
            if (s.has_key(Gtk.PRINT_SETTINGS_REVERSE)) reverse = s.get_reverse();
            if (s.has_key(Gtk.PRINT_SETTINGS_USE_COLOR)) grayscale = !s.get_use_color();
            if (s.has_key(Gtk.PRINT_SETTINGS_ORIENTATION))
                landscape = s.get_orientation() == Gtk.PageOrientation.LANDSCAPE
                    || s.get_orientation() == Gtk.PageOrientation.REVERSE_LANDSCAPE;
            if (s.has_key(Gtk.PRINT_SETTINGS_DUPLEX)) {
                var d = s.get_duplex();
                duplex = d == Gtk.PrintDuplex.HORIZONTAL ? Duplex.LONG_EDGE
                    : d == Gtk.PrintDuplex.VERTICAL ? Duplex.SHORT_EDGE : Duplex.ONE_SIDED;
            }
            if (s.has_key(Gtk.PRINT_SETTINGS_NUMBER_UP)) pages_per_sheet = int.max(1, s.get_number_up());
            var paper = s.get_paper_size();
            if (paper != null) media = Media.keyword_for_paper(paper);
        }

        private int nup_order_to_gtk() {
            switch (nup_order) {
                case NupOrder.RIGHT_LEFT_TOP_BOTTOM: return (int) Gtk.NumberUpLayout.RLTB;
                case NupOrder.TOP_BOTTOM_LEFT_RIGHT: return (int) Gtk.NumberUpLayout.TBLR;
                case NupOrder.TOP_BOTTOM_RIGHT_LEFT: return (int) Gtk.NumberUpLayout.TBRL;
                default: return (int) Gtk.NumberUpLayout.LRTB;
            }
        }
    }

    namespace Options {

        public string humanize(string keyword) {
            string text = keyword.replace("-", " ").replace("_", " ");
            if (text.has_prefix("x ")) text = text.substring(2);
            if (text.length == 0) return keyword;
            return text.substring(0, 1).up() + text.substring(1);
        }

        public string quality_label(int q) {
            switch (q) {
                case 3: return _("Draft");
                case 5: return _("Best");
                default: return _("Normal");
            }
        }

        public string expand_template(string template, string title, int page, int pages, DateTime when) {
            return template.replace("{title}", title)
                .replace("{page}", page.to_string())
                .replace("{pages}", pages.to_string())
                .replace("{date}", when.format("%x"))
                .replace("{time}", when.format("%X"));
        }
    }
}
