using Gtk;

namespace Singularity {

     /**
     * Base application class for Singularity apps.
     *
     * Extends Gtk.Application with automatic theme loading, accent
     * colour management, dark-mode toggling, and per-app window-state
     * persistence. All Singularity apps should subclass this instead of
     * Gtk.Application directly.
     */
    public class Application : Gtk.Application {

        private GLib.Settings? desktop_settings;
        private GLib.Settings? iface_settings;
        // True when desktop_settings loaded successfully; iface_settings only
        // controls dark-mode as a fallback when this is false.
        private bool has_desktop_settings = false;

        /**
         * Creates a new Singularity application.
         *
         * @param app_id  Reverse-DNS application ID (e.g. `"org.example.MyApp"`).
         * @param flags   GLib application flags; defaults to none.
         */
        public Application(string app_id, ApplicationFlags flags = ApplicationFlags.FLAGS_NONE) {
            Object(application_id: app_id, flags: flags);
        }

        protected override void startup() {
            base.startup();

            // Override gtk-theme in-process only (per-process, NOT via GSettings).
            // The "Singularity" theme has empty CSS files so GTK4 loads nothing from
            // the theme layer, letting our style.css at PRIORITY_APPLICATION win.
            // The notify guard ensures GSettings binding changes can't reset it.
            var _gs = Gtk.Settings.get_default();
            _gs.gtk_theme_name = "Singularity";
            _gs.notify["gtk-theme-name"].connect(() => {
                if (_gs.gtk_theme_name != "Singularity") {
                    _gs.gtk_theme_name = "Singularity";
                }
            });

            Singularity.Style.StyleManager.get_default().load_theme();
            Singularity.Accessibility.AccessibilityManager.get_default();

            string fallback_accent = detect_system_accent();
            bool fallback_dark = false;

            try {
                desktop_settings = new GLib.Settings(Singularity.Runtime.desktop_settings_schema);
                desktop_settings.changed["accent-color"].connect(() => {
                    update_accent_color();
                });
                desktop_settings.changed["background-picture-uri"].connect(() => {
                    if (desktop_settings.get_string("accent-color") == "wallpaper") {
                        update_accent_color();
                    }
                });
                desktop_settings.changed["dark-mode"].connect(() => {
                    update_theme_mode();
                });
                desktop_settings.changed["singularity-theme"].connect(() => {
                    Singularity.Style.StyleManager.get_default().load_user_theme(
                        desktop_settings.get_string("singularity-theme"));
                });
                update_accent_color();
                has_desktop_settings = true;
                // Load user theme after accent/dark mode so CSS variables are ready.
                Singularity.Style.StyleManager.get_default().load_user_theme(
                    desktop_settings.get_string("singularity-theme"));
            } catch (Error e) {
                warning("Desktop settings unavailable, using system fallbacks: %s", e.message);
                Singularity.Style.StyleManager.get_default().apply_accent_color(fallback_accent);
            }
            // React to system color-scheme changes only as a fallback when
            // desktop_settings is unavailable. When desktop_settings is present,
            // our dark-mode key owns gtk_application_prefer_dark_theme and the
            // system setting must not override it.
            try {
                iface_settings = new GLib.Settings("org.gnome.desktop.interface");
                iface_settings.changed["color-scheme"].connect(() => {
                    if (!has_desktop_settings) {
                        apply_color_scheme(iface_settings.get_string("color-scheme"));
                    }
                });

                if (!has_desktop_settings) {
                    apply_color_scheme(iface_settings.get_string("color-scheme"));
                    fallback_dark = iface_settings.get_string("color-scheme") == "prefer-dark";
                }
            } catch (Error e) {
                // This is expected, org.gnome.desktop.interface may not be present in
                // all environments.
                if (!fallback_dark) {
                    var scheme = Environment.get_variable("XDG_CURRENT_DESKTOP");
                    fallback_dark = (Environment.get_variable("GTK_THEME") ?? "").contains(":dark");
                }
            }
            // Apply our own dark-mode preference last so it always wins over
            // any system-level setting applied above.
            if (has_desktop_settings) {
                update_theme_mode();
            } else if (fallback_dark) {
                Gtk.Settings.get_default().gtk_application_prefer_dark_theme = true;
                Singularity.Style.StyleManager.get_default().apply_color_scheme(true);
                Singularity.Style.StyleManager.get_default().apply_accent_color(fallback_accent);
            }

            var quit_action = new SimpleAction("quit", null);
            quit_action.activate.connect(() => {
                foreach (var win in get_windows()) {
                    if (win is Gtk.Window) {
                        ((Gtk.Window) win).close();
                    }
                }
            });
            add_action(quit_action);
            set_accels_for_action("app.quit", {"<Ctrl>q", "<Alt>F4"});
        }

