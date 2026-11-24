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
