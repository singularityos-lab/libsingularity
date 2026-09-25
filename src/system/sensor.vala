using GLib;

namespace Singularity {

    /**
     * What a sensor is measuring.
     *
     * Finer than CPU/GPU/SYSTEM because a modern SoC reports far more than
     * three things, and lumping the rest together makes the list unreadable.
     * MEASURED on CIX Sky1 once SCMI sensors were enabled: 25 readings, of
     * which 17 fell into SYSTEM -- NPU, VPU, two DDR, two SOC, an
     * interconnect, six PCB points, three NVMe and two NICs, all in one capped
     * list where the only way to see the drive was to widen the cap.
     *
     * SYSTEM stays the honest fallback for anything unrecognised; the
     * allow-list doctrine is unchanged, this only widens what can be named.
     */
    public enum SensorKind {
        CPU,
        GPU,
        SYSTEM,
        NPU,
        VPU,
        MEMORY,
        STORAGE,
        NETWORK,
        BOARD
    }

    /**
     * How close a sensor is to the temperature the hardware acts on.
     *
     * Banded by THERMAL MARGIN -- degrees still available before the limit --
     * and not by a fraction of it. A fraction misreads every device whose
     * limit is not near 100 C: an NVMe with an 84 C critical trip would be
     * called warm at 63 C, which is its ordinary idle temperature.
     */
    public enum Severity {
        NORMAL,
        WARM,
        HOT,
        CRITICAL
    }

    /**
     * Turns a temperature plus a limit into a Severity.
     *
     * THE FALLBACK LIMITS ARE LOAD-BEARING, NOT DECORATION. Surveyed across
     * eight fleet machines, the drivers that matter most are precisely the
     * ones that advertise no limit at all: k10temp (Ryzen), scmi (CIX Sky1)
     * and cpu_thermal (Pi and most Arm SoCs) publish tempN_input with no
     * tempN_crit and no critical trip point. Colouring only the sensors that
     * declare a limit would therefore leave the CPU -- the one sensor a user
     * actually watches -- permanently uncoloured on both Arm and AMD.
     */
    /**
     * Room temperature, the floor a heat bar is drawn from. Not a threshold --
     * nothing is judged against it, it only stops idle sensors from all
     * rendering half-full. See SensorReading.heat_fraction.
     */
    public const int AMBIENT_MILLIDEGREES = 20000;

    namespace Thresholds {
        /** Margin at or above which a sensor is unremarkable. */
        public const int NORMAL_MARGIN_MILLIDEGREES = 25000;
        /** Margin at or above which a sensor is warm but not yet notable. */
        public const int WARM_MARGIN_MILLIDEGREES = 12000;

        public int fallback_limit(SensorKind kind) {
            switch (kind) {
                // Tctl on Zen throttles at 95 and Arm SoC critical trips sit
                // at 105, so 100 is the middle of the range the fleet has.
                case SensorKind.CPU: return 100000;
                // NVIDIA slows at 83 and shuts down in the low 90s; the
                // Mali-G720 on Sky1 trips at 95.
                case SensorKind.GPU: return 95000;
                // Accelerators share the die with the GPU and throttle in
                // the same range.
                case SensorKind.NPU:
                case SensorKind.VPU: return 95000;
                // Board, NIC, DRAM, drive and anything unrecognised. DDR5 is
                // already throttling above 85, so the same number serves.
                // Anything with a real limit -- and an NVMe almost always
                // publishes one -- overrides this.
                default: return 85000;
            }
        }

        public Severity classify(int millidegrees, int limit_millidegrees) {
            if (limit_millidegrees <= 0) {
                return Severity.NORMAL;
            }
            int margin = limit_millidegrees - millidegrees;
            if (margin <= 0) {
                return Severity.CRITICAL;
            }
            if (margin < WARM_MARGIN_MILLIDEGREES) {
                return Severity.HOT;
            }
            if (margin < NORMAL_MARGIN_MILLIDEGREES) {
                return Severity.WARM;
            }
            return Severity.NORMAL;
        }
    }

    /** One temperature sensor, as reported by the kernel. */
    public class SensorReading : Object {
        public string label { get; private set; }
        public int millidegrees { get; private set; }
        public SensorKind kind { get; private set; }

        /**
         * Temperature at which the hardware acts, in millidegrees.
         *
         * Taken from the driver when it publishes one and from
         * Thresholds.fallback_limit() when it does not, so it is never zero
         * and a caller can always draw a margin.
         */
        public int limit_millidegrees { get; private set; }

        /**
         * True when the driver published the limit, false when it came from
         * Thresholds.fallback_limit().
         *
         * Needed because a reported limit is worth keeping when two sources
         * describe the same sensor -- see the dedup in refresh_internal().
         */
        public bool limit_is_reported { get; private set; }

        public Severity severity { get; private set; }

        /**
         * True when the driver gave this sensor a name of its own (a hwmon
         * tempN_label), false when all we have is the chip or zone name.
         *
         * Used to break ties between two sources describing the same silicon:
         * a labelled reading is the more specific one. See refresh_internal().
         */
        public bool is_labelled { get; private set; }

        /** Degrees still available before limit_millidegrees. */
        public int margin_millidegrees {
            get { return limit_millidegrees - millidegrees; }
        }

        /**
         * How hot this sensor is, 0.0 to 1.0, for drawing a bar.
         *
         * Spans AMBIENT to the limit rather than 0 C to the limit. Zero is not
         * a meaningful floor for a temperature: a machine sitting in a room is
         * already at 20-ish, so measuring from 0 puts every idle sensor near
         * the middle of its bar and the bars stop distinguishing anything.
         * Measured on O6N, from ambient: CPU_B0 at 49 C against a 100 C limit
         * fills 0.36 while the NVMe at 67.8 C against 85 C fills 0.73, so the
         * one sensor actually worth looking at is the one that reads full --
         * from 0 C those would be 0.49 and 0.80, much closer together.
         *
         * Clamped at both ends: a sensor below ambient reads 0 rather than
         * negative, and one past its limit reads 1 rather than overflowing.
         */
        public double heat_fraction {
            get {
                int span = limit_millidegrees - AMBIENT_MILLIDEGREES;
                if (span <= 0) {
                    return 0.0;
                }
                double f = (double) (millidegrees - AMBIENT_MILLIDEGREES)
                         / (double) span;
                if (f < 0.0) return 0.0;
                if (f > 1.0) return 1.0;
                return f;
            }
        }

        public SensorReading(string label, int millidegrees, SensorKind kind) {
            this.with_limit(label, millidegrees, kind, 0, false);
        }

        /**
         * Extended form carrying a reported thermal limit and/or provenance.
         *
         * A NAMED constructor rather than default arguments on the primary
         * one: Vala default arguments are source-level sugar only -- the
         * generated C constructor takes every listed parameter with no
         * overload, so a client compiled against the old 3-argument
         * SensorReading(label, millidegrees, kind) would still link against
         * a 5-argument symbol and silently pass garbage for the two new
         * parameters instead of failing to build. Keeping the primary
         * constructor's signature frozen and adding this as a second,
         * separately-named entry point avoids that trap entirely.
         */
        public SensorReading.with_limit(string label, int millidegrees, SensorKind kind,
                             int limit_millidegrees, bool is_labelled) {
            this.is_labelled = is_labelled;
            this.label = label;
            this.millidegrees = millidegrees;
            this.kind = kind;
            this.limit_is_reported = limit_millidegrees > 0;
            this.limit_millidegrees = this.limit_is_reported
                ? limit_millidegrees
                : Thresholds.fallback_limit(kind);
            this.severity = Thresholds.classify(millidegrees,
                                                this.limit_millidegrees);
        }
    }

    /** One power rail, in milliwatts. */
    public class PowerReading : Object {
        public string label { get; private set; }
        public int milliwatts { get; private set; }

        public PowerReading(string label, int milliwatts) {
            this.label = label;
            this.milliwatts = milliwatts;
        }
    }

