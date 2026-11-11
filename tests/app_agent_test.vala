using Gtk;
using Singularity.Widgets;

const string IFACE = "dev.sinty.AppAgent1";
const string PATH = "/dev/sinty/AgentTest";

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

int failures = 0;

void check(bool ok, string what) {
    print("%s %s\n", ok ? "ok" : "not ok", what);
    if (!ok) failures++;
}

async Json.Object? call(DBusConnection bus, string intent, string args) {
    try {
        var r = yield bus.call(bus.unique_name, PATH, IFACE, "Invoke", new Variant("(ss)", intent, args),
            new VariantType("(s)"), DBusCallFlags.NONE, 5000, null);
        return Json.from_string(r.get_child_value(0).get_string()).get_object();
    } catch (Error e) {
        print("# %s: %s\n", intent, e.message);
        return null;
    }
}

async Json.Array? call_list(DBusConnection bus, string intent) {
    try {
        var r = yield bus.call(bus.unique_name, PATH, IFACE, "Invoke", new Variant("(ss)", intent, "{}"),
            new VariantType("(s)"), DBusCallFlags.NONE, 5000, null);
        return Json.from_string(r.get_child_value(0).get_string()).get_array();
    } catch (Error e) {
        print("# %s: %s\n", intent, e.message);
        return null;
    }
}

async void run_checks(Singularity.Application app, DBusConnection bus, Gtk.Window win, RibbonToggle toggle, TextView doc, int[] counters) {
    var actions = yield call_list(bus, "app_actions");
    bool saw_bold = false, saw_hello = false;
    if (actions != null) {
        foreach (var n in actions.get_elements()) {
            var o = n.get_object();
            if (o.get_string_member("name") == "win.bold") saw_bold = true;
            if (o.get_string_member("name") == "app.hello") saw_hello = !o.get_boolean_member("needs_confirmation");
        }
    }
    check(saw_bold && saw_hello, "app_actions lists app and window actions");

    var r = yield call(bus, "app_action", "{\"name\":\"app.hello\"}");
    check(r != null && counters[0] == 1, "app_action runs an app action");

    r = yield call(bus, "app_action", "{\"name\":\"win.bold\"}");
    check(r != null && r.get_string_member("state") == "true" && r.get_boolean_member("state_changed"), "app_action reads back a stateful action");

    r = yield call(bus, "app_action", "{\"name\":\"app.delete-all\"}");
    check(r == null && counters[1] == 0, "app_action refuses an irreversible action");

    r = yield call(bus, "app_action_confirmed", "{\"name\":\"app.delete-all\"}");
    check(r != null && counters[1] == 1, "app_action_confirmed runs it");

    var cmds = yield call_list(bus, "app_commands");
    string bid = "", tid = "", mid = "", sid = "";
    if (cmds != null) {
        foreach (var n in cmds.get_elements()) {
            var o = n.get_object();
            string label = o.get_string_member("label");
            if (label == "Insert Row") bid = o.get_string_member("id");
            if (label == "Wrap Text") tid = o.get_string_member("id");
            if (label == "Borders") mid = o.get_string_member("id");
            if (o.get_string_member("kind") == "choice") sid = o.get_string_member("id");
        }
    }
    check(bid != "" && tid != "" && mid != "" && sid != "", "app_commands lists button, toggle, menu and choice");

    r = yield call(bus, "app_command", "{\"id\":\"%s\"}".printf(bid));
    check(r != null && counters[2] == 1, "app_command presses a button");

    r = yield call(bus, "app_command", "{\"id\":\"%s\",\"on\":true}".printf(tid));
    check(r != null && toggle.active && r.get_boolean_member("verified"), "app_command turns a toggle on");

    r = yield call(bus, "app_command", "{\"id\":\"%s\",\"entry\":\"Thick > Bottom\"}".printf(mid));
    check(r != null && counters[3] == 1, "app_command opens a submenu entry");

    r = yield call(bus, "app_command", "{\"id\":\"%s\",\"option\":\"Arial\"}".printf(sid));
    check(r != null && r.get_string_member("selected") == "arial", "app_command picks a choice");

    r = yield call(bus, "app_command", "{\"id\":\"missing\"}");
    check(r == null, "app_command refuses an unknown id");

    r = yield call(bus, "app_read", "{\"offset\":6,\"limit\":5}");
    check(r != null && r.get_string_member("text") == "world" && r.get_int_member("length") == 17 && r.get_boolean_member("more"), "app_read pages the document");

    r = yield call(bus, "app_edit", "{\"find\":\"world\",\"replace\":\"there\"}");
    check(r != null && r.get_boolean_member("verified") && doc.buffer.text == "hello there, mars", "app_edit replaces and reads back");

    doc.buffer.undo();
    check(doc.buffer.text == "hello world, mars", "Ctrl+Z undoes an app_edit");

    r = yield call(bus, "app_edit", "{\"find\":\"pluto\",\"replace\":\"x\"}");
    check(r == null && doc.buffer.text == "hello world, mars", "app_edit refuses a missing match");

    r = yield call(bus, "app_batch", "{\"steps\":[{\"intent\":\"app_action\",\"args\":{\"name\":\"app.hello\"}},{\"intent\":\"app_edit\",\"args\":{\"text\":\"new\"}}]}");
    check(r != null && r.get_int_member("done") == 2 && r.get_boolean_member("verified") && counters[0] == 2 && doc.buffer.text == "new", "app_batch runs steps in order");

    r = yield call(bus, "app_batch", "{\"steps\":[{\"intent\":\"app_action\",\"args\":{\"name\":\"app.hello\"}},{\"intent\":\"app_action_confirmed\",\"args\":{\"name\":\"app.delete-all\"}}]}");
    check(r == null && counters[0] == 2 && counters[1] == 1, "app_batch refuses an irreversible step before running anything");

    win.destroy();
    app.quit();
}

