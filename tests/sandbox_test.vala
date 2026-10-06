using Singularity;
using Singularity.Sandbox;

string scratch;

string write_file(string relative, string contents) {
    string path = Path.build_filename(scratch, relative);
    DirUtils.create_with_parents(Path.get_dirname(path), 0755);
    try {
        FileUtils.set_contents(path, contents);
    } catch (Error e) {
        assert_not_reached();
    }
    return path;
}

Singularity.Sandbox.Permission? find(Singularity.Sandbox.Permission[] list, string id) {
    foreach (var permission in list) {
        if (permission.id == id) return permission;
    }
    return null;
}

void test_config() {
    assert(Config.parse_backends("flatpak;cpak").length == 2);
    assert(Config.parse_backends("auto").length == 2);
    assert(Config.parse_backends("none").length == 0);
    var only = Config.parse_backends(" cpak , cpak ");
    assert(only.length == 1 && only[0] == "cpak");
    string path = write_file("etc/sandbox.conf", "[Sandbox]\nBackends=cpak\n[cpak]\nCommand=/opt/bin/cpak --quiet\n");
    var config = new Config();
    assert(config.load_file(path));
    assert(config.backends.length == 1 && config.backends[0] == "cpak");
    assert(config.cpak_command == "/opt/bin/cpak --quiet");
    var backends = new Backends.from_config(config);
    assert(backends.all().length == 1 && backends.all()[0].kind == "cpak");
}

void test_flatpak_model() {
    string user = Path.build_filename(scratch, "flatpak-user");
    string system = Path.build_filename(scratch, "flatpak-system");
    write_file("flatpak-system/app/org.example.Player/current/active/metadata",
        "[Application]\nname=org.example.Player\n\n[Context]\nshared=network;ipc;\nsockets=wayland;pulseaudio;\n" +
        "devices=dri;\nfilesystems=xdg-music:ro;~/Mixes;\n\n[Session Bus Policy]\norg.mpris.MediaPlayer2.Player=own\n" +
        "org.freedesktop.Notifications=talk\n\n[Environment]\nPLAYER_MODE=fast\n");
    write_file("flatpak-system/overrides/org.example.Player", "[Context]\ndevices=all;\n");
    write_file("flatpak-user/overrides/org.example.Player",
        "[Context]\nshared=!network;\nfilesystems=home;\n\n[Session Bus Policy]\norg.freedesktop.Notifications=none\n");
    var backend = new FlatpakBackend(user, system);
    assert(backend.available());
    var loop = new MainLoop();
    App[] apps = {};
    backend.list_apps.begin((obj, res) => {
        apps = backend.list_apps.end(res);
        loop.quit();
    });
    loop.run();
    assert(apps.length == 1 && apps[0].id == "org.example.Player" && apps[0].portal_app_id == "org.example.Player");
    var list = FlatpakBackend.build(backend.defaults("org.example.Player"), backend.user_override("org.example.Player"));
    var network = find(list, "network:network");
    assert(network != null && network.default_enabled && !network.enabled && network.overridden);
    var ipc = find(list, "network:ipc");
    assert(ipc.enabled && !ipc.overridden);
    var all = find(list, "devices:all");
    assert(all.enabled && all.default_enabled && !all.overridden && all.category == "camera");
    var music = find(list, "files:xdg-music");
    assert(music.enabled && music.value == "xdg-music:ro" && !music.overridden);
    var home = find(list, "files:home");
    assert(home.enabled && !home.default_enabled && home.overridden);
    assert(find(list, "files:~/Mixes") != null);
    assert(!find(list, "files:xdg-videos").enabled);
    var notifications = find(list, "session-bus:org.freedesktop.Notifications");
    assert(notifications.kind == Kind.BUS_POLICY && !notifications.enabled && notifications.default_enabled);
    var mpris = find(list, "session-bus:org.mpris.MediaPlayer2.Player");
    assert(mpris.enabled && mpris.value == "own");
    var env = find(list, "environment:PLAYER_MODE");
    assert(env.value == "fast" && !env.editable);

    assert(backend.write("org.example.Player", network, true, true));
    assert(backend.write("org.example.Player", find(list, "sockets:x11"), true, false));
    assert(backend.write("org.example.Player", music, false, false));
    assert(backend.write("org.example.Player", notifications, true, true));
    assert(backend.write("org.example.Player", mpris, false, false));
    var after = FlatpakBackend.build(backend.defaults("org.example.Player"), backend.user_override("org.example.Player"));
    assert(find(after, "network:network").enabled && !find(after, "network:network").overridden);
    assert(find(after, "sockets:x11").enabled && find(after, "sockets:x11").overridden);
    assert(!find(after, "files:xdg-music").enabled && find(after, "files:xdg-music").overridden);
    assert(find(after, "session-bus:org.freedesktop.Notifications").enabled);
    assert(!find(after, "session-bus:org.mpris.MediaPlayer2.Player").enabled);
    string written = "";
    try {
        FileUtils.get_contents(backend.override_path("org.example.Player"), out written);
    } catch (Error e) {
        assert_not_reached();
    }
    assert("sockets=x11;" in written && "!xdg-music" in written && "org.mpris.MediaPlayer2.Player=none" in written);
    assert(!("!network" in written));

    var music_on = find(after, "files:xdg-music");
    assert(backend.write("org.example.Player", music_on, true, false));
    var restored = FlatpakBackend.build(backend.defaults("org.example.Player"), backend.user_override("org.example.Player"));
    assert(find(restored, "files:xdg-music").value == "xdg-music:ro" && !find(restored, "files:xdg-music").overridden);

    backend.reset_all.begin(apps[0], (obj, res) => {
        assert(backend.reset_all.end(res));
        loop.quit();
    });
    loop.run();
    assert(!FileUtils.test(backend.override_path("org.example.Player"), FileTest.EXISTS));

    var entry = new KeyFile();
    entry.set_string("Desktop Entry", "X-Flatpak", "org.example.Player");
    var mapped = backend.app_for_desktop("org.example.Player.desktop", entry);
    assert(mapped != null && mapped.id == "org.example.Player");
    assert(backend.app_for_desktop("org.example.Missing.desktop", null) == null);
}