    public enum FanMode {
        UNKNOWN,
        FULL_SPEED,
        MANUAL,
        AUTOMATIC
    }

    /** One fan, as reported by hwmon. */
    public class FanReading : Object {
        public string label { get; private set; }
        public int rpm { get; private set; }
        public string chip { get; private set; default = ""; }
        public string hwmon_path { get; private set; default = ""; }
        public int channel { get; private set; default = 0; }
        public int pwm_channel { get; private set; default = 0; }
        public int pwm { get; private set; default = -1; }
        public int pwm_enable { get; private set; default = -1; }

        public FanMode mode {
            get {
                if (pwm_enable < 0) return FanMode.UNKNOWN;
                if (pwm_enable == 0) return FanMode.FULL_SPEED;
                if (pwm_enable == 1) return FanMode.MANUAL;
                return FanMode.AUTOMATIC;
            }
        }

        public double pwm_fraction {
            get { return pwm < 0 ? -1.0 : ((double) pwm / 255.0).clamp(0.0, 1.0); }
        }

        public FanReading(string label, int rpm) {
            this.label = label;
            this.rpm = rpm;
        }

        public FanReading.with_control(string label, int rpm, string chip,
                                       string hwmon_path, int channel,
                                       int pwm_channel, int pwm, int pwm_enable) {
            this.label = label;
            this.rpm = rpm;
            this.chip = chip;
            this.hwmon_path = hwmon_path;
            this.channel = channel;
            this.pwm_channel = pwm_channel;
            this.pwm = pwm;
            this.pwm_enable = pwm_enable;
        }

        public void read_auto_points(out int[] temps, out int[] pwms) {
            int[] found_temps = {};
            int[] found_pwms = {};
            for (int point = 1; point <= 16 && hwmon_path != "" && pwm_channel > 0; point++) {
                string stem = "%s/pwm%d_auto_point%d".printf(hwmon_path, pwm_channel, point);
                string temp_raw = "";
                string pwm_raw = "";
                try {
                    FileUtils.get_contents(stem + "_temp", out temp_raw);
                    FileUtils.get_contents(stem + "_pwm", out pwm_raw);
                } catch (FileError e) {
                    break;
                }
                found_temps += int.parse(temp_raw.strip());
                found_pwms += int.parse(pwm_raw.strip());
            }
            temps = found_temps;
            pwms = found_pwms;
        }
    }

    /**
     * One cpufreq policy's current clock, with the maximum that policy can
     * reach.
     *
     * The maximum travels WITH the reading because it is not one number per
     * machine. CIX Sky1 exposes five cpufreq policies with five different
     * maxima, so 2.1 GHz is near-idle on one cluster and flat out on another.
     * Normalising against a single machine-wide maximum would paint the
     * little cores as permanently idle.
     */
    public class ClockReading : Object {
        public string label { get; private set; }
        public int khz { get; private set; }
        /** 0 when the policy publishes no maximum. */
        public int max_khz { get; private set; }

        public ClockReading(string label, int khz, int max_khz) {
            this.label = label;
            this.khz = khz;
            this.max_khz = max_khz;
        }

        /** 0.0 to 1.0 of this policy's maximum; -1.0 when unknown. */
        public double fraction {
            get {
                if (max_khz <= 0) {
                    return -1.0;
                }
                double f = (double) khz / (double) max_khz;
                return f > 1.0 ? 1.0 : f;
            }
        }
    }

    /**
     * Reads temperatures, fan speeds and CPU clocks from sysfs.
     *
     * SOURCES. /sys/class/hwmon is primary: it is the generic kernel interface
     * and covers x86 (coretemp, k10temp, zenpower) plus most GPUs (amdgpu,
     * nouveau, i915). /sys/class/thermal is the fallback, because a number of
     * ARM SoCs expose temperatures only there.
     *
     * CLASSIFICATION IS AN ALLOW-LIST, AND THAT IS THE WHOLE POINT.
     * An earlier version treated any unrecognised sensor as a CPU sensor. That
     * is wrong on ordinary hardware, and measurably so -- checked against four
     * machines, every one of them reported something that was not the CPU:
     *
     *   Ryzen 8700G desktop   picked "enp1s0 PHY" 68 C   (a NIC; CPU was 59 C)
     *   Threadripper          picked "enp1s0 PHY" 80 C   (a NIC; CPU was 67 C)
     *   Comet Lake laptop     picked "pch_cometlake" 43 C (chipset; CPU 36 C)
     *   Dell workstation      picked "dell_smm" 85 C     (SMM probe; CPU 47 C)
     *
     * An unknown sensor is therefore SYSTEM, never CPU. `cpu_millidegrees` is
     * -1 unless a sensor was positively identified as a CPU, so a caller can
     * tell "no CPU sensor here" from "the CPU is cold" instead of confidently
     * displaying a network chip as the processor temperature.
     *
     * SoCs whose zone names no generic list can know (CIX Sky1 uses TZB0/TZB1
     * for its big cluster and TZGT for graphics) are handled by cpu_hint and
     * gpu_hint, which a distribution can set without patching this file.
     *
     * NVIDIA. Their driver publishes NO hwmon node -- verified on both the
     * proprietary build (595.58) and the open kernel module (595.71); neither
     * creates one under /sys/class/hwmon or the DRM device. So NVIDIA GPUs are
     * queried through nvidia-smi instead, ASYNCHRONOUSLY and only when the
     * binary is present. Measured cost is 14-16 ms per query on an RTX 4500,
     * i.e. under 1% duty cycle at the default 2 s interval, and the call never
     * blocks the caller's thread. libnvidia-ml is also present on such systems,
     * so this could move to NVML later without a fork; nvidia-smi is chosen
     * first because it needs no new link-time dependency.
     *
     * POWER. Most boards expose no power rail at all (no power*_input,
     * curr*_input or energy*_uj), so no wattage is invented for them and
     * gpu_power_milliwatts stays -1. Where the hardware really does report it
     * -- NVIDIA via nvidia-smi -- it is passed through as measured.
     */
    public class SensorMonitor : Object {
        // Public because start() uses it as a default argument, and Vala requires
        // a default value to be at least as accessible as the method.
        public const int DEFAULT_INTERVAL_SEC = 2;

        private const string HWMON_DIR = "/sys/class/hwmon";
        private const string THERMAL_DIR = "/sys/class/thermal";
        private const string CPUFREQ_DIR = "/sys/devices/system/cpu/cpufreq";
        private const string CPUINFO_PATH = "/proc/cpuinfo";
        private const string DRM_DIR = "/sys/class/drm";
        private const string PROC_DIR = "/proc";

        /**
         * Prefix applied to every path this class reads.
         *
         * Empty in normal use, so the paths are exactly the ones above. Tests
         * point it at a fixture tree instead: the classification rules are the
         * part of this class most likely to be wrong on hardware nobody has to
         * hand, and they are only testable against synthetic sysfs.
         */
        public string sysfs_root { get; set; default = ""; }

        /**
         * Upper bound on a believable temperature, in millidegrees.
         *
         * MEASURED: a fleet host reported 65261850 -- 65261 C -- from a hwmon
         * node. That is a sentinel, not a temperature, and without a ceiling
         * it becomes the hottest sensor on the machine and pins every summary
         * and every colour to itself.
         */
        private const int MAX_PLAUSIBLE_MILLIDEGREES = 150000;

        /**
         * The lower bound stays at "greater than zero": the same survey saw
         * -274000, which is below absolute zero and so unambiguously a
         * sentinel as well.
         */
        private static bool plausible(int millidegrees) {
            return millidegrees > 0
                && millidegrees <= MAX_PLAUSIBLE_MILLIDEGREES;
        }

