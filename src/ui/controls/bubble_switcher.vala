using Gtk;
using GLib;
using Gee;

namespace Singularity.Widgets {

    /**
     * A view switcher made for the window bubble bar.
     *
     * Options are plain text entries inside a single bubble, in the same
     * visual language as the path in Files: the current option reads at
     * full strength, the others are dimmed, and hovering shows a round
     * halo. Drives a Gtk.Stack like {@link SegmentedControl}, or works
     * standalone through {@link add_option} and {@link selected}.
     */
    public class BubbleSwitcher : Box {

        public signal void selected(string name);

        private Stack? _stack;
        private Map<string, Button> _buttons = new HashMap<string, Button>();
        private Gee.List<string> _names = new ArrayList<string>();
        private string? _active_name = null;

        public BubbleSwitcher(Stack? stack = null) {
            Object(orientation: Orientation.HORIZONTAL, spacing: 0);
            if (stack != null) set_stack(stack);
        }

        construct {
            add_css_class("bubble-switcher");
            hexpand = false;
            halign = Align.CENTER;
            valign = Align.CENTER;
        }

        public void set_stack(Stack stack) {
            _stack = stack;
            rebuild_buttons();
            _stack.get_pages().items_changed.connect(() => rebuild_buttons());
            _stack.notify["visible-child-name"].connect(update_active_button);
        }

        public void add_option(string name, string label) {
            var btn = new Button.with_label(label);
            btn.add_css_class("flat");
            btn.add_css_class("bubble-switcher-item");
            btn.clicked.connect(() => set_active(name));
            append(btn);
            _buttons.set(name, btn);
            _names.add(name);

            if (_stack == null && _active_name == null) _active_name = name;
            update_active_button();
        }

        public void set_active(string name) {
            if (_stack != null) {
                _stack.visible_child_name = name;
                return;
            }
            if (_active_name == name) return;
            _active_name = name;
            update_active_button();
            selected(name);
        }

        public void set_option_visible(string name, bool visible) {
            var btn = _buttons.get(name);
            if (btn == null || btn.visible == visible) return;
            btn.visible = visible;
            if (visible || active_option != name) return;
            foreach (var other in _names) {
                var candidate = _buttons.get(other);
                if (candidate != null && candidate.visible) {
                    set_active(other);
                    return;
                }
            }
        }

        public bool is_option_visible(string name) {
            var btn = _buttons.get(name);
            return btn != null && btn.visible;
        }

        public string? active_option {
            get { return _stack != null ? _stack.visible_child_name : _active_name; }
        }

        private void rebuild_buttons() {
            Widget? child = get_first_child();
            while (child != null) {
                Widget? next = child.get_next_sibling();
                remove(child);
                child = next;
            }
            _buttons.clear();
            _names.clear();

            var pages = _stack.get_pages();
            for (uint i = 0; i < pages.get_n_items(); i++) {
                var page = pages.get_item(i) as StackPage;
                if (page == null || page.name == null) continue;
                string title = page.title;
                if (title == null || title == "") {
                    title = page.name.substring(0, 1).up() + page.name.substring(1);
                }
                add_option(page.name, title);
            }
        }

        internal Gee.List<string> option_names() {
            return _names.read_only_view;
        }

        internal string option_label(string name) {
            var btn = _buttons.get(name);
            return btn != null ? (btn.label ?? name) : name;
        }

        private void update_active_button() {
            string? wanted = active_option;
            foreach (var entry in _buttons.entries) {
                if (entry.key == wanted) entry.value.add_css_class("current");
                else entry.value.remove_css_class("current");
            }
            notify_property("active-option");
        }
    }
}