void test_flatpak_cgroup() {
    string cgroup = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-flatpak-org.example.Player-1234.scope\n";
    assert(FlatpakBackend.app_id_from_cgroup(cgroup) == "org.example.Player");
    assert(FlatpakBackend.app_id_from_cgroup("0::/user.slice/session-2.scope\n") == null);
}

const string CPAK_LIST = """[
  {"cpak_id": "UGxheWVyOmJyYW5jaDptYWluOmdpdGh1Yi5jb20vZXhhbXBsZS9wbGF5ZXI=", "name": "Player", "version": "main",
   "origin": "github.com/example/player", "parsed_desktop_entries": ["/usr/share/applications/org.example.Player.desktop"],
   "parsed_override": {"socketWayland": true, "socketPulseAudio": true, "deviceDri": true, "deviceVideo": false,
     "notification": true, "network": true, "socketX11": false,
     "filesystem": [{"path": "xdg-music", "access": "read-only"}],
     "sessionBus": {"talk": [{"name": "org.freedesktop.secrets.example", "path": "/"}], "own": ["org.mpris.MediaPlayer2.player"]},
     "env": ["PLAYER_MODE=fast"]}},
  {"cpak_id": "U0RLOmJyYW5jaDptYWluOmdpdGh1Yi5jb20vZXhhbXBsZS9zZGs=", "name": "SDK", "version": "main",
   "origin": "github.com/example/sdk", "parsed_desktop_entries": []},
  {"name": "Broken"}
]""";

