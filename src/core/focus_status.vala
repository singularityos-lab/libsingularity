using GLib;

namespace Singularity {

    /**
     * The Focus state of the desktop, read from the `dev.sinty.Focus1`
     * D-Bus interface of the shell.
     *
     * Apps use it to adapt while the user is focusing, for example a chat
     * app that stops badge animations while Sleep is on. Nothing here
     * blocks: until the shell answers, `available` is false and `active`
     * is false.
     *
     * {{{
     * var focus = Singularity.FocusStatus.get_default ();
     * focus.changed.connect (() => {
     *     if (focus.active) print ("%s is on\n", focus.mode_name);
     * });
     * }}}
     */
    public class FocusStatus : Object {
        public const string BUS_NAME = "dev.sinty.Focus";
        public const string OBJECT_PATH = "/dev/sinty/Focus";
        public const string INTERFACE = "dev.sinty.Focus1";

        private static FocusStatus? instance = null;
        private DBusProxy? proxy = null;

        /** True while the shell exports the interface. */
        public bool available { get; private set; default = false; }
        /** True while a Focus mode is on. */
        public bool active { get; private set; default = false; }
        /** Id of the active mode, such as `do-not-disturb`, `work`, `sleep`, `personal` or a custom id. */
        public string mode_id { get; private set; default = ""; }
        /** Translated name of the active mode. */
        public string mode_name { get; private set; default = ""; }
        /** Symbolic icon of the active mode. */
        public string icon_name { get; private set; default = ""; }
        /** Why the mode is on: `manual`, `schedule`, `presenting`, `fullscreen`, or empty. */
        public string reason { get; private set; default = ""; }
        /** Unix time when a manually started mode ends, 0 when it has no end. */
        public int64 until { get; private set; default = 0; }

        /** Emitted after any property above changed. */
        public signal void changed();

        /** The shared instance, connected on first use. */
        public static FocusStatus get_default() {
            if (instance == null) {
                instance = new FocusStatus();
                instance.connect_proxy.begin();
            }
            return instance;
        }

        private async void connect_proxy() {
            try {
                proxy = yield new DBusProxy.for_bus(BusType.SESSION, DBusProxyFlags.DO_NOT_AUTO_START,
                    null, BUS_NAME, OBJECT_PATH, INTERFACE, null);
                proxy.g_properties_changed.connect(() => sync());
                proxy.notify["g-name-owner"].connect(() => sync());
                sync();
            } catch (Error e) {
                debug("FocusStatus: %s", e.message);
            }
        }

        private void sync() {
            available = proxy != null && proxy.g_name_owner != null;
            active = get_bool("Active");
            mode_id = get_string("ModeId");
            mode_name = get_string("ModeName");
            icon_name = get_string("IconName");
            reason = get_string("Reason");
            var v = proxy != null ? proxy.get_cached_property("Until") : null;
            until = v != null && v.is_of_type(VariantType.INT64) ? v.get_int64() : 0;
            changed();
        }

        private bool get_bool(string name) {
            var v = proxy != null ? proxy.get_cached_property(name) : null;
            return v != null && v.is_of_type(VariantType.BOOLEAN) && v.get_boolean();
        }

        private string get_string(string name) {
            var v = proxy != null ? proxy.get_cached_property(name) : null;
            return v != null && v.is_of_type(VariantType.STRING) ? v.get_string() : "";
        }

        /**
         * Tells the shell that the app presents or shares the screen, so
         * Focus modes set to turn on while presenting do. The shell ends the
         * presentation by itself when the app leaves the bus.
         *
         * @return A cookie for `end_presenting`, 0 when the shell does not answer.
         */
        public static async uint begin_presenting(string reason) {
            try {
                var bus = yield Bus.get(BusType.SESSION);
                var ret = yield bus.call(BUS_NAME, OBJECT_PATH, INTERFACE, "BeginPresenting",
                    new Variant("(s)", reason), new VariantType("(u)"), DBusCallFlags.NO_AUTO_START, 2000, null);
                return ret.get_child_value(0).get_uint32();
            } catch (Error e) {
                debug("FocusStatus: BeginPresenting failed: %s", e.message);
                return 0;
            }
        }

        /** Ends a presentation started with `begin_presenting`. */
        public static async void end_presenting(uint cookie) {
            if (cookie == 0) return;
            try {
                var bus = yield Bus.get(BusType.SESSION);
                yield bus.call(BUS_NAME, OBJECT_PATH, INTERFACE, "EndPresenting",
                    new Variant("(u)", cookie), null, DBusCallFlags.NO_AUTO_START, 2000, null);
            } catch (Error e) {
                debug("FocusStatus: EndPresenting failed: %s", e.message);
            }
        }
    }
}
