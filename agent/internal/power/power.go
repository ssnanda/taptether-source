package power

import (
    "errors"
    "os"
    "path/filepath"
    "runtime"
    "time"
)

// Paired shutdown is on by default in the Windows agent, and enabled by the
// macOS/Ubuntu installers. A local computer owner can disable it at any time.
// The opt-out marker is in the per-user agent config directory, so it survives
// repairs and binary updates. This is checked on every request.
func Enabled() bool {
    if os.Getenv("TAPTETHER_ENABLE_SHUTDOWN") == "0" {
        return false
    }
    config, err := os.UserConfigDir()
    if err != nil {
        return false
    }
    marker := filepath.Join(config, "taptether", "remote-shutdown-disabled")
    if _, err := os.Stat(marker); err == nil {
        return false
    } else if !os.IsNotExist(err) {
        return false
    }
    return os.Getenv("TAPTETHER_ENABLE_SHUTDOWN") == "1" || runtime.GOOS == "windows"
}

func RequestShutdown() error {
    if !Enabled() {
        return errors.New("remote shutdown is disabled on this computer")
    }
    return schedulePlatformShutdown(800 * time.Millisecond)
}
