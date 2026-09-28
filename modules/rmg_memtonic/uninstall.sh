#!/system/bin/sh
# uninstall.sh —— RMG MemTonic v1.4.1 卸载清理
# 停止守护与护栏，还原未处理的 renice 清单，删除运行时文件，
# 并清理 v1.0.0 时代遗留在 /data/local/tmp 的文件。
#
# v1.3.0 变更：①守护与护栏均有 KILL 兜底（TERM 对 sleep 中的 mksh 循环
# 可能被延迟处理，实测教训）；②清理 v1.3.0 新增的还原清单文件。

# 1. 停止守护与护栏（KILL 兜底）
for pf in /data/adb/modules/rmg_memtonic/run/memtonic.pid \
          /data/adb/modules/rmg_memtonic/run/guard.pid; do
  p=$(cat "$pf" 2>/dev/null); p=${p%%:*}
  if [ -n "$p" ] && [ -d /proc/$p ]; then
    kill "$p" 2>/dev/null
    sleep 1
    [ -d /proc/$p ] && kill -9 "$p" 2>/dev/null
  fi
done

# 2. 还原清单中尚未还原的 tid（若有）——卸载不能把别的应用留在降优先级状态
RLST=/data/local/tmp/memtonic_storm_renice.lst
if [ -s "$RLST" ]; then
  while read -r tid on ap pkg; do
    case "$ap" in ''|*[!0-9-]*) continue;; esac
    [ -d /proc/$tid ] || continue
    renice -n $((on - ap)) -p "$tid" >/dev/null 2>&1
  done < "$RLST"
fi

# 3. 删除运行时文件与历史遗留
rm -rf /data/adb/modules/rmg_memtonic/run
rm -f "$RLST"
rm -f /data/local/tmp/memtonic.log /data/local/tmp/.memtonic.pid /data/local/tmp/.memtonic.trim
