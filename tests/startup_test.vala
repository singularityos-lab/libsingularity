using Singularity.Startup;

static GLib.Application app;

static void spin(Runner r) {
    var context = MainContext.default();
    int64 deadline = get_monotonic_time() + 10000000;
    while (r.running && get_monotonic_time() < deadline) context.iteration(true);
    while (context.pending()) context.iteration(false);
}

static Runner runner_for(Plan plan, RequestKind kind = RequestKind.ACTIVATE) {
    return new Runner(plan, app, new Request(kind));
}

static Plan full_plan(Gee.List<string> log) {
    var plan = new Plan();
    plan.main("config", Category.PREPARE, (c) => { log.add("config"); });
    plan.main("window", Category.SHELL, (c) => { log.add("window"); }).depends_on("config").reaches(Milestone.SHELL_READY);
    plan.worker("catalog", Category.CONTENT, (c) => { return new Gtk.StringObject("42"); }, (c, v) => { log.add("catalog=%s".printf(((Gtk.StringObject) v).string)); })
        .depends_on("config").reaches(Milestone.CONTENT_READY);
    plan.main("show", Category.CONTENT, (c) => { log.add("show"); }).depends_on("window").depends_on("catalog").reaches(Milestone.INTERACTIVE);
    plan.main("extras", Category.DEFERRED, (c) => { log.add("extras"); }).depends_on("show");
    return plan;
}

static void expect_invalid(Plan plan, string fragment) {
    try {
        plan.validate();
        assert_not_reached();
    } catch (PlanError e) {
        if (!(fragment in e.message)) error("expected \"%s\" in \"%s\"", fragment, e.message);
    }
}

static void test_validation() {
    var dup = new Plan();
    dup.main("a", Category.SHELL, (c) => {}).reaches(Milestone.SHELL_READY).reaches(Milestone.CONTENT_READY).reaches(Milestone.INTERACTIVE);
    dup.main("a", Category.SHELL, (c) => {});
    expect_invalid(dup, "declared twice");

    var missing = new Plan();
    missing.main("a", Category.SHELL, (c) => {}).depends_on("ghost").reaches(Milestone.SHELL_READY).reaches(Milestone.CONTENT_READY).reaches(Milestone.INTERACTIVE);
    expect_invalid(missing, "unknown task \"ghost\"");

    var cycle = new Plan();
    cycle.main("a", Category.SHELL, (c) => {}).depends_on("b").reaches(Milestone.SHELL_READY).reaches(Milestone.CONTENT_READY).reaches(Milestone.INTERACTIVE);
    cycle.main("b", Category.PREPARE, (c) => {}).depends_on("a");
    expect_invalid(cycle, "dependency cycle");

    var unreachable = new Plan();
    unreachable.main("a", Category.SHELL, (c) => {}).reaches(Milestone.SHELL_READY);
    expect_invalid(unreachable, "no task reaches milestone content-ready");

    var empty = new Plan();
    expect_invalid(empty, "no tasks");

    var deferred = new Plan();
    deferred.main("late", Category.DEFERRED, (c) => {}).reaches(Milestone.INTERACTIVE).reaches(Milestone.SHELL_READY).reaches(Milestone.CONTENT_READY);
    expect_invalid(deferred, "cannot gate an early milestone");

    var service = new Plan();
    service.main("load", Category.PREPARE, (c) => {});
    try {
        service.validate(false);
    } catch (PlanError e) {
        error("a service plan without milestones must be valid: %s", e.message);
    }

    var log = new Gee.ArrayList<string>();
    try {
        full_plan(log).validate();
    } catch (PlanError e) {
        error("valid plan rejected: %s", e.message);
    }
}

static void test_order_and_milestones() {
    var log = new Gee.ArrayList<string>();
    var r = runner_for(full_plan(log));
    var seen = new Gee.ArrayList<string>();
    r.milestone_reached.connect((m) => seen.add("%s@%d".printf(m.to_id(), log.size)));
    try {
        r.start();
    } catch (PlanError e) {
        error("%s", e.message);
    }
    spin(r);
    assert(!r.running);
    assert(log[0] == "config");
    assert(log.index_of("window") > 0 && log.index_of("catalog=42") > 0);
    assert(log.index_of("show") > log.index_of("window") && log.index_of("show") > log.index_of("catalog=42"));
    if (log[log.size - 1] != "extras") error("order: %s", string.joinv(",", log.to_array()));
    assert(seen.size == 4);
    assert(seen[0].has_prefix("shell-ready") || seen[0].has_prefix("content-ready"));
    assert(seen[2] == "interactive@%d".printf(log.index_of("show") + 1));
    assert(seen[3].has_prefix("settled"));
    int64 last = -1;
    foreach (var m in new Milestone[] { Milestone.SHELL_READY, Milestone.CONTENT_READY, Milestone.INTERACTIVE, Milestone.SETTLED }) {
        assert(r.reached_at(m) >= last);
        last = r.reached_at(m);
    }
}

