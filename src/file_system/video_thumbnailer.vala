namespace Singularity.FileSystem {

    /**
     * Extracts a representative frame from a video with GStreamer.
     *
     * The frame is taken at 10% of the duration, or at 3 seconds when the
     * duration is unknown, which skips the black or title frames most
     * videos start with. `thumbnail()` also looks up and fills the
     * freedesktop.org thumbnail cache through ThumbnailCache.
     *
     * The methods block while the video is decoded; call them from a
     * worker thread. When no decoder is installed for the video they
     * return null, so the caller keeps showing the file type icon.
     */
    public class VideoThumbnailer : Object {
        /** The name failures are recorded under in the thumbnail cache. */
        public const string FAILURE_APP = "singularity-thumbnailer";

        private const int64 FALLBACK_POSITION = 3 * Gst.SECOND;
        private const Gst.ClockTime STEP_TIMEOUT = 8 * Gst.SECOND;
        private const uint PLAY_FLAG_VIDEO = 1 << 0;

        /**
         * Returns a thumbnail of the video at `uri` with at least `pixels`
         * pixels on its longer side when the video is that large, reading
         * the cache first and writing new thumbnails to it.
         *
         * @param uri    A local or GIO URI of the video.
         * @param mtime  The modification time of the file, in seconds.
         * @param pixels Wanted size of the longer side.
         * @param mime   The MIME type of the file, or null.
         * @return The thumbnail, or null when the video cannot be decoded.
         */
        public static Gdk.Pixbuf? thumbnail(string uri, int64 mtime, int pixels, string? mime = null) {
            var cached = ThumbnailCache.load(uri, mtime, pixels);
            if (cached != null) return cached;
            if (ThumbnailCache.has_failed(FAILURE_APP, uri, mtime)) return null;
            var frame = grab_frame(uri, (int) ThumbnailCache.Size.LARGE);
            if (frame == null) {
                ThumbnailCache.save_failure(FAILURE_APP, uri, mtime);
                return null;
            }
            ThumbnailCache.save(frame, uri, mtime, mime);
            return ThumbnailCache.scale_to(frame, int.max(pixels, (int) ThumbnailCache.Size.NORMAL));
        }

        /**
         * Decodes one frame of the video at `uri`.
         *
         * @param uri      A local or GIO URI of the video.
         * @param max_size Longest side of the returned frame, or 0 for full size.
         * @return The frame, or null when the video cannot be decoded.
         */
        public static Gdk.Pixbuf? grab_frame(string uri, int max_size = 0) {
            Singularity.Widgets.VideoPaintable.ensure_gstreamer();
            var playbin = Gst.ElementFactory.make("playbin", null);
            var sink = Gst.ElementFactory.make("appsink", null) as Gst.App.Sink;
            var audio = Gst.ElementFactory.make("fakesink", null);
            if (playbin == null || sink == null) return null;
            sink.caps = Gst.Caps.from_string("video/x-raw,format=RGB,pixel-aspect-ratio=1/1");
            sink.sync = false;
            playbin.set("video-sink", sink);
            if (audio != null) playbin.set("audio-sink", audio);
            playbin.set("flags", PLAY_FLAG_VIDEO);
            playbin.set("uri", uri);
            Gdk.Pixbuf? frame = null;
            if (wait_paused(playbin, Gst.State.PAUSED)) {
                int n_video = 0;
                playbin.get("n-video", out n_video);
                if (n_video > 0) {
                    int64 duration = 0;
                    int64 target = FALLBACK_POSITION;
                    if (playbin.query_duration(Gst.Format.TIME, out duration) && duration > 0) {
                        target = duration / 10;
                    }
                    if (playbin.seek_simple(Gst.Format.TIME, Gst.SeekFlags.FLUSH | Gst.SeekFlags.KEY_UNIT, target)) {
                        wait_paused(playbin, Gst.State.VOID_PENDING);
                    }
                    var sample = sink.try_pull_preroll(STEP_TIMEOUT);
                    if (sample != null) frame = to_pixbuf(sample);
                }
            }
            playbin.set_state(Gst.State.NULL);
            if (frame != null && max_size > 0) frame = ThumbnailCache.scale_to(frame, max_size);
            return frame;
        }

        private static bool wait_paused(Gst.Element playbin, Gst.State request) {
            if (request != Gst.State.VOID_PENDING
                    && playbin.set_state(request) == Gst.StateChangeReturn.FAILURE) {
                return false;
            }
            var bus = playbin.get_bus();
            while (true) {
                var message = bus.timed_pop_filtered(STEP_TIMEOUT,
                    Gst.MessageType.ASYNC_DONE | Gst.MessageType.ERROR);
                if (message == null) return false;
                if (message.type == Gst.MessageType.ERROR) return false;
                if (message.src == playbin) return true;
            }
        }

        private static Gdk.Pixbuf? to_pixbuf(Gst.Sample sample) {
            var caps = sample.get_caps();
            var buffer = sample.get_buffer();
            if (caps == null || buffer == null) return null;
            var info = new Gst.Video.Info();
            if (!info.from_caps(caps) || info.width <= 0 || info.height <= 0) return null;
            Gst.MapInfo map;
            if (!buffer.map(out map, Gst.MapFlags.READ)) return null;
            var bytes = new Bytes(map.data);
            buffer.unmap(map);
            return new Gdk.Pixbuf.from_bytes(bytes, Gdk.Colorspace.RGB, false, 8,
                info.width, info.height, info.stride[0]);
        }
    }
}
