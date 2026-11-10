package sintysystem

// #cgo pkg-config: sinty-system-1
// #include <stdlib.h>
// #include <sinty-system/v1.h>
import "C"

import (
	"errors"
	"syscall"
	"unsafe"
)

func check(rc C.int) error {
	if rc >= 0 {
		return nil
	}
	return syscall.Errno(-rc)
}

func text(b []C.char) string {
	n := 0
	for n < len(b) && b[n] != 0 {
		n++
	}
	if n == 0 {
		return ""
	}
	return C.GoStringN(&b[0], C.int(n))
}

func Version() (uint32, uint32) {
	var major, minor C.uint32_t
	C.sinty_system_version(&major, &minor)
	return uint32(major), uint32(minor)
}

type Socket struct {
	Family        uint8
	Protocol      uint8
	State         uint8
	LocalPort     uint16
	RemotePort    uint16
	Local         string
	Remote        string
	UID           uint32
	PID           int32
	Inode         uint64
	BytesSent     uint64
	BytesReceived uint64
	BytesAcked    uint64
}

func Sockets(tcp, udp bool) ([]Socket, error) {
	var flags C.uint32_t
	if tcp {
		flags |= C.SINTY_PROC_SOCKETS_TCP
	}
	if udp {
		flags |= C.SINTY_PROC_SOCKETS_UDP
	}
	var list *C.SintySocketList
	if err := check(C.sinty_proc_sockets(flags, &list)); err != nil {
		return nil, err
	}
	defer C.sinty_proc_socket_list_free(list)
	n := int(C.sinty_proc_socket_list_count(list))
	out := make([]Socket, 0, n)
	for i := 0; i < n; i++ {
		s := C.sinty_proc_socket_list_at(list, C.size_t(i))
		out = append(out, Socket{
			Family: uint8(s.family), Protocol: uint8(s.protocol), State: uint8(s.state),
			LocalPort: uint16(s.local_port), RemotePort: uint16(s.remote_port),
			Local: text(s.local[:]), Remote: text(s.remote[:]),
			UID: uint32(s.uid), PID: int32(s.pid), Inode: uint64(s.inode),
			BytesSent: uint64(s.bytes_sent), BytesReceived: uint64(s.bytes_received), BytesAcked: uint64(s.bytes_acked),
		})
	}
	return out, nil
}

func SetNice(pid int32, nice int32) error {
	return check(C.sinty_proc_set_nice(C.int32_t(pid), C.int32_t(nice)))
}

func SetIOPriority(pid int32, class, level uint32) error {
	return check(C.sinty_proc_set_io_priority(C.int32_t(pid), C.uint32_t(class), C.uint32_t(level)))
}

type SensorKind uint32

const (
	SensorTemperature SensorKind = C.SINTY_SENSOR_TEMPERATURE
	SensorFan         SensorKind = C.SINTY_SENSOR_FAN
	SensorVoltage     SensorKind = C.SINTY_SENSOR_VOLTAGE
	SensorPower       SensorKind = C.SINTY_SENSOR_POWER
	SensorCurrent     SensorKind = C.SINTY_SENSOR_CURRENT
	SensorEnergy      SensorKind = C.SINTY_SENSOR_ENERGY
	SensorHumidity    SensorKind = C.SINTY_SENSOR_HUMIDITY
)

type Reading struct {
	Kind        SensorKind
	Value       int64
	Min, Max    int64
	Crit        int64
	HasMin      bool
	HasMax      bool
	HasCrit     bool
	Chip, Label string
	Device      string
}

func Sensors(thermalZones bool) ([]Reading, error) {
	var flags C.uint32_t
	if thermalZones {
		flags = C.SINTY_SENSORS_THERMAL_ZONES
	}
	var list *C.SintySensorList
	if err := check(C.sinty_sensors_list(flags, &list)); err != nil {
		return nil, err
	}
	defer C.sinty_sensors_list_free(list)
	n := int(C.sinty_sensors_list_count(list))
	out := make([]Reading, 0, n)
	for i := 0; i < n; i++ {
		r := C.sinty_sensors_list_at(list, C.size_t(i))
		out = append(out, Reading{
			Kind: SensorKind(r.kind), Value: int64(r.value), Min: int64(r.min), Max: int64(r.max), Crit: int64(r.crit),
			HasMin: r.has_min != 0, HasMax: r.has_max != 0, HasCrit: r.has_crit != 0,
			Chip: text(r.chip[:]), Label: text(r.label[:]), Device: text(r.device[:]),
		})
	}
	return out, nil
}

