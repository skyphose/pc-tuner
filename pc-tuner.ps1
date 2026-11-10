# =====================================================================
#  pc-tuner.ps1 - the ENGINE
#
#  Tweaks live in .\modules\*.json as PURE DATA - no executable code.
#  This engine implements a small, fixed vocabulary of actions (see
#  $Handlers below):
#
#    registry             set a registry value
#    registry-flags       merge key=value flags into a composite string
#    powercfg-scheme      activate a power plan
#    netadapter-advanced  set network adapter advanced properties
#
#  A module can only DESCRIBE changes using those actions. Note that a
#  registry write can still be as powerful as code (e.g. an autostart
#  entry), so the engine refuses known autostart/security locations
#  ($DeniedRegistryKeys) - but review new modules like you'd review code.
#
#  Original values are saved to pc-tuner-backup.json before any change;
#  -Revert restores them.
#
#  Usage:
#    .\pc-tuner.ps1                      status of every tweak
#    .\pc-tuner.ps1 -Apply safe          apply all safe-tier tweaks
#    .\pc-tuner.ps1 -Apply hags          apply specific tweak(s)
#    .\pc-tuner.ps1 -Apply memory-integrity -AcceptTradeoffs
#    .\pc-tuner.ps1 -Revert all          restore original values
#    .\pc-tuner.ps1 -Validate            check modules; exit 1 if any fail
#    add -DryRun to preview without changing anything
#
#  PowerShell 5.1 compatible.
# =====================================================================

[CmdletBinding()]
param(
    [string[]]$Apply,
    [string[]]$Revert,
    [switch]$AcceptTradeoffs,
    [switch]$NoPause,
    [switch]$StatusJson,
    [switch]$DryRun,
    [switch]$Validate
)

$ErrorActionPreference = 'Stop'
$ModulesDir = Join-Path $PSScriptRoot 'modules'
$BackupPath = Join-Path $PSScriptRoot 'pc-tuner-backup.json'
$PowerCfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'

# ---------------------------------------------------------------- helpers

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# All registry access goes through .NET, which treats paths and names
# literally: no wildcard expansion, no `..` resolution, and reads and
# writes always hit the same key.
function Open-RegKey($Path, [switch]$Write) {
    $hive, $sub = $Path -split ':\\', 2
    $root = if ($hive -eq 'HKLM') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
    if ($Write) { $root.CreateSubKey($sub) } else { $root.OpenSubKey($sub) }
}

function Get-RegValue($Path, $Name) {
    $key = Open-RegKey $Path
    if (-not $key) { return $null }
    try { $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames') } finally { $key.Close() }
}

function Set-RegValue($Path, $Name, $Value, $Type) {
    if (-not $Type) { $Type = 'DWord' }
    $data = switch ($Type) {
        # DWORDs above 0x7FFFFFFF must be passed as their signed equivalent
        'DWord' { [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]([long]$Value -band 4294967295L)), 0) }
        'QWord' { [long]$Value }
        default { [string]$Value }
    }
    $key = Open-RegKey $Path -Write
    try { $key.SetValue($Name, $data, [Microsoft.Win32.RegistryValueKind]$Type) } finally { $key.Close() }
}

function Remove-RegValue($Path, $Name) {
    $hive, $sub = $Path -split ':\\', 2
    $root = if ($hive -eq 'HKLM') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
    $key = $root.OpenSubKey($sub, $true)
    if ($key) { try { $key.DeleteValue($Name, $false) } finally { $key.Close() } }
}

function ConvertFrom-FlagString($s) {
    $h = [ordered]@{}
    foreach ($pair in ("$s" -split ';' | Where-Object { $_ -match '=' })) {
        $k, $v = $pair -split '=', 2
        $h[$k.Trim()] = $v.Trim()
    }
    $h
}

function ConvertTo-FlagString($h) {
    (($h.Keys | ForEach-Object { "$_=$($h[$_])" }) -join ';') + ';'
}

# `powercfg /getactivescheme` is cached for the run; cleared after changes.
function Get-ActiveScheme {
    if (-not $script:SchemeOut) { $script:SchemeOut = "$(& $PowerCfg /getactivescheme)" }
    $script:SchemeOut
}

