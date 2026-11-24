package netkind

import (
	"context"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// Watch calls fn once the directory exists and again after every file in it
// is written or replaced, until ctx ends. A directory that does not exist yet,
// or is removed, is waited for.
func Watch(ctx context.Context, dir string, fn func()) {
	for ctx.Err() == nil {
		fd, err := unix.InotifyInit1(unix.IN_CLOEXEC | unix.IN_NONBLOCK)
		if err != nil {
			return
		}
		if _, err := unix.InotifyAddWatch(fd, dir, unix.IN_CLOSE_WRITE|unix.IN_MOVED_TO|unix.IN_DELETE|unix.IN_DELETE_SELF|unix.IN_MOVE_SELF); err != nil {
			unix.Close(fd)
			select {
			case <-ctx.Done():
				return
			case <-time.After(5 * time.Second):
			}
			continue
		}
		fn()
		follow(ctx, fd, fn)
		unix.Close(fd)
	}
}

func follow(ctx context.Context, fd int, fn func()) {
	buf := make([]byte, 4096)
	fds := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}
	for ctx.Err() == nil {
		n, err := unix.Poll(fds, 1000)
		if err != nil && err != unix.EINTR {
			return
		}
		if n <= 0 {
			continue
		}
		got, err := unix.Read(fd, buf)
		if err != nil || got <= 0 {
			continue
		}
		gone := false
		for off := 0; off+unix.SizeofInotifyEvent <= got; {
			ev := (*unix.InotifyEvent)(unsafe.Pointer(&buf[off]))
			if ev.Mask&(unix.IN_DELETE_SELF|unix.IN_MOVE_SELF|unix.IN_IGNORED) != 0 {
				gone = true
			}
			off += unix.SizeofInotifyEvent + int(ev.Len)
		}
		fn()
		if gone {
			return
		}
	}
}
