using Singularity;

static MainLoop loop;

static void wait_for(ref bool flag) {
    var context = MainContext.default();
    while (!flag) context.iteration(true);
}

static void test_engine() {
    var expected = Environment.get_variable("EXPECT_ENGINE");
    if (expected == null) {
        Test.skip("EXPECT_ENGINE not set");
        return;
    }
    assert(Async.accelerated() == (expected == "native"));
}

static void test_run_value() {
    bool done = false;
    int value = 0;
    Thread<void*>? worker = null;
    unowned Thread<void*> main_thread = Thread.self<void*>();
    Async.run.begin<int>((c) => {
        worker = Thread.self<void*>();
        return 6 * 7;
    }, Async.Qos.USER, null, (o, r) => {
        try {
            value = Async.run.end<int>(r);
        } catch (Error e) {
            assert_not_reached();
        }
        done = true;
    });
    wait_for(ref done);
    assert(value == 42);
    assert(worker != main_thread);
}

static void test_run_object() {
    bool done = false;
    Gdk.Texture? texture = null;
    Async.run.begin<Gdk.Texture>((c) => {
        var bytes = new Bytes(new uint8[16 * 16 * 4]);
        return new Gdk.MemoryTexture(16, 16, Gdk.MemoryFormat.R8G8B8A8, bytes, 16 * 4);
    }, Async.Qos.INTERACTIVE, null, (o, r) => {
        try {
            texture = Async.run.end<Gdk.Texture>(r);
        } catch (Error e) {
            assert_not_reached();
        }
        done = true;
    });
    wait_for(ref done);
    assert(texture != null);
    assert(texture.get_width() == 16);
    assert(texture.ref_count == 1);
}

static void test_run_error() {
    bool done = false;
    Error? failure = null;
    Async.run.begin<string>((c) => {
        throw new IOError.NOT_FOUND("missing");
    }, Async.Qos.UTILITY, null, (o, r) => {
        try {
            Async.run.end<string>(r);
        } catch (Error e) {
            failure = e;
        }
        done = true;
    });
    wait_for(ref done);
    assert(failure is IOError.NOT_FOUND);
}

static void test_widget_scope() {
    Gtk.Window? window = new Gtk.Window();
    Gtk.Label? label = new Gtk.Label("x");
    window.child = label;
    Cancellable scope = Async.scope_of(label);
    assert(scope == Async.scope_of(label));
    assert(!scope.is_cancelled());
    label = null;
    bool done = false;
    bool ran = false;
    Error? failure = null;
    window.destroy();
    window = null;
    assert(scope.is_cancelled());
    Async.run.begin<bool>((c) => {
        ran = true;
        return true;
    }, Async.Qos.USER, scope, (o, r) => {
        try {
            Async.run.end<bool>(r);
        } catch (Error e) {
            failure = e;
        }
        done = true;
    });
    wait_for(ref done);
    assert(failure is IOError.CANCELLED);
}

const int ITEMS = 5000;

static void test_feed() {
    var feed = Async.Feed.spawn((f, c) => {
        for (int i = 0; i < ITEMS; i++) {
            var item = new Object();
            item.set_data<int>("n", i + 1);
            f.push(item);
        }
    });
    int count = 0;
    int batches = 0;
    bool ordered = true;
    bool done = false;
    read_feed.begin(feed, (o, r) => {
        try {
            read_feed.end(r, out count, out batches, out ordered);
        } catch (Error e) {
            assert_not_reached();
        }
        done = true;
    });
    wait_for(ref done);
    assert(count == ITEMS);
    assert(ordered);
    assert(batches < ITEMS / 10);
}

static async void read_feed(Async.Feed feed, out int count, out int batches, out bool ordered) throws Error {
    count = 0;
    batches = 0;
    ordered = true;
    GenericArray<Object>? batch;
    while ((batch = yield feed.next()) != null) {
        batches++;
        foreach (var item in batch.data) {
            if (item.get_data<int>("n") != count + 1) ordered = false;
            count++;
        }
    }
}

static void test_feed_error() {
    var feed = Async.Feed.spawn((f, c) => {
        f.push(new Object());
        throw new IOError.FAILED("producer failed");
    });
    bool done = false;
    int count = 0;
    Error? failure = null;
    read_feed.begin(feed, (o, r) => {
        int batches;
        bool ordered;
        try {
            read_feed.end(r, out count, out batches, out ordered);
        } catch (Error e) {
            failure = e;
        }
        done = true;
    });
    wait_for(ref done);
    assert(failure is IOError.FAILED);
}

static void test_feed_cancel() {
    var cancellable = new Cancellable();
    var feed = new Async.Feed();
    bool done = false;
    Error? failure = null;
    feed.next.begin(cancellable, (o, r) => {
        try {
            feed.next.end(r);
        } catch (Error e) {
            failure = e;
        }
        done = true;
    });
    cancellable.cancel();
    wait_for(ref done);
    assert(failure is IOError.CANCELLED);
    feed.close();
}

static void test_many() {
    const int total = 20000;
    int delivered = 0;
    var start = get_monotonic_time();
    for (int i = 0; i < total; i++) {
        Async.run.begin<int>((c) => {
            return 1;
        }, Async.Qos.USER, null, (o, r) => {
            try {
                delivered += Async.run.end<int>(r);
            } catch (Error e) {
                assert_not_reached();
            }
        });
    }
    var context = MainContext.default();
    while (delivered < total) context.iteration(true);
    var seconds = (get_monotonic_time() - start) / 1000000.0;
    Test.message("%d runs in %.3f s (%s)", total, seconds, Async.accelerated() ? "native" : "fallback");
}

int main(string[] args) {
    Gtk.test_init(ref args);
    loop = new MainLoop();
    Test.add_func("/async/engine", test_engine);
    Test.add_func("/async/run-value", test_run_value);
    Test.add_func("/async/run-object", test_run_object);
    Test.add_func("/async/run-error", test_run_error);
    Test.add_func("/async/widget-scope", test_widget_scope);
    Test.add_func("/async/feed", test_feed);
    Test.add_func("/async/feed-error", test_feed_error);
    Test.add_func("/async/feed-cancel", test_feed_cancel);
    Test.add_func("/async/many", test_many);
    return Test.run();
}
