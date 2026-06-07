using Gtk;

namespace Singularity.Widgets {

    /**
     * The application toolbar rendered at the top of a Window.
     *
     * Contains a left area, centered title, and right area (which includes the close button).
     * Use `pack_start()` and `pack_end()` to add custom controls.
     */
    public class ToolBar : Box {
        /** Label showing the current window title. */
        public Label title_label { get; private set; }

        /** Container on the leading (left) side of the toolbar. */
        public Box start_box { get; private set; }

        /** Container on the trailing (right) side of the toolbar. */
        public Box end_box { get; private set; }

        /** The window minimize button in the trailing area (hidden by default). */
        public Button minimize_btn { get; private set; }

        /** The window maximize button in the trailing area (hidden by default). */
        public Button maximize_btn { get; private set; }

        /** The window close button in the trailing area. */
        public CloseButton close_btn { get; private set; }

        /**
         * When `true` the toolbar is positioned statically at the top of the
         * window layout. When `false` it floats as an overlay and the content
         * area scrolls beneath it (adding the `toolbar-scroll-under` CSS class).
         */
        public bool is_static { get; set; default = true; }

        /** Height in pixels of the toolbar. */
        public int toolbar_height { get; private set; default = 46; }

        public ToolBar() {
            Object(orientation: Orientation.HORIZONTAL, spacing: 6);
        }

        // Built in construct so .ui/vetro instances are assembled too.
        construct {
            orientation = Orientation.HORIZONTAL;
            spacing = 6;
            add_css_class("singularity-toolbar");
            set_size_request(-1, 46);
            start_box = new Box(Orientation.HORIZONTAL, 6);
            start_box.hexpand = false;
            start_box.halign = Align.START;
            start_box.set_margin_top(3);
            start_box.set_margin_bottom(3);
            append(start_box);
            title_label = new Label("");
            title_label.add_css_class("title");
            title_label.hexpand = true;
            title_label.halign = Align.CENTER;
            append(title_label);
            end_box = new Box(Orientation.HORIZONTAL, 6);
            end_box.hexpand = false;
            end_box.halign = Align.END;
            end_box.set_margin_top(3);
            end_box.set_margin_bottom(3);
            minimize_btn = new Button.from_icon_name("window-minimize-symbolic");
            minimize_btn.add_css_class("flat");
            minimize_btn.add_css_class("image-button");
            minimize_btn.valign = Align.CENTER;
            minimize_btn.visible = false;
            minimize_btn.tooltip_text = _("Minimize Window");
            minimize_btn.clicked.connect(() => {
                var w = get_root() as Gtk.Window;
                if (w != null) w.minimize();
            });
            end_box.append(minimize_btn);

            maximize_btn = new Button.from_icon_name("window-maximize-symbolic");
            maximize_btn.add_css_class("flat");
            maximize_btn.add_css_class("image-button");
            maximize_btn.valign = Align.CENTER;
            maximize_btn.visible = false;
            maximize_btn.tooltip_text = _("Maximize Window");
            maximize_btn.clicked.connect(() => {
                var w = get_root() as Gtk.Window;
                if (w == null) return;
                if (w.maximized) w.unmaximize();
                else w.maximize();
            });
            end_box.append(maximize_btn);

            close_btn = new Singularity.Widgets.CloseButton();
            close_btn.clicked.connect(() => {
                var window = (Gtk.Window)get_root();
                window.close();
            });
            end_box.append(close_btn);
            append(end_box);
            notify["is-static"].connect(() => {
                if (is_static) {
                    remove_css_class("toolbar-scroll-under");
                } else {
                    add_css_class("toolbar-scroll-under");
                }
            });
            add_css_class("toolbar-scroll-under");
        }

        /**
         * Shows the minimize/maximize controls following the user's window
         * button-layout. Used by the legacy static titlebar.
         */
        private GLib.Settings? _wm_layout_settings = null;

        public void enable_window_controls() {
            apply_button_layout();
            // React live to button-layout changes from Settings.
            if (_wm_layout_settings == null) {
                var src = GLib.SettingsSchemaSource.get_default();
                if (src != null && src.lookup("org.gnome.desktop.wm.preferences", true) != null) {
                    _wm_layout_settings = new GLib.Settings("org.gnome.desktop.wm.preferences");
                    _wm_layout_settings.changed["button-layout"].connect((k) => apply_button_layout());
                }
            }
        }

        private void apply_button_layout() {
            string layout = resolve_button_layout();
            minimize_btn.visible = "minimize" in layout;
            maximize_btn.visible = "maximize" in layout;
            close_btn.visible = "close" in layout;
        }

        // Prefer the host org.gnome.desktop.wm.preferences button-layout (which
        // the Settings min/max toggles write to) and fall back to GTK's
        // gtk_decoration_layout, matching HoverControls. Without this the legacy
        // titlebar / SSD toolbar read only the GTK default (":close") and never
        // showed the minimize/maximize buttons even when enabled in Settings.
        private static string resolve_button_layout() {
            var src = GLib.SettingsSchemaSource.get_default();
            if (src != null && src.lookup("org.gnome.desktop.wm.preferences", true) != null) {
                var wm = new GLib.Settings("org.gnome.desktop.wm.preferences");
                string bl = wm.get_string("button-layout");
                if (bl != null && bl != "") return bl;
            }
            return Gtk.Settings.get_default().gtk_decoration_layout ?? ":close";
        }

        /** Enables or disables server-side-decoration mode on this toolbar. */
        public void set_ssd_mode(bool enabled) {
            if (enabled) {
                add_css_class("ssd-mode");
                close_btn.visible = false;
                minimize_btn.visible = false;
                maximize_btn.visible = false;
                is_static = true;
            } else {
                remove_css_class("ssd-mode");
                close_btn.visible = true;
                title_label.visible = true;
            }
        }
        private Widget? custom_title_widget = null;

        /** Sets the title text shown in the centre of the toolbar. */
        public void set_title(string title) {
            title_label.label = title;
        }

        /**
         * Replaces the title label with a custom widget.
         * Pass `null` to restore the default title label.
         */
        public void set_title_widget(Widget? widget) {
            if (custom_title_widget != null && custom_title_widget.parent == this) {
                remove(custom_title_widget);
            }
            if (widget != null) {
                if (title_label != null && title_label.parent == this) {
                    remove(title_label);
                }
                widget.hexpand = true;
                widget.halign = Align.FILL;
                widget.valign = Align.CENTER;
                insert_child_after(widget, start_box);
                custom_title_widget = widget;
            } else {
                if (title_label != null && title_label.parent != this) {
                    insert_child_after(title_label, start_box);
                }
                custom_title_widget = null;
            }
        }

        /** Appends a widget to the leading (left) area. */
        public void pack_start(Widget widget) {
            start_box.append(widget);
        }

        /** Prepends a widget to the trailing (right) area, before the close button. */
        public void pack_end(Widget widget) {
            end_box.prepend(widget);
        }
    }
}
