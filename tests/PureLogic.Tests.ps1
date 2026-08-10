# Unit tests for the pure-logic (no WinForms, no network/process I/O)
# functions in LocalhostManager.ps1. Run with:
#
#   Invoke-Pester (Join-Path $PSScriptRoot 'PureLogic.Tests.ps1')
#
# LocalhostManager.ps1 has no "import only the functions" mode - the
# bottom of the file calls Application.Run($form), and loading it (even
# via dot-sourcing) starts the background poller runspace, the tray icon,
# and - if enabled - the web dashboard/proxy HTTP listeners. There's no
# way to safely dot-source the whole script from a test. Instead,
# Import-PureFunctions below pulls specific named function *bodies* out of
# the file via the PowerShell AST and defines only those in this session,
# so the functions under test run for real (this is not a reimplementation
# to keep in sync - it's the actual shipped code) without ever executing
# the GUI/startup path.
#
# Written for Pester 3.4.0 (the version that ships in Windows PowerShell
# 5.1) - if this machine ever gets a newer Pester on the module path,
# `Should Be` still works there too, so no changes needed.

$script:AppPath = Join-Path $PSScriptRoot '..\LocalhostManager.ps1'

# Returns the source text of each named top-level function, pulled out of
# LocalhostManager.ps1 via the AST. Deliberately just returns text rather
# than dot-sourcing it itself - dot-sourcing from inside a function defines
# things in that function's own scope, not the caller's, so the actual `.`
# has to happen at this file's top level (below) for the functions to be
# visible to the Describe/It blocks.
function Get-PureFunctionSource {
    param([string[]]$Names)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:AppPath, [ref]$tokens, [ref]$parseErrors)
    $allFuncs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    foreach ($name in $Names) {
        $def = $allFuncs | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if (-not $def) { throw "Function '$name' not found in LocalhostManager.ps1 - was it renamed?" }
        $def.Extent.Text
    }
}

foreach ($source in (Get-PureFunctionSource -Names @(
    'Get-NormalizedPath',
    'Test-PathUnderRoot',
    'Get-CustomNameKey',
    'Get-ProxySlug',
    'Test-HasShellChainingChars',
    'Get-NetworkInterfaceLabel',
    'Get-RowLanInfo',
    'Merge-LiveWithHistoryFallback',
    'Get-SearchFilteredDisplay',
    'Test-LogEntryMatchesProject',
    'Get-NearestExistingAncestor',
    'Get-CollapsedPathDisplay'
))) {
    . ([scriptblock]::Create($source))
}

Describe 'Get-NormalizedPath' {
    It 'lowercases and trims a trailing backslash' {
        Get-NormalizedPath 'C:\Users\Foo\Bar\' | Should Be 'c:\users\foo\bar'
    }
    It 'is idempotent for a path with no trailing backslash' {
        Get-NormalizedPath 'C:\Users\Foo' | Should Be 'c:\users\foo'
    }
    It 'returns empty string for empty input' {
        Get-NormalizedPath '' | Should Be ''
    }
}

Describe 'Test-PathUnderRoot' {
    It 'is always true when Root is empty (no restriction configured)' {
        Test-PathUnderRoot -Path 'C:\anything' -Root '' | Should Be $true
    }
    It 'is true when Path is under Root' {
        Test-PathUnderRoot -Path 'C:\Projects\app\src' -Root 'C:\Projects' | Should Be $true
    }
    It 'is false when Path is not under Root' {
        Test-PathUnderRoot -Path 'C:\Other\app' -Root 'C:\Projects' | Should Be $false
    }
    It 'compares case-insensitively' {
        Test-PathUnderRoot -Path 'c:\PROJECTS\app' -Root 'C:\Projects' | Should Be $true
    }
}