func Sysctl(name string) (string, error) {
	cname := C.CString(name)
	defer C.free(unsafe.Pointer(cname))
	buf := make([]C.char, 4096)
	rc := C.sinty_sysctl_get(cname, &buf[0], C.size_t(len(buf)))
	if err := check(rc); err != nil {
		return "", err
	}
	return C.GoStringN(&buf[0], rc), nil
}

func SetSysctl(name, value string) error {
	cname := C.CString(name)
	defer C.free(unsafe.Pointer(cname))
	cvalue := C.CString(value)
	defer C.free(unsafe.Pointer(cvalue))
	return check(C.sinty_sysctl_set(cname, cvalue))
}

type Supply struct {
	Kind, Status                          uint32
	Online, Present, Capacity, Cycles     int32
	DeviceScope                           bool
	ChargeStart, ChargeEnd                int32
	EnergyNow, EnergyFull, EnergyDesign   int64
	PowerNow, VoltageNow                  int64
	TimeToEmpty, TimeToFull               int64
	Name, Model, Manufacturer, Technology string
	Serial                                string
}

func Supplies() ([]Supply, error) {
	var list *C.SintyPowerSupplyList
	if err := check(C.sinty_power_supplies(&list)); err != nil {
		return nil, err
	}
	defer C.sinty_power_supply_list_free(list)
	n := int(C.sinty_power_supply_list_count(list))
	out := make([]Supply, 0, n)
	for i := 0; i < n; i++ {
		s := C.sinty_power_supply_list_at(list, C.size_t(i))
		out = append(out, Supply{
			Kind: uint32(s.kind), Status: uint32(s.status), Online: int32(s.online), Present: int32(s.present),
			Capacity: int32(s.capacity), Cycles: int32(s.cycle_count), DeviceScope: s.device_scope != 0,
			ChargeStart: int32(s.charge_start_threshold), ChargeEnd: int32(s.charge_end_threshold),
			EnergyNow: int64(s.energy_now), EnergyFull: int64(s.energy_full), EnergyDesign: int64(s.energy_full_design),
			PowerNow: int64(s.power_now), VoltageNow: int64(s.voltage_now),
			TimeToEmpty: int64(s.time_to_empty), TimeToFull: int64(s.time_to_full),
			Name: text(s.name[:]), Model: text(s.model[:]), Manufacturer: text(s.manufacturer[:]),
			Technology: text(s.technology[:]), Serial: text(s.serial[:]),
		})
	}
	return out, nil
}

func SetChargeThresholds(name string, start, end int32) error {
	cname := C.CString(name)
	defer C.free(unsafe.Pointer(cname))
	return check(C.sinty_power_set_charge_thresholds(cname, C.int32_t(start), C.int32_t(end)))
}

func PlatformProfile() (string, string, error) {
	cur := make([]C.char, 64)
	choices := make([]C.char, 256)
	if err := check(C.sinty_power_profile(&cur[0], C.size_t(len(cur)), &choices[0], C.size_t(len(choices)))); err != nil {
		return "", "", err
	}
	return text(cur), text(choices), nil
}

func SetPlatformProfile(profile string) error {
	c := C.CString(profile)
	defer C.free(unsafe.Pointer(c))
	return check(C.sinty_power_set_profile(c))
}

type Backlight struct {
	Kind                    uint32
	Brightness, Max, Actual int64
	Name, Connector         string
}

func Backlights() ([]Backlight, error) {
	var list *C.SintyBacklightList
	if err := check(C.sinty_display_backlights(&list)); err != nil {
		return nil, err
	}
	defer C.sinty_display_backlight_list_free(list)
	n := int(C.sinty_display_backlight_list_count(list))
	out := make([]Backlight, 0, n)
	for i := 0; i < n; i++ {
		b := C.sinty_display_backlight_list_at(list, C.size_t(i))
		out = append(out, Backlight{Kind: uint32(b.kind), Brightness: int64(b.brightness), Max: int64(b.max_brightness),
			Actual: int64(b.actual_brightness), Name: text(b.name[:]), Connector: text(b.connector[:])})
	}
	return out, nil
}

func SetBacklight(name string, value int64) error {
	c := C.CString(name)
	defer C.free(unsafe.Pointer(c))
	return check(C.sinty_display_set_backlight(c, C.int64_t(value)))
}

