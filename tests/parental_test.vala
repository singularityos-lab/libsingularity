using Singularity.Parental;

static string scratch_dir() {
    string dir = Path.build_filename(Environment.get_tmp_dir(), "parental-test-%d".printf((int) Posix.getpid()));
    DirUtils.create_with_parents(dir, 0700);
    return dir;
}

static void test_bedtime() {
    var p = new Policy("sam");
    assert(!p.in_bedtime(22 * 60));
    p.bedtime_enabled = true;
    p.bedtime_start = 21 * 60;
    p.bedtime_end = 7 * 60;
    assert(p.in_bedtime(21 * 60));
    assert(p.in_bedtime(23 * 60 + 59));
    assert(p.in_bedtime(0));
    assert(p.in_bedtime(6 * 60 + 59));
    assert(!p.in_bedtime(7 * 60));
    assert(!p.in_bedtime(12 * 60));
    assert(p.minutes_until_bedtime(20 * 60 + 50) == 10);
    assert(p.minutes_until_bedtime(22 * 60) == 0);
    p.bedtime_start = 13 * 60;
    p.bedtime_end = 15 * 60;
    assert(p.in_bedtime(14 * 60));
    assert(!p.in_bedtime(15 * 60));
    assert(!p.in_bedtime(12 * 60));
}

static void test_limits() {
    var p = new Policy("sam");
    assert(p.seconds_left(99999) == -1);
    assert(p.evaluate(12 * 60, 99999) == Verdict.ALLOWED);
    p.daily_limit_minutes = 60;
    p.warning_minutes = 5;
    assert(p.seconds_left(0) == 3600);
    assert(p.seconds_left(4000) == 0);
    assert(p.evaluate(12 * 60, 10 * 60) == Verdict.ALLOWED);
    assert(p.evaluate(12 * 60, 55 * 60) == Verdict.WARNING);
    assert(p.evaluate(12 * 60, 60 * 60) == Verdict.LIMIT_REACHED);
    p.bedtime_enabled = true;
    p.bedtime_start = 21 * 60;
    p.bedtime_end = 7 * 60;
    assert(p.evaluate(20 * 60 + 57, 0) == Verdict.WARNING);
    assert(p.evaluate(21 * 60 + 1, 0) == Verdict.BEDTIME);
    assert(p.evaluate(22 * 60, 60 * 60) == Verdict.BEDTIME);
}

static void test_apps_and_web() {
    var p = new Policy("sam");
    p.set_app_blocked("org.example.Game.desktop", true);
    assert(p.blocks_app("org.example.Game"));
    assert(p.blocks_app("org.example.game.desktop"));
    assert(!p.blocks_app("org.example.Other"));
    p.set_app_blocked("org.example.Game", false);
    assert(!p.blocks_app("org.example.Game"));
    assert(p.blocked_apps.length == 0);

    p.blocked_sites = { "example.com", "https://www.Bad.org/path" };
    assert(!p.blocks_uri("https://example.com/"));
    p.web_filter_enabled = true;
    assert(p.blocks_uri("https://example.com/a"));
    assert(p.blocks_uri("http://news.example.com/"));
    assert(!p.blocks_uri("https://notexample.com/"));
    assert(p.blocks_uri("https://bad.org/"));
    assert(!p.blocks_uri("about:blank"));
    assert(!p.blocks_uri("file:///home/sam/a.html"));
    p.web_allow_listed_only = true;
    p.allowed_sites = { "kids.example.net" };
    assert(!p.blocks_uri("https://kids.example.net/game"));
    assert(p.blocks_uri("https://example.org/"));
}

static void test_roundtrip() {
    var p = new Policy("sam");
    p.blocked_apps = { "org.example.Game" };
    p.daily_limit_minutes = 90;
    p.warning_minutes = 10;
    p.bedtime_enabled = true;
    p.bedtime_start = 20 * 60 + 30;
    p.bedtime_end = 6 * 60 + 45;
    p.web_filter_enabled = true;
    p.blocked_sites = { "example.com" };
    try {
        var q = Policy.from_data("sam", p.to_data());
        assert(q.blocks_app("org.example.Game"));
        assert(q.daily_limit_minutes == 90);
        assert(q.warning_minutes == 10);
        assert(q.bedtime_enabled);
        assert(q.bedtime_start == 20 * 60 + 30);
        assert(q.bedtime_end == 6 * 60 + 45);
        assert(q.web_filter_enabled);
        assert(q.blocked_sites.length == 1);
        var bad = Policy.from_data("sam", "[Time]\nDailyLimitMinutes=999999\nBedtimeStart=99:99\n");
        assert(bad.daily_limit_minutes == 1440);
        assert(bad.bedtime_start == 21 * 60);
    } catch (Error e) {
        error(e.message);
    }
    assert(!new Policy("x").is_active);
    assert(p.is_active);
}

