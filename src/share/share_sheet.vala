using Gtk;

namespace Singularity.Widgets {

    public class ShareSheet : AppDialog {
        public ShareContent content { get; private set; }
        public Gtk.Window? parent_window { get; private set; }

        public bool working { get; private set; default = false; }

        private Stack stack;
        private FlowBox tiles;
        private PreferencesGroup link_group;
        private ActionRow account_row;
        private ActionRow access_row;
        private ActionRow expiry_row;
        private DropDown account_drop;
        private DropDown access_drop;
        private DropDown expiry_drop;
        private Gee.ArrayList<Accounts.Account> accounts = new Gee.ArrayList<Accounts.Account>();
        private Box page_box;
        private Box page_holder;
        private Label page_title;
        private Button back_button;
        private Label progress_label;
        private Stack progress_indicator;
        private CircularProgress progress_ring;
        private Label progress_percent;
        private Label detail_label;
        private Label progress_detail;
        private Button progress_cancel;
        private StatusPage status;
        private Cancellable? work_cancellable;
        private bool hidden_while_working;
        private Toast? waiting_toast;
        private int page_serial;

        public ShareSheet(Gtk.Window? parent, ShareContent content, Gtk.Application? app = null) {
            base(parent != null ? parent.application : (app ?? (Gtk.Application) GLib.Application.get_default()), parent != null, true);
            this.content = content;
            parent_window = parent;
            transient_for = parent;
            build();
        }

        private void build() {
            set_title(_("Share"));
            set_default_size(460, -1);
            resizable = false;
            add_css_class("share-sheet");

            var summary = new Box(Orientation.HORIZONTAL, 14);
            summary.margin_start = 22;
            summary.margin_end = 22;
            summary.margin_top = 2;
            summary.margin_bottom = 16;
            summary.append(preview_widget());
            var labels = new Box(Orientation.VERTICAL, 2);
            labels.valign = Align.CENTER;
            labels.hexpand = true;
            var name = new Label(content.summary_title);
            name.add_css_class("title-4");
            name.xalign = 0;
            name.ellipsize = Pango.EllipsizeMode.MIDDLE;
            name.max_width_chars = 32;
            labels.append(name);
            detail_label = new Label(summary_detail());
            detail_label.add_css_class("dim-label");
            detail_label.add_css_class("caption");
            detail_label.xalign = 0;
            detail_label.ellipsize = Pango.EllipsizeMode.END;
            detail_label.visible = detail_label.label != "";
            labels.append(detail_label);
            summary.append(labels);
            content_box.append(summary);

            stack = new Stack();
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.vhomogeneous = false;
            stack.interpolate_size = true;
            stack.add_named(build_home(), "home");
            stack.add_named(build_page(), "page");
            stack.add_named(build_progress(), "progress");
            status = new StatusPage();
            status.compact = true;
            var status_box = new Box(Orientation.VERTICAL, 12);
            status_box.append(status);
            var status_back = new Button.with_label(_("Back"));
            status_back.add_css_class("pill");
            status_back.halign = Align.CENTER;
            status_back.margin_bottom = 22;
            status_back.clicked.connect(show_home);
            status_box.append(status_back);
            stack.add_named(status_box, "status");
            content_box.append(stack);

            close_request.connect(() => {
                if (working) {
                    hide_while_working();
                    return true;
                }
                if (work_cancellable != null) work_cancellable.cancel();
                return false;
            });
            load_accounts.begin();
        }

        private string summary_detail() {
            string sub = content.location != null ? location_subtitle() : content.summary_subtitle;
            if (content.files.length == 1) {
                var located = Accounts.CloudShare.locate(content.files[0]);
                var owner = located != null ? Accounts.Manager.get_default().get_account(located.account_id) : null;
                if (owner != null) sub = _("%s, online in %s").printf(sub, owner.display_name);
            }
            return sub;
        }

        private string location_subtitle() {
            var account = Accounts.Manager.get_default().get_account(content.location.account_id);
            return account != null ? account.display_name : _("Online file");
        }

