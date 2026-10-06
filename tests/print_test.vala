using Singularity.Print;

void check_ranges() {
    try {
        var p = PageRanges.parse("1-3, 7", 10);
        assert(p.length == 4 && p[0] == 0 && p[2] == 2 && p[3] == 6);
        p = PageRanges.parse("8-", 10);
        assert(p.length == 3 && p[0] == 7 && p[2] == 9);
        p = PageRanges.parse("-2;5", 10);
        assert(p.length == 3 && p[0] == 0 && p[1] == 1 && p[2] == 4);
        p = PageRanges.parse("3-1, 2", 5);
        assert(p.length == 3 && p[0] == 0 && p[2] == 2);
        assert(PageRanges.format(PageRanges.parse("1,2,3,5,7-8", 10)) == "1-3, 5, 7-8");
    } catch (Error e) {
        error("valid range rejected: %s", e.message);
    }
    foreach (var bad in new string[] {"", "0", "11", "a", "1-x", "4-12"}) {
        bool failed = false;
        try {
            PageRanges.parse(bad, 10);
        } catch (PrintError e) {
            failed = true;
        }
        if (!failed) error("invalid range \"%s\" accepted", bad);
    }
}

LayoutSpec a4_spec(int n) {
    var s = new LayoutSpec();
    s.page_width = 595;
    s.page_height = 842;
    s.sheet_width = 595;
    s.sheet_height = 842;
    s.pages_per_sheet = n;
    return s;
}

void check_nup() {
    int[] pages = {0, 1, 2, 3, 4};
    var sides = Imposition.impose(pages, a4_spec(1));
    assert(sides.size == 5);
    assert((sides[0].placements[0].scale - 1.0).abs() < 1e-6);

    sides = Imposition.impose(pages, a4_spec(2));
    assert(sides.size == 3);
    var p0 = sides[0].placements[0];
    var p1 = sides[0].placements[1];
    assert(p0.rotated && p1.rotated);
    assert(p0.y < p1.y);
    assert(sides[2].placements[1].page == -1);
    assert(p0.width <= 595 + 1e-6 && p0.height <= 421 + 1e-6);

    sides = Imposition.impose(pages, a4_spec(4));
    assert(sides.size == 2);
    assert(!sides[0].placements[0].rotated);
    assert(sides[0].placements[1].x > sides[0].placements[0].x);
    assert(sides[0].placements[2].y > sides[0].placements[0].y);

    var spec = a4_spec(4);
    spec.order = NupOrder.TOP_BOTTOM_LEFT_RIGHT;
    sides = Imposition.impose(pages, spec);
    assert(sides[0].placements[1].y > sides[0].placements[0].y);
    assert((sides[0].placements[1].x - sides[0].placements[0].x).abs() < 1e-6);

    int cols, rows;
    bool rot;
    Imposition.grid(6, 595, 842, 595, 842, out cols, out rows, out rot);
    assert(cols * rows == 6 && rot);
    Imposition.grid(9, 595, 842, 595, 842, out cols, out rows, out rot);
    assert(cols == 3 && rows == 3 && !rot);
    Imposition.grid(16, 595, 842, 595, 842, out cols, out rows, out rot);
    assert(cols == 4 && rows == 4);

    spec = a4_spec(1);
    spec.scale_mode = ScaleMode.CUSTOM;
    spec.scale_percent = 50;
    sides = Imposition.impose({0}, spec);
    assert((sides[0].placements[0].width - 297.5).abs() < 1e-6);
    assert((sides[0].placements[0].x - 148.75).abs() < 1e-6);
}

void check_order_filters() {
    int[] pages = {0, 1, 2, 3, 4, 5};
    var spec = a4_spec(1);
    spec.page_set = PageSet.ODD;
    var sides = Imposition.impose(pages, spec);
    assert(sides.size == 3 && sides[0].placements[0].page == 0 && sides[1].placements[0].page == 2);
    spec.page_set = PageSet.EVEN;
    sides = Imposition.impose(pages, spec);
    assert(sides.size == 3 && sides[0].placements[0].page == 1);
    spec.page_set = PageSet.ALL;
    spec.reverse = true;
    sides = Imposition.impose(pages, spec);
    assert(sides[0].placements[0].page == 5 && sides[5].placements[0].page == 0);
    assert(Imposition.physical_sheets(5, true, 2) == 6);
    assert(Imposition.physical_sheets(5, false, 1) == 5);
}

