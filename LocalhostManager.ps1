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
    $defaults = @{ OnlyNode = $true; RootDir = ''; ShowGroups = $true; SelectedGroups = @() }
    if (-not (Test-Path $script:SettingsPath)) { return $defaults }
    try {
        $raw = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
        $showGroups = if ($raw.PSObject.Properties.Name -contains 'ShowGroups') { [bool]$raw.ShowGroups } else { $true }
        $selectedGroups = if ($raw.PSObject.Properties.Name -contains 'SelectedGroups') { @($raw.SelectedGroups) } else { @() }
        return @{
            OnlyNode       = [bool]$raw.OnlyNode
            RootDir        = [string]$raw.RootDir
            ShowGroups     = $showGroups
            SelectedGroups = $selectedGroups
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
    # Used by the tray icon/menu, which always shows every known server
    # regardless of the main window's "Use Groups" filter.
    return $Rows
}

function Get-StatusRank {
    param([string]$Status)
    switch ($Status) {
        'ON'      { return 0 }
        'CRASHED' { return 1 }
        default   { return 2 }
    }
}

function Get-GroupRowsOrdered {
    param($Rows, [string[]]$GroupNames)
    # Filters Rows down to just the members of the given groups (in the
    # order given), each row tagged with which group it belongs to so the
    # grid can draw a separator between groups. A project that's in more
    # than one selected group — or that has more than one historical port
    # recorded for the same project path (e.g. a stale OFF entry sitting
    # alongside the live ON one) — is only shown once: the live/ON row
    # wins, otherwise the lowest port.
    $result = @()
    $usedPaths = New-Object System.Collections.Generic.HashSet[string]
    foreach ($groupName in $GroupNames) {
        if (-not $script:Groups.ContainsKey($groupName)) { continue }
        $groupPaths = New-Object System.Collections.Generic.HashSet[string]
        foreach ($p in $script:Groups[$groupName]) { [void]$groupPaths.Add((Get-NormalizedPath $p)) }

        $candidateRows = @($Rows | Where-Object {
            $_.ProjectPath -and $groupPaths.Contains((Get-NormalizedPath $_.ProjectPath))
        } | Sort-Object @{ Expression = { Get-StatusRank $_.Status } }, { [int]$_.Port })

        foreach ($r in $candidateRows) {
            $key = Get-NormalizedPath $r.ProjectPath
            if ($usedPaths.Contains($key)) { continue }
            [void]$usedPaths.Add($key)
            $result += [PSCustomObject]@{ Row = $r; Group = $groupName }
        }
    }
    return $result
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

# ---------------------------------------------------------------------------
# Background TCP/process poller. Get-NetTCPConnection and Get-NetIPAddress
# are WMI-backed and routinely take 200ms-1s+ to return. Running them on the
# UI thread every timer tick used to freeze the whole window for that long —
# most noticeable as stutter while dragging the title bar, since dragging
# needs that same thread to keep pumping mouse-move messages. Instead a
# background runspace polls on its own loop and drops results into this
# synchronized (thread-safe) cache; the UI thread only ever reads from it,
# which is effectively instant.
# ---------------------------------------------------------------------------
$script:LiveCache = [hashtable]::Synchronized(@{
    Listeners     = @{}
    LanIps        = @()
    Ready         = $false
    StopRequested = $false
})

$script:BackgroundPollScript = {
    param($Cache, $ExcludedNames, $IntervalMs)

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

    while (-not $Cache.StopRequested) {
        try {
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
                if ($ExcludedNames -contains $procName) { continue }

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

            $lanIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } |
                Select-Object -ExpandProperty IPAddress -Unique)

            $Cache.Listeners = $result
            $Cache.LanIps    = $lanIps
            $Cache.Ready     = $true
        } catch {
            # Transient polling failure - keep serving the last good snapshot.
        }
        Start-Sleep -Milliseconds $IntervalMs
    }
}

$script:PollRunspace = [runspacefactory]::CreateRunspace()
$script:PollRunspace.ApartmentState = 'MTA'
$script:PollRunspace.ThreadOptions = 'ReuseThread'
$script:PollRunspace.Open()

$script:PollShell = [powershell]::Create()
$script:PollShell.Runspace = $script:PollRunspace
[void]$script:PollShell.AddScript($script:BackgroundPollScript).
    AddArgument($script:LiveCache).
    AddArgument($script:ExcludedProcessNames).
    AddArgument(4000)
$script:PollHandle = $script:PollShell.BeginInvoke()

function Stop-BackgroundPoller {
    $script:LiveCache.StopRequested = $true
    try { $script:PollShell.Stop() } catch {}
    try { $script:PollShell.Dispose() } catch {}
    try { $script:PollRunspace.Close() } catch {}
}

function Get-LanIPv4Addresses {
    return @($script:LiveCache.LanIps)
}

