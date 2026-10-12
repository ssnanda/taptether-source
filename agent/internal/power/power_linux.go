//go:build linux

package power

import (
    "log"
    "os/exec"
    "time"
)

func schedulePlatformShutdown(delay time.Duration) error {
    bin, err := exec.LookPath("loginctl")
    if err != nil { return err }
    go func() {
        time.Sleep(delay)
        if output, err := exec.Command(bin, "poweroff").CombinedOutput(); err != nil {
            log.Printf("TapTether remote shutdown failed: %v (%s)", err, output)
        }
    }()
    return nil
}