int main(string[] args) {
    string dir = DirUtils.make_tmp("agent-test-XXXXXX");
    var display = start_display(dir);
    if (display == null) {
        print("1..0 # SKIP no display\n");
        return 0;
    }
    var app = new Singularity.Application("dev.sinty.AgentTest", ApplicationFlags.FLAGS_NONE);
    int[] counters = { 0, 0, 0, 0 };
    var hello = new SimpleAction("hello", null);
    hello.activate.connect(() => counters[0]++);
    var nuke = new SimpleAction("delete-all", null);
    nuke.activate.connect(() => counters[1]++);
    app.activate.connect(() => {
        app.add_action(hello);
        app.add_action(nuke);
        var win = new ApplicationWindow(app);
        win.add_action(new SimpleAction.stateful("bold", null, new Variant.boolean(false)));
        var ribbon = new ContextRibbon("dev.sinty.AgentTest");
        var home = ribbon.add_context("home", "Home");
        var insert = home.add_button("list-add-symbolic", "Insert Row");
        insert.activated.connect(() => counters[2]++);
        var toggle = home.add_toggle("format-text-wrap-symbolic", "Wrap Text");
        var borders = home.add_menu("format-border-symbolic", "Borders");
        borders.set_builder((m) => {
            m.add_item("None", null, () => {});
            var thick = m.add_submenu("Thick", null);
            thick.add_item("Bottom", null, () => counters[3]++);
        });
        var font = home.add_selector("Font", 10);
        font.add_option("sans", "Sans");
        font.add_option("arial", "Arial");
        var doc = new TextView();
        doc.buffer.text = "hello world, mars";
        var box = new Box(Orientation.VERTICAL, 0);
        box.append(ribbon);
        box.append(doc);
        win.child = box;
        win.present();
        Bus.own_name_on_connection(app.get_dbus_connection(), "dev.sinty.Agent", BusNameOwnerFlags.NONE,
            (c, n) => run_checks.begin(app, c, win, toggle, doc, counters), null);
        app.hold();
    });
    app.run(args);
    display.send_signal(Posix.Signal.TERM);
    print("1..%d\n", failures == 0 ? 17 : failures);
    return failures == 0 ? 0 : 1;
}
