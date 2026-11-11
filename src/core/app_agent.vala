using Singularity.Widgets;

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
            add_builtin_intents();
        }

        private static Regex? risky_re = null;

        private static bool risky(string action) {
            if (risky_re == null) {
                try {
                    risky_re = new Regex("(^|[-_.])(send|delete|remove|erase|wipe|format|trash|discard|publish|post|forward|reply|uninstall|install|restore|revoke|reset|quit|purge|overwrite|empty|block|unfollow|sign-?out|log-?out|pay|buy|share|push|commit|flash)", RegexCompileFlags.CASELESS);
                } catch (RegexError e) {
                    return true;
                }
            }
            return risky_re.match(action);
        }

        private ActionGroup? group_for(string prefix) {
            if (prefix == "app") return app;
            var w = app.get_active_window();
            if (w == null && app.get_windows().length() > 0) w = app.get_windows().nth_data(0);
            if (prefix == "win") return w as ActionGroup;
            return null;
        }

        private void describe_group(Json.Builder b, string prefix, ActionGroup? g) {
            if (g == null) return;
            foreach (string name in g.list_actions()) {
                string full = prefix + "." + name;
                b.begin_object();
                b.set_member_name("name").add_string_value(full);
                b.set_member_name("enabled").add_boolean_value(g.get_action_enabled(name));
                var pt = g.get_action_parameter_type(name);
                b.set_member_name("parameter").add_string_value(pt != null ? pt.dup_string() : "");
                var st = g.get_action_state(name);
                if (st != null) b.set_member_name("state").add_string_value(st.print(false));
                var accels = app.get_accels_for_action(full);
                if (accels.length > 0) {
                    b.set_member_name("keys");
                    b.begin_array();
                    foreach (string a in accels) b.add_string_value(a);
                    b.end_array();
                }
                b.set_member_name("needs_confirmation").add_boolean_value(risky(name));
                b.end_object();
            }
        }

        private Json.Node? run_action(Json.Object args, bool confirmed) throws Error {
            string full = args.has_member("name") ? args.get_string_member("name") : "";
            int dot = full.index_of_char('.');
            if (dot <= 0) throw new IOError.INVALID_ARGUMENT("name must look like win.bold or app.new-window");
            string prefix = full.substring(0, dot);
            string name = full.substring(dot + 1);
            var g = group_for(prefix);
            if (g == null || !g.has_action(name)) throw new IOError.NOT_FOUND("no action %s; list them with app_actions", full);
            if (!confirmed && risky(name)) throw new IOError.PERMISSION_DENIED("%s changes things that cannot be undone: use app_action_confirmed", full);
            if (!g.get_action_enabled(name)) throw new IOError.FAILED("%s is disabled right now", full);
            Variant? param = null;
            var pt = g.get_action_parameter_type(name);
            if (pt != null) {
                if (!args.has_member("value")) throw new IOError.INVALID_ARGUMENT("%s takes a value of type %s", full, pt.dup_string());
                param = Json.gvariant_deserialize(args.get_member("value"), pt.dup_string());
                if (param == null) throw new IOError.INVALID_ARGUMENT("value does not fit type %s", pt.dup_string());
            }
            var before = g.get_action_state(name);
            g.activate_action(name, param);
            var after = g.get_action_state(name);
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("action").add_string_value(full);
            b.set_member_name("activated").add_boolean_value(true);
            if (after != null) {
                b.set_member_name("state").add_string_value(after.print(false));
                b.set_member_name("state_changed").add_boolean_value(before == null || !before.equal(after));
            }
            var w = app.get_active_window();
            b.set_member_name("window").add_string_value(w != null && w.title != null ? w.title : "");
            b.end_object();
            return b.get_root();
        }

        private Gee.ArrayList<ContextRibbon> ribbons() {
            var list = new Gee.ArrayList<ContextRibbon>();
            foreach (unowned ContextRibbon r in ContextRibbon.live) {
                var w = r.get_root() as Gtk.Window;
                if (w != null && w.application == app) list.add(r);
            }
            var active = app.get_active_window();
            list.sort((a, b) => (a.get_root() == active ? 0 : 1) - (b.get_root() == active ? 0 : 1));
            return list;
        }

        private static string clean(string? s) {
            return s != null ? s.replace("_", "").replace("\u2026", "").strip() : "";
        }

        private void describe_menu(Json.Builder b, ContextMenu menu, int depth) {
            b.begin_array();
            foreach (var e in menu.entries) {
                b.begin_object();
                b.set_member_name("label").add_string_value(clean(e.label));
                b.set_member_name("enabled").add_boolean_value(e.row.sensitive);
                if (e.row.has_css_class("checked")) b.set_member_name("checked").add_boolean_value(true);
                if (e.sub != null && depth < 3) {
                    b.set_member_name("entries");
                    describe_menu(b, e.sub, depth + 1);
                }
                b.end_object();
            }
            b.end_array();
        }

        private void describe_item(Json.Builder b, RibbonContext c, RibbonItem it) {
            if (it is RibbonSeparator) return;
            b.begin_object();
            b.set_member_name("id").add_string_value(it.id);
            b.set_member_name("tab").add_string_value(c.title);
            b.set_member_name("label").add_string_value(clean(it.label != null && it.label != "" ? it.label : it.tooltip));
            if (it.tooltip != null && it.tooltip != it.label) b.set_member_name("tip").add_string_value(clean(it.tooltip));
            b.set_member_name("enabled").add_boolean_value(it.widget.sensitive);
            if (it is RibbonToggle) {
                b.set_member_name("kind").add_string_value("toggle");
                b.set_member_name("active").add_boolean_value(((RibbonToggle) it).active);
            } else if (it is RibbonSelector) {
                var sel = (RibbonSelector) it;
                b.set_member_name("kind").add_string_value("choice");
                b.set_member_name("selected").add_string_value(sel.selected ?? sel.text);
                b.set_member_name("options");
                sel.describe_options(b);
            } else if (it is RibbonMenu) {
                b.set_member_name("kind").add_string_value("menu");
                var m = ((RibbonMenu) it).build_detached();
                if (m != null) {
                    b.set_member_name("entries");
                    describe_menu(b, m, 0);
                    m.unparent();
                }
            } else if (it is RibbonWidget) {
                b.set_member_name("kind").add_string_value((((RibbonWidget) it).child is Gtk.Button) ? "button" : "field");
            } else {
                b.set_member_name("kind").add_string_value("button");
            }
            b.end_object();
        }

        private RibbonItem? find_item(string id, out RibbonContext? owner) {
            owner = null;
            foreach (var r in ribbons()) {
                foreach (var c in r.all_contexts()) {
                    foreach (var it in c.items) {
                        if (it.id == id) {
                            owner = c;
                            return it;
                        }
                    }
                }
            }
            return null;
        }

        private static bool press_entry(ContextMenu menu, string[] path, int at) {
            foreach (var e in menu.entries) {
                if (clean(e.label).down() != path[at].strip().down()) continue;
                if (at + 1 < path.length) return e.sub != null && press_entry(e.sub, path, at + 1);
                if (!e.row.sensitive || !(e.row is Gtk.Button)) return false;
                ((Gtk.Button) e.row).clicked();
                return true;
            }
            return false;
        }

        private Json.Node run_command(Json.Object args, bool confirmed) throws Error {
            string id = args.has_member("id") ? args.get_string_member("id") : "";
            RibbonContext? owner;
            var it = find_item(id, out owner);
            if (it == null) throw new IOError.NOT_FOUND("no command %s; list them with app_commands", id);
            string label = clean(it.label != null && it.label != "" ? it.label : it.tooltip);
            string entry = args.has_member("entry") ? args.get_string_member("entry") : "";
            string what = (label + " " + entry).replace(" ", "-");
            if (!confirmed && risky(what)) throw new IOError.PERMISSION_DENIED("%s changes things that cannot be undone: use app_command_confirmed", label);
            if (!it.widget.sensitive) throw new IOError.FAILED("%s is disabled right now", label);
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("id").add_string_value(id);
            b.set_member_name("label").add_string_value(label);
            bool ok = true;
            if (it is RibbonToggle) {
                var t = (RibbonToggle) it;
                bool want = args.has_member("on") ? args.get_boolean_member("on") : !t.active;
                t.active = want;
                ok = t.active == want;
                b.set_member_name("active").add_boolean_value(t.active);
            } else if (it is RibbonSelector) {
                var sel = (RibbonSelector) it;
                string opt = args.has_member("option") ? args.get_string_member("option") : "";
                ok = sel.choose(opt);
                if (!ok) throw new IOError.INVALID_ARGUMENT("%s has no option %s", label, opt);
                b.set_member_name("selected").add_string_value(sel.selected ?? "");
            } else if (it is RibbonMenu) {
                var m = ((RibbonMenu) it).build_detached();
                if (m == null) {
                    ((RibbonMenu) it).popup();
                } else {
                    if (entry == "") {
                        m.unparent();
                        throw new IOError.INVALID_ARGUMENT("%s is a menu: give entry, with submenus as \"Parent > Item\"", label);
                    }
                    ok = press_entry(m, entry.split(">"), 0);
                    m.unparent();
                    if (!ok) throw new IOError.NOT_FOUND("%s has no enabled entry %s", label, entry);
                }
                b.set_member_name("entry").add_string_value(entry);
            } else if (it is RibbonButton) {
                ((RibbonButton) it).button.clicked();
            } else if (it is RibbonWidget && ((RibbonWidget) it).child is Gtk.Button) {
                ((Gtk.Button) ((RibbonWidget) it).child).clicked();
            } else {
                throw new IOError.NOT_SUPPORTED("%s is a field, not a command", label);
            }
            b.set_member_name("done").add_boolean_value(ok);
            b.end_object();
            var n = b.get_root();
            n.get_object().set_boolean_member("verified", ok);
            return n;
        }

        private static void collect_text(Gtk.Widget w, Gee.ArrayList<Gtk.Widget> found) {
            if (!w.get_mapped()) return;
            if (w is Gtk.TextView || (w is Gtk.Editable && !(w is Gtk.Text))) {
                found.add(w);
                return;
            }
            for (var c = w.get_first_child(); c != null; c = c.get_next_sibling()) collect_text(c, found);
        }

        private static int text_size(Gtk.Widget w) {
            if (w is Gtk.TextView) return ((Gtk.TextView) w).buffer.get_char_count() + 1000000;
            return ((Gtk.Editable) w).text.char_count();
        }

        private Gtk.Widget? document() {
            var win = app.get_active_window();
            if (win == null && app.get_windows().length() > 0) win = app.get_windows().nth_data(0);
            if (win == null) return null;
            var focus = win.get_focus();
            for (var f = focus; f != null; f = f.get_parent()) {
                if (f is Gtk.TextView) return f;
            }
            var found = new Gee.ArrayList<Gtk.Widget>();
            collect_text(win, found);
            Gtk.Widget? best = null;
            foreach (var w in found) {
                if (best == null || text_size(w) > text_size(best)) best = w;
            }
            return best;
        }

        private static string widget_text(Gtk.Widget w) {
            if (w is Gtk.TextView) {
                var buf = ((Gtk.TextView) w).buffer;
                Gtk.TextIter a, b;
                buf.get_bounds(out a, out b);
                return buf.get_text(a, b, true);
            }
            return ((Gtk.Editable) w).text;
        }

        private Json.Node read_document(Json.Object args) throws Error {
            var w = document();
            if (w == null) throw new IOError.NOT_FOUND("this app shows no text right now");
            string text = widget_text(w);
            int total = text.char_count();
            int offset = args.has_member("offset") ? (int) args.get_int_member("offset") : 0;
            int limit = args.has_member("limit") ? (int) args.get_int_member("limit") : 20000;
            offset = offset.clamp(0, total);
            int end = (offset + limit).clamp(offset, total);
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("text").add_string_value(text.substring(text.index_of_nth_char(offset), text.index_of_nth_char(end) - text.index_of_nth_char(offset)));
            b.set_member_name("offset").add_int_value(offset);
            b.set_member_name("length").add_int_value(total);
            b.set_member_name("more").add_boolean_value(end < total);
            b.set_member_name("editable").add_boolean_value((w is Gtk.TextView) ? ((Gtk.TextView) w).editable : ((Gtk.Editable) w).editable);
            b.end_object();
            return b.get_root();
        }

        private Json.Node edit_document(Json.Object args) throws Error {
            var w = document();
            if (w == null) throw new IOError.NOT_FOUND("this app shows no text right now");
            string find = args.has_member("find") ? args.get_string_member("find") : "";
            string replace = args.has_member("replace") ? args.get_string_member("replace") : "";
            bool all = args.has_member("all") && args.get_boolean_member("all");
            bool whole = args.has_member("text");
            if (!whole && find == "") throw new IOError.INVALID_ARGUMENT("give find and replace, or text to replace everything");
            string before = widget_text(w);
            string expected;
            int count = 0;
            if (whole) {
                expected = args.get_string_member("text");
                count = 1;
            } else {
                int at = before.index_of(find);
                if (at < 0) throw new IOError.NOT_FOUND("the text has no \"%s\"", find);
                if (all) {
                    count = before.split(find).length - 1;
                    expected = before.replace(find, replace);
                } else {
                    count = 1;
                    expected = before.substring(0, at) + replace + before.substring(at + find.length);
                }
            }
            if (w is Gtk.TextView) {
                var tv = (Gtk.TextView) w;
                if (!tv.editable) throw new IOError.PERMISSION_DENIED("this text cannot be edited");
                var buf = tv.buffer;
                buf.begin_user_action();
                if (whole) {
                    buf.set_text(expected, -1);
                } else {
                    int from = 0;
                    int done = 0;
                    while (done < count) {
                        string now = widget_text(w);
                        int at = now.index_of(find, from);
                        if (at < 0) break;
                        Gtk.TextIter s, e;
                        buf.get_iter_at_offset(out s, now.substring(0, at).char_count());
                        buf.get_iter_at_offset(out e, now.substring(0, at + find.length).char_count());
                        buf.delete(ref s, ref e);
                        buf.insert(ref s, replace, -1);
                        from = at + replace.length;
                        done++;
                    }
                }
                buf.end_user_action();
            } else {
                var ed = (Gtk.Editable) w;
                if (!ed.editable) throw new IOError.PERMISSION_DENIED("this text cannot be edited");
                ed.text = expected;
            }
            string after = widget_text(w);
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("replaced").add_int_value(count);
            b.set_member_name("length").add_int_value(after.char_count());
            b.set_member_name("verified").add_boolean_value(after == expected);
            b.set_member_name("undo").add_string_value("Ctrl+Z");
            b.end_object();
            return b.get_root();
        }

        private async Json.Node run_batch(Json.Object args) throws Error {
            if (!args.has_member("steps")) throw new IOError.INVALID_ARGUMENT("give steps, a list of {intent, args}");
            var steps = args.get_array_member("steps");
            if (steps.get_length() > 50) throw new IOError.INVALID_ARGUMENT("at most 50 steps");
            foreach (var n in steps.get_elements()) {
                var o = n.get_object();
                string name = o != null && o.has_member("intent") ? o.get_string_member("intent") : "";
                bool known = false;
                foreach (var i in intents) {
                    if (i.name != name) continue;
                    known = true;
                    if (i.risk == AppIntentRisk.IRREVERSIBLE || name == "app_batch")
                        throw new IOError.PERMISSION_DENIED("%s cannot run in a batch: call it on its own", name);
                }
                if (!known) throw new IOError.NOT_FOUND("unknown intent %s", name);
            }
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("results");
            b.begin_array();
            int ok = 0;
            bool verified = true;
            string? failed = null;
            foreach (var n in steps.get_elements()) {
                var o = n.get_object();
                string name = o.get_string_member("intent");
                string raw = o.has_member("args") ? Json.to_string(o.get_member("args"), false) : "{}";
                b.begin_object();
                b.set_member_name("intent").add_string_value(name);
                try {
                    string res = yield run(name, raw);
                    var parsed = Json.from_string(res);
                    b.set_member_name("result").add_value(parsed);
                    if (parsed != null && parsed.get_node_type() == Json.NodeType.OBJECT && parsed.get_object().has_member("verified")
                        && !parsed.get_object().get_boolean_member("verified")) verified = false;
                    ok++;
                } catch (Error e) {
                    b.set_member_name("error").add_string_value(e.message);
                    failed = name;
                }
                b.end_object();
                if (failed != null) break;
            }
            b.end_array();
            b.set_member_name("done").add_int_value(ok);
            b.set_member_name("total").add_int_value((int) steps.get_length());
            if (failed != null) b.set_member_name("stopped_at").add_string_value(failed);
            b.set_member_name("verified").add_boolean_value(failed == null && verified);
            b.end_object();
            return b.get_root();
        }

        private void add_builtin_intents() {
            add_intent("app_read", "Read the whole text of the document this app shows, in pages: offset and limit count characters. Use it before editing.",
                "{\"type\":\"object\",\"properties\":{\"offset\":{\"type\":\"integer\"},\"limit\":{\"type\":\"integer\"}}}",
                AppIntentRisk.READ, (args) => read_document(args));
            add_intent("app_edit", "Change the document this app shows: replace find with replace (all for every match), or give text to replace everything. It reads the text back and answers verified; Ctrl+Z undoes it.",
                "{\"type\":\"object\",\"properties\":{\"find\":{\"type\":\"string\"},\"replace\":{\"type\":\"string\"},\"all\":{\"type\":\"boolean\"},\"text\":{\"type\":\"string\"}}}",
                AppIntentRisk.UNDOABLE, (args) => edit_document(args));
            add_async_intent("app_batch", "Run several intents of this app in order in one call, stopping at the first error. Steps that cannot be undone are refused here.",
                "{\"type\":\"object\",\"properties\":{\"steps\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"intent\":{\"type\":\"string\"},\"args\":{\"type\":\"object\"}},\"required\":[\"intent\"]}}},\"required\":[\"steps\"]}",
                AppIntentRisk.UNDOABLE, (args, reply) => {
                    run_batch.begin(args, (obj, res) => {
                        try {
                            reply(run_batch.end(res), null);
                        } catch (Error e) {
                            reply(null, e);
                        }
                    });
                });
            add_intent("app_commands", "List every command of this app's ribbon, tab by tab: buttons, on and off toggles, choices with their options, and menus with their entries. Run one with app_command.",
                "{\"type\":\"object\",\"properties\":{\"tab\":{\"type\":\"string\"}}}", AppIntentRisk.READ, (args) => {
                    string tab = args.has_member("tab") ? args.get_string_member("tab").down() : "";
                    var b = new Json.Builder();
                    b.begin_array();
                    foreach (var r in ribbons()) {
                        foreach (var c in r.all_contexts()) {
                            if (!c.shown) continue;
                            if (tab != "" && c.title.down() != tab && c.id != tab) continue;
                            foreach (var it in c.items) describe_item(b, c, it);
                        }
                    }
                    b.end_array();
                    return b.get_root();
                });
            add_intent("app_command", "Press one ribbon command by the id app_commands gives, exactly as a click does. For a toggle give on; for a choice give option; for a menu give entry, with submenus as \"Parent > Item\".",
                "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"on\":{\"type\":\"boolean\"},\"option\":{\"type\":\"string\"},\"entry\":{\"type\":\"string\"}},\"required\":[\"id\"]}",
                AppIntentRisk.UNDOABLE, (args) => run_command(args, false));
            add_intent("app_command_confirmed", "Press a ribbon command that cannot be undone (send, delete, publish, share). The user confirms it first.",
                "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"on\":{\"type\":\"boolean\"},\"option\":{\"type\":\"string\"},\"entry\":{\"type\":\"string\"}},\"required\":[\"id\"]}",
                AppIntentRisk.IRREVERSIBLE, (args) => run_command(args, true));
            add_intent("app_actions", "List every command this app offers (menu, ribbon, toolbar and keyboard actions) with whether it is enabled, the value it takes, its current state and its keys. Run them with app_action.",
                "{\"type\":\"object\",\"properties\":{}}", AppIntentRisk.READ, (args) => {
                    var b = new Json.Builder();
                    b.begin_array();
                    describe_group(b, "app", app);
                    describe_group(b, "win", group_for("win"));
                    b.end_array();
                    return b.get_root();
                });
            add_intent("app_action", "Run one command of this app exactly as its menu, button or key does, by the name app_actions gives (win.bold, app.new-window). value is the parameter when the command takes one. Answers with the state read back after it ran.",
                "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"value\":{}},\"required\":[\"name\"]}",
                AppIntentRisk.UNDOABLE, (args) => run_action(args, false));
            add_intent("app_action_confirmed", "Run a command that cannot be undone (send, delete, publish, share). The user confirms it first.",
                "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"value\":{}},\"required\":[\"name\"]}",
                AppIntentRisk.IRREVERSIBLE, (args) => run_action(args, true));
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
            app.hold();
            try {
                return yield run(name, raw);
            } finally {
                if (app.inactivity_timeout < 10000) app.inactivity_timeout = 10000;
                app.release();
            }
        }

        private async string run(string name, string raw) throws Error {
            foreach (var i in intents) {
                if (i.name != name) continue;
                var node = Json.from_string(raw);
                var obj = node != null && node.get_node_type() == Json.NodeType.OBJECT ? node.get_object() : new Json.Object();
                Json.Node? result = null;
                if (i.handler != null) {
                    result = i.handler(obj);
                } else {
                    Error? failure = null;
                    SourceFunc resume = run.callback;
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
            return agent.context_json().make_valid();
        }

        public async string invoke(string intent, string args, BusName sender) throws DBusError, IOError {
            check(sender);
            try {
                var result = yield agent.invoke(intent, args);
                return result.make_valid();
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
