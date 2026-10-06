using Gtk;
using GLib;

namespace Singularity.Widgets {

    public class ChipDragPayload : Object {
        public string id;
        public ChipBar owner;
        public bool handled = false;
        public bool cancelled = false;
        public bool detach_queued = false;

        public ChipDragPayload (ChipBar owner, string id) {
            this.owner = owner;
            this.id = id;
        }
    }

    /**
     * A single tab chip in the ChipBar.
     *
     * Rendered as a pill: [label][×]. Clicking the label fires
     * `activated`; clicking × fires `close_requested`.
     * Set `active` to highlight it with the system accent colour.
     */
    public class Chip : Box {

        public string chip_id { get; construct; default = ""; }
        /** The label shown on the chip body (named chip_label to avoid clashing
         *  with the existing set_label method's accessor) */
        public string chip_label {
            get { return _body_label != null ? _body_label.label : ""; }
            set { if (_body_label != null) _body_label.label = value ?? ""; }
        }

        public signal void activated       ();
        public signal void close_requested ();
        /** Emitted on a double click on the chip. */
        public signal void double_activated ();
        /**
         * Emitted on secondary click or long-press, with the pointer
         * position in chip coordinates. Return true to claim the event.
         */
        public signal bool context_requested (double x, double y);
        /** Emitted when an inline rename is committed with a changed label. */
        public signal void renamed (string new_label);
        /** Emitted when an inline rename ends without a new label. */
        public signal void rename_cancelled ();

        /** Menu shown on secondary click or long-press, or null for none. */
        public GLib.MenuModel? menu_model { get; set; default = null; }

        private bool   _active   = false;
        private bool   _closable = true;
        private bool   _renaming = false;
        private int64  _last_click = 0;
        private Button _body_btn;
        private Label  _body_label;
        private Button _close_btn;
        private Box    _prefix_box;
        private Gtk.Text _rename_text;

        public Chip (string id, string? label = null) {
            Object (orientation: Orientation.HORIZONTAL, spacing: 0, chip_id: id);
            this.chip_label = label ?? "";
        }

        // Built in construct so .ui/vetro instances (created via g_object_new
        // with chip-id/label) are fully assembled too.
        construct {
            add_css_class ("chip");
            valign = Align.CENTER;

            _prefix_box = new Box (Orientation.HORIZONTAL, 0);
            _prefix_box.valign       = Align.CENTER;
            _prefix_box.margin_start = 10;
            _prefix_box.visible      = false;
            append (_prefix_box);

            _body_btn = new Button.with_label ("");
            _body_btn.has_frame = false;
            _body_btn.add_css_class ("chip-body");
            _body_label = (Label) _body_btn.get_child ();
            // Default: ellipsize with a sensible visible minimum so the
            // chip never collapses to "..." alone.
            _body_label.ellipsize       = Pango.EllipsizeMode.END;
            _body_label.width_chars     = 6;
            _body_label.max_width_chars = 18;
            _body_btn.clicked.connect (_on_body_clicked);
            append (_body_btn);

            _rename_text = new Gtk.Text ();
            _rename_text.add_css_class ("chip-body");
            _rename_text.valign  = Align.CENTER;
            _rename_text.visible = false;
            _rename_text.activate.connect (() => _finish_rename (true));
            var rename_keys = new EventControllerKey ();
            rename_keys.key_pressed.connect ((keyval, code, state) => {
                if (keyval != Gdk.Key.Escape) return false;
                _finish_rename (false);
                return true;
            });
            _rename_text.add_controller (rename_keys);
            var rename_focus = new EventControllerFocus ();
            rename_focus.leave.connect (() => _finish_rename (true));
            _rename_text.add_controller (rename_focus);
            append (_rename_text);

            _close_btn = new Button.from_icon_name ("window-close-symbolic");
            _close_btn.has_frame = false;
            _close_btn.add_css_class ("chip-close");
            _close_btn.visible = _closable;
            _close_btn.clicked.connect (() => close_requested ());
            append (_close_btn);

            var menu_click = new GestureClick ();
            menu_click.button = Gdk.BUTTON_SECONDARY;
            menu_click.propagation_phase = PropagationPhase.CAPTURE;
            menu_click.pressed.connect ((n_press, x, y) => {
                if (_renaming) return;
                if (_request_context (x, y))
                    menu_click.set_state (EventSequenceState.CLAIMED);
            });
            add_controller (menu_click);

            var hold = new GestureLongPress ();
            hold.pressed.connect ((x, y) => {
                if (_renaming) return;
                if (_request_context (x, y))
                    hold.set_state (EventSequenceState.CLAIMED);
            });
            add_controller (hold);
        }

