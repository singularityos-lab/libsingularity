namespace Singularity.Imaging {

    public class FloatImage : Object {
        public int width { get; private set; }
        public int height { get; private set; }
        public float[] data;

        public FloatImage(int width, int height) {
            this.width = int.max(1, width);
            this.height = int.max(1, height);
            data = new float[(size_t) this.width * this.height * 4];
        }

        public FloatImage.filled(int width, int height, float r, float g, float b, float a = 1.0f) {
            this(width, height);
            fill(r, g, b, a);
        }

        public FloatImage.from_data(int width, int height, owned float[] rgba) {
            this.width = width;
            this.height = height;
            data = (owned) rgba;
        }

        public void fill(float r, float g, float b, float a = 1.0f) {
            size_t n = (size_t) width * height;
            for (size_t i = 0; i < n; i++) {
                data[i * 4] = r;
                data[i * 4 + 1] = g;
                data[i * 4 + 2] = b;
                data[i * 4 + 3] = a;
            }
        }

        public FloatImage copy() {
            var c = new FloatImage(width, height);
            Memory.copy(c.data, data, data.length * sizeof(float));
            return c;
        }

        public size_t offset(int x, int y) {
            return ((size_t) y * width + x) * 4;
        }

        public size_t pixel_count() {
            return (size_t) width * height;
        }

        public void get_pixel(int x, int y, out float r, out float g, out float b, out float a) {
            size_t i = offset(x.clamp(0, width - 1), y.clamp(0, height - 1));
            r = data[i];
            g = data[i + 1];
            b = data[i + 2];
            a = data[i + 3];
        }

        public void set_pixel(int x, int y, float r, float g, float b, float a = 1.0f) {
            if (x < 0 || y < 0 || x >= width || y >= height) return;
            size_t i = offset(x, y);
            data[i] = r;
            data[i + 1] = g;
            data[i + 2] = b;
            data[i + 3] = a;
        }

        public void sample(double x, double y, out float r, out float g, out float b, out float a) {
            double fx = (x - 0.5).clamp(0.0, width - 1);
            double fy = (y - 0.5).clamp(0.0, height - 1);
            int x0 = (int) fx, y0 = (int) fy;
            int x1 = int.min(x0 + 1, width - 1), y1 = int.min(y0 + 1, height - 1);
            float tx = (float) (fx - x0), ty = (float) (fy - y0);
            size_t i00 = offset(x0, y0), i10 = offset(x1, y0), i01 = offset(x0, y1), i11 = offset(x1, y1);
            float w00 = (1 - tx) * (1 - ty), w10 = tx * (1 - ty), w01 = (1 - tx) * ty, w11 = tx * ty;
            r = data[i00] * w00 + data[i10] * w10 + data[i01] * w01 + data[i11] * w11;
            g = data[i00 + 1] * w00 + data[i10 + 1] * w10 + data[i01 + 1] * w01 + data[i11 + 1] * w11;
            b = data[i00 + 2] * w00 + data[i10 + 2] * w10 + data[i01 + 2] * w01 + data[i11 + 2] * w11;
            a = data[i00 + 3] * w00 + data[i10 + 3] * w10 + data[i01 + 3] * w01 + data[i11 + 3] * w11;
        }

        public FloatImage resized(int w, int h) {
            w = int.max(1, w);
            h = int.max(1, h);
            if (w == width && h == height) return copy();
            var out_img = new FloatImage(w, h);
            double sx = (double) width / w, sy = (double) height / h;
            bool shrink = sx > 1.0 || sy > 1.0;
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < w; x++) {
                        size_t d = out_img.offset(x, y);
                        if (!shrink) {
                            float r, g, b, a;
                            sample((x + 0.5) * sx, (y + 0.5) * sy, out r, out g, out b, out a);
                            out_img.data[d] = r;
                            out_img.data[d + 1] = g;
                            out_img.data[d + 2] = b;
                            out_img.data[d + 3] = a;
                            continue;
                        }
                        int x0 = (int) (x * sx), x1 = int.min(width, int.max(x0 + 1, (int) ((x + 1) * sx)));
                        int y0 = (int) (y * sy), y1 = int.min(height, int.max(y0 + 1, (int) ((y + 1) * sy)));
                        float ar = 0, ag = 0, ab = 0, aa = 0;
                        int n = 0;
                        for (int yy = y0; yy < y1; yy++) {
                            size_t i = offset(x0, yy);
                            for (int xx = x0; xx < x1; xx++) {
                                ar += data[i];
                                ag += data[i + 1];
                                ab += data[i + 2];
                                aa += data[i + 3];
                                i += 4;
                                n++;
                            }
                        }
                        out_img.data[d] = ar / n;
                        out_img.data[d + 1] = ag / n;
                        out_img.data[d + 2] = ab / n;
                        out_img.data[d + 3] = aa / n;
                    }
                }
            });
            return out_img;
        }

        public FloatImage scaled_to_fit(int max_side) {
            if (width <= max_side && height <= max_side) return this;
            double f = (double) max_side / int.max(width, height);
            return resized(int.max(1, (int) Math.round(width * f)), int.max(1, (int) Math.round(height * f)));
        }

        public FloatImage cropped(int x, int y, int w, int h) {
            x = x.clamp(0, width - 1);
            y = y.clamp(0, height - 1);
            w = w.clamp(1, width - x);
            h = h.clamp(1, height - y);
            var out_img = new FloatImage(w, h);
            for (int yy = 0; yy < h; yy++)
                Memory.copy(&out_img.data[out_img.offset(0, yy)], &data[offset(x, y + yy)], (size_t) w * 4 * sizeof(float));
            return out_img;
        }

        public FloatImage rotated_quarter(int turns) {
            int t = ((turns % 4) + 4) % 4;
            if (t == 0) return copy();
            int w = t % 2 == 1 ? height : width, h = t % 2 == 1 ? width : height;
            var out_img = new FloatImage(w, h);
            for (int y = 0; y < height; y++) {
                for (int x = 0; x < width; x++) {
                    int nx, ny;
                    if (t == 1) { nx = height - 1 - y; ny = x; }
                    else if (t == 2) { nx = width - 1 - x; ny = height - 1 - y; }
                    else { nx = y; ny = width - 1 - x; }
                    size_t s = offset(x, y), d = out_img.offset(nx, ny);
                    out_img.data[d] = data[s];
                    out_img.data[d + 1] = data[s + 1];
                    out_img.data[d + 2] = data[s + 2];
                    out_img.data[d + 3] = data[s + 3];
                }
            }
            return out_img;
        }

        public FloatImage flipped_horizontal() {
            var out_img = new FloatImage(width, height);
            for (int y = 0; y < height; y++) {
                for (int x = 0; x < width; x++) {
                    size_t s = offset(x, y), d = out_img.offset(width - 1 - x, y);
                    out_img.data[d] = data[s];
                    out_img.data[d + 1] = data[s + 1];
                    out_img.data[d + 2] = data[s + 2];
                    out_img.data[d + 3] = data[s + 3];
                }
            }
            return out_img;
        }

        public float[] luminance(float kr = 0.2126f, float kg = 0.7152f, float kb = 0.0722f) {
            var plane = new float[pixel_count()];
            size_t n = pixel_count();
            for (size_t i = 0; i < n; i++) plane[i] = data[i * 4] * kr + data[i * 4 + 1] * kg + data[i * 4 + 2] * kb;
            return plane;
        }

        public float[] channel(int c) {
            var plane = new float[pixel_count()];
            size_t n = pixel_count();
            for (size_t i = 0; i < n; i++) plane[i] = data[i * 4 + c];
            return plane;
        }

        public void set_channel(int c, float[] plane) {
            size_t n = pixel_count();
            for (size_t i = 0; i < n; i++) data[i * 4 + c] = plane[i];
        }

        public void paste(FloatImage src, int ox, int oy) {
            for (int y = 0; y < src.height; y++) {
                int ty = y + oy;
                if (ty < 0 || ty >= height) continue;
                for (int x = 0; x < src.width; x++) {
                    int tx = x + ox;
                    if (tx < 0 || tx >= width) continue;
                    size_t s = src.offset(x, y), d = offset(tx, ty);
                    data[d] = src.data[s];
                    data[d + 1] = src.data[s + 1];
                    data[d + 2] = src.data[s + 2];
                    data[d + 3] = src.data[s + 3];
                }
            }
        }

        public bool is_opaque() {
            size_t n = pixel_count();
            for (size_t i = 0; i < n; i++) if (data[i * 4 + 3] < 0.9999f) return false;
            return true;
        }

        public static FloatImage from_rgba8(uint8[] pixels, int width, int height, int stride, bool has_alpha, bool linearize) {
            var img = new FloatImage(width, height);
            unowned float[] table = Transfer.srgb_decode_table();
            int channels = has_alpha ? 4 : 3;
            Parallel.range(height, (start, end) => {
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < width; x++) {
                        int s = y * stride + x * channels;
                        size_t d = img.offset(x, y);
                        for (int c = 0; c < 3; c++) img.data[d + c] = linearize ? table[pixels[s + c]] : pixels[s + c] / 255.0f;
                        img.data[d + 3] = has_alpha ? pixels[s + 3] / 255.0f : 1.0f;
                    }
                }
            });
            return img;
        }

        public static FloatImage from_rgba16(uint16[] pixels, int width, int height, int channels, bool linearize) {
            var img = new FloatImage(width, height);
            Parallel.range(height, (start, end) => {
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < width; x++) {
                        size_t s = ((size_t) y * width + x) * channels;
                        size_t d = img.offset(x, y);
                        for (int c = 0; c < 3; c++) {
                            float v = pixels[s + int.min(c, channels - 1)] / 65535.0f;
                            img.data[d + c] = linearize ? Transfer.srgb_to_linear(v) : v;
                        }
                        img.data[d + 3] = channels == 4 || channels == 2 ? pixels[s + channels - 1] / 65535.0f : 1.0f;
                    }
                }
            });
            return img;
        }

        public uint8[] to_rgba8(bool encode) {
            var out_px = new uint8[pixel_count() * 4];
            Parallel.range(height, (start, end) => {
                for (size_t i = (size_t) start * width; i < (size_t) end * width; i++) {
                    for (int c = 0; c < 3; c++) {
                        float v = data[i * 4 + c];
                        out_px[i * 4 + c] = encode ? Transfer.encode_byte(v) : (uint8) (v.clamp(0.0f, 1.0f) * 255.0f + 0.5f);
                    }
                    out_px[i * 4 + 3] = (uint8) (data[i * 4 + 3].clamp(0.0f, 1.0f) * 255.0f + 0.5f);
                }
            });
            return out_px;
        }

        public uint16[] to_rgba16(bool encode) {
            var out_px = new uint16[pixel_count() * 4];
            Parallel.range(height, (start, end) => {
                for (size_t i = (size_t) start * width; i < (size_t) end * width; i++) {
                    for (int c = 0; c < 3; c++) {
                        float v = data[i * 4 + c];
                        out_px[i * 4 + c] = encode ? Transfer.encode_word(v) : (uint16) (v.clamp(0.0f, 1.0f) * 65535.0f + 0.5f);
                    }
                    out_px[i * 4 + 3] = (uint16) (data[i * 4 + 3].clamp(0.0f, 1.0f) * 65535.0f + 0.5f);
                }
            });
            return out_px;
        }

        public static FloatImage from_texture(Gdk.Texture texture, bool linearize) {
            var downloader = new Gdk.TextureDownloader(texture);
            downloader.set_format(Gdk.MemoryFormat.R32G32B32A32_FLOAT);
            size_t stride;
            var bytes = downloader.download_bytes(out stride);
            int w = texture.get_width(), h = texture.get_height();
            var img = new FloatImage(w, h);
            unowned uint8[] raw = bytes.get_data();
            for (int y = 0; y < h; y++)
                Memory.copy(&img.data[img.offset(0, y)], &raw[y * stride], (size_t) w * 4 * sizeof(float));
            if (linearize) {
                Parallel.range(h, (start, end) => {
                    for (size_t i = (size_t) start * w; i < (size_t) end * w; i++)
                        for (int c = 0; c < 3; c++) img.data[i * 4 + c] = Transfer.srgb_to_linear(img.data[i * 4 + c]);
                });
            }
            return img;
        }

        public Gdk.Texture to_texture(bool encode) {
            var bytes = new Bytes.take(to_rgba8(encode));
            return new Gdk.MemoryTexture(width, height, Gdk.MemoryFormat.R8G8B8A8, bytes, width * 4);
        }

        public Gdk.Texture to_texture16(bool encode) {
            var words = to_rgba16(encode);
            unowned uint8[] raw = (uint8[]) words;
            raw.length = words.length * 2;
            var bytes = new Bytes(raw);
            return new Gdk.MemoryTexture(width, height, Gdk.MemoryFormat.R16G16B16A16, bytes, width * 8);
        }
    }
}
