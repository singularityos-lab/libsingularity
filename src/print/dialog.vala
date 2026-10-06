using Gtk;
using Singularity.Widgets;

namespace Singularity.Print {

    public enum DialogResult {
        CANCELLED,
        PRINTED,
        SAVED,
        APPLIED
    }

    /**
     * The Singularity print dialog: a large live preview of the imposed
     * sheets beside a compact options panel. Used by applications
     * through `Singularity.Print.run()` and by the print portal, which
     * passes no source and receives the chosen options instead.
     */
    public class PrintDialog : AppDialog {
        public PageSource? source { get; private set; }
        public string app_id { get; private set; }
        public JobOptions options { get; private set; }
        public Printer? printer { get; private set; }
        public PrinterCapabilities? capabilities { get; private set; }
        public DialogResult result { get; private set; default = DialogResult.CANCELLED; }
        public int job_id { get; private set; }
        public string[] saved_files { get; private set; default = {}; }
        public bool apply_only { get; set; }

        public signal void finished(DialogResult result);

        private PreviewStage stage;
        private PrinterPicker picker;
        private SheetRenderer renderer;
        private Gee.List<SheetSide> sides = new Gee.ArrayList<SheetSide>();
        private int n_pages;
        private PageFormat? paginated_format;
        private bool syncing;
        private uint update_source;
        private bool pending_reflow;
        private bool busy;
        private Button print_button;
        private Label summary;
        private Banner banner;
        private DropDown preset_drop;
        private string[] preset_names = {};

        private SpinRow copies_row;
        private SwitchRow collate_row;
        private DropDown range_drop;
        private RangeMode[] range_modes = {};
        private EntryRow range_entry;
        private DropDown pageset_drop;
        private SwitchRow reverse_row;
        private ToggleButton portrait_btn;
        private ToggleButton landscape_btn;
        private DropDown paper_drop;
        private string[] paper_keys = {};
        private DropDown scale_drop;
        private ActionRow scale_action_row;
        private ActionRow nup_action_row;
        private SpinRow scale_row;
        private DropDown nup_drop;
        private ActionRow order_row;
        private DropDown order_drop;
        private SwitchRow borders_row;
        private SwitchRow booklet_row;
        private DropDown margins_drop;
        private SpinRow[] margin_rows = {};
        private PreferencesGroup device_group;
        private ActionRow duplex_row;
        private DropDown duplex_drop;
        private ActionRow color_row;
        private DropDown color_drop;
        private ActionRow quality_row;
        private DropDown quality_drop;
        private int[] quality_values = {};
        private ActionRow source_row;
        private DropDown source_drop;
        private string[] source_keys = {};
        private ActionRow type_row;
        private DropDown type_drop;
        private string[] type_keys = {};
        private DropDown header_drop;
        private DropDown footer_drop;
        private EntryRow watermark_row;
        private SpinRow watermark_opacity;
        private PreferencesGroup output_group;
        private DropDown format_drop;
        private ExpanderRow advanced_row;
        private Gee.ArrayList<Widget> advanced_rows = new Gee.ArrayList<Widget>();
        private ActionRow selection_hint;
        private PreferencesGroup? extras_group;
        private Gee.HashMap<string, Widget> extra_rows = new Gee.HashMap<string, Widget>();
        private bool source_dirty;
        private int[] last_selection = {};

        private const string[] HEADER_TEMPLATES = {"", "{title}", "{date}", "{title}, {date}"};
        private const string[] FOOTER_TEMPLATES = {"", "Page {page} of {pages}", "{page}", "{title}", "{date}"};

        public PrintDialog(Gtk.Window? parent, PageSource? source, JobOptions? initial, string app_id) {
            base(parent != null && parent.application != null ? parent.application
                 : (Gtk.Application) GLib.Application.get_default(), parent != null, true);
            this.source = source;
            this.app_id = app_id;
            ensure_style();
            transient_for = parent;
            modal = parent != null;
            options = initial != null ? initial.copy() : new JobOptions();
            if (source != null && source.imposes_pages) {
                options.pages_per_sheet = 1;
                options.booklet = false;
            }
            if (source != null && source.extra_options != null) source.extra_options.restore(options.app_options);
            build();
        }

        private static bool style_ready;

        private static void ensure_style() {
            if (style_ready || GLib.Application.get_default() is Singularity.Application) return;
            style_ready = true;
            Singularity.Style.StyleManager.pin_brand_themes();
            Singularity.Style.StyleManager.get_default().load_theme();
        }

