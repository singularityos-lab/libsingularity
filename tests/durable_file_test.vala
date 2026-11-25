void test_writes_in_order_and_keeps_the_newest() {
    var dir = DirUtils.make_tmp("durable-XXXXXX");
    var path = Path.build_filename(dir, "sub", "state.json");
    var file = new Singularity.DurableFile(path);
    for (int i = 0; i < 200; i++) file.write("value %d".printf(i));
    file.flush();
    string got;
    FileUtils.get_contents(path, out got);
    assert(got == "value 199");
    Posix.Stat st;
    Posix.stat(path, out st);
    assert((st.st_mode & 0777) == 0600);
    var entries = Dir.open(Path.get_dirname(path));
    int n = 0;
    while (entries.read_name() != null) n++;
    assert(n == 1);
}

void test_write_does_not_wait_for_the_disk() {
    var dir = DirUtils.make_tmp("durable-XXXXXX");
    var file = new Singularity.DurableFile(Path.build_filename(dir, "big"));
    var big = string.nfill(32 << 20, 'x');
    int64 t0 = get_monotonic_time();
    file.write(big);
    int64 spent = get_monotonic_time() - t0;
    file.flush();
    assert(spent < 20000);
    Posix.Stat st;
    Posix.stat(Path.build_filename(dir, "big"), out st);
    assert(st.st_size == 32 << 20);
}

void main(string[] args) {
    Test.init(ref args);
    Test.add_func("/durable-file/order", test_writes_in_order_and_keeps_the_newest);
    Test.add_func("/durable-file/non-blocking", test_write_does_not_wait_for_the_disk);
    Test.run();
}
