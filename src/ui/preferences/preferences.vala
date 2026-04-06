using Gtk;
using Gee;

namespace Singularity.Widgets {

    /**
     * A generic color theme descriptor used by ColorSchemePreview
     * and ColorSchemeRow.
     *
     * Applications that offer a theme chooser (terminals, editors, …) can
     * build their theme lists using this class, then pass them to
     * ColorSchemeRow.
     */
    public class ColorTheme : Object {
        /** Machine-readable identifier used to persist the user's choice. */
        public string id { get; set; }
        /** Human-readable display name shown beneath the preview swatch. */
        public string name { get; set; }
        /** Background colour as a CSS hex string, e.g. "#282c34". */
        public string background { get; set; }
        /** Default text colour as a CSS hex string. */
        public string foreground { get; set; }
        /**
         * 16-entry ANSI colour palette as CSS hex strings.
         * Indices 0–7 are the normal colours; 8–15 are the bright variants.
         */
        public string[] palette { get; set; }

        public ColorTheme(string id, string name, string background,
                          string foreground, string[] palette) {
            Object();
            this.id = id;
            this.name = name;
            this.background = background;
            this.foreground = foreground;
            this.palette = palette;
        }
    }

    /**
     * A group of preference rows with an optional title and description.
     *
     * Analogous to `Adw.PreferencesGroup`. Rows are stacked in a
     * Gtk.ListBox and separated visually from other groups.
     */
    public class PreferencesGroup : Box {
        private Box header_box;
        private Box title_box;
        private Box header_suffix_box;
        private Label? title_label;
        private Label? description_label;
        private ListBox list_box;
        public string title {
            get { return title_label != null ? title_label.label : ""; }
            set {
                if (title_label == null) {
                    title_label = new Label(value);
                    title_label.add_css_class("heading");
                    title_label.halign = Align.START;
                    title_box.prepend(title_label);
                } else {
                    title_label.label = value;
                }
            }
        }
        public string description {
            get { return description_label != null ? description_label.label : ""; }
            set {
                if (description_label == null) {
                    description_label = new Label(value);
                    description_label.add_css_class("dim-label");
                    description_label.halign = Align.START;
                    description_label.wrap = true;
                    description_label.max_width_chars = 50;
                    title_box.append(description_label);
                } else {
                    description_label.label = value;
                }
            }
        }

        public PreferencesGroup(string? title = null, string? description = null) {
            Object(orientation: Orientation.VERTICAL, spacing: 6);
            header_box = new Box(Orientation.HORIZONTAL, 12);
            header_box.margin_bottom = 6;
            header_box.margin_start = 6;
            header_box.margin_end = 6;
            header_box.valign = Align.CENTER;
            append(header_box);

            title_box = new Box(Orientation.VERTICAL, 2);
            title_box.hexpand = true;
            title_box.valign = Align.CENTER;
            header_box.append(title_box);

            header_suffix_box = new Box(Orientation.HORIZONTAL, 6);
            header_suffix_box.valign = Align.CENTER;
            header_box.append(header_suffix_box);

            if (title != null) this.title = title;
            if (description != null) this.description = description;
            list_box = new ListBox();
            list_box.add_css_class("preferences-group");
            list_box.selection_mode = SelectionMode.NONE;
            list_box.activate_on_single_click = true;
            // Row activation is handled by ActionRow.activate() override.
            // Do NOT connect row_activated here - it would cause the activated
            // signal to fire twice on keyboard activation (Enter key).
            append(list_box);
        }

        /**
         * Appends a widget to the right side of the group header row.
         *
         * @param widget The widget to add (e.g. a button or switch).
         */
        public void add_header_suffix(Widget widget) {
            header_suffix_box.append(widget);
        }

    /**
     * Appends a row to the group's list box.
     *
     * @param row Any Gtk.Widget — typically a PreferencesRow subclass.
     */
        public void add_row(Widget row) {
            list_box.append(row);
        }

        /**
         * Removes a previously added row from the group's list box.
         *
         * @param row The widget to remove.
         */
        public void remove_row(Widget row) {
            list_box.remove(row);
        }

