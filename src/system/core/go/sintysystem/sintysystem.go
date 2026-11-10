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

func MakeSwapFile(path string, bytes uint64, label string) error {
	p, l := C.CString(path), C.CString(label)
	defer C.free(unsafe.Pointer(p))
	defer C.free(unsafe.Pointer(l))
	return check(C.sinty_fs_swapfile(p, C.uint64_t(bytes), l))
}

func MakeF2fs(path, label string) error {
	p, l := C.CString(path), C.CString(label)
	defer C.free(unsafe.Pointer(p))
	defer C.free(unsafe.Pointer(l))
	return check(C.sinty_fs_mkfs_f2fs(p, l))
}

func MakeExt4Encrypted(path, label string) error {
	p, l := C.CString(path), C.CString(label)
	defer C.free(unsafe.Pointer(p))
	defer C.free(unsafe.Pointer(l))
	return check(C.sinty_fs_mkfs_ext4_encrypted(p, l))
}

func GrowExt4(path string, size uint64) (uint64, error) {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	var out C.uint64_t
	err := check(C.sinty_fs_ext4_grow(p, C.uint64_t(size), &out))
	return uint64(out), err
}

func Mount(source, target, fstype, options string) error {
	s, t, f, o := C.CString(source), C.CString(target), C.CString(fstype), C.CString(options)
	defer C.free(unsafe.Pointer(s))
	defer C.free(unsafe.Pointer(t))
	defer C.free(unsafe.Pointer(f))
	defer C.free(unsafe.Pointer(o))
	return check(C.sinty_mount(s, t, f, o))
}

func MountOverlay(target string, lowers []string, upper, work, options string, readonly bool) error {
	if len(lowers) == 0 {
		return syscall.EINVAL
	}
	t := C.CString(target)
	defer C.free(unsafe.Pointer(t))
	arr := C.malloc(C.size_t(len(lowers)) * C.size_t(unsafe.Sizeof(uintptr(0))))
	defer C.free(arr)
	ptrs := unsafe.Slice((**C.char)(arr), len(lowers))
	for i, l := range lowers {
		ptrs[i] = C.CString(l)
		defer C.free(unsafe.Pointer(ptrs[i]))
	}
	var u, w, o *C.char
	if upper != "" {
		u = C.CString(upper)
		defer C.free(unsafe.Pointer(u))
	}
	if work != "" {
		w = C.CString(work)
		defer C.free(unsafe.Pointer(w))
	}
	if options != "" {
		o = C.CString(options)
		defer C.free(unsafe.Pointer(o))
	}
	return check(C.sinty_mount_overlay(t, (**C.char)(arr), C.size_t(len(lowers)), u, w, o, C.bool(readonly)))
}

func Unmount(target string, lazy bool) error {
	t := C.CString(target)
	defer C.free(unsafe.Pointer(t))
	return check(C.sinty_unmount(t, C.bool(lazy)))
}

func MountPointOf(device string) (string, error) {
	d := C.CString(device)
	defer C.free(unsafe.Pointer(d))
	buf := make([]C.char, 4096)
	rc := C.sinty_mount_find(d, &buf[0], C.size_t(len(buf)))
	if err := check(rc); err != nil || rc == 0 {
		return "", err
	}
	return text(buf), nil
}

type FsCheck struct {
	Errors         uint32
	Fixed          uint32
	LostClusters   uint32
	CrossLinks     uint32
	BadChains      uint32
	SizeMismatches uint32
	FatMismatches  uint32
	Dirty          bool
	Counters       uint32
	Files          uint32
	Dirs           uint32
	Message        string
}

func (c FsCheck) Clean() bool {
	return c.Errors == c.Fixed
}

func CheckFilesystem(path string, repair bool) (FsCheck, error) {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	var r C.SintyFsCheck
	if err := check(C.sinty_fs_check(p, C.bool(repair), &r)); err != nil {
		return FsCheck{}, err
	}
	return FsCheck{
		Errors: uint32(r.errors), Fixed: uint32(r.fixed), LostClusters: uint32(r.lost_clusters),
		CrossLinks: uint32(r.cross_links), BadChains: uint32(r.bad_chains), SizeMismatches: uint32(r.size_mismatches),
		FatMismatches: uint32(r.fat_mismatches), Dirty: r.dirty != 0, Counters: uint32(r.counters),
		Files: uint32(r.files), Dirs: uint32(r.dirs), Message: text(r.message[:]),
	}, nil
}

func BuildErofs(source, out, label string) (uint32, error) {
	s, o, l := C.CString(source), C.CString(out), C.CString(label)
	defer C.free(unsafe.Pointer(s))
	defer C.free(unsafe.Pointer(o))
	defer C.free(unsafe.Pointer(l))
	var blocks C.uint32_t
	err := check(C.sinty_erofs_build(s, o, l, &blocks))
	return uint32(blocks), err
}

type FscryptID [16]byte

type FscryptPolicy struct {
	Contents  uint8
	Filenames uint8
	Flags     uint8
	ID        FscryptID
}

type FscryptKeyStatus struct {
	Present     bool
	Incomplete  bool
	AddedBySelf bool
	Users       uint32
}

func NewFscryptPolicy(id FscryptID) FscryptPolicy {
	return FscryptPolicy{Contents: 1, Filenames: 4, Flags: 2, ID: id}
}

func FscryptIdentifier(raw []byte) FscryptID {
	var id FscryptID
	if len(raw) == 0 {
		raw = []byte{0}
	}
	C.sinty_fscrypt_identifier((*C.uint8_t)(unsafe.Pointer(&raw[0])), C.size_t(len(raw)), (*C.uint8_t)(unsafe.Pointer(&id[0])))
	return id
}

func FscryptAddKey(mount string, raw []byte) (FscryptID, error) {
	var id FscryptID
	if len(raw) != 64 {
		return id, syscall.EINVAL
	}
	m := C.CString(mount)
	defer C.free(unsafe.Pointer(m))
	err := check(C.sinty_fscrypt_add_key(m, (*C.uint8_t)(unsafe.Pointer(&raw[0])), C.size_t(len(raw)), (*C.uint8_t)(unsafe.Pointer(&id[0]))))
	return id, err
}

func FscryptRemoveKey(mount string, id FscryptID, allUsers bool) (busy bool, others bool, err error) {
	m := C.CString(mount)
	defer C.free(unsafe.Pointer(m))
	var flags C.uint32_t
	err = check(C.sinty_fscrypt_remove_key(m, (*C.uint8_t)(unsafe.Pointer(&id[0])), C.bool(allUsers), &flags))
	return flags&1 != 0, flags&2 != 0, err
}

