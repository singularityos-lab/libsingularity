namespace Singularity.Imaging {

    public errordomain IccError {
        INVALID,
        UNSUPPORTED
    }

    public enum RenderingIntent {
        PERCEPTUAL,
        RELATIVE_COLORIMETRIC,
        SATURATION,
        ABSOLUTE_COLORIMETRIC;

        public string label() {
            switch (this) {
                case RELATIVE_COLORIMETRIC: return _("Relative Colorimetric");
                case SATURATION: return _("Saturation");
                case ABSOLUTE_COLORIMETRIC: return _("Absolute Colorimetric");
                default: return _("Perceptual");
            }
        }
    }

    public struct Primaries {
        public double rx;
        public double ry;
        public double gx;
        public double gy;
        public double bx;
        public double by;
        public double wx;
        public double wy;

        public Primaries(double rx, double ry, double gx, double gy, double bx, double by, double wx, double wy) {
            this.rx = rx;
            this.ry = ry;
            this.gx = gx;
            this.gy = gy;
            this.bx = bx;
            this.by = by;
            this.wx = wx;
            this.wy = wy;
        }

        public static Primaries rec709() {
            return Primaries(0.64, 0.33, 0.30, 0.60, 0.15, 0.06, 0.3127, 0.3290);
        }

        public static Primaries rec2020() {
            return Primaries(0.708, 0.292, 0.170, 0.797, 0.131, 0.046, 0.3127, 0.3290);
        }

        public static Primaries display_p3() {
            return Primaries(0.680, 0.320, 0.265, 0.690, 0.150, 0.060, 0.3127, 0.3290);
        }

        public static Primaries adobe_rgb() {
            return Primaries(0.64, 0.33, 0.21, 0.71, 0.15, 0.06, 0.3127, 0.3290);
        }

        public static Primaries prophoto() {
            return Primaries(0.7347, 0.2653, 0.1596, 0.8404, 0.0366, 0.0001, 0.3457, 0.3585);
        }

        public double[] to_xyz() {
            double xr = rx / ry, zr = (1 - rx - ry) / ry;
            double xg = gx / gy, zg = (1 - gx - gy) / gy;
            double xb = bx / by, zb = (1 - bx - by) / by;
            double xw = wx / wy, zw = (1 - wx - wy) / wy;
            double[] m = { xr, xg, xb, 1, 1, 1, zr, zg, zb };
            var inv = Matrix3.invert(m);
            double sr = inv[0] * xw + inv[1] * 1 + inv[2] * zw;
            double sg = inv[3] * xw + inv[4] * 1 + inv[5] * zw;
            double sb = inv[6] * xw + inv[7] * 1 + inv[8] * zw;
            return { sr * xr, sg * xg, sb * xb, sr, sg, sb, sr * zr, sg * zg, sb * zb };
        }

        public static double[] conversion(Primaries from, Primaries to) {
            var a = from.to_xyz();
            var b = Matrix3.invert(to.to_xyz());
            if ((from.wx - to.wx).abs() > 1e-4 || (from.wy - to.wy).abs() > 1e-4) {
                var adapt = Matrix3.bradford(from.wx, from.wy, to.wx, to.wy);
                return Matrix3.multiply(b, Matrix3.multiply(adapt, a));
            }
            return Matrix3.multiply(b, a);
        }
    }

    namespace Matrix3 {

        public double[] identity() {
            return { 1, 0, 0, 0, 1, 0, 0, 0, 1 };
        }

        public double[] multiply(double[] a, double[] b) {
            var r = new double[9];
            for (int i = 0; i < 3; i++)
                for (int j = 0; j < 3; j++)
                    r[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j];
            return r;
        }

        public double determinant(double[] m) {
            return m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6]);
        }

        public double[] invert(double[] m) {
            double det = determinant(m);
            if (det.abs() < 1e-15) return identity();
            double inv = 1.0 / det;
            return {
                (m[4] * m[8] - m[5] * m[7]) * inv, (m[2] * m[7] - m[1] * m[8]) * inv, (m[1] * m[5] - m[2] * m[4]) * inv,
                (m[5] * m[6] - m[3] * m[8]) * inv, (m[0] * m[8] - m[2] * m[6]) * inv, (m[2] * m[3] - m[0] * m[5]) * inv,
                (m[3] * m[7] - m[4] * m[6]) * inv, (m[1] * m[6] - m[0] * m[7]) * inv, (m[0] * m[4] - m[1] * m[3]) * inv
            };
        }

        public void apply(double[] m, ref float r, ref float g, ref float b) {
            float nr = (float) (m[0] * r + m[1] * g + m[2] * b);
            float ng = (float) (m[3] * r + m[4] * g + m[5] * b);
            float nb = (float) (m[6] * r + m[7] * g + m[8] * b);
            r = nr;
            g = ng;
            b = nb;
        }

        public double[] bradford(double swx, double swy, double dwx, double dwy) {
            double[] ma = { 0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296 };
            double sx = swx / swy, sz = (1 - swx - swy) / swy;
            double dx = dwx / dwy, dz = (1 - dwx - dwy) / dwy;
            double[] s = { ma[0] * sx + ma[1] + ma[2] * sz, ma[3] * sx + ma[4] + ma[5] * sz, ma[6] * sx + ma[7] + ma[8] * sz };
            double[] d = { ma[0] * dx + ma[1] + ma[2] * dz, ma[3] * dx + ma[4] + ma[5] * dz, ma[6] * dx + ma[7] + ma[8] * dz };
            double[] scale = { d[0] / s[0], 0, 0, 0, d[1] / s[1], 0, 0, 0, d[2] / s[2] };
            return multiply(invert(ma), multiply(scale, ma));
        }

        public void apply_image(double[] m, FloatImage img) {
            float m0 = (float) m[0], m1 = (float) m[1], m2 = (float) m[2];
            float m3 = (float) m[3], m4 = (float) m[4], m5 = (float) m[5];
            float m6 = (float) m[6], m7 = (float) m[7], m8 = (float) m[8];
            int w = img.width;
            Parallel.range(img.height, (start, end) => {
                for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                    float r = img.data[i * 4], g = img.data[i * 4 + 1], b = img.data[i * 4 + 2];
                    img.data[i * 4] = m0 * r + m1 * g + m2 * b;
                    img.data[i * 4 + 1] = m3 * r + m4 * g + m5 * b;
                    img.data[i * 4 + 2] = m6 * r + m7 * g + m8 * b;
                }
            });
        }
    }

    public class IccProfile : Object {
        private void* handle;
        public string id { get; private set; }
        public string description { get; private set; default = ""; }

        private IccProfile(void* handle, string id) {
            this.handle = handle;
            this.id = id;
            var buffer = new uint8[256];
            uint32 n = Lcms.get_profile_info_ascii(handle, 0, "en", "US", buffer);
            if (n > 0) description = ((string) buffer).strip();
            if (description == "") description = id;
        }

        ~IccProfile() {
            if (handle != null) Lcms.close_profile(handle);
        }

        internal void* get_handle() {
            return handle;
        }

        private static IccProfile rgb(string id, Primaries p, double gamma, bool srgb_curve = false) {
            Lcms.CIExyY white = { p.wx, p.wy, 1.0 };
            Lcms.CIExyYTriple prim = { { p.rx, p.ry, 1.0 }, { p.gx, p.gy, 1.0 }, { p.bx, p.by, 1.0 } };
            void* curve;
            if (srgb_curve) {
                double[] parameters = { 2.4, 1.0 / 1.055, 0.055 / 1.055, 1.0 / 12.92, 0.04045 };
                curve = Lcms.build_parametric_tone_curve(null, 4, parameters);
            } else {
                curve = Lcms.build_gamma(null, gamma);
            }
            void*[] curves = { curve, curve, curve };
            var h = Lcms.create_rgb_profile(white, prim, curves);
            Lcms.free_tone_curve(curve);
            var profile = new IccProfile(h, id);
            return profile;
        }

        public static IccProfile srgb() {
            return new IccProfile(Lcms.create_srgb_profile(), "srgb");
        }

        public static IccProfile linear_srgb() {
            return rgb("linear-srgb", Primaries.rec709(), 1.0);
        }

        public static IccProfile display_p3() {
            return rgb("display-p3", Primaries.display_p3(), 0, true);
        }

        public static IccProfile adobe_rgb() {
            return rgb("adobe-rgb", Primaries.adobe_rgb(), 563.0 / 256.0);
        }

        public static IccProfile prophoto() {
            return rgb("prophoto", Primaries.prophoto(), 1.8);
        }

        public static IccProfile rec2020() {
            return rgb("rec2020", Primaries.rec2020(), 0, true);
        }

        public static IccProfile linear_rec2020() {
            return rgb("linear-rec2020", Primaries.rec2020(), 1.0);
        }

        public static IccProfile lab() {
            return new IccProfile(Lcms.create_lab4_profile(null), "lab");
        }

        public static string[] builtin_ids() {
            return { "srgb", "display-p3", "adobe-rgb", "prophoto", "rec2020", "linear-srgb", "linear-rec2020" };
        }

        public static IccProfile? builtin(string id) {
            switch (id) {
                case "srgb": return srgb();
                case "linear-srgb": return linear_srgb();
                case "display-p3": return display_p3();
                case "adobe-rgb": return adobe_rgb();
                case "prophoto": return prophoto();
                case "rec2020": return rec2020();
                case "linear-rec2020": return linear_rec2020();
                default: return null;
            }
        }

        public static string builtin_label(string id) {
            switch (id) {
                case "srgb": return "sRGB";
                case "linear-srgb": return _("Linear sRGB");
                case "display-p3": return "Display P3";
                case "adobe-rgb": return "Adobe RGB (1998)";
                case "prophoto": return "ProPhoto RGB";
                case "rec2020": return "Rec. 2020";
                case "linear-rec2020": return _("Linear Rec. 2020");
                default: return id;
            }
        }

        public static IccProfile from_data(uint8[] data) throws IccError {
            if (data.length < 128) throw new IccError.INVALID("Profile too short");
            var h = Lcms.open_profile_from_mem(data);
            if (h == null) throw new IccError.INVALID("Not an ICC profile");
            return new IccProfile(h, "icc:" + Checksum.compute_for_data(ChecksumType.MD5, data));
        }

        public static IccProfile from_file(string path) throws Error {
            uint8[] data;
            FileUtils.get_data(path, out data);
            return from_data(data);
        }

        public uint8[] to_data() {
            uint32 size = 0;
            if (!Lcms.save_profile_to_mem(handle, null, ref size) || size == 0) return new uint8[0];
            var buffer = new uint8[size];
            if (!Lcms.save_profile_to_mem(handle, buffer, ref size)) return new uint8[0];
            return buffer;
        }

        public bool is_rgb() {
            return Lcms.get_color_space(handle) == 0x52474220;
        }
    }

    public class ColorTransform : Object {
        private void* handle;
        public IccProfile source { get; construct; }
        public IccProfile target { get; construct; }

        public ColorTransform(IccProfile source, IccProfile target, RenderingIntent intent = RenderingIntent.PERCEPTUAL, bool black_point = true) {
            Object(source: source, target: target);
            uint32 flags = Lcms.FLAGS_NOCACHE | Lcms.FLAGS_COPY_ALPHA;
            if (black_point) flags |= Lcms.FLAGS_BLACKPOINTCOMPENSATION;
            handle = Lcms.create_transform(source.get_handle(), Lcms.TYPE_RGBA_FLT, target.get_handle(), Lcms.TYPE_RGBA_FLT, (uint32) intent, flags);
        }

        public ColorTransform.proofing(IccProfile source, IccProfile target, IccProfile proof, RenderingIntent intent, bool gamut_warning) {
            Object(source: source, target: target);
            uint32 flags = Lcms.FLAGS_NOCACHE | Lcms.FLAGS_COPY_ALPHA | Lcms.FLAGS_SOFTPROOFING | Lcms.FLAGS_BLACKPOINTCOMPENSATION;
            if (gamut_warning) {
                flags |= Lcms.FLAGS_GAMUTCHECK;
                uint16[] alarm = new uint16[16];
                alarm[0] = 0x0000;
                alarm[1] = 0xFFFF;
                alarm[2] = 0xFFFF;
                Lcms.set_alarm_codes(alarm);
            }
            handle = Lcms.create_proofing_transform(source.get_handle(), Lcms.TYPE_RGBA_FLT, target.get_handle(), Lcms.TYPE_RGBA_FLT,
                proof.get_handle(), (uint32) intent, (uint32) RenderingIntent.RELATIVE_COLORIMETRIC, flags);
        }

        ~ColorTransform() {
            if (handle != null) Lcms.delete_transform(handle);
        }

        public bool valid() {
            return handle != null;
        }

        public void apply(FloatImage img) {
            if (handle == null) return;
            int w = img.width;
            Parallel.range(img.height, (start, end) => {
                Lcms.do_transform(handle, &img.data[(size_t) start * w * 4], &img.data[(size_t) start * w * 4], (uint32) ((end - start) * w));
            });
        }

        public void apply_pixels(float[] rgba) {
            if (handle == null) return;
            Lcms.do_transform(handle, rgba, rgba, (uint32) (rgba.length / 4));
        }
    }
}
