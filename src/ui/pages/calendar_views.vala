using Gtk;
using GLib;
using Gee;
using Singularity.Calendar;

namespace Singularity.Widgets {

    // ── EventChip ────────────────────────────────────────────────────────────

    /**
     * A colored pill showing a calendar event.
     * Used in month cells and time-column views.
     */
    public class CalendarEventChip : Button {
        public CalendarEvent event_data { get; private set; }

        private static Gee.HashMap<string, CssProvider> _color_providers = new Gee.HashMap<string, CssProvider>();
        private static CssProvider? _global_provider = null;

        private static void ensure_color_css(string hex) {
            if (_color_providers.has_key(hex)) return;
            var p = new CssProvider();
            try {
                p.load_from_string(
                    ".cal-event-dot-%s { background-color: %s; border-radius: 4px; min-width: 8px; min-height: 8px; }"
                    .printf(hex.replace("#", ""), hex));
                _color_providers[hex] = p;
            } catch (Error e) {
                warning("CalendarEventChip CSS: %s", e.message);
            }
        }

        public CalendarEventChip (CalendarEvent evt) {
            event_data = evt;
            add_css_class ("cal-event-chip");
            tooltip_text = evt.title;

            var box = new Box (Orientation.HORIZONTAL, 4);
            box.margin_start = 5;
            box.margin_end   = 5;

            var dot = new Box (Orientation.HORIZONTAL, 0);
            dot.add_css_class ("cal-event-dot");
            dot.add_css_class ("cal-event-dot-%s".printf (evt.color.replace ("#", "")));
            dot.valign = Align.CENTER;

            ensure_color_css(evt.color);
            if (_color_providers.has_key(evt.color)) {
                dot.get_style_context ().add_provider (_color_providers[evt.color], Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            }
            box.append (dot);

            if (!evt.all_day) {
                var time_lbl = new Label (evt.start_time.format ("%H:%M"));
                time_lbl.add_css_class ("cal-event-time");
                box.append (time_lbl);
            }

            var title_lbl = new Label (evt.title);
            title_lbl.ellipsize = Pango.EllipsizeMode.END;
            title_lbl.halign    = Align.START;
            title_lbl.hexpand   = true;
            box.append (title_lbl);

            set_child (box);
        }
    }

    // ── CalendarNavPicker ─────────────────────────────────────────────────────

    /**
     * A compact month-grid date picker for the sidebar.
     * Emits date_selected when the user clicks a day.
     */
    public class CalendarNavPicker : Box {
        private DateTime   _display_month;
        private DateTime?  _selected;
        private Label      _month_lbl;
        private Grid       _grid;

        public signal void date_selected (DateTime date);

        public CalendarNavPicker () {
            Object (orientation: Orientation.VERTICAL, spacing: 4);
            add_css_class ("cal-nav-picker");
            _display_month = new DateTime.now_local ();
            _selected      = _display_month;
            _build ();
        }

        public void set_date (DateTime date) {
            _display_month = new DateTime.local (date.get_year (), date.get_month (), 1, 0, 0, 0);
            _selected      = date;
            _refresh ();
        }

        public DateTime displayed_month { get { return _display_month; } }

        private void _build () {
            var hdr  = new Box (Orientation.HORIZONTAL, 0);

            var prev = new Button.from_icon_name ("go-previous-symbolic");
            prev.add_css_class ("flat"); prev.add_css_class ("circular");
            prev.set_size_request (28, 28);
            prev.clicked.connect (() => { _display_month = _display_month.add_months (-1); _refresh (); });

            _month_lbl = new Label ("");
            _month_lbl.hexpand  = true;
            _month_lbl.halign   = Align.CENTER;
            _month_lbl.add_css_class ("cal-nav-month-label");

            var next = new Button.from_icon_name ("go-next-symbolic");
            next.add_css_class ("flat"); next.add_css_class ("circular");
            next.set_size_request (28, 28);
            next.clicked.connect (() => { _display_month = _display_month.add_months (1); _refresh (); });

            hdr.append (prev);
            hdr.append (_month_lbl);
            hdr.append (next);
            append (hdr);

            _grid = new Grid ();
            _grid.column_spacing = 2;
            _grid.row_spacing    = 1;
            _grid.halign = Align.CENTER;
            append (_grid);

            _refresh ();
        }

