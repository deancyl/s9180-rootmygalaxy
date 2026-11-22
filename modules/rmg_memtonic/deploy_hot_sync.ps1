# deploy_hot_sync.ps1 —— RMG MemTonic v1.13.22 热更新部署与实机验证脚本
$ErrorActionPreference = "Stop"

$adb = "D:\Google\Workspace\RootMyGalaxy\porting\tools\platform-tools\adb.exe"
$src = "D:\Codex\s9180-rootmygalaxy\modules\rmg_memtonic"
$dst = "/data/adb/modules/rmg_memtonic"
$tmp = "/data/local/tmp/rmg_memtonic_stage"
$sh = "C:\Program Files\Git\bin\sh.exe"

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  RMG MemTonic v1.13.22 热更新部署与真机现场验证  " -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

# 1. 本地静态语法检查
Write-Host "`n[1/7] 本地 Shell 语法检查 (sh -n)..." -ForegroundColor Yellow
$scripts = @(
    "$src\scripts\memtonic.sh",
    "$src\scripts\storm_guard.sh",
    "$src\scripts\fluency_shield.sh",
    "$src\scripts\cpu_guard.sh",
    "$src\scripts\mt_lib.sh",
    "$src\scripts\vk_injector.sh",
    "$src\scripts\in_app_stress_test.sh",
    "$src\service.sh",
    "$src\hotinstall.sh",
    "$src\customize.sh",
    "$src\uninstall.sh"
)
foreach ($s in $scripts) {
    if (Test-Path $s) {
        & $sh -n $s
        if ($LASTEXITCODE -ne 0) {
            Write-Error "脚本语法错误: $s"
            exit 1
        }
        Write-Host "  [PASS] $(Split-Path $s -Leaf)" -ForegroundColor Green
    }
}

# 2. 检查设备连接与 Root 权限
Write-Host "`n[2/7] 检查设备连接与 Root 权限..." -ForegroundColor Yellow
$devOut = & $adb devices
Write-Host ($devOut | Out-String)
$targetDev = ($devOut | Select-String "([A-Za-z0-9]+)\s+device$") | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1
if (-not $targetDev) {
    Write-Error "未找到处于已连接 (device) 状态的 Android 手机，请检查 USB 调试！"
    exit 1
}
Write-Host "目标设备序列号: $targetDev" -ForegroundColor Green

$rootId = (& $adb -s $targetDev shell "su -c 'id'" | Out-String).Trim()
Write-Host "Root 验证: $rootId" -ForegroundColor Green
if ($rootId -notmatch "uid=0") {
    Write-Error "设备未获得 Root 权限 ($rootId)"
    exit 1
}

# 3. 停止当前旧守护并清理旧标志位，还原内核参数
Write-Host "`n[3/7] 停止旧守护、清理旧标志位、还原三星原生 VM 内核参数..." -ForegroundColor Yellow
$stopCmd = @'
sh /data/adb/modules/rmg_memtonic/scripts/memtonic.sh stop 2>/dev/null
pkill -9 -f "scripts/storm_guard.sh" 2>/dev/null
pkill -9 -f "scripts/cpu_guard.sh" 2>/dev/null
pkill -9 -f "scripts/fluency_shield.sh" 2>/dev/null
pkill -9 -f "scripts/memtonic.sh" 2>/dev/null
# 立即还原三星 S9180 原生 VM 参数
sysctl -w vm.watermark_scale_factor=37 2>/dev/null
sysctl -w vm.swappiness=145 2>/dev/null
sysctl -w vm.page-cluster=0 2>/dev/null
# 清理所有误报与残留标志位
rm -f /data/adb/modules/rmg_memtonic/run/*.flag 2>/dev/null
rm -f /data/adb/modules/rmg_memtonic/run/paging_storm.* 2>/dev/null
rm -f /data/adb/modules/rmg_memtonic/run/ss_heap.* 2>/dev/null
rm -f /data/adb/modules/rmg_memtonic/run/reboot_suppressed.flag 2>/dev/null
rm -f /data/adb/modules/rmg_memtonic/run/soft_reboot_advised.flag 2>/dev/null
rm -f /data/adb/modules/rmg_memtonic/run/ss_heap_extreme.flag 2>/dev/null
rm -f /data/adb/modules/rmg_memtonic/run/mem_forecast.flag 2>/dev/null
rm -f /data/adb/modules/rmg_memtonic/run/ss_gc_boost.pids 2>/dev/null
# 还原 GC 线程特权
ss_pid=$(pidof system_server); ss_pid=${ss_pid%% *}
if [ -n "$ss_pid" ]; then
  for tid in /proc/$ss_pid/task/*; do
    t=${tid##*/}
    comm=$(cat /proc/$ss_pid/task/$t/comm 2>/dev/null)
    case "$comm" in
      *GC*|*Heap*|*Jit*)
        renice -n 0 -p $t 2>/dev/null
        taskset -p 7f $t 2>/dev/null
        ;;
    esac
  done
