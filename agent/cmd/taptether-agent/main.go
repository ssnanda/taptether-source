package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/ssnanda/taptether.com/agent/internal/discovery"
	"github.com/ssnanda/taptether.com/agent/internal/input"
	"github.com/ssnanda/taptether.com/agent/internal/identity"
	"github.com/ssnanda/taptether.com/agent/internal/power"
    "github.com/ssnanda/taptether.com/agent/internal/updater"
    "github.com/ssnanda/taptether.com/agent/internal/neighbors"
)

var version = "dev"

func main() {
	addr := flag.String("listen", ":48321", "TLS listen address; use a LAN firewall for additional restriction")
	showVersion := flag.Bool("version", false, "Print the agent version")
	listDevices := flag.Bool("list-devices", false, "List authorized phone IDs and names")
	revokeDevice := flag.String("revoke-device", "", "Revoke an authorized phone ID")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}
	dir, err := os.UserConfigDir()
	fatalIf(err)
	dir = filepath.Join(dir, "taptether")
	fatalIf(os.MkdirAll(dir, 0700))
	registry := identity.New(filepath.Join(dir, "authorized_devices.json"))
	if *listDevices {
		devices,err:=registry.List();fatalIf(err)
		for _,d:=range devices { fmt.Printf("%s  %s\n",d.ID,d.Name) }
		return
	}
	if *revokeDevice!="" {fatalIf(registry.Revoke(*revokeDevice));fmt.Println("Device revoked:",*revokeDevice);return}
	certFile, keyFile, tokenFile := filepath.Join(dir, "server.crt"), filepath.Join(dir, "server.key"), filepath.Join(dir, "pairing.token")
	if err := ensureCertificate(certFile, keyFile); err != nil {
		log.Fatal(err)
	}
	token, err := ensureToken(tokenFile)
	fatalIf(err)
	certPEM, err := os.ReadFile(certFile)
	fatalIf(err)
	block, _ := pem.Decode(certPEM)
	if block == nil {
		log.Fatal("invalid local certificate")
	}
	digest := sha256.Sum256(block.Bytes)
	fmt.Printf("\nTapTether Agent %s — LAN-only remote input\n", version)
	fmt.Println("Pairing token (keep private):", token)
	fmt.Println("TLS SHA-256 fingerprint:", strings.ToUpper(hex.EncodeToString(digest[:])))
	fmt.Println("Port: 48321 (HTTPS)")
	for _, a := range privateAddresses() {
		fmt.Printf("iPhone host: %s\n", a)
	}
	fmt.Println("Linux Wayland/X11 native uinput and macOS CoreGraphics are supported; macOS requires Accessibility permission. Windows uses SendInput in the signed-in user desktop.")
	fmt.Println("No telemetry or cloud connections are implemented. UDP 48322 answers local discovery probes. Restrict control port 48321 to trusted LAN devices.")
	mux := http.NewServeMux()
	access := &identityAPI{devices: registry, legacyToken: token}
	access.Register(mux)
    // Upgrades require a previously paired, TLS-pinned phone. The server
    // chooses its own fixed updater; clients never supply commands or URLs.
    mux.HandleFunc("/api/neighbors", func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Cache-Control", "no-store")
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
        entries, err := neighbors.Read()
        if err != nil {
            http.Error(w, "neighbor inventory unavailable", http.StatusServiceUnavailable)
            return
        }
        w.Header().Set("Content-Type", "application/json")
        _ = json.NewEncoder(w).Encode(entries)
    })
    mux.HandleFunc("/api/update", func(w http.ResponseWriter, r *http.Request) {
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
        r.Body = http.MaxBytesReader(w, r.Body, 256)
        defer r.Body.Close()
        var req struct { Confirm bool `json:"confirm"` }
        d := json.NewDecoder(r.Body)
        d.DisallowUnknownFields()
        if d.Decode(&req) != nil || d.Decode(new(any)) != io.EOF || !req.Confirm {
            http.Error(w, "explicit confirmation required", http.StatusBadRequest)
            return
        }
        if !updater.Supported() {
            http.Error(w, "use the built-in SSH updater or local installer", http.StatusNotImplemented)
            return
        }
        if err := updater.Start(); err != nil {
            http.Error(w, "update could not be started", http.StatusServiceUnavailable)
            return
        }
        w.WriteHeader(http.StatusAccepted)
    })
    mux.HandleFunc("/api/info", func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Cache-Control", "no-store")
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
        w.Header().Set("Content-Type", "application/json")
        hostname, _ := os.Hostname()
        // Only authenticated LAN clients see OS/hostname metadata. Never
        // reveal this via unauthenticated HTTP or pairing endpoints.
        _ = json.NewEncoder(w).Encode(map[string]any{
            "version": version, "shutdownEnabled": power.Enabled(),
            "hostname": hostname, "platform": runtime.GOOS,
            "macAddress": localHardwareAddress(),
        })
    })
    var mu sync.Mutex
	mux.HandleFunc("/api/control", func(w http.ResponseWriter, r *http.Request) {
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
		body := http.MaxBytesReader(w, r.Body, 4096)
		defer body.Close()
		decoder := json.NewDecoder(body)
		decoder.DisallowUnknownFields()
		var cmd input.Event
		if err := decoder.Decode(&cmd); err != nil {
			http.Error(w, "invalid JSON command", http.StatusBadRequest)
			return
		}
		var extra any
		if err := decoder.Decode(&extra); err != io.EOF {
			http.Error(w, "unexpected trailing JSON", http.StatusBadRequest)
			return
		}
		if err := cmd.Validate(); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
        if cmd.Type == "shutdown" {
            if !power.Enabled() {
                http.Error(w, "remote shutdown disabled; enable it explicitly on the computer", http.StatusForbidden)
                return
            }
            if err := power.RequestShutdown(); err != nil {
                http.Error(w, err.Error(), http.StatusUnprocessableEntity)
                return
            }
            w.WriteHeader(http.StatusNoContent)
            return
        }
        mu.Lock()
        err := input.Send(cmd)
		mu.Unlock()
		if err != nil {
			http.Error(w, err.Error(), http.StatusUnprocessableEntity)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	go func() { if err:=discovery.Serve(context.Background(),version,48321);err!=nil {log.Printf("LAN discovery unavailable (UDP %d): %v",discovery.Port,err)} }()
	server := &http.Server{Addr: *addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 8 * time.Second, WriteTimeout: 8 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 4096}
	log.Fatal(server.ListenAndServeTLS(certFile, keyFile))
}

func fatalIf(err error) {
	if err != nil {
		log.Fatal(err)
	}
}
func privateRemote(remote string) bool {
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	return ip != nil && (ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast())
}
func privateAddresses() []string {
	ifaces, err := net.InterfaceAddrs()
	if err != nil {
		return nil
	}
	var result []string
	for _, a := range ifaces {
		network, ok := a.(*net.IPNet)
		if !ok {
			continue
		}
		ip := network.IP.To4()
		if ip != nil && ip.IsPrivate() {
			result = append(result, ip.String())
		}
	}
	return result
}
func ensureToken(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err == nil {
		if len(strings.TrimSpace(string(data))) >= 32 {
			return strings.TrimSpace(string(data)), nil
		}
		return "", errors.New("existing pairing token invalid")
	}
	if !os.IsNotExist(err) {
		return "", err
	}
	b := make([]byte, 24)
	if _, err = rand.Read(b); err != nil {
		return "", err
	}
	val := hex.EncodeToString(b)
	if err = os.WriteFile(path, []byte(val+"\n"), 0600); err != nil {
		return "", err
	}
	return val, nil
}
func ensureCertificate(crt, key string) error {
	_, ec := os.Stat(crt)
	_, ek := os.Stat(key)
	if ec == nil && ek == nil {
		return nil
	}
	if !os.IsNotExist(ec) || !os.IsNotExist(ek) {
		return errors.New("certificate/key incomplete or unreadable; repair manually, never silently replace identity")
	}
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return err
	}
	tmpl := x509.Certificate{SerialNumber: serial, Subject: pkixName(), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().AddDate(5, 0, 0), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true, DNSNames: []string{"localhost"}}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &priv.PublicKey, priv)
	if err != nil {
		return err
	}
	pemKey, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		return err
	}
	if err = os.WriteFile(key, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pemKey}), 0600); err != nil {
		return err
	}
	if err = os.WriteFile(crt, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600); err != nil {
		return err
	}
	return nil
}

// A CN is not required for cert pinning; the certificate is never publicly trusted.
func pkixName() pkix.Name { return pkix.Name{CommonName: "TapTether Local Agent"} }

 // localHardwareAddress is included only in authenticated /api/info.
 // Prefer an active interface with an RFC1918 IPv4 address, ignoring VPN
 // tunnel/loopback adapters and random virtual interfaces when possible.
func localHardwareAddress() string {
    interfaces, err := net.Interfaces()
    if err != nil { return "" }
    for _, network := range interfaces {
        if network.Flags&net.FlagUp == 0 || network.Flags&net.FlagLoopback != 0 ||
            len(network.HardwareAddr) != 6 { continue }
        addresses, err := network.Addrs()
        if err != nil { continue }
        for _, address := range addresses {
            ipv4, ok := address.(*net.IPNet)
            if !ok { continue }
            ip := ipv4.IP.To4()
            if ip != nil && ip.IsPrivate() {
                return strings.ToUpper(network.HardwareAddr.String())
            }
        }
    }
    return ""
}
