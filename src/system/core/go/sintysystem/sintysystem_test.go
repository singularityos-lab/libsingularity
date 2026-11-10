package sintysystem

import (
	"encoding/hex"
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

func TestSettingsDefaults(t *testing.T) {
	dir := os.Getenv("SINTY_SCHEMA_DIR")
	if dir == "" {
		t.Skip("SINTY_SCHEMA_DIR is not set")
	}
	conf := t.TempDir()
	profile := filepath.Join(conf, "profile")
	if err := os.WriteFile(profile, []byte("user-db:user\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GSETTINGS_SCHEMA_DIR", dir)
	t.Setenv("XDG_DATA_DIRS", "/nonexistent")
	t.Setenv("XDG_CONFIG_HOME", conf)
	t.Setenv("DCONF_PROFILE", profile)
	t.Setenv("DBUS_SESSION_BUS_ADDRESS", "unix:path=/nonexistent-sinty/bus")
	k := func(name string) SettingsKey { return SettingsKey{Schema: "dev.sinty.Test", Key: name} }
	if v, err := k("enabled").Bool(); err != nil || !v {
		t.Errorf("enabled %v %v", v, err)
	}
	if v, err := k("count").Int(); err != nil || v != -42 {
		t.Errorf("count %v %v", v, err)
	}
	if v, err := k("ratio").Double(); err != nil || v != 0.75 {
		t.Errorf("ratio %v %v", v, err)
	}
	if v, err := k("mode").String(); err != nil || v != "dark" {
		t.Errorf("mode %q %v", v, err)
	}
	if v, err := k("apps").Strv(); err != nil || len(v) != 3 || v[1] != "edit" {
		t.Errorf("apps %v %v", v, err)
	}
	if v, err := k("enabled").Writable(); err != nil || !v {
		t.Errorf("writable %v %v", v, err)
	}
	if _, err := k("enabled").Int(); !errors.Is(err, syscall.EINVAL) {
		t.Errorf("wrong type read gave %v", err)
	}
	if err := k("count").SetInt(500); !errors.Is(err, syscall.EINVAL) {
		t.Errorf("out of range gave %v", err)
	}
	if err := k("enabled").SetString("x"); !errors.Is(err, syscall.EINVAL) {
		t.Errorf("wrong type write gave %v", err)
	}
	if err := k("enabled").SetBool(false); !errors.Is(err, syscall.ENOENT) {
		t.Errorf("write without a session bus gave %v", err)
	}
	child := SettingsKey{Schema: "dev.sinty.Test.Child", Path: "/dev/sinty/child/", Key: "size"}
	if v, err := child.Int(); err != nil || v != 7 {
		t.Errorf("relocatable %v %v", v, err)
	}
	if _, err := (SettingsKey{Schema: "no.such.Schema", Key: "x"}).Bool(); !errors.Is(err, syscall.ENOENT) {
		t.Errorf("missing schema gave %v", err)
	}
}

func TestJournalFixtures(t *testing.T) {
	dir := os.Getenv("SINTY_JOURNAL_FIXTURES")
	if dir == "" {
		t.Skip("SINTY_JOURNAL_FIXTURES is not set")
	}
	if !JournalAvailable(dir) || JournalAvailable("/nonexistent-sinty") {
		t.Fatal("availability is wrong")
	}
	boots, err := JournalBoots(dir)
	if err != nil || len(boots) == 0 {
		t.Fatalf("boots %v %v", boots, err)
	}
	last := boots[len(boots)-1]
	entries, err := Journal(dir, last.ID, 7, "", 20)
	if err != nil || len(entries) == 0 || len(entries) > 20 {
		t.Fatalf("entries %d %v", len(entries), err)
	}
	for _, e := range entries {
		if e.BootID != last.ID || e.Realtime < last.First || e.Realtime > last.Last {
			t.Errorf("entry outside its boot: %+v", e)
		}
	}
	if _, err := Journal(dir, "not-a-boot", 7, "", 1); !errors.Is(err, syscall.EINVAL) {
		t.Errorf("bad boot id gave %v", err)
	}
}

func TestConfRoundTrip(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "xdg", "singularity"), 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "xdg", "singularity", "power.conf")
	if err := os.WriteFile(path, []byte("# power\n[Power]\nBackend=command\nSuspend=helper suspend\nLevels=10;20;\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("XDG_CONFIG_DIRS", filepath.Join(dir, "missing")+":"+filepath.Join(dir, "xdg"))
	found, err := FindConf("singularity/power.conf")
	if err != nil || found != path {
		t.Fatalf("find %q %v", found, err)
	}
	if _, err := FindConf("../etc/passwd"); !errors.Is(err, syscall.EINVAL) {
		t.Errorf("escape gave %v", err)
	}
	c, err := OpenConf(found)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if v, err := c.String("Power", "Suspend"); err != nil || v != "helper suspend" {
		t.Errorf("suspend %q %v", v, err)
	}
	if v, err := c.List("Power", "Levels"); err != nil || len(v) != 2 || v[1] != "20" {
		t.Errorf("levels %v %v", v, err)
	}
	if err := c.SetBool("Power", "Enabled", true); err != nil {
		t.Fatal(err)
	}
	if err := c.SetInt("Limits", "Max", 80); err != nil {
		t.Fatal(err)
	}
	if err := c.Save(path); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(path)
	want := "# power\n[Power]\nBackend=command\nSuspend=helper suspend\nLevels=10;20;\nEnabled=true\n\n[Limits]\nMax=80\n"
	if string(data) != want {
		t.Errorf("saved %q", data)
	}
	again, err := ParseConf(string(data))
	if err != nil {
		t.Fatal(err)
	}
	defer again.Close()
	if v, err := again.Int("Limits", "Max"); err != nil || v != 80 {
		t.Errorf("max %v %v", v, err)
	}
	if g, err := again.Groups(); err != nil || len(g) != 2 {
		t.Errorf("groups %v %v", g, err)
	}
	if _, err := ParseConf("broken\n"); !errors.Is(err, syscall.EINVAL) {
		t.Errorf("broken gave %v", err)
	}
}

func TestFscryptIdentifier(t *testing.T) {
	raw := make([]byte, 64)
	for i := range raw {
		raw[i] = byte(i)
	}
	id := FscryptIdentifier(raw)
	if got := hex.EncodeToString(id[:]); got != "8699c2c53707405da5aba5ae4d8583c0" {
		t.Fatalf("identifier %s", got)
	}
	if _, err := FscryptAddKey(t.TempDir(), raw[:10]); !errors.Is(err, syscall.EINVAL) {
		t.Fatalf("short key: %v", err)
	}
	p, err := FscryptGetPolicy(t.TempDir())
	if err != nil && !errors.Is(err, syscall.EOPNOTSUPP) {
		t.Fatal(err)
	}
	if p != nil && p.Contents == 0 {
		t.Fatalf("policy %+v", p)
	}
}

func TestMountHelpers(t *testing.T) {
	if _, err := MountPointOf("/proc"); !errors.Is(err, syscall.EINVAL) {
		t.Fatalf("non block device: %v", err)
	}
	if _, err := GrowExt4(filepath.Join(t.TempDir(), "none"), 0); !errors.Is(err, syscall.ENOENT) {
		t.Fatalf("missing device: %v", err)
	}
	if err := MountOverlay(t.TempDir(), nil, "", "", "", true); !errors.Is(err, syscall.EINVAL) {
		t.Fatalf("overlay without layers: %v", err)
	}
	if err := MountOverlay(t.TempDir(), []string{t.TempDir()}, t.TempDir(), "", "", false); !errors.Is(err, syscall.EINVAL) {
		t.Fatalf("upper without work: %v", err)
	}
	if err := Unmount(t.TempDir(), false); err == nil {
		t.Fatal("unmount of a plain directory succeeded")
	}
}

func TestCheckFilesystem(t *testing.T) {
	img := filepath.Join(t.TempDir(), "fs.img")
	f, err := os.Create(img)
	if err != nil {
		t.Fatal(err)
	}
	f.Truncate(48 << 20)
	f.Close()
	if err := MakeExfat(img, "Prova"); err != nil {
		t.Fatal(err)
	}
	r, err := CheckFilesystem(img, false)
	if err != nil || !r.Clean() || r.Errors != 0 {
		t.Fatalf("fresh volume: %+v %v", r, err)
	}
	raw, _ := os.ReadFile(img)
	raw[0x6a] |= 2
	os.WriteFile(img, raw, 0o644)
	r, _ = CheckFilesystem(img, false)
	if !r.Dirty || r.Clean() || r.Message == "" {
		t.Fatalf("dirty volume: %+v", r)
	}
	if r, err = CheckFilesystem(img, true); err != nil || !r.Clean() {
		t.Fatalf("repair: %+v %v", r, err)
	}
	if r, _ = CheckFilesystem(img, false); r.Errors != 0 {
		t.Fatalf("after repair: %+v", r)
	}
}

func TestBuildErofs(t *testing.T) {
	src := t.TempDir()
	os.MkdirAll(filepath.Join(src, "a", "b"), 0o755)
	os.WriteFile(filepath.Join(src, "a", "b", "nota"), []byte("ciao"), 0o644)
	img := filepath.Join(t.TempDir(), "root.erofs")
	blocks, err := BuildErofs(src, img, "radice")
	if err != nil || blocks < 3 {
		t.Fatalf("build: %d %v", blocks, err)
	}
	if _, err := BuildErofs(filepath.Join(src, "a", "b", "nota"), img, ""); !errors.Is(err, syscall.EINVAL) {
		t.Fatalf("file as source: %v", err)
	}
}

func TestMakeF2fs(t *testing.T) {
	img := filepath.Join(t.TempDir(), "f2fs.img")
	f, err := os.Create(img)
	if err != nil {
		t.Fatal(err)
	}
	f.Truncate(96 << 20)
	f.Close()
	if err := MakeF2fs(img, "Dati"); err != nil {
		t.Fatal(err)
	}
	if err := SetFilesystemLabel(img, "Nuovo"); err != nil {
		t.Fatal(err)
	}
	small := filepath.Join(t.TempDir(), "small.img")
	os.WriteFile(small, make([]byte, 4<<20), 0o644)
	if err := MakeF2fs(small, ""); !errors.Is(err, syscall.EFBIG) {
		t.Fatalf("tiny device: %v", err)
	}
}

func TestMakeSwapFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "swap")
	if err := MakeSwapFile(path, 8<<20, "memoria"); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil || st.Size() != 8<<20 || st.Mode().Perm() != 0o600 {
		t.Fatalf("%v %v", st, err)
	}
	info, err := ProbeFilesystem(path)
	if err != nil || info.Type != "swap" || info.Label != "memoria" {
		t.Fatalf("%+v %v", info, err)
	}
	if err := MakeSwapFile(path, 8<<20, ""); !errors.Is(err, syscall.EEXIST) {
		t.Fatalf("existing file: %v", err)
	}
}

