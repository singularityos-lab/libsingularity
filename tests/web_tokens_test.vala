using Singularity.Style;

void test_translation() {
    assert(WebTokens.translate("@text_color") == "var(--sinty-text-color)");
    assert(WebTokens.translate("#1a1a1a") == "#1a1a1a");
    assert(WebTokens.translate("rgba(248, 248, 248, 0.85)") == "rgba(248, 248, 248, 0.85)");
    assert(WebTokens.translate("alpha(@text_color, 0.04)") == "color-mix(in srgb, var(--sinty-text-color) 4%, transparent)");
    assert(WebTokens.translate("mix(@accent_color, white, 0.84)") == "color-mix(in srgb, var(--sinty-accent-color) 16%, white)");
    assert(WebTokens.translate("alpha(mix(@accent_color, black, 0.74), 0.94)")
        == "color-mix(in srgb, color-mix(in srgb, var(--sinty-accent-color) 26%, black) 94%, transparent)");
}

void test_every_theme_colour_is_exported() {
    string css;
    try {
        css = WebTokens.css();
    } catch (Error e) {
        assert_not_reached();
    }
    foreach (string resource in new string[] { "/dev/sinty/libsingularity/style.light.css", "/dev/sinty/libsingularity/style.dark.css" }) {
        string text;
        try {
            text = (string) GLib.resources_lookup_data(resource, 0).get_data();
        } catch (Error e) {
            assert_not_reached();
        }
        foreach (string line in text.split("\n")) {
            if (!line.has_prefix("@define-color ")) continue;
            string name = line.substring(14).split(" ")[0];
            if (!(WebTokens.property(name) + ":" in css)) {
                error("%s from %s is not exported", name, resource);
            }
        }
    }
    assert(!("@define" in css));
    assert(!(" alpha(" in css));
    assert(!(" mix(" in css));
    assert("--motion-duration-small:" in css);
    assert("--motion-curve-standard: cubic-bezier(" in css);
    assert("prefers-reduced-motion" in css);
    assert(":root[data-sinty-theme=\"dark\"]" in css);
    assert("[data-sinty-accent=\"teal\"]" in css);
}

void test_accents_follow_the_toolkit() {
    string css;
    try {
        css = WebTokens.css();
    } catch (Error e) {
        assert_not_reached();
    }
    string light_yellow = StyleManager.readable_accent("#e5a50a", false);
    assert(light_yellow != "#e5a50a");
    assert(("--sinty-accent-color: " + light_yellow + ";") in css);
    assert(("--sinty-accent-fg: " + StyleManager.contrast_fg_for(light_yellow) + ";") in css);
    assert("--sinty-accent-color: #3584e4;" in css);
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/web-tokens/translation", test_translation);
    Test.add_func("/web-tokens/every-theme-colour", test_every_theme_colour_is_exported);
    Test.add_func("/web-tokens/accents", test_accents_follow_the_toolkit);
    return Test.run();
}
