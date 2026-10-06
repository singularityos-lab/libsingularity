using Singularity;

string data_home;

void write_file(string path, string contents) {
    try {
        DirUtils.create_with_parents(Path.get_dirname(path), 0755);
        FileUtils.set_contents(path, contents);
    } catch (Error e) {
        error("%s", e.message);
    }
}

void test_find_data_files() {
    write_file(Path.build_filename(data_home, "singularity", "files-actions", "a.ini"), "[Files Action]\n");
    write_file(Path.build_filename(data_home, "singularity", "files-actions", "b.txt"), "");
    var found = Runtime.find_data_files("singularity/files-actions", ".ini");
    bool has_a = false;
    foreach (var path in found) {
        assert(path.has_suffix(".ini"));
        if (path == Path.build_filename(data_home, "singularity", "files-actions", "a.ini")) has_a = true;
    }
    assert(has_a);
}

void test_file_action_matching() {
    var action = new FileAction("test.images", "Scan", null, { "image/*", "text/plain", "application/x-cd-image" });
    var file = File.new_for_path("/nonexistent");
    assert(action.matches(file, "image/png"));
    assert(action.matches(file, "text/plain"));
    assert(action.matches(file, "text/markdown"));
    assert(action.matches(file, "application/x-cd-image"));
    assert(!action.matches(file, "application/pdf"));
    assert(!action.matches(file, null));

    action.multiple = false;
    assert(action.matches_all({ file }, { "image/png" }));
    assert(!action.matches_all({ file, file }, { "image/png", "image/png" }));
    action.multiple = true;
    assert(action.matches_all({ file, file }, { "image/png", "image/jpeg" }));
    assert(!action.matches_all({ file, file }, { "image/png", "application/pdf" }));

    var any = new FileAction("test.any", "Any", null, {});
    assert(any.matches(file, "application/pdf"));
}

void test_declarative_file_action() {
    string path = Path.build_filename(data_home, "singularity", "files-actions", "dev.sinty.test.write.ini");
    write_file(path, "[Files Action]\nName=Write to a Drive\nIcon=drive-removable-media-symbolic\n" +
        "MimeTypes=application/x-cd-image;application/x-raw-disk-image;\nMultipleFiles=false\n" +
        "AppId=dev.sinty.drivewriter\nAction=write-image\n");
    var action = DeclarativeFileAction.from_file(path);
    assert(action != null);
    assert(action.id == "dev.sinty.test.write");
    assert(action.label == "Write to a Drive");
    assert(action.icon_name == "drive-removable-media-symbolic");
    assert(action.app_id == "dev.sinty.drivewriter");
    assert(action.app_action == "write-image");
    assert(action.command_line == null);
    assert(!action.multiple);
    assert(action.mime_types.length == 2);

    string bad = Path.build_filename(data_home, "singularity", "files-actions", "bad.ini");
    write_file(bad, "[Files Action]\nName=Nothing to run\n");
    Test.expect_message(null, LogLevelFlags.LEVEL_WARNING, "*needs AppId or Exec*");
    assert(DeclarativeFileAction.from_file(bad) == null);
    Test.assert_expected_messages();
    FileUtils.remove(bad);
}

void test_search_meta_dict() {
    var meta = new SearchResultMeta("acct-1", "GitHub");
    meta.description = "alice@example.com";
    meta.icon = new ThemedIcon("dialog-password-symbolic");
    meta.preview_color = "#3584e4";
    meta.add_action("copy", "Copy", "edit-copy-symbolic");
    meta.add_action("open", "Open");
    var dict = meta.to_dict();
    assert(dict["id"].get_string() == "acct-1");
    assert(dict["name"].get_string() == "GitHub");
    assert(dict["description"].get_string() == "alice@example.com");
    assert(dict["preview-color"].get_string() == "#3584e4");
    assert(Icon.deserialize(dict["icon"]).equal(new ThemedIcon("dialog-password-symbolic")));
    var actions = dict["actions"];
    assert(actions.n_children() == 2);
    string id, label, icon;
    actions.get_child(1, "(sss)", out id, out label, out icon);
    assert(id == "open" && label == "Open" && icon == "");
    assert(!dict.contains("preview-text"));
}