func HwdbGet(modalias, key string) (string, error) {
	cm := C.CString(modalias)
	defer C.free(unsafe.Pointer(cm))
	ck := C.CString(key)
	defer C.free(unsafe.Pointer(ck))
	buf := make([]C.char, 512)
	rc := C.sinty_device_hwdb_get(cm, ck, &buf[0], C.size_t(len(buf)))
	if err := check(rc); err != nil {
		return "", err
	}
	return C.GoStringN(&buf[0], rc), nil
}

func DeviceNames(syspath string) (vendor, model string, err error) {
	c := C.CString(syspath)
	defer C.free(unsafe.Pointer(c))
	var names C.SintyDeviceNames
	if err := check(C.sinty_device_names(c, &names)); err != nil {
		return "", "", err
	}
	return text(names.vendor[:]), text(names.model[:]), nil
}

type Link struct {
	SpeedMbps, MaxSupportedMbps int32
	Duplex, Autoneg, Port       int32
}

func LinkInfo(iface string) (Link, error) {
	c := C.CString(iface)
	defer C.free(unsafe.Pointer(c))
	var info C.SintyLinkInfo
	if err := check(C.sinty_net_link_info(c, &info)); err != nil {
		return Link{}, err
	}
	return Link{int32(info.speed_mbps), int32(info.max_supported_mbps), int32(info.duplex), int32(info.autoneg), int32(info.port)}, nil
}

func Locales() ([]string, error) {
	var list *C.SintyTextList
	if err := check(C.sinty_i18n_installed_locales(&list)); err != nil {
		return nil, err
	}
	defer C.sinty_text_list_free(list)
	n := int(C.sinty_text_list_count(list))
	out := make([]string, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, C.GoString(C.sinty_text_list_at(list, C.size_t(i))))
	}
	return out, nil
}

type FirewallPort struct {
	Spec    string
	Comment string
}

var ErrTooManyPorts = errors.New("sintysystem: too many firewall ports")

func FirewallApply(enabled, public bool, ports []FirewallPort) error {
	if len(ports) > 256 {
		return ErrTooManyPorts
	}
	specs := make([]*C.char, len(ports)+1)
	comments := make([]*C.char, len(ports)+1)
	for i, p := range ports {
		specs[i] = C.CString(p.Spec)
		comments[i] = C.CString(p.Comment)
	}
	defer func() {
		for i := range ports {
			C.free(unsafe.Pointer(specs[i]))
			C.free(unsafe.Pointer(comments[i]))
		}
	}()
	cs := (**C.char)(C.malloc(C.size_t(len(specs)) * C.size_t(unsafe.Sizeof(uintptr(0)))))
	cc := (**C.char)(C.malloc(C.size_t(len(comments)) * C.size_t(unsafe.Sizeof(uintptr(0)))))
	defer C.free(unsafe.Pointer(cs))
	defer C.free(unsafe.Pointer(cc))
	copy(unsafe.Slice(cs, len(specs)), specs)
	copy(unsafe.Slice(cc, len(comments)), comments)
	return check(C.sinty_firewall_apply(C.bool(enabled), C.bool(public), cs, cc, C.size_t(len(ports))))
}

type FirewallSummary struct {
	TablePresent, ChainPresent, PolicyDrop bool
	Rules                                  uint32
	Comments                               []string
}

func FirewallState() (FirewallSummary, error) {
	var s C.SintyFirewallSummary
	if err := check(C.sinty_firewall_summary(&s)); err != nil {
		return FirewallSummary{}, err
	}
	out := FirewallSummary{TablePresent: s.table_present != 0, ChainPresent: s.chain_present != 0,
		PolicyDrop: s.chain_policy_drop != 0, Rules: uint32(s.rules)}
	for i := 0; i < len(s.comments) && i < int(s.rules); i++ {
		out.Comments = append(out.Comments, text(s.comments[i][:]))
	}
	return out, nil
}

type RTCTime struct {
	Year, Month, Day, Hour, Minute, Second int32
}

func RTC() (RTCTime, error) {
	var t C.SintyRtcTime
	if err := check(C.sinty_time_rtc_read(&t)); err != nil {
		return RTCTime{}, err
	}
	return RTCTime{int32(t.year), int32(t.month), int32(t.day), int32(t.hour), int32(t.minute), int32(t.second)}, nil
}

func SetRTC(t RTCTime) error {
	c := C.SintyRtcTime{year: C.int32_t(t.Year), month: C.int32_t(t.Month), day: C.int32_t(t.Day),
		hour: C.int32_t(t.Hour), minute: C.int32_t(t.Minute), second: C.int32_t(t.Second)}
	return check(C.sinty_time_rtc_write(&c))
}

