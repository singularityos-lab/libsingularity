using Singularity;

private class FakeBackend : GLib.Object, DynamicInternetBackend {
    public string name { owned get { return "Fake"; } }
    public string preferred { get; private set; default = ""; }

    public async Gee.List<InternetUplink> probe(Cancellable? cancellable) throws Error {
        var result = new Gee.ArrayList<InternetUplink>();
        result.add(uplink("portable", 12));
        return result;
    }

    public async void prefer(string uplink_id, Cancellable? cancellable) throws Error {
        preferred = uplink_id;
    }

    public async void reset(Cancellable? cancellable) throws Error {
        preferred = "";
    }
}

private InternetUplink uplink(string id, int latency, int loss = 0,
                              bool reachable = true, bool metered = false) {
    var result = new InternetUplink(id, id, id, InternetUplinkKind.OTHER);
    result.latency_ms = latency;
    result.loss_percent = loss;
    result.reachable = reachable;
    result.metered = metered;
    result.score = DynamicInternetPolicy.score(result);
    return result;
}

private void test_score() {
    var fast = uplink("fast", 20);
    var slow = uplink("slow", 120);
    var lossy = uplink("lossy", 20, 30);
    var metered = uplink("metered", 20, 0, true, true);
    var captive = uplink("captive", 5);
    captive.captive = true;

    assert(fast.score > slow.score);
    assert(fast.score > lossy.score);
    assert(fast.score > metered.score);
    assert(DynamicInternetPolicy.score(captive) < 0);
}

private void test_hard_failover() {
    var current = uplink("wifi", -1, 100, false);
    current.failures = DynamicInternetPolicy.HARD_FAILURES;
    var ethernet = uplink("ethernet", 15);
    ethernet.successes = 1;

    assert(DynamicInternetPolicy.should_switch(current, ethernet, 0, 1));
}

private void test_hysteresis() {
    var current = uplink("wifi", 60);
    var candidate = uplink("ethernet", 10);
    candidate.successes = DynamicInternetPolicy.HEALTHY_SAMPLES;
    int64 now = 30 * TimeSpan.SECOND;

    assert(DynamicInternetPolicy.should_switch(current, candidate, 0, now));
    assert(!DynamicInternetPolicy.should_switch(current, candidate,
        now - 5 * TimeSpan.SECOND, now));

    candidate.successes = 1;
    assert(!DynamicInternetPolicy.should_switch(current, candidate, 0, now));
}

private void test_backend_contract() {
    var backend = new FakeBackend();
    var manager = new DynamicInternetManager();
    var loop = new MainLoop();
    uint timeout = Timeout.add_seconds(1, () => {
        loop.quit();
        return Source.REMOVE;
    });
    manager.changed.connect(() => {
        if (manager.preferred_id == "portable") loop.quit();
    });

    manager.set_backend(backend);
    manager.set_active(true);
    loop.run();
    if (timeout != 0) Source.remove(timeout);

    assert(manager.backend_name == "Fake");
    assert(manager.preferred_id == "portable");
    assert(backend.preferred == "portable");
    manager.set_active(false);
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/dynamic-internet/score", test_score);
    Test.add_func("/dynamic-internet/hard-failover", test_hard_failover);
    Test.add_func("/dynamic-internet/hysteresis", test_hysteresis);
    Test.add_func("/dynamic-internet/backend-contract", test_backend_contract);
    return Test.run();
}
