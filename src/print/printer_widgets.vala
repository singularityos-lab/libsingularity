using Gtk;
using Singularity.Widgets;

namespace Singularity.Print {

    /**
     * Supply levels as coloured bars, one per marker, using the colours
     * the printer reports.
     */
    public class InkLevels : Box {
        public bool large { get; construct; }

        public InkLevels(bool large = false) {
            Object(orientation: large ? Orientation.VERTICAL : Orientation.HORIZONTAL,
                   spacing: large ? 8 : 3, large: large);
            add_css_class(large ? "print-ink-levels-large" : "print-ink-levels");
        }

        public void set_markers(Gee.List<Marker> markers) {
            var child = get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                remove(child);
                child = next;
            }
            int shown = 0;
            foreach (var m in markers) {
                if (!m.known && !large) continue;
                append(large ? large_row(m) : small_bar(m));
                shown++;
            }
            visible = shown > 0;
        }

        private Widget small_bar(Marker m) {
            var bar = new InkBar(m, false);
            bar.set_size_request(22, 6);
            bar.tooltip_text = "%s %d%%".printf(m.name, m.level);
            return bar;
        }

        private Widget large_row(Marker m) {
            var row = new Box(Orientation.HORIZONTAL, 10);
            var name = new Label(m.name);
            name.xalign = 0;
            name.width_chars = 12;
            name.ellipsize = Pango.EllipsizeMode.END;
            row.append(name);
            var bar = new InkBar(m, true);
            bar.hexpand = true;
            bar.set_size_request(120, 10);
            bar.valign = Align.CENTER;
            row.append(bar);
            var pct = new Label(m.known ? "%d%%".printf(m.level) : _("Unknown"));
            pct.add_css_class("dim-label");
            pct.add_css_class("numeric");
            pct.width_chars = 7;
            pct.xalign = 1;
            if (m.low) pct.add_css_class("warning");
            row.append(pct);
            row.update_property(AccessibleProperty.LABEL,
                                "%s %s".printf(m.name, m.known ? "%d%%".printf(m.level) : _("Unknown")), -1);
            return row;
        }
    }

    public class InkBar : Widget {
        private Marker marker;
        private bool rounded_large;

        public InkBar(Marker marker, bool large) {
            this.marker = marker;
            rounded_large = large;
            add_css_class("print-ink-bar");
        }

        public override void snapshot(Snapshot snapshot) {
            float w = get_width();
            float h = get_height();
            var rect = Graphene.Rect().init(0, 0, w, h);
            var rr = Gsk.RoundedRect();
            rr.init_from_rect(rect, h / 2);
            var fg = get_color();
            snapshot.push_rounded_clip(rr);
            var track = Gdk.RGBA() { red = fg.red, green = fg.green, blue = fg.blue, alpha = 0.12f };
            snapshot.append_color(track, rect);
            if (marker.known) {
                var c = marker.rgba();
                if (c.red > 0.95 && c.green > 0.95 && c.blue > 0.95) c = Gdk.RGBA() { red = 0.8f, green = 0.8f, blue = 0.8f, alpha = 1 };
                float fill = w * marker.level / 100.0f;
                snapshot.append_color(c, Graphene.Rect().init(0, 0, fill, h));
            }
            snapshot.pop();
        }
    }

    /**
     * A printer as a card: full-colour device icon, name, status with a
     * coloured dot, location and supply levels.
     */
    public class PrinterCard : Box {
        public Printer printer { get; private set; }
        private Image icon;
        private Label name_label;
        private Label status_label;
        private Box dot;
        private Label location;
        private InkLevels inks;
        private Image default_star;

        public PrinterCard(Printer printer, int icon_size = 48) {
            Object(orientation: Orientation.HORIZONTAL, spacing: 12);
            add_css_class("print-printer-card");
            icon = new Image.from_icon_name(printer.icon_name);
            icon.pixel_size = icon_size;
            icon.valign = Align.CENTER;
            append(icon);
            var text = new Box(Orientation.VERTICAL, 2);
            text.valign = Align.CENTER;
            text.hexpand = true;
            var title_row = new Box(Orientation.HORIZONTAL, 6);
            name_label = new Label("");
            name_label.add_css_class("heading");
            name_label.xalign = 0;
            name_label.ellipsize = Pango.EllipsizeMode.END;
            name_label.max_width_chars = 26;
            title_row.append(name_label);
            default_star = new Image.from_icon_name("starred-symbolic");
            default_star.add_css_class("print-default-star");
            default_star.tooltip_text = _("Default Printer");
            title_row.append(default_star);
            text.append(title_row);
            var status_row = new Box(Orientation.HORIZONTAL, 6);
            dot = new Box(Orientation.HORIZONTAL, 0);
            dot.add_css_class("print-status-dot");
            dot.valign = Align.CENTER;
            dot.set_size_request(8, 8);
            status_row.append(dot);
            status_label = new Label("");
            status_label.add_css_class("caption");
            status_label.xalign = 0;
            status_label.ellipsize = Pango.EllipsizeMode.END;
            status_row.append(status_label);
            text.append(status_row);
            location = new Label("");
            location.add_css_class("caption");
            location.add_css_class("dim-label");
            location.xalign = 0;
            location.ellipsize = Pango.EllipsizeMode.END;
            text.append(location);
            inks = new InkLevels(false);
            inks.margin_top = 3;
            inks.halign = Align.START;
            text.append(inks);
            append(text);
            update(printer);
        }

        public void update(Printer p) {
            printer = p;
            icon.icon_name = p.icon_name;
            name_label.label = p.display_name;
            status_label.label = p.status_text();
            foreach (var c in new string[] {"ready", "printing", "paused", "offline", "attention", "low"})
                dot.remove_css_class(c);
            dot.add_css_class(p.status == PrinterStatus.READY && p.low_supplies ? "low" : p.status.css_class());
            dot.visible = !p.is_pdf;
            location.label = p.location;
            location.visible = p.location != "";
            default_star.visible = p.is_default;
            inks.set_markers(p.markers);
            update_property(AccessibleProperty.LABEL, "%s, %s".printf(p.display_name, p.status_text()), -1);
        }
    }

    /**
     * The printer chooser at the top of the print dialog: the selected
     * printer as a card, opening a list of all printers, "Save as PDF"
     * first, plus printers found nearby that can be added on the spot.
     */
    public class PrinterPicker : Box {
        public signal void selected(Printer printer);
        public signal void add_requested(DiscoveredPrinter device);

        private Button button;
        private Box current_box;
        private PrinterCard? current_card;
        private Popover popover;
        private ListBox list;
        private ListBox nearby;
        private Label nearby_title;
        private Spinner nearby_spinner;
        private Gee.List<Printer> printers = new Gee.ArrayList<Printer>();
        public bool discovery_enabled { get; set; default = true; }
        private bool discovered;
        private ScrolledWindow scroller;
        private string current_name = "";

        public PrinterPicker() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("print-printer-picker");
            button = new Button();
            button.add_css_class("print-picker-button");
            var inner = new Box(Orientation.HORIZONTAL, 8);
            current_box = new Box(Orientation.HORIZONTAL, 0);
            current_box.hexpand = true;
            inner.append(current_box);
            var arrow = new Image.from_icon_name("pan-down-symbolic");
            arrow.valign = Align.CENTER;
            inner.append(arrow);
            button.child = inner;
            button.tooltip_text = _("Choose Printer");
            append(button);

            popover = new Popover();
            popover.add_css_class("print-picker-popover");
            popover.set_parent(button);
            popover.position = PositionType.BOTTOM;
            var pbox = new Box(Orientation.VERTICAL, 6);
            pbox.margin_top = pbox.margin_bottom = 6;
            pbox.margin_start = pbox.margin_end = 6;
            list = new ListBox();
            list.selection_mode = SelectionMode.NONE;
            list.add_css_class("print-picker-list");
            list.row_activated.connect((row) => {
                int i = row.get_index();
                if (i >= 0 && i < printers.size) {
                    popover.popdown();
                    choose(printers[i]);
                }
            });
            pbox.append(list);
            var nearby_head = new Box(Orientation.HORIZONTAL, 6);
            nearby_head.margin_top = 6;
            nearby_head.margin_start = 8;
            nearby_title = new Label(_("Nearby Printers"));
            nearby_title.add_css_class("heading");
            nearby_title.xalign = 0;
            nearby_title.hexpand = true;
            nearby_head.append(nearby_title);
            nearby_spinner = new Spinner();
            nearby_head.append(nearby_spinner);
            pbox.append(nearby_head);
            nearby = new ListBox();
            nearby.selection_mode = SelectionMode.NONE;
            nearby.add_css_class("print-picker-list");
            pbox.append(nearby);
            var manage = new Button.with_label(_("Printer Settings…"));
            manage.add_css_class("flat");
            manage.halign = Align.START;
            manage.margin_top = 4;
            manage.clicked.connect(() => {
                popover.popdown();
                open_printer_settings();
            });
            pbox.append(manage);
            nearby_head.visible = false;
            nearby.visible = false;
            scroller = new ScrolledWindow();
            scroller.hscrollbar_policy = PolicyType.NEVER;
            scroller.propagate_natural_height = true;
            scroller.max_content_height = 520;
            scroller.min_content_width = 360;
            scroller.child = pbox;
            popover.child = scroller;
            button.clicked.connect(() => {
                scroller.min_content_width = int.max(360, button.get_width() - 24);
                popover.popup();
                if (discovery_enabled && !discovered) {
                    discovered = true;
                    discover.begin(nearby_head);
                }
            });
        }

        public static void open_printer_settings() {
            Bus.get_proxy.begin<Singularity.Shell.ShellService>(BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell",
                                                                DBusProxyFlags.DO_NOT_AUTO_START, null, (o, r) => {
                try {
                    var shell = Bus.get_proxy.end<Singularity.Shell.ShellService>(r);
                    shell.open_settings("printers");
                } catch (Error e) {
                    debug("Cannot open printer settings: %s", e.message);
                }
            });
        }

        public void set_printers(Gee.List<Printer> printers, string? selected_name) {
            this.printers = printers;
            var child = list.get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                list.remove(child);
                child = next;
            }
            Printer? pick = null;
            foreach (var p in printers) {
                var row = new ListBoxRow();
                row.add_css_class("print-picker-row");
                var line = new Box(Orientation.HORIZONTAL, 8);
                var card = new PrinterCard(p, 40);
                card.hexpand = true;
                line.append(card);
                var check = new Image.from_icon_name("object-select-symbolic");
                check.add_css_class("print-picker-check");
                check.valign = Align.CENTER;
                check.opacity = 0;
                line.append(check);
                row.child = line;
                list.append(row);
                if (p.name == selected_name) pick = p;
            }
            if (pick == null) {
                foreach (var p in printers) if (p.is_default) { pick = p; break; }
            }
            if (pick == null && printers.size > 0) pick = printers[0];
            if (pick != null) show_current(pick);
        }

        public void refresh_printer(Printer p) {
            int i = 0;
            var child = list.get_first_child();
            while (child != null) {
                var line = ((ListBoxRow) child).child;
                var card = line != null ? line.get_first_child() as PrinterCard : null;
                if (card != null && card.printer.name == p.name) card.update(p);
                if (i < printers.size && printers[i].name == p.name) printers[i] = p;
                child = child.get_next_sibling();
                i++;
            }
            if (current_card != null && current_card.printer.name == p.name) current_card.update(p);
        }

        private void show_current(Printer p) {
            current_name = p.name;
            var row = list.get_first_child();
            while (row != null) {
                var line = ((ListBoxRow) row).child;
                var card = line != null ? line.get_first_child() as PrinterCard : null;
                var check = line != null ? line.get_last_child() : null;
                if (card != null && check != null) check.opacity = card.printer.name == current_name ? 1 : 0;
                row = row.get_next_sibling();
            }
            if (current_card != null) current_box.remove(current_card);
            current_card = new PrinterCard(p, 48);
            current_box.append(current_card);
        }

        public void choose(Printer p) {
            show_current(p);
            selected(p);
        }

        private async void discover(Box head) {
            var backend = PrinterBackend.get_default();
            if (!backend.can(BackendFeature.ADD_DISCOVERED)) return;
            head.visible = true;
            nearby_spinner.spinning = true;
            Gee.List<DiscoveredPrinter> found;
            try {
                found = yield backend.discover();
            } catch (Error e) {
                found = new Gee.ArrayList<DiscoveredPrinter>();
            }
            nearby_spinner.spinning = false;
            nearby_spinner.visible = false;
            int shown = 0;
            foreach (var d in found) {
                bool known = false;
                foreach (var p in printers) if (p.device_uri == d.uri) known = true;
                if (known || !d.driverless) continue;
                var row = new ListBoxRow();
                row.activatable = false;
                row.add_css_class("print-picker-row");
                var box = new Box(Orientation.HORIZONTAL, 12);
                box.add_css_class("print-printer-card");
                var icon = new Image.from_icon_name(d.icon_name);
                icon.pixel_size = 40;
                box.append(icon);
                var text = new Box(Orientation.VERTICAL, 2);
                text.hexpand = true;
                text.valign = Align.CENTER;
                var n = new Label(d.name);
                n.add_css_class("heading");
                n.xalign = 0;
                n.ellipsize = Pango.EllipsizeMode.END;
                text.append(n);
                var sub = new Label(d.make_model != "" ? d.make_model : _("Driverless"));
                sub.add_css_class("caption");
                sub.add_css_class("dim-label");
                sub.xalign = 0;
                sub.ellipsize = Pango.EllipsizeMode.END;
                text.append(sub);
                box.append(text);
                var add = new Button.with_label(_("Add"));
                add.valign = Align.CENTER;
                add.clicked.connect(() => {
                    popover.popdown();
                    add_requested(d);
                });
                box.append(add);
                row.child = box;
                nearby.append(row);
                shown++;
            }
            nearby.visible = shown > 0;
            head.visible = shown > 0;
        }
    }
}
