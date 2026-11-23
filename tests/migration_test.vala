using Gtk;
using Singularity.Migration;

int failures = 0;

void check(bool ok, string what) {
    print("%s %s\n", ok ? "ok" : "not ok", what);
    if (!ok) failures++;
}

Subprocess? start_display(string runtime_dir) {
    string? daemon = Environment.find_program_in_path("gtk4-broadwayd");
    if (daemon == null) return null;
    int number = 40 + (int) (Posix.getpid() % 400);
    try {
        var launcher = new SubprocessLauncher(SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
        launcher.setenv("XDG_RUNTIME_DIR", runtime_dir, true);
        var process = launcher.spawnv({ daemon, ":%d".printf(number), "-u", Path.build_filename(runtime_dir, "http.sock") });
        string socket = Path.build_filename(runtime_dir, "broadway%d.socket".printf(number + 1));
        for (int i = 0; i < 100 && !FileUtils.test(socket, FileTest.EXISTS); i++) Thread.usleep(20000);
        if (!FileUtils.test(socket, FileTest.EXISTS)) return null;
        Environment.set_variable("XDG_RUNTIME_DIR", runtime_dir, true);
        Environment.set_variable("GDK_BACKEND", "broadway", true);
        Environment.set_variable("GSK_RENDERER", "cairo", true);
        Environment.set_variable("BROADWAY_DISPLAY", ":%d".printf(number), true);
        return process;
    } catch (Error e) {
        return null;
    }
}

class Rich : TextView, Stateful {
    public Rich() {
        TextIter end;
        buffer.set_text("Picture here: ");
        buffer.get_end_iter(out end);
        buffer.create_child_anchor(end);
        buffer.get_end_iter(out end);
        buffer.insert(ref end, " and after", -1);
    }

    public bool has_anchor() {
        TextIter i;
        buffer.get_start_iter(out i);
        do {
            if (i.get_child_anchor() != null) return true;
        } while (i.forward_char());
        return false;
    }

    public Variant? save_widget_state() {
        TextIter ins;
        buffer.get_iter_at_mark(out ins, buffer.get_insert());
        return new Variant.int32(ins.get_offset());
    }

    public void restore_widget_state(Variant state) {
        TextIter at;
        buffer.get_iter_at_offset(out at, state.get_int32());
        buffer.place_cursor(at);
    }
}

class Editor : Gtk.ApplicationWindow {
    public TextView view;
    public Entry title;
    public Notebook tabs;
    public CheckButton wrap;
    public ListView list;
    public Paned split;
    public ScrolledWindow scroller;
    public Rich rich;
    public string document;

    public Editor(Gtk.Application app, string document) {
        Object(application: app);
        this.document = document;
        set_default_size(640, 480);
        split = new Paned(Orientation.HORIZONTAL);
        var strings = new StringList(null);
        for (int i = 0; i < 200; i++) strings.append("Row %d".printf(i));
        list = new ListView(new MultiSelection(strings), new SignalListItemFactory());
        ((SignalListItemFactory) list.factory).setup.connect((o) => ((ListItem) o).child = new Label(""));
        ((SignalListItemFactory) list.factory).bind.connect((o) => {
            var item = (ListItem) o;
            ((Label) item.child).label = ((StringObject) item.item).string;
        });
        var list_scroll = new ScrolledWindow();
        list_scroll.child = list;
        split.start_child = list_scroll;
        var right = new Box(Orientation.VERTICAL, 4);
        title = new Entry();
        right.append(title);
        wrap = new CheckButton.with_label("Wrap");
        right.append(wrap);
        tabs = new Notebook();
        view = new TextView();
        view.buffer.create_tag("bold", "weight", 700);
        scroller = new ScrolledWindow();
        scroller.vexpand = true;
        scroller.child = view;
        tabs.append_page(scroller, new Label("Text"));
        rich = new Rich();
        tabs.append_page(rich, new Label("Info"));
        right.append(tabs);
        split.end_child = right;
        child = split;
    }
}

class TestApp : Gtk.Application, Migratable {
    public string model_value = "";

    public TestApp() {
        Object(application_id: "dev.sinty.MigrationTest", flags: ApplicationFlags.NON_UNIQUE);
    }

    public Variant save_model() {
        return new Variant.string(model_value);
    }

    public async void restore_model(Variant model) throws Error {
        model_value = model.get_string();
    }

    public string window_kind(Gtk.Window window) {
        return (window is Editor) ? "editor" : "";
    }

    public Variant save_window(Gtk.Window window) {
        return new Variant.string(((Editor) window).document);
    }

    public async Gtk.Window? rebuild_window(string kind, Variant data) throws Error {
        return new Editor(this, data.get_string());
    }
}

void type_text(TextBuffer buffer, string text) {
    int index = 0;
    unichar c;
    while (text.get_next_char(ref index, out c)) {
        buffer.begin_user_action();
        buffer.insert_interactive_at_cursor(c.to_string(), -1, true);
        buffer.end_user_action();
    }
}

string text_of(TextBuffer b) {
    TextIter s, e;
    b.get_bounds(out s, out e);
    return b.get_text(s, e, true);
}

async void run_test(TestApp app) {
    check(Session.supported(app), "the toolkit can save undo history");
    var first = new Editor(app, "/home/demo/notes.txt");
    first.present();
    Timeout.add(200, run_test.callback);
    yield;

    var buffer = first.view.buffer;
    buffer.begin_irreversible_action();
    buffer.set_text("Loaded line\n");
    buffer.end_irreversible_action();
    TextIter end;
    buffer.get_end_iter(out end);
    buffer.place_cursor(end);
    type_text(buffer, "hello world\n");
    type_text(buffer, "second line here\n");
    for (int i = 0; i < 60; i++) type_text(buffer, "filler %d\n".printf(i));
    buffer.undo();
    buffer.undo();
    TextIter a, b;
    buffer.get_iter_at_offset(out a, 12);
    buffer.get_iter_at_offset(out b, 17);
    buffer.apply_tag_by_name("bold", a, b);
    buffer.select_range(a, b);
    first.title.text = "Draft title";
    first.title.select_region(2, 7);
    first.wrap.active = true;
    first.tabs.page = 0;
    first.split.position = 210;
    first.list.model.select_item(7, true);
    first.list.model.select_item(42, false);
    app.model_value = "model 1";
    TextIter rich_at;
    first.rich.buffer.get_iter_at_offset(out rich_at, 5);
    first.rich.buffer.place_cursor(rich_at);
    Timeout.add(300, run_test.callback);
    yield;
    first.scroller.vadjustment.value = 300;
    Timeout.add(100, run_test.callback);
    yield;

    Variant before;
    try {
        before = Session.capture(app);
    } catch (Error e) {
        check(false, "capture: " + e.message);
        app.quit();
        return;
    }
    check(before.is_of_type(new VariantType(Session.TYPE)), "the state has the session type");
    string undo_before = text_of(buffer);
    bool can_redo_before = buffer.can_redo;

    app.model_value = "";
    first.destroy();
    Report report;
    try {
        report = yield Session.restore(app, before);
    } catch (Error e) {
        check(false, "restore: " + e.message);
        app.quit();
        return;
    }
    foreach (var d in report.differences) print("# %s\n", d);
    check(report.exact, "every captured widget was found again");
    check(app.model_value == "model 1", "the app model came back");

    Editor? second = null;
    foreach (var w in app.get_windows()) if (w is Editor) second = (Editor) w;
    check(second != null, "the window was rebuilt");
    if (second == null) {
        app.quit();
        return;
    }
    var nb = second.view.buffer;
    check(text_of(nb) == undo_before, "the text is identical");
    check(nb.can_undo && nb.can_redo == can_redo_before, "undo and redo are available as before");
    TextIter ins, bound;
    nb.get_iter_at_mark(out ins, nb.get_insert());
    nb.get_iter_at_mark(out bound, nb.get_selection_bound());
    check(ins.get_offset() == 12 && bound.get_offset() == 17, "the selection is in the same place");
    TextIter t;
    nb.get_iter_at_offset(out t, 13);
    check(t.has_tag(nb.tag_table.lookup("bold")), "the bold range came back");
    check(second.title.text == "Draft title", "the entry text came back");
    int s1, s2;
    second.title.get_selection_bounds(out s1, out s2);
    check(s1 == 2 && s2 == 7, "the entry selection came back");
    check(second.wrap.active, "the check button came back");
    check(second.split.position == 210, "the pane position came back");
    var sel = second.list.model;
    check(sel.is_selected(7) && sel.is_selected(42) && !sel.is_selected(8), "the list selection came back");
    check(Math.fabs(second.scroller.vadjustment.value - 300) < 1, "the scroll position came back");
    TextIter rich_ins;
    second.rich.buffer.get_iter_at_mark(out rich_ins, second.rich.buffer.get_insert());
    check(second.rich.has_anchor() && rich_ins.get_offset() == 5, "a widget that keeps its own state keeps its embedded objects and gets its cursor back");
    bool generic = false;
    var rich_state = before.get_child_value(4).get_child_value(0).get_child_value(2).get_variant();
    for (size_t k = 0; k < rich_state.n_children(); k++) {
        var e = rich_state.get_child_value(k);
        var props = e.get_child_value(1);
        if (props.lookup_value("stateful", null) != null && props.lookup_value("text", null) != null) generic = true;
    }
    check(!generic, "the generic text capture leaves a self-managed text view alone");

    Variant after;
    try {
        after = Session.capture(app);
    } catch (Error e) {
        check(false, "second capture: " + e.message);
        app.quit();
        return;
    }
    var differences = new Gee.ArrayList<string>();
    Session.compare(before, after, differences);
    foreach (var d in differences) print("# %s\n", d);
    check(differences.size == 0, "capturing again gives the same state");

    var original = new TextBuffer(null);
    original.begin_irreversible_action();
    original.set_text("Loaded line\n");
    original.end_irreversible_action();
    TextIter oe;
    original.get_end_iter(out oe);
    original.place_cursor(oe);
    type_text(original, "hello world\n");
    type_text(original, "second line here\n");
    for (int i = 0; i < 60; i++) type_text(original, "filler %d\n".printf(i));
    original.undo();
    original.undo();
    bool same = true;
    int steps = 0;
    while (original.can_undo) {
        original.undo();
        nb.undo();
        steps++;
        if (text_of(original) != text_of(nb)) {
            same = false;
            break;
        }
    }
    check(same && !nb.can_undo, "undoing step by step matches the original (%d steps)".printf(steps));
    bool redo_same = true;
    while (original.can_redo) {
        original.redo();
        nb.redo();
        if (text_of(original) != text_of(nb)) {
            redo_same = false;
            break;
        }
    }
    check(redo_same && !nb.can_redo, "redoing step by step matches the original");
    app.quit();
}

int main(string[] args) {
    string runtime = DirUtils.make_tmp("migration-test-XXXXXX");
    Subprocess? display = null;
    if (Environment.get_variable("WAYLAND_DISPLAY") == null) display = start_display(runtime);
    if (display == null && Environment.get_variable("WAYLAND_DISPLAY") == null) {
        print("1..0 # SKIP gtk4-broadwayd is not available\n");
        return 77;
    }
    var app = new TestApp();
    app.activate.connect(() => {
        app.hold();
        run_test.begin(app, (o, r) => {
            run_test.end(r);
            app.release();
        });
    });
    app.run(args);
    if (display != null) display.force_exit();
    print("%s\n", failures == 0 ? "all ok" : "%d failures".printf(failures));
    return failures == 0 ? 0 : 1;
}
