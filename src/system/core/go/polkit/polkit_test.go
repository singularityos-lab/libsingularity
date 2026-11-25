package polkit

import (
	"errors"
	"testing"

	"github.com/godbus/dbus/v5"
)

func TestCheck(t *testing.T) {
	uids := map[dbus.Sender]uint32{":1.1": 0, ":1.2": 1000, ":1.3": 1001}
	caller := func(s dbus.Sender) (uint32, error) {
		uid, ok := uids[s]
		if !ok {
			return 0, errors.New("gone")
		}
		return uid, nil
	}
	admin := func(uid uint32) bool { return uid == 1000 }
	var asked []string
	cases := []struct {
		name   string
		polkit func(dbus.Sender, string) (bool, bool)
		sender dbus.Sender
		ok     bool
	}{
		{"root without asking", func(dbus.Sender, string) (bool, bool) { asked = append(asked, "root"); return false, true }, ":1.1", true},
		{"polkit allows", func(dbus.Sender, string) (bool, bool) { return true, true }, ":1.3", true},
		{"polkit refuses an administrator", func(dbus.Sender, string) (bool, bool) { return false, true }, ":1.2", false},
		{"no polkit, administrator", func(dbus.Sender, string) (bool, bool) { return false, false }, ":1.2", true},
		{"no polkit, other user", func(dbus.Sender, string) (bool, bool) { return false, false }, ":1.3", false},
		{"unknown caller", func(dbus.Sender, string) (bool, bool) { return true, true }, ":1.9", false},
	}
	for _, c := range cases {
		a := &Authorizer{Caller: caller, IsAdmin: admin, Polkit: c.polkit}
		if err := a.Check(c.sender, "dev.sinty.test"); (err == nil) != c.ok {
			t.Errorf("%s: %v", c.name, err)
		}
	}
	if len(asked) != 0 {
		t.Fatal("polkit was asked about root")
	}
}

func TestConfirm(t *testing.T) {
	uids := map[dbus.Sender]uint32{":1.1": 0, ":1.2": 1000}
	caller := func(s dbus.Sender) (uint32, error) {
		uid, ok := uids[s]
		if !ok {
			return 0, errors.New("gone")
		}
		return uid, nil
	}
	admin := func(uint32) bool { return true }
	cases := []struct {
		name   string
		polkit func(dbus.Sender, string) (bool, bool)
		sender dbus.Sender
		ok     bool
	}{
		{"root", func(dbus.Sender, string) (bool, bool) { return false, false }, ":1.1", true},
		{"confirmed", func(dbus.Sender, string) (bool, bool) { return true, true }, ":1.2", true},
		{"dismissed", func(dbus.Sender, string) (bool, bool) { return false, true }, ":1.2", false},
		{"no polkit, administrator", func(dbus.Sender, string) (bool, bool) { return false, false }, ":1.2", false},
		{"unknown caller", func(dbus.Sender, string) (bool, bool) { return true, true }, ":1.9", false},
	}
	for _, c := range cases {
		a := &Authorizer{Caller: caller, IsAdmin: admin, Polkit: c.polkit}
		if err := a.Confirm(c.sender, "dev.sinty.test"); (err == nil) != c.ok {
			t.Errorf("%s: %v", c.name, err)
		}
	}
}
