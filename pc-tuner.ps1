# =====================================================================
#  pc-tuner.ps1 — the ENGINE
#
#  Tweaks live in .\modules\*.json as PURE DATA — no executable code.
#  This engine implements a small, fixed vocabulary of actions:
#
#    registry             set a registry value
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

function Get-RegValue($Path, $Name) {
    try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

function Set-RegValue($Path, $Name, $Value, $Type) {
    if (-not $Type) { $Type = 'DWord' }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Load-Backup {
    if (Test-Path $BackupPath) { Get-Content $BackupPath -Raw | ConvertFrom-Json } else { New-Object PSObject }
}

function Save-Backup($backup) {
    $backup | ConvertTo-Json -Depth 6 | Out-File $BackupPath -Encoding utf8
}

# ------------------------------------------------------- action handlers
# Each action type implements: state (current value), applied (bool),
# describe (human string), apply, revert($saved, $hasBackup).

function Get-ActionState($a) {
    switch ($a.type) {
        'registry' {
            Get-RegValue $a.path $a.name
        }
        'powercfg-scheme' {
            $out = powercfg /getactivescheme
            if ("$out" -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { $Matches[1] } else { $null }
        }
        'netadapter-advanced' {
            $h = @{}
            foreach ($p in $a.properties) {
                $cur = Get-NetAdapterAdvancedProperty -Name $a.adapter -DisplayName $p.displayName -ErrorAction SilentlyContinue
                $h[$p.displayName] = if ($cur) { $cur.DisplayValue } else { $null }
            }
            $h
        }
        default { throw "Unknown action type '$($a.type)' - engine refuses to run it." }
    }
}

function Test-ActionApplied($a) {
    switch ($a.type) {
        'registry' { (Get-ActionState $a) -eq $a.value }
        'powercfg-scheme' { (Get-ActionState $a) -eq $a.guid }
        'netadapter-advanced' {
            $cur = Get-ActionState $a
            $bad = @($a.properties | Where-Object { $cur[$_.displayName] -ne $_.value })
            $bad.Count -eq 0
        }
    }
}

function Describe-ActionState($a) {
    switch ($a.type) {
        'registry' { "$($a.name)=$(Get-ActionState $a)" }
        'powercfg-scheme' {
            $out = "$(powercfg /getactivescheme)"
            if ($out -match '\((.+)\)') { "active: $($Matches[1])" } else { 'active: unknown' }
        }
        'netadapter-advanced' {
            $cur = Get-ActionState $a
            ($a.properties | ForEach-Object { "$($_.displayName)=$($cur[$_.displayName])" }) -join ', '
        }
    }
}

function Describe-ActionChange($a) {
    switch ($a.type) {
        'registry' { "set $($a.path)\$($a.name) = $($a.value)" }
        'powercfg-scheme' { "activate power scheme $($a.guid)" }
        'netadapter-advanced' { "set adapter '$($a.adapter)': " + (($a.properties | ForEach-Object { "$($_.displayName)=$($_.value)" }) -join ', ') }
    }
}

function Invoke-ActionApply($a) {
    switch ($a.type) {
        'registry' { Set-RegValue $a.path $a.name $a.value $a.valueType }
        'powercfg-scheme' { powercfg /setactive $a.guid | Out-Null }
        'netadapter-advanced' {
            foreach ($p in $a.properties) {
                Set-NetAdapterAdvancedProperty -Name $a.adapter -DisplayName $p.displayName -DisplayValue $p.value -NoRestart
            }
            if ($a.restart) { Restart-NetAdapter -Name $a.adapter }
        }
    }
}

function Invoke-ActionRevert($a, $saved, $hasBackup) {
    switch ($a.type) {
        'registry' {
            $target = if ($hasBackup) { $saved } else { $a.default }
            if ($null -eq $target) {
                Remove-ItemProperty -Path $a.path -Name $a.name -ErrorAction SilentlyContinue
            } else {
                Set-RegValue $a.path $a.name $target $a.valueType
            }
        }
        'powercfg-scheme' {
            $target = if ($hasBackup -and $saved) { $saved } else { $a.default }
            if ($target) { powercfg /setactive $target | Out-Null }
        }
        'netadapter-advanced' {
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

$ValidActionTypes = 'registry', 'powercfg-scheme', 'netadapter-advanced'

function Test-ModuleErrors($m) {
    $errors = @()
    if (-not $m.module) { $errors += 'missing "module" name' }
    if (-not $m.tweaks) { $errors += 'missing or empty "tweaks" array'; return $errors }
    foreach ($t in @($m.tweaks)) {
        if (-not $t.id) { $errors += 'a tweak is missing "id"'; continue }
        foreach ($field in 'name', 'risk', 'why') {
            if (-not $t.$field) { $errors += "$($t.id): missing `"$field`"" }
        }
        if ($t.risk -and $t.risk -notin 'safe', 'tradeoff') { $errors += "$($t.id): risk must be 'safe' or 'tradeoff'" }
        if (-not $t.actions) { $errors += "$($t.id): no actions"; continue }
        foreach ($a in @($t.actions)) {
            if ($a.type -notin $ValidActionTypes) {
                $errors += "$($t.id): unknown action type '$($a.type)' (allowed: $($ValidActionTypes -join ', '))"
                continue
            }
            switch ($a.type) {
                'registry' {
                    foreach ($f in 'path', 'name') { if (-not $a.$f) { $errors += "$($t.id): registry action missing `"$f`"" } }
                    if ($null -eq $a.value) { $errors += "$($t.id): registry action missing `"value`"" }
                    if ($a.path -and $a.path -notmatch '^(HKLM|HKCU):\\') { $errors += "$($t.id): registry path must start with HKLM:\ or HKCU:\" }
                }
                'powercfg-scheme' {
                    if (-not $a.guid) { $errors += "$($t.id): powercfg-scheme action missing `"guid`"" }
                }
                'netadapter-advanced' {
                    if (-not $a.adapter) { $errors += "$($t.id): netadapter-advanced action missing `"adapter`"" }
                    if (-not $a.properties) { $errors += "$($t.id): netadapter-advanced action missing `"properties`"" }
                }
            }
        }
    }
    $errors
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
    foreach ($t in $m.tweaks) {
        $t | Add-Member -NotePropertyName Module -NotePropertyValue $m.module -Force
        $AllTweaks += $t
    }
}

$dups = $AllTweaks | Group-Object id | Where-Object Count -gt 1
if ($dups) { Write-Host "Duplicate tweak ids across modules: $($dups.Name -join ', ')" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- status

function Test-TweakApplied($t) {
    $notApplied = @($t.actions | Where-Object { -not (Test-ActionApplied $_) })
    $notApplied.Count -eq 0
}

function Show-Status {
    Write-Host ""
    Write-Host "PC-TUNER STATUS" -ForegroundColor Cyan
    foreach ($m in $Modules) {
        Write-Host ""
        Write-Host "  module: $($m.module)  ($($m.File))" -ForegroundColor Cyan
        Write-Host ("  " + "-" * 66)
        foreach ($t in $m.tweaks) {
            $applied = Test-TweakApplied $t
            $mark = if ($applied) { '[ON ]' } else { '[off]' }
            $color = if ($applied) { 'Green' } else { 'Yellow' }
            $riskTag = if ($t.risk -eq 'tradeoff') { '(!) ' } else { '    ' }
            $detail = ($t.actions | ForEach-Object { Describe-ActionState $_ }) -join '; '
            Write-Host ("  {0}{1} {2,-20} {3}" -f $riskTag, $mark, $t.id, $detail) -ForegroundColor $color
        }
    }
    Write-Host ""
    Write-Host "Apply safe tier:   .\pc-tuner.ps1 -Apply safe"
    Write-Host "Tradeoff tweaks:   .\pc-tuner.ps1 -Apply <id> -AcceptTradeoffs"
    Write-Host "Undo everything:   .\pc-tuner.ps1 -Revert all"
    Write-Host ""
}

# ---------------------------------------------------------------- actions

function Resolve-TweakIds($names) {
    $ids = @()
    foreach ($n in ($names -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if ($n -eq 'safe') { $ids += @($AllTweaks | Where-Object risk -eq 'safe').id }
        elseif ($n -eq 'all') { $ids += $AllTweaks.id }
        elseif ($AllTweaks.id -contains $n) { $ids += $n }
        else { Write-Host "Unknown tweak: $n (valid: $($AllTweaks.id -join ', '))" -ForegroundColor Red }
    }
    $ids | Select-Object -Unique
}

if ($StatusJson) {
    $out = foreach ($m in $Modules) {
        [pscustomobject]@{
            module      = $m.module
            file        = $m.File
            description = $m.description
            tweaks      = @(foreach ($t in $m.tweaks) {
                [pscustomobject]@{
                    id          = $t.id
                    name        = $t.name
                    risk        = $t.risk
                    needsAdmin  = [bool]$t.needsAdmin
                    needsReboot = [bool]$t.needsReboot
                    why         = $t.why
                    applied     = (Test-TweakApplied $t)
                    detail      = (($t.actions | ForEach-Object { Describe-ActionState $_ }) -join '; ')
                    changes     = @($t.actions | ForEach-Object { Describe-ActionChange $_ })
                }
            })
        }
    }
    ConvertTo-Json -InputObject @($out) -Depth 6
    exit 0
}

$rebootNeeded = $false

if ($Apply -or $Revert) {
    $mode = if ($Apply) { 'Apply' } else { 'Revert' }
    $names = if ($Apply) { $Apply } else { $Revert }
    $ids = Resolve-TweakIds $names
    $selected = @($AllTweaks | Where-Object { $ids -contains $_.id })

    if ($mode -eq 'Apply') {
        $gated = @($selected | Where-Object risk -eq 'tradeoff')
        if ($gated.Count -gt 0 -and -not $AcceptTradeoffs) {
            foreach ($g in $gated) {
                Write-Host "SKIPPED $($g.id): tradeoff - re-run with -AcceptTradeoffs after reading:" -ForegroundColor Red
                Write-Host "  $($g.why)"
            }
            $selected = @($selected | Where-Object risk -ne 'tradeoff')
        }
    }

    if ((@($selected | Where-Object needsAdmin).Count -gt 0) -and -not (Test-Admin) -and -not $DryRun) {
        Write-Host "Elevation required - relaunching as admin (accept the UAC prompt)..."
        $argList = @('-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"","-$mode",($ids -join ','))
        if ($AcceptTradeoffs) { $argList += '-AcceptTradeoffs' }
        if ($NoPause) { $argList += '-NoPause' }
        Start-Process powershell -Verb RunAs -ArgumentList $argList -Wait
        exit
    }

    try { Start-Transcript -Path (Join-Path $PSScriptRoot 'pc-tuner-last-run.log') -Force | Out-Null } catch {}

    foreach ($t in $selected) {
        try {
            if ($DryRun) {
                $verb = if ($mode -eq 'Apply') { 'would apply' } else { 'would revert' }
                Write-Host "~ $($t.id): $verb" -ForegroundColor Cyan
                foreach ($a in $t.actions) { Write-Host "    -> $(Describe-ActionChange $a)" }
                continue
            }
            if ($mode -eq 'Apply') {
                if (Test-TweakApplied $t) { Write-Host "= $($t.id): already applied"; continue }
                # back up original state once (array aligned with actions)
                $backup = Load-Backup
                if (-not ($backup.PSObject.Properties.Name -contains $t.id)) {
                    $states = @($t.actions | ForEach-Object { Get-ActionState $_ })
                    $backup | Add-Member -NotePropertyName $t.id -NotePropertyValue $states
                    Save-Backup $backup
                }
                Write-Host "+ $($t.id):" -ForegroundColor Green
                foreach ($a in $t.actions) {
                    Write-Host "    -> $(Describe-ActionChange $a)"
                    Invoke-ActionApply $a
                }
            } else {
                $backup = Load-Backup
                $hasBackup = $backup.PSObject.Properties.Name -contains $t.id
                $saved = if ($hasBackup) { $backup.$($t.id) } else { $null }
                Write-Host "- $($t.id): reverting" -ForegroundColor Yellow
                for ($i = 0; $i -lt @($t.actions).Count; $i++) {
                    $s = if ($hasBackup) { @($saved)[$i] } else { $null }
                    Invoke-ActionRevert @($t.actions)[$i] $s $hasBackup
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
    Show-Status
    try { Stop-Transcript | Out-Null } catch {}
    if (-not $NoPause) { Read-Host "Press Enter to close" | Out-Null }
} else {
    Show-Status
}