function Get-LiveListeners {
    return $script:LiveCache.Listeners
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

        $managed = $script:ManagedProcesses[(Get-NormalizedPath $e.ProjectPath)]

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
            HasLog      = [bool]$managed
        }
    }

    foreach ($key in ($history.Keys | Sort-Object { [int]$_ })) {
        if ($seen.ContainsKey($key)) { continue }
        $h = $history[$key]
        if (-not (Test-PathUnderRoot -Path $h.ProjectPath -Root $RootDir)) { continue }

        $nameKey = Get-CustomNameKey -ProjectPath $h.ProjectPath -Port $key
        $customName = if ($script:CustomNames.ContainsKey($nameKey)) { $script:CustomNames[$nameKey] } else { '' }

        $managed = $script:ManagedProcesses[(Get-NormalizedPath $h.ProjectPath)]
        $status = 'OFF'
        if ($managed -and $managed.Proc.HasExited -and $managed.Crashed) { $status = 'CRASHED' }

        $rows += [PSCustomObject]@{
            Status      = $status
            Port        = $key
            CustomName  = $customName
            ProcessName = $h.ProcessName
            ProcId      = $null
            LocalUrl    = "http://localhost:$key"
            LanUrls     = ''
            ProjectPath = $h.ProjectPath
            Action      = 'Start'
            HasLog      = [bool]$managed
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
$script:SelectedGroups = @($script:Settings.SelectedGroups | Where-Object { $script:Groups.ContainsKey($_) })

# Processes launched by this app, keyed by normalized project path. Lets us
# capture stdout/stderr and tell "stopped by user" apart from "exited on its
# own" for the one PID this app actually holds a handle to (the npm/cmd
# wrapper) — separate from the PID discovered via TCP scanning below, which
# is often a few process-tree hops downstream of this one.
$script:ManagedProcesses = @{}
$script:LogCap = 1000

function New-ManagedLogLine {
    param([string]$Text)
    return "[$(Get-Date -Format 'HH:mm:ss')] $Text"
}

function Add-ManagedLog {
    param($Entry, [string]$Text)
    if (-not $Text) { return }
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -eq '') { continue }
        $Entry.Log.Enqueue((New-ManagedLogLine $line))
        $discard = $null
        while ($Entry.Log.Count -gt $script:LogCap) { [void]$Entry.Log.TryDequeue([ref]$discard) }
    }
}

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

# ---------------------------------------------------------------------------
# On/off toggle switch (pill + sliding knob) used in place of plain
# checkboxes for the top-bar preferences. It's a Panel we own-draw and
# hit-test ourselves — WinForms has no built-in switch control.
# ---------------------------------------------------------------------------
function New-ToggleSwitch {
    param([bool]$Checked = $false)

    $sw = New-Object System.Windows.Forms.Panel
    $sw.Size = New-Object System.Drawing.Size(38, 20)
    $sw.Tag = [PSCustomObject]@{ Checked = $Checked; OnChange = $null }
    $sw.Cursor = [System.Windows.Forms.Cursors]::Hand

    $sw.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $isOn = $s.Tag.Checked
        $bg = if ($isOn) { [System.Drawing.Color]::FromArgb(46, 160, 67) } else { [System.Drawing.Color]::FromArgb(130, 130, 135) }
        $d = $s.Height
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc(0, 0, $d, $d, 90, 180)
        $path.AddArc($s.Width - $d, 0, $d, $d, 270, 180)
        $path.CloseFigure()
        $brush = New-Object System.Drawing.SolidBrush($bg)
        $g.FillPath($brush, $path)
        $brush.Dispose()
        $path.Dispose()
        $knobD = $d - 4
        $knobX = if ($isOn) { $s.Width - $knobD - 2 } else { 2 }
        $g.FillEllipse([System.Drawing.Brushes]::White, $knobX, 2, $knobD, $knobD)
    })
    $sw.Add_Click({ param($s, $e) Invoke-ToggleClick -Switch $s })
    return $sw
}

function Invoke-ToggleClick {
    param($Switch)
    $Switch.Tag.Checked = -not $Switch.Tag.Checked
    $Switch.Invalidate()
    if ($Switch.Tag.OnChange) { & $Switch.Tag.OnChange }
}

function Get-ToggleChecked {
    param($Switch)
    return [bool]$Switch.Tag.Checked
}

function Set-ToggleChecked {
    param($Switch, [bool]$Value)
    $Switch.Tag.Checked = $Value
    $Switch.Invalidate()
}

function Set-ToggleOnChange {
    param($Switch, [scriptblock]$Handler)
    $Switch.Tag.OnChange = $Handler
}

function Connect-ToggleLabel {
    # Lets clicking the caption label toggle the switch next to it too.
    param($Switch, $Label)
    $Label.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Label.Add_Click({ Invoke-ToggleClick -Switch $Switch }.GetNewClosure())
}

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

$nodeOnlySwitch = New-ToggleSwitch -Checked $script:Settings.OnlyNode
$nodeOnlySwitch.Location = New-Object System.Drawing.Point(100, 10)

$nodeOnlyLabel = New-Object System.Windows.Forms.Label
$nodeOnlyLabel.Text = 'Node/npm projects only'
$nodeOnlyLabel.Location = New-Object System.Drawing.Point(143, 11)
$nodeOnlyLabel.Size = New-Object System.Drawing.Size(150, 20)

$settingsButton = New-Object System.Windows.Forms.Button
$settingsButton.Text = 'Settings...'
$settingsButton.Location = New-Object System.Drawing.Point(298, 8)
$settingsButton.Size = New-Object System.Drawing.Size(80, 24)

