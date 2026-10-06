namespace Singularity.Animation {

    public enum PageDirection {
        AUTO,
        FORWARD,
        BACK
    }

    /**
     * Direction-aware page changes for a `Gtk.Stack`.
     *
     * The new page enters from 24 px on the side it comes from while it fades
     * in: a page further down the stack comes from the right, going back
     * comes from the left. The slide takes PAGE with the standard curve and
     * the fade MEDIUM. With Reduced Motion only the fade is left.
     */
    public class PageTransition : Object {

        public const double DISTANCE = 24.0;

        private const string DATA_KEY = "singularity-page-transition";
        private const string SKIP_KEY = "singularity-page-transition-skip";

        private Gtk.Widget? _current = null;
        private Gtk.Widget? _animating = null;
        private PageDirection _next = PageDirection.AUTO;
        private ulong _handler = 0;

        public unowned Gtk.Stack stack { get; construct; }

        public bool enabled { get; set; default = true; }

        public signal void started(Gtk.Widget page, PageDirection direction);

        private PageTransition(Gtk.Stack stack) {
            Object(stack: stack);
        }

        construct {
            stack.transition_type = Gtk.StackTransitionType.NONE;
            _current = stack.visible_child;
            _handler = stack.notify["visible-child"].connect(on_visible_child);
        }

        public static PageTransition attach(Gtk.Stack stack) {
            var existing = stack.get_data<PageTransition>(DATA_KEY);
            if (existing != null) return existing;
            var transition = new PageTransition(stack);
            stack.set_data<PageTransition>(DATA_KEY, transition);
            return transition;
        }

        public static PageTransition? lookup(Gtk.Stack stack) {
            return stack.get_data<PageTransition>(DATA_KEY);
        }

        public static void exclude(Gtk.Stack stack) {
            stack.set_data<bool>(SKIP_KEY, true);
        }

        public static bool is_excluded(Gtk.Stack stack) {
            return stack.get_data<bool>(SKIP_KEY);
        }

        public static bool is_page_like(Gtk.StackTransitionType type) {
            switch (type) {
                case Gtk.StackTransitionType.CROSSFADE:
                case Gtk.StackTransitionType.SLIDE_LEFT_RIGHT:
                case Gtk.StackTransitionType.SLIDE_LEFT:
                case Gtk.StackTransitionType.SLIDE_RIGHT:
                case Gtk.StackTransitionType.OVER_LEFT_RIGHT:
                case Gtk.StackTransitionType.UNDER_LEFT:
                case Gtk.StackTransitionType.UNDER_RIGHT:
                case Gtk.StackTransitionType.OVER_LEFT:
                case Gtk.StackTransitionType.OVER_RIGHT:
                    return true;
                default:
                    return false;
            }
        }

        public void forward() {
            _next = PageDirection.FORWARD;
        }

        public void back() {
            _next = PageDirection.BACK;
        }

        public static int page_index(Gtk.Stack stack, Gtk.Widget? page) {
            if (page == null) return -1;
            int index = 0;
            for (var child = stack.get_first_child(); child != null; child = child.get_next_sibling()) {
                if (child == page) return index;
                index++;
            }
            return -1;
        }

        public static PageDirection direction_between(int from_index, int to_index) {
            if (from_index < 0 || to_index < 0) return PageDirection.FORWARD;
            return to_index >= from_index ? PageDirection.FORWARD : PageDirection.BACK;
        }

        private void on_visible_child() {
            var previous = _current;
            var page = stack.visible_child;
            _current = page;
            var hint = _next;
            _next = PageDirection.AUTO;
            if (page == null || page == previous) return;
            finish_running();
            if (!enabled || previous == null || !stack.get_mapped()) return;
            var direction = hint != PageDirection.AUTO ? hint
                : direction_between(page_index(stack, previous), page_index(stack, page));
            animate(page, direction);
        }

        private void finish_running() {
            if (_animating == null) return;
            var page = _animating;
            _animating = null;
            Singularity.Motion.cancel(page, "opacity");
            page.opacity = 1.0;
            var transform = ChildTransform.lookup(page);
            if (transform != null) {
                Singularity.Motion.cancel(transform, "translate-x");
                transform.reset_transform();
            }
        }

        private void animate(Gtk.Widget page, PageDirection direction) {
            _animating = page;
            started(page, direction);
            page.opacity = 0.0;
            var fade = Singularity.Motion.tween(page, "opacity", 1.0,
                Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER, stack);
            fade.done.connect(() => {
                if (_animating == page && ChildTransform.lookup(page) == null) _animating = null;
            });
            if (Singularity.Motion.reduced()) return;
            var transform = ChildTransform.for_widget(page, (out width, out height, out x, out y) => {
                width = stack.get_width();
                height = stack.get_height();
                x = 0.0;
                y = 0.0;
            });
            transform.translate_x = direction == PageDirection.BACK ? -DISTANCE : DISTANCE;
            var slide = Singularity.Motion.tween(transform, "translate-x", 0.0,
                Singularity.Motion.Duration.PAGE, Singularity.Motion.Curve.STANDARD, stack);
            slide.done.connect(() => {
                if (_animating == page) _animating = null;
            });
        }
    }
}
