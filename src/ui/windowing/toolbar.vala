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

        /** Enables or disables server-side-decoration mode on this toolbar. */
        public void set_ssd_mode(bool enabled) {
            if (enabled) {
                add_css_class("ssd-mode");
                close_btn.visible = false;
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
    /**
     * An invisible spacer widget that reserves the same vertical space as a
     * ToolBar when the toolbar is used as an overlay.
     *
     * Place this at the top of a scrollable area so content does not start
     * behind the floating toolbar.
     */
    public class ToolbarSpacer : Widget {

        /** Creates a spacer with the default toolbar height (46 px). */
        public ToolbarSpacer() {
            add_css_class("toolbar-spacer");
            set_size_request(-1, 46);
            visible = true;
            can_target = false;
            focusable = false;
        }

        /**
         * Creates a spacer with a custom height.
         *
         * @param height Height in pixels.
         */
        public ToolbarSpacer.with_height(int height) {
            add_css_class("toolbar-spacer");
            set_size_request(-1, height);
            visible = true;
            can_target = false;
            focusable = false;
        }
    }
}
