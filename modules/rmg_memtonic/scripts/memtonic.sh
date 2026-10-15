#!/system/bin/sh
# memtonic.sh —— RMG MemTonic v1.10.0（SM-S9180 内存与异常守护）
#
# v1.10.0 内存风暴监测/快照/亮屏风暴级压实（源自 2026-10-09~10 Synology 转码事故取证）：
#   * P1-1 mem PSI 连续监测：cpu_guard 60s 轮挂载 psi_mem_read（mksh 内建 read 零 fork，
#     实测 fork 版 9.35ms/次 → 内建 <0.5ms，零新增唤醒）；
#   * P0-2 灾难黑匣子：连续 2 轮 psi_mem some≥25 落盘 PSI/meminfo/RSS+majflt Top10
#     （2026-10-09 事故关键证据靠 daagent ANR 碰巧带出，黑匣子让取证不再靠运气）；
#     冷却 900s + 日限 10 份 + 轮转 5 份，最坏 0.04% 占空比；
#   * P0-1 亮屏风暴级压实例外：GEMINI 铁律"亮屏禁压"保留，唯一例外通道 =
#     psi_mem some≥30（调用方硬阈值保证）+ 相机/截屏/风暴守卫无条件生效；
#   * P1-2 kswapd_growth（>90s CPU/h）顺手触发压实（风暴级例外通道，1h 天然限频）；
#   * P2 前台 majflt 差分指纹（≥500/60s 记预警，10min 限频）——转码类负载信号，
#     为 rmg_sentinel 试点铺路；
#   * maintenance 新增 storm=1 第 2 参数（铁律例外通道），R3 息屏压实冷却 3600s→900s
#     与亮屏路径共用 last_compact.ts 统一限频。
#
# v1.9.12 全模块 ARG_MAX 审计修复（2026-10-08 部署实测后深审，7 脚本全覆盖）：
#   * 封堵 gfxinfo 捕获点（in_app_stress_test.sh）：dumpsys 输出改落临时文件快照，
#     不经 shell 变量中转（同型于 v1.9.11 哨兵缺陷）；
#   * 归因修正：v1.9.11 部署期 stderr 的 "printf: Argument list too long" 实为
#     check_rollback_disarm 初版缺陷在启动路径暴露（memtonic.sh[223] 报错前缀铁证），
#     storm_restore_pending 的批量 renice（≤50 tid/批 ~600B）设计安全、无独立缺陷；
#   * fluency_shield 日志版本串同步（曾滞留 1.9.10，与 module.prop 不一致）。
#
# v1.9.11 Rollback 地雷排除（源自 2026-10-08 三合一排查取证）：
#   * check_rollback_disarm 哨兵：主循环检测 enabling 态回滚，孤儿 session 自动
#     pm install-abandon（One UI 16 移除全部 rollback 命令后的唯一有效路径）；
#     dry-run 默认开（touch run/rollback_disarm.enable 启用）；
#   * system_server PID 变化时重置 vk 门闩并重拉只读监视器（主守护跨软重启存活，
#     vk_injector 一次性退出后无人再消费门闩的缺口）；
#   * env_baseline 启动环境基线（max_cached=1030 已定性三星原生，只记不改）。
#
# 设计保证：
#   * 不杀进程、不冻结、不打断任何后台服务（风暴护栏只调 nice，不动其他）；
#   * 无挂载、无 sepolicy、无 boot 阶段脚本——全部动作是运行时调度参数（重启即还原）；
#   * 不持久化任何系统属性，不触 zram 设备参数（RAM Plus 零接触）；
#   * 运行时文件位于模块私有目录 run/（700 root）；唯一例外是还原清单
#     /data/local/tmp/memtonic_storm_renice.lst（下次启动补还原，防御闭环）。
#
# v1.6.0 Sentinel P1 深度融合：
#   * FR-4 CPU 失常护栏（cpu_guard.sh）：
#     连续 3 个 60s 窗口 CPU > 50% 的用户应用 -> renice +10 温和降权；
#     CPU 回落后自动还原；高优线程/前台/前台服务全程豁免；风暴期暂停。
#   * FR-5 崩溃雷达（cpu_guard.sh）：
#     旁路监听 /data/system/dropbox 文件计数变化，检测 App 崩溃与 ANR 事件。
#   * FR-7 结构性健康追踪（memtonic.sh）：
#     每小时打点内存健康指标与 kswapd CPU 增量；kswapd > 90s/h 触发软重启建议。
#   * Fix：RLST 还原清单同 tid 去重（消除重复 restore_skipped_changed 噪音日志）；
#   * Fix：incident 黑匣子快照自动老化清理（保留最新 10 个，防磁盘无限堆积）。
#
# v1.5.1 热修复（v1.5.0 严重漏洞修复）：
#   * 修复 Launcher 普通线程批量恢复时遭遇异常提权（-4 变 -9）的致命 Bug；
#   * 修复 memtonic.sh stop 强杀护栏时导致优先级无法还原的 Bug；
#   * 修复护栏为 Launcher 让路时错误降级核心高优先级线程导致掉帧的缺陷；
#   * 修复 capture_incident 快照同秒并发写入时的竞争覆盖风险。
#
# 用法：
#   sh memtonic.sh            守护模式（由 service.sh 拉起，通常不需要手动执行）
#   sh memtonic.sh once       立即执行一次全套维护（风暴期自动拒绝）
#   sh memtonic.sh optimize   WebUI 一键系统优化（v1.12.1：Launcher 提权 + 息屏时压实）
#   sh memtonic.sh status     查看运行状态与最近日志
#   sh memtonic.sh stop       停止守护循环（所有子进程跟随退出并还原）
#   sh memtonic.sh guarddry   干跑一轮风暴扫描：只打印将削峰的候选，不做修改


