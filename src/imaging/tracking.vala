namespace Singularity.Imaging {

    namespace Tracking {

        public enum MotionModel {
            TRANSLATION,
            SIMILARITY,
            AFFINE,
            HOMOGRAPHY
        }

        public class Plane : Object {
            public int width { get; private set; }
            public int height { get; private set; }
            public float[] data;

            public Plane(int width, int height) {
                this.width = int.max(1, width);
                this.height = int.max(1, height);
                data = new float[(size_t) this.width * this.height];
            }

            public static Plane from_image(FloatImage img) {
                var p = new Plane(img.width, img.height);
                for (size_t i = 0; i < p.data.length; i++) {
                    float a = img.data[i * 4 + 3];
                    float l = 0.2126f * img.data[i * 4] + 0.7152f * img.data[i * 4 + 1] + 0.0722f * img.data[i * 4 + 2];
                    p.data[i] = Transfer.linear_to_srgb(l.clamp(0, 1));
                }
                return p;
            }

            public float at(int x, int y) {
                return data[(size_t) y.clamp(0, height - 1) * width + x.clamp(0, width - 1)];
            }

            public float sample(double x, double y) {
                double fx = x - 0.5, fy = y - 0.5;
                int x0 = (int) Math.floor(fx), y0 = (int) Math.floor(fy);
                float tx = (float) (fx - x0), ty = (float) (fy - y0);
                float a = at(x0, y0), b = at(x0 + 1, y0), c = at(x0, y0 + 1), d = at(x0 + 1, y0 + 1);
                return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty;
            }

            public Plane half() {
                var blurred = new Plane(width, height);
                Memory.copy(blurred.data, data, data.length * sizeof(float));
                blurred.data = Filters.gaussian_plane(blurred.data, width, height, 1.0);
                var r = new Plane(int.max(1, width / 2), int.max(1, height / 2));
                for (int y = 0; y < r.height; y++)
                    for (int x = 0; x < r.width; x++)
                        r.data[(size_t) y * r.width + x] = (blurred.at(x * 2, y * 2) + blurred.at(x * 2 + 1, y * 2) + blurred.at(x * 2, y * 2 + 1) + blurred.at(x * 2 + 1, y * 2 + 1)) * 0.25f;
                return r;
            }

            public float gradient_magnitude(int x, int y) {
                float gx = at(x + 1, y) - at(x - 1, y);
                float gy = at(x, y + 1) - at(x, y - 1);
                return Math.sqrtf(gx * gx + gy * gy);
            }
        }

        public class Pyramid : Object {
            public Plane[] levels;

            public Pyramid(Plane base_plane, int count = 4) {
                Plane[] l = { base_plane };
                var cur = base_plane;
                for (int i = 1; i < count; i++) {
                    if (cur.width < 16 || cur.height < 16) break;
                    cur = cur.half();
                    l += cur;
                }
                levels = l;
            }

            public static Pyramid from_image(FloatImage img, int count = 4) {
                return new Pyramid(Plane.from_image(img), count);
            }
        }

        public double[] good_features(Plane p, int max_count, double min_distance, double quality = 0.01, double[]? region = null) {
            int w = p.width, h = p.height;
            var score = new float[(size_t) w * h];
            float best = 0;
            int x0 = 2, y0 = 2, x1 = w - 3, y1 = h - 3;
            if (region != null && region.length >= 4) {
                x0 = int.max(2, (int) region[0]);
                y0 = int.max(2, (int) region[1]);
                x1 = int.min(w - 3, (int) (region[0] + region[2]));
                y1 = int.min(h - 3, (int) (region[1] + region[3]));
            }
            for (int y = y0; y <= y1; y++)
                for (int x = x0; x <= x1; x++) {
                    double sxx = 0, syy = 0, sxy = 0;
                    for (int dy = -2; dy <= 2; dy++)
                        for (int dx = -2; dx <= 2; dx++) {
                            float gx = p.at(x + dx + 1, y + dy) - p.at(x + dx - 1, y + dy);
                            float gy = p.at(x + dx, y + dy + 1) - p.at(x + dx, y + dy - 1);
                            sxx += gx * gx;
                            syy += gy * gy;
                            sxy += gx * gy;
                        }
                    double tr = sxx + syy, det = sxx * syy - sxy * sxy;
                    double disc = Math.sqrt(double.max(0, tr * tr / 4 - det));
                    float lmin = (float) (tr / 2 - disc);
                    score[(size_t) y * w + x] = lmin;
                    if (lmin > best) best = lmin;
                }
            if (best <= 0) return {};
            float threshold = (float) (best * quality);
            var candidates = new Gee.ArrayList<int>();
            for (int y = y0; y <= y1; y++)
                for (int x = x0; x <= x1; x++) {
                    float s = score[(size_t) y * w + x];
                    if (s < threshold) continue;
                    bool peak = true;
                    for (int dy = -1; dy <= 1 && peak; dy++)
                        for (int dx = -1; dx <= 1; dx++) {
                            if (dx == 0 && dy == 0) continue;
                            int xx = x + dx, yy = y + dy;
                            if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue;
                            if (score[(size_t) yy * w + xx] > s) {
                                peak = false;
                                break;
                            }
                        }
                    if (peak) candidates.add(y * w + x);
                }
            candidates.sort((a, b) => score[b] > score[a] ? 1 : (score[b] < score[a] ? -1 : 0));
            double[] out_pts = {};
            double md2 = min_distance * min_distance;
            foreach (var c in candidates) {
                double cx = c % w + 0.5, cy = c / w + 0.5;
                bool ok = true;
                for (int i = 0; i < out_pts.length; i += 2) {
                    double dx = out_pts[i] - cx, dy = out_pts[i + 1] - cy;
                    if (dx * dx + dy * dy < md2) {
                        ok = false;
                        break;
                    }
                }
                if (!ok) continue;
                out_pts += cx;
                out_pts += cy;
                if (out_pts.length / 2 >= max_count) break;
            }
            return out_pts;
        }

        public bool lucas_kanade(Pyramid a, Pyramid b, double x, double y, double guess_x, double guess_y, int window, out double nx, out double ny, out double error) {
            int levels = int.min(a.levels.length, b.levels.length);
            double gx = (guess_x - x), gy = (guess_y - y);
            double scale_top = Math.pow(2, levels - 1);
            double dx = gx / scale_top, dy = gy / scale_top;
            nx = guess_x;
            ny = guess_y;
            error = double.MAX;
            int half = int.max(2, window / 2);
            for (int lv = levels - 1; lv >= 0; lv--) {
                var pa = a.levels[lv];
                var pb = b.levels[lv];
                double s = Math.pow(2, lv);
                double px = x / s, py = y / s;
                double gxx = 0, gyy = 0, gxy = 0;
                int n = (2 * half + 1) * (2 * half + 1);
                var ix = new float[n];
                var iy = new float[n];
                var iv = new float[n];
                int k = 0;
                for (int wy = -half; wy <= half; wy++)
                    for (int wx = -half; wx <= half; wx++) {
                        double sx = px + wx, sy = py + wy;
                        float ax = (pa.sample(sx + 1, sy) - pa.sample(sx - 1, sy)) * 0.5f;
                        float ay = (pa.sample(sx, sy + 1) - pa.sample(sx, sy - 1)) * 0.5f;
                        ix[k] = ax;
                        iy[k] = ay;
                        iv[k] = pa.sample(sx, sy);
                        gxx += ax * ax;
                        gyy += ay * ay;
                        gxy += ax * ay;
                        k++;
                    }
                double det = gxx * gyy - gxy * gxy;
                if (det.abs() < 1e-9) {
                    if (lv == 0) return false;
                    dx *= 2;
                    dy *= 2;
                    continue;
                }
                for (int it = 0; it < 20; it++) {
                    double bx = 0, by = 0;
                    k = 0;
                    for (int wy = -half; wy <= half; wy++)
                        for (int wx = -half; wx <= half; wx++) {
                            double diff = iv[k] - pb.sample(px + wx + dx, py + wy + dy);
                            bx += diff * ix[k];
                            by += diff * iy[k];
                            k++;
                        }
                    double ux = (gyy * bx - gxy * by) / det;
                    double uy = (gxx * by - gxy * bx) / det;
                    dx += ux;
                    dy += uy;
                    if (ux * ux + uy * uy < 1e-4) break;
                }
                if (lv > 0) {
                    dx *= 2;
                    dy *= 2;
                }
            }
            nx = x + dx;
            ny = y + dy;
            var p0 = a.levels[0];
            var p1 = b.levels[0];
            if (nx < 0 || ny < 0 || nx >= p1.width || ny >= p1.height) return false;
            double err = 0;
            int cnt = 0;
            for (int wy = -half; wy <= half; wy++)
                for (int wx = -half; wx <= half; wx++) {
                    err += (p0.sample(x + wx, y + wy) - p1.sample(nx + wx, ny + wy)).abs();
                    cnt++;
                }
            error = err / cnt;
            return true;
        }

        public double ncc_match(Plane reference, double cx, double cy, int half_feature, Plane target, double guess_x, double guess_y, int search, out double mx, out double my) {
            int n = (2 * half_feature + 1) * (2 * half_feature + 1);
            var tpl = new float[n];
            double mean = 0;
            int k = 0;
            for (int dy = -half_feature; dy <= half_feature; dy++)
                for (int dx = -half_feature; dx <= half_feature; dx++) {
                    tpl[k] = reference.sample(cx + dx, cy + dy);
                    mean += tpl[k++];
                }
            mean /= n;
            double tvar = 0;
            for (int i = 0; i < n; i++) {
                tpl[i] -= (float) mean;
                tvar += tpl[i] * tpl[i];
            }
            mx = guess_x;
            my = guess_y;
            if (tvar < 1e-9) return 0;
            int range = search;
            var scores = new double[(2 * range + 1) * (2 * range + 1)];
            double best = -2;
            int bi = 0, bj = 0;
            for (int j = -range; j <= range; j++)
                for (int i = -range; i <= range; i++) {
                    double sx = guess_x + i, sy = guess_y + j;
                    double m = 0;
                    for (int dy = -half_feature; dy <= half_feature; dy++)
                        for (int dx = -half_feature; dx <= half_feature; dx++) m += target.sample(sx + dx, sy + dy);
                    m /= n;
                    double num = 0, var2 = 0;
                    k = 0;
                    for (int dy = -half_feature; dy <= half_feature; dy++)
                        for (int dx = -half_feature; dx <= half_feature; dx++) {
                            double v = target.sample(sx + dx, sy + dy) - m;
                            num += v * tpl[k++];
                            var2 += v * v;
                        }
                    double s = var2 < 1e-12 ? -1 : num / Math.sqrt(var2 * tvar);
                    scores[(j + range) * (2 * range + 1) + (i + range)] = s;
                    if (s > best) {
                        best = s;
                        bi = i;
                        bj = j;
                    }
                }
            double ox = 0, oy = 0;
            int stride = 2 * range + 1;
            if (bi > -range && bi < range) {
                double l = scores[(bj + range) * stride + bi + range - 1], c = scores[(bj + range) * stride + bi + range], r = scores[(bj + range) * stride + bi + range + 1];
                double d = l - 2 * c + r;
                if (d.abs() > 1e-12) ox = (0.5 * (l - r) / d).clamp(-0.5, 0.5);
            }
            if (bj > -range && bj < range) {
                double u = scores[(bj + range - 1) * stride + bi + range], c = scores[(bj + range) * stride + bi + range], dn = scores[(bj + range + 1) * stride + bi + range];
                double d = u - 2 * c + dn;
                if (d.abs() > 1e-12) oy = (0.5 * (u - dn) / d).clamp(-0.5, 0.5);
            }
            mx = guess_x + bi + ox;
            my = guess_y + bj + oy;
            return best;
        }

        public double[] identity() {
            return { 1, 0, 0, 0, 1, 0, 0, 0, 1 };
        }

        public double[] multiply(double[] a, double[] b) {
            var r = new double[9];
            for (int i = 0; i < 3; i++)
                for (int j = 0; j < 3; j++) {
                    double s = 0;
                    for (int k = 0; k < 3; k++) s += a[i * 3 + k] * b[k * 3 + j];
                    r[i * 3 + j] = s;
                }
            return r;
        }

        public double[]? invert(double[] m) {
            double det = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6]);
            if (det.abs() < 1e-14) return null;
            return {
                (m[4] * m[8] - m[5] * m[7]) / det, (m[2] * m[7] - m[1] * m[8]) / det, (m[1] * m[5] - m[2] * m[4]) / det,
                (m[5] * m[6] - m[3] * m[8]) / det, (m[0] * m[8] - m[2] * m[6]) / det, (m[2] * m[3] - m[0] * m[5]) / det,
                (m[3] * m[7] - m[4] * m[6]) / det, (m[1] * m[6] - m[0] * m[7]) / det, (m[0] * m[4] - m[1] * m[3]) / det
            };
        }

        public void apply(double[] m, double x, double y, out double ox, out double oy) {
            double w = m[6] * x + m[7] * y + m[8];
            if (w.abs() < 1e-12) w = 1e-12;
            ox = (m[0] * x + m[1] * y + m[2]) / w;
            oy = (m[3] * x + m[4] * y + m[5]) / w;
        }

        private bool solve(double[] a, double[] b, int n, double[] x) {
            var m = new double[n * (n + 1)];
            for (int r = 0; r < n; r++) {
                for (int c = 0; c < n; c++) m[r * (n + 1) + c] = a[r * n + c];
                m[r * (n + 1) + n] = b[r];
            }
            for (int col = 0; col < n; col++) {
                int piv = col;
                for (int r = col + 1; r < n; r++) if (m[r * (n + 1) + col].abs() > m[piv * (n + 1) + col].abs()) piv = r;
                if (m[piv * (n + 1) + col].abs() < 1e-14) return false;
                if (piv != col) {
                    for (int c = 0; c <= n; c++) {
                        double t = m[col * (n + 1) + c];
                        m[col * (n + 1) + c] = m[piv * (n + 1) + c];
                        m[piv * (n + 1) + c] = t;
                    }
                }
                for (int r = 0; r < n; r++) {
                    if (r == col) continue;
                    double f = m[r * (n + 1) + col] / m[col * (n + 1) + col];
                    if (f == 0) continue;
                    for (int c = col; c <= n; c++) m[r * (n + 1) + c] -= f * m[col * (n + 1) + c];
                }
            }
            for (int r = 0; r < n; r++) x[r] = m[r * (n + 1) + n] / m[r * (n + 1) + r];
            return true;
        }

        public double[]? fit(MotionModel motion, double[] src, double[] dst, int[]? subset = null) {
            int n = subset != null ? subset.length : src.length / 2;
            if (n == 0) return null;
            switch (motion) {
                case MotionModel.TRANSLATION: {
                    double tx = 0, ty = 0;
                    for (int k = 0; k < n; k++) {
                        int i = subset != null ? subset[k] : k;
                        tx += dst[i * 2] - src[i * 2];
                        ty += dst[i * 2 + 1] - src[i * 2 + 1];
                    }
                    return { 1, 0, tx / n, 0, 1, ty / n, 0, 0, 1 };
                }
                case MotionModel.SIMILARITY: {
                    if (n < 2) return null;
                    double sx = 0, sy = 0, dx = 0, dy = 0;
                    for (int k = 0; k < n; k++) {
                        int i = subset != null ? subset[k] : k;
                        sx += src[i * 2];
                        sy += src[i * 2 + 1];
                        dx += dst[i * 2];
                        dy += dst[i * 2 + 1];
                    }
                    sx /= n;
                    sy /= n;
                    dx /= n;
                    dy /= n;
                    double a = 0, b = 0, den = 0;
                    for (int k = 0; k < n; k++) {
                        int i = subset != null ? subset[k] : k;
                        double px = src[i * 2] - sx, py = src[i * 2 + 1] - sy;
                        double qx = dst[i * 2] - dx, qy = dst[i * 2 + 1] - dy;
                        a += px * qx + py * qy;
                        b += px * qy - py * qx;
                        den += px * px + py * py;
                    }
                    if (den < 1e-12) return null;
                    a /= den;
                    b /= den;
                    return { a, -b, dx - (a * sx - b * sy), b, a, dy - (b * sx + a * sy), 0, 0, 1 };
                }
                case MotionModel.AFFINE: {
                    if (n < 3) return null;
                    var ata = new double[36];
                    var atb = new double[6];
                    for (int k = 0; k < n; k++) {
                        int i = subset != null ? subset[k] : k;
                        double x = src[i * 2], y = src[i * 2 + 1];
                        double[] r0 = { x, y, 1, 0, 0, 0 };
                        double[] r1 = { 0, 0, 0, x, y, 1 };
                        for (int p = 0; p < 6; p++) {
                            for (int q = 0; q < 6; q++) ata[p * 6 + q] += r0[p] * r0[q] + r1[p] * r1[q];
                            atb[p] += r0[p] * dst[i * 2] + r1[p] * dst[i * 2 + 1];
                        }
                    }
                    var sol = new double[6];
                    if (!solve(ata, atb, 6, sol)) return null;
                    return { sol[0], sol[1], sol[2], sol[3], sol[4], sol[5], 0, 0, 1 };
                }
                default: {
                    if (n < 4) return null;
                    double msx = 0, msy = 0, mdx = 0, mdy = 0;
                    for (int k = 0; k < n; k++) {
                        int i = subset != null ? subset[k] : k;
                        msx += src[i * 2];
                        msy += src[i * 2 + 1];
                        mdx += dst[i * 2];
                        mdy += dst[i * 2 + 1];
                    }
                    msx /= n;
                    msy /= n;
                    mdx /= n;
                    mdy /= n;
                    double ss = 0, ds = 0;
                    for (int k = 0; k < n; k++) {
                        int i = subset != null ? subset[k] : k;
                        ss += Math.hypot(src[i * 2] - msx, src[i * 2 + 1] - msy);
                        ds += Math.hypot(dst[i * 2] - mdx, dst[i * 2 + 1] - mdy);
                    }
                    double fs = ss > 0 ? Math.SQRT2 * n / ss : 1, fd = ds > 0 ? Math.SQRT2 * n / ds : 1;
                    var ata = new double[64];
                    var atb = new double[8];
                    for (int k = 0; k < n; k++) {
                        int i = subset != null ? subset[k] : k;
                        double x = (src[i * 2] - msx) * fs, y = (src[i * 2 + 1] - msy) * fs;
                        double u = (dst[i * 2] - mdx) * fd, v = (dst[i * 2 + 1] - mdy) * fd;
                        double[] r0 = { x, y, 1, 0, 0, 0, -u * x, -u * y };
                        double[] r1 = { 0, 0, 0, x, y, 1, -v * x, -v * y };
                        for (int p = 0; p < 8; p++) {
                            for (int q = 0; q < 8; q++) ata[p * 8 + q] += r0[p] * r0[q] + r1[p] * r1[q];
                            atb[p] += r0[p] * u + r1[p] * v;
                        }
                    }
                    var sol = new double[8];
                    if (!solve(ata, atb, 8, sol)) return null;
                    double[] hn = { sol[0], sol[1], sol[2], sol[3], sol[4], sol[5], sol[6], sol[7], 1 };
                    double[] ts = { fs, 0, -msx * fs, 0, fs, -msy * fs, 0, 0, 1 };
                    double[] td_inv = { 1 / fd, 0, mdx, 0, 1 / fd, mdy, 0, 0, 1 };
                    var hm = multiply(td_inv, multiply(hn, ts));
                    double s = hm[8].abs() > 1e-12 ? hm[8] : 1;
                    for (int i = 0; i < 9; i++) hm[i] /= s;
                    return hm;
                }
            }
        }

        public int minimal_points(MotionModel motion) {
            switch (motion) {
                case MotionModel.TRANSLATION: return 1;
                case MotionModel.SIMILARITY: return 2;
                case MotionModel.AFFINE: return 3;
                default: return 4;
            }
        }

        public double[]? ransac(MotionModel motion, double[] src, double[] dst, double threshold, int iterations, out bool[] inliers, uint32 seed = 7) {
            int n = src.length / 2;
            inliers = new bool[n];
            int need = minimal_points(motion);
            if (n < need) return null;
            var rng = new Rand.with_seed(seed);
            double[]? best = null;
            int best_count = -1;
            double t2 = threshold * threshold;
            for (int it = 0; it < iterations; it++) {
                var subset = new int[need];
                for (int k = 0; k < need; k++) {
                    bool dup = false;
                    do {
                        subset[k] = rng.int_range(0, n);
                        dup = false;
                        for (int q = 0; q < k; q++) if (subset[q] == subset[k]) dup = true;
                    } while (dup && n > need);
                }
                var m = fit(motion, src, dst, subset);
                if (m == null) continue;
                int count = 0;
                for (int i = 0; i < n; i++) {
                    double px, py;
                    apply(m, src[i * 2], src[i * 2 + 1], out px, out py);
                    double ex = px - dst[i * 2], ey = py - dst[i * 2 + 1];
                    if (ex * ex + ey * ey <= t2) count++;
                }
                if (count > best_count) {
                    best_count = count;
                    best = m;
                }
                if (count == n) break;
            }
            if (best == null) return null;
            int[] idx = {};
            for (int i = 0; i < n; i++) {
                double px, py;
                apply(best, src[i * 2], src[i * 2 + 1], out px, out py);
                double ex = px - dst[i * 2], ey = py - dst[i * 2 + 1];
                inliers[i] = ex * ex + ey * ey <= t2;
                if (inliers[i]) idx += i;
            }
            if (idx.length >= need) {
                var refined = fit(motion, src, dst, idx);
                if (refined != null) best = refined;
            }
            return best;
        }

        public double[] smooth(double[] values, double sigma) {
            int n = values.length;
            var r = new double[n];
            if (sigma <= 0.01) {
                for (int i = 0; i < n; i++) r[i] = values[i];
                return r;
            }
            int radius = (int) Math.ceil(sigma * 3);
            for (int i = 0; i < n; i++) {
                double acc = 0, wsum = 0;
                for (int k = -radius; k <= radius; k++) {
                    int j = (i + k).clamp(0, n - 1);
                    double w = Math.exp(-(k * k) / (2 * sigma * sigma));
                    acc += values[j] * w;
                    wsum += w;
                }
                r[i] = acc / wsum;
            }
            return r;
        }

        public void decompose_similarity(double[] m, out double tx, out double ty, out double scale, out double angle) {
            tx = m[2];
            ty = m[5];
            scale = Math.sqrt(m[0] * m[0] + m[3] * m[3]);
            angle = Math.atan2(m[3], m[0]);
        }

        public double[] compose_similarity(double tx, double ty, double scale, double angle) {
            double c = Math.cos(angle) * scale, s = Math.sin(angle) * scale;
            return { c, -s, tx, s, c, ty, 0, 0, 1 };
        }

        public double[] track_features(Pyramid a, Pyramid b, double[] points, int window, double max_error, out bool[] ok) {
            int n = points.length / 2;
            var result = new double[points.length];
            ok = new bool[n];
            for (int i = 0; i < n; i++) {
                double nx, ny, err;
                bool good = lucas_kanade(a, b, points[i * 2], points[i * 2 + 1], points[i * 2], points[i * 2 + 1], window, out nx, out ny, out err);
                if (good && err <= max_error) {
                    double bx, by, berr;
                    bool back = lucas_kanade(b, a, nx, ny, points[i * 2], points[i * 2 + 1], window, out bx, out by, out berr);
                    if (!back || Math.hypot(bx - points[i * 2], by - points[i * 2 + 1]) > 1.0) good = false;
                } else {
                    good = false;
                }
                ok[i] = good;
                result[i * 2] = nx;
                result[i * 2 + 1] = ny;
            }
            return result;
        }

        public double[]? frame_motion(Pyramid a, Pyramid b, MotionModel motion, int max_features = 300, double threshold = 1.5) {
            var feats = good_features(a.levels[0], max_features, 8, 0.01);
            if (feats.length < minimal_points(motion) * 2) return null;
            bool[] ok;
            var moved = track_features(a, b, feats, 15, 0.2, out ok);
            double[] s = {}, d = {};
            for (int i = 0; i < ok.length; i++) {
                if (!ok[i]) continue;
                s += feats[i * 2];
                s += feats[i * 2 + 1];
                d += moved[i * 2];
                d += moved[i * 2 + 1];
            }
            bool[] inl;
            return ransac(motion, s, d, threshold, 300, out inl);
        }
    }
}