$useGroupsSwitch = New-ToggleSwitch -Checked $script:Settings.ShowGroups
$useGroupsSwitch.Location = New-Object System.Drawing.Point(388, 10)

$useGroupsLabel = New-Object System.Windows.Forms.Label
$useGroupsLabel.Text = 'Use Groups'
$useGroupsLabel.Location = New-Object System.Drawing.Point(431, 11)
$useGroupsLabel.Size = New-Object System.Drawing.Size(85, 20)

$scopeLabel = New-Object System.Windows.Forms.Label
$scopeLabel.Text = ''
$scopeLabel.Location = New-Object System.Drawing.Point(525, 12)
$scopeLabel.Size = New-Object System.Drawing.Size(180, 20)
$scopeLabel.ForeColor = [System.Drawing.Color]::SteelBlue
$scopeLabel.AutoEllipsis = $true

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = ''
$statusLabel.Location = New-Object System.Drawing.Point(710, 12)
$statusLabel.Size = New-Object System.Drawing.Size(200, 20)
$statusLabel.ForeColor = [System.Drawing.Color]::DimGray
$statusLabel.TextAlign = 'MiddleRight'

$groupLabel = New-Object System.Windows.Forms.Label
$groupLabel.Text = 'Group:'
$groupLabel.Location = New-Object System.Drawing.Point(10, 48)
$groupLabel.Size = New-Object System.Drawing.Size(45, 20)

$groupsButton = New-Object System.Windows.Forms.Button
$groupsButton.Text = 'Groups: none selected'
$groupsButton.TextAlign = 'MiddleLeft'
$groupsButton.Location = New-Object System.Drawing.Point(55, 44)
$groupsButton.Size = New-Object System.Drawing.Size(170, 24)

# Multi-select "dropdown": a plain Button that pops open a checked-list so
# 2+ groups can be active in the table at once (a normal ComboBox only
# ever lets you pick one).
$groupsPopup = New-Object System.Windows.Forms.ToolStripDropDown
$groupsPopup.AutoClose = $true
$groupsPopup.Padding = New-Object System.Windows.Forms.Padding(2)

$groupsCheckedList = New-Object System.Windows.Forms.CheckedListBox
$groupsCheckedList.CheckOnClick = $true
$groupsCheckedList.BorderStyle = 'None'
$groupsCheckedList.IntegralHeight = $false
$groupsCheckedList.Size = New-Object System.Drawing.Size(200, 130)

$groupsListHost = New-Object System.Windows.Forms.ToolStripControlHost($groupsCheckedList)
$groupsListHost.AutoSize = $false
$groupsListHost.Size = $groupsCheckedList.Size
$groupsListHost.Margin = New-Object System.Windows.Forms.Padding(0)
$groupsPopup.Items.Add($groupsListHost) | Out-Null

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

[System.Windows.Forms.Control[]]$topControls = @($refreshButton, $nodeOnlySwitch, $nodeOnlyLabel, $settingsButton, $useGroupsSwitch, $useGroupsLabel, $scopeLabel, $statusLabel, $groupLabel, $groupsButton, $startAllButton, $stopAllButton, $manageGroupsButton)
$topPanel.Controls.AddRange($topControls)
Connect-ToggleLabel -Switch $nodeOnlySwitch -Label $nodeOnlyLabel
Connect-ToggleLabel -Switch $useGroupsSwitch -Label $useGroupsLabel

function Update-GroupsVisibility {
    $show = Get-ToggleChecked $useGroupsSwitch
    $groupLabel.Visible = $show
    $groupsButton.Visible = $show
    $startAllButton.Visible = $show
    $stopAllButton.Visible = $show
    $manageGroupsButton.Visible = $show
    $topPanel.Height = if ($show) { 76 } else { 40 }
    if ($grid) {
        $grid.Location = New-Object System.Drawing.Point(0, $topPanel.Height)
        $grid.Size = New-Object System.Drawing.Size($form.ClientSize.Width, ($form.ClientSize.Height - $topPanel.Height))
    }
}

function Update-GroupsButtonText {
    $count = $script:SelectedGroups.Count
    $groupsButton.Text = if ($count -eq 0) { 'Groups: none selected' } elseif ($count -eq 1) { "Group: $($script:SelectedGroups[0])" } else { "Groups: $count selected" }
}

function Sync-GroupsCheckedList {
    $groupsCheckedList.Items.Clear()
    foreach ($name in ($script:Groups.Keys | Sort-Object)) {
        $isChecked = $script:SelectedGroups -contains $name
        $groupsCheckedList.Items.Add($name, $isChecked) | Out-Null
    }
}

$groupsCheckedList.Add_ItemCheck({
    param($s, $e)
    $name = $groupsCheckedList.Items[$e.Index]
    $isChecked = ($e.NewValue -eq [System.Windows.Forms.CheckState]::Checked)
    if ($isChecked) {
        if ($script:SelectedGroups -notcontains $name) { $script:SelectedGroups = @($script:SelectedGroups + $name) }
    } else {
        $script:SelectedGroups = @($script:SelectedGroups | Where-Object { $_ -ne $name })
    }
    $script:Settings.SelectedGroups = $script:SelectedGroups
    Save-Settings $script:Settings
    Update-GroupsButtonText
    Refresh-Grid
})

