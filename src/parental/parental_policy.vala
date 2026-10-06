namespace Singularity.Parental {

    public enum Verdict {
        ALLOWED,
        WARNING,
        LIMIT_REACHED,
        BEDTIME
    }

    public class Policy : Object {
        public const string GROUP_APPS = "Apps";
        public const string GROUP_TIME = "Time";
        public const string GROUP_WEB = "Web";

        public string user_name { get; set; default = ""; }
        public string[] blocked_apps { get; set; default = {}; }
        public int daily_limit_minutes { get; set; default = 0; }
        public int warning_minutes { get; set; default = 5; }
        public bool bedtime_enabled { get; set; default = false; }
        public int bedtime_start { get; set; default = 21 * 60; }
        public int bedtime_end { get; set; default = 7 * 60; }
        public bool web_filter_enabled { get; set; default = false; }
        public bool web_allow_listed_only { get; set; default = false; }
        public string[] blocked_sites { get; set; default = {}; }
        public string[] allowed_sites { get; set; default = {}; }

        public Policy(string user_name) {
            this.user_name = user_name;
        }

        public bool is_active {
            get {
                return blocked_apps.length > 0 || daily_limit_minutes > 0 || bedtime_enabled || web_filter_enabled;
            }
        }

        public static string normalize_app_id(string app_id) {
            string id = app_id.strip();
            if (id.has_suffix(".desktop")) id = id.substring(0, id.length - 8);
            return id.down();
        }

        public bool blocks_app(string? app_id) {
            if (app_id == null || app_id == "") return false;
            string id = normalize_app_id(app_id);
            foreach (string blocked in blocked_apps) {
                if (normalize_app_id(blocked) == id) return true;
            }
            return false;
        }

        public void set_app_blocked(string app_id, bool blocked) {
            string id = normalize_app_id(app_id);
            string[] list = {};
            foreach (string item in blocked_apps) {
                if (normalize_app_id(item) != id) list += item;
            }
            if (blocked) list += id;
            blocked_apps = list;
        }

        public static int parse_minutes(string hhmm, int fallback) {
            var parts = hhmm.strip().split(":");
            if (parts.length != 2) return fallback;
            int h = int.parse(parts[0]);
            int m = int.parse(parts[1]);
            if (h < 0 || h > 23 || m < 0 || m > 59) return fallback;
            return h * 60 + m;
        }

        public static string format_minutes(int minutes) {
            int m = ((minutes % 1440) + 1440) % 1440;
            return "%02d:%02d".printf(m / 60, m % 60);
        }

        public bool in_bedtime(int minute_of_day) {
            if (!bedtime_enabled || bedtime_start == bedtime_end) return false;
            if (bedtime_start < bedtime_end) return minute_of_day >= bedtime_start && minute_of_day < bedtime_end;
            return minute_of_day >= bedtime_start || minute_of_day < bedtime_end;
        }

        public int minutes_until_bedtime(int minute_of_day) {
            if (!bedtime_enabled || bedtime_start == bedtime_end) return -1;
            if (in_bedtime(minute_of_day)) return 0;
            return ((bedtime_start - minute_of_day) % 1440 + 1440) % 1440;
        }

        public int64 seconds_left(int64 used_seconds) {
            if (daily_limit_minutes <= 0) return -1;
            return int64.max(0, (int64) daily_limit_minutes * 60 - used_seconds);
        }

        public Verdict evaluate(int minute_of_day, int64 used_seconds) {
            if (in_bedtime(minute_of_day)) return Verdict.BEDTIME;
            int64 left = seconds_left(used_seconds);
            if (left == 0) return Verdict.LIMIT_REACHED;
            int warn = int.max(0, warning_minutes);
            if (left > 0 && left <= (int64) warn * 60) return Verdict.WARNING;
            int until_bed = minutes_until_bedtime(minute_of_day);
            if (until_bed > 0 && until_bed <= warn) return Verdict.WARNING;
            return Verdict.ALLOWED;
        }

        public static string? host_of(string uri) {
            string? host = Uri.peek_scheme(uri) != null ? null : uri;
            try {
                if (host == null) host = Uri.parse(uri, UriFlags.NONE).get_host();
            } catch (Error e) {
                return null;
            }
            if (host == null) return null;
            host = host.down();
            if (host.has_suffix(".")) host = host.substring(0, host.length - 1);
            return host;
        }

        public static string normalize_site(string site) {
            string s = site.strip().down();
            if (s.contains("://")) s = host_of(s) ?? s;
            int slash = s.index_of_char('/');
            if (slash >= 0) s = s.substring(0, slash);
            if (s.has_prefix("www.")) s = s.substring(4);
            return s;
        }

        private static bool host_matches(string host, string[] sites) {
            foreach (string raw in sites) {
                string site = normalize_site(raw);
                if (site == "") continue;
                if (host == site || host.has_suffix("." + site)) return true;
            }
            return false;
        }

        public bool blocks_uri(string uri) {
            if (!web_filter_enabled) return false;
            string? scheme = Uri.peek_scheme(uri);
            if (scheme != "http" && scheme != "https") return false;
            string? host = host_of(uri);
            if (host == null || host == "") return false;
            if (web_allow_listed_only) return !host_matches(host, allowed_sites);
            return host_matches(host, blocked_sites);
        }

        public string to_data() {
            var kf = new KeyFile();
            kf.set_string_list(GROUP_APPS, "Blocked", blocked_apps);
            kf.set_integer(GROUP_TIME, "DailyLimitMinutes", daily_limit_minutes);
            kf.set_integer(GROUP_TIME, "WarningMinutes", warning_minutes);
            kf.set_boolean(GROUP_TIME, "Bedtime", bedtime_enabled);
            kf.set_string(GROUP_TIME, "BedtimeStart", format_minutes(bedtime_start));
            kf.set_string(GROUP_TIME, "BedtimeEnd", format_minutes(bedtime_end));
            kf.set_boolean(GROUP_WEB, "Filter", web_filter_enabled);
            kf.set_boolean(GROUP_WEB, "AllowListedOnly", web_allow_listed_only);
            kf.set_string_list(GROUP_WEB, "Blocked", blocked_sites);
            kf.set_string_list(GROUP_WEB, "Allowed", allowed_sites);
            return kf.to_data();
        }

        private static string[] read_list(KeyFile kf, string group, string key) {
            try {
                if (kf.has_group(group) && kf.has_key(group, key)) {
                    string[] out_list = {};
                    foreach (string item in kf.get_string_list(group, key)) {
                        if (item.strip() != "") out_list += item.strip();
                    }
                    return out_list;
                }
            } catch (Error e) {
            }
            return {};
        }

        private static int read_int(KeyFile kf, string group, string key, int fallback) {
            try {
                if (kf.has_group(group) && kf.has_key(group, key)) return kf.get_integer(group, key);
            } catch (Error e) {
            }
            return fallback;
        }

        private static bool read_bool(KeyFile kf, string group, string key, bool fallback) {
            try {
                if (kf.has_group(group) && kf.has_key(group, key)) return kf.get_boolean(group, key);
            } catch (Error e) {
            }
            return fallback;
        }

        private static string read_string(KeyFile kf, string group, string key, string fallback) {
            try {
                if (kf.has_group(group) && kf.has_key(group, key)) return kf.get_string(group, key);
            } catch (Error e) {
            }
            return fallback;
        }

        public static Policy from_data(string user_name, string data) throws Error {
            var kf = new KeyFile();
            kf.load_from_data(data, data.length, KeyFileFlags.NONE);
            var policy = new Policy(user_name);
            policy.blocked_apps = read_list(kf, GROUP_APPS, "Blocked");
            policy.daily_limit_minutes = read_int(kf, GROUP_TIME, "DailyLimitMinutes", 0).clamp(0, 24 * 60);
            policy.warning_minutes = read_int(kf, GROUP_TIME, "WarningMinutes", 5).clamp(0, 60);
            policy.bedtime_enabled = read_bool(kf, GROUP_TIME, "Bedtime", false);
            policy.bedtime_start = parse_minutes(read_string(kf, GROUP_TIME, "BedtimeStart", "21:00"), 21 * 60);
            policy.bedtime_end = parse_minutes(read_string(kf, GROUP_TIME, "BedtimeEnd", "07:00"), 7 * 60);
            policy.web_filter_enabled = read_bool(kf, GROUP_WEB, "Filter", false);
            policy.web_allow_listed_only = read_bool(kf, GROUP_WEB, "AllowListedOnly", false);
            policy.blocked_sites = read_list(kf, GROUP_WEB, "Blocked");
            policy.allowed_sites = read_list(kf, GROUP_WEB, "Allowed");
            return policy;
        }

        public Policy copy() {
            try {
                return from_data(user_name, to_data());
            } catch (Error e) {
                return new Policy(user_name);
            }
        }
    }
}
