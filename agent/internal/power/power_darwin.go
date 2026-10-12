//go:build darwin

package power

import (
    "log"
    "os/exec"
    "time"
)

func schedulePlatformShutdown(delay time.Duration) error {
    bin, err := exec.LookPath("osascript")
    if err != nil { return err }
    go func() {
        time.Sleep(delay)
        // macOS may demand System Events automation approval from the desktop user.
        if output, err := exec.Command(bin, "-e", "tell application \"System Events\" to shut down").CombinedOutput(); err != nil {
            log.Printf("TapTether macOS shutdown failed: %v (%s)", err, output)
        }
    }()
    return nil
}