$groupsButton.Add_Click({
    Sync-GroupsCheckedList
    $groupsPopup.Show($groupsButton, (New-Object System.Drawing.Point(0, $groupsButton.Height)))
})

Update-GroupsButtonText

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

$colLog = New-Object System.Windows.Forms.DataGridViewButtonColumn
$colLog.Name = 'Log'; $colLog.HeaderText = ''; $colLog.FillWeight = 65; $colLog.Text = 'View Log'
$colLog.UseColumnTextForButtonValue = $true
$colLog.ReadOnly = $true

$colAction = New-Object System.Windows.Forms.DataGridViewButtonColumn
$colAction.Name = 'Action'; $colAction.HeaderText = ''; $colAction.FillWeight = 60
$colAction.UseColumnTextForButtonValue = $false
$colAction.ReadOnly = $true

[System.Windows.Forms.DataGridViewColumn[]]$gridColumns = @($colStatus, $colPort, $colCustomName, $colProc, $colPid, $colLocal, $colLan, $colPath, $colLog, $colAction)
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

function Add-DataRow {
    param($r)
    $idx = $grid.Rows.Add($r.Status, $r.Port, $r.CustomName, $r.ProcessName, $r.ProcId, $r.LocalUrl, $r.LanUrls, $r.ProjectPath, 'View Log', $r.Action)
    $row = $grid.Rows[$idx]
    $row.Tag = $r
    switch ($r.Status) {
        'ON'      { $row.Cells['Status'].Style.ForeColor = [System.Drawing.Color]::ForestGreen }
        'CRASHED' {
            $row.Cells['Status'].Style.ForeColor = [System.Drawing.Color]::OrangeRed
            $row.Cells['Status'].Style.Font = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Bold)
        }
        default   { $row.Cells['Status'].Style.ForeColor = [System.Drawing.Color]::Gray }
    }
}

function Add-SeparatorRow {
    $idx = $grid.Rows.Add('', '', '', '', '', '', '', '', '', '')
    $row = $grid.Rows[$idx]
    $row.Tag = 'separator'
    $row.Height = 6
    $row.ReadOnly = $true
    $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::SteelBlue
    $row.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::SteelBlue
    foreach ($colName in @('Log', 'Action')) {
        $row.Cells[$colName] = New-Object System.Windows.Forms.DataGridViewTextBoxCell
    }
}

function Get-DisplayRows {
    # Use Groups active: the selected group(s) define exactly what's shown,
    # and they always stay visible even if Node/npm-only or the root-dir
    # scope would otherwise have hidden them. Each entry is tagged with its
    # Group (or $null when ungrouped) so the grid can draw separators.
    $useGroups = (Get-ToggleChecked $useGroupsSwitch) -and $script:SelectedGroups.Count -gt 0
    if ($useGroups) {
        $sourceRows = @(Build-Rows -OnlyNode $false -RootDir '')
        return @(Get-GroupRowsOrdered -Rows $sourceRows -GroupNames $script:SelectedGroups)
    }
    $rows = @(Build-Rows -OnlyNode (Get-ToggleChecked $nodeOnlySwitch) -RootDir $script:RootDir)
    return @($rows | ForEach-Object { [PSCustomObject]@{ Row = $_; Group = $null } })
}

function Get-DisplayRowsSignature {
    param($Display)
    return ($Display | ForEach-Object {
        "$($_.Group)|$($_.Row.Status)|$($_.Row.Port)|$($_.Row.ProcId)|$($_.Row.CustomName)|$($_.Row.ProjectPath)|$($_.Row.Action)|$([bool]$_.Row.HasLog)"
    }) -join "`n"
}

function Render-Grid {
    param($Display)
    $grid.SuspendLayout()
    try {
        $grid.Rows.Clear()
        $lastGroup = $null
        foreach ($d in $Display) {
            if ($null -ne $d.Group -and $null -ne $lastGroup -and $d.Group -ne $lastGroup) { Add-SeparatorRow }
            Add-DataRow -r $d.Row
            $lastGroup = $d.Group
        }
        $grid.ClearSelection()
    } finally {
        $grid.ResumeLayout()
    }
}

$script:FlashTimer = New-Object System.Windows.Forms.Timer
$script:FlashTimer.Interval = 350
$script:FlashTimer.Add_Tick({
    $statusLabel.ForeColor = [System.Drawing.Color]::DimGray
    $script:FlashTimer.Stop()
})

function Flash-StatusLabel {
    $statusLabel.ForeColor = [System.Drawing.Color]::Crimson
    $script:FlashTimer.Stop()
    $script:FlashTimer.Start()
}

function Refresh-Grid {
    # Full, forced rebuild — used for direct user actions (Refresh button,
    # toggles, settings/group changes, start/stop) where the grid content
    # is expected to change right away.
    if ($grid.IsCurrentCellInEditMode) { return }
    $display = @(Get-DisplayRows)
    Render-Grid -Display $display
    $script:LastRowsSignature = Get-DisplayRowsSignature $display
    $statusLabel.Text = "Last refreshed: $(Get-Date -Format 'HH:mm:ss')  |  $($display.Count) shown"
    Update-TrayIcon
    Flash-StatusLabel
}