        private void _on_body_clicked () {
            if (_renaming) return;
            int64 now = get_monotonic_time ();
            int interval = get_settings ().gtk_double_click_time;
            bool is_double = _last_click > 0 && now - _last_click <= interval * 1000;
            _last_click = is_double ? 0 : now;
            activated ();
            if (is_double) double_activated ();
        }

        private bool _request_context (double x, double y) {
            bool claimed = context_requested (x, y);
            if (menu_model == null) return claimed;
            var pop = new PopoverMenu.from_model (menu_model);
            pop.has_arrow = false;
            pop.set_parent (this);
            Gdk.Rectangle rect = { (int) x, (int) y, 1, 1 };
            pop.pointing_to = rect;
            pop.closed.connect (() => Idle.add (() => {
                pop.unparent ();
                return Source.REMOVE;
            }));
            pop.popup ();
            return true;
        }

        /**
         * Whether the close button is shown. Hide it on chips that must
         * stay, such as the last remaining tab.
         */
        public bool closable {
            get { return _closable; }
            set {
                _closable = value;
                if (_close_btn != null) _close_btn.visible = value;
            }
        }

        /** Tooltip of the close button, or null for none. */
        public string? close_tooltip {
            get { return _close_btn != null ? _close_btn.tooltip_text : null; }
            set { if (_close_btn != null) _close_btn.tooltip_text = value; }
        }

        /** True while the label is being edited inline. */
        public bool renaming {
            get { return _renaming; }
        }

        /**
         * Shows a widget before the label, such as an icon or a status dot.
         * Replaces any previous prefix, including one set by `set_color`.
         *
         * @param widget The widget to show, or null to remove the prefix.
         */
        public void set_prefix (Widget? widget) {
            Widget? old;
            while ((old = _prefix_box.get_first_child ()) != null)
                _prefix_box.remove (old);
            if (widget != null) _prefix_box.append (widget);
            _prefix_box.visible = widget != null;
        }

        /**
         * Shows a small colour dot before the label, like a tab colour.
         *
         * @param color The dot colour, or null to remove the dot.
         */
        public void set_color (Gdk.RGBA? color) {
            if (color == null) {
                set_prefix (null);
                return;
            }
            Gdk.RGBA fill = color;
            var dot = new DrawingArea ();
            dot.content_width  = 8;
            dot.content_height = 8;
            dot.valign = Align.CENTER;
            dot.set_draw_func ((area, cr, width, height) => {
                cr.arc (width / 2.0, height / 2.0,
                        double.min (width, height) / 2.0, 0, 2 * Math.PI);
                Gdk.cairo_set_source_rgba (cr, fill);
                cr.fill ();
            });
            set_prefix (dot);
        }

        /**
         * Turns the label into an inline text field. Enter or moving the
         * focus away commits and emits `renamed` when the text changed;
         * otherwise, or on Escape, `rename_cancelled` is emitted. Both are
         * emitted from an idle callback. The label itself is left unchanged
         * so the owner can validate the new name and apply it with
         * `set_label`.
         */
        public void begin_rename () {
            if (_renaming) return;
            _renaming = true;
            string current = chip_label;
            _rename_text.text = current;
            _rename_text.width_chars     = current.char_count ().clamp (6, 24);
            _rename_text.max_width_chars = _rename_text.width_chars;
            _rename_text.visible = true;
            _body_btn.visible    = false;
            _rename_text.grab_focus ();
            _rename_text.select_region (0, -1);
        }

