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
     *   sidebar.box.append(new ToolbarSpacer.with_height(70));
     *   sidebar.box.append(new Button.with_label("Home"));
     *   window.set_sidebar(sidebar);
     * }}}
     */
    public class AppSidebar : Box {

        /** The inner content box. Append your rows here. */
        public Box box { get; private set; }

        internal ScrolledWindow _scroll;

        /**
         * Creates a new AppSidebar with default 200 px width.
         *
         * @param width Preferred width in pixels (default 200).
         */
        public AppSidebar(int width = 200) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);

            _scroll = new ScrolledWindow();
            _scroll.set_size_request(width, -1);
            _scroll.hscrollbar_policy = PolicyType.NEVER;
            _scroll.vscrollbar_policy = PolicyType.AUTOMATIC;
            _scroll.vexpand = true;

            box = new Box(Orientation.VERTICAL, 2);
            box.add_css_class("navigation-sidebar");
            box.margin_top = 10;
            box.margin_bottom = 10;
            box.margin_start = 10;
            box.margin_end = 10;

            _scroll.set_child(box);
            append(_scroll);
        }
    }
}