namespace Singularity.Widgets {

    /**
     * A compact HH:MM time picker with stacked stepper arrows, in the spirit of
     * the macOS time field: two zero-padded numeric fields (hour, minute) that
     * can be typed into or nudged with the up/down steppers, separated by a
     * colon. Hours wrap 0-23 and minutes 0-59.
     *
     * Read or set the value through the `time` property ("HH:MM"); listen to
     * `changed` for user edits.
     */
    public class TimePicker : Gtk.Box {

        /** Emitted when the user changes the hour or minute. */
        public signal void changed();

        private Gtk.SpinButton hour_spin;
        private Gtk.SpinButton min_spin;
        private bool _updating = false;

        /** The selected time as a zero-padded "HH:MM" string. */
        public string time {
            owned get {
                return "%02d:%02d".printf((int) hour_spin.value, (int) min_spin.value);
            }
            set {
                var parts = value.split(":");
                if (parts.length != 2) return;
                _updating = true;
                hour_spin.value = ((double) int.parse(parts[0])).clamp(0, 23);
                min_spin.value = ((double) int.parse(parts[1])).clamp(0, 59);
                _updating = false;
            }
        }

        public TimePicker(string initial = "00:00") {
            Object(orientation: Gtk.Orientation.HORIZONTAL, spacing: 4);
            add_css_class("time-picker");
            valign = Gtk.Align.CENTER;

            hour_spin = make_field(0, 23);
            var colon = new Gtk.Label(":");
            colon.add_css_class("time-picker-colon");
            colon.valign = Gtk.Align.CENTER;
            min_spin = make_field(0, 59);

            append(hour_spin);
            append(colon);
            append(min_spin);

            this.time = initial;

            hour_spin.value_changed.connect(() => { if (!_updating) changed(); });
            min_spin.value_changed.connect(() => { if (!_updating) changed(); });
        }

        private Gtk.SpinButton make_field(int lo, int hi) {
            var adj = new Gtk.Adjustment(lo, lo, hi, 1, 5, 0);
            var s = new Gtk.SpinButton(adj, 1, 0);
            s.wrap = true;
            s.numeric = true;
            // Vertical orientation stacks the steppers like a macOS time field.
            s.orientation = Gtk.Orientation.VERTICAL;
            s.width_chars = 2;
            s.max_width_chars = 2;
            s.add_css_class("time-picker-field");
            // Always render zero-padded (07 instead of 7).
            s.output.connect(() => {
                s.text = "%02d".printf((int) s.adjustment.value);
                return true;
            });
            return s;
        }
    }
}