void test_activation_reply_dict() {
    var reply = SearchActivationReply.copy("123456", true, 30);
    var dict = reply.to_dict();
    assert(dict["copy-text"].get_string() == "123456");
    assert(dict["copy-sensitive"].get_boolean());
    assert(dict["copy-clear-after"].get_uint32() == 30);
    assert(new SearchActivationReply().to_dict().size() == 0);
}

void test_quick_tile_click() {
    var tile = new QuickTile("dev.sinty.test.tile", "Test", "starred-symbolic");
    int toggles = 0;
    int clicks = 0;
    tile.toggled.connect((active) => { toggles++; assert(active == tile.active); });
    tile.clicked.connect(() => clicks++);
    tile.click();
    assert(tile.active && toggles == 1 && clicks == 1);
    tile.toggleable = false;
    tile.click();
    assert(tile.active && toggles == 1 && clicks == 2);
    assert(!tile.has_detail_page);
    tile.set_detail_page(() => new Gtk.Label("detail"));
    assert(tile.has_detail_page);
}

void test_plugin_context_quick_tiles() {
    var context = new PluginContext();
    var tile = new QuickTile("dev.sinty.test.tile", "Test", "starred-symbolic");
    int added = 0;
    context.quick_tile_added.connect(() => added++);
    context.add_quick_tile(tile);
    context.add_quick_tile(new QuickTile("dev.sinty.test.tile", "Duplicate", "starred-symbolic"));
    assert(added == 1);
    assert(context.get_quick_tiles().length == 1);
    context.remove_quick_tile(tile);
    assert(context.get_quick_tiles().length == 0);
}

class EmptyProvider : SearchProviderService {
    public override async string[] get_initial_results(string[] terms, Cancellable? cancellable) throws Error {
        return { "one" };
    }

    public override async SearchResultMeta[] get_result_metas(string[] ids, Cancellable? cancellable) throws Error {
        return {};
    }

    public override async SearchActivationReply? activate_result(string id, string[] terms, uint32 timestamp) throws Error {
        return null;
    }
}

void test_camera_clients() {
    string dump = """[
      {"id": 40, "type": "PipeWire:Interface:Node", "info": {"state": "running", "props": {"media.class": "Video/Source", "device.api": "v4l2", "node.name": "v4l2_input.pci"}}},
      {"id": 41, "type": "PipeWire:Interface:Node", "info": {"state": "running", "props": {"media.class": "Video/Source", "node.name": "screen-share"}}},
      {"id": 50, "type": "PipeWire:Interface:Client", "info": {"props": {"application.name": "Firefox", "application.process.id": 4242, "application.process.binary": "firefox", "pipewire.access.portal.app_id": "org.mozilla.firefox"}}},
      {"id": 60, "type": "PipeWire:Interface:Node", "info": {"state": "running", "props": {"media.class": "Stream/Input/Video", "client.id": 50, "node.name": "webrtc"}}},
      {"id": 61, "type": "PipeWire:Interface:Node", "info": {"state": "running", "props": {"media.class": "Stream/Input/Video", "application.name": "Recorder", "node.name": "rec"}}},
      {"id": 70, "type": "PipeWire:Interface:Link", "info": {"output-node-id": 40, "input-node-id": 60}},
      {"id": 71, "type": "PipeWire:Interface:Link", "info": {"output-node-id": 41, "input-node-id": 61}},
      {"id": 72, "type": "PipeWire:Interface:Link", "info": {"output-node-id": 40, "input-node-id": 60}}
    ]""";
    var clients = CameraClients.parse_dump(dump);
    assert(clients.length == 1);
    assert(clients[0].name == "Firefox");
    assert(clients[0].app_id == "org.mozilla.firefox");
    assert(clients[0].binary == "firefox");
    assert(clients[0].pid == 4242);
    assert(CameraClients.parse_dump("not json").length == 0);
    assert(CameraClients.parse_dump("{}").length == 0);
}

