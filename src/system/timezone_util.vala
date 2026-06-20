using GLib;

namespace Singularity {

    public class TimezoneUtil {

        public static string[] list() {
            var file = File.new_for_path("/usr/share/zoneinfo/zone.tab");
            if (!file.query_exists()) {
                return {"UTC", "Europe/Rome", "America/New_York", "Asia/Tokyo"};
            }
            var l = new List<string>();
            walk(File.new_for_path("/usr/share/zoneinfo"), "", l);
            l.sort(string.collate);
            string[] arr = new string[l.length()];
            int i = 0;
            foreach (var tz in l) {
                arr[i++] = tz;
            }
            return arr;
        }

        private static void walk(File dir, string prefix, List<string> list) {
            try {
                var enumerator = dir.enumerate_children(
                    FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE, 0);
                FileInfo info;
                while ((info = enumerator.next_file()) != null) {
                    string name = info.get_name();
                    if (name == "." || name == ".." || name == "posix" ||
                        name == "right" || name == "Etc" || name == "SystemV") continue;
                    if (info.get_file_type() == FileType.DIRECTORY) {
                        walk(dir.get_child(name), prefix + name + "/", list);
                    } else {
                        list.append(prefix + name);
                    }
                }
            } catch (Error e) {}
        }
    }
}
