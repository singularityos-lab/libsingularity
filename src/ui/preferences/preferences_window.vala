using Gtk;

namespace Singularity.Widgets {

    /**
     * Standalone preferences dialog for Singularity apps. Built on top of
     * `AppDialog` so the chrome (titlebar, modal handling, theming) is
     * the same one used everywhere else (file properties dialog, etc).
     */
    public class PreferencesWindow : Singularity.Widgets.AppDialog {

        /**
         * @param app              The owning application.
         * @param preferences_page Widget to display (usually a `PreferencesPage`).
         * @param use_modal        Modal by default; pass false for floating.
         */
        public PreferencesWindow(Gtk.Application app,
                                 Gtk.Widget preferences_page,
                                 bool use_modal = true) {
            base(app, use_modal);
            add_css_class("preferences-window");
            set_title("Preferences");
            set_default_size(560, 520);

            var scrolled = new ScrolledWindow();
            scrolled.hscrollbar_policy = PolicyType.NEVER;
            scrolled.vscrollbar_policy = PolicyType.AUTOMATIC;
            scrolled.vexpand = true;
            scrolled.hexpand = true;
            scrolled.set_child(preferences_page);

            content_box.append(scrolled);
        }
    }
}
