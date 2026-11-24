package netkind

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestUnknownKindsCountAsPublic(t *testing.T) {
	for in, want := range map[string]Kind{"home\n": Home, "work": Work, "none": None, "public": Public, "": Public, "office": Public} {
		if got := Parse(in); got != want {
			t.Errorf("%q: %s", in, got)
		}
	}
	if !Home.Private() || !Work.Private() || Public.Private() || None.Private() {
		t.Fatal("private set")
	}
}

func TestWhatIsWrittenIsWhatIsRead(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "sinty-nm")
	if _, ok := Read(dir); ok {
		t.Fatal("read before anything was written")
	}
	if err := Write(dir, Home, true); err != nil {
		t.Fatal(err)
	}
	if k, ok := Read(dir); !ok || k != Home || !Metered(dir) {
		t.Fatalf("%s %v %v", k, ok, Metered(dir))
	}
	if err := Write(dir, Public, false); err != nil {
		t.Fatal(err)
	}
	if k, _ := Read(dir); k != Public || Metered(dir) {
		t.Fatalf("%s %v", k, Metered(dir))
	}
}

func TestOnAPublicNetworkOnlyTheCableIsAdmitted(t *testing.T) {
	dir := t.TempDir()
	links := map[string]string{"192.168.1.5": "wlan0", "172.16.42.1": "usb0", "10.0.0.2": "ncm0"}
	admit := Admit(dir, func(ip net.IP) string { return links[ip.String()] })
	wifi := &net.TCPAddr{IP: net.ParseIP("192.168.1.5")}
	if !admit(wifi) {
		t.Fatal("refused before sinty-nm said anything")
	}
	for kind, open := range map[Kind]bool{Home: true, Work: true, None: true, Public: false} {
		os.WriteFile(filepath.Join(dir, "network-kind"), []byte(kind), 0o644)
		if admit(wifi) != open {
			t.Errorf("%s over wifi", kind)
		}
		if admit(&net.UDPAddr{IP: net.ParseIP("192.168.1.5")}) != open {
			t.Errorf("%s over wifi, udp", kind)
		}
		if !admit(&net.TCPAddr{IP: net.ParseIP("172.16.42.1")}) || !admit(&net.TCPAddr{IP: net.ParseIP("10.0.0.2")}) {
			t.Errorf("%s over the cable", kind)
		}
	}
}

func TestPacketsArePlacedOnTheLinkTheyCameFrom(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "network-kind"), []byte("public"), 0o644)
	towards := func(ip net.IP) string {
		if ip.To4()[0] == 172 {
			return "usb0"
		}
		return "wlan0"
	}
	admit := AdmitPeer(dir, towards)
	if admit(&net.UDPAddr{IP: net.ParseIP("192.168.1.9")}) {
		t.Fatal("wifi peer admitted on a public network")
	}
	if !admit(&net.UDPAddr{IP: net.ParseIP("172.16.42.2")}) {
		t.Fatal("cable peer refused")
	}
	if admit(&net.UnixAddr{Name: "x"}) {
		t.Fatal("unknown address admitted on a public network")
	}
}
