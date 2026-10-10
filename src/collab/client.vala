namespace Singularity.Collab {

    public class Person : Object {
        public string id { get; construct; }
        public string name { get; construct; }
        public string icon_name { get; construct; }
        public string provider_name { get; construct; }
        public bool can_join { get; construct; }

        public Person(string id, string name, string icon_name, string provider_name, bool can_join) {
            Object(id: id, name: name, icon_name: icon_name, provider_name: provider_name, can_join: can_join);
        }
    }

    public class SessionInfo : Object {
        public string id { get; construct; }
        public string kind { get; construct; }
        public string title { get; construct; }
        public bool hosting { get; construct; }
        public string host_name { get; construct; }
        public string[] people { get; construct; }
        public string[] people_ids { get; construct; }

        public SessionInfo(string id, string kind, string title, bool hosting, string host_name, string[] people, string[] people_ids) {
            Object(id: id, kind: kind, title: title, hosting: hosting, host_name: host_name, people: people, people_ids: people_ids);
        }
    }

    public delegate void PersonPicked(Person person);

    public class Client : Object {
        public const string BUS_NAME = "dev.sinty.Nearby";
        public const string OBJECT_PATH = "/dev/sinty/Nearby/Collab";
        public const string INTERFACE = "dev.sinty.Collab1";

        private static Client? instance = null;
        private DBusConnection? bus = null;
        private Gee.HashMap<string, Shared> shared = new Gee.HashMap<string, Shared>();
        private Gee.ArrayList<Person> cached = new Gee.ArrayList<Person>();

        public signal void people_changed();
        public signal void sessions_changed();
        public signal void joined(string session, string name);
        public signal void left(string session, string name);
        public signal void ended(string session);
        public signal void offered(string offer, string name, string kind, string title, bool invite);
        public signal void offer_closed(string offer);
        public signal void raw(string session, string author, string data);

        public static Client get_default() {
            if (instance == null) instance = new Client();
            return instance;
        }

        private Client() {
            try {
                bus = Bus.get_sync(BusType.SESSION);
            } catch (Error e) {
                warning("collab: %s", e.message);
                return;
            }
            bus.signal_subscribe(BUS_NAME, INTERFACE, null, OBJECT_PATH, null, DBusSignalFlags.NONE, on_signal);
            refresh_people.begin();
        }

        public static string kind_label(string kind) {
            switch (kind) {
                case "Note": return _("Note");
                case "Task": return _("Task");
                case "TaskList": return _("Task List");
                case "Event": return _("Event");
                case "Color": return _("Color");
                case "Sheet": return _("Spreadsheet");
                case "Document": return _("Document");
                case "Presentation": return _("Presentation");
                case "Drawing": return _("Drawing");
                case "Database": return _("Database");
                case "Formula": return _("Formula");
                case "Publication": return _("Publication");
                default: return kind;
            }
        }

        public static bool installed() {
            return Capabilities.available(Contracts.COLLAB);
        }

        public bool available {
            get { return installed() && cached.size > 0; }
        }

        public Gee.List<Person> people {
            owned get { return cached.read_only_view; }
        }

        private void on_signal(DBusConnection c, string? sender, string path, string iface, string name, Variant args) {
            switch (name) {
                case "PeopleChanged":
                    refresh_people.begin();
                    break;
                case "SessionsChanged":
                    sessions_changed();
                    break;
                case "Received":
                    string sid, author, data;
                    args.get("(sss)", out sid, out author, out data);
                    var s = shared[sid];
                    if (s != null) s.receive(author, data);
                    raw(sid, author, data);
                    break;
                case "Joined":
                    string sid, person, who;
                    args.get("(sss)", out sid, out person, out who);
                    joined(sid, who);
                    break;
                case "Left":
                    string sid, person, who;
                    args.get("(sss)", out sid, out person, out who);
                    left(sid, who);
                    break;
                case "Ended":
                    string sid;
                    args.get("(s)", out sid);
                    var s = shared[sid];
                    if (s != null) s.ended();
                    ended(sid);
                    break;
                case "Offered":
                    string offer, who, kind, title;
                    bool invite;
                    args.get("(ssssb)", out offer, out who, out kind, out title, out invite);
                    offered(offer, who, kind, title, invite);
                    break;
                case "OfferClosed":
                    string offer;
                    args.get("(s)", out offer);
                    offer_closed(offer);
                    break;
                default:
                    break;
            }
        }

        private async Variant? invoke(string method, Variant? args, string reply = "()") throws Error {
            if (bus == null) throw new IOError.NOT_CONNECTED("no session bus");
            return yield bus.call(BUS_NAME, OBJECT_PATH, INTERFACE, method, args, new VariantType(reply),
                DBusCallFlags.NONE, 15000, null);
        }

        public async void refresh_people() {
            var fresh = new Gee.ArrayList<Person>();
            if (installed()) {
                try {
                    var r = yield invoke("ListPeople", null, "(aa{sv})");
                    foreach (var entry in r.get_child_value(0)) {
                        var d = new VariantDict(entry);
                        string id = "", name = "", icon = "computer-symbolic", provider = "";
                        bool sessions = false;
                        d.lookup("id", "s", out id);
                        d.lookup("name", "s", out name);
                        d.lookup("icon", "s", out icon);
                        d.lookup("provider-name", "s", out provider);
                        d.lookup("sessions", "b", out sessions);
                        fresh.add(new Person(id, name, icon, provider, sessions));
                    }
                } catch (Error e) {
                    debug("collab: %s", e.message);
                }
            }
            cached = fresh;
            people_changed();
        }

        public async void send(string person, string kind, string title, string payload, string text) throws Error {
            yield invoke("Send", new Variant("(sssss)", person, kind, title, payload, text));
        }

        public async string share(string person, string kind, string title, string snapshot, bool read_only = false) throws Error {
            var r = yield invoke("Share", new Variant("(sssss)", person, kind, title, snapshot, read_only ? "view" : "edit"), "(s)");
            return r.get_child_value(0).get_string();
        }

        public async void invite(string session, string person) throws Error {
            yield invoke("Invite", new Variant("(ss)", session, person));
        }

        public async void leave(string session) throws Error {
            yield invoke("Leave", new Variant("(s)", session));
        }

        public async void accept(string offer) throws Error {
            yield invoke("Accept", new Variant("(s)", offer));
        }

        public async void decline(string offer) throws Error {
            yield invoke("Decline", new Variant("(s)", offer));
        }

        public async void remove_person(string session, string person) throws Error {
            yield invoke("RemovePerson", new Variant("(ss)", session, person));
        }

        public async Gee.List<SessionInfo> sessions() {
            var list = new Gee.ArrayList<SessionInfo>();
            if (!installed()) return list;
            try {
                var r = yield invoke("ListSessions", null, "(aa{sv})");
                foreach (var entry in r.get_child_value(0)) {
                    var d = new VariantDict(entry);
                    string id = "", kind = "", title = "", host = "";
                    bool hosting = false;
                    string[] people = {}, ids = {};
                    d.lookup("id", "s", out id);
                    d.lookup("kind", "s", out kind);
                    d.lookup("title", "s", out title);
                    d.lookup("hosting", "b", out hosting);
                    d.lookup("host-name", "s", out host);
                    d.lookup("people", "^as", out people);
                    d.lookup("people-ids", "^as", out ids);
                    list.add(new SessionInfo(id, kind, title, hosting, host, people, ids));
                }
            } catch (Error e) {
                debug("collab: %s", e.message);
            }
            return list;
        }

        public async bool get_enabled() {
            if (bus == null || !installed()) return false;
            try {
                var r = yield bus.call(BUS_NAME, OBJECT_PATH, "org.freedesktop.DBus.Properties", "Get",
                    new Variant("(ss)", INTERFACE, "Enabled"), new VariantType("(v)"), DBusCallFlags.NONE, 5000, null);
                return r.get_child_value(0).get_variant().get_boolean();
            } catch (Error e) {
                return false;
            }
        }

        public async void set_enabled(bool on) {
            if (bus == null) return;
            try {
                yield bus.call(BUS_NAME, OBJECT_PATH, "org.freedesktop.DBus.Properties", "Set",
                    new Variant("(ssv)", INTERFACE, "Enabled", new Variant.boolean(on)), null, DBusCallFlags.NONE, 5000, null);
            } catch (Error e) {
                warning("collab: %s", e.message);
            }
            yield refresh_people();
        }

        public async HashTable<string, Variant>[] records(string method) {
            HashTable<string, Variant>[] out = {};
            if (!installed()) return out;
            try {
                var r = yield invoke(method, null, "(aa{sv})");
                foreach (var entry in r.get_child_value(0)) {
                    var table = new HashTable<string, Variant>(str_hash, str_equal);
                    var it = entry.iterator();
                    string key;
                    Variant val;
                    while (it.next("{sv}", out key, out val)) table[key] = val;
                    out += table;
                }
            } catch (Error e) {
                debug("collab: %s", e.message);
            }
            return out;
        }

        public async void update_snapshot(string session, string snapshot) {
            try {
                yield invoke("UpdateSnapshot", new Variant("(ss)", session, snapshot));
            } catch (Error e) {
                debug("collab: %s", e.message);
            }
        }

        public void send_raw(string session, string data) {
            post(session, data);
        }

        internal void post(string session, string data) {
            invoke.begin("Post", new Variant("(ss)", session, data), "()", (obj, res) => {
                try {
                    invoke.end(res);
                } catch (Error e) {
                    warning("collab: %s", e.message);
                }
            });
        }

        internal void attach(Shared s) {
            shared[s.session] = s;
        }

        internal void detach(Shared s) {
            if (shared[s.session] == s) shared.unset(s.session);
        }

        public static void pick(Gtk.Widget anchor, bool sessions_only, owned PersonPicked picked) {
            var client = get_default();
            var cb = (owned) picked;
            client.refresh_people.begin((obj, res) => {
                client.refresh_people.end(res);
                Timeout.add(150, () => {
                    show_people(anchor, sessions_only, (owned) cb);
                    return Source.REMOVE;
                });
            });
        }

        private static void show_people(Gtk.Widget anchor, bool sessions_only, owned PersonPicked cb) {
            var client = get_default();
            {
                var menu = new Widgets.ContextMenu(anchor);
                int shown = 0;
                foreach (var p in client.people) {
                    if (sessions_only && !p.can_join) continue;
                    var person = p;
                    menu.add_item(p.name, p.icon_name, () => cb(person));
                    shown++;
                }
                if (shown == 0) menu.add_item(_("Nobody Nearby"), "network-offline-symbolic", () => {});
                menu.closed.connect(() => {
                    Idle.add(() => {
                        menu.unparent();
                        return Source.REMOVE;
                    });
                });
                menu.popup();
            }
        }
    }

    public abstract class Shared : Object {
        public string session { get; private set; default = ""; }
        public string site { get; private set; }
        public bool attached { get { return session != ""; } }
        protected int64 clock = 0;
        private Json.Array? outgoing = null;
        private uint flush_id = 0;

        public signal void presence(string author, Json.Object state);
        public signal void before_remote();
        public signal void ended();

        construct {
            site = Uuid.string_random().substring(0, 8);
        }

        public void attach(string session_id) {
            detach();
            session = session_id;
            Client.get_default().attach(this);
        }

        public void detach() {
            if (session == "") return;
            Client.get_default().detach(this);
            session = "";
        }

        protected int64 tick(int64 seen = 0) {
            int64 now = get_real_time() / 1000;
            clock = int64.max(int64.max(clock + 1, now), seen + 1);
            return clock;
        }

        protected void observe(int64 ts) {
            if (ts > clock) clock = ts;
        }

        protected void queue(Json.Node op) {
            if (outgoing == null) outgoing = new Json.Array();
            outgoing.add_element(op);
            if (session == "" || flush_id != 0) return;
            flush_id = Timeout.add(40, () => {
                flush_id = 0;
                flush();
                return Source.REMOVE;
            });
        }

        public void flush() {
            if (outgoing == null || session == "") return;
            var o = new Json.Object();
            o.set_array_member("o", outgoing);
            outgoing = null;
            Client.get_default().post(session, encode(o));
        }

        public string? take_outgoing() {
            if (outgoing == null) return null;
            var o = new Json.Object();
            o.set_array_member("o", outgoing);
            outgoing = null;
            return encode(o);
        }

        public void merge(string author, string data) {
            receive(author, data);
        }

        public void set_presence(Json.Object state) {
            if (session == "") return;
            var o = new Json.Object();
            o.set_object_member("p", state);
            Client.get_default().post(session, encode(o));
        }

        internal void receive(string author, string data) {
            var o = decode(data);
            if (o == null) return;
            if (o.has_member("p")) {
                var p = o.get_object_member("p");
                if (p != null) presence(author, p);
            }
            if (o.has_member("o")) {
                before_remote();
                var ops = o.get_array_member("o");
                for (uint i = 0; i < ops.get_length(); i++) apply(ops.get_element(i), author);
            }
        }

        protected abstract void apply(Json.Node op, string author);

        public static string encode(Json.Object o) {
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(o);
            return Json.to_string(node, false);
        }

        public static Json.Object? decode(string text) {
            if (text == "") return null;
            try {
                var node = Json.from_string(text);
                return node != null && node.get_node_type() == Json.NodeType.OBJECT ? node.get_object() : null;
            } catch (Error e) {
                return null;
            }
        }
    }
}
