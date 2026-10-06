using Singularity.Annotations;

Cairo.ImageSurface stripes(int w, int h) {
    var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, w, h);
    var cr = new Cairo.Context(surface);
    cr.set_source_rgb(1, 1, 1);
    cr.paint();
    for (int x = 0; x < w; x += 4) {
        cr.rectangle(x, 0, 2, h);
    }
    cr.set_source_rgb(0, 0, 0);
    cr.fill();
    surface.flush();
    return surface;
}

Gdk.RGBA rgba(string spec) {
    var c = Gdk.RGBA();
    c.parse(spec);
    return c;
}

uint32 pixel(Cairo.ImageSurface s, int x, int y) {
    unowned uchar[] data = s.get_data();
    int o = y * s.get_stride() + x * 4;
    return ((uint32) data[o + 3] << 24) | ((uint32) data[o + 2] << 16) | ((uint32) data[o + 1] << 8) | data[o];
}

double variance(Cairo.ImageSurface s, int x0, int y0, int w, int h) {
    double sum = 0, sq = 0;
    int n = 0;
    for (int y = y0; y < y0 + h; y++) {
        for (int x = x0; x < x0 + w; x++) {
            double v = pixel(s, x, y) & 0xff;
            sum += v;
            sq += v * v;
            n++;
        }
    }
    double mean = sum / n;
    return sq / n - mean * mean;
}

void test_undo_redo() {
    var doc = new Document(stripes(200, 100));
    assert(!doc.can_undo && !doc.is_modified);
    var arrow = new ArrowItem();
    arrow.x1 = 10; arrow.y1 = 10; arrow.x2 = 120; arrow.y2 = 60;
    arrow.color = rgba("#e01b24");
    doc.add(arrow);
    var rect = new ShapeItem();
    rect.x = 20; rect.y = 20; rect.width = 50; rect.height = 30;
    doc.add(rect);
    assert(doc.items.size == 2);
    assert(doc.undo());
    assert(doc.items.size == 1);
    assert(doc.items[0] is ArrowItem);
    assert(doc.can_redo);
    assert(doc.redo());
    assert(doc.items.size == 2);
    assert(doc.items[1] is ShapeItem);
    assert(doc.undo() && doc.undo());
    assert(doc.items.size == 0);
    assert(!doc.undo());
    doc.redo();
    var pen = new StrokeItem();
    pen.add_point(1, 1);
    pen.add_point(5, 5);
    doc.add(pen);
    assert(!doc.can_redo);
}

void test_move_is_undoable() {
    var doc = new Document(stripes(200, 100));
    var shape = new ShapeItem();
    shape.x = 10; shape.y = 10; shape.width = 20; shape.height = 20;
    doc.add(shape);
    doc.checkpoint();
    doc.move_item(doc.items[0], 30, 5);
    assert(((ShapeItem) doc.items[0]).x == 40);
    doc.undo();
    assert(((ShapeItem) doc.items[0]).x == 10);
}

void test_steps_numbering() {
    var doc = new Document(stripes(100, 100));
    for (int i = 0; i < 3; i++) {
        var step = new StepItem();
        step.x = 10 + i * 20;
        step.y = 50;
        step.number = doc.next_step_number();
        doc.add(step);
    }
    assert(((StepItem) doc.items[2]).number == 3);
    doc.undo();
    assert(doc.next_step_number() == 3);
    doc.remove(doc.items[0]);
    assert(doc.next_step_number() == 3);
}

void test_hit_testing() {
    var doc = new Document(stripes(300, 200));
    var ellipse = new ShapeItem();
    ellipse.ellipse = true;
    ellipse.x = 100; ellipse.y = 50; ellipse.width = 100; ellipse.height = 60;
    ellipse.stroke = 4;
    doc.add(ellipse);
    var arrow = new ArrowItem();
    arrow.x1 = 0; arrow.y1 = 190; arrow.x2 = 100; arrow.y2 = 190;
    doc.add(arrow);
    assert(doc.item_at(100, 80) == ellipse);
    assert(doc.item_at(150, 80) == null);
    assert(doc.item_at(50, 191) == arrow);
    assert(doc.item_at(50, 150) == null);
}