. "$(dirname "$0")/mt_lib.sh"

# maintenance <标签> [storm]：执行一轮内存维护（按需压实）
# 彻底剔除 drop_caches，绝不人为丢弃页缓存，杜绝应用冷读盘性能劣化。
# v1.10.0: 新增第 2 参数 storm=1 —— GEMINI.md 亮屏铁律的"风暴级例外"唯一通道：
#   仅当调用方已用硬阈值（psi_mem some≥30 或 kswapd≥90s/h）证明设备深陷内存风暴时
#   才允许亮屏压实（2026-10-09 Synology 转码事故：PSI mem full 10.6% 设备整体停顿，
#   压实 1s CPU 相对风暴是九牛一毛，两害相权取其轻）；常规亮屏禁压铁律不变；
#   相机/截屏守卫无条件生效（即使风暴级例外，录像中压实掉帧同样不可接受）。
maintenance() {
  tag=$1
  _storm=${2:-0}
  # P0 Camera Sentinel 协同：相机活跃期间（录像/连拍/扫码）严禁触发内存压实！
  if [ -f "$RUN/camera_active.flag" ]; then
    logx W "[$tag] 拒绝执行：相机活跃中，严禁内存压实防录像掉帧"
    return 1
  fi
  # Screenshot Sentinel 协同：截屏处理期间禁止内存压实（防截屏后 AI 处理掉帧）
  if [ -f "$SCREENSHOT_ACTIVE_FLAG" ]; then
    logx W "[$tag] 拒绝执行：截屏处理中，严禁内存压实防掉帧"
    return 1
  fi
  # GEMINI.md 铁律防护：内存压实耗时数百毫秒，绝不允许在亮屏期间触发
  # v1.10.0: 风暴级例外（storm=1）是唯一放行通道，门槛由调用方硬阈值保证
  if ! screen_off; then
    if [ "$_storm" != "1" ]; then
      logx W "[$tag] 拒绝执行：检测到屏幕处于亮屏/交互状态，严禁内存压实防掉帧"
      return 1
    fi
    logx W "[$tag] 亮屏风暴级例外放行：psi/kswapd 硬阈值已满足_两害相权取其轻"
  fi
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
  log "[$tag] 结束 avail=$(avail_kb)KB"
  rm -rf "$LOCK" 2>/dev/null
}

