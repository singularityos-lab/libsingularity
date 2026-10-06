using Singularity.Calendar;

string[] dates(Gee.List<DateTime> list) {
    string[] out_list = {};
    foreach (var d in list) out_list += d.format("%Y-%m-%d %H:%M");
    return out_list;
}

void expect(string[] got, string[] want, string label) {
    string g = string.joinv(",", got);
    string w = string.joinv(",", want);
    if (g != w) {
        stderr.printf("%s\n  got:  %s\n  want: %s\n", label, g, w);
        assert_not_reached();
    }
}

DateTime at(int y, int m, int d, int h = 9, int mi = 0) {
    return new DateTime.local(y, m, d, h, mi, 0);
}

void test_weekly_days_interval_count() {
    var rule = RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR;COUNT=6");
    var got = rule.occurrences(at(2026, 1, 5), at(2026, 1, 1), at(2026, 12, 31));
    expect(dates(got), { "2026-01-05 09:00", "2026-01-07 09:00", "2026-01-09 09:00",
        "2026-01-19 09:00", "2026-01-21 09:00", "2026-01-23 09:00" }, "weekly");
}

void test_monthly_nth_weekday() {
    var rule = RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=2TU");
    var got = rule.occurrences(at(2026, 1, 13), at(2026, 1, 1), at(2026, 4, 30));
    expect(dates(got), { "2026-01-13 09:00", "2026-02-10 09:00", "2026-03-10 09:00", "2026-04-14 09:00" }, "2TU");
}

void test_monthly_last_friday() {
    var rule = RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=-1FR;UNTIL=20260430T235959Z");
    var got = rule.occurrences(at(2026, 1, 30), at(2026, 1, 1), at(2026, 12, 31));
    expect(dates(got), { "2026-01-30 09:00", "2026-02-27 09:00", "2026-03-27 09:00", "2026-04-24 09:00" }, "-1FR");
}

void test_last_weekday_of_month() {
    var rule = RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3");
    var got = rule.occurrences(at(2026, 1, 30), at(2026, 1, 1), at(2026, 12, 31));
    expect(dates(got), { "2026-01-30 09:00", "2026-02-27 09:00", "2026-03-31 09:00" }, "bysetpos");
}

void test_monthly_31st_skips_short_months() {
    var rule = RecurrenceRule.parse("FREQ=MONTHLY;COUNT=4");
    var got = rule.occurrences(at(2026, 1, 31), at(2026, 1, 1), at(2027, 1, 1));
    expect(dates(got), { "2026-01-31 09:00", "2026-03-31 09:00", "2026-05-31 09:00", "2026-07-31 09:00" }, "31st");
}

void test_yearly_and_exdate_and_window() {
    var rule = RecurrenceRule.parse("FREQ=YEARLY");
    string[] ex = { at(2028, 2, 29).format_iso8601() };
    var got = rule.occurrences(at(2024, 2, 29), at(2025, 1, 1), at(2033, 1, 1), ex);
    expect(dates(got), { "2032-02-29 09:00" }, "leap yearly");
    var daily = RecurrenceRule.parse("FREQ=DAILY;INTERVAL=3");
    var window = daily.occurrences(at(2026, 1, 1), at(2026, 1, 10), at(2026, 1, 17), null, TimeSpan.HOUR);
    expect(dates(window), { "2026-01-10 09:00", "2026-01-13 09:00", "2026-01-16 09:00" }, "daily window");
}

void test_rrule_roundtrip() {
    var rule = RecurrenceRule.parse("FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=5");
    assert(rule.to_rrule() == "FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=5");
    assert(RecurrenceRule.parse("") == null);
    assert(RecurrenceRule.parse("FREQ=SECONDLY") == null);
}

