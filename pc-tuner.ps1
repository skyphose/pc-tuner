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
#  A module file can only DESCRIBE changes using those actions, so the
#  only code that ever runs on your machine is this file. Audit this
#  once; module JSONs are then safe to read at a glance.
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
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ModulesDir = Join-Path $PSScriptRoot 'modules'
$BackupPath = Join-Path $PSScriptRoot 'pc-tuner-backup.json'

# ---------------------------------------------------------------- helpers

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Reads go straight through .NET (no PowerShell provider overhead);
# writes use the provider so value types are handled explicitly.
function Get-RegValue($Path, $Name) {
    $hive, $sub = $Path -split ':\\', 2
    $root = if ($hive -eq 'HKLM') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
    $key = $root.OpenSubKey($sub)
    if (-not $key) { return $null }
    try { $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames') } finally { $key.Close() }
}

function Set-RegValue($Path, $Name, $Value, $Type) {
    if (-not $Type) { $Type = 'DWord' }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Remove-RegValue($Path, $Name) {
    Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
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
    if (-not $script:SchemeOut) { $script:SchemeOut = "$(powercfg /getactivescheme)" }
    $script:SchemeOut
}

function Set-ActiveScheme($Guid) {
    powercfg /setactive $Guid | Out-Null
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
        foreach ($sub in $class.GetSubKeyNames()) {
            try { $key = $class.OpenSubKey($sub) } catch { continue }   # some subkeys are ACL-protected
            if (-not $key -or $key.GetValue('NetCfgInstanceId') -ne $nic.Id) { continue }
            $params = $key.OpenSubKey('Ndi\params')
            if ($params) {
                foreach ($kw in $params.GetSubKeyNames()) {
                    $p = $params.OpenSubKey($kw)
                    $desc = $p.GetValue('ParamDesc')
                    if ($Names -notcontains $desc) { continue }
                    $raw = $key.GetValue($kw)
                    if ($null -eq $raw) { $raw = $p.GetValue('default') }
                    $enum = $p.OpenSubKey('enum')
                    $h[$desc] = if ($enum -and $null -ne $enum.GetValue("$raw")) { $enum.GetValue("$raw") } else { "$raw" }
                }
            }
            break
        }
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
#   Apply (a,s)     make the change
#   Revert(a,saved,hasBackup)  restore

$RegPathRule = '^(HKLM|HKCU):\\'

$Handlers = @{
    'registry' = @{
        Required = 'path', 'name', 'value'
        Read     = { param($a) Get-RegValue $a.path $a.name }
        Test     = { param($a, $s) $s -eq $a.value }
        Show     = { param($a, $s) "$($a.name)=$s" }
        Change   = { param($a) "set $($a.path)\$($a.name) = $($a.value)" }
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

function Test-ModuleErrors($m) {
    if (-not $m.module) { 'missing "module" name' }
    if (-not $m.tweaks) { 'missing or empty "tweaks" array'; return }
    foreach ($t in @($m.tweaks)) {
        if (-not $t.id) { 'a tweak is missing "id"'; continue }
        foreach ($f in 'name', 'risk', 'why') { if (-not $t.$f) { "$($t.id): missing `"$f`"" } }
        if ($t.risk -and $t.risk -notin 'safe', 'tradeoff') { "$($t.id): risk must be 'safe' or 'tradeoff'" }
        if (-not $t.actions) { "$($t.id): no actions"; continue }
        foreach ($a in @($t.actions)) {
            $h = if ($a.type) { $Handlers[$a.type] }
            if (-not $h) { "$($t.id): unknown action type '$($a.type)' (allowed: $(($Handlers.Keys | Sort-Object) -join ', '))"; continue }
            foreach ($f in $h.Required) {
                if ($null -eq $a.$f -or "$($a.$f)" -eq '') { "$($t.id): $($a.type) action missing `"$f`"" }
            }
            if ($a.path -and $a.path -notmatch $RegPathRule) { "$($t.id): registry path must start with HKLM:\ or HKCU:\" }
        }
    }
}

# ------------------------------------------------------------ load modules

if (-not (Test-Path $ModulesDir)) { Write-Host "No modules directory at $ModulesDir" -ForegroundColor Red; exit 1 }

$Modules = @()
$AllTweaks = @()
foreach ($f in Get-ChildItem $ModulesDir -Filter '*.json' | Sort-Object Name) {
    try {
        $m = Get-Content $f.FullName -Raw | ConvertFrom-Json
    } catch {
        Write-Host "SKIPPING $($f.Name): invalid JSON - $($_.Exception.Message)" -ForegroundColor Red
        continue
    }
    $validationErrors = @(Test-ModuleErrors $m)
    if ($validationErrors.Count -gt 0) {
        Write-Host "SKIPPING $($f.Name): failed validation -" -ForegroundColor Red
        foreach ($e in $validationErrors) { Write-Host "    $e" -ForegroundColor Red }
        continue
    }
    $m | Add-Member -NotePropertyName File -NotePropertyValue $f.Name -Force
    $Modules += $m
    $AllTweaks += @($m.tweaks)
}

$dups = $AllTweaks | Group-Object id | Where-Object Count -gt 1
if ($dups) { Write-Host "Duplicate tweak ids across modules: $($dups.Name -join ', ')" -ForegroundColor Red; exit 1 }

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

function Resolve-TweakIds($names) {
    $ids = foreach ($n in ($names -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if ($n -eq 'safe') { @($AllTweaks | Where-Object risk -eq 'safe').id }
        elseif ($n -eq 'all') { $AllTweaks.id }
        elseif ($AllTweaks.id -contains $n) { $n }
        else { Write-Host "Unknown tweak: $n (valid: $($AllTweaks.id -join ', '))" -ForegroundColor Red }
    }
    @($ids | Select-Object -Unique)
}

$mode = if ($Apply) { 'Apply' } else { 'Revert' }
$ids = Resolve-TweakIds $(if ($Apply) { $Apply } else { $Revert })
$selected = @($AllTweaks | Where-Object { $ids -contains $_.id })

if ($mode -eq 'Apply' -and -not $AcceptTradeoffs) {
    foreach ($g in @($selected | Where-Object risk -eq 'tradeoff')) {
        Write-Host "SKIPPED $($g.id): tradeoff - re-run with -AcceptTradeoffs after reading:" -ForegroundColor Red
        Write-Host "  $($g.why)"
    }
    $selected = @($selected | Where-Object risk -ne 'tradeoff')
}

if (@($selected | Where-Object needsAdmin).Count -gt 0 -and -not $DryRun -and -not (Test-Admin)) {
    Write-Host "Elevation required - relaunching as admin (accept the UAC prompt)..."
    $argList = @('-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", "-$mode", ($ids -join ','))
    if ($AcceptTradeoffs) { $argList += '-AcceptTradeoffs' }
    if ($NoPause) { $argList += '-NoPause' }
    Start-Process powershell -Verb RunAs -ArgumentList $argList -Wait
    exit
}

if (-not $DryRun) { try { Start-Transcript -Path (Join-Path $PSScriptRoot 'pc-tuner-last-run.log') -Force | Out-Null } catch {} }

$backup = if (Test-Path $BackupPath) { Get-Content $BackupPath -Raw | ConvertFrom-Json } else { New-Object PSObject }
$rebootNeeded = $false

foreach ($t in $selected) {
    try {
        $acts = @($t.actions)
        if ($mode -eq 'Apply') {
            $st = Get-TweakState $t
            if ($st.Applied) { Write-Host "= $($t.id): already applied"; continue }
            if ($DryRun) {
                Write-Host "~ $($t.id): would apply" -ForegroundColor Cyan
                Get-ChangeList $t | ForEach-Object { Write-Host "    -> $_" }
                continue
            }
            # back up original state once (array aligned with actions)
            if ($backup.PSObject.Properties.Name -notcontains $t.id) {
                $backup | Add-Member -NotePropertyName $t.id -NotePropertyValue $st.States
                $backup | ConvertTo-Json -Depth 6 | Out-File $BackupPath -Encoding utf8
            }
            Write-Host "+ $($t.id):" -ForegroundColor Green
            for ($i = 0; $i -lt $acts.Count; $i++) {
                Write-Host "    -> $(& $Handlers[$acts[$i].type].Change $acts[$i])"
                & $Handlers[$acts[$i].type].Apply $acts[$i] $st.States[$i]
            }
        } else {
            $hasBackup = $backup.PSObject.Properties.Name -contains $t.id
            $saved = @()   # assigned separately: `$x = if {...}` would unroll a 1-element array
            if ($hasBackup) { $saved = @($backup.($t.id)) }
            if ($DryRun) {
                $src = if ($hasBackup) { 'backed-up values' } else { 'module defaults (no backup)' }
                Write-Host "~ $($t.id): would revert to $src" -ForegroundColor Cyan
                continue
            }
            Write-Host "- $($t.id): reverting" -ForegroundColor Yellow
            for ($i = 0; $i -lt $acts.Count; $i++) {
                $s = if ($hasBackup) { $saved[$i] } else { $null }
                & $Handlers[$acts[$i].type].Revert $acts[$i] $s $hasBackup
            }
        }
        if ($t.needsReboot) { $rebootNeeded = $true }
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
