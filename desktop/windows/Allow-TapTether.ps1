param([Parameter(Mandatory=$true)][string]$AgentPath)
$ErrorActionPreference = 'Stop'
if (!(Test-Path $AgentPath -PathType Leaf)) {
    throw 'TapTether executable is missing.'
}
Get-NetFirewallRule -DisplayName 'TapTether Private LAN*' -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'TapTether Private LAN Control' -Direction Inbound -Action Allow -Profile Private -Protocol TCP -LocalPort 48321 -Program $AgentPath | Out-Null
New-NetFirewallRule -DisplayName 'TapTether Private LAN Discovery' -Direction Inbound -Action Allow -Profile Private -Protocol UDP -LocalPort 48322 -Program $AgentPath | Out-Null
Write-Host 'Private-network firewall rules installed.'