        private void build() {
            set_title(_("Print"));
            add_css_class("print-dialog");
            set_default_size(1080, 740);
            renderer = new SheetRenderer(source ?? new SampleSource(), options);

            var body = new Box(Orientation.HORIZONTAL, 0);
            body.vexpand = true;
            stage = new PreviewStage();
            body.append(stage);

            var panel = new Box(Orientation.VERTICAL, 0);
            panel.add_css_class("print-panel");
            panel.set_size_request(420, -1);
            panel.hexpand = false;
            var scroller = new ScrolledWindow();
            scroller.hscrollbar_policy = PolicyType.NEVER;
            scroller.vexpand = true;
            var column = new Box(Orientation.VERTICAL, 18);
            column.margin_start = column.margin_end = 18;
            column.margin_top = 6;
            column.margin_bottom = 18;
            scroller.child = column;
            panel.append(scroller);
            body.append(panel);
            content_box.append(body);

            banner = new Banner("", BannerStyle.ERROR);
            banner.visible = false;
            column.append(banner);

            picker = new PrinterPicker();
            picker.selected.connect((p) => select_printer.begin(p));
            picker.add_requested.connect((d) => add_nearby.begin(d));
            column.append(picker);

            column.append(build_presets());
            column.append(build_pages());
            column.append(build_layout());
            if (source != null && source.extra_options != null) column.append(build_extras(source.extra_options));
            device_group = build_device();
            column.append(device_group);
            output_group = build_output();
            column.append(output_group);
            column.append(build_more());

            var footer = new Box(Orientation.HORIZONTAL, 10);
            footer.add_css_class("print-footer");
            summary = new Label("");
            summary.add_css_class("dim-label");
            summary.xalign = 0;
            summary.hexpand = true;
            summary.ellipsize = Pango.EllipsizeMode.END;
            footer.append(summary);
            var cancel = add_cancel_button();
            footer.append(cancel);
            print_button = new Button.with_label(_("Print"));
            print_button.add_css_class("suggested-action");
            print_button.clicked.connect(() => confirm.begin());
            footer.append(print_button);
            panel.append(footer);

            close_request.connect(() => {
                if (result == DialogResult.CANCELLED) finished(result);
                return false;
            });

            sync_widgets();
            update_visibility();
            stage.set_loading();
            load_printers.begin();
        }

        private DropDown drop(string[] labels, string accessible) {
            var d = new DropDown.from_strings(labels);
            d.valign = Align.CENTER;
            d.update_property(AccessibleProperty.LABEL, accessible, -1);
            d.notify["selected"].connect(() => on_changed(d == paper_drop || d == margins_drop));
            return d;
        }

        private ActionRow row_with(PreferencesGroup g, string title, Widget suffix, string? subtitle = null) {
            var row = new ActionRow(title, subtitle);
            row.add_suffix(suffix);
            g.add_row(row);
            return row;
        }

        private Widget build_presets() {
            var g = new PreferencesGroup(_("Presets"));
            preset_drop = new DropDown.from_strings({});
            preset_drop.valign = Align.CENTER;
            preset_drop.update_property(AccessibleProperty.LABEL, _("Preset"), -1);
            var row = new ActionRow(_("Preset"));
            row.add_suffix(preset_drop);
            var save = new Button.from_icon_name("document-save-symbolic");
            save.valign = Align.CENTER;
            save.tooltip_text = _("Save as Preset");
            save.update_property(AccessibleProperty.LABEL, _("Save as Preset"), -1);
            save.clicked.connect(() => save_preset(save));
            row.add_suffix(save);
            g.add_row(row);
            fill_presets();
            preset_drop.notify["selected"].connect(() => {
                if (syncing) return;
                uint i = preset_drop.selected;
                if (i == 0 || i >= preset_names.length + 1) return;
                var p = PresetStore.get_default().load_preset(preset_names[i - 1]);
                if (p == null) return;
                string keep_printer = options.printer;
                int keep_copies = options.copies;
                options.apply(p.to_variant(false));
                options.printer = keep_printer;
                options.copies = keep_copies;
                if (capabilities != null) options.apply_defaults(capabilities);
                sync_widgets();
                schedule(true);
            });
            return g;
        }

        private void fill_presets() {
            syncing = true;
            preset_names = PresetStore.get_default().list_presets();
            string[] labels = {_("Last Used")};
            foreach (var n in preset_names) labels += n;
            preset_drop.model = new StringList(labels);
            preset_drop.selected = 0;
            syncing = false;
        }

        private void save_preset(Widget anchor) {
            var pop = new Popover();
            pop.set_parent(anchor);
            var box = new Box(Orientation.VERTICAL, 8);
            box.margin_start = box.margin_end = box.margin_top = box.margin_bottom = 10;
            var title = new Label(_("Save as Preset"));
            title.add_css_class("heading");
            title.xalign = 0;
            box.append(title);
            var entry = new Entry();
            entry.placeholder_text = _("Preset Name");
            box.append(entry);
            var actions = new Box(Orientation.HORIZONTAL, 6);
            actions.halign = Align.END;
            var ok = new Button.with_label(_("Save"));
            ok.add_css_class("suggested-action");
            ok.sensitive = false;
            entry.changed.connect(() => ok.sensitive = entry.text.strip() != "");
            actions.append(ok);
            box.append(actions);
            pop.child = box;
            ok.clicked.connect(() => {
                string name = entry.text.strip();
                try {
                    PresetStore.get_default().save_preset(name, options);
                    fill_presets();
                    for (int i = 0; i < preset_names.length; i++) if (preset_names[i] == name) preset_drop.selected = i + 1;
                } catch (Error e) {
                    show_error(_("Cannot Save Preset"), e.message);
                }
                pop.popdown();
            });
            entry.activate.connect(() => { if (ok.sensitive) ok.clicked(); });
            pop.closed.connect(() => Idle.add(() => { pop.unparent(); return Source.REMOVE; }));
            pop.popup();
            entry.grab_focus();
        }

