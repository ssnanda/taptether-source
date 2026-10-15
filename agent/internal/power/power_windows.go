//go:build windows

package power

import (
    "log"
    "os/exec"
    "time"
)

// Shutdown is requested only after a paired, authenticated mobile command.
// Using the interactive user's shutdown.exe requires no extra service rights.
func schedulePlatformShutdown(delay time.Duration) error {
    path, err := exec.LookPath("shutdown.exe")
    if err != nil { return err }
    go func() {
        time.Sleep(delay)
        // Windows informs the signed-in user about pending system shutdown.
        // A five-second grace period provides a brief chance to abort.
        if output, err := exec.Command(path, "/s", "/t", "5").CombinedOutput(); err != nil {
            log.Printf("TapTether Windows shutdown failed: %v (%s)", err, output)
        }
    }()
    return nil
}
