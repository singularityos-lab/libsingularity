namespace Singularity.Print {

    /**
     * PWG 5101.1 media names: parsing, readable labels and the paper
     * sizes offered when the destination does not report its own.
     */
    namespace Media {

        public const string[] COMMON = {
            "iso_a4_210x297mm",
            "na_letter_8.5x11in",
            "na_legal_8.5x14in",
            "iso_a5_148x210mm",
            "iso_a3_297x420mm",
            "iso_b5_176x250mm",
            "na_executive_7.25x10.5in",
            "na_index-4x6_4x6in",
            "om_small-photo_100x150mm",
            "na_5x7_5x7in",
            "iso_dl_110x220mm",
            "iso_c5_162x229mm",
            "na_number-10_4.125x9.5in"
        };

        public MediaSize? from_keyword(string keyword) {
            string[] parts = keyword.split("_");
            if (parts.length < 3) return null;
            string dims = parts[parts.length - 1];
            double factor;
            if (dims.has_suffix("mm")) {
                factor = 1.0;
                dims = dims.substring(0, dims.length - 2);
            } else if (dims.has_suffix("in")) {
                factor = 25.4;
                dims = dims.substring(0, dims.length - 2);
            } else {
                return null;
            }
            string[] wh = dims.split("x");
            if (wh.length != 2) return null;
            double w = double.parse(wh[0]) * factor;
            double h = double.parse(wh[1]) * factor;
            if (w <= 0 || h <= 0) return null;
            return new MediaSize(keyword, w, h);
        }

        public string label(string keyword, double width_mm, double height_mm) {
            string[] parts = keyword.split("_");
            string family = parts.length > 1 ? parts[1] : keyword;
            switch (family) {
                case "a3": return "A3";
                case "a4": return "A4";
                case "a5": return "A5";
                case "a6": return "A6";
                case "b4": return "B4";
                case "b5": return "B5";
                case "letter": return _("Letter");
                case "legal": return _("Legal");
                case "executive": return _("Executive");
                case "ledger": return _("Tabloid");
                case "dl": return _("Envelope DL");
                case "c5": return _("Envelope C5");
                case "c6": return _("Envelope C6");
                case "number-10": return _("Envelope #10");
                case "index-4x6": return _("Photo 4 x 6 in");
                case "small-photo": return _("Photo 10 x 15 cm");
                case "5x7": return _("Photo 5 x 7 in");
                default: break;
            }
            if (keyword.has_suffix("in"))
                return _("%s x %s in").printf(trim(width_mm / 25.4), trim(height_mm / 25.4));
            return _("%s x %s mm").printf(trim(width_mm), trim(height_mm));
        }

        public string default_keyword() {
            string name = Gtk.PaperSize.get_default();
            foreach (var k in COMMON) if (k.has_prefix(name + "_")) return k;
            return "iso_a4_210x297mm";
        }

        public string? best_match(string wanted, Gee.List<MediaSize> available) {
            foreach (var m in available) if (m.keyword == wanted) return m.keyword;
            var target = from_keyword(wanted);
            if (target == null) return available.size > 0 ? available[0].keyword : null;
            foreach (var m in available) {
                if ((m.width_mm - target.width_mm).abs() < 1.5 && (m.height_mm - target.height_mm).abs() < 1.5)
                    return m.keyword;
            }
            return null;
        }

        public Gtk.PaperSize paper_size(string keyword) {
            var m = from_keyword(keyword);
            if (m == null) return new Gtk.PaperSize(null);
            string[] parts = keyword.split("_");
            string gtk_name = parts.length >= 2 ? parts[0] + "_" + parts[1] : keyword;
            foreach (unowned var known in Gtk.PaperSize.get_paper_sizes(false)) {
                if (known.get_name() == gtk_name) return known.copy();
            }
            return new Gtk.PaperSize.custom(keyword, label(keyword, m.width_mm, m.height_mm),
                                            m.width_mm, m.height_mm, Gtk.Unit.MM);
        }

        public string keyword_for_paper(Gtk.PaperSize paper) {
            double w = paper.get_width(Gtk.Unit.MM);
            double h = paper.get_height(Gtk.Unit.MM);
            foreach (var k in COMMON) {
                var m = from_keyword(k);
                if (m != null && (m.width_mm - w).abs() < 1.5 && (m.height_mm - h).abs() < 1.5) return k;
            }
            return "custom_%s_%sx%smm".printf(paper.get_name().replace("_", "-"), trim(w), trim(h));
        }

        private string trim(double v) {
            char[] buf = new char[double.DTOSTR_BUF_SIZE];
            string s = v.format(buf, "%.2f");
            while (s.contains(".") && (s.has_suffix("0") || s.has_suffix("."))) s = s.substring(0, s.length - 1);
            return s;
        }
    }
}
