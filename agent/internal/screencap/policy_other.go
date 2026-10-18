//go:build !linux

package screencap

// Desktop sharing on macOS and Windows is governed by their existing
// native permission controls. The Ubuntu-only tray preference does not
// modify their established Screen Core, capture code or permissions.
func PolicyAllowed() bool { return true }
