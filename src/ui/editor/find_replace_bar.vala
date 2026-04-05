using Gtk;

namespace Singularity.Widgets {

    /**
     * An inline find-and-replace bar that slides down inside a text editor.
     *
     * Contains a find entry, match counter, prev/next navigation buttons,
     * a toggle to reveal the replace row, and a close button.
     * Connect to the emitted signals to drive the underlying text buffer.
     */
    public class FindReplaceBar : Box {
        private Revealer _revealer;
        private Entry _find_entry;
        private Entry _replace_entry;
        private Label _match_label;
        private Box _replace_row;
        private bool _replace_visible = false;

        /** Whether the bar is currently revealed (visible to the user). */
        public bool reveal_child {
            get { return _revealer.reveal_child; }
            set { _revealer.reveal_child = value; }
        }

        /** Emitted when the user requests the next occurrence of the query. */
        public signal void find_next(string query);
        /** Emitted when the user requests the previous occurrence of the query. */
        public signal void find_prev(string query);
        /** Emitted when the user requests replacing the current match. */
        public signal void replace_one(string query, string replacement);
        /** Emitted when the user requests replacing all matches. */
        public signal void replace_all(string query, string replacement);
        /** Emitted when the bar is closed by the user. */
        public signal void closed();

        /** The current text in the find entry. */
        public string find_text {
            get { return _find_entry.text; }
            set { _find_entry.text = value; }
        }

        /**
         * Updates the match counter label.
         *
         * @param current 1-based index of the currently highlighted match.
         * @param total   Total number of matches found (0 = no matches).
         */
        public void set_match_info(int current, int total) {
            if (total == 0)
                _match_label.label = "No matches";
            else
                _match_label.label = "%d of %d".printf(current, total);
        }

        public FindReplaceBar() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("write-find-bar");

            var outer = new Box(Orientation.VERTICAL, 0);
            outer.add_css_class("write-find-bar-inner");

            // ── Find row ──
            var find_row = new Box(Orientation.HORIZONTAL, 4);
            find_row.margin_top = 6;
            find_row.margin_bottom = 2;
            find_row.margin_start = 10;
            find_row.margin_end = 10;

            _find_entry = new Entry();
            _find_entry.placeholder_text = "Find…";
            _find_entry.hexpand = true;
            _find_entry.activate.connect(() => find_next(_find_entry.text));
            _find_entry.changed.connect(() => {
                if (_find_entry.text != "") find_next(_find_entry.text);
                else set_match_info(0, 0);
            });

            _match_label = new Label("");
            _match_label.add_css_class("dim-label");
            _match_label.add_css_class("caption");
            _match_label.width_chars = 10;

            var prev_btn = make_icon_btn("go-up-symbolic", "Previous match");
            prev_btn.clicked.connect(() => find_prev(_find_entry.text));

            var next_btn = make_icon_btn("go-down-symbolic", "Next match");
            next_btn.clicked.connect(() => find_next(_find_entry.text));

            var toggle_replace = make_icon_btn("edit-find-replace-symbolic", "Show Replace");
            toggle_replace.clicked.connect(() => {
                _replace_visible = !_replace_visible;
                _replace_row.visible = _replace_visible;
                if (_replace_visible) _replace_entry.grab_focus();
            });

            var close_btn = make_icon_btn("window-close-symbolic", "Close");
            close_btn.clicked.connect(() => {
                _revealer.reveal_child = false;
                closed();
            });

            find_row.append(_find_entry);
            find_row.append(_match_label);
            find_row.append(prev_btn);
            find_row.append(next_btn);
            find_row.append(toggle_replace);
            find_row.append(close_btn);
            outer.append(find_row);

            // ── Replace row (hidden) ──
            _replace_row = new Box(Orientation.HORIZONTAL, 4);
            _replace_row.margin_top = 2;
            _replace_row.margin_bottom = 6;
            _replace_row.margin_start = 10;
            _replace_row.margin_end = 10;
            _replace_row.visible = false;

            _replace_entry = new Entry();
            _replace_entry.placeholder_text = "Replace with…";
            _replace_entry.hexpand = true;
            _replace_entry.activate.connect(() => replace_one(_find_entry.text, _replace_entry.text));

            var rep_btn = new Button.with_label("Replace");
            rep_btn.has_frame = false;
            rep_btn.clicked.connect(() => replace_one(_find_entry.text, _replace_entry.text));

            var rep_all_btn = new Button.with_label("Replace All");
            rep_all_btn.has_frame = false;
            rep_all_btn.clicked.connect(() => replace_all(_find_entry.text, _replace_entry.text));

            _replace_row.append(_replace_entry);
            _replace_row.append(rep_btn);
            _replace_row.append(rep_all_btn);
            outer.append(_replace_row);

            _revealer = new Revealer();
            _revealer.transition_type = RevealerTransitionType.SLIDE_DOWN;
            _revealer.reveal_child = false;
            _revealer.set_child(outer);

            append(_revealer);
        }

        /** Reveals the bar and focuses the find entry. */
        public void open_find() {
            _revealer.reveal_child = true;
            _find_entry.grab_focus();
        }

        /** Reveals the bar, expands the replace row, and focuses the replace entry. */
        public void open_replace() {
            _revealer.reveal_child = true;
            _replace_visible = true;
            _replace_row.visible = true;
            _replace_entry.grab_focus();
        }

        private Button make_icon_btn(string icon, string tooltip) {
            var btn = new Button();
            btn.has_frame = false;
            btn.tooltip_text = tooltip;
            var img = new Image.from_icon_name(icon);
            img.pixel_size = 16;
            btn.set_child(img);
            return btn;
        }
    }
}
