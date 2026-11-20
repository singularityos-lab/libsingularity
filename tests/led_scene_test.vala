using Singularity;

string ascii(uint8[] px, int w, int h) {
    var s = new StringBuilder();
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) s.append_c(px[y * w + x] > 0 ? '#' : '.');
        s.append_c('\n');
    }
    return s.str;
}

void test_text_fits() {
    var ctx = new LedContext();
    ctx.set_value("time", "12:34");
    var scene = LedScene.builtin("clock", 13, 8);
    assert (LedFont.text_width("12:34", 0) == 13);
    assert (LedFont.text_width("12:34") == 17);
    assert (!LedRenderer.animated(scene, ctx));
    var px = LedRenderer.render(scene, ctx, 0);
    assert (ascii(px, 13, 8) ==
        ".............\n" +
        ".#.###.####.#\n" +
        "##...##..##.#\n" +
        ".#.###.######\n" +
        ".#.#..#..#..#\n" +
        "######.###..#\n" +
        ".............\n" +
        ".............\n");
    assert (px[2 * 13 + 0] == 7 && px[2 * 13 + 5] == 3 && px[2 * 13 + 6] == 7 && px[2 * 13 + 9] == 7 && px[2 * 13 + 12] == 3);
}

void test_scroll_moves() {
    var ctx = new LedContext();
    ctx.set_value("media", "ARTIST - SONG");
    var scene = LedScene.builtin("now-playing", 13, 8);
    assert (LedRenderer.animated(scene, ctx));
    var a = LedRenderer.render(scene, ctx, 0);
    var b = LedRenderer.render(scene, ctx, 500);
    assert (ascii(a, 13, 8) != ascii(b, 13, 8));
    for (int x = 0; x < 3; x++) assert (a[2 * 13 + x] == b[2 * 13 + x]);
}

void test_bar_and_when() {
    var ctx = new LedContext();
    ctx.set_value("battery", "50");
    ctx.set_value("charging", "");
    var scene = LedScene.builtin("battery", 13, 8);
    var px = LedRenderer.render(scene, ctx, 0);
    int lit = 0;
    for (int x = 1; x < 9; x++) if (px[2 * 13 + x] == 7) lit++;
    assert (lit == 4);
    assert (px[1 * 13 + 12] == 0 && px[3 * 13 + 11] == 0);
    ctx.set_value("charging", "1");
    px = LedRenderer.render(scene, ctx, 0);
    assert (px[3 * 13 + 11] == 7);
    px = LedRenderer.render(scene, ctx, 700);
    assert (px[3 * 13 + 11] == 0);
}

void test_round_trip() throws Error {
    var scene = LedScene.builtin("battery", 13, 8);
    var anim = new LedLayer();
    anim.kind = LedLayerKind.BITMAP;
    for (int i = 0; i < 3; i++) {
        var f = new LedFrame(13, 8);
        f.duration_ms = 100 + i;
        f.pixels[i * 14] = (uint8) (i + 3);
        anim.frames.add(f);
    }
    scene.layers.add(anim);
    var back = LedScene.from_json(scene.to_json());
    assert (back.to_json() == scene.to_json());
    assert (back.layers.length == scene.layers.length);
    assert (back.layers[3].frames.length == 3);
    assert (back.layers[3].frames[2].pixels[28] == 5);
    var ctx = new LedContext();
    ctx.set_value("battery", "80");
    for (int64 t = 0; t < 1500; t += 50) {
        assert (Memory.cmp(LedRenderer.render(scene, ctx, t), LedRenderer.render(back, ctx, t), 104) == 0);
    }
}

void test_rejects_foreign_json() {
    try {
        LedScene.from_json("{\"width\": 13}");
        assert_not_reached();
    } catch (Error e) {
    }
    try {
        LedScene.from_json("{\"format\": \"sinty-led-scene\", \"version\": 1, \"width\": 100000, \"height\": 100000}");
        assert_not_reached();
    } catch (Error e) {
    }
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/led/text-fits", test_text_fits);
    Test.add_func("/led/scroll-moves", test_scroll_moves);
    Test.add_func("/led/bar-and-when", test_bar_and_when);
    Test.add_func("/led/round-trip", () => {
        try { test_round_trip(); } catch (Error e) { error(e.message); }
    });
    Test.add_func("/led/rejects-foreign-json", test_rejects_foreign_json);
    return Test.run();
}
