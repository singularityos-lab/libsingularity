namespace Singularity.Style {

    internal class AccentIcons {
        private const string TEMPLATE_FILE = "accent-template.ini";
        private const string[] KEYS = {
            "back_depth", "back_mid", "back_top", "back_bot", "front_depth",
            "rim", "front", "glow_a", "glow_b", "mark", "mark_shade"
        };

        private struct Oklch {
            double l;
            double c;
            double h;
        }

        private static double to_linear(double c) {
            return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
        }

        private static double to_srgb(double c) {
            return c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055;
        }

        private static bool parse(string hex, out Oklch result) {
            result = Oklch();
            string h = hex.strip().down();
            if (h.has_prefix("#")) h = h.substring(1);
            if (h.length != 6) return false;
            int v[3];
            for (int i = 0; i < 3; i++) {
                int64 n;
                if (!int64.try_parse("0x" + h.substring(i * 2, 2), out n)) return false;
                v[i] = (int) n;
            }
            double r = to_linear(v[0] / 255.0);
            double g = to_linear(v[1] / 255.0);
            double b = to_linear(v[2] / 255.0);
            double l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
            double m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
            double s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
            double lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s;
            double a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
            double bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
            double hue = Math.atan2(bb, a) * 180 / Math.PI;
            if (hue < 0) hue += 360;
            result = Oklch() { l = lightness, c = Math.sqrt(a * a + bb * bb), h = hue };
            return true;
        }

        private static void to_linear_rgb(double lightness, double chroma, double hue, out double r, out double g, out double b) {
            double a = chroma * Math.cos(hue * Math.PI / 180);
            double bb = chroma * Math.sin(hue * Math.PI / 180);
            double l = Math.pow(lightness + 0.3963377774 * a + 0.2158037573 * bb, 3);
            double m = Math.pow(lightness - 0.1055613458 * a - 0.0638541728 * bb, 3);
            double s = Math.pow(lightness - 0.0894841775 * a - 1.2914855480 * bb, 3);
            r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
            g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
            b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;
        }

        private static string format(double lightness, double chroma, double hue) {
            double r, g, b;
            to_linear_rgb(lightness, chroma, hue, out r, out g, out b);
            for (int i = 0; i < 80; i++) {
                if (r >= -0.0001 && r <= 1.0001 && g >= -0.0001 && g <= 1.0001 && b >= -0.0001 && b <= 1.0001) break;
                chroma *= 0.95;
                to_linear_rgb(lightness, chroma, hue, out r, out g, out b);
            }
            return "#%02x%02x%02x".printf(
                (uint) Math.round(to_srgb(r.clamp(0, 1)).clamp(0, 1) * 255),
                (uint) Math.round(to_srgb(g.clamp(0, 1)).clamp(0, 1) * 255),
                (uint) Math.round(to_srgb(b.clamp(0, 1)).clamp(0, 1) * 255));
        }

        private static string? find_base(string theme) {
            var display = Gdk.Display.get_default();
            if (display == null) return null;
            string[]? dirs = Gtk.IconTheme.get_for_display(display).get_search_path();
            if (dirs == null) return null;
            foreach (unowned string dir in dirs) {
                string path = Path.build_filename(dir, theme);
                if (FileUtils.test(Path.build_filename(path, TEMPLATE_FILE), FileTest.EXISTS)) return path;
            }
            return null;
        }

        public static string? ensure(string theme, string accent_hex) {
            string? base_dir = find_base(theme);
            if (base_dir == null) return null;
            var kf = new KeyFile();
            var template = new HashTable<string, string>(str_hash, str_equal);
            double follow, min_ratio, neutral;
            try {
                kf.load_from_file(Path.build_filename(base_dir, TEMPLATE_FILE), KeyFileFlags.NONE);
                foreach (unowned string key in KEYS) template.insert(key, kf.get_string("Accent Template", key).down());
                follow = kf.get_double("Derivation", "hue_follow");
                min_ratio = kf.get_double("Derivation", "min_chroma_ratio");
                neutral = kf.get_double("Derivation", "neutral_chroma");
            } catch (Error e) {
                return null;
            }

            Oklch accent;
            Oklch front;
            if (!parse(accent_hex, out accent)) return null;
            if (!parse(template.get("front"), out front)) return null;
            string tag = accent_hex.strip().down().replace("#", "");
            string name = "%s-custom-%s".printf(theme, tag);
            string icons_dir = Path.build_filename(Environment.get_user_data_dir(), "icons");
            string dest = Path.build_filename(icons_dir, name);
            if (FileUtils.test(Path.build_filename(dest, "index.theme"), FileTest.EXISTS)) return name;

            double ratio = (accent.c / front.c).clamp(min_ratio, 1.0);
            double hue = accent.c < neutral ? front.h : accent.h;
            var palette = new HashTable<string, string>(str_hash, str_equal);
            foreach (unowned string key in KEYS) {
                Oklch t;
                if (!parse(template.get(key), out t)) return null;
                double offset = t.h - front.h + 180;
                offset = offset - Math.floor(offset / 360) * 360 - 180;
                palette.insert(key, format(t.l, t.c * ratio, hue + offset * follow));
            }

            string tmp = "%s.tmp-%s".printf(dest, Uuid.string_random());
            try {
                remove_tree(tmp);
                var dirs = new GenericArray<string>();
                string scalable = Path.build_filename(base_dir, "scalable");
                var sd = Dir.open(scalable);
                string? ctx;
                while ((ctx = sd.read_name()) != null) {
                    string ctx_path = Path.build_filename(scalable, ctx);
                    if (!FileUtils.test(ctx_path, FileTest.IS_DIR)) continue;
                    bool used = false;
                    var cd = Dir.open(ctx_path);
                    string? file;
                    while ((file = cd.read_name()) != null) {
                        if (!file.has_suffix(".svg")) continue;
                        string src = Path.build_filename(ctx_path, file);
                        string out_path = Path.build_filename(tmp, "scalable", ctx, file);
                        if (FileUtils.test(src, FileTest.IS_SYMLINK)) {
                            string target = FileUtils.read_link(src);
                            string resolved = Path.is_absolute(target) ? target : Path.build_filename(ctx_path, target);
                            if (!is_template(resolved, template)) continue;
                            DirUtils.create_with_parents(Path.get_dirname(out_path), 0755);
                            FileUtils.symlink(target, out_path);
                            used = true;
                            continue;
                        }
                        if (!is_template(src, template)) continue;
                        string text;
                        FileUtils.get_contents(src, out text);
                        DirUtils.create_with_parents(Path.get_dirname(out_path), 0755);
                        FileUtils.set_contents(out_path, recolor(text, template, palette));
                        used = true;
                    }
                    if (used) dirs.add("scalable/" + ctx);
                }
                if (dirs.length == 0) {
                    remove_tree(tmp);
                    return null;
                }
                var index = new StringBuilder();
                index.append("[Icon Theme]\nName=%s\nComment=%s folders in a custom accent\nInherits=%s\nHidden=true\nDirectories=".printf(name, theme, theme));
                for (int i = 0; i < dirs.length; i++) index.append((i > 0 ? "," : "") + dirs[i]);
                index.append("\n");
                foreach (unowned string d in dirs.data) {
                    index.append("\n[%s]\nSize=16\nMinSize=8\nMaxSize=512\nType=Scalable\n".printf(d));
                }
                FileUtils.set_contents(Path.build_filename(tmp, "index.theme"), index.str);
                prune_custom(icons_dir, theme, name);
                if (FileUtils.rename(tmp, dest) != 0) {
                    remove_tree(tmp);
                    return FileUtils.test(Path.build_filename(dest, "index.theme"), FileTest.EXISTS) ? name : null;
                }
            } catch (Error e) {
                warning("accent icons: %s", e.message);
                remove_tree(tmp);
                return null;
            }
            return name;
        }

        private static bool is_template(string path, HashTable<string, string> template) {
            string text;
            try {
                FileUtils.get_contents(path, out text);
            } catch (Error e) {
                return false;
            }
            text = text.down();
            return text.contains(template.get("front")) && text.contains(template.get("back_top"));
        }

        private static string recolor(string text, HashTable<string, string> template, HashTable<string, string> palette) {
            string out_text = text;
            foreach (unowned string key in KEYS) {
                string marker = "\x01%s\x01".printf(key);
                out_text = out_text.replace(template.get(key), marker).replace(template.get(key).up(), marker);
            }
            foreach (unowned string key in KEYS) {
                out_text = out_text.replace("\x01%s\x01".printf(key), palette.get(key));
            }
            return out_text;
        }

        private static void prune_custom(string icons_dir, string theme, string keep) {
            try {
                var d = Dir.open(icons_dir);
                string? n;
                string prefix = theme + "-custom-";
                while ((n = d.read_name()) != null) {
                    if (n.has_prefix(prefix) && n != keep) remove_tree(Path.build_filename(icons_dir, n));
                }
            } catch (Error e) {
            }
        }

        private static void remove_tree(string path) {
            if (FileUtils.test(path, FileTest.IS_SYMLINK) || FileUtils.test(path, FileTest.IS_REGULAR)) {
                FileUtils.remove(path);
                return;
            }
            if (!FileUtils.test(path, FileTest.IS_DIR)) return;
            try {
                var d = Dir.open(path);
                string? n;
                while ((n = d.read_name()) != null) remove_tree(Path.build_filename(path, n));
            } catch (Error e) {
            }
            DirUtils.remove(path);
        }
    }
}
