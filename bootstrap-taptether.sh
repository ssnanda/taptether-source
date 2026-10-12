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
0.1.0+1
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
version: 0.1.0+1
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

// MVP backend: xdotool on an X11 desktop session. Wayland needs a separate backend.
func Send(e Event) error {
 if e.Type == "ping" { return nil }
 if os.Getenv("DISPLAY") == "" { return fmt.Errorf("DISPLAY not set: start the agent inside an X11 desktop session") }
 if _, err := exec.LookPath("xdotool"); err != nil { return fmt.Errorf("install xdotool: sudo apt install xdotool") }
 var args []string
 switch e.Type {
 case "move": args = []string{"mousemove_relative", "--", strconv.Itoa(e.DX), strconv.Itoa(e.DY)}
 case "scroll":
  if e.DY == 0 {return nil}
  button := "4"; if e.DY > 0 {button = "5"}
  ticks := e.DY; if ticks < 0 {ticks = -ticks}; if ticks > 8 {ticks = 8}
  args = []string{"click", "--repeat", strconv.Itoa(ticks), "--delay", "20", button}
 case "click":
  switch e.Button {
  case "left": args = []string{"click", "1"}
  case "right": args = []string{"click", "3"}
  case "double": args = []string{"click", "--repeat", "2", "--delay", "100", "1"}
  }
 case "key":
  key := strings.TrimSpace(e.Key)
  for _, ch := range key {
   if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '+' || ch == '_' || ch == '-') {
    return fmt.Errorf("unsupported key combination")
   }
  }
  args = []string{"key", "--clearmodifiers", key}
 case "text": args = []string{"type", "--clearmodifiers", "--delay", "0", "--", e.Text}
 default: return fmt.Errorf("unsupported command type")
 }
 ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
 defer cancel()
 output, err := exec.CommandContext(ctx, "xdotool", args...).CombinedOutput()
 if err != nil {return fmt.Errorf("xdotool failed: %v (%s)", err, strings.TrimSpace(string(output)))}
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
 dir, err := os.UserConfigDir(); fatalIf(err)
 dir = filepath.Join(dir,"taptether")
 fatalIf(os.MkdirAll(dir,0700))
 certFile, keyFile, tokenFile := filepath.Join(dir,"server.crt"), filepath.Join(dir,"server.key"),filepath.Join(dir,"pairing.token")
 if err := ensureCertificate(certFile,keyFile); err != nil {log.Fatal(err)}
 token,err := ensureToken(tokenFile);fatalIf(err)
 certPEM,err := os.ReadFile(certFile);fatalIf(err)
 block,_ := pem.Decode(certPEM);if block==nil {log.Fatal("invalid local certificate")}
 digest := sha256.Sum256(block.Bytes)
 fmt.Printf("\nTapTether Agent %s — LAN-only remote input\n",version)
 fmt.Println("Pairing token (keep private):",token)
 fmt.Println("TLS SHA-256 fingerprint:",strings.ToUpper(hex.EncodeToString(digest[:])))
 fmt.Println("Port: 48321 (HTTPS)")
 for _,a := range privateAddresses() {fmt.Printf("iPhone host: %s\n",a)}
 fmt.Println("Controls available on Linux X11 with xdotool. Wayland and Windows/macOS input are not yet implemented.")
 fmt.Println("No telemetry or outgoing network connections are implemented. Restrict inbound port 48321 to trusted LAN devices.")
 mux:=http.NewServeMux()
 var mu sync.Mutex
 mux.HandleFunc("/api/control",func(w http.ResponseWriter,r *http.Request){
  w.Header().Set("Cache-Control","no-store")
  if r.Method != http.MethodPost {http.Error(w,"POST required",http.StatusMethodNotAllowed);return}
  if r.TLS==nil || !privateRemote(r.RemoteAddr) {http.Error(w,"LAN TLS required",http.StatusForbidden);return}
  got:=strings.TrimPrefix(r.Header.Get("Authorization"),"Bearer ")
  if subtle.ConstantTimeCompare([]byte(got),[]byte(token))!=1 {http.Error(w,"not paired",http.StatusUnauthorized);return}
  body:=http.MaxBytesReader(w,r.Body,4096)
  defer body.Close()
  decoder:=json.NewDecoder(body);decoder.DisallowUnknownFields()
  var cmd input.Event
  if err:=decoder.Decode(&cmd);err!=nil {http.Error(w,"invalid JSON command",http.StatusBadRequest);return}
  var extra any
  if err:=decoder.Decode(&extra);err!=io.EOF {http.Error(w,"unexpected trailing JSON",http.StatusBadRequest);return}
  if err:=cmd.Validate();err!=nil {http.Error(w,err.Error(),http.StatusBadRequest);return}
  mu.Lock()
  err:=input.Send(cmd)
  mu.Unlock()
  if err!=nil {http.Error(w,err.Error(),http.StatusUnprocessableEntity);return}
  w.WriteHeader(http.StatusNoContent)
 })
 server:=&http.Server{Addr:*addr,Handler:mux,ReadHeaderTimeout:5*time.Second,ReadTimeout:8*time.Second,WriteTimeout:8*time.Second,IdleTimeout:30*time.Second,MaxHeaderBytes:4096}
 log.Fatal(server.ListenAndServeTLS(certFile,keyFile))
}

