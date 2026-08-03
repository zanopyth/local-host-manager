# Must run before any window/handle is created (hence first thing in the
# file, before even loading WinForms). Without an explicit DPI-awareness
# declaration, Windows treats this process as DPI-unaware on a scaled
# display (125%/150%, the common laptop/4K default) and bitmap-stretches
# the whole rendered window to match - which is what was fringing/blurring
# the menu and other ClearType text into a smeared "unfinished" look, while
# window chrome Windows draws itself (the title bar) stayed crisp. Per-
# Monitor-v2 (Win 10 1703+) is tried first for the sharpest result; each
# older API is a documented fallback for earlier Windows versions.
Add-Type -Name DpiAwareness -Namespace LocalhostManager -MemberDefinition @"
[DllImport("user32.dll")]
public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[DllImport("SHCore.dll")]
public static extern int SetProcessDpiAwareness(int value);
[DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
"@
try {
    # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    $ctx = [IntPtr](-4)
    if (-not [LocalhostManager.DpiAwareness]::SetProcessDpiAwarenessContext($ctx)) { throw 'unsupported' }
} catch {
    try { [void][LocalhostManager.DpiAwareness]::SetProcessDpiAwareness(2) }
    catch { try { [void][LocalhostManager.DpiAwareness]::SetProcessDPIAware() } catch {} }
}

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

Add-Type -Name TokenPriv -Namespace LocalhostManager -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)]
public struct LUID { public uint LowPart; public int HighPart; }

[StructLayout(LayoutKind.Sequential)]
public struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

[StructLayout(LayoutKind.Sequential)]
public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID Luid; public uint Attributes; }

[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

[DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

[DllImport("kernel32.dll")]
public static extern IntPtr GetCurrentProcess();
"@

# Best-effort: enable SeDebugPrivilege on our own token. Present only on a
# token that already has it (elevated/Administrator launches - UAC strips it
# from a standard token entirely), so this is a silent no-op unless run "as
# Administrator". Where it IS present, it lets ReadProcessMemory/PEB reads
# (Get-ProcessWorkingDirectory) succeed against processes this app couldn't
# otherwise open a handle into - notably ones spawned inside another tool's
# sandboxed/job-restricted shell (an agent or CI runner), which normally
# block cross-process memory reads from unrelated apps regardless of same
# user/session. Without this, such a process's working directory can only
# ever be recovered via the history fallback in Build-Rows, never read live.
function Enable-DebugPrivilege {
    try {
        $TOKEN_ADJUST_PRIVILEGES = 0x20
        $TOKEN_QUERY = 0x8
        $SE_PRIVILEGE_ENABLED = 0x2
        $hToken = [IntPtr]::Zero
        if (-not [LocalhostManager.TokenPriv]::OpenProcessToken([LocalhostManager.TokenPriv]::GetCurrentProcess(), ($TOKEN_ADJUST_PRIVILEGES -bor $TOKEN_QUERY), [ref]$hToken)) { return }
        $luid = New-Object LocalhostManager.TokenPriv+LUID
        if (-not [LocalhostManager.TokenPriv]::LookupPrivilegeValue($null, 'SeDebugPrivilege', [ref]$luid)) { return }
        $tp = New-Object LocalhostManager.TokenPriv+TOKEN_PRIVILEGES
        $tp.PrivilegeCount = 1
        $tp.Luid = $luid
        $tp.Attributes = $SE_PRIVILEGE_ENABLED
        [void][LocalhostManager.TokenPriv]::AdjustTokenPrivileges($hToken, $false, [ref]$tp, 0, [IntPtr]::Zero, [IntPtr]::Zero)
    } catch {}
}
Enable-DebugPrivilege

Add-Type -Name DwmApi -Namespace LocalhostManager -MemberDefinition @"
[DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
"@

# WinForms client-area colors never reach the native title bar/window frame
# Windows itself draws - that's DWM chrome, opted into dark rendering via
# this specific attribute (Windows 10 2004+ and all of Windows 11). Without
# it, a dark-themed window still gets a light title bar and window border no
# matter what colors the form and its controls use.
function Set-DarkTitleBar {
    param($FormControl)
    if (-not $script:Theme.IsDark) { return }
    try {
        $enabled = 1
        [LocalhostManager.DwmApi]::DwmSetWindowAttribute($FormControl.Handle, 20, [ref]$enabled, 4) | Out-Null
    } catch {}
}

Add-Type -Name ScrollBarTheme -Namespace LocalhostManager -MemberDefinition @"
[DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
public static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string pszSubIdList);

public delegate bool EnumChildProc(IntPtr hWnd, IntPtr lParam);

[DllImport("user32.dll")]
public static extern bool EnumChildWindows(IntPtr hWndParent, EnumChildProc lpEnumFunc, IntPtr lParam);

[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
"@

# The DataGridView's scrollbars (the horizontal one is the visible offender
# - a plain white/light native bar no matter the app's theme, since
# there's no managed API to recolor a native ScrollBar control) are real
# child ScrollBar windows, not owner-drawn. SetWindowTheme's undocumented
# but long-stable "DarkMode_Explorer" subapp name is what Windows' own
# dark mode uses for exactly this class - not a pixel-exact Catppuccin
# Mocha match (Windows renders its own fixed dark gray, not our theme's
# specific hues), but a real dark scrollbar instead of a jarring white
# one. Has to be re-run whenever a scrollbar could have newly appeared,
# not just once at grid creation - DataGridView doesn't create the
# ScrollBar child window until a scrollbar first actually becomes
# necessary, so an earlier EnumChildWindows pass simply won't find it yet.
function Set-DarkScrollBars {
    param($Control)
    if (-not $script:Theme.IsDark) { return }
    try {
        $callback = {
            param($hWnd, $lParam)
            $sb = New-Object System.Text.StringBuilder 256
            [LocalhostManager.ScrollBarTheme]::GetClassName($hWnd, $sb, 256) | Out-Null
            if ($sb.ToString() -eq 'ScrollBar') {
                [LocalhostManager.ScrollBarTheme]::SetWindowTheme($hWnd, 'DarkMode_Explorer', $null) | Out-Null
            }
            return $true
        }
        [LocalhostManager.ScrollBarTheme]::EnumChildWindows($Control.Handle, $callback, [IntPtr]::Zero) | Out-Null
    } catch {}
}

# Recolors MenuStrip/ContextMenuStrip chrome (dropdown background, image
# margin, hover/press highlight, borders) for the dark theme — the default
# ProfessionalColorTable is hardcoded light and would otherwise paint a
# white band behind dark-mode menu text no matter what BackColor is set on
# the strip itself.
Add-Type -TypeDefinition @"
using System.Drawing;
using System.Windows.Forms;

namespace LocalhostManager {
    public class ThemedColorTable : ProfessionalColorTable {
        private Color _base, _hover, _border, _accent;
        public ThemedColorTable(Color baseColor, Color hover, Color border, Color accent) {
            _base = baseColor; _hover = hover; _border = border; _accent = accent;
            UseSystemColors = false;
        }
        public override Color MenuStripGradientBegin { get { return _base; } }
        public override Color MenuStripGradientEnd { get { return _base; } }
        public override Color ToolStripDropDownBackground { get { return _base; } }
        public override Color ImageMarginGradientBegin { get { return _base; } }
        public override Color ImageMarginGradientMiddle { get { return _base; } }
        public override Color ImageMarginGradientEnd { get { return _base; } }
        public override Color MenuItemSelected { get { return _hover; } }
        public override Color MenuItemSelectedGradientBegin { get { return _hover; } }
        public override Color MenuItemSelectedGradientEnd { get { return _hover; } }
        public override Color MenuItemPressedGradientBegin { get { return _hover; } }
        public override Color MenuItemPressedGradientMiddle { get { return _hover; } }
        public override Color MenuItemPressedGradientEnd { get { return _hover; } }
        public override Color MenuItemBorder { get { return _accent; } }
        public override Color SeparatorDark { get { return _border; } }
        public override Color SeparatorLight { get { return _border; } }
        public override Color ToolStripBorder { get { return _border; } }
        public override Color MenuBorder { get { return _border; } }
    }
}
"@ -ReferencedAssemblies System.Windows.Forms, System.Drawing

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
                AutoRestart = if ($prop.Value.PSObject.Properties.Name -contains 'AutoRestart') { [bool]$prop.Value.AutoRestart } else { $false }
                CommandLine = if ($prop.Value.PSObject.Properties.Name -contains 'CommandLine') { [string]$prop.Value.CommandLine } else { $null }
            }
        }
        return $h
    } catch { return @{} }
}

function Save-History($history) {
    # Unlike Load-History, this used to have no error handling at all - a
    # disk-full/locked-file/permission failure here would throw unhandled
    # while $script:CustomNames-style in-memory state had already moved on,
    # silently losing the write (and everything since the last successful
    # one) with no user-visible sign anything went wrong.
    try {
        if (-not (Test-Path $script:HistoryDir)) { New-Item -ItemType Directory -Path $script:HistoryDir -Force | Out-Null }
        $history | ConvertTo-Json | Set-Content -Path $script:HistoryPath -Encoding UTF8
    } catch {
        Write-AppErrorLog -Context 'Failed to save history.json' -Exception $_.Exception
    }
}

$script:SettingsPath = Join-Path $script:HistoryDir 'settings.json'

function Get-DefaultColumnVisibility {
    # Only the informational (non-interactive) columns are toggleable at
    # all - Status/Port/Pin/Log/Action are either the whole point of the
    # table or a click target, so hiding them would remove functionality,
    # not just declutter. Defaults favor what's useful even for an idle
    # process (RAM genuinely varies row to row) over what's usually
    # uninteresting until something's actually busy (CPU sits at 0% for
    # an idle dev server almost all the time).
    return @{
        CustomName  = $true
        Process     = $true
        PID         = $false
        Cpu         = $false
        Mem         = $true
        LocalUrl    = $true
        LanUrls     = $false
        ProjectPath = $false
    }
}

function Get-DefaultColumnFillWeights {
    # Starting point only - every column here is user-resizable within
    # the grid's Fill layout (see New-PortsGrid/Update-ColumnLayout),
    # which redistributes these weights as the user drags a column
    # border, so these just need to be reasonable relative to each
    # other, not exact. Log and Action (Restart/Stop) are deliberately
    # NOT listed - they're fixed-width, non-Fill columns (see
    # New-PortsGrid), so a FillWeight for them wouldn't mean anything.
    return @{
        Status      = 40
        Port        = 45
        Pin         = 34
        CustomName  = 105
        Process     = 62
        PID         = 50
        Cpu         = 48
        Mem         = 55
        LocalUrl    = 110
        LanUrls     = 170
        ProjectPath = 162
    }
}

function Get-DefaultColumnOrder {
    return @('Status', 'Port', 'Pin', 'CustomName', 'Process', 'PID', 'Cpu', 'Mem', 'LocalUrl', 'LanUrls', 'ProjectPath', 'Log', 'Action')
}

function Get-NormalizedColumnOrder {
    # Restart (Log) and Stop/Start (Action) always stay the last two
    # columns, right-most in the table - see the comment on
    # colLog/colAction in New-PortsGrid for why. Applied both when
    # persisting a user's reorder (Save-ColumnLayout) and when restoring
    # one (Load-Settings), so neither a live drag nor a stale/hand-edited
    # settings.json can leave them anywhere else.
    param([string[]]$Order)
    $rest = @($Order | Where-Object { $_ -ne 'Log' -and $_ -ne 'Action' })
    return @($rest + 'Log' + 'Action')
}

function Load-Settings {
    # DashboardEnabled defaults to $false: the web dashboard is opt-in,
    # never auto-started on a fresh install. The end user turns it on (and
    # picks a port) themselves via the Dashboard menu.
    $defaults = @{ OnlyNode = $true; RootDir = ''; ShowGroups = $true; SelectedGroups = @(); WebPort = 3199; DashboardEnabled = $false; ShowSystemPorts = $false; Theme = 'Terminal'; LaunchAtStartup = $false; StartMinimized = $false; CrashNotifications = $true; CheckForUpdates = $true; GroupDividerStyle = 'Hairline'; ProxyEnabled = $false; ProxyPort = 2802; AutoRestartMaxAttempts = 5; AutoRestartWindowMinutes = 5; HealthCheckEnabled = $false; ColumnVisibility = (Get-DefaultColumnVisibility); ColumnFillWeights = (Get-DefaultColumnFillWeights); ColumnOrder = (Get-DefaultColumnOrder) }
    if (-not (Test-Path $script:SettingsPath)) { return $defaults }
    try {
        $raw = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
        $showGroups = if ($raw.PSObject.Properties.Name -contains 'ShowGroups') { [bool]$raw.ShowGroups } else { $true }
        $selectedGroups = if ($raw.PSObject.Properties.Name -contains 'SelectedGroups') { @($raw.SelectedGroups) } else { @() }
        $webPort = if ($raw.PSObject.Properties.Name -contains 'WebPort' -and [int]$raw.WebPort -gt 0) { [int]$raw.WebPort } else { 3199 }
        $dashboardEnabled = if ($raw.PSObject.Properties.Name -contains 'DashboardEnabled') { [bool]$raw.DashboardEnabled } else { $false }
        $showSystemPorts = if ($raw.PSObject.Properties.Name -contains 'ShowSystemPorts') { [bool]$raw.ShowSystemPorts } else { $false }
        # Explicit 'Light' must be preserved, not treated the same as a
        # missing property - it used to be safe to conflate the two only
        # because Light was also the fallback default; now that the
        # fallback is Terminal, an old settings.json saved as Light would
        # otherwise get silently upgraded on load.
        $theme = if ($raw.PSObject.Properties.Name -contains 'Theme' -and [string]$raw.Theme -in @('Light', 'Dark', 'Terminal')) { [string]$raw.Theme } else { 'Terminal' }
        $launchAtStartup = if ($raw.PSObject.Properties.Name -contains 'LaunchAtStartup') { [bool]$raw.LaunchAtStartup } else { $false }
        $startMinimized = if ($raw.PSObject.Properties.Name -contains 'StartMinimized') { [bool]$raw.StartMinimized } else { $false }
        $crashNotifications = if ($raw.PSObject.Properties.Name -contains 'CrashNotifications') { [bool]$raw.CrashNotifications } else { $true }
        $checkForUpdates = if ($raw.PSObject.Properties.Name -contains 'CheckForUpdates') { [bool]$raw.CheckForUpdates } else { $true }
        $groupDividerStyle = if ($raw.PSObject.Properties.Name -contains 'GroupDividerStyle' -and [string]$raw.GroupDividerStyle -in @('Dotted', 'Labeled')) { [string]$raw.GroupDividerStyle } else { 'Hairline' }
        $proxyEnabled = if ($raw.PSObject.Properties.Name -contains 'ProxyEnabled') { [bool]$raw.ProxyEnabled } else { $false }
        $proxyPort = if ($raw.PSObject.Properties.Name -contains 'ProxyPort' -and [int]$raw.ProxyPort -gt 0) { [int]$raw.ProxyPort } else { 2802 }
        $autoRestartMaxAttempts = if ($raw.PSObject.Properties.Name -contains 'AutoRestartMaxAttempts' -and [int]$raw.AutoRestartMaxAttempts -gt 0) { [int]$raw.AutoRestartMaxAttempts } else { 5 }
        $autoRestartWindowMinutes = if ($raw.PSObject.Properties.Name -contains 'AutoRestartWindowMinutes' -and [int]$raw.AutoRestartWindowMinutes -gt 0) { [int]$raw.AutoRestartWindowMinutes } else { 5 }
        $healthCheckEnabled = if ($raw.PSObject.Properties.Name -contains 'HealthCheckEnabled') { [bool]$raw.HealthCheckEnabled } else { $false }
        # Merged onto the defaults (not replaced wholesale) so a settings
        # file saved before a new toggleable column existed still gets
        # that column's intended default instead of it vanishing/showing
        # based on an absent key.
        $columnVisibility = Get-DefaultColumnVisibility
        if ($raw.PSObject.Properties.Name -contains 'ColumnVisibility' -and $raw.ColumnVisibility) {
            foreach ($colName in @($columnVisibility.Keys)) {
                if ($raw.ColumnVisibility.PSObject.Properties.Name -contains $colName) {
                    $columnVisibility[$colName] = [bool]$raw.ColumnVisibility.$colName
                }
            }
        }
        $columnFillWeights = Get-DefaultColumnFillWeights
        if ($raw.PSObject.Properties.Name -contains 'ColumnFillWeights' -and $raw.ColumnFillWeights) {
            foreach ($colName in @($columnFillWeights.Keys)) {
                if ($raw.ColumnFillWeights.PSObject.Properties.Name -contains $colName) {
                    $columnFillWeights[$colName] = [int]$raw.ColumnFillWeights.$colName
                }
            }
        }
        # A saved order missing some column (an older save, before a
        # column existed) or naming an unknown one (a column since
        # removed) both just fall back to the coded default order
        # wholesale, rather than trying to splice the difference - safer
        # than risking a partial/duplicate DisplayIndex assignment.
        $defaultOrder = Get-DefaultColumnOrder
        $columnOrder = if ($raw.PSObject.Properties.Name -contains 'ColumnOrder' -and $raw.ColumnOrder) {
            $savedOrder = @($raw.ColumnOrder | ForEach-Object { [string]$_ })
            if (@($savedOrder | Sort-Object) -join ',' -eq @($defaultOrder | Sort-Object) -join ',') { Get-NormalizedColumnOrder $savedOrder } else { $defaultOrder }
        } else { $defaultOrder }
        return @{
            OnlyNode           = [bool]$raw.OnlyNode
            RootDir            = [string]$raw.RootDir
            ShowGroups         = $showGroups
            SelectedGroups     = $selectedGroups
            WebPort            = $webPort
            DashboardEnabled   = $dashboardEnabled
            ShowSystemPorts    = $showSystemPorts
            Theme              = $theme
            LaunchAtStartup    = $launchAtStartup
            StartMinimized     = $startMinimized
            CrashNotifications = $crashNotifications
            ProxyEnabled       = $proxyEnabled
            ProxyPort          = $proxyPort
            AutoRestartMaxAttempts   = $autoRestartMaxAttempts
            AutoRestartWindowMinutes = $autoRestartWindowMinutes
            HealthCheckEnabled = $healthCheckEnabled
            CheckForUpdates    = $checkForUpdates
            GroupDividerStyle  = $groupDividerStyle
            ColumnVisibility   = $columnVisibility
            ColumnFillWeights  = $columnFillWeights
            ColumnOrder        = $columnOrder
        }
    } catch { return $defaults }
}

function Save-Settings($settings) {
    # See Save-History for why this is wrapped - same silent-data-loss risk
    # on a disk-full/locked-file/permission failure.
    try {
        if (-not (Test-Path $script:HistoryDir)) { New-Item -ItemType Directory -Path $script:HistoryDir -Force | Out-Null }
        $settings | ConvertTo-Json | Set-Content -Path $script:SettingsPath -Encoding UTF8
    } catch {
        Write-AppErrorLog -Context 'Failed to save settings.json' -Exception $_.Exception
    }
}

$script:StartupRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:StartupRunName = 'LocalhostManager'

