using Gtk;

namespace Singularity.Widgets {

    public class AppSettingsListGroup : PreferencesGroup {
        private Singularity.Core.AppSettingItem item;
        private uint generation = 0;

        public signal void changed();

        public AppSettingsListGroup(Singularity.Core.AppSettingItem item) {
            base(item.label, item.subtitle);
            this.item = item;
            if (item.add_command.length > 0) {
                var add_button = new Button.with_label(item.add_label ?? _("Add"));
                add_button.add_css_class("pill");
                add_button.valign = Align.CENTER;
                add_button.clicked.connect(open_add_dialog);
                add_header_suffix(add_button);
            }
            map.connect(() => reload.begin());
            reload.begin();
        }

        public async void reload() {
            uint mine = ++generation;
            Json.Node? root = null;
            string? failure = null;
            try {
                string output = yield run(item.list_command);
                var parser = new Json.Parser();
                parser.load_from_data(output);
                root = parser.get_root();
            } catch (Error e) {
                failure = e.message;
            }
            if (mine != generation) return;
            clear();
            if (failure != null) {
                var row = new ActionRow(_("Could Not Load the List"), failure, "dialog-warning-symbolic");
                row.activatable = false;
                add_row(row);
                return;
            }
            int count = 0;
            if (root != null && root.get_node_type() == Json.NodeType.ARRAY) {
                root.get_array().foreach_element((arr, index, node) => {
                    if (node.get_node_type() != Json.NodeType.OBJECT) return;
                    add_row(entry_row(node.get_object()));
                    count++;
                });
            }
            if (count == 0) {
                var none = new ActionRow(item.empty_label ?? _("Nothing Added"));
                none.activatable = false;
                add_row(none);
            }
        }

        private static string member_text(Json.Object obj, string member) {
            if (!obj.has_member(member)) return "";
            var node = obj.get_member(member);
            if (node.get_node_type() != Json.NodeType.VALUE) return "";
            if (node.get_value_type() == typeof(string)) return node.get_string();
            if (node.get_value_type() == typeof(int64)) return node.get_int().to_string();
            return "";
        }

        private ActionRow entry_row(Json.Object obj) {
            string id = member_text(obj, item.item_id);
            string title = member_text(obj, item.item_title);
            if (title == "") title = id;
            string subtitle = member_text(obj, item.item_subtitle);
            var row = new ActionRow(title, subtitle != "" ? subtitle : null, item.item_icon);
            row.activatable = false;
            bool removable = item.remove_command.length > 0 && id != ""
                && obj.get_boolean_member_with_default(item.item_removable, true);
            if (removable) {
                var remove = new Button.from_icon_name("list-remove-symbolic");
                remove.valign = Align.CENTER;
                remove.add_css_class("flat");
                remove.tooltip_text = _("Remove");
                remove.clicked.connect(() => confirm_remove(id, title, remove));
                row.add_suffix(remove);
            }
            return row;
        }

        private Gtk.Application? application() {
            return GLib.Application.get_default() as Gtk.Application;
        }

        private void confirm_remove(string id, string title, Button button) {
            var app = application();
            if (app == null) {
                remove_entry.begin(id, button);
                return;
            }
            var dialog = new ConfirmDialog(app, _("Remove “%s”?").printf(title), "user-trash",
                item.remove_description, _("Remove"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dialog.transient_for = get_root() as Gtk.Window;
            dialog.modal = true;
            dialog.response.connect((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) remove_entry.begin(id, button);
            });
            dialog.present();
        }

        private async void remove_entry(string id, Button button) {
            var values = new HashTable<string, string>(str_hash, str_equal);
            values["id"] = id;
            button.sensitive = false;
            try {
                yield run(expand(item.remove_command, values));
                changed();
            } catch (Error e) {
                button.sensitive = true;
                var app = application();
                if (app != null) {
                    var notice = new ConfirmDialog.message(app, _("Could Not Remove"), "dialog-warning", e.message);
                    notice.transient_for = get_root() as Gtk.Window;
                    notice.present();
                }
            }
            yield reload();
        }

        private void open_add_dialog() {
            var app = application();
            if (app == null) return;
            string title = item.add_label ?? _("Add");
            var dialog = new ConfirmDialog(app, title, null, item.add_description, _("Add"),
                ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.closes_on_primary = false;
            dialog.transient_for = get_root() as Gtk.Window;
            dialog.modal = true;
            var group = new PreferencesGroup();
            var entries = new Gee.ArrayList<EntryRow>();
            var status = new Label("");
            status.add_css_class("caption");
            status.wrap = true;
            status.max_width_chars = 42;
            status.visible = false;
            bool busy = false;
            foreach (var field in item.fields) {
                var row = new EntryRow(field.label);
                if (field.placeholder != null) row.placeholder_text = field.placeholder;
                row.entry_changed.connect(() => {
                    status.visible = false;
                    dialog.primary_sensitive = !busy && complete(entries);
                });
                entries.add(row);
                group.add_row(row);
            }
            dialog.custom_area.append(group);
            dialog.custom_area.append(status);
            dialog.primary_sensitive = false;
            dialog.response.connect((r) => {
                if (r != ConfirmDialog.Response.PRIMARY || busy || !complete(entries)) return;
                var values = new HashTable<string, string>(str_hash, str_equal);
                for (int i = 0; i < entries.size; i++) values[item.fields[i].key] = entries[i].text.strip();
                busy = true;
                dialog.primary_sensitive = false;
                status.remove_css_class("error");
                status.add_css_class("dim-label");
                status.label = _("Adding…");
                status.visible = true;
                add_entry.begin(values, (obj, res) => {
                    string? failure = add_entry.end(res);
                    busy = false;
                    if (failure == null) {
                        dialog.close_dialog();
                        return;
                    }
                    status.remove_css_class("dim-label");
                    status.add_css_class("error");
                    status.label = failure;
                    dialog.primary_sensitive = complete(entries);
                });
            });
            dialog.present();
            if (entries.size > 0) entries[0].grab_focus();
        }

        private static bool complete(Gee.ArrayList<EntryRow> entries) {
            foreach (var row in entries) {
                string value = row.text.strip();
                if (value == "" || value.has_prefix("-")) return false;
            }
            return true;
        }

        private async string? add_entry(HashTable<string, string> values) {
            string? failure = null;
            try {
                yield run(expand(item.add_command, values));
                changed();
            } catch (Error e) {
                failure = e.message;
            }
            yield reload();
            return failure;
        }

        private static string[] expand(string[] command, HashTable<string, string> values) {
            string[] argv = {};
            foreach (var part in command) {
                string arg = part;
                values.foreach((key, value) => {
                    arg = arg.replace("{" + key + "}", value);
                });
                argv += arg;
            }
            return argv;
        }

        private static async string run(string[] argv) throws Error {
            var process = new Subprocess.newv(argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            string? output = null;
            string? errors = null;
            yield process.communicate_utf8_async(null, null, out output, out errors);
            if (process.get_successful()) return output ?? "";
            string message = "";
            foreach (var line in (errors ?? "").split("\n")) {
                if (line.strip() != "") message = line.strip();
            }
            if (message.has_prefix("Error: ")) message = message.substring(7);
            if (message == "") message = _("The command did not complete.");
            throw new IOError.FAILED(message);
        }
    }
}
