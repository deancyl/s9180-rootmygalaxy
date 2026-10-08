#!/system/bin/sh
# storm_guard.sh —— RMG MemTonic 启动风暴护栏子进程（v1.9.5 - Sentinel Fusion）
# 由 memtonic.sh 守护以 nohup 外部脚本方式拉起。
# 生命周期：随守护进程生死（$PPID = 守护 pid，探活失败则还原并退出）。
# 职责：
#   1. 启动时若 system_server 年龄 < STORM_SSPID_FRESH（刚重 root / 刚框架重启），
#      立即进入护栏窗口并生成黑匣子快照；
#   2. 每 STORM_POLL 秒监视 system_server PID，变化（KSU 软重启）即异步生成
#      黑匣子全景快照（run/incident-<ts>.log）并进入护栏窗口；
#   3. 窗口：launcher 全线程 renice -4 让路、新启动应用 renice +5 削峰
#      （白名单/前台焦点豁免、oom_score_adj <= 200 前台服务动态豁免）；
#      8 分钟上限，CPU PSI 回落连续 3 次 + 20s 平滑冷却期后提前退出；
#   4. 窗口结束批量极速还原（批量聚合 renice -p，耗时 <2s），全程结构化日志可审计。

. "$(dirname "$0")/mt_lib.sh"

echo $$ > "$GUARD_PIDF" 2>/dev/null

base=$(pidof system_server)
# 启动即处于风暴：root 刚恢复 / 框架刚重启
if [ -n "$base" ]; then
  up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
  case "$up" in ''|*[!0-9.]*) up=0;; esac
  up=${up%%.*}
  st=$(pid_starttime "$base")
  case "$st" in ''|*[!0-9]*) st=0;; esac
  age=$(( up - st / CLK_TCK ))
  if [ "$age" -lt "$STORM_SSPID_FRESH" ]; then
    capture_incident fresh_boot
    storm_window fresh_boot
    base=$(pidof system_server)
  fi
fi

while kill -0 "$PPID" 2>/dev/null; do
  sleep $STORM_POLL
  check_root_liveness
  cur=$(pidof system_server)
  if [ -n "$cur" ] && [ "$cur" != "$base" ]; then
    # 固化 base 防级联，并立即触发 60s 黑匣子快照取证
    base=$cur
    capture_incident soft_reboot
    storm_window soft_reboot
  fi
done

# 守护进程已死：若窗口未结束，先还原再退出
storm_restore_pending parent_exit
rm -rf "$STORM_FLAG" 2>/dev/null
exit 0