function Invoke-PeriodicRefresh {
    # Runs every tick, but only repaints the grid when something in it
    # actually changed — otherwise the table would visibly flicker/reset
    # selection every few seconds for no reason. The corner status label
    # flashes red on every tick regardless, so it's still obvious the app
    # is alive and polling.
    if ($grid.IsCurrentCellInEditMode) { Flash-StatusLabel; return }
    $display = @(Get-DisplayRows)
    $sig = Get-DisplayRowsSignature $display
    if ($sig -ne $script:LastRowsSignature) {
        Render-Grid -Display $display
        $script:LastRowsSignature = $sig
    }
    $statusLabel.Text = "Last refreshed: $(Get-Date -Format 'HH:mm:ss')  |  $($display.Count) shown"
    Update-TrayIcon
    Flash-StatusLabel
}

function Start-ProjectAtPath {
    param([string]$ProjectPath)
    try {
        $key = Get-NormalizedPath $ProjectPath

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'cmd.exe'
        $psi.Arguments = "/c cd /d `"$ProjectPath`" && npm start"
        $psi.WorkingDirectory = $ProjectPath
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $proc.EnableRaisingEvents = $true

        $entry = @{
            Proc          = $proc
            Log           = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
            StoppedByUser = $false
            Crashed       = $false
        }
        $script:ManagedProcesses[$key] = $entry

        # Register-ObjectEvent (not .add_EventName(scriptblock)) is required
        # here: Process events fire on a ThreadPool thread, and hooking a raw
        # scriptblock directly onto a .NET event runs it on that thread,
        # which corrupts this single-threaded runspace and silently kills
        # the whole app. Register-ObjectEvent queues the action to run
        # safely on the engine's own event-processing thread instead.
        $subPrefix = "LHM_$([guid]::NewGuid().ToString('N'))"
        $eventData = @{ Entry = $entry; ProjectPath = $ProjectPath; SubPrefix = $subPrefix }

        Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -SourceIdentifier "$subPrefix`_out" -MessageData $eventData -Action {
            if ($null -ne $Event.SourceEventArgs.Data) { Add-ManagedLog -Entry $Event.MessageData.Entry -Text $Event.SourceEventArgs.Data }
        } | Out-Null
        Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -SourceIdentifier "$subPrefix`_err" -MessageData $eventData -Action {
            if ($null -ne $Event.SourceEventArgs.Data) { Add-ManagedLog -Entry $Event.MessageData.Entry -Text $Event.SourceEventArgs.Data }
        } | Out-Null
        Register-ObjectEvent -InputObject $proc -EventName Exited -SourceIdentifier "$subPrefix`_exit" -MessageData $eventData -Action {
            $e = $Event.MessageData.Entry
            if ($e.StoppedByUser) {
                Add-ManagedLog -Entry $e -Text '*** stopped ***'
            } else {
                $e.Crashed = $true
                $code = $e.Proc.ExitCode
                Add-ManagedLog -Entry $e -Text "*** process exited unexpectedly (exit code $code) ***"
                try {
                    $label = Split-Path -Leaf $Event.MessageData.ProjectPath
                    $notifyIcon.ShowBalloonTip(4000, 'Localhost Manager', "$label crashed (exit code $code).", [System.Windows.Forms.ToolTipIcon]::Warning)
                } catch {}
            }
            $p = $Event.MessageData.SubPrefix
            Unregister-Event -SourceIdentifier "${p}_out" -ErrorAction SilentlyContinue
            Unregister-Event -SourceIdentifier "${p}_err" -ErrorAction SilentlyContinue
            Unregister-Event -SourceIdentifier "${p}_exit" -ErrorAction SilentlyContinue
        } | Out-Null

        [void]$proc.Start()
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()

        return $true
    } catch {
        return $false
    }
}

