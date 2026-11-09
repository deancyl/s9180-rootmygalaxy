#!/system/bin/sh
# service.sh —— RMG MemTonic v1.13.19
# 由 ksud 在每次临时 root 会话建立时自动调用，负责拉起 memtonic 守护循环
# （护栏子进程 storm_guard.sh 由守护自身拉起，本脚本无需关心）。
# 幂等性：已存在存活实例时不重复启动。
# 陈旧 PID 防护：同时校验 pid 与 /proc/<pid>/stat 的进程启动时间，
#                重启后 PID 被复用也不会误判为"已在运行"。

# v1.13.19: 零 fork 写法（KernelSU 官方规范）——${0%/*} 由 shell 内建完成，不启动 dirname。
# ksud 始终以绝对路径调用本脚本，故 $0 必含 "/"；万一被相对路径调用则退回当前目录。
MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR=.
RUN=$MODDIR/run
PIDF=$RUN/memtonic.pid
mkdir -p "$RUN" 2>/dev/null
chmod 700 "$RUN" 2>/dev/null

entry=$(cat "$PIDF" 2>/dev/null)
p=${entry%%:*}
st=${entry##*:}
if [ -n "$p" ] && [ -d /proc/$p ] && grep -q memtonic /proc/$p/cmdline 2>/dev/null; then
  cst=$(awk '{print $22}' /proc/$p/stat 2>/dev/null)
  if [ "$cst" = "$st" ]; then
    exit 0
  fi
fi
# v1.13.19: 走到这里说明主进程已不在（或从未启动）。若 pid 文件此前存在，说明上一轮
# 属异常终止——子守护可能仍是孤儿（父进程被 kill -9 后，cgroup/renice 干预仍在继续，
# 且 `while kill -0 $PPID` 在 PPID→1 后恒真）。先清场再拉起，避免双实例并发调度。
# 全新启动（无 pid 文件）不清场，避免误杀同一次冷启动中已拉起的子进程。
if [ -n "$p" ]; then
  pkill -9 -f "scripts/cpu_guard.sh" 2>/dev/null
  pkill -9 -f "scripts/fluency_shield.sh" 2>/dev/null
  pkill -9 -f "scripts/storm_guard.sh" 2>/dev/null
  pkill -9 -f "scripts/vk_injector.sh" 2>/dev/null
fi
rm -f "$PIDF"
nohup sh "$MODDIR/scripts/memtonic.sh" >/dev/null 2>&1 &
