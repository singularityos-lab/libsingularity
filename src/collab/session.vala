namespace Singularity.Collab {

    public delegate string TextGetter();
    public delegate void TextSetter(string text, string author);
    public delegate Gee.Map<string, string> UnitsGetter();
    public delegate void UnitsSetter(Gee.Map<string, string?> changed, string author);

    public class TextBinding : Object {
        public Text text { get; private set; }
        private TextGetter getter;
        private TextSetter setter;
        private string last;
        private bool applying = false;
        private uint pending = 0;
        private string pending_author = "";

        public TextBinding(Text text, owned TextGetter getter, owned TextSetter setter) {
            this.text = text;
            this.getter = (owned) getter;
            this.setter = (owned) setter;
            last = text.to_string();
            text.before_remote.connect(local_changed);
            text.inserted.connect((o, s, author) => remote(author));
            text.removed.connect((o, n, author) => remote(author));
        }

        public static void diff(string before, string after, out int start, out int removed, out string inserted) {
            int a_len = before.char_count();
            int b_len = after.char_count();
            int prefix = 0;
            int ia = 0, ib = 0;
            unichar ca, cb;
            while (prefix < a_len && prefix < b_len) {
                int na = ia, nb = ib;
                before.get_next_char(ref na, out ca);
                after.get_next_char(ref nb, out cb);
                if (ca != cb) break;
                ia = na;
                ib = nb;
                prefix++;
            }
            int suffix = 0;
            int ea = before.length, eb = after.length;
            while (suffix < a_len - prefix && suffix < b_len - prefix) {
                int pa = ea, pb = eb;
                before.get_prev_char(ref pa, out ca);
                after.get_prev_char(ref pb, out cb);
                if (ca != cb) break;
                ea = pa;
                eb = pb;
                suffix++;
            }
            start = prefix;
            removed = a_len - prefix - suffix;
            inserted = after.substring(ib, (long) (eb - ib));
        }

        public void local_changed() {
            if (applying) return;
            string now = getter();
            if (now == last) return;
            int start, removed;
            string inserted;
            diff(last, now, out start, out removed, out inserted);
            if (removed > 0) text.delete(start, removed);
            if (inserted != "") text.insert(start, inserted);
            last = now;
        }

        private void remote(string author) {
            pending_author = author;
            if (pending != 0) return;
            pending = Idle.add(() => {
                pending = 0;
                last = text.to_string();
                applying = true;
                setter(last, pending_author);
                applying = false;
                return Source.REMOVE;
            });
        }
    }

    public class UnitsBinding : Object {
        public Document document { get; private set; }
        private UnitsGetter getter;
        private UnitsSetter setter;
        private Gee.HashMap<string, string?> incoming = new Gee.HashMap<string, string?>();
        private uint pending = 0;
        private string pending_author = "";
        private bool applying = false;

        public UnitsBinding(Document document, owned UnitsGetter getter, owned UnitsSetter setter) {
            this.document = document;
            this.getter = (owned) getter;
            this.setter = (owned) setter;
            document.before_remote.connect(local_changed);
            document.changed.connect((key, value, author) => {
                incoming[key] = value;
                pending_author = author;
                if (pending != 0) return;
                pending = Idle.add(() => {
                    pending = 0;
                    var batch = incoming;
                    incoming = new Gee.HashMap<string, string?>();
                    applying = true;
                    setter(batch, pending_author);
                    applying = false;
                    return Source.REMOVE;
                });
            });
        }

        public void local_changed() {
            if (applying) return;
            document.update(getter());
        }
    }

    public class Session : Object {
        public Shared model { get; construct; }
        public string kind { get; construct; }
        public string title { get; set; }
        public string id { get; private set; default = ""; }
        public bool hosting { get; private set; default = false; }
        public Gee.ArrayList<string> people { get; default = new Gee.ArrayList<string>(); }

        public signal void person_joined(string name);
        public signal void person_left(string name);
        public signal void closed();

        private ulong joined_id = 0;
        private ulong left_id = 0;
        private ulong ended_id = 0;

        public Session(string kind, string title, Shared model) {
            Object(kind: kind, title: title, model: model);
        }

        public bool active {
            get { return id != ""; }
        }

        private static string snapshot_of(Shared model) {
            if (model is Text) return ((Text) model).snapshot();
            if (model is Document) return ((Document) model).snapshot();
            return "";
        }

        private void wire(string session_id) {
            id = session_id;
            model.attach(session_id);
            var client = Client.get_default();
            joined_id = client.joined.connect((sid, name) => {
                if (sid != id) return;
                if (!people.contains(name)) people.add(name);
                person_joined(name);
            });
            left_id = client.left.connect((sid, name) => {
                if (sid != id) return;
                people.remove(name);
                person_left(name);
            });
            ended_id = client.ended.connect((sid) => {
                if (sid != id) return;
                finish();
            });
        }

        private void finish() {
            var client = Client.get_default();
            if (joined_id != 0) client.disconnect(joined_id);
            if (left_id != 0) client.disconnect(left_id);
            if (ended_id != 0) client.disconnect(ended_id);
            joined_id = left_id = ended_id = 0;
            model.flush();
            model.detach();
            id = "";
            closed();
        }

        public async void share_with(Person person, bool read_only = false) throws Error {
            var client = Client.get_default();
            if (id == "") {
                string sid = yield client.share(person.id, kind, title, snapshot_of(model), read_only);
                hosting = true;
                wire(sid);
            } else {
                yield client.invite(id, person.id);
            }
        }

        public void join(string session_id, string host_name) {
            hosting = false;
            people.add(host_name);
            wire(session_id);
        }

        public void pick_and_share(Gtk.Widget anchor, owned PersonPicked? shared = null) {
            var done = (owned) shared;
            Client.pick(anchor, true, (person) => {
                share_with.begin(person, false, (obj, res) => {
                    try {
                        share_with.end(res);
                        if (done != null) done(person);
                    } catch (Error e) {
                        warning("collab: %s", e.message);
                    }
                });
            });
        }

        public async void stop() {
            if (id == "") return;
            model.flush();
            try {
                yield Client.get_default().leave(id);
            } catch (Error e) {
                debug("collab: %s", e.message);
            }
            if (id != "") finish();
        }

        public async void refresh_snapshot() {
            if (id == "" || !hosting) return;
            yield Client.get_default().update_snapshot(id, snapshot_of(model));
        }
    }

    public delegate void Sent(Person person);

    public static void send_to(Gtk.Widget anchor, string kind, string title, string payload, string text, owned Sent? sent = null) {
        var done = (owned) sent;
        Client.pick(anchor, false, (person) => {
            Client.get_default().send.begin(person.id, kind, title, payload, text, (obj, res) => {
                try {
                    Client.get_default().send.end(res);
                    if (done != null) done(person);
                } catch (Error e) {
                    warning("collab: %s", e.message);
                }
            });
        });
    }
}
