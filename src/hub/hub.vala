namespace Singularity.Hub {

    public const string BUS_NAME = "dev.sinty.Hub";
    public const string OBJECT_PATH = "/dev/sinty/Hub";
    public const string INTERFACE = "dev.sinty.Hub1";
    public const string ACTION_NAME = "hub-action";

    public enum ItemKind {
        EMAIL,
        TEXT,
        CHAT,
        CALL,
        MISSED_CALL,
        VOICEMAIL,
        INVITE,
        SOCIAL,
        NOTIFICATION;

        public string to_key() {
            switch (this) {
                case EMAIL: return "email";
                case TEXT: return "text";
                case CHAT: return "chat";
                case CALL: return "call";
                case MISSED_CALL: return "missed-call";
                case VOICEMAIL: return "voicemail";
                case INVITE: return "invite";
                case SOCIAL: return "social";
                default: return "notification";
            }
        }

        public static ItemKind from_key(string key) {
            switch (key) {
                case "email": return EMAIL;
                case "text": return TEXT;
                case "chat": return CHAT;
                case "call": return CALL;
                case "missed-call": return MISSED_CALL;
                case "voicemail": return VOICEMAIL;
                case "invite": return INVITE;
                case "social": return SOCIAL;
                default: return NOTIFICATION;
            }
        }

        public string app_id() {
            switch (this) {
                case EMAIL: return "dev.sinty.lettere";
                case TEXT:
                case CHAT: return "dev.sinty.messages";
                case CALL:
                case MISSED_CALL:
                case VOICEMAIL: return "dev.sinty.phone";
                case INVITE: return "dev.sinty.calendar";
                case SOCIAL: return "dev.sinty.contacts";
                default: return "";
            }
        }

        public string icon_name(bool unread) {
            switch (this) {
                case EMAIL: return unread ? "mail-unread-symbolic" : "mail-read-symbolic";
                case TEXT: return "mail-message-new-symbolic";
                case CHAT: return "mail-message-new-symbolic";
                case CALL: return "call-incoming-symbolic";
                case MISSED_CALL: return "call-missed-symbolic";
                case VOICEMAIL: return "call-start-symbolic";
                case INVITE: return "x-office-calendar-symbolic";
                case SOCIAL: return "system-users-symbolic";
                default: return "preferences-system-notifications-symbolic";
            }
        }
    }

    public enum AccountKind {
        NOTIFICATIONS,
        MESSAGING,
        TEXT,
        EMAIL,
        SOCIAL,
        CALLS,
        VOICEMAIL;

        public string to_key() {
            switch (this) {
                case NOTIFICATIONS: return "notifications";
                case MESSAGING: return "messaging";
                case TEXT: return "text";
                case EMAIL: return "email";
                case SOCIAL: return "social";
                case CALLS: return "calls";
                default: return "voicemail";
            }
        }

        public static AccountKind from_key(string key) {
            switch (key) {
                case "notifications": return NOTIFICATIONS;
                case "messaging": return MESSAGING;
                case "text": return TEXT;
                case "email": return EMAIL;
                case "social": return SOCIAL;
                case "calls": return CALLS;
                default: return VOICEMAIL;
            }
        }
    }

    public class Account : Object {
        public string id { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string detail { get; set; default = ""; }
        public string icon_name { get; set; default = "mail-unread-symbolic"; }
        public AccountKind kind { get; set; default = AccountKind.EMAIL; }
        public string app_id { get; set; default = ""; }

        public Account(string id, string name, AccountKind kind) {
            Object(id: id, name: name, kind: kind);
        }

        public Variant to_variant() {
            var b = new VariantBuilder(new VariantType("a{sv}"));
            b.add("{sv}", "id", new Variant.string(id));
            b.add("{sv}", "name", new Variant.string(name));
            b.add("{sv}", "detail", new Variant.string(detail));
            b.add("{sv}", "icon", new Variant.string(icon_name));
            b.add("{sv}", "kind", new Variant.string(kind.to_key()));
            b.add("{sv}", "app", new Variant.string(app_id));
            return b.end();
        }

        public static Account? from_variant(Variant v) {
            if (!v.is_of_type(new VariantType("a{sv}"))) return null;
            var dict = new VariantDict(v);
            string id = lookup_string(dict, "id");
            if (id == "") return null;
            var a = new Account(id, lookup_string(dict, "name"), AccountKind.from_key(lookup_string(dict, "kind")));
            a.detail = lookup_string(dict, "detail");
            string icon = lookup_string(dict, "icon");
            if (icon != "") a.icon_name = icon;
            a.app_id = lookup_string(dict, "app");
            return a;
        }
    }

    public class Item : Object {
        public string id { get; set; default = ""; }
        public string account { get; set; default = ""; }
        public ItemKind kind { get; set; default = ItemKind.NOTIFICATION; }
        public string sender { get; set; default = ""; }
        public string subject { get; set; default = ""; }
        public string preview { get; set; default = ""; }
        public int64 timestamp { get; set; default = 0; }
        public bool unread { get; set; default = true; }
        public bool priority { get; set; default = false; }
        public bool flagged { get; set; default = false; }
        public bool attachment { get; set; default = false; }
        public int count { get; set; default = 1; }
        public string app_id { get; set; default = ""; }
        public string target { get; set; default = ""; }
        public string icon { get; set; default = ""; }
        public string body { get; set; default = ""; }
        public string[] actions { get; set; default = {}; }

        public Item(string account, string id, ItemKind kind) {
            Object(account: account, id: id, kind: kind);
        }

        public string key {
            owned get { return account + "\n" + id; }
        }

        public Variant to_variant() {
            var b = new VariantBuilder(new VariantType("a{sv}"));
            b.add("{sv}", "id", new Variant.string(id));
            b.add("{sv}", "account", new Variant.string(account));
            b.add("{sv}", "kind", new Variant.string(kind.to_key()));
            b.add("{sv}", "sender", new Variant.string(sender));
            b.add("{sv}", "subject", new Variant.string(subject));
            b.add("{sv}", "preview", new Variant.string(preview));
            b.add("{sv}", "time", new Variant.int64(timestamp));
            b.add("{sv}", "unread", new Variant.boolean(unread));
            b.add("{sv}", "priority", new Variant.boolean(priority));
            b.add("{sv}", "flagged", new Variant.boolean(flagged));
            b.add("{sv}", "attachment", new Variant.boolean(attachment));
            b.add("{sv}", "count", new Variant.int32(count));
            b.add("{sv}", "app", new Variant.string(app_id));
            b.add("{sv}", "target", new Variant.string(target));
            b.add("{sv}", "icon", new Variant.string(icon));
            b.add("{sv}", "body", new Variant.string(body));
            b.add("{sv}", "actions", new Variant.strv(actions));
            return b.end();
        }

        public static Item? from_variant(Variant v) {
            if (!v.is_of_type(new VariantType("a{sv}"))) return null;
            var dict = new VariantDict(v);
            string id = lookup_string(dict, "id");
            string account = lookup_string(dict, "account");
            if (id == "" || account == "") return null;
            var item = new Item(account, id, ItemKind.from_key(lookup_string(dict, "kind")));
            item.sender = lookup_string(dict, "sender");
            item.subject = lookup_string(dict, "subject");
            item.preview = lookup_string(dict, "preview");
            Variant? t = dict.lookup_value("time", VariantType.INT64);
            item.timestamp = t != null ? t.get_int64() : new DateTime.now_utc().to_unix();
            item.unread = lookup_bool(dict, "unread", true);
            item.priority = lookup_bool(dict, "priority", false);
            item.flagged = lookup_bool(dict, "flagged", false);
            item.attachment = lookup_bool(dict, "attachment", false);
            Variant? c = dict.lookup_value("count", VariantType.INT32);
            item.count = c != null ? int.max(1, c.get_int32()) : 1;
            item.app_id = lookup_string(dict, "app");
            item.target = lookup_string(dict, "target");
            item.icon = lookup_string(dict, "icon");
            item.body = lookup_string(dict, "body");
            Variant? acts = dict.lookup_value("actions", VariantType.STRING_ARRAY);
            if (acts != null) item.actions = acts.dup_strv();
            return item;
        }
    }

    private static string lookup_string(VariantDict dict, string key) {
        Variant? v = dict.lookup_value(key, VariantType.STRING);
        return v != null ? v.get_string() : "";
    }

    private static bool lookup_bool(VariantDict dict, string key, bool fallback) {
        Variant? v = dict.lookup_value(key, VariantType.BOOLEAN);
        return v != null ? v.get_boolean() : fallback;
    }

    public class ItemAction : Object {
        public string id { get; construct; }
        public string label { get; construct; }
        public string icon_name { get; construct; }

        public ItemAction(string id, string label, string icon_name) {
            Object(id: id, label: label, icon_name: icon_name);
        }

        public string encode() {
            return "%s\t%s\t%s".printf(id, label, icon_name);
        }

        public static ItemAction? decode(string spec) {
            string[] parts = spec.split("\t");
            if (parts.length < 2 || parts[0] == "") return null;
            return new ItemAction(parts[0], parts[1], parts.length > 2 ? parts[2] : "");
        }

        public static Gee.List<ItemAction> defaults(ItemKind kind) {
            var list = new Gee.ArrayList<ItemAction>();
            switch (kind) {
                case ItemKind.EMAIL:
                    list.add(new ItemAction("reply", _("Reply"), "mail-reply-sender-symbolic"));
                    list.add(new ItemAction("reply-all", _("Reply All"), "mail-reply-all-symbolic"));
                    list.add(new ItemAction("forward", _("Forward"), "mail-forward-symbolic"));
                    break;
                case ItemKind.TEXT:
                case ItemKind.CHAT:
                    list.add(new ItemAction("reply", _("Reply"), "mail-reply-sender-symbolic"));
                    break;
                case ItemKind.CALL:
                case ItemKind.MISSED_CALL:
                case ItemKind.VOICEMAIL:
                    list.add(new ItemAction("call", _("Call Back"), "call-start-symbolic"));
                    list.add(new ItemAction("message", _("Message"), "mail-message-new-symbolic"));
                    break;
                case ItemKind.INVITE:
                    list.add(new ItemAction("accept", _("Accept"), "object-select-symbolic"));
                    list.add(new ItemAction("decline", _("Decline"), "window-close-symbolic"));
                    break;
                default:
                    break;
            }
            return list;
        }
    }

    public delegate void ActionHandler(string account, string id, string action);

    private static void send(string method, Variant parameters) {
        GLib.Bus.get.begin(BusType.SESSION, null, (obj, res) => {
            try {
                var bus = GLib.Bus.get.end(res);
                bus.call.begin(BUS_NAME, OBJECT_PATH, INTERFACE, method, parameters, null,
                    DBusCallFlags.NO_AUTO_START, 5000, null, (o, r) => {
                        try {
                            bus.call.end(r);
                        } catch (Error e) {
                            if (!(e is DBusError.SERVICE_UNKNOWN) && !(e is DBusError.NAME_HAS_NO_OWNER))
                                warning("Hub.%s: %s", method, e.message);
                        }
                    });
            } catch (Error e) {
                warning("Hub: %s", e.message);
            }
        });
    }

    public static void register_account(Account account) {
        send("RegisterAccount", new Variant.tuple({ account.to_variant() }));
    }

    public static void publish(Item item) {
        send("Publish", new Variant.tuple({ item.to_variant() }));
    }

    public static void withdraw(string account, string id) {
        send("Withdraw", new Variant("(ss)", account, id));
    }

    public static void install_action(GLib.Application app, owned ActionHandler handler) {
        var action = new SimpleAction(ACTION_NAME, new VariantType("(sss)"));
        action.activate.connect((parameter) => {
            string account, id, name;
            parameter.get("(sss)", out account, out id, out name);
            handler(account, id, name);
        });
        app.add_action(action);
    }

    public static void deliver(string app_id, string account, string id, string action) {
        string bus_name = app_id.has_suffix(".desktop") ? app_id.substring(0, app_id.length - 8) : app_id;
        string path = "/" + bus_name.replace(".", "/").replace("-", "_");
        var parameter = new Variant("(sss)", account, id, action);
        var args = new Variant("(s@av@a{sv})", ACTION_NAME, new Variant.array(VariantType.VARIANT, { new Variant.variant(parameter) }),
            new VariantBuilder(new VariantType("a{sv}")).end());
        GLib.Bus.get.begin(BusType.SESSION, null, (obj, res) => {
            try {
                var bus = GLib.Bus.get.end(res);
                bus.call.begin(bus_name, path, "org.freedesktop.Application", "ActivateAction", args, null,
                    DBusCallFlags.NONE, 25000, null, (o, r) => {
                        try {
                            bus.call.end(r);
                        } catch (Error e) {
                            warning("Hub: cannot reach %s: %s", bus_name, e.message);
                        }
                    });
            } catch (Error e) {
                warning("Hub: %s", e.message);
            }
        });
    }

    public static uint watch_actions(DBusConnection bus, owned ActionHandler handler) {
        return bus.signal_subscribe(BUS_NAME, INTERFACE, "ActionRequested", OBJECT_PATH, null,
            DBusSignalFlags.NONE, (conn, sender, path, iface, name, parameters) => {
                string account, id, action;
                parameters.get("(sss)", out account, out id, out action);
                handler(account, id, action);
            });
    }
}
