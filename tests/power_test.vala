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
    var backend = Singularity.PowerActions.backend_for(config, out choice);
    assert(choice == "command");
    assert(backend is Singularity.CommandSuspendBackend);

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
    string fake = script("fake-suspend", "echo \"$@\" > %s\n".printf(marker));
    var backend = new Singularity.CommandSuspendBackend(fake + " mem");
    var missing = new Singularity.CommandSuspendBackend(Path.build_filename(fixture_root, "bin", "absent"));
    var failing = new Singularity.CommandSuspendBackend(script("fail-suspend", "exit 3\n"));
    bool done = false;
    bool available = false;
    bool missing_available = true;
    bool failed = false;
    run_async(() => {
        backend.is_available.begin((obj, res) => {
            available = backend.is_available.end(res);
            missing.is_available.begin((obj2, res2) => {
                missing_available = missing.is_available.end(res2);
                backend.suspend.begin((obj3, res3) => {
                    try {
                        backend.suspend.end(res3);
                    } catch (Error e) {
                        error("suspend failed: %s", e.message);
                    }
                    failing.suspend.begin((obj4, res4) => {
                        try {
                            failing.suspend.end(res4);
                        } catch (Error e) {
                            failed = true;
                        }
                        done = true;
                    });
                });
            });
        });
        return Source.REMOVE;
    });
    wait_for(() => done);
    assert(done);
    assert(available);
    assert(!missing_available);
    assert(failed);
    assert(read_file(marker) == "mem");
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
    string helper = script("fake-helper",
        "[ \"$1\" = charge-limit ] || exit 2\necho \"$3\" > %s/$2/charge_control_end_threshold\n".printf(root));
    var manager = new Singularity.BatteryManager(root, new Singularity.CommandChargeLimit(helper));
    assert(manager.charge_limit_available);
    assert(!manager.charge_limit_active);

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
    assert(read_file(Path.build_filename(root, "BAT0", "charge_control_end_threshold")) == "80");
    assert(manager.charge_limit_active);
    assert(manager.primary.charge_limit == 80);

    done = false;
    run_async(() => {
        manager.set_charge_limited.begin(false, (obj, res) => {
            try {
                manager.set_charge_limited.end(res);
            } catch (Error e) {
                error("unlimit failed: %s", e.message);
            }
            done = true;
        });
        return Source.REMOVE;
    });
    wait_for(() => done);
    assert(read_file(Path.build_filename(root, "BAT0", "charge_control_end_threshold")) == "100");
    assert(!manager.charge_limit_active);

    var broken = new Singularity.BatteryManager(root, new Singularity.CommandChargeLimit(script("deny-helper", "echo denied >&2\nexit 1\n")));
    string message = "";
    done = false;
    run_async(() => {
        broken.set_charge_limited.begin(true, (obj, res) => {
            try {
                broken.set_charge_limited.end(res);
            } catch (Error e) {
                message = e.message;
            }
            done = true;
        });
        return Source.REMOVE;
    });
    wait_for(() => done);
    assert(message == "denied");

    string conf = Path.build_filename(fixture_root, "limit.conf");
    write_file(conf, "[Battery]\nSysfsPath=%s\nChargeLimit=none\n".printf(root));
    var disabled = Singularity.BatteryManager.from_config(new Singularity.PowerConfig.from_file(conf));
    assert(disabled.batteries.size == 2);
    assert(!disabled.charge_limit_available);

    write_file(conf, "[Battery]\nSysfsPath=%s\nChargeLimitCommand=%s\n".printf(root, helper));
    var replaced = Singularity.BatteryManager.from_config(new Singularity.PowerConfig.from_file(conf));
    assert(replaced.charge_limit_available);
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
    return Test.run();
}
