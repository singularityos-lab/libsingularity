using Gtk;
using GtkLayerShell;

namespace Singularity.Shell {

    /**
     * A layer-shell window used as a dialog in the Singularity shell.
     *
     * Positions itself via GTK Layer Shell anchors so it can float above
     * the compositor's normal window stack (e.g. for system dialogs, confirmation prompts,
     * or overlay panels).
     *
     * Three convenience constructors are provided:
     * - `ShellDialog()` – default, no anchors
     * - `ShellDialog.anchored()` – explicit anchor combination
     * - `ShellDialog.bottom()` – anchored to the bottom edge with margin
     *
     * Subclass and override `close_dialog()` and `open_dialog()` for custom show/hide behavior.
     */
    public class ShellDialog : Window {
        /** The main content area; append widgets here. */
        public Box content_box { get; private set; }
        /** Whether the surface is anchored to the top edge. */
        public bool anchor_top { get; construct; default = false; }
        /** Whether the surface is anchored to the bottom edge. */
        public bool anchor_bottom { get; construct; default = false; }
        /** Whether the surface is anchored to the left edge. */
        public bool anchor_left { get; construct; default = false; }
        /** Whether the surface is anchored to the right edge. */
        public bool anchor_right { get; construct; default = false; }
        /** Top-edge margin in pixels (applied when `anchor_top` is true). */
        public int margin_top_value { get; construct; default = 0; }
        /** Bottom-edge margin in pixels (applied when `anchor_bottom` is true). */
        public int margin_bottom_value { get; construct; default = 0; }
        /** Left-edge margin in pixels (applied when `anchor_left` is true). */
        public int margin_left_value { get; construct; default = 0; }
        /** Right-edge margin in pixels (applied when `anchor_right` is true). */
        public int margin_right_value { get; construct; default = 0; }

        /**
         * Creates a basic shell dialog with no anchors.
         *
         * @param app The owning Gtk.Application.
         */
        public ShellDialog(Gtk.Application app) {
            Object(application: app);
        }

        /**
         * Creates a shell dialog with explicit anchor settings.
         *
         * @param app    The owning application, or `null`.
         * @param top    Anchor to top edge.
         * @param bottom Anchor to bottom edge.
         * @param left   Anchor to left edge.
         * @param right  Anchor to right edge.
         */
        public ShellDialog.anchored(Gtk.Application? app, bool top, bool bottom, bool left, bool right) {
            Object(
                application: app,
                anchor_top: top,
                anchor_bottom: bottom,
                anchor_left: left,
                anchor_right: right
            );
        }

        /**
         * Creates a shell dialog anchored to the bottom edge.
         *
         * @param app    The owning application, or `null`.
         * @param margin Bottom margin in pixels; defaults to 60.
         */
        public ShellDialog.bottom(Gtk.Application? app, int margin = 60) {
            Object(
                application: app,
                anchor_bottom: true,
                margin_bottom_value: margin
            );
        }
        construct {
            init_for_window(this);
            set_layer(this, GtkLayerShell.Layer.OVERLAY);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.ON_DEMAND);
            set_anchor(this, GtkLayerShell.Edge.TOP, anchor_top);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, anchor_bottom);
            set_anchor(this, GtkLayerShell.Edge.LEFT, anchor_left);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, anchor_right);
            if (margin_top_value > 0)
                set_margin(this, GtkLayerShell.Edge.TOP, margin_top_value);
            if (margin_bottom_value > 0)
                set_margin(this, GtkLayerShell.Edge.BOTTOM, margin_bottom_value);
            if (margin_left_value > 0)
                set_margin(this, GtkLayerShell.Edge.LEFT, margin_left_value);
            if (margin_right_value > 0)
                set_margin(this, GtkLayerShell.Edge.RIGHT, margin_right_value);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("dialog");

            bool full = anchor_top && anchor_bottom && anchor_left && anchor_right;
            if (full) {
                // -1 = ignore exclusive zones from dock/panel so we cover the full screen
                set_exclusive_zone(this, -1);
                add_css_class("dialog-overlay");
                var outer = new Box(Orientation.VERTICAL, 0);
                outer.add_css_class("dialog-overlay-bg");
                content_box = new Box(Orientation.VERTICAL, 0);
                content_box.add_css_class("dialog-content");
                content_box.hexpand = true;
                content_box.vexpand = true;
                content_box.halign = Align.CENTER;
                content_box.valign = Align.CENTER;
                outer.append(content_box);
                set_child(outer);
            } else {
                content_box = new Box(Orientation.VERTICAL, 0);
                content_box.add_css_class("dialog-content");
                set_child(content_box);
            }

            var key_controller = new EventControllerKey();
            key_controller.key_pressed.connect((keyval, keycode, state) => {
                if (keyval == Gdk.Key.Escape) {
                    close_dialog();
                    return true;
                }
                return false;
            });
            ((Gtk.Widget)this).add_controller(key_controller);
        }

        /**
         * Hides the dialog. Override to add custom close behaviour.
         */
        public virtual void close_dialog() {
            hide();
        }

        /**
         * Presents the dialog. Override to add custom show behaviour.
         */
        public virtual void open_dialog() {
            present();
        }
    }
}