        private Widget build_pages() {
            var g = new PreferencesGroup(_("Copies and Pages"));
            copies_row = new SpinRow(_("Copies"), null, 1, 999, 1, 1);
            copies_row.spin_btn.value_changed.connect(() => on_changed(false));
            g.add_row(copies_row);
            collate_row = new SwitchRow(_("Collate"), _("Keep each copy together"), true);
            collate_row.switch_btn.notify["active"].connect(() => on_changed(false));
            g.add_row(collate_row);
            string[] range_labels = {_("All Pages")};
            range_modes = {RangeMode.ALL};
            if (source != null && source.current_page >= 0) {
                range_labels += _("Current Page");
                range_modes += RangeMode.CURRENT;
            }
            if (source != null && source.has_selection) {
                range_labels += _("Selection");
                range_modes += RangeMode.SELECTION;
            }
            range_labels += _("Custom Range");
            range_modes += RangeMode.CUSTOM;
            range_drop = drop(range_labels, _("Pages"));
            row_with(g, _("Pages"), range_drop);
            range_entry = new EntryRow(_("Range"));
            range_entry.entry_changed.connect(() => on_changed(false));
            g.add_row(range_entry);
            selection_hint = new ActionRow(_("Selection"), _("Only the selected content is printed"));
            selection_hint.visible = false;
            pageset_drop = drop({_("All Sheets"), _("Odd Sheets Only"), _("Even Sheets Only")}, _("Print"));
            row_with(g, _("Print"), pageset_drop);
            reverse_row = new SwitchRow(_("Reverse Order"), _("Last sheet first"), false);
            reverse_row.switch_btn.notify["active"].connect(() => on_changed(false));
            g.add_row(reverse_row);
            return g;
        }

        private Widget build_layout() {
            var g = new PreferencesGroup(_("Layout"));
            var orient = new Box(Orientation.HORIZONTAL, 4);
            orient.add_css_class("print-orientation");
            orient.valign = Align.CENTER;
            portrait_btn = new ToggleButton();
            portrait_btn.child = orientation_icon(false);
            portrait_btn.tooltip_text = _("Portrait");
            portrait_btn.update_property(AccessibleProperty.LABEL, _("Portrait"), -1);
            portrait_btn.add_css_class("singularity-hover-btn");
            landscape_btn = new ToggleButton();
            landscape_btn.child = orientation_icon(true);
            landscape_btn.tooltip_text = _("Landscape");
            landscape_btn.update_property(AccessibleProperty.LABEL, _("Landscape"), -1);
            landscape_btn.add_css_class("singularity-hover-btn");
            landscape_btn.group = portrait_btn;
            portrait_btn.toggled.connect(() => on_changed(true));
            landscape_btn.toggled.connect(() => on_changed(true));
            orient.append(portrait_btn);
            orient.append(landscape_btn);
            row_with(g, _("Orientation"), orient);
            paper_drop = drop({}, _("Paper Size"));
            row_with(g, _("Paper Size"), paper_drop);
            scale_drop = drop({_("Fit to Page"), _("Actual Size"), _("Custom")}, _("Scale"));
            scale_action_row = row_with(g, _("Scale"), scale_drop);
            scale_row = new SpinRow(_("Custom Scale"), _("Percent of actual size"), 10, 400, 5, 100);
            scale_row.spin_btn.value_changed.connect(() => on_changed(false));
            g.add_row(scale_row);
            string[] nups = {};
            foreach (var n in Imposition.PAGES_PER_SHEET) nups += n.to_string();
            nup_drop = drop(nups, _("Pages per Sheet"));
            nup_action_row = row_with(g, _("Pages per Sheet"), nup_drop);
            order_drop = drop({_("Across, Then Down"), _("Across Right to Left"), _("Down, Then Across"),
                               _("Down Right to Left")}, _("Page Order"));
            order_row = row_with(g, _("Page Order"), order_drop);
            borders_row = new SwitchRow(_("Page Borders"), null, false);
            borders_row.switch_btn.notify["active"].connect(() => on_changed(false));
            g.add_row(borders_row);
            booklet_row = new SwitchRow(_("Booklet"), _("Folds into a book, printed on both sides"), false);
            booklet_row.switch_btn.notify["active"].connect(() => on_changed(false));
            g.add_row(booklet_row);
            return g;
        }

