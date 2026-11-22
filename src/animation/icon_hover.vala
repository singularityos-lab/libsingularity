namespace Singularity.Animation {

    public class IconHover : Object {
        public const uint DWELL = 80;

        private uint limit_ms;
        private uint pending = 0;
        private bool hovered = false;
        private bool played = false;
        private double detail = 1.0;

        public IconHover(uint limit_ms = IconMotion.DOCK_LIMIT) {
            this.limit_ms = limit_ms;
        }

        public static void attach(Gtk.Widget target, Gtk.Image image) {
            var hover = new IconHover();
            var motion = new Gtk.EventControllerMotion();
            unowned Gtk.Image icon = image;
            motion.enter.connect((x, y) => hover.entered(icon));
            motion.leave.connect(() => hover.left());
            target.add_controller(motion);
        }

        public void entered(Gtk.Image? image, double detail = 1.0) {
            if (hovered) return;
            hovered = true;
            this.detail = detail;
            var icon = WeakRef(image);
            pending = Timeout.add(DWELL, () => {
                pending = 0;
                played = animate(icon.get() as Gtk.Image);
                return Source.REMOVE;
            });
        }

        public void left() {
            cancel();
            hovered = false;
            played = false;
            detail = 1.0;
        }

        public void activated(Gtk.Image? image) {
            if (played) return;
            cancel();
            bool running = animate(image);
            if (hovered) played = running;
        }

        private bool animate(Gtk.Image? image) {
            return image != null && IconMotion.play(image, limit_ms, detail);
        }

        private void cancel() {
            if (pending == 0) return;
            Source.remove(pending);
            pending = 0;
        }
    }
}
