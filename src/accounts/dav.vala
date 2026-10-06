namespace Singularity.Accounts {

    /** WebDAV XML namespace. */
    public const string NS_DAV = "DAV:";
    /** CalDAV XML namespace. */
    public const string NS_CALDAV = "urn:ietf:params:xml:ns:caldav";
    /** CardDAV XML namespace. */
    public const string NS_CARDDAV = "urn:ietf:params:xml:ns:carddav";
    /** Calendar server extensions (getctag). */
    public const string NS_CALSERVER = "http://calendarserver.org/ns/";
    /** Apple iCal extensions (calendar-color). */
    public const string NS_APPLE = "http://apple.com/ns/ical/";
    /** ownCloud and Nextcloud extensions. */
    public const string NS_OWNCLOUD = "http://owncloud.org/ns";

    /**
     * One property of a WebDAV response.
     */
    public class DavProperty : Object {
        /** Namespace URI. */
        public string ns { get; construct; }
        /** Local name. */
        public string name { get; construct; }
        /** Text of the whole element, with CDATA unwrapped. */
        public string text { get; set; default = ""; }
        /** Text of every DAV:href inside the element. */
        public Gee.ArrayList<string> hrefs = new Gee.ArrayList<string>();
        /** Direct children as "{namespace}name". */
        public Gee.ArrayList<string> children = new Gee.ArrayList<string>();
        /** The "name" attribute of each direct child, for component sets. */
        public Gee.ArrayList<string> child_names = new Gee.ArrayList<string>();
        /** Every element inside the property, at any depth, as "{namespace}name". */
        public Gee.ArrayList<string> descendants = new Gee.ArrayList<string>();

        public DavProperty(string ns, string name) {
            Object(ns: ns, name: name);
        }

        /** True when a direct child with the namespace and name exists. */
        public bool has_child(string child_ns, string child_name) {
            return children.contains("{%s}%s".printf(child_ns, child_name));
        }
    }

    /**
     * One DAV:response of a multistatus body.
     */
    public class DavResponse : Object {
        /** The href as sent by the server (usually an absolute path). */
        public string href { get; set; default = ""; }
        /** Status of the response element itself, or 0 when absent. */
        public uint status { get; set; default = 0; }
        private Gee.HashMap<string, DavProperty> found = new Gee.HashMap<string, DavProperty>();
        private Gee.HashSet<string> missing = new Gee.HashSet<string>();

        internal void add(DavProperty prop, uint prop_status) {
            string key = "{%s}%s".printf(prop.ns, prop.name);
            if (prop_status >= 200 && prop_status < 300) found[key] = prop;
            else missing.add(key);
        }

        /** Returns a property the server reported with a 2xx status, or null. */
        public DavProperty? prop(string ns, string name) {
            return found["{%s}%s".printf(ns, name)];
        }

        /** Trimmed text of a property, or an empty string. */
        public string text(string ns, string name) {
            var p = prop(ns, name);
            return p != null ? p.text.strip() : "";
        }

        /** True when the resource type contains the given element. */
        public bool is_type(string ns, string name) {
            var p = prop(NS_DAV, "resourcetype");
            return p != null && p.has_child(ns, name);
        }

        /** True when the response element says the resource is gone (404). */
        public bool removed {
            get { return status == 404 || status == 410; }
        }
    }

    /**
     * Parser for WebDAV multistatus bodies (RFC 4918, RFC 6578), namespace
     * aware and independent of prefixes.
     */
    public class Multistatus : Object {
        /** Every response, in document order. */
        public Gee.ArrayList<DavResponse> responses = new Gee.ArrayList<DavResponse>();
        /** DAV:sync-token of a sync-collection report, or an empty string. */
        public string sync_token { get; set; default = ""; }

        private class Frame {
            public string ns;
            public string name;
            public HashTable<string, string> scope;
            public StringBuilder text = new StringBuilder();
        }

        private Gee.ArrayList<Frame> stack;
        private DavResponse? current;
        private Gee.ArrayList<DavProperty> pending;
        private DavProperty? prop;
        private int prop_depth;
        private uint propstat_status;

        /**
         * Parses a multistatus document.
         *
         * @param xml The response body.
         */
        public static Multistatus parse(string xml) throws AccountsError {
            var ms = new Multistatus();
            ms.run(xml);
            return ms;
        }

        private static uint parse_status(string line) {
            var parts = line.strip().split(" ");
            if (parts.length < 2) return 0;
            return (uint) uint64.parse(parts[1]);
        }

        private void run(string xml) throws AccountsError {
            stack = new Gee.ArrayList<Frame>();
            pending = new Gee.ArrayList<DavProperty>();
            prop = null;
            prop_depth = -1;
            MarkupParser parser = {
                (ctx, element, names, values) => on_start(element, names, values),
                (ctx, element) => on_end(),
                (ctx, text, len) => on_text(text, len),
                null,
                null
            };
            var ctx = new MarkupParseContext(parser, MarkupParseFlags.TREAT_CDATA_AS_TEXT | MarkupParseFlags.PREFIX_ERROR_POSITION, this, null);
            try {
                ctx.parse(xml, -1);
                ctx.end_parse();
            } catch (MarkupError e) {
                throw new AccountsError.PROTOCOL(_("The server sent malformed XML: %s").printf(e.message));
            }
        }

        private void on_start(string element, string[] names, string[] values) {
            var scope = new HashTable<string, string>(str_hash, str_equal);
            if (stack.size > 0) stack[stack.size - 1].scope.foreach((k, v) => scope.insert(k, v));
            for (int i = 0; i < names.length; i++) {
                if (names[i] == "xmlns") scope.insert("", values[i]);
                else if (names[i].has_prefix("xmlns:")) scope.insert(names[i].substring(6), values[i]);
            }
            var frame = new Frame();
            int colon = element.index_of(":");
            string prefix = colon >= 0 ? element.substring(0, colon) : "";
            frame.name = colon >= 0 ? element.substring(colon + 1) : element;
            frame.ns = scope.lookup(prefix) ?? "";
            frame.scope = scope;
            stack.add(frame);
            int depth = stack.size - 1;

            if (prop != null && depth > prop_depth) prop.descendants.add("{%s}%s".printf(frame.ns, frame.name));
            if (prop != null && depth == prop_depth + 1) {
                prop.children.add("{%s}%s".printf(frame.ns, frame.name));
                for (int i = 0; i < names.length; i++) if (names[i] == "name") prop.child_names.add(values[i]);
            }
            if (frame.ns == NS_DAV && frame.name == "response") {
                current = new DavResponse();
                return;
            }
            if (frame.ns == NS_DAV && frame.name == "propstat") {
                pending.clear();
                propstat_status = 200;
                return;
            }
            if (current != null && prop == null && depth >= 1) {
                var parent = stack[depth - 1];
                if (parent.ns == NS_DAV && parent.name == "prop") {
                    prop = new DavProperty(frame.ns, frame.name);
                    prop_depth = depth;
                }
            }
        }

        private void on_end() {
            var frame = stack.remove_at(stack.size - 1);
            int depth = stack.size;
            string text = frame.text.str;
            if (stack.size > 0 && prop != null && depth > prop_depth) stack[stack.size - 1].text.append(text);

            if (prop != null && depth == prop_depth) {
                prop.text = text;
                pending.add(prop);
                prop = null;
                prop_depth = -1;
                return;
            }
            if (prop != null && frame.ns == NS_DAV && frame.name == "href") {
                prop.hrefs.add(text.strip());
                return;
            }
            if (prop != null) return;
            if (frame.ns != NS_DAV) return;
            switch (frame.name) {
                case "href":
                    if (current != null) current.href = text.strip();
                    break;
                case "status":
                    if (current == null) break;
                    if (depth >= 1 && stack[depth - 1].name == "propstat") propstat_status = parse_status(text);
                    else current.status = parse_status(text);
                    break;
                case "propstat":
                    if (current != null) foreach (var p in pending) current.add(p, propstat_status);
                    pending.clear();
                    break;
                case "response":
                    if (current != null) responses.add(current);
                    current = null;
                    break;
                case "sync-token":
                    if (current == null) sync_token = text.strip();
                    break;
            }
        }

        private void on_text(string text, size_t len) {
            if (stack.size == 0) return;
            stack[stack.size - 1].text.append_len(text, (ssize_t) len);
        }
    }

    /**
     * A calendar, task list, address book or folder found on a DAV server.
     */
    public class DavCollectionInfo : Object {
        /** Absolute address of the collection, ending with a slash. */
        public string url { get; set; default = ""; }
        /** Display name, or the last path segment. */
        public string name { get; set; default = ""; }
        /** CSS colour, or an empty string. */
        public string color { get; set; default = ""; }
        /** calendarserver getctag, or an empty string. */
        public string ctag { get; set; default = ""; }
        /** RFC 6578 sync token, or an empty string. */
        public string sync_token { get; set; default = ""; }
        /** Supported iCalendar components, such as VEVENT and VTODO. */
        public string[] components { get; set; default = {}; }
        /** True for address books. */
        public bool is_addressbook { get; set; default = false; }
        /** True when the current user has no write privilege. */
        public bool read_only { get; set; default = false; }
    }

    /**
     * A WebDAV, CalDAV and CardDAV client bound to one account capability.
     */
    public class DavClient : Object {
        /** The HTTP client carrying the account credentials. */
        public HttpClient http { get; construct; }

        public DavClient(HttpClient http) {
            Object(http: http);
        }

        /** Escapes text for XML element content. */
        public static string xml_escape(string text) {
            return Markup.escape_text(text);
        }

        /**
         * Sends PROPFIND and parses the multistatus answer.
         *
         * @param url   Resource address.
         * @param depth "0" or "1".
         * @param body  propfind XML body.
         */
        public async Multistatus propfind(string url, string depth, string body, Cancellable? cancellable = null) throws Error {
            return yield xml_request("PROPFIND", url, depth, body, cancellable);
        }

        /** Sends REPORT and parses the multistatus answer. */
        public async Multistatus report(string url, string depth, string body, Cancellable? cancellable = null) throws Error {
            return yield xml_request("REPORT", url, depth, body, cancellable);
        }

        private async Multistatus xml_request(string method, string url, string depth, string body, Cancellable? cancellable) throws Error {
            var headers = new HashTable<string, string>(str_hash, str_equal);
            headers.insert("Depth", depth);
            var response = yield http.send(method, url, "application/xml; charset=utf-8", new Bytes(body.data), headers, cancellable);
            if (response.status != 207) HttpClient.check(response, method);
            if (response.status != 207) throw new AccountsError.PROTOCOL(_("%s did not answer with a multistatus").printf(method));
            return Multistatus.parse(response.text());
        }

        /**
         * Uploads a resource.
         *
         * @param url           Resource address.
         * @param content_type  Media type of the body.
         * @param data          Body.
         * @param if_match      ETag the server copy must still have, or null.
         * @param create_only   Send If-None-Match: * so an existing resource is not replaced.
         * @return The new ETag, or an empty string when the server did not send one.
         */
        public async string put(string url, string content_type, Bytes data, string? if_match, bool create_only, Cancellable? cancellable = null) throws Error {
            var headers = new HashTable<string, string>(str_hash, str_equal);
            if (if_match != null && if_match != "") headers.insert("If-Match", if_match);
            if (create_only) headers.insert("If-None-Match", "*");
            var response = yield http.send("PUT", url, content_type, data, headers, cancellable);
            HttpClient.check(response, "PUT");
            return response.header("ETag") ?? "";
        }

        /** Deletes a resource; a resource that is already gone is not an error. */
        public async void delete(string url, string? if_match, Cancellable? cancellable = null) throws Error {
            var headers = new HashTable<string, string>(str_hash, str_equal);
            if (if_match != null && if_match != "") headers.insert("If-Match", if_match);
            var response = yield http.send("DELETE", url, null, null, headers, cancellable);
            if (response.status == 404 || response.status == 410) return;
            HttpClient.check(response, "DELETE");
        }

        /** Downloads a resource. */
        public async HttpResponse get_resource(string url, Cancellable? cancellable = null) throws Error {
            var response = yield http.send("GET", url, null, null, null, cancellable);
            HttpClient.check(response, "GET");
            return response;
        }

        /** Creates a collection (folder). */
        public async void mkcol(string url, Cancellable? cancellable = null) throws Error {
            var response = yield http.send("MKCOL", url, null, null, null, cancellable);
            HttpClient.check(response, "MKCOL");
        }

        /** Moves or renames a resource. */
        public async void move(string url, string destination, bool overwrite, Cancellable? cancellable = null) throws Error {
            var headers = new HashTable<string, string>(str_hash, str_equal);
            headers.insert("Destination", destination);
            headers.insert("Overwrite", overwrite ? "T" : "F");
            var response = yield http.send("MOVE", url, null, null, headers, cancellable);
            HttpClient.check(response, "MOVE");
        }

        /** Reads the ETag of one resource with PROPFIND, or returns an empty string. */
        public async string fetch_etag(string url, Cancellable? cancellable = null) throws Error {
            const string BODY = "<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:getetag/></d:prop></d:propfind>";
            var ms = yield propfind(url, "0", BODY, cancellable);
            foreach (var r in ms.responses) {
                string etag = r.text(NS_DAV, "getetag");
                if (etag != "") return etag;
            }
            return "";
        }

        private const string PRINCIPAL_BODY = """<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="urn:ietf:params:xml:ns:carddav"><d:prop><d:resourcetype/><d:current-user-principal/><c:calendar-home-set/><a:addressbook-home-set/></d:prop></d:propfind>""";

        private const string COLLECTION_BODY = """<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/" xmlns:ic="http://apple.com/ns/ical/"><d:prop><d:resourcetype/><d:displayname/><ic:calendar-color/><cs:getctag/><d:sync-token/><c:supported-calendar-component-set/><d:current-user-privilege-set/></d:prop></d:propfind>""";

        /**
         * Finds the calendars (with `addressbooks` false) or address books
         * reachable from `start`: the address may be a collection, a home
         * set, a principal or a bare server, in which case the
         * /.well-known/ address is tried (RFC 6764).
         */
        public async Gee.List<DavCollectionInfo> discover(string start, bool addressbooks, Cancellable? cancellable = null) throws Error {
            string home = "";
            string principal = "";
            string tried = start;
            Multistatus? ms = null;
            try {
                ms = yield propfind(start, "0", PRINCIPAL_BODY, cancellable);
            } catch (AccountsError.NOT_FOUND e) {
                ms = null;
            } catch (AccountsError.PROTOCOL e) {
                ms = null;
            }
            if (ms == null || ms.responses.size == 0) {
                tried = HttpClient.resolve(start, addressbooks ? "/.well-known/carddav" : "/.well-known/caldav");
                ms = yield propfind(tried, "0", PRINCIPAL_BODY, cancellable);
            }
            foreach (var r in ms.responses) {
                if (r.is_type(addressbooks ? NS_CARDDAV : NS_CALDAV, addressbooks ? "addressbook" : "calendar")) {
                    var single = yield list_collections(tried, "0", addressbooks, cancellable);
                    if (single.size > 0) return single;
                }
                var hs = r.prop(addressbooks ? NS_CARDDAV : NS_CALDAV, addressbooks ? "addressbook-home-set" : "calendar-home-set");
                if (hs != null && hs.hrefs.size > 0) home = hs.hrefs[0];
                var cp = r.prop(NS_DAV, "current-user-principal");
                if (cp != null && cp.hrefs.size > 0) principal = cp.hrefs[0];
            }
            if (home == "" && principal != "") {
                var pm = yield propfind(HttpClient.resolve(tried, principal), "0", PRINCIPAL_BODY, cancellable);
                foreach (var r in pm.responses) {
                    var hs = r.prop(addressbooks ? NS_CARDDAV : NS_CALDAV, addressbooks ? "addressbook-home-set" : "calendar-home-set");
                    if (hs != null && hs.hrefs.size > 0) home = hs.hrefs[0];
                }
            }
            if (home == "") throw new AccountsError.PROTOCOL(addressbooks
                ? _("The server does not offer address books")
                : _("The server does not offer calendars"));
            return yield list_collections(HttpClient.resolve(tried, home), "1", addressbooks, cancellable);
        }

        /** Lists the calendar or address book collections at or below `url`. */
        public async Gee.List<DavCollectionInfo> list_collections(string url, string depth, bool addressbooks, Cancellable? cancellable = null) throws Error {
            var ms = yield propfind(url, depth, COLLECTION_BODY, cancellable);
            return collections_from(ms, url, addressbooks);
        }

        /** Extracts the calendars or address books of a PROPFIND answer. */
        public static Gee.List<DavCollectionInfo> collections_from(Multistatus ms, string url, bool addressbooks) {
            var result = new Gee.ArrayList<DavCollectionInfo>();
            foreach (var r in ms.responses) {
                bool is_cal = r.is_type(NS_CALDAV, "calendar");
                bool is_book = r.is_type(NS_CARDDAV, "addressbook");
                if (addressbooks ? !is_book : !is_cal) continue;
                var info = new DavCollectionInfo();
                string href = r.href.has_suffix("/") ? r.href : r.href + "/";
                info.url = HttpClient.resolve(url, href);
                info.name = r.text(NS_DAV, "displayname");
                if (info.name == "") info.name = last_segment(href);
                info.color = normalize_color(r.text(NS_APPLE, "calendar-color"));
                info.ctag = r.text(NS_CALSERVER, "getctag");
                info.sync_token = r.text(NS_DAV, "sync-token");
                info.is_addressbook = is_book;
                var comps = r.prop(NS_CALDAV, "supported-calendar-component-set");
                if (comps != null) info.components = comps.child_names.to_array();
                else if (is_cal) info.components = { "VEVENT", "VTODO" };
                var privs = r.prop(NS_DAV, "current-user-privilege-set");
                if (privs != null && privs.descendants.size > 0) {
                    info.read_only = !("{DAV:}write" in privs.descendants.to_array()
                        || "{DAV:}write-content" in privs.descendants.to_array()
                        || "{DAV:}all" in privs.descendants.to_array());
                }
                result.add(info);
            }
            return result;
        }

        /** Last non-empty path segment of an href, decoded. */
        public static string last_segment(string href) {
            var parts = href.split("/");
            for (int i = parts.length - 1; i >= 0; i--) {
                if (parts[i] != "") return Uri.unescape_string(parts[i]) ?? parts[i];
            }
            return href;
        }

        /** Turns "#RRGGBBAA" into "#RRGGBB" and returns other values unchanged. */
        public static string normalize_color(string value) {
            string v = value.strip();
            if (v.has_prefix("#") && v.length == 9) return v.substring(0, 7);
            return v;
        }
    }
}
