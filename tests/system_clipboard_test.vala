void test_no_compositor () {
    Environment.set_variable ("WAYLAND_DISPLAY", "sinty-test-missing-display", true);
    Environment.set_variable ("XDG_RUNTIME_DIR", Environment.get_tmp_dir (), true);
    try {
        Singularity.SystemClipboard.set_bytes (new Bytes ("x".data), { "text/plain" });
        assert_not_reached ();
    } catch (IOError e) {
    }
    assert (!Singularity.SystemClipboard.owns ());
    try {
        Singularity.SystemClipboard.set_bytes (new Bytes ("x".data), {});
        assert_not_reached ();
    } catch (IOError e) {
    }
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/system-clipboard/no-compositor", test_no_compositor);
    return Test.run ();
}
