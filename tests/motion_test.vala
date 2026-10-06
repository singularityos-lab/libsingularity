using Singularity;
using Singularity.Animation;

class Probe : Object {
    public double x { get; set; default = 0.0; }
}

Motion motion;

void fresh_clock() {
    motion.skip_all();
    motion.reduce_motion = false;
    motion.duration_scale = 1.0;
    motion.use_manual_clock(0);
}

void assert_close(double actual, double expected, double tolerance, string what) {
    if (Math.fabs(actual - expected) > tolerance) {
        error("%s: expected %.6f, got %.6f", what, expected, actual);
    }
}

double reference_bezier(double x1, double y1, double x2, double y2, double t) {
    const int SAMPLES = 200000;
    double previous_x = 0.0;
    double previous_y = 0.0;
    for (int i = 1; i <= SAMPLES; i++) {
        double s = (double) i / SAMPLES;
        double inverse = 1.0 - s;
        double x = 3 * inverse * inverse * s * x1 + 3 * inverse * s * s * x2 + s * s * s;
        double y = 3 * inverse * inverse * s * y1 + 3 * inverse * s * s * y2 + s * s * s;
        if (x >= t) {
            double span = x - previous_x;
            double local = span > 0 ? (t - previous_x) / span : 0.0;
            return previous_y + (y - previous_y) * local;
        }
        previous_x = x;
        previous_y = y;
    }
    return 1.0;
}

void test_tokens() {
    assert(Motion.Duration.INSTANT.ms() == 0);
    assert(Motion.Duration.MICRO.ms() == 90);
    assert(Motion.Duration.SMALL.ms() == 140);
    assert(Motion.Duration.MEDIUM.ms() == 220);
    assert(Motion.Duration.LARGE.ms() == 320);
    assert(Motion.Duration.PAGE.ms() == 380);
    assert(Motion.Duration.SCENE.ms() == 600);
    assert(Motion.Duration.MEDIUM.exit_ms() == 154);
    assert(Motion.Curve.STANDARD.to_css() == "cubic-bezier(0.2, 0, 0, 1)");
    assert(Motion.Curve.ENTER.to_css() == "cubic-bezier(0.05, 0.7, 0.1, 1)");
    assert(Motion.Curve.EXIT.to_css() == "cubic-bezier(0.3, 0, 0.8, 0.15)");
    assert(Motion.Curve.EMPHASIZED.to_css() == "cubic-bezier(0.22, 1, 0.36, 1)");
    assert(Motion.Spring.GENTLE.damping() == 26 && Motion.Spring.GENTLE.stiffness() == 170);
    assert(Motion.Spring.SNAPPY.damping() == 30 && Motion.Spring.SNAPPY.stiffness() == 400);
    assert(Motion.Spring.BOUNCY.damping() == 14 && Motion.Spring.BOUNCY.stiffness() == 300);
    string css = motion.css();
    assert("--motion-duration-medium: 220ms;" in css);
    assert("--motion-duration-medium-exit: 154ms;" in css);
    assert("--motion-curve-enter: cubic-bezier(0.05, 0.7, 0.1, 1);" in css);
}

void test_bezier_math() {
    foreach (var curve in Motion.Curve.all()) {
        assert(curve.ease(0.0) == 0.0);
        assert(curve.ease(1.0) == 1.0);
        double x1, y1, x2, y2;
        curve.get_points(out x1, out y1, out x2, out y2);
        for (double t = 0.05; t < 1.0; t += 0.05) {
            assert_close(curve.ease(t), reference_bezier(x1, y1, x2, y2, t), 1e-4, curve.css_name());
        }
    }
    assert_close(Motion.Curve.LINEAR.ease(0.37), 0.37, 1e-12, "linear");
    assert(Motion.Curve.ENTER.ease(0.2) > Motion.Curve.STANDARD.ease(0.2));
    assert(Motion.Curve.EXIT.ease(0.5) < 0.5);
    double previous = 0.0;
    for (double t = 0.0; t <= 1.0; t += 0.01) {
        double value = Motion.Curve.STANDARD.ease(t);
        assert(value >= previous - 1e-9);
        previous = value;
    }
}

