using Gtk;

namespace Singularity.Widgets {

    public class ThemePreview : Gtk.DrawingArea {

        private bool _shell_dark = true;
        private bool _app_dark = false;
        private Gdk.RGBA accent;

        public bool shell_dark {
            get { return _shell_dark; }
            set { _shell_dark = value; queue_draw(); }
        }

        public bool app_dark {
            get { return _app_dark; }
            set { _app_dark = value; queue_draw(); }
        }

        public ThemePreview(bool shell_dark = true, bool app_dark = false) {
            _shell_dark = shell_dark;
            _app_dark = app_dark;
            accent = Gdk.RGBA();
            accent.parse("#3584e4");
            set_size_request(-1, 120);
            set_draw_func(draw);
        }

        public void set_accent_hex(string hex) {
            var c = Gdk.RGBA();
            if (hex != "" && c.parse(hex)) { accent = c; queue_draw(); }
        }

        private static void round_rect(Cairo.Context ctx, double x, double y, double w, double h, double r) {
            double PI = Math.PI;
            ctx.new_sub_path();
            ctx.arc(x + w - r, y + r,     r, -0.5 * PI, 0);
            ctx.arc(x + w - r, y + h - r, r, 0,          0.5 * PI);
            ctx.arc(x + r,     y + h - r, r, 0.5 * PI,   PI);
            ctx.arc(x + r,     y + r,     r, PI,         1.5 * PI);
            ctx.close_path();
        }

        private void draw(DrawingArea area, Cairo.Context ctx, int pw, int ph) {
            bool shell_dark = _shell_dark;
            bool app_dark = _app_dark;
            Gdk.RGBA ac = accent;

            double PI = Math.PI;
            double pad = 8.0;

            double d = shell_dark ? 0.10 : 0.86;
            ctx.set_source_rgb(d, d, d + 0.01);
            round_rect(ctx, 0, 0, pw, ph, 10);
            ctx.fill();

            double s_bg = shell_dark ? 0.17 : 0.97;
            double s_fg = shell_dark ? 0.78 : 0.32;
            double panelH = 16.0;

            round_rect(ctx, pad, pad, pw - pad * 2, panelH, 5);
            ctx.set_source_rgb(s_bg, s_bg, s_bg);
            ctx.fill();
            ctx.set_source_rgba(s_fg, s_fg, s_fg, 0.45);
            ctx.rectangle(pw / 2 - 13, pad + panelH / 2 - 2, 26, 4);
            ctx.fill();
            for (int di = 0; di < 3; di++) {
                if (di == 0) ctx.set_source_rgba(ac.red, ac.green, ac.blue, 0.9);
                else ctx.set_source_rgba(s_fg, s_fg, s_fg, 0.5);
                ctx.arc(pw - pad - 9 - di * 9, pad + panelH / 2, 2.3, 0, 2 * PI);
                ctx.fill();
            }

            double bodyY = pad + panelH + 8;
            double bodyH = ph - bodyY - pad;

            double sbW = 72.0;
            double sbX = pw - pad - sbW;
            round_rect(ctx, sbX, bodyY, sbW, bodyH, 6);
            ctx.set_source_rgb(s_bg, s_bg, s_bg);
            ctx.fill();
            double tg = 6.0;
            double tw = (sbW - tg * 3) / 2.0;
            double th = (bodyH - tg * 3) / 2.0;
            for (int ti = 0; ti < 4; ti++) {
                double txx = sbX + tg + (ti % 2) * (tw + tg);
                double tyy = bodyY + tg + (ti / 2) * (th + tg);
                bool tactive = (ti == 0);
                if (tactive) ctx.set_source_rgba(ac.red, ac.green, ac.blue, 0.85);
                else ctx.set_source_rgba(s_fg, s_fg, s_fg, shell_dark ? 0.16 : 0.12);
                round_rect(ctx, txx, tyy, tw, th, 4);
                ctx.fill();
                if (tactive) ctx.set_source_rgba(1, 1, 1, 0.9);
                else ctx.set_source_rgba(s_fg, s_fg, s_fg, 0.45);
                ctx.arc(txx + tw / 2, tyy + th / 2, 2.6, 0, 2 * PI);
                ctx.fill();
            }

            double a_bg = app_dark ? 0.17 : 0.99;
            double a_hb = app_dark ? 0.13 : 0.93;
            double a_fg = app_dark ? 0.80 : 0.28;
            double wx = pad;
            double wy = bodyY;
            double ww = sbX - 8 - wx;
            double wh = bodyH;
            double rr = 6.0;
            double hbH = 16.0;

            round_rect(ctx, wx, wy, ww, wh, rr);
            ctx.set_source_rgb(a_bg, a_bg, a_bg);
            ctx.fill();
            ctx.save();
            round_rect(ctx, wx, wy, ww, wh, rr);
            ctx.clip();
            ctx.set_source_rgb(a_hb, a_hb, a_hb);
            ctx.rectangle(wx, wy, ww, hbH);
            ctx.fill();
            ctx.restore();
            ctx.set_source_rgba(a_fg, a_fg, a_fg, 0.16);
            ctx.rectangle(wx, wy + hbH, ww, 0.5);
            ctx.fill();
            ctx.set_source_rgba(a_fg, a_fg, a_fg, 0.3);
            ctx.arc(wx + ww - 9, wy + hbH / 2, 3, 0, 2 * PI);
            ctx.fill();
            ctx.set_source_rgba(a_fg, a_fg, a_fg, 0.45);
            ctx.rectangle(wx + 8, wy + hbH / 2 - 2, ww * 0.38, 4);
            ctx.fill();
            ctx.set_source_rgba(a_fg, a_fg, a_fg, 0.5);
            ctx.rectangle(wx + 8, wy + hbH + 8, ww * 0.55, 4);
            ctx.fill();
            ctx.set_source_rgba(a_fg, a_fg, a_fg, 0.22);
            ctx.rectangle(wx + 8, wy + hbH + 16, ww * 0.8, 3.5);
            ctx.fill();
            ctx.rectangle(wx + 8, wy + hbH + 23, ww * 0.68, 3.5);
            ctx.fill();
            double bw = 30.0, bh = 11.0;
            round_rect(ctx, wx + ww - bw - 8, wy + wh - bh - 7, bw, bh, 4);
            ctx.set_source_rgba(ac.red, ac.green, ac.blue, 0.9);
            ctx.fill();
            round_rect(ctx, wx, wy, ww, wh, rr);
            ctx.set_source_rgba(a_fg, a_fg, a_fg, app_dark ? 0.3 : 0.14);
            ctx.set_line_width(0.8);
            ctx.stroke();
        }
    }
}
