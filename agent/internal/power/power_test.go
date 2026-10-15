package power

import (
    "os"
    "path/filepath"
    "runtime"
    "testing"
)

func TestShutdownRequiresConfiguredInstallerOnLinuxAndMac(t *testing.T) {
    home := t.TempDir()
    if runtime.GOOS == "windows" { t.Setenv("APPDATA", home) } else {
        t.Setenv("XDG_CONFIG_HOME", home)
    }
    t.Setenv("TAPTETHER_ENABLE_SHUTDOWN", "")
    if Enabled() != (runtime.GOOS == "windows") {
        t.Fatal("Windows defaults on; Linux and macOS use installer setting")
    }
}

func TestShutdownPersistentOptOut(t *testing.T) {
    home := t.TempDir()
    if runtime.GOOS == "windows" { t.Setenv("APPDATA", home) } else {
        t.Setenv("XDG_CONFIG_HOME", home)
    }
    t.Setenv("TAPTETHER_ENABLE_SHUTDOWN", "1")
    if !Enabled() { t.Fatal("installed agent should allow shutdown") }
    directory := filepath.Join(home, "taptether")
    if err := os.MkdirAll(directory, 0700); err != nil { t.Fatal(err) }
    marker := filepath.Join(directory, "remote-shutdown-disabled")
    if err := os.WriteFile(marker, []byte{}, 0600); err != nil { t.Fatal(err) }
    if Enabled() { t.Fatal("owner opt-out must disable without restart") }
    if err := os.Remove(marker); err != nil { t.Fatal(err) }
    if !Enabled() { t.Fatal("on must be restored without restart") }
    t.Setenv("TAPTETHER_ENABLE_SHUTDOWN", "0")
    if Enabled() { t.Fatal("explicit shutdown override must disable it") }
    if err := RequestShutdown(); err == nil {
        t.Fatal("disabled shutdown must refuse")
    }
}