void test_ics_roundtrip() {
    var evt = CalendarEvent();
    evt.id = "abc-1";
    evt.title = "Team sync; weekly, planning";
    evt.description = "Line one\nLine two";
    evt.location = "Room 4";
    evt.start_time = at(2026, 3, 2, 10, 30);
    evt.end_time = at(2026, 3, 2, 11, 0);
    evt.recurrence = "FREQ=WEEKLY;BYDAY=MO";
    evt.exdates = { at(2026, 3, 9, 10, 30).format_iso8601() };
    evt.organizer = "boss@example.com";
    evt.organizer_name = "The Boss";
    evt.attendees = new Gee.ArrayList<CalendarAttendee>();
    evt.attendees.add(new CalendarAttendee("ann@example.com", "Ann, Smith", "ACCEPTED"));
    evt.alarms = { 15 };
    var list = new Gee.ArrayList<CalendarEvent?>();
    list.add(evt);
    string text = Ics.serialize(list, "REQUEST");
    var doc = Ics.parse(text);
    assert(doc.method == "REQUEST");
    assert(doc.events.size == 1);
    var back = doc.events[0];
    assert(back.id == "abc-1");
    assert(back.title == evt.title);
    assert(back.description == evt.description);
    assert(back.location == "Room 4");
    assert(back.start_time.compare(evt.start_time) == 0);
    assert(back.recurrence == "FREQ=WEEKLY;BYDAY=MO");
    assert(back.exdates.length == 1);
    assert(back.organizer == "boss@example.com" && back.organizer_name == "The Boss");
    assert(back.attendees.size == 1 && back.attendees[0].name == "Ann, Smith" && back.attendees[0].status == "ACCEPTED");
    assert(back.alarms.length == 1 && back.alarms[0] == 15);
    string reply = Ics.reply(back, "ann@example.com", "DECLINED");
    assert(reply.contains("METHOD:REPLY") && reply.contains("PARTSTAT=DECLINED"));
}

void test_ics_all_day_folding_override() {
    string text = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x1\r\nDTSTART;VALUE=DATE:20260401\r\nRRULE:FREQ=DAILY;COUNT=3\r\nSUMMARY:A very long summary that is folded across\r\n  two lines\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:x1\r\nRECURRENCE-ID;VALUE=DATE:20260402\r\nDTSTART;VALUE=DATE:20260405\r\nSUMMARY:Moved\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    var doc = Ics.parse(text);
    assert(doc.events.size == 2);
    var master = doc.events[0];
    assert(master.all_day);
    assert(master.title == "A very long summary that is folded across two lines");
    assert(master.end_time.compare(master.start_time.add_days(1)) == 0);
    assert(master.exdates.length == 1);
    var rule = RecurrenceRule.parse(master.recurrence);
    var got = rule.occurrences(master.start_time, at(2026, 3, 1), at(2026, 5, 1), master.exdates, TimeSpan.DAY);
    expect(dates(got), { "2026-04-01 00:00", "2026-04-03 00:00" }, "override exdate");
    assert(doc.events[1].title == "Moved" && !doc.events[1].is_recurring());
}

void test_tzid() {
    string text = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:t\nDTSTART;TZID=America/New_York:20260615T090000\nDURATION:PT90M\nEND:VEVENT\nEND:VCALENDAR\n";
    var doc = Ics.parse(text);
    var e = doc.events[0];
    var utc = e.start_time.to_utc();
    assert(utc.get_hour() == 13);
    assert(e.end_time.difference(e.start_time) == 90 * TimeSpan.MINUTE);
}

void test_webcal_url() {
    assert(WebCalendarProvider.normalize_url(" webcal://calendar.proton.me/api/x.ics ") == "https://calendar.proton.me/api/x.ics");
    assert(WebCalendarProvider.normalize_url("webcals://a.b/c") == "https://a.b/c");
    assert(WebCalendarProvider.normalize_url("https://a.b/c") == "https://a.b/c");
}

