package main

import (
    "net/http"
    "strconv"
    "sync/atomic"
)

// An explicit, bounded, same-LAN performance sample. No camera/screen bytes,
// storage, cloud service, or background test is involved.
const lanProbeBytes = 4 << 20

var lanProbeActive atomic.Bool

func registerLanProbeEndpoint(mux *http.ServeMux, access *identityAPI) {
    // Deterministic non-repeating bytes avoid misleading compressible payloads
    // while never using any private data or expensive per-request randomness.
    payload := make([]byte, 32<<10)
    var seed uint32 = 0x9e3779b9
    for index := range payload {
        seed ^= seed << 13
        seed ^= seed >> 17
        seed ^= seed << 5
        payload[index] = byte(seed)
    }
    mux.HandleFunc("/api/lan-benchmark", func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate")
        w.Header().Set("X-Content-Type-Options", "nosniff")
        if r.Method != http.MethodGet {
            http.Error(w, "GET required", http.StatusMethodNotAllowed)
            return
        }
        if r.TLS == nil || !privateRemote(r.RemoteAddr) {
            http.Error(w, "LAN TLS required", http.StatusForbidden)
            return
        }
        if !access.authorized(r) {
            http.Error(w, "not paired", http.StatusUnauthorized)
            return
        }
        if !lanProbeActive.CompareAndSwap(false, true) {
            http.Error(w, "LAN speed test already running", http.StatusTooManyRequests)
            return
        }
        defer lanProbeActive.Store(false)

        // bytes=0 is a tiny API RTT sample, 4 MiB is a short download test.
        requested := r.URL.Query().Get("bytes")
        count := lanProbeBytes
        if requested == "0" { count = 0 } else if requested != "" &&
            requested != strconv.Itoa(lanProbeBytes) {
            http.Error(w, "invalid benchmark size", http.StatusBadRequest)
            return
        }
        w.Header().Set("Content-Type", "application/octet-stream")
        w.Header().Set("Content-Length", strconv.Itoa(count))
        w.Header().Set("X-Test-Bytes", strconv.Itoa(count))
        w.Header().Set("Content-Encoding", "identity")
        w.WriteHeader(http.StatusOK)
        for sent := 0; sent < count; sent += len(payload) {
            select {
            case <-r.Context().Done(): return
            default:
            }
            n, err := w.Write(payload)
            if err != nil || n != len(payload) { return }
        }
    })
}
