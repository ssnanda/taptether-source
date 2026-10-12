#!/usr/bin/env bash
# TapTether project bootstrap: Flutter mobile + Go LAN-only agent.
set -euo pipefail
IFS=$'\n\t'

REPO='ssnanda/taptether.com'
ROOT="${TAPTETHER_ROOT:-$(pwd)}"
if [[ "${1:-}" == '--help' ]]; then
  echo 'Usage: cd /Users/sandip/Projects/taptether && bash bootstrap-taptether.sh'
  echo 'Optional: TAPTETHER_ROOT=/absolute/path bash bootstrap-taptether.sh'
  exit 0
fi
if [[ "$ROOT" == '/' ]]; then echo 'Refusing to bootstrap into /' >&2; exit 1; fi
mkdir -p "$ROOT"
ROOT="$(cd "$ROOT" && pwd -P)"
cd "$ROOT"
printf '\nTapTether bootstrap in %s\n' "$ROOT"

if [[ -d .git ]]; then
  remote="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -n "$remote" ]]; then
    case "$remote" in
      git@github.com:ssnanda/taptether.com.git|https://github.com/ssnanda/taptether.com.git|ssh://git@github.com/ssnanda/taptether.com.git|https://github.com/ssnanda/taptether.com)
        echo "Git remote verified: $remote" ;;
      *) echo "ERROR: existing 'origin' points to $remote; expected $REPO. Nothing changed." >&2; exit 1;;
    esac
  else
    git remote add origin "git@github.com:$REPO.git"
  fi
else
  git init -b main
  git remote add origin "git@github.com:$REPO.git"
fi

# Refuse to replace an existing independently developed Flutter app.
if [[ ! -e .taptether-bootstrapped && -e app/lib/main.dart ]]; then
  echo 'Existing app/lib/main.dart found; bootstrap will not overwrite an existing app.' >&2
  exit 1
fi
mkdir -p bin agent/cmd/taptether-agent agent/internal/input app/lib tv dist

# Do not overwrite existing user-edited project files on reruns.
write_new() {
  local path="$1"
  if [[ -e "$path" && ! ( "$path" == 'app/lib/main.dart' || "$path" == 'app/test/widget_test.dart' ) ]]; then
    cat >/dev/null
    echo "Preserved existing $path"
  elif [[ -e "$path" && -e .taptether-bootstrapped ]]; then
    cat >/dev/null
    echo "Preserved existing $path"
  else
    mkdir -p "$(dirname "$path")"
    cat >"$path"
    echo "Created $path"
  fi
}

write_new .gitignore <<'TT_GITIGNORE'
# Generated builds and local tooling
.dart_tool/
.flutter-plugins*
.packages
**/build/
**/.gradle/
**/DerivedData/
**/Pods/
**/.symlinks/
**/Flutter/ephemeral/
**/Generated.xcconfig
**/flutter_export_environment.sh
.idea/
.vscode/
*.iml
.DS_Store
# Never commit local agent identity or credentials
.env
.env.*
!.env.example
*.pem
*.key
*.p12
*.mobileprovision
*.keystore
*.jks
config.local.json
dist/
coverage/
TT_GITIGNORE

write_new VERSION <<'TT_VERSION'
0.3.1+7
TT_VERSION

# Flutter tooling creates native iOS and Android runner projects; do not hand-code those.
if command -v flutter >/dev/null 2>&1; then
  if [[ ! -d app/ios || ! -d app/android ]]; then
    echo 'Generating native iOS/Android Flutter project...'
    (cd app && flutter create --platforms=ios,android --org com.taptether --project-name taptether .)
  fi
else
  echo 'Flutter not found. Dart sources/scripts will be generated now.'
  echo 'Install Flutter and run ./bin/0-doctor.sh --repair to create iOS/Android runners.'
fi

# The Flutter-generated starter screen is replaced only on a first bootstrap.
if [[ ! -e .taptether-bootstrapped ]]; then
  cat >app/pubspec.yaml <<'TT_PUBSPEC'
name: taptether
description: Local-first universal remote for trusted personal devices.
publish_to: none
version: 0.3.1+7
environment:
  sdk: '>=3.4.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  crypto: ^3.0.3
dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^5.0.0
flutter:
  uses-material-design: true
TT_PUBSPEC
  echo 'Created app/pubspec.yaml'
fi

write_new app/lib/main.dart <<'TT_FLUTTER'
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

void main() => runApp(const TapTetherApp());

class TapTetherApp extends StatelessWidget {
  const TapTetherApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'TapTether',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF57E6C2),
          scaffoldBackgroundColor: const Color(0xFF102326),
        ),
        home: const RemoteScreen(),
      );
}

/// Pin the locally generated certificate. Never accept arbitrary certificates.
/// No cloud, analytics SDK, or outbound endpoint exists in this app.
class LocalAgent {
  HttpClient? _client;
  Uri? _base;
  String? _token;

  bool get configured => _base != null && _client != null;

  void configure(String host, String token, String fingerprint) {
    host = host.trim();
    final expected = fingerprint.replaceAll(RegExp(r'[^a-fA-F0-9]'), '').toUpperCase();
    if (expected.length != 64) {
      throw const FormatException('Enter the complete 64-character TLS SHA-256 fingerprint.');
    }
    if (token.trim().length < 20) {
      throw const FormatException('Enter the pairing token printed by the agent.');
    }
    if (!_isLocalHost(host)) {
      throw const FormatException('Only RFC1918 private IPv4 or .local hosts are allowed.');
    }
    _client?.close(force: true);
    final context = SecurityContext(withTrustedRoots: false);
    final client = HttpClient(context: context);
    client.connectionTimeout = const Duration(seconds: 4);
    client.badCertificateCallback = (cert, _, __) {
      try {
        final b64 = cert.pem
            .replaceAll('-----BEGIN CERTIFICATE-----', '')
            .replaceAll('-----END CERTIFICATE-----', '')
            .replaceAll(RegExp(r'\s+'), '');
        final digest = sha256.convert(base64Decode(b64)).toString().toUpperCase();
        return digest == expected;
      } catch (_) {
        return false;
      }
    };
    _client = client;
    _base = Uri(scheme: 'https', host: host, port: 48321);
    _token = token.trim();
  }

  static bool _isLocalHost(String host) {
    if (RegExp(r'^[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*\.local$').hasMatch(host)) return true;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final oct = parts.map(int.tryParse).toList();
    if (oct.any((v) => v == null || v < 0 || v > 255)) return false;
    final a = oct[0]!, b = oct[1]!;
    return a == 10 || (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) || a == 127;
  }

  Future<void> send(String type, [Map<String, Object> details = const {}]) async {
    if (!configured) throw StateError('Connect to your local agent first.');
    final req = await _client!.postUrl(_base!.resolve('/api/control'));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'type': type, ...details}));
    final res = await req.close().timeout(const Duration(seconds: 5));
    if (res.statusCode != 204) {
      final body = await utf8.decoder.bind(res).join();
      throw StateError('Agent response ${res.statusCode}: $body');
    }
    await res.drain<void>();
  }

  void disconnect() {
    _client?.close(force: true);
    _client = null;
    _base = null;
    _token = null;
  }
}

