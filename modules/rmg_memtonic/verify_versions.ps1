$repoRoot = "D:\Codex\s9180-rootmygalaxy\modules\rmg_memtonic"
$propFile = Join-Path $repoRoot "module.prop"
$propContent = Get-Content $propFile -Raw
$version = ""
if ($propContent -match 'version=(v?[0-9.]+)') { $version = $matches[1] }
$verNum = $version.TrimStart('v')
$vc = ""
if ($propContent -match 'versionCode=([0-9]+)') { $vc = $matches[1] }

$files = @(
    "module.prop",
    "scripts\mt_lib.sh",
    "scripts\memtonic.sh",
    "scripts\fluency_shield.sh",
            "service.sh",
    "customize.sh",
    "hotinstall.sh",
    "uninstall.sh",
    "README.md",
    "CHANGELOG.md"
)

Write-Host "=== 验证版本号一致性 ($version, code=$vc) ===" -ForegroundColor Cyan
$allPass = $true
foreach ($f in $files) {
    $p = Join-Path $repoRoot $f
    $matches = Select-String -Path $p -Pattern "(v?$verNum|versionCode=$vc|vc$vc)"
    if ($matches) {
        Write-Host "  [OK] $f : $($matches.Count) match(es)" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $f : No match found!" -ForegroundColor Red
        $allPass = $false
    }
}
if ($allPass) {
    Write-Host "=== 所有文件版本号校验全部通过 ===" -ForegroundColor Green
} else {
    Write-Host "=== 存在版本号未对齐文件 ===" -ForegroundColor Red
}
