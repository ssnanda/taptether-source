//go:build darwin && cgo

package screencap

import (
  "encoding/binary"
  "encoding/json"
  "errors"
  "fmt"
  "io"
  "net"
  "os"
  "path/filepath"
  "strings"
  "time"
)

type Frame struct { JPEG []byte; Width int; Height int }

func coreDir() string {
  config, err := os.UserConfigDir()
  if err != nil { return "" }
  return filepath.Join(config, "taptether", "screen-core")
}

func Available() bool {
  dir := coreDir()
  if dir == "" { return false }
  info, err := os.Stat(filepath.Join(dir, "capture.sock"))
  return err == nil && info.Mode()&os.ModeSocket != 0
}

func Capture() (Frame, error) {
  dir := coreDir()
  if dir == "" { return Frame{}, errors.New("Screen Core unavailable") }
  token, err := os.ReadFile(filepath.Join(dir, "ipc.token"))
  if err != nil { return Frame{}, errors.New("install the stable TapTether Screen Core once from the Mac app") }
  tokenText := strings.TrimSpace(string(token))
  if len(tokenText) != 64 { return Frame{}, errors.New("Screen Core authorization invalid") }
  conn, err := net.DialTimeout("unix", filepath.Join(dir, "capture.sock"), 2*time.Second)
  if err != nil { return Frame{}, errors.New("Screen Core is not running; restart TapTether Agent") }
  defer conn.Close()
  _ = conn.SetDeadline(time.Now().Add(10*time.Second))
  if err := json.NewEncoder(conn).Encode(map[string]string{
    "token": tokenText, "action": "capture",
  }); err != nil { return Frame{}, err }
  header := make([]byte, 12)
  if _, err := io.ReadFull(conn, header); err != nil { return Frame{}, err }
  width := int(binary.BigEndian.Uint32(header[0:4]))
  height := int(binary.BigEndian.Uint32(header[4:8]))
  length := int(binary.BigEndian.Uint32(header[8:12]))
  if length <= 0 || length > 2<<20 { return Frame{}, errors.New("invalid Screen Core frame size") }
  payload := make([]byte, length)
  if _, err := io.ReadFull(conn, payload); err != nil { return Frame{}, err }
  if width == 0 && height == 0 {
    return Frame{}, errors.New(string(payload))
  }
  if width < 1 || width > 1280 || height < 1 || height > 720 {
    return Frame{}, fmt.Errorf("invalid Screen Core dimensions: %d x %d", width, height)
  }
  return Frame{JPEG:payload, Width:width, Height:height}, nil
}
