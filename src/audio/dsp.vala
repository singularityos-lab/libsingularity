namespace Singularity.Audio {

    public double db_to_gain(double db) {
        return db <= -144 ? 0 : Math.pow(10, db / 20.0);
    }

    public double gain_to_db(double gain) {
        return gain <= 1e-8 ? -160 : 20 * Math.log10(gain);
    }

    public void pan_gains(double pan, out float left, out float right) {
        double p = (pan.clamp(-1, 1) + 1) * Math.PI / 4;
        left = (float) (Math.cos(p) * Math.SQRT2);
        right = (float) (Math.sin(p) * Math.SQRT2);
        if (left > 1) left = 1;
        if (right > 1) right = 1;
    }

    namespace Fft {
        public void transform(double[] re, double[] im, bool inverse) {
            int n = re.length;
            for (int i = 1, j = 0; i < n; i++) {
                int bit = n >> 1;
                for (; (j & bit) != 0; bit >>= 1) j ^= bit;
                j ^= bit;
                if (i < j) {
                    double t = re[i]; re[i] = re[j]; re[j] = t;
                    t = im[i]; im[i] = im[j]; im[j] = t;
                }
            }
            for (int len = 2; len <= n; len <<= 1) {
                double ang = 2 * Math.PI / len * (inverse ? 1 : -1);
                double wr = Math.cos(ang), wi = Math.sin(ang);
                for (int i = 0; i < n; i += len) {
                    double cr = 1, ci = 0;
                    for (int j = 0; j < len / 2; j++) {
                        int a = i + j, b = i + j + len / 2;
                        double ur = re[a], ui = im[a];
                        double vr = re[b] * cr - im[b] * ci;
                        double vi = re[b] * ci + im[b] * cr;
                        re[a] = ur + vr; im[a] = ui + vi;
                        re[b] = ur - vr; im[b] = ui - vi;
                        double nr = cr * wr - ci * wi;
                        ci = cr * wi + ci * wr;
                        cr = nr;
                    }
                }
            }
            if (inverse) {
                for (int i = 0; i < n; i++) {
                    re[i] /= n;
                    im[i] /= n;
                }
            }
        }
    }

    public enum FilterType {
        PEAK,
        LOW_SHELF,
        HIGH_SHELF,
        LOW_PASS,
        HIGH_PASS,
        BAND_PASS,
        NOTCH;

        public string key() {
            switch (this) {
                case LOW_SHELF: return "low-shelf";
                case HIGH_SHELF: return "high-shelf";
                case LOW_PASS: return "low-pass";
                case HIGH_PASS: return "high-pass";
                case BAND_PASS: return "band-pass";
                case NOTCH: return "notch";
                default: return "peak";
            }
        }

        public static FilterType from_key(string key) {
            switch (key) {
                case "low-shelf": return LOW_SHELF;
                case "high-shelf": return HIGH_SHELF;
                case "low-pass": return LOW_PASS;
                case "high-pass": return HIGH_PASS;
                case "band-pass": return BAND_PASS;
                case "notch": return NOTCH;
                default: return PEAK;
            }
        }
    }

    public class Biquad : Object {
        public double b0 = 1;
        public double b1;
        public double b2;
        public double a1;
        public double a2;
        private double[] z1;
        private double[] z2;

        public Biquad(int channels = 2) {
            z1 = new double[channels];
            z2 = new double[channels];
        }

        public void design(FilterType type, double rate, double freq, double gain_db, double q) {
            double f = freq.clamp(1, rate * 0.49);
            double a = Math.pow(10, gain_db / 40);
            double w0 = 2 * Math.PI * f / rate;
            double cw = Math.cos(w0), sw = Math.sin(w0);
            double alpha = sw / (2 * double.max(q, 0.01));
            double nb0 = 1, nb1 = 0, nb2 = 0, na0 = 1, na1 = 0, na2 = 0;
            switch (type) {
                case FilterType.LOW_PASS:
                    nb0 = (1 - cw) / 2; nb1 = 1 - cw; nb2 = (1 - cw) / 2;
                    na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha;
                    break;
                case FilterType.HIGH_PASS:
                    nb0 = (1 + cw) / 2; nb1 = -(1 + cw); nb2 = (1 + cw) / 2;
                    na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha;
                    break;
                case FilterType.BAND_PASS:
                    nb0 = alpha; nb1 = 0; nb2 = -alpha;
                    na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha;
                    break;
                case FilterType.NOTCH:
                    nb0 = 1; nb1 = -2 * cw; nb2 = 1;
                    na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha;
                    break;
                case FilterType.LOW_SHELF: {
                    double s = 2 * Math.sqrt(a) * alpha;
                    nb0 = a * ((a + 1) - (a - 1) * cw + s);
                    nb1 = 2 * a * ((a - 1) - (a + 1) * cw);
                    nb2 = a * ((a + 1) - (a - 1) * cw - s);
                    na0 = (a + 1) + (a - 1) * cw + s;
                    na1 = -2 * ((a - 1) + (a + 1) * cw);
                    na2 = (a + 1) + (a - 1) * cw - s;
                    break;
                }
                case FilterType.HIGH_SHELF: {
                    double s = 2 * Math.sqrt(a) * alpha;
                    nb0 = a * ((a + 1) + (a - 1) * cw + s);
                    nb1 = -2 * a * ((a - 1) + (a + 1) * cw);
                    nb2 = a * ((a + 1) + (a - 1) * cw - s);
                    na0 = (a + 1) - (a - 1) * cw + s;
                    na1 = 2 * ((a - 1) - (a + 1) * cw);
                    na2 = (a + 1) - (a - 1) * cw - s;
                    break;
                }
                default:
                    nb0 = 1 + alpha * a; nb1 = -2 * cw; nb2 = 1 - alpha * a;
                    na0 = 1 + alpha / a; na1 = -2 * cw; na2 = 1 - alpha / a;
                    break;
            }
            b0 = nb0 / na0; b1 = nb1 / na0; b2 = nb2 / na0;
            a1 = na1 / na0; a2 = na2 / na0;
        }

        public void reset() {
            for (int c = 0; c < z1.length; c++) z1[c] = z2[c] = 0;
        }

        public void process(float[] data, int frames, int channels) {
            int ch = int.min(channels, z1.length);
            for (int c = 0; c < ch; c++) {
                double s1 = z1[c], s2 = z2[c];
                for (int i = 0; i < frames; i++) {
                    int k = i * channels + c;
                    double x = data[k];
                    double y = b0 * x + s1;
                    s1 = b1 * x - a1 * y + s2;
                    s2 = b2 * x - a2 * y;
                    data[k] = (float) y;
                }
                z1[c] = s1; z2[c] = s2;
            }
        }

        public double response_db(double rate, double freq) {
            double w = 2 * Math.PI * freq / rate;
            double cr = Math.cos(w), ci = -Math.sin(w);
            double c2r = Math.cos(2 * w), c2i = -Math.sin(2 * w);
            double nr = b0 + b1 * cr + b2 * c2r, ni = b1 * ci + b2 * c2i;
            double dr = 1 + a1 * cr + a2 * c2r, di = a1 * ci + a2 * c2i;
            double mag = Math.sqrt((nr * nr + ni * ni) / (dr * dr + di * di));
            return gain_to_db(mag);
        }
    }

    public class EqBand : Object {
        public FilterType type;
        public double frequency;
        public double gain_db;
        public double q;
        public bool enabled = true;

        public EqBand(FilterType type, double frequency, double gain_db = 0, double q = 0.707) {
            this.type = type;
            this.frequency = frequency;
            this.gain_db = gain_db;
            this.q = q;
        }
    }

    public class Equalizer : Object {
        public Gee.ArrayList<EqBand> bands = new Gee.ArrayList<EqBand>();
        private Gee.ArrayList<Biquad> filters = new Gee.ArrayList<Biquad>();
        private double rate;
        private int channels;

        public Equalizer(double rate, int channels = 2) {
            this.rate = rate;
            this.channels = channels;
        }

        public void update() {
            while (filters.size < bands.size) filters.add(new Biquad(channels));
            for (int i = 0; i < bands.size; i++) {
                var b = bands[i];
                filters[i].design(b.type, rate, b.frequency, b.gain_db, b.q);
            }
        }

        public void process(float[] data, int frames) {
            for (int i = 0; i < bands.size && i < filters.size; i++) {
                if (bands[i].enabled) filters[i].process(data, frames, channels);
            }
        }

        public double response_db(double freq) {
            double sum = 0;
            for (int i = 0; i < bands.size && i < filters.size; i++) if (bands[i].enabled) sum += filters[i].response_db(rate, freq);
            return sum;
        }
    }

    public class Compressor : Object {
        public double threshold_db = -18;
        public double ratio = 4;
        public double attack_ms = 10;
        public double release_ms = 120;
        public double knee_db = 6;
        public double makeup_db = 0;
        public double reduction_db { get; private set; }
        private double env_db = -160;
        private double rate;
        private int channels;

        public Compressor(double rate, int channels = 2) {
            this.rate = rate;
            this.channels = channels;
        }

        public double static_gain_db(double level_db) {
            double over = level_db - threshold_db;
            double r = double.max(1, ratio);
            if (knee_db > 0 && over.abs() <= knee_db / 2) {
                double x = over + knee_db / 2;
                return (1 / r - 1) * x * x / (2 * knee_db);
            }
            if (over <= 0) return 0;
            return over / r - over;
        }

        public void process(float[] data, int frames) {
            double att = Math.exp(-1.0 / (rate * attack_ms / 1000.0));
            double rel = Math.exp(-1.0 / (rate * release_ms / 1000.0));
            double makeup = makeup_db;
            double max_red = 0;
            for (int i = 0; i < frames; i++) {
                double peak = 0;
                for (int c = 0; c < channels; c++) peak = double.max(peak, data[i * channels + c].abs());
                double level = gain_to_db(peak);
                double target = static_gain_db(level);
                double coef = target < env_db ? att : rel;
                env_db = target + coef * (env_db - target);
                if (env_db > 0) env_db = 0;
                double g = db_to_gain(env_db + makeup);
                max_red = double.min(max_red, env_db);
                for (int c = 0; c < channels; c++) data[i * channels + c] = (float) (data[i * channels + c] * g);
            }
            reduction_db = max_red;
        }

        public void reset() {
            env_db = 0;
        }
    }

    public class Limiter : Object {
        public double ceiling_db = -1;
        public double release_ms = 60;
        private int lookahead;
        private float[] delay;
        private double[] peaks;
        private int pos;
        private double gain = 1;
        private double rate;
        private int channels;

        public Limiter(double rate, int channels = 2, double lookahead_ms = 5) {
            this.rate = rate;
            this.channels = channels;
            lookahead = int.max(1, (int) (rate * lookahead_ms / 1000));
            delay = new float[lookahead * channels];
            peaks = new double[lookahead];
        }

        public int latency {
            get { return lookahead; }
        }

        public void process(float[] data, int frames) {
            double ceiling = db_to_gain(ceiling_db);
            double rel = Math.exp(-1.0 / (rate * release_ms / 1000.0));
            for (int i = 0; i < frames; i++) {
                double peak = 0;
                for (int c = 0; c < channels; c++) peak = double.max(peak, data[i * channels + c].abs());
                peaks[pos] = peak;
                double window = 0;
                foreach (double p in peaks) window = double.max(window, p);
                double target = window > ceiling ? ceiling / window : 1;
                if (target < gain) gain = target;
                else gain = target + rel * (gain - target);
                for (int c = 0; c < channels; c++) {
                    float input = data[i * channels + c];
                    float output = delay[pos * channels + c];
                    delay[pos * channels + c] = input;
                    double v = output * gain;
                    if (v > ceiling) v = ceiling;
                    if (v < -ceiling) v = -ceiling;
                    data[i * channels + c] = (float) v;
                }
                pos = (pos + 1) % lookahead;
            }
        }
    }

    public class NoiseGate : Object {
        public double threshold_db = -50;
        public double range_db = -40;
        public double attack_ms = 2;
        public double release_ms = 150;
        private double gain = 1;
        private double rate;
        private int channels;

        public NoiseGate(double rate, int channels = 2) {
            this.rate = rate;
            this.channels = channels;
        }

        public void process(float[] data, int frames) {
            double att = Math.exp(-1.0 / (rate * attack_ms / 1000.0));
            double rel = Math.exp(-1.0 / (rate * release_ms / 1000.0));
            double floor = db_to_gain(range_db);
            double env = 0;
            for (int i = 0; i < frames; i++) {
                double peak = 0;
                for (int c = 0; c < channels; c++) peak = double.max(peak, data[i * channels + c].abs());
                env = double.max(peak, env * 0.999);
                double target = gain_to_db(env) >= threshold_db ? 1 : floor;
                double coef = target > gain ? att : rel;
                gain = target + coef * (gain - target);
                for (int c = 0; c < channels; c++) data[i * channels + c] = (float) (data[i * channels + c] * gain);
            }
        }
    }

    public class NoiseReduction : Object {
        public const int SIZE = 2048;
        public const int HOP = 512;
        public double reduction_db = 18;
        public double sensitivity = 1.5;
        private double[] profile;
        private bool learned;
        private int channels;
        private double[] window;
        private float[] pending;
        private int pending_frames;
        private double[,] overlap;
        private double[,] input;
        private float[] ready;
        private int ready_start;
        private int ready_frames;
        private double[] floor_estimate;
        private int frames_seen;

        public NoiseReduction(int channels = 2) {
            this.channels = channels;
            profile = new double[SIZE / 2 + 1];
            floor_estimate = new double[SIZE / 2 + 1];
            window = new double[SIZE];
            for (int i = 0; i < SIZE; i++) window[i] = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / SIZE);
            overlap = new double[channels, SIZE];
            input = new double[channels, SIZE];
            pending = new float[HOP * channels];
            ready = new float[HOP * 4 * channels];
            ready_frames = HOP;
        }

        public bool has_profile {
            get { return learned; }
        }

        public int latency {
            get { return SIZE; }
        }

        public void learn(float[] data, int frames) {
            var acc = new double[SIZE / 2 + 1];
            int count = 0;
            var re = new double[SIZE];
            var im = new double[SIZE];
            for (int start = 0; start + SIZE <= frames; start += HOP) {
                for (int c = 0; c < channels; c++) {
                    for (int i = 0; i < SIZE; i++) {
                        re[i] = data[(start + i) * channels + c] * window[i];
                        im[i] = 0;
                    }
                    Fft.transform(re, im, false);
                    for (int k = 0; k <= SIZE / 2; k++) acc[k] += Math.sqrt(re[k] * re[k] + im[k] * im[k]);
                    count++;
                }
            }
            if (count == 0) return;
            for (int k = 0; k <= SIZE / 2; k++) profile[k] = acc[k] / count;
            learned = true;
        }

        public double[] get_profile() {
            return profile;
        }

        public void set_profile(double[] values) {
            if (values.length != profile.length) return;
            for (int k = 0; k < profile.length; k++) profile[k] = values[k];
            learned = true;
        }

        private void push_ready(double[,] src) {
            int capacity = ready.length / channels;
            if (ready_frames + HOP > capacity) {
                var grown = new float[(ready_frames + HOP) * 2 * channels];
                for (int i = 0; i < ready_frames; i++) {
                    int from = ((ready_start + i) % capacity) * channels;
                    for (int c = 0; c < channels; c++) grown[i * channels + c] = ready[from + c];
                }
                ready = grown;
                ready_start = 0;
                capacity = ready.length / channels;
            }
            for (int i = 0; i < HOP; i++) {
                int to = ((ready_start + ready_frames + i) % capacity) * channels;
                for (int c = 0; c < channels; c++) ready[to + c] = (float) src[c, i];
            }
            ready_frames += HOP;
        }

        private void hop() {
            var re = new double[SIZE];
            var im = new double[SIZE];
            double floor_gain = db_to_gain(-reduction_db);
            for (int c = 0; c < channels; c++) {
                for (int i = 0; i < SIZE - HOP; i++) input[c, i] = input[c, i + HOP];
                for (int i = 0; i < HOP; i++) input[c, SIZE - HOP + i] = pending[i * channels + c];
            }
            for (int c = 0; c < channels; c++) {
                for (int i = 0; i < SIZE; i++) {
                    re[i] = input[c, i] * window[i];
                    im[i] = 0;
                }
                Fft.transform(re, im, false);
                if (!learned) {
                    for (int k = 0; k <= SIZE / 2; k++) {
                        double mag = Math.sqrt(re[k] * re[k] + im[k] * im[k]);
                        if (frames_seen == 0 && c == 0) floor_estimate[k] = mag;
                        else if (c == 0) floor_estimate[k] = mag < floor_estimate[k] ? mag : floor_estimate[k] * 1.002 + 1e-9;
                    }
                }
                unowned double[] noise = learned ? profile : floor_estimate;
                for (int k = 0; k <= SIZE / 2; k++) {
                    double mag = Math.sqrt(re[k] * re[k] + im[k] * im[k]);
                    double n = noise[k] * sensitivity;
                    double g = mag > 1e-12 ? double.max(floor_gain, (mag - n) / mag) : floor_gain;
                    re[k] *= g;
                    im[k] *= g;
                    if (k > 0 && k < SIZE / 2) {
                        re[SIZE - k] *= g;
                        im[SIZE - k] *= g;
                    }
                }
                Fft.transform(re, im, true);
                for (int i = 0; i < SIZE; i++) overlap[c, i] += re[i] * window[i] / 1.5;
            }
            frames_seen++;
            push_ready(overlap);
            for (int c = 0; c < channels; c++) {
                for (int i = 0; i < SIZE - HOP; i++) overlap[c, i] = overlap[c, i + HOP];
                for (int i = SIZE - HOP; i < SIZE; i++) overlap[c, i] = 0;
            }
        }

        public void process(float[] data, int frames) {
            int capacity;
            for (int i = 0; i < frames; i++) {
                for (int c = 0; c < channels; c++) pending[pending_frames * channels + c] = data[i * channels + c];
                pending_frames++;
                if (pending_frames == HOP) {
                    hop();
                    pending_frames = 0;
                }
            }
            capacity = ready.length / channels;
            for (int i = 0; i < frames; i++) {
                if (ready_frames == 0) {
                    for (int c = 0; c < channels; c++) data[i * channels + c] = 0;
                    continue;
                }
                int from = ready_start * channels;
                for (int c = 0; c < channels; c++) data[i * channels + c] = ready[from + c];
                ready_start = (ready_start + 1) % capacity;
                ready_frames--;
            }
        }
    }
}