void test_cpak_parse() {
    var records = CpakBackend.parse_list(CPAK_LIST);
    assert(records.length == 2);
    assert(records[0].origin == "github.com/example/player");
    string expected = "cpak-%s-org.example.Player.desktop".printf(
        Checksum.compute_for_string(ChecksumType.SHA256, records[0].cpak_id));
    assert(records[0].desktop_ids.length == 1 && records[0].desktop_ids[0] == expected);
    assert(CpakBackend.portal_id(expected) == expected.substring(0, expected.length - 8));
    assert(records[1].desktop_ids.length == 0);
    assert(CpakBackend.parse_list("nope").length == 0);

    var grants = CpakBackend.parse_grants("""[
      {"id": "aaaaaaaabbbbbbbb", "origin": "github.com/example/player", "selection": "/home/u/Music/Live",
       "kind": "directory", "access": "read-write", "lifetime": "persistent"},
      {"id": "cccccccc", "selection": "/tmp/x", "lifetime": "session"}
    ]""");
    assert(grants.length == 1 && grants[0].selection == "/home/u/Music/Live");

    var running = CpakBackend.parse_running("""[
      {"origin": "github.com/example/player", "container": "running", "container_pid": 4242},
      {"origin": "github.com/example/player", "container": "stopped", "container_pid": 17}
    ]""");
    assert(running.size == 1 && running[4242] == "github.com/example/player");

    var entry = new KeyFile();
    entry.set_string("Desktop Entry", "Exec", "/home/u/.local/bin/cpak run --desktop-launch github.com/example/player --desktop-file-span 0,0 @player -- %U");
    assert(CpakBackend.origin_from_entry(entry) == "github.com/example/player");
    var tagged = new KeyFile();
    tagged.set_string("Desktop Entry", "X-cpak-Origin", "github.com/example/other");
    assert(CpakBackend.origin_from_entry(tagged) == "github.com/example/other");
    assert(CpakBackend.origin_from_entry(new KeyFile()) == null);
}

Json.Node parse_node(string json) {
    var parser = new Json.Parser();
    try {
        parser.load_from_data(json);
    } catch (Error e) {
        assert_not_reached();
    }
    return parser.get_root().copy();
}

Json.Object parse_object(string json) {
    return parse_node(json).get_object();
}

void test_cpak_model() {
    var records = CpakBackend.parse_list(CPAK_LIST);
    var declared = records[0].declared;
    var user = parse_object("""{"socketWayland": true, "socketPulseAudio": false, "deviceDri": true, "deviceVideo": true,
      "notification": true, "network": false, "filesystem": [{"path": "xdg-music", "access": "read-only"}, {"path": "home", "access": "read-write"}],
      "sessionBus": {"own": ["org.mpris.MediaPlayer2.player"]}, "env": ["PLAYER_MODE=fast"]}""");
    var list = CpakBackend.build(declared, user, CpakBackend.parse_grants(
        """[{"id": "aaaaaaaabbbbbbbb", "selection": "/home/u/Music/Live", "access": "read-only", "lifetime": "persistent"}]"""));
    var camera = find(list, "devices:camera");
    assert(camera.enabled && !camera.default_enabled && camera.overridden && camera.category == "camera");
    var sound = find(list, "sockets:pulseaudio");
    assert(!sound.enabled && sound.default_enabled && sound.category == "microphone");
    assert(find(list, "features:notifications").category == "notifications");
    assert(!find(list, "network:network").enabled && find(list, "network:network").overridden);
    assert(find(list, "sockets:wayland").enabled && !find(list, "sockets:wayland").overridden);
    assert(find(list, "sockets:x11-socket") == null);
    var home = find(list, "files:home");
    assert(home.enabled && home.overridden && !home.default_enabled);
    var music = find(list, "files:xdg-music");
    assert(music.enabled && !music.overridden && music.value == "read-only");
    var grant = find(list, "files:grant:aaaaaaaabbbbbbbb");
    assert(grant.revocable && !grant.editable && grant.detail.contains("/home/u/Music/Live"));
    var secrets = find(list, "session-bus:org.freedesktop.secrets.example");
    assert(!secrets.enabled && secrets.default_enabled && secrets.overridden);
    assert(find(list, "session-bus:org.mpris.MediaPlayer2.player").value == "own");
    assert(find(list, "environment:PLAYER_MODE").value == "fast");

    var args = CpakBackend.override_args("github.com/example/player", declared, user, camera, false);
    assert(args.length == 6 && args[0] == "override" && args[1] == "github.com/example/player");
    assert(args[3] == "deviceVideo" && args[5] == "false");
    args = CpakBackend.override_args("github.com/example/player", declared, user, home, false);
    assert(args[3] == "filesystem");
    var fs = parse_node(args[5]).get_array();
    assert(fs.get_length() == 1);
    assert(fs.get_object_element(0).get_string_member("path") == "xdg-music");
    var videos = find(list, "files:xdg-videos");
    args = CpakBackend.override_args("github.com/example/player", declared, user, videos, true);
    fs = parse_node(args[5]).get_array();
    assert(fs.get_length() == 3);
    assert(fs.get_object_element(2).get_string_member("access") == "read-write");
    args = CpakBackend.override_args("github.com/example/player", declared, user, secrets, true);
    assert(args[3] == "sessionBus");
    var bus = parse_object(args[5]);
    assert(bus.get_array_member("talk").get_length() == 1);
    assert(bus.get_array_member("talk").get_object_element(0).get_string_member("path") == "/");
    assert(bus.get_array_member("own").get_length() == 1);
    args = CpakBackend.override_args("github.com/example/player", declared, null,
        find(CpakBackend.build(declared, null, {}), "session-bus:org.mpris.MediaPlayer2.player"), false);
    bus = parse_object(args[5]);
    assert(!bus.has_member("own") && bus.get_array_member("talk").get_length() == 1);
    assert(CpakBackend.override_args("github.com/example/player", declared, user, grant, false) == null);
    assert(CpakBackend.override_args("github.com/example/player", declared, user,
        find(list, "environment:PLAYER_MODE"), false) == null);

    var untouched = CpakBackend.build(declared, null, {});
    foreach (var permission in untouched) assert(!permission.overridden);
}