        private Widget preview_widget() {
            if (content.files.length == 1) {
                string[] types = content.content_types();
                if (types.length == 1 && types[0].has_prefix("image/") && content.files[0].get_path() != null) {
                    try {
                        var pixbuf = new Gdk.Pixbuf.from_file_at_scale(content.files[0].get_path(), 96, 96, true);
                        var thumb = new Image.from_paintable(Gdk.Texture.for_pixbuf(pixbuf));
                        thumb.pixel_size = 48;
                        thumb.add_css_class("share-preview");
                        return thumb;
                    } catch (Error e) {
                    }
                }
            }
            var image = new Image.from_gicon(content.location != null
                ? (GLib.Icon) new ThemedIcon(content.location.is_folder ? "folder" : ContentType.get_generic_icon_name(Accounts.CloudDrive.guess_type(content.location.name)) ?? "text-x-generic")
                : content.icon);
            image.pixel_size = 48;
            return image;
        }

        private Widget build_home() {
            var box = new Box(Orientation.VERTICAL, 18);
            box.margin_start = 18;
            box.margin_end = 18;
            box.margin_bottom = 20;

            var targets = ShareTargets.get_default().list_for(content);
            int fit = 7;
            if (parent_window != null && parent_window.get_width() > 0) fit = (parent_window.get_width() - 2 * SHADOW_MARGIN - 34) / 70;
            fit = fit.clamp(3, 7);
            int per_line = targets.size <= fit ? int.max(targets.size, 1) : (int) Math.ceil(targets.size / Math.ceil(targets.size / (double) fit));
            tiles = new FlowBox();
            tiles.selection_mode = SelectionMode.NONE;
            tiles.homogeneous = true;
            tiles.halign = Align.CENTER;
            tiles.min_children_per_line = per_line;
            tiles.max_children_per_line = per_line;
            tiles.column_spacing = 2;
            tiles.row_spacing = 4;
            tiles.add_css_class("share-targets");
            tiles.update_property(AccessibleProperty.LABEL, _("Share To"), -1);
            foreach (var target in targets) {
                var tile = make_tile(target);
                tiles.append(tile);
                tile.get_parent().focusable = false;
            }
            box.append(tiles);

            link_group = new PreferencesGroup(_("Link"));
            account_row = new ActionRow(_("Upload To"));
            account_drop = new DropDown.from_strings({});
            account_drop.valign = Align.CENTER;
            account_drop.update_property(AccessibleProperty.LABEL, _("Upload To"), -1);
            account_row.add_suffix(account_drop);
            account_drop.notify["selected"].connect(() => {
                update_expiry_row();
            });
            link_group.add_row(account_row);
            access_row = new ActionRow(_("Access"));
            access_drop = new DropDown.from_strings({ Accounts.LinkAccess.VIEW.label(), Accounts.LinkAccess.EDIT.label() });
            access_drop.valign = Align.CENTER;
            access_drop.update_property(AccessibleProperty.LABEL, _("Access"), -1);
            access_drop.selected = Accounts.CloudShare.last_access == Accounts.LinkAccess.EDIT ? 1 : 0;
            access_drop.notify["selected"].connect(() => {
                Accounts.CloudShare.last_access = access;
            });
            access_row.add_suffix(access_drop);
            link_group.add_row(access_row);
            expiry_row = new ActionRow(_("Expires"));
            expiry_drop = new DropDown.from_strings({ _("Never"), _("In a Day"), _("In a Week"), _("In a Month") });
            expiry_drop.valign = Align.CENTER;
            expiry_drop.update_property(AccessibleProperty.LABEL, _("Expires"), -1);
            expiry_row.add_suffix(expiry_drop);
            link_group.add_row(expiry_row);
            link_group.visible = false;
            box.append(link_group);

            return box;
        }

        private Widget make_tile(ShareTarget target) {
            var button = new Button();
            button.add_css_class("share-tile");
            button.width_request = 68;
            var inner = new Box(Orientation.VERTICAL, 6);
            var icon = new Image.from_gicon(target.get_icon(content));
            icon.pixel_size = 40;
            inner.append(icon);
            var label = new Label(target.label);
            label.single_line_mode = true;
            label.ellipsize = Pango.EllipsizeMode.END;
            label.max_width_chars = 9;
            label.add_css_class("caption");
            inner.append(label);
            button.child = inner;
            string full = target.description ?? target.label;
            button.tooltip_text = full;
            button.update_property(AccessibleProperty.LABEL, full, -1);
            button.clicked.connect(() => target.activate(this, content));
            return button;
        }

