using GLib;

namespace Singularity.Calendar {

    public class IcsDocument : Object {
        public string method { get; set; default = ""; }
        public Gee.ArrayList<CalendarEvent?> events = new Gee.ArrayList<CalendarEvent?>();
    }

    public class Ics : Object {
        private class Property {
            public string name;
            public Gee.HashMap<string, string> parameters = new Gee.HashMap<string, string>();
            public string value;
        }

        private static string[] unfold(string text) {
            string[] lines = {};
            var current = new StringBuilder();
            bool started = false;
            foreach (string raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n")) {
                if ((raw.has_prefix(" ") || raw.has_prefix("\t")) && started) {
                    current.append(raw.substring(1));
                    continue;
                }
                if (started) lines += current.str;
                current.truncate(0);
                current.append(raw);
                started = true;
            }
            if (started && current.len > 0) lines += current.str;
            return lines;
        }

        private static Property? parse_line(string line) {
            if (line.strip() == "") return null;
            int colon = -1;
            bool quoted = false;
            for (int i = 0; i < line.length; i++) {
                char c = line[i];
                if (c == '"') quoted = !quoted;
                else if (c == ':' && !quoted) {
                    colon = i;
                    break;
                }
            }
            if (colon < 0) return null;
            var prop = new Property();
            prop.value = line.substring(colon + 1);
            string head = line.substring(0, colon);
            string[] parts = split_params(head);
            prop.name = parts[0].up();
            for (int i = 1; i < parts.length; i++) {
                int eq = parts[i].index_of_char('=');
                if (eq <= 0) continue;
                string val = parts[i].substring(eq + 1);
                if (val.has_prefix("\"") && val.has_suffix("\"") && val.length >= 2) val = val.substring(1, val.length - 2);
                prop.parameters[parts[i].substring(0, eq).up()] = val;
            }
            return prop;
        }

        private static string[] split_params(string head) {
            string[] parts = {};
            var current = new StringBuilder();
            bool quoted = false;
            for (int i = 0; i < head.length; i++) {
                char c = head[i];
                if (c == '"') quoted = !quoted;
                if (c == ';' && !quoted) {
                    parts += current.str;
                    current.truncate(0);
                } else {
                    current.append_c(c);
                }
            }
            parts += current.str;
            return parts;
        }

        public static string[] with_string(string[]? values, string item) {
            string[] result = {};
            if (values != null) foreach (string value in values) result += value;
            result += item;
            return result;
        }

        public static int[] with_int(int[]? values, int item) {
            int[] result = {};
            if (values != null) foreach (int value in values) result += value;
            result += item;
            return result;
        }

        public static string unescape(string value) {
            var builder = new StringBuilder();
            for (int i = 0; i < value.length; i++) {
                char c = value[i];
                if (c == '\\' && i + 1 < value.length) {
                    char n = value[++i];
                    if (n == 'n' || n == 'N') builder.append_c('\n');
                    else builder.append_c(n);
                } else {
                    builder.append_c(c);
                }
            }
            return builder.str;
        }

        public static string escape(string value) {
            return value.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\r\n", "\\n").replace("\n", "\\n");
        }

        private static TimeZone zone_for(Property prop) {
            if (prop.parameters.has_key("TZID")) {
                string id = prop.parameters["TZID"];
                if (id.has_prefix("/")) id = id.substring(1);
                try {
                    return new TimeZone.identifier(id);
                } catch (Error e) {
                }
            }
            return new TimeZone.local();
        }

        private static DateTime? parse_date_value(string value, TimeZone zone, out bool date_only) {
            date_only = false;
            string text = value.strip();
            if (text.length < 8) return null;
            int year = int.parse(text.substring(0, 4));
            int month = int.parse(text.substring(4, 2));
            int day = int.parse(text.substring(6, 2));
            if (year <= 0 || month < 1 || month > 12 || day < 1 || day > 31) return null;
            if (text.length < 15 || text[8] != 'T') {
                date_only = true;
                return new DateTime.local(year, month, day, 0, 0, 0);
            }
            int hour = int.parse(text.substring(9, 2));
            int minute = int.parse(text.substring(11, 2));
            int second = int.parse(text.substring(13, 2));
            if (text.has_suffix("Z")) return new DateTime.utc(year, month, day, hour, minute, second).to_local();
            var result = new DateTime(zone, year, month, day, hour, minute, second);
            return result != null ? result.to_local() : null;
        }