void check_booklet() {
    var order = Imposition.booklet_order(8);
    int[] expected = {7, 0, 1, 6, 5, 2, 3, 4};
    assert(order.length == 8);
    for (int i = 0; i < 8; i++) assert(order[i] == expected[i]);
    order = Imposition.booklet_order(5);
    assert(order.length == 8);

    var spec = a4_spec(1);
    spec.booklet = true;
    int[] pages = {0, 1, 2, 3, 4};
    var sides = Imposition.impose(pages, spec);
    assert(sides.size == 4);
    assert(sides[0].width > sides[0].height);
    assert(sides[0].placements[0].page == -1);
    assert(sides[0].placements[1].page == 0);
    assert(sides[1].placements[0].page == 1);
    assert(sides[1].placements[1].page == -1);
    assert(sides[0].placements[0].x + sides[0].placements[0].width <= sides[0].width / 2 + 1e-6);
}

void check_options() {
    var o = new JobOptions();
    o.printer = "Office";
    o.copies = 3;
    o.collate = false;
    o.duplex = Duplex.SHORT_EDGE;
    o.pages_per_sheet = 4;
    o.nup_order = NupOrder.TOP_BOTTOM_RIGHT_LEFT;
    o.grayscale = true;
    o.media = "na_letter_8.5x11in";
    o.landscape = true;
    o.watermark = "DRAFT";
    o.extras.insert("finishings", "4");
    o.range_mode = RangeMode.CUSTOM;
    o.ranges = "2-3";

    var copy = new JobOptions();
    copy.apply(o.to_variant(false));
    assert(copy.printer == "Office" && copy.duplex == Duplex.SHORT_EDGE && copy.pages_per_sheet == 4);
    assert(copy.nup_order == NupOrder.TOP_BOTTOM_RIGHT_LEFT && copy.grayscale && copy.landscape);
    assert(copy.watermark == "DRAFT" && copy.extras.lookup("finishings") == "4");
    assert(copy.copies == 1 && copy.range_mode == RangeMode.ALL);
    var full = o.copy();
    assert(full.copies == 3 && full.ranges == "2-3");

    var s = o.to_gtk_settings();
    assert(s.get_printer() == "Office");
    assert(s.get_n_copies() == 3 && !s.get_collate());
    assert(s.get_duplex() == Gtk.PrintDuplex.VERTICAL);
    assert(s.get_number_up() == 4);
    assert(s.get_number_up_layout() == Gtk.NumberUpLayout.TBRL);
    assert(!s.get_use_color());
    assert(s.get_orientation() == Gtk.PageOrientation.LANDSCAPE);
    assert(s.get_print_pages() == Gtk.PrintPages.RANGES);
    var ranges = s.get_page_ranges();
    assert(ranges.length == 1 && ranges[0].start == 1 && ranges[0].end == 2);

    var back = new JobOptions();
    back.from_gtk_settings(s);
    assert(back.copies == 3 && back.duplex == Duplex.SHORT_EDGE && back.grayscale && back.landscape);
    assert(back.media == "na_letter_8.5x11in");

    double w, h;
    o.geometry(out w, out h);
    assert((w - 792).abs() < 0.01 && (h - 612).abs() < 0.01);

    var caps = new PrinterCapabilities();
    caps.media.add(Media.from_keyword("iso_a4_210x297mm"));
    caps.media_default = "iso_a4_210x297mm";
    caps.sides = {"one-sided"};
    caps.color_modes = {"monochrome"};
    var p = new JobOptions();
    p.media = "na_letter_8.5x11in";
    p.duplex = Duplex.LONG_EDGE;
    p.apply_defaults(caps);
    assert(p.media == "iso_a4_210x297mm" && p.duplex == Duplex.ONE_SIDED && p.grayscale);

    var m = Media.from_keyword("na_index-4x6_4x6in");
    assert(m != null && (m.width_mm - 101.6).abs() < 0.01);
    assert(Media.from_keyword("bogus") == null);
    assert(Media.label("iso_a4_210x297mm", 210, 297) == "A4");
    assert(Options.expand_template("{title} {page}/{pages}", "Doc", 2, 5, new DateTime.now_local()) == "Doc 2/5");
}

