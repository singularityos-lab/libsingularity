using Gtk;

namespace Singularity.Widgets {

    [DBus (name = "dev.sinty.ScreenKeyboard")]
    internal interface ScreenKeyboardBus : Object {
        public signal void closed(bool accepted);
        public abstract void open(string text, int cursor) throws GLib.Error;
        public abstract void set_text(string text, int cursor) throws GLib.Error;
        public abstract void navigate(string direction) throws GLib.Error;
        public abstract void activate() throws GLib.Error;
        public abstract void close() throws GLib.Error;
    }

    internal class TvTextKeys : Object {
        private static ScreenKeyboardBus? _bus = null;

        private unowned Widget? _typed_on = null;
        private bool _typed = false;
        private Gtk.Window? _win = null;
        private Widget? _focus = null;
        private Editable? _editable = null;
        private ulong _closed_handler = 0;
        private ulong _changed_handler = 0;
        private ulong _cursor_handler = 0;
        private ulong _focus_handler = 0;

        private static ScreenKeyboardBus? bus() {
            if (_bus != null) return _bus;
            try {
                _bus = Bus.get_proxy_sync<ScreenKeyboardBus>(BusType.SESSION, "dev.sinty.ScreenKeyboard",
                    "/dev/sinty/ScreenKeyboard", DBusProxyFlags.DO_NOT_AUTO_START | DBusProxyFlags.DO_NOT_LOAD_PROPERTIES);
                ((DBusProxy) _bus).set_default_timeout(1000);
            } catch (GLib.Error e) {
                return null;
            }
            return _bus;
        }

        public bool key(Gtk.Window win, uint keyval) {
            if (_editable != null) return remote_key(keyval);
            var focus = win.get_focus();
            Editable? editable = focus as Editable;
            if (editable == null && focus != null) editable = focus.get_ancestor(typeof(Editable)) as Editable;
            if (editable == null) return false;
            if (focus != _typed_on) {
                _typed_on = focus;
                _typed = false;
            }
            if (Gdk.keyval_to_unicode(keyval) > 31) _typed = true;
            if (keyval != Gdk.Key.Return && keyval != Gdk.Key.KP_Enter) return false;
            if (_typed) return false;
            return open(win, focus, editable);
        }

        private bool remote_key(uint keyval) {
            var keyboard = bus();
            if (keyboard == null) {
                release();
                return false;
            }
            try {
                switch (keyval) {
                    case Gdk.Key.Up:
                        keyboard.navigate("up");
                        return true;
                    case Gdk.Key.Down:
                        keyboard.navigate("down");
                        return true;
                    case Gdk.Key.Left:
                        keyboard.navigate("left");
                        return true;
                    case Gdk.Key.Right:
                        keyboard.navigate("right");
                        return true;
                    case Gdk.Key.Return:
                    case Gdk.Key.KP_Enter:
                        keyboard.activate();
                        return true;
                    case Gdk.Key.Escape:
                    case Gdk.Key.Back:
                        keyboard.close();
                        return true;
                    default:
                        return false;
                }
            } catch (GLib.Error e) {
                release();
                return false;
            }
        }

        private bool open(Gtk.Window win, Widget focus, Editable editable) {
            var keyboard = bus();
            if (keyboard == null) return false;
            try {
                keyboard.open(editable.get_text(), editable.get_position());
            } catch (GLib.Error e) {
                return false;
            }
            _win = win;
            _focus = focus;
            _editable = editable;
            _closed_handler = keyboard.closed.connect(on_closed);
            _changed_handler = editable.changed.connect(send_text);
            _cursor_handler = editable.notify["cursor-position"].connect(send_text);
            _focus_handler = win.notify["focus-widget"].connect(() => {
                if (_win != null && _win.get_focus() != _focus) {
                    try {
                        bus().close();
                    } catch (GLib.Error e) {
                        release();
                    }
                }
            });
            return true;
        }

        private void send_text() {
            if (_editable == null || _bus == null) return;
            try {
                _bus.set_text(_editable.get_text(), _editable.get_position());
            } catch (GLib.Error e) {
                release();
            }
        }

        private void on_closed(bool accepted) {
            Widget? focus = _focus;
            release();
            if (accepted && focus != null) {
                Widget target = focus.get_ancestor(typeof(Entry)) ?? focus.get_ancestor(typeof(SearchEntry)) ?? focus;
                target.activate();
            }
        }

        private void release() {
            if (_bus != null && _closed_handler != 0) _bus.disconnect(_closed_handler);
            if (_editable != null) {
                _editable.disconnect(_changed_handler);
                _editable.disconnect(_cursor_handler);
            }
            if (_win != null) _win.disconnect(_focus_handler);
            _closed_handler = 0;
            _changed_handler = 0;
            _cursor_handler = 0;
            _focus_handler = 0;
            _win = null;
            _focus = null;
            _editable = null;
        }
    }
}
