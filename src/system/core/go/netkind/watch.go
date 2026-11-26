//go:build linux

package netkind

import (
	"context"

	"github.com/singularityos-lab/libsingularity/src/system/core/go/dirwatch"
)

// Watch calls fn once the directory exists and again after every file in it
// is written or replaced, until ctx ends. A directory that does not exist yet,
// or is removed, is waited for.
func Watch(ctx context.Context, dir string, fn func()) {
	dirwatch.Watch(ctx, dir, fn)
}
