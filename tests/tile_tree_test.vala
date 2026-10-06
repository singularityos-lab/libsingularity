using Singularity;

string order (TileTree tree) {
    return string.joinv (",", tree.tiles ());
}

void test_zone () {
    assert (TileZone.at (50, 50, 100, 100) == TileZone.CENTER);
    assert (TileZone.at (5, 50, 100, 100) == TileZone.LEFT);
    assert (TileZone.at (95, 50, 100, 100) == TileZone.RIGHT);
    assert (TileZone.at (50, 3, 100, 100) == TileZone.TOP);
    assert (TileZone.at (50, 98, 100, 100) == TileZone.BOTTOM);
    assert (TileZone.LEFT.is_before ());
    assert (!TileZone.BOTTOM.is_before ());
    assert (TileZone.TOP.orientation () == Gtk.Orientation.VERTICAL);
}

void test_add_split_remove () {
    var tree = new TileTree ();
    int changes = 0;
    tree.changed.connect (() => changes++);
    tree.add ("a");
    assert (tree.size == 1);
    assert (tree.root.is_leaf);
    tree.split ("a", "b", TileZone.RIGHT);
    assert (order (tree) == "a,b");
    assert (tree.root.orientation == Gtk.Orientation.HORIZONTAL);
    tree.split ("a", "c", TileZone.TOP);
    assert (order (tree) == "c,a,b");
    assert (!tree.split ("a", "b", TileZone.LEFT));
    assert (!tree.split ("a", "d", TileZone.CENTER));
    assert (tree.remove ("a"));
    assert (order (tree) == "c,b");
    assert (!tree.remove ("zzz"));
    assert (tree.remove ("c"));
    assert (tree.remove ("b"));
    assert (tree.is_empty);
    assert (changes == 6);
}

void test_move_and_swap () {
    var tree = TileTree.balanced ({ "a", "b", "c", "d" });
    assert (order (tree) == "a,b,c,d");
    assert (tree.move ("d", "a", TileZone.LEFT));
    assert (order (tree) == "d,a,b,c");
    assert (!tree.move ("a", "a", TileZone.LEFT));
    assert (!tree.move ("a", "b", TileZone.CENTER));
    assert (tree.swap ("d", "c"));
    assert (order (tree) == "c,a,b,d");
}

void test_geometry_and_neighbors () {
    var tree = new TileTree ();
    tree.add ("left");
    tree.split ("left", "right", TileZone.RIGHT);
    tree.split ("right", "bottom", TileZone.BOTTOM);
    TileRect r;
    assert (tree.geometry ("right", out r));
    assert (r.x == 0.5 && r.y == 0 && r.width == 0.5 && r.height == 0.5);
    assert (tree.neighbor ("left", TileDirection.RIGHT) == "right");
    assert (tree.neighbor ("right", TileDirection.DOWN) == "bottom");
    assert (tree.neighbor ("bottom", TileDirection.LEFT) == "left");
    assert (tree.neighbor ("left", TileDirection.LEFT) == null);
    assert (tree.neighbor ("bottom", TileDirection.UP) == "right");
}

void test_json_round_trip () {
    var tree = TileTree.balanced ({ "a", "b", "c" }, Gtk.Orientation.VERTICAL);
    tree.root.ratio = 0.3;
    var node = tree.to_json ();
    var copy = TileTree.from_json (node, { "c", "b", "a" });
    assert (copy != null);
    assert (order (copy) == "a,b,c");
    assert (copy.root.orientation == Gtk.Orientation.VERTICAL);
    assert (Math.fabs (copy.root.ratio - 0.3) < 1e-9);
    assert (TileTree.from_json (node, { "a", "b" }) == null);
    assert (TileTree.from_json (node, { "a", "b", "x" }) == null);
    var parser = new Json.Parser ();
    try {
        parser.load_from_data ("{\"orientation\":\"diagonal\",\"start\":{\"tile\":\"a\"},\"end\":{\"tile\":\"b\"}}");
    } catch (Error e) {
        assert_not_reached ();
    }
    assert (TileTree.from_json (parser.get_root (), { "a", "b" }) == null);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/tile-tree/zone", test_zone);
    Test.add_func ("/tile-tree/add-split-remove", test_add_split_remove);
    Test.add_func ("/tile-tree/move-swap", test_move_and_swap);
    Test.add_func ("/tile-tree/geometry", test_geometry_and_neighbors);
    Test.add_func ("/tile-tree/json", test_json_round_trip);
    return Test.run ();
}
