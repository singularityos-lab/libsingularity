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
     * Action layout: vertical list rows (icon + title + description + chevron),
     * regardless of action count, so every Singularity app shares the same
     * welcome UX.
     */
    public class WelcomePage : Box {

        public signal void close_requested();

        /** The app's full-color hicolor icon shown above the title. Empty = no icon. */
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

        /**
         * Marks the page as the start of a section inside the app rather
         * than the app's start screen. A section page leaves the window's
         * bubbles and sidebar toggle in place. Default false.
         */
        public bool is_section {
            get { return _is_section; }
            set {
                if (_is_section == value) return;
                _is_section = value;
                if (!get_mapped()) return;
                if (value) _leave_host();
                else _join_host();
            }
        }

        /**
         * Lays the page out for embedding inside another scrolling view,
         * such as a settings page. The page then drops its own vertical
         * scrolling and reports the full height of its content, so the
         * outer view scrolls it. Default false.
         */
        public bool embedded {
            get { return _embedded; }
            set {
                _embedded = value;
                _scroll.vscrollbar_policy = value ? PolicyType.NEVER : PolicyType.AUTOMATIC;
                _scroll.propagate_natural_height = value;
            }
        }

        /**
         * Lays the page out for a narrow fixed-width column, such as the
         * shell sidebar: small top and bottom margins, no side margins,
         * and an action list as wide as the column. Default false.
         */
        public bool compact {
            get { return _compact; }
            set {
                _compact = value;
                _left_pane.margin_top = value ? 10 : 40;
                _left_pane.margin_bottom = value ? 8 : 36;
                _left_pane.margin_start = value ? 0 : 40;
                _left_pane.margin_end = value ? 0 : 40;
                _left_pane.spacing = value ? 12 : 20;
                _left_pane.halign = value ? Align.FILL : Align.CENTER;
                _actions_box.halign = value ? Align.FILL : Align.CENTER;
            }
        }

        /** Number of actions registered with add_action. */
        public int action_count {
            get { return _actions.length; }
        }

        /** Subtitle / tagline (smaller, muted). */
        public string subtitle {
            get { return _subtitle_lbl.label; }
            set {
                _subtitle_lbl.label = value;
                _subtitle_lbl.visible = value != "";
            }
        }

        // -- Private state -------------------------------------------------

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
        private bool _is_section = false;
        private bool _embedded = false;
        private bool _compact = false;
        private ScrolledWindow _scroll;

        private class ActionEntry {
            public string icon;
            public string label;
            public string description;
            public string? caption;
            public ActionCallback callback;
            public Widget? row = null;
            public Label? desc_label = null;

            public ActionEntry(string icon, string label, string description, string? caption,
                               owned ActionCallback callback) {
                this.icon = icon;
                this.label = label;
                this.description = description;
                this.caption = caption;
                this.callback = (owned) callback;
            }
        }

        [CCode (has_target = true)]
        public delegate void ActionCallback();

        private ActionEntry[] _actions = {};
        private bool _actions_built = false;

        // -- Constructor ---------------------------------------------------

        public WelcomePage() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
        }

        // Built in construct so .ui/vetro instances are assembled too; actions
        // are added imperatively via add_action.
        construct {
            orientation = Orientation.VERTICAL;
            spacing = 0;
            add_css_class("welcome-page");

            // Top bar: close button
            var top_bar = new Box(Orientation.HORIZONTAL, 0);
            top_bar.margin_top = 8;
            top_bar.margin_end = 8;

            _close_btn = new Singularity.Widgets.IconButton("window-close-symbolic", _("Close"));
            _close_btn.halign = Align.END;
            _close_btn.hexpand = true;
            _close_btn.visible = false;
            _close_btn.clicked.connect(() => close_requested());
            top_bar.append(_close_btn);
            append(top_bar);

            // Scrollable body
            var scroll = new ScrolledWindow();
            _scroll = scroll;
            scroll.set_policy(PolicyType.NEVER, PolicyType.AUTOMATIC);
            scroll.hexpand = true;
            scroll.vexpand = true;

            // Split box - orientation toggled dynamically in size_allocate
            _split_box = new Box(Orientation.HORIZONTAL, 0);
            _split_box.add_css_class("welcome-page-split");
            _split_box.hexpand = true;
            _split_box.vexpand = true;

            // -- Left pane: icon + title + subtitle + actions ---------------
            _left_pane = new Box(Orientation.VERTICAL, 20);
            _left_pane.add_css_class("welcome-page-left");
            _left_pane.valign = Align.CENTER;
            _left_pane.halign = Align.CENTER;
            _left_pane.hexpand = true;
            _left_pane.margin_top = 40;
            _left_pane.margin_bottom = 36;
            _left_pane.margin_start = 40;
            _left_pane.margin_end = 40;

            var header = new Box(Orientation.VERTICAL, 6);
            header.halign = Align.CENTER;

            _app_icon = new Image();
            _app_icon.pixel_size = 64;
            _app_icon.halign = Align.CENTER;
            _app_icon.visible = false;
            _app_icon.add_css_class("welcome-page-icon");
            header.append(_app_icon);

            _title_lbl = new Label("");
            _title_lbl.add_css_class("title-1");
            _title_lbl.wrap = true;
            _title_lbl.justify = Justification.CENTER;
            _title_lbl.visible = false;
            header.append(_title_lbl);

            _subtitle_lbl = new Label("");
            _subtitle_lbl.add_css_class("dim-label");
            _subtitle_lbl.wrap = true;
            _subtitle_lbl.justify = Justification.CENTER;
            _subtitle_lbl.visible = false;
            header.append(_subtitle_lbl);

            _left_pane.append(header);

            _actions_box = new Box(Orientation.VERTICAL, 0);
            _actions_box.halign = Align.CENTER;
            _actions_box.hexpand = true;
            _left_pane.append(_actions_box);

            _split_box.append(_left_pane);

            // -- Right pane: extra widget (recent files, etc.) --------------
            _right_pane = new Box(Orientation.VERTICAL, 0);
            _right_pane.add_css_class("welcome-page-right");
            _right_pane.hexpand        = true;
            _right_pane.vexpand        = true;
            _right_pane.visible        = false;
            _right_pane.margin_top     = 10;
            _right_pane.margin_bottom  = 10;
            _right_pane.margin_start   = 10;
            _right_pane.margin_end     = 10;
            _split_box.append(_right_pane);

            scroll.set_child(_split_box);
            append(scroll);

            map.connect(ensure_actions_built);
        }

        // -- Window integration --------------------------------------------

        private unowned Window? _host = null;

        public override void map() {
            base.map();
            if (!_is_section) _join_host();
        }

        public override void unmap() {
            _leave_host();
            base.unmap();
        }

        private void _join_host() {
            if (_host != null) return;
            _host = get_root() as Window;
            if (_host != null) _host.welcome_page_shown();
        }

        private void _leave_host() {
            if (_host != null) _host.welcome_page_hidden();
            _host = null;
        }

        // -- Responsive layout ---------------------------------------------

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
                    _left_pane.set_size_request(-1, -1);
                    _right_pane.valign = Align.START;
                }
            }
            // Responsive margins: shrink on narrow widths
            int h_margin = _compact ? 0 : (width < 400 ? 16 : (width < 600 ? 24 : 40));
            _left_pane.margin_start = h_margin;
            _left_pane.margin_end = h_margin;
            base.size_allocate(width, height, baseline);
        }

        // -- Public API ----------------------------------------------------

        /**
         * Register an action that will appear in the actions area.
         * Call before the widget is mapped.
         */
        public void add_action(string icon_name, string label,
                               string description, owned ActionCallback callback) {
            add_action_with_caption(icon_name, label, description, null, (owned) callback);
        }

        /**
         * Register an action with a caption shown dim at the right of its
         * row, for example the action's keyboard shortcut.
         * Call before the widget is mapped.
         */
        public void add_action_with_caption(string icon_name, string label,
                                            string description, string? caption,
                                            owned ActionCallback callback) {
            _actions += new ActionEntry(icon_name, label, description, caption, (owned) callback);
        }

        /**
         * Returns the title of the action at `index`, in the order the
         * actions were added.
         */
        public string get_action_label(int index) {
            return _actions[index].label;
        }

        /** Returns the description of the action at `index`. */
        public string get_action_description(int index) {
            return _actions[index].description;
        }

        public void set_action_description(int index, string description) {
            if (index < 0 || index >= _actions.length) return;
            _actions[index].description = description;
            if (_actions[index].desc_label != null) {
                _actions[index].desc_label.label = description;
                _actions[index].desc_label.visible = description != "";
            }
        }

        public Widget? get_action_widget(int index) {
            if (index < 0 || index >= _actions.length) return null;
            return _actions[index].row;
        }

        /** Returns the icon name of the action at `index`. */
        public string get_action_icon_name(int index) {
            return _actions[index].icon;
        }

        /**
         * Runs the callback of the action at `index`, as if its row had
         * been clicked. Used by search to open an action directly.
         */
        public void trigger_action(int index) {
            if (index < 0 || index >= _actions.length) return;
            _actions[index].callback();
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
                widget.add_css_class("welcome-page-right-content");
                _right_pane.append((!)widget);
                _right_pane.visible = true;
            } else {
                _right_pane.visible = false;
            }
        }

        // -- Private helpers -----------------------------------------------

        private void ensure_actions_built() {
            if (_actions_built) return;
            _actions_built = true;
            if (_actions.length == 0) return;
            build_list_actions();
        }

        /** 1-2 actions: stacked cards (icon left, text right). */
        private void build_card_actions() {
            var col = new Box(Orientation.VERTICAL, 10);
            col.halign = Align.FILL;
            col.hexpand = true;

            foreach (var entry in _actions) {
                var card = new Button();
                card.add_css_class("welcome-page-card");
                card.has_frame = false;
                card.hexpand = true;

                var card_box = new Box(Orientation.HORIZONTAL, 12);
                card_box.add_css_class("welcome-card-content");
                card_box.valign = Align.CENTER;

                string shown = large_icon_name(entry.icon);
                var icon = new Image.from_icon_name(shown);
                icon.pixel_size = shown.has_suffix("-symbolic") ? 20 : 32;
                icon.set_size_request(36, 36);
                icon.valign = Align.CENTER;

                var text_box = new Box(Orientation.VERTICAL, 3);
                text_box.valign = Align.CENTER;
                text_box.hexpand = true;

                var title = new Label(entry.label);
                title.add_css_class("title-4");
                title.xalign = 0;
                title.wrap = true;
                title.wrap_mode = Pango.WrapMode.WORD_CHAR;

                var desc = new Label(entry.description);
                desc.visible = entry.description != "";
                desc.add_css_class("dim-label");
                desc.add_css_class("caption");
                desc.wrap = true;
                desc.wrap_mode = Pango.WrapMode.WORD_CHAR;
                desc.xalign = 0;

                text_box.append(title);
                text_box.append(desc);
                card_box.append(icon);
                card_box.append(text_box);
                card.set_child(card_box);

                var action = entry;
                action.row = card;
                action.desc_label = desc;
                card.clicked.connect(() => action.callback());
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

                string shown = large_icon_name(entry.icon);
                var icon = new Image.from_icon_name(shown);
                icon.pixel_size = shown.has_suffix("-symbolic") ? 24 : 32;
                icon.set_size_request(32, 32);
                icon.valign = Align.CENTER;

                var text_box = new Box(Orientation.VERTICAL, 2);
                text_box.valign = Align.CENTER;
                text_box.hexpand = true;

                var title = new Label(entry.label);
                title.add_css_class("title-4");
                title.xalign = 0;
                title.wrap = true;
                title.wrap_mode = Pango.WrapMode.WORD_CHAR;

                var desc = new Label(entry.description);
                desc.visible = entry.description != "";
                desc.add_css_class("dim-label");
                desc.add_css_class("caption");
                desc.wrap = true;
                desc.wrap_mode = Pango.WrapMode.WORD_CHAR;
                desc.xalign = 0;

                text_box.append(title);
                text_box.append(desc);

                var chevron = new Image.from_icon_name("go-next-symbolic");
                chevron.pixel_size = 16;
                chevron.valign = Align.CENTER;
                chevron.add_css_class("dim-label");

                row.append(icon);
                row.append(text_box);
                if (entry.caption != null && entry.caption != "") {
                    var caption = new Label(entry.caption);
                    caption.add_css_class("dim-label");
                    caption.add_css_class("caption");
                    caption.valign = Align.CENTER;
                    row.append(caption);
                }
                row.append(chevron);
                btn.set_child(row);

                var action = entry;
                action.row = btn;
                action.desc_label = desc;
                btn.clicked.connect(() => action.callback());
                list_box.append(btn);
            }

            _actions_box.append(list_box);
        }
    }
}