        private string detect_system_accent() {
            try {
                var proxy = new GLib.DBusProxy.for_bus_sync(
                    BusType.SESSION,
                    DBusProxyFlags.DO_NOT_AUTO_START | DBusProxyFlags.DO_NOT_LOAD_PROPERTIES,
                    null,
                    "org.freedesktop.portal.Desktop",
                    "/org/freedesktop/portal/desktop",
                    "org.freedesktop.portal.Settings"
                );
                var variant = proxy.call_sync("Read", new Variant("(ss)", "org.freedesktop.appearance", "accent-color"), DBusCallFlags.NONE, -1);
                if (!variant.is_of_type(new VariantType("(v)"))) return "blue";
                var value = variant.get_child_value(0).get_variant();
                if (value.is_of_type(new VariantType("(ddd)"))) {
                    double r = value.get_child_value(0).get_double();
                    double g = value.get_child_value(1).get_double();
                    double b = value.get_child_value(2).get_double();
                    return "#%02x%02x%02x".printf((uint)(r * 255 + 0.5), (uint)(g * 255 + 0.5), (uint)(b * 255 + 0.5));
                }
            } catch {}
            try {
                var iface = new GLib.Settings("org.gnome.desktop.interface");
                if (iface.settings_schema.has_key("accent-color")) {
                    string name = iface.get_string("accent-color");
                    if (name != null && name != "") return name;
                }
            } catch {}
            return "blue";
        }

        private void update_accent_color() {
            if (desktop_settings == null) return;
            string color_name = desktop_settings.get_string("accent-color");
            string? wallpaper_path = null;
            if (color_name == "wallpaper") {
                string uri = desktop_settings.get_string("background-picture-uri");
                if (uri != "") {
                    var file = File.new_for_uri(uri);
                    wallpaper_path = file.get_path();
                }
            } else if (color_name == "custom") {
                string hex = desktop_settings.get_string("custom-accent-color");
                if (hex == "" || hex == null) hex = "#3584e4";
                color_name = hex;
            }
            Singularity.Style.StyleManager.get_default().apply_accent_color(color_name, wallpaper_path);
        }

        private void update_theme_mode() {
            if (desktop_settings == null) return;
            bool dark_mode = desktop_settings.get_boolean("dark-mode");
            Gtk.Settings.get_default().gtk_application_prefer_dark_theme = dark_mode;
            Singularity.Style.StyleManager.get_default().apply_color_scheme(dark_mode);
            // Re-apply accent so base tint colors use the correct light/dark base.
            update_accent_color();
        }

        private void apply_color_scheme(string scheme) {
            bool dark = (scheme == "prefer-dark");
            Gtk.Settings.get_default().gtk_application_prefer_dark_theme = dark;
            Singularity.Style.StyleManager.get_default().apply_color_scheme(dark);
            if (has_desktop_settings) {
                update_accent_color();
            }
        }

        /**
         * Returns the widget to display in the preferences window.
         *
         * Override this in your Application subclass to provide a
         * custom preferences page built with Singularity.Widgets.PreferencesGroup
         * and its row types. The widget will be shown in a
         * Singularity.Widgets.PreferencesWindow when
         * open_preferences is called.
         *
         * Return `null` (the default) if the app has no preferences.
         *
         * Note: the JSON settings descriptor installed under
         * `$XDG_DATA_DIR/singularity/app-settings/` is a separate mechanism
         * used by the Singularity Settings panel. Both can coexist - this
         * method only controls the standalone preferences window that opens
         * outside the shell settings panel.
         */
        protected virtual Gtk.Widget? get_preferences_page() {
            return null;
        }

        /**
         * Opens (or raises) the app's preferences window.
         *
         * If get_preferences_page returns `null` this is a no-op.
         * Only one preferences window is kept alive at a time; calling this
         * again while the window is already open simply presents it.
         *
         * @param parent Optional parent window for the dialog; used to place
         *               the preferences window near the calling window.
         */
        public void open_preferences(Gtk.Window? parent = null) {
            var page = get_preferences_page();
            if (page == null) return;

            // Use instance data to avoid ABI-breaking private fields; the window
            // reference is stored with the GObject instance and cleared on close.
            var existing = get_data<Singularity.Widgets.PreferencesWindow?>("_prefs_window");
            if (existing != null) {
                existing.present();
                return;
            }

            var win = new Singularity.Widgets.PreferencesWindow(this, page);
            var app_name = GLib.Environment.get_application_name();
            if (app_name != null && app_name != "") {
                win.title = "%s - Preferences".printf(app_name);
            } else {
                win.title = "Preferences";
            }
            if (parent != null) {
                win.transient_for = parent;
            }
            set_data("_prefs_window", win);
            win.close_request.connect(() => {
                set_data<Singularity.Widgets.PreferencesWindow?>("_prefs_window", null);
                return false;
            });
            win.present();
        }
    }
}
