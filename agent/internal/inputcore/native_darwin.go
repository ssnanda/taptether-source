//go:build darwin && cgo

package inputcore

/*
#cgo LDFLAGS: -framework ApplicationServices
#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <stdint.h>

static bool tt_trusted(void) { return AXIsProcessTrusted(); }
static bool tt_move(int dx, int dy) {
  CGEventRef current = CGEventCreate(NULL); if (!current) return false;
  CGPoint p = CGEventGetLocation(current); CFRelease(current); p.x += dx; p.y += dy;
  CGEventRef e = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, p, kCGMouseButtonLeft);
  if (!e) return false; CGEventPost(kCGHIDEventTap, e); CFRelease(e); return true;
}
static bool tt_button(int button, int clicks) {
  CGEventRef current = CGEventCreate(NULL); if (!current) return false;
  CGPoint p = CGEventGetLocation(current); CFRelease(current);
  CGMouseButton b = button == 1 ? kCGMouseButtonRight : kCGMouseButtonLeft;
  CGEventType down = button == 1 ? kCGEventRightMouseDown : kCGEventLeftMouseDown;
  CGEventType up = button == 1 ? kCGEventRightMouseUp : kCGEventLeftMouseUp;
  for (int i=0; i<clicks; i++) { CGEventRef d=CGEventCreateMouseEvent(NULL,down,p,b), u=CGEventCreateMouseEvent(NULL,up,p,b); if(!d||!u){if(d)CFRelease(d);if(u)CFRelease(u);return false;} CGEventSetIntegerValueField(d,kCGMouseEventClickState,i+1); CGEventSetIntegerValueField(u,kCGMouseEventClickState,i+1); CGEventPost(kCGHIDEventTap,d); CGEventPost(kCGHIDEventTap,u); CFRelease(d); CFRelease(u); }
  return true;
}
static bool tt_scroll(int delta) { CGEventRef e=CGEventCreateScrollWheelEvent(NULL,kCGScrollEventUnitLine,1,-delta); if(!e)return false; CGEventPost(kCGHIDEventTap,e); CFRelease(e); return true; }
static bool tt_key(int code, uint64_t flags) { CGEventRef d=CGEventCreateKeyboardEvent(NULL,(CGKeyCode)code,true),u=CGEventCreateKeyboardEvent(NULL,(CGKeyCode)code,false); if(!d||!u){if(d)CFRelease(d);if(u)CFRelease(u);return false;} CGEventSetFlags(d,flags);CGEventSetFlags(u,flags);CGEventPost(kCGHIDEventTap,d);CGEventPost(kCGHIDEventTap,u);CFRelease(d);CFRelease(u);return true; }
static bool tt_type(const uint16_t *chars,int count) { CGEventRef d=CGEventCreateKeyboardEvent(NULL,0,true),u=CGEventCreateKeyboardEvent(NULL,0,false);if(!d||!u){if(d)CFRelease(d);if(u)CFRelease(u);return false;}CGEventKeyboardSetUnicodeString(d,(UniCharCount)count,(const UniChar*)chars);CGEventKeyboardSetUnicodeString(u,(UniCharCount)count,(const UniChar*)chars);CGEventPost(kCGHIDEventTap,d);CGEventPost(kCGHIDEventTap,u);CFRelease(d);CFRelease(u);return true; }
*/
import "C"

import (
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"unicode/utf16"
	"unsafe"

	"github.com/ssnanda/taptether.com/agent/internal/input"
)

const (
	macShift   = uint64(C.kCGEventFlagMaskShift)
	macControl = uint64(C.kCGEventFlagMaskControl)
	macOption  = uint64(C.kCGEventFlagMaskAlternate)
	macCommand = uint64(C.kCGEventFlagMaskCommand)
)

var macCodes = map[string]int{"a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "space": 49, "tab": 48, "escape": 53, "esc": 53, "return": 36, "enter": 36, "backspace": 51, "delete": 117, "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "equal": 24, "minus": 27, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111}
var macModifiers = map[string]uint64{"ctrl": macControl, "control": macControl, "shift": macShift, "alt": macOption, "option": macOption, "cmd": macCommand, "command": macCommand, "meta": macCommand, "super": macCommand}

func Trusted() bool { return bool(C.tt_trusted()) }
func SendNative(e input.Event) error {
	if e.Type == "ping" {
		return nil
	}
	if e.Type == "key" && strings.HasPrefix(strings.ToLower(e.Key), "xf86audio") {
		return macVolume(e.Key)
	}
	if !Trusted() {
		return errors.New("allow TapTether Input Core in System Settings > Privacy & Security > Accessibility, then restart TapTether")
	}
	var ok bool
	switch e.Type {
	case "move":
		ok = bool(C.tt_move(C.int(e.DX), C.int(e.DY)))
	case "scroll":
		ok = bool(C.tt_scroll(C.int(e.DY)))
	case "click":
		b, c := 0, 1
		if e.Button == "right" {
			b = 1
		}
		if e.Button == "double" {
			c = 2
		}
		ok = bool(C.tt_button(C.int(b), C.int(c)))
	case "key":
		parts := strings.Split(strings.ToLower(strings.TrimSpace(e.Key)), "+")
		if len(parts) == 0 || len(parts) > 4 {
			return errors.New("invalid key combination")
		}
		var flags uint64
		for _, m := range parts[:len(parts)-1] {
			mask, found := macModifiers[m]
			if !found {
				return fmt.Errorf("unsupported modifier: %q", m)
			}
			flags |= mask
		}
		code, found := macCodes[parts[len(parts)-1]]
		if !found {
			return fmt.Errorf("unsupported macOS key: %q", e.Key)
		}
		ok = bool(C.tt_key(C.int(code), C.uint64_t(flags)))
	case "text":
		chars := utf16.Encode([]rune(e.Text))
		if len(chars) == 0 || len(chars) > 512 {
			return errors.New("unsupported text length")
		}
		ok = bool(C.tt_type((*C.uint16_t)(unsafe.Pointer(&chars[0])), C.int(len(chars))))
	default:
		return fmt.Errorf("unsupported event: %q", e.Type)
	}
	if !ok {
		return errors.New("macOS CoreGraphics input event failed")
	}
	return nil
}
func macVolume(key string) error {
	var script string
	switch strings.ToLower(key) {
	case "xf86audioraisevolume":
		script = "set v to output volume of (get volume settings)\nif v > 94 then\nset v to 94\nend if\nset volume output volume (v + 6)"
	case "xf86audiolowervolume":
		script = "set v to output volume of (get volume settings)\nif v < 6 then\nset v to 6\nend if\nset volume output volume (v - 6)"
	case "xf86audiomute":
		script = "set volume output muted (not (output muted of (get volume settings)))"
	default:
		return errors.New("unknown macOS media key")
	}
	out, err := exec.Command("osascript", "-e", script).CombinedOutput()
	if err != nil {
		return fmt.Errorf("volume command: %w (%s)", err, strings.TrimSpace(string(out)))
	}
	return nil
}
