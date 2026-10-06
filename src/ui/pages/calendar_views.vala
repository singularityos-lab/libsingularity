using Gtk;
using GLib;
using Gee;
using Singularity.Calendar;

namespace Singularity.Widgets {

    public class CalendarLayout : Object {
        private const string[] SUNDAY_FIRST = {
            "US", "CA", "MX", "BR", "JP", "KR", "TW", "HK", "IL", "PH", "ZA", "IN", "PE", "CO", "VE",
            "GT", "HN", "NI", "PA", "PR", "DO", "SV", "BO", "PY", "AR", "SA", "TH", "KE", "ZW"
        };
        private static int _first_weekday = 0;

        public static int first_weekday() {
            if (_first_weekday != 0) return _first_weekday;
            string? locale = Intl.setlocale(LocaleCategory.TIME, null);
            _first_weekday = 1;
            if (locale != null) {
                int underscore = locale.index_of_char('_');
                if (underscore > 0 && locale.length >= underscore + 3) {
                    string region = locale.substring(underscore + 1, 2).up();
                    foreach (string code in SUNDAY_FIRST) {
                        if (code == region) {
                            _first_weekday = 7;
                            break;
                        }
                    }
                }
            }
            return _first_weekday;
        }

        public static DateTime day_start(DateTime date) {
            return new DateTime.local(date.get_year(), date.get_month(), date.get_day_of_month(), 0, 0, 0);
        }

        public static DateTime week_start(DateTime date) {
            int offset = (date.get_day_of_week() - first_weekday() + 7) % 7;
            return day_start(date).add_days(-offset);
        }

        public static bool same_day(DateTime a, DateTime b) {
            return a.get_year() == b.get_year() && a.get_day_of_year() == b.get_day_of_year();
        }

        public static string weekday_label(int column, bool abbreviated) {
            int weekday = (first_weekday() - 1 + column) % 7 + 1;
            return Singularity.Calendar.RecurrenceRule.weekday_name(weekday, abbreviated);
        }

        public static bool covers_day(CalendarEvent evt, DateTime day) {
            var start = day_start(day);
            var end = start.add_days(1);
            if (evt.all_day) {
                var event_end = evt.end_time.compare(evt.start_time) > 0 ? evt.end_time : evt.start_time.add_days(1);
                return day_start(evt.start_time).compare(end) < 0 && event_end.compare(start) > 0;
            }
            return evt.start_time.compare(end) < 0 && evt.end_time.compare(start) > 0
                || (evt.start_time.compare(start) >= 0 && evt.start_time.compare(end) < 0);
        }

        public static bool spans_days(CalendarEvent evt) {
            if (evt.all_day) return true;
            return evt.end_time.difference(evt.start_time) >= TimeSpan.DAY;
        }

        public static string time_label(DateTime time) {
            return time.format("%H:%M");
        }

        public static string time_range(CalendarEvent evt) {
            if (evt.all_day) return _("All day");
            if (same_day(evt.start_time, evt.end_time) || evt.end_time.difference(evt.start_time) < TimeSpan.DAY
                    && evt.end_time.get_hour() == 0 && evt.end_time.get_minute() == 0) {
                return "%s - %s".printf(time_label(evt.start_time), time_label(evt.end_time));
            }
            return "%s %s - %s %s".printf(evt.start_time.format("%-d %b").strip(), time_label(evt.start_time),
                evt.end_time.format("%-d %b").strip(), time_label(evt.end_time));
        }

        private static HashMap<string, CssProvider>? color_providers = null;

