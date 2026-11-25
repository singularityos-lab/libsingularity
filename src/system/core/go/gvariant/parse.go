// Package gvariant parses GVariant text without the inputs that stall the
// godbus lexer.
package gvariant

import (
	"errors"
	"fmt"
	"unicode"

	"github.com/godbus/dbus/v5"
)

// ErrNumber reports a digit outside ASCII where a number would start. The
// godbus lexer enters its number state on any Unicode digit but consumes only
// ASCII ones, so it never advances and grows its token list until memory runs out.
var ErrNumber = errors.New("gvariant: non-ASCII digit outside a string")

// Parse is dbus.ParseVariant for text that may come from a damaged or hostile
// file. It also returns an error where godbus panics, as it does for a
// dictionary whose key type Go cannot represent, such as "@a{bv} {}".
func Parse(s string, sig dbus.Signature) (v dbus.Variant, err error) {
	if err := check(s); err != nil {
		return dbus.Variant{}, err
	}
	defer func() {
		if r := recover(); r != nil {
			v, err = dbus.Variant{}, fmt.Errorf("gvariant: %v", r)
		}
	}()
	return dbus.ParseVariant(s, sig)
}

func check(s string) error {
	var quote rune
	escaped := false
	for _, r := range s {
		switch {
		case escaped:
			escaped = false
		case quote != 0 && r == '\\':
			escaped = true
		case quote != 0:
			if r == quote {
				quote = 0
			}
		case r == '\'' || r == '"':
			quote = r
		case r > unicode.MaxASCII && unicode.IsNumber(r):
			return ErrNumber
		}
	}
	return nil
}