        private Widget build_page() {
            page_box = new Box(Orientation.VERTICAL, 12);
            page_box.margin_start = 18;
            page_box.margin_end = 18;
            page_box.margin_bottom = 20;
            var head = new Box(Orientation.HORIZONTAL, 8);
            back_button = new CircularButton("go-previous-symbolic", _("Back"));
            back_button.valign = Align.CENTER;
            back_button.clicked.connect(show_home);
            head.append(back_button);
            page_title = new Label("");
            page_title.add_css_class("heading");
            page_title.xalign = 0;
            page_title.hexpand = true;
            head.append(page_title);
            page_box.append(head);
            page_holder = new Box(Orientation.VERTICAL, 12);
            page_box.append(page_holder);
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.propagate_natural_height = true;
            scroll.max_content_height = 480;
            scroll.child = page_box;
            return scroll;
        }

        private Widget build_progress() {
            var box = new Box(Orientation.VERTICAL, 12);
            box.valign = Align.CENTER;
            box.halign = Align.CENTER;
            box.margin_top = 8;
            box.margin_bottom = 24;
            var spinner = new Spinner();
            spinner.set_size_request(48, 48);
            spinner.spinning = true;
            progress_ring = new CircularProgress(72);
            progress_percent = new Label("");
            progress_percent.add_css_class("heading");
            progress_percent.add_css_class("numeric");
            var ring_overlay = new Overlay();
            ring_overlay.child = progress_ring;
            ring_overlay.add_overlay(progress_percent);
            progress_indicator = new Stack();
            progress_indicator.halign = Align.CENTER;
            progress_indicator.add_named(spinner, "spinner");
            progress_indicator.add_named(ring_overlay, "ring");
            box.append(progress_indicator);
            progress_label = new Label("");
            progress_label.add_css_class("title-4");
            progress_label.wrap = true;
            progress_label.justify = Justification.CENTER;
            progress_label.max_width_chars = 36;
            box.append(progress_label);
            progress_detail = new Label("");
            progress_detail.add_css_class("dim-label");
            progress_detail.wrap = true;
            progress_detail.justify = Justification.CENTER;
            box.append(progress_detail);
            progress_cancel = new Button.with_label(_("Cancel"));
            progress_cancel.add_css_class("pill");
            progress_cancel.halign = Align.CENTER;
            progress_cancel.margin_top = 12;
            progress_cancel.clicked.connect(() => {
                if (work_cancellable != null) work_cancellable.cancel();
            });
            box.append(progress_cancel);
            return box;
        }

        private async void load_accounts() {
            var manager = Accounts.Manager.get_default();
            yield manager.load();
            accounts.clear();
            foreach (var a in Accounts.CloudShare.link_accounts()) accounts.add(a);
            detail_label.label = summary_detail();
            detail_label.visible = detail_label.label != "";
            var names = new StringList(null);
            foreach (var a in accounts) names.append(a.display_name);
            account_drop.model = names;
            var def = Accounts.CloudShare.default_account();
            for (int i = 0; i < accounts.size; i++) if (def != null && accounts[i].id == def.id) account_drop.selected = i;
            bool wants_link = content.has_files || content.location != null;
            account_row.visible = accounts.size > 0 && content.has_files && has_local_files();
            link_group.visible = wants_link && (accounts.size > 0 || content.location != null || !has_local_files());
            update_expiry_row();
        }

        private bool has_local_files() {
            foreach (var f in content.files) if (Accounts.CloudShare.locate(f) == null) return true;
            return false;
        }

        private void update_expiry_row() {
            bool supported = false;
            var seen = new Gee.HashSet<string>();
            if (content.location != null) seen.add(content.location.account_id);
            foreach (var f in content.files) {
                var loc = Accounts.CloudShare.locate(f);
                if (loc != null) seen.add(loc.account_id);
                else if (selected_account != null) seen.add(selected_account.id);
            }
            supported = seen.size > 0;
            foreach (string id in seen) {
                var account = Accounts.Manager.get_default().get_account(id);
                var links = account != null ? Accounts.LinkSharing.for_account(account) : null;
                if (links == null || !links.supports_expiry) supported = false;
            }
            expiry_row.visible = supported;
        }

        public Accounts.Account? selected_account {
            owned get {
                uint i = account_drop.selected;
                return i < accounts.size ? accounts[(int) i] : null;
            }
        }

