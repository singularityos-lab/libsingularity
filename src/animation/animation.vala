namespace Singularity.Animation {

    /** Playback state of an Animation. */
    public enum AnimationState {
        /** The animation has not been started yet. */
        IDLE,
        /** The animation is temporarily suspended. */
        PAUSED,
        /** The animation is actively running. */
        PLAYING,
        /** The animation has completed. */
        FINISHED
    }

    /**
     * Abstract base class for frame-clock-driven animations.
     *
     * Subclass this and implement `on_update()` to advance the animation
     * on every frame. Use `TimedAnimation` for the common case of
     * interpolating a numeric value over a fixed duration.
     */
    public abstract class Animation : Object {

        private uint tick_id = 0;

        /** Current playback state of this animation. */
        public AnimationState state { get; protected set; default = AnimationState.IDLE; }

        /** The GTK widget whose frame clock drives this animation. */
        public Gtk.Widget widget { get; construct; }

        /** Emitted when the animation reaches its final frame. */
        public signal void done();

        /** Emitted on every rendered frame while the animation is playing. */
        public signal void tick();

        /**
         * Called on every frame while the animation is playing.
         *
         * @param frame_time Monotonic frame timestamp in microseconds
         *                   (from Gdk.FrameClock.get_frame_time).
         * @return `true` to continue animating; `false` to stop.
         */
        protected abstract bool on_update(int64 frame_time);

        /**
         * Creates a new animation bound to the given widget's frame clock.
         *
         * @param widget The widget whose frame clock will drive this animation.
         */
        protected Animation(Gtk.Widget widget) {
            Object(widget: widget);
        }

        /**
         * Starts or resumes the animation.
         * 
         * Has no effect if the animation is already playing.
         */
        public void play() {
            if (state == AnimationState.PLAYING) return;
            state = AnimationState.PLAYING;
            if (tick_id == 0) {
                tick_id = widget.add_tick_callback(on_tick);
            }
        }

        /** Pauses the animation at the current frame. Call `play()` to resume. */
        public void pause() {
            if (state != AnimationState.PLAYING) return;
            state = AnimationState.PAUSED;
            remove_tick_callback();
        }

        /** Resets the animation to its initial state without emitting `done`. */
        public void reset() {
            state = AnimationState.IDLE;
            remove_tick_callback();
        }

        /** Skips to the end of the animation, emitting `done`. */
        public void skip() {
            stop();
        }

        /**
         * Marks the animation as finished, removes the tick callback, and
         * emits `done`.
         */
        protected void stop() {
            state = AnimationState.FINISHED;
            remove_tick_callback();
            done();
        }

        private void remove_tick_callback() {
            if (tick_id != 0) {
                widget.remove_tick_callback(tick_id);
                tick_id = 0;
            }
        }

        private bool on_tick(Gtk.Widget widget, Gdk.FrameClock frame_clock) {
            if (state != AnimationState.PLAYING) {
                return false;
            }

            int64 frame_time = frame_clock.get_frame_time();
            bool continue_animating = on_update(frame_time);

            tick();

            if (!continue_animating) {
                stop();
                return false;
            }

            return true;
        }
    }
}
