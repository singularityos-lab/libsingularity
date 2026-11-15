using Gtk;

namespace Singularity {

    public class WatchFaceView : Gtk.Widget {
        private string? _face_id = null;
        private Gdk.Texture? _wallpaper = null;
        private Cairo.ImageSurface? _wall_cache = null;
        private int _wall_w = 0;
        private int _wall_h = 0;
        private uint _timer = 0;
        private uint _tick = 0;
        private int64 _started = 0;
        private ulong _store_id = 0;
        private ulong _current_id = 0;
        private ulong _registry_id = 0;

        public double battery { get; set; default = -1.0; }
        public bool charging { get; set; default = false; }
        public uint notifications { get; set; default = 0; }

        public WatchFaceView(string? face_id = null) {
            _face_id = face_id;
            overflow = Overflow.HIDDEN;
            var store = WatchFaceStore.get_default();
            _store_id = store.changed.connect((id) => {
                if (id == resolved_id()) restart();
            });
            _current_id = store.current_changed.connect(() => {
                if (_face_id == null) restart();
            });
            _registry_id = WatchFaceRegistry.get_default().changed.connect(() => restart());
            notify["battery"].connect(() => queue_draw());
            notify["notifications"].connect(() => queue_draw());
        }

        public string? face_id {
            get { return _face_id; }
            set {
                _face_id = value;
                restart();
            }
        }

        public Gdk.Texture? wallpaper {
            get { return _wallpaper; }
            set {
                _wallpaper = value;
                _wall_cache = null;
                queue_draw();
            }
        }

        public WatchFaceProvider? provider {
            owned get { return WatchFaceRegistry.get_default().find(resolved_id()); }
        }

        private string resolved_id() {
            return _face_id ?? WatchFaceStore.get_default().current;
        }

        public override void map() {
            base.map();
            _started = GLib.get_monotonic_time();
            restart();
        }

        public override void unmap() {
            stop();
            base.unmap();
        }

        public override void dispose() {
            stop();
            var store = WatchFaceStore.get_default();
            if (_store_id != 0) { store.disconnect(_store_id); _store_id = 0; }
            if (_current_id != 0) { store.disconnect(_current_id); _current_id = 0; }
            if (_registry_id != 0) { WatchFaceRegistry.get_default().disconnect(_registry_id); _registry_id = 0; }
            base.dispose();
        }

        private void stop() {
            if (_timer != 0) {
                Source.remove(_timer);
                _timer = 0;
            }
            if (_tick != 0) {
                remove_tick_callback(_tick);
                _tick = 0;
            }
        }

        private void restart() {
            stop();
            queue_draw();
            if (!get_mapped()) return;
            var face = provider;
            if (face == null) return;
            var refresh = face.get_refresh(build_frame(face, get_width(), get_height()));
            if (refresh == WatchFaceRefresh.CONTINUOUS && !Singularity.Motion.reduced()) {
                _tick = add_tick_callback(() => {
                    queue_draw();
                    return Source.CONTINUE;
                });
                return;
            }
            schedule(refresh == WatchFaceRefresh.MINUTE ? 60 : 1);
        }

        private void schedule(int period) {
            var now = new DateTime.now_local();
            double into = now.get_seconds() + 0.0;
            double wait = period == 60 ? 60.0 - into : 1.0 - (into - Math.floor(into));
            _timer = Timeout.add(uint.max(16, (uint) (wait * 1000.0) + 5), () => {
                _timer = 0;
                queue_draw();
                schedule(period);
                return Source.REMOVE;
            });
        }

        private WatchFaceFrame build_frame(WatchFaceProvider face, int w, int h) {
            var frame = new WatchFaceFrame();
            var now = new DateTime.now_local();
            frame.width = w;
            frame.height = h;
            frame.time = now;
            frame.seconds = now.get_seconds();
            frame.battery = battery;
            frame.charging = charging;
            frame.notifications = notifications;
            frame.elapsed = (GLib.get_monotonic_time() - _started) / 1000000.0;
            WatchFaceStore.get_default().fill(face, frame);
            return frame;
        }

        private Cairo.ImageSurface? wallpaper_surface(int w, int h) {
            if (_wallpaper == null || w <= 0 || h <= 0) return null;
            int scale = int.max(1, get_scale_factor());
            int pw = w * scale;
            int ph = h * scale;
            if (_wall_cache != null && _wall_w == pw && _wall_h == ph) return _wall_cache;
            int tw = _wallpaper.get_width();
            int th = _wallpaper.get_height();
            var source = new Cairo.ImageSurface(Cairo.Format.ARGB32, tw, th);
            source.flush();
            unowned uchar[] data = source.get_data();
            data.length = source.get_stride() * th;
            _wallpaper.download(data, source.get_stride());
            source.mark_dirty();
            var target = new Cairo.ImageSurface(Cairo.Format.ARGB32, pw, ph);
            var cr = new Cairo.Context(target);
            double cover = double.max((double) pw / tw, (double) ph / th);
            cr.translate((pw - tw * cover) / 2.0, (ph - th * cover) / 2.0);
            cr.scale(cover, cover);
            cr.set_source_surface(source, 0, 0);
            cr.get_source().set_filter(Cairo.Filter.GOOD);
            cr.paint();
            target.set_device_scale(scale, scale);
            _wall_cache = target;
            _wall_w = pw;
            _wall_h = ph;
            return _wall_cache;
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            int w = get_width();
            int h = get_height();
            var face = provider;
            if (face == null || w <= 0 || h <= 0) return;
            var frame = build_frame(face, w, h);
            frame.wallpaper = wallpaper_surface(w, h);
            var cr = snapshot.append_cairo(Graphene.Rect().init(0, 0, w, h));
            cr.save();
            face.draw(cr, frame);
            cr.restore();
        }
    }
}
