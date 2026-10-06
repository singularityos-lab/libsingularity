using GLib;

namespace Singularity {

    /**
     * One search result described by an app for the desktop search.
     *
     * Only what is set here leaves the app process. Keep secrets out of
     * every field: the shell shows them in the launcher and the overview.
     */
    public class SearchResultMeta : Object {
        /** Identifier the app uses to find the result again on activation. */
        public string id { get; construct; }
        /** Title of the row. */
        public string name { get; construct; }
        /** Second line of the row, or null. */
        public string? description { get; set; default = null; }
        /** Row icon, or null to use the app icon. */
        public GLib.Icon? icon { get; set; default = null; }
        /** Relevance hint; higher sorts first within the app's group. */
        public double score { get; set; default = 0.0; }
        /** When true, the search stays open after the row is activated. */
        public bool keeps_open { get; set; default = false; }
        /** Colour swatch preview, such as "#3584e4". */
        public string? preview_color { get; set; default = null; }
        /** Icon preview drawn large; a GLib.BytesIcon carries PNG data, e.g. a QR code. */
        public GLib.Icon? preview_icon { get; set; default = null; }
        /** Image preview as an absolute path or a file URI. */
        public string? preview_image { get; set; default = null; }
        /** Short monospace text preview. */
        public string? preview_text { get; set; default = null; }
        /**
         * Draws the colour, icon or image preview at 160 pixels instead of
         * the row size, for content that must stay readable, such as a QR
         * code to scan.
         */
        public bool preview_large { get; set; default = false; }

        private string[] _action_ids = {};
        private string[] _action_labels = {};
        private string[] _action_icons = {};

        public SearchResultMeta(string id, string name) {
            Object(id: id, name: name);
        }

        /**
         * Adds a secondary button to the row. Clicking it calls
         * SearchProviderService.activate_action with `action_id`.
         *
         * @param action_id Identifier passed back on activation.
         * @param label     Tooltip, or button text when there is no icon.
         * @param icon_name Symbolic icon name, or null.
         */
        public void add_action(string action_id, string label, string? icon_name = null) {
            _action_ids += action_id;
            _action_labels += label;
            _action_icons += icon_name ?? "";
        }

        /** Serializes the meta into the a{sv} sent over D-Bus. */
        public HashTable<string, Variant> to_dict() {
            var dict = new HashTable<string, Variant>(str_hash, str_equal);
            dict["id"] = new Variant.string(id);
            dict["name"] = new Variant.string(name);
            if (description != null) dict["description"] = new Variant.string(description);
            if (icon != null) {
                var serialized = icon.serialize();
                if (serialized != null) dict["icon"] = serialized;
            }
            if (score != 0.0) dict["score"] = new Variant.double(score);
            if (keeps_open) dict["keeps-open"] = new Variant.boolean(true);
            if (preview_color != null) dict["preview-color"] = new Variant.string(preview_color);
            if (preview_icon != null) {
                var serialized = preview_icon.serialize();
                if (serialized != null) dict["preview-icon"] = serialized;
            }
            if (preview_image != null) dict["preview-image"] = new Variant.string(preview_image);
            if (preview_text != null) dict["preview-text"] = new Variant.string(preview_text);
            if (preview_large) dict["preview-large"] = new Variant.boolean(true);
            if (_action_ids.length > 0) {
                var builder = new VariantBuilder(new VariantType("a(sss)"));
                for (int i = 0; i < _action_ids.length; i++)
                    builder.add("(sss)", _action_ids[i], _action_labels[i], _action_icons[i]);
                dict["actions"] = builder.end();
            }
            return dict;
        }
    }

    /**
     * What the shell does after a result or one of its actions was
     * activated. Return null from the activation methods when the app
     * handled everything itself, for example by opening a window.
     */
    public class SearchActivationReply : Object {
        /** Text the shell puts on the clipboard, or null. */
        public string? copy_text { get; set; default = null; }
        /**
         * Marks the copied text as a secret. The shell tags it so that
         * clipboard managers skip it, and never keeps it anywhere else.
         */
        public bool copy_sensitive { get; set; default = false; }
        /** Seconds after which the shell clears the copied text, 0 to keep it. */
        public uint clear_after { get; set; default = 0; }

