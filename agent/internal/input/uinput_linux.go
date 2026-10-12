//go:build linux

package input

import (
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
	"unsafe"
)

// TapTether uses the Linux virtual HID interface, rather than Wayland's
// RemoteDesktop portal. Access to /dev/uinput is restricted by a dedicated
// local group; this agent must NEVER run as root or expose an internet listener.
const (
	evSyn         = 0
	evKey         = 1
	evRel         = 2
	synReport     = 0
	relX          = 0
	relY          = 1
	relWheel      = 8
	btnLeft       = 0x110
	btnRight      = 0x111
	keyLeftShift  = 42
	keyLeftCtrl   = 29
	keyLeftAlt    = 56
	keyLeftMeta   = 125
	keyVolumeDown = 114
	keyVolumeUp   = 115
	keyMute       = 113
	uiDevCreate   = 0x5501
	uiDevDestroy  = 0x5502
	uiDevSetup    = 0x405c5503 // _IOW('U',3,struct uinput_setup), 92 bytes
	uiSetEvBit    = 0x40045564
	uiSetKeyBit   = 0x40045565
	uiSetRelBit   = 0x40045566
)

type uinputSetup struct {
	Bustype, Vendor, Product, Version uint16
	Name                              [80]byte
	MaxEffects                        uint32
}

type virtualDevice struct{ f *os.File }

var activeDevice *virtualDevice

func ioctl(fd uintptr, request, value uintptr) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, request, value)
	if errno != 0 {
		return errno
	}
	return nil
}

func newVirtualDevice() (*virtualDevice, error) {
	f, err := os.OpenFile("/dev/uinput", os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		if errors.Is(err, os.ErrPermission) {
			return nil, fmt.Errorf("/dev/uinput permission denied: run Ubuntu desktop setup and log out/in to activate the taptether group: %w", err)
		}
		return nil, fmt.Errorf("cannot open /dev/uinput (run sudo modprobe uinput and desktop setup): %w", err)
	}
	device := &virtualDevice{f: f}
	success := false
	defer func() {
		if !success {
			_ = f.Close()
		}
	}()
	if err := ioctl(f.Fd(), uiSetEvBit, evKey); err != nil {
		return nil, err
	}
	if err := ioctl(f.Fd(), uiSetEvBit, evRel); err != nil {
		return nil, err
	}
	for _, key := range allEnabledKeys() {
		if err := ioctl(f.Fd(), uiSetKeyBit, uintptr(key)); err != nil {
			return nil, fmt.Errorf("enable key %d: %w", key, err)
		}
	}
	for _, axis := range []int{relX, relY, relWheel} {
		if err := ioctl(f.Fd(), uiSetRelBit, uintptr(axis)); err != nil {
			return nil, err
		}
	}
	setup := uinputSetup{Bustype: 3, Vendor: 0xF07A, Product: 0x0001, Version: 1}
	copy(setup.Name[:], "TapTether Virtual Keyboard and Mouse")
	if err := ioctl(f.Fd(), uiDevSetup, uintptr(unsafe.Pointer(&setup))); err != nil {
		return nil, fmt.Errorf("uinput setup: %w", err)
	}
	if err := ioctl(f.Fd(), uiDevCreate, 0); err != nil {
		return nil, fmt.Errorf("uinput create: %w", err)
	}
	// Allow udev/libinput to enumerate the new virtual input device.
	time.Sleep(250 * time.Millisecond)
	success = true
	return device, nil
}

