//go:build linux

// Package dirwatch tells a service when files in a directory change, without
// polling.
package dirwatch

import (
	"bytes"
	"context"
	"path/filepath"
	"slices"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// Watch calls fn once the directory exists and again after every file in it
// is written or replaced, until ctx ends. A directory that does not exist yet,
// or is removed, is waited for.
func Watch(ctx context.Context, dir string, fn func()) {
	Files(ctx, dir, nil, fn)
}

// Files is Watch limited to the named files of the directory: changes to
// other files in it do not call fn.
func Files(ctx context.Context, dir string, names []string, fn func()) {
	stop, err := unix.Eventfd(0, unix.EFD_CLOEXEC|unix.EFD_NONBLOCK)
	if err != nil {
		return
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
	for ctx.Err() == nil {
		fd, err := unix.InotifyInit1(unix.IN_CLOEXEC | unix.IN_NONBLOCK)
		if err != nil {
			return
		}
		if _, err := unix.InotifyAddWatch(fd, dir, unix.IN_CLOSE_WRITE|unix.IN_MOVED_TO|unix.IN_DELETE|unix.IN_DELETE_SELF|unix.IN_MOVE_SELF); err != nil {
			unix.Close(fd)
			awaitCreation(ctx, stop, dir)
			continue
		}
		fn()
		follow(ctx, stop, fd, names, fn)
		unix.Close(fd)
	}
}

func awaitCreation(ctx context.Context, stop int, dir string) {
	fd, err := unix.InotifyInit1(unix.IN_CLOEXEC | unix.IN_NONBLOCK)
	if err != nil {
		return
	}
	defer unix.Close(fd)
	if _, err := unix.InotifyAddWatch(fd, filepath.Dir(dir), unix.IN_CREATE|unix.IN_MOVED_TO|unix.IN_ONLYDIR); err != nil {
		select {
		case <-ctx.Done():
		case <-time.After(5 * time.Second):
		}
		return
	}
	if exists(dir) {
		return
	}
	buf := make([]byte, 4096)
	for ctx.Err() == nil {
		if !wait(stop, fd) {
			return
		}
		got, _ := unix.Read(fd, buf)
		if got > 0 && exists(dir) {
			return
		}
	}
}

func exists(dir string) bool {
	var st unix.Stat_t
	return unix.Stat(dir, &st) == nil
}

func wait(stop, fd int) bool {
	fds := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}, {Fd: int32(stop), Events: unix.POLLIN}}
	for {
		_, err := unix.Poll(fds, -1)
		if err == unix.EINTR {
			continue
		}
		if err != nil || fds[1].Revents != 0 {
			return false
		}
		return fds[0].Revents != 0
	}
}

func follow(ctx context.Context, stop, fd int, names []string, fn func()) {
	buf := make([]byte, 4096)
	for ctx.Err() == nil {
		if !wait(stop, fd) {
			return
		}
		got, err := unix.Read(fd, buf)
		if err != nil || got <= 0 {
			continue
		}
		gone, changed := false, names == nil
		for off := 0; off+unix.SizeofInotifyEvent <= got; {
			ev := (*unix.InotifyEvent)(unsafe.Pointer(&buf[off]))
			end := min(got, off+unix.SizeofInotifyEvent+int(ev.Len))
			switch {
			case ev.Mask&(unix.IN_DELETE_SELF|unix.IN_MOVE_SELF|unix.IN_IGNORED) != 0:
				gone = true
			case ev.Mask&unix.IN_Q_OVERFLOW != 0:
				changed = true
			case !changed:
				name := string(bytes.TrimRight(buf[off+unix.SizeofInotifyEvent:end], "\x00"))
				changed = slices.Contains(names, name)
			}
			off = end
		}
		if changed || gone {
			fn()
		}
		if gone {
			return
		}
	}
}