# The launch path a user actually double-clicks: the compiled .exe (its own
# process) normally, or "powershell -File script.ps1" when run unpackaged
# from source - MainModule.FileName alone would point at powershell.exe with
# no argument in that case and just open a blank shell on login.
function Get-AppLaunchCommand {
    if ($PSCommandPath -and $PSCommandPath -like '*.ps1') {
        return "powershell.exe -WindowStyle Hidden -File `"$PSCommandPath`""
    }
    return "`"$([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)`""
}

function Set-LaunchAtStartup {
    param([bool]$Enable)
    try {
        if ($Enable) {
            New-ItemProperty -Path $script:StartupRunKey -Name $script:StartupRunName -Value (Get-AppLaunchCommand) -PropertyType String -Force | Out-Null
        } else {
            Remove-ItemProperty -Path $script:StartupRunKey -Name $script:StartupRunName -ErrorAction SilentlyContinue
        }
    } catch {}
}

# Relaunches the app and exits this instance - used after a theme change,
# since every control reads $script:Theme.* once at creation time rather
# than repainting live on toggle. Releases the single-instance mutex first
# so the freshly spawned copy's own startup check doesn't see this (still
# exiting) instance and refuse to open.
function Restart-App {
    try { $script:SingleInstanceMutex.Close() } catch {}
    try {
        if ($PSCommandPath -and $PSCommandPath -like '*.ps1') {
            Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-File', $PSCommandPath)
        } else {
            Start-Process -FilePath ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        }
    } catch {}
    $script:ReallyExit = $true
    $notifyIcon.Visible = $false
    $form.Close()
}

# Everything the app knows (settings, groups, port history, custom names)
# lives as four small JSON files under %LOCALAPPDATA%\LocalhostManager -
# nothing here needs a database or an installer-managed profile, so backup/
# restore is just zipping and unzipping that folder's known files.
$script:BackupFileNames = @('settings.json', 'groups.json', 'history.json', 'customnames.json')

function Export-AppBackup {
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = 'Localhost Manager Backup (*.lhmbackup)|*.lhmbackup'
    $sfd.FileName = "LocalhostManager-Backup-$(Get-Date -Format 'yyyy-MM-dd').lhmbackup"
    if ($sfd.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $tempDir = Join-Path $env:TEMP "LHM-Backup-$([guid]::NewGuid())"
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $included = 0
        foreach ($f in $script:BackupFileNames) {
            $src = Join-Path $script:HistoryDir $f
            if (Test-Path $src) { Copy-Item $src -Destination (Join-Path $tempDir $f) -Force; $included++ }
        }
        if (Test-Path $sfd.FileName) { Remove-Item $sfd.FileName -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $sfd.FileName)
        [System.Windows.Forms.MessageBox]::Show("Backed up $included file(s) to:`n$($sfd.FileName)", 'Backup Complete', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Backup failed: $($_.Exception.Message)", 'Backup Failed', 'OK', 'Error') | Out-Null
    } finally {
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Import-AppBackup {
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = 'Localhost Manager Backup (*.lhmbackup;*.zip)|*.lhmbackup;*.zip|All files (*.*)|*.*'
    if ($ofd.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "This replaces your current settings, groups, port history, and custom names with the backup's, then restarts the app. This can't be undone. Continue?",
        'Restore Backup', 'YesNo', 'Warning')
    if ($confirm -ne 'Yes') { return }

    $tempDir = Join-Path $env:TEMP "LHM-Restore-$([guid]::NewGuid())"
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ofd.FileName, $tempDir)
        $restored = 0
        foreach ($f in $script:BackupFileNames) {
            $src = Join-Path $tempDir $f
            if (Test-Path $src) {
                if (-not (Test-Path $script:HistoryDir)) { New-Item -ItemType Directory -Path $script:HistoryDir -Force | Out-Null }
                Copy-Item $src -Destination (Join-Path $script:HistoryDir $f) -Force
                $restored++
            }
        }
        if ($restored -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("That file doesn't look like a Localhost Manager backup - none of the expected files ($($script:BackupFileNames -join ', ')) were found inside it.", 'Restore Failed', 'OK', 'Warning') | Out-Null
            return
        }
        Restart-App
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Restore failed: $($_.Exception.Message)", 'Restore Failed', 'OK', 'Error') | Out-Null
    } finally {
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
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
    # See Save-History for why this is wrapped - same silent-data-loss risk
    # on a disk-full/locked-file/permission failure.
    try {
        if (-not (Test-Path $script:HistoryDir)) { New-Item -ItemType Directory -Path $script:HistoryDir -Force | Out-Null }
        $names | ConvertTo-Json | Set-Content -Path $script:CustomNamesPath -Encoding UTF8
    } catch {
        Write-AppErrorLog -Context 'Failed to save customnames.json' -Exception $_.Exception
    }
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

# ---------------------------------------------------------------------------
# Build & Deploy - a per-project "build then mirror dist/ into a server's
# public/" recipe (originally written for the Jewelry Store frontend/server
# split, generalized so any tracked project can define one). Keyed by
# normalized project path, same convention as CustomNames.
# ---------------------------------------------------------------------------
$script:DeployDefsPath = Join-Path $script:HistoryDir 'deploydefs.json'

function Load-DeployDefs {
    if (-not (Test-Path $script:DeployDefsPath)) { return @{} }
    try {
        $raw = Get-Content $script:DeployDefsPath -Raw | ConvertFrom-Json
        $h = @{}
        foreach ($prop in $raw.PSObject.Properties) {
            # TargetDirs (plural, array) is current; TargetDir (singular
            # string) is the pre-multi-target shape - wrap it into a
            # one-element array so old saved recipes (including the
            # Jewelry Store one saved before this existed) keep working.
            $targets = if ($prop.Value.PSObject.Properties.Name -contains 'TargetDirs') {
                @($prop.Value.TargetDirs | ForEach-Object { [string]$_ })
            } elseif ($prop.Value.PSObject.Properties.Name -contains 'TargetDir' -and $prop.Value.TargetDir) {
                @([string]$prop.Value.TargetDir)
            } else {
                @()
            }
            $h[$prop.Name] = @{
                BuildCommand = [string]$prop.Value.BuildCommand
                WorkingDir   = [string]$prop.Value.WorkingDir
                SourceDir    = [string]$prop.Value.SourceDir
                TargetDirs   = $targets
            }
        }
        return $h
    } catch { return @{} }
}

function Save-DeployDefs($defs) {
    # See Save-History for why this is wrapped - same silent-data-loss risk
    # on a disk-full/locked-file/permission failure.
    try {
        if (-not (Test-Path $script:HistoryDir)) { New-Item -ItemType Directory -Path $script:HistoryDir -Force | Out-Null }
        $defs | ConvertTo-Json | Set-Content -Path $script:DeployDefsPath -Encoding UTF8
    } catch {
        Write-AppErrorLog -Context 'Failed to save deploydefs.json' -Exception $_.Exception
    }
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
    # See Save-History for why this is wrapped - same silent-data-loss risk
    # on a disk-full/locked-file/permission failure.
    try {
        if (-not (Test-Path $script:HistoryDir)) { New-Item -ItemType Directory -Path $script:HistoryDir -Force | Out-Null }
        $groups | ConvertTo-Json | Set-Content -Path $script:GroupsPath -Encoding UTF8
    } catch {
        Write-AppErrorLog -Context 'Failed to save groups.json' -Exception $_.Exception
    }
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
    # Placeholder - $script:Settings doesn't exist yet at this point in
    # the script's own startup, so the real persisted value is synced in
    # right after Load-Settings runs (below), well before the background
    # poller thread that actually reads this is started. Also updated
    # live from Show-SettingsDialog's OK handler, so toggling it takes
    # effect on the poller's next cycle without an app restart.
    HealthCheckEnabled = $false
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

# ---------------------------------------------------------------------------
# Reverse proxy cache. Same shape/role as DashboardCache above, for the
# "Local Domains" feature: the UI thread republishes RouteMap (hostname
# slug -> {Port, Label, ProjectPath}) on every refresh cycle, and the
# HttpListener runspace only ever reads it to decide where to relay each
# request - no Actions/Results queue needed here since the proxy has
# nothing to report back (it only forwards HTTP, it doesn't start/stop
# anything).
# ---------------------------------------------------------------------------
$script:ProxyCache = [hashtable]::Synchronized(@{
    RouteMap      = @{}
    Port          = 0
    StopRequested = $false
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

    function Get-HealthProbeHost {
        # Wildcard binds (0.0.0.0/::) accept both address families, so
        # plain IPv4 loopback always reaches them - no different from how
        # LocalUrl is already built elsewhere. A listener bound to one
        # specific address, though, is genuinely only reachable on that
        # address; an IPv6 literal needs [brackets] in a URL, which a bare
        # IPv4 literal or hostname never does.
        param([string]$LocalAddr)
        if (-not $LocalAddr -or $LocalAddr -eq '0.0.0.0' -or $LocalAddr -eq '::') { return '127.0.0.1' }
        if ($LocalAddr -like '*:*') { return "[$LocalAddr]" }
        return $LocalAddr
    }

    function Test-HttpResponding {
        # Opt-in health check (Settings > Preferences): proves a listening
        # process is actually processing HTTP requests, not just holding
        # the socket open - a hung/frozen server looks identical to a
        # healthy one under a plain "is something listening" check, which
        # is all Status=ON has ever meant. Runs every probe concurrently
        # via BeginGetResponse/EndGetResponse (true async, not a
        # thread-per-port) so N tracked projects cost roughly one
        # timeout's worth of wall time total, not N timeouts summed -
        # this whole poller loop only gets ~4s per cycle before other
        # tracked ports go stale, and a single hung server must never
        # delay detecting everything else.
        # $Targets is @{ Port; ProbeHost } pairs, not bare port numbers -
        # ProbeHost must match the listener's actual bind address family.
        # Vite (and other modern Node tooling) binds to "localhost", which
        # Node resolves to the IPv6 loopback (::1) first on many systems -
        # a probe that always assumes 127.0.0.1 silently misses every one
        # of those and reports a perfectly healthy dev server as not
        # responding, having never actually reached it. See
        # Get-HealthProbeHost for how ProbeHost is derived from the
        # listener's real LocalAddr.
        param($Targets, [int]$TimeoutMs)
        $pending = @()
        foreach ($t in $Targets) {
            try {
                $req = [System.Net.HttpWebRequest]::Create("http://$($t.ProbeHost):$($t.Port)/")
                $req.Method = 'GET'
                $req.Timeout = $TimeoutMs
                $req.ReadWriteTimeout = $TimeoutMs
                $req.KeepAlive = $false
                $ar = $req.BeginGetResponse($null, $null)
                $pending += @{ Port = $t.Port; Request = $req; AsyncResult = $ar }
            } catch {
                # Couldn't even start the request (socket-level failure) -
                # treated as unresponsive below, same as a real timeout.
            }
        }
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs + 300)
        while (([DateTime]::UtcNow -lt $deadline) -and @($pending | Where-Object { -not $_.AsyncResult.IsCompleted }).Count -gt 0) {
            Start-Sleep -Milliseconds 50
        }
        $results = @{}
        foreach ($p in $pending) {
            try {
                if ($p.AsyncResult.IsCompleted) {
                    $resp = $p.Request.EndGetResponse($p.AsyncResult)
                    $resp.Close()
                    $results[$p.Port] = $true
                } else {
                    try { $p.Request.Abort() } catch {}
                    $results[$p.Port] = $false
                }
            } catch [System.Net.WebException] {
                # Any HTTP response at all - even a 404/500 - still proves
                # the process is actually answering requests, not just
                # holding the socket. WebException is how HttpWebRequest
                # surfaces a non-2xx status, not only connection failures.
                if ($_.Exception.Response) {
                    $_.Exception.Response.Close()
                    $results[$p.Port] = $true
                } else {
                    $results[$p.Port] = $false
                }
            } catch {
                $results[$p.Port] = $false
            }
        }
        return $results
    }

    # CPU% isn't a snapshot value - .NET only exposes cumulative
    # TotalProcessorTime, so it takes two samples spaced apart to turn into
    # a percentage. This persists across poll ticks (declared outside the
    # while loop, in the same runspace the loop itself runs in) rather
    # than living in $Cache: it's pure intermediate state the UI thread
    # never needs to see, only this tick's computed CpuPercent result does.
    $prevCpuSamples = @{}

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
            $nowUtc = [DateTime]::UtcNow
            $nextCpuSamples = @{}
            foreach ($key in $byPort.Keys) {
                $c = $byPort[$key]
                $procId = [int]$c.OwningProcess
                $proc = $null
                try { $proc = Get-Process -Id $procId -ErrorAction Stop } catch {}
                if (-not $proc) { continue }
                $procName = $proc.ProcessName

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

                $memMB = $null
                try { $memMB = [Math]::Round($proc.WorkingSet64 / 1MB, 0) } catch {}

                # $null (not 0) until a second sample exists - "0%" and
                # "not measured yet" are different facts, and the grid
                # renders $null as blank rather than a misleading 0%.
                #
                # Deliberately NOT normalized by ProcessorCount (the
                # "% of total system capacity" convention modern Task
                # Manager defaults to) - on a high core-count machine that
                # makes a single-threaded dev server maxing out its one
                # thread read as a barely-visible few percent, which
                # defeats the point of this column (spotting what's
                # actually busy). 100% here means "one full core busy",
                # the older Task Manager / Process Explorer / htop
                # convention - can exceed 100% for a genuinely
                # multi-threaded process, same as those tools.
                $cpuPercent = $null
                try {
                    $cpuNow = $proc.TotalProcessorTime
                    $nextCpuSamples[$procId] = @{ Time = $nowUtc; Cpu = $cpuNow }
                    $prev = $prevCpuSamples[$procId]
                    if ($prev) {
                        $elapsedMs = ($nowUtc - $prev.Time).TotalMilliseconds
                        if ($elapsedMs -gt 0) {
                            $deltaMs = ($cpuNow - $prev.Cpu).TotalMilliseconds
                            $cpuPercent = [Math]::Max(0, [Math]::Round($deltaMs / $elapsedMs * 100, 1))
                        }
                    }
                } catch {}

                $result[$key] = @{
                    Port        = $key
                    ProcId      = $procId
                    ProcessName = $procName
                    LocalAddr   = $c.LocalAddress
                    ProjectPath = $cwd
                    IsNode      = [bool]$isNode
                    IsSystem    = $isSystem
                    CommandLine = $commandLine
                    CpuPercent  = $cpuPercent
                    MemMB       = $memMB
                }
            }
            # Only carries forward samples for PIDs actually seen this tick -
            # otherwise a long session accumulates one stale entry per PID
            # that's ever briefly listened on a port, forever.
            $prevCpuSamples = $nextCpuSamples

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

            # Health-check probe, opt-in and off by default - only actual
            # npm/node projects get probed (never IsSystem processes,
            # which frequently aren't HTTP servers at all and would just
            # rack up false "unresponsive" reports for something that was
            # never going to answer a GET request in the first place).
            if ($Cache.HealthCheckEnabled) {
                $portsToProbe = @($result.Keys | Where-Object { $result[$_].IsNode -and -not $result[$_].IsSystem })
                if ($portsToProbe.Count -gt 0) {
                    $targets = @($portsToProbe | ForEach-Object { @{ Port = $_; ProbeHost = (Get-HealthProbeHost -LocalAddr $result[$_].LocalAddr) } })
                    $probeResults = Test-HttpResponding -Targets $targets -TimeoutMs 1500
                    foreach ($port in $portsToProbe) {
                        $result[$port].Responding = if ($probeResults.ContainsKey($port)) { $probeResults[$port] } else { $false }
                    }
                }
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
        # Checked before the plain 'Ethernet' case below - Windows names a
        # Hyper-V virtual switch's host-side adapter "vEthernet (...)",
        # which contains "Ethernet" as a substring. With 'Ethernet' checked
        # first, every real Hyper-V adapter matched it instead and was
        # misclassified as a real, non-virtual NIC (SortRank 0, not tinted
        # purple in the row Detail popup) - the opposite of what this
        # function exists to flag.
        'Hyper-V|vEthernet'  { return [PSCustomObject]@{ Label = 'Hyper-V';    IsVirtual = $true;  SortRank = 2 } }
        'Ethernet'           { return [PSCustomObject]@{ Label = 'Ethernet';    IsVirtual = $false; SortRank = 0 } }
        'VMware'             { return [PSCustomObject]@{ Label = 'VMware';     IsVirtual = $true;  SortRank = 2 } }
        'VirtualBox'         { return [PSCustomObject]@{ Label = 'VirtualBox';IsVirtual = $true;  SortRank = 2 } }
        'Docker'             { return [PSCustomObject]@{ Label = 'Docker';    IsVirtual = $true;  SortRank = 2 } }
        default              { return [PSCustomObject]@{ Label = $InterfaceAlias; IsVirtual = $false; SortRank = 1 } }
    }
}

function Merge-LiveWithHistoryFallback {
    # The PEB read behind ProjectPath can fail for a perfectly normal, live
    # process - e.g. one spawned inside a sandboxed shell (an agent/CI
    # runner) whose job/security context blocks an unrelated app like this
    # one from opening a memory-reading handle into it, even though the
    # process's name/PID/command line are all still visible. When that
    # happens for a port this app has already resolved before, fall back to
    # the last known-good path/command line instead of clobbering it to
    # null - otherwise a single unreadable restart silently drops the port
    # out of Groups (path match), Manage Groups (path is required to even
    # list it) and the "Dev Servers Only" filter (needs IsNode). A process
    # that resolves fine this cycle always wins over history.
    param($RawLive, $History)
    $live = @{}
    foreach ($key in $RawLive.Keys) {
        $e = $RawLive[$key]
        $prior = $History[$key]
        if (-not $e.ProjectPath -and $prior -and $prior.ProjectPath) {
            $e = $e.Clone()
            $e.ProjectPath = $prior.ProjectPath
            if (-not $e.CommandLine) { $e.CommandLine = $prior.CommandLine }
            $e.IsNode = $true
        }
        $live[$key] = $e
    }
    return $live
}

function Sync-HistoryFromLive {
    # A pinned port is remembered here regardless of IsNode - that's the
    # whole point of pinning: keep tracking something (even a non-npm
    # process) through a shutdown so History can offer it back later. A
    # plain (unpinned) entry is still only tracked while it's a recognized
    # Node project, same as before. $History is a hashtable (reference
    # type) - mutated in place and saved, same as when this was inlined in
    # Build-Rows, so the caller's copy reflects the update without needing
    # a return value.
    param($Live, $History)
    foreach ($key in $Live.Keys) {
        $e = $Live[$key]
        if ($e.IsSystem) { continue }
        $pinned = $History.ContainsKey($key) -and [bool]$History[$key].Pinned
        $autoRestart = $History.ContainsKey($key) -and [bool]$History[$key].AutoRestart
        if ($e.IsNode -or $pinned -or $autoRestart) {
            $History[$key] = @{ ProjectPath = $e.ProjectPath; ProcessName = $e.ProcessName; Pinned = $pinned; AutoRestart = $autoRestart; CommandLine = $e.CommandLine }
        }
    }
    Save-History $History
}

function Get-RowLanInfo {
    # A listener bound to a specific address (not the wildcard 0.0.0.0/::)
    # only answers on localhost, regardless of what else is on the machine -
    # no LAN entries to build in that case.
    param([string]$LocalAddr, [string]$Port, $LanIps)
    if ($LocalAddr -ne '0.0.0.0' -and $LocalAddr -ne '::') {
        return @{ LanUrls = '(localhost only)'; LanEntries = @() }
    }
    $lanEntries = @($LanIps | ForEach-Object {
        $info = Get-NetworkInterfaceLabel -InterfaceAlias $_.InterfaceAlias
        [PSCustomObject]@{
            Label     = $info.Label
            Url       = "http://$($_.IPAddress):$Port"
            IsVirtual = $info.IsVirtual
            SortRank  = $info.SortRank
        }
    } | Sort-Object SortRank, Label)
    $lanUrls = ($lanEntries | ForEach-Object { $_.Url }) -join ', '
    return @{ LanUrls = $lanUrls; LanEntries = $lanEntries }
}

function Build-Rows {
    param([bool]$OnlyNode, [string]$RootDir)

    $rawLive = Get-LiveListeners
    $history = Load-History
    $lanIps = @(Get-LanIPv4Addresses)

    $live = Merge-LiveWithHistoryFallback -RawLive $rawLive -History $history
    Sync-HistoryFromLive -Live $live -History $history

    $rows = @()
    $seen = @{}

    foreach ($key in ($live.Keys | Sort-Object { [int]$_ })) {
        $e = $live[$key]
        if ($e.IsSystem) { continue }
        $pinned = $history.ContainsKey($key) -and [bool]$history[$key].Pinned
        $autoRestart = $history.ContainsKey($key) -and [bool]$history[$key].AutoRestart
        # Pinning bypasses Dev-Servers-Only too - same "stays visible
        # regardless of the filter" idea Use Groups already gets.
        if ($OnlyNode -and -not $e.IsNode -and -not $pinned) { continue }
        if (-not (Test-PathUnderRoot -Path $e.ProjectPath -Root $RootDir)) { continue }
        $seen[$key] = $true

        $lan = Get-RowLanInfo -LocalAddr $e.LocalAddr -Port $key -LanIps $lanIps

        $nameKey = Get-CustomNameKey -ProjectPath $e.ProjectPath -Port $key
        $customName = if ($script:CustomNames.ContainsKey($nameKey)) { $script:CustomNames[$nameKey] } else { '' }

        $managed = $script:ManagedProcesses[(Get-NormalizedPath $e.ProjectPath)]

        $rows += [PSCustomObject]@{
            Status      = 'ON'
            Port        = $key
            CustomName  = $customName
            ProcessName = $e.ProcessName
            ProcId      = $e.ProcId
            Cpu         = $e.CpuPercent
            Mem         = $e.MemMB
            LocalUrl    = "http://localhost:$key"
            LanUrls     = $lan.LanUrls
            LanEntries  = $lan.LanEntries
            ProjectPath = $e.ProjectPath
            Action      = 'Stop'
            HasLog      = [bool]$managed
            Pinned      = $pinned
            AutoRestart = $autoRestart
            CommandLine = $e.CommandLine
            # $true/$false once the background poller's health-check probe
            # (opt-in, Settings > Preferences) has actually run against
            # this port; $null when it's off, or this isn't an npm/node
            # project the probe bothers with - see Test-HttpResponding.
            Responding  = $e.Responding
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
            Cpu         = $null
            Mem         = $null
            LocalUrl    = "http://localhost:$key"
            LanUrls     = ''
            LanEntries  = @()
            ProjectPath = $h.ProjectPath
            Action      = 'Start'
            HasLog      = [bool]$managed
            Pinned      = [bool]$h.Pinned
            AutoRestart = [bool]$h.AutoRestart
            CommandLine = $h.CommandLine
            Responding  = $null
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
            Cpu         = $e.CpuPercent
            Mem         = $e.MemMB
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
    # Plain `exit` only unwinds the PowerShell pipeline - in the ps2exe-
    # compiled .exe it does not reliably tear down the host process this
    # early (before Application.Run ever starts), leaving a windowless,
    # tray-icon-less zombie behind after the dialog is dismissed. Every
    # duplicate launch left one of these running invisibly, which is what
    # made the real instance look like it had vanished from both the
    # taskbar and the tray. Environment.Exit terminates the process
    # unconditionally, regardless of how it was hosted.
    [System.Environment]::Exit(0)
}

# Loaded here (ahead of everything else that used to load it further down)
# because the Light/Dark palette selection right below needs to know the
# saved theme choice before any control gets built against it.
$script:Settings = Load-Settings
# Syncs the placeholder set when $script:LiveCache was declared (above,
# before $script:Settings existed) to the actual persisted value - the
# background poller thread that reads this isn't started until well after
# this point, so it always sees the real setting from its very first cycle.
$script:LiveCache.HealthCheckEnabled = [bool]$script:Settings.HealthCheckEnabled

# ---------------------------------------------------------------------------
# Theme — flat, GNOME/Adwaita-inspired palettes, light and dark. Swapped in
# for the default WinForms 3D-bevel gray look: flat bordered buttons with
# rounded corners, a real background/foreground color system, and a
# grid/card background instead of the OS default ButtonFace gray filling
# unused rows. $script:Settings.Theme (loaded above) picks which one is
# active; because controls read $script:Theme.* once, at creation time,
# switching between the two takes a restart (Show-SettingsDialog offers to
# do that automatically) rather than repainting live.
# ---------------------------------------------------------------------------
$script:LightTheme = @{
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
    Warning     = [System.Drawing.Color]::FromArgb(0xF5, 0x7C, 0x00)
    WarningTint = [System.Drawing.Color]::FromArgb(0xFF, 0xF3, 0xE0)
    RowAlt      = [System.Drawing.Color]::FromArgb(0xF7, 0xF6, 0xF5)
    ToggleOff   = [System.Drawing.Color]::FromArgb(0xC6, 0xC6, 0xC6)
    IsDark      = $false
    Radius      = 8
    FontFamily  = 'Segoe UI'
}

# Dark variant — Discord's palette family: blue-gray (not neutral-gray or
# navy-black) surfaces at three tiers of lightness - tertiary/darkest for
# outer chrome (title bar, toolbar row), secondary for panels/inactive tabs,
# primary/brightest for the main content surface - plus its blurple accent
# and muted (not pure white/full-saturation) text and status colors.
$script:DarkTheme = @{
    WindowBg    = [System.Drawing.Color]::FromArgb(0x1E, 0x1F, 0x22)
    PanelBg     = [System.Drawing.Color]::FromArgb(0x2B, 0x2D, 0x31)
    CardBg      = [System.Drawing.Color]::FromArgb(0x31, 0x33, 0x38)
    Border      = [System.Drawing.Color]::FromArgb(0x3F, 0x42, 0x48)
    TextPrimary = [System.Drawing.Color]::FromArgb(0xDB, 0xDE, 0xE1)
    TextDim     = [System.Drawing.Color]::FromArgb(0x94, 0x9B, 0xA4)
    Accent      = [System.Drawing.Color]::FromArgb(0x58, 0x65, 0xF2)
    AccentDark  = [System.Drawing.Color]::FromArgb(0x75, 0x81, 0xF5)
    AccentTint  = [System.Drawing.Color]::FromArgb(0x35, 0x37, 0x4B)
    Success     = [System.Drawing.Color]::FromArgb(0x23, 0xA5, 0x5A)
    SuccessTint = [System.Drawing.Color]::FromArgb(0x1E, 0x2E, 0x25)
    Danger      = [System.Drawing.Color]::FromArgb(0xF2, 0x3F, 0x42)
    DangerTint  = [System.Drawing.Color]::FromArgb(0x30, 0x22, 0x24)
    Warning     = [System.Drawing.Color]::FromArgb(0xFA, 0xA6, 0x1A)
    WarningTint = [System.Drawing.Color]::FromArgb(0x3A, 0x2E, 0x1C)
    RowAlt      = [System.Drawing.Color]::FromArgb(0x2E, 0x30, 0x35)
    ToggleOff   = [System.Drawing.Color]::FromArgb(0x4E, 0x50, 0x58)
    IsDark      = $true
    Radius      = 8
    FontFamily  = 'Segoe UI'
}

# Terminal variant — Catppuccin Mocha, translated from the herdr-tui-design
# skill: crust/mantle/base tiering for the three background levels, one blue
# accent, semantic status colors, muted (not pure gray) borders. Radius = 0
# and a monospace FontFamily are the two tokens that turn every rounded
# WinForms control flat and every proportional-font label into terminal text
# without touching the drawing code itself (see Initialize-ModernButton).
$script:TerminalTheme = @{
    WindowBg    = [System.Drawing.Color]::FromArgb(0x11, 0x11, 0x1B)
    PanelBg     = [System.Drawing.Color]::FromArgb(0x18, 0x18, 0x25)
    CardBg      = [System.Drawing.Color]::FromArgb(0x1E, 0x1E, 0x2E)
    Border      = [System.Drawing.Color]::FromArgb(0x6C, 0x70, 0x86)
    TextPrimary = [System.Drawing.Color]::FromArgb(0xCD, 0xD6, 0xF4)
    TextDim     = [System.Drawing.Color]::FromArgb(0xA6, 0xAD, 0xC8)
    Accent      = [System.Drawing.Color]::FromArgb(0x89, 0xB4, 0xFA)
    AccentDark  = [System.Drawing.Color]::FromArgb(0x74, 0xC7, 0xEC)
    AccentTint  = [System.Drawing.Color]::FromArgb(0x31, 0x32, 0x44)
    Success     = [System.Drawing.Color]::FromArgb(0xA6, 0xE3, 0xA1)
    SuccessTint = [System.Drawing.Color]::FromArgb(0x1E, 0x2E, 0x25)
    Danger      = [System.Drawing.Color]::FromArgb(0xF3, 0x8B, 0xA8)
    DangerTint  = [System.Drawing.Color]::FromArgb(0x30, 0x22, 0x26)
    Warning     = [System.Drawing.Color]::FromArgb(0xFA, 0xB3, 0x87)
    WarningTint = [System.Drawing.Color]::FromArgb(0x30, 0x28, 0x20)
    RowAlt      = [System.Drawing.Color]::FromArgb(0x1A, 0x1A, 0x28)
    ToggleOff   = [System.Drawing.Color]::FromArgb(0x45, 0x47, 0x5A)
    IsDark      = $true
    Radius      = 0
    FontFamily  = 'Cascadia Mono'
}

$script:Theme = switch ($script:Settings.Theme) {
    'Dark'     { $script:DarkTheme }
    'Terminal' { $script:TerminalTheme }
    default    { $script:LightTheme }
}

# Dark mode needs a custom ToolStrip renderer (see ThemedColorTable above) so
# menu/tray-menu chrome matches; light mode keeps the default renderer ($null
# below restores it) since it already matches this palette.
$script:MenuRenderer = if ($script:Theme.IsDark) {
    $colorTable = New-Object LocalhostManager.ThemedColorTable($script:Theme.CardBg, $script:Theme.AccentTint, $script:Theme.Border, $script:Theme.Accent)
    New-Object System.Windows.Forms.ToolStripProfessionalRenderer($colorTable)
} else {
    $null
}

function Draw-ToolbarIcon {
    # Small hand-drawn vector glyphs (no image assets), matching the
    # anti-aliased vector look the rest of this file already draws buttons
    # and rounded-rects with. $Alpha lets Draw-ButtonContent crossfade two
    # icons during a morph animation.
    param($Graphics, [string]$Icon, [System.Drawing.RectangleF]$Rect, [System.Drawing.Color]$Color, [float]$Alpha = 1.0)
    if (-not $Icon -or $Alpha -le 0.01) { return }
    $a = [Math]::Max(0, [Math]::Min(255, [int](255 * $Alpha)))
    $c = [System.Drawing.Color]::FromArgb($a, $Color)
    $pen = New-Object System.Drawing.Pen($c, 1.6)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

    switch ($Icon) {
        'Play' {
            $pts = @(
                (New-Object System.Drawing.PointF($Rect.Left, $Rect.Top)),
                (New-Object System.Drawing.PointF($Rect.Left, $Rect.Bottom)),
                (New-Object System.Drawing.PointF($Rect.Right, ($Rect.Top + $Rect.Height / 2)))
            )
            $brush = New-Object System.Drawing.SolidBrush($c)
            $Graphics.FillPolygon($brush, $pts)
            $brush.Dispose()
        }
        'Square' {
            $Graphics.DrawRectangle($pen, $Rect.X, $Rect.Y, $Rect.Width, $Rect.Height)
        }
        'Check' {
            $pts = @(
                (New-Object System.Drawing.PointF($Rect.Left, ($Rect.Top + $Rect.Height * 0.55))),
                (New-Object System.Drawing.PointF(($Rect.Left + $Rect.Width * 0.38), $Rect.Bottom)),
                (New-Object System.Drawing.PointF($Rect.Right, $Rect.Top))
            )
            $Graphics.DrawLines($pen, $pts)
        }
        'X' {
            $Graphics.DrawLine($pen, $Rect.Left, $Rect.Top, $Rect.Right, $Rect.Bottom)
            $Graphics.DrawLine($pen, $Rect.Right, $Rect.Top, $Rect.Left, $Rect.Bottom)
        }
        'Deploy' {
            # Plain up-arrow (shaft + chevron head) - reads as "push/build
            # and ship" without needing an icon-font glyph (see the
            # Columns/"filter" button confusion - a missing font glyph
            # renders blank with no obvious cause, a hand-drawn vector never
            # can).
            $midX = $Rect.Left + $Rect.Width / 2.0
            $Graphics.DrawLine($pen, $midX, $Rect.Bottom, $midX, $Rect.Top)
            $Graphics.DrawLine($pen, $Rect.Left, ($Rect.Top + $Rect.Height * 0.42), $midX, $Rect.Top)
            $Graphics.DrawLine($pen, $Rect.Right, ($Rect.Top + $Rect.Height * 0.42), $midX, $Rect.Top)
        }
    }
    $pen.Dispose()
}

function Draw-ButtonLayer {
    # Draws one icon+text layer centered as a group, offset vertically by
    # $YOffset and faded by $Alpha — the two knobs Draw-ButtonContent needs
    # to crossfade an old layer out and a new one in during a morph.
    param($Graphics, [System.Drawing.RectangleF]$Rect, [string]$Icon, [string]$Text, $Font, [System.Drawing.Color]$Color, [float]$Alpha, [float]$YOffset)
    $hasIcon = [bool]$Icon
    $hasText = [bool]$Text
    if ($Alpha -le 0.01 -or (-not $hasIcon -and -not $hasText)) { return }
    $iconSize = 12
    $gap = 6
    # Measure with the same StringFormat we draw with (GenericTypographic,
    # via Graphics.MeasureString/DrawString - both GDI+). Mixing this with
    # TextRenderer.MeasureText (GDI) used to under/overshoot by a couple px
    # because GenericDefault - DrawString's implicit format - pads the
    # string with extra leading space GDI's measurement doesn't know about,
    # so the centered group rendered a few px right of true center.
    $sf = [System.Drawing.StringFormat]::GenericTypographic
    $textSize = if ($hasText) { $Graphics.MeasureString($Text, $Font, [System.Drawing.PointF]::Empty, $sf) } else { [System.Drawing.SizeF]::Empty }
    $totalW = $textSize.Width + $(if ($hasIcon -and $hasText) { $iconSize + $gap } elseif ($hasIcon) { $iconSize } else { 0 })
    $startX = $Rect.X + ($Rect.Width - $totalW) / 2.0
    $centerY = $Rect.Y + $Rect.Height / 2.0 + $YOffset

    if ($hasIcon) {
        $iconRect = New-Object System.Drawing.RectangleF($startX, ($centerY - $iconSize / 2.0), $iconSize, $iconSize)
        Draw-ToolbarIcon -Graphics $Graphics -Icon $Icon -Rect $iconRect -Color $Color -Alpha $Alpha
        $startX += $iconSize + $(if ($hasText) { $gap } else { 0 })
    }
    if ($hasText) {
        $textColor = [System.Drawing.Color]::FromArgb([int](255 * $Alpha), $Color)
        $brush = New-Object System.Drawing.SolidBrush($textColor)
        $Graphics.DrawString($Text, $Font, $brush, $startX, ($centerY - $textSize.Height / 2.0), $sf)
        $brush.Dispose()
    }
}

function Draw-ButtonContent {
    # When a morph is mid-flight ($t.AnimProgress < 1), crossfades the old
    # icon/text out (fading up) while the new one fades in (from below) —
    # the same idea as the React version's AnimatePresence icon/text swap,
    # just driven by a WinForms Timer tick instead of framer-motion.
    param($Graphics, [System.Drawing.RectangleF]$Rect, $Tag, $Font, [System.Drawing.Color]$Color)
    $Graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $p = $Tag.AnimProgress
    if ($p -ge 1.0 -or -not $Tag.PrevText) {
        Draw-ButtonLayer -Graphics $Graphics -Rect $Rect -Icon $Tag.Icon -Text $Tag.DisplayText -Font $Font -Color $Color -Alpha 1.0 -YOffset 0
        return
    }
    $eased = 1 - [Math]::Pow(1 - $p, 3)
    Draw-ButtonLayer -Graphics $Graphics -Rect $Rect -Icon $Tag.PrevIcon -Text $Tag.PrevText -Font $Font -Color $Color -Alpha (1 - $eased) -YOffset (-4 * $eased)
    Draw-ButtonLayer -Graphics $Graphics -Rect $Rect -Icon $Tag.Icon -Text $Tag.DisplayText -Font $Font -Color $Color -Alpha $eased -YOffset (4 * (1 - $eased))
}

function Start-ButtonMorph {
    # Arms the crossfade + (optional) solid-fill flip on a button already
    # set up by Initialize-ModernButton. Used to turn Stop All into an
    # inline "Confirm?" state instead of a blocking MessageBox.
    param($Button, [string]$Icon, [string]$Text, [string]$Variant = $null)
    $t = $Button.Tag
    if ($t.DisplayText -eq $Text -and $t.Icon -eq $Icon) { return }

    $t.PrevIcon = $t.Icon
    $t.PrevText = $t.DisplayText
    $t.Icon = $Icon
    $t.DisplayText = $Text

    switch ($Variant) {
        'Accent'  { $t.Fg = $script:Theme.Accent;  $t.BorderNormal = $script:Theme.Border;  $t.FillActive = $script:Theme.AccentTint;  $t.BorderActive = $script:Theme.Accent; $t.SolidFill = $null }
        'Success' { $t.Fg = $script:Theme.Success; $t.BorderNormal = $script:Theme.Success; $t.FillActive = $script:Theme.SuccessTint; $t.BorderActive = $script:Theme.Success; $t.SolidFill = $null }
        'Danger'  { $t.Fg = $script:Theme.Danger;  $t.BorderNormal = $script:Theme.Danger;  $t.FillActive = $script:Theme.DangerTint;  $t.BorderActive = $script:Theme.Danger; $t.SolidFill = $null }
        'DangerSolid' { $t.Fg = [System.Drawing.Color]::White; $t.BorderNormal = $script:Theme.Danger; $t.BorderActive = $script:Theme.Danger; $t.FillActive = $script:Theme.Danger; $t.SolidFill = $script:Theme.Danger }
    }

    $t.AnimProgress = 0.0
    if (-not $t.AnimTimer) {
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 15
        $timer.Add_Tick({
            param($s, $e)
            $bt = $Button.Tag
            $bt.AnimProgress += 0.15
            if ($bt.AnimProgress -ge 1.0) { $bt.AnimProgress = 1.0; $s.Stop() }
            if (-not $Button.IsDisposed) { $Button.Invalidate() }
        }.GetNewClosure())
        $t.AnimTimer = $timer
    }
    $t.AnimTimer.Start()
    $Button.Invalidate()
}

function Get-ButtonRoundedRectPath {
    # Builds the anti-aliased rounded-rect outline shared by every button
    # paint state (split-mode and normal) - Region-based clipping has hard,
    # stair-stepped corners with no anti-aliasing, so this traces the path
    # by hand instead. Caller owns the returned path and must Dispose it.
    param([System.Drawing.Rectangle]$Rect, [int]$Radius)
    $d = [Math]::Min($Radius * 2, [Math]::Min($Rect.Width, $Rect.Height))
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($d -le 0) {
        $path.AddRectangle($Rect)
    } else {
        $path.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90)
        $path.AddArc($Rect.Right - $d, $Rect.Y, $d, $d, 270, 90)
        $path.AddArc($Rect.Right - $d, $Rect.Bottom - $d, $d, $d, 0, 90)
        $path.AddArc($Rect.X, $Rect.Bottom - $d, $d, $d, 90, 90)
        $path.CloseFigure()
    }
    return $path
}

function Draw-SplitModeButtonContent {
    # Two-option pill: left half is a plain "Cancel" tile (an X, no fill
    # commitment), right half is the actual destructive action (solid
    # Danger, a check) - same rounded outline as a normal button, just
    # clipped into two independently-filled halves either side of a thin
    # divider, so the confirm step reads as "pick one of two buttons"
    # instead of "click here again".
    param($Graphics, $Path, [System.Drawing.Rectangle]$Rect, $Tag)
    $g = $Graphics
    $midX = $Rect.X + $Rect.Width / 2.0
    $leftRectF  = New-Object System.Drawing.RectangleF($Rect.X, $Rect.Y, ($midX - $Rect.X), $Rect.Height)
    $rightRectF = New-Object System.Drawing.RectangleF($midX, $Rect.Y, ($Rect.Right - $midX), $Rect.Height)
    $leftFill   = if ($Tag.State -eq 'Pressed') { $script:Theme.PanelBg } else { $script:Theme.CardBg }

    $origClip = $g.Clip.Clone()
    $g.SetClip($Path, [System.Drawing.Drawing2D.CombineMode]::Replace)
    $g.SetClip($leftRectF, [System.Drawing.Drawing2D.CombineMode]::Intersect)
    $leftBrush = New-Object System.Drawing.SolidBrush($leftFill)
    $g.FillRectangle($leftBrush, $Rect)
    $leftBrush.Dispose()
    $g.Clip = $origClip.Clone()

    $g.SetClip($Path, [System.Drawing.Drawing2D.CombineMode]::Replace)
    $g.SetClip($rightRectF, [System.Drawing.Drawing2D.CombineMode]::Intersect)
    $rightBrush = New-Object System.Drawing.SolidBrush($Tag.SplitAccent)
    $g.FillRectangle($rightBrush, $Rect)
    $rightBrush.Dispose()
    $g.Clip = $origClip.Clone()
    $g.ResetClip()

    $borderPen = New-Object System.Drawing.Pen($Tag.SplitAccent, 1.4)
    $g.DrawPath($borderPen, $Path)
    $borderPen.Dispose()

    $dividerColor = [System.Drawing.Color]::FromArgb(100, $script:Theme.Border)
    $dividerPen = New-Object System.Drawing.Pen($dividerColor, 1.2)
    $g.DrawLine($dividerPen, $midX, ($Rect.Y + 4), $midX, ($Rect.Bottom - 4))
    $dividerPen.Dispose()

    $iconSize = 13
    $leftIconRect  = New-Object System.Drawing.RectangleF(($leftRectF.X + $leftRectF.Width / 2.0 - $iconSize / 2.0), ($Rect.Y + $Rect.Height / 2.0 - $iconSize / 2.0), $iconSize, $iconSize)
    $rightIconRect = New-Object System.Drawing.RectangleF(($rightRectF.X + $rightRectF.Width / 2.0 - $iconSize / 2.0), ($Rect.Y + $Rect.Height / 2.0 - $iconSize / 2.0), $iconSize, $iconSize)
    Draw-ToolbarIcon -Graphics $g -Icon 'X' -Rect $leftIconRect -Color $script:Theme.TextPrimary -Alpha 1.0
    Draw-ToolbarIcon -Graphics $g -Icon 'Check' -Rect $rightIconRect -Color ([System.Drawing.Color]::White) -Alpha 1.0
}

function Get-ButtonPaintColors {
    # Resolves the fill/border/text colors for one paint of a non-split-mode
    # button, given its current owner-drawn state (see Initialize-ModernButton's
    # $Button.Tag). Disabled wins over everything; a caller-set SolidFill
    # (used for morphed/pill-style buttons) wins over the normal
    # state-based Normal/Hover/Pressed palette.
    param($Tag, [bool]$Enabled, [System.Drawing.Color]$ParentColor)
    if (-not $Enabled) {
        $fillColor = $ParentColor
        $borderColor = $script:Theme.Border
        $textColor = $script:Theme.TextDim
    } elseif ($Tag.SolidFill) {
        $fillColor = $Tag.SolidFill
        $borderColor = $Tag.SolidFill
        $textColor = $Tag.Fg
    } else {
        $fillColor = if ($Tag.State -eq 'Normal') { $script:Theme.CardBg } else { $Tag.FillActive }
        $borderColor = if ($Tag.State -eq 'Normal') { $Tag.BorderNormal } else { $Tag.BorderActive }
        $textColor = $Tag.Fg
    }
    if ($null -eq $fillColor) { $fillColor = $script:Theme.CardBg }
    if ($null -eq $borderColor) { $borderColor = $script:Theme.Border }
    if ($null -eq $textColor) { $textColor = $script:Theme.TextPrimary }
    return @{ Fill = $fillColor; Border = $borderColor; Text = $textColor }
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
    # -Icon opts a button into the icon+text layer (Draw-ButtonContent) so
    # it can later be morphed via Start-ButtonMorph; plain buttons just get
    # a single static layer with Icon = $null.
    param($Button, [string]$Variant = 'Neutral', [int]$Radius = $script:Theme.Radius, [string]$Icon = $null)

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
    $Button.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9)
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.UseVisualStyleBackColor = $false
    $Button.Tag = [PSCustomObject]@{
        State = 'Normal'; Fg = $fg; BorderNormal = $borderNormal; FillActive = $fillActive; BorderActive = $borderActive; Radius = $Radius
        Icon = $Icon; DisplayText = $Button.Text; PrevIcon = $null; PrevText = $null; AnimProgress = 1.0; AnimTimer = $null; SolidFill = $null
        SplitMode = $false; LastMouseDownX = 0; SplitAccent = $script:Theme.Danger
    }

    $dbProp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance, NonPublic')
    $dbProp.SetValue($Button, $true, $null)

    $Button.Add_MouseEnter({ param($s, $e) $s.Tag.State = 'Hover'; $s.Invalidate() })
    $Button.Add_MouseLeave({ param($s, $e) $s.Tag.State = 'Normal'; $s.Invalidate() })
    $Button.Add_MouseDown({ param($s, $e) $s.Tag.State = 'Pressed'; $s.Tag.LastMouseDownX = $e.X; $s.Invalidate() })
    $Button.Add_MouseUp({ param($s, $e) $s.Tag.State = 'Hover'; $s.Invalidate() })
    $Button.Add_EnabledChanged({ param($s, $e) $s.Tag.State = 'Normal'; $s.Invalidate() })

    $Button.Add_Paint({
        param($s, $e)
        $t = $s.Tag
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $parentColor = if ($s.Parent) { $s.Parent.BackColor } else { $script:Theme.WindowBg }
        $g.Clear($parentColor)

        # Pressed state insets the drawn rect by a couple of px instead of
        # resizing the actual control — a cheap stand-in for the original's
        # whileTap={{ scale: 0.98 }}, without disturbing sibling layout.
        $inset = if ($t.State -eq 'Pressed') { 2 } else { 0 }
        $rect = New-Object System.Drawing.Rectangle($inset, $inset, ($s.Width - 1 - 2 * $inset), ($s.Height - 1 - 2 * $inset))
        $path = Get-ButtonRoundedRectPath -Rect $rect -Radius $t.Radius

        if ($t.SplitMode) {
            Draw-SplitModeButtonContent -Graphics $g -Path $path -Rect $rect -Tag $t
            $path.Dispose()
            return
        }

        $colors = Get-ButtonPaintColors -Tag $t -Enabled $s.Enabled -ParentColor $parentColor

        $fillBrush = New-Object System.Drawing.SolidBrush($colors.Fill)
        $g.FillPath($fillBrush, $path)
        $fillBrush.Dispose()

        $borderPen = New-Object System.Drawing.Pen($colors.Border, 1.4)
        $g.DrawPath($borderPen, $path)
        $borderPen.Dispose()

        $contentRect = New-Object System.Drawing.RectangleF($rect.X, $rect.Y, $rect.Width, $rect.Height)
        Draw-ButtonContent -Graphics $g -Rect $contentRect -Tag $t -Font $s.Font -Color $colors.Text

        $path.Dispose()
    })
}

# Fully custom tab strip, used instead of the native TabControl. TabControl
# paints its tab-strip chrome via the OS visual style renderer regardless of
# any owner-draw hookup - fine in light mode since that native look is
# already near-white, but in dark mode the selected tab in particular kept
# showing a native light background no matter what DrawItem painted (a
# long-standing WinForms/TabControl quirk, not something fixable from
# DrawItem alone). Same custom-control philosophy already used for buttons/
# toggles/pills elsewhere in this file, applied here for the same reason:
# guaranteed colors in both themes instead of fighting native chrome.
function New-CustomTabControl {
    param([string[]]$Labels)

    $root = New-Object System.Windows.Forms.Panel
    $root.BackColor = $script:Theme.CardBg

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 32
    $header.BackColor = $script:Theme.PanelBg

    $headerBorder = New-Object System.Windows.Forms.Panel
    $headerBorder.Dock = 'Bottom'
    $headerBorder.Height = 1
    $headerBorder.BackColor = $script:Theme.Border
    $header.Controls.Add($headerBorder)

    $body = New-Object System.Windows.Forms.Panel
    $body.Dock = 'Fill'
    $body.BackColor = $script:Theme.CardBg

    $root.Controls.Add($body)
    $root.Controls.Add($header)

    $tabSet = [PSCustomObject]@{
        Root     = $root
        Header   = $header
        Body     = $body
        Buttons  = @()
        Pages    = @()
        Selected = 0
    }

    foreach ($lbl in $Labels) {
        $btn = New-Object System.Windows.Forms.Label
        $btn.Text = $lbl
        $btn.TextAlign = 'MiddleCenter'
        $btn.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9)
        $btn.Height = $header.Height - 1
        $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
        $header.Controls.Add($btn)
        $tabSet.Buttons += $btn

        $page = New-Object System.Windows.Forms.Panel
        $page.Dock = 'Fill'
        $page.BackColor = $script:Theme.CardBg
        $page.Visible = $false
        $body.Controls.Add($page)
        $tabSet.Pages += $page
    }

    for ($i = 0; $i -lt $tabSet.Buttons.Count; $i++) {
        $idx = $i
        $tabSet.Buttons[$i].Add_Click({ Select-CustomTab -TabSet $tabSet -Index $idx }.GetNewClosure())
    }

    Update-CustomTabLayout -TabSet $tabSet
    Select-CustomTab -TabSet $tabSet -Index 0
    return $tabSet
}

function Update-CustomTabLayout {
    param($TabSet)
    $x = 6
    $btnHeight = $TabSet.Header.Height - 1
    foreach ($btn in $TabSet.Buttons) {
        $w = ([System.Windows.Forms.TextRenderer]::MeasureText($btn.Text, $btn.Font).Width) + 28
        $btn.Location = New-Object System.Drawing.Point($x, 0)
        $btn.Size = New-Object System.Drawing.Size($w, $btnHeight)
        $x += $w
    }
}

function Select-CustomTab {
    param($TabSet, [int]$Index)
    for ($i = 0; $i -lt $TabSet.Buttons.Count; $i++) {
        $btn = $TabSet.Buttons[$i]
        $isSel = ($i -eq $Index)
        $btn.BackColor = if ($isSel) { $script:Theme.CardBg } else { $script:Theme.PanelBg }
        $btn.ForeColor = if (-not $btn.Enabled) { $script:Theme.Border } elseif ($isSel) { $script:Theme.TextPrimary } else { $script:Theme.TextDim }
        $TabSet.Pages[$i].Visible = $isSel
    }
    $TabSet.Selected = $Index
}

function Set-CustomTabEnabled {
    # Grayed out, not hidden, when disabled - same idiom the old TabPage-
    # based System tab used (Update-SystemTabState): still visible/
    # discoverable, just inert. Doesn't force navigation away if it happens
    # to already be the selected tab - the page's own content (grid vs.
    # placeholder) already communicates the "off" state.
    param($TabSet, [int]$Index, [bool]$Enabled)
    $btn = $TabSet.Buttons[$Index]
    $btn.Enabled = $Enabled
    $btn.Cursor = if ($Enabled) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }
    $isSel = ($TabSet.Selected -eq $Index)
    $btn.ForeColor = if (-not $Enabled) { $script:Theme.Border } elseif ($isSel) { $script:Theme.TextPrimary } else { $script:Theme.TextDim }
}

function Set-CustomTabText {
    param($TabSet, [int]$Index, [string]$Text)
    $TabSet.Buttons[$Index].Text = $Text
    Update-CustomTabLayout -TabSet $TabSet
}

# Small owner-drawn capsule/"badge" label (rounded ends, tinted fill) used
# for at-a-glance health indicators - e.g. the error-log status in Settings.
# Same anti-aliased-path technique as Initialize-ModernButton above, just
# fully rounded (pill) instead of a soft-corner rect, and non-interactive.
function New-StatusPill {
    param([string]$Text, [string]$Tone = 'Success')
    $fill = if ($Tone -eq 'Danger') { $script:Theme.DangerTint } else { $script:Theme.SuccessTint }
    $fg   = if ($Tone -eq 'Danger') { $script:Theme.Danger } else { $script:Theme.Success }

    $pill = New-Object System.Windows.Forms.Label
    $pill.AutoSize = $false
    $pill.TextAlign = 'MiddleCenter'
    $pill.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 8, [System.Drawing.FontStyle]::Bold)
    $pill.ForeColor = $fg
    $pill.Tag = [PSCustomObject]@{ Fill = $fill }

    $dbProp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance, NonPublic')
    $dbProp.SetValue($pill, $true, $null)

    $pill.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $parentColor = if ($s.Parent) { $s.Parent.BackColor } else { $script:Theme.WindowBg }
        $g.Clear($parentColor)

        $rect = New-Object System.Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
        $d = $rect.Height
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        if ($script:Theme.Radius -le 0) {
            $path.AddRectangle($rect)
        } else {
            $path.AddArc($rect.X, $rect.Y, $d, $d, 90, 180)
            $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 180)
            $path.CloseFigure()
        }

        $fillBrush = New-Object System.Drawing.SolidBrush($s.Tag.Fill)
        $g.FillPath($fillBrush, $path)
        $fillBrush.Dispose()

        $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
        [System.Windows.Forms.TextRenderer]::DrawText($g, $s.Text, $s.Font, $s.ClientRectangle, $s.ForeColor, $flags)
        $path.Dispose()
    })

    $pill.Text = $Text
    $measured = [System.Windows.Forms.TextRenderer]::MeasureText($Text, $pill.Font)
    $pill.Size = New-Object System.Drawing.Size(($measured.Width + 22), 20)
    return $pill
}

