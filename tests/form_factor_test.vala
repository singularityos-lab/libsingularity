using Singularity;

void test_phone_panel_over_dsi() {
    assert(FormFactor.classify("DSI-1", 71, 155) == FormFactorKind.PHONE);
    assert(FormFactor.classify_main("DSI-1", 71, 155) == FormFactorKind.PHONE);
}

void test_phone_panel_without_connector_name() {
    assert(FormFactor.classify("Unknown-1", 71, 155) == FormFactorKind.PHONE);
    assert(FormFactor.classify_main("Unknown-1", 71, 155) == FormFactorKind.PHONE);
}

void test_laptop_panel_stays_desktop() {
    assert(FormFactor.classify("eDP-1", 302, 188) == FormFactorKind.DESKTOP);
    assert(FormFactor.classify_main("eDP-1", 302, 188) == FormFactorKind.DESKTOP);
}

void test_unknown_size_stays_desktop() {
    assert(FormFactor.classify("DSI-1", 0, 0) == FormFactorKind.DESKTOP);
    assert(FormFactor.classify_main("HDMI-A-1", 0, 0) == FormFactorKind.DESKTOP);
}

void test_watch_panel() {
    assert(FormFactor.classify("DSI-1", 30, 30) == FormFactorKind.WATCH);
    assert(FormFactor.classify_main("DSI-1", 30, 30) == FormFactorKind.WATCH);
}

void test_external_screens_keep_their_kind_but_not_as_main() {
    assert(FormFactor.classify("HDMI-A-1", 230, 160) == FormFactorKind.TABLET);
    assert(FormFactor.classify("HDMI-A-1", 1210, 680) == FormFactorKind.TV);
    assert(FormFactor.classify_main("HDMI-A-1", 230, 160) == FormFactorKind.DESKTOP);
    assert(FormFactor.classify_main("HDMI-A-1", 1210, 680) == FormFactorKind.DESKTOP);
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/form-factor/phone-dsi", test_phone_panel_over_dsi);
    Test.add_func("/form-factor/phone-unknown-connector", test_phone_panel_without_connector_name);
    Test.add_func("/form-factor/laptop", test_laptop_panel_stays_desktop);
    Test.add_func("/form-factor/unknown-size", test_unknown_size_stays_desktop);
    Test.add_func("/form-factor/watch", test_watch_panel);
    Test.add_func("/form-factor/external", test_external_screens_keep_their_kind_but_not_as_main);
    return Test.run();
}