# guarddry：干跑一轮扫描——只报告候选，不修改任何进程（验收/演示用）
guarddry() {
  focus=$(focused_pkg)
  echo "前台焦点: ${focus:-无}"
  echo "CPU PSI some avg10: $(psi_val cpu some)%"
  echo "--- 将被削峰的候选（uid 应用 + nice=0 + 非白名单 + 非焦点 + 非前台服务）---"
  for d in /proc/[0-9]*; do
    pid=${d##*/}
    u=$(is_app_uid "$pid"); [ -n "$u" ] || continue
    pkg=$(pkg_of "$pid"); [ -n "$pkg" ] || continue
    in_whitelist "$pkg" && continue
    is_foreground_service "$pid" && { echo "  [前台服务豁免] $pid $pkg (adj=$(cat /proc/$pid/oom_score_adj 2>/dev/null))"; continue; }
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
  if ! maintenance once; then
    exit 1
  fi
  exit 0
  ;;
guarddry)
  guarddry
  exit 0
  ;;
optimize)
  # v1.12.1: WebUI 一键系统优化（sh memtonic.sh optimize，由 WebUI 启动守护按钮调用）
  # 遵守 GEMINI 铁律与三条底线：不杀进程/不冻结/不动 zram/不持久内核参数；
  # 亮屏期间严禁内存压实（防掉帧）——亮屏时仅做 Launcher 提权，息屏时执行全套维护（压实）。
  if [ -d "$STORM_FLAG" ]; then
    logx W "event=webui_optimize_rejected reason=storm_active"
    echo "风暴护栏活动期，优化已拒绝（避免负优化）。"
    exit 1
  fi
  _op_l=0
  for d in /proc/[0-9]*; do
    _op_p=${d##*/}
    _op_u=$(is_app_uid "$_op_p"); [ -n "$_op_u" ] || continue
    _op_k=$(pkg_of "$_op_p"); [ "$_op_k" = "$LAUNCHER_PKG" ] || continue
    renice_tree "$_op_p" "$LAUNCHER_NICE" "$_op_k" 0
    _op_l=$((_op_l+1))
  done
  if screen_off; then
    if maintenance webui_optimize; then _op_c=完成; else _op_c=失败; fi
  else
    _op_c=跳过
    logx W "event=webui_optimize reason=screen_on msg=亮屏严禁压实防掉帧_GEMINI铁律"
  fi
  update_module_desc
  logx A "event=webui_optimize_end avail=$(avail_kb)KB launcher=$_op_l compact=$_op_c"
  if [ "$_op_c" = "跳过" ]; then
    echo "系统优化完成：Launcher 提权 ${_op_l} 个进程；内存压实跳过（亮屏防掉帧铁律，息屏后自动按需执行）；当前可用 $(avail_kb)KB。"
  else
    echo "系统优化完成：Launcher 提权 ${_op_l} 个进程；内存压实${_op_c}；当前可用 $(avail_kb)KB。"
  fi
  exit 0
  ;;
restart)
  # Fix-A: restart = 全量清场后重启（解决重复实例问题）
  sh "$0" stop
  sleep 2
  exec sh "$0"
  ;;
