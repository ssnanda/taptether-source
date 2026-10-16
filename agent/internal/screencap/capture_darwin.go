//go:build darwin && cgo

// Package screencap captures the primary macOS display in memory only.
// macOS Screen Recording approval is separate from Input Core Accessibility.
package screencap

/*
#cgo LDFLAGS: -framework ApplicationServices
#include <ApplicationServices/ApplicationServices.h>
#include <stdlib.h>
#include <stdbool.h>
#include <math.h>

static bool tt_capture_permitted(void) {
  return CGPreflightScreenCaptureAccess();
}
static void tt_request_capture_access(void) {
  CGRequestScreenCaptureAccess();
}
static void *tt_primary_display(int *outW, int *outH) {
  CGImageRef src = CGDisplayCreateImage(CGMainDisplayID());
  if (src == NULL) return NULL;
  size_t originalW = CGImageGetWidth(src), originalH = CGImageGetHeight(src);
  if (originalW == 0 || originalH == 0) { CGImageRelease(src); return NULL; }
  double ratio = fmin(1280.0/(double)originalW, 720.0/(double)originalH);
  if (ratio > 1.0) ratio = 1.0;
  size_t w = (size_t)((double)originalW * ratio);
  size_t h = (size_t)((double)originalH * ratio);
  if (w == 0 || h == 0 || w > 1280 || h > 720) { CGImageRelease(src); return NULL; }
  void *pixels = calloc(w * h, 4);
  if (!pixels) { CGImageRelease(src); return NULL; }
  CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(pixels, w, h, 8, w*4, colors,
      kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(colors);
  if (!ctx) { CGImageRelease(src); free(pixels); return NULL; }
  CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), src);
  CGContextRelease(ctx);
  CGImageRelease(src);
  *outW = (int)w; *outH = (int)h;
  return pixels;
}
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

func Available() bool { return true }

func Capture() (Frame, error) {
    if !bool(C.tt_capture_permitted()) {
        requestAccess.Do(func() { C.tt_request_capture_access() })
        return Frame{}, errors.New("allow Screen Recording for TapTether Agent in macOS System Settings > Privacy & Security, then restart the agent")
    }
    var w, h C.int
    ptr := C.tt_primary_display(&w, &h)
    if ptr == nil {
        return Frame{}, errors.New("macOS display capture unavailable; verify the desktop session and Screen Recording permission")
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