type ClockState struct {
	Synchronized bool
	State        int32
	Status       uint32
	OffsetNs     int64
	MaxErrorUs   int64
	EstErrorUs   int64
}

func Clock() (ClockState, error) {
	var s C.SintyClockState
	if err := check(C.sinty_time_clock(&s)); err != nil {
		return ClockState{}, err
	}
	return ClockState{s.synchronized != 0, int32(s.state), uint32(s.status), int64(s.offset_ns), int64(s.max_error_us), int64(s.est_error_us)}, nil
}

func TimeZone() (string, error) {
	var buf [256]C.char
	if err := check(C.sinty_time_zone(&buf[0], C.size_t(len(buf)))); err != nil {
		return "", err
	}
	return text(buf[:]), nil
}

func ServiceControl(action, unit string) error {
	a, u := C.CString(action), C.CString(unit)
	defer C.free(unsafe.Pointer(a))
	defer C.free(unsafe.Pointer(u))
	return check(C.sinty_service_control(a, u))
}

func ServiceState(unit string) (string, error) {
	u := C.CString(unit)
	defer C.free(unsafe.Pointer(u))
	var buf [64]C.char
	if err := check(C.sinty_service_state(u, &buf[0], C.size_t(len(buf)))); err != nil {
		return "", err
	}
	return text(buf[:]), nil
}

type EsrtEntry struct {
	Class              string
	Type               uint32
	Version            uint32
	LowestVersion      uint32
	CapsuleFlags       uint32
	LastAttemptVersion uint32
	LastAttemptStatus  uint32
}

func Esrt() ([]EsrtEntry, error) {
	var l *C.SintyEsrtList
	if err := check(C.sinty_firmware_esrt(&l)); err != nil {
		return nil, err
	}
	defer C.sinty_firmware_esrt_free(l)
	n := int(C.sinty_firmware_esrt_count(l))
	out := make([]EsrtEntry, 0, n)
	for i := 0; i < n; i++ {
		e := C.sinty_firmware_esrt_at(l, C.size_t(i))
		out = append(out, EsrtEntry{text(e.fw_class[:]), uint32(e.fw_type), uint32(e.fw_version),
			uint32(e.lowest_supported_version), uint32(e.capsule_flags), uint32(e.last_attempt_version), uint32(e.last_attempt_status)})
	}
	return out, nil
}

func CapsuleSupported() bool {
	return bool(C.sinty_firmware_capsule_supported())
}

func StageCapsule(esp, name string, data []byte) error {
	if len(data) == 0 {
		return syscall.EINVAL
	}
	e, n := C.CString(esp), C.CString(name)
	defer C.free(unsafe.Pointer(e))
	defer C.free(unsafe.Pointer(n))
	return check(C.sinty_firmware_stage_capsule(e, n, (*C.uint8_t)(unsafe.Pointer(&data[0])), C.size_t(len(data))))
}

type TableKind uint32

const (
	TableNone TableKind = 0
	TableGPT  TableKind = 1
	TableDOS  TableKind = 2
)

type DiskTable struct {
	Kind        TableKind
	SectorSize  uint32
	Size        uint64
	FirstUsable uint64
	LastUsable  uint64
	ID          string
}

type Partition struct {
	Number   uint32
	Bootable bool
	Start    uint64
	Size     uint64
	Attrs    uint64
	Type     string
	UUID     string
	Name     string
}

func ReadPartitions(path string) (DiskTable, []Partition, error) {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	var info C.SintyDiskTable
	var l *C.SintyPartitionList
	if err := check(C.sinty_disk_table(p, &info, &l)); err != nil {
		return DiskTable{}, nil, err
	}
	defer C.sinty_disk_partitions_free(l)
	t := DiskTable{TableKind(info.kind), uint32(info.sector_size), uint64(info.size), uint64(info.first_usable), uint64(info.last_usable), text(info.guid[:])}
	n := int(C.sinty_disk_partitions_count(l))
	out := make([]Partition, 0, n)
	for i := 0; i < n; i++ {
		e := C.sinty_disk_partitions_at(l, C.size_t(i))
		out = append(out, Partition{uint32(e.number), e.bootable != 0, uint64(e.start), uint64(e.size), uint64(e.attrs),
			text(e._type[:]), text(e.uuid[:]), text(e.name[:])})
	}
	return t, out, nil
}

