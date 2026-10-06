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

Image? first_image(Widget root) {
    for (var c = root.get_first_child(); c != null; c = c.get_next_sibling()) {
        if (c is Image && ((Image) c).icon_name != "pan-down-symbolic") return (Image) c;
        var found = first_image(c);
        if (found != null) return found;
    }
    return null;
}

Label? first_label(Widget root) {
    for (var c = root.get_first_child(); c != null; c = c.get_next_sibling()) {
        if (c is Label) return (Label) c;
        var found = first_label(c);
        if (found != null) return found;
    }
    return null;
}

void test_style_keys() {
    assert(ToolbarStyle.from_key("compact") == ToolbarStyle.COMPACT);
    assert(ToolbarStyle.from_key("expanded") == ToolbarStyle.EXPANDED);
    assert(ToolbarStyle.from_key("text") == ToolbarStyle.TEXT_ONLY);
    assert(ToolbarStyle.from_key("bogus") == ToolbarStyle.COMPACT);
    assert(ToolbarStyle.from_key(null) == ToolbarStyle.COMPACT);
    assert(ToolbarStyle.TEXT_ONLY.to_key() == "text");
    assert(ToolbarSettings.path_for("dev.sinty.notes") == "/dev/sinty/toolbar/dev-sinty-notes/");
}

void test_item_faces() {
    if (!gtk_ready) {
        Test.skip("no display");
        return;
    }
    var ribbon = new ContextRibbon("test.ribbon.faces");
    var home = ribbon.add_context("home", "Home");
    var bold = home.add_button("format-text-bold-symbolic", "Bold");
    var picture = home.add_button("insert-image-symbolic", "Picture");
    picture.label_in_compact = true;
    var text_only = home.add_button(null, "Styles");
    var icon_only = home.add_button("edit-clear-all-symbolic", null, "Clear Formatting");

    assert(first_image(bold.widget).visible && !first_label(bold.widget).visible);
    assert(first_image(picture.widget).visible && first_label(picture.widget).visible);
    assert(!first_image(text_only.widget).visible && first_label(text_only.widget).visible);

    ribbon.toolbar_style = ToolbarStyle.EXPANDED;
    assert(ribbon.has_css_class("expanded"));
    assert(first_image(bold.widget).visible && first_label(bold.widget).visible);
    assert(first_image(icon_only.widget).visible && !first_label(icon_only.widget).visible);

    ribbon.toolbar_style = ToolbarStyle.TEXT_ONLY;
    assert(!first_image(bold.widget).visible && first_label(bold.widget).visible);
    assert(first_image(icon_only.widget).visible);

    var late = home.add_toggle("format-text-italic-symbolic", "Italic");
    assert(!first_image(late.widget).visible && first_label(late.widget).visible);

    ribbon.toolbar_style = ToolbarStyle.COMPACT;
    var color = home.add_menu("format-text-bold-symbolic", "Font Color");
    var swatch = new DrawingArea();
    color.set_face(swatch);
    assert(first_image(color.widget) == null);
    assert(swatch.visible && !first_label(color.widget).visible);
    ribbon.toolbar_style = ToolbarStyle.EXPANDED;
    assert(swatch.visible && first_label(color.widget).visible);
    ribbon.toolbar_style = ToolbarStyle.TEXT_ONLY;
    assert(!swatch.visible && first_label(color.widget).visible);
}

void test_tooltips() {
    if (!gtk_ready) {
        Test.skip("no display");
        return;
    }
    var ribbon = new ContextRibbon("test.ribbon.tips");
    var home = ribbon.add_context("home", "Home");
    var bold = home.add_toggle("format-text-bold-symbolic", "Bold");
    bold.shortcut = "Ctrl+B";
    assert(bold.widget.tooltip_text == "Bold (Ctrl+B)");
    var hl = home.add_menu("notes-marker-symbolic", "Highlight", "Highlight (Ctrl+Shift+H)");
    hl.shortcut = "Ctrl+Shift+H";
    assert(hl.widget.tooltip_text == "Highlight (Ctrl+Shift+H)");
    var clear = home.add_button("edit-clear-all-symbolic", null, "Clear Formatting");
    assert(clear.widget.tooltip_text == "Clear Formatting");
}

void test_selector() {
    if (!gtk_ready) {
        Test.skip("no display");
        return;
    }
    var ribbon = new ContextRibbon("test.ribbon.selector");
    var home = ribbon.add_context("home", "Home");
    var size = home.add_selector("Font Size", 3);
    size.add_option("11", "11");
    size.add_option("14", "14");
    size.text = "11";
    assert(size.text == "11");
    size.selected = "14";
    assert(size.text == "14");
    size.text = "9";
    assert(size.selected == "14" && size.text == "9");
}

