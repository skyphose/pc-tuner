# =====================================================================
#  tests/roundtrip.ps1 - end-to-end test of the engine, no admin needed
#
#  Copies the engine into a temp folder with a test-only module that
#  touches nothing but HKCU:\Software\pc-tuner-selftest, then checks:
#  apply, idempotent re-apply, dry-run, tradeoff gating, backup format,
#  exact revert, no-backup revert, and module validation.
#
#  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\roundtrip.ps1
#  Exits 1 on the first failed check.
# =====================================================================

$ErrorActionPreference = 'Stop'
$Key = 'HKCU:\Software\pc-tuner-selftest'
$Work = Join-Path ([IO.Path]::GetTempPath()) ("pc-tuner-test-" + [guid]::NewGuid().ToString('N'))
$Engine = Join-Path $Work 'pc-tuner.ps1'
$script:Failed = 0

function Check($name, $cond) {
    if ($cond) { Write-Host "  ok   $name" -ForegroundColor Green }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:Failed++ }
}

function Run([string[]]$EngineArgs) {
    @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Engine @EngineArgs -NoPause 6>&1 | ForEach-Object { "$_" })
}

function Get-TestValue($name) { (Get-ItemProperty $Key -Name $name -ErrorAction SilentlyContinue).$name }

function Reset-TestKey {
    if (Test-Path $Key) { Remove-Item $Key -Recurse -Force }
    New-Item $Key -Force | Out-Null
    New-ItemProperty $Key -Name Existing -Value 5 -PropertyType DWord | Out-Null
    New-ItemProperty $Key -Name Flags -Value 'Keep=1;Mine=0;' -PropertyType String | Out-Null
}

$module = @'
{"module":"selftest","tweaks":[
 {"id":"t-new","name":"creates a value","risk":"safe","why":"test","actions":[
   {"type":"registry","path":"HKCU:\\Software\\pc-tuner-selftest","name":"New","value":1,"valueType":"DWord"}]},
 {"id":"t-existing","name":"overwrites + string","risk":"safe","why":"test","actions":[
   {"type":"registry","path":"HKCU:\\Software\\pc-tuner-selftest","name":"Existing","value":0,"valueType":"DWord"},
   {"type":"registry","path":"HKCU:\\Software\\pc-tuner-selftest","name":"Str","value":"0","valueType":"String"}]},
 {"id":"t-flags","name":"merges a flag","risk":"safe","why":"test","actions":[
   {"type":"registry-flags","path":"HKCU:\\Software\\pc-tuner-selftest","name":"Flags","flags":[{"key":"Mine","value":"1"}]}]},
 {"id":"t-trade","name":"gated","risk":"tradeoff","why":"test","actions":[
   {"type":"registry","path":"HKCU:\\Software\\pc-tuner-selftest","name":"Trade","value":1}]}
]}
'@