void test_timed_frame_rates() {
    uint[] rates = { 60, 120, 144 };
    double[] halfway = {};
    int64[] finished_at = {};
    foreach (uint hz in rates) {
        fresh_clock();
        var animation = new TimedAnimation.with_curve(null, 0.0, 100.0, Motion.Duration.MEDIUM, Motion.Curve.STANDARD);
        int64 done_time = -1;
        animation.done.connect(() => done_time = motion.manual_time);
        animation.play();
        motion.advance(100, hz);
        halfway += animation.value;
        motion.advance(200, hz);
        assert(animation.state == AnimationState.FINISHED);
        assert(animation.value == 100.0);
        finished_at += done_time;
    }
    double expected = 100.0 * Motion.Curve.STANDARD.ease(100.0 / 220.0);
    for (int i = 0; i < rates.length; i++) {
        assert_close(halfway[i], expected, 1e-6, "value at 100 ms, %u Hz".printf(rates[i]));
        double frame_ms = 1000.0 / rates[i];
        assert(finished_at[i] >= 220000);
        assert(finished_at[i] <= 220000 + (int64) (frame_ms * 1000) + 1);
    }
}

void test_timed_bezier_and_skip() {
    fresh_clock();
    var animation = new TimedAnimation(null, 0.0, 1.0, 300);
    animation.set_bezier(0.3, 0.0, 0.8, 0.15);
    animation.play();
    motion.advance(150);
    assert_close(animation.value, Motion.Curve.EXIT.ease(0.5), 1e-9, "custom bezier");
    bool done = false;
    animation.done.connect(() => done = true);
    animation.skip();
    assert(done);
    assert(animation.value == 1.0);
    assert(motion.active_count == 0);
}

void test_first_frame_advances() {
    fresh_clock();
    var animation = new TimedAnimation.with_curve(null, 0.0, 1.0, Motion.Duration.MEDIUM, Motion.Curve.LINEAR);
    animation.play();
    motion.advance(16);
    assert(animation.value > 0.0);
}

void test_pause_resume() {
    fresh_clock();
    var animation = new TimedAnimation.with_curve(null, 0.0, 1.0, 200, Motion.Curve.LINEAR);
    animation.play();
    motion.advance(50);
    animation.pause();
    motion.advance(500);
    assert_close(animation.value, 0.25, 1e-9, "paused value");
    animation.play();
    motion.advance(50);
    assert_close(animation.value, 0.5, 1e-9, "resumed value");
}

void test_spring_settles() {
    foreach (var spring in new Motion.Spring[] { Motion.Spring.GENTLE, Motion.Spring.SNAPPY, Motion.Spring.BOUNCY }) {
        fresh_clock();
        var animation = new SpringAnimation(null, 0.0, 1.0, spring);
        double estimated = animation.estimated_duration;
        double peak = 0.0;
        int64 done_time = -1;
        animation.done.connect(() => done_time = motion.manual_time);
        animation.tick.connect(() => peak = double.max(peak, animation.value));
        animation.play();
        motion.advance(3000, 120);
        assert(animation.state == AnimationState.FINISHED);
        assert(animation.value == 1.0);
        assert(done_time > 0);
        assert_close(done_time / 1000.0, estimated, 1000.0 / 120 + 1, "settle time");
        if (spring == Motion.Spring.BOUNCY) assert(peak > 1.1);
        if (spring == Motion.Spring.GENTLE) assert(peak < 1.001);
    }
    assert_close(SpringSolver.settle_time(30, 400, 1, -1, 0), 0.49, 0.1, "snappy settle");
}

void test_spring_closed_form() {
    double position, speed;
    SpringSolver.evaluate(30, 400, 1, -1.0, 0.0, 0.0, out position, out speed);
    assert_close(position, -1.0, 1e-12, "start position");
    assert_close(speed, 0.0, 1e-9, "start speed");
    double dt = 1e-6;
    double previous, unused;
    foreach (double damping in new double[] { 14.0, 40.0, 60.0 }) {
        SpringSolver.evaluate(damping, 400, 1, -1.0, 3.0, 0.1, out previous, out unused);
        SpringSolver.evaluate(damping, 400, 1, -1.0, 3.0, 0.1 + dt, out position, out speed);
        assert_close((position - previous) / dt, speed, 1e-3, "velocity is the derivative");
    }
}

