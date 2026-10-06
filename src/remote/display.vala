using Gtk;

namespace Singularity.Remote {

    public class RemoteDisplay : Widget {
        private RemoteSession? _session;
        private ulong frame_id;
        private ulong cursor_id;
        private bool _fit = true;
        private double scale = 1;
        private double off_x;
        private double off_y;
        private uint buttons;
        private int last_x;
        private int last_y;
        private uint resize_id;
        private bool _resize_remote;
        private Gee.HashSet<uint> held = new Gee.HashSet<uint> ();
        private Gee.HashMap<uint, uint> implied = new Gee.HashMap<uint, uint> ();
        private const uint[] IMPLIED_KEYS = { Gdk.Key.Control_L, Gdk.Key.Alt_L, Gdk.Key.Shift_L };

        public bool fit {
            get { return _fit; }
            set {
                _fit = value;
                queue_resize ();
            }
        }

        public bool resize_remote {
            get { return _resize_remote; }
            set {
                _resize_remote = value;
                schedule_remote_resize ();
            }
        }

        public RemoteSession? session {
            get { return _session; }
            set {
                if (_session != null) {
                    _session.disconnect (frame_id);
                    _session.disconnect (cursor_id);
                }
                _session = value;
                held.clear ();
                implied.clear ();
                buttons = 0;
                if (_session != null) {
                    frame_id = _session.frame.connect (() => {
                        queue_resize ();
                        queue_draw ();
                    });
                    cursor_id = _session.cursor_changed.connect ((c) => set_cursor (c));
                } else {
                    set_cursor (null);
                }
                queue_resize ();
            }
        }

        construct {
            focusable = true;
            can_focus = true;
            overflow = Overflow.HIDDEN;
            add_css_class ("remote-display");

            var motion = new EventControllerMotion ();
            motion.motion.connect ((x, y) => pointer (x, y));
            add_controller (motion);

            var click = new GestureClick ();
            click.button = 0;
            click.pressed.connect ((n, x, y) => {
                grab_focus ();
                uint bit = button_bit (click.get_current_button ());
                buttons |= bit;
                pointer (x, y);
            });
            click.released.connect ((n, x, y) => {
                buttons &= ~button_bit (click.get_current_button ());
                pointer (x, y);
            });
            click.stopped.connect (() => {
                if (buttons != 0) {
                    buttons = 0;
                    if (_session != null) _session.send_pointer (last_x, last_y, 0);
                }
            });
            add_controller (click);

            var scroll = new EventControllerScroll (EventControllerScrollFlags.BOTH_AXES | EventControllerScrollFlags.DISCRETE);
            scroll.scroll.connect ((dx, dy) => {
                if (_session != null) _session.send_scroll (last_x, last_y, dx, dy);
                return true;
            });
            add_controller (scroll);

            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((keyval, keycode, state) => {
                if (_session == null) return false;
                uint extra = implied_modifiers (keyval, state);
                for (int i = 0; i < IMPLIED_KEYS.length; i++) {
                    if ((extra & (1 << i)) != 0) _session.send_key (IMPLIED_KEYS[i], 0, true);
                }
                if (extra != 0) implied[keyval] = extra;
                held.add (keyval);
                _session.send_key (keyval, keycode, true);
                return true;
            });
            keys.key_released.connect ((keyval, keycode, state) => {
                if (_session == null) return;
                held.remove (keyval);
                _session.send_key (keyval, keycode, false);
                uint extra;
                if (implied.unset (keyval, out extra)) release_implied (extra);
            });
            add_controller (keys);
            var focus = new EventControllerFocus ();
            focus.leave.connect (release_all);
            add_controller (focus);
        }

        private bool holding (uint a, uint b) {
            return held.contains (a) || held.contains (b);
        }

        public static bool needs_shift (uint keyval) {
            if (keyval >= 'A' && keyval <= 'Z') return true;
            return keyval < 0x80 && "~!@#$%^&*()_+{}|:\"<>?".index_of_char ((unichar) keyval) >= 0;
        }

