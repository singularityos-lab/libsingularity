using Gee;

namespace Singularity.Core {

    /**
     * Built-in terminal colour theme catalogue.
     *
     * Provides a set of predefined ColorTheme objects for terminal emulators
     * (e.g. singularity-terminal). The special `"auto"` theme derives its palette
     * from the current desktop accent colour at call time.
     */
    public class TerminalThemes : Object {

        // Resolve the current accent color hex from GSettings
        private static string get_accent_hex () {
            try {
                var s = new GLib.Settings ("dev.sinty.desktop");
                string name = s.get_string ("accent-color");
                // "custom" e "wallpaper" salvano entrambi il colore calcolato in custom-accent-color
                if (name == "custom" || name == "wallpaper")
                    return s.get_string ("custom-accent-color");
                switch (name) {
                    case "blue":   return "#3584e4";
                    case "teal":   return "#2190a4";
                    case "green":  return "#3a944a";
                    case "yellow": return "#c88800";
                    case "orange": return "#e66100";
                    case "red":    return "#e01b24";
                    case "pink":   return "#d56199";
                    case "purple": return "#9141ac";
                    case "slate":  return "#6f8396";
                    default:       return "#3584e4";
                }
            } catch { return "#3584e4"; }
        }

        // Mix accent with black for a dark-mode background.
        private static string tint_bg (string hex) {
            if (hex.length < 7) return "#0e0e0e";
            int r = (int) hex.substring (1, 2).to_long (null, 16);
            int g = (int) hex.substring (3, 2).to_long (null, 16);
            int b = (int) hex.substring (5, 2).to_long (null, 16);
            int br = (int)(0x0d + r * 0.18);
            int bg = (int)(0x0d + g * 0.18);
            int bb = (int)(0x0d + b * 0.18);
            return "#%02x%02x%02x".printf (br.clamp(0,255), bg.clamp(0,255), bb.clamp(0,255));
        }

        // Mix accent with white for a light-mode background (~10 % accent, 90 % white).
        private static string tint_bg_light (string hex) {
            if (hex.length < 7) return "#f5f5f5";
            int r = (int) hex.substring (1, 2).to_long (null, 16);
            int g = (int) hex.substring (3, 2).to_long (null, 16);
            int b = (int) hex.substring (5, 2).to_long (null, 16);
            int br = (int)(0xf5 - (255 - r) * 0.08);
            int bg = (int)(0xf5 - (255 - g) * 0.08);
            int bb = (int)(0xf5 - (255 - b) * 0.08);
            return "#%02x%02x%02x".printf (br.clamp(0,255), bg.clamp(0,255), bb.clamp(0,255));
        }

        // Darken accent by 20 % toward black (for light-mode variant).
        private static string darken (string hex) {
            if (hex.length < 7) return "#555555";
            int r = (int) hex.substring (1, 2).to_long (null, 16);
            int g = (int) hex.substring (3, 2).to_long (null, 16);
            int b = (int) hex.substring (5, 2).to_long (null, 16);
            int dr = (int)(r * 0.80);
            int dg = (int)(g * 0.80);
            int db = (int)(b * 0.80);
            return "#%02x%02x%02x".printf (dr.clamp(0,255), dg.clamp(0,255), db.clamp(0,255));
        }

        // Lighten accent by 40 % toward white (for dark-mode bright variant).
        private static string lighten (string hex) {
            if (hex.length < 7) return "#aaaaaa";
            int r = (int) hex.substring (1, 2).to_long (null, 16);
            int g = (int) hex.substring (3, 2).to_long (null, 16);
            int b = (int) hex.substring (5, 2).to_long (null, 16);
            int lr = r + (int)((255 - r) * 0.40);
            int lg = g + (int)((255 - g) * 0.40);
            int lb = b + (int)((255 - b) * 0.40);
            return "#%02x%02x%02x".printf (lr.clamp(0,255), lg.clamp(0,255), lb.clamp(0,255));
        }