        /**
         * The temperature this hwmon sensor is acted on at, or 0.
         *
         * tempN_crit first and tempN_max second: _crit is the hard limit,
         * while _max is frequently a soft target the chip sits at under full
         * load. Treating the soft one as critical would report a merely busy
         * CPU as overheating.
         */
        private int hwmon_limit(string base_path, string stem) {
            foreach (string suffix in new string[] { "_crit", "_max" }) {
                string? raw = read_first_line(base_path + "/" + stem + suffix);
                if (raw == null) {
                    continue;
                }
                int value = int.parse(raw);
                if (plausible(value)) {
                    return value;
                }
            }
            return 0;
        }

        /**
         * The lowest critical trip point of a thermal zone, or 0.
         *
         * "critical" is preferred over "hot" because critical is the trip the
         * kernel powers the machine off at, where hot is an intermediate
         * notification. The LOWEST is taken because a zone may publish several
         * and the first one reached is the one that matters.
         */
        private int thermal_limit(string base_path) {
            int best = 0;
            for (int i = 0; i < 16; i++) {
                string? trip_type = read_first_line(
                    "%s/trip_point_%d_type".printf(base_path, i));
                if (trip_type == null || trip_type.strip().down() != "critical") {
                    continue;
                }
                string? raw = read_first_line(
                    "%s/trip_point_%d_temp".printf(base_path, i));
                if (raw == null) {
                    continue;
                }
                int value = int.parse(raw);
                if (plausible(value) && (best == 0 || value < best)) {
                    best = value;
                }
            }
            return best;
        }

        private string hwmon_dir() { return sysfs_root + HWMON_DIR; }
        private string thermal_dir() { return sysfs_root + THERMAL_DIR; }
        private string cpufreq_dir() { return sysfs_root + CPUFREQ_DIR; }
        private string cpuinfo_path() { return sysfs_root + CPUINFO_PATH; }
        private string drm_dir() { return sysfs_root + DRM_DIR; }
        private string proc_dir() { return sysfs_root + PROC_DIR; }

        // Kernel driver names, not product names.
        private const string[] CPU_CHIPS = {
            "coretemp", "k10temp", "zenpower", "x86_pkg_temp",
            "cpu_thermal", "cpu-thermal", "soc_thermal", "soc-thermal",
            // Tegra/Thor-class boards name their zones this way.
            "cpu-therm", "tj-thermal",
            // Bare "cpu" catches the per-core Qualcomm naming (cpu0_0_thermal,
            // cpu1_2_thermal, ...) and anything else that spells it out; a
            // sensor with "cpu" in its name is a CPU sensor in practice.
            // "cluster" is the CPU cluster zone on those same SoCs.
            "cpu", "cluster",
            "armada_thermal", "imx_thermal", "sun4i-ts", "scpi-sensors"
        };
        // hwmon label text that identifies a CPU package or core.
        //
        // Bare "cpu" is here for the same reason it is in CPU_CHIPS: a sensor
        // that spells out CPU is a CPU sensor. It is load-bearing on every
        // Arm SystemReady board, where the identity is in the LABEL and never
        // in the chip name. MEASURED on CIX Sky1: one hwmon chip named
        // scmi_sensors carries all 22 sensors, and the CPU ones are told apart
        // only by their labels CPU_B0, CPU_B1, CPU_M0, CPU_M1. Without this
        // the panel reported cpu=-1 on the SoC this distribution targets.
        private const string[] CPU_LABELS = {
            "package id", "tctl", "tdie", "tccd", "core ", "cpu"
        };
        // hwmon label text that identifies a GPU. Same reasoning: on Sky1 the
        // GPU is scmi_sensors GPU_AVE / GPU_top / GPU_btm.
        private const string[] GPU_LABELS = {
            "gpu"
        };
        /*
         * Labels that name the REGULATOR rather than the die.
         *
         * A desktop Super-I/O chip labels its VRM sensors "CPU VRM" and
         * "GPU VRM". Those contain "cpu" and "gpu" but run hotter than the
         * part they feed, so with hottest-wins they would be reported as the
         * CPU temperature and overstate it. Excluded rather than ranked --
         * ranking would need a notion of which sensor is more authoritative,
         * which sysfs does not provide.
         */
        private const string[] NOT_DIE_LABELS = {
            "vrm", "vrout", "vddq", "ambient"
        };

        /*
         * The rest of what a SoC reports. Matched against chip AND label,
         * because a Sky1 board names these in the label (scmi_sensors NPU,
         * DDR_top, PCB_AMB) while a PC names them in the chip (nvme, r8169).
         *
         * Order matters in classify(): VPU is tested before GPU would be, or
         * a "VPU" label never gets the chance -- and NPU before both, since a
         * neural accelerator is neither.
         */
        private const string[] NPU_NEEDLES = { "npu", "aipu" };
        private const string[] VPU_NEEDLES = { "vpu", "amvx", "venc", "vdec" };
        private const string[] MEMORY_NEEDLES = { "ddr", "dram", "dimm", "lpddr" };
        private const string[] STORAGE_NEEDLES = { "nvme", "drivetemp", "sd_", "ssd" };
        private const string[] NETWORK_NEEDLES = {
            "r8169", "r8125", "mt7921", "iwlwifi", "phy", "eth", "enp", "wlan"
        };
        /*
         * Board-level points: the PCB thermistors, the SoC package zones and
         * the generic ACPI zone. These are the machine, not a component, and
         * grouping them apart keeps them from crowding out a hot drive.
         */
        private const string[] BOARD_NEEDLES = { "pcb", "soc_", "acpitz", "board" };
        private const string[] GPU_CHIPS = {
            "amdgpu", "radeon", "nouveau", "i915", "xe",
            "panfrost", "panthor", "mali", "lima", "v3d", "vc4",
            // Tegra/Thor expose the integrated GPU as a thermal zone.
            "gpu-thermal", "gpu-therm",
            // Bare "gpu" also catches Qualcomm's GPU subsystem zones
            // (gpuss_0_thermal .. gpuss_7_thermal, Adreno). Checked before the
            // CPU list, so "gpuss" cannot be mistaken for a CPU sensor.
            "gpu"
        };

        private const string[] IDLE_FAN_CHIPS = { "thinkpad", "dell_smm", "applesmc" };

        private uint _timer_id = 0;
        private int _interval_sec = DEFAULT_INTERVAL_SEC;
        private SensorReading[] _readings = {};
        // Sysfs-derived readings only, without the NVIDIA set merged in.
        private SensorReading[] _base_readings = {};
        private int[] _clocks_khz = {};
        private ClockReading[] _clocks = {};
        private FanReading[] _fans = {};
        private PowerReading[] _power = {};
        private SensorReading[] _nvidia_readings = {};
        private bool _nvidia_present = false;
        private bool _nvidia_checked = false;
        private bool _nvidia_in_flight = false;
        private double _base_gpu_utilization = -1.0;
        private double _nvidia_gpu_utilization = -1.0;
        private int64 _amd_vram_used = -1;
        private int64 _amd_vram_total = -1;
        private int64 _nvidia_vram_used = -1;
        private int64 _nvidia_vram_total = -1;
        private int64 _drm_resident_bytes = -1;
        private int64 _last_gpu_sample_us = 0;
        private Gee.HashMap<string, uint64?> _drm_counters =
            new Gee.HashMap<string, uint64?>();

        /** Hottest sensor positively identified as a CPU, or -1 if none. */
        public int cpu_millidegrees { get; private set; default = -1; }
        /** Hottest sensor identified as a GPU, or -1 if none. */
        public int gpu_millidegrees { get; private set; default = -1; }
        /** Hottest sensor that is neither, or -1. Use when there is no CPU. */
        public int system_millidegrees { get; private set; default = -1; }
        /** Highest current CPU clock in kHz, or -1 when cpufreq is absent. */
        public int cpu_khz { get; private set; default = -1; }
        /** False when the machine exposes nothing readable. */
        public bool available { get; private set; default = false; }
        /** GPU power draw where the hardware reports it, else -1. */
        public int gpu_power_milliwatts { get; private set; default = -1; }
        /** GPU utilization from 0.0 to 1.0, or -1 when unavailable. */
        public double gpu_utilization { get; private set; default = -1.0; }
        /** Video memory in use across all GPUs, in bytes, or -1 when no driver reports it. */
        public int64 vram_used_bytes { get; private set; default = -1; }
        /** Total video memory across all GPUs, in bytes, or -1 when no driver reports it. */
        public int64 vram_total_bytes { get; private set; default = -1; }