void test_crop() {
    var doc = new Document(stripes(200, 100));
    doc.set_crop({ 50, 10, 100, 60 });
    assert(doc.is_cropped);
    var out_surface = doc.render();
    assert(out_surface.get_width() == 100 && out_surface.get_height() == 60);
    doc.set_crop({ -20, -20, 500, 500 });
    assert(doc.crop.width == 200 && doc.crop.height == 100);
    doc.undo();
    assert(doc.crop.width == 100);
    doc.undo();
    assert(!doc.is_cropped);
    doc.set_crop({ 10, 10, 2, 2 });
    assert(!doc.is_cropped);
}

void test_redaction() {
    var source = stripes(200, 100);
    var doc = new Document(source);
    double before = variance(doc.render(), 40, 20, 60, 40);
    assert(before > 1000);
    var pixelate = new RedactItem();
    pixelate.x = 40; pixelate.y = 20; pixelate.width = 60; pixelate.height = 40;
    doc.add(pixelate);
    var rendered = doc.render();
    double after = variance(rendered, 40, 20, 60, 40);
    assert(after < before / 4);
    assert(variance(rendered, 120, 20, 60, 40) > 1000);
    assert(pixel(source, 41, 21) == pixel(stripes(200, 100), 41, 21));
    doc.undo();
    var blur = new RedactItem();
    blur.style = RedactStyle.BLUR;
    blur.x = 40; blur.y = 20; blur.width = 60; blur.height = 40;
    doc.add(blur);
    assert(variance(doc.render(), 44, 24, 52, 32) < before / 4);
}

void test_drawing_changes_pixels() {
    var doc = new Document(stripes(200, 100));
    var hl = new StrokeItem();
    hl.highlighter = true;
    hl.color = rgba("#f6d32d");
    hl.add_point(10, 50);
    hl.add_point(190, 50);
    doc.add(hl);
    var rendered = doc.render();
    uint32 p = pixel(rendered, 101, 50);
    assert(((p >> 16) & 0xff) > 0x40);
    var text = new TextItem();
    text.x = 10; text.y = 10; text.text = "Hi";
    text.color = rgba("#3584e4");
    doc.add(text);
    var b = text.bounds();
    assert(b.width > 10 && b.height > 10);
}

void test_exports() {
    string dir = DirUtils.make_tmp("markup-test-XXXXXX");
    var doc = new Document(stripes(120, 80));
    var arrow = new ArrowItem();
    arrow.x1 = 10; arrow.y1 = 10; arrow.x2 = 80; arrow.y2 = 60;
    arrow.color = rgba("#e01b24");
    doc.add(arrow);
    var step = new StepItem();
    step.x = 30; step.y = 30; step.number = 1;
    doc.add(step);
    var label = new TextItem();
    label.x = 5; label.y = 5; label.text = "a < b";
    doc.add(label);
    doc.set_crop({ 5, 5, 100, 70 });
    string png = Path.build_filename(dir, "out.png");
    doc.save_png(png);
    var loaded = new Cairo.ImageSurface.from_png(png);
    assert(loaded.get_width() == 100 && loaded.get_height() == 70);
    var texture = doc.to_texture();
    assert(texture.get_width() == 100);
    string svg = doc.to_svg();
    assert("<image" in svg && "data:image/png;base64," in svg);
    assert("<polygon" in svg && "#e01b24" in svg);
    assert("<circle" in svg && ">1</text>" in svg);
    assert("a &lt; b" in svg);
    assert("translate(-5 -5)" in svg);
    FileUtils.unlink(png);
    DirUtils.remove(dir);
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/markup/undo-redo", test_undo_redo);
    Test.add_func("/markup/move", test_move_is_undoable);
    Test.add_func("/markup/steps", test_steps_numbering);
    Test.add_func("/markup/hit", test_hit_testing);
    Test.add_func("/markup/crop", test_crop);
    Test.add_func("/markup/redaction", test_redaction);
    Test.add_func("/markup/drawing", test_drawing_changes_pixels);
    Test.add_func("/markup/exports", test_exports);
    return Test.run();
}
