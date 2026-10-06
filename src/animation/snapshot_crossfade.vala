namespace Singularity.Animation {

    public delegate void SceneChange();

    /**
     * Draws a still image of a window on top of it while the window changes
     * underneath, then fades the image away.
     */
    public class SnapshotCover : Gtk.Widget {

        public Gdk.Texture texture { get; construct; }

        static construct {
            set_css_name("snapshotcover");
        }

        public SnapshotCover(Gdk.Texture texture) {
            Object(texture: texture);
        }

        construct {
            can_target = false;
            can_focus = false;
        }

        public override void measure(Gtk.Orientation orientation, int for_size,
                                     out int minimum, out int natural,
                                     out int minimum_baseline, out int natural_baseline) {
            minimum = 0;
            natural = 0;
            minimum_baseline = -1;
            natural_baseline = -1;
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            var rect = Graphene.Rect();
            rect.init(0, 0, texture.get_width(), texture.get_height());
            snapshot.append_texture(texture, rect);
        }
    }

    /**
     * Crossfades every open window from its old look to a new one.
     *
     * `run()` takes a picture of each mapped toplevel, applies the change,
     * lays the pictures over the changed windows and fades them out over
     * SCENE with a linear curve. Used for the light and dark switch; with
     * Reduced Motion the change is immediate.
     */
    public class SnapshotCrossfade : Object {

        private Gtk.Window window;
        private SnapshotCover cover;
        private Gdk.FrameClock? clock = null;
        private ulong layout_handler = 0;
        private TimedAnimation? fade = null;

        private static GenericArray<SnapshotCrossfade> running = null;

        private SnapshotCrossfade(Gtk.Window window, Gdk.Texture texture) {
            this.window = window;
            cover = new SnapshotCover(texture);
        }

        public static uint active_count {
            get { return running != null ? running.length : 0; }
        }

        public static Gdk.Texture? render_window(Gtk.Window window) {
            int width = window.get_width();
            int height = window.get_height();
            if (width <= 0 || height <= 0 || !window.get_mapped()) return null;
            var renderer = window.get_renderer();
            if (renderer == null) return null;
            var paintable = new Gtk.WidgetPaintable(window);
            var snapshot = new Gtk.Snapshot();
            paintable.snapshot(snapshot, width, height);
            var node = snapshot.to_node();
            if (node == null) return null;
            var viewport = Graphene.Rect();
            viewport.init(0, 0, width, height);
            return renderer.render_texture(node, viewport);
        }

        public static void run(owned SceneChange change, uint duration_ms = Singularity.Motion.Duration.SCENE) {
            if (Singularity.Motion.reduced() || Gdk.Display.get_default() == null) {
                change();
                return;
            }
            finish_all();
            var fades = new GenericArray<SnapshotCrossfade>();
            var toplevels = Gtk.Window.get_toplevels();
            for (uint i = 0; i < toplevels.get_n_items(); i++) {
                var window = toplevels.get_item(i) as Gtk.Window;
                if (window == null || !window.get_mapped() || !window.visible) continue;
                var texture = render_window(window);
                if (texture == null) continue;
                fades.add(new SnapshotCrossfade(window, texture));
            }
            change();
            if (running == null) running = new GenericArray<SnapshotCrossfade>();
            foreach (var item in fades) {
                running.add(item);
                item.start(duration_ms);
            }
        }

        public static void finish_all() {
            if (running == null) return;
            SnapshotCrossfade[] list = {};
            foreach (var item in running) list += item;
            foreach (var item in list) item.finish();
        }

        private void start(uint duration_ms) {
            cover.insert_before(window, null);
            clock = window.get_frame_clock();
            if (clock != null) layout_handler = clock.layout.connect_after(place);
            window.queue_allocate();
            fade = new TimedAnimation.with_curve(window, 1.0, 0.0, duration_ms, Singularity.Motion.Curve.LINEAR);
            fade.reduced_mode = ReducedMode.JUMP;
            fade.set_sink((value) => cover.opacity = value);
            fade.done.connect(finish);
            fade.play();
        }

        private void place() {
            if (cover.get_parent() != window) return;
            int minimum, natural, minimum_baseline, natural_baseline;
            cover.measure(Gtk.Orientation.HORIZONTAL, -1, out minimum, out natural,
                out minimum_baseline, out natural_baseline);
            cover.measure(Gtk.Orientation.VERTICAL, -1, out minimum, out natural,
                out minimum_baseline, out natural_baseline);
            cover.allocate(cover.texture.get_width(), cover.texture.get_height(), -1, null);
        }

        private void finish() {
            if (layout_handler != 0 && clock != null) clock.disconnect(layout_handler);
            layout_handler = 0;
            clock = null;
            if (fade != null && fade.state == AnimationState.PLAYING) {
                var playing = fade;
                fade = null;
                playing.skip();
            }
            if (cover.get_parent() != null) cover.unparent();
            if (running != null) running.remove(this);
        }
    }
}
