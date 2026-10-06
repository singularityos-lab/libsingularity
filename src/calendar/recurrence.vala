using GLib;

namespace Singularity.Calendar {

    public enum RecurrenceFrequency {
        NONE,
        DAILY,
        WEEKLY,
        MONTHLY,
        YEARLY;

        public string to_rrule() {
            switch (this) {
                case DAILY: return "DAILY";
                case WEEKLY: return "WEEKLY";
                case MONTHLY: return "MONTHLY";
                case YEARLY: return "YEARLY";
                default: return "";
            }
        }

        public static RecurrenceFrequency from_rrule(string value) {
            switch (value.up()) {
                case "DAILY": return DAILY;
                case "WEEKLY": return WEEKLY;
                case "MONTHLY": return MONTHLY;
                case "YEARLY": return YEARLY;
                default: return NONE;
            }
        }
    }

    public struct RecurrenceWeekday {
        public int position;
        public int weekday;

        public RecurrenceWeekday(int weekday, int position = 0) {
            this.weekday = weekday;
            this.position = position;
        }
    }

    public class RecurrenceRule : Object {
        private const string[] DAY_CODES = { "MO", "TU", "WE", "TH", "FR", "SA", "SU" };
        private const int MAX_PERIODS = 20000;

        public RecurrenceFrequency frequency { get; set; default = RecurrenceFrequency.NONE; }
        public int interval { get; set; default = 1; }
        public int count { get; set; default = 0; }
        public DateTime? until { get; set; default = null; }
        public RecurrenceWeekday[] by_weekday = {};
        public int[] by_month_day = {};
        public int[] by_month = {};
        public int[] by_set_pos = {};

        public RecurrenceRule(RecurrenceFrequency frequency = RecurrenceFrequency.NONE, int interval = 1) {
            this.frequency = frequency;
            this.interval = interval;
        }

        public static RecurrenceRule? parse(string? text) {
            if (text == null) return null;
            string value = text.strip();
            if (value.has_prefix("RRULE:")) value = value.substring(6);
            if (value == "") return null;
            var rule = new RecurrenceRule();
            foreach (string part in value.split(";")) {
                int eq = part.index_of_char('=');
                if (eq <= 0) continue;
                string key = part.substring(0, eq).up();
                string val = part.substring(eq + 1);
                switch (key) {
                    case "FREQ":
                        rule.frequency = RecurrenceFrequency.from_rrule(val);
                        break;
                    case "INTERVAL":
                        rule.interval = int.max(1, int.parse(val));
                        break;
                    case "COUNT":
                        rule.count = int.max(0, int.parse(val));
                        break;
                    case "UNTIL":
                        rule.until = parse_until(val);
                        break;
                    case "BYDAY":
                        RecurrenceWeekday[] days = {};
                        foreach (string item in val.split(",")) {
                            string code = item.strip().up();
                            if (code.length < 2) continue;
                            string day = code.substring(code.length - 2);
                            int weekday = weekday_from_code(day);
                            if (weekday == 0) continue;
                            string prefix = code.substring(0, code.length - 2);
                            int position = prefix == "" ? 0 : int.parse(prefix);
                            days += RecurrenceWeekday(weekday, position);
                        }
                        rule.by_weekday = days;
                        break;
                    case "BYMONTHDAY":
                        rule.by_month_day = parse_int_list(val, -31, 31);
                        break;
                    case "BYMONTH":
                        rule.by_month = parse_int_list(val, 1, 12);
                        break;
                    case "BYSETPOS":
                        rule.by_set_pos = parse_int_list(val, -366, 366);
                        break;
                }
            }
            if (rule.frequency == RecurrenceFrequency.NONE) return null;
            return rule;
        }

        private static int[] parse_int_list(string value, int min, int max) {
            int[] result = {};
            foreach (string item in value.split(",")) {
                int number = int.parse(item.strip());
                if (number != 0 && number >= min && number <= max) result += number;
            }
            return result;
        }

