namespace Singularity.Style {

    /**
     * The design tokens of libsingularity as CSS custom properties for the
     * web, generated from the same theme definitions, accents and motion
     * values the toolkit uses, so pages built on them match the desktop.
     *
     * Colours are `--sinty-<name>`, with `_` in the GTK name written as `-`.
     * The scheme follows `prefers-color-scheme` unless the root element sets
     * `data-sinty-theme` to `light` or `dark`; the accent is chosen with
     * `data-sinty-accent`, blue when it is absent.
     */
    public class WebTokens : Object {

        private const string LIGHT_BASE = "#f6f5f4";
        private const string DARK_BASE = "#242424";
        private const string LIGHT_TOOLBAR = "#e8e8e8";
        private const string DARK_TOOLBAR = "#1a1a1a";
        private const double LIGHT_TOOLBAR_ALPHA = 0.85;
        private const double DARK_TOOLBAR_ALPHA = 0.75;

        public static string css() throws Error {
            var b = new StringBuilder();
            b.append(":root {\n");
            theme(b, "/dev/sinty/libsingularity/style.light.css");
            derived(b, false);
            accent(b, "blue", false);
            motion(b, false);
            b.append("  font-family: 'Inter', sans-serif;\n}\n");

            b.append("@media (prefers-color-scheme: dark) {\n  :root:not([data-sinty-theme=\"light\"]) {\n");
            theme(b, "/dev/sinty/libsingularity/style.dark.css", "  ");
            derived(b, true, "  ");
            accent(b, "blue", true, "  ");
            b.append("  }\n");
            for (int i = 0; i < StyleManager.ACCENT_NAMES.length; i++) {
                string name = StyleManager.ACCENT_NAMES[i];
                b.append_printf("  :root:not([data-sinty-theme=\"light\"])[data-sinty-accent=\"%s\"] {\n", name);
                accent(b, name, true, "  ");
                b.append("  }\n");
            }
            b.append("}\n");

            b.append(":root[data-sinty-theme=\"dark\"] {\n");
            theme(b, "/dev/sinty/libsingularity/style.dark.css");
            derived(b, true);
            accent(b, "blue", true);
            b.append("}\n");

            for (int i = 0; i < StyleManager.ACCENT_NAMES.length; i++) {
                string name = StyleManager.ACCENT_NAMES[i];
                b.append_printf(":root[data-sinty-accent=\"%s\"] {\n", name);
                accent(b, name, false);
                b.append("}\n");
                b.append_printf(":root[data-sinty-theme=\"dark\"][data-sinty-accent=\"%s\"] {\n", name);
                accent(b, name, true);
                b.append("}\n");
            }

            b.append("@media (prefers-reduced-motion: reduce) {\n  :root {\n");
            motion(b, true, "  ");
            b.append("  }\n}\n");
            return b.str;
        }

        public static string property(string gtk_name) {
            return "--sinty-" + gtk_name.replace("_", "-");
        }

        private static void theme(StringBuilder b, string resource, string indent = "") throws Error {
            var bytes = GLib.resources_lookup_data(resource, 0);
            string text = (string) bytes.get_data();
            var definition = new Regex("@define-color\\s+([A-Za-z0-9_]+)\\s+([^;]+);");
            MatchInfo match;
            definition.match(text, 0, out match);
            while (match.matches()) {
                b.append_printf("%s  %s: %s;\n", indent, property(match.fetch(1)), translate(match.fetch(2).strip()));
                match.next();
            }
        }

        private static void derived(StringBuilder b, bool dark, string indent = "") {
            string accent = "var(--sinty-accent-color)";
            string base_bg = dark ? DARK_BASE : LIGHT_BASE;
            string toolbar = dark ? DARK_TOOLBAR : LIGHT_TOOLBAR;
            double alpha = dark ? DARK_TOOLBAR_ALPHA : LIGHT_TOOLBAR_ALPHA;
            b.append_printf("%s  --sinty-window-tint: %s;\n", indent, mix(base_bg, accent, 0.08));
            b.append_printf("%s  --sinty-overview-bg: var(--sinty-window-tint);\n", indent);
            b.append_printf("%s  --sinty-toolbar-bg: %s;\n", indent, mix(base_bg, mix(toolbar, accent, 0.05), alpha));
            b.append_printf("%s  --sinty-headerbar-bg-color: var(--sinty-toolbar-bg);\n", indent);
            b.append_printf("%s  --sinty-accent-bg: var(--sinty-accent-color);\n", indent);
            b.append_printf("%s  --sinty-accent-bg-color: var(--sinty-accent-color);\n", indent);
            b.append_printf("%s  --sinty-accent-fg-color: var(--sinty-accent-fg);\n", indent);
        }

