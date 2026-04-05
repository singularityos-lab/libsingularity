using Gtk;

namespace Singularity.Widgets {

    /**
     * A standalone preferences window for Singularity apps.
     *
     * Wraps any Gtk.Widget (typically a Gtk.Box containing
     * PreferencesGroup instances) in a scrollable, consistently styled
     * window.
     */
    public class PreferencesWindow : Gtk.Window {

        /**
         * Creates a preferences window wrapping `preferences_page`.
         *
         * @param app              The owning application.
         * @param preferences_page Widget to display as the preferences content.
         */
        public PreferencesWindow(Gtk.Application app, Gtk.Widget preferences_page) {
            Object(application: app);
            add_css_class("singularity");
            add_css_class("singularity-app");
            add_css_class("preferences-window");

            set_default_size(560, 480);
            resizable = true;

            var outer = new Box(Orientation.VERTICAL, 0);
            set_child(outer);

            var header = new HeaderBar();
            header.add_css_class("preferences-headerbar");
            outer.append(header);

            var scrolled = new ScrolledWindow();
            scrolled.hscrollbar_policy = PolicyType.NEVER;
            scrolled.vscrollbar_policy = PolicyType.AUTOMATIC;
            scrolled.vexpand = true;
            scrolled.hexpand = true;
            scrolled.set_child(preferences_page);
            outer.append(scrolled);
        }
    }
}
