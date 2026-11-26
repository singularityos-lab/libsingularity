// Package uevent delivers device events to Sinty services. When a device
// manager broadcasts libudev events, the subsystems a service asks for are
// filtered in the kernel, so the service wakes only for its own devices;
// otherwise it reads the kernel events and filters them itself.
package uevent

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"os"

	"golang.org/x/sys/unix"
)

const (
	groupKernel = 1
	groupUdev   = 2
	udevMagic   = 0xfeedcafe
	udevHeader  = 40
	recvBuffer  = 4 << 20
)

var udevControl = "/run/udev/control"

// ErrOverflow reports that the socket dropped events; the caller should
// rescan what it follows.
var ErrOverflow = errors.New("uevent: events were dropped")

// Match selects the events of one subsystem, and of one device type in it
// when DevType is set.
type Match struct {
	Subsystem string
	DevType   string
}

// Event is one device event.
type Event struct {
	props []byte
}

// Get returns the value of a property of the event.
func (e Event) Get(key string) string {
	p := e.props
	for len(p) > 0 {
		kv := p
		if end := bytes.IndexByte(p, 0); end >= 0 {
			kv, p = p[:end], p[end+1:]
		} else {
			p = nil
		}
		if len(kv) > len(key) && kv[len(key)] == '=' && string(kv[:len(key)]) == key {
			return string(kv[len(key)+1:])
		}
	}
	return ""
}

func (e Event) Action() string    { return e.Get("ACTION") }
func (e Event) Subsystem() string { return e.Get("SUBSYSTEM") }
func (e Event) DevType() string   { return e.Get("DEVTYPE") }
func (e Event) DevPath() string   { return e.Get("DEVPATH") }

// Monitor is an open event socket.
type Monitor struct {
	fd      int
	udev    bool
	matches []Match
	check   bool
}

// Open starts listening for the events that satisfy any of matches, or for
// every event when none is given.
func Open(matches ...Match) (*Monitor, error) {
	_, err := os.Stat(udevControl)
	m := &Monitor{udev: err == nil, matches: matches, check: true}
	fd, err := unix.Socket(unix.AF_NETLINK, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC|unix.SOCK_NONBLOCK, unix.NETLINK_KOBJECT_UEVENT)
	if err != nil {
		return nil, err
	}
	_ = unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_RCVBUF, recvBuffer)
	group := uint32(groupKernel)
	if m.udev {
		group = groupUdev
		if len(matches) > 0 {
			prog := filter(matches)
			if err := unix.SetsockoptSockFprog(fd, unix.SOL_SOCKET, unix.SO_ATTACH_FILTER, &unix.SockFprog{Len: uint16(len(prog)), Filter: &prog[0]}); err != nil {
				unix.Close(fd)
				return nil, err
			}
		}
	}
	if err := unix.Bind(fd, &unix.SockaddrNetlink{Family: unix.AF_NETLINK, Groups: group}); err != nil {
		unix.Close(fd)
		return nil, err
	}
	m.fd = fd
	return m, nil
}

// Filtered reports whether the kernel drops the events nobody asked for.
func (m *Monitor) Filtered() bool { return m.udev && len(m.matches) > 0 }

// Run calls fn for every matching event until ctx ends, then closes the
// socket. fn gets ErrOverflow when events were lost.
func (m *Monitor) Run(ctx context.Context, fn func(Event, error)) error {
	defer unix.Close(m.fd)
	stop, err := unix.Eventfd(0, unix.EFD_CLOEXEC|unix.EFD_NONBLOCK)
	if err != nil {
		return err
	}
	defer unix.Close(stop)
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			one := [8]byte{1}
			_, _ = unix.Write(stop, one[:])
		case <-done:
		}
	}()
	buf := make([]byte, 64<<10)
	fds := []unix.PollFd{{Fd: int32(m.fd), Events: unix.POLLIN}, {Fd: int32(stop), Events: unix.POLLIN}}
	for ctx.Err() == nil {
		if _, err := unix.Poll(fds, -1); err != nil {
			if err == unix.EINTR {
				continue
			}
			return err
		}
		if fds[1].Revents != 0 {
			break
		}
		for {
			n, from, err := unix.Recvfrom(m.fd, buf, 0)
			if err == unix.EAGAIN || err == unix.EINTR {
				break
			}
			if err == unix.ENOBUFS {
				fn(Event{}, ErrOverflow)
				continue
			}
			if err != nil {
				return err
			}
			if ev, ok := m.parse(buf[:n], from); ok {
				fn(ev, nil)
			}
		}
	}
	return ctx.Err()
}

