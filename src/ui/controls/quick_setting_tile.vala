using Gtk;

namespace Singularity.Widgets {

    /**
     * A compact icon+label tile button for quick-settings panels.
     *
     * Supports 2-state (on/off) and 3-state (e.g. power profiles) toggles.
     * Use `state` for multi-step tiles; `active` is a convenience
     * bool that maps to `state > 0`.
     *
     * CSS classes applied automatically:
     * - `.quick-setting-tile`          - always present
     * - `.active`                      - when state == n_states − 1 (fully on)
     * - `.state-partial`               - when 0 < state < n_states − 1 (middle)
     *
     * For tiles that navigate to a settings page when the chevron is tapped,
     * wrap in a Box with CSS class `.quick-setting-group` and append a button
     * with `.quick-setting-nav-btn` (see system_view.vala `make_tile_with_nav`).
     */
    public class QuickSettingTile : Button {

        private Image _icon;
        private Label _title_label;
        private Label _subtitle_label;
        private Box _main_box;
        private Box _text_box;

        private uint _pop_id = 0;
        private bool _pop_b = false;
        private int _state = 0;
        private int _n_states = 2;
        private bool _auto_toggle = true;

        // -- Public properties ------------------------------------------------

        /** Icon name shown on the left of the tile. */
        public string icon_name {
            set { _icon.icon_name = value; }
            owned get { return _icon.icon_name; }
        }

        /** Primary label. */
        public string title {
            set { _title_label.label = value; }
            get { return _title_label.label; }
        }

        /** Secondary dimmed label shown below the title; hidden when empty. */
        public string subtitle {
            set {
                _subtitle_label.label = value;
                _subtitle_label.visible = (value != null && value != "");
            }
            get { return _subtitle_label.label; }
        }

        /**
         * Number of states this tile cycles through (2 or 3).
         * Must be set before first use; defaults to 2.
         */
        public int n_states {
            get { return _n_states; }
            set { _n_states = (value > 1) ? value : 2; }
        }

        /**
         * Current state index (0 ... n_states − 1).
         * Changing this updates the `.active` / `.state-partial` CSS classes.
         */
        public int state {
            get { return _state; }
            set {
                _state = value.clamp(0, _n_states - 1);
                _sync_css();
                notify_property("active");
            }
        }

        /**
         * Convenience bool: true when `state == n_states − 1` (fully active).
         * Setting `active = true` sets `state = n_states − 1`; false, 0.
         */
        public bool active {
            get { return _state == _n_states - 1; }
            set {
                _state = value ? (_n_states - 1) : 0;
                _sync_css();
            }
        }

        /**
         * When true (default), clicking the tile advances `state` by 1,
         * wrapping back to 0 after the last state.
         * Set to false for tiles whose click handler manages state externally.
         */
        public bool auto_toggle {
            get { return _auto_toggle; }
            set { _auto_toggle = value; }
        }

        public bool compact {
            set {
                _text_box.visible = !value;
                _main_box.spacing = value ? 0 : 10;
                _main_box.halign = value ? Align.CENTER : Align.FILL;
                _main_box.margin_start = value ? 0 : 2;
                _main_box.margin_end = value ? 0 : 2;
                _main_box.margin_top = value ? 0 : 6;
                _main_box.margin_bottom = value ? 0 : 6;
            }
        }

        // -- Constructor ------------------------------------------------------

        public QuickSettingTile(string title, string icon_name, bool is_active = false) {
            Object();
            this.title = title;
            this.icon_name = icon_name;
            this.active = is_active;
        }

        // Built in construct so .ui/vetro instances are assembled too; the
        // title/icon-name/subtitle properties are then applied by GtkBuilder.
        construct {
            add_css_class("quick-setting-tile");

            _main_box = new Box(Orientation.HORIZONTAL, 10);
            _main_box.valign = Align.CENTER;
            _main_box.margin_start = 2;
            _main_box.margin_end = 2;
            _main_box.margin_top = 6;
            _main_box.margin_bottom = 6;

            _icon = new Image();
            _icon.pixel_size = 20;
            _icon.add_css_class("tile-icon");
            _main_box.append(_icon);

            _text_box = new Box(Orientation.VERTICAL, 0);
            _text_box.valign = Align.CENTER;
            _text_box.hexpand = true;

            _title_label = new Label("");
            _title_label.add_css_class("tile-title");
            _title_label.halign = Align.START;
            _title_label.ellipsize = Pango.EllipsizeMode.END;
            _text_box.append(_title_label);

            _subtitle_label = new Label("");
            _subtitle_label.add_css_class("tile-subtitle");
            _subtitle_label.halign = Align.START;
            _subtitle_label.ellipsize = Pango.EllipsizeMode.END;
            _subtitle_label.visible = false;
            _text_box.append(_subtitle_label);

            _main_box.append(_text_box);
            set_child(_main_box);

            clicked.connect(() => {
                if (_auto_toggle) {
                    state = (_state + 1) % _n_states;
                }
                _pop();
            });
        }

        private void _pop() {
            Widget target = this;
            var group = get_parent();
            if (group != null && group.has_css_class("quick-setting-group")) target = group;
            target.remove_css_class("tile-pop-a");
            target.remove_css_class("tile-pop-b");
            _pop_b = !_pop_b;
            target.add_css_class(_pop_b ? "tile-pop-b" : "tile-pop-a");
            if (_pop_id != 0) Source.remove(_pop_id);
            _pop_id = Timeout.add(600, () => {
                target.remove_css_class("tile-pop-a");
                target.remove_css_class("tile-pop-b");
                _pop_id = 0;
                return Source.REMOVE;
            });
        }

        // -- Internal ---------------------------------------------------------

        private void _sync_css() {
            remove_css_class("active");
            remove_css_class("state-partial");
            if (_state == _n_states - 1) {
                add_css_class("active");
            } else if (_state > 0) {
                add_css_class("state-partial");
            }
        }
    }
}
