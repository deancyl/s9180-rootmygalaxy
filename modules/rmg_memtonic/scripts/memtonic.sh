#!/system/bin/sh
# memtonic.sh —— RMG MemTonic v1.4.1（SM-S9180 临时 Root 会话内存维护守护）
#
# 设计保证：
#   * 不杀进程、不冻结、不打断任何后台服务（风暴护栏只调 nice，不动其他）；
#   * 无挂载、无 sepolicy、无 boot 阶段脚本——全部动作是运行时调度参数（重启即还原）；
#   * 不持久化任何系统属性，不触 zram 设备参数（RAM Plus 零接触）；
#   * 运行时文件位于模块私有目录 run/（700 root）；唯一例外是还原清单
#     /data/local/tmp/memtonic_storm_renice.lst（下次启动补还原，防御闭环）。
#
# v1.3.0 新增：
#   * storm guard 启动风暴护栏：检测 system_server 重启/新生 → 8 分钟窗口内
#     给桌面让路（全线程 renice -4）、对窗口内新启动的应用进程削峰（renice +5，
#     仅限 uid 应用、白名单与前台焦点豁免），窗口结束逐一还原；
#     窗口内禁止一切维护动作；CPU 压力回落提前退出。
#     结构说明：护栏为独立外部脚本 storm_guard.sh——Android 16 mksh 后台化
#     "shell 函数"会瞬时死亡（实测），外部脚本 fork+exec 才可靠。
#   * 结构化日志：L=E/A/W/X/S 五级、key=value 单行、超 256KB 字节基准截断、
#     E/A/W/X 同步镜像 logcat（tag MemTonic，无 root 时也可诊断）。
#   * 自我负担核算：快照记录自身累计 CPU 时间（self_cpu_ms）。
#
# v1.4.1 变更（2026-09-28 两次真实软重启 16 窗日志实证驱动）：
#   * 修复风暴窗口级联重触发：storm_restore_pending 的全局变量 cur 改名 r_cur，
#     且护栏主循环改为窗口前先固化 base（双重保险）——此前同一 sspid 会连续
#     重开 4-11 轮窗口；
#   * 白名单补充 com.catalinagroup.（HK 通话录音）/ com.nutomic.（syncthing）/
#     com.wangc.，并增加 whitelist_skip 留痕日志（S 级）；
#   * storm_end 增加 scan_ms/restore_ms 计时，归因窗口超限（实测 480s 上限
#     被突破至 619s）。
#
# 用法：
#   sh memtonic.sh            守护模式（由 service.sh 拉起，通常不需要手动执行）
#   sh memtonic.sh once       立即执行一次全套维护（风暴期自动拒绝）
#   sh memtonic.sh status     查看运行状态与最近日志
#   sh memtonic.sh stop       停止守护循环（护栏子进程 ≤5s 内跟随退出并还原）
#   sh memtonic.sh guarddry   干跑一轮风暴扫描：只打印将削峰的候选，不做修改

. /data/adb/modules/rmg_memtonic/scripts/mt_lib.sh

# maintenance <标签>：执行一轮全套维护（压实 + 条件性清缓存 + 可选重压缩）
# 使用 mkdir 原子锁防止 once 与夜间维护并发；持锁者意外死亡时用 rm -rf 回收
# 陈旧锁（注意：锁目录内含 pid 文件，rmdir 对非空目录会失败——这是 v1.2.0 的教训）
maintenance() {
  tag=$1
  if ! mkdir "$LOCK" 2>/dev/null; then
    lp=$(cat "$LOCK/pid" 2>/dev/null)
    if alive "$lp"; then
      log "[$tag] 忙碌：另一轮维护持锁中 (pid $lp)"
      return 1
    fi
    rm -rf "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || { log "[$tag] 无法获取锁"; return 1; }
  fi
  echo $$ > "$LOCK/pid"
  log "[$tag] 开始 avail=$(avail_kb)KB psi_mem=$(psi_val memory some)"
  if echo 1 > /proc/sys/vm/compact_memory 2>/dev/null; then
    log "[$tag] 内存压实完成"
  else
    log "[$tag] 内存压实失败"
  fi
  a=$(avail_kb)
  if [ "$a" -lt $NIGHT_DROP_BELOW ] && echo 1 > /proc/sys/vm/drop_caches 2>/dev/null; then
    log "[$tag] 已丢弃干净页缓存，可用内存 $a -> $(avail_kb)KB"
  fi
  if [ "$RECOMPRESS" = "1" ] && [ -e "$ZRAM/idle" ] && [ -e "$ZRAM/recompress" ]; then
    echo idle > "$ZRAM/idle" 2>/dev/null
    sleep 2
    b=$(avail_kb)
    if echo "type=idle" > "$ZRAM/recompress" 2>/dev/null; then
      log "[$tag] zram 空闲页重压缩完成，可用内存 $b -> $(avail_kb)KB"
    else
      log "[$tag] zram 重压缩写入失败"
    fi
  fi
  log "[$tag] 结束 avail=$(avail_kb)KB"
  rm -rf "$LOCK" 2>/dev/null
}

