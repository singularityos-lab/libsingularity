namespace Singularity {

    public abstract class ShareTarget : Object {
        public string id { get; construct; }
        public string label { get; construct set; }
        public string icon_name { get; construct set; }
        public string? description { get; set; default = null; }
        public int priority { get; set; default = 100; }

        public virtual bool accepts(ShareContent content) {
            return content.has_files;
        }

        public virtual GLib.Icon get_icon(ShareContent content) {
            return new ThemedIcon(icon_name);
        }

        public abstract void activate(Widgets.ShareSheet sheet, ShareContent content);
    }

    public class DeclarativeShareTarget : ShareTarget {
        public const string GROUP = "Share Target";

        public string[] mime_types { get; set; default = {}; }
        public bool files { get; set; default = true; }
        public bool uris { get; set; default = false; }
        public bool text { get; set; default = false; }
        public bool multiple { get; set; default = true; }
        public string? app_id { get; set; default = null; }
        public string? files_action { get; set; default = null; }
        public string? text_action { get; set; default = null; }
        public string? command_line { get; set; default = null; }

        public DeclarativeShareTarget(string id, string label, string icon_name) {
            Object(id: id, label: label, icon_name: icon_name);
        }

        public static DeclarativeShareTarget? from_file(string path) {
            var kf = new KeyFile();
            try {
                kf.load_from_file(path, KeyFileFlags.NONE);
                if (!kf.has_group(GROUP)) return null;
                string base_name = Path.get_basename(path);
                string id = kf.has_key(GROUP, "Id") ? kf.get_string(GROUP, "Id") : base_name.substring(0, base_name.last_index_of("."));
                var target = new DeclarativeShareTarget(id, kf.get_locale_string(GROUP, "Name", null),
                    kf.has_key(GROUP, "Icon") ? kf.get_string(GROUP, "Icon") : "application-x-executable");
                if (kf.has_key(GROUP, "Description")) target.description = kf.get_locale_string(GROUP, "Description", null);
                if (kf.has_key(GROUP, "MimeTypes")) target.mime_types = kf.get_string_list(GROUP, "MimeTypes");
                if (kf.has_key(GROUP, "Accepts")) {
                    string[] accepts = kf.get_string_list(GROUP, "Accepts");
                    target.files = "files" in accepts;
                    target.uris = "uris" in accepts;
                    target.text = "text" in accepts;
                }
                if (kf.has_key(GROUP, "MultipleFiles")) target.multiple = kf.get_boolean(GROUP, "MultipleFiles");
                if (kf.has_key(GROUP, "Priority")) target.priority = kf.get_integer(GROUP, "Priority");
                if (kf.has_key(GROUP, "AppId")) target.app_id = kf.get_string(GROUP, "AppId");
                if (kf.has_key(GROUP, "FilesAction")) target.files_action = kf.get_string(GROUP, "FilesAction");
                if (kf.has_key(GROUP, "TextAction")) target.text_action = kf.get_string(GROUP, "TextAction");
                if (kf.has_key(GROUP, "Exec")) target.command_line = kf.get_string(GROUP, "Exec");
                if (target.app_id == null && target.command_line == null) {
                    warning("Share target %s: needs AppId or Exec", path);
                    return null;
                }
                return target;
            } catch (Error e) {
                warning("Share target %s: %s", path, e.message);
                return null;
            }
        }

        public bool installed {
            get { return app_id == null || ShareTargets.find_app_info(app_id) != null; }
        }

        public override bool accepts(ShareContent content) {
            if (content.has_files) {
                if (!files) return false;
                if (!multiple && content.files.length > 1) return false;
                return content.all_match(mime_types);
            }
            if (content.has_uris && uris) return text_action != null || files_action != null || command_line != null;
            if (content.has_text && text) return text_action != null;
            return false;
        }

        public override void activate(Widgets.ShareSheet sheet, ShareContent content) {
            var ctx = Gdk.Display.get_default()?.get_app_launch_context();
            try {
                if (content.has_files || (content.has_uris && text_action == null)) {
                    string[] list = {};
                    if (content.has_files) foreach (var f in content.files) list += f.get_uri();
                    else list = content.uris;
                    if (command_line != null) {
                        var launch = new GLib.List<string>();
                        foreach (string u in list) launch.append(u);
                        var flags = command_line.contains("%u") || command_line.contains("%U") ? AppInfoCreateFlags.SUPPORTS_URIS : AppInfoCreateFlags.NONE;
                        AppInfo.create_from_commandline(command_line, label, flags).launch_uris(launch, ctx);
                    } else if (files_action != null) {
                        ShareTargets.activate_app_action.begin(app_id, files_action, new Variant.strv(list));
                    } else {
                        var info = ShareTargets.find_app_info(app_id);
                        if (info == null) throw new IOError.NOT_FOUND(_("%s is not installed").printf(label));
                        var launch = new GLib.List<string>();
                        foreach (string u in list) launch.append(u);
                        info.launch_uris(launch, ctx);
                    }
                } else {
                    string payload = content.link_or_text ?? "";
                    ShareTargets.activate_app_action.begin(app_id, text_action, new Variant.string(payload));
                }
                sheet.finish();
            } catch (Error e) {
                sheet.show_error(_("Could Not Share"), e.message);
            }
        }
    }

    public class ShareTargets : Object {
        private static ShareTargets? instance;
        private Gee.ArrayList<ShareTarget> targets = new Gee.ArrayList<ShareTarget>();
        private bool loaded;

        public signal void changed();

        public static ShareTargets get_default() {
            if (instance == null) instance = new ShareTargets();
            return instance;
        }

        private void ensure_loaded() {
            if (loaded) return;
            loaded = true;
            targets.add(new Widgets.CopyLinkTarget());
            targets.add(new Widgets.OnlineAccountTarget());
            targets.add(new Widgets.QrCodeTarget());
            targets.add(new Widgets.ClipboardTarget());
            targets.add(new Widgets.OpenWithTarget());
            targets.add(new Widgets.NearbyTarget());
            foreach (string path in Runtime.find_data_files("singularity/share-targets", ".ini")) {
                var target = DeclarativeShareTarget.from_file(path);
                if (target == null || !target.installed) continue;
                bool dup = false;
                foreach (var t in targets) if (t.id == target.id) dup = true;
                if (!dup) targets.add(target);
            }
        }

        public void register(ShareTarget target) {
            ensure_loaded();
            unregister(target.id);
            targets.add(target);
            changed();
        }

        public void unregister(string id) {
            ensure_loaded();
            foreach (var t in targets) {
                if (t.id == id) {
                    targets.remove(t);
                    changed();
                    return;
                }
            }
        }

        public ShareTarget? lookup(string id) {
            ensure_loaded();
            foreach (var t in targets) if (t.id == id) return t;
            return null;
        }

        public Gee.List<ShareTarget> list_for(ShareContent content) {
            ensure_loaded();
            var result = new Gee.ArrayList<ShareTarget>();
            foreach (var t in targets) if (t.accepts(content)) result.add(t);
            result.sort((a, b) => a.priority != b.priority ? a.priority - b.priority : strcmp(a.label, b.label));
            return result;
        }

        public static AppInfo? find_app_info(string app_id) {
            string wanted = app_id + ".desktop";
            foreach (var info in AppInfo.get_all()) {
                if (info.get_id() == wanted) return info;
            }
            return null;
        }

        public static async void activate_app_action(string app_id, string action, Variant parameter) {
            var param = new Variant.array(VariantType.VARIANT, { new Variant.variant(parameter) });
            var platform = new VariantBuilder(VariantType.VARDICT);
            var args = new Variant("(s@av@a{sv})", action, param, platform.end());
            string path = "/" + app_id.replace(".", "/").replace("-", "_");
            try {
                var bus = yield GLib.Bus.get(BusType.SESSION);
                try {
                    yield bus.call(app_id, path, "org.freedesktop.Application", "ActivateAction", args, null, DBusCallFlags.NONE, 5000);
                    return;
                } catch (Error e) {
                    if (!(e is DBusError.SERVICE_UNKNOWN) && !(e is DBusError.NAME_HAS_NO_OWNER)) throw e;
                }
                var info = find_app_info(app_id);
                if (info == null) {
                    warning("Share: %s is not running and has no desktop entry", app_id);
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
                    yield bus.call(app_id, path, "org.freedesktop.Application", "ActivateAction", args, null, DBusCallFlags.NONE, 5000);
                } else {
                    warning("Share: %s did not start", app_id);
                }
            } catch (Error e) {
                warning("Share: %s.%s failed: %s", app_id, action, e.message);
            }
        }
    }

    public delegate ShareContent? ShareSource();

    public class Share : Object {
        public static Widgets.ShareSheet present(Gtk.Window? parent, ShareContent content, Gtk.Application? app = null) {
            var sheet = new Widgets.ShareSheet(parent, content, app);
            sheet.open_dialog();
            return sheet;
        }

        public static Widgets.ShareSheet files(Gtk.Window parent, File[] files) {
            return present(parent, new ShareContent.for_files(files));
        }

        public static Widgets.ShareSheet uris(Gtk.Window parent, string[] uris, string title = "") {
            return present(parent, new ShareContent.for_uris(uris, title));
        }

        public static Widgets.ShareSheet text(Gtk.Window parent, string text, string title = "") {
            return present(parent, new ShareContent.for_text(text, title));
        }

        public static Widgets.ShareSheet copy_link(Gtk.Window parent, File[] files) {
            var sheet = new Widgets.ShareSheet(parent, new ShareContent.for_files(files));
            sheet.open_dialog();
            sheet.run_target("copy-link");
            return sheet;
        }

        public static Widgets.ShareSheet copy_link_for_entry(Gtk.Window parent, string account_id, string entry_id, string name, bool is_folder = false) {
            var sheet = new Widgets.ShareSheet(parent, new ShareContent.for_location(new Accounts.CloudLocation(account_id, entry_id, name, is_folder)));
            sheet.open_dialog();
            sheet.run_target("copy-link");
            return sheet;
        }

        public static Widgets.ShareSheet present_entry(Gtk.Window parent, string account_id, string entry_id, string name, bool is_folder = false) {
            var sheet = new Widgets.ShareSheet(parent, new ShareContent.for_location(new Accounts.CloudLocation(account_id, entry_id, name, is_folder)));
            sheet.open_dialog();
            return sheet;
        }

        public static SimpleAction add_action(ActionMap map, Gtk.Window window, owned ShareSource source, string name = "share") {
            var action = new SimpleAction(name, null);
            action.activate.connect(() => {
                var content = source();
                if (content != null && content.count > 0) present(window, content);
            });
            map.add_action(action);
            return action;
        }

        public static SimpleAction add_link_action(ActionMap map, Gtk.Window window, owned ShareSource source, string name = "copy-link") {
            var action = new SimpleAction(name, null);
            action.activate.connect(() => {
                var content = source();
                if (content != null && content.has_files) copy_link(window, content.files);
            });
            map.add_action(action);
            return action;
        }
    }
}
