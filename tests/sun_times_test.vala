using GLib;

private string zoneinfo_dir;

private int minutes_of(string hhmm) {
    var parts = hhmm.split(":");
    assert(parts.length == 2);
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}

private void check_local(string tz_id, double lat, double lon, int y, int m, int d, string sunrise, string sunset) {
    TimeZone tz;
    try {
        tz = new TimeZone.identifier(tz_id);
    } catch (Error e) {
        Test.skip("timezone %s not installed".printf(tz_id));
        return;
    }
    var day = new DateTime(tz, y, m, d, 12, 0, 0);
    string got_set, got_rise;
    assert(Singularity.SunTimes.local_times(lat, lon, day, out got_set, out got_rise) == Singularity.SunDay.NORMAL);
    int rise_diff = (minutes_of(got_rise) - minutes_of(sunrise)).abs();
    int set_diff = (minutes_of(got_set) - minutes_of(sunset)).abs();
    if (rise_diff > 4 || set_diff > 4)
        error("%s %04d-%02d-%02d: got %s/%s, expected %s/%s", tz_id, y, m, d, got_rise, got_set, sunrise, sunset);
}

void test_rome_summer() {
    check_local("Europe/Rome", 41.9, 12.4833, 2026, 6, 21, "05:35", "20:48");
}

void test_london_winter() {
    check_local("Europe/London", 51.5083, -0.1253, 2026, 12, 21, "08:04", "15:53");
}

void test_sydney_southern_summer() {
    check_local("Australia/Sydney", -33.8667, 151.2167, 2026, 12, 21, "05:41", "20:05");
}

void test_polar() {
    double rise, set;
    assert(Singularity.SunTimes.compute(69.65, 18.96, 2026, 6, 21, out rise, out set) == Singularity.SunDay.POLAR_DAY);
    assert(Singularity.SunTimes.compute(69.65, 18.96, 2026, 12, 21, out rise, out set) == Singularity.SunDay.POLAR_NIGHT);
    assert(Singularity.SunTimes.compute(-77.85, 166.67, 2026, 12, 21, out rise, out set) == Singularity.SunDay.POLAR_DAY);
}

void test_equinox_day_length() {
    double rise, set;
    assert(Singularity.SunTimes.compute(0.0, 0.0, 2026, 3, 20, out rise, out set) == Singularity.SunDay.NORMAL);
    double length = set - rise;
    assert(length > 12 * 60 && length < 12 * 60 + 10);
    assert((rise + set) / 2 > 720 - 10 && (rise + set) / 2 < 720 + 10);
}

void test_iso6709() {
    double lat, lon;
    assert(Singularity.SunTimes.parse_iso6709("+4154+01229", out lat, out lon));
    assert((lat - 41.9).abs() < 0.001);
    assert((lon - 12.4833).abs() < 0.001);
    assert(Singularity.SunTimes.parse_iso6709("+513030-0000731", out lat, out lon));
    assert((lat - 51.5083).abs() < 0.001);
    assert((lon + 0.1253).abs() < 0.001);
    assert(Singularity.SunTimes.parse_iso6709("-3352+15113", out lat, out lon));
    assert((lat + 33.8667).abs() < 0.001);
    assert(!Singularity.SunTimes.parse_iso6709("garbage", out lat, out lon));
    assert(!Singularity.SunTimes.parse_iso6709("+41x4+01229", out lat, out lon));
}

void test_timezone_lookup() {
    double lat, lon;
    assert(Singularity.SunTimes.timezone_coordinates("Europe/Rome", out lat, out lon, zoneinfo_dir));
    assert((lat - 41.9).abs() < 0.001);
    assert(Singularity.SunTimes.timezone_coordinates("Australia/Sydney", out lat, out lon, zoneinfo_dir));
    assert(lat < 0);
    assert(!Singularity.SunTimes.timezone_coordinates("Mars/Olympus", out lat, out lon, zoneinfo_dir));
    assert(!Singularity.SunTimes.timezone_coordinates("Europe/Rome", out lat, out lon, "/nonexistent"));
}

public static int main(string[] args) {
    Test.init(ref args);
    zoneinfo_dir = args.length > 1 ? args[1] : "tests/fixtures/zoneinfo";
    Test.add_func("/sun-times/rome-summer", test_rome_summer);
    Test.add_func("/sun-times/london-winter", test_london_winter);
    Test.add_func("/sun-times/sydney", test_sydney_southern_summer);
    Test.add_func("/sun-times/polar", test_polar);
    Test.add_func("/sun-times/equinox", test_equinox_day_length);
    Test.add_func("/sun-times/iso6709", test_iso6709);
    Test.add_func("/sun-times/timezone", test_timezone_lookup);
    return Test.run();
}
