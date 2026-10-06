namespace Singularity.Animation {

    public enum GroupMode {
        PARALLEL,
        SEQUENCE
    }

    public class AnimationGroup : Object, Playable {

        private GenericArray<Playable> children = new GenericArray<Playable>();
        private uint pending = 0;
        private int current = -1;
        private bool running = false;
        private uint _delay = 0;
        private AnimationGroup? _self = null;

        public GroupMode mode { get; construct; }

        public uint delay {
            get { return _delay; }
            set {
                _delay = value;
                if (mode == GroupMode.PARALLEL) {
                    foreach (var child in children) child.delay = value;
                } else if (children.length > 0) {
                    children[0].delay = value;
                }
            }
        }

        public bool is_running {
            get { return running; }
        }

        public uint length {
            get { return children.length; }
        }

        public AnimationGroup(GroupMode mode = GroupMode.PARALLEL) {
            Object(mode: mode);
        }

        public AnimationGroup add(Playable child) {
            children.add(child);
            child.done.connect(on_child_done);
            var animation = child as Animation;
            if (animation != null) animation.notify["state"].connect(on_child_state);
            if (running) {
                if (mode == GroupMode.PARALLEL) {
                    pending++;
                    child.play();
                }
            }
            return this;
        }

        public void play() {
            if (running) return;
            running = true;
            _self = this;
            if (children.length == 0) {
                finish();
                return;
            }
            if (mode == GroupMode.PARALLEL) {
                pending = children.length;
                foreach (var child in snapshot()) child.play();
            } else {
                current = 0;
                children[0].play();
            }
        }

        public void skip() {
            if (!running) play();
            if (mode == GroupMode.PARALLEL) {
                foreach (var child in snapshot()) child.skip();
                return;
            }
            while (running && current >= 0 && current < children.length) {
                children[current].skip();
            }
        }

        public void reset() {
            running = false;
            _self = null;
            pending = 0;
            current = -1;
            foreach (var child in children) child.reset();
        }

        private Playable[] snapshot() {
            Playable[] list = {};
            foreach (var child in children) list += child;
            return list;
        }

        private void on_child_done(Playable child) {
            if (!running) return;
            if (mode == GroupMode.PARALLEL) {
                if (pending > 0) pending--;
                if (pending == 0) finish();
                return;
            }
            if (current < 0 || children[current] != child) return;
            current++;
            if (current >= children.length) {
                finish();
                return;
            }
            children[current].play();
        }

        private void on_child_state(Object child, ParamSpec spec) {
            if (running && ((Animation) child).state == AnimationState.IDLE) abandon();
        }

        private void abandon() {
            running = false;
            pending = 0;
            current = -1;
            _self = null;
        }

        private void finish() {
            running = false;
            current = -1;
            var keep = _self;
            _self = null;
            done();
        }
    }
}
