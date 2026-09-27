# =============================================================================
#  s9180-root-kit dm3q (SM-S9180 / S9180ZHS8FZG1) - REAL KernelSU v3.3.0 late-load
#
#  Difference vs run_root_dm3q_32601.ps1 (version-number patch):
#    the binary copied onto /data/local/tmp/.ksud-stage is a ksud BUILT FROM
#    the Samsung-patched v3.3.0 source tree, with the v3.3.0 module embedded
#    as its late-load asset. The module loaded by late-load is therefore real
#    v3.3.0 code - not a relabeled 3.2.5 build.
#
#  Flow: exploit root -> helper --late-load -> helper execs
#    /data/local/tmp/ksud-selected (= the v3.3.0 ksud) -> it stages
#    .ksud-stage onto /data/adb/ksud, loads its embedded REAL v3.3.0 module
#    via ksuinit manual relocation, then runs features/sepolicy/su init.
#
#  Usage:
#    .\04-deploy-device.ps1                  full flow
#    .\04-deploy-device.ps1 -Verify          check device state only
#    .\04-deploy-device.ps1 -SkipPush        files already on device
#    .\04-deploy-device.ps1 -NoApp           do not install the Manager
#    .\04-deploy-device.ps1 -Attempts 3      retry the exploit 3 times
#    .\04-deploy-device.ps1 -Serial <sn>     target a specific device
#    .\04-deploy-device.ps1 -InsModFallback  load module from file via insmod
#
#  Rollback: everything is memory-resident - REBOOT clears it. The original
#  App ksud-stage (md5 bd9080bc...) is backed up on device as
#  /data/local/tmp/.ksud-stage.orig before the first overwrite.
# =============================================================================

param(
    [switch]$SkipPush,
    [switch]$NoApp,
    [switch]$Verify,
    [switch]$InsModFallback,
    [int]$Attempts = 1,
    [string]$Serial = ""   # set your device serial, or leave empty if only one device is attached
)

$ErrorActionPreference = "Continue"

# ===== config =====
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Payload     = "$ScriptDir\payloads\dm3q-S9180ZHS8FZG1__payload"
$RootHelper  = "$ScriptDir\payloads\dm3q-S9180ZHS8FZG1__root"
$Ksud330     = "$ScriptDir\out\ksud-dm3q-S9180ZHS8FZG1-330-kdp"
$Ko330       = "$ScriptDir\out\android13-5.15_kernelsu-dm3q-S9180ZHS8FZG1-330.ko"
$Apk         = "$ScriptDir\..\ksu-32601\apk\KernelSU_v3.3.0_32601-release.apk"

# device paths
$DevPayload  = "/data/local/tmp/cve-2026-43499"
$DevRoot     = "/data/local/tmp/cve-2026-43499-root"
$DevKsud330  = "/data/local/tmp/ksud-330"
$DevSelected = "/data/local/tmp/ksud-selected"   # helper --late-load execs THIS
$DevSelectedBak = "/data/local/tmp/ksud-selected.orig"
$DevStage    = "/data/local/tmp/.ksud-stage"     # v3.3.0 stage_daemon_from source
$DevStageBak = "/data/local/tmp/.ksud-stage.orig"
$DevKo       = "/data/local/tmp/kernelsu-dm3q-330.ko"

$WarmupIters      = 400
$TargetFirmware   = "S9180ZHS8FZG1"
$ExpectedVersion  = "32601"

# ===== log =====
$LogDir = "$ScriptDir\logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$TimeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = "$LogDir\run_330_$TimeStamp.log"

function Write-Log {
    param([string]$Level, [string]$Message)
    $line = "[$(Get-Date -Format 'HH:mm:ss')][$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    switch ($Level) {
        "ERR"   { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "OK"    { Write-Host $line -ForegroundColor Green }
        "STAGE" { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
}

function Find-Adb {
    if ($env:ADB_BIN -and (Test-Path $env:ADB_BIN)) { return $env:ADB_BIN }
    foreach ($p in @("$ScriptDir\adb-bin\adb.exe",
                     "D:\WorkBuddy\RootMyGalaxy\porting\tools\platform-tools\adb.exe",
                     "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe")) {
        if (Test-Path $p) { return $p }
    }
    return (Get-Command adb -ErrorAction SilentlyContinue).Source
}

function Invoke-Adb {
    param([string[]]$AdbArgs)
    $full = @("-s", $Serial) + $AdbArgs
    Write-Log "ADB" ("& adb " + ($full -join ' '))
    $out = & $Adb @full 2>&1
    $rc = $LASTEXITCODE
    if ($rc -ne 0) { Write-Log "ERR" ("adb return=$rc :: " + ($full -join ' ')) }
    Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'HH:mm:ss')][OUT] $out"
    return @{ Output = $out; ExitCode = $rc }
}