void test_spring_interruption_keeps_velocity() {
    fresh_clock();
    var animation = new SpringAnimation(null, 0.0, 100.0, Motion.Spring.SNAPPY);
    animation.play();
    motion.advance(60, 120);
    double value = animation.value;
    double velocity = animation.velocity;
    assert(velocity > 0.0);
    animation.retarget(-50.0);
    assert(animation.value == value);
    assert(animation.velocity == velocity);
    motion.advance(1, 0);
    assert_close(animation.value, value + velocity / 1000.0, 0.2, "no jump after retarget");
    motion.advance(3000, 120);
    assert(animation.value == -50.0);
}

void test_spring_to_hands_over_velocity() {
    fresh_clock();
    var probe = new Probe();
    Motion.tween(probe, "x", 100.0, Motion.Duration.LARGE, Motion.Curve.STANDARD);
    motion.advance(40, 120);
    double x = probe.x;
    var spring = Motion.spring_to(probe, "x", 0.0, Motion.Spring.SNAPPY);
    assert(spring.initial_velocity > 0.0);
    motion.advance(8, 0);
    assert(probe.x > x);
    motion.advance(3000, 120);
    assert(probe.x == 0.0);
    var again = Motion.spring_to(probe, "x", 50.0);
    motion.advance(30, 120);
    double mid_velocity = again.velocity;
    var same = Motion.spring_to(probe, "x", 80.0);
    assert(same == again);
    assert(same.velocity == mid_velocity);
}

void test_gesture_release() {
    fresh_clock();
    var animation = new SpringAnimation(null, 0.0, 0.0, Motion.Spring.SNAPPY);
    for (int i = 0; i <= 50; i++) {
        animation.track_at(1000000 + i * 2000, i * 2.0);
    }
    assert(animation.tracking);
    assert(animation.value == 100.0);
    assert_close(animation.velocity, 1000.0, 1.0, "tracked velocity");
    animation.release(300.0);
    assert(!animation.tracking);
    assert_close(animation.initial_velocity, 1000.0, 1.0, "release velocity");
    motion.advance(1);
    assert(animation.value > 100.0);
    motion.advance(3000, 144);
    assert(animation.value == 300.0);
}

void test_keyframes() {
    fresh_clock();
    var animation = new KeyframeAnimation(null, 400, 0.0);
    animation.add(0.25, 10.0, Motion.Curve.LINEAR).add(0.75, -10.0, Motion.Curve.LINEAR).add(1.0, 0.0, Motion.Curve.LINEAR);
    assert_close(animation.value_at(0.125), 5.0, 1e-9, "first segment");
    assert_close(animation.value_at(0.5), 0.0, 1e-9, "middle segment");
    animation.play();
    motion.advance(300);
    assert_close(animation.value, -10.0, 1e-9, "keyframe at 300 ms");
    motion.advance(200);
    assert(animation.state == AnimationState.FINISHED);
    assert(animation.value == 0.0);
}

void test_stagger() {
    fresh_clock();
    uint[] expected = { 0, 20, 40, 60, 80, 100, 120, 140, 160, 160, 160 };
    for (uint i = 0; i < expected.length; i++) assert(Motion.stagger_delay(i) == expected[i]);
    Playable[] items = {};
    TimedAnimation[] animations = {};
    for (int i = 0; i < 12; i++) {
        var animation = new TimedAnimation.with_curve(null, 0.0, 1.0, 100, Motion.Curve.LINEAR);
        animations += animation;
        items += animation;
    }
    Motion.stagger(items);
    foreach (var animation in animations) animation.play();
    motion.advance(50);
    assert_close(animations[0].value, 0.5, 1e-9, "first item");
    assert_close(animations[1].value, 0.3, 1e-9, "second item");
    assert(animations[3].value == 0.0);
    motion.advance(150);
    assert_close(animations[8].value, 0.4, 1e-9, "ninth item");
    assert(animations[8].value == animations[11].value);
    assert(animations[7].value > animations[8].value);
}

