#!/system/bin/sh
# uninstall.sh —— RMG MemTonic v1.9.6 卸载清理
# 停止守护与护栏，还原未处理的 renice 清单，删除运行时文件，
# 并清理 v1.0.0 时代遗留在 /data/local/tmp 的文件。

MODDIR=$(dirname "$0")

# 1. 停止守护与护栏（KILL 兜底）
for pf in "$MODDIR/run/memtonic.pid" \
          "$MODDIR/run/guard.pid"; do
  p=$(cat "$pf" 2>/dev/null); p=${p%%:*}
  if [ -n "$p" ] && [ -d /proc/$p ]; then
    cmd=$(cat /proc/$p/cmdline 2>/dev/null)
    case "$cmd" in
      *memtonic*|*guard*|*shield*)
        kill "$p" 2>/dev/null
        sleep 1
        [ -d /proc/$p ] && kill -9 "$p" 2>/dev/null
        ;;
    esac
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

# Source the runtime constants/files early so flush_guard_restore can find
# $RUN/flush_guard.bak before the run directory is removed.
. "$MODDIR/scripts/mt_lib.sh" 2>/dev/null
flush_guard_restore 2>/dev/null
bt2_guard_restore 2>/dev/null
# v1.13.16 B0: 卸载同样补全 kill -9 跳过的清场（GC 提权 / 相机亲和 / 核亲和）
gc_boost_off 2>/dev/null
camera_affinity_off 2>/dev/null
if [ -s "$MODDIR/run/affinity_constrained.lst" ]; then
  while read -r _ap _apkg _aorig; do
    case "$_ap" in ''|*[!0-9]*) continue;; esac
    case "$_aorig" in ''|*[!a-zA-Z0-9_-]*) continue;; esac
    [ -d "/proc/$_ap" ] || continue
    echo "$_ap" > "/dev/cpuset/$_aorig/tasks" 2>/dev/null
  done < "$MODDIR/run/affinity_constrained.lst"
fi


# 3. 删除运行时文件与历史遗留
rm -rf "$MODDIR/run"
rm -f "$RLST"
rm -f /data/local/tmp/memtonic.log /data/local/tmp/.memtonic.pid /data/local/tmp/.memtonic.trim