        /**
         * Substring identifying the CPU/GPU sensor on hardware the allow-list
         * cannot know. Empty by default: a distribution sets these, and no
         * single vendor's naming is baked in here.
         */
        public string cpu_hint { get; set; default = ""; }
        public string gpu_hint { get; set; default = ""; }

        public bool gpu_sampling { get; set; default = true; }

        public signal void updated();

        public SensorMonitor() {}

        public void start(int interval_sec = DEFAULT_INTERVAL_SEC) {
            if (_timer_id != 0) return;
            _interval_sec = interval_sec > 0 ? interval_sec : DEFAULT_INTERVAL_SEC;
            refresh();
            _timer_id = Timeout.add_seconds(_interval_sec, () => {
                refresh();
                return Source.CONTINUE;
            });
        }

        public void stop() {
            if (_timer_id != 0) {
                Source.remove(_timer_id);
                _timer_id = 0;
            }
        }

        public override void dispose() {
            stop();
            base.dispose();
        }

        /** Every sensor read on the last refresh, in discovery order. */
        public SensorReading[] readings() {
            return _readings;
        }

        /** Current CPU clocks in kHz, highest first. */
        public int[] clocks_khz() {
            return _clocks_khz;
        }

        /**
         * The same clocks, each carrying the maximum of the cpufreq policy it
         * came from. Ordered to match clocks_khz().
         *
         * Kept alongside clocks_khz() rather than replacing it: a bare kHz
         * list is all a caller printing a number needs, and changing that
         * return type would break every existing one.
         */
        public ClockReading[] clocks() {
            return _clocks;
        }

        /**
         * Fans that are actually turning.
         *
         * Zero-RPM entries are omitted: a board commonly exposes more fan
         * headers than it has fans, and those read 0 forever. MEASURED on an
         * IGX Thor dev kit -- f75308 presents four headers of which two are
         * populated (1342 and 1046 RPM) and two read 0. Listing the empty ones
         * would imply two dead fans. A genuinely stopped fan is therefore also
         * hidden, which is the deliberate trade: an absent fan and an idle one
         * are indistinguishable through this interface.
         */
        public FanReading[] fans() {
            FanReading[] spinning = {};
            foreach (FanReading fan in _fans) {
                if (fan.rpm > 0) spinning += fan;
            }
            return spinning;
        }

        public FanReading[] fan_channels() {
            FanReading[] found = {};
            foreach (FanReading fan in _fans) {
                if (fan.rpm > 0 || matches_any(fan.chip, IDLE_FAN_CHIPS)) found += fan;
            }
            return found;
        }

        /**
         * Power rails the hardware actually measures.
         *
         * Two sources, both real readings rather than estimates:
         *   * hwmon power*_input, a direct figure in microwatts. An AMD GPU
         *     reports its package power this way (measured: amdgpu PPT 59.2 W).
         *   * INA-style shunt monitors, which publish bus voltage and current
         *     per channel but no power field. Volts x amps on the SAME channel
         *     is measurement, not synthesis, and it cross-checks: on an IGX
         *     Thor board channel 1 reads 12.08 V and 140 mA = 1.69 W, which is
         *     exactly what nvidia-smi independently reports for that GPU.
         *
         * DELIBERATELY NOT INCLUDED: Intel RAPL. /sys/class/powercap/.../
         * energy_uj is root-only on current kernels (restricted after the
         * Platypus side-channel work), so a desktop session simply cannot read
         * it -- measured here as an empty value rather than a number. It also
         * reports cumulative energy, so watts would require differencing over
         * time. Nothing is reported rather than guessed.
         */
        public PowerReading[] power_rails() {
            return _power;
        }

        private static string? read_first_line(string path) {
            string contents;
            try {
                if (!FileUtils.get_contents(path, out contents)) {
                    return null;
                }
            } catch (FileError e) {
                return null;
            }
            return contents.strip();
        }

        private static bool matches_any(string text, string[] needles) {
            string lower = text.down();
            foreach (string needle in needles) {
                if (lower.contains(needle)) {
                    return true;
                }
            }
            return false;
        }

        private SensorKind classify(string chip, string? label) {
            string joined = (label != null && label != "")
                ? chip + " " + label
                : chip;

            if (gpu_hint != "" && joined.contains(gpu_hint)) {
                return SensorKind.GPU;
            }
            if (cpu_hint != "" && joined.contains(cpu_hint)) {
                return SensorKind.CPU;
            }
            if (matches_any(chip, GPU_CHIPS)) {
                return SensorKind.GPU;
            }
            if (matches_any(chip, CPU_CHIPS)) {
                return SensorKind.CPU;
            }
            if (label != null && !matches_any(label, NOT_DIE_LABELS)) {
                // GPU before CPU, matching the order of the chip checks.
                if (matches_any(label, GPU_LABELS)) {
                    return SensorKind.GPU;
                }
                if (matches_any(label, CPU_LABELS)) {
                    return SensorKind.CPU;
                }
            }

            // Everything else the SoC reports, matched on chip+label together.
            // NPU first, then VPU: both would otherwise be swallowed by a
            // broader match, and "vpu" must not be read as "gpu".
            if (matches_any(joined, NPU_NEEDLES)) {
                return SensorKind.NPU;
            }
            if (matches_any(joined, VPU_NEEDLES)) {
                return SensorKind.VPU;
            }
            if (matches_any(joined, MEMORY_NEEDLES)) {
                return SensorKind.MEMORY;
            }
            if (matches_any(joined, STORAGE_NEEDLES)) {
                return SensorKind.STORAGE;
            }
            if (matches_any(joined, NETWORK_NEEDLES)) {
                return SensorKind.NETWORK;
            }
            if (matches_any(joined, BOARD_NEEDLES)) {
                return SensorKind.BOARD;
            }
            // Unknown is SYSTEM on purpose. See the class comment.
            return SensorKind.SYSTEM;
        }

        private SensorReading[] collect_hwmon() {
            SensorReading[] found = {};
            Dir dir;
            try {
                dir = Dir.open(hwmon_dir(), 0);
            } catch (FileError e) {
                return found;
            }
            string? node;
            while ((node = dir.read_name()) != null) {
                string base_path = hwmon_dir() + "/" + node;
                string chip = read_first_line(base_path + "/name") ?? node;
                Dir inner;
                try {
                    inner = Dir.open(base_path, 0);
                } catch (FileError e) {
                    continue;
                }
                string? entry;
                while ((entry = inner.read_name()) != null) {
                    if (!entry.has_prefix("temp") || !entry.has_suffix("_input")) {
                        continue;
                    }
                    string? raw = read_first_line(base_path + "/" + entry);
                    if (raw == null) {
                        continue;
                    }
                    int millidegrees = int.parse(raw);
                    if (!plausible(millidegrees)) {
                        continue;
                    }
                    string stem = entry.substring(0, entry.length - "_input".length);
                    string? label = read_first_line(base_path + "/" + stem + "_label");
                    string name = (label != null && label != "")
                        ? "%s %s".printf(chip, label)
                        : chip;
                    found += new SensorReading.with_limit(name, millidegrees,
                                               classify(chip, label),
                                               hwmon_limit(base_path, stem),
                                               label != null && label != "");
                }
            }
            return found;
        }

