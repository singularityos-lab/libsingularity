using GLib;

private string fixture_root;

private void write_vendor(string card, string vendor) {
    string device = Path.build_filename(fixture_root, card, "device");
    assert(DirUtils.create_with_parents(device, 0755) == 0);
    try {
        assert(FileUtils.set_contents(
            Path.build_filename(device, "vendor"), vendor
        ));
    } catch (FileError e) {
        error("fixture write failed: %s", e.message);
    }
}

private void remove_path(File file) {
    try {
        var type = file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        if (type == FileType.DIRECTORY) {
            var children = file.enumerate_children(
                FileAttribute.STANDARD_NAME,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS
            );
            FileInfo? info;
            while ((info = children.next_file()) != null) {
                remove_path(file.get_child(info.get_name()));
            }
        }
        file.delete();
    } catch (Error e) {
        error("cleanup failed: %s", e.message);
    }
}

private void reset_fixture() {
    if (FileUtils.test(fixture_root, FileTest.EXISTS)) {
        remove_path(File.new_for_path(fixture_root));
    }
    assert(DirUtils.create_with_parents(fixture_root, 0755) == 0);
}

private void test_secondary_intel_card() {
    reset_fixture();
    assert(DirUtils.create_with_parents(
        Path.build_filename(fixture_root, "card0"), 0755
    ) == 0);
    write_vendor("card1", "0x8086\n");
    assert(
        Singularity.HardwareInfo.graphics_from_drm(fixture_root)
        == "Intel Graphics"
    );
}

private void test_hybrid_graphics() {
    reset_fixture();
    write_vendor("card1", "0x8086\n");
    write_vendor("card2", "0x10de\n");
    assert(
        Singularity.HardwareInfo.graphics_from_drm(fixture_root)
        == "Intel + NVIDIA Graphics"
    );
}

private void test_virtual_gpu() {
    reset_fixture();
    write_vendor("card0", "0x1af4\n");
    assert(Singularity.HardwareInfo.graphics_from_drm(fixture_root) == "VirtIO GPU");
}

private void write_block(string name, string size, string removable) {
    string dev = Path.build_filename(fixture_root, name);
    assert(DirUtils.create_with_parents(dev, 0755) == 0);
    try {
        FileUtils.set_contents(Path.build_filename(dev, "size"), size);
        FileUtils.set_contents(Path.build_filename(dev, "removable"), removable);
    } catch (FileError e) {
        error("fixture write failed: %s", e.message);
    }
}

private void test_disks() {
    reset_fixture();
    write_block("nvme0n1", "83886080\n", "0\n");
    write_block("sda", "1000\n", "1\n");
    write_block("loop0", "2048000\n", "0\n");
    write_block("zram0", "8000000\n", "0\n");
    write_block("dm-0", "2048000\n", "0\n");
    assert(Singularity.HardwareInfo.disks_from_sys(fixture_root) == (uint64) 83886080 * 512);
}

private void test_connector_is_ignored() {
    reset_fixture();
    write_vendor("card0-DP-1", "0x1002\n");
    assert(
        Singularity.HardwareInfo.graphics_from_drm(fixture_root)
        == "Unknown Graphics"
    );
}

private void write_file(string relative, string content) {
    string path = Path.build_filename(fixture_root, relative);
    assert(DirUtils.create_with_parents(Path.get_dirname(path), 0755) == 0);
    try {
        FileUtils.set_contents(path, content, content.length);
    } catch (FileError e) {
        error("fixture write failed: %s", e.message);
    }
}

private string arm_cpuinfo(string[] parts) {
    var sb = new StringBuilder();
    for (int i = 0; i < parts.length; i++) {
        sb.append("processor\t: %d\nBogoMIPS\t: 38.40\nCPU implementer\t: 0x41\nCPU architecture: 8\nCPU part\t: %s\n\n".printf(i, parts[i]));
    }
    return sb.str;
}

private void test_x86_processor() {
    reset_fixture();
    write_file("cpuinfo", "processor\t: 0\nmodel name\t: AMD Ryzen 7 7840U w/ Radeon 780M Graphics\n");
    assert(
        Singularity.HardwareInfo.processor_from(
            Path.build_filename(fixture_root, "cpuinfo"), Path.build_filename(fixture_root, "soc0")
        ) == "AMD Ryzen 7 7840U w/ Radeon 780M Graphics"
    );
}

private void test_arm_soc_processor() {
    reset_fixture();
    write_file("cpuinfo", arm_cpuinfo({ "0xd03", "0xd03", "0xd03", "0xd03" }));
    write_file("soc0/family", "Snapdragon\n");
    write_file("soc0/machine", "QRB2210\n");
    assert(
        Singularity.HardwareInfo.processor_from(
            Path.build_filename(fixture_root, "cpuinfo"), Path.build_filename(fixture_root, "soc0")
        ) == "Snapdragon QRB2210 (4 \u00d7 Cortex-A53)"
    );
}

