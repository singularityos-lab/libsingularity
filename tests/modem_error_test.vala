const string CORE = "org.freedesktop.ModemManager1.Error.Core.";

string describe(string name, string message) {
    return Singularity.ModemError.describe(DBusError.new_for_dbus_error(name, message));
}

void test_no_network() {
    assert(describe(CORE + "NotRegistered", "cellular service is not registered yet")
        == "There is no mobile network yet. Check the SIM or eSIM in Settings.");
}

void test_unknown_error_loses_the_bus_prefix() {
    assert(describe(CORE + "Failed", "end the current call before placing another")
        == "end the current call before placing another");
}

void test_esim_error() {
    assert(describe("dev.sinty.Modem1.ESIM.Error.Active", "profile is active")
        == "Turn the eSIM off before deleting it.");
}

void test_local_error_is_kept() {
    var e = new IOError.NOT_FOUND("No SIM");
    assert(Singularity.ModemError.describe(e) == "No SIM");
    assert(e.message == "No SIM");
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/modem-error/no-network", test_no_network);
    Test.add_func("/modem-error/unknown", test_unknown_error_loses_the_bus_prefix);
    Test.add_func("/modem-error/esim", test_esim_error);
    Test.add_func("/modem-error/local", test_local_error_is_kept);
    return Test.run();
}