        private SensorReading[] collect_thermal() {
            SensorReading[] found = {};
            Dir dir;
            try {
                dir = Dir.open(thermal_dir(), 0);
            } catch (FileError e) {
                return found;
            }
            string? node;
            while ((node = dir.read_name()) != null) {
                if (!node.has_prefix("thermal_zone")) {
                    continue;
                }
                string base_path = thermal_dir() + "/" + node;
                string? zone_type = read_first_line(base_path + "/type");
                string? raw = read_first_line(base_path + "/temp");
                if (zone_type == null || raw == null) {
                    continue;
                }
                int millidegrees = int.parse(raw);
                if (!plausible(millidegrees)) {
                    continue;
                }
                found += new SensorReading.with_limit(zone_type, millidegrees,
                                           classify(zone_type, null),
                                           thermal_limit(base_path), false);
            }
            return found;
        }

        private int read_int(string path, int fallback) {
            string? raw = read_first_line(path);
            if (raw == null || raw == "") return fallback;
            int64 value;
            return int64.try_parse(raw, out value) ? (int) value : fallback;
        }

        private FanReading[] collect_fans() {
            FanReading[] found = {};
            Dir dir;
            try {
                dir = Dir.open(hwmon_dir(), 0);
            } catch (FileError e) {
                return found;
            }
            string? node;
            while ((node = dir.read_name()) != null) {
                string base_path = hwmon_dir() + "/" + node;
                string chip = read_first_line(base_path + "/name") ?? node;
                Dir inner;
                try {
                    inner = Dir.open(base_path, 0);
                } catch (FileError e) {
                    continue;
                }
                string? entry;
                while ((entry = inner.read_name()) != null) {
                    if (!entry.has_prefix("fan") || !entry.has_suffix("_input")) {
                        continue;
                    }
                    string? raw = read_first_line(base_path + "/" + entry);
                    if (raw == null) {
                        continue;
                    }
                    int rpm = int.parse(raw);
                    if (rpm < 0) {
                        continue;
                    }
                    string stem = entry.substring(0, entry.length - "_input".length);
                    int channel = int.parse(stem.substring("fan".length));
                    string? label = read_first_line(base_path + "/" + stem + "_label");
                    string name = (label != null && label != "")
                        ? "%s %s".printf(chip, label)
                        : "%s %s".printf(chip, stem);
                    int pwm_channel = channel;
                    if (!FileUtils.test("%s/pwm%d".printf(base_path, channel), FileTest.EXISTS)) {
                        pwm_channel = FileUtils.test(base_path + "/pwm1", FileTest.EXISTS)
                            && !FileUtils.test(base_path + "/pwm2", FileTest.EXISTS) ? 1 : 0;
                    }
                    int pwm = pwm_channel > 0
                        ? read_int("%s/pwm%d".printf(base_path, pwm_channel), -1) : -1;
                    int pwm_enable = pwm_channel > 0
                        ? read_int("%s/pwm%d_enable".printf(base_path, pwm_channel), -1) : -1;
                    found += new FanReading.with_control(name, rpm, chip, base_path,
                                                         channel, pwm_channel, pwm, pwm_enable);
                }
            }
            return found;
        }

        private PowerReading[] collect_power() {
            PowerReading[] found = {};
            Dir dir;
            try {
                dir = Dir.open(hwmon_dir(), 0);
            } catch (FileError e) {
                return found;
            }
            string? node;
            while ((node = dir.read_name()) != null) {
                string base_path = hwmon_dir() + "/" + node;
                string chip = read_first_line(base_path + "/name") ?? node;

                // 1. A direct power reading, in microwatts.
                Dir inner;
                try {
                    inner = Dir.open(base_path, 0);
                } catch (FileError e) {
                    continue;
                }
                // Channels already covered by a direct powerN_input reading.
                // Shunt drivers (INA219/ina2xx) expose BOTH that and inN/currN
                // for one physical rail, so synthesising V x I for such a
                // channel would report the same rail twice under two labels.
                bool[] direct_channel = new bool[9];
                string? entry;
                while ((entry = inner.read_name()) != null) {
                    if (!entry.has_prefix("power") || !entry.has_suffix("_input")) {
                        continue;
                    }
                    string? raw = read_first_line(base_path + "/" + entry);
                    if (raw == null) {
                        continue;
                    }
                    int64 microwatts = int64.parse(raw);
                    if (microwatts <= 0) {
                        continue;
                    }
                    string stem = entry.substring(0, entry.length - "_input".length);
                    int direct_ch = int.parse(stem.substring("power".length));
                    if (direct_ch >= 1 && direct_ch <= 8) {
                        direct_channel[direct_ch] = true;
                    }
                    string? label = read_first_line(base_path + "/" + stem + "_label");
                    string name = (label != null && label != "")
                        ? "%s %s".printf(chip, label)
                        : chip;
                    found += new PowerReading(name, (int) (microwatts / 1000));
                }

                // 2. Shunt monitors: bus volts x channel amps. hwmon numbers
                //    both from 1, so channel N pairs inN_input with currN_input.
                for (int ch = 1; ch <= 8; ch++) {
                    if (direct_channel[ch]) {
                        continue;
                    }
                    string? volt_raw = read_first_line("%s/in%d_input".printf(base_path, ch));
                    string? curr_raw = read_first_line("%s/curr%d_input".printf(base_path, ch));
                    if (volt_raw == null || curr_raw == null) {
                        continue;
                    }
                    int millivolts = int.parse(volt_raw);
                    int milliamps = int.parse(curr_raw);
                    if (millivolts <= 0 || milliamps <= 0) {
                        continue;
                    }
                    string? label = read_first_line("%s/curr%d_label".printf(base_path, ch));
                    string name = (label != null && label != "")
                        ? "%s %s".printf(chip, label)
                        : "%s ch%d".printf(chip, ch);
                    found += new PowerReading(name, (millivolts * milliamps) / 1000);
                }
            }
            return found;
        }

        /**
         * CPU MHz as reported by /proc/cpuinfo.
         *
         * Used when cpufreq yields nothing -- either because the directory is
         * absent (common on virtual machines and on x86 with no scaling driver)
         * or because it exists but is empty / has no readable scaling_cur_freq.
         */
        /**
         * Clocks with no maximum attached: /proc/cpuinfo reports the current
         * MHz and nothing else, so these readings are deliberately built with
         * max_khz 0 and a caller must treat their fraction as unknown rather
         * than inventing a denominator.
         */
        private ClockReading[] clocks_from_cpuinfo() {
            ClockReading[] found = {};
            string? cpuinfo = read_first_line(cpuinfo_path());
            if (cpuinfo == null) {
                return found;
            }
            int index = 0;
            foreach (string line in cpuinfo.split("\n")) {
                if (!line.down().has_prefix("cpu mhz")) {
                    continue;
                }
                string[] parts = line.split(":");
                if (parts.length < 2) {
                    continue;
                }
                int mhz = (int) double.parse(parts[1].strip());
                if (mhz > 0) {
                    found += new ClockReading("cpu%d".printf(index), mhz * 1000, 0);
                    index++;
                }
            }
            return found;
        }

        /**
         * This policy's ceiling, in kHz, or 0.
         *
         * cpuinfo_max_freq is the hardware maximum; scaling_max_freq is what
         * the governor is currently allowed to use and can be lowered at
         * runtime. The hardware number is the honest denominator -- against
         * scaling_max_freq a thermally capped core would read as 100% busy.
         */
        private int policy_max_khz(string policy_path) {
            foreach (string name in new string[] { "cpuinfo_max_freq",
                                                   "scaling_max_freq" }) {
                string? raw = read_first_line(policy_path + "/" + name);
                if (raw == null) {
                    continue;
                }
                int khz = int.parse(raw);
                if (khz > 0) {
                    return khz;
                }
            }
            return 0;
        }

