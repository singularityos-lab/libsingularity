using Gtk;

namespace Singularity.Widgets {

    /**
     * A welcome/start page widget for Singularity apps.
     *
     * Split layout: LEFT pane (icon + title + subtitle + actions),
     * RIGHT pane (extra widget, e.g. recent files list).
     *
     * Responsive: when width < 680 px or no extra widget, right pane moves
     * below the left pane (vertical stacking).
     *
     * Action layout rules:
     * - 1–2 actions: stacked cards (icon + title + description)
     * - 3+ actions: list rows (icon + title + description + chevron)
     */
    public class WelcomePage : Box {

        public signal void close_requested();

        /** Whether to show the close (×) button in the top-right corner. */
        public bool show_close_button {
            get { return _close_btn.visible; }
            set { _close_btn.visible = value; }
        }

        /** Name of the symbolic icon shown above the title. Empty = no icon. */
        public string app_icon_name {
            get { return _icon_name; }
            set {
                _icon_name = value;
                if (value != "") {
                    _app_icon.icon_name = value;
                    _app_icon.visible = true;
                } else {
                    _app_icon.visible = false;
                }
            }
        }

        /** Main title text (large, bold). */
        public new string title {
            get { return _title_lbl.label; }
            set {
                _title_lbl.label = value;
                _title_lbl.visible = value != "";
            }
        }

        /** Subtitle / tagline (smaller, muted). */
        public string subtitle {
            get { return _subtitle_lbl.label; }
            set {
                _subtitle_lbl.label = value;
                _subtitle_lbl.visible = value != "";
            }
        }

        // ── Private state ─────────────────────────────────────────────────

        private string _icon_name = "";
        private Image _app_icon;
        private Label _title_lbl;
        private Label _subtitle_lbl;
        private Button _close_btn;
        private Box _actions_box;
        private Box _split_box;
        private Box _left_pane;
        private Box _right_pane;
        private bool _is_wide = false;

        private struct ActionEntry {
            public string icon;
            public string label;
            public string description;
            public ActionCallback callback;
        }

        [CCode (has_target = true)]
        public delegate void ActionCallback();

        private ActionEntry[] _actions = {};
        private bool _actions_built = false;

        // ── Constructor ───────────────────────────────────────────────────

        public WelcomePage() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("welcome-page");

            // Top bar: close button
            var top_bar = new Box(Orientation.HORIZONTAL, 0);
            top_bar.margin_top = 8;
            top_bar.margin_end = 8;

            _close_btn = new Singularity.Widgets.IconButton("window-close-symbolic", "Close");
            _close_btn.halign = Align.END;
            _close_btn.hexpand = true;
            _close_btn.visible = false;
            _close_btn.clicked.connect(() => close_requested());
            top_bar.append(_close_btn);
            append(top_bar);

            // Scrollable body
            var scroll = new ScrolledWindow();
            scroll.set_policy(PolicyType.NEVER, PolicyType.AUTOMATIC);
            scroll.hexpand = true;
            scroll.vexpand = true;

            // Split box - orientation toggled dynamically in size_allocate
            _split_box = new Box(Orientation.HORIZONTAL, 0);
            _split_box.add_css_class("welcome-page-split");
            _split_box.hexpand = true;
            _split_box.vexpand = true;

            // ── Left pane: icon + title + subtitle + actions ───────────────
            _left_pane = new Box(Orientation.VERTICAL, 28);
            _left_pane.add_css_class("welcome-page-left");
            _left_pane.valign = Align.CENTER;
            _left_pane.halign = Align.CENTER;
            _left_pane.hexpand = true;
            _left_pane.margin_top = 52;
            _left_pane.margin_bottom = 48;
            _left_pane.margin_start = 48;
            _left_pane.margin_end = 48;

            var header = new Box(Orientation.VERTICAL, 6);
            header.halign = Align.CENTER;

            _app_icon = new Image();
            _app_icon.pixel_size = 72;
            _app_icon.halign = Align.CENTER;
            _app_icon.visible = false;
            _app_icon.add_css_class("welcome-page-icon");
            header.append(_app_icon);

            _title_lbl = new Label("");
            _title_lbl.add_css_class("title-1");
            _title_lbl.halign = Align.CENTER;
            _title_lbl.visible = false;
            header.append(_title_lbl);

            _subtitle_lbl = new Label("");
            _subtitle_lbl.add_css_class("dim-label");
            _subtitle_lbl.halign = Align.CENTER;
            _subtitle_lbl.visible = false;
            header.append(_subtitle_lbl);

            _left_pane.append(header);

            _actions_box = new Box(Orientation.VERTICAL, 0);
            _actions_box.halign = Align.CENTER;
            _actions_box.hexpand = true;
            _left_pane.append(_actions_box);

            _split_box.append(_left_pane);

            // ── Right pane: extra widget (recent files, etc.) ──────────────
            _right_pane = new Box(Orientation.VERTICAL, 0);
            _right_pane.add_css_class("welcome-page-right");
            _right_pane.hexpand = true;
            _right_pane.vexpand = true;
            _right_pane.visible = false;
            _split_box.append(_right_pane);

            scroll.set_child(_split_box);
            append(scroll);

            map.connect(ensure_actions_built);
        }

        // ── Responsive layout ─────────────────────────────────────────────