        private static DateTime? parse_date(Property prop, out bool date_only) {
            bool value_date = prop.parameters.has_key("VALUE") && prop.parameters["VALUE"].up() == "DATE";
            var result = parse_date_value(prop.value, zone_for(prop), out date_only);
            if (value_date) date_only = true;
            return result;
        }

        public static int64 parse_duration(string value) {
            string text = value.strip().up();
            bool negative = text.has_prefix("-");
            if (negative || text.has_prefix("+")) text = text.substring(1);
            if (!text.has_prefix("P")) return 0;
            int64 total = 0;
            int64 number = 0;
            bool in_time = false;
            for (int i = 1; i < text.length; i++) {
                char c = text[i];
                if (c.isdigit()) {
                    number = number * 10 + (c - '0');
                    continue;
                }
                switch (c) {
                    case 'T': in_time = true; break;
                    case 'W': total += number * 7 * TimeSpan.DAY; break;
                    case 'D': total += number * TimeSpan.DAY; break;
                    case 'H': total += number * TimeSpan.HOUR; break;
                    case 'M': total += in_time ? number * TimeSpan.MINUTE : number * 30 * TimeSpan.DAY; break;
                    case 'S': total += number * TimeSpan.SECOND; break;
                }
                number = 0;
            }
            return negative ? -total : total;
        }

        private static string strip_mailto(string value) {
            string text = value.strip();
            if (text.down().has_prefix("mailto:")) text = text.substring(7);
            return text;
        }

