using Gtk;

namespace Singularity.Widgets {

    public enum SwipeEdge {
        LEADING,
        TRAILING
    }

    public enum SwipeStyle {
        NEUTRAL,
        ACCENT,
        WARNING,
        DESTRUCTIVE;

        public string css_class() {
            switch (this) {
                case ACCENT: return "accent";
                case WARNING: return "warning";
                case DESTRUCTIVE: return "destructive";
                default: return "neutral";
            }
        }
    }

    public class SwipeAction : Object {
        public string label { get; set; }
        public string icon_name { get; set; }
        public SwipeStyle style { get; set; default = SwipeStyle.NEUTRAL; }

        public signal void activated();

        public SwipeAction(string label, string icon_name, SwipeStyle style = SwipeStyle.NEUTRAL) {
            Object(label: label, icon_name: icon_name, style: style);
        }
    }

    internal class SwipeSurface : Widget {
        public Widget content { get; construct; }
        public Box leading { get; construct; }
        public Box trailing { get; construct; }

        private double _offset = 0.0;

        public double offset {
            get { return _offset; }
            set {
                if (_offset == value) return;
                _offset = value;
                queue_allocate();
            }
        }

        public SwipeSurface(Widget content) {
            var leading = new Box(Orientation.HORIZONTAL, 0);
            leading.homogeneous = true;
            leading.add_css_class("swipe-actions");
            leading.add_css_class("leading");
            var trailing = new Box(Orientation.HORIZONTAL, 0);
            trailing.homogeneous = true;
            trailing.add_css_class("swipe-actions");
            trailing.add_css_class("trailing");
            Object(content: content, leading: leading, trailing: trailing);
        }

        construct {
            overflow = Overflow.HIDDEN;
            leading.set_parent(this);
            trailing.set_parent(this);
            content.set_parent(this);
            content.add_css_class("swipe-content");
        }

        public override void dispose() {
            leading.unparent();
            trailing.unparent();
            content.unparent();
            base.dispose();
        }

        public override SizeRequestMode get_request_mode() {
            return content.get_request_mode();
        }

        public override void measure(Orientation orientation, int for_size, out int minimum, out int natural,
                                     out int minimum_baseline, out int natural_baseline) {
            content.measure(orientation, for_size, out minimum, out natural, out minimum_baseline, out natural_baseline);
        }

        public override void size_allocate(int width, int height, int baseline) {
            int lead = (int) Math.round(double.max(0.0, _offset));
            int trail = (int) Math.round(double.max(0.0, -_offset));
            leading.visible = lead > 0;
            trailing.visible = trail > 0;
            if (lead > 0) {
                int min, nat;
                leading.measure(Orientation.HORIZONTAL, height, out min, out nat, null, null);
                leading.allocate(int.max(lead, min), height, -1, null);
            }
            if (trail > 0) {
                int min, nat;
                trailing.measure(Orientation.HORIZONTAL, height, out min, out nat, null, null);
                int w = int.max(trail, min);
                var at = new Gsk.Transform().translate(Graphene.Point() { x = width - w, y = 0 });
                trailing.allocate(w, height, -1, at);
            }
            var shift = new Gsk.Transform().translate(Graphene.Point() { x = (float) _offset, y = 0 });
            content.allocate(width, height, baseline, shift);
        }
    }

    internal class RowSwipe : Object {
        private const double BUTTON_WIDTH = 76.0;
        private const double START_DISTANCE = 12.0;
        private const double FULL_FRACTION = 0.6;
        private const double FLING_VELOCITY = 1600.0;
        private const double RUBBER = 0.35;

        private static unowned RowSwipe? open_row = null;

        private unowned ListBoxRow row;
        private SwipeSurface surface;
        private Gee.ArrayList<SwipeAction> leading_actions = new Gee.ArrayList<SwipeAction>();
        private Gee.ArrayList<SwipeAction> trailing_actions = new Gee.ArrayList<SwipeAction>();
        private GestureDrag drag;
        private Singularity.Animation.AnchoredDrag travel;
        private Singularity.Animation.SpringAnimation? tracker = null;
        private bool tracking = false;
        private double origin = 0.0;
        private bool full = false;

        public bool menu_enabled { get; set; default = true; }

