// Package polkit decides whether the caller of a system D-Bus method may run
// an administrative action. polkit decides when it runs, and its agent asks
// the person for their PIN or password; without polkit, members of the
// administrator groups are allowed.
package polkit

import (
	"os/user"
	"strconv"

	"github.com/godbus/dbus/v5"
)

const name = "org.freedesktop.PolicyKit1"

var DefaultAdminGroups = []string{"wheel", "sudo", "admin"}

type Authorizer struct {
	Conn        *dbus.Conn
	AdminGroups []string
	Caller      func(sender dbus.Sender) (uint32, error)
	IsAdmin     func(uid uint32) bool
	Polkit      func(sender dbus.Sender, action string) (authorized, ran bool)
}

func Denied(message string) *dbus.Error {
	return dbus.NewError("org.freedesktop.DBus.Error.AccessDenied", []any{message})
}

// Check returns nil when sender may run action. root always may.
func (a *Authorizer) Check(sender dbus.Sender, action string) *dbus.Error {
	uid, err := a.caller(sender)
	if err != nil {
		return Denied("the caller could not be identified")
	}
	if uid == 0 {
		return nil
	}
	if ok, ran := a.polkit(sender, action); ran {
		if ok {
			return nil
		}
		return Denied("not authorized")
	}
	if a.isAdmin(uid) {
		return nil
	}
	return Denied("not authorized")
}

// Confirm returns nil only when polkit ran and authorized sender for action,
// so the person confirmed with their PIN or password. Without polkit it
// refuses: administrator groups are not a confirmation. root always may.
func (a *Authorizer) Confirm(sender dbus.Sender, action string) *dbus.Error {
	uid, err := a.caller(sender)
	if err != nil {
		return Denied("the caller could not be identified")
	}
	if uid == 0 {
		return nil
	}
	if ok, ran := a.polkit(sender, action); ran && ok {
		return nil
	}
	return Denied("not confirmed")
}

func (a *Authorizer) caller(sender dbus.Sender) (uint32, error) {
	if a.Caller != nil {
		return a.Caller(sender)
	}
	var uid uint32
	err := a.Conn.BusObject().Call("org.freedesktop.DBus.GetConnectionUnixUser", 0, string(sender)).Store(&uid)
	return uid, err
}

func (a *Authorizer) polkit(sender dbus.Sender, action string) (bool, bool) {
	if a.Polkit != nil {
		return a.Polkit(sender, action)
	}
	if a.Conn == nil || !a.available() {
		return false, false
	}
	subject := struct {
		Kind    string
		Details map[string]dbus.Variant
	}{"system-bus-name", map[string]dbus.Variant{"name": dbus.MakeVariant(string(sender))}}
	var res struct {
		Authorized bool
		Challenge  bool
		Details    map[string]string
	}
	const allowInteraction = uint32(1)
	call := a.Conn.Object(name, "/org/freedesktop/PolicyKit1/Authority").Call(
		"org.freedesktop.PolicyKit1.Authority.CheckAuthorization", 0,
		subject, action, map[string]string{}, allowInteraction, "")
	if call.Err != nil || call.Store(&res) != nil {
		return false, false
	}
	return res.Authorized, true
}

func (a *Authorizer) available() bool {
	var owned bool
	if err := a.Conn.BusObject().Call("org.freedesktop.DBus.NameHasOwner", 0, name).Store(&owned); err == nil && owned {
		return true
	}
	var names []string
	if err := a.Conn.BusObject().Call("org.freedesktop.DBus.ListActivatableNames", 0).Store(&names); err != nil {
		return false
	}
	for _, n := range names {
		if n == name {
			return true
		}
	}
	return false
}

func (a *Authorizer) isAdmin(uid uint32) bool {
	if a.IsAdmin != nil {
		return a.IsAdmin(uid)
	}
	groups := a.AdminGroups
	if groups == nil {
		groups = DefaultAdminGroups
	}
	u, err := user.LookupId(strconv.FormatUint(uint64(uid), 10))
	if err != nil {
		return false
	}
	ids, err := u.GroupIds()
	if err != nil {
		return false
	}
	for _, id := range ids {
		g, err := user.LookupGroupId(id)
		if err != nil {
			continue
		}
		for _, want := range groups {
			if g.Name == want {
				return true
			}
		}
	}
	return false
}
