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

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/brightness/full-range-identity", test_full_range_is_identity);
    Test.add_func("/brightness/level-maps-into-limits", test_level_maps_into_limits);
    Test.add_func("/brightness/hardware-outside-limits", test_hardware_outside_limits_is_clamped);
    return Test.run();
}
