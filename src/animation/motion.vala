using Singularity.Animation;

namespace Singularity {

    public class Motion : Object {

        public enum Duration {
            INSTANT = 0,
            MICRO = 90,
            SMALL = 140,
            MEDIUM = 220,
            LARGE = 320,
            PAGE = 380,
            SCENE = 600;

            public uint ms() {
                return (uint) this;
            }

            public uint exit_ms() {
                return (uint) Math.round((uint) this * EXIT_FACTOR);
            }

            public string css_name() {
                switch (this) {
                    case INSTANT: return "instant";
                    case MICRO: return "micro";
                    case SMALL: return "small";
                    case MEDIUM: return "medium";
                    case LARGE: return "large";
                    case PAGE: return "page";
                    default: return "scene";
                }
            }

            public static Duration[] all() {
                return { INSTANT, MICRO, SMALL, MEDIUM, LARGE, PAGE, SCENE };
            }
        }

        public enum Curve {
            LINEAR,
            STANDARD,
            ENTER,
            EXIT,
            EMPHASIZED;

            public void get_points(out double x1, out double y1, out double x2, out double y2) {
                switch (this) {
                    case STANDARD: x1 = 0.2; y1 = 0.0; x2 = 0.0; y2 = 1.0; return;
                    case ENTER: x1 = 0.05; y1 = 0.7; x2 = 0.1; y2 = 1.0; return;
                    case EXIT: x1 = 0.3; y1 = 0.0; x2 = 0.8; y2 = 0.15; return;
                    case EMPHASIZED: x1 = 0.22; y1 = 1.0; x2 = 0.36; y2 = 1.0; return;
                    default: x1 = 0.0; y1 = 0.0; x2 = 1.0; y2 = 1.0; return;
                }
            }

            public double ease(double t) {
                if (this == LINEAR) return t.clamp(0.0, 1.0);
                double x1, y1, x2, y2;
                get_points(out x1, out y1, out x2, out y2);
                return Bezier.solve(x1, y1, x2, y2, t);
            }

            public string to_css() {
                if (this == LINEAR) return "linear";
                double x1, y1, x2, y2;
                get_points(out x1, out y1, out x2, out y2);
                return "cubic-bezier(%s, %s, %s, %s)".printf(
                    css_number(x1), css_number(y1), css_number(x2), css_number(y2));
            }

            public string css_name() {
                switch (this) {
                    case STANDARD: return "standard";
                    case ENTER: return "enter";
                    case EXIT: return "exit";
                    case EMPHASIZED: return "emphasized";
                    default: return "linear";
                }
            }

            public static Curve[] all() {
                return { LINEAR, STANDARD, ENTER, EXIT, EMPHASIZED };
            }
        }

        public enum Spring {
            GENTLE,
            SNAPPY,
            BOUNCY;

            public double damping() {
                switch (this) {
                    case GENTLE: return 26.0;
                    case BOUNCY: return 14.0;
                    default: return 30.0;
                }
            }

            public double stiffness() {
                switch (this) {
                    case GENTLE: return 170.0;
                    case BOUNCY: return 300.0;
                    default: return 400.0;
                }
            }

            public double mass() {
                return 1.0;
            }

            public double damping_ratio() {
                return damping() / (2.0 * Math.sqrt(stiffness() * mass()));
            }
        }

        public enum Preset {
            FADE,
            FADE_SLIDE,
            SCALE_FADE
        }

        public const double EXIT_FACTOR = 0.7;
        public const uint STAGGER_STEP = 20;
        public const uint STAGGER_CAP = 8;
        public const double ENTER_SCALE = 0.96;
        public const double EXIT_SCALE = 0.98;
        public const double SLIDE_DISTANCE = 12.0;
        public const double REST_EPSILON = 0.001;

        private const string REDUCE_KEY = "reduce-motion";
        private const string SCALE_KEY = "motion-duration-scale";

        private static Motion? _default = null;