        public override void size_allocate(int width, int height, int baseline) {
            bool should_wide = width >= 680 && _right_pane.visible;
            if (should_wide != _is_wide) {
                _is_wide = should_wide;
                _split_box.orientation = _is_wide ? Orientation.HORIZONTAL : Orientation.VERTICAL;
                if (_is_wide) {
                    _left_pane.hexpand = false;
                    _left_pane.set_size_request(320, -1);
                    _right_pane.valign = Align.FILL;
                    _right_pane.vexpand = true;
                } else {
                    _left_pane.hexpand = true;
                    _left_pane.set_size_request(560, -1);
                    _right_pane.valign = Align.START;
                }
            }
            // Responsive margins: shrink on narrow widths
            int h_margin = width < 400 ? 16 : (width < 600 ? 28 : 48);
            _left_pane.margin_start = h_margin;
            _left_pane.margin_end = h_margin;
            base.size_allocate(width, height, baseline);
        }

        // ── Public API ────────────────────────────────────────────────────

        /**
         * Register an action that will appear in the actions area.
         * Call before the widget is mapped.
         */
        public void add_action(string icon_name, string label,
                               string description, ActionCallback callback) {
            _actions += ActionEntry() {
                icon = icon_name,
                label = label,
                description = description,
                callback = callback
            };
        }

        /**
         * Set an extra widget shown in the right pane (e.g. a recent-files list).
         * Replaces any previously set extra widget. Pass null to hide the right pane.
         */
        public void set_extra_widget(Widget? widget) {
            Widget? child = _right_pane.get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                _right_pane.remove(child);
                child = next;
            }
            if (widget != null) {
                _right_pane.append((!)widget);
                _right_pane.visible = true;
            } else {
                _right_pane.visible = false;
            }
        }

        // ── Private helpers ───────────────────────────────────────────────

        private void ensure_actions_built() {
            if (_actions_built) return;
            _actions_built = true;
            if (_actions.length == 0) return;
            if (_actions.length <= 2) {
                build_card_actions();
            } else {
                build_list_actions();
            }
        }

        /** 1–2 actions: stacked cards (icon left, text right). */
        private void build_card_actions() {
            var col = new Box(Orientation.VERTICAL, 10);
            col.halign = Align.FILL;
            col.hexpand = true;

            foreach (var entry in _actions) {
                var card = new Button();
                card.add_css_class("welcome-page-card");
                card.has_frame = false;
                card.hexpand = true;

                var card_box = new Box(Orientation.HORIZONTAL, 16);
                card_box.margin_top = 16;
                card_box.margin_bottom = 16;
                card_box.margin_start = 18;
                card_box.margin_end = 18;
                card_box.valign = Align.CENTER;

                var icon = new Image.from_icon_name(entry.icon);
                icon.pixel_size = 36;
                icon.valign = Align.CENTER;

                var text_box = new Box(Orientation.VERTICAL, 3);
                text_box.valign = Align.CENTER;
                text_box.hexpand = true;

                var title = new Label(entry.label);
                title.add_css_class("title-4");
                title.halign = Align.START;
                title.xalign = 0;

                var desc = new Label(entry.description);
                desc.add_css_class("dim-label");
                desc.add_css_class("caption");
                desc.halign = Align.START;
                desc.wrap = true;
                desc.xalign = 0;

                text_box.append(title);
                text_box.append(desc);
                card_box.append(icon);
                card_box.append(text_box);
                card.set_child(card_box);

                var cb = entry.callback;
                card.clicked.connect(() => cb());
                col.append(card);
            }

            _actions_box.append(col);
        }

        /** 3+ actions: vertical list rows. */
        private void build_list_actions() {
            var list_box = new Box(Orientation.VERTICAL, 4);
            list_box.add_css_class("welcome-page-list");
            list_box.halign = Align.FILL;
            list_box.hexpand = true;

            foreach (var entry in _actions) {
                var btn = new Button();
                btn.add_css_class("welcome-page-row");
                btn.has_frame = false;

                var row = new Box(Orientation.HORIZONTAL, 14);
                row.margin_top = 10;
                row.margin_bottom = 10;
                row.margin_start = 14;
                row.margin_end = 14;

                var icon = new Image.from_icon_name(entry.icon);
                icon.pixel_size = 32;
                icon.valign = Align.CENTER;

                var text_box = new Box(Orientation.VERTICAL, 2);
                text_box.valign = Align.CENTER;
                text_box.hexpand = true;

                var title = new Label(entry.label);
                title.add_css_class("title-4");
                title.halign = Align.START;
                title.xalign = 0;

                var desc = new Label(entry.description);
                desc.add_css_class("dim-label");
                desc.add_css_class("caption");
                desc.halign = Align.START;
                desc.wrap = true;
                desc.xalign = 0;

                text_box.append(title);
                text_box.append(desc);

                var chevron = new Image.from_icon_name("go-next-symbolic");
                chevron.pixel_size = 16;
                chevron.valign = Align.CENTER;
                chevron.add_css_class("dim-label");

                row.append(icon);
                row.append(text_box);
                row.append(chevron);
                btn.set_child(row);

                var cb = entry.callback;
                btn.clicked.connect(() => cb());
                list_box.append(btn);
            }

            _actions_box.append(list_box);
        }
    }
}
