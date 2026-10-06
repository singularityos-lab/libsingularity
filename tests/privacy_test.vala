using Singularity;

void test_parse_permissions() {
    var builder = new VariantBuilder(new VariantType("a{sas}"));
    builder.add("{s^as}", "org.example.Camera", new string[] { "yes" });
    builder.add("{s^as}", "org.example.Denied", new string[] { "no" });
    builder.add("{s^as}", "org.example.Map", new string[] { "EXACT", "1700000000" });
    builder.add("{s^as}", "org.example.Nowhere", new string[] { "NONE", "0" });
    var entries = PermissionStore.parse_permissions(builder.end());
    assert(entries.length == 4);
    assert(entries[0].app_id == "org.example.Camera" && entries[0].allowed);
    assert(entries[1].app_id == "org.example.Denied" && !entries[1].allowed);
    assert(entries[2].first == "EXACT" && entries[2].allowed && entries[2].values[1] == "1700000000");
    assert(!entries[3].allowed);
    assert(PermissionStore.parse_permissions(new Variant.string("x")).length == 0);
}

void test_parse_background_apps() {
    var list = new VariantBuilder(new VariantType("aa{sv}"));
    var one = new VariantBuilder(new VariantType("a{sv}"));
    one.add("{sv}", "app_id", new Variant.string("org.example.Player"));
    one.add("{sv}", "instance", new Variant.string("12345"));
    one.add("{sv}", "message", new Variant.string("Playing music"));
    list.add_value(one.end());
    var empty = new VariantBuilder(new VariantType("a{sv}"));
    empty.add("{sv}", "instance", new Variant.string("1"));
    list.add_value(empty.end());
    var apps = BackgroundApps.parse(list.end());
    assert(apps.length == 1);
    assert(apps[0].app_id == "org.example.Player");
    assert(apps[0].instance == "12345");
    assert(apps[0].message == "Playing music");
    assert(BackgroundApps.parse(new Variant.string("x")).length == 0);
}

void test_stop_argv() {
    var app = new BackgroundApp("org.example.Player", "4242", "");
    var argv = BackgroundApps.stop_argv(BackgroundApps.DEFAULT_STOP_COMMAND, app);
    assert(argv.length == 3);
    assert(argv[0] == "flatpak" && argv[1] == "kill" && argv[2] == "4242");
    argv = BackgroundApps.stop_argv("my-stopper --app '{app_id}'", app);
    assert(argv.length == 3 && argv[2] == "org.example.Player");
    assert(BackgroundApps.stop_argv("'unterminated", app).length == 0);
}

void test_microphone_dump() {
    string dump = """[
      {"id": 40, "type": "PipeWire:Interface:Node", "info": {"props": {"media.class": "Audio/Source", "node.name": "alsa_input.pci"}}},
      {"id": 41, "type": "PipeWire:Interface:Node", "info": {"props": {"media.class": "Audio/Sink", "node.name": "alsa_output.pci"}}},
      {"id": 60, "type": "PipeWire:Interface:Client", "info": {"props": {"application.name": "Recorder", "pipewire.access.portal.app_id": "org.example.Recorder", "application.process.id": 777, "application.process.binary": "recorder"}}},
      {"id": 70, "type": "PipeWire:Interface:Node", "info": {"props": {"media.class": "Stream/Input/Audio", "client.id": 60}}},
      {"id": 71, "type": "PipeWire:Interface:Node", "info": {"props": {"media.class": "Stream/Input/Audio", "application.name": "Peak", "stream.monitor": true}}},
      {"id": 72, "type": "PipeWire:Interface:Node", "info": {"props": {"media.class": "Stream/Input/Audio", "application.name": "Loopback"}}},
      {"id": 80, "type": "PipeWire:Interface:Link", "info": {"output-node-id": 40, "input-node-id": 70}},
      {"id": 81, "type": "PipeWire:Interface:Link", "info": {"output-node-id": 40, "input-node-id": 70}},
      {"id": 82, "type": "PipeWire:Interface:Link", "info": {"output-node-id": 40, "input-node-id": 71}},
      {"id": 83, "type": "PipeWire:Interface:Link", "info": {"output-node-id": 41, "input-node-id": 72}}
    ]""";
    var clients = MicrophoneClients.parse_dump(dump);
    assert(clients.length == 1);
    assert(clients[0].name == "Recorder");
    assert(clients[0].app_id == "org.example.Recorder");
    assert(clients[0].pid == 777);
    assert(clients[0].binary == "recorder");
    assert(MicrophoneClients.parse_dump("not json").length == 0);
    assert(MicrophoneClients.parse_dump("{}").length == 0);
}

void test_microphone_local_users() {
    var usage = MicrophoneClients.get_default();
    int changes = 0;
    ulong id = usage.changed.connect(() => changes++);
    assert(!usage.in_use);
    usage.acquire("dictation", "Dictation");
    usage.acquire("notes", "Notes");
    assert(usage.in_use);
    assert(usage.labels().length == 2 && usage.labels()[0] == "Dictation" && usage.labels()[1] == "Notes");
    usage.release("dictation");
    assert(usage.in_use && usage.labels().length == 1 && usage.labels()[0] == "Notes");
    usage.release("missing");
    usage.release("notes");
    assert(!usage.in_use && usage.labels().length == 0);
    assert(changes == 4);
    usage.disconnect(id);
}

void test_microphone_merge() {
    var local = new MicrophoneClient();
    local.name = "Dettatura";
    var stream = new MicrophoneClient();
    stream.name = "Dictation";
    var other = new MicrophoneClient();
    other.name = "Recorder";
    var merged = MicrophoneClients.merge({ local }, { "dictation" }, { stream, other });
    assert(merged.length == 2);
    assert(merged[0].name == "Dettatura" && merged[1].name == "Recorder");
    assert(MicrophoneClients.merge({}, {}, { stream }).length == 1);
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/privacy/permission-store/parse", test_parse_permissions);
    Test.add_func("/privacy/background-apps/parse", test_parse_background_apps);
    Test.add_func("/privacy/background-apps/stop-argv", test_stop_argv);
    Test.add_func("/privacy/microphone/dump", test_microphone_dump);
    Test.add_func("/privacy/microphone/local-users", test_microphone_local_users);
    Test.add_func("/privacy/microphone/merge", test_microphone_merge);
    return Test.run();
}
