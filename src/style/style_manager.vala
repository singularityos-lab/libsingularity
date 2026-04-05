using Gtk;
using Gdk;

namespace Singularity.Style {

    /**
     * Manages GTK CSS theming for Singularity apps.
     *
     * Loads the built-in dark theme and applies accent colour, light/dark
     * switching, high-contrast override, and large-text scaling. All CSS is
     * embedded in the library as a GResource and therefore requires no
     * external files at runtime.
     *
     * Obtain the shared instance via get_default. The instance is
     * initialised automatically by Singularity.Application.startup.
     */
    public class StyleManager : Object {

        private static StyleManager? _instance;

        /**
         * Returns the shared StyleManager instance,
         * creating it on first call.
         */
        public static StyleManager get_default() {
            if (_instance == null) {
                _instance = new StyleManager();
            }
            return _instance;
        }

        /**
         * Loads the structural theme CSS into the default display.
         *
         * Also loads dark color variables by default. Call
         * apply_color_scheme() afterwards to switch to light.
         */
        public void load_theme() {
            if (base_theme_provider != null) return;
            _load_combined_css(true);
        }

        /**
         * Reloads the combined color-vars + structural CSS into a single
         * provider so that @define-color declarations are visible to all
         * rules.
         */
        private void _load_combined_css(bool dark) {
            var display = Gdk.Display.get_default();
            if (base_theme_provider != null) {
                StyleContext.remove_provider_for_display(display, base_theme_provider);
                base_theme_provider = null;
            }
            string color_path = dark
                ? "/dev/sinty/libsingularity/style.dark.css"
                : "/dev/sinty/libsingularity/style.light.css";
            try {
                var color_bytes = GLib.resources_lookup_data(color_path, 0);
                var struct_bytes = GLib.resources_lookup_data(
                    "/dev/sinty/libsingularity/style.css", 0);
                unowned uint8[] color_data = color_bytes.get_data();
                unowned uint8[] struct_data = struct_bytes.get_data();
                string color_css = (string) color_data;
                string struct_css = (string) struct_data;
                string combined = color_css + "\n" + struct_css;
                base_theme_provider = new CssProvider();
                base_theme_provider.load_from_string(combined);
                StyleContext.add_provider_for_display(
                    display,
                    base_theme_provider,
                    Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
                );
            } catch (Error e) {
                warning("StyleManager: FAILED to load theme: %s", e.message);
                base_theme_provider = null;
            }
        }

