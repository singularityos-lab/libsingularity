using Singularity.Accounts;

void check(bool ok, string label) {
    if (!ok) {
        stderr.printf("FAILED: %s\n", label);
        assert_not_reached();
    }
}

void test_multistatus_prefixed() {
    string xml = """<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x1="http://apple.com/ns/ical/">
 <d:response>
  <d:href>/remote.php/dav/calendars/alice/personal/</d:href>
  <d:propstat>
   <d:prop>
    <d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>
    <d:displayname>Personal &amp; Family</d:displayname>
    <x1:calendar-color>#0082C9FF</x1:calendar-color>
    <cs:getctag>ctag-1</cs:getctag>
    <cal:supported-calendar-component-set><cal:comp name="VEVENT"/><cal:comp name="VTODO"/></cal:supported-calendar-component-set>
    <d:current-user-privilege-set><d:privilege><d:read/></d:privilege><d:privilege><d:write/></d:privilege></d:current-user-privilege-set>
   </d:prop>
   <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
  <d:propstat>
   <d:prop><d:sync-token/></d:prop>
   <d:status>HTTP/1.1 404 Not Found</d:status>
  </d:propstat>
 </d:response>
 <d:response>
  <d:href>/remote.php/dav/calendars/alice/birthdays/</d:href>
  <d:propstat>
   <d:prop>
    <d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>
    <cal:supported-calendar-component-set><cal:comp name="VEVENT"/></cal:supported-calendar-component-set>
    <d:current-user-privilege-set><d:privilege><d:read/></d:privilege></d:current-user-privilege-set>
   </d:prop>
   <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
 </d:response>
 <d:response>
  <d:href>/remote.php/dav/calendars/alice/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
</d:multistatus>""";
    try {
        var ms = Multistatus.parse(xml);
        check(ms.responses.size == 3, "three responses");
        var r = ms.responses[0];
        check(r.text(NS_DAV, "displayname") == "Personal & Family", "entity decoded");
        check(r.is_type(NS_CALDAV, "calendar"), "calendar type");
        check(r.prop(NS_DAV, "sync-token") == null, "404 property is not reported as found");
        var cals = DavClient.collections_from(ms, "https://cloud.example/remote.php/dav/calendars/alice/", false);
        check(cals.size == 2, "two calendars");
        check(cals[0].url == "https://cloud.example/remote.php/dav/calendars/alice/personal/", "absolute url");
        check(cals[0].color == "#0082C9", "colour without alpha");
        check(cals[0].ctag == "ctag-1", "ctag");
        check("VTODO" in cals[0].components && "VEVENT" in cals[0].components, "components");
        check(!cals[0].read_only, "writable");
        check(cals[1].read_only, "read only calendar");
        check(cals[1].name == "birthdays", "name falls back to segment");
        check(DavClient.collections_from(ms, "https://cloud.example/", true).size == 0, "no address books");
    } catch (Error e) {
        check(false, e.message);
    }
}

void test_multistatus_default_namespace_and_cdata() {
    string xml = """<multistatus xmlns="DAV:"><response><href>/cal/a%20b.ics</href><propstat><prop><getetag>"e1"</getetag><C:calendar-data xmlns:C="urn:ietf:params:xml:ns:caldav"><![CDATA[BEGIN:VCALENDAR
BEGIN:VEVENT
UID:a b
SUMMARY:x < y
END:VEVENT
END:VCALENDAR
]]></C:calendar-data></prop><status>HTTP/1.1 200 OK</status></propstat></response><response><href>/cal/gone.ics</href><status>HTTP/1.1 404 Not Found</status></response><sync-token>http://example.com/sync/7</sync-token></multistatus>""";
    try {
        var ms = Multistatus.parse(xml);
        check(ms.responses.size == 2, "two responses");
        check(ms.responses[0].text(NS_DAV, "getetag") == "\"e1\"", "etag");
        string data = ms.responses[0].text(NS_CALDAV, "calendar-data");
        check(data.contains("SUMMARY:x < y"), "cdata kept");
        check(Component.find_uid(data) == "a b", "uid from data");
        check(ms.responses[1].removed, "removed member");
        check(ms.sync_token == "http://example.com/sync/7", "sync token");
        check(DavRemoteCollection.key_of("https://h/cal/", ms.responses[0].href) == "/cal/a b.ics", "href key decoded");
        check(DavRemoteCollection.key_of("https://h/cal/", "https://h/cal/a%20b.ics") == "/cal/a b.ics", "absolute href key");
    } catch (Error e) {
        check(false, e.message);
    }
    bool threw = false;
    try {
        Multistatus.parse("<d:multistatus xmlns:d=\"DAV:\"><d:response>");
    } catch (Error e) {
        threw = true;
    }
    check(threw, "truncated xml throws");
}