        private Widget build_extras(ExtraOptions extras) {
            extras_group = new PreferencesGroup(extras.title != "" ? extras.title : _("Document Options"),
                                                extras.description != "" ? extras.description : null);
            foreach (var o in extras.items) {
                Widget row;
                string key = o.key;
                switch (o.kind) {
                    case ExtraKind.SWITCH:
                        var sw = new SwitchRow(o.title, o.subtitle != "" ? o.subtitle : null, extras.get_bool(key));
                        sw.switch_btn.notify["active"].connect(() => {
                            if (!syncing) extras.set_bool(key, sw.active);
                        });
                        row = sw;
                        break;
                    case ExtraKind.CHOICE:
                        var d = new DropDown.from_strings(o.choice_labels);
                        d.valign = Align.CENTER;
                        d.update_property(AccessibleProperty.LABEL, o.title, -1);
                        d.selected = o.choice_index();
                        string[] ids = o.choice_ids;
                        d.notify["selected"].connect(() => {
                            if (!syncing && d.selected < ids.length) extras.set_choice(key, ids[d.selected]);
                        });
                        var ar = new ActionRow(o.title, o.subtitle != "" ? o.subtitle : null);
                        ar.add_suffix(d);
                        row = ar;
                        break;
                    case ExtraKind.NUMBER:
                        var sp = new SpinRow(o.title, o.subtitle != "" ? o.subtitle : null, o.min, o.max, o.step,
                                             extras.get_number(key));
                        sp.spin_btn.digits = o.digits;
                        sp.spin_btn.value_changed.connect(() => {
                            if (!syncing) extras.set_number(key, sp.value);
                        });
                        row = sp;
                        break;
                    default:
                        row = new ActionRow(o.title, o.subtitle);
                        break;
                }
                extras_group.add_row(row);
                extra_rows[key] = row;
            }
            extras.changed.connect((key, reflow) => {
                extras.store(options.app_options);
                update_extra_visibility();
                if (reflow) source_dirty = true;
                schedule(reflow);
            });
            update_extra_visibility();
            return extras_group;
        }

        private void update_extra_visibility() {
            if (source == null || source.extra_options == null) return;
            foreach (var e in extra_rows.entries) e.value.visible = source.extra_options.is_visible(e.key);
        }

        private Widget orientation_icon(bool landscape) {
            var box = new Box(Orientation.HORIZONTAL, 0);
            box.add_css_class(landscape ? "print-orient-landscape" : "print-orient-portrait");
            box.halign = Align.CENTER;
            box.valign = Align.CENTER;
            box.set_size_request(landscape ? 20 : 14, landscape ? 14 : 20);
            return box;
        }

        private PreferencesGroup build_device() {
            var g = new PreferencesGroup(_("Printer Options"));
            duplex_drop = drop({_("Off"), _("Long Edge"), _("Short Edge")}, _("Two-Sided"));
            duplex_row = row_with(g, _("Two-Sided"), duplex_drop);
            color_drop = drop({_("Color"), _("Grayscale")}, _("Color"));
            color_row = row_with(g, _("Color"), color_drop);
            quality_drop = drop({}, _("Quality"));
            quality_row = row_with(g, _("Quality"), quality_drop);
            source_drop = drop({}, _("Paper Source"));
            source_row = row_with(g, _("Paper Source"), source_drop);
            type_drop = drop({}, _("Paper Type"));
            type_row = row_with(g, _("Paper Type"), type_drop);
            return g;
        }

        private PreferencesGroup build_output() {
            var g = new PreferencesGroup(_("Output"));
            format_drop = drop({_("PDF Document"), _("PNG Images")}, _("Format"));
            row_with(g, _("Format"), format_drop);
            return g;
        }

        private Widget build_more() {
            var g = new PreferencesGroup(_("More Options"));
            var margins = new ExpanderRow(_("Margins"), null, "view-fullscreen-symbolic");
            margins_drop = drop({_("Default"), _("None"), _("Minimum"), _("Custom")}, _("Margins"));
            var mrow = new ActionRow(_("Margins"));
            mrow.add_suffix(margins_drop);
            margins.add_row(mrow);
            string[] sides = {_("Top"), _("Bottom"), _("Left"), _("Right")};
            foreach (var s in sides) {
                var r = new SpinRow(s, _("Millimetres"), 0, 80, 1, 10);
                r.spin_btn.value_changed.connect(() => on_changed(true));
                margins.add_row(r);
                margin_rows += r;
            }
            g.add_row(margins);

            var deco = new ExpanderRow(_("Headers and Footers"), null, "format-justify-center-symbolic");
            header_drop = drop({_("None"), _("Title"), _("Date"), _("Title and Date")}, _("Header"));
            var hrow = new ActionRow(_("Header"));
            hrow.add_suffix(header_drop);
            deco.add_row(hrow);
            footer_drop = drop({_("None"), _("Page Number of Total"), _("Page Number"), _("Title"), _("Date")}, _("Footer"));
            var frow = new ActionRow(_("Footer"));
            frow.add_suffix(footer_drop);
            deco.add_row(frow);
            g.add_row(deco);

            var mark = new ExpanderRow(_("Watermark"), null, "insert-text-symbolic");
            watermark_row = new EntryRow(_("Text"));
            watermark_row.entry_changed.connect(() => on_changed(false));
            mark.add_row(watermark_row);
            watermark_opacity = new SpinRow(_("Opacity"), _("Percent"), 5, 100, 5, 15);
            watermark_opacity.spin_btn.value_changed.connect(() => on_changed(false));
            mark.add_row(watermark_opacity);
            g.add_row(mark);

            advanced_row = new ExpanderRow(_("Printer Features"), _("Options offered by this printer"), "preferences-other-symbolic");
            advanced_row.visible = false;
            g.add_row(advanced_row);
            return g;
        }

