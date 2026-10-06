using Gtk;
using Singularity.Widgets;

namespace Singularity.Print {

    /**
     * Paper size, orientation and margins for a document, remembered per
     * application and picked up by the print dialog.
     */
    public class PageSetupDialog : AppDialog {
        public JobOptions options { get; private set; }
        public bool applied { get; private set; }

        public signal void finished(bool applied);

        private DropDown paper_drop;
        private string[] paper_keys = {};
        private ToggleButton landscape_btn;
        private DropDown margins_drop;
        private SpinRow[] margin_rows = {};

        public PageSetupDialog(Gtk.Window? parent, JobOptions initial) {
            base(parent != null ? parent.application : (Gtk.Application) GLib.Application.get_default(), parent != null, true);
            transient_for = parent;
            options = initial.copy();
            set_title(_("Page Setup"));
            set_default_size(440, -1);
            resizable = false;
            build();
        }

        private void build() {
            var box = new Box(Orientation.VERTICAL, 18);
            box.margin_start = box.margin_end = 20;
            box.margin_bottom = 18;
            var g = new PreferencesGroup(_("Paper"));
            string[] labels = {};
            uint sel = 0;
            foreach (var k in Media.COMMON) {
                var m = Media.from_keyword(k);
                if (m == null) continue;
                if (k == options.media) sel = paper_keys.length;
                paper_keys += k;
                labels += m.label();
            }
            if (options.media == "") {
                string d = Media.default_keyword();
                for (int i = 0; i < paper_keys.length; i++) if (paper_keys[i] == d) sel = i;
            }
            paper_drop = new DropDown.from_strings(labels);
            paper_drop.valign = Align.CENTER;
            paper_drop.selected = sel;
            paper_drop.update_property(AccessibleProperty.LABEL, _("Paper Size"), -1);
            var prow = new ActionRow(_("Paper Size"));
            prow.add_suffix(paper_drop);
            g.add_row(prow);
            var orient = new Box(Orientation.HORIZONTAL, 4);
            orient.add_css_class("print-orientation");
            orient.valign = Align.CENTER;
            var portrait = new ToggleButton();
            portrait.tooltip_text = _("Portrait");
            portrait.update_property(AccessibleProperty.LABEL, _("Portrait"), -1);
            portrait.add_css_class("singularity-hover-btn");
            var pshape = new Box(Orientation.HORIZONTAL, 0);
            pshape.add_css_class("print-orient-portrait");
            pshape.set_size_request(14, 20);
            pshape.halign = pshape.valign = Align.CENTER;
            portrait.child = pshape;
            landscape_btn = new ToggleButton();
            landscape_btn.tooltip_text = _("Landscape");
            landscape_btn.update_property(AccessibleProperty.LABEL, _("Landscape"), -1);
            landscape_btn.add_css_class("singularity-hover-btn");
            var lshape = new Box(Orientation.HORIZONTAL, 0);
            lshape.add_css_class("print-orient-landscape");
            lshape.set_size_request(20, 14);
            lshape.halign = lshape.valign = Align.CENTER;
            landscape_btn.child = lshape;
            landscape_btn.group = portrait;
            portrait.active = !options.landscape;
            landscape_btn.active = options.landscape;
            orient.append(portrait);
            orient.append(landscape_btn);
            var orow = new ActionRow(_("Orientation"));
            orow.add_suffix(orient);
            g.add_row(orow);
            box.append(g);

            var mg = new PreferencesGroup(_("Margins"));
            margins_drop = new DropDown.from_strings({_("Default"), _("None"), _("Minimum"), _("Custom")});
            margins_drop.valign = Align.CENTER;
            margins_drop.selected = (uint) options.margins;
            margins_drop.update_property(AccessibleProperty.LABEL, _("Margins"), -1);
            var mrow = new ActionRow(_("Margins"));
            mrow.add_suffix(margins_drop);
            mg.add_row(mrow);
            string[] sides = {_("Top"), _("Bottom"), _("Left"), _("Right")};
            double[] values = {options.margin_top, options.margin_bottom, options.margin_left, options.margin_right};
            for (int i = 0; i < 4; i++) {
                var r = new SpinRow(sides[i], _("Millimetres"), 0, 80, 1, values[i]);
                mg.add_row(r);
                margin_rows += r;
            }
            margins_drop.notify["selected"].connect(sync_margins);
            sync_margins();
            box.append(mg);

            var footer = new Box(Orientation.HORIZONTAL, 10);
            footer.halign = Align.END;
            var cancel = add_cancel_button();
            footer.append(cancel);
            var apply = new Button.with_label(_("Apply"));
            apply.add_css_class("suggested-action");
            apply.clicked.connect(() => {
                if (paper_drop.selected < paper_keys.length) options.media = paper_keys[paper_drop.selected];
                options.landscape = landscape_btn.active;
                options.margins = (MarginsMode) margins_drop.selected;
                options.margin_top = margin_rows[0].value;
                options.margin_bottom = margin_rows[1].value;
                options.margin_left = margin_rows[2].value;
                options.margin_right = margin_rows[3].value;
                applied = true;
                finished(true);
                close();
            });
            footer.append(apply);
            box.append(footer);
            content_box.append(box);
            close_request.connect(() => {
                if (!applied) finished(false);
                return false;
            });
        }

        private void sync_margins() {
            foreach (var r in margin_rows) r.visible = margins_drop.selected == MarginsMode.CUSTOM;
        }
    }

    /**
     * Shows Page Setup and stores the result as the application's last
     * used print settings, so the next print dialog starts from it.
     * Returns the chosen page setup, or null when cancelled.
     */
    public async Gtk.PageSetup? page_setup(Gtk.Window? window) {
        string app_id = app_identifier();
        var store = PresetStore.get_default();
        var initial = store.last_used(app_id) ?? new JobOptions();
        var dialog = new PageSetupDialog(window, initial);
        bool ok = false;
        dialog.finished.connect((applied) => {
            ok = applied;
            Idle.add(page_setup.callback);
        });
        dialog.open_dialog();
        yield;
        if (!ok) return null;
        store.remember(app_id, dialog.options);
        return PageFormat.from_options(dialog.options, null).to_page_setup();
    }
}