void test_content_lines() {
    string text = "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:c1\r\nFN:Ada Lovelace\r\nN:Lovelace;Ada;;;\r\nNOTE:line one\\nline two\\, with comma\r\nitem1.EMAIL;TYPE=\"INTERNET,HOME\":ada@example.com\r\nX-LONG:" +
        string.nfill(90, 'a') + "\r\n  continued\r\nEND:VCARD\r\n";
    var c = Component.parse(text);
    check(c != null && c.name == "VCARD", "vcard parsed");
    check(c.get_text("NOTE") == "line one\nline two, with comma", "text unescaped");
    var email = c.get_line("EMAIL");
    check(email.group == "item1" && email.param("type") == "INTERNET,HOME", "group and quoted param");
    check(c.get_value("X-LONG") == string.nfill(90, 'a') + " continued", "unfolded");
    string out_text = c.to_string();
    foreach (string line in out_text.split("\r\n")) check(line.length <= 75, "folded at 75 octets");
    var again = Component.parse(out_text);
    check(again.get_text("NOTE") == c.get_text("NOTE") && again.get_value("X-LONG") == c.get_value("X-LONG"), "round trip");
    check(Component.find_uid(out_text) == "c1", "vcard uid");
    string utf = ContentLine.fold("SUMMARY:" + string.nfill(40, 'x') + "àèìòù€€€€€€€€€€€€€€€€");
    foreach (string line in utf.split("\r\n")) check(line.validate(), "utf-8 not split");
    check(ContentLine.escape_text("a,b;c\\d\ne") == "a\\,b\\;c\\\\d\\ne", "escape");
}

void test_converters_event() {
    string ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:e1\r\nDTSTART;TZID=Europe/Rome:20261005T100000\r\nDTEND;TZID=Europe/Rome:20261005T113000\r\nSUMMARY:Standup\r\nDESCRIPTION:Daily\\, short\r\nLOCATION:Room 1\r\nRRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6\r\nATTENDEE;CN=Bob;ROLE=OPT-PARTICIPANT:mailto:bob@example.com\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    try {
        var o = Converters.ical_event_to_graph(ics);
        check(o.get_string_member("subject") == "Standup", "subject");
        check(o.get_object_member("start").get_string_member("dateTime") == "2026-10-05T08:00:00.0000000", "rome to utc");
        check(o.get_object_member("start").get_string_member("timeZone") == "UTC", "utc zone");
        check(!o.get_boolean_member("isAllDay"), "not all day");
        var rec = o.get_object_member("recurrence");
        check(rec.get_object_member("pattern").get_string_member("type") == "weekly", "weekly");
        check(rec.get_object_member("pattern").get_array_member("daysOfWeek").get_length() == 2, "two days");
        check(rec.get_object_member("range").get_int_member("numberOfOccurrences") == 6, "count");
        check(o.get_array_member("attendees").get_object_element(0).get_string_member("type") == "optional", "optional attendee");
        o.set_string_member("id", "AAMk1");
        o.set_string_member("lastModifiedDateTime", "2026-09-01T10:00:00Z");
        string back = Converters.graph_event_to_ical(o);
        var ev = Component.parse(back).get_child("VEVENT");
        check(ev.get_text("UID") == "AAMk1", "graph id becomes uid");
        check(ev.get_value("DTSTART") == "20261005T080000Z", "utc dtstart");
        check(ev.get_value("RRULE") == "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6", "rrule round trip");
        check(ev.get_text("DESCRIPTION") == "Daily, short", "description");
        var events = Singularity.Calendar.Ics.parse(back).events;
        check(events.size == 1 && events[0].title == "Standup" && events[0].location == "Room 1", "calendar parser reads it");
    } catch (Error e) {
        check(false, e.message);
    }
    string allday = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:d1\r\nDTSTART;VALUE=DATE:20261224\r\nDTEND;VALUE=DATE:20261226\r\nSUMMARY:Holidays\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    try {
        var o = Converters.ical_event_to_graph(allday);
        check(o.get_boolean_member("isAllDay"), "all day");
        check(o.get_object_member("end").get_string_member("dateTime") == "2026-12-26T00:00:00.0000000", "all day end");
        o.set_string_member("id", "d1");
        var ev = Component.parse(Converters.graph_event_to_ical(o)).get_child("VEVENT");
        check(ev.get_value("DTSTART") == "20261224" && ev.get_line("DTSTART").param("VALUE") == "DATE", "date value back");
    } catch (Error e) {
        check(false, e.message);
    }
}