fi
'@
[System.IO.File]::WriteAllText("$src\stop_stage.sh", ($stopCmd -replace "`r`n", "`n"))
& $adb -s $targetDev push "$src\stop_stage.sh" "/data/local/tmp/stop_stage.sh" | Out-Null
Remove-Item "$src\stop_stage.sh" -Force
& $adb -s $targetDev shell "su -c 'sh /data/local/tmp/stop_stage.sh && rm -f /data/local/tmp/stop_stage.sh'" | Out-Null
Start-Sleep -Seconds 2
Write-Host "  [OK] 旧守护已停止，旧标志位已清除，内核参数已还原 (watermark=37, swappiness=145)" -ForegroundColor Green

# 4. 推送文件至暂存目录
Write-Host "`n[4/7] 推送新版本文件至设备暂存目录 $tmp..." -ForegroundColor Yellow
& $adb -s $targetDev shell "rm -rf $tmp && mkdir -p $tmp/scripts" | Out-Null
& $adb -s $targetDev push "$src\module.prop" "$tmp/module.prop" | Out-Null
& $adb -s $targetDev push "$src\service.sh" "$tmp/service.sh" | Out-Null
& $adb -s $targetDev push "$src\hotinstall.sh" "$tmp/hotinstall.sh" | Out-Null
& $adb -s $targetDev push "$src\customize.sh" "$tmp/customize.sh" | Out-Null
& $adb -s $targetDev push "$src\uninstall.sh" "$tmp/uninstall.sh" | Out-Null
& $adb -s $targetDev push "$src\README.md" "$tmp/README.md" | Out-Null
& $adb -s $targetDev push "$src\CHANGELOG.md" "$tmp/CHANGELOG.md" | Out-Null
Get-ChildItem "$src\scripts\*.sh" | ForEach-Object {
    & $adb -s $targetDev push $_.FullName "$tmp/scripts/$($_.Name)" | Out-Null
}
Write-Host "  [OK] 全部文件推送完毕" -ForegroundColor Green

