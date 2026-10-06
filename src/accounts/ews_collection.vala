namespace Singularity.Accounts {

    /**
     * The parts of an Exchange Web Services SOAP answer the calendar sync
     * needs: item ids with change keys, MIME content and response codes.
     */
    public class EwsReply : Object {
        /** Item ids in document order. */
        public Gee.ArrayList<string> ids = new Gee.ArrayList<string>();
        /** Change keys, parallel to `ids`. */
        public Gee.ArrayList<string> change_keys = new Gee.ArrayList<string>();
        /** Base64 MIME content per item id. */
        public Gee.HashMap<string, string> mime = new Gee.HashMap<string, string>();
        /** Every m:ResponseCode, in order. */
        public Gee.ArrayList<string> codes = new Gee.ArrayList<string>();

        private string current_id = "";
        private bool in_mime;
        private bool in_code;
        private StringBuilder text = new StringBuilder();

        private static string local(string name) {
            int colon = name.index_of(":");
            return colon >= 0 ? name.substring(colon + 1) : name;
        }

        /** Parses a SOAP answer. */
        public static EwsReply parse(string xml) throws AccountsError {
            var reply = new EwsReply();
            reply.run(xml);
            return reply;
        }

        private void on_start(string element, string[] names, string[] values) {
            string n = local(element);
            if (n == "ItemId") {
                string id = "";
                string ck = "";
                for (int i = 0; i < names.length; i++) {
                    if (names[i] == "Id") id = values[i];
                    if (names[i] == "ChangeKey") ck = values[i];
                }
                ids.add(id);
                change_keys.add(ck);
                current_id = id;
                if (mime.has_key("")) {
                    mime[id] = mime[""];
                    mime.unset("");
                }
            } else if (n == "MimeContent" || n == "ResponseCode") {
                in_mime = n == "MimeContent";
                in_code = n == "ResponseCode";
                text.truncate(0);
            } else if (n == "CalendarItem" || n == "Message" || n == "Contact" || n == "Task") {
                current_id = "";
            }
        }

        private void on_end(string element) {
            string n = local(element);
            if (n == "MimeContent") {
                in_mime = false;
                mime[current_id] = text.str.strip();
            } else if (n == "ResponseCode") {
                in_code = false;
                codes.add(text.str.strip());
            }
        }

        private void on_text(string t, size_t len) {
            if (in_mime || in_code) text.append_len(t, (ssize_t) len);
        }

        private void run(string xml) throws AccountsError {
            MarkupParser parser = {
                (ctx, element, names, values) => on_start(element, names, values),
                (ctx, element) => on_end(element),
                (ctx, t, len) => on_text(t, len),
                null,
                null
            };
            var ctx = new MarkupParseContext(parser, MarkupParseFlags.TREAT_CDATA_AS_TEXT, this, null);
            try {
                ctx.parse(xml, -1);
                ctx.end_parse();
            } catch (MarkupError e) {
                throw new AccountsError.PROTOCOL(_("The Exchange server sent malformed XML: %s").printf(e.message));
            }
        }

        /** The first response code that is not NoError, or an empty string. */
        public string first_error() {
            foreach (string c in codes) if (c != "NoError") return c;
            return "";
        }
    }

    /**
     * The calendar folder of an Exchange account, synchronised through
     * Exchange Web Services with iCalendar MIME content. Items are
     * replaced by deleting and recreating them, so an edited event gets a
     * new item id.
     */
    public class EwsRemoteCollection : Object, RemoteCollection {
        private HttpClient http;
        private string ews_url;
        private string _name;

        public string id { get { return ews_url; } }
        public string name { get { return _name; } }
        public string color { get { return ""; } }
        public bool read_only { get { return false; } }

        public EwsRemoteCollection(HttpClient http, string ews_url, string name) {
            this.http = http;
            this.ews_url = ews_url;
            this._name = name;
        }

        public Json.Object to_descriptor() {
            var o = new Json.Object();
            o.set_string_member("type", "ews");
            o.set_string_member("url", ews_url);
            o.set_string_member("name", _name);
            return o;
        }

        private const string ENVELOPE = """<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"><soap:Header><t:RequestServerVersion Version="Exchange2013"/></soap:Header><soap:Body>%s</soap:Body></soap:Envelope>""";

        private async EwsReply call(string body, Cancellable? cancellable) throws Error {
            var headers = new HashTable<string, string>(str_hash, str_equal);
            headers.insert("Accept", "text/xml");
            var response = yield http.send("POST", ews_url, "text/xml; charset=utf-8", new Bytes(ENVELOPE.printf(body).data), headers, cancellable);
            if (response.status != 200 && response.status != 500) HttpClient.check(response, "EWS");
            return EwsReply.parse(response.text());
        }

        private static string attr(string value) {
            return Markup.escape_text(value);
        }

        public async string get_tag(Cancellable? cancellable = null) throws Error {
            return "";
        }

        public async Gee.Map<string, string> list_index(Cancellable? cancellable = null) throws Error {
            var reply = yield call("""<m:FindItem Traversal="Shallow"><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape></m:ItemShape><m:ParentFolderIds><t:DistinguishedFolderId Id="calendar"/></m:ParentFolderIds></m:FindItem>""", cancellable);
            string error = reply.first_error();
            if (error != "") throw new AccountsError.PROTOCOL(_("The Exchange server refused to list the calendar: %s").printf(error));
            var index = new Gee.HashMap<string, string>();
            for (int i = 0; i < reply.ids.size; i++) index[reply.ids[i]] = reply.change_keys[i];
            return index;
        }

        public async Gee.List<RemoteItem> fetch(Gee.Collection<string> hrefs, Cancellable? cancellable = null) throws Error {
            var result = new Gee.ArrayList<RemoteItem>();
            if (hrefs.size == 0) return result;
            var sb = new StringBuilder("""<m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:IncludeMimeContent>true</t:IncludeMimeContent></m:ItemShape><m:ItemIds>""");
            foreach (string id in hrefs) sb.append("<t:ItemId Id=\"%s\"/>".printf(attr(id)));
            sb.append("</m:ItemIds></m:GetItem>");
            var reply = yield call(sb.str, cancellable);
            for (int i = 0; i < reply.ids.size; i++) {
                string id = reply.ids[i];
                if (!reply.mime.has_key(id)) continue;
                uint8[] raw = Base64.decode(reply.mime[id]);
                var text = new StringBuilder();
                text.append_len((string) raw, raw.length);
                result.add(new RemoteItem(id, reply.change_keys[i], text.str));
            }
            return result;
        }

        public async RemoteItem create(string uid, string data, Cancellable? cancellable = null) throws Error {
            string body = """<m:CreateItem SendMeetingInvitations="SendToNone"><m:SavedItemFolderId><t:DistinguishedFolderId Id="calendar"/></m:SavedItemFolderId><m:Items><t:CalendarItem><t:MimeContent CharacterSet="UTF-8">%s</t:MimeContent></t:CalendarItem></m:Items></m:CreateItem>""".printf(Base64.encode(data.data));
            var reply = yield call(body, cancellable);
            string error = reply.first_error();
            if (error != "" || reply.ids.size == 0) throw new AccountsError.PROTOCOL(_("The Exchange server refused the event: %s").printf(error));
            var list = new Gee.ArrayList<string>();
            list.add(reply.ids[0]);
            var fetched = yield fetch(list, cancellable);
            if (fetched.size > 0) return fetched[0];
            return new RemoteItem(reply.ids[0], reply.change_keys[0]);
        }

        public async RemoteItem update(string href, string etag, string data, Cancellable? cancellable = null) throws Error {
            yield remove(href, etag, cancellable);
            return yield create(Component.find_uid(data), data, cancellable);
        }

        public async void remove(string href, string etag, Cancellable? cancellable = null) throws Error {
            string ck = etag != "" ? " ChangeKey=\"%s\"".printf(attr(etag)) : "";
            var reply = yield call("""<m:DeleteItem DeleteType="MoveToDeletedItems" SendMeetingCancellations="SendToNone"><m:ItemIds><t:ItemId Id="%s"%s/></m:ItemIds></m:DeleteItem>""".printf(attr(href), ck), cancellable);
            string error = reply.first_error();
            if (error == "" || error == "ErrorItemNotFound") return;
            if (error == "ErrorIrresolvableConflict") throw new AccountsError.CONFLICT(_("The event changed on the Exchange server"));
            throw new AccountsError.PROTOCOL(_("The Exchange server refused to delete the event: %s").printf(error));
        }
    }
}
