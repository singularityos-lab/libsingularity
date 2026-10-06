using Singularity.Widgets;

string root;

void write_file(string path, string content) {
    DirUtils.create_with_parents(Path.get_dirname(path), 0755);
    try {
        FileUtils.set_contents(path, content);
    } catch (FileError e) {
        error("%s", e.message);
    }
}

void write_app(string id, string type) {
    write_file(Path.build_filename(root, "data", "applications", id),
        "[Desktop Entry]\nType=Application\nName=%s\nExec=true %%f\nMimeType=%s;\n".printf(id, type));
}

void test_no_default_until_chosen() {
    assert(!FileOpener.has_chosen_default("application/x-opener-test"));
}

void test_user_choice_is_detected() {
    write_file(Path.build_filename(root, "config", "mimeapps.list"),
        "[Default Applications]\napplication/x-opener-test=opener-b.desktop;\n");
    assert(FileOpener.has_chosen_default("application/x-opener-test"));
    assert(!FileOpener.has_chosen_default("application/x-opener-other"));
}

void test_missing_app_is_not_a_choice() {
    write_file(Path.build_filename(root, "config", "mimeapps.list"),
        "[Default Applications]\napplication/x-opener-test=opener-missing.desktop;\n");
    assert(!FileOpener.has_chosen_default("application/x-opener-test"));
}

void test_desktop_specific_list_wins() {
    write_file(Path.build_filename(root, "config", "mimeapps.list"), "[Default Applications]\n");
    write_file(Path.build_filename(root, "config", "singularity-mimeapps.list"),
        "[Default Applications]\napplication/x-opener-test=opener-a.desktop;\n");
    assert(FileOpener.has_chosen_default("application/x-opener-test"));
}

int main(string[] args) {
    try {
        root = DirUtils.make_tmp("opener-XXXXXX");
    } catch (FileError e) {
        error("%s", e.message);
    }
    Environment.set_variable("XDG_CONFIG_HOME", Path.build_filename(root, "config"), true);
    Environment.set_variable("XDG_DATA_HOME", Path.build_filename(root, "data"), true);
    Environment.set_variable("XDG_CONFIG_DIRS", Path.build_filename(root, "sysconfig"), true);
    Environment.set_variable("XDG_DATA_DIRS", Path.build_filename(root, "sysdata"), true);
    Environment.set_variable("XDG_CURRENT_DESKTOP", "Singularity", true);
    write_app("opener-a.desktop", "application/x-opener-test");
    write_app("opener-b.desktop", "application/x-opener-test");
    Test.init(ref args);
    Test.add_func("/file-opener/no-default", test_no_default_until_chosen);
    Test.add_func("/file-opener/user-choice", test_user_choice_is_detected);
    Test.add_func("/file-opener/missing-app", test_missing_app_is_not_a_choice);
    Test.add_func("/file-opener/desktop-list", test_desktop_specific_list_wins);
    return Test.run();
}