Describe 'Get-CustomNameKey' {
    It 'uses the normalized project path when one is known' {
        Get-CustomNameKey -ProjectPath 'C:\Foo\Bar\' -Port '3000' | Should Be 'c:\foo\bar'
    }
    It 'falls back to port:<n> when the path is unknown' {
        Get-CustomNameKey -ProjectPath '' -Port '3000' | Should Be 'port:3000'
    }
}

Describe 'Get-ProxySlug' {
    It 'lowercases and collapses non-alphanumeric runs to a single hyphen' {
        Get-ProxySlug -Label 'My Cool App!!' -Port '3000' | Should Be 'my-cool-app'
    }
    It 'trims leading/trailing hyphens' {
        Get-ProxySlug -Label '--Frontend--' -Port '3000' | Should Be 'frontend'
    }
    It 'falls back to port-<n> when nothing usable is left' {
        Get-ProxySlug -Label '!!!' -Port '3000' | Should Be 'port-3000'
    }
    It 'falls back to port-<n> for empty input' {
        Get-ProxySlug -Label '' -Port '3000' | Should Be 'port-3000'
    }
}

Describe 'Test-HasShellChainingChars' {
    It 'is false for an ordinary build command' {
        Test-HasShellChainingChars 'npm run build' | Should Be $false
    }
    It 'is false for a build command with quoted arguments' {
        Test-HasShellChainingChars 'npm run build -- --mode="production"' | Should Be $false
    }
    It 'is false for a quoted Windows path with spaces' {
        Test-HasShellChainingChars 'C:\Program Files\nodejs\node.exe' | Should Be $false
    }
    It 'is true for && chaining' {
        Test-HasShellChainingChars 'build && calc.exe' | Should Be $true
    }
    It 'is true for | piping' {
        Test-HasShellChainingChars 'build | calc.exe' | Should Be $true
    }
    It 'is false for empty or null input' {
        Test-HasShellChainingChars '' | Should Be $false
        Test-HasShellChainingChars $null | Should Be $false
    }
}

Describe 'Get-NetworkInterfaceLabel' {
    It 'classifies Ethernet as real, rank 0' {
        $r = Get-NetworkInterfaceLabel -InterfaceAlias 'Ethernet'
        $r.Label | Should Be 'Ethernet'
        $r.IsVirtual | Should Be $false
        $r.SortRank | Should Be 0
    }
    It 'classifies Wi-Fi as real, rank 0' {
        $r = Get-NetworkInterfaceLabel -InterfaceAlias 'Wi-Fi'
        $r.Label | Should Be 'Wi-Fi'
        $r.IsVirtual | Should Be $false
    }
    It 'classifies Tailscale as real but VPN, rank 1' {
        $r = Get-NetworkInterfaceLabel -InterfaceAlias 'Tailscale'
        $r.IsVirtual | Should Be $false
        $r.SortRank | Should Be 1
    }
    It 'flags VMware as virtual' {
        $r = Get-NetworkInterfaceLabel -InterfaceAlias 'VMware Network Adapter VMnet8'
        $r.Label | Should Be 'VMware'
        $r.IsVirtual | Should Be $true
    }
    It 'flags Hyper-V/vEthernet as virtual' {
        (Get-NetworkInterfaceLabel -InterfaceAlias 'Hyper-V Virtual Ethernet Adapter').IsVirtual | Should Be $true
        (Get-NetworkInterfaceLabel -InterfaceAlias 'vEthernet (Default Switch)').IsVirtual | Should Be $true
    }
    It 'falls back to the raw alias, rank 1, for anything unrecognized' {
        $r = Get-NetworkInterfaceLabel -InterfaceAlias 'SomeWeirdAdapter'
        $r.Label | Should Be 'SomeWeirdAdapter'
        $r.IsVirtual | Should Be $false
        $r.SortRank | Should Be 1
    }
    It 'falls back to a generic label for empty input' {
        (Get-NetworkInterfaceLabel -InterfaceAlias '').Label | Should Be 'Network'
    }
}

