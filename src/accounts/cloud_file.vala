using Gtk;

namespace Singularity.Accounts {

    /**
     * A file of an online account opened through CloudFileDialog: a local
     * working copy plus where it came from, so saving can upload it back.
     *
     * The origin is written next to the working copy, so an app that only
     * keeps the local path can find it again with for_local().
     */
    public class CloudFile : Object {
        /** Account identifier. */
        public string account_id { get; construct; }
        /** The entry on the server. */
        public CloudEntry entry { get; set; }
        /** Local working copy. */
        public File local { get; construct; }

        public CloudFile(string account_id, CloudEntry entry, File local) {
            Object(account_id: account_id, entry: entry, local: local);
        }

        /** Directory of the local working copies of an account. */
        public static string cache_directory(string account_id) {
            return Path.build_filename(Environment.get_user_cache_dir(), "singularity", "cloud-files", account_id);
        }

        private static File origin_file(File local) {
            return local.get_parent().get_child("." + local.get_basename() + ".origin");
        }

        private void write_origin() {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("account").add_string_value(account_id);
            b.set_member_name("id").add_string_value(entry.id);
            b.set_member_name("parent").add_string_value(entry.parent_id);
            b.set_member_name("name").add_string_value(entry.name);
            b.set_member_name("type").add_string_value(entry.content_type);
            b.set_member_name("export").add_string_value(entry.export_type);
            b.end_object();
            var gen = new Json.Generator();
            gen.set_root(b.get_root());
            try {
                FileUtils.set_contents(origin_file(local).get_path(), gen.to_data(null));
            } catch (Error e) {
                warning("accounts: %s", e.message);
            }
        }

        /**
         * Returns the origin of a working copy opened from an online
         * account, or null for an ordinary local file.
         */
        public static CloudFile? for_local(File local) {
            if (local.get_path() == null) return null;
            var origin = origin_file(local);
            if (!origin.query_exists()) return null;
            try {
                var parser = new Json.Parser();
                parser.load_from_file(origin.get_path());
                var o = parser.get_root().get_object();
                var e = new CloudEntry();
                e.id = o.get_string_member("id");
                e.parent_id = o.get_string_member("parent");
                e.name = o.get_string_member("name");
                e.content_type = o.get_string_member("type");
                e.export_type = o.has_member("export") ? o.get_string_member("export") : "";
                return new CloudFile(o.get_string_member("account"), e, local);
            } catch (Error e) {
                return null;
            }
        }

        /**
         * Downloads an entry into a fresh working copy.
         */
        public static async CloudFile download(CloudDrive drive, CloudEntry entry, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            string dir = Path.build_filename(cache_directory(drive.account.id),
                Checksum.compute_for_string(ChecksumType.SHA1, entry.id).substring(0, 16));
            DirUtils.create_with_parents(dir, 0700);
            var local = File.new_for_path(Path.build_filename(dir, entry.name));
            yield drive.download(entry, local, cancellable, progress);
            var file = new CloudFile(drive.account.id, entry, local);
            file.write_origin();
            return file;
        }

        /** The drive of the file's account, or null when the account is gone. */
        public CloudDrive? get_drive() {
            var account = Manager.get_default().get_account(account_id);
            return account != null ? CloudDrive.for_account(account) : null;
        }

        /**
         * Uploads the working copy over the server file. Documents that only
         * exist in the provider's own format are uploaded as a new file
         * next to the original instead.
         */
        public async void save_back(Cancellable? cancellable = null) throws Error {
            yield Manager.get_default().load();
            var drive = get_drive();
            if (drive == null) throw new AccountsError.NOT_FOUND(_("The online account of this file is no longer available"));
            if (entry.export_type != "") {
                entry = yield drive.upload(entry.parent_id != "" ? entry.parent_id : drive.root_id, entry.name, local, cancellable);
            } else {
                entry = yield drive.replace(entry, local, cancellable);
            }
            write_origin();
        }

        /**
         * Convenience for apps: when `local` is a working copy of an online
         * file, uploads it and returns true; otherwise returns false.
         */
        public static async bool sync_back(File local, Cancellable? cancellable = null) throws Error {
            var file = for_local(local);
            if (file == null) return false;
            yield file.save_back(cancellable);
            return true;
        }
    }

    /**
     * Mode of CloudFileDialog.
     */
    public enum CloudFileDialogMode {
        OPEN,
        SAVE
    }

    /**
     * Dialog to open a file from, or save a file to, an online account.
     *
     * {{{
     * var file = yield CloudFileDialog.open(window, { "application/vnd.oasis.opendocument.text" });
     * if (file != null) load(file.local);
     * }}}
     */
    public class CloudFileDialog : Singularity.Widgets.AppDialog {
        /** Emitted with the chosen file, or null when cancelled. */
        public signal void finished(CloudFile? file);