void test_plugin_gettext_domain() {
    assert(PluginPreferences.domain_for_app("dev.sinty.clock", null) == "singularity-clock");
    assert(PluginPreferences.domain_for_app("dev.sinty.QrCodes.desktop", null) == "singularity-qrcodes");
    assert(PluginPreferences.domain_for_app("dev.sinty.clock", "/opt/local/bin/singularity-clock") == "singularity-clock");
    string locale = Path.build_filename(data_home, "locale-test");
    write_file(Path.build_filename(locale, "it", "LC_MESSAGES", "singularity-clock.mo"), "");
    assert(PluginPreferences.find_locale_dir("singularity-clock", { "/nonexistent", locale }, { "it_IT", "it", "C" }) == locale);
    assert(PluginPreferences.find_locale_dir("singularity-clock", { locale }, { "de", "C" }) == null);
}

void test_multiarch_widget_dirs() {
    string lib = Path.build_filename(data_home, "lib");
    DirUtils.create_with_parents(Path.build_filename(lib, "x86_64-linux-gnu", "singularity", "widgets"), 0755);
    DirUtils.create_with_parents(Path.build_filename(lib, "aarch64-linux-gnu"), 0755);
    DirUtils.create_with_parents(Path.build_filename(lib, "python3", "singularity", "widgets"), 0755);
    var found = multiarch_widget_dirs({ lib, "/nonexistent" });
    assert(found.length == 1);
    assert(found[0] == Path.build_filename(lib, "x86_64-linux-gnu", "singularity", "widgets"));
}

void test_dock_menu_reply_path() {
    assert(DockMenu.reply_path_for("dev.sinty.Passwords.desktop") == "/dev/sinty/DockMenu/dev_sinty_passwords");
    assert(DockMenu.reply_path_for("org.gnome.Some-App") == "/dev/sinty/DockMenu/org_gnome_some_app");
    assert(Variant.is_object_path(DockMenu.reply_path_for("a.b-c")));
}

void test_settings_page_actions_and_detail() {
    var context = new PluginContext();
    var action = new SettingsPageAction("dev.sinty.test.share", SettingsPageAction.WIFI, "Share");
    int added = 0;
    context.settings_page_action_added.connect(() => added++);
    context.add_settings_page_action(action);
    context.add_settings_page_action(new SettingsPageAction("dev.sinty.test.share", SettingsPageAction.WIFI, "Again"));
    assert(added == 1);
    assert(context.get_settings_page_actions(SettingsPageAction.WIFI).length == 1);
    assert(context.get_settings_page_actions("bluetooth").length == 0);
    int pressed = 0;
    action.activated.connect(() => pressed++);
    action.activate();
    assert(pressed == 1);
    context.remove_settings_page_action(action);
    assert(context.get_settings_page_actions(SettingsPageAction.WIFI).length == 0);

    var per_network = new SettingsPageAction("dev.sinty.test.share-network", SettingsPageAction.WIFI_NETWORK, "Share Network");
    context.add_settings_page_action(per_network);
    assert(context.get_settings_page_actions(SettingsPageAction.WIFI).length == 0);
    assert(context.get_settings_page_actions(SettingsPageAction.WIFI_NETWORK).length == 1);
    string? target = null;
    per_network.activated_for.connect((t) => target = t);
    per_network.activate_for("Harbor Guest");
    assert(target == "Harbor Guest");
    context.remove_settings_page_action(per_network);

    var tile = new QuickTile("dev.sinty.test.detail", "Test", "starred-symbolic");
    int requested = 0;
    tile.detail_page_requested.connect(() => requested++);
    tile.open_detail_page();
    assert(requested == 0);
    tile.set_detail_page(() => new Gtk.Label("detail"));
    tile.open_detail_page();
    assert(requested == 1);
}

void test_large_preview_dict() {
    var meta = new SearchResultMeta("qr", "QR");
    assert(!meta.to_dict().contains("preview-large"));
    meta.preview_large = true;
    assert(meta.to_dict()["preview-large"].get_boolean());
}