function Set-ActiveScheme([string]$Guid) {
    if ($Guid -notmatch $GuidRule) { throw "refusing non-GUID power scheme '$Guid'" }
    & $PowerCfg /setactive $Guid | Out-Null
    $script:SchemeOut = $null
}

# Reads adapter advanced properties from the driver's registry key - the
# same data Get-NetAdapterAdvancedProperty returns, without loading the
# NetAdapter/CIM module (~0.6 s). Anything not found that way falls back
# to the cmdlet, so status is never guessed.
function Get-NicAdvanced($Adapter, $Names) {
    $h = @{}
    foreach ($n in $Names) { $h[$n] = $null }
    $nic = [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object Name -eq $Adapter
    $class = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}')
    if ($nic -and $class) {
        try {
            foreach ($sub in $class.GetSubKeyNames()) {
                try { $key = $class.OpenSubKey($sub) } catch { continue }   # some subkeys are ACL-protected
                if (-not $key) { continue }
                try {
                    if ($key.GetValue('NetCfgInstanceId') -ne $nic.Id) { continue }
                    $params = $key.OpenSubKey('Ndi\params')
                    if (-not $params) { break }
                    try {
                        foreach ($kw in $params.GetSubKeyNames()) {
                            $p = $params.OpenSubKey($kw)
                            try {
                                $desc = $p.GetValue('ParamDesc')
                                if ($Names -notcontains $desc) { continue }
                                $raw = $key.GetValue($kw)
                                if ($null -eq $raw) { $raw = $p.GetValue('default') }
                                $enum = $p.OpenSubKey('enum')
                                $h[$desc] = if ($enum -and $null -ne $enum.GetValue("$raw")) { $enum.GetValue("$raw") } else { "$raw" }
                                if ($enum) { $enum.Close() }
                            } finally { $p.Close() }
                        }
                    } finally { $params.Close() }
                    break
                } finally { $key.Close() }
            }
        } finally { $class.Close() }
    }
    foreach ($n in @($h.Keys | Where-Object { $null -eq $h[$_] })) {
        $cur = Get-NetAdapterAdvancedProperty -Name $Adapter -DisplayName $n -ErrorAction SilentlyContinue
        if ($cur) { $h[$n] = $cur.DisplayValue }
    }
    $h
}

# ------------------------------------------------------- action handlers
# The ONLY things a module can make the engine do. Each type defines:
#   Required        fields a module must supply
#   Read  (a)       current state (this is what gets backed up)
#   Test  (a,s)     is the desired value in place?
#   Show  (a,s)     human-readable current state
#   Change(a)       human-readable description of what Apply will do
#   Target(a)       what a revert touches (for -DryRun)
#   Saved (a,s)     is a backed-up state well-formed for this action?
#   Apply (a,s)     make the change
#   Revert(a,saved,hasBackup)  restore

$GuidRule = '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'

function Test-Scalar($v) { $v -is [string] -or $v -is [ValueType] }