        public static IcsDocument parse(string text) {
            var doc = new IcsDocument();
            CalendarEvent? current = null;
            bool in_alarm = false;
            bool date_only = false;
            int64 duration = -1;
            string? recurrence_id = null;
            var overrides = new Gee.ArrayList<string>();
            var override_uids = new Gee.ArrayList<string>();
            foreach (string line in unfold(text)) {
                var prop = parse_line(line);
                if (prop == null) continue;
                if (prop.name == "BEGIN" && prop.value.up() == "VEVENT") {
                    current = CalendarEvent();
                    current.id = Uuid.string_random();
                    current.title = "";
                    current.description = "";
                    current.location = "";
                    current.recurrence = "";
                    current.organizer = "";
                    current.organizer_name = "";
                    current.color = "";
                    current.calendar_id = "";
                    current.exdates = {};
                    current.alarms = {};
                    current.attendees = new Gee.ArrayList<CalendarAttendee>();
                    date_only = false;
                    duration = -1;
                    recurrence_id = null;
                    continue;
                }
                if (current == null) {
                    if (prop.name == "METHOD") doc.method = prop.value.strip().up();
                    continue;
                }
                if (prop.name == "BEGIN" && prop.value.up() == "VALARM") {
                    in_alarm = true;
                    continue;
                }
                if (prop.name == "END" && prop.value.up() == "VALARM") {
                    in_alarm = false;
                    continue;
                }
                if (in_alarm) {
                    if (prop.name == "TRIGGER" && !(prop.parameters.has_key("VALUE") && prop.parameters["VALUE"].up() == "DATE-TIME")) {
                        int64 offset = parse_duration(prop.value);
                        if (offset <= 0) current.alarms = with_int(current.alarms, (int) (-offset / TimeSpan.MINUTE));
                    }
                    continue;
                }
                if (prop.name == "END" && prop.value.up() == "VEVENT") {
                    if (current.start_time != null) {
                        current.all_day = date_only;
                        if (current.end_time == null) {
                            if (duration >= 0) current.end_time = current.start_time.add(duration);
                            else current.end_time = date_only ? current.start_time.add_days(1) : current.start_time.add_hours(1);
                        }
                        if (current.end_time.compare(current.start_time) < 0) current.end_time = current.start_time.add_hours(1);
                        if (recurrence_id != null) {
                            current.recurrence = "";
                            overrides.add(recurrence_id);
                            override_uids.add(current.id);
                            current.id = current.id + "-" + recurrence_id;
                        }
                        doc.events.add(current);
                    }
                    current = null;
                    continue;
                }
                switch (prop.name) {
                    case "UID":
                        current.id = prop.value.strip();
                        break;
                    case "SUMMARY":
                        current.title = unescape(prop.value);
                        break;
                    case "DESCRIPTION":
                        current.description = unescape(prop.value);
                        break;
                    case "LOCATION":
                        current.location = unescape(prop.value);
                        break;
                    case "DTSTART":
                        current.start_time = parse_date(prop, out date_only);
                        break;
                    case "DTEND": {
                        bool end_date_only;
                        current.end_time = parse_date(prop, out end_date_only);
                        break;
                    }
                    case "DURATION":
                        duration = parse_duration(prop.value);
                        break;
                    case "RRULE":
                        current.recurrence = prop.value.strip();
                        break;
                    case "EXDATE":
                        foreach (string item in prop.value.split(",")) {
                            bool ex_date_only;
                            var ex = parse_date_value(item, zone_for(prop), out ex_date_only);
                            if (ex != null) current.exdates = with_string(current.exdates, ex.format_iso8601());
                        }
                        break;
                    case "RECURRENCE-ID": {
                        bool rid_date_only;
                        var rid = parse_date(prop, out rid_date_only);
                        if (rid != null) recurrence_id = rid.format_iso8601();
                        break;
                    }
                    case "ORGANIZER":
                        current.organizer = strip_mailto(prop.value);
                        current.organizer_name = prop.parameters.has_key("CN") ? prop.parameters["CN"] : "";
                        break;
                    case "ATTENDEE": {
                        var attendee = new CalendarAttendee(strip_mailto(prop.value),
                            prop.parameters.has_key("CN") ? prop.parameters["CN"] : "",
                            prop.parameters.has_key("PARTSTAT") ? prop.parameters["PARTSTAT"].up() : "NEEDS-ACTION");
                        if (prop.parameters.has_key("ROLE")) attendee.role = prop.parameters["ROLE"].up();
                        current.attendees.add(attendee);
                        break;
                    }
                    case "COLOR":
                        current.color = prop.value.strip();
                        break;
                }
            }
            for (int i = 0; i < overrides.size; i++) {
                for (int j = 0; j < doc.events.size; j++) {
                    CalendarEvent evt = doc.events[j];
                    if (evt.id == override_uids[i] && evt.is_recurring()) {
                        evt.exdates = with_string(evt.exdates, overrides[i]);
                        doc.events[j] = evt;
                    }
                }
            }
            return doc;
        }

        private static void fold(StringBuilder builder, string line) {
            int limit = 75;
            int count = 0;
            unichar c;
            int index = 0;
            var chunk = new StringBuilder();
            while (line.get_next_char(ref index, out c)) {
                int size = c.to_string().length;
                if (count + size > limit) {
                    builder.append(chunk.str);
                    builder.append("\r\n ");
                    chunk.truncate(0);
                    count = 1;
                    limit = 75;
                }
                chunk.append_unichar(c);
                count += size;
            }
            builder.append(chunk.str);
            builder.append("\r\n");
        }

        private static string utc_stamp(DateTime value) {
            return value.to_utc().format("%Y%m%dT%H%M%SZ");
        }

        private static string quote_param(string value) {
            if (value.contains(":") || value.contains(";") || value.contains(",")) return "\"" + value.replace("\"", "'") + "\"";
            return value;
        }

        public static string serialize(Gee.List<CalendarEvent?> events, string method = "PUBLISH") {
            var builder = new StringBuilder();
            fold(builder, "BEGIN:VCALENDAR");
            fold(builder, "VERSION:2.0");
            fold(builder, "PRODID:-//Singularity//Calendar//EN");
            fold(builder, "CALSCALE:GREGORIAN");
            if (method != "") fold(builder, "METHOD:" + method);
            foreach (var evt in events) {
                append_event(builder, evt, method);
            }
            fold(builder, "END:VCALENDAR");
            return builder.str;
        }

