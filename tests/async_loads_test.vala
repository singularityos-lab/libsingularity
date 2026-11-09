using Singularity;

static string dir;

static void wait_for(ref bool flag) {
    var context = MainContext.default();
    while (!flag) context.iteration(true);
}

static void spin(int ms) {
    var context = MainContext.default();
    int64 end = get_monotonic_time() + ms * 1000;
    while (get_monotonic_time() < end) context.iteration(false);
}

static string write_png(string name, int width, int height) {
    var pixbuf = new Gdk.Pixbuf(Gdk.Colorspace.RGB, true, 8, width, height);
    pixbuf.fill(0x3366ccff);
    string path = Path.build_filename(dir, name);
    try {
        pixbuf.savev(path, "png", {}, {});
    } catch (Error e) {
        error("%s", e.message);
    }
    return path;
}

static void test_load_bytes() {
    string path = Path.build_filename(dir, "data.bin");
    var data = new uint8[3 * 1024 * 1024 + 17];
    for (int i = 0; i < data.length; i++) data[i] = (uint8) (i * 31 + 7);
    try {
        FileUtils.set_data(path, data);
    } catch (Error e) {
        error("%s", e.message);
    }
    bool done = false;
    Bytes? bytes = null;
    Async.load_bytes.begin(File.new_for_path(path), Async.Qos.USER, null, (o, r) => {
        try {
            bytes = Async.load_bytes.end(r);
        } catch (Error e) {
            error("%s", e.message);
        }
        done = true;
    });
    wait_for(ref done);
    assert(bytes.get_size() == data.length);
    assert(Memory.cmp(bytes.get_data(), data, data.length) == 0);
}

static void test_load_bytes_missing() {
    bool done = false;
    Error? failure = null;
    Async.load_bytes.begin(File.new_for_path(Path.build_filename(dir, "missing")), Async.Qos.BACKGROUND, null, (o, r) => {
        try {
            Async.load_bytes.end(r);
        } catch (Error e) {
            failure = e;
        }
        done = true;
    });
    wait_for(ref done);
    assert(failure is IOError.NOT_FOUND);
}

static void test_load_texture() {
    var file = File.new_for_path(write_png("full.png", 300, 200));
    bool done = false;
    Gdk.Texture? texture = null;
    Async.load_texture.begin(file, Async.Qos.INTERACTIVE, null, (o, r) => {
        try {
            texture = Async.load_texture.end(r);
        } catch (Error e) {
            error("%s", e.message);
        }
        done = true;
    });
    wait_for(ref done);
    assert(texture.get_width() == 300 && texture.get_height() == 200);
}

static void test_load_image_scaled() {
    var file = File.new_for_path(write_png("big.png", 1000, 500));
    var small = File.new_for_path(write_png("small.png", 40, 30));
    bool done = false;
    Gdk.Texture? scaled = null;
    Gdk.Texture? kept = null;
    Async.load_image.begin(file, 200, Async.Qos.USER, null, (o, r) => {
        try {
            scaled = Async.load_image.end(r);
        } catch (Error e) {
            error("%s", e.message);
        }
        Async.load_image.begin(small, 200, Async.Qos.USER, null, (o2, r2) => {
            try {
                kept = Async.load_image.end(r2);
            } catch (Error e) {
                error("%s", e.message);
            }
            done = true;
        });
    });
    wait_for(ref done);
    assert(scaled.get_width() == 200 && scaled.get_height() == 100);
    assert(kept.get_width() == 40 && kept.get_height() == 30);
}

static void test_thumbnails() {
    var thumbs = new Async.Thumbnails("async-loads-test");
    var file = File.new_for_path(write_png("photo.png", 800, 600));
    int finished = 0;
    Gdk.Texture? first = null;
    Gdk.Texture? second = null;
    unowned Thread<void*> main_thread = Thread.self<void*>();
    thumbs.load.begin(file, 128, Async.Qos.UTILITY, null, (o, r) => {
        try {
            first = thumbs.load.end(r);
        } catch (Error e) {
            error("%s", e.message);
        }
        assert(Thread.self<void*>() == main_thread);
        finished++;
    });
    thumbs.load.begin(file, 100, Async.Qos.UTILITY, null, (o, r) => {
        try {
            second = thumbs.load.end(r);
        } catch (Error e) {
            error("%s", e.message);
        }
        finished++;
    });
    assert(thumbs.in_flight == 1);
    while (finished < 2) MainContext.default().iteration(true);
    assert(first != null && first == second);
    assert(first.get_width() == 128 && first.get_height() == 96);
    assert(thumbs.peek(file, 128) == first);

    int64 deadline = get_monotonic_time() + 5 * 1000000;
    while (thumbs.saved == 0 && get_monotonic_time() < deadline) MainContext.default().iteration(false);
    assert(thumbs.saved == 1);
    string uri = file.get_uri();
    assert(FileUtils.test(FileSystem.ThumbnailCache.path_for(uri, FileSystem.ThumbnailCache.Size.NORMAL), FileTest.IS_REGULAR));
    assert(FileUtils.test(FileSystem.ThumbnailCache.path_for(uri, FileSystem.ThumbnailCache.Size.LARGE), FileTest.IS_REGULAR));

    var again = new Async.Thumbnails("async-loads-test");
    bool done = false;
    Gdk.Texture? cached = null;
    again.load.begin(file, 128, Async.Qos.UTILITY, null, (o, r) => {
        try {
            cached = again.load.end(r);
        } catch (Error e) {
            error("%s", e.message);
        }
        done = true;
    });
    wait_for(ref done);
    assert(cached != null && cached.get_width() == 128);
    spin(200);
    assert(again.saved == 0);
}

