using Singularity.Keyframes;
using Singularity.Audio;

void check(bool condition, string message) {
    if (!condition) {
        printerr("FAIL: %s\n", message);
        Process.exit(1);
    }
}

void test_keyframes() {
    var v = new AnimatedValue(5);
    check(v.at(100) == 5, "static value");
    v.set_key(0, 0);
    v.set_key(1000, 10);
    check((v.at(500) - 5).abs() < 1e-9, "linear midpoint");
    check(v.at(-10) == 0 && v.at(5000) == 10, "clamped ends");
    v.keys[0].interpolation = Interpolation.HOLD;
    check(v.at(999) == 0, "hold");
    v.keys[0].interpolation = Interpolation.EASE_IN_OUT;
    double mid = v.at(500);
    check((mid - 5).abs() < 1e-6, "ease symmetric midpoint");
    check(v.at(100) < 1.0, "ease in starts slow");
    v.keys[0].interpolation = Interpolation.BEZIER;
    v.keys[0].out_x = 0.5;
    v.keys[0].out_y = 0.9;
    check(v.at(200) > 2, "bezier overshoots linear early");
    var copy = AnimatedValue.from_json(v.to_json());
    check(copy.equals(v) && (copy.at(300) - v.at(300)).abs() < 1e-9, "json round trip");
    v.move_key(1000, 2000);
    check(v.keys[1].time == 2000, "move key");
    var speed = new AnimatedValue(2);
    check((speed.integral(0, 1000000000) - 2e9).abs() < 1, "constant integral");
    speed.set_key(0, 1);
    speed.set_key(1000000000, 3);
    check((speed.integral(0, 1000000000, 1000) - 2e9).abs() < 1e6, "ramp integral");
}

void test_biquad() {
    int rate = 48000;
    var eq = new Equalizer(rate, 1);
    eq.bands.add(new EqBand(FilterType.PEAK, 1000, 6, 1));
    eq.update();
    check((eq.response_db(1000) - 6).abs() < 0.05, "peak gain at centre");
    check(eq.response_db(50).abs() < 0.2, "flat far away");
    var data = new float[rate];
    for (int i = 0; i < rate; i++) data[i] = (float) (0.1 * Math.sin(2 * Math.PI * 1000 * i / rate));
    eq.process(data, rate);
    double rms = 0;
    for (int i = rate / 2; i < rate; i++) rms += data[i] * data[i];
    rms = Math.sqrt(rms / (rate / 2));
    check((gain_to_db(rms / (0.1 / Math.SQRT2)) - 6).abs() < 0.2, "processed gain");
}

void test_dynamics() {
    int rate = 48000;
    var data = new float[rate * 2];
    for (int i = 0; i < rate; i++) {
        float v = (float) Math.sin(2 * Math.PI * 440 * i / rate);
        data[i * 2] = v;
        data[i * 2 + 1] = v;
    }
    var limiter = new Limiter(rate, 2);
    limiter.ceiling_db = -6;
    limiter.process(data, rate);
    float max = 0;
    for (int i = 0; i < rate * 2; i++) max = float.max(max, data[i].abs());
    check(max <= (float) db_to_gain(-6) + 1e-4f, "limiter ceiling");
    var comp = new Compressor(rate, 2);
    comp.threshold_db = -20;
    comp.ratio = 4;
    comp.knee_db = 0;
    check((comp.static_gain_db(0) + 15).abs() < 1e-9, "compressor curve");
}

void test_noise_reduction() {
    int rate = 48000;
    int frames = rate * 2;
    var noise = new float[frames];
    uint seed = 1;
    for (int i = 0; i < frames; i++) {
        seed = seed * 1103515245 + 12345;
        noise[i] = (float) (((seed >> 8) & 0xffff) / 65535.0 - 0.5) * 0.02f;
    }
    var copy = new float[frames];
    for (int i = 0; i < frames; i++) copy[i] = noise[(i * 7) % frames];
    var nr2 = new NoiseReduction(1);
    nr2.learn(noise, frames);
    nr2.process(copy, frames);
    double after = 0;
    for (int i = rate / 2; i < frames; i++) after += copy[i] * copy[i];
    double before_tail = 0;
    for (int i = rate / 2; i < frames; i++) before_tail += noise[(i * 7) % frames] * noise[(i * 7) % frames];
    check(after < before_tail * 0.2, "noise reduced by more than 7 dB");
    var tone = new float[frames];
    for (int i = 0; i < frames; i++) tone[i] = (float) (0.5 * Math.sin(2 * Math.PI * 1000 * i / rate));
    var nr3 = new NoiseReduction(1);
    nr3.learn(noise, frames);
    nr3.process(tone, frames);
    double tone_rms = 0;
    for (int i = rate; i < frames; i++) tone_rms += tone[i] * tone[i];
    tone_rms = Math.sqrt(tone_rms / (frames - rate));
    check((tone_rms - 0.5 / Math.SQRT2).abs() < 0.03, "tone preserved");
    int shift = nr3.latency;
    check((tone[rate] - (float) (0.5 * Math.sin(2 * Math.PI * 1000 * (rate - shift) / rate))).abs() < 0.05, "latency equals window");
}

void test_loudness() {
    int rate = 48000;
    var meter = new LoudnessMeter(rate, 2);
    int frames = rate * 20;
    double amp = db_to_gain(-18.0);
    var data = new float[frames * 2];
    for (int i = 0; i < frames; i++) {
        float v = (float) (amp * Math.sin(2 * Math.PI * 1000 * i / rate));
        data[i * 2] = v;
        data[i * 2 + 1] = v;
    }
    meter.add(data, frames);
    check((meter.integrated + 18.0).abs() < 0.1, "EBU 1 kHz -18 dBFS stereo is -18 LUFS, got %.3f".printf(meter.integrated));
    check((meter.true_peak_db + 18.0).abs() < 0.2, "true peak");
    check(meter.range < 0.5, "constant tone has no range");
}

void test_ducker() {
    int rate = 48000;
    var voice = new float[rate * 4];
    for (int i = rate; i < rate * 2; i++) voice[i] = (float) (0.3 * Math.sin(i * 0.05));
    var ducker = new Ducker();
    int64[] times;
    var gains = ducker.envelope(voice, rate * 4, 1, rate, 100000000, out times);
    check(gains[3] > -1, "no ducking before voice");
    check(gains[18] < -10, "ducked during voice");
    check(gains[39] > -3, "released after voice");
    check(times[10] == 1000000000, "envelope times");
}

int main(string[] args) {
    test_keyframes();
    test_biquad();
    test_dynamics();
    test_noise_reduction();
    test_loudness();
    test_ducker();
    print("media engine tests passed\n");
    return 0;
}