        public Gee.List<Accounts.Account> link_accounts {
            owned get { return accounts; }
        }

        public Accounts.LinkAccess access {
            get { return access_drop.selected == 1 ? Accounts.LinkAccess.EDIT : Accounts.LinkAccess.VIEW; }
        }

        public DateTime? expires {
            owned get {
                if (!expiry_row.visible) return null;
                var now = new DateTime.now_local();
                switch (expiry_drop.selected) {
                    case 1: return now.add_days(1);
                    case 2: return now.add_days(7);
                    case 3: return now.add_months(1);
                    default: return null;
                }
            }
        }

        public void run_target(string id) {
            var target = ShareTargets.get_default().lookup(id);
            if (target != null && target.accepts(content)) {
                if (!accounts_ready) {
                    load_accounts.begin((o, r) => {
                        load_accounts.end(r);
                        target.activate(this, content);
                    });
                    return;
                }
                target.activate(this, content);
            }
        }

        private bool accounts_ready {
            get { return account_drop.model != null && ((ListModel) account_drop.model).get_n_items() == accounts.size && accounts.size > 0; }
        }

        public void show_home() {
            if (working) return;
            stack.visible_child_name = "home";
        }

        public void show_page(string title, Widget page) {
            page_serial++;
            page_title.label = title;
            var child = page_holder.get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                page_holder.remove(child);
                child = next;
            }
            page_holder.append(page);
            stack.visible_child_name = "page";
        }

        public void show_error(string title, string message) {
            working = false;
            status.icon_name = "dialog-warning";
            status.title = title;
            status.description = message;
            stack.visible_child_name = "status";
            if (hidden_while_working) reveal_after_background();
        }

        public void show_status(string icon_name, string title, string message) {
            status.icon_name = icon_name;
            status.title = title;
            status.description = message;
            stack.visible_child_name = "status";
        }

        public Cancellable begin_work(string label, string detail = "") {
            working = true;
            work_cancellable = new Cancellable();
            progress_label.label = label;
            progress_detail.label = detail;
            progress_detail.visible = detail != "";
            progress_indicator.visible_child_name = "spinner";
            stack.visible_child_name = "progress";
            return work_cancellable;
        }

        public void update_fraction(int64 done, int64 total) {
            if (total <= 0) {
                progress_indicator.visible_child_name = "spinner";
                return;
            }
            double fraction = double.min(1.0, (double) done / total);
            int percent = (int) (fraction * 100);
            progress_ring.color = Style.StyleManager.get_default().accent_hex;
            progress_ring.fraction = fraction;
            progress_percent.label = "%d%%".printf(percent);
            progress_ring.tooltip_text = _("%d%% uploaded").printf(percent);
            progress_indicator.visible_child_name = "ring";
            if (waiting_toast != null) waiting_toast.title = "%s %d%%".printf(progress_label.label, percent);
        }

        public void update_work(string label, string detail = "") {
            progress_label.label = label;
            progress_detail.label = detail;
            progress_detail.visible = detail != "";
            if (waiting_toast != null) waiting_toast.title = label;
        }

        public void end_work() {
            working = false;
            work_cancellable = null;
            if (waiting_toast != null) {
                waiting_toast.dismiss();
                waiting_toast = null;
            }
        }

        private void hide_while_working() {
            hidden_while_working = true;
            set_visible(false);
            var window = parent_window as Window;
            if (window != null) {
                waiting_toast = new Toast(progress_label.label);
                waiting_toast.timeout = 0;
                waiting_toast.button_label = _("Cancel");
                waiting_toast.button_clicked.connect(() => {
                    if (work_cancellable != null) work_cancellable.cancel();
                });
                window.add_toast(waiting_toast);
            }
        }

        private void reveal_after_background() {
            hidden_while_working = false;
            if (waiting_toast != null) {
                waiting_toast.dismiss();
                waiting_toast = null;
            }
            present();
        }

        public bool can_toast {
            get { return parent_window is Window; }
        }

        public void toast(Toast toast) {
            var window = parent_window as Window;
            if (window != null) window.add_toast(toast);
        }

        public void finish() {
            working = false;
            if (work_cancellable != null) work_cancellable.cancel();
            destroy();
        }

