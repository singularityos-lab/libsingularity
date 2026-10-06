using GLib;
using Singularity.Accessibility;

private string fixture_dir;
private string work_dir;

private string write_file(string name, string contents) {
    string path = Path.build_filename(work_dir, name);
    DirUtils.create_with_parents(Path.get_dirname(path), 0755);
    try {
        FileUtils.set_contents(path, contents);
    } catch (FileError e) {
        error("fixture write failed: %s", e.message);
    }
    return path;
}

private Json.Object read_json(string path) {
    var parser = new Json.Parser();
    try {
        parser.load_from_file(path);
    } catch (Error e) {
        error("cannot parse %s: %s", path, e.message);
    }
    return parser.get_root().get_object();
}

private const string LEGACY = """{
    "general": {
        "enableKeyEcho": false,
        "speechVerbosityLevel": 0,
        "verbalizePunctuationStyle": 3,
        "keyboardLayout": 2,
        "orcaModifierKeys": ["Caps_Lock", "Shift_Lock"],
        "voices": {"default": {"rate": 70, "average-pitch": 6.5, "gain": 8.0, "family": {"name": "Italian", "lang": "it"}}}
    },
    "profiles": {"default": {"profile": ["Default", "default"], "enableEchoByWord": true,
        "speechServerInfo": ["Espeak NG", "espeak-ng"]}},
    "pronunciations": {},
    "keybindings": {}
}""";

private void test_json_read() {
    var store = new OrcaJsonStore(write_file("read/user-settings.conf", LEGACY));
    assert(!store.get_bool("key-echo"));
    assert(!store.get_bool("character-echo"));
    assert(store.get_bool("word-echo"));
    assert(store.get_string("verbosity") == "brief");
    assert(store.get_string("punctuation") == "none");
    assert(store.get_string("keyboard-layout") == "laptop");
    assert(store.get_string("speech-server") == "Espeak NG");
    assert(store.get_string("synthesizer") == "espeak-ng");
    assert(store.get_string("voice") == "Italian");
    assert(store.get_string("voice-lang") == "it");
    assert(store.get_int("rate") == 70);
    assert(store.get_double("pitch") == 6.5);
    assert(store.get_double("volume") == 8.0);
    var mods = store.get_strv("modifier-keys");
    assert(mods.length == 2 && mods[0] == "Caps_Lock");
    assert(ScreenReaderSettings.modifier_choice_for(mods) == "caps-lock");
}

private void test_json_write() {
    string path = write_file("write/user-settings.conf", LEGACY);
    var store = new OrcaJsonStore(path);
    store.set_bool("key-echo", true);
    store.set_string("verbosity", "verbose");
    store.set_string("punctuation", "some");
    store.set_string("keyboard-layout", "desktop");
    store.set_string("synthesizer", "festival");
    store.set_string("speech-server", "Festival");
    store.set_int("rate", 35);
    store.set_double("pitch", 4.0);
    store.set_double("volume", 9.5);
    store.set_string("voice", "English");
    store.set_strv("modifier-keys", ScreenReaderSettings.modifier_keys_for("both"));

    var root = read_json(path);
    var prof = root.get_object_member("profiles").get_object_member("default");
    assert(prof.get_boolean_member("enableKeyEcho"));
    assert(prof.get_int_member("speechVerbosityLevel") == 1);
    assert(prof.get_int_member("verbalizePunctuationStyle") == 2);
    assert(prof.get_int_member("keyboardLayout") == 1);
    var info = prof.get_array_member("speechServerInfo");
    assert(info.get_string_element(0) == "Festival" && info.get_string_element(1) == "festival");
    assert(prof.get_string_member("speechServerFactory") == "speechdispatcherfactory");
    var voice = prof.get_object_member("voices").get_object_member("default");
    assert(voice.get_int_member("rate") == 35);
    assert(voice.get_double_member("average-pitch") == 4.0);
    assert(voice.get_double_member("gain") == 9.5);
    assert(voice.get_boolean_member("established"));
    assert(voice.get_object_member("family").get_string_member("name") == "English");
    assert(voice.get_object_member("family").get_string_member("lang") == "it");
    assert(prof.get_array_member("orcaModifierKeys").get_length() == 4);
    assert(root.get_object_member("general").get_boolean_member("enableKeyEcho") == false);
    assert(root.has_member("keybindings") && root.has_member("pronunciations"));

    var again = new OrcaJsonStore(path);
    assert(again.get_bool("key-echo"));
    assert(again.get_string("punctuation") == "some");
    assert(again.get_int("rate") == 35);
    assert(again.get_string("voice") == "English");
    assert(ScreenReaderSettings.modifier_choice_for(again.get_strv("modifier-keys")) == "both");
}

