namespace Singularity {

    public enum SunDay { NORMAL, POLAR_DAY, POLAR_NIGHT }

    public class SunTimes : GLib.Object {
        private const double ZENITH = 90.833;

        public static SunDay compute(double latitude, double longitude, int year, int month, int day,
                                     out double sunrise_utc, out double sunset_utc) {
            sunrise_utc = 0;
            sunset_utc = 0;
            var date = GLib.Date();
            date.set_dmy((GLib.DateDay) day, (GLib.DateMonth) month, (GLib.DateYear) year);
            int doy = (int) date.get_day_of_year();
            int days = ((GLib.DateYear) year).is_leap_year() ? 366 : 365;
            double gamma = 2.0 * Math.PI / days * (doy - 1);
            double eqtime = 229.18 * (0.000075 + 0.001868 * Math.cos(gamma) - 0.032077 * Math.sin(gamma)
                - 0.014615 * Math.cos(2 * gamma) - 0.040849 * Math.sin(2 * gamma));
            double decl = 0.006918 - 0.399912 * Math.cos(gamma) + 0.070257 * Math.sin(gamma)
                - 0.006758 * Math.cos(2 * gamma) + 0.000907 * Math.sin(2 * gamma)
                - 0.002697 * Math.cos(3 * gamma) + 0.00148 * Math.sin(3 * gamma);
            double lat = latitude.clamp(-89.99, 89.99) * Math.PI / 180.0;
            double cos_ha = Math.cos(ZENITH * Math.PI / 180.0) / (Math.cos(lat) * Math.cos(decl))
                - Math.tan(lat) * Math.tan(decl);
            if (cos_ha < -1.0) return SunDay.POLAR_DAY;
            if (cos_ha > 1.0) return SunDay.POLAR_NIGHT;
            double ha = Math.acos(cos_ha) * 180.0 / Math.PI;
            sunrise_utc = 720.0 - 4.0 * (longitude + ha) - eqtime;
            sunset_utc = 720.0 - 4.0 * (longitude - ha) - eqtime;
            return SunDay.NORMAL;
        }

        public static SunDay local_times(double latitude, double longitude, GLib.DateTime local_day,
                                         out string sunset, out string sunrise) {
            sunset = "";
            sunrise = "";
            double rise_utc, set_utc;
            var day = compute(latitude, longitude, local_day.get_year(), local_day.get_month(),
                local_day.get_day_of_month(), out rise_utc, out set_utc);
            if (day != SunDay.NORMAL) return day;
            var midnight_utc = new GLib.DateTime.utc(local_day.get_year(), local_day.get_month(),
                local_day.get_day_of_month(), 0, 0, 0);
            var tz = local_day.get_timezone();
            sunrise = midnight_utc.add_seconds(Math.round(rise_utc * 60)).to_timezone(tz).format("%H:%M");
            sunset = midnight_utc.add_seconds(Math.round(set_utc * 60)).to_timezone(tz).format("%H:%M");
            return day;
        }

        public static bool parse_iso6709(string text, out double latitude, out double longitude) {
            latitude = 0;
            longitude = 0;
            int split = -1;
            for (int i = 1; i < text.length; i++) {
                if (text[i] == '+' || text[i] == '-') {
                    split = i;
                    break;
                }
            }
            if (split < 0) return false;
            double lat, lon;
            if (!parse_angle(text.substring(0, split), 2, out lat)) return false;
            if (!parse_angle(text.substring(split), 3, out lon)) return false;
            latitude = lat;
            longitude = lon;
            return true;
        }

        private static bool parse_angle(string part, int degree_digits, out double value) {
            value = 0;
            if (part.length < 1 + degree_digits + 2) return false;
            double sign = part[0] == '-' ? -1.0 : 1.0;
            if (part[0] != '+' && part[0] != '-') return false;
            string digits = part.substring(1);
            for (int i = 0; i < digits.length; i++) {
                if (!digits[i].isdigit()) return false;
            }
            double deg = double.parse(digits.substring(0, degree_digits));
            double min = double.parse(digits.substring(degree_digits, 2));
            double sec = digits.length >= degree_digits + 4 ? double.parse(digits.substring(degree_digits + 2, 2)) : 0;
            value = sign * (deg + min / 60.0 + sec / 3600.0);
            return true;
        }

        public static bool timezone_coordinates(string tz_id, out double latitude, out double longitude,
                                                string? zoneinfo_dir = null) {
            latitude = 0;
            longitude = 0;
            string dir = zoneinfo_dir ?? GLib.Environment.get_variable("TZDIR") ?? "/usr/share/zoneinfo";
            foreach (string name in new string[] { "zone1970.tab", "zone.tab" }) {
                string contents;
                try {
                    if (!GLib.FileUtils.get_contents(GLib.Path.build_filename(dir, name), out contents)) continue;
                } catch (GLib.Error e) {
                    continue;
                }
                foreach (string line in contents.split("\n")) {
                    if (line.has_prefix("#")) continue;
                    var cols = line.split("\t");
                    if (cols.length < 3 || cols[2] != tz_id) continue;
                    if (parse_iso6709(cols[1], out latitude, out longitude)) return true;
                }
            }
            return false;
        }

        public static string? local_timezone_id() {
            string? env = GLib.Environment.get_variable("TZ");
            if (env != null && env != "") {
                string id = env.has_prefix(":") ? env.substring(1) : env;
                if (!id.has_prefix("/")) return id;
            }
            string ident = new GLib.TimeZone.local().get_identifier();
            if (ident != "" && ident != "localtime" && !ident.has_prefix("/") && ident != "UTC") return ident;
            try {
                string target = GLib.FileUtils.read_link("/etc/localtime");
                int pos = target.index_of("zoneinfo/");
                if (pos >= 0) return target.substring(pos + 9);
            } catch (GLib.FileError e) {
            }
            try {
                string contents;
                if (GLib.FileUtils.get_contents("/etc/timezone", out contents)) {
                    string id = contents.strip();
                    if (id != "") return id;
                }
            } catch (GLib.FileError e) {
            }
            return null;
        }
    }
}
