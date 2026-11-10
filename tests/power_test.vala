using GLib;

private string fixture_root;

private void write_file(string path, string contents) {
    assert(DirUtils.create_with_parents(Path.get_dirname(path), 0755) == 0);
    try {
        assert(FileUtils.set_contents(path, contents));
    } catch (FileError e) {
        error("fixture write failed: %s", e.message);
    }
}

private string read_file(string path) {
    try {
        string contents;
        FileUtils.get_contents(path, out contents);
        return contents.strip();
    } catch (FileError e) {
        return "";
    }
}

private string script(string name, string body) {
    string path = Path.build_filename(fixture_root, "bin", name);
    write_file(path, "#!/bin/sh\n" + body);
    FileUtils.chmod(path, 0755);
    return path;
}

private void supply(string name, string type, string[] files) {
    string dir = Path.build_filename(fixture_root, "power_supply", name);
    write_file(Path.build_filename(dir, "type"), type + "\n");
    for (int i = 0; i + 1 < files.length; i += 2) {
        write_file(Path.build_filename(dir, files[i]), files[i + 1] + "\n");
    }
}

private void run_async(owned SourceFunc body) {
    Idle.add((owned) body);
}

private void wait_for(owned SourceFunc done_check) {
    var loop = new MainLoop();
    Timeout.add(20, () => {
        if (done_check()) {
            loop.quit();
            return Source.REMOVE;
        }
        return Source.CONTINUE;
    });
    Timeout.add_seconds(10, () => {
        loop.quit();
        return Source.REMOVE;
    });
    loop.run();
}

private void test_config_backends() {
    string path = Path.build_filename(fixture_root, "power.conf");
    write_file(path, "[Suspend]\nBackend=command\nCommand=/bin/true --flag\n[Battery]\nChargeLimit=none\n");
    var config = new Singularity.PowerConfig.from_file(path);
    assert(config.source_path == path);
    assert(config.get_string("Suspend", "Command", "") == "/bin/true --flag");
    assert(config.get_string("Missing", "Key", "fallback") == "fallback");
    string choice;
    assert(Singularity.PowerActions.backend_for(config, out choice) == null);
    assert(choice == "command");

    write_file(path, "[Suspend]\nBackend=elogind\n");
    config = new Singularity.PowerConfig.from_file(path);
    assert(Singularity.PowerActions.backend_for(config, out choice) is Singularity.LogindSuspendBackend);

    write_file(path, "[Suspend]\nBackend=none\n");
    config = new Singularity.PowerConfig.from_file(path);
    assert(Singularity.PowerActions.backend_for(config, out choice) == null);
    assert(choice == "none");

    write_file(path, "");
    config = new Singularity.PowerConfig.from_file(path);
    assert(Singularity.PowerActions.backend_for(config, out choice) == null);
    assert(choice == "auto");
}

private void test_command_suspend() {
    string marker = Path.build_filename(fixture_root, "suspended");
    var backend = new Singularity.CommandSuspendBackend(script("fake-suspend", "touch %s\n".printf(marker)));
    bool done = false;
    bool available = true;
    bool refused = false;
    run_async(() => {
        backend.is_available.begin((obj, res) => {
            available = backend.is_available.end(res);
            backend.suspend.begin((obj2, res2) => {
                try {
                    backend.suspend.end(res2);
                } catch (Error e) {
                    refused = e is IOError.NOT_SUPPORTED;
                }
                done = true;
            });
        });
        return Source.REMOVE;
    });
    wait_for(() => done);
    assert(done);
    assert(!available);
    assert(refused);
    assert(!FileUtils.test(marker, FileTest.EXISTS));
}

private void test_battery_scan() {
    supply("AC", "Mains", { "online", "1" });
    supply("BAT0", "Battery", {
        "present", "1", "status", "Discharging", "capacity", "64",
        "energy_full", "42000000", "energy_full_design", "50000000",
        "cycle_count", "312", "charge_control_end_threshold", "100",
        "model_name", "Fixture Cell"
    });
    supply("BAT1", "Battery", {
        "present", "1", "capacity", "90",
        "charge_full", "3000000", "charge_full_design", "4000000", "cycle_count", "0"
    });
    supply("hid-mouse-battery", "Battery", { "scope", "Device", "capacity", "20" });
    supply("BAT9", "Battery", { "present", "0" });

    var list = Singularity.BatteryHealth.scan(Path.build_filename(fixture_root, "power_supply"));
    assert(list.size == 2);
    var bat0 = list[0];
    assert(bat0.name == "BAT0");
    assert(bat0.level == 64);
    assert(bat0.health == 84);
    assert(bat0.cycles == 312);
    assert(bat0.charge_limit == 100);
    assert(bat0.limit_supported);
    assert(bat0.model == "Fixture Cell");
    var bat1 = list[1];
    assert(bat1.health == 75);
    assert(bat1.cycles == -1);
    assert(!bat1.limit_supported);

    assert(Singularity.BatteryHealth.scan(Path.build_filename(fixture_root, "nowhere")).size == 0);
}