# 5. 覆盖到目标目录并精准赋权 (严禁触碰 webroot)
Write-Host "`n[5/7] 覆盖到 $dst 并严格赋权 (保持 webroot 不变)..." -ForegroundColor Yellow
$copyCmd = @'
cp -f /data/local/tmp/rmg_memtonic_stage/module.prop /data/adb/modules/rmg_memtonic/module.prop
cp -f /data/local/tmp/rmg_memtonic_stage/service.sh /data/adb/modules/rmg_memtonic/service.sh
cp -f /data/local/tmp/rmg_memtonic_stage/hotinstall.sh /data/adb/modules/rmg_memtonic/hotinstall.sh
cp -f /data/local/tmp/rmg_memtonic_stage/customize.sh /data/adb/modules/rmg_memtonic/customize.sh
cp -f /data/local/tmp/rmg_memtonic_stage/uninstall.sh /data/adb/modules/rmg_memtonic/uninstall.sh
cp -f /data/local/tmp/rmg_memtonic_stage/README.md /data/adb/modules/rmg_memtonic/README.md
cp -f /data/local/tmp/rmg_memtonic_stage/CHANGELOG.md /data/adb/modules/rmg_memtonic/CHANGELOG.md
cp -rf /data/local/tmp/rmg_memtonic_stage/scripts/* /data/adb/modules/rmg_memtonic/scripts/
rm -rf /data/local/tmp/rmg_memtonic_stage

chown -R 0:0 /data/adb/modules/rmg_memtonic/scripts
chmod 0755 /data/adb/modules/rmg_memtonic/scripts
chmod 0755 /data/adb/modules/rmg_memtonic/scripts/*.sh
chown 0:0 /data/adb/modules/rmg_memtonic/service.sh /data/adb/modules/rmg_memtonic/hotinstall.sh /data/adb/modules/rmg_memtonic/customize.sh /data/adb/modules/rmg_memtonic/uninstall.sh /data/adb/modules/rmg_memtonic/module.prop /data/adb/modules/rmg_memtonic/README.md /data/adb/modules/rmg_memtonic/CHANGELOG.md
chmod 0755 /data/adb/modules/rmg_memtonic/service.sh /data/adb/modules/rmg_memtonic/hotinstall.sh /data/adb/modules/rmg_memtonic/customize.sh /data/adb/modules/rmg_memtonic/uninstall.sh
chmod 0644 /data/adb/modules/rmg_memtonic/module.prop /data/adb/modules/rmg_memtonic/README.md /data/adb/modules/rmg_memtonic/CHANGELOG.md
'@
[System.IO.File]::WriteAllText("$src\copy_stage.sh", ($copyCmd -replace "`r`n", "`n"))
& $adb -s $targetDev push "$src\copy_stage.sh" "/data/local/tmp/copy_stage.sh" | Out-Null
Remove-Item "$src\copy_stage.sh" -Force
& $adb -s $targetDev shell "su -c 'sh /data/local/tmp/copy_stage.sh && rm -f /data/local/tmp/copy_stage.sh'" | Out-Null
Write-Host "  [OK] 覆盖与权限配置完成 (webroot 目录权限未触碰)" -ForegroundColor Green

# 6. 重启守护
Write-Host "`n[6/7] 启动新守护进程并等待初始化..." -ForegroundColor Yellow
& $adb -s $targetDev shell "su -c 'sh $dst/service.sh'"
Start-Sleep -Seconds 5

# 7. 全量验收断言与真机基线提取
Write-Host "`n[7/7] 执行真机状态检查与基线数据提取..." -ForegroundColor Yellow
$verifyScript = @'
echo "=== DAEMONS ==="
for d in memtonic.sh cpu_guard.sh storm_guard.sh fluency_shield.sh; do
  cnt=$(ps -ef | grep "scripts/$d" | grep -v grep | wc -l)
  echo "$d instance_count: $cnt"
done

echo "=== VM_PARAMS ==="
echo "watermark_scale_factor=$(cat /proc/sys/vm/watermark_scale_factor)"
echo "page-cluster=$(cat /proc/sys/vm/page-cluster)"
echo "swappiness=$(cat /proc/sys/vm/swappiness)"

echo "=== VERSIONS ==="
grep "^version=" /data/adb/modules/rmg_memtonic/module.prop
grep -m1 "event=start ver=" /data/adb/modules/rmg_memtonic/run/memtonic.log 2>/dev/null

echo "=== JAVA_HEAP_CHECK ==="
ss_pid=$(pidof system_server); ss_pid=${ss_pid%% *}
java_heap=$(awk '
  /^\[anon:dalvik-(main space|large object space|non moving space|zygote space)/ { in_j=1; next }
  /^[0-9a-f]+-[0-9a-f]+ / { in_j=0 }
  in_j && /^Pss:/ { p += $2 }
  in_j && /^SwapPss:/ { s += $2 }
  END { print p + s + 0 }
' "/proc/$ss_pid/smaps" 2>/dev/null)
echo "system_server_pid=$ss_pid dalvik_java_heap_kb=$java_heap"

echo "=== FLAGS_CLEAN ==="
ls /data/adb/modules/rmg_memtonic/run/*.flag 2>/dev/null || echo "flags_clean_ok"
ls /data/adb/modules/rmg_memtonic/run/ss_heap.* 2>/dev/null || echo "ss_heap_clean_ok"

echo "=== RECENT_LOG ==="
tail -n 15 /data/adb/modules/rmg_memtonic/run/memtonic.log 2>/dev/null

echo "=== OBJECTS ==="
dumpsys meminfo $ss_pid | awk '/Objects/,/SQL/ {print}'
'@
[System.IO.File]::WriteAllText("$src\verify_device.sh", ($verifyScript -replace "`r`n", "`n"))
& $adb -s $targetDev push "$src\verify_device.sh" "/data/local/tmp/verify_device.sh" | Out-Null
Remove-Item "$src\verify_device.sh" -Force

$verOutput = (& $adb -s $targetDev shell "su -c 'sh /data/local/tmp/verify_device.sh && rm -f /data/local/tmp/verify_device.sh'" | Out-String)
Write-Host $verOutput

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  RMG MemTonic v1.13.22 部署与验证全部完成!       " -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Cyan
