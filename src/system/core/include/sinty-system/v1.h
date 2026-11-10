#ifndef SINTY_SYSTEM_V1_H
#define SINTY_SYSTEM_V1_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void sinty_system_version(uint32_t *major, uint32_t *minor);
void sinty_string_free(char *s);

typedef struct {
    int32_t pid;
    int32_t ppid;
    uint32_t uid;
    uint8_t state;
    uint8_t pad[3];
    int32_t nice;
    uint32_t threads;
    uint64_t rss_bytes;
    uint64_t vsize_bytes;
    uint64_t utime_ticks;
    uint64_t stime_ticks;
    uint64_t start_ticks;
    char name[64];
    char *cmdline;
} SintyProcess;

typedef struct SintyProcessList SintyProcessList;

int sinty_proc_list(SintyProcessList **out);
size_t sinty_proc_list_count(const SintyProcessList *list);
const SintyProcess *sinty_proc_list_at(const SintyProcessList *list, size_t index);
void sinty_proc_list_free(SintyProcessList *list);
int sinty_proc_get(int32_t pid, SintyProcess *out);
int sinty_proc_signal(int32_t pid, int32_t sig);
int sinty_proc_get_nice(int32_t pid, int32_t *out);
int sinty_proc_set_nice(int32_t pid, int32_t nice);
int sinty_proc_set_io_priority(int32_t pid, uint32_t io_class, uint32_t level);
int sinty_proc_get_io_priority(int32_t pid, uint32_t *io_class, uint32_t *level);

enum {
    SINTY_PROC_SOCKETS_TCP = 1,
    SINTY_PROC_SOCKETS_UDP = 2
};

typedef struct {
    uint8_t family;
    uint8_t protocol;
    uint8_t state;
    uint8_t pad;
    uint16_t local_port;
    uint16_t remote_port;
    char local[46];
    char remote[46];
    uint32_t uid;
    int32_t pid;
    uint64_t inode;
    uint64_t bytes_sent;
    uint64_t bytes_received;
    uint64_t bytes_acked;
} SintySocket;

typedef struct SintySocketList SintySocketList;

int sinty_proc_sockets(uint32_t flags, SintySocketList **out);
size_t sinty_proc_socket_list_count(const SintySocketList *list);
const SintySocket *sinty_proc_socket_list_at(const SintySocketList *list, size_t index);
void sinty_proc_socket_list_free(SintySocketList *list);

typedef enum {
    SINTY_SENSOR_TEMPERATURE = 0,
    SINTY_SENSOR_FAN = 1,
    SINTY_SENSOR_VOLTAGE = 2,
    SINTY_SENSOR_POWER = 3,
    SINTY_SENSOR_CURRENT = 4,
    SINTY_SENSOR_ENERGY = 5,
    SINTY_SENSOR_HUMIDITY = 6
} SintySensorKind;

enum {
    SINTY_SENSORS_THERMAL_ZONES = 1
};

typedef struct {
    uint32_t kind;
    uint8_t has_max;
    uint8_t has_crit;
    uint8_t has_min;
    uint8_t pad;
    int64_t value;
    int64_t min;
    int64_t max;
    int64_t crit;
    char chip[64];
    char label[64];
    char device[128];
} SintySensorReading;

typedef struct SintySensorList SintySensorList;

int sinty_sensors_list(uint32_t flags, SintySensorList **out);
size_t sinty_sensors_list_count(const SintySensorList *list);
const SintySensorReading *sinty_sensors_list_at(const SintySensorList *list, size_t index);
void sinty_sensors_list_free(SintySensorList *list);
int sinty_sysctl_get(const char *name, char *out, size_t len);
int sinty_sysctl_set(const char *name, const char *value);

typedef enum {
    SINTY_SUPPLY_UNKNOWN = 0,
    SINTY_SUPPLY_BATTERY = 1,
    SINTY_SUPPLY_MAINS = 2,
    SINTY_SUPPLY_USB = 3,
    SINTY_SUPPLY_UPS = 4,
    SINTY_SUPPLY_WIRELESS = 5
} SintySupplyType;

typedef enum {
    SINTY_SUPPLY_STATUS_UNKNOWN = 0,
    SINTY_SUPPLY_STATUS_CHARGING = 1,
    SINTY_SUPPLY_STATUS_DISCHARGING = 2,
    SINTY_SUPPLY_STATUS_NOT_CHARGING = 3,
    SINTY_SUPPLY_STATUS_FULL = 4
} SintySupplyStatus;

