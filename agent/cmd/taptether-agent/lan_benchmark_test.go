package main

import (
    "crypto/tls"
    "net/http"
    "net/http/httptest"
    "strconv"
    "strings"
    "testing"

    "github.com/ssnanda/taptether.com/agent/internal/identity"
)

func TestLanBenchmarkRequiresPairedLANAndBoundsTraffic(t *testing.T) {
    token := strings.Repeat("b", 32)
    mux := http.NewServeMux()
    registerLanProbeEndpoint(mux, &identityAPI{
        devices: identity.New(t.TempDir() + "/devices.json"),
        legacyToken: token,
    })
    probe := func(method, remote, bearer, byteCount string, tlsOn bool) *httptest.ResponseRecorder {
        req := httptest.NewRequest(method, "/api/lan-benchmark?bytes="+byteCount, nil)
        req.RemoteAddr = remote
        if tlsOn { req.TLS = &tls.ConnectionState{} }
        req.Header.Set("Authorization", "Bearer "+bearer)
        res := httptest.NewRecorder()
        mux.ServeHTTP(res, req)
        return res
    }
    for _, tc := range []struct{ method, remote, bearer, size string; tlsOn bool; code int }{
        {"GET", "192.168.1.8:1234", token, "0", true, 200},
        {"GET", "192.168.1.8:1234", "wrong", "0", true, 401},
        {"GET", "8.8.8.8:1234", token, "0", true, 403},
        {"GET", "192.168.1.8:1234", token, "0", false, 403},
        {"POST", "192.168.1.8:1234", token, "0", true, 405},
        {"GET", "192.168.1.8:1234", token, "104857600", true, 400},
    } {
        res:=probe(tc.method, tc.remote, tc.bearer, tc.size, tc.tlsOn)
        if res.Code != tc.code { t.Errorf("%v: HTTP %d want %d", tc, res.Code, tc.code) }
    }
    fast := probe("GET", "10.0.1.22:2301", token, "0", true)
    if fast.Body.Len() != 0 || fast.Header().Get("Cache-Control") == "" {
        t.Fatal("RTT sample must be bodyless and non-cacheable")
    }
    full := probe("GET", "10.0.1.22:2301", token, strconv.Itoa(lanProbeBytes), true)
    if full.Code != 200 || full.Body.Len() != lanProbeBytes {
        t.Fatalf("bounded benchmark failed: status %d, length %d",
            full.Code, full.Body.Len())
    }
    if full.Header().Get("Content-Length") != strconv.Itoa(lanProbeBytes) {
        t.Fatal("benchmark must advertise transfer size")
    }
    if full.Body.Bytes()[0] == full.Body.Bytes()[1] {
        t.Fatal("test payload should not be a constant byte stream")
    }
}
