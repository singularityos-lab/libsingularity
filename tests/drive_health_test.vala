using Singularity;

static Variant sample(string state, string[] reasons) {
    return new Variant.tuple({
        new Variant.string("ab12"), new Variant.string("/dev/sdb"), new Variant.string("SanDisk Cruzer"),
        new Variant.string("4C53"), new Variant.uint64(32000000000), new Variant.string(state),
        new Variant.strv(reasons), new Variant.int64(1700000000), new Variant.uint64(0)
    });
}

static void test_parse() {
    var h = DriveHealth.from_variant(sample("failing", { "fake-capacity", "io-error" }));
    assert(h != null);
    assert(h.key == "ab12" && h.device == "/dev/sdb" && h.name == "SanDisk Cruzer" && h.size == 32000000000);
    assert(h.condition == DriveCondition.FAILING);
    assert(h.troubled);
    assert(h.reasons.length == 2);
    assert(h.explain().contains("more space than it really has"));
    assert(h.icon_name() == "dialog-error-symbolic");
    assert(DriveHealth.from_variant(new Variant("(s)", "x")) == null);
}

static void test_conditions() {
    assert(DriveCondition.parse("good") == DriveCondition.GOOD);
    assert(DriveCondition.parse("watch") == DriveCondition.WATCH);
    assert(DriveCondition.parse("worn") == DriveCondition.WORN);
    assert(DriveCondition.parse("nonsense") == DriveCondition.UNKNOWN);
    assert(!DriveHealth.from_variant(sample("watch", {})).troubled);
    assert(DriveHealth.from_variant(sample("worn", {})).troubled);
    foreach (var r in new string[] { "fake-capacity", "smart-failing", "smart-worn", "unreadable", "read-only",
                                     "check-failed", "io-error", "timeout", "reset", "slow-writes" }) {
        assert(DriveHealth.reason_text(r) != r);
    }
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/drive-health/parse", test_parse);
    Test.add_func("/drive-health/conditions", test_conditions);
    return Test.run();
}
