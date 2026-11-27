package orgpolicy

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadKeepsStringsOnly(t *testing.T) {
	path := filepath.Join(t.TempDir(), "policy.json")
	os.WriteFile(path, []byte(`{"usb.storage":"read-only","screen.lock-after":"300","bad":5}`), 0o644)
	p := Read(path)
	if p.Storage() != StorageReadOnly || p.Int(ScreenLockAfter, 0) != 300 {
		t.Fatalf("%v", p)
	}
	if _, ok := p["bad"]; ok {
		t.Fatal("non-string value kept")
	}
}

func TestMissingOrUnknownMeansAllow(t *testing.T) {
	if Read("/nonexistent/policy.json").Storage() != StorageAllow {
		t.Fatal("missing file")
	}
	if (Policy{USBStorage: "maybe"}).Storage() != StorageAllow {
		t.Fatal("unknown value")
	}
	if (Policy{UpdatesDeferDays: "x"}).Int(UpdatesDeferDays, 7) != 7 {
		t.Fatal("fallback")
	}
}