        private static void accent(StringBuilder b, string name, bool dark, string indent = "") {
            string hex = "#3584e4";
            for (int i = 0; i < StyleManager.ACCENT_NAMES.length; i++) {
                if (StyleManager.ACCENT_NAMES[i] == name) hex = StyleManager.ACCENT_HEXES[i];
            }
            string readable = StyleManager.readable_accent(hex, dark);
            b.append_printf("%s  --sinty-accent-color: %s;\n", indent, readable);
            b.append_printf("%s  --sinty-accent-fg: %s;\n", indent, StyleManager.contrast_fg_for(readable));
        }

        private static void motion(StringBuilder b, bool reduce, string indent = "") {
            foreach (var duration in Motion.Duration.all()) {
                uint ms = duration.ms();
                if (reduce && ms > Motion.Duration.SMALL.ms()) ms = Motion.Duration.SMALL.ms();
                b.append_printf("%s  --motion-duration-%s: %ums;\n", indent, duration.css_name(), ms);
                b.append_printf("%s  --motion-duration-%s-exit: %ums;\n", indent, duration.css_name(),
                    (uint) Math.round(ms * Motion.EXIT_FACTOR));
            }
            foreach (var curve in Motion.Curve.all()) {
                string value = reduce && curve != Motion.Curve.LINEAR ? Motion.Curve.LINEAR.to_css() : curve.to_css();
                b.append_printf("%s  --motion-curve-%s: %s;\n", indent, curve.css_name(), value);
            }
        }

        private static string number(double value) {
            double rounded = Math.round(value * 10000.0) / 10000.0;
            string text = rounded.to_string();
            return text;
        }

        private static string mix(string first, string second, double factor) {
            return "color-mix(in srgb, %s %s%%, %s)".printf(first, number((1.0 - factor) * 100.0), second);
        }

        /**
         * Rewrites one GTK colour expression as standard CSS: `@name` becomes
         * a custom property, `alpha()` and `mix()` become `color-mix()`.
         */
        public static string translate(string expression) {
            int pos = 0;
            return parse(expression, ref pos).strip();
        }

        private static string parse(string s, ref int pos) {
            while (pos < s.length && s[pos].isspace()) pos++;
            if (pos < s.length && s[pos] == '@') {
                int start = ++pos;
                while (pos < s.length && (s[pos].isalnum() || s[pos] == '_')) pos++;
                return "var(%s)".printf(property(s.substring(start, pos - start)));
            }
            int start = pos;
            while (pos < s.length && (s[pos].isalnum() || s[pos] == '-' || s[pos] == '_' || s[pos] == '#' || s[pos] == '.')) pos++;
            string word = s.substring(start, pos - start);
            if (pos < s.length && s[pos] == '(') {
                pos++;
                var args = new GenericArray<string>();
                if (word == "alpha" || word == "mix") {
                    while (pos < s.length) {
                        args.add(parse(s, ref pos));
                        while (pos < s.length && s[pos].isspace()) pos++;
                        if (pos < s.length && s[pos] == ',') {
                            pos++;
                            continue;
                        }
                        if (pos < s.length && s[pos] == ')') pos++;
                        break;
                    }
                    if (word == "alpha" && args.length == 2) {
                        return "color-mix(in srgb, %s %s%%, transparent)".printf(args[0], number(double.parse(args[1]) * 100.0));
                    }
                    if (word == "mix" && args.length == 3) {
                        return mix(args[0], args[1], double.parse(args[2]));
                    }
                    return s.substring(start, pos - start);
                }
                int depth = 1;
                while (pos < s.length && depth > 0) {
                    if (s[pos] == '(') depth++;
                    else if (s[pos] == ')') depth--;
                    pos++;
                }
                return s.substring(start, pos - start);
            }
            return word;
        }
    }
}