        private void sync_widgets() {
            syncing = true;
            copies_row.value = options.copies;
            collate_row.active = options.collate;
            range_drop.selected = 0;
            for (uint i = 0; i < range_modes.length; i++) if (range_modes[i] == options.range_mode) range_drop.selected = i;
            range_entry.text = options.ranges;
            pageset_drop.selected = (uint) options.page_set;
            reverse_row.active = options.reverse;
            portrait_btn.active = !options.landscape;
            landscape_btn.active = options.landscape;
            scale_drop.selected = (uint) options.scale_mode;
            scale_row.value = options.scale;
            for (int i = 0; i < Imposition.PAGES_PER_SHEET.length; i++)
                if (Imposition.PAGES_PER_SHEET[i] == options.pages_per_sheet) nup_drop.selected = i;
            order_drop.selected = (uint) options.nup_order;
            borders_row.active = options.borders;
            booklet_row.active = options.booklet;
            margins_drop.selected = (uint) options.margins;
            margin_rows[0].value = options.margin_top;
            margin_rows[1].value = options.margin_bottom;
            margin_rows[2].value = options.margin_left;
            margin_rows[3].value = options.margin_right;
            duplex_drop.selected = (uint) options.duplex;
            color_drop.selected = options.grayscale ? 1 : 0;
            format_drop.selected = (uint) options.output_format;
            header_drop.selected = index_of(HEADER_TEMPLATES, options.header);
            footer_drop.selected = 0;
            for (uint i = 0; i < FOOTER_TEMPLATES.length; i++) if (footer_template(i) == options.footer) footer_drop.selected = i;
            watermark_row.text = options.watermark;
            watermark_opacity.value = options.watermark_opacity;
            sync_device_lists();
            syncing = false;
        }

        private uint index_of(string[] list, string v) {
            for (int i = 0; i < list.length; i++) if (list[i] == v) return i;
            return 0;
        }

        private void sync_device_lists() {
            var caps = capabilities ?? PrinterCapabilities.for_pdf();
            string[] labels = {};
            paper_keys = {};
            uint sel = 0;
            foreach (var m in caps.media) {
                if (m.keyword == options.media) sel = paper_keys.length;
                paper_keys += m.keyword;
                labels += m.label();
            }
            paper_drop.model = new StringList(labels);
            paper_drop.selected = sel;

            labels = {};
            quality_values = {};
            int[] qs = caps.qualities.length > 0 ? caps.qualities : new int[] {3, 4, 5};
            sel = 0;
            foreach (var q in qs) {
                if (q == options.quality) sel = quality_values.length;
                quality_values += q;
                labels += Options.quality_label(q);
            }
            quality_drop.model = new StringList(labels);
            quality_drop.selected = sel;

            labels = {_("Automatic")};
            source_keys = {""};
            sel = 0;
            foreach (var s in caps.sources) {
                if (s == "auto") continue;
                if (s == options.media_source) sel = source_keys.length;
                source_keys += s;
                labels += Options.humanize(s);
            }
            source_drop.model = new StringList(labels);
            source_drop.selected = sel;

            labels = {_("Automatic")};
            type_keys = {""};
            sel = 0;
            foreach (var t in caps.media_types) {
                if (t == "auto") continue;
                if (t == options.media_type) sel = type_keys.length;
                type_keys += t;
                labels += Options.humanize(t);
            }
            type_drop.model = new StringList(labels);
            type_drop.selected = sel;
            rebuild_advanced(caps);
        }

        private void rebuild_advanced(PrinterCapabilities caps) {
            advanced_rows.clear();
            advanced_row.clear_rows();
            foreach (var extra in caps.extras) {
                string[] labels = {_("Printer Default")};
                foreach (var v in extra.values) labels += Options.humanize(v);
                var d = new DropDown.from_strings(labels);
                d.valign = Align.CENTER;
                d.update_property(AccessibleProperty.LABEL, extra.label(), -1);
                string current = options.extras.lookup(extra.name) ?? "";
                for (int i = 0; i < extra.values.length; i++) if (extra.values[i] == current) d.selected = i + 1;
                string name = extra.name;
                string[] values = extra.values;
                d.notify["selected"].connect(() => {
                    if (syncing) return;
                    if (d.selected == 0) options.extras.remove(name);
                    else options.extras.insert(name, values[d.selected - 1]);
                });
                var row = new ActionRow(extra.label());
                row.add_suffix(d);
                advanced_row.add_row(row);
                advanced_rows.add(row);
            }
            advanced_row.visible = advanced_rows.size > 0 && printer != null && !printer.is_pdf;
        }