        private GLib.Settings? _settings = null;
        private Gtk.Settings? _gtk_settings = null;
        private GenericArray<Singularity.Animation.Animation> _active = new GenericArray<Singularity.Animation.Animation>();
        private int64 _manual_time = 0;
        private uint _fallback_id = 0;
        private Gtk.CssProvider? _css_provider = null;

        public bool reduce_motion { get; set; default = false; }

        public double duration_scale { get; set; default = 1.0; }

        public bool manual_clock { get; private set; default = false; }

        public bool paused {
            get { return manual_clock; }
            set {
                if (value == manual_clock) return;
                if (value) use_manual_clock(GLib.get_monotonic_time());
                else use_frame_clock();
            }
        }

        public int64 manual_time {
            get { return _manual_time; }
        }

        public signal void changed();

        public static Motion get_default() {
            if (_default == null) _default = new Motion();
            return _default;
        }

        construct {
            var source = GLib.SettingsSchemaSource.get_default();
            string schema_id = Runtime.desktop_settings_schema;
            var schema = source != null ? source.lookup(schema_id, true) : null;
            if (schema != null && schema.has_key(REDUCE_KEY)) {
                _settings = new GLib.Settings(schema_id);
                _settings.bind(REDUCE_KEY, this, "reduce-motion", SettingsBindFlags.DEFAULT);
                if (schema.has_key(SCALE_KEY)) {
                    _settings.bind(SCALE_KEY, this, "duration-scale", SettingsBindFlags.DEFAULT);
                }
            }
            track_gtk_settings();
            notify["reduce-motion"].connect(() => emit_changed());
            notify["duration-scale"].connect(() => emit_changed());
            if (GLib.Environment.get_variable("SINGULARITY_MOTION_CLOCK") == "manual") {
                use_manual_clock(0);
            }
            Singularity.Animation.MotionDebug.export_if_requested();
        }

        private void track_gtk_settings() {
            if (_gtk_settings != null) return;
            _gtk_settings = Gtk.Settings.get_default();
            if (_gtk_settings == null) return;
            _gtk_settings.notify["gtk-enable-animations"].connect(() => emit_changed());
        }

        private void emit_changed() {
            refresh_css();
            changed();
        }

        public bool animations_enabled {
            get {
                track_gtk_settings();
                return _gtk_settings == null || _gtk_settings.gtk_enable_animations;
            }
        }

        public bool is_reduced() {
            return reduce_motion || !animations_enabled;
        }

        public static bool reduced() {
            return get_default().is_reduced();
        }

        public void set_reduced(bool reduce) {
            reduce_motion = reduce;
            var source = GLib.SettingsSchemaSource.get_default();
            var schema = source != null ? source.lookup("org.gnome.desktop.interface", true) : null;
            if (schema == null || !schema.has_key("enable-animations")) return;
            var interface_settings = new GLib.Settings("org.gnome.desktop.interface");
            if (interface_settings.get_boolean("enable-animations") == reduce) {
                interface_settings.set_boolean("enable-animations", !reduce);
            }
        }

        public uint scale(uint ms) {
            double factor = duration_scale > 0.0 ? duration_scale : 1.0;
            return (uint) Math.round(ms * factor);
        }

        public static uint stagger_delay(uint index, uint step = STAGGER_STEP, uint cap = STAGGER_CAP) {
            if (reduced()) return 0;
            return uint.min(index, cap) * step;
        }

        public static void stagger(Playable[] items, uint step = STAGGER_STEP, uint cap = STAGGER_CAP) {
            for (uint i = 0; i < items.length; i++) {
                items[i].delay = stagger_delay(i, step, cap);
            }
        }

        public void use_manual_clock(int64 start_us = 0) {
            _manual_time = start_us;
            manual_clock = true;
            stop_fallback();
            foreach (var animation in active_snapshot()) animation.clock_changed();
        }

        public void use_frame_clock() {
            if (!manual_clock) return;
            manual_clock = false;
            foreach (var animation in active_snapshot()) animation.clock_changed();
            update_fallback();
        }

