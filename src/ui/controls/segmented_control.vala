using Gtk;
using GLib;
using Gee;

namespace Singularity.Widgets {

    /**
     * A horizontal segmented control (tab-strip) that can drive a Gtk.Stack or be used standalone.
     *
     * When bound to a Gtk.Stack, the control synchronizes with the stack automatically:
     * selecting a button switches the visible child, and adding/removing pages rebuilds the buttons.
     * Standalone buttons can be added with `add_option()`.
     */
    public class SegmentedControl : Box {
        private Stack? _stack;
        private Box _inner_box;
        private Map<string, Button> _buttons = new HashMap<string, Button>();

        /**
         * Creates a segmented control, optionally bound to a stack.
         *
         * @param stack The Gtk.Stack to control, or null for standalone use.
         */
        public SegmentedControl(Stack? stack = null) {
            Object(orientation: Orientation.HORIZONTAL, spacing: 0);
            _stack = stack;

            add_css_class("segmented-control");
            halign = Align.CENTER;
            valign = Align.CENTER;

            _inner_box = new Box(Orientation.HORIZONTAL, 0);
            _inner_box.add_css_class("segmented-inner");
            append(_inner_box);

            if (_stack != null) {
                set_stack(_stack);
            }
        }

        /**
         * Binds the control to a Gtk.Stack, rebuilding buttons to match
         * its pages and tracking visibility changes.
         *
         * @param stack The stack to bind to.
         */
        public void set_stack(Stack stack) {
            _stack = stack;

            // Rebuild now and when pages change
            rebuild_buttons();

            _stack.get_pages().items_changed.connect((model, idx, rem, add) => {
                rebuild_buttons();
            });

            // Sync with stack visibility
            _stack.notify["visible-child-name"].connect(update_active_button);
        }

        /**
         * Adds a standalone button to the strip (for use without a stack).
         *
         * @param name  Machine-readable identifier for this option.
         * @param label Human-readable button label.
         */
        public void add_option(string name, string label) {
            var btn = new Button.with_label(label);
            btn.has_frame = false;
            btn.add_css_class("segmented-button");

            btn.clicked.connect(() => {
                if (_stack != null) _stack.visible_child_name = name;
            });

            _inner_box.append(btn);
            _buttons.set(name, btn);
            update_active_button();
        }

        private void rebuild_buttons() {
            if (_stack == null) return;

            // Clean old buttons
            Widget? child = _inner_box.get_first_child();
            while (child != null) {
                Widget? next = child.get_next_sibling();
                _inner_box.remove(child);
                child = next;
            }
            _buttons.clear();

            // Create buttons for stack children
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
            if (_stack == null) return;
            string active_name = _stack.visible_child_name;

            var it = _buttons.map_iterator();
            while (it.next()) {
                string name = it.get_key();
                var btn = it.get_value();
                if (name == active_name) {
                    btn.add_css_class("active");
                } else {
                    btn.remove_css_class("active");
                }
            }
        }
    }
}