class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key});
  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  final agent = LocalAgent();
  final host = TextEditingController();
  final token = TextEditingController();
  final pin = TextEditingController();
  final typing = TextEditingController();
  String status = 'Not connected';
  int fingers = 0;
  DateTime lastMovement = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    host.dispose(); token.dispose(); pin.dispose(); typing.dispose();
    agent.disconnect();
    super.dispose();
  }

  Future<void> command(String type, [Map<String, Object> data = const {}]) async {
    try {
      await agent.send(type, data);
    } catch (e) {
      if (mounted) setState(() => status = e.toString());
    }
  }

  Future<void> connect() async {
    try {
      agent.configure(host.text, token.text, pin.text);
      await agent.send('ping');
      if (mounted) setState(() => status = 'Connected to ${host.text.trim()}');
    } catch (e) {
      agent.disconnect();
      if (mounted) setState(() => status = '$e');
    }
  }

  Widget keyButton(String label, String key, {double? width}) =>
      SizedBox(width: width, child: OutlinedButton(
        onPressed: agent.configured ? () => command('key', {'key': key}) : null,
        child: Text(label, textAlign: TextAlign.center),
      ));

  @override
  Widget build(BuildContext context) {
    final connected = agent.configured;
    return Scaffold(
      appBar: AppBar(title: const Text('TapTether'), actions: [
        IconButton(tooltip: 'Disconnect', onPressed: connected ? () {
          agent.disconnect(); setState(() => status = 'Disconnected');
        } : null, icon: const Icon(Icons.link_off)),
      ]),
      body: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Your devices. Your control. Your network.',
            style: TextStyle(color: Color(0xFF57E6C2))),
        const SizedBox(height: 12),
        if (!connected) ...[
          const Text('Pair with Ubuntu agent', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text('Run the agent on Ubuntu and copy its LAN IP, token and certificate SHA-256 fingerprint. These credentials are kept in memory only.'),
          const SizedBox(height: 12),
          TextField(controller: host, autocorrect: false,
              decoration: const InputDecoration(labelText: 'Ubuntu LAN IP (e.g. 192.168.1.10)', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          TextField(controller: token, obscureText: true, autocorrect: false,
              decoration: const InputDecoration(labelText: 'Agent pairing token', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          TextField(controller: pin, autocorrect: false,
              decoration: const InputDecoration(labelText: 'Certificate SHA-256 fingerprint', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          FilledButton.icon(onPressed: connect, icon: const Icon(Icons.lan), label: const Text('Connect locally')),
        ] else ...[
          const Text('Trackpad', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const Text('Move: one finger  ·  Scroll: two fingers  ·  Tap: click  ·  Long press: right click'),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => command('click', {'button': 'left'}),
            onDoubleTap: () => command('click', {'button': 'double'}),
            onLongPress: () => command('click', {'button': 'right'}),
            child: Listener(
              onPointerDown: (_) => fingers++,
              onPointerUp: (_) => fingers = fingers > 0 ? fingers - 1 : 0,
              onPointerCancel: (_) => fingers = fingers > 0 ? fingers - 1 : 0,
              onPointerMove: (event) {
                final now = DateTime.now();
                if (now.difference(lastMovement).inMilliseconds < 22) return;
                lastMovement = now;
                if (fingers > 1) {
                  final dy = event.delta.dy.round();
                  if (dy != 0) unawaited(command('scroll', {'dy': dy}));
                } else {
                  final dx = (event.delta.dx * 1.7).round();
                  final dy = (event.delta.dy * 1.7).round();
                  if (dx != 0 || dy != 0) unawaited(command('move', {'dx': dx, 'dy': dy}));
                }
              },
              child: Container(
                height: 260,
                decoration: BoxDecoration(
                  color: const Color(0xFF1B393C),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF57E6C2).withValues(alpha: 0.25))),
                child: const Center(child: Icon(Icons.touch_app, size: 50, color: Color(0xFF57E6C2))),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: () => command('click', {'button': 'left'}), child: const Text('Left click'))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton(onPressed: () => command('click', {'button': 'right'}), child: const Text('Right click'))),
          ]),
          const SizedBox(height: 12),
          TextField(controller: typing, autocorrect: false, enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Type on computer', border: OutlineInputBorder()),
            onChanged: (text) {
              if (text.isNotEmpty) {
                unawaited(command('text', {'text': text}));
                typing.clear();
              }
            }),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 4, children: [
            keyButton('Esc','Escape'), keyButton('Tab','Tab'),
            keyButton('Enter','Return'), keyButton('⌫','BackSpace'),
            keyButton('↑','Up'), keyButton('↓','Down'),
            keyButton('←','Left'), keyButton('→','Right'),
            keyButton('Ctrl+C','ctrl+c'), keyButton('Ctrl+V','ctrl+v'),
            keyButton('Ctrl+L','ctrl+l'), keyButton('Alt+Tab','alt+Tab'),
          ]),
          const SizedBox(height: 8),
          const Text('System volume', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          Wrap(spacing: 8, runSpacing: 4, children: [
            keyButton('Volume −', 'XF86AudioLowerVolume'),
            keyButton('Mute', 'XF86AudioMute'),
            keyButton('Volume +', 'XF86AudioRaiseVolume'),
          ]),
        ],
        const SizedBox(height: 16),
        Text(status, style: const TextStyle(fontSize: 12, color: Colors.white70)),
      ])),
    );
  }
}
TT_FLUTTER

write_new app/test/widget_test.dart <<'TT_TEST'
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/main.dart';

void main() {
  testWidgets('TapTether shows pairing screen', (tester) async {
    await tester.pumpWidget(const TapTetherApp());
    expect(find.text('Pair with Ubuntu agent'), findsOneWidget);
  });
}
TT_TEST

write_new agent/go.mod <<'TT_GOMOD'
module github.com/ssnanda/taptether.com/agent

go 1.22
TT_GOMOD

write_new agent/internal/input/types.go <<'TT_INPUT_TYPES'
package input

import "fmt"

type Event struct {
 Type string `json:"type"`
 DX int `json:"dx,omitempty"`
 DY int `json:"dy,omitempty"`
 Button string `json:"button,omitempty"`
 Key string `json:"key,omitempty"`
 Text string `json:"text,omitempty"`
}

func (e Event) Validate() error {
 switch e.Type {
 case "ping": return nil
 case "move": if e.DX < -300 || e.DX > 300 || e.DY < -300 || e.DY > 300 {return fmt.Errorf("movement too large")}
 case "scroll": if e.DY < -100 || e.DY > 100 {return fmt.Errorf("scroll too large")}
 case "click": if e.Button != "left" && e.Button != "right" && e.Button != "double" {return fmt.Errorf("invalid mouse button")}
 case "key": if len(e.Key) < 1 || len(e.Key) > 48 {return fmt.Errorf("invalid key")}
 case "text": if len(e.Text) == 0 || len(e.Text) > 256 {return fmt.Errorf("text length outside limits")}
 default: return fmt.Errorf("unknown command type")
 }
 return nil
}
TT_INPUT_TYPES

write_new agent/internal/input/input_linux.go <<'TT_INPUT_LINUX'
//go:build linux

package input

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// uinput works on Wayland and X11 without RemoteDesktop portal popups.
// On X11 only, xdotool is a compatibility fallback if uinput is unavailable.
func Send(e Event) error {
	if e.Type == "ping" {
		return nil
	}
	if activeDevice == nil {
		device, err := newVirtualDevice()
		if err == nil {
			activeDevice = device
		} else {
			if os.Getenv("XDG_SESSION_TYPE") == "wayland" || os.Getenv("DISPLAY") == "" {
				return fmt.Errorf("native Wayland input unavailable: %w", err)
			}
			return sendX11(e)
		}
	}
	return activeDevice.send(e)
}
func sendX11(e Event) error {
	if os.Getenv("DISPLAY") == "" {
		return fmt.Errorf("DISPLAY not set, X11 fallback unavailable")
	}
	if _, err := exec.LookPath("xdotool"); err != nil {
		return fmt.Errorf("X11 fallback requires xdotool: %w", err)
	}
	var args []string
	switch e.Type {
	case "move":
		args = []string{"mousemove_relative", "--", strconv.Itoa(e.DX), strconv.Itoa(e.DY)}
	case "scroll":
		if e.DY == 0 {
			return nil
		}
		button := "4"
		if e.DY > 0 {
			button = "5"
		}
		ticks := e.DY
		if ticks < 0 {
			ticks = -ticks
		}
		if ticks > 8 {
			ticks = 8
		}
		args = []string{"click", "--repeat", strconv.Itoa(ticks), "--delay", "20", button}
	case "click":
		switch e.Button {
		case "right":
			args = []string{"click", "3"}
		case "double":
			args = []string{"click", "--repeat", "2", "--delay", "100", "1"}
		default:
			args = []string{"click", "1"}
		}
	case "key":
		for _, ch := range strings.TrimSpace(e.Key) {
			if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '+' || ch == '_' || ch == '-') {
				return fmt.Errorf("unsupported key combination")
			}
		}
		args = []string{"key", "--clearmodifiers", e.Key}
	case "text":
		args = []string{"type", "--clearmodifiers", "--delay", "0", "--", e.Text}
	default:
		return fmt.Errorf("unsupported input event")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "xdotool", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("xdotool failed: %w (%s)", err, strings.TrimSpace(string(output)))
	}
	return nil
}
TT_INPUT_LINUX

write_new agent/internal/input/input_other.go <<'TT_INPUT_OTHER'
//go:build !linux
package input

import "fmt"

// Cross-platform Go binaries compile now; native input backends are planned.
func Send(e Event) error {
 if e.Type == "ping" {return nil}
 return fmt.Errorf("input backend for this operating system is not implemented yet")
}
TT_INPUT_OTHER