        /**
         * Updates the accent colour CSS variables on the given provider.
         *
         * The `color_name` argument is one of the named swatches:
         * blue, teal, green, yellow, orange, red, pink, purple, slate;
         * or the special value `"wallpaper"`, which case the dominant 
         * colour is sampled from `wallpaper_path`.
         *
         * @param provider     The Gtk.CssProvider to update.
         * @param color_name   Accent colour identifier.
         * @param wallpaper_path Filesystem path to the wallpaper image; only
         *                      used when `color_name` is `"wallpaper"`.
         */
        public void apply_accent_color(CssProvider provider, string color_name, string? wallpaper_path = null) {
            string hex_color = "#3584e4";
            if (color_name.has_prefix("#") && color_name.length >= 7) {
                // Hex color passed directly (e.g. from custom color picker or wallpaper extraction).
                hex_color = color_name;
            } else if (color_name == "wallpaper" && wallpaper_path != null) {
                hex_color = extract_primary_color(wallpaper_path);
            } else {
                switch (color_name) {
                    case "blue":   hex_color = "#3584e4"; break;
                    case "teal":   hex_color = "#2190a4"; break;
                    case "green":  hex_color = "#3a944a"; break;
                    case "yellow": hex_color = "#e5a50a"; break;
                    case "orange": hex_color = "#e66100"; break;
                    case "red":    hex_color = "#e01b24"; break;
                    case "pink":   hex_color = "#d56199"; break;
                    case "purple": hex_color = "#9141ac"; break;
                    case "slate":  hex_color = "#787878"; break;
                }
            }
            // Pre-compute surface tint colors in Vala so GTK CSS never needs to
            // resolve mix() at paint time. Use mode-appropriate base colors.
            bool dark = current_dark_mode;
            string base_bg     = dark ? "#242424" : "#f6f5f4";
            string toolbar_base = dark ? "#1a1a1a" : "#e8e8e8";
            string dock_base   = dark ? "#1e1e1e" : "#e0e0e0";
            string dock_blur   = dark ? "#141414" : "#d8d8d8";
            string hover_rgba  = dark ? "rgba(255, 255, 255, 0.08)" : "rgba(0, 0, 0, 0.06)";
            double toolbar_alpha = dark ? 0.75 : 0.85;
            double dock_alpha    = dark ? 0.70 : 0.80;
            double dock_blur_alpha = dark ? 0.45 : 0.60;
            string tint8 = _mix_hex(base_bg, hex_color, 0.08);
            // Compute toolbar rgba directly to avoid GTK CSS alpha(#hex) issues.
            string toolbar_rgba = _mix_rgba(toolbar_base, hex_color, 0.05, toolbar_alpha);
            // Pre-compute hover/active variants for button rules.
            string hover_hex  = _mix_hex(hex_color, "#ffffff", 0.15);
            string active_hex = _mix_hex(hex_color, "#000000", 0.15);
            // Dock background: base + 4% accent tint (opaque + blur variant)
            string dock_bg      = _mix_rgba(dock_base, hex_color, 0.04, dock_alpha);
            string dock_bg_blur = _mix_rgba(dock_blur, hex_color, 0.04, dock_blur_alpha);
            // Compute alpha variants (pure alpha of the accent color).
            uint8 ar, ag, ab;
            _parse_hex(hex_color, out ar, out ag, out ab);
            string alpha10 = "rgba(%u, %u, %u, 0.10)".printf(ar, ag, ab);
            string alpha15 = "rgba(%u, %u, %u, 0.15)".printf(ar, ag, ab);
            string alpha20 = "rgba(%u, %u, %u, 0.20)".printf(ar, ag, ab);
            string alpha25 = "rgba(%u, %u, %u, 0.25)".printf(ar, ag, ab);
            string alpha28 = "rgba(%u, %u, %u, 0.28)".printf(ar, ag, ab);
            string alpha35 = "rgba(%u, %u, %u, 0.35)".printf(ar, ag, ab);
            string alpha40 = "rgba(%u, %u, %u, 0.40)".printf(ar, ag, ab);
            string alpha50 = "rgba(%u, %u, %u, 0.50)".printf(ar, ag, ab);
            string alpha80 = "rgba(%u, %u, %u, 0.80)".printf(ar, ag, ab);
            string alpha85 = "rgba(%u, %u, %u, 0.85)".printf(ar, ag, ab);
            string css = ("""
                /* Named color definitions - convenience for CSS rules in style.css
                 * that reference @accent_color etc. */
                @define-color accent_color %s;
                @define-color accent_bg @accent_color;
                @define-color accent_bg_color @accent_color;
                @define-color accent_fg white;
                @define-color accent_fg_color white;
                @define-color accent_color_10 %s;
                @define-color accent_color_15 %s;
                @define-color accent_color_20 %s;
                @define-color accent_color_50 %s;
                @define-color hover_white %s;
                @define-color window_tint %s;
                @define-color overview_bg @window_tint;
                @define-color toolbar_bg %s;
                @define-color headerbar_bg_color @toolbar_bg;

                /* ── Accent widget rules (hardcoded hex, priority 601 beats GTK built-in) ──
                 * GTK4's Default fallback theme hardcodes switch:checked blue (#3584e4).
                 * If @accent_color ever fails to resolve (undefined in that cascade step),
                 * GTK falls back to that blue. Emitting the rules here with literal hex
                 * values at priority 601 guarantees the correct accent is always applied. */

                switch:checked {
                    background-color: %s;
                    border-color: %s;
                }
                switch:checked > slider { border-color: %s; }

                .singularity switch:checked,
                .singularity-app switch:checked {
                    background-color: %s;
                    border-color: %s;
                }

                scale trough highlight { background-color: %s; }
                scale slider { background-color: %s; }
                .singularity scale trough highlight,
                .singularity-app scale trough highlight { background-color: %s; }
                .singularity scale slider,
                .singularity-app scale slider { background-color: %s; }

                progressbar progress { background-color: %s; }
                .singularity progressbar progress,
                .singularity-app progressbar progress { background-color: %s; }

                button.suggested-action {
                    background-color: %s;
                    color: white;
                }
                button.suggested-action:hover   { background-color: %s; }
                button.suggested-action:active  { background-color: %s; }
                .singularity button.suggested-action,
                .singularity-app button.suggested-action { background-color: %s; }
                .singularity button.suggested-action:hover,
                .singularity-app button.suggested-action:hover { background-color: %s; }

                checkbutton check:checked,
                radiobutton radio:checked {
                    background-color: %s;
                    border-color: %s;
                }
                .singularity checkbutton check:checked,
                .singularity-app checkbutton check:checked,
                .singularity radiobutton radio:checked,
                .singularity-app radiobutton radio:checked {
                    background-color: %s;
                    border-color: %s;
                }

                .toggle-tile.active { background-color: %s; }

                .sidebar-row:selected { background-color: %s; }

                .quick-setting-tile.active {
                    background-color: %s;
                    color: white;
                }
                .quick-setting-tile.active:hover { background-color: %s; }
                .quick-setting-tile.active:focus { background-color: %s; }
                .quick-setting-tile.active~.quick-setting-nav-btn {
                    background-color: %s;
                    color: white;
                }
                .quick-setting-tile.active~.quick-setting-nav-btn:hover { background-color: %s; }

                .workspace-preview.active .workspace-clipper {
                    border-color: %s;
                    box-shadow: 0 0 0 1px %s, 0 8px 32px rgba(0, 0, 0, 0.4);
                }
                .workspace-preview.selected .workspace-clipper {
                    border-color: %s;
                    border-width: 2px;
                    box-shadow: 0 0 0 1px %s, 0 0 15px %s, 0 8px 32px rgba(0, 0, 0, 0.6);
                }
            """).printf(
                hex_color,
                alpha10, alpha15, alpha20, alpha50,
                hover_rgba, tint8, toolbar_rgba,
                /* switch */ hex_color, hex_color, hex_color,
                hex_color, hex_color,
                /* scale */ hex_color, hex_color, hex_color, hex_color,
                /* progressbar */ hex_color, hex_color,
                /* button */ hex_color, hover_hex, active_hex, hex_color, hover_hex,
                /* check/radio */ hex_color, hex_color, hex_color, hex_color,
                /* toggle-tile */ hex_color,
                /* sidebar-row */ hex_color,
                /* quick-setting-tile */ hex_color, hover_hex, hex_color, hex_color, hover_hex,
                /* workspace active */ alpha40, alpha20,
                /* workspace selected */ hex_color, hex_color, alpha40
            );

            // Extra rules via token substitution - avoids %s counting errors.
            // Tokens: {HEX} {HOVER} {ACTIVE} {A10} {A15} {A20} {A25} {A28} {A35} {A40} {A80} {A85}
            css += """
                .activities-button:active,
                .clock-button:active,
                .system-pill-button:active { background-color: {HEX}; color: white; }
                .notification-button:active { background-color: {HEX}; color: white; }

                .workspace-button { color: {HEX}; }
                .workspace-button:hover { background-color: {A20}; }

                .calendar-day-btn.today { background-color: {HEX}; color: white; }
                .event-dot { background-color: {HEX}; }
                .notification-group-badge { background-color: {HEX}; }

                .audio-device-chip.active { background-color: {HEX}; color: white; }

                .search-result-row:active   { background-color: {HEX}; }
                .search-result-row:selected { background-color: {HEX}; }

                .app-switcher-item.selected { background-color: {A28}; }

                .quick-setting-tile.state-partial       { background-color: {A25}; }
                .quick-setting-tile.state-partial:hover { background-color: {A35}; }
                .quick-setting-group .quick-setting-tile.state-partial { background-color: {A25}; }
                .quick-setting-group .quick-setting-tile.state-partial~.quick-setting-nav-btn { background-color: {A15}; }

                .media-player-card .accent-button       { background-color: {HEX}; color: white; }
                .media-player-card .accent-button:hover { background-color: {A80}; }

                .osd-pill progressbar progress { background-color: {HEX}; }

                .singularity button:active     { background-color: {HEX}; }
                .singularity-app button:active { background-color: {HEX}; }

                .greeter-password-entry:focus { border-color: {A80}; box-shadow: 0 0 0 2px {A28}; }
                .greeter-session-pill:active  { background: {HEX}; border-color: {HEX}; }

                .singularity .wallpaper-item:checked     { background-color: {HEX}; border-color: {HEX}; }
                .singularity-app .wallpaper-item:checked { background-color: {HEX}; border-color: {HEX}; }

                togglebutton.close-button:checked { background: {HEX}; }

                .boxed-list > row:selected { background-color: {A20}; }
                listbox row:selected       { background-color: {A20}; }
                columnview row:selected    { background-color: {A20}; }

                scrollbar slider:active { background-color: {HEX}; }

                spinbutton:focus-within                   { border-color: {HEX}; }
                .singularity spinbutton button:active     { background-color: {HEX}; }
                .singularity-app spinbutton button:active { background-color: {HEX}; }

                .singularity entry selection     { background-color: {HEX}; }
                .singularity-app entry selection { background-color: {HEX}; }

                .view:selected, iconview:selected { background-color: {HEX}; }

                .browser-progress > trough > progress { background-color: {HEX}; }

                /* Dock accent tint - 4% accent blended into dark base */
                .dock-box {
                    background-color: {DOCK_BG};
                }
                window.singularity-blur .dock-box,
                .singularity-blur .dock-box,
                window.singularity-blur .dock-window:backdrop .dock-box,
                .singularity-blur .dock-window:backdrop .dock-box {
                    background-color: {DOCK_BG_BLUR};
                }
            """
            .replace("{HEX}",          hex_color)
            .replace("{HOVER}",         hover_hex)
            .replace("{ACTIVE}",        active_hex)
            .replace("{A10}",           alpha10)
            .replace("{A15}",           alpha15)
            .replace("{A20}",           alpha20)
            .replace("{A25}",           alpha25)
            .replace("{A28}",           alpha28)
            .replace("{A35}",           alpha35)
            .replace("{A40}",           alpha40)
            .replace("{A80}",           alpha80)
            .replace("{A85}",           alpha85)
            .replace("{DOCK_BG}",       dock_bg)
            .replace("{DOCK_BG_BLUR}",  dock_bg_blur);
            var display = Gdk.Display.get_default();
            if (display != null) {
                StyleContext.remove_provider_for_display(display, provider);
            }
            try {
                provider.load_from_string(css);
            } catch (Error e) {
                warning("StyleManager: failed to apply accent color: %s", e.message);
            }
            if (display != null) {
                StyleContext.add_provider_for_display(
                    display, provider,
                    Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1
                );
            }
            // Propagate accent to GTK4/3 config files so installed GTK themes
            // (e.g. Kids) can use @accent_color without hardcoding a value.
            _write_gtk_accent(hex_color);
        }

