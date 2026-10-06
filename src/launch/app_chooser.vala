using Gtk;

namespace Singularity.Widgets {

    public class OpenWithDialog : AppDialog {
        public signal void chosen(AppInfo app, bool remember);

        private string content_type;
        private SwitchRow remember_row;
        private Box list_box;
        private bool answered = false;

        public OpenWithDialog(Gtk.Application? app, Gtk.Window? parent, string content_type, string file_name, bool remember_default) {
            base(app, true);
            this.content_type = content_type;
            if (parent != null) transient_for = parent;
            set_title(_("Open With"));
            set_default_size(460, -1);

            var box = new Box(Orientation.VERTICAL, 16);
            box.margin_top = 4;
            box.margin_bottom = 18;
            box.margin_start = 22;
            box.margin_end = 22;

            var headline = new Label(_("Choose an app to open \"%s\".").printf(file_name));
            headline.wrap = true;
            headline.wrap_mode = Pango.WrapMode.WORD_CHAR;
            headline.xalign = 0;
            box.append(headline);

            var scroller = new ScrolledWindow();
            scroller.hscrollbar_policy = PolicyType.NEVER;
            scroller.propagate_natural_height = true;
            scroller.max_content_height = 420;
            list_box = new Box(Orientation.VERTICAL, 12);
            scroller.child = list_box;
            box.append(scroller);

            var options = new PreferencesGroup();
            remember_row = new SwitchRow(_("Always Use This App"), kind_label(content_type), remember_default);
            options.add_row(remember_row);
            box.append(options);

            content_box.append(box);
            populate();

            close_request.connect(() => {
                answered = true;
                return false;
            });
        }

        private static string kind_label(string content_type) {
            string description = ContentType.get_description(content_type);
            if (description == "" || description.contains(content_type)) return _("For every file of this kind");
            return _("For every %s").printf(description);
        }

        private void populate() {
            var listed = new GenericSet<string>(str_hash, str_equal);
            var suggested = new PreferencesGroup(_("Suggested Apps"));
            int count = 0;
            foreach (var info in AppInfo.get_recommended_for_type(content_type)) {
                if (!info.should_show() || listed.contains(info.get_id())) continue;
                listed.add(info.get_id());
                suggested.add_row(app_row(info));
                count++;
            }
            var others = new PreferencesGroup(_("Other Apps That Support This File"));
            int other_count = 0;
            foreach (var info in AppInfo.get_all_for_type(content_type)) {
                if (!info.should_show() || listed.contains(info.get_id())) continue;
                listed.add(info.get_id());
                others.add_row(app_row(info));
                other_count++;
            }
            if (count > 0) list_box.append(suggested);
            if (other_count > 0) list_box.append(others);

            if (count + other_count == 0) {
                var empty = new PreferencesGroup(_("No App Can Open This File"), _("None of the installed apps declares support for this kind of file. Choose any app below, or look for one in the Store."));
                var store = FileOpener.app_by_id("dev.sinty.store.desktop");
                var store_row = new ActionRow(_("Find an App in the Store"), null, "dev.sinty.store");
                store_row.add_suffix(new Image.from_icon_name("go-next-symbolic"));
                store_row.activated.connect(() => {
                    try {
                        if (store != null) store.launch(null, launch_context());
                    } catch (Error e) {
                        warning("Cannot open the Store: %s", e.message);
                    }
                    close_dialog();
                });
                empty.add_row(store_row);
                list_box.prepend(empty);
            }

            var all = new ExpanderRow(_("All Apps"), _("Open the file with any installed app"));
            var everything = new List<AppInfo>();
            foreach (var info in AppInfo.get_all()) {
                if (!info.should_show() || listed.contains(info.get_id())) continue;
                everything.insert_sorted(info, (a, b) => a.get_name().collate(b.get_name()));
            }
            foreach (var info in everything) all.add_row(app_row(info));
            var all_group = new PreferencesGroup();
            all_group.add_row(all);
            list_box.append(all_group);
        }

        private ActionRow app_row(AppInfo info) {
            var row = new ActionRow(info.get_display_name(), info.get_description());
            var icon = info.get_icon() != null ? new Image.from_gicon(info.get_icon()) : new Image.from_icon_name("application-x-executable");
            icon.pixel_size = 32;
            icon.margin_end = 12;
            row.add_prefix(icon);
            row.add_suffix(new Image.from_icon_name("go-next-symbolic"));
            row.activated.connect(() => {
                if (answered) return;
                answered = true;
                chosen(info, remember_row.active);
                close_dialog();
            });
            return row;
        }

