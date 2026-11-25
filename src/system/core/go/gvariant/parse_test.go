package gvariant

import (
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
)

func parseWithin(t *testing.T, s string, sig dbus.Signature) (dbus.Variant, error) {
	t.Helper()
	type result struct {
		v   dbus.Variant
		err error
	}
	done := make(chan result, 1)
	go func() {
		v, err := Parse(s, sig)
		done <- result{v, err}
	}()
	select {
	case r := <-done:
		return r.v, r.err
	case <-time.After(2 * time.Second):
		t.Fatalf("Parse(%q) did not return", s)
		return dbus.Variant{}, nil
	}
}

func TestUnicodeDigitIsRejected(t *testing.T) {
	for _, s := range []string{"٧", "[1, ٣]", "<١>", "{'a': １}"} {
		if _, err := parseWithin(t, s, dbus.Signature{}); err != ErrNumber {
			t.Fatalf("%q: got %v", s, err)
		}
	}
}

func TestUnicodeDigitInsideAStringIsKept(t *testing.T) {
	for _, s := range []string{"'٧'", "\"x٣\"", "'it\\'s ١'", "b'٢'"} {
		if _, err := parseWithin(t, s, dbus.Signature{}); err != nil {
			t.Fatalf("%q: %v", s, err)
		}
	}
}

func TestUnrepresentableKeyIsAnError(t *testing.T) {
	if _, err := parseWithin(t, "@a{bv} {}", dbus.Signature{}); err == nil {
		t.Fatal("a dictionary keyed by bool was accepted")
	}
}

func TestOrdinaryValues(t *testing.T) {
	cases := map[string]any{
		"@u 32":      uint32(32),
		"'10.0.0.2'": "10.0.0.2",
		"-7":         int32(-7),
		"['a', 'b']": []string{"a", "b"},
		"true":       true,
	}
	for s, want := range cases {
		v, err := parseWithin(t, s, dbus.Signature{})
		if err != nil {
			t.Fatalf("%q: %v", s, err)
		}
		if got := dbus.MakeVariant(want); v.String() != got.String() {
			t.Fatalf("%q: got %s, want %s", s, v, got)
		}
	}
}

func FuzzParse(f *testing.F) {
	f.Add("[{'address': <'10.0.0.2'>, 'prefix': <uint32 24>}]")
	f.Add("@a{sv} {}")
	f.Add("٧")
	f.Add("b'\\x00'")
	f.Fuzz(func(t *testing.T, s string) {
		_, _ = parseWithin(t, s, dbus.Signature{})
	})
}
