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
     * How an animation behaves while Reduced Motion is on.
     *
     * See `Singularity.Motion.reduced()`.
     */
    public enum ReducedMode {
        /** Skips straight to the final value. */
        JUMP,
        /** Plays a short linear fade of `Motion.Duration.SMALL` instead. */
        SHORTEN,
        /** Ignores Reduced Motion; only for motion the user drives directly. */
        FULL
    }

    /**
     * Receives the value of an animation on every frame.
     *
     * @param value The current animated value.
     */
    public delegate void ValueSink(double value);

    /**
     * Common interface of animations and animation groups.
     *
     * Lets `AnimationGroup` and the stagger helpers of `Singularity.Motion`
     * start, skip and delay any kind of animation.
     */
    public interface Playable : Object {
        /** Delay in milliseconds before the animation starts moving. */
        public abstract uint delay { get; set; }
        /** Starts or resumes playback. */
        public abstract void play();
        /** Jumps to the final state and emits `done`. */
        public abstract void skip();
        /** Stops playback without emitting `done`. */
        public abstract void reset();
        /** Emitted once when the animation reaches its final state. */
        public signal void done();
    }

    /**
     * Abstract base class for frame-clock-driven animations.
     *
     * Progress is computed from elapsed time, never from a frame count, so an
     * animation lasts the same at 60, 120 and 144 Hz and under load. The
     * elapsed time follows `Motion.duration_scale` and the manual clock of
     * `Singularity.Motion`. Subclass this and implement `on_update()`, or use
     * `TimedAnimation`, `SpringAnimation` or `KeyframeAnimation`.
     */
    public abstract class Animation : Object, Playable {

        private uint tick_id = 0;
        private int64 last_time = -1;
        private double raw_elapsed = 0.0;
        private ulong unrealize_id = 0;
        private ValueSink? sink = null;

        /** Current playback state of this animation. */
        public AnimationState state { get; protected set; default = AnimationState.IDLE; }

        /**
         * The widget whose frame clock drives this animation.
         *
         * When `null`, the animation only advances with the manual clock of
         * `Singularity.Motion`.
         */
        public Gtk.Widget? widget { get; construct; }

        /** Delay in milliseconds between `play()` and the first moving frame. */
        public uint delay { get; set; default = 0; }

        /** What this animation does while Reduced Motion is on. */
        public ReducedMode reduced_mode { get; set; default = ReducedMode.JUMP; }

        /** Whether Reduced Motion applied when playback started. */
        protected bool reduced { get; private set; default = false; }

        /** Milliseconds elapsed since the end of the delay. */
        public double elapsed {
            get { return double.max(0.0, raw_elapsed - delay); }
        }

        /** Emitted on every frame while the animation is playing. */
        public signal void tick();

        /**
         * Advances the animation.
         *
         * @param elapsed_ms Milliseconds elapsed since the end of the delay,
         *                   already multiplied by the speed of `Singularity.Motion`.
         * @return `true` to keep animating, `false` to finish.
         */
        protected abstract bool on_update(double elapsed_ms);

        /** Called when playback starts from the beginning. */
        protected virtual void on_begin() {
        }

        /** Called when the animation jumps or settles to its final state. */
        protected virtual void on_finish() {
        }

        /**
         * Returns the value this animation currently holds.
         *
         * @return The current value, passed to the sink on every frame.
         */
        public virtual double current_value() {
            return 0.0;
        }

        /**
         * Sets a function that receives the value on every frame and the final
         * value once more at the end.
         *
         * Prefer it to a `tick` handler that reads the animation back, which
         * would keep the animation alive through its own closure.
         *
         * @param value_sink The receiver, or `null` to remove it.
         */
        public void set_sink(owned ValueSink? value_sink) {
            sink = (owned) value_sink;
        }

        /**
         * Creates a new animation bound to the given widget's frame clock.
         *
         * @param widget The widget whose frame clock will drive this animation.
         */
        protected Animation(Gtk.Widget? widget) {
            Object(widget: widget);
        }

        /**
         * Starts or resumes the animation.
         *
         * Has no effect if the animation is already playing. The first frame
         * after starting is already advanced.
         */
        public void play() {
            if (state == AnimationState.PLAYING) return;
            var motion = Singularity.Motion.get_default();
            if (state != AnimationState.PAUSED) {
                raw_elapsed = 0.0;
                reduced = motion.is_reduced() && reduced_mode != ReducedMode.FULL;
                on_begin();
            }
            state = AnimationState.PLAYING;
            last_time = motion.now_for(widget);
            motion.register(this);
            attach();
        }

        /** Pauses the animation at the current frame. Call `play()` to resume. */
        public void pause() {
            if (state != AnimationState.PLAYING) return;
            state = AnimationState.PAUSED;
            detach();
            Singularity.Motion.get_default().unregister(this);
        }

        /** Resets the animation to its initial state without emitting `done`. */
        public void reset() {
            state = AnimationState.IDLE;
            raw_elapsed = 0.0;
            detach();
            sink = null;
            Singularity.Motion.get_default().unregister(this);
        }

        /** Jumps to the final value and emits `done`. */
        public void skip() {
            if (state == AnimationState.FINISHED) return;
            on_finish();
            stop();
        }

        /**
         * Marks the animation as finished, detaches it from the frame clock,
         * sends the final value to the sink and emits `done`.
         */
        protected void stop() {
            state = AnimationState.FINISHED;
            detach();
            Singularity.Motion.get_default().unregister(this);
            if (sink != null) sink(current_value());
            sink = null;
            done();
        }

        /** Restarts the elapsed time from the end of the delay, keeping the state. */
        protected void restart_clock() {
            raw_elapsed = delay;
        }

        internal void clock_changed() {
            last_time = -1;
            if (state != AnimationState.PLAYING) return;
            if (Singularity.Motion.get_default().manual_clock) detach();
            else attach();
        }

        internal void step(int64 now) {
            if (state != AnimationState.PLAYING) return;
            if (last_time >= 0 && now > last_time) {
                raw_elapsed += (now - last_time) / 1000.0 / Singularity.Motion.get_default().duration_scale.clamp(0.01, 100.0);
            }
            if (now >= 0) last_time = now;
            if (reduced && reduced_mode == ReducedMode.JUMP) {
                on_finish();
                tick();
                stop();
                return;
            }
            if (raw_elapsed < delay) return;
            bool running = on_update(raw_elapsed - delay);
            if (sink != null) sink(current_value());
            tick();
            if (!running) stop();
        }

        private void attach() {
            if (widget == null || Singularity.Motion.get_default().manual_clock) return;
            if (tick_id == 0) tick_id = widget.add_tick_callback(on_tick);
            if (unrealize_id == 0) {
                unrealize_id = widget.unrealize.connect(() => {
                    if (state == AnimationState.PLAYING) skip();
                });
            }
        }

        private void detach() {
            if (tick_id != 0) {
                widget.remove_tick_callback(tick_id);
                tick_id = 0;
            }
            if (unrealize_id != 0) {
                SignalHandler.disconnect(widget, unrealize_id);
                unrealize_id = 0;
            }
        }

        private bool on_tick(Gtk.Widget widget, Gdk.FrameClock frame_clock) {
            if (state != AnimationState.PLAYING) {
                tick_id = 0;
                return false;
            }
            step(frame_clock.get_frame_time());
            if (state != AnimationState.PLAYING) {
                tick_id = 0;
                return false;
            }
            return true;
        }
    }
}
