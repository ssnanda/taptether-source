//go:build linux

package screencap

import (
    "os"
    "path/filepath"
)

// PolicyAllowed is controlled only by the local Ubuntu desktop user.
// The marker persists across logins, reboots, and agent updates. A missing
// marker preserves the existing default; unreadable/malformed state fails
// closed rather than silently allowing a screen read.
func PolicyAllowed() bool {
    home, err := os.UserHomeDir()
    if err != nil || home == "" {
        return false
    }
    path := filepath.Join(home, ".config", "taptether", "screen-sharing-disabled")
    _, err = os.Lstat(path)
    return os.IsNotExist(err)
}