        private void _refresh () {
            _month_lbl.label = _display_month.format ("%B %Y");

            Widget? c = _grid.get_first_child ();
            while (c != null) { var n = c.get_next_sibling (); _grid.remove (c); c = n; }

            string[] dow = { "S","M","T","W","T","F","S" };
            for (int i = 0; i < 7; i++) {
                var l = new Label (dow[i]);
                l.add_css_class ("dim-label"); l.add_css_class ("caption");
                l.set_size_request (28, 18); l.halign = Align.CENTER;
                _grid.attach (l, i, 0, 1, 1);
            }

            var first     = new DateTime.local (_display_month.get_year (), _display_month.get_month (), 1, 0, 0, 0);
            int start_col = first.get_day_of_week () % 7;
            int dim       = _days_in_month (_display_month.get_year (), _display_month.get_month ());
            var today     = new DateTime.now_local ();

            int row = 1, col = start_col;
            for (int d = 1; d <= dim; d++) {
                bool is_today = today.get_year ()  == _display_month.get_year ()  &&
                                today.get_month () == _display_month.get_month () &&
                                d == today.get_day_of_month ();
                bool is_sel   = _selected != null &&
                                _selected.get_year ()  == _display_month.get_year ()  &&
                                _selected.get_month () == _display_month.get_month () &&
                                d == _selected.get_day_of_month ();

                var btn = new Button.with_label (d.to_string ());
                btn.add_css_class ("flat"); btn.add_css_class ("cal-nav-day-btn");
                if (is_today)  btn.add_css_class ("today");
                if (is_sel)    btn.add_css_class ("selected");
                btn.set_size_request (28, 26);

                int captured_d = d;
                btn.clicked.connect (() => {
                    _selected = new DateTime.local (_display_month.get_year (), _display_month.get_month (), captured_d, 0, 0, 0);
                    _refresh ();
                    date_selected (_selected);
                });

                _grid.attach (btn, col, row, 1, 1);
                col++;
                if (col > 6) { col = 0; row++; }
            }
        }

        private int _days_in_month (int y, int m) {
            if (m == 12) return 31;
            var a = new DateTime.local (y, m + 1, 1, 0, 0, 0);
            var b = new DateTime.local (y, m,     1, 0, 0, 0);
            return (int) (a.difference (b) / TimeSpan.DAY);
        }
    }

    // ── CalendarMonthView ─────────────────────────────────────────────────────

    /**
     * Month-grid view.  Shows 6 weeks × 7 days with event chips per cell.
     */
    public class CalendarMonthView : Box {
        private DateTime        _date;
        private CalendarManager _mgr;
        private Grid            _grid;

        public signal void event_activated (CalendarEvent evt);
        public signal void day_selected    (DateTime date);

        public CalendarMonthView (CalendarManager mgr) {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class ("cal-month-view");
            hexpand = true; vexpand = true;
            _mgr  = mgr;
            _date = new DateTime.now_local ();
            _build_dow_header ();
            _grid = new Grid ();
            _grid.add_css_class ("cal-month-grid");
            _grid.hexpand            = true;
            _grid.vexpand            = true;
            _grid.row_homogeneous    = true;
            _grid.column_homogeneous = true;
            append (_grid);
        }

        public void set_date (DateTime date) {
            _date = date;
            refresh.begin ();
        }

        private void _build_dow_header () {
            var hdr = new Grid ();
            hdr.add_css_class ("cal-dow-header");
            hdr.column_homogeneous = true;
            string[] names = { "Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday" };
            for (int i = 0; i < 7; i++) {
                var l = new Label (names[i]);
                l.add_css_class ("cal-dow-label");
                l.halign = Align.CENTER; l.hexpand = true;
                hdr.attach (l, i, 0, 1, 1);
            }
            append (hdr);
        }

