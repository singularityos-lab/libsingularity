using Singularity.Imaging;

private void near(double got, double want, double tolerance) {
    if ((got - want).abs() > tolerance) {
        stderr.printf("got %f want %f\n", got, want);
        assert_not_reached();
    }
}

private void test_transfer() {
    for (int i = 0; i <= 255; i++) {
        float lin = Transfer.srgb_to_linear(i / 255.0f);
        assert(Transfer.encode_byte(lin) == i);
    }
    near(Transfer.srgb_to_linear(0.5f), 0.21404, 1e-4);
    near(Transfer.linear_to_srgb(-0.25f), -Transfer.linear_to_srgb(0.25f), 1e-6);
}

private void test_parallel() {
    var hits = new int[1000];
    Parallel.range(1000, (s, e) => {
        for (int i = s; i < e; i++) hits[i]++;
    }, 3);
    foreach (int h in hits) assert(h == 1);
}

private void test_resize_and_geometry() {
    var img = new FloatImage(4, 2);
    for (int x = 0; x < 4; x++) {
        img.set_pixel(x, 0, x, 0, 0);
        img.set_pixel(x, 1, x, 1, 0);
    }
    var half = img.resized(2, 1);
    float r, g, b, a;
    half.get_pixel(0, 0, out r, out g, out b, out a);
    near(r, 0.5, 1e-6);
    near(g, 0.5, 1e-6);
    var rot = img.rotated_quarter(1);
    assert(rot.width == 2 && rot.height == 4);
    rot.get_pixel(1, 3, out r, out g, out b, out a);
    near(r, 3, 1e-6);
    near(g, 0, 1e-6);
    var flip = img.flipped_horizontal();
    flip.get_pixel(0, 0, out r, out g, out b, out a);
    near(r, 3, 1e-6);
    var crop = img.cropped(1, 1, 2, 1);
    crop.get_pixel(1, 0, out r, out g, out b, out a);
    near(r, 2, 1e-6);
    near(g, 1, 1e-6);
}

private void test_rgba8_roundtrip() {
    uint8[] px = new uint8[4 * 3 * 2];
    for (int i = 0; i < px.length; i++) px[i] = (uint8) (i * 11);
    var img = FloatImage.from_rgba8(px, 3, 2, 12, true, true);
    var back = img.to_rgba8(true);
    for (int i = 0; i < px.length; i++) assert(back[i] == px[i]);
    var tex = img.to_texture(true);
    var again = FloatImage.from_texture(tex, true);
    var back2 = again.to_rgba8(true);
    for (int i = 0; i < px.length; i++) assert(back2[i] == px[i]);
}

private void test_gaussian() {
    int w = 64, h = 64;
    var plane = new float[w * h];
    plane[32 * w + 32] = 1.0f;
    var blurred = Filters.gaussian_plane(plane, w, h, 3.0);
    double sum = 0, mx = 0, var_x = 0;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            double v = blurred[y * w + x];
            sum += v;
            var_x += v * (x - 32) * (x - 32);
            mx = double.max(mx, v);
        }
    }
    near(sum, 1.0, 1e-3);
    near(Math.sqrt(var_x / sum), 3.0, 0.35);
    assert(blurred[32 * w + 32] == (float) mx);
    var flat = new float[w * h];
    for (int i = 0; i < flat.length; i++) flat[i] = 0.25f;
    var g = Filters.guided_plane(flat, flat, w, h, 4, 1e-3f);
    near(g[100], 0.25, 1e-4);
}