# ---------------------------------------------------------------------------
# Rounds any dropdown/context-menu popup (ToolStripDropDown, the auto-created
# ToolStripDropDownMenu behind a top-level menu item, or a ContextMenuStrip —
# all derive from ToolStripDropDown) by clipping it to a rounded-rect Region
# on every paint, since AutoSize means the final Size isn't known until
# layout, then stroking a matching border so the corners don't look bare.
# ---------------------------------------------------------------------------
# Scales a Light/Dark-tuned radius down to 0 under the Terminal theme,
# instead of every call site hardcoding its own theme check.
function Get-ThemedRadius {
    param([int]$Default = $script:Theme.Radius)
    if ($script:Theme.Radius -le 0) { return 0 }
    return $Default
}

function Enable-RoundedPopup {
    param($Popup, [int]$Radius = $script:Theme.Radius)
    $Popup.BackColor = $script:Theme.CardBg
    $paintHandler = {
        param($s, $e)
        if ($s.Width -le 0 -or $s.Height -le 0) { return }
        $rect = New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.Height)
        $d = [Math]::Min($Radius * 2, [Math]::Min($rect.Width, $rect.Height))
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        if ($d -le 0) {
            $path.AddRectangle($rect)
        } else {
            $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
            $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
            $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
            $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
            $path.CloseFigure()
        }
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

$script:RootDir = $script:Settings.RootDir
$script:CustomNames = Load-CustomNames
$script:DeployDefs = Load-DeployDefs
$script:Groups = Load-Groups
$script:SelectedGroups = @($script:Settings.SelectedGroups | Where-Object { $script:Groups.ContainsKey($_) })
# Search box state - deliberately transient (not persisted to
# settings.json, resets on restart, same as a browser's find-in-page).
# LastDisplaySplit caches the most recently built Get-DisplayRowsSplit
# result so typing in the search box can re-filter/re-render instantly
# without a fresh live scan or history.json write - see
# Get-SearchFilteredDisplay/Render-FilteredGrids.
$script:SearchFilter = ''
$script:LastDisplaySplit = $null

# Processes launched by this app, keyed by normalized project path. Lets us
# capture stdout/stderr and tell "stopped by user" apart from "exited on its
# own" for the one PID this app actually holds a handle to (the npm/cmd
# wrapper) — separate from the PID discovered via TCP scanning below, which
# is often a few process-tree hops downstream of this one.
$script:ManagedProcesses = @{}
# Rolling-window auto-restart attempt timestamps, keyed by normalized
# project path - deliberately NOT stored on a $script:ManagedProcesses
# entry, since Start-ProjectAtPath replaces that entry outright on every
# (re)start, which would reset an attempt counter kept there back to zero
# after a single successful restart and defeat the whole point of capping
# a crash loop. This dictionary outlives any one process's entry.
$script:AutoRestartAttempts = @{}
# User-configurable via Settings > Preferences > Startup - Load-Settings
# already validated/clamped these (falls back to 5/5 if missing or
# nonsensical), so no further checking needed here. Kept as their own
# script-scope variables (rather than reading $script:Settings.* directly
# at every use site) since they're read on every crash, and the Settings
# dialog's OK handler updates both in lockstep with $script:Settings so a
# changed cap takes effect immediately, no restart required.
$script:AutoRestartMaxAttempts = [int]$script:Settings.AutoRestartMaxAttempts
$script:AutoRestartWindowMinutes = [int]$script:Settings.AutoRestartWindowMinutes
# Guards Invoke-Restart/Invoke-ToggleAction against re-entrancy: both now
# pump the UI message loop (Wait-UiResponsive) while they wait on kills/
# starts instead of blocking it outright, which keeps the window responsive
# but also means a click on another action button mid-flight would normally
# reach its handler. One action at a time app-wide is simpler and safer than
# reasoning about interleaved starts/stops.
$script:ActionBusy = $false
$script:LogCap = 1000
$script:LogDir = Join-Path $script:HistoryDir 'logs'
$script:LogDiskCap = 2000
$script:AppLogPath = Join-Path $script:LogDir 'app-error.log'
$script:AppLogDiskCap = 2000

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

# App-level failures (as opposed to a managed dev server crashing) -
# startup errors, unhandled exceptions in event handlers, things that don't
# have a project to attach a per-project log to. Kept separate from the
# per-project logs above so "is Localhost Manager itself broken" is always
# one file, regardless of which project (if any) was involved.
function Write-AppErrorLog {
    param([string]$Context, [System.Exception]$Exception, [string]$Extra, [ValidateSet('Error', 'Warning')][string]$Level = 'Error')
    try {
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        $lines = @("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$($Level.ToUpper())] $Context")
        if ($Exception) {
            $lines += "    $($Exception.GetType().FullName): $($Exception.Message)"
            if ($Exception.StackTrace) {
                $lines += ($Exception.StackTrace -split "`r?`n" | ForEach-Object { "    $_" })
            }
        }
        if ($Extra) { $lines += "    $Extra" }
        Add-Content -Path $script:AppLogPath -Value $lines -Encoding UTF8
        $existing = @(Get-Content -Path $script:AppLogPath -ErrorAction Stop)
        if ($existing.Count -gt $script:AppLogDiskCap) {
            Set-Content -Path $script:AppLogPath -Value ($existing | Select-Object -Last $script:AppLogDiskCap) -Encoding UTF8
        }
    } catch {}
}

# Each logged failure starts with a "[yyyy-MM-dd HH:mm:ss] Context" line,
# optionally followed by indented detail lines - counting matches of that
# header pattern gives an entry count without having to parse the whole
# file into structured records just to answer "is anything wrong?".
function Get-AppErrorLogStats {
    $stats = [PSCustomObject]@{ Count = 0; LastText = $null }
    if (-not (Test-Path $script:AppLogPath)) { return $stats }
    try {
        $headers = @(Get-Content -Path $script:AppLogPath -ErrorAction Stop |
            Where-Object { $_ -match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]' })
        $stats.Count = $headers.Count
        if ($headers.Count -gt 0 -and $headers[-1] -match '^\[([^\]]+)\]\s*(?:\[(?:ERROR|WARNING)\]\s*)?(.*)$') {
            $stats.LastText = "$($matches[2]) ($($matches[1]))"
        }
    } catch {}
    return $stats
}

# Belt-and-suspenders net for the many event handlers below (timer ticks,
# grid/menu click handlers, Register-ObjectEvent callbacks) that have no
# try/catch of their own - without this, an exception raised inside one of
# those just vanishes (or takes the whole message loop down) with nothing
# on disk to explain why. This does NOT replace the explicit
# Write-AppErrorLog calls at specific failure points below; those give
# better context than "an unhandled exception happened somewhere".
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException) | Out-Null
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    Write-AppErrorLog -Context 'Unhandled UI exception' -Exception $e.Exception
})
[System.AppDomain]::CurrentDomain.add_UnhandledException({
    param($sender, $e)
    Write-AppErrorLog -Context 'Unhandled exception (fatal)' -Exception ($e.ExceptionObject -as [System.Exception])
})

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

# Single source of truth for the version shown in About and compared
# against GitHub's latest release tag by the update checker - bump this
# (and CHANGELOG.md) on every release instead of editing the About label.
$script:AppVersion = '1.18.4'
$script:UpdateRepo = 'zanopyth/local-host-manager'

function Get-AppIcon {
    param([string]$FileName)
    $path = Join-Path $script:AppDir $FileName
    if (Test-Path $path) {
        try { return New-Object System.Drawing.Icon($path) } catch {}
    }
    try { return [System.Drawing.Icon]::ExtractAssociatedIcon([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch { return [System.Drawing.SystemIcons]::Application }
}

# System.Drawing.Icon's own pixel data comes out corrupted (colored static)
# for any frame stored PNG-compressed - which every frame in a modern .ico
# saved by current icon tools is - and that's not just a .ToBitmap() quirk:
# Graphics.DrawIcon on the same Icon object reproduces the identical
# garbage, so nothing routed through the Icon class can be trusted for a
# static bitmap. Windows' own native icon painting (Form.Icon, NotifyIcon)
# is unaffected - only .NET's own extraction is broken - so this reads the
# .ico's ICONDIR by hand, grabs the entry closest to the wanted size, and
# decodes its embedded image bytes directly as a PNG/Bitmap, never touching
# System.Drawing.Icon at all.
function Get-AppIconBitmap {
    param([string]$FileName, [int]$Size = 48)
    $path = Join-Path $script:AppDir $FileName
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $count = [BitConverter]::ToUInt16($bytes, 4)
        $best = $null
        for ($i = 0; $i -lt $count; $i++) {
            $off = 6 + ($i * 16)
            $w = $bytes[$off]; if ($w -eq 0) { $w = 256 }
            $entry = [PSCustomObject]@{
                Width      = $w
                ByteSize   = [BitConverter]::ToUInt32($bytes, $off + 8)
                ImgOffset  = [BitConverter]::ToUInt32($bytes, $off + 12)
            }
            if (-not $best -or [Math]::Abs($entry.Width - $Size) -lt [Math]::Abs($best.Width - $Size)) { $best = $entry }
        }
        if ($best) {
            $frameBytes = New-Object byte[] $best.ByteSize
            [Array]::Copy($bytes, $best.ImgOffset, $frameBytes, 0, $best.ByteSize)
            $ms = New-Object System.IO.MemoryStream(,$frameBytes)
            $bmp = [System.Drawing.Image]::FromStream($ms)
            return New-Object System.Drawing.Bitmap($bmp, $Size, $Size)
        }
    } catch {}
    return $null
}

$script:IconOk = Get-AppIcon 'LocalhostManager.ico'
$script:IconAlert = Get-AppIcon 'LocalhostManager-alert.ico'

# ---------------------------------------------------------------------------
# Update checker: compares $script:AppVersion against the tag of GitHub's
# "latest" release for this repo. Runs the actual HTTP call on a background
# runspace (same pattern as the live-listener poller) so a slow/offline
# network never blocks the UI thread, and reports back through a
# synchronized hashtable a WinForms Timer polls until it's done.
# ---------------------------------------------------------------------------
function Compare-VersionStrings {
    # Positive if A > B, negative if A < B, 0 if equal. Numeric per-segment
    # comparison (not string comparison) so "1.8.10" correctly beats "1.8.9".
    param([string]$A, [string]$B)
    $pa = @(($A -replace '^v') -split '\.' | ForEach-Object { [int]([regex]::Match($_, '\d+').Value) })
    $pb = @(($B -replace '^v') -split '\.' | ForEach-Object { [int]([regex]::Match($_, '\d+').Value) })
    for ($i = 0; $i -lt [Math]::Max($pa.Count, $pb.Count); $i++) {
        $x = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $y = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($x -ne $y) { return $x - $y }
    }
    return 0
}

$script:UpdateCheckInFlight = $false
$script:UpdateAvailable = $false
$script:UpdateLatestVersion = $null
$script:UpdateUrl = $null

$script:UpdateCheckError = $null

function Complete-UpdateCheck {
    # No MessageBox here on purpose - Show-UpdateCheckDialog (opened
    # immediately on click, before this ever resolves) polls these same
    # script:Update* fields and updates itself in place once
    # UpdateCheckInFlight flips false, so the manual "Check for Updates..."
    # path always gets visible feedback instead of a silent wait. The
    # automatic startup check has no dialog open to update, so it still
    # only surfaces a found update via the tray balloon below.
    param($Cache)
    $script:UpdateCheckError = $null
    if ($Cache.Error -or -not $Cache.Latest) {
        $script:UpdateCheckError = if ($Cache.Error) { $Cache.Error } else { 'No release information returned.' }
        return
    }
    $latest = [string]$Cache.Latest
    if ((Compare-VersionStrings $latest $script:AppVersion) -gt 0) {
        $script:UpdateAvailable = $true
        $script:UpdateLatestVersion = $latest -replace '^v'
        $script:UpdateUrl = [string]$Cache.Url
        try {
            $script:BalloonAction = 'Update'
            $notifyIcon.ShowBalloonTip(6000, 'Localhost Manager', "Update available: $latest (you have v$script:AppVersion). Click to download.", [System.Windows.Forms.ToolTipIcon]::Info)
        } catch {}
    }
}

function Start-UpdateCheck {
    param([switch]$Interactive)
    if ($script:UpdateCheckInFlight) { return }
    if (-not $Interactive -and -not [bool]$script:Settings.CheckForUpdates) { return }

    $script:UpdateCheckInFlight = $true
    $cache = [hashtable]::Synchronized(@{ Done = $false; Latest = $null; Url = $null; Error = $null })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($Cache, $Repo)
        try {
            $resp = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'LocalhostManager-UpdateCheck' } -TimeoutSec 6
            $Cache.Latest = [string]$resp.tag_name
            $Cache.Url = [string]$resp.html_url
        } catch {
            $Cache.Error = $_.Exception.Message
        } finally {
            $Cache.Done = $true
        }
    }).AddArgument($cache).AddArgument($script:UpdateRepo)
    $asyncHandle = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 400
    $timer.Add_Tick({
        if (-not $cache.Done) { return }
        $timer.Stop()
        try { $ps.EndInvoke($asyncHandle) } catch {}
        $ps.Dispose(); $rs.Close(); $rs.Dispose()
        $script:UpdateCheckInFlight = $false
        Complete-UpdateCheck -Cache $cache
    }.GetNewClosure())
    $timer.Start()
}

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
        $bg = if ($isOn) { $script:Theme.Accent } else { $script:Theme.ToggleOff }
        $d = $s.Height
        $brush = New-Object System.Drawing.SolidBrush($bg)
        if ($script:Theme.Radius -le 0) {
            $g.FillRectangle($brush, 0, 0, $s.Width, $s.Height)
        } else {
            $path = New-Object System.Drawing.Drawing2D.GraphicsPath
            $path.AddArc(0, 0, $d, $d, 90, 180)
            $path.AddArc($s.Width - $d, 0, $d, $d, 270, 180)
            $path.CloseFigure()
            $g.FillPath($brush, $path)
            $path.Dispose()
        }
        $brush.Dispose()
        $knobD = $d - 4
        $knobX = if ($isOn) { $s.Width - $knobD - 2 } else { 2 }
        if ($script:Theme.Radius -le 0) {
            $g.FillRectangle([System.Drawing.Brushes]::White, $knobX, 2, $knobD, $knobD)
        } else {
            $g.FillEllipse([System.Drawing.Brushes]::White, $knobX, 2, $knobD, $knobD)
        }
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
    # 23x23 to sit close to the search box's 24px height (top-aligned with
    # it too - see its Location below) instead of the smaller 20x20 this
    # used to be, which read as visually mismatched sitting right next to
    # it.
    $pill.Size = New-Object System.Drawing.Size(23, 23)
    $pill.Tag = [PSCustomObject]@{ On = $false; Text = 'Dashboard off'; Url = $null }

    $dbProp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance, NonPublic')
    $dbProp.SetValue($pill, $true, $null)

    $pill.Add_Paint({
        param($s, $e)
        $t = $s.Tag
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $parentColor = if ($s.Parent) { $s.Parent.BackColor } else { $script:Theme.WindowBg }
        $g.Clear($parentColor)

        $rect = New-Object System.Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
        $d = $rect.Height
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        if ($script:Theme.Radius -le 0) {
            $path.AddRectangle($rect)
        } else {
            $path.AddArc($rect.X, $rect.Y, $d, $d, 90, 180)
            $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 180)
            $path.CloseFigure()
        }

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
        if ($script:Theme.Radius -le 0) {
            $g.FillRectangle($dotBrush, $dotRect.X, $dotRect.Y, $dotRect.Width, $dotRect.Height)
        } else {
            $g.FillEllipse($dotBrush, $dotRect)
        }
        $dotBrush.Dispose()

        $path.Dispose()
    })

    $pill.Add_Click({
        param($s, $e)
        if ($s.Tag.On -and $s.Tag.Url) { try { Start-Process $s.Tag.Url } catch {} }
    })

    return $pill
}

function New-ActionBusyIndicator {
    # Same ring+dot look as the dashboard pill above (square in Terminal
    # theme, rounded otherwise - both just read $script:Theme.Radius),
    # repurposed as a busy light: hidden at rest, shown and blinking
    # red/green for the duration of a Start/Stop/Restart action so a
    # Wait-UiResponsive pause reads as "working" instead of "frozen".
    $ind = New-Object System.Windows.Forms.Panel
    $ind.Size = New-Object System.Drawing.Size(34, 28)
    $ind.Tag = [PSCustomObject]@{ Lit = $false }
    $ind.Visible = $false
    $ind.Cursor = [System.Windows.Forms.Cursors]::Default

    $dbProp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance, NonPublic')
    $dbProp.SetValue($ind, $true, $null)

    $ind.Add_Paint({
        param($s, $e)
        $t = $s.Tag
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $parentColor = if ($s.Parent) { $s.Parent.BackColor } else { $script:Theme.WindowBg }
        $g.Clear($parentColor)

        $size = [Math]::Min($s.Width, $s.Height)
        $rect = New-Object System.Drawing.Rectangle((($s.Width - $size) / 2), (($s.Height - $size) / 2), $size, $size)
        $d = $rect.Height
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        if ($script:Theme.Radius -le 0) {
            $path.AddRectangle($rect)
        } else {
            $path.AddArc($rect.X, $rect.Y, $d, $d, 90, 180)
            $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 180)
            $path.CloseFigure()
        }

        $ringColor = if ($t.Lit) { $script:Theme.Success } else { $script:Theme.Danger }
        $fillColor = if ($t.Lit) { $script:Theme.SuccessTint } else { $script:Theme.DangerTint }

        $fillBrush = New-Object System.Drawing.SolidBrush($fillColor)
        $g.FillPath($fillBrush, $path)
        $fillBrush.Dispose()

        $borderPen = New-Object System.Drawing.Pen($ringColor, 1)
        $g.DrawPath($borderPen, $path)
        $borderPen.Dispose()

        $dotSize = 8.0
        $cx = $rect.X + ($rect.Width / 2.0)
        $cy = $rect.Y + ($rect.Height / 2.0)
        $dotRect = New-Object System.Drawing.RectangleF(($cx - $dotSize / 2.0), ($cy - $dotSize / 2.0), $dotSize, $dotSize)
        $dotBrush = New-Object System.Drawing.SolidBrush($ringColor)
        if ($script:Theme.Radius -le 0) {
            $g.FillRectangle($dotBrush, $dotRect.X, $dotRect.Y, $dotRect.Width, $dotRect.Height)
        } else {
            $g.FillEllipse($dotBrush, $dotRect)
        }
        $dotBrush.Dispose()

        $path.Dispose()
    })

    return $ind
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
$form.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9)
Set-DarkTitleBar -FormControl $form

# ---------------------------------------------------------------------------
# Menu bar — the standard File / Settings / About a desktop app is expected
# to have. Menu items call straight into the same functions the old toolbar
# buttons used (Show-SettingsDialog, Show-ManageGroupsDialog, Refresh-Grid,
# the tray Exit path); no persistence/business logic lives here.
# ---------------------------------------------------------------------------
$menuStrip = New-Object System.Windows.Forms.MenuStrip
$menuStrip.BackColor = $script:Theme.CardBg
$menuStrip.ForeColor = $script:Theme.TextPrimary
$menuStrip.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9)
$menuStrip.Padding = New-Object System.Windows.Forms.Padding(8, 3, 0, 3)
if ($script:MenuRenderer) { $menuStrip.Renderer = $script:MenuRenderer }

$menuFile = New-Object System.Windows.Forms.ToolStripMenuItem('File')
$menuFileRefresh = New-Object System.Windows.Forms.ToolStripMenuItem('Refresh')
$menuFileRefresh.ShortcutKeys = [System.Windows.Forms.Keys]::F5
$menuFileRefresh.Add_Click({ Refresh-Grid })
$menuFileBackup = New-Object System.Windows.Forms.ToolStripMenuItem('Backup Settings...')
$menuFileBackup.Add_Click({ Export-AppBackup })
$menuFileRestore = New-Object System.Windows.Forms.ToolStripMenuItem('Restore Backup...')
$menuFileRestore.Add_Click({ Import-AppBackup })
$menuFileExit = New-Object System.Windows.Forms.ToolStripMenuItem('Exit')
$menuFileExit.Add_Click({
    $script:ReallyExit = $true
    $notifyIcon.Visible = $false
    $form.Close()
})
[System.Windows.Forms.ToolStripItem[]]$menuFileItems = @($menuFileRefresh, (New-Object System.Windows.Forms.ToolStripSeparator), $menuFileBackup, $menuFileRestore, (New-Object System.Windows.Forms.ToolStripSeparator), $menuFileExit)
$menuFile.DropDownItems.AddRange($menuFileItems)

$menuSettings = New-Object System.Windows.Forms.ToolStripMenuItem('Settings')
$menuSettingsPrefs = New-Object System.Windows.Forms.ToolStripMenuItem('Preferences...')
$menuSettingsPrefs.Add_Click({ Show-SettingsDialog })
$menuSettingsGroups = New-Object System.Windows.Forms.ToolStripMenuItem('Manage Groups...')
$menuSettingsGroups.Add_Click({ Show-ManageGroupsDialog })
$menuSettingsNodeOnly = New-Object System.Windows.Forms.ToolStripMenuItem('Dev Servers Only')
$menuSettingsNodeOnly.Checked = $script:Settings.OnlyNode
# Stock ToolStripProfessionalRenderer draws a checked item's checkbox glyph
# and its text at overlapping X positions (reproduced in isolation with a
# bare, unthemed MenuStrip - not something this app's own rendering causes),
# clipping the first letter or two behind the checkbox. Padding.Left nudges
# the text clear of the glyph without touching the renderer/color table.
$menuSettingsNodeOnly.Padding = New-Object System.Windows.Forms.Padding(20, 2, 4, 2)
$menuSettingsNodeOnly.Add_Click({
    Invoke-ToggleClick -Switch $nodeOnlySwitch
    $menuSettingsNodeOnly.Checked = Get-ToggleChecked $nodeOnlySwitch
})
$menuSettingsUseGroups = New-Object System.Windows.Forms.ToolStripMenuItem('Use Groups')
$menuSettingsUseGroups.Checked = $script:Settings.ShowGroups
$menuSettingsUseGroups.Padding = New-Object System.Windows.Forms.Padding(20, 2, 4, 2)
$menuSettingsUseGroups.Add_Click({
    Invoke-ToggleClick -Switch $useGroupsSwitch
    $menuSettingsUseGroups.Checked = Get-ToggleChecked $useGroupsSwitch
})
[System.Windows.Forms.ToolStripItem[]]$menuSettingsItems = @($menuSettingsPrefs, $menuSettingsGroups, (New-Object System.Windows.Forms.ToolStripSeparator), $menuSettingsNodeOnly, $menuSettingsUseGroups)
$menuSettings.DropDownItems.AddRange($menuSettingsItems)

$menuDashboard = New-Object System.Windows.Forms.ToolStripMenuItem('Dashboard')
$menuDashboard.Add_Click({ Show-DashboardDialog })

$menuLocalDomains = New-Object System.Windows.Forms.ToolStripMenuItem('Local Domains')
$menuLocalDomains.Add_Click({ Show-ProxyDialog })

$menuHelp = New-Object System.Windows.Forms.ToolStripMenuItem('Help')
$menuHelpUpdate = New-Object System.Windows.Forms.ToolStripMenuItem('Check for Updates...')
$menuHelpUpdate.Add_Click({ Show-UpdateCheckDialog })
$menuHelpAbout = New-Object System.Windows.Forms.ToolStripMenuItem('About')
$menuHelpAbout.Add_Click({ Show-AboutDialog })
[System.Windows.Forms.ToolStripItem[]]$menuHelpItems = @($menuHelpUpdate, (New-Object System.Windows.Forms.ToolStripSeparator), $menuHelpAbout)
$menuHelp.DropDownItems.AddRange($menuHelpItems)

[System.Windows.Forms.ToolStripItem[]]$menuTopItems = @($menuFile, $menuSettings, $menuDashboard, $menuLocalDomains, $menuHelp)
$menuStrip.Items.AddRange($menuTopItems)
$form.MainMenuStrip = $menuStrip
# File and Help have no checkable/iconed items, so the ~25px gutter every
# ToolStripDropDownMenu reserves on the left for check/image glyphs was
# pure dead space - a persistent, unused-looking gap down the left edge of
# both menus. Settings keeps its margin: "Dev Servers Only" / "Use Groups"
# are real .Checked items that render their checkmark in that gutter.
$menuFile.DropDown.ShowImageMargin = $false
$menuHelp.DropDown.ShowImageMargin = $false
Enable-RoundedPopup -Popup $menuFile.DropDown
Enable-RoundedPopup -Popup $menuHelp.DropDown
Enable-RoundedPopup -Popup $menuSettings.DropDown
# Each top-level item's DropDown is a separate auto-created
# ToolStripDropDownMenu, not the MenuStrip itself - it doesn't inherit
# $menuStrip.ForeColor, so its item text defaulted to black regardless of
# the (dark, in dark mode) background Enable-RoundedPopup gives it.
$menuFile.DropDown.ForeColor = $script:Theme.TextPrimary
$menuSettings.DropDown.ForeColor = $script:Theme.TextPrimary
$menuHelp.DropDown.ForeColor = $script:Theme.TextPrimary

# By default, once one top-level menu is opened by a click, MenuStrip lets
# you switch to the next one just by hovering over it - standard Windows
# behavior, but not wanted here: every menu should need its own explicit
# click. A click-triggered open happens while the mouse button is still
# physically down (menus open on mouse-DOWN, not mouse-up, to support the
# classic press-drag-release gesture); a hover-triggered auto-switch to a
# sibling item happens with no button held at all. Checking MouseButtons at
# Opening time (fires for both cases) tells them apart without needing to
# track clicks ourselves.
foreach ($topItem in @($menuFile, $menuSettings)) {
    $topItem.DropDown.Add_Opening({
        param($s, $e)
        if ([System.Windows.Forms.Control]::MouseButtons -eq [System.Windows.Forms.MouseButtons]::None) { $e.Cancel = $true }
    })
}

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
$refreshButton.Size = New-Object System.Drawing.Size(100, 28)

$startAllButton = New-Object System.Windows.Forms.Button
$startAllButton.Text = 'Start All'
$startAllButton.Location = New-Object System.Drawing.Point(16, 48)
$startAllButton.Size = New-Object System.Drawing.Size(100, 28)

$stopAllButton = New-Object System.Windows.Forms.Button
$stopAllButton.Text = 'Stop All'
$stopAllButton.Location = New-Object System.Drawing.Point(128, 48)
$stopAllButton.Size = New-Object System.Drawing.Size(100, 28)

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
# Y=14 top-aligns with the search box (also Y=14, 24px tall) sitting just
# to its left - both read as one row at a glance instead of the dot
# looking vertically offset next to it.
$script:DashboardPill.Location = New-Object System.Drawing.Point(908, 14)
$script:DashboardPill.Anchor = 'Top,Right'

# Busy light for Start/Stop/Restart - stacked directly under the dashboard
# status pill (both Top,Right-anchored so they move together on resize),
# sized to match it (23x23, was a smaller 20x20 that read as mismatched
# next to the pill) instead of the 34x28 toolbar-button size it used
# before the Deploy button took that slot. Y keeps the same 8px gap below
# the pill as before (14 + 23 + 8 = 45), just shifted to match the pill's
# new position/size.
$script:ActionBusyIndicator = New-ActionBusyIndicator
$script:ActionBusyIndicator.Size = New-Object System.Drawing.Size(23, 23)
$script:ActionBusyIndicator.Location = New-Object System.Drawing.Point(908, 45)
$script:ActionBusyIndicator.Anchor = 'Top,Right'
$script:ActionBusyTip = New-Object System.Windows.Forms.ToolTip
$script:ActionBusyTip.InitialDelay = 300
$script:ActionBusyTip.SetToolTip($script:ActionBusyIndicator, 'Working...')

$script:ActionBusyTimer = New-Object System.Windows.Forms.Timer
$script:ActionBusyTimer.Interval = 350
$script:ActionBusyTimer.Add_Tick({
    $t = $script:ActionBusyIndicator.Tag
    $t.Lit = -not $t.Lit
    $script:ActionBusyIndicator.Invalidate()
})

function Start-ActionBusyIndicator {
    if ($script:ActionBusyTimer.Enabled) { return }
    $script:ActionBusyIndicator.Tag.Lit = $true
    $script:ActionBusyIndicator.Visible = $true
    $script:ActionBusyIndicator.Invalidate()
    $script:ActionBusyTimer.Start()
}

function Stop-ActionBusyIndicator {
    $script:ActionBusyTimer.Stop()
    $script:ActionBusyIndicator.Visible = $false
}

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

# Search/filter box - narrows the Live/History/System grids to rows whose
# Custom Name, Process, Port, or Project Path contains the typed text.
# Deliberately NOT applied inside Get-DisplayRows/Get-DisplayRowsSplit
# (see Get-SearchFilteredDisplay) - it only affects what these three
# grids render, never what the web dashboard or the Local Domains proxy
# see. Anchored Top,Left,Right so it stretches with the window instead of
# leaving a growing gap (or, at a narrower width, crowding the dashboard
# status dot) - the right margin captured here at the panel's initial
# 960px width keeps a fixed gap before that dot as the window resizes.
$searchLbl = New-Object System.Windows.Forms.Label
$searchLbl.Text = 'Search:'
$searchLbl.Location = New-Object System.Drawing.Point(525, 16)
$searchLbl.Size = New-Object System.Drawing.Size(55, 22)
$searchLbl.TextAlign = 'MiddleLeft'
$searchLbl.ForeColor = $script:Theme.TextPrimary

$searchBox = New-Object System.Windows.Forms.TextBox
$searchBox.Location = New-Object System.Drawing.Point(582, 14)
$searchBox.Size = New-Object System.Drawing.Size(318, 24)
$searchBox.Anchor = 'Top,Left,Right'
$searchBox.BackColor = $script:Theme.CardBg
$searchBox.ForeColor = $script:Theme.TextPrimary
$searchBox.BorderStyle = 'FixedSingle'
$searchBox.Add_TextChanged({
    $script:SearchFilter = $searchBox.Text.Trim()
    Render-FilteredGrids
})

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
$groupsButton.Text = 'Groups'
$groupsButton.Location = New-Object System.Drawing.Point(128, 12)
$groupsButton.Size = New-Object System.Drawing.Size(100, 28)

# Multi-select "dropdown": a plain Button that pops open a checked-list so
# 2+ groups can be active in the table at once (a normal ComboBox only
# ever lets you pick one).
$groupsPopup = New-Object System.Windows.Forms.ToolStripDropDown
$groupsPopup.AutoClose = $true
$groupsPopup.Padding = New-Object System.Windows.Forms.Padding(2)
Enable-RoundedPopup -Popup $groupsPopup -Radius (Get-ThemedRadius 10)

$groupsCheckedList = New-Object System.Windows.Forms.CheckedListBox
$groupsCheckedList.CheckOnClick = $true
$groupsCheckedList.BorderStyle = 'None'
$groupsCheckedList.IntegralHeight = $false
$groupsCheckedList.Size = New-Object System.Drawing.Size(200, 130)
$groupsCheckedList.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9)
$groupsCheckedList.BackColor = $script:Theme.CardBg
$groupsCheckedList.ForeColor = $script:Theme.TextPrimary

$groupsListHost = New-Object System.Windows.Forms.ToolStripControlHost($groupsCheckedList)
$groupsListHost.AutoSize = $false
$groupsListHost.Size = $groupsCheckedList.Size
$groupsListHost.Margin = New-Object System.Windows.Forms.Padding(0)
$groupsPopup.Items.Add($groupsListHost) | Out-Null

# Column chooser - same "button pops open a checked-list" shape as Groups
# above, for the same reason (more than one thing can be toggled at once).
# Only the informational columns are listed - see Get-DefaultColumnVisibility
# for why Status/Port/Pin/Log/Action aren't offered here.
$columnsButton = New-Object System.Windows.Forms.Button
$columnsButton.Location = New-Object System.Drawing.Point(232, 12)
$columnsButton.Size = New-Object System.Drawing.Size(34, 28)

$columnsPopup = New-Object System.Windows.Forms.ToolStripDropDown
$columnsPopup.AutoClose = $true
$columnsPopup.Padding = New-Object System.Windows.Forms.Padding(2)
Enable-RoundedPopup -Popup $columnsPopup -Radius (Get-ThemedRadius 10)

$script:ColumnToggleList = @(
    @{ Name = 'CustomName';  Label = 'Custom Name' }
    @{ Name = 'Process';     Label = 'Process' }
    @{ Name = 'PID';         Label = 'PID' }
    @{ Name = 'Cpu';         Label = 'CPU' }
    @{ Name = 'Mem';         Label = 'RAM' }
    @{ Name = 'LocalUrl';    Label = 'Local URL' }
    @{ Name = 'LanUrls';     Label = 'Network URL(s)' }
    @{ Name = 'ProjectPath'; Label = 'Project Path' }
)

$columnsCheckedList = New-Object System.Windows.Forms.CheckedListBox
$columnsCheckedList.CheckOnClick = $true
$columnsCheckedList.BorderStyle = 'None'
$columnsCheckedList.IntegralHeight = $false
$columnsCheckedList.Size = New-Object System.Drawing.Size(180, ($script:ColumnToggleList.Count * 20 + 6))
$columnsCheckedList.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9)
$columnsCheckedList.BackColor = $script:Theme.CardBg
$columnsCheckedList.ForeColor = $script:Theme.TextPrimary
foreach ($col in $script:ColumnToggleList) {
    $isChecked = if ($script:Settings.ColumnVisibility.ContainsKey($col.Name)) { [bool]$script:Settings.ColumnVisibility[$col.Name] } else { $true }
    $columnsCheckedList.Items.Add($col.Label, $isChecked) | Out-Null
}

$columnsListHost = New-Object System.Windows.Forms.ToolStripControlHost($columnsCheckedList)
$columnsListHost.AutoSize = $false
$columnsListHost.Size = $columnsCheckedList.Size
$columnsListHost.Margin = New-Object System.Windows.Forms.Padding(0)
$columnsPopup.Items.Add($columnsListHost) | Out-Null

# Build & Deploy - sits directly under the column-chooser button (same
# 34x28 footprint), opening the full Deploy Manager picker
# (Show-DeployManagerDialog, defined further down): every tracked port,
# filterable by group or port range, with Deploy/Configure actions -
# not just the projects that already have a saved recipe.
$deployButton = New-Object System.Windows.Forms.Button
$deployButton.Location = New-Object System.Drawing.Point(232, 48)
$deployButton.Size = New-Object System.Drawing.Size(34, 28)
$deployButton.Add_Click({ Show-DeployManagerDialog })