        // Parse a single hex nibble character to its integer value (0-15).
        private static uint8 _nibble(char c) {
            if (c >= '0' && c <= '9') return (uint8)(c - '0');
            if (c >= 'a' && c <= 'f') return (uint8)(c - 'a' + 10);
            if (c >= 'A' && c <= 'F') return (uint8)(c - 'A' + 10);
            return 0;
        }

        // Parse "#rrggbb" hex string into r, g, b components.
        private static void _parse_hex(string c, out uint8 r, out uint8 g, out uint8 b) {
            r = (uint8)(_nibble(c[1]) * 16 + _nibble(c[2]));
            g = (uint8)(_nibble(c[3]) * 16 + _nibble(c[4]));
            b = (uint8)(_nibble(c[5]) * 16 + _nibble(c[6]));
        }

        // Mix two #rrggbb hex colors. factor=0.0, c1, factor=1.0, c2.
        private string _mix_hex(string c1, string c2, double factor) {
            uint8 r1, g1, b1, r2, g2, b2;
            _parse_hex(c1, out r1, out g1, out b1);
            _parse_hex(c2, out r2, out g2, out b2);
            uint8 r = (uint8)((1.0 - factor) * r1 + factor * r2 + 0.5);
            uint8 g = (uint8)((1.0 - factor) * g1 + factor * g2 + 0.5);
            uint8 b = (uint8)((1.0 - factor) * b1 + factor * b2 + 0.5);
            return "#%02x%02x%02x".printf(r, g, b);
        }