$Handlers = @{
    'registry' = @{
        Required = 'path', 'name', 'value'
        Read     = { param($a) Get-RegValue $a.path $a.name }
        Test     = { param($a, $s) $s -eq $a.value }
        Show     = { param($a, $s) "$($a.name)=$s" }
        Change   = { param($a) "set $($a.path)\$($a.name) = $($a.value)" }
        Target   = { param($a) "$($a.path)\$($a.name)" }
        Saved    = { param($a, $s) $null -eq $s -or (Test-Scalar $s) }
        Apply    = { param($a, $s) Set-RegValue $a.path $a.name $a.value $a.valueType }
        Revert   = { param($a, $saved, $hasBackup)
            $target = if ($hasBackup) { $saved } else { $a.default }
            if ($null -eq $target) { Remove-RegValue $a.path $a.name }
            else { Set-RegValue $a.path $a.name $target $a.valueType }
        }
    }
    'registry-flags' = @{
        Required = 'path', 'name', 'flags'
        Read     = { param($a) Get-RegValue $a.path $a.name }
        Test     = { param($a, $s)
            $cur = ConvertFrom-FlagString $s
            @($a.flags | Where-Object { $cur[$_.key] -ne "$($_.value)" }).Count -eq 0
        }
        Show     = { param($a, $s)
            $cur = ConvertFrom-FlagString $s
            ($a.flags | ForEach-Object { "$($_.key)=$($cur[$_.key])" }) -join ', '
        }
        Change   = { param($a) "merge into $($a.path)\$($a.name): " + (($a.flags | ForEach-Object { "$($_.key)=$($_.value)" }) -join ', ') + ' (other flags preserved)' }
        Target   = { param($a) "$($a.path)\$($a.name)" }
        Saved    = { param($a, $s) $null -eq $s -or $s -is [string] }
        Apply    = { param($a, $s)
            $cur = ConvertFrom-FlagString $s
            foreach ($f in $a.flags) { $cur[$f.key] = "$($f.value)" }
            Set-RegValue $a.path $a.name (ConvertTo-FlagString $cur) 'String'
        }
        Revert   = { param($a, $saved, $hasBackup)
            if ($hasBackup -and $null -eq $saved) { Remove-RegValue $a.path $a.name }
            elseif ($hasBackup) { Set-RegValue $a.path $a.name $saved 'String' }
            else {
                # no backup: strip only our flags, preserve the rest
                $cur = ConvertFrom-FlagString (Get-RegValue $a.path $a.name)
                foreach ($f in $a.flags) { $cur.Remove($f.key) }
                Set-RegValue $a.path $a.name (ConvertTo-FlagString $cur) 'String'
            }
        }
    }
    'powercfg-scheme' = @{
        Required = @('guid')
        Read     = { param($a) if ((Get-ActiveScheme) -match '([0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12})') { $Matches[1] } }
        Test     = { param($a, $s) $s -eq $a.guid }
        Show     = { param($a, $s) if ((Get-ActiveScheme) -match '\((.+)\)') { "active: $($Matches[1])" } else { 'active: unknown' } }
        Change   = { param($a) "activate power scheme $($a.guid)" }
        Target   = { param($a) 'active power scheme' }
        Saved    = { param($a, $s) $null -eq $s -or ($s -is [string] -and $s -match $GuidRule) }
        Apply    = { param($a, $s) Set-ActiveScheme $a.guid }
        Revert   = { param($a, $saved, $hasBackup)
            $target = if ($hasBackup -and $saved) { $saved } else { $a.default }
            if ($target) { Set-ActiveScheme $target }
        }
    }
    'netadapter-advanced' = @{
        Required = 'adapter', 'properties'
        Read     = { param($a) Get-NicAdvanced $a.adapter @($a.properties.displayName) }
        Test     = { param($a, $s) @($a.properties | Where-Object { $s[$_.displayName] -ne $_.value }).Count -eq 0 }
        Show     = { param($a, $s) ($a.properties | ForEach-Object { "$($_.displayName)=$($s[$_.displayName])" }) -join ', ' }
        Change   = { param($a) "set adapter '$($a.adapter)': " + (($a.properties | ForEach-Object { "$($_.displayName)=$($_.value)" }) -join ', ') }
        Target   = { param($a) "adapter '$($a.adapter)'" }
        # a backup may only restore the properties this module manages
        Saved    = { param($a, $s)
            if ($null -eq $s) { return $true }
            if ($s -isnot [Management.Automation.PSCustomObject]) { return $false }
            $allowed = @($a.properties.displayName)
            @($s.PSObject.Properties | Where-Object { $allowed -cnotcontains $_.Name -or ($null -ne $_.Value -and $_.Value -isnot [string]) }).Count -eq 0
        }
        Apply    = { param($a, $s)
            foreach ($p in $a.properties) {
                Set-NetAdapterAdvancedProperty -Name $a.adapter -DisplayName $p.displayName -DisplayValue $p.value -NoRestart
            }
            if ($a.restart) { Restart-NetAdapter -Name $a.adapter }
        }
        Revert   = { param($a, $saved, $hasBackup)
            if (-not $hasBackup -or $null -eq $saved) {
                Write-Host "    (no backup for adapter settings - leaving as-is)" -ForegroundColor DarkYellow
                return
            }
            foreach ($prop in $saved.PSObject.Properties) {
                if ($null -ne $prop.Value) {
                    Set-NetAdapterAdvancedProperty -Name $a.adapter -DisplayName $prop.Name -DisplayValue $prop.Value -NoRestart
                }
            }
            if ($a.restart) { Restart-NetAdapter -Name $a.adapter }
        }
    }
}

