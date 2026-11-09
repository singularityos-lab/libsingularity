namespace Singularity {

    [CCode (cname = "singularity_background_current_tid", cheader_filename = "core/background_work.h")]
    private extern int background_current_tid();

    [CCode (cname = "singularity_background_nice_of", cheader_filename = "core/background_work.h")]
    private extern int background_nice_of(int tid);

    [CCode (cname = "singularity_background_lower_self", cheader_filename = "core/background_work.h")]
    private extern void background_lower_self();

    [CCode (cname = "singularity_background_apply", cheader_filename = "core/background_work.h")]
    private extern bool background_apply(int id, bool thread, bool background, int normal_nice);

    public class BackgroundWork : Object {
        private int _id;
        private bool _thread;
        private int _normal_nice;
        private bool _finished = false;
        private Mutex _lock = Mutex();
        private Gtk.Widget? _bar = null;
        private Gtk.Window? _window = null;
        private ulong[] _bar_handlers = {};
        private ulong[] _window_handlers = {};

        public bool foreground { get; private set; default = false; }

        private BackgroundWork(int id, bool thread) {
            _id = id;
            _thread = thread;
            _normal_nice = thread && id > 0 ? background_nice_of(id) : 0;
            if (_id > 0) background_apply(_id, _thread, true, _normal_nice);
        }

        public static BackgroundWork enter(Gtk.Widget? bar = null) {
            var work = new BackgroundWork(background_current_tid(), true);
            if (bar != null) work.follow_from_any_thread(bar);
            return work;
        }

        private void follow_from_any_thread(Gtk.Widget bar) {
            var ctx = MainContext.default();
            if (ctx.is_owner()) {
                follow(bar);
                return;
            }
            Gtk.Widget target = bar;
            ctx.invoke(() => {
                follow(target);
                return Source.REMOVE;
            });
        }

        public static BackgroundWork observe() {
            return new BackgroundWork(0, false);
        }

        public static BackgroundWork for_process(Pid pid) {
            return new BackgroundWork((int) pid, false);
        }

        public static void lower() {
            background_lower_self();
        }

        public void follow(Gtk.Widget bar) {
            unfollow();
            _lock.lock();
            bool done = _finished;
            _lock.unlock();
            if (done) return;
            _bar = bar;
            _bar_handlers = {
                bar.map.connect(update),
                bar.unmap.connect(update),
                bar.notify["root"].connect(() => {
                    watch_window();
                    update();
                })
            };
            watch_window();
            update();
        }

        public void unfollow() {
            unwatch_window();
            if (_bar != null) {
                foreach (ulong h in _bar_handlers) _bar.disconnect(h);
            }
            _bar_handlers = {};
            _bar = null;
            apply_state(false);
        }

        public void finish() {
            _lock.lock();
            if (!_finished) {
                _finished = true;
                if (_id > 0) background_apply(_id, _thread, false, _normal_nice);
            }
            _lock.unlock();
            var ctx = MainContext.default();
            if (ctx.is_owner()) {
                drop_bar();
            } else {
                ctx.invoke(() => {
                    drop_bar();
                    return Source.REMOVE;
                });
            }
        }

        private void drop_bar() {
            unwatch_window();
            if (_bar != null) {
                foreach (ulong h in _bar_handlers) _bar.disconnect(h);
            }
            _bar_handlers = {};
            _bar = null;
        }

        private void watch_window() {
            unwatch_window();
            _window = _bar != null ? _bar.get_root() as Gtk.Window : null;
            if (_window == null) return;
            _window_handlers = {
                _window.notify["is-active"].connect(update),
                _window.notify["suspended"].connect(update),
                _window.notify["visible"].connect(update)
            };
        }

        private void unwatch_window() {
            if (_window != null) {
                foreach (ulong h in _window_handlers) _window.disconnect(h);
            }
            _window_handlers = {};
            _window = null;
        }

        private void update() {
            apply_state(_bar != null && _bar.get_mapped() && _window != null
                && _window.visible && _window.is_active && !_window.suspended);
        }

        private void apply_state(bool value) {
            _lock.lock();
            if (!_finished && value != foreground) {
                if (_id > 0) background_apply(_id, _thread, !value, _normal_nice);
                _lock.unlock();
                foreground = value;
                return;
            }
            _lock.unlock();
        }
    }
}