void check_presets(string dir) {
    var store = new PresetStore(Path.build_filename(dir, "printing-%u.ini".printf(Random.next_int())));
    var o = new JobOptions();
    o.printer = "Photo";
    o.quality = 5;
    o.pages_per_sheet = 2;
    try {
        store.save_preset("Photos", o);
        o.quality = 3;
        store.save_preset("Draft", o);
    } catch (Error e) {
        error("save preset: %s", e.message);
    }
    var names = store.list_presets();
    assert(names.length == 2);
    var loaded = store.load_preset("Photos");
    assert(loaded != null && loaded.quality == 5 && loaded.pages_per_sheet == 2 && loaded.printer == "Photo");
    try {
        store.delete_preset("Photos");
    } catch (Error e) {
        error("delete preset: %s", e.message);
    }
    assert(store.list_presets().length == 1 && store.load_preset("Photos") == null);
    store.remember("dev.sinty.write", o);
    var last = store.last_used("dev.sinty.write");
    assert(last != null && last.quality == 3);
    assert(store.last_used("dev.sinty.other") == null);
    FileUtils.remove(store.path);
}

void check_status() {
    var p = new Printer();
    p.name = "X";
    p.state = 3;
    assert(p.status == PrinterStatus.READY);
    p.state_reasons = {"media-empty-error"};
    assert(p.status == PrinterStatus.ATTENTION && p.status_text() == "Out of paper");
    p.state_reasons = {"offline-report"};
    assert(p.status == PrinterStatus.OFFLINE);
    p.state_reasons = {"none"};
    p.state = 4;
    p.state_message = "Waiting for printer to become available.";
    assert(p.offline && p.status == PrinterStatus.OFFLINE);
    p.state_message = "";
    assert(!p.offline && p.status == PrinterStatus.PRINTING);
    p.state = 5;
    assert(p.status == PrinterStatus.PAUSED);
    p.state = 3;
    var m = new Marker();
    m.name = "Yellow";
    m.color = "#FFFF00";
    m.level = 8;
    m.low_level = 10;
    p.markers.add(m);
    assert(p.low_supplies && p.status_text() == "Ready, supplies low");
    var yellow = m.rgba();
    assert(yellow.red > 0.99 && yellow.green > 0.99 && yellow.blue < 0.01);
    m.color = "#00FFFF#FF00FF";
    var cyan = m.rgba();
    assert(cyan.red < 0.01 && cyan.green > 0.99 && cyan.blue > 0.99);
    m.color = "none";
    assert(m.rgba().red > 0.49 && m.rgba().red < 0.51);
    assert(PrinterBackend.sanitize_name("Office Laser (2nd floor)") == "Office_Laser_2nd_floor");
    assert(Printer.save_as_pdf().is_pdf && Printer.save_as_pdf().kind == PrinterKind.PDF);
    assert(PrinterKind.guess("HP LaserJet Pro", "", "") == PrinterKind.LASER);
    assert(PrinterKind.guess("Brother MFC-L2710DW", "", "") == PrinterKind.MULTIFUNCTION);
}

