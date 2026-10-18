//go:build (!darwin && !windows && !linux) || (darwin && !cgo)

package screencap

import "errors"

type Frame struct {
    JPEG []byte
    Width int
    Height int
}

func Available() bool { return false }

func Capture() (Frame, error) {
    return Frame{}, errors.New("screen capture currently requires the macOS agent with Screen Recording permission")
}

func CaptureDetail() (Frame, error) {
    return Frame{}, errors.New("high-detail screen capture unavailable on this platform")
}
