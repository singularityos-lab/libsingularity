using GLib;
using Singularity;
using Singularity.Updates;
using Singularity.Firmware;

private string fixture;

private void put(string relative, string content) {
    string file = Path.build_filename(fixture, relative);
    DirUtils.create_with_parents(Path.get_dirname(file), 0755);
    try {
        FileUtils.set_contents(file, content);
    } catch (FileError e) {
        error("fixture write failed: %s", e.message);
    }
}

private void put_data(string relative, uint8[] data) {
    string file = Path.build_filename(fixture, relative);
    DirUtils.create_with_parents(Path.get_dirname(file), 0755);
    try {
        FileUtils.set_data(file, data);
    } catch (FileError e) {
        error("fixture write failed: %s", e.message);
    }
}

private void remove_tree(string path) {
    if (!FileUtils.test(path, FileTest.EXISTS)) return;
    if (FileUtils.test(path, FileTest.IS_DIR) && !FileUtils.test(path, FileTest.IS_SYMLINK)) {
        try {
            var dir = Dir.open(path);
            string? name;
            while ((name = dir.read_name()) != null) remove_tree(Path.build_filename(path, name));
        } catch (FileError e) {
            error("cleanup failed: %s", e.message);
        }
        DirUtils.remove(path);
    } else {
        FileUtils.remove(path);
    }
}

private void new_fixture(string name) {
    fixture = Path.build_filename(Environment.get_tmp_dir(), "updates-test-" + name);
    remove_tree(fixture);
    DirUtils.create_with_parents(fixture, 0755);
}

private void test_config() {
    new_fixture("config");
    var config = new Config();
    assert(config.backend == "auto");
    assert(config.atomic_bus_name == Config.ATOMIC_BUS_NAME);
    put("updates.conf", "[Updates]\nBackend=Atomic\n[Atomic]\nName=ABRoot\nBus=session\nBusName=org.example.Updates\nObjectPath=not a path\n");
    assert(config.load_file(Path.build_filename(fixture, "updates.conf")));
    assert(config.backend == "atomic");
    assert(config.atomic_name == "ABRoot");
    assert(config.atomic_bus_type() == BusType.SESSION);
    assert(config.atomic_bus_name == "org.example.Updates");
    assert(config.atomic_object_path == Config.ATOMIC_OBJECT_PATH);
    assert(Config.normalize_backend("PackageKit") == "packagekit");
    assert(Config.normalize_backend("rpm-ostree") == "auto");
    remove_tree(fixture);
}

private void test_state() {
    assert(State.parse("up-to-date") == State.UP_TO_DATE);
    assert(State.parse(" Scheduled ") == State.SCHEDULED);
    assert(State.parse("bogus") == State.UNKNOWN);
    assert(State.DOWNLOADING.is_busy());
    assert(!State.READY.is_busy());
}

private void test_packagekit_parsing() {
    var pkg = PackageKitProvider.package_from_id("openssl;3.0.13-1;x86_64;updates", "TLS library", true);
    assert(pkg.name == "openssl");
    assert(pkg.version == "3.0.13-1");
    assert(pkg.security);
    var entry = PackageKitProvider.history_entry("2026-09-20T10:00:00Z", true, 22,
        "updating\topenssl;3.0.13-1;x86_64;updates\nupdating\tbash;5.2-1;x86_64;updates\nupdating\topenssl;3.0.13-1;i686;updates");
    assert(entry.success);
    assert(entry.detail == "openssl, bash");
    assert(entry.time == new DateTime.utc(2026, 9, 20, 10, 0, 0).to_unix());
    var failed = PackageKitProvider.history_entry("garbage", false, 22, "");
    assert(!failed.success);
    assert(failed.time == 0);
}

private void test_markup() {
    string text = Client.markup_to_text("<p>This release fixes &amp; improves:</p><ul><li>Battery  life</li><li>USB-C &lt;PD&gt;</li></ul><p>Reboot required.</p>");
    assert(text == "This release fixes & improves:\n• Battery life\n• USB-C <PD>\n\nReboot required.");
    assert(Client.markup_to_text("  ") == "");
    assert(Client.markup_to_text("Plain") == "Plain");
}

