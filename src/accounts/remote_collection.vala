namespace Singularity.Accounts {

    /**
     * What a synchronised collection holds.
     */
    public enum ContentKind {
        /** Calendar events, as iCalendar objects with a VEVENT. */
        EVENTS,
        /** Tasks, as iCalendar objects with a VTODO. */
        TASKS,
        /** Contacts, as vCards. */
        CONTACTS;

        /** Stable identifier used in cache paths. */
        public string to_id() {
            switch (this) {
                case EVENTS: return "events";
                case TASKS: return "tasks";
                default: return "contacts";
            }
        }

        /** The account capability that provides this content. */
        public Capability capability() {
            switch (this) {
                case EVENTS: return Capability.CALENDAR;
                case TASKS: return Capability.TASKS;
                default: return Capability.CONTACTS;
            }
        }

        /** iCalendar component name, or an empty string for contacts. */
        public string component() {
            switch (this) {
                case EVENTS: return "VEVENT";
                case TASKS: return "VTODO";
                default: return "";
            }
        }

        /** Media type of the items. */
        public string media_type() {
            return this == CONTACTS ? "text/vcard; charset=utf-8" : "text/calendar; charset=utf-8";
        }
    }

    /**
     * One item on the server: its address, version tag and text.
     */
    public class RemoteItem : Object {
        /** Opaque address of the item within its collection. */
        public string href { get; set; }
        /** Version tag (ETag, changeKey); changes on every server side edit. */
        public string etag { get; set; }
        /** iCalendar or vCard text, possibly empty when not fetched. */
        public string data { get; set; }

        public RemoteItem(string href, string etag, string data = "") {
            Object(href: href, etag: etag, data: data);
        }
    }

    /**
     * A calendar, task list or address book on a server, seen as a set of
     * iCalendar or vCard items with version tags. SyncedCollection builds a
     * two-way sync on top of it.
     */
    public interface RemoteCollection : Object {
        /** Stable identifier (collection address or remote id). */
        public abstract string id { get; }
        /** Display name. */
        public abstract string name { get; }
        /** CSS colour, or an empty string. */
        public abstract string color { get; }
        /** True when the server does not accept changes. */
        public abstract bool read_only { get; }

        /** A JSON description that from_descriptor() turns back into a collection without network access. */
        public abstract Json.Object to_descriptor();

        /**
         * A tag that changes whenever anything in the collection changes
         * (CalDAV getctag), or an empty string when the server has none.
         */
        public abstract async string get_tag(Cancellable? cancellable = null) throws Error;

        /** Lists every item address with its version tag. */
        public abstract async Gee.Map<string, string> list_index(Cancellable? cancellable = null) throws Error;

        /** Downloads the given items. Unknown addresses are skipped. */
        public abstract async Gee.List<RemoteItem> fetch(Gee.Collection<string> hrefs, Cancellable? cancellable = null) throws Error;

        /**
         * Creates an item. The returned item carries the server address and
         * tag; its data is set when the server changed the item (for example
         * a new UID), otherwise it is empty.
         */
        public abstract async RemoteItem create(string uid, string data, Cancellable? cancellable = null) throws Error;

        /** Replaces an item if its tag is still `etag`; throws AccountsError.CONFLICT otherwise. */
        public abstract async RemoteItem update(string href, string etag, string data, Cancellable? cancellable = null) throws Error;

        /** Deletes an item if its tag is still `etag`; an item already gone is not an error. */
        public abstract async void remove(string href, string etag, Cancellable? cancellable = null) throws Error;
    }

    /**
     * A CalDAV calendar or task list, or a CardDAV address book.
     */
    public class DavRemoteCollection : Object, RemoteCollection {
        private DavClient dav;
        private string _url;
        private string _name;
        private string _color;
        private bool _read_only;
        private ContentKind kind;
        private Gee.HashMap<string, string> raw_hrefs = new Gee.HashMap<string, string>();

        public string id { get { return _url; } }
        public string name { get { return _name; } }
        public string color { get { return _color; } }
        public bool read_only { get { return _read_only; } }
        /** Address of the collection. */
        public string url { get { return _url; } }

        public DavRemoteCollection(DavClient dav, string url, string name, string color, bool read_only, ContentKind kind) {
            this.dav = dav;
            this._url = url.has_suffix("/") ? url : url + "/";
            this._name = name;
            this._color = color;
            this._read_only = read_only;
            this.kind = kind;
        }

        public Json.Object to_descriptor() {
            var o = new Json.Object();
            o.set_string_member("type", "dav");
            o.set_string_member("url", _url);
            o.set_string_member("name", _name);
            o.set_string_member("color", _color);
            o.set_boolean_member("read-only", _read_only);
            return o;
        }

        /** Normalises an href to a decoded absolute path used as item key. */
        public static string key_of(string base_url, string href) {
            string abs = HttpClient.resolve(base_url, href);
            try {
                var u = Uri.parse(abs, UriFlags.ENCODED);
                return Uri.unescape_string(u.get_path()) ?? u.get_path();
            } catch (UriError e) {
                return href;
            }
        }

        private string url_of(string key) {
            string[] segs = {};
            foreach (string seg in key.split("/")) segs += Uri.escape_string(seg, "@:!$&'()*+,;=", false);
            string path = string.joinv("/", segs);
            try {
                var u = Uri.parse(_url, UriFlags.ENCODED);
                return Uri.join(UriFlags.ENCODED, u.get_scheme(), null, u.get_host(), u.get_port(), path, null, null);
            } catch (UriError e) {
                return HttpClient.resolve(_url, path);
            }
        }

        public async string get_tag(Cancellable? cancellable = null) throws Error {
            const string BODY = """<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/"><d:prop><cs:getctag/><d:sync-token/></d:prop></d:propfind>""";
            var ms = yield dav.propfind(_url, "0", BODY, cancellable);
            foreach (var r in ms.responses) {
                string ctag = r.text(NS_CALSERVER, "getctag");
                if (ctag != "") return ctag;
                string token = r.text(NS_DAV, "sync-token");
                if (token != "") return token;
            }
            return "";
        }

        public async Gee.Map<string, string> list_index(Cancellable? cancellable = null) throws Error {
            var index = new Gee.HashMap<string, string>();
            Multistatus ms;
            if (kind == ContentKind.CONTACTS) {
                const string BODY = """<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:resourcetype/></d:prop></d:propfind>""";
                ms = yield dav.propfind(_url, "1", BODY, cancellable);
            } else {
                string body = """<?xml version="1.0" encoding="utf-8"?><c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/></d:prop><c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="%s"/></c:comp-filter></c:filter></c:calendar-query>""".printf(kind.component());
                ms = yield dav.report(_url, "1", body, cancellable);
            }
            string own = key_of(_url, _url);
            foreach (var r in ms.responses) {
                if (r.removed) continue;
                string key = key_of(_url, r.href);
                if (key == own || key + "/" == own || r.is_type(NS_DAV, "collection")) continue;
                index[key] = r.text(NS_DAV, "getetag");
                raw_hrefs[key] = r.href;
            }
            return index;
        }

        public async Gee.List<RemoteItem> fetch(Gee.Collection<string> hrefs, Cancellable? cancellable = null) throws Error {
            var result = new Gee.ArrayList<RemoteItem>();
            var all = new Gee.ArrayList<string>();
            all.add_all(hrefs);
            for (int start = 0; start < all.size; start += 50) {
                var sb = new StringBuilder();
                if (kind == ContentKind.CONTACTS) {
                    sb.append("""<?xml version="1.0" encoding="utf-8"?><a:addressbook-multiget xmlns:d="DAV:" xmlns:a="urn:ietf:params:xml:ns:carddav"><d:prop><d:getetag/><a:address-data/></d:prop>""");
                } else {
                    sb.append("""<?xml version="1.0" encoding="utf-8"?><c:calendar-multiget xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/><c:calendar-data/></d:prop>""");
                }
                for (int i = start; i < all.size && i < start + 50; i++) {
                    string path = raw_hrefs[all[i]];
                    if (path == null) {
                        try {
                            path = Uri.parse(url_of(all[i]), UriFlags.ENCODED).get_path();
                        } catch (UriError e) {
                            path = all[i];
                        }
                    }
                    sb.append("<d:href>").append(DavClient.xml_escape(path)).append("</d:href>");
                }
                sb.append(kind == ContentKind.CONTACTS ? "</a:addressbook-multiget>" : "</c:calendar-multiget>");
                var ms = yield dav.report(_url, "1", sb.str, cancellable);
                foreach (var r in ms.responses) {
                    if (r.removed) continue;
                    string data = kind == ContentKind.CONTACTS ? r.text(NS_CARDDAV, "address-data") : r.text(NS_CALDAV, "calendar-data");
                    if (data == "") continue;
                    result.add(new RemoteItem(key_of(_url, r.href), r.text(NS_DAV, "getetag"), data));
                }
            }
            if (result.size < all.size) {
                var have = new Gee.HashSet<string>();
                foreach (var item in result) have.add(item.href);
                foreach (string key in all) {
                    if (have.contains(key)) continue;
                    var response = yield dav.http.send("GET", url_of(key), null, null, null, cancellable);
                    if (!response.ok) continue;
                    result.add(new RemoteItem(key, response.header("ETag") ?? "", response.text()));
                }
            }
            return result;
        }

        private static string file_name(string uid, ContentKind kind) {
            var sb = new StringBuilder();
            unichar c;
            int i = 0;
            while (uid.get_next_char(ref i, out c)) {
                if (c.isalnum() || c == '-' || c == '_' || c == '.') sb.append_unichar(c);
                else sb.append_c('_');
            }
            if (sb.len == 0) sb.append(Uuid.string_random());
            return sb.str + (kind == ContentKind.CONTACTS ? ".vcf" : ".ics");
        }

        public async RemoteItem create(string uid, string data, Cancellable? cancellable = null) throws Error {
            string target = _url + file_name(uid, kind);
            string etag = yield dav.put(target, kind.media_type(), new Bytes(data.data), null, true, cancellable);
            if (etag == "") etag = yield dav.fetch_etag(target, cancellable);
            return new RemoteItem(key_of(_url, target), etag);
        }

        public async RemoteItem update(string href, string etag, string data, Cancellable? cancellable = null) throws Error {
            string target = url_of(href);
            string new_etag = yield dav.put(target, kind.media_type(), new Bytes(data.data), etag, false, cancellable);
            if (new_etag == "") new_etag = yield dav.fetch_etag(target, cancellable);
            return new RemoteItem(href, new_etag);
        }

        public async void remove(string href, string etag, Cancellable? cancellable = null) throws Error {
            yield dav.delete(url_of(href), etag, cancellable);
        }
    }
}
