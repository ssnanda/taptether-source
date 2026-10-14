//go:build windows

package input

// Native, dependency-free Windows SendInput backend. The agent must run in
// the logged-in user's interactive desktop, not a Session 0 Windows service.
// Windows blocks SendInput into elevated/secure desktops via UIPI.
import (
    "errors"
    "fmt"
    "strings"
    "syscall"
    "unicode/utf16"
    "unsafe"
)

var sendInputProc = syscall.NewLazyDLL("user32.dll").NewProc("SendInput")

const (
    inputMouse = 0
    inputKeyboard = 1
    mouseMove = 0x0001
    mouseLeftDown = 0x0002
    mouseLeftUp = 0x0004
    mouseRightDown = 0x0008
    mouseRightUp = 0x0010
    mouseWheel = 0x0800
    keyUp = 0x0002
    keyUnicode = 0x0004
    keyExtended = 0x0001
)

// x64 Windows INPUT is 40 bytes: a 4-byte type, 4-byte alignment padding,
// and a union whose largest member (MOUSEINPUT) occupies 32 bytes.
type winInput struct {
    kind uint32
    padding uint32
    payload [32]byte
}
type winMouse struct {
    dx int32
    dy int32
    data uint32
    flags uint32
    time uint32
    extra uintptr
}
type winKeyboard struct {
    virtualKey uint16
    scan uint16
    flags uint32
    time uint32
    extra uintptr
}

func mouse(dx, dy int32, data, flags uint32) winInput {
    var item winInput
    item.kind = inputMouse
    *(*winMouse)(unsafe.Pointer(&item.payload[0])) = winMouse{
        dx: dx, dy: dy, data: data, flags: flags,
    }
    return item
}
func keyboard(key uint16, flags uint32) winInput {
    var item winInput
    item.kind = inputKeyboard
    *(*winKeyboard)(unsafe.Pointer(&item.payload[0])) = winKeyboard{
        virtualKey: key, flags: flags,
    }
    return item
}
func unicodeKey(code uint16, flags uint32) winInput {
    var item winInput
    item.kind = inputKeyboard
    *(*winKeyboard)(unsafe.Pointer(&item.payload[0])) = winKeyboard{
        scan: code, flags: flags | keyUnicode,
    }
    return item
}
func inject(items ...winInput) error {
    if len(items) == 0 { return nil }
    n, _, err := sendInputProc.Call(
        uintptr(len(items)),
        uintptr(unsafe.Pointer(&items[0])),
        unsafe.Sizeof(items[0]),
    )
    if n != uintptr(len(items)) {
        if err != nil && err != syscall.Errno(0) { return fmt.Errorf("SendInput: %w", err) }
        return errors.New("Windows rejected synthetic input; run in the signed-in desktop")
    }
    return nil
}

var namedKeys = map[string]uint16{
    "tab":0x09, "enter":0x0D, "return":0x0D, "escape":0x1B, "esc":0x1B,
    "backspace":0x08, "space":0x20, "up":0x26, "down":0x28,
    "left":0x25, "right":0x27, "home":0x24, "end":0x23,
    "pageup":0x21, "pagedown":0x22, "delete":0x2E, "insert":0x2D,
    "xf86audioraisevolume":0xAF, "xf86audiolowervolume":0xAE,
    "xf86audiomute":0xAD, "minus":0xBD, "equal":0xBB,
}
var modifierKeys = map[string]uint16{
    "shift":0x10, "ctrl":0x11, "control":0x11,
    "alt":0x12, "option":0x12, "cmd":0x5B, "command":0x5B,
    "meta":0x5B, "super":0x5B, "win":0x5B,
}
func lookupKey(name string) (uint16, bool) {
    if v, ok := namedKeys[name]; ok { return v, true }
    if len(name) == 1 {
        c := name[0]
        if c >= 'a' && c <= 'z' { return uint16(c-'a') + 0x41, true }
        if c >= '0' && c <= '9' { return uint16(c), true }
    }
    if len(name) > 1 && name[0] == 'f' {
        var num int
        if _, err := fmt.Sscanf(name, "f%d", &num); err == nil &&
            num >= 1 && num <= 12 && name == fmt.Sprintf("f%d", num) {
            return uint16(num - 1 + 0x70), true
        }
    }
    return 0, false
}
func sendKey(value string) error {
    tokens := strings.Split(strings.ToLower(strings.TrimSpace(value)), "+")
    if len(tokens) == 0 || len(tokens) > 4 { return errors.New("invalid key combination") }
    modifiers := make([]uint16, 0, len(tokens)-1)
    for _, part := range tokens[:len(tokens)-1] {
        vk, found := modifierKeys[part]
        if !found { return fmt.Errorf("unsupported Windows modifier: %q", part) }
        modifiers = append(modifiers, vk)
    }
    vk, found := lookupKey(tokens[len(tokens)-1])
    if !found { return fmt.Errorf("unsupported Windows key: %q", value) }
    sequence := make([]winInput, 0, 2*(len(modifiers)+1))
    for _, mod := range modifiers { sequence = append(sequence, keyboard(mod, 0)) }
    sequence = append(sequence, keyboard(vk, 0), keyboard(vk, keyUp))
    for i := len(modifiers)-1; i >= 0; i-- {
        sequence = append(sequence, keyboard(modifiers[i], keyUp))
    }
    return inject(sequence...)
}
func sendText(value string) error {
    codes := utf16.Encode([]rune(value))
    if len(codes) == 0 || len(codes) > 256 { return errors.New("invalid text length") }
    // Keep SendInput batches reasonably small on constrained desktops.
    for start := 0; start < len(codes); start += 64 {
        end := start+64
        if end > len(codes) { end = len(codes) }
        entries := make([]winInput, 0, (end-start)*2)
        for _, code := range codes[start:end] {
            entries = append(entries, unicodeKey(code, 0), unicodeKey(code, keyUp))
        }
        if err := inject(entries...); err != nil { return err }
    }
    return nil
}
func Send(e Event) error {
    switch e.Type {
    case "ping": return nil
    case "move": return inject(mouse(int32(e.DX), int32(e.DY), 0, mouseMove))
    case "scroll":
        if e.DY == 0 { return nil }
        return inject(mouse(0, 0, uint32(int32(-e.DY*120)), mouseWheel))
    case "click":
        down, up, count := uint32(mouseLeftDown), uint32(mouseLeftUp), 1
        if e.Button == "right" { down, up = mouseRightDown, mouseRightUp }
        if e.Button == "double" { count = 2 }
        entries := make([]winInput, 0, count*2)
        for i:=0;i<count;i++ { entries = append(entries, mouse(0,0,0,down), mouse(0,0,0,up)) }
        return inject(entries...)
    case "key": return sendKey(e.Key)
    case "text": return sendText(e.Text)
    }
    return errors.New("unknown Windows input command")
}