        public void show_links(string title, Gee.List<Accounts.SharedFile> shared) {
            end_work();
            if (hidden_while_working) reveal_after_background();
            var box = new Box(Orientation.VERTICAL, 12);
            var group = new PreferencesGroup(shared.size == 1 ? _("Link") : _("Links"),
                shared.size > 0 && shared[0].link.expires != null
                    ? _("Anyone with the link can open it until %s.").printf(shared[0].link.expires.format("%x"))
                    : _("Anyone with the link can open it."));
            foreach (var s in shared) {
                string name = s.source != null ? (s.source.get_basename() ?? "") : content.summary_title;
                var row = new ActionRow(name, s.link.url);
                var copy = new Button.from_icon_name("edit-copy-symbolic");
                copy.tooltip_text = _("Copy Link");
                copy.add_css_class("flat");
                copy.valign = Align.CENTER;
                string url = s.link.url;
                copy.clicked.connect(() => {
                    get_clipboard().set_text(url);
                    copy.icon_name = "object-select-symbolic";
                });
                row.add_suffix(copy);
                group.add_row(row);
            }
            box.append(group);
            var actions = new Box(Orientation.HORIZONTAL, 12);
            actions.halign = Align.CENTER;
            var remove = new Button.with_label(shared.size == 1 ? _("Remove Link") : _("Remove Links"));
            remove.add_css_class("pill");
            remove.add_css_class("destructive-action");
            remove.clicked.connect(() => remove_shared.begin(shared));
            actions.append(remove);
            if (shared.size == 1) {
                var qr = new Button.with_label(_("Show QR Code"));
                qr.add_css_class("pill");
                string url = shared[0].link.url;
                qr.clicked.connect(() => show_qr(url, null));
                actions.append(qr);
            }
            var copy_all = new Button.with_label(shared.size == 1 ? _("Copy Link") : _("Copy Links"));
            copy_all.add_css_class("pill");
            copy_all.add_css_class("suggested-action");
            copy_all.clicked.connect(() => {
                get_clipboard().set_text(join_links(shared));
                copy_all.label = _("Copied");
            });
            actions.append(copy_all);
            box.append(actions);
            show_page(title, box);
        }

        public void hold_clipboard() {
            var app = application;
            if (app == null) return;
            app.hold();
            Timeout.add_seconds(120, () => {
                app.release();
                return Source.REMOVE;
            });
        }

        public static string join_links(Gee.List<Accounts.SharedFile> shared) {
            string[] urls = {};
            foreach (var s in shared) urls += s.link.url;
            return string.joinv("\n", urls);
        }

        private async void remove_shared(Gee.List<Accounts.SharedFile> shared) {
            var cancellable = begin_work(shared.size == 1 ? _("Removing the link") : _("Removing the links"));
            try {
                foreach (var s in shared) yield Accounts.CloudShare.unshare(s, cancellable);
                end_work();
                bool uploaded = false;
                foreach (var s in shared) if (s.uploaded != null) uploaded = true;
                show_status("user-trash-full", shared.size == 1 ? _("Link Removed") : _("Links Removed"),
                    uploaded ? _("The uploaded copies and their links no longer exist.") : _("Anyone who has the link can no longer open it."));
            } catch (Error e) {
                end_work();
                show_error(_("Could Not Remove the Link"), e.message);
            }
        }

        public void show_qr(string text, Gee.List<Accounts.SharedFile>? shared) {
            var box = new Box(Orientation.VERTICAL, 12);
            box.halign = Align.CENTER;
            try {
                var code = QrCode.encode_text(text, QrEcLevel.MEDIUM);
                var texture = code.to_texture(int.max(2, 216 / (code.size + 8)));
                var picture = new Image.from_paintable(texture);
                picture.pixel_size = texture.width;
                picture.halign = Align.CENTER;
                picture.add_css_class("share-qr");
                picture.update_property(AccessibleProperty.LABEL, _("QR code for %s").printf(text), -1);
                box.append(picture);
                var label = new Label(text);
                label.selectable = true;
                label.wrap = true;
                label.wrap_mode = Pango.WrapMode.CHAR;
                label.max_width_chars = 40;
                label.justify = Justification.CENTER;
                label.add_css_class("dim-label");
                box.append(label);
                var actions = new Box(Orientation.HORIZONTAL, 12);
                actions.halign = Align.CENTER;
                if (shared != null) {
                    var remove = new Button.with_label(_("Remove Link"));
                    remove.add_css_class("pill");
                    remove.add_css_class("destructive-action");
                    remove.clicked.connect(() => remove_shared.begin(shared));
                    actions.append(remove);
                }
                var save = new Button.with_label(_("Save Image…"));
                save.add_css_class("pill");
                save.clicked.connect(() => save_qr.begin(code));
                actions.append(save);
                var copy = new Button.with_label(_("Copy Image"));
                copy.add_css_class("pill");
                copy.add_css_class("suggested-action");
                copy.clicked.connect(() => {
                    try {
                        get_clipboard().set_texture(code.to_texture(10));
                        copy.label = _("Copied");
                    } catch (Error e) {
                        show_error(_("Could Not Copy"), e.message);
                    }
                });
                actions.append(copy);
                box.append(actions);
                show_page(_("QR Code"), box);
            } catch (Error e) {
                show_error(_("No QR Code"), e.message);
            }
        }

