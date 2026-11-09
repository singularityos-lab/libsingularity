namespace Singularity.Async {

    /**
     * A tiled cache for large canvases whose tiles are drawn on worker
     * threads.
     *
     * The draw function runs off the main thread, so it must only read data
     * that the main thread does not change while tiles are drawn, for example
     * an immutable copy of the document. A tile that is missing or out of
     * date is requested in the background; until it arrives the previous
     * tile at that place is shown, and the widget is redrawn when it does.
     */
    public class TileCache : Object {
        public delegate void DrawTile(Cairo.Context cr, double x, double y, double width, double height);

        private class Tile {
            public Gdk.Texture? texture;
            public uint version;
            public uint drawn_generation;
            public uint drawn_version;
            public uint requested_generation;
            public uint requested_version;
            public uint64 used;

            public bool fresh(uint generation) {
                return texture != null && drawn_generation == generation && drawn_version == version;
            }

            public bool asked(uint generation) {
                return requested_generation == generation && requested_version == version;
            }
        }

        private class Drawn {
            public Gdk.Texture texture;
        }

        private DrawTile draw_func;
        private HashTable<string, Tile> tiles = new HashTable<string, Tile>(str_hash, str_equal);
        private uint generation = 1;
        private double scale = 0;
        private uint64 frame = 0;
        private Cancellable current = new Cancellable();
        private weak Gtk.Widget? widget;
        private Cancellable? widget_scope;
        private ulong scope_id;

        public int tile_size { get; construct; }
        public int max_tiles { get; set; default = 256; }
        public Qos qos { get; set; default = Qos.INTERACTIVE; }

        /** Visible tiles that were up to date in the last frame. */
        public int ready_last_frame { get; private set; default = 0; }

        /** Visible tiles shown from an older drawing in the last frame. */
        public int stale_last_frame { get; private set; default = 0; }

        /** Visible tiles with nothing to show yet in the last frame. */
        public int missing_last_frame { get; private set; default = 0; }

        /** Tiles being drawn right now. */
        public int in_flight { get; private set; default = 0; }

        public TileCache(owned DrawTile draw, int tile_size = 256) {
            Object(tile_size: tile_size);
            draw_func = (owned) draw;
        }

        ~TileCache() {
            current.cancel();
            if (widget_scope != null) widget_scope.disconnect(scope_id);
        }

        /** Marks every tile out of date. Old tiles stay visible until redrawn. */
        public void invalidate() {
            generation++;
            current.cancel();
            current = new Cancellable();
            if (widget != null) widget.queue_draw();
        }

        /** Marks the tiles covering an area out of date. */
        public void invalidate_area(double x, double y, double width, double height) {
            int t = tile_size;
            int i0 = (int) Math.floor(x / t), i1 = (int) Math.floor((x + width) / t);
            int j0 = (int) Math.floor(y / t), j1 = (int) Math.floor((y + height) / t);
            for (int i = i0; i <= i1; i++) {
                for (int j = j0; j <= j1; j++) {
                    var tile = tiles[key(i, j)];
                    if (tile != null) tile.version++;
                }
            }
            if (widget != null) widget.queue_draw();
        }

        private static string key(int i, int j) {
            return "%d,%d".printf(i, j);
        }

        private Gdk.Texture render(int i, int j, double tile_scale) {
            int t = tile_size;
            int px = (int) Math.ceil(t * tile_scale);
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, px, px);
            var cr = new Cairo.Context(surface);
            cr.scale(tile_scale, tile_scale);
            cr.translate(-i * t, -j * t);
            cr.rectangle(i * t, j * t, t, t);
            cr.clip();
            draw_func(cr, i * t, j * t, t, t);
            surface.flush();
            int stride = surface.get_stride();
            unowned uint8[] data = (uint8[]) surface.get_data();
            data.length = stride * px;
            return new Gdk.MemoryTexture(px, px, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, new Bytes(data), stride);
        }

        private async void request(int i, int j, Tile tile) {
            uint gen = generation;
            uint version = tile.version;
            double tile_scale = scale;
            tile.requested_generation = gen;
            tile.requested_version = version;
            in_flight++;
            try {
                var drawn = yield run<Drawn>((c) => {
                    var result = new Drawn();
                    result.texture = render(i, j, tile_scale);
                    return result;
                }, qos, current);
                string k = key(i, j);
                var target = tiles[k];
                if (target == null) {
                    target = tile;
                    tiles[k] = target;
                }
                if (gen == generation && tile_scale == scale && version == target.version) {
                    target.texture = drawn.texture;
                    target.drawn_generation = gen;
                    target.drawn_version = version;
                } else if (target.texture == null) {
                    target.texture = drawn.texture;
                }
            } catch (Error e) {
                if (tile.requested_generation == gen && tile.requested_version == version) tile.requested_generation = 0;
            }
            in_flight--;
            if (widget != null) widget.queue_draw();
        }

        private void attach(Gtk.Widget target) {
            if (widget == target) return;
            if (widget_scope != null) widget_scope.disconnect(scope_id);
            widget = target;
            widget_scope = scope_of(target);
            scope_id = widget_scope.connect(() => {
                Idle.add(() => {
                    current.cancel();
                    return Source.REMOVE;
                });
            });
        }

        private void trim() {
            if (tiles.size() <= max_tiles) return;
            var used = new Gee.ArrayList<uint64?>();
            tiles.foreach((k, tile) => used.add(tile.used));
            used.sort((a, b) => a < b ? -1 : (a > b ? 1 : 0));
            int drop = (int) tiles.size() - max_tiles;
            uint64 cutoff = used[drop - 1];
            tiles.foreach_remove((k, tile) => {
                if (drop == 0 || tile.used > cutoff) return false;
                drop--;
                return true;
            });
        }

        /**
         * Appends the visible tiles to `snapshot` and requests the ones that
         * are missing or out of date.
         */
        public void snapshot(Gtk.Snapshot snapshot, Gtk.Widget widget, Graphene.Rect viewport, double content_x, double content_y) {
            attach(widget);
            double s = Widgets.TileCache.device_scale(widget);
            if (s != scale) {
                scale = s;
                generation++;
                current.cancel();
                current = new Cancellable();
            }
            frame++;
            int t = tile_size;
            double vx = Widgets.TileCache.snap(viewport.origin.x, scale), vy = Widgets.TileCache.snap(viewport.origin.y, scale);
            double vw = viewport.size.width, vh = viewport.size.height;
            double cx = Widgets.TileCache.snap(content_x, scale), cy = Widgets.TileCache.snap(content_y, scale);
            int i0 = (int) Math.floor(cx / t), i1 = (int) Math.floor((cx + vw) / t);
            int j0 = (int) Math.floor(cy / t), j1 = (int) Math.floor((cy + vh) / t);
            int ready = 0, stale = 0, missing = 0;
            snapshot.push_clip(Graphene.Rect().init((float) vx, (float) vy, (float) vw, (float) vh));
            for (int j = j0; j <= j1; j++) {
                for (int i = i0; i <= i1; i++) {
                    string k = key(i, j);
                    var tile = tiles[k];
                    if (tile == null) {
                        tile = new Tile();
                        tiles[k] = tile;
                    }
                    tile.used = frame;
                    bool fresh = tile.fresh(generation);
                    if (!fresh && !tile.asked(generation)) request.begin(i, j, tile);
                    if (tile.texture == null) {
                        missing++;
                        continue;
                    }
                    if (fresh) ready++;
                    else stale++;
                    var rect = Graphene.Rect().init((float) (vx + i * t - cx), (float) (vy + j * t - cy), (float) t, (float) t);
                    snapshot.append_scaled_texture(tile.texture, fresh ? Gsk.ScalingFilter.NEAREST : Gsk.ScalingFilter.LINEAR, rect);
                }
            }
            snapshot.pop();
            ready_last_frame = ready;
            stale_last_frame = stale;
            missing_last_frame = missing;
            trim();
        }
    }
}