func FscryptStatus(mount string, id FscryptID) (FscryptKeyStatus, error) {
	m := C.CString(mount)
	defer C.free(unsafe.Pointer(m))
	var st C.SintyFscryptKeyStatus
	if err := check(C.sinty_fscrypt_key_status(m, (*C.uint8_t)(unsafe.Pointer(&id[0])), &st)); err != nil {
		return FscryptKeyStatus{}, err
	}
	return FscryptKeyStatus{Present: st.status == 2, Incomplete: st.status == 3, AddedBySelf: bool(st.added_by_self), Users: uint32(st.user_count)}, nil
}

func FscryptSetPolicy(dir string, p FscryptPolicy) error {
	d := C.CString(dir)
	defer C.free(unsafe.Pointer(d))
	var cp C.SintyFscryptPolicy
	cp.version = 2
	cp.contents = C.uint8_t(p.Contents)
	cp.filenames = C.uint8_t(p.Filenames)
	cp.flags = C.uint8_t(p.Flags)
	for i, b := range p.ID {
		cp.id[i] = C.uint8_t(b)
	}
	return check(C.sinty_fscrypt_set_policy(d, &cp))
}

func FscryptGetPolicy(path string) (*FscryptPolicy, error) {
	c := C.CString(path)
	defer C.free(unsafe.Pointer(c))
	var cp C.SintyFscryptPolicy
	if err := check(C.sinty_fscrypt_get_policy(c, &cp)); err != nil {
		if errors.Is(err, syscall.ENODATA) {
			return nil, nil
		}
		return nil, err
	}
	p := &FscryptPolicy{Contents: uint8(cp.contents), Filenames: uint8(cp.filenames), Flags: uint8(cp.flags)}
	for i := range p.ID {
		p.ID[i] = byte(cp.id[i])
	}
	return p, nil
}

var ErrWrongPassphrase = syscall.EKEYREJECTED

type LuksInfo struct {
	Version       uint32
	Keyslots      uint32
	SectorSize    uint32
	PayloadOffset uint64
	UUID          string
	Label         string
	Cipher        string
}

func secret(s string) (*C.char, C.size_t, func()) {
	n := len(s)
	if n == 0 {
		n = 1
	}
	p := (*C.char)(C.malloc(C.size_t(n)))
	b := unsafe.Slice((*byte)(unsafe.Pointer(p)), n)
	copy(b, s)
	return p, C.size_t(len(s)), func() {
		for i := range b {
			b[i] = 0
		}
		C.free(unsafe.Pointer(p))
	}
}

func LuksInfoOf(path string) (LuksInfo, error) {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	var i C.SintyLuksInfo
	if err := check(C.sinty_crypt_info(p, &i)); err != nil {
		return LuksInfo{}, err
	}
	return LuksInfo{uint32(i.version), uint32(i.keyslots), uint32(i.sector_size), uint64(i.payload_offset), text(i.uuid[:]), text(i.label[:]), text(i.cipher[:])}, nil
}

func LuksFormat(path, passphrase, label string) error {
	p, l := C.CString(path), C.CString(label)
	defer C.free(unsafe.Pointer(p))
	defer C.free(unsafe.Pointer(l))
	s, n, done := secret(passphrase)
	defer done()
	return check(C.sinty_crypt_format(p, s, n, l))
}

func LuksChangePassphrase(path, old, new string) error {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	o, on, doneOld := secret(old)
	defer doneOld()
	s, sn, doneNew := secret(new)
	defer doneNew()
	return check(C.sinty_crypt_change_passphrase(p, o, on, s, sn))
}

func LuksOpen(path, passphrase, name string, readOnly bool) error {
	p, m := C.CString(path), C.CString(name)
	defer C.free(unsafe.Pointer(p))
	defer C.free(unsafe.Pointer(m))
	s, n, done := secret(passphrase)
	defer done()
	return check(C.sinty_crypt_open(p, s, n, m, C.bool(readOnly)))
}

func LuksClose(name string) error {
	m := C.CString(name)
	defer C.free(unsafe.Pointer(m))
	return check(C.sinty_crypt_close(m))
}

type BtAdapter struct {
	Path         string
	Address      string
	Alias        string
	Name         string
	Powered      bool
	Discoverable bool
	Pairable     bool
	Discovering  bool
}

type BtDevice struct {
	Path      string
	Adapter   string
	Address   string
	Alias     string
	Name      string
	Icon      string
	Class     uint32
	RSSI      int16
	HasRSSI   bool
	Battery   int
	Paired    bool
	Trusted   bool
	Blocked   bool
	Connected bool
}

type Bluetooth struct {
	s *C.SintyBtSession
}

func OpenBluetooth() (*Bluetooth, error) {
	var s *C.SintyBtSession
	if err := check(C.sinty_bt_session_open(&s)); err != nil {
		return nil, err
	}
	return &Bluetooth{s: s}, nil
}

func (b *Bluetooth) Close() {
	if b != nil && b.s != nil {
		C.sinty_bt_session_close(b.s)
		b.s = nil
	}
}

func (b *Bluetooth) session() *C.SintyBtSession {
	if b == nil {
		return nil
	}
	return b.s
}

func (b *Bluetooth) Snapshot() ([]BtAdapter, []BtDevice, error) {
	var st *C.SintyBtState
	if err := check(C.sinty_bt_snapshot(b.session(), &st)); err != nil {
		return nil, nil, err
	}
	defer C.sinty_bt_free(st)
	var adapters []BtAdapter
	for i := C.size_t(0); i < C.sinty_bt_adapter_count(st); i++ {
		a := C.sinty_bt_adapter_at(st, i)
		adapters = append(adapters, BtAdapter{
			Path: text(a.path[:]), Address: text(a.address[:]), Alias: text(a.alias[:]), Name: text(a.name[:]),
			Powered: bool(a.powered), Discoverable: bool(a.discoverable), Pairable: bool(a.pairable), Discovering: bool(a.discovering),
		})
	}
	var devices []BtDevice
	for i := C.size_t(0); i < C.sinty_bt_device_count(st); i++ {
		d := C.sinty_bt_device_at(st, i)
		devices = append(devices, BtDevice{
			Path: text(d.path[:]), Adapter: text(d.adapter[:]), Address: text(d.address[:]), Alias: text(d.alias[:]),
			Name: text(d.name[:]), Icon: text(d.icon[:]), Class: uint32(d.device_class), RSSI: int16(d.rssi),
			HasRSSI: bool(d.has_rssi), Battery: int(d.battery), Paired: bool(d.paired), Trusted: bool(d.trusted),
			Blocked: bool(d.blocked), Connected: bool(d.connected),
		})
	}
	return adapters, devices, nil
}

