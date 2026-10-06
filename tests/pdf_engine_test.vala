using Singularity.Pdf;

string tmpdir;

string sample(string name, int pages, bool second = false) {
    string path = Path.build_filename(tmpdir, name);
    var surface = new Cairo.PdfSurface(path, 595, 842);
    for (int p = 0; p < pages; p++) {
        var cr = new Cairo.Context(surface);
        cr.select_font_face("sans-serif", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
        cr.set_font_size(20);
        cr.move_to(60, 90);
        cr.show_text("Report page %d".printf(p + 1));
        cr.select_font_face("serif", Cairo.FontSlant.NORMAL, Cairo.FontWeight.NORMAL);
        cr.set_font_size(11);
        cr.move_to(60, 130);
        cr.show_text(second ? "The account number is 9999 8888 7777 6666." : "The account number is 4417 1234 5678 9113.");
        cr.move_to(60, 150);
        cr.show_text("Revenue grew by twelve percent.");
        cr.set_source_rgb(0.2, 0.4, 0.8);
        cr.rectangle(60, 200, 150, 60);
        cr.fill();
        cr.set_source_rgb(0, 0, 0);
        cr.move_to(60, 400);
        cr.line_to(300, 400);
        cr.set_line_width(0.8);
        cr.stroke();
        cr.rectangle(60, 430, 12, 12);
        cr.stroke();
        cr.show_page();
    }
    surface.finish();
    return path;
}

void check(bool condition, string what) {
    if (!condition) {
        printerr("FAIL: %s\n", what);
        Process.exit(1);
    }
    print("ok %s\n", what);
}

void test_crypto() {
    uint8[] key = { 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
    uint8[] block = { 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
    var aes = new Aes(key);
    aes.encrypt_block(block);
    uint8[] expected = { 0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30, 0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a };
    bool same = true;
    for (int i = 0; i < 16; i++) if (block[i] != expected[i]) same = false;
    check(same, "AES-128 FIPS-197 vector");
    aes.decrypt_block(block);
    check(block[0] == 0x00 && block[15] == 0xff, "AES-128 decrypt");
    var key256 = new uint8[32];
    for (int i = 0; i < 32; i++) key256[i] = (uint8) i;
    uint8[] b2 = { 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
    new Aes(key256).encrypt_block(b2);
    check(b2[0] == 0x8e && b2[1] == 0xa2 && b2[15] == 0x89, "AES-256 FIPS-197 vector");
    var rc4 = Crypto.rc4("Key".data, "Plaintext".data);
    check(rc4[0] == 0xbb && rc4[1] == 0xf3 && rc4[8] == 0xd3, "RC4 vector");
    var iv = Crypto.random_bytes(16);
    var cbc = new Aes(key256);
    var enc = cbc.cbc_encrypt(iv, "hello pdf world, more than one block".data);
    var dec = cbc.cbc_decrypt(iv, enc);
    check(dec.length == 36 && dec[0] == 'h', "AES CBC round trip");
}

void test_roundtrip(string path) throws Error {
    var doc = Document.open_file(path);
    check(doc.page_count() == 3, "parse cairo PDF");
    var opts = new SaveOptions();
    opts.mode = SaveMode.COMPACT;
    opts.garbage_collect = true;
    var bytes = doc.save(opts);
    var again = Document.open_bytes(bytes);
    check(again.page_count() == 3 && again.uses_xref_stream, "object streams round trip");
    var enc_opts = new SaveOptions();
    enc_opts.new_security = SecurityHandler.create_aes256("user", "owner", Permissions.PRINT);
    var enc = again.save(enc_opts);
    bool refused = false;
    try {
        Document.open_bytes(enc, "wrong");
    } catch (PdfError e) {
        refused = e is PdfError.PASSWORD;
    }
    check(refused, "wrong password refused");
    var opened = Document.open_bytes(enc, "user");
    check(opened.page_count() == 3 && opened.security != null && !opened.security.owner_access, "AES-256 user password");
    var owner = Document.open_bytes(enc, "owner");
    check(owner.security.owner_access, "AES-256 owner password");
    var it = new Interpreter(opened);
    it.run_page(0);
    check(it.page_text().contains("Revenue grew"), "text through decryption");
    opened.info().set("Title", Obj.text("Changed"));
    var incr = new SaveOptions();
    incr.mode = SaveMode.INCREMENTAL;
    var inc = opened.save(incr);
    check(inc.length > enc.length, "incremental save appends");
    var reopened = Document.open_bytes(inc, "user");
    check(reopened.lookup(reopened.trailer.get("Info"), "Title").text_value() == "Changed", "incremental change visible");
}

void test_pages(string path) throws Error {
    var doc = Document.open_file(path);
    Pages.rotate(doc, { 0 }, 90);
    check(doc.page_rotation(0) == 90, "rotate");
    Pages.move(doc, 2, 0);
    var it = new Interpreter(doc);
    it.run_page(0);
    check(it.page_text().contains("page 3"), "reorder");
    Pages.delete(doc, { 1 });
    check(doc.page_count() == 2, "delete");
    Pages.insert_blank(doc, 1, 595, 842);
    check(doc.page_count() == 3, "insert blank");
    var extracted = Pages.extract(doc, { 0 });
    var saved = Document.open_bytes(extracted.save());
    check(saved.page_count() == 1, "extract");
    var parts = Pages.split_every(Document.open_file(path), 2);
    check(parts.size == 2 && parts[1].page_count() == 1, "split every 2");
    var list = new Gee.ArrayList<Document>();
    list.add(Document.open_file(path));
    list.add(Document.open_file(path));
    var merged = Document.open_bytes(Pages.merge(list, { "First", "Second" }).save());
    check(merged.page_count() == 6, "merge");
    var outline = Outline.read(merged);
    check(outline.size >= 2 && outline[0].title == "First" && outline[1].page == 3, "merge bookmarks");
}

void test_forms(string path) throws Error {
    var doc = Document.open_file(path);
    var detected = Forms.detect(doc, 0);
    check(detected.size >= 2, "detect fields (%d)".printf(detected.size));
    var name = Forms.create_field(doc, 0, FieldType.TEXT, "Name", Rect.of(60, 600, 260, 620));
    var qty = Forms.create_field(doc, 0, FieldType.TEXT, "Qty", Rect.of(60, 570, 160, 590));
    var price = Forms.create_field(doc, 0, FieldType.TEXT, "Price", Rect.of(60, 540, 160, 560));
    var total = Forms.create_field(doc, 0, FieldType.TEXT, "Total", Rect.of(60, 510, 160, 530));
    Forms.set_script(doc, total, "C", "event.value = this.getField(\"Qty\").value * this.getField(\"Price\").value;");
    Forms.set_script(doc, total, "F", "AFNumber_Format(2, 0, 0, 0, \"€\", true);");
    Forms.create_field(doc, 0, FieldType.CHECKBOX, "Agree", Rect.of(300, 600, 314, 614));
    Forms.create_field(doc, 0, FieldType.RADIO, "Size", Rect.of(300, 570, 312, 582), { "Small" });
    Forms.create_field(doc, 0, FieldType.RADIO, "Size", Rect.of(330, 570, 342, 582), { "Large" });
    Forms.create_field(doc, 0, FieldType.COMBO, "Country", Rect.of(300, 540, 420, 556), { "Italy", "France" });
    var values = new Gee.HashMap<string, string>();
    values["Name"] = "Mario Rossi";
    values["Qty"] = "3";
    values["Price"] = "2.5";
    values["Agree"] = "true";
    values["Size"] = "Large";
    values["Country"] = "France";
    Forms.import_values(doc, values);
    var reopened = Document.open_bytes(doc.save());
    var fields = Forms.list(reopened);
    check(fields.size == 7, "field count (%d)".printf(fields.size));
    var t = Forms.find(reopened, "Total");
    check(t != null && t.value == "7.5", "calculation (%s)".printf(t != null ? t.value : "null"));
    check(Forms.display_value(t, t.value) == "€7.50", "number format");
    check(Forms.find(reopened, "Agree").value == "Yes", "checkbox");
    var size = Forms.find(reopened, "Size");
    check(size.value == "Large" && size.widgets.size == 2, "radio group");
    string csv = Forms.export_csv(reopened);
    check(csv.contains("Mario Rossi"), "csv export");
    string xfdf = Annotations.export_xfdf(reopened, "form.pdf");
    var fresh = Document.open_bytes(doc.save());
    Forms.set_value(fresh, Forms.find(fresh, "Name"), "");
    Annotations.import_xfdf(fresh, xfdf);
    check(Forms.find(fresh, "Name").value == "Mario Rossi", "xfdf field import");
    string msg;
    var ranged = Forms.find(fresh, "Qty");
    Forms.set_script(fresh, ranged, "V", "AFRange_Validate(true, 1, true, 10);");
    ranged = Forms.find(fresh, "Qty");
    check(!Forms.validate(ranged, "12", out msg) && Forms.validate(ranged, "5", out msg), "range validation");
}

void test_annotations(string path) throws Error {
    var doc = Document.open_file(path);
    var sq = Annotations.shape(doc, 0, ShapeKind.RECTANGLE, { 100, 100, 200, 150 }, { 1, 0, 0 }, null, 2, 1, "Tester", "Box");
    Annotations.shape(doc, 0, ShapeKind.ARROW, { 100, 300, 250, 350 }, { 0, 0, 1 }, null, 1.5, 1, "Tester", "");
    Annotations.shape(doc, 0, ShapeKind.CLOUD, { 300, 300, 400, 300, 400, 380, 300, 380 }, { 0, 0.5, 0 }, null, 1, 1, "Tester", "");
    Annotations.stamp(doc, 0, Rect.of(350, 700, 500, 750), "Approved", { 0, 0.5, 0 }, "Tester");
    Annotations.reply(doc, 0, sq, "I agree", "Other");
    Annotations.set_state(doc, 0, sq, "Accepted", "Other");
    var reopened = Document.open_bytes(doc.save());
    var all = Annotations.list(reopened);
    check(all.size == 6, "annotation count (%d)".printf(all.size));
    AnnotInfo? box = null;
    foreach (var a in all) if (a.subtype == "Square") box = a;
    check(box != null && Annotations.current_state(all, box) == "Accepted", "review state");
    string xfdf = Annotations.export_xfdf(reopened, "doc.pdf");
    check(xfdf.contains("<square") && xfdf.contains("inreplyto"), "xfdf export");
    var target = Document.open_file(path);
    int imported = Annotations.import_xfdf(target, xfdf);
    check(imported >= 5, "xfdf import (%d)".printf(imported));
    var fdf = Annotations.export_fdf(reopened, "doc.pdf");
    var t2 = Document.open_file(path);
    check(Annotations.import_fdf(t2, fdf) >= 5, "fdf round trip");
}

void test_redaction(string path) throws Error {
    var doc = Document.open_file(path);
    var areas = Redaction.find_text(doc, 0, new Regex("\\d{4} \\d{4} \\d{4} \\d{4}"));
    check(areas.size == 1, "find sensitive text");
    Rect[] list = { areas[0], Rect.of(55, 580, 215, 650) };
    var report = Redaction.apply(doc, 0, list, null, "");
    check(report.verified && report.glyphs_removed == 19 && report.paths_removed >= 1, "redaction verified");
    var reopened = Document.open_bytes(doc.save());
    var it = new Interpreter(reopened);
    it.run_page(0);
    string text = it.page_text();
    check(!text.contains("4417") && !text.contains("9113") && text.contains("Revenue grew"), "text removed, rest kept");
}

void test_compare(string a, string b) throws Error {
    var result = Compare.documents(Document.open_file(a), Document.open_file(b));
    check(result.replaced == 3 && result.pages_added == 0, "compare replaced numbers (%d)".printf(result.replaced));
    check(result.changes[0].old_text == "4417 1234 5678 9113." && result.changes[0].new_text == "9999 8888 7777 6666.", "compare text");
}

void test_standards(string path) throws Error {
    var doc = Document.open_file(path);
    var before = Standards.check_pdfa(doc, "2b");
    check(before.size > 0, "pdfa issues found");
    SaveOptions opts;
    var remaining = Standards.convert_pdfa(doc, "2b", out opts);
    foreach (var i in remaining) print("  remaining %s %s\n", i.rule, i.message);
    check(remaining.size == 0, "pdfa conversion");
    var saved = Document.open_bytes(doc.save(opts));
    check(Standards.pdfa_part(saved) == "2b", "pdfa metadata");
    var ua = Document.open_file(path);
    int tagged = Tags.auto_tag(ua, "en-US", "Report");
    check(tagged >= 3, "auto tag (%d)".printf(tagged));
    var nodes = Tags.read(Document.open_bytes(ua.save()));
    check(nodes.size >= 3 && nodes[0].text.contains("Report"), "structure tree read");
    var uaissues = Standards.check_pdfua(ua);
    foreach (var i in uaissues) print("  ua %s %s\n", i.rule, i.message);
    check(uaissues.size == 0, "pdf/ua check after tagging");
}

void test_script() {
    string r;
    var values = new Gee.HashMap<string, string>();
    values["a"] = "1.234,5";
    values["b"] = "2";
    check(Script.calculate("AFSimple_Calculate(\"SUM\", new Array(\"a\", \"b\"));", values, out r) && r == "1236.5", "AFSimple_Calculate");
    check(Script.calculate("var x = this.getField(\"b\").value; if (x > 1) { event.value = x * 10; } else { event.value = 0; }", values, out r) && r == "20", "script if");
    check(!Script.calculate("while (true) {}", values, out r), "unsupported script refused");
    string f;
    check(Script.format("AFDate_FormatEx(\"dd/mm/yyyy\");", "2026-09-29", out f) && f == "29/09/2026", "date format");
}

int main(string[] args) {
    tmpdir = DirUtils.make_tmp("pdf-engine-XXXXXX");
    test_crypto();
    test_script();
    try {
        string a = sample("a.pdf", 3);
        string b = sample("b.pdf", 3, true);
        test_roundtrip(a);
        test_pages(a);
        test_forms(a);
        test_annotations(a);
        test_redaction(a);
        test_compare(a, b);
        test_standards(a);
    } catch (Error e) {
        printerr("FAIL: %s\n", e.message);
        return 1;
    }
    return 0;
}