        // Returns true when the desktop is in light mode.
        private static bool is_light_mode () {
            try {
                var s = new GLib.Settings ("dev.sinty.desktop");
                return !s.get_boolean ("dark-mode");
            } catch { return false; }
        }

        /**
         * Builds a terminal colour theme from the current desktop accent colour.
         * Automatically produces a dark or light variant to match the current
         * system colour scheme.
         */
        public static Singularity.Widgets.ColorTheme make_auto_theme () {
            string accent = get_accent_hex ();
            if (is_light_mode ()) {
                // Light variant: very light accent-tinted background, dark text.
                string bg      = tint_bg_light (accent);
                string acc_drk = darken (accent);
                return new Singularity.Widgets.ColorTheme (
                    "auto", "Auto (Accent Color)",
                    bg, "#1a1a1a",
                    {
                        "#f0f0f0", "#c0392b", "#27ae60", "#d68910",
                        accent,    "#8e44ad", "#16a085", "#555555",
                        "#aaaaaa", "#e74c3c", "#2ecc71", "#f1c40f",
                        acc_drk,   "#9b59b6", "#1abc9c", "#1a1a1a"
                    }
                );
            }
            // Dark variant (original behaviour).
            string bg_dark = tint_bg (accent);
            string acc_lit = lighten (accent);
            return new Singularity.Widgets.ColorTheme (
                "auto", "Auto (Accent Color)",
                bg_dark, "#e8e8e8",
                {
                    "#2a2a2a", "#f38ba8", "#a6e3a1", "#f9e2af",
                    accent,    "#cba6f7", "#89dceb",  "#cccccc",
                    "#555555", "#ff7f9f", "#b8f0bb", "#ffe0a0",
                    acc_lit,   "#d8b4ff", "#9aeaf7",  "#ffffff"
                }
            );
        }

        /**
         * Returns the full list of built-in themes, starting with `"auto"`.
         */
        public static ArrayList<Singularity.Widgets.ColorTheme> get_all() {
            var themes = new ArrayList<Singularity.Widgets.ColorTheme>();
            themes.add(make_auto_theme ());
            themes.add(new Singularity.Widgets.ColorTheme(
                "onedark",
                "One Dark",
                "#282c34",
                "#abb2bf",
                {
                    "#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
                    "#5c6370", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#ffffff"
                }
            ));
            themes.add(new Singularity.Widgets.ColorTheme(
                "dracula",
                "Dracula",
                "#282a36",
                "#f8f8f2",
                {
                    "#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
                    "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"
                }
            ));
            themes.add(new Singularity.Widgets.ColorTheme(
                "nord",
                "Nord",
                "#2e3440",
                "#d8dee9",
                {
                    "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
                    "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"
                }
            ));
            themes.add(new Singularity.Widgets.ColorTheme(
                "solarized-dark",
                "Solarized Dark",
                "#002b36",
                "#839496",
                {
                    "#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                    "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"
                }
            ));
            themes.add(new Singularity.Widgets.ColorTheme(
                "monokai",
                "Monokai Pro",
                "#2d2a2e",
                "#fcfcfa",
                {
                    "#403e41", "#ff6188", "#a9dc76", "#ffd866", "#fc9867", "#ab9df2", "#78dce8", "#fcfcfa",
                    "#727072", "#ff6188", "#a9dc76", "#ffd866", "#fc9867", "#ab9df2", "#78dce8", "#fcfcfa"
                }
            ));
            themes.add(new Singularity.Widgets.ColorTheme(
                "gruvbox",
                "Gruvbox Dark",
                "#282828",
                "#ebdbb2",
                {
                    "#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
                    "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"
                }
            ));
            themes.add(new Singularity.Widgets.ColorTheme(
                "tokyo-night",
                "Tokyo Night",
                "#1a1b26",
                "#c0caf5",
                {
                    "#15161e", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
                    "#414868", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5"
                }
            ));
            themes.add(new Singularity.Widgets.ColorTheme(
                "catppuccin",
                "Catppuccin",
                "#1e1e2e",
                "#cdd6f4",
                {
                    "#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
                    "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"
                }
            ));
            return themes;
        }