func (b *Bluetooth) setAdapter(path string, which C.int, on bool) error {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	return check(C.sinty_bt_set_adapter(b.session(), p, which, C.bool(on)))
}

func (b *Bluetooth) SetPowered(adapter string, on bool) error {
	return b.setAdapter(adapter, C.SINTY_BT_POWERED, on)
}

func (b *Bluetooth) SetDiscoverable(adapter string, on bool) error {
	return b.setAdapter(adapter, C.SINTY_BT_DISCOVERABLE, on)
}

func (b *Bluetooth) SetPairable(adapter string, on bool) error {
	return b.setAdapter(adapter, C.SINTY_BT_PAIRABLE, on)
}

func (b *Bluetooth) setDevice(path string, which C.int, on bool) error {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	return check(C.sinty_bt_set_device(b.session(), p, which, C.bool(on)))
}

func (b *Bluetooth) SetTrusted(device string, on bool) error {
	return b.setDevice(device, C.SINTY_BT_TRUSTED, on)
}

func (b *Bluetooth) SetBlocked(device string, on bool) error {
	return b.setDevice(device, C.SINTY_BT_BLOCKED, on)
}

func (b *Bluetooth) SetAlias(path, alias string) error {
	p, a := C.CString(path), C.CString(alias)
	defer C.free(unsafe.Pointer(p))
	defer C.free(unsafe.Pointer(a))
	return check(C.sinty_bt_set_alias(b.session(), p, a))
}

func (b *Bluetooth) action(device string, action C.int) error {
	p := C.CString(device)
	defer C.free(unsafe.Pointer(p))
	return check(C.sinty_bt_device_action(b.session(), p, action))
}

func (b *Bluetooth) Connect(device string) error {
	return b.action(device, C.SINTY_BT_CONNECT)
}

func (b *Bluetooth) Disconnect(device string) error {
	return b.action(device, C.SINTY_BT_DISCONNECT)
}

func (b *Bluetooth) Pair(device string) error {
	return b.action(device, C.SINTY_BT_PAIR)
}

func (b *Bluetooth) CancelPairing(device string) error {
	return b.action(device, C.SINTY_BT_CANCEL_PAIRING)
}

func (b *Bluetooth) Remove(device string) error {
	p := C.CString(device)
	defer C.free(unsafe.Pointer(p))
	return check(C.sinty_bt_remove(b.session(), p))
}

func (b *Bluetooth) Discovery(adapter string, on bool) error {
	p := C.CString(adapter)
	defer C.free(unsafe.Pointer(p))
	return check(C.sinty_bt_discovery(b.session(), p, C.bool(on)))
}

type Notification struct {
	AppName      string
	Icon         string
	Summary      string
	Body         string
	Category     string
	DesktopEntry string
	Actions      []string
	ReplacesID   uint32
	TimeoutMs    int32
	Urgency      uint8
	Transient    bool
}

func Notify(n Notification) (uint32, error) {
	var q C.SintyNotification
	var owned []*C.char
	str := func(s string) *C.char {
		if s == "" {
			return nil
		}
		p := C.CString(s)
		owned = append(owned, p)
		return p
	}
	defer func() {
		for _, p := range owned {
			C.free(unsafe.Pointer(p))
		}
	}()
	q.app_name, q.icon, q.summary, q.body = str(n.AppName), str(n.Icon), str(n.Summary), str(n.Body)
	q.category, q.desktop_entry = str(n.Category), str(n.DesktopEntry)
	if len(n.Actions) > 0 {
		arr := (*[32]*C.char)(C.malloc(C.size_t(32 * unsafe.Sizeof(uintptr(0)))))
		defer C.free(unsafe.Pointer(arr))
		if len(n.Actions) > len(arr) {
			return 0, syscall.EINVAL
		}
		for i, a := range n.Actions {
			if a == "" {
				return 0, syscall.EINVAL
			}
			arr[i] = str(a)
		}
		q.actions = &arr[0]
		q.n_actions = C.size_t(len(n.Actions))
	}
	q.replaces_id, q.timeout_ms, q.urgency, q.transient = C.uint32_t(n.ReplacesID), C.int32_t(n.TimeoutMs), C.uint8_t(n.Urgency), C.bool(n.Transient)
	var id C.uint32_t
	if err := check(C.sinty_notify_send(&q, &id)); err != nil {
		return 0, err
	}
	return uint32(id), nil
}

func CloseNotification(id uint32) error {
	return check(C.sinty_notify_close(C.uint32_t(id)))
}

type User struct {
	Path           string
	Name           string
	RealName       string
	Home           string
	Shell          string
	Icon           string
	Language       string
	Email          string
	UID            uint64
	Administrator  bool
	Locked         bool
	AutomaticLogin bool
	SystemAccount  bool
}

func userFrom(u *C.SintyUser) User {
	return User{
		Path: text(u.path[:]), Name: text(u.name[:]), RealName: text(u.real_name[:]), Home: text(u.home[:]),
		Shell: text(u.shell[:]), Icon: text(u.icon[:]), Language: text(u.language[:]), Email: text(u.email[:]),
		UID: uint64(u.uid), Administrator: u.account_type == 1, Locked: bool(u.locked),
		AutomaticLogin: bool(u.automatic_login), SystemAccount: bool(u.system_account),
	}
}

func Users() ([]User, error) {
	var l *C.SintyUsers
	if err := check(C.sinty_accounts_users(&l)); err != nil {
		return nil, err
	}
	defer C.sinty_accounts_users_free(l)
	var out []User
	for i := C.size_t(0); i < C.sinty_accounts_users_count(l); i++ {
		out = append(out, userFrom(C.sinty_accounts_users_at(l, i)))
	}
	return out, nil
}

func FindUser(name string) (User, error) {
	n := C.CString(name)
	defer C.free(unsafe.Pointer(n))
	var u C.SintyUser
	if err := check(C.sinty_accounts_find(n, &u)); err != nil {
		return User{}, err
	}
	return userFrom(&u), nil
}

