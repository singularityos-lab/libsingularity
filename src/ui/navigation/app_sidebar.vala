using Gtk;

namespace Singularity.Widgets {

    /**
     * A standard navigation sidebar for Singularity apps.
     *
     * Wraps a ScrolledWindow → Box(navigation-sidebar) — the canonical
     * pattern used by Files, Photos, and Store. Use this instead of
     * rolling the pattern by hand in each app.
     *
     * The inner content box is exposed via the `box` property so callers
     * can append rows, buttons, separators, and SidebarSectionLabels.
     *
     * Default width: 200 px (override with `set_size_request`).
     *
     * Example:
     * {{{
     *   var sidebar = new AppSidebar();
     *   sidebar.box.append(new SidebarSectionLabel("Places"));
     *   sidebar.box.append(make_row("Home", "user-home-symbolic"));
     *   root.append(sidebar);
     * }}}
     */
    public class AppSidebar : ScrolledWindow {

        /** The inner navigation-sidebar box. Append your rows here. */
        public Box box { get; private set; }

        /**
         * Creates a new AppSidebar with default 200 px width.
         *
         * @param width Preferred width in pixels (default 200).
         */
        public AppSidebar(int width = 200) {
            Object();
            hscrollbar_policy = PolicyType.NEVER;
            vscrollbar_policy = PolicyType.AUTOMATIC;
            set_size_request(width, -1);

            box = new Box(Orientation.VERTICAL, 2);
            box.add_css_class("navigation-sidebar");
            box.margin_top    = 10;
            box.margin_bottom = 10;
            box.margin_start  = 10;
            box.margin_end    = 10;
            set_child(box);
        }
    }
}
