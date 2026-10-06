namespace Singularity.Widgets {

    public enum SkeletonShape {
        LINE,
        BLOCK,
        CIRCLE
    }

    /**
     * A grey placeholder for content that is still loading.
     *
     * A soft sheen crosses every skeleton of the window together, once every
     * 1200 ms at constant speed. With Reduced Motion the placeholder stays
     * still. When the content is ready, `Skeleton.reveal()` crossfades from
     * the placeholder to it.
     *
     * {{{
     *   var placeholder = Singularity.Widgets.Skeleton.list (5);
     *   stack.add_named (placeholder, "loading");
     *   Singularity.Widgets.Skeleton.reveal (placeholder, content);
     * }}}
     */
    public class Skeleton : Gtk.Widget {

        public const uint SHEEN_PERIOD_MS = 1200;
        public const double BAND = 160.0;

        private uint _tick_id = 0;
        private ulong _motion_handler = 0;

        public SkeletonShape shape { get; construct set; default = SkeletonShape.LINE; }

        public int radius { get; set; default = 6; }

        static construct {
            set_css_name("skeleton");
        }

        public Skeleton(SkeletonShape shape = SkeletonShape.LINE, int width = -1, int height = 14) {
            Object(shape: shape);
            set_size_request(width, height);
            if (width < 0) hexpand = true;
            add_css_class("singularity-skeleton");
            update_property(Gtk.AccessibleProperty.LABEL, _("Loading"), -1);
        }

        construct {
            can_target = false;
            can_focus = false;
            map.connect(sync_tick);
            unmap.connect(stop_tick);
            _motion_handler = Singularity.Motion.get_default().changed.connect(() => {
                sync_tick();
                queue_draw();
            });
        }

        public override void dispose() {
            stop_tick();
            if (_motion_handler != 0) {
                Singularity.Motion.get_default().disconnect(_motion_handler);
                _motion_handler = 0;
            }
            base.dispose();
        }

        public bool animating {
            get { return _tick_id != 0; }
        }

        private void sync_tick() {
            if (!get_mapped() || Singularity.Motion.reduced()) {
                stop_tick();
                return;
            }
            if (_tick_id != 0) return;
            _tick_id = add_tick_callback(() => {
                queue_draw();
                return true;
            });
        }

        private void stop_tick() {
            if (_tick_id == 0) return;
            remove_tick_callback(_tick_id);
            _tick_id = 0;
        }

        public static double sheen_phase(int64 time_us, double scale = 1.0) {
            double period = SHEEN_PERIOD_MS * 1000.0 * (scale > 0.0 ? scale : 1.0);
            double position = time_us % (int64) period;
            if (position < 0) position += period;
            return position / period;
        }

        private int64 current_time() {
            var motion = Singularity.Motion.get_default();
            int64 now = motion.now_for(this);
            return now >= 0 ? now : GLib.get_monotonic_time();
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            float width = get_width();
            float height = get_height();
            if (width <= 0 || height <= 0) return;
            var fg = get_color();
            var base_color = fg;
            base_color.alpha = 0.10f;
            float corner = shape == SkeletonShape.CIRCLE ? float.min(width, height) / 2.0f
                : float.min(radius, height / 2.0f);
            var rect = Graphene.Rect();
            rect.init(0, 0, width, height);
            var rounded = Gsk.RoundedRect();
            rounded.init_from_rect(rect, corner);
            snapshot.push_rounded_clip(rounded);
            snapshot.append_color(base_color, rect);
            if (!Singularity.Motion.reduced()) append_sheen(snapshot, fg, width, height);
            snapshot.pop();
        }

        private void append_sheen(Gtk.Snapshot snapshot, Gdk.RGBA fg, float width, float height) {
            var root = get_root() as Gtk.Widget;
            float span = root != null ? root.get_width() : width;
            float offset = 0.0f;
            if (root != null) {
                Graphene.Point origin;
                if (compute_point(root, Graphene.Point() { x = 0, y = 0 }, out origin)) offset = origin.x;
            }
            double phase = sheen_phase(current_time(), Singularity.Motion.get_default().duration_scale);
            float center = (float) (phase * (span + 2 * BAND) - BAND) - offset;
            var clear = fg;
            clear.alpha = 0.0f;
            var shine = fg;
            shine.alpha = 0.08f;
            Gsk.ColorStop[] stops = {
                Gsk.ColorStop() { offset = 0.0f, color = clear },
                Gsk.ColorStop() { offset = 0.5f, color = shine },
                Gsk.ColorStop() { offset = 1.0f, color = clear }
            };
            var bounds = Graphene.Rect();
            bounds.init(0, 0, width, height);
            Graphene.Point start = { center - (float) BAND / 2.0f, 0 };
            Graphene.Point end = { center + (float) BAND / 2.0f, 0 };
            snapshot.append_linear_gradient(bounds, start, end, stops);
        }

        public static Gtk.Box list(uint rows = 5, bool avatar = true) {
            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 18);
            box.add_css_class("singularity-skeleton-list");
            box.margin_top = 12;
            box.margin_start = 12;
            box.margin_end = 12;
            for (uint i = 0; i < rows; i++) {
                var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 12);
                if (avatar) {
                    var circle = new Skeleton(SkeletonShape.CIRCLE, 40, 40);
                    circle.hexpand = false;
                    circle.valign = Gtk.Align.CENTER;
                    row.append(circle);
                }
                var lines = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
                lines.hexpand = true;
                lines.valign = Gtk.Align.CENTER;
                var title = new Skeleton(SkeletonShape.LINE, -1, 14);
                title.margin_end = (int) (40 + (i * 37) % 90);
                lines.append(title);
                var detail = new Skeleton(SkeletonShape.LINE, -1, 10);
                detail.margin_end = (int) (120 + (i * 53) % 110);
                lines.append(detail);
                row.append(lines);
                box.append(row);
            }
            return box;
        }

        public static Gtk.FlowBox grid(uint count = 8, int tile_width = 160, int tile_height = 120, bool caption = true) {
            var flow = new Gtk.FlowBox();
            flow.add_css_class("singularity-skeleton-grid");
            flow.selection_mode = Gtk.SelectionMode.NONE;
            flow.homogeneous = true;
            flow.column_spacing = 12;
            flow.row_spacing = 12;
            flow.margin_top = 12;
            flow.margin_start = 12;
            flow.margin_end = 12;
            flow.valign = Gtk.Align.START;
            flow.can_target = false;
            for (uint i = 0; i < count; i++) {
                var tile = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
                var block = new Skeleton(SkeletonShape.BLOCK, tile_width, tile_height);
                block.hexpand = false;
                block.radius = 10;
                tile.append(block);
                if (caption) {
                    var line = new Skeleton(SkeletonShape.LINE, (int) (tile_width * 0.7), 12);
                    line.hexpand = false;
                    tile.append(line);
                }
                flow.append(tile);
            }
            return flow;
        }

        public static Singularity.Animation.AnimationGroup reveal(Gtk.Widget placeholder, Gtk.Widget content) {
            return Singularity.Motion.crossfade(placeholder, content);
        }
    }
}