        /**
         * A reply that copies `text`.
         *
         * @param text        Text to copy.
         * @param sensitive   Whether the text is a secret.
         * @param clear_after Seconds before the clipboard is cleared, 0 to keep it.
         */
        public static SearchActivationReply copy(string text, bool sensitive = false, uint clear_after = 0) {
            var reply = new SearchActivationReply();
            reply.copy_text = text;
            reply.copy_sensitive = sensitive;
            reply.clear_after = clear_after;
            return reply;
        }

        /** Serializes the reply into the a{sv} sent over D-Bus. */
        public HashTable<string, Variant> to_dict() {
            var dict = new HashTable<string, Variant>(str_hash, str_equal);
            if (copy_text != null) {
                dict["copy-text"] = new Variant.string(copy_text);
                if (copy_sensitive) dict["copy-sensitive"] = new Variant.boolean(true);
                if (clear_after > 0) dict["copy-clear-after"] = new Variant.uint32(clear_after);
            }
            return dict;
        }
    }

    /**
     * Serves search results from an app to the desktop search, over the
     * `dev.sinty.SearchProvider1` D-Bus interface. The data stays in the app
     * process; the shell only receives the metas the app returns.
     *
     * Subclass it, then call `export` with the application before it runs.
     * Pair it with a manifest in `datadir/singularity/search-providers` and,
     * to answer while the app is closed, a D-Bus service file for the app's
     * bus name that starts it with `--gapplication-service`.
     */
    public abstract class SearchProviderService : Object {
        /** D-Bus interface name served by this class. */
        public const string INTERFACE_NAME = "dev.sinty.SearchProvider1";

        private weak GLib.Application? _app = null;
        private DBusConnection? _connection = null;
        private uint _registration = 0;
        private string? _object_path = null;
        private SearchProviderSkeleton? _skeleton = null;

        /** Object path the provider is exported at, once exported. */
        public string? object_path {
            get { return _object_path; }
        }

        /**
         * Returns the ids of the results matching `terms`, best first.
         *
         * @param terms       The query split on whitespace.
         * @param cancellable Cancelled when the call is abandoned.
         */
        public abstract async string[] get_initial_results(string[] terms, Cancellable? cancellable) throws Error;

        /**
         * Narrows `previous` to the ids matching `terms`, when the user keeps
         * typing the same query. Defaults to a fresh search.
         */
        public virtual async string[] get_subsearch_results(string[] previous, string[] terms,
                                                            Cancellable? cancellable) throws Error {
            return yield get_initial_results(terms, cancellable);
        }

        /** Returns the metas for `ids`, in the same order. Unknown ids are skipped. */
        public abstract async SearchResultMeta[] get_result_metas(string[] ids, Cancellable? cancellable) throws Error;

        /**
         * Called when the user activates the result `id`.
         *
         * @param id        The result id.
         * @param terms     The query at activation time.
         * @param timestamp The input event time, for window activation.
         * @return What the shell should do next, or null.
         */
        public abstract async SearchActivationReply? activate_result(string id, string[] terms,
                                                                     uint32 timestamp) throws Error;

        /**
         * Called when the user clicks the secondary action `action_id` of
         * the result `id`. Defaults to doing nothing.
         */
        public virtual async SearchActivationReply? activate_action(string id, string action_id,
                                                                    string[] terms, uint32 timestamp) throws Error {
            return null;
        }

        /**
         * Called when the user asks to see every result in the app, for
         * example from the group header. Defaults to activating the app.
         */
        public virtual void launch_search(string[] terms, uint32 timestamp) {
            if (_app != null) _app.activate();
        }

