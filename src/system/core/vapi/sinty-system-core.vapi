[CCode (cheader_filename = "sinty-system/v1.h", lower_case_cprefix = "sinty_")]
namespace SintySystem {
    public void system_version (out uint32 major, out uint32 minor);

    [CCode (cname = "SintyProcess", has_type_id = false, destroy_function = "")]
    public struct Process {
        public int32 pid;
        public int32 ppid;
        public uint32 uid;
        public uint8 state;
        public int32 nice;
        public uint32 threads;
        public uint64 rss_bytes;
        public uint64 vsize_bytes;
        public uint64 utime_ticks;
        public uint64 stime_ticks;
        public uint64 start_ticks;
        public char name[64];
        [CCode (array_length = false)]
        public unowned char* cmdline;
    }

    [Compact]
    [CCode (cname = "SintyProcessList", free_function = "sinty_proc_list_free")]
    public class ProcessList {
        [CCode (cname = "sinty_proc_list_count")]
        public size_t count ();
        [CCode (cname = "sinty_proc_list_at")]
        public unowned Process? at (size_t index);
    }

    [CCode (cname = "sinty_proc_list")]
    public int proc_list (out ProcessList list);
    [CCode (cname = "sinty_proc_get")]
    public int proc_get (int32 pid, out Process process);
    [CCode (cname = "sinty_proc_signal")]
    public int proc_signal (int32 pid, int32 sig);
    [CCode (cname = "sinty_proc_get_nice")]
    public int proc_get_nice (int32 pid, out int32 nice);
    [CCode (cname = "sinty_proc_set_nice")]
    public int proc_set_nice (int32 pid, int32 nice);
    [CCode (cname = "sinty_proc_set_io_priority")]
    public int proc_set_io_priority (int32 pid, uint32 io_class, uint32 level);
    [CCode (cname = "sinty_proc_get_io_priority")]
    public int proc_get_io_priority (int32 pid, out uint32 io_class, out uint32 level);

    [CCode (cname = "int", cprefix = "SINTY_PROC_SOCKETS_", has_type_id = false)]
    [Flags]
    public enum SocketFlags {
        TCP,
        UDP
    }

    [CCode (cname = "SintySocket", has_type_id = false, destroy_function = "")]
    public struct Socket {
        public uint8 family;
        public uint8 protocol;
        public uint8 state;
        public uint16 local_port;
        public uint16 remote_port;
        public char local[46];
        public char remote[46];
        public uint32 uid;
        public int32 pid;
        public uint64 inode;
        public uint64 bytes_sent;
        public uint64 bytes_received;
        public uint64 bytes_acked;
    }

    [Compact]
    [CCode (cname = "SintySocketList", free_function = "sinty_proc_socket_list_free")]
    public class SocketList {
        [CCode (cname = "sinty_proc_socket_list_count")]
        public size_t count ();
        [CCode (cname = "sinty_proc_socket_list_at")]
        public unowned Socket? at (size_t index);
    }

    [CCode (cname = "sinty_proc_sockets")]
    public int proc_sockets (SocketFlags flags, out SocketList list);

    [CCode (cname = "SintySensorKind", cprefix = "SINTY_SENSOR_", has_type_id = false)]
    public enum SensorKind {
        TEMPERATURE,
        FAN,
        VOLTAGE,
        POWER,
        CURRENT,
        ENERGY,
        HUMIDITY
    }

    [CCode (cname = "SintySensorReading", has_type_id = false, destroy_function = "")]
    public struct SensorReading {
        public uint32 kind;
        public uint8 has_max;
        public uint8 has_crit;
        public uint8 has_min;
        public int64 value;
        public int64 min;
        public int64 max;
        public int64 crit;
        public char chip[64];
        public char label[64];
        public char device[128];
    }

    [Compact]
    [CCode (cname = "SintySensorList", free_function = "sinty_sensors_list_free")]
    public class SensorList {
        [CCode (cname = "sinty_sensors_list_count")]
        public size_t count ();
        [CCode (cname = "sinty_sensors_list_at")]
        public unowned SensorReading? at (size_t index);
    }

