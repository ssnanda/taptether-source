//go:build linux

package screencap

import (
    "os"
    "path/filepath"
    "testing"
)

func TestUbuntuScreenSharingPolicy(t *testing.T) {
    home := t.TempDir()
    t.Setenv("HOME", home)
    if !PolicyAllowed() {
        t.Fatal("existing Ubuntu installations should initially allow screen sharing")
    }
    dir := filepath.Join(home, ".config", "taptether")
    if err := os.MkdirAll(dir, 0700); err != nil { t.Fatal(err) }
    marker := filepath.Join(dir, "screen-sharing-disabled")
    if err := os.WriteFile(marker, nil, 0600); err != nil { t.Fatal(err) }
    if PolicyAllowed() { t.Fatal("sharing must be blocked with marker present") }
    if _, err := Capture(); err == nil {
        t.Fatal("blocked capture should be rejected before dialing any screen helper")
    }
    if err := os.Remove(marker); err != nil { t.Fatal(err) }
    if !PolicyAllowed() { t.Fatal("sharing should re-enable when marker removed") }
    if err := os.Symlink(filepath.Join(dir, "missing"), marker); err != nil { t.Fatal(err) }
    if PolicyAllowed() { t.Fatal("broken symlink must not re-enable sharing") }
}