void test_groups() {
    fresh_clock();
    var first = new TimedAnimation(null, 0.0, 1.0, 100, TimedAnimation.Easing.LINEAR);
    var second = new TimedAnimation(null, 0.0, 1.0, 100, TimedAnimation.Easing.LINEAR);
    var sequence = new AnimationGroup(GroupMode.SEQUENCE);
    sequence.add(first).add(second);
    bool done = false;
    sequence.done.connect(() => done = true);
    sequence.play();
    motion.advance(50);
    assert(second.state == AnimationState.IDLE);
    motion.advance(60);
    assert(first.state == AnimationState.FINISHED);
    assert(second.state == AnimationState.PLAYING);
    assert(!done);
    motion.advance(120);
    assert(done);

    var a = new TimedAnimation(null, 0.0, 1.0, 100, TimedAnimation.Easing.LINEAR);
    var b = new TimedAnimation(null, 0.0, 1.0, 300, TimedAnimation.Easing.LINEAR);
    var parallel = new AnimationGroup(GroupMode.PARALLEL);
    parallel.add(a).add(b);
    int count = 0;
    parallel.done.connect(() => count++);
    parallel.play();
    motion.advance(150);
    assert(count == 0);
    motion.advance(200);
    assert(count == 1);

    var c = new TimedAnimation(null, 0.0, 1.0, 1000, TimedAnimation.Easing.LINEAR);
    var d = new TimedAnimation(null, 0.0, 1.0, 1000, TimedAnimation.Easing.LINEAR);
    var skipped = new AnimationGroup(GroupMode.SEQUENCE);
    skipped.add(c).add(d);
    bool skipped_done = false;
    skipped.done.connect(() => skipped_done = true);
    skipped.play();
    skipped.skip();
    assert(skipped_done && c.value == 1.0 && d.value == 1.0);
}

void test_reduce_motion() {
    fresh_clock();
    motion.reduce_motion = true;
    assert(Motion.reduced());
    assert(Motion.stagger_delay(5) == 0);
    var jump = new TimedAnimation.with_curve(null, 0.0, 1.0, Motion.Duration.LARGE, Motion.Curve.STANDARD);
    bool jumped = false;
    jump.done.connect(() => jumped = true);
    jump.play();
    motion.advance(1);
    assert(jumped && jump.value == 1.0);

    var fade = new TimedAnimation.with_curve(null, 0.0, 1.0, Motion.Duration.LARGE, Motion.Curve.ENTER);
    fade.reduced_mode = ReducedMode.SHORTEN;
    fade.play();
    motion.advance(70);
    assert_close(fade.value, 0.5, 1e-9, "shortened fade is linear 140 ms");
    motion.advance(71);
    assert(fade.state == AnimationState.FINISHED);

    var spring = new SpringAnimation(null, 0.0, 10.0, Motion.Spring.BOUNCY);
    double peak = 0.0;
    spring.tick.connect(() => peak = double.max(peak, spring.value));
    spring.play();
    motion.advance(70);
    assert_close(spring.value, 5.0, 1e-9, "reduced spring arrives linearly");
    motion.advance(100);
    assert(spring.value == 10.0 && peak <= 10.0);

    var full = new TimedAnimation.with_curve(null, 0.0, 1.0, 200, Motion.Curve.LINEAR);
    full.reduced_mode = ReducedMode.FULL;
    full.play();
    motion.advance(100);
    assert_close(full.value, 0.5, 1e-9, "full mode ignores reduce motion");

    assert("--motion-duration-scene: 140ms;" in motion.css());
    assert("--motion-curve-standard: linear;" in motion.css());
    motion.reduce_motion = false;
    assert("--motion-duration-scene: 600ms;" in motion.css());
}

void test_reduce_motion_setting() {
    fresh_clock();
    var settings = new GLib.Settings("dev.sinty.motiontest");
    settings.set_boolean("reduce-motion", true);
    assert(motion.reduce_motion);
    assert(Motion.reduced());
    settings.set_boolean("reduce-motion", false);
    assert(!Motion.reduced());
    settings.set_double("motion-duration-scale", 2.0);
    assert(motion.duration_scale == 2.0);
    var animation = new TimedAnimation.with_curve(null, 0.0, 1.0, 100, Motion.Curve.LINEAR);
    animation.play();
    motion.advance(100);
    assert_close(animation.value, 0.5, 1e-9, "duration scale doubles the time");
    assert("--motion-duration-medium: 440ms;" in motion.css());
    settings.set_double("motion-duration-scale", 1.0);
}

void test_skip_all() {
    fresh_clock();
    var a = new TimedAnimation(null, 0.0, 5.0, 1000);
    var b = new SpringAnimation(null, 0.0, 7.0);
    a.play();
    b.play();
    motion.advance(10);
    assert(motion.active_count == 2);
    motion.skip_all();
    assert(motion.active_count == 0);
    assert(a.value == 5.0 && b.value == 7.0);
}