# ------------------------------------------------------- module validation

# Writing to these locations is equivalent to running code or weakening
# security (autostart, file-association/COM hijacks, debugger hijacks,
# services, policies, UAC, Defender...). Matched as substrings of the
# lower-cased key path, so subkeys and Wow6432Node variants are covered.
# This is defense in depth, not a guarantee: still review new modules.
$DeniedRegistryKeys = @(
    '\currentversion\run'            # Run, RunOnce, RunOnceEx, RunServices*
    '\classes\'                      # file associations, COM, shell verbs
    '\image file execution options'
    '\silentprocessexit'
    '\winlogon'
    '\services\'
    '\policies\'                     # incl. EnableLUA (UAC), Defender policy
    '\windows defender'
    '\control\session manager'       # BootExecute, KnownDLLs, AppCertDlls, env
    '\control\lsa'
    '\control\securityproviders'
    '\control\print\monitors'
    '\control\terminal server'
    '\windows nt\currentversion\windows'   # AppInit_DLLs, Load, Run
    '\command processor'             # AutoRun
    '\shell folders'                 # Startup folder redirection
    '\active setup'
    '\netsh'
    '\explorer\shellexecutehooks'
    '\explorer\browser helper objects'
    '\shellserviceobjectdelayload'
    '\environment'                   # PATH hijack
)

$UnsafeChars = '[\x00-\x1f\x7f*?\[\]`/]'   # control chars, wildcards, `/`
$IdRule = '^[a-z0-9][a-z0-9-]*$'

function Get-AllStrings($o) {
    if ($o -is [string]) { $o }
    elseif ($o -is [array]) { foreach ($x in $o) { Get-AllStrings $x } }
    elseif ($o -is [Management.Automation.PSCustomObject]) {
        foreach ($p in $o.PSObject.Properties) { $p.Name; Get-AllStrings $p.Value }
    }
}

function Test-SafeName($s) { $s -is [string] -and $s -ne '' -and $s -notmatch $UnsafeChars }

function Test-RegPath($p) {
    if (-not (Test-SafeName $p) -or $p -notmatch '^(HKLM|HKCU):\\[^\\]') { return 'registry path must be a plain HKLM:\ or HKCU:\ key path (no wildcards)' }
    if (@($p -split '\\' | Where-Object { $_ -in '', '.', '..' }).Count -gt 0) { return "registry path has an empty, '.' or '..' segment" }
    $lower = $p.Substring(5).ToLowerInvariant() + '\'
    foreach ($d in $DeniedRegistryKeys) { if ($lower.Contains($d)) { return "registry path is in a protected location ('$($d.Trim('\'))')" } }
}

