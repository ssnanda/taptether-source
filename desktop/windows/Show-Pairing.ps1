# Pairing details are displayed only after a local user action.
$ErrorActionPreference = 'Stop'
$config = Join-Path $env:APPDATA 'taptether'
$tokenFile = Join-Path $config 'pairing.token'
$certFile = Join-Path $config 'server.crt'
if (!(Test-Path $tokenFile) -or !(Test-Path $certFile)) {
    throw 'Agent is not ready yet. Run Install-TapTether.cmd first.'
}
$token = (Get-Content $tokenFile -Raw).Trim()
$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certFile)
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $digest = [BitConverter]::ToString($sha.ComputeHash($cert.RawData)).Replace('-', '')
} finally {
    $sha.Dispose()
    $cert.Dispose()
}
$addresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' } |
    Select-Object -ExpandProperty IPAddress
Write-Host 'TapTether Windows pairing details — PRIVATE' -ForegroundColor Cyan
Write-Host ('LAN IP: ' + ($addresses -join ', '))
Write-Host 'Port: 48321'
Write-Host ('Pairing token: ' + $token)
Write-Host ('TLS SHA-256 fingerprint: ' + $digest)
Write-Host 'Only enter this information in your own TapTether phone app.'