void test_toggle_state() {
    if (!gtk_ready) {
        Test.skip("no display");
        return;
    }
    var ribbon = new ContextRibbon("test.ribbon.toggle");
    var home = ribbon.add_context("home", "Home");
    var bold = home.add_toggle("format-text-bold-symbolic", "Bold");
    bool seen = false;
    bold.toggled.connect((a) => seen = a);
    bold.active = true;
    assert(seen && bold.button.active);
    assert((bold.button.get_state_flags() & StateFlags.CHECKED) != 0);
}

void test_contexts() {
    if (!gtk_ready) {
        Test.skip("no display");
        return;
    }
    var ribbon = new ContextRibbon("test.ribbon.contexts");
    ribbon.add_context("home", "Home");
    ribbon.add_context("insert", "Insert");
    assert(ribbon.active_context == "home");
    int tabs = 0;
    for (var c = ribbon.tabs.get_first_child(); c != null; c = c.get_next_sibling()) tabs++;
    assert(tabs == 2);
    assert(ribbon.tabs.active_option == "home");
    string? changed = null;
    ribbon.context_changed.connect((id) => changed = id);
    ribbon.tabs.set_active("insert");
    assert(ribbon.active_context == "insert" && changed == "insert");
    ribbon.active_context = "home";
    assert(ribbon.tabs.active_option == "home");
    ribbon.active_context = "missing";
    assert(ribbon.active_context == "home");
    assert(ribbon.get_context("home") != null && ribbon.get_context("nope") == null);
}

void test_tabs_in_ribbon() {
    if (!gtk_ready) {
        Test.skip("no display");
        return;
    }
    var ribbon = new ContextRibbon("test.ribbon.tabrow");
    ribbon.add_context("home", "Home");
    ribbon.add_context("insert", "Insert");
    Widget row = ribbon.get_first_child();
    assert(row.has_css_class("context-ribbon-tab-row"));
    assert(!row.visible);
    var titlebar = new Box(Orientation.HORIZONTAL, 0);
    var before = new Label("before");
    var after = new Label("after");
    titlebar.append(before);
    titlebar.append(ribbon.tabs);
    titlebar.append(after);

    ribbon.tabs_in_ribbon = true;
    assert(ribbon.tabs.get_parent() == row);
    assert(row.visible);
    assert(before.get_next_sibling() == after);
    ribbon.tabs.visible = false;
    assert(!row.visible);
    ribbon.tabs.visible = true;
    assert(row.visible);
    ribbon.tabs.set_active("insert");
    assert(ribbon.active_context == "insert");

    ribbon.tabs_in_ribbon = false;
    assert(ribbon.tabs.get_parent() == titlebar);
    assert(before.get_next_sibling() == ribbon.tabs && ribbon.tabs.get_next_sibling() == after);
    assert(!row.visible);
}

int visible_items(Widget strip) {
    int n = 0;
    for (var c = strip.get_first_child(); c != null; c = c.get_next_sibling()) {
        if (c.has_css_class("context-ribbon-more")) continue;
        if (c.get_child_visible()) n++;
    }
    return n;
}

Widget? more_of(Widget strip) {
    for (var c = strip.get_first_child(); c != null; c = c.get_next_sibling())
        if (c.has_css_class("context-ribbon-more")) return c;
    return null;
}

void test_overflow() {
    if (!gtk_ready) {
        Test.skip("no display");
        return;
    }
    var ribbon = new ContextRibbon("test.ribbon.overflow");
    var home = ribbon.add_context("home", "Home");
    for (int i = 0; i < 12; i++) {
        home.add_button("format-text-bold-symbolic", "Item %d".printf(i));
        if (i == 5) home.add_separator();
    }
    var strip = ribbon.stack.get_child_by_name("home");
    int min, nat;
    strip.measure(Orientation.HORIZONTAL, -1, out min, out nat, null, null);
    int mmin, mnat;
    more_of(strip).measure(Orientation.HORIZONTAL, -1, out mmin, out mnat, null, null);
    assert(min == mnat);
    assert(nat > min * 6);

    strip.allocate(nat, 40, -1, null);
    assert(visible_items(strip) == 13);
    assert(!more_of(strip).get_child_visible());

    strip.allocate(nat / 2, 40, -1, null);
    int shown = visible_items(strip);
    assert(shown > 0 && shown < 13);
    assert(more_of(strip).get_child_visible());
    Widget? last = null;
    for (var c = strip.get_first_child(); c != null; c = c.get_next_sibling())
        if (c.get_child_visible() && !c.has_css_class("context-ribbon-more")) last = c;
    assert(!(last is Separator));

    strip.allocate(min, 40, -1, null);
    assert(more_of(strip).get_child_visible());
}