Describe 'Get-RowLanInfo' {
    It 'reports localhost-only for a listener bound to a specific (non-wildcard) address' {
        $r = Get-RowLanInfo -LocalAddr '127.0.0.1' -Port '3000' -LanIps @()
        $r.LanUrls | Should Be '(localhost only)'
        $r.LanEntries.Count | Should Be 0
    }
    It 'builds one entry per LAN IP for a wildcard (0.0.0.0) bind, real adapters sorted first' {
        $lanIps = @(
            [PSCustomObject]@{ IPAddress = '192.168.1.50'; InterfaceAlias = 'VMware Network Adapter VMnet8' }
            [PSCustomObject]@{ IPAddress = '10.0.0.5'; InterfaceAlias = 'Ethernet' }
        )
        $r = Get-RowLanInfo -LocalAddr '0.0.0.0' -Port '3000' -LanIps $lanIps
        $r.LanEntries.Count | Should Be 2
        $r.LanEntries[0].Label | Should Be 'Ethernet'
        $r.LanEntries[0].IsVirtual | Should Be $false
        $r.LanEntries[1].Label | Should Be 'VMware'
        $r.LanEntries[1].IsVirtual | Should Be $true
    }
    It 'also treats the IPv6 wildcard (::) as a wildcard bind' {
        $lanIps = @([PSCustomObject]@{ IPAddress = '10.0.0.5'; InterfaceAlias = 'Ethernet' })
        (Get-RowLanInfo -LocalAddr '::' -Port '3000' -LanIps $lanIps).LanEntries.Count | Should Be 1
    }
}

Describe 'Merge-LiveWithHistoryFallback' {
    It 'keeps a live entry with its own ProjectPath unchanged' {
        $rawLive = @{ '3000' = @{ ProjectPath = 'C:\Live\App'; CommandLine = 'node app.js'; IsNode = $true } }
        $result = Merge-LiveWithHistoryFallback -RawLive $rawLive -History @{}
        $result['3000'].ProjectPath | Should Be 'C:\Live\App'
    }
    It 'falls back to the historical ProjectPath/CommandLine when the live PEB read came back empty' {
        $rawLive = @{ '3000' = @{ ProjectPath = $null; CommandLine = $null; IsNode = $false } }
        $history = @{ '3000' = @{ ProjectPath = 'C:\Known\App'; CommandLine = 'node app.js' } }
        $result = Merge-LiveWithHistoryFallback -RawLive $rawLive -History $history
        $result['3000'].ProjectPath | Should Be 'C:\Known\App'
        $result['3000'].CommandLine | Should Be 'node app.js'
        $result['3000'].IsNode | Should Be $true
    }
    It 'a resolving live entry always wins over history, even if history disagrees' {
        $rawLive = @{ '3000' = @{ ProjectPath = 'C:\Fresh\App'; CommandLine = 'node app.js'; IsNode = $true } }
        $history = @{ '3000' = @{ ProjectPath = 'C:\Stale\App'; CommandLine = 'node old.js' } }
        $result = Merge-LiveWithHistoryFallback -RawLive $rawLive -History $history
        $result['3000'].ProjectPath | Should Be 'C:\Fresh\App'
    }
    It 'does not fall back when history has no ProjectPath for that port either' {
        $rawLive = @{ '3000' = @{ ProjectPath = $null; CommandLine = $null; IsNode = $false } }
        $result = Merge-LiveWithHistoryFallback -RawLive $rawLive -History @{}
        $result['3000'].ProjectPath | Should BeNullOrEmpty
    }
}