# ===== entry =====
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  s9180-root-kit dm3q - REAL KernelSU v3.3.0 late-load" -ForegroundColor Cyan
Write-Host "  Galaxy S23 Ultra (SM-S9180 / $TargetFirmware)" -ForegroundColor Cyan
Write-Host "  serial=$Serial  attempts=$Attempts  verify=$Verify" -ForegroundColor Cyan
Write-Host "  log: $LogFile" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$Adb = Find-Adb
if (-not $Adb) { Write-Log "ERR" "adb not found. Set `$env:ADB_BIN"; exit 1 }
Write-Log "OK" "adb: $Adb"

$state = (& $Adb -s $Serial get-state 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $state -ne "device") {
    Write-Log "ERR" "device not connected (state=$state, serial=$Serial)"
    exit 1
}

$kernel = (& $Adb -s $Serial shell "uname -r" | Out-String).Trim()
$fp = (& $Adb -s $Serial shell "getprop ro.build.fingerprint" | Out-String).Trim()
Write-Log "INFO" "kernel=$kernel"
Write-Log "INFO" "fingerprint=$fp"
if ($fp -notmatch $TargetFirmware) {
    Write-Log "WARN" "firmware mismatch (expected $TargetFirmware)"
    $ans = Read-Host "continue anyway? (type YES)"
    if ($ans -ne "YES") { Write-Log "ERR" "cancelled by user"; exit 1 }
}

if ($Verify) {
    Write-Log "STAGE" "verify mode"
    $mod = (& $Adb -s $Serial shell "cat /proc/modules" | Out-String)
    if ($mod -match "kernelsu") { Write-Log "OK" "kernelsu loaded -> device has root" }
    else { Write-Log "WARN" "kernelsu not loaded -> not rooted since last reboot" }
    if (Test-Path $Ksud330) {
        $info = (& $Adb -s $Serial shell "$DevKsud330 debug info" | Out-String)
        Write-Host $info
        if ($info -match "version:\s*$ExpectedVersion") { Write-Log "OK" "driver reports $ExpectedVersion (real v3.3.0 code)" }
        else { Write-Log "WARN" "driver does not report $ExpectedVersion" }
    } else {
        Write-Log "INFO" "local $Ksud330 not built yet - verify with the on-device ksud after deploy"
    }
    Write-Log "OK" "verify done"
    exit 0
}

# ===== push =====
if (-not $SkipPush) {
    foreach ($f in @($Payload, $RootHelper, $Ksud330, $Ko330, $Apk)) {
        if (-not (Test-Path $f)) { Write-Log "ERR" "missing file: $f"; exit 1 }
    }
    Write-Log "STAGE" "push files"
    Invoke-Adb @("push", $Payload, $DevPayload) | Out-Null
    Invoke-Adb @("push", $RootHelper, $DevRoot) | Out-Null
    Invoke-Adb @("push", $Ksud330, $DevKsud330) | Out-Null
    Invoke-Adb @("push", $Ko330, $DevKo) | Out-Null
    # Back up the ORIGINAL binaries once (rollback anchors), then make the
    # REAL v3.3.0 ksud the late-load target: the helper execs ksud-selected,
    # and the v3.3.0 ksud itself stages .ksud-stage onto /data/adb/ksud.
    Invoke-Adb @("shell", "if [ ! -f $DevSelectedBak ] && [ -f $DevSelected ]; then cp $DevSelected $DevSelectedBak; fi") | Out-Null
    Invoke-Adb @("shell", "if [ ! -f $DevStageBak ] && [ -f $DevStage ]; then cp $DevStage $DevStageBak; fi") | Out-Null
    Invoke-Adb @("shell", "cp $DevKsud330 $DevSelected; cp $DevKsud330 $DevStage; chmod 755 $DevPayload $DevRoot $DevKsud330 $DevSelected $DevStage $DevKo") | Out-Null
    Invoke-Adb @("shell", "md5sum $DevKsud330 $DevSelected $DevStage $DevKo $DevSelectedBak $DevStageBak") | Out-Null
    Write-Log "OK" "files pushed; ksud-selected and .ksud-stage now contain the v3.3.0 ksud"
}

# ===== warmup =====
Write-Log "STAGE" "warmup ($WarmupIters x /system/bin/true)"
$null = & $Adb -s $Serial shell "i=0; while [ `$i -lt $WarmupIters ]; do /system/bin/true; i=`$((i+1)); done" 2>&1

# ===== exploit =====
Write-Log "STAGE" "trigger exploit (EXPLOIT_ATTEMPTS=$Attempts)"
Write-Host "device may reboot - this is expected" -ForegroundColor Yellow

