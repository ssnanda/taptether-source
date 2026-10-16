//go:build windows

// Package screencap captures the signed-in Windows interactive desktop.
// GDI is a conservative snapshot implementation; Windows Graphics Capture
// remains the preferred future live-stream backend.
package screencap

import (
    "bytes"
    "errors"
    "image"
    "image/jpeg"
    "syscall"
    "unsafe"
)

type Frame struct {
    JPEG []byte
    Width int
    Height int
}

var (
    user32 = syscall.NewLazyDLL("user32.dll")
    gdi32 = syscall.NewLazyDLL("gdi32.dll")
    getSystemMetrics = user32.NewProc("GetSystemMetrics")
    getDC = user32.NewProc("GetDC")
    releaseDC = user32.NewProc("ReleaseDC")
    createCompatibleDC = gdi32.NewProc("CreateCompatibleDC")
    deleteDC = gdi32.NewProc("DeleteDC")
    createDIBSection = gdi32.NewProc("CreateDIBSection")
    selectObject = gdi32.NewProc("SelectObject")
    deleteObject = gdi32.NewProc("DeleteObject")
    stretchBlt = gdi32.NewProc("StretchBlt")
    setStretchBltMode = gdi32.NewProc("SetStretchBltMode")
)

type bitmapInfoHeader struct {
    Size uint32
    Width int32
    Height int32
    Planes uint16
    BitCount uint16
    Compression uint32
    SizeImage uint32
    XPixelsPerMeter int32
    YPixelsPerMeter int32
    ColorsUsed uint32
    ColorsImportant uint32
}
type bitmapInfo struct {
    Header bitmapInfoHeader
    Colors [1]uint32
}

func Available() bool { return true }

func Capture() (Frame, error) {
    widthValue, _, _ := getSystemMetrics.Call(0)
    heightValue, _, _ := getSystemMetrics.Call(1)
    width, height := int(int32(widthValue)), int(int32(heightValue))
    if width <= 0 || height <= 0 || width > 16384 || height > 16384 {
        return Frame{}, errors.New("Windows has no usable primary interactive display")
    }
    ratio := 1.0
    if p:=1280.0/float64(width); p<ratio { ratio=p }
    if p:=720.0/float64(height); p<ratio { ratio=p }
    targetWidth, targetHeight := int(float64(width)*ratio), int(float64(height)*ratio)
    if targetWidth < 1 || targetHeight < 1 || targetWidth > 1280 || targetHeight > 720 {
        return Frame{}, errors.New("Windows screen dimensions outside capture limits")
    }
    desktopDC, _, _ := getDC.Call(0)
    if desktopDC == 0 { return Frame{}, errors.New("Windows desktop is unavailable") }
    defer releaseDC.Call(0, desktopDC)
    memoryDC, _, _ := createCompatibleDC.Call(desktopDC)
    if memoryDC == 0 { return Frame{}, errors.New("Windows screen capture context unavailable") }
    defer deleteDC.Call(memoryDC)

    bitmap := bitmapInfo{Header: bitmapInfoHeader{
        Size: uint32(unsafe.Sizeof(bitmapInfoHeader{})),
        Width: int32(targetWidth), Height: -int32(targetHeight),
        Planes: 1, BitCount: 32, Compression: 0,
    }}
    var pixelPtr uintptr
    dib, _, _ := createDIBSection.Call(desktopDC,
        uintptr(unsafe.Pointer(&bitmap)), 0,
        uintptr(unsafe.Pointer(&pixelPtr)), 0, 0)
    if dib == 0 || pixelPtr == 0 {
        return Frame{}, errors.New("Windows screenshot bitmap allocation failed")
    }
    defer deleteObject.Call(dib)
    old, _, _ := selectObject.Call(memoryDC, dib)
    if old == 0 { return Frame{}, errors.New("Windows screenshot bitmap selection failed") }
    defer selectObject.Call(memoryDC, old)
    // HALFTONE downsampling on the in-memory bitmap; do not write a BMP file.
    setStretchBltMode.Call(memoryDC, 4)
    const srccopy = 0x00CC0020
    ok, _, _ := stretchBlt.Call(memoryDC, 0, 0,
        uintptr(targetWidth), uintptr(targetHeight),
        desktopDC, 0, 0, uintptr(width), uintptr(height), srccopy)
    if ok == 0 { return Frame{}, errors.New("Windows screen read failed") }

    size := targetWidth*targetHeight*4
    if size == 0 || size > 1280*720*4 {
        return Frame{}, errors.New("Windows screenshot exceeds safe dimensions")
    }
    source := unsafe.Slice((*byte)(unsafe.Pointer(pixelPtr)), size)
    rgba := image.NewRGBA(image.Rect(0, 0, targetWidth, targetHeight))
    for i:=0;i<size;i+=4 {
        rgba.Pix[i] = source[i+2]
        rgba.Pix[i+1] = source[i+1]
        rgba.Pix[i+2] = source[i]
        rgba.Pix[i+3] = 255
    }
    var output bytes.Buffer
    if err := jpeg.Encode(&output, rgba, &jpeg.Options{Quality:68}); err != nil {
        return Frame{}, err
    }
    if output.Len() > 2<<20 {
        return Frame{}, errors.New("Windows snapshot exceeds safe transfer size")
    }
    return Frame{JPEG:output.Bytes(), Width:targetWidth, Height:targetHeight}, nil
}
