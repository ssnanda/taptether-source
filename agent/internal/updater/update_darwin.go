//go:build darwin

package updater

import (
    "errors"
    "os"
    "os/exec"
    "path/filepath"
    "sync"
    "time"
)

// Only the installed, local, SHA-256-verifying updater may run.
// This is a per-user LaunchAgent and does not require sudo.
var updateMu sync.Mutex
var lastStart time.Time

func Supported() bool { return true }

func Start() error {
    updateMu.Lock()
    defer updateMu.Unlock()
    if time.Since(lastStart) < 3*time.Minute {
        return errors.New("update already requested recently")
    }
    home, err := os.UserHomeDir()
    if err != nil { return err }
    script := filepath.Join(home, ".local", "bin", "taptether-agent-update-mac")
    info, err := os.Lstat(script)
    if err != nil { return err }
    if !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
        return errors.New("installed update helper is not executable")
    }
    cmd := exec.Command("/bin/bash", script, "update")
    cmd.Stdin = nil
    cmd.Stdout = nil
    cmd.Stderr = nil
    if err := cmd.Start(); err != nil { return err }
    lastStart = time.Now()
    return cmd.Process.Release()
}