func TestNetLinksAndWireguardKeys(t *testing.T) {
	links, err := NetLinks()
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, l := range links {
		if l.Name == "lo" && l.Flags&NetFlagLoopback != 0 {
			found = true
		}
	}
	if !found {
		t.Fatalf("lo missing in %+v", links)
	}
	lo, err := NetLinkByName("lo")
	if err != nil || lo.Index != 1 {
		t.Fatalf("%+v %v", lo, err)
	}
	if _, err := NetLinkByName("nonesiste0"); !errors.Is(err, syscall.ENOENT) {
		t.Fatalf("missing link: %v", err)
	}
	if _, err := NetAddresses(); err != nil {
		t.Fatal(err)
	}
	if _, err := NetRoutes(); err != nil {
		t.Fatal(err)
	}
	priv, err := WgGenerateKey()
	if err != nil || len(priv) != 44 {
		t.Fatalf("%q %v", priv, err)
	}
	pub, err := WgPublicKey("dwdtCnMYpX08FsFyUbJmRQ8ML4BJmFV4dH5OzxkEjmg=")
	if err != nil || pub != "XXdiHLHmLJB8JTBL4XrxxseidpQllzP43uhdKHH5zFQ=" {
		t.Fatalf("%q %v", pub, err)
	}
	if _, err := WgPublicKey("corta"); !errors.Is(err, syscall.EINVAL) {
		t.Fatalf("bad key: %v", err)
	}
	ifs, err := WifiInterfaces()
	if err != nil && !errors.Is(err, syscall.EOPNOTSUPP) {
		t.Fatal(err)
	}
	for _, i := range ifs {
		if _, err := WifiPowerSave(i.Name); err != nil && !errors.Is(err, syscall.EOPNOTSUPP) {
			t.Fatalf("%s power save: %v", i.Name, err)
		}
	}
	if err := WifiSetPowerSave("nonesiste0", true); !errors.Is(err, syscall.ENOENT) {
		t.Fatalf("missing interface: %v", err)
	}
	if err := WgApply("wgtest0", "[Peer]\nAllowedIPs = 10.0.0.0/8\n"); !errors.Is(err, syscall.EINVAL) {
		t.Fatalf("peer without key: %v", err)
	}
}