        /**
         * Exports the provider for `app`, at `object_path` or at the app's
         * object path followed by `/SearchProvider`.
         *
         * Call it before `app.run`. With a Singularity.Application the object
         * is exported while the app registers on the bus, so D-Bus activated
         * calls always find it; with another GLib.Application it is exported
         * at startup.
         */
        public void export(GLib.Application app, string? object_path = null) {
            _app = app;
            if (app.get_is_registered() && app.get_dbus_connection() != null) {
                register_on(app.get_dbus_connection(), app.get_dbus_object_path(), object_path);
                return;
            }
            var sing = app as Singularity.Application;
            if (sing != null) {
                sing.dbus_registered.connect((conn, path) => register_on(conn, path, object_path));
                sing.dbus_unregistered.connect(() => unexport());
            } else {
                app.startup.connect(() => {
                    if (app.get_is_registered() && app.get_dbus_connection() != null)
                        register_on(app.get_dbus_connection(), app.get_dbus_object_path(), object_path);
                });
                app.shutdown.connect(() => unexport());
            }
        }

        /** Removes the provider from the bus. */
        public void unexport() {
            if (_connection != null && _registration != 0)
                _connection.unregister_object(_registration);
            _registration = 0;
            _connection = null;
            _skeleton = null;
        }

        private void register_on(DBusConnection connection, string? app_path, string? requested) {
            if (_registration != 0) return;
            string path = requested ?? (app_path ?? "/") + "/SearchProvider";
            _skeleton = new SearchProviderSkeleton(this);
            try {
                _registration = connection.register_object(path, _skeleton);
                _connection = connection;
                _object_path = path;
            } catch (IOError e) {
                warning("SearchProviderService: cannot export %s: %s", path, e.message);
            }
        }

        internal void hold() {
            if (_app == null) return;
            if ((_app.flags & ApplicationFlags.IS_SERVICE) != 0 && _app.inactivity_timeout == 0)
                _app.inactivity_timeout = 10000;
            _app.hold();
        }

        internal void release() {
            if (_app != null) _app.release();
        }
    }

    [DBus (name = "dev.sinty.SearchProvider1")]
    internal class SearchProviderSkeleton : Object {
        private SearchProviderService service;

        public SearchProviderSkeleton(SearchProviderService service) {
            this.service = service;
        }

        public async string[] get_initial_result_set(string[] terms) throws GLib.DBusError, GLib.IOError {
            service.hold();
            try {
                return yield service.get_initial_results(terms, null);
            } catch (Error e) {
                throw new DBusError.FAILED(e.message);
            } finally {
                service.release();
            }
        }

        public async string[] get_subsearch_result_set(string[] previous_results, string[] terms)
                throws GLib.DBusError, GLib.IOError {
            service.hold();
            try {
                return yield service.get_subsearch_results(previous_results, terms, null);
            } catch (Error e) {
                throw new DBusError.FAILED(e.message);
            } finally {
                service.release();
            }
        }

        public async HashTable<string, Variant>[] get_result_metas(string[] identifiers)
                throws GLib.DBusError, GLib.IOError {
            service.hold();
            try {
                var metas = yield service.get_result_metas(identifiers, null);
                var dicts = new HashTable<string, Variant>[metas.length];
                for (int i = 0; i < metas.length; i++) dicts[i] = metas[i].to_dict();
                return dicts;
            } catch (Error e) {
                throw new DBusError.FAILED(e.message);
            } finally {
                service.release();
            }
        }

        public async HashTable<string, Variant> activate_result(string identifier, string[] terms, uint32 timestamp)
                throws GLib.DBusError, GLib.IOError {
            service.hold();
            try {
                var reply = yield service.activate_result(identifier, terms, timestamp);
                return reply != null ? reply.to_dict() : new HashTable<string, Variant>(str_hash, str_equal);
            } catch (Error e) {
                throw new DBusError.FAILED(e.message);
            } finally {
                service.release();
            }
        }

        public async HashTable<string, Variant> activate_action(string identifier, string action,
                                                                string[] terms, uint32 timestamp)
                throws GLib.DBusError, GLib.IOError {
            service.hold();
            try {
                var reply = yield service.activate_action(identifier, action, terms, timestamp);
                return reply != null ? reply.to_dict() : new HashTable<string, Variant>(str_hash, str_equal);
            } catch (Error e) {
                throw new DBusError.FAILED(e.message);
            } finally {
                service.release();
            }
        }

        public void launch_search(string[] terms, uint32 timestamp) throws GLib.DBusError, GLib.IOError {
            service.launch_search(terms, timestamp);
        }
    }
}
