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
    "sort"
    "strings"
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

// privateLANInterfaces returns current LAN addresses, excluding VPN/loopback
// and public networks. This list is a local hint, never an identity.
func privateLANInterfaces() []string {
    interfaces, err := net.Interfaces()
    if err != nil { return nil }
    var addresses []string
    for _, iface := range interfaces {
        if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 ||
            iface.Flags&net.FlagPointToPoint != 0 { continue }
        entries, err := iface.Addrs()
        if err != nil { continue }
        for _, entry := range entries {
            subnet, ok := entry.(*net.IPNet)
            if !ok { continue }
            ip := subnet.IP.To4()
            if ip == nil || !ip.IsPrivate() { continue }
            addresses = append(addresses, ip.String())
        }
    }
    sort.Strings(addresses)
    return addresses
}

// Announcements are untrusted, contain no secret/key, and are sent only on
// LAN UDP when an address changes (at most once per hour). Existing on-demand
// discovery probes remain available at all times.
func changedAddresses(previous, current []string) bool {
    return strings.Join(previous, ",") != strings.Join(current, ",")
}

func announceLAN(conn *net.UDPConn, payload []byte) {
    if len(privateLANInterfaces()) == 0 { return }
    destination := &net.UDPAddr{IP: net.IPv4bcast, Port: Port}
    // The OS may block broadcast; failure is non-fatal. Mobile clients still
    // have an on-demand discovery fallback.
    _, _ = conn.WriteToUDP(payload, destination)
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
    knownIPs := privateLANInterfaces()
    var lastAnnouncement time.Time
    ticker := time.NewTicker(time.Minute)
    defer ticker.Stop()
    // A small local timer checks for DHCP changes; there is no active scan,
    // external request or periodic network broadcast while the IP is stable.
    go func() {
        for {
            select {
            case <-ctx.Done(): return
            case <-ticker.C:
                next := privateLANInterfaces()
                if !changedAddresses(knownIPs, next) { continue }
                // Changes inside the 1-hour cooldown are remembered and
                // announced once the next check is eligible.
                if !lastAnnouncement.IsZero() &&
                    time.Since(lastAnnouncement) < time.Hour { continue }
                if len(next) == 0 { continue }
                announceLAN(conn, payload)
                knownIPs = next
                lastAnnouncement = time.Now()
            }
        }
    }()
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
