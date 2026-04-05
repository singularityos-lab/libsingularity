using Gtk;
using GLib;

namespace Singularity.Widgets {

    /**
     * Floating address-bar pill shown at the top-centre of the browser
     * when the toolbar is hidden or scrolled out of view.
     *
     * Displays the current page domain with a security icon and reload button.
     * Call `update_from_uri()` to refresh displayed information when the page URL changes.
     */
    public class BrowserPill : Gtk.Box {
        private Gtk.Image security_icon;
        private Gtk.Label domain_label;
        private Gtk.Button reload_btn;

        /** Emitted when the user clicks the reload button. */
        public signal void reload_requested ();

        /**
         * Creates a new browser pill widget.
         */
        public BrowserPill () {
            Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 6);
            add_css_class ("browser-pill");
            add_css_class ("pill-hidden");
            halign = Gtk.Align.CENTER;
            valign = Gtk.Align.START;
            margin_top = 8;

            security_icon = new Gtk.Image.from_icon_name ("channel-secure-symbolic");
            security_icon.pixel_size = 14;
            security_icon.add_css_class ("secure");
            append (security_icon);

            domain_label = new Gtk.Label ("New Tab");
            append (domain_label);

            reload_btn = new Gtk.Button.from_icon_name ("view-refresh-symbolic");
            reload_btn.add_css_class ("flat");
            reload_btn.tooltip_text = "Reload";
            reload_btn.clicked.connect (() => reload_requested ());
            append (reload_btn);
        }

        /**
         * Updates the pill to reflect the given URI.
         *
         * Parses the URI to extract the hostname and sets the security icon
         * to secure (HTTPS) or insecure (HTTP/other).  Passing `null` or an
         * internal URI (e.g. `"about:blank"`) resets the pill to "New Tab".
         *
         * @param uri The page URI, or `null` to reset.
         */
        public void update_from_uri (string? uri) {
            if (uri == null || uri == "" || uri.has_prefix ("about:") || uri.has_prefix ("singularity:")) {
                domain_label.label = "New Tab";
                security_icon.icon_name = "channel-secure-symbolic";
                security_icon.remove_css_class ("insecure");
                security_icon.add_css_class ("secure");
                return;
            }
            try {
                var parsed = GLib.Uri.parse (uri, GLib.UriFlags.NONE);
                string host = parsed.get_host () ?? uri;
                if (host.has_prefix ("www.")) host = host.substring (4);
                domain_label.label = host;
                if (parsed.get_scheme () == "https") {
                    security_icon.icon_name = "channel-secure-symbolic";
                    security_icon.remove_css_class ("insecure");
                    security_icon.add_css_class ("secure");
                } else {
                    security_icon.icon_name = "channel-insecure-symbolic";
                    security_icon.remove_css_class ("secure");
                    security_icon.add_css_class ("insecure");
                }
            } catch (Error e) {
                domain_label.label = uri.length > 40 ? uri.substring (0, 40) + "\xe2\x80\xa6" : uri;
                security_icon.icon_name = "channel-insecure-symbolic";
                security_icon.remove_css_class ("secure");
                security_icon.add_css_class ("insecure");
            }
        }
    }

}
