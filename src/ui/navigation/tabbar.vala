using Gtk;

namespace Singularity.Widgets {

    /**
     * A horizontal tab bar that mirrors the pages of a Gtk.Notebook.
     *
     * Automatically synchronizes tabs with notebook pages: adds/removes tabs,
     * tracks the active page, and reflects label changes in real time.
     * When only one page is open, the close button hides.
     */
    public class TabBar : Box {
        private Notebook notebook;
        // Maps page widget, label-change handler ID so we can disconnect on removal
        private HashTable<Widget, ulong> label_handler_ids;

        /**
         * Creates a tab bar bound to the given notebook.
         *
         * @param notebook The Gtk.Notebook whose pages to mirror
         */
        public TabBar(Notebook notebook) {
            Object(orientation: Orientation.HORIZONTAL, spacing: 6);
            this.notebook = notebook;
            label_handler_ids = new HashTable<Widget, ulong>(direct_hash, direct_equal);
            add_css_class("tab-bar");
            notebook.page_added.connect(on_page_added);
            notebook.page_removed.connect(on_page_removed);
            notebook.switch_page.connect(on_switch_page);
            for (int i = 0; i < notebook.get_n_pages(); i++) {
                var page = notebook.get_nth_page(i);
                add_tab_button(page);
            }
        }

        private void on_page_added(Widget page, uint page_num) {
            add_tab_button(page);
            update_single_mode();
        }

        private void on_page_removed(Widget page, uint page_num) {
            // Disconnect the label-change handler before removing the button
            ulong hid = label_handler_ids.get(page);
            if (hid != 0) {
                var label_widget = notebook.get_tab_label(page);
                if (label_widget is Label)
                    ((Label)label_widget).disconnect(hid);
                label_handler_ids.remove(page);
            }
            Widget? child = get_first_child();
            while (child != null) {
                var btn = child as TabButton;
                if (btn != null && btn.page == page) {
                    remove(child);
                    break;
                }
                child = child.get_next_sibling();
            }
            update_single_mode();
        }

        private void on_switch_page(Widget page, uint page_num) {
            Widget? child = get_first_child();
            while (child != null) {
                var btn = child as TabButton;
                if (btn != null) {
                    if (btn.page == page) {
                        btn.set_active(true);
                    } else {
                        btn.set_active(false);
                    }
                }
                child = child.get_next_sibling();
            }
        }

        private void add_tab_button(Widget page) {
            var btn = new TabButton(page);
            btn.clicked.connect(() => {
                int page_num = notebook.page_num(page);
                if (page_num != -1) {
                    notebook.set_current_page(page_num);
                }
            });
            btn.close_clicked.connect(() => {
                int page_num = notebook.page_num(page);
                if (page_num != -1) {
                    notebook.remove_page(page_num);
                }
            });
            var label_widget = notebook.get_tab_label(page);
            if (label_widget is Label) {
                btn.set_label(((Label)label_widget).label);
                ulong hid = ((Label)label_widget).notify["label"].connect((s, p) => {
                    btn.set_label(((Label)label_widget).label);
                });
                label_handler_ids.set(page, hid);
            } else {
                btn.set_label("Tab");
            }
            append(btn);
            if (notebook.get_current_page() == notebook.page_num(page)) {
                btn.set_active(true);
            }
            update_single_mode();
        }

        private void update_single_mode() {
            bool single = notebook.get_n_pages() <= 1;
            Widget? child = get_first_child();
            while (child != null) {
                var btn = child as TabButton;
                if (btn != null) btn.set_single_mode(single);
                child = child.get_next_sibling();
            }
        }
    }
    /**
     * A single tab button inside a TabBar.
     *
     * Renders as a pill with an ellipsised label and a close (×) button.
     * Emits `clicked` when the user clicks the label area and
     * `close_clicked` when the × button is pressed.
     */
    public class TabButton : Box {
        /** The notebook page widget this button represents. */
        public Widget page { get; private set; }
        /** Emitted when the user selects this tab. */
        public signal void clicked();
        /** Emitted when the user clicks the close (×) button. */
        public signal void close_clicked();
        private Label label_widget;
        private Button close_btn;

        /**
         * Creates a tab button for the given notebook page.
         *
         * @param page The notebook page widget this button represents.
         */
        public TabButton(Widget page) {
            Object(orientation: Orientation.HORIZONTAL, spacing: 0);
            this.page = page;
            add_css_class("tab-button");
            add_css_class("flat");
            hexpand = true;
            var center_box = new CenterBox();
            center_box.hexpand = true;
            center_box.halign = Align.FILL;
            append(center_box);
            label_widget = new Label("");
            label_widget.ellipsize = Pango.EllipsizeMode.END;
            label_widget.max_width_chars = 20;
            label_widget.halign = Align.CENTER;
            center_box.set_center_widget(label_widget);
            close_btn = new Button.from_icon_name("window-close-symbolic");
            close_btn.add_css_class("tab-close-button");
            close_btn.valign = Align.CENTER;
            close_btn.vexpand = false;
            close_btn.has_frame = false;
            close_btn.set_size_request(20, 20);
            close_btn.clicked.connect(() => {
                close_clicked();
            });
            center_box.set_end_widget(close_btn);
            var gesture = new GestureClick();
            gesture.button = 1;
            gesture.pressed.connect((n, x, y) => {
                var pick = this.pick(x, y, PickFlags.DEFAULT);
                if (pick != null && pick.has_css_class("tab-close-button")) {
                    return;
                }
                clicked();
            });
            add_controller(gesture);
        }

        /** Updates the visible label text. @param text New label. */
        public void set_label(string text) {
            label_widget.label = text;
        }

        /** Highlights or unhighlights this tab. @param active `true` to mark as active. */
        public void set_active(bool active) {
            if (active) {
                add_css_class("active");
            } else {
                remove_css_class("active");
            }
        }

        /**
         * Enables or disables single-tab mode.
         *
         * In single-tab mode the close button is hidden and an alternate
         * CSS style is applied.
         *
         * @param single `true` when this is the only tab open.
         */
        public void set_single_mode(bool single) {
            close_btn.visible = !single;
            if (single) {
                remove_css_class("active");
                add_css_class("single-tab");
            } else {
                remove_css_class("single-tab");
            }
        }
    }
}