        private void _finish_rename (bool commit) {
            if (!_renaming) return;
            _renaming = false;
            string text = _rename_text.text.strip ();
            bool had_focus = _rename_text.has_focus;
            _body_btn.visible = true;
            if (had_focus) _body_btn.grab_focus ();
            _rename_text.visible = false;
            bool changed = commit && text != "" && text != chip_label;
            Idle.add (() => {
                if (changed) renamed (text);
                else rename_cancelled ();
                return Source.REMOVE;
            });
        }

        public bool active {
            get { return _active; }
            set {
                _active = value;
                if (value) add_css_class ("active");
                else        remove_css_class ("active");
            }
        }

        public void set_label (string label) {
            _body_label.label = label;
        }

        /** Toggle ellipsis on the label. False = always show the full label. */
        public void set_ellipsize (bool on) {
            _body_label.ellipsize = on ? Pango.EllipsizeMode.END : Pango.EllipsizeMode.NONE;
        }

        /** Visible character bounds when ellipsis is on. */
        public void set_label_chars (int min_chars, int max_chars) {
            _body_label.width_chars     = min_chars;
            _body_label.max_width_chars = max_chars;
        }
    }

    /**
     * Visual variants of a ChipBar.
     */
    public enum ChipBarStyle {
        /** Tinted bottom bar with a top border, for tabs. */
        BAR,
        /** Transparent, compact row, for filter chips above content. */
        FILTER
    }

    /**
     * Horizontal bar of Chip widgets shown at the bottom
     * of a LeafPane when one or more bugs are attached to it.
     */
    public class ChipBar : Box, Gtk.Buildable {

        /** Emitted with the chip's id when the chip body is clicked. */
        public signal void chip_activated (string id);
        /** Emitted with the chip's id when the close button is clicked. */
        public signal void chip_closed    (string id);
        /** Emitted when a detachable chip is dropped outside its window. */
        public signal void chip_detached  (string id);

        /**
         * Emitted after the user reorders the chips by drag-and-drop.
         * The argument is the new ordered list of chip ids; apps should
         * persist it (e.g. settings) so the order survives restart.
         */
        public signal void chips_reordered (string[] ids);

        /** Emitted with the chip's id when the chip is double-clicked. */
        public signal void chip_double_activated (string id);

        /**
         * Emitted with the chip's id on secondary click or long-press.
         * Connect it to build a menu on demand, anchored with
         * `get_chip_widget`; static menus can use `set_chip_menu` instead.
         */
        public signal void chip_context_requested (string id);

        /**
         * Emitted when an inline rename started with `begin_rename` is
         * committed with a changed label. The chip keeps its old label
         * until the app accepts the name with `set_chip_label`. Emitted
         * from an idle callback, so handlers may remove or rebuild chips.
         */
        public signal void chip_renamed (string id, string new_label);

        /** Emitted when an inline rename ends without a new label. */
        public signal void chip_rename_cancelled (string id);

        /** Number of chips currently in the bar. */
        public int chip_count { get; private set; default = 0; }

        private ScrolledWindow _scroll;
        private Box            _chips_box;
        private weak Widget?   _drop_root;
        private DropTarget?    _root_drop_target;

        /**
         * Per-chip ellipsis policy applied to every chip added afterwards
         * (and propagated to existing chips). False = chips always show
         * their full label and the bar scrolls horizontally if needed.
         */
        public bool ellipsize_labels { get; set; default = true; }

        /** Minimum visible label width (in chars) when ellipsis is on. */
        public int min_label_chars { get; set; default = 6; }