static void test_window_independent_of_catalog() {
    var log = new Gee.ArrayList<string>();
    var plan = new Plan();
    var gate = new Cond();
    var mutex = Mutex();
    bool open = false;
    plan.worker("catalog", Category.CONTENT, (c) => {
        mutex.lock();
        while (!open) gate.wait(mutex);
        mutex.unlock();
        return null;
    }).reaches(Milestone.CONTENT_READY).reaches(Milestone.INTERACTIVE);
    plan.main("window", Category.SHELL, (c) => {
        log.add("window");
        mutex.lock();
        open = true;
        gate.signal();
        mutex.unlock();
    }).reaches(Milestone.SHELL_READY);
    var r = runner_for(plan);
    try {
        r.start();
    } catch (PlanError e) {
        error("%s", e.message);
    }
    spin(r);
    assert(log.size == 1);
    assert(r.reached_at(Milestone.SHELL_READY) <= r.reached_at(Milestone.CONTENT_READY));
}

static void test_recoverable_failure() {
    var log = new Gee.ArrayList<string>();
    var plan = new Plan();
    plan.main("window", Category.SHELL, (c) => { log.add("window"); }).reaches(Milestone.SHELL_READY).reaches(Milestone.CONTENT_READY);
    plan.worker("sync", Category.CONTENT, (c) => { throw new IOError.FAILED("offline"); }).recoverable("cloud");
    plan.main("cloud-view", Category.CONTENT, (c) => { log.add("cloud-view"); }).depends_on("sync");
    plan.main("local", Category.CONTENT, (c) => { log.add("local"); }).depends_on("window").reaches(Milestone.INTERACTIVE);
    var r = runner_for(plan);
    bool essential = false;
    r.essential_failure.connect(() => essential = true);
    try {
        r.start();
    } catch (PlanError e) {
        error("%s", e.message);
    }
    spin(r);
    assert(!essential);
    assert(!r.failed);
    assert(!("cloud-view" in log));
    assert("local" in log);
    assert("cloud" in r.disabled_features());
    assert(r.has_reached(Milestone.INTERACTIVE));
    assert(plan.get_task("sync").state == TaskState.FAILED);
    assert(plan.get_task("cloud-view").state == TaskState.SKIPPED);
}

static void test_essential_failure() {
    var plan = new Plan();
    plan.main("window", Category.SHELL, (c) => {}).reaches(Milestone.SHELL_READY);
    plan.worker("database", Category.CONTENT, (c) => { throw new IOError.FAILED("corrupt"); }).reaches(Milestone.CONTENT_READY);
    plan.main("show", Category.CONTENT, (c) => {}).depends_on("database").reaches(Milestone.INTERACTIVE);
    var r = runner_for(plan);
    string? reported = null;
    r.essential_failure.connect((t, e) => reported = "%s:%s".printf(t.id, e.message));
    try {
        r.start();
    } catch (PlanError e) {
        error("%s", e.message);
    }
    spin(r);
    assert(r.failed);
    assert(reported == "database:corrupt");
    assert(r.has_reached(Milestone.SHELL_READY));
    assert(!r.has_reached(Milestone.CONTENT_READY));
    assert(!r.has_reached(Milestone.INTERACTIVE));
    assert(plan.get_task("show").state == TaskState.SKIPPED);
}