        public void advance(uint ms, uint hz = 0) {
            if (!manual_clock) use_manual_clock(GLib.get_monotonic_time());
            int64 target = _manual_time + (int64) ms * 1000;
            if (hz == 0) {
                _manual_time = target;
                step_all(_manual_time);
                return;
            }
            double frame = 1000000.0 / hz;
            double position = _manual_time;
            while (_manual_time < target) {
                position += frame;
                _manual_time = int64.min(target, (int64) Math.round(position));
                step_all(_manual_time);
            }
        }

        public void skip_all() {
            foreach (var animation in active_snapshot()) animation.skip();
        }

        public uint active_count {
            get { return _active.length; }
        }

        private Singularity.Animation.Animation[] active_snapshot() {
            Singularity.Animation.Animation[] list = {};
            foreach (var animation in _active) list += animation;
            return list;
        }

        private void step_all(int64 now) {
            foreach (var animation in active_snapshot()) animation.step(now);
        }

        internal int64 now_for(Gtk.Widget? widget) {
            if (manual_clock) return _manual_time;
            if (widget != null) {
                var clock = widget.get_frame_clock();
                if (clock != null) return clock.get_frame_time();
            }
            return -1;
        }

        internal void register(Singularity.Animation.Animation animation) {
            for (int i = 0; i < _active.length; i++) {
                if (_active[i] == animation) return;
            }
            _active.add(animation);
            update_fallback();
        }

        internal void unregister(Singularity.Animation.Animation animation) {
            _active.remove(animation);
            update_fallback();
        }

        private void update_fallback() {
            bool needed = false;
            if (!manual_clock) {
                foreach (var animation in _active) {
                    if (animation.widget == null) {
                        needed = true;
                        break;
                    }
                }
            }
            if (!needed) {
                stop_fallback();
                return;
            }
            if (_fallback_id != 0) return;
            _fallback_id = Timeout.add(8, () => {
                int64 now = GLib.get_monotonic_time();
                foreach (var animation in active_snapshot()) {
                    if (animation.widget == null) animation.step(now);
                }
                bool again = false;
                foreach (var animation in _active) {
                    if (animation.widget == null) again = true;
                }
                if (!again) _fallback_id = 0;
                return again;
            });
        }

        private void stop_fallback() {
            if (_fallback_id == 0) return;
            Source.remove(_fallback_id);
            _fallback_id = 0;
        }

        public string css() {
            var builder = new StringBuilder(":root {\n");
            bool reduce = is_reduced();
            foreach (var duration in Duration.all()) {
                uint ms = duration.ms();
                if (reduce && ms > Duration.SMALL.ms()) ms = Duration.SMALL.ms();
                builder.append_printf("  --motion-duration-%s: %ums;\n", duration.css_name(), scale(ms));
                builder.append_printf("  --motion-duration-%s-exit: %ums;\n", duration.css_name(),
                    scale((uint) Math.round(ms * EXIT_FACTOR)));
            }
            foreach (var curve in Curve.all()) {
                string value = reduce && curve != Curve.LINEAR ? Curve.LINEAR.to_css() : curve.to_css();
                builder.append_printf("  --motion-curve-%s: %s;\n", curve.css_name(), value);
            }
            builder.append("}\n");
            return builder.str;
        }

        public static bool css_variables_supported() {
            return Gtk.get_major_version() > 4 || Gtk.get_minor_version() >= 16;
        }

