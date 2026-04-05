using Gtk;

namespace Singularity.Widgets {

    // A4 at 96 DPI: 1mm = 3.7795275591px
    public class PageCanvas : Box {
        private Box _outer;
        private Box _page_box;
        private Box _ruler_container;
        private RulerWidget _ruler;
        private const double MM_TO_PX = 3.7795275591;
        private double _page_width_mm   = 210.0;
        private double _left_margin_mm  = 25.4;
        private double _right_margin_mm = 25.4;
        private double _top_margin_mm   = 25.4;
        private double _bottom_margin_mm = 25.4;

        public double page_width_mm {
            get { return _page_width_mm; }
            set { 
                _page_width_mm = value; 
                _ruler.page_width_mm = value;
                update_page_size(); 
            }
        }
        public double left_margin_mm {
            get { return _left_margin_mm; }
            set { 
                _left_margin_mm = value; 
                _ruler.left_margin_mm = value;
                update_content_margins(); 
            }
        }
        public double right_margin_mm {
            get { return _right_margin_mm; }
            set { 
                _right_margin_mm = value; 
                _ruler.right_margin_mm = value;
                update_content_margins(); 
            }
        }

        public signal void margins_changed(double left_mm, double right_mm);

        public PageCanvas() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("write-page-canvas");
            hexpand = true;
            vexpand = true;

            _ruler_container = new Box(Orientation.VERTICAL, 0);
            _ruler_container.add_css_class("write-ruler-container");
            _ruler_container.hexpand = true;
            _ruler = new RulerWidget();
            _ruler.halign = Align.CENTER;
            _ruler.margins_changed.connect((l, r) => {
                _left_margin_mm = l;
                _right_margin_mm = r;
                margins_changed(l, r);
            });
            _ruler_container.append(_ruler);
            append(_ruler_container);

            _outer = new Box(Orientation.VERTICAL, 0);
            _outer.add_css_class("write-canvas-outer");
            _outer.hexpand = true;
            _outer.vexpand = true;

            _page_box = new Box(Orientation.VERTICAL, 0);
            _page_box.add_css_class("write-page");
            _page_box.halign = Align.CENTER;
            _page_box.valign = Align.START;
            _page_box.margin_top = 16;
            _page_box.margin_bottom = 48;
            _outer.append(_page_box);

            append(_outer);
            update_page_size();
            update_content_margins();
        }

        public void set_content_widget(Widget w) {
            var old = _page_box.get_first_child();
            if (old != null) _page_box.remove(old);
            _page_box.append(w);
            update_content_margins();
        }

        public void show_ruler(bool show) {
            _ruler_container.visible = show;
        }

        private void update_page_size() {
            int px_w = (int)(_page_width_mm * MM_TO_PX);
            int px_h = (int)(297.0 * MM_TO_PX); // A4 minimum height
            _page_box.set_size_request(px_w, px_h);
            _ruler.set_size_request(px_w, -1);
        }

        // Widget margins are NOT used - callers should set TextView.left_margin etc.
        // directly so the entire white page surface is clickable/focusable.

        private void update_content_margins() {
            var child = _page_box.get_first_child();
            if (child == null) return;
            child.margin_start  = 0;
            child.margin_end    = 0;
            child.margin_top    = 0;
            child.margin_bottom = 0;
            child.hexpand = true;
            child.vexpand = true;
        }
    }
}
