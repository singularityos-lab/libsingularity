namespace Singularity.Widgets {

    /**
     * Plays one audio or video file through a GStreamer playbin.
     *
     * Video frames are drawn by `video`, a VideoPaintable, so the playback
     * works with or without gtk4paintablesink. The object tracks position,
     * duration, mute state and the tags of the stream, including embedded
     * cover art, and updates `position` a few times per second while it
     * plays. Call `stop()` when the playback is no longer shown.
     */
    public class MediaPlayback : Object {
        /** The paintable showing the video frames. */
        public VideoPaintable video { get; private set; }

        /** The URI being played, or null. */
        public string? uri { get; private set; default = null; }

        /** Whether the pipeline could be created. */
        public bool available { get { return playbin != null; } }

        /** Whether the stream is playing. */
        public bool playing { get; private set; default = false; }

        /** Whether the stream has a video track, known once it is ready. */
        public bool has_video { get; private set; default = false; }

        /** Whether the stream is ready: tracks, duration and tags are known. */
        public bool ready { get; private set; default = false; }

        /** Stream duration in nanoseconds, or 0 when unknown. */
        public int64 duration { get; private set; default = 0; }

        /** Playback position in nanoseconds. */
        public int64 position { get; private set; default = 0; }

        /** Cover art embedded in the stream tags, or null. */
        public Gdk.Texture? cover { get; private set; default = null; }

        /** Title from the stream tags, or null. */
        public string? title { get; private set; default = null; }

        /** Artist from the stream tags, or null. */
        public string? artist { get; private set; default = null; }

        /** Album from the stream tags, or null. */
        public string? album { get; private set; default = null; }

        /** Restart from the beginning when the end is reached. */
        public bool loop { get; set; default = false; }

        /** Whether the audio is muted. */
        public bool muted {
            get { return _muted; }
            set {
                _muted = value;
                if (playbin != null) playbin.set("mute", value);
            }
        }

        /** Linear volume between 0 and 1. */
        public double volume {
            get { return _volume; }
            set {
                _volume = value.clamp(0.0, 1.0);
                if (playbin != null) playbin.set("volume", _volume);
            }
        }

        /** Emitted with a readable message when the stream cannot be played. */
        public signal void failed(string message);

        /** Emitted when the end of the stream is reached. */
        public signal void finished();

        private Gst.Element? playbin = null;
        private uint tick_id = 0;
        private bool _muted = false;
        private double _volume = 1.0;

        public MediaPlayback() {
            VideoPaintable.ensure_gstreamer();
            video = new VideoPaintable();
            playbin = Gst.ElementFactory.make("playbin", null);
            if (playbin == null) return;
            if (video.sink != null) playbin.set("video-sink", video.sink);
            var bus = playbin.get_bus();
            bus.add_signal_watch();
            bus.message.connect(on_message);
        }

        ~MediaPlayback() {
            stop_ticking();
            if (playbin != null) {
                playbin.set_state(Gst.State.NULL);
                playbin.get_bus().remove_signal_watch();
            }
        }

        /**
         * Opens a file or stream.
         *
         * @param uri      The URI to play.
         * @param autoplay Start playing as soon as possible; otherwise the
         *                 first frame is shown and playback waits for play().
         */
        public void open(string uri, bool autoplay = true) {
            if (playbin == null) {
                Idle.add(() => {
                    failed(_("Playback is unavailable because the GStreamer playbin element is missing."));
                    return Source.REMOVE;
                });
                return;
            }
            stop();
            this.uri = uri;
            playbin.set("uri", uri);
            playbin.set("mute", _muted);
            playbin.set("volume", _volume);
            playbin.set_state(autoplay ? Gst.State.PLAYING : Gst.State.PAUSED);
            if (autoplay) {
                playing = true;
                start_ticking();
            }
        }

        /** Stops playback and releases the stream. */
        public void stop() {
            stop_ticking();
            if (playbin != null) playbin.set_state(Gst.State.NULL);
            video.clear();
            playing = false;
            ready = false;
            has_video = false;
            duration = 0;
            position = 0;
            cover = null;
            title = null;
            artist = null;
            album = null;
            uri = null;
        }

        /** Starts or resumes playback. */
        public void play() {
            if (playbin == null || uri == null) return;
            if (duration > 0 && position >= duration) seek(0);
            playbin.set_state(Gst.State.PLAYING);
            playing = true;
            start_ticking();
        }

        /** Pauses playback. */
        public void pause() {
            if (playbin == null || uri == null) return;
            playbin.set_state(Gst.State.PAUSED);
            playing = false;
            stop_ticking();
            update_position();
        }

        /** Toggles between playing and paused. */
        public void toggle() {
            if (playing) pause(); else play();
        }

        /**
         * Seeks to a position.
         *
         * @param target   Position in nanoseconds.
         * @param accurate Land on the exact frame instead of the nearest key frame.
         */
        public void seek(int64 target, bool accurate = true) {
            if (playbin == null) return;
            var flags = Gst.SeekFlags.FLUSH;
            flags |= accurate ? Gst.SeekFlags.ACCURATE : Gst.SeekFlags.KEY_UNIT | Gst.SeekFlags.SNAP_NEAREST;
            int64 clamped = int64.max(0, duration > 0 ? int64.min(target, duration) : target);
            if (playbin.seek_simple(Gst.Format.TIME, flags, clamped)) position = clamped;
        }

        /** Seeks to a fraction between 0 and 1 of the duration. */
        public void seek_fraction(double fraction, bool accurate = false) {
            if (duration <= 0) return;
            seek((int64) (fraction.clamp(0.0, 1.0) * duration), accurate);
        }

        /** Formats a time in nanoseconds as m:ss or h:mm:ss. */
        public static string format_time(int64 nanoseconds) {
            int64 total = int64.max(0, nanoseconds / Gst.SECOND);
            int64 hours = total / 3600;
            int64 minutes = (total / 60) % 60;
            int64 seconds = total % 60;
            if (hours > 0) return "%lld:%02lld:%02lld".printf(hours, minutes, seconds);
            return "%lld:%02lld".printf(minutes, seconds);
        }

        private void start_ticking() {
            if (tick_id != 0) return;
            tick_id = Timeout.add(250, () => {
                update_position();
                return Source.CONTINUE;
            });
        }

        private void stop_ticking() {
            if (tick_id == 0) return;
            Source.remove(tick_id);
            tick_id = 0;
        }

        private void update_position() {
            if (playbin == null) return;
            int64 value = 0;
            if (playbin.query_position(Gst.Format.TIME, out value)) position = value;
            if (duration <= 0 && playbin.query_duration(Gst.Format.TIME, out value) && value > 0) duration = value;
        }

        private void on_message(Gst.Bus bus, Gst.Message message) {
            switch (message.type) {
                case Gst.MessageType.ASYNC_DONE:
                    on_ready();
                    break;
                case Gst.MessageType.DURATION_CHANGED:
                    int64 value = 0;
                    if (playbin.query_duration(Gst.Format.TIME, out value) && value > 0) duration = value;
                    break;
                case Gst.MessageType.EOS:
                    if (loop) {
                        seek(0);
                    } else {
                        pause();
                        position = duration;
                        finished();
                    }
                    break;
                case Gst.MessageType.TAG:
                    Gst.TagList tags;
                    message.parse_tag(out tags);
                    read_tags(tags);
                    break;
                case Gst.MessageType.ERROR:
                    Error err;
                    string debug;
                    message.parse_error(out err, out debug);
                    stop_ticking();
                    playing = false;
                    failed(err.message);
                    break;
                default:
                    break;
            }
        }

        private void on_ready() {
            int n_video = 0;
            playbin.get("n-video", out n_video);
            has_video = n_video > 0;
            int64 value = 0;
            if (playbin.query_duration(Gst.Format.TIME, out value) && value > 0) duration = value;
            update_position();
            ready = true;
        }

        private void read_tags(Gst.TagList tags) {
            string? text = null;
            if (title == null && tags.get_string(Gst.Tags.TITLE, out text)) title = text;
            if (artist == null && tags.get_string(Gst.Tags.ARTIST, out text)) artist = text;
            if (album == null && tags.get_string(Gst.Tags.ALBUM, out text)) album = text;
            if (cover != null) return;
            Gst.Sample? sample = null;
            if (!tags.get_sample(Gst.Tags.IMAGE, out sample)
                    && !tags.get_sample(Gst.Tags.PREVIEW_IMAGE, out sample)) return;
            var buffer = sample != null ? sample.get_buffer() : null;
            if (buffer == null) return;
            Gst.MapInfo map;
            if (!buffer.map(out map, Gst.MapFlags.READ)) return;
            var bytes = new Bytes(map.data);
            buffer.unmap(map);
            try {
                cover = Gdk.Texture.from_bytes(bytes);
            } catch (Error e) {
                cover = null;
            }
        }
    }
}
