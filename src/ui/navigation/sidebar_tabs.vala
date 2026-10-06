using Gtk;

namespace Singularity.Widgets {

    public const int BUBBLE_BAND_HEIGHT = 52;
    public const int STATIC_BAND_HEIGHT = 8;

    public bool has_floating_bubbles (Widget widget) {
        var root = widget.get_root () as Singularity.Widgets.Window;
        return root != null && root.floating_bubbles;
    }

    public void apply_bubble_inset (Widget widget, int floating = BUBBLE_BAND_HEIGHT, int classic = STATIC_BAND_HEIGHT) {
        widget.set_data<int> ("singularity-bubble-inset-floating", floating);
        widget.set_data<int> ("singularity-bubble-inset-classic", classic);
        if (widget.get_root () != null) {
            widget.margin_top = has_floating_bubbles (widget) ? floating : classic;
        }
        if (widget.get_data<bool> ("singularity-bubble-inset-installed")) return;
        widget.set_data<bool> ("singularity-bubble-inset-installed", true);
        widget.realize.connect (() => {
            widget.margin_top = has_floating_bubbles (widget)
                ? widget.get_data<int> ("singularity-bubble-inset-floating")
                : widget.get_data<int> ("singularity-bubble-inset-classic");
        });
    }

    public class SidebarTabs : BubbleSwitcher {
        private bool _reserve = false;

        public bool reserve_bubble_band {
            get { return _reserve; }
            set {
                _reserve = value;
                if (value) apply_bubble_inset (this);
                else apply_bubble_inset (this, 0, 0);
            }
        }

        public SidebarTabs (Stack? stack = null) {
            Object (orientation: Orientation.HORIZONTAL, spacing: 0);
            if (stack != null) set_stack (stack);
        }

        construct {
            add_css_class ("sidebar-tabs");
            homogeneous = true;
            hexpand = true;
            halign = Align.FILL;
            margin_bottom = 8;
        }
    }
}