        private void read_widgets() {
            options.copies = (int) copies_row.value;
            options.collate = collate_row.active;
            if (range_drop.selected < range_modes.length) options.range_mode = range_modes[range_drop.selected];
            options.ranges = range_entry.text;
            options.page_set = (PageSet) pageset_drop.selected;
            options.reverse = reverse_row.active;
            options.landscape = landscape_btn.active;
            if (paper_drop.selected < paper_keys.length) options.media = paper_keys[paper_drop.selected];
            options.scale_mode = (ScaleMode) scale_drop.selected;
            options.scale = (int) scale_row.value;
            if (nup_drop.selected < Imposition.PAGES_PER_SHEET.length)
                options.pages_per_sheet = Imposition.PAGES_PER_SHEET[nup_drop.selected];
            options.nup_order = (NupOrder) order_drop.selected;
            options.borders = borders_row.active;
            options.booklet = booklet_row.active;
            options.margins = (MarginsMode) margins_drop.selected;
            options.margin_top = margin_rows[0].value;
            options.margin_bottom = margin_rows[1].value;
            options.margin_left = margin_rows[2].value;
            options.margin_right = margin_rows[3].value;
            options.duplex = (Duplex) duplex_drop.selected;
            options.grayscale = color_drop.selected == 1;
            if (quality_drop.selected < quality_values.length) options.quality = quality_values[quality_drop.selected];
            if (source_drop.selected < source_keys.length) options.media_source = source_keys[source_drop.selected];
            if (type_drop.selected < type_keys.length) options.media_type = type_keys[type_drop.selected];
            options.output_format = (OutputFormat) format_drop.selected;
            if (header_drop.selected < HEADER_TEMPLATES.length) options.header = header_template(header_drop.selected);
            if (footer_drop.selected < FOOTER_TEMPLATES.length) options.footer = footer_template(footer_drop.selected);
            options.watermark = watermark_row.text;
            options.watermark_opacity = (int) watermark_opacity.value;
        }

        private string header_template(uint i) {
            return HEADER_TEMPLATES[i];
        }

        private string footer_template(uint i) {
            if (i == 1) return _("Page {page} of {pages}");
            return FOOTER_TEMPLATES[i];
        }

        private void update_visibility() {
            bool pdf = printer != null && printer.is_pdf;
            bool portal = source == null;
            range_entry.visible = options.range_mode == RangeMode.CUSTOM;
            var caps = capabilities ?? PrinterCapabilities.for_pdf();
            collate_row.visible = options.copies > 1;
            copies_row.visible = !pdf || portal;
            bool own = source != null && source.imposes_pages;
            scale_row.visible = options.scale_mode == ScaleMode.CUSTOM && options.pages_per_sheet == 1 && !options.booklet;
            scale_action_row.visible = options.pages_per_sheet == 1 && !options.booklet;
            order_row.visible = options.pages_per_sheet > 1 && !options.booklet && !own;
            borders_row.visible = (options.pages_per_sheet > 1 || options.booklet) && !own;
            nup_action_row.visible = !options.booklet && !own;
            booklet_row.visible = !own;
            foreach (var r in margin_rows) r.visible = options.margins == MarginsMode.CUSTOM;
            device_group.visible = !pdf;
            duplex_row.visible = caps.supports_duplex && !options.booklet;
            color_row.visible = caps.supports_color || pdf;
            quality_row.visible = caps.qualities.length > 1;
            source_row.visible = source_keys.length > 1;
            type_row.visible = type_keys.length > 1;
            output_group.visible = pdf && !portal;
            print_button.label = apply_only ? _("Print") : pdf ? _("Save") : _("Print");
        }

        private void on_changed(bool reflow) {
            if (syncing) return;
            read_widgets();
            update_visibility();
            schedule(reflow);
        }

        private void schedule(bool reflow) {
            if (reflow) pending_reflow = true;
            if (update_source != 0) Source.remove(update_source);
            update_source = Timeout.add(90, () => {
                update_source = 0;
                bool r = pending_reflow;
                pending_reflow = false;
                refresh.begin(r);
                return Source.REMOVE;
            });
        }

        private int generation;

        private async void refresh(bool reflow) {
            int gen = ++generation;
            var format = PageFormat.from_options(options, capabilities);
            var src = source ?? renderer.source;
            bool again = source_dirty;
            if (src.imposes_pages) {
                string? problem;
                int[] wanted = document_selection(src, out problem);
                if (!same_pages(wanted, last_selection)) again = true;
                src.page_selection = wanted;
                last_selection = wanted;
            }
            if (paginated_format == null || again || (reflow && src.can_reflow && !format.same_layout(paginated_format))) {
                stage.set_loading();
                source_dirty = false;
                try {
                    src.print_selection = options.range_mode == RangeMode.SELECTION;
                    n_pages = yield src.paginate(format);
                    paginated_format = format;
                } catch (Error e) {
                    if (gen != generation) return;
                    stage.set_message(_("Cannot Prepare the Document"), e.message);
                    print_button.sensitive = false;
                    return;
                }
                if (gen != generation) return;
            }
            impose(format);
        }