write_new agent/cmd/taptether-agent/main.go <<'TT_GO_MAIN'
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
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
	"strings"
	"sync"
	"time"

	"github.com/ssnanda/taptether.com/agent/internal/input"
)

var version = "dev"

func main() {
	addr := flag.String("listen", ":48321", "TLS listen address; use a LAN firewall for additional restriction")
	flag.Parse()
	dir, err := os.UserConfigDir()
	fatalIf(err)
	dir = filepath.Join(dir, "taptether")
	fatalIf(os.MkdirAll(dir, 0700))
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
	fmt.Println("Linux Wayland/X11 native uinput is supported; X11 can fall back to xdotool. Windows/macOS input is not implemented.")
	fmt.Println("No telemetry or outgoing network connections are implemented. Restrict inbound port 48321 to trusted LAN devices.")
	mux := http.NewServeMux()
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
		got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if subtle.ConstantTimeCompare([]byte(got), []byte(token)) != 1 {
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
		mu.Lock()
		err := input.Send(cmd)
		mu.Unlock()
		if err != nil {
			http.Error(w, err.Error(), http.StatusUnprocessableEntity)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
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
TT_GO_MAIN

# Fix the type of the pkix.Name helper with a direct stdlib import.
if grep -q 'func pkixName()' agent/cmd/taptether-agent/main.go; then
  python3 - <<'TT_PATCHGO'
from pathlib import Path
p=Path('agent/cmd/taptether-agent/main.go')
s=p.read_text()
s=s.replace('"crypto/x509"','"crypto/x509"\n "crypto/x509/pkix"')
s=s.replace('func pkixName() (name struct{CommonName string}) {name.CommonName="TapTether Local Agent";return name}', 'func pkixName() pkix.Name { return pkix.Name{CommonName:"TapTether Local Agent"} }')
p.write_text(s)
TT_PATCHGO
fi

write_new agent/cmd/taptether-agent/main_test.go <<'TT_GO_TEST'
package main

import "testing"
func TestLANRestrictions(t *testing.T){
 cases:=map[string]bool{"192.168.1.11:3000":true,"10.0.0.1:80":true,"127.0.0.1:443":true,"8.8.8.8:443":false,"1.1.1.1:80":false,"garbage":false}
 for s,want:=range cases{if got:=privateRemote(s);got!=want{t.Errorf("%s=%v; want %v",s,got,want)}}
}
TT_GO_TEST

write_new bin/0-doctor.sh <<'TT_DOCTOR'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
echo 'TapTether toolchain check'
for app in git flutter dart go python3; do
  if command -v "$app" >/dev/null 2>&1; then echo "OK: $app ($(command -v "$app"))"; else echo "MISSING: $app"; fi
done
if [[ "$(uname -s)" == Darwin ]]; then
  if command -v xcodebuild >/dev/null 2>&1; then echo 'OK: Xcode build tools'; else echo 'MISSING: Xcode build tools'; fi
  if command -v pod >/dev/null 2>&1; then echo 'OK: CocoaPods'; else echo 'MISSING: CocoaPods (may be required for iOS plugins)'; fi
fi
if [[ "$(uname -s)" == Linux ]]; then
  command -v xdotool >/dev/null 2>&1 && echo 'OK: xdotool' || echo 'MISSING: xdotool (sudo apt install xdotool)'
  [[ -n "${DISPLAY:-}" ]] && echo "X11 DISPLAY=${DISPLAY}" || echo 'No DISPLAY; Ubuntu input requires active X11 desktop'
fi
if [[ "${1:-}" == --repair ]]; then
  command -v flutter >/dev/null 2>&1 || { echo 'Install Flutter first' >&2; exit 1; }
  (cd app && flutter create --platforms=ios,android --org com.taptether --project-name taptether . && flutter pub get)
  echo 'Flutter native platform projects generated/repaired.'
fi
TT_DOCTOR

write_new bin/1-bump-version.sh <<'TT_BUMP'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
kind="${1:-patch}"
case "$kind" in patch|minor|major) ;; *) echo 'Usage: ./bin/1-bump-version.sh [patch|minor|major]' >&2;exit 2;;esac
[[ -d .git ]] || { echo 'Not a git repository' >&2; exit 1; }
[[ "$(git branch --show-current)" == main ]] || { echo 'Switch to the main branch before bumping/pushing.' >&2; exit 1; }
remote="$(git remote get-url origin 2>/dev/null || true)"
case "$remote" in
  git@github.com:ssnanda/taptether.com.git|ssh://git@github.com/ssnanda/taptether.com.git|https://github.com/ssnanda/taptether.com.git|https://github.com/ssnanda/taptether.com) ;;
  *) echo "Refusing push: origin is not ssnanda/taptether.com ($remote)" >&2;exit 1;;
esac
# Avoid mixing a version-only commit with already-staged unrelated edits.
if ! git diff --cached --quiet; then echo 'Commit/unstage currently staged changes first.' >&2;exit 1;fi
command -v python3 >/dev/null 2>&1 || { echo 'python3 is required' >&2; exit 1; }
python3 - "$kind" <<'TT_BUMPPY'
import re,sys
from pathlib import Path
kind=sys.argv[1]
p=Path('VERSION')
q=Path('app/pubspec.yaml')
old=p.read_text().strip()
m=re.fullmatch(r'(\d+)\.(\d+)\.(\d+)\+(\d+)',old)
if not m: raise SystemExit('Unexpected VERSION format: '+old)
a,b,c,n=map(int,m.groups())
if kind=='major': a,b,c=a+1,0,0
elif kind=='minor':b,c=b+1,0
else:c+=1
new=f'{a}.{b}.{c}+{n+1}'
s=q.read_text()
s,count=re.subn(r'(?m)^version:\s*\S+\s*$',f'version: {new}',s,count=1)
if count!=1:raise SystemExit('Could not update app/pubspec.yaml version')
q.write_text(s)
p.write_text(new+'\n')
print(f'Version: {old} -> {new}')
TT_BUMPPY
version="$(cat VERSION)"
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  git add -- VERSION app/pubspec.yaml
else
  echo 'No commits yet: adding initial project scaffold with this first version bump.'
  git add -A
  git diff --cached --stat
fi
git commit -m "chore: bump TapTether to $version"
git push -u origin main
echo "Pushed version $version to github.com/ssnanda/taptether.com (main)"
TT_BUMP

write_new bin/2a-tt-apk.sh <<'TT_APK'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v flutter >/dev/null 2>&1 || { echo 'Flutter SDK not found.' >&2;exit 1; }
cd "$ROOT/app"
flutter pub get
flutter build apk --release "$@"
mkdir -p "$ROOT/dist/android"
version="$(cat "$ROOT/VERSION")"
cp build/app/outputs/flutter-apk/app-release.apk "$ROOT/dist/android/TapTether-${version}.apk"
echo "APK: $ROOT/dist/android/TapTether-${version}.apk"
TT_APK

write_new bin/2a-tt-ipa.sh <<'TT_IPA'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo 'IPA builds require macOS with Xcode.' >&2;exit 1; }
command -v flutter >/dev/null 2>&1 || { echo 'Flutter SDK not found.' >&2;exit 1; }
command -v xcodebuild >/dev/null 2>&1 || { echo 'Xcode not found.' >&2;exit 1; }
cd "$ROOT/app"
flutter pub get
version="$(cat "$ROOT/VERSION")"
mkdir -p "$ROOT/dist/ios"
if [[ "${1:-}" == --signed ]]; then
  shift
  flutter build ipa --release "$@"
  echo 'Signed IPA (requires configured Apple signing): app/build/ios/ipa/'
else
  [[ "${1:-}" == --unsigned ]] && shift
  flutter build ios --release --no-codesign "$@"
  [[ -d build/ios/iphoneos/Runner.app ]] || { echo 'Runner.app missing.' >&2;exit 1; }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/Payload"
  cp -R build/ios/iphoneos/Runner.app "$tmp/Payload/"
  output="$ROOT/dist/ios/TapTether-${version}-unsigned.ipa"
  (cd "$tmp" && /usr/bin/zip -qry "$output" Payload)
  echo "Unsigned IPA: $output"
  echo 'Unsigned IPA requires external signing (for example AltStore) before installation on iPhone.'
fi
TT_IPA

