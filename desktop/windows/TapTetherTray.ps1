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
$brandIcon = Join-Path $folder 'TapTether.ico'
if (Test-Path $brandIcon) {
    try {
        $script:tray.Icon = [System.Drawing.Icon]::new($brandIcon)
    } catch { }
}
$script:runningIcon = $script:tray.Icon
$script:tray.Text = 'TapTether Agent'
$menu = [System.Windows.Forms.ContextMenuStrip]::new()
$versionItem = $menu.Items.Add('TapTether Agent')
$versionItem.Enabled = $false
$statusItem = $menu.Items.Add('Status: Checking')
$statusItem.Enabled = $false
[void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

function Get-ManagedAgentProcesses {
    # Never control a different user's process with the same executable name.
    @(Get-CimInstance Win32_Process -Filter "Name='TapTetherAgent.exe'" -ErrorAction Stop |
        Where-Object { $_.ExecutablePath -eq $agentExe })
}

function Stop-ManagedAgent {
    try {
        foreach ($process in (Get-ManagedAgentProcesses)) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        }
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            if ((Get-ManagedAgentProcesses).Count -eq 0) { return $true }
            Start-Sleep -Milliseconds 150
        }
        return $false
    } catch { return $false }
}

function Start-ManagedAgent {
    if (!(Test-Path $agentExe)) {
        [System.Windows.Forms.MessageBox]::Show(
            'TapTether is not installed. Reinstall the Windows agent.',
            'TapTether Agent') | Out-Null
        return
    }
    try {
        if ((Get-ManagedAgentProcesses).Count -eq 0) {
            Start-Process -FilePath $agentExe -WindowStyle Hidden -ErrorAction Stop
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            'TapTether could not start. Open Settings to inspect agent status.',
            'TapTether Agent') | Out-Null
    }
}

$startStopItem = $menu.Items.Add('Start TapTether')
$startStopItem.Add_Click({
    if ((Get-ManagedAgentProcesses).Count -gt 0) {
        if (!(Stop-ManagedAgent)) {
            [System.Windows.Forms.MessageBox]::Show(
                'TapTether could not be stopped.', 'TapTether Agent') | Out-Null
        }
    } else {
        Start-ManagedAgent
    }
})
$pairingItem = $menu.Items.Add('Pair Device')
$pairingItem.Add_Click({
    $cmd = Join-Path $folder 'Show-Pairing.cmd'
    if (Test-Path $cmd) {
        Start-Process -FilePath $cmd
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            'Pairing helper unavailable. Reinstall TapTether.',
            'TapTether Agent') | Out-Null
    }
})
[void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
$updateItem = $menu.Items.Add('Check for Updates...')
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
$settingsItem = [System.Windows.Forms.ToolStripMenuItem]::new('Settings')
$restartItem = $settingsItem.DropDownItems.Add('Restart agent')
$restartItem.Add_Click({
    if (Stop-ManagedAgent) { Start-ManagedAgent } else {
        [System.Windows.Forms.MessageBox]::Show(
            'TapTether could not be restarted.', 'TapTether Agent') | Out-Null
    }
})
$agentStatusItem = $settingsItem.DropDownItems.Add('Agent status')
$agentStatusItem.Add_Click({
    $state = if ((Get-ManagedAgentProcesses).Count -gt 0) { 'Running' } else { 'Stopped' }
    [System.Windows.Forms.MessageBox]::Show(
        ('Agent status: ' + $state + [Environment]::NewLine +
         'Installed version: ' + $versionItem.Text),
        'TapTether Agent') | Out-Null
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
[void]$settingsItem.DropDownItems.Add($shutdownItem)
[void]$menu.Items.Add($settingsItem)
[void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
$quitItem = $menu.Items.Add('Quit TapTether')
$quitItem.Add_Click({
    if (Stop-ManagedAgent) {
        [System.Windows.Forms.Application]::Exit()
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            'TapTether agent is still running. Stop it before quitting.',
            'TapTether Agent') | Out-Null
    }
})
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
    $isRunning = (Get-ManagedAgentProcesses).Count -gt 0
    $statusItem.Text = if ($isRunning) { 'Status: Running' } else { 'Status: Stopped' }
    $startStopItem.Text = if ($isRunning) { 'Stop TapTether' } else { 'Start TapTether' }
    $script:tray.Text = if ($isRunning) { 'TapTether Agent - Running' } else { 'TapTether Agent - Stopped' }
    $script:tray.Icon = if ($isRunning) {
        if (Test-Path $brandIcon) { $script:runningIcon } else { [System.Drawing.SystemIcons]::Application }
    } else { [System.Drawing.SystemIcons]::Warning }
    $shutdownItem.Checked = !(Test-Path $disabledShutdown)

    if ($script:updating -and $null -ne $script:updateProcess) {
        $script:updateProcess.Refresh()
        if ($script:updateProcess.HasExited) {
            $success = $script:updateProcess.ExitCode -eq 0
            $script:updateProcess.Dispose()
            $script:updateProcess = $null
            $script:updating = $false
            $updateItem.Text = 'Check for Updates...'
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