        // Mix two #rrggbb hex colors and return an rgba() CSS string with the
        // given alpha - avoids GTK CSS alpha(#hex, factor) parsing issues.
        private string _mix_rgba(string c1, string c2, double factor, double alpha) {
            uint8 r1, g1, b1, r2, g2, b2;
            _parse_hex(c1, out r1, out g1, out b1);
            _parse_hex(c2, out r2, out g2, out b2);
            uint8 r = (uint8)((1.0 - factor) * r1 + factor * r2 + 0.5);
            uint8 g = (uint8)((1.0 - factor) * g1 + factor * g2 + 0.5);
            uint8 b = (uint8)((1.0 - factor) * b1 + factor * b2 + 0.5);
            return "rgba(%u, %u, %u, %.2f)".printf(r, g, b, alpha);
        }

        // Writes @define-color accent_color to ~/.config/gtk-{3,4}.0/gtk.css
        // so GTK3/4 apps using themes that reference @accent_color pick up the
        // Singularity accent setting.
        private void _write_gtk_accent(string hex_color) {
            // Sentinel markers for reliable block replacement.
            const string START_SENTINEL = "/* Singularity accent";
            const string END_SENTINEL   = "/* end Singularity accent */";
            foreach (string ver in new string[]{"gtk-4.0", "gtk-3.0"}) {
                // GTK3 needs extra legacy color aliases.
                string extra = (ver == "gtk-3.0")
                    ? ("@define-color theme_selected_bg_color @accent_color;\n"
                       + "@define-color theme_selected_fg_color white;\n"
                       + "@define-color link_color @accent_color;\n")
                    : "";
                string block = ("/* Singularity accent - auto-generated, do not edit */\n"
                    + "@define-color accent_color %s;\n"
                    + "@define-color accent_bg_color @accent_color;\n"
                    + "@define-color accent_fg_color white;\n"
                    + extra
                    + "/* end Singularity accent */\n").printf(hex_color);
                string dir = GLib.Path.build_filename(
                    GLib.Environment.get_home_dir(), ".config", ver);
                try {
                    GLib.DirUtils.create_with_parents(dir, 0755);
                } catch (Error e) {
                    warning("StyleManager: could not create config dir %s: %s", dir, e.message);
                }
                string path = GLib.Path.build_filename(dir, "gtk.css");
                string existing = "";
                // File may not exist on first run — that is expected, start with empty string.
                try { GLib.FileUtils.get_contents(path, out existing); } catch (Error e) {
                    if (!(e is GLib.FileError.NOENT)) warning("StyleManager: could not read %s: %s", path, e.message);
                }
                // Strip any previous auto-generated block.
                int block_start = existing.index_of(START_SENTINEL);
                if (block_start >= 0) {
                    int end_pos = existing.index_of(END_SENTINEL, block_start);
                    int block_end;
                    if (end_pos >= 0) {
                        block_end = end_pos + END_SENTINEL.length;
                        if (block_end < existing.length && existing[block_end] == '\n')
                            block_end++;
                    } else {
                        // Old format: skip 4 newlines then eat any orphaned @define-color accent* lines.
                        block_end = block_start;
                        for (int i = 0; i < 4; i++) {
                            int nl = existing.index_of("\n", block_end);
                            if (nl < 0) { block_end = existing.length; break; }
                            block_end = nl + 1;
                        }
                        while (block_end < existing.length
                               && existing.substring(block_end).has_prefix("@define-color accent")) {
                            int nl = existing.index_of("\n", block_end);
                            if (nl < 0) { block_end = existing.length; break; }
                            block_end = nl + 1;
                        }
                    }
                    existing = existing.substring(0, block_start) + existing.substring(block_end);
                }
                try {
                    GLib.FileUtils.set_contents(path, block + existing);
                } catch (Error e) {
                    warning("StyleManager: failed to write GTK accent for %s: %s", ver, e.message);
                }
            }
        }