        public static void tint(Widget widget, string? color) {
            if (color_providers == null) color_providers = new HashMap<string, CssProvider>();
            string hex = color != null && color != "" ? color : "#3584e4";
            var rgba = Gdk.RGBA();
            if (!rgba.parse(hex)) {
                hex = "#3584e4";
                rgba.parse(hex);
            }
            string key = "cal-color-" + hex.replace("#", "").replace("(", "").replace(")", "").replace(",", "").replace(" ", "");
            if (!color_providers.has_key(key)) {
                var provider = new CssProvider();
                provider.load_from_string(
                    ".%s { --cal-event-color: %s; }\n".printf(key, hex)
                    + ".%s.cal-event-chip, .%s.cal-timed-event { background-color: alpha(%s, 0.2); background-image: none; border-left: 3px solid %s; }\n".printf(key, key, hex, hex)
                    + ".%s.cal-event-chip:hover, .%s.cal-timed-event:hover { background-color: alpha(%s, 0.32); background-image: none; }\n".printf(key, key, hex)
                    + ".%s.cal-event-dot, .%s.cal-color-swatch { background-color: %s; }\n".printf(key, key, hex)
                    + ".%s.cal-event-chip { padding: 1px 2px; min-height: 18px; border-radius: 5px; }\n".printf(key)
                    + ".%s.cal-timed-event { padding: 1px 4px; border-radius: 6px; }\n".printf(key));
                color_providers[key] = provider;
                StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider, STYLE_PROVIDER_PRIORITY_USER + 5);
            }
            widget.add_css_class(key);
        }
    }

    public class CalendarEventChip : Button {
        public CalendarEvent event_data { get; private set; }

        public CalendarEventChip (CalendarEvent evt, bool show_time = true) {
            event_data = evt;
            add_css_class ("cal-event-chip");
            tooltip_text = "%s\n%s".printf (evt.title, CalendarLayout.time_range (evt));
            CalendarLayout.tint (this, evt.color);

            var box = new Box (Orientation.HORIZONTAL, 4);
            box.margin_start = 4;
            box.margin_end   = 4;

            if (!evt.all_day && show_time) {
                var time_lbl = new Label (CalendarLayout.time_label (evt.start_time));
                time_lbl.add_css_class ("cal-event-time");
                box.append (time_lbl);
            }

            var title_lbl = new Label (evt.title != "" ? evt.title : _("Untitled"));
            title_lbl.ellipsize = Pango.EllipsizeMode.END;
            title_lbl.halign    = Align.START;
            title_lbl.hexpand   = true;
            title_lbl.xalign    = 0;
            box.append (title_lbl);

            if (evt.is_recurring ()) {
                var icon = new Image.from_icon_name ("media-playlist-repeat-symbolic");
                icon.pixel_size = 10;
                icon.add_css_class ("dim-label");
                box.append (icon);
            }
            set_child (box);
        }
    }

    public class CalendarNavPicker : Box {
        private DateTime   _display_month;
        private DateTime?  _selected;
        private Label      _month_lbl;
        private Grid       _grid;
        private Button     _today_btn;
        private Gee.HashSet<string> _busy_days = new Gee.HashSet<string> ();

        public signal void date_selected (DateTime date);
        public signal void today_clicked ();
        public signal void month_changed (DateTime month);

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

        public void set_busy_days (Gee.Collection<string> days) {
            _busy_days.clear ();
            _busy_days.add_all (days);
            _refresh ();
        }

        public DateTime displayed_month { get { return _display_month; } }

        private void _build () {
            var hdr  = new Box (Orientation.HORIZONTAL, 0);

            var prev = new Button.from_icon_name ("go-previous-symbolic");
            prev.add_css_class ("flat"); prev.add_css_class ("circular");
            prev.set_size_request (28, 28);
            prev.tooltip_text = _("Previous Month");
            prev.clicked.connect (() => { _display_month = _display_month.add_months (-1); _refresh (); month_changed (_display_month); });

            _month_lbl = new Label ("");
            _month_lbl.hexpand  = true;
            _month_lbl.halign   = Align.CENTER;
            _month_lbl.add_css_class ("cal-nav-month-label");

            _today_btn = new Button.with_label (_("Today"));
            _today_btn.add_css_class ("flat");
            _today_btn.add_css_class ("cal-nav-today-btn");
            _today_btn.set_size_request (-1, 24);
            _today_btn.clicked.connect (() => {
                var now = new DateTime.now_local ();
                _display_month = new DateTime.local (now.get_year (), now.get_month (), 1, 0, 0, 0);
                _selected      = now;
                _refresh ();
                month_changed (_display_month);
                today_clicked ();
            });

            var next = new Button.from_icon_name ("go-next-symbolic");
            next.add_css_class ("flat"); next.add_css_class ("circular");
            next.set_size_request (28, 28);
            next.tooltip_text = _("Next Month");
            next.clicked.connect (() => { _display_month = _display_month.add_months (1); _refresh (); month_changed (_display_month); });

            hdr.append (prev);
            hdr.append (_month_lbl);
            hdr.append (_today_btn);
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
            _month_lbl.label = _display_month.format (_("%B %Y"));

            Widget? c = _grid.get_first_child ();
            while (c != null) { var n = c.get_next_sibling (); _grid.remove (c); c = n; }

            for (int i = 0; i < 7; i++) {
                string name = CalendarLayout.weekday_label (i, true);
                var l = new Label (name.substring (0, name.index_of_nth_char (1)));
                l.add_css_class ("dim-label"); l.add_css_class ("caption");
                l.set_size_request (28, 18); l.halign = Align.CENTER;
                _grid.attach (l, i, 0, 1, 1);
            }

            var first     = new DateTime.local (_display_month.get_year (), _display_month.get_month (), 1, 0, 0, 0);
            int start_col = (first.get_day_of_week () - CalendarLayout.first_weekday () + 7) % 7;
            int dim       = GLib.Date.get_days_in_month ((DateMonth) _display_month.get_month (), (DateYear) _display_month.get_year ());
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
                string key = "%04d-%02d-%02d".printf (_display_month.get_year (), _display_month.get_month (), d);
                if (_busy_days.contains (key)) btn.add_css_class ("busy");
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
    }

    public class CalendarMonthView : Box {
        private DateTime        _date;
        private CalendarManager _mgr;
        private Grid            _grid;
        private Grid            _header;
        private const int       MAX_CHIPS = 3;

        public signal void event_activated (CalendarEvent evt, Widget source);
        public signal void day_selected    (DateTime date);
        public signal void create_requested (DateTime start, DateTime end, bool all_day);

        private bool _show_weekends = true;
        public bool show_weekends {
            get { return _show_weekends; }
            set {
                _show_weekends = value;
                int col = 0;
                for (Widget? w = _header.get_first_child (); w != null; w = w.get_next_sibling ()) {
                    int weekday = (CalendarLayout.first_weekday () - 1 + col) % 7 + 1;
                    w.visible = value || weekday < 6;
                    col++;
                }
                refresh.begin ();
            }
        }

        public CalendarMonthView (CalendarManager mgr) {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class ("cal-month-view");
            hexpand = true; vexpand = true;
            _mgr  = mgr;
            _date = new DateTime.now_local ();
            _header = new Grid ();
            _header.add_css_class ("cal-dow-header");
            _header.column_homogeneous = true;
            for (int i = 0; i < 7; i++) {
                var l = new Label (CalendarLayout.weekday_label (i, false));
                l.add_css_class ("cal-dow-label");
                l.ellipsize = Pango.EllipsizeMode.END;
                l.halign = Align.CENTER; l.hexpand = true;
                _header.attach (l, i, 0, 1, 1);
            }
            append (_header);
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

        public async void refresh () {
            var first = new DateTime.local (_date.get_year (), _date.get_month (), 1, 0, 0, 0);
            var range_start = CalendarLayout.week_start (first);
            var range_end   = range_start.add_days (42);
            var events = yield _mgr.get_events (range_start, range_end);
            events.sort ((a, b) => {
                if (a.all_day != b.all_day) return a.all_day ? -1 : 1;
                return a.start_time.compare (b.start_time);
            });

            Widget? c = _grid.get_first_child ();
            while (c != null) { var n = c.get_next_sibling (); _grid.remove (c); c = n; }

            var today = new DateTime.now_local ();
            for (int i = 0; i < 42; i++) {
                var day = range_start.add_days (i);
                bool in_month = day.get_month () == _date.get_month ();
                bool is_today = CalendarLayout.same_day (day, today);

                var cell = new Box (Orientation.VERTICAL, 0);
                cell.add_css_class ("cal-day-cell");
                if (!in_month) cell.add_css_class ("out-of-month");
                if (is_today)  cell.add_css_class ("today");
                cell.hexpand = true; cell.vexpand = true;
                cell.overflow = Overflow.HIDDEN;
                cell.visible = _show_weekends || day.get_day_of_week () < 6;

                var num_btn = new Button.with_label (day.get_day_of_month ().to_string ());
                num_btn.add_css_class ("flat");
                num_btn.add_css_class (is_today ? "cal-today-badge" : "cal-day-num");
                num_btn.halign = Align.END;
                num_btn.margin_end = 4; num_btn.margin_top = 3;
                num_btn.tooltip_text = day.format (_("%A, %-d %B"));
                var captured_day = day;
                num_btn.clicked.connect (() => day_selected (captured_day));
                cell.append (num_btn);

                var ev_box = new Box (Orientation.VERTICAL, 2);
                ev_box.margin_start = 3; ev_box.margin_end = 3; ev_box.margin_bottom = 4;
                var day_events = new Gee.ArrayList<CalendarEvent?> ();
                foreach (var evt in events) {
                    if (CalendarLayout.covers_day (evt, day)) day_events.add (evt);
                }
                int shown = 0;
                foreach (var evt in day_events) {
                    if (shown == MAX_CHIPS && day_events.size > MAX_CHIPS) break;
                    var chip = new CalendarEventChip (evt, !CalendarLayout.spans_days (evt));
                    chip.add_css_class ("compact");
                    if (CalendarLayout.spans_days (evt)) chip.add_css_class ("spanning");
                    var cap = evt;
                    chip.clicked.connect (() => event_activated (cap, chip));
                    ev_box.append (chip);
                    shown++;
                }
                if (day_events.size > MAX_CHIPS) {
                    var more = new Button.with_label (ngettext ("%d more", "%d more", day_events.size - MAX_CHIPS).printf (day_events.size - MAX_CHIPS));
                    more.add_css_class ("flat");
                    more.add_css_class ("cal-more-label");
                    more.halign = Align.START;
                    var list = day_events;
                    more.clicked.connect (() => show_day_popover (more, captured_day, list));
                    ev_box.append (more);
                }
                cell.append (ev_box);

                var gesture = new GestureClick ();
                gesture.pressed.connect ((n, x, y) => {
                    if (n == 2) {
                        var start = new DateTime.local (captured_day.get_year (), captured_day.get_month (), captured_day.get_day_of_month (), 9, 0, 0);
                        create_requested (start, start.add_hours (1), false);
                    }
                });
                cell.add_controller (gesture);

                _grid.attach (cell, i % 7, i / 7, 1, 1);
            }
        }

        private void show_day_popover (Widget anchor, DateTime day, Gee.List<CalendarEvent?> list) {
            var pop = new Popover ();
            pop.add_css_class ("cal-day-popover");
            var box = new Box (Orientation.VERTICAL, 4);
            box.margin_top = 8; box.margin_bottom = 8; box.margin_start = 8; box.margin_end = 8;
            var title = new Label (day.format (_("%A, %-d %B")));
            title.add_css_class ("heading");
            title.halign = Align.START;
            box.append (title);
            foreach (var evt in list) {
                var chip = new CalendarEventChip (evt);
                chip.set_size_request (220, -1);
                var cap = evt;
                chip.clicked.connect (() => {
                    pop.popdown ();
                    event_activated (cap, anchor);
                });
                box.append (chip);
            }
            pop.child = box;
            pop.set_parent (anchor);
            pop.closed.connect (() => Idle.add (() => { pop.unparent (); return false; }));
            pop.popup ();
        }
    }

    private class TimedSlot : Object {
        public int start_min;
        public int end_min;
        public int column;
        public int columns;
        public int offset_x;
        public int offset_y;
    }

    public class CalendarTimeGrid : Box {
        public const int HOUR_H = 48;
        protected CalendarManager _mgr;
        protected DateTime        _start;
        protected int             _days;
        private Grid              _header;
        private Box               _all_day_row;
        private Box[]             _all_day_cells;
        private Overlay[]         _columns;
        private Box               _now_line;
        private int               _now_column = -1;
        private ScrolledWindow    _scroll;
        private uint              _clock_source = 0;
        private Box?              _ghost = null;
        private bool              _scrolled = false;

        public signal void event_activated (CalendarEvent evt, Widget source);
        public signal void day_selected    (DateTime date);
        public signal void create_requested (DateTime start, DateTime end, bool all_day);
        public signal void event_moved     (CalendarEvent evt, DateTime new_start);
        public signal void event_copied    (CalendarEvent evt, DateTime new_start);

        private bool _show_weekends = true;
        public bool show_weekends {
            get { return _show_weekends; }
            set {
                _show_weekends = value;
                _apply_weekends ();
            }
        }

        private void _apply_weekends () {
            for (int d = 0; d < _days; d++) {
                bool visible = _days == 1 || _show_weekends || _start.add_days (d).get_day_of_week () < 6;
                _columns[d].visible = visible;
                _all_day_cells[d].visible = visible;
                var header = _header.get_child_at (d + 1, 0);
                if (header != null) header.visible = visible;
            }
        }

        public CalendarTimeGrid (CalendarManager mgr, int days) {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            _mgr = mgr;
            _days = days;
            _start = CalendarLayout.day_start (new DateTime.now_local ());
            hexpand = true; vexpand = true;
            _build ();
            _clock_source = Timeout.add_seconds (60, () => { _place_now_line (); return Source.CONTINUE; });
        }

        protected override void dispose () {
            if (_clock_source != 0) {
                Source.remove (_clock_source);
                _clock_source = 0;
            }
            base.dispose ();
        }

        private void _build () {
            _header = new Grid ();
            _header.add_css_class ("cal-week-header");
            _header.column_homogeneous = false;
            var spacer = new Box (Orientation.VERTICAL, 0);
            spacer.set_size_request (56, -1);
            _header.attach (spacer, 0, 0, 1, 1);
            append (_header);

            var all_day_outer = new Box (Orientation.HORIZONTAL, 0);
            all_day_outer.add_css_class ("cal-all-day-row");
            var all_day_label = new Label (_("All day"));
            all_day_label.add_css_class ("cal-time-label");
            all_day_label.set_size_request (56, -1);
            all_day_label.xalign = 1;
            all_day_outer.append (all_day_label);
            _all_day_row = new Box (Orientation.HORIZONTAL, 0);
            _all_day_row.homogeneous = true;
            _all_day_row.hexpand = true;
            _all_day_cells = new Box[_days];
            for (int d = 0; d < _days; d++) {
                var cell = new Box (Orientation.VERTICAL, 2);
                cell.add_css_class ("cal-all-day-cell");
                cell.hexpand = true;
                cell.set_size_request (-1, 26);
                int column = d;
                var click = new GestureClick ();
                click.pressed.connect ((n, x, y) => {
                    if (n != 2) return;
                    var day = _start.add_days (column);
                    create_requested (day, day.add_days (1), true);
                });
                cell.add_controller (click);
                _all_day_cells[d] = cell;
                _all_day_row.append (cell);
            }
            all_day_outer.append (_all_day_row);
            append (all_day_outer);

            _scroll = new ScrolledWindow ();
            _scroll.hexpand = true; _scroll.vexpand = true;
            _scroll.hscrollbar_policy = PolicyType.NEVER;

            var outer = new Box (Orientation.HORIZONTAL, 0);
            var time_col = new Fixed ();
            time_col.add_css_class ("cal-time-gutter");
            time_col.set_size_request (56, HOUR_H * 24);
            for (int h = 1; h < 24; h++) {
                var lbl = new Label (CalendarLayout.time_label (new DateTime.local (2024, 1, 1, h, 0, 0)));
                lbl.add_css_class ("cal-time-label");
                lbl.xalign = 1;
                lbl.set_size_request (52, 16);
                time_col.put (lbl, 0, h * HOUR_H - 8);
            }
            outer.append (time_col);

            var cols = new Box (Orientation.HORIZONTAL, 0);
            cols.homogeneous = true;
            cols.hexpand = true;
            _columns = new Overlay[_days];
            for (int d = 0; d < _days; d++) {
                var bg = new Box (Orientation.VERTICAL, 0);
                bg.add_css_class ("cal-day-column");
                bg.set_size_request (-1, HOUR_H * 24);
                bg.hexpand = true;
                for (int h = 0; h < 24; h++) {
                    var hr = new Box (Orientation.VERTICAL, 0);
                    hr.add_css_class ("cal-hour-slot");
                    hr.set_size_request (-1, HOUR_H);
                    bg.append (hr);
                }
                var ov = new Overlay ();
                ov.hexpand = true;
                ov.set_child (bg);
                ov.get_child_position.connect (_position_child);
                _attach_create_gestures (ov, d);
                _columns[d] = ov;
                cols.append (ov);
            }
            outer.append (cols);
            _scroll.set_child (outer);
            _scroll.map.connect (() => {
                if (_scrolled) return;
                _scrolled = true;
                Idle.add (() => {
                    if (_pending_minute >= 0) _apply_scroll_minute (_pending_minute);
                    else scroll_to_working_hours ();
                    _pending_minute = -1;
                    return false;
                });
            });
            append (_scroll);

            _now_line = new Box (Orientation.HORIZONTAL, 0);
            _now_line.add_css_class ("cal-now-line");
            _now_line.can_target = false;
            _now_line.set_size_request (-1, 2);
        }

        private int _pending_minute = -1;

        /**
         * Scrolls the hours so that `time` shows near the top, with an hour
         * of context above it. Before the view is shown the position is kept
         * and applied when it appears.
         */
        public void scroll_to_time (DateTime time) {
            int minute = time.get_hour () * 60 + time.get_minute ();
            if (!_scroll.get_mapped () || !_scrolled) {
                _pending_minute = minute;
                return;
            }
            Idle.add (() => { _apply_scroll_minute (minute); return false; });
        }

        private void _apply_scroll_minute (int minute) {
            double y = double.max (0, (minute - 60) * HOUR_H / 60.0);
            _scroll.get_vadjustment ().value = y;
        }

        public void scroll_to_working_hours () {
            var now = new DateTime.now_local ();
            int hour = _now_column >= 0 ? int.max (0, now.get_hour () - 2) : 7;
            _scroll.get_vadjustment ().value = hour * HOUR_H;
        }

        private int _minute_at (double y) {
            int minutes = (int) (y / HOUR_H * 60.0);
            return (minutes / 15 * 15).clamp (0, 24 * 60 - 15);
        }

        private void _attach_create_gestures (Overlay ov, int column) {
            var drag = new GestureDrag ();
            double origin_y = 0;
            drag.drag_begin.connect ((x, y) => {
                origin_y = y;
                var target = ov.pick (x, y, PickFlags.DEFAULT);
                if (target != null && !target.is_ancestor (ov.get_child ()) && target != ov.get_child ()) {
                    drag.set_state (EventSequenceState.DENIED);
                }
            });
            drag.drag_update.connect ((dx, dy) => {
                if (dy.abs () < 8) return;
                int a = _minute_at (double.min (origin_y, origin_y + dy));
                int b = _minute_at (double.max (origin_y, origin_y + dy)) + 15;
                _show_ghost (ov, a, b);
            });
            drag.drag_end.connect ((dx, dy) => {
                _clear_ghost ();
                var day = _start.add_days (column);
                if (dy.abs () < 8) return;
                int a = _minute_at (double.min (origin_y, origin_y + dy));
                int b = _minute_at (double.max (origin_y, origin_y + dy)) + 15;
                create_requested (day.add_minutes (a), day.add_minutes (b), false);
            });
            ov.add_controller (drag);
            var click = new GestureClick ();
            click.pressed.connect ((n, x, y) => {
                if (n != 2) return;
                var day = _start.add_days (column);
                int a = _minute_at (y) / 30 * 30;
                create_requested (day.add_minutes (a), day.add_minutes (a + 60), false);
            });
            ov.add_controller (click);
        }

        private void _show_ghost (Overlay ov, int a, int b) {
            if (_ghost == null || _ghost.get_parent () != ov) {
                _clear_ghost ();
                _ghost = new Box (Orientation.VERTICAL, 0);
                _ghost.add_css_class ("cal-create-ghost");
                _ghost.can_target = false;
                _ghost.valign = Align.FILL;
                _ghost.halign = Align.FILL;
                var slot = new TimedSlot ();
                _ghost.set_data<TimedSlot> ("slot", slot);
                ov.add_overlay (_ghost);
            }
            var slot = _ghost.get_data<TimedSlot> ("slot");
            slot.start_min = a; slot.end_min = b; slot.column = 0; slot.columns = 1;
            _ghost.queue_resize ();
            ov.queue_allocate ();
        }

        private void _clear_ghost () {
            if (_ghost != null) {
                var parent = _ghost.get_parent () as Overlay;
                if (parent != null) parent.remove_overlay (_ghost);
                _ghost = null;
            }
        }

        private bool _position_child (Overlay ov, Widget widget, out Gdk.Rectangle rect) {
            rect = Gdk.Rectangle ();
            int width = ov.get_width ();
            if (widget == _now_line) {
                var now = new DateTime.now_local ();
                rect.x = 0;
                rect.width = width;
                rect.y = (now.get_hour () * 60 + now.get_minute ()) * HOUR_H / 60;
                rect.height = 2;
                return true;
            }
            var slot = widget.get_data<TimedSlot> ("slot");
            if (slot == null) return false;
            int usable = width - 6;
            int col_w = usable / int.max (1, slot.columns);
            rect.x = 2 + slot.column * col_w;
            rect.width = int.max (8, col_w - 2);
            rect.x += slot.offset_x;
            rect.y = slot.start_min * HOUR_H / 60 + 1 + slot.offset_y;
            rect.height = int.max (22, (slot.end_min - slot.start_min) * HOUR_H / 60 - 2);
            return true;
        }

        public void set_date (DateTime date) {
            _start = _days == 7 ? CalendarLayout.week_start (date) : CalendarLayout.day_start (date);
            _update_header ();
            _apply_weekends ();
            refresh.begin ();
        }

        public DateTime range_start { get { return _start; } }

        private void _update_header () {
            for (int d = 0; d < 7; d++) {
                var old = _header.get_child_at (d + 1, 0);
                if (old != null) _header.remove (old);
            }
            var today = new DateTime.now_local ();
            for (int d = 0; d < _days; d++) {
                var date = _start.add_days (d);
                bool is_today = CalendarLayout.same_day (date, today);
                var btn = new Button ();
                btn.add_css_class ("flat");
                btn.add_css_class ("cal-week-day-btn");
                btn.hexpand = true;
                var vbox = new Box (Orientation.VERTICAL, 2);
                vbox.halign = Align.CENTER;
                var dow_lbl = new Label (date.format (_days == 1 ? "%A" : "%a"));
                dow_lbl.add_css_class ("cal-dow-label");
                var day_lbl = new Label (date.get_day_of_month ().to_string ());
                day_lbl.add_css_class (is_today ? "cal-today-badge" : "cal-week-day-num");
                day_lbl.halign = Align.CENTER;
                vbox.append (dow_lbl);
                vbox.append (day_lbl);
                btn.child = vbox;
                var captured = date;
                btn.clicked.connect (() => day_selected (captured));
                _header.attach (btn, d + 1, 0, 1, 1);
            }
        }

        private void _place_now_line () {
            var parent = _now_line.get_parent () as Overlay;
            if (parent != null) parent.remove_overlay (_now_line);
            _now_column = -1;
            var today = new DateTime.now_local ();
            for (int d = 0; d < _days; d++) {
                if (CalendarLayout.same_day (_start.add_days (d), today)) {
                    _columns[d].add_overlay (_now_line);
                    _now_column = d;
                }
            }
        }

        public async void refresh () {
            var range_end = _start.add_days (_days);
            var events = yield _mgr.get_events (_start, range_end);
            events.sort ((a, b) => a.start_time.compare (b.start_time));

            for (int d = 0; d < _days; d++) {
                var ov = _columns[d];
                Widget? c = ov.get_first_child ();
                while (c != null) {
                    var n = c.get_next_sibling ();
                    if (c != ov.get_child ()) ov.remove_overlay (c);
                    c = n;
                }
                Widget? a = _all_day_cells[d].get_first_child ();
                while (a != null) { var n = a.get_next_sibling (); _all_day_cells[d].remove (a); a = n; }
            }
            _place_now_line ();

            for (int d = 0; d < _days; d++) {
                var day = _start.add_days (d);
                var day_end = day.add_days (1);
                var timed = new Gee.ArrayList<CalendarEvent?> ();
                foreach (var evt in events) {
                    if (!CalendarLayout.covers_day (evt, day)) continue;
                    if (CalendarLayout.spans_days (evt)) {
                        var chip = new CalendarEventChip (evt, false);
                        chip.add_css_class ("compact");
                        var cap = evt;
                        chip.clicked.connect (() => event_activated (cap, chip));
                        _all_day_cells[d].append (chip);
                    } else {
                        timed.add (evt);
                    }
                }
                var slots = new Gee.ArrayList<TimedSlot> ();
                foreach (var evt in timed) {
                    var slot = new TimedSlot ();
                    var s = evt.start_time.compare (day) < 0 ? day : evt.start_time;
                    var e = evt.end_time.compare (day_end) > 0 ? day_end : evt.end_time;
                    slot.start_min = (int) (s.difference (day) / TimeSpan.MINUTE);
                    slot.end_min = int.max (slot.start_min + 20, (int) (e.difference (day) / TimeSpan.MINUTE));
                    slots.add (slot);
                }
                _assign_columns (slots);
                for (int i = 0; i < timed.size; i++) {
                    var evt = timed[i];
                    var chip = new CalendarEventChip (evt);
                    chip.remove_css_class ("cal-event-chip");
                    chip.add_css_class ("cal-timed-event");
                    CalendarLayout.tint (chip, evt.color);
                    chip.set_data<TimedSlot> ("slot", slots[i]);
                    chip.valign = Align.FILL;
                    chip.halign = Align.FILL;
                    chip.get_child ().valign = Align.START;
                    var cap = evt;
                    _attach_move_gesture (chip, cap, d);
                    chip.clicked.connect (() => {
                        if (chip.get_data<bool> ("dragged")) {
                            chip.set_data<bool> ("dragged", false);
                            return;
                        }
                        event_activated (cap, chip);
                    });
                    _columns[d].add_overlay (chip);
                }
            }
        }

        private void _attach_move_gesture (Widget chip, CalendarEvent evt, int column) {
            var drag = new GestureDrag ();
            drag.propagation_phase = PropagationPhase.CAPTURE;
            drag.drag_update.connect ((dx, dy) => {
                if (dy.abs () < 6 && dx.abs () < 12) return;
                drag.set_state (EventSequenceState.CLAIMED);
                chip.set_data<bool> ("dragged", true);
                chip.add_css_class ("dragging");
                if ((drag.get_current_event_state () & Gdk.ModifierType.CONTROL_MASK) != 0) chip.add_css_class ("copying");
                else chip.remove_css_class ("copying");
                var slot = chip.get_data<TimedSlot> ("slot");
                slot.offset_x = (int) dx;
                slot.offset_y = (int) dy;
                chip.get_parent ().queue_allocate ();
            });
            drag.drag_end.connect ((dx, dy) => {
                bool copy = (drag.get_current_event_state () & Gdk.ModifierType.CONTROL_MASK) != 0;
                chip.remove_css_class ("dragging");
                chip.remove_css_class ("copying");
                var slot = chip.get_data<TimedSlot> ("slot");
                slot.offset_x = 0;
                slot.offset_y = 0;
                chip.get_parent ().queue_allocate ();
                if (!chip.get_data<bool> ("dragged")) return;
                int minutes = (int) Math.round (dy / HOUR_H * 60.0 / 15.0) * 15;
                int column_width = int.max (1, _columns[0].get_width ());
                int day_shift = _days > 1 ? (int) Math.round (dx / column_width) : 0;
                day_shift = (column + day_shift).clamp (0, _days - 1) - column;
                if (minutes == 0 && day_shift == 0) {
                    chip.queue_allocate ();
                    return;
                }
                var target = evt.start_time.add_days (day_shift).add_minutes (minutes);
                if (copy) event_copied (evt, target);
                else event_moved (evt, target);
            });
            chip.add_controller (drag);
        }

        private void _assign_columns (Gee.List<TimedSlot> slots) {
            int i = 0;
            while (i < slots.size) {
                int cluster_end = slots[i].end_min;
                int j = i;
                var active = new Gee.ArrayList<TimedSlot> ();
                int max_cols = 0;
                while (j < slots.size && (j == i || slots[j].start_min < cluster_end)) {
                    var slot = slots[j];
                    var free = new Gee.HashSet<int> ();
                    foreach (var other in active) if (other.end_min > slot.start_min) free.add (other.column);
                    int col = 0;
                    while (free.contains (col)) col++;
                    slot.column = col;
                    active.add (slot);
                    max_cols = int.max (max_cols, col + 1);
                    cluster_end = int.max (cluster_end, slot.end_min);
                    j++;
                }
                for (int k = i; k < j; k++) slots[k].columns = max_cols;
                i = j;
            }
        }
    }

    public class CalendarWeekView : CalendarTimeGrid {
        public CalendarWeekView (CalendarManager mgr) {
            base (mgr, 7);
            add_css_class ("cal-week-view");
            set_date (new DateTime.now_local ());
        }
    }

    public class CalendarDayView : CalendarTimeGrid {
        public CalendarDayView (CalendarManager mgr) {
            base (mgr, 1);
            add_css_class ("cal-day-view");
            set_date (new DateTime.now_local ());
        }
    }
}
