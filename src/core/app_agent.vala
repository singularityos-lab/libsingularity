namespace Singularity {

    /** How far the effect of an intent reaches, which decides when the agent asks first. */
    public enum AppIntentRisk {
        READ,
        UNDOABLE,
        IRREVERSIBLE;

        public string to_id() {
            switch (this) {
                case READ: return "read";
                case UNDOABLE: return "undoable";
                default: return "irreversible";
            }
        }
    }

    public delegate Json.Node? AppIntentHandler(Json.Object args) throws Error;
    public delegate Json.Node? AppContextProvider();

    /** Delivers the outcome of an intent that finishes later. Call it once, on the main thread. */
    public delegate void AppIntentReply(Json.Node? result, Error? error);
    public delegate void AppIntentAsyncHandler(Json.Object args, owned AppIntentReply reply);

    /**
     * What an application offers to the system agent, on dev.sinty.AppAgent1.
     *
     * Only the owner of dev.sinty.Agent may call it: the daemon applies the
     * user's mode and writes the receipt, so a call from anywhere else would
     * skip both. Handlers run on the main thread and may touch the UI. Without
     * the daemon on the system the object stays exported and unused.
     */
    public class AppAgent : Object {
        private const string AGENT_NAME = "dev.sinty.Agent";

        private class Intent {
            public string name;
            public string description;
            public string schema;
            public AppIntentRisk risk;
            public AppIntentHandler? handler = null;
            public AppIntentAsyncHandler? async_handler = null;

            public Intent(string name, string description, string schema, AppIntentRisk risk) {
                this.name = name;
                this.description = description;
                this.schema = schema;
                this.risk = risk;
            }
        }

        private unowned Gtk.Application app;
        private List<Intent> intents = new List<Intent>();
        private AppContextProvider? context_provider = null;
        private DBusConnection? connection = null;
        private AppAgentService? service = null;
        private uint registration = 0;

        internal AppAgent(Gtk.Application app) {
            this.app = app;
        }

        /**
         * Adds an intent. //schema// is a JSON Schema for the arguments. Declaring
         * the same name twice replaces the earlier one.
         */
        public void add_intent(string name, string description, string schema, AppIntentRisk risk, owned AppIntentHandler handler) {
            var intent = new Intent(name, description, schema, risk);
            intent.handler = (owned) handler;
            put(intent);
        }

        /** Adds an intent whose result arrives later, such as a script run in a web page. */
        public void add_async_intent(string name, string description, string schema, AppIntentRisk risk, owned AppIntentAsyncHandler handler) {
            var intent = new Intent(name, description, schema, risk);
            intent.async_handler = (owned) handler;
            put(intent);
        }

        private void put(Intent intent) {
            unowned List<Intent>? old = intents.search<string>(intent.name, (i, n) => strcmp(i.name, n));
            if (old != null) intents.delete_link(old);
            intents.append(intent);
        }

        /** Sets what Context answers beside the active window: selection, open document, view. */
        public void set_context_provider(owned AppContextProvider provider) {
            context_provider = (owned) provider;
        }

        /** Tells the agent that something happened: an export ended, a message arrived. */
        public void emit_event(string name, Json.Node? data) {
            if (service != null) service.intent_event(name, data != null ? Json.to_string(data, false) : "null");
        }

        internal void export(DBusConnection connection, string object_path) throws Error {
            this.connection = connection;
            service = new AppAgentService(this);
            registration = connection.register_object(object_path, service);
        }

        internal void unexport() {
            if (connection != null && registration != 0) connection.unregister_object(registration);
            registration = 0;
            connection = null;
            service = null;
        }

        internal bool from_agent(string sender) {
            try {
                var r = connection.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "GetNameOwner", new Variant("(s)", AGENT_NAME), new VariantType("(s)"), DBusCallFlags.NONE, 2000);
                return r.get_child_value(0).get_string() == sender;
            } catch (Error e) {
                return false;
            }
        }

        internal string list_json() {
            var b = new Json.Builder();
            b.begin_array();
            foreach (var i in intents) {
                b.begin_object();
                b.set_member_name("name").add_string_value(i.name);
                b.set_member_name("description").add_string_value(i.description);
                b.set_member_name("risk").add_string_value(i.risk.to_id());
                b.set_member_name("schema");
                try {
                    b.add_value(Json.from_string(i.schema));
                } catch (Error e) {
                    b.add_null_value();
                }
                b.end_object();
            }
            b.end_array();
            return Json.to_string(b.get_root(), false);
        }

        internal string context_json() {
            var b = new Json.Builder();
            b.begin_object();
            var w = app.get_active_window();
            b.set_member_name("window").add_string_value(w != null && w.title != null ? w.title : "");
            b.set_member_name("windows").add_int_value(app.get_windows().length());
            if (context_provider != null) {
                var extra = context_provider();
                if (extra != null) b.set_member_name("app").add_value(extra);
            }
            b.end_object();
            return Json.to_string(b.get_root(), false);
        }

        internal async string invoke(string name, string raw) throws Error {
            foreach (var i in intents) {
                if (i.name != name) continue;
                var node = Json.from_string(raw);
                var obj = node != null && node.get_node_type() == Json.NodeType.OBJECT ? node.get_object() : new Json.Object();
                Json.Node? result = null;
                if (i.handler != null) {
                    result = i.handler(obj);
                } else {
                    Error? failure = null;
                    SourceFunc resume = invoke.callback;
                    i.async_handler(obj, (r, e) => {
                        result = r;
                        failure = e != null ? e.copy() : null;
                        Idle.add((owned) resume);
                    });
                    yield;
                    if (failure != null) throw failure;
                }
                return result != null ? Json.to_string(result, false) : "{}";
            }
            throw new DBusError.INVALID_ARGS("unknown intent %s", name);
        }
    }

    [DBus (name = "dev.sinty.AppAgent1")]
    internal class AppAgentService : Object {
        private unowned AppAgent agent;

        public signal void intent_event(string name, string data);

        internal AppAgentService(AppAgent agent) {
            this.agent = agent;
        }

        private void check(BusName sender) throws DBusError {
            if (!agent.from_agent(sender)) throw new DBusError.ACCESS_DENIED("only the system agent may call this");
        }

        public string list_intents(BusName sender) throws DBusError, IOError {
            check(sender);
            return agent.list_json();
        }

        public string context(BusName sender) throws DBusError, IOError {
            check(sender);
            return agent.context_json();
        }

        public async string invoke(string intent, string args, BusName sender) throws DBusError, IOError {
            check(sender);
            try {
                return yield agent.invoke(intent, args);
            } catch (DBusError e) {
                throw e;
            } catch (IOError e) {
                throw e;
            } catch (Error e) {
                throw new DBusError.FAILED("%s", e.message);
            }
        }
    }
}
