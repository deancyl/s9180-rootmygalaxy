$adb = "D:\Google\Workspace\RootMyGalaxy\porting\tools\platform-tools\adb.exe"
$checkScript = @'
echo "=== STABILITY_CHECK ==="
date
uptime
echo "=== DAEMONS_PIDS ==="
ps -ef | grep "scripts/" | grep -v grep
echo "=== TAIL_LOG ==="
tail -n 25 /data/adb/modules/rmg_memtonic/run/memtonic.log
'@
[System.IO.File]::WriteAllText("D:\Codex\s9180-rootmygalaxy\modules\rmg_memtonic\check_stage.sh", ($checkScript -replace "`r`n", "`n"))
& $adb push "D:\Codex\s9180-rootmygalaxy\modules\rmg_memtonic\check_stage.sh" "/data/local/tmp/check_stage.sh" | Out-Null
Remove-Item "D:\Codex\s9180-rootmygalaxy\modules\rmg_memtonic\check_stage.sh" -Force
$res = & $adb shell "su -c 'sh /data/local/tmp/check_stage.sh && rm -f /data/local/tmp/check_stage.sh'"
$res