try {
    New-Item -ItemType Directory (Join-Path $Work 'modules') -Force | Out-Null
    Copy-Item (Join-Path $PSScriptRoot '..\pc-tuner.ps1') $Engine
    Set-Content (Join-Path $Work 'modules\selftest.json') $module
    Reset-TestKey

    Write-Host "dry-run"
    $out = Run '-Apply', 'all', '-DryRun'
    Check 'dry-run previews safe tweaks' (@($out -match '^~ t-new: would apply').Count -eq 1)
    Check 'dry-run changes nothing' ($null -eq (Get-TestValue New) -and (Get-TestValue Existing) -eq 5)
    Check 'dry-run writes no backup' (-not (Test-Path (Join-Path $Work 'pc-tuner-backup.json')))

    Write-Host "apply"
    $out = Run '-Apply', 'all'
    Check 'tradeoff skipped without -AcceptTradeoffs' (@($out -match '^SKIPPED t-trade').Count -eq 1 -and $null -eq (Get-TestValue Trade))
    Check 'new value created' ((Get-TestValue New) -eq 1)
    Check 'existing DWord overwritten' ((Get-TestValue Existing) -eq 0)
    Check 'string value written' ((Get-TestValue Str) -eq '0')
    Check 'flag merged, others preserved' ((Get-TestValue Flags) -eq 'Keep=1;Mine=1;')

    $out = Run '-Apply', 'all', '-AcceptTradeoffs'
    Check 're-apply is idempotent' (@($out -match '^= t-(new|existing|flags): already applied').Count -eq 3)
    Check 'tradeoff applied with -AcceptTradeoffs' ((Get-TestValue Trade) -eq 1)

    Write-Host "backup"
    $backup = Get-Content (Join-Path $Work 'pc-tuner-backup.json') -Raw | ConvertFrom-Json
    Check 'backup entries are plain arrays' (($backup.'t-existing' -is [array]) -and @($backup.'t-existing').Count -eq 2)
    Check 'backup holds original values' (@($backup.'t-existing')[0] -eq 5 -and @($backup.'t-flags')[0] -eq 'Keep=1;Mine=0;')

    Write-Host "revert"
    Run '-Revert', 'all' | Out-Null
    Check 'created value removed' ($null -eq (Get-TestValue New))
    Check 'overwritten value restored' ((Get-TestValue Existing) -eq 5)
    Check 'absent string removed' ($null -eq (Get-TestValue Str))
    Check 'flag string restored exactly' ((Get-TestValue Flags) -eq 'Keep=1;Mine=0;')
    Check 'tradeoff value removed' ($null -eq (Get-TestValue Trade))

    Write-Host "revert without backup"
    Remove-Item (Join-Path $Work 'pc-tuner-backup.json')
    Set-ItemProperty $Key -Name Flags -Value 'Keep=1;Mine=1;'
    Set-ItemProperty $Key -Name Existing -Value 7
    $out = Run '-Revert', 'all'
    Check "'revert all' skips tweaks pc-tuner never changed" (@($out -match '^= t-existing: never changed').Count -eq 1 -and (Get-TestValue Existing) -eq 7)
    Run '-Revert', 't-flags' | Out-Null
    Check 'explicit revert strips only our flag' ((Get-TestValue Flags) -eq 'Keep=1;')

    Write-Host "already-applied tweaks still get a backup"
    Set-ItemProperty $Key -Name Existing -Value 0; Set-ItemProperty $Key -Name Str -Value '0'
    Run '-Apply', 't-existing' | Out-Null
    $out = Run '-Revert', 'all', '-DryRun'
    Check 'backed up even though already applied' (@($out -match '^~ t-existing: would revert').Count -eq 1)
    Check 'dry-run revert shows values' (@($out -match 'Existing := 0').Count -eq 1)

    Write-Host "tampered backup"
    Set-Content (Join-Path $Work 'pc-tuner-backup.json') '{ "t-existing": [ {"evil": 1}, "x" ], "t-new": [ 1, 2 ] }'
    $out = Run '-Revert', 't-existing,t-new'
    Check 'non-scalar backup value refused' (@($out -match '^x t-existing: FAILED - backup entry').Count -eq 1 -and (Get-TestValue Existing) -eq 0)
    Check 'wrong-length backup refused' (@($out -match '^x t-new: FAILED - backup entry').Count -eq 1)

    Write-Host "validation"
    Set-Content (Join-Path $Work 'modules\evil.json') @'
{"module":"evil","tweaks":[
 {"id":"e1","name":"n","risk":"safe","why":"w","actions":[{"type":"exec","cmd":"calc"}]},
 {"id":"e2","name":"n","risk":"safe","why":"w","actions":[{"type":"registry","path":"HKCR:\\x","name":"v","value":0}]}
]}
'@
    $out = Run @()
    Check 'invalid module skipped' (@($out -match '^SKIPPING evil.json').Count -eq 1)
    Check 'unknown action type rejected' (@($out -match "unknown action type 'exec'").Count -eq 1)
    Check 'non-HKLM/HKCU path rejected' (@($out -match 'e2: registry path').Count -eq 1)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Engine -Validate | Out-Null
    Check '-Validate exits 1 when a module is invalid' ($LASTEXITCODE -eq 1)

    # each case is a separate module so one rejection can't mask another
    $evil = [ordered]@{
        'autostart Run key'      = '{"type":"registry","path":"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run","name":"x","value":"calc.exe","valueType":"String"}'
        'fodhelper COM hijack'   = '{"type":"registry","path":"HKCU:\\Software\\Classes\\ms-settings\\Shell\\Open\\command","name":"","value":"calc.exe","valueType":"String"}'
        'UAC off via policies'   = '{"type":"registry","path":"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System","name":"EnableLUA","value":0}'
        'disable a service'      = '{"type":"registry","path":"HKLM:\\SYSTEM\\CurrentControlSet\\Services\\WinDefend","name":"Start","value":4}'
        'dot-dot traversal'      = '{"type":"registry","path":"HKCU:\\Software\\Microsoft\\GameBar\\..\\..\\Microsoft\\Windows\\CurrentVersion\\Run","name":"x","value":1}'
        'wildcard path'          = '{"type":"registry","path":"HKCU:\\Software\\Microsoft\\Game*","name":"x","value":1}'
        'wildcard value name'    = '{"type":"registry","path":"HKCU:\\Control Panel\\Mouse","name":"Mouse*","value":1}'
        'array as value'         = '{"type":"registry","path":"HKCU:\\Software\\pc-tuner-selftest","name":"x","value":[1,2]}'
        'array as type'          = '{"type":["registry","powercfg-scheme"],"path":"HKCU:\\Software\\x","name":"x","value":1}'
        'bad valueType'          = '{"type":"registry","path":"HKCU:\\Software\\x","name":"x","value":1,"valueType":"Binary"}'
        'powercfg arg injection' = '{"type":"powercfg-scheme","guid":["scheme_min","/energy"]}'
        'non-GUID default'       = '{"type":"powercfg-scheme","guid":"8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c","default":"scheme_max"}'
        'wildcard adapter'       = '{"type":"netadapter-advanced","adapter":"*","properties":[{"displayName":"*","value":"Disabled"}]}'
        'flag injection'         = '{"type":"registry-flags","path":"HKCU:\\Software\\x","name":"x","flags":[{"key":"A","value":"1;B=2"}]}'
        'control chars'          = '{"type":"registry","path":"HKCU:\\Software\\x","name":"x\u001b[2K\r","value":1}'
    }
    Remove-Item (Join-Path $Work 'modules\evil.json')
    $i = 0
    foreach ($case in $evil.Keys) {
        $i++
        $json = '{"module":"evil' + $i + '","tweaks":[{"id":"evil-' + $i + '","name":"n","risk":"safe","why":"w","actions":[' + $evil[$case] + ']}]}'
        Set-Content (Join-Path $Work "modules\evil$i.json") $json
    }
    $out = Run @()
    $i = 0
    foreach ($case in $evil.Keys) { $i++; Check "rejected: $case" (@($out -match "^SKIPPING evil$i\.json").Count -eq 1) }
    $id = '"x,memory-integrity -AcceptTradeoffs"'
    Set-Content (Join-Path $Work 'modules\evil-id.json') ('{"module":"e","tweaks":[{"id":' + $id + ',"name":"n","risk":"safe","why":"w","actions":[{"type":"registry","path":"HKCU:\\Software\\x","name":"x","value":1}]}]}')
    $out = Run @()
    Check 'rejected: argument injection via id' (@($out -match '^SKIPPING evil-id\.json').Count -eq 1)
}
finally {
    if (Test-Path $Key) { Remove-Item $Key -Recurse -Force }
    if (Test-Path $Work) { Remove-Item $Work -Recurse -Force }
}

if ($script:Failed) { Write-Host "$script:Failed check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "all checks passed" -ForegroundColor Green
