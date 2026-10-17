//go:build linux

package input

import (
    "errors"
    "fmt"
    "os"
    "syscall"
    "time"
    "unsafe"
)

// A dedicated tablet-style absolute pointer maps taps in the phone's
// Snapshot/Live frame to coordinates without moving the existing mouse core
// or requiring X11-only tools. The Linux service's restricted /dev/uinput group
// remains the only elevated permission.
const (
    evAbs = 3
    absX = 0
    absY = 1
    uiSetAbsBit = 0x40045567
    uiAbsSetup = 0x401c5504
)

type absInfo struct {
    Value int32
    Minimum int32
    Maximum int32
    Fuzz int32
    Flat int32
    Resolution int32
}
type absSetup struct {
    Code uint16
    Pad uint16
    Info absInfo
}

var tabletDevice *virtualDevice

func openAbsoluteDevice() (*virtualDevice, error) {
    if unsafe.Sizeof(absSetup{}) != 28 {
        return nil, errors.New("unexpected Linux absolute-axis ioctl ABI")
    }
    f, err := os.OpenFile("/dev/uinput", os.O_WRONLY|syscall.O_NONBLOCK, 0)
    if err != nil { return nil, fmt.Errorf("Ubuntu virtual pointer requires /dev/uinput: %w", err) }
    valid := false
    defer func() { if !valid { _ = f.Close() } }()
    for _, typ := range []uintptr{evKey, evAbs} {
        if err = ioctl(f.Fd(), uiSetEvBit, typ); err != nil { return nil, err }
    }
    for _, key := range []uintptr{btnLeft, btnRight} {
        if err = ioctl(f.Fd(), uiSetKeyBit, key); err != nil { return nil, err }
    }
    for _, axis := range []uint16{absX, absY} {
        if err = ioctl(f.Fd(), uiSetAbsBit, uintptr(axis)); err != nil { return nil, err }
        setup := absSetup{Code: axis, Info: absInfo{Minimum: 0, Maximum: 10000}}
        if err = ioctl(f.Fd(), uiAbsSetup, uintptr(unsafe.Pointer(&setup))); err != nil { return nil, err }
    }
    device := uinputSetup{Bustype: 3, Vendor: 0xF07A, Product: 0x0002, Version: 1}
    copy(device.Name[:], "TapTether Absolute Screen Pointer")
    if err = ioctl(f.Fd(), uiDevSetup, uintptr(unsafe.Pointer(&device))); err != nil { return nil, err }
    if err = ioctl(f.Fd(), uiDevCreate, 0); err != nil { return nil, err }
    time.Sleep(250 * time.Millisecond)
    valid = true
    return &virtualDevice{f: f}, nil
}

func sendTap(e Event) error {
    if tabletDevice == nil {
        device, err := openAbsoluteDevice()
        if err != nil { return fmt.Errorf("Ubuntu screen tapping unavailable: %w", err) }
        tabletDevice = device
    }
    if err := tabletDevice.emit(evAbs, absX, int32(e.X)); err != nil { return err }
    if err := tabletDevice.emit(evAbs, absY, int32(e.Y)); err != nil { return err }
    if err := tabletDevice.sync(); err != nil { return err }
    key := btnLeft
    if e.Button == "right" { key = btnRight }
    if err := tabletDevice.press(key); err != nil { return err }
    if e.Button == "double" { return tabletDevice.press(key) }
    return nil
}
