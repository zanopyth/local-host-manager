Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -Name ProcCwd -Namespace LocalhostManager -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)]
public struct PROCESS_BASIC_INFORMATION {
    public IntPtr ExitStatus;
    public IntPtr PebBaseAddress;
    public IntPtr AffinityMask;
    public IntPtr BasePriority;
    public IntPtr UniqueProcessId;
    public IntPtr InheritedFromUniqueProcessId;
}

[DllImport("ntdll.dll")]
public static extern int NtQueryInformationProcess(IntPtr hProcess, int piClass, ref PROCESS_BASIC_INFORMATION pbi, int cb, out int size);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int dwSize, out int lpNumberOfBytesRead);
"@

# ---------------------------------------------------------------------------
# Recovers the true working directory of an arbitrary running process by
# reading its PEB (ProcessParameters->CurrentDirectory) directly out of its
# memory. Needed because "npm start" processes show up in WMI/CommandLine as
# just `node ...\npm-cli.js start` with no project path in the arguments.
# ---------------------------------------------------------------------------
function Get-ProcessWorkingDirectory {
    param([int]$ProcId)
    try {
        $p = [System.Diagnostics.Process]::GetProcessById($ProcId)
        $hProcess = $p.Handle

        $pbi = New-Object LocalhostManager.ProcCwd+PROCESS_BASIC_INFORMATION
        $size = 0
        $status = [LocalhostManager.ProcCwd]::NtQueryInformationProcess($hProcess, 0, [ref]$pbi, [System.Runtime.InteropServices.Marshal]::SizeOf($pbi), [ref]$size)
        if ($status -ne 0) { return $null }

        $ptrBuf = New-Object byte[] 8
        $read = 0
        [void][LocalhostManager.ProcCwd]::ReadProcessMemory($hProcess, [IntPtr]::Add($pbi.PebBaseAddress, 0x20), $ptrBuf, 8, [ref]$read)
        $processParams = [IntPtr][BitConverter]::ToInt64($ptrBuf, 0)

        $usBuf = New-Object byte[] 16
        [void][LocalhostManager.ProcCwd]::ReadProcessMemory($hProcess, [IntPtr]::Add($processParams, 0x38), $usBuf, 16, [ref]$read)
        $length = [BitConverter]::ToUInt16($usBuf, 0)
        $bufferPtr = [IntPtr][BitConverter]::ToInt64($usBuf, 8)
        if ($length -le 0 -or $length -gt 8192) { return $null }

        $strBuf = New-Object byte[] $length
        [void][LocalhostManager.ProcCwd]::ReadProcessMemory($hProcess, $bufferPtr, $strBuf, $length, [ref]$read)
        return [System.Text.Encoding]::Unicode.GetString($strBuf, 0, $read).TrimEnd('\')
    } catch {
        return $null
    }
}

$script:HistoryDir  = Join-Path $env:LOCALAPPDATA 'LocalhostManager'
$script:HistoryPath = Join-Path $script:HistoryDir 'history.json'

function Load-History {
    if (-not (Test-Path $script:HistoryPath)) { return @{} }
    try {
        $raw = Get-Content $script:HistoryPath -Raw | ConvertFrom-Json
        $h = @{}
        foreach ($prop in $raw.PSObject.Properties) {
            $h[$prop.Name] = @{
                ProjectPath = $prop.Value.ProjectPath
                ProcessName = $prop.Value.ProcessName
            }
        }
        return $h
    } catch { return @{} }
}

function Save-History($history) {
    if (-not (Test-Path $script:HistoryDir)) { New-Item -ItemType Directory -Path $script:HistoryDir -Force | Out-Null }
    $history | ConvertTo-Json | Set-Content -Path $script:HistoryPath -Encoding UTF8
}

$script:SettingsPath = Join-Path $script:HistoryDir 'settings.json'

function Load-Settings {
    $defaults = @{ OnlyNode = $true; RootDir = ''; ShowGroups = $true }
    if (-not (Test-Path $script:SettingsPath)) { return $defaults }
    try {
        $raw = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
        $showGroups = if ($raw.PSObject.Properties.Name -contains 'ShowGroups') { [bool]$raw.ShowGroups } else { $true }
        return @{
            OnlyNode   = [bool]$raw.OnlyNode
            RootDir    = [string]$raw.RootDir
            ShowGroups = $showGroups
        }
    } catch { return $defaults }
}

function Save-Settings($settings) {
    if (-not (Test-Path $script:HistoryDir)) { New-Item -ItemType Directory -Path $script:HistoryDir -Force | Out-Null }
    $settings | ConvertTo-Json | Set-Content -Path $script:SettingsPath -Encoding UTF8
}

$script:CustomNamesPath = Join-Path $script:HistoryDir 'customnames.json'

function Load-CustomNames {
    if (-not (Test-Path $script:CustomNamesPath)) { return @{} }
    try {
        $raw = Get-Content $script:CustomNamesPath -Raw | ConvertFrom-Json
        $h = @{}
        foreach ($prop in $raw.PSObject.Properties) { $h[$prop.Name] = [string]$prop.Value }
        return $h
    } catch { return @{} }
}

function Save-CustomNames($names) {
    if (-not (Test-Path $script:HistoryDir)) { New-Item -ItemType Directory -Path $script:HistoryDir -Force | Out-Null }
    $names | ConvertTo-Json | Set-Content -Path $script:CustomNamesPath -Encoding UTF8
}

function Get-CustomNameKey {
    param([string]$ProjectPath, [string]$Port)
    if ($ProjectPath) { return $ProjectPath.TrimEnd('\').ToLowerInvariant() }
    return "port:$Port"
}

function Get-NormalizedPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    return $Path.TrimEnd('\').ToLowerInvariant()
}

$script:GroupsPath = Join-Path $script:HistoryDir 'groups.json'

function Load-Groups {
    if (-not (Test-Path $script:GroupsPath)) { return @{} }
    try {
        $raw = Get-Content $script:GroupsPath -Raw | ConvertFrom-Json
        $g = @{}
        foreach ($prop in $raw.PSObject.Properties) { $g[$prop.Name] = @($prop.Value) }
        return $g
    } catch { return @{} }
}

function Save-Groups($groups) {
    if (-not (Test-Path $script:HistoryDir)) { New-Item -ItemType Directory -Path $script:HistoryDir -Force | Out-Null }
    $groups | ConvertTo-Json | Set-Content -Path $script:GroupsPath -Encoding UTF8
}

function Get-AllGroupedPaths {
    $paths = New-Object System.Collections.Generic.HashSet[string]
    foreach ($groupPaths in $script:Groups.Values) {
        foreach ($p in $groupPaths) { [void]$paths.Add((Get-NormalizedPath $p)) }
    }
    return $paths
}

function Limit-ToGroupedRows {
    param($Rows)
    if ($script:Settings.ShowGroups) { return $Rows }
    $grouped = Get-AllGroupedPaths
    return @($Rows | Where-Object { $_.ProjectPath -and $grouped.Contains((Get-NormalizedPath $_.ProjectPath)) })
}

function Test-PathUnderRoot {
    param([string]$Path, [string]$Root)
    if (-not $Root) { return $true }
    if (-not $Path) { return $false }
    $p = $Path.TrimEnd('\').ToLowerInvariant()
    $r = $Root.TrimEnd('\').ToLowerInvariant()
    return ($p -eq $r) -or $p.StartsWith("$r\")
}

$script:ExcludedProcessNames = @(
    'svchost','System','Idle','Registry','lsass','services','wininit','csrss',
    'smss','spoolsv','dllhost','MsMpEng','SearchIndexer','dashost','fontdrvhost',
    'winlogon','dwm','sihost','taskhostw','WUDFHost','NisSrv','SecurityHealthService'
)

function Get-LanIPv4Addresses {
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -ExpandProperty IPAddress -Unique
}

function Get-LiveListeners {
    $conns = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue
    $byPort = @{}
    foreach ($c in $conns) {
        if ($c.LocalPort -eq 0) { continue }
        $key = [string]$c.LocalPort
        if ($byPort.ContainsKey($key)) {
            if ($byPort[$key].LocalAddress -eq '::' -and $c.LocalAddress -ne '::') {
                $byPort[$key] = $c
            }
            continue
        }
        $byPort[$key] = $c
    }

    $result = @{}
    foreach ($key in $byPort.Keys) {
        $c = $byPort[$key]
        $procId = [int]$c.OwningProcess
        $procName = $null
        try { $procName = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch {}
        if (-not $procName) { continue }
        if ($script:ExcludedProcessNames -contains $procName) { continue }

        $cwd = Get-ProcessWorkingDirectory -ProcId $procId
        $isNode = $false
        if ($cwd) { $isNode = Test-Path (Join-Path $cwd 'package.json') -ErrorAction SilentlyContinue }

        $result[$key] = @{
            Port        = $key
            ProcId      = $procId
            ProcessName = $procName
            LocalAddr   = $c.LocalAddress
            ProjectPath = $cwd
            IsNode      = [bool]$isNode
        }
    }
    return $result
}

function Build-Rows {
    param([bool]$OnlyNode, [string]$RootDir)

    $live = Get-LiveListeners
    $history = Load-History
    $lanIps = @(Get-LanIPv4Addresses)

    foreach ($key in $live.Keys) {
        $e = $live[$key]
        if ($e.IsNode) {
            $history[$key] = @{ ProjectPath = $e.ProjectPath; ProcessName = $e.ProcessName }
        }
    }
    Save-History $history

    $rows = @()
    $seen = @{}

    foreach ($key in ($live.Keys | Sort-Object { [int]$_ })) {
        $e = $live[$key]
        if ($OnlyNode -and -not $e.IsNode) { continue }
        if (-not (Test-PathUnderRoot -Path $e.ProjectPath -Root $RootDir)) { continue }
        $seen[$key] = $true

        $lanUrls = ''
        if ($e.LocalAddr -eq '0.0.0.0' -or $e.LocalAddr -eq '::') {
            $lanUrls = ($lanIps | ForEach-Object { "http://$($_):$key" }) -join ', '
        } else {
            $lanUrls = '(localhost only)'
        }

        $nameKey = Get-CustomNameKey -ProjectPath $e.ProjectPath -Port $key
        $customName = if ($script:CustomNames.ContainsKey($nameKey)) { $script:CustomNames[$nameKey] } else { '' }

        $rows += [PSCustomObject]@{
            Status      = 'ON'
            Port        = $key
            CustomName  = $customName
            ProcessName = $e.ProcessName
            ProcId      = $e.ProcId
            LocalUrl    = "http://localhost:$key"
            LanUrls     = $lanUrls
            ProjectPath = $e.ProjectPath
            Action      = 'Stop'
        }
    }

    foreach ($key in ($history.Keys | Sort-Object { [int]$_ })) {
        if ($seen.ContainsKey($key)) { continue }
        $h = $history[$key]
        if (-not (Test-PathUnderRoot -Path $h.ProjectPath -Root $RootDir)) { continue }

        $nameKey = Get-CustomNameKey -ProjectPath $h.ProjectPath -Port $key
        $customName = if ($script:CustomNames.ContainsKey($nameKey)) { $script:CustomNames[$nameKey] } else { '' }

        $rows += [PSCustomObject]@{
            Status      = 'OFF'
            Port        = $key
            CustomName  = $customName
            ProcessName = $h.ProcessName
            ProcId      = $null
            LocalUrl    = "http://localhost:$key"
            LanUrls     = ''
            ProjectPath = $h.ProjectPath
            Action      = 'Start'
        }
    }

    return $rows | Sort-Object { [int]$_.Port }
}

# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Settings = Load-Settings
$script:RootDir = $script:Settings.RootDir
$script:CustomNames = Load-CustomNames
$script:Groups = Load-Groups

$script:AppDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }

function Get-AppIcon {
    param([string]$FileName)
    $path = Join-Path $script:AppDir $FileName
    if (Test-Path $path) {
        try { return New-Object System.Drawing.Icon($path) } catch {}
    }
    try { return [System.Drawing.Icon]::ExtractAssociatedIcon([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch { return [System.Drawing.SystemIcons]::Application }
}

$script:IconOk = Get-AppIcon 'LocalhostManager.ico'
$script:IconAlert = Get-AppIcon 'LocalhostManager-alert.ico'

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Localhost Manager'
$form.Size = New-Object System.Drawing.Size(920, 560)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(700, 400)
$form.Icon = $script:IconOk

$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock = 'Top'
$topPanel.Height = 76

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = 'Refresh'
$refreshButton.Location = New-Object System.Drawing.Point(10, 8)
$refreshButton.Size = New-Object System.Drawing.Size(80, 24)

$nodeOnlyCheck = New-Object System.Windows.Forms.CheckBox
$nodeOnlyCheck.Text = 'Node/npm projects only'
$nodeOnlyCheck.Checked = $script:Settings.OnlyNode
$nodeOnlyCheck.Location = New-Object System.Drawing.Point(100, 11)
$nodeOnlyCheck.Size = New-Object System.Drawing.Size(170, 20)

$settingsButton = New-Object System.Windows.Forms.Button
$settingsButton.Text = 'Settings...'
$settingsButton.Location = New-Object System.Drawing.Point(280, 8)
$settingsButton.Size = New-Object System.Drawing.Size(80, 24)

$showGroupsCheck = New-Object System.Windows.Forms.CheckBox
$showGroupsCheck.Text = 'Show Groups'
$showGroupsCheck.Checked = $script:Settings.ShowGroups
$showGroupsCheck.Location = New-Object System.Drawing.Point(365, 11)
$showGroupsCheck.Size = New-Object System.Drawing.Size(105, 20)

$scopeLabel = New-Object System.Windows.Forms.Label
$scopeLabel.Text = ''
$scopeLabel.Location = New-Object System.Drawing.Point(480, 12)
$scopeLabel.Size = New-Object System.Drawing.Size(215, 20)
$scopeLabel.ForeColor = [System.Drawing.Color]::SteelBlue
$scopeLabel.AutoEllipsis = $true

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = ''
$statusLabel.Location = New-Object System.Drawing.Point(700, 12)
$statusLabel.Size = New-Object System.Drawing.Size(210, 20)
$statusLabel.ForeColor = [System.Drawing.Color]::DimGray

$groupLabel = New-Object System.Windows.Forms.Label
$groupLabel.Text = 'Group:'
$groupLabel.Location = New-Object System.Drawing.Point(10, 48)
$groupLabel.Size = New-Object System.Drawing.Size(45, 20)

$groupCombo = New-Object System.Windows.Forms.ComboBox
$groupCombo.DropDownStyle = 'DropDownList'
$groupCombo.Location = New-Object System.Drawing.Point(55, 44)
$groupCombo.Size = New-Object System.Drawing.Size(170, 24)

$startAllButton = New-Object System.Windows.Forms.Button
$startAllButton.Text = 'Start All'
$startAllButton.Location = New-Object System.Drawing.Point(235, 44)
$startAllButton.Size = New-Object System.Drawing.Size(80, 24)

$stopAllButton = New-Object System.Windows.Forms.Button
$stopAllButton.Text = 'Stop All'
$stopAllButton.Location = New-Object System.Drawing.Point(320, 44)
$stopAllButton.Size = New-Object System.Drawing.Size(80, 24)

$manageGroupsButton = New-Object System.Windows.Forms.Button
$manageGroupsButton.Text = 'Manage Groups...'
$manageGroupsButton.Location = New-Object System.Drawing.Point(410, 44)
$manageGroupsButton.Size = New-Object System.Drawing.Size(130, 24)

[System.Windows.Forms.Control[]]$topControls = @($refreshButton, $nodeOnlyCheck, $settingsButton, $showGroupsCheck, $scopeLabel, $statusLabel, $groupLabel, $groupCombo, $startAllButton, $stopAllButton, $manageGroupsButton)
$topPanel.Controls.AddRange($topControls)

function Update-GroupsVisibility {
    $show = $showGroupsCheck.Checked
    $groupLabel.Visible = $show
    $groupCombo.Visible = $show
    $startAllButton.Visible = $show
    $stopAllButton.Visible = $show
    $manageGroupsButton.Visible = $show
    $topPanel.Height = if ($show) { 76 } else { 40 }
    if ($grid) {
        $grid.Location = New-Object System.Drawing.Point(0, $topPanel.Height)
        $grid.Size = New-Object System.Drawing.Size($form.ClientSize.Width, ($form.ClientSize.Height - $topPanel.Height))
    }
}

function Update-GroupCombo {
    $previous = $groupCombo.SelectedItem
    $groupCombo.Items.Clear()
    foreach ($name in ($script:Groups.Keys | Sort-Object)) { $groupCombo.Items.Add($name) | Out-Null }
    if ($previous -and $groupCombo.Items.Contains($previous)) {
        $groupCombo.SelectedItem = $previous
    } elseif ($groupCombo.Items.Count -gt 0) {
        $groupCombo.SelectedIndex = 0
    }
}
Update-GroupCombo

function Update-ScopeLabel {
    if ($script:RootDir) {
        $scopeLabel.Text = "Scope: $script:RootDir"
    } else {
        $scopeLabel.Text = 'Scope: All projects'
    }
}
Update-ScopeLabel

$grid = New-Object System.Windows.Forms.DataGridView
$grid.AutoGenerateColumns = $false
$grid.ReadOnly = $false
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $false
$grid.EditMode = 'EditOnKeystrokeOrF2'
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
$grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
$grid.ColumnHeadersHeight = 28
$grid.RowTemplate.Height = 26

$colStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colStatus.Name = 'Status'; $colStatus.HeaderText = 'Status'; $colStatus.FillWeight = 45; $colStatus.ReadOnly = $true

$colPort = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colPort.Name = 'Port'; $colPort.HeaderText = 'Port'; $colPort.FillWeight = 45; $colPort.ReadOnly = $true

$colCustomName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colCustomName.Name = 'CustomName'; $colCustomName.HeaderText = 'Custom Name'; $colCustomName.FillWeight = 90; $colCustomName.ReadOnly = $false

$colProc = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colProc.Name = 'Process'; $colProc.HeaderText = 'Process'; $colProc.FillWeight = 70; $colProc.ReadOnly = $true

$colPid = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colPid.Name = 'PID'; $colPid.HeaderText = 'PID'; $colPid.FillWeight = 45; $colPid.ReadOnly = $true

$colLocal = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colLocal.Name = 'LocalUrl'; $colLocal.HeaderText = 'Local URL'; $colLocal.FillWeight = 110; $colLocal.ReadOnly = $true

$colLan = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colLan.Name = 'LanUrls'; $colLan.HeaderText = 'Network URL(s)'; $colLan.FillWeight = 180; $colLan.ReadOnly = $true

$colPath = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colPath.Name = 'ProjectPath'; $colPath.HeaderText = 'Project Path'; $colPath.FillWeight = 180; $colPath.ReadOnly = $true

$colAction = New-Object System.Windows.Forms.DataGridViewButtonColumn
$colAction.Name = 'Action'; $colAction.HeaderText = ''; $colAction.FillWeight = 60
$colAction.UseColumnTextForButtonValue = $false
$colAction.ReadOnly = $true

[System.Windows.Forms.DataGridViewColumn[]]$gridColumns = @($colStatus, $colPort, $colCustomName, $colProc, $colPid, $colLocal, $colLan, $colPath, $colAction)
$grid.Columns.AddRange($gridColumns)
$grid.AutoSizeColumnsMode = 'Fill'

$dgvDoubleBufferProp = [System.Windows.Forms.DataGridView].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance, NonPublic')
$dgvDoubleBufferProp.SetValue($grid, $true, $null)
$grid.Anchor = 'Top,Bottom,Left,Right'
$grid.Location = New-Object System.Drawing.Point(0, 76)
$grid.Size = New-Object System.Drawing.Size($form.ClientSize.Width, ($form.ClientSize.Height - 76))

$form.Controls.Add($topPanel)
$form.Controls.Add($grid)
Update-GroupsVisibility

function Refresh-Grid {
    if ($grid.IsCurrentCellInEditMode) { return }

    $grid.SuspendLayout()
    try {
        $grid.Rows.Clear()
        $rows = @(Limit-ToGroupedRows (Build-Rows -OnlyNode $nodeOnlyCheck.Checked -RootDir $script:RootDir))
        foreach ($r in $rows) {
            $idx = $grid.Rows.Add($r.Status, $r.Port, $r.CustomName, $r.ProcessName, $r.ProcId, $r.LocalUrl, $r.LanUrls, $r.ProjectPath, $r.Action)
            $row = $grid.Rows[$idx]
            $row.Tag = $r
            if ($r.Status -eq 'ON') {
                $row.Cells['Status'].Style.ForeColor = [System.Drawing.Color]::ForestGreen
            } else {
                $row.Cells['Status'].Style.ForeColor = [System.Drawing.Color]::Firebrick
            }
        }
        $grid.ClearSelection()
    } finally {
        $grid.ResumeLayout()
    }
    $statusLabel.Text = "Last refreshed: $(Get-Date -Format 'HH:mm:ss')  |  $($rows.Count) shown"
    Update-TrayIcon
}

function Start-ProjectAtPath {
    param([string]$ProjectPath)
    try {
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/k cd /d `"$ProjectPath`" && npm start" -WindowStyle Normal
        return $true
    } catch {
        return $false
    }
}

function Stop-ProjectById {
    param([int]$ProcId)
    try {
        Stop-Process -Id $ProcId -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Invoke-ToggleAction {
    param($data)

    if ($data.Status -eq 'ON') {
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Stop $($data.ProcessName) (PID $($data.ProcId)) listening on port $($data.Port)?",
            'Confirm Stop', 'YesNo', 'Warning')
        if ($confirm -ne 'Yes') { return }
        if (-not (Stop-ProjectById -ProcId $data.ProcId)) {
            [System.Windows.Forms.MessageBox]::Show('Could not stop process.', 'Error', 'OK', 'Error') | Out-Null
        }
    } else {
        if (-not $data.ProjectPath) {
            [System.Windows.Forms.MessageBox]::Show('No known project path for this port.', 'Cannot Start', 'OK', 'Warning') | Out-Null
            return
        }
        if (-not (Start-ProjectAtPath -ProjectPath $data.ProjectPath)) {
            [System.Windows.Forms.MessageBox]::Show('Could not start project.', 'Error', 'OK', 'Error') | Out-Null
        }
    }
    Start-Sleep -Milliseconds 800
    Refresh-Grid
}

$grid.Add_CellContentClick({
    param($s, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -ne $colAction.Index) { return }
    $row = $grid.Rows[$e.RowIndex]
    Invoke-ToggleAction $row.Tag
})

$grid.Add_CellEndEdit({
    param($s, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -ne $colCustomName.Index) { return }
    $row = $grid.Rows[$e.RowIndex]
    $data = $row.Tag
    if (-not $data) { return }

    $newName = [string]$row.Cells[$colCustomName.Index].Value
    $nameKey = Get-CustomNameKey -ProjectPath $data.ProjectPath -Port $data.Port

    if ([string]::IsNullOrWhiteSpace($newName)) {
        if ($script:CustomNames.ContainsKey($nameKey)) { $script:CustomNames.Remove($nameKey) }
    } else {
        $script:CustomNames[$nameKey] = $newName
    }
    Save-CustomNames $script:CustomNames
})

function Show-SettingsDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Settings'
    $dlg.Size = New-Object System.Drawing.Size(480, 190)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Only show projects under this root directory:'
    $lbl.Location = New-Object System.Drawing.Point(15, 15)
    $lbl.Size = New-Object System.Drawing.Size(400, 20)

    $pathBox = New-Object System.Windows.Forms.TextBox
    $pathBox.Text = $script:RootDir
    $pathBox.Location = New-Object System.Drawing.Point(15, 40)
    $pathBox.Size = New-Object System.Drawing.Size(330, 24)
    $pathBox.ReadOnly = $true

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Text = 'Browse...'
    $browseButton.Location = New-Object System.Drawing.Point(355, 39)
    $browseButton.Size = New-Object System.Drawing.Size(95, 24)
    $browseButton.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($pathBox.Text) { $fbd.SelectedPath = $pathBox.Text }
        if ($fbd.ShowDialog() -eq 'OK') { $pathBox.Text = $fbd.SelectedPath }
    })

    $clearButton = New-Object System.Windows.Forms.Button
    $clearButton.Text = 'Clear (no restriction)'
    $clearButton.Location = New-Object System.Drawing.Point(15, 75)
    $clearButton.Size = New-Object System.Drawing.Size(160, 24)
    $clearButton.Add_Click({ $pathBox.Text = '' })

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'OK'
    $okButton.Location = New-Object System.Drawing.Point(275, 115)
    $okButton.Size = New-Object System.Drawing.Size(85, 26)
    $okButton.Add_Click({ $dlg.Tag = 'OK'; $dlg.Close() })

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = New-Object System.Drawing.Point(365, 115)
    $cancelButton.Size = New-Object System.Drawing.Size(85, 26)
    $cancelButton.Add_Click({ $dlg.Close() })

    [System.Windows.Forms.Control[]]$dlgControls = @($lbl, $pathBox, $browseButton, $clearButton, $okButton, $cancelButton)
    $dlg.Controls.AddRange($dlgControls)
    $dlg.AcceptButton = $okButton
    $dlg.ShowDialog($form) | Out-Null

    if ($dlg.Tag -eq 'OK') {
        $script:RootDir = $pathBox.Text
        $script:Settings.RootDir = $script:RootDir
        Save-Settings $script:Settings
        Update-ScopeLabel
        Refresh-Grid
    }
}

$settingsButton.Add_Click({ Show-SettingsDialog })

function Get-KnownProjects {
    $allRows = @(Build-Rows -OnlyNode $true -RootDir '')
    $seen = @{}
    $projects = @()
    foreach ($r in $allRows) {
        if (-not $r.ProjectPath) { continue }
        $key = Get-NormalizedPath $r.ProjectPath
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $label = if ($r.CustomName) { $r.CustomName } else { Split-Path -Leaf $r.ProjectPath }
        $projects += [PSCustomObject]@{
            ProjectPath = $r.ProjectPath
            Label       = "$label (port $($r.Port))"
        }
    }
    return $projects | Sort-Object Label
}

function Show-ManageGroupsDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Manage Groups'
    $dlg.Size = New-Object System.Drawing.Size(460, 460)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $nameLabel = New-Object System.Windows.Forms.Label
    $nameLabel.Text = 'Group name:'
    $nameLabel.Location = New-Object System.Drawing.Point(15, 15)
    $nameLabel.Size = New-Object System.Drawing.Size(100, 20)

    $nameCombo = New-Object System.Windows.Forms.ComboBox
    $nameCombo.DropDownStyle = 'DropDown'
    $nameCombo.Location = New-Object System.Drawing.Point(15, 38)
    $nameCombo.Size = New-Object System.Drawing.Size(415, 24)
    foreach ($n in ($script:Groups.Keys | Sort-Object)) { $nameCombo.Items.Add($n) | Out-Null }

    $projLabel = New-Object System.Windows.Forms.Label
    $projLabel.Text = 'Projects in this group:'
    $projLabel.Location = New-Object System.Drawing.Point(15, 70)
    $projLabel.Size = New-Object System.Drawing.Size(200, 20)

    $projList = New-Object System.Windows.Forms.CheckedListBox
    $projList.Location = New-Object System.Drawing.Point(15, 92)
    $projList.Size = New-Object System.Drawing.Size(415, 260)
    $projList.CheckOnClick = $true

    $knownProjects = @(Get-KnownProjects)
    foreach ($p in $knownProjects) { $projList.Items.Add($p.Label) | Out-Null }

    function Set-CheckedFromGroup {
        param([string]$GroupName)
        for ($i = 0; $i -lt $projList.Items.Count; $i++) { $projList.SetItemChecked($i, $false) }
        if (-not $GroupName -or -not $script:Groups.ContainsKey($GroupName)) { return }
        $paths = @($script:Groups[$GroupName] | ForEach-Object { Get-NormalizedPath $_ })
        for ($i = 0; $i -lt $knownProjects.Count; $i++) {
            if ($paths -contains (Get-NormalizedPath $knownProjects[$i].ProjectPath)) { $projList.SetItemChecked($i, $true) }
        }
    }

    $nameCombo.Add_SelectedIndexChanged({ Set-CheckedFromGroup -GroupName $nameCombo.Text })

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = 'Save Group'
    $saveButton.Location = New-Object System.Drawing.Point(15, 365)
    $saveButton.Size = New-Object System.Drawing.Size(110, 28)
    $saveButton.Add_Click({
        $name = $nameCombo.Text.Trim()
        if (-not $name) {
            [System.Windows.Forms.MessageBox]::Show('Enter a group name.', 'Cannot Save', 'OK', 'Warning') | Out-Null
            return
        }
        $paths = @()
        for ($i = 0; $i -lt $knownProjects.Count; $i++) {
            if ($projList.GetItemChecked($i)) { $paths += $knownProjects[$i].ProjectPath }
        }
        $script:Groups[$name] = $paths
        Save-Groups $script:Groups
        if (-not $nameCombo.Items.Contains($name)) { $nameCombo.Items.Add($name) | Out-Null }
        Update-GroupCombo
        [System.Windows.Forms.MessageBox]::Show("Saved group '$name' with $($paths.Count) project(s).", 'Saved', 'OK', 'Information') | Out-Null
    })

    $deleteButton = New-Object System.Windows.Forms.Button
    $deleteButton.Text = 'Delete Group'
    $deleteButton.Location = New-Object System.Drawing.Point(135, 365)
    $deleteButton.Size = New-Object System.Drawing.Size(110, 28)
    $deleteButton.Add_Click({
        $name = $nameCombo.Text.Trim()
        if (-not $name -or -not $script:Groups.ContainsKey($name)) { return }
        $confirm = [System.Windows.Forms.MessageBox]::Show("Delete group '$name'?", 'Confirm Delete', 'YesNo', 'Warning')
        if ($confirm -ne 'Yes') { return }
        $script:Groups.Remove($name)
        Save-Groups $script:Groups
        $nameCombo.Items.Remove($name)
        $nameCombo.Text = ''
        Set-CheckedFromGroup -GroupName ''
        Update-GroupCombo
    })

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = 'Close'
    $closeButton.Location = New-Object System.Drawing.Point(345, 365)
    $closeButton.Size = New-Object System.Drawing.Size(85, 28)
    $closeButton.Add_Click({ $dlg.Close() })

    [System.Windows.Forms.Control[]]$dlgControls = @($nameLabel, $nameCombo, $projLabel, $projList, $saveButton, $deleteButton, $closeButton)
    $dlg.Controls.AddRange($dlgControls)
    $dlg.ShowDialog($form) | Out-Null
}

$manageGroupsButton.Add_Click({ Show-ManageGroupsDialog })

function Start-GroupAll {
    param([string]$Name)

    if (-not $Name -or -not $script:Groups.ContainsKey($Name)) {
        [System.Windows.Forms.MessageBox]::Show('Pick a group first (or create one via Manage Groups).', 'No Group Selected', 'OK', 'Warning') | Out-Null
        return
    }
    $paths = @($script:Groups[$Name] | ForEach-Object { Get-NormalizedPath $_ })
    $allRows = @(Build-Rows -OnlyNode $true -RootDir '')
    $toStart = @($allRows | Where-Object { $_.Status -eq 'OFF' -and $_.ProjectPath -and ($paths -contains (Get-NormalizedPath $_.ProjectPath)) })

    if ($toStart.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Everything in '$Name' is already running (or has no known path).", 'Nothing to Start', 'OK', 'Information') | Out-Null
        return
    }
    $started = 0
    foreach ($row in $toStart) {
        if (Start-ProjectAtPath -ProjectPath $row.ProjectPath) { $started++ }
    }
    Start-Sleep -Milliseconds 1000
    Refresh-Grid
    [System.Windows.Forms.MessageBox]::Show("Started $started of $($toStart.Count) project(s) in '$Name'.", 'Start All', 'OK', 'Information') | Out-Null
}

function Stop-GroupAll {
    param([string]$Name)

    if (-not $Name -or -not $script:Groups.ContainsKey($Name)) {
        [System.Windows.Forms.MessageBox]::Show('Pick a group first (or create one via Manage Groups).', 'No Group Selected', 'OK', 'Warning') | Out-Null
        return
    }
    $paths = @($script:Groups[$Name] | ForEach-Object { Get-NormalizedPath $_ })
    $allRows = @(Build-Rows -OnlyNode $true -RootDir '')
    $toStop = @($allRows | Where-Object { $_.Status -eq 'ON' -and $_.ProjectPath -and ($paths -contains (Get-NormalizedPath $_.ProjectPath)) })

    if ($toStop.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Nothing in '$Name' is currently running.", 'Nothing to Stop', 'OK', 'Information') | Out-Null
        return
    }
    $list = ($toStop | ForEach-Object { "$($_.ProcessName) (port $($_.Port))" }) -join "`n"
    $confirm = [System.Windows.Forms.MessageBox]::Show("Stop these $($toStop.Count) process(es)?`n`n$list", 'Confirm Stop All', 'YesNo', 'Warning')
    if ($confirm -ne 'Yes') { return }

    $stopped = 0
    foreach ($row in $toStop) {
        if (Stop-ProjectById -ProcId $row.ProcId) { $stopped++ }
    }
    Refresh-Grid
    [System.Windows.Forms.MessageBox]::Show("Stopped $stopped of $($toStop.Count) process(es) in '$Name'.", 'Stop All', 'OK', 'Information') | Out-Null
}

$startAllButton.Add_Click({ Start-GroupAll -Name $groupCombo.SelectedItem })
$stopAllButton.Add_Click({ Stop-GroupAll -Name $groupCombo.SelectedItem })

# ---------------------------------------------------------------------------
# System tray
# ---------------------------------------------------------------------------
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = $script:IconOk
$notifyIcon.Text = 'Localhost Manager'
$notifyIcon.ContextMenuStrip = $trayMenu
$notifyIcon.Visible = $true

function Restore-MainWindow {
    $form.Show()
    $form.WindowState = 'Normal'
    $form.Activate()
}

$notifyIcon.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Restore-MainWindow }
})

function Update-TrayIcon {
    $allRows = @(Limit-ToGroupedRows (Build-Rows -OnlyNode $true -RootDir ''))
    $onCount = @($allRows | Where-Object { $_.Status -eq 'ON' }).Count
    $totalCount = $allRows.Count

    $newIcon = if ($totalCount -gt 0 -and $onCount -lt $totalCount) { $script:IconAlert } else { $script:IconOk }
    if ($notifyIcon.Icon -ne $newIcon) { $notifyIcon.Icon = $newIcon }

    $newText = if ($totalCount -eq 0) { 'Localhost Manager - no projects yet' } else { "Localhost Manager - $onCount/$totalCount running" }
    if ($notifyIcon.Text -ne $newText) { $notifyIcon.Text = $newText }
}

function Build-TrayMenuItems {
    $trayMenu.Items.Clear()

    $openItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Open Localhost Manager'
    $openItem.Font = New-Object System.Drawing.Font($trayMenu.Font, [System.Drawing.FontStyle]::Bold)
    $openItem.Add_Click({ Restore-MainWindow })
    $trayMenu.Items.Add($openItem) | Out-Null
    $trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $allRows = @(Limit-ToGroupedRows (Build-Rows -OnlyNode $true -RootDir ''))
    if ($allRows.Count -eq 0) {
        $emptyText = if ($script:Settings.ShowGroups) { 'No known npm projects yet' } else { 'No grouped projects yet' }
        $noneItem = New-Object System.Windows.Forms.ToolStripMenuItem $emptyText
        $noneItem.Enabled = $false
        $trayMenu.Items.Add($noneItem) | Out-Null
    } else {
        foreach ($r in $allRows) {
            $projName = if ($r.CustomName) { $r.CustomName } elseif ($r.ProjectPath) { Split-Path -Leaf $r.ProjectPath } else { $r.ProcessName }
            $label = if ($r.Status -eq 'ON') { "[ON]   $($r.Port)  $projName" } else { "[OFF]  $($r.Port)  $projName" }
            $item = New-Object System.Windows.Forms.ToolStripMenuItem $label
            $capturedRow = $r
            $clickHandler = { Invoke-ToggleAction $capturedRow }.GetNewClosure()
            $item.Add_Click($clickHandler)
            $trayMenu.Items.Add($item) | Out-Null
        }
    }

    if ($script:Settings.ShowGroups -and $script:Groups.Keys.Count -gt 0) {
        $trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
        foreach ($groupName in ($script:Groups.Keys | Sort-Object)) {
            $groupItem = New-Object System.Windows.Forms.ToolStripMenuItem "Group: $groupName"
            $capturedName = $groupName

            $startItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Start All'
            $startItem.Add_Click({ Start-GroupAll -Name $capturedName }.GetNewClosure())
            $groupItem.DropDownItems.Add($startItem) | Out-Null

            $stopItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Stop All'
            $stopItem.Add_Click({ Stop-GroupAll -Name $capturedName }.GetNewClosure())
            $groupItem.DropDownItems.Add($stopItem) | Out-Null

            $trayMenu.Items.Add($groupItem) | Out-Null
        }
    }

    $trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Refresh'
    $refreshItem.Add_Click({ Refresh-Grid })
    $trayMenu.Items.Add($refreshItem) | Out-Null

    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit'
    $exitItem.Add_Click({
        $script:ReallyExit = $true
        $notifyIcon.Visible = $false
        $form.Close()
    })
    $trayMenu.Items.Add($exitItem) | Out-Null
}

$trayMenu.Add_Opening({ Build-TrayMenuItems })

$script:ReallyExit = $false
$script:TrayNoticeShown = $false
$form.Add_FormClosing({
    param($s, $e)
    if (-not $script:ReallyExit) {
        $e.Cancel = $true
        $form.Hide()
        if (-not $script:TrayNoticeShown) {
            $notifyIcon.ShowBalloonTip(2000, 'Localhost Manager', 'Still running in the tray. Right-click the tray icon to exit.', [System.Windows.Forms.ToolTipIcon]::Info)
            $script:TrayNoticeShown = $true
        }
    } else {
        $notifyIcon.Visible = $false
    }
})

$refreshButton.Add_Click({ Refresh-Grid })
$nodeOnlyCheck.Add_CheckedChanged({
    $script:Settings.OnlyNode = $nodeOnlyCheck.Checked
    Save-Settings $script:Settings
    Refresh-Grid
})
$showGroupsCheck.Add_CheckedChanged({
    $script:Settings.ShowGroups = $showGroupsCheck.Checked
    Save-Settings $script:Settings
    Update-GroupsVisibility
    Refresh-Grid
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 4000
$timer.Add_Tick({ Refresh-Grid })
$timer.Start()

try {
    Refresh-Grid
} catch {
    [System.Windows.Forms.MessageBox]::Show("Startup error: $_", 'Error') | Out-Null
}
[System.Windows.Forms.Application]::Run($form)