private void test_json_fresh() {
    string path = Path.build_filename(work_dir, "fresh", "orca", "user-settings.conf");
    var store = new OrcaJsonStore(path);
    assert(store.get_bool("key-echo"));
    assert(store.get_string("verbosity") == "verbose");
    assert(store.get_string("punctuation") == "most");
    assert(store.get_int("rate") == 50);
    assert(store.get_double("volume") == 10.0);
    assert(ScreenReaderSettings.modifier_choice_for(store.get_strv("modifier-keys")) == "insert");
    store.set_int("rate", 60);
    assert(FileUtils.test(path, FileTest.IS_REGULAR));
    var prof = read_json(path).get_object_member("profiles").get_object_member("default");
    assert(prof.get_array_member("profile").get_string_element(1) == "default");
    assert(prof.get_object_member("voices").get_object_member("default").get_int_member("rate") == 60);
}

private void test_paths() {
    string schema, sub, key;
    OrcaGSettingsStore.locate("verbosity", out schema, out sub, out key);
    assert(schema == "org.gnome.Orca.Speech" && sub == "speech" && key == "verbosity-level");
    OrcaGSettingsStore.locate("punctuation", out schema, out sub, out key);
    assert(key == "punctuation-level");
    OrcaGSettingsStore.locate("word-echo", out schema, out sub, out key);
    assert(schema == "org.gnome.Orca.TypingEcho" && sub == "typing-echo");
    OrcaGSettingsStore.locate("laptop-modifier-keys", out schema, out sub, out key);
    assert(schema == "org.gnome.Orca.Keybindings" && sub == "keybindings");
    OrcaGSettingsStore.locate("voice", out schema, out sub, out key);
    assert(schema == "org.gnome.Orca.Voice" && sub == "voice-sets/primary/default" && key == "family-name");
    OrcaGSettingsStore.locate("rate", out schema, out sub, out key);
    assert(key == "rate");
    assert(OrcaGSettingsStore.sanitize("My Profile_2!") == "my-profile-2");
    var store = new OrcaGSettingsStore("My Profile");
    assert(store.path_for("rate") == "/org/gnome/orca/my-profile/voice-sets/primary/default/");
    assert(store.path_for("key-echo") == "/org/gnome/orca/my-profile/typing-echo/");
    assert(new OrcaGSettingsStore().path_for("synthesizer") == "/org/gnome/orca/default/speech/");
}

private void test_gsettings() {
    assert(OrcaGSettingsStore.schemas_installed());
    var store = new OrcaGSettingsStore();
    int changes = 0;
    store.changed.connect(() => changes++);
    assert(store.get_string("verbosity") == "verbose");
    assert(store.get_int("rate") == 50);
    store.set_string("verbosity", "brief");
    store.set_string("punctuation", "all");
    store.set_int("rate", 80);
    store.set_double("pitch", 7.0);
    store.set_bool("character-echo", true);
    store.set_string("synthesizer", "espeak-ng");
    store.set_string("keyboard-layout", "laptop");
    store.set_strv("modifier-keys", ScreenReaderSettings.modifier_keys_for("both"));

    var speech = new GLib.Settings.with_path("org.gnome.Orca.Speech", "/org/gnome/orca/default/speech/");
    assert(speech.get_string("verbosity-level") == "brief");
    assert(speech.get_string("punctuation-level") == "all");
    assert(speech.get_string("synthesizer") == "espeak-ng");
    var voice = new GLib.Settings.with_path("org.gnome.Orca.Voice", "/org/gnome/orca/default/voice-sets/primary/default/");
    assert(voice.get_int("rate") == 80);
    assert(voice.get_double("pitch") == 7.0);
    assert(voice.get_boolean("established"));
    var echo = new GLib.Settings.with_path("org.gnome.Orca.TypingEcho", "/org/gnome/orca/default/typing-echo/");
    assert(echo.get_boolean("character-echo"));
    var keys = new GLib.Settings.with_path("org.gnome.Orca.Keybindings", "/org/gnome/orca/default/keybindings/");
    assert(keys.get_string("keyboard-layout") == "laptop");
    assert(keys.get_strv("laptop-modifier-keys").length == 4);
    assert(keys.get_strv("desktop-modifier-keys")[0] == "Insert");
    assert(ScreenReaderSettings.modifier_choice_for(store.get_strv("modifier-keys")) == "both");
    var ctx = MainContext.default();
    while (ctx.pending()) ctx.iteration(false);
    assert(changes > 0);
}