        /**
         * Looks up a theme by its machine-readable identifier.
         *
         * @param id Theme ID (e.g. `"dracula"`, `"nord"`, `"auto"`).
         * @return The matching theme, or `null` if not found.
         */
        public static Singularity.Widgets.ColorTheme? get_by_id(string id) {
            if (id == "auto") return make_auto_theme ();
            foreach (var theme in get_all()) {
                if (theme.id == id) return theme;
            }
            return null;
        }

        /**
         * Generates a GtkSourceView 5 style-scheme XML string for the given
         * theme id. Returns an empty string if the id is unknown.
         */
        public static string get_source_scheme_xml (string id) {
            var theme = get_by_id (id);
            if (theme == null) return "";
            return _theme_to_source_xml (theme);
        }

        // Mix two hex colours: t=0 → hex1, t=1 → hex2.
        private static string _mix_hex (string hex1, string hex2, double t) {
            if (hex1.length < 7 || hex2.length < 7) return hex1;
            int r1 = (int) hex1.substring (1, 2).to_long (null, 16);
            int g1 = (int) hex1.substring (3, 2).to_long (null, 16);
            int b1 = (int) hex1.substring (5, 2).to_long (null, 16);
            int r2 = (int) hex2.substring (1, 2).to_long (null, 16);
            int g2 = (int) hex2.substring (3, 2).to_long (null, 16);
            int b2 = (int) hex2.substring (5, 2).to_long (null, 16);
            int r = (int) (r1 * (1.0 - t) + r2 * t);
            int g = (int) (g1 * (1.0 - t) + g2 * t);
            int b = (int) (b1 * (1.0 - t) + b2 * t);
            return "#%02x%02x%02x".printf (r.clamp(0,255), g.clamp(0,255), b.clamp(0,255));
        }

        // Returns the relative luminance (BT.709) of a hex colour.
        private static float _lum_hex (string hex) {
            if (hex.length < 7) return 0.0f;
            float r = (float) hex.substring (1, 2).to_long (null, 16) / 255.0f;
            float g = (float) hex.substring (3, 2).to_long (null, 16) / 255.0f;
            float b = (float) hex.substring (5, 2).to_long (null, 16) / 255.0f;
            return 0.2126f * r + 0.7152f * g + 0.0722f * b;
        }