        private AppLaunchContext? launch_context() {
            return get_display().get_app_launch_context();
        }
    }

    public class FileOpener : Object {
        public static void open(File file, Gtk.Window? parent) {
            string type = content_type_of(file);
            if (type == "inode/directory") {
                launch_default(file, type, parent);
                return;
            }
            var chosen = chosen_default(type);
            if (chosen != null) {
                launch(chosen, file, parent);
                return;
            }
            var candidates = new List<AppInfo>();
            foreach (var info in AppInfo.get_all_for_type(type)) {
                if (info.should_show()) candidates.append(info);
            }
            if (candidates.length() == 1) {
                launch(candidates.nth_data(0), file, parent);
                return;
            }
            ask(file, type, parent, true);
        }

        public static void open_with(File file, Gtk.Window? parent) {
            ask(file, content_type_of(file), parent, false);
        }

        public static bool has_chosen_default(string content_type) {
            return chosen_default(content_type) != null;
        }

        private static void ask(File file, string type, Gtk.Window? parent, bool remember_default) {
            var app = parent != null ? parent.application : null;
            var dialog = new OpenWithDialog(app, parent, type, display_name(file), remember_default);
            dialog.chosen.connect((info, remember) => {
                if (remember) {
                    try {
                        info.set_as_default_for_type(type);
                    } catch (Error e) {
                        warning("Cannot set the default app for %s: %s", type, e.message);
                    }
                }
                launch(info, file, parent);
            });
            dialog.open_dialog();
        }

        private static void launch(AppInfo info, File file, Gtk.Window? parent) {
            var files = new List<File>();
            files.append(file);
            try {
                AppLaunchContext? context = parent != null ? parent.get_display().get_app_launch_context() : null;
                info.launch(files, context);
            } catch (Error e) {
                warning("Cannot open %s with %s: %s", file.get_uri(), info.get_id(), e.message);
            }
        }

        private static void launch_default(File file, string type, Gtk.Window? parent) {
            var info = AppInfo.get_default_for_type(type, false);
            if (info != null) launch(info, file, parent);
        }

        private static string content_type_of(File file) {
            try {
                var info = file.query_info(FileAttribute.STANDARD_CONTENT_TYPE, FileQueryInfoFlags.NONE);
                string? type = info.get_content_type();
                if (type != null && type != "") return type;
            } catch (Error e) {
            }
            bool uncertain;
            return ContentType.guess(file.get_basename(), null, out uncertain);
        }

        private static string display_name(File file) {
            try {
                var info = file.query_info(FileAttribute.STANDARD_DISPLAY_NAME, FileQueryInfoFlags.NONE);
                return info.get_display_name();
            } catch (Error e) {
                return file.get_basename() ?? file.get_uri();
            }
        }

        private static AppInfo? chosen_default(string type) {
            foreach (string path in mimeapps_paths()) {
                var key_file = new KeyFile();
                try {
                    key_file.load_from_file(path, KeyFileFlags.NONE);
                } catch (Error e) {
                    continue;
                }
                if (!key_file.has_group("Default Applications")) continue;
                try {
                    if (!key_file.has_key("Default Applications", type)) continue;
                    foreach (string id in key_file.get_string_list("Default Applications", type)) {
                        var info = app_by_id(id.strip());
                        if (info != null) return info;
                    }
                } catch (Error e) {
                }
            }
            return null;
        }

        public static AppInfo? app_by_id(string id) {
            foreach (var info in AppInfo.get_all()) {
                if (info.get_id() == id) return info;
            }
            return null;
        }

        private static string[] mimeapps_paths() {
            string[] desktops = {};
            string? current = Environment.get_variable("XDG_CURRENT_DESKTOP");
            if (current != null) {
                foreach (string d in current.split(":")) {
                    if (d != "") desktops += d.down();
                }
            }
            string[] config_dirs = { Environment.get_user_config_dir() };
            foreach (string d in Environment.get_system_config_dirs()) config_dirs += d;
            string[] data_dirs = { Environment.get_user_data_dir() };
            foreach (string d in Environment.get_system_data_dirs()) data_dirs += d;
            string[] paths = {};
            foreach (string dir in config_dirs) {
                foreach (string d in desktops) paths += Path.build_filename(dir, d + "-mimeapps.list");
                paths += Path.build_filename(dir, "mimeapps.list");
            }
            foreach (string dir in data_dirs) {
                foreach (string d in desktops) paths += Path.build_filename(dir, "applications", d + "-mimeapps.list");
                paths += Path.build_filename(dir, "applications", "mimeapps.list");
            }
            return paths;
        }
    }
}