private void test_hsi() {
    assert(Client.hsi_level("HSI:2 (v2.0.1)") == 2);
    assert(Client.hsi_level("HSI:0! (v1.9)") == 0);
    assert(Client.hsi_has_runtime_issue("HSI:0! (v1.9)"));
    assert(!Client.hsi_has_runtime_issue("HSI:3 (v2.0)"));
    assert(Client.hsi_level("HSI:INVALID:missing-data") == -1);
    assert(Client.hsi_level("") == -1);

    var dict = new VariantBuilder(new VariantType("a{sv}"));
    dict.add("{sv}", "AppstreamId", new Variant.string("org.fwupd.hsi.Uefi.SecureBoot"));
    dict.add("{sv}", "HsiLevel", new Variant.uint32(1));
    dict.add("{sv}", "HsiResult", new Variant.uint32(2));
    dict.add("{sv}", "Flags", new Variant.uint64(SecurityAttr.FLAG_ACTION_CONFIG_FW));
    var attr = SecurityAttr.from_variant(dict.end());
    assert(attr.failing);
    assert(attr.title == "Secure Boot");
    assert(attr.advice != "");
    assert(attr.result_text == "Not enabled.");

    var ok = new VariantBuilder(new VariantType("a{sv}"));
    ok.add("{sv}", "AppstreamId", new Variant.string("org.example.Unknown"));
    ok.add("{sv}", "Name", new Variant.string("Example check"));
    ok.add("{sv}", "HsiLevel", new Variant.uint32(3));
    ok.add("{sv}", "Flags", new Variant.uint64(SecurityAttr.FLAG_SUCCESS));
    var passed = SecurityAttr.from_variant(ok.end());
    assert(!passed.failing);
    assert(passed.title == "Example check");

    var runtime = new VariantBuilder(new VariantType("a{sv}"));
    runtime.add("{sv}", "AppstreamId", new Variant.string("org.fwupd.hsi.Kernel.Tainted"));
    runtime.add("{sv}", "HsiLevel", new Variant.uint32(0));
    runtime.add("{sv}", "Flags", new Variant.uint64(SecurityAttr.FLAG_RUNTIME_ISSUE));
    assert(SecurityAttr.from_variant(runtime.end()).failing);
}

private void test_firmware_variants() {
    var dev = new VariantBuilder(new VariantType("a{sv}"));
    dev.add("{sv}", "DeviceId", new Variant.string("abc"));
    dev.add("{sv}", "Name", new Variant.string("System Firmware"));
    dev.add("{sv}", "Flags", new Variant.uint64(Device.FLAG_UPDATABLE | Device.FLAG_NEEDS_REBOOT | Device.FLAG_REQUIRE_AC));
    var device = Device.from_variant(dev.end());
    assert(device.updatable && device.needs_restart && device.requires_ac);

    var rel = new VariantBuilder(new VariantType("a{sv}"));
    rel.add("{sv}", "Version", new Variant.string("1.2.3"));
    rel.add("{sv}", "Locations", new Variant.strv({ "https://example.org/a.cab", "https://mirror/a.cab" }));
    rel.add("{sv}", "Checksum", new Variant.strv({ "aa", "bb" }));
    rel.add("{sv}", "Size", new Variant.uint64(42));
    var release = Release.from_variant(rel.end());
    assert(release.uri == "https://example.org/a.cab");
    assert(release.checksum == "bb");
    assert(release.size == 42);

    var rem = new VariantBuilder(new VariantType("a{sv}"));
    rem.add("{sv}", "RemoteId", new Variant.string("lvfs"));
    rem.add("{sv}", "Uri", new Variant.string("https://cdn.fwupd.org/downloads/firmware.xml.zst"));
    rem.add("{sv}", "Flags", new Variant.uint64(1));
    rem.add("{sv}", "Type", new Variant.uint32(1));
    var remote = Remote.from_variant(rem.end());
    assert(remote.enabled && remote.downloads);
}

