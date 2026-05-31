using Gtk;
using GLib;
using Gee;

namespace Singularity.Widgets {

    /**
     * A horizontal segmented control (tab-strip) that can drive a Gtk.Stack
     * or work standalone.
     *
     * Bound to a Stack:
     *   - clicking a button switches `visible_child_name`
     *   - active state mirrors the stack at all times
     *
     * Standalone:
     *   - clicking a button marks it active and emits `selected`
     *   - the first added option is active by default
     */
    public class SegmentedControl : Box {

        public signal void selected(string name);

        private Stack? _stack;
        private Box _inner_box;
        private Map<string, Button> _buttons = new HashMap<string, Button>();
        private string? _active_name = null;

        public SegmentedControl(Stack? stack = null) {
            Object(orientation: Orientation.HORIZONTAL, spacing: 0);
            _stack = stack;

            add_css_class("segmented-control");
            halign = Align.CENTER;
            valign = Align.CENTER;

            _inner_box = new Box(Orientation.HORIZONTAL, 0);
            _inner_box.add_css_class("segmented-inner");
            append(_inner_box);

            if (_stack != null) set_stack(_stack);
        }

        public void set_stack(Stack stack) {
            _stack = stack;
            rebuild_buttons();
            _stack.get_pages().items_changed.connect((model, idx, rem, add) => {
                rebuild_buttons();
            });
            _stack.notify["visible-child-name"].connect(update_active_button);
        }

        public void add_option(string name, string label) {
            var btn = new Button.with_label(label);
            btn.has_frame = false;
            btn.add_css_class("segmented-button");

            btn.clicked.connect(() => {
                if (_stack != null) {
                    _stack.visible_child_name = name;
                } else {
                    _active_name = name;
                    update_active_button();
                    selected(name);
                }
            });

            _inner_box.append(btn);
            _buttons.set(name, btn);

            // First option becomes the standalone default.
            if (_stack == null && _active_name == null) _active_name = name;

            update_active_button();
        }

        /** Mark the option with the given name as active. */
        public void set_active(string name) {
            if (_stack != null) _stack.visible_child_name = name;
            else                _active_name = name;
            update_active_button();
        }

        public string? active_option { get { return _active_name; } }

        private void rebuild_buttons() {
            if (_stack == null) return;

            Widget? child = _inner_box.get_first_child();
            while (child != null) {
                Widget? next = child.get_next_sibling();
                _inner_box.remove(child);
                child = next;
            }
            _buttons.clear();

            var pages_model = _stack.get_pages();
            uint n = pages_model.get_n_items();

            for (uint i = 0; i < n; i++) {
                var item = pages_model.get_item(i);
                var page = item as StackPage;
                if (page == null) continue;

                string name = page.name;
                if (name == "empty" || name == null) continue;

                string title = page.title;
                if (title == null || title == "") {
                    title = name.substring(0, 1).up() + name.substring(1);
                }
                add_option(name, title);
            }
        }

        private void update_active_button() {
            string? wanted = (_stack != null)
                ? _stack.visible_child_name
                : _active_name;
            if (wanted == null) return;

            var it = _buttons.map_iterator();
            while (it.next()) {
                string name = it.get_key();
                var btn = it.get_value();
                if (name == wanted) btn.add_css_class("active");
                else                btn.remove_css_class("active");
            }
        }
    }
}