void test_sidebar_tabs() {
    if (!gtk_ready) {
        Test.skip("no display");
        return;
    }
    var stack = new Stack();
    stack.add_titled(new Label("a"), "layer", "Layer");
    stack.add_titled(new Label("b"), "text", "Text");
    var tabs = new SidebarTabs(stack);
    assert(tabs.has_css_class("sidebar-tabs"));
    assert(tabs.has_css_class("bubble-switcher"));
    assert(tabs.homogeneous && tabs.halign == Align.FILL);
    tabs.set_active("text");
    assert(stack.visible_child_name == "text");
    tabs.reserve_bubble_band = true;
    assert(tabs.margin_top == 0);
    tabs.reserve_bubble_band = false;
    assert(tabs.margin_top == 0);
}

void test_settings_registration() {
    string? dir = Environment.get_variable("GSETTINGS_SCHEMA_DIR");
    if (dir == null || Singularity.Core.safe_settings(ToolbarSettings.REGISTRY_SCHEMA_ID) == null) {
        Test.skip("schemas not compiled");
        return;
    }
    assert(!ToolbarSettings.is_registered("test.ribbon.registry"));
    ToolbarSettings.register("test.ribbon.registry");
    ToolbarSettings.register("test.ribbon.registry");
    assert(ToolbarSettings.is_registered("test.ribbon.registry"));
    var registry = Singularity.Core.safe_settings(ToolbarSettings.REGISTRY_SCHEMA_ID);
    int count = 0;
    foreach (unowned string a in registry.get_strv("apps")) if (a == "test.ribbon.registry") count++;
    assert(count == 1);

    var descriptor = Singularity.Core.AppSettingsLoader.load_for_app("test.ribbon.registry.desktop");
    assert(descriptor != null);
    Singularity.Core.AppSettingItem? item = null;
    foreach (var it in descriptor.items) if (it.key == "toolbar-style") item = it;
    assert(item != null);
    assert(item.schema_id == ToolbarSettings.SCHEMA_ID);
    assert(item.path == "/dev/sinty/toolbar/test-ribbon-registry/");
    assert(item.widget == "combo" && item.options.size == 3);
    var s = Singularity.Core.AppSettingsLoader.settings_for(descriptor, item);
    assert(s != null && s.get_string("toolbar-style") == "compact");
    s.set_string("toolbar-style", "expanded");
    var app_side = ToolbarSettings.for_app("test.ribbon.registry");
    assert(app_side.get_string("toolbar-style") == "expanded");
    assert(Singularity.Core.AppSettingsLoader.load_for_app("test.ribbon.unregistered") == null);

    if (!gtk_ready) return;
    var ribbon = new ContextRibbon("test.ribbon.registry");
    ribbon.add_context("home", "Home");
    assert(ribbon.toolbar_style == ToolbarStyle.EXPANDED);
    app_side.set_string("toolbar-style", "text");
    assert(ribbon.toolbar_style == ToolbarStyle.TEXT_ONLY);
}

int main(string[] args) {
    Test.init(ref args);
    Log.set_always_fatal(LogLevelFlags.LEVEL_ERROR | LogLevelFlags.LEVEL_CRITICAL);
    Subprocess? display = null;
    string? runtime_dir = null;
    Environment.unset_variable("WAYLAND_DISPLAY");
    Environment.unset_variable("DISPLAY");
    try {
        runtime_dir = DirUtils.make_tmp("context-ribbon-XXXXXX");
        string? user_runtime = Environment.get_variable("XDG_RUNTIME_DIR");
        if (runtime_dir.length > 80 && user_runtime != null) {
            DirUtils.remove(runtime_dir);
            runtime_dir = DirUtils.mkdtemp(Path.build_filename(user_runtime, "context-ribbon-XXXXXX"));
        }
        display = start_private_display(runtime_dir);
    } catch (Error e) {
    }
    gtk_ready = display != null && Gtk.init_check();
    if (gtk_ready) Gtk.Settings.get_default().gtk_enable_animations = false;
    Test.add_func("/context-ribbon/style-keys", test_style_keys);
    Test.add_func("/context-ribbon/item-faces", test_item_faces);
    Test.add_func("/context-ribbon/tooltips", test_tooltips);
    Test.add_func("/context-ribbon/selector", test_selector);
    Test.add_func("/context-ribbon/toggle-state", test_toggle_state);
    Test.add_func("/context-ribbon/contexts", test_contexts);
    Test.add_func("/context-ribbon/overflow", test_overflow);
    Test.add_func("/context-ribbon/tabs-in-ribbon", test_tabs_in_ribbon);
    Test.add_func("/context-ribbon/settings-registration", test_settings_registration);
    Test.add_func("/sidebar-tabs/basics", test_sidebar_tabs);
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
