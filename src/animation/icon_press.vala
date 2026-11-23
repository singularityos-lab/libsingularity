namespace Singularity.Animation {

    public delegate Gtk.Image? PressedIcon();
    public delegate MotionBin? PressedBin();

    public class IconPress : Object {
        public const double SQUASH = 0.12;

        private PressedBin find_bin;
        private PressedIcon icon;
        private MotionBin? held = null;

        private IconPress(owned PressedBin find_bin, owned PressedIcon icon) {
            this.find_bin = (owned) find_bin;
            this.icon = (owned) icon;
        }

        public static void attach(Gtk.Widget target, owned PressedBin bin, owned PressedIcon icon) {
            var press = new IconPress((owned) bin, (owned) icon);
            var events = new Gtk.EventControllerLegacy();
            events.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            events.event.connect((event) => {
                switch (event.get_event_type()) {
                    case Gdk.EventType.BUTTON_PRESS:
                    case Gdk.EventType.TOUCH_BEGIN:
                        press.down();
                        break;
                    case Gdk.EventType.BUTTON_RELEASE:
                    case Gdk.EventType.TOUCH_END:
                    case Gdk.EventType.TOUCH_CANCEL:
                    case Gdk.EventType.GRAB_BROKEN:
                        press.up();
                        break;
                    default:
                        break;
                }
                return false;
            });
            target.add_controller(events);
            target.set_data<IconPress>("singularity-icon-press", press);
        }

        private void down() {
            if (held != null || Singularity.Motion.reduced()) return;
            var image = icon();
            if (image != null && IconMotion.animated(image)) return;
            held = find_bin();
            if (held == null) return;
            Singularity.Motion.spring_to(held, "squash", SQUASH, Singularity.Motion.Spring.SNAPPY);
        }

        private void up() {
            if (held == null) return;
            var bin = held;
            held = null;
            Singularity.Motion.spring_to(bin, "squash", 0.0, Singularity.Motion.Spring.BOUNCY);
        }
    }
}