Describe 'Get-SearchFilteredDisplay' {
    # Reads $script:SearchFilter directly (it's wired to the toolbar
    # search box's live text, not passed as a parameter) - set/reset it
    # around each assertion rather than depending on Pester 3.4's
    # BeforeEach/AfterEach (not available in that version).
    #
    # Every call below wraps the function call itself in @(...), not just
    # parentheses - PowerShell unrolls a single-item array back to a bare
    # scalar (and a zero-item one to $null) as it crosses a function
    # return boundary, regardless of the @() the function itself already
    # wraps its own return value in. This bit the real call sites in
    # LocalhostManager.ps1 too (Render-FilteredGrids/Invoke-PeriodicRefresh)
    # until they were fixed to @()-wrap their calls as well - an
    # exactly-one-match (or zero-match) search left a tab header reading
    # "Live ()" instead of "Live (1)"/"Live (0)", since .Count on the
    # collapsed scalar/$null silently returns $null rather than throwing.
    $sampleDisplay = @(
        [PSCustomObject]@{ Group = $null; Row = [PSCustomObject]@{ CustomName = 'Frontend'; ProcessName = 'node'; Port = '3000'; ProjectPath = 'C:\Projects\web-app' } }
        [PSCustomObject]@{ Group = $null; Row = [PSCustomObject]@{ CustomName = ''; ProcessName = 'python'; Port = '8000'; ProjectPath = 'C:\Projects\api-server' } }
        [PSCustomObject]@{ Group = $null; Row = [PSCustomObject]@{ CustomName = 'Worker'; ProcessName = $null; Port = '9000'; ProjectPath = $null } }
    )

    It 'returns everything unfiltered when the search term is empty' {
        $script:SearchFilter = ''
        @(Get-SearchFilteredDisplay -Display $sampleDisplay).Count | Should Be 3
    }
    It 'matches against Custom Name, case-insensitively, even with exactly one match' {
        $script:SearchFilter = 'FRONT'
        $result = @(Get-SearchFilteredDisplay -Display $sampleDisplay)
        $result.Count | Should Be 1
        $result[0].Row.CustomName | Should Be 'Frontend'
    }
    It 'matches against Process Name for a row with no Custom Name' {
        $script:SearchFilter = 'python'
        $result = @(Get-SearchFilteredDisplay -Display $sampleDisplay)
        $result.Count | Should Be 1
        $result[0].Row.ProcessName | Should Be 'python'
    }
    It 'matches against Port' {
        $script:SearchFilter = '9000'
        @(Get-SearchFilteredDisplay -Display $sampleDisplay).Count | Should Be 1
    }
    It 'matches against Project Path' {
        $script:SearchFilter = 'api-server'
        @(Get-SearchFilteredDisplay -Display $sampleDisplay).Count | Should Be 1
    }
    It 'does not throw for a row with null ProcessName/ProjectPath' {
        $script:SearchFilter = 'worker'
        { Get-SearchFilteredDisplay -Display $sampleDisplay } | Should Not Throw
    }
    It 'returns nothing (not an error) when no row matches, exactly zero results' {
        $script:SearchFilter = 'nonexistent-xyz'
        @(Get-SearchFilteredDisplay -Display $sampleDisplay).Count | Should Be 0
    }
    $script:SearchFilter = ''
}