        private ClockReading[] collect_clocks() {
            ClockReading[] found = {};
            Dir dir;
            try {
                dir = Dir.open(cpufreq_dir(), 0);
            } catch (FileError e) {
                return clocks_from_cpuinfo();
            }
            string? node;
            while ((node = dir.read_name()) != null) {
                if (!node.has_prefix("policy")) {
                    continue;
                }
                string policy_path = cpufreq_dir() + "/" + node;
                string? raw = read_first_line(policy_path + "/scaling_cur_freq");
                if (raw == null) {
                    continue;
                }
                int khz = int.parse(raw);
                if (khz > 0) {
                    found += new ClockReading(node, khz, policy_max_khz(policy_path));
                }
            }
            // A present cpufreq directory can still yield nothing: no policy*
            // entries, or policies whose scaling_cur_freq is unreadable. Fall
            // back on the same source as the absent-directory case.
            if (found.length == 0) {
                return clocks_from_cpuinfo();
            }
            return found;
        }

        private double collect_amd_gpu_utilization() {
            double best = -1.0;
            Dir dir;
            try {
                dir = Dir.open(drm_dir(), 0);
            } catch (FileError e) {
                return best;
            }
            string? node;
            while ((node = dir.read_name()) != null) {
                if (!node.has_prefix("card") || node.contains("-")) {
                    continue;
                }
                string? raw = read_first_line(
                    drm_dir() + "/" + node + "/device/gpu_busy_percent");
                if (raw == null) {
                    continue;
                }
                double value = double.parse(raw) / 100.0;
                if (value >= 0.0 && value > best) {
                    best = value.clamp(0.0, 1.0);
                }
            }
            return best;
        }

        private void collect_amd_vram() {
            int64 used = -1;
            int64 total = -1;
            Dir dir;
            try {
                dir = Dir.open(drm_dir(), 0);
            } catch (FileError e) {
                _amd_vram_used = used;
                _amd_vram_total = total;
                return;
            }
            string? node;
            while ((node = dir.read_name()) != null) {
                if (!node.has_prefix("card") || node.contains("-")) {
                    continue;
                }
                string device = drm_dir() + "/" + node + "/device/";
                string? raw_used = read_first_line(device + "mem_info_vram_used");
                string? raw_total = read_first_line(device + "mem_info_vram_total");
                if (raw_used == null || raw_total == null) {
                    continue;
                }
                used = (used < 0 ? 0 : used) + int64.parse(raw_used);
                total = (total < 0 ? 0 : total) + int64.parse(raw_total);
            }
            _amd_vram_used = used;
            _amd_vram_total = total;
        }

        private void update_vram() {
            int64 used = -1;
            int64 total = -1;
            if (_amd_vram_total > 0) {
                used = _amd_vram_used;
                total = _amd_vram_total;
            }
            if (_nvidia_vram_total > 0) {
                used = (used < 0 ? 0 : used) + _nvidia_vram_used;
                total = (total < 0 ? 0 : total) + _nvidia_vram_total;
            }
            if (total < 0 && _drm_resident_bytes >= 0) {
                used = _drm_resident_bytes;
            }
            vram_used_bytes = used;
            vram_total_bytes = total;
        }

        internal static int64 parse_fdinfo_bytes(string value) {
            string[] parts = value.strip().split(" ");
            int64 amount = int64.parse(parts[0]);
            string unit = parts.length > 1 ? parts[parts.length - 1] : "";
            switch (unit) {
                case "KiB": return amount * 1024;
                case "MiB": return amount * 1024 * 1024;
                case "GiB": return amount * 1024 * 1024 * 1024;
                default: return amount;
            }
        }

        private void collect_drm_clients(
            Gee.HashMap<string, uint64?> counters,
            Gee.HashMap<string, uint64?> capacities) {
            var clients = new Gee.HashSet<string>();
            _drm_resident_bytes = -1;
            Dir proc;
            try {
                proc = Dir.open(proc_dir(), 0);
            } catch (FileError e) {
                return;
            }
            string? pid;
            while ((pid = proc.read_name()) != null) {
                if (pid == "" || !pid[0].isdigit()) {
                    continue;
                }
                string fdinfo_path = proc_dir() + "/" + pid + "/fdinfo";
                Dir fdinfo;
                try {
                    fdinfo = Dir.open(fdinfo_path, 0);
                } catch (FileError e) {
                    continue;
                }
                string? fd;
                while ((fd = fdinfo.read_name()) != null) {
                    string contents;
                    try {
                        if (!FileUtils.get_contents(fdinfo_path + "/" + fd,
                                                    out contents)) {
                            continue;
                        }
                    } catch (FileError e) {
                        continue;
                    }

                    string driver = "";
                    string device = "";
                    string client = "";
                    var engines = new Gee.HashMap<string, uint64?>();
                    var engine_capacities = new Gee.HashMap<string, uint64?>();
                    int64 resident = -1;
                    foreach (string line in contents.split("\n")) {
                        int separator = line.index_of(":");
                        if (separator < 0) {
                            continue;
                        }
                        string key = line.substring(0, separator).strip();
                        string value = line.substring(separator + 1).strip();
                        if (key == "drm-driver") {
                            driver = value;
                        } else if (key == "drm-pdev") {
                            device = value;
                        } else if (key == "drm-client-id") {
                            client = value;
                        } else if (key.has_prefix("drm-resident-")) {
                            resident = (resident < 0 ? 0 : resident) + parse_fdinfo_bytes(value);
                        } else if (key.has_prefix("drm-engine-capacity-")) {
                            string engine = key.substring("drm-engine-capacity-".length);
                            engine_capacities[engine] = uint64.parse(value);
                        } else if (key.has_prefix("drm-engine-")) {
                            string engine = key.substring("drm-engine-".length);
                            string[] parts = value.split(" ");
                            engines[engine] = uint64.parse(parts[0]);
                        }
                    }
                    if (driver == "" || client == "") {
                        continue;
                    }
                    string client_key = "%s|%s|%s".printf(driver, device, client);
                    if (clients.contains(client_key)) {
                        continue;
                    }
                    clients.add(client_key);
                    if (resident >= 0) {
                        _drm_resident_bytes = (_drm_resident_bytes < 0 ? 0 : _drm_resident_bytes) + resident;
                    }
                    foreach (var entry in engines.entries) {
                        counters[client_key + "|" + entry.key] = entry.value;
                        string engine_key = device + "|" + entry.key;
                        uint64 capacity = engine_capacities.has_key(entry.key)
                            ? engine_capacities[entry.key] : 1;
                        if (!capacities.has_key(engine_key)
                            || capacity > capacities[engine_key]) {
                            capacities[engine_key] = capacity;
                        }
                    }
                }
            }
        }

        internal void sample_gpu_utilization(int64 now_us) {
            double best = collect_amd_gpu_utilization();
            collect_amd_vram();
            var counters = new Gee.HashMap<string, uint64?>();
            var capacities = new Gee.HashMap<string, uint64?>();
            collect_drm_clients(counters, capacities);
            update_vram();

            if (counters.size > 0) {
                var deltas = new Gee.HashMap<string, uint64?>();
                foreach (var entry in counters.entries) {
                    if (!_drm_counters.has_key(entry.key)) {
                        continue;
                    }
                    uint64 previous = _drm_counters[entry.key];
                    if (entry.value < previous) {
                        continue;
                    }
                    int engine_separator = entry.key.last_index_of("|");
                    string client_key = entry.key.substring(0, engine_separator);
                    int client_separator = client_key.last_index_of("|");
                    string device_key = client_key.substring(0, client_separator);
                    int device_separator = device_key.last_index_of("|");
                    string device = device_key.substring(device_separator + 1);
                    string engine = entry.key.substring(engine_separator + 1);
                    string engine_key = device + "|" + engine;
                    uint64 delta = entry.value - previous;
                    deltas[engine_key] = (deltas.has_key(engine_key)
                        ? deltas[engine_key] : 0) + delta;
                }
                int64 elapsed_us = now_us - _last_gpu_sample_us;
                if (_last_gpu_sample_us > 0 && elapsed_us > 0) {
                    foreach (var entry in deltas.entries) {
                        uint64 capacity = capacities.has_key(entry.key)
                            ? capacities[entry.key] : 1;
                        double value = (double) entry.value
                            / ((double) elapsed_us * 1000.0 * (double) capacity);
                        if (value > best) {
                            best = value.clamp(0.0, 1.0);
                        }
                    }
                } else if (best < 0.0) {
                    best = 0.0;
                }
            }
            _drm_counters = counters;
            _last_gpu_sample_us = now_us;
            _base_gpu_utilization = best;
            gpu_utilization = _base_gpu_utilization > _nvidia_gpu_utilization
                ? _base_gpu_utilization : _nvidia_gpu_utilization;
        }


