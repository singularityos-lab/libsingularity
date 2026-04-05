using Gtk;

namespace Singularity.Widgets {

    /**
     * A drop-down button for choosing paragraph styles in a rich-text editor.
     *
     * Displays the current style name in a Gtk.MenuButton and shows
     * a popover list of all available styles when clicked.
     * Emits `style_selected` when the user picks an entry.
     */
    public class StyleChooser : Box {
        private MenuButton _btn;
        private Label _label;
        private Popover _pop;

        /**
         * Emitted when the user selects a style from the popover list.
         *
         * @param style_id   Machine-readable identifier (e.g. `"h1"`, `"body"`).
         * @param style_name Human-readable display name (e.g. `"Heading 1"`).
         */
        public signal void style_selected(string style_id, string style_name);

        private struct StyleEntry {
            public string id;
            public string name;
        }

        private static StyleEntry[] STYLES = {
            { "body",     "Body" },
            { "h1",       "Heading 1" },
            { "h2",       "Heading 2" },
            { "h3",       "Heading 3" },
            { "h4",       "Heading 4" },
            { "quote",    "Quote" },
            { "code",     "Code" },
            { "bullet",   "Bulleted List" },
            { "numbered", "Numbered List" }
        };

        /**
         * Updates the button label to reflect the currently active style without
         * emitting `style_selected`.
         *
         * @param style_id The id of the style to mark as current.
         */
        public void set_current_style(string style_id) {
            foreach (var s in STYLES) {
                if (s.id == style_id) {
                    _label.label = s.name;
                    return;
                }
            }
        }

        public StyleChooser() {
            Object(orientation: Orientation.HORIZONTAL, spacing: 0);

            _label = new Label("Body");
            _label.xalign = 0;
            _label.set_size_request(130, -1);

            var list_box = new Box(Orientation.VERTICAL, 0);
            list_box.add_css_class("style-chooser-list");
            list_box.margin_top = 4;
            list_box.margin_bottom = 4;

            foreach (var s in STYLES) {
                var lbl = new Label(s.name);
                lbl.xalign = 0;
                lbl.halign = Align.START;
                var item_btn = new Button();
                item_btn.set_child(lbl);
                item_btn.has_frame = false;
                item_btn.halign = Align.FILL;
                item_btn.add_css_class("style-chooser-item");
                item_btn.add_css_class("style-item-" + s.id);
                string sid = s.id;
                string sname = s.name;
                item_btn.clicked.connect(() => {
                    _label.label = sname;
                    style_selected(sid, sname);
                    _pop.popdown();
                });
                list_box.append(item_btn);
            }

            var scroll = new ScrolledWindow();
            scroll.set_child(list_box);
            scroll.set_policy(PolicyType.NEVER, PolicyType.AUTOMATIC);
            scroll.max_content_height = 300;
            scroll.propagate_natural_height = true;

            _pop = new Popover();
            _pop.set_child(scroll);

            _btn = new MenuButton();
            _btn.add_css_class("singularity-button");
            _btn.add_css_class("style-chooser");
            _btn.set_child(_label);
            _btn.set_popover(_pop);

            append(_btn);
        }
    }
}
