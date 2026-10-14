//go:build linux

package updater

import (
    "errors"
    "os"
    "os/exec"
    "path/filepath"
    "sync"
    "time"
)

// Ubuntu package upgrades require elevated privileges. This is available
// only where the computer owner has ALREADY configured noninteractive sudo.
// No sudoers entries are added and no authorization is bypassed.
var updateMu sync.Mutex
var lastStart time.Time

func helper() (string, error) {
    home, err := os.UserHomeDir()
    if err != nil { return "", err }
    path := filepath.Join(home, ".local", "bin", "taptether-agent-update")
    stat, err := os.Lstat(path)
    if err != nil { return "", err }
    if !stat.Mode().IsRegular() || stat.Mode().Perm()&0111 == 0 {
        return "", errors.New("installed agent update helper is unavailable")
    }
    return path, nil
}

func Supported() bool {
    if _, err := helper(); err != nil { return false }
    // Never trigger an interactive sudo prompt inside a background service.
    check := exec.Command("sudo", "-n", "true")
    return check.Run() == nil
}

func Start() error {
    updateMu.Lock()
    defer updateMu.Unlock()
    if time.Since(lastStart) < 3*time.Minute {
        return errors.New("update was already requested")
    }
    path, err := helper()
    if err != nil { return err }
    if !Supported() {
        return errors.New("agent update requires preconfigured passwordless sudo")
    }
    cmd := exec.Command("/bin/bash", path, "update")
    cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, nil, nil
    if err := cmd.Start(); err != nil { return err }
    lastStart = time.Now()
    return cmd.Process.Release()
}