Singularity.Widgets.WelcomePage make_welcome_page(int[] seen) {
    var page = new Singularity.Widgets.WelcomePage();
    string word = "inbox-" + seen.length.to_string();
    page.add_action("mail-inbox-symbolic", "Inbox", "Open the inbox", () => {
        seen[0] = word.length;
    });
    return page;
}

void test_welcome_action_keeps_closure() {
    if (!gtk_ready) {
        Test.skip("no display");
        return;
    }
    int[] seen = { 0, 0 };
    var page = make_welcome_page(seen);
    var noise = new string[64];
    for (int i = 0; i < noise.length; i++) noise[i] = "overwrite-%d-%s".printf(i, string.nfill(32, 'x'));
    page.trigger_action(0);
    assert(seen[0] == "inbox-2".length);
}

bool gtk_ready = false;
TestDBus test_bus;
GLib.Application export_app;

void test_search_provider_export_before_register() {
    test_bus = new TestDBus(TestDBusFlags.NONE);
    test_bus.up();
    var app = new GLib.Application("dev.sinty.ExportTest", ApplicationFlags.DEFAULT_FLAGS);
    var provider = new EmptyProvider();
    provider.export(app);
    assert(provider.object_path == null);
    try {
        app.register();
    } catch (Error e) {
        error("%s", e.message);
    }
    assert(provider.object_path == "/dev/sinty/ExportTest/SearchProvider");
    var late = new EmptyProvider();
    late.export(app, "/dev/sinty/ExportTest/Late");
    assert(late.object_path == "/dev/sinty/ExportTest/Late");
    provider.unexport();
    late.unexport();
    export_app = app;
}

class MemoryStore : Object, OverviewWidgetConfigStore {
    public HashTable<string, Variant> configs = new HashTable<string, Variant>(str_hash, str_equal);

    public Variant? load_config(string instance_id) {
        return configs[instance_id];
    }

    public void save_config(string instance_id, Variant? config) {
        if (config == null) configs.remove(instance_id);
        else configs[instance_id] = config;
    }
}

void test_widget_config_store() {
    var registry = OverviewWidgetRegistry.get_default();
    assert(!registry.save_instance_config("w-1", new Variant.string("x")));
    var store = new MemoryStore();
    registry.config_store = store;
    string? changed = null;
    registry.instance_config_changed.connect((iid, cfg) => changed = iid);
    assert(registry.save_instance_config("w-1", new Variant.string("Milan")));
    assert(changed == "w-1");
    assert(registry.get_instance_config("w-1").get_string() == "Milan");
    registry.config_store = null;
}

int main(string[] args) {
    try {
        data_home = DirUtils.make_tmp("extension-api-XXXXXX");
    } catch (FileError e) {
        error("%s", e.message);
    }
    Environment.set_variable("XDG_DATA_HOME", data_home, true);
    Test.init(ref args);
    gtk_ready = Gtk.init_check();
    Test.add_func("/extension/find-data-files", test_find_data_files);
    Test.add_func("/extension/file-action-matching", test_file_action_matching);
    Test.add_func("/extension/declarative-file-action", test_declarative_file_action);
    Test.add_func("/extension/search-meta-dict", test_search_meta_dict);
    Test.add_func("/extension/activation-reply-dict", test_activation_reply_dict);
    Test.add_func("/extension/quick-tile-click", test_quick_tile_click);
    Test.add_func("/extension/plugin-context-quick-tiles", test_plugin_context_quick_tiles);
    Test.add_func("/extension/widget-config-store", test_widget_config_store);
    Test.add_func("/extension/search-provider-export-before-register", test_search_provider_export_before_register);
    Test.add_func("/extension/camera-clients", test_camera_clients);
    Test.add_func("/extension/plugin-gettext-domain", test_plugin_gettext_domain);
    Test.add_func("/extension/multiarch-widget-dirs", test_multiarch_widget_dirs);
    Test.add_func("/extension/dock-menu-reply-path", test_dock_menu_reply_path);
    Test.add_func("/extension/settings-page-actions", test_settings_page_actions_and_detail);
    Test.add_func("/extension/large-preview", test_large_preview_dict);
    Test.add_func("/extension/welcome-action-closure", test_welcome_action_keeps_closure);
    return Test.run();
}