        private CloudFileDialogMode mode;
        private string[] mime_types;
        private File? save_source;
        private Gtk.ListBox accounts_list;
        private Gtk.ListBox files_list;
        private Gtk.Stack stack;
        private Singularity.Widgets.StatusPage status;
        private Gtk.Label location;
        private Gtk.Button up_button;
        private Gtk.Button primary;
        private Gtk.Entry name_entry;
        private Gtk.Spinner spinner;
        private Singularity.Widgets.CircularProgress transfer_ring;
        private CloudDrive? drive;
        private Gee.ArrayList<string> trail = new Gee.ArrayList<string>();
        private Gee.ArrayList<string> trail_names = new Gee.ArrayList<string>();
        private Gee.ArrayList<CloudEntry> shown = new Gee.ArrayList<CloudEntry>();
        private Cancellable cancellable = new Cancellable();
        private bool done;

        public CloudFileDialog(Gtk.Window parent, CloudFileDialogMode mode, string[]? mime_types = null, File? save_source = null, string suggested_name = "") {
            base(parent.application, true, false);
            this.mode = mode;
            this.mime_types = mime_types ?? new string[0];
            this.save_source = save_source;
            transient_for = parent;
            set_title(mode == CloudFileDialogMode.OPEN ? _("Open from Online Account") : _("Save to Online Account"));
            set_default_size(760, 520);

            var body = new Box(Orientation.HORIZONTAL, 0);
            body.vexpand = true;

            accounts_list = new ListBox();
            accounts_list.add_css_class("navigation-sidebar");
            accounts_list.selection_mode = SelectionMode.SINGLE;
            accounts_list.width_request = 200;
            var accounts_scroll = new ScrolledWindow();
            accounts_scroll.hscrollbar_policy = PolicyType.NEVER;
            accounts_scroll.child = accounts_list;
            body.append(accounts_scroll);

            var right = new Box(Orientation.VERTICAL, 6);
            right.hexpand = true;
            right.margin_start = 12;
            right.margin_end = 12;

            var path_row = new Box(Orientation.HORIZONTAL, 6);
            up_button = new Button.from_icon_name("go-up-symbolic");
            up_button.add_css_class("flat");
            up_button.tooltip_text = _("Parent Folder");
            up_button.sensitive = false;
            up_button.clicked.connect(go_up);
            path_row.append(up_button);
            location = new Label("");
            location.xalign = 0;
            location.hexpand = true;
            location.ellipsize = Pango.EllipsizeMode.START;
            location.add_css_class("heading");
            path_row.append(location);
            spinner = new Spinner();
            path_row.append(spinner);
            transfer_ring = new Singularity.Widgets.CircularProgress(22);
            transfer_ring.visible = false;
            path_row.append(transfer_ring);
            right.append(path_row);

            files_list = new ListBox();
            files_list.add_css_class("boxed-list");
            files_list.selection_mode = SelectionMode.SINGLE;
            files_list.row_activated.connect((row) => activate_entry(row.get_index()));
            files_list.row_selected.connect((row) => update_primary());
            var files_scroll = new ScrolledWindow();
            files_scroll.vexpand = true;
            files_scroll.hscrollbar_policy = PolicyType.NEVER;
            files_scroll.child = files_list;

            status = new Singularity.Widgets.StatusPage();
            stack = new Stack();
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.add_named(files_scroll, "files");
            stack.add_named(status, "status");
            stack.vexpand = true;
            right.append(stack);
            body.append(right);
            content_box.append(body);

            var footer = new Box(Orientation.HORIZONTAL, 12);
            footer.margin_top = 12;
            footer.margin_bottom = 16;
            footer.margin_start = 16;
            footer.margin_end = 16;
            name_entry = new Entry();
            name_entry.hexpand = true;
            name_entry.placeholder_text = _("File name");
            name_entry.text = suggested_name;
            name_entry.visible = mode == CloudFileDialogMode.SAVE;
            name_entry.changed.connect(update_primary);
            name_entry.activate.connect(() => { if (primary.sensitive) primary.clicked(); });
            var spacer = new Box(Orientation.HORIZONTAL, 0);
            spacer.hexpand = mode == CloudFileDialogMode.OPEN;
            var cancel = add_cancel_button();
            cancel.add_css_class("pill");
            cancel.width_request = 120;
            primary = new Button.with_label(mode == CloudFileDialogMode.OPEN ? _("Open") : _("Save"));
            primary.add_css_class("pill");
            primary.add_css_class("suggested-action");
            primary.width_request = 120;
            primary.sensitive = false;
            primary.clicked.connect(on_primary);
            footer.append(cancel);
            footer.append(name_entry);
            footer.append(spacer);
            footer.append(primary);
            content_box.append(footer);

            accounts_list.row_selected.connect((row) => {
                if (row == null) return;
                var account = row.get_data<Account>("account");
                if (account != null) choose_account(account);
            });
            close_request.connect(() => {
                cancellable.cancel();
                if (!done) {
                    done = true;
                    finished(null);
                }
                return false;
            });
            load_accounts.begin();
        }