function Stop-ProjectById {
    param([int]$ProcId, [string]$ProjectPath)

    $managed = $script:ManagedProcesses[(Get-NormalizedPath $ProjectPath)]
    if ($managed -and -not $managed.Proc.HasExited) {
        $managed.StoppedByUser = $true
        try {
            Start-Process -FilePath 'taskkill.exe' -ArgumentList "/PID $($managed.Proc.Id) /T /F" -WindowStyle Hidden -Wait | Out-Null
        } catch {}
        # Safety net: the discovered listening PID is sometimes a grandchild
        # a couple of hops below the wrapper we hold a handle to, and
        # taskkill /T occasionally misses a detached descendant.
        try {
            if (Get-Process -Id $ProcId -ErrorAction SilentlyContinue) {
                Stop-Process -Id $ProcId -Force -ErrorAction SilentlyContinue
            }
        } catch {}
        return $true
    }

    try {
        Stop-Process -Id $ProcId -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Show-Terminal {
    param([string]$ProjectPath, [string]$Title)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Terminal - $Title"
    $dlg.Size = New-Object System.Drawing.Size(780, 520)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimumSize = New-Object System.Drawing.Size(420, 260)
    $dlg.Icon = $script:IconOk

    $outputBox = New-Object System.Windows.Forms.TextBox
    $outputBox.Multiline = $true
    $outputBox.ReadOnly = $true
    $outputBox.ScrollBars = 'Vertical'
    $outputBox.WordWrap = $false
    $outputBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $outputBox.Dock = 'Fill'
    $outputBox.BackColor = [System.Drawing.Color]::Black
    $outputBox.ForeColor = [System.Drawing.Color]::Gainsboro

    $inputPanel = New-Object System.Windows.Forms.Panel
    $inputPanel.Dock = 'Bottom'
    $inputPanel.Height = 32

    $promptLabel = New-Object System.Windows.Forms.Label
    $promptLabel.Text = '>'
    $promptLabel.Location = New-Object System.Drawing.Point(6, 8)
    $promptLabel.Size = New-Object System.Drawing.Size(14, 20)
    $promptLabel.ForeColor = [System.Drawing.Color]::Gainsboro

    $inputBox = New-Object System.Windows.Forms.TextBox
    $inputBox.Location = New-Object System.Drawing.Point(22, 4)
    $inputBox.Anchor = 'Top,Left,Right'
    $inputBox.Size = New-Object System.Drawing.Size(740, 24)
    $inputBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $inputBox.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
    $inputBox.ForeColor = [System.Drawing.Color]::White

    $inputPanel.Controls.Add($promptLabel)
    $inputPanel.Controls.Add($inputBox)
    $dlg.Controls.Add($outputBox)
    $dlg.Controls.Add($inputPanel)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = '/k'
    $psi.WorkingDirectory = $ProjectPath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.EnableRaisingEvents = $true

    $outputQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $subPrefix = "LHMT_$([guid]::NewGuid().ToString('N'))"
    $eventData = @{ Queue = $outputQueue }

    Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -SourceIdentifier "$subPrefix`_out" -MessageData $eventData -Action {
        if ($null -ne $Event.SourceEventArgs.Data) { $Event.MessageData.Queue.Enqueue($Event.SourceEventArgs.Data) }
    } | Out-Null
    Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -SourceIdentifier "$subPrefix`_err" -MessageData $eventData -Action {
        if ($null -ne $Event.SourceEventArgs.Data) { $Event.MessageData.Queue.Enqueue($Event.SourceEventArgs.Data) }
    } | Out-Null

    try {
        [void]$proc.Start()
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not start a terminal: $_", 'Error', 'OK', 'Error') | Out-Null
        return
    }

    $outputBox.AppendText("[Terminal open at: $ProjectPath]`r`n")

    $pumpTimer = New-Object System.Windows.Forms.Timer
    $pumpTimer.Interval = 150
    $pumpTimer.Add_Tick({
        $line = $null
        $appended = $false
        while ($outputQueue.TryDequeue([ref]$line)) {
            $outputBox.AppendText("$line`r`n")
            $appended = $true
        }
        if ($appended) {
            $outputBox.SelectionStart = $outputBox.TextLength
            $outputBox.ScrollToCaret()
        }
    })
    $pumpTimer.Start()

    $inputBox.Add_KeyDown({
        param($s2, $e2)
        if ($e2.KeyCode -ne [System.Windows.Forms.Keys]::Enter) { return }
        $e2.SuppressKeyPress = $true
        $cmd = $inputBox.Text
        $inputBox.Clear()
        if ($proc.HasExited) { return }
        $outputBox.AppendText("> $cmd`r`n")
        try { $proc.StandardInput.WriteLine($cmd) } catch {}
    })

    $dlg.Add_Shown({ $inputBox.Focus() })
    $dlg.Add_FormClosing({
        $pumpTimer.Stop()
        Unregister-Event -SourceIdentifier "$subPrefix`_out" -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier "$subPrefix`_err" -ErrorAction SilentlyContinue
        if (-not $proc.HasExited) {
            try { Start-Process -FilePath 'taskkill.exe' -ArgumentList "/PID $($proc.Id) /T /F" -WindowStyle Hidden -Wait | Out-Null } catch {}
        }
    })

    $dlg.ShowDialog($form) | Out-Null
}

function Invoke-ToggleAction {
    param($data)

    if ($data.Status -eq 'ON') {
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Stop $($data.ProcessName) (PID $($data.ProcId)) listening on port $($data.Port)?",
            'Confirm Stop', 'YesNo', 'Warning')
        if ($confirm -ne 'Yes') { return }
        if (-not (Stop-ProjectById -ProcId $data.ProcId -ProjectPath $data.ProjectPath)) {
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

function Show-LogViewer {
    param([string]$ProjectPath, [string]$Title)

    $key = Get-NormalizedPath $ProjectPath
    $entry = $script:ManagedProcesses[$key]

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Log - $Title"
    $dlg.Size = New-Object System.Drawing.Size(760, 520)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimumSize = New-Object System.Drawing.Size(420, 260)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Multiline = $true
    $textBox.ReadOnly = $true
    $textBox.ScrollBars = 'Vertical'
    $textBox.WordWrap = $false
    $textBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $textBox.Dock = 'Fill'
    $textBox.BackColor = [System.Drawing.Color]::Black
    $textBox.ForeColor = [System.Drawing.Color]::Gainsboro

    $bottomPanel = New-Object System.Windows.Forms.Panel
    $bottomPanel.Dock = 'Bottom'
    $bottomPanel.Height = 40

    $copyButton = New-Object System.Windows.Forms.Button
    $copyButton.Text = 'Copy All'
    $copyButton.Location = New-Object System.Drawing.Point(10, 6)
    $copyButton.Size = New-Object System.Drawing.Size(90, 26)
    $copyButton.Add_Click({ if ($textBox.Text) { [System.Windows.Forms.Clipboard]::SetText($textBox.Text) } })

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = 'Close'
    $closeButton.Anchor = 'Top,Right'
    $closeButton.Location = New-Object System.Drawing.Point(660, 6)
    $closeButton.Size = New-Object System.Drawing.Size(80, 26)
    $closeButton.Add_Click({ $dlg.Close() })

    [System.Windows.Forms.Control[]]$bottomControls = @($copyButton, $closeButton)
    $bottomPanel.Controls.AddRange($bottomControls)
    $dlg.Controls.Add($textBox)
    $dlg.Controls.Add($bottomPanel)

    function Update-LogText {
        if (-not $entry) {
            $textBox.Text = '(No log captured for this project — it was not started via Localhost Manager, or the app was restarted since.)'
            return
        }
        $atBottom = $textBox.SelectionStart -ge ($textBox.TextLength - 2)
        $textBox.Text = ($entry.Log.ToArray() -join "`r`n")
        if ($atBottom) {
            $textBox.SelectionStart = $textBox.TextLength
            $textBox.ScrollToCaret()
        }
    }
    Update-LogText

    if ($entry -and -not $entry.Proc.HasExited) {
        $liveTimer = New-Object System.Windows.Forms.Timer
        $liveTimer.Interval = 1000
        $liveTimer.Add_Tick({ Update-LogText })
        $liveTimer.Start()
        $dlg.Add_FormClosed({ $liveTimer.Stop() })
    }

    $dlg.ShowDialog($form) | Out-Null
}

$grid.Add_CellContentClick({
    param($s, $e)
    if ($e.RowIndex -lt 0) { return }
    $row = $grid.Rows[$e.RowIndex]
    if ($row.Tag -eq 'separator') { return }
    $data = $row.Tag
    if ($e.ColumnIndex -eq $colAction.Index) {
        Invoke-ToggleAction $data
    } elseif ($e.ColumnIndex -eq $colLog.Index) {
        $label = if ($data.CustomName) { $data.CustomName } elseif ($data.ProjectPath) { Split-Path -Leaf $data.ProjectPath } else { "Port $($data.Port)" }
        Show-LogViewer -ProjectPath $data.ProjectPath -Title $label
    }
})

$grid.Add_CellDoubleClick({
    param($s, $e)
    if ($e.RowIndex -lt 0) { return }
    $row = $grid.Rows[$e.RowIndex]
    if ($row.Tag -eq 'separator') { return }
    if ($e.ColumnIndex -eq $colAction.Index -or $e.ColumnIndex -eq $colLog.Index) { return }
    $data = $row.Tag
    if (-not $data) { return }
    if (-not $data.ProjectPath) {
        [System.Windows.Forms.MessageBox]::Show('No known project path for this port.', 'Cannot Open Terminal', 'OK', 'Warning') | Out-Null
        return
    }
    $label = if ($data.CustomName) { $data.CustomName } elseif ($data.ProjectPath) { Split-Path -Leaf $data.ProjectPath } else { "Port $($data.Port)" }
    Show-Terminal -ProjectPath $data.ProjectPath -Title $label
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
        Update-GroupsButtonText
        Refresh-Grid
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
        if ($script:SelectedGroups -contains $name) {
            $script:SelectedGroups = @($script:SelectedGroups | Where-Object { $_ -ne $name })
            $script:Settings.SelectedGroups = $script:SelectedGroups
            Save-Settings $script:Settings
        }
        Update-GroupsButtonText
        Refresh-Grid
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
    param([string[]]$Names)

    $Names = @($Names | Where-Object { $_ -and $script:Groups.ContainsKey($_) })
    if ($Names.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Pick at least one group first (or create one via Manage Groups).', 'No Group Selected', 'OK', 'Warning') | Out-Null
        return
    }
    $label = $Names -join ', '
    $paths = New-Object System.Collections.Generic.HashSet[string]
    foreach ($n in $Names) { foreach ($p in $script:Groups[$n]) { [void]$paths.Add((Get-NormalizedPath $p)) } }
    $allRows = @(Build-Rows -OnlyNode $true -RootDir '')
    $toStart = @($allRows | Where-Object { $_.Status -eq 'OFF' -and $_.ProjectPath -and $paths.Contains((Get-NormalizedPath $_.ProjectPath)) })

    if ($toStart.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Everything in '$label' is already running (or has no known path).", 'Nothing to Start', 'OK', 'Information') | Out-Null
        return
    }
    $started = 0
    foreach ($row in $toStart) {
        if (Start-ProjectAtPath -ProjectPath $row.ProjectPath) { $started++ }
    }
    Start-Sleep -Milliseconds 1000
    Refresh-Grid
    [System.Windows.Forms.MessageBox]::Show("Started $started of $($toStart.Count) project(s) in '$label'.", 'Start All', 'OK', 'Information') | Out-Null
}

function Stop-GroupAll {
    param([string[]]$Names)

    $Names = @($Names | Where-Object { $_ -and $script:Groups.ContainsKey($_) })
    if ($Names.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Pick at least one group first (or create one via Manage Groups).', 'No Group Selected', 'OK', 'Warning') | Out-Null
        return
    }
    $label = $Names -join ', '
    $paths = New-Object System.Collections.Generic.HashSet[string]
    foreach ($n in $Names) { foreach ($p in $script:Groups[$n]) { [void]$paths.Add((Get-NormalizedPath $p)) } }
    $allRows = @(Build-Rows -OnlyNode $true -RootDir '')
    $toStop = @($allRows | Where-Object { $_.Status -eq 'ON' -and $_.ProjectPath -and $paths.Contains((Get-NormalizedPath $_.ProjectPath)) })

    if ($toStop.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Nothing in '$label' is currently running.", 'Nothing to Stop', 'OK', 'Information') | Out-Null
        return
    }
    $list = ($toStop | ForEach-Object { "$($_.ProcessName) (port $($_.Port))" }) -join "`n"
    $confirm = [System.Windows.Forms.MessageBox]::Show("Stop these $($toStop.Count) process(es)?`n`n$list", 'Confirm Stop All', 'YesNo', 'Warning')
    if ($confirm -ne 'Yes') { return }

    $stopped = 0
    foreach ($row in $toStop) {
        if (Stop-ProjectById -ProcId $row.ProcId -ProjectPath $row.ProjectPath) { $stopped++ }
    }
    Refresh-Grid
    [System.Windows.Forms.MessageBox]::Show("Stopped $stopped of $($toStop.Count) process(es) in '$label'.", 'Stop All', 'OK', 'Information') | Out-Null
}

$startAllButton.Add_Click({ Start-GroupAll -Names $script:SelectedGroups })
$stopAllButton.Add_Click({ Stop-GroupAll -Names $script:SelectedGroups })

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
    $crashedCount = @($allRows | Where-Object { $_.Status -eq 'CRASHED' }).Count
    $totalCount = $allRows.Count

    $newIcon = if ($totalCount -gt 0 -and $onCount -lt $totalCount) { $script:IconAlert } else { $script:IconOk }
    if ($notifyIcon.Icon -ne $newIcon) { $notifyIcon.Icon = $newIcon }

    $newText = if ($totalCount -eq 0) {
        'Localhost Manager - no projects yet'
    } elseif ($crashedCount -gt 0) {
        "Localhost Manager - $onCount/$totalCount running ($crashedCount crashed)"
    } else {
        "Localhost Manager - $onCount/$totalCount running"
    }
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
        $emptyText = 'No known npm projects yet'
        $noneItem = New-Object System.Windows.Forms.ToolStripMenuItem $emptyText
        $noneItem.Enabled = $false
        $trayMenu.Items.Add($noneItem) | Out-Null
    } else {
        foreach ($r in $allRows) {
            $projName = if ($r.CustomName) { $r.CustomName } elseif ($r.ProjectPath) { Split-Path -Leaf $r.ProjectPath } else { $r.ProcessName }
            $label = switch ($r.Status) {
                'ON'      { "[ON]      $($r.Port)  $projName" }
                'CRASHED' { "[CRASHED] $($r.Port)  $projName" }
                default   { "[OFF]     $($r.Port)  $projName" }
            }
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
            $startItem.Add_Click({ Start-GroupAll -Names @($capturedName) }.GetNewClosure())
            $groupItem.DropDownItems.Add($startItem) | Out-Null

            $stopItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Stop All'
            $stopItem.Add_Click({ Stop-GroupAll -Names @($capturedName) }.GetNewClosure())
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
        Stop-BackgroundPoller
    }
})

$refreshButton.Add_Click({ Refresh-Grid })
Set-ToggleOnChange -Switch $nodeOnlySwitch -Handler {
    $script:Settings.OnlyNode = Get-ToggleChecked $nodeOnlySwitch
    Save-Settings $script:Settings
    Refresh-Grid
}
Set-ToggleOnChange -Switch $useGroupsSwitch -Handler {
    $script:Settings.ShowGroups = Get-ToggleChecked $useGroupsSwitch
    Save-Settings $script:Settings
    Update-GroupsVisibility
    Refresh-Grid
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 4000
$timer.Add_Tick({ Invoke-PeriodicRefresh })
$timer.Start()

try {
    $waitStart = [DateTime]::UtcNow
    while (-not $script:LiveCache.Ready -and ([DateTime]::UtcNow - $waitStart).TotalMilliseconds -lt 3000) {
        Start-Sleep -Milliseconds 50
    }
    Refresh-Grid
} catch {
    [System.Windows.Forms.MessageBox]::Show("Startup error: $_", 'Error') | Out-Null
}
[System.Windows.Forms.Application]::Run($form)