        public async void refresh () {
            Widget? c = _grid.get_first_child ();
            while (c != null) { var n = c.get_next_sibling (); _grid.remove (c); c = n; }

            var first     = new DateTime.local (_date.get_year (), _date.get_month (), 1, 0, 0, 0);
            int dim       = _days_in_month (_date.get_year (), _date.get_month ());
            int start_col = first.get_day_of_week () % 7;
            var today     = new DateTime.now_local ();

            int prev_y = _date.get_month () == 1 ? _date.get_year () - 1 : _date.get_year ();
            int prev_m = _date.get_month () == 1 ? 12 : _date.get_month () - 1;
            int prev_dim = _days_in_month (prev_y, prev_m);

            var range_start = first.add_days (-start_col);
            var range_end   = range_start.add_days (42);
            Gee.List<CalendarEvent?> events;
            try   { events = yield _mgr.get_events (range_start, range_end); }
            catch (Error e) {
                warning ("CalendarMonthView: failed to fetch events: %s", e.message);
                events = new Gee.ArrayList<CalendarEvent?> ();
            }

            int day = 1 - start_col;
            for (int r = 0; r < 6; r++) {
                for (int ci = 0; ci < 7; ci++) {
                    int cy, cm, cd; bool in_month;
                    if (day <= 0) {
                        cd = prev_dim + day; cm = prev_m; cy = prev_y; in_month = false;
                    } else if (day > dim) {
                        int nm = _date.get_month () == 12 ? 1 : _date.get_month () + 1;
                        int ny = _date.get_month () == 12 ? _date.get_year () + 1 : _date.get_year ();
                        cd = day - dim; cm = nm; cy = ny; in_month = false;
                    } else {
                        cd = day; cm = _date.get_month (); cy = _date.get_year (); in_month = true;
                    }

                    bool is_today = cy == today.get_year () && cm == today.get_month () && cd == today.get_day_of_month ();

                    var cell = new Box (Orientation.VERTICAL, 0);
                    cell.add_css_class ("cal-day-cell");
                    if (!in_month) cell.add_css_class ("out-of-month");
                    if (is_today)  cell.add_css_class ("today");
                    cell.hexpand = true; cell.vexpand = true;

                    var num_lbl = new Label (cd.to_string ());
                    num_lbl.halign = Align.END;
                    num_lbl.margin_end = 6; num_lbl.margin_top = 5;
                    if (is_today) num_lbl.add_css_class ("cal-today-badge");
                    else          num_lbl.add_css_class ("cal-day-num");
                    cell.append (num_lbl);

                    var ev_box = new Box (Orientation.VERTICAL, 1);
                    ev_box.margin_start = 2; ev_box.margin_end = 2; ev_box.margin_bottom = 4;
                    int n_shown = 0;
                    foreach (var evt in events) {
                        if (evt.start_time.get_year () != cy || evt.start_time.get_month () != cm ||
                            evt.start_time.get_day_of_month () != cd) continue;
                        if (n_shown < 3) {
                            var chip = new CalendarEventChip (evt);
                            chip.add_css_class ("compact");
                            var cap = evt;
                            chip.clicked.connect (() => event_activated (cap));
                            ev_box.append (chip);
                        } else if (n_shown == 3) {
                            var more = new Label ("+more");
                            more.add_css_class ("cal-more-label");
                            more.halign = Align.START; more.margin_start = 6;
                            ev_box.append (more);
                        }
                        n_shown++;
                    }
                    cell.append (ev_box);

                    int ccy = cy, ccm = cm, ccd = cd;
                    var gesture = new GestureClick ();
                    gesture.pressed.connect ((n, x, y) => {
                        if (n == 2) day_selected (new DateTime.local (ccy, ccm, ccd, 0, 0, 0));
                    });
                    cell.add_controller (gesture);

                    _grid.attach (cell, ci, r, 1, 1);
                    day++;
                }
            }
        }

        private int _days_in_month (int y, int m) {
            if (m == 12) return 31;
            var a = new DateTime.local (y, m + 1, 1, 0, 0, 0);
            var b = new DateTime.local (y, m,     1, 0, 0, 0);
            return (int) (a.difference (b) / TimeSpan.DAY);
        }
    }

