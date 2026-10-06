namespace Singularity.Equations {

    public class Equation : Object {
        public const string ODF_MEDIA_TYPE = "application/vnd.oasis.opendocument.formula";
        public const string OMML_MIME = "application/x-omml+xml";

        private string _mathml = "";
        private string? pending_latex;
        private Cairo.ImageSurface? surface;
        private double rendered_scale = 1.0;
        private double _width_pt;
        private double _ascent_pt;
        private double _descent_pt;
        private Gdk.Texture? _texture;

        public bool display { get; set; default = true; }
        public Justification justification { get; set; default = Justification.CENTER_GROUP; }
        public bool numbered { get; set; default = false; }
        public string? label { get; set; }
        public double max_width_pt { get; set; default = 0; }

        public signal void changed();

        public string mathml {
            get {
                ensure_mathml();
                return _mathml;
            }
            set {
                _mathml = normalize(value);
                pending_latex = null;
            }
        }

        public string latex {
            owned get {
                if (pending_latex != null) return pending_latex;
                var root = MathXml.parse(_mathml);
                if (root == null) return "";
                var sem = root.find("semantics");
                if (sem == null) return "";
                foreach (var a in sem.children) {
                    if (a.local != "annotation") continue;
                    string enc = a.attr("encoding");
                    if (enc == "application/x-tex" || enc == "TeX" || enc == "LaTeX") return a.text.strip();
                }
                return "";
            }
        }

        public string speech {
            owned get {
                string s = Speech.describe(mathml);
                if (s == "") return _("Empty equation");
                return s;
            }
        }

        public double width_pt {
            get { return _width_pt; }
        }

        public double ascent_pt {
            get { return _ascent_pt; }
        }

        public double descent_pt {
            get { return _descent_pt; }
        }

        public Gdk.Texture? texture {
            get { return _texture; }
        }

        public bool rendered {
            get { return surface != null; }
        }

        public Equation() {
            _mathml = "<math xmlns=\"" + Omml.MATHML_NS + "\" display=\"block\"><mrow/></math>";
        }

        public Equation.from_mathml(string mathml) {
            _mathml = normalize(mathml);
            var root = MathXml.parse(_mathml);
            if (root != null) {
                string d = root.attr("display");
                display = d == "" || d == "block";
                string j = root.attr("data-justification");
                if (j == "") j = root.attr("indentalign");
                if (j != "") justification = Justification.from_mathml(j);
            }
        }

        public Equation.from_latex(string latex) {
            this();
            pending_latex = latex;
        }

        public static Equation? from_omml(string omml_xml) {
            if (!omml_xml.contains("oMath")) return null;
            bool disp;
            Justification jc;
            string mml = Omml.to_mathml(omml_xml, out disp, out jc);
            var eq = new Equation.from_mathml(mml);
            eq.display = disp;
            eq.justification = jc;
            return eq;
        }

        public static Equation? from_odf_object(string content_xml) {
            var root = MathXml.parse(content_xml);
            if (root == null) return null;
            var math = root.find("math");
            if (math == null) return null;
            return new Equation.from_mathml(math.to_xml());
        }

        public static Equation? from_clipboard(string mime, Bytes data) {
            string text = ((string) data.get_data()).make_valid((ssize_t) data.get_size());
            string m = mime.down();
            if (m == OMML_MIME || m.contains("omml")) return from_omml(text);
            if (m.contains("mathml")) {
                if (!text.contains("math")) return null;
                return new Equation.from_mathml(text);
            }
            if (m == "text/html") {
                int ms = text.index_of("<m:oMath");
                if (ms >= 0) {
                    int para = text.index_of("<m:oMathPara");
                    int start = para >= 0 && para <= ms ? para : ms;
                    string close_tag = para >= 0 && para <= ms ? "</m:oMathPara>" : "</m:oMath>";
                    int end = text.index_of(close_tag, start);
                    if (end > start) {
                        var eq = from_omml(text.substring(start, end + close_tag.length - start));
                        if (eq != null) return eq;
                    }
                }
                int s = text.index_of("<math");
                if (s < 0) return null;
                int e = text.index_of("</math>", s);
                if (e < 0) return null;
                return new Equation.from_mathml(text.substring(s, e + 7 - s));
            }
            string t = text.strip();
            if (t.has_prefix("<") && t.contains("<math")) return new Equation.from_mathml(t);
            return null;
        }

        private static string normalize(string mathml) {
            var root = MathXml.parse(mathml);
            if (root == null) return mathml;
            var math = root.find("math");
            if (math == null) return mathml;
            var clean = strip_prefix(math);
            if (!clean.has_attr("xmlns")) clean.set_attr("xmlns", Omml.MATHML_NS);
            return clean.to_xml();
        }

        private static MathNode strip_prefix(MathNode n) {
            var c = new MathNode(n.local);
            c.text = n.text;
            foreach (var a in n.attribute_names()) {
                if (a.has_prefix("xmlns:")) continue;
                if (a == "xmlns") {
                    c.set_attr("xmlns", Omml.MATHML_NS);
                    continue;
                }
                int colon = a.index_of_char(':');
                c.set_attr(colon >= 0 ? a.substring(colon + 1) : a, n.get_attr(a) ?? "");
            }
            foreach (var k in n.children) c.append(strip_prefix(k));
            return c;
        }

        public string mathml_for_display() {
            var root = MathXml.parse(mathml);
            if (root == null) return mathml;
            if (display) root.set_attr("display", "block");
            else root.set_attr("display", "inline");
            if (display && justification != Justification.CENTER_GROUP) root.set_attr("data-justification", justification.to_mathml());
            return root.to_xml();
        }

        public string to_omml() {
            return Omml.from_mathml(mathml, display, justification, false);
        }

        public string to_omml_html() {
            return Omml.from_mathml(mathml, display, justification, true);
        }

        public string to_odf_object() {
            return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + mathml_for_display();
        }

        public string to_word_html() {
            var sb = new StringBuilder();
            sb.append("<html xmlns:o=\"urn:schemas-microsoft-com:office:office\" xmlns:w=\"urn:schemas-microsoft-com:office:word\" xmlns:m=\"").append(Omml.HTML_NS).append("\" xmlns=\"http://www.w3.org/TR/REC-html40\">");
            sb.append("<head><meta charset=\"utf-8\"></head><body><!--StartFragment--><p class=MsoNormal>");
            string omml = to_omml_html().replace(" xmlns:m=\"" + Omml.HTML_NS + "\"", "");
            sb.append("<!--[if gte msEquation 12]>").append(omml).append("<![endif]-->");
            sb.append("<![if !msEquation]>").append(mathml_for_display()).append("<![endif]>");
            sb.append("</p><!--EndFragment--></body></html>");
            return sb.str;
        }

        public Gdk.ContentProvider content_provider() {
            Gdk.ContentProvider[] parts = {};
            var mml = new Bytes(mathml_for_display().data);
            parts += new Gdk.ContentProvider.for_bytes("application/mathml+xml", mml);
            parts += new Gdk.ContentProvider.for_bytes("application/mathml-presentation+xml", mml);
            parts += new Gdk.ContentProvider.for_bytes("MathML", mml);
            parts += new Gdk.ContentProvider.for_bytes("MathML Presentation", mml);
            parts += new Gdk.ContentProvider.for_bytes(OMML_MIME, new Bytes(to_omml().data));
            parts += new Gdk.ContentProvider.for_bytes("text/html", new Bytes(to_word_html().data));
            if (surface != null) {
                var buf = new ByteArray();
                surface.write_to_png_stream((data) => {
                    buf.append(data);
                    return Cairo.Status.SUCCESS;
                });
                parts += new Gdk.ContentProvider.for_bytes("image/png", new Bytes(buf.data));
            }
            string l = latex;
            var val = GLib.Value(typeof(string));
            val.set_string(l != "" ? l : mathml_for_display());
            parts += new Gdk.ContentProvider.for_value(val);
            return new Gdk.ContentProvider.union(parts);
        }

        public static string helper_program() {
            string? over = Environment.get_variable("SINGULARITY_EQUATION_HELPER");
            if (over != null && over != "") return over;
            return "singularity-formula";
        }

        public static bool editor_available() {
            string p = helper_program();
            if (Path.is_absolute(p)) return FileUtils.test(p, FileTest.IS_EXECUTABLE);
            return Environment.find_program_in_path(p) != null;
        }

        private void ensure_mathml() {
            if (pending_latex == null) return;
            string latex_src = pending_latex;
            if (latex_src.strip() == "") {
                pending_latex = null;
                return;
            }
            if (!editor_available()) return;
            string dir;
            try {
                dir = DirUtils.make_tmp("singularity-equation-XXXXXX");
            } catch (Error e) {
                return;
            }
            string out_path = Path.build_filename(dir, "out.mml");
            try {
                var proc = new Subprocess.newv({ helper_program(), "--render", latex_src, out_path }, SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
                proc.wait(null);
                string text;
                if (FileUtils.get_contents(out_path, out text)) {
                    _mathml = normalize(text);
                    pending_latex = null;
                }
            } catch (Error e) {
                warning("equation: %s", e.message);
            }
            FileUtils.remove(out_path);
            DirUtils.remove(dir);
        }

        private bool read_metrics(string json, double scale) {
            try {
                var parser = new Json.Parser();
                parser.load_from_data(json);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return false;
                var o = root.get_object();
                double w = o.get_double_member("width");
                double h = o.get_double_member("height");
                double b = o.get_double_member("baseline");
                _width_pt = w;
                _ascent_pt = b;
                _descent_pt = double.max(0, h - b);
                rendered_scale = o.has_member("scale") ? o.get_double_member("scale") : scale;
                return true;
            } catch (Error e) {
                return false;
            }
        }

        private void load_png(string path) {
            surface = new Cairo.ImageSurface.from_png(path);
            if (surface.status() != Cairo.Status.SUCCESS) {
                surface = null;
                _texture = null;
                return;
            }
            try {
                _texture = Gdk.Texture.from_filename(path);
            } catch (Error e) {
                _texture = null;
            }
        }

        public async bool render(double font_size_pt, double scale, Cancellable? cancellable = null) {
            if (!editor_available()) return false;
            string dir;
            try {
                dir = DirUtils.make_tmp("singularity-equation-XXXXXX");
            } catch (Error e) {
                return false;
            }
            string in_path = Path.build_filename(dir, "in.mml");
            string out_path = Path.build_filename(dir, "out.png");
            string mml_out = Path.build_filename(dir, "out.mml");
            bool ok = false;
            try {
                string[] argv = { helper_program(), "--render" };
                if (pending_latex != null) {
                    argv += pending_latex;
                } else {
                    FileUtils.set_contents(in_path, _mathml);
                    argv += in_path;
                }
                argv += out_path;
                argv += "--size";
                argv += "%.3f".printf(font_size_pt).replace(",", ".");
                argv += "--scale";
                argv += "%.3f".printf(scale).replace(",", ".");
                argv += "--padding";
                argv += "%.3f".printf(font_size_pt * 0.08).replace(",", ".");
                argv += "--metrics";
                argv += "--transparent";
                if (!display) argv += "--inline";
                if (max_width_pt > 0) {
                    argv += "--width";
                    argv += "%.3f".printf(max_width_pt).replace(",", ".");
                    argv += "--justify";
                    argv += justification.to_mathml();
                }
                if (pending_latex != null) {
                    argv += "--mathml-out";
                    argv += mml_out;
                }
                var proc = new Subprocess.newv(argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
                string? stdout_text;
                string? stderr_text;
                yield proc.communicate_utf8_async(null, cancellable, out stdout_text, out stderr_text);
                if (proc.get_if_exited() && proc.get_exit_status() == 0 && stdout_text != null) {
                    string line = stdout_text.strip();
                    int nl = line.last_index_of_char('\n');
                    if (nl >= 0) line = line.substring(nl + 1);
                    if (read_metrics(line, scale) && FileUtils.test(out_path, FileTest.EXISTS)) {
                        load_png(out_path);
                        ok = surface != null;
                    }
                    if (pending_latex != null && FileUtils.test(mml_out, FileTest.EXISTS)) {
                        string text;
                        FileUtils.get_contents(mml_out, out text);
                        _mathml = normalize(text);
                        pending_latex = null;
                    }
                }
            } catch (Error e) {
                if (!(e is IOError.CANCELLED)) warning("equation render: %s", e.message);
            }
            foreach (var p in new string[] { in_path, out_path, mml_out }) FileUtils.remove(p);
            DirUtils.remove(dir);
            return ok;
        }

        public void paint(Cairo.Context cr, double x, double baseline_y, double zoom = 1.0) {
            if (surface == null) return;
            cr.save();
            cr.translate(x, baseline_y - _ascent_pt * zoom);
            double k = zoom / rendered_scale;
            cr.scale(k, k);
            cr.set_source_surface(surface, 0, 0);
            cr.paint();
            cr.restore();
        }

        public async bool edit(Gtk.Window? parent) {
            if (!editor_available()) return false;
            string dir;
            try {
                dir = DirUtils.make_tmp("singularity-equation-XXXXXX");
            } catch (Error e) {
                return false;
            }
            string in_path = Path.build_filename(dir, "in.mml");
            string target = Path.build_filename(dir, "equation.png");
            string[] outputs = { "equation.png", "equation.mml", "equation.tex", "equation.json" };
            bool changed_now = false;
            try {
                string[] argv = { helper_program(), "--insert", target };
                if (pending_latex != null) {
                    if (pending_latex.strip() != "") {
                        argv += "--latex";
                        argv += pending_latex;
                    }
                } else {
                    FileUtils.set_contents(in_path, mathml_for_display());
                    argv += "--mathml";
                    argv += in_path;
                }
                if (!display) argv += "--inline";
                if (parent != null) parent.sensitive = false;
                var proc = new Subprocess.newv(argv, SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
                yield proc.wait_async(null);
                string mml_path = Path.build_filename(dir, "equation.mml");
                if (FileUtils.test(mml_path, FileTest.EXISTS)) {
                    string text;
                    FileUtils.get_contents(mml_path, out text);
                    bool keep_display = display;
                    _mathml = normalize(text);
                    pending_latex = null;
                    display = keep_display;
                    string json = "";
                    string json_path = Path.build_filename(dir, "equation.json");
                    if (FileUtils.test(json_path, FileTest.EXISTS) && FileUtils.get_contents(json_path, out json)) read_metrics(json, 2.0);
                    if (FileUtils.test(target, FileTest.EXISTS)) load_png(target);
                    changed_now = true;
                }
            } catch (Error e) {
                warning("equation edit: %s", e.message);
            }
            if (parent != null) parent.sensitive = true;
            FileUtils.remove(in_path);
            foreach (var o in outputs) FileUtils.remove(Path.build_filename(dir, o));
            DirUtils.remove(dir);
            if (changed_now) changed();
            return changed_now;
        }
    }
}
