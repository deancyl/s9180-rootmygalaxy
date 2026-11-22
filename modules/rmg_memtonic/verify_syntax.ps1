$sh = "C:\Program Files\Git\bin\sh.exe"
$repoRoot = "D:\Codex\s9180-rootmygalaxy\modules\rmg_memtonic"
$scripts = @(
    "$repoRoot\scripts\memtonic.sh",
    "$repoRoot\scripts\fluency_shield.sh",
    "$repoRoot\scripts\mt_lib.sh",
    "$repoRoot\service.sh",
    "$repoRoot\hotinstall.sh",
    "$repoRoot\customize.sh",
    "$repoRoot\uninstall.sh",
    "$repoRoot\action.sh"
)

Write-Host "=== 开始执行静态语法校验 (sh -n) ===" -ForegroundColor Cyan
$failed = 0
foreach ($s in $scripts) {
    if (Test-Path $s) {
        & $sh -n $s
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [FAIL] $s" -ForegroundColor Red
            $failed++
        } else {
            Write-Host "  [PASS] $s" -ForegroundColor Green
        }
    } else {
        Write-Host "  [WARN] 未找到文件: $s" -ForegroundColor Yellow
        $failed++
    }
}
if ($failed -gt 0) {
    Write-Host "=== 静态语法校验未通过 (失败: $failed) ===" -ForegroundColor Red
    exit 1
} else {
    Write-Host "=== 静态语法校验全部通过 ===" -ForegroundColor Green
    exit 0
}
