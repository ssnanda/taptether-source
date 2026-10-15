package neighbors

import (
    "bufio"
    "context"
    "os"
    "os/exec"
    "regexp"
    "runtime"
    "sort"
    "strings"
    "time"
    "net"
)

type Neighbor struct {
    IP string `json:"ip"`
    MAC string `json:"mac"`
}

var (
    macRe = regexp.MustCompile(`(?i)^(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}$`)
    // macOS arp: ? (192.168.0.23) at a0:bb:cc:dd:ee:ff on en0 ...
    apple = regexp.MustCompile(`\(([0-9.]+)\) at ([0-9a-fA-F:]+)`)
)

func clean(ip, mac string) (Neighbor, bool) {
    address := net.ParseIP(ip).To4()
    if address == nil || !address.IsPrivate() {
        return Neighbor{}, false
    }
    mac = strings.ToUpper(strings.ReplaceAll(mac, "-", ":"))
    if !macRe.MatchString(mac) || mac == "00:00:00:00:00:00" ||
        mac == "FF:FF:FF:FF:FF:FF" {
        return Neighbor{}, false
    }
    return Neighbor{IP: address.String(), MAC: mac}, true
}

// Parse returns only verified-format IPv4 and MAC values from the OS cache.
// It does not infer that a stale neighbor is online or paired.
func Parse(raw, platform string) []Neighbor {
    found := map[string]Neighbor{}
    scanner := bufio.NewScanner(strings.NewReader(raw))
    scanner.Buffer(make([]byte, 256), 4096)
    for scanner.Scan() {
        line := scanner.Text()
        var ip, mac string
        switch platform {
        case "linux":
            columns := strings.Fields(line)
            if len(columns) >= 6 && columns[2] != "0x0" {
                ip, mac = columns[0], columns[3]
            }
        case "darwin":
            match := apple.FindStringSubmatch(line)
            if len(match) == 3 { ip, mac = match[1], match[2] }
        case "windows":
            columns := strings.Fields(line)
            if len(columns) >= 2 {
                ip, mac = columns[0], columns[1]
            }
        }
        if value, ok := clean(ip, mac); ok && len(found) < 1024 {
            found[value.IP] = value
        }
    }
    result := make([]Neighbor, 0, len(found))
    for _, n := range found { result = append(result, n) }
    sort.Slice(result, func(i,j int) bool { return result[i].IP < result[j].IP })
    return result
}

func Read() ([]Neighbor, error) {
    if runtime.GOOS == "linux" {
        raw, err := os.ReadFile("/proc/net/arp")
        if err != nil { return nil, err }
        return Parse(string(raw), "linux"), nil
    }
    var args []string
    if runtime.GOOS == "windows" || runtime.GOOS == "darwin" {
        args = []string{"-a"}
    } else {
        return nil, nil
    }
    ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
    defer cancel()
    output, err := exec.CommandContext(ctx, "arp", args...).Output()
    if err != nil { return nil, err }
    return Parse(string(output), runtime.GOOS), nil
}
