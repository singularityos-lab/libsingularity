using Singularity.Accounts;

[CCode (cname = "flock", cheader_filename = "sys/file.h")]
extern int test_flock(int fd, int operation);
[CCode (cname = "open", cheader_filename = "fcntl.h")]
extern int test_open(string path, int flags, int mode);

const int LOCK_EX = 2;
const int LOCK_UN = 8;
const int OPEN_FLAGS = 66;

void check(bool ok, string label) {
    if (!ok) {
        stderr.printf("FAILED: %s\n", label);
        assert_not_reached();
    }
}

string todo_text(string uid, string summary) {
    return "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:%s\r\nSUMMARY:%s\r\nEND:VTODO\r\nEND:VCALENDAR\r\n".printf(uid, summary);
}

async void nap(uint ms) {
    Timeout.add(ms, nap.callback);
    yield;
}

class DirRemote : Object, RemoteCollection {
    private string root;
    private int lock_fd;

    private string _id;

    public string id { get { return _id; } }
    public string name { get { return "Shared"; } }
    public string color { get { return ""; } }
    public bool read_only { get { return false; } }

    public DirRemote(string root) {
        this.root = root;
        _id = "dir:" + root;
        lock_fd = test_open(Path.build_filename(root, ".lock"), OPEN_FLAGS, 0600);
    }

    public Json.Object to_descriptor() {
        var o = new Json.Object();
        o.set_string_member("type", "dir");
        o.set_string_member("root", root);
        return o;
    }

    private static string etag_of(string data) {
        return Checksum.compute_for_string(ChecksumType.SHA1, data).substring(0, 12);
    }

    private string file_of(string href) {
        return Path.build_filename(root, Path.get_basename(href));
    }

    private string? read(string href) {
        try {
            string data;
            FileUtils.get_contents(file_of(href), out data);
            return data;
        } catch (Error e) {
            return null;
        }
    }

    private void write(string href, string data) throws Error {
        FileUtils.set_contents(file_of(href), data);
    }

    private Gee.TreeMap<string, string> listing() {
        var map = new Gee.TreeMap<string, string>();
        try {
            var dir = Dir.open(root);
            string? n;
            while ((n = dir.read_name()) != null) {
                if (!n.has_suffix(".ics")) continue;
                string href = "/dir/" + n;
                string? data = read(href);
                if (data != null) map[href] = etag_of(data);
            }
        } catch (Error e) {
        }
        return map;
    }

    private async void jitter() {
        yield nap(Random.int_range(2, 25));
    }

    public async string get_tag(Cancellable? cancellable = null) throws Error {
        yield jitter();
        var sb = new StringBuilder();
        foreach (var e in listing().entries) sb.append("%s=%s;".printf(e.key, e.value));
        return etag_of(sb.str);
    }

    public async Gee.Map<string, string> list_index(Cancellable? cancellable = null) throws Error {
        yield jitter();
        return listing();
    }

    public async Gee.List<RemoteItem> fetch(Gee.Collection<string> hrefs, Cancellable? cancellable = null) throws Error {
        yield jitter();
        var result = new Gee.ArrayList<RemoteItem>();
        foreach (string href in hrefs) {
            string? data = read(href);
            if (data != null) result.add(new RemoteItem(href, etag_of(data), data));
        }
        return result;
    }

    public async RemoteItem create(string uid, string data, Cancellable? cancellable = null) throws Error {
        yield jitter();
        string href = "/dir/" + uid + ".ics";
        test_flock(lock_fd, LOCK_EX);
        try {
            if (read(href) != null) throw new AccountsError.CONFLICT("exists");
            write(href, data);
        } finally {
            test_flock(lock_fd, LOCK_UN);
        }
        return new RemoteItem(href, etag_of(data));
    }

    public async RemoteItem update(string href, string etag, string data, Cancellable? cancellable = null) throws Error {
        yield jitter();
        test_flock(lock_fd, LOCK_EX);
        try {
            string? current = read(href);
            if (current == null) throw new AccountsError.NOT_FOUND("gone");
            if (etag_of(current) != etag) throw new AccountsError.CONFLICT("changed");
            write(href, data);
        } finally {
            test_flock(lock_fd, LOCK_UN);
        }
        return new RemoteItem(href, etag_of(data));
    }

