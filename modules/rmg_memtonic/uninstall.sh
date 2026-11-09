#!/system/bin/sh
# uninstall.sh —— RMG MemTonic v1.13.19 卸载清理
# 停止守护与全部子进程，统一还原所有优先级 / 亲和 / 提权改动，删除运行时文件，
# 并清理早期遗留在 /data/local/tmp 的文件。

# v1.13.19: 零 fork 写法（KernelSU 官方规范）——${0%/*} 由 shell 内建完成，不启动 dirname。
MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR=/data/adb/modules/rmg_memtonic

# 1. 终止守护与全部子进程
# v1.13.19: 原实现只遍历 memtonic.pid / guard.pid 两个 pid 文件，cpu_guard.sh、
# fluency_shield.sh、vk_injector.sh 三个子守护不会被终止；紧随其后的 rm -rf run 又会
# 删光所有 pid 文件与还原清单 → 孤儿无主、无法再 stop、清单丢失（11-08 审计 P0-1）。
# 现与 memtonic.sh stop 对齐：pid 文件 + pkill 双保险。
for pf in "$MODDIR/run/memtonic.pid" \
          "$MODDIR/run/guard.pid" \
          "$MODDIR/run/cpuguard.pid" \
          "$MODDIR/run/fluencyshield.pid"; do
  p=$(cat "$pf" 2>/dev/null); p=${p%%:*}
  if [ -n "$p" ] && [ -d /proc/$p ]; then
    kill "$p" 2>/dev/null
    sleep 1
    [ -d /proc/$p ] && kill -9 "$p" 2>/dev/null
  fi
done
pkill -9 -f "scripts/cpu_guard.sh" 2>/dev/null
pkill -9 -f "scripts/fluency_shield.sh" 2>/dev/null
pkill -9 -f "scripts/storm_guard.sh" 2>/dev/null
pkill -9 -f "scripts/vk_injector.sh" 2>/dev/null

# 2. 还原清单中尚未还原的 tid（若有）——卸载不能把别的应用留在降优先级状态
RLST=/data/local/tmp/memtonic_storm_renice.lst
if [ -s "$RLST" ]; then
  while read -r tid on ap pkg; do
    case "$ap" in ''|*[!0-9-]*) continue;; esac
    [ -d /proc/$tid ] || continue
    renice -n $((on - ap)) -p "$tid" >/dev/null 2>&1
  done < "$RLST"
fi

# Source the runtime constants/files early so the restore helpers can find their
# $RUN/*.bak before the run directory is removed.
. "$MODDIR/scripts/mt_lib.sh" 2>/dev/null
# v1.13.19: 与 memtonic.sh stop 共用同一份清场序列（storm / flush / bt / bt2 /
# camera_vip / camera_affinity / gc_boost / shield_fg / affinity(cgroup.procs) /
# rogue / rayneo）。必须在 rm -rf run 之前执行，否则清单随目录一起消失。
restore_all_on_exit

# 3. 删除运行时文件与历史遗留
rm -rf "$MODDIR/run"
rm -f "$RLST"
rm -f /data/local/tmp/memtonic.log /data/local/tmp/.memtonic.pid /data/local/tmp/.memtonic.trim
# v1.13.19: 清理调试残留（曾推送到模块目录的临时测试夹具）
rm -rf "$MODDIR/.t"