stop)
  p=$(cat "$PIDF" 2>/dev/null)
  p=${p%%:*}
  if alive "$p"; then
    kill "$p" 2>/dev/null
    sleep 1
    alive "$p" && kill -9 "$p" 2>/dev/null
  fi
  g=$(cat "$GUARD_PIDF" 2>/dev/null)
  if alive "$g"; then kill -9 "$g" 2>/dev/null; fi
  # v1.6.0: 同时终止 CPU 护栏子进程
  cg=$(cat "$RUN/cpuguard.pid" 2>/dev/null)
  if [ -n "$cg" ] && [ -d /proc/$cg ] && grep -q cpu_guard /proc/$cg/cmdline 2>/dev/null; then
    kill -9 "$cg" 2>/dev/null
  fi
  # v1.6.0: 如果 vk_injector.sh 还在 30秒延时中，一并终止
  pkill -f vk_injector 2>/dev/null
  # 终止 FR-9 护盾
  fs=$(cat "$RUN/fluencyshield.pid" 2>/dev/null)
  if alive "$fs"; then kill -9 "$fs" 2>/dev/null; fi
  # Fix-A: 全量清场孤儿进程（不依赖 pid 文件，防止孤儿进程残留）
  pkill -9 -f storm_guard.sh 2>/dev/null
  pkill -9 -f cpu_guard.sh 2>/dev/null
  pkill -9 -f fluency_shield.sh 2>/dev/null
  rm -f "$PIDF" "$GUARD_PIDF" "$RUN/cpuguard.pid" "$RUN/fluencyshield.pid" "$RUN/vk_injected.flag"
  # P2 Camera Sentinel 清场
  rm -f "$RUN/camera_active.flag" "$RUN/camera_vip.bak" 2>/dev/null
  # Screenshot Sentinel 清场
  rm -f "$SCREENSHOT_ACTIVE_FLAG" "$SCREENSHOT_END_TS" "$RUN/screenshot_fg.bak" 2>/dev/null

  # v1.5.1: 护栏被 kill -9 强杀，主动兜底还原风暴降权
  storm_restore_pending manual_stop
  # v1.6.0: 还原 CPU 失常护栏降权（cpu_guard 被强杀前来不及自清场）
  if [ -s "$RUN/cpu_rogue_renice.lst" ]; then
    while read -r tid on pkg; do
      case "$tid" in ''|*[!0-9]*) continue;; esac
      [ -d /proc/$tid ] || continue
      cur=$(nice_of "$tid"); [ -n "$cur" ] || continue
      renice -n $((on - cur)) -p "$tid" >/dev/null 2>&1
    done < "$RUN/cpu_rogue_renice.lst"
    rm -f "$RUN/cpu_rogue_renice.lst" 2>/dev/null
  fi

  logx E "event=stop"
  update_module_desc   # v1.11.0: 停止时刷新卡片描述（守护:stopped）
  echo "守护循环已停止，所有子进程已终止，所有降权已还原。"
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
  if alive "$g"; then
    echo "护栏：监视中 pid=$g"
  else
    echo "护栏：未运行"
  fi
  cg=$(cat "$RUN/cpuguard.pid" 2>/dev/null)
  if [ -n "$cg" ] && [ -d /proc/$cg ] && grep -q cpu_guard /proc/$cg/cmdline 2>/dev/null; then
    echo "CPU护栏：监视中 pid=$cg"
  else
    echo "CPU护栏：未运行"
  fi
  [ -d "$STORM_FLAG" ] && echo "风暴护栏：窗口活动中" || echo "风暴护栏：待命"
  echo "可用内存=$(avail_kb)KB  守护自身CPU=$(self_cpu_ms "$p")ms"
  echo "--- 最近日志 ---"
  tail -n 8 "$LOG" 2>/dev/null
  exit 0
  ;;
""|start)
  ;;
*)
  exit 1
  ;;
esac

# ---- 守护模式 ----
# Fix-A: 单例保护——若已有实例在跑，拒绝重复启动，防双实例污染
_existing=$(cat "$PIDF" 2>/dev/null); _existing=${_existing%%:*}
if [ -n "$_existing" ] && [ -d "/proc/$_existing" ] && grep -q memtonic /proc/$_existing/cmdline 2>/dev/null; then
  logx W "event=start_rejected reason=already_running pid=$_existing msg=请先stop再start"
  echo "已有实例运行中 (pid=$_existing)，请先执行 stop。"
  exit 1
fi
check_root_liveness
echo "$$:$(pid_starttime $$)" > "$PIDF"
logx E "event=start ver=1.12.1 pid=$$ poll=${CHECK_INTERVAL}s storm_win=${STORM_WINDOW}s"

