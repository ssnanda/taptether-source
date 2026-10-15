# TapTether Windows user tray. UI-only, no admin privilege or network calls.
# A separate, SHA-256-verifying local updater owns agent replacement.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$folder = Join-Path $env:LOCALAPPDATA 'TapTether'
$agentExe = Join-Path $folder 'TapTetherAgent.exe'
$updateHelper = Join-Path $folder 'Update-TapTether.ps1'
$versionPath = Join-Path $folder 'version.txt'
$disabledShutdown = Join-Path (Join-Path $env:APPDATA 'taptether') 'remote-shutdown-disabled'
$mutexName = 'Local\TapTetherTray-' + ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -replace '[^a-zA-Z0-9-]', '_')
$mutex = [System.Threading.Mutex]::new($false, $mutexName)
$acquired = $false
try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (!$acquired) { $mutex.Dispose(); exit 0 }

$script:updating = $false
$script:updateProcess = $null
$script:tray = [System.Windows.Forms.NotifyIcon]::new()
$script:tray.Icon = [System.Drawing.SystemIcons]::Application
$script:tray.Text = 'TapTether Agent'
$menu = [System.Windows.Forms.ContextMenuStrip]::new()
$versionItem = $menu.Items.Add('TapTether Agent')
$versionItem.Enabled = $false
$statusItem = $menu.Items.Add('Status: Checking')
$statusItem.Enabled = $false
[void]$menu.Items.Add('-')

$startItem = $menu.Items.Add('Start Agent')
$startItem.Add_Click({
    if (Test-Path $agentExe) {
        Start-Process -FilePath $agentExe -WindowStyle Hidden
    }
})
$stopItem = $menu.Items.Add('Stop Agent')
$stopItem.Add_Click({
    Get-CimInstance Win32_Process -Filter "Name='TapTetherAgent.exe'" |
        Where-Object { $_.ExecutablePath -eq $agentExe } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
})
$restartItem = $menu.Items.Add('Restart Agent')
$restartItem.Add_Click({
    Get-CimInstance Win32_Process -Filter "Name='TapTetherAgent.exe'" |
        Where-Object { $_.ExecutablePath -eq $agentExe } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    if (Test-Path $agentExe) {
        Start-Process -FilePath $agentExe -WindowStyle Hidden
    }
})
[void]$menu.Items.Add('-')
$updateItem = $menu.Items.Add('Update Agent...')
$updateItem.Add_Click({
    if ($script:updating) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        'Check for the latest verified TapTether agent release and install it if newer? The agent may briefly disconnect; pairing is preserved.',
        'Update TapTether Agent',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    if (!(Test-Path $updateHelper)) {
        [System.Windows.Forms.MessageBox]::Show(
            'The installed agent predates one-click updates. Run the downloaded TapTether installer once.',
            'Updater unavailable') | Out-Null
        return
    }
    try {
        # Run in a separate process so this tray stays responsive and its
        # current process survives when the agent executable is replaced.
        # Do not surface updater stdout: legacy builds printed private tokens.
        $arguments = '-NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $updateHelper + '"'
        $script:updateProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $script:updating = $true
        $updateItem.Enabled = $false
        $updateItem.Text = 'Updating...'
        $script:tray.ShowBalloonTip(2500, 'TapTether',
            'Checking and installing the verified agent release.',
            [System.Windows.Forms.ToolTipIcon]::Info)
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            'Could not launch the trusted update helper.',
            'TapTether Update', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})
$shutdownItem = [System.Windows.Forms.ToolStripMenuItem]::new('Allow remote shutdown')
$shutdownItem.CheckOnClick = $true
$shutdownItem.Checked = !(Test-Path $disabledShutdown)
$shutdownItem.Add_CheckedChanged({
    try {
        if ($shutdownItem.Checked) {
            Remove-Item $disabledShutdown -Force -ErrorAction SilentlyContinue
        } else {
            New-Item -ItemType Directory -Path (Split-Path $disabledShutdown) -Force | Out-Null
            New-Item -ItemType File -Path $disabledShutdown -Force | Out-Null
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            'Unable to change the local shutdown setting.', 'TapTether') | Out-Null
    }
})
[void]$menu.Items.Add($shutdownItem)
[void]$menu.Items.Add('-')
$pairingItem = $menu.Items.Add('Show pairing details...')
$pairingItem.Add_Click({
    $cmd = Join-Path $folder 'Show-Pairing.cmd'
    if (Test-Path $cmd) { Start-Process -FilePath $cmd }
})
$quitItem = $menu.Items.Add('Quit tray (agent stays running)')
$quitItem.Add_Click({ [System.Windows.Forms.Application]::Exit() })
$script:tray.ContextMenuStrip = $menu
$script:tray.Visible = $true

$timer = [System.Windows.Forms.Timer]::new()
$timer.Interval = 3000
$timer.Add_Tick({
    $ver = 'unknown'
    try {
        if (Test-Path $versionPath) {
            $ver = (Get-Content $versionPath -Raw -ErrorAction Stop).Trim()
        }
    } catch {}
    $versionItem.Text = 'TapTether Agent v' + $ver
    $statusItem.Text = if (Get-Process -Name TapTetherAgent -ErrorAction SilentlyContinue) {
        'Status: Running'
    } else { 'Status: Stopped' }
    $shutdownItem.Checked = !(Test-Path $disabledShutdown)

    if ($script:updating -and $null -ne $script:updateProcess) {
        $script:updateProcess.Refresh()
        if ($script:updateProcess.HasExited) {
            $success = $script:updateProcess.ExitCode -eq 0
            $script:updateProcess.Dispose()
            $script:updateProcess = $null
            $script:updating = $false
            $updateItem.Text = 'Update Agent...'
            $updateItem.Enabled = $true
            $message = if ($success) {
                'Update complete. Current agent version: ' + $ver
            } else {
                'Update failed. Your previous agent remains available.'
            }
            $script:tray.ShowBalloonTip(6000,
                'TapTether Agent', $message,
                $(if ($success) { [System.Windows.Forms.ToolTipIcon]::Info }
                  else { [System.Windows.Forms.ToolTipIcon]::Warning }))
        }
    }
})
$timer.Start()
try {
    [System.Windows.Forms.Application]::Run()
} finally {
    $timer.Stop()
    $timer.Dispose()
    $script:tray.Visible = $false
    $script:tray.Dispose()
    $menu.Dispose()
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
