//go:build linux

package updater

import (
    "errors"
    "os"
    "os/exec"
    "sync"
    "time"
)

// An installer-managed, narrowly authorized systemd unit performs package
// updates as root. The input agent itself remains unprivileged and cannot
// execute arbitrary commands or use sudo (NoNewPrivileges=true).
var updateMu sync.Mutex
var lastStart time.Time

func Supported() bool {
    info, err := os.Stat("/etc/systemd/system/taptether-update.service")
    return err == nil && info.Mode().IsRegular()
}

func Start() error {
    updateMu.Lock()
    defer updateMu.Unlock()
    if !Supported() {
        return errors.New("install the new Ubuntu update service first")
    }
    if time.Since(lastStart) < 3*time.Minute {
        return errors.New("update already requested")
    }
    // A fixed systemd unit, with a polkit rule restricted to this single
    // operation, avoids broad passwordless sudo rights for the agent.
    cmd := exec.Command("systemctl", "start", "--no-block", "taptether-update.service")
    cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, nil, nil
    if err := cmd.Run(); err != nil { return err }
    lastStart = time.Now()
    return nil
}