private void test_arm_big_little_without_soc() {
    reset_fixture();
    write_file("cpuinfo", arm_cpuinfo({ "0xd05", "0xd05", "0xd05", "0xd05", "0xd0b", "0xd0b", "0xd0b", "0xd0b" }));
    assert(
        Singularity.HardwareInfo.processor_from(
            Path.build_filename(fixture_root, "cpuinfo"), Path.build_filename(fixture_root, "soc0")
        ) == "4 \u00d7 Cortex-A55 + 4 \u00d7 Cortex-A76"
    );
}

private void test_arm_unknown_cores() {
    reset_fixture();
    write_file("cpuinfo", arm_cpuinfo({ "0xfff", "0xfff" }));
    assert(
        Singularity.HardwareInfo.processor_from(
            Path.build_filename(fixture_root, "cpuinfo"), Path.build_filename(fixture_root, "soc0")
        ) == "2 cores"
    );
}

private void test_devicetree_model() {
    reset_fixture();
    write_file("model", "Arduino UNO Q\0");
    assert(
        Singularity.HardwareInfo.model_from(
            Path.build_filename(fixture_root, "dmi"), Path.build_filename(fixture_root, "model")
        ) == "Arduino UNO Q"
    );
}

private void test_dmi_model_first() {
    reset_fixture();
    write_file("dmi", "ThinkPad X13\n");
    write_file("model", "Board\0");
    assert(
        Singularity.HardwareInfo.model_from(
            Path.build_filename(fixture_root, "dmi"), Path.build_filename(fixture_root, "model")
        ) == "ThinkPad X13"
    );
}

private void test_adreno_chip_id() {
    assert(Singularity.HardwareInfo.gpu_from_compatible({ "qcom,adreno-07000200", "qcom,adreno" }) == "Qualcomm Adreno 702");
    assert(Singularity.HardwareInfo.gpu_from_compatible({ "qcom,adreno-630.2", "qcom,adreno" }) == "Qualcomm Adreno 630");
    assert(Singularity.HardwareInfo.gpu_from_compatible({ "qcom,adreno-43050a01", "qcom,adreno" }) == "Qualcomm Adreno");
}

private void test_other_soc_gpus() {
    assert(Singularity.HardwareInfo.gpu_from_compatible({ "rockchip,rk3588-mali", "arm,mali-valhall-csf" }) == "Arm Mali");
    assert(Singularity.HardwareInfo.gpu_from_compatible({ "rockchip,rk3399-mali", "arm,mali-t860" }) == "Arm Mali-T860");
    assert(Singularity.HardwareInfo.gpu_from_compatible({ "brcm,2711-v3d" }) == "Broadcom VideoCore");
    assert(Singularity.HardwareInfo.gpu_from_compatible({ "nvidia,gm20b" }) == "NVIDIA Tegra Graphics");
    assert(Singularity.HardwareInfo.gpu_from_compatible({ "simple-framebuffer" }) == null);
}

private void test_soc_gpu_from_bound_driver() {
    reset_fixture();
    write_file("drivers/adreno/5900000.gpu/of_node/compatible", "qcom,adreno-07000200\0qcom,adreno\0");
    assert(Singularity.HardwareInfo.soc_gpu(Path.build_filename(fixture_root, "drivers")) == "Qualcomm Adreno 702");
    reset_fixture();
    assert(Singularity.HardwareInfo.soc_gpu(Path.build_filename(fixture_root, "drivers")) == null);
}

private int main(string[] args) {
    Test.init(ref args);
    string root = Environment.get_variable("MESON_BUILD_ROOT")
        ?? Environment.get_current_dir();
    fixture_root = Path.build_filename(
        root, "hardware-info-" + Uuid.string_random()
    );

    Test.add_func("/hardware-info/secondary-intel-card", test_secondary_intel_card);
    Test.add_func("/hardware-info/hybrid-graphics", test_hybrid_graphics);
    Test.add_func("/hardware-info/ignore-connector", test_connector_is_ignored);
    Test.add_func("/hardware-info/virtual-gpu", test_virtual_gpu);
    Test.add_func("/hardware-info/disks", test_disks);
    Test.add_func("/hardware-info/x86-processor", test_x86_processor);
    Test.add_func("/hardware-info/arm-soc-processor", test_arm_soc_processor);
    Test.add_func("/hardware-info/arm-big-little", test_arm_big_little_without_soc);
    Test.add_func("/hardware-info/arm-unknown-cores", test_arm_unknown_cores);
    Test.add_func("/hardware-info/devicetree-model", test_devicetree_model);
    Test.add_func("/hardware-info/dmi-model-first", test_dmi_model_first);
    Test.add_func("/hardware-info/adreno-chip-id", test_adreno_chip_id);
    Test.add_func("/hardware-info/other-soc-gpus", test_other_soc_gpus);
    Test.add_func("/hardware-info/soc-gpu-bound-driver", test_soc_gpu_from_bound_driver);
    int result = Test.run();
    if (FileUtils.test(fixture_root, FileTest.EXISTS)) {
        remove_path(File.new_for_path(fixture_root));
    }
    return result;
}
