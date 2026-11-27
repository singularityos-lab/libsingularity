package busname

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
)

func privateBus(t *testing.T) string {
	bin, err := exec.LookPath("dbus-daemon")
	if err != nil {
		t.Skip("dbus-daemon not installed")
	}
	dir := t.TempDir()
	conf := filepath.Join(dir, "bus.conf")
	sock := fmt.Sprintf("libsingularity-busname-%d-%d", os.Getpid(), time.Now().UnixNano())
	err = os.WriteFile(conf, []byte(`<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig><type>session</type><listen>unix:abstract=`+sock+`</listen>
<auth>EXTERNAL</auth><policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy></busconfig>`), 0o600)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(bin, "--config-file="+conf, "--nofork", "--print-address")
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
	addr, err := bufio.NewReader(out).ReadString('\n')
	if err != nil {
		t.Fatalf("%v: %s", err, stderr.String())
	}
	return strings.TrimSpace(addr)
}

func connect(t *testing.T, addr string) *dbus.Conn {
	conn, err := dbus.Connect(addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

func owner(t *testing.T, conn *dbus.Conn, name string) string {
	var id string
	if err := conn.BusObject().Call("org.freedesktop.DBus.GetNameOwner", 0, name).Store(&id); err != nil {
		return ""
	}
	return id
}

var names = []string{"org.example.Power", "org.example.Power.Profiles", "org.example.Power.Extra"}

func TestOwnFreeNames(t *testing.T) {
	addr := privateBus(t)
	a := connect(t, addr)
	if err := Own(context.Background(), a, names...); err != nil {
		t.Fatal(err)
	}
	for _, n := range names {
		if owner(t, a, n) != a.Names()[0] {
			t.Fatalf("%s not owned", n)
		}
	}
}

func TestOwnWaitsForOwnerToExit(t *testing.T) {
	addr := privateBus(t)
	a := connect(t, addr)
	if err := Own(context.Background(), a, names...); err != nil {
		t.Fatal(err)
	}
	b := connect(t, addr)
	done := make(chan error, 1)
	go func() { done <- Own(context.Background(), b, names...) }()
	select {
	case err := <-done:
		t.Fatalf("Own returned while the names were taken: %v", err)
	case <-time.After(300 * time.Millisecond):
	}
	a.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Own did not take over after the owner exited")
	}
	for _, n := range names {
		if owner(t, b, n) != b.Names()[0] {
			t.Fatalf("%s not taken over", n)
		}
	}
}

func TestOwnStopsWithContext(t *testing.T) {
	addr := privateBus(t)
	a := connect(t, addr)
	if err := Own(context.Background(), a, names...); err != nil {
		t.Fatal(err)
	}
	b := connect(t, addr)
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	if err := Own(ctx, b, names...); err == nil {
		t.Fatal("Own succeeded while the names were taken")
	}
	a.Close()
	time.Sleep(200 * time.Millisecond)
	if owner(t, b, names[0]) == b.Names()[0] {
		t.Fatal("a cancelled Own still took the name")
	}
}