write_new bin/2b-tt-agent.sh <<'TT_AGENTBUILD'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
target="${1:-}"
arch="${2:-amd64}"
case "$target" in linux|darwin|windows) ;; *) echo 'Usage: ./bin/2b-tt-agent.sh linux|darwin|windows [amd64|arm64]' >&2;exit 2;;esac
case "$arch" in amd64|arm64) ;; *) echo 'Supported architectures: amd64, arm64' >&2;exit 2;;esac
command -v go >/dev/null 2>&1 || { echo 'Go not installed.' >&2;exit 1; }
version="$(cat "$ROOT/VERSION")"
mkdir -p "$ROOT/dist/agents"
ext=''; [[ "$target" == windows ]] && ext='.exe'
output="$ROOT/dist/agents/TapTetherAgent-${target}-${arch}-${version}${ext}"
(cd "$ROOT/agent" && CGO_ENABLED=0 GOOS="$target" GOARCH="$arch" go build -trimpath -ldflags "-s -w -X main.version=$version" -o "$output" ./cmd/taptether-agent)
echo "Built $output"
TT_AGENTBUILD

write_new bin/2b-tt-ubuntu.sh <<'TT_UBUNTU'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/bin/2b-tt-agent.sh" linux amd64
"$ROOT/bin/2b-tt-agent.sh" linux arm64
"$ROOT/bin/2b-tt-deb.sh"
TT_UBUNTU

write_new bin/2b-tt-deb.sh <<'TT_DEB'
#!/usr/bin/env bash
# Portable Debian package builder: avoids macOS ar/ranlib's Mach-O symbol index.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'Python 3 is required for .deb packaging.' >&2; exit 1; }
python3 - "$ROOT" <<'TT_DEB_PY'
from __future__ import annotations

import io
import os
from pathlib import Path
import re
import sys
import tarfile
import tempfile

root = Path(sys.argv[1])
version = (root / 'VERSION').read_text(encoding='utf-8').strip()
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+', version):
    raise SystemExit(f'Invalid package version: {version!r}')

output_dir = root / 'dist' / 'ubuntu'
output_dir.mkdir(parents=True, exist_ok=True)


def tar_gz(members):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz', format=tarfile.USTAR_FORMAT) as archive:
        for path, content, mode in members:
            entry = tarfile.TarInfo(path)
            entry.size = len(content)
            entry.mode = mode
            entry.uid = entry.gid = entry.mtime = 0
            entry.uname = entry.gname = 'root'
            archive.addfile(entry, io.BytesIO(content))
    return buffer.getvalue()


def write_ar_member(fh, name, data):
    if len(name) > 15:
        raise ValueError(f'Debian archive member name too long: {name}')
    header = (
        f'{name + "/":<16}'
        f'{0:<12}'
        f'{0:<6}'
        f'{0:<6}'
        f'{"100644":<8}'
        f'{len(data):<10}'
        '`\n'
    ).encode('ascii')
    if len(header) != 60:
        raise AssertionError('Invalid ar header length')
    fh.write(header)
    fh.write(data)
    if len(data) % 2:
        fh.write(b'\n')


for arch in ('amd64', 'arm64'):
    binary_path = root / 'dist' / 'agents' / f'TapTetherAgent-linux-{arch}-{version}'
    if not binary_path.is_file():
        raise SystemExit(f'Missing {binary_path}; run ./bin/2b-tt-ubuntu.sh first')
    binary = binary_path.read_bytes()
    if len(binary) < 1024 or not binary.startswith(b'\x7fELF'):
        raise SystemExit(f'Not a plausible Linux ELF executable: {binary_path}')
    control = (
        'Package: taptether-agent\n'
        f'Version: {version}\n'
        'Section: utils\n'
        'Priority: optional\n'
        f'Architecture: {arch}\n'
        'Maintainer: TapTether <support@taptether.com>\n'
        'Depends: xdotool\n'
        'Description: TapTether Wayland/X11 virtual keyboard, mouse and volume agent\n'
        ' A local HTTPS remote input agent with native Linux uinput support.\n'
        ' No cloud account or telemetry.\n'
    ).encode('utf-8')
    members = (
        ('debian-binary', b'2.0\n'),
        ('control.tar.gz', tar_gz([('control', control, 0o644)])),
        ('data.tar.gz', tar_gz([('usr/local/bin/taptether-agent', binary, 0o755)])),
    )
    output = output_dir / f'taptether-agent_{version}_{arch}.deb'
    fd, temp_path = tempfile.mkstemp(prefix=f'.taptether-{arch}-', suffix='.deb', dir=output_dir)
    try:
        with os.fdopen(fd, 'wb') as fh:
            fh.write(b'!<arch>\n')
            for name, data in members:
                write_ar_member(fh, name, data)
        if os.path.getsize(temp_path) < 1024:
            raise RuntimeError(f'Unexpectedly small package: {temp_path}')
        os.replace(temp_path, output)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)
    print(f'Debian package: {output} ({output.stat().st_size:,} bytes)')
TT_DEB_PY
TT_DEB

write_new bin/2b-tt-windows.sh <<'TT_WINDOWS'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/bin/2b-tt-agent.sh" windows amd64
"$ROOT/bin/2b-tt-agent.sh" windows arm64
TT_WINDOWS

write_new bin/2b-tt-macos.sh <<'TT_MACOS'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/bin/2b-tt-agent.sh" darwin amd64
"$ROOT/bin/2b-tt-agent.sh" darwin arm64
TT_MACOS

write_new bin/2c-tt-android-tv.sh <<'TT_ANDROIDTV'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo 'Experimental Android TV APK: currently uses the mobile layout (not TV-optimized).'
"$ROOT/bin/2a-tt-apk.sh" "$@"
TT_ANDROIDTV

write_new bin/2c-tt-lg-tv.sh <<'TT_LG'
#!/usr/bin/env bash
set -euo pipefail
echo 'LG webOS TV Flutter build target requires LG webOS Flutter SDK, device eligibility, and TV project setup.' >&2
echo 'No .ipk is generated by this initial mobile/Ubuntu scaffold. See tv/README.md.' >&2
exit 2
TT_LG

write_new bin/2c-tt-samsung-tv.sh <<'TT_SAMSUNG'
#!/usr/bin/env bash
set -euo pipefail
echo 'Samsung Tizen Flutter build target requires Flutter-Tizen and Tizen TV SDK configuration.' >&2
echo 'No .tpk is generated by this initial mobile/Ubuntu scaffold. See tv/README.md.' >&2
exit 2
TT_SAMSUNG

write_new bin/2d-tt-all.sh <<'TT_ALL'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/bin/2b-tt-ubuntu.sh"
"$ROOT/bin/2b-tt-windows.sh"
"$ROOT/bin/2b-tt-macos.sh"
if command -v flutter >/dev/null 2>&1; then
  "$ROOT/bin/2a-tt-apk.sh"
  if [[ "$(uname -s)" == Darwin ]]; then
    "$ROOT/bin/2a-tt-ipa.sh"
  fi
else
  echo 'Flutter missing: mobile builds skipped.'
fi
echo 'All available TapTether artifacts are in dist/.'
TT_ALL

write_new bin/3-run-agent.sh <<'TT_RUN'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/agent"
exec go run ./cmd/taptether-agent "$@"
TT_RUN

write_new bin/3-push-project.sh <<'TT_PUSH'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "$(git branch --show-current)" == main ]] || { echo 'Switch to main branch first' >&2; exit 1; }
remote="$(git remote get-url origin 2>/dev/null || true)"
case "$remote" in
  git@github.com:ssnanda/taptether.com.git|ssh://git@github.com/ssnanda/taptether.com.git|https://github.com/ssnanda/taptether.com.git|https://github.com/ssnanda/taptether.com) ;;
  *) echo "Wrong origin: $remote" >&2;exit 1;;
esac
printf 'Stage ALL nonignored files and push to ssnanda/taptether.com? [y/N] '
read -r ans
[[ "$ans" == y || "$ans" == Y ]] || exit 0
git add -A
git diff --cached --stat
if git diff --cached --quiet; then echo 'No changes to commit.';else
  git commit -m "chore: update TapTether project"
fi
git push -u origin main
TT_PUSH

write_new bin/4-ubuntu-desktop-setup.sh <<'TT_DESKTOP_SH'
#!/usr/bin/env bash
# TapTether Ubuntu installer: restricted uinput access, boot service, dock launcher, SSH management.
# Installs a systemd SYSTEM service running as this ordinary desktop user (never root).
set -euo pipefail