        /** Maximum visible label width (in chars) when ellipsis is on. */
        public int max_label_chars { get; set; default = 18; }

        /**
         * When true, the user can drag chips to reorder them (tab-like).
         * Toggling this property re-wires drag/drop on every existing
         * chip. Default off so the behaviour is opt-in.
         */
        public bool reorderable { get; set; default = false; }

        /** When true, dropping a chip outside its window requests a detach. */
        public bool detachable { get; set; default = false; }

        /** Tooltip of every chip's close button, or null for none. */
        public string? close_tooltip { get; set; default = null; }

        /**
         * Visual variant of the bar. `BAR` is the default bottom bar with
         * its own tinted background and top border, as used for sheet or
         * document tabs. `FILTER` drops the background and border and
         * tightens the spacing, for a row of filter chips above content.
         */
        public ChipBarStyle bar_style { get; set; default = ChipBarStyle.BAR; }

        public ChipBar () {
            Object (orientation: Orientation.HORIZONTAL, spacing: 0);
        }

        // Setup in construct so .ui/vetro instances are assembled too.
        construct {
            add_css_class ("chip-bar");

            _scroll = new ScrolledWindow ();
            _scroll.hexpand           = true;
            _scroll.vscrollbar_policy = PolicyType.NEVER;
            _scroll.hscrollbar_policy = PolicyType.AUTOMATIC;
            append (_scroll);

            _chips_box = new Box (Orientation.HORIZONTAL, 6);
            _chips_box.margin_start  = 8;
            _chips_box.margin_end    = 8;
            _chips_box.margin_top    = 5;
            _chips_box.margin_bottom = 5;
            _chips_box.valign        = Align.CENTER;
            _scroll.set_child (_chips_box);

            // When the policy flips, restyle every existing chip.
            notify["ellipsize-labels"].connect (_apply_label_policy);
            notify["min-label-chars"].connect  (_apply_label_policy);
            notify["max-label-chars"].connect  (_apply_label_policy);
            notify["reorderable"].connect      (_apply_drag_policy);
            notify["detachable"].connect       (_apply_drag_policy);
            notify["root"].connect             (_sync_root_drop_target);
            notify["close-tooltip"].connect    (_apply_close_tooltip);
            notify["bar-style"].connect        (_apply_bar_style);
        }

        private void _apply_bar_style () {
            bool filter = bar_style == ChipBarStyle.FILTER;
            if (filter) add_css_class ("filter");
            else remove_css_class ("filter");
            _chips_box.margin_start  = filter ? 0 : 8;
            _chips_box.margin_end    = filter ? 0 : 8;
            _chips_box.margin_top    = filter ? 2 : 5;
            _chips_box.margin_bottom = filter ? 2 : 5;
        }

        // Buildable: a <child> Chip declared in markup is routed into the bar
        // (appended to the inner box and wired up) instead of GtkBox's default
        // of adding it as a direct child.
        public void add_child (Gtk.Builder builder, GLib.Object child, string? type) {
            var chip = child as Chip;
            if (chip != null) {
                _register_chip (chip);
            } else {
                base.add_child (builder, child, type);
            }
        }

        /**
         * Adds a new chip to the bar.
         *
         * @param id    Unique identifier used in `chip_activated` and `chip_closed`.
         * @param label Human-readable label shown on the chip.
         */
        public void add_chip (string id, string label) {
            _register_chip (new Chip (id, label));
        }

