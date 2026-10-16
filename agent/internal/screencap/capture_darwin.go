//go:build darwin && cgo

// Package screencap uses ScreenCaptureKit to capture the primary macOS
// display. Bytes remain in memory; Screen Recording consent is mandatory.
package screencap

/*
#cgo LDFLAGS: -framework ScreenCaptureKit -framework ApplicationServices -framework Foundation
#include <stdbool.h>
#include <stdlib.h>

bool tt_capture_supported(void);
bool tt_capture_permitted(void);
void tt_request_capture_access(void);
void *tt_primary_display(int *outW, int *outH);
*/
import "C"

import (
    "bytes"
    "errors"
    "image"
    "image/jpeg"
    "sync"
    "unsafe"
)

var requestAccess sync.Once

type Frame struct {
    JPEG []byte
    Width int
    Height int
}

func Available() bool { return bool(C.tt_capture_supported()) }

func Capture() (Frame, error) {
    if !Available() {
        return Frame{}, errors.New("ScreenCaptureKit screenshots require macOS 14 or newer")
    }
    if !bool(C.tt_capture_permitted()) {
        requestAccess.Do(func() { C.tt_request_capture_access() })
        return Frame{}, errors.New("allow Screen Recording for TapTether Agent in macOS System Settings > Privacy & Security, then restart the agent")
    }
    var w, h C.int
    ptr := C.tt_primary_display(&w, &h)
    if ptr == nil {
        return Frame{}, errors.New("ScreenCaptureKit could not capture the main display; verify the desktop session and permission")
    }
    defer C.free(ptr)
    size := int(w) * int(h) * 4
    if size < 4 || size > 1280*720*4 {
        return Frame{}, errors.New("capture dimensions outside safety limits")
    }
    pixels := C.GoBytes(unsafe.Pointer(ptr), C.int(size))
    picture := &image.RGBA{Pix:pixels, Stride:int(w)*4, Rect:image.Rect(0,0,int(w),int(h))}
    var buffer bytes.Buffer
    if err := jpeg.Encode(&buffer, picture, &jpeg.Options{Quality:68}); err != nil {
        return Frame{}, err
    }
    if buffer.Len() > 2<<20 {
        return Frame{}, errors.New("screen image exceeds transfer limit")
    }
    return Frame{JPEG:buffer.Bytes(), Width:int(w), Height:int(h)}, nil
}
