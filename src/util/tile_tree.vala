namespace Singularity {

    public enum TileZone {
        LEFT,
        RIGHT,
        TOP,
        BOTTOM,
        CENTER;

        public static TileZone at (double x, double y, double width, double height) {
            double nx = x / double.max (1.0, width);
            double ny = y / double.max (1.0, height);
            if (nx >= 0.25 && nx <= 0.75 && ny >= 0.25 && ny <= 0.75)
                return CENTER;

            double edge = nx;
            TileZone zone = LEFT;
            if (1.0 - nx < edge) {
                edge = 1.0 - nx;
                zone = RIGHT;
            }
            if (ny < edge) {
                edge = ny;
                zone = TOP;
            }
            if (1.0 - ny < edge)
                zone = BOTTOM;
            return zone;
        }

        public bool is_before () {
            return this == LEFT || this == TOP;
        }

        public Gtk.Orientation orientation () {
            return this == LEFT || this == RIGHT ? Gtk.Orientation.HORIZONTAL : Gtk.Orientation.VERTICAL;
        }
    }

    public enum TileDirection {
        LEFT,
        RIGHT,
        UP,
        DOWN
    }

    public class TileNode : Object {
        public string? tile;
        public Gtk.Orientation orientation;
        public double ratio = 0.5;
        public TileNode? start;
        public TileNode? end;

        public TileNode.leaf (string tile) {
            this.tile = tile;
        }

        public TileNode.split (Gtk.Orientation orientation, TileNode start, TileNode end, double ratio = 0.5) {
            this.orientation = orientation;
            this.start = start;
            this.end = end;
            this.ratio = ratio.clamp (0.05, 0.95);
        }

        public bool is_leaf {
            get { return tile != null; }
        }

        public int count () {
            if (tile != null) return 1;
            return (start != null ? start.count () : 0) + (end != null ? end.count () : 0);
        }
    }

    public struct TileRect {
        public double x;
        public double y;
        public double width;
        public double height;
    }

    public class TileTree : Object {
        public TileNode? root { get; private set; default = null; }

        public signal void changed ();

        public int size {
            get { return root != null ? root.count () : 0; }
        }

        public bool is_empty {
            get { return root == null; }
        }

        public string[] tiles () {
            var ids = new GenericArray<string> ();
            if (root != null) collect (root, ids);
            string[] result = {};
            foreach (unowned string id in ids.data) result += id;
            return result;
        }

        private static void collect (TileNode node, GenericArray<string> ids) {
            if (node.tile != null) {
                ids.add (node.tile);
                return;
            }
            if (node.start != null) collect (node.start, ids);
            if (node.end != null) collect (node.end, ids);
        }

        public bool contains (string id) {
            return find (root, id) != null;
        }

        private static TileNode? find (TileNode? node, string id) {
            if (node == null) return null;
            if (node.tile != null) return node.tile == id ? node : null;
            return find (node.start, id) ?? find (node.end, id);
        }

        public void add (string id) {
            if (contains (id)) return;
            if (root == null) {
                root = new TileNode.leaf (id);
            } else {
                var ids = tiles ();
                split (ids[ids.length - 1], id, root.count () % 2 == 1 ? TileZone.RIGHT : TileZone.BOTTOM);
                return;
            }
            changed ();
        }

        public bool split (string? target, string id, TileZone zone) {
            if (zone == TileZone.CENTER || contains (id)) return false;
            var inserted = new TileNode.leaf (id);
            if (root == null) {
                root = inserted;
                changed ();
                return true;
            }
            TileNode? anchor = target != null ? find (root, target) : null;
            bool before = zone.is_before ();
            if (anchor == null) {
                var old_root = root;
                root = new TileNode.split (zone.orientation (), before ? inserted : old_root, before ? old_root : inserted,
                                           before ? 1.0 / (old_root.count () + 1) : (double) old_root.count () / (old_root.count () + 1));
                changed ();
                return true;
            }
            var moved = new TileNode.leaf (anchor.tile);
            anchor.tile = null;
            anchor.orientation = zone.orientation ();
            anchor.ratio = 0.5;
            anchor.start = before ? inserted : moved;
            anchor.end = before ? moved : inserted;
            changed ();
            return true;
        }

        public bool remove (string id) {
            if (root == null) return false;
            bool removed;
            var updated = remove_from (root, id, out removed);
            if (!removed) return false;
            root = updated;
            changed ();
            return true;
        }

        private static TileNode? remove_from (TileNode node, string id, out bool removed) {
            if (node.tile != null) {
                removed = node.tile == id;
                return removed ? null : node;
            }
            bool child_removed = false;
            if (node.start != null) {
                var start = remove_from (node.start, id, out child_removed);
                if (child_removed) {
                    removed = true;
                    if (start == null) return node.end;
                    node.start = start;
                    return node;
                }
            }
            if (node.end != null) {
                var end = remove_from (node.end, id, out child_removed);
                if (child_removed) {
                    removed = true;
                    if (end == null) return node.start;
                    node.end = end;
                    return node;
                }
            }
            removed = false;
            return node;
        }

        public bool move (string id, string target, TileZone zone) {
            if (id == target || zone == TileZone.CENTER) return false;
            if (!contains (id) || !contains (target)) return false;
            var saved = root;
            bool removed;
            root = remove_from (root, id, out removed);
            if (!split (target, id, zone)) {
                root = saved;
                return false;
            }
            return true;
        }

        public bool swap (string a, string b) {
            var na = find (root, a);
            var nb = find (root, b);
            if (na == null || nb == null || na == nb) return false;
            na.tile = b;
            nb.tile = a;
            changed ();
            return true;
        }

        public void replace_root (TileNode? node) {
            root = node;
            changed ();
        }

        public static TileTree balanced (string[] ids, Gtk.Orientation first = Gtk.Orientation.HORIZONTAL) {
            var tree = new TileTree ();
            if (ids.length > 0) tree.root = build_balanced (ids, 0, ids.length, first);
            return tree;
        }

        private static TileNode build_balanced (string[] ids, int first, int count, Gtk.Orientation orientation) {
            if (count == 1) return new TileNode.leaf (ids[first]);
            int first_count = count / 2;
            var next = orientation == Gtk.Orientation.HORIZONTAL ? Gtk.Orientation.VERTICAL : Gtk.Orientation.HORIZONTAL;
            return new TileNode.split (orientation,
                build_balanced (ids, first, first_count, next),
                build_balanced (ids, first + first_count, count - first_count, next),
                (double) first_count / count);
        }

        public bool geometry (string id, out TileRect rect) {
            rect = TileRect () { x = 0, y = 0, width = 1, height = 1 };
            return root != null && locate (root, id, 0, 0, 1, 1, ref rect);
        }

        private static bool locate (TileNode node, string id, double x, double y, double w, double h, ref TileRect rect) {
            if (node.tile != null) {
                if (node.tile != id) return false;
                rect = TileRect () { x = x, y = y, width = w, height = h };
                return true;
            }
            if (node.orientation == Gtk.Orientation.HORIZONTAL) {
                double sw = w * node.ratio;
                return (node.start != null && locate (node.start, id, x, y, sw, h, ref rect))
                    || (node.end != null && locate (node.end, id, x + sw, y, w - sw, h, ref rect));
            }
            double sh = h * node.ratio;
            return (node.start != null && locate (node.start, id, x, y, w, sh, ref rect))
                || (node.end != null && locate (node.end, id, x, y + sh, w, h - sh, ref rect));
        }

        public string? neighbor (string id, TileDirection direction) {
            TileRect from;
            if (!geometry (id, out from)) return null;
            double cx = from.x + from.width / 2;
            double cy = from.y + from.height / 2;
            string? best = null;
            double best_score = double.MAX;
            foreach (string other in tiles ()) {
                if (other == id) continue;
                TileRect r;
                geometry (other, out r);
                double gap;
                double overlap;
                switch (direction) {
                    case TileDirection.LEFT:
                        gap = from.x - (r.x + r.width);
                        overlap = double.min (from.y + from.height, r.y + r.height) - double.max (from.y, r.y);
                        break;
                    case TileDirection.RIGHT:
                        gap = r.x - (from.x + from.width);
                        overlap = double.min (from.y + from.height, r.y + r.height) - double.max (from.y, r.y);
                        break;
                    case TileDirection.UP:
                        gap = from.y - (r.y + r.height);
                        overlap = double.min (from.x + from.width, r.x + r.width) - double.max (from.x, r.x);
                        break;
                    default:
                        gap = r.y - (from.y + from.height);
                        overlap = double.min (from.x + from.width, r.x + r.width) - double.max (from.x, r.x);
                        break;
                }
                if (gap < -1e-6 || overlap <= 1e-6) continue;
                double rx = r.x + r.width / 2;
                double ry = r.y + r.height / 2;
                double score = gap * 10 + Math.fabs (direction == TileDirection.LEFT || direction == TileDirection.RIGHT ? ry - cy : rx - cx);
                if (score < best_score) {
                    best_score = score;
                    best = other;
                }
            }
            return best;
        }

        public Json.Node to_json () {
            var builder = new Json.Builder ();
            if (root == null) {
                builder.add_null_value ();
            } else {
                write_node (builder, root);
            }
            return builder.get_root ();
        }

        private static void write_node (Json.Builder builder, TileNode node) {
            builder.begin_object ();
            if (node.tile != null) {
                builder.set_member_name ("tile");
                builder.add_string_value (node.tile);
            } else {
                builder.set_member_name ("orientation");
                builder.add_string_value (node.orientation == Gtk.Orientation.HORIZONTAL ? "horizontal" : "vertical");
                builder.set_member_name ("ratio");
                builder.add_double_value (node.ratio);
                builder.set_member_name ("start");
                write_node (builder, node.start);
                builder.set_member_name ("end");
                write_node (builder, node.end);
            }
            builder.end_object ();
        }

        public static TileTree? from_json (Json.Node? node, string[] expected) {
            if (node == null || node.get_node_type () != Json.NodeType.OBJECT) return null;
            var parsed = read_node (node.get_object ());
            if (parsed == null) return null;
            var tree = new TileTree ();
            tree.root = parsed;
            var found = tree.tiles ();
            if (found.length != expected.length) return null;
            var seen = new GenericSet<string> (str_hash, str_equal);
            foreach (string id in found) {
                if (seen.contains (id)) return null;
                seen.add (id);
            }
            foreach (string id in expected)
                if (!seen.contains (id)) return null;
            return tree;
        }

        private static TileNode? read_node (Json.Object? obj) {
            if (obj == null) return null;
            if (obj.has_member ("tile")) {
                string id = obj.get_string_member ("tile");
                return id != null && id != "" ? new TileNode.leaf (id) : null;
            }
            if (!obj.has_member ("orientation") || !obj.has_member ("start") || !obj.has_member ("end"))
                return null;
            string orientation = obj.get_string_member ("orientation");
            if (orientation != "horizontal" && orientation != "vertical") return null;
            var start = read_node (obj.get_object_member ("start"));
            var end = read_node (obj.get_object_member ("end"));
            if (start == null || end == null) return null;
            double ratio = obj.has_member ("ratio") ? obj.get_double_member ("ratio") : 0.5;
            return new TileNode.split (orientation == "horizontal" ? Gtk.Orientation.HORIZONTAL : Gtk.Orientation.VERTICAL,
                                       start, end, ratio);
        }
    }
}
