using GLib;

private class RecordingBackend : Object, Singularity.GammaBackend {
    public Gee.ArrayList<int> values = new Gee.ArrayList<int>();

    public void set_night_light(int temperature) {
        values.add(temperature);
    }

    public void reset_night_light() {
        values.add(Singularity.NightLightManager.TEMP_MAX);
    }
}

private const string SCHEMA = """<?xml version="1.0" encoding="UTF-8"?>
<schemalist>
  <schema id="dev.sinty.desktop" path="/dev/sinty/desktop/">
    <key name="night-light-enabled" type="b"><default>false</default></key>
    <key name="night-light-temperature" type="i"><default>4000</default></key>
    <key name="night-light-adaptive" type="b"><default>false</default></key>
    <key name="night-light-adaptive-from" type="s"><default>'19:00'</default></key>
    <key name="night-light-adaptive-to" type="s"><default>'07:00'</default></key>
    <key name="night-light-schedule" type="s"><default>'manual'</default></key>
    <key name="night-light-sun-from" type="s"><default>'19:00'</default></key>
    <key name="night-light-sun-to" type="s"><default>'07:00'</default></key>
    <key name="night-light-sun-source" type="s"><default>''</default></key>
    <key name="privacy-location-enabled" type="b"><default>false</default></key>
  </schema>
</schemalist>
""";

private void run_for(uint ms) {
    var loop = new MainLoop();
    Timeout.add(ms, () => {
        loop.quit();
        return Source.REMOVE;
    });
    loop.run();
}

void test_smooth_transition() {
    var settings = new Settings("dev.sinty.desktop");
    settings.reset("night-light-enabled");
    var manager = new Singularity.NightLightManager();
    var backend = new RecordingBackend();
    manager.backend = backend;
    manager.transition_ms = 300;
    manager.set_ease((t) => t * t * (3 - 2 * t));
    backend.values.clear();
    settings.set_boolean("night-light-enabled", true);
    run_for(600);
    assert(backend.values.size >= 8);
    assert(backend.values[backend.values.size - 1] == 4000);
    for (int i = 1; i < backend.values.size; i++) assert(backend.values[i] <= backend.values[i - 1]);
    assert(backend.values[0] < 6500 && backend.values[0] > 4000);
    backend.values.clear();
    settings.set_boolean("night-light-enabled", false);
    run_for(600);
    assert(backend.values.size >= 8);
    assert(backend.values[backend.values.size - 1] == 6500);
    for (int i = 1; i < backend.values.size; i++) assert(backend.values[i] >= backend.values[i - 1]);
}

void test_reduced_motion_is_instant() {
    var settings = new Settings("dev.sinty.desktop");
    settings.set_boolean("night-light-enabled", false);
    var manager = new Singularity.NightLightManager();
    var backend = new RecordingBackend();
    manager.backend = backend;
    manager.transition_ms = 0;
    backend.values.clear();
    settings.set_boolean("night-light-enabled", true);
    run_for(100);
    assert(backend.values.size == 1);
    assert(backend.values[0] == 4000);
    settings.set_boolean("night-light-enabled", false);
}

void test_sun_schedule_from_timezone() {
    var settings = new Settings("dev.sinty.desktop");
    var manager = new Singularity.NightLightManager();
    settings.set_boolean("privacy-location-enabled", false);
    settings.set_boolean("night-light-enabled", true);
    settings.set_boolean("night-light-adaptive", true);
    settings.set_string("night-light-schedule", "sunset-sunrise");
    run_for(100);
    assert(settings.get_string("night-light-sun-source") == "timezone");
    assert(manager.from_key() == "night-light-sun-from");
    string from = settings.get_string("night-light-sun-from");
    string to = settings.get_string("night-light-sun-to");
    assert(from.length == 5 && to.length == 5);
    assert(int.parse(from.substring(0, 2)) >= 16 && int.parse(from.substring(0, 2)) <= 21);
    assert(int.parse(to.substring(0, 2)) >= 4 && int.parse(to.substring(0, 2)) <= 9);
    settings.set_string("night-light-schedule", "manual");
    assert(manager.from_key() == "night-light-adaptive-from");
    settings.set_boolean("night-light-enabled", false);
    settings.set_boolean("night-light-adaptive", false);
}

public static int main(string[] args) {
    Test.init(ref args);
    string dir = Path.build_filename(Environment.get_tmp_dir(), "night-light-test-%d".printf((int) Posix.getpid()));
    DirUtils.create_with_parents(dir, 0755);
    try {
        FileUtils.set_contents(Path.build_filename(dir, "dev.sinty.desktop.gschema.xml"), SCHEMA);
        int status;
        Process.spawn_command_line_sync("glib-compile-schemas " + Shell.quote(dir), null, null, out status);
        assert(status == 0);
    } catch (Error e) {
        error("%s", e.message);
    }
    Environment.set_variable("GSETTINGS_SCHEMA_DIR", dir, true);
    Environment.set_variable("GSETTINGS_BACKEND", "memory", true);
    Environment.set_variable("TZ", "Europe/Rome", true);
    Test.add_func("/night-light/smooth-transition", test_smooth_transition);
    Test.add_func("/night-light/reduced-motion", test_reduced_motion_is_instant);
    Test.add_func("/night-light/sun-schedule-timezone", test_sun_schedule_from_timezone);
    int result = Test.run();
    FileUtils.remove(Path.build_filename(dir, "dev.sinty.desktop.gschema.xml"));
    FileUtils.remove(Path.build_filename(dir, "gschemas.compiled"));
    DirUtils.remove(dir);
    return result;
}