UNIT='taptether-agent.service'
SYS_SERVICE="/etc/systemd/system/$UNIT"
OLD_USER_SERVICE="$HOME/.config/systemd/user/$UNIT"
CTL="$HOME/.local/bin/taptetherctl"
APP="$HOME/.local/share/applications/taptether.desktop"
OLD_AUTOSTART="$HOME/.config/autostart/taptether-agent.desktop"
CONFIG="$HOME/.config/taptether"
AGENT='/usr/local/bin/taptether-agent'

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf 'TapTether: %s\n' "$*"; }
user_bus() {
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  if [[ -S "$XDG_RUNTIME_DIR/bus" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  fi
}
pin() {
  if ! command -v gsettings >/dev/null 2>&1; then
    note 'GNOME dock not available here. The launcher remains in Show Applications.'
    return 0
  fi
  user_bus
  if ! python3 - <<'PY'
import ast
import subprocess
import sys
try:
    value = subprocess.check_output(
        ['gsettings', 'get', 'org.gnome.shell', 'favorite-apps'],
        text=True, stderr=subprocess.DEVNULL).strip()
    if value.startswith('@as '):
        value = value[4:]
    entries = ast.literal_eval(value)
    if not isinstance(entries, list):
        raise ValueError('unexpected favorites setting')
    if 'taptether.desktop' not in entries:
        entries.append('taptether.desktop')
        subprocess.run(['gsettings', 'set', 'org.gnome.shell', 'favorite-apps', str(entries)],
                       check=True, stderr=subprocess.DEVNULL)
    print('TapTether added to the GNOME dock.')
except (OSError, ValueError, SyntaxError, subprocess.CalledProcessError) as exc:
    print('Dock pinning was not possible over SSH:', exc, file=sys.stderr)
    sys.exit(1)
PY
  then
    note 'Pin it manually: Show Applications → TapTether → Add to Favorites.'
  fi
}
setup_permissions() {
  # Only the daemon receives the privileged input group through systemd.
  # The interactive user is NOT added to this group.
  sudo groupadd --system --force taptether
  printf 'uinput\n' | sudo tee /etc/modules-load.d/taptether-uinput.conf >/dev/null
  printf 'KERNEL=="uinput", SUBSYSTEM=="misc", GROUP="taptether", MODE="0660"\n' \
    | sudo tee /etc/udev/rules.d/80-taptether-uinput.rules >/dev/null
  sudo modprobe uinput
  sudo udevadm control --reload-rules
  sudo udevadm trigger --subsystem-match=misc --sysname-match=uinput || true
  [[ -e /dev/uinput ]] || fail '/dev/uinput not available on this Ubuntu kernel.'
  sudo chgrp taptether /dev/uinput
  sudo chmod 0660 /dev/uinput
}
pairing() {
  [[ -r "$CONFIG/pairing.token" && -r "$CONFIG/server.crt" ]] || \
    fail 'No pairing credentials yet. Start the service, then run taptetherctl pairing.'
  note 'PRIVATE credentials below; do not share them or publish installation logs.'
  printf 'LAN IP(s): '
  hostname -I 2>/dev/null || true
  printf 'Port: 48321\nPairing token: '
  cat "$CONFIG/pairing.token"
  printf 'TLS certificate SHA-256 fingerprint: '
  openssl x509 -in "$CONFIG/server.crt" -outform DER | sha256sum | awk '{print toupper($1)}'
}
ensure_running() {
  local attempt
  for attempt in $(seq 1 20); do
    if systemctl is-active --quiet "$UNIT" &&
       [[ -s "$CONFIG/pairing.token" && -s "$CONFIG/server.crt" ]]; then
      return 0
    fi
    sleep 1
  done
  systemctl --no-pager --full status "$UNIT" >&2 || true
  fail 'Service did not initialize in 20 seconds. Check: sudo journalctl -u taptether-agent -n 60'
}
install() {
  [[ "$(id -u)" != 0 ]] || fail 'Run installer as the Ubuntu desktop user, not root.'
  [[ -x "$AGENT" ]] || fail 'Install the TapTether .deb first.'
  command -v sudo >/dev/null 2>&1 || fail 'sudo required for a secure systemd service.'
  command -v systemctl >/dev/null 2>&1 || fail 'systemd required.'
  command -v openssl >/dev/null 2>&1 || fail 'openssl required for pairing fingerprint.'
  command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum required for pairing fingerprint.'
  local username homedir tmp
  username="$(id -un)"
  homedir="$HOME"
  [[ "$username" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || fail 'Unsafe username for unit file.'
  [[ "$homedir" == /* && "$homedir" != *$'\n'* ]] || fail 'Invalid home directory.'
  note 'Configuring /dev/uinput permissions for the service only.'
  setup_permissions
  mkdir -p "${CTL%/*}" "${APP%/*}" "$CONFIG"
  chmod 700 "$CONFIG"
  if [[ "$(realpath "${BASH_SOURCE[0]}")" != "$(realpath -m "$CTL")" ]]; then
    cp "${BASH_SOURCE[0]}" "$CTL"
  fi
  chmod 700 "$CTL"
  cat > "$APP" <<DESKTOP
[Desktop Entry]
Version=1.0
Type=Application
Name=TapTether Agent
Comment=Start TapTether local keyboard, trackpad and volume agent
Exec=$CTL start
Icon=input-keyboard
Terminal=false
StartupNotify=false
Categories=Network;Utility;
DESKTOP
  # Migrate from legacy desktop-login systemd user service. Avoid port 48321 collisions.
  user_bus
  systemctl --user disable --now "$UNIT" >/dev/null 2>&1 || true
  rm -f "$OLD_AUTOSTART" "$OLD_USER_SERVICE"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  pkill -u "$(id -u)" -x taptether-agent >/dev/null 2>&1 || true
  tmp="$(mktemp)"
  cat > "$tmp" <<SYSTEMD
[Unit]
Description=TapTether private LAN keyboard, trackpad and volume agent
After=systemd-modules-load.service network.target

[Service]
Type=simple
User=$username
SupplementaryGroups=taptether
Environment="HOME=$homedir"
ExecStart=$AGENT
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
CapabilityBoundingSet=
ProtectSystem=full
PrivateTmp=true
# The agent prints its secret token on stdout: never put stdout in the system journal.
StandardOutput=null
StandardError=journal

[Install]
WantedBy=multi-user.target
SYSTEMD
  sudo install -m 0644 "$tmp" "$SYS_SERVICE"
  rm -f "$tmp"
  sudo systemctl daemon-reload
  sudo systemctl enable "$UNIT"
  sudo systemctl restart "$UNIT"
  ensure_running
  pin
  note 'Agent running now in the background and enabled at system boot (even before desktop login).'
  note 'You can retrieve credentials later with: ~/.local/bin/taptetherctl pairing'
  printf '\n====== TapTether pairing details ======\n'
  pairing
  printf '=======================================\n'
  note 'SSH controls: ~/.local/bin/taptetherctl {start|stop|restart|status|pairing|logs|permissions|pin}'
  note 'Security: uinput grants control even at the lock/login screen. Restrict TCP 48321 to trusted LAN devices.'
}
start() {
  sudo systemctl start "$UNIT"
  ensure_running
  note 'Agent running in background.'
}
stop() { sudo systemctl stop "$UNIT"; note 'Agent stopped.'; }
restart() { sudo systemctl restart "$UNIT"; ensure_running; note 'Agent restarted.'; }
status() {
  systemctl --no-pager --full status "$UNIT" || true
  printf '\nAuto-start at reboot: '
  systemctl is-enabled "$UNIT" || true
}
permissions() {
  ls -l /dev/uinput 2>&1 || true
  printf 'Expected input group: taptether (assigned to systemd service, not your SSH shell)\n'
  if systemctl is-active --quiet "$UNIT"; then
    note 'TapTether system service is active.'
  else
    note 'TapTether service is not running.'
  fi
}
case "${1:-}" in
  install) install ;;
  start) start ;;
  stop) stop ;;
  restart) restart ;;
  status) status ;;
  pairing) pairing ;;
  logs) journalctl --no-pager -u "$UNIT" -n 60 ;;
  permissions) permissions ;;
  pin) pin ;;
  session-start) : ;;  # Compatibility with old GNOME autostart references.
  *) printf 'Usage: taptetherctl {install|start|stop|restart|status|pairing|logs|permissions|pin}\n' >&2; exit 2 ;;
esac
TT_DESKTOP_SH

write_new bin/4-test.sh <<'TT_TEST_SH'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$ROOT/agent" && go test ./... && go vet ./...)
if command -v flutter >/dev/null 2>&1; then
  (cd "$ROOT/app" && flutter pub get && flutter analyze && flutter test)
else
  echo 'Flutter not installed; Go tests completed, Flutter checks skipped.'
fi
TT_TEST_SH

write_new tv/README.md <<'TT_TV_DOC'
# TapTether Smart TV Targets

The Flutter mobile app can build an experimental Android TV APK, but its UI is not yet tailored for D-pad navigation or the Play Store TV requirements.

LG webOS and Samsung Tizen require **separate vendor SDK targets**. A normal Flutter iOS/Android build cannot produce installable webOS `.ipk` or Tizen `.tpk` packages automatically. Hardware/firmware support varies. The provided LG/Samsung build scripts intentionally fail with clear instructions rather than produce fake deliverables.

**Planned approach:** Support LG/Samsung remote control from the mobile app through local TV network APIs *without installing an app on the TV* first. Investigate installable TV Flutter targets only if they add meaningful functionality. TV operating systems limit background control and input injection.
TT_TV_DOC

write_new README.md <<'TT_README'
# TapTether

**Your devices. Your control. Your network.**

Private LAN-only remote-control prototype. Single repository containing a Flutter iOS/Android app, a Go TLS-enabled agent and shell scripts for packaging multiple operating systems. Repository: `github.com/ssnanda/taptether.com` (private).

## Bootstrap on macOS

1. Place `bootstrap-taptether.sh` in `/Users/sandip/Projects/taptether`.
2. `cd /Users/sandip/Projects/taptether`.
3. `bash bootstrap-taptether.sh`.
4. `./bin/0-doctor.sh` (use `--repair` if native Flutter runners weren't created).
5. `./bin/4-test.sh`.
6. `./bin/3-push-project.sh` to commit and push initial source files.

Requires git, Go 1.22+, Flutter SDK, Android SDK for APK, and Xcode/macOS for IPA. On Ubuntu 26.04, native `/dev/uinput` input supports GNOME Wayland and X11. Restricted permissions are configured by `bin/4-ubuntu-desktop-setup.sh`; see [WAYLAND.md](WAYLAND.md).

## Scripts

| Script | Function |
|---|---|
| `./bin/0-doctor.sh` | Check prerequisites; `--repair` creates Flutter runners |
| `./bin/1-bump-version.sh [patch\|minor\|major]` | Increment VERSION and Flutter build number; git commit **and push main** |
| `./bin/2a-tt-ipa.sh` | Create **unsigned** IPA by default for later signing (e.g. AltStore) |
| `./bin/2a-tt-ipa.sh --signed` | Flutter signed IPA; needs Xcode signing configured |
| `./bin/2a-tt-apk.sh` | Build Android APK to `dist/android` |
| `./bin/2b-tt-ubuntu.sh` | Build Ubuntu/Linux agents **and two `.deb` installers** |
| `./bin/2b-tt-deb.sh` | Package Ubuntu `.deb` from prebuilt Go binaries |
| `./bin/2b-tt-windows.sh` | Build Windows agents (backend not yet implemented) |
| `./bin/2b-tt-macos.sh` | Build macOS agents (backend not yet implemented) |
| `./bin/2c-tt-android-tv.sh` | Experimental Android TV APK (phone layout) |
| `./bin/2c-tt-lg-tv.sh` | Explain TV vendor SDK prerequisites, no fake build |
| `./bin/2c-tt-samsung-tv.sh` | Explain TV vendor SDK prerequisites, no fake build |
| `./bin/3-run-agent.sh` | Start Go agent on current computer |
| `./bin/3-push-project.sh` | Review and commit all nonignored project files to main |
| `./bin/4-test.sh` | Go tests + Flutter analyze/tests (when Flutter installed) |
| `./bin/4-ubuntu-desktop-setup.sh` | SSH-installable Ubuntu X11 desktop launcher, graphical-login autostart, user service, pairing details |
| `./bin/2d-tt-all.sh` | Build all available Go targets, Ubuntu installers and available mobile targets |
| `./bin/4-ubuntu-desktop-setup.sh` | Configure native uinput permissions, GNOME dock and desktop autostart |
| `./bin/5-tt-remote-install-ubuntu.sh` | Build, install and configure the Ubuntu agent over SSH |


## Ubuntu desktop launcher and SSH setup

After installing the Ubuntu .deb, use the TapTether desktop setup helper from your Mac:

1. `scp bin/4-ubuntu-desktop-setup.sh sandip@192.168.68.87:/tmp/taptether-setup.sh`
2. `ssh -t sandip@192.168.68.87 'bash /tmp/taptether-setup.sh install'`

This installs `~/.local/bin/taptetherctl` for the **normal desktop user**, a user-level systemd service, a dock-launchable application entry, and an XDG graphical-session autostart file. The installer attempts to pin the launcher to the Ubuntu GNOME dock over the desktop D-Bus connection; if the session is not available, pin it later from Show Applications.

Use SSH to manage the agent: `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl start'`, or replace `start` with `stop`, `restart`, `status`, `logs`, or `pairing`. The `pairing` command prints the LAN IP, certificate fingerprint, **and private pairing token**; do not post the token or commit it to GitHub.

**Important:** Auto-start means **at graphical user login after reboot**, not remote control of the login screen. A logged-in **X11/Xorg** desktop session is required. Wayland, headless SSH, and controlling the screen before login are not supported in this prototype. The dock entry is a *launcher*, not a live tray-status indicator. The agent intentionally suppresses stdout in its user service so the secret pairing token isn't saved in systemd logs.

## Try Ubuntu remote control (Wayland / X11)

1. On macOS run `./bin/5-tt-remote-install-ubuntu.sh sandip@192.168.68.87`. It builds both Linux agents, securely copies the matching .deb over SSH and sets up restricted uinput permissions, desktop autostart and a GNOME dock launcher.
2. **Log out and log in to Ubuntu** or reboot once to activate `taptether` group membership.
3. From macOS use `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl start'` or just let TapTether start at graphical login.
4. Retrieve LAN IP/token/TLS fingerprint via `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl pairing'`. Keep the token private.
5. Build/install the matching TapTether iOS/Android 0.3.1+7 app to see trackpad, keyboard and volume buttons.

See [WAYLAND.md](WAYLAND.md) for permissions, SSH commands and limitations.

## Important scope notes

- **Linux path:** iOS/Android UI ⇄ authenticated HTTPS local agent ⇄ Ubuntu Wayland/X11 native uinput keyboard/mouse/media keys. X11-only xdotool fallback remains.
- Windows/macOS native input, device auto-discovery, clipboard sync, TV remote adapters, and polished TV-specific app builds are future work. Windows/macOS binaries compile but do **not** provide remote input yet.
- Native Linux uinput unit tests and cross-compilation pass; test on your actual Ubuntu desktop to verify hardware event handling. Review/verify on a private LAN before relying on it.
- An unsigned IPA is *not* independently installable; use AltStore or valid code signing. A signed IPA requires configured Xcode signing.
- TV operating systems can have compatibility or background-service restrictions; see `tv/README.md`.
- Build-time dependency downloads (Flutter/Go toolchains) are distinct from runtime communications. This app intentionally has no runtime cloud integration.

## GitHub safety

The bootstrap creates the SSH remote `git@github.com:ssnanda/taptether.com.git` unless an allowed matching origin is already present. It does **not** push automatically. `1-bump-version.sh` commits **only the version files** and pushes to `main`; run `3-push-project.sh` for other source changes. It refuses to push to a different repository. On the **first** commit only, `1-bump-version.sh` stages the initial scaffold so the new private repository is usable.
TT_README

write_new agent/internal/input/uinput_linux.go <<'TT_UINPUT_NATIVE'
//go:build linux

package input

import (
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
	"unsafe"
)

// TapTether uses the Linux virtual HID interface, rather than Wayland's
// RemoteDesktop portal. Access to /dev/uinput is restricted by a dedicated
// local group; this agent must NEVER run as root or expose an internet listener.
const (
	evSyn         = 0
	evKey         = 1
	evRel         = 2
	synReport     = 0
	relX          = 0
	relY          = 1
	relWheel      = 8
	btnLeft       = 0x110
	btnRight      = 0x111
	keyLeftShift  = 42
	keyLeftCtrl   = 29
	keyLeftAlt    = 56
	keyLeftMeta   = 125
	keyVolumeDown = 114
	keyVolumeUp   = 115
	keyMute       = 113
	uiDevCreate   = 0x5501
	uiDevDestroy  = 0x5502
	uiDevSetup    = 0x405c5503 // _IOW('U',3,struct uinput_setup), 92 bytes
	uiSetEvBit    = 0x40045564
	uiSetKeyBit   = 0x40045565
	uiSetRelBit   = 0x40045566
)

type uinputSetup struct {
	Bustype, Vendor, Product, Version uint16
	Name                              [80]byte
	MaxEffects                        uint32
}

type virtualDevice struct{ f *os.File }

var activeDevice *virtualDevice

func ioctl(fd uintptr, request, value uintptr) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, request, value)
	if errno != 0 {
		return errno
	}
	return nil
}

func newVirtualDevice() (*virtualDevice, error) {
	f, err := os.OpenFile("/dev/uinput", os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		if errors.Is(err, os.ErrPermission) {
			return nil, fmt.Errorf("/dev/uinput permission denied: run Ubuntu desktop setup and log out/in to activate the taptether group: %w", err)
		}
		return nil, fmt.Errorf("cannot open /dev/uinput (run sudo modprobe uinput and desktop setup): %w", err)
	}
	device := &virtualDevice{f: f}
	success := false
	defer func() {
		if !success {
			_ = f.Close()
		}
	}()
	if err := ioctl(f.Fd(), uiSetEvBit, evKey); err != nil {
		return nil, err
	}
	if err := ioctl(f.Fd(), uiSetEvBit, evRel); err != nil {
		return nil, err
	}
	for _, key := range allEnabledKeys() {
		if err := ioctl(f.Fd(), uiSetKeyBit, uintptr(key)); err != nil {
			return nil, fmt.Errorf("enable key %d: %w", key, err)
		}
	}
	for _, axis := range []int{relX, relY, relWheel} {
		if err := ioctl(f.Fd(), uiSetRelBit, uintptr(axis)); err != nil {
			return nil, err
		}
	}
	setup := uinputSetup{Bustype: 3, Vendor: 0xF07A, Product: 0x0001, Version: 1}
	copy(setup.Name[:], "TapTether Virtual Keyboard and Mouse")
	if err := ioctl(f.Fd(), uiDevSetup, uintptr(unsafe.Pointer(&setup))); err != nil {
		return nil, fmt.Errorf("uinput setup: %w", err)
	}
	if err := ioctl(f.Fd(), uiDevCreate, 0); err != nil {
		return nil, fmt.Errorf("uinput create: %w", err)
	}
	// Allow udev/libinput to enumerate the new virtual input device.
	time.Sleep(250 * time.Millisecond)
	success = true
	return device, nil
}

func (d *virtualDevice) emit(typ, code uint16, value int32) error {
	// 64-bit Linux struct input_event: timeval{int64,int64}, u16,u16,i32.
	var buf [24]byte
	binary.LittleEndian.PutUint16(buf[16:18], typ)
	binary.LittleEndian.PutUint16(buf[18:20], code)
	binary.LittleEndian.PutUint32(buf[20:24], uint32(value))
	_, err := d.f.Write(buf[:])
	return err
}
func (d *virtualDevice) sync() error { return d.emit(evSyn, synReport, 0) }
func (d *virtualDevice) press(code int) error {
	if err := d.emit(evKey, uint16(code), 1); err != nil {
		return err
	}
	if err := d.sync(); err != nil {
		return err
	}
	if err := d.emit(evKey, uint16(code), 0); err != nil {
		return err
	}
	return d.sync()
}
func (d *virtualDevice) chord(keys []int) (err error) {
	// Always release held keys even on write failure.
	defer func() {
		for i := len(keys) - 1; i >= 0; i-- {
			_ = d.emit(evKey, uint16(keys[i]), 0)
		}
		_ = d.sync()
	}()
	for _, k := range keys {
		if err = d.emit(evKey, uint16(k), 1); err != nil {
			return err
		}
	}
	return d.sync()
}
func (d *virtualDevice) send(e Event) error {
	switch e.Type {
	case "ping":
		return nil
	case "move":
		if err := d.emit(evRel, relX, int32(e.DX)); err != nil {
			return err
		}
		if err := d.emit(evRel, relY, int32(e.DY)); err != nil {
			return err
		}
		return d.sync()
	case "scroll":
		if e.DY == 0 {
			return nil
		}
		ticks := e.DY
		if ticks > 8 {
			ticks = 8
		}
		if ticks < -8 {
			ticks = -8
		}
		return d.emitAndSync(evRel, relWheel, int32(-ticks))
	case "click":
		key := btnLeft
		if e.Button == "right" {
			key = btnRight
		}
		if err := d.press(key); err != nil {
			return err
		}
		if e.Button == "double" {
			return d.press(key)
		}
		return nil
	case "key":
		keys, err := parseChord(e.Key)
		if err != nil {
			return err
		}
		return d.chord(keys)
	case "text":
		if !utf8.ValidString(e.Text) {
			return errors.New("invalid UTF-8 text")
		}
		for _, r := range e.Text {
			code, shifted, ok := asciiKey(r)
			if !ok {
				return fmt.Errorf("Wayland text input currently supports ASCII; unsupported character %q", r)
			}
			if shifted {
				if err := d.chord([]int{keyLeftShift, code}); err != nil {
					return err
				}
			} else if err := d.press(code); err != nil {
				return err
			}
		}
		return nil
	default:
		return fmt.Errorf("unknown input type %q", e.Type)
	}
}
func (d *virtualDevice) emitAndSync(typ, code uint16, val int32) error {
	if err := d.emit(typ, code, val); err != nil {
		return err
	}
	return d.sync()
}

var namedKeys = map[string]int{
	"escape": 1, "esc": 1, "tab": 15, "return": 28, "enter": 28, "backspace": 14,
	"up": 103, "down": 108, "left": 105, "right": 106, "space": 57, "delete": 111,
	"ctrl": keyLeftCtrl, "control": keyLeftCtrl, "alt": keyLeftAlt, "shift": keyLeftShift, "super": keyLeftMeta, "meta": keyLeftMeta,
	"xf86audioraisevolume": keyVolumeUp, "xf86audiolowervolume": keyVolumeDown, "xf86audiomute": keyMute,
}
var asciiCodes = map[rune]int{
	'1': 2, '2': 3, '3': 4, '4': 5, '5': 6, '6': 7, '7': 8, '8': 9, '9': 10, '0': 11,
	'-': 12, '=': 13, '[': 26, ']': 27, ';': 39, '\'': 40, '`': 41, '\\': 43, ',': 51, '.': 52, '/': 53,
	'q': 16, 'w': 17, 'e': 18, 'r': 19, 't': 20, 'y': 21, 'u': 22, 'i': 23, 'o': 24, 'p': 25,
	'a': 30, 's': 31, 'd': 32, 'f': 33, 'g': 34, 'h': 35, 'j': 36, 'k': 37, 'l': 38,
	'z': 44, 'x': 45, 'c': 46, 'v': 47, 'b': 48, 'n': 49, 'm': 50,
	' ': 57, '\t': 15, '\n': 28,
}
var shiftedSymbols = map[rune]rune{
	'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7', '*': '8', '(': '9', ')': '0',
	'_': '-', '+': '=', '{': '[', '}': ']', ':': ';', '"': '\'', '~': '`', '|': '\\', '<': ',', '>': '.', '?': '/',
}

func asciiKey(r rune) (int, bool, bool) {
	if r >= 'A' && r <= 'Z' {
		return asciiCodes[r+('a'-'A')], true, true
	}
	if val, ok := asciiCodes[r]; ok {
		return val, false, true
	}
	if raw, ok := shiftedSymbols[r]; ok {
		return asciiCodes[raw], true, true
	}
	return 0, false, false
}
func parseChord(raw string) ([]int, error) {
	parts := strings.Split(strings.ToLower(strings.TrimSpace(raw)), "+")
	if len(parts) > 4 {
		return nil, errors.New("key combination too long")
	}
	result := make([]int, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if val, ok := namedKeys[p]; ok {
			result = append(result, val)
			continue
		}
		if len(p) == 1 {
			if val, ok := asciiCodes[rune(p[0])]; ok {
				result = append(result, val)
				continue
			}
		}
		return nil, fmt.Errorf("unsupported key: %q", p)
	}
	return result, nil
}
func allEnabledKeys() []int {
	seen := map[int]bool{}
	for _, code := range namedKeys {
		seen[code] = true
	}
	for _, code := range asciiCodes {
		seen[code] = true
	}
	seen[btnLeft] = true
	seen[btnRight] = true
	keys := make([]int, 0, len(seen))
	for key := range seen {
		keys = append(keys, key)
	}
	return keys
}

func uinputSetupSize() uintptr { return unsafe.Sizeof(uinputSetup{}) }
TT_UINPUT_NATIVE

write_new agent/internal/input/uinput_linux_test.go <<'TT_UINPUT_TEST'
//go:build linux

package input

import "testing"

func TestASCIIKeyMap(t *testing.T) {
	cases := []struct {
		ch    rune
		code  int
		shift bool
		ok    bool
	}{
		{'a', 30, false, true}, {'A', 30, true, true}, {'1', 2, false, true}, {'!', 2, true, true},
		{' ', 57, false, true}, {'\n', 28, false, true}, {'?', 53, true, true}, {'é', 0, false, false},
	}
	for _, tt := range cases {
		code, shift, ok := asciiKey(tt.ch)
		if code != tt.code || shift != tt.shift || ok != tt.ok {
			t.Errorf("asciiKey(%q)=(%d,%t,%t)", tt.ch, code, shift, ok)
		}
	}
}
func TestKeyChords(t *testing.T) {
	tests := []struct {
		input string
		want  []int
	}{
		{"ctrl+c", []int{29, 46}}, {"alt+Tab", []int{56, 15}},
		{"XF86AudioRaiseVolume", []int{115}}, {"XF86AudioLowerVolume", []int{114}},
		{"XF86AudioMute", []int{113}},
	}
	for _, tt := range tests {
		got, err := parseChord(tt.input)
		if err != nil || len(got) != len(tt.want) {
			t.Errorf("parseChord(%q): %v %v", tt.input, got, err)
			continue
		}
		for i, k := range got {
			if k != tt.want[i] {
				t.Errorf("parseChord(%q) [%d]=%d, want %d", tt.input, i, k, tt.want[i])
			}
		}
	}
	for _, bad := range []string{"unknown", "ctrl+", "ctrl+alt+shift+meta+x"} {
		if _, err := parseChord(bad); err == nil {
			t.Errorf("wanted error for %q", bad)
		}
	}
}
func TestVirtualDeviceLayout(t *testing.T) {
	// CI has no physical /dev/uinput. Validate ioctl ABI via sizeof in build test.
	if got := uinputSetupSize(); got != 92 {
		t.Fatalf("uinput_setup size=%d want=92", got)
	}
}
TT_UINPUT_TEST

write_new bin/5-tt-remote-install-ubuntu.sh <<'TT_UBUNTU_REMOTE'
#!/usr/bin/env bash
# Build and install current TapTether agent over SSH; service starts and prints pairing values.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:-sandip@192.168.68.87}"
[[ "$HOST" =~ ^[a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+$ ]] || {
  echo 'Usage: ./bin/5-tt-remote-install-ubuntu.sh user@host' >&2; exit 2;
}
version="$(cat "$ROOT/VERSION")"
"$ROOT/bin/2b-tt-ubuntu.sh"
arch="$(ssh "$HOST" 'dpkg --print-architecture')"
[[ "$arch" == amd64 || "$arch" == arm64 ]] || {
  echo "Unsupported remote Ubuntu architecture: $arch" >&2; exit 1;
}
package="$ROOT/dist/ubuntu/taptether-agent_${version}_${arch}.deb"
[[ -s "$package" ]] || { echo "Missing installer: $package" >&2; exit 1; }
stage="$(ssh "$HOST" 'mktemp -d /tmp/taptether-install.XXXXXXXX')"
[[ "$stage" =~ ^/tmp/taptether-install\.[a-zA-Z0-9]+$ ]] || {
  echo "Invalid remote temp directory: $stage" >&2; exit 1;
}
trap 'ssh "$HOST" "rm -rf '\''$stage'\''" >/dev/null 2>&1 || true' EXIT
scp "$package" "$ROOT/bin/4-ubuntu-desktop-setup.sh" "$HOST:$stage/"
ssh -tt "$HOST" "set -e; dpkg-deb --info '$stage/$(basename "$package")' >/dev/null; sudo apt install -y '$stage/$(basename "$package")'; bash '$stage/4-ubuntu-desktop-setup.sh' install"
echo "TapTether $version deployed and enabled on $HOST. The installer above displayed PRIVATE pairing values."
TT_UBUNTU_REMOTE

write_new WAYLAND.md <<'TT_WAYLAND_DOC'
# TapTether 0.3 — GNOME Wayland / Ubuntu 26.04

TapTether on Linux now supports native `/dev/uinput` virtual devices. This works with GNOME Wayland and X11 without the RemoteDesktop portal used by apps that call XTEST. It does not fix unrelated dialogs from Steam Input or other apps. The hardware-style keyboard/media events may work on the lock screen; keep your pairing token private and restrict port 48321 to trusted LAN devices.

## Install/update from Mac

Run `./bin/5-tt-remote-install-ubuntu.sh sandip@192.168.68.87` from the TapTether repository. The script builds Linux amd64 and arm64 installers, copies the detected architecture over SSH, installs it, adds your Ubuntu user to the restricted `taptether` group, configures `/dev/uinput`, and creates the per-user desktop autostart and dock launcher.

**First-time security setup requires sudo.** Log out of the Ubuntu graphical desktop and log back in (or reboot) to apply group membership. A running SSH shell cannot acquire newly added supplementary groups without a new login. It does not run the agent as root. `taptether` group membership grants access to a powerful virtual keyboard/mouse interface; only grant it to trusted users.

## SSH commands

- `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl status'`
- `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl start'`
- `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl restart'`
- `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl permissions'`
- `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl pairing'` (PRIVATE TOKEN — never share in a chat)
- `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl logs'`

The service starts on graphical desktop login through the user's autostart entry, not at the graphical login screen. The Ubuntu dock shortcut launches it on demand. No cloud component is required.

## Limitations

- Keyboard layout for hardware text synthesis is US-English ASCII only in 0.3. Unicode text input needs a future method. Physical host keyboard layouts may change mappings.
- Go builds compile and unit tests run on Linux; end-to-end uinput and libinput integration must be tested on a real GNOME Wayland desktop.
- Input injection is privileged by Linux device permissions; do not expose `/dev/uinput` to all users, run this service as root, or expose port 48321 publicly.
- Volume controls synthesize `KEY_VOLUMEUP`, `KEY_VOLUMEDOWN`, and `KEY_MUTE` media key events. Desktop sound settings and the active audio sink determine actual volume effects.
- Existing iOS/Android apps must be rebuilt to show the new volume buttons. Pairing credentials persist on Ubuntu unless its user config directory is removed.
- If GNOME keeps showing Remote Desktop prompts even when TapTether is not involved, investigate Steam Input or other XWayland/XTEST clients separately.
TT_WAYLAND_DOC

# iOS requires Local Network usage privacy text. The generated app must prompt for permission.
if [[ -f app/ios/Runner/Info.plist ]]; then
  if ! grep -q NSLocalNetworkUsageDescription app/ios/Runner/Info.plist; then
    python3 - <<'TT_PLIST'
from pathlib import Path
p=Path('app/ios/Runner/Info.plist')
s=p.read_text()
s=s.replace('</dict>', '\t<key>NSLocalNetworkUsageDescription</key>\n\t<string>TapTether connects only to devices on your local network.</string>\n</dict>',1)
p.write_text(s)
TT_PLIST
  fi
fi
# Android requires network permission.
if [[ -f app/android/app/src/main/AndroidManifest.xml ]]; then
  if ! grep -q android.permission.INTERNET app/android/app/src/main/AndroidManifest.xml; then
    python3 - <<'TT_MANIFEST'
from pathlib import Path
p=Path('app/android/app/src/main/AndroidManifest.xml')
s=p.read_text()
s=s.replace('<application', '<uses-permission android:name="android.permission.INTERNET" />\n    <application',1)
p.write_text(s)
TT_MANIFEST
  fi
fi

chmod +x bin/*.sh
if command -v go >/dev/null 2>&1; then
  (cd agent && gofmt -w ./cmd/taptether-agent/*.go ./internal/input/*.go && go test ./...)
fi
if command -v flutter >/dev/null 2>&1; then
  (cd app && flutter pub get)
fi

touch .taptether-bootstrapped
printf '\nBootstrap completed. Next:\n  ./bin/0-doctor.sh\n  ./bin/4-test.sh\n  ./bin/3-push-project.sh\n'
printf 'Build: ./bin/2a-tt-apk.sh | ./bin/2a-tt-ipa.sh | ./bin/2b-tt-ubuntu.sh\n'
printf 'Version + GitHub push: ./bin/1-bump-version.sh patch\n'
