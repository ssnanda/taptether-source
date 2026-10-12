//go:build darwin && !cgo

package input

import "errors"

// Native macOS input requires CGO_ENABLED=1 and Apple's CoreGraphics frameworks.
func Send(e Event) error {
    if e.Type == "ping" { return nil }
    return errors.New("macOS input unavailable: rebuild on macOS with CGO_ENABLED=1")
}
