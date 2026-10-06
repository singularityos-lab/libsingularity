using Gtk;

namespace Singularity.Widgets {

    public class NearbyTarget : ShareTarget {
        public NearbyTarget() {
            Object(id: "nearby", label: _("Nearby"), icon_name: "dev.sinty.Nearby");
            description = _("Send to a Nearby Device");
            priority = 15;
        }

        public override GLib.Icon get_icon(ShareContent content) {
            var display = Gdk.Display.get_default();
            bool app_icon = display != null && IconTheme.get_for_display(display).has_icon(icon_name);
            return new ThemedIcon(app_icon ? icon_name : "phone");
        }

        public override bool accepts(ShareContent content) {
            if (content.location != null) return false;
            if (!content.has_files && !content.has_uris && !content.has_text) return false;
            if (content.has_files) {
                foreach (var f in content.files) if (f.get_path() == null) return false;
            }
            return NearbyClient.get_default().available;
        }

        public override void activate(ShareSheet sheet, ShareContent content) {
            var client = NearbyClient.get_default();
            client.start();
            sheet.begin_work(_("Looking for Devices…"));
            client.refresh.begin((o, r) => {
                client.refresh.end(r);
                if (!content.has_files) {
                    sheet.end_work();
                    show_devices(sheet, content, new Variant[0]);
                    return;
                }
                client.list.begin("ListBluetoothDevices", null, (o2, r2) => {
                    var bluetooth = client.list.end(r2);
                    sheet.end_work();
                    show_devices(sheet, content, client.bluetooth_available ? bluetooth : new Variant[0]);
                });
            });
        }

        private void show_devices(ShareSheet sheet, ShareContent content, Variant[] bluetooth) {
            var client = NearbyClient.get_default();
            var nearby = client.usable_devices();
            if (nearby.size == 0 && bluetooth.length == 0) {
                var box = new Box(Orientation.VERTICAL, 12);
                var status = new StatusPage();
                status.icon_name = "dev.sinty.Nearby";
                status.title = _("No Devices Nearby");
                status.description = _("Pair your phone or another computer in Settings, Connected Devices. Both need to be on the same network.");
                box.append(status);
                var open = new Button.with_label(_("Open Connected Devices"));
                open.add_css_class("pill");
                open.halign = Align.CENTER;
                open.clicked.connect(() => {
                    NearbyClient.open_settings();
                    sheet.finish();
                });
                box.append(open);
                sheet.show_page(_("Nearby"), box);
                return;
            }
            var page = new Box(Orientation.VERTICAL, 12);
            if (nearby.size > 0) {
                string hint = content.has_files ? _("Files go to the Downloads folder of the other device.")
                    : content.has_uris ? _("The link opens on the other device.") : _("The text appears on the other device.");
                var group = new PreferencesGroup(_("Devices"), hint);
                var rows = new Widget[0];
                foreach (var d in nearby) {
                    if (!d.has_plugin("share")) continue;
                    var row = new ActionRow(d.name, d.status_text());
                    var icon = new Image.from_icon_name(d.full_icon_name);
                    icon.pixel_size = 32;
                    icon.margin_end = 12;
                    row.add_prefix(icon);
                    row.activatable = true;
                    var device = d;
                    row.activated.connect(() => send(sheet, content, device));
                    group.add_row(row);
                    rows += row;
                }
                page.append(group);
                Motion.cascade(rows, Motion.Preset.FADE);
            }
            if (bluetooth.length > 0) {
                var group = new PreferencesGroup(_("Bluetooth"), _("Sent with Bluetooth file transfer."));
                foreach (var dict in bluetooth) {
                    string name = NearbyClient.text_of(dict, "name");
                    string address = NearbyClient.text_of(dict, "address");
                    var row = new ActionRow(name, NearbyClient.flag_of(dict, "connected") ? _("Connected") : _("Paired"));
                    var icon = new Image.from_icon_name(full_icon(NearbyClient.text_of(dict, "icon", "bluetooth-symbolic")));
                    icon.pixel_size = 32;
                    icon.margin_end = 12;
                    row.add_prefix(icon);
                    row.activatable = true;
                    row.activated.connect(() => send_bluetooth(sheet, content, name, address));
                    group.add_row(row);
                }
                page.append(group);
            }
            sheet.show_page(_("Send to a Nearby Device"), page);
        }

        private static string full_icon(string symbolic) {
            string full = symbolic.replace("-symbolic", "");
            var display = Gdk.Display.get_default();
            if (display != null && IconTheme.get_for_display(display).has_icon(full)) return full;
            return "dev.sinty.Nearby";
        }

        private void send(ShareSheet sheet, ShareContent content, NearbyDevice device) {
            var client = NearbyClient.get_default();
            if (content.has_files) {
                var cancel = sheet.begin_work(_("Sending to %s…").printf(device.name), content.summary_title);
                client.share_files.begin(device.id, content.files, (o, r) => {
                    try {
                        string tid = client.share_files.end(r);
                        follow(sheet, tid, device.name, cancel);
                    } catch (Error e) {
                        sheet.show_error(_("Could Not Send"), e.message);
                    }
                });
                return;
            }
            string method = content.has_uris ? "ShareUrl" : "ShareText";
            string payload = content.has_uris ? content.uris[0] : (content.text ?? "");
            client.call.begin(method, new Variant("(ss)", device.id, payload), null, (o, r) => {
                try {
                    client.call.end(r);
                    if (sheet.can_toast) {
                        sheet.toast(new Toast(content.has_uris ? _("Opened on %s").printf(device.name) : _("Sent to %s").printf(device.name)));
                    }
                    sheet.finish();
                } catch (Error e) {
                    sheet.show_error(_("Could Not Send"), e.message);
                }
            });
        }

        private void send_bluetooth(ShareSheet sheet, ShareContent content, string name, string address) {
            var client = NearbyClient.get_default();
            var cancel = sheet.begin_work(_("Sending to %s…").printf(name), content.summary_title);
            client.bluetooth_send_files.begin(address, content.files, (o, r) => {
                try {
                    follow(sheet, client.bluetooth_send_files.end(r), name, cancel);
                } catch (Error e) {
                    sheet.show_error(_("Could Not Send"), e.message);
                }
            });
        }

        private void follow(ShareSheet sheet, string tid, string name, Cancellable cancel) {
            var client = NearbyClient.get_default();
            ulong progress = 0;
            ulong done = 0;
            ulong gone = 0;
            progress = client.transfer_progress.connect((id, d, t) => {
                if (id == tid) sheet.update_fraction(d, t);
            });
            gone = ((Widget) sheet).destroy.connect(() => {
                if (progress != 0) client.disconnect(progress);
                if (done != 0) client.disconnect(done);
                progress = 0;
                done = 0;
            });
            done = client.transfer_finished.connect((id, ok, detail) => {
                if (id != tid) return;
                client.disconnect(progress);
                client.disconnect(done);
                progress = 0;
                done = 0;
                sheet.disconnect(gone);
                if (ok) {
                    sheet.end_work();
                    if (sheet.can_toast) sheet.toast(new Toast(_("Sent to %s").printf(name)));
                    sheet.finish();
                } else {
                    sheet.show_error(_("Could Not Send"), detail);
                }
            });
        }
    }
}
