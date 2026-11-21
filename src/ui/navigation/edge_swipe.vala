using Gtk;

namespace Singularity.Widgets {

    public delegate bool EdgeSwipeAccept (double x, double y);

    public class EdgeSwipe : Object {
        private const double CLAIM_DISTANCE = 10.0;
        private const double FLING_VELOCITY = 1.0;

        private Widget _host;
        private GestureDrag _drag;
        private Singularity.Animation.SpringAnimation? _spring = null;
        private Singularity.Animation.VelocityTracker _velocity = new Singularity.Animation.VelocityTracker ();
        private EdgeSwipeAccept? _accept = null;
        private double _start_progress = 0.0;
        private double _target = 0.0;
        private bool _deciding = false;
        private uint _generation = 0;

        public double progress { get; private set; default = 0.0; }
        public bool is_open { get; private set; default = false; }
        public bool tracking { get; private set; default = false; }
        public int direction { get; set; default = 1; }
        public int distance { get; set; default = 320; }
        public bool enabled { get; set; default = true; }

        public signal void begin_track ();
        public signal void settled (bool open);

        public EdgeSwipe (Widget host) {
            _host = host;
            _drag = new GestureDrag ();
            _drag.touch_only = true;
            _drag.propagation_phase = PropagationPhase.CAPTURE;
            _drag.drag_begin.connect (on_begin);
            _drag.drag_update.connect (on_update);
            _drag.drag_end.connect (on_end);
            _drag.cancel.connect (() => {
                if (tracking) finish_track (0.0);
                _deciding = false;
            });
            host.add_controller (_drag);
        }

        public void set_accept (owned EdgeSwipeAccept? accept) {
            _accept = (owned) accept;
        }

        public void set_open (bool value, bool animate = true) {
            if (!animate) {
                stop_spring ();
                _target = value ? 1.0 : 0.0;
                progress = _target;
                if (is_open != value) {
                    is_open = value;
                    settled (value);
                }
                return;
            }
            animate_to (value ? 1.0 : 0.0, 0.0);
        }

        public bool settling {
            get { return _spring != null; }
        }

        public double target {
            get { return _target; }
        }

        private void on_begin (double x, double y) {
            _deciding = false;
            if (!enabled || _accept == null || !_accept (x, y)) {
                _drag.set_state (EventSequenceState.DENIED);
                return;
            }
            _deciding = true;
        }

        private void on_update (double dx, double dy) {
            if (_deciding) {
                if (dx.abs () < CLAIM_DISTANCE && dy.abs () < CLAIM_DISTANCE) return;
                double along = dx * direction;
                bool useful = (along > 0 && progress < 1.0) || (along < 0 && progress > 0.0);
                _deciding = false;
                if (dx.abs () <= dy.abs () || !useful) {
                    _drag.set_state (EventSequenceState.DENIED);
                    return;
                }
                _drag.set_state (EventSequenceState.CLAIMED);
                stop_spring ();
                _start_progress = progress - (dx * direction) / double.max (distance, 1);
                _velocity.reset ();
                tracking = true;
                begin_track ();
            }
            if (!tracking) return;
            double value = (_start_progress + dx * direction / double.max (distance, 1)).clamp (0.0, 1.0);
            progress = value;
            uint32 event_ms = _drag.get_current_event_time ();
            int64 now = event_ms > 0 ? (int64) event_ms * 1000 : Singularity.Motion.get_default ().now_for (_host);
            _velocity.add (now >= 0 ? now : GLib.get_monotonic_time (), value);
        }

        private void on_end (double dx, double dy) {
            _deciding = false;
            if (!tracking) return;
            finish_track (_velocity.velocity);
        }

        private void finish_track (double velocity) {
            tracking = false;
            double goal;
            if (velocity > FLING_VELOCITY) goal = 1.0;
            else if (velocity < -FLING_VELOCITY) goal = 0.0;
            else goal = progress >= 0.5 ? 1.0 : 0.0;
            animate_to (goal, velocity);
        }

        private void animate_to (double goal, double velocity) {
            stop_spring ();
            _target = goal;
            if (progress == goal) {
                settle (goal >= 1.0);
                return;
            }
            uint generation = ++_generation;
            var spring = new Singularity.Animation.SpringAnimation (_host, progress, goal, Singularity.Motion.Spring.SNAPPY);
            spring.clamp = true;
            spring.initial_velocity = velocity;
            spring.set_sink ((v) => {
                if (generation == _generation) progress = v.clamp (0.0, 1.0);
            });
            spring.done.connect (() => {
                if (generation != _generation) return;
                _spring = null;
                progress = goal;
                settle (goal >= 1.0);
            });
            _spring = spring;
            spring.play ();
        }

        private void settle (bool value) {
            is_open = value;
            settled (value);
        }

        private void stop_spring () {
            if (_spring == null) return;
            var spring = _spring;
            _spring = null;
            _generation++;
            spring.pause ();
        }

        public void detach () {
            stop_spring ();
            if (_host != null) _host.remove_controller (_drag);
            _host = null;
        }
    }
}
