namespace Singularity.Animation {

    public delegate void ListChange();

    public class ListAnimator : Object {

        public Gtk.Widget container { get; construct; }

        public ListAnimator(Gtk.Widget container) {
            Object(container: container);
        }

        public static MotionBin wrap(Gtk.Widget content) {
            return new MotionBin(content);
        }

        public void insert(Gtk.Widget row, owned ListChange change) {
            var before = positions();
            change();
            row.opacity = 0.0;
            var bin = bin_of(row);
            if (bin != null && !Singularity.Motion.reduced()) {
                bin.origin_y = 0.0;
                bin.scale_y = Singularity.Motion.ENTER_SCALE;
            }
            after_layout(() => {
                settle(before, row);
                Singularity.Motion.tween(row, "opacity", 1.0, Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER);
                if (bin != null) Singularity.Motion.tween(bin, "scale-y", 1.0, Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER);
            });
        }

        public void remove(Gtk.Widget row, owned ListChange change) {
            var fade = Singularity.Motion.tween(row, "opacity", 0.0, Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.EXIT);
            fade.done.connect(() => {
                var before = positions();
                change();
                after_layout(() => settle(before, null));
            });
        }

        public const string KEY_DATA = "singularity-list-key";

        public uint max_new_rows { get; set; default = 3; }

        public static void set_key(Gtk.Widget row, string key) {
            row.set_data<string>(KEY_DATA, key);
        }

        public static string? key_of(Gtk.Widget row) {
            return row.get_data<string>(KEY_DATA);
        }

        public void rebuild(owned ListChange change) {
            var before = keyed_positions();
            change();
            if (before.size() == 0) return;
            after_layout(() => settle_keyed(before));
        }

        private HashTable<string, Graphene.Point?> keyed_positions() {
            var table = new HashTable<string, Graphene.Point?>(str_hash, str_equal);
            for (var child = container.get_first_child(); child != null; child = child.get_next_sibling()) {
                string? key = key_of(child);
                if (key == null || child.opacity == 0.0 || !child.get_mapped()) continue;
                Graphene.Point point;
                if (child.compute_point(container, Graphene.Point() { x = 0, y = 0 }, out point)) {
                    table.insert(key, point);
                }
            }
            return table;
        }

        private void settle_keyed(HashTable<string, Graphene.Point?> before) {
            var fresh = new GenericArray<Gtk.Widget>();
            for (var child = container.get_first_child(); child != null; child = child.get_next_sibling()) {
                string? key = key_of(child);
                if (key != null && !before.contains(key) && child.get_mapped()) fresh.add(child);
            }
            bool reduced = Singularity.Motion.reduced();
            if (fresh.length <= max_new_rows) {
                foreach (var row in fresh) {
                    row.opacity = 0.0;
                    var bin = bin_of(row);
                    if (bin != null && !reduced) {
                        bin.origin_y = 0.0;
                        bin.scale_y = Singularity.Motion.ENTER_SCALE;
                        Singularity.Motion.tween(bin, "scale-y", 1.0, Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER);
                    }
                    Singularity.Motion.tween(row, "opacity", 1.0, Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER);
                }
            }
            if (reduced) return;
            for (var child = container.get_first_child(); child != null; child = child.get_next_sibling()) {
                string? key = key_of(child);
                if (key == null || !before.contains(key) || !child.get_mapped()) continue;
                var bin = bin_of(child);
                if (bin == null) continue;
                Graphene.Point now;
                if (!child.compute_point(container, Graphene.Point() { x = 0, y = 0 }, out now)) continue;
                Graphene.Point? old = before.get(key);
                double dy = old.y - now.y;
                double dx = old.x - now.x;
                if (dx != 0.0) {
                    bin.translate_x = dx;
                    Singularity.Motion.spring_to(bin, "translate-x", 0.0, Singularity.Motion.Spring.SNAPPY);
                }
                if (dy != 0.0) {
                    bin.translate_y = dy;
                    Singularity.Motion.spring_to(bin, "translate-y", 0.0, Singularity.Motion.Spring.SNAPPY);
                }
            }
        }

        public void move(owned ListChange change) {
            var before = positions();
            change();
            after_layout(() => settle(before, null));
        }

        private HashTable<Gtk.Widget, Graphene.Point?> positions() {
            var table = new HashTable<Gtk.Widget, Graphene.Point?>(direct_hash, direct_equal);
            for (var child = container.get_first_child(); child != null; child = child.get_next_sibling()) {
                Graphene.Point point;
                if (child.compute_point(container, Graphene.Point() { x = 0, y = 0 }, out point)) {
                    table.insert(child, point);
                }
            }
            return table;
        }

        private void settle(HashTable<Gtk.Widget, Graphene.Point?> before, Gtk.Widget? skip) {
            if (Singularity.Motion.reduced()) return;
            for (var child = container.get_first_child(); child != null; child = child.get_next_sibling()) {
                if (child == skip || !before.contains(child)) continue;
                var bin = bin_of(child);
                if (bin == null) continue;
                Graphene.Point now;
                if (!child.compute_point(container, Graphene.Point() { x = 0, y = 0 }, out now)) continue;
                Graphene.Point? old = before.get(child);
                double dx = old.x - now.x;
                double dy = old.y - now.y;
                if (dx != 0.0) {
                    bin.translate_x = bin.translate_x + dx;
                    Singularity.Motion.spring_to(bin, "translate-x", 0.0, Singularity.Motion.Spring.SNAPPY);
                }
                if (dy != 0.0) {
                    bin.translate_y = bin.translate_y + dy;
                    Singularity.Motion.spring_to(bin, "translate-y", 0.0, Singularity.Motion.Spring.SNAPPY);
                }
            }
        }

        private static MotionBin? bin_of(Gtk.Widget row) {
            var bin = row as MotionBin;
            if (bin != null) return bin;
            return row.get_first_child() as MotionBin;
        }

        private void after_layout(owned ListChange callback) {
            var clock = container.get_frame_clock();
            if (clock == null) {
                callback();
                return;
            }
            ulong handler = 0;
            handler = clock.layout.connect_after(() => {
                clock.disconnect(handler);
                callback();
            });
            container.queue_allocate();
        }
    }
}
