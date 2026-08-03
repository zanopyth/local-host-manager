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
    'Merge-LiveWithHistoryFallback'
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
