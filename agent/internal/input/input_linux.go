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

// MVP backend: xdotool on an X11 desktop session. Wayland needs a separate backend.
func Send(e Event) error {
	if e.Type == "ping" {
		return nil
	}
	if os.Getenv("DISPLAY") == "" {
		return fmt.Errorf("DISPLAY not set: start the agent inside an X11 desktop session")
	}
	if _, err := exec.LookPath("xdotool"); err != nil {
		return fmt.Errorf("install xdotool: sudo apt install xdotool")
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
		case "left":
			args = []string{"click", "1"}
		case "right":
			args = []string{"click", "3"}
		case "double":
			args = []string{"click", "--repeat", "2", "--delay", "100", "1"}
		}
	case "key":
		key := strings.TrimSpace(e.Key)
		for _, ch := range key {
			if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '+' || ch == '_' || ch == '-') {
				return fmt.Errorf("unsupported key combination")
			}
		}
		args = []string{"key", "--clearmodifiers", key}
	case "text":
		args = []string{"type", "--clearmodifiers", "--delay", "0", "--", e.Text}
	default:
		return fmt.Errorf("unsupported command type")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "xdotool", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("xdotool failed: %v (%s)", err, strings.TrimSpace(string(output)))
	}
	return nil
}
