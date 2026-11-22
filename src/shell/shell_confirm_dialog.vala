using Gtk;

namespace Singularity.Shell {

    public class ShellConfirmDialog : ShellDialog {
        public signal void response (Singularity.Widgets.ConfirmDialog.Response r);

        private Box _custom_area;
        private Button _primary_btn;
        private Button _secondary_btn;
        private Button _cancel_btn;
        private bool _responded = false;
        private Singularity.Animation.TimedAnimation? _anim = null;

        public bool closes_on_primary { get; set; default = true; }

        public ShellConfirmDialog (Gtk.Application? app,
                                   string title,
                                   string? icon_name,
                                   string? description,
                                   string primary_label,
                                   Singularity.Widgets.ConfirmDialog.ActionStyle primary_style = Singularity.Widgets.ConfirmDialog.ActionStyle.DEFAULT) {
            Object (
                application: app,
                anchor_top: true,
                anchor_bottom: true,
                anchor_left: true,
                anchor_right: true
            );
            add_css_class ("power-confirm-dialog");

            var box = new Box (Orientation.VERTICAL, 14);
            box.halign = Align.CENTER;
            box.valign = Align.CENTER;
            box.add_css_class ("power-card");
            box.margin_top = 28;
            box.margin_bottom = 28;
            box.margin_start = 40;
            box.margin_end = 40;
            content_box.append (box);

            if (icon_name != null) {
                string shown = Singularity.Widgets.large_icon_name (icon_name);
                var icon = new Image.from_icon_name (shown);
                icon.pixel_size = 56;
                Singularity.Animation.IconMotion.play_when_shown(icon);
                if (shown.has_suffix ("-symbolic")) icon.add_css_class ("dim-label");
                box.append (icon);
            }

            var title_label = new Label (title);
            title_label.add_css_class ("title-1");
            title_label.wrap = true;
            title_label.max_width_chars = 32;
            title_label.justify = Justification.CENTER;
            box.append (title_label);

            if (description != null && description != "") {
                var desc_label = new Label (description);
                desc_label.add_css_class ("dim-label");
                desc_label.add_css_class ("body");
                desc_label.wrap = true;
                desc_label.wrap_mode = Pango.WrapMode.WORD_CHAR;
                desc_label.max_width_chars = 48;
                desc_label.justify = Justification.CENTER;
                box.append (desc_label);
            }

            _custom_area = new Box (Orientation.VERTICAL, 8);
            box.append (_custom_area);

            var btn_row = new Box (Orientation.HORIZONTAL, 12);
            btn_row.halign = Align.CENTER;
            btn_row.margin_top = 4;
            box.append (btn_row);

            _cancel_btn = pill (_("Cancel"));
            _cancel_btn.clicked.connect (() => respond (Singularity.Widgets.ConfirmDialog.Response.CANCEL));
            btn_row.append (_cancel_btn);

            _secondary_btn = pill ("");
            _secondary_btn.visible = false;
            _secondary_btn.clicked.connect (() => respond (Singularity.Widgets.ConfirmDialog.Response.SECONDARY));
            btn_row.append (_secondary_btn);

            _primary_btn = pill (primary_label);
            style_button (_primary_btn, primary_style);
            _primary_btn.clicked.connect (() => respond (Singularity.Widgets.ConfirmDialog.Response.PRIMARY));
            btn_row.append (_primary_btn);

            close_request.connect (() => {
                if (!_responded) {
                    _responded = true;
                    response (Singularity.Widgets.ConfirmDialog.Response.CANCEL);
                }
                return false;
            });

            hide ();
        }

        private static Button pill (string label) {
            var button = new Button.with_label (label);
            button.add_css_class ("pill");
            button.width_request = 128;
            return button;
        }

        private static void style_button (Button button, Singularity.Widgets.ConfirmDialog.ActionStyle style) {
            if (style == Singularity.Widgets.ConfirmDialog.ActionStyle.SUGGESTED) button.add_css_class ("suggested-action");
            else if (style == Singularity.Widgets.ConfirmDialog.ActionStyle.DESTRUCTIVE) button.add_css_class ("destructive-action");
        }

        public bool has_cancel {
            get { return _cancel_btn.visible; }
            set { _cancel_btn.visible = value; }
        }

        public Box custom_area {
            get { return _custom_area; }
        }

        public bool primary_sensitive {
            get { return _primary_btn.sensitive; }
            set { _primary_btn.sensitive = value; }
        }

        public void focus_primary () {
            _primary_btn.grab_focus ();
        }

        public void set_secondary (string label, Singularity.Widgets.ConfirmDialog.ActionStyle style = Singularity.Widgets.ConfirmDialog.ActionStyle.DEFAULT) {
            _secondary_btn.label = label;
            _secondary_btn.visible = true;
            style_button (_secondary_btn, style);
        }

        private void respond (Singularity.Widgets.ConfirmDialog.Response r) {
            _responded = true;
            response (r);
            if (r != Singularity.Widgets.ConfirmDialog.Response.PRIMARY || closes_on_primary) fade_out ();
        }

        public new void present () {
            open_dialog ();
        }

        public override void open_dialog () {
            _responded = false;
            opacity = 0;
            if (_anim != null) _anim.skip ();
            base.present ();
            _anim = new Singularity.Animation.TimedAnimation (this, 0, 1, 160,
                Singularity.Animation.TimedAnimation.Easing.EASE_OUT_CUBIC);
            _anim.tick.connect (() => { opacity = _anim.value; });
            _anim.done.connect (() => { _anim = null; });
            _anim.play ();
        }

        public override void close_dialog () {
            if (!_responded) {
                _responded = true;
                response (Singularity.Widgets.ConfirmDialog.Response.CANCEL);
            }
            fade_out ();
        }

        private void fade_out () {
            if (_anim != null) _anim.skip ();
            _anim = new Singularity.Animation.TimedAnimation (this, 1, 0, 120,
                Singularity.Animation.TimedAnimation.Easing.EASE_IN_CUBIC);
            _anim.tick.connect (() => { opacity = _anim.value; });
            _anim.done.connect (() => {
                _anim = null;
                hide ();
            });
            _anim.play ();
        }
    }
}