Initialize-ModernButton -Button $refreshButton
Initialize-ModernButton -Button $groupsButton
Initialize-ModernButton -Button $startAllButton -Variant Success -Icon Play
Initialize-ModernButton -Button $stopAllButton -Variant Danger -Icon Square
# Text must be set before Initialize-ModernButton - it owner-draws from
# Tag.DisplayText, snapshotted from .Text at init time; the icon font
# then has to be applied AFTER, since Initialize-ModernButton
# unconditionally sets .Font to the theme font.
$columnsButton.Text = [string][char]0xE71C
Initialize-ModernButton -Button $columnsButton
$columnsButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 11)
$script:ColumnsButtonTip = New-Object System.Windows.Forms.ToolTip
$script:ColumnsButtonTip.InitialDelay = 300
$script:ColumnsButtonTip.SetToolTip($columnsButton, 'Choose columns')

# Deploy uses a hand-drawn vector icon (Draw-ToolbarIcon), not a font
# glyph like Columns above - no text at all, so Draw-ButtonLayer's
# icon-only path centers it alone.
$deployButton.Text = ''
$deployButton.AccessibleName = 'Build & Deploy'
Initialize-ModernButton -Button $deployButton -Icon 'Deploy'
$script:DeployButtonTip = New-Object System.Windows.Forms.ToolTip
$script:DeployButtonTip.InitialDelay = 300
$script:DeployButtonTip.SetToolTip($deployButton, 'Build & Deploy')

[System.Windows.Forms.Control[]]$topControls = @($refreshButton, $groupsButton, $columnsButton, $deployButton, $startAllButton, $stopAllButton, $script:ActionBusyIndicator, $divider1, $script:DashboardPill, $useGroupsSwitch, $useGroupsLabel, $nodeOnlySwitch, $nodeOnlyLabel, $searchLbl, $searchBox, $topPanelDivider)
$topPanel.Controls.AddRange($topControls)
Connect-ToggleLabel -Switch $nodeOnlySwitch -Label $nodeOnlyLabel
Connect-ToggleLabel -Switch $useGroupsSwitch -Label $useGroupsLabel

function Update-SystemTabState {
    # Grayed out (not hidden) when off, same idiom as Update-GroupsVisibility
    # below - the tab stays visible/discoverable, its content just goes
    # inert and swaps in an explanatory placeholder instead of an empty grid.
    $show = [bool]$script:Settings.ShowSystemPorts
    Set-CustomTabEnabled -TabSet $script:MainTabs -Index 2 -Enabled $show
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
    # Button label stays a static "Groups" to match the other toolbar
    # buttons; the selection detail moves to a hover tooltip instead.
    $count = $script:SelectedGroups.Count
    $detail = if ($count -eq 0) { 'None selected' } elseif ($count -eq 1) { "Selected: $($script:SelectedGroups[0])" } else { "Selected: $count groups" }
    $script:DashboardTip.SetToolTip($groupsButton, $detail)
}

function Sync-GroupsCheckedList {
    $groupsCheckedList.Items.Clear()
    foreach ($name in ($script:Groups.Keys | Sort-Object)) {
        $isChecked = $script:SelectedGroups -contains $name
        $groupsCheckedList.Items.Add($name, $isChecked) | Out-Null
    }
    # Size was a fixed 130px tall regardless of item count - fine for ~7
    # groups, but left a large empty band below the last item (and before
    # the rounded border) for anyone with only 1-3 groups defined. Size to
    # fit the actual items instead, still capped at the original 130px so a
    # long list keeps scrolling rather than growing unbounded.
    $maxHeight = 130
    $minHeight = $groupsCheckedList.ItemHeight + 4
    $contentHeight = ($groupsCheckedList.Items.Count * $groupsCheckedList.ItemHeight) + 4
    $newHeight = [Math]::Max($minHeight, [Math]::Min($maxHeight, $contentHeight))
    $groupsCheckedList.Size = New-Object System.Drawing.Size(200, $newHeight)
    $groupsListHost.Size = $groupsCheckedList.Size
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

$columnsCheckedList.Add_ItemCheck({
    param($s, $e)
    # Items were added in the same order as $script:ColumnToggleList, so
    # the event's item index maps straight back to it - no name lookup
    # through the (visible, translated) label text needed.
    $colName = $script:ColumnToggleList[$e.Index].Name
    $isChecked = ($e.NewValue -eq [System.Windows.Forms.CheckState]::Checked)
    $script:Settings.ColumnVisibility[$colName] = $isChecked
    Save-Settings $script:Settings
    Update-ColumnVisibility
})

$columnsButton.Add_Click({
    $columnsPopup.Show($columnsButton, (New-Object System.Drawing.Point(0, $columnsButton.Height)))
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
$script:ColIdx = @{ Status = 0; Port = 1; Pin = 2; CustomName = 3; Process = 4; PID = 5; Cpu = 6; Mem = 7; LocalUrl = 8; LanUrls = 9; ProjectPath = 10; Log = 11; Action = 12 }
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
    $g.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9)
    $g.EnableHeadersVisualStyles = $false
    $g.ColumnHeadersDefaultCellStyle.BackColor = $script:Theme.PanelBg
    $g.ColumnHeadersDefaultCellStyle.ForeColor = $script:Theme.TextPrimary
    $g.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9, [System.Drawing.FontStyle]::Bold)
    $g.ColumnHeadersDefaultCellStyle.Alignment = 'MiddleLeft'
    $g.ColumnHeadersBorderStyle = 'None'
    $g.ColumnHeadersHeightSizeMode = 'DisableResizing'
    $g.ColumnHeadersHeight = 34
    $g.RowTemplate.Height = 32
    $g.DefaultCellStyle.BackColor = $script:Theme.CardBg
    $g.DefaultCellStyle.ForeColor = $script:Theme.TextPrimary
    $g.DefaultCellStyle.SelectionBackColor = $script:Theme.AccentTint
    $g.DefaultCellStyle.SelectionForeColor = $script:Theme.TextPrimary
    $g.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(4, 0, 4, 0)
    $g.AlternatingRowsDefaultCellStyle.BackColor = $script:Theme.RowAlt
    $g.AlternatingRowsDefaultCellStyle.SelectionBackColor = $script:Theme.AccentTint

    $colStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colStatus.Name = 'Status'; $colStatus.HeaderText = 'Status'; $colStatus.FillWeight = 40; $colStatus.MinimumWidth = 58; $colStatus.ReadOnly = $true

    $colPort = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colPort.Name = 'Port'; $colPort.HeaderText = 'Port'; $colPort.FillWeight = 45; $colPort.MinimumWidth = 44; $colPort.ReadOnly = $true

    # Icon-only toggle, colored per row (see Add-DataRow) rather than swapped
    # between a "pin"/"unpin" glyph pair, so clicking it can't cause a
    # visible layout jump. Plain text cell rather than a DataGridViewButton
    # column - the native button chrome paints its own light face regardless
    # of cell BackColor, which reads fine blended into a white grid but shows
    # up as a stray light-gray box in dark mode.
    $colPin = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colPin.Name = 'Pin'; $colPin.HeaderText = ''; $colPin.FillWeight = 34; $colPin.MinimumWidth = 32
    $colPin.ReadOnly = $true
    $colPin.DefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 9.5)
    $colPin.DefaultCellStyle.Alignment = 'MiddleCenter'
    $colPin.DefaultCellStyle.SelectionBackColor = $script:Theme.PanelBg

    $colCustomName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colCustomName.Name = 'CustomName'; $colCustomName.HeaderText = 'Custom Name'; $colCustomName.FillWeight = 105; $colCustomName.MinimumWidth = 104; $colCustomName.ReadOnly = $false

    $colProc = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colProc.Name = 'Process'; $colProc.HeaderText = 'Process'; $colProc.FillWeight = 62; $colProc.MinimumWidth = 60; $colProc.ReadOnly = $true

    $colPid = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colPid.Name = 'PID'; $colPid.HeaderText = 'PID'; $colPid.FillWeight = 50; $colPid.MinimumWidth = 46; $colPid.ReadOnly = $true

    $colCpu = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colCpu.Name = 'Cpu'; $colCpu.HeaderText = 'CPU'; $colCpu.FillWeight = 48; $colCpu.MinimumWidth = 46; $colCpu.ReadOnly = $true
    $colCpu.DefaultCellStyle.Alignment = 'MiddleRight'

    $colMem = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colMem.Name = 'Mem'; $colMem.HeaderText = 'RAM'; $colMem.FillWeight = 55; $colMem.MinimumWidth = 52; $colMem.ReadOnly = $true
    $colMem.DefaultCellStyle.Alignment = 'MiddleRight'

    $colLocal = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colLocal.Name = 'LocalUrl'; $colLocal.HeaderText = 'Local URL'; $colLocal.FillWeight = 110; $colLocal.MinimumWidth = 60; $colLocal.ReadOnly = $true

    $colLan = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colLan.Name = 'LanUrls'; $colLan.HeaderText = 'Network URL(s)'; $colLan.FillWeight = 170; $colLan.MinimumWidth = 60; $colLan.ReadOnly = $true

    $colPath = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colPath.Name = 'ProjectPath'; $colPath.HeaderText = 'Project Path'; $colPath.FillWeight = 162; $colPath.MinimumWidth = 60; $colPath.ReadOnly = $true

    # Restart and Stop/Start are click targets, not information to
    # rebalance - unlike the informational columns, they stay a fixed
    # size (AutoSizeMode 'None' opts them out of the grid's Fill
    # redistribution entirely) and un-resizable, so they never grow,
    # shrink, or drift as other columns are resized or the window is.
    # Kept pinned to the last two DisplayIndex slots too (see
    # Save-ColumnLayout/Update-ColumnLayout) - WinForms has no per-column
    # "don't let this be reordered" flag, so that's enforced by snapping
    # them back after the fact rather than blocking the drag itself.
    #
    # Width is measured against the theme's actual font rather than a
    # hardcoded guess - Light/Dark use Segoe UI, Terminal uses the wider
    # monospace Cascadia Mono, and a width tuned for one clipped "Restart"
    # to "Res..." under the other. TextRenderer (not Graphics.MeasureString)
    # to match how the cell's own text is actually rendered.
    $actionMeasureFont = New-Object System.Drawing.Font($script:Theme.FontFamily, 9)
    $restartTextWidth = [System.Windows.Forms.TextRenderer]::MeasureText('Restart', $actionMeasureFont).Width
    $startTextWidth = [System.Windows.Forms.TextRenderer]::MeasureText('Start', $actionMeasureFont).Width
    $actionMeasureFont.Dispose()

    $colLog = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colLog.Name = 'Log'; $colLog.HeaderText = ''; $colLog.Width = $restartTextWidth + 22; $colLog.MinimumWidth = $restartTextWidth + 22
    $colLog.AutoSizeMode = 'None'
    $colLog.Resizable = 'False'
    $colLog.ReadOnly = $true
    $colLog.DefaultCellStyle.Alignment = 'MiddleCenter'
    # Success (matches "ON" status and the Start All button), not TextDim -
    # this is a live, clickable action, not a muted secondary label.
    $colLog.DefaultCellStyle.ForeColor = $script:Theme.Success
    $colLog.DefaultCellStyle.SelectionForeColor = $script:Theme.Success
    $colLog.DefaultCellStyle.SelectionBackColor = $script:Theme.PanelBg

    $colAction = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colAction.Name = 'Action'; $colAction.HeaderText = ''; $colAction.Width = $startTextWidth + 22; $colAction.MinimumWidth = $startTextWidth + 22
    $colAction.AutoSizeMode = 'None'
    $colAction.Resizable = 'False'
    $colAction.ReadOnly = $true
    $colAction.DefaultCellStyle.Alignment = 'MiddleCenter'

    [System.Windows.Forms.DataGridViewColumn[]]$gridColumns = @($colStatus, $colPort, $colPin, $colCustomName, $colProc, $colPid, $colCpu, $colMem, $colLocal, $colLan, $colPath, $colLog, $colAction)
    $g.Columns.AddRange($gridColumns)
    # Fill (not None/fixed-width): a v1.14.0 attempt at "every column
    # freely resizable" switched this to fixed widths, on the mistaken
    # assumption that Fill mode itself blocked manual resize - it
    # doesn't (WinForms redistributes FillWeight among Fill-mode columns
    # as you drag a border, which is real interactive resize; only the
    # content-based AutoSizeMode Status briefly had actually disabled
    # it). Fixed widths let the columns' TOTAL width exceed the grid's
    # own width once the user (or the window) got narrower than that
    # total, which is what caused both new bugs that fix introduced: a
    # horizontal scrollbar WinForms can't theme (always white/native,
    # regardless of app theme), and the hand-drawn group-divider line
    # (see Draw-GroupDividerRow) being positioned against row bounds
    # that no longer matched the visible/scrolled area. Fill mode
    # guarantees columns always exactly fill the grid's width, so
    # neither problem can occur - and resize still works.
    # AllowUserToOrderColumns adds drag-to-reposition on top; both
    # survive restart via FillWeight/DisplayIndex - see
    # Update-ColumnLayout/Save-ColumnLayout.
    $g.AutoSizeColumnsMode = 'Fill'
    $g.AllowUserToResizeColumns = $true
    $g.AllowUserToOrderColumns = $true
    $dgvDoubleBufferProp.SetValue($g, $true, $null)
    $g.Dock = 'Fill'
    Set-DarkScrollBars -Control $g
    $g.Add_Resize({ param($s, $e) Set-DarkScrollBars -Control $s })

    # Column-resize handles in the header are invisible by default here
    # (ColumnHeadersBorderStyle is 'None', same reason as CellBorderStyle
    # below - the native border styles have a history of rendering
    # glitches under this app's Windows 11 visual style/theme, e.g. the
    # leaked vertical lines CellBorderStyle used to produce). Hand-drawn
    # dividers instead, and only while the mouse is actually over the
    # header bar, so the normal borderless look is undisturbed the rest
    # of the time. $g.Tag (unused otherwise - row-level Tag is a
    # different object, see Add-DataRow/Add-SeparatorRow) tracks hover
    # state; CellPainting below does the actual drawing.
    $g.Tag = [PSCustomObject]@{ HeaderHovered = $false }
    $g.Add_MouseMove({
        param($s, $e)
        $overHeader = $e.Y -ge 0 -and $e.Y -lt $s.ColumnHeadersHeight
        if ($overHeader -ne $s.Tag.HeaderHovered) {
            $s.Tag.HeaderHovered = $overHeader
            $s.Invalidate((New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.ColumnHeadersHeight)))
        }
    })
    $g.Add_MouseLeave({
        param($s, $e)
        if ($s.Tag.HeaderHovered) {
            $s.Tag.HeaderHovered = $false
            $s.Invalidate((New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.ColumnHeadersHeight)))
        }
    })
    $g.Add_CellPainting({
        param($s, $e)
        if ($e.RowIndex -ne -1 -or $e.ColumnIndex -lt 0 -or -not $s.Tag.HeaderHovered) { return }
        $e.Paint($e.ClipBounds, $e.PaintParts)
        $pen = New-Object System.Drawing.Pen($script:Theme.Border, 1)
        $x = $e.CellBounds.Right - 1
        $e.Graphics.DrawLine($pen, $x, ($e.CellBounds.Top + 6), $x, ($e.CellBounds.Bottom - 6))
        $pen.Dispose()
        $e.Handled = $true
    })

    # Replaces the native CellBorderStyle border this column used to draw
    # (removed above) — a single flat line under each real row, no verticals.
    $g.Add_RowPostPaint({
        param($s, $e)
        $row = $s.Rows[$e.RowIndex]
        if ($row.Tag -eq 'separator') {
            Draw-GroupDividerRow -Graphics $e.Graphics -RowBounds $e.RowBounds -GroupName $row.HeaderCell.Value
            return
        }
        $borderColor = $script:Theme.Border
        if ($null -eq $borderColor) { return }
        $y = $e.RowBounds.Bottom - 1
        $pen = New-Object System.Drawing.Pen($borderColor, 1)
        $e.Graphics.DrawLine($pen, $e.RowBounds.Left, $y, $e.RowBounds.Right, $y)
        $pen.Dispose()
    })

    # Separator rows are visual dividers only - keyboard/mouse navigation
    # should skip over them like they aren't there, instead of letting them
    # become the current cell (which otherwise draws a stray default focus
    # box on top of an all-but-empty row).
    $g.Add_CellEnter({
        param($s, $e)
        if ($e.RowIndex -lt 0 -or $e.RowIndex -ge $s.Rows.Count) { return }
        $row = $s.Rows[$e.RowIndex]
        if ($row.Tag -ne 'separator') { return }
        $dir = if ($e.RowIndex + 1 -lt $s.Rows.Count) { 1 } else { -1 }
        $targetIndex = $e.RowIndex + $dir
        if ($targetIndex -ge 0 -and $targetIndex -lt $s.Rows.Count) {
            # Setting .CurrentCell synchronously here re-enters
            # SetCurrentCellAddressCore - the very call still on the stack
            # dispatching this CellEnter - and throws "Operation is not
            # valid because it results in a reentrant call to the
            # SetCurrentCellAddressCore function." Deferred via
            # BeginInvoke so it runs after the click that landed on this
            # separator row has fully finished, not nested inside it.
            $col = $e.ColumnIndex
            $s.BeginInvoke([Action]{
                # Re-check bounds - by the time this runs the grid may
                # have re-rendered (rows cleared/rebuilt) out from under
                # the row/column indices captured above.
                if ($s.IsDisposed -or $targetIndex -ge $s.Rows.Count -or $col -ge $s.ColumnCount) { return }
                $s.CurrentCell = $s.Rows[$targetIndex].Cells[$col]
            }.GetNewClosure()) | Out-Null
        }
    })

    # ColumnWidthChanged/ColumnDisplayIndexChanged fire for far more than
    # an actual user drag - resizing the whole app window recalculates
    # every Fill-mode column's pixel width against the new available
    # space (the proportion/FillWeight is unchanged, but .Width still
    # fires the event), and adding a Fill-mode grid to its parent for the
    # first time does the same as its very first layout pass. Schedule-
    # ColumnLayoutSave (defined below, after all three grids exist -
    # fine, since this scriptblock only actually runs later, whenever the
    # event fires) doesn't act on these directly; it just notes which
    # grid changed and (re)starts a short one-shot timer. That both
    # collapses a whole drag gesture's worth of events into a single
    # save, and - the reason this has to be deferred at all, not just an
    # efficiency nicety - avoids writing to .FillWeight while WinForms is
    # still mid-resize itself, which throws "This operation cannot be
    # performed while an auto-filled column is being resized." Actually
    # persisting/propagating that layout happens later, on the timer
    # tick, once whatever triggered the event has fully settled.
    $g.Add_ColumnWidthChanged({ param($s, $e) Schedule-ColumnLayoutSave -SourceGrid $s })
    $g.Add_ColumnDisplayIndexChanged({ param($s, $e) Schedule-ColumnLayoutSave -SourceGrid $s })

    return $g
}

# See the long comment on Add_ColumnWidthChanged above for why this has to
# be set before the very first grid is created, not just around the
# explicit Update-ColumnLayout calls below.
$script:SyncingColumnLayout = $true

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

function Update-ColumnVisibility {
    # Applies the Columns popup's checked state to all three grids at
    # once - they share the same column set (see New-PortsGrid), so a
    # toggle should never look different depending on which tab you're on.
    foreach ($col in $script:ColumnToggleList) {
        $visible = if ($script:Settings.ColumnVisibility.ContainsKey($col.Name)) { [bool]$script:Settings.ColumnVisibility[$col.Name] } else { $true }
        foreach ($grid in @($liveGrid, $historyGrid, $systemGrid)) {
            if ($grid.Columns[$col.Name]) { $grid.Columns[$col.Name].Visible = $visible }
        }
    }
}
Update-ColumnVisibility

function Update-ColumnLayout {
    # Applies saved fill-weights + display order to all three grids at
    # once - same "every tab stays visually identical" rationale as
    # Update-ColumnVisibility above. Guarded by SyncingColumnLayout so
    # setting .FillWeight/.DisplayIndex here doesn't re-trigger
    # Save-ColumnLayout via the ColumnWidthChanged/ColumnDisplayIndexChanged
    # handlers wired in New-PortsGrid. Saves and restores the PREVIOUS
    # guard value rather than hardcoding it back to $false - during
    # startup this gets called while the outer, whole-startup guard (see
    # $script:SyncingColumnLayout = $true above, before the first grid
    # exists) is already $true, and hardcoding $false here would end that
    # protection early, right as the very first call returns.
    $wasSyncingColumnLayout = $script:SyncingColumnLayout
    $script:SyncingColumnLayout = $true
    try {
        foreach ($grid in @($liveGrid, $historyGrid, $systemGrid)) {
            foreach ($colName in @($script:Settings.ColumnFillWeights.Keys)) {
                $col = $grid.Columns[$colName]
                if ($col) { $col.FillWeight = [Math]::Max(1, [int]$script:Settings.ColumnFillWeights[$colName]) }
            }
            for ($i = 0; $i -lt $script:Settings.ColumnOrder.Count; $i++) {
                $col = $grid.Columns[$script:Settings.ColumnOrder[$i]]
                if ($col) { $col.DisplayIndex = $i }
            }
        }
    } finally {
        $script:SyncingColumnLayout = $wasSyncingColumnLayout
    }
}

function Save-ColumnLayout {
    # The real work, run only from the debounce timer below (see
    # Schedule-ColumnLayoutSave) - never called directly from a
    # ColumnWidthChanged/ColumnDisplayIndexChanged handler itself, since
    # by the time this runs, whatever triggered those events (a column
    # drag, a window resize, initial layout) has fully settled. Captures
    # the source grid's current state, persists it, and mirrors it onto
    # the other two so every tab keeps matching - same idea as the
    # Columns popup's ItemCheck handler (see
    # $columnsCheckedList.Add_ItemCheck), just triggered by the grid
    # itself instead of a popup.
    param($SourceGrid)
    if ($script:SyncingColumnLayout) { return }
    $weights = @{}
    $order = New-Object System.Collections.Generic.List[string]
    foreach ($col in ($SourceGrid.Columns | Sort-Object DisplayIndex)) {
        # Log/Action (Restart/Stop) are fixed-width, non-Fill columns
        # (see New-PortsGrid) - .FillWeight on them is meaningless, and
        # their DisplayIndex gets forced back to last anyway.
        if ($col.Name -in @('Log', 'Action')) { continue }
        $weights[$col.Name] = $col.FillWeight
        $order.Add($col.Name)
    }
    $script:Settings.ColumnFillWeights = $weights
    $script:Settings.ColumnOrder = Get-NormalizedColumnOrder @($order)
    Save-Settings $script:Settings
    Update-ColumnLayout
}

# One-shot debounce: ColumnWidthChanged/ColumnDisplayIndexChanged can
# fire many times in a row for a single user gesture (dragging one
# column shifts every column between its old and new position, each
# with its own event) or for reasons that have nothing to do with the
# user at all (see the long comment on Add_ColumnWidthChanged in
# New-PortsGrid). Restarting this timer on every firing and only acting
# once it goes quiet for 400ms collapses all of that into a single
# Save-ColumnLayout call, made safely after WinForms has finished
# whatever resize/layout operation triggered the event in the first
# place - calling Save-ColumnLayout (which writes .FillWeight) directly
# from inside the event handler intermittently threw "This operation
# cannot be performed while an auto-filled column is being resized."
$script:PendingColumnLayoutGrid = $null
$script:ColumnLayoutSaveTimer = New-Object System.Windows.Forms.Timer
$script:ColumnLayoutSaveTimer.Interval = 400
$script:ColumnLayoutSaveTimer.Add_Tick({
    $script:ColumnLayoutSaveTimer.Stop()
    if ($script:PendingColumnLayoutGrid -and -not $script:SyncingColumnLayout) {
        Save-ColumnLayout -SourceGrid $script:PendingColumnLayoutGrid
    }
    $script:PendingColumnLayoutGrid = $null
})

function Schedule-ColumnLayoutSave {
    param($SourceGrid)
    if ($script:SyncingColumnLayout) { return }
    $script:PendingColumnLayoutGrid = $SourceGrid
    $script:ColumnLayoutSaveTimer.Stop()
    $script:ColumnLayoutSaveTimer.Start()
}

# Called only now that Update-ColumnLayout, Save-ColumnLayout, and
# Schedule-ColumnLayoutSave all exist - setting .DisplayIndex inside
# Update-ColumnLayout fires ColumnDisplayIndexChanged synchronously
# (unlike a button click, this runs as part of the script's own
# top-to-bottom setup, not deferred until after everything has loaded),
# and that handler calls Schedule-ColumnLayoutSave. Calling this before
# that chain's functions had all been reached yet threw "... is not
# recognized". (In practice $script:SyncingColumnLayout, already $true
# here, makes this a non-issue regardless of definition order - but the
# order is kept safe anyway, in case that guard is ever removed.)
Update-ColumnLayout

$script:MainTabs = New-CustomTabControl -Labels @('Live', 'History', 'System')
$script:MainTabs.Root.Anchor = 'Top,Bottom,Left,Right'

$script:MainTabs.Pages[0].Controls.Add($liveGrid)
$script:MainTabs.Pages[1].Controls.Add($historyGrid)

$systemPlaceholderLabel = New-Object System.Windows.Forms.Label
$systemPlaceholderLabel.Text = "System-owned ports are hidden.`r`nEnable `"Show system-owned ports`" in Settings > Preferences to view them here."
$systemPlaceholderLabel.Dock = 'Fill'
$systemPlaceholderLabel.TextAlign = 'MiddleCenter'
$systemPlaceholderLabel.ForeColor = $script:Theme.TextDim
$systemPlaceholderLabel.BackColor = $script:Theme.CardBg
$systemPlaceholderLabel.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9.5)

$script:MainTabs.Pages[2].Controls.Add($systemGrid)
$script:MainTabs.Pages[2].Controls.Add($systemPlaceholderLabel)

$gridTop = $menuStrip.Height + $topPanel.Height
$script:MainTabs.Root.Location = New-Object System.Drawing.Point(0, $gridTop)
$script:MainTabs.Root.Size = New-Object System.Drawing.Size($form.ClientSize.Width, ($form.ClientSize.Height - $gridTop - $script:BottomBar.Height))

# Fill/content control added first, then Dock='Top'/'Bottom' controls in
# reverse visual order (later-added = higher z-order = closer to its dock
# edge) — the standard WinForms pattern for MenuStrip + toolbar + content.
$form.Controls.Add($script:MainTabs.Root)
$form.Controls.Add($script:BottomBar)
$form.Controls.Add($topPanel)
$form.Controls.Add($menuStrip)
Update-GroupsVisibility
Update-SystemTabState

function Add-DataRow {
    param($Grid, $r)
    # $null (not 0/blank-zero) means "not measured yet" (first poll tick
    # after a process appears, or a stopped/history row with nothing
    # running) - shown as a blank cell rather than a misleading "0%"/"0 MB".
    $cpuText = if ($null -ne $r.Cpu) { "$($r.Cpu)%" } else { '' }
    $memText = if ($null -ne $r.Mem) { "$($r.Mem) MB" } else { '' }
    $idx = $Grid.Rows.Add($r.Status, $r.Port, ([string][char]0xE718), $r.CustomName, $r.ProcessName, $r.ProcId, $cpuText, $memText, $r.LocalUrl, $r.LanUrls, $r.ProjectPath, 'Restart', $r.Action)
    $row = $Grid.Rows[$idx]
    $row.Tag = $r
    switch ($r.Status) {
        'ON'      {
            # Responding is $false only once a health-check probe has
            # actually timed out (see the background poller) - $null means
            # "not probed" (health check off, or not an npm/node project),
            # which reads the same as a normal healthy ON row rather than
            # a false alarm.
            if ($r.Responding -eq $false) {
                $row.Cells['Status'].Style.ForeColor = $script:Theme.Warning
                $row.Cells['Status'].ToolTipText = 'Listening, but not responding to HTTP requests - may be hung, or still starting up.'
            } else {
                $row.Cells['Status'].Style.ForeColor = $script:Theme.Success
            }
        }
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

function Draw-GroupDividerRow {
    # Renders the rule that breaks the grid between groups. Reads the style
    # live from Settings > Appearance (Hairline/Dotted/Labeled) so switching
    # it just needs a Refresh-Grid, no restart. All three keep the same 8px
    # inset from the row edges the old accent bar used, just with a much
    # quieter muted-border color instead of a 2px accent-colored bar - the
    # original read as an alert/warning stripe rather than a section break.
    param($Graphics, [System.Drawing.Rectangle]$RowBounds, [string]$GroupName)
    $lineColor = $script:Theme.Border
    if ($null -eq $lineColor) { return }
    $y = $RowBounds.Top + [Math]::Floor($RowBounds.Height / 2.0)
    $left = $RowBounds.Left + 8
    $right = $RowBounds.Right - 8

    switch ($script:Settings.GroupDividerStyle) {
        'Dotted' {
            $pen = New-Object System.Drawing.Pen($lineColor, 1)
            $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dot
            $Graphics.DrawLine($pen, $left, $y, $right, $y)
            $pen.Dispose()
        }
        'Labeled' {
            $text = if ($GroupName) { $GroupName.ToUpperInvariant() } else { '' }
            $pen = New-Object System.Drawing.Pen($lineColor, 1)
            if ($text) {
                $font = New-Object System.Drawing.Font($script:Theme.FontFamily, 7.5, [System.Drawing.FontStyle]::Bold)
                $sf = [System.Drawing.StringFormat]::GenericTypographic
                $textSize = $Graphics.MeasureString($text, $font, [System.Drawing.PointF]::Empty, $sf)
                $pad = 10
                $textLeft = $RowBounds.Left + ($RowBounds.Width - $textSize.Width) / 2.0
                $Graphics.DrawLine($pen, $left, $y, ($textLeft - $pad), $y)
                $Graphics.DrawLine($pen, ($textLeft + $textSize.Width + $pad), $y, $right, $y)
                $brush = New-Object System.Drawing.SolidBrush($script:Theme.TextDim)
                $Graphics.DrawString($text, $font, $brush, $textLeft, ($y - $textSize.Height / 2.0), $sf)
                $brush.Dispose()
                $font.Dispose()
            } else {
                $Graphics.DrawLine($pen, $left, $y, $right, $y)
            }
            $pen.Dispose()
        }
        default {
            # Hairline
            $pen = New-Object System.Drawing.Pen($lineColor, 1)
            $Graphics.DrawLine($pen, $left, $y, $right, $y)
            $pen.Dispose()
        }
    }
}

function Add-SeparatorRow {
    # -GroupName is only consumed by the 'Labeled' divider style (Settings >
    # Appearance) - stashed on the row header cell since RowHeadersVisible is
    # false, so it never renders on its own and doesn't disturb row.Tag
    # (still the 'separator' sentinel every click/double-click/right-click
    # handler already checks for).
    param($Grid, [string]$GroupName = '')
    $idx = $Grid.Rows.Add('', '', '', '', '', '', '', '', '', '', '', '', '')
    $row = $Grid.Rows[$idx]
    $row.Tag = 'separator'
    $row.HeaderCell.Value = $GroupName
    # Labeled needs room for a centered caption; the plain rules stay thin.
    $row.Height = if ($script:Settings.GroupDividerStyle -eq 'Labeled') { 20 } else { 10 }
    $row.ReadOnly = $true
    $row.DefaultCellStyle.BackColor = $script:Theme.PanelBg
    $row.DefaultCellStyle.SelectionBackColor = $script:Theme.PanelBg
    foreach ($colName in @('Pin', 'Log', 'Action')) {
        $row.Cells[$colName] = New-Object System.Windows.Forms.DataGridViewTextBoxCell
    }
}

function Get-ProxySlug {
    # DNS-label-safe hostname piece for the reverse proxy: lowercase,
    # non-alphanumeric runs collapsed to a single hyphen, trimmed. Empty
    # input (a name that's all symbols, or none at all) falls back to the
    # port itself so every running project still gets a usable address.
    param([string]$Label, [string]$Port)
    $slug = ([string]$Label).ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $slug = $slug.Trim('-')
    if (-not $slug) { $slug = "port-$Port" }
    return $slug
}

function Get-ProxyUrlForPort {
    # Reverse lookup (Port -> slug) for the Detail popup - the RouteMap
    # itself is keyed by slug since that's what the listener needs to
    # route incoming requests, but the grid only ever knows a row's port.
    param([string]$Port)
    if (-not $script:Settings.ProxyEnabled -or -not $script:ProxyCache.Listening -or -not $Port) { return $null }
    foreach ($slug in $script:ProxyCache.RouteMap.Keys) {
        if ([string]$script:ProxyCache.RouteMap[$slug].Port -eq [string]$Port) {
            return "http://$slug.localhost:$($script:ProxyCache.Port)/"
        }
    }
    return $null
}

function Update-ProxyRouteMap {
    # Rebuilt every refresh cycle (see Get-DisplayRowsSplit) from whatever
    # is currently ON - same cadence/lifetime as Publish-DashboardRows, and
    # for the same reason: cheap, and "a few seconds stale" is fine for a
    # route table nobody but this machine's browser ever reads.
    param($Display)
    if (-not $script:ProxyCache) { return }
    $routes = @{}
    $used = @{}
    foreach ($entry in $Display) {
        $row = $entry.Row
        if ($row.Status -ne 'ON' -or -not $row.Port) { continue }
        $label = if ($row.CustomName) { [string]$row.CustomName } elseif ($row.ProjectPath) { Split-Path -Leaf $row.ProjectPath } else { '' }
        $slug = Get-ProxySlug -Label $label -Port $row.Port
        # Two different projects can sanitize to the same slug (e.g. two
        # custom names that only differ in punctuation) - the port makes
        # the second one collision-free instead of silently shadowing the
        # first.
        if ($used.ContainsKey($slug)) { $slug = "$slug-$($row.Port)" }
        $used[$slug] = $true
        $routes[$slug] = @{ Port = [int]$row.Port; Label = $(if ($label) { $label } else { "port $($row.Port)" }); ProjectPath = [string]$row.ProjectPath }
    }
    $script:ProxyCache.RouteMap = $routes
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
    Update-ProxyRouteMap -Display $display
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
        "$($_.Group)|$($_.Row.Status)|$($_.Row.Port)|$($_.Row.ProcId)|$($_.Row.CustomName)|$($_.Row.ProjectPath)|$($_.Row.Action)|$([bool]$_.Row.HasLog)|$([bool]$_.Row.Pinned)|$($_.Row.Cpu)|$($_.Row.Mem)|$($_.Row.Responding)"
    }) -join "`n"
}

function Get-SearchFilteredDisplay {
    # Narrows an already-built display list (Group-tagged rows, the same
    # shape Get-DisplayRows returns) down to rows matching the search box's
    # current text. Deliberately applied only here - right before
    # rendering - never inside Get-DisplayRows/Get-DisplayRowsSplit
    # themselves, since that same result also feeds the web dashboard and
    # the Local Domains proxy route map. A local search narrowing what you
    # see in this window shouldn't stop a project's *.localhost address
    # from working, or hide it from someone checking the dashboard on
    # their phone.
    param($Display)
    $term = $script:SearchFilter
    if (-not $term) { return $Display }
    return @($Display | Where-Object {
        $r = $_.Row
        "$($r.CustomName) $($r.ProcessName) $($r.Port) $($r.ProjectPath)" -like "*$term*"
    })
}

function Render-Grid {
    param($Grid, $Display)
    $Grid.SuspendLayout()
    try {
        $Grid.Rows.Clear()
        $lastGroup = $null
        foreach ($d in $Display) {
            if ($null -ne $d.Group -and $null -ne $lastGroup -and $d.Group -ne $lastGroup) { Add-SeparatorRow -Grid $Grid -GroupName $d.Group }
            Add-DataRow -Grid $Grid -r $d.Row
            $lastGroup = $d.Group
        }
        $Grid.ClearSelection()
    } finally {
        $Grid.ResumeLayout()
    }
    # A row-count/content change can introduce or remove a scrollbar just
    # like a resize can - see Set-DarkScrollBars for why this has to be
    # re-run rather than done once.
    Set-DarkScrollBars -Control $Grid
}