func SetUserLanguage(path, lang string) error {
	p, l := C.CString(path), C.CString(lang)
	defer C.free(unsafe.Pointer(p))
	defer C.free(unsafe.Pointer(l))
	return check(C.sinty_accounts_set_text(p, C.SINTY_USER_LANGUAGE, l))
}

func SetUserRealName(path, name string) error {
	p, l := C.CString(path), C.CString(name)
	defer C.free(unsafe.Pointer(p))
	defer C.free(unsafe.Pointer(l))
	return check(C.sinty_accounts_set_text(p, C.SINTY_USER_REAL_NAME, l))
}

func Hostname() (string, string, error) {
	var n C.SintyHostNames
	if err := check(C.sinty_hostname_get(&n)); err != nil {
		return "", "", err
	}
	return text(n.static_name[:]), text(n.pretty[:]), nil
}

func SetHostname(static, pretty string) error {
	s, p := C.CString(static), C.CString(pretty)
	defer C.free(unsafe.Pointer(s))
	defer C.free(unsafe.Pointer(p))
	return check(C.sinty_hostname_set(s, p))
}

func SystemLanguage() (string, error) {
	var buf [64]C.char
	if err := check(C.sinty_language_get(&buf[0], C.size_t(len(buf)))); err != nil {
		return "", err
	}
	return text(buf[:]), nil
}

func SetSystemLanguage(lang string) error {
	l := C.CString(lang)
	defer C.free(unsafe.Pointer(l))
	return check(C.sinty_language_set(l))
}

type Printer struct {
	Name, URI, Info, Location, MakeModel string
	State, Queued                        uint32
	Accepting, Default                   bool
}

type PrintJob struct {
	ID, State  uint32
	Name       string
	PrinterURI string
	User       string
	Created    int64
	KBytes     uint32
}

func printServer(server string) *C.char {
	if server == "" {
		return nil
	}
	return C.CString(server)
}

func printerFrom(p *C.SintyPrinter) Printer {
	return Printer{
		Name: text(p.name[:]), URI: text(p.uri[:]), Info: text(p.info[:]), Location: text(p.location[:]),
		MakeModel: text(p.make_model[:]), State: uint32(p.state), Queued: uint32(p.queued),
		Accepting: bool(p.accepting), Default: bool(p.is_default),
	}
}

func Printers(server string) ([]Printer, error) {
	s := printServer(server)
	defer C.free(unsafe.Pointer(s))
	var l *C.SintyPrinters
	if err := check(C.sinty_print_printers(s, &l)); err != nil {
		return nil, err
	}
	defer C.sinty_print_printers_free(l)
	var out []Printer
	for i := C.size_t(0); i < C.sinty_print_printers_count(l); i++ {
		out = append(out, printerFrom(C.sinty_print_printers_at(l, i)))
	}
	return out, nil
}

func DefaultPrinter(server string) (string, error) {
	s := printServer(server)
	defer C.free(unsafe.Pointer(s))
	var buf [128]C.char
	if err := check(C.sinty_print_default(s, &buf[0], C.size_t(len(buf)))); err != nil {
		return "", err
	}
	return text(buf[:]), nil
}

func PrinterInfo(server, queue string) (Printer, error) {
	s, q := printServer(server), C.CString(queue)
	defer C.free(unsafe.Pointer(s))
	defer C.free(unsafe.Pointer(q))
	var p C.SintyPrinter
	if err := check(C.sinty_print_printer(s, q, &p)); err != nil {
		return Printer{}, err
	}
	return printerFrom(&p), nil
}

func PrintJobs(server, queue string, completed bool) ([]PrintJob, error) {
	s, q := printServer(server), C.CString(queue)
	defer C.free(unsafe.Pointer(s))
	defer C.free(unsafe.Pointer(q))
	var l *C.SintyPrintJobs
	if err := check(C.sinty_print_jobs(s, q, C.bool(completed), &l)); err != nil {
		return nil, err
	}
	defer C.sinty_print_jobs_free(l)
	var out []PrintJob
	for i := C.size_t(0); i < C.sinty_print_jobs_count(l); i++ {
		j := C.sinty_print_jobs_at(l, i)
		out = append(out, PrintJob{
			ID: uint32(j.id), State: uint32(j.state), Name: text(j.name[:]), PrinterURI: text(j.printer_uri[:]),
			User: text(j.user[:]), Created: int64(j.created), KBytes: uint32(j.kbytes),
		})
	}
	return out, nil
}

func PrintFile(server, queue, path, title string, copies int) (uint32, error) {
	s, q, p, t := printServer(server), C.CString(queue), C.CString(path), C.CString(title)
	defer C.free(unsafe.Pointer(s))
	defer C.free(unsafe.Pointer(q))
	defer C.free(unsafe.Pointer(p))
	defer C.free(unsafe.Pointer(t))
	var id C.uint32_t
	if err := check(C.sinty_print_file(s, q, p, t, C.int(copies), &id)); err != nil {
		return 0, err
	}
	return uint32(id), nil
}

func CancelPrintJob(server, queue string, id uint32) error {
	s, q := printServer(server), C.CString(queue)
	defer C.free(unsafe.Pointer(s))
	defer C.free(unsafe.Pointer(q))
	return check(C.sinty_print_cancel(s, q, C.uint32_t(id)))
}

