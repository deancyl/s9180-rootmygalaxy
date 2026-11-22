$repoRoot = "D:\Codex\s9180-rootmygalaxy\modules\rmg_memtonic"
$dc = Select-String -Path "$repoRoot\scripts\*" -Pattern "drop_caches"
Write-Host "=== 检查 drop_caches 分布 ===" -ForegroundColor Cyan
$bad = 0
foreach ($m in $dc) {
    Write-Host "$($m.Filename):$($m.LineNumber): $($m.Line.Trim())"
    if ($m.Line -match "echo [23] >.*drop_caches") {
        Write-Host "  [FAIL] 包含自动 echo 2 或 3!" -ForegroundColor Red
        $bad++
    }
}
if ($bad -eq 0) {
    Write-Host "=== drop_caches 检查通过：无任何自动 echo 2 或 3 ===" -ForegroundColor Green
    exit 0
} else {
    Write-Host "=== drop_caches 检查失败 ===" -ForegroundColor Red
    exit 1
}
