using Gtk;

namespace Singularity.Widgets {

    internal class TvTextKeys : Object {
        private unowned Widget? _typed_on = null;
        private bool _typed = false;

        public bool key(Gtk.Window win, uint keyval) {
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
            TvKeyboard.open(focus, editable);
            return true;
        }
    }

    internal class TvKeyboard : Popover {
        private const string[] ROWS = { "1234567890", "qwertyuiop", "asdfghjkl@", "zxcvbnm.-_" };

        private unowned Editable _target;
        private bool _upper = false;
        private GenericArray<Button> _letters = new GenericArray<Button>();
        private Button? _first = null;

        public signal void done();

        public TvKeyboard(Widget anchor, Editable target) {
            _target = target;
            has_arrow = false;
            autohide = true;
            position = PositionType.BOTTOM;
            add_css_class("tv-keyboard");
            set_parent(anchor);

            var rows = new Box(Orientation.VERTICAL, 8);
            rows.add_css_class("tv-keyboard-rows");
            foreach (string row in ROWS) {
                var line = new Box(Orientation.HORIZONTAL, 8);
                line.halign = Align.CENTER;
                for (int i = 0; i < row.length; i++) {
                    string ch = row.substring(i, 1);
                    var key = make_key(ch);
                    key.clicked.connect(() => type(_upper ? ch.up() : ch));
                    if (ch.get_char().isalpha()) _letters.add(key);
                    if (_first == null && ch == "q") _first = key;
                    line.append(key);
                }
                rows.append(line);
            }

            var last = new Box(Orientation.HORIZONTAL, 8);
            last.halign = Align.CENTER;
            var shift = make_key(_("Shift"));
            shift.add_css_class("tv-key-wide");
            shift.clicked.connect(() => toggle_shift());
            var space = make_key(_("Space"));
            space.add_css_class("tv-key-space");
            space.clicked.connect(() => type(" "));
            var erase = new Button.from_icon_name("edit-clear-symbolic");
            erase.add_css_class("tv-key");
            erase.add_css_class("tv-key-wide");
            erase.tooltip_text = _("Delete");
            erase.update_property(Gtk.AccessibleProperty.LABEL, _("Delete"), -1);
            erase.clicked.connect(() => erase_one());
            var ok = make_key(_("Done"));
            ok.add_css_class("tv-key-wide");
            ok.add_css_class("suggested-action");
            ok.clicked.connect(() => {
                popdown();
                done();
            });
            last.append(shift);
            last.append(space);
            last.append(erase);
            last.append(ok);
            rows.append(last);
            child = rows;

            map.connect(() => {
                if (_first != null) _first.grab_focus();
            });
            closed.connect(() => {
                Idle.add(() => {
                    unparent();
                    return Source.REMOVE;
                });
            });
        }

        public static void open(Widget focus, Editable editable) {
            Widget anchor = focus.get_ancestor(typeof(Entry)) ?? focus.get_ancestor(typeof(SearchEntry)) ?? focus;
            var keyboard = new TvKeyboard(anchor, editable);
            keyboard.done.connect(() => anchor.activate());
            keyboard.closed.connect(() => {
                focus.grab_focus();
                Idle.add(() => {
                    editable.set_position(-1);
                    return Source.REMOVE;
                });
            });
            keyboard.popup();
        }

        private static Button make_key(string text) {
            var key = new Button.with_label(text);
            key.add_css_class("tv-key");
            key.can_shrink = false;
            return key;
        }

        private void type(string text) {
            int pos = _target.get_position();
            _target.insert_text(text, -1, ref pos);
            _target.set_position(pos);
            if (_upper && text.get_char().isalpha()) toggle_shift();
        }

        private void erase_one() {
            int pos = _target.get_position();
            if (pos <= 0) return;
            _target.delete_text(pos - 1, pos);
            _target.set_position(pos - 1);
        }

        private void toggle_shift() {
            _upper = !_upper;
            foreach (var key in _letters) {
                string label = key.label;
                key.label = _upper ? label.up() : label.down();
            }
        }
    }
}
