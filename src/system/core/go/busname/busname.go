// Package busname claims the well-known names of a system service. A service
// can be started twice at once, by the service manager and by D-Bus
// activation; the copy that loses waits in the bus queue instead of failing,
// so the manager does not restart it in a loop, and it takes over as soon as
// the owner exits.
package busname

import (
	"context"
	"errors"
	"fmt"

	"github.com/godbus/dbus/v5"
)

// Own makes conn the primary owner of names. When another connection owns
// the first name, Own waits until that connection releases it or ctx ends.
// The other names must be free once the first one is owned.
func Own(ctx context.Context, conn *dbus.Conn, names ...string) error {
	if len(names) == 0 {
		return nil
	}
	ch := make(chan *dbus.Signal, 16)
	conn.Signal(ch)
	defer conn.RemoveSignal(ch)
	reply, err := conn.RequestName(names[0], 0)
	if err != nil {
		return err
	}
	switch reply {
	case dbus.RequestNameReplyPrimaryOwner, dbus.RequestNameReplyAlreadyOwner:
	case dbus.RequestNameReplyInQueue:
		if err := acquired(ctx, ch, names[0]); err != nil {
			conn.ReleaseName(names[0])
			return err
		}
	default:
		return fmt.Errorf("%s is owned by another process", names[0])
	}
	for _, name := range names[1:] {
		reply, err := conn.RequestName(name, dbus.NameFlagDoNotQueue)
		if err != nil {
			return err
		}
		if reply != dbus.RequestNameReplyPrimaryOwner && reply != dbus.RequestNameReplyAlreadyOwner {
			return fmt.Errorf("%s is owned by another process", name)
		}
	}
	return nil
}

func acquired(ctx context.Context, ch <-chan *dbus.Signal, name string) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case sig, ok := <-ch:
			if !ok {
				return errors.New("the bus connection closed")
			}
			if sig.Name == "org.freedesktop.DBus.NameAcquired" && len(sig.Body) == 1 && sig.Body[0] == name {
				return nil
			}
		}
	}
}