        // Shared registration used by both add_chip (imperative) and add_child
        // (markup): apply label policy, relay signals, append, count, drag.
        private void _register_chip (Chip chip) {
            chip.set_ellipsize (ellipsize_labels);
            chip.set_label_chars (min_label_chars, max_label_chars);
            string cid = chip.chip_id;
            chip.activated.connect       (() => chip_activated (cid));
            chip.close_requested.connect (() => chip_closed    (cid));
            chip.double_activated.connect (() => chip_double_activated (cid));
            chip.context_requested.connect ((x, y) => {
                chip_context_requested (cid);
                return Signal.has_handler_pending (this,
                    Signal.lookup ("chip-context-requested", typeof (ChipBar)),
                    0, false);
            });
            chip.renamed.connect ((new_label) => chip_renamed (cid, new_label));
            chip.rename_cancelled.connect (() => chip_rename_cancelled (cid));
            if (close_tooltip != null) chip.close_tooltip = close_tooltip;
            if (chip.parent != _chips_box) _chips_box.append (chip);
            chip_count++;
            if (reorderable || detachable) _install_drag (chip);
        }

        // -- Drag-to-reorder ------------------------------------------------
        //
        // Each chip carries:
        //  - a GtkDragSource that hands off the chip's id
        //  - a GtkDropTarget that, on drop, finds the source chip by id,
        //    pulls it out of the box and re-inserts it before/after the
        //    target chip based on the cursor x position.
        //
        // We mark the controllers via set_data so _apply_reorderable_policy
        // can find and remove them when the property is toggled off.

        private void _install_drag (Chip chip) {
            if (chip.get_data<bool> ("singularity-chip-drag-installed")) return;
            chip.set_data<bool> ("singularity-chip-drag-installed", true);

            var src = new Gtk.DragSource ();
            src.set_actions (Gdk.DragAction.MOVE);
            string cid = chip.chip_id;
            ChipDragPayload? payload = null;
            src.prepare.connect ((x, y) => {
                payload = new ChipDragPayload (this, cid);
                return new Gdk.ContentProvider.for_value (payload);
            });
            // A translucent live copy of the chip follows the cursor (the
            // "ghost"); the original is dimmed in place so it reads as the slot
            // being moved.
            src.drag_begin.connect ((drag) => {
                var ghost = new Gtk.WidgetPaintable (chip);
                src.set_icon (ghost, chip.get_width () / 2, chip.get_height () / 2);
                chip.add_css_class ("chip-dragging");
            });
            src.drag_end.connect ((drag, delete_data) => {
                chip.remove_css_class ("chip-dragging");
                _clear_drop_marks ();
                if (detachable && payload != null &&
                        !payload.handled && !payload.cancelled)
                    _queue_detach (payload);
                payload = null;
            });
            src.drag_cancel.connect ((drag, reason) => {
                chip.remove_css_class ("chip-dragging");
                _clear_drop_marks ();
                if (payload == null) return false;
                payload.cancelled = reason == Gdk.DragCancelReason.ERROR;
                if (detachable && !payload.handled && !payload.cancelled) {
                    _queue_detach (payload);
                    return true;
                }
                return false;
            });
            chip.add_controller (src);
            chip.set_data<Gtk.DragSource> ("singularity-chip-drag-src", src);

            if (!reorderable) return;

            var tgt = new Gtk.DropTarget (typeof (ChipDragPayload), Gdk.DragAction.MOVE);
            // While hovering, mark which side of this chip the drop will land on
            // so the user sees where the dragged chip is going.
            tgt.motion.connect ((x, y) => {
                _mark_drop (chip, x > (chip.get_width () / 2));
                return Gdk.DragAction.MOVE;
            });
            tgt.leave.connect (() => {
                chip.remove_css_class ("drop-before");
                chip.remove_css_class ("drop-after");
            });
            tgt.drop.connect ((value, x, y) => {
                _clear_drop_marks ();
                var dropped = value.get_object () as ChipDragPayload;
                if (dropped == null || dropped.owner != this) return false;
                string dragged_id = dropped.id;
                if (dragged_id == cid) return false;
                var dragged = _find (dragged_id);
                if (dragged == null) return false;
                _chips_box.remove (dragged);
                int target_index = _index_of (chip);
                bool after = x > (chip.get_width () / 2);
                if (after) {
                    _insert_at (dragged, target_index + 1);
                } else {
                    _insert_at (dragged, target_index);
                }
                string[] ids = _ordered_ids ();
                dropped.handled = true;
                chips_reordered (ids);
                return true;
            });
            chip.add_controller (tgt);
            chip.set_data<Gtk.DropTarget> ("singularity-chip-drop-tgt", tgt);
        }