    public async void remove(string href, string etag, Cancellable? cancellable = null) throws Error {
        yield jitter();
        test_flock(lock_fd, LOCK_EX);
        try {
            string? current = read(href);
            if (current == null) return;
            if (etag_of(current) != etag) throw new AccountsError.CONFLICT("changed");
            FileUtils.unlink(file_of(href));
        } finally {
            test_flock(lock_fd, LOCK_UN);
        }
    }
}

bool run_sync(SyncedCollection c) {
    var loop = new MainLoop();
    bool ok = false;
    c.sync.begin(null, (obj, res) => {
        ok = c.sync.end(res);
        loop.quit();
    });
    loop.run();
    return ok;
}

async void worker(string mirror, string server, string who, int count, string mode) {
    var c = new SyncedCollection("acc", new DirRemote(server), ContentKind.TASKS, mirror);
    if (mode == "write") {
        for (int i = 0; i < count; i++) {
            c.put("%s-%d".printf(who, i), todo_text("%s-%d".printf(who, i), "%s item %d".printf(who, i)));
            if (i % 5 == 4) c.remove("%s-%d".printf(who, i - 2));
            c.cancel_scheduled();
            yield nap(Random.int_range(0, 6));
        }
        return;
    }
    if (mode == "syncloop") {
        int64 until = get_monotonic_time() + count * 1000;
        while (get_monotonic_time() < until) {
            yield c.sync();
            c.cancel_scheduled();
            yield nap(Random.int_range(0, 10));
        }
        return;
    }
    for (int i = 0; i < count; i++) {
        c.put("%s-%d".printf(who, i), todo_text("%s-%d".printf(who, i), "%s item %d".printf(who, i)));
        if (i % 5 == 4) c.remove("%s-%d".printf(who, i - 2));
        if (i % 2 == 0) yield c.sync();
        yield nap(Random.int_range(0, 15));
    }
    c.cancel_scheduled();
    while (!(yield c.sync())) yield nap(50);
    c.cancel_scheduled();
}

int run_worker(string[] args) {
    var loop = new MainLoop();
    worker.begin(args[2], args[3], args[4], int.parse(args[5]), args[6], () => loop.quit());
    loop.run();
    return 0;
}

string self_path() {
    try {
        return FileUtils.read_link("/proc/self/exe");
    } catch (FileError e) {
        assert_not_reached();
    }
}

string[] scratch_dirs;

string scratch_dir(string name) {
    try {
        string dir = DirUtils.make_tmp(name + "-XXXXXX");
        scratch_dirs += dir;
        return dir;
    } catch (Error e) {
        assert_not_reached();
    }
}

void remove_tree(string path) {
    if (FileUtils.test(path, FileTest.IS_DIR) && !FileUtils.test(path, FileTest.IS_SYMLINK)) {
        try {
            var dir = Dir.open(path);
            string? name;
            while ((name = dir.read_name()) != null) remove_tree(Path.build_filename(path, name));
        } catch (FileError e) {
        }
        DirUtils.remove(path);
    } else {
        FileUtils.unlink(path);
    }
}

Subprocess spawn_worker(string mirror, string server, string who, int count, string mode = "sync") {
    try {
        return new Subprocess.newv({ self_path(), "--worker", mirror, server, who, count.to_string(), mode }, SubprocessFlags.NONE);
    } catch (Error e) {
        assert_not_reached();
    }
}

bool wait_ok(Subprocess p) {
    try {
        p.wait();
        return p.get_if_exited() && p.get_exit_status() == 0;
    } catch (Error e) {
        return false;
    }
}

bool expected_alive(int i, int count) {
    return !(i % 5 == 2 && i + 2 < count);
}