private void test_blend() {
    float r, g, b;
    Blend.mix(BlendMode.MULTIPLY, 0.5f, 0.5f, 0.5f, 0.5f, 1.0f, 0.0f, out r, out g, out b);
    near(r, 0.25, 1e-6);
    near(g, 0.5, 1e-6);
    near(b, 0.0, 1e-6);
    Blend.mix(BlendMode.SCREEN, 0.5f, 0.5f, 0.5f, 0.5f, 1.0f, 0.0f, out r, out g, out b);
    near(r, 0.75, 1e-6);
    near(g, 1.0, 1e-6);
    Blend.mix(BlendMode.LUMINOSITY, 1.0f, 0.0f, 0.0f, 0.5f, 0.5f, 0.5f, out r, out g, out b);
    near(0.3 * r + 0.59 * g + 0.11 * b, 0.5, 1e-5);
    for (int i = 0; i < BlendMode.COUNT; i++) {
        var m = (BlendMode) i;
        assert(BlendMode.from_key(m.key()) == m);
        assert(m.psd_key().length == 4);
    }
    var base_img = new FloatImage.filled(2, 2, 0.2f, 0.2f, 0.2f);
    var top = new FloatImage.filled(1, 1, 1.0f, 0.0f, 0.0f);
    Blend.composite(base_img, top, 1, 1, BlendMode.NORMAL, 0.5f, null, false);
    float rr, gg, bb, aa;
    base_img.get_pixel(1, 1, out rr, out gg, out bb, out aa);
    near(rr, 0.6, 1e-6);
    near(gg, 0.1, 1e-6);
    near(aa, 1.0, 1e-6);
    base_img.get_pixel(0, 0, out rr, out gg, out bb, out aa);
    near(rr, 0.2, 1e-6);
}

private void test_matrices() {
    var m = Primaries.conversion(Primaries.rec709(), Primaries.rec2020());
    float r = 1, g = 1, b = 1;
    Matrix3.apply(m, ref r, ref g, ref b);
    near(r, 1, 1e-4);
    near(g, 1, 1e-4);
    near(b, 1, 1e-4);
    r = 1; g = 0; b = 0;
    Matrix3.apply(m, ref r, ref g, ref b);
    near(r, 0.6274, 1e-3);
    near(g, 0.0691, 1e-3);
    near(b, 0.0164, 1e-3);
    var back = Matrix3.multiply(Matrix3.invert(m), m);
    for (int i = 0; i < 9; i++) near(back[i], i % 4 == 0 ? 1 : 0, 1e-9);
    var d50 = Primaries.conversion(Primaries.rec709(), Primaries.prophoto());
    r = 1; g = 1; b = 1;
    Matrix3.apply(d50, ref r, ref g, ref b);
    near(r, 1, 2e-3);
    near(g, 1, 2e-3);
    near(b, 1, 2e-3);
}

private void test_icc() {
    var srgb = IccProfile.srgb();
    var lin = IccProfile.linear_srgb();
    assert(srgb.is_rgb());
    var data = IccProfile.rec2020().to_data();
    assert(data.length > 128);
    IccProfile reloaded;
    try {
        reloaded = IccProfile.from_data(data);
    } catch (Error e) {
        assert_not_reached();
    }
    assert(reloaded.id.has_prefix("icc:"));
    var img = new FloatImage.filled(3, 3, 0.5f, 0.25f, 0.75f, 0.5f);
    var t = new ColorTransform(srgb, lin, RenderingIntent.RELATIVE_COLORIMETRIC, false);
    assert(t.valid());
    t.apply(img);
    float r, g, b, a;
    img.get_pixel(2, 2, out r, out g, out b, out a);
    near(r, Transfer.srgb_to_linear(0.5f), 2e-3);
    near(g, Transfer.srgb_to_linear(0.25f), 2e-3);
    near(a, 0.5, 1e-6);
    var back = new ColorTransform(lin, srgb, RenderingIntent.RELATIVE_COLORIMETRIC, false);
    back.apply(img);
    img.get_pixel(0, 0, out r, out g, out b, out a);
    near(r, 0.5, 2e-3);
    near(b, 0.75, 2e-3);
    var proof = new ColorTransform.proofing(srgb, srgb, IccProfile.adobe_rgb(), RenderingIntent.RELATIVE_COLORIMETRIC, false);
    assert(proof.valid());
    try {
        IccProfile.from_data(new uint8[10]);
        assert_not_reached();
    } catch (IccError e) {
    }
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/imaging/transfer", test_transfer);
    Test.add_func("/imaging/parallel", test_parallel);
    Test.add_func("/imaging/geometry", test_resize_and_geometry);
    Test.add_func("/imaging/rgba8", test_rgba8_roundtrip);
    Test.add_func("/imaging/gaussian", test_gaussian);
    Test.add_func("/imaging/blend", test_blend);
    Test.add_func("/imaging/matrices", test_matrices);
    Test.add_func("/imaging/icc", test_icc);
    return Test.run();
}
