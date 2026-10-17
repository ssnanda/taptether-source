//go:build linux

package main

import (
    "errors"
    "fmt"
    "net"
    "os"
    "path/filepath"
    "time"
)

// The system service has no DISPLAY/Wayland session. Ask the same-user desktop
// helper to launch only the URL already validated by mediaDestination.
func linuxDesktopBrowser(address string) error {
    if len(address) > 256 {
        return errors.New("media URL too long")
    }
    path := filepath.Join(fmt.Sprintf("/run/user/%d", os.Getuid()), "taptether-screen.sock")
    conn, err := net.DialTimeout("unix", path, time.Second)
    if err != nil {
        return errors.New("Ubuntu desktop is not signed in; screen/media helper unavailable")
    }
    defer conn.Close()
    _ = conn.SetDeadline(time.Now().Add(7*time.Second))
    if _, err := conn.Write([]byte("O"+address+"\n")); err != nil { return err }
    var answer [1]byte
    if _, err := conn.Read(answer[:]); err != nil { return err }
    if answer[0] != 'Y' { return errors.New("Ubuntu default browser could not be opened") }
    return nil
}
