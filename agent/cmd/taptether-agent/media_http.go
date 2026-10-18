package main

import (
    "context"
    "encoding/json"
    "errors"
    "io"
    "net/http"
    "net/url"
    "os/exec"
    "runtime"
    "strings"
    "time"
    "unicode"
    "unicode/utf8"
)

// mediaDestination accepts only two service names and generates the entire
// URL locally. The paired phone cannot supply an executable or arbitrary URL.
func mediaDestination(service, query string) (string, error) {
    query = strings.TrimSpace(query)
    if !utf8.ValidString(query) || utf8.RuneCountInString(query) > 70 {
        return "", errors.New("media search must contain at most 70 characters")
    }
    for _, ch := range query {
        if unicode.IsControl(ch) { return "", errors.New("media search contains control characters") }
    }
    var destination url.URL
    destination.Scheme = "https"
    switch service {
    case "youtube":
        destination.Host = "www.youtube.com"
        if query != "" {
            destination.Path = "/results"
            destination.RawQuery = url.Values{"search_query": {query}}.Encode()
        }
    case "netflix":
        destination.Host = "www.netflix.com"
        if query != "" {
            destination.Path = "/search"
            destination.RawQuery = url.Values{"q": {query}}.Encode()
        }
    default:
        return "", errors.New("unsupported media service")
    }
    return destination.String(), nil
}

func openMediaBrowser(address string) error {
    ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
    defer cancel()
    var cmd *exec.Cmd
    switch runtime.GOOS {
    case "darwin":
        cmd = exec.CommandContext(ctx, "/usr/bin/open", address)
    case "windows":
        cmd = exec.CommandContext(ctx, "rundll32.exe", "url.dll,FileProtocolHandler", address)
    case "linux":
        return linuxDesktopBrowser(address)
    default:
        return errors.New("media browser control is not supported on this operating system")
    }
    // The URL was assembled above; no shell is involved.
    return cmd.Run()
}

func registerMediaEndpoint(mux *http.ServeMux, access *identityAPI) {
    mux.HandleFunc("/api/media/open", func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Cache-Control", "no-store")
        if r.Method != http.MethodPost {
            http.Error(w, "POST required", http.StatusMethodNotAllowed)
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
        r.Body = http.MaxBytesReader(w, r.Body, 512)
        defer r.Body.Close()
        var request struct {
            Service string `json:"service"`
            Query string `json:"query"`
            Focus bool `json:"focus"`
        }
        decoder := json.NewDecoder(r.Body)
        decoder.DisallowUnknownFields()
        if decoder.Decode(&request) != nil || decoder.Decode(new(any)) != io.EOF {
            http.Error(w, "invalid media request", http.StatusBadRequest)
            return
        }
        destination, err := mediaDestination(request.Service, request.Query)
        if err != nil {
            http.Error(w, err.Error(), http.StatusBadRequest)
            return
        }
        if request.Focus {
            if request.Query != "" {
                http.Error(w, "focus cannot include media search", http.StatusBadRequest)
                return
            }
            if err := focusMediaBrowser(); err != nil {
                http.Error(w, "could not focus the existing desktop browser", http.StatusUnprocessableEntity)
                return
            }
            w.WriteHeader(http.StatusNoContent)
            return
        }
        if err := openMediaBrowser(destination); err != nil {
            http.Error(w, "default browser could not be opened in this desktop session", http.StatusUnprocessableEntity)
            return
        }
        w.WriteHeader(http.StatusNoContent)
    })
}