static void test_file_store() {
    string dir = scratch_dir();
    string policies = Path.build_filename(dir, "policies");
    DirUtils.create_with_parents(policies, 0700);
    string script = Path.build_filename(dir, "helper.sh");
    try {
        FileUtils.set_contents(script,
            "#!/bin/sh\nset -e\nD=%s\nif [ \"$1\" = set ]; then cat > \"$D/$2.conf\"; else rm -f \"$D/$2.conf\"; fi\n".printf(policies));
    } catch (Error e) {
        error(e.message);
    }
    FileUtils.chmod(script, 0755);
    var store = new FilePolicyStore(policies, script);
    assert(store.path_for("../etc") == null);
    assert(store.path_for("-rf") == null);
    assert(store.path_for("sam") == Path.build_filename(policies, "sam.conf"));
    assert(!store.load("sam").is_active);

    var p = new Policy("sam");
    p.daily_limit_minutes = 30;
    var loop = new MainLoop();
    Error? failure = null;
    store.save.begin(p, (obj, res) => {
        try {
            store.save.end(res);
        } catch (Error e) {
            failure = e;
        }
        loop.quit();
    });
    loop.run();
    assert(failure == null);
    assert(store.load("sam").daily_limit_minutes == 30);

    store.save.begin(new Policy("sam"), (obj, res) => {
        try {
            store.save.end(res);
        } catch (Error e) {
            failure = e;
        }
        loop.quit();
    });
    loop.run();
    assert(failure == null);
    assert(!FileUtils.test(Path.build_filename(policies, "sam.conf"), FileTest.EXISTS));

    var failing = new FilePolicyStore(policies, "/bin/false");
    failing.save.begin(p, (obj, res) => {
        try {
            failing.save.end(res);
        } catch (Error e) {
            failure = e;
        }
        loop.quit();
    });
    loop.run();
    assert(failure != null);
}

static void test_usage_store() {
    string path = Path.build_filename(scratch_dir(), "usage", "usage.json");
    var store = new JsonUsageStore(path, 35);
    var today = new DateTime.now_local();
    string d0 = UsageReport.day_key(today);
    string d1 = UsageReport.day_key(today.add_days(-1));
    string old = UsageReport.day_key(today.add_days(-60));
    store.add(d0, "org.example.Game", 600);
    store.add(d0, "org.example.Game", 60);
    store.add(d0, "org.example.Edit", 1200);
    store.add(d1, "org.example.Game", 300);
    store.add(old, "org.example.Game", 9999);
    store.add(d0, "", 50);
    store.add(d0, "org.example.Zero", 0);
    try {
        store.flush();
    } catch (Error e) {
        error(e.message);
    }
    var again = new JsonUsageStore(path, 35);
    var day0 = again.day(d0);
    assert(day0.size == 2);
    assert(day0[0].app_id == "org.example.Edit" && day0[0].seconds == 1200);
    assert(day0[1].seconds == 660);
    assert(UsageReport.total(day0) == 1860);
    assert(again.day(old).size == 0);
    int64[] week = UsageReport.week_totals(again, today);
    assert(week.length == 7);
    assert(week[6] == 1860);
    assert(week[5] == 300);
    assert(week[0] == 0);
    var apps = UsageReport.week_apps(again, today);
    assert(apps[0].app_id == "org.example.Edit");
    assert(apps[1].seconds == 960);
    var folded = UsageReport.fold(apps, 1);
    assert(folded.size == 2 && folded[1].app_id == "other" && folded[1].seconds == 960);
    Posix.chmod(path, 0);
    var locked = new JsonUsageStore(path, 35);
    if (Posix.getuid() != 0) assert(!locked.readable);
    Posix.chmod(path, 0600);
    try {
        again.clear();
    } catch (Error e) {
        error(e.message);
    }
    assert(new JsonUsageStore(path, 35).day(d0).size == 0);
}

static void test_format() {
    assert(UsageReport.format_duration(0) == "0 min");
    assert(UsageReport.format_duration(20) == "Under 1 min");
    assert(UsageReport.format_duration(90 * 60) == "1 h 30 min");
    assert(UsageReport.format_duration(120 * 60) == "2 h");
    assert(UsageReport.format_duration(45 * 60) == "45 min");
}

static void test_config() {
    string dir = scratch_dir();
    string path = Path.build_filename(dir, "parental-controls.conf");
    try {
        FileUtils.set_contents(path, "[Policy]\nBackend=file\nDirectory=/srv/p\n[Usage]\nDirectory=/var/lib/st/%u\n");
    } catch (Error e) {
        error(e.message);
    }
    var cfg = new Config.from_file(path);
    assert(cfg.backend == "file");
    assert(cfg.policy_directory == "/srv/p");
    assert(cfg.usage_directory_for("sam", "/home/sam") == "/var/lib/st/sam");
    var empty = new Config.from_file(Path.build_filename(dir, "missing.conf"));
    assert(empty.usage_directory_for("sam", "/home/sam") == "/home/sam/.local/share/singularity/screen-time");
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/parental/bedtime", test_bedtime);
    Test.add_func("/parental/limits", test_limits);
    Test.add_func("/parental/apps-web", test_apps_and_web);
    Test.add_func("/parental/roundtrip", test_roundtrip);
    Test.add_func("/parental/file-store", test_file_store);
    Test.add_func("/parental/usage-store", test_usage_store);
    Test.add_func("/parental/format", test_format);
    Test.add_func("/parental/config", test_config);
    return Test.run();
}
