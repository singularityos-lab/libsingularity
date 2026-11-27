//go:build unix

package kernfs

import (
	"bytes"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

func TestReadFileMatchesOS(t *testing.T) {
	for _, path := range []string{"/proc/self/status", "/proc/self/maps", "/proc/cpuinfo"} {
		want, err := os.ReadFile(path)
		if err != nil {
			t.Skip(err)
		}
		got, err := ReadFile(path)
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		if path == "/proc/cpuinfo" && !bytes.Equal(got, want) {
			t.Fatalf("%s: %d bytes, want %d", path, len(got), len(want))
		}
		if len(got) == 0 {
			t.Fatalf("%s: empty", path)
		}
	}
}

func TestReadFileLarge(t *testing.T) {
	path := filepath.Join(t.TempDir(), "big")
	want := bytes.Repeat([]byte("0123456789abcdef"), 10000)
	if err := os.WriteFile(path, want, 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := ReadFile(path)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("got %d bytes, %v", len(got), err)
	}
}

func TestReadFileMissing(t *testing.T) {
	_, err := ReadFile(filepath.Join(t.TempDir(), "none"))
	if !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("err = %v", err)
	}
}

func TestReadFileEmpty(t *testing.T) {
	path := filepath.Join(t.TempDir(), "empty")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := ReadFile(path)
	if err != nil || len(got) != 0 {
		t.Fatalf("got %q, %v", got, err)
	}
}
