void test_stale_removed_live_kept() {
    string root;
    try {
        root = DirUtils.make_tmp("webkit-sockets-XXXXXX");
        if (root.length > 60) {
            DirUtils.remove(root);
            root = DirUtils.mkdtemp(Path.build_filename(Environment.get_user_runtime_dir(), "wks-XXXXXX"));
        }
    } catch (FileError e) {
        error("%s", e.message);
    }
    string dir = Path.build_filename(root, "webkitgtk");
    assert(DirUtils.create_with_parents(dir, 0700) == 0);
    string stale = Path.build_filename(dir, "bus-proxy-stale");
    string live = Path.build_filename(dir, "bus-proxy-live");
    string other = Path.build_filename(dir, "other-socket");
    Socket listener;
    try {
        var dead = new Socket(SocketFamily.UNIX, SocketType.STREAM, SocketProtocol.DEFAULT);
        dead.bind(new UnixSocketAddress(stale), true);
        dead.close();
        var dead_other = new Socket(SocketFamily.UNIX, SocketType.STREAM, SocketProtocol.DEFAULT);
        dead_other.bind(new UnixSocketAddress(other), true);
        dead_other.close();
        listener = new Socket(SocketFamily.UNIX, SocketType.STREAM, SocketProtocol.DEFAULT);
        listener.bind(new UnixSocketAddress(live), true);
        listener.listen();
    } catch (Error e) {
        error("%s", e.message);
    }
    assert(FileUtils.test(stale, FileTest.EXISTS));
    assert(Singularity.Core.WebKitSockets.clear_stale_bus_proxies(root) == 1);
    assert(!FileUtils.test(stale, FileTest.EXISTS));
    assert(FileUtils.test(live, FileTest.EXISTS));
    assert(FileUtils.test(other, FileTest.EXISTS));
    assert(Singularity.Core.WebKitSockets.clear_stale_bus_proxies(Path.build_filename(root, "missing")) == 0);
    try {
        listener.close();
    } catch (Error e) {
    }
    FileUtils.unlink(live);
    FileUtils.unlink(other);
    DirUtils.remove(dir);
    DirUtils.remove(root);
}

void test_no_webkit_in_plain_process() {
    assert(!Singularity.Core.WebKitSockets.webkit_loaded());
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/webkit-sockets/stale-removed-live-kept", test_stale_removed_live_kept);
    Test.add_func("/webkit-sockets/no-webkit-in-plain-process", test_no_webkit_in_plain_process);
    return Test.run();
}
