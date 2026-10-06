private string make_root() {
    try {
        return DirUtils.make_tmp("singularity-proc-XXXXXX");
    } catch (FileError e) {
        error("cannot create fake proc root: %s", e.message);
    }
}

private void write_fd(string root, int pid, int fd, string target, string fdinfo) {
    string base_dir = Path.build_filename(root, pid.to_string());
    DirUtils.create_with_parents(Path.build_filename(base_dir, "fd"), 0755);
    DirUtils.create_with_parents(Path.build_filename(base_dir, "fdinfo"), 0755);
    string link = Path.build_filename(base_dir, "fd", fd.to_string());
    FileUtils.remove(link);
    if (FileUtils.symlink(target, link) != 0) error("cannot link %s", link);
    try {
        FileUtils.set_contents(Path.build_filename(base_dir, "fdinfo", fd.to_string()), fdinfo);
    } catch (FileError e) {
        error("cannot write fdinfo: %s", e.message);
    }
}

private string intel_client(string id, uint64 render_ns) {
    return "pos:\t0\nflags:\t02100002\ndrm-driver:\ti915\ndrm-pdev:\t0000:00:02.0\n" +
        "drm-client-id:\t%s\ndrm-engine-render:\t%s ns\ndrm-engine-copy:\t0 ns\n".printf(id, render_ns.to_string()) +
        "drm-engine-capacity-render:\t1\ndrm-resident-system0:\t2048 KiB\n";
}

private void test_parse_amd_legacy_memory() {
    string text = "drm-driver:\tamdgpu\ndrm-pdev:\t0000:03:00.0\ndrm-client-id:\t7\n" +
        "drm-engine-gfx:\t5000 ns\ndrm-memory-vram:\t1024 KiB\ndrm-memory-gtt:\t512 KiB\n";
    Singularity.ProcessGpuUsage.Client client;
    assert(Singularity.ProcessGpuUsage.parse_fdinfo(text, out client));
    assert(client.key == "0000:03:00.0/7");
    assert(client.memory == 1536 * 1024);
    assert(client.engines.get("gfx") == 5000);
}

private void test_non_drm_fdinfo_is_ignored() {
    Singularity.ProcessGpuUsage.Client client;
    assert(!Singularity.ProcessGpuUsage.parse_fdinfo("pos:\t0\nflags:\t02\n", out client));
}

private void test_busy_share_and_shared_client() {
    string root = make_root();
    write_fd(root, 200, 5, "/dev/dri/renderD128", intel_client("11", 0));
    write_fd(root, 300, 9, "/dev/dri/renderD128", intel_client("11", 0));
    write_fd(root, 300, 4, "/tmp/notes.txt", "pos:\t0\n");
    var usage = new Singularity.ProcessGpuUsage();
    usage.proc_root = root;
    usage.sample();
    assert(usage.memory(200) == 2048 * 1024);
    assert(usage.memory(300) == 0);
    Thread.usleep(200000);
    write_fd(root, 200, 5, "/dev/dri/renderD128", intel_client("11", 100000000));
    write_fd(root, 300, 9, "/dev/dri/renderD128", intel_client("11", 100000000));
    usage.sample();
    double busy = usage.busy(200);
    assert(busy > 20 && busy < 60);
    assert(usage.busy(300) == 0);
}

private const string SS_OUTPUT =
    "ESTAB 0 0 192.168.1.2:43512 1.2.3.4:443 users:((\"firefox\",pid=1234,fd=55))\n" +
    "\t cubic wscale:7,7 rto:204 bytes_sent:1000 bytes_acked:1001 bytes_received:5000 segs_out:10\n" +
    "ESTAB 0 0 192.168.1.2:43514 5.6.7.8:443 users:((\"firefox\",pid=1234,fd=56))\n" +
    "\t cubic bytes_sent:200 bytes_received:300\n" +
    "ESTAB 0 0 127.0.0.1:631 127.0.0.1:50000\n" +
    "\t cubic bytes_sent:1 bytes_received:1\n";

private void test_parse_ss() {
    var sockets = Singularity.ProcessNetworkUsage.parse(SS_OUTPUT);
    assert(sockets.length == 2);
    assert(sockets[0].pid == 1234);
    assert(sockets[0].sent == 1000);
    assert(sockets[0].received == 5000);
    assert(sockets[1].key == "192.168.1.2:43514 5.6.7.8:443");
}

private void test_network_rates() {
    var usage = new Singularity.ProcessNetworkUsage();
    usage.apply(Singularity.ProcessNetworkUsage.parse(SS_OUTPUT));
    Thread.usleep(500000);
    string later = SS_OUTPUT.replace("bytes_received:5000", "bytes_received:55000")
        .replace("bytes_sent:200", "bytes_sent:10200");
    usage.apply(Singularity.ProcessNetworkUsage.parse(later));
    double received = usage.received_rate(1234);
    double sent = usage.sent_rate(1234);
    assert(received > 60000 && received < 110000);
    assert(sent > 12000 && sent < 22000);
    assert(usage.received_rate(999) == 0);
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/process-usage/amd-legacy-memory", test_parse_amd_legacy_memory);
    Test.add_func("/process-usage/non-drm-ignored", test_non_drm_fdinfo_is_ignored);
    Test.add_func("/process-usage/gpu-busy-shared-client", test_busy_share_and_shared_client);
    Test.add_func("/process-usage/parse-ss", test_parse_ss);
    Test.add_func("/process-usage/network-rates", test_network_rates);
    return Test.run();
}