static void test_hold_and_steps() {
    var log = new Gee.ArrayList<string>();
    var plan = new Plan();
    plan.main("async", Category.PREPARE, (c) => {
        var h = c.hold();
        Timeout.add(30, () => {
            log.add("async-done");
            h.release();
            return Source.REMOVE;
        });
    });
    int n = 0;
    plan.steps("fill", Category.SHELL, (c) => {
        log.add("step%d".printf(n));
        n++;
        return n < 5;
    }).depends_on("async").reaches(Milestone.SHELL_READY).reaches(Milestone.CONTENT_READY).reaches(Milestone.INTERACTIVE);
    var r = runner_for(plan);
    try {
        r.start();
    } catch (PlanError e) {
        error("%s", e.message);
    }
    spin(r);
    assert(log[0] == "async-done");
    assert(log.size == 6);
    assert(log[5] == "step4");
    assert(r.has_reached(Milestone.INTERACTIVE));
}

static void test_hold_failure() {
    var plan = new Plan();
    plan.main("dbus", Category.PREPARE, (c) => {
        var h = c.hold();
        Idle.add(() => {
            h.fail(new IOError.TIMED_OUT("no answer"));
            return Source.REMOVE;
        });
    }).reaches(Milestone.SHELL_READY).reaches(Milestone.CONTENT_READY).reaches(Milestone.INTERACTIVE);
    var r = runner_for(plan);
    try {
        r.start();
    } catch (PlanError e) {
        error("%s", e.message);
    }
    spin(r);
    assert(r.failed);
    assert(plan.get_task("dbus").error.message == "no answer");
}

static void test_cancel() {
    var log = new Gee.ArrayList<string>();
    var plan = new Plan();
    plan.worker("slow", Category.CONTENT, (c) => {
        while (!c.is_cancelled()) Thread.usleep(2000);
        return new Gtk.StringObject("done");
    }, (c, v) => { log.add("applied"); }).reaches(Milestone.SHELL_READY).reaches(Milestone.CONTENT_READY).reaches(Milestone.INTERACTIVE);
    plan.main("after", Category.DEFERRED, (c) => { log.add("after"); }).depends_on("slow");
    var r = runner_for(plan);
    try {
        r.start();
    } catch (PlanError e) {
        error("%s", e.message);
    }
    Timeout.add(50, () => {
        r.cancel();
        return Source.REMOVE;
    });
    spin(r);
    assert(!("applied" in log));
    assert(!("after" in log));
    assert(plan.get_task("slow").state == TaskState.CANCELLED);
    assert(plan.get_task("after").state == TaskState.CANCELLED);
    assert(!plan.get_task("slow").lingering);
}

static void test_lingering_worker() {
    var plan = new Plan();
    plan.worker("stubborn", Category.CONTENT, (c) => {
        Thread.usleep(2600000);
        return null;
    }).reaches(Milestone.SHELL_READY).reaches(Milestone.CONTENT_READY).reaches(Milestone.INTERACTIVE);
    var r = runner_for(plan);
    try {
        r.start();
    } catch (PlanError e) {
        error("%s", e.message);
    }
    Timeout.add(20, () => {
        r.cancel();
        return Source.REMOVE;
    });
    var context = MainContext.default();
    int64 deadline = get_monotonic_time() + 5000000;
    while (plan.get_task("stubborn").state == TaskState.RUNNING && get_monotonic_time() < deadline) context.iteration(true);
    assert(plan.get_task("stubborn").lingering);
}

static void test_concurrency_limit() {
    var plan = new Plan();
    int active = 0, peak = 0;
    var mutex = Mutex();
    for (int i = 0; i < 12; i++) {
        var t = plan.worker("w%d".printf(i), Category.CONTENT, (c) => {
            mutex.lock();
            active++;
            if (active > peak) peak = active;
            mutex.unlock();
            Thread.usleep(15000);
            mutex.lock();
            active--;
            mutex.unlock();
            return null;
        });
        if (i == 0) t.reaches(Milestone.SHELL_READY).reaches(Milestone.CONTENT_READY).reaches(Milestone.INTERACTIVE);
    }
    var r = runner_for(plan);
    r.max_workers = 3;
    try {
        r.start();
    } catch (PlanError e) {
        error("%s", e.message);
    }
    spin(r);
    assert(peak <= 3);
    assert(peak >= 2);
}

