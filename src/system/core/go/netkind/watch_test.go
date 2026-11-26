//go:build linux

package netkind

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestWatchSeesEveryChangeEvenAcrossARecreatedDirectory(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "sinty-nm")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	seen := make(chan Kind, 16)
	go Watch(ctx, dir, func() {
		if k, ok := Read(dir); ok {
			seen <- k
		}
	})
	expect := func(want Kind) {
		t.Helper()
		deadline := time.After(10 * time.Second)
		for {
			select {
			case k := <-seen:
				if k == want {
					return
				}
			case <-deadline:
				t.Fatalf("never saw %s", want)
			}
		}
	}
	time.Sleep(100 * time.Millisecond)
	Write(dir, Home, false)
	expect(Home)
	Write(dir, Public, true)
	expect(Public)
	os.RemoveAll(dir)
	time.Sleep(100 * time.Millisecond)
	Write(dir, Work, false)
	expect(Work)
}

func TestWatchReturnsAsSoonAsTheContextEnds(t *testing.T) {
	for _, present := range []bool{true, false} {
		dir := filepath.Join(t.TempDir(), "sinty-nm")
		if present {
			os.MkdirAll(dir, 0o755)
		}
		ctx, cancel := context.WithCancel(context.Background())
		finished := make(chan struct{})
		go func() {
			Watch(ctx, dir, func() {})
			close(finished)
		}()
		time.Sleep(100 * time.Millisecond)
		start := time.Now()
		cancel()
		select {
		case <-finished:
			if d := time.Since(start); d > 200*time.Millisecond {
				t.Fatalf("present=%v: returned after %v", present, d)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("present=%v: still running after cancel", present)
		}
	}
}

func TestWatchSeesADirectoryCreatedLaterAtOnce(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "sinty-nm")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	seen := make(chan Kind, 4)
	go Watch(ctx, dir, func() {
		if k, ok := Read(dir); ok {
			seen <- k
		}
	})
	time.Sleep(100 * time.Millisecond)
	start := time.Now()
	Write(dir, Home, false)
	select {
	case k := <-seen:
		if k != Home {
			t.Fatalf("saw %s", k)
		}
		if d := time.Since(start); d > time.Second {
			t.Fatalf("took %v", d)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("never saw the new directory")
	}
}
