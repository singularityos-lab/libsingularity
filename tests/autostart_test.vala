using Singularity;

string root;

void write_entry(string dir, string name, string body) {
    try {
        DirUtils.create_with_parents(dir, 0755);
        FileUtils.set_contents(Path.build_filename(dir, name),
            "[Desktop Entry]\nType=Application\nName=" + name + "\n" + body);
    } catch (Error e) {
        error("%s", e.message);
    }
}

string[] names(Gee.List<string> paths) {
    string[] result = {};
    foreach (var p in paths) result += Path.get_basename(Path.get_dirname(p)) + "/" + Path.get_basename(p);
    return result;
}

AutostartManager host_like(string name) {
    string base_dir = Path.build_filename(root, name);
    string user = Path.build_filename(base_dir, "user");
    string etc = Path.build_filename(base_dir, "etc");
    string opt = Path.build_filename(base_dir, "opt");
    write_entry(etc, "nm-applet.desktop", "Exec=true\nNotShowIn=KDE;GNOME;\n");
    write_entry(etc, "gnome-only.desktop", "Exec=true\nOnlyShowIn=GNOME;\n");
    write_entry(etc, "plain.desktop", "Exec=true\n");
    write_entry(etc, "ours.desktop", "Exec=true\nOnlyShowIn=Singularity;\n");
    write_entry(etc, "ours-gnome-cond.desktop", "Exec=true\nOnlyShowIn=GNOME;Singularity;\nX-GNOME-AutostartCondition=GNOME3 if-session gnome\n");
    write_entry(opt, "dev.sinty.store.updates.desktop", "Exec=true\nNoDisplay=true\n");
    write_entry(opt, "dev.sinty.badge.desktop", "Exec=true\n");
    write_entry(opt, "not-here.desktop", "Exec=true\nNotShowIn=Singularity;\n");
    write_entry(user, "dev.sinty.badge.desktop", "Exec=true\nHidden=true\n");
    write_entry(user, "mine.desktop", "Exec=true\n");
    write_entry(user, "mine-off.desktop", "Exec=true\nX-GNOME-Autostart-enabled=false\n");
    return new AutostartManager.with_dirs(user, { opt }, { etc });
}

void test_only_prefix_and_named_entries_run() {
    var manager = host_like("run");
    var launched = names(manager.launchable_entries("Singularity"));
    assert(launched.length == 3);
    assert(launched[0] == "opt/dev.sinty.store.updates.desktop");
    assert(launched[1] == "user/mine.desktop");
    assert(launched[2] == "etc/ours.desktop");
    var visible = names(manager.visible_entries());
    assert(visible.length == 4);
    assert(visible[1] == "user/mine-off.desktop");
    assert(manager.contains("dev.sinty.store.updates.desktop"));
    assert(!manager.contains("dev.sinty.badge.desktop"));
    assert(!manager.contains("nm-applet.desktop"));
}

void test_system_rules() {
    string dir = Path.build_filename(root, "rules");
    write_entry(dir, "nm-applet.desktop", "Exec=true\nNotShowIn=KDE;GNOME;\n");
    write_entry(dir, "gnome.desktop", "Exec=true\nOnlyShowIn=GNOME;\n");
    write_entry(dir, "ours.desktop", "Exec=true\nOnlyShowIn=Singularity;\n");
    write_entry(dir, "hidden.desktop", "Exec=true\nHidden=true\nOnlyShowIn=Singularity;\n");
    write_entry(dir, "tryexec.desktop", "Exec=true\nTryExec=no-such-program-here\n");
    write_entry(dir, "not.desktop", "Exec=true\nNotShowIn=Singularity;\n");
    write_entry(dir, "cond-missing.desktop", "Exec=true\nX-GNOME-AutostartCondition=if-exists no-such-file-here\n");
    write_entry(dir, "cond-unless.desktop", "Exec=true\nX-GNOME-AutostartCondition=unless-exists no-such-file-here\n");
    write_entry(dir, "cond-gnome.desktop", "Exec=true\nX-GNOME-AutostartCondition=GNOME3 unless-session gnome\n");
    string p(string n) { return Path.build_filename(dir, n); }
    assert(!AutostartManager.system_entry_should_launch(p("nm-applet.desktop"), true, "Singularity"));
    assert(AutostartManager.system_entry_should_launch(p("nm-applet.desktop"), false, "Singularity"));
    assert(!AutostartManager.system_entry_should_launch(p("gnome.desktop"), true, "Singularity"));
    assert(!AutostartManager.system_entry_should_launch(p("gnome.desktop"), false, "Singularity"));
    assert(AutostartManager.system_entry_should_launch(p("ours.desktop"), true, "Singularity"));
    assert(!AutostartManager.system_entry_should_launch(p("ours.desktop"), true, "GNOME"));
    assert(!AutostartManager.system_entry_should_launch(p("hidden.desktop"), true, "Singularity"));
    assert(!AutostartManager.system_entry_should_launch(p("tryexec.desktop"), false, "Singularity"));
    assert(!AutostartManager.system_entry_should_launch(p("not.desktop"), false, "Singularity"));
    assert(!AutostartManager.system_entry_should_launch(p("cond-missing.desktop"), false, "Singularity"));
    assert(AutostartManager.system_entry_should_launch(p("cond-unless.desktop"), false, "Singularity"));
    assert(!AutostartManager.system_entry_should_launch(p("cond-gnome.desktop"), false, "Singularity"));
}

void test_remove_system_entry_hides_it() {
    string user = Path.build_filename(root, "remove", "user");
    string opt = Path.build_filename(root, "remove", "opt");
    write_entry(opt, "updates.desktop", "Exec=true\n");
    write_entry(user, "own.desktop", "Exec=true\n");
    var manager = new AutostartManager.with_dirs(user, { opt }, {});
    manager.remove(Path.build_filename(opt, "updates.desktop"));
    string override_path = Path.build_filename(user, "updates.desktop");
    assert(FileUtils.test(override_path, FileTest.EXISTS));
    assert(AutostartManager.is_hidden(override_path));
    assert(FileUtils.test(Path.build_filename(opt, "updates.desktop"), FileTest.EXISTS));
    assert(manager.visible_entries().size == 1);
    assert(manager.launchable_entries("Singularity").size == 1);
    manager.remove(Path.build_filename(user, "own.desktop"));
    assert(!FileUtils.test(Path.build_filename(user, "own.desktop"), FileTest.EXISTS));
    manager.remove("/etc/passwd");
    assert(FileUtils.test("/etc/passwd", FileTest.EXISTS));
}

int main(string[] args) {
    try {
        root = DirUtils.make_tmp("autostart-test-XXXXXX");
    } catch (FileError e) {
        error("%s", e.message);
    }
    Environment.set_variable("XDG_CONFIG_HOME", root, true);
    Test.init(ref args);
    Test.add_func("/autostart/only-prefix-and-named", test_only_prefix_and_named_entries_run);
    Test.add_func("/autostart/system-rules", test_system_rules);
    Test.add_func("/autostart/remove-system-entry", test_remove_system_entry_hides_it);
    return Test.run();
}
