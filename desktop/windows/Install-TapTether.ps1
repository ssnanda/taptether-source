# TapTether Windows local installation; no SSH, no remote credentials.
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'TapTetherAgent.exe'
$destinationDir = Join-Path $env:LOCALAPPDATA 'TapTether'
$destination = Join-Path $destinationDir 'TapTetherAgent.exe'
if (!(Test-Path $source -PathType Leaf)) {
    throw 'TapTetherAgent.exe was not found in the extracted ZIP.'
}
New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
# Stop only the current user's agent at its known install location.
Get-CimInstance Win32_Process -Filter "Name='TapTetherAgent.exe'" |
    Where-Object { $_.ExecutablePath -eq $destination } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 400
Copy-Item $source $destination -Force
foreach ($file in @('Update-TapTether.ps1', 'Show-Pairing.ps1',
        'Install-TapTether.ps1', 'Allow-TapTether.ps1',
        'Show-Pairing.cmd', 'Install-TapTether.cmd',
        'Configure-Shutdown.ps1', 'Configure-Shutdown.cmd',
        'TapTetherTray.ps1',
        'TapTether.ico',
        'README-Windows.txt', 'version.txt')) {
    Copy-Item (Join-Path $PSScriptRoot $file) (Join-Path $destinationDir $file) -Force
}
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
New-ItemProperty -Path $runKey -Name 'TapTetherAgent' -Value ('"' + $destination + '"') -PropertyType String -Force | Out-Null
# Native notification-area control: no console window and no admin account.
$trayScript = Join-Path $destinationDir 'TapTetherTray.ps1'
$trayArgs = '-NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $trayScript + '"'
$trayStartup = '"powershell.exe" ' + $trayArgs
New-ItemProperty -Path $runKey -Name 'TapTetherTray' -Value $trayStartup -PropertyType String -Force | Out-Null
Start-Process -FilePath 'powershell.exe' -ArgumentList $trayArgs -WindowStyle Hidden
Start-Process -FilePath $destination -WindowStyle Hidden
Start-Sleep -Seconds 2
Write-Host 'TapTether Agent installed for this Windows user.'
Write-Host 'The agent and tray start at sign-in. No Windows SSH server is needed.'
Write-Host 'Run Show-Pairing.cmd to see the private pairing credentials.'
Write-Host 'Windows may require you to allow TapTether through the Private network firewall.'
$firewallScript = Join-Path $PSScriptRoot 'Allow-TapTether.ps1'
if (Test-Path $firewallScript) {
    $choice = Read-Host 'Configure Windows Private firewall rule (UAC approval required)? [Y/n]'
    if ($choice -ne 'n' -and $choice -ne 'N') {
        try {
            $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $firewallScript + '" -AgentPath "' + $destination + '"'
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru
            if ($proc.ExitCode -ne 0) {
                Write-Warning 'Firewall authorization was cancelled or failed.'
            }
        } catch {
            Write-Warning 'Firewall authorization was not completed. Try again as administrator.'
        }
    }
}