function Update-TabHeaders {
    param([int]$LiveCount, [int]$HistoryCount, [int]$SystemCount)
    Set-CustomTabText -TabSet $script:MainTabs -Index 0 -Text "Live ($LiveCount)"
    Set-CustomTabText -TabSet $script:MainTabs -Index 1 -Text "History ($HistoryCount)"
    $systemText = if ([bool]$script:Settings.ShowSystemPorts) { "System ($SystemCount)" } else { 'System' }
    Set-CustomTabText -TabSet $script:MainTabs -Index 2 -Text $systemText
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

function Render-FilteredGrids {
    # Re-renders all three grids from the last-built display data (no live
    # rescan, no history.json write) - shared by Refresh-Grid below and by
    # the search box's TextChanged handler, so typing in the search box
    # doesn't trigger a fresh scan/disk write on every keystroke.
    if (-not $script:LastDisplaySplit) { return }
    $split = $script:LastDisplaySplit
    # @(...) wrapping the call (not just the return inside
    # Get-SearchFilteredDisplay itself) matters here - PowerShell unrolls
    # a single-item array back to a bare scalar as it crosses a function
    # return boundary, and collapses a zero-item one to $null. Without
    # forcing array context at the call site too, an exactly-one-match (or
    # zero-match) search left $liveFiltered.Count silently returning $null
    # instead of 1 or 0, and the tab header briefly read "Live ()".
    $liveFiltered = @(Get-SearchFilteredDisplay -Display $split.Live)
    $historyFiltered = @(Get-SearchFilteredDisplay -Display $split.History)
    $systemFiltered = @(Get-SearchFilteredDisplay -Display $split.System)
    Render-Grid -Grid $liveGrid -Display $liveFiltered
    Render-Grid -Grid $historyGrid -Display $historyFiltered
    Render-Grid -Grid $systemGrid -Display $systemFiltered
    Update-TabHeaders -LiveCount $liveFiltered.Count -HistoryCount $historyFiltered.Count -SystemCount $systemFiltered.Count
}

function Refresh-Grid {
    # Full, forced rebuild — used for direct user actions (Refresh button,
    # toggles, settings/group changes, start/stop) where the grid content
    # is expected to change right away.
    if ($liveGrid.IsCurrentCellInEditMode -or $historyGrid.IsCurrentCellInEditMode -or $systemGrid.IsCurrentCellInEditMode) { return }
    $split = Get-DisplayRowsSplit
    $script:LastDisplaySplit = $split
    Render-FilteredGrids
    $script:LastLiveSignature = Get-DisplayRowsSignature $split.Live
    $script:LastHistorySignature = Get-DisplayRowsSignature $split.History
    $script:LastSystemSignature = Get-DisplayRowsSignature $split.System
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
    $script:LastDisplaySplit = $split
    $liveSig = Get-DisplayRowsSignature $split.Live
    $historySig = Get-DisplayRowsSignature $split.History
    $systemSig = Get-DisplayRowsSignature $split.System
    if ($liveSig -ne $script:LastLiveSignature) {
        Render-Grid -Grid $liveGrid -Display @(Get-SearchFilteredDisplay -Display $split.Live)
        $script:LastLiveSignature = $liveSig
    }
    if ($historySig -ne $script:LastHistorySignature) {
        Render-Grid -Grid $historyGrid -Display @(Get-SearchFilteredDisplay -Display $split.History)
        $script:LastHistorySignature = $historySig
    }
    if ($systemSig -ne $script:LastSystemSignature) {
        Render-Grid -Grid $systemGrid -Display @(Get-SearchFilteredDisplay -Display $split.System)
        $script:LastSystemSignature = $systemSig
    }
    Update-TabHeaders -LiveCount @(Get-SearchFilteredDisplay -Display $split.Live).Count -HistoryCount @(Get-SearchFilteredDisplay -Display $split.History).Count -SystemCount @(Get-SearchFilteredDisplay -Display $split.System).Count
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

function Test-HasShellChainingChars {
    # Guards every place a string that didn't come from this app's own
    # fixed choices (npm run <script>, a hardcoded flag, ...) gets
    # concatenated into a cmd.exe command line - captured process command
    # lines and Build & Deploy recipe fields both flow in from JSON files
    # (history.json/deploydefs.json) that a crafted/tampered backup import
    # can plant values into. Blocks the actual command-chaining operators
    # (&, |) and embedded newlines rather than quotes, since a real
    # captured Windows command line legitimately contains quoted paths -
    # blocking those would break the normal replay case, not just attacks.
    param([string]$Value)
    if (-not $Value) { return $false }
    return [bool]($Value -match '[&|]|\r|\n')
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
        if ((Test-HasShellChainingChars $runCommand) -or (Test-HasShellChainingChars $ProjectPath)) {
            Write-AppErrorLog -Context "Refused to start project: command/path contains shell chaining characters ($ProjectPath)" -Level Warning
            return $false
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
            StartedAt     = [DateTime]::UtcNow
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
                $label = Split-Path -Leaf $Event.MessageData.ProjectPath

                # A near-instant exit whose own output mentions an address
                # conflict is a port collision, not a real crash - flag it
                # separately so the notification/error log point at the
                # actual cause instead of a bare, unhelpful exit code. (This
                # is what a plain "exit code 1" looked like for Body Shop
                # when something else already had port 5100.)
                $portConflict = $false
                if (((Get-Date).ToUniversalTime() - $e.StartedAt).TotalSeconds -le 8) {
                    $recentLog = ($e.Log.ToArray() | Select-Object -Last 25) -join "`n"
                    if ($recentLog -match '(?i)(EADDRINUSE|address already in use|port \d+ is already in use|already in use)') {
                        $portConflict = $true
                    }
                }

                if ($portConflict) {
                    Write-AppErrorLog -Context "Project failed to start: $label - port already in use (exit code $code)"
                    try {
                        if ([bool]$script:Settings.CrashNotifications) {
                            $notifyIcon.ShowBalloonTip(4000, 'Localhost Manager', "$label didn't start - its port is already in use by something else.", [System.Windows.Forms.ToolTipIcon]::Warning)
                        }
                    } catch {}
                } else {
                    Write-AppErrorLog -Context "Project crashed: $label (exit code $code)"
                    try {
                        if ([bool]$script:Settings.CrashNotifications) {
                            $notifyIcon.ShowBalloonTip(4000, 'Localhost Manager', "$label crashed (exit code $code).", [System.Windows.Forms.ToolTipIcon]::Warning)
                        }
                    } catch {}
                }
            }
            $p = $Event.MessageData.SubPrefix
            Unregister-Event -SourceIdentifier "${p}_out" -ErrorAction SilentlyContinue
            Unregister-Event -SourceIdentifier "${p}_err" -ErrorAction SilentlyContinue
            Unregister-Event -SourceIdentifier "${p}_exit" -ErrorAction SilentlyContinue

            # Auto-restart runs after the old process's own events are torn
            # down above, and only for a genuine unattended crash - never
            # when the user themselves stopped it.
            if (-not $e.StoppedByUser) {
                $autoRestart = Get-AutoRestartConfig -ProjectPath $Event.MessageData.ProjectPath
                if ($autoRestart.Enabled) {
                    Invoke-CrashAutoRestart -ProjectPath $Event.MessageData.ProjectPath -CommandLine $autoRestart.CommandLine -Label $label
                }
            }
        } | Out-Null

        [void]$proc.Start()
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()

        return $true
    } catch {
        Write-AppErrorLog -Context "Failed to start project: $ProjectPath" -Exception $_.Exception
        return $false
    }
}

function Wait-UiResponsive {
    # Sleeps for the given duration while still pumping the WinForms message
    # loop, so the window keeps repainting/accepting input instead of
    # Windows flagging it "Not Responding" the way a plain Start-Sleep would
    # during a Restart/Stop/Start action - the whole point being that a
    # bounded pause should read as "busy" (see Start-/Stop-ActionBusyIndicator),
    # never as "hung".
    param([int]$Milliseconds)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 30
    }
}

function Wait-ProcessExitUiResponsive {
    # Same idea as Wait-UiResponsive, but bounded on a specific process
    # exiting (used for the taskkill wrapper) instead of a fixed duration.
    # Returns $true if it exited within the timeout, $false if still running
    # when we gave up - callers already treat that as "move on, the safety
    # net below still has a shot at it", same as the old WaitForExit(3000).
    param($Process, [int]$TimeoutMilliseconds)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while (-not $Process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 30
    }
    return $Process.HasExited
}

function Invoke-TaskKill {
    # Shared by every "hard-kill a process tree" call site (Stop-ProjectById,
    # Test-PortCollision, the deploy terminal's Stop Deploy button) - used
    # to be copy-pasted three times. Bounded wait, not -Wait: every caller
    # runs on the single WinForms UI thread, and a slow/stuck taskkill (AV
    # scanning it, an unkillable detached grandchild process, ...) must
    # never block that thread indefinitely - that's what froze the whole
    # app for an hour after a phone-hub restart, once. If it doesn't finish
    # in time this just gives up and returns $false; taskkill keeps running
    # independently and callers already treat that as "a safety-net
    # Stop-Process still has a shot at it", not a hard failure.
    param(
        [Parameter(Mandatory)][int]$ProcId,
        [int]$TimeoutMilliseconds = 3000,
        [string]$LogContext = ''
    )
    try {
        $killProc = New-Object System.Diagnostics.Process
        $killProc.StartInfo.FileName = 'taskkill.exe'
        $killProc.StartInfo.Arguments = "/PID $ProcId /T /F"
        $killProc.StartInfo.UseShellExecute = $false
        $killProc.StartInfo.CreateNoWindow = $true
        [void]$killProc.Start()
        $finished = Wait-ProcessExitUiResponsive -Process $killProc -TimeoutMilliseconds $TimeoutMilliseconds
        if (-not $finished -and $LogContext) {
            Write-AppErrorLog -Context "taskkill did not finish within $($TimeoutMilliseconds)ms for PID $ProcId ($LogContext) - continuing without waiting" -Level Warning
        }
        return $finished
    } catch {
        return $false
    }
}

function Stop-ProjectById {
    param([int]$ProcId, [string]$ProjectPath)

    $managed = $script:ManagedProcesses[(Get-NormalizedPath $ProjectPath)]
    if ($managed -and -not $managed.Proc.HasExited) {
        $managed.StoppedByUser = $true
        Invoke-TaskKill -ProcId $managed.Proc.Id -LogContext $ProjectPath | Out-Null
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
    # every refresh, so this is the single source of truth for it. Always
    # merges onto the existing entry (rather than replacing it outright)
    # so an independent flag on the same record - AutoRestart - never gets
    # silently wiped by toggling this one.
    param($data)
    $key = [string]$data.Port
    $history = Load-History
    $existing = if ($history.ContainsKey($key)) { $history[$key] } else { @{ AutoRestart = $false } }
    $history[$key] = @{
        ProjectPath = $data.ProjectPath
        ProcessName = $data.ProcessName
        Pinned      = -not [bool]$existing.Pinned
        AutoRestart = [bool]$existing.AutoRestart
        CommandLine = $data.CommandLine
    }
    Save-History $history
    # Unlike Invoke-ToggleAction/Invoke-Restart, there's no confirm
    # MessageBox or DoEvents pump between the triggering click and this
    # call to let the grid's own CellContentClick dispatch settle first -
    # calling Refresh-Grid synchronously here can catch the DataGridView
    # still mid-click (e.g. right after committing an edit on a
    # different cell in the same click, like clicking away from Custom
    # Name onto the neighboring Pin column), which throws "Operation
    # cannot be performed in this event handler" on Rows.Clear().
    # BeginInvoke defers it to the next message-loop iteration, after the
    # current click has fully unwound.
    $form.BeginInvoke([Action]{ Refresh-Grid }) | Out-Null
}

function Invoke-ToggleAutoRestart {
    # Same merge-onto-existing-entry pattern as Invoke-TogglePin (see its
    # comment) - AutoRestart and Pinned are independent flags on the same
    # history.json record, keyed by port.
    param($data)
    $key = [string]$data.Port
    $history = Load-History
    $existing = if ($history.ContainsKey($key)) { $history[$key] } else { @{ Pinned = $false } }
    $history[$key] = @{
        ProjectPath = $data.ProjectPath
        ProcessName = $data.ProcessName
        Pinned      = [bool]$existing.Pinned
        AutoRestart = -not [bool]$existing.AutoRestart
        CommandLine = $data.CommandLine
    }
    Save-History $history
    Refresh-Grid
}

function Get-AutoRestartConfig {
    # AutoRestart lives in history.json keyed by port, but a just-crashed
    # process is (by definition) no longer listening on one - so this
    # matches by ProjectPath across every history entry instead of a
    # direct port lookup. Returns the matching entry's own CommandLine
    # too (the last observed OS argv for this project, same fallback
    # Start-ProjectAtPath already understands for non-npm projects) so
    # the caller doesn't need a second Load-History pass.
    param([string]$ProjectPath)
    $result = [PSCustomObject]@{ Enabled = $false; CommandLine = $null }
    if (-not $ProjectPath) { return $result }
    $normalized = Get-NormalizedPath $ProjectPath
    $history = Load-History
    foreach ($h in $history.Values) {
        if ($h.ProjectPath -and (Get-NormalizedPath $h.ProjectPath) -eq $normalized -and [bool]$h.AutoRestart) {
            $result.Enabled = $true
            $result.CommandLine = $h.CommandLine
            break
        }
    }
    return $result
}

function Invoke-CrashAutoRestart {
    # Capped rolling-window retry so a project that's genuinely
    # crash-looping (bad code, a permanently-taken port, ...) gets a
    # handful of real tries and then gives up loudly instead of hammering
    # forever. The window is tracked in $script:AutoRestartAttempts, keyed
    # by normalized project path - deliberately NOT on the process's own
    # $entry, since Start-ProjectAtPath replaces that entry outright on
    # every (re)start, which would silently reset an attempt counter kept
    # there back to zero after just one successful restart (see that
    # variable's declaration).
    param([string]$ProjectPath, [string]$CommandLine, [string]$Label)
    $key = Get-NormalizedPath $ProjectPath
    $cutoff = (Get-Date).ToUniversalTime().AddMinutes(-$script:AutoRestartWindowMinutes)
    $attempts = @($script:AutoRestartAttempts[$key] | Where-Object { $_ -gt $cutoff })

    if ($attempts.Count -ge $script:AutoRestartMaxAttempts) {
        $script:AutoRestartAttempts[$key] = $attempts
        Write-AppErrorLog -Context "Auto-restart gave up on $Label - $($script:AutoRestartMaxAttempts) attempts in $($script:AutoRestartWindowMinutes) minutes"
        try {
            if ([bool]$script:Settings.CrashNotifications) {
                $notifyIcon.ShowBalloonTip(5000, 'Localhost Manager', "$Label keeps crashing - gave up auto-restarting after $($script:AutoRestartMaxAttempts) tries. Check its log.", [System.Windows.Forms.ToolTipIcon]::Error)
            }
        } catch {}
        return
    }

    $attempts += (Get-Date).ToUniversalTime()
    $script:AutoRestartAttempts[$key] = $attempts

    # Brief pause before relaunching - gives a transient port collision
    # (the other holder still tearing down, e.g. right after a sleep/wake)
    # a moment to clear instead of racing straight back into it.
    Start-Sleep -Milliseconds 1500

    if (-not (Start-ProjectAtPath -ProjectPath $ProjectPath -CommandLine $CommandLine)) {
        Write-AppErrorLog -Context "Auto-restart failed to relaunch $Label (attempt $($attempts.Count) of $($script:AutoRestartMaxAttempts))"
    } else {
        $managed = $script:ManagedProcesses[$key]
        if ($managed) { Add-ManagedLog -Entry $managed -Text "*** auto-restarted (attempt $($attempts.Count) of $($script:AutoRestartMaxAttempts) in $($script:AutoRestartWindowMinutes) min) ***" }
    }
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

function Get-PortListenerInfo {
    # Fresh, single-port synchronous check used right before a launch -
    # unlike $script:LiveCache (which can lag behind by up to one poll
    # interval), this always reflects reality at the moment Start is
    # clicked. ProjectPath, when available, is borrowed from LiveCache
    # (whatever the background poller's PEB walk already resolved for this
    # PID) rather than duplicating that walk here - fine for "whose orphan
    # is this" context even if it's a tick stale, since the busy/free fact
    # itself always comes from the fresh check above.
    param([int]$Port)
    try {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    } catch { $conn = $null }
    if (-not $conn) { return $null }

    $procId = [int]$conn.OwningProcess
    $procName = $null
    try { $procName = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch {}

    $projectPath = $null
    $cached = $script:LiveCache.Listeners[[string]$Port]
    if ($cached -and [int]$cached.ProcId -eq $procId) { $projectPath = $cached.ProjectPath }

    return [PSCustomObject]@{
        ProcId      = $procId
        ProcessName = $procName
        ProjectPath = $projectPath
    }
}

function Test-PortCollision {
    # Runs immediately before a desktop-triggered Start/Restart so a
    # process already squatting the target port becomes an upfront,
    # actionable choice instead of the doomed launch that hit Body Shop:
    # npm's node exiting 1 with "port already in use", logged as a plain,
    # unexplained crash. Returns $true when it's fine to go ahead and call
    # Start-ProjectAtPath, $false when the caller should not start it.
    #
    # Not wired into Start-ProjectAtPath itself - that function is also the
    # web dashboard's start/restart path (see Invoke-DashboardAction), and
    # a blocking MessageBox triggered by a remote browser click would just
    # hang the desktop app waiting for someone at the keyboard to answer it.
    param([string]$ProjectPath, [int]$Port, [string]$Label)
    if ($Port -le 0) { return $true }
    $info = Get-PortListenerInfo -Port $Port
    if (-not $info) { return $true }

    $sameProject = $info.ProjectPath -and ((Get-NormalizedPath $info.ProjectPath) -eq (Get-NormalizedPath $ProjectPath))
    $who = if ($info.ProcessName) { "$($info.ProcessName) (PID $($info.ProcId))" } else { "PID $($info.ProcId)" }

    if ($sameProject) {
        $title = 'Already Running?'
        $message = "$Label already appears to be listening on port $Port ($who), but Localhost Manager isn't tracking it - probably left running from an earlier session or crash.`n`nKill it and start fresh?"
    } else {
        $title = 'Port In Use'
        $message = "Port $Port is already in use by $who, which doesn't look related to $Label. Starting now will very likely fail immediately.`n`nKill that process and start anyway?"
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show($message, $title, 'YesNo', 'Warning')
    if ($confirm -ne 'Yes') { return $false }

    Invoke-TaskKill -ProcId $info.ProcId -LogContext "port $Port" | Out-Null
    try {
        if (Get-Process -Id $info.ProcId -ErrorAction SilentlyContinue) {
            Stop-Process -Id $info.ProcId -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    Wait-UiResponsive -Milliseconds 400
    return $true
}

function Invoke-ToggleAction {
    param($data)
    if ($script:ActionBusy) { return }
    $script:ActionBusy = $true
    try {
        if ($data.Status -eq 'ON') {
            $confirm = [System.Windows.Forms.MessageBox]::Show(
                "Stop $($data.ProcessName) (PID $($data.ProcId)) listening on port $($data.Port)?",
                'Confirm Stop', 'YesNo', 'Warning')
            if ($confirm -ne 'Yes') { return }
            Start-ActionBusyIndicator
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
            Start-ActionBusyIndicator
            $label = if ($data.CustomName) { $data.CustomName } else { Split-Path -Leaf $data.ProjectPath }
            if (-not (Test-PortCollision -ProjectPath $data.ProjectPath -Port ([int]$data.Port) -Label $label)) { return }
            if (-not (Start-ProjectAtPath -ProjectPath $data.ProjectPath -CommandLine $data.CommandLine)) {
                [System.Windows.Forms.MessageBox]::Show('Could not start project.', 'Error', 'OK', 'Error') | Out-Null
            }
        }
        Wait-UiResponsive -Milliseconds 800
        Refresh-Grid
    } finally {
        $script:ActionBusy = $false
        Stop-ActionBusyIndicator
    }
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
    if ($script:ActionBusy) { return }
    $script:ActionBusy = $true
    try {
        if ($data.Status -eq 'ON') {
            $confirm = [System.Windows.Forms.MessageBox]::Show(
                "Restart $($data.ProcessName) (PID $($data.ProcId)) listening on port $($data.Port)?",
                'Confirm Restart', 'YesNo', 'Warning')
            if ($confirm -ne 'Yes') { return }
            Start-ActionBusyIndicator
            if (-not (Stop-ProjectById -ProcId $data.ProcId -ProjectPath $data.ProjectPath)) {
                [System.Windows.Forms.MessageBox]::Show('Could not stop process.', 'Error', 'OK', 'Error') | Out-Null
                return
            }
            Wait-UiResponsive -Milliseconds 800
        }

        Start-ActionBusyIndicator
        $label = if ($data.CustomName) { $data.CustomName } else { Split-Path -Leaf $data.ProjectPath }
        if (-not (Test-PortCollision -ProjectPath $data.ProjectPath -Port ([int]$data.Port) -Label $label)) { return }

        if (-not (Start-ProjectAtPath -ProjectPath $data.ProjectPath -CommandLine $data.CommandLine)) {
            [System.Windows.Forms.MessageBox]::Show('Could not start project.', 'Error', 'OK', 'Error') | Out-Null
        }
        Wait-UiResponsive -Milliseconds 800
        Refresh-Grid
    } finally {
        $script:ActionBusy = $false
        Stop-ActionBusyIndicator
    }
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
    Set-DarkTitleBar -FormControl $dlg

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

function Show-AppErrorLogViewer {
    # Same live-tail shape as Show-LogViewer above, but reading the single
    # flat app-error.log file instead of a per-project in-memory queue, and
    # colorizing each entry's header line so a scroll through a busy log
    # reads as a list of incidents rather than a wall of text.
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Error & Crash Log'
    $dlg.Size = New-Object System.Drawing.Size(780, 520)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimumSize = New-Object System.Drawing.Size(480, 300)
    $dlg.Icon = $script:IconOk
    $dlg.BackColor = $script:Theme.WindowBg
    Set-DarkTitleBar -FormControl $dlg

    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.Dock = 'Fill'
    $rtb.ReadOnly = $true
    # WordWrap on, not off: a long single-line entry (a full exception
    # message, a stack trace frame) otherwise requires horizontal scrolling,
    # and RichTextBox auto-scrolls horizontally to follow the caret after
    # AppendText - which left the START of the line (often the most useful
    # part) scrolled out of view. Wrapping means everything is always
    # on-screen without the reader having to scroll sideways to read it.
    $rtb.WordWrap = $true
    $rtb.ScrollBars = 'Vertical'
    $rtb.BorderStyle = 'None'
    $rtb.Font = New-Object System.Drawing.Font('Consolas', 9)
    $rtb.BackColor = [System.Drawing.Color]::FromArgb(0x1E, 0x1E, 0x1E)
    $rtb.ForeColor = [System.Drawing.Color]::Gainsboro

    $bottomPanel = New-Object System.Windows.Forms.Panel
    $bottomPanel.Dock = 'Bottom'
    $bottomPanel.Height = 44
    $bottomPanel.BackColor = $script:Theme.PanelBg

    $filterPanel = New-Object System.Windows.Forms.Panel
    $filterPanel.Dock = 'Top'
    $filterPanel.Height = 40
    $filterPanel.BackColor = $script:Theme.PanelBg

    # Parent rtb/bottomPanel/filterPanel to the form BEFORE adding the
    # Top,Right-anchored buttons below: anchoring captures its
    # distance-from-edge baseline against the parent's size at the moment
    # the child is parented. Adding buttons to a not-yet-docked bottomPanel
    # (still at its default ~200px design-time width) baselines them
    # against that wrong width, and once bottomPanel gets its real ~760px
    # docked width the anchor math throws them far off to the right,
    # outside the visible window - which is exactly why they went missing.
    $dlg.Controls.Add($rtb)
    $dlg.Controls.Add($bottomPanel)
    $dlg.Controls.Add($filterPanel)

    $filterLbl = New-Object System.Windows.Forms.Label
    $filterLbl.Text = 'Filter:'
    $filterLbl.Location = New-Object System.Drawing.Point(12, 12)
    $filterLbl.Size = New-Object System.Drawing.Size(40, 20)
    $filterLbl.ForeColor = $script:Theme.TextDim

    $filterBox = New-Object System.Windows.Forms.TextBox
    $filterBox.Location = New-Object System.Drawing.Point(54, 8)
    $filterBox.Size = New-Object System.Drawing.Size(320, 24)
    $filterBox.BorderStyle = 'FixedSingle'
    $filterBox.BackColor = $script:Theme.CardBg
    $filterBox.ForeColor = $script:Theme.TextPrimary

    [System.Windows.Forms.Control[]]$filterControls = @($filterLbl, $filterBox)
    $filterPanel.Controls.AddRange($filterControls)

    $countLbl = New-Object System.Windows.Forms.Label
    $countLbl.Location = New-Object System.Drawing.Point(12, 15)
    $countLbl.Size = New-Object System.Drawing.Size(420, 20)
    $countLbl.ForeColor = $script:Theme.TextDim
    $countLbl.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 8)
    $countLbl.AutoEllipsis = $true

    $openFolderButton = New-Object System.Windows.Forms.Button
    $openFolderButton.Text = 'Open Folder'
    $openFolderButton.Anchor = 'Top,Right'
    $openFolderButton.Location = New-Object System.Drawing.Point(475, 8)
    $openFolderButton.Size = New-Object System.Drawing.Size(95, 28)
    $openFolderButton.Add_Click({
        try {
            if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
            Start-Process explorer.exe $script:LogDir
        } catch {}
    })
    Initialize-ModernButton -Button $openFolderButton

    $clearButton = New-Object System.Windows.Forms.Button
    $clearButton.Text = 'Clear Log'
    $clearButton.Anchor = 'Top,Right'
    $clearButton.Location = New-Object System.Drawing.Point(580, 8)
    $clearButton.Size = New-Object System.Drawing.Size(85, 28)
    Initialize-ModernButton -Button $clearButton -Variant Danger

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = 'Close'
    $closeButton.Anchor = 'Top,Right'
    $closeButton.Location = New-Object System.Drawing.Point(675, 8)
    $closeButton.Size = New-Object System.Drawing.Size(80, 28)
    $closeButton.Add_Click({ $dlg.Close() })
    Initialize-ModernButton -Button $closeButton -Variant Accent

    [System.Windows.Forms.Control[]]$bottomControls = @($countLbl, $openFolderButton, $clearButton, $closeButton)
    $bottomPanel.Controls.AddRange($bottomControls)

    $headerFont = New-Object System.Drawing.Font('Consolas', 9, [System.Drawing.FontStyle]::Bold)
    $bodyFont = New-Object System.Drawing.Font('Consolas', 9)
    $errorColor = [System.Drawing.Color]::FromArgb(0xFF, 0x8A, 0x65)
    $warningColor = [System.Drawing.Color]::FromArgb(0xFF, 0xD5, 0x4F)
    $bodyColor = [System.Drawing.Color]::FromArgb(0xAA, 0xAA, 0xAA)
    $emptyColor = [System.Drawing.Color]::FromArgb(0x77, 0x77, 0x77)
    $entryHeaderPattern = '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]\s*(?:\[(ERROR|WARNING)\]\s*)?(.*)$'

    # State is an object (not a bare variable) so the nested functions/event
    # handlers below - which run in this same scope but can only read outer
    # variables, not reassign them - can still mutate it via property
    # assignment. Signature bundles the filter text in with the file's raw
    # content so a filter keystroke forces a re-render exactly like a file
    # change does, without needing two separate change-tracking paths.
    $state = [PSCustomObject]@{ Signature = $null }

    function Get-AppLogEntries {
        # Groups raw lines into per-incident records (header + its indented
        # detail lines) so filtering/highlighting always keeps a header
        # together with the detail that explains it, instead of matching
        # (or hiding) stray lines out of context.
        param([string]$Text)
        $entries = @()
        $current = $null
        foreach ($line in ($Text -split "`r?`n")) {
            if ($line -eq '') { continue }
            if ($line -match $entryHeaderPattern) {
                if ($current) { $entries += $current }
                $level = if ($matches[2]) { $matches[2] } else { 'ERROR' }
                $current = [PSCustomObject]@{
                    Header  = "[$($matches[1])] $($matches[3])"
                    Level   = $level
                    Details = @()
                }
            } elseif ($current) {
                $current.Details += $line
            }
        }
        if ($current) { $entries += $current }
        return $entries
    }

    function Update-AppLogText {
        $text = $null
        if (Test-Path $script:AppLogPath) {
            try { $text = Get-Content -Path $script:AppLogPath -Raw -ErrorAction Stop } catch {}
        }
        $filter = $filterBox.Text.Trim()
        $sig = "$filter|$text"
        if ($sig -eq $state.Signature) { return }
        $state.Signature = $sig

        $allEntries = if ($text) { @(Get-AppLogEntries -Text $text) } else { @() }
        $shownEntries = if ($filter) {
            @($allEntries | Where-Object { $_.Header -like "*$filter*" -or ($_.Details -join "`n") -like "*$filter*" })
        } else {
            $allEntries
        }

        if ($allEntries.Count -eq 0) {
            $countLbl.Text = "$script:AppLogPath"
        } elseif ($filter) {
            $countLbl.Text = "$($shownEntries.Count) of $($allEntries.Count) entries match `"$filter`""
        } else {
            $stats = Get-AppErrorLogStats
            $countLbl.Text = "$($allEntries.Count) entr$(if ($allEntries.Count -eq 1) {'y'} else {'ies'}) - last: $($stats.LastText)"
        }

        $atBottom = $rtb.SelectionStart -ge ($rtb.TextLength - 2)
        $rtb.SuspendLayout()
        $rtb.Clear()
        if ($shownEntries.Count -eq 0) {
            $rtb.SelectionColor = $emptyColor
            $rtb.SelectionFont = $bodyFont
            $emptyMessage = if ($allEntries.Count -eq 0) {
                'No errors logged. Startup failures, unhandled exceptions, and dev-server crashes will show up here automatically.'
            } else {
                "No entries match `"$filter`"."
            }
            $rtb.AppendText($emptyMessage)
        } else {
            foreach ($entry in $shownEntries) {
                $icon = if ($entry.Level -eq 'WARNING') { [char]0x26A0 } else { [char]0x2716 }
                $rtb.SelectionColor = if ($entry.Level -eq 'WARNING') { $warningColor } else { $errorColor }
                $rtb.SelectionFont = $headerFont
                $rtb.AppendText("$icon $($entry.Header)`r`n")
                foreach ($detail in $entry.Details) {
                    $rtb.SelectionColor = $bodyColor
                    $rtb.SelectionFont = $bodyFont
                    $rtb.AppendText("$detail`r`n")
                }
            }
        }
        $rtb.ResumeLayout()
        if ($atBottom) {
            $rtb.SelectionStart = $rtb.TextLength
            $rtb.ScrollToCaret()
        }
    }
    Update-AppLogText

    $filterBox.Add_TextChanged({ Update-AppLogText })

    $clearButton.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show('Clear the error log? This cannot be undone.', 'Clear Log', 'YesNo', 'Warning')
        if ($confirm -ne 'Yes') { return }
        try { if (Test-Path $script:AppLogPath) { Clear-Content -Path $script:AppLogPath -Force } } catch {}
        Update-AppLogText
    })

    $liveTimer = New-Object System.Windows.Forms.Timer
    $liveTimer.Interval = 2000
    $liveTimer.Add_Tick({ Update-AppLogText })
    $liveTimer.Start()
    $dlg.Add_FormClosed({ $liveTimer.Stop() })

    $dlg.ShowDialog($form) | Out-Null
}

function Get-WrappedLabelHeight {
    # A wrapped Label's .Height is stale until it's been through a real
    # layout pass (normally means being parented) - AutoSize + MaximumSize
    # doesn't recompute it just from being constructed, so reading .Height
    # right after `New-Object` still returns the single-line default even
    # if the text visibly wraps once shown. Measuring the wrapped text
    # directly (the same technique used for the Restart column's width -
    # see New-PortsGrid) sidesteps the timing issue entirely: it's the
    # real wrapped height, independent of when/whether the label has
    # actually been parented yet.
    param([string]$Text, [System.Drawing.Font]$LabelFont, [int]$MaxWidth)
    $flags = [System.Windows.Forms.TextFormatFlags]::WordBreak
    return [System.Windows.Forms.TextRenderer]::MeasureText($Text, $LabelFont, (New-Object System.Drawing.Size($MaxWidth, 0)), $flags).Height
}

function New-DeployFieldRow {
    # One "wrapping description label, above a value box (optionally with
    # a Browse... button beside it)" row, used three times in
    # Show-DeployConfigDialog. The box is positioned via
    # Get-WrappedLabelHeight rather than a fixed gap, so it always lands
    # below the label's real wrapped height regardless of theme font.
    param([string]$LabelText, [int]$Y, [string]$Value, [bool]$Browse, [System.Drawing.Font]$LabelFont, [int]$LabelMaxWidth)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $LabelText
    $lbl.AutoSize = $true
    $lbl.MaximumSize = New-Object System.Drawing.Size($LabelMaxWidth, 0)
    $lbl.Location = New-Object System.Drawing.Point(15, $Y)
    $lbl.ForeColor = $script:Theme.TextDim
    $lbl.Font = $LabelFont

    $boxY = $Y + (Get-WrappedLabelHeight -Text $LabelText -LabelFont $LabelFont -MaxWidth $LabelMaxWidth) + 2
    $box = New-Object System.Windows.Forms.TextBox
    $box.Text = $Value
    $box.Location = New-Object System.Drawing.Point(15, $boxY)
    $box.Size = New-Object System.Drawing.Size(($(if ($Browse) { 405 } else { 495 })), 24)
    $box.BorderStyle = 'FixedSingle'
    $box.BackColor = $script:Theme.CardBg
    $box.ForeColor = $script:Theme.TextPrimary

    $rowResult = @{ Label = $lbl; Box = $box; Browse = $null; Bottom = ($boxY + 24) }
    if ($Browse) {
        $browseBtn = New-Object System.Windows.Forms.Button
        $browseBtn.Text = '...'
        $browseBtn.Location = New-Object System.Drawing.Point(425, ($boxY - 1))
        $browseBtn.Size = New-Object System.Drawing.Size(85, 26)
        $browseBtn.Add_Click({
            $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
            if ($box.Text) { $fbd.SelectedPath = $box.Text }
            if ($fbd.ShowDialog() -eq 'OK') { $box.Text = $fbd.SelectedPath }
        }.GetNewClosure())
        Initialize-ModernButton -Button $browseBtn
        $rowResult.Browse = $browseBtn
    }
    return $rowResult
}

function Show-DeployConfigDialog {
    # Add/edit the build+deploy recipe attached to one tracked port -
    # originally written for the Jewelry Store frontend/server split (npm
    # run build, then robocopy dist/ into the server's public/),
    # generalized so any project can have one, and any project can mirror
    # its build output to more than one place (e.g. a server's public/ AND
    # a staging copy).
    #
    # The recipe is *attached to* $ProjectPath (that's what makes it show
    # up when browsing from that port in Show-DeployManagerDialog / row
    # detail) but the working folder the build actually runs in is its own
    # editable field, not assumed to equal $ProjectPath - the frontend/
    # server split is exactly the case where they differ: the only thing
    # that's a *tracked port* is the server, but the build has to run over
    # in the frontend's folder, which isn't a port at all.
    param([string]$ProjectPath, [string]$Label)

    $existing = $script:DeployDefs[(Get-NormalizedPath $ProjectPath)]

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Configure Deploy - $Label"
    $dlg.Size = New-Object System.Drawing.Size(540, 560)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $script:Theme.WindowBg
    $dlg.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9)
    Set-DarkTitleBar -FormControl $dlg

    $descFont = New-Object System.Drawing.Font($script:Theme.FontFamily, 8)
    $labelMaxWidth = 500

    # AutoSize + MaximumSize (width capped, height 0 = unlimited) instead of
    # a fixed Size box: this is what a fixed one-line-tall box guessed
    # under Light/Dark's Segoe UI, then silently clipped to nothing once
    # Terminal's much wider monospace font pushed the same text onto a
    # second line the box had no room for ("Project folder (where the
    # build command runs) - not always this port's..." cut off mid-
    # sentence). Wrapping labels can never clip this way - worst case they
    # just wrap and every control below cascades down to match, via each
    # row's real measured height instead of a guessed fixed gap. See
    # Get-WrappedLabelHeight/New-DeployFieldRow above for why the row
    # boxes are positioned by measuring rather than trusting .Height.

    $defaultWorkingDir = if ($existing.WorkingDir) { $existing.WorkingDir } else { $ProjectPath }
    $defaultBuild = if ($existing.BuildCommand) { $existing.BuildCommand } else { 'npm run build' }
    $defaultSource = if ($existing.SourceDir) { $existing.SourceDir } else { Join-Path $defaultWorkingDir 'dist' }

    $y = 12
    $workDirRow = New-DeployFieldRow -LabelText 'Project folder (where the build command runs):' -Y $y -Value $defaultWorkingDir -Browse $true -LabelFont $descFont -LabelMaxWidth $labelMaxWidth
    $y = $workDirRow.Bottom + 16

    $buildRow = New-DeployFieldRow -LabelText 'Build command:' -Y $y -Value $defaultBuild -Browse $false -LabelFont $descFont -LabelMaxWidth $labelMaxWidth
    $y = $buildRow.Bottom + 16

    $sourceRow = New-DeployFieldRow -LabelText 'Build output folder (source):' -Y $y -Value $defaultSource -Browse $true -LabelFont $descFont -LabelMaxWidth $labelMaxWidth
    $y = $sourceRow.Bottom + 16

    $targetsLbl = New-Object System.Windows.Forms.Label
    $targetsLbl.Text = 'Deploy target folder(s) - each is mirrored, old files there get deleted:'
    $targetsLbl.AutoSize = $true
    $targetsLbl.MaximumSize = New-Object System.Drawing.Size($labelMaxWidth, 0)
    $targetsLbl.Location = New-Object System.Drawing.Point(15, $y)
    $targetsLbl.ForeColor = $script:Theme.TextDim
    $targetsLbl.Font = $descFont
    $y += (Get-WrappedLabelHeight -Text $targetsLbl.Text -LabelFont $descFont -MaxWidth $labelMaxWidth) + 2

    $targetsList = New-Object System.Windows.Forms.ListBox
    $targetsList.Location = New-Object System.Drawing.Point(15, $y)
    $targetsList.Size = New-Object System.Drawing.Size(405, 90)
    $targetsList.BorderStyle = 'FixedSingle'
    $targetsList.BackColor = $script:Theme.CardBg
    $targetsList.ForeColor = $script:Theme.TextPrimary
    foreach ($t in @($existing.TargetDirs)) { if ($t) { [void]$targetsList.Items.Add($t) } }

    $addTargetBtn = New-Object System.Windows.Forms.Button
    $addTargetBtn.Text = 'Add...'
    $addTargetBtn.Location = New-Object System.Drawing.Point(425, $y)
    $addTargetBtn.Size = New-Object System.Drawing.Size(85, 26)
    $addTargetBtn.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($fbd.ShowDialog() -eq 'OK' -and $fbd.SelectedPath -notin $targetsList.Items) {
            [void]$targetsList.Items.Add($fbd.SelectedPath)
        }
    }.GetNewClosure())
    Initialize-ModernButton -Button $addTargetBtn

    $removeTargetBtn = New-Object System.Windows.Forms.Button
    $removeTargetBtn.Text = 'Remove'
    $removeTargetBtn.Location = New-Object System.Drawing.Point(425, ($y + 30))
    $removeTargetBtn.Size = New-Object System.Drawing.Size(85, 26)
    $removeTargetBtn.Add_Click({
        if ($targetsList.SelectedIndex -ge 0) { $targetsList.Items.RemoveAt($targetsList.SelectedIndex) }
    }.GetNewClosure())
    Initialize-ModernButton -Button $removeTargetBtn
    $y += $targetsList.Height + 20

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'Save'
    $okButton.Location = New-Object System.Drawing.Point(340, $y)
    $okButton.Size = New-Object System.Drawing.Size(85, 28)
    $okButton.Add_Click({ $dlg.Tag = 'OK'; $dlg.Close() })
    Initialize-ModernButton -Button $okButton -Variant Accent

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = New-Object System.Drawing.Point(430, $y)
    $cancelButton.Size = New-Object System.Drawing.Size(85, 28)
    $cancelButton.Add_Click({ $dlg.Close() })
    Initialize-ModernButton -Button $cancelButton
    $y += 28 + 20
    $dlg.ClientSize = New-Object System.Drawing.Size($dlg.ClientSize.Width, $y)

    [System.Windows.Forms.Control[]]$controls = @(
        $workDirRow.Label, $workDirRow.Box, $workDirRow.Browse,
        $buildRow.Label, $buildRow.Box,
        $sourceRow.Label, $sourceRow.Box, $sourceRow.Browse,
        $targetsLbl, $targetsList, $addTargetBtn, $removeTargetBtn,
        $okButton, $cancelButton
    )
    $dlg.Controls.AddRange($controls)
    $dlg.AcceptButton = $okButton
    $dlg.ShowDialog($form) | Out-Null

    if ($dlg.Tag -ne 'OK') { return $null }
    if (-not $workDirRow.Box.Text -or -not $sourceRow.Box.Text -or $targetsList.Items.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('The project folder, the build output folder, and at least one deploy target folder are all required.', 'Missing Folder', 'OK', 'Warning') | Out-Null
        return $null
    }

    $config = @{
        BuildCommand = $buildRow.Box.Text
        WorkingDir   = $workDirRow.Box.Text
        SourceDir    = $sourceRow.Box.Text
        TargetDirs   = @($targetsList.Items)
    }
    $script:DeployDefs[(Get-NormalizedPath $ProjectPath)] = $config
    Save-DeployDefs $script:DeployDefs
    return $config
}

