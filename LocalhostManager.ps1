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
                Pinned      = if ($prop.Value.PSObject.Properties.Name -contains 'Pinned') { [bool]$prop.Value.Pinned } else { $false }
                CommandLine = if ($prop.Value.PSObject.Properties.Name -contains 'CommandLine') { [string]$prop.Value.CommandLine } else { $null }
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
    # DashboardEnabled defaults to $false: the web dashboard is opt-in,
    # never auto-started on a fresh install. The end user turns it on (and
    # picks a port) themselves via the Dashboard menu.
    $defaults = @{ OnlyNode = $true; RootDir = ''; ShowGroups = $true; SelectedGroups = @(); WebPort = 3199; DashboardEnabled = $false; ShowSystemPorts = $false }
    if (-not (Test-Path $script:SettingsPath)) { return $defaults }
    try {
        $raw = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
        $showGroups = if ($raw.PSObject.Properties.Name -contains 'ShowGroups') { [bool]$raw.ShowGroups } else { $true }
        $selectedGroups = if ($raw.PSObject.Properties.Name -contains 'SelectedGroups') { @($raw.SelectedGroups) } else { @() }
        $webPort = if ($raw.PSObject.Properties.Name -contains 'WebPort' -and [int]$raw.WebPort -gt 0) { [int]$raw.WebPort } else { 3199 }
        $dashboardEnabled = if ($raw.PSObject.Properties.Name -contains 'DashboardEnabled') { [bool]$raw.DashboardEnabled } else { $false }
        $showSystemPorts = if ($raw.PSObject.Properties.Name -contains 'ShowSystemPorts') { [bool]$raw.ShowSystemPorts } else { $false }
        return @{
            OnlyNode         = [bool]$raw.OnlyNode
            RootDir          = [string]$raw.RootDir
            ShowGroups       = $showGroups
            SelectedGroups   = $selectedGroups
            WebPort          = $webPort
            DashboardEnabled = $dashboardEnabled
            ShowSystemPorts  = $showSystemPorts
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

# Also doubles as the "system-owned" classification for the System tab
# (see IsSystem below) - these names never show as manageable dev-server
# rows on Live/History, but a port bound by one of them (e.g. the kernel
# http.sys listener behind .NET's HttpListener, which reports as PID 4
# "System") can still be surfaced read-only there.
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

# ---------------------------------------------------------------------------
# Web dashboard cache. Shared with the HttpListener background runspace
# (see "Web Dashboard" section near the bottom): the UI thread publishes a
# JSON row snapshot into it on every refresh, and the listener thread only
# ever reads from it. Stop/restart requests flow the other way through the
# Actions queue + Results map so the listener thread never has to call back
# into UI-thread-owned functions/state directly across the runspace
# boundary. Initialized here (not lazily) so early startup calls to
# Refresh-Grid, before the listener itself has started, have somewhere
# safe to publish into.
# ---------------------------------------------------------------------------
$script:DashboardCache = [hashtable]::Synchronized(@{
    RowsJson      = '[]'
    Actions       = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    Results       = [hashtable]::Synchronized(@{})
    StopRequested = $false
    Port          = 0
    Addresses     = @()
    BoundWildcard = $false
    Listening     = $false
    ListenError   = ''
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

    function Get-ProcessCommandLine {
        # Same PEB walk as Get-ProcessWorkingDirectory above (same process
        # handle, same RTL_USER_PROCESS_PARAMETERS struct) but reads the
        # CommandLine UNICODE_STRING at offset 0x70 instead of
        # CurrentDirectory's DosPath at 0x38 - the exact argv the process is
        # actually running with (e.g. "python -m http.server 8792"), which
        # Start/Restart can replay later for anything that isn't an npm
        # project and so has no "npm run <script>" to fall back to.
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
            [void][LocalhostManager.ProcCwd]::ReadProcessMemory($hProcess, [IntPtr]::Add($processParams, 0x70), $usBuf, 16, [ref]$read)
            $length = [BitConverter]::ToUInt16($usBuf, 0)
            $bufferPtr = [IntPtr][BitConverter]::ToInt64($usBuf, 8)
            if ($length -le 0 -or $length -gt 65536) { return $null }

            $strBuf = New-Object byte[] $length
            [void][LocalhostManager.ProcCwd]::ReadProcessMemory($hProcess, $bufferPtr, $strBuf, $length, [ref]$read)
            return [System.Text.Encoding]::Unicode.GetString($strBuf, 0, $read).Trim()
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

                # System-owned processes (System/svchost/lsass/...) never get a
                # cwd/package.json probe - it's wasted work (they have no
                # meaningful project cwd) and, for protected processes, a
                # ReadProcessMemory attempt that can only fail anyway.
                $isSystem = $ExcludedNames -contains $procName
                $cwd = $null
                $isNode = $false
                $commandLine = $null
                if (-not $isSystem) {
                    $cwd = Get-ProcessWorkingDirectory -ProcId $procId
                    if ($cwd) { $isNode = Test-Path (Join-Path $cwd 'package.json') -ErrorAction SilentlyContinue }
                    $commandLine = Get-ProcessCommandLine -ProcId $procId
                }

                $result[$key] = @{
                    Port        = $key
                    ProcId      = $procId
                    ProcessName = $procName
                    LocalAddr   = $c.LocalAddress
                    ProjectPath = $cwd
                    IsNode      = [bool]$isNode
                    IsSystem    = $isSystem
                    CommandLine = $commandLine
                }
            }

            # Keep the InterfaceAlias alongside each IP (not just the flat
            # address) so the main script can label/sort/flag entries by
            # adapter type (Ethernet vs Tailscale vs a VMware/virtual
            # adapter) - this runspace has no access to functions defined in
            # the main script scope, so that classification happens later,
            # in Build-Rows.
            $lanEntries = @()
            $seenLanIp = @{}
            foreach ($ipInfo in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' })) {
                if ($seenLanIp.ContainsKey($ipInfo.IPAddress)) { continue }
                $seenLanIp[$ipInfo.IPAddress] = $true
                $lanEntries += [PSCustomObject]@{ IPAddress = $ipInfo.IPAddress; InterfaceAlias = $ipInfo.InterfaceAlias }
            }

            $Cache.Listeners = $result
            $Cache.LanIps    = $lanEntries
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

function Get-NetworkInterfaceLabel {
    # Classifies an adapter by its InterfaceAlias so Network URL rows can
    # show which "layer" an address actually belongs to, be ordered with
    # the useful ones first, and flag anything that's only reachable from
    # this machine itself (a hypervisor's NAT/host-only adapter) rather
    # than a real LAN/Tailnet address.
    param([string]$InterfaceAlias)
    if (-not $InterfaceAlias) {
        return [PSCustomObject]@{ Label = 'Network'; IsVirtual = $false; SortRank = 1 }
    }
    switch -Regex ($InterfaceAlias) {
        'Tailscale'          { return [PSCustomObject]@{ Label = 'Tailscale';   IsVirtual = $false; SortRank = 1 } }
        'Wi-?Fi|Wireless'    { return [PSCustomObject]@{ Label = 'Wi-Fi';       IsVirtual = $false; SortRank = 0 } }
        'Ethernet'           { return [PSCustomObject]@{ Label = 'Ethernet';    IsVirtual = $false; SortRank = 0 } }
        'VMware'             { return [PSCustomObject]@{ Label = 'VMware';     IsVirtual = $true;  SortRank = 2 } }
        'Hyper-V|vEthernet'  { return [PSCustomObject]@{ Label = 'Hyper-V';    IsVirtual = $true;  SortRank = 2 } }
        'VirtualBox'         { return [PSCustomObject]@{ Label = 'VirtualBox';IsVirtual = $true;  SortRank = 2 } }
        'Docker'             { return [PSCustomObject]@{ Label = 'Docker';    IsVirtual = $true;  SortRank = 2 } }
        default              { return [PSCustomObject]@{ Label = $InterfaceAlias; IsVirtual = $false; SortRank = 1 } }
    }
}

function Build-Rows {
    param([bool]$OnlyNode, [string]$RootDir)

    $live = Get-LiveListeners
    $history = Load-History
    $lanIps = @(Get-LanIPv4Addresses)

    # A pinned port is remembered here regardless of IsNode - that's the
    # whole point of pinning: keep tracking something (even a non-npm
    # process) through a shutdown so History can offer it back later. A
    # plain (unpinned) entry is still only tracked while it's a recognized
    # Node project, same as before.
    foreach ($key in $live.Keys) {
        $e = $live[$key]
        if ($e.IsSystem) { continue }
        $pinned = $history.ContainsKey($key) -and [bool]$history[$key].Pinned
        if ($e.IsNode -or $pinned) {
            $history[$key] = @{ ProjectPath = $e.ProjectPath; ProcessName = $e.ProcessName; Pinned = $pinned; CommandLine = $e.CommandLine }
        }
    }
    Save-History $history

    $rows = @()
    $seen = @{}

    foreach ($key in ($live.Keys | Sort-Object { [int]$_ })) {
        $e = $live[$key]
        if ($e.IsSystem) { continue }
        $pinned = $history.ContainsKey($key) -and [bool]$history[$key].Pinned
        # Pinning bypasses Dev-Servers-Only too - same "stays visible
        # regardless of the filter" idea Use Groups already gets.
        if ($OnlyNode -and -not $e.IsNode -and -not $pinned) { continue }
        if (-not (Test-PathUnderRoot -Path $e.ProjectPath -Root $RootDir)) { continue }
        $seen[$key] = $true

        $lanUrls = ''
        $lanEntries = @()
        if ($e.LocalAddr -eq '0.0.0.0' -or $e.LocalAddr -eq '::') {
            $lanEntries = @($lanIps | ForEach-Object {
                $info = Get-NetworkInterfaceLabel -InterfaceAlias $_.InterfaceAlias
                [PSCustomObject]@{
                    Label     = $info.Label
                    Url       = "http://$($_.IPAddress):$key"
                    IsVirtual = $info.IsVirtual
                    SortRank  = $info.SortRank
                }
            } | Sort-Object SortRank, Label)
            $lanUrls = ($lanEntries | ForEach-Object { $_.Url }) -join ', '
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
            LanEntries  = $lanEntries
            ProjectPath = $e.ProjectPath
            Action      = 'Stop'
            HasLog      = [bool]$managed
            Pinned      = $pinned
            CommandLine = $e.CommandLine
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
            LanEntries  = @()
            ProjectPath = $h.ProjectPath
            Action      = 'Start'
            HasLog      = [bool]$managed
            Pinned      = [bool]$h.Pinned
            CommandLine = $h.CommandLine
        }
    }

    return $rows | Sort-Object { [int]$_.Port }
}

function Build-SystemRows {
    # Read-only counterpart to Build-Rows for the System tab: ports owned by
    # OS-level processes (System/svchost/lsass/...), most commonly a kernel
    # http.sys listener behind .NET's HttpListener (shows as PID 4 "System")
    # rather than the app that actually registered it. No OnlyNode/RootDir
    # scoping - these have no project path to scope by - and never feed
    # history.json (that only ever tracks IsNode entries, see Build-Rows).
    $live = Get-LiveListeners
    $lanIps = @(Get-LanIPv4Addresses)
    $rows = @()

    foreach ($key in ($live.Keys | Sort-Object { [int]$_ })) {
        $e = $live[$key]
        if (-not $e.IsSystem) { continue }

        $lanUrls = ''
        $lanEntries = @()
        if ($e.LocalAddr -eq '0.0.0.0' -or $e.LocalAddr -eq '::') {
            $lanEntries = @($lanIps | ForEach-Object {
                $info = Get-NetworkInterfaceLabel -InterfaceAlias $_.InterfaceAlias
                [PSCustomObject]@{
                    Label     = $info.Label
                    Url       = "http://$($_.IPAddress):$key"
                    IsVirtual = $info.IsVirtual
                    SortRank  = $info.SortRank
                }
            } | Sort-Object SortRank, Label)
            $lanUrls = ($lanEntries | ForEach-Object { $_.Url }) -join ', '
        } else {
            $lanUrls = '(localhost only)'
        }

        $nameKey = Get-CustomNameKey -ProjectPath '' -Port $key
        $customName = if ($script:CustomNames.ContainsKey($nameKey)) { $script:CustomNames[$nameKey] } else { '' }

        $rows += [PSCustomObject]@{
            Status      = 'ON'
            Port        = $key
            CustomName  = $customName
            ProcessName = $e.ProcessName
            ProcId      = $e.ProcId
            LocalUrl    = "http://localhost:$key"
            LanUrls     = $lanUrls
            LanEntries  = $lanEntries
            ProjectPath = ''
            Action      = ''
            HasLog      = $false
        }
    }

    return $rows | Sort-Object { [int]$_.Port }
}

# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------------
# Single-instance guard. A named Mutex is process-independent (unlike a
# lock file), so it can't be left stale by a crash — Windows releases it
# automatically when the owning process exits.
# ---------------------------------------------------------------------------
$script:SingleInstanceCreatedNew = $false
$script:SingleInstanceMutex = New-Object System.Threading.Mutex($true, 'LocalhostManager_SingleInstance_Mutex', [ref]$script:SingleInstanceCreatedNew)
if (-not $script:SingleInstanceCreatedNew) {
    [System.Windows.Forms.MessageBox]::Show('Localhost Manager is already running. Check your system tray.', 'Localhost Manager', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    exit
}

# ---------------------------------------------------------------------------
# Theme — flat, light, GNOME/Adwaita-inspired palette. Swapped in for the
# default WinForms 3D-bevel gray look: flat bordered buttons with rounded
# corners, a real background/foreground color system, and a white grid
# instead of the OS default ButtonFace gray filling unused rows.
# ---------------------------------------------------------------------------
$script:Theme = @{
    WindowBg    = [System.Drawing.Color]::FromArgb(0xFA, 0xFA, 0xFA)
    PanelBg     = [System.Drawing.Color]::FromArgb(0xF2, 0xF1, 0xF0)
    CardBg      = [System.Drawing.Color]::White
    Border      = [System.Drawing.Color]::FromArgb(0xD1, 0xD1, 0xD1)
    TextPrimary = [System.Drawing.Color]::FromArgb(0x2E, 0x34, 0x36)
    TextDim     = [System.Drawing.Color]::FromArgb(0x77, 0x76, 0x7B)
    Accent      = [System.Drawing.Color]::FromArgb(0x35, 0x84, 0xE4)
    AccentDark  = [System.Drawing.Color]::FromArgb(0x1C, 0x71, 0xD8)
    AccentTint  = [System.Drawing.Color]::FromArgb(0xE3, 0xEE, 0xFB)
    Success     = [System.Drawing.Color]::FromArgb(0x26, 0xA2, 0x69)
    SuccessTint = [System.Drawing.Color]::FromArgb(0xE3, 0xF6, 0xEC)
    Danger      = [System.Drawing.Color]::FromArgb(0xC0, 0x1C, 0x28)
    DangerTint  = [System.Drawing.Color]::FromArgb(0xFB, 0xE6, 0xE7)
    RowAlt      = [System.Drawing.Color]::FromArgb(0xF7, 0xF6, 0xF5)
}

function Initialize-ModernButton {
    # Fully owner-drawn button: a Region-based clip would leave hard,
    # stair-stepped corners (Region has no anti-aliasing). Instead this
    # erases the button to its parent's background color, then fills +
    # strokes an anti-aliased rounded-rect path and draws the text itself,
    # for genuinely smooth "vector" corners with proper hover/press states.
    # Neutral = white with a gray border. Accent/Success/Danger keep a white
    # fill but swap the border + text color, so semantic buttons (Save,
    # Delete, Stop All) read as colored without becoming a solid block.
    param($Button, [string]$Variant = 'Neutral', [int]$Radius = 8)

    switch ($Variant) {
        'Accent'  { $fg = $script:Theme.Accent;  $borderNormal = $script:Theme.Border;  $fillActive = $script:Theme.AccentTint;  $borderActive = $script:Theme.Accent }
        'Success' { $fg = $script:Theme.Success; $borderNormal = $script:Theme.Success; $fillActive = $script:Theme.SuccessTint; $borderActive = $script:Theme.Success }
        'Danger'  { $fg = $script:Theme.Danger;  $borderNormal = $script:Theme.Danger;  $fillActive = $script:Theme.DangerTint;  $borderActive = $script:Theme.Danger }
        default   { $fg = $script:Theme.TextPrimary; $borderNormal = $script:Theme.Border; $fillActive = $script:Theme.PanelBg; $borderActive = $script:Theme.Border }
    }

    $Button.FlatStyle = 'Flat'
    $Button.FlatAppearance.BorderSize = 0
    $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::Transparent
    $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::Transparent
    $Button.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.UseVisualStyleBackColor = $false
    $Button.Tag = [PSCustomObject]@{
        State = 'Normal'; Fg = $fg; BorderNormal = $borderNormal; FillActive = $fillActive; BorderActive = $borderActive; Radius = $Radius
    }

    $dbProp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance, NonPublic')
    $dbProp.SetValue($Button, $true, $null)

    $Button.Add_MouseEnter({ param($s, $e) $s.Tag.State = 'Hover'; $s.Invalidate() })
    $Button.Add_MouseLeave({ param($s, $e) $s.Tag.State = 'Normal'; $s.Invalidate() })
    $Button.Add_MouseDown({ param($s, $e) $s.Tag.State = 'Pressed'; $s.Invalidate() })
    $Button.Add_MouseUp({ param($s, $e) $s.Tag.State = 'Hover'; $s.Invalidate() })
    $Button.Add_EnabledChanged({ param($s, $e) $s.Tag.State = 'Normal'; $s.Invalidate() })

    $Button.Add_Paint({
        param($s, $e)
        $t = $s.Tag
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $parentColor = if ($s.Parent) { $s.Parent.BackColor } else { [System.Drawing.Color]::White }
        $g.Clear($parentColor)

        $rect = New-Object System.Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
        $d = [Math]::Min($t.Radius * 2, [Math]::Min($rect.Width, $rect.Height))
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
        $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
        $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
        $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
        $path.CloseFigure()

        if (-not $s.Enabled) {
            $fillColor = $parentColor
            $borderColor = $script:Theme.Border
            $textColor = $script:Theme.TextDim
        } else {
            $fillColor = if ($t.State -eq 'Normal') { [System.Drawing.Color]::White } else { $t.FillActive }
            $borderColor = if ($t.State -eq 'Normal') { $t.BorderNormal } else { $t.BorderActive }
            $textColor = $t.Fg
        }
        if ($null -eq $fillColor) { $fillColor = [System.Drawing.Color]::White }
        if ($null -eq $borderColor) { $borderColor = [System.Drawing.Color]::FromArgb(0xD1, 0xD1, 0xD1) }
        if ($null -eq $textColor) { $textColor = [System.Drawing.Color]::Black }

        $fillBrush = New-Object System.Drawing.SolidBrush($fillColor)
        $g.FillPath($fillBrush, $path)
        $fillBrush.Dispose()

        $borderPen = New-Object System.Drawing.Pen($borderColor, 1.4)
        $g.DrawPath($borderPen, $path)
        $borderPen.Dispose()

        $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis
        [System.Windows.Forms.TextRenderer]::DrawText($g, $s.Text, $s.Font, $s.ClientRectangle, $textColor, $flags)

        $path.Dispose()
    })
}

# ---------------------------------------------------------------------------
# Rounds any dropdown/context-menu popup (ToolStripDropDown, the auto-created
# ToolStripDropDownMenu behind a top-level menu item, or a ContextMenuStrip —
# all derive from ToolStripDropDown) by clipping it to a rounded-rect Region
# on every paint, since AutoSize means the final Size isn't known until
# layout, then stroking a matching border so the corners don't look bare.
# ---------------------------------------------------------------------------
function Enable-RoundedPopup {
    param($Popup, [int]$Radius = 8)
    $Popup.BackColor = [System.Drawing.Color]::White
    $paintHandler = {
        param($s, $e)
        if ($s.Width -le 0 -or $s.Height -le 0) { return }
        $rect = New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.Height)
        $d = [Math]::Min($Radius * 2, [Math]::Min($rect.Width, $rect.Height))
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
        $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
        $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
        $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
        $path.CloseFigure()
        $s.Region = New-Object System.Drawing.Region($path)
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $borderColor = $script:Theme.Border
        if ($null -ne $borderColor) {
            $borderPen = New-Object System.Drawing.Pen($borderColor, 1)
            $e.Graphics.DrawPath($borderPen, $path)
            $borderPen.Dispose()
        }
        $path.Dispose()
    }.GetNewClosure()
    $Popup.Add_Paint($paintHandler)
}

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
$script:LogDir = Join-Path $script:HistoryDir 'logs'
$script:LogDiskCap = 2000

function New-ManagedLogLine {
    param([string]$Text)
    return "[$(Get-Date -Format 'HH:mm:ss')] $Text"
}

function Get-ProjectLogFilePath {
    # In-memory logs (below) don't survive the app restarting — the process
    # handle/redirected-output streams they depend on are gone the moment
    # this app's own process exits, even if the launched dev server itself
    # is still running. Mirroring each line to a per-project file here is
    # what lets Show-LogViewer still show history after a restart (app
    # update, crash, machine sleep/wake killing the tray process, etc).
    param([string]$ProjectPath)
    $key = Get-NormalizedPath $ProjectPath
    if (-not $key) { return $null }
    $safe = ($key -replace '[:\\/]', '_') -replace '[^a-z0-9_\-. ]', '_'
    if ($safe.Length -gt 150) { $safe = $safe.Substring(0, 150) }
    return Join-Path $script:LogDir "$safe.log"
}

function Save-ProjectLogLine {
    param([string]$ProjectPath, [string]$Line)
    $path = Get-ProjectLogFilePath -ProjectPath $ProjectPath
    if (-not $path) { return }
    try {
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        Add-Content -Path $path -Value $Line -Encoding UTF8
    } catch {}
}

function Limit-ProjectLogFile {
    # Called once per project start (not per line) to keep the on-disk log
    # from growing unbounded across many restarts/sessions.
    param([string]$ProjectPath)
    $path = Get-ProjectLogFilePath -ProjectPath $ProjectPath
    if (-not $path -or -not (Test-Path $path)) { return }
    try {
        $lines = @(Get-Content -Path $path -Tail $script:LogDiskCap -ErrorAction Stop)
        Set-Content -Path $path -Value $lines -Encoding UTF8
    } catch {}
}

function Add-ManagedLog {
    param($Entry, [string]$Text)
    if (-not $Text) { return }
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -eq '') { continue }
        $logLine = New-ManagedLogLine $line
        $Entry.Log.Enqueue($logLine)
        $discard = $null
        while ($Entry.Log.Count -gt $script:LogCap) { [void]$Entry.Log.TryDequeue([ref]$discard) }
        if ($Entry.ProjectPath) { Save-ProjectLogLine -ProjectPath $Entry.ProjectPath -Line $logLine }
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
        $bg = if ($isOn) { $script:Theme.Accent } else { [System.Drawing.Color]::FromArgb(0xC6, 0xC6, 0xC6) }
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

# ---------------------------------------------------------------------------
# Web dashboard status indicator — a small circular badge (not a labeled
# pill) so it reads as a quiet status dot rather than another toolbar
# button. Green/red tint + ring + center dot, using the same Success/Danger
# tokens the grid's own Status column already uses. Details (port, URL,
# error) live in the tooltip instead of on-face text.
# ---------------------------------------------------------------------------
function New-DashboardPill {
    $pill = New-Object System.Windows.Forms.Panel
    $pill.Size = New-Object System.Drawing.Size(20, 20)
    $pill.Tag = [PSCustomObject]@{ On = $false; Text = 'Dashboard off'; Url = $null }

    $dbProp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance, NonPublic')
    $dbProp.SetValue($pill, $true, $null)

    $pill.Add_Paint({
        param($s, $e)
        $t = $s.Tag
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $parentColor = if ($s.Parent) { $s.Parent.BackColor } else { [System.Drawing.Color]::White }
        $g.Clear($parentColor)

        $rect = New-Object System.Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
        $d = $rect.Height
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc($rect.X, $rect.Y, $d, $d, 90, 180)
        $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 180)
        $path.CloseFigure()

        $fillColor = if ($t.On) { $script:Theme.SuccessTint } else { $script:Theme.DangerTint }
        $ringColor = if ($t.On) { $script:Theme.Success } else { $script:Theme.Danger }

        $fillBrush = New-Object System.Drawing.SolidBrush($fillColor)
        $g.FillPath($fillBrush, $path)
        $fillBrush.Dispose()

        $borderPen = New-Object System.Drawing.Pen($ringColor, 1)
        $g.DrawPath($borderPen, $path)
        $borderPen.Dispose()

        # Centered on the ring's own bounding box (0,0 .. Width-1,Height-1),
        # not the control's full Width/Height, and in float space so it
        # lands dead-center instead of getting truncated a pixel off by
        # integer division.
        $dotSize = 8.0
        $cx = $rect.X + ($rect.Width / 2.0)
        $cy = $rect.Y + ($rect.Height / 2.0)
        $dotRect = New-Object System.Drawing.RectangleF(($cx - $dotSize / 2.0), ($cy - $dotSize / 2.0), $dotSize, $dotSize)
        $dotBrush = New-Object System.Drawing.SolidBrush($ringColor)
        $g.FillEllipse($dotBrush, $dotRect)
        $dotBrush.Dispose()

        $path.Dispose()
    })

    $pill.Add_Click({
        param($s, $e)
        if ($s.Tag.On -and $s.Tag.Url) { try { Start-Process $s.Tag.Url } catch {} }
    })

    return $pill
}

function Update-DashboardPill {
    if (-not $script:DashboardPill) { return }
    $t = $script:DashboardPill.Tag
    if ($script:Settings.DashboardEnabled -and $script:DashboardCache.Listening) {
        $t.On = $true
        $t.Text = "Dashboard - $($script:DashboardCache.Port)"
        $t.Url = "http://localhost:$($script:DashboardCache.Port)"
        $addrText = (@($script:DashboardCache.Addresses) | ForEach-Object { "$($_.Label): $($_.Url)" }) -join "`n"
        $script:DashboardTip.SetToolTip($script:DashboardPill, "Running - click to open`n$addrText")
        $script:DashboardPill.Cursor = [System.Windows.Forms.Cursors]::Hand
    } elseif ($script:Settings.DashboardEnabled -and $script:DashboardCache.ListenError) {
        $t.On = $false
        $t.Text = 'Dashboard: failed'
        $t.Url = $null
        $script:DashboardTip.SetToolTip($script:DashboardPill, "Failed to start: $($script:DashboardCache.ListenError)")
        $script:DashboardPill.Cursor = [System.Windows.Forms.Cursors]::Default
    } elseif ($script:Settings.DashboardEnabled) {
        $t.On = $false
        $t.Text = 'Dashboard starting...'
        $t.Url = $null
        $script:DashboardTip.SetToolTip($script:DashboardPill, 'Web dashboard is starting...')
        $script:DashboardPill.Cursor = [System.Windows.Forms.Cursors]::Default
    } else {
        $t.On = $false
        $t.Text = 'Dashboard off'
        $t.Url = $null
        $script:DashboardTip.SetToolTip($script:DashboardPill, 'Off. Enable it from the Dashboard menu.')
        $script:DashboardPill.Cursor = [System.Windows.Forms.Cursors]::Default
    }
    $script:DashboardPill.Invalidate()
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Localhost Manager'
$form.Size = New-Object System.Drawing.Size(960, 580)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(700, 400)
$form.Icon = $script:IconOk
$form.BackColor = $script:Theme.WindowBg
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

# ---------------------------------------------------------------------------
# Menu bar — the standard File / Settings / About a desktop app is expected
# to have. Menu items call straight into the same functions the old toolbar
# buttons used (Show-SettingsDialog, Show-ManageGroupsDialog, Refresh-Grid,
# the tray Exit path); no persistence/business logic lives here.
# ---------------------------------------------------------------------------
$menuStrip = New-Object System.Windows.Forms.MenuStrip
$menuStrip.BackColor = [System.Drawing.Color]::White
$menuStrip.ForeColor = $script:Theme.TextPrimary
$menuStrip.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$menuStrip.Padding = New-Object System.Windows.Forms.Padding(8, 3, 0, 3)

$menuFile = New-Object System.Windows.Forms.ToolStripMenuItem('File')
$menuFileRefresh = New-Object System.Windows.Forms.ToolStripMenuItem('Refresh')
$menuFileRefresh.ShortcutKeys = [System.Windows.Forms.Keys]::F5
$menuFileRefresh.Add_Click({ Refresh-Grid })
$menuFileExit = New-Object System.Windows.Forms.ToolStripMenuItem('Exit')
$menuFileExit.Add_Click({
    $script:ReallyExit = $true
    $notifyIcon.Visible = $false
    $form.Close()
})
[System.Windows.Forms.ToolStripItem[]]$menuFileItems = @($menuFileRefresh, (New-Object System.Windows.Forms.ToolStripSeparator), $menuFileExit)
$menuFile.DropDownItems.AddRange($menuFileItems)

$menuSettings = New-Object System.Windows.Forms.ToolStripMenuItem('Settings')
$menuSettingsPrefs = New-Object System.Windows.Forms.ToolStripMenuItem('Preferences...')
$menuSettingsPrefs.Add_Click({ Show-SettingsDialog })
$menuSettingsGroups = New-Object System.Windows.Forms.ToolStripMenuItem('Manage Groups...')
$menuSettingsGroups.Add_Click({ Show-ManageGroupsDialog })
$menuSettingsNodeOnly = New-Object System.Windows.Forms.ToolStripMenuItem('Dev Servers Only')
$menuSettingsNodeOnly.Checked = $script:Settings.OnlyNode
$menuSettingsNodeOnly.Add_Click({
    Invoke-ToggleClick -Switch $nodeOnlySwitch
    $menuSettingsNodeOnly.Checked = Get-ToggleChecked $nodeOnlySwitch
})
$menuSettingsUseGroups = New-Object System.Windows.Forms.ToolStripMenuItem('Use Groups')
$menuSettingsUseGroups.Checked = $script:Settings.ShowGroups
$menuSettingsUseGroups.Add_Click({
    Invoke-ToggleClick -Switch $useGroupsSwitch
    $menuSettingsUseGroups.Checked = Get-ToggleChecked $useGroupsSwitch
})
[System.Windows.Forms.ToolStripItem[]]$menuSettingsItems = @($menuSettingsPrefs, $menuSettingsGroups, (New-Object System.Windows.Forms.ToolStripSeparator), $menuSettingsNodeOnly, $menuSettingsUseGroups)
$menuSettings.DropDownItems.AddRange($menuSettingsItems)

$menuDashboard = New-Object System.Windows.Forms.ToolStripMenuItem('Dashboard')
$menuDashboard.Add_Click({ Show-DashboardDialog })

$menuAbout = New-Object System.Windows.Forms.ToolStripMenuItem('About')
$menuAbout.Add_Click({ Show-AboutDialog })

[System.Windows.Forms.ToolStripItem[]]$menuTopItems = @($menuFile, $menuSettings, $menuDashboard, $menuAbout)
$menuStrip.Items.AddRange($menuTopItems)
$form.MainMenuStrip = $menuStrip
Enable-RoundedPopup -Popup $menuFile.DropDown -Radius 8
Enable-RoundedPopup -Popup $menuSettings.DropDown -Radius 8

$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock = 'Top'
$topPanel.Height = 88
$topPanel.BackColor = $script:Theme.PanelBg
# Set explicitly (matching Dock='Top''s eventual real width) before any
# Right-anchored children are added below. WinForms bakes each anchored
# child's margin from whatever width the parent reports at the moment
# Controls.Add/AddRange runs -- if that's still the Panel's un-docked
# default (~200px, since Dock doesn't take effect until parented to
# $form later), every Top,Right-only control ends up positioned using a
# margin computed against 200px and lands far off-screen once the panel
# actually grows to its real size. (Same fix applied to BottomBar below,
# for the same reason -- scopeLabel lives there now.)
$topPanel.Width = $form.ClientSize.Width

$topPanelDivider = New-Object System.Windows.Forms.Panel
$topPanelDivider.Dock = 'Bottom'
$topPanelDivider.Height = 1
$topPanelDivider.BackColor = $script:Theme.Border

function New-VerticalDivider {
    param([int]$X, [int]$Y = 12, [int]$Height = 28)
    $div = New-Object System.Windows.Forms.Panel
    $div.Location = New-Object System.Drawing.Point($X, $Y)
    $div.Size = New-Object System.Drawing.Size(1, $Height)
    $div.BackColor = $script:Theme.Border
    return $div
}

# ---------------------------------------------------------------------------
# Toolbar layout. Row 1: Refresh, then the Group picker (its own text
# already reads "Group: X" — no separate "Group:" label alongside it).
# Row 2, directly below: Start All / Stop All. To the right, at a fixed
# column (not edge-anchored), the two toggles stack in the same two rows
# (Use Groups next to row 1, Dev Servers Only next to row 2). The
# dashboard status dot sits on its own, pinned to the far right edge.
# ---------------------------------------------------------------------------
$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = 'Refresh'
$refreshButton.Location = New-Object System.Drawing.Point(16, 12)
$refreshButton.Size = New-Object System.Drawing.Size(84, 28)

$startAllButton = New-Object System.Windows.Forms.Button
$startAllButton.Text = 'Start All'
$startAllButton.Location = New-Object System.Drawing.Point(16, 48)
$startAllButton.Size = New-Object System.Drawing.Size(84, 28)

$stopAllButton = New-Object System.Windows.Forms.Button
$stopAllButton.Text = 'Stop All'
$stopAllButton.Location = New-Object System.Drawing.Point(112, 48)
$stopAllButton.Size = New-Object System.Drawing.Size(84, 28)

$divider1 = New-VerticalDivider -X 278 -Y 8 -Height 72

# Always visible regardless of the "Use Groups" setting — Dev Servers Only
# is an independent toggle, so both toggle rows (and the dashboard dot)
# stay put even when the Group/Start All/Stop All cluster is hidden.
$script:DashboardTip = New-Object System.Windows.Forms.ToolTip
# Defaults are InitialDelay=500 / AutoPopDelay=5000 — the 5s pop delay is
# what made it feel "stuck" lingering on screen after a hover. Trimmed to
# a snappier show/stay time.
$script:DashboardTip.InitialDelay = 300
$script:DashboardTip.ReshowDelay = 100
$script:DashboardTip.AutoPopDelay = 2000
$script:DashboardPill = New-DashboardPill
$script:DashboardPill.Location = New-Object System.Drawing.Point(908, 16)
$script:DashboardPill.Anchor = 'Top,Right'

$useGroupsSwitch = New-ToggleSwitch -Checked $script:Settings.ShowGroups
$useGroupsSwitch.Location = New-Object System.Drawing.Point(310, 16)

$useGroupsLabel = New-Object System.Windows.Forms.Label
$useGroupsLabel.Text = 'Use Groups'
$useGroupsLabel.Location = New-Object System.Drawing.Point(356, 15)
$useGroupsLabel.Size = New-Object System.Drawing.Size(76, 22)
$useGroupsLabel.TextAlign = 'MiddleLeft'
$useGroupsLabel.ForeColor = $script:Theme.TextPrimary

$nodeOnlySwitch = New-ToggleSwitch -Checked $script:Settings.OnlyNode
$nodeOnlySwitch.Location = New-Object System.Drawing.Point(310, 52)

$nodeOnlyLabel = New-Object System.Windows.Forms.Label
$nodeOnlyLabel.Text = 'Dev Servers Only'
$nodeOnlyLabel.Location = New-Object System.Drawing.Point(356, 51)
$nodeOnlyLabel.Size = New-Object System.Drawing.Size(152, 22)
$nodeOnlyLabel.TextAlign = 'MiddleLeft'
$nodeOnlyLabel.ForeColor = $script:Theme.TextPrimary

# Footer clock — just the time, not "Last refreshed: ... | N shown"; the
# count moved to the tab headers (Live (N) / History (N)) already, so
# repeating it here was redundant. Scope sits on the same line, right-
# aligned, since it no longer fits the (now button-only) toolbar row.
$script:BottomBarDivider = New-Object System.Windows.Forms.Panel
$script:BottomBarDivider.Dock = 'Top'
$script:BottomBarDivider.Height = 1
$script:BottomBarDivider.BackColor = $script:Theme.Border

$script:BottomBar = New-Object System.Windows.Forms.Panel
$script:BottomBar.Dock = 'Bottom'
$script:BottomBar.Height = 26
$script:BottomBar.BackColor = $script:Theme.PanelBg
# Same fix as topPanel above: set Width before adding Right-anchored
# children, or their initial margin gets computed against the ~200px
# un-docked default and they land off-screen once the bar reaches its
# real width.
$script:BottomBar.Width = $form.ClientSize.Width

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = ''
$statusLabel.Location = New-Object System.Drawing.Point(12, 4)
$statusLabel.Size = New-Object System.Drawing.Size(90, 18)
$statusLabel.ForeColor = $script:Theme.TextDim
$statusLabel.TextAlign = 'MiddleLeft'

$scopeLabel = New-Object System.Windows.Forms.Label
$scopeLabel.Text = ''
$scopeLabel.Location = New-Object System.Drawing.Point(628, 4)
$scopeLabel.Size = New-Object System.Drawing.Size(304, 18)
$scopeLabel.TextAlign = 'MiddleLeft'
$scopeLabel.ForeColor = $script:Theme.Accent
$scopeLabel.AutoEllipsis = $true
$scopeLabel.Anchor = 'Top,Right'

$script:BottomBar.Controls.AddRange(@($statusLabel, $scopeLabel, $script:BottomBarDivider))

$groupsButton = New-Object System.Windows.Forms.Button
$groupsButton.Text = 'Groups: none selected'
$groupsButton.TextAlign = 'MiddleLeft'
$groupsButton.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
$groupsButton.Location = New-Object System.Drawing.Point(112, 12)
$groupsButton.Size = New-Object System.Drawing.Size(150, 28)

# Multi-select "dropdown": a plain Button that pops open a checked-list so
# 2+ groups can be active in the table at once (a normal ComboBox only
# ever lets you pick one).
$groupsPopup = New-Object System.Windows.Forms.ToolStripDropDown
$groupsPopup.AutoClose = $true
$groupsPopup.Padding = New-Object System.Windows.Forms.Padding(2)
Enable-RoundedPopup -Popup $groupsPopup -Radius 10

$groupsCheckedList = New-Object System.Windows.Forms.CheckedListBox
$groupsCheckedList.CheckOnClick = $true
$groupsCheckedList.BorderStyle = 'None'
$groupsCheckedList.IntegralHeight = $false
$groupsCheckedList.Size = New-Object System.Drawing.Size(200, 130)
$groupsCheckedList.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$groupsListHost = New-Object System.Windows.Forms.ToolStripControlHost($groupsCheckedList)
$groupsListHost.AutoSize = $false
$groupsListHost.Size = $groupsCheckedList.Size
$groupsListHost.Margin = New-Object System.Windows.Forms.Padding(0)
$groupsPopup.Items.Add($groupsListHost) | Out-Null

Initialize-ModernButton -Button $refreshButton
Initialize-ModernButton -Button $groupsButton
Initialize-ModernButton -Button $startAllButton -Variant Success
Initialize-ModernButton -Button $stopAllButton -Variant Danger

[System.Windows.Forms.Control[]]$topControls = @($refreshButton, $groupsButton, $startAllButton, $stopAllButton, $divider1, $script:DashboardPill, $useGroupsSwitch, $useGroupsLabel, $nodeOnlySwitch, $nodeOnlyLabel, $topPanelDivider)
$topPanel.Controls.AddRange($topControls)
Connect-ToggleLabel -Switch $nodeOnlySwitch -Label $nodeOnlyLabel
Connect-ToggleLabel -Switch $useGroupsSwitch -Label $useGroupsLabel

function Update-SystemTabState {
    # Grayed out (not hidden) when off, same idiom as Update-GroupsVisibility
    # below - the tab stays visible/discoverable, its content just goes
    # inert and swaps in an explanatory placeholder instead of an empty grid.
    $show = [bool]$script:Settings.ShowSystemPorts
    $tabPageSystem.Enabled = $show
    $systemGrid.Visible = $show
    $systemPlaceholderLabel.Visible = -not $show
}

function Update-GroupsVisibility {
    # Grayed out (not hidden) when off, so the toolbar layout never shifts
    # and it's still obvious the controls exist, just inactive.
    $show = Get-ToggleChecked $useGroupsSwitch
    $groupsButton.Enabled = $show
    $startAllButton.Enabled = $show
    $stopAllButton.Enabled = $show
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

# Column layout is identical for the Live and History grids (same order,
# same indices), so event handlers can address cells by a single shared
# index map instead of per-grid column objects.
$script:ColIdx = @{ Status = 0; Port = 1; Pin = 2; CustomName = 3; Process = 4; PID = 5; LocalUrl = 6; LanUrls = 7; ProjectPath = 8; Log = 9; Action = 10 }
$dgvDoubleBufferProp = [System.Windows.Forms.DataGridView].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance, NonPublic')

function New-PortsGrid {
    $g = New-Object System.Windows.Forms.DataGridView
    $g.AutoGenerateColumns = $false
    $g.ReadOnly = $false
    $g.AllowUserToAddRows = $false
    $g.AllowUserToDeleteRows = $false
    $g.AllowUserToResizeRows = $false
    $g.RowHeadersVisible = $false
    $g.SelectionMode = 'FullRowSelect'
    $g.MultiSelect = $false
    $g.EditMode = 'EditOnKeystrokeOrF2'
    $g.BackgroundColor = $script:Theme.CardBg
    $g.BorderStyle = 'None'
    # CellBorderStyle 'SingleHorizontal' still leaks vertical column-divider
    # lines under the Windows 11 visual style enabled via EnableVisualStyles
    # further up — a known DataGridView theming quirk. Disabling native cell
    # borders entirely and hand-drawing just a bottom line per row (below)
    # sidesteps it and guarantees no vertical lines regardless of OS theme.
    $g.CellBorderStyle = 'None'
    $g.GridColor = $script:Theme.Border
    $g.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $g.EnableHeadersVisualStyles = $false
    $g.ColumnHeadersDefaultCellStyle.BackColor = $script:Theme.PanelBg
    $g.ColumnHeadersDefaultCellStyle.ForeColor = $script:Theme.TextPrimary
    $g.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $g.ColumnHeadersDefaultCellStyle.Alignment = 'MiddleLeft'
    $g.ColumnHeadersBorderStyle = 'None'
    $g.ColumnHeadersHeightSizeMode = 'DisableResizing'
    $g.ColumnHeadersHeight = 34
    $g.RowTemplate.Height = 32
    $g.DefaultCellStyle.BackColor = [System.Drawing.Color]::White
    $g.DefaultCellStyle.ForeColor = $script:Theme.TextPrimary
    $g.DefaultCellStyle.SelectionBackColor = $script:Theme.AccentTint
    $g.DefaultCellStyle.SelectionForeColor = $script:Theme.TextPrimary
    $g.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(4, 0, 4, 0)
    $g.AlternatingRowsDefaultCellStyle.BackColor = $script:Theme.RowAlt
    $g.AlternatingRowsDefaultCellStyle.SelectionBackColor = $script:Theme.AccentTint

    $colStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colStatus.Name = 'Status'; $colStatus.HeaderText = 'Status'; $colStatus.FillWeight = 55; $colStatus.MinimumWidth = 58; $colStatus.ReadOnly = $true

    $colPort = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colPort.Name = 'Port'; $colPort.HeaderText = 'Port'; $colPort.FillWeight = 45; $colPort.MinimumWidth = 44; $colPort.ReadOnly = $true

    # Icon-only toggle button - always the same glyph, colored per row (see
    # Add-DataRow) rather than swapped between a "pin"/"unpin" glyph pair,
    # so clicking it can't cause a visible layout jump.
    $colPin = New-Object System.Windows.Forms.DataGridViewButtonColumn
    $colPin.Name = 'Pin'; $colPin.HeaderText = ''; $colPin.FillWeight = 34; $colPin.MinimumWidth = 32
    $colPin.Text = [string][char]0xE718
    $colPin.UseColumnTextForButtonValue = $true
    $colPin.ReadOnly = $true
    $colPin.FlatStyle = 'Flat'
    $colPin.DefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 9.5)
    $colPin.DefaultCellStyle.Alignment = 'MiddleCenter'
    $colPin.DefaultCellStyle.SelectionBackColor = $script:Theme.PanelBg

    $colCustomName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colCustomName.Name = 'CustomName'; $colCustomName.HeaderText = 'Custom Name'; $colCustomName.FillWeight = 105; $colCustomName.MinimumWidth = 104; $colCustomName.ReadOnly = $false

    $colProc = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colProc.Name = 'Process'; $colProc.HeaderText = 'Process'; $colProc.FillWeight = 62; $colProc.MinimumWidth = 60; $colProc.ReadOnly = $true

    $colPid = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colPid.Name = 'PID'; $colPid.HeaderText = 'PID'; $colPid.FillWeight = 50; $colPid.MinimumWidth = 46; $colPid.ReadOnly = $true

    $colLocal = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colLocal.Name = 'LocalUrl'; $colLocal.HeaderText = 'Local URL'; $colLocal.FillWeight = 110; $colLocal.ReadOnly = $true

    $colLan = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colLan.Name = 'LanUrls'; $colLan.HeaderText = 'Network URL(s)'; $colLan.FillWeight = 170; $colLan.ReadOnly = $true

    $colPath = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colPath.Name = 'ProjectPath'; $colPath.HeaderText = 'Project Path'; $colPath.FillWeight = 162; $colPath.ReadOnly = $true

    $colLog = New-Object System.Windows.Forms.DataGridViewButtonColumn
    $colLog.Name = 'Log'; $colLog.HeaderText = ''; $colLog.FillWeight = 65; $colLog.Text = 'Restart'
    $colLog.UseColumnTextForButtonValue = $true
    $colLog.ReadOnly = $true
    $colLog.FlatStyle = 'Flat'
    $colLog.DefaultCellStyle.ForeColor = $script:Theme.TextDim
    $colLog.DefaultCellStyle.SelectionForeColor = $script:Theme.TextDim
    $colLog.DefaultCellStyle.SelectionBackColor = $script:Theme.PanelBg

    $colAction = New-Object System.Windows.Forms.DataGridViewButtonColumn
    $colAction.Name = 'Action'; $colAction.HeaderText = ''; $colAction.FillWeight = 60
    $colAction.UseColumnTextForButtonValue = $false
    $colAction.ReadOnly = $true
    $colAction.FlatStyle = 'Flat'

    [System.Windows.Forms.DataGridViewColumn[]]$gridColumns = @($colStatus, $colPort, $colPin, $colCustomName, $colProc, $colPid, $colLocal, $colLan, $colPath, $colLog, $colAction)
    $g.Columns.AddRange($gridColumns)
    $g.AutoSizeColumnsMode = 'Fill'
    $dgvDoubleBufferProp.SetValue($g, $true, $null)
    $g.Dock = 'Fill'

    # Replaces the native CellBorderStyle border this column used to draw
    # (removed above) — a single flat line under each real row, no verticals.
    $g.Add_RowPostPaint({
        param($s, $e)
        $row = $s.Rows[$e.RowIndex]
        if ($row.Tag -eq 'separator') { return }
        $borderColor = $script:Theme.Border
        if ($null -eq $borderColor) { return }
        $y = $e.RowBounds.Bottom - 1
        $pen = New-Object System.Drawing.Pen($borderColor, 1)
        $e.Graphics.DrawLine($pen, $e.RowBounds.Left, $y, $e.RowBounds.Right, $y)
        $pen.Dispose()
    })

    return $g
}

$liveGrid = New-PortsGrid
$historyGrid = New-PortsGrid
$systemGrid = New-PortsGrid
# System rows are never Start/Stop/Restart-able (several are protected OS
# processes - PID 4 "System", lsass, csrss - where a kill attempt would be
# actively dangerous), so those columns don't apply here at all. Pinning is
# meaningless too - there's no project to bring back after a shutdown.
$systemGrid.Columns['Log'].Visible = $false
$systemGrid.Columns['Action'].Visible = $false
$systemGrid.Columns['Pin'].Visible = $false

$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Anchor = 'Top,Bottom,Left,Right'
$tabControl.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$tabControl.Padding = New-Object System.Drawing.Point(14, 5)

$tabPageLive = New-Object System.Windows.Forms.TabPage
$tabPageLive.Text = 'Live'
$tabPageLive.BackColor = $script:Theme.CardBg
$tabPageLive.Controls.Add($liveGrid)

$tabPageHistory = New-Object System.Windows.Forms.TabPage
$tabPageHistory.Text = 'History'
$tabPageHistory.BackColor = $script:Theme.CardBg
$tabPageHistory.Controls.Add($historyGrid)

$systemPlaceholderLabel = New-Object System.Windows.Forms.Label
$systemPlaceholderLabel.Text = "System-owned ports are hidden.`r`nEnable `"Show system-owned ports`" in Settings > Preferences to view them here."
$systemPlaceholderLabel.Dock = 'Fill'
$systemPlaceholderLabel.TextAlign = 'MiddleCenter'
$systemPlaceholderLabel.ForeColor = $script:Theme.TextDim
$systemPlaceholderLabel.BackColor = $script:Theme.CardBg
$systemPlaceholderLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)

$tabPageSystem = New-Object System.Windows.Forms.TabPage
$tabPageSystem.Text = 'System'
$tabPageSystem.BackColor = $script:Theme.CardBg
$tabPageSystem.Controls.Add($systemGrid)
$tabPageSystem.Controls.Add($systemPlaceholderLabel)

[System.Windows.Forms.TabPage[]]$tabPages = @($tabPageLive, $tabPageHistory, $tabPageSystem)
$tabControl.TabPages.AddRange($tabPages)

$gridTop = $menuStrip.Height + $topPanel.Height
$tabControl.Location = New-Object System.Drawing.Point(0, $gridTop)
$tabControl.Size = New-Object System.Drawing.Size($form.ClientSize.Width, ($form.ClientSize.Height - $gridTop - $script:BottomBar.Height))

# Fill/content control added first, then Dock='Top'/'Bottom' controls in
# reverse visual order (later-added = higher z-order = closer to its dock
# edge) — the standard WinForms pattern for MenuStrip + toolbar + content.
$form.Controls.Add($tabControl)
$form.Controls.Add($script:BottomBar)
$form.Controls.Add($topPanel)
$form.Controls.Add($menuStrip)
Update-GroupsVisibility
Update-SystemTabState

function Add-DataRow {
    param($Grid, $r)
    $idx = $Grid.Rows.Add($r.Status, $r.Port, '', $r.CustomName, $r.ProcessName, $r.ProcId, $r.LocalUrl, $r.LanUrls, $r.ProjectPath, 'Restart', $r.Action)
    $row = $Grid.Rows[$idx]
    $row.Tag = $r
    switch ($r.Status) {
        'ON'      { $row.Cells['Status'].Style.ForeColor = $script:Theme.Success }
        'CRASHED' {
            $row.Cells['Status'].Style.ForeColor = $script:Theme.Danger
            $row.Cells['Status'].Style.Font = New-Object System.Drawing.Font($Grid.Font, [System.Drawing.FontStyle]::Bold)
        }
        default   { $row.Cells['Status'].Style.ForeColor = $script:Theme.TextDim }
    }
    if ($Grid.Columns['Pin'].Visible) {
        $pinCell = $row.Cells['Pin']
        if ($r.Pinned) {
            $pinCell.Style.ForeColor = $script:Theme.Accent
            $pinCell.Style.SelectionForeColor = $script:Theme.Accent
            $pinCell.Style.SelectionBackColor = $script:Theme.AccentTint
            $pinCell.ToolTipText = 'Pinned - stays listed and restartable after it stops. Click to unpin.'
        } else {
            $pinCell.Style.ForeColor = $script:Theme.Border
            $pinCell.Style.SelectionForeColor = $script:Theme.Border
            $pinCell.Style.SelectionBackColor = $script:Theme.PanelBg
            $pinCell.ToolTipText = 'Pin - keep this port listed (and restartable) even after it stops.'
        }
    }
    $actionCell = $row.Cells['Action']
    if ($r.Action -eq 'Stop') {
        $actionCell.Style.ForeColor = $script:Theme.Danger
        $actionCell.Style.SelectionForeColor = $script:Theme.Danger
        $actionCell.Style.SelectionBackColor = $script:Theme.DangerTint
    } else {
        $actionCell.Style.ForeColor = $script:Theme.Success
        $actionCell.Style.SelectionForeColor = $script:Theme.Success
        $actionCell.Style.SelectionBackColor = $script:Theme.SuccessTint
    }
}

function Add-SeparatorRow {
    param($Grid)
    $idx = $Grid.Rows.Add('', '', '', '', '', '', '', '', '', '', '')
    $row = $Grid.Rows[$idx]
    $row.Tag = 'separator'
    $row.Height = 10
    $row.ReadOnly = $true
    $row.DefaultCellStyle.BackColor = $script:Theme.PanelBg
    $row.DefaultCellStyle.SelectionBackColor = $script:Theme.PanelBg
    foreach ($colName in @('Pin', 'Log', 'Action')) {
        $row.Cells[$colName] = New-Object System.Windows.Forms.DataGridViewTextBoxCell
    }
}

function Get-DisplayRows {
    # Use Groups active: the selected group(s) define exactly what's shown,
    # and they always stay visible even if Dev-Servers-Only or the root-dir
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

function Get-DisplayRowsSplit {
    # Live tab = actually listening right now (Status ON). History tab =
    # everything else (OFF/CRASHED) — ports LocalhostManager remembers but
    # nothing is bound to at the moment. See LocalUrl detection in
    # Build-Rows: ON rows come from the real TCP listener scan, OFF/CRASHED
    # rows come from history.json. System tab = OS-owned listeners, built
    # only when the Preferences toggle is on (Build-SystemRows scans the
    # live cache regardless, so this is purely a display-time gate).
    $display = @(Get-DisplayRows)
    Publish-DashboardRows -Display $display
    $systemRows = if ([bool]$script:Settings.ShowSystemPorts) { @(Build-SystemRows) } else { @() }
    return @{
        Live    = @($display | Where-Object { $_.Row.Status -eq 'ON' })
        History = @($display | Where-Object { $_.Row.Status -ne 'ON' })
        System  = @($systemRows | ForEach-Object { [PSCustomObject]@{ Row = $_; Group = $null } })
    }
}

function Get-DisplayRowsSignature {
    param($Display)
    return ($Display | ForEach-Object {
        "$($_.Group)|$($_.Row.Status)|$($_.Row.Port)|$($_.Row.ProcId)|$($_.Row.CustomName)|$($_.Row.ProjectPath)|$($_.Row.Action)|$([bool]$_.Row.HasLog)|$([bool]$_.Row.Pinned)"
    }) -join "`n"
}

function Render-Grid {
    param($Grid, $Display)
    $Grid.SuspendLayout()
    try {
        $Grid.Rows.Clear()
        $lastGroup = $null
        foreach ($d in $Display) {
            if ($null -ne $d.Group -and $null -ne $lastGroup -and $d.Group -ne $lastGroup) { Add-SeparatorRow -Grid $Grid }
            Add-DataRow -Grid $Grid -r $d.Row
            $lastGroup = $d.Group
        }
        $Grid.ClearSelection()
    } finally {
        $Grid.ResumeLayout()
    }
}

function Update-TabHeaders {
    param([int]$LiveCount, [int]$HistoryCount, [int]$SystemCount)
    $tabPageLive.Text = "Live ($LiveCount)"
    $tabPageHistory.Text = "History ($HistoryCount)"
    $tabPageSystem.Text = if ([bool]$script:Settings.ShowSystemPorts) { "System ($SystemCount)" } else { 'System' }
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
    if ($liveGrid.IsCurrentCellInEditMode -or $historyGrid.IsCurrentCellInEditMode -or $systemGrid.IsCurrentCellInEditMode) { return }
    $split = Get-DisplayRowsSplit
    Render-Grid -Grid $liveGrid -Display $split.Live
    Render-Grid -Grid $historyGrid -Display $split.History
    Render-Grid -Grid $systemGrid -Display $split.System
    $script:LastLiveSignature = Get-DisplayRowsSignature $split.Live
    $script:LastHistorySignature = Get-DisplayRowsSignature $split.History
    $script:LastSystemSignature = Get-DisplayRowsSignature $split.System
    Update-TabHeaders -LiveCount $split.Live.Count -HistoryCount $split.History.Count -SystemCount $split.System.Count
    $statusLabel.Text = Get-Date -Format 'HH:mm:ss'
    Update-TrayIcon
    Flash-StatusLabel
}

function Invoke-PeriodicRefresh {
    # Runs every tick, but only repaints a grid when something in it
    # actually changed — otherwise the table would visibly flicker/reset
    # selection every few seconds for no reason. The corner status label
    # flashes red on every tick regardless, so it's still obvious the app
    # is alive and polling. Live, History and System are tracked/repainted
    # independently so activity in one tab doesn't reset scroll/selection
    # in the others.
    if ($liveGrid.IsCurrentCellInEditMode -or $historyGrid.IsCurrentCellInEditMode -or $systemGrid.IsCurrentCellInEditMode) { Flash-StatusLabel; return }
    $split = Get-DisplayRowsSplit
    $liveSig = Get-DisplayRowsSignature $split.Live
    $historySig = Get-DisplayRowsSignature $split.History
    $systemSig = Get-DisplayRowsSignature $split.System
    if ($liveSig -ne $script:LastLiveSignature) {
        Render-Grid -Grid $liveGrid -Display $split.Live
        $script:LastLiveSignature = $liveSig
    }
    if ($historySig -ne $script:LastHistorySignature) {
        Render-Grid -Grid $historyGrid -Display $split.History
        $script:LastHistorySignature = $historySig
    }
    if ($systemSig -ne $script:LastSystemSignature) {
        Render-Grid -Grid $systemGrid -Display $split.System
        $script:LastSystemSignature = $systemSig
    }
    Update-TabHeaders -LiveCount $split.Live.Count -HistoryCount $split.History.Count -SystemCount $split.System.Count
    $statusLabel.Text = Get-Date -Format 'HH:mm:ss'
    Update-TrayIcon
    Flash-StatusLabel
}

function Get-NpmRunScript {
    # "start" is the conventional entry point, but not every project defines
    # one (e.g. workspace packages that only expose "dev" for a vite/webpack
    # dev server). Falling back blindly to "npm start" makes those crash
    # with "Missing script: start" even though the project is fine.
    param([string]$ProjectPath)
    $pkgPath = Join-Path $ProjectPath 'package.json'
    if (Test-Path $pkgPath) {
        try {
            $scripts = (Get-Content -Path $pkgPath -Raw | ConvertFrom-Json).scripts
            $names = @($scripts.PSObject.Properties.Name)
            if ($names -contains 'start') { return 'start' }
            if ($names -contains 'dev') { return 'dev' }
        } catch {}
    }
    return 'start'
}

function Start-ProjectAtPath {
    # Node projects always go through npm run <script> - unchanged, and
    # still the most predictable option when a package.json is present.
    # Anything else (a plain "python -m http.server", a .bat-launched
    # static server, ...) has no npm script to guess, so it falls back to
    # $CommandLine - the literal argv LocalhostManager captured from the
    # process while it was actually running (see Get-ProcessCommandLine in
    # the background poller), persisted onto its history.json entry.
    param([string]$ProjectPath, [string]$CommandLine)
    try {
        $key = Get-NormalizedPath $ProjectPath
        $hasPackageJson = Test-Path (Join-Path $ProjectPath 'package.json')
        # No package.json AND nothing captured yet - there is genuinely no
        # known way to start this. Bail out instead of falling back to
        # "npm run start", which would just fail with ENOENT (no
        # package.json to run against) and look like a crash rather than
        # the "we don't know how to start this yet" it actually is.
        if (-not $hasPackageJson -and -not $CommandLine) { return $false }
        $runCommand = if ($hasPackageJson) {
            "npm run $(Get-NpmRunScript -ProjectPath $ProjectPath)"
        } else {
            $CommandLine
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'cmd.exe'
        $psi.Arguments = "/c cd /d `"$ProjectPath`" && $runCommand"
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
            ProjectPath   = $ProjectPath
        }
        $script:ManagedProcesses[$key] = $entry
        Limit-ProjectLogFile -ProjectPath $ProjectPath
        Add-ManagedLog -Entry $entry -Text '*** started ***'

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

function Invoke-TogglePin {
    # Pinning writes straight to history.json (keyed by port, same as the
    # rest of history) rather than touching $script:ManagedProcesses or any
    # in-memory row state - Build-Rows re-derives Pinned from that file on
    # every refresh, so this is the single source of truth for it.
    param($data)
    $key = [string]$data.Port
    $history = Load-History
    $isPinned = $history.ContainsKey($key) -and [bool]$history[$key].Pinned

    if ($isPinned) {
        $history[$key].Pinned = $false
    } else {
        $history[$key] = @{
            ProjectPath = $data.ProjectPath
            ProcessName = $data.ProcessName
            Pinned      = $true
            CommandLine = $data.CommandLine
        }
    }
    Save-History $history
    Refresh-Grid
}

function Test-ProjectStartable {
    # Mirrors the check Start-ProjectAtPath makes internally, so the UI can
    # give a specific, accurate reason up front instead of "Could not start
    # project" after already trying and failing - most commonly a
    # first-ever Start on something pinned/recorded before command-line
    # capture existed, or before it was ever seen running long enough to be
    # captured at all.
    param([string]$ProjectPath, [string]$CommandLine)
    if (-not $ProjectPath) { return $false }
    if (Test-Path (Join-Path $ProjectPath 'package.json')) { return $true }
    return [bool]$CommandLine
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
        if (-not (Test-ProjectStartable -ProjectPath $data.ProjectPath -CommandLine $data.CommandLine)) {
            [System.Windows.Forms.MessageBox]::Show("This isn't an npm project (no package.json) and hasn't been seen running since command-line capture was added, so there's no known command to start it with. Run it manually once while it's live and LocalhostManager will remember it for next time.", 'No Known Start Command', 'OK', 'Warning') | Out-Null
            return
        }
        if (-not (Start-ProjectAtPath -ProjectPath $data.ProjectPath -CommandLine $data.CommandLine)) {
            [System.Windows.Forms.MessageBox]::Show('Could not start project.', 'Error', 'OK', 'Error') | Out-Null
        }
    }
    Start-Sleep -Milliseconds 800
    Refresh-Grid
}

function Invoke-Restart {
    param($data)

    if (-not $data.ProjectPath) {
        [System.Windows.Forms.MessageBox]::Show('No known project path for this port.', 'Cannot Restart', 'OK', 'Warning') | Out-Null
        return
    }
    if ($data.Status -ne 'ON' -and -not (Test-ProjectStartable -ProjectPath $data.ProjectPath -CommandLine $data.CommandLine)) {
        [System.Windows.Forms.MessageBox]::Show("This isn't an npm project (no package.json) and hasn't been seen running since command-line capture was added, so there's no known command to start it with. Run it manually once while it's live and LocalhostManager will remember it for next time.", 'No Known Start Command', 'OK', 'Warning') | Out-Null
        return
    }

    if ($data.Status -eq 'ON') {
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Restart $($data.ProcessName) (PID $($data.ProcId)) listening on port $($data.Port)?",
            'Confirm Restart', 'YesNo', 'Warning')
        if ($confirm -ne 'Yes') { return }
        if (-not (Stop-ProjectById -ProcId $data.ProcId -ProjectPath $data.ProjectPath)) {
            [System.Windows.Forms.MessageBox]::Show('Could not stop process.', 'Error', 'OK', 'Error') | Out-Null
            return
        }
        Start-Sleep -Milliseconds 800
    }

    if (-not (Start-ProjectAtPath -ProjectPath $data.ProjectPath -CommandLine $data.CommandLine)) {
        [System.Windows.Forms.MessageBox]::Show('Could not start project.', 'Error', 'OK', 'Error') | Out-Null
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

    $bottomPanel.BackColor = $script:Theme.PanelBg

    $copyButton = New-Object System.Windows.Forms.Button
    $copyButton.Text = 'Copy All'
    $copyButton.Location = New-Object System.Drawing.Point(10, 6)
    $copyButton.Size = New-Object System.Drawing.Size(90, 28)
    $copyButton.Add_Click({ if ($textBox.Text) { [System.Windows.Forms.Clipboard]::SetText($textBox.Text) } })
    Initialize-ModernButton -Button $copyButton

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = 'Close'
    $closeButton.Anchor = 'Top,Right'
    $closeButton.Location = New-Object System.Drawing.Point(660, 6)
    $closeButton.Size = New-Object System.Drawing.Size(80, 28)
    $closeButton.Add_Click({ $dlg.Close() })
    Initialize-ModernButton -Button $closeButton

    [System.Windows.Forms.Control[]]$bottomControls = @($copyButton, $closeButton)
    $bottomPanel.Controls.AddRange($bottomControls)
    $dlg.Controls.Add($textBox)
    $dlg.Controls.Add($bottomPanel)

    function Update-LogText {
        if ($entry) {
            $atBottom = $textBox.SelectionStart -ge ($textBox.TextLength - 2)
            $textBox.Text = ($entry.Log.ToArray() -join "`r`n")
            if ($atBottom) {
                $textBox.SelectionStart = $textBox.TextLength
                $textBox.ScrollToCaret()
            }
            return
        }

        # No live entry - either never started via this app, or it was
        # (Localhost Manager restarted, PC slept/resumed and killed the tray
        # process, etc). Fall back to the on-disk history for this project,
        # if any was captured across a prior run.
        $logPath = Get-ProjectLogFilePath -ProjectPath $ProjectPath
        $historyText = $null
        if ($logPath -and (Test-Path $logPath)) {
            try { $historyText = Get-Content -Path $logPath -Raw -ErrorAction Stop } catch {}
        }
        if ($historyText) {
            $textBox.Text = "(Showing saved log history from a previous run. Localhost Manager is not attached to this process right now, so live output will resume once it is stopped/started again from here.)`r`n`r`n$historyText"
        } else {
            $textBox.Text = '(No log captured for this project - it was not started via Localhost Manager.)'
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

function Show-RowDetail {
    # Sticky-note style: compact, appears right at the click point, and
    # nothing in the body is a clickable/editable control except the copy
    # icon buttons - values are plain Labels (not TextBoxes) so there's
    # nothing to accidentally focus/select/edit. Each Network URL gets its
    # own row labeled by adapter ("Ethernet", "Tailscale", "VMware", ...);
    # rows for a virtual (VM-only) adapter are tinted purple so it reads
    # clearly as "not a real LAN/Tailnet address."
    param($Data, [System.Drawing.Point]$ScreenPoint)

    $label = if ($Data.CustomName) { $Data.CustomName } elseif ($Data.ProjectPath) { Split-Path -Leaf $Data.ProjectPath } else { "Port $($Data.Port)" }

    $fields = @(
        @{ Label = 'Status';      Value = [string]$Data.Status;      IsVirtual = $false }
        @{ Label = 'Port';        Value = [string]$Data.Port;        IsVirtual = $false }
        @{ Label = 'Pinned';      Value = if ($Data.Pinned) { 'Yes' } else { 'No' }; IsVirtual = $false }
        @{ Label = 'Custom Name'; Value = [string]$Data.CustomName;  IsVirtual = $false }
        @{ Label = 'Process';     Value = [string]$Data.ProcessName; IsVirtual = $false }
        @{ Label = 'PID';         Value = [string]$Data.ProcId;      IsVirtual = $false }
        @{ Label = 'Local URL';   Value = [string]$Data.LocalUrl;    IsVirtual = $false }
    )

    # One row per network URL (already labeled/sorted by adapter type in
    # Build-Rows), so each address gets its own copy button and its own
    # "layer" label instead of a generic "Network URL N".
    if ($Data.LanEntries -and @($Data.LanEntries).Count -gt 0) {
        foreach ($entry in $Data.LanEntries) {
            $fields += @{ Label = $entry.Label; Value = $entry.Url; IsVirtual = [bool]$entry.IsVirtual }
        }
    } else {
        $fallback = if ($Data.LanUrls) { [string]$Data.LanUrls } else { '(localhost only)' }
        $fields += @{ Label = 'Network URL'; Value = $fallback; IsVirtual = $false }
    }

    $fields += @{ Label = 'Project Path'; Value = [string]$Data.ProjectPath; IsVirtual = $false }
    if ($Data.CommandLine) {
        $fields += @{ Label = 'Command'; Value = [string]$Data.CommandLine; IsVirtual = $false }
    }

    $rowHeight = 28
    $topMargin = 8
    $dlgWidth = 420
    $clientHeight = $topMargin + ($fields.Count * $rowHeight) + 38
    $purpleBg = [System.Drawing.Color]::FromArgb(0xEA, 0xDD, 0xF7)
    $purpleAccent = [System.Drawing.Color]::FromArgb(0x6A, 0x1B, 0x9A)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Details - $label"
    $dlg.ClientSize = New-Object System.Drawing.Size($dlgWidth, $clientHeight)
    $dlg.StartPosition = 'Manual'
    $dlg.FormBorderStyle = 'FixedToolWindow'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $script:Theme.WindowBg
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $screenArea = [System.Windows.Forms.Screen]::FromPoint($ScreenPoint).WorkingArea
    $px = [Math]::Max($screenArea.Left, [Math]::Min($ScreenPoint.X, $screenArea.Right - $dlg.Width))
    $py = [Math]::Max($screenArea.Top, [Math]::Min($ScreenPoint.Y, $screenArea.Bottom - $dlg.Height))
    $dlg.Location = New-Object System.Drawing.Point($px, $py)

    $rowY = $topMargin
    $allValuesText = New-Object System.Text.StringBuilder
    [System.Windows.Forms.Control[]]$rowPanels = @()

    foreach ($f in $fields) {
        $rowPanel = New-Object System.Windows.Forms.Panel
        $rowPanel.Location = New-Object System.Drawing.Point(0, $rowY)
        $rowPanel.Size = New-Object System.Drawing.Size($dlgWidth, $rowHeight)
        $rowPanel.BackColor = if ($f.IsVirtual) { $purpleBg } else { $script:Theme.WindowBg }

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = "$($f.Label):"
        $lbl.Location = New-Object System.Drawing.Point(10, 6)
        $lbl.Size = New-Object System.Drawing.Size(88, 16)
        $lbl.ForeColor = if ($f.IsVirtual) { $purpleAccent } else { $script:Theme.TextDim }
        $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
        $lbl.BackColor = [System.Drawing.Color]::Transparent

        $valueLbl = New-Object System.Windows.Forms.Label
        $valueLbl.Text = $f.Value
        $valueLbl.AutoEllipsis = $true
        $valueLbl.Location = New-Object System.Drawing.Point(100, 6)
        $valueLbl.Size = New-Object System.Drawing.Size(($dlgWidth - 100 - 42), 16)
        $valueLbl.ForeColor = $script:Theme.TextPrimary
        $valueLbl.BackColor = [System.Drawing.Color]::Transparent

        $copyBtn = New-Object System.Windows.Forms.Button
        $copyBtn.Location = New-Object System.Drawing.Point(($dlgWidth - 34), 0)
        $copyBtn.Size = New-Object System.Drawing.Size(26, 26)
        $capturedValue = $f.Value
        $copyBtn.Add_Click({ if ($capturedValue) { [System.Windows.Forms.Clipboard]::SetText($capturedValue) } }.GetNewClosure())
        Initialize-ModernButton -Button $copyBtn -Radius 6
        $copyBtn.Text = [string][char]0xE8C8
        $copyBtn.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 10)

        [System.Windows.Forms.Control[]]$rowChildren = @($lbl, $valueLbl, $copyBtn)
        $rowPanel.Controls.AddRange($rowChildren)
        $rowPanels += $rowPanel

        [void]$allValuesText.AppendLine("$($f.Label): $($f.Value)")
        $rowY += $rowHeight
    }

    $dlg.Controls.AddRange($rowPanels)

    $bottomPanel = New-Object System.Windows.Forms.Panel
    $bottomPanel.Dock = 'Bottom'
    $bottomPanel.Height = 34
    $bottomPanel.BackColor = $script:Theme.PanelBg

    $copyAllButton = New-Object System.Windows.Forms.Button
    $copyAllButton.Text = 'Copy All'
    $copyAllButton.Location = New-Object System.Drawing.Point(8, 3)
    $copyAllButton.Size = New-Object System.Drawing.Size(78, 26)
    $allText = $allValuesText.ToString()
    $copyAllButton.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($allText) }.GetNewClosure())
    Initialize-ModernButton -Button $copyAllButton

    [System.Windows.Forms.Control[]]$bottomControls = @($copyAllButton)
    $bottomPanel.Controls.AddRange($bottomControls)
    $dlg.Controls.Add($bottomPanel)

    $dlg.ShowDialog($form) | Out-Null
}

function Register-GridEvents {
    param($Grid)

    $Grid.Add_CellContentClick({
        param($s, $e)
        if ($e.RowIndex -lt 0) { return }
        $row = $s.Rows[$e.RowIndex]
        if ($row.Tag -eq 'separator') { return }
        $data = $row.Tag
        if ($e.ColumnIndex -eq $script:ColIdx.Action) {
            Invoke-ToggleAction $data
        } elseif ($e.ColumnIndex -eq $script:ColIdx.Log) {
            Invoke-Restart $data
        } elseif ($e.ColumnIndex -eq $script:ColIdx.Pin) {
            Invoke-TogglePin $data
        }
    })

    $Grid.Add_CellDoubleClick({
        param($s, $e)
        if ($e.RowIndex -lt 0) { return }
        $row = $s.Rows[$e.RowIndex]
        if ($row.Tag -eq 'separator') { return }
        if ($e.ColumnIndex -eq $script:ColIdx.Action -or $e.ColumnIndex -eq $script:ColIdx.Log -or $e.ColumnIndex -eq $script:ColIdx.Pin) { return }
        $data = $row.Tag
        if (-not $data) { return }
        $label = if ($data.CustomName) { $data.CustomName } elseif ($data.ProjectPath) { Split-Path -Leaf $data.ProjectPath } else { "Port $($data.Port)" }
        Show-LogViewer -ProjectPath $data.ProjectPath -Title $label
    })

    $Grid.Add_CellMouseDown({
        param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
        if ($e.RowIndex -lt 0) { return }
        $row = $s.Rows[$e.RowIndex]
        if ($row.Tag -eq 'separator') { return }
        $data = $row.Tag
        if (-not $data) { return }
        $s.ClearSelection()
        $row.Selected = $true
        # Used to be a right-click context menu with a single "Detail..."
        # item - a one-entry dropdown always looks broken (empty icon
        # gutter, menu wider than the text needs) and it was just an extra
        # click to the only thing it could ever do. Right-click opens the
        # detail popup directly now, positioned at the actual cursor
        # (Cursor.Position, not e.X/e.Y, which are cell-relative not
        # screen-relative).
        $screenPoint = [System.Windows.Forms.Cursor]::Position
        Show-RowDetail -Data $data -ScreenPoint $screenPoint
    })

    $Grid.Add_CellEndEdit({
        param($s, $e)
        if ($e.RowIndex -lt 0 -or $e.ColumnIndex -ne $script:ColIdx.CustomName) { return }
        $row = $s.Rows[$e.RowIndex]
        $data = $row.Tag
        if (-not $data) { return }

        $newName = [string]$row.Cells[$script:ColIdx.CustomName].Value
        $nameKey = Get-CustomNameKey -ProjectPath $data.ProjectPath -Port $data.Port

        if ([string]::IsNullOrWhiteSpace($newName)) {
            if ($script:CustomNames.ContainsKey($nameKey)) { $script:CustomNames.Remove($nameKey) }
        } else {
            $script:CustomNames[$nameKey] = $newName
        }
        Save-CustomNames $script:CustomNames
    })
}

function Register-SystemGridEvents {
    # Deliberately a smaller event set than Register-GridEvents: no
    # Action/Log wiring at all (those columns are hidden on this grid, but
    # this is belt-and-suspenders - Invoke-ToggleAction/Invoke-Restart must
    # never be reachable for a row whose PID can be a protected OS process),
    # and no double-click log viewer since these rows have no project/log to
    # show. Right-click "Detail..." and the Custom Name column still work,
    # same as Live/History.
    param($Grid)

    $Grid.Add_CellMouseDown({
        param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
        if ($e.RowIndex -lt 0) { return }
        $row = $s.Rows[$e.RowIndex]
        if ($row.Tag -eq 'separator') { return }
        $data = $row.Tag
        if (-not $data) { return }
        $s.ClearSelection()
        $row.Selected = $true
        # Used to be a right-click context menu with a single "Detail..."
        # item - a one-entry dropdown always looks broken (empty icon
        # gutter, menu wider than the text needs) and it was just an extra
        # click to the only thing it could ever do. Right-click opens the
        # detail popup directly now.
        $screenPoint = [System.Windows.Forms.Cursor]::Position
        Show-RowDetail -Data $data -ScreenPoint $screenPoint
    })

    $Grid.Add_CellEndEdit({
        param($s, $e)
        if ($e.RowIndex -lt 0 -or $e.ColumnIndex -ne $script:ColIdx.CustomName) { return }
        $row = $s.Rows[$e.RowIndex]
        $data = $row.Tag
        if (-not $data) { return }

        $newName = [string]$row.Cells[$script:ColIdx.CustomName].Value
        $nameKey = Get-CustomNameKey -ProjectPath $data.ProjectPath -Port $data.Port

        if ([string]::IsNullOrWhiteSpace($newName)) {
            if ($script:CustomNames.ContainsKey($nameKey)) { $script:CustomNames.Remove($nameKey) }
        } else {
            $script:CustomNames[$nameKey] = $newName
        }
        Save-CustomNames $script:CustomNames
    })
}

Register-GridEvents -Grid $liveGrid
Register-GridEvents -Grid $historyGrid
Register-SystemGridEvents -Grid $systemGrid

function Show-AboutDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'About Localhost Manager'
    $dlg.Size = New-Object System.Drawing.Size(380, 300)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Icon = $script:IconOk
    $dlg.BackColor = [System.Drawing.Color]::White
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $iconBox = New-Object System.Windows.Forms.PictureBox
    $iconBox.Image = $script:IconOk.ToBitmap()
    $iconBox.SizeMode = 'CenterImage'
    $iconBox.Location = New-Object System.Drawing.Point(20, 24)
    $iconBox.Size = New-Object System.Drawing.Size(48, 48)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = 'Localhost Manager'
    $titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = $script:Theme.TextPrimary
    $titleLabel.Location = New-Object System.Drawing.Point(80, 24)
    $titleLabel.Size = New-Object System.Drawing.Size(270, 28)

    $versionLabel = New-Object System.Windows.Forms.Label
    $versionLabel.Text = 'Version 1.7.0'
    $versionLabel.ForeColor = $script:Theme.TextDim
    $versionLabel.Location = New-Object System.Drawing.Point(80, 54)
    $versionLabel.Size = New-Object System.Drawing.Size(270, 20)

    $descLabel = New-Object System.Windows.Forms.Label
    $descLabel.Text = 'Scans your machine for running localhost dev servers, shows their status and LAN URLs, and lets you start/stop them individually or in named groups.'
    $descLabel.ForeColor = $script:Theme.TextPrimary
    $descLabel.Location = New-Object System.Drawing.Point(20, 96)
    $descLabel.Size = New-Object System.Drawing.Size(330, 60)

    $linkLabel = New-Object System.Windows.Forms.LinkLabel
    $linkLabel.Text = 'github.com/zanopyth/local-host-manager'
    $linkLabel.LinkColor = $script:Theme.Accent
    $linkLabel.ActiveLinkColor = $script:Theme.AccentDark
    $linkLabel.Location = New-Object System.Drawing.Point(20, 162)
    $linkLabel.Size = New-Object System.Drawing.Size(330, 20)
    $linkLabel.Add_LinkClicked({
        try { Start-Process 'https://github.com/zanopyth/local-host-manager' } catch {}
    })

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = 'Close'
    $closeButton.Location = New-Object System.Drawing.Point(265, 210)
    $closeButton.Size = New-Object System.Drawing.Size(85, 28)
    $closeButton.Add_Click({ $dlg.Close() })
    Initialize-ModernButton -Button $closeButton -Variant Accent

    [System.Windows.Forms.Control[]]$dlgControls = @($iconBox, $titleLabel, $versionLabel, $descLabel, $linkLabel, $closeButton)
    $dlg.Controls.AddRange($dlgControls)
    $dlg.AcceptButton = $closeButton
    $dlg.ShowDialog($form) | Out-Null
}

function Show-SettingsDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Settings'
    $dlg.Size = New-Object System.Drawing.Size(480, 270)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $script:Theme.WindowBg
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Only show projects under this root directory:'
    $lbl.Location = New-Object System.Drawing.Point(15, 15)
    $lbl.Size = New-Object System.Drawing.Size(400, 20)
    $lbl.ForeColor = $script:Theme.TextPrimary

    $pathBox = New-Object System.Windows.Forms.TextBox
    $pathBox.Text = $script:RootDir
    $pathBox.Location = New-Object System.Drawing.Point(15, 40)
    $pathBox.Size = New-Object System.Drawing.Size(330, 24)
    $pathBox.ReadOnly = $true
    $pathBox.BorderStyle = 'FixedSingle'
    $pathBox.BackColor = [System.Drawing.Color]::White
    $pathBox.ForeColor = $script:Theme.TextPrimary

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Text = 'Browse...'
    $browseButton.Location = New-Object System.Drawing.Point(355, 39)
    $browseButton.Size = New-Object System.Drawing.Size(95, 26)
    $browseButton.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($pathBox.Text) { $fbd.SelectedPath = $pathBox.Text }
        if ($fbd.ShowDialog() -eq 'OK') { $pathBox.Text = $fbd.SelectedPath }
    })
    Initialize-ModernButton -Button $browseButton

    $clearButton = New-Object System.Windows.Forms.Button
    $clearButton.Text = 'Clear (no restriction)'
    $clearButton.Location = New-Object System.Drawing.Point(15, 75)
    $clearButton.Size = New-Object System.Drawing.Size(170, 26)
    $clearButton.Add_Click({ $pathBox.Text = '' })
    Initialize-ModernButton -Button $clearButton

    $systemPortsSwitch = New-ToggleSwitch -Checked ([bool]$script:Settings.ShowSystemPorts)
    $systemPortsSwitch.Location = New-Object System.Drawing.Point(15, 116)

    $systemPortsLbl = New-Object System.Windows.Forms.Label
    $systemPortsLbl.Text = 'Show system-owned ports'
    $systemPortsLbl.Location = New-Object System.Drawing.Point(60, 116)
    $systemPortsLbl.Size = New-Object System.Drawing.Size(250, 20)
    $systemPortsLbl.ForeColor = $script:Theme.TextPrimary
    Connect-ToggleLabel -Switch $systemPortsSwitch -Label $systemPortsLbl

    $systemPortsHintLbl = New-Object System.Windows.Forms.Label
    $systemPortsHintLbl.Text = "Adds a System tab for ports owned by OS processes (System, svchost, lsass, ...) - e.g. a kernel http.sys listener shadowing a port you meant to use yourself. Read-only: nothing here can be stopped or restarted."
    $systemPortsHintLbl.Location = New-Object System.Drawing.Point(15, 142)
    $systemPortsHintLbl.Size = New-Object System.Drawing.Size(435, 48)
    $systemPortsHintLbl.ForeColor = $script:Theme.TextDim
    $systemPortsHintLbl.Font = New-Object System.Drawing.Font('Segoe UI', 8)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'OK'
    $okButton.Location = New-Object System.Drawing.Point(275, 195)
    $okButton.Size = New-Object System.Drawing.Size(85, 28)
    $okButton.Add_Click({ $dlg.Tag = 'OK'; $dlg.Close() })
    Initialize-ModernButton -Button $okButton -Variant Accent

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = New-Object System.Drawing.Point(365, 195)
    $cancelButton.Size = New-Object System.Drawing.Size(85, 28)
    $cancelButton.Add_Click({ $dlg.Close() })
    Initialize-ModernButton -Button $cancelButton

    [System.Windows.Forms.Control[]]$dlgControls = @($lbl, $pathBox, $browseButton, $clearButton, $systemPortsSwitch, $systemPortsLbl, $systemPortsHintLbl, $okButton, $cancelButton)
    $dlg.Controls.AddRange($dlgControls)
    $dlg.AcceptButton = $okButton
    $dlg.ShowDialog($form) | Out-Null

    if ($dlg.Tag -eq 'OK') {
        $script:RootDir = $pathBox.Text
        $script:Settings.RootDir = $script:RootDir
        $script:Settings.ShowSystemPorts = Get-ToggleChecked $systemPortsSwitch
        Save-Settings $script:Settings
        Update-ScopeLabel
        Update-SystemTabState
        Refresh-Grid
    }
}

function Show-DashboardDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Dashboard'
    $dlg.Size = New-Object System.Drawing.Size(480, 300)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $script:Theme.WindowBg
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $introLbl = New-Object System.Windows.Forms.Label
    $introLbl.Text = 'View the current table and stop/restart projects from a browser, on this PC or (once you set up reachability) your LAN/Tailnet.'
    $introLbl.Location = New-Object System.Drawing.Point(15, 15)
    $introLbl.Size = New-Object System.Drawing.Size(435, 34)
    $introLbl.ForeColor = $script:Theme.TextDim

    $enableSwitch = New-ToggleSwitch -Checked ([bool]$script:Settings.DashboardEnabled)
    $enableSwitch.Location = New-Object System.Drawing.Point(15, 58)

    $enableLbl = New-Object System.Windows.Forms.Label
    $enableLbl.Text = 'Enable web dashboard'
    $enableLbl.Location = New-Object System.Drawing.Point(60, 58)
    $enableLbl.Size = New-Object System.Drawing.Size(250, 20)
    $enableLbl.ForeColor = $script:Theme.TextPrimary
    Connect-ToggleLabel -Switch $enableSwitch -Label $enableLbl

    $offByDefaultLbl = New-Object System.Windows.Forms.Label
    $offByDefaultLbl.Text = 'Off by default. Nothing listens on any port until you enable it here.'
    $offByDefaultLbl.Location = New-Object System.Drawing.Point(15, 84)
    $offByDefaultLbl.Size = New-Object System.Drawing.Size(435, 18)
    $offByDefaultLbl.ForeColor = $script:Theme.TextDim
    $offByDefaultLbl.Font = New-Object System.Drawing.Font('Segoe UI', 8)

    $portLbl = New-Object System.Windows.Forms.Label
    $portLbl.Text = 'Port:'
    $portLbl.Location = New-Object System.Drawing.Point(15, 118)
    $portLbl.Size = New-Object System.Drawing.Size(40, 24)
    $portLbl.ForeColor = $script:Theme.TextPrimary
    $portLbl.TextAlign = 'MiddleLeft'

    $portBox = New-Object System.Windows.Forms.NumericUpDown
    $portBox.Location = New-Object System.Drawing.Point(60, 116)
    $portBox.Size = New-Object System.Drawing.Size(90, 24)
    $portBox.Minimum = 1024
    $portBox.Maximum = 65535
    $portBox.Value = [Math]::Max(1024, [Math]::Min(65535, [int]$script:Settings.WebPort))
    $portBox.Enabled = [bool]$script:Settings.DashboardEnabled

    Set-ToggleOnChange -Switch $enableSwitch -Handler {
        $portBox.Enabled = Get-ToggleChecked $enableSwitch
    }.GetNewClosure()

    $statusLbl = New-Object System.Windows.Forms.Label
    $statusLbl.Location = New-Object System.Drawing.Point(15, 150)
    $statusLbl.Size = New-Object System.Drawing.Size(435, 60)
    $statusLbl.ForeColor = $script:Theme.TextDim
    $statusLbl.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    if ($script:Settings.DashboardEnabled -and $script:DashboardCache.Listening) {
        $addrText = (@($script:DashboardCache.Addresses) | ForEach-Object { "$($_.Label): $($_.Url)" }) -join "`n"
        $statusLbl.Text = "Currently running.`n$addrText"
    } elseif ($script:Settings.DashboardEnabled -and $script:DashboardCache.ListenError) {
        $statusLbl.Text = "Enabled but failed to start: $($script:DashboardCache.ListenError)"
    } elseif ($script:Settings.DashboardEnabled) {
        $statusLbl.Text = 'Enabled, starting...'
    } else {
        $statusLbl.Text = 'Not running.'
    }

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'OK'
    $okButton.Location = New-Object System.Drawing.Point(275, 225)
    $okButton.Size = New-Object System.Drawing.Size(85, 28)
    $okButton.Add_Click({ $dlg.Tag = 'OK'; $dlg.Close() })
    Initialize-ModernButton -Button $okButton -Variant Accent

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = New-Object System.Drawing.Point(365, 225)
    $cancelButton.Size = New-Object System.Drawing.Size(85, 28)
    $cancelButton.Add_Click({ $dlg.Close() })
    Initialize-ModernButton -Button $cancelButton

    [System.Windows.Forms.Control[]]$dlgControls = @($introLbl, $enableSwitch, $enableLbl, $offByDefaultLbl, $portLbl, $portBox, $statusLbl, $okButton, $cancelButton)
    $dlg.Controls.AddRange($dlgControls)
    $dlg.AcceptButton = $okButton
    $dlg.ShowDialog($form) | Out-Null

    if ($dlg.Tag -eq 'OK') {
        $newEnabled = Get-ToggleChecked $enableSwitch
        $newPort = [int]$portBox.Value
        $wasEnabled = [bool]$script:Settings.DashboardEnabled
        $portChanged = $newPort -ne [int]$script:Settings.WebPort

        $script:Settings.DashboardEnabled = $newEnabled
        $script:Settings.WebPort = $newPort
        Save-Settings $script:Settings

        if ($newEnabled -and -not $wasEnabled) {
            Start-WebDashboard -Port $newPort
        } elseif (-not $newEnabled -and $wasEnabled) {
            Stop-WebDashboard
        } elseif ($newEnabled -and $wasEnabled -and $portChanged) {
            Restart-WebDashboard -Port $newPort
        }
        Update-DashboardPill
    }
}

function Get-KnownProjects {
    param([bool]$OnlyNode = $true)
    $allRows = @(Build-Rows -OnlyNode $OnlyNode -RootDir '')
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

function Set-GroupPortsPinned {
    # One-shot bulk pin, not a persisted per-group setting: applied to
    # whatever ports are on record (live or historical) for these project
    # paths at the moment you hit Save Group. History is keyed by port, not
    # project path, and a project can have more than one port on record
    # (e.g. it ran on a different port once before) - every matching entry
    # gets pinned, not just the most recent.
    param([string[]]$ProjectPaths)
    $targets = New-Object System.Collections.Generic.HashSet[string]
    foreach ($p in $ProjectPaths) { [void]$targets.Add((Get-NormalizedPath $p)) }

    $history = Load-History
    $pinnedCount = 0
    foreach ($key in @($history.Keys)) {
        $h = $history[$key]
        if ($h.ProjectPath -and $targets.Contains((Get-NormalizedPath $h.ProjectPath))) {
            if (-not [bool]$h.Pinned) { $pinnedCount++ }
            $h.Pinned = $true
        }
    }
    Save-History $history
    return $pinnedCount
}

function Show-ManageGroupsDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Manage Groups'
    $dlg.Size = New-Object System.Drawing.Size(460, 486)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $script:Theme.WindowBg
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $nameLabel = New-Object System.Windows.Forms.Label
    $nameLabel.Text = 'Group name:'
    $nameLabel.Location = New-Object System.Drawing.Point(15, 15)
    $nameLabel.Size = New-Object System.Drawing.Size(100, 20)
    $nameLabel.ForeColor = $script:Theme.TextPrimary

    $nameCombo = New-Object System.Windows.Forms.ComboBox
    $nameCombo.DropDownStyle = 'DropDown'
    $nameCombo.Location = New-Object System.Drawing.Point(15, 38)
    $nameCombo.Size = New-Object System.Drawing.Size(415, 24)
    foreach ($n in ($script:Groups.Keys | Sort-Object)) { $nameCombo.Items.Add($n) | Out-Null }

    $projLabel = New-Object System.Windows.Forms.Label
    $projLabel.Text = 'Projects in this group:'
    $projLabel.Location = New-Object System.Drawing.Point(15, 70)
    $projLabel.Size = New-Object System.Drawing.Size(200, 20)
    $projLabel.ForeColor = $script:Theme.TextPrimary

    $showAllCheck = New-Object System.Windows.Forms.CheckBox
    $showAllCheck.Text = 'Show all listening ports (not just Node/dev servers)'
    $showAllCheck.Location = New-Object System.Drawing.Point(15, 92)
    $showAllCheck.Size = New-Object System.Drawing.Size(415, 20)
    $showAllCheck.ForeColor = $script:Theme.TextPrimary

    $pinGroupCheck = New-Object System.Windows.Forms.CheckBox
    $pinGroupCheck.Text = 'Pin all ports in this group (keeps them listed even after they stop)'
    $pinGroupCheck.Location = New-Object System.Drawing.Point(15, 114)
    $pinGroupCheck.Size = New-Object System.Drawing.Size(415, 20)
    $pinGroupCheck.ForeColor = $script:Theme.TextPrimary

    $projList = New-Object System.Windows.Forms.CheckedListBox
    $projList.Location = New-Object System.Drawing.Point(15, 140)
    $projList.Size = New-Object System.Drawing.Size(415, 236)
    $projList.CheckOnClick = $true
    $projList.BorderStyle = 'FixedSingle'

    # Boxed in a hashtable so event handlers (each running in their own
    # PowerShell scope) can update it in place without needing $script: scope.
    $state = @{ KnownProjects = @(Get-KnownProjects -OnlyNode $true) }
    foreach ($p in $state.KnownProjects) { $projList.Items.Add($p.Label) | Out-Null }

    function Set-CheckedFromGroup {
        param([string]$GroupName)
        for ($i = 0; $i -lt $projList.Items.Count; $i++) { $projList.SetItemChecked($i, $false) }
        if (-not $GroupName -or -not $script:Groups.ContainsKey($GroupName)) { return }
        $paths = @($script:Groups[$GroupName] | ForEach-Object { Get-NormalizedPath $_ })
        for ($i = 0; $i -lt $state.KnownProjects.Count; $i++) {
            if ($paths -contains (Get-NormalizedPath $state.KnownProjects[$i].ProjectPath)) { $projList.SetItemChecked($i, $true) }
        }
    }

    $nameCombo.Add_SelectedIndexChanged({ Set-CheckedFromGroup -GroupName $nameCombo.Text })

    $showAllCheck.Add_CheckedChanged({
        $state.KnownProjects = @(Get-KnownProjects -OnlyNode (-not $showAllCheck.Checked))
        $projList.Items.Clear()
        foreach ($p in $state.KnownProjects) { $projList.Items.Add($p.Label) | Out-Null }
        Set-CheckedFromGroup -GroupName $nameCombo.Text
    })

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = 'Save Group'
    $saveButton.Location = New-Object System.Drawing.Point(15, 391)
    $saveButton.Size = New-Object System.Drawing.Size(110, 28)
    Initialize-ModernButton -Button $saveButton -Variant Success
    $saveButton.Add_Click({
        $name = $nameCombo.Text.Trim()
        if (-not $name) {
            [System.Windows.Forms.MessageBox]::Show('Enter a group name.', 'Cannot Save', 'OK', 'Warning') | Out-Null
            return
        }
        $paths = @()
        for ($i = 0; $i -lt $state.KnownProjects.Count; $i++) {
            if ($projList.GetItemChecked($i)) { $paths += $state.KnownProjects[$i].ProjectPath }
        }
        $script:Groups[$name] = $paths
        Save-Groups $script:Groups
        if (-not $nameCombo.Items.Contains($name)) { $nameCombo.Items.Add($name) | Out-Null }
        Update-GroupsButtonText

        $pinnedNote = ''
        if ($pinGroupCheck.Checked -and $paths.Count -gt 0) {
            $pinnedCount = Set-GroupPortsPinned -ProjectPaths $paths
            $pinnedNote = " Pinned $pinnedCount port(s) on record for this group."
        }
        Refresh-Grid
        [System.Windows.Forms.MessageBox]::Show("Saved group '$name' with $($paths.Count) project(s).$pinnedNote", 'Saved', 'OK', 'Information') | Out-Null
    })

    $deleteButton = New-Object System.Windows.Forms.Button
    $deleteButton.Text = 'Delete Group'
    $deleteButton.Location = New-Object System.Drawing.Point(135, 391)
    $deleteButton.Size = New-Object System.Drawing.Size(110, 28)
    Initialize-ModernButton -Button $deleteButton -Variant Danger
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
    $closeButton.Location = New-Object System.Drawing.Point(345, 391)
    $closeButton.Size = New-Object System.Drawing.Size(85, 28)
    $closeButton.Add_Click({ $dlg.Close() })
    Initialize-ModernButton -Button $closeButton

    [System.Windows.Forms.Control[]]$dlgControls = @($nameLabel, $nameCombo, $projLabel, $showAllCheck, $pinGroupCheck, $projList, $saveButton, $deleteButton, $closeButton)
    $dlg.Controls.AddRange($dlgControls)
    $dlg.ShowDialog($form) | Out-Null
}

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
    $allRows = @(Build-Rows -OnlyNode $false -RootDir '')
    $toStart = @($allRows | Where-Object { $_.Status -eq 'OFF' -and $_.ProjectPath -and $paths.Contains((Get-NormalizedPath $_.ProjectPath)) })

    if ($toStart.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Everything in '$label' is already running (or has no known path).", 'Nothing to Start', 'OK', 'Information') | Out-Null
        return
    }
    $started = 0
    foreach ($row in $toStart) {
        if (Start-ProjectAtPath -ProjectPath $row.ProjectPath -CommandLine $row.CommandLine) { $started++ }
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
    $allRows = @(Build-Rows -OnlyNode $false -RootDir '')
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
Enable-RoundedPopup -Popup $trayMenu -Radius 8

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
    # Same data the main window's grid is built from — Dev-Servers-Only,
    # root-dir scope, and Use Groups/selected groups all apply here too, so
    # the tray icon/text always matches what's actually on screen.
    $allRows = @((Get-DisplayRows) | ForEach-Object { $_.Row })
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

    $allRows = @((Get-DisplayRows) | ForEach-Object { $_.Row })
    if ($allRows.Count -eq 0) {
        $emptyText = 'No projects in current scope'
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
        Stop-WebDashboard
    }
})

$refreshButton.Add_Click({ Refresh-Grid })
Set-ToggleOnChange -Switch $nodeOnlySwitch -Handler {
    $script:Settings.OnlyNode = Get-ToggleChecked $nodeOnlySwitch
    Save-Settings $script:Settings
    $menuSettingsNodeOnly.Checked = Get-ToggleChecked $nodeOnlySwitch
    Refresh-Grid
}
Set-ToggleOnChange -Switch $useGroupsSwitch -Handler {
    $script:Settings.ShowGroups = Get-ToggleChecked $useGroupsSwitch
    Save-Settings $script:Settings
    $menuSettingsUseGroups.Checked = Get-ToggleChecked $useGroupsSwitch
    Update-GroupsVisibility
    Refresh-Grid
}

# ---------------------------------------------------------------------------
# Web Dashboard — a read/control view of the current table at
# http://localhost:<port> (default 3199, configurable in Settings). Runs an
# HttpListener on its own background runspace (same pattern as the TCP
# poller above). It never touches UI-thread state directly: row data flows
# UI-thread -> DashboardCache.RowsJson (published on every Get-DisplayRowsSplit
# call, so it's always in sync with what's on screen); stop/start/restart
# requests flow listener-thread -> DashboardCache.Actions queue ->
# $script:DashboardActionTimer (UI thread, drains the queue and calls the
# same Stop-ProjectById/Start-ProjectAtPath used by the grid) ->
# DashboardCache.Results, which the listener thread polls for up to 8s
# before responding to the browser.
# ---------------------------------------------------------------------------
function Get-DashboardAddresses {
    param([int]$Port)
    $list = New-Object System.Collections.Generic.List[object]
    $list.Add([PSCustomObject]@{ Label = 'This PC'; Url = "http://localhost:$Port" })
    $seen = @{}
    foreach ($ipInfo in @(Get-LanIPv4Addresses)) {
        if ($seen.ContainsKey($ipInfo.IPAddress)) { continue }
        $seen[$ipInfo.IPAddress] = $true
        $info = Get-NetworkInterfaceLabel -InterfaceAlias $ipInfo.InterfaceAlias
        if ($info.IsVirtual) { continue }
        $list.Add([PSCustomObject]@{ Label = $info.Label; Url = "http://$($ipInfo.IPAddress):$Port" })
    }
    return @($list.ToArray() | Sort-Object { if ($_.Label -eq 'Tailscale') { 0 } elseif ($_.Label -eq 'This PC') { -1 } else { 1 } })
}

function Publish-DashboardRows {
    param($Display)
    if (-not $script:DashboardCache) { return }
    [object[]]$dashRows = @($Display | ForEach-Object {
        [PSCustomObject]@{
            Status      = $_.Row.Status
            Port        = $_.Row.Port
            CustomName  = $_.Row.CustomName
            ProcessName = $_.Row.ProcessName
            ProcId      = $_.Row.ProcId
            LocalUrl    = $_.Row.LocalUrl
            LanUrls     = $_.Row.LanUrls
            LanEntries  = @($_.Row.LanEntries | ForEach-Object { [PSCustomObject]@{ Label = $_.Label; Url = $_.Url } })
            ProjectPath = $_.Row.ProjectPath
            HasLog      = [bool]$_.Row.HasLog
            CommandLine = $_.Row.CommandLine
        }
    })
    # -InputObject (not the pipeline) is required so a single-row result
    # still serializes as a one-element JSON array instead of Windows
    # PowerShell 5.1's ConvertTo-Json unwrapping it to a bare object.
    $script:DashboardCache.RowsJson = ConvertTo-Json -InputObject $dashRows -Depth 6
}

function Invoke-DashboardAction {
    param($Action)
    $result = @{ Ok = $false; Message = '' }
    try {
        switch ($Action.Type) {
            'stop' {
                if (Stop-ProjectById -ProcId $Action.ProcId -ProjectPath $Action.ProjectPath) {
                    $result.Ok = $true; $result.Message = 'Stopped.'
                } else {
                    $result.Message = 'Could not stop process.'
                }
            }
            'start' {
                if (-not $Action.ProjectPath) {
                    $result.Message = 'No known project path for this port.'
                } elseif (Start-ProjectAtPath -ProjectPath $Action.ProjectPath -CommandLine $Action.CommandLine) {
                    $result.Ok = $true; $result.Message = 'Started.'
                } else {
                    $result.Message = 'Could not start project.'
                }
            }
            'restart' {
                if (-not $Action.ProjectPath) {
                    $result.Message = 'No known project path for this port.'
                } else {
                    $ok = $true
                    if ($Action.Status -eq 'ON') {
                        $ok = Stop-ProjectById -ProcId $Action.ProcId -ProjectPath $Action.ProjectPath
                        if ($ok) { Start-Sleep -Milliseconds 800 }
                    }
                    if (-not $ok) {
                        $result.Message = 'Could not stop process.'
                    } elseif (Start-ProjectAtPath -ProjectPath $Action.ProjectPath -CommandLine $Action.CommandLine) {
                        $result.Ok = $true; $result.Message = 'Restarted.'
                    } else {
                        $result.Message = 'Could not start project.'
                    }
                }
            }
            default { $result.Message = 'Unknown action.' }
        }
    } catch {
        $result.Message = $_.Exception.Message
    }
    Refresh-Grid
    return $result
}

function Get-DashboardHtml {
    param([int]$Port)
    $netshCmd = "netsh http add urlacl url=http://+:$Port/ user=Everyone"
    $faviconDataUri = ''
    try {
        $iconPath = Join-Path $script:AppDir 'LocalhostManager.ico'
        if (Test-Path $iconPath) {
            $iconBytes = [System.IO.File]::ReadAllBytes($iconPath)
            $faviconDataUri = 'data:image/x-icon;base64,' + [Convert]::ToBase64String($iconBytes)
        }
    } catch {}
    $html = @'
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Localhost Manager</title>
<link rel="icon" type="image/x-icon" href="__FAVICON_DATA_URI__">
<style>
  :root {
    --bg: #FAFAFA; --panel: #F2F1F0; --card: #FFFFFF; --border: #D1D1D1;
    --text: #2E3436; --dim: #77767B; --accent: #3584E4; --accent-dark: #1C71D8;
    --success: #26A269; --success-tint: #E3F6EC; --danger: #C01C28; --danger-tint: #FBE6E7;
  }
  * { box-sizing: border-box; }
  body { margin: 0; font-family: 'Segoe UI', system-ui, sans-serif; background: var(--bg); color: var(--text); }
  header { padding: 20px 24px 12px; }
  h1 { font-size: 20px; margin: 0 0 4px; display: flex; align-items: center; gap: 10px; }
  h1 img { width: 24px; height: 24px; }
  .sub { color: var(--dim); font-size: 13px; }
  .addrs { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 10px; }
  .addr { background: var(--card); border: 1px solid var(--border); border-radius: 6px; padding: 5px 10px; font-size: 12px; }
  .addr b { color: var(--accent-dark); }
  main { padding: 0 24px 24px; }
  table { width: 100%; border-collapse: collapse; background: var(--card); border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }
  th, td { text-align: left; padding: 9px 12px; font-size: 13px; border-bottom: 1px solid var(--border); }
  th { background: var(--panel); font-weight: 600; color: var(--dim); font-size: 11px; text-transform: uppercase; letter-spacing: .04em; }
  tr:last-child td { border-bottom: none; }
  .status { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px; font-weight: 600; }
  .status.ON { background: var(--success-tint); color: var(--success); }
  .status.OFF { background: var(--panel); color: var(--dim); }
  .status.CRASHED { background: var(--danger-tint); color: var(--danger); }
  .actions { white-space: nowrap; }
  button { font-family: inherit; font-size: 12px; padding: 5px 10px; border-radius: 6px; border: 1px solid var(--border); background: var(--card); color: var(--text); cursor: pointer; margin-right: 4px; }
  button.primary { background: var(--accent); color: white; border-color: var(--accent-dark); }
  button.danger { background: var(--danger); color: white; border-color: #8f1520; }
  button:disabled { opacity: .5; cursor: default; }
  .confirm { display: inline-flex; gap: 4px; align-items: center; }
  .empty { padding: 30px; text-align: center; color: var(--dim); }
  details { margin-top: 18px; background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 10px 14px; font-size: 12px; }
  summary { cursor: pointer; font-weight: 600; color: var(--dim); }
  code { background: var(--panel); padding: 2px 5px; border-radius: 4px; }
  a { color: var(--accent-dark); }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#1E1E20; --panel:#2A2A2D; --card:#232326; --border:#3A3A3D; --text:#E7E7E9; --dim:#9A9A9F; }
  }
</style>
</head>
<body>
<header>
  <h1><img src="__FAVICON_DATA_URI__" alt=""> Localhost Manager</h1>
  <div class="sub" id="statusLine">Loading...</div>
  <div class="addrs" id="addrList"></div>
  <div class="sub" id="bindWarning" style="display:none;color:var(--danger);margin-top:6px;">Currently reachable from this PC only &mdash; see remote access tips below to open it up.</div>
</header>
<main>
  <table>
    <thead><tr><th>Status</th><th>Port</th><th>Name</th><th>Process</th><th>Local URL</th><th>LAN</th><th class="actions">Action</th></tr></thead>
    <tbody id="rows"><tr><td class="empty" colspan="7">Loading...</td></tr></tbody>
  </table>
  <details>
    <summary>Remote access tips</summary>
    <p>This page is bound to this machine only by default. To reach it from other devices:</p>
    <p><b>Same Wi-Fi/LAN:</b> run this once as Administrator, then use one of the LAN addresses above:</p>
    <p><code>__NETSH_CMD__</code></p>
    <p><b>Remote / different network:</b> install <a href="https://tailscale.com/kb/1017/install" target="_blank">Tailscale</a> on this machine and any device that needs access, or advertise this machine's LAN as a subnet route so tailnet devices can reach it without installing Tailscale themselves &mdash; see <a href="https://tailscale.com/kb/1019/subnets" target="_blank">Tailscale's subnet routes docs</a>.</p>
  </details>
</main>
<script>
async function refresh() {
  try {
    const [rowsRes, metaRes] = await Promise.all([fetch('/api/rows'), fetch('/api/meta')]);
    const rows = await rowsRes.json();
    const meta = await metaRes.json();
    renderAddrs(meta);
    renderRows(rows);
    document.getElementById('statusLine').textContent = 'Live — last updated ' + new Date().toLocaleTimeString();
  } catch (e) {
    document.getElementById('statusLine').textContent = 'Connection lost, retrying...';
  }
}

function renderAddrs(meta) {
  const el = document.getElementById('addrList');
  el.innerHTML = (meta.Addresses || []).map(a =>
    '<span class="addr"><b>' + esc(a.Label) + ':</b> ' + esc(a.Url) + '</span>'
  ).join('');
  document.getElementById('bindWarning').style.display = meta.BoundWildcard ? 'none' : 'block';
}

function renderRows(rows) {
  const tbody = document.getElementById('rows');
  if (!rows.length) {
    tbody.innerHTML = '<tr><td class="empty" colspan="7">Nothing tracked yet.</td></tr>';
    return;
  }
  tbody.innerHTML = rows.map(r => {
    const key = r.Port + '_' + (r.ProcId || 0);
    const canAct = !!r.ProjectPath;
    let actionCell = '';
    if (canAct) {
      actionCell = r.Status === 'ON'
        ? btn(key, 'stop', 'danger', 'Stop', r) + btn(key, 'restart', '', 'Restart', r)
        : btn(key, 'start', 'primary', 'Start', r);
    }
    return '<tr>' +
      '<td><span class="status ' + r.Status + '">' + r.Status + '</span></td>' +
      '<td>' + r.Port + '</td>' +
      '<td>' + esc(r.CustomName || '') + '</td>' +
      '<td>' + esc(r.ProcessName || '') + '</td>' +
      '<td>' + (r.Status === 'ON' ? '<a href="' + esc(r.LocalUrl) + '" target="_blank">' + esc(r.LocalUrl) + '</a>' : '') + '</td>' +
      '<td>' + renderLan(r) + '</td>' +
      '<td class="actions" id="act-' + key + '">' + actionCell + '</td>' +
      '</tr>';
  }).join('');
}

function renderLan(r) {
  if (r.LanEntries && r.LanEntries.length) {
    return r.LanEntries.map(function(e) {
      return '<a href="' + esc(e.Url) + '" target="_blank" title="' + esc(e.Label) + '">' + esc(e.Url) + '</a>';
    }).join(', ');
  }
  return esc(r.LanUrls || '');
}

function btn(key, type, cls, label, row) {
  return '<button class="' + cls + '" data-key="' + key + '" data-type="' + type + '" ' +
    'data-procid="' + (row.ProcId || 0) + '" data-status="' + esc(row.Status) + '" ' +
    'data-path="' + esc(row.ProjectPath || '') + '">' + label + '</button>';
}

document.getElementById('rows').addEventListener('click', (e) => {
  const b = e.target.closest('button[data-type]');
  if (!b) return;
  const cell = b.closest('td');
  const row = { ProcId: Number(b.dataset.procid), ProjectPath: b.dataset.path, Status: b.dataset.status };
  confirmAction(cell, b.dataset.type, row);
});

function confirmAction(cell, type, row) {
  const prevHtml = cell.innerHTML;
  cell.innerHTML = '<span class="confirm">' + type + '? ' +
    '<button class="danger yesBtn">Yes</button>' +
    '<button class="noBtn">No</button></span>';
  cell.querySelector('.noBtn').onclick = () => { cell.innerHTML = prevHtml; };
  cell.querySelector('.yesBtn').onclick = () => runAction(cell, type, row);
}

async function runAction(cell, type, row) {
  cell.innerHTML = '<button disabled>Working...</button>';
  try {
    const res = await fetch('/api/' + type, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ProcId: row.ProcId, ProjectPath: row.ProjectPath, Status: row.Status, CommandLine: row.CommandLine })
    });
    const result = await res.json();
    if (!result.Ok) { alert(result.Message || 'Action failed.'); }
  } catch (e) {
    alert('Request failed: ' + e);
  }
  refresh();
}

function esc(s) {
  return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

refresh();
setInterval(refresh, 1500);
</script>
</body>
</html>
'@
    return $html.Replace('__NETSH_CMD__', $netshCmd).Replace('__FAVICON_DATA_URI__', $faviconDataUri)
}

$script:DashboardListenScript = {
    param($Cache, $Html)

    $listener = New-Object System.Net.HttpListener
    $boundOk = $false
    try {
        $listener.Prefixes.Add("http://+:$($Cache.Port)/")
        $listener.Start()
        $boundOk = $true
        $Cache.BoundWildcard = $true
    } catch {
        try { $listener.Close() } catch {}
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://localhost:$($Cache.Port)/")
        $listener.Prefixes.Add("http://127.0.0.1:$($Cache.Port)/")
        try {
            $listener.Start()
            $boundOk = $true
            $Cache.BoundWildcard = $false
        } catch {
            $Cache.ListenError = $_.Exception.Message
            $boundOk = $false
        }
    }
    $Cache.Listening = $boundOk
    if (-not $boundOk) { return }

    while (-not $Cache.StopRequested) {
        $context = $null
        try {
            $asyncResult = $listener.BeginGetContext($null, $null)
            while (-not $asyncResult.AsyncWaitHandle.WaitOne(500)) {
                if ($Cache.StopRequested) { try { $listener.Stop() } catch {}; return }
            }
            $context = $listener.EndGetContext($asyncResult)
        } catch {
            if ($Cache.StopRequested) { return }
            continue
        }
        if (-not $context) { continue }

        $req = $context.Request
        $res = $context.Response
        try {
            $path = $req.Url.AbsolutePath
            if ($req.HttpMethod -eq 'GET' -and $path -eq '/') {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($Html)
                $res.ContentType = 'text/html; charset=utf-8'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/rows') {
                $json = $Cache.RowsJson
                if (-not $json) { $json = '[]' }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/meta') {
                $meta = ConvertTo-Json -InputObject @{ Addresses = $Cache.Addresses; Port = $Cache.Port; BoundWildcard = $Cache.BoundWildcard } -Depth 4
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($meta)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            elseif ($req.HttpMethod -eq 'POST' -and ($path -eq '/api/stop' -or $path -eq '/api/restart' -or $path -eq '/api/start')) {
                $enc = if ($req.ContentEncoding) { $req.ContentEncoding } else { [System.Text.Encoding]::UTF8 }
                $reader = New-Object System.IO.StreamReader($req.InputStream, $enc)
                $bodyText = $reader.ReadToEnd()
                $reader.Close()
                $body = $null
                try { $body = $bodyText | ConvertFrom-Json } catch {}

                $type = 'start'
                if ($path -eq '/api/stop') { $type = 'stop' } elseif ($path -eq '/api/restart') { $type = 'restart' }
                $id = [guid]::NewGuid().ToString()
                $action = @{
                    Id          = $id
                    Type        = $type
                    ProcId      = if ($body.ProcId) { [int]$body.ProcId } else { 0 }
                    ProjectPath = [string]$body.ProjectPath
                    Status      = [string]$body.Status
                    CommandLine = [string]$body.CommandLine
                }
                $Cache.Actions.Enqueue($action)

                $waited = 0
                $result = $null
                while ($waited -lt 8000) {
                    if ($Cache.Results.ContainsKey($id)) {
                        $result = $Cache.Results[$id]
                        [void]$Cache.Results.Remove($id)
                        break
                    }
                    Start-Sleep -Milliseconds 150
                    $waited += 150
                }
                if (-not $result) { $result = @{ Ok = $false; Message = 'Timed out waiting for the app to process the action.' } }

                $json = ConvertTo-Json -InputObject $result -Depth 3
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            else {
                $res.StatusCode = 404
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('Not found')
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
        } catch {
            try { $res.StatusCode = 500 } catch {}
        } finally {
            try { $res.OutputStream.Close() } catch {}
        }
    }
    try { $listener.Stop() } catch {}
    try { $listener.Close() } catch {}
}

function Start-WebDashboard {
    param([int]$Port)
    $script:DashboardCache.StopRequested = $false
    $script:DashboardCache.Port = $Port
    $script:DashboardCache.Addresses = @(Get-DashboardAddresses -Port $Port)
    $script:DashboardCache.Listening = $false
    $script:DashboardCache.ListenError = ''
    $script:DashboardNotifiedFailure = $false

    $html = Get-DashboardHtml -Port $Port

    $script:DashboardRunspace = [runspacefactory]::CreateRunspace()
    $script:DashboardRunspace.ApartmentState = 'MTA'
    $script:DashboardRunspace.ThreadOptions = 'ReuseThread'
    $script:DashboardRunspace.Open()

    $script:DashboardShell = [powershell]::Create()
    $script:DashboardShell.Runspace = $script:DashboardRunspace
    [void]$script:DashboardShell.AddScript($script:DashboardListenScript).
        AddArgument($script:DashboardCache).
        AddArgument($html)
    $script:DashboardHandle = $script:DashboardShell.BeginInvoke()
}

function Stop-WebDashboard {
    if (-not $script:DashboardShell) { return }
    $script:DashboardCache.StopRequested = $true
    try { $script:DashboardShell.Stop() } catch {}
    try { $script:DashboardShell.Dispose() } catch {}
    try { $script:DashboardRunspace.Close() } catch {}
    $script:DashboardShell = $null
    $script:DashboardRunspace = $null
}

function Restart-WebDashboard {
    param([int]$Port)
    Stop-WebDashboard
    Start-WebDashboard -Port $Port
}

$script:DashboardNotifiedFailure = $false
$script:DashboardActionTimer = New-Object System.Windows.Forms.Timer
$script:DashboardActionTimer.Interval = 300
$script:DashboardActionTimer.Add_Tick({
    while ($script:DashboardCache.Actions.Count -gt 0) {
        $action = $script:DashboardCache.Actions.Dequeue()
        $result = Invoke-DashboardAction -Action $action
        $script:DashboardCache.Results[$action.Id] = $result
    }
    if ($script:DashboardCache.Listening) {
        $script:DashboardCache.Addresses = @(Get-DashboardAddresses -Port $script:DashboardCache.Port)
    } elseif ($script:DashboardCache.ListenError -and -not $script:DashboardNotifiedFailure) {
        $script:DashboardNotifiedFailure = $true
        try {
            $notifyIcon.ShowBalloonTip(4000, 'Localhost Manager', "Web dashboard failed to start on port $($script:DashboardCache.Port): $($script:DashboardCache.ListenError)", [System.Windows.Forms.ToolTipIcon]::Warning)
        } catch {}
    }
    Update-DashboardPill
})
$script:DashboardActionTimer.Start()

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
    if ($script:Settings.DashboardEnabled) {
        Start-WebDashboard -Port ([int]$script:Settings.WebPort)
    }
    Update-DashboardPill
} catch {
    [System.Windows.Forms.MessageBox]::Show("Startup error: $_", 'Error') | Out-Null
}
[System.Windows.Forms.Application]::Run($form)
