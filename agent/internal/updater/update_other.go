//go:build !darwin

package updater

import "errors"

// Ubuntu needs privileged package installation and Windows requires its own
// signed updater. Neither silently elevates through a remote control service.
func Supported() bool { return false }

func Start() error {
    return errors.New("on-device update not available for this platform")
}
