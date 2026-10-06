using Gtk;
using Peas;

namespace Singularity {

    public interface FileIconProvider : Object {
        public abstract bool matches(GLib.File file, string? content_type);
        public abstract async Gdk.Paintable? load_icon(GLib.File file, int size);
    }

    public interface FilesPlugin : Object {
        public abstract void activate(FilesPluginContext context);
        public abstract void deactivate();
    }

    /**
     * An entry of the Files context menu, shown for files of the given
     * MIME types, for example "Write to a Drive" for disk images.
     *
     * Register it from a FilesPlugin with FilesPluginContext.add_file_action,
     * or declare it without code in a `.ini` file read by FileActionRegistry.
     */
    public class FileAction : Object {
        /** Stable identifier, e.g. `dev.sinty.drivewriter.write`. */
        public string id { get; construct; }
        /** Menu label. */
        public string label { get; construct; }
        /** Symbolic icon name, or null. */
        public string? icon_name { get; construct; }
        /**
         * MIME types the entry applies to. An entry is an exact type
         * (`image/png`), a wildcard (`image/*`) or a parent type
         * (`text/plain` also matches `text/markdown`). `inode/directory`
         * matches folders. Empty matches every file.
         */
        public string[] mime_types { get; construct; }
        /** Whether the entry is offered when several files are selected. */
        public bool multiple { get; set; default = true; }

        /** Emitted with the selected files when the entry is chosen. */
        public signal void activated(GLib.File[] files);

        public FileAction(string id, string label, string? icon_name, string[] mime_types) {
            Object(id: id, label: label, icon_name: icon_name, mime_types: mime_types);
        }

        /** Whether the entry applies to one file of the given content type. */
        public virtual bool matches(GLib.File file, string? content_type) {
            if (mime_types.length == 0) return true;
            if (content_type == null) return false;
            string mime = GLib.ContentType.get_mime_type(content_type) ?? content_type;
            foreach (unowned string pattern in mime_types) {
                if (pattern.has_suffix("/*")) {
                    if (mime.has_prefix(pattern.substring(0, pattern.length - 1))) return true;
                } else if (mime == pattern || GLib.ContentType.is_mime_type(content_type, pattern)) {
                    return true;
                }
            }
            return false;
        }

        /**
         * Whether the entry applies to a whole selection: every file must
         * match, and more than one file needs `multiple`.
         */
        public bool matches_all(GLib.File[] files, string?[] content_types) {
            if (files.length == 0) return false;
            if (files.length > 1 && !multiple) return false;
            for (int i = 0; i < files.length; i++) {
                if (!matches(files[i], i < content_types.length ? content_types[i] : null)) return false;
            }
            return true;
        }

        /** Runs the entry. The default implementation emits `activated`. */
        public virtual void activate(GLib.File[] files) {
            activated(files);
        }
    }

    public class FilesPluginContext : Object {
        public signal void file_icon_provider_added(FileIconProvider provider);
        public signal void file_icon_provider_removed(FileIconProvider provider);
        /** Emitted when a plugin adds a context menu entry. */
        public signal void file_action_added(FileAction action);
        /** Emitted when a plugin removes a context menu entry. */
        public signal void file_action_removed(FileAction action);

        public FilesPluginContext() {
        }

        public void add_file_icon_provider(FileIconProvider provider) {
            file_icon_provider_added(provider);
        }

        public void remove_file_icon_provider(FileIconProvider provider) {
            file_icon_provider_removed(provider);
        }

        /** Adds an entry to the Files context menu. */
        public void add_file_action(FileAction action) {
            file_action_added(action);
        }

        /** Removes an entry added with add_file_action. */
        public void remove_file_action(FileAction action) {
            file_action_removed(action);
        }
    }

    /**
     * A FileAction declared in a key file instead of a plugin.
     *
     * The file lives in `datadir/singularity/files-actions/<id>.ini`:
     * {{{
     *   [Files Action]
     *   Name=Write to a Drive
     *   Icon=drive-removable-media-symbolic
     *   MimeTypes=application/x-cd-image;application/x-raw-disk-image;
     *   MultipleFiles=false
     *   AppId=dev.sinty.drivewriter
     *   Action=write-image
     * }}}
     * With `AppId` and `Action`, the app's GAction is activated over D-Bus
     * with the selected file URIs as its `as` parameter; the app is started
     * first when it is not running. With `AppId` alone, the app is launched
     * with the files. `Exec` runs a command line instead, with the desktop
     * entry field codes `%f`, `%F`, `%u` and `%U`. `Name` can be localized
     * like in a desktop entry.
     */
    public class DeclarativeFileAction : FileAction {
        /** Application id used for `Action` or to open the files. */
        public string? app_id { get; construct; }
        /** GAction name activated on `app_id`, or null. */
        public string? app_action { get; construct; }
        /** Command line run with the files, or null. */
        public string? command_line { get; construct; }

        public DeclarativeFileAction(string id, string label, string? icon_name, string[] mime_types,
                                     string? app_id, string? app_action, string? command_line) {
            Object(id: id, label: label, icon_name: icon_name, mime_types: mime_types,
                   app_id: app_id, app_action: app_action, command_line: command_line);
        }