        // Highlight the gap where the dragged chip will be inserted, on the
        // leading or trailing edge of the hovered chip.
        private void _mark_drop (Chip chip, bool after) {
            _clear_drop_marks ();
            chip.add_css_class (after ? "drop-after" : "drop-before");
        }

        private void _clear_drop_marks () {
            Widget? w = _chips_box.get_first_child ();
            while (w != null) {
                w.remove_css_class ("drop-before");
                w.remove_css_class ("drop-after");
                w = w.get_next_sibling ();
            }
        }

        private void _uninstall_drag (Chip chip) {
            if (!chip.get_data<bool> ("singularity-chip-drag-installed")) return;
            var src = chip.get_data<Gtk.DragSource> ("singularity-chip-drag-src");
            var tgt = chip.get_data<Gtk.DropTarget>  ("singularity-chip-drop-tgt");
            if (src != null) chip.remove_controller (src);
            if (tgt != null) chip.remove_controller (tgt);
            chip.set_data<Gtk.DragSource>    ("singularity-chip-drag-src", null);
            chip.set_data<Gtk.DropTarget>    ("singularity-chip-drop-tgt", null);
            chip.set_data<bool>              ("singularity-chip-drag-installed", false);
        }

        private void _sync_root_drop_target () {
            var root = get_root () as Widget;
            if (_drop_root == root &&
                    ((_root_drop_target != null) == detachable)) return;
            if (_drop_root != null && _root_drop_target != null)
                _drop_root.remove_controller (_root_drop_target);
            _drop_root = null;
            _root_drop_target = null;
            if (!detachable || root == null) return;

            var target = new DropTarget (typeof (ChipDragPayload),
                                         Gdk.DragAction.MOVE);
            target.drop.connect ((value, x, y) => {
                var payload = value.get_object () as ChipDragPayload;
                if (payload == null || payload.owner != this) return false;
                payload.handled = true;
                return true;
            });
            root.add_controller (target);
            _drop_root = root;
            _root_drop_target = target;
        }

        private void _queue_detach (ChipDragPayload payload) {
            if (payload.detach_queued) return;
            payload.detach_queued = true;
            Idle.add (() => {
                chip_detached (payload.id);
                return Source.REMOVE;
            });
        }

        private void _apply_drag_policy () {
            _sync_root_drop_target ();
            Widget? w = _chips_box.get_first_child ();
            while (w != null) {
                var c = w as Chip;
                if (c != null) {
                    _uninstall_drag (c);
                    if (reorderable || detachable) _install_drag (c);
                }
                w = w.get_next_sibling ();
            }
        }

        private int _index_of (Chip chip) {
            int i = 0;
            Widget? w = _chips_box.get_first_child ();
            while (w != null) {
                if (w == chip) return i;
                w = w.get_next_sibling ();
                i++;
            }
            return -1;
        }

        private void _insert_at (Chip chip, int index) {
            if (index <= 0) {
                Widget? first = _chips_box.get_first_child ();
                if (first == null) _chips_box.append (chip);
                else               _chips_box.insert_child_after (chip, null);
                return;
            }
            int i = 0;
            Widget? w = _chips_box.get_first_child ();
            Widget? prev = null;
            while (w != null && i < index) {
                prev = w;
                w = w.get_next_sibling ();
                i++;
            }
            _chips_box.insert_child_after (chip, prev);
        }

        private string[] _ordered_ids () {
            string[] ids = {};
            Widget? w = _chips_box.get_first_child ();
            while (w != null) {
                var c = w as Chip;
                if (c != null) ids += c.chip_id;
                w = w.get_next_sibling ();
            }
            return ids;
        }

