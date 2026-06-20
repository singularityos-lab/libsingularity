namespace Singularity {

    public class ColorUtil {

        public static void rgb_to_hsv(double r, double g, double b,
                                      out double h, out double s, out double v) {
            double mx = double.max(r, double.max(g, b));
            double mn = double.min(r, double.min(g, b));
            double d  = mx - mn;
            v = mx;
            s = (mx == 0.0) ? 0.0 : d / mx;
            if (d == 0.0) { h = 0.0; return; }
            if (mx == r)      h = 60.0 * (((g - b) / d) % 6.0);
            else if (mx == g) h = 60.0 * (((b - r) / d) + 2.0);
            else              h = 60.0 * (((r - g) / d) + 4.0);
            if (h < 0.0) h += 360.0;
        }

        public static void hsv_to_rgb(double h, double s, double v,
                                      out double r, out double g, out double b) {
            h = ((h % 360.0) + 360.0) % 360.0;
            double c  = v * s;
            double x  = c * (1.0 - Math.fabs((h / 60.0) % 2.0 - 1.0));
            double m  = v - c;
            double r1 = 0, g1 = 0, b1 = 0;
            if      (h < 60)  { r1 = c; g1 = x; b1 = 0; }
            else if (h < 120) { r1 = x; g1 = c; b1 = 0; }
            else if (h < 180) { r1 = 0; g1 = c; b1 = x; }
            else if (h < 240) { r1 = 0; g1 = x; b1 = c; }
            else if (h < 300) { r1 = x; g1 = 0; b1 = c; }
            else              { r1 = c; g1 = 0; b1 = x; }
            r = r1 + m; g = g1 + m; b = b1 + m;
        }

        public static string hsv_to_hex(double h, double s, double v) {
            double r, g, b;
            hsv_to_rgb(h, s, v, out r, out g, out b);
            return "#%02x%02x%02x".printf((uint)(r * 255 + 0.5),
                                          (uint)(g * 255 + 0.5),
                                          (uint)(b * 255 + 0.5));
        }

        public static double srgb_luminance(double r, double g, double b) {
            return 0.2126 * r + 0.7152 * g + 0.0722 * b;
        }
    }
}
