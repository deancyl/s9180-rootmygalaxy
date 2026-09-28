#!/system/bin/sh
# storm_guard.sh —— RMG MemTonic 启动风暴护栏子进程（v1.4.1）
# 由 memtonic.sh 守护以 nohup 外部脚本方式拉起（mksh 后台化函数会瞬时死亡，实测）。
# 生命周期：随守护进程生死（$PPID = 守护 pid，探活失败则还原并退出）。
# 职责：
#   1. 启动时若 system_server 年龄 < STORM_SSPID_FRESH（刚重 root / 刚框架重启），
#      立即进入护栏窗口；
#   2. 每 STORM_POLL 秒监视 system_server PID，变化（KSU 软重启）即进入护栏窗口；
#   3. 窗口：launcher 全线程 renice -4 让路、窗口内新启动应用进程 renice +5 削峰
#      （白名单/前台焦点豁免、仅限 uid 应用、nice=0 才动）、窗口内禁维护；
#      8 分钟上限，CPU PSI 回落（连续 3 次 avg10 < 10%）提前退出；
#   4. 窗口结束逐一还原，全程结构化日志可审计。
# v1.4.1 修复：soft_reboot 触发时先固化 base 再进窗口（详见主循环内注释）。

. /data/adb/modules/rmg_memtonic/scripts/mt_lib.sh

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
    storm_window fresh_boot
    base=$(pidof system_server)
  fi
fi

while kill -0 "$PPID" 2>/dev/null; do
  sleep $STORM_POLL
  cur=$(pidof system_server)
  if [ -n "$cur" ] && [ "$cur" != "$base" ]; then
    # v1.4.1：必须在进入窗口【之前】先固化 base——窗口内还原函数会使用
    # 全局变量（v1.3.0 的 cur 污染事故），窗口后赋值 base=$cur 会把
    # 污染值存进 base，导致同一 sspid 级联重开风暴窗口（实证 16 窗）
    base=$cur
    storm_window soft_reboot
  fi
done

# 守护进程已死：若窗口未结束，先还原再退出
storm_restore_pending parent_exit
rm -rf "$STORM_FLAG" 2>/dev/null
exit 0
