//go:build unix

// Package kernfs reads the small files the kernel generates under /sys and
// /proc without going through the runtime poller. Those files always report
// ready, so os.ReadFile wakes the poller thread on every read; a service that
// samples many of them on a timer pays that wakeup for each file.
package kernfs

import (
	"os"

	"golang.org/x/sys/unix"
)

// ReadFile returns the contents of path, read with blocking system calls.
func ReadFile(path string) ([]byte, error) {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_CLOEXEC, 0)
	for err == unix.EINTR {
		fd, err = unix.Open(path, unix.O_RDONLY|unix.O_CLOEXEC, 0)
	}
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	defer unix.Close(fd)
	buf := make([]byte, 0, 512)
	for {
		if len(buf) == cap(buf) {
			buf = append(buf, 0)[:len(buf)]
		}
		n, err := unix.Read(fd, buf[len(buf):cap(buf)])
		if err == unix.EINTR {
			continue
		}
		if err != nil {
			return nil, &os.PathError{Op: "read", Path: path, Err: err}
		}
		if n == 0 {
			return buf, nil
		}
		buf = buf[:len(buf)+n]
	}
}
