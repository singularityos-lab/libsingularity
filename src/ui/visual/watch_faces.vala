namespace Singularity {

    public class WatchPaint {
        public const string FAMILY = "Inter, Noto Sans, sans-serif";

        public static Gdk.RGBA rgba(string spec) {
            var c = Gdk.RGBA();
            if (!c.parse(spec)) c.parse("white");
            return c;
        }

        public static void color(Cairo.Context cr, Gdk.RGBA c, double alpha = 1.0) {
            cr.set_source_rgba(c.red, c.green, c.blue, c.alpha * alpha);
        }

        public static Gdk.RGBA mix(Gdk.RGBA a, Gdk.RGBA b, double t) {
            var c = Gdk.RGBA();
            c.red = (float) (a.red + (b.red - a.red) * t);
            c.green = (float) (a.green + (b.green - a.green) * t);
            c.blue = (float) (a.blue + (b.blue - a.blue) * t);
            c.alpha = (float) (a.alpha + (b.alpha - a.alpha) * t);
            return c;
        }

        public static double luminance(Gdk.RGBA c) {
            return 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue;
        }

        public static void polar(double cx, double cy, double r, double angle, out double x, out double y) {
            x = cx + r * Math.sin(angle);
            y = cy - r * Math.cos(angle);
        }

        public static double rad(double degrees) {
            return degrees * Math.PI / 180.0;
        }

        public static double hour_angle(WatchFaceFrame f, bool smooth_seconds = false) {
            var t = f.time;
            return rad(((t.get_hour() % 12) + t.get_minute() / 60.0 + Math.floor(f.seconds) / 3600.0) * 30.0);
        }

        public static double minute_angle(WatchFaceFrame f) {
            return rad((f.time.get_minute() + Math.floor(f.seconds) / 60.0) * 6.0);
        }

        public static double second_angle(WatchFaceFrame f, bool sweep) {
            return rad((sweep ? f.seconds : Math.floor(f.seconds)) * 6.0);
        }

        public static Pango.Layout layout(Cairo.Context cr, string text, double px, int weight, double tracking = 0.0, bool tabular = true) {
            var layout = Pango.cairo_create_layout(cr);
            var desc = new Pango.FontDescription();
            desc.set_family(FAMILY);
            desc.set_absolute_size(px * Pango.SCALE);
            desc.set_weight((Pango.Weight) weight);
            layout.set_font_description(desc);
            var attrs = new Pango.AttrList();
            if (tabular) attrs.insert(Pango.AttrFontFeatures.@new("tnum=1"));
            if (tracking != 0.0) attrs.insert(Pango.attr_letter_spacing_new((int) (tracking * Pango.SCALE)));
            layout.set_attributes(attrs);
            layout.set_text(text, -1);
            return layout;
        }

        public static void text(Cairo.Context cr, string text, double x, double y, double px, int weight,
                                double xalign = 0.5, double yalign = 0.5, double tracking = 0.0) {
            var l = layout(cr, text, px, weight, tracking);
            Pango.Rectangle ink, logical;
            l.get_pixel_extents(out ink, out logical);
            cr.move_to(x - ink.x - ink.width * xalign, y - ink.y - ink.height * yalign);
            Pango.cairo_show_layout(cr, l);
        }

        public static void text_shadowed(Cairo.Context cr, string text, double x, double y, double px, int weight,
                                         Gdk.RGBA ink, double xalign = 0.5, double yalign = 0.5, double tracking = 0.0) {
            for (int i = 1; i <= 2; i++) {
                cr.set_source_rgba(0, 0, 0, 0.14);
                WatchPaint.text(cr, text, x, y + i * px * 0.008, px, weight, xalign, yalign, tracking);
            }
            color(cr, ink);
            WatchPaint.text(cr, text, x, y, px, weight, xalign, yalign, tracking);
        }

        public static void tick(Cairo.Context cr, double cx, double cy, double outer, double inner, double angle, double width) {
            double x1, y1, x2, y2;
            polar(cx, cy, outer, angle, out x1, out y1);
            polar(cx, cy, inner, angle, out x2, out y2);
            cr.set_line_width(width);
            cr.set_line_cap(Cairo.LineCap.BUTT);
            cr.move_to(x1, y1);
            cr.line_to(x2, y2);
            cr.stroke();
        }

        public static void dot(Cairo.Context cr, double x, double y, double r) {
            cr.new_sub_path();
            cr.arc(x, y, r, 0, 2 * Math.PI);
            cr.fill();
        }

        public static void rounded_rect(Cairo.Context cr, double x, double y, double w, double h, double r) {
            r = double.min(r, double.min(w, h) / 2.0);
            cr.new_sub_path();
            cr.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
            cr.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
            cr.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
            cr.arc(x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
            cr.close_path();
        }

        public static void begin_hand(Cairo.Context cr, double cx, double cy, double angle) {
            cr.save();
            cr.translate(cx, cy);
            cr.rotate(angle);
        }

        public static void paint_background(Cairo.Context cr, WatchFaceFrame f, Gdk.RGBA c) {
            color(cr, c);
            cr.rectangle(0, 0, f.width, f.height);
            cr.fill();
        }

        public static void vignette(Cairo.Context cr, WatchFaceFrame f, double light, double dark) {
            double cx = f.width / 2.0, cy = f.height / 2.0, r = f.size / 2.0;
            var g = new Cairo.Pattern.radial(cx, cy - r * 0.25, 0, cx, cy, r * 1.25);
            g.add_color_stop_rgba(0, 1, 1, 1, light);
            g.add_color_stop_rgba(0.55, 1, 1, 1, 0);
            g.add_color_stop_rgba(1, 0, 0, 0, dark);
            cr.set_source(g);
            cr.rectangle(0, 0, f.width, f.height);
            cr.fill();
        }

        public static string date_label(DateTime t, string format) {
            return t.format(format).up().strip();
        }
    }

    namespace WatchFaces {

        public void register_builtin(WatchFaceRegistry registry) {
            registry.add(new Meridian());
            registry.add(new Portrait());
            registry.add(new Chronograph());
            registry.add(new EventHorizon());
            registry.add(new Stack());
            registry.add(new Rings());
            registry.add(new Words());
            registry.add(new Aurora());
            registry.add(new Bauhaus());
            registry.add(new Pilot());
        }

        private const string ID = "dev.sinty.watch.";

        public class Meridian : WatchFaceProvider {
            public override string id { get { return ID + "meridian"; } }
            public override string name { get { return _("Meridian"); } }

            public override WatchFaceOption[] get_options() {
                return {
                    WatchFaceOption.colors("dial", _("Dial"), { "#10141c", "#efe9dc", "#3a4048", "#13352b" },
                        { _("Midnight"), _("Ivory"), _("Slate"), _("Forest") }, "#10141c"),
                    WatchFaceOption.colors("accent", _("Seconds"), { "#ff6a2b", "#e23b3b", "#d8b26e", "#4aa3ff" },
                        { _("Orange"), _("Red"), _("Gold"), _("Blue") }, "#ff6a2b"),
                    WatchFaceOption.toggle("seconds", _("Seconds Hand"), true),
                    WatchFaceOption.toggle("date", _("Date"), true)
                };
            }

            public override WatchFaceRefresh get_refresh(WatchFaceFrame f) {
                return f.get_flag("seconds", true) ? WatchFaceRefresh.SECOND : WatchFaceRefresh.MINUTE;
            }

            private static void dauphine(Cairo.Context cr, double length, double tail, double width, Gdk.RGBA light, Gdk.RGBA dark) {
                double shoulder = -length * 0.12;
                cr.move_to(0, tail);
                cr.line_to(-width / 2, shoulder);
                cr.line_to(0, -length);
                cr.close_path();
                WatchPaint.color(cr, light);
                cr.fill();
                cr.move_to(0, tail);
                cr.line_to(width / 2, shoulder);
                cr.line_to(0, -length);
                cr.close_path();
                WatchPaint.color(cr, dark);
                cr.fill();
            }

            public override void draw(Cairo.Context cr, WatchFaceFrame f) {
                double s = f.size, cx = f.width / 2.0, cy = f.height / 2.0, r = s / 2.0;
                var dial = f.get_color("dial", "#10141c");
                var accent = f.get_color("accent", "#ff6a2b");
                bool light_dial = WatchPaint.luminance(dial) > 0.5;
                var ink = WatchPaint.rgba(light_dial ? "#1b1d22" : "#f3f1ec");
                WatchPaint.paint_background(cr, f, dial);
                WatchPaint.vignette(cr, f, light_dial ? 0.10 : 0.07, light_dial ? 0.18 : 0.45);

                WatchPaint.color(cr, ink, 0.5);
                for (int i = 0; i < 60; i++) {
                    if (i % 5 == 0) continue;
                    WatchPaint.tick(cr, cx, cy, r * 0.93, r * 0.88, WatchPaint.rad(i * 6), s * 0.004);
                }
                for (int i = 0; i < 12; i++) {
                    double a = WatchPaint.rad(i * 30);
                    WatchPaint.begin_hand(cr, cx, cy, a);
                    double bw = s * 0.022;
                    double[] offsets = i == 0 ? new double[] { -bw * 0.75, bw * 0.75 } : new double[] { 0 };
                    foreach (double off in offsets) {
                        var g = new Cairo.Pattern.linear(off - bw / 2, 0, off + bw / 2, 0);
                        g.add_color_stop_rgba(0, ink.red, ink.green, ink.blue, 1.0);
                        g.add_color_stop_rgba(0.5, ink.red, ink.green, ink.blue, 0.82);
                        g.add_color_stop_rgba(1, ink.red, ink.green, ink.blue, 0.6);
                        cr.set_source(g);
                        WatchPaint.rounded_rect(cr, off - bw / 2, -r * 0.87, bw * (i == 0 ? 0.8 : 1.0), r * 0.17, bw * 0.2);
                        cr.fill();
                    }
                    cr.restore();
                }

                WatchPaint.color(cr, ink, 0.72);
                WatchPaint.text(cr, "SINGULARITY", cx, cy - r * 0.42, s * 0.03, 600, 0.5, 0.5, s * 0.008);
                WatchPaint.color(cr, ink, 0.42);
                WatchPaint.text(cr, "AUTOMATIC", cx, cy + r * 0.42, s * 0.022, 500, 0.5, 0.5, s * 0.006);

                if (f.get_flag("date", true)) {
                    double ww = s * 0.11, wh = s * 0.075, wx = cx + r * 0.55 - ww / 2, wy = cy - wh / 2;
                    WatchPaint.color(cr, ink, 0.35);
                    WatchPaint.rounded_rect(cr, wx - 1.5, wy - 1.5, ww + 3, wh + 3, s * 0.008);
                    cr.fill();
                    cr.set_source_rgb(light_dial ? 1.0 : 0.97, light_dial ? 1.0 : 0.96, light_dial ? 1.0 : 0.94);
                    WatchPaint.rounded_rect(cr, wx, wy, ww, wh, s * 0.006);
                    cr.fill();
                    cr.set_source_rgb(0.1, 0.1, 0.12);
                    WatchPaint.text(cr, f.time.get_day_of_month().to_string(), cx + r * 0.55, cy, s * 0.045, 600);
                }

                var light = ink;
                var dark = WatchPaint.mix(ink, dial, 0.38);
                double ha = WatchPaint.hour_angle(f), ma = WatchPaint.minute_angle(f);
                for (int pass = 0; pass < 2; pass++) {
                    double dx = pass == 0 ? s * 0.006 : 0, dy = pass == 0 ? s * 0.014 : 0;
                    var sl = pass == 0 ? WatchPaint.rgba("rgba(0,0,0,0.28)") : light;
                    var sd = pass == 0 ? WatchPaint.rgba("rgba(0,0,0,0.28)") : dark;
                    WatchPaint.begin_hand(cr, cx + dx, cy + dy, ha);
                    dauphine(cr, r * 0.54, r * 0.08, s * 0.05, sl, sd);
                    cr.restore();
                    WatchPaint.begin_hand(cr, cx + dx, cy + dy, ma);
                    dauphine(cr, r * 0.84, r * 0.09, s * 0.04, sl, sd);
                    cr.restore();
                }
                WatchPaint.color(cr, ink);
                WatchPaint.dot(cr, cx, cy, s * 0.022);
                if (f.get_flag("seconds", true)) {
                    double sa = WatchPaint.second_angle(f, false);
                    WatchPaint.begin_hand(cr, cx + s * 0.004, cy + s * 0.01, sa);
                    cr.set_source_rgba(0, 0, 0, 0.25);
                    cr.rectangle(-s * 0.003, -r * 0.9, s * 0.006, r * 1.12);
                    cr.fill();
                    cr.restore();
                    WatchPaint.begin_hand(cr, cx, cy, sa);
                    WatchPaint.color(cr, accent);
                    cr.rectangle(-s * 0.003, -r * 0.9, s * 0.006, r * 1.12);
                    cr.fill();
                    WatchPaint.dot(cr, 0, r * 0.2, s * 0.018);
                    cr.restore();
                }
                WatchPaint.color(cr, accent);
                WatchPaint.dot(cr, cx, cy, s * 0.011);
            }
        }

        public class Portrait : WatchFaceProvider {
            public override string id { get { return ID + "portrait"; } }
            public override string name { get { return _("Portrait"); } }

            public override WatchFaceOption[] get_options() {
                return {
                    WatchFaceOption.choice("position", _("Time"), { "bottom", "top", "center" }, { _("Bottom"), _("Top"), _("Center") }, "bottom"),
                    WatchFaceOption.choice("weight", _("Style"), { "light", "bold" }, { _("Light"), _("Bold") }, "light"),
                    WatchFaceOption.toggle("date", _("Date"), true),
                    WatchFaceOption.toggle("dim", _("Dim Photo"), true)
                };
            }

            public override void draw(Cairo.Context cr, WatchFaceFrame f) {
                double s = f.size, cx = f.width / 2.0;
                string position = f.get_value("position", "bottom");
                if (f.wallpaper != null) {
                    cr.set_source_surface(f.wallpaper, 0, 0);
                    cr.paint();
                } else {
                    var g = new Cairo.Pattern.linear(0, 0, f.width, f.height);
                    g.add_color_stop_rgb(0, 0.12, 0.16, 0.28);
                    g.add_color_stop_rgb(1, 0.36, 0.20, 0.30);
                    cr.set_source(g);
                    cr.paint();
                }
                double time_y = position == "top" ? f.height * 0.36 : position == "center" ? f.height * 0.52 : f.height * 0.74;
                if (f.get_flag("dim", true)) {
                    Cairo.Pattern scrim;
                    if (position == "center") {
                        scrim = new Cairo.Pattern.radial(cx, time_y, 0, cx, time_y, s * 0.6);
                        scrim.add_color_stop_rgba(0, 0, 0, 0, 0.42);
                        scrim.add_color_stop_rgba(1, 0, 0, 0, 0.1);
                    } else {
                        bool top = position == "top";
                        scrim = new Cairo.Pattern.linear(0, top ? 0 : f.height, 0, top ? f.height : 0);
                        scrim.add_color_stop_rgba(0, 0, 0, 0, 0.6);
                        scrim.add_color_stop_rgba(0.55, 0, 0, 0, 0.12);
                        scrim.add_color_stop_rgba(1, 0, 0, 0, 0.0);
                    }
                    cr.set_source(scrim);
                    cr.paint();
                }
                bool bold = f.get_value("weight", "light") == "bold";
                var white = WatchPaint.rgba("white");
                double px = s * (bold ? 0.27 : 0.3);
                WatchPaint.text_shadowed(cr, f.time.format("%H:%M"), cx, time_y, px, bold ? 800 : 300, white, 0.5, 0.5, bold ? -s * 0.006 : 0);
                if (f.get_flag("date", true)) {
                    var date_white = WatchPaint.rgba("rgba(255,255,255,0.92)");
                    WatchPaint.text_shadowed(cr, WatchPaint.date_label(f.time, "%A %e"), cx, time_y - px * 0.5 - s * 0.06,
                        s * 0.04, 600, date_white, 0.5, 0.5, s * 0.008);
                }
            }
        }

        public class Chronograph : WatchFaceProvider {
            public override string id { get { return ID + "chronograph"; } }
            public override string name { get { return _("Chronograph"); } }

            public override WatchFaceOption[] get_options() {
                return {
                    WatchFaceOption.choice("dial", _("Dial"), { "panda", "reverse", "blue" }, { _("Panda"), _("Reverse"), _("Blue") }, "panda"),
                    WatchFaceOption.toggle("tachymeter", _("Tachymeter"), true)
                };
            }

            public override WatchFaceRefresh get_refresh(WatchFaceFrame f) {
                return WatchFaceRefresh.SECOND;
            }

            private void subdial(Cairo.Context cr, double x, double y, double r, Gdk.RGBA fill, Gdk.RGBA ink, string[] labels, double hand, Gdk.RGBA hand_color) {
                WatchPaint.color(cr, ink, 0.25);
                WatchPaint.dot(cr, x, y, r + 1.5);
                WatchPaint.color(cr, fill);
                WatchPaint.dot(cr, x, y, r);
                cr.set_line_width(0.6);
                for (int i = 1; i < 9; i++) {
                    WatchPaint.color(cr, ink, 0.07);
                    cr.new_sub_path();
                    cr.arc(x, y, r * i / 9.0, 0, 2 * Math.PI);
                    cr.stroke();
                }
                WatchPaint.color(cr, ink, 0.8);
                for (int i = 0; i < 12; i++) WatchPaint.tick(cr, x, y, r * 0.96, r * (i % 3 == 0 ? 0.76 : 0.84), WatchPaint.rad(i * 30), r * 0.03);
                for (int i = 0; i < labels.length; i++) {
                    double lx, ly;
                    WatchPaint.polar(x, y, r * 0.55, WatchPaint.rad(i * 360.0 / labels.length), out lx, out ly);
                    WatchPaint.text(cr, labels[i], lx, ly, r * 0.22, 600);
                }
                WatchPaint.begin_hand(cr, x, y, hand);
                WatchPaint.color(cr, hand_color);
                cr.move_to(-r * 0.035, r * 0.12);
                cr.line_to(0, -r * 0.88);
                cr.line_to(r * 0.035, r * 0.12);
                cr.close_path();
                cr.fill();
                cr.restore();
                WatchPaint.color(cr, hand_color);
                WatchPaint.dot(cr, x, y, r * 0.07);
            }

            public override void draw(Cairo.Context cr, WatchFaceFrame f) {
                double s = f.size, cx = f.width / 2.0, cy = f.height / 2.0, r = s / 2.0;
                string style = f.get_value("dial", "panda");
                Gdk.RGBA dial, sub, ink, sub_ink;
                if (style == "reverse") {
                    dial = WatchPaint.rgba("#141416"); sub = WatchPaint.rgba("#ece7db"); ink = WatchPaint.rgba("#f2f0ea"); sub_ink = WatchPaint.rgba("#17171a");
                } else if (style == "blue") {
                    dial = WatchPaint.rgba("#173a6b"); sub = WatchPaint.rgba("#c9ced6"); ink = WatchPaint.rgba("#f2f4f8"); sub_ink = WatchPaint.rgba("#14243d");
                } else {
                    dial = WatchPaint.rgba("#eeebe4"); sub = WatchPaint.rgba("#17171a"); ink = WatchPaint.rgba("#17171a"); sub_ink = WatchPaint.rgba("#f2f0ea");
                }
                WatchPaint.paint_background(cr, f, dial);
                for (int i = 0; i < 180; i++) {
                    double a = WatchPaint.rad(i * 2);
                    cr.move_to(cx, cy);
                    cr.arc(cx, cy, r * 1.5, a - Math.PI / 2, a - Math.PI / 2 + WatchPaint.rad(2));
                    cr.close_path();
                    cr.set_source_rgba(1, 1, 1, i % 2 == 0 ? 0.035 : 0.0);
                    cr.fill();
                }
                WatchPaint.vignette(cr, f, 0.08, 0.35);

                bool tachy = f.get_flag("tachymeter", true);
                cr.set_source_rgb(0.06, 0.06, 0.07);
                cr.new_sub_path();
                cr.arc(cx, cy, r * 1.5, 0, 2 * Math.PI);
                cr.new_sub_path();
                cr.arc_negative(cx, cy, r * 0.85, 2 * Math.PI, 0);
                cr.fill();
                cr.set_source_rgba(1, 1, 1, 0.9);
                if (tachy) {
                    int[] values = { 500, 400, 300, 250, 200, 180, 160, 140, 120, 110, 100, 90, 80, 70 };
                    foreach (int v in values) {
                        double a = WatchPaint.rad(3600.0 / v * 6.0);
                        WatchPaint.tick(cr, cx, cy, r * 0.995, r * 0.965, a, s * 0.004);
                        double tx, ty;
                        WatchPaint.polar(cx, cy, r * 0.918, a, out tx, out ty);
                        WatchPaint.text(cr, v.to_string(), tx, ty, s * 0.03, 600);
                    }
                    WatchPaint.text(cr, "TACHYMETER", cx, cy - r * 0.918, s * 0.026, 700, 0.5, 0.5, s * 0.004);
                } else {
                    for (int i = 1; i < 12; i++) {
                        double tx, ty;
                        WatchPaint.polar(cx, cy, r * 0.918, WatchPaint.rad(i * 30), out tx, out ty);
                        WatchPaint.text(cr, (i * 5).to_string(), tx, ty, s * 0.038, 600);
                    }
                    WatchPaint.text(cr, "60", cx, cy - r * 0.918, s * 0.038, 700);
                }

                for (int i = 0; i < 240; i++) {
                    WatchPaint.color(cr, ink, i % 4 == 0 ? 0.75 : 0.35);
                    WatchPaint.tick(cr, cx, cy, r * 0.84, r * (i % 4 == 0 ? 0.79 : 0.815), WatchPaint.rad(i * 1.5), s * (i % 4 == 0 ? 0.004 : 0.0022));
                }
                for (int i = 0; i < 12; i++) {
                    WatchPaint.begin_hand(cr, cx, cy, WatchPaint.rad(i * 30));
                    double bw = s * 0.018;
                    WatchPaint.color(cr, ink);
                    WatchPaint.rounded_rect(cr, -bw / 2, -r * 0.76, bw, r * 0.12, bw * 0.3);
                    cr.fill();
                    cr.restore();
                }

                double sr = r * 0.2;
                var red = WatchPaint.rgba("#e0312c");
                subdial(cr, cx - r * 0.42, cy, sr, sub, sub_ink, { "60", "20", "40" }, WatchPaint.second_angle(f, false), sub_ink);
                double h24 = WatchPaint.rad((f.time.get_hour() + f.time.get_minute() / 60.0) * 15.0);
                subdial(cr, cx + r * 0.42, cy, sr, sub, sub_ink, { "24", "6", "12", "18" }, h24, sub_ink);
                double level = f.battery < 0 ? 1.0 : f.battery.clamp(0, 100) / 100.0;
                subdial(cr, cx, cy + r * 0.42, sr, sub, sub_ink, { "100", "25", "50", "75" }, WatchPaint.rad(level * 360.0 - (level >= 1.0 ? 360.0 : 0.0)), red);

                WatchPaint.color(cr, ink, 0.85);
                WatchPaint.text(cr, "SINGULARITY", cx, cy - r * 0.42, s * 0.03, 700, 0.5, 0.5, s * 0.007);
                WatchPaint.color(cr, ink, 0.5);
                WatchPaint.text(cr, "CHRONOGRAPH", cx, cy - r * 0.34, s * 0.02, 600, 0.5, 0.5, s * 0.005);

                double ha = WatchPaint.hour_angle(f), ma = WatchPaint.minute_angle(f);
                var steel = WatchPaint.rgba(style == "panda" ? "#202124" : "#e9e9ec");
                var lume = WatchPaint.rgba("#f4f6ee");
                for (int pass = 0; pass < 2; pass++) {
                    double dx = pass == 0 ? s * 0.006 : 0, dy = pass == 0 ? s * 0.012 : 0;
                    double[] lengths = { r * 0.55, r * 0.8 };
                    double[] angles = { ha, ma };
                    double[] widths = { s * 0.032, s * 0.024 };
                    for (int k = 0; k < 2; k++) {
                        WatchPaint.begin_hand(cr, cx + dx, cy + dy, angles[k]);
                        if (pass == 0) cr.set_source_rgba(0, 0, 0, 0.3); else WatchPaint.color(cr, steel);
                        WatchPaint.rounded_rect(cr, -widths[k] / 2, -lengths[k], widths[k], lengths[k] + r * 0.1, widths[k] / 2);
                        cr.fill();
                        if (pass == 1) {
                            WatchPaint.color(cr, lume);
                            WatchPaint.rounded_rect(cr, -widths[k] * 0.26, -lengths[k] + widths[k] * 0.4, widths[k] * 0.52, lengths[k] * 0.62, widths[k] * 0.26);
                            cr.fill();
                        }
                        cr.restore();
                    }
                }
                WatchPaint.begin_hand(cr, cx, cy, 0);
                WatchPaint.color(cr, red);
                cr.rectangle(-s * 0.0025, -r * 0.84, s * 0.005, r * 1.04);
                cr.fill();
                cr.restore();
                WatchPaint.color(cr, steel);
                WatchPaint.dot(cr, cx, cy, s * 0.02);
                WatchPaint.color(cr, red);
                WatchPaint.dot(cr, cx, cy, s * 0.009);
            }
        }

        public class EventHorizon : WatchFaceProvider {
            public override string id { get { return ID + "event-horizon"; } }
            public override string name { get { return _("Event Horizon"); } }

            public override WatchFaceOption[] get_options() {
                return {
                    WatchFaceOption.choice("palette", _("Light"), { "ember", "ice", "violet" }, { _("Ember"), _("Ice"), _("Violet") }, "ember"),
                    WatchFaceOption.toggle("digital", _("Digital Time"), true)
                };
            }

            public override WatchFaceRefresh get_refresh(WatchFaceFrame f) {
                return WatchFaceRefresh.CONTINUOUS;
            }

            private static void palette(string name, out Gdk.RGBA hot, out Gdk.RGBA mid, out Gdk.RGBA cold) {
                if (name == "ice") {
                    hot = WatchPaint.rgba("#f4fbff"); mid = WatchPaint.rgba("#6fd0ff"); cold = WatchPaint.rgba("#1b3c8f");
                } else if (name == "violet") {
                    hot = WatchPaint.rgba("#fff0fb"); mid = WatchPaint.rgba("#ff5fd2"); cold = WatchPaint.rgba("#4b1a8f");
                } else {
                    hot = WatchPaint.rgba("#fff6e0"); mid = WatchPaint.rgba("#ffaa3b"); cold = WatchPaint.rgba("#8f2410");
                }
            }

            private void disk(Cairo.Context cr, double cx, double cy, double r, bool front, Gdk.RGBA hot, Gdk.RGBA mid, Gdk.RGBA cold, double t) {
                int rings = 26;
                cr.save();
                cr.rectangle(cx - r * 2, front ? cy : cy - r * 2, r * 4, r * 2);
                cr.clip();
                for (int i = 0; i < rings; i++) {
                    double k = i / (double) (rings - 1);
                    double rr = r * (0.36 + k * 0.5);
                    var c = k < 0.3 ? WatchPaint.mix(hot, mid, k / 0.3) : WatchPaint.mix(mid, cold, (k - 0.3) / 0.7);
                    double alpha = (1.0 - k) * 0.85 + 0.05;
                    cr.save();
                    cr.translate(cx, cy);
                    cr.scale(1.0, 0.24);
                    cr.set_line_width(r * 0.05);
                    var g = new Cairo.Pattern.linear(-rr, 0, rr, 0);
                    g.add_color_stop_rgba(0, c.red, c.green, c.blue, alpha * 0.5);
                    g.add_color_stop_rgba(1, c.red, c.green, c.blue, alpha * 0.2);
                    cr.set_source(g);
                    cr.new_sub_path();
                    cr.arc(0, 0, rr, 0, 2 * Math.PI);
                    cr.stroke();
                    cr.set_line_width(r * 0.014);
                    double[] dash = { rr * 0.7, rr * 0.35 };
                    cr.set_dash(dash, -t * (12.0 / (0.4 + k)) * r * 0.01 + i * rr * 0.37);
                    var streak = new Cairo.Pattern.linear(-rr, 0, rr, 0);
                    var bright = WatchPaint.mix(c, hot, 0.5);
                    streak.add_color_stop_rgba(0, bright.red, bright.green, bright.blue, alpha * 0.55);
                    streak.add_color_stop_rgba(1, bright.red, bright.green, bright.blue, alpha * 0.2);
                    cr.set_source(streak);
                    cr.new_sub_path();
                    cr.arc(0, 0, rr, 0, 2 * Math.PI);
                    cr.stroke();
                    cr.restore();
                }
                cr.restore();
            }

            public override void draw(Cairo.Context cr, WatchFaceFrame f) {
                double s = f.size, cx = f.width / 2.0, cy = f.height / 2.0, r = s / 2.0;
                double t = f.elapsed;
                Gdk.RGBA hot, mid, cold;
                palette(f.get_value("palette", "ember"), out hot, out mid, out cold);
                cr.set_source_rgb(0.012, 0.012, 0.024);
                cr.paint();
                uint seed = 7;
                for (int i = 0; i < 140; i++) {
                    seed = seed * 1103515245 + 12345;
                    double x = (seed >> 8) % 10000 / 10000.0 * f.width;
                    seed = seed * 1103515245 + 12345;
                    double y = (seed >> 8) % 10000 / 10000.0 * f.height;
                    seed = seed * 1103515245 + 12345;
                    double phase = (seed >> 8) % 1000 / 1000.0;
                    double tw = 0.35 + 0.65 * (0.5 + 0.5 * Math.sin(t * (0.6 + phase) + phase * 6.28));
                    cr.set_source_rgba(1, 1, 1, 0.55 * tw);
                    WatchPaint.dot(cr, x, y, 0.5 + phase * 0.8);
                }
                double bh = r * 0.26;
                double by = cy - r * 0.04;
                disk(cr, cx, by, r, false, hot, mid, cold, t);
                var glow = new Cairo.Pattern.radial(cx, by, bh * 0.9, cx, by, bh * 1.9);
                glow.add_color_stop_rgba(0, mid.red, mid.green, mid.blue, 0.75);
                glow.add_color_stop_rgba(0.35, mid.red, mid.green, mid.blue, 0.22);
                glow.add_color_stop_rgba(1, cold.red, cold.green, cold.blue, 0.0);
                cr.set_source(glow);
                WatchPaint.dot(cr, cx, by, bh * 1.9);
                cr.save();
                cr.translate(cx, by);
                cr.scale(1.0, 0.92);
                cr.set_line_width(bh * 0.22);
                var lens = new Cairo.Pattern.radial(0, 0, bh * 1.1, 0, 0, bh * 1.5);
                lens.add_color_stop_rgba(0, hot.red, hot.green, hot.blue, 0.75);
                lens.add_color_stop_rgba(0.5, mid.red, mid.green, mid.blue, 0.45);
                lens.add_color_stop_rgba(1, cold.red, cold.green, cold.blue, 0.0);
                cr.set_source(lens);
                cr.new_sub_path();
                cr.arc(0, 0, bh * 1.25, Math.PI * 1.02, Math.PI * 1.98);
                cr.stroke();
                cr.restore();
                cr.set_source_rgb(0, 0, 0);
                WatchPaint.dot(cr, cx, by, bh);
                WatchPaint.color(cr, hot, 0.95);
                cr.set_line_width(s * 0.004);
                cr.new_sub_path();
                cr.arc(cx, by, bh * 1.03, 0, 2 * Math.PI);
                cr.stroke();
                disk(cr, cx, by, r, true, hot, mid, cold, t);
                cr.set_source_rgb(0, 0, 0);
                cr.save();
                cr.rectangle(cx - bh, by - bh, bh * 2, bh);
                cr.clip();
                WatchPaint.dot(cr, cx, by, bh * 0.985);
                cr.restore();

                int minute = f.time.get_minute();
                for (int i = 0; i < 60; i++) {
                    double x, y;
                    WatchPaint.polar(cx, cy, r * 0.92, WatchPaint.rad(i * 6), out x, out y);
                    bool lit = i <= minute;
                    if (lit) WatchPaint.color(cr, WatchPaint.mix(hot, mid, i / 60.0), 0.9); else cr.set_source_rgba(1, 1, 1, 0.12);
                    WatchPaint.dot(cr, x, y, i % 5 == 0 ? s * 0.0065 : s * 0.0042);
                }
                double hx, hy;
                WatchPaint.polar(cx, cy, r * 0.92, WatchPaint.hour_angle(f), out hx, out hy);
                var halo = new Cairo.Pattern.radial(hx, hy, 0, hx, hy, s * 0.045);
                halo.add_color_stop_rgba(0, hot.red, hot.green, hot.blue, 0.9);
                halo.add_color_stop_rgba(1, mid.red, mid.green, mid.blue, 0.0);
                cr.set_source(halo);
                WatchPaint.dot(cr, hx, hy, s * 0.045);
                WatchPaint.color(cr, hot);
                WatchPaint.dot(cr, hx, hy, s * 0.013);

                if (f.get_flag("digital", true)) {
                    cr.set_source_rgba(1, 1, 1, 0.94);
                    WatchPaint.text(cr, f.time.format("%H:%M"), cx, cy + r * 0.58, s * 0.11, 250, 0.5, 0.5, s * 0.01);
                    WatchPaint.color(cr, mid, 0.85);
                    WatchPaint.text(cr, WatchPaint.date_label(f.time, "%a %e"), cx, cy - r * 0.6, s * 0.032, 600, 0.5, 0.5, s * 0.01);
                }
            }
        }

        public class Stack : WatchFaceProvider {
            public override string id { get { return ID + "stack"; } }
            public override string name { get { return _("Stack"); } }

            public override WatchFaceOption[] get_options() {
                return {
                    WatchFaceOption.colors("accent", _("Minutes"), { "#ff7a2f", "#c6ff3d", "#ffb3c7", "#8a8f98" },
                        { _("Orange"), _("Lime"), _("Rose"), _("Graphite") }, "#ff7a2f"),
                    WatchFaceOption.toggle("seconds", _("Seconds Ring"), true)
                };
            }

            public override WatchFaceRefresh get_refresh(WatchFaceFrame f) {
                return f.get_flag("seconds", true) ? WatchFaceRefresh.SECOND : WatchFaceRefresh.MINUTE;
            }

            public override void draw(Cairo.Context cr, WatchFaceFrame f) {
                double s = f.size, cx = f.width / 2.0, cy = f.height / 2.0, r = s / 2.0;
                var accent = f.get_color("accent", "#ff7a2f");
                cr.set_source_rgb(0, 0, 0);
                cr.paint();
                double px = s * 0.38;
                double left = cx - s * 0.05;
                cr.set_source_rgb(1, 1, 1);
                WatchPaint.text(cr, f.time.format("%H"), left, cy - s * 0.02, px, 800, 0.5, 1.0, -s * 0.012);
                WatchPaint.color(cr, accent);
                WatchPaint.text(cr, f.time.format("%M"), left, cy + s * 0.02, px, 800, 0.5, 0.0, -s * 0.012);
                cr.save();
                cr.translate(cx + s * 0.33, cy);
                cr.rotate(Math.PI / 2);
                cr.set_source_rgba(1, 1, 1, 0.85);
                WatchPaint.text(cr, WatchPaint.date_label(f.time, "%a %e %b"), 0, 0, s * 0.042, 700, 0.5, 0.5, s * 0.01);
                cr.restore();
                if (f.battery >= 0) {
                    cr.save();
                    cr.translate(cx + s * 0.40, cy);
                    cr.rotate(Math.PI / 2);
                    WatchPaint.color(cr, accent, 0.9);
                    WatchPaint.text(cr, "%d%%".printf((int) f.battery), 0, 0, s * 0.03, 600, 0.5, 0.5, s * 0.008);
                    cr.restore();
                }
                if (f.get_flag("seconds", true)) {
                    double sec = Math.floor(f.seconds);
                    cr.set_line_cap(Cairo.LineCap.ROUND);
                    for (int i = 0; i < 60; i++) {
                        if (i <= sec) WatchPaint.color(cr, accent); else cr.set_source_rgba(1, 1, 1, 0.14);
                        WatchPaint.tick(cr, cx, cy, r * 0.97, r * 0.93, WatchPaint.rad(i * 6), s * 0.007);
                    }
                }
            }
        }

        public class Rings : WatchFaceProvider {
            public override string id { get { return ID + "rings"; } }
            public override string name { get { return _("Rings"); } }

            public override WatchFaceOption[] get_options() {
                return {
                    WatchFaceOption.choice("palette", _("Colors"), { "activity", "ocean", "sunset", "mono" },
                        { _("Activity"), _("Ocean"), _("Sunset"), _("Mono") }, "activity"),
                    WatchFaceOption.toggle("seconds", _("Seconds Ring"), true)
                };
            }

            public override WatchFaceRefresh get_refresh(WatchFaceFrame f) {
                return f.get_flag("seconds", true) ? WatchFaceRefresh.CONTINUOUS : WatchFaceRefresh.MINUTE;
            }

            private static string[] colors(string palette) {
                switch (palette) {
                    case "ocean": return { "#2f6bff", "#00b8ff", "#7ff0ff" };
                    case "sunset": return { "#ff4d3a", "#ff9f0a", "#ffd60a" };
                    case "mono": return { "#ffffff", "#b8bcc4", "#70757e" };
                }
                return { "#fa114f", "#92e82a", "#1eeaef" };
            }

            private static void ring(Cairo.Context cr, double cx, double cy, double radius, double width, double fraction, Gdk.RGBA c) {
                cr.set_line_width(width);
                cr.set_line_cap(Cairo.LineCap.ROUND);
                WatchPaint.color(cr, c, 0.2);
                cr.new_sub_path();
                cr.arc(cx, cy, radius, 0, 2 * Math.PI);
                cr.stroke();
                if (fraction <= 0.001) {
                    WatchPaint.color(cr, c);
                    WatchPaint.dot(cr, cx, cy - radius, width / 2);
                    return;
                }
                double start = -Math.PI / 2;
                double end = start + fraction * 2 * Math.PI;
                var g = new Cairo.Pattern.linear(cx - radius, cy - radius, cx + radius, cy + radius);
                var deep = WatchPaint.mix(c, WatchPaint.rgba("black"), 0.25);
                g.add_color_stop_rgba(0, deep.red, deep.green, deep.blue, 1);
                g.add_color_stop_rgba(1, c.red, c.green, c.blue, 1);
                cr.set_source(g);
                cr.new_sub_path();
                cr.arc(cx, cy, radius, start, end);
                cr.stroke();
                double ex = cx + radius * Math.cos(end), ey = cy + radius * Math.sin(end);
                cr.save();
                cr.translate(ex, ey);
                cr.rotate(end + Math.PI / 2);
                cr.set_source_rgba(0, 0, 0, 0.35);
                cr.new_sub_path();
                cr.arc(width * 0.12, 0, width / 2, -Math.PI / 2, Math.PI / 2);
                cr.fill();
                cr.restore();
                WatchPaint.color(cr, c);
                WatchPaint.dot(cr, ex, ey, width / 2);
            }

            public override void draw(Cairo.Context cr, WatchFaceFrame f) {
                double s = f.size, cx = f.width / 2.0, cy = f.height / 2.0, r = s / 2.0;
                cr.set_source_rgb(0, 0, 0);
                cr.paint();
                var palette = colors(f.get_value("palette", "activity"));
                bool seconds = f.get_flag("seconds", true);
                var t = f.time;
                double hours = ((t.get_hour() % 12) + t.get_minute() / 60.0) / 12.0;
                double minutes = (t.get_minute() + f.seconds / 60.0) / 60.0;
                double w = s * (seconds ? 0.075 : 0.095);
                double gap = w * 1.18;
                double outer = r * (seconds ? 0.86 : 0.8);
                ring(cr, cx, cy, outer, w, hours, WatchPaint.rgba(palette[0]));
                ring(cr, cx, cy, outer - gap, w, minutes, WatchPaint.rgba(palette[1]));
                if (seconds) ring(cr, cx, cy, outer - gap * 2, w, f.seconds / 60.0, WatchPaint.rgba(palette[2]));
                cr.set_source_rgb(1, 1, 1);
                WatchPaint.text(cr, t.format("%H:%M"), cx, cy - s * 0.01, s * (seconds ? 0.1 : 0.13), 700, 0.5, 0.5, -s * 0.002);
                cr.set_source_rgba(1, 1, 1, 0.6);
                WatchPaint.text(cr, WatchPaint.date_label(t, "%a %e"), cx, cy + s * (seconds ? 0.075 : 0.1), s * 0.03, 600, 0.5, 0.5, s * 0.006);
            }
        }

        public class Words : WatchFaceProvider {
            private const string[] GRID = {
                "ITLISASAMPM", "ACQUARTERDC", "TWENTYFIVEX", "HALFSTENFTO", "PASTERUNINE",
                "ONESIXTHREE", "FOURFIVETWO", "EIGHTELEVEN", "SEVENTWELVE", "TENSEOCLOCK"
            };

            public override string id { get { return ID + "words"; } }
            public override string name { get { return _("Words"); } }

            public override WatchFaceOption[] get_options() {
                return {
                    WatchFaceOption.colors("color", _("Color"), { "#ffffff", "#ffb23f", "#7cf2c8", "#ff8fb1" },
                        { _("White"), _("Amber"), _("Mint"), _("Pink") }, "#ffffff")
                };
            }

            private static void light(bool[,] lit, int row, int col, int len) {
                for (int i = 0; i < len; i++) lit[row, col + i] = true;
            }

            private static void hour_word(bool[,] lit, int h) {
                switch (h) {
                    case 1: light(lit, 5, 0, 3); break;
                    case 2: light(lit, 6, 8, 3); break;
                    case 3: light(lit, 5, 6, 5); break;
                    case 4: light(lit, 6, 0, 4); break;
                    case 5: light(lit, 6, 4, 4); break;
                    case 6: light(lit, 5, 3, 3); break;
                    case 7: light(lit, 8, 0, 5); break;
                    case 8: light(lit, 7, 0, 5); break;
                    case 9: light(lit, 4, 7, 4); break;
                    case 10: light(lit, 9, 0, 3); break;
                    case 11: light(lit, 7, 5, 6); break;
                    default: light(lit, 8, 5, 6); break;
                }
            }

            public override void draw(Cairo.Context cr, WatchFaceFrame f) {
                double s = f.size, cx = f.width / 2.0, cy = f.height / 2.0;
                var c = f.get_color("color", "#ffffff");
                cr.set_source_rgb(0.02, 0.02, 0.025);
                cr.paint();
                var lit = new bool[10, 11];
                int m = f.time.get_minute();
                int step = m / 5;
                int h = f.time.get_hour() % 12;
                light(lit, 0, 0, 2);
                light(lit, 0, 3, 2);
                switch (step) {
                    case 1: case 11: light(lit, 2, 6, 4); break;
                    case 2: case 10: light(lit, 3, 5, 3); break;
                    case 3: case 9: light(lit, 1, 0, 1); light(lit, 1, 2, 7); break;
                    case 4: case 8: light(lit, 2, 0, 6); break;
                    case 5: case 7: light(lit, 2, 0, 6); light(lit, 2, 6, 4); break;
                    case 6: light(lit, 3, 0, 4); break;
                }
                if (step == 0) light(lit, 9, 5, 6);
                else if (step <= 6) light(lit, 4, 0, 4);
                else {
                    light(lit, 3, 9, 2);
                    h = (h + 1) % 12;
                }
                hour_word(lit, h);
                double area = s * 0.78;
                double cw = area / 11.0, ch = area / 10.0;
                double x0 = cx - area / 2 + cw / 2, y0 = cy - area / 2 + ch / 2;
                for (int row = 0; row < 10; row++) {
                    for (int col = 0; col < 11; col++) {
                        string letter = GRID[row].substring(col, 1);
                        double x = x0 + col * cw, y = y0 + row * ch;
                        if (lit[row, col]) {
                            for (int g = 0; g < 4; g++) {
                                WatchPaint.color(cr, c, 0.12);
                                double ox = (g % 2 == 0 ? 1 : -1) * s * 0.003, oy = (g < 2 ? 1 : -1) * s * 0.003;
                                WatchPaint.text(cr, letter, x + ox, y + oy, s * 0.05, 700);
                            }
                            WatchPaint.color(cr, c);
                        } else {
                            cr.set_source_rgba(1, 1, 1, 0.11);
                        }
                        WatchPaint.text(cr, letter, x, y, s * 0.05, lit[row, col] ? 700 : 500);
                    }
                }
                int extra = m % 5;
                double[] dx = { -1, 1, 1, -1 };
                double[] dy = { -1, -1, 1, 1 };
                for (int i = 0; i < 4; i++) {
                    if (i < extra) WatchPaint.color(cr, c); else cr.set_source_rgba(1, 1, 1, 0.11);
                    WatchPaint.dot(cr, cx + dx[i] * (area / 2 + s * 0.045), cy + dy[i] * (area / 2 + s * 0.035), s * 0.009);
                }
            }
        }

        public class Aurora : WatchFaceProvider {
            public override string id { get { return ID + "aurora"; } }
            public override string name { get { return _("Aurora"); } }

            public override WatchFaceOption[] get_options() {
                return {
                    WatchFaceOption.choice("palette", _("Sky"), { "aurora", "sunset", "sea" }, { _("Aurora"), _("Sunset"), _("Sea") }, "aurora"),
                    WatchFaceOption.toggle("date", _("Date"), true)
                };
            }

            public override WatchFaceRefresh get_refresh(WatchFaceFrame f) {
                return WatchFaceRefresh.CONTINUOUS;
            }

            public override void draw(Cairo.Context cr, WatchFaceFrame f) {
                double s = f.size, cx = f.width / 2.0, cy = f.height / 2.0;
                string[] colors;
                switch (f.get_value("palette", "aurora")) {
                    case "sunset": colors = { "#ff5e62", "#ffb347", "#8e44ff" }; break;
                    case "sea": colors = { "#00c6ff", "#0052d4", "#00f5c4" }; break;
                    default: colors = { "#00ffa3", "#7a5cff", "#00a2ff" }; break;
                }
                cr.set_source_rgb(0.02, 0.025, 0.04);
                cr.paint();
                double t = f.elapsed;
                cr.set_operator(Cairo.Operator.SCREEN);
                for (int i = 0; i < 3; i++) {
                    double phase = i * 2.1;
                    double bx = cx + Math.sin(t * 0.13 + phase) * s * 0.28;
                    double by = cy + Math.cos(t * 0.11 + phase * 1.3) * s * 0.26;
                    double br = s * (0.55 + 0.08 * Math.sin(t * 0.2 + phase));
                    var c = WatchPaint.rgba(colors[i]);
                    var g = new Cairo.Pattern.radial(bx, by, 0, bx, by, br);
                    g.add_color_stop_rgba(0, c.red, c.green, c.blue, 0.75);
                    g.add_color_stop_rgba(0.5, c.red, c.green, c.blue, 0.25);
                    g.add_color_stop_rgba(1, c.red, c.green, c.blue, 0.0);
                    cr.set_source(g);
                    cr.paint();
                }
                cr.set_operator(Cairo.Operator.OVER);
                var shade = new Cairo.Pattern.radial(cx, cy, 0, cx, cy, s * 0.7);
                shade.add_color_stop_rgba(0, 0, 0, 0, 0.0);
                shade.add_color_stop_rgba(1, 0, 0, 0, 0.45);
                cr.set_source(shade);
                cr.paint();
                cr.set_source_rgba(1, 1, 1, 0.97);
                WatchPaint.text(cr, f.time.format("%H:%M"), cx, cy, s * 0.27, 200, 0.5, 0.5, -s * 0.004);
                if (f.get_flag("date", true)) {
                    cr.set_source_rgba(1, 1, 1, 0.8);
                    WatchPaint.text(cr, WatchPaint.date_label(f.time, "%A %e %B"), cx, cy + s * 0.2, s * 0.034, 500, 0.5, 0.5, s * 0.006);
                }
            }
        }

        public class Bauhaus : WatchFaceProvider {
            public override string id { get { return ID + "bauhaus"; } }
            public override string name { get { return _("Bauhaus"); } }

            public override WatchFaceOption[] get_options() {
                return {
                    WatchFaceOption.choice("palette", _("Colors"), { "classic", "night", "sage" }, { _("Classic"), _("Night"), _("Sage") }, "classic"),
                    WatchFaceOption.toggle("seconds", _("Seconds"), true)
                };
            }

            public override WatchFaceRefresh get_refresh(WatchFaceFrame f) {
                return f.get_flag("seconds", true) ? WatchFaceRefresh.CONTINUOUS : WatchFaceRefresh.MINUTE;
            }

            private static void bar(Cairo.Context cr, double cx, double cy, double angle, double length, double width, Gdk.RGBA c) {
                WatchPaint.begin_hand(cr, cx, cy, angle);
                WatchPaint.color(cr, c);
                WatchPaint.rounded_rect(cr, -width / 2, -length, width, length + width / 2, width / 2);
                cr.fill();
                cr.restore();
            }

            public override void draw(Cairo.Context cr, WatchFaceFrame f) {
                double s = f.size, cx = f.width / 2.0, cy = f.height / 2.0, r = s / 2.0;
                string[] c;
                switch (f.get_value("palette", "classic")) {
                    case "night": c = { "#14161a", "#ece6d8", "#ff5a3c", "#f2b705", "#ece6d8" }; break;
                    case "sage": c = { "#c9d3c0", "#23302a", "#e8662f", "#23302a", "#23302a" }; break;
                    default: c = { "#efe8da", "#1d3fb5", "#d9301f", "#f2b705", "#1a1a1a" }; break;
                }
                WatchPaint.paint_background(cr, f, WatchPaint.rgba(c[0]));
                WatchPaint.color(cr, WatchPaint.rgba(c[4]));
                WatchPaint.dot(cr, cx, cy - r * 0.84, s * 0.02);
                for (int i = 1; i < 4; i++) {
                    double x, y;
                    WatchPaint.polar(cx, cy, r * 0.84, WatchPaint.rad(i * 90), out x, out y);
                    WatchPaint.color(cr, WatchPaint.rgba(c[4]), 0.35);
                    WatchPaint.dot(cr, x, y, s * 0.008);
                }
                bar(cr, cx, cy, WatchPaint.hour_angle(f), r * 0.48, s * 0.075, WatchPaint.rgba(c[1]));
                bar(cr, cx, cy, WatchPaint.minute_angle(f), r * 0.76, s * 0.045, WatchPaint.rgba(c[2]));
                if (f.get_flag("seconds", true)) {
                    double x, y;
                    WatchPaint.polar(cx, cy, r * 0.84, WatchPaint.second_angle(f, true), out x, out y);
                    WatchPaint.color(cr, WatchPaint.rgba(c[3]));
                    WatchPaint.dot(cr, x, y, s * 0.028);
                }
                WatchPaint.color(cr, WatchPaint.rgba(c[0]));
                WatchPaint.dot(cr, cx, cy, s * 0.01);
            }
        }

        public class Pilot : WatchFaceProvider {
            public override string id { get { return ID + "pilot"; } }
            public override string name { get { return _("Pilot"); } }

            public override WatchFaceOption[] get_options() {
                return {
                    WatchFaceOption.colors("lume", _("Lume"), { "#e8f3d6", "#bfe3ff", "#ffb066" }, { _("Classic"), _("Blue"), _("Orange") }, "#e8f3d6"),
                    WatchFaceOption.toggle("seconds", _("Seconds Hand"), true)
                };
            }

            public override WatchFaceRefresh get_refresh(WatchFaceFrame f) {
                return f.get_flag("seconds", true) ? WatchFaceRefresh.SECOND : WatchFaceRefresh.MINUTE;
            }

            private static void sword(Cairo.Context cr, double length, double width, Gdk.RGBA steel, Gdk.RGBA lume, bool shadow) {
                cr.move_to(0, -length);
                cr.line_to(width / 2, -length + width * 1.4);
                cr.line_to(width / 2, length * 0.08);
                cr.line_to(-width / 2, length * 0.08);
                cr.line_to(-width / 2, -length + width * 1.4);
                cr.close_path();
                if (shadow) {
                    cr.set_source_rgba(0, 0, 0, 0.45);
                    cr.fill();
                    return;
                }
                WatchPaint.color(cr, steel);
                cr.fill();
                double inset = width * 0.22;
                cr.move_to(0, -length + inset * 2.2);
                cr.line_to(width / 2 - inset, -length + width * 1.4 + inset * 0.4);
                cr.line_to(width / 2 - inset, -length * 0.18);
                cr.line_to(-width / 2 + inset, -length * 0.18);
                cr.line_to(-width / 2 + inset, -length + width * 1.4 + inset * 0.4);
                cr.close_path();
                WatchPaint.color(cr, lume);
                cr.fill();
            }

            public override void draw(Cairo.Context cr, WatchFaceFrame f) {
                double s = f.size, cx = f.width / 2.0, cy = f.height / 2.0, r = s / 2.0;
                var lume = f.get_color("lume", "#e8f3d6");
                cr.set_source_rgb(0.075, 0.078, 0.082);
                cr.paint();
                WatchPaint.vignette(cr, f, 0.05, 0.4);
                WatchPaint.color(cr, lume, 0.9);
                for (int i = 0; i < 60; i++) {
                    if (i == 0) continue;
                    bool major = i % 5 == 0;
                    WatchPaint.tick(cr, cx, cy, r * 0.97, r * (major ? 0.88 : 0.92), WatchPaint.rad(i * 6), s * (major ? 0.01 : 0.004));
                }
                double t0x, t0y;
                WatchPaint.polar(cx, cy, r * 0.97, 0, out t0x, out t0y);
                cr.move_to(cx - s * 0.04, cy - r * 0.97);
                cr.line_to(cx + s * 0.04, cy - r * 0.97);
                cr.line_to(cx, cy - r * 0.8);
                cr.close_path();
                cr.fill();
                foreach (double side in new double[] { -1, 1 }) {
                    double dx, dy;
                    WatchPaint.polar(cx, cy, r * 0.94, WatchPaint.rad(side * 8.5), out dx, out dy);
                    WatchPaint.dot(cr, dx, dy, s * 0.011);
                }
                for (int i = 1; i < 12; i++) {
                    double x, y;
                    WatchPaint.polar(cx, cy, r * 0.7, WatchPaint.rad(i * 30), out x, out y);
                    WatchPaint.color(cr, lume, 0.95);
                    WatchPaint.text(cr, i.to_string(), x, y, s * 0.11, 700);
                }
                var steel = WatchPaint.rgba("#1f3554");
                double ha = WatchPaint.hour_angle(f), ma = WatchPaint.minute_angle(f);
                for (int pass = 0; pass < 2; pass++) {
                    double dx = pass == 0 ? s * 0.007 : 0, dy = pass == 0 ? s * 0.015 : 0;
                    WatchPaint.begin_hand(cr, cx + dx, cy + dy, ha);
                    sword(cr, r * 0.5, s * 0.06, steel, lume, pass == 0);
                    cr.restore();
                    WatchPaint.begin_hand(cr, cx + dx, cy + dy, ma);
                    sword(cr, r * 0.82, s * 0.045, steel, lume, pass == 0);
                    cr.restore();
                }
                WatchPaint.color(cr, steel);
                WatchPaint.dot(cr, cx, cy, s * 0.03);
                if (f.get_flag("seconds", true)) {
                    WatchPaint.begin_hand(cr, cx, cy, WatchPaint.second_angle(f, false));
                    cr.set_source_rgb(0.92, 0.92, 0.9);
                    cr.rectangle(-s * 0.0028, -r * 0.92, s * 0.0056, r * 1.15);
                    cr.fill();
                    WatchPaint.rounded_rect(cr, -s * 0.009, r * 0.12, s * 0.018, r * 0.13, s * 0.004);
                    cr.fill();
                    cr.restore();
                    cr.set_source_rgb(0.92, 0.92, 0.9);
                    WatchPaint.dot(cr, cx, cy, s * 0.011);
                }
            }
        }
    }
}
