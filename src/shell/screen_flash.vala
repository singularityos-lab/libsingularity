using Gtk;
using GtkLayerShell;

namespace Singularity.Shell {

    /**
     * Full-screen white-flash overlay shown immediately after a screenshot.
     *
     * Covers the entire monitor via GTK Layer Shell, fades out briefly, then closes itself.
     * Use the static helper `flash()` to trigger the effect.
     */
    public class ScreenFlash : Gtk.Window {

        /** Milliseconds before the flash window auto-closes. */
        private const uint FLASH_DURATION_MS = 350;

        /**
         * Creates a new screen-flash window attached to the given application.
         *
         * @param app The owning Gtk.Application; must be non-null.
         */
        public ScreenFlash(Gtk.Application app) {
            // Pass application via Object() so GTK4 sets up the surface type
            // before layer-shell methods are called - same pattern as Overview.
            Object(application: app, decorated: false);

            var fill = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            fill.hexpand = true;
            fill.vexpand = true;
            fill.add_css_class("screen-flash-fill");
            set_child(fill);

            add_css_class("screen-flash");
            GtkLayerShell.init_for_window(this);
            set_layer(this, GtkLayerShell.Layer.OVERLAY);
            set_anchor(this, GtkLayerShell.Edge.TOP, true);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
        }

        // Show a brief white flash and auto-close.

        /**
         * Triggers a brief full-screen white flash and closes automatically.
         */
        public static void flash() {
            var app = GLib.Application.get_default() as Gtk.Application;
            if (app == null) return;
            var win = new ScreenFlash(app);
            win.present();
            GLib.Timeout.add(FLASH_DURATION_MS, () => {
                win.close();
                return GLib.Source.REMOVE;
            });
        }
    }
}
