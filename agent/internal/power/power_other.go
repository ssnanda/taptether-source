//go:build !linux && !darwin && !windows

package power

import (
    "errors"
    "time"
)

func schedulePlatformShutdown(_ time.Duration) error {
    return errors.New("remote shutdown is not supported on this OS")
}
