//go:build linux

package screencap

import (
    "encoding/binary"
    "errors"
    "fmt"
    "io"
    "net"
    "os"
    "path/filepath"
    "time"
)

type Frame struct {
    JPEG []byte
    Width int
    Height int
}

// The screen helper lives in the desktop user's login session. It speaks over
// a 0600 Unix socket in /run/user/<uid>, never a public HTTP listener.
func screenSocket() string {
    dir := fmt.Sprintf("/run/user/%d", os.Getuid())
    if runtimeDir := os.Getenv("XDG_RUNTIME_DIR"); runtimeDir == dir {
        dir = runtimeDir
    }
    return filepath.Join(dir, "taptether-screen.sock")
}

// Available reports installed OS support, not whether a graphical session
// happens to be logged in at this instant. The UI must allow Snapshot/Live
// selection and show an actionable error if the screen helper is absent.
func Available() bool {
    info, err := os.Stat("/usr/share/taptether/taptether_screen.py")
    return err == nil && info.Mode().IsRegular()
}

func Capture() (Frame, error) {
    conn, err := net.DialTimeout("unix", screenSocket(), 1*time.Second)
    if err != nil {
        return Frame{}, errors.New("Ubuntu Screen helper is unavailable: sign in to the desktop and run the TapTether screen helper")
    }
    defer conn.Close()
    _ = conn.SetDeadline(time.Now().Add(9*time.Second))
    if _, err = conn.Write([]byte{'G'}); err != nil { return Frame{}, err }
    header := make([]byte, 12)
    if _, err = io.ReadFull(conn, header); err != nil { return Frame{}, fmt.Errorf("Ubuntu capture helper did not respond: %w", err) }
    width := int(binary.BigEndian.Uint32(header[0:4]))
    height := int(binary.BigEndian.Uint32(header[4:8]))
    size := int(binary.BigEndian.Uint32(header[8:12]))
    if size < 1 || size > 2<<20 {
        return Frame{}, errors.New("invalid Ubuntu capture frame size")
    }
    jpeg := make([]byte, size)
    if _, err = io.ReadFull(conn, jpeg); err != nil { return Frame{}, err }
    if width == 0 && height == 0 { return Frame{}, errors.New(string(jpeg)) }
    if width < 1 || width > 1280 || height < 1 || height > 720 {
        return Frame{}, fmt.Errorf("invalid Ubuntu capture dimensions %dx%d", width, height)
    }
    if len(jpeg) < 3 || jpeg[0] != 0xff || jpeg[1] != 0xd8 || jpeg[len(jpeg)-2] != 0xff || jpeg[len(jpeg)-1] != 0xd9 {
        return Frame{}, errors.New("invalid Ubuntu JPEG frame")
    }
    return Frame{JPEG:jpeg, Width:width, Height:height}, nil
}
