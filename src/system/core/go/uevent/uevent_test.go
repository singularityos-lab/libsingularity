package uevent

import (
	"context"
	"encoding/binary"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestHashesMatchLibudev(t *testing.T) {
	for s, want := range map[string]uint32{
		"power_supply": 0xb1acbcca, "pci": 0x59163b92, "usb": 0x577c5e5, "usb_device": 0x27f8f50c,
		"block": 0xf0031db7, "net": 0xa74d3cc8, "a": 0x92685f5e, "ab": 0x1aa14063, "abc": 0x13577c9b,
	} {
		if got := murmur2([]byte(s)); got != want {
			t.Errorf("%s: %#x, want %#x", s, got, want)
		}
	}
}

func encode(subsystem, devtype string, props ...string) []byte {
	body := strings.Join(append([]string{"SUBSYSTEM=" + subsystem}, props...), "\x00") + "\x00"
	if devtype != "" {
		body = "DEVTYPE=" + devtype + "\x00" + body
	}
	h := make([]byte, udevHeader)
	copy(h, "libudev\x00")
	binary.BigEndian.PutUint32(h[8:], udevMagic)
	binary.LittleEndian.PutUint32(h[12:], udevHeader)
	binary.LittleEndian.PutUint32(h[16:], udevHeader)
	binary.LittleEndian.PutUint32(h[20:], uint32(len(body)))
	binary.BigEndian.PutUint32(h[24:], murmur2([]byte(subsystem)))
	if devtype != "" {
		binary.BigEndian.PutUint32(h[28:], murmur2([]byte(devtype)))
	}
	return append(h, body...)
}

func TestKernelEventsAreParsedAndFiltered(t *testing.T) {
	m := &Monitor{matches: []Match{{Subsystem: "power_supply"}}, check: true}
	kernel := &unix.SockaddrNetlink{Pid: 0}
	msg := []byte("change@/devices/BAT0\x00ACTION=change\x00DEVPATH=/devices/BAT0\x00SUBSYSTEM=power_supply\x00SEQNUM=7\x00")
	ev, ok := m.parse(msg, kernel)
	if !ok || ev.Action() != "change" || ev.DevPath() != "/devices/BAT0" || ev.Get("SEQNUM") != "7" || ev.Get("SEQ") != "" {
		t.Fatalf("%v %q %q", ok, ev.Action(), ev.DevPath())
	}
	if _, ok := m.parse([]byte("add@/devices/eth0\x00ACTION=add\x00SUBSYSTEM=net\x00"), kernel); ok {
		t.Fatal("another subsystem passed")
	}
	if _, ok := m.parse(msg, &unix.SockaddrNetlink{Pid: 4242}); ok {
		t.Fatal("a kernel event from a process was accepted")
	}
}

func TestUdevHeaderIsChecked(t *testing.T) {
	m := &Monitor{udev: true, check: true}
	from := &unix.SockaddrNetlink{Pid: 99}
	good := encode("block", "disk", "ACTION=add")
	if ev, ok := m.parse(good, from); !ok || ev.DevType() != "disk" || ev.Action() != "add" {
		t.Fatalf("%v %q", ok, ev.DevType())
	}
	short := append([]byte(nil), good...)
	binary.LittleEndian.PutUint32(short[20:], 4096)
	for name, msg := range map[string][]byte{"length": short, "prefix": append([]byte("libudeX\x00"), good[8:]...), "truncated": good[:20]} {
		if _, ok := m.parse(msg, from); ok {
			t.Errorf("%s accepted", name)
		}
	}
	if _, ok := m.parse(good, &unix.SockaddrNetlink{Pid: 0}); ok {
		t.Fatal("a udev event from the kernel was accepted")
	}
}

func TestTheKernelDropsOtherSubsystems(t *testing.T) {
	dir := t.TempDir()
	old := udevControl
	udevControl = filepath.Join(dir, "control")
	t.Cleanup(func() { udevControl = old })
	if err := os.WriteFile(udevControl, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	m, err := Open(Match{Subsystem: "power_supply"}, Match{Subsystem: "usb", DevType: "usb_device"})
	if err != nil {
		t.Skipf("no uevent socket here: %v", err)
	}
	if !m.Filtered() {
		t.Fatal("not filtered with a device manager running")
	}
	m.check = false
	tx, err := unix.Socket(unix.AF_NETLINK, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, unix.NETLINK_KOBJECT_UEVENT)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(tx)
	if err := unix.Bind(tx, &unix.SockaddrNetlink{Family: unix.AF_NETLINK}); err != nil {
		t.Fatal(err)
	}
	sent := map[string][]byte{
		"net":           encode("net", "", "ACTION=add"),
		"usb interface": encode("usb", "usb_interface", "ACTION=add"),
		"battery":       encode("power_supply", "", "ACTION=change"),
		"usb device":    encode("usb", "usb_device", "ACTION=add"),
		"block":         encode("block", "disk", "ACTION=add"),
	}
	for name, msg := range sent {
		if err := unix.Sendto(tx, msg, 0, &unix.SockaddrNetlink{Family: unix.AF_NETLINK, Groups: groupUdev}); err != nil {
			unix.Close(m.fd)
			t.Skipf("cannot broadcast %s here: %v", name, err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	var got []string
	m.Run(ctx, func(ev Event, err error) {
		if err != nil {
			t.Error(err)
			return
		}
		got = append(got, ev.Subsystem()+"/"+ev.DevType())
	})
	sort.Strings(got)
	if strings.Join(got, " ") != "power_supply/ usb/usb_device" {
		t.Fatalf("delivered %q", got)
	}
}

func TestRunStopsWithTheContext(t *testing.T) {
	m, err := Open()
	if err != nil {
		t.Skipf("no uevent socket here: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- m.Run(ctx, func(Event, error) {}) }()
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not return after the context ended")
	}
}
