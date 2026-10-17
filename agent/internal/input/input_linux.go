//go:build linux

package input

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// uinput works on Wayland and X11 without RemoteDesktop portal popups.
// On X11 only, xdotool is a compatibility fallback if uinput is unavailable.
func Send(e Event) error {
	if e.Type == "ping" {
		return nil
	}
	if e.Type == "tap" {
		return sendTap(e)
	}
	if activeDevice == nil {
		device, err := newVirtualDevice()
		if err == nil {
			activeDevice = device
		} else {
			if os.Getenv("XDG_SESSION_TYPE") == "wayland" || os.Getenv("DISPLAY") == "" {
				return fmt.Errorf("native Wayland input unavailable: %w", err)
			}
			return sendX11(e)
		}
	}
	return activeDevice.send(e)
}
func sendX11(e Event) error {
	if os.Getenv("DISPLAY") == "" {
		return fmt.Errorf("DISPLAY not set, X11 fallback unavailable")
	}
	if _, err := exec.LookPath("xdotool"); err != nil {
		return fmt.Errorf("X11 fallback requires xdotool: %w", err)
	}
	var args []string
	switch e.Type {
	case "move":
		args = []string{"mousemove_relative", "--", strconv.Itoa(e.DX), strconv.Itoa(e.DY)}
	case "scroll":
		if e.DY == 0 {
			return nil
		}
		button := "4"
		if e.DY > 0 {
			button = "5"
		}
		ticks := e.DY
		if ticks < 0 {
			ticks = -ticks
		}
		if ticks > 8 {
			ticks = 8
		}
		args = []string{"click", "--repeat", strconv.Itoa(ticks), "--delay", "20", button}
	case "click":
		switch e.Button {
		case "right":
			args = []string{"click", "3"}
		case "double":
			args = []string{"click", "--repeat", "2", "--delay", "100", "1"}
		default:
			args = []string{"click", "1"}
		}
	case "key":
		for _, ch := range strings.TrimSpace(e.Key) {
			if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '+' || ch == '_' || ch == '-') {
				return fmt.Errorf("unsupported key combination")
			}
		}
		args = []string{"key", "--clearmodifiers", e.Key}
	case "text":
		args = []string{"type", "--clearmodifiers", "--delay", "0", "--", e.Text}
	default:
		return fmt.Errorf("unsupported input event")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "xdotool", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("xdotool failed: %w (%s)", err, strings.TrimSpace(string(output)))
	}
	return nil
}
