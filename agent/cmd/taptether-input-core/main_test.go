//go:build darwin && cgo

package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRequestFrameDoesNotWaitForConnectionClose(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	done := make(chan error, 1)
	go func() {
		request, err := readRequest(server)
		if err == nil && request.Protocol != 1 {
			err = fmt.Errorf("protocol lost")
		}
		done <- err
	}()
	if err := json.NewEncoder(client).Encode(map[string]any{
		"protocol": 1, "token": "test", "event": map[string]any{"type": "ping"},
	}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(250 * time.Millisecond):
		t.Fatal("newline-framed request waited for socket close")
	}
}

func TestSecureDirectory(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := secureDirectory(dir); err != nil {
		t.Fatalf("secure directory rejected: %v", err)
	}
	if err := os.Chmod(dir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := secureDirectory(dir); err == nil {
		t.Fatal("world-readable IPC directory accepted")
	}
	file := filepath.Join(dir, "file")
	if err := os.WriteFile(file, []byte("x"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := secureDirectory(file); err == nil {
		t.Fatal("regular file accepted as IPC directory")
	}
}