void test_web_subscription() {
    string dir;
    try {
        dir = DirUtils.make_tmp("calendar-test-XXXXXX");
    } catch (FileError e) {
        error("tmp: %s", e.message);
    }
    Environment.set_variable("XDG_DATA_HOME", dir, true);
    string body = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:w1\r\nSUMMARY:Standup\r\nDTSTART:20260105T090000Z\r\nDTEND:20260105T091500Z\r\nRRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=3\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    var server = new Soup.Server("server-header", "test");
    int hits = 0;
    server.add_handler("/cal.ics", (srv, msg, path, query) => {
        hits++;
        msg.set_status(200, null);
        msg.set_response("text/calendar", Soup.MemoryUse.COPY, body.data);
    });
    server.add_handler("/missing.ics", (srv, msg, path, query) => {
        msg.set_status(404, null);
    });
    try {
        server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
    } catch (Error e) {
        error("listen: %s", e.message);
    }
    var uris = server.get_uris();
    uint port = (uint) uris.data.get_port();
    var loop = new MainLoop();
    var manager = CalendarManager.get_default();
    WebCalendarProvider? provider = null;
    string? failure = null;
    WebCalendarProvider.subscribe.begin(manager, "Team", "http://127.0.0.1:%u/cal.ics".printf(port), null, (obj, res) => {
        try {
            provider = WebCalendarProvider.subscribe.end(res);
        } catch (Error e) {
            failure = e.message;
        }
        loop.quit();
    });
    loop.run();
    assert(failure == null);
    assert(provider != null && provider.url == "http://127.0.0.1:%u/cal.ics".printf(port));
    assert(manager.get_provider(provider.id) != null);
    Gee.List<CalendarEvent?>? got = null;
    provider.get_events.begin(new DateTime.utc(2026, 1, 1, 0, 0, 0), new DateTime.utc(2026, 2, 1, 0, 0, 0), (obj, res) => {
        try {
            got = provider.get_events.end(res);
        } catch (Error e) {
        }
        loop.quit();
    });
    loop.run();
    assert(got != null && got.size == 3);
    assert(got[0].calendar_id == provider.id && got[0].title == "Standup");

    manager.unregister_provider(provider.id);
    WebCalendarProvider.register_all(manager);
    var restored = manager.get_provider(provider.id);
    assert(restored != null && restored != provider && restored.name == "Team");
    provider = (WebCalendarProvider) restored;

    WebCalendarProvider.subscribe.begin(manager, "Dup", "http://127.0.0.1:%u/cal.ics".printf(port), null, (obj, res) => {
        try {
            WebCalendarProvider.subscribe.end(res);
        } catch (Error e) {
            failure = e.message;
        }
        loop.quit();
    });
    loop.run();
    assert(failure != null);
    failure = null;
    WebCalendarProvider.subscribe.begin(manager, "", "http://127.0.0.1:%u/missing.ics".printf(port), null, (obj, res) => {
        try {
            WebCalendarProvider.subscribe.end(res);
        } catch (Error e) {
            failure = e.message;
        }
        loop.quit();
    });
    loop.run();
    assert(failure != null);

    provider.unsubscribe(manager);
    assert(manager.get_provider(provider.id) == null);
    WebCalendarProvider.register_all(manager);
    assert(manager.get_provider(provider.id) == null);
    server.disconnect();
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/calendar/weekly", test_weekly_days_interval_count);
    Test.add_func("/calendar/monthly-nth", test_monthly_nth_weekday);
    Test.add_func("/calendar/monthly-last", test_monthly_last_friday);
    Test.add_func("/calendar/bysetpos", test_last_weekday_of_month);
    Test.add_func("/calendar/monthly-31", test_monthly_31st_skips_short_months);
    Test.add_func("/calendar/yearly-exdate", test_yearly_and_exdate_and_window);
    Test.add_func("/calendar/rrule-roundtrip", test_rrule_roundtrip);
    Test.add_func("/calendar/ics-roundtrip", test_ics_roundtrip);
    Test.add_func("/calendar/ics-override", test_ics_all_day_folding_override);
    Test.add_func("/calendar/tzid", test_tzid);
    Test.add_func("/calendar/webcal-url", test_webcal_url);
    Test.add_func("/calendar/web-subscription", test_web_subscription);
    return Test.run();
}
