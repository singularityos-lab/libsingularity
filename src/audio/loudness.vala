namespace Singularity.Audio {

    public class LoudnessMeter : Object {
        private double rate;
        private int channels;
        private Biquad shelf;
        private Biquad highpass;
        private double[] ring;
        private int ring_pos;
        private int ring_fill;
        private int block;
        private int step;
        private int since_step;
        private Gee.ArrayList<double?> blocks = new Gee.ArrayList<double?>();
        private Gee.ArrayList<double?> short_blocks = new Gee.ArrayList<double?>();
        private double[] short_ring;
        private int short_pos;
        private int short_fill;
        private int short_len;
        private double running;
        private double short_running;
        private double peak;
        private float[] history;
        private int history_pos;
        public double momentary { get; private set; default = -160; }
        public double short_term { get; private set; default = -160; }

        public LoudnessMeter(double rate, int channels = 2) {
            this.rate = rate;
            this.channels = channels;
            shelf = new Biquad(channels);
            highpass = new Biquad(channels);
            design_k_weighting();
            block = (int) (rate * 0.4);
            step = (int) (rate * 0.1);
            ring = new double[block];
            short_len = (int) (rate * 3);
            short_ring = new double[short_len];
            history = new float[4 * channels];
        }

        private void design_k_weighting() {
            double f0 = 1681.974450955533;
            double g = 3.999843853973347;
            double q = 0.7071752369554196;
            double k = Math.tan(Math.PI * f0 / rate);
            double vh = Math.pow(10.0, g / 20.0);
            double vb = Math.pow(vh, 0.4996667741545416);
            double a0 = 1.0 + k / q + k * k;
            shelf.b0 = (vh + vb * k / q + k * k) / a0;
            shelf.b1 = 2.0 * (k * k - vh) / a0;
            shelf.b2 = (vh - vb * k / q + k * k) / a0;
            shelf.a1 = 2.0 * (k * k - 1.0) / a0;
            shelf.a2 = (1.0 - k / q + k * k) / a0;
            f0 = 38.13547087602444;
            q = 0.5003270373238773;
            k = Math.tan(Math.PI * f0 / rate);
            a0 = 1.0 + k / q + k * k;
            highpass.b0 = 1.0 / a0 * 1.0;
            highpass.b1 = -2.0 / a0;
            highpass.b2 = 1.0 / a0;
            highpass.a1 = 2.0 * (k * k - 1.0) / a0;
            highpass.a2 = (1.0 - k / q + k * k) / a0;
        }

        private static double to_lufs(double mean_square) {
            return mean_square <= 1e-20 ? -160 : -0.691 + 10 * Math.log10(mean_square);
        }

        public void add(float[] data, int frames) {
            for (int i = 0; i < frames * channels; i++) {
                float v = data[i];
                double a = v.abs();
                if (a > peak) peak = a;
            }
            true_peak_scan(data, frames);
            var filtered = new float[frames * channels];
            Memory.copy(filtered, data, frames * channels * sizeof(float));
            shelf.process(filtered, frames, channels);
            highpass.process(filtered, frames, channels);
            for (int i = 0; i < frames; i++) {
                double sum = 0;
                for (int c = 0; c < channels; c++) {
                    double w = channels > 3 && (c == 4 || c == 5) ? 1.41 : (channels > 3 && c == 3 ? 0 : 1);
                    double s = filtered[i * channels + c];
                    sum += w * s * s;
                }
                running += sum - ring[ring_pos];
                ring[ring_pos] = sum;
                ring_pos = (ring_pos + 1) % block;
                if (ring_fill < block) ring_fill++;
                short_running += sum - short_ring[short_pos];
                short_ring[short_pos] = sum;
                short_pos = (short_pos + 1) % short_len;
                if (short_fill < short_len) short_fill++;
                since_step++;
                if (since_step >= step) {
                    since_step = 0;
                    if (ring_fill == block) {
                        double ms = double.max(0, running) / block;
                        blocks.add(ms);
                        momentary = to_lufs(ms);
                    }
                    if (short_fill == short_len) {
                        double ms = double.max(0, short_running) / short_len;
                        short_term = to_lufs(ms);
                        if (blocks.size % 10 == 0) short_blocks.add(ms);
                    }
                }
            }
        }

        private void true_peak_scan(float[] data, int frames) {
            for (int i = 0; i < frames; i++) {
                for (int c = 0; c < channels; c++) {
                    float x0 = history[((history_pos + 2) % 4) * channels + c];
                    float x1 = history[((history_pos + 3) % 4) * channels + c];
                    float x2 = data[i * channels + c];
                    float xm = history[((history_pos + 1) % 4) * channels + c];
                    for (int p = 1; p < 4; p++) {
                        double t = p / 4.0;
                        double v = x0 + 0.5 * t * (x1 - xm + t * (2 * xm - 5 * x0 + 4 * x1 - x2 + t * (3 * (x0 - x1) + x2 - xm)));
                        if (v.abs() > peak) peak = v.abs();
                    }
                }
                for (int c = 0; c < channels; c++) history[history_pos * channels + c] = data[i * channels + c];
                history_pos = (history_pos + 1) % 4;
            }
        }

        public double true_peak_db {
            get { return gain_to_db(peak); }
        }

        public double integrated {
            get {
                if (blocks.size == 0) return -160;
                double sum = 0;
                int n = 0;
                foreach (var b in blocks) {
                    if (to_lufs(b) > -70) {
                        sum += b;
                        n++;
                    }
                }
                if (n == 0) return -160;
                double relative = to_lufs(sum / n) - 10;
                sum = 0;
                n = 0;
                foreach (var b in blocks) {
                    double l = to_lufs(b);
                    if (l > -70 && l > relative) {
                        sum += b;
                        n++;
                    }
                }
                return n == 0 ? -160 : to_lufs(sum / n);
            }
        }

        public double range {
            get {
                var values = new Gee.ArrayList<double?>();
                double sum = 0;
                int n = 0;
                foreach (var b in short_blocks) {
                    if (to_lufs(b) > -70) {
                        sum += b;
                        n++;
                    }
                }
                if (n == 0) return 0;
                double relative = to_lufs(sum / n) - 20;
                foreach (var b in short_blocks) {
                    double l = to_lufs(b);
                    if (l > -70 && l > relative) values.add(l);
                }
                if (values.size < 2) return 0;
                values.sort((a, b) => a < b ? -1 : (a > b ? 1 : 0));
                double lo = values[(int) ((values.size - 1) * 0.10)];
                double hi = values[(int) ((values.size - 1) * 0.95)];
                return hi - lo;
            }
        }
    }

    public class Ducker : Object {
        public double threshold_db = -36;
        public double amount_db = -15;
        public double attack_ms = 80;
        public double release_ms = 600;
        public double hold_ms = 300;

        public Gee.ArrayList<double?> envelope(float[] voice, int frames, int channels, double rate, int64 step_ns, out int64[] times) {
            var gains = new Gee.ArrayList<double?>();
            int step = int.max(1, (int) (rate * step_ns / 1000000000.0));
            int64[] t = {};
            double gain = 0;
            double hold = 0;
            double att = 1 - Math.exp(-step / (rate * attack_ms / 1000.0));
            double rel = 1 - Math.exp(-step / (rate * release_ms / 1000.0));
            for (int start = 0; start < frames; start += step) {
                double sum = 0;
                int count = 0;
                for (int i = start; i < int.min(frames, start + step); i++) {
                    for (int c = 0; c < channels; c++) {
                        double v = voice[i * channels + c];
                        sum += v * v;
                        count++;
                    }
                }
                double level = gain_to_db(Math.sqrt(sum / int.max(1, count)));
                bool speaking = level > threshold_db;
                if (speaking) hold = hold_ms / 1000.0;
                else hold -= step / rate;
                double target = speaking || hold > 0 ? amount_db : 0;
                gain += (target - gain) * (target < gain ? att : rel);
                gains.add(gain);
                t += (int64) (start / rate * 1000000000.0);
            }
            times = t;
            return gains;
        }
    }
}