private void test_detect() {
    var cfg = new ScreenReaderConfig();
    var s = ScreenReaderSettings.detect(cfg);
    assert(s.kind == ScreenReaderBackendKind.GSETTINGS && s.available);

    string conf = write_file("conf/screen-reader.conf",
        "[ScreenReader]\nBackend=json\nJsonPath=%s\nVoicesCommand=my-say\n".printf(Path.build_filename(work_dir, "conf", "orca.json")));
    var cfg2 = new ScreenReaderConfig();
    assert(cfg2.load_file(conf));
    assert(cfg2.voices_command == "my-say");
    var s2 = ScreenReaderSettings.detect(cfg2);
    assert(s2.kind == ScreenReaderBackendKind.JSON);
    assert(((OrcaJsonStore) s2.store).path.has_suffix("conf/orca.json"));

    var cfg3 = new ScreenReaderConfig();
    cfg3.backend = "none";
    var s3 = ScreenReaderSettings.detect(cfg3);
    assert(s3.kind == ScreenReaderBackendKind.NONE && !s3.available);
}

private void test_voice_parsing() {
    var modules = SpeechVoices.parse_modules("OUTPUT MODULES\nespeak-ng\nfestival\n\n");
    assert(modules.length == 2 && modules[1] == "festival");
    var voices = SpeechVoices.parse_voices(
        "                   NAME     LANGUAGE             VARIANT\n" +
        "              Afrikaans           af                none\n" +
        "     English (Great Britain)   en-GB             none\n" +
        "    Italian  it  f2\n");
    assert(voices.length == 3);
    assert(voices[0].name == "Afrikaans" && voices[0].language == "af");
    assert(voices[1].name == "English (Great Britain)" && voices[1].language == "en-GB");
    assert(voices[2].variant == "f2");
}

private void test_voice_command() {
    string bin = write_file("bin/fake-say",
        "#!/bin/sh\nif [ \"$1\" = \"-O\" ]; then printf 'OUTPUT MODULES\\nespeak-ng\\ndummy\\n'; else printf 'NAME LANGUAGE VARIANT\\nItalian it none\\nGerman de none\\n'; fi\n");
    FileUtils.chmod(bin, 0755);
    var voices = new SpeechVoices(bin);
    assert(voices.available);
    var loop = new MainLoop();
    string[] modules = {};
    SpeechVoice[] list = {};
    voices.list_modules.begin((o, r) => {
        modules = voices.list_modules.end(r);
        voices.list_voices.begin("espeak-ng", (o2, r2) => {
            list = voices.list_voices.end(r2);
            loop.quit();
        });
    });
    loop.run();
    assert(modules.length == 2 && modules[0] == "espeak-ng");
    assert(list.length == 2 && list[1].name == "German");
    assert(!new SpeechVoices("no-such-say-command").available);
}

int main(string[] args) {
    fixture_dir = args.length > 1 ? args[1] : "tests/fixtures/screen-reader";
    try {
        work_dir = DirUtils.make_tmp("screen-reader-XXXXXX");
    } catch (FileError e) {
        error("tmp: %s", e.message);
    }
    string schemas = Path.build_filename(work_dir, "schemas");
    DirUtils.create_with_parents(schemas, 0755);
    string xml;
    try {
        FileUtils.get_contents(Path.build_filename(fixture_dir, "orca-schema.xml"), out xml);
        FileUtils.set_contents(Path.build_filename(schemas, "org.gnome.Orca.gschema.xml"), xml);
        Process.spawn_command_line_sync("glib-compile-schemas " + Shell.quote(schemas));
    } catch (Error e) {
        error("schema setup: %s", e.message);
    }
    Environment.set_variable("GSETTINGS_SCHEMA_DIR", schemas, true);
    Environment.set_variable("GSETTINGS_BACKEND", "memory", true);
    Test.init(ref args);
    Test.add_func("/screen-reader/json-read", test_json_read);
    Test.add_func("/screen-reader/json-write", test_json_write);
    Test.add_func("/screen-reader/json-fresh", test_json_fresh);
    Test.add_func("/screen-reader/paths", test_paths);
    Test.add_func("/screen-reader/gsettings", test_gsettings);
    Test.add_func("/screen-reader/detect", test_detect);
    Test.add_func("/screen-reader/voice-parsing", test_voice_parsing);
    Test.add_func("/screen-reader/voice-command", test_voice_command);
    return Test.run();
}
