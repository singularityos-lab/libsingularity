using Gtk;

namespace Singularity.Widgets {

    public class StepIsland : Box {

        public signal void back_clicked();
        public signal void next_clicked();

        private StepDots dots_box;
        private Label title_lbl;
        private Button back_btn;
        private Button next_btn;
        private string[] _steps;
        private int _step = 0;

        public string next_label {
            get { return next_btn.label; }
            set { next_btn.label = value; }
        }

        public bool next_enabled {
            get { return next_btn.sensitive; }
            set { next_btn.sensitive = value; }
        }

        public bool back_visible {
            get { return back_btn.visible; }
            set { back_btn.visible = value; }
        }

        public int step {
            get { return _step; }
            set {
                _step = value;
                update_state();
            }
        }

        public StepIsland(string[] steps) {
            Object(orientation: Orientation.HORIZONTAL, spacing: 12);
            _steps = steps;

            add_css_class("singularity-step-island");
            halign = Align.CENTER;
            valign = Align.END;
            margin_bottom = 22;

            back_btn = new Button.with_label(_("Back"));
            back_btn.add_css_class("flat");
            back_btn.valign = Align.CENTER;
            back_btn.clicked.connect(() => back_clicked());
            append(back_btn);

            var center = new Box(Orientation.HORIZONTAL, 12);
            center.valign = Align.CENTER;
            center.margin_start = 4;
            center.margin_end = 4;

            dots_box = new StepDots(steps.length);
            dots_box.valign = Align.CENTER;
            center.append(dots_box);

            title_lbl = new Label("");
            title_lbl.add_css_class("singularity-step-island-title");
            center.append(title_lbl);
            append(center);

            next_btn = new Button.with_label(_("Next"));
            next_btn.add_css_class("suggested-action");
            next_btn.valign = Align.CENTER;
            next_btn.clicked.connect(() => next_clicked());
            append(next_btn);

            update_state();
        }

        private void update_state() {
            dots_box.go_to(_step);
            if (_step >= 0 && _step < _steps.length)
                title_lbl.label = _steps[_step];
        }
    }

    private class StepDots : Widget {
        private const double DOT = 8.0;
        private const double ACTIVE = 20.0;
        private const double GAP = 7.0;
        private const double IDLE_ALPHA = 0.3;
        private const double DONE_ALPHA = 0.7;

        private int count;
        private int target = 0;
        private double _position = 0.0;
        private bool placed = false;

        public double position {
            get { return _position; }
            set { _position = value; queue_draw(); }
        }

        public StepDots(int count) {
            this.count = int.max(0, count);
            add_css_class("singularity-step-dots");
        }

        public void go_to(int step) {
            target = step;
            if (!placed || !get_mapped()) {
                placed = true;
                Singularity.Motion.cancel(this, "position");
                position = step;
                return;
            }
            Singularity.Motion.tween(this, "position", step,
                Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.STANDARD);
        }

        public override SizeRequestMode get_request_mode() {
            return SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure(Orientation orientation, int for_size,
                                     out int minimum, out int natural,
                                     out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = -1;
            natural_baseline = -1;
            if (orientation == Orientation.HORIZONTAL) {
                double width = count > 0 ? (count - 1) * (DOT + GAP) + ACTIVE : 0.0;
                minimum = natural = (int) Math.ceil(width);
            } else {
                minimum = natural = (int) DOT;
            }
        }

        public override void snapshot(Snapshot snapshot) {
            var color = get_color();
            double top = (get_height() - DOT) / 2.0;
            double x = 0.0;
            for (int i = 0; i < count; i++) {
                double near = double.max(0.0, 1.0 - Math.fabs(i - _position));
                double width = DOT + (ACTIVE - DOT) * near;
                double rest = i < target ? DONE_ALPHA : IDLE_ALPHA;
                if (i == target) rest = 1.0;
                double alpha = rest + (1.0 - rest) * near;
                var dot_color = color;
                dot_color.alpha = (float) (color.alpha * alpha);
                var rect = Graphene.Rect() {
                    origin = { (float) x, (float) top },
                    size = { (float) width, (float) DOT }
                };
                var rounded = Gsk.RoundedRect();
                rounded.init_from_rect(rect, (float) (DOT / 2.0));
                snapshot.push_rounded_clip(rounded);
                snapshot.append_color(dot_color, rect);
                snapshot.pop();
                x += width + GAP;
            }
        }
    }
}