        /**
         * Samples the dominant colour from an image file.
         *
         * The image is scaled to 1×1 pixel and the resulting colour is
         * returned as a CSS hex string. Falls back to `"#3584e4"` on error.
         *
         * @param path Filesystem path to the image.
         * @return Hex colour string, e.g. `"#1a2b3c"`.
         */
        public string extract_primary_color(string path) {
            try {
                // Sample at 32×32: enough to find dominant colors without being slow.
                var pixbuf = new Gdk.Pixbuf.from_file_at_scale(path, 32, 32, false);
                unowned uint8[] pixels = pixbuf.get_pixels();
                int nc    = pixbuf.get_n_channels();
                int rs    = pixbuf.get_rowstride();
                int w     = pixbuf.get_width();
                int h     = pixbuf.get_height();

                // Find the most vibrant pixel: score = saturation × value.
                // Skip pixels that are too dark (val < 0.15) or too washed-out
                // (val > 0.95 or sat < 0.15) because they make poor accent colors.
                double best_score = -1;
                uint8 best_r = 53, best_g = 132, best_b = 228; // GNOME blue fallback

                for (int y = 0; y < h; y++) {
                    for (int x = 0; x < w; x++) {
                        int idx = y * rs + x * nc;
                        double r = pixels[idx]     / 255.0;
                        double g = pixels[idx + 1] / 255.0;
                        double b = pixels[idx + 2] / 255.0;

                        double vmax = double.max(r, double.max(g, b));
                        double vmin = double.min(r, double.min(g, b));
                        double val  = vmax;
                        double sat  = (vmax > 0.0) ? (vmax - vmin) / vmax : 0.0;

                        if (val < 0.15 || val > 0.95 || sat < 0.15) continue;

                        double score = sat * val;
                        if (score > best_score) {
                            best_score = score;
                            best_r = pixels[idx];
                            best_g = pixels[idx + 1];
                            best_b = pixels[idx + 2];
                        }
                    }
                }

                if (best_score >= 0) {
                    return "#%02x%02x%02x".printf(best_r, best_g, best_b);
                }

                // All pixels are very muted/dark - return a neutral accent.
                return "#555555";
            } catch (GLib.Error e) {
                warning("StyleManager: color extraction failed: %s", e.message);
            }
            return "#3584e4";
        }