static void test_critical_first() {
    var log = new Gee.ArrayList<string>();
    var plan = new Plan();
    plan.main("deferred-early", Category.DEFERRED, (c) => { log.add("deferred"); });
    plan.main("prepare", Category.PREPARE, (c) => { log.add("prepare"); });
    plan.main("window", Category.SHELL, (c) => { log.add("window"); }).depends_on("prepare").reaches(Milestone.SHELL_READY).reaches(Milestone.CONTENT_READY).reaches(Milestone.INTERACTIVE);
    var r = runner_for(plan);
    try {
        r.start();
    } catch (PlanError e) {
        error("%s", e.message);
    }
    spin(r);
    assert(log[0] == "prepare");
    assert(log[1] == "window");
    assert(log[2] == "deferred");
}

static void test_wrapped_kind() {
    bool ran = false;
    var plan = Plan.wrapped((c) => { ran = true; });
    assert(plan.kind == PlanKind.LEGACY_WRAPPED);
    var r = runner_for(plan);
    try {
        r.start();
    } catch (PlanError e) {
        error("%s", e.message);
    }
    spin(r);
    assert(ran);
    assert(r.has_reached(Milestone.INTERACTIVE));
    assert(PlanKind.LEGACY_WRAPPED.to_id() == "legacy-wrapped");
    assert(new Plan().kind == PlanKind.STRUCTURED);
}

static void test_main_slice_budget() {
    var plan = new Plan();
    plan.main("heavy", Category.SHELL, (c) => { Thread.usleep(40000); }).budget(10).reaches(Milestone.SHELL_READY).reaches(Milestone.CONTENT_READY).reaches(Milestone.INTERACTIVE);
    var r = runner_for(plan);
    try {
        r.start();
    } catch (PlanError e) {
        error("%s", e.message);
    }
    spin(r);
    assert(plan.get_task("heavy").overrun_us >= 25000);
    assert(r.longest_slice_us() >= 35000);
}

static void test_cached_task() {
    var got = new Gee.ArrayList<string>();
    for (int round = 0; round < 2; round++) {
        var plan = new Plan();
        plan.cached("index", Category.CONTENT, "library-v1", (c) => {
            return "hello".data;
        }, (c, bytes) => {
            var text = new StringBuilder();
            text.append_len((string) bytes, bytes.length);
            got.add(text.str);
        }).reaches(Milestone.SHELL_READY).reaches(Milestone.CONTENT_READY).reaches(Milestone.INTERACTIVE);
        var r = runner_for(plan);
        try {
            r.start();
        } catch (PlanError e) {
            error("%s", e.message);
        }
        spin(r);
        assert(plan.get_task("index").state == TaskState.DONE);
    }
    assert(got.size == 2);
    assert(got[0] == "hello" && got[1] == "hello");
}

static void test_cached_failure() {
    var plan = new Plan();
    plan.cached("index", Category.CONTENT, "broken", (c) => {
        throw new IOError.FAILED("unreadable");
    }, (c, bytes) => {}).recoverable("index").reaches(Milestone.SHELL_READY).reaches(Milestone.CONTENT_READY).reaches(Milestone.INTERACTIVE);
    var r = runner_for(plan);
    try {
        r.start();
    } catch (PlanError e) {
        error("%s", e.message);
    }
    spin(r);
    assert(plan.get_task("index").state == TaskState.FAILED);
    assert(plan.get_task("index").error.message == "unreadable");
}

public static int main(string[] args) {
    Test.init(ref args);
    app = new GLib.Application("dev.sinty.StartupTest", ApplicationFlags.NON_UNIQUE);
    Test.add_func("/startup/validation", test_validation);
    Test.add_func("/startup/order-and-milestones", test_order_and_milestones);
    Test.add_func("/startup/window-independent-of-catalog", test_window_independent_of_catalog);
    Test.add_func("/startup/recoverable-failure", test_recoverable_failure);
    Test.add_func("/startup/essential-failure", test_essential_failure);
    Test.add_func("/startup/hold-and-steps", test_hold_and_steps);
    Test.add_func("/startup/hold-failure", test_hold_failure);
    Test.add_func("/startup/cancel", test_cancel);
    Test.add_func("/startup/lingering-worker", test_lingering_worker);
    Test.add_func("/startup/concurrency-limit", test_concurrency_limit);
    Test.add_func("/startup/critical-first", test_critical_first);
    Test.add_func("/startup/wrapped-kind", test_wrapped_kind);
    Test.add_func("/startup/main-slice-budget", test_main_slice_budget);
    Test.add_func("/startup/cached-task", test_cached_task);
    Test.add_func("/startup/cached-failure", test_cached_failure);
    return Test.run();
}
