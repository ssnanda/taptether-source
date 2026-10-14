package neighbors

import "testing"

func TestParseLinux(t *testing.T) {
    data := "IP address HW type Flags HW address Mask Device\n" +
        "192.168.68.1 0x1 0x2 aa:bb:cc:dd:ee:01 * wlan0\n" +
        "192.168.68.2 0x1 0x0 00:00:00:00:00:00 * wlan0\n"
    result := Parse(data, "linux")
    if len(result) != 1 || result[0].IP != "192.168.68.1" ||
        result[0].MAC != "AA:BB:CC:DD:EE:01" {
        t.Fatalf("unexpected Linux neighbor cache: %#v", result)
    }
}
func TestParseDarwinWindows(t *testing.T) {
    darwin := "? (192.168.68.34) at a0:b1:c2:d3:e4:f5 on en0 ifscope\n"
    windows := "  192.168.68.34  a0-b1-c2-d3-e4-f5 dynamic\n"
    for _, tc := range []struct { raw, platform string }{
        {darwin, "darwin"}, {windows, "windows"},
    } {
        result := Parse(tc.raw, tc.platform)
        if len(result) != 1 || result[0].MAC != "A0:B1:C2:D3:E4:F5" {
            t.Fatalf("%s: unexpected parsed cache %#v", tc.platform, result)
        }
    }
}
func TestRejectsPublicAndInvalidMACs(t *testing.T) {
    raw := "8.8.8.8  11-22-33-44-55-66 dynamic\n" +
        "192.168.68.3  00-00-00-00-00-00 dynamic\n" +
        "192.168.68.4  ff-ff-ff-ff-ff-ff static\n"
    if result := Parse(raw, "windows"); len(result) != 0 {
        t.Fatalf("expected no valid private neighbors, got %#v", result)
    }
}