        private CssProvider? base_theme_provider;
        private CssProvider? user_theme_provider;
        private CssProvider? user_theme_variant_provider;
        private string current_user_theme = "";
        private bool current_dark_mode = true;

        /**
         * Switches between dark and light color scheme.
         *
         * Reloads the combined color-vars + structural CSS with the
         * appropriate color variable file.
         *
         * @param dark `true` for dark, `false` for light.
         */
        public void apply_color_scheme(bool dark) {
            _load_combined_css(dark);
            current_dark_mode = dark;
            _load_user_theme_variant(dark);
        }

        private CssProvider? high_contrast_provider;
        private CssProvider? large_text_provider;

        /**
         * Enables or disables the high-contrast CSS overlay.
         *
         * @param enabled `true` to apply high-contrast styles.
         */
        public void set_high_contrast(bool enabled) {
            if (enabled) {
                if (high_contrast_provider == null) {
                    high_contrast_provider = new CssProvider();
                    try {
                        high_contrast_provider.load_from_resource(
                            "/dev/sinty/libsingularity/high-contrast.css"
                        );
                        StyleContext.add_provider_for_display(
                            Gdk.Display.get_default(),
                            high_contrast_provider,
                            Gtk.STYLE_PROVIDER_PRIORITY_USER
                        );
                    } catch (Error e) {
                        warning("StyleManager: failed to load high-contrast theme: %s", e.message);
                        high_contrast_provider = null;
                    }
                }
            } else {
                if (high_contrast_provider != null) {
                    StyleContext.remove_provider_for_display(
                        Gdk.Display.get_default(),
                        high_contrast_provider
                    );
                    high_contrast_provider = null;
                }
            }
        }

        /**
         * Switches between default and large-text font sizes.
         *
         * Uses the Inter typeface at 10 pt (default) or 14 pt (large text),
         * which are the standard Singularity design-system sizes.
         *
         * @param enabled `true` to enable large text.
         */
        public void set_large_text(bool enabled) {
            var settings = Gtk.Settings.get_default();
            if (enabled) {
                settings.gtk_font_name = "Inter 14";
            } else {
                settings.gtk_font_name = "Inter 10";
            }
        }

