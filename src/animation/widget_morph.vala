namespace Singularity.Animation {

    /**
     * Shared-element motion for a widget that a container owns, such as a
     * photo viewer laid over a grid.
     *
     * `grow()` makes the widget start exactly on a rectangle, a thumbnail
     * for example, and grow into its own place with the gentle spring.
     * `shrink()` sends it back into the rectangle over LARGE with the
     * standard curve while it fades. `content` is the part of the widget
     * that shows the element, such as the picture inside a letterboxed
     * `Gtk.Picture`; the element keeps its proportions on the way. With
     * Reduced Motion both are short fades.
     */
    public class WidgetMorph : Object {

        public static Graphene.Rect contain(double width, double height, double content_width, double content_height) {
            var rect = Graphene.Rect();
            if (width <= 0 || height <= 0 || content_width <= 0 || content_height <= 0) {
                rect.init(0, 0, (float) width, (float) height);
                return rect;
            }
            double scale = double.min(width / content_width, height / content_height);
            double w = content_width * scale;
            double h = content_height * scale;
            rect.init((float) ((width - w) / 2.0), (float) ((height - h) / 2.0), (float) w, (float) h);
            return rect;
        }

        public static bool transform_for(Graphene.Rect widget_bounds, Graphene.Rect content, Graphene.Rect target,
                                         out double translate_x, out double translate_y, out double scale) {
            translate_x = 0.0;
            translate_y = 0.0;
            scale = 1.0;
            if (content.get_width() <= 0 || content.get_height() <= 0) return false;
            scale = double.min(target.get_width() / content.get_width(), target.get_height() / content.get_height());
            double content_cx = content.get_x() + content.get_width() / 2.0;
            double content_cy = content.get_y() + content.get_height() / 2.0;
            double target_cx = target.get_x() + target.get_width() / 2.0;
            double target_cy = target.get_y() + target.get_height() / 2.0;
            translate_x = target_cx - widget_bounds.get_x() - scale * content_cx;
            translate_y = target_cy - widget_bounds.get_y() - scale * content_cy;
            return true;
        }

        private static ChildTransform? prepare(Gtk.Widget widget, Graphene.Rect rect, Gtk.Widget relative_to,
                                              Graphene.Rect? content, out double tx, out double ty, out double s) {
            tx = 0.0;
            ty = 0.0;
            s = 1.0;
            var existing = ChildTransform.lookup(widget);
            if (existing != null) existing.reset_transform();
            Graphene.Rect bounds;
            if (!widget.compute_bounds(relative_to, out bounds)) return null;
            var inner = content ?? Graphene.Rect() { origin = { 0, 0 }, size = { bounds.get_width(), bounds.get_height() } };
            if (!transform_for(bounds, inner, rect, out tx, out ty, out s)) return null;
            var transform = ChildTransform.for_widget(widget, DragLift.place_in_parent(widget));
            transform.origin_x = 0.0;
            transform.origin_y = 0.0;
            return transform;
        }

        public static AnimationGroup grow(Gtk.Widget widget, Graphene.Rect rect, Gtk.Widget relative_to,
                                          Graphene.Rect? content = null) {
            var group = new AnimationGroup(GroupMode.PARALLEL);
            widget.opacity = 0.0;
            group.add(Singularity.Motion.tween(widget, "opacity", 1.0,
                Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.LINEAR));
            double tx = 0.0, ty = 0.0, s = 1.0;
            var transform = Singularity.Motion.reduced() ? null
                : prepare(widget, rect, relative_to, content, out tx, out ty, out s);
            if (transform != null) {
                transform.translate_x = tx;
                transform.translate_y = ty;
                transform.scale_x = s;
                transform.scale_y = s;
                string[] properties = { "translate-x", "translate-y", "scale-x", "scale-y" };
                double[] targets = { 0.0, 0.0, 1.0, 1.0 };
                for (int i = 0; i < properties.length; i++) {
                    group.add(Singularity.Motion.spring_to(transform, properties[i], targets[i],
                        Singularity.Motion.Spring.GENTLE, double.NAN, widget));
                }
            }
            group.play();
            return group;
        }

        public static AnimationGroup shrink(Gtk.Widget widget, Graphene.Rect rect, Gtk.Widget relative_to,
                                            Graphene.Rect? content = null) {
            var group = new AnimationGroup(GroupMode.PARALLEL);
            double tx = 0.0, ty = 0.0, s = 1.0;
            var transform = Singularity.Motion.reduced() ? null
                : prepare(widget, rect, relative_to, content, out tx, out ty, out s);
            if (transform == null) {
                group.add(Singularity.Motion.tween(widget, "opacity", 0.0,
                    Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.LINEAR));
                group.play();
                return group;
            }
            string[] properties = { "translate-x", "translate-y", "scale-x", "scale-y" };
            double[] targets = { tx, ty, s, s };
            for (int i = 0; i < properties.length; i++) {
                group.add(Singularity.Motion.tween(transform, properties[i], targets[i],
                    Singularity.Motion.Duration.LARGE, Singularity.Motion.Curve.STANDARD, widget));
            }
            group.add(Singularity.Motion.tween(widget, "opacity", 0.0,
                Singularity.Motion.Duration.LARGE, Singularity.Motion.Curve.EXIT));
            group.done.connect(() => {
                transform.reset_transform();
                widget.opacity = 1.0;
            });
            group.play();
            return group;
        }
    }
}
