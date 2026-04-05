using Gtk;

namespace Singularity.Widgets {

    /**
     * A Box widget that shows a floating action bar at the top-right
     * corner when the user hovers over it.
     *
     * Apps supply their own buttons via `add_control()`; the hover
     * behaviour, pill styling and CSS transitions are all built-in.
     */
    public class HoverControls : Box {

        private Overlay overlay;
        private Box controls_box;

        public HoverControls() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            hexpand = true;
            vexpand = true;

            overlay = new Overlay();
            overlay.hexpand = true;
            overlay.vexpand = true;
            overlay.add_css_class("singularity-hover-overlay");

            controls_box = new Box(Orientation.HORIZONTAL, 4);
            controls_box.halign = Align.END;
            controls_box.valign = Align.START;
            controls_box.margin_top = 10;
            controls_box.margin_end = 10;
            controls_box.add_css_class("singularity-hover-controls");

            overlay.add_overlay(controls_box);
            append(overlay);
        }

        /**
         * Set the main content widget displayed beneath the controls.
         */
        public void set_content(Widget w) {
            overlay.set_child(w);
        }

        /**
         * Append a widget to the floating control bar.
         * The "singularity-hover-btn" CSS class is added automatically.
         */
        public void add_control(Widget w) {
            w.add_css_class("singularity-hover-btn");
            if (w is Button) {
                ((Button) w).add_css_class("flat");
                w.set_size_request(28, 28);
            }
            controls_box.append(w);
        }

        /**
         * Append a thin vertical separator between control groups.
         */
        public void add_separator() {
            var sep = new Box(Orientation.HORIZONTAL, 0);
            sep.add_css_class("singularity-hover-sep");
            controls_box.append(sep);
        }
    }
}