        private static bool same_pages(int[] a, int[] b) {
            if (a.length != b.length) return false;
            for (int i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
            return true;
        }

        private int[] document_selection(PageSource src, out string? problem) {
            int saved = n_pages;
            if (src.document_pages >= 0) n_pages = src.document_pages;
            var pages = selected_pages(out problem);
            n_pages = saved;
            return pages;
        }

        private int[] selected_pages(out string? problem) {
            problem = null;
            int[] pages = {};
            switch (options.range_mode) {
                case RangeMode.CURRENT:
                    int cp = source != null ? source.current_page : 0;
                    if (cp >= 0 && cp < n_pages) pages += cp;
                    break;
                case RangeMode.CUSTOM:
                    try {
                        pages = PageRanges.parse(options.ranges, n_pages);
                    } catch (PrintError e) {
                        problem = e.message;
                    }
                    break;
                default:
                    for (int i = 0; i < n_pages; i++) pages += i;
                    break;
            }
            return pages;
        }

        private void impose(PageFormat format) {
            string? problem;
            var src = source ?? renderer.source;
            int[] pages;
            if (src.imposes_pages) {
                document_selection(src, out problem);
                pages = {};
                if (problem == null) for (int i = 0; i < n_pages; i++) pages += i;
            } else {
                pages = selected_pages(out problem);
            }
            range_entry.subtitle = problem ?? "";
            if (problem != null) range_entry.add_css_class("error");
            else range_entry.remove_css_class("error");
            var spec = new LayoutSpec();
            spec.page_width = src.page_width;
            spec.page_height = src.page_height;
            spec.sheet_width = format.width;
            spec.sheet_height = format.height;
            spec.pages_per_sheet = src.imposes_pages ? 1 : options.pages_per_sheet;
            spec.order = options.nup_order;
            spec.scale_mode = options.scale_mode;
            spec.scale_percent = options.scale;
            spec.booklet = options.booklet && !src.imposes_pages;
            spec.page_set = options.page_set;
            spec.reverse = options.reverse;
            spec.gutter = options.pages_per_sheet > 1 ? 6 : 0;
            sides = Imposition.impose(pages, spec);
            renderer.options = options;
            renderer.total_pages = n_pages;
            if (sides.size == 0) {
                stage.set_message(_("Nothing to Print"), problem ?? _("No pages match these settings"));
            } else {
                stage.set_sides(renderer, sides);
            }
            update_summary();
            print_button.sensitive = !busy && sides.size > 0 && printer != null;
        }

        private void update_summary() {
            if (sides.size == 0) {
                summary.label = "";
                return;
            }
            bool pdf = printer == null || printer.is_pdf;
            if (source == null) {
                summary.label = "";
            } else if (pdf) {
                summary.label = ngettext("%d page", "%d pages", sides.size).printf(sides.size);
            } else {
                int sheets = Imposition.physical_sheets(sides.size, options.duplexed, options.copies);
                summary.label = ngettext("%d sheet of paper", "%d sheets of paper", sheets).printf(sheets);
            }
        }

        private async void load_printers() {
            var list = new Gee.ArrayList<Printer>();
            list.add(Printer.save_as_pdf());
            var backend = PrinterBackend.get_default();
            try {
                foreach (var p in yield backend.list_printers()) list.add(p);
            } catch (Error e) {
                debug("Printers unavailable: %s", e.message);
            }
            picker.set_printers(list, options.printer != "" ? options.printer : null);
            Printer? pick = null;
            foreach (var p in list) if (p.name == options.printer) pick = p;
            if (pick == null) foreach (var p in list) if (p.is_default) { pick = p; break; }
            if (pick == null) pick = list.size > 1 ? list[1] : list[0];
            picker.choose(pick);
        }

        private async void select_printer(Printer p) {
            printer = p;
            options.printer = p.is_pdf ? "" : p.name;
            banner.visible = false;
            try {
                capabilities = yield PrinterBackend.get_default().capabilities(p.name);
            } catch (Error e) {
                capabilities = PrinterCapabilities.for_pdf();
                capabilities.color_modes = {"color", "monochrome"};
                if (!p.is_pdf) show_error(_("Printer Details Unavailable"), e.message);
            }
            if (p.status == PrinterStatus.OFFLINE)
                show_warning(_("This printer is offline. The job waits in the queue until it is back."));
            else if (p.attention_reason() != null)
                show_warning(p.attention_reason());
            options.apply_defaults(capabilities);
            if (p.is_pdf) options.printer = Printer.PDF_PRINTER;
            sync_widgets();
            update_visibility();
            schedule(true);
        }

        private async void add_nearby(DiscoveredPrinter d) {
            var backend = PrinterBackend.get_default();
            busy = true;
            print_button.sensitive = false;
            try {
                yield backend.add_discovered(d, d.name);
                yield load_printers();
                foreach (var p in yield backend.list_printers()) {
                    if (p.device_uri == d.uri) {
                        picker.choose(p);
                        break;
                    }
                }
            } catch (Error e) {
                show_error(_("Cannot Add Printer"), e.message);
            }
            busy = false;
            print_button.sensitive = sides.size > 0;
        }

        private void show_error(string title, string message) {
            banner.style = BannerStyle.ERROR;
            banner.title = "%s: %s".printf(title, message);
            banner.visible = true;
        }

        private void show_warning(string message) {
            banner.style = BannerStyle.WARNING;
            banner.title = message;
            banner.visible = true;
        }

        private async void confirm() {
            if (printer == null || sides.size == 0) return;
            read_widgets();
            PresetStore.get_default().remember(app_id, options);
            if (apply_only) {
                if (printer.is_pdf) {
                    string? path = yield choose_path(false);
                    if (path == null) return;
                    options.output_path = path;
                }
                result = DialogResult.APPLIED;
                finish();
                return;
            }
            busy = true;
            print_button.sensitive = false;
            if (printer.is_pdf) {
                yield save_to_file();
            } else {
                yield send_to_printer();
            }
            busy = false;
            if (result != DialogResult.CANCELLED) finish();
            else print_button.sensitive = true;
        }

        private void finish() {
            finished(result);
            close();
        }

        private async string? choose_path(bool png) {
            var fd = new FileDialog();
            fd.title = png ? _("Save as Images") : _("Save as PDF");
            string base_name = source != null && source.title != "" ? source.title : _("Document");
            foreach (var ext in new string[] {".pdf", ".odt", ".md", ".txt", ".docx", ".ods", ".odp", ".xlsx", ".pptx"})
                if (base_name.down().has_suffix(ext)) base_name = base_name.substring(0, base_name.length - ext.length);
            fd.initial_name = base_name + (png ? ".png" : ".pdf");
            try {
                var file = yield fd.save(this, null);
                return file.get_path();
            } catch (Error e) {
                return null;
            }
        }

        private async void save_to_file() {
            bool png = options.output_format == OutputFormat.PNG;
            string? target = options.output_path != "" ? options.output_path : yield choose_path(png);
            if (target == null) return;
            try {
                if (png) {
                    saved_files = renderer.write_png(target, sides);
                } else {
                    renderer.write_pdf(target, sides);
                    saved_files = {target};
                }
                result = DialogResult.SAVED;
            } catch (Error e) {
                show_error(_("Cannot Save"), e.message);
            }
        }

        private async void send_to_printer() {
            string dir = Path.build_filename(Environment.get_user_cache_dir(), "singularity", "print");
            DirUtils.create_with_parents(dir, 0700);
            string path = Path.build_filename(dir, "job-%s.pdf".printf(Uuid.string_random()));
            try {
                renderer.write_pdf(path, sides);
                string title = source != null && source.title != "" ? source.title : _("Document");
                job_id = yield PrinterBackend.get_default().submit(printer.name, path, title, options, capabilities);
                result = DialogResult.PRINTED;
                JobWatcher.get_default().watch(printer, job_id, title);
            } catch (PrintError.NOT_AUTHORIZED e) {
                show_error(_("Not Allowed to Print"), e.message);
            } catch (Error e) {
                show_error(_("Cannot Print"), e.message);
            }
            FileUtils.remove(path);
        }
    }

