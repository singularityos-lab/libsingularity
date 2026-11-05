using Gtk;
using Singularity.Widgets;

int failures = 0;

void check(bool ok, string what) {
    print("%s %s\n", ok ? "ok" : "not ok", what);
    if (!ok) failures++;
}

class Named : Object {
    public string title { get; set; }

    public Named(string title) {
        Object(title: title);
    }
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

string shown(ChoiceButton button) {
    var box = (Box) button.child;
    return ((Label) box.get_first_child()).label;
}

int main(string[] args) {
    string dir = DirUtils.make_tmp("choice-test-XXXXXX");
    var display = start_display(dir);
    if (display == null) {
        print("1..0 # SKIP no display\n");
        return 0;
    }
    Gtk.init();

    var button = new ChoiceButton.from_strings({ "Sans", "Serif", "Mono" });
    int notified = 0;
    button.notify["selected"].connect(() => notified++);
    check(button.selected == 0 && shown(button) == "Sans", "selects the first entry");

    button.selected = 2;
    check(button.selected == 2 && shown(button) == "Mono" && notified == 1, "selecting updates the label and notifies once");
    button.selected = 2;
    check(notified == 1, "selecting the same entry does not notify");
    check(((StringObject) button.selected_item).string == "Mono", "selected_item is the chosen entry");

    button.selected = 9;
    check(button.selected == INVALID_LIST_POSITION && shown(button) == "", "an out of range index clears the selection");

    var list = new StringList(null);
    button.model = list;
    check(button.selected == INVALID_LIST_POSITION, "an empty model has no selection");
    list.append("One");
    check(button.selected == 0 && shown(button) == "One", "the first added entry is selected");
    list.splice(0, 0, { "Zero" });
    check(button.selected == 1 && shown(button) == "One", "an insertion before keeps the chosen entry");
    list.remove(1);
    check(button.selected == 0 && shown(button) == "Zero", "removing the chosen entry falls back to its neighbour");

    var store = new GLib.ListStore(typeof(Named));
    store.append(new Named("Alpha"));
    store.append(new Named("Beta"));
    var expr = new PropertyExpression(typeof(Named), null, "title");
    var named = new ChoiceButton(store, expr);
    named.selected = 1;
    check(shown(named) == "Beta", "an expression names object entries");

    var win = new Gtk.Window();
    win.child = named;
    win.present();
    named.clicked();
    var menu = named.get_last_child() as ContextMenu;
    check(menu != null && menu.visible, "clicking opens a context menu");

    display.send_signal(Posix.Signal.TERM);
    print("1..%d\n", failures == 0 ? 11 : failures);
    return failures == 0 ? 0 : 1;
}
