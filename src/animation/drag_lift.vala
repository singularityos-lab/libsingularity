namespace Singularity.Animation {

    /**
     * Lifts what the user picks up.
     *
     * When a drag starts, the drag icon is a picture of the item that grows
     * to 104 % with a wider shadow over SMALL, while the item left behind
     * dims. When the drag ends, whether it was dropped or refused, the item
     * settles back with the snappy spring. With Reduced Motion only the dim
     * and the shadow change.
     *
     * {{{
     *   var source = new Gtk.DragSource ();
     *   tile.add_controller (source);
     *   Singularity.Animation.DragLift.attach (source, tile);
     * }}}
     */
    public class DragLift : Object {

        public const double LIFT_SCALE = 1.04;
        public const double DIM_OPACITY = 0.45;
        public const int SHADOW_ROOM = 24;

        private const string DATA_KEY = "singularity-drag-lift";

        private MotionBin? _icon_bin = null;
        private double _press_x = -1.0;
        private double _press_y = -1.0;

        public unowned Gtk.DragSource source { get; construct; }

        public unowned Gtk.Widget item { get; construct; }

        public bool use_icon { get; set; default = true; }

        public signal void lifted(MotionBin icon);

        private DragLift(Gtk.DragSource source, Gtk.Widget item) {
            Object(source: source, item: item);
        }

        construct {
            var press = new Gtk.GestureClick();
            press.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            press.button = 0;
            press.pressed.connect((n, x, y) => {
                _press_x = x;
                _press_y = y;
            });
            var anchor = source.get_widget();
            if (anchor != null) anchor.add_controller(press);
            source.drag_begin.connect(on_begin);
            source.drag_end.connect((drag, delete_data) => settle());
            source.drag_cancel.connect((drag, reason) => {
                settle();
                return false;
            });
        }

        public static DragLift attach(Gtk.DragSource source, Gtk.Widget? item = null) {
            var existing = source.get_data<DragLift>(DATA_KEY);
            if (existing != null) return existing;
            var lift = new DragLift(source, item ?? source.get_widget());
            source.set_data<DragLift>(DATA_KEY, lift);
            return lift;
        }

        public static MotionBin build_icon(Gtk.Widget item) {
            var paintable = new Gtk.WidgetPaintable(item);
            var image = paintable.get_current_image();
            var picture = new Gtk.Picture.for_paintable(image);
            picture.can_shrink = false;
            picture.set_size_request(item.get_width(), item.get_height());
            var card = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            card.add_css_class("singularity-drag-lift");
            card.overflow = Gtk.Overflow.HIDDEN;
            card.append(picture);
            var bin = new MotionBin(card);
            bin.margin_top = SHADOW_ROOM;
            bin.margin_bottom = SHADOW_ROOM;
            bin.margin_start = SHADOW_ROOM;
            bin.margin_end = SHADOW_ROOM;
            return bin;
        }

        public static void lift(MotionBin bin) {
            var card = bin.child;
            if (card != null) card.add_css_class("lifted");
            if (Singularity.Motion.reduced()) return;
            Singularity.Motion.tween(bin, "scale", LIFT_SCALE,
                Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.STANDARD);
        }

        private void on_begin(Gdk.Drag drag) {
            Singularity.Motion.tween(item, "opacity", DIM_OPACITY,
                Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.STANDARD);
            if (!use_icon || item.get_width() <= 0) return;
            var bin = build_icon(item);
            _icon_bin = bin;
            var icon = Gtk.DragIcon.get_for_drag(drag) as Gtk.DragIcon;
            if (icon == null) return;
            icon.child = bin;
            double x = _press_x, y = _press_y;
            if (x < 0 || y < 0) {
                x = item.get_width() / 2.0;
                y = item.get_height() / 2.0;
            }
            var anchor = source.get_widget();
            if (anchor != null && anchor != item) {
                Graphene.Point point;
                if (anchor.compute_point(item, Graphene.Point() { x = (float) x, y = (float) y }, out point)) {
                    x = point.x;
                    y = point.y;
                }
            }
            drag.set_hotspot((int) x + SHADOW_ROOM, (int) y + SHADOW_ROOM);
            lift(bin);
            lifted(bin);
        }

        private void settle() {
            _icon_bin = null;
            Singularity.Motion.tween(item, "opacity", 1.0,
                Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.STANDARD);
            if (Singularity.Motion.reduced() || !item.get_mapped()) return;
            var bin = Singularity.Motion.motion_bin_for(item);
            if (bin != null) {
                bin.scale = LIFT_SCALE;
                Singularity.Motion.spring_to(bin, "scale", 1.0, Singularity.Motion.Spring.SNAPPY);
                return;
            }
            var transform = ChildTransform.for_widget(item, place_in_parent(item));
            transform.scale_x = LIFT_SCALE;
            transform.scale_y = LIFT_SCALE;
            Singularity.Motion.spring_to(transform, "scale-x", 1.0, Singularity.Motion.Spring.SNAPPY, double.NAN, item);
            Singularity.Motion.spring_to(transform, "scale-y", 1.0, Singularity.Motion.Spring.SNAPPY, double.NAN, item);
        }

        public static ChildPlacement place_in_parent(Gtk.Widget child) {
            var parent = child.get_parent();
            Graphene.Rect bounds = Graphene.Rect();
            bool known = parent != null && child.compute_bounds(parent, out bounds);
            int margin_x = child.margin_start + child.margin_end;
            int margin_y = child.margin_top + child.margin_bottom;
            double left = bounds.get_x() - child.margin_start;
            double top = bounds.get_y() - child.margin_top;
            int width = (int) Math.round(bounds.get_width()) + margin_x;
            int height = (int) Math.round(bounds.get_height()) + margin_y;
            return (out w, out h, out x, out y) => {
                if (known) {
                    w = width;
                    h = height;
                    x = left;
                    y = top;
                } else {
                    w = child.get_width();
                    h = child.get_height();
                    x = 0.0;
                    y = 0.0;
                }
            };
        }
    }
}