static void test_thumbnails_not_image() {
    var thumbs = new Async.Thumbnails("async-loads-test");
    string path = Path.build_filename(dir, "notes.txt");
    try {
        FileUtils.set_contents(path, "plain text");
    } catch (Error e) {
        error("%s", e.message);
    }
    bool done = false;
    Gdk.Texture? texture = null;
    thumbs.load.begin(File.new_for_path(path), 128, Async.Qos.UTILITY, null, (o, r) => {
        try {
            texture = thumbs.load.end(r);
        } catch (Error e) {
            error("%s", e.message);
        }
        done = true;
    });
    wait_for(ref done);
    assert(texture == null);
}

static void test_thumbnails_cancel() {
    var thumbs = new Async.Thumbnails("async-loads-test");
    var file = File.new_for_path(write_png("cancel.png", 2000, 2000));
    var cancellable = new Cancellable();
    bool done = false;
    Error? failure = null;
    thumbs.load.begin(file, 256, Async.Qos.UTILITY, cancellable, (o, r) => {
        try {
            thumbs.load.end(r);
        } catch (Error e) {
            failure = e;
        }
        done = true;
    });
    cancellable.cancel();
    wait_for(ref done);
    assert(failure is IOError.CANCELLED);
    int64 deadline = get_monotonic_time() + 5 * 1000000;
    while (thumbs.in_flight > 0 && get_monotonic_time() < deadline) MainContext.default().iteration(true);
    assert(thumbs.in_flight == 0);
    assert(thumbs.peek(file, 256) == null);
}

static void test_tile_cache() {
    int calls = 0;
    int main_calls = 0;
    int color = 0;
    unowned Thread<void*> main_thread = Thread.self<void*>();
    var cache = new Async.TileCache((cr, x, y, w, h) => {
        AtomicInt.inc(ref calls);
        if (Thread.self<void*>() == main_thread) AtomicInt.inc(ref main_calls);
        cr.set_source_rgb(AtomicInt.get(ref color), 0, 0);
        cr.paint();
    }, 64);
    var area = new Gtk.DrawingArea();
    var window = new Gtk.Window();
    window.set_child(area);
    var viewport = Graphene.Rect().init(0, 0, 200, 130);

    var snap = new Gtk.Snapshot();
    cache.snapshot(snap, area, viewport, 0, 0);
    snap.to_node();
    assert(cache.missing_last_frame == 12);
    assert(cache.in_flight == 12);

    int64 deadline = get_monotonic_time() + 5 * 1000000;
    while (cache.in_flight > 0 && get_monotonic_time() < deadline) MainContext.default().iteration(true);
    assert(cache.in_flight == 0);
    assert(AtomicInt.get(ref calls) == 12);
    assert(AtomicInt.get(ref main_calls) == 0);

    snap = new Gtk.Snapshot();
    cache.snapshot(snap, area, viewport, 0, 0);
    snap.to_node();
    assert(cache.ready_last_frame == 12);
    assert(cache.in_flight == 0);

    AtomicInt.set(ref color, 1);
    cache.invalidate_area(0, 0, 10, 10);
    snap = new Gtk.Snapshot();
    cache.snapshot(snap, area, viewport, 0, 0);
    snap.to_node();
    assert(cache.stale_last_frame == 1);
    assert(cache.ready_last_frame == 11);
    assert(cache.in_flight == 1);

    cache.invalidate();
    snap = new Gtk.Snapshot();
    cache.snapshot(snap, area, viewport, 0, 0);
    snap.to_node();
    assert(cache.stale_last_frame == 12);
    assert(cache.missing_last_frame == 0);

    deadline = get_monotonic_time() + 5 * 1000000;
    while (cache.in_flight > 0 && get_monotonic_time() < deadline) MainContext.default().iteration(true);
    snap = new Gtk.Snapshot();
    cache.snapshot(snap, area, viewport, 0, 0);
    snap.to_node();
    assert(cache.ready_last_frame == 12);
    assert(AtomicInt.get(ref main_calls) == 0);
    window.destroy();
}

int main(string[] args) {
    Test.init(ref args);
    try {
        dir = DirUtils.make_tmp("async-loads-XXXXXX");
    } catch (Error e) {
        error("%s", e.message);
    }
    Environment.set_variable("XDG_CACHE_HOME", Path.build_filename(dir, "cache"), true);
    Gtk.init();
    Test.add_func("/async/load-bytes", test_load_bytes);
    Test.add_func("/async/load-bytes-missing", test_load_bytes_missing);
    Test.add_func("/async/load-texture", test_load_texture);
    Test.add_func("/async/load-image-scaled", test_load_image_scaled);
    Test.add_func("/async/thumbnails", test_thumbnails);
    Test.add_func("/async/thumbnails-not-image", test_thumbnails_not_image);
    Test.add_func("/async/thumbnails-cancel", test_thumbnails_cancel);
    Test.add_func("/async/tile-cache", test_tile_cache);
    return Test.run();
}