void test_converters_contact_and_tasks() {
    string vcf = "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:x\r\nFN:Ada Lovelace\r\nN:Lovelace;Ada;;;\r\nEMAIL;TYPE=INTERNET:ada@example.com\r\nTEL;TYPE=CELL:+39 333\r\nTEL;TYPE=WORK:+39 06\r\nORG:Analytical Engines\r\nTITLE:Countess\r\nBDAY:1815-12-10\r\nADR;TYPE=HOME:;;1 Main St;London;;N1;UK\r\nNOTE:Math\r\nEND:VCARD\r\n";
    try {
        var o = Converters.vcard_to_graph_contact(vcf);
        check(o.get_string_member("givenName") == "Ada" && o.get_string_member("surname") == "Lovelace", "names");
        check(o.get_string_member("mobilePhone") == "+39 333", "mobile");
        check(o.get_array_member("businessPhones").get_string_element(0) == "+39 06", "work phone");
        check(o.get_string_member("birthday") == "1815-12-10T00:00:00Z", "birthday");
        check(o.get_object_member("homeAddress").get_string_member("city") == "London", "address");
        o.set_string_member("id", "C1");
        var card = Component.parse(Converters.graph_contact_to_vcard(o));
        check(card.get_text("UID") == "C1" && card.get_text("FN") == "Ada Lovelace", "vcard back");
        check(card.get_value("N") == "Lovelace;Ada;;;", "n back");
        check(card.get_lines("TEL").size == 2 && card.get_text("ORG") == "Analytical Engines", "tel and org");
        check(card.get_value("BDAY") == "1815-12-10", "bday back");
    } catch (Error e) {
        check(false, e.message);
    }
    string todo = "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:t1\r\nSUMMARY:Buy milk\r\nDESCRIPTION:2 litres\r\nDUE;VALUE=DATE:20261003\r\nPRIORITY:1\r\nSTATUS:COMPLETED\r\nCOMPLETED:20261002T101010Z\r\nEND:VTODO\r\nEND:VCALENDAR\r\n";
    try {
        var g = Converters.ical_todo_to_google(todo);
        check(g.get_string_member("status") == "completed" && g.get_string_member("due") == "2026-10-03T00:00:00.000Z", "google task");
        check(g.get_string_member("notes") == "2 litres", "google notes");
        g.set_string_member("id", "G1");
        var back = Component.parse(Converters.google_task_to_ical(g)).get_child("VTODO");
        check(back.get_value("STATUS") == "COMPLETED" && back.get_value("DUE") == "20261003", "google back");
        var m = Converters.ical_todo_to_graph(todo);
        check(m.get_string_member("status") == "completed" && m.get_string_member("importance") == "high", "graph task");
        m.set_string_member("id", "M1");
        var mb = Component.parse(Converters.graph_todo_to_ical(m)).get_child("VTODO");
        check(mb.get_text("SUMMARY") == "Buy milk" && mb.get_value("PRIORITY") == "1" && mb.get_value("DUE") == "20261003", "graph back");
    } catch (Error e) {
        check(false, e.message);
    }
}

void test_calendar_compose_keeps_unknown() {
    string previous = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Other//EN\r\nBEGIN:VTIMEZONE\r\nTZID:Europe/Rome\r\nEND:VTIMEZONE\r\nBEGIN:VEVENT\r\nUID:k1\r\nSUMMARY:Old\r\nCATEGORIES:Work\r\nX-CUSTOM:keep me\r\nSEQUENCE:3\r\nDTSTART:20261001T080000Z\r\nDTEND:20261001T090000Z\r\nBEGIN:VALARM\r\nTRIGGER:-PT30M\r\nACTION:DISPLAY\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    var evt = Singularity.Calendar.Ics.parse(previous).events[0];
    evt.title = "New title";
    evt.alarms = { 10 };
    string composed = Singularity.Calendar.AccountCalendarProvider.compose(evt, previous);
    var root = Component.parse(composed);
    check(root.get_child("VTIMEZONE") != null, "timezone kept");
    var ev = root.get_child("VEVENT");
    check(ev.get_text("SUMMARY") == "New title", "summary replaced");
    check(ev.get_text("CATEGORIES") == "Work" && ev.get_text("X-CUSTOM") == "keep me", "unknown kept");
    check(ev.get_value("SEQUENCE") == "4", "sequence bumped");
    check(ev.children.size == 1 && ev.children[0].get_value("TRIGGER") == "-PT10M", "alarm replaced");
    check(root.get_line("METHOD") == null, "no METHOD for CalDAV");
    string fresh = Singularity.Calendar.AccountCalendarProvider.compose(evt, null);
    check(!fresh.contains("METHOD:"), "fresh has no METHOD");
}