typedef struct {
    uint32_t kind;
    uint32_t status;
    int32_t online;
    int32_t present;
    int32_t capacity;
    int32_t device_scope;
    int32_t cycle_count;
    int32_t charge_start_threshold;
    int32_t charge_end_threshold;
    int32_t pad;
    int64_t energy_now;
    int64_t energy_full;
    int64_t energy_full_design;
    int64_t power_now;
    int64_t voltage_now;
    int64_t time_to_empty;
    int64_t time_to_full;
    char name[64];
    char model[64];
    char manufacturer[64];
    char technology[32];
    char serial[64];
} SintyPowerSupply;

typedef struct SintyPowerSupplyList SintyPowerSupplyList;

int sinty_power_supplies(SintyPowerSupplyList **out);
size_t sinty_power_supply_list_count(const SintyPowerSupplyList *list);
const SintyPowerSupply *sinty_power_supply_list_at(const SintyPowerSupplyList *list, size_t index);
void sinty_power_supply_list_free(SintyPowerSupplyList *list);
int sinty_power_set_charge_thresholds(const char *name, int32_t start, int32_t end);
int sinty_power_profile(char *current, size_t current_len, char *choices, size_t choices_len);
int sinty_power_set_profile(const char *profile);

typedef struct {
    int32_t id;
    int32_t online;
    int64_t cur_khz;
    int64_t min_khz;
    int64_t max_khz;
    int64_t hw_min_khz;
    int64_t hw_max_khz;
    char governor[32];
    char governors[128];
    char epp[32];
    char epps[160];
    char driver[32];
    char cpus[64];
} SintyCpuPolicy;

typedef struct SintyCpuPolicyList SintyCpuPolicyList;

int sinty_power_cpu_policies(SintyCpuPolicyList **out);
size_t sinty_power_cpu_policy_list_count(const SintyCpuPolicyList *list);
const SintyCpuPolicy *sinty_power_cpu_policy_list_at(const SintyCpuPolicyList *list, size_t index);
void sinty_power_cpu_policy_list_free(SintyCpuPolicyList *list);
int sinty_power_set_governor(const char *governor);
int sinty_power_set_energy_preference(const char *preference);

typedef enum {
    SINTY_BACKLIGHT_UNKNOWN = 0,
    SINTY_BACKLIGHT_FIRMWARE = 1,
    SINTY_BACKLIGHT_PLATFORM = 2,
    SINTY_BACKLIGHT_RAW = 3
} SintyBacklightType;

typedef struct {
    uint32_t kind;
    uint32_t pad;
    int64_t brightness;
    int64_t max_brightness;
    int64_t actual_brightness;
    char name[64];
    char connector[64];
} SintyBacklight;

typedef struct SintyBacklightList SintyBacklightList;

int sinty_display_backlights(SintyBacklightList **out);
size_t sinty_display_backlight_list_count(const SintyBacklightList *list);
const SintyBacklight *sinty_display_backlight_list_at(const SintyBacklightList *list, size_t index);
void sinty_display_backlight_list_free(SintyBacklightList *list);
int sinty_display_set_backlight(const char *name, int64_t value);

typedef struct {
    uint32_t bus;
    uint32_t pad;
    char connector[64];
} SintyDdcDisplay;

typedef struct SintyDdcList SintyDdcList;

#define SINTY_VCP_BRIGHTNESS 0x10
#define SINTY_VCP_CONTRAST 0x12

int sinty_display_ddc_list(SintyDdcList **out);
size_t sinty_display_ddc_list_count(const SintyDdcList *list);
const SintyDdcDisplay *sinty_display_ddc_list_at(const SintyDdcList *list, size_t index);
void sinty_display_ddc_list_free(SintyDdcList *list);
int sinty_display_ddc_get(uint32_t bus, uint8_t vcp, uint16_t *current, uint16_t *maximum);
int sinty_display_ddc_set(uint32_t bus, uint8_t vcp, uint16_t value);

typedef struct {
    char vendor[128];
    char model[128];
} SintyDeviceNames;

int sinty_device_hwdb_get(const char *modalias, const char *key, char *out, size_t len);
int sinty_device_names(const char *syspath, SintyDeviceNames *out);
int sinty_device_uevent_get(const char *syspath, const char *key, char *out, size_t len);

typedef struct {
    int32_t speed_mbps;
    int32_t max_supported_mbps;
    int32_t duplex;
    int32_t autoneg;
    int32_t port;
    int32_t pad;
    uint32_t supported[32];
    uint32_t words;
    uint32_t pad2;
} SintyLinkInfo;

int sinty_net_link_info(const char *iface, SintyLinkInfo *out);

#ifdef __cplusplus
}
#endif

#endif
