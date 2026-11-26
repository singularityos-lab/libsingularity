//go:build linux

package dirwatch

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func replace(t *testing.T, path, data string) {
	t.Helper()
	tmp := path + "+"
	if err := os.WriteFile(tmp, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tmp, path); err != nil {
		t.Fatal(err)
	}
}

func TestOnlyTheNamedFilesWakeTheWatcher(t *testing.T) {
	dir := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls := make(chan struct{}, 16)
	go Files(ctx, dir, []string{"passwd", "group"}, func() { calls <- struct{}{} })
	expect := func(want bool, what string) {
		t.Helper()
		select {
		case <-calls:
			if !want {
				t.Fatalf("%s woke the watcher", what)
			}
		case <-time.After(300 * time.Millisecond):
			if want {
				t.Fatalf("%s did not wake the watcher", what)
			}
		}
	}
	expect(true, "the start")
	os.WriteFile(filepath.Join(dir, "resolv.conf"), []byte("nameserver 1.1.1.1\n"), 0o644)
	expect(false, "another file")
	replace(t, filepath.Join(dir, "passwd"), "root:x:0:0::/root:/bin/sh\n")
	expect(true, "a replaced passwd")
	os.WriteFile(filepath.Join(dir, "group"), []byte("wheel:x:10:\n"), 0o644)
	expect(true, "a written group")
	expect(false, "nothing")
}

func TestEveryFileWakesAnUnfilteredWatcher(t *testing.T) {
	dir := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls := make(chan struct{}, 16)
	go Watch(ctx, dir, func() { calls <- struct{}{} })
	<-calls
	os.WriteFile(filepath.Join(dir, "anything"), []byte("x"), 0o644)
	select {
	case <-calls:
	case <-time.After(2 * time.Second):
		t.Fatal("a write was missed")
	}
}
