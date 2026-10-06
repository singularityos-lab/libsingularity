namespace Singularity.FileSystem {

    /**
     * Reads and writes the freedesktop.org thumbnail cache.
     *
     * Thumbnails live in `$XDG_CACHE_HOME/thumbnails/<size>/`, named after
     * the MD5 of the file URI, and carry the `Thumb::URI` and
     * `Thumb::MTime` PNG text chunks, so thumbnails written here are
     * reused by every other application that follows the specification,
     * and the other way round. Failures are recorded under
     * `thumbnails/fail/<app>/` so an undecodable file is not retried until
     * it changes.
     *
     * The methods block on disk and image work; call them from a worker
     * thread.
     */
    public class ThumbnailCache : Object {

        /** The sizes of the specification, in pixels. */
        public enum Size {
            NORMAL = 128,
            LARGE = 256,
            X_LARGE = 512,
            XX_LARGE = 1024;

            /** The directory name of the size. */
            public string to_folder() {
                switch (this) {
                    case NORMAL: return "normal";
                    case LARGE: return "large";
                    case X_LARGE: return "x-large";
                    default: return "xx-large";
                }
            }

            /** The smallest size holding `pixels` pixels, or the largest size. */
            public static Size for_pixels(int pixels) {
                if (pixels <= NORMAL) return NORMAL;
                if (pixels <= LARGE) return LARGE;
                if (pixels <= X_LARGE) return X_LARGE;
                return XX_LARGE;
            }
        }

        private const Size[] SIZES = { Size.NORMAL, Size.LARGE, Size.X_LARGE, Size.XX_LARGE };

        /** The root of the cache, normally `~/.cache/thumbnails`. */
        public static string root() {
            return Path.build_filename(Environment.get_user_cache_dir(), "thumbnails");
        }

        /** The file name of the thumbnail of `uri`: the MD5 of the URI plus `.png`. */
        public static string file_name(string uri) {
            return Checksum.compute_for_string(ChecksumType.MD5, uri) + ".png";
        }

        /** The path of the thumbnail of `uri` at `size`, whether it exists or not. */
        public static string path_for(string uri, Size size) {
            return Path.build_filename(root(), size.to_folder(), file_name(uri));
        }

        /** The path of the failure record of `uri` written by `app`. */
        public static string failure_path(string app, string uri) {
            return Path.build_filename(root(), "fail", app, file_name(uri));
        }

        /**
         * Loads a thumbnail of `uri` that is still valid for `mtime` and has
         * at least `pixels` pixels on its longer side when such a size
         * exists, falling back to the largest valid one.
         *
         * @return The thumbnail, or null when none is cached or valid.
         */
        public static Gdk.Pixbuf? load(string uri, int64 mtime, int pixels) {
            Size wanted = Size.for_pixels(pixels);
            int start = 0;
            while (SIZES[start] != wanted) start++;
            for (int i = start; i < SIZES.length; i++) {
                var pixbuf = read_valid(path_for(uri, SIZES[i]), uri, mtime);
                if (pixbuf != null) return pixbuf;
            }
            for (int i = start - 1; i >= 0; i--) {
                var pixbuf = read_valid(path_for(uri, SIZES[i]), uri, mtime);
                if (pixbuf != null) return pixbuf;
            }
            return null;
        }

        /**
         * Stores `image` as the thumbnail of `uri`, scaled down to each of
         * `sizes`. Images smaller than a size are stored unscaled.
         *
         * @param image    The full image, for example a video frame.
         * @param uri      The URI of the file the thumbnail stands for.
         * @param mtime    The modification time of that file, in seconds.
         * @param mime     Its MIME type, or null.
         * @param sizes    The sizes to write.
         * @return Whether every size was written.
         */
        public static bool save(Gdk.Pixbuf image, string uri, int64 mtime, string? mime,
                                Size[] sizes = { Size.NORMAL, Size.LARGE }) {
            bool ok = true;
            foreach (Size size in sizes) {
                var scaled = scale_to(image, (int) size);
                ok = write_png(scaled, path_for(uri, size), uri, mtime, mime) && ok;
            }
            return ok;
        }

        /** Records that no thumbnail can be made for `uri` at `mtime`. */
        public static bool save_failure(string app, string uri, int64 mtime) {
            var marker = new Gdk.Pixbuf(Gdk.Colorspace.RGB, true, 8, 1, 1);
            marker.fill(0);
            return write_png(marker, failure_path(app, uri), uri, mtime, null);
        }

        /** Whether `app` recorded a failure for `uri` that is still valid for `mtime`. */
        public static bool has_failed(string app, string uri, int64 mtime) {
            return read_valid(failure_path(app, uri), uri, mtime) != null;
        }

        /** Scales `image` down so its longer side is at most `pixels`. */
        public static Gdk.Pixbuf scale_to(Gdk.Pixbuf image, int pixels) {
            int width = image.width;
            int height = image.height;
            int longest = int.max(width, height);
            if (longest <= pixels) return image;
            double factor = (double) pixels / longest;
            int w = int.max(1, (int) Math.round(width * factor));
            int h = int.max(1, (int) Math.round(height * factor));
            return image.scale_simple(w, h, Gdk.InterpType.BILINEAR);
        }

        private static Gdk.Pixbuf? read_valid(string path, string uri, int64 mtime) {
            if (!FileUtils.test(path, FileTest.IS_REGULAR)) return null;
            try {
                var pixbuf = new Gdk.Pixbuf.from_file(path);
                if (pixbuf.get_option("tEXt::Thumb::URI") != uri) return null;
                if (pixbuf.get_option("tEXt::Thumb::MTime") != mtime.to_string()) return null;
                return pixbuf;
            } catch (Error e) {
                return null;
            }
        }

        private static bool write_png(Gdk.Pixbuf image, string path, string uri, int64 mtime, string? mime) {
            string dir = Path.get_dirname(path);
            if (DirUtils.create_with_parents(dir, 0700) != 0) return false;
            string temp = "%s.%s.tmp".printf(path, Uuid.string_random());
            try {
                string[] keys = { "tEXt::Thumb::URI", "tEXt::Thumb::MTime", "tEXt::Software" };
                string[] values = { uri, mtime.to_string(), "Singularity" };
                if (mime != null) {
                    keys += "tEXt::Thumb::Mimetype";
                    values += mime;
                }
                image.savev(temp, "png", keys, values);
                FileUtils.chmod(temp, 0600);
                if (FileUtils.rename(temp, path) != 0) {
                    FileUtils.unlink(temp);
                    return false;
                }
                return true;
            } catch (Error e) {
                FileUtils.unlink(temp);
                return false;
            }
        }
    }
}