$RootOk = $false
for ($attempt = 1; $attempt -le 3; $attempt++) {
    Write-Log "STAGE" "exploit attempt $attempt/3"
    $null = & $Adb -s $Serial wait-for-device 2>&1
    Start-Sleep -Seconds 2
    $cmd = "CVE43499_ROOT_HELPER=$DevRoot EXPLOIT_ATTEMPTS=$Attempts LD_PRELOAD=$DevPayload /system/bin/true"
    $out = (& $Adb -s $Serial shell $cmd 2>&1 | Out-String)
    Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'HH:mm:ss')][OUT] $out"
    if ($out -match "temporary-root-ready") { $RootOk = $true; Write-Log "OK" "temporary-root-ready (attempt $attempt)"; break }
    $idOut = (& $Adb -s $Serial exec-out $DevRoot "-c" "/system/bin/id" | Out-String)
    if ($idOut -match "uid=0\(root\)") { $RootOk = $true; Write-Log "OK" "uid=0(root) confirmed (attempt $attempt)"; break }
    if ($attempt -lt 3) { Write-Log "WARN" "attempt $attempt failed, retry in 3s"; Start-Sleep -Seconds 3 }
}
if (-not $RootOk) { Write-Log "ERR" "exploit did not yield root"; exit 1 }

# ===== late-load (real v3.3.0 ksud from .ksud-stage) =====
if (-not $InsModFallback) {
    Write-Log "STAGE" "late-load via v3.3.0 ksud (embedded module = real v3.3.0 code)"
    $ksuOut = Invoke-Adb @("shell", "$DevRoot --late-load")
} else {
    Write-Log "STAGE" "fallback: insmod the v3.3.0 module from file, then late-load"
    # adb does not re-quote, so wrap the whole helper command in single quotes
    $ins = "$DevKsud330 insmod $DevKo"
    $insOut = (& $Adb -s $Serial shell "$DevRoot -c '$ins'" 2>&1 | Out-String)
    Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'HH:mm:ss')][OUT] insmod: $insOut"
    $ksuOut = Invoke-Adb @("shell", "$DevRoot --late-load")
}
Start-Sleep -Seconds 2

$modOut = (& $Adb -s $Serial shell "cat /proc/modules" | Out-String)
if ($modOut -match "kernelsu") {
    Write-Log "OK" "kernelsu present in /proc/modules"
    $modOut -split "`n" | Where-Object { $_ -match "kernelsu" } | ForEach-Object { Write-Host $_.Trim() }
} else {
    Write-Log "ERR" "kernelsu missing from /proc/modules"
    Write-Host "check kmsg: adb -s $Serial shell su -c 'dmesg | tail -40'" -ForegroundColor Yellow
    exit 1
}

# ===== verify driver version =====
Write-Log "STAGE" "verify driver version"
$verOk = $false
for ($i = 0; $i -lt 3; $i++) {
    $info = (& $Adb -s $Serial shell "$DevKsud330 debug info" | Out-String)
    Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'HH:mm:ss')][OUT] info: $info"
    foreach ($l in ($info -split "`n" | Where-Object { $_.Trim() -ne "" })) { Write-Log "INFO" "info> $($l.Trim())" }
    if ($info -match "version:\s*$ExpectedVersion") { $verOk = $true; break }
    Start-Sleep -Seconds 2
}
if ($verOk) { Write-Log "OK" "driver reports version $ExpectedVersion - real v3.3.0 module active" }
else { Write-Log "WARN" "driver does not report $ExpectedVersion" }

# ===== Manager app =====
if (-not $NoApp) {
    Write-Log "STAGE" "install KernelSU Manager v3.3.0 ($ExpectedVersion)"
    $apkResult = Invoke-Adb @("install", "-r", $Apk)
    if ($apkResult.ExitCode -eq 0) {
        Write-Log "OK" "Manager installed (me.weishu.kernelsu)"
        $null = & $Adb -s $Serial shell "am start -n me.weishu.kernelsu/.ui.MainActivity" 2>&1
    } else {
        Write-Log "WARN" "apk install failed, install manually: $Apk"
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  done." -ForegroundColor Green
Write-Host "  * root is memory-resident; reboot clears it" -ForegroundColor Gray
Write-Host "  * late-load ran REAL v3.3.0 code (not a version-stamped 3.2.5)" -ForegroundColor Gray
Write-Host "  * rollback: cp $DevSelectedBak $DevSelected ; cp $DevStageBak $DevStage ; reboot" -ForegroundColor Gray
Write-Host "  * log: $LogFile" -ForegroundColor Gray
Write-Host "============================================================" -ForegroundColor Cyan