void check_extra_options(string dir) {
    var x = new ExtraOptions("Prepress", "Marks");
    x.add_switch("marks", "Crop Marks", null, false);
    x.add_choice("layout", "Imposition", {"none", "nup", "booklet"}, {"None", "Several", "Booklet"}, "nup");
    x.add_number("across", "Across", null, 1, 20, 1, 2);
    x.add_note("colour", "Colour", "RGB only");
    x.show_when("across", "layout", {"nup"});
    assert(x.items.size == 4);
    assert(!x.get_bool("marks") && x.get_choice("layout") == "nup" && x.get_number("across") == 2);
    assert(x.is_visible("across") && x.is_visible("colour") && !x.is_visible("missing"));
    string last_key = "";
    bool last_reflow = false;
    int fired = 0;
    x.changed.connect((k, r) => {
        last_key = k;
        last_reflow = r;
        fired++;
    });
    x.set_choice("layout", "booklet");
    assert(fired == 1 && last_key == "layout" && last_reflow);
    assert(!x.is_visible("across"));
    x.set_choice("layout", "booklet");
    assert(fired == 1);
    x.set_choice("layout", "poster");
    assert(fired == 1 && x.get_choice("layout") == "booklet");
    x.set_number("across", 99);
    assert(x.get_number("across") == 20);
    assert(!x.set_value("marks", new Variant.string("yes")));
    x.set_bool("marks", true);
    var o = new JobOptions();
    x.store(o.app_options);
    assert(o.app_options.lookup("colour") == null);
    var copy = o.copy();
    var y = new ExtraOptions("Prepress");
    y.add_switch("marks", "Crop Marks", null, false);
    y.add_choice("layout", "Imposition", {"none", "nup", "booklet"}, {"None", "Several", "Booklet"}, "none");
    y.add_number("across", "Across", null, 1, 10, 1, 1);
    y.restore(copy.app_options);
    assert(y.get_bool("marks") && y.get_choice("layout") == "booklet" && y.get_number("across") == 10);
    var store = new PresetStore(Path.build_filename(dir, "extra-presets-%lld.ini".printf(get_monotonic_time())));
    store.remember("dev.sinty.test", o);
    var back = store.last_used("dev.sinty.test");
    assert(back != null && back.app_options.lookup("layout").get_string() == "booklet");
    y.reset();
    assert(!y.get_bool("marks") && y.get_choice("layout") == "none");
}

void check_snapshot_breaks() {
    var s = new Cairo.ImageSurface(Cairo.Format.ARGB32, 40, 300);
    var cr = new Cairo.Context(s);
    cr.set_source_rgb(1, 1, 1);
    cr.paint();
    cr.set_source_rgb(0, 0, 0);
    for (int y = 0; y < 300; y += 20) {
        cr.rectangle(2, y + 4, 30, 12);
        cr.fill();
    }
    s.flush();
    assert(SnapshotSource.uniform_row(s, 0) && SnapshotSource.uniform_row(s, 17));
    assert(!SnapshotSource.uniform_row(s, 5));
    var cuts = SnapshotSource.page_breaks(s, 110, 22);
    assert(cuts[0] == 0 && cuts[cuts.length - 1] == 300);
    for (int i = 1; i < cuts.length - 1; i++) {
        assert(SnapshotSource.uniform_row(s, cuts[i]));
        assert(cuts[i] - cuts[i - 1] <= 110 && cuts[i] - cuts[i - 1] > 110 - 22);
    }
    var solid = new Cairo.ImageSurface(Cairo.Format.ARGB32, 10, 250);
    var sc = new Cairo.Context(solid);
    sc.set_source_rgb(0, 0, 0);
    sc.paint();
    sc.set_source_rgb(1, 0, 0);
    sc.set_line_width(1);
    for (int y = 0; y < 250; y++) {
        sc.rectangle(y % 10, y, 1, 1);
        sc.fill();
    }
    cuts = SnapshotSource.page_breaks(solid, 100, 20);
    assert(cuts.length == 4 && cuts[1] == 100 && cuts[2] == 200 && cuts[3] == 250);
    var tiny = new Cairo.ImageSurface(Cairo.Format.ARGB32, 10, 30);
    cuts = SnapshotSource.page_breaks(tiny, 100, 20);
    assert(cuts.length == 2 && cuts[1] == 30);
}

int main(string[] args) {
    Intl.setlocale(LocaleCategory.ALL, "C");
    string dir = Environment.get_variable("TMPDIR") ?? ".";
    check_ranges();
    check_nup();
    check_order_filters();
    check_booklet();
    check_options();
    check_presets(dir);
    check_status();
    check_extra_options(dir);
    check_snapshot_breaks();
    print("print tests passed\n");
    return 0;
}
