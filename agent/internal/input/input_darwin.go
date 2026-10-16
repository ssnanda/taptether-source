//go:build darwin

package input

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Send delegates all Accessibility-sensitive work to the independently
// installed Input Core. Routine agent updates never replace that executable.
func Send(event Event) error {
	if event.Type == "tap" { return tapViaInputCore(event) }
	config, err := os.UserConfigDir()
	if err != nil {
		return err
	}
	dir := filepath.Join(config, "taptether", "input-core")
	tokenBytes, err := os.ReadFile(filepath.Join(dir, "ipc.token"))
	if err != nil {
		return errors.New("TapTether Input Core is not installed; use Install / Repair")
	}
	token := strings.TrimSpace(string(tokenBytes))
	if len(token) != 64 {
		return errors.New("TapTether Input Core authorization is invalid; use Install / Repair")
	}

	conn, err := net.DialTimeout("unix", filepath.Join(dir, "input.sock"), time.Second)
	if err != nil {
		return fmt.Errorf("TapTether Input Core unavailable: %w", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	request := struct {
		Protocol int    `json:"protocol"`
		Token    string `json:"token"`
		Event    Event  `json:"event"`
	}{1, token, event}
	if err := json.NewEncoder(conn).Encode(request); err != nil {
		return err
	}
	var response struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}
	if err := json.NewDecoder(conn).Decode(&response); err != nil {
		return err
	}
	if !response.OK {
		if response.Error == "" {
			response.Error = "input command rejected"
		}
		return errors.New(response.Error)
	}
	return nil
}