function Show-DeployRunDialog {
    # Runs the build command, then mirrors the output folder into every
    # configured target via robocopy - the build gates the copies (a && so
    # a failed build deploys nothing), the targets themselves run
    # unconditionally one after another (a bare & - if target 2 is
    # unreachable, target 1 having already succeeded still matters). Same
    # async Register-ObjectEvent pattern as Start-ProjectAtPath (not a raw
    # .Add_OutputDataReceived - that fires on a ThreadPool thread and
    # corrupts this single-threaded runspace) so a slow build never blocks
    # the window.
    #
    # Runs under cmd /k, not /c - the session stays open afterward as a
    # real interactive shell instead of exiting the moment the scripted
    # part finishes, and the textbox is editable: typing a line and
    # pressing Enter sends it to the session's stdin (RedirectStandardInput)
    # the same way a real terminal would. Since /k means there's no single
    # "final exit code" to read once and be done (the process only exits
    # when the user types `exit` or the dialog force-kills it), the
    # build+deploy result instead comes from a sentinel line
    # (LHM_DEPLOY_DONE:<code>) echoed right after the scripted commands,
    # parsed out of the output stream and never shown to the user verbatim.
    #
    # -Port is just which port row this recipe is attached to, shown here
    # so it's never ambiguous which of possibly several similar-looking
    # projects is actually about to be built - the info panel below the
    # title also spells out the exact build folder/command and every
    # copy target, since the port itself doesn't say where the build
    # actually runs (see Show-DeployConfigDialog: that's a separate,
    # independently-editable folder).
    param([string]$ProjectPath, [string]$Label, [string]$Port, [hashtable]$Config)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = if ($Port) { "Deploy - $Label (port $Port)" } else { "Deploy - $Label" }
    $dlg.Size = New-Object System.Drawing.Size(720, 520)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimumSize = New-Object System.Drawing.Size(420, 300)
    $dlg.BackColor = $script:Theme.WindowBg
    $dlg.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9)
    Set-DarkTitleBar -FormControl $dlg

    $infoLbl = New-Object System.Windows.Forms.Label
    $infoLbl.Dock = 'Top'
    $infoLbl.Height = 60
    $infoLbl.TextAlign = 'TopLeft'
    $infoLbl.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 4)
    $infoLbl.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 8)
    $infoLbl.ForeColor = $script:Theme.TextDim
    $infoLbl.BackColor = $script:Theme.WindowBg
    $portSuffix = if ($Port) { " (port $Port)" } else { '' }
    $targetsText = (@($Config.TargetDirs) -join '  ;  ')
    $infoLbl.Text = "Project: $Label$portSuffix`r`nBuild: `"$($Config.BuildCommand)`" in $($Config.WorkingDir)`r`nCopy: $($Config.SourceDir)  ->  $targetsText"

    $statusLbl = New-Object System.Windows.Forms.Label
    $statusLbl.Dock = 'Top'
    $statusLbl.Height = 28
    $statusLbl.TextAlign = 'MiddleLeft'
    $statusLbl.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
    $statusLbl.Text = 'Starting...'
    $statusLbl.ForeColor = $script:Theme.TextDim
    $statusLbl.BackColor = $script:Theme.PanelBg

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Multiline = $true
    $textBox.ReadOnly = $false
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

    $rerunButton = New-Object System.Windows.Forms.Button
    $rerunButton.Text = 'Run Again'
    $rerunButton.Location = New-Object System.Drawing.Point(10, 6)
    $rerunButton.Size = New-Object System.Drawing.Size(100, 28)
    $rerunButton.Enabled = $false
    Initialize-ModernButton -Button $rerunButton -Variant Accent

    # Hard-kills the whole cmd.exe /k tree (taskkill /T /F), same mechanism
    # Stop-ProjectById already uses for the grid's Stop button - not a real
    # CTRL_C_EVENT (this process has no console of its own to attach for
    # one, being a -noConsole build, and a soft signal risks a build tool
    # just swallowing it and continuing). The visible effect is the same
    # thing a user expects from Ctrl+C at a real prompt: the running
    # build/copy stops right now.
    $stopButton = New-Object System.Windows.Forms.Button
    $stopButton.Text = 'Stop Deploy'
    $stopButton.Location = New-Object System.Drawing.Point(120, 6)
    $stopButton.Size = New-Object System.Drawing.Size(100, 28)
    $stopButton.Enabled = $false
    Initialize-ModernButton -Button $stopButton -Variant Danger

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = 'Close'
    $closeButton.Anchor = 'Top,Right'
    $closeButton.Location = New-Object System.Drawing.Point(620, 6)
    $closeButton.Size = New-Object System.Drawing.Size(80, 28)
    $closeButton.Add_Click({ $dlg.Close() })
    Initialize-ModernButton -Button $closeButton

    [System.Windows.Forms.Control[]]$bottomControls = @($rerunButton, $stopButton, $closeButton)
    $bottomPanel.Controls.AddRange($bottomControls)
    $dlg.Controls.Add($textBox)
    $dlg.Controls.Add($statusLbl)
    $dlg.Controls.Add($infoLbl)
    $dlg.Controls.Add($bottomPanel)

    $currentProc = $null

    # Enter sends whatever's on the current line to the session's stdin -
    # a minimal terminal, not a full PTY (programs that need a real console,
    # like interactive setup wizards, won't work over this pipe), but
    # enough to run ordinary follow-up commands in the same shell/directory
    # the build just ran in.
    $textBox.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -ne [System.Windows.Forms.Keys]::Return) { return }
        $e.SuppressKeyPress = $true
        if (-not $currentProc -or $currentProc.HasExited) { return }
        $lineIndex = $textBox.GetLineFromCharIndex($textBox.SelectionStart)
        $lineText = $textBox.Lines[$lineIndex]
        try { $currentProc.StandardInput.WriteLine($lineText) } catch {}
        $textBox.AppendText("`r`n")
        $textBox.SelectionStart = $textBox.TextLength
        $textBox.ScrollToCaret()
    })

    function Start-DeployRun {
        if ($currentProc -and -not $currentProc.HasExited) { try { $currentProc.Kill() } catch {} }
        $rerunButton.Enabled = $false
        $stopButton.Enabled = $true
        $textBox.Clear()
        $statusLbl.Text = 'Running...'
        $statusLbl.ForeColor = $script:Theme.Accent

        $workDir = if ($Config.WorkingDir) { $Config.WorkingDir } else { $ProjectPath }
        $buildCmd = if ($Config.BuildCommand) { $Config.BuildCommand } else { 'npm run build' }
        $targets = @($Config.TargetDirs)

        # Recipe fields are free-typed and stored in deploydefs.json, which
        # (like history.json's CommandLine) a tampered/shared backup import
        # could plant a value into - refuse to build a command line out of
        # anything containing shell chaining operators rather than trusting
        # every field is always benign.
        $unsafeValues = @($workDir, $buildCmd, $Config.SourceDir) + $targets
        if ($unsafeValues | Where-Object { Test-HasShellChainingChars $_ }) {
            $statusLbl.Text = 'Refused to run: recipe contains shell chaining characters (& or |) - check C-Deploy.'
            $statusLbl.ForeColor = $script:Theme.Danger
            $rerunButton.Enabled = $true
            $stopButton.Enabled = $false
            Write-AppErrorLog -Context "Refused to run deploy for $ProjectPath - recipe contains shell chaining characters" -Level Warning
            return
        }

        $copySteps = ($targets | ForEach-Object { "robocopy `"$($Config.SourceDir)`" `"$_`" /MIR" }) -join ' & '
        $cmdLine = "cd /d `"$workDir`" && $buildCmd && $copySteps & echo LHM_DEPLOY_DONE:%errorlevel%"

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'cmd.exe'
        $psi.Arguments = "/k $cmdLine"
        $psi.WorkingDirectory = $workDir
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $proc.EnableRaisingEvents = $true

        $subPrefix = "LHMDeploy_$([guid]::NewGuid().ToString('N'))"
        $eventData = @{ TextBox = $textBox; StatusLbl = $statusLbl; RerunButton = $rerunButton; StopButton = $stopButton; SubPrefix = $subPrefix; Dlg = $dlg; MultiTarget = ($targets.Count -gt 1) }

        Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -SourceIdentifier "$subPrefix`_out" -MessageData $eventData -Action {
            if ($null -eq $Event.SourceEventArgs.Data -or $Event.MessageData.Dlg.IsDisposed) { return }
            $line = $Event.SourceEventArgs.Data
            if ($line -match '^LHM_DEPLOY_DONE:(\d+)$') {
                $code = [int]$Matches[1]
                $suffix = if ($Event.MessageData.MultiTarget) { ' - see output above for per-folder results' } else { '' }
                if ($code -lt 8) {
                    $Event.MessageData.StatusLbl.Text = "Deploy done (exit code $code)$suffix - shell still open below"
                    $Event.MessageData.StatusLbl.ForeColor = $script:Theme.Success
                } else {
                    $Event.MessageData.StatusLbl.Text = "Deploy failed (exit code $code)$suffix - shell still open below"
                    $Event.MessageData.StatusLbl.ForeColor = $script:Theme.Danger
                }
                $Event.MessageData.RerunButton.Enabled = $true
                return
            }
            $Event.MessageData.TextBox.AppendText($line + "`r`n")
        } | Out-Null
        Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -SourceIdentifier "$subPrefix`_err" -MessageData $eventData -Action {
            if ($null -ne $Event.SourceEventArgs.Data -and -not $Event.MessageData.Dlg.IsDisposed) {
                $Event.MessageData.TextBox.AppendText($Event.SourceEventArgs.Data + "`r`n")
            }
        } | Out-Null
        Register-ObjectEvent -InputObject $proc -EventName Exited -SourceIdentifier "$subPrefix`_exit" -MessageData $eventData -Action {
            $d = $Event.MessageData
            if (-not $d.Dlg.IsDisposed) {
                $d.StatusLbl.Text = 'Session closed'
                $d.StatusLbl.ForeColor = $script:Theme.TextDim
                $d.RerunButton.Enabled = $true
                $d.StopButton.Enabled = $false
            }
            $p = $d.SubPrefix
            Unregister-Event -SourceIdentifier "${p}_out" -ErrorAction SilentlyContinue
            Unregister-Event -SourceIdentifier "${p}_err" -ErrorAction SilentlyContinue
            Unregister-Event -SourceIdentifier "${p}_exit" -ErrorAction SilentlyContinue
        } | Out-Null

        [void]$proc.Start()
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()
        $currentProc = $proc
    }

    $rerunButton.Add_Click({ Start-DeployRun })
    $stopButton.Add_Click({
        if (-not $currentProc -or $currentProc.HasExited) { return }
        $stopButton.Enabled = $false
        $statusLbl.Text = 'Stopping...'
        $statusLbl.ForeColor = $script:Theme.Danger
        # Same taskkill /T /F approach as Stop-ProjectById - see the "Stop
        # Deploy" comment above for why this hard-kills the tree instead of
        # sending a real CTRL_C_EVENT. The Exited handler above still fires
        # once the process actually dies, which is what flips the buttons
        # back and prints "Session closed" - this click just triggers that.
        Invoke-TaskKill -ProcId $currentProc.Id | Out-Null
    })
    $dlg.Add_Shown({ Start-DeployRun })
    $dlg.Add_FormClosed({ if ($currentProc -and -not $currentProc.HasExited) { try { $currentProc.Kill() } catch {} } })
    $dlg.ShowDialog($form) | Out-Null
}

function Invoke-DeployForProject {
    # Entry point for both the row-detail "Deploy..." button and the
    # Deploy Manager picker. First run for a project prompts for its recipe
    # (Show-DeployConfigDialog); every run after that reuses the saved one.
    # -Port is display-only (which port row this recipe is attached to,
    # for Show-DeployRunDialog's header - it's not itself part of the
    # recipe, since the actual build folder can be a different one, see
    # Show-DeployConfigDialog).
    param([string]$ProjectPath, [string]$Label, [string]$Port)
    if (-not $ProjectPath) {
        [System.Windows.Forms.MessageBox]::Show('No known project path for this port.', 'Cannot Deploy', 'OK', 'Warning') | Out-Null
        return
    }
    $key = Get-NormalizedPath $ProjectPath
    $config = $script:DeployDefs[$key]
    if (-not $config) {
        $config = Show-DeployConfigDialog -ProjectPath $ProjectPath -Label $Label
        if (-not $config) { return }
    }
    Show-DeployRunDialog -ProjectPath $ProjectPath -Label $Label -Port $Port -Config $config
}

function Show-DeployManagerDialog {
    # What the toolbar Deploy button opens: every tracked port (live +
    # remembered history, ignoring the main window's own Group/root-dir
    # scoping - this picker filters independently), filterable by group or
    # by a port range, so a deploy recipe can be attached to any project,
    # not just ones already configured.
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Build & Deploy'
    $dlg.Size = New-Object System.Drawing.Size(760, 560)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimumSize = New-Object System.Drawing.Size(560, 360)
    $dlg.BackColor = $script:Theme.WindowBg
    $dlg.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9)
    Set-DarkTitleBar -FormControl $dlg

    $filterPanel = New-Object System.Windows.Forms.Panel
    $filterPanel.Dock = 'Top'
    # Taller than the row of controls strictly needs, on purpose - the
    # "Selected port" label's top edge got visually clipped when this was
    # sized tight to the controls, and a fixed exact-fit height is exactly
    # the kind of guess that keeps breaking under a different font/theme
    # (Terminal's monospace metrics again). Generous fixed padding here
    # costs nothing and heads that class of bug off for every row added to
    # this panel in the future, not just the current ones.
    $filterPanel.Height = 60
    $filterPanel.BackColor = $script:Theme.PanelBg
    # Set before adding the Top,Right-anchored $selectedLbl below, or its
    # anchor baseline gets computed against the panel's tiny un-docked
    # default width instead of the dialog's real one, and it ends up
    # nowhere near the right edge once Dock actually resizes the panel -
    # same fix already applied to topPanel/BottomBar elsewhere in this file.
    $filterPanel.Width = $dlg.ClientSize.Width

    # Every X position below is measured against the actual label text at
    # the dialog's real font, not guessed - a fixed guessed gap (or worse, a
    # fixed-width Label box) is exactly what produced both spacing bugs
    # here before this: "Port from:" wrapping inside too narrow a box, then
    # "Group:"/"Port range:" crowding straight into the control after them
    # because the guessed gap was too small for how they actually render.
    $filterFont = $dlg.Font
    $pad = 12
    $x = 10

    $groupLbl = New-Object System.Windows.Forms.Label
    $groupLbl.Text = 'Group:'
    $groupLbl.AutoSize = $true
    $groupLbl.Location = New-Object System.Drawing.Point($x, 23)
    $groupLbl.ForeColor = $script:Theme.TextDim
    $x += [System.Windows.Forms.TextRenderer]::MeasureText($groupLbl.Text, $filterFont).Width + $pad

    $groupCombo = New-Object System.Windows.Forms.ComboBox
    $groupCombo.DropDownStyle = 'DropDownList'
    $groupCombo.Location = New-Object System.Drawing.Point($x, 18)
    $groupCombo.Size = New-Object System.Drawing.Size(160, 24)
    [void]$groupCombo.Items.Add('All Groups')
    foreach ($gName in ($script:Groups.Keys | Sort-Object)) { [void]$groupCombo.Items.Add($gName) }
    $groupCombo.SelectedIndex = 0
    $x += $groupCombo.Width + ($pad * 2)

    $rangeLbl = New-Object System.Windows.Forms.Label
    $rangeLbl.Text = 'Port range:'
    $rangeLbl.AutoSize = $true
    $rangeLbl.Location = New-Object System.Drawing.Point($x, 23)
    $rangeLbl.ForeColor = $script:Theme.TextDim
    $x += [System.Windows.Forms.TextRenderer]::MeasureText($rangeLbl.Text, $filterFont).Width + $pad

    $portMinBox = New-Object System.Windows.Forms.TextBox
    $portMinBox.Location = New-Object System.Drawing.Point($x, 18)
    $portMinBox.Size = New-Object System.Drawing.Size(60, 24)
    $portMinBox.BorderStyle = 'FixedSingle'
    $portMinBox.BackColor = $script:Theme.CardBg
    $portMinBox.ForeColor = $script:Theme.TextPrimary
    $x += $portMinBox.Width + $pad

    $dashLbl = New-Object System.Windows.Forms.Label
    $dashLbl.Text = '-'
    $dashLbl.AutoSize = $true
    $dashLbl.Location = New-Object System.Drawing.Point($x, 23)
    $dashLbl.ForeColor = $script:Theme.TextDim
    $x += [System.Windows.Forms.TextRenderer]::MeasureText($dashLbl.Text, $filterFont).Width + $pad

    $portMaxBox = New-Object System.Windows.Forms.TextBox
    $portMaxBox.Location = New-Object System.Drawing.Point($x, 18)
    $portMaxBox.Size = New-Object System.Drawing.Size(60, 24)
    $portMaxBox.BorderStyle = 'FixedSingle'
    $portMaxBox.BackColor = $script:Theme.CardBg
    $portMaxBox.ForeColor = $script:Theme.TextPrimary

    $selectedLbl = New-Object System.Windows.Forms.Label
    $selectedLbl.Text = 'Selected port: -'
    $selectedLbl.AutoSize = $true
    $selectedLbl.Anchor = 'Top,Right'
    $selectedLbl.ForeColor = $script:Theme.Accent
    $selectedLbl.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9, [System.Drawing.FontStyle]::Bold)
    # X is a placeholder - AutoSize plus the Top,Right anchor repositions
    # it against the dialog's real width the moment it's parented/shown,
    # same fix as the rest of this row: never trust a guessed X for text
    # whose rendered width depends on the active theme's font. Pulled left
    # of the panel's true right edge (rather than flush against it) so it
    # doesn't crowd the window's edge/border.
    $selectedLbl.Location = New-Object System.Drawing.Point(520, 23)

    [System.Windows.Forms.Control[]]$filterControls = @($groupLbl, $groupCombo, $rangeLbl, $portMinBox, $dashLbl, $portMaxBox, $selectedLbl)
    $filterPanel.Controls.AddRange($filterControls)

    $list = New-Object System.Windows.Forms.ListView
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.MultiSelect = $false
    $list.Dock = 'Fill'
    $list.BackColor = $script:Theme.CardBg
    $list.ForeColor = $script:Theme.TextPrimary
    [void]$list.Columns.Add('Port', 70)
    [void]$list.Columns.Add('Name', 130)
    [void]$list.Columns.Add('Status', 60)
    [void]$list.Columns.Add('Process', 80)
    [void]$list.Columns.Add('Deploy', 60)
    [void]$list.Columns.Add('Project Path', 260)

    function Update-DeployManagerList {
        $list.Items.Clear()
        $selectedGroup = [string]$groupCombo.SelectedItem
        $groupPaths = if ($selectedGroup -and $selectedGroup -ne 'All Groups' -and $script:Groups.ContainsKey($selectedGroup)) {
            [System.Collections.Generic.HashSet[string]]::new([string[]]@($script:Groups[$selectedGroup] | ForEach-Object { Get-NormalizedPath $_ }))
        } else { $null }
        $minPort = 0; [void][int]::TryParse($portMinBox.Text, [ref]$minPort)
        $maxPort = [int]::MaxValue
        if ($portMaxBox.Text) { [void][int]::TryParse($portMaxBox.Text, [ref]$maxPort); if ($maxPort -eq 0) { $maxPort = [int]::MaxValue } }

        $rows = @(Build-Rows -OnlyNode $false -RootDir '') | Where-Object { $_.ProjectPath }
        foreach ($r in $rows) {
            $portNum = 0; [void][int]::TryParse([string]$r.Port, [ref]$portNum)
            if ($portNum -lt $minPort -or $portNum -gt $maxPort) { continue }
            if ($groupPaths -and -not $groupPaths.Contains((Get-NormalizedPath $r.ProjectPath))) { continue }

            $displayName = if ($r.CustomName) { $r.CustomName } else { Split-Path -Leaf $r.ProjectPath }
            $hasDeploy = if ($script:DeployDefs.ContainsKey((Get-NormalizedPath $r.ProjectPath))) { 'Yes' } else { 'No' }

            $item = New-Object System.Windows.Forms.ListViewItem([string]$r.Port)
            [void]$item.SubItems.Add($displayName)
            [void]$item.SubItems.Add([string]$r.Status)
            [void]$item.SubItems.Add([string]$r.ProcessName)
            [void]$item.SubItems.Add($hasDeploy)
            [void]$item.SubItems.Add([string]$r.ProjectPath)
            $item.Tag = @{ ProjectPath = $r.ProjectPath; Label = $displayName; Port = [string]$r.Port }
            [void]$list.Items.Add($item)
        }
    }

    $groupCombo.Add_SelectedIndexChanged({ Update-DeployManagerList })
    $portMinBox.Add_TextChanged({ Update-DeployManagerList })
    $portMaxBox.Add_TextChanged({ Update-DeployManagerList })
    $list.Add_SelectedIndexChanged({
        $selectedLbl.Text = if ($list.SelectedItems.Count -gt 0) { "Selected port: $($list.SelectedItems[0].Tag.Port)" } else { 'Selected port: -' }
    })

    $bottomPanel = New-Object System.Windows.Forms.Panel
    $bottomPanel.Dock = 'Bottom'
    $bottomPanel.Height = 40
    $bottomPanel.BackColor = $script:Theme.PanelBg

    $deployBtn = New-Object System.Windows.Forms.Button
    $deployBtn.Text = 'Deploy'
    $deployBtn.Location = New-Object System.Drawing.Point(10, 6)
    $deployBtn.Size = New-Object System.Drawing.Size(90, 28)
    $deployBtn.Add_Click({
        # Deliberately no .GetNewClosure() here (or on Configure below) -
        # this button is created once, not inside a loop, so it doesn't
        # need a snapshotted copy of $list; it needs the LIVE enclosing
        # scope, the same as $rerunButton.Add_Click({ Start-DeployRun }) in
        # Show-DeployRunDialog. GetNewClosure() creates an isolated scope
        # that only carries variables, not nested `function`s defined in
        # the enclosing scope - Configure's click handler used to call
        # Update-DeployManagerList (a nested function, right below) and
        # threw "term not recognized" because of exactly this.
        if ($list.SelectedItems.Count -eq 0) { return }
        $sel = $list.SelectedItems[0].Tag
        Invoke-DeployForProject -ProjectPath $sel.ProjectPath -Label $sel.Label -Port $sel.Port
    })
    Initialize-ModernButton -Button $deployBtn -Variant Accent

    $configureBtn = New-Object System.Windows.Forms.Button
    $configureBtn.Text = 'Configure...'
    $configureBtn.Location = New-Object System.Drawing.Point(108, 6)
    $configureBtn.Size = New-Object System.Drawing.Size(100, 28)
    $configureBtn.Add_Click({
        if ($list.SelectedItems.Count -eq 0) { return }
        $sel = $list.SelectedItems[0].Tag
        Show-DeployConfigDialog -ProjectPath $sel.ProjectPath -Label $sel.Label | Out-Null
        Update-DeployManagerList
    })
    Initialize-ModernButton -Button $configureBtn

    $closeBtn = New-Object System.Windows.Forms.Button
    $closeBtn.Text = 'Close'
    $closeBtn.Anchor = 'Top,Right'
    $closeBtn.Location = New-Object System.Drawing.Point(660, 6)
    $closeBtn.Size = New-Object System.Drawing.Size(80, 28)
    $closeBtn.Add_Click({ $dlg.Close() })
    Initialize-ModernButton -Button $closeBtn

    [System.Windows.Forms.Control[]]$bottomControls = @($deployBtn, $configureBtn, $closeBtn)
    $bottomPanel.Controls.AddRange($bottomControls)

    $dlg.Controls.Add($list)
    $dlg.Controls.Add($filterPanel)
    $dlg.Controls.Add($bottomPanel)

    Update-DeployManagerList
    $dlg.ShowDialog($form) | Out-Null
}

function Get-RowDetailFields {
    # What to show in the Detail popup, and in what order - kept separate
    # from the actual panel/control layout in Show-RowDetail below, since
    # this part is pure data shaping (no WinForms objects touched at all):
    # given a row, decide which fields exist and what their display value
    # is.
    param($Data)
    $fields = @()

    # Auto-restart only makes sense for a real project (Start-ProjectAtPath
    # needs a ProjectPath to relaunch) - System-tab rows and bare unresolved
    # ports never get this row. Placed first since it's the one live,
    # clickable control in the popup rather than read-only information.
    if ($Data.ProjectPath) {
        $fields += @{ Label = 'Auto-Restart'; Value = [bool]$Data.AutoRestart; IsVirtual = $false }
    }

    $fields += @(
        @{ Label = 'Status';      Value = [string]$Data.Status;      IsVirtual = $false }
        @{ Label = 'Port';        Value = [string]$Data.Port;        IsVirtual = $false }
        @{ Label = 'Pinned';      Value = if ($Data.Pinned) { 'Yes' } else { 'No' }; IsVirtual = $false }
        @{ Label = 'Custom Name'; Value = [string]$Data.CustomName;  IsVirtual = $false }
    )

    # $null (health check off, or not an npm/node project) shows nothing -
    # only a completed probe (true/false) is worth a row here.
    if ($null -ne $Data.Responding) {
        $fields += @{ Label = 'Responding'; Value = if ($Data.Responding) { 'Yes' } else { 'No - listening but not answering HTTP requests' }; IsVirtual = $false }
    }

    $fields += @(
        @{ Label = 'Process';     Value = [string]$Data.ProcessName; IsVirtual = $false }
        @{ Label = 'PID';         Value = [string]$Data.ProcId;      IsVirtual = $false }
        @{ Label = 'CPU';         Value = if ($null -ne $Data.Cpu) { "$($Data.Cpu)%" } else { '' }; IsVirtual = $false }
        @{ Label = 'RAM';         Value = if ($null -ne $Data.Mem) { "$($Data.Mem) MB" } else { '' }; IsVirtual = $false }
        @{ Label = 'Local URL';   Value = [string]$Data.LocalUrl;    IsVirtual = $false }
    )

    $proxyUrl = if ($Data.Status -eq 'ON') { Get-ProxyUrlForPort -Port $Data.Port } else { $null }
    if ($proxyUrl) {
        $fields += @{ Label = 'Local Domain'; Value = $proxyUrl; IsVirtual = $false }
    }

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

    return $fields
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
    $fields = Get-RowDetailFields -Data $Data

    $rowHeight = 28
    $topMargin = 8
    $dlgWidth = 420
    $clientHeight = $topMargin + ($fields.Count * $rowHeight) + 38
    $purpleBg = if ($script:Theme.IsDark) { [System.Drawing.Color]::FromArgb(0x3A, 0x2E, 0x47) } else { [System.Drawing.Color]::FromArgb(0xEA, 0xDD, 0xF7) }
    $purpleAccent = if ($script:Theme.IsDark) { [System.Drawing.Color]::FromArgb(0xC7, 0x9A, 0xF0) } else { [System.Drawing.Color]::FromArgb(0x6A, 0x1B, 0x9A) }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Details - $label"
    $dlg.ClientSize = New-Object System.Drawing.Size($dlgWidth, $clientHeight)
    $dlg.StartPosition = 'Manual'
    $dlg.FormBorderStyle = 'FixedToolWindow'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $script:Theme.WindowBg
    $dlg.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9)
    Set-DarkTitleBar -FormControl $dlg

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

        # Auto-Restart is the one live, clickable control in an otherwise
        # read-only sticky-note popup - a real CheckBox instead of the
        # usual label/value/copy-button triple, wired straight to
        # Invoke-ToggleAutoRestart (same history.json-backed toggle Pin
        # uses). Checked is set before the event is wired so the initial
        # render doesn't fire a spurious toggle.
        if ($f.Label -eq 'Auto-Restart') {
            $chk = New-Object System.Windows.Forms.CheckBox
            $chk.Text = 'Auto Crash Restart'
            $chk.AutoSize = $false
            $chk.Location = New-Object System.Drawing.Point(10, 5)
            $chk.Size = New-Object System.Drawing.Size(($dlgWidth - 20), 20)
            $chk.ForeColor = $script:Theme.TextPrimary
            $chk.BackColor = [System.Drawing.Color]::Transparent
            $chk.Checked = [bool]$f.Value
            $capturedData = $Data
            $chk.Add_CheckedChanged({ Invoke-ToggleAutoRestart $capturedData }.GetNewClosure())
            $rowPanel.Controls.Add($chk)
            $rowPanels += $rowPanel
            [void]$allValuesText.AppendLine("Auto-Restart: $(if ($f.Value) { 'Yes' } else { 'No' })")
            $rowY += $rowHeight
            continue
        }

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = "$($f.Label):"
        $lbl.Location = New-Object System.Drawing.Point(10, 6)
        $lbl.Size = New-Object System.Drawing.Size(88, 16)
        $lbl.ForeColor = if ($f.IsVirtual) { $purpleAccent } else { $script:Theme.TextDim }
        $lbl.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 8, [System.Drawing.FontStyle]::Bold)
        $lbl.BackColor = [System.Drawing.Color]::Transparent

        # "Local URL" opens in the default browser on click - the only field
        # that's always a real, reachable http(s) URL (network entries can
        # be virtual-adapter/unreachable addresses, so those stay plain text).
        if ($f.Label -in @('Local URL', 'Local Domain') -and $f.Value -match '^https?://') {
            $valueLbl = New-Object System.Windows.Forms.LinkLabel
            $valueLbl.LinkColor = $script:Theme.Accent
            $valueLbl.ActiveLinkColor = $script:Theme.AccentDark
            $valueLbl.LinkBehavior = 'HoverUnderline'
            $capturedUrl = $f.Value
            $valueLbl.Add_LinkClicked({ try { Start-Process $capturedUrl } catch {} }.GetNewClosure())
        } else {
            $valueLbl = New-Object System.Windows.Forms.Label
            $valueLbl.ForeColor = $script:Theme.TextPrimary
        }
        $valueLbl.Text = $f.Value
        $valueLbl.AutoEllipsis = $true
        $valueLbl.Location = New-Object System.Drawing.Point(100, 6)
        $valueLbl.Size = New-Object System.Drawing.Size(($dlgWidth - 100 - 42), 16)
        $valueLbl.BackColor = [System.Drawing.Color]::Transparent

        $copyBtn = New-Object System.Windows.Forms.Button
        $copyBtn.Location = New-Object System.Drawing.Point(($dlgWidth - 34), 0)
        $copyBtn.Size = New-Object System.Drawing.Size(26, 26)
        $capturedValue = $f.Value
        $copyBtn.Add_Click({ if ($capturedValue) { [System.Windows.Forms.Clipboard]::SetText($capturedValue) } }.GetNewClosure())
        # Text must be set before Initialize-ModernButton - it owner-draws
        # from Tag.DisplayText, which is snapshotted from .Text at init time,
        # so setting .Text afterward silently left the glyph blank.
        $copyBtn.Text = [string][char]0xE8C8
        Initialize-ModernButton -Button $copyBtn -Radius (Get-ThemedRadius 6)
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
    if ($Data.ProjectPath) {
        $capturedPath = $Data.ProjectPath
        $capturedLabel = $label
        $capturedPort = [string]$Data.Port

        # C-Deploy ("Configure Deploy") always opens the recipe editor,
        # whether or not one exists yet - it never runs anything itself.
        # Separate from Deploy below so "set up/change the recipe" and
        # "actually build and copy" are two distinct, unambiguous actions
        # instead of one button that means different things depending on
        # whether a recipe happens to exist yet.
        $configDeployButton = New-Object System.Windows.Forms.Button
        $configDeployButton.Text = 'C-Deploy'
        $configDeployButton.Location = New-Object System.Drawing.Point(94, 3)
        $configDeployButton.Size = New-Object System.Drawing.Size(78, 26)
        $configDeployButton.Add_Click({ Show-DeployConfigDialog -ProjectPath $capturedPath -Label $capturedLabel | Out-Null }.GetNewClosure())
        Initialize-ModernButton -Button $configDeployButton
        $bottomControls += $configDeployButton

        $deployButton = New-Object System.Windows.Forms.Button
        $deployButton.Text = 'Deploy'
        $deployButton.Location = New-Object System.Drawing.Point(180, 3)
        $deployButton.Size = New-Object System.Drawing.Size(70, 26)
        $deployButton.Add_Click({ Invoke-DeployForProject -ProjectPath $capturedPath -Label $capturedLabel -Port $capturedPort }.GetNewClosure())
        Initialize-ModernButton -Button $deployButton -Variant Accent
        $bottomControls += $deployButton
    }
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
    $dlg.BackColor = $script:Theme.WindowBg
    $dlg.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9)
    Set-DarkTitleBar -FormControl $dlg

    $iconBox = New-Object System.Windows.Forms.PictureBox
    # System.Drawing.Icon's own pixel data is corrupted for this file
    # (confirmed: both .ToBitmap() and Graphics.DrawIcon on the same Icon
    # object produce identical colored static) - Get-AppIconBitmap sidesteps
    # the Icon class entirely and decodes the .ico's embedded PNG frame
    # directly, which renders correctly.
    $iconBmp = Get-AppIconBitmap -FileName 'LocalhostManager.ico' -Size 48
    if ($iconBmp) { $iconBox.Image = $iconBmp }
    $iconBox.SizeMode = 'CenterImage'
    $iconBox.Location = New-Object System.Drawing.Point(20, 24)
    $iconBox.Size = New-Object System.Drawing.Size(48, 48)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = 'Localhost Manager'
    $titleLabel.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 13, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = $script:Theme.TextPrimary
    $titleLabel.Location = New-Object System.Drawing.Point(80, 24)
    $titleLabel.Size = New-Object System.Drawing.Size(270, 28)

    $versionLabel = New-Object System.Windows.Forms.Label
    $versionLabel.Text = "Version $script:AppVersion"
    $versionLabel.ForeColor = $script:Theme.TextDim
    $versionLabel.Location = New-Object System.Drawing.Point(80, 54)
    $versionLabel.Size = New-Object System.Drawing.Size(270, 20)

    [System.Windows.Forms.Control[]]$dlgExtraControls = @()
    if ($script:UpdateAvailable -and $script:UpdateLatestVersion) {
        $updateLabel = New-Object System.Windows.Forms.LinkLabel
        $updateLabel.Text = "Update available: v$script:UpdateLatestVersion - click to download"
        $updateLabel.LinkColor = $script:Theme.Accent
        $updateLabel.ActiveLinkColor = $script:Theme.AccentDark
        $updateLabel.Location = New-Object System.Drawing.Point(20, 188)
        $updateLabel.Size = New-Object System.Drawing.Size(330, 20)
        $updateLabel.Add_LinkClicked({ try { Start-Process $script:UpdateUrl } catch {} })
        $dlgExtraControls += $updateLabel
    }

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

    [System.Windows.Forms.Control[]]$dlgControls = @($iconBox, $titleLabel, $versionLabel, $descLabel, $linkLabel, $closeButton) + $dlgExtraControls
    $dlg.Controls.AddRange($dlgControls)
    $dlg.AcceptButton = $closeButton
    $dlg.ShowDialog($form) | Out-Null
}