void test_two_syncers() {
    string mirror = scratch_dir("mirror");
    string server = scratch_dir("server");
    const int COUNT = 40;
    var a = spawn_worker(mirror, server, "a", COUNT);
    var b = spawn_worker(mirror, server, "b", COUNT);
    check(wait_ok(a), "first syncer finished");
    check(wait_ok(b), "second syncer finished");
    var remote = new DirRemote(server);
    var c = new SyncedCollection("acc", remote, ContentKind.TASKS, mirror);
    check(run_sync(c), "final sync");
    int expected = 0;
    string[] missing = {};
    foreach (string who in new string[] { "a", "b" }) {
        for (int i = 0; i < COUNT; i++) {
            string uid = "%s-%d".printf(who, i);
            bool alive = expected_alive(i, COUNT);
            if (alive) expected++;
            bool on_server = FileUtils.test(Path.build_filename(server, uid + ".ics"), FileTest.EXISTS);
            bool in_mirror = c.get_item(uid) != null;
            if (alive != on_server || alive != in_mirror) missing += "%s server=%s mirror=%s".printf(uid, on_server.to_string(), in_mirror.to_string());
        }
    }
    if (missing.length > 0) stderr.printf("lost or resurrected: %s\n", string.joinv(", ", missing));
    check(missing.length == 0, "every creation and deletion of both syncers survived");
    check(c.items().size == expected && c.pending_changes() == 0, "mirror holds exactly the expected items, all uploaded");
    stdout.printf("# %d items expected, %d on the server, %d in the mirror\n", expected, (int) remote_count(server), c.items().size);
}

uint remote_count(string server) {
    uint n = 0;
    try {
        var dir = Dir.open(server);
        string? name;
        while ((name = dir.read_name()) != null) if (name.has_suffix(".ics")) n++;
    } catch (Error e) {
    }
    return n;
}

void test_writers_and_a_syncer() {
    string mirror = scratch_dir("mirror");
    string server = scratch_dir("server");
    const int COUNT = 150;
    var syncer = spawn_worker(mirror, server, "sync", 4000, "syncloop");
    var a = spawn_worker(mirror, server, "a", COUNT, "write");
    var b = spawn_worker(mirror, server, "b", COUNT, "write");
    check(wait_ok(a) && wait_ok(b), "writers finished");
    check(wait_ok(syncer), "syncer finished");
    var c = new SyncedCollection("acc", new DirRemote(server), ContentKind.TASKS, mirror);
    check(run_sync(c), "final sync");
    int expected = 0;
    string[] missing = {};
    foreach (string who in new string[] { "a", "b" }) {
        for (int i = 0; i < COUNT; i++) {
            string uid = "%s-%d".printf(who, i);
            bool alive = expected_alive(i, COUNT);
            if (alive) expected++;
            bool on_server = FileUtils.test(Path.build_filename(server, uid + ".ics"), FileTest.EXISTS);
            bool in_mirror = c.get_item(uid) != null;
            if (alive != on_server || alive != in_mirror) missing += uid;
        }
    }
    if (missing.length > 0) stderr.printf("%d lost or resurrected: %s\n", missing.length, string.joinv(", ", missing));
    check(missing.length == 0, "no local edit written while another process synced was lost");
    stdout.printf("# %d items expected, %d on the server, %d in the mirror\n", expected, (int) remote_count(server), c.items().size);
}

void test_change_notification() {
    string mirror = scratch_dir("mirror");
    string server = scratch_dir("server");
    var c = new SyncedCollection("acc", new DirRemote(server), ContentKind.TASKS, mirror);
    c.watch();
    int changes = 0;
    c.changed.connect(() => changes++);
    var p = spawn_worker(mirror, server, "other", 3, "sync");
    bool exited = false;
    p.wait_async.begin(null, () => exited = true);
    var loop = new MainLoop();
    int64 deadline = get_monotonic_time() + 20 * 1000000;
    Timeout.add(50, () => {
        bool done = c.get_item("other-2") != null && c.pending_changes() == 0 && exited;
        if (!done && get_monotonic_time() < deadline) return Source.CONTINUE;
        loop.quit();
        return Source.REMOVE;
    });
    loop.run();
    check(wait_ok(p), "writer process finished");
    check(changes > 0, "changed() emitted for another process");
    check(c.get_item("other-0") != null && c.get_item("other-2") != null, "items written elsewhere are visible without a sync here");
    c.unwatch();
}

int main(string[] args) {
    if (args.length == 7 && args[1] == "--worker") return run_worker(args);
    Test.init(ref args);
    Test.add_func("/mirror/two-syncers", test_two_syncers);
    Test.add_func("/mirror/writers-and-a-syncer", test_writers_and_a_syncer);
    Test.add_func("/mirror/change-notification", test_change_notification);
    int result = Test.run();
    foreach (string dir in scratch_dirs) remove_tree(dir);
    return result;
}
