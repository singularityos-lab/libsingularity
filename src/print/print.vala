namespace Singularity.Print {

    /**
     * Hands a submitted job to the Printers service, which follows it
     * and posts a notification when it completes or fails. The service
     * is started on demand through D-Bus activation.
     */
    public class JobWatcher : Object {
        private static JobWatcher? instance;

        public const string SERVICE_ID = "dev.sinty.Printers";
        public const string SERVICE_PATH = "/dev/sinty/Printers";

        public static JobWatcher get_default() {
            if (instance == null) instance = new JobWatcher();
            return instance;
        }

        public void watch(Printer printer, int job_id, string title) {
            if (job_id <= 0) return;
            var param = new Variant("(sis)", printer.name, job_id, title);
            Bus.get.begin(BusType.SESSION, null, (obj, res) => {
                try {
                    var conn = Bus.get.end(res);
                    var args = new VariantBuilder(new VariantType("av"));
                    args.add("v", param);
                    conn.call.begin(SERVICE_ID, SERVICE_PATH, "org.gtk.Actions", "Activate",
                                    new Variant("(s@av@a{sv})", "watch-job", args.end(),
                                                new VariantBuilder(VariantType.VARDICT).end()),
                                    null, DBusCallFlags.NONE, 5000, null, (o, r) => {
                        try {
                            conn.call.end(r);
                        } catch (Error e) {
                            debug("Printers service unavailable: %s", e.message);
                        }
                    });
                } catch (Error e) {
                    debug("Session bus unavailable: %s", e.message);
                }
            });
        }
    }

    /**
     * Shows the Singularity print dialog for an application's
     * Gtk.PrintOperation. Drop-in for `op.run(PRINT_DIALOG, window)`:
     * the operation's `begin-print`, `paginate` and `draw-page` handlers
     * render the live preview and the printed pages. Returns APPLY when
     * the document was printed or saved, CANCEL otherwise.
     *
     * A Gtk.PrintOperation can lay out its pages only once. When the
     * page format changes in the dialog the pages are scaled onto the
     * new paper; pass a factory to `run_with_factory()` to let the
     * document reflow instead.
     */
    public async Gtk.PrintOperationResult run(Gtk.Window? window, Gtk.PrintOperation op) {
        var source = new OperationSource(op, window);
        var result = yield run_source(window, source, options_for(op));
        return result == DialogResult.PRINTED || result == DialogResult.SAVED
            ? Gtk.PrintOperationResult.APPLY : Gtk.PrintOperationResult.CANCEL;
    }

    /**
     * Like `run()`, with a factory that builds a fresh, fully connected
     * Gtk.PrintOperation. The dialog asks for a new one whenever the
     * paper size, orientation or margins change, so text reflows.
     */
    public async Gtk.PrintOperationResult run_with_factory(Gtk.Window? window, owned OperationFactory factory) {
        var source = new OperationSource.with_factory((owned) factory, window);
        var result = yield run_source(window, source, options_for(source.last_operation));
        return result == DialogResult.PRINTED || result == DialogResult.SAVED
            ? Gtk.PrintOperationResult.APPLY : Gtk.PrintOperationResult.CANCEL;
    }

    /**
     * Render-callback printing: `paginate` lays the document out for a
     * page format and returns the page count; `render` draws one page at
     * 72 dots per inch, origin at the top left of the paper. The format
     * carries the margins the user picked.
     */
    public async DialogResult run_callbacks(Gtk.Window? window, string title,
                                            owned PaginateFunc paginate, owned RenderPageFunc render,
                                            int current_page = -1, bool has_selection = false) {
        var source = new CallbackSource(title, (owned) paginate, (owned) render);
        source.current_page = current_page;
        source.has_selection = has_selection;
        return yield run_source(window, source);
    }

    /**
     * Shows the dialog for any page source and waits until it closes.
     */
    public async DialogResult run_source(Gtk.Window? window, PageSource source, JobOptions? initial = null) {
        string app_id = app_identifier();
        var options = initial ?? PresetStore.get_default().last_used(app_id) ?? new JobOptions();
        options.range_mode = RangeMode.ALL;
        options.ranges = "";
        options.copies = 1;
        options.output_path = "";
        var dialog = new PrintDialog(window, source, options, app_id);
        DialogResult result = DialogResult.CANCELLED;
        dialog.finished.connect((r) => {
            result = r;
            Idle.add(run_source.callback);
        });
        dialog.open_dialog();
        yield;
        return result;
    }

    private JobOptions? options_for(Gtk.PrintOperation? op) {
        if (op == null || op.default_page_setup == null) return null;
        var o = PresetStore.get_default().last_used(app_identifier()) ?? new JobOptions();
        var ps = op.default_page_setup;
        string keyword = Media.keyword_for_paper(ps.get_paper_size());
        if (o.media == "" || keyword != Media.default_keyword()) o.media = keyword;
        o.landscape = ps.get_orientation() == Gtk.PageOrientation.LANDSCAPE
            || ps.get_orientation() == Gtk.PageOrientation.REVERSE_LANDSCAPE;
        return o;
    }

    private string app_identifier() {
        var app = GLib.Application.get_default();
        if (app != null && app.application_id != null) return app.application_id;
        return Environment.get_prgname() ?? "default";
    }
}
