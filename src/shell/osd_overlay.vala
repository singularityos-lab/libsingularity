using Gtk;
using GLib;
using GtkLayerShell;

namespace Singularity.Shell {

    /**
     * Top-centre pill OSD overlay for transient system feedback.
     *
     * Used for volume, brightness, keyboard backlight, and caps/num-lock notifications.
     * Positions itself at the top-centre of the primary monitor via GTK Layer Shell
     * and auto-hides after a short timeout.
     *
     * Obtain the shared instance via `get_default()`.
     */
    public class OsdOverlay : Gtk.Window {
        private static OsdOverlay? _instance = null;
        private Image icon_widget;
        private ProgressBar bar;
        private Label label_widget;
        private uint hide_timeout = 0;

        /** Milliseconds the OSD remains visible before auto-hiding. */
        private const uint OSD_HIDE_DELAY_MS = 1800;

        /** Returns the shared OsdOverlay instance, creating it on first call. */
        public static OsdOverlay get_default() {
            if (_instance == null) {
                _instance = new OsdOverlay();
                var app = GLib.Application.get_default() as Gtk.Application;
                if (app != null) _instance.set_application(app);
            }
            return _instance;
        }

        public OsdOverlay() {
            Object(
                decorated: false,
                resizable: false,
                deletable: false,
                can_focus: false,
                focusable: false,
                focus_on_click: false
            );
            add_css_class("panel-window");

            var pill = new Box(Orientation.HORIZONTAL, 12);
            pill.add_css_class("osd-pill");
            pill.valign = Align.START;
            pill.halign = Align.CENTER;

            icon_widget = new Image();
            icon_widget.pixel_size = 24;
            icon_widget.valign = Align.CENTER;
            pill.append(icon_widget);

            var vbox = new Box(Orientation.VERTICAL, 4);
            vbox.valign = Align.CENTER;
            vbox.hexpand = true;

            label_widget = new Label("");
            label_widget.halign = Align.START;
            label_widget.add_css_class("caption");
            vbox.append(label_widget);

            bar = new ProgressBar();
            bar.hexpand = true;
            bar.valign = Align.CENTER;
            vbox.append(bar);

            pill.append(vbox);
            set_child(pill);

            try_setup_layer_shell();
        }

        protected override void dispose() {
            if (hide_timeout != 0) {
                Source.remove(hide_timeout);
                hide_timeout = 0;
            }
            base.dispose();
        }

        private void try_setup_layer_shell() {
            GtkLayerShell.init_for_window(this);
            GtkLayerShell.set_layer(this, GtkLayerShell.Layer.OVERLAY);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.TOP, true);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.LEFT, false);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.RIGHT, false);
            GtkLayerShell.set_margin(this, GtkLayerShell.Edge.TOP, 16);
            GtkLayerShell.set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
        }

        /**
         * Displays the OSD with the given icon and optional progress value.
         *
         * The overlay is presented immediately and auto-hides after ~1.5 seconds.
         *
         * @param icon_name Symbolic icon name (e.g. `"audio-volume-high-symbolic"`).
         * @param value     Progress value in the range 0–100 for a progress bar,
         *                  or a negative value to show only the icon and label.
         * @param text      Optional label shown below the progress bar.
         */
        public void show_osd(string icon_name, double value, string? text = null) {
            icon_widget.icon_name = icon_name;
            bar.visible = value >= 0;
            if (value >= 0) {
                bar.fraction = (value / 100.0).clamp(0.0, 1.0);
            }
            label_widget.label = text ?? "";
            label_widget.visible = text != null && text.length > 0;

            present();

            if (hide_timeout != 0) {
                Source.remove(hide_timeout);
                hide_timeout = 0;
            }
            hide_timeout = Timeout.add(OSD_HIDE_DELAY_MS, () => {
                hide();
                hide_timeout = 0;
                return Source.REMOVE;
            });
        }

        ~OsdOverlay() {
        }
    }
}
