# Local owner setting only. It never exposes pairing credentials or opens
# firewall rules. The agent checks this marker on every shutdown request.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$folder = Join-Path $env:APPDATA 'taptether'
$disabled = Join-Path $folder 'remote-shutdown-disabled'
$form = New-Object System.Windows.Forms.Form
$form.Text = 'TapTether Remote Shutdown'
$form.ClientSize = New-Object System.Drawing.Size(410, 174)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.StartPosition = 'CenterScreen'
$checkbox = New-Object System.Windows.Forms.CheckBox
$checkbox.Text = 'Allow remote shutdown'
$checkbox.Checked = !(Test-Path $disabled)
$checkbox.AutoSize = $true
$checkbox.Location = New-Object System.Drawing.Point(24, 22)
$form.Controls.Add($checkbox)
$detail = New-Object System.Windows.Forms.Label
$detail.Text = 'Only a paired phone can request shutdown. The phone asks for confirmation before sending it.'
$detail.Location = New-Object System.Drawing.Point(24, 58)
$detail.Size = New-Object System.Drawing.Size(355, 52)
$form.Controls.Add($detail)
$save = New-Object System.Windows.Forms.Button
$save.Text = 'Save'
$save.Location = New-Object System.Drawing.Point(293, 121)
$save.DialogResult = [System.Windows.Forms.DialogResult]::OK
$form.Controls.Add($save)
$form.AcceptButton = $save
try {
    if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        if ($checkbox.Checked) {
            Remove-Item $disabled -Force -ErrorAction SilentlyContinue
        } else {
            New-Item -ItemType File -Path $disabled -Force | Out-Null
        }
    }
} finally {
    $form.Dispose()
}