    [CCode (cname = "SINTY_SENSORS_THERMAL_ZONES")]
    public const uint32 SENSORS_THERMAL_ZONES;
    [CCode (cname = "sinty_sensors_list")]
    public int sensors_list (uint32 flags, out SensorList list);
    [CCode (cname = "sinty_sysctl_get")]
    public int sysctl_get (string name, [CCode (array_length_type = "size_t")] char[] buffer);
    [CCode (cname = "sinty_sysctl_set")]
    public int sysctl_set (string name, string value);

    [CCode (cname = "SintySupplyType", cprefix = "SINTY_SUPPLY_", has_type_id = false)]
    public enum SupplyType {
        UNKNOWN,
        BATTERY,
        MAINS,
        USB,
        UPS,
        WIRELESS
    }

    [CCode (cname = "SintySupplyStatus", cprefix = "SINTY_SUPPLY_STATUS_", has_type_id = false)]
    public enum SupplyStatus {
        UNKNOWN,
        CHARGING,
        DISCHARGING,
        NOT_CHARGING,
        FULL
    }

    [CCode (cname = "SintyPowerSupply", has_type_id = false, destroy_function = "")]
    public struct PowerSupply {
        public uint32 kind;
        public uint32 status;
        public int32 online;
        public int32 present;
        public int32 capacity;
        public int32 device_scope;
        public int32 cycle_count;
        public int32 charge_start_threshold;
        public int32 charge_end_threshold;
        public int64 energy_now;
        public int64 energy_full;
        public int64 energy_full_design;
        public int64 power_now;
        public int64 voltage_now;
        public int64 time_to_empty;
        public int64 time_to_full;
        public char name[64];
        public char model[64];
        public char manufacturer[64];
        public char technology[32];
        public char serial[64];
    }

    [Compact]
    [CCode (cname = "SintyPowerSupplyList", free_function = "sinty_power_supply_list_free")]
    public class PowerSupplyList {
        [CCode (cname = "sinty_power_supply_list_count")]
        public size_t count ();
        [CCode (cname = "sinty_power_supply_list_at")]
        public unowned PowerSupply? at (size_t index);
    }

    [CCode (cname = "sinty_power_supplies")]
    public int power_supplies (out PowerSupplyList list);
    [CCode (cname = "sinty_power_set_charge_thresholds")]
    public int power_set_charge_thresholds (string name, int32 start, int32 end);
    [CCode (cname = "sinty_power_profile")]
    public int power_profile ([CCode (array_length_type = "size_t")] char[] current, [CCode (array_length_type = "size_t")] char[] choices);
    [CCode (cname = "sinty_power_set_profile")]
    public int power_set_profile (string profile);

    [CCode (cname = "SintyCpuPolicy", has_type_id = false, destroy_function = "")]
    public struct CpuPolicy {
        public int32 id;
        public int32 online;
        public int64 cur_khz;
        public int64 min_khz;
        public int64 max_khz;
        public int64 hw_min_khz;
        public int64 hw_max_khz;
        public char governor[32];
        public char governors[128];
        public char epp[32];
        public char epps[160];
        public char driver[32];
        public char cpus[64];
    }

    [Compact]
    [CCode (cname = "SintyCpuPolicyList", free_function = "sinty_power_cpu_policy_list_free")]
    public class CpuPolicyList {
        [CCode (cname = "sinty_power_cpu_policy_list_count")]
        public size_t count ();
        [CCode (cname = "sinty_power_cpu_policy_list_at")]
        public unowned CpuPolicy? at (size_t index);
    }

    [CCode (cname = "sinty_power_cpu_policies")]
    public int power_cpu_policies (out CpuPolicyList list);
    [CCode (cname = "sinty_power_set_governor")]
    public int power_set_governor (string governor);
    [CCode (cname = "sinty_power_set_energy_preference")]
    public int power_set_energy_preference (string preference);

    [CCode (cname = "SintyBacklightType", cprefix = "SINTY_BACKLIGHT_", has_type_id = false)]
    public enum BacklightType {
        UNKNOWN,
        FIRMWARE,
        PLATFORM,
        RAW
    }

    [CCode (cname = "SintyBacklight", has_type_id = false, destroy_function = "")]
    public struct Backlight {
        public uint32 kind;
        public int64 brightness;
        public int64 max_brightness;
        public int64 actual_brightness;
        public char name[64];
        public char connector[64];
    }