Describe 'Test-LogEntryMatchesProject' {
    # A real project's identifying strings, matching what
    # Get-KnownProjectLogFilters would build - Write-AppErrorLog call
    # sites use the raw folder name or full path, never the Custom Name
    # ("Body-Shop"), which is exactly the bug this function exists to
    # work around.
    $project = [PSCustomObject]@{
        Display         = 'Body-Shop (port 5100)'
        FolderName       = 'body-shop-server'
        ProjectPathText = 'C:\Users\Gaming\Documents\Body Shop\body-shop-server'
        Port            = '5100'
    }

    It 'always matches when Project is $null (All Projects)' {
        $entry = [PSCustomObject]@{ Header = 'anything at all'; Details = @() }
        Test-LogEntryMatchesProject -Entry $entry -Project $null | Should Be $true
    }
    It 'matches a crash entry that only contains the raw folder name' {
        $entry = [PSCustomObject]@{ Header = '[2026-07-29 23:31:44] Project crashed: body-shop-server (exit code -1)'; Details = @() }
        Test-LogEntryMatchesProject -Entry $entry -Project $project | Should Be $true
    }
    It 'does NOT match on the Custom Name alone (the actual bug this exists to avoid)' {
        # "Jewerly" (a real custom name typo in this app) vs. the real
        # folder "jewelry-store-server" - deliberately not a substring of
        # each other, unlike "Body-Shop"/"body-shop-server" which
        # coincidentally overlap and would mask this exact failure mode.
        $jewelryProject = [PSCustomObject]@{
            Display         = 'Jewerly (port 5200)'
            FolderName       = 'jewelry-store-server'
            ProjectPathText = 'C:\Users\Gaming\Documents\Jewelry Store\jewelry-store-server'
            Port            = '5200'
        }
        $entry = [PSCustomObject]@{ Header = 'Project crashed: Jewerly (exit code 1)'; Details = @() }
        Test-LogEntryMatchesProject -Entry $entry -Project $jewelryProject | Should Be $false
    }
    It 'matches an entry that only contains the full project path' {
        $entry = [PSCustomObject]@{ Header = 'Failed to start project:'; Details = @('C:\Users\Gaming\Documents\Body Shop\body-shop-server') }
        Test-LogEntryMatchesProject -Entry $entry -Project $project | Should Be $true
    }
    It 'matches an entry that only contains "port <n>"' {
        $entry = [PSCustomObject]@{ Header = "taskkill did not finish within 3000ms for PID 1234 (port 5100)"; Details = @() }
        Test-LogEntryMatchesProject -Entry $entry -Project $project | Should Be $true
    }
    It 'does not match an unrelated entry' {
        $entry = [PSCustomObject]@{ Header = 'Project crashed: Full-Stack (exit code 1)'; Details = @() }
        Test-LogEntryMatchesProject -Entry $entry -Project $project | Should Be $false
    }
}

Describe 'Get-NearestExistingAncestor' {
    It 'returns the path itself when it already exists' {
        Get-NearestExistingAncestor -Path $env:TEMP | Should Be $env:TEMP
    }
    It 'walks up to the nearest existing parent for a path that does not exist yet' {
        $missing = Join-Path $env:TEMP 'lhm-test-does-not-exist\dist'
        Get-NearestExistingAncestor -Path $missing | Should Be $env:TEMP
    }
    It 'returns $null when nothing in the chain exists (bogus drive)' {
        Get-NearestExistingAncestor -Path 'Z:\nonexistent-xyz\dist' | Should Be $null
    }
    It 'returns $null for empty input' {
        Get-NearestExistingAncestor -Path '' | Should Be $null
    }
}

Describe 'Get-CollapsedPathDisplay' {
    It 'abbreviates every segment but the drive root and the last 2, splitting multi-word names into initials' {
        $path = 'C:\Users\Gaming\Documents\Phone Store CRM\phone-hub\phone-hub-server\dist'
        Get-CollapsedPathDisplay -Path $path | Should Be 'C:\U\G\D\PSC\p\phone-hub-server\dist'
    }
    It 'abbreviates a multi-word project folder even when only one folder level follows it' {
        $path = 'C:\Users\Gaming\Documents\Transaction Coordinator CRM\tc-crm-server\dist'
        Get-CollapsedPathDisplay -Path $path | Should Be 'C:\U\G\D\TCC\tc-crm-server\dist'
    }
    It 'leaves a path unchanged when it already has 2 or fewer segments after the root' {
        Get-CollapsedPathDisplay -Path 'C:\Users\Gaming' | Should Be 'C:\Users\Gaming'
    }
    It 'abbreviates exactly one segment once there are 3 segments after the root' {
        Get-CollapsedPathDisplay -Path 'C:\Users\Gaming\Documents' | Should Be 'C:\U\Gaming\Documents'
    }
    It 'returns empty input unchanged' {
        Get-CollapsedPathDisplay -Path '' | Should Be ''
    }
}