    // ── CalendarWeekView ──────────────────────────────────────────────────────

    /**
     * Week view: 7 day columns with time-positioned event chips.
     */
    public class CalendarWeekView : Box {
        private DateTime        _week_start;
        private CalendarManager _mgr;
        private Grid            _day_header_grid;
        private Overlay[]       _day_overlays;
        private const int       HOUR_H = 56;

        public signal void event_activated (CalendarEvent evt);

        public CalendarWeekView (CalendarManager mgr) {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class ("cal-week-view");
            hexpand = true; vexpand = true;
            _mgr        = mgr;
            _week_start = _sunday_of_week (new DateTime.now_local ());
            _day_overlays = new Overlay[7];
            _build_ui ();
        }

        public void set_date (DateTime date) {
            _week_start = _sunday_of_week (date);
            _update_day_headers ();
            refresh.begin ();
        }

        private void _build_ui () {
            // ── Day header row ──────────────────────────────────────────────
            _day_header_grid = new Grid ();
            _day_header_grid.add_css_class ("cal-week-header");
            _day_header_grid.column_homogeneous = false;

            var gutter_spc = new Box (Orientation.VERTICAL, 0);
            gutter_spc.set_size_request (56, -1);
            _day_header_grid.attach (gutter_spc, 0, 0, 1, 1);

            for (int d = 0; d < 7; d++) {
                var ph = new Box (Orientation.VERTICAL, 0);
                ph.hexpand = true;
                _day_header_grid.attach (ph, d + 1, 0, 1, 1);
            }
            append (_day_header_grid);

            // ── Scrollable time + day columns ───────────────────────────────
            var scroll = new ScrolledWindow ();
            scroll.hexpand = true; scroll.vexpand = true;
            scroll.hscrollbar_policy = PolicyType.NEVER;

            var outer = new Box (Orientation.HORIZONTAL, 0);

            // Time gutter
            var time_col = new Box (Orientation.VERTICAL, 0);
            time_col.add_css_class ("cal-time-gutter");
            time_col.set_size_request (56, HOUR_H * 24);
            for (int h = 0; h < 24; h++) {
                var lbl = new Label (h == 0 ? "" : "%02d:00".printf (h));
                lbl.add_css_class ("cal-time-label");
                lbl.valign = Align.START; lbl.margin_top = -8;
                lbl.set_size_request (56, HOUR_H);
                time_col.append (lbl);
            }
            outer.append (time_col);
            outer.append (new Separator (Orientation.VERTICAL));

            // Day columns grid
            var cols_grid = new Grid ();
            cols_grid.hexpand = true;
            cols_grid.column_homogeneous = true;

            for (int d = 0; d < 7; d++) {
                // Background hour rows
                var bg = new Box (Orientation.VERTICAL, 0);
                bg.set_size_request (0, HOUR_H * 24);
                bg.hexpand = true;
                for (int h = 0; h < 24; h++) {
                    var hr = new Box (Orientation.VERTICAL, 0);
                    hr.add_css_class (h % 2 == 0 ? "cal-hour-even" : "cal-hour-odd");
                    hr.set_size_request (-1, HOUR_H);
                    hr.hexpand = true;
                    bg.append (hr);
                }

                var ov = new Overlay ();
                ov.hexpand = true;
                ov.set_child (bg);
                if (d > 0) {
                    var vsep = new Separator (Orientation.VERTICAL);
                    ov.add_overlay (vsep);
                    vsep.halign = Align.START;
                }
                _day_overlays[d] = ov;
                cols_grid.attach (ov, d, 0, 1, 1);
            }

            outer.append (cols_grid);
            scroll.set_child (outer);

            scroll.map.connect (() => {
                scroll.get_vadjustment ().value = HOUR_H * 7;
            });

            append (scroll);
            _update_day_headers ();
        }