func ClipboardTypes(primary bool) ([]string, error) {
	var list *C.SintyTextList
	if err := check(C.sinty_clipboard_types(C.bool(primary), &list)); err != nil {
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

func ClipboardRead(primary bool, mime string) ([]byte, error) {
	m := C.CString(mime)
	defer C.free(unsafe.Pointer(m))
	var data *C.uint8_t
	var n C.size_t
	if err := check(C.sinty_clipboard_read(C.bool(primary), m, &data, &n)); err != nil {
		return nil, err
	}
	defer C.sinty_bytes_free(data, n)
	return C.GoBytes(unsafe.Pointer(data), C.int(n)), nil
}

type ClipboardHolder struct {
	h *C.SintyClipboardHolder
}

func ClipboardSet(data []byte, mimes []string, primary bool) (*ClipboardHolder, error) {
	if len(mimes) == 0 {
		return nil, syscall.EINVAL
	}
	cm := C.malloc(C.size_t(len(mimes)) * C.size_t(unsafe.Sizeof(uintptr(0))))
	defer C.free(cm)
	list := unsafe.Slice((**C.char)(cm), len(mimes))
	for i, m := range mimes {
		list[i] = C.CString(m)
		defer C.free(unsafe.Pointer(list[i]))
	}
	var buf *C.uint8_t
	if len(data) > 0 {
		buf = (*C.uint8_t)(C.CBytes(data))
		defer C.free(unsafe.Pointer(buf))
	}
	var h *C.SintyClipboardHolder
	if err := check(C.sinty_clipboard_set(buf, C.size_t(len(data)), (**C.char)(cm), C.size_t(len(mimes)), C.bool(primary), &h)); err != nil {
		return nil, err
	}
	return &ClipboardHolder{h: h}, nil
}

func (c *ClipboardHolder) Active() bool {
	return c.h != nil && bool(C.sinty_clipboard_holder_active(c.h))
}

func (c *ClipboardHolder) Close() {
	if c.h != nil {
		C.sinty_clipboard_holder_free(c.h)
		c.h = nil
	}
}

type SettingsKey struct {
	Schema, Path, Key string
}

func (k SettingsKey) c() (*C.char, *C.char, *C.char) {
	var p *C.char
	if k.Path != "" {
		p = C.CString(k.Path)
	}
	return C.CString(k.Schema), p, C.CString(k.Key)
}

func freeKey(s, p, k *C.char) {
	C.free(unsafe.Pointer(s))
	C.free(unsafe.Pointer(p))
	C.free(unsafe.Pointer(k))
}

func (k SettingsKey) Bool() (bool, error) {
	s, p, n := k.c()
	defer freeKey(s, p, n)
	var v C.bool
	err := check(C.sinty_settings_get_bool(s, p, n, &v))
	return bool(v), err
}

func (k SettingsKey) Int() (int64, error) {
	s, p, n := k.c()
	defer freeKey(s, p, n)
	var v C.int64_t
	err := check(C.sinty_settings_get_int(s, p, n, &v))
	return int64(v), err
}

func (k SettingsKey) Double() (float64, error) {
	s, p, n := k.c()
	defer freeKey(s, p, n)
	var v C.double
	err := check(C.sinty_settings_get_double(s, p, n, &v))
	return float64(v), err
}

func (k SettingsKey) String() (string, error) {
	s, p, n := k.c()
	defer freeKey(s, p, n)
	var v *C.char
	if err := check(C.sinty_settings_get_string(s, p, n, &v)); err != nil {
		return "", err
	}
	defer C.sinty_string_free(v)
	return C.GoString(v), nil
}

func (k SettingsKey) Strv() ([]string, error) {
	s, p, n := k.c()
	defer freeKey(s, p, n)
	var list *C.SintyTextList
	if err := check(C.sinty_settings_get_strv(s, p, n, &list)); err != nil {
		return nil, err
	}
	defer C.sinty_text_list_free(list)
	count := int(C.sinty_text_list_count(list))
	out := make([]string, 0, count)
	for i := 0; i < count; i++ {
		out = append(out, C.GoString(C.sinty_text_list_at(list, C.size_t(i))))
	}
	return out, nil
}

func (k SettingsKey) Writable() (bool, error) {
	s, p, n := k.c()
	defer freeKey(s, p, n)
	var v C.bool
	err := check(C.sinty_settings_writable(s, p, n, &v))
	return bool(v), err
}

func (k SettingsKey) SetBool(v bool) error {
	s, p, n := k.c()
	defer freeKey(s, p, n)
	return check(C.sinty_settings_set_bool(s, p, n, C.bool(v)))
}

func (k SettingsKey) SetInt(v int64) error {
	s, p, n := k.c()
	defer freeKey(s, p, n)
	return check(C.sinty_settings_set_int(s, p, n, C.int64_t(v)))
}

func (k SettingsKey) SetDouble(v float64) error {
	s, p, n := k.c()
	defer freeKey(s, p, n)
	return check(C.sinty_settings_set_double(s, p, n, C.double(v)))
}

func (k SettingsKey) SetString(v string) error {
	s, p, n := k.c()
	defer freeKey(s, p, n)
	cv := C.CString(v)
	defer C.free(unsafe.Pointer(cv))
	return check(C.sinty_settings_set_string(s, p, n, cv))
}

func (k SettingsKey) SetStrv(v []string) error {
	s, p, n := k.c()
	defer freeKey(s, p, n)
	var arr unsafe.Pointer
	if len(v) > 0 {
		arr = C.malloc(C.size_t(len(v)) * C.size_t(unsafe.Sizeof(uintptr(0))))
		defer C.free(arr)
		list := unsafe.Slice((**C.char)(arr), len(v))
		for i, item := range v {
			list[i] = C.CString(item)
			defer C.free(unsafe.Pointer(list[i]))
		}
	}
	return check(C.sinty_settings_set_strv(s, p, n, (**C.char)(arr), C.size_t(len(v))))
}

func (k SettingsKey) Reset() error {
	s, p, n := k.c()
	defer freeKey(s, p, n)
	return check(C.sinty_settings_reset(s, p, n))
}

type LogEntry struct {
	Realtime, Monotonic uint64
	Seq                 uint64
	PID                 int32
	Priority            uint8
	BootID              string
	Identifier          string
	Unit                string
	Message             string
}

type LogBoot struct {
	ID          string
	First, Last uint64
	Entries     uint64
}

func logEntries(l *C.SintyLogEntries) []LogEntry {
	defer C.sinty_logs_entries_free(l)
	n := int(C.sinty_logs_entries_count(l))
	out := make([]LogEntry, 0, n)
	for i := 0; i < n; i++ {
		e := C.sinty_logs_entries_at(l, C.size_t(i))
		out = append(out, LogEntry{
			Realtime: uint64(e.realtime_usec), Monotonic: uint64(e.monotonic_usec), Seq: uint64(e.seq),
			PID: int32(e.pid), Priority: uint8(e.priority), BootID: text(e.boot_id[:]),
			Identifier: text(e.identifier[:]), Unit: text(e.unit[:]), Message: text(e.message[:]),
		})
	}
	return out
}

func optString(s string) *C.char {
	if s == "" {
		return nil
	}
	return C.CString(s)
}

func KernelLog() ([]LogEntry, error) {
	var l *C.SintyLogEntries
	if err := check(C.sinty_logs_kernel(&l)); err != nil {
		return nil, err
	}
	return logEntries(l), nil
}

func Journal(dir, boot string, maxPriority int, unit string, limit int) ([]LogEntry, error) {
	d, b, u := optString(dir), optString(boot), optString(unit)
	defer C.free(unsafe.Pointer(d))
	defer C.free(unsafe.Pointer(b))
	defer C.free(unsafe.Pointer(u))
	var l *C.SintyLogEntries
	if err := check(C.sinty_logs_journal(d, b, C.int(maxPriority), u, C.size_t(limit), &l)); err != nil {
		return nil, err
	}
	return logEntries(l), nil
}

func JournalBoots(dir string) ([]LogBoot, error) {
	d := optString(dir)
	defer C.free(unsafe.Pointer(d))
	var l *C.SintyLogBoots
	if err := check(C.sinty_logs_boots(d, &l)); err != nil {
		return nil, err
	}
	defer C.sinty_logs_boots_free(l)
	n := int(C.sinty_logs_boots_count(l))
	out := make([]LogBoot, 0, n)
	for i := 0; i < n; i++ {
		b := C.sinty_logs_boots_at(l, C.size_t(i))
		out = append(out, LogBoot{ID: text(b.id[:]), First: uint64(b.first_usec), Last: uint64(b.last_usec), Entries: uint64(b.entries)})
	}
	return out, nil
}

func JournalAvailable(dir string) bool {
	d := optString(dir)
	defer C.free(unsafe.Pointer(d))
	return bool(C.sinty_logs_journal_available(d))
}

type Conf struct {
	c *C.SintyConf
}

func OpenConf(path string) (*Conf, error) {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	var c *C.SintyConf
	if err := check(C.sinty_conf_open(p, &c)); err != nil {
		return nil, err
	}
	return &Conf{c: c}, nil
}

func ParseConf(text string) (*Conf, error) {
	t := C.CString(text)
	defer C.free(unsafe.Pointer(t))
	var c *C.SintyConf
	if err := check(C.sinty_conf_parse(t, C.size_t(len(text)), &c)); err != nil {
		return nil, err
	}
	return &Conf{c: c}, nil
}

func FindConf(name string) (string, error) {
	n := C.CString(name)
	defer C.free(unsafe.Pointer(n))
	var buf [4096]C.char
	if err := check(C.sinty_conf_find(n, &buf[0], C.size_t(len(buf)))); err != nil {
		return "", err
	}
	return text(buf[:]), nil
}

func (f *Conf) Close() {
	if f.c != nil {
		C.sinty_conf_free(f.c)
		f.c = nil
	}
}

func cpair(group, key string) (*C.char, *C.char) {
	return C.CString(group), C.CString(key)
}

func (f *Conf) String(group, key string) (string, error) {
	g, k := cpair(group, key)
	defer C.free(unsafe.Pointer(g))
	defer C.free(unsafe.Pointer(k))
	var v *C.char
	if err := check(C.sinty_conf_get_string(f.c, g, k, &v)); err != nil {
		return "", err
	}
	defer C.sinty_string_free(v)
	return C.GoString(v), nil
}

func (f *Conf) LocaleString(group, key, locale string) (string, error) {
	g, k := cpair(group, key)
	defer C.free(unsafe.Pointer(g))
	defer C.free(unsafe.Pointer(k))
	l := C.CString(locale)
	defer C.free(unsafe.Pointer(l))
	var v *C.char
	if err := check(C.sinty_conf_get_locale_string(f.c, g, k, l, &v)); err != nil {
		return "", err
	}
	defer C.sinty_string_free(v)
	return C.GoString(v), nil
}

func (f *Conf) Bool(group, key string) (bool, error) {
	g, k := cpair(group, key)
	defer C.free(unsafe.Pointer(g))
	defer C.free(unsafe.Pointer(k))
	var v C.bool
	err := check(C.sinty_conf_get_bool(f.c, g, k, &v))
	return bool(v), err
}

func (f *Conf) Int(group, key string) (int64, error) {
	g, k := cpair(group, key)
	defer C.free(unsafe.Pointer(g))
	defer C.free(unsafe.Pointer(k))
	var v C.int64_t
	err := check(C.sinty_conf_get_int(f.c, g, k, &v))
	return int64(v), err
}

func textList(l *C.SintyTextList) []string {
	defer C.sinty_text_list_free(l)
	n := int(C.sinty_text_list_count(l))
	out := make([]string, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, C.GoString(C.sinty_text_list_at(l, C.size_t(i))))
	}
	return out
}

func (f *Conf) List(group, key string) ([]string, error) {
	g, k := cpair(group, key)
	defer C.free(unsafe.Pointer(g))
	defer C.free(unsafe.Pointer(k))
	var l *C.SintyTextList
	if err := check(C.sinty_conf_get_list(f.c, g, k, &l)); err != nil {
		return nil, err
	}
	return textList(l), nil
}

func (f *Conf) SetString(group, key, value string) error {
	g, k := cpair(group, key)
	defer C.free(unsafe.Pointer(g))
	defer C.free(unsafe.Pointer(k))
	v := C.CString(value)
	defer C.free(unsafe.Pointer(v))
	return check(C.sinty_conf_set_string(f.c, g, k, v))
}

func (f *Conf) SetBool(group, key string, value bool) error {
	g, k := cpair(group, key)
	defer C.free(unsafe.Pointer(g))
	defer C.free(unsafe.Pointer(k))
	return check(C.sinty_conf_set_bool(f.c, g, k, C.bool(value)))
}

func (f *Conf) SetInt(group, key string, value int64) error {
	g, k := cpair(group, key)
	defer C.free(unsafe.Pointer(g))
	defer C.free(unsafe.Pointer(k))
	return check(C.sinty_conf_set_int(f.c, g, k, C.int64_t(value)))
}

func (f *Conf) SetList(group, key string, values []string) error {
	g, k := cpair(group, key)
	defer C.free(unsafe.Pointer(g))
	defer C.free(unsafe.Pointer(k))
	var arr unsafe.Pointer
	if len(values) > 0 {
		arr = C.malloc(C.size_t(len(values)) * C.size_t(unsafe.Sizeof(uintptr(0))))
		defer C.free(arr)
		list := unsafe.Slice((**C.char)(arr), len(values))
		for i, v := range values {
			list[i] = C.CString(v)
			defer C.free(unsafe.Pointer(list[i]))
		}
	}
	return check(C.sinty_conf_set_list(f.c, g, k, (**C.char)(arr), C.size_t(len(values))))
}

func (f *Conf) Remove(group, key string) error {
	g, k := cpair(group, key)
	defer C.free(unsafe.Pointer(g))
	defer C.free(unsafe.Pointer(k))
	return check(C.sinty_conf_remove(f.c, g, k))
}

func (f *Conf) Groups() ([]string, error) {
	var l *C.SintyTextList
	if err := check(C.sinty_conf_groups(f.c, &l)); err != nil {
		return nil, err
	}
	return textList(l), nil
}

func (f *Conf) Keys(group string) ([]string, error) {
	g := C.CString(group)
	defer C.free(unsafe.Pointer(g))
	var l *C.SintyTextList
	if err := check(C.sinty_conf_keys(f.c, g, &l)); err != nil {
		return nil, err
	}
	return textList(l), nil
}

func (f *Conf) Save(path string) error {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	return check(C.sinty_conf_save(f.c, p))
}

type NetLink struct {
	Index     int32
	Name      string
	Kind      string
	MAC       string
	Flags     uint32
	MTU       uint32
	OperState uint8
	Wireless  bool
	RxBytes   uint64
	TxBytes   uint64
}

type NetAddress struct {
	Index   int32
	Family  uint8
	Prefix  uint8
	Scope   uint8
	Address string
}

type NetRoute struct {
	Oif         int32
	Family      uint8
	Prefix      uint8
	Table       uint8
	Protocol    uint8
	Scope       uint8
	Priority    uint32
	Destination string
	Gateway     string
}

const (
	NetFlagUp       = 0x1
	NetFlagLoopback = 0x8
	NetFlagRunning  = 0x40
	NetFlagLowerUp  = 0x10000
)

func listed(rc C.int) (int, error) {
	if rc < 0 {
		return 0, syscall.Errno(-rc)
	}
	return int(rc), nil
}

func grow[T any](call func([]T) (int, error)) ([]T, error) {
	for size := 64; ; size *= 4 {
		buf := make([]T, size)
		n, err := call(buf)
		if errors.Is(err, syscall.EFBIG) && size < 1<<16 {
			continue
		}
		if err != nil {
			return nil, err
		}
		return buf[:n], nil
	}
}

func netLink(l *C.SintyNetLink) NetLink {
	return NetLink{
		Index:     int32(l.index),
		Name:      text(l.name[:]),
		Kind:      text(l.kind[:]),
		MAC:       text(l.mac[:]),
		Flags:     uint32(l.flags),
		MTU:       uint32(l.mtu),
		OperState: uint8(l.operstate),
		Wireless:  l.wireless != 0,
		RxBytes:   uint64(l.rx_bytes),
		TxBytes:   uint64(l.tx_bytes),
	}
}

func NetLinks() ([]NetLink, error) {
	raw, err := grow(func(b []C.SintyNetLink) (int, error) {
		return listed(C.sinty_net_links(&b[0], C.size_t(len(b))))
	})
	if err != nil {
		return nil, err
	}
	out := make([]NetLink, len(raw))
	for i := range raw {
		out[i] = netLink(&raw[i])
	}
	return out, nil
}

func NetLinkByName(name string) (NetLink, error) {
	c := C.CString(name)
	defer C.free(unsafe.Pointer(c))
	var l C.SintyNetLink
	if err := check(C.sinty_net_link(c, &l)); err != nil {
		return NetLink{}, err
	}
	return netLink(&l), nil
}

func NetAddresses() ([]NetAddress, error) {
	raw, err := grow(func(b []C.SintyNetAddress) (int, error) {
		return listed(C.sinty_net_addresses(&b[0], C.size_t(len(b))))
	})
	if err != nil {
		return nil, err
	}
	out := make([]NetAddress, len(raw))
	for i, a := range raw {
		out[i] = NetAddress{int32(a.index), uint8(a.family), uint8(a.prefix), uint8(a.scope), text(a.address[:])}
	}
	return out, nil
}

func NetRoutes() ([]NetRoute, error) {
	raw, err := grow(func(b []C.SintyNetRoute) (int, error) {
		return listed(C.sinty_net_routes(&b[0], C.size_t(len(b))))
	})
	if err != nil {
		return nil, err
	}
	out := make([]NetRoute, len(raw))
	for i, r := range raw {
		out[i] = NetRoute{int32(r.oif), uint8(r.family), uint8(r.prefix), uint8(r.table), uint8(r.protocol), uint8(r.scope), uint32(r.priority), text(r.destination[:]), text(r.gateway[:])}
	}
	return out, nil
}

func strings2(a, b string, f func(*C.char, *C.char) C.int) error {
	ca, cb := C.CString(a), C.CString(b)
	defer C.free(unsafe.Pointer(ca))
	defer C.free(unsafe.Pointer(cb))
	return check(f(ca, cb))
}

func NetSetUp(name string, up bool) error {
	c := C.CString(name)
	defer C.free(unsafe.Pointer(c))
	return check(C.sinty_net_set_up(c, C.bool(up)))
}

func NetSetMTU(name string, mtu uint32) error {
	c := C.CString(name)
	defer C.free(unsafe.Pointer(c))
	return check(C.sinty_net_set_mtu(c, C.uint32_t(mtu)))
}

func NetCreateLink(name, kind string) error {
	return strings2(name, kind, func(a, b *C.char) C.int { return C.sinty_net_link_create(a, b) })
}

func NetDeleteLink(name string) error {
	c := C.CString(name)
	defer C.free(unsafe.Pointer(c))
	return check(C.sinty_net_link_delete(c))
}

func NetAddAddress(name, cidr string) error {
	return strings2(name, cidr, func(a, b *C.char) C.int { return C.sinty_net_address_add(a, b) })
}

func NetDeleteAddress(name, cidr string) error {
	return strings2(name, cidr, func(a, b *C.char) C.int { return C.sinty_net_address_delete(a, b) })
}

func netRoute(dst, gateway, dev string, metric uint32, add bool) error {
	cd, cg, cv := C.CString(dst), C.CString(gateway), C.CString(dev)
	defer C.free(unsafe.Pointer(cd))
	defer C.free(unsafe.Pointer(cg))
	defer C.free(unsafe.Pointer(cv))
	if add {
		return check(C.sinty_net_route_add(cd, cg, cv, C.uint32_t(metric)))
	}
	return check(C.sinty_net_route_delete(cd, cg, cv, C.uint32_t(metric)))
}

func NetAddRoute(dst, gateway, dev string, metric uint32) error {
	return netRoute(dst, gateway, dev, metric, true)
}

func NetDeleteRoute(dst, gateway, dev string, metric uint32) error {
	return netRoute(dst, gateway, dev, metric, false)
}

type WgDevice struct {
	IfIndex       int32
	ListenPort    uint16
	FwMark        uint32
	PublicKey     string
	HasPrivateKey bool
	Peers         int
}

type WgPeer struct {
	PublicKey        string
	HasPresharedKey  bool
	Keepalive        uint16
	Endpoint         string
	AllowedIPs       string
	AllowedCount     int
	LastHandshake    int64
	RxBytes, TxBytes uint64
}

func WgGenerateKey() (string, error) {
	var out [45]C.char
	if err := check(C.sinty_wg_generate_key(&out[0])); err != nil {
		return "", err
	}
	return text(out[:]), nil
}

func WgPublicKey(private string) (string, error) {
	c := C.CString(private)
	defer C.free(unsafe.Pointer(c))
	var out [45]C.char
	if err := check(C.sinty_wg_public_key(c, &out[0])); err != nil {
		return "", err
	}
	return text(out[:]), nil
}

func WgConfigure(ifname, conf string) error {
	return strings2(ifname, conf, func(a, b *C.char) C.int { return C.sinty_wg_configure(a, b) })
}

func WgApply(ifname, conf string) error {
	return strings2(ifname, conf, func(a, b *C.char) C.int { return C.sinty_wg_apply(a, b) })
}

func WgGet(ifname string) (WgDevice, []WgPeer, error) {
	c := C.CString(ifname)
	defer C.free(unsafe.Pointer(c))
	var dev C.SintyWgDevice
	raw, err := grow(func(b []C.SintyWgPeer) (int, error) {
		n, err := listed(C.sinty_wg_get(c, &dev, &b[0], C.size_t(len(b))))
		if err == nil && int(dev.peers) > n {
			return 0, syscall.EFBIG
		}
		return n, err
	})
	if err != nil {
		return WgDevice{}, nil, err
	}
	d := WgDevice{int32(dev.ifindex), uint16(dev.listen_port), uint32(dev.fwmark), text(dev.public_key[:]), dev.has_private_key != 0, int(dev.peers)}
	peers := make([]WgPeer, len(raw))
	for i, p := range raw {
		peers[i] = WgPeer{text(p.public_key[:]), p.has_preshared_key != 0, uint16(p.keepalive), text(p.endpoint[:]), text(p.allowed_ips[:]), int(p.allowed_count), int64(p.last_handshake), uint64(p.rx_bytes), uint64(p.tx_bytes)}
	}
	return d, peers, nil
}

const (
	WifiSecPrivacy = 1
	WifiSecWPA     = 2
	WifiSecPSK     = 4
	WifiSecSAE     = 8
	WifiSec8021X   = 16
	WifiSecOWE     = 32
)

type WifiInterface struct {
	Index     int32
	Wiphy     uint32
	Type      uint32
	Frequency uint32
	Name      string
	MAC       string
	SSID      string
}

type WifiBss struct {
	BSSID      string
	SSID       string
	Frequency  uint32
	SignalMBm  int32
	SeenMsAgo  uint32
	Security   uint32
	Associated bool
}

type WifiStation struct {
	MAC           string
	SignalDBm     int32
	TxBitrate100k uint32
	RxBitrate100k uint32
	ConnectedS    uint32
	InactiveMs    uint32
	RxBytes       uint64
	TxBytes       uint64
}

func WifiInterfaces() ([]WifiInterface, error) {
	raw, err := grow(func(b []C.SintyWifiInterface) (int, error) {
		return listed(C.sinty_wifi_interfaces(&b[0], C.size_t(len(b))))
	})
	if err != nil {
		return nil, err
	}
	out := make([]WifiInterface, len(raw))
	for i, w := range raw {
		out[i] = WifiInterface{int32(w.index), uint32(w.wiphy), uint32(w.iftype), uint32(w.frequency), text(w.name[:]), text(w.mac[:]), text(w.ssid[:])}
	}
	return out, nil
}

func WifiScanResults(ifname string) ([]WifiBss, error) {
	c := C.CString(ifname)
	defer C.free(unsafe.Pointer(c))
	raw, err := grow(func(b []C.SintyWifiBss) (int, error) {
		return listed(C.sinty_wifi_scan_results(c, &b[0], C.size_t(len(b))))
	})
	if err != nil {
		return nil, err
	}
	out := make([]WifiBss, len(raw))
	for i, b := range raw {
		out[i] = WifiBss{text(b.bssid[:]), text(b.ssid[:]), uint32(b.frequency), int32(b.signal_mbm), uint32(b.seen_ms_ago), uint32(b.security), b.status == 1}
	}
	return out, nil
}

func WifiStations(ifname string) ([]WifiStation, error) {
	c := C.CString(ifname)
	defer C.free(unsafe.Pointer(c))
	raw, err := grow(func(b []C.SintyWifiStation) (int, error) {
		return listed(C.sinty_wifi_stations(c, &b[0], C.size_t(len(b))))
	})
	if err != nil {
		return nil, err
	}
	out := make([]WifiStation, len(raw))
	for i, s := range raw {
		out[i] = WifiStation{text(s.mac[:]), int32(s.signal_dbm), uint32(s.tx_bitrate_100k), uint32(s.rx_bitrate_100k), uint32(s.connected_s), uint32(s.inactive_ms), uint64(s.rx_bytes), uint64(s.tx_bytes)}
	}
	return out, nil
}

func WifiScan(ifname, ssid string, timeoutMs int32) error {
	ci, cs := C.CString(ifname), C.CString(ssid)
	defer C.free(unsafe.Pointer(ci))
	defer C.free(unsafe.Pointer(cs))
	return check(C.sinty_wifi_scan(ci, cs, C.int32_t(timeoutMs)))
}

func WifiSetPowerSave(ifname string, on bool) error {
	c := C.CString(ifname)
	defer C.free(unsafe.Pointer(c))
	v := C.int(0)
	if on {
		v = 1
	}
	return check(C.sinty_wifi_set_power_save(c, v))
}

func WifiPowerSave(ifname string) (bool, error) {
	c := C.CString(ifname)
	defer C.free(unsafe.Pointer(c))
	r := C.sinty_wifi_power_save(c)
	if r < 0 {
		return false, check(r)
	}
	return r == 1, nil
}