        private static string _theme_to_source_xml (Singularity.Widgets.ColorTheme theme) {
            string bg  = theme.background;
            string fg  = theme.foreground;
            var    p   = theme.palette;

            bool   dark     = _lum_hex (bg) < 0.3f;
            string cur_line = dark ? _mix_hex (bg, "#ffffff", 0.08)
                                   : _mix_hex (bg, "#000000", 0.05);
            string ln_bg    = dark ? _mix_hex (bg, "#000000", 0.12)
                                   : _mix_hex (bg, "#000000", 0.04);
            string sel_bg   = dark ? _mix_hex (p[4], bg, 0.30)
                                   : _mix_hex (p[4], "#ffffff", 0.55);
            string variant  = dark ? "dark" : "light";
            string sid      = "sinty-" + theme.id;

            return
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
                "<style-scheme id=\"%s\" name=\"%s\" version=\"1.0\">\n".printf (sid, theme.name) +
                "  <author>Singularity</author>\n" +
                "  <metadata><property name=\"variant\">%s</property></metadata>\n".printf (variant) +
                "  <color name=\"bg\"   value=\"%s\"/>\n".printf (bg) +
                "  <color name=\"fg\"   value=\"%s\"/>\n".printf (fg) +
                "  <color name=\"p0\"   value=\"%s\"/>\n".printf (p[0]) +
                "  <color name=\"p1\"   value=\"%s\"/>\n".printf (p[1]) +
                "  <color name=\"p2\"   value=\"%s\"/>\n".printf (p[2]) +
                "  <color name=\"p3\"   value=\"%s\"/>\n".printf (p[3]) +
                "  <color name=\"p4\"   value=\"%s\"/>\n".printf (p[4]) +
                "  <color name=\"p5\"   value=\"%s\"/>\n".printf (p[5]) +
                "  <color name=\"p6\"   value=\"%s\"/>\n".printf (p[6]) +
                "  <color name=\"p7\"   value=\"%s\"/>\n".printf (p[7]) +
                "  <color name=\"p8\"   value=\"%s\"/>\n".printf (p[8]) +
                "  <color name=\"p9\"   value=\"%s\"/>\n".printf (p[9]) +
                "  <color name=\"p10\"  value=\"%s\"/>\n".printf (p[10]) +
                "  <color name=\"p11\"  value=\"%s\"/>\n".printf (p[11]) +
                "  <color name=\"p12\"  value=\"%s\"/>\n".printf (p[12]) +
                "  <color name=\"p13\"  value=\"%s\"/>\n".printf (p[13]) +
                "  <color name=\"p14\"  value=\"%s\"/>\n".printf (p[14]) +
                "  <color name=\"p15\"  value=\"%s\"/>\n".printf (p[15]) +
                "  <color name=\"cur\"  value=\"%s\"/>\n".printf (cur_line) +
                "  <color name=\"lnbg\" value=\"%s\"/>\n".printf (ln_bg) +
                "  <color name=\"sel\"  value=\"%s\"/>\n".printf (sel_bg) +
                "  <style name=\"text\"              foreground=\"fg\"  background=\"bg\"/>\n" +
                "  <style name=\"line-numbers\"      foreground=\"p8\"  background=\"lnbg\"/>\n" +
                "  <style name=\"current-line\"      background=\"cur\"/>\n" +
                "  <style name=\"current-line-number\" foreground=\"fg\"/>\n" +
                "  <style name=\"draw-spaces\"        foreground=\"p8\"/>\n" +
                "  <style name=\"selection\"          background=\"sel\" foreground=\"bg\"/>\n" +
                "  <style name=\"bracket-match\"      foreground=\"p3\"  bold=\"true\"/>\n" +
                "  <style name=\"bracket-mismatch\"   foreground=\"p1\"  bold=\"true\"/>\n" +
                "  <style name=\"def:comment\"        foreground=\"p8\"  italic=\"true\"/>\n" +
                "  <style name=\"def:doc-comment\"    foreground=\"p8\"  italic=\"true\"/>\n" +
                "  <style name=\"def:string\"         foreground=\"p2\"/>\n" +
                "  <style name=\"def:keyword\"        foreground=\"p5\"  bold=\"true\"/>\n" +
                "  <style name=\"def:type\"           foreground=\"p3\"/>\n" +
                "  <style name=\"def:class\"          foreground=\"p3\"/>\n" +
                "  <style name=\"def:constant\"       foreground=\"p4\"/>\n" +
                "  <style name=\"def:number\"         foreground=\"p9\"/>\n" +
                "  <style name=\"def:float\"          foreground=\"p9\"/>\n" +
                "  <style name=\"def:identifier\"     foreground=\"fg\"/>\n" +
                "  <style name=\"def:function\"       foreground=\"p12\"/>\n" +
                "  <style name=\"def:preprocessor\"   foreground=\"p6\"/>\n" +
                "  <style name=\"def:special-char\"   foreground=\"p14\"/>\n" +
                "  <style name=\"def:operator\"       foreground=\"fg\"/>\n" +
                "  <style name=\"def:variable\"       foreground=\"fg\"/>\n" +
                "  <style name=\"def:error\"          foreground=\"p1\"  underline=\"error\"/>\n" +
                "  <style name=\"def:warning\"        foreground=\"p3\"  underline=\"single\"/>\n" +
                "</style-scheme>\n";
        }
    }
}
