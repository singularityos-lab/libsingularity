package sintysystem

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestVersion(t *testing.T) {
	if major, _ := Version(); major != 1 {
		t.Fatalf("major %d", major)
	}
}

func TestOwnSocket(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skip(err)
	}
	defer l.Close()
	c, err := net.Dial("tcp", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	port := uint16(l.Addr().(*net.TCPAddr).Port)
	list, err := Sockets(true, false)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range list {
		if s.PID == int32(os.Getpid()) && s.LocalPort == port {
			return
		}
	}
	t.Fatalf("own listener on %d not found among %d sockets", port, len(list))
}

func TestSysctl(t *testing.T) {
	v, err := Sysctl("kernel.ostype")
	if err != nil {
		t.Fatal(err)
	}
	if v != "Linux" {
		t.Fatalf("ostype %q", v)
	}
}

func TestFirewallValidation(t *testing.T) {
	err := FirewallApply(true, false, []FirewallPort{{Spec: "nope", Comment: "x"}})
	if err == nil {
		t.Fatal("invalid spec accepted")
	}
}

func TestClock(t *testing.T) {
	s, err := Clock()
	if err != nil {
		t.Fatal(err)
	}
	if s.State < 0 || s.State > 5 || s.MaxErrorUs < 0 {
		t.Fatalf("clock %+v", s)
	}
	if err := SetRTC(RTCTime{Year: 2026, Month: 2, Day: 30}); err == nil {
		t.Fatal("an impossible date reached the RTC")
	}
}

func TestEsrt(t *testing.T) {
	list, err := Esrt()
	if err != nil {
		t.Skip(err)
	}
	for _, e := range list {
		if len(e.Class) != 36 {
			t.Fatalf("class %q", e.Class)
		}
	}
	if err := StageCapsule(t.TempDir(), "../evil.cap", make([]byte, 64)); err == nil {
		t.Fatal("a capsule name with a path was accepted")
	}
}