    [Compact]
    [CCode (cname = "SintyBacklightList", free_function = "sinty_display_backlight_list_free")]
    public class BacklightList {
        [CCode (cname = "sinty_display_backlight_list_count")]
        public size_t count ();
        [CCode (cname = "sinty_display_backlight_list_at")]
        public unowned Backlight? at (size_t index);
    }

    [CCode (cname = "sinty_display_backlights")]
    public int display_backlights (out BacklightList list);
    [CCode (cname = "sinty_display_set_backlight")]
    public int display_set_backlight (string name, int64 value);

    [CCode (cname = "SintyDdcDisplay", has_type_id = false, destroy_function = "")]
    public struct DdcDisplay {
        public uint32 bus;
        public char connector[64];
    }

    [Compact]
    [CCode (cname = "SintyDdcList", free_function = "sinty_display_ddc_list_free")]
    public class DdcList {
        [CCode (cname = "sinty_display_ddc_list_count")]
        public size_t count ();
        [CCode (cname = "sinty_display_ddc_list_at")]
        public unowned DdcDisplay? at (size_t index);
    }

    [CCode (cname = "SINTY_VCP_BRIGHTNESS")]
    public const uint8 VCP_BRIGHTNESS;
    [CCode (cname = "SINTY_VCP_CONTRAST")]
    public const uint8 VCP_CONTRAST;
    [CCode (cname = "sinty_display_ddc_list")]
    public int display_ddc_list (out DdcList list);
    [CCode (cname = "sinty_display_ddc_get")]
    public int display_ddc_get (uint32 bus, uint8 vcp, out uint16 current, out uint16 maximum);
    [CCode (cname = "sinty_display_ddc_set")]
    public int display_ddc_set (uint32 bus, uint8 vcp, uint16 value);

    [CCode (cname = "SintyDeviceNames", has_type_id = false, destroy_function = "")]
    public struct DeviceNames {
        public char vendor[128];
        public char model[128];
    }

    [CCode (cname = "sinty_device_hwdb_get")]
    public int device_hwdb_get (string modalias, string key, [CCode (array_length_type = "size_t")] char[] buffer);
    [CCode (cname = "sinty_device_names")]
    public int device_names (string syspath, out DeviceNames names);
    [CCode (cname = "sinty_device_uevent_get")]
    public int device_uevent_get (string syspath, string key, [CCode (array_length_type = "size_t")] char[] buffer);

    [CCode (cname = "SintyLinkInfo", has_type_id = false, destroy_function = "")]
    public struct LinkInfo {
        public int32 speed_mbps;
        public int32 max_supported_mbps;
        public int32 duplex;
        public int32 autoneg;
        public int32 port;
        public uint32 supported[32];
        public uint32 words;
    }

    [CCode (cname = "sinty_net_link_info")]
    public int net_link_info (string iface, out LinkInfo info);

    [Compact]
    [CCode (cname = "SintyTextList", free_function = "sinty_text_list_free")]
    public class TextList {
        [CCode (cname = "sinty_text_list_count")]
        public size_t count ();
        [CCode (cname = "sinty_text_list_at")]
        public unowned string? at (size_t index);
    }

    [CCode (cname = "sinty_i18n_installed_locales")]
    public int i18n_installed_locales (out TextList list);

    [CCode (cname = "SintyNvidiaGpu", has_type_id = false, destroy_function = "")]
    public struct NvidiaGpu {
        public int32 temperature_c;
        public int32 sm_clock_mhz;
        public int32 power_mw;
        public int32 utilization_pct;
        public int64 memory_used;
        public int64 memory_total;
        public char name[96];
    }

    [Compact]
    [CCode (cname = "SintyNvidiaList", free_function = "sinty_gpu_nvidia_list_free")]
    public class NvidiaList {
        [CCode (cname = "sinty_gpu_nvidia_list_count")]
        public size_t count ();
        [CCode (cname = "sinty_gpu_nvidia_list_at")]
        public unowned NvidiaGpu? at (size_t index);
    }

    [CCode (cname = "sinty_gpu_nvidia")]
    public int gpu_nvidia (out NvidiaList list);
}