function Show-UpdateCheckDialog {
    # Opens immediately on click with an animated "Checking..." state, then
    # resolves itself in place once the background check lands - replaces
    # the old behavior where clicking "Check for Updates..." gave no
    # feedback at all until a MessageBox appeared several seconds later
    # (or never, if it silently failed).
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Check for Updates'
    $dlg.Size = New-Object System.Drawing.Size(360, 170)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Icon = $script:IconOk
    $dlg.BackColor = $script:Theme.WindowBg
    $dlg.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9)
    Set-DarkTitleBar -FormControl $dlg

    $spinner = New-Object System.Windows.Forms.Label
    $spinner.Text = ([char]0x25CF)
    $spinner.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 14)
    $spinner.ForeColor = $script:Theme.Accent
    $spinner.Location = New-Object System.Drawing.Point(20, 22)
    $spinner.Size = New-Object System.Drawing.Size(30, 30)
    $spinner.TextAlign = 'MiddleCenter'

    $statusLbl = New-Object System.Windows.Forms.Label
    $statusLbl.Text = 'Checking for updates'
    $statusLbl.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 11)
    $statusLbl.ForeColor = $script:Theme.TextPrimary
    $statusLbl.Location = New-Object System.Drawing.Point(60, 20)
    $statusLbl.Size = New-Object System.Drawing.Size(270, 26)

    $detailLbl = New-Object System.Windows.Forms.Label
    $detailLbl.Text = "You're on v$script:AppVersion"
    $detailLbl.ForeColor = $script:Theme.TextDim
    $detailLbl.Location = New-Object System.Drawing.Point(60, 48)
    $detailLbl.Size = New-Object System.Drawing.Size(270, 20)

    $actionButton = New-Object System.Windows.Forms.Button
    $actionButton.Text = 'Close'
    $actionButton.Location = New-Object System.Drawing.Point(245, 100)
    $actionButton.Size = New-Object System.Drawing.Size(85, 28)
    Initialize-ModernButton -Button $actionButton -Variant Accent
    $actionButton.Add_Click({ $dlg.Close() })

    $dlg.Controls.AddRange(@($spinner, $statusLbl, $detailLbl, $actionButton))
    $dlg.AcceptButton = $actionButton

    # Pulses the dot's opacity via foreground color lerp between the accent
    # color and the window background - a cheap "still working" heartbeat
    # that doesn't need a sprite sheet or GDI+ arc-drawing timer.
    #
    # Theme colors are pulled into local variables *before* GetNewClosure()
    # rather than read as $script:Theme.X from inside the closure - chaining
    # a dotted member-access off a script-scope variable inside a
    # GetNewClosure()'d scriptblock intermittently throws "Cannot convert
    # null to type System.Drawing.Color" on the property setter, even though
    # $script:Theme.X is never actually null. Snapshotting the value first
    # sidesteps whatever closure-scope resolution bug causes that.
    $accentColor = $script:Theme.Accent
    $windowBgColor = $script:Theme.WindowBg
    $dangerColor = $script:Theme.Danger
    $successColor = $script:Theme.Success

    $pulseStep = 0
    $animTimer = New-Object System.Windows.Forms.Timer
    $animTimer.Interval = 90
    $animTimer.Add_Tick({
        $pulseStep = ($pulseStep + 1) % 20
        $t = if ($pulseStep -le 10) { $pulseStep / 10.0 } else { (20 - $pulseStep) / 10.0 }
        $a = $accentColor
        $bg = $windowBgColor
        $r = [int]($bg.R + ($a.R - $bg.R) * $t)
        $g = [int]($bg.G + ($a.G - $bg.G) * $t)
        $b = [int]($bg.B + ($a.B - $bg.B) * $t)
        $spinner.ForeColor = [System.Drawing.Color]::FromArgb($r, $g, $b)
    }.GetNewClosure())
    $animTimer.Start()

    $pollTimer = New-Object System.Windows.Forms.Timer
    $pollTimer.Interval = 150
    $pollTimer.Add_Tick({
        if ($script:UpdateCheckInFlight) { return }
        $pollTimer.Stop()
        $animTimer.Stop()
        if ($script:UpdateCheckError) {
            $spinner.Text = [char]0x2715
            $spinner.ForeColor = $dangerColor
            $statusLbl.Text = "Couldn't check for updates"
            $detailLbl.Text = $script:UpdateCheckError
        } elseif ($script:UpdateAvailable) {
            $spinner.Text = [char]0x2191
            $spinner.ForeColor = $accentColor
            $statusLbl.Text = "Update available: v$script:UpdateLatestVersion"
            $detailLbl.Text = "You're on v$script:AppVersion"
            $actionButton.Text = 'Download'
            $actionButton.Add_Click({ try { Start-Process $script:UpdateUrl } catch {}; $dlg.Close() })
        } else {
            $spinner.Text = [char]0x2713
            $spinner.ForeColor = $successColor
            $statusLbl.Text = "You're up to date"
            $detailLbl.Text = "Version $script:AppVersion is the latest release"
        }
    }.GetNewClosure())
    $pollTimer.Start()

    Start-UpdateCheck -Interactive
    $dlg.Add_FormClosed({ $animTimer.Stop(); $pollTimer.Stop() })
    $dlg.ShowDialog($form) | Out-Null
}

function New-SettingsSectionLabel {
    # Small bold section heading used to break up a settings tab without a
    # full GroupBox - matches the "Diagnostics" heading the dialog already
    # had, just reusable across every tab now that there are several.
    param([string]$Text, [int]$X, [int]$Y)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9, [System.Drawing.FontStyle]::Bold)
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size(300, 20)
    $l.ForeColor = $script:Theme.TextPrimary
    return $l
}

function Show-SettingsDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Settings'
    $dlg.Size = New-Object System.Drawing.Size(500, 430)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $script:Theme.WindowBg
    $dlg.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9)
    Set-DarkTitleBar -FormControl $dlg

    $tabs = New-CustomTabControl -Labels @('General', 'Appearance', 'Startup', 'Diagnostics')
    $tabs.Root.Location = New-Object System.Drawing.Point(12, 12)
    $tabs.Root.Size = New-Object System.Drawing.Size(464, 330)
    foreach ($p in $tabs.Pages) { $p.BackColor = $script:Theme.WindowBg }
    $tabs.Root.BackColor = $script:Theme.WindowBg

    $tabGeneral = $tabs.Pages[0]
    $tabAppearance = $tabs.Pages[1]
    $tabStartup = $tabs.Pages[2]
    $tabDiagnostics = $tabs.Pages[3]

    # --- General ------------------------------------------------------------
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Only show projects under this folder:'
    $lbl.Location = New-Object System.Drawing.Point(15, 15)
    $lbl.Size = New-Object System.Drawing.Size(400, 20)
    $lbl.ForeColor = $script:Theme.TextPrimary

    $pathBox = New-Object System.Windows.Forms.TextBox
    $pathBox.Text = $script:RootDir
    $pathBox.Location = New-Object System.Drawing.Point(15, 40)
    $pathBox.Size = New-Object System.Drawing.Size(315, 24)
    $pathBox.ReadOnly = $true
    $pathBox.BorderStyle = 'FixedSingle'
    $pathBox.BackColor = $script:Theme.CardBg
    $pathBox.ForeColor = $script:Theme.TextPrimary

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Text = 'Browse...'
    $browseButton.Location = New-Object System.Drawing.Point(340, 39)
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
    $systemPortsSwitch.Location = New-Object System.Drawing.Point(15, 121)

    $systemPortsLbl = New-Object System.Windows.Forms.Label
    $systemPortsLbl.Text = 'Show system-owned ports'
    $systemPortsLbl.Location = New-Object System.Drawing.Point(60, 121)
    $systemPortsLbl.Size = New-Object System.Drawing.Size(250, 20)
    $systemPortsLbl.ForeColor = $script:Theme.TextPrimary
    Connect-ToggleLabel -Switch $systemPortsSwitch -Label $systemPortsLbl

    $systemPortsHintLbl = New-Object System.Windows.Forms.Label
    $systemPortsHintLbl.Text = "Adds a System tab for ports owned by OS processes (System, svchost, lsass, ...) - e.g. a kernel http.sys listener shadowing a port you meant to use yourself. Read-only: nothing here can be stopped or restarted."
    $systemPortsHintLbl.Location = New-Object System.Drawing.Point(15, 147)
    $systemPortsHintLbl.Size = New-Object System.Drawing.Size(420, 48)
    $systemPortsHintLbl.ForeColor = $script:Theme.TextDim
    $systemPortsHintLbl.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 8)

    $healthCheckSwitch = New-ToggleSwitch -Checked ([bool]$script:Settings.HealthCheckEnabled)
    $healthCheckSwitch.Location = New-Object System.Drawing.Point(15, 205)

    $healthCheckLbl = New-Object System.Windows.Forms.Label
    $healthCheckLbl.Text = 'Health check (listening vs. responding)'
    $healthCheckLbl.Location = New-Object System.Drawing.Point(60, 205)
    $healthCheckLbl.Size = New-Object System.Drawing.Size(320, 20)
    $healthCheckLbl.ForeColor = $script:Theme.TextPrimary
    Connect-ToggleLabel -Switch $healthCheckSwitch -Label $healthCheckLbl

    $healthCheckHintLbl = New-Object System.Windows.Forms.Label
    $healthCheckHintLbl.Text = "A bound port doesn't prove the app behind it is actually working - a hung server still holds the socket. Sends a lightweight GET to each npm/node project's own address every ~4s; one that doesn't answer shows ON in amber instead of green."
    $healthCheckHintLbl.Location = New-Object System.Drawing.Point(15, 231)
    $healthCheckHintLbl.Size = New-Object System.Drawing.Size(420, 48)
    $healthCheckHintLbl.ForeColor = $script:Theme.TextDim
    $healthCheckHintLbl.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 8)

    $tabGeneral.Controls.AddRange(@($lbl, $pathBox, $browseButton, $clearButton, $systemPortsSwitch, $systemPortsLbl, $systemPortsHintLbl, $healthCheckSwitch, $healthCheckLbl, $healthCheckHintLbl))

    # --- Appearance -----------------------------------------------------------
    # Theme and Group Divider each get their own Panel: WinForms auto-groups
    # every RadioButton sharing an immediate Parent into one mutually
    # exclusive set, so having both trios directly under $tabAppearance meant
    # picking a divider style silently unchecked whichever Theme radio was
    # selected (and Save, reading an all-unchecked Theme group, quietly fell
    # back to Light).
    $themeSectionPanel = New-Object System.Windows.Forms.Panel
    $themeSectionPanel.Location = New-Object System.Drawing.Point(0, 0)
    $themeSectionPanel.Size = New-Object System.Drawing.Size(450, 160)
    $themeSectionPanel.BackColor = $script:Theme.WindowBg

    $themeLbl = New-SettingsSectionLabel -Text 'Theme' -X 15 -Y 15

    $themeLightRadio = New-Object System.Windows.Forms.RadioButton
    $themeLightRadio.Text = 'Light'
    $themeLightRadio.Location = New-Object System.Drawing.Point(18, 42)
    $themeLightRadio.Size = New-Object System.Drawing.Size(100, 22)
    $themeLightRadio.ForeColor = $script:Theme.TextPrimary
    $themeLightRadio.Checked = ($script:Settings.Theme -notin @('Dark', 'Terminal'))

    $themeDarkRadio = New-Object System.Windows.Forms.RadioButton
    $themeDarkRadio.Text = 'Dark'
    $themeDarkRadio.Location = New-Object System.Drawing.Point(18, 68)
    $themeDarkRadio.Size = New-Object System.Drawing.Size(100, 22)
    $themeDarkRadio.ForeColor = $script:Theme.TextPrimary
    $themeDarkRadio.Checked = ($script:Settings.Theme -eq 'Dark')

    $themeTerminalRadio = New-Object System.Windows.Forms.RadioButton
    $themeTerminalRadio.Text = 'Terminal'
    $themeTerminalRadio.Location = New-Object System.Drawing.Point(18, 94)
    $themeTerminalRadio.Size = New-Object System.Drawing.Size(100, 22)
    $themeTerminalRadio.ForeColor = $script:Theme.TextPrimary
    $themeTerminalRadio.Checked = ($script:Settings.Theme -eq 'Terminal')

    $themeHintLbl = New-Object System.Windows.Forms.Label
    $themeHintLbl.Text = 'Applies after a restart - you will be offered one automatically if you change this.'
    $themeHintLbl.Location = New-Object System.Drawing.Point(15, 124)
    $themeHintLbl.Size = New-Object System.Drawing.Size(420, 32)
    $themeHintLbl.ForeColor = $script:Theme.TextDim
    $themeHintLbl.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 8)

    $themeSectionPanel.Controls.AddRange(@($themeLbl, $themeLightRadio, $themeDarkRadio, $themeTerminalRadio, $themeHintLbl))

    $dividerSectionPanel = New-Object System.Windows.Forms.Panel
    $dividerSectionPanel.Location = New-Object System.Drawing.Point(0, 168)
    $dividerSectionPanel.Size = New-Object System.Drawing.Size(450, 90)
    $dividerSectionPanel.BackColor = $script:Theme.WindowBg

    $dividerLbl = New-SettingsSectionLabel -Text 'Group Divider' -X 15 -Y 0

    $dividerHairlineRadio = New-Object System.Windows.Forms.RadioButton
    $dividerHairlineRadio.Text = 'Thin line'
    $dividerHairlineRadio.Location = New-Object System.Drawing.Point(18, 27)
    $dividerHairlineRadio.Size = New-Object System.Drawing.Size(120, 22)
    $dividerHairlineRadio.ForeColor = $script:Theme.TextPrimary
    $dividerHairlineRadio.Checked = ($script:Settings.GroupDividerStyle -notin @('Dotted', 'Labeled'))

    $dividerDottedRadio = New-Object System.Windows.Forms.RadioButton
    $dividerDottedRadio.Text = 'Dotted line'
    $dividerDottedRadio.Location = New-Object System.Drawing.Point(148, 27)
    $dividerDottedRadio.Size = New-Object System.Drawing.Size(120, 22)
    $dividerDottedRadio.ForeColor = $script:Theme.TextPrimary
    $dividerDottedRadio.Checked = ($script:Settings.GroupDividerStyle -eq 'Dotted')

    $dividerLabeledRadio = New-Object System.Windows.Forms.RadioButton
    $dividerLabeledRadio.Text = 'Labeled'
    $dividerLabeledRadio.Location = New-Object System.Drawing.Point(278, 27)
    $dividerLabeledRadio.Size = New-Object System.Drawing.Size(120, 22)
    $dividerLabeledRadio.ForeColor = $script:Theme.TextPrimary
    $dividerLabeledRadio.Checked = ($script:Settings.GroupDividerStyle -eq 'Labeled')

    $dividerHintLbl = New-Object System.Windows.Forms.Label
    $dividerHintLbl.Text = 'How the rule between groups looks in the Live/History tables. "Labeled" names the group starting below it.'
    $dividerHintLbl.Location = New-Object System.Drawing.Point(15, 54)
    $dividerHintLbl.Size = New-Object System.Drawing.Size(420, 32)
    $dividerHintLbl.ForeColor = $script:Theme.TextDim
    $dividerHintLbl.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 8)

    $dividerSectionPanel.Controls.AddRange(@($dividerLbl, $dividerHairlineRadio, $dividerDottedRadio, $dividerLabeledRadio, $dividerHintLbl))

    $tabAppearance.Controls.AddRange(@($themeSectionPanel, $dividerSectionPanel))

    # --- Startup ----------------------------------------------------------
    $launchSwitch = New-ToggleSwitch -Checked ([bool]$script:Settings.LaunchAtStartup)
    $launchSwitch.Location = New-Object System.Drawing.Point(15, 15)

    $launchLbl = New-Object System.Windows.Forms.Label
    $launchLbl.Text = 'Launch at Windows startup'
    $launchLbl.Location = New-Object System.Drawing.Point(60, 15)
    $launchLbl.Size = New-Object System.Drawing.Size(300, 20)
    $launchLbl.ForeColor = $script:Theme.TextPrimary
    Connect-ToggleLabel -Switch $launchSwitch -Label $launchLbl

    $minimizedSwitch = New-ToggleSwitch -Checked ([bool]$script:Settings.StartMinimized)
    $minimizedSwitch.Location = New-Object System.Drawing.Point(15, 51)

    $minimizedLbl = New-Object System.Windows.Forms.Label
    $minimizedLbl.Text = 'Start minimized to tray'
    $minimizedLbl.Location = New-Object System.Drawing.Point(60, 51)
    $minimizedLbl.Size = New-Object System.Drawing.Size(300, 20)
    $minimizedLbl.ForeColor = $script:Theme.TextPrimary
    Connect-ToggleLabel -Switch $minimizedSwitch -Label $minimizedLbl

    $crashNotifSwitch = New-ToggleSwitch -Checked ([bool]$script:Settings.CrashNotifications)
    $crashNotifSwitch.Location = New-Object System.Drawing.Point(15, 87)

    $crashNotifLbl = New-Object System.Windows.Forms.Label
    $crashNotifLbl.Text = 'Notify me if a dev server crashes'
    $crashNotifLbl.Location = New-Object System.Drawing.Point(60, 87)
    $crashNotifLbl.Size = New-Object System.Drawing.Size(360, 20)
    $crashNotifLbl.ForeColor = $script:Theme.TextPrimary
    Connect-ToggleLabel -Switch $crashNotifSwitch -Label $crashNotifLbl

    $updateCheckSwitch = New-ToggleSwitch -Checked ([bool]$script:Settings.CheckForUpdates)
    $updateCheckSwitch.Location = New-Object System.Drawing.Point(15, 123)

    $updateCheckLbl = New-Object System.Windows.Forms.Label
    $updateCheckLbl.Text = 'Check for updates on startup'
    $updateCheckLbl.Location = New-Object System.Drawing.Point(60, 123)
    $updateCheckLbl.Size = New-Object System.Drawing.Size(300, 20)
    $updateCheckLbl.ForeColor = $script:Theme.TextPrimary
    Connect-ToggleLabel -Switch $updateCheckSwitch -Label $updateCheckLbl

    $autoRestartAttemptsLbl = New-Object System.Windows.Forms.Label
    $autoRestartAttemptsLbl.Text = 'Auto Crash Restart: max attempts'
    $autoRestartAttemptsLbl.Location = New-Object System.Drawing.Point(15, 163)
    $autoRestartAttemptsLbl.Size = New-Object System.Drawing.Size(280, 24)
    $autoRestartAttemptsLbl.ForeColor = $script:Theme.TextPrimary
    $autoRestartAttemptsLbl.TextAlign = 'MiddleLeft'

    $autoRestartAttemptsBox = New-Object System.Windows.Forms.NumericUpDown
    $autoRestartAttemptsBox.Location = New-Object System.Drawing.Point(300, 161)
    $autoRestartAttemptsBox.Size = New-Object System.Drawing.Size(70, 24)
    $autoRestartAttemptsBox.Minimum = 1
    $autoRestartAttemptsBox.Maximum = 50
    $autoRestartAttemptsBox.Value = [Math]::Max(1, [Math]::Min(50, [int]$script:Settings.AutoRestartMaxAttempts))
    $autoRestartAttemptsBox.BackColor = $script:Theme.CardBg
    $autoRestartAttemptsBox.ForeColor = $script:Theme.TextPrimary
    $autoRestartAttemptsBox.BorderStyle = 'FixedSingle'

    $autoRestartWindowLbl = New-Object System.Windows.Forms.Label
    $autoRestartWindowLbl.Text = '...within a rolling window of (minutes)'
    $autoRestartWindowLbl.Location = New-Object System.Drawing.Point(15, 199)
    $autoRestartWindowLbl.Size = New-Object System.Drawing.Size(280, 24)
    $autoRestartWindowLbl.ForeColor = $script:Theme.TextPrimary
    $autoRestartWindowLbl.TextAlign = 'MiddleLeft'

    $autoRestartWindowBox = New-Object System.Windows.Forms.NumericUpDown
    $autoRestartWindowBox.Location = New-Object System.Drawing.Point(300, 197)
    $autoRestartWindowBox.Size = New-Object System.Drawing.Size(70, 24)
    $autoRestartWindowBox.Minimum = 1
    $autoRestartWindowBox.Maximum = 120
    $autoRestartWindowBox.Value = [Math]::Max(1, [Math]::Min(120, [int]$script:Settings.AutoRestartWindowMinutes))
    $autoRestartWindowBox.BackColor = $script:Theme.CardBg
    $autoRestartWindowBox.ForeColor = $script:Theme.TextPrimary
    $autoRestartWindowBox.BorderStyle = 'FixedSingle'

    $tabStartup.Controls.AddRange(@($launchSwitch, $launchLbl, $minimizedSwitch, $minimizedLbl, $crashNotifSwitch, $crashNotifLbl, $updateCheckSwitch, $updateCheckLbl, $autoRestartAttemptsLbl, $autoRestartAttemptsBox, $autoRestartWindowLbl, $autoRestartWindowBox))

    # --- Diagnostics --------------------------------------------------------
    $logStats = Get-AppErrorLogStats
    $pillTone = if ($logStats.Count -gt 0) { 'Danger' } else { 'Success' }
    $pillText = if ($logStats.Count -gt 0) { "$($logStats.Count) logged" } else { 'All clear' }
    $diagPill = New-StatusPill -Text $pillText -Tone $pillTone
    $diagPill.Location = New-Object System.Drawing.Point(15, 16)

    $diagDescLbl = New-Object System.Windows.Forms.Label
    $diagDescLbl.Text = 'Startup failures, unhandled exceptions, and dev-server crashes are recorded automatically so you have something to check after the app misbehaves.'
    $diagDescLbl.Location = New-Object System.Drawing.Point(15, 46)
    $diagDescLbl.Size = New-Object System.Drawing.Size(420, 40)
    $diagDescLbl.ForeColor = $script:Theme.TextDim
    $diagDescLbl.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 8)

    $viewLogButton = New-Object System.Windows.Forms.Button
    $viewLogButton.Text = 'View Log'
    $viewLogButton.Location = New-Object System.Drawing.Point(15, 92)
    $viewLogButton.Size = New-Object System.Drawing.Size(95, 26)
    $viewLogButton.Add_Click({ Show-AppErrorLogViewer })
    Initialize-ModernButton -Button $viewLogButton

    $tabDiagnostics.Controls.AddRange(@($diagPill, $diagDescLbl, $viewLogButton))

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'OK'
    $okButton.Location = New-Object System.Drawing.Point(295, 355)
    $okButton.Size = New-Object System.Drawing.Size(85, 28)
    $okButton.Add_Click({ $dlg.Tag = 'OK'; $dlg.Close() })
    Initialize-ModernButton -Button $okButton -Variant Accent

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = New-Object System.Drawing.Point(385, 355)
    $cancelButton.Size = New-Object System.Drawing.Size(85, 28)
    $cancelButton.Add_Click({ $dlg.Close() })
    Initialize-ModernButton -Button $cancelButton

    $dlg.Controls.AddRange(@($tabs.Root, $okButton, $cancelButton))
    $dlg.AcceptButton = $okButton
    $dlg.ShowDialog($form) | Out-Null

    if ($dlg.Tag -eq 'OK') {
        $script:RootDir = $pathBox.Text
        $script:Settings.RootDir = $script:RootDir
        $script:Settings.ShowSystemPorts = Get-ToggleChecked $systemPortsSwitch

        $script:Settings.HealthCheckEnabled = Get-ToggleChecked $healthCheckSwitch
        # Read directly by the background poller thread every cycle (see
        # $script:LiveCache's own comment) - updating it here means
        # toggling the switch takes effect on the poller's next tick,
        # same "no restart needed" treatment as the Auto Crash Restart cap.
        $script:LiveCache.HealthCheckEnabled = [bool]$script:Settings.HealthCheckEnabled

        $newTheme = if ($themeTerminalRadio.Checked) { 'Terminal' } elseif ($themeDarkRadio.Checked) { 'Dark' } else { 'Light' }
        $themeChanged = $newTheme -ne $script:Settings.Theme
        $script:Settings.Theme = $newTheme

        $newLaunchAtStartup = Get-ToggleChecked $launchSwitch
        if ($newLaunchAtStartup -ne [bool]$script:Settings.LaunchAtStartup) { Set-LaunchAtStartup -Enable $newLaunchAtStartup }
        $script:Settings.LaunchAtStartup = $newLaunchAtStartup

        $script:Settings.StartMinimized = Get-ToggleChecked $minimizedSwitch
        $script:Settings.CrashNotifications = Get-ToggleChecked $crashNotifSwitch
        $script:Settings.CheckForUpdates = Get-ToggleChecked $updateCheckSwitch

        $script:Settings.GroupDividerStyle = if ($dividerLabeledRadio.Checked) { 'Labeled' } elseif ($dividerDottedRadio.Checked) { 'Dotted' } else { 'Hairline' }

        $script:Settings.AutoRestartMaxAttempts = [int]$autoRestartAttemptsBox.Value
        $script:Settings.AutoRestartWindowMinutes = [int]$autoRestartWindowBox.Value
        # Takes effect immediately, no restart needed - unlike Theme, this
        # isn't baked into anything already constructed at startup.
        $script:AutoRestartMaxAttempts = [int]$autoRestartAttemptsBox.Value
        $script:AutoRestartWindowMinutes = [int]$autoRestartWindowBox.Value

        Save-Settings $script:Settings
        Update-ScopeLabel
        Update-SystemTabState
        Refresh-Grid

        if ($themeChanged) {
            $restart = [System.Windows.Forms.MessageBox]::Show('Restart Localhost Manager now to apply the new theme?', 'Theme Changed', 'YesNo', 'Question')
            if ($restart -eq 'Yes') { Restart-App }
        }
    }
}

function Show-DashboardDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Dashboard'
    $dlg.Size = New-Object System.Drawing.Size(520, 340)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $script:Theme.WindowBg
    $dlg.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9)
    Set-DarkTitleBar -FormControl $dlg

    $introLbl = New-Object System.Windows.Forms.Label
    $introLbl.Text = 'View the current table and stop/restart projects from a browser, on this PC or (once you set up reachability) your LAN/Tailnet.'
    $introLbl.Location = New-Object System.Drawing.Point(15, 15)
    $introLbl.Size = New-Object System.Drawing.Size(475, 48)
    $introLbl.ForeColor = $script:Theme.TextDim

    $enableSwitch = New-ToggleSwitch -Checked ([bool]$script:Settings.DashboardEnabled)
    $enableSwitch.Location = New-Object System.Drawing.Point(15, 70)

    $enableLbl = New-Object System.Windows.Forms.Label
    $enableLbl.Text = 'Enable web dashboard'
    $enableLbl.Location = New-Object System.Drawing.Point(60, 70)
    $enableLbl.Size = New-Object System.Drawing.Size(250, 20)
    $enableLbl.ForeColor = $script:Theme.TextPrimary
    Connect-ToggleLabel -Switch $enableSwitch -Label $enableLbl

    $offByDefaultLbl = New-Object System.Windows.Forms.Label
    $offByDefaultLbl.Text = 'Off by default. Nothing listens on any port until you enable it here.'
    $offByDefaultLbl.Location = New-Object System.Drawing.Point(15, 96)
    $offByDefaultLbl.Size = New-Object System.Drawing.Size(475, 32)
    $offByDefaultLbl.ForeColor = $script:Theme.TextDim
    $offByDefaultLbl.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 8)

    $portLbl = New-Object System.Windows.Forms.Label
    $portLbl.Text = 'Port:'
    $portLbl.Location = New-Object System.Drawing.Point(15, 140)
    $portLbl.Size = New-Object System.Drawing.Size(55, 24)
    $portLbl.ForeColor = $script:Theme.TextPrimary
    $portLbl.TextAlign = 'MiddleLeft'

    $portBox = New-Object System.Windows.Forms.NumericUpDown
    $portBox.Location = New-Object System.Drawing.Point(75, 138)
    $portBox.Size = New-Object System.Drawing.Size(90, 24)
    $portBox.Minimum = 1024
    $portBox.Maximum = 65535
    $portBox.Value = [Math]::Max(1024, [Math]::Min(65535, [int]$script:Settings.WebPort))
    $portBox.Enabled = [bool]$script:Settings.DashboardEnabled
    $portBox.BackColor = $script:Theme.CardBg
    $portBox.ForeColor = $script:Theme.TextPrimary
    $portBox.BorderStyle = 'FixedSingle'

    Set-ToggleOnChange -Switch $enableSwitch -Handler {
        $portBox.Enabled = Get-ToggleChecked $enableSwitch
    }.GetNewClosure()

    $statusLbl = New-Object System.Windows.Forms.Label
    $statusLbl.Location = New-Object System.Drawing.Point(15, 172)
    $statusLbl.Size = New-Object System.Drawing.Size(475, 70)
    $statusLbl.ForeColor = $script:Theme.TextDim
    $statusLbl.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 8)
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
    $okButton.Location = New-Object System.Drawing.Point(315, 255)
    $okButton.Size = New-Object System.Drawing.Size(85, 28)
    $okButton.Add_Click({ $dlg.Tag = 'OK'; $dlg.Close() })
    Initialize-ModernButton -Button $okButton -Variant Accent

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = New-Object System.Drawing.Point(405, 255)
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