        /**
         * Shows the dialog to open a file and returns the downloaded file,
         * or null when the user cancelled.
         *
         * @param parent     Window the dialog belongs to.
         * @param mime_types Media types to show besides folders; empty shows every file.
         */
        public static async CloudFile? open(Gtk.Window parent, string[]? mime_types = null) {
            var dialog = new CloudFileDialog(parent, CloudFileDialogMode.OPEN, mime_types);
            CloudFile? result = null;
            dialog.finished.connect((f) => {
                result = f;
                Idle.add(open.callback);
            });
            dialog.open_dialog();
            yield;
            return result;
        }

        /**
         * Shows the dialog to upload a local file and returns the uploaded
         * file, or null when the user cancelled. Later saves can call
         * CloudFile.save_back() on the result.
         */
        public static async CloudFile? save(Gtk.Window parent, File source, string suggested_name) {
            var dialog = new CloudFileDialog(parent, CloudFileDialogMode.SAVE, null, source, suggested_name);
            CloudFile? result = null;
            dialog.finished.connect((f) => {
                result = f;
                Idle.add(save.callback);
            });
            dialog.open_dialog();
            yield;
            return result;
        }

        private void show_status(string icon, string title, string description) {
            status.icon_name = icon;
            status.title = title;
            status.description = description;
            stack.visible_child_name = "status";
        }

        private async void load_accounts() {
            var manager = Manager.get_default();
            yield manager.load();
            yield CloudMounts.get_default().load();
            int n = 0;
            foreach (var account in manager.get_accounts_for(Capability.FILES)) {
                if (CloudDrive.for_account(account) == null) continue;
                var row = new ListBoxRow();
                var box = new Box(Orientation.HORIZONTAL, 8);
                box.margin_top = 6;
                box.margin_bottom = 6;
                box.margin_start = 6;
                box.append(new Image.from_icon_name(account.symbolic_icon_name));
                var label = new Label(account.display_name);
                label.xalign = 0;
                label.ellipsize = Pango.EllipsizeMode.END;
                box.append(label);
                row.child = box;
                row.tooltip_text = account.provider_name;
                row.set_data<Account>("account", account);
                accounts_list.append(row);
                n++;
            }
            if (n == 0) {
                show_status(manager.available ? "singularity-account-generic" : "dialog-warning",
                    _("No Online Accounts With Files"),
                    manager.available
                        ? _("Add a Nextcloud, ownCloud, Google, Microsoft or WebDAV account in Settings, Online Accounts.")
                        : _("The online accounts service is not available."));
                return;
            }
            accounts_list.select_row(accounts_list.get_row_at_index(0));
        }

        private void choose_account(Account account) {
            var mounted = CloudMounts.get_default().for_account(account.id);
            drive = mounted != null ? new MountedCloudDrive(account, mounted.path) : CloudDrive.for_account(account);
            trail.clear();
            trail_names.clear();
            if (drive == null) return;
            trail.add(drive.root_id);
            trail_names.add(account.display_name);
            load_folder.begin();
        }

        private void go_up() {
            if (trail.size <= 1) return;
            trail.remove_at(trail.size - 1);
            trail_names.remove_at(trail_names.size - 1);
            load_folder.begin();
        }

        private bool wanted(CloudEntry e) {
            if (e.is_folder || mime_types.length == 0) return true;
            foreach (string t in mime_types) {
                if (t == e.content_type || ContentType.is_a(e.content_type, t)) return true;
            }
            return false;
        }

        private static string describe(CloudEntry e) {
            string when = e.modified != null ? e.modified.to_local().format("%x") : "";
            if (e.is_folder) return when;
            string size = e.size >= 0 ? format_size((uint64) e.size) : "";
            return size != "" && when != "" ? "%s, %s".printf(size, when) : size + when;
        }