        private void _update_day_headers () {
            // Remove old labels, keep gutter spacer
            for (int d = 0; d < 7; d++) {
                var old = _day_header_grid.get_child_at (d + 1, 0);
                if (old != null) _day_header_grid.remove (old);
            }

            string[] dow   = { "Sun","Mon","Tue","Wed","Thu","Fri","Sat" };
            var today = new DateTime.now_local ();

            for (int d = 0; d < 7; d++) {
                var date = _week_start.add_days (d);
                bool is_today = date.get_year ()  == today.get_year ()  &&
                                date.get_month () == today.get_month () &&
                                date.get_day_of_month () == today.get_day_of_month ();

                var vbox = new Box (Orientation.VERTICAL, 2);
                vbox.halign = Align.CENTER; vbox.hexpand = true;
                vbox.margin_top = 6; vbox.margin_bottom = 6;

                var dow_lbl = new Label (dow[d]);
                dow_lbl.add_css_class ("cal-dow-label");

                var day_lbl = new Label (date.get_day_of_month ().to_string ());
                if (is_today) day_lbl.add_css_class ("cal-today-badge");
                else          day_lbl.add_css_class ("cal-week-day-num");

                vbox.append (dow_lbl);
                vbox.append (day_lbl);
                _day_header_grid.attach (vbox, d + 1, 0, 1, 1);
            }
        }

        public async void refresh () {
            // Clear event chips from overlays (keep bg + vsep)
            for (int d = 0; d < 7; d++) {
                var ov = _day_overlays[d];
                Widget? c = ov.get_first_child ();
                while (c != null) {
                    var n = c.get_next_sibling ();
                    if (c.has_css_class ("cal-event-chip") || c.has_css_class ("cal-timed-event"))
                        ov.remove_overlay (c);
                    c = n;
                }
            }

            var range_end = _week_start.add_days (7);
            Gee.List<CalendarEvent?> events;
            try   { events = yield _mgr.get_events (_week_start, range_end); }
            catch (Error e) {
                warning ("CalendarWeekView: failed to fetch events: %s", e.message);
                events = new Gee.ArrayList<CalendarEvent?> ();
            }

            foreach (var evt in events) {
                int d = (int) (evt.start_time.difference (_week_start) / TimeSpan.DAY);
                if (d < 0 || d >= 7) continue;

                var chip = new CalendarEventChip (evt);
                chip.add_css_class ("cal-timed-event");
                chip.valign = Align.START;
                chip.halign = Align.FILL;
                chip.hexpand = true;
                chip.margin_start = 3; chip.margin_end = 3;

                int start_min = evt.start_time.get_hour () * 60 + evt.start_time.get_minute ();
                int end_min   = evt.all_day ? (23 * 60 + 59) :
                                evt.end_time.get_hour () * 60 + evt.end_time.get_minute ();
                if (end_min <= start_min) end_min = start_min + 60;

                chip.margin_top = start_min * HOUR_H / 60;
                chip.set_size_request (-1, (end_min - start_min) * HOUR_H / 60 - 2);

                var cap = evt;
                chip.clicked.connect (() => event_activated (cap));
                _day_overlays[d].add_overlay (chip);
            }
        }

        private DateTime _sunday_of_week (DateTime d) {
            // GTK DateTime: 1=Mon … 7=Sun; we want Sunday as first day
            int dow = d.get_day_of_week () % 7; // Sun=0, Mon=1 … Sat=6
            return d.add_days (-dow).add (
                -(d.get_hour ()   * (int64) TimeSpan.HOUR)
                -(d.get_minute () * (int64) TimeSpan.MINUTE)
                -(d.get_second () * (int64) TimeSpan.SECOND));
        }
    }

    // ── CalendarDayView ───────────────────────────────────────────────────────

    /**
     * Single-day view with hourly time slots and time-positioned event chips.
     */
    public class CalendarDayView : Box {
        private DateTime        _date;
        private CalendarManager _mgr;
        private Overlay         _events_overlay;
        private Label           _day_header_lbl;
        private const int       HOUR_H = 56;

        public signal void event_activated (CalendarEvent evt);

        public CalendarDayView (CalendarManager mgr) {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class ("cal-day-view");
            hexpand = true; vexpand = true;
            _mgr  = mgr;
            _date = new DateTime.now_local ();
            _build_ui ();
        }

        public void set_date (DateTime date) {
            _date = date;
            _day_header_lbl.label = _date.format ("%A, %B %e %Y");
            refresh.begin ();
        }

