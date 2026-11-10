package sintysystem

import (
	"net"
	"os"
	"testing"
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