# 即刻触发一次 Staged Rollback 检测（事前告警，防误重启丢 Root）
check_staged_rollback
# v1.9.11: 启动环境基线 + Rollback 地雷排除哨兵（dry-run 默认开）
env_baseline
check_rollback_disarm
update_module_desc   # v1.11.0: 启动即刷卡片描述（此后事件驱动 + 每小时兜底）

# 防御闭环：上次会话若在窗口中途死亡，先补还原再开始
storm_restore_pending session_start
rm -rf "$STORM_FLAG" "$RUN/vk_injected.flag" 2>/dev/null


# 风暴护栏子进程：独立外部脚本
nohup sh "$MODDIR/scripts/storm_guard.sh" >/dev/null 2>&1 &
echo "$!" > "$GUARD_PIDF"
logx E "event=guard_launched pid=$(cat "$GUARD_PIDF" 2>/dev/null)"

# v1.6.0 FR-4/FR-5：CPU 失常护栏 + 崩溃雷达子进程
nohup sh "$MODDIR/scripts/cpu_guard.sh" >/dev/null 2>&1 &
echo "$!" > "$RUN/cpuguard.pid"
logx E "event=cpuguard_launched pid=$(cat "$RUN/cpuguard.pid" 2>/dev/null)"

# v1.6.0 FR-8：Vulkan 强启与无障碍自愈护盾
nohup sh "$MODDIR/scripts/vk_injector.sh" >/dev/null 2>&1 &
logx E "event=vk_injector_launched msg=后台等待开机平息后执行"

# v1.6.0 FR-9：前台绝对护盾
nohup sh "$MODDIR/scripts/fluency_shield.sh" >/dev/null 2>&1 &
logx E "event=fluencyshield_launched msg=前台流畅度最后一道防线已启动"

# v1.6.0 FR-7：结构性健康追踪变量
last_health=0
last_kswapd_cpu=0
# v1.9.11: system_server PID 基线（首轮不触发 sspid_changed 误报）
last_sspid=$(pidof system_server 2>/dev/null)