        /**
         * True when this machine has an NVIDIA driver and nvidia-smi. Checked
         * once: the answer cannot change without a driver reload, and probing
         * every tick would spawn a process just to learn "no".
         */
        private bool nvidia_available() {
            if (_nvidia_checked) {
                return _nvidia_present;
            }
            _nvidia_checked = true;
            // A fixture root describes a machine that is not this one, so the
            // host's NVIDIA stack must not leak into it: nvidia-smi would report
            // real GPUs on a real NVIDIA box and make the fixture's results
            // depend on where the tests happen to run.
            if (sysfs_root != "") {
                _nvidia_present = false;
                return _nvidia_present;
            }
            _nvidia_present = FileUtils.test("/proc/driver/nvidia", FileTest.IS_DIR)
                && Environment.find_program_in_path("nvidia-smi") != null;
            return _nvidia_present;
        }

        internal void parse_nvidia(string? csv) {
            SensorReading[] found = {};
            int power_milliwatts = -1;
            double utilization = -1.0;
            if (csv == null) {
                _nvidia_readings = found;
                gpu_power_milliwatts = -1;
                _nvidia_gpu_utilization = -1.0;
                gpu_utilization = _base_gpu_utilization;
                _nvidia_vram_used = -1;
                _nvidia_vram_total = -1;
                update_vram();
                return;
            }
            int64 vram_used = -1;
            int64 vram_total = -1;
            foreach (string line in csv.split("\n")) {
                if (line.strip() == "") {
                    continue;
                }
                string[] fields = line.split(",");
                if (fields.length >= 7) {
                    int64 used_mib = int64.parse(fields[5].strip());
                    int64 total_mib = int64.parse(fields[6].strip());
                    if (total_mib > 0) {
                        vram_used = (vram_used < 0 ? 0 : vram_used) + used_mib * 1024 * 1024;
                        vram_total = (vram_total < 0 ? 0 : vram_total) + total_mib * 1024 * 1024;
                    }
                }
                if (fields.length < 2) {
                    continue;
                }
                string name = fields[0].strip();
                int celsius = int.parse(fields[1].strip());
                if (fields.length >= 5) {
                    double value = double.parse(fields[4].strip()) / 100.0;
                    if (value >= 0.0 && value > utilization) {
                        utilization = value.clamp(0.0, 1.0);
                    }
                }
                // The same ceiling as sysfs. nvidia-smi also reports the
                // absolute die temperature on every generation here -- do NOT
                // switch this query to temperature.gpu.tlimit, which on Ada is
                // degrees BELOW the throttle point while Turing reports an
                // absolute value, so one field would mean two different things
                // across the fleet.
                if (!plausible(celsius * 1000)) {
                    continue;
                }
                found += new SensorReading.with_limit(name, celsius * 1000, SensorKind.GPU,
                                           0, true);
                if (fields.length >= 4) {
                    // Fields can read "[N/A]" -- an integrated Thor GPU reports
                    // no SM clock. double.parse yields 0 there, which the
                    // guard below discards.
                    double watts = double.parse(fields[3].strip());
                    if (watts > 0.0) {
                        int milliwatts = (int) (watts * 1000.0);
                        if (milliwatts > power_milliwatts) {
                            power_milliwatts = milliwatts;
                        }
                    }
                }
            }
            _nvidia_readings = found;
            gpu_power_milliwatts = power_milliwatts;
            _nvidia_gpu_utilization = utilization;
            _nvidia_vram_used = vram_used;
            _nvidia_vram_total = vram_total;
            update_vram();
            gpu_utilization = _base_gpu_utilization > _nvidia_gpu_utilization
                ? _base_gpu_utilization : _nvidia_gpu_utilization;
        }