function Test-ModuleErrors($m) {
    if ($m -isnot [Management.Automation.PSCustomObject]) { 'module must be a JSON object'; return }
    if (@(Get-AllStrings $m | Where-Object { $_ -match '[\x00-\x08\x0b-\x1f\x7f]' }).Count) { 'contains control characters'; return }
    if (-not (Test-SafeName $m.module)) { 'missing or invalid "module" name' }
    if (-not $m.tweaks) { 'missing or empty "tweaks" array'; return }
    foreach ($t in @($m.tweaks)) {
        if ($t.id -isnot [string] -or $t.id -cnotmatch $IdRule) { "tweak id '$($t.id)' must match $IdRule"; continue }
        foreach ($f in 'name', 'why') { if ($t.$f -isnot [string] -or -not $t.$f) { "$($t.id): missing `"$f`"" } }
        if ($t.risk -cnotin 'safe', 'tradeoff') { "$($t.id): risk must be 'safe' or 'tradeoff'" }
        if (-not $t.actions) { "$($t.id): no actions"; continue }
        foreach ($a in @($t.actions)) {
            $h = if ($a.type -is [string]) { $Handlers[$a.type] }
            if (-not $h) { "$($t.id): unknown action type '$($a.type)' (allowed: $(($Handlers.Keys | Sort-Object) -join ', '))"; continue }
            foreach ($f in $h.Required) {
                if ($null -eq $a.$f -or "$($a.$f)" -eq '') { "$($t.id): $($a.type) action missing `"$f`"" }
            }
            $id = $t.id
            switch ($a.type) {
                { $_ -like 'registry*' } {
                    if ($a.path) { $e = Test-RegPath $a.path; if ($e) { "${id}: $e" } }
                    if ($a.name -and -not (Test-SafeName $a.name)) { "${id}: registry value name has invalid characters" }
                }
                'registry' {
                    if ($null -ne $a.value -and -not (Test-Scalar $a.value)) { "${id}: value must be a string or number" }
                    if ($null -ne $a.default -and -not (Test-Scalar $a.default)) { "${id}: default must be a string or number" }
                    if ($a.valueType -and $a.valueType -cnotin 'DWord', 'QWord', 'String', 'ExpandString') { "${id}: valueType must be DWord, QWord, String or ExpandString" }
                }
                'registry-flags' {
                    foreach ($f in @($a.flags)) {
                        if (-not (Test-SafeName $f.key) -or "$($f.key)$($f.value)" -match '[;=]' -or -not (Test-Scalar $f.value)) { "${id}: flag keys/values must be plain strings without ';' or '='" }
                    }
                }
                'powercfg-scheme' {
                    foreach ($f in 'guid', 'default') {
                        if ($null -ne $a.$f -and ($a.$f -isnot [string] -or $a.$f -notmatch $GuidRule)) { "${id}: $f must be a GUID string" }
                    }
                }
                'netadapter-advanced' {
                    if ($a.adapter -and -not (Test-SafeName $a.adapter)) { "${id}: adapter name has invalid characters" }
                    foreach ($p in @($a.properties)) {
                        if (-not (Test-SafeName $p.displayName) -or $p.value -isnot [string]) { "${id}: each property needs a plain displayName and a string value" }
                    }
                }
            }
        }
    }
}

# ------------------------------------------------------------ load modules

if (-not (Test-Path $ModulesDir)) { Write-Host "No modules directory at $ModulesDir" -ForegroundColor Red; exit 1 }

$Modules = @()
$AllTweaks = @()
$InvalidModules = 0
foreach ($f in Get-ChildItem $ModulesDir -Filter '*.json' | Sort-Object Name) {
    try {
        $m = Get-Content $f.FullName -Raw | ConvertFrom-Json
    } catch {
        Write-Host "SKIPPING $($f.Name): invalid JSON - $($_.Exception.Message)" -ForegroundColor Red
        $InvalidModules++
        continue
    }
    $validationErrors = @(Test-ModuleErrors $m)
    if ($validationErrors.Count -gt 0) {
        Write-Host "SKIPPING $($f.Name): failed validation -" -ForegroundColor Red
        foreach ($e in $validationErrors) { Write-Host "    $e" -ForegroundColor Red }
        $InvalidModules++
        continue
    }
    $m | Add-Member -NotePropertyName File -NotePropertyValue $f.Name -Force
    $Modules += $m
    $AllTweaks += @($m.tweaks)
}

$dups = $AllTweaks | Group-Object id | Where-Object Count -gt 1
if ($dups) { Write-Host "Duplicate tweak ids across modules: $($dups.Name -join ', ')" -ForegroundColor Red; exit 1 }

if ($Validate) {
    Write-Host "$($Modules.Count) module(s) valid, $InvalidModules invalid; $($AllTweaks.Count) tweaks."
    exit ([int]($InvalidModules -gt 0))
}

# ------------------------------------------------------------------ state

