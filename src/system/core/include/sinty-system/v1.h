#ifndef SINTY_SYSTEM_V1_H
#define SINTY_SYSTEM_V1_H

#include <stdbool.h>
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

typedef struct SintyTextList SintyTextList;

size_t sinty_text_list_count(const SintyTextList *list);
const char *sinty_text_list_at(const SintyTextList *list, size_t index);
void sinty_text_list_free(SintyTextList *list);

int sinty_i18n_installed_locales(SintyTextList **out);

typedef struct {
    int32_t temperature_c;
    int32_t sm_clock_mhz;
    int32_t power_mw;
    int32_t utilization_pct;
    int64_t memory_used;
    int64_t memory_total;
    char name[96];
} SintyNvidiaGpu;

typedef struct SintyNvidiaList SintyNvidiaList;

int sinty_gpu_nvidia(SintyNvidiaList **out);
size_t sinty_gpu_nvidia_list_count(const SintyNvidiaList *list);
const SintyNvidiaGpu *sinty_gpu_nvidia_list_at(const SintyNvidiaList *list, size_t index);
void sinty_gpu_nvidia_list_free(SintyNvidiaList *list);

typedef struct {
    uint8_t table_present;
    uint8_t chain_present;
    uint8_t chain_policy_drop;
    uint8_t pad;
    uint32_t rules;
    char comments[16][64];
} SintyFirewallSummary;

int sinty_firewall_apply(bool enabled, bool public_profile, const char *const *port_specs, const char *const *comments, size_t count);
int sinty_firewall_summary(SintyFirewallSummary *out);

typedef enum {
    SINTY_AUDIO_NODE = 1,
    SINTY_AUDIO_CLIENT = 2,
    SINTY_AUDIO_LINK = 3,
} SintyAudioKind;

typedef struct {
    uint32_t id;
    int32_t kind;
    uint32_t output_node;
    uint32_t input_node;
    size_t n_props;
    char **keys;
    char **values;
} SintyAudioObject;

typedef struct SintyAudioGraph SintyAudioGraph;

int sinty_audio_graph(SintyAudioGraph **out);
size_t sinty_audio_graph_count(const SintyAudioGraph *graph);
const SintyAudioObject *sinty_audio_graph_at(const SintyAudioGraph *graph, size_t index);
void sinty_audio_graph_free(SintyAudioGraph *graph);
const char *sinty_audio_object_prop(const SintyAudioObject *object, const char *key);
int sinty_audio_set_controls(const char *node_name, const char *const *names, const float *values, size_t count);

typedef struct {
    int32_t year;
    int32_t month;
    int32_t day;
    int32_t hour;
    int32_t minute;
    int32_t second;
} SintyRtcTime;

typedef struct {
    int32_t synchronized;
    int32_t state;
    uint32_t status;
    uint32_t pad;
    int64_t offset_ns;
    int64_t max_error_us;
    int64_t est_error_us;
} SintyClockState;

int sinty_time_rtc_read(SintyRtcTime *out);
int sinty_time_rtc_write(const SintyRtcTime *time);
int sinty_time_clock(SintyClockState *out);
int sinty_time_zone(char *buf, size_t len);

int sinty_service_control(const char *action, const char *unit);
int sinty_service_state(const char *unit, char *buf, size_t len);

typedef struct {
    char fw_class[40];
    uint32_t fw_type;
    uint32_t fw_version;
    uint32_t lowest_supported_version;
    uint32_t capsule_flags;
    uint32_t last_attempt_version;
    uint32_t last_attempt_status;
} SintyEsrtEntry;

typedef struct SintyEsrtList SintyEsrtList;

int sinty_firmware_esrt(SintyEsrtList **out);
size_t sinty_firmware_esrt_count(const SintyEsrtList *list);
const SintyEsrtEntry *sinty_firmware_esrt_at(const SintyEsrtList *list, size_t index);
void sinty_firmware_esrt_free(SintyEsrtList *list);
bool sinty_firmware_capsule_supported(void);
int sinty_firmware_stage_capsule(const char *esp, const char *name, const uint8_t *data, size_t len);

typedef struct {
    uint32_t number;
    uint32_t bootable;
    uint64_t start;
    uint64_t size;
    uint64_t attrs;
    char type[40];
    char uuid[40];
    char name[80];
} SintyPartition;

typedef struct {
    uint32_t kind;
    uint32_t sector_size;
    uint64_t size;
    uint64_t first_usable;
    uint64_t last_usable;
    char guid[40];
} SintyDiskTable;

typedef struct SintyPartitionList SintyPartitionList;

int sinty_disk_table(const char *path, SintyDiskTable *info, SintyPartitionList **out);
size_t sinty_disk_partitions_count(const SintyPartitionList *list);
const SintyPartition *sinty_disk_partitions_at(const SintyPartitionList *list, size_t index);
void sinty_disk_partitions_free(SintyPartitionList *list);
int sinty_disk_create_table(const char *path, uint32_t kind);
int sinty_disk_add(const char *path, uint64_t start, uint64_t size, const char *type, const char *name, uint32_t *number);
int sinty_disk_remove(const char *path, uint32_t number);
int sinty_disk_set_type(const char *path, uint32_t number, const char *type);
int sinty_disk_set_name(const char *path, uint32_t number, const char *name);
int sinty_disk_set_attrs(const char *path, uint32_t number, uint64_t attrs);
int sinty_disk_resize(const char *path, uint32_t number, uint64_t size);
int sinty_disk_sync_kernel(const char *path);
int sinty_disk_uevent(const char *name, const char *action);
bool sinty_disk_settle(const char *name, uint32_t timeout_ms);
int sinty_disk_wipe(const char *path);
int sinty_disk_swap(const char *path, bool on);
int sinty_disk_eject(const char *path);