        private async void save_qr(QrCode code) {
            var dialog = new FileDialog();
            dialog.initial_name = _("QR Code") + ".png";
            try {
                var file = yield dialog.save(this, null);
                if (file == null) return;
                yield file.replace_contents_async(code.to_png(12), null, false, FileCreateFlags.REPLACE_DESTINATION, null, null);
            } catch (Error e) {
                if (!(e is Gtk.DialogError.DISMISSED)) show_error(_("Could Not Save"), e.message);
            }
        }

        public async Gee.List<Accounts.SharedFile>? create_links(Accounts.Account? upload_to, bool always_upload = false) {
            var result = new Gee.ArrayList<Accounts.SharedFile>();
            var access = this.access;
            var expires = this.expires;
            if (content.location != null) {
                var cancellable = begin_work(_("Creating a link to %s").printf(content.location.name));
                try {
                    var link = yield Accounts.CloudShare.link_location(content.location, access, expires, cancellable);
                    result.add(new Accounts.SharedFile(link, null, null));
                    end_work();
                    return result;
                } catch (Error e) {
                    end_work();
                    if (!(e is Accounts.AccountsError.CANCELLED) && !(e is IOError.CANCELLED)) show_error(_("Could Not Create the Link"), e.message);
                    else show_home();
                    return null;
                }
            }
            bool needs_account = always_upload || has_local_files();
            if (needs_account && upload_to == null) {
                show_status("singularity-account-generic", _("No Online Account"),
                    _("Add a Nextcloud, Google or Microsoft account in Settings, Online Accounts, to share files with a link."));
                return null;
            }
            var cancellable = begin_work("");
            int n = 0;
            foreach (var f in content.files) {
                n++;
                string name = f.get_basename() ?? "";
                bool located = !always_upload && Accounts.CloudShare.locate(f) != null;
                string detail = content.files.length > 1 ? _("%d of %d").printf(n, content.files.length) : "";
                update_work(located ? _("Creating a link to %s").printf(name) : _("Uploading %s to %s").printf(name, upload_to.display_name), detail);
                progress_indicator.visible_child_name = "spinner";
                try {
                    Accounts.SharedFile shared;
                    if (always_upload) {
                        var links = Accounts.LinkSharing.for_account(upload_to);
                        var entry = yield Accounts.CloudShare.upload(upload_to, f, cancellable, (done, total) => update_fraction(done, total));
                        var link = yield links.create_link(entry, access, links.supports_expiry ? expires : null, cancellable);
                        shared = new Accounts.SharedFile(link, entry, f);
                        Accounts.CloudShare.last_account_id = upload_to.id;
                    } else {
                        shared = yield Accounts.CloudShare.share_file(f, upload_to, access, expires, cancellable, (done, total) => update_fraction(done, total));
                    }
                    result.add(shared);
                } catch (Error e) {
                    foreach (var s in result) {
                        try {
                            yield Accounts.CloudShare.unshare(s, null);
                        } catch (Error ignored) {
                        }
                    }
                    end_work();
                    if (e is Accounts.AccountsError.CANCELLED || e is IOError.CANCELLED) {
                        if (hidden_while_working) destroy();
                        else show_home();
                    } else {
                        show_error(_("Could Not Share %s").printf(name), e.message);
                    }
                    return null;
                }
            }
            end_work();
            return result;
        }

