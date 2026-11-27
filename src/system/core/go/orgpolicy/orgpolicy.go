// Package orgpolicy reads the settings an organization applies to a managed
// device. The management agent writes them to File as a flat JSON object of
// strings; services read them and enforce the keys they own.
package orgpolicy

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/singularityos-lab/libsingularity/src/system/core/go/dirwatch"
)

const File = "/var/lib/sinty-it/policy.json"

const (
	ScreenLockAfter   = "screen.lock-after"
	USBStorage        = "usb.storage"
	SigninNoticeTitle = "signin.notice-title"
	SigninNoticeText  = "signin.notice-text"
	UpdatesDeferDays  = "updates.defer-days"
	UpdatesWindow     = "updates.window"
	KioskApp          = "kiosk.app"
)

type Storage string

const (
	StorageAllow    Storage = "allow"
	StorageReadOnly Storage = "read-only"
	StorageDeny     Storage = "deny"
)

type Policy map[string]string

func Read(path string) Policy {
	raw, err := os.ReadFile(path)
	if err != nil {
		return Policy{}
	}
	var all map[string]any
	if json.Unmarshal(raw, &all) != nil {
		return Policy{}
	}
	p := Policy{}
	for k, v := range all {
		if s, ok := v.(string); ok {
			p[k] = s
		}
	}
	return p
}

func (p Policy) Int(key string, fallback int) int {
	v, err := strconv.Atoi(strings.TrimSpace(p[key]))
	if err != nil {
		return fallback
	}
	return v
}

func (p Policy) Storage() Storage {
	switch s := Storage(strings.TrimSpace(p[USBStorage])); s {
	case StorageReadOnly, StorageDeny:
		return s
	}
	return StorageAllow
}

func Watch(ctx context.Context, path string, fn func(Policy)) {
	fn(Read(path))
	dirwatch.Files(ctx, filepath.Dir(path), []string{filepath.Base(path)}, func() { fn(Read(path)) })
}
