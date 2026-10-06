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
         * Keeps the app dark whatever the desktop or system appearance is, for
         * apps built around a dark canvas such as a camera viewfinder. Set it
         * before the application starts.
         */
        public bool force_dark { get; set; default = false; }

        /**
         * Name shown in the About dialog and in the automatic Help menu.
         * Defaults to the application name, then to the name in the
         * application's desktop entry.
         */
        public string? about_name { get; set; default = null; }

        /** Icon name shown in the About dialog. Defaults to the application ID. */
        public string? about_icon { get; set; default = null; }

        /** Version shown in the About dialog. Hidden when null. */
        public string? about_version { get; set; default = null; }

        /**
         * One-line description shown in the About dialog. Defaults to the
         * comment of the application's desktop entry.
         */
        public string? about_description { get; set; default = null; }

        /** Project website shown in the About dialog. Hidden when null. */
        public string? about_website { get; set; default = null; }

        /** Human-readable license name shown in the About dialog. Hidden when null. */
        public string? about_license { get; set; default = null; }

        /** Credits line shown in the About dialog. Hidden when null. */
        public string? about_credits { get; set; default = null; }

        private bool _menubar_queued = false;
        private GLib.Menu? _auto_about_section = null;
        private AppInfo? _desktop_info_cache = null;
        private bool _desktop_info_done = false;
        private bool _extending_menubar = false;
        private SimpleAction? _window_path_action = null;

        /**
         * Creates a new Singularity application.
         *
         * @param app_id  Reverse-DNS application ID (e.g. `"org.example.MyApp"`).
         * @param flags   GLib application flags; defaults to none.
         */
        public Application(string app_id, ApplicationFlags flags = ApplicationFlags.FLAGS_NONE) {
            Object(application_id: app_id, flags: flags);
        }

        construct {
            // Bind libsingularity's own translation domain (its widgets ship
            // user-facing strings); resolve the locale dir from the install
            // prefix so it works whatever the prefix.
            string locale_dir = "/usr/share/locale";
            try {
                string exe = GLib.FileUtils.read_link("/proc/self/exe");
                locale_dir = GLib.Path.build_filename(
                    GLib.Path.get_dirname(GLib.Path.get_dirname(exe)), "share", "locale");
            } catch (Error e) { }
            Intl.bindtextdomain("libsingularity", locale_dir);
            Intl.bind_textdomain_codeset("libsingularity", "UTF-8");

            // GTK_CSD must be set BEFORE Gtk.init runs. Application.startup
            // runs after init, so we read the user's force-ssd setting
            // here and disable GTK's CSD so labwc draws its own SSD via
            // xdg-decoration instead of GTK's fallback titlebar.
            var ds = Core.safe_settings(Singularity.Runtime.desktop_settings_schema);
            if (ds != null && ds.get_boolean("force-ssd")) {
                GLib.Environment.set_variable("GTK_CSD", "0", true);
            }

            notify["menubar"].connect(_queue_menubar_update);
        }

        /**
         * Emitted while the application registers on the session bus,
         * before it owns its bus name. Objects exported from a handler are
         * in place before any D-Bus activated call can reach them.
         */
        public signal void dbus_registered(DBusConnection connection, string object_path);

        /** Emitted when the application leaves the session bus. */
        public signal void dbus_unregistered(DBusConnection connection, string object_path);

        public override bool dbus_register(DBusConnection connection, string object_path) throws Error {
            if (!base.dbus_register(connection, object_path)) return false;
            try {
                ActionAccels.for_application(this).export(connection, object_path);
            } catch (IOError e) {
                warning("ActionAccels: cannot export %s: %s", object_path, e.message);
            }
            dbus_registered(connection, object_path);
            return true;
        }

        public override void dbus_unregister(DBusConnection connection, string object_path) {
            dbus_unregistered(connection, object_path);
            ActionAccels.for_application(this).unexport();
            base.dbus_unregister(connection, object_path);
        }

        protected override void startup() {
            base.startup();

            if (Singularity.Core.WebKitSockets.webkit_loaded())
                Singularity.Core.WebKitSockets.clear_stale_bus_proxies();

            // Pin the brand GTK and icon themes in-process (per-process, NOT via
            // GSettings). The pinned "SingularityShell" GTK theme has empty CSS so
            // GTK loads nothing from the theme layer, letting our style.css win;
            // the icon theme pin keeps symbolic icons working on Wayland. Shared
            // with the shell via the same helper so the policy lives in one place.
            Singularity.Style.StyleManager.pin_brand_themes();

            Singularity.Style.StyleManager.get_default().load_theme();
            Singularity.Accessibility.AccessibilityManager.get_default();
            Singularity.Text.SpellIntegration.install(this);

            string fallback_accent = detect_system_accent();
            bool fallback_dark = false;

            desktop_settings = Core.safe_settings(Singularity.Runtime.desktop_settings_schema);
            if (desktop_settings != null) {
                var oobe_theme_file = Path.build_filename(
                    Environment.get_home_dir(), ".config", "sinty", "theme-mode");
                if (FileUtils.test(oobe_theme_file, FileTest.EXISTS)) {
                    try {
                        string tok;
                        FileUtils.get_contents(oobe_theme_file, out tok);
                        tok = tok.strip();
                        if (tok == "light" || tok == "dual" || tok == "dark")
                            desktop_settings.set_string("theme-mode", tok);
                    } catch (GLib.Error e) {}
                    // Consume the OOBE seed once -- re-applying it on every launch would
                    // overwrite the user's later theme choice.
                    FileUtils.unlink(oobe_theme_file);
                }
                desktop_settings.changed["accent-color"].connect(() => {
                    update_accent_color();
                });
                desktop_settings.changed["background-picture-uri"].connect(() => {
                    if (desktop_settings.get_string("accent-color") == "wallpaper") {
                        update_accent_color();
                    }
                });
                Singularity.Style.ThemeMode.get_default().changed.connect(() => {
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
            } else {
                Singularity.Style.StyleManager.get_default().apply_accent_color(fallback_accent);
            }
            // React to system color-scheme changes only as a fallback when
            // desktop_settings is unavailable. When desktop_settings is present,
            // our dark-mode key owns gtk_application_prefer_dark_theme and the
            // system setting must not override it.
            iface_settings = Core.safe_settings("org.gnome.desktop.interface");
            if (iface_settings != null) {
                iface_settings.changed["color-scheme"].connect(() => {
                    if (!has_desktop_settings) {
                        apply_color_scheme(iface_settings.get_string("color-scheme"));
                    }
                });

                if (!has_desktop_settings) {
                    apply_color_scheme(iface_settings.get_string("color-scheme"));
                    fallback_dark = iface_settings.get_string("color-scheme") == "prefer-dark";
                }
            } else if (!fallback_dark) {
                fallback_dark = (Environment.get_variable("GTK_THEME") ?? "").contains(":dark");
            }
            if (!has_desktop_settings && !fallback_dark) {
                var gs = Gtk.Settings.get_default();
                if (gs != null) fallback_dark = gs.gtk_application_prefer_dark_theme;
            }
            // Apply our own dark-mode preference last so it always wins over
            // any system-level setting applied above.
            if (has_desktop_settings) {
                update_theme_mode();
            } else if (fallback_dark || force_dark) {
                Gtk.Settings.get_default().gtk_application_prefer_dark_theme = true;
                Singularity.Style.StyleManager.get_default().apply_color_scheme(true);
                Singularity.Style.StyleManager.get_default().apply_accent_color(fallback_accent);
            }

            var quit_action = new SimpleAction("quit", null);
            quit_action.activate.connect(() => {
                var windows = new Gee.ArrayList<Gtk.Window>();
                foreach (var win in get_windows()) windows.add(win);
                foreach (var win in windows) win.close();
            });
            add_action(quit_action);
            set_accels_for_action("app.quit", {"<Ctrl>q", "<Alt>F4"});
            describe_action("app.quit", _("Quit"));

            var about_action = new SimpleAction("about", null);
            about_action.activate.connect(() => show_about());
            add_action(about_action);

            var shortcuts_action = new SimpleAction("shortcuts", null);
            shortcuts_action.activate.connect(() => show_shortcuts());
            add_action(shortcuts_action);
            if (get_actions_for_accel("<Control>question").length == 0)
                set_accels_for_action("app.shortcuts", {"<Control>question"});
            describe_action("app.shortcuts", _("Keyboard Shortcuts"));

            _window_path_action = new SimpleAction.stateful("active-window-path", null, new Variant.string(""));
            _window_path_action.set_enabled(false);
            add_action(_window_path_action);
            notify["active-window"].connect(_sync_window_path);
            window_added.connect(_queue_menubar_update);

            _queue_menubar_update();
        }

        /**
         * Names a shortcut for the desktop, which lists the accelerators of
         * the app even when it has no menu bar. See Singularity.ActionAccels.
         */
        public const int APP_STYLE_PRIORITY = Gtk.STYLE_PROVIDER_PRIORITY_USER + 1;

        public static Gtk.CssProvider? add_app_css(string css) {
            var display = Gdk.Display.get_default();
            if (display == null) return null;
            var provider = new Gtk.CssProvider();
            provider.load_from_string(css);
            Gtk.StyleContext.add_provider_for_display(display, provider, APP_STYLE_PRIORITY);
            return provider;
        }

        public static Gtk.CssProvider? add_app_css_resource(string resource_path) {
            var display = Gdk.Display.get_default();
            if (display == null) return null;
            var provider = new Gtk.CssProvider();
            provider.load_from_resource(resource_path);
            Gtk.StyleContext.add_provider_for_display(display, provider, APP_STYLE_PRIORITY);
            return provider;
        }

        public void describe_action(string detailed_action, string label, string? group = null) {
            ActionAccels.for_application(this).describe(detailed_action, label, group);
        }

        /**
         * Opens the About dialog, filled from the `about_*` properties.
         * This is what the automatic `app.about` action does; an app that
         * adds its own `about` action replaces it.
         *
         * @param parent Window the dialog is placed over; defaults to the
         *               active window.
         */
        public void show_about(Gtk.Window? parent = null) {
            string icon = about_icon ?? application_id ?? "application-x-executable";
            string? description = about_description;
            if (description == null) {
                var info = _desktop_info();
                if (info != null) description = info.get_description();
            }
            var dlg = new Singularity.Widgets.AboutDialog(this, icon, _display_name(),
                about_version, description, about_website, about_license, about_credits);
            dlg.transient_for = parent ?? get_active_window();
            dlg.present();
        }

        /**
         * Opens the keyboard shortcuts dialog built from the menu bar and
         * the application's accelerators. This is what the automatic
         * `app.shortcuts` action (Ctrl+?) does.
         *
         * @param parent Window the dialog is placed over; defaults to the
         *               active window.
         */
        public void show_shortcuts(Gtk.Window? parent = null) {
            var dlg = new Singularity.Widgets.ShortcutsDialog(this);
            dlg.transient_for = parent ?? get_active_window();
            dlg.present();
        }

        private AppInfo? _desktop_info() {
            if (_desktop_info_done) return _desktop_info_cache;
            _desktop_info_done = true;
            if (application_id == null) return null;
            string id = application_id + ".desktop";
            foreach (var info in AppInfo.get_all()) {
                if (info.get_id() == id) {
                    _desktop_info_cache = info;
                    break;
                }
            }
            return _desktop_info_cache;
        }

        private string _display_name() {
            if (about_name != null && about_name != "") return about_name;
            var info = _desktop_info();
            if (info != null) return info.get_display_name();
            string? name = GLib.Environment.get_application_name();
            if (name != null && name != "" && name != GLib.Environment.get_prgname()
                    && name != application_id)
                return name;
            foreach (var win in get_windows()) {
                if (win.title != null && win.title != "") return win.title;
            }
            return application_id ?? "";
        }

        private void _sync_window_path() {
            if (_window_path_action == null) return;
            string path = "";
            var win = get_active_window() as Gtk.ApplicationWindow;
            string? base_path = get_dbus_object_path();
            if (win != null && win.get_id() != 0 && base_path != null)
                path = "%s/window/%u".printf(base_path, win.get_id());
            _window_path_action.set_state(new Variant.string(path));
        }

        private void _queue_menubar_update() {
            if (_menubar_queued || _extending_menubar) return;
            _menubar_queued = true;
            Idle.add(() => {
                _menubar_queued = false;
                _extend_menubar();
                return false;
            });
        }

        private void _extend_menubar() {
            var menu = menubar as GLib.Menu;
            if (menu == null || menu.get_n_items() == 0) return;
            _extending_menubar = true;
            if (!_has_help_menu(menu) && lookup_action("about") != null
                    && lookup_action("shortcuts") != null) {
                var help = new GLib.Menu();
                var keys = new GLib.Menu();
                keys.append(_("Keyboard Shortcuts"), "app.shortcuts");
                help.append_section(null, keys);
                _auto_about_section = new GLib.Menu();
                help.append_section(null, _auto_about_section);
                menu.append_submenu(_("Help"), help);
            }
            if (_auto_about_section != null) {
                string label = _("About %s").printf(_display_name());
                string? current = null;
                if (_auto_about_section.get_n_items() > 0)
                    _auto_about_section.get_item_attribute(0, Menu.ATTRIBUTE_LABEL, "s", out current);
                if (current != label) {
                    if (_auto_about_section.get_n_items() > 0) _auto_about_section.remove(0);
                    _auto_about_section.append(label, "app.about");
                }
            }
            _annotate_accels(menu);
            _extending_menubar = false;
        }

        private static bool _has_help_menu(MenuModel menu) {
            for (int i = 0; i < menu.get_n_items(); i++) {
                string? label = null;
                menu.get_item_attribute(i, Menu.ATTRIBUTE_LABEL, "s", out label);
                if (label == null) continue;
                label = label.replace("_", "");
                if (label == "Help" || label == _("Help") || label == GLib.dgettext(null, "Help"))
                    return true;
            }
            return false;
        }

        private void _annotate_accels(GLib.Menu menu) {
            for (int i = 0; i < menu.get_n_items(); i++) {
                MenuModel? link = menu.get_item_link(i, Menu.LINK_SECTION);
                if (link == null) link = menu.get_item_link(i, Menu.LINK_SUBMENU);
                if (link != null) {
                    if (link is GLib.Menu) _annotate_accels((GLib.Menu) link);
                    continue;
                }
                string? current = null;
                menu.get_item_attribute(i, "accel", "s", out current);
                if (current != null) continue;
                string? accel = Singularity.Widgets.ShortcutsDialog.item_accel(this, menu, i);
                if (accel == null) continue;
                var item = new MenuItem.from_model(menu, i);
                item.set_attribute_value("accel", new Variant.string(accel));
                menu.remove(i);
                menu.insert_item(i, item);
            }
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
            var iface = Core.safe_settings("org.gnome.desktop.interface");
            if (iface != null && iface.settings_schema.has_key("accent-color")) {
                string name = iface.get_string("accent-color");
                if (name != null && name != "") return name;
            }
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
            // Applications follow the app tone: light unless the effective mode
            // is full Dark. The shell chrome follows a different (shell) tone.
            bool dark = force_dark || Singularity.Style.ThemeMode.get_default().app_dark();
            Gtk.Settings.get_default().gtk_application_prefer_dark_theme = dark;
            Singularity.Style.StyleManager.get_default().apply_color_scheme(dark);
            // Re-apply accent so base tint colors use the correct light/dark base.
            update_accent_color();
        }

        private void apply_color_scheme(string scheme) {
            bool dark = force_dark || (scheme == "prefer-dark");
            Gtk.Settings.get_default().gtk_application_prefer_dark_theme = dark;
            Singularity.Style.StyleManager.get_default().apply_color_scheme(dark);
            if (has_desktop_settings) {
                update_accent_color();
            }
        }

        /**
         * Standalone appearance override for apps that expose their own preference
         * (for example from an in-app settings dialog) when running outside the
         * Singularity desktop. "system" follows the system dark preference,
         * "light"/"dark" force it. Ignored under the desktop, where the desktop
         * theme-mode owns the appearance.
         */
        public void set_app_appearance(string mode) {
            if (has_desktop_settings || force_dark) return;
            bool dark;
            switch (mode) {
                case "light": dark = false; break;
                case "dark":  dark = true;  break;
                default:
                    dark = (iface_settings != null
                            && iface_settings.get_string("color-scheme") == "prefer-dark");
                    var gs = Gtk.Settings.get_default();
                    if (!dark && gs != null) dark = gs.gtk_application_prefer_dark_theme;
                    if (!dark) dark = (Environment.get_variable("GTK_THEME") ?? "").contains(":dark");
                    break;
            }
            Gtk.Settings.get_default().gtk_application_prefer_dark_theme = dark;
            Singularity.Style.StyleManager.get_default().apply_color_scheme(dark);
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
                win.title = _("%s - Preferences").printf(app_name);
            } else {
                win.title = _("Preferences");
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