void test_credentials() {
    var basic = new AccountCredentials("alice", "s3cret", "password");
    check(basic.authorization_header() == "Basic " + Base64.encode("alice:s3cret".data), "basic header");
    var token = new AccountCredentials("tester@gmail.test", "ya29.x", "oauth2");
    check(token.authorization_header() == "Bearer ya29.x", "bearer header");
    uint8[] raw = Base64.decode(token.xoauth2_response());
    var sb = new StringBuilder();
    sb.append_len((string) raw, raw.length);
    check(sb.str == "user=tester@gmail.test" + "\x01" + "auth=Bearer ya29.x" + "\x01\x01" && sb.str.split("\x01").length == 4 && sb.str.split("\x01")[1] == "auth=Bearer ya29.x", "xoauth2 string");
    check(new AccountCredentials("u", "p", "ntlm").authorization_header() == null, "ntlm has no header");
}

void test_http_helpers() {
    check(HttpClient.resolve("https://h/a/b/", "/.well-known/caldav") == "https://h/.well-known/caldav", "resolve absolute path");
    check(HttpClient.resolve("https://h/a/b/", "c/") == "https://h/a/b/c/", "resolve relative");
    check(HttpClient.origin_of("https://H:8443/x") == "https://h:8443", "origin");
    var d = WebDavDrive.parse_http_date("Sun, 27 Sep 2026 10:11:12 GMT");
    check(d != null && d.get_year() == 2026 && d.get_month() == 9 && d.get_hour() == 10, "http date");
    check(GoogleDrive.export_type_for("application/vnd.google-apps.spreadsheet") == "application/vnd.oasis.opendocument.spreadsheet", "export type");
}

class MemoryRemote : Object, RemoteCollection {
    public Gee.HashMap<string, RemoteItem> store = new Gee.HashMap<string, RemoteItem>();
    public signal void during_write();
    public bool offline = false;
    public bool reject_write = false;
    public int list_calls = 0;
    public string tag_value = "t0";
    private int counter = 0;

    public string id { get { return "mem"; } }
    public string name { get { return "Memory"; } }
    public string color { get { return ""; } }
    public bool read_only { get { return false; } }

    public Json.Object to_descriptor() {
        var o = new Json.Object();
        o.set_string_member("type", "memory");
        return o;
    }

    private void bump() {
        tag_value = "t%d".printf(++counter);
    }

    private void online() throws Error {
        if (offline) throw new AccountsError.NETWORK("offline");
    }

    public string server_put(string uid, string data) {
        string href = "/mem/" + uid + ".ics";
        store[href] = new RemoteItem(href, "e%d".printf(++counter), data);
        bump();
        return href;
    }

    public async string get_tag(Cancellable? cancellable = null) throws Error {
        online();
        return tag_value;
    }

    public async Gee.Map<string, string> list_index(Cancellable? cancellable = null) throws Error {
        online();
        list_calls++;
        var index = new Gee.HashMap<string, string>();
        foreach (var e in store.entries) index[e.key] = e.value.etag;
        return index;
    }

    public async Gee.List<RemoteItem> fetch(Gee.Collection<string> hrefs, Cancellable? cancellable = null) throws Error {
        online();
        var result = new Gee.ArrayList<RemoteItem>();
        foreach (string h in hrefs) if (store.has_key(h)) result.add(store[h]);
        return result;
    }

    public async RemoteItem create(string uid, string data, Cancellable? cancellable = null) throws Error {
        online();
        if (reject_write) throw new AccountsError.AUTH_FAILED("Write rejected");
        string href = "/mem/" + uid + ".ics";
        if (store.has_key(href)) throw new AccountsError.CONFLICT("exists");
        server_put(uid, data);
        during_write();
        return new RemoteItem(href, store[href].etag);
    }