func (m *Monitor) parse(msg []byte, from unix.Sockaddr) (Event, bool) {
	sender, ok := from.(*unix.SockaddrNetlink)
	if !ok {
		return Event{}, false
	}
	var props []byte
	if m.udev {
		if sender.Pid == 0 || len(msg) < udevHeader || !bytes.HasPrefix(msg, []byte("libudev\x00")) || binary.BigEndian.Uint32(msg[8:]) != udevMagic {
			return Event{}, false
		}
		off, size := binary.LittleEndian.Uint32(msg[16:]), binary.LittleEndian.Uint32(msg[20:])
		if off < udevHeader || uint64(off)+uint64(size) > uint64(len(msg)) {
			return Event{}, false
		}
		props = msg[off : off+size]
	} else {
		if sender.Pid != 0 {
			return Event{}, false
		}
		head := bytes.IndexByte(msg, 0)
		if head < 0 || !bytes.Contains(msg[:head], []byte("@")) {
			return Event{}, false
		}
		props = msg[head+1:]
	}
	ev := Event{props: bytes.Clone(props)}
	if m.check && !m.wants(ev) {
		return Event{}, false
	}
	return ev, true
}

func (m *Monitor) wants(ev Event) bool {
	if len(m.matches) == 0 {
		return true
	}
	subsystem := ev.Subsystem()
	for _, w := range m.matches {
		if w.Subsystem == subsystem && (w.DevType == "" || w.DevType == ev.DevType()) {
			return true
		}
	}
	return false
}

func filter(matches []Match) []unix.SockFilter {
	const (
		load   = unix.BPF_LD | unix.BPF_W | unix.BPF_ABS
		equal  = unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K
		ret    = unix.BPF_RET | unix.BPF_K
		accept = 0xffffffff
	)
	var body []unix.SockFilter
	for _, w := range matches {
		sub := murmur2([]byte(w.Subsystem))
		if w.DevType == "" {
			body = append(body,
				unix.SockFilter{Code: load, K: 24},
				unix.SockFilter{Code: equal, Jt: 0, Jf: 1, K: sub},
				unix.SockFilter{Code: ret, K: accept})
			continue
		}
		body = append(body,
			unix.SockFilter{Code: load, K: 24},
			unix.SockFilter{Code: equal, Jt: 0, Jf: 3, K: sub},
			unix.SockFilter{Code: load, K: 28},
			unix.SockFilter{Code: equal, Jt: 0, Jf: 1, K: murmur2([]byte(w.DevType))},
			unix.SockFilter{Code: ret, K: accept})
	}
	prog := []unix.SockFilter{
		{Code: load, K: 8},
		{Code: equal, Jt: 0, Jf: uint8(len(body)), K: udevMagic},
	}
	prog = append(prog, body...)
	return append(prog, unix.SockFilter{Code: ret, K: 0})
}

func murmur2(key []byte) uint32 {
	const m, r = 0x5bd1e995, 24
	h := uint32(len(key))
	for len(key) >= 4 {
		k := binary.LittleEndian.Uint32(key)
		k *= m
		k ^= k >> r
		k *= m
		h = h*m ^ k
		key = key[4:]
	}
	switch len(key) {
	case 3:
		h ^= uint32(key[2]) << 16
		fallthrough
	case 2:
		h ^= uint32(key[1]) << 8
		fallthrough
	case 1:
		h ^= uint32(key[0])
		h *= m
	}
	h ^= h >> 13
	h *= m
	h ^= h >> 15
	return h
}
