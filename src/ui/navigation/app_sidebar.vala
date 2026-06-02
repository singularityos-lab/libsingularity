using Gtk;

namespace Singularity.Widgets {

    /**
     * A standard navigation sidebar for Singularity apps.
     *
     * ScrolledWindow -> Box(navigation-sidebar). Append children to
     * `box` to populate the sidebar: buttons, separators, labels, etc.
     *
     * Example:
     * {{{
     *   var sidebar = new AppSidebar();
     *   Singularity.Widgets.apply_titlebar_inset (sidebar.box);
     *   sidebar.box.append(new Button.with_label(_("Home")));
     *   window.set_sidebar(sidebar);
     * }}}
     */
    public class AppSidebar : Box, Gtk.Buildable {

        /** The inner content box. Append your rows here. */
        public Box box { get; private set; }

        internal ScrolledWindow _scroll;
        private int _width = 200;

        /** Preferred width in pixels. Safe to set after construction. */
        public int sidebar_width {
            get { return _width; }
            set {
                _width = value;
                if (_scroll != null) _scroll.set_size_request(_width, -1);
            }
        }

        /**
         * Creates a new AppSidebar with default 200 px width.
         *
         * @param width Preferred width in pixels (default 200).
         */
        public AppSidebar(int width = 200) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            this.sidebar_width = width;
        }

        construct {
            orientation = Orientation.VERTICAL;
            spacing = 0;
            _scroll = new ScrolledWindow();
            _scroll.set_size_request(_width, -1);
            _scroll.hscrollbar_policy = PolicyType.NEVER;
            _scroll.vscrollbar_policy = PolicyType.AUTOMATIC;
            _scroll.vexpand = true;
            // ScrolledWindow draws its own frame by default in GTK4;
            // that gave the AppSidebar a visible inner right border
            // that Files (which uses a raw scroll) doesn't have.
            _scroll.has_frame = false;

            box = new Box(Orientation.VERTICAL, 2);
            box.add_css_class("navigation-sidebar");
            // No own margins: the Window.sidebar_area already supplies
            // the 10px padding gutter via `.window-sidebar` CSS.

            _scroll.set_child(box);
            append(_scroll);
        }

        // Buildable: nested <child> widgets populate the inner content box.
        public void add_child(Gtk.Builder builder, GLib.Object child, string? type) {
            if (child is Widget && box != null) {
                box.append((Widget) child);
            } else {
                base.add_child(builder, child, type);
            }
        }
    }
}