        public RowSwipe(ListBoxRow row) {
            this.row = row;
            var content = row.get_child();
            row.set_child(null);
            surface = new SwipeSurface(content);
            row.set_child(surface);
            row.add_css_class("swipeable");
            row.overflow = Overflow.HIDDEN;

            drag = new GestureDrag();
            travel = Singularity.Animation.AnchoredDrag.attach(drag);
            drag.propagation_phase = PropagationPhase.CAPTURE;
            update_touch_only();
            drag.drag_begin.connect(() => {
                tracking = false;
                update_touch_only();
            });
            drag.drag_update.connect(() => on_update(travel.travel_x, travel.travel_y));
            drag.drag_end.connect(() => on_end());
            drag.cancel.connect(() => {
                if (tracking) settle(0.0, 0.0);
                tracking = false;
            });
            row.add_controller(drag);

            var tap = new GestureClick();
            tap.propagation_phase = PropagationPhase.CAPTURE;
            tap.released.connect((n, x, y) => {
                if (surface.offset == 0.0 || tracking) return;
                if (inside_actions(x, y)) return;
                tap.set_state(EventSequenceState.CLAIMED);
                close();
            });
            row.add_controller(tap);

            var context = new GestureClick();
            context.button = Gdk.BUTTON_SECONDARY;
            context.pressed.connect((n, x, y) => {
                if (!menu_enabled || (leading_actions.size == 0 && trailing_actions.size == 0)) return;
                context.set_state(EventSequenceState.CLAIMED);
                show_menu(x, y);
            });
            row.add_controller(context);

            var keys = new ShortcutController();
            keys.add_shortcut(new Shortcut(ShortcutTrigger.parse_string("<Shift>F10|Menu"),
                new CallbackAction(() => {
                    if (!menu_enabled || (leading_actions.size == 0 && trailing_actions.size == 0)) return false;
                    show_menu(row.get_width() / 2.0, row.get_height() / 2.0);
                    return true;
                })));
            row.add_controller(keys);
        }

        private void update_touch_only() {
            drag.touch_only = !Singularity.FormFactor.get_default().kind.is_touch_first();
        }

        public void add(SwipeEdge edge, SwipeAction action) {
            var list = edge == SwipeEdge.LEADING ? leading_actions : trailing_actions;
            list.add(action);
            rebuild(edge);
        }

        public void clear() {
            close_now();
            leading_actions.clear();
            trailing_actions.clear();
            rebuild(SwipeEdge.LEADING);
            rebuild(SwipeEdge.TRAILING);
        }

        public void append_to(ContextMenu menu) {
            foreach (var a in leading_actions) {
                var action = a;
                menu.add_item(action.label, action.icon_name, () => action.activated(),
                    action.style == SwipeStyle.DESTRUCTIVE ? "destructive" : null);
            }
            foreach (var a in trailing_actions) {
                var action = a;
                menu.add_item(action.label, action.icon_name, () => action.activated(),
                    action.style == SwipeStyle.DESTRUCTIVE ? "destructive" : null);
            }
        }

        private void show_menu(double x, double y) {
            var menu = new ContextMenu(row);
            menu.set_pointing_to(Gdk.Rectangle() { x = (int) x, y = (int) y, width = 1, height = 1 });
            append_to(menu);
            menu.popup();
        }

        private void rebuild(SwipeEdge edge) {
            var box = edge == SwipeEdge.LEADING ? surface.leading : surface.trailing;
            var list = edge == SwipeEdge.LEADING ? leading_actions : trailing_actions;
            for (Widget? c = box.get_first_child(); c != null; c = box.get_first_child()) box.remove(c);
            var ordered = new Gee.ArrayList<SwipeAction>();
            ordered.add_all(list);
            if (edge == SwipeEdge.TRAILING) {
                ordered.clear();
                for (int i = list.size - 1; i >= 0; i--) ordered.add(list[i]);
            }
            foreach (var a in ordered) {
                var action = a;
                var button = new Button();
                button.add_css_class("swipe-action");
                button.add_css_class(action.style.css_class());
                button.tooltip_text = action.label;
                var inner = new Box(Orientation.VERTICAL, 4);
                inner.halign = Align.CENTER;
                inner.valign = Align.CENTER;
                var icon = new Image.from_icon_name(action.icon_name);
                inner.append(icon);
                var label = new Label(action.label);
                label.add_css_class("caption");
                label.ellipsize = Pango.EllipsizeMode.END;
                label.max_width_chars = 10;
                inner.append(label);
                button.child = inner;
                button.set_data<SwipeAction>("swipe-action", action);
                button.clicked.connect(() => {
                    close();
                    action.activated();
                });
                box.append(button);
            }
        }