void test_app_matching() {
    var app = new App("cpak", "github.com/example/player");
    app.desktop_id = "cpak-abc-org.example.Player.desktop";
    app.portal_app_id = "cpak-abc-org.example.Player";
    assert(app.matches("github.com/example/player"));
    assert(app.matches("cpak-abc-org.example.Player"));
    assert(app.matches("cpak-abc-org.example.Player.desktop"));
    assert(!app.matches("org.example.Player"));
    assert(!app.matches(""));
}

void test_usage() {
    var usage = new Singularity.Privacy.Usage(Path.build_filename(scratch, "state", "usage.ini"));
    int64 now = 1000 * TimeSpan.DAY;
    usage.record("org.example.Old", "camera", now - 8 * TimeSpan.DAY);
    usage.record("org.example.Map", "location", now - TimeSpan.HOUR);
    usage.record("org.example.Mic", "microphone", now - TimeSpan.MINUTE);
    usage.record("org.example.Map", "location", now - 2 * TimeSpan.HOUR);
    var recent = usage.recent(now);
    assert(recent.length == 2);
    assert(recent[0].app_id == "org.example.Mic" && recent[1].app_id == "org.example.Map");
    assert(usage.last_used("org.example.Map", "location") == now - TimeSpan.HOUR);
    var reloaded = new Singularity.Privacy.Usage(Path.build_filename(scratch, "state", "usage.ini"));
    assert(reloaded.recent(now).length == 2);
}

int main(string[] args) {
    Test.init(ref args);
    try {
        scratch = DirUtils.make_tmp("sandbox-test-XXXXXX");
    } catch (Error e) {
        return 1;
    }
    Test.add_func("/sandbox/config", test_config);
    Test.add_func("/sandbox/flatpak-model", test_flatpak_model);
    Test.add_func("/sandbox/flatpak-cgroup", test_flatpak_cgroup);
    Test.add_func("/sandbox/cpak-parse", test_cpak_parse);
    Test.add_func("/sandbox/cpak-model", test_cpak_model);
    Test.add_func("/sandbox/app-matching", test_app_matching);
    Test.add_func("/sandbox/usage", test_usage);
    return Test.run();
}