    public async RemoteItem update(string href, string etag, string data, Cancellable? cancellable = null) throws Error {
        online();
        if (!store.has_key(href)) throw new AccountsError.NOT_FOUND("gone");
        if (store[href].etag != etag) throw new AccountsError.CONFLICT("changed");
        store[href] = new RemoteItem(href, "e%d".printf(++counter), data);
        bump();
        during_write();
        return new RemoteItem(href, store[href].etag);
    }

    public async void remove(string href, string etag, Cancellable? cancellable = null) throws Error {
        online();
        if (!store.has_key(href)) return;
        if (store[href].etag != etag) throw new AccountsError.CONFLICT("changed");
        store.unset(href);
        bump();
    }
}

string todo_text(string uid, string summary) {
    return "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:%s\r\nSUMMARY:%s\r\nEND:VTODO\r\nEND:VCALENDAR\r\n".printf(uid, summary);
}

bool run_sync(SyncedCollection c) {
    var loop = new MainLoop();
    bool ok = false;
    c.sync.begin(null, (obj, res) => {
        ok = c.sync.end(res);
        loop.quit();
    });
    loop.run();
    return ok;
}

void test_rejected_upload() {
    try {
        string dir = DirUtils.make_tmp("sync-rejected-XXXXXX");
        var remote = new MemoryRemote();
        remote.reject_write = true;
        var c = new SyncedCollection("acc", remote, ContentKind.TASKS, dir);
        c.put("rejected", todo_text("rejected", "Keep source"));
        check(!run_sync(c), "rejected upload fails sync");
        check(c.last_error == "Write rejected", "rejection is reported");
        check(c.pending_changes() == 1 && c.get_item("rejected").href == "", "rejected task remains pending");
        var reopened = new SyncedCollection("acc", remote, ContentKind.TASKS, dir);
        check(reopened.pending_changes() == 1 && reopened.get_item("rejected").state == SyncState.NEW, "pending task survives restart");
        remote.reject_write = false;
        check(run_sync(reopened), "retry succeeds");
        check(reopened.pending_changes() == 0 && reopened.get_item("rejected").href != "", "retry has an acknowledgement");
        check(remote.store.size == 1, "retry creates one task");
        c.cancel_scheduled();
        reopened.cancel_scheduled();
    } catch (Error e) {
        check(false, e.message);
    }
}

string summary_of(SyncedCollection c, string uid) {
    var item = c.get_item(uid);
    if (item == null) return "";
    var root = Component.parse(item.data);
    return root.get_child("VTODO").get_text("SUMMARY");
}

void test_sync_engine() {
    string dir = "";
    try {
        dir = DirUtils.make_tmp("sync-test-XXXXXX");
    } catch (Error e) {
        check(false, e.message);
    }
    var remote = new MemoryRemote();
    remote.server_put("a", todo_text("a", "Server A"));
    remote.server_put("b", todo_text("b", "Server B"));
    var c = new SyncedCollection("acc", remote, ContentKind.TASKS, dir);
    check(run_sync(c), "first sync");
    check(c.items().size == 2 && summary_of(c, "a") == "Server A", "pulled two items");

    int calls = remote.list_calls;
    check(run_sync(c), "idle sync");
    check(remote.list_calls == calls, "unchanged tag skips listing");

    c.put("c", todo_text("c", "Local C"));
    c.put("a", todo_text("a", "Local A"));
    c.remove("b");
    check(c.pending_changes() == 3, "three pending");
    check(run_sync(c), "push sync");
    check(c.pending_changes() == 0, "nothing pending");
    check(remote.store.has_key("/mem/c.ics") && !remote.store.has_key("/mem/b.ics"), "created and deleted on server");
    check(Component.parse(remote.store["/mem/a.ics"].data).get_child("VTODO").get_text("SUMMARY") == "Local A", "edited on server");

    remote.server_put("a", todo_text("a", "Server A2"));
    remote.server_put("d", todo_text("d", "Server D"));
    remote.store.unset("/mem/c.ics");
    check(run_sync(c), "pull changes");
    check(summary_of(c, "a") == "Server A2" && summary_of(c, "d") == "Server D", "server edits and creations");
    check(c.get_item("c") == null, "server deletion applied");

    c.put("a", todo_text("a", "Local A3"));
    remote.server_put("a", todo_text("a", "Server A3"));
    check(run_sync(c), "conflict sync");
    check(summary_of(c, "a") == "Server A3", "server wins on conflict");
    check(c.conflicts == 1, "conflict counted");

    c.put("d", todo_text("d", "Local D2"));
    remote.store.unset("/mem/d.ics");
    check(run_sync(c), "edit of deleted item");
    check(remote.store.has_key("/mem/d.ics") && summary_of(c, "d") == "Local D2", "local edit recreates it");

    remote.offline = true;
    c.put("e", todo_text("e", "Offline E"));
    check(!run_sync(c), "offline sync fails");
    check(c.offline && c.pending_changes() == 1, "change kept while offline");
    var reopened = new SyncedCollection("acc", remote, ContentKind.TASKS, dir);
    check(reopened.pending_changes() == 1 && reopened.get_item("e") != null, "offline change persisted");
    remote.offline = false;
    check(run_sync(reopened), "back online");
    check(reopened.pending_changes() == 0 && remote.store.has_key("/mem/e.ics") && !reopened.offline, "offline change uploaded");
    ulong h = remote.during_write.connect(() => reopened.put("e", todo_text("e", "Edited during upload")));
    reopened.put("e", todo_text("e", "First edit"));
    check(run_sync(reopened), "sync with an edit arriving during the upload");
    remote.disconnect(h);
    check(reopened.pending_changes() == 1 && summary_of(reopened, "e") == "Edited during upload", "edit made during the upload is kept as pending");
    check(run_sync(reopened), "next sync");
    check(Component.parse(remote.store["/mem/e.ics"].data).get_child("VTODO").get_text("SUMMARY") == "Edited during upload", "late edit reaches the server");
    reopened.forget();
    c.forget();
    DirUtils.remove(dir);
}