private void test_charge_limit() {
    string root = Path.build_filename(fixture_root, "power_supply");
    string marker = Path.build_filename(fixture_root, "helper-ran");
    string helper = script("fake-helper", "touch %s\n".printf(marker));
    var manager = new Singularity.BatteryManager(root, new Singularity.CommandChargeLimit(helper));
    assert(!manager.charge_limit_available);

    bool done = false;
    run_async(() => {
        manager.set_charge_limited.begin(true, (obj, res) => {
            try {
                manager.set_charge_limited.end(res);
            } catch (Error e) {
                error("limit failed: %s", e.message);
            }
            done = true;
        });
        return Source.REMOVE;
    });
    wait_for(() => done);
    assert(!FileUtils.test(marker, FileTest.EXISTS));
    assert(read_file(Path.build_filename(root, "BAT0", "charge_control_end_threshold")) == "100");
    assert(!manager.charge_limit_active);

    string conf = Path.build_filename(fixture_root, "limit.conf");
    write_file(conf, "[Battery]\nSysfsPath=%s\nChargeLimit=none\n".printf(root));
    var disabled = Singularity.BatteryManager.from_config(new Singularity.PowerConfig.from_file(conf));
    assert(disabled.batteries.size == 2);
    assert(!disabled.charge_limit_available);

    write_file(conf, "[Battery]\nSysfsPath=%s\nChargeLimitCommand=%s\n".printf(root, helper));
    var replaced = Singularity.BatteryManager.from_config(new Singularity.PowerConfig.from_file(conf));
    assert(replaced.charge_limit_available);
    assert(replaced.charge_limit_backend is Singularity.UPowerChargeLimit);
}

[DBus (name = "org.freedesktop.UPower")]
public class MockUPower : Object {
    public ObjectPath[] enumerate_devices() throws Error {
        return { new ObjectPath("/org/freedesktop/UPower/devices/line_power_AC"),
            new ObjectPath("/org/freedesktop/UPower/devices/battery_BAT0") };
    }
}

[DBus (name = "org.freedesktop.UPower.Device")]
public class MockUPowerDevice : Object {
    public string native_path { owned get; construct; }
    public string file { get; construct; }

    public MockUPowerDevice(string native_path, string file) {
        Object(native_path: native_path, file: file);
    }

    public void enable_charge_threshold(bool enable) throws Error {
        if (file == "") throw new IOError.NOT_SUPPORTED("no threshold");
        FileUtils.set_contents(file, enable ? "80" : "100");
    }
}

private void test_upower_charge_limit() {
    var bus = new TestDBus(TestDBusFlags.NONE);
    bus.up();
    Environment.set_variable("DBUS_SYSTEM_BUS_ADDRESS", bus.get_bus_address(), true);
    string root = Path.build_filename(fixture_root, "power_supply");
    string end_file = Path.build_filename(root, "BAT0", "charge_control_end_threshold");
    try {
        var conn = Bus.get_sync(BusType.SYSTEM);
        conn.register_object("/org/freedesktop/UPower", new MockUPower());
        conn.register_object("/org/freedesktop/UPower/devices/line_power_AC", new MockUPowerDevice("AC", ""));
        conn.register_object("/org/freedesktop/UPower/devices/battery_BAT0", new MockUPowerDevice("BAT0", end_file));
        conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
            new Variant("(su)", "org.freedesktop.UPower", 0), null, DBusCallFlags.NONE, -1);
    } catch (Error e) {
        error("mock: %s", e.message);
    }
    var manager = new Singularity.BatteryManager(root, new Singularity.UPowerChargeLimit());
    assert(manager.charge_limit_available);
    foreach (bool limited in new bool[] { true, false }) {
        bool done = false;
        run_async(() => {
            manager.set_charge_limited.begin(limited, (obj, res) => {
                try {
                    manager.set_charge_limited.end(res);
                } catch (Error e) {
                    error("upower limit failed: %s", e.message);
                }
                done = true;
            });
            return Source.REMOVE;
        });
        wait_for(() => done);
        assert(read_file(end_file) == (limited ? "80" : "100"));
        assert(manager.charge_limit_active == limited);
    }
    bus.down();
}

public static int main(string[] args) {
    Test.init(ref args);
    try {
        fixture_root = DirUtils.make_tmp("power-test-XXXXXX");
    } catch (FileError e) {
        error("tmp: %s", e.message);
    }
    Test.add_func("/power/config", test_config_backends);
    Test.add_func("/power/command-suspend", test_command_suspend);
    Test.add_func("/power/battery-scan", test_battery_scan);
    Test.add_func("/power/charge-limit", test_charge_limit);
    Test.add_func("/power/upower-charge-limit", test_upower_charge_limit);
    return Test.run();
}
