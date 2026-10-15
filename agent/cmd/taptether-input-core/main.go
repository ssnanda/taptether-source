//go:build darwin && cgo

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
	"bytes"
	"crypto/subtle"
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
	"syscall"
	"time"
	"unsafe"

	"github.com/ssnanda/taptether.com/agent/internal/inputcore"
)

var version = "dev"

func main() {
	showVersion := flag.Bool("version", false, "print version")
	diagnose := flag.Bool("diagnose", false, "report Accessibility state")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}
	if *diagnose {
		if inputcore.Trusted() {
			fmt.Println("Accessibility: allowed")
		} else {
			fmt.Println("Accessibility: approval required")
		}
		return
	}
	config, err := os.UserConfigDir()
	fatal(err)
	dir := filepath.Join(config, "taptether", "input-core")
	fatal(secureDirectory(dir))
	tokenBytes, err := os.ReadFile(filepath.Join(dir, "ipc.token"))
	fatal(err)
	token := strings.TrimSpace(string(tokenBytes))
	if len(token) != 64 {
		log.Fatal("invalid Input Core authorization token")
	}
	// Verify the installed peer once before accepting commands. codesign can
	// take seconds on first use and must never run in the input-event path.
	fatal(verifySigningPeer(installedAgentPath()))
	socket := filepath.Join(dir, "input.sock")
	if info, err := os.Lstat(socket); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			log.Fatal("refusing to replace non-socket input.sock")
		}
		_ = os.Remove(socket)
	} else if !os.IsNotExist(err) {
		fatal(err)
	}
	listener, err := net.Listen("unix", socket)
	fatal(err)
	fatal(os.Chmod(socket, 0600))
	defer listener.Close()
	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go serve(conn, token)
	}
}
func serve(conn net.Conn, token string) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	unix, ok := conn.(*net.UnixConn)
	if !ok {
		return
	}
	if err := authorizePeer(unix); err != nil {
		write(conn, inputcore.Response{Error: "unauthorized local client"})
		return
	}
	request, err := readRequest(conn)
	if err != nil || request.Protocol != inputcore.ProtocolVersion || subtle.ConstantTimeCompare([]byte(request.Token), []byte(token)) != 1 {
		write(conn, inputcore.Response{Error: "invalid request authorization"})
		return
	}
	if err := request.Event.Validate(); err != nil {
		write(conn, inputcore.Response{Error: err.Error()})
		return
	}
	if err := inputcore.SendNative(request.Event); err != nil {
		write(conn, inputcore.Response{Error: err.Error()})
		return
	}
	trusted := inputcore.Trusted()
	write(conn, inputcore.Response{OK: true, Version: version, Trusted: &trusted})
}

func readRequest(reader io.Reader) (inputcore.Request, error) {
	framed := bufio.NewReader(io.LimitReader(reader, 4097))
	payload, err := framed.ReadBytes('\n')
	if err != nil && err != io.EOF {
		return inputcore.Request{}, err
	}
	if len(payload) == 0 || len(payload) > 4096 {
		return inputcore.Request{}, errors.New("invalid request frame")
	}
	var request inputcore.Request
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		return inputcore.Request{}, err
	}
	if decoder.Decode(new(any)) != io.EOF {
		return inputcore.Request{}, errors.New("trailing request data")
	}
	return request, nil
}
func write(w io.Writer, response inputcore.Response) { _ = json.NewEncoder(w).Encode(response) }
func secureDirectory(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode().Perm() != 0700 {
		return errors.New("Input Core directory must be mode 0700")
	}
	return nil
}
func authorizePeer(conn *net.UnixConn) error {
	raw, err := conn.SyscallConn()
	if err != nil {
		return err
	}
	var check error
	err = raw.Control(func(fd uintptr) {
		var uid C.uid_t
		var pid C.pid_t
		if C.tt_peer(C.int(fd), &uid, &pid) != 0 {
			check = errors.New("could not read peer credentials")
			return
		}
		if int(uid) != os.Getuid() {
			check = errors.New("peer uid mismatch")
			return
		}
		path, e := processPath(int(pid))
		if e != nil {
			check = e
			return
		}
		expected := installedAgentPath()
		if path != expected {
			check = fmt.Errorf("unexpected peer path %q", path)
			return
		}
		info, e := os.Lstat(path)
		if e != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0022 != 0 {
			check = errors.New("insecure agent executable")
			return
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || int(stat.Uid) != os.Getuid() {
			check = errors.New("agent owner mismatch")
			return
		}
	})
	if err != nil {
		return err
	}
	return check
}

func installedAgentPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".local", "bin", "taptether-agent")
}

func verifySigningPeer(agentPath string) error {
	corePath, err := os.Executable()
	if err != nil {
		return err
	}
	for _, path := range []string{corePath, agentPath} {
		if output, err := exec.Command("/usr/bin/codesign", "--verify", "--strict", path).CombinedOutput(); err != nil {
			return fmt.Errorf("invalid code signature for %s: %s", filepath.Base(path), strings.TrimSpace(string(output)))
		}
	}
	team := func(path string) string {
		output, _ := exec.Command("/usr/bin/codesign", "-dv", "--verbose=4", path).CombinedOutput()
		for _, line := range strings.Split(string(output), "\n") {
			if strings.HasPrefix(line, "TeamIdentifier=") {
				return strings.TrimPrefix(line, "TeamIdentifier=")
			}
		}
		return ""
	}
	coreTeam, agentTeam := team(corePath), team(agentPath)
	if coreTeam != agentTeam {
		return errors.New("agent and Input Core signing teams differ")
	}
	// Local development uses ad-hoc signatures without a TeamIdentifier. A
	// production Developer ID build must have the same non-empty team on both.
	return nil
}
func processPath(pid int) (string, error) {
	buffer := make([]byte, 4096)
	count := C.tt_pid_path(C.pid_t(pid), (*C.char)(unsafe.Pointer(&buffer[0])), C.uint32_t(len(buffer)))
	if count <= 0 {
		return "", errors.New("missing peer executable")
	}
	return C.GoString((*C.char)(unsafe.Pointer(&buffer[0]))), nil
}
func fatal(err error) {
	if err != nil {
		log.Fatal(err)
	}
}
