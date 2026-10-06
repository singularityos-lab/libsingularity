using Singularity.Vector;

void check (bool cond, string what) {
    if (!cond) {
        stderr.printf ("FAIL: %s\n", what);
        Process.exit (1);
    }
}

bool near (double a, double b, double eps = 1e-3) {
    return (a - b).abs () <= eps;
}

void test_svg_round_trip () {
    var p = PathData.parse_svg ("M10 20 L30 20 C40 20 50 30 50 40 Z");
    check (p.segs.size == 4, "svg segments");
    var q = PathData.parse_svg (p.to_svg ());
    check (q.to_svg () == p.to_svg (), "svg round trip");
}

void test_bezier_length () {
    var line = Bezier.line (Point (0, 0), Point (100, 0));
    check (near (line.length (), 100, 1e-6), "line bezier length");
    double k = PathData.KAPPA;
    var quarter = Bezier (Point (100, 0), Point (100, 100 * k), Point (100 * k, 100), Point (0, 100));
    check (near (quarter.length (), Math.PI * 50, 0.1), "quarter circle length %f".printf (quarter.length ()));
    double t = quarter.t_at_length (Math.PI * 25);
    var mid = quarter.at (t);
    check (near (Math.hypot (mid.x, mid.y), 100, 0.1), "point at half length lies on the arc");
    check (near (mid.x, mid.y, 0.5), "half length is at 45 degrees");
    Bezier l, r;
    quarter.split (0.3, out l, out r);
    check (near (l.length () + r.length (), quarter.length (), 0.01), "split preserves length");
}

void test_offset_square () {
    var edges = new Gee.ArrayList<OffsetEdge> ();
    edges.add (new OffsetEdge ({ Point (0, 0), Point (100, 0) }, 10));
    edges.add (new OffsetEdge ({ Point (100, 0), Point (100, 50) }, 10));
    edges.add (new OffsetEdge ({ Point (100, 50), Point (0, 50) }, 15));
    edges.add (new OffsetEdge ({ Point (0, 50), Point (0, 0) }, 10));
    var pts = Offset.closed (edges);
    var r = Rect.empty ();
    foreach (var p in pts) r = r.include (p.x, p.y);
    check (near (r.x, -10) && near (r.y, -10), "offset top left %f %f".printf (r.x, r.y));
    check (near (r.x2 (), 110) && near (r.y2 (), 65), "offset bottom right %f %f".printf (r.x2 (), r.y2 ()));
    check (pts.length == 4, "intersect corners give four points, got %d".printf (pts.length));
    var rev = new Gee.ArrayList<OffsetEdge> ();
    for (int i = edges.size - 1; i >= 0; i--) rev.add (new OffsetEdge (Polyline.reversed (edges[i].pts), edges[i].width));
    var pts2 = Offset.closed (rev);
    var r2 = Rect.empty ();
    foreach (var p in pts2) r2 = r2.include (p.x, p.y);
    check (near (r2.x, -10) && near (r2.x2 (), 110), "offset is outward for either orientation");
    edges[0].end_corner = CornerStyle.BEVEL;
    check (Offset.closed (edges).length == 5, "bevel adds a point");
}

void test_boolean () {
    var a = new PathData.rect (0, 0, 10, 10);
    var b = new PathData.rect (5, 0, 10, 10);
    check (near (PathBoolean.area (PathBoolean.apply (a, b, BoolOp.UNION)), 150, 0.01), "union area");
    check (near (PathBoolean.area (PathBoolean.apply (a, b, BoolOp.INTERSECT)), 50, 0.01), "intersect area");
}

void test_curve_fit () {
    Point[] pts = {};
    for (int i = 0; i <= 50; i++) {
        double a = Math.PI * i / 50;
        pts += Point (100 * Math.cos (a), 100 * Math.sin (a));
    }
    var fit = CurveFit.fit (pts, 0.5);
    check (fit.size >= 1 && fit.size <= 4, "half circle fits in few curves, got %d".printf (fit.size));
    foreach (var p in pts) {
        double best = double.INFINITY;
        foreach (var bz in fit) {
            var q = bz.at (bz.nearest_t (p.x, p.y));
            best = double.min (best, q.distance (p));
        }
        check (best < 1.0, "fit stays close to the samples");
    }
}

void test_stroke_outline () {
    Point[] c = { Point (0, 0), Point (50, 0), Point (100, 0) };
    double[] w = { 2, 10, 2 };
    var o = StrokeOutline.build (c, w, false);
    double maxy = 0;
    foreach (var p in o) maxy = double.max (maxy, p.y.abs ());
    check (near (maxy, 5), "variable width follows the samples");
    var curve = new ResponseCurve (0.5, 0.0, 1.0, 0.5);
    check (curve.map (0.5) < 0.5, "soft curve lowers mid pressure");
    check (near (curve.map (0), 0) && near (curve.map (1), 1), "curve end points fixed");
}

void test_asset_library () throws Error {
    string dir = DirUtils.make_tmp ("assets-XXXXXX");
    string path = Path.build_filename (dir, "assets.json");
    var lib = new Singularity.Assets.AssetLibrary (path);
    var a = new Singularity.Assets.Asset ();
    a.kind = "fabric";
    a.name = "Denim 12 oz";
    a.set_field ("width", "150");
    lib.add (a);
    var lib2 = new Singularity.Assets.AssetLibrary (path);
    var list = lib2.list ("fabric");
    check (list.size == 1 && list[0].name == "Denim 12 oz", "asset persisted");
    check (list[0].get_number ("width") == 150, "asset field");
    check (lib2.from_drag_text (Singularity.Assets.AssetLibrary.drag_text (list[0])) != null, "drag text resolves");
    FileUtils.remove (path);
    DirUtils.remove (dir);
}

int main () {
    test_svg_round_trip ();
    test_bezier_length ();
    test_offset_square ();
    test_boolean ();
    test_curve_fit ();
    test_stroke_outline ();
    try {
        test_asset_library ();
    } catch (Error e) {
        check (false, e.message);
    }
    print ("vector: ok\n");
    return 0;
}
