using GLib;

private string fixture_root;

private void write_vendor(string card, string vendor) {
    string device = Path.build_filename(fixture_root, card, "device");
    assert(DirUtils.create_with_parents(device, 0755) == 0);
    try {
        assert(FileUtils.set_contents(
            Path.build_filename(device, "vendor"), vendor
        ));
    } catch (FileError e) {
        error("fixture write failed: %s", e.message);
    }
}

private void remove_path(File file) {
    try {
        var type = file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        if (type == FileType.DIRECTORY) {
            var children = file.enumerate_children(
                FileAttribute.STANDARD_NAME,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS
            );
            FileInfo? info;
            while ((info = children.next_file()) != null) {
                remove_path(file.get_child(info.get_name()));
            }
        }
        file.delete();
    } catch (Error e) {
        error("cleanup failed: %s", e.message);
    }
}

private void reset_fixture() {
    if (FileUtils.test(fixture_root, FileTest.EXISTS)) {
        remove_path(File.new_for_path(fixture_root));
    }
    assert(DirUtils.create_with_parents(fixture_root, 0755) == 0);
}

private void test_secondary_intel_card() {
    reset_fixture();
    assert(DirUtils.create_with_parents(
        Path.build_filename(fixture_root, "card0"), 0755
    ) == 0);
    write_vendor("card1", "0x8086\n");
    assert(
        Singularity.HardwareInfo.graphics_from_drm(fixture_root)
        == "Intel Graphics"
    );
}

private void test_hybrid_graphics() {
    reset_fixture();
    write_vendor("card1", "0x8086\n");
    write_vendor("card2", "0x10de\n");
    assert(
        Singularity.HardwareInfo.graphics_from_drm(fixture_root)
        == "Intel + NVIDIA Graphics"
    );
}

private void test_connector_is_ignored() {
    reset_fixture();
    write_vendor("card0-DP-1", "0x1002\n");
    assert(
        Singularity.HardwareInfo.graphics_from_drm(fixture_root)
        == "Unknown Graphics"
    );
}

private int main(string[] args) {
    Test.init(ref args);
    string root = Environment.get_variable("MESON_BUILD_ROOT")
        ?? Environment.get_current_dir();
    fixture_root = Path.build_filename(
        root, "hardware-info-" + Uuid.string_random()
    );

    Test.add_func("/hardware-info/secondary-intel-card", test_secondary_intel_card);
    Test.add_func("/hardware-info/hybrid-graphics", test_hybrid_graphics);
    Test.add_func("/hardware-info/ignore-connector", test_connector_is_ignored);
    int result = Test.run();
    if (FileUtils.test(fixture_root, FileTest.EXISTS)) {
        remove_path(File.new_for_path(fixture_root));
    }
    return result;
}