        /** Removes all rows from the group's list box. */
        public void clear() {
            Widget? child = list_box.get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                list_box.remove(child);
                child = next;
            }
        }
    }
    /** Base class for all rows in a PreferencesGroup. */
    public class PreferencesRow : ListBoxRow {

        public PreferencesRow() {
            add_css_class("preferences-row");
        }
    }
    /**
     * A preference row with a title, optional subtitle, optional leading icon,
     * and support for suffix and prefix widgets.
     *
     * Activating the row (click or Enter) emits `activated`.
     * Subclasses (SwitchRow, EntryRow, …) connect to
     * `activated` to implement their specific interaction.
     */
    public class ActionRow : PreferencesRow {
        /** Emitted when the row is activated by a click or keyboard Enter. */
        public signal void activated();
        private Box main_box;
        private Box prefix_box;
        private Box suffix_box;
        protected Box labels_box;
        private Label title_label;
        private Label? subtitle_label;
        private Image? icon_image;
        public string title {
            get { return title_label.label; }
            set { title_label.label = value; }
        }
        public string subtitle {
            get { return subtitle_label != null ? subtitle_label.label : ""; }
            set {
                if (subtitle_label == null && value != "") {
                    subtitle_label = new Label(value);
                    subtitle_label.add_css_class("subtitle");
                    subtitle_label.halign = Align.START;
                    subtitle_label.wrap = true;
                    subtitle_label.wrap_mode = Pango.WrapMode.WORD_CHAR;
                    subtitle_label.xalign = 0f;
                    labels_box.append(subtitle_label);
                } else if (subtitle_label != null) {
                    subtitle_label.label = value;
                }
            }
        }
        public string icon_name {
            set {
                if (icon_image == null) {
                    icon_image = new Image.from_icon_name(value);
                    icon_image.pixel_size = 24;
                    icon_image.margin_end = 12;
                    prefix_box.append(icon_image);
                } else {
                    icon_image.icon_name = value;
                }
            }
        }

        public ActionRow(string title, string? subtitle = null, string? icon_name = null) {
            main_box = new Box(Orientation.HORIZONTAL, 0);
            main_box.margin_top = 8;
            main_box.margin_bottom = 8;
            main_box.margin_start = 12;
            main_box.margin_end = 12;
            set_child(main_box);
            prefix_box = new Box(Orientation.HORIZONTAL, 0);
            main_box.append(prefix_box);
            if (icon_name != null) {
                this.icon_name = icon_name;
            }
            labels_box = new Box(Orientation.VERTICAL, 2);
            labels_box.valign = Align.CENTER;
            labels_box.hexpand = true;
            main_box.append(labels_box);
            title_label = new Label(title);
            title_label.add_css_class("title");
            title_label.halign = Align.START;
            title_label.wrap = true;
            title_label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            title_label.xalign = 0f;
            labels_box.append(title_label);
            if (subtitle != null) {
                this.subtitle = subtitle;
            }
            suffix_box = new Box(Orientation.HORIZONTAL, 6);
            suffix_box.valign = Align.CENTER;
            main_box.append(suffix_box);
            this.activatable = true;
        }

    /**
     * Appends a widget to the trailing end of the row (after labels).
     *
     * @param widget The widget to add (e.g. a Gtk.Switch).
     */
        public void add_suffix(Widget widget) {
            suffix_box.append(widget);
        }

        /**
         * Prepends a widget to the leading end of the row (before the icon and labels).
         *
         * @param widget The widget to add.
         */
        public void add_prefix(Widget widget) {
            prefix_box.append(widget);
        }

        public override void activate() {
            // Do NOT call base.activate(): it would emit ListBox::row-activated
            // which, combined with this direct call, would fire activated() twice.
            activated();
        }
    }
    /**
     * An ActionRow with a toggle switch suffix.
     *
     * Clicking anywhere on the row (not just the switch widget) toggles the
     * value - consistent with standard GNOME preferences behaviour.
     * Bind `active` to a GSettings boolean key to persist the value.
     */
    public class SwitchRow : ActionRow {
        /**
         * The underlying Gtk.Switch widget.
         *
         * Exposed publicly because consumers frequently need to:
         * - bind `switch_btn` to a GSettings key via `settings.bind()`
         * - connect to `switch_btn.notify["active"]` for fine-grained reactions
         * - set `switch_btn.active` to reflect external state changes
         * These use-cases cannot be satisfied through the `active` property alone.
         */
        public Switch switch_btn;
        public bool active {
            get { return switch_btn.active; }
            set { switch_btn.active = value; }
        }
        private ulong _activated_handler = 0;

        public SwitchRow(string title, string? subtitle = null, bool active = false) {
            base(title, subtitle);
            switch_btn = new Switch();
            switch_btn.active = active;
            switch_btn.valign = Align.CENTER;
            switch_btn.can_focus = false;
            // Do NOT set can_target = false: that silently breaks GTK4 event
            // delivery so neither the Switch nor the row activation fires.
            add_suffix(switch_btn);
            // When the user clicks directly on the Switch, state_set fires
            // before the row's activated signal.  Block the activated handler
            // for that event loop cycle so it does not toggle a second time.
            switch_btn.state_set.connect((state) => {
                if (_activated_handler != 0)
                    SignalHandler.block(this, _activated_handler);
                GLib.Idle.add(() => {
                    if (_activated_handler != 0)
                        SignalHandler.unblock(this, _activated_handler);
                    return GLib.Source.REMOVE;
                });
                return false; // let the Switch update its own visual state
            });
            // Clicking anywhere else on the row fires activated() without
            // state_set having run, so the handler is unblocked and we toggle.
            _activated_handler = this.activated.connect(() => {
                switch_btn.active = !switch_btn.active;
            });
        }
    }
    /**
     * An ActionRow with a numeric spin-button suffix.
     */
    public class SpinRow : ActionRow {
    /** The underlying Gtk.SpinButton widget. */
        public SpinButton spin_btn;
        public double value {
            get { return spin_btn.value; }
            set { spin_btn.value = value; }
        }

        /**
         * Creates a spin row.
         *
         * @param title    Row label.
         * @param subtitle Optional subtitle shown below the title.
         * @param min      Minimum allowed value.
         * @param max      Maximum allowed value.
         * @param step     Increment step.
         * @param value    Initial value.
         */
        public SpinRow(string title, string? subtitle = null, double min, double max, double step, double value) {
            base(title, subtitle);
            spin_btn = new SpinButton.with_range(min, max, step);
            spin_btn.value = value;
            spin_btn.valign = Align.CENTER;
            add_suffix(spin_btn);
            this.activated.connect(() => {
                spin_btn.grab_focus();
            });
        }
    }
    /**
     * An ActionRow that expands to reveal additional rows below it.
     *
     * Add child rows with `add_row()`. Toggle programmatically via the
     * `expanded` property. Users can also click the row to toggle.
     */
    public class ExpanderRow : ActionRow {
        private Box content_box;
        private Revealer revealer;
        private Image arrow_icon;
        private bool _expanded = false;
        public bool expanded {
            get { return _expanded; }
            set {
                _expanded = value;
                revealer.reveal_child = value;
                if (value) {
                    arrow_icon.add_css_class("rotated");
                    arrow_icon.icon_name = "go-up-symbolic";
                } else {
                    arrow_icon.remove_css_class("rotated");
                    arrow_icon.icon_name = "go-down-symbolic";
                }
            }
        }

        public ExpanderRow(string title, string? subtitle = null, string? icon_name = null) {
            base(title, subtitle, icon_name);
            arrow_icon = new Image.from_icon_name("go-down-symbolic");
            add_suffix(arrow_icon);
            var internal_box = new Box(Orientation.VERTICAL, 0);
            internal_box.hexpand = true;
            var header = this.get_child();
            if (header != null) {
                this.set_child(null);
                header.valign = Align.CENTER;
                header.vexpand = true;
                internal_box.append(header);
            }
            revealer = new Revealer();
            revealer.transition_type = RevealerTransitionType.SLIDE_DOWN;
            content_box = new Box(Orientation.VERTICAL, 0);
            content_box.add_css_class("expander-content");
            revealer.set_child(content_box);
            internal_box.append(revealer);
            this.set_child(internal_box);
            this.activatable = false;
            var gesture = new GestureClick();
            gesture.released.connect(() => {
                expanded = !expanded;
            });
            this.add_controller(gesture);
        }

        public void add_row(Widget row) {
            content_box.append(row);
        }

        public void clear_rows() {
            Widget? child = content_box.get_first_child();
            while (child != null) {
                Widget? next = child.get_next_sibling();
                content_box.remove(child);
                child = next;
            }
        }
    }
    /**
     * An ActionRow with an inline text entry.
     *
     * Clicking the row focuses the entry. Signals `entry_changed` and
     * `entry_activated` mirror the underlying Gtk.Entry events.
     */
    public class EntryRow : ActionRow {
        protected Entry entry;
        protected Image status_icon;

        public string text {
            get { return entry.text; }
            set { entry.text = value; }
        }

        public signal void entry_changed();
        public signal void entry_activated();

        public EntryRow(string title, string? icon_name = null) {
            base(title, null, icon_name);

            // Tighten vertical margins — row has title + entry stacked
            var mb = this.get_child() as Box;
            if (mb != null) {
                mb.margin_top = 6;
                mb.margin_bottom = 6;
            }
            labels_box.spacing = 0;
            labels_box.valign = Align.CENTER;

            entry = new Entry();
            entry.placeholder_text = title;
            entry.hexpand = true;
            entry.has_frame = false;
            entry.add_css_class("flat");
            entry.add_css_class("preferences-entry");
            entry.margin_top = 3;
            labels_box.append(entry);

            status_icon = new Image();
            status_icon.pixel_size = 16;
            status_icon.visible = false;
            add_suffix(status_icon);

            entry.changed.connect(() => { entry_changed(); });
            entry.activate.connect(() => { entry_activated(); });

            this.activated.connect(() => {
                entry.grab_focus();
            });
        }
    }
    /** An EntryRow with masked input and a reveal toggle button. */
    public class PasswordRow : EntryRow {
        private Button reveal_btn;
        private bool _show_password = false;

        public PasswordRow(string title) {
            base(title);
            entry.visibility = false;
            entry.input_purpose = InputPurpose.PASSWORD;
            reveal_btn = new Button.from_icon_name("view-reveal-symbolic");
            reveal_btn.valign = Align.CENTER;
            reveal_btn.add_css_class("flat");
            reveal_btn.add_css_class("circular");
            reveal_btn.clicked.connect(() => {
                _show_password = !_show_password;
                entry.visibility = _show_password;
                reveal_btn.icon_name = _show_password ? "view-conceal-symbolic" : "view-reveal-symbolic";
                if (_show_password) {
                    reveal_btn.add_css_class("accent");
                } else {
                    reveal_btn.remove_css_class("accent");
                }
            });
            add_suffix(reveal_btn);
        }
    }
    /** An EntryRow that validates the input as an e-mail address. */
    public class EmailRow : EntryRow {

        public EmailRow(string title) {
            base(title);
            entry.input_purpose = InputPurpose.EMAIL;
            entry.changed.connect(validate);
        }

        private void validate() {
            if (entry.text == "") {
                status_icon.visible = false;
                entry.remove_css_class("error");
                entry.remove_css_class("success");
                return;
            }
            try {
                var regex = new Regex("^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$");
                if (regex.match(entry.text)) {
                    status_icon.icon_name = "object-select-symbolic";
                    status_icon.add_css_class("success");
                    status_icon.remove_css_class("error");
                    entry.add_css_class("success");
                    entry.remove_css_class("error");
                } else {
                    status_icon.icon_name = "dialog-error-symbolic";
                    status_icon.add_css_class("error");
                    status_icon.remove_css_class("success");
                    entry.add_css_class("error");
                    entry.remove_css_class("success");
                }
                status_icon.visible = true;
            } catch (Error e) {
                warning("Regex error: %s", e.message);
            }
        }
    }
    /**
     * An ExpanderRow with a search bar and a filterable list box inside.
     *
     * Use `list_box` to populate the inner list and `search_entry` to react to
     * the user's search query.
     */
    public class SearchableExpanderRow : ExpanderRow {
        public Singularity.Widgets.SearchEntry search_entry;
        public ListBox list_box;

        public SearchableExpanderRow(string title, string? subtitle = null, string? icon_name = null) {
            base(title, subtitle, icon_name);
            var container = new Box(Orientation.VERTICAL, 12);
            container.margin_top = 12;
            container.margin_bottom = 12;
            container.margin_start = 12;
            container.margin_end = 12;
            search_entry = new Singularity.Widgets.SearchEntry();
            search_entry.placeholder_text = "Search...";
            container.append(search_entry);
            var scrolled = new ScrolledWindow();
            scrolled.set_size_request(-1, 300);
            scrolled.propagate_natural_height = true;
            list_box = new ListBox();
            list_box.selection_mode = SelectionMode.NONE;
            scrolled.child = list_box;
            container.append(scrolled);
            add_row(container);
        }
    }
    /**
     * An ExpanderRow that lets the user pick one value from a list.
     *
     * The currently selected value is shown in the row header as a dim label.
     * Emits `selected` when the user picks an item.
     */
    public class SelectionRow : ExpanderRow {
        /** Emitted with the chosen item string when the user makes a selection. */
        public signal void selected(string item);
        private Singularity.Widgets.SearchEntry search_entry;
        private ListBox list_box;
        private Label value_label;
        private GLib.List<string> items;
        private GLib.List<string?> item_subtitles;
        private GLib.List<GLib.Icon?> item_icons;
        private Gee.ArrayList<Singularity.Core.AppSettingOption> options;
        private string _current_value;
        public string current_value {
            get { return _current_value; }
            set {
                _current_value = value;
                if (options != null && options.size > 0) {
                    foreach (var opt in options) {
                        if (opt.id == value) {
                            value_label.label = opt.label;
                            return;
                        }
                    }
                    value_label.label = value;
                } else {
                    value_label.label = value;
                }
            }
        }

        /**
         * Creates a selection row from a plain string array.
         *
         * @param title   Row label.
         * @param items   Array of option strings shown in the expanded list.
         * @param current Initially selected item string.
         */
        public SelectionRow(string title, string[] items, string current = "") {
            base(title);
            this.items = new GLib.List<string>();
            foreach (string item in items) {
                this.items.append(item);
            }
            this._current_value = current;
            value_label = new Label(current);
            value_label.add_css_class("dim-label");
            add_suffix(value_label);
            init_ui();
        }

        /**
         * Creates a selection row with per-item subtitles and optional icons.
         *
         * @param title     Row label.
         * @param items     Array of option strings.
         * @param subtitles Optional subtitle per item; use `null` entries to skip.
         * @param icons     Optional icon per item; use `null` entries to skip.
         * @param current   Initially selected item string.
         */
        // Constructor that accepts per-item subtitles and optional icons.
        // Pass null in subtitles/icons arrays to skip for a specific item.
        public SelectionRow.with_details(string title, string[] items,
                                         string[]? subtitles, GLib.Icon?[]? icons,
                                         string current = "") {
            base(title);
            this.items = new GLib.List<string>();
            this.item_subtitles = new GLib.List<string?>();
            this.item_icons = new GLib.List<GLib.Icon?>();
            for (int i = 0; i < items.length; i++) {
                this.items.append(items[i]);
                this.item_subtitles.append(subtitles != null && i < subtitles.length ? subtitles[i] : null);
                this.item_icons.append(icons != null && i < icons.length ? icons[i] : null);
            }
            this._current_value = current;
            value_label = new Label(current);
            value_label.add_css_class("dim-label");
            add_suffix(value_label);
            init_ui();
        }

    /**
     * Creates a selection row from a list of Singularity.Core.AppSettingOption objects.
         *
         * @param title   Row label.
         * @param options The list of options (id + label pairs).
         * @param current The initially selected option id.
         */
        public SelectionRow.with_options(string title, Gee.ArrayList<Singularity.Core.AppSettingOption> options, string current = "") {
            base(title);
            this.options = options;
            this.items = new GLib.List<string>();
            this._current_value = current;
            string label_text = current;
            foreach (var opt in options) {
                if (opt.id == current) {
                    label_text = opt.label;
                    break;
                }
            }
            value_label = new Label(label_text);
            value_label.add_css_class("dim-label");
            add_suffix(value_label);
            init_ui();
        }

        private void init_ui() {
            var container = new Box(Orientation.VERTICAL, 0);
            int count = (options != null) ? options.size : (int)items.length();
            if (count > 5) {
                var se_wrap = new Box(Orientation.VERTICAL, 0);
                se_wrap.margin_top = 8;
                se_wrap.margin_bottom = 4;
                se_wrap.margin_start = 12;
                se_wrap.margin_end = 12;
                search_entry = new Singularity.Widgets.SearchEntry();
                search_entry.placeholder_text = "Search...";
                search_entry.search_changed.connect(filter_list);
                se_wrap.append(search_entry);
                container.append(se_wrap);
            }
            var scrolled = new ScrolledWindow();
            scrolled.min_content_height = 200;
            scrolled.max_content_height = 320;
            scrolled.hscrollbar_policy = PolicyType.NEVER;
            list_box = new ListBox();
            list_box.selection_mode = SelectionMode.NONE;
            scrolled.child = list_box;
            container.append(scrolled);
            add_row(container);
            // Pre-populate so the ScrolledWindow has content before the Revealer
            // calculates its target height — prevents the "10px tall" collapse.
            populate_list();
            this.notify["expanded"].connect(() => {
                if (expanded) {
                    populate_list();
                }
            });
        }

        /**
         * Replaces the current item list and rebuilds the inner list box.
         *
         * @param new_items New array of option strings.
         */
        public void set_items(string[] new_items) {
            items = new GLib.List<string>();
            foreach (string item in new_items) {
                items.append(item);
            }
            options = null;
            if (expanded) populate_list();
        }

        private void populate_list() {
            filter_list(search_entry);
        }

        private void filter_list(Singularity.Widgets.SearchEntry? entry) {
            Widget child = list_box.get_first_child();
            while (child != null) {
                list_box.remove(child);
                child = list_box.get_first_child();
            }
            string query = (entry != null) ? entry.text.down() : "";
            int count = 0;
            if (options != null && options.size > 0) {
                foreach (var opt in options) {
                    if (query == "" || opt.label.down().contains(query)) {
                        add_option_row(opt.label, opt.id, null, null);
                        count++;
                    }
                }
            } else {
                int i = 0;
                foreach (string item in items) {
                    if (query == "" || item.down().contains(query)) {
                        string? sub = (item_subtitles != null) ? item_subtitles.nth_data(i) : null;
                        GLib.Icon? icon = (item_icons != null) ? item_icons.nth_data(i) : null;
                        add_option_row(item, item, sub, icon);
                        count++;
                    }
                    i++;
                }
            }
        }

        private void add_option_row(string label, string id, string? subtitle, GLib.Icon? icon) {
            var row = new ActionRow(label, subtitle);
            row.activatable = true;
            if (icon != null) {
                var img = new Image.from_gicon(icon);
                img.pixel_size = 24;
                img.margin_end = 8;
                row.add_prefix(img);
            }
            if (id == current_value) {
                row.add_suffix(new Image.from_icon_name("object-select-symbolic"));
            }
            var gesture = new GestureClick();
            gesture.pressed.connect((n, x, y) => {
                gesture.set_state(EventSequenceState.CLAIMED);
            });
            gesture.released.connect(() => {
                current_value = id;
                selected(id);
                expanded = false;
            });
            row.add_controller(gesture);
            list_box.append(row);
        }
    }
    /**
     * A small swatch widget that renders a preview of a ColorTheme.
     *
     * Draws the theme background colour as a rounded rectangle with several
     * coloured pill shapes representing the palette. When `selected`
     * is `true` an accent-coloured border is drawn around the swatch.
     */
    public class ColorSchemePreview : Widget {
        public ColorTheme theme { get; construct; }
        public bool selected { get; set; default = false; }

        public ColorSchemePreview(ColorTheme theme) {
            Object(theme: theme);
            this.add_css_class("color-scheme-preview");
            this.set_size_request(140, 80);
        }

        public override void snapshot(Snapshot snapshot) {
            float width = get_width();
            float height = get_height();
            if (theme == null) return;
            Gdk.RGBA bg_color = Gdk.RGBA();
            if (!bg_color.parse(theme.background)) {
                bg_color.parse("#000000");
            }
            var bounds = Graphene.Rect().init(0, 0, width, height);
            var rounded_rect = Gsk.RoundedRect();
            rounded_rect.init(
                bounds,
                {8, 8}, {8, 8}, {8, 8}, {8, 8}
            );
            snapshot.push_rounded_clip(rounded_rect);
            snapshot.append_color(bg_color, bounds);
            int line_height = 6;
            int line_gap = 6;
            int start_y = 12;
            int start_x = 12;
            if (theme.palette.length > 7) {
                draw_pill(snapshot, start_x, start_y, 20, theme.palette[1]);
                draw_pill(snapshot, start_x + 24, start_y, 30, theme.palette[2]);
                draw_pill(snapshot, start_x + 58, start_y, 15, theme.palette[7]);
                start_y += line_height + line_gap;
                draw_pill(snapshot, start_x + 10, start_y, 25, theme.palette[3]);
                draw_pill(snapshot, start_x + 39, start_y, 40, theme.palette[4]);
                start_y += line_height + line_gap;
                draw_pill(snapshot, start_x, start_y, 15, theme.palette[5]);
                draw_pill(snapshot, start_x + 19, start_y, 20, theme.palette[6]);
                draw_pill(snapshot, start_x + 43, start_y, 30, theme.palette[7]);
                start_y += line_height + line_gap;
                draw_pill(snapshot, start_x + 5, start_y, 35, theme.palette[2]);
                draw_pill(snapshot, start_x + 44, start_y, 20, theme.palette[1]);
            }
            snapshot.pop();
            if (selected) {
                var border_color = Gdk.RGBA();
                border_color.parse("#3584e4");
                float border_width = 2;
                snapshot.append_border(
                    rounded_rect,
                    {border_width, border_width, border_width, border_width},
                    {border_color, border_color, border_color, border_color}
                );
                float icon_size = 20;
                float padding = 4;
                var icon_bounds = Graphene.Rect().init(width - icon_size - padding, height - icon_size - padding, icon_size, icon_size);
                var icon_rect = Gsk.RoundedRect();
                icon_rect.init(
                    icon_bounds,
                    {10, 10}, {10, 10}, {10, 10}, {10, 10}
                );
                snapshot.push_rounded_clip(icon_rect);
                snapshot.append_color(border_color, icon_bounds);
                snapshot.pop();
                Gdk.RGBA white = Gdk.RGBA();
                white.parse("#ffffff");
            }
        }

        private void draw_pill(Snapshot snapshot, int x, int y, int w, string color_str) {
            Gdk.RGBA color = Gdk.RGBA();
            color.parse(color_str);
            var bounds = Graphene.Rect().init(x, y, w, 6);
            var rect = Gsk.RoundedRect();
            rect.init(
                bounds,
                {3, 3}, {3, 3}, {3, 3}, {3, 3}
            );
            snapshot.push_rounded_clip(rect);
            snapshot.append_color(color, bounds);
            snapshot.pop();
        }
    }
    /**
     * A PreferencesRow that displays a scrollable grid of colour-scheme
     * swatches and lets the user pick one.
     *
     * Emits `scheme_selected` when the user clicks a swatch.
     */
    public class ColorSchemeRow : PreferencesRow {
        /** Emitted with the selected theme's id when the user picks a scheme. */
        public signal void scheme_selected(string scheme_id);
        private FlowBox flow_box;
        private string _current_scheme;
        public string current_scheme {
            get { return _current_scheme; }
            set {
                _current_scheme = value;
                update_selection();
            }
        }

        public ColorSchemeRow(string title, Gee.ArrayList<ColorTheme> themes, string current) {
            this._current_scheme = current;
            var main_box = new Box(Orientation.VERTICAL, 12);
            main_box.margin_top = 12;
            main_box.margin_bottom = 12;
            main_box.margin_start = 12;
            main_box.margin_end = 12;
            set_child(main_box);
            var label = new Label(title);
            label.add_css_class("heading");
            label.halign = Align.START;
            main_box.append(label);
            flow_box = new FlowBox();
            flow_box.valign = Align.START;
            flow_box.max_children_per_line = 3;
            flow_box.min_children_per_line = 2;
            flow_box.selection_mode = SelectionMode.NONE;
            flow_box.column_spacing = 12;
            flow_box.row_spacing = 12;
            flow_box.homogeneous = true;
            foreach (var theme in themes) {
                var preview = new ColorSchemePreview(theme);
                var container = new Box(Orientation.VERTICAL, 6);
                container.append(preview);
                var name_lbl = new Label(theme.name);
                name_lbl.add_css_class("caption");
                container.append(name_lbl);
                var wrapper = new Box(Orientation.VERTICAL, 0);
                wrapper.append(container);
                var gesture = new GestureClick();
                gesture.released.connect(() => {
                    current_scheme = theme.id;
                    scheme_selected(theme.id);
                });
                wrapper.add_controller(gesture);
                wrapper.set_data("theme_id", theme.id);
                wrapper.set_data("preview_widget", preview);
                flow_box.append(wrapper);
            }
            main_box.append(flow_box);
            update_selection();
            this.activatable = false;
        }

        private void update_selection() {
            Widget child = flow_box.get_first_child();
            while (child != null) {
                var fb_child = child as FlowBoxChild;
                if (fb_child != null) {
                    var wrapper = fb_child.get_child();
                    string? id = wrapper.get_data<string>("theme_id");
                    var preview = wrapper.get_data<ColorSchemePreview>("preview_widget");
                    if (id == current_scheme) {
                        preview.selected = true;
                    } else {
                        preview.selected = false;
                    }
                    preview.queue_draw();
                }
                child = child.get_next_sibling();
            }
        }
    }
}
