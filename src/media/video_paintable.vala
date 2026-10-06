namespace Singularity.Widgets {

    /**
     * A paintable that shows the frames of a GStreamer pipeline.
     *
     * Plug `sink` into a pipeline, for example as the `video-sink` of a
     * playbin, and show the paintable in a Gtk.Picture. The sink is
     * gtk4paintablesink when that plugin is installed. Otherwise frames
     * go through an appsink, are converted to RGBA by GStreamer and are
     * uploaded as textures on the main thread, so video still renders on
     * systems without the GTK GStreamer plugin.
     *
     * Usage:
     * {{{
     *   var video = new Singularity.Widgets.VideoPaintable();
     *   if (video.sink != null) {
     *       playbin.set("video-sink", video.sink);
     *       picture.paintable = video;
     *   }
     * }}}
     */
    public class VideoPaintable : Object, Gdk.Paintable {
        /** The element to use as video sink, or null when no sink could be built. */
        public Gst.Element? sink { get; private set; }

        /** Whether frames come from gtk4paintablesink rather than the appsink fallback. */
        public bool native { get; private set; default = false; }

        /** Whether a frame is available to draw. */
        public bool has_frame {
            get { return inner != null ? inner.get_intrinsic_width() > 0 : texture != null; }
        }

        /** Emitted on the main thread when the first frame after a clear() arrives. */
        public signal void first_frame();

        private Gdk.Paintable? inner = null;
        private Gdk.Texture? texture = null;
        private Gdk.Texture? pending = null;
        private uint idle_id = 0;
        private bool waiting_first = true;
        private Mutex frame_lock = Mutex();

        /**
         * Creates the paintable and its sink.
         *
         * @param allow_native Use gtk4paintablesink when it is installed.
         *                     Pass false to always use the appsink path.
         */
        public VideoPaintable(bool allow_native = true) {
            ensure_gstreamer();
            if (allow_native && try_native()) return;
            sink = build_fallback_sink();
        }

        /** Initializes GStreamer once for the process when nobody did yet. */
        public static void ensure_gstreamer() {
            if (!Gst.is_initialized()) {
                unowned string[]? args = null;
                Gst.init(ref args);
            }
        }

        /**
         * Drops the frame on screen, for example before the pipeline opens
         * another file, so the previous picture does not linger.
         */
        public void clear() {
            frame_lock.lock();
            pending = null;
            waiting_first = true;
            frame_lock.unlock();
            if (texture != null) {
                texture = null;
                invalidate_size();
                invalidate_contents();
            }
        }

        private bool try_native() {
            var gtk_sink = Gst.ElementFactory.make("gtk4paintablesink", null);
            if (gtk_sink == null) return false;
            Gdk.Paintable? paintable = null;
            gtk_sink.get("paintable", out paintable);
            if (paintable == null) return false;
            inner = paintable;
            inner.invalidate_contents.connect(() => {
                invalidate_contents();
                if (waiting_first && inner.get_intrinsic_width() > 0) {
                    waiting_first = false;
                    first_frame();
                }
            });
            inner.invalidate_size.connect(() => invalidate_size());
            sink = gtk_sink;
            native = true;
            return true;
        }

        private Gst.Element? build_fallback_sink() {
            var convert = Gst.ElementFactory.make("videoconvert", null);
            var app_sink = Gst.ElementFactory.make("appsink", null) as Gst.App.Sink;
            if (convert == null || app_sink == null) return null;
            app_sink.caps = Gst.Caps.from_string("video/x-raw,format=RGBA");
            app_sink.max_buffers = 2;
            app_sink.drop = true;
            app_sink.emit_signals = true;
            app_sink.new_sample.connect(on_new_sample);
            app_sink.new_preroll.connect(on_new_preroll);
            var bin = new Gst.Bin(null);
            bin.add_many(convert, app_sink);
            convert.link(app_sink);
            bin.add_pad(new Gst.GhostPad("sink", convert.get_static_pad("sink")));
            return bin;
        }

        private Gst.FlowReturn on_new_sample(Gst.App.Sink app_sink) {
            var sample = app_sink.pull_sample();
            if (sample != null) push(sample);
            return Gst.FlowReturn.OK;
        }

        private Gst.FlowReturn on_new_preroll(Gst.App.Sink app_sink) {
            var sample = app_sink.pull_preroll();
            if (sample != null) push(sample);
            return Gst.FlowReturn.OK;
        }

        private void push(Gst.Sample sample) {
            var caps = sample.get_caps();
            var buffer = sample.get_buffer();
            if (caps == null || buffer == null) return;
            var info = new Gst.Video.Info();
            if (!info.from_caps(caps)) return;
            Gst.MapInfo map;
            if (!buffer.map(out map, Gst.MapFlags.READ)) return;
            var bytes = new Bytes(map.data);
            buffer.unmap(map);
            var frame = new Gdk.MemoryTexture(info.width, info.height,
                Gdk.MemoryFormat.R8G8B8A8, bytes, (size_t) info.stride[0]);
            frame_lock.lock();
            pending = frame;
            if (idle_id == 0) idle_id = Idle.add(apply_pending, Priority.HIGH_IDLE);
            frame_lock.unlock();
        }

        private bool apply_pending() {
            frame_lock.lock();
            var next = pending;
            pending = null;
            idle_id = 0;
            bool announce = waiting_first && next != null;
            if (announce) waiting_first = false;
            frame_lock.unlock();
            if (next == null) return Source.REMOVE;
            bool resized = texture == null
                || texture.get_width() != next.get_width()
                || texture.get_height() != next.get_height();
            texture = next;
            if (resized) invalidate_size();
            invalidate_contents();
            if (announce) first_frame();
            return Source.REMOVE;
        }

        public int get_intrinsic_width() {
            if (inner != null) return inner.get_intrinsic_width();
            return texture != null ? texture.get_width() : 0;
        }

        public int get_intrinsic_height() {
            if (inner != null) return inner.get_intrinsic_height();
            return texture != null ? texture.get_height() : 0;
        }

        public double get_intrinsic_aspect_ratio() {
            if (inner != null) return inner.get_intrinsic_aspect_ratio();
            if (texture == null || texture.get_height() == 0) return 0.0;
            return (double) texture.get_width() / texture.get_height();
        }

        public void snapshot(Gdk.Snapshot snapshot, double width, double height) {
            if (inner != null) {
                inner.snapshot(snapshot, width, height);
            } else if (texture != null) {
                texture.snapshot(snapshot, width, height);
            }
        }
    }
}