        private async void load_folder() {
            if (drive == null) return;
            up_button.sensitive = trail.size > 1;
            location.label = string.joinv(" / ", trail_names.to_array());
            spinner.spinning = true;
            Widget? child;
            while ((child = files_list.get_first_child()) != null) files_list.remove(child);
            shown.clear();
            update_primary();
            try {
                var entries = yield drive.list(trail[trail.size - 1], cancellable);
                entries.sort((a, b) => {
                    if (a.is_folder != b.is_folder) return a.is_folder ? -1 : 1;
                    return a.name.collate(b.name);
                });
                foreach (var e in entries) {
                    if (!wanted(e)) continue;
                    shown.add(e);
                    var row = new ListBoxRow();
                    var box = new Box(Orientation.HORIZONTAL, 10);
                    box.margin_top = 6;
                    box.margin_bottom = 6;
                    box.margin_start = 8;
                    box.margin_end = 8;
                    var icon = new Image.from_gicon(e.gicon);
                    icon.pixel_size = 32;
                    box.append(icon);
                    var text = new Box(Orientation.VERTICAL, 2);
                    var name = new Label(e.name);
                    name.xalign = 0;
                    name.ellipsize = Pango.EllipsizeMode.MIDDLE;
                    text.append(name);
                    string details = describe(e);
                    if (details != "") {
                        var sub = new Label(details);
                        sub.xalign = 0;
                        sub.add_css_class("dim-label");
                        sub.add_css_class("caption");
                        text.append(sub);
                    }
                    box.append(text);
                    row.child = box;
                    files_list.append(row);
                }
                if (shown.size == 0) {
                    show_status("folder", _("Empty Folder"), mode == CloudFileDialogMode.OPEN
                        ? _("There are no files here that this app can open.")
                        : _("Save here or go back to choose another folder."));
                } else {
                    stack.visible_child_name = "files";
                }
            } catch (Error e) {
                if (!(e is AccountsError.CANCELLED)) {
                    show_status("network-error", _("Could Not Open This Folder"), e.message);
                }
            }
            spinner.spinning = false;
            update_primary();
        }

        private void activate_entry(int index) {
            if (index < 0 || index >= shown.size) return;
            var e = shown[index];
            if (e.is_folder) {
                trail.add(e.id);
                trail_names.add(e.name);
                load_folder.begin();
            } else if (mode == CloudFileDialogMode.OPEN) {
                on_primary();
            } else {
                name_entry.text = e.name;
            }
        }

        private CloudEntry? selected_entry() {
            var row = files_list.get_selected_row();
            if (row == null) return null;
            int i = row.get_index();
            return i >= 0 && i < shown.size ? shown[i] : null;
        }

        private void update_primary() {
            if (drive == null || spinner.spinning) {
                primary.sensitive = false;
                return;
            }
            if (mode == CloudFileDialogMode.OPEN) {
                var e = selected_entry();
                primary.sensitive = e != null && !e.is_folder;
            } else {
                string n = name_entry.text.strip();
                primary.sensitive = n != "" && !n.contains("/");
            }
        }

        private void show_transfer(int64 done, int64 total) {
            if (total <= 0) return;
            double fraction = double.min(1.0, (double) done / total);
            transfer_ring.color = Singularity.Style.StyleManager.get_default().accent_hex;
            transfer_ring.fraction = fraction;
            transfer_ring.tooltip_text = (mode == CloudFileDialogMode.OPEN ? _("%d%% downloaded") : _("%d%% uploaded")).printf((int) (fraction * 100));
            transfer_ring.visible = true;
            spinner.visible = false;
        }

        private void hide_transfer() {
            transfer_ring.visible = false;
            spinner.visible = true;
        }

        private void on_primary() {
            primary.sensitive = false;
            spinner.spinning = true;
            if (mode == CloudFileDialogMode.OPEN) {
                var e = selected_entry();
                if (e == null || e.is_folder) return;
                if (drive is MountedCloudDrive) {
                    finish(new CloudFile(drive.account.id, e, File.new_for_path(e.id)));
                    return;
                }
                CloudFile.download.begin(drive, e, cancellable, show_transfer, (obj, res) => {
                    try {
                        finish(CloudFile.download.end(res));
                    } catch (Error err) {
                        hide_transfer();
                        spinner.spinning = false;
                        show_status("network-error", _("Could Not Open the File"), err.message);
                    }
                });
            } else {
                upload.begin();
            }
        }

        private async void upload() {
            try {
                string folder = trail[trail.size - 1];
                string name = name_entry.text.strip();
                var entry = yield drive.upload(folder, name, save_source, cancellable, show_transfer);
                if (entry.parent_id == "") entry.parent_id = folder;
                if (drive is MountedCloudDrive) {
                    finish(new CloudFile(drive.account.id, entry, File.new_for_path(entry.id)));
                    return;
                }
                hide_transfer();
                var file = yield CloudFile.download(drive, entry, cancellable);
                finish(file);
            } catch (Error err) {
                hide_transfer();
                spinner.spinning = false;
                show_status("network-error", _("Could Not Save the File"), err.message);
                update_primary();
            }
        }

        private void finish(CloudFile file) {
            done = true;
            finished(file);
            close();
        }
    }
}
