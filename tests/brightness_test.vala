private void test_full_range_is_identity() {
    assert(Singularity.DisplayBrightness.level_to_hardware(40.0, 0.0, 100.0) == 40.0);
    assert(Singularity.DisplayBrightness.hardware_to_level(40.0, 0.0, 100.0) == 40.0);
}

private void test_level_maps_into_limits() {
    assert(Singularity.DisplayBrightness.level_to_hardware(0.0, 20.0, 80.0) == 20.0);
    assert(Singularity.DisplayBrightness.level_to_hardware(100.0, 20.0, 80.0) == 80.0);
    assert(Singularity.DisplayBrightness.level_to_hardware(50.0, 20.0, 80.0) == 50.0);
    assert(Singularity.DisplayBrightness.hardware_to_level(35.0, 20.0, 80.0) == 25.0);
}

private void test_hardware_outside_limits_is_clamped() {
    assert(Singularity.DisplayBrightness.hardware_to_level(10.0, 20.0, 80.0) == 0.0);
    assert(Singularity.DisplayBrightness.hardware_to_level(95.0, 20.0, 80.0) == 100.0);
}

private uint8[] base_edid(string? name, int hdr_min_code) {
    uint8[] e = new uint8[hdr_min_code >= 0 ? 256 : 128];
    uint8[] header = { 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    for (int i = 0; i < 8; i++) e[i] = header[i];
    uint8[] ident = { 0x4C, 0x2D, 0x34, 0x12, 0x01, 0x02, 0x03, 0x04, 0x10, 0x22 };
    for (int i = 0; i < 10; i++) e[8 + i] = ident[i];
    if (name != null) {
        int d = 72;
        e[d + 3] = 0xFC;
        for (int i = 0; i < 13; i++) e[d + 5 + i] = i < name.length ? name[i] : 0x0A;
    }
    if (hdr_min_code >= 0) {
        e[126] = 1;
        int b = 128;
        e[b] = 0x02; e[b + 1] = 0x03; e[b + 2] = 11;
        uint8[] block = { 0xE6, 0x06, 0x05, 0x01, 0x60, 0x50, (uint8) hdr_min_code };
        for (int i = 0; i < block.length; i++) e[b + 4 + i] = block[i];
    }
    return e;
}

private void test_edid_identity() {
    var a = Singularity.EdidFacts.parse(base_edid(null, -1));
    var b = Singularity.EdidFacts.parse(base_edid("Other Name", -1));
    assert(a.id == "7a8f58b1ea549f22");
    assert(a.id == b.id);
    assert(Singularity.EdidFacts.parse(new uint8[4]).id == "");
}

private void test_edid_emissive() {
    assert(!Singularity.EdidFacts.parse(base_edid("Office LCD", -1)).emissive);
    assert(Singularity.EdidFacts.parse(base_edid("27 OLED", -1)).emissive);
    assert(Singularity.EdidFacts.parse(base_edid(null, 1)).emissive);
    assert(!Singularity.EdidFacts.parse(base_edid(null, 0x50)).emissive);
}

private void test_software_floor() {
    assert(Singularity.DisplayBrightness.software_fraction(0.0) == Singularity.DisplayBrightness.SOFTWARE_FLOOR);
    assert(Singularity.DisplayBrightness.software_fraction(100.0) == 1.0);
    assert(Singularity.DisplayBrightness.software_fraction(-20.0) == Singularity.DisplayBrightness.SOFTWARE_FLOOR);
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/brightness/full-range-identity", test_full_range_is_identity);
    Test.add_func("/brightness/level-maps-into-limits", test_level_maps_into_limits);
    Test.add_func("/brightness/hardware-outside-limits", test_hardware_outside_limits_is_clamped);
    Test.add_func("/brightness/edid-identity", test_edid_identity);
    Test.add_func("/brightness/edid-emissive", test_edid_emissive);
    Test.add_func("/brightness/software-floor", test_software_floor);
    return Test.run();
}
