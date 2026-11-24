// Package netkind is the one place Sinty services learn what kind of network
// the device is on. sinty-nm writes it; the firewall, the debug bridge, Nearby
// and updates read it.
package netkind

import (
	"net"
	"os"
	"path/filepath"
	"strings"
)

type Kind string

const (
	None   Kind = "none"
	Public Kind = "public"
	Home   Kind = "home"
	Work   Kind = "work"
)

const Dir = "/run/sinty-nm"

func Parse(s string) Kind {
	switch k := Kind(strings.TrimSpace(s)); k {
	case None, Public, Home, Work:
		return k
	}
	return Public
}

func (k Kind) Private() bool {
	return k == Home || k == Work
}

func Read(dir string) (Kind, bool) {
	b, err := os.ReadFile(filepath.Join(dir, "network-kind"))
	if err != nil {
		return "", false
	}
	return Parse(string(b)), true
}

func Metered(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, "metered"))
	return err == nil
}

func Write(dir string, k Kind, metered bool) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp := filepath.Join(dir, ".network-kind")
	if err := os.WriteFile(tmp, []byte(string(k)+"\n"), 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, filepath.Join(dir, "network-kind")); err != nil {
		return err
	}
	if metered {
		return os.WriteFile(filepath.Join(dir, "metered"), nil, 0o644)
	}
	if err := os.Remove(filepath.Join(dir, "metered")); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

var cableLinks = []string{"usb", "rndis", "ncm"}

func Cable(link string) bool {
	for _, p := range cableLinks {
		if strings.HasPrefix(link, p) {
			return true
		}
	}
	return false
}

func LinkOf(ip net.IP) string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, i := range ifaces {
		addrs, err := i.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			if n, ok := a.(*net.IPNet); ok && n.IP.Equal(ip) {
				return i.Name
			}
		}
	}
	return ""
}

func LinkTowards(ip net.IP) string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, i := range ifaces {
		addrs, err := i.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			if n, ok := a.(*net.IPNet); ok && n.Contains(ip) {
				return i.Name
			}
		}
	}
	return ""
}

func ipOf(a net.Addr) net.IP {
	switch a := a.(type) {
	case *net.TCPAddr:
		return a.IP
	case *net.UDPAddr:
		return a.IP
	}
	return nil
}

func admit(dir string, link func() string) bool {
	k, ok := Read(dir)
	if !ok || k != Public {
		return true
	}
	return Cable(link())
}

// Admit refuses peers reaching the device through a public network, judged by
// the local address they connected to. Until sinty-nm has said anything every
// peer is let in, so recovery and early boot keep their way in, and a cable
// link is always trusted.
func Admit(dir string, linkOf func(net.IP) string) func(local net.Addr) bool {
	return func(local net.Addr) bool {
		ip := ipOf(local)
		return admit(dir, func() string {
			if ip == nil {
				return ""
			}
			return linkOf(ip)
		})
	}
}

// AdmitPeer is Admit for packets, where only the sender is known: the link is
// the one whose subnet holds the sender.
func AdmitPeer(dir string, linkTowards func(net.IP) string) func(remote net.Addr) bool {
	return func(remote net.Addr) bool {
		ip := ipOf(remote)
		return admit(dir, func() string {
			if ip == nil {
				return ""
			}
			return linkTowards(ip)
		})
	}
}