        private void _build_ui () {
            // ── Day header ──────────────────────────────────────────────────
            _day_header_lbl = new Label ("");
            _day_header_lbl.add_css_class ("cal-day-title");
            _day_header_lbl.label = _date.format ("%A, %B %e %Y");
            _day_header_lbl.halign = Align.START;
            _day_header_lbl.margin_start = 16;
            _day_header_lbl.margin_top   = 10;
            _day_header_lbl.margin_bottom = 10;
            append (_day_header_lbl);
            append (new Separator (Orientation.HORIZONTAL));

            // ── Scrollable time grid ────────────────────────────────────────
            var scroll = new ScrolledWindow ();
            scroll.hexpand = true; scroll.vexpand = true;
            scroll.hscrollbar_policy = PolicyType.NEVER;

            var hbox = new Box (Orientation.HORIZONTAL, 0);

            // Time gutter
            var time_col = new Box (Orientation.VERTICAL, 0);
            time_col.add_css_class ("cal-time-gutter");
            time_col.set_size_request (56, HOUR_H * 24);
            for (int h = 0; h < 24; h++) {
                var lbl = new Label (h == 0 ? "" : "%02d:00".printf (h));
                lbl.add_css_class ("cal-time-label");
                lbl.valign = Align.START; lbl.margin_top = -8;
                lbl.set_size_request (56, HOUR_H);
                time_col.append (lbl);
            }
            hbox.append (time_col);
            hbox.append (new Separator (Orientation.VERTICAL));

            // Events overlay
            var bg = new Box (Orientation.VERTICAL, 0);
            bg.set_size_request (0, HOUR_H * 24);
            bg.hexpand = true;
            for (int h = 0; h < 24; h++) {
                var hr = new Box (Orientation.VERTICAL, 0);
                hr.add_css_class (h % 2 == 0 ? "cal-hour-even" : "cal-hour-odd");
                hr.set_size_request (-1, HOUR_H);
                hr.hexpand = true;
                bg.append (hr);
            }

            _events_overlay = new Overlay ();
            _events_overlay.hexpand = true;
            _events_overlay.set_child (bg);
            hbox.append (_events_overlay);

            scroll.set_child (hbox);
            scroll.map.connect (() => {
                scroll.get_vadjustment ().value = HOUR_H * 7;
            });
            append (scroll);
        }

        public async void refresh () {
            Widget? c = _events_overlay.get_first_child ();
            while (c != null) {
                var n = c.get_next_sibling ();
                if (c.has_css_class ("cal-event-chip") || c.has_css_class ("cal-timed-event"))
                    _events_overlay.remove_overlay (c);
                c = n;
            }

            if (_mgr == null) return;
            var day_start = new DateTime.local (_date.get_year (), _date.get_month (), _date.get_day_of_month (), 0, 0, 0);
            var day_end   = day_start.add_days (1);

            Gee.List<CalendarEvent?> events;
            try   { events = yield _mgr.get_events (day_start, day_end); }
            catch (Error e) {
                warning ("CalendarDayView: failed to fetch events: %s", e.message);
                events = new Gee.ArrayList<CalendarEvent?> ();
            }

            foreach (var evt in events) {
                var chip = new CalendarEventChip (evt);
                chip.add_css_class ("cal-timed-event");
                chip.valign  = Align.START;
                chip.halign  = Align.FILL;
                chip.hexpand = true;
                chip.margin_start = 8; chip.margin_end = 8;

                int start_min = evt.start_time.get_hour () * 60 + evt.start_time.get_minute ();
                int end_min   = evt.all_day ? (23 * 60 + 59) :
                                evt.end_time.get_hour () * 60 + evt.end_time.get_minute ();
                if (end_min <= start_min) end_min = start_min + 60;

                chip.margin_top = start_min * HOUR_H / 60;
                chip.set_size_request (-1, (end_min - start_min) * HOUR_H / 60 - 2);

                var cap = evt;
                chip.clicked.connect (() => event_activated (cap));
                _events_overlay.add_overlay (chip);
            }
        }
    }
}
