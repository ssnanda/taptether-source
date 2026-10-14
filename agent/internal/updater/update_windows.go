//go:build windows

package updater

import (
    "errors"
    "os"
    "os/exec"
    "path/filepath"
    "sync"
    "time"
)

var updateMu sync.Mutex
var lastStart time.Time

func scriptPath() (string, error) {
    local := os.Getenv("LOCALAPPDATA")
    if local == "" { return "", errors.New("LOCALAPPDATA unavailable") }
    path := filepath.Join(local, "TapTether", "Update-TapTether.ps1")
    info, err := os.Stat(path)
    if err != nil { return "", err }
    if !info.Mode().IsRegular() { return "", errors.New("updater unavailable") }
    return path, nil
}

func Supported() bool {
    _, err := scriptPath()
    return err == nil
}
func Start() error {
    updateMu.Lock()
    defer updateMu.Unlock()
    if time.Since(lastStart) < 3*time.Minute {
        return errors.New("update requested recently")
    }
    script, err := scriptPath()
    if err != nil { return err }
    cmd := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive",
        "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass",
        "-File", script)
    cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, nil, nil
    if err := cmd.Start(); err != nil { return err }
    lastStart = time.Now()
    return cmd.Process.Release()
}
