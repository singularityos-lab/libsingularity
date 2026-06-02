using Gtk;
using GLib;

namespace Singularity.Widgets {

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

        private bool   _active   = false;
        private Button _body_btn;
        private Label  _body_label;

        public Chip (string id, string? label = null) {
            Object (orientation: Orientation.HORIZONTAL, spacing: 0, chip_id: id);
            this.chip_label = label ?? "";
        }

        // Built in construct so .ui/vetro instances (created via g_object_new
        // with chip-id/label) are fully assembled too.
        construct {
            add_css_class ("chip");
            valign = Align.CENTER;

            _body_btn = new Button.with_label ("");
            _body_btn.has_frame = false;
            _body_btn.add_css_class ("chip-body");
            _body_label = (Label) _body_btn.get_child ();
            // Default: ellipsize with a sensible visible minimum so the
            // chip never collapses to "..." alone.
            _body_label.ellipsize       = Pango.EllipsizeMode.END;
            _body_label.width_chars     = 6;
            _body_label.max_width_chars = 18;
            _body_btn.clicked.connect (() => activated ());
            append (_body_btn);

            var close = new Button.from_icon_name ("window-close-symbolic");
            close.has_frame = false;
            close.add_css_class ("chip-close");
            close.clicked.connect (() => close_requested ());
            append (close);
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
     * Horizontal bar of Chip widgets shown at the bottom
     * of a LeafPane when one or more bugs are attached to it.
     */
    public class ChipBar : Box, Gtk.Buildable {

        /** Emitted with the chip's id when the chip body is clicked. */
        public signal void chip_activated (string id);
        /** Emitted with the chip's id when the close button is clicked. */
        public signal void chip_closed    (string id);

        /**
         * Emitted after the user reorders the chips by drag-and-drop.
         * The argument is the new ordered list of chip ids; apps should
         * persist it (e.g. settings) so the order survives restart.
         */
        public signal void chips_reordered (string[] ids);

        /** Number of chips currently in the bar. */
        public int chip_count { get; private set; default = 0; }

        private ScrolledWindow _scroll;
        private Box            _chips_box;

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
            notify["reorderable"].connect      (_apply_reorderable_policy);
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
            if (chip.parent != _chips_box) _chips_box.append (chip);
            chip_count++;
            if (reorderable) _install_drag (chip);
        }

        // -- Drag-to-reorder ------------------------------------------------
        //
        // Each chip carries:
        //  - a GtkDragSource that hands off the chip's id (as string)
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
            src.prepare.connect ((x, y) => {
                return new Gdk.ContentProvider.for_value (cid);
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
            });
            src.drag_cancel.connect ((drag, reason) => {
                chip.remove_css_class ("chip-dragging");
                _clear_drop_marks ();
                return false;
            });
            chip.add_controller (src);
            chip.set_data<Gtk.DragSource> ("singularity-chip-drag-src", src);

            var tgt = new Gtk.DropTarget (typeof (string), Gdk.DragAction.MOVE);
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
                string dragged_id = value.get_string ();
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

        private void _apply_reorderable_policy () {
            Widget? w = _chips_box.get_first_child ();
            while (w != null) {
                var c = w as Chip;
                if (c != null) {
                    if (reorderable) _install_drag (c);
                    else             _uninstall_drag (c);
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