void test_morph_math() {
    var from = Graphene.Rect();
    from.init(10, 500, 48, 48);
    var to = Graphene.Rect();
    to.init(200, 100, 480, 320);
    double tx, ty, sx, sy;
    Motion.morph_transform(from, to, out tx, out ty, out sx, out sy);
    assert(tx == -190 && ty == 400);
    assert_close(sx, 0.1, 1e-6, "scale x");
    assert_close(sy, 0.15, 1e-6, "scale y");
}

void test_velocity_tracker() {
    var tracker = new VelocityTracker();
    tracker.add(0, 0.0);
    tracker.add(500000, 10.0);
    tracker.add(510000, 20.0);
    tracker.add(520000, 30.0);
    assert_close(tracker.velocity, 1000.0, 1e-6, "old samples are dropped");
}

void test_helpers_release_animations() {
    fresh_clock();
    var probe = new Probe();
    bool finalized = false;
    var animation = Motion.tween(probe, "x", 10.0, Motion.Duration.SMALL, Motion.Curve.STANDARD);
    animation.weak_ref(() => finalized = true);
    var group = new AnimationGroup(GroupMode.PARALLEL);
    group.add(animation);
    bool group_finalized = false;
    group.weak_ref(() => group_finalized = true);
    bool group_done = false;
    group.done.connect(() => group_done = true);
    group.play();
    group = null;
    animation = null;
    assert(!finalized && !group_finalized);
    motion.advance(200);
    assert(probe.x == 10.0);
    assert(group_done);
    assert(finalized);
    assert(group_finalized);
}

void test_page_direction() {
    assert(Singularity.Animation.PageTransition.direction_between(0, 2) == Singularity.Animation.PageDirection.FORWARD);
    assert(Singularity.Animation.PageTransition.direction_between(3, 1) == Singularity.Animation.PageDirection.BACK);
    assert(Singularity.Animation.PageTransition.direction_between(-1, 1) == Singularity.Animation.PageDirection.FORWARD);
    assert(Singularity.Animation.PageTransition.is_page_like(Gtk.StackTransitionType.CROSSFADE));
    assert(Singularity.Animation.PageTransition.is_page_like(Gtk.StackTransitionType.SLIDE_LEFT_RIGHT));
    assert(!Singularity.Animation.PageTransition.is_page_like(Gtk.StackTransitionType.NONE));
    assert(!Singularity.Animation.PageTransition.is_page_like(Gtk.StackTransitionType.SLIDE_UP_DOWN));
    assert_close(Singularity.Animation.PageTransition.DISTANCE, 24.0, 0.0001, "page distance");
}

void test_popover_origin() {
    double x, y;
    Singularity.Animation.PopoverMotion.origin_for(Gtk.PositionType.BOTTOM, out x, out y);
    assert_close(x, 0.5, 0.0001, "bottom x");
    assert_close(y, 0.0, 0.0001, "bottom y");
    Singularity.Animation.PopoverMotion.origin_for(Gtk.PositionType.TOP, out x, out y);
    assert_close(y, 1.0, 0.0001, "top y");
    Singularity.Animation.PopoverMotion.origin_for(Gtk.PositionType.RIGHT, out x, out y);
    assert_close(x, 0.0, 0.0001, "right x");
}

void test_skeleton_phase() {
    assert_close(Singularity.Widgets.Skeleton.sheen_phase(0), 0.0, 0.0001, "phase start");
    assert_close(Singularity.Widgets.Skeleton.sheen_phase(600000), 0.5, 0.0001, "phase half");
    assert_close(Singularity.Widgets.Skeleton.sheen_phase(1200000 + 300000), 0.25, 0.0001, "phase wraps");
    assert_close(Singularity.Widgets.Skeleton.sheen_phase(3000000, 5.0), 0.5, 0.0001, "phase follows slow animations");
}

void test_focus_ring_interpolate() {
    var from = Graphene.Rect();
    from.init(0, 0, 100, 20);
    var to = Graphene.Rect();
    to.init(200, 100, 40, 40);
    var half = Singularity.Animation.FocusRing.interpolate(from, to, 0.5);
    assert_close(half.get_x(), 100, 0.001, "ring x");
    assert_close(half.get_y(), 50, 0.001, "ring y");
    assert_close(half.get_width(), 70, 0.001, "ring width");
    assert_close(half.get_height(), 30, 0.001, "ring height");
}

