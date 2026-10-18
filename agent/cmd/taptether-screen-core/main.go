//go:build darwin && cgo

// TapTether Screen Core is a stable, local-only process. The main agent can be
// updated without replacing this executable or its Screen Recording consent.
package main

/*
#cgo LDFLAGS: -lproc
#include <libproc.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

static int tt_peer(int fd, uid_t *uid, pid_t *pid) {
  gid_t gid;
  socklen_t size = sizeof(*pid);
  if (getpeereid(fd, uid, &gid) != 0) return -1;
  if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, pid, &size) != 0) return -1;
  return 0;
}
static int tt_pid_path(pid_t pid, char *buffer, uint32_t size) {
  return proc_pidpath(pid, buffer, size);
}
*/
import "C"

import (
  "bufio"
  "crypto/subtle"
  "encoding/binary"
  "encoding/json"
  "errors"
  "flag"
  "fmt"
  "io"
  "log"
  "net"
  "os"
  "os/exec"
  "path/filepath"
  "strings"
  "sync"
  "syscall"
  "time"
  "unsafe"
)

var version = "1"
var captureMutex sync.Mutex

type captureRequest struct {
  Token string `json:"token"`
  Action string `json:"action"`
}

func installedAgent() string {
  home, _ := os.UserHomeDir()
  return filepath.Join(home, ".local", "bin", "taptether-agent")
}

func main() {
  showVersion := flag.Bool("version", false, "print stable Screen Core version")
  flag.Parse()
  if *showVersion { fmt.Println(version); return }
  config, err := os.UserConfigDir()
  fatal(err)
  dir := filepath.Join(config, "taptether", "screen-core")
  info, err := os.Stat(dir)
  fatal(err)
  if !info.IsDir() || info.Mode().Perm() != 0700 {
    log.Fatal("Screen Core directory must be private (0700)")
  }
  tokenBytes, err := os.ReadFile(filepath.Join(dir, "ipc.token"))
  fatal(err)
  token := strings.TrimSpace(string(tokenBytes))
  if len(token) != 64 { log.Fatal("invalid Screen Core IPC token") }
  fatal(verifySignedBinaries())
  socket := filepath.Join(dir, "capture.sock")
  if info, err := os.Lstat(socket); err == nil {
    if info.Mode()&os.ModeSocket == 0 { log.Fatal("refusing non-socket path") }
    fatal(os.Remove(socket))
  } else if !os.IsNotExist(err) { fatal(err) }
  listener, err := net.Listen("unix", socket)
  fatal(err)
  fatal(os.Chmod(socket, 0600))
  defer listener.Close()
  defer os.Remove(socket)
  for {
    conn, err := listener.Accept()
    if err != nil { log.Printf("accept: %v", err); continue }
    go serveCapture(conn, token)
  }
}

func serveCapture(conn net.Conn, token string) {
  defer conn.Close()
  _ = conn.SetDeadline(time.Now().Add(11 * time.Second))
  peer, ok := conn.(*net.UnixConn)
  if !ok || authorizePeer(peer) != nil {
    sendError(conn, "unauthorized local capture client")
    return
  }
  line, err := bufio.NewReader(io.LimitReader(conn, 513)).ReadBytes('\n')
  if err != nil || len(line) > 512 {
    sendError(conn, "invalid capture request")
    return
  }
  var req captureRequest
  d := json.NewDecoder(strings.NewReader(string(line)))
  d.DisallowUnknownFields()
  if d.Decode(&req) != nil || d.Decode(new(any)) != io.EOF ||
      (req.Action != "capture" && req.Action != "capture-detail") || len(req.Token) != len(token) ||
      subtle.ConstantTimeCompare([]byte(req.Token), []byte(token)) != 1 {
    sendError(conn, "capture authorization rejected")
    return
  }
  captureMutex.Lock()
  frame, err := nativeCapture(req.Action == "capture-detail")
  captureMutex.Unlock()
  if err != nil { sendError(conn, err.Error()); return }
  maxW, maxH := 1280, 720
  if req.Action == "capture-detail" { maxW, maxH = 1920, 1080 }
  if frame.Width < 1 || frame.Width > maxW ||
      frame.Height < 1 || frame.Height > maxH ||
      len(frame.JPEG) == 0 || len(frame.JPEG) > 4<<20 {
    sendError(conn, "invalid capture dimensions")
    return
  }
  header := make([]byte, 12)
  binary.BigEndian.PutUint32(header[0:4], uint32(frame.Width))
  binary.BigEndian.PutUint32(header[4:8], uint32(frame.Height))
  binary.BigEndian.PutUint32(header[8:12], uint32(len(frame.JPEG)))
  _, _ = conn.Write(header)
  _, _ = conn.Write(frame.JPEG)
}
func sendError(w io.Writer, message string) {
  if len(message) > 512 { message = message[:512] }
  header := make([]byte, 12)
  binary.BigEndian.PutUint32(header[8:12], uint32(len(message)))
  _, _ = w.Write(header)
  _, _ = io.WriteString(w, message)
}
func authorizePeer(conn *net.UnixConn) error {
  raw, err := conn.SyscallConn()
  if err != nil { return err }
  var outcome error
  err = raw.Control(func(fd uintptr) {
    var uid C.uid_t
    var pid C.pid_t
    if C.tt_peer(C.int(fd), &uid, &pid) != 0 || int(uid) != os.Getuid() {
      outcome = errors.New("peer uid mismatch"); return
    }
    buffer := make([]byte, 4096)
    n := C.tt_pid_path(pid, (*C.char)(unsafe.Pointer(&buffer[0])), C.uint32_t(len(buffer)))
    if n <= 0 || C.GoString((*C.char)(unsafe.Pointer(&buffer[0]))) != installedAgent() {
      outcome = errors.New("unexpected executable"); return
    }
    info, e := os.Lstat(installedAgent())
    if e != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0022 != 0 {
      outcome = errors.New("insecure agent executable"); return
    }
    stat, ok := info.Sys().(*syscall.Stat_t)
    if !ok || int(stat.Uid) != os.Getuid() {
      outcome = errors.New("agent executable owner mismatch")
    }
  })
  if err != nil { return err }
  return outcome
}
func verifySignedBinaries() error {
  own, err := os.Executable()
  if err != nil { return err }
  for _, path := range []string{own, installedAgent()} {
    if output, err := exec.Command("/usr/bin/codesign", "--verify", "--strict", path).CombinedOutput(); err != nil {
      return fmt.Errorf("invalid code signature for %s: %s", filepath.Base(path), strings.TrimSpace(string(output)))
    }
  }
  return nil
}
func fatal(err error) { if err != nil { log.Fatal(err) } }
