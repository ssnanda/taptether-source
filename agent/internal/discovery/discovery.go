// Package discovery exposes only public LAN discovery hints. It never sends
// credentials or a certificate fingerprint: pairing still requires TLS pinning.
package discovery

import (
    "context"
    "encoding/json"
    "errors"
    "net"
    "os"
    "runtime"
    "time"
)

const Port = 48322
const Probe = "TAPTETHER_DISCOVER_V1"

type Announcement struct {
    Protocol int `json:"protocol"`
    Name string `json:"name"`
    Platform string `json:"platform"`
    Version string `json:"version"`
    Port int `json:"port"`
}

func MakeAnnouncement(name, version string, port int) ([]byte,error) {
    if len(name)>64 { name=name[:64] }
    return json.Marshal(Announcement{Protocol:1,Name:name,Platform:runtime.GOOS,Version:version,Port:port})
}

func AcceptProbe(raw []byte, addr *net.UDPAddr) bool {
    return addr!=nil && addr.IP!=nil &&
        (addr.IP.IsPrivate() || addr.IP.IsLinkLocalUnicast()) &&
        string(raw)==Probe
}

// Serve responds to explicit UDP broadcasts on port 48322. It does not
// advertise private keys, pairing tokens, or TLS fingerprints.
func Serve(ctx context.Context, version string, controlPort int) error {
    conn,err := net.ListenUDP("udp4", &net.UDPAddr{IP:net.IPv4zero,Port:Port})
    if err!=nil { return err }
    defer conn.Close()
    name,_ := os.Hostname()
    payload,err:=MakeAnnouncement(name,version,controlPort)
    if err!=nil {return err}
    buf:=make([]byte,512)
    for {
        _=conn.SetReadDeadline(time.Now().Add(2*time.Second))
        n,addr,err:=conn.ReadFromUDP(buf)
        if err!=nil {
            if errors.Is(err,os.ErrDeadlineExceeded) || isTimeout(err) {
                if ctx.Err()!=nil { return nil }
                continue
            }
            if ctx.Err()!=nil { return nil }
            return err
        }
        if !AcceptProbe(buf[:n],addr) { continue }
        _,_=conn.WriteToUDP(payload,addr)
    }
}

func isTimeout(err error) bool {
    var netErr net.Error
    return errors.As(err,&netErr) && netErr.Timeout()
}
