using Gtk;

namespace Singularity {

    /**
     * Base application class for Singularity shells (compositor sessions).
     *
     * Where Singularity.Application is the base for regular apps that *consume*
     * desktop settings, ShellApplication is the base for the desktop shell that
     * *owns* the session: it is the settings authority, manages the panels,
     * docks and overview, and drives the compositor.
     *
     * This base deliberately stays compositor-agnostic: it only carries the
     * concerns shared by any Singularity shell (pinning the brand GTK and icon
     * themes). Compositor-specific behaviour (writing labwc's themerc, syncing
     * org.gnome.desktop.interface, generating gtk-3.0/settings.ini, etc.) belongs
     * in the concrete shell subclass, not here, so the library never couples to
     * a particular compositor.
     */
    public abstract class ShellApplication : Gtk.Application {

        /**
         * Creates a new Singularity shell application.
         *
         * @param app_id  Reverse-DNS application ID.
         * @param flags   GLib application flags; defaults to none.
         */
        protected ShellApplication(string app_id, ApplicationFlags flags = ApplicationFlags.FLAGS_NONE) {
            Object(application_id: app_id, flags: flags);
        }

        protected override void startup() {
            base.startup();
            // Pin the brand GTK and icon themes once, after Gtk.init. The notify
            // guards inside keep them pinned for the lifetime of the shell.
            Singularity.Style.StyleManager.pin_brand_themes();
        }
    }
}