# Reads every action of a tweak exactly once.
function Get-TweakState($t) {
    $acts = @($t.actions)
    $states = [object[]]::new($acts.Count)   # not New-Object: PS 5.1 would serialize that as {value,Count}
    $applied = $true
    $detail = for ($i = 0; $i -lt $acts.Count; $i++) {
        $h = $Handlers[$acts[$i].type]
        $states[$i] = & $h.Read $acts[$i]
        if (-not (& $h.Test $acts[$i] $states[$i])) { $applied = $false }
        & $h.Show $acts[$i] $states[$i]
    }
    [pscustomobject]@{ Applied = $applied; Detail = ($detail -join '; '); States = $states }
}

function Get-ChangeList($t) {
    foreach ($a in @($t.actions)) { & $Handlers[$a.type].Change $a }
}

function Show-Status {
    $w = ($AllTweaks.id | Measure-Object -Property Length -Maximum).Maximum
    Write-Host ""
    Write-Host "PC-TUNER STATUS" -ForegroundColor Cyan
    foreach ($m in $Modules) {
        Write-Host ""
        Write-Host "  module: $($m.module)  ($($m.File))" -ForegroundColor Cyan
        Write-Host ("  " + "-" * ($w + 46))
        foreach ($t in $m.tweaks) {
            $st = Get-TweakState $t
            $mark = if ($st.Applied) { '[ON ]' } else { '[off]' }
            $color = if ($st.Applied) { 'Green' } else { 'Yellow' }
            $riskTag = if ($t.risk -eq 'tradeoff') { '(!) ' } else { '    ' }
            Write-Host ("  {0}{1} {2} {3}" -f $riskTag, $mark, $t.id.PadRight($w), $st.Detail) -ForegroundColor $color
        }
    }
    Write-Host ""
    Write-Host "Apply safe tier:   .\pc-tuner.ps1 -Apply safe"
    Write-Host "Tradeoff tweaks:   .\pc-tuner.ps1 -Apply <id> -AcceptTradeoffs"
    Write-Host "Undo everything:   .\pc-tuner.ps1 -Revert all"
    Write-Host ""
}

if ($StatusJson) {
    $out = foreach ($m in $Modules) {
        [pscustomobject]@{
            module      = $m.module
            file        = $m.File
            description = $m.description
            tweaks      = @(foreach ($t in $m.tweaks) {
                $st = Get-TweakState $t
                [pscustomobject]@{
                    id          = $t.id
                    name        = $t.name
                    risk        = $t.risk
                    needsAdmin  = [bool]$t.needsAdmin
                    needsReboot = [bool]$t.needsReboot
                    why         = $t.why
                    applied     = $st.Applied
                    detail      = $st.Detail
                    changes     = @(Get-ChangeList $t)
                }
            })
        }
    }
    ConvertTo-Json -InputObject @($out) -Depth 6
    exit 0
}

if (-not ($Apply -or $Revert)) { Show-Status; exit 0 }

# --------------------------------------------------------- apply / revert

