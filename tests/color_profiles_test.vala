using GLib;

private void put32(uint8[] data, int at, uint32 value) {
    data[at] = (uint8) (value >> 24);
    data[at + 1] = (uint8) (value >> 16);
    data[at + 2] = (uint8) (value >> 8);
    data[at + 3] = (uint8) value;
}

private void put4(uint8[] data, int at, string tag) {
    for (int i = 0; i < 4; i++) data[at + i] = (uint8) tag[i];
}

private uint8[] make_profile(string device_class, string title, bool mluc) {
    int tag_offset = 144;
    int text_len = mluc ? title.length * 2 : title.length + 1;
    int tag_size = mluc ? 28 + text_len : 12 + text_len;
    var data = new uint8[tag_offset + tag_size];
    put32(data, 0, data.length);
    put4(data, 12, device_class);
    put4(data, 16, "RGB ");
    put4(data, 36, "acsp");
    put32(data, 128, 1);
    put4(data, 132, "desc");
    put32(data, 136, tag_offset);
    put32(data, 140, tag_size);
    if (mluc) {
        put4(data, tag_offset, "mluc");
        put32(data, tag_offset + 8, 1);
        put32(data, tag_offset + 12, 12);
        put4(data, tag_offset + 16, "enUS");
        put32(data, tag_offset + 20, text_len);
        put32(data, tag_offset + 24, 28);
        for (int i = 0; i < title.length; i++) {
            data[tag_offset + 28 + i * 2] = 0;
            data[tag_offset + 28 + i * 2 + 1] = (uint8) title[i];
        }
    } else {
        put4(data, tag_offset, "desc");
        put32(data, tag_offset + 8, text_len);
        for (int i = 0; i < title.length; i++) data[tag_offset + 12 + i] = (uint8) title[i];
    }
    return data;
}

void test_header() {
    assert(Singularity.ColorProfiles.is_display_profile(make_profile("mntr", "Panel", false)));
    assert(!Singularity.ColorProfiles.is_display_profile(make_profile("prtr", "Printer", false)));
    var broken = make_profile("mntr", "Panel", false);
    broken[36] = 'x';
    assert(!Singularity.ColorProfiles.is_display_profile(broken));
    assert(!Singularity.ColorProfiles.is_display_profile(new uint8[40]));
}

void test_title() {
    assert(Singularity.ColorProfiles.profile_title(make_profile("mntr", "Studio Display", false), "x") == "Studio Display");
    assert(Singularity.ColorProfiles.profile_title(make_profile("mntr", "Calibrated D65", true), "x") == "Calibrated D65");
    var no_tags = make_profile("mntr", "Panel", false);
    put32(no_tags, 128, 0);
    assert(Singularity.ColorProfiles.profile_title(no_tags, "fallback.icc") == "fallback.icc");
}

void test_display_key() {
    assert(Singularity.ColorProfiles.display_key("DEL", "U2720Q", "ABC123", "DP-1") == "DEL U2720Q ABC123");
    assert(Singularity.ColorProfiles.display_key("", "", "", "HDMI-A-1") == "HDMI-A-1");
    assert(Singularity.ColorProfiles.display_key("BOE", "", "", "eDP-1") == "BOE");
}

void test_scan() {
    string root = Path.build_filename(Environment.get_tmp_dir(), "color-profiles-test-%d".printf((int) Posix.getpid()));
    string user = Path.build_filename(root, "user");
    string system = Path.build_filename(root, "system", "vendor");
    DirUtils.create_with_parents(user, 0755);
    DirUtils.create_with_parents(system, 0755);
    try {
        FileUtils.set_data(Path.build_filename(user, "mine.icc"), make_profile("mntr", "My Panel", false));
        FileUtils.set_data(Path.build_filename(user, "printer.icc"), make_profile("prtr", "Printer", false));
        FileUtils.set_data(Path.build_filename(user, "notes.txt"), make_profile("mntr", "Ignored", false));
        FileUtils.set_data(Path.build_filename(system, "Vendor.ICM"), make_profile("mntr", "Adobe RGB", true));
    } catch (FileError e) {
        error("%s", e.message);
    }
    var list = Singularity.ColorProfiles.scan_dirs({ user, Path.build_filename(root, "system"), "/nonexistent" });
    assert(list.size == 2);
    assert(list[0].title == "Adobe RGB");
    assert(!list[0].user);
    assert(list[1].title == "My Panel");
    assert(list[1].user);
    FileUtils.remove(Path.build_filename(user, "mine.icc"));
    FileUtils.remove(Path.build_filename(user, "printer.icc"));
    FileUtils.remove(Path.build_filename(user, "notes.txt"));
    FileUtils.remove(Path.build_filename(system, "Vendor.ICM"));
}

public static int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/color-profiles/header", test_header);
    Test.add_func("/color-profiles/title", test_title);
    Test.add_func("/color-profiles/display-key", test_display_key);
    Test.add_func("/color-profiles/scan", test_scan);
    return Test.run();
}
