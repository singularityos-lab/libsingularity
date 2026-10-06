using Gtk;
using Singularity;
using Singularity.Animation;

bool gtk_ready = false;
string output_dir;

Subprocess? start_private_display(string runtime_dir) {
    string? daemon = Environment.find_program_in_path("gtk4-broadwayd");
    if (daemon == null) return null;
    int number = 40 + (int) (Posix.getpid() % 400);
    try {
        var launcher = new SubprocessLauncher(SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
        launcher.setenv("XDG_RUNTIME_DIR", runtime_dir, true);
        string[] argv = { daemon, ":%d".printf(number), "-u", Path.build_filename(runtime_dir, "http.sock") };
        string? timeout = Environment.find_program_in_path("timeout");
        if (timeout != null) argv = { timeout, "120", daemon, ":%d".printf(number), "-u", Path.build_filename(runtime_dir, "http.sock") };
        var process = launcher.spawnv(argv);
        string socket = Path.build_filename(runtime_dir, "broadway%d.socket".printf(number + 1));
        for (int i = 0; i < 100 && !FileUtils.test(socket, FileTest.EXISTS); i++) Thread.usleep(20000);
        if (!FileUtils.test(socket, FileTest.EXISTS)) {
            process.send_signal(Posix.Signal.TERM);
            return null;
        }
        Environment.set_variable("XDG_RUNTIME_DIR", runtime_dir, true);
        Environment.set_variable("DBUS_SESSION_BUS_ADDRESS", "unix:path=" + Path.build_filename(runtime_dir, "no-bus"), true);
        Environment.set_variable("GDK_BACKEND", "broadway", true);
        Environment.set_variable("GSK_RENDERER", "cairo", true);
        Environment.set_variable("BROADWAY_DISPLAY", ":%d".printf(number), true);
        return process;
    } catch (Error e) {
        return null;
    }
}

bool wait_for(Widget widget) {
    int64 deadline = get_monotonic_time() + 5 * TimeSpan.SECOND;
    while (!(widget.get_mapped() && widget.get_width() > 0) && get_monotonic_time() < deadline) {
        MainContext.default().iteration(false);
        Thread.usleep(1000);
    }
    return widget.get_mapped() && widget.get_width() > 0;
}

double coverage(Gdk.Texture texture) {
    int width = texture.get_width();
    int height = texture.get_height();
    var pixels = new uint8[width * height * 4];
    texture.download(pixels, width * 4);
    double total = 0.0;
    for (int i = 3; i < pixels.length; i += 4) total += pixels[i];
    return total / (width * height * 255.0);
}

void test_capture_follows_manual_clock() {
    if (!gtk_ready) {
        Test.skip("no display");
        return;
    }
    var motion = Motion.get_default();
    motion.reduce_motion = false;
    motion.duration_scale = 1.0;
    var window = new Gtk.Window();
    window.set_default_size(240, 120);
    var outer = new Box(Orientation.VERTICAL, 0);
    var bin = new MotionBin();
    var block = new DrawingArea();
    block.set_size_request(120, 60);
    block.set_draw_func((area, cr, width, height) => {
        cr.set_source_rgb(0.2, 0.4, 0.8);
        cr.paint();
    });
    bin.child = block;
    bin.halign = Align.CENTER;
    bin.valign = Align.CENTER;
    bin.vexpand = true;
    outer.append(bin);
    window.child = outer;
    window.present();
    assert(wait_for(outer));

    motion.use_manual_clock(0);
    Motion.reveal(bin, Motion.Preset.FADE);
    uint[] times = { 0, 40, 80, 160, 400 };
    double[] seen = {};
    uint now = 0;
    foreach (var time in times) {
        motion.advance(time - now, 60);
        now = time;
        var texture = Motion.capture_texture(outer);
        assert(texture != null);
        assert(texture.get_width() == outer.get_width());
        seen += coverage(texture);
    }
    assert(seen[0] < 0.01);
    for (int i = 1; i < seen.length; i++) assert(seen[i] >= seen[i - 1]);
    assert(seen[1] > seen[0] && seen[2] > seen[1]);
    assert(seen[seen.length - 1] > 0.2);

    string path = Path.build_filename(output_dir, "capture.png");
    assert(Motion.capture(outer, path));
    assert(FileUtils.test(path, FileTest.EXISTS));
    FileUtils.unlink(path);

    Motion.reveal(bin, Motion.Preset.FADE);
    motion.advance(40);
    double before = coverage(Motion.capture_texture(outer));
    double again = coverage(Motion.capture_texture(outer));
    assert(before == again);
    motion.advance(400);
    assert(coverage(Motion.capture_texture(outer)) > before);

    var root = Motion.capture_texture(window);
    assert(root != null);

    motion.skip_all();
    motion.use_frame_clock();
    window.destroy();
}

void test_capture_rejects_unmapped() {
    if (!gtk_ready) {
        Test.skip("no display");
        return;
    }
    var label = new Label("Hidden");
    assert(Motion.capture_texture(label) == null);
    assert(!Motion.capture(label, Path.build_filename(output_dir, "hidden.png")));
}

int main(string[] args) {
    Test.init(ref args);
    Log.set_always_fatal(LogLevelFlags.LEVEL_ERROR | LogLevelFlags.LEVEL_CRITICAL);
    Subprocess? display = null;
    string? runtime_dir = null;
    Environment.unset_variable("WAYLAND_DISPLAY");
    Environment.unset_variable("DISPLAY");
    try {
        runtime_dir = DirUtils.make_tmp("motion-capture-XXXXXX");
        string? user_runtime = Environment.get_variable("XDG_RUNTIME_DIR");
        if (runtime_dir.length > 80 && user_runtime != null) {
            DirUtils.remove(runtime_dir);
            runtime_dir = DirUtils.mkdtemp(Path.build_filename(user_runtime, "motion-capture-XXXXXX"));
        }
        display = start_private_display(runtime_dir);
    } catch (Error e) {
    }
    output_dir = runtime_dir ?? Environment.get_tmp_dir();
    gtk_ready = display != null && Gtk.init_check();
    Test.add_func("/motion-capture/follows-manual-clock", test_capture_follows_manual_clock);
    Test.add_func("/motion-capture/rejects-unmapped", test_capture_rejects_unmapped);
    int result = Test.run();
    if (display != null) {
        display.send_signal(Posix.Signal.TERM);
        try {
            display.wait();
        } catch (Error e) {
        }
    }
    if (runtime_dir != null) {
        Dir? dir = null;
        try {
            dir = Dir.open(runtime_dir);
        } catch (Error e) {
        }
        string? name = null;
        while (dir != null && (name = dir.read_name()) != null) FileUtils.unlink(Path.build_filename(runtime_dir, name));
        DirUtils.remove(runtime_dir);
    }
    return result;
}