    /**
     * Stand-in pages for the portal, where the application renders the
     * document only after the dialog closes: numbered sheets with text
     * lines, enough to show layout, n-up, order and decorations.
     */
    public class SampleSource : PageSource {
        private PageFormat format = new PageFormat();

        public SampleSource() {
            title = _("Document");
        }

        public override async int paginate(PageFormat format) throws Error {
            this.format = format;
            page_width = format.width;
            page_height = format.height;
            return 4;
        }

        public override void render_page(Cairo.Context cr, int index) {
            double x = format.margin_left;
            double y = format.margin_top;
            double w = format.content_width;
            double h = format.content_height;
            cr.set_source_rgb(0.84, 0.86, 0.9);
            double line = y + 34;
            cr.rectangle(x, y, w * 0.55, 16);
            cr.fill();
            int i = 0;
            while (line < y + h - 12) {
                double len = (i % 5 == 4) ? 0.6 : 0.95 - (i % 3) * 0.04;
                cr.set_source_rgb(0.88, 0.9, 0.93);
                cr.rectangle(x, line, w * len, 6);
                cr.fill();
                line += 13;
                i++;
            }
            var layout = Pango.cairo_create_layout(cr);
            var font = Pango.FontDescription.from_string("Sans Bold");
            font.set_absolute_size(double.min(w, h) * 0.32 * Pango.SCALE);
            layout.set_font_description(font);
            layout.set_text((index + 1).to_string(), -1);
            int lw, lh;
            layout.get_pixel_size(out lw, out lh);
            cr.move_to(x + (w - lw) / 2, y + (h - lh) / 2);
            cr.set_source_rgba(0.35, 0.45, 0.6, 0.55);
            Pango.cairo_show_layout(cr, layout);
        }
    }
}