typedef struct {
    char type[16];
    char usage[16];
    char uuid[40];
    char label[256];
    char version[16];
    uint32_t block_size;
    uint32_t pad;
    uint64_t size;
} SintyFsInfo;

int sinty_fs_probe(const char *path, SintyFsInfo *out);
int sinty_fs_set_label(const char *path, const char *label);
int sinty_fs_mkswap(const char *path, const char *label);
int sinty_fs_mkfs_vfat(const char *path, const char *label, uint8_t bits);
int sinty_fs_mkfs_exfat(const char *path, const char *label);
int sinty_fs_mkfs_ext4(const char *path, const char *label);

typedef struct {
    uint32_t version;
    uint32_t keyslots;
    uint32_t sector_size;
    uint32_t pad;
    uint64_t payload_offset;
    char uuid[40];
    char label[48];
    char cipher[64];
} SintyLuksInfo;

int sinty_crypt_info(const char *path, SintyLuksInfo *out);
int sinty_crypt_format(const char *path, const char *pass, size_t len, const char *label);
int sinty_crypt_change_passphrase(const char *path, const char *old, size_t old_len, const char *new_pass, size_t new_len);
int sinty_crypt_open(const char *path, const char *pass, size_t len, const char *name, bool read_only);
int sinty_crypt_close(const char *name);

typedef struct SintyBtSession SintyBtSession;
typedef struct SintyBtState SintyBtState;

typedef struct {
    char path[64];
    char address[24];
    char alias[256];
    char name[256];
    bool powered;
    bool discoverable;
    bool pairable;
    bool discovering;
} SintyBtAdapter;

typedef struct {
    char path[128];
    char adapter[64];
    char address[24];
    char alias[256];
    char name[256];
    char icon[64];
    uint32_t device_class;
    int16_t rssi;
    int16_t battery;
    bool paired;
    bool trusted;
    bool blocked;
    bool connected;
    bool has_rssi;
    uint8_t pad[3];
} SintyBtDevice;

enum { SINTY_BT_POWERED, SINTY_BT_DISCOVERABLE, SINTY_BT_PAIRABLE };
enum { SINTY_BT_TRUSTED, SINTY_BT_BLOCKED };
enum { SINTY_BT_CONNECT, SINTY_BT_DISCONNECT, SINTY_BT_PAIR, SINTY_BT_CANCEL_PAIRING };

int sinty_bt_session_open(SintyBtSession **out);
void sinty_bt_session_close(SintyBtSession *s);
int sinty_bt_snapshot(SintyBtSession *s, SintyBtState **out);
size_t sinty_bt_adapter_count(const SintyBtState *st);
const SintyBtAdapter *sinty_bt_adapter_at(const SintyBtState *st, size_t i);
size_t sinty_bt_device_count(const SintyBtState *st);
const SintyBtDevice *sinty_bt_device_at(const SintyBtState *st, size_t i);
void sinty_bt_free(SintyBtState *st);
int sinty_bt_set_adapter(SintyBtSession *s, const char *path, int which, bool on);
int sinty_bt_set_device(SintyBtSession *s, const char *path, int which, bool on);
int sinty_bt_set_alias(SintyBtSession *s, const char *path, const char *alias);
int sinty_bt_device_action(SintyBtSession *s, const char *path, int action);
int sinty_bt_remove(SintyBtSession *s, const char *path);
int sinty_bt_discovery(SintyBtSession *s, const char *adapter, bool on);

enum { SINTY_NOTIFY_LOW, SINTY_NOTIFY_NORMAL, SINTY_NOTIFY_CRITICAL };

typedef struct {
    const char *app_name;
    const char *icon;
    const char *summary;
    const char *body;
    const char *category;
    const char *desktop_entry;
    const char *const *actions;
    size_t n_actions;
    uint32_t replaces_id;
    int32_t timeout_ms;
    uint8_t urgency;
    bool transient;
    uint8_t pad[6];
} SintyNotification;

int sinty_notify_send(const SintyNotification *n, uint32_t *id);
int sinty_notify_close(uint32_t id);

typedef struct SintyInputEngines SintyInputEngines;

typedef struct {
    char name[64];
    char label[128];
    char symbol[16];
    char language[32];
} SintyInputEngine;

enum { SINTY_INPUT_CONVERSION, SINTY_INPUT_FULLWIDTH, SINTY_INPUT_LEARN };
enum { SINTY_INPUT_CONVERT_NONE, SINTY_INPUT_CONVERT_SIMPLIFIED, SINTY_INPUT_CONVERT_TRADITIONAL, SINTY_INPUT_CONVERT_TAIWAN, SINTY_INPUT_CONVERT_HONGKONG };

int sinty_input_engines(SintyInputEngines **out);
size_t sinty_input_engines_count(const SintyInputEngines *l);
const SintyInputEngine *sinty_input_engines_at(const SintyInputEngines *l, size_t i);
void sinty_input_engines_free(SintyInputEngines *l);
int sinty_input_select(const char *name);
int sinty_input_active(char *buf, size_t len);
int sinty_input_configure(const char *name, int option, int value);

#ifdef __cplusplus
}
#endif

#endif