void test_ews_reply() {
    string xml = """<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><m:GetItemResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><m:ResponseMessages><m:GetItemResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode><m:Items><t:CalendarItem><t:MimeContent CharacterSet="UTF-8">%s</t:MimeContent><t:ItemId Id="AAMk=1" ChangeKey="DwAA"/></t:CalendarItem></m:Items></m:GetItemResponseMessage><m:GetItemResponseMessage ResponseClass="Error"><m:ResponseCode>ErrorItemNotFound</m:ResponseCode></m:GetItemResponseMessage></m:ResponseMessages></m:GetItemResponse></s:Body></s:Envelope>""".printf(Base64.encode("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n".data));
    try {
        var r = EwsReply.parse(xml);
        check(r.ids.size == 1 && r.ids[0] == "AAMk=1" && r.change_keys[0] == "DwAA", "item id and change key");
        check(r.mime.has_key("AAMk=1"), "mime attached to the id that follows it");
        check(r.first_error() == "ErrorItemNotFound", "first error code");
    } catch (Error e) {
        check(false, e.message);
    }
}

void test_graph_reminder() {
    string ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:r1\r\nDTSTART:20261001T080000Z\r\nDTEND:20261001T090000Z\r\nSUMMARY:Call\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT15M\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    try {
        var o = Converters.ical_event_to_graph(ics);
        check(o.get_boolean_member("isReminderOn") && o.get_int_member("reminderMinutesBeforeStart") == 15, "reminder to graph");
        o.set_string_member("id", "R1");
        var events = Singularity.Calendar.Ics.parse(Converters.graph_event_to_ical(o)).events;
        check(events.size == 1 && events[0].alarms.length == 1 && events[0].alarms[0] == 15, "reminder back as alarm");
    } catch (Error e) {
        check(false, e.message);
    }
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/accounts/ews-reply", test_ews_reply);
    Test.add_func("/accounts/graph-reminder", test_graph_reminder);
    Test.add_func("/accounts/multistatus-prefixed", test_multistatus_prefixed);
    Test.add_func("/accounts/multistatus-default-ns", test_multistatus_default_namespace_and_cdata);
    Test.add_func("/accounts/content-lines", test_content_lines);
    Test.add_func("/accounts/converters-event", test_converters_event);
    Test.add_func("/accounts/converters-contact-tasks", test_converters_contact_and_tasks);
    Test.add_func("/accounts/calendar-compose", test_calendar_compose_keeps_unknown);
    Test.add_func("/accounts/credentials", test_credentials);
    Test.add_func("/accounts/http-helpers", test_http_helpers);
    Test.add_func("/accounts/sync-engine", test_sync_engine);
    Test.add_func("/accounts/rejected-upload", test_rejected_upload);
    return Test.run();
}
