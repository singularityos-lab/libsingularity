using Gtk;

namespace Singularity.Widgets {

    /**
     * Dialog presenting an application: icon, name, version, description
     * and a Project group with the website, license and credits.
     *
     * Rows and labels whose value is null or empty are left out.
     * Singularity.Application.show_about opens one filled from the
     * application's `about_*` properties.
     */
    public class AboutDialog : AppDialog {

        /**
         * @param app         Owning application.
         * @param icon        Icon name of the application.
         * @param name        Human-readable application name.
         * @param version     Version string, e.g. `"1.0.0"`.
         * @param description One-line description of the application.
         * @param website     Project website URI.
         * @param license     Human-readable license name.
         * @param credits     Credits line, e.g. data providers.
         */
        public AboutDialog(Gtk.Application app,
                           string icon,
                           string name,
                           string? version = null,
                           string? description = null,
                           string? website = null,
                           string? license = null,
                           string? credits = null) {
            base(app, true);
            set_title(_("About %s").printf(name));
            set_default_size(400, -1);

            var body = new Box(Orientation.VERTICAL, 10);
            body.margin_top = 12;
            body.margin_bottom = 20;
            body.margin_start = 24;
            body.margin_end = 24;

            var image = new Image.from_icon_name(icon);
            image.pixel_size = 96;
            body.append(image);

            var title = new Label(name);
            title.add_css_class("title-1");
            body.append(title);

            if (version != null && version != "") {
                var ver = new Label(_("Version %s").printf(version));
                ver.add_css_class("dim-label");
                body.append(ver);
            }

            if (description != null && description != "") {
                var desc = new Label(description);
                desc.wrap = true;
                desc.justify = Justification.CENTER;
                desc.max_width_chars = 40;
                body.append(desc);
            }

            var group = new PreferencesGroup(_("Project"));
            group.margin_top = 8;
            bool has_rows = false;
            if (website != null && website != "") {
                var site = new ActionRow(_("Website"), website);
                var open = new Button.from_icon_name("web-browser-symbolic");
                open.add_css_class("flat");
                open.valign = Align.CENTER;
                open.tooltip_text = _("Open Website");
                open.clicked.connect(() => new UriLauncher(website).launch.begin(this, null));
                site.add_suffix(open);
                group.add_row(site);
                has_rows = true;
            }
            if (license != null && license != "") {
                group.add_row(new ActionRow(_("License"), license));
                has_rows = true;
            }
            if (credits != null && credits != "") {
                group.add_row(new ActionRow(_("Credits"), credits));
                has_rows = true;
            }
            if (has_rows) body.append(group);

            content_box.append(body);
        }
    }
}