        public void link_ready(Gee.List<Accounts.SharedFile> shared) {
            string text = join_links(shared);
            var clipboard = can_toast ? parent_window.get_clipboard() : get_clipboard();
            if (!can_toast) hold_clipboard();
            clipboard.set_text(text);
            if (!can_toast) {
                show_links(_("Link Copied"), shared);
                return;
            }
            var toast = new Toast(shared.size == 1 ? _("Link copied") : _("%d links copied").printf(shared.size));
            toast.button_label = _("Undo");
            var window = (Window) parent_window;
            toast.button_clicked.connect(() => undo_links.begin(window, shared, text));
            window.add_toast(toast);
            finish();
        }

        private static async void undo_links(Window window, Gee.List<Accounts.SharedFile> shared, string text) {
            try {
                foreach (var s in shared) yield Accounts.CloudShare.unshare(s, null);
                var clipboard = window.get_clipboard();
                string? current = null;
                try {
                    current = yield clipboard.read_text_async(null);
                } catch (Error e) {
                }
                if (current == text) clipboard.set_text("");
                window.add_toast(new Toast(shared.size == 1 ? _("Link removed") : _("Links removed")));
            } catch (Error e) {
                window.add_toast(new Toast(_("Could not remove the link: %s").printf(e.message)));
            }
        }
    }

    public class CopyLinkTarget : ShareTarget {
        public CopyLinkTarget() {
            Object(id: "copy-link", label: _("Copy Link"), icon_name: "singularity-share-link");
            priority = 10;
        }

        public override bool accepts(ShareContent content) {
            return content.has_files || content.location != null;
        }

        public override void activate(ShareSheet sheet, ShareContent content) {
            sheet.create_links.begin(sheet.selected_account, false, (o, r) => {
                var shared = sheet.create_links.end(r);
                if (shared != null) sheet.link_ready(shared);
            });
        }
    }

    public class OnlineAccountTarget : ShareTarget {
        public OnlineAccountTarget() {
            Object(id: "online-account", label: _("Upload"), icon_name: "singularity-share-upload");
            description = _("Send to Online Account");
            priority = 30;
        }

        public override bool accepts(ShareContent content) {
            return content.has_files;
        }

        public override void activate(ShareSheet sheet, ShareContent content) {
            if (sheet.link_accounts.size == 0) {
                sheet.show_status("singularity-account-generic", _("No Online Account"),
                    _("Add a Nextcloud, Google or Microsoft account in Settings, Online Accounts, to upload files."));
                return;
            }
            var group = new PreferencesGroup(_("Accounts"));
            foreach (var account in sheet.link_accounts) {
                var row = new ActionRow(account.display_name, account.provider_name);
                var icon = new Image.from_icon_name(account.icon_name);
                icon.pixel_size = 32;
                icon.margin_end = 12;
                row.add_prefix(icon);
                var chosen = account;
                row.activated.connect(() => {
                    sheet.create_links.begin(chosen, true, (o, r) => {
                        var shared = sheet.create_links.end(r);
                        if (shared != null) sheet.show_links(_("Sent to %s").printf(chosen.display_name), shared);
                    });
                });
                group.add_row(row);
            }
            sheet.show_page(description ?? label, group);
        }
    }

    public class QrCodeTarget : ShareTarget {
        public QrCodeTarget() {
            Object(id: "qr-code", label: _("QR Code"), icon_name: "dev.sinty.qrcodes");
            description = _("Show QR Code");
            priority = 50;
        }

        public override GLib.Icon get_icon(ShareContent content) {
            var display = Gdk.Display.get_default();
            bool app_icon = display != null && IconTheme.get_for_display(display).has_icon(icon_name);
            return new ThemedIcon(app_icon ? icon_name : "singularity-share-qr");
        }

        public override bool accepts(ShareContent content) {
            if (content.location != null) return true;
            if (content.has_files) return content.files.length == 1;
            if (content.has_uris) return content.uris.length == 1;
            return content.has_text && content.text.length <= 2000;
        }

        public override void activate(ShareSheet sheet, ShareContent content) {
            if (!content.has_files && content.location == null) {
                sheet.show_qr(content.link_or_text ?? "", null);
                return;
            }
            sheet.create_links.begin(sheet.selected_account, false, (o, r) => {
                var shared = sheet.create_links.end(r);
                if (shared != null && shared.size == 1) sheet.show_qr(shared[0].link.url, shared);
            });
        }
    }

    public class ClipboardTarget : ShareTarget {
        public ClipboardTarget() {
            Object(id: "clipboard", label: _("Clipboard"), icon_name: "singularity-share-clipboard");
            description = _("Copy to Clipboard");
            priority = 60;
        }

        public override bool accepts(ShareContent content) {
            return content.has_files || content.has_uris || content.has_text;
        }

        public override void activate(ShareSheet sheet, ShareContent content) {
            var clipboard = sheet.parent_window != null ? sheet.parent_window.get_clipboard() : sheet.get_clipboard();
            if (content.has_files) {
                string[] uris = {};
                foreach (var f in content.files) uris += f.get_uri();
                var list = new Gdk.FileList.from_array(content.files);
                Gdk.ContentProvider[] providers = {
                    new Gdk.ContentProvider.for_value(list),
                    new Gdk.ContentProvider.for_bytes("text/uri-list", new Bytes((string.joinv("\r\n", uris) + "\r\n").data)),
                    new Gdk.ContentProvider.for_bytes("text/plain;charset=utf-8", new Bytes(string.joinv("\n", uris).data))
                };
                clipboard.set_content(new Gdk.ContentProvider.union(providers));
            } else {
                clipboard.set_text(content.link_or_text ?? "");
            }
            if (sheet.parent_window == null) sheet.hold_clipboard();
            if (sheet.can_toast) sheet.toast(new Toast(_("Copied to clipboard")));
            sheet.finish();
        }
    }

    public class OpenWithTarget : ShareTarget {
        public OpenWithTarget() {
            Object(id: "open-with", label: _("Open With"), icon_name: "singularity-share-open-with");
            description = _("Open With…");
            priority = 70;
        }

        public override bool accepts(ShareContent content) {
            return content.has_files || (content.has_uris && content.uris.length == 1);
        }

        private static Gee.List<AppInfo> apps_for(ShareContent content) {
            var result = new Gee.ArrayList<AppInfo>();
            string[] types = { "x-scheme-handler/" + (Uri.peek_scheme(content.uris.length > 0 ? content.uris[0] : "") ?? "https") };
            if (content.has_files) types = content.content_types();
            string own = GLib.Application.get_default()?.application_id ?? "";
            var seen = new Gee.HashSet<string>();
            var first = new Gee.ArrayList<AppInfo>();
            foreach (var info in AppInfo.get_recommended_for_type(types[0])) first.add(info);
            foreach (var info in AppInfo.get_all_for_type(types[0])) first.add(info);
            foreach (var info in first) {
                string id = info.get_id() ?? info.get_name();
                if (id in seen || !info.should_show() || id == own + ".desktop") continue;
                bool all = true;
                for (int i = 1; i < types.length && all; i++) {
                    bool found = false;
                    foreach (var other in AppInfo.get_all_for_type(types[i])) if (other.get_id() == info.get_id()) found = true;
                    all = found;
                }
                if (!all) continue;
                seen.add(id);
                result.add(info);
            }
            return result;
        }

        public override GLib.Icon get_icon(ShareContent content) {
            var apps = apps_for(content);
            if (apps.size > 0 && apps[0].get_icon() != null) return apps[0].get_icon();
            return base.get_icon(content);
        }

        public override void activate(ShareSheet sheet, ShareContent content) {
            var apps = apps_for(content);
            if (apps.size == 0) {
                sheet.show_status("application-x-executable", _("No Apps"), _("No installed app can open this."));
                return;
            }
            var group = new PreferencesGroup(_("Apps"));
            foreach (var info in apps) {
                var row = new ActionRow(info.get_display_name(), info.get_description());
                var icon = new Image.from_gicon(info.get_icon() ?? new ThemedIcon("application-x-executable"));
                icon.pixel_size = 32;
                icon.margin_end = 12;
                row.add_prefix(icon);
                var app = info;
                row.activated.connect(() => {
                    var uris = new GLib.List<string>();
                    if (content.has_files) foreach (var f in content.files) uris.append(f.get_uri());
                    else uris.append(content.uris[0]);
                    try {
                        app.launch_uris(uris, sheet.get_display().get_app_launch_context());
                        sheet.finish();
                    } catch (Error e) {
                        sheet.show_error(_("Could Not Open"), e.message);
                    }
                });
                group.add_row(row);
            }
            sheet.show_page(_("Open With"), group);
        }
    }
}
