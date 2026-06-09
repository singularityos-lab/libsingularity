using Gtk;

namespace Singularity.Widgets {

    /**
     * Helpers to make content widgets state-aware of the host window's
     * titlebar / bubble strip. Widgets that paint a background spanning
     * the full window (sourceview, list view background, etc.) should
     * call `apply_titlebar_inset` on themselves so the first row of
     * content sits below the strip while the surface itself runs all
     * the way to the top edge. Background continuity = no visible cut
     * line between bg and content.
     *
     * Pattern:
     *
     *   public MyView () {
     *       // ...
     *       Singularity.Widgets.apply_titlebar_inset (this);
     *   }
     *
     * The helper subscribes to the host window's flat / toolbar.visible
     * notifications and re-applies whenever the state changes.
     */
    public const int TITLEBAR_INSET_HEIGHT = 40;

    /**
     * Returns the top inset for the given widget right now. 46 when the
     * host Singularity window is in flat mode and the bubble strip would
     * sit on top; 0 otherwise (SSD, or floating toolbar that already
     * reserves its own space).
     */
    public int titlebar_inset_for (Widget widget) {
        var root = widget.get_root () as Singularity.Widgets.Window;
        if (root == null) return 0;
        if (root.force_ssd) return 0;
        // Flat mode means our bubble strip is on top.
        return root.flat ? TITLEBAR_INSET_HEIGHT : 0;
    }

    /**
     * Binds `widget.margin_top` to follow the host window's titlebar
     * state. The widget is left at margin 0 until the host is realised
     * with a Singularity.Widgets.Window root; then it tracks the strip
     * height. Safe to call multiple times: only the first call wires
     * the subscription.
     */
    public void apply_titlebar_inset (Widget widget) {
        if (widget.get_data<bool> ("singularity-titlebar-inset-installed")) return;
        widget.set_data<bool> ("singularity-titlebar-inset-installed", true);

        widget.realize.connect (() => {
            var root = widget.get_root () as Singularity.Widgets.Window;
            if (root == null) return;
            widget.margin_top = titlebar_inset_for (widget);
            root.notify["flat"].connect (() => {
                widget.margin_top = titlebar_inset_for (widget);
            });
            root.toolbar.notify["visible"].connect (() => {
                widget.margin_top = titlebar_inset_for (widget);
            });
        });
    }

    /**
     * Reserve at the top of a content surface (list, column, process
     * table) that sits directly under the bubble bar. Adds the
     * `singularity-view-edge` class (for the CSS divider and any
     * descendant-padding rules) and pushes the widget down by 55 px
     * in CSD mode so the content does not flow under the bubbles.
     * Zero margin in SSD mode (labwc owns the strip).
     *
     * Pattern:
     *
     *   Singularity.Widgets.apply_view_edge (list_scroll);
     */
    public const int VIEW_EDGE_INSET_HEIGHT = 55;

    public void apply_view_edge (Widget widget) {
        widget.add_css_class ("singularity-view-edge");

        if (widget.get_data<bool> ("singularity-view-edge-installed")) return;
        widget.set_data<bool> ("singularity-view-edge-installed", true);

        widget.realize.connect (() => {
            var root = widget.get_root () as Singularity.Widgets.Window;
            if (root == null) return;
            widget.margin_top = (root.force_ssd || root.legacy_titlebar) ? 0 : VIEW_EDGE_INSET_HEIGHT;
        });
    }
}
