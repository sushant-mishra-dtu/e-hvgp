#==========================================================================
# run_iverilog.ps1 -- local A/B regression using Icarus Verilog
#
# Xcelium is the PRIMARY simulator for this project (see run_xcelium.sh).
# Icarus is used here only because it is what is installed on this machine;
# the RTL is plain Verilog-2001 and is not tailored to either tool.
#
#   .\sim\run_iverilog.ps1              run every test, both configurations
#   .\sim\run_iverilog.ps1 -Test mixed  run one test
#   .\sim\run_iverilog.ps1 -Wave        also dump waves.vcd
#==========================================================================
param(
    [string]$Test = "",
    [switch]$Wave,
    [string]$IverilogBin = "C:\iverilog\bin"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
if (Test-Path $IverilogBin) { $env:PATH = "$IverilogBin;$env:PATH" }

$OutDir = Join-Path $Root "sim\out"
$ResDir = Join-Path $Root "sim\out\res"
New-Item -ItemType Directory -Force $OutDir | Out-Null
New-Item -ItemType Directory -Force $ResDir | Out-Null

Write-Host "== assembling test programs =="
python sim/build_tests.py
if ($LASTEXITCODE -ne 0) { throw "assembler failed" }

Write-Host "== compiling BASELINE (EHVGP_ENABLE=0) =="
iverilog -g2001 -o "$OutDir\base.vvp" -s tb_top -f sim/filelist.f
if ($LASTEXITCODE -ne 0) { throw "baseline compile failed" }

Write-Host "== compiling E-HVGP  (EHVGP_ENABLE=1) =="
iverilog -g2001 -D EHVGP -o "$OutDir\ehvgp.vvp" -s tb_top -f sim/filelist.f
if ($LASTEXITCODE -ne 0) { throw "e-hvgp compile failed" }

$tests = if ($Test) { @($Test) } else {
    Get-ChildItem "$Root\tests" -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName "prog.hex") } |
        ForEach-Object { $_.Name }
}

$rows = @()
$fail = 0

foreach ($t in $tests) {
    $hex = "tests/$t/prog.hex"
    foreach ($m in @("base", "ehvgp")) {
        $args = @("$OutDir\$m.vvp",
                  "+HEX=$hex", "+NAME=$t",
                  "+ARCH=sim/out/res/${t}_$m.arch",
                  "+PLACE=sim/out/res/${t}_$m.place",
                  "+MAXCYC=200000")
        if ($Wave) { $args += "+WAVE" }
        $log = & vvp $args 2>&1
        $log | Out-File -Encoding utf8 "$ResDir\${t}_$m.log"
        if ($log -match "RESULT: FAIL" -or $log -match "TIMEOUT") {
            Write-Host "  $t/$m : SIM FAIL" -ForegroundColor Red
            $fail++
        }
    }

    # ---- architectural equivalence (hard invariant) ----------------------
    $a = Get-Content "$ResDir\${t}_base.arch"
    $b = Get-Content "$ResDir\${t}_ehvgp.arch"
    $diff = Compare-Object $a $b
    $archOk = ($null -eq $diff)
    if (-not $archOk) { $fail++ }

    # ---- placement difference (expected, this is the mechanism) ----------
    $pa = (Get-Content "$ResDir\${t}_base.place")  | Where-Object { $_ -match '^v\d+ ' }
    $pb = (Get-Content "$ResDir\${t}_ehvgp.place") | Where-Object { $_ -match '^v\d+ ' }
    $placeDiff = @(Compare-Object $pa $pb).Count

    function GetC($file, $key) {
        $l = Select-String -Path $file -Pattern "^$key\s+(\d+)$"
        if ($l) { [int]$l.Matches[0].Groups[1].Value } else { 0 }
    }
    $fb = "$ResDir\${t}_base.place"
    $fe = "$ResDir\${t}_ehvgp.place"

    $rows += [pscustomobject]@{
        test        = $t
        arch_match  = $(if ($archOk) { "YES" } else { "NO" })
        place_diff  = $placeDiff
        cyc_base    = GetC $fb "cycles"
        cyc_ehvgp   = GetC $fe "cycles"
        conf_base   = GetC $fb "bank_conflicts"
        conf_ehvgp  = GetC $fe "bank_conflicts"
        stall_base  = GetC $fb "bank_stall_cycles"
        stall_ehvgp = GetC $fe "bank_stall_cycles"
        uops_base   = GetC $fb "vector_uops"
        uops_ehvgp  = GetC $fe "vector_uops"
    }
}

Write-Host ""
Write-Host "=========================================================================="
Write-Host " BASELINE vs E-HVGP        (arch_match=YES is the correctness invariant)"
Write-Host "=========================================================================="
$rows | Format-Table -AutoSize

$rows | Export-Csv -NoTypeInformation -Path "$ResDir\summary.csv"
Write-Host "wrote $ResDir\summary.csv"

if ($fail -ne 0) { Write-Host "FAILURES: $fail" -ForegroundColor Red; exit 1 }
Write-Host "all tests: architectural results identical" -ForegroundColor Green
exit 0
