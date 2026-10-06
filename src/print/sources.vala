namespace Singularity.Print {

    /**
     * The page geometry a source paginates for: paper size in points in
     * the chosen orientation and the margins of the printable area.
     */
    public class PageFormat : Object {
        public string media { get; set; default = "iso_a4_210x297mm"; }
        public bool landscape { get; set; }
        public double width { get; set; default = 595.3; }
        public double height { get; set; default = 841.9; }
        public double margin_top { get; set; }
        public double margin_bottom { get; set; }
        public double margin_left { get; set; }
        public double margin_right { get; set; }

        public double content_width {
            get { return width - margin_left - margin_right; }
        }

        public double content_height {
            get { return height - margin_top - margin_bottom; }
        }

        public static PageFormat from_options(JobOptions o, PrinterCapabilities? caps) {
            var f = new PageFormat();
            f.media = o.media != "" ? o.media : Media.default_keyword();
            f.landscape = o.landscape;
            double w, h, t, b, l, r;
            o.geometry(out w, out h);
            o.margins_pt(caps, out t, out b, out l, out r);
            f.width = w;
            f.height = h;
            f.margin_top = t;
            f.margin_bottom = b;
            f.margin_left = l;
            f.margin_right = r;
            return f;
        }

        public bool same_layout(PageFormat? other) {
            if (other == null) return false;
            return (width - other.width).abs() < 0.5 && (height - other.height).abs() < 0.5
                && (margin_top - other.margin_top).abs() < 0.5 && (margin_bottom - other.margin_bottom).abs() < 0.5
                && (margin_left - other.margin_left).abs() < 0.5 && (margin_right - other.margin_right).abs() < 0.5;
        }

        public Gtk.PageSetup to_page_setup() {
            var ps = new Gtk.PageSetup();
            ps.set_paper_size(Media.paper_size(media));
            ps.set_orientation(landscape ? Gtk.PageOrientation.LANDSCAPE : Gtk.PageOrientation.PORTRAIT);
            ps.set_top_margin(margin_top, Gtk.Unit.POINTS);
            ps.set_bottom_margin(margin_bottom, Gtk.Unit.POINTS);
            ps.set_left_margin(margin_left, Gtk.Unit.POINTS);
            ps.set_right_margin(margin_right, Gtk.Unit.POINTS);
            return ps;
        }
    }

    /**
     * Where printed pages come from. A source paginates for a page
     * format and then draws any of its pages at 72 dots per inch with
     * the origin at the top left corner of the paper.
     */
    public abstract class PageSource : Object {
        public string title { get; set; default = ""; }
        public int current_page { get; set; default = -1; }
        public bool has_selection { get; set; }
        public bool print_selection { get; set; }
        public double page_width { get; protected set; default = 595.3; }
        public double page_height { get; protected set; default = 841.9; }
        public ExtraOptions? extra_options { get; set; }
        public int document_pages { get; protected set; default = -1; }
        public int[] page_selection = {};

        public virtual bool imposes_pages {
            get { return false; }
        }

        /** Whether a new page format makes the source lay itself out again. */
        public virtual bool can_reflow {
            get { return true; }
        }

        public abstract async int paginate(PageFormat format) throws Error;
        public abstract void render_page(Cairo.Context cr, int index);
    }

    public delegate int PaginateFunc(PageFormat format);
    public delegate void RenderPageFunc(Cairo.Context cr, int page, PageFormat format);

    /**
     * A source backed by two callbacks: one that lays the document out
     * for a format and returns the page count, one that draws a page.
     */
    public class CallbackSource : PageSource {
        private PaginateFunc paginate_func;
        private RenderPageFunc render_func;
        private PageFormat format = new PageFormat();

        public CallbackSource(string title, owned PaginateFunc paginate, owned RenderPageFunc render) {
            this.title = title;
            paginate_func = (owned) paginate;
            render_func = (owned) render;
        }

        public override async int paginate(PageFormat format) throws Error {
            this.format = format;
            page_width = format.width;
            page_height = format.height;
            return paginate_func(format);
        }

        public override void render_page(Cairo.Context cr, int index) {
            render_func(cr, index, format);
        }
    }

    public delegate Gtk.PrintOperation OperationFactory();

    /**
     * A source that drives an application's Gtk.PrintOperation through
     * its preview interface and records every page as vector drawing.
     * An operation can run only once; with a factory the dialog makes a
     * fresh operation whenever the page format changes, so the document
     * reflows. Without one, later formats reuse the first layout and the
     * pages are scaled onto the new paper.
     */
    public class OperationSource : PageSource {
        private Gtk.PrintOperation? op;
        private OperationFactory? factory;
        private Gtk.Window? parent;
        private Gee.ArrayList<Cairo.RecordingSurface> pages = new Gee.ArrayList<Cairo.RecordingSurface>();
        private bool used;

        public Gtk.PrintOperation? last_operation { get; private set; }

        public override bool can_reflow {
            get { return factory != null || !used; }
        }

        public OperationSource(Gtk.PrintOperation op, Gtk.Window? parent) {
            this.op = op;
            this.parent = parent;
            read_operation(op);
        }

        public OperationSource.with_factory(owned OperationFactory factory, Gtk.Window? parent) {
            this.factory = (owned) factory;
            this.parent = parent;
            read_operation(this.factory());
        }

        private void read_operation(Gtk.PrintOperation o) {
            op = o;
            last_operation = o;
            title = o.job_name ?? "";
            current_page = o.current_page;
            has_selection = o.has_selection;
        }

        public override async int paginate(PageFormat format) throws Error {
            if (used && factory == null) return pages.size;
            Gtk.PrintOperation current;
            if (used) {
                current = factory();
            } else {
                current = op;
            }
            used = true;
            last_operation = current;
            pages.clear();
            page_width = format.width;
            page_height = format.height;
            current.default_page_setup = format.to_page_setup();
            current.use_full_page = false;
            current.unit = Gtk.Unit.POINTS;
            var settings = current.print_settings ?? new Gtk.PrintSettings();
            settings.set_print_pages(print_selection ? Gtk.PrintPages.SELECTION : Gtk.PrintPages.ALL);
            current.print_settings = settings;
            Error? failure = null;
            ulong handler = current.preview.connect((preview, context, win) => {
                var scratch = new Cairo.RecordingSurface(Cairo.Content.COLOR_ALPHA, null);
                context.set_cairo_context(new Cairo.Context(scratch), 72, 72);
                preview.ready.connect((ctx) => {
                    int n = current.n_pages;
                    for (int i = 0; i < n; i++) {
                        var extents = Cairo.Rectangle() { x = 0, y = 0, width = format.width, height = format.height };
                        var surface = new Cairo.RecordingSurface(Cairo.Content.COLOR_ALPHA, extents);
                        ctx.set_cairo_context(new Cairo.Context(surface), 72, 72);
                        preview.render_page(i);
                        pages.add(surface);
                    }
                    preview.end_preview();
                });
                return true;
            });
            try {
                current.run(Gtk.PrintOperationAction.PREVIEW, parent);
            } catch (Error e) {
                failure = e;
            }
            current.disconnect(handler);
            if (failure != null) throw failure;
            return pages.size;
        }

        public override void render_page(Cairo.Context cr, int index) {
            if (index < 0 || index >= pages.size) return;
            cr.set_source_surface(pages[index], 0, 0);
            cr.paint();
        }
    }
}
