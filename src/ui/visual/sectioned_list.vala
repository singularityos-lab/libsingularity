using Gtk;

namespace Singularity.Widgets {

    public class SectionedList : Box {

        public signal void selected(string id);

        private Singularity.Widgets.SearchEntry search;
        private ScrolledWindow scroll;
        private Box content;
        private Overlay overlay;
        private Label sticky;

        private Label[] headers = {};
        private string[] header_titles = {};
        private Box[] section_boxes = {};

        private Button[] rows = {};
        private Image[] row_checks = {};
        private string[] row_ids = {};
        private string[] row_text = {};
        private int[] row_section = {};
        private int sel_index = -1;

        public string? selected_id {
            get { return sel_index >= 0 ? row_ids[sel_index] : null; }
        }

        public SectionedList() {
            Object(orientation: Orientation.VERTICAL, spacing: 8);

            search = new Singularity.Widgets.SearchEntry();
            search.placeholder_text = "Search";
            search.add_css_class("singularity-section-search");
            search.search_changed.connect(apply_filter);
            append(search);

            content = new Box(Orientation.VERTICAL, 0);
            content.hexpand = true;

            scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vscrollbar_policy = PolicyType.AUTOMATIC;
            scroll.set_child(content);
            scroll.hexpand = true;
            scroll.vexpand = true;
            scroll.set_size_request(-1, 280);

            sticky = new Label("");
            sticky.add_css_class("singularity-section-sticky");
            sticky.xalign = 0;
            sticky.halign = Align.FILL;
            sticky.valign = Align.START;
            sticky.margin_start = 5;
            sticky.margin_end = 5;
            sticky.margin_top = 2;
            sticky.visible = false;

            overlay = new Overlay();
            overlay.set_child(scroll);
            overlay.add_overlay(sticky);
            overlay.hexpand = true;
            overlay.vexpand = true;
            append(overlay);

            scroll.vadjustment.value_changed.connect(update_sticky);
            map.connect(() => Idle.add(() => { update_sticky(); return false; }));
        }

        public void add_section(string title) {
            var header = new Label(title);
            header.add_css_class("singularity-section-header");
            header.xalign = 0;
            header.halign = Align.FILL;
            content.append(header);

            var box = new Box(Orientation.VERTICAL, 2);
            content.append(box);

            headers += header;
            header_titles += title;
            section_boxes += box;
        }

        public void add_item(string id, string label, string? subtitle = null) {
            if (section_boxes.length == 0) return;
            int sec = section_boxes.length - 1;
            int index = rows.length;
            var box = section_boxes[sec];

            var btn = new Button();
            btn.has_frame = false;
            btn.add_css_class("singularity-section-row");

            var hb = new Box(Orientation.HORIZONTAL, 8);
            var text = new Box(Orientation.VERTICAL, 1);
            text.hexpand = true;
            var lbl = new Label(label);
            lbl.xalign = 0;
            lbl.halign = Align.START;
            text.append(lbl);
            if (subtitle != null && subtitle != "") {
                var sub = new Label(subtitle);
                sub.add_css_class("dim-label");
                sub.add_css_class("caption");
                sub.xalign = 0;
                sub.halign = Align.START;
                text.append(sub);
            }
            hb.append(text);

            var check = new Image.from_icon_name("object-select-symbolic");
            check.add_css_class("accent-color");
            check.valign = Align.CENTER;
            check.visible = false;
            hb.append(check);

            btn.set_child(hb);
            btn.clicked.connect(() => select_row(index));
            box.append(btn);

            rows += btn;
            row_checks += check;
            row_ids += id;
            row_text += (label + " " + (subtitle ?? "")).down();
            row_section += sec;
        }

        private void select_row(int idx) {
            for (int i = 0; i < rows.length; i++) {
                bool s = (i == idx);
                row_checks[i].visible = s;
                if (s) rows[i].add_css_class("selected");
                else rows[i].remove_css_class("selected");
            }
            sel_index = idx;
            selected(row_ids[idx]);
        }

        private void apply_filter() {
            string q = search.text.down().strip();
            var seen = new bool[section_boxes.length];

            for (int i = 0; i < rows.length; i++) {
                bool match = q == "" || q in row_text[i];
                rows[i].visible = match;
                if (match) seen[row_section[i]] = true;
            }
            for (int s = 0; s < section_boxes.length; s++) {
                headers[s].visible = seen[s];
                section_boxes[s].visible = seen[s];
            }
            Idle.add(() => { update_sticky(); return false; });
        }

        private void update_sticky() {
            double v = scroll.vadjustment.value;
            int active = -1;
            for (int i = 0; i < headers.length; i++) {
                if (!headers[i].visible) continue;
                Gtk.Allocation a;
                headers[i].get_allocation(out a);
                if (a.y <= v) active = i;
                else break;
            }
            if (active >= 0) {
                Gtk.Allocation a;
                headers[active].get_allocation(out a);
                if (a.y < v - 1) {
                    sticky.label = header_titles[active];
                    sticky.visible = true;
                    return;
                }
            }
            sticky.visible = false;
        }
    }
}
