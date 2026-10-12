package power

import (
    "errors"
    "os"
    "time"
)

// Shutdown is disabled until the computer owner explicitly enables it.
func Enabled() bool { return os.Getenv("TAPTETHER_ENABLE_SHUTDOWN") == "1" }

func RequestShutdown() error {
    if !Enabled() {
        return errors.New("remote shutdown is disabled on this computer")
    }
    return schedulePlatformShutdown(800 * time.Millisecond)
}