func CreatePartitionTable(path string, kind TableKind) error {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	return check(C.sinty_disk_create_table(p, C.uint32_t(kind)))
}

func AddPartition(path string, start, size uint64, kind, name string) (uint32, error) {
	p, k, n := C.CString(path), C.CString(kind), C.CString(name)
	defer C.free(unsafe.Pointer(p))
	defer C.free(unsafe.Pointer(k))
	defer C.free(unsafe.Pointer(n))
	var number C.uint32_t
	if err := check(C.sinty_disk_add(p, C.uint64_t(start), C.uint64_t(size), k, n, &number)); err != nil {
		return 0, err
	}
	return uint32(number), nil
}

func RemovePartition(path string, number uint32) error {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	return check(C.sinty_disk_remove(p, C.uint32_t(number)))
}

func SetPartitionType(path string, number uint32, kind string) error {
	p, k := C.CString(path), C.CString(kind)
	defer C.free(unsafe.Pointer(p))
	defer C.free(unsafe.Pointer(k))
	return check(C.sinty_disk_set_type(p, C.uint32_t(number), k))
}

func SetPartitionName(path string, number uint32, name string) error {
	p, n := C.CString(path), C.CString(name)
	defer C.free(unsafe.Pointer(p))
	defer C.free(unsafe.Pointer(n))
	return check(C.sinty_disk_set_name(p, C.uint32_t(number), n))
}

func SetPartitionAttrs(path string, number uint32, attrs uint64) error {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	return check(C.sinty_disk_set_attrs(p, C.uint32_t(number), C.uint64_t(attrs)))
}

func ResizePartition(path string, number uint32, size uint64) error {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	return check(C.sinty_disk_resize(p, C.uint32_t(number), C.uint64_t(size)))
}

func SyncPartitions(path string) error {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	return check(C.sinty_disk_sync_kernel(p))
}

func BlockUevent(name, action string) error {
	n, a := C.CString(name), C.CString(action)
	defer C.free(unsafe.Pointer(n))
	defer C.free(unsafe.Pointer(a))
	return check(C.sinty_disk_uevent(n, a))
}

func SettleBlock(name string, timeoutMs uint32) bool {
	n := C.CString(name)
	defer C.free(unsafe.Pointer(n))
	return bool(C.sinty_disk_settle(n, C.uint32_t(timeoutMs)))
}

func WipeSignatures(path string) error {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	return check(C.sinty_disk_wipe(p))
}

func Swap(path string, on bool) error {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	return check(C.sinty_disk_swap(p, C.bool(on)))
}

func Eject(path string) error {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	return check(C.sinty_disk_eject(p))
}

type FsInfo struct {
	Type      string
	Usage     string
	UUID      string
	Label     string
	Version   string
	BlockSize uint32
	Size      uint64
}

func ProbeFilesystem(path string) (FsInfo, error) {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	var i C.SintyFsInfo
	if err := check(C.sinty_fs_probe(p, &i)); err != nil {
		return FsInfo{}, err
	}
	return FsInfo{text(i._type[:]), text(i.usage[:]), text(i.uuid[:]), text(i.label[:]), text(i.version[:]), uint32(i.block_size), uint64(i.size)}, nil
}

func SetFilesystemLabel(path, label string) error {
	p, l := C.CString(path), C.CString(label)
	defer C.free(unsafe.Pointer(p))
	defer C.free(unsafe.Pointer(l))
	return check(C.sinty_fs_set_label(p, l))
}

func MakeSwap(path, label string) error {
	p, l := C.CString(path), C.CString(label)
	defer C.free(unsafe.Pointer(p))
	defer C.free(unsafe.Pointer(l))
	return check(C.sinty_fs_mkswap(p, l))
}

func MakeVfat(path, label string, bits uint8) error {
	p, l := C.CString(path), C.CString(label)
	defer C.free(unsafe.Pointer(p))
	defer C.free(unsafe.Pointer(l))
	return check(C.sinty_fs_mkfs_vfat(p, l, C.uint8_t(bits)))
}

func MakeExfat(path, label string) error {
	p, l := C.CString(path), C.CString(label)
	defer C.free(unsafe.Pointer(p))
	defer C.free(unsafe.Pointer(l))
	return check(C.sinty_fs_mkfs_exfat(p, l))
}

func MakeExt4(path, label string) error {
	p, l := C.CString(path), C.CString(label)
	defer C.free(unsafe.Pointer(p))
	defer C.free(unsafe.Pointer(l))
	return check(C.sinty_fs_mkfs_ext4(p, l))
}