private void test_verify() {
    new_fixture("verify");
    put("blob", "firmware");
    var file = File.new_for_path(Path.build_filename(fixture, "blob"));
    try {
        Fetch.verify(file, Checksum.compute_for_string(ChecksumType.SHA256, "firmware"));
    } catch (Error e) {
        error("checksum should match: %s", e.message);
    }
    bool rejected = false;
    try {
        Fetch.verify(file, Checksum.compute_for_string(ChecksumType.SHA256, "other"));
    } catch (Error e) {
        rejected = true;
    }
    assert(rejected);
    remove_tree(fixture);
}

private void test_device_security() {
    new_fixture("security-bios");
    var bios = new DeviceSecurity(fixture);
    bios.read_tpm();
    bios.read_secure_boot();
    assert(!bios.tpm_present);
    assert(bios.secure_boot == SecureBootState.UNSUPPORTED);

    new_fixture("security-efi");
    string guid = "8be4df61-93ca-11d2-aa0d-00e098032b8c";
    put("sys/class/tpm/tpm0/tpm_version_major", "2\n");
    put_data("sys/firmware/efi/efivars/SecureBoot-" + guid, { 6, 0, 0, 0, 1 });
    put_data("sys/firmware/efi/efivars/SetupMode-" + guid, { 6, 0, 0, 0, 0 });
    put("proc/self/mountinfo",
        "22 1 253:0 / / rw,relatime - ext4 /dev/mapper/root rw\n" +
        "30 22 0:25 / /home rw - btrfs /dev/mapper/home rw\n");
    put("sys/dev/block/253:0/dm/uuid", "LVM-abc\n");
    put("sys/dev/block/253:0/slaves/dm-1/dev", "253:1\n");
    put("sys/dev/block/253:1/dm/uuid", "CRYPT-LUKS2-0123-root\n");
    var efi = new DeviceSecurity(fixture);
    efi.read_all("/home/user");
    assert(efi.tpm_present && efi.tpm_version == "2.0");
    assert(efi.secure_boot == SecureBootState.ENABLED);
    assert(efi.encryption == EncryptionState.ENCRYPTED);
    assert(efi.encryption_method == "LUKS");
    assert(efi.encryption_scope == "system");

    new_fixture("security-home");
    put_data("sys/firmware/efi/efivars/SecureBoot-" + guid, { 6, 0, 0, 0, 0 });
    put_data("sys/firmware/efi/efivars/SetupMode-" + guid, { 6, 0, 0, 0, 1 });
    put("proc/self/mountinfo",
        "22 1 8:2 / / rw - ext4 /dev/sda2 rw\n" +
        "30 22 0:40 / /home rw - btrfs /dev/mapper/crypthome rw\n");
    put("sys/class/block/dm-3/dm/name", "crypthome\n");
    put("sys/class/block/dm-3/dev", "253:3\n");
    put("sys/dev/block/253:3/dm/uuid", "CRYPT-LUKS1-9-crypthome\n");
    var home = new DeviceSecurity(fixture);
    home.read_all("/home/user");
    assert(home.secure_boot == SecureBootState.SETUP_MODE);
    assert(home.encryption == EncryptionState.ENCRYPTED);
    assert(home.encryption_scope == "home");

    new_fixture("security-plain");
    put("proc/self/mountinfo", "22 1 8:2 / / rw - ext4 /dev/sda2 rw\n");
    put("sys/class/tpm/tpm0/device/description", "TPM\n");
    var plain = new DeviceSecurity(fixture);
    plain.read_all("/home/user");
    assert(plain.encryption == EncryptionState.NOT_ENCRYPTED);
    assert(plain.tpm_present && plain.tpm_version == "");
    remove_tree(fixture);
    foreach (string name in new string[] { "security-bios", "security-efi", "security-home" }) {
        remove_tree(Path.build_filename(Environment.get_tmp_dir(), "updates-test-" + name));
    }
}

public static int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/updates/config", test_config);
    Test.add_func("/updates/state", test_state);
    Test.add_func("/updates/packagekit-parsing", test_packagekit_parsing);
    Test.add_func("/firmware/markup", test_markup);
    Test.add_func("/firmware/hsi", test_hsi);
    Test.add_func("/firmware/variants", test_firmware_variants);
    Test.add_func("/firmware/verify", test_verify);
    Test.add_func("/security/device", test_device_security);
    return Test.run();
}