$mode = if ($Apply) { 'Apply' } else { 'Revert' }
$names = @(($(if ($Apply) { $Apply } else { $Revert }) -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$explicit = @($names | Where-Object { $_ -notin 'safe', 'all' })

$ids = @(foreach ($n in $names) {
    if ($n -eq 'safe') { @($AllTweaks | Where-Object risk -eq 'safe').id }
    elseif ($n -eq 'all') { $AllTweaks.id }
    elseif ($AllTweaks.id -contains $n) { $n }
    else { Write-Host "Unknown tweak: $n (valid: $($AllTweaks.id -join ', '))" -ForegroundColor Red }
}) | Select-Object -Unique
$selected = @($AllTweaks | Where-Object { $ids -contains $_.id })

if ($mode -eq 'Apply' -and -not $AcceptTradeoffs) {
    foreach ($g in @($selected | Where-Object risk -eq 'tradeoff')) {
        Write-Host "SKIPPED $($g.id): tradeoff - re-run with -AcceptTradeoffs after reading:" -ForegroundColor Red
        Write-Host "  $($g.why)"
    }
    $selected = @($selected | Where-Object risk -ne 'tradeoff')
}

if (@($selected | Where-Object needsAdmin).Count -gt 0 -and -not $DryRun -and -not (Test-Admin)) {
    # Pass the user's original selection (not resolved ids) so 'safe'/'all'
    # keep their meaning; every element was matched against known ids above.
    $pass = @($names | Where-Object { $_ -in 'safe', 'all' -or $AllTweaks.id -contains $_ })
    Write-Host "Elevation required - relaunching as admin (accept the UAC prompt)..."
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", "-$mode", ($pass -join ','))
    if ($AcceptTradeoffs) { $argList += '-AcceptTradeoffs' }
    if ($NoPause) { $argList += '-NoPause' }
    Start-Process (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -ArgumentList $argList -Wait
    exit
}

if (-not $DryRun) { try { Start-Transcript -Path (Join-Path $PSScriptRoot 'pc-tuner-last-run.log') -Force | Out-Null } catch {} }

$backup = if (Test-Path $BackupPath) { Get-Content $BackupPath -Raw | ConvertFrom-Json } else { New-Object PSObject }
$rebootNeeded = $false

foreach ($t in $selected) {
    try {
        $acts = @($t.actions)
        $hasBackup = $backup.PSObject.Properties.Name -contains $t.id
        if ($mode -eq 'Apply') {
            $st = Get-TweakState $t
            # Back up original state once (array aligned with actions) - even
            # if it's already applied, so a later revert restores what was
            # there instead of falling back to module defaults.
            if (-not $hasBackup -and -not $DryRun) {
                $backup | Add-Member -NotePropertyName $t.id -NotePropertyValue $st.States
                $backup | ConvertTo-Json -Depth 6 | Out-File $BackupPath -Encoding utf8
            }
            if ($st.Applied) { Write-Host "= $($t.id): already applied"; continue }
            if ($DryRun) {
                Write-Host "~ $($t.id): would apply" -ForegroundColor Cyan
                Get-ChangeList $t | ForEach-Object { Write-Host "    -> $_" }
                continue
            }
            Write-Host "+ $($t.id):" -ForegroundColor Green
            for ($i = 0; $i -lt $acts.Count; $i++) {
                Write-Host "    -> $(& $Handlers[$acts[$i].type].Change $acts[$i])"
                & $Handlers[$acts[$i].type].Apply $acts[$i] $st.States[$i]
            }
        } else {
            if (-not $hasBackup -and $explicit -notcontains $t.id) {
                Write-Host "= $($t.id): never changed by pc-tuner (no backup) - skipped; revert it by name to force module defaults"
                continue
            }
            $saved = @()   # assigned separately: `$x = if {...}` would unroll a 1-element array
            if ($hasBackup) {
                $saved = @($backup.($t.id))
                $bad = $saved.Count -ne $acts.Count
                for ($i = 0; -not $bad -and $i -lt $acts.Count; $i++) {
                    if (-not (& $Handlers[$acts[$i].type].Saved $acts[$i] $saved[$i])) { $bad = $true }
                }
                if ($bad) { throw "backup entry doesn't match this tweak's actions (edited backup or module?) - not reverting" }
            }
            if ($DryRun) { Write-Host "~ $($t.id): would revert" -ForegroundColor Cyan }
            else { Write-Host "- $($t.id): reverting" -ForegroundColor Yellow }
            for ($i = 0; $i -lt $acts.Count; $i++) {
                $s = if ($hasBackup) { $saved[$i] } else { $null }
                if ($DryRun) {
                    $to = if (-not $hasBackup) { 'module default' } elseif ($null -eq $s) { '(remove - did not exist)' } else { ConvertTo-Json $s -Compress }
                    Write-Host "    -> $(& $Handlers[$acts[$i].type].Target $acts[$i]) := $to"
                    continue
                }
                & $Handlers[$acts[$i].type].Revert $acts[$i] $s $hasBackup
            }
        }
        if ($t.needsReboot -and -not $DryRun) { $rebootNeeded = $true }
    } catch {
        Write-Host "x $($t.id): FAILED - $($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($rebootNeeded) {
    Write-Host ""
    Write-Host "REBOOT REQUIRED for some changes to take effect." -ForegroundColor Cyan
}
if (-not $DryRun) { Show-Status }
try { Stop-Transcript | Out-Null } catch {}
if (-not $NoPause -and -not $DryRun) { Read-Host "Press Enter to close" | Out-Null }
