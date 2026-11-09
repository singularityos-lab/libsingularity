[CCode (cname = "syscall", cheader_filename = "unistd.h,sys/syscall.h")]
extern long raw_syscall(long number, int which, int who);
[CCode (cname = "SYS_ioprio_get", cheader_filename = "sys/syscall.h")]
extern const long SYS_IOPRIO_GET;
[CCode (cname = "SYS_gettid", cheader_filename = "sys/syscall.h")]
extern const long SYS_GETTID;
[CCode (cname = "getpriority", cheader_filename = "sys/resource.h")]
extern int get_priority(int which, int who);
[CCode (cname = "syscall", cheader_filename = "unistd.h,sys/syscall.h")]
extern long gettid_syscall(long number);

void check(bool cond, string what) {
    if (!cond) {
        stderr.printf("FAIL: %s\n", what);
        Process.exit(1);
    }
    print("ok: %s\n", what);
}

int io_class(int tid) {
    return (int) (raw_syscall(SYS_IOPRIO_GET, 1, tid) >> 13);
}

bool can_restore() {
    string text;
    try {
        FileUtils.get_contents("/proc/self/limits", out text);
    } catch (FileError e) {
        return false;
    }
    foreach (string line in text.split("\n")) {
        if (!line.has_prefix("Max nice priority")) continue;
        string[] parts = line.substring(17).strip().split_set(" ", 0);
        string[] fields = {};
        foreach (string p in parts) if (p != "") fields += p;
        return fields.length >= 2 && (fields[1] == "unlimited" || int.parse(fields[1]) >= 20);
    }
    return false;
}

int main(string[] args) {
    bool restore = can_restore();
    print("restore to nice 0 allowed: %s\n", restore.to_string());

    int tid = 0;
    int low_nice = 0, low_io = 0, back_nice = 0, back_io = 0;
    var t = new Thread<bool>("work", () => {
        tid = (int) gettid_syscall(SYS_GETTID);
        var work = Singularity.BackgroundWork.enter();
        low_nice = get_priority(0, tid);
        low_io = io_class(tid);
        work.finish();
        back_nice = get_priority(0, tid);
        back_io = io_class(tid);
        return true;
    });
    t.join();
    check(low_nice == 19, "thread runs at nice 19");
    check(low_io == 3, "thread runs at idle disk priority");
    check(back_io == 0, "disk priority comes back");
    if (restore) check(back_nice == 0, "processor priority comes back");
    check(get_priority(0, (int) gettid_syscall(SYS_GETTID)) == 0, "main thread untouched");

    Pid pid;
    try {
        Process.spawn_async(null, { "sleep", "5" }, null, SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD, null, out pid);
    } catch (SpawnError e) {
        check(false, e.message);
        return 1;
    }
    var proc = Singularity.BackgroundWork.for_process(pid);
    check(get_priority(0, (int) pid) == 19 && io_class((int) pid) == 3, "child process lowered");
    proc.finish();
    check(io_class((int) pid) == 0, "child disk priority comes back");
    if (restore) check(get_priority(0, (int) pid) == 0, "child processor priority comes back");
    Posix.kill(pid, Posix.Signal.TERM);

    int async_io = -1;
    int async_nice = -100;
    var main_loop = new MainLoop();
    Singularity.Async.run.begin<bool>((c) => {
        int me = (int) gettid_syscall(SYS_GETTID);
        async_io = io_class(me);
        async_nice = get_priority(0, me);
        return true;
    }, Singularity.Async.Qos.BACKGROUND, null, (o, r) => {
        try {
            Singularity.Async.run.end<bool>(r);
        } catch (Error e) {
        }
        main_loop.quit();
    });
    main_loop.run();
    print("async engine native: %s\n", Singularity.Async.accelerated().to_string());
    check(async_io == 3, "background async work runs at idle disk priority");
    if (!Singularity.Async.accelerated()) check(async_nice == 19, "background async work runs at nice 19");

    if (Gtk.init_check()) {
        var window = new Gtk.Window();
        window.title = "bwtest";
        var bar = new Gtk.ProgressBar();
        var stack = new Gtk.Stack();
        stack.add_named(bar, "bar");
        stack.add_named(new Gtk.Label("other"), "other");
        window.child = stack;
        var loop = MainContext.default();
        int wtid = 0;
        Singularity.BackgroundWork? work = null;
        var gate = new Mutex();
        var started = new Cond();
        var stop = false;
        var worker = new Thread<bool>("follow", () => {
            gate.lock();
            wtid = (int) gettid_syscall(SYS_GETTID);
            work = Singularity.BackgroundWork.enter();
            started.signal();
            while (!stop) started.wait(gate);
            gate.unlock();
            return true;
        });
        gate.lock();
        while (work == null) started.wait(gate);
        gate.unlock();
        work.follow(bar);
        window.present();
        for (int i = 0; i < 1000 && !(window.is_active && bar.get_mapped()); i++) {
            loop.iteration(false);
            Thread.usleep(10000);
        }
        print("window active: %s\n", window.is_active.to_string());
        if (window.is_active) {
            check(work.foreground && io_class(wtid) == 0, "followed bar in the active window raises the work");
            if (restore) check(get_priority(0, wtid) == 0, "followed work at normal processor priority");
            stack.visible_child_name = "other";
            for (int i = 0; i < 20; i++) loop.iteration(false);
            check(!work.foreground && io_class(wtid) == 3 && get_priority(0, wtid) == 19, "switching away lowers it again");
            stack.visible_child_name = "bar";
            for (int i = 0; i < 20; i++) loop.iteration(false);
            check(work.foreground && io_class(wtid) == 0, "coming back raises it");
        }
        work.finish();
        gate.lock();
        stop = true;
        started.signal();
        gate.unlock();
        worker.join();
    }
    print("background-work: ok\n");
    return 0;
}