func fatalIf(err error){if err!=nil {log.Fatal(err)}}
func privateRemote(remote string)bool{
 host,_,err:=net.SplitHostPort(remote);if err!=nil{return false}
 ip:=net.ParseIP(host);return ip!=nil && (ip.IsPrivate()||ip.IsLoopback()||ip.IsLinkLocalUnicast())
}
func privateAddresses()[]string{
 ifaces,err:=net.InterfaceAddrs();if err!=nil{return nil}
 var result []string
 for _,a:=range ifaces{
  network,ok:=a.(*net.IPNet);if !ok {continue}
  ip:=network.IP.To4();if ip!=nil && ip.IsPrivate(){result=append(result,ip.String())}
 }
 return result
}
func ensureToken(path string)(string,error){
 data,err:=os.ReadFile(path)
 if err==nil {if len(strings.TrimSpace(string(data)))>=32 {return strings.TrimSpace(string(data)),nil};return "",errors.New("existing pairing token invalid")}
 if !os.IsNotExist(err){return "",err}
 b:=make([]byte,24);if _,err=rand.Read(b);err!=nil{return "",err}
 val:=hex.EncodeToString(b)
 if err=os.WriteFile(path,[]byte(val+"\n"),0600);err!=nil{return "",err}
 return val,nil
}
func ensureCertificate(crt,key string)error{
 _,ec:=os.Stat(crt);_,ek:=os.Stat(key)
 if ec==nil && ek==nil{return nil}
 if !os.IsNotExist(ec)||!os.IsNotExist(ek){return errors.New("certificate/key incomplete or unreadable; repair manually, never silently replace identity")}
 priv,err:=ecdsa.GenerateKey(elliptic.P256(),rand.Reader);if err!=nil{return err}
 serial,err:=rand.Int(rand.Reader,new(big.Int).Lsh(big.NewInt(1),128));if err!=nil{return err}
 tmpl:=x509.Certificate{SerialNumber:serial,Subject:pkixName(),NotBefore:time.Now().Add(-time.Hour),NotAfter:time.Now().AddDate(5,0,0),KeyUsage:x509.KeyUsageDigitalSignature,ExtKeyUsage:[]x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},BasicConstraintsValid:true,DNSNames:[]string{"localhost"}}
 der,err:=x509.CreateCertificate(rand.Reader,&tmpl,&tmpl,&priv.PublicKey,priv);if err!=nil{return err}
 pemKey,err:=x509.MarshalPKCS8PrivateKey(priv);if err!=nil{return err}
 if err=os.WriteFile(key,pem.EncodeToMemory(&pem.Block{Type:"PRIVATE KEY",Bytes:pemKey}),0600);err!=nil{return err}
 if err=os.WriteFile(crt,pem.EncodeToMemory(&pem.Block{Type:"CERTIFICATE",Bytes:der}),0600);err!=nil{return err}
 return nil
}
// A CN is not required for cert pinning; the certificate is never publicly trusted.
func pkixName() (name struct{CommonName string}) {name.CommonName="TapTether Local Agent";return name}
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
    ).encode('ascii') + bytes((96, 10))
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
        'Description: TapTether local-first keyboard and trackpad agent\n'
        ' A local HTTPS remote input agent for an X11 Ubuntu desktop.\n'
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

Requires git, Go 1.22+, Flutter SDK, Android SDK for APK, and Xcode/macOS for IPA. On Ubuntu, install `xdotool` and use an **X11/Xorg desktop session**, not Wayland, for input injection in this first version.

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
| `./bin/2d-tt-all.sh` | Build all available Go targets, Ubuntu installers and available mobile targets |

## Try Ubuntu remote control

1. Copy repository/build agent to an Ubuntu computer running a graphical X11 desktop, and `sudo apt install xdotool`.
2. On Ubuntu, run `./bin/3-run-agent.sh` or the built `TapTetherAgent-linux-amd64-*` binary.
3. The agent prints its *private LAN IP*, secret pairing token, and TLS certificate fingerprint.
4. Install/run TapTether on your iPhone or Android phone, enter these three values, and connect using local Wi-Fi.
5. Keep the token secret. Firewall TCP port 48321 to trusted devices on the LAN.

The agent stores its identity and token in the current OS user's configuration directory (`~/.config/taptether` on most Linux desktops), **not the git repository**. There are no analytics, cloud endpoints, update pings, or arbitrary remote shell commands. TLS encryption and manual certificate fingerprint pinning are mandatory. Pairing values are kept only in memory by this prototype; reenter after relaunch.

## Important scope notes

- **Working MVP path:** iOS/Android UI ⇄ authenticated HTTPS local agent ⇄ Ubuntu **X11 + xdotool** keyboard/mouse.
- **Wayland**, Windows/macOS native input, device auto-discovery, clipboard sync, TV remote adapters, and polished TV-specific app builds are future work. Windows/macOS binaries compile but do **not** provide remote input yet.
- The input backend has not been tested on physical hardware. Review/verify on a private LAN before relying on it.
- An unsigned IPA is *not* independently installable; use AltStore or valid code signing. A signed IPA requires configured Xcode signing.
- TV operating systems can have compatibility or background-service restrictions; see `tv/README.md`.
- Build-time dependency downloads (Flutter/Go toolchains) are distinct from runtime communications. This app intentionally has no runtime cloud integration.

## GitHub safety

The bootstrap creates the SSH remote `git@github.com:ssnanda/taptether.com.git` unless an allowed matching origin is already present. It does **not** push automatically. `1-bump-version.sh` commits **only the version files** and pushes to `main`; run `3-push-project.sh` for other source changes. It refuses to push to a different repository. On the **first** commit only, `1-bump-version.sh` stages the initial scaffold so the new private repository is usable.
TT_README

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
