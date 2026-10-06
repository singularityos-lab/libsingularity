namespace Singularity.Accounts {

    /**
     * Conversions between iCalendar/vCard text and the JSON resources of
     * Microsoft Graph and Google Tasks, so apps only ever handle iCalendar
     * and vCard whatever the account.
     *
     * Only the fields the Singularity apps edit are mapped; the remote id
     * becomes the UID so an item keeps its identity across syncs.
     */
    namespace Converters {

        /** Parses an iCalendar date or date-time line into UTC. */
        public DateTime? parse_ical_time(ContentLine? line, out bool date_only) {
            date_only = false;
            if (line == null) return null;
            string text = line.value.strip();
            if (text.length < 8) return null;
            int y = int.parse(text.substring(0, 4));
            int m = int.parse(text.substring(4, 2));
            int d = int.parse(text.substring(6, 2));
            string? kind = line.param("VALUE");
            if (text.length < 15 || text[8] != 'T' || (kind != null && kind.up() == "DATE")) {
                date_only = true;
                return new DateTime.utc(y, m, d, 0, 0, 0);
            }
            int h = int.parse(text.substring(9, 2));
            int mi = int.parse(text.substring(11, 2));
            int s = int.parse(text.substring(13, 2));
            if (text.has_suffix("Z")) return new DateTime.utc(y, m, d, h, mi, s);
            TimeZone zone = new TimeZone.local();
            string? tzid = line.param("TZID");
            if (tzid != null) {
                try {
                    zone = new TimeZone.identifier(tzid.has_prefix("/") ? tzid.substring(1) : tzid);
                } catch (Error e) {
                }
            }
            var local = new DateTime(zone, y, m, d, h, mi, s);
            return local != null ? local.to_utc() : null;
        }

        /** Formats a UTC time as an iCalendar UTC date-time. */
        public string ical_utc(DateTime t) {
            return t.to_utc().format("%Y%m%dT%H%M%SZ");
        }

        /** Parses Graph dateTimeTimeZone or RFC 3339 text into UTC. */
        public DateTime? parse_remote_time(string text, string time_zone = "UTC") {
            string t = text.strip();
            if (t == "") return null;
            if (t.length == 10) t += "T00:00:00";
            int dot = t.index_of(".");
            if (dot > 0) {
                int end = dot + 1;
                while (end < t.length && t[end].isdigit()) end++;
                t = t.substring(0, dot) + t.substring(end);
            }
            bool has_zone = t.has_suffix("Z") || t.last_index_of("+") > 10 || t.last_index_of("-") > 10;
            TimeZone zone = new TimeZone.utc();
            if (!has_zone && time_zone != "" && time_zone != "UTC") {
                try {
                    zone = new TimeZone.identifier(time_zone);
                } catch (Error e) {
                }
            }
            var parsed = new DateTime.from_iso8601(t, has_zone ? null : zone);
            return parsed != null ? parsed.to_utc() : null;
        }

        /** Formats a UTC time for Graph dateTimeTimeZone values. */
        public string graph_time(DateTime t) {
            return t.to_utc().format("%Y-%m-%dT%H:%M:%S.0000000");
        }

        private string member(Json.Object o, string name) {
            if (!o.has_member(name)) return "";
            var n = o.get_member(name);
            if (n.get_node_type() != Json.NodeType.VALUE) return "";
            return n.get_value().type() == typeof(string) ? n.get_string() : "";
        }

        private Json.Object? obj(Json.Object o, string name) {
            if (!o.has_member(name)) return null;
            var n = o.get_member(name);
            return n.get_node_type() == Json.NodeType.OBJECT ? n.get_object() : null;
        }

        private bool flag(Json.Object o, string name) {
            if (!o.has_member(name)) return false;
            var n = o.get_member(name);
            return n.get_node_type() == Json.NodeType.VALUE && n.get_value().type() == typeof(bool) && n.get_boolean();
        }

        private Component calendar_wrapper() {
            var cal = new Component("VCALENDAR");
            cal.add_value("VERSION", "2.0");
            cal.add_value("PRODID", "-//Singularity//Online Accounts//EN");
            return cal;
        }

        private Component? first_of(string ics, string component) {
            var root = Component.parse(ics);
            if (root == null) return null;
            if (root.name == component) return root;
            return root.get_child(component);
        }

        private const string[] WEEKDAYS_ICAL = { "SU", "MO", "TU", "WE", "TH", "FR", "SA" };
        private const string[] WEEKDAYS_GRAPH = { "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" };

        private string graph_day(string ical_day) {
            string d = ical_day.length > 2 ? ical_day.substring(ical_day.length - 2) : ical_day;
            for (int i = 0; i < 7; i++) if (WEEKDAYS_ICAL[i] == d.up()) return WEEKDAYS_GRAPH[i];
            return "monday";
        }

        private string ical_day(string graph_day) {
            for (int i = 0; i < 7; i++) if (WEEKDAYS_GRAPH[i] == graph_day.down()) return WEEKDAYS_ICAL[i];
            return "MO";
        }

        /** Converts an RRULE to a Graph patternedRecurrence, or returns null when it cannot be expressed. */
        public Json.Object? rrule_to_graph(string rrule, DateTime start) {
            var parts = new HashTable<string, string>(str_hash, str_equal);
            foreach (string p in rrule.split(";")) {
                int eq = p.index_of("=");
                if (eq > 0) parts.insert(p.substring(0, eq).up(), p.substring(eq + 1));
            }
            string freq = parts.lookup("FREQ") ?? "";
            var pattern = new Json.Object();
            int interval = parts.contains("INTERVAL") ? int.parse(parts.lookup("INTERVAL")) : 1;
            pattern.set_int_member("interval", interval > 0 ? interval : 1);
            string? byday = parts.lookup("BYDAY");
            switch (freq) {
                case "DAILY":
                    pattern.set_string_member("type", "daily");
                    break;
                case "WEEKLY":
                    pattern.set_string_member("type", "weekly");
                    var days = new Json.Array();
                    if (byday != null) foreach (string d in byday.split(",")) days.add_string_element(graph_day(d));
                    else days.add_string_element(WEEKDAYS_GRAPH[start.get_day_of_week() % 7]);
                    pattern.set_array_member("daysOfWeek", days);
                    break;
                case "MONTHLY":
                    pattern.set_string_member("type", "absoluteMonthly");
                    pattern.set_int_member("dayOfMonth", start.get_day_of_month());
                    break;
                case "YEARLY":
                    pattern.set_string_member("type", "absoluteYearly");
                    pattern.set_int_member("dayOfMonth", start.get_day_of_month());
                    pattern.set_int_member("month", start.get_month());
                    break;
                default:
                    return null;
            }
            var range = new Json.Object();
            range.set_string_member("startDate", start.format("%Y-%m-%d"));
            if (parts.contains("COUNT")) {
                range.set_string_member("type", "numbered");
                range.set_int_member("numberOfOccurrences", int.parse(parts.lookup("COUNT")));
            } else if (parts.contains("UNTIL")) {
                var until_line = new ContentLine("UNTIL", parts.lookup("UNTIL"));
                bool date_only;
                var until = parse_ical_time(until_line, out date_only);
                range.set_string_member("type", "endDate");
                range.set_string_member("endDate", until != null ? until.format("%Y-%m-%d") : start.format("%Y-%m-%d"));
            } else {
                range.set_string_member("type", "noEnd");
            }
            var rec = new Json.Object();
            rec.set_object_member("pattern", pattern);
            rec.set_object_member("range", range);
            return rec;
        }

        /** Converts a Graph patternedRecurrence to an RRULE, or returns an empty string. */
        public string graph_to_rrule(Json.Object rec) {
            var pattern = obj(rec, "pattern");
            var range = obj(rec, "range");
            if (pattern == null) return "";
            var sb = new StringBuilder();
            string type = member(pattern, "type");
            switch (type) {
                case "daily": sb.append("FREQ=DAILY"); break;
                case "weekly": sb.append("FREQ=WEEKLY"); break;
                case "absoluteMonthly": case "relativeMonthly": sb.append("FREQ=MONTHLY"); break;
                case "absoluteYearly": case "relativeYearly": sb.append("FREQ=YEARLY"); break;
                default: return "";
            }
            int64 interval = pattern.has_member("interval") ? pattern.get_int_member("interval") : 1;
            if (interval > 1) sb.append(";INTERVAL=%lld".printf(interval));
            if (type == "weekly" && pattern.has_member("daysOfWeek")) {
                string[] days = {};
                pattern.get_array_member("daysOfWeek").foreach_element((a, i, n) => days += ical_day(n.get_string()));
                if (days.length > 0) sb.append(";BYDAY=" + string.joinv(",", days));
            }
            if (range != null) {
                string rtype = member(range, "type");
                if (rtype == "numbered" && range.has_member("numberOfOccurrences")) {
                    sb.append(";COUNT=%lld".printf(range.get_int_member("numberOfOccurrences")));
                } else if (rtype == "endDate") {
                    string end = member(range, "endDate").replace("-", "");
                    if (end.length == 8) sb.append(";UNTIL=" + end + "T235959Z");
                }
            }
            return sb.str;
        }

        /**
         * Converts the first VEVENT of an iCalendar object into a Graph event
         * body for POST or PATCH.
         */
        public Json.Object ical_event_to_graph(string ics) throws AccountsError {
            var ev = first_of(ics, "VEVENT");
            if (ev == null) throw new AccountsError.INVALID(_("The event has no VEVENT"));
            var o = new Json.Object();
            o.set_string_member("subject", ev.get_text("SUMMARY"));
            var body = new Json.Object();
            body.set_string_member("contentType", "text");
            body.set_string_member("content", ev.get_text("DESCRIPTION"));
            o.set_object_member("body", body);
            var loc = new Json.Object();
            loc.set_string_member("displayName", ev.get_text("LOCATION"));
            o.set_object_member("location", loc);
            bool date_only;
            var start = parse_ical_time(ev.get_line("DTSTART"), out date_only);
            if (start == null) throw new AccountsError.INVALID(_("The event has no start"));
            bool end_date_only;
            var end = parse_ical_time(ev.get_line("DTEND"), out end_date_only);
            if (end == null) {
                string dur = ev.get_value("DURATION");
                int64 span = dur != "" ? Singularity.Calendar.Ics.parse_duration(dur) : (date_only ? TimeSpan.DAY : TimeSpan.HOUR);
                end = start.add(span);
            }
            o.set_boolean_member("isAllDay", date_only);
            var s = new Json.Object();
            s.set_string_member("dateTime", date_only ? start.format("%Y-%m-%dT00:00:00.0000000") : graph_time(start));
            s.set_string_member("timeZone", "UTC");
            o.set_object_member("start", s);
            var e = new Json.Object();
            e.set_string_member("dateTime", date_only ? end.format("%Y-%m-%dT00:00:00.0000000") : graph_time(end));
            e.set_string_member("timeZone", "UTC");
            o.set_object_member("end", e);
            string rrule = ev.get_value("RRULE");
            if (rrule != "") {
                var rec = rrule_to_graph(rrule, start);
                if (rec != null) o.set_object_member("recurrence", rec);
            } else {
                o.set_null_member("recurrence");
            }
            var attendees = new Json.Array();
            foreach (var line in ev.get_lines("ATTENDEE")) {
                string mail = line.value;
                if (mail.down().has_prefix("mailto:")) mail = mail.substring(7);
                var a = new Json.Object();
                var addr = new Json.Object();
                addr.set_string_member("address", mail);
                addr.set_string_member("name", line.param("CN") ?? "");
                a.set_object_member("emailAddress", addr);
                a.set_string_member("type", (line.param("ROLE") ?? "") == "OPT-PARTICIPANT" ? "optional" : "required");
                attendees.add_object_element(a);
            }
            o.set_array_member("attendees", attendees);
            int reminder = -1;
            foreach (var alarm in ev.children) {
                if (alarm.name != "VALARM") continue;
                var trigger = alarm.get_line("TRIGGER");
                if (trigger == null || (trigger.param("VALUE") ?? "").up() == "DATE-TIME") continue;
                int64 offset = Singularity.Calendar.Ics.parse_duration(trigger.value);
                if (offset > 0) continue;
                int minutes = (int) (-offset / TimeSpan.MINUTE);
                if (reminder < 0 || minutes > reminder) reminder = minutes;
            }
            o.set_boolean_member("isReminderOn", reminder >= 0);
            if (reminder >= 0) o.set_int_member("reminderMinutesBeforeStart", reminder);
            return o;
        }

        /** Converts a Graph event into an iCalendar object whose UID is the Graph id. */
        public string graph_event_to_ical(Json.Object o) {
            var cal = calendar_wrapper();
            var ev = new Component("VEVENT");
            ev.set_text("UID", member(o, "id"));
            string stamp = member(o, "lastModifiedDateTime");
            var modified = parse_remote_time(stamp);
            ev.set_value("DTSTAMP", ical_utc(modified ?? new DateTime.now_utc()));
            bool all_day = flag(o, "isAllDay");
            var start_obj = obj(o, "start");
            var end_obj = obj(o, "end");
            if (start_obj != null) {
                var st = parse_remote_time(member(start_obj, "dateTime"), member(start_obj, "timeZone"));
                if (st != null) {
                    if (all_day) ev.set_value("DTSTART", st.format("%Y%m%d")).parameters["VALUE"] = "DATE";
                    else ev.set_value("DTSTART", ical_utc(st));
                }
            }
            if (end_obj != null) {
                var en = parse_remote_time(member(end_obj, "dateTime"), member(end_obj, "timeZone"));
                if (en != null) {
                    if (all_day) ev.set_value("DTEND", en.format("%Y%m%d")).parameters["VALUE"] = "DATE";
                    else ev.set_value("DTEND", ical_utc(en));
                }
            }
            ev.set_text("SUMMARY", member(o, "subject"));
            var body = obj(o, "body");
            if (body != null) {
                string content = member(body, "content");
                if (member(body, "contentType").down() == "html") content = strip_html(content);
                if (content.strip() != "") ev.set_text("DESCRIPTION", content.strip());
            }
            var loc = obj(o, "location");
            if (loc != null && member(loc, "displayName") != "") ev.set_text("LOCATION", member(loc, "displayName"));
            var rec = obj(o, "recurrence");
            if (rec != null) {
                string rrule = graph_to_rrule(rec);
                if (rrule != "") ev.set_value("RRULE", rrule);
            }
            var org = obj(o, "organizer");
            if (org != null) {
                var addr = obj(org, "emailAddress");
                if (addr != null && member(addr, "address") != "") {
                    var l = ev.add_value("ORGANIZER", "mailto:" + member(addr, "address"));
                    if (member(addr, "name") != "") l.parameters["CN"] = member(addr, "name");
                }
            }
            if (o.has_member("attendees") && o.get_member("attendees").get_node_type() == Json.NodeType.ARRAY) {
                o.get_array_member("attendees").foreach_element((a, i, n) => {
                    if (n.get_node_type() != Json.NodeType.OBJECT) return;
                    var addr = obj(n.get_object(), "emailAddress");
                    if (addr == null || member(addr, "address") == "") return;
                    var l = ev.add_value("ATTENDEE", "mailto:" + member(addr, "address"));
                    if (member(addr, "name") != "") l.parameters["CN"] = member(addr, "name");
                    l.parameters["ROLE"] = member(n.get_object(), "type") == "optional" ? "OPT-PARTICIPANT" : "REQ-PARTICIPANT";
                    var status = obj(n.get_object(), "status");
                    string response = status != null ? member(status, "response") : "";
                    l.parameters["PARTSTAT"] = response == "accepted" ? "ACCEPTED"
                        : response == "declined" ? "DECLINED"
                        : response == "tentativelyAccepted" ? "TENTATIVE" : "NEEDS-ACTION";
                });
            }
            if (flag(o, "isReminderOn") && o.has_member("reminderMinutesBeforeStart")) {
                var alarm = new Component("VALARM");
                alarm.add_value("ACTION", "DISPLAY");
                alarm.set_text("DESCRIPTION", member(o, "subject"));
                int64 minutes = o.get_int_member("reminderMinutesBeforeStart");
                alarm.add_value("TRIGGER", minutes == 0 ? "PT0M" : "-PT%lldM".printf(minutes));
                ev.children.add(alarm);
            }
            cal.children.add(ev);
            return cal.to_string();
        }

        private string strip_html(string html) {
            try {
                var tags = new Regex("<[^>]*>");
                string text = tags.replace(html.replace("<br>", "\n").replace("<br/>", "\n").replace("</p>", "\n"), -1, 0, "");
                return text.replace("&nbsp;", " ").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&amp;", "&");
            } catch (RegexError e) {
                return html;
            }
        }

        /** Converts a vCard into a Graph contact body for POST or PATCH. */
        public Json.Object vcard_to_graph_contact(string vcf) throws AccountsError {
            var card = Component.parse(vcf);
            if (card == null || card.name != "VCARD") throw new AccountsError.INVALID(_("The contact is not a vCard"));
            var o = new Json.Object();
            string[] n = card.get_value("N").split(";");
            o.set_string_member("surname", n.length > 0 ? ContentLine.unescape_text(n[0]) : "");
            o.set_string_member("givenName", n.length > 1 ? ContentLine.unescape_text(n[1]) : "");
            o.set_string_member("middleName", n.length > 2 ? ContentLine.unescape_text(n[2]) : "");
            o.set_string_member("displayName", card.get_text("FN"));
            o.set_string_member("nickName", card.get_text("NICKNAME"));
            var emails = new Json.Array();
            foreach (var l in card.get_lines("EMAIL")) {
                var e = new Json.Object();
                e.set_string_member("address", l.text);
                e.set_string_member("name", card.get_text("FN"));
                emails.add_object_element(e);
            }
            o.set_array_member("emailAddresses", emails);
            var business = new Json.Array();
            var home = new Json.Array();
            string mobile = "";
            foreach (var l in card.get_lines("TEL")) {
                string type = (l.param("TYPE") ?? "").down();
                if (type.contains("cell") && mobile == "") mobile = l.text;
                else if (type.contains("work")) business.add_string_element(l.text);
                else home.add_string_element(l.text);
            }
            o.set_array_member("businessPhones", business);
            o.set_array_member("homePhones", home);
            if (mobile != "") o.set_string_member("mobilePhone", mobile);
            else o.set_null_member("mobilePhone");
            string[] org = card.get_value("ORG").split(";");
            o.set_string_member("companyName", org.length > 0 ? ContentLine.unescape_text(org[0]) : "");
            o.set_string_member("jobTitle", card.get_text("TITLE"));
            o.set_string_member("personalNotes", card.get_text("NOTE"));
            string bday = card.get_value("BDAY").replace("-", "");
            if (bday.length >= 8) {
                o.set_string_member("birthday", "%s-%s-%sT00:00:00Z".printf(bday.substring(0, 4), bday.substring(4, 2), bday.substring(6, 2)));
            } else {
                o.set_null_member("birthday");
            }
            var adr = card.get_line("ADR");
            if (adr != null) {
                string[] p = adr.value.split(";");
                var a = new Json.Object();
                a.set_string_member("street", p.length > 2 ? ContentLine.unescape_text(p[2]) : "");
                a.set_string_member("city", p.length > 3 ? ContentLine.unescape_text(p[3]) : "");
                a.set_string_member("state", p.length > 4 ? ContentLine.unescape_text(p[4]) : "");
                a.set_string_member("postalCode", p.length > 5 ? ContentLine.unescape_text(p[5]) : "");
                a.set_string_member("countryOrRegion", p.length > 6 ? ContentLine.unescape_text(p[6]) : "");
                o.set_object_member((adr.param("TYPE") ?? "").down().contains("work") ? "businessAddress" : "homeAddress", a);
            }
            return o;
        }

        /** Converts a Graph contact into a vCard 3.0 whose UID is the Graph id. */
        public string graph_contact_to_vcard(Json.Object o) {
            var card = new Component("VCARD");
            card.add_value("VERSION", "3.0");
            card.set_text("UID", member(o, "id"));
            string given = member(o, "givenName");
            string family = member(o, "surname");
            string middle = member(o, "middleName");
            string fn = member(o, "displayName");
            if (fn == "") fn = (given + " " + family).strip();
            card.set_text("FN", fn);
            card.set_value("N", "%s;%s;%s;;".printf(ContentLine.escape_text(family), ContentLine.escape_text(given), ContentLine.escape_text(middle)));
            if (member(o, "nickName") != "") card.set_text("NICKNAME", member(o, "nickName"));
            if (o.has_member("emailAddresses") && o.get_member("emailAddresses").get_node_type() == Json.NodeType.ARRAY) {
                o.get_array_member("emailAddresses").foreach_element((a, i, n) => {
                    if (n.get_node_type() != Json.NodeType.OBJECT) return;
                    string addr = member(n.get_object(), "address");
                    if (addr != "") card.add_value("EMAIL", ContentLine.escape_text(addr)).parameters["TYPE"] = "INTERNET";
                });
            }
            if (member(o, "mobilePhone") != "") card.add_value("TEL", ContentLine.escape_text(member(o, "mobilePhone"))).parameters["TYPE"] = "CELL";
            foreach (string key in new string[] { "businessPhones", "homePhones" }) {
                if (!o.has_member(key) || o.get_member(key).get_node_type() != Json.NodeType.ARRAY) continue;
                string type = key == "businessPhones" ? "WORK" : "HOME";
                o.get_array_member(key).foreach_element((a, i, n) => {
                    if (n.get_node_type() == Json.NodeType.VALUE && n.get_string() != "") {
                        card.add_value("TEL", ContentLine.escape_text(n.get_string())).parameters["TYPE"] = type;
                    }
                });
            }
            if (member(o, "companyName") != "") card.set_value("ORG", ContentLine.escape_text(member(o, "companyName")));
            if (member(o, "jobTitle") != "") card.set_text("TITLE", member(o, "jobTitle"));
            if (member(o, "personalNotes") != "") card.set_text("NOTE", member(o, "personalNotes"));
            string bday = member(o, "birthday");
            if (bday.length >= 10) card.set_value("BDAY", bday.substring(0, 10));
            foreach (string key in new string[] { "homeAddress", "businessAddress" }) {
                var a = obj(o, key);
                if (a == null) continue;
                string street = member(a, "street");
                string city = member(a, "city");
                if (street == "" && city == "" && member(a, "postalCode") == "") continue;
                var l = card.add_value("ADR", ";;%s;%s;%s;%s;%s".printf(
                    ContentLine.escape_text(street), ContentLine.escape_text(city), ContentLine.escape_text(member(a, "state")),
                    ContentLine.escape_text(member(a, "postalCode")), ContentLine.escape_text(member(a, "countryOrRegion"))));
                l.parameters["TYPE"] = key == "homeAddress" ? "HOME" : "WORK";
            }
            return card.to_string();
        }

        /** Converts the first VTODO into a Microsoft To Do task body. */
        public Json.Object ical_todo_to_graph(string ics) throws AccountsError {
            var todo = first_of(ics, "VTODO");
            if (todo == null) throw new AccountsError.INVALID(_("The task has no VTODO"));
            var o = new Json.Object();
            o.set_string_member("title", todo.get_text("SUMMARY"));
            var body = new Json.Object();
            body.set_string_member("contentType", "text");
            body.set_string_member("content", todo.get_text("DESCRIPTION"));
            o.set_object_member("body", body);
            bool done = todo.get_value("STATUS").up() == "COMPLETED" || todo.get_line("COMPLETED") != null;
            o.set_string_member("status", done ? "completed" : "notStarted");
            int priority = int.parse(todo.get_value("PRIORITY"));
            o.set_string_member("importance", priority >= 1 && priority <= 4 ? "high" : priority >= 6 ? "low" : "normal");
            bool date_only;
            var due = parse_ical_time(todo.get_line("DUE"), out date_only);
            if (due != null) {
                var d = new Json.Object();
                d.set_string_member("dateTime", date_only ? due.format("%Y-%m-%dT00:00:00.0000000") : graph_time(due));
                d.set_string_member("timeZone", "UTC");
                o.set_object_member("dueDateTime", d);
            } else {
                o.set_null_member("dueDateTime");
            }
            if (done) {
                var completed = parse_ical_time(todo.get_line("COMPLETED"), out date_only) ?? new DateTime.now_utc();
                var c = new Json.Object();
                c.set_string_member("dateTime", graph_time(completed));
                c.set_string_member("timeZone", "UTC");
                o.set_object_member("completedDateTime", c);
            }
            return o;
        }

        /** Converts a Microsoft To Do task into a VTODO whose UID is the task id. */
        public string graph_todo_to_ical(Json.Object o) {
            var cal = calendar_wrapper();
            var todo = new Component("VTODO");
            todo.set_text("UID", member(o, "id"));
            var modified = parse_remote_time(member(o, "lastModifiedDateTime"));
            todo.set_value("DTSTAMP", ical_utc(modified ?? new DateTime.now_utc()));
            if (modified != null) todo.set_value("LAST-MODIFIED", ical_utc(modified));
            var created = parse_remote_time(member(o, "createdDateTime"));
            if (created != null) todo.set_value("CREATED", ical_utc(created));
            todo.set_text("SUMMARY", member(o, "title"));
            var body = obj(o, "body");
            if (body != null && member(body, "content").strip() != "") {
                string content = member(body, "content");
                if (member(body, "contentType").down() == "html") content = strip_html(content);
                todo.set_text("DESCRIPTION", content.strip());
            }
            string status = member(o, "status");
            todo.set_value("STATUS", status == "completed" ? "COMPLETED" : status == "inProgress" ? "IN-PROCESS" : "NEEDS-ACTION");
            string importance = member(o, "importance");
            if (importance == "high") todo.set_value("PRIORITY", "1");
            else if (importance == "low") todo.set_value("PRIORITY", "9");
            var due = obj(o, "dueDateTime");
            if (due != null) {
                var t = parse_remote_time(member(due, "dateTime"), member(due, "timeZone"));
                if (t != null) todo.set_value("DUE", t.format("%Y%m%d")).parameters["VALUE"] = "DATE";
            }
            var completed = obj(o, "completedDateTime");
            if (completed != null) {
                var t = parse_remote_time(member(completed, "dateTime"), member(completed, "timeZone"));
                if (t != null) todo.set_value("COMPLETED", ical_utc(t));
            }
            cal.children.add(todo);
            return cal.to_string();
        }

        /** Converts the first VTODO into a Google Tasks resource. */
        public Json.Object ical_todo_to_google(string ics) throws AccountsError {
            var todo = first_of(ics, "VTODO");
            if (todo == null) throw new AccountsError.INVALID(_("The task has no VTODO"));
            var o = new Json.Object();
            o.set_string_member("title", todo.get_text("SUMMARY"));
            o.set_string_member("notes", todo.get_text("DESCRIPTION"));
            bool done = todo.get_value("STATUS").up() == "COMPLETED" || todo.get_line("COMPLETED") != null;
            o.set_string_member("status", done ? "completed" : "needsAction");
            bool date_only;
            var due = parse_ical_time(todo.get_line("DUE"), out date_only);
            if (due != null) o.set_string_member("due", due.format("%Y-%m-%dT00:00:00.000Z"));
            else o.set_null_member("due");
            if (done) {
                var completed = parse_ical_time(todo.get_line("COMPLETED"), out date_only) ?? new DateTime.now_utc();
                o.set_string_member("completed", completed.format("%Y-%m-%dT%H:%M:%S.000Z"));
            } else {
                o.set_null_member("completed");
            }
            return o;
        }

        /** Converts a Google Tasks resource into a VTODO whose UID is the task id. */
        public string google_task_to_ical(Json.Object o) {
            var cal = calendar_wrapper();
            var todo = new Component("VTODO");
            todo.set_text("UID", member(o, "id"));
            var updated = parse_remote_time(member(o, "updated"));
            todo.set_value("DTSTAMP", ical_utc(updated ?? new DateTime.now_utc()));
            if (updated != null) todo.set_value("LAST-MODIFIED", ical_utc(updated));
            todo.set_text("SUMMARY", member(o, "title"));
            if (member(o, "notes") != "") todo.set_text("DESCRIPTION", member(o, "notes"));
            bool done = member(o, "status") == "completed";
            todo.set_value("STATUS", done ? "COMPLETED" : "NEEDS-ACTION");
            var due = parse_remote_time(member(o, "due"));
            if (due != null) todo.set_value("DUE", due.format("%Y%m%d")).parameters["VALUE"] = "DATE";
            var completed = parse_remote_time(member(o, "completed"));
            if (completed != null) todo.set_value("COMPLETED", ical_utc(completed));
            if (member(o, "parent") != "") todo.add_value("RELATED-TO", ContentLine.escape_text(member(o, "parent")));
            cal.children.add(todo);
            return cal.to_string();
        }
    }
}