        /**
         * Parses a declarative entry. Returns null when the file is not a
         * valid entry or names no way to run it.
         */
        public static DeclarativeFileAction? from_file(string path) {
            const string GROUP = "Files Action";
            var kf = new KeyFile();
            try {
                kf.load_from_file(path, KeyFileFlags.NONE);
                if (!kf.has_group(GROUP)) return null;
                string base_name = Path.get_basename(path);
                string id = kf.has_key(GROUP, "Id") ? kf.get_string(GROUP, "Id")
                    : base_name.substring(0, base_name.last_index_of("."));
                string label = kf.get_locale_string(GROUP, "Name", null);
                string? icon = kf.has_key(GROUP, "Icon") ? kf.get_string(GROUP, "Icon") : null;
                string[] mimes = kf.has_key(GROUP, "MimeTypes") ? kf.get_string_list(GROUP, "MimeTypes") : new string[0];
                string? app_id = kf.has_key(GROUP, "AppId") ? kf.get_string(GROUP, "AppId") : null;
                string? action = kf.has_key(GROUP, "Action") ? kf.get_string(GROUP, "Action") : null;
                string? exec = kf.has_key(GROUP, "Exec") ? kf.get_string(GROUP, "Exec") : null;
                if (app_id == null && exec == null) {
                    warning("Files action %s: needs AppId or Exec", path);
                    return null;
                }
                var entry = new DeclarativeFileAction(id, label, icon, mimes, app_id, action, exec);
                if (kf.has_key(GROUP, "MultipleFiles"))
                    entry.multiple = kf.get_boolean(GROUP, "MultipleFiles");
                return entry;
            } catch (Error e) {
                warning("Files action %s: %s", path, e.message);
                return null;
            }
        }

        public override void activate(GLib.File[] files) {
            base.activate(files);
            var ctx = Gdk.Display.get_default()?.get_app_launch_context();
            var list = new GLib.List<GLib.File>();
            foreach (var f in files) list.append(f);
            try {
                if (command_line != null) {
                    var flags = command_line.contains("%u") || command_line.contains("%U")
                        ? AppInfoCreateFlags.SUPPORTS_URIS : AppInfoCreateFlags.NONE;
                    var info = AppInfo.create_from_commandline(command_line, label, flags);
                    info.launch(list, ctx);
                } else if (app_action != null) {
                    activate_app_action.begin(files);
                } else {
                    var info = find_app_info(app_id);
                    if (info == null) {
                        warning("Files action %s: no desktop entry for %s", id, app_id);
                        return;
                    }
                    info.launch(list, ctx);
                }
            } catch (Error e) {
                warning("Files action %s failed: %s", id, e.message);
            }
        }

        private static AppInfo? find_app_info(string app_id) {
            string wanted = app_id + ".desktop";
            foreach (var info in AppInfo.get_all()) {
                if (info.get_id() == wanted) return info;
            }
            return null;
        }

        private async void activate_app_action(GLib.File[] files) {
            string[] uris = {};
            foreach (var f in files) uris += f.get_uri();
            var param = new Variant.array(VariantType.VARIANT, { new Variant.variant(new Variant.strv(uris)) });
            var platform = new VariantBuilder(VariantType.VARDICT);
            var args = new Variant("(s@av@a{sv})", app_action, param, platform.end());
            string path = "/" + app_id.replace(".", "/").replace("-", "_");
            try {
                var bus = yield GLib.Bus.get(BusType.SESSION);
                try {
                    yield bus.call(app_id, path, "org.freedesktop.Application", "ActivateAction",
                        args, null, DBusCallFlags.NONE, 5000);
                    return;
                } catch (Error e) {
                    if (!(e is DBusError.SERVICE_UNKNOWN) && !(e is DBusError.NAME_HAS_NO_OWNER)) throw e;
                }
                var info = find_app_info(app_id);
                if (info == null) {
                    warning("Files action %s: %s is not running and has no desktop entry", id, app_id);
                    return;
                }
                bool appeared = false;
                bool resumed = false;
                SourceFunc resume = activate_app_action.callback;
                uint watch = Bus.watch_name_on_connection(bus, app_id, BusNameWatcherFlags.NONE, () => {
                    if (resumed) return;
                    resumed = true;
                    appeared = true;
                    resume();
                }, null);
                uint timeout = Timeout.add_seconds(15, () => {
                    if (!resumed) {
                        resumed = true;
                        resume();
                    }
                    return Source.REMOVE;
                });
                info.launch(null, Gdk.Display.get_default()?.get_app_launch_context());
                yield;
                Bus.unwatch_name(watch);
                if (appeared) {
                    Source.remove(timeout);
                    yield bus.call(app_id, path, "org.freedesktop.Application", "ActivateAction",
                        args, null, DBusCallFlags.NONE, 5000);
                } else {
                    warning("Files action %s: %s did not start", id, app_id);
                }
            } catch (Error e) {
                warning("Files action %s failed: %s", id, e.message);
            }
        }
    }

    /**
     * Loads the declarative Files context menu entries installed in
     * `datadir/singularity/files-actions/*.ini`.
     */
    public class FileActionRegistry : Object {
        /** Returns every valid declarative entry; a user copy overrides a system one. */
        public static FileAction[] load_declarative() {
            FileAction[] actions = {};
            foreach (string path in Runtime.find_data_files("singularity/files-actions", ".ini")) {
                var action = DeclarativeFileAction.from_file(path);
                if (action != null) actions += action;
            }
            return actions;
        }
    }
}
