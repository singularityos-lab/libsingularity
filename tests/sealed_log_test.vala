using Singularity;

static string dir;
static Socket receiver;

static void setup () {
    try {
        dir = DirUtils.make_tmp ("sl-XXXXXX");
        FileUtils.set_contents (Path.build_filename (dir, "c"), "# test\n11 shell session user\n13 sinty-nm -\n");
        receiver = new Socket (SocketFamily.UNIX, SocketType.DATAGRAM, SocketProtocol.DEFAULT);
        receiver.bind (new UnixSocketAddress (Path.build_filename (dir, "s")), false);
        receiver.timeout = 2;
    } catch (Error e) {
        error (e.message);
    }
}

static uint8[] receive () {
    var buffer = new uint8[256];
    try {
        var n = receiver.receive (buffer);
        buffer.length = (int) n;
    } catch (Error e) {
        error (e.message);
    }
    return buffer;
}

static void expect (uint8[] got, uint8[] want) {
    assert (got.length == want.length);
    for (int i = 0; i < want.length; i++) {
        assert (got[i] == want[i]);
    }
}

static void test_session_events () {
    var log = SealedLog.open_at ("shell", Path.build_filename (dir, "c"), Path.build_filename (dir, "s"));
    assert (log != null);
    assert (log.log ("first-frame", { 1, 2, 3, 4 }));
    expect (receive (), { 11, 37, 3, 0, 1, 2, 3 });
    assert (log.log ("ready", { 300 }));
    expect (receive (), { 11, 2, 1, 0, 0xac, 0x02 });
    assert (log.log ("lock"));
    expect (receive (), { 11, 35, 0, 0 });
}

static void test_family_is_enforced () {
    var nm = SealedLog.open_at ("sinty-nm", Path.build_filename (dir, "c"), Path.build_filename (dir, "s"));
    assert (nm != null);
    assert (nm.code_of ("first-frame") == -1);
    assert (!nm.log ("first-frame"));
    assert (nm.code_of ("fail") == 4);
}

static void test_unknown_and_builtin () {
    assert (SealedLog.open_at ("nobody", Path.build_filename (dir, "c"), Path.build_filename (dir, "s")) == null);
    var updated = SealedLog.open_at ("updated", Path.build_filename (dir, "missing"), Path.build_filename (dir, "s"));
    assert (updated != null && updated.code_of ("rollback") == 34);
    var lost = SealedLog.open_at ("shell", Path.build_filename (dir, "c"), Path.build_filename (dir, "none"));
    assert (!lost.log ("ready"));
}

int main (string[] args) {
    Test.init (ref args);
    setup ();
    Test.add_func ("/sealed-log/session", test_session_events);
    Test.add_func ("/sealed-log/family", test_family_is_enforced);
    Test.add_func ("/sealed-log/unknown", test_unknown_and_builtin);
    return Test.run ();
}