function Show-ProxyDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Local Domains'
    $dlg.Size = New-Object System.Drawing.Size(520, 470)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $script:Theme.WindowBg
    $dlg.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9)
    Set-DarkTitleBar -FormControl $dlg

    $introLbl = New-Object System.Windows.Forms.Label
    $introLbl.Text = "Give each running project a friendly address, e.g. http://my_project.localhost:$([int]$script:Settings.ProxyPort)/, instead of a raw port. Works from this PC's browser (Chrome/Edge/Firefox resolve *.localhost to loopback on their own) - not from other devices or non-browser tools like curl."
    $introLbl.Location = New-Object System.Drawing.Point(15, 15)
    $introLbl.Size = New-Object System.Drawing.Size(475, 56)
    $introLbl.ForeColor = $script:Theme.TextDim

    $enableSwitch = New-ToggleSwitch -Checked ([bool]$script:Settings.ProxyEnabled)
    $enableSwitch.Location = New-Object System.Drawing.Point(15, 78)

    $enableLbl = New-Object System.Windows.Forms.Label
    $enableLbl.Text = 'Enable Local Domains'
    $enableLbl.Location = New-Object System.Drawing.Point(60, 78)
    $enableLbl.Size = New-Object System.Drawing.Size(250, 20)
    $enableLbl.ForeColor = $script:Theme.TextPrimary
    Connect-ToggleLabel -Switch $enableSwitch -Label $enableLbl

    $offByDefaultLbl = New-Object System.Windows.Forms.Label
    $offByDefaultLbl.Text = 'Off by default. Nothing listens on any port until you enable it here.'
    $offByDefaultLbl.Location = New-Object System.Drawing.Point(15, 104)
    $offByDefaultLbl.Size = New-Object System.Drawing.Size(475, 20)
    $offByDefaultLbl.ForeColor = $script:Theme.TextDim
    $offByDefaultLbl.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 8)

    $portLbl = New-Object System.Windows.Forms.Label
    $portLbl.Text = 'Port:'
    $portLbl.Location = New-Object System.Drawing.Point(15, 138)
    $portLbl.Size = New-Object System.Drawing.Size(55, 24)
    $portLbl.ForeColor = $script:Theme.TextPrimary
    $portLbl.TextAlign = 'MiddleLeft'

    $portBox = New-Object System.Windows.Forms.NumericUpDown
    $portBox.Location = New-Object System.Drawing.Point(75, 136)
    $portBox.Size = New-Object System.Drawing.Size(90, 24)
    $portBox.Minimum = 1024
    $portBox.Maximum = 65535
    $portBox.Value = [Math]::Max(1024, [Math]::Min(65535, [int]$script:Settings.ProxyPort))
    $portBox.Enabled = [bool]$script:Settings.ProxyEnabled
    $portBox.BackColor = $script:Theme.CardBg
    $portBox.ForeColor = $script:Theme.TextPrimary
    $portBox.BorderStyle = 'FixedSingle'

    $setupLbl = New-SettingsSectionLabel -Text 'One-time setup (per port)' -X 15 -Y 172

    $cmdBox = New-Object System.Windows.Forms.TextBox
    $cmdBox.Location = New-Object System.Drawing.Point(15, 196)
    $cmdBox.Size = New-Object System.Drawing.Size(390, 24)
    $cmdBox.ReadOnly = $true
    $cmdBox.BackColor = $script:Theme.CardBg
    $cmdBox.ForeColor = $script:Theme.TextPrimary
    $cmdBox.BorderStyle = 'FixedSingle'
    $cmdBox.Text = "netsh http add urlacl url=http://+:$([int]$portBox.Value)/ user=Everyone"
    $portBox.Add_ValueChanged({ $cmdBox.Text = "netsh http add urlacl url=http://+:$([int]$portBox.Value)/ user=Everyone" }.GetNewClosure())

    $copyCmdButton = New-Object System.Windows.Forms.Button
    $copyCmdButton.Text = 'Copy'
    $copyCmdButton.Location = New-Object System.Drawing.Point(410, 195)
    $copyCmdButton.Size = New-Object System.Drawing.Size(80, 26)
    $copyCmdButton.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($cmdBox.Text) }.GetNewClosure())
    Initialize-ModernButton -Button $copyCmdButton

    $setupHintLbl = New-Object System.Windows.Forms.Label
    $setupHintLbl.Text = "Run this once as Administrator, then re-enable Local Domains here. Loopback-only - no firewall change, nothing reachable from other devices; it just lets this port bind without elevating every time."
    $setupHintLbl.Location = New-Object System.Drawing.Point(15, 226)
    $setupHintLbl.Size = New-Object System.Drawing.Size(475, 54)
    $setupHintLbl.ForeColor = $script:Theme.TextDim
    $setupHintLbl.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 8)

    $statusLbl = New-Object System.Windows.Forms.Label
    $statusLbl.Location = New-Object System.Drawing.Point(15, 288)
    $statusLbl.Size = New-Object System.Drawing.Size(475, 62)
    $statusLbl.ForeColor = $script:Theme.TextDim
    $statusLbl.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 8)
    if ($script:Settings.ProxyEnabled -and $script:ProxyCache.Listening) {
        $statusLbl.Text = "Currently running on port $($script:ProxyCache.Port). Open the Detail popup on any running project's row for its exact *.localhost address."
    } elseif ($script:Settings.ProxyEnabled -and $script:ProxyCache.ListenError) {
        $statusLbl.Text = "Enabled but failed to start: $($script:ProxyCache.ListenError)`nMost likely cause: the one-time setup command above hasn't been run yet for this port."
    } elseif ($script:Settings.ProxyEnabled) {
        $statusLbl.Text = 'Enabled, starting...'
    } else {
        $statusLbl.Text = 'Not running.'
    }

    Set-ToggleOnChange -Switch $enableSwitch -Handler {
        $portBox.Enabled = Get-ToggleChecked $enableSwitch
    }.GetNewClosure()

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'OK'
    $okButton.Location = New-Object System.Drawing.Point(315, 385)
    $okButton.Size = New-Object System.Drawing.Size(85, 28)
    $okButton.Add_Click({ $dlg.Tag = 'OK'; $dlg.Close() })
    Initialize-ModernButton -Button $okButton -Variant Accent

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = New-Object System.Drawing.Point(405, 385)
    $cancelButton.Size = New-Object System.Drawing.Size(85, 28)
    $cancelButton.Add_Click({ $dlg.Close() })
    Initialize-ModernButton -Button $cancelButton

    [System.Windows.Forms.Control[]]$dlgControls = @($introLbl, $enableSwitch, $enableLbl, $offByDefaultLbl, $portLbl, $portBox, $setupLbl, $cmdBox, $copyCmdButton, $setupHintLbl, $statusLbl, $okButton, $cancelButton)
    $dlg.Controls.AddRange($dlgControls)
    $dlg.AcceptButton = $okButton
    $dlg.ShowDialog($form) | Out-Null

    if ($dlg.Tag -eq 'OK') {
        $newEnabled = Get-ToggleChecked $enableSwitch
        $newPort = [int]$portBox.Value
        $wasEnabled = [bool]$script:Settings.ProxyEnabled
        $portChanged = $newPort -ne [int]$script:Settings.ProxyPort

        $script:Settings.ProxyEnabled = $newEnabled
        $script:Settings.ProxyPort = $newPort
        Save-Settings $script:Settings

        if ($newEnabled -and -not $wasEnabled) {
            Start-ProxyServer -Port $newPort
        } elseif (-not $newEnabled -and $wasEnabled) {
            Stop-ProxyServer
        } elseif ($newEnabled -and $wasEnabled -and $portChanged) {
            Restart-ProxyServer -Port $newPort
        }
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
    $dlg.Font = New-Object System.Drawing.Font($script:Theme.FontFamily, 9)
    Set-DarkTitleBar -FormControl $dlg

    $nameLabel = New-Object System.Windows.Forms.Label
    $nameLabel.Text = 'Group name:'
    $nameLabel.Location = New-Object System.Drawing.Point(15, 15)
    $nameLabel.Size = New-Object System.Drawing.Size(100, 20)
    $nameLabel.ForeColor = $script:Theme.TextPrimary

    $nameCombo = New-Object System.Windows.Forms.ComboBox
    $nameCombo.DropDownStyle = 'DropDown'
    $nameCombo.Location = New-Object System.Drawing.Point(15, 38)
    $nameCombo.Size = New-Object System.Drawing.Size(415, 24)
    $nameCombo.BackColor = $script:Theme.CardBg
    $nameCombo.ForeColor = $script:Theme.TextPrimary
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
    $projList.BackColor = $script:Theme.CardBg
    $projList.ForeColor = $script:Theme.TextPrimary

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
        $rowLabel = if ($row.CustomName) { $row.CustomName } else { Split-Path -Leaf $row.ProjectPath }
        if (-not (Test-PortCollision -ProjectPath $row.ProjectPath -Port ([int]$row.Port) -Label $rowLabel)) { continue }
        if (Start-ProjectAtPath -ProjectPath $row.ProjectPath -CommandLine $row.CommandLine) { $started++ }
    }
    Start-Sleep -Milliseconds 1000
    Refresh-Grid
    [System.Windows.Forms.MessageBox]::Show("Started $started of $($toStart.Count) project(s) in '$label'.", 'Start All', 'OK', 'Information') | Out-Null
}

function Stop-GroupAll {
    # -SkipConfirm is set by the Stop All button, which now gets its
    # confirmation from the inline arm/confirm morph (see Disarm-StopAllButton
    # below) instead of this blocking dialog. The per-group context-menu
    # item still calls this without -SkipConfirm, so it keeps the dialog.
    param([string[]]$Names, [switch]$SkipConfirm)

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
    if (-not $SkipConfirm) {
        $list = ($toStop | ForEach-Object { "$($_.ProcessName) (port $($_.Port))" }) -join "`n"
        $confirm = [System.Windows.Forms.MessageBox]::Show("Stop these $($toStop.Count) process(es)?`n`n$list", 'Confirm Stop All', 'YesNo', 'Warning')
        if ($confirm -ne 'Yes') { return }
    }

    $stopped = 0
    foreach ($row in $toStop) {
        if (Stop-ProjectById -ProcId $row.ProcId -ProjectPath $row.ProjectPath) { $stopped++ }
    }
    Refresh-Grid
    [System.Windows.Forms.MessageBox]::Show("Stopped $stopped of $($toStop.Count) process(es) in '$label'.", 'Stop All', 'OK', 'Information') | Out-Null
}

# Stop All is destructive, so it keeps a confirm step — but as an inline
# button morph (icon+text crossfade to a solid "Confirm?" state) instead of
# a blocking MessageBox, echoing the two-step delete-button pattern. First
# click arms it; a second click within 3s (or the button's own re-click)
# actually stops things. It auto-disarms on timeout, on losing window focus,
# or if the user starts something else from the toolbar first.
$script:StopAllArmed = $false
$script:StopAllDisarmTimer = New-Object System.Windows.Forms.Timer
$script:StopAllDisarmTimer.Interval = 3000

function Disarm-StopAllButton {
    if (-not $script:StopAllArmed) { return }
    $script:StopAllArmed = $false
    $script:StopAllDisarmTimer.Stop()
    $stopAllButton.Tag.SplitMode = $false
    Start-ButtonMorph -Button $stopAllButton -Icon 'Square' -Text 'Stop All' -Variant 'Danger'
}

function Enter-StopAllConfirmState {
    # Snaps straight into the split (cancel | confirm) render - no
    # crossfade, since Draw-ButtonContent's icon/text morph doesn't know how
    # to animate into two independently-clipped halves.
    $t = $stopAllButton.Tag
    $t.Icon = 'Check'
    $t.DisplayText = 'Confirm?'
    $t.PrevIcon = $null
    $t.PrevText = $null
    $t.AnimProgress = 1.0
    $t.SplitMode = $true
    $t.SplitAccent = $script:Theme.Danger
    $stopAllButton.Invalidate()
}

# Start All isn't destructive, but a misclick still spins up every stopped
# project in the group - same inline split-pill confirm as Stop All, just
# green instead of red, so backing out is as easy as getting into it.
$script:StartAllArmed = $false
$script:StartAllDisarmTimer = New-Object System.Windows.Forms.Timer
$script:StartAllDisarmTimer.Interval = 3000

function Disarm-StartAllButton {
    if (-not $script:StartAllArmed) { return }
    $script:StartAllArmed = $false
    $script:StartAllDisarmTimer.Stop()
    $startAllButton.Tag.SplitMode = $false
    Start-ButtonMorph -Button $startAllButton -Icon 'Play' -Text 'Start All' -Variant 'Success'
}

function Enter-StartAllConfirmState {
    $t = $startAllButton.Tag
    $t.Icon = 'Check'
    $t.DisplayText = 'Confirm?'
    $t.PrevIcon = $null
    $t.PrevText = $null
    $t.AnimProgress = 1.0
    $t.SplitMode = $true
    $t.SplitAccent = $script:Theme.Success
    $startAllButton.Invalidate()
}

$script:StopAllDisarmTimer.Add_Tick({ Disarm-StopAllButton })
$script:StartAllDisarmTimer.Add_Tick({ Disarm-StartAllButton })
$form.Add_Deactivate({ Disarm-StopAllButton; Disarm-StartAllButton })

$startAllButton.Add_Click({
    Disarm-StopAllButton
    if (-not $script:StartAllArmed) {
        $script:StartAllArmed = $true
        Enter-StartAllConfirmState
        $script:StartAllDisarmTimer.Stop()
        $script:StartAllDisarmTimer.Start()
        return
    }
    $clickedCancel = $startAllButton.Tag.LastMouseDownX -lt ($startAllButton.Width / 2.0)
    Disarm-StartAllButton
    if ($clickedCancel) { return }
    Start-GroupAll -Names $script:SelectedGroups
})
$stopAllButton.Add_Click({
    Disarm-StartAllButton
    if (-not $script:StopAllArmed) {
        $script:StopAllArmed = $true
        Enter-StopAllConfirmState
        $script:StopAllDisarmTimer.Stop()
        $script:StopAllDisarmTimer.Start()
        return
    }
    # Split pill is live: left half (X) cancels, right half (check) confirms.
    $clickedCancel = $stopAllButton.Tag.LastMouseDownX -lt ($stopAllButton.Width / 2.0)
    Disarm-StopAllButton
    if ($clickedCancel) { return }
    Stop-GroupAll -Names $script:SelectedGroups -SkipConfirm
})

# ---------------------------------------------------------------------------
# System tray
# ---------------------------------------------------------------------------
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayMenu.ShowImageMargin = $false
Enable-RoundedPopup -Popup $trayMenu
$trayMenu.ForeColor = $script:Theme.TextPrimary
if ($script:MenuRenderer) { $trayMenu.Renderer = $script:MenuRenderer }

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

$script:BalloonAction = $null
$notifyIcon.Add_BalloonTipClicked({
    if ($script:BalloonAction -eq 'Update' -and $script:UpdateUrl) { try { Start-Process $script:UpdateUrl } catch {} }
    $script:BalloonAction = $null
})

# Rebuild the menu items here, on MouseUp, rather than relying solely on
# ContextMenuStrip's own Opening event. NotifyIcon picks the popup's
# on-screen position (including whether to flip it above the cursor to
# clear the taskbar) using the strip's size at the moment it decides to
# show it, which happens right after this event — Opening fires too late,
# so if the item count grew since the last show (e.g. a project was
# added), the position was still computed from the old, shorter menu and
# the taller one ends up rendered partly behind the taskbar. Building here
# guarantees the strip is already its final size before that calculation.
$notifyIcon.Add_MouseUp({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { Build-TrayMenuItems }
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
            $groupItem.DropDown.ForeColor = $script:Theme.TextPrimary
            $groupItem.DropDown.ShowImageMargin = $false
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
        Stop-ProxyServer
    }
})

$refreshButton.Add_Click({ Disarm-StopAllButton; Disarm-StartAllButton; Refresh-Grid })
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
            Cpu         = $_.Row.Cpu
            Mem         = $_.Row.Mem
            LocalUrl    = $_.Row.LocalUrl
            LanUrls     = $_.Row.LanUrls
            LanEntries  = @($_.Row.LanEntries | ForEach-Object { [PSCustomObject]@{ Label = $_.Label; Url = $_.Url } })
            ProjectPath = $_.Row.ProjectPath
            HasLog      = [bool]$_.Row.HasLog
            CommandLine = $_.Row.CommandLine
            Responding  = $_.Row.Responding
        }
    })
    # -InputObject (not the pipeline) is required so a single-row result
    # still serializes as a one-element JSON array instead of Windows
    # PowerShell 5.1's ConvertTo-Json unwrapping it to a bare object.
    $script:DashboardCache.RowsJson = ConvertTo-Json -InputObject $dashRows -Depth 6
}

function Get-DashboardKnownHistoryEntry {
    # The dashboard has no login - anyone who can POST to it could otherwise
    # name an arbitrary ProjectPath/CommandLine and have Start-ProjectAtPath
    # run it verbatim. Never trust those two fields off the wire: look the
    # path up against history.json (what this app actually knows about) and
    # always re-derive CommandLine from that record, ignoring whatever the
    # request body claims it is.
    param([string]$ProjectPath)
    if (-not $ProjectPath) { return $null }
    $key = Get-NormalizedPath $ProjectPath
    foreach ($entry in (Load-History).Values) {
        if ((Get-NormalizedPath ([string]$entry.ProjectPath)) -eq $key) { return $entry }
    }
    return $null
}

function Test-DashboardKnownListener {
    # Same idea for Stop: without this, Stop-ProjectById's own safety-net
    # falls back to Stop-Process -Id <whatever PID the caller named> -Force
    # for any PID that doesn't match a process this app itself launched -
    # letting an unauthenticated caller kill an arbitrary process on the
    # machine. Require the PID to actually be the one this app's own scan
    # currently has recorded as listening for that project.
    param([string]$ProjectPath, [int]$ProcId)
    if (-not $ProjectPath -or -not $ProcId) { return $false }
    $key = Get-NormalizedPath $ProjectPath
    foreach ($l in (Get-LiveListeners).Values) {
        if ([int]$l.ProcId -eq $ProcId -and (Get-NormalizedPath ([string]$l.ProjectPath)) -eq $key) { return $true }
    }
    return $false
}

function Invoke-DashboardAction {
    param($Action)
    $result = @{ Ok = $false; Message = '' }
    try {
        switch ($Action.Type) {
            'stop' {
                if (-not (Test-DashboardKnownListener -ProjectPath $Action.ProjectPath -ProcId $Action.ProcId)) {
                    $result.Message = 'Unknown process - refusing to stop.'
                } elseif (Stop-ProjectById -ProcId $Action.ProcId -ProjectPath $Action.ProjectPath) {
                    $result.Ok = $true; $result.Message = 'Stopped.'
                } else {
                    $result.Message = 'Could not stop process.'
                }
            }
            'start' {
                $known = Get-DashboardKnownHistoryEntry -ProjectPath $Action.ProjectPath
                if (-not $known) {
                    $result.Message = 'Unknown project - refusing to start.'
                } elseif (Start-ProjectAtPath -ProjectPath $Action.ProjectPath -CommandLine ([string]$known.CommandLine)) {
                    $result.Ok = $true; $result.Message = 'Started.'
                } else {
                    $result.Message = 'Could not start project.'
                }
            }
            'restart' {
                $known = Get-DashboardKnownHistoryEntry -ProjectPath $Action.ProjectPath
                if (-not $known) {
                    $result.Message = 'Unknown project - refusing to restart.'
                } else {
                    $ok = $true
                    if ($Action.Status -eq 'ON') {
                        if (-not (Test-DashboardKnownListener -ProjectPath $Action.ProjectPath -ProcId $Action.ProcId)) {
                            $ok = $false
                            $result.Message = 'Unknown process - refusing to restart.'
                        } else {
                            $ok = Stop-ProjectById -ProcId $Action.ProcId -ProjectPath $Action.ProjectPath
                            if (-not $ok) { $result.Message = 'Could not stop process.' }
                            if ($ok) { Start-Sleep -Milliseconds 800 }
                        }
                    }
                    if ($ok) {
                        if (Start-ProjectAtPath -ProjectPath $Action.ProjectPath -CommandLine ([string]$known.CommandLine)) {
                            $result.Ok = $true; $result.Message = 'Restarted.'
                        } else {
                            $result.Message = 'Could not start project.'
                        }
                    }
                }
            }
            default { $result.Message = 'Unknown action.' }
        }
    } catch {
        # Never echo raw exception text back to an unauthenticated caller -
        # log the real detail server-side, return a generic message.
        Write-AppErrorLog -Context 'Dashboard action failed' -Exception $_.Exception
        $result.Message = 'Action failed - see the app for details.'
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

# One HTTP request per PowerShell instance, run against a pooled runspace -
# same fix, same reason, as the Local Domains proxy (see
# ProxyHandleRequestScript above): a plain accept-process-accept loop meant
# one client's Stop/Start/Restart click - which can legitimately block for
# up to 8s waiting on the UI thread to drain the action queue - froze the
# whole dashboard for every other visitor, including that same page's own
# 1.5s auto-refresh poll, until the click finished.
$script:DashboardHandleRequestScript = {
    param($Context, $Cache, $Html)

    $req = $Context.Request
    $res = $Context.Response
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
            $bodyParseFailed = $false
            try { $body = $bodyText | ConvertFrom-Json } catch { $bodyParseFailed = $true }

            if ($bodyParseFailed) {
                $res.StatusCode = 400
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('Malformed JSON body')
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
                return
            }

            $type = 'start'
            if ($path -eq '/api/stop') { $type = 'stop' } elseif ($path -eq '/api/restart') { $type = 'restart' }
            $id = [guid]::NewGuid().ToString()
            $procId = 0
            try { if ($body.ProcId) { $procId = [int]$body.ProcId } } catch {}
            $action = @{
                Id          = $id
                Type        = $type
                ProcId      = $procId
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

$script:DashboardListenScript = {
    param($Cache, $Html, $HandleRequestScript)

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

    $pool = [runspacefactory]::CreateRunspacePool(1, 8)
    $pool.Open()
    # Same in-flight bookkeeping as ProxyListenScript - each entry is one
    # accepted connection currently being handled on the pool, reaped
    # (Disposed) once its BeginInvoke completes.
    $inFlight = New-Object System.Collections.Generic.List[object]

    while (-not $Cache.StopRequested) {
        for ($i = $inFlight.Count - 1; $i -ge 0; $i--) {
            if ($inFlight[$i].Handle.IsCompleted) {
                try { $inFlight[$i].Shell.EndInvoke($inFlight[$i].Handle) } catch {}
                try { $inFlight[$i].Shell.Dispose() } catch {}
                $inFlight.RemoveAt($i)
            }
        }

        $context = $null
        try {
            $asyncResult = $listener.BeginGetContext($null, $null)
            while (-not $asyncResult.AsyncWaitHandle.WaitOne(500)) {
                if ($Cache.StopRequested) {
                    try { $listener.Stop() } catch {}
                    foreach ($inf in $inFlight) { try { $inf.Shell.Dispose() } catch {} }
                    try { $pool.Close() } catch {}
                    return
                }
            }
            $context = $listener.EndGetContext($asyncResult)
        } catch {
            if ($Cache.StopRequested) { return }
            continue
        }
        if (-not $context) { continue }

        $sh = [powershell]::Create()
        $sh.RunspacePool = $pool
        [void]$sh.AddScript($HandleRequestScript).AddArgument($context).AddArgument($Cache).AddArgument($Html)
        $handle = $sh.BeginInvoke()
        $inFlight.Add(@{ Shell = $sh; Handle = $handle })
    }
    foreach ($inf in $inFlight) { try { $inf.Shell.Dispose() } catch {} }
    try { $pool.Close() } catch {}
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
        AddArgument($html).
        AddArgument($script:DashboardHandleRequestScript)
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
        Write-AppErrorLog -Context "Web dashboard failed to start on port $($script:DashboardCache.Port)" -Extra $script:DashboardCache.ListenError
        try {
            $notifyIcon.ShowBalloonTip(4000, 'Localhost Manager', "Web dashboard failed to start on port $($script:DashboardCache.Port): $($script:DashboardCache.ListenError)", [System.Windows.Forms.ToolTipIcon]::Warning)
        } catch {}
    }
    Update-DashboardPill
})
$script:DashboardActionTimer.Start()

# ---------------------------------------------------------------------------
# Reverse proxy ("Local Domains") — routes http://<name>.localhost:<port>/
# to whichever real port that project is currently running on, keyed by
# ProxyCache.RouteMap (rebuilt every refresh cycle, see Update-ProxyRouteMap).
# Same background-runspace/HttpListener shape as the Web Dashboard above,
# minus an Actions queue: this listener only ever relays HTTP, it never
# needs to call back into UI-thread state.
#
# Unlike the dashboard, there's no useful "bind to literal localhost"
# fallback here if the wildcard bind fails - a listener bound to just
# "http://localhost:<port>/" only ever matches requests whose Host header
# is literally "localhost", never "<name>.localhost", so it couldn't route
# anything. Wildcard (and therefore the one-time urlacl grant - see
# Show-ProxyDialog) is the only mode that works for this feature.
# ---------------------------------------------------------------------------
# One HTTP request per PowerShell instance, run against a pooled runspace -
# extracted to its own scriptblock (rather than inlined in the accept loop
# below) because a real page load fires several requests in parallel
# (document + JS + CSS + favicon + ...), and handling them one at a time
# was the very first thing that broke in testing: a synchronous
# accept-process-accept loop left HTTP.SYS's own backlog queue rejecting
# the 3rd/4th concurrent asset with a bare 503 while request #1 was still
# being relayed. A small RunspacePool (see Start-ProxyServer) gives each
# accepted connection its own thread so the accept loop is never blocked
# on an in-flight relay.
$script:ProxyHandleRequestScript = {
    param($Context, $Cache)

    function Get-ProxyIndexHtml {
        param($RouteMap, [int]$Port, [string]$RequestedSlug)
        $rows = ($RouteMap.Keys | Sort-Object | ForEach-Object {
            $r = $RouteMap[$_]
            $addr = "$_.localhost`:$Port"
            "<tr><td><a href='http://$addr/'>$addr</a></td><td>$([System.Net.WebUtility]::HtmlEncode($r.Label))</td><td>$($r.Port)</td></tr>"
        }) -join "`n"
        if (-not $rows) { $rows = "<tr><td colspan='3'>Nothing is running right now.</td></tr>" }
        $notice = if ($RequestedSlug) {
            "<p class='err'>No running project matches '<b>$([System.Net.WebUtility]::HtmlEncode($RequestedSlug)).localhost</b>'.</p>"
        } else { '' }
        return @"
<!doctype html><html><head><meta charset='utf-8'><title>Local Domains</title>
<style>
body{font-family:Segoe UI,sans-serif;background:#1e1f22;color:#ddd;padding:24px}
table{border-collapse:collapse;width:100%;max-width:640px}
td,th{padding:6px 10px;text-align:left;border-bottom:1px solid #444}
a{color:#7aa2f7} .err{color:#e06c75}
</style></head><body>
<h2>Localhost Manager - Local Domains</h2>
$notice
<table><tr><th>Address</th><th>Project</th><th>Port</th></tr>$rows</table>
</body></html>
"@
    }

    $req = $Context.Request
    $res = $Context.Response
    # HTTP/1.1 only allows one in-flight response per connection at a time,
    # in request order - a keep-alive connection the browser reuses/
    # pipelines across several of the pooled runspaces above (see
    # ProxyListenScript) can finish out of order, and HttpListener reacts to
    # that by failing the connection with a bare 503 (this is exactly what
    # broke concurrent asset loads in testing - a real SPA's JS/CSS came
    # back 503 once fetched alongside its other assets). Closing every
    # connection after one response removes the shared-connection ordering
    # constraint entirely: each request gets its own connection, so nothing
    # is ever waiting on response order again.
    $res.KeepAlive = $false
    try {
        $rawHost = $req.Url.Host
        $slug = if ($rawHost -match '(?i)^(localhost|127\.0\.0\.1|\[?::1\]?)$') { '' } else { ($rawHost -replace '(?i)\.localhost$', '').ToLowerInvariant() }
        $route = if ($slug) { $Cache.RouteMap[$slug] } else { $null }

        if (-not $route) {
            $res.StatusCode = if ($slug) { 404 } else { 200 }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes((Get-ProxyIndexHtml $Cache.RouteMap $Cache.Port $slug))
            $res.ContentType = 'text/html; charset=utf-8'
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $fwd = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$($route.Port)$($req.Url.PathAndQuery)")
            $fwd.Method = $req.HttpMethod
            $fwd.AllowAutoRedirect = $false
            $fwd.Timeout = 30000
            $fwd.KeepAlive = $false
            foreach ($key in $req.Headers.AllKeys) {
                if (-not $key) { continue }
                switch -Regex ($key) {
                    # Origin dropped, not just left alone: the browser sends
                    # it (CORS-mode fetches - module scripts, stylesheets,
                    # ...) as http://<name>.localhost:<proxyPort>, which is
                    # not the backend's real origin. Forwarding it verbatim
                    # is exactly what broke a real app in testing - its own
                    # origin-check middleware saw a foreign Origin and threw
                    # a 500 for every asset fetched that way (module JS,
                    # CSS), while plain navigations/fetches with no Origin
                    # header sailed through fine. Dropping it makes the
                    # backend see the same kind of request it always has:
                    # same-origin, no CORS header to second-guess.
                    '^(Host|Content-Length|Connection|Transfer-Encoding|Expect|Proxy-Connection|Keep-Alive|Date|If-Modified-Since|Range|Origin)$' { continue }
                    '^Accept$'       { $fwd.Accept = $req.Headers[$key]; continue }
                    '^Content-Type$' { $fwd.ContentType = $req.Headers[$key]; continue }
                    '^User-Agent$'   { $fwd.UserAgent = $req.Headers[$key]; continue }
                    '^Referer$'      { $fwd.Referer = $req.Headers[$key]; continue }
                    default { try { $fwd.Headers.Add($key, $req.Headers[$key]) } catch {} }
                }
            }
            if ($req.HasEntityBody) {
                $fwd.ContentLength = $req.ContentLength64
                $reqStream = $fwd.GetRequestStream()
                $req.InputStream.CopyTo($reqStream)
                $reqStream.Close()
            } else {
                $fwd.ContentLength = 0
            }

            $fwdRes = $null
            try {
                $fwdRes = $fwd.GetResponse()
            } catch [System.Net.WebException] {
                # A backend returning 4xx/5xx lands here too (GetResponse
                # throws on any non-2xx status) - .Response is still the
                # real upstream response in that case, only $null when
                # the connection itself failed (backend gone/refused).
                $fwdRes = $_.Exception.Response
            }

            if ($fwdRes) {
                $res.StatusCode = [int]$fwdRes.StatusCode
                foreach ($hKey in $fwdRes.Headers.AllKeys) {
                    if ($hKey -in @('Transfer-Encoding', 'Connection', 'Content-Length', 'Keep-Alive')) { continue }
                    try { $res.Headers.Add($hKey, $fwdRes.Headers[$hKey]) } catch {}
                }
                if ($fwdRes.ContentType) { $res.ContentType = $fwdRes.ContentType }
                if ($fwdRes.ContentLength -ge 0) {
                    $res.ContentLength64 = $fwdRes.ContentLength
                } else {
                    $res.SendChunked = $true
                }
                $respStream = $fwdRes.GetResponseStream()
                $respStream.CopyTo($res.OutputStream)
                $respStream.Close()
                $fwdRes.Close()
            } else {
                $res.StatusCode = 502
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("<h3>502 - couldn't reach $([System.Net.WebUtility]::HtmlEncode($route.Label)) on port $($route.Port)</h3>")
                $res.ContentType = 'text/html; charset=utf-8'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
        }
    } catch {
        try { $res.StatusCode = 502 } catch {}
    } finally {
        try { $res.OutputStream.Close() } catch {}
    }
}

$script:ProxyListenScript = {
    param($Cache, $HandleRequestScript)

    $listener = New-Object System.Net.HttpListener
    $boundOk = $false
    try {
        $listener.Prefixes.Add("http://+:$($Cache.Port)/")
        $listener.Start()
        $boundOk = $true
    } catch {
        $Cache.ListenError = $_.Exception.Message
        $boundOk = $false
    }
    $Cache.Listening = $boundOk
    if (-not $boundOk) { return }

    $pool = [runspacefactory]::CreateRunspacePool(1, 8)
    $pool.Open()
    # Each entry is one accepted connection currently being relayed on the
    # pool - reaped (Disposed) once its BeginInvoke completes, checked once
    # per accept-loop iteration below. Nothing here ever waits on this list;
    # it only exists so completed instances get cleaned up instead of
    # leaking a PowerShell instance per request.
    $inFlight = New-Object System.Collections.Generic.List[object]

    while (-not $Cache.StopRequested) {
        for ($i = $inFlight.Count - 1; $i -ge 0; $i--) {
            if ($inFlight[$i].Handle.IsCompleted) {
                try { $inFlight[$i].Shell.EndInvoke($inFlight[$i].Handle) } catch {}
                try { $inFlight[$i].Shell.Dispose() } catch {}
                $inFlight.RemoveAt($i)
            }
        }

        $context = $null
        try {
            $asyncResult = $listener.BeginGetContext($null, $null)
            while (-not $asyncResult.AsyncWaitHandle.WaitOne(500)) {
                if ($Cache.StopRequested) {
                    try { $listener.Stop() } catch {}
                    foreach ($inf in $inFlight) { try { $inf.Shell.Dispose() } catch {} }
                    try { $pool.Close() } catch {}
                    return
                }
            }
            $context = $listener.EndGetContext($asyncResult)
        } catch {
            if ($Cache.StopRequested) { return }
            continue
        }
        if (-not $context) { continue }

        $sh = [powershell]::Create()
        $sh.RunspacePool = $pool
        [void]$sh.AddScript($HandleRequestScript).AddArgument($context).AddArgument($Cache)
        $handle = $sh.BeginInvoke()
        $inFlight.Add(@{ Shell = $sh; Handle = $handle })
    }
    foreach ($inf in $inFlight) { try { $inf.Shell.Dispose() } catch {} }
    try { $pool.Close() } catch {}
    try { $listener.Stop() } catch {}
    try { $listener.Close() } catch {}
}

function Start-ProxyServer {
    param([int]$Port)
    $script:ProxyCache.StopRequested = $false
    $script:ProxyCache.Port = $Port
    $script:ProxyCache.Listening = $false
    $script:ProxyCache.ListenError = ''

    $script:ProxyRunspace = [runspacefactory]::CreateRunspace()
    $script:ProxyRunspace.ApartmentState = 'MTA'
    $script:ProxyRunspace.ThreadOptions = 'ReuseThread'
    $script:ProxyRunspace.Open()

    $script:ProxyShell = [powershell]::Create()
    $script:ProxyShell.Runspace = $script:ProxyRunspace
    [void]$script:ProxyShell.AddScript($script:ProxyListenScript).AddArgument($script:ProxyCache).AddArgument($script:ProxyHandleRequestScript)
    $script:ProxyHandle = $script:ProxyShell.BeginInvoke()
}

function Stop-ProxyServer {
    if (-not $script:ProxyShell) { return }
    $script:ProxyCache.StopRequested = $true
    try { $script:ProxyShell.Stop() } catch {}
    try { $script:ProxyShell.Dispose() } catch {}
    try { $script:ProxyRunspace.Close() } catch {}
    $script:ProxyShell = $null
    $script:ProxyRunspace = $null
}

function Restart-ProxyServer {
    param([int]$Port)
    Stop-ProxyServer
    Start-ProxyServer -Port $Port
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
    if ($script:Settings.DashboardEnabled) {
        Start-WebDashboard -Port ([int]$script:Settings.WebPort)
    }
    if ($script:Settings.ProxyEnabled) {
        Start-ProxyServer -Port ([int]$script:Settings.ProxyPort)
    }
    Update-DashboardPill
    Start-UpdateCheck
} catch {
    Write-AppErrorLog -Context 'Startup error' -Exception $_.Exception
    [System.Windows.Forms.MessageBox]::Show("Startup error: $_", 'Error') | Out-Null
}

if ([bool]$script:Settings.StartMinimized) {
    # Same hide-not-close idiom as FormClosing: the window still gets
    # created (so first-show layout/handle creation happens normally),
    # it just never becomes visible - straight to the tray icon.
    $form.Add_Shown({ $form.Hide() })
}

# SyncingColumnLayout is released here, not earlier - see where it's set
# to $true, just before the grids are first created. Genuine user column
# drags can only happen once the message loop below is pumping, so
# holding the guard through the entirety of this synchronous startup
# sequence costs nothing and is the only boundary that's actually safe:
# adding the Fill-mode grids to their parent tab pages several hundred
# lines up triggers WinForms' first real layout pass (Fill-mode columns
# compute their pixel widths against a real size for the first time),
# which fires ColumnWidthChanged for every column - each one was calling
# Save-ColumnLayout (a disk write) which itself called Update-ColumnLayout
# again, cascading into dozens of redundant writes during ordinary
# startup and making the app appear to hang.
$script:SyncingColumnLayout = $false

[System.Windows.Forms.Application]::Run($form)