# guarddry：干跑一轮扫描——只报告候选，不修改任何进程（验收/演示用）
# 注意：无窗口上下文，会列出全部现存候选；真实窗口内仅对"新启动"进程动手
guarddry() {
  focus=$(focused_pkg)
  echo "前台焦点: ${focus:-无}"
  echo "CPU PSI some avg10: $(psi_val cpu some)%"
  echo "--- 将被削峰的候选（uid 应用 + nice=0 + 非白名单 + 非焦点）---"
  for d in /proc/[0-9]*; do
    pid=${d##*/}
    u=$(is_app_uid "$pid"); [ -n "$u" ] || continue
    pkg=$(pkg_of "$pid"); [ -n "$pkg" ] || continue
    in_whitelist "$pkg" && continue
    [ "$pkg" = "$focus" ] && continue
    [ "$pkg" = "$LAUNCHER_PKG" ] && { echo "  [让路] $pid $pkg → renice $LAUNCHER_NICE"; continue; }
    [ "$(nice_of "$pid")" = "0" ] || continue
    nt=$(ls /proc/$pid/task 2>/dev/null | wc -l)
    echo "  [削峰] $pid $pkg (${nt}线程 → renice $STORM_NICE_APP)"
  done
}

case "$1" in
once)
  if [ -d "$STORM_FLAG" ]; then
    logx W "event=maintenance_deferred reason=storm_active mode=once"
    echo "风暴护栏活动期，维护已拒绝（避免负优化）"; exit 1
  fi
  maintenance once
  exit 0
  ;;
guarddry)
  guarddry
  exit 0
  ;;
stop)
  p=$(cat "$PIDF" 2>/dev/null)
  p=${p%%:*}
  # 实测教训：TERM 对正在 sleep 的 mksh 循环可能被延迟处理，必须 KILL 兜底
  if [ -n "$p" ] && [ -d /proc/$p ]; then
    kill "$p" 2>/dev/null
    sleep 1
    [ -d /proc/$p ] && kill -9 "$p" 2>/dev/null
  fi
  g=$(cat "$GUARD_PIDF" 2>/dev/null)
  [ -n "$g" ] && [ -d /proc/$g ] && kill -9 "$g" 2>/dev/null
  rm -f "$PIDF" "$GUARD_PIDF"
  logx E "event=stop"
  echo "守护循环已停止（护栏随停，还原清单已由护栏兜底处理）"
  exit 0
  ;;
status)
  p=$(cat "$PIDF" 2>/dev/null)
  p=${p%%:*}
  if alive "$p"; then
    echo "循环：运行中 pid=$p"
  else
    echo "循环：未运行"
    rm -f "$PIDF" 2>/dev/null
  fi
  g=$(cat "$GUARD_PIDF" 2>/dev/null)
  if [ -n "$g" ] && [ -d /proc/$g ]; then
    echo "护栏：监视中 pid=$g"
  else
    echo "护栏：未运行"
  fi
  [ -d "$STORM_FLAG" ] && echo "风暴护栏：窗口活动中" || echo "风暴护栏：待命"
  echo "可用内存=$(avail_kb)KB  守护自身CPU=$(self_cpu_ms "$p")ms"
  echo "--- 最近日志 ---"
  tail -n 6 "$LOG" 2>/dev/null
  exit 0
  ;;
esac

# ---- 守护模式 ----
echo "$$:$(pid_starttime $$)" > "$PIDF"
logx E "event=start ver=1.4.1 pid=$$ poll=${CHECK_INTERVAL}s storm_win=${STORM_WINDOW}s"
# 防御闭环：上次会话若在窗口中途死亡，先补还原再开始
storm_restore_pending session_start

# 护栏子进程：独立外部脚本（mksh 后台化函数会瞬时死亡，实测教训）
nohup sh "$MODDIR/scripts/storm_guard.sh" >/dev/null 2>&1 &
echo "$!" > "$GUARD_PIDF"
logx E "event=guard_launched pid=$(cat "$GUARD_PIDF" 2>/dev/null)"

last_full=0
last_tick=""
while true; do
  sleep $CHECK_INTERVAL
  # 会话自检：临时 root 会话消失（如内核模块被卸载）则干净退出
  if ! grep -q '^kernelsu' /proc/modules 2>/dev/null; then
    logx E "event=exit reason=kernelsu_gone"
    rm -f "$PIDF"
    exit 0
  fi
  snapshot
  # 每日心跳：证明循环存活，避免"静默失效"无法察觉
  today=$(date '+%Y%m%d')
  if [ "$today" != "$last_tick" ]; then
    last_tick=$today
    log "[tick] 存活检查 avail=$(avail_kb)KB"
  fi
  # 风暴护栏活动期禁止维护（启动期做内存操作是负优化）
  if [ -d "$STORM_FLAG" ]; then
    logx W "event=maintenance_deferred reason=storm_active"
    continue
  fi
  if screen_off; then
    now=$(date +%s)
    if [ $((now - last_full)) -ge $FULL_INTERVAL ]; then
      last_full=$now
      maintenance night
    fi
  elif [ "$EMERG" = "1" ]; then
    a=$(avail_kb)
    if [ "$a" -lt $EMERG_AVAIL ]; then
      echo 1 > /proc/sys/vm/compact_memory 2>/dev/null
      log "[emerg] 可用内存=${a}KB -> 已压实（亮屏）"
    fi
  fi
done
