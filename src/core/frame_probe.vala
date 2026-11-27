namespace Singularity {

    public class FrameProbe : Object {
        public const string ENV = "SINTY_FRAME_PROBE";

        private class Track {
            public string name;
            public int frames;
            public int64 busy_us;
            public int64 worst_us;
            public int64 started_us;
            public int64 laid_out_us;
            public int64 layout_us;
        }

        private static FrameProbe? instance;
        private HashTable<Gdk.FrameClock, Track> tracks = new HashTable<Gdk.FrameClock, Track>(direct_hash, direct_equal);
        private int64 window_start;

        public static void install() {
            if (instance != null || Environment.get_variable(ENV) == null) return;
            instance = new FrameProbe();
        }

        private FrameProbe() {
            window_start = get_monotonic_time();
            var toplevels = Gtk.Window.get_toplevels();
            toplevels.items_changed.connect((pos, removed, added) => {
                for (uint i = pos; i < pos + added; i++) watch((Gtk.Window) toplevels.get_item(i));
            });
            for (uint i = 0; i < toplevels.get_n_items(); i++) watch((Gtk.Window) toplevels.get_item(i));
            Timeout.add_seconds(5, report);
        }

        private void watch(Gtk.Window window) {
            if (window.get_realized()) attach(window);
            ((Gtk.Widget) window).realize.connect(() => attach(window));
        }

        private void attach(Gtk.Window window) {
            var clock = window.get_frame_clock();
            if (clock == null || tracks.contains(clock)) return;
            var track = new Track();
            track.name = window.get_type().name() + (window.title != null ? ":" + window.title : "");
            tracks.insert(clock, track);
            clock.before_paint.connect(() => track.started_us = get_monotonic_time());
            clock.layout.connect_after(() => track.laid_out_us = get_monotonic_time());
            clock.after_paint.connect(() => {
                if (track.started_us == 0) return;
                var spent = get_monotonic_time() - track.started_us;
                track.frames++;
                track.busy_us += spent;
                if (track.laid_out_us >= track.started_us) track.layout_us += track.laid_out_us - track.started_us;
                if (spent > track.worst_us) track.worst_us = spent;
                track.started_us = 0;
            });
        }

        private bool report() {
            var now = get_monotonic_time();
            var seconds = (now - window_start) / 1000000.0;
            tracks.foreach((clock, track) => {
                if (track.frames == 0) return;
                stderr.printf("frame-probe %s fps=%.1f avg_ms=%.2f worst_ms=%.2f frames=%d layout_ms=%.1f total_ms=%.1f\n",
                    track.name, track.frames / seconds, track.busy_us / 1000.0 / track.frames,
                    track.worst_us / 1000.0, track.frames, track.layout_us / 1000.0, track.busy_us / 1000.0);
                track.frames = 0;
                track.busy_us = 0;
                track.worst_us = 0;
                track.layout_us = 0;
            });
            window_start = now;
            return Source.CONTINUE;
        }
    }
}
