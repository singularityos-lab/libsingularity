namespace Singularity.Print {

    public abstract class SnapshotSource : PageSource {
        public const double CSS_PX_PER_POINT = 96.0 / 72.0;

        public double resolution { get; set; default = 2.0; }

        private Cairo.ImageSurface? strip;
        private int serial;
        private double pixels_per_point = 1;
        private int[] cuts = {};
        private PageFormat format = new PageFormat();
        private Gee.HashMap<int, Cairo.ImageSurface> slices = new Gee.HashMap<int, Cairo.ImageSurface>();

        protected abstract async Cairo.ImageSurface render_strip(int css_width, double resolution) throws Error;

        public override async int paginate(PageFormat format) throws Error {
            int ticket = ++serial;
            int css_width = int.max((int) Math.floor(format.content_width * CSS_PX_PER_POINT), 1);
            var rendered = yield render_strip(css_width, resolution);
            if (ticket != serial) throw new IOError.CANCELLED(_("A newer layout replaced this one"));
            rendered.flush();
            this.format = format;
            page_width = format.width;
            page_height = format.height;
            slices.clear();
            strip = rendered;
            pixels_per_point = strip.get_width() / double.max(format.content_width, 1);
            int page_px = int.max((int) Math.floor(format.content_height * pixels_per_point), 1);
            cuts = page_breaks(strip, page_px, page_px / 5);
            return cuts.length - 1;
        }

        public override void render_page(Cairo.Context cr, int index) {
            if (strip == null || index < 0 || index + 1 >= cuts.length) return;
            var slice = slices[index];
            if (slice == null) {
                int h = int.max(cuts[index + 1] - cuts[index], 1);
                slice = new Cairo.ImageSurface(Cairo.Format.ARGB32, strip.get_width(), h);
                var sc = new Cairo.Context(slice);
                sc.set_source_surface(strip, 0, -cuts[index]);
                sc.paint();
                slice.flush();
                slices[index] = slice;
            }
            cr.save();
            cr.translate(format.margin_left, format.margin_top);
            cr.scale(1 / pixels_per_point, 1 / pixels_per_point);
            cr.set_source_surface(slice, 0, 0);
            cr.paint();
            cr.restore();
        }

        public static int[] page_breaks(Cairo.ImageSurface surface, int page_px, int search) {
            surface.flush();
            int height = surface.get_height();
            int[] result = {0};
            int start = 0;
            page_px = int.max(page_px, 1);
            while (start + page_px < height) {
                int cut = start + page_px;
                for (int y = cut; y > cut - search && y > start; y--) {
                    if (uniform_row(surface, y)) {
                        cut = y;
                        break;
                    }
                }
                result += cut;
                start = cut;
            }
            if (height > 0 && result[result.length - 1] < height) result += height;
            if (result.length == 1) result += int.max(height, 1);
            return result;
        }

        public static bool uniform_row(Cairo.ImageSurface surface, int y) {
            int w = surface.get_width();
            if (y < 0 || y >= surface.get_height() || w == 0) return false;
            int stride = surface.get_stride();
            unowned uint8[] data = surface.get_data();
            int row = y * stride;
            for (int x = 1; x < w; x++) {
                int p = row + x * 4;
                if (data[p] != data[row] || data[p + 1] != data[row + 1]
                    || data[p + 2] != data[row + 2] || data[p + 3] != data[row + 3]) return false;
            }
            return true;
        }

        public static Cairo.ImageSurface surface_from_texture(Gdk.Texture texture) {
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, texture.get_width(), texture.get_height());
            surface.flush();
            unowned uint8[] data = surface.get_data();
            texture.download(data, surface.get_stride());
            surface.mark_dirty();
            return surface;
        }
    }
}