        private Gee.ArrayList<SwipeAction> side(double offset) {
            return offset > 0 ? leading_actions : trailing_actions;
        }

        private double reveal_width(double offset) {
            return side(offset).size * BUTTON_WIDTH;
        }

        private bool inside_actions(double x, double y) {
            double o = surface.offset;
            if (o > 0) return x < o;
            if (o < 0) return x > row.get_width() + o;
            return false;
        }

        private void on_update(double dx, double dy) {
            if (!tracking) {
                if (Math.fabs(dx) < START_DISTANCE || Math.fabs(dx) < Math.fabs(dy) * 1.2) return;
                origin = surface.offset;
                double probe = origin + dx;
                if (origin == 0.0 && side(probe).size == 0) return;
                tracking = true;
                drag.set_state(EventSequenceState.CLAIMED);
                if (open_row != null && open_row != this) open_row.close();
                Singularity.Motion.cancel(surface, "offset");
                tracker = new Singularity.Animation.SpringAnimation(surface, surface.offset, 0.0,
                    Singularity.Motion.Spring.SNAPPY);
                tracker.reduced_mode = Singularity.Animation.ReducedMode.FULL;
            }
            double raw = origin + dx;
            double width = double.max(1.0, row.get_width());
            double value;
            if (side(raw).size == 0) {
                value = raw * RUBBER * 0.3;
            } else {
                value = raw.clamp(-width, width);
            }
            surface.offset = value;
            if (tracker != null) tracker.track(value);
            set_full(Math.fabs(value) >= width * FULL_FRACTION && side(value).size > 0);
        }

        private void set_full(bool value) {
            if (full == value) return;
            full = value;
            foreach (var box in new Box[] { surface.leading, surface.trailing }) {
                Widget? primary = box == surface.leading ? box.get_first_child() : box.get_last_child();
                for (Widget? c = box.get_first_child(); c != null; c = c.get_next_sibling()) {
                    if (c != primary) c.visible = !value;
                }
                if (value) box.add_css_class("full");
                else box.remove_css_class("full");
            }
        }

        private void on_end() {
            if (!tracking) return;
            tracking = false;
            double velocity = tracker != null ? tracker.velocity : 0.0;
            tracker = null;
            double offset = surface.offset;
            var actions = side(offset);
            if (actions.size == 0 || offset == 0.0) {
                settle(0.0, velocity);
                return;
            }
            double reveal = reveal_width(offset);
            bool same_way = (velocity > 0) == (offset > 0);
            bool fling = same_way && Math.fabs(velocity) >= FLING_VELOCITY && Math.fabs(offset) > reveal;
            if (full || fling) {
                commit(offset > 0 ? SwipeEdge.LEADING : SwipeEdge.TRAILING, velocity);
                return;
            }
            if (Math.fabs(offset) >= reveal / 2.0 && !(Math.fabs(velocity) >= FLING_VELOCITY && !same_way)) {
                settle(offset > 0 ? reveal : -reveal, velocity);
                open_row = this;
                return;
            }
            settle(0.0, velocity);
        }

        private void commit(SwipeEdge edge, double velocity) {
            var actions = edge == SwipeEdge.LEADING ? leading_actions : trailing_actions;
            var action = actions[0];
            double width = double.max(1.0, row.get_width());
            set_full(true);
            var anim = Singularity.Motion.spring_to(surface, "offset", edge == SwipeEdge.LEADING ? width : -width,
                Singularity.Motion.Spring.SNAPPY, velocity);
            anim.clamp = true;
            ulong handler = 0;
            handler = anim.done.connect(() => {
                anim.disconnect(handler);
                action.activated();
                close();
            });
        }

        private void settle(double target, double velocity) {
            if (target == 0.0) {
                set_full(false);
                if (open_row == this) open_row = null;
            }
            Singularity.Motion.spring_to(surface, "offset", target, Singularity.Motion.Spring.SNAPPY,
                velocity.is_nan() ? 0.0 : velocity);
        }

        public void close() {
            if (open_row == this) open_row = null;
            set_full(false);
            Singularity.Motion.spring_to(surface, "offset", 0.0, Singularity.Motion.Spring.SNAPPY);
        }

        public void close_now() {
            if (open_row == this) open_row = null;
            Singularity.Motion.cancel(surface, "offset");
            set_full(false);
            surface.offset = 0.0;
        }

        public bool is_open {
            get { return surface.offset != 0.0; }
        }
    }
}
