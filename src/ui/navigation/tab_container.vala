using Gtk;

namespace Singularity.Widgets {

    /**
     * A complete tab-pane widget combining a scrollable TabBar
     * and a hidden Gtk.Notebook.
     *
     * The tab bar appears automatically once two or more pages exist.
     * Add pages with `add_tab()` and remove them with `remove_tab()`.
     */
    public class TabContainer : Box {
    /** Scrollable wrapper around the tab bar; hidden when there is only one tab. */
        public ScrolledWindow tab_scroll { get; private set; }
        /** The underlying tab bar. */
        public TabBar tab_bar { get; private set; }
    /** The underlying Gtk.Notebook (tabs hidden; managed via the tab bar). */
        public Notebook notebook { get; private set; }

        /** Forwarded from the underlying notebook: a page was added. */
        public signal void page_added(Widget child, uint page_num);
        /** Forwarded from the underlying notebook: a page was removed. */
        public signal void page_removed(Widget child, uint page_num);
        /** Forwarded from the underlying notebook: the visible page changed. */
        public signal void switch_page(Widget? page, uint page_num);

        /** Creates a new tab container. */
        public TabContainer() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            notebook = new Notebook();
            notebook.hexpand = true;
            notebook.vexpand = true;
            notebook.show_tabs = false;
            tab_bar = new TabBar(notebook);
            tab_bar.hexpand = true;
            tab_bar.halign = Align.FILL;
            tab_scroll = new ScrolledWindow();
            tab_scroll.set_policy(PolicyType.AUTOMATIC, PolicyType.NEVER);
            tab_scroll.vscrollbar_policy = PolicyType.NEVER;
            tab_scroll.set_child(tab_bar);
            tab_scroll.hexpand = true;
            tab_scroll.halign = Align.FILL;
            tab_scroll.margin_start = 8;
            tab_scroll.margin_end = 8;
            tab_scroll.add_css_class("terminal-tab-scroll");
            tab_scroll.add_css_class("flat");
            append(tab_scroll);
            append(notebook);
            notebook.page_added.connect((p, n) => {
                update_tab_scroll_visibility();
                page_added(p, n);
            });
            notebook.page_removed.connect((p, n) => {
                update_tab_scroll_visibility();
                page_removed(p, n);
            });
            notebook.switch_page.connect((p, n) => switch_page(p, n));
            update_tab_scroll_visibility();
        }

        /**
         * Adds a new tab.
         *
         * @param content Widget to show when this tab is selected.
         * @param title   Label text shown on the tab.
         */
        public void add_tab(Widget content, string title) {
            var label = new Label(title);
            notebook.append_page(content, label);
            content.visible = true;
        }

        /**
         * Removes the tab containing the given widget.
         *
         * @param content The content widget passed to `add_tab()`.
         */
        public void remove_tab(Widget content) {
            int page_num = notebook.page_num(content);
            if (page_num != -1) {
                notebook.remove_page(page_num);
            }
        }

        private void update_tab_scroll_visibility() {
            tab_scroll.visible = notebook.get_n_pages() > 1;
        }

        /** Returns the total number of open tabs. */
        public int get_n_pages() {
            return notebook.get_n_pages();
        }

        /** Returns the content widget of the currently selected tab, or `null`. */
        public Widget? get_current_page() {
            return notebook.get_nth_page(notebook.get_current_page());
        }

        /**
         * Updates the title of the tab containing the given widget.
         *
         * @param content The content widget whose tab label to change.
         * @param title   New label text.
         */
        public void set_tab_title(Widget content, string title) {
            var label = notebook.get_tab_label(content) as Label;
            if (label != null) {
                label.label = title;
            }
        }
    }
}