        private static DateTime? parse_until(string value) {
            string text = value.strip();
            if (text.length < 8) return null;
            int year = int.parse(text.substring(0, 4));
            int month = int.parse(text.substring(4, 2));
            int day = int.parse(text.substring(6, 2));
            if (text.length >= 15 && text[8] == 'T') {
                int hour = int.parse(text.substring(9, 2));
                int minute = int.parse(text.substring(11, 2));
                int second = int.parse(text.substring(13, 2));
                if (text.has_suffix("Z")) return new DateTime.utc(year, month, day, hour, minute, second).to_local();
                return new DateTime.local(year, month, day, hour, minute, second);
            }
            return new DateTime.local(year, month, day, 23, 59, 59);
        }

        private static int weekday_from_code(string code) {
            for (int i = 0; i < DAY_CODES.length; i++) {
                if (DAY_CODES[i] == code) return i + 1;
            }
            return 0;
        }

        public string to_rrule() {
            if (frequency == RecurrenceFrequency.NONE) return "";
            var builder = new StringBuilder("FREQ=" + frequency.to_rrule());
            if (interval > 1) builder.append_printf(";INTERVAL=%d", interval);
            if (by_weekday.length > 0) {
                string[] codes = {};
                foreach (var day in by_weekday) {
                    codes += (day.position != 0 ? day.position.to_string() : "") + DAY_CODES[day.weekday - 1];
                }
                builder.append(";BYDAY=" + string.joinv(",", codes));
            }
            if (by_month_day.length > 0) builder.append(";BYMONTHDAY=" + join_ints(by_month_day));
            if (by_month.length > 0) builder.append(";BYMONTH=" + join_ints(by_month));
            if (by_set_pos.length > 0) builder.append(";BYSETPOS=" + join_ints(by_set_pos));
            if (count > 0) {
                builder.append_printf(";COUNT=%d", count);
            } else if (until != null) {
                builder.append(";UNTIL=" + until.to_utc().format("%Y%m%dT%H%M%SZ"));
            }
            return builder.str;
        }

        private static string join_ints(int[] values) {
            string[] parts = {};
            foreach (int value in values) parts += value.to_string();
            return string.joinv(",", parts);
        }

        public static string weekday_name(int weekday, bool abbreviated = false) {
            var monday = new DateTime.local(2024, 1, 1, 12, 0, 0);
            return monday.add_days(weekday - 1).format(abbreviated ? "%a" : "%A");
        }

        public static string ordinal(int position) {
            switch (position) {
                case 1: return _("first");
                case 2: return _("second");
                case 3: return _("third");
                case 4: return _("fourth");
                case 5: return _("fifth");
                case -1: return _("last");
                case -2: return _("second to last");
                default: return position.to_string();
            }
        }

        public string describe(DateTime start) {
            if (frequency == RecurrenceFrequency.NONE) return _("Does not repeat");
            string text;
            switch (frequency) {
                case RecurrenceFrequency.DAILY:
                    text = interval == 1 ? _("Every day") : _("Every %d days").printf(interval);
                    break;
                case RecurrenceFrequency.WEEKLY:
                    text = interval == 1 ? _("Every week") : _("Every %d weeks").printf(interval);
                    if (by_weekday.length > 0) {
                        string[] names = {};
                        foreach (var day in sorted_weekdays()) names += weekday_name(day.weekday, by_weekday.length > 2);
                        text += " " + _("on %s").printf(string.joinv(", ", names));
                    }
                    break;
                case RecurrenceFrequency.MONTHLY:
                    text = interval == 1 ? _("Every month") : _("Every %d months").printf(interval);
                    text += " " + describe_month_part(start);
                    break;
                default:
                    text = interval == 1 ? _("Every year") : _("Every %d years").printf(interval);
                    if (by_month.length > 0 || by_weekday.length > 0 || by_month_day.length > 0) {
                        string month = new DateTime.local(2024, by_month.length > 0 ? by_month[0] : start.get_month(), 1, 0, 0, 0).format("%B");
                        text += " " + _("in %s").printf(month) + " " + describe_month_part(start);
                    } else {
                        text += " " + _("on %s").printf(start.format("%-d %B").strip());
                    }
                    break;
            }
            if (count > 0) {
                text += ", " + ngettext("%d time", "%d times", count).printf(count);
            } else if (until != null) {
                text += ", " + _("until %s").printf(until.format("%x"));
            }
            return text;
        }

