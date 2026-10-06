namespace Singularity.Imaging {

    namespace Filters {

        private int[] box_sizes(double sigma, int n) {
            double ideal = Math.sqrt((12.0 * sigma * sigma / n) + 1.0);
            int wl = (int) Math.floor(ideal);
            if (wl % 2 == 0) wl--;
            int wu = wl + 2;
            double mi = (12.0 * sigma * sigma - n * wl * wl - 4.0 * n * wl - 3.0 * n) / (-4.0 * wl - 4.0);
            int m = (int) Math.round(mi);
            var sizes = new int[n];
            for (int i = 0; i < n; i++) sizes[i] = i < m ? wl : wu;
            return sizes;
        }

        private void box_h(float[] src, float[] dst, int w, int h, int r) {
            if (r <= 0) {
                Memory.copy(dst, src, src.length * sizeof(float));
                return;
            }
            float inv = 1.0f / (r + r + 1);
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    size_t row = (size_t) y * w;
                    float first = src[row], last = src[row + w - 1];
                    float acc = (r + 1) * first;
                    for (int j = 0; j < r; j++) acc += src[row + int.min(j, w - 1)];
                    for (int x = 0; x < w; x++) {
                        int add = x + r, sub = x - r - 1;
                        acc += add < w ? src[row + add] : last;
                        acc -= sub >= 0 ? src[row + sub] : first;
                        dst[row + x] = acc * inv;
                    }
                }
            });
        }

        private void box_v(float[] src, float[] dst, int w, int h, int r) {
            if (r <= 0) {
                Memory.copy(dst, src, src.length * sizeof(float));
                return;
            }
            float inv = 1.0f / (r + r + 1);
            Parallel.range(w, (start, end) => {
                for (int x = start; x < end; x++) {
                    float first = src[x], last = src[(size_t) (h - 1) * w + x];
                    float acc = (r + 1) * first;
                    for (int j = 0; j < r; j++) acc += src[(size_t) int.min(j, h - 1) * w + x];
                    for (int y = 0; y < h; y++) {
                        int add = y + r, sub = y - r - 1;
                        acc += add < h ? src[(size_t) add * w + x] : last;
                        acc -= sub >= 0 ? src[(size_t) sub * w + x] : first;
                        dst[(size_t) y * w + x] = acc * inv;
                    }
                }
            });
        }

        public float[] box_plane(float[] plane, int w, int h, int radius) {
            var tmp = new float[plane.length];
            var out_plane = new float[plane.length];
            box_h(plane, tmp, w, h, radius);
            box_v(tmp, out_plane, w, h, radius);
            return out_plane;
        }

        public float[] gaussian_plane(float[] plane, int w, int h, double sigma) {
            if (sigma < 0.2) return plane.copy();
            var sizes = box_sizes(sigma, 3);
            var a = plane.copy();
            var b = new float[plane.length];
            foreach (int size in sizes) {
                int r = (size - 1) / 2;
                box_h(a, b, w, h, r);
                box_v(b, a, w, h, r);
            }
            return a;
        }

        public FloatImage gaussian(FloatImage img, double sigma, bool alpha = false) {
            var out_img = img.copy();
            if (sigma < 0.2) return out_img;
            int channels = alpha ? 4 : 3;
            for (int c = 0; c < channels; c++) out_img.set_channel(c, gaussian_plane(img.channel(c), img.width, img.height, sigma));
            return out_img;
        }

        public float[] guided_plane(float[] guide, float[] src, int w, int h, int radius, float eps) {
            int n = guide.length;
            var ip = new float[n];
            var ii = new float[n];
            for (int i = 0; i < n; i++) {
                ip[i] = guide[i] * src[i];
                ii[i] = guide[i] * guide[i];
            }
            var mean_i = box_plane(guide, w, h, radius);
            var mean_p = box_plane(src, w, h, radius);
            var mean_ip = box_plane(ip, w, h, radius);
            var mean_ii = box_plane(ii, w, h, radius);
            var a = new float[n];
            var b = new float[n];
            for (int i = 0; i < n; i++) {
                float cov = mean_ip[i] - mean_i[i] * mean_p[i];
                float variance = mean_ii[i] - mean_i[i] * mean_i[i];
                a[i] = cov / (variance + eps);
                b[i] = mean_p[i] - a[i] * mean_i[i];
            }
            var mean_a = box_plane(a, w, h, radius);
            var mean_b = box_plane(b, w, h, radius);
            var q = new float[n];
            for (int i = 0; i < n; i++) q[i] = mean_a[i] * guide[i] + mean_b[i];
            return q;
        }

        public float[] resize_plane(float[] plane, int w, int h, int nw, int nh) {
            var out_plane = new float[(size_t) nw * nh];
            double sx = (double) w / nw, sy = (double) h / nh;
            Parallel.range(nh, (start, end) => {
                for (int y = start; y < end; y++) {
                    double fy = ((y + 0.5) * sy - 0.5).clamp(0, h - 1);
                    int y0 = (int) fy, y1 = int.min(y0 + 1, h - 1);
                    float ty = (float) (fy - y0);
                    for (int x = 0; x < nw; x++) {
                        double fx = ((x + 0.5) * sx - 0.5).clamp(0, w - 1);
                        int x0 = (int) fx, x1 = int.min(x0 + 1, w - 1);
                        float tx = (float) (fx - x0);
                        float top = plane[(size_t) y0 * w + x0] * (1 - tx) + plane[(size_t) y0 * w + x1] * tx;
                        float bottom = plane[(size_t) y1 * w + x0] * (1 - tx) + plane[(size_t) y1 * w + x1] * tx;
                        out_plane[(size_t) y * nw + x] = top * (1 - ty) + bottom * ty;
                    }
                }
            });
            return out_plane;
        }

        public float sample_plane(float[] plane, int w, int h, double x, double y) {
            double fx = (x - 0.5).clamp(0, w - 1), fy = (y - 0.5).clamp(0, h - 1);
            int x0 = (int) fx, y0 = (int) fy;
            int x1 = int.min(x0 + 1, w - 1), y1 = int.min(y0 + 1, h - 1);
            float tx = (float) (fx - x0), ty = (float) (fy - y0);
            float top = plane[(size_t) y0 * w + x0] * (1 - tx) + plane[(size_t) y0 * w + x1] * tx;
            float bottom = plane[(size_t) y1 * w + x0] * (1 - tx) + plane[(size_t) y1 * w + x1] * tx;
            return top * (1 - ty) + bottom * ty;
        }
    }
}