func (d *virtualDevice) emit(typ, code uint16, value int32) error {
	// 64-bit Linux struct input_event: timeval{int64,int64}, u16,u16,i32.
	var buf [24]byte
	binary.LittleEndian.PutUint16(buf[16:18], typ)
	binary.LittleEndian.PutUint16(buf[18:20], code)
	binary.LittleEndian.PutUint32(buf[20:24], uint32(value))
	_, err := d.f.Write(buf[:])
	return err
}
func (d *virtualDevice) sync() error { return d.emit(evSyn, synReport, 0) }
func (d *virtualDevice) press(code int) error {
	if err := d.emit(evKey, uint16(code), 1); err != nil {
		return err
	}
	if err := d.sync(); err != nil {
		return err
	}
	if err := d.emit(evKey, uint16(code), 0); err != nil {
		return err
	}
	return d.sync()
}
func (d *virtualDevice) chord(keys []int) (err error) {
	// Always release held keys even on write failure.
	defer func() {
		for i := len(keys) - 1; i >= 0; i-- {
			_ = d.emit(evKey, uint16(keys[i]), 0)
		}
		_ = d.sync()
	}()
	for _, k := range keys {
		if err = d.emit(evKey, uint16(k), 1); err != nil {
			return err
		}
	}
	return d.sync()
}
func (d *virtualDevice) send(e Event) error {
	switch e.Type {
	case "ping":
		return nil
	case "move":
		if err := d.emit(evRel, relX, int32(e.DX)); err != nil {
			return err
		}
		if err := d.emit(evRel, relY, int32(e.DY)); err != nil {
			return err
		}
		return d.sync()
	case "scroll":
		if e.DY == 0 {
			return nil
		}
		ticks := e.DY
		if ticks > 8 {
			ticks = 8
		}
		if ticks < -8 {
			ticks = -8
		}
		return d.emitAndSync(evRel, relWheel, int32(-ticks))
	case "click":
		key := btnLeft
		if e.Button == "right" {
			key = btnRight
		}
		if err := d.press(key); err != nil {
			return err
		}
		if e.Button == "double" {
			return d.press(key)
		}
		return nil
	case "key":
		keys, err := parseChord(e.Key)
		if err != nil {
			return err
		}
		return d.chord(keys)
	case "text":
		if !utf8.ValidString(e.Text) {
			return errors.New("invalid UTF-8 text")
		}
		for _, r := range e.Text {
			code, shifted, ok := asciiKey(r)
			if !ok {
				return fmt.Errorf("Wayland text input currently supports ASCII; unsupported character %q", r)
			}
			if shifted {
				if err := d.chord([]int{keyLeftShift, code}); err != nil {
					return err
				}
			} else if err := d.press(code); err != nil {
				return err
			}
		}
		return nil
	default:
		return fmt.Errorf("unknown input type %q", e.Type)
	}
}
func (d *virtualDevice) emitAndSync(typ, code uint16, val int32) error {
	if err := d.emit(typ, code, val); err != nil {
		return err
	}
	return d.sync()
}

var namedKeys = map[string]int{
	"escape": 1, "esc": 1, "tab": 15, "return": 28, "enter": 28, "backspace": 14,
	"up": 103, "down": 108, "left": 105, "right": 106, "space": 57, "delete": 111,
	"ctrl": keyLeftCtrl, "control": keyLeftCtrl, "alt": keyLeftAlt, "shift": keyLeftShift, "super": keyLeftMeta, "meta": keyLeftMeta,
	"xf86audioraisevolume": keyVolumeUp, "xf86audiolowervolume": keyVolumeDown, "xf86audiomute": keyMute,
}
var asciiCodes = map[rune]int{
	'1': 2, '2': 3, '3': 4, '4': 5, '5': 6, '6': 7, '7': 8, '8': 9, '9': 10, '0': 11,
	'-': 12, '=': 13, '[': 26, ']': 27, ';': 39, '\'': 40, '`': 41, '\\': 43, ',': 51, '.': 52, '/': 53,
	'q': 16, 'w': 17, 'e': 18, 'r': 19, 't': 20, 'y': 21, 'u': 22, 'i': 23, 'o': 24, 'p': 25,
	'a': 30, 's': 31, 'd': 32, 'f': 33, 'g': 34, 'h': 35, 'j': 36, 'k': 37, 'l': 38,
	'z': 44, 'x': 45, 'c': 46, 'v': 47, 'b': 48, 'n': 49, 'm': 50,
	' ': 57, '\t': 15, '\n': 28,
}
var shiftedSymbols = map[rune]rune{
	'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7', '*': '8', '(': '9', ')': '0',
	'_': '-', '+': '=', '{': '[', '}': ']', ':': ';', '"': '\'', '~': '`', '|': '\\', '<': ',', '>': '.', '?': '/',
}

func asciiKey(r rune) (int, bool, bool) {
	if r >= 'A' && r <= 'Z' {
		return asciiCodes[r+('a'-'A')], true, true
	}
	if val, ok := asciiCodes[r]; ok {
		return val, false, true
	}
	if raw, ok := shiftedSymbols[r]; ok {
		return asciiCodes[raw], true, true
	}
	return 0, false, false
}
func parseChord(raw string) ([]int, error) {
	parts := strings.Split(strings.ToLower(strings.TrimSpace(raw)), "+")
	if len(parts) > 4 {
		return nil, errors.New("key combination too long")
	}
	result := make([]int, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if val, ok := namedKeys[p]; ok {
			result = append(result, val)
			continue
		}
		if len(p) == 1 {
			if val, ok := asciiCodes[rune(p[0])]; ok {
				result = append(result, val)
				continue
			}
		}
		return nil, fmt.Errorf("unsupported key: %q", p)
	}
	return result, nil
}
func allEnabledKeys() []int {
	seen := map[int]bool{}
	for _, code := range namedKeys {
		seen[code] = true
	}
	for _, code := range asciiCodes {
		seen[code] = true
	}
	seen[btnLeft] = true
	seen[btnRight] = true
	keys := make([]int, 0, len(seen))
	for key := range seen {
		keys = append(keys, key)
	}
	return keys
}

func uinputSetupSize() uintptr { return unsafe.Sizeof(uinputSetup{}) }
