using Gtk;
using Singularity.Widgets;

bool gtk_ready = false;

Subprocess? start_private_display(string runtime_dir) {
    string? daemon = Environment.find_program_in_path("gtk4-broadwayd");
    if (daemon == null) return null;
    int number = 40 + (int) (Posix.getpid() % 400);
    try {
        var launcher = new SubprocessLauncher(SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
        launcher.setenv("XDG_RUNTIME_DIR", runtime_dir, true);
        string[] argv = { daemon, ":%d".printf(number), "-u", Path.build_filename(runtime_dir, "http.sock") };
        string? timeout = Environment.find_program_in_path("timeout");
        if (timeout != null) argv = { timeout, "120", daemon, ":%d".printf(number), "-u", Path.build_filename(runtime_dir, "http.sock") };
        var process = launcher.spawnv(argv);
        string socket = Path.build_filename(runtime_dir, "broadway%d.socket".printf(number + 1));
        for (int i = 0; i < 100 && !FileUtils.test(socket, FileTest.EXISTS); i++) Thread.usleep(20000);
        if (!FileUtils.test(socket, FileTest.EXISTS)) {
            process.send_signal(Posix.Signal.TERM);
            return null;
        }
        Environment.set_variable("XDG_RUNTIME_DIR", runtime_dir, true);
        Environment.set_variable("DBUS_SESSION_BUS_ADDRESS", "unix:path=" + Path.build_filename(runtime_dir, "no-bus"), true);
        Environment.set_variable("GDK_BACKEND", "broadway", true);
        Environment.set_variable("GSK_RENDERER", "cairo", true);
        Environment.set_variable("BROADWAY_DISPLAY", ":%d".printf(number), true);
        return process;
    } catch (Error e) {
        return null;
    }
}

Banner make_banner() {
    var banner = new Banner("Make Browser your default web browser to open links from other apps here.");
    banner.icon_name = "web-browser-symbolic";
    banner.button_label = "Set as Default";
    banner.secondary_label = "Not Now";
    return banner;
}

Button[] buttons_of(Banner banner) {
    Button[] found = {};
    var stack = new GenericArray<Widget>();
    stack.add(banner);
    while (stack.length > 0) {
        var widget = stack[stack.length - 1];
        stack.remove_index(stack.length - 1);
        if (widget is Button) found += (Button) widget;
        for (var child = widget.get_last_child(); child != null; child = child.get_prev_sibling()) stack.add(child);
    }
    return found;
}

int row_width(Button[] buttons) {
    int total = 0;
    foreach (var button in buttons) {
        int min, nat;
        button.measure(Orientation.HORIZONTAL, -1, out min, out nat, null, null);
        total += nat;
    }
    return total + 8 * (buttons.length - 1);
}

Graphene.Rect bounds_in(Widget widget, Widget target) {
    Graphene.Rect rect;
    assert(widget.compute_bounds(target, out rect));
    return rect;
}

void test_minimum_is_one_button() {
    if (!gtk_ready) {
        Test.skip("no display");
        return;
    }
    var banner = make_banner();
    var buttons = buttons_of(banner);
    assert(buttons.length == 2);
    int widest = 0;
    foreach (var button in buttons) {
        int min, nat;
        button.measure(Orientation.HORIZONTAL, -1, out min, out nat, null, null);
        widest = int.max(widest, min);
    }
    int minimum, natural;
    banner.measure(Orientation.HORIZONTAL, -1, out minimum, out natural, null, null);
    assert(minimum < row_width(buttons));
    assert(minimum >= widest);
    assert(natural >= row_width(buttons));
}

void test_narrow_width_stacks() {
    if (!gtk_ready) {
        Test.skip("no display");
        return;
    }
    var banner = make_banner();
    var buttons = buttons_of(banner);
    int row = row_width(buttons);
    int wide_min, wide_nat, narrow_min, narrow_nat, banner_min, banner_nat;
    banner.measure(Orientation.HORIZONTAL, -1, out banner_min, out banner_nat, null, null);
    int wide = banner_nat + 200;
    banner.measure(Orientation.VERTICAL, wide, out wide_min, out wide_nat, null, null);
    int narrow = int.max(banner_min, row / 2 + 40);
    assert(narrow < row);
    banner.measure(Orientation.VERTICAL, narrow, out narrow_min, out narrow_nat, null, null);
    int button_min, button_nat;
    buttons[0].measure(Orientation.VERTICAL, -1, out button_min, out button_nat, null, null);
    assert(narrow_min >= wide_min + button_min);

    var window = new Gtk.Window();
    window.child = banner;
    window.present();
    banner.allocate(wide, wide_nat, -1, null);
    var secondary = bounds_in(buttons[0], banner);
    var main = bounds_in(buttons[1], banner);
    assert(buttons[1].has_css_class("suggested-action"));
    assert(Math.fabs(secondary.origin.y - main.origin.y) < 0.5);
    assert(main.origin.x > secondary.origin.x + secondary.size.width);

    banner.allocate(narrow, narrow_nat, -1, null);
    secondary = bounds_in(buttons[0], banner);
    main = bounds_in(buttons[1], banner);
    assert(main.origin.y >= secondary.origin.y + secondary.size.height);
    assert(Math.fabs(secondary.origin.x - main.origin.x) < 0.5);
    assert(Math.fabs(secondary.size.width - main.size.width) < 0.5);
    assert(main.origin.x + main.size.width <= narrow + 0.5);
    window.destroy();
}

void settle(int ms) {
    int64 until = get_monotonic_time() + ms * 1000;
    var context = MainContext.default();
    while (get_monotonic_time() < until) {
        while (context.pending()) context.iteration(false);
        Thread.usleep(5000);
    }
}

T? find_child<T>(Widget root) {
    var stack = new GenericArray<Widget>();
    stack.add(root);
    while (stack.length > 0) {
        var widget = stack[stack.length - 1];
        stack.remove_index(stack.length - 1);
        if (widget.get_type().is_a(typeof(T))) return (T) widget;
        for (var child = widget.get_last_child(); child != null; child = child.get_prev_sibling()) stack.add(child);
    }
    return null;
}

void check_selection_list(SelectionRow row, int width) {
    var window = new Gtk.Window();
    window.default_width = width;
    window.default_height = 900;
    var list_parent = new ListBox();
    list_parent.append(row);
    window.child = list_parent;
    window.present();
    settle(300);
    row.expanded = true;
    settle(900);
    var scrolled = find_child<ScrolledWindow>(row);
    var list = find_child<ListBox>(row);
    assert(scrolled != null && list != null);
    int parent_min, parent_nat;
    list_parent.measure(Orientation.VERTICAL, width, out parent_min, out parent_nat, null, null);
    list_parent.allocate(width, parent_nat, -1, null);
    assert(list.get_width() > 0);
    int list_min, list_nat;
    list.measure(Orientation.VERTICAL, list.get_width(), out list_min, out list_nat, null, null);
    assert(list_nat > 0);
    assert(scrolled.get_height() <= list_nat + 1);
    assert(scrolled.get_height() >= list_nat - 1);
    window.destroy();
}

void test_selection_row_fits_long_subtitles() {
    if (!gtk_ready) {
        Test.skip("no display");
        return;
    }
    var options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
    var smart = new Singularity.Core.AppSettingOption();
    smart.id = "smart";
    smart.label = "Hourly, Daily and Weekly Backups";
    smart.subtitle = "Every hour for a day, every day for a month, every week before that";
    options.add(smart);
    var fixed = new Singularity.Core.AppSettingOption();
    fixed.id = "keep-last";
    fixed.label = "A Fixed Number of Backups";
    fixed.subtitle = "The oldest are deleted first";
    options.add(fixed);
    check_selection_list(new SelectionRow.with_options("Keep", options, "smart"), 360);
    check_selection_list(new SelectionRow("Keep", { "Hourly, Daily and Weekly", "A Fixed Number" }, "A Fixed Number"), 360);
}

void test_selection_row_scrolls_long_lists() {
    if (!gtk_ready) {
        Test.skip("no display");
        return;
    }
    string[] items = {};
    for (int i = 0; i < 30; i++) items += "Choice %d".printf(i);
    var row = new SelectionRow("Many", items, items[0]);
    var window = new Gtk.Window();
    window.default_width = 360;
    window.default_height = 900;
    var list_parent = new ListBox();
    list_parent.append(row);
    window.child = list_parent;
    window.present();
    settle(300);
    row.expanded = true;
    settle(300);
    int parent_min, parent_nat;
    list_parent.measure(Orientation.VERTICAL, 360, out parent_min, out parent_nat, null, null);
    list_parent.allocate(360, parent_nat, -1, null);
    var scrolled = find_child<ScrolledWindow>(row);
    var list = find_child<ListBox>(row);
    assert(scrolled.get_height() > 100);
    assert(scrolled.get_height() <= 320 + 2);
    assert(list.get_height() > scrolled.get_height());
    window.destroy();
}

void test_switch_row_notifies_active() {
    if (!gtk_ready) {
        Test.skip("no display");
        return;
    }
    var row = new SwitchRow("Sync", null, false);
    int notified = 0;
    row.notify["active"].connect(() => notified++);
    row.switch_btn.active = true;
    assert(row.active);
    assert(notified == 1);
    row.active = false;
    assert(!row.switch_btn.active);
    assert(notified == 2);
    row.active = false;
    assert(notified == 2);
    settle(50);
    row.activated();
    assert(row.active);
    assert(notified == 3);
}

GestureDrag drag_of(Widget host) {
    var controllers = host.observe_controllers();
    for (uint i = 0; i < controllers.get_n_items(); i++) {
        var c = controllers.get_item(i) as GestureDrag;
        if (c != null) return c;
    }
    assert_not_reached();
}

void drag(GestureDrag gesture, double x, double y, double[] steps, uint step_ms) {
    var motion = Singularity.Motion.get_default();
    Signal.emit_by_name(gesture, "drag-begin", x, y);
    for (int i = 0; i + 1 < steps.length; i += 2) {
        motion.advance(step_ms);
        Signal.emit_by_name(gesture, "drag-update", steps[i], steps[i + 1]);
    }
    Signal.emit_by_name(gesture, "drag-end", steps[steps.length - 2], steps[steps.length - 1]);
    motion.advance(2000, 60);
}

EdgeSheet make_sheet(Box host) {
    var sheet = new EdgeSheet(host, PackType.START);
    var child = new Box(Orientation.VERTICAL, 0);
    child.set_size_request(200, -1);
    sheet.set_child(child);
    sheet.swipe.distance = 200;
    return sheet;
}

void test_edge_swipe_follows_finger() {
    if (!gtk_ready) { Test.skip("no display"); return; }
    var host = new Box(Orientation.VERTICAL, 0);
    var sheet = make_sheet(host);
    var gesture = drag_of(host);
    var motion = Singularity.Motion.get_default();
    motion.use_manual_clock(1000000);
    Signal.emit_by_name(gesture, "drag-begin", 4.0, 300.0);
    motion.advance(16);
    Signal.emit_by_name(gesture, "drag-update", 12.0, 1.0);
    assert_true(sheet.swipe.tracking);
    double start = sheet.swipe.progress;
    motion.advance(200);
    Signal.emit_by_name(gesture, "drag-update", 62.0, 3.0);
    assert_cmpfloat_with_epsilon(sheet.swipe.progress - start, 0.25, 0.001);
    motion.advance(200);
    Signal.emit_by_name(gesture, "drag-update", 132.0, 3.0);
    assert_cmpfloat_with_epsilon(sheet.swipe.progress - start, 0.6, 0.001);
    motion.advance(400);
    Signal.emit_by_name(gesture, "drag-update", 132.0, 3.0);
    Signal.emit_by_name(gesture, "drag-end", 132.0, 3.0);
    motion.advance(2000, 60);
    assert_true(sheet.swipe.is_open);
    assert_cmpfloat(sheet.swipe.progress, CompareOperator.EQ, 1.0);
    motion.use_frame_clock();
}

void test_edge_swipe_ignores_vertical_and_far_drags() {
    if (!gtk_ready) { Test.skip("no display"); return; }
    var host = new Box(Orientation.VERTICAL, 0);
    var sheet = make_sheet(host);
    var gesture = drag_of(host);
    Singularity.Motion.get_default().use_manual_clock(1000000);
    drag(gesture, 4, 300, { 3, 40, 6, 120 }, 16);
    assert_false(sheet.swipe.is_open);
    assert_cmpfloat(sheet.swipe.progress, CompareOperator.EQ, 0.0);
    drag(gesture, 150, 300, { 40, 0, 160, 0 }, 16);
    assert_false(sheet.swipe.is_open);
    sheet.can_open = false;
    drag(gesture, 4, 300, { 40, 0, 160, 0 }, 16);
    assert_false(sheet.swipe.is_open);
    Singularity.Motion.get_default().use_frame_clock();
}

void test_edge_swipe_flings_closed() {
    if (!gtk_ready) { Test.skip("no display"); return; }
    var host = new Box(Orientation.VERTICAL, 0);
    var sheet = make_sheet(host);
    var gesture = drag_of(host);
    Singularity.Motion.get_default().use_manual_clock(1000000);
    sheet.swipe.set_open(true, false);
    bool closed = false;
    sheet.swipe.settled.connect((open) => closed = !open);
    drag(gesture, 150, 300, { -12, 0, -30, 0, -50, 0 }, 16);
    assert_true(closed);
    assert_cmpfloat(sheet.swipe.progress, CompareOperator.EQ, 0.0);
    assert_false(sheet.revealed);
    Singularity.Motion.get_default().use_frame_clock();
}
void test_detail_pane_overlays_on_narrow_widths() {
    if (!gtk_ready) { Test.skip("no display"); return; }
    var main = new Box(Orientation.VERTICAL, 0);
    var panel = new Box(Orientation.VERTICAL, 0);
    var pane = new DetailPane(main);
    pane.panel_width = 400;
    pane.set_panel(panel);
    var window = new Gtk.Window();
    window.child = pane;
    window.present();
    var motion = Singularity.Motion.get_default();
    motion.use_manual_clock(1000000);
    pane.reveal_panel = true;
    motion.advance(2000, 60);
    assert_true(pane.panel_revealed);
    pane.allocate(1200, 800, -1, null);
    assert_false(pane.overlay_mode);
    assert_cmpint(main.get_width(), CompareOperator.EQ, 800);
    assert_cmpint(panel.get_width(), CompareOperator.EQ, 400);
    pane.allocate(420, 800, -1, null);
    assert_true(pane.overlay_mode);
    assert_cmpint(main.get_width(), CompareOperator.EQ, 420);
    assert_cmpint(panel.get_width(), CompareOperator.EQ, 420);
    bool closed = false;
    pane.panel_closed.connect(() => closed = true);
    pane.reveal_panel = false;
    motion.advance(2000, 60);
    assert_true(closed);
    assert_false(pane.panel_revealed);
    motion.use_frame_clock();
    window.destroy();
}

int main(string[] args) {
    Test.init(ref args);
    Log.set_always_fatal(LogLevelFlags.LEVEL_ERROR | LogLevelFlags.LEVEL_CRITICAL);
    Subprocess? display = null;
    string? runtime_dir = null;
    Environment.unset_variable("WAYLAND_DISPLAY");
    Environment.unset_variable("DISPLAY");
    try {
        runtime_dir = DirUtils.make_tmp("widget-layout-XXXXXX");
        string? user_runtime = Environment.get_variable("XDG_RUNTIME_DIR");
        if (runtime_dir.length > 80 && user_runtime != null) {
            DirUtils.remove(runtime_dir);
            runtime_dir = DirUtils.mkdtemp(Path.build_filename(user_runtime, "widget-layout-XXXXXX"));
        }
        display = start_private_display(runtime_dir);
    } catch (Error e) {
    }
    gtk_ready = display != null && Gtk.init_check();
    if (gtk_ready) Gtk.Settings.get_default().gtk_enable_animations = false;
    Test.add_func("/banner/minimum-is-one-button", test_minimum_is_one_button);
    Test.add_func("/banner/narrow-width-stacks", test_narrow_width_stacks);
    Test.add_func("/selection-row/fits-long-subtitles", test_selection_row_fits_long_subtitles);
    Test.add_func("/selection-row/scrolls-long-lists", test_selection_row_scrolls_long_lists);
    Test.add_func("/switch-row/notifies-active", test_switch_row_notifies_active);
    Test.add_func("/edge-swipe/follows-finger", test_edge_swipe_follows_finger);
    Test.add_func("/edge-swipe/ignores-vertical-and-far-drags", test_edge_swipe_ignores_vertical_and_far_drags);
    Test.add_func("/edge-swipe/flings-closed", test_edge_swipe_flings_closed);
    Test.add_func("/detail-pane/overlays-on-narrow-widths", test_detail_pane_overlays_on_narrow_widths);
    int result = Test.run();
    if (display != null) {
        display.send_signal(Posix.Signal.TERM);
        try {
            display.wait();
        } catch (Error e) {
        }
    }
    if (runtime_dir != null) {
        Dir? dir = null;
        try {
            dir = Dir.open(runtime_dir);
        } catch (Error e) {
        }
        string? name = null;
        while (dir != null && (name = dir.read_name()) != null) FileUtils.unlink(Path.build_filename(runtime_dir, name));
        DirUtils.remove(runtime_dir);
    }
    return result;
}
