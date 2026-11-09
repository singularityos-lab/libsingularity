using Singularity.Profiles;

void check(bool cond, string what) {
    if (!cond) {
        stderr.printf("FAIL: %s\n", what);
        Process.exit(1);
    }
}

Facts facts_at(int hour, int minute, int weekday) {
    var f = new Facts();
    var monday = new DateTime.local(2026, 11, 9, hour, minute, 0);
    f.now = monday.add_days(weekday - 1);
    return f;
}

void test_roundtrip() {
    var set = ProfileSet.defaults();
    var again = ProfileSet.from_data(set.to_data());
    check(again != null, "defaults parse back");
    check(again.profiles.size == 5, "five builtin profiles");
    var evening = again.find("evening");
    check(evening != null && evening.builtin, "evening is builtin");
    check(same_value(evening.get_value(Areas.APPEARANCE, "dark-mode"), "true"), "evening dark mode survives");
    check(evening.rules.size == 1 && !evening.rules[0].enabled, "evening rule is off by default");
    var time = evening.rules[0].conditions[0];
    check(time.start_minute == 20 * 60 && time.end_minute == 23 * 60, "evening hours survive");
    check(ProfileSet.from_data("{\"version\": 99, \"profiles\": []}") == null, "newer format refused");
}

void test_values() {
    var p = new Profile("p", "P", "x");
    p.set_value("audio", "volume", "40");
    p.set_value("audio", "output", string_value("hdmi"));
    check(p.count_values() == 2, "two values");
    p.unset_value("audio", "volume");
    check(p.count_values() == 1, "unset removes");
    p.unset_value("audio", "output");
    check(p.areas().length == 0, "empty area dropped");
    check(same_value("{\"a\": 1, \"b\": [1,2]}", "{\"b\":[1,2],\"a\":1}"), "json equality ignores layout");
    check(!same_value("1", "2"), "different numbers differ");
    check(same_value(string_value("x"), "\"x\""), "string encoding");
}

void test_conditions() {
    var c = new Condition(ConditionKind.TIME);
    c.start_minute = 23 * 60;
    c.end_minute = 7 * 60;
    check(c.holds(facts_at(23, 30, 1)), "overnight start");
    check(c.holds(facts_at(6, 59, 2)), "overnight after midnight");
    check(!c.holds(facts_at(7, 0, 2)), "overnight end exclusive");
    c.days = 1;
    check(c.holds(facts_at(2, 0, 2)), "night that started monday counts on tuesday");
    check(!c.holds(facts_at(23, 30, 2)), "tuesday evening excluded");

    var f = new Facts();
    f.wifi_ssid = "Office";
    var w = new Condition(ConditionKind.WIFI);
    w.match = "Office";
    check(w.holds(f), "wifi match");
    w.match = "Home";
    check(!w.holds(f), "wifi mismatch");

    var s = new Condition(ConditionKind.SCREEN);
    s.match = "dell";
    f.screens = { "DP-1 Dell U2720Q" };
    check(s.holds(f), "screen substring, case insensitive");

    var b = new Condition(ConditionKind.BATTERY);
    b.below_percent = 20;
    f.on_battery = true;
    f.battery_percent = 15;
    check(b.holds(f), "low battery");
    f.on_battery = false;
    check(!b.holds(f), "charging is not low battery");

    var k = new Condition(ConditionKind.KEY);
    f.key_present = true;
    f.key_owner = "mirko";
    check(k.holds(f), "any key");
    k.match = "anna";
    check(!k.holds(f), "someone else's key");
}

void test_choose() {
    var set = new ProfileSet();
    var work = new Profile("work", "Work", "x");
    var r1 = new Rule();
    var t = new Condition(ConditionKind.TIME);
    t.start_minute = 9 * 60;
    t.end_minute = 18 * 60;
    r1.conditions.add(t);
    work.rules.add(r1);
    set.profiles.add(work);

    var office = new Profile("office", "Office", "x");
    var r2 = new Rule();
    var t2 = new Condition(ConditionKind.TIME);
    t2.start_minute = 9 * 60;
    t2.end_minute = 18 * 60;
    var wifi = new Condition(ConditionKind.WIFI);
    wifi.match = "Office";
    r2.conditions.add(t2);
    r2.conditions.add(wifi);
    office.rules.add(r2);
    set.profiles.add(office);

    var f = facts_at(10, 0, 1);
    check(set.choose("", "", f).profile.id == "work", "only the time rule holds");
    f.wifi_ssid = "Office";
    var sel = set.choose("", "", f);
    check(sel.profile.id == "office" && !sel.manual && sel.rule.specificity == 2, "more specific rule wins");
    check(set.choose("work", "", f).profile.id == "work" && set.choose("work", "", f).manual, "manual wins");
    check(set.choose("", "office", f).profile.id == "work", "suppressed profile is skipped");
    check(set.choose("", "", facts_at(20, 0, 1)).profile == null, "nothing outside hours");
    check(set.choose("missing", "", facts_at(20, 0, 1)).profile == null, "unknown manual id ignored");
}

void test_area() {
    var area = new Area("audio", "Sound", "audio-volume-high-symbolic");
    var store = new Gee.HashMap<string, string>();
    store["volume"] = "50";
    area.add(new Option("volume", "Volume", OptionKind.INTEGER).with_range(0, 100));
    area.add(new Option("level", "Level", OptionKind.INTEGER)).read_only = true;
    area.handlers((key) => store[key], (key, json) => { store[key] = json; });
    try {
        var snap = area.snapshot({ "volume" });
        check(snap["volume"] == "50", "snapshot reads");
        var values = new HashTable<string, string>(str_hash, str_equal);
        values["volume"] = "30";
        values["level"] = "9";
        values["unknown"] = "1";
        area.apply(values);
        check(store["volume"] == "30", "apply writes");
        check(!store.has_key("level"), "read only key untouched");
        var info = AreaInfo.from_data(area.describe());
        check(info != null && info.options.size == 2 && info.find("volume").max == 100, "describe roundtrip");
    } catch (Error e) {
        check(false, e.message);
    }
    check(Area.path_segment("app:dev.sinty.music") == "app_dev_sinty_music", "object path segment");
}

int main(string[] args) {
    test_roundtrip();
    test_values();
    test_conditions();
    test_choose();
    test_area();
    print("profiles: ok\n");
    return 0;
}
