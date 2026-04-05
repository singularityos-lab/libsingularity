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

        public string chip_id { get; construct; }

        public signal void activated       ();
        public signal void close_requested ();

        private bool   _active   = false;
        private Button _body_btn;

        public Chip (string id, string label) {
            Object (orientation: Orientation.HORIZONTAL, spacing: 0,
                    chip_id: id);
            add_css_class ("chip");
            valign = Align.CENTER;

            _body_btn = new Button.with_label (label);
            _body_btn.has_frame = false;
            _body_btn.add_css_class ("chip-body");
            ((Label) _body_btn.get_child ()).ellipsize = Pango.EllipsizeMode.END;
            ((Label) _body_btn.get_child ()).max_width_chars = 12;
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
            ((Label) _body_btn.get_child ()).label = label;
        }
    }

    /**
     * Horizontal bar of Chip widgets shown at the bottom
     * of a LeafPane when one or more bugs are attached to it.
     */
    public class ChipBar : Box {

        /** Emitted with the chip's id when the chip body is clicked. */
        public signal void chip_activated (string id);
        /** Emitted with the chip's id when the close button is clicked. */
        public signal void chip_closed    (string id);

        /** Number of chips currently in the bar. */
        public int chip_count { get; private set; default = 0; }

        private ScrolledWindow _scroll;
        private Box            _chips_box;

        public ChipBar () {
            Object (orientation: Orientation.HORIZONTAL, spacing: 0);
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
        }

        /**
         * Adds a new chip to the bar.
         *
         * @param id    Unique identifier used in `chip_activated` and `chip_closed`.
         * @param label Human-readable label shown on the chip.
         */
        public void add_chip (string id, string label) {
            var chip = new Chip (id, label);
            // Capture id by value for the closures
            string cid = id;
            chip.activated.connect       (() => chip_activated (cid));
            chip.close_requested.connect (() => chip_closed    (cid));
            _chips_box.append (chip);
            chip_count++;
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