        private static void append_event(StringBuilder builder, CalendarEvent evt, string method) {
            fold(builder, "BEGIN:VEVENT");
            fold(builder, "UID:" + evt.id);
            fold(builder, "DTSTAMP:" + utc_stamp(new DateTime.now_utc()));
            if (evt.all_day) {
                fold(builder, "DTSTART;VALUE=DATE:" + evt.start_time.format("%Y%m%d"));
                var end = evt.end_time.compare(evt.start_time) > 0 ? evt.end_time : evt.start_time.add_days(1);
                fold(builder, "DTEND;VALUE=DATE:" + end.format("%Y%m%d"));
            } else {
                fold(builder, "DTSTART:" + utc_stamp(evt.start_time));
                fold(builder, "DTEND:" + utc_stamp(evt.end_time));
            }
            fold(builder, "SUMMARY:" + escape(evt.title ?? ""));
            if (evt.description != null && evt.description != "") fold(builder, "DESCRIPTION:" + escape(evt.description));
            if (evt.location != null && evt.location != "") fold(builder, "LOCATION:" + escape(evt.location));
            if (evt.is_recurring()) fold(builder, "RRULE:" + evt.recurrence);
            if (evt.exdates != null) {
                foreach (string ex in evt.exdates) {
                    var parsed = new DateTime.from_iso8601(ex, new TimeZone.local());
                    if (parsed == null) continue;
                    if (evt.all_day) fold(builder, "EXDATE;VALUE=DATE:" + parsed.format("%Y%m%d"));
                    else fold(builder, "EXDATE:" + utc_stamp(parsed));
                }
            }
            if (evt.organizer != null && evt.organizer != "") {
                string cn = evt.organizer_name != null && evt.organizer_name != "" ? ";CN=" + quote_param(evt.organizer_name) : "";
                fold(builder, "ORGANIZER%s:mailto:%s".printf(cn, evt.organizer));
            }
            if (evt.attendees != null) {
                foreach (var attendee in evt.attendees) {
                    string cn = attendee.name != "" ? ";CN=" + quote_param(attendee.name) : "";
                    string rsvp = method == "REQUEST" ? ";RSVP=TRUE" : "";
                    fold(builder, "ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=%s;PARTSTAT=%s%s%s:mailto:%s".printf(
                        attendee.role, attendee.status, rsvp, cn, attendee.email));
                }
            }
            if (method == "CANCEL") fold(builder, "STATUS:CANCELLED");
            if (method == "REQUEST" || method == "CANCEL") fold(builder, "SEQUENCE:%lld".printf(new DateTime.now_utc().to_unix() / 60));
            if (evt.alarms != null) {
                foreach (int minutes in evt.alarms) {
                    fold(builder, "BEGIN:VALARM");
                    fold(builder, "ACTION:DISPLAY");
                    fold(builder, "DESCRIPTION:" + escape(evt.title ?? ""));
                    fold(builder, minutes == 0 ? "TRIGGER:PT0M" : "TRIGGER:-PT%dM".printf(minutes));
                    fold(builder, "END:VALARM");
                }
            }
            fold(builder, "END:VEVENT");
        }

        public static string reply(CalendarEvent evt, string attendee_email, string status) {
            CalendarEvent copy = evt;
            copy.attendees = new Gee.ArrayList<CalendarAttendee>();
            if (evt.attendees != null) {
                foreach (var attendee in evt.attendees) {
                    if (attendee.email.down() == attendee_email.down()) {
                        var answer = attendee.copy();
                        answer.status = status;
                        copy.attendees.add(answer);
                    }
                }
            }
            if (copy.attendees.size == 0) copy.attendees.add(new CalendarAttendee(attendee_email, "", status));
            copy.alarms = {};
            var list = new Gee.ArrayList<CalendarEvent?>();
            list.add(copy);
            return serialize(list, "REPLY");
        }
    }
}