void test_widget_morph_math() {
    var fit = Singularity.Animation.WidgetMorph.contain(800, 600, 1000, 500);
    assert_close(fit.get_width(), 800, 0.01, "contain width");
    assert_close(fit.get_height(), 400, 0.01, "contain height");
    assert_close(fit.get_y(), 100, 0.01, "contain top");
    var bounds = Graphene.Rect();
    bounds.init(10, 20, 800, 600);
    var target = Graphene.Rect();
    target.init(100, 100, 80, 80);
    double tx, ty, s;
    assert(Singularity.Animation.WidgetMorph.transform_for(bounds, fit, target, out tx, out ty, out s));
    assert_close(s, 0.1, 0.0001, "morph scale keeps proportions");
    assert_close(bounds.get_x() + tx + s * (fit.get_x() + fit.get_width() / 2.0), 140, 0.001, "morph centre x");
    assert_close(bounds.get_y() + ty + s * (fit.get_y() + fit.get_height() / 2.0), 140, 0.001, "morph centre y");
}

void test_snapshot_crossfade_without_display() {
    bool changed = false;
    Singularity.Animation.SnapshotCrossfade.run(() => changed = true);
    assert(changed);
    assert(Singularity.Animation.SnapshotCrossfade.active_count == 0);
}

int main(string[] args) {
    string fixtures = args.length > 1 ? args[1] : "tests/fixtures/motion";
    string schemas;
    try {
        schemas = DirUtils.make_tmp("motion-schemas-XXXXXX");
        int status;
        Process.spawn_sync(null, { "glib-compile-schemas", "--targetdir", schemas, fixtures },
            null, SpawnFlags.SEARCH_PATH, null, null, null, out status);
        if (status != 0) error("glib-compile-schemas failed");
    } catch (Error e) {
        error("%s", e.message);
    }
    GLib.Environment.set_variable("GSETTINGS_SCHEMA_DIR", schemas, true);
    GLib.Environment.set_variable("GSETTINGS_BACKEND", "memory", true);
    Runtime.desktop_settings_schema = "dev.sinty.motiontest";
    Test.init(ref args);
    motion = Motion.get_default();
    motion.use_manual_clock(0);
    Test.add_func("/motion/tokens", test_tokens);
    Test.add_func("/motion/bezier", test_bezier_math);
    Test.add_func("/motion/timed-frame-rates", test_timed_frame_rates);
    Test.add_func("/motion/timed-bezier-skip", test_timed_bezier_and_skip);
    Test.add_func("/motion/first-frame", test_first_frame_advances);
    Test.add_func("/motion/pause-resume", test_pause_resume);
    Test.add_func("/motion/spring-settles", test_spring_settles);
    Test.add_func("/motion/spring-closed-form", test_spring_closed_form);
    Test.add_func("/motion/spring-interruption", test_spring_interruption_keeps_velocity);
    Test.add_func("/motion/spring-to-handover", test_spring_to_hands_over_velocity);
    Test.add_func("/motion/gesture-release", test_gesture_release);
    Test.add_func("/motion/keyframes", test_keyframes);
    Test.add_func("/motion/stagger", test_stagger);
    Test.add_func("/motion/groups", test_groups);
    Test.add_func("/motion/reduce-motion", test_reduce_motion);
    Test.add_func("/motion/reduce-motion-setting", test_reduce_motion_setting);
    Test.add_func("/motion/skip-all", test_skip_all);
    Test.add_func("/motion/morph-math", test_morph_math);
    Test.add_func("/motion/velocity-tracker", test_velocity_tracker);
    Test.add_func("/motion/helpers-release", test_helpers_release_animations);
    Test.add_func("/motion/page-direction", test_page_direction);
    Test.add_func("/motion/popover-origin", test_popover_origin);
    Test.add_func("/motion/skeleton-phase", test_skeleton_phase);
    Test.add_func("/motion/focus-ring-interpolate", test_focus_ring_interpolate);
    Test.add_func("/motion/widget-morph-math", test_widget_morph_math);
    Test.add_func("/motion/snapshot-crossfade-no-display", test_snapshot_crossfade_without_display);
    return Test.run();
}
