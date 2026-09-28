#!/system/bin/sh
# service.sh —— RMG MemTonic v1.4.2
# 由 ksud 在每次临时 root 会话建立时自动调用，负责拉起 memtonic 守护循环
# （护栏子进程 storm_guard.sh 由守护自身拉起，本脚本无需关心）。
# 幂等性：已存在存活实例时不重复启动。
# 陈旧 PID 防护：同时校验 pid 与 /proc/<pid>/stat 的进程启动时间，
#                重启后 PID 被复用也不会误判为"已在运行"。

RUN=/data/adb/modules/rmg_memtonic/run
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
rm -f "$PIDF"
nohup sh /data/adb/modules/rmg_memtonic/scripts/memtonic.sh >/dev/null 2>&1 &