func TestPartitionTableOnImage(t *testing.T) {
	path := filepath.Join(t.TempDir(), "disk.img")
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(path, 32<<20); err != nil {
		t.Fatal(err)
	}
	if err := CreatePartitionTable(path, TableGPT); err != nil {
		t.Fatal(err)
	}
	n, err := AddPartition(path, 0, 8<<20, "", "data")
	if err != nil || n != 1 {
		t.Fatalf("add: %d %v", n, err)
	}
	if err := SetPartitionName(path, 1, "renamed"); err != nil {
		t.Fatal(err)
	}
	info, parts, err := ReadPartitions(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Kind != TableGPT || info.SectorSize != 512 || len(parts) != 1 {
		t.Fatalf("table: %+v %+v", info, parts)
	}
	if parts[0].Name != "renamed" || parts[0].Start != 1<<20 || parts[0].Size != 8<<20 {
		t.Fatalf("partition: %+v", parts[0])
	}
	if err := RemovePartition(path, 1); err != nil {
		t.Fatal(err)
	}
	if err := RemovePartition(path, 1); !errors.Is(err, syscall.ENOENT) {
		t.Fatalf("remove twice: %v", err)
	}
}

func TestFilesystemOnImage(t *testing.T) {
	path := filepath.Join(t.TempDir(), "fs.img")
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(path, 64<<20); err != nil {
		t.Fatal(err)
	}
	if err := MakeVfat(path, "DATA", 0); err != nil {
		t.Fatal(err)
	}
	if err := SetFilesystemLabel(path, "photos"); err != nil {
		t.Fatal(err)
	}
	info, err := ProbeFilesystem(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Type != "vfat" || info.Version != "FAT16" || info.Label != "PHOTOS" || len(info.UUID) != 9 {
		t.Fatalf("probe: %+v", info)
	}
	if err := MakeExt4(path, "home"); err != nil {
		t.Fatal(err)
	}
	if info, err = ProbeFilesystem(path); err != nil || info.Type != "ext4" || info.Label != "home" {
		t.Fatalf("ext4: %+v %v", info, err)
	}
	if err := MakeExfat(path, "Média"); err != nil {
		t.Fatal(err)
	}
	if info, err = ProbeFilesystem(path); err != nil || info.Type != "exfat" || info.Label != "Média" {
		t.Fatalf("exfat: %+v %v", info, err)
	}
	if err := MakeSwap(path, "swap"); err != nil {
		t.Fatal(err)
	}
	if info, err = ProbeFilesystem(path); err != nil || info.Type != "swap" || info.Label != "swap" {
		t.Fatalf("swap: %+v %v", info, err)
	}
}

func TestLuksOnImage(t *testing.T) {
	path := filepath.Join(t.TempDir(), "luks.img")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(path, 24<<20); err != nil {
		t.Fatal(err)
	}
	if err := LuksFormat(path, "first pass", "vault"); err != nil {
		t.Fatal(err)
	}
	info, err := LuksInfoOf(path)
	if err != nil || info.Version != 2 || info.Label != "vault" || info.PayloadOffset != 16<<20 {
		t.Fatalf("info: %+v %v", info, err)
	}
	if err := LuksChangePassphrase(path, "wrong", "x"); !errors.Is(err, ErrWrongPassphrase) {
		t.Fatalf("wrong passphrase: %v", err)
	}
	if err := LuksChangePassphrase(path, "first pass", "second pass"); err != nil {
		t.Fatal(err)
	}
	if err := LuksOpen(path, "second pass", "sinty-test", true); !errors.Is(err, syscall.EINVAL) {
		t.Fatalf("open on a regular file: %v", err)
	}
}

func TestBluetoothWithoutBluez(t *testing.T) {
	addr := os.Getenv("SINTY_BUS_ADDRESS")
	if addr == "" {
		t.Skip("SINTY_BUS_ADDRESS is not set")
	}
	t.Setenv("DBUS_SYSTEM_BUS_ADDRESS", addr)
	var once *Bluetooth
	if _, _, err := once.Snapshot(); !errors.Is(err, syscall.ENOENT) {
		t.Errorf("snapshot without bluez: %v", err)
	}
	b, err := OpenBluetooth()
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	if err := b.SetPowered("/org/freedesktop/DBus", true); !errors.Is(err, syscall.EINVAL) {
		t.Errorf("a foreign path gave %v", err)
	}
	if err := b.Connect("/org/bluez/hci0"); !errors.Is(err, syscall.EINVAL) {
		t.Errorf("an adapter path as a device gave %v", err)
	}
	if err := b.Discovery("/org/bluez/hci0", true); !errors.Is(err, syscall.ENOENT) {
		t.Errorf("discovery without bluez: %v", err)
	}
}

func TestNotifyWithoutServer(t *testing.T) {
	addr := os.Getenv("SINTY_BUS_ADDRESS")
	if addr == "" {
		t.Skip("SINTY_BUS_ADDRESS is not set")
	}
	t.Setenv("DBUS_SESSION_BUS_ADDRESS", addr)
	if _, err := Notify(Notification{Summary: "x", Actions: []string{"odd"}}); !errors.Is(err, syscall.EINVAL) {
		t.Errorf("an odd action list gave %v", err)
	}
	if _, err := Notify(Notification{Summary: "x", Actions: []string{"", "Apri"}}); !errors.Is(err, syscall.EINVAL) {
		t.Errorf("an empty action key gave %v", err)
	}
	if _, err := Notify(Notification{Summary: "Prova", Urgency: 2}); !errors.Is(err, syscall.ENOENT) {
		t.Errorf("notify without a server: %v", err)
	}
	if err := CloseNotification(7); !errors.Is(err, syscall.ENOENT) {
		t.Errorf("close without a server: %v", err)
	}
}

func TestAccountsDaemon(t *testing.T) {
	addr := os.Getenv("SINTY_ACCOUNTS_ADDRESS")
	if addr == "" {
		t.Skip("SINTY_ACCOUNTS_ADDRESS is not set")
	}
	t.Setenv("DBUS_SYSTEM_BUS_ADDRESS", addr)
	users, err := Users()
	if err != nil || len(users) != 2 || users[0].Name != "alice" || !users[0].Administrator || users[1].Administrator {
		t.Fatalf("users: %+v %v", users, err)
	}
	if err := SetUserLanguage(users[0].Path, "fr_FR.UTF-8"); err != nil {
		t.Fatal(err)
	}
	if u, err := FindUser("alice"); err != nil || u.Language != "fr_FR.UTF-8" {
		t.Errorf("find: %+v %v", u, err)
	}
	if _, err := FindUser("nobody"); !errors.Is(err, syscall.ENOENT) {
		t.Errorf("unknown user gave %v", err)
	}
	if err := SetHostname("bad name", ""); !errors.Is(err, syscall.EINVAL) {
		t.Errorf("bad host name gave %v", err)
	}
}

func TestPrintWithoutServer(t *testing.T) {
	missing := "/nonexistent-sinty/cups.sock"
	if _, err := Printers(missing); !errors.Is(err, syscall.ENOENT) {
		t.Errorf("printers without a server: %v", err)
	}
	if _, err := PrinterInfo(missing, "../etc"); !errors.Is(err, syscall.EINVAL) {
		t.Errorf("bad queue name gave %v", err)
	}
	if _, err := Printers("example.com:631"); !errors.Is(err, syscall.EOPNOTSUPP) {
		t.Errorf("remote server gave %v", err)
	}
}

func TestPrintTorchio(t *testing.T) {
	sock, queue := os.Getenv("SINTY_TORCHIO_SOCKET"), os.Getenv("SINTY_TORCHIO_PRINTER")
	if sock == "" || queue == "" {
		t.Skip("SINTY_TORCHIO_SOCKET is not set")
	}
	list, err := Printers(sock)
	if err != nil || len(list) == 0 {
		t.Fatalf("printers: %+v %v", list, err)
	}
	if def, err := DefaultPrinter(sock); err != nil || def != queue {
		t.Errorf("default: %q %v", def, err)
	}
	if p, err := PrinterInfo(sock, queue); err != nil || p.Name != queue || !p.Accepting {
		t.Errorf("printer: %+v %v", p, err)
	}
	doc := filepath.Join(t.TempDir(), "lettera.txt")
	if err := os.WriteFile(doc, []byte("Lettera di prova\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	id, err := PrintFile(sock, queue, doc, "", 1)
	if err != nil || id == 0 {
		t.Fatalf("print: %d %v", id, err)
	}
	found := false
	for try := 0; try < 50 && !found; try++ {
		for _, done := range []bool{false, true} {
			jobs, err := PrintJobs(sock, queue, done)
			if err != nil {
				t.Fatal(err)
			}
			for _, j := range jobs {
				if j.ID == id && j.Name == "lettera.txt" {
					found = true
				}
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !found {
		t.Errorf("job %d never showed up", id)
	}
	if err := CancelPrintJob(sock, queue, 99999); !errors.Is(err, syscall.ENOENT) {
		t.Errorf("cancel of a missing job gave %v", err)
	}
}

func TestClipboardWithoutCompositor(t *testing.T) {
	t.Setenv("WAYLAND_DISPLAY", "/nonexistent-sinty/wayland-0")
	if _, err := ClipboardTypes(false); !errors.Is(err, syscall.ENOENT) {
		t.Errorf("types without a compositor: %v", err)
	}
	if _, err := ClipboardSet([]byte("x"), nil, false); !errors.Is(err, syscall.EINVAL) {
		t.Errorf("set without types: %v", err)
	}
}

func TestClipboardCompositor(t *testing.T) {
	sock := os.Getenv("SINTY_WAYLAND_SOCKET")
	if sock == "" {
		t.Skip("SINTY_WAYLAND_SOCKET is not set")
	}
	t.Setenv("WAYLAND_DISPLAY", sock)
	h, err := ClipboardSet([]byte("dal binding Go"), []string{"text/plain;charset=utf-8", "UTF8_STRING"}, false)
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()
	var got []byte
	for try := 0; try < 50; try++ {
		if got, err = ClipboardRead(false, "UTF8_STRING"); err == nil {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if string(got) != "dal binding Go" {
		t.Fatalf("read %q %v", got, err)
	}
	if types, err := ClipboardTypes(false); err != nil || len(types) != 2 {
		t.Errorf("types %v %v", types, err)
	}
	if !h.Active() {
		t.Error("holder lost the selection")
	}
}
