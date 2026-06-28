using Gtk;

namespace Singularity.Widgets {

    public class StepIsland : Box {

        public signal void back_clicked();
        public signal void next_clicked();

        private Box dots_box;
        private Label title_lbl;
        private Button back_btn;
        private Button next_btn;
        private Box[] dots = {};
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

            back_btn = new Button.with_label("Back");
            back_btn.add_css_class("flat");
            back_btn.valign = Align.CENTER;
            back_btn.clicked.connect(() => back_clicked());
            append(back_btn);

            var center = new Box(Orientation.HORIZONTAL, 12);
            center.valign = Align.CENTER;
            center.margin_start = 4;
            center.margin_end = 4;

            dots_box = new Box(Orientation.HORIZONTAL, 7);
            dots_box.valign = Align.CENTER;
            center.append(dots_box);

            title_lbl = new Label("");
            title_lbl.add_css_class("singularity-step-island-title");
            center.append(title_lbl);
            append(center);

            for (int i = 0; i < _steps.length; i++) {
                var dot = new Box(Orientation.HORIZONTAL, 0);
                dot.add_css_class("singularity-step-dot");
                dot.valign = Align.CENTER;
                dots += dot;
                dots_box.append(dot);
            }

            next_btn = new Button.with_label("Next");
            next_btn.add_css_class("suggested-action");
            next_btn.valign = Align.CENTER;
            next_btn.clicked.connect(() => next_clicked());
            append(next_btn);

            update_state();
        }

        private void update_state() {
            for (int i = 0; i < dots.length; i++) {
                dots[i].remove_css_class("active");
                dots[i].remove_css_class("done");
                if (i == _step) dots[i].add_css_class("active");
                else if (i < _step) dots[i].add_css_class("done");
            }
            if (_step >= 0 && _step < _steps.length)
                title_lbl.label = _steps[_step];
        }
    }
}