        public void install_css(Gdk.Display? display = Gdk.Display.get_default()) {
            track_gtk_settings();
            if (display == null || !css_variables_supported()) return;
            if (_css_provider == null) {
                _css_provider = new Gtk.CssProvider();
                Gtk.StyleContext.add_provider_for_display(display, _css_provider,
                    Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            }
            _css_provider.load_from_string(css());
        }

        private void refresh_css() {
            if (_css_provider != null) _css_provider.load_from_string(css());
        }

        private static string css_number(double value) {
            var buffer = new char[double.DTOSTR_BUF_SIZE];
            return value.format(buffer, "%g");
        }

        public static TimedAnimation tween(Object target, string property, double to,
                                           uint duration_ms = Duration.MEDIUM,
                                           Curve curve = Curve.STANDARD,
                                           Gtk.Widget? clock_widget = null) {
            var widget = clock_widget ?? (target as Gtk.Widget);
            double from = read_double(target, property);
            cancel_property(target, property);
            var animation = new TimedAnimation.with_curve(widget, from, to, duration_ms, curve);
            animation.reduced_mode = property == "opacity" ? ReducedMode.SHORTEN : ReducedMode.JUMP;
            bind_property_animation(target, property, animation);
            animation.set_sink((value) => {
                write_double(target, property, value);
                if (animation_finished(target, property)) release_data(target, property);
            });
            animation.play();
            return animation;
        }

        public static SpringAnimation spring_to(Object target, string property, double to,
                                                Spring spring = Spring.SNAPPY,
                                                double velocity = double.NAN,
                                                Gtk.Widget? clock_widget = null) {
            var existing = target.get_data<Singularity.Animation.Animation>(property_key(property));
            var running = existing as SpringAnimation;
            if (running != null && running.state == AnimationState.PLAYING) {
                running.set_current(read_double(target, property));
                if (!velocity.is_nan()) running.override_velocity(velocity);
                running.retarget(to);
                return running;
            }
            var widget = clock_widget ?? (target as Gtk.Widget);
            double from = read_double(target, property);
            double start_velocity = 0.0;
            var timed = existing as TimedAnimation;
            if (timed != null && timed.state == AnimationState.PLAYING) start_velocity = timed.velocity;
            if (!velocity.is_nan()) start_velocity = velocity;
            cancel_property(target, property);
            var animation = new SpringAnimation(widget, from, to, spring);
            animation.initial_velocity = start_velocity;
            bind_property_animation(target, property, animation);
            animation.set_sink((value) => {
                write_double(target, property, value);
                if (animation_finished(target, property)) release_data(target, property);
            });
            animation.play();
            return animation;
        }

        public static TimedAnimation tween_color(Gtk.Widget widget, Gdk.RGBA from, Gdk.RGBA to,
                                                 owned ColorCallback apply,
                                                 uint duration_ms = Duration.SMALL,
                                                 Curve curve = Curve.STANDARD) {
            var animation = new TimedAnimation.with_curve(widget, 0.0, 1.0, duration_ms, curve);
            animation.reduced_mode = ReducedMode.SHORTEN;
            animation.set_sink((value) => apply(mix_rgba(from, to, value)));
            animation.play();
            return animation;
        }

        public static TimedAnimation tween_size(Gtk.Widget widget, int to_width, int to_height,
                                                uint duration_ms = Duration.MEDIUM,
                                                Curve curve = Curve.STANDARD) {
            int from_width = widget.width_request >= 0 ? widget.width_request : widget.get_width();
            int from_height = widget.height_request >= 0 ? widget.height_request : widget.get_height();
            var animation = new TimedAnimation.with_curve(widget, 0.0, 1.0, duration_ms, curve);
            animation.set_sink((value) => apply_size(widget, from_width, from_height, to_width, to_height, value));
            animation.play();
            return animation;
        }

        private static void apply_size(Gtk.Widget widget, int from_width, int from_height,
                                       int to_width, int to_height, double progress) {
            int width = to_width < 0 ? -1 : (int) Math.round(from_width + (to_width - from_width) * progress);
            int height = to_height < 0 ? -1 : (int) Math.round(from_height + (to_height - from_height) * progress);
            widget.set_size_request(width, height);
        }

        public static Gdk.RGBA mix_rgba(Gdk.RGBA from, Gdk.RGBA to, double progress) {
            Gdk.RGBA result = {
                (float) (from.red + (to.red - from.red) * progress),
                (float) (from.green + (to.green - from.green) * progress),
                (float) (from.blue + (to.blue - from.blue) * progress),
                (float) (from.alpha + (to.alpha - from.alpha) * progress)
            };
            return result;
        }

        public static AnimationGroup reveal(Gtk.Widget widget, Preset preset = Preset.FADE_SLIDE,
                                            uint delay = 0) {
            var group = new AnimationGroup(GroupMode.PARALLEL);
            var bin = motion_bin_for(widget);
            bool reduce = reduced();
            var fade_target = bin != null ? (Gtk.Widget) bin : widget;
            fade_target.opacity = 0.0;
            if (bin != null && !reduce) {
                if (preset == Preset.FADE_SLIDE) {
                    bin.translate_y = SLIDE_DISTANCE;
                    group.add(tween(bin, "translate-y", 0.0, Duration.MEDIUM, Curve.ENTER));
                } else if (preset == Preset.SCALE_FADE) {
                    bin.scale = ENTER_SCALE;
                    group.add(tween(bin, "scale", 1.0, Duration.MEDIUM, Curve.ENTER));
                }
            }
            group.add(tween(fade_target, "opacity", 1.0, Duration.MEDIUM, Curve.ENTER));
            group.delay = delay;
            group.play();
            return group;
        }

        public static AnimationGroup conceal(Gtk.Widget widget, Preset preset = Preset.FADE,
                                             uint delay = 0) {
            var group = new AnimationGroup(GroupMode.PARALLEL);
            var bin = motion_bin_for(widget);
            var fade_target = bin != null ? (Gtk.Widget) bin : widget;
            uint exit = Duration.MEDIUM.exit_ms();
            if (bin != null && !reduced()) {
                if (preset == Preset.FADE_SLIDE) {
                    group.add(tween(bin, "translate-y", SLIDE_DISTANCE * 0.5, exit, Curve.EXIT));
                } else if (preset == Preset.SCALE_FADE) {
                    group.add(tween(bin, "scale", EXIT_SCALE, exit, Curve.EXIT));
                }
            }
            group.add(tween(fade_target, "opacity", 0.0, exit, Curve.EXIT));
            group.delay = delay;
            group.play();
            return group;
        }

        public static AnimationGroup cascade(Gtk.Widget[] widgets, Preset preset = Preset.FADE_SLIDE,
                                             uint step = STAGGER_STEP, uint cap = STAGGER_CAP) {
            var group = new AnimationGroup(GroupMode.PARALLEL);
            for (uint i = 0; i < widgets.length; i++) {
                group.add(reveal(widgets[i], preset, stagger_delay(i, step, cap)));
            }
            group.play();
            return group;
        }

        public static AnimationGroup crossfade(Gtk.Widget from, Gtk.Widget to) {
            var group = new AnimationGroup(GroupMode.PARALLEL);
            to.opacity = 0.0;
            to.visible = true;
            var out_animation = tween(from, "opacity", 0.0, Duration.SMALL, Curve.EXIT);
            out_animation.done.connect(() => {
                from.visible = false;
                from.opacity = 1.0;
            });
            group.add(out_animation);
            group.add(tween(to, "opacity", 1.0, Duration.MEDIUM, Curve.ENTER));
            group.play();
            return group;
        }

        public static void morph_transform(Graphene.Rect from, Graphene.Rect to,
                                           out double translate_x, out double translate_y,
                                           out double scale_x, out double scale_y) {
            float to_width = to.get_width();
            float to_height = to.get_height();
            scale_x = to_width > 0 ? from.get_width() / to_width : 1.0;
            scale_y = to_height > 0 ? from.get_height() / to_height : 1.0;
            translate_x = from.get_x() - to.get_x();
            translate_y = from.get_y() - to.get_y();
        }

        public static AnimationGroup morph(MotionBin bin, Graphene.Rect rect, Gtk.Widget relative_to,
                                           bool towards_rect = false, bool use_spring = true) {
            var group = new AnimationGroup(GroupMode.PARALLEL);
            Graphene.Rect bounds = Graphene.Rect();
            bool measured = !reduced() && bin.compute_bounds(relative_to, out bounds);
            if (!measured) {
                if (towards_rect) group.add(tween(bin, "opacity", 0.0, Duration.SMALL, Curve.LINEAR));
                else {
                    bin.opacity = 0.0;
                    group.add(tween(bin, "opacity", 1.0, Duration.SMALL, Curve.LINEAR));
                }
                group.play();
                return group;
            }
            double tx, ty, sx, sy;
            morph_transform(rect, bounds, out tx, out ty, out sx, out sy);
            bin.origin_x = 0.0;
            bin.origin_y = 0.0;
            if (!towards_rect) {
                bin.translate_x = tx;
                bin.translate_y = ty;
                bin.scale_x = sx;
                bin.scale_y = sy;
                tx = 0.0;
                ty = 0.0;
                sx = 1.0;
                sy = 1.0;
            }
            string[] properties = { "translate-x", "translate-y", "scale-x", "scale-y" };
            double[] targets = { tx, ty, sx, sy };
            for (int i = 0; i < properties.length; i++) {
                if (use_spring && !towards_rect) group.add(spring_to(bin, properties[i], targets[i], Spring.GENTLE));
                else group.add(tween(bin, properties[i], targets[i], Duration.LARGE, Curve.STANDARD));
            }
            if (towards_rect) group.add(tween(bin, "opacity", 0.0, Duration.LARGE, Curve.EXIT));
            group.play();
            return group;
        }

        public static MotionBin? motion_bin_for(Gtk.Widget widget) {
            var bin = widget as MotionBin;
            if (bin != null) return bin;
            return widget.get_parent() as MotionBin;
        }

        public static bool capture(Gtk.Widget widget, string png_path) {
            var texture = capture_texture(widget);
            if (texture == null) return false;
            return texture.save_to_png(png_path);
        }

        public static Gdk.Texture? capture_texture(Gtk.Widget widget) {
            int width = widget.get_width();
            int height = widget.get_height();
            var native = widget.get_native();
            if (width <= 0 || height <= 0 || native == null || !widget.get_mapped()) return null;
            var renderer = native.get_renderer();
            if (renderer == null) return null;
            var snapshot = new Gtk.Snapshot();
            var parent = widget.get_parent();
            if (parent != null) {
                Graphene.Point origin;
                if (!widget.compute_point(parent, Graphene.Point.zero(), out origin)) return null;
                snapshot.translate({ -origin.x, -origin.y });
                parent.snapshot_child(widget, snapshot);
            } else {
                for (var child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
                    widget.snapshot_child(child, snapshot);
                }
            }
            var viewport = Graphene.Rect();
            viewport.init(0, 0, width, height);
            var node = snapshot.to_node() ?? new Gsk.ColorNode({ 0.0f, 0.0f, 0.0f, 0.0f }, viewport);
            return renderer.render_texture(node, viewport);
        }

        private static string property_key(string property) {
            return "singularity-motion-" + property;
        }

        private static void bind_property_animation(Object target, string property,
                                                    Singularity.Animation.Animation animation) {
            target.set_data<Singularity.Animation.Animation>(property_key(property), animation);
        }

        private static bool animation_finished(Object target, string property) {
            var current = target.get_data<Singularity.Animation.Animation>(property_key(property));
            return current != null && current.state == AnimationState.FINISHED;
        }

        private static void release_data(Object target, string property) {
            target.set_data<Singularity.Animation.Animation?>(property_key(property), null);
        }

        public static void cancel(Object target, string property) {
            cancel_property(target, property);
        }

        private static void cancel_property(Object target, string property) {
            var existing = target.get_data<Singularity.Animation.Animation>(property_key(property));
            if (existing == null) return;
            target.set_data<Singularity.Animation.Animation?>(property_key(property), null);
            existing.reset();
        }

        private static double read_double(Object target, string property) {
            var spec = target.get_class().find_property(property);
            if (spec == null) return 0.0;
            var value = Value(spec.value_type);
            target.get_property(property, ref value);
            if (spec.value_type == typeof(float)) return value.get_float();
            if (spec.value_type == typeof(int)) return value.get_int();
            return value.get_double();
        }

        private static void write_double(Object target, string property, double number) {
            var spec = target.get_class().find_property(property);
            if (spec == null) return;
            var value = Value(spec.value_type);
            if (spec.value_type == typeof(float)) value.set_float((float) number);
            else if (spec.value_type == typeof(int)) value.set_int((int) Math.round(number));
            else value.set_double(number);
            target.set_property(property, value);
        }
    }

    public delegate void ColorCallback(Gdk.RGBA color);
}
