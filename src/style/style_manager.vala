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
         * GTK theme name pinned for all first-party Singularity surfaces. It is
         * an empty CSS theme so the theme layer contributes nothing and styling
         * comes solely from libsingularity's style.css (PRIORITY_USER). This is
         * deliberately NOT the full "Singularity" theme, which is for
         * third-party GTK apps; our surfaces must never inherit that base.
         */
        public const string BRAND_GTK_THEME = "SingularityShell";
        /**
         * Icon theme name pinned for all Singularity surfaces. It is an empty
         * theme that inherits Adwaita, so every icon (including symbolic ones)
         * resolves through Adwaita under our brand name.
         */
        public const string BRAND_ICON_THEME = "Singularity";

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
         * Pins the GTK and icon themes to the Singularity brand themes and keeps
         * them pinned via notify guards.
         *
         * The pinned "SingularityShell" GTK theme ships empty CSS so GTK loads
         * nothing from the theme layer, letting our embedded style.css win. (The
         * full "Singularity" GTK theme, built from our tokens, is for third-party
         * apps only.) The "Singularity" icon theme is an empty seam inheriting
         * Adwaita. The notify guards stop the
         * Settings portal (the default settings source on Wayland) from resetting
         * either to hicolor/default, which would drop symbolic icons for coloured
         * fallbacks. Call this once, after Gtk has been initialised (e.g. from an
         * application's startup), for both apps and shells.
         */
        private static string _desired_icon_theme = BRAND_ICON_THEME;
        private static bool _icon_theme_pinned = false;

        private const string[] ACCENT_NAMES = {
            "blue", "teal", "green", "yellow", "orange", "red", "pink", "purple", "slate"
        };
        private const string[] ACCENT_HEXES = {
            "#3584e4", "#2190a4", "#3a944a", "#e5a50a", "#e66100", "#e01b24", "#d56199", "#9141ac", "#787878"
        };

        public static void pin_brand_themes() {
            typeof(StyleManager).class_ref();
            var gs = Gtk.Settings.get_default();
            if (gs == null) return;
            gs.gtk_theme_name = BRAND_GTK_THEME;
            gs.notify["gtk-theme-name"].connect(() => {
                if (gs.gtk_theme_name != BRAND_GTK_THEME) {
                    gs.gtk_theme_name = BRAND_GTK_THEME;
                }
            });

            // The icon theme follows the user's chosen pack (dev.sinty.desktop
            // icon-theme), defaulting to the brand seam. The notify guard only
            // blocks the Settings portal from resetting to hicolor; it re-pins to
            // the desired pack, not a hardcoded brand, so picking another pack
            // applies to Singularity apps too.
            var src = GLib.SettingsSchemaSource.get_default();
            if (src != null && src.lookup("dev.sinty.desktop", true) != null) {
                var ds = new GLib.Settings("dev.sinty.desktop");
                string it = ds.get_string("icon-theme");
                if (it != "") _desired_icon_theme = it;
                ds.changed["icon-theme"].connect(() => {
                    string n = ds.get_string("icon-theme");
                    _desired_icon_theme = (n != "") ? n : BRAND_ICON_THEME;
                    refresh_icon_theme();
                });
            }
            _icon_theme_pinned = true;
            refresh_icon_theme();
            gs.notify["gtk-icon-theme-name"].connect(() => refresh_icon_theme());
        }

        /**
         * Maps the brand icon pack to its installed accent variant (for example
         * Singularity-teal); any other pack is returned unchanged.
         */
        public static string resolve_icon_theme(string theme) {
            if (theme != BRAND_ICON_THEME) return theme;
            var sm = get_default();
            if (!(sm.current_accent in ACCENT_NAMES)) {
                string? custom = AccentIcons.ensure(theme, sm.accent_hex);
                if (custom != null && icon_theme_installed(custom)) return custom;
            }
            string accent = sm.current_accent in ACCENT_NAMES
                ? sm.current_accent : nearest_accent_name(sm.accent_hex);
            string variant = "%s-%s".printf(BRAND_ICON_THEME, accent);
            return icon_theme_installed(variant) ? variant : theme;
        }

        private static void refresh_icon_theme() {
            if (!_icon_theme_pinned) return;
            var gs = Gtk.Settings.get_default();
            if (gs == null) return;
            string name = resolve_icon_theme(_desired_icon_theme);
            if (gs.gtk_icon_theme_name != name) gs.gtk_icon_theme_name = name;
        }

        private static bool icon_theme_installed(string name) {
            var display = Gdk.Display.get_default();
            if (display == null) return false;
            string[]? dirs = Gtk.IconTheme.get_for_display(display).get_search_path();
            if (dirs == null) return false;
            foreach (unowned string dir in dirs) {
                if (FileUtils.test(Path.build_filename(dir, name, "index.theme"), FileTest.EXISTS))
                    return true;
            }
            return false;
        }

        private static string nearest_accent_name(string hex) {
            uint8 r, g, b;
            _parse_hex(hex, out r, out g, out b);
            float h, s, v;
            Gtk.rgb_to_hsv(r / 255.0f, g / 255.0f, b / 255.0f, out h, out s, out v);
            if (s < 0.2 || v < 0.15) return "slate";
            string best = "blue";
            float best_d = 2.0f;
            for (int i = 0; i < ACCENT_NAMES.length - 1; i++) {
                uint8 cr, cg, cb;
                _parse_hex(ACCENT_HEXES[i], out cr, out cg, out cb);
                float ch, cs, cv;
                Gtk.rgb_to_hsv(cr / 255.0f, cg / 255.0f, cb / 255.0f, out ch, out cs, out cv);
                float d = (h - ch).abs();
                if (d > 0.5f) d = 1.0f - d;
                if (d < best_d) {
                    best_d = d;
                    best = ACCENT_NAMES[i];
                }
            }
            return best;
        }

        /**
         * Loads the structural theme CSS into the default display.
         *
         * Also loads dark color variables by default. Call
         * apply_color_scheme() afterwards to switch to light.
         */
        public void load_theme() {
            install_bubble_buttons();
            Singularity.Motion.get_default().install_css();
            Singularity.Animation.WidgetMotion.install();
            if (accent_provider != null) return;
            apply_accent_color("blue");
            setup_material_style();
            setup_density_style();
        }

        private const string BUBBLE_BUTTON_CLASS = "singularity-bubble-button";

        private const string[] NEUTRAL_BUTTON_CLASSES = {
            "text-button", "image-button", "image-text-button", "flat", "pill", "circular",
            "suggested-action", "destructive-action", "toggle", "popup", "arrow-button",
            "keyboard-activating", BUBBLE_BUTTON_CLASS
        };

        private const string[] ROLE_CONTAINER_CLASSES = {
            "singularity-hover-btn", "singularity-toolbar", "segmented-control", "chip",
            "chip-bar", "tab-bar", "context-menu", "osk", "image-viewer-bar",
            "singularity-step-island", "media-player-card", "cal-nav-picker"
        };

        private static bool bubble_buttons_installed = false;

        private static void install_bubble_buttons() {
            if (bubble_buttons_installed) return;
            bubble_buttons_installed = true;
            typeof(Gtk.Button).class_ref();
            uint map_signal = Signal.lookup("map", typeof(Gtk.Widget));
            Signal.add_emission_hook(map_signal, 0, (hint, values) => {
                var button = values[0].get_object() as Gtk.Button;
                if (button != null) track_button(button);
                return true;
            });
        }

        private static void track_button(Gtk.Button button) {
            if (!button.get_data<bool>("singularity-bubble-tracked")) {
                button.set_data<bool>("singularity-bubble-tracked", true);
                button.notify["css-classes"].connect((obj, pspec) => classify_button((Gtk.Button) obj));
            }
            classify_button(button);
        }

        private static void classify_button(Gtk.Button button) {
            bool bubble = is_plain_button(button);
            if (bubble == button.has_css_class(BUBBLE_BUTTON_CLASS)) return;
            if (bubble) button.add_css_class(BUBBLE_BUTTON_CLASS);
            else button.remove_css_class(BUBBLE_BUTTON_CLASS);
        }

        private static bool has_only_neutral_classes(Gtk.Widget widget) {
            foreach (unowned string name in widget.get_css_classes()) {
                if (!(name in NEUTRAL_BUTTON_CLASSES)) return false;
            }
            return true;
        }

        private static bool is_plain_button(Gtk.Button button) {
            if (!has_only_neutral_classes(button)) return false;
            for (var parent = button.get_parent(); parent != null; parent = parent.get_parent()) {
                if (parent is Gtk.MenuButton || parent is Gtk.DropDown) {
                    if (!has_only_neutral_classes(parent)) return false;
                    continue;
                }
                if (parent is Gtk.Button || parent is Gtk.SpinButton || parent is Gtk.WindowControls
                        || parent is Gtk.HeaderBar || parent is Gtk.StackSwitcher || parent is Gtk.ScaleButton
                        || parent is Gtk.Calendar || parent is Gtk.ColorDialogButton
                        || parent is Gtk.FontDialogButton) {
                    return false;
                }
                foreach (unowned string name in ROLE_CONTAINER_CLASSES) {
                    if (parent.has_css_class(name)) return false;
                }
                if (parent.has_css_class("navigation-sidebar") && button.has_css_class("flat")) return false;
            }
            return true;
        }

        private GLib.Settings? density_settings = null;
        private CssProvider? density_provider = null;

        private const string DENSITY_MEDIUM = """
            .singularity .preferences-row { min-height: 44px; }
            .singularity .preferences-row .row-content { padding: 8px 14px; }
            .singularity .preferences-row .title { font-size: 14px; }
            .singularity .preferences-row .subtitle { font-size: 12px; }
            .singularity .preferences-row .row-icon { -gtk-icon-size: 20px; margin-right: 12px; }
            .singularity .preferences-group { margin-bottom: 16px; }
            .singularity .preferences-group .heading { font-size: 15px; }
            .singularity .preferences-group .group-description { font-size: 12px; }
            .singularity .preferences-group .group-header { padding: 10px 14px 4px; }
            .preferences-page-margins { margin: 24px 40px; }
            .singularity .preferences-row switch { min-width: 44px; min-height: 24px; }
            .singularity .preferences-row switch slider { min-width: 20px; min-height: 20px; }
            .singularity .preferences-row button { min-height: 28px; }
            .singularity .preferences-row button.image-button,
            .singularity .preferences-row button.circular-button { min-width: 28px; min-height: 28px; }
            .welcome-card-content { padding: 14px 16px; }
                    .singularity-sidebar-row { padding: 6px 12px; min-height: 28px; }
            .singularity-sidebar-row > box > image { -gtk-icon-size: 20px; }
            .sidebar-section-label label { font-size: 12px; }
            .singularity popover.context-menu .menu-row { min-height: 28px; padding: 2px 10px; }
            .singularity popover.context-menu .menu-row label { font-size: 14px; }
            .bubble-switcher button.bubble-switcher-item { min-height: 28px; padding: 3px 14px; }
            .segmented-inner, .segmented-button { min-height: 26px; }
            .singularity entry.search { padding: 5px 12px; min-height: 26px; }
            .singularity-toast { padding: 6px 6px 6px 16px; }
            .singularity-toast label { font-size: 14px; }
            .singularity .singularity-toast button { min-height: 26px; }
            .status-page .status-page-icon { -gtk-icon-size: 80px; }
            .status-page:not(.compact) .status-page-title { font-size: 24px; }
            .dialog-card button.pill { min-height: 26px; padding: 5px 18px; }
""";

        private const string DENSITY_LARGE = """
            .singularity .preferences-row { min-height: 52px; }
            .singularity .preferences-row .row-content { padding: 10px 16px; }
            .singularity .preferences-row .title { font-size: 15px; }
            .singularity .preferences-row .subtitle { font-size: 13px; }
            .singularity .preferences-row .row-icon { -gtk-icon-size: 24px; margin-right: 12px; }
            .singularity .preferences-group { margin-bottom: 20px; }
            .singularity .preferences-group .heading { font-size: 17px; }
            .singularity .preferences-group .group-description { font-size: 13px; }
            .singularity .preferences-group .group-header { padding: 12px 16px 6px; }
            .preferences-page-margins { margin: 28px 48px; }
            .singularity .preferences-row switch { min-width: 48px; min-height: 26px; }
            .singularity .preferences-row switch slider { min-width: 22px; min-height: 22px; }
            .singularity .preferences-row button { min-height: 32px; }
            .singularity .preferences-row button.image-button,
            .singularity .preferences-row button.circular-button { min-width: 32px; min-height: 32px; }
            .welcome-card-content { padding: 16px 18px; }
                    .singularity-sidebar-row { padding: 8px 14px; min-height: 32px; }
            .singularity-sidebar-row > box > image { -gtk-icon-size: 24px; }
            .sidebar-section-label label { font-size: 13px; }
            .singularity popover.context-menu .menu-row { min-height: 34px; padding: 3px 12px; }
            .singularity popover.context-menu .menu-row label { font-size: 15px; }
            .bubble-switcher button.bubble-switcher-item { min-height: 34px; padding: 4px 16px; }
            .segmented-inner, .segmented-button { min-height: 32px; }
            .singularity entry.search { padding: 6px 14px; min-height: 30px; }
            .singularity-toast { padding: 8px 8px 8px 18px; }
            .singularity-toast label { font-size: 15px; }
            .singularity .singularity-toast button { min-height: 32px; }
            .status-page .status-page-icon { -gtk-icon-size: 96px; }
            .status-page:not(.compact) .status-page-title { font-size: 28px; }
            .dialog-card button.pill { min-height: 32px; padding: 6px 20px; }
""";

        private void setup_density_style() {
            density_settings = Singularity.Core.safe_settings(
                Singularity.Runtime.desktop_settings_schema);
            if (density_settings != null
                    && density_settings.settings_schema.has_key("interface-density")) {
                density_settings.changed["interface-density"].connect(update_density_style);
            }
            update_density_style();
        }

        private void update_density_style() {
            string density = "compact";
            if (density_settings != null
                    && density_settings.settings_schema.has_key("interface-density")) {
                density = density_settings.get_string("interface-density");
            }
            string css = density == "large" ? DENSITY_LARGE : density == "medium" ? DENSITY_MEDIUM : "";
            if (density_provider == null) {
                density_provider = new CssProvider();
                var display = Gdk.Display.get_default();
                if (display != null) {
                    StyleContext.add_provider_for_display(display, density_provider,
                        Gtk.STYLE_PROVIDER_PRIORITY_USER + 2);
                }
            }
            density_provider.load_from_string(css);
        }

        private void setup_material_style() {
            material_settings = Singularity.Core.safe_settings(
                Singularity.Runtime.desktop_settings_schema);
            if (material_settings != null
                    && material_settings.settings_schema.has_key("window-transparency")) {
                material_settings.changed["window-transparency"].connect(
                    update_material_style);
            }
            update_material_style();
        }

        private void update_material_style() {
            int transparency = 12;
            if (material_settings != null
                    && material_settings.settings_schema.has_key("window-transparency")) {
                transparency = material_settings.get_int("window-transparency").clamp(0, 90);
            }
            int opacity = 100 - transparency;
            string base_bg = current_dark_mode ? "#242424" : "#f6f5f4";
            uint8 red, green, blue;
            _parse_hex(base_bg, out red, out green, out blue);
            string background = "rgba(%u, %u, %u, %d.%02d)".printf(
                red, green, blue, opacity / 100, opacity % 100);
            string css = """
                .singularity-blur .singularity-app-frame,
                .singularity-glass .singularity-app-frame {
                    background-color: %s;
                }
            """.printf(background);

            if (material_provider == null) {
                material_provider = new CssProvider();
                var display = Gdk.Display.get_default();
                if (display != null) {
                    StyleContext.add_provider_for_display(display, material_provider,
                        Gtk.STYLE_PROVIDER_PRIORITY_USER + 1);
                }
            }
            try {
                material_provider.load_from_string(css);
            } catch (Error e) {
                warning("StyleManager: failed to apply material style: %s", e.message);
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
        public void apply_accent_color(string color_name, string? wallpaper_path = null) {
            string accent = color_name;
            string? wall = wallpaper_path;
            string hex_color = "#3584e4";
            current_accent = accent;
            current_accent_wallpaper = wall;
            if (accent.has_prefix("#") && accent.length >= 7) {
                hex_color = accent;
            } else if (accent == "wallpaper" && wall != null) {
                hex_color = extract_primary_color(wall);
            } else {
                for (int i = 0; i < ACCENT_NAMES.length; i++) {
                    if (ACCENT_NAMES[i] == accent) hex_color = ACCENT_HEXES[i];
                }
            }
            // Expose the resolved accent hex so callers (e.g. the shell's labwc
            // theming) can derive their own accent-tinted colours.
            accent_hex = hex_color;
            accent_fg_hex = contrast_fg_for(hex_color);
            refresh_icon_theme();
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
            string toolbar_tinted = _mix_hex(toolbar_base, hex_color, 0.05);
            string toolbar_hex = _mix_hex(base_bg, toolbar_tinted, toolbar_alpha);
            // Pre-compute hover/active variants for button rules.
            string hover_hex  = _mix_hex(hex_color, "#ffffff", 0.15);
            string active_hex = _mix_hex(hex_color, "#000000", 0.15);
            // Dock background: base + 4% accent tint (opaque + blur variant)
            string dock_bg      = _mix_rgba(dock_base, hex_color, 0.04, dock_alpha);
            string dock_bg_blur = _mix_rgba(dock_blur, hex_color, 0.04, dock_blur_alpha);
            string dock_bg_glass = _mix_rgba(dock_blur, hex_color, 0.06,
                dark ? 0.30 : 0.38);
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
                @define-color accent_color %s;
                @define-color accent_bg @accent_color;
                @define-color accent_bg_color @accent_color;
                @define-color accent_fg %s;
                @define-color accent_fg_color %s;
                @define-color window_tint %s;
                @define-color overview_bg @window_tint;
                @define-color toolbar_bg %s;
                @define-color headerbar_bg_color @toolbar_bg;

                /* Standard GTK aliases for external apps and legacy widgets */
                @define-color theme_selected_bg_color @accent_color;
                @define-color theme_selected_fg_color @accent_fg;
                @define-color selected_bg_color @accent_color;
                @define-color selected_fg_color @accent_fg;
                @define-color theme_fg_color @text_color;
                @define-color theme_text_color @text_color;
                @define-color theme_bg_color @window_bg;
                @define-color theme_base_color @window_bg;

                /* Ensure selection and focus states use the accent */
                selection { background-color: @accent_color; color: @accent_fg; }
                :selected { background-color: @accent_color; color: @accent_fg; }
                :focus { border-color: @accent_color; }

                /* Explicit rules for OSD and level indicators */
                .osd-pill {
                    background-color: @surface_overlay;
                    border: 1px solid alpha(@text_color, 0.12);
                    border-radius: 999px;
                    padding: 8px 16px;
                    box-shadow: 0 4px 12px alpha(@shadow_color, 0.3);
                    min-width: 200px;
                }
                .singularity-blur .osd-pill { background-color: rgba(30, 30, 30, 0.6); }

                levelbar block.filled { background-color: @accent_color; }
                progressbar trough {
                    background-color: alpha(@text_color, 0.1);
                    border-radius: 99px;
                    min-height: 6px;
                    border: none;
                }
                progressbar progress {
                    background-color: @accent_color;
                    background-image: none;
                    border-radius: 99px;
                    min-height: 6px;
                    border: none;
                }
                
                /* Global overrides for common UI elements */
                progress { 
                    background-color: @accent_color; 
                    background-image: none;
                }
                highlight { background-color: @accent_color; }
                slider { background-color: @accent_color; }

                /* Dock accent tint */
                .dock-box { background-color: %s; }
                window.singularity-blur .dock-box,
                .singularity-blur .dock-box,
                window.singularity-blur .dock-window:backdrop .dock-box,
                .singularity-blur .dock-window:backdrop .dock-box { background-color: %s; }
                window.singularity-glass .dock-box,
                .singularity-glass .dock-box,
                window.singularity-glass .dock-window:backdrop .dock-box,
                .singularity-glass .dock-window:backdrop .dock-box { background-color: %s; }

                /* Workspace previews - rgbacomputed here for box-shadow */
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
                accent_fg_hex, accent_fg_hex,
                tint8, toolbar_hex,
                dock_bg, dock_bg_blur, dock_bg_glass,
                alpha40, alpha20,
                hex_color, hex_color, alpha40
            );

            // Extra rules via token substitution, only rules that need rgba()
            // values not expressible via @define-color in style.css.
            // Tokens: {HEX} {HOVER} {ACTIVE} {A10} {A15} {A20} {A25} {A28} {A35} {A40} {A80} {A85}
            css += """
                .workspace-button { color: {HEX}; }
                .workspace-button:hover { background-color: {A20}; }

                .search-result-row:active   { background-color: {A20}; }

                .app-switcher-item.selected { background-color: {A28}; }

                .quick-setting-tile.state-partial       { background-color: {A25}; }
                .quick-setting-tile.state-partial:hover { background-color: {A35}; }
                .quick-setting-group .quick-setting-tile.state-partial { background-color: {A25}; }
                .quick-setting-group .quick-setting-tile.state-partial~.quick-setting-nav-btn { background-color: {A15}; }

                .media-player-card .accent-button:hover { background-color: {A80}; }

                .boxed-list > row:selected { background-color: {A20}; }
                columnview row:selected    { background-color: {A20}; }

                .greeter-password-entry:focus { border-color: {A80}; box-shadow: 0 0 0 2px {A28}; }
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

            // Combine base theme + accent into one string for a single parse pass.
            string color_path = current_dark_mode
                ? "/dev/sinty/libsingularity/style.dark.css"
                : "/dev/sinty/libsingularity/style.light.css";
            string combined;
            string base_css = "";
            bool lowered_buttons = GLib.Application.get_default() is Singularity.Application;
            try {
                var color_bytes = GLib.resources_lookup_data(color_path, 0);
                var struct_bytes = GLib.resources_lookup_data("/dev/sinty/libsingularity/style.css", 0);
                string defaults = (string) GLib.resources_lookup_data(
                    "/dev/sinty/libsingularity/button-defaults.css", 0).get_data();
                string singularity = (string) GLib.resources_lookup_data(
                    "/dev/sinty/libsingularity/singularity-button.css", 0).get_data();
                string structure = ((string) struct_bytes.get_data())
                    .replace("/* @button-defaults */", lowered_buttons ? "" : defaults)
                    .replace("/* @singularity-button */", lowered_buttons ? "" : singularity);
                combined = (string)color_bytes.get_data() + "\n" + structure + "\n" + css;
                if (lowered_buttons)
                    base_css = (string)color_bytes.get_data() + "\n" + css + "\n" + defaults + "\n" + singularity;
            } catch (Error e) {
                warning("StyleManager: failed to load base CSS, using accent only: %s", e.message);
                combined = css;
            }

            var display = Gdk.Display.get_default();
            if (display != null && accent_provider != null) {
                StyleContext.remove_provider_for_display(display, accent_provider);
            }
            if (display != null && base_provider != null) {
                StyleContext.remove_provider_for_display(display, base_provider);
            }
            base_provider = null;
            if (base_css != "") {
                base_provider = new CssProvider();
                base_provider.load_from_string(base_css);
                if (display != null) {
                    StyleContext.add_provider_for_display(display, base_provider,
                        Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION - 1);
                }
            }
            
            accent_provider = new CssProvider();
            try {
                // message("StyleManager: applying hex color %s", hex_color);
                accent_provider.load_from_string(combined);
            } catch (Error e) {
                warning("StyleManager: failed to apply accent color: %s", e.message);
            }

            if (display != null) {
                StyleContext.add_provider_for_display(
                    display, accent_provider,
                    Gtk.STYLE_PROVIDER_PRIORITY_USER
                );
            }
            
            // Extra switch/toggle overrides to ensure they use the accent in the shell
            // Loaded at PRIORITY_USER + 1, so these win without needing the
            // (GTK-unsupported) !important keyword.
            string switch_css = """
                /* Generic toggles */
                switch:checked { background-color: {HEX}; border-color: {HEX}; }

                /* Specific sidebar/shell toggles */
                .singularity switch:checked { background-color: {HEX}; border-color: {HEX}; }
                .navigation-sidebar switch:checked { background-color: {HEX}; }

                /* Selection in shell lists */
                .singularity listbox row:selected,
                .singularity .boxed-list > row:selected {
                    background-color: {A20};
                }
            """
            .replace("{HEX}", hex_color)
            .replace("{A20}", alpha20);
            
            var switch_provider = new CssProvider();
            switch_provider.load_from_string(switch_css);
            if (display != null) {
                StyleContext.add_provider_for_display(display, switch_provider, Gtk.STYLE_PROVIDER_PRIORITY_USER + 1);
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
            // Use fixed string for alpha to avoid locale-dependent decimal separator (comma vs dot)
            int a_int = (int)alpha;
            int a_dec = (int)((alpha - a_int) * 100);
            return "rgba(%u, %u, %u, %d.%02d)".printf(r, g, b, a_int, a_dec);
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
                       + "@define-color theme_selected_fg_color @accent_fg_color;\n"
                       + "@define-color link_color @accent_color;\n")
                    : "";
                string block = ("/* Singularity accent - auto-generated, do not edit */\n"
                    + "@define-color accent_color %s;\n"
                    + "@define-color accent_bg_color @accent_color;\n"
                    + "@define-color accent_fg_color %s;\n"
                    + extra
                    + "/* end Singularity accent */\n").printf(hex_color, contrast_fg_for(hex_color));
                string dir = GLib.Path.build_filename(
                    GLib.Environment.get_home_dir(), ".config", ver);
                try {
                    GLib.DirUtils.create_with_parents(dir, 0755);
                } catch (Error e) {
                    warning("StyleManager: could not create config dir %s: %s", dir, e.message);
                }
                string path = GLib.Path.build_filename(dir, "gtk.css");
                string existing = "";
                // File may not exist on first run - that is expected, start with empty string.
                try { GLib.FileUtils.get_contents(path, out existing); } catch (Error e) {
                    if (!(e is GLib.FileError.NOENT)) warning("StyleManager: could not read %s: %s", path, e.message);
                    existing = "";
                }
                if (existing == null) existing = "";
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
                uint8 best_r = 53, best_g = 132, best_b = 228; // default blue fallback

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

        private CssProvider? accent_provider;
        private CssProvider? base_provider;
        private CssProvider? material_provider;
        private GLib.Settings? material_settings;
        private CssProvider? user_theme_provider;
        private CssProvider? user_theme_variant_provider;
        private string current_user_theme = "";
        private bool current_dark_mode = true;
        private string current_accent = "blue";
        private string? current_accent_wallpaper = null;

        /** Whether the dark colour scheme is applied. */
        public bool dark {
            get { return current_dark_mode; }
        }

        /** The resolved accent colour as a "#rrggbb" hex string. */
        public string accent_hex { get; private set; default = "#3584e4"; }

        /**
         * Text colour used on surfaces filled with the accent, as a "#rrggbb"
         * hex string. Computed from the accent on every change, see
         * contrast_fg_for; exposed to CSS as `@accent_fg_color`.
         */
        public string accent_fg_hex { get; private set; default = "#ffffff"; }

        /** Near-black used for text on light accents. */
        public const string ACCENT_DARK_FG = "#1c1c1c";

        /**
         * WCAG 2 relative luminance of an sRGB colour, 0 for black and 1
         * for white.
         */
        public static double relative_luminance(Gdk.RGBA color) {
            double[] channels = { color.red, color.green, color.blue };
            double sum = 0;
            double[] weights = { 0.2126, 0.7152, 0.0722 };
            for (int i = 0; i < 3; i++) {
                double c = channels[i];
                double linear = c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
                sum += weights[i] * linear;
            }
            return sum;
        }

        /** WCAG 2 contrast ratio between two colours, from 1 to 21. */
        public static double contrast_ratio(Gdk.RGBA a, Gdk.RGBA b) {
            double la = relative_luminance(a);
            double lb = relative_luminance(b);
            return (double.max(la, lb) + 0.05) / (double.min(la, lb) + 0.05);
        }

        /**
         * Picks the text colour for a surface filled with `background`:
         * white when it reaches 3:1, the WCAG ratio for bold button labels
         * and UI components, otherwise whichever of white and
         * ACCENT_DARK_FG contrasts more.
         *
         * @param background Any colour Gdk.RGBA.parse accepts.
         * @return "#ffffff" or ACCENT_DARK_FG.
         */
        public static string contrast_fg_for(string background) {
            var bg = Gdk.RGBA();
            if (!bg.parse(background)) return "#ffffff";
            var white = Gdk.RGBA();
            white.parse("#ffffff");
            var dark = Gdk.RGBA();
            dark.parse(ACCENT_DARK_FG);
            double on_white = contrast_ratio(bg, white);
            if (on_white >= 3.0) return "#ffffff";
            return contrast_ratio(bg, dark) > on_white ? ACCENT_DARK_FG : "#ffffff";
        }

        public bool crossfade_scheme_changes { get; set; default = true; }

        /**
         * Switches between dark and light color scheme.
         *
         * Reloads the combined CSS with the appropriate color variable file
         * by re-applying the current accent color.
         *
         * @param dark `true` for dark, `false` for light.
         */
        public void apply_color_scheme(bool dark) {
            if (dark != current_dark_mode && crossfade_scheme_changes && accent_provider != null) {
                Singularity.Animation.SnapshotCrossfade.run(() => apply_color_scheme_now(dark));
                return;
            }
            apply_color_scheme_now(dark);
        }

        private void apply_color_scheme_now(bool dark) {
            current_dark_mode = dark;
            apply_accent_color(current_accent, current_accent_wallpaper);
            if (recolor_seed != null) recolor_from_color(recolor_seed);
            update_material_style();
            _load_user_theme_variant(dark);
        }

        private CssProvider? recolor_provider;
        private string? recolor_seed = null;

        /** Emitted after the application's recoloring changed or was reset. */
        public signal void recolored();

        /**
         * Recolors named theme colors for this application only.
         *
         * Keys are theme color names such as `window_bg`, `toolbar_bg`, `card_bg`,
         * `surface_bg`, `sidebar_bg_color` or `accent_color`; values are any
         * color {@link Gdk.RGBA.parse} accepts.
         * Colors left out keep their theme value, invalid entries are ignored,
         * and each call replaces the previous recoloring. The system accent and
         * other applications are not affected.
         *
         * @param colors Map of theme color name to CSS color.
         */
        public void recolor(HashTable<string, string> colors) {
            recolor_seed = null;
            load_recolor(colors);
        }

        /**
         * Recolors this application from a single seed color.
         *
         * Derives a palette in the style of the system accent: the seed becomes
         * the accent and tints the window, view, card, sidebar and header bar
         * surfaces for the current light or dark scheme, following later
         * scheme changes. Useful to match an album cover or a document color.
         *
         * @param color Seed color in any {@link Gdk.RGBA.parse} format.
         */
        public void recolor_from_color(string color) {
            var rgba = Gdk.RGBA();
            if (!rgba.parse(color)) return;
            string seed = "#%02x%02x%02x".printf((uint) (rgba.red * 255), (uint) (rgba.green * 255),
                                                 (uint) (rgba.blue * 255));
            bool dark = current_dark_mode;
            string window_base = dark ? "#242424" : "#f6f5f4";
            string toolbar_base = dark ? "#303030" : "#e0e0e0";
            string surface_base = dark ? "#1e1e1e" : "#ffffff";
            var colors = new HashTable<string, string>(str_hash, str_equal);
            colors["accent_color"] = seed;
            colors["accent_bg_color"] = seed;
            string window_bg = _mix_hex(window_base, seed, 0.08);
            string toolbar_bg = _mix_hex(toolbar_base, seed, 0.10);
            string card_bg = _mix_hex(window_base, seed, dark ? 0.16 : 0.10);
            colors["window_bg"] = window_bg;
            colors["window_bg_color"] = window_bg;
            colors["toolbar_bg"] = toolbar_bg;
            colors["headerbar_bg_color"] = toolbar_bg;
            colors["surface_bg"] = _mix_hex(surface_base, seed, 0.05);
            colors["view_bg_color"] = colors["surface_bg"];
            colors["card_bg"] = card_bg;
            colors["card_bg_color"] = card_bg;
            colors["sidebar_bg_color"] = _mix_hex(window_base, seed, 0.12);
            colors["secondary_sidebar_bg_color"] = _mix_hex(window_base, seed, 0.10);
            recolor_seed = seed;
            load_recolor(colors);
        }

        /** Removes the application's recoloring and returns to the theme colors. */
        public void reset_recolor() {
            recolor_seed = null;
            var display = Gdk.Display.get_default();
            if (recolor_provider != null && display != null) {
                StyleContext.remove_provider_for_display(display, recolor_provider);
            }
            recolor_provider = null;
            recolored();
        }

        private void load_recolor(HashTable<string, string> colors) {
            var display = Gdk.Display.get_default();
            if (display == null) return;
            var css = new StringBuilder();
            string? accent = colors["accent_bg_color"] ?? colors["accent_color"];
            if (accent != null && !colors.contains("accent_fg_color")) {
                string fg = contrast_fg_for(accent);
                css.append_printf("@define-color accent_fg_color %s;\n@define-color accent_fg %s;\n", fg, fg);
            }
            colors.foreach((name, value) => {
                var rgba = Gdk.RGBA();
                if (!Regex.match_simple("^[a-z_]+$", name) || !rgba.parse(value)) return;
                css.append_printf("@define-color %s %s;\n", name, rgba.to_string());
            });
            if (recolor_provider == null) {
                recolor_provider = new CssProvider();
                StyleContext.add_provider_for_display(display, recolor_provider,
                    Gtk.STYLE_PROVIDER_PRIORITY_USER + 2);
            }
            recolor_provider.load_from_string(css.str);
            recolored();
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
                            Gtk.STYLE_PROVIDER_PRIORITY_USER + 3
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
         * @param enabled `true` to enable large text.
         */
        public void set_large_text(bool enabled) {
            set_text_scale(enabled ? 1.4 : 1.0);
        }

        private double text_scale = 1.0;

        /**
         * Scales every text size of the Singularity style by `factor`.
         *
         * The interface font and the pixel font sizes of the built-in style
         * sheet grow together, so labels sized in CSS follow the system text
         * scaling like the rest of the desktop.
         *
         * @param factor Text scaling factor, 1.0 for the default size.
         */
        public void set_text_scale(double factor) {
            factor = factor.clamp(0.5, 3.0);
            text_scale = factor;
            var gtk_settings = Gtk.Settings.get_default();
            if (gtk_settings != null) {
                gtk_settings.gtk_font_name = "Inter %d".printf((int) Math.round(10 * factor));
            }
            var display = Gdk.Display.get_default();
            if (display == null) return;
            if (Math.fabs(factor - 1.0) < 0.01) {
                if (large_text_provider != null) {
                    StyleContext.remove_provider_for_display(display, large_text_provider);
                    large_text_provider = null;
                }
                return;
            }
            string css = "";
            try {
                var bytes = GLib.resources_lookup_data("/dev/sinty/libsingularity/style.css", 0);
                css = (string) bytes.get_data();
            } catch (Error e) {
                warning("StyleManager: failed to read style.css for text scaling: %s", e.message);
                return;
            }
            if (large_text_provider == null) {
                large_text_provider = new CssProvider();
                StyleContext.add_provider_for_display(display, large_text_provider,
                    Gtk.STYLE_PROVIDER_PRIORITY_USER + 3);
            }
            large_text_provider.load_from_string(scaled_font_css(css, factor));
        }

        private static string scaled_font_css(string css, double factor) {
            var out_css = new StringBuilder();
            var size_re = /font-size:\s*([0-9.]+)px/;
            int depth = 0;
            int block_start = 0;
            bool skipping = false;
            for (int i = 0; i < css.length; i++) {
                char c = css[i];
                if (c == '{') {
                    if (depth == 0) {
                        string selector = css.substring(block_start, i - block_start).strip();
                        int comment = selector.last_index_of("*/");
                        if (comment >= 0) selector = selector.substring(comment + 2).strip();
                        skipping = selector.has_prefix("@");
                        block_start = i + 1;
                        if (!skipping) {
                            int end = css.index_of_char('}', i);
                            if (end < 0) break;
                            string body = css.substring(i + 1, end - i - 1);
                            MatchInfo match;
                            if (size_re.match(body, 0, out match)) {
                                double px = double.parse(match.fetch(1));
                                out_css.append("%s { font-size: %dpx; }\n".printf(
                                    selector, (int) Math.round(px * factor)));
                            }
                        }
                    }
                    depth++;
                } else if (c == '}') {
                    depth--;
                    if (depth == 0) {
                        block_start = i + 1;
                        skipping = false;
                    }
                }
            }
            return out_css.str;
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