        private string describe_month_part(DateTime start) {
            if (by_weekday.length > 0) {
                string[] parts = {};
                foreach (var day in by_weekday) {
                    int position = day.position != 0 ? day.position : (by_set_pos.length > 0 ? by_set_pos[0] : 0);
                    if (position != 0) {
                        parts += _("on the %s %s").printf(ordinal(position), weekday_name(day.weekday));
                    } else {
                        parts += _("on every %s").printf(weekday_name(day.weekday));
                    }
                }
                return string.joinv(", ", parts);
            }
            if (by_month_day.length > 0) {
                string[] days = {};
                foreach (int day in by_month_day) days += day == -1 ? _("the last day") : day.to_string();
                return _("on day %s").printf(string.joinv(", ", days));
            }
            return _("on day %d").printf(start.get_day_of_month());
        }

        private RecurrenceWeekday[] sorted_weekdays() {
            var list = new Gee.ArrayList<RecurrenceWeekday?>();
            foreach (var day in by_weekday) list.add(day);
            list.sort((a, b) => a.weekday - b.weekday);
            RecurrenceWeekday[] result = {};
            foreach (var day in list) result += day;
            return result;
        }

        public Gee.List<DateTime> occurrences(DateTime dtstart, DateTime range_start, DateTime range_end,
                                              string[]? exdates = null, int64 duration = 0, int limit = 5000) {
            var result = new Gee.ArrayList<DateTime>();
            if (frequency == RecurrenceFrequency.NONE) {
                if (dtstart.compare(range_end) < 0 && dtstart.add(duration).compare(range_start) > 0) result.add(dtstart);
                return result;
            }
            var excluded = new Gee.HashSet<string>();
            if (exdates != null) {
                foreach (string ex in exdates) {
                    var parsed = new DateTime.from_iso8601(ex, new TimeZone.local());
                    if (parsed != null) excluded.add(occurrence_key(parsed));
                }
            }
            int emitted = 0;
            int periods = 0;
            var period = period_start(dtstart);
            while (periods++ < MAX_PERIODS && period.compare(range_end) < 0) {
                foreach (var candidate in expand_period(period, dtstart)) {
                    if (candidate.compare(dtstart) < 0) continue;
                    if (until != null && candidate.compare(until) > 0) return result;
                    if (count > 0 && emitted >= count) return result;
                    emitted++;
                    if (candidate.compare(range_end) >= 0) return result;
                    bool before = duration > 0 ? candidate.add(duration).compare(range_start) <= 0 : candidate.compare(range_start) < 0;
                    if (before || excluded.contains(occurrence_key(candidate))) continue;
                    result.add(candidate);
                    if (result.size >= limit) return result;
                }
                period = next_period(period);
            }
            return result;
        }

        public static string occurrence_key(DateTime value) {
            return value.to_local().format("%Y%m%dT%H%M");
        }

        private DateTime period_start(DateTime dtstart) {
            var day = new DateTime.local(dtstart.get_year(), dtstart.get_month(), dtstart.get_day_of_month(), 0, 0, 0);
            switch (frequency) {
                case RecurrenceFrequency.WEEKLY:
                    return day.add_days(-(dtstart.get_day_of_week() - 1));
                case RecurrenceFrequency.MONTHLY:
                    return new DateTime.local(dtstart.get_year(), dtstart.get_month(), 1, 0, 0, 0);
                case RecurrenceFrequency.YEARLY:
                    return new DateTime.local(dtstart.get_year(), 1, 1, 0, 0, 0);
                default:
                    return day;
            }
        }

        private DateTime next_period(DateTime period) {
            switch (frequency) {
                case RecurrenceFrequency.WEEKLY: return period.add_weeks(interval);
                case RecurrenceFrequency.MONTHLY: return period.add_months(interval);
                case RecurrenceFrequency.YEARLY: return period.add_years(interval);
                default: return period.add_days(interval);
            }
        }

        private static int days_in_month(int year, int month) {
            return GLib.Date.get_days_in_month((DateMonth) month, (DateYear) year);
        }

        private DateTime? at_time(int year, int month, int day, DateTime dtstart) {
            if (day < 1 || day > days_in_month(year, month)) return null;
            return new DateTime.local(year, month, day, dtstart.get_hour(), dtstart.get_minute(), dtstart.get_seconds());
        }

        private bool month_allowed(int month) {
            if (by_month.length == 0) return true;
            foreach (int m in by_month) if (m == month) return true;
            return false;
        }