        /**
         * Query nvidia-smi off-thread. Spawned via Subprocess.newv rather than a
         * shell, and never waited on: the result lands on a later tick, so a
         * slow or wedged driver cannot stall the UI.
         */
        private void refresh_nvidia() {
            if (!nvidia_available() || _nvidia_in_flight) {
                return;
            }
            string[] argv = {
                "nvidia-smi",
                "--query-gpu=name,temperature.gpu,clocks.sm,power.draw,utilization.gpu,memory.used,memory.total",
                "--format=csv,noheader,nounits"
            };
            try {
                Subprocess proc = new Subprocess.newv(
                    argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
                _nvidia_in_flight = true;
                proc.communicate_utf8_async.begin(null, null, (obj, res) => {
                    string? stdout_text = null;
                    try {
                        proc.communicate_utf8_async.end(res, out stdout_text, null);
                    } catch (Error e) {
                        stdout_text = null;
                    }
                    parse_nvidia(stdout_text);
                    _nvidia_in_flight = false;
                    // Publish what just arrived. Without this a one-shot
                    // refresh() never reports an NVIDIA GPU, and a timer-driven
                    // caller sees it only on the following tick. This merges the
                    // cached sysfs readings rather than calling refresh() again,
                    // so completing a query cannot start another one and does not
                    // re-walk every hwmon and thermal node.
                    publish_state();
                });
            } catch (Error e) {
                // Driver present but the tool failed: stop asking.
                _nvidia_present = false;
                _nvidia_in_flight = false;
            }
        }

        /**
         * Whether two sensor names refer to the same thing.
         *
         * Compared with separators and case removed, because the SAME sensor is
         * routinely spelled differently by the two interfaces. MEASURED on a
         * Raspberry Pi 5: hwmon calls it "cpu_thermal" and the thermal zone
         * calls it "cpu-thermal", so an exact comparison listed one 53 C sensor
         * twice.
         */
        private static bool same_sensor(string a, string b) {
            return a.down().replace("-", "").replace("_", "").replace(" ", "")
                == b.down().replace("-", "").replace("_", "").replace(" ", "");
        }

        public void refresh() {
            refresh_internal(true);
        }

        private void refresh_internal(bool query_nvidia) {
            // BOTH sources, always -- not hwmon-with-thermal-as-fallback.
            // MEASURED on an NVIDIA IGX Thor dev kit: hwmon exists there, but
            // contains only a Super-I/O chip, INA power monitors, the NIC and
            // the NVMe -- no CPU or GPU temperature at all. The CPU and GPU
            // live in /sys/class/thermal as cpu-thermal and gpu-thermal. A
            // "use thermal only when hwmon is empty" rule therefore reported NO
            // CPU on that machine, because hwmon was non-empty but useless.
            // Thermal zones that merely duplicate an hwmon chip are dropped.
            SensorReading[] found = collect_hwmon();
            foreach (SensorReading zone in collect_thermal()) {
                // The two interfaces do not carry the same information.
                // MEASURED on CIX Sky1: hwmon publishes acpitz with no
                // tempN_crit at all, while the identically named thermal zone
                // publishes a 98 C critical trip. Dropping the zone outright
                // therefore threw away the only real limit on the machine and
                // left the sensor on a guess.
                //
                // The scan prefers an entry that still lacks a reported limit,
                // rather than stopping at the first name match. Sky1 presents
                // FOUR sensors all called acpitz and four zones to match; a
                // first-match rule upgraded one of them and left the other
                // three on the fallback, so the same sensor was drawn against
                // two different limits.
                //
                // Among same-label limit-less candidates, the CLOSEST reading
                // by temperature wins, not the first found. hwmon and thermal
                // enumerate independently, so "first" is directory order, not
                // correspondence -- with two acpitz readings at 40C/50C and
                // one 40C zone, a first-match rule could upgrade the 50C entry
                // and leave two 40C readings, hiding the hottest sensor.
                int upgrade_index = -1;
                int best_delta = int.MAX;
                bool duplicate = false;
                for (int i = 0; i < found.length; i++) {
                    if (!same_sensor(found[i].label, zone.label)) {
                        continue;
                    }
                    duplicate = true;
                    if (found[i].limit_is_reported) {
                        continue;
                    }
                    int delta = found[i].millidegrees > zone.millidegrees
                        ? found[i].millidegrees - zone.millidegrees
                        : zone.millidegrees - found[i].millidegrees;
                    if (delta < best_delta) {
                        best_delta = delta;
                        upgrade_index = i;
                    }
                }
                if (upgrade_index >= 0) {
                    found[upgrade_index] = zone;
                } else if (!duplicate) {
                    found += zone;
                }
            }
            // PREFER THE LABELLED SOURCE WHEN TWO DESCRIBE THE SAME SILICON.
            //
            // MEASURED on CIX Sky1 with SCMI sensors enabled: the SoC reports
            // its CPU and GPU twice, once through scmi_sensors with real
            // labels and once as bare ACPI thermal zones, and the pairs are
            // identical to the degree --
            //
            //     TZB0 47.0  ==  scmi_sensors CPU_B0 47.0
            //     TZM0 46.0  ==  scmi_sensors CPU_M0 46.0
            //     TZGT 44.0  ==  scmi_sensors GPU_AVE 44.0
            //
            // -- so the panel drew eight CPU rows for four sensors. Drop the
            // unlabelled twin: a reading the driver bothered to name is the
            // more specific description of the same thing.
            //
            // Deliberately NARROW. It requires the same kind AND the exact
            // same temperature, rather than dropping ACPI zones wholesale,
            // because plenty of unlabelled sensors are genuinely independent
            // -- both r8169 NICs on this board are unlabelled and must
            // survive. The trade is that two distinct same-kind sensors
            // reading identically for one tick will briefly show as one; that
            // is a cosmetic loss, where dropping a real sensor outright is
            // not.
            // CARRY THE LIMIT ACROSS BEFORE DROPPING THE TWIN.
            //
            // The labelled twin is the better NAME, but not necessarily the
            // better LIMIT. On this same Sky1 topology the unlabelled ACPI
            // zone is frequently the only side carrying a real critical trip
            // -- the identical case already noted further up this method,
            // where hwmon acpitz publishes no tempN_crit at all while the
            // matching thermal zone publishes 98 C. Shadowing TZB0 into
            // CPU_B0 without moving that trip over left the survivor on a
            // guessed fallback limit, so margin and severity were computed
            // against the wrong ceiling -- silently, because the row still
            // looked right. Adopt the reported limit first, then drop.
            // Each donor is consumed at most ONCE. Kind plus temperature is
            // not an identity: Sky1 reports several same-kind sensors that
            // can read identically for a tick (the CPU cluster zones sit
            // within a degree of each other), and without a consumed flag a
            // single zone's trip point would be handed to every labelled
            // sensor that happened to match it that tick -- inventing a
            // limit for sensors whose donor was really a different zone.
            // One-to-one keeps an unmatched sensor honestly limit-less
            // instead, which downstream already renders as a fallback rather
            // than as a wrong ceiling.
            bool[] limit_donor_used = new bool[found.length];
            for (int i = 0; i < found.length; i++) {
                if (!found[i].is_labelled || found[i].limit_is_reported) {
                    continue;
                }
                for (int j = 0; j < found.length; j++) {
                    if (limit_donor_used[j]) {
                        continue;
                    }
                    SensorReading twin = found[j];
                    if (twin.is_labelled || !twin.limit_is_reported) {
                        continue;
                    }
                    if (twin.kind == found[i].kind
                        && twin.millidegrees == found[i].millidegrees) {
                        found[i] = new SensorReading.with_limit(found[i].label,
                                                                found[i].millidegrees,
                                                                found[i].kind,
                                                                twin.limit_millidegrees,
                                                                true);
                        limit_donor_used[j] = true;
                        break;
                    }
                }
            }

            SensorReading[] deduped = {};
            foreach (SensorReading candidate in found) {
                bool shadowed = false;
                if (!candidate.is_labelled) {
                    foreach (SensorReading other in found) {
                        if (other.is_labelled
                            && other.kind == candidate.kind
                            && other.millidegrees == candidate.millidegrees) {
                            shadowed = true;
                            break;
                        }
                    }
                }
                if (!shadowed) {
                    deduped += candidate;
                }
            }
            found = deduped;

            // Keep the sysfs-derived set separate from the NVIDIA set: when the
            // async query lands, publish_state() can merge the two again without
            // re-walking every hwmon and thermal node.
            SensorReading[] base_found = found;

            // NVIDIA readings arrive asynchronously, so this merges whatever the
            // last query returned rather than waiting for a fresh one.
            if (query_nvidia && gpu_sampling) {
                refresh_nvidia();
            }
            _base_readings = base_found;

            _fans = collect_fans();
            _power = collect_power();
            if (gpu_sampling) {
                sample_gpu_utilization(GLib.get_monotonic_time());
            }

            ClockReading[] clocks = collect_clocks();
            // Highest first, so a caller can take element 0 as "the" clock.
            // The whole reading is swapped, not the kHz alone: each carries
            // its own policy maximum and separating the two would normalise a
            // big core against a little core's ceiling.
            if (clocks.length > 1) {
                for (int i = 0; i < clocks.length; i++) {
                    for (int j = i + 1; j < clocks.length; j++) {
                        if (clocks[j].khz > clocks[i].khz) {
                            ClockReading swap = clocks[i];
                            clocks[i] = clocks[j];
                            clocks[j] = swap;
                        }
                    }
                }
            }
            _clocks = clocks;
            int[] khz_only = {};
            foreach (ClockReading clock in clocks) {
                khz_only += clock.khz;
            }
            _clocks_khz = khz_only;

            publish_state();
        }

        /**
         * Recompute the published properties from the cached reading sets and
         * emit updated().
         *
         * Split out of refresh_internal() so the asynchronous nvidia-smi
         * callback can publish its result without re-walking every hwmon and
         * thermal node -- it merges _base_readings with the NVIDIA set instead.
         */
        private void publish_state() {
            SensorReading[] found = _base_readings;
            foreach (SensorReading reading in _nvidia_readings) {
                found += reading;
            }
            _readings = found;

            int hottest_cpu = -1;
            int hottest_gpu = -1;
            int hottest_system = -1;
            foreach (SensorReading reading in found) {
                switch (reading.kind) {
                    case SensorKind.CPU:
                        if (reading.millidegrees > hottest_cpu) {
                            hottest_cpu = reading.millidegrees;
                        }
                        break;
                    case SensorKind.GPU:
                        if (reading.millidegrees > hottest_gpu) {
                            hottest_gpu = reading.millidegrees;
                        }
                        break;
                    default:
                        if (reading.millidegrees > hottest_system) {
                            hottest_system = reading.millidegrees;
                        }
                        break;
                }
            }

            cpu_millidegrees = hottest_cpu;
            gpu_millidegrees = hottest_gpu;
            gpu_utilization = _base_gpu_utilization > _nvidia_gpu_utilization
                ? _base_gpu_utilization : _nvidia_gpu_utilization;
            system_millidegrees = hottest_system;
            cpu_khz = _clocks_khz.length > 0 ? _clocks_khz[0] : -1;
            // Any readable category counts. A VM or a restricted-hwmon setup
            // can expose clocks, fans or power rails with no temperature at all;
            // reporting "nothing readable" there would hide real data.
            available = found.length > 0
                || _clocks_khz.length > 0
                || fans().length > 0
                || _power.length > 0
                || gpu_utilization >= 0.0;

            updated();
        }
    }
}