        /**
         * Loads a user-provided Singularity theme by name.
         *
         * Searches standard theme directories for a directory named
         * `theme_name` containing `singularity/style.css`.  The CSS is loaded
         * at priority 605 (above the built-in base at 600).  If the theme also
         * provides `singularity/style-light.css` it will be swapped in/out when
         * apply_color_scheme is called.
         *
         * Pass an empty string to unload any previously loaded user theme and
         * revert to the built-in default look.
         *
         * @param theme_name Theme directory name, e.g. `"MyTheme"`.
         */
        public void load_user_theme(string theme_name) {
            // Unload current user theme providers.
            if (user_theme_provider != null) {
                StyleContext.remove_provider_for_display(
                    Gdk.Display.get_default(), user_theme_provider);
                user_theme_provider = null;
            }
            if (user_theme_variant_provider != null) {
                StyleContext.remove_provider_for_display(
                    Gdk.Display.get_default(), user_theme_variant_provider);
                user_theme_variant_provider = null;
            }
            current_user_theme = theme_name;
            if (theme_name == "") return;

            string? theme_dir = find_theme_dir(theme_name);
            if (theme_dir == null) {
                warning("StyleManager: user theme '%s' not found in theme dirs", theme_name);
                return;
            }
            string css_path = GLib.Path.build_filename(theme_dir, "singularity", "style.css");
            if (!GLib.FileUtils.test(css_path, GLib.FileTest.EXISTS)) {
                warning("StyleManager: user theme '%s' has no singularity/style.css", theme_name);
                return;
            }
            user_theme_provider = new CssProvider();
            try {
                user_theme_provider.load_from_path(css_path);
                StyleContext.add_provider_for_display(
                    Gdk.Display.get_default(),
                    user_theme_provider,
                    Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 5
                );
            } catch (Error e) {
                warning("StyleManager: failed to load user theme '%s': %s", theme_name, e.message);
                user_theme_provider = null;
                return;
            }
            // Load the correct variant for the current dark/light mode.
            _load_user_theme_variant(current_dark_mode);
        }

        // Called by apply_color_scheme to swap the user-theme variant.
        private void _load_user_theme_variant(bool dark) {
            current_dark_mode = dark;
            if (user_theme_variant_provider != null) {
                StyleContext.remove_provider_for_display(
                    Gdk.Display.get_default(), user_theme_variant_provider);
                user_theme_variant_provider = null;
            }
            if (current_user_theme == "") return;
            string? theme_dir = find_theme_dir(current_user_theme);
            if (theme_dir == null) return;
            string variant = dark ? "style-dark.css" : "style-light.css";
            string variant_path = GLib.Path.build_filename(theme_dir, "singularity", variant);
            if (!GLib.FileUtils.test(variant_path, GLib.FileTest.EXISTS)) return;
            user_theme_variant_provider = new CssProvider();
            try {
                user_theme_variant_provider.load_from_path(variant_path);
                StyleContext.add_provider_for_display(
                    Gdk.Display.get_default(),
                    user_theme_variant_provider,
                    Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 6
                );
            } catch (Error e) {
                warning("StyleManager: failed to load user theme variant: %s", e.message);
                user_theme_variant_provider = null;
            }
        }

        /**
         * Returns the filesystem path of a named theme directory, or `null`.
         *
         * Searches (in order): `~/.local/share/themes`, `~/.themes`,
         * `/usr/local/share/themes`, `/usr/share/themes`.
         */
        public static string? find_theme_dir(string theme_name) {
            string[] dirs = {
                GLib.Path.build_filename(GLib.Environment.get_home_dir(), ".local", "share", "themes"),
                GLib.Path.build_filename(GLib.Environment.get_home_dir(), ".themes"),
                "/usr/local/share/themes",
                "/usr/share/themes"
            };
            foreach (string dir in dirs) {
                string candidate = GLib.Path.build_filename(dir, theme_name);
                string css = GLib.Path.build_filename(candidate, "singularity", "style.css");
                if (GLib.FileUtils.test(css, GLib.FileTest.EXISTS))
                    return candidate;
            }
            return null;
        }

        /**
         * Returns the names of all installed Singularity themes (those that
         * contain a `singularity/style.css` file inside a standard theme dir).
         */
        public static string[] list_singularity_themes() {
            var themes = new Gee.ArrayList<string>();
            string[] dirs = {
                "/usr/share/themes",
                "/usr/local/share/themes",
                GLib.Path.build_filename(GLib.Environment.get_home_dir(), ".local", "share", "themes"),
                GLib.Path.build_filename(GLib.Environment.get_home_dir(), ".themes")
            };
            foreach (string dir in dirs) {
                try {
                    var d = GLib.Dir.open(dir);
                    string? name;
                    while ((name = d.read_name()) != null) {
                        if (name.has_prefix(".") || name == "Singularity") continue;
                        string css = GLib.Path.build_filename(dir, name, "singularity", "style.css");
                        if (GLib.FileUtils.test(css, GLib.FileTest.EXISTS) && !themes.contains(name))
                            themes.add(name);
                    }
                } catch (Error e) {}
            }
            themes.sort((a, b) => GLib.strcmp(a, b));
            return themes.to_array();
        }
    }
}