        private void _apply_label_policy () {
            Widget? w = _chips_box.get_first_child ();
            while (w != null) {
                var c = w as Chip;
                if (c != null) {
                    c.set_ellipsize (ellipsize_labels);
                    c.set_label_chars (min_label_chars, max_label_chars);
                }
                w = w.get_next_sibling ();
            }
        }

        private void _apply_close_tooltip () {
            Widget? w = _chips_box.get_first_child ();
            while (w != null) {
                var c = w as Chip;
                if (c != null) c.close_tooltip = close_tooltip;
                w = w.get_next_sibling ();
            }
        }

        /**
         * Updates the label of an existing chip.
         *
         * @param id    The chip's unique identifier.
         * @param label The new label to display.
         */
        public void update_chip_label (string id, string label) {
            var chip = _find (id);
            if (chip != null) chip.set_label (label);
        }

        /**
         * Removes the chip with the given id from the bar.
         *
         * @param id The chip's unique identifier.
         */
        public void remove_chip (string id) {
            var chip = _find (id);
            if (chip != null) {
                _chips_box.remove (chip);
                chip_count--;
            }
        }

        /** Highlight one chip as active; pass null to deactivate all. */
        public void set_active (string? id) {
            Widget? w = _chips_box.get_first_child ();
            while (w != null) {
                var c = w as Chip;
                if (c != null)
                    c.active = (id != null && c.chip_id == id);
                w = w.get_next_sibling ();
            }
        }

        /**
         * Sets the label of an existing chip.
         *
         * @param id    The chip's unique identifier.
         * @param label The new label to display.
         */
        public void set_chip_label (string id, string label) {
            update_chip_label (id, label);
        }

        /**
         * Sets the menu shown on secondary click or long-press of a chip.
         * Actions resolve from the chip upwards, so `win.` and `app.`
         * actions work.
         *
         * @param id   The chip's unique identifier.
         * @param menu The menu to show, or null to remove it.
         */
        public void set_chip_menu (string id, GLib.MenuModel? menu) {
            var chip = _find (id);
            if (chip != null) chip.menu_model = menu;
        }

        /**
         * Shows or hides the close button of a chip.
         *
         * @param id       The chip's unique identifier.
         * @param closable False to hide the close button.
         */
        public void set_chip_closable (string id, bool closable) {
            var chip = _find (id);
            if (chip != null) chip.closable = closable;
        }

        /**
         * Shows a widget before a chip's label, such as an icon.
         *
         * @param id     The chip's unique identifier.
         * @param widget The widget to show, or null to remove the prefix.
         */
        public void set_chip_prefix (string id, Widget? widget) {
            var chip = _find (id);
            if (chip != null) chip.set_prefix (widget);
        }

        /**
         * Shows a small colour dot before a chip's label.
         *
         * @param id    The chip's unique identifier.
         * @param color The dot colour, or null to remove the dot.
         */
        public void set_chip_color (string id, Gdk.RGBA? color) {
            var chip = _find (id);
            if (chip != null) chip.set_color (color);
        }

        /**
         * Turns a chip's label into an inline text field. Enter or moving
         * the focus away commits and emits `chip_renamed`; Escape cancels
         * and emits `chip_rename_cancelled`.
         *
         * @param id The chip's unique identifier.
         */
        public void begin_rename (string id) {
            var chip = _find (id);
            if (chip != null) chip.begin_rename ();
        }

        /**
         * Returns the chip widget with the given id, for anchoring popovers.
         *
         * @param id The chip's unique identifier.
         * @return The chip, or null if there is none with that id.
         */
        public Chip? get_chip_widget (string id) {
            return _find (id);
        }

        private Chip? _find (string id) {
            Widget? w = _chips_box.get_first_child ();
            while (w != null) {
                var c = w as Chip;
                if (c != null && c.chip_id == id) return c;
                w = w.get_next_sibling ();
            }
            return null;
        }
    }
}