        private uint implied_modifiers (uint keyval, Gdk.ModifierType state) {
            uint extra = 0;
            if (keyval == Gdk.Key.Shift_L || keyval == Gdk.Key.Shift_R || keyval == Gdk.Key.Control_L || keyval == Gdk.Key.Control_R || keyval == Gdk.Key.Alt_L || keyval == Gdk.Key.Alt_R) return extra;
            if ((state & Gdk.ModifierType.CONTROL_MASK) != 0 && !holding (Gdk.Key.Control_L, Gdk.Key.Control_R)) extra |= 1;
            if ((state & Gdk.ModifierType.ALT_MASK) != 0 && !holding (Gdk.Key.Alt_L, Gdk.Key.Alt_R)) extra |= 2;
            if (needs_shift (keyval) && !holding (Gdk.Key.Shift_L, Gdk.Key.Shift_R)) extra |= 4;
            return extra;
        }

        private void release_implied (uint extra) {
            for (int i = IMPLIED_KEYS.length - 1; i >= 0; i--) {
                if ((extra & (1 << i)) != 0) _session.send_key (IMPLIED_KEYS[i], 0, false);
            }
        }

        public void release_all () {
            if (_session == null) return;
            foreach (uint k in held) _session.send_key (k, 0, false);
            held.clear ();
            foreach (uint extra in implied.values) release_implied (extra);
            implied.clear ();
            if (buttons != 0) {
                buttons = 0;
                _session.send_pointer (last_x, last_y, 0);
            }
        }

        private static uint button_bit (uint button) {
            switch (button) {
                case 1: return 1;
                case 2: return 2;
                case 3: return 4;
                default: return 0;
            }
        }

        private void pointer (double x, double y) {
            if (_session == null || _session.width <= 0 || scale <= 0) return;
            last_x = (int) Math.floor ((x - off_x) / scale);
            last_y = (int) Math.floor ((y - off_y) / scale);
            _session.send_pointer (last_x, last_y, buttons);
        }

        protected override SizeRequestMode get_request_mode () {
            return SizeRequestMode.CONSTANT_SIZE;
        }

        protected override void measure (Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = natural_baseline = -1;
            minimum = 0;
            natural = 0;
            if (_session == null || _fit) return;
            natural = minimum = orientation == Orientation.HORIZONTAL ? _session.width : _session.height;
        }

        protected override void size_allocate (int width, int height, int baseline) {
            schedule_remote_resize ();
        }

        private void schedule_remote_resize () {
            if (!_resize_remote || !_fit) return;
            if (resize_id != 0) Source.remove (resize_id);
            resize_id = Timeout.add (400, () => {
                resize_id = 0;
                if (_session != null && _session.active && _session.can_resize) {
                    int f = get_scale_factor ();
                    _session.request_size (get_width () * f & ~1, get_height () * f);
                }
                return Source.REMOVE;
            });
        }

        protected override void snapshot (Gtk.Snapshot snapshot) {
            if (_session == null || _session.texture == null) return;
            var tex = _session.texture;
            double w = get_width (), h = get_height ();
            double tw = tex.width, th = tex.height;
            if (_fit) {
                double f = get_scale_factor ();
                scale = double.min (w / tw, h / th);
                if ((scale * f - 1).abs () < 0.02) scale = 1 / f;
            } else {
                scale = 1;
            }
            off_x = Math.floor ((w - tw * scale) / 2);
            off_y = Math.floor ((h - th * scale) / 2);
            if (off_x < 0) off_x = 0;
            if (off_y < 0) off_y = 0;
            var rect = Graphene.Rect ().init ((float) off_x, (float) off_y, (float) (tw * scale), (float) (th * scale));
            var filter = scale < 1 ? Gsk.ScalingFilter.TRILINEAR : Gsk.ScalingFilter.LINEAR;
            if ((scale - 1).abs () < 0.001) filter = Gsk.ScalingFilter.NEAREST;
            snapshot.append_scaled_texture (tex, filter, rect);
        }
    }
}