last_full=0
last_tick=""
while true; do
  sleep $CHECK_INTERVAL
  
  # v1.6.0 FR-8：顺手备份健康的无障碍列表，供软重启时自愈使用
  a11y=$(settings get secure enabled_accessibility_services 2>/dev/null)
  if [ -n "$a11y" ] && [ "$a11y" != "null" ]; then
    echo "$a11y" > "$RUN/a11y.bak"
  fi

  check_root_liveness
  snapshot

  # 每轮周期巡检 Rollback 挂起状态
  check_staged_rollback
  # v1.9.11: Rollback 地雷排除哨兵（6h 去重，仅孤儿回滚，dry-run 默认开）
  check_rollback_disarm

  # v1.9.11: system_server PID 变化检测（主循环粒度 1h，vk 门闩重置属审计用途无时效要求；
  # 即时风暴响应与黑匣子快照由 storm_guard 5s 粒度负责，职责不重叠）
  _sspid=$(pidof system_server 2>/dev/null)
  if [ -n "$_sspid" ] && [ -n "$last_sspid" ] && [ "$_sspid" != "$last_sspid" ]; then
    rm -f "$RUN/vk_injected.flag" 2>/dev/null
    nohup sh "$MODDIR/scripts/vk_injector.sh" >/dev/null 2>&1 &
    logx W "event=sspid_changed old=$last_sspid new=$_sspid msg=vk门闩已重置_只读监视器已重拉"
  fi
  [ -n "$_sspid" ] && last_sspid=$_sspid

  # v1.6.0 FR-7：结构性健康追踪（每小时打点一次）
  now_s=$(date +%s)
  if [ $((now_s - last_health)) -ge 3600 ]; then
    last_health=$now_s
    sw=$(awk '/^SwapTotal/{t=$2}/^SwapFree/{f=$2}END{print t-f}' /proc/meminfo)
    # 定位 kswapd 并计算本小时 CPU 增量（v1.9.0: 不再操作 kswapd 亲和性）
    ks_pid=$(pgrep -x kswapd0 2>/dev/null | head -n 1)
    if [ -n "$ks_pid" ]; then
      new_kswapd_cpu=$(self_cpu_ms "$ks_pid")
      if [ -n "$new_kswapd_cpu" ] && [ "$last_kswapd_cpu" -gt 0 ]; then
        ks_delta=$((new_kswapd_cpu - last_kswapd_cpu))
        logx S "health_snap avail_kb=$(avail_kb) swap_used=${sw}KB psi_cpu=$(psi_val cpu some) psi_mem=$(psi_val memory some) psi_io=$(psi_val io some) kswapd_pid=$ks_pid kswapd_delta_ms=$ks_delta"
        # kswapd 在 1 小时内消耗超过 90s CPU：内存颠簸提示
        # v1.9.0 修复：当 staged_rollback 处于活跃状态时，抑制 soft_reboot 建议
        # （防止与 do_not_reboot 告警产生1秒内矛盾，实测曾诱发 APEX 回滚丢 Root）
        if [ "$ks_delta" -ge 90000 ]; then
          rb_cnt=$(dumpsys rollback 2>/dev/null | grep -c 'state: enabling')
          case "$rb_cnt" in ''|*[!0-9]*) rb_cnt=0;; esac
          if [ "$rb_cnt" -gt 0 ]; then
            logx W "warn=kswapd_growth delta_ms=$ks_delta note=soft_reboot_suppressed reason=staged_rollback_active count=$rb_cnt"
          else
            logx W "warn=kswapd_growth delta_ms=$ks_delta suggest=soft_reboot reason=memory_thrashing"
          fi
          # v1.10.0 P1-2: kswapd 每小时烧 >90s CPU = 换页风暴实锤，顺手触发一次压实
          # （风暴级例外通道，亮屏也放行；kswapd 判定 1h 一次天然限频，无叠加风险）
          # 相机/截屏守卫在 maintenance 内部无条件生效
          maintenance ks_growth_compact 1
        fi
      else
        logx S "health_snap avail_kb=$(avail_kb) swap_used=${sw}KB psi_cpu=$(psi_val cpu some) psi_mem=$(psi_val memory some) psi_io=$(psi_val io some) kswapd_pid=$ks_pid kswapd_delta_ms=NA"
      fi
      last_kswapd_cpu=${new_kswapd_cpu:-0}
    else
      logx S "health_snap avail_kb=$(avail_kb) swap_used=${sw}KB psi_cpu=$(psi_val cpu some) psi_mem=$(psi_val memory some) psi_io=$(psi_val io some) kswapd_pid=NA"
    fi
    update_module_desc   # v1.11.0: 每小时随 health_snap 刷新卡片描述（事件点另有即时刷新）
  fi


  # 每日心跳
  today=$(date '+%Y%m%d')
  if [ "$today" != "$last_tick" ]; then
    last_tick=$today
    update_module_desc   # v1.11.0: 每日心跳兜底刷新卡片描述（事件驱动点在 cpu_guard/mem_blackbox）
    log "[tick] 存活检查 avail=$(avail_kb)KB"
    incident_cleanup   # v1.6.0: 保留最新 10 个黑匣子快照，老化清理更早的
  fi

  # 风暴护栏活动期禁止维护
  if [ -d "$STORM_FLAG" ]; then
    logx W "event=maintenance_deferred reason=storm_active"
    continue
  fi

  # R3: 纯按需压实（息屏 + 高 PSI 压力 + 900s 冷却控制）
  # v1.10.0: 冷却 3600s→900s，与 cpu_guard 亮屏风暴级压实共用 last_compact.ts 统一限频
  if screen_off; then
    if psi_mem_pressure_high; then
      now=$(date +%s)
      last_compact=$(cat "$RUN/last_compact.ts" 2>/dev/null)
      case "$last_compact" in ''|*[!0-9]*) last_compact=0;; esac
      if [ $((now - last_compact)) -ge 900 ]; then
        echo "$now" > "$RUN/last_compact.ts"
        maintenance on_demand_pressure
      fi
    fi
  fi
done