        private bool month_day_allowed(DateTime date) {
            if (by_month_day.length == 0) return true;
            int total = days_in_month(date.get_year(), date.get_month());
            foreach (int d in by_month_day) {
                int actual = d > 0 ? d : total + d + 1;
                if (actual == date.get_day_of_month()) return true;
            }
            return false;
        }

        private bool weekday_allowed(DateTime date) {
            if (by_weekday.length == 0) return true;
            foreach (var day in by_weekday) if (day.weekday == date.get_day_of_week()) return true;
            return false;
        }

        private Gee.ArrayList<DateTime> month_candidates(int year, int month, DateTime dtstart) {
            var list = new Gee.ArrayList<DateTime>();
            int total = days_in_month(year, month);
            if (by_weekday.length > 0) {
                foreach (var wd in by_weekday) {
                    var matches = new Gee.ArrayList<int>();
                    for (int d = 1; d <= total; d++) {
                        var date = new DateTime.local(year, month, d, 0, 0, 0);
                        if (date.get_day_of_week() == wd.weekday) matches.add(d);
                    }
                    if (wd.position == 0) {
                        foreach (int d in matches) {
                            var value = at_time(year, month, d, dtstart);
                            if (value != null && month_day_allowed(value)) list.add(value);
                        }
                    } else {
                        int index = wd.position > 0 ? wd.position - 1 : matches.size + wd.position;
                        if (index >= 0 && index < matches.size) {
                            var value = at_time(year, month, matches[index], dtstart);
                            if (value != null && month_day_allowed(value)) list.add(value);
                        }
                    }
                }
            } else if (by_month_day.length > 0) {
                foreach (int d in by_month_day) {
                    int actual = d > 0 ? d : total + d + 1;
                    var value = at_time(year, month, actual, dtstart);
                    if (value != null) list.add(value);
                }
            } else {
                var value = at_time(year, month, dtstart.get_day_of_month(), dtstart);
                if (value != null) list.add(value);
            }
            return list;
        }

        private Gee.List<DateTime> expand_period(DateTime period, DateTime dtstart) {
            var list = new Gee.ArrayList<DateTime>();
            switch (frequency) {
                case RecurrenceFrequency.DAILY: {
                    var value = at_time(period.get_year(), period.get_month(), period.get_day_of_month(), dtstart);
                    if (value != null && month_allowed(value.get_month()) && month_day_allowed(value) && weekday_allowed(value)) list.add(value);
                    break;
                }
                case RecurrenceFrequency.WEEKLY: {
                    for (int i = 0; i < 7; i++) {
                        var day = period.add_days(i);
                        bool wanted = by_weekday.length == 0 ? day.get_day_of_week() == dtstart.get_day_of_week() : weekday_allowed(day);
                        if (!wanted || !month_allowed(day.get_month())) continue;
                        var value = at_time(day.get_year(), day.get_month(), day.get_day_of_month(), dtstart);
                        if (value != null) list.add(value);
                    }
                    break;
                }
                case RecurrenceFrequency.MONTHLY:
                    if (month_allowed(period.get_month())) list.add_all(month_candidates(period.get_year(), period.get_month(), dtstart));
                    break;
                case RecurrenceFrequency.YEARLY: {
                    if (by_month.length > 0) {
                        foreach (int month in by_month) list.add_all(month_candidates(period.get_year(), month, dtstart));
                    } else if (by_weekday.length > 0 || by_month_day.length > 0) {
                        list.add_all(month_candidates(period.get_year(), dtstart.get_month(), dtstart));
                    } else {
                        var value = at_time(period.get_year(), dtstart.get_month(), dtstart.get_day_of_month(), dtstart);
                        if (value != null) list.add(value);
                    }
                    break;
                }
                default:
                    break;
            }
            list.sort((a, b) => a.compare(b));
            if (by_set_pos.length == 0 || list.size == 0) return list;
            var picked = new Gee.ArrayList<DateTime>();
            foreach (int pos in by_set_pos) {
                int index = pos > 0 ? pos - 1 : list.size + pos;
                if (index >= 0 && index < list.size && !picked.contains(list[index])) picked.add(list[index]);
            }
            picked.sort((a, b) => a.compare(b));
            return picked;
        }
    }
}
