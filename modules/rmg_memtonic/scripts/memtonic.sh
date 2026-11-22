#!/system/bin/sh
# memtonic.sh —— RMG MemTonic v2.0.1（SM-S9180 内存与异常主守护）
#
# v2.0.1 闭环与省电重构：
# 1. 主循环改为亮屏 60s / 息屏 300s 零 fork 轻节拍调度；
# 2. 补齐软重启检测、黑匣子快照、无障碍自愈备份与风暴窗口；
# 3. 补齐 Dropbox 崩溃感知 (目录时间戳 0-fork 比对)；
# 4. 补齐极端 CPU+IO 熔断器 (每 3 分钟扫描，非白名单/非前台 >=150% CPU 且无缺页让步)；
# 5. 补齐 system_server 纯 Java 堆只读预警 (每 30 分钟采集，连续 2 次 >=440MB 预警)；
# 6. 彻底移除 once/optimize 中残余的 drop_caches，保持全周期零 drop_caches。

_mt_self_dir=${0%/*}
[ "$_mt_self_dir" = "$0" ] && _mt_self_dir="/data/adb/modules/rmg_memtonic/scripts"
if [ -f "$_mt_self_dir/mt_lib.sh" ]; then
  . "$_mt_self_dir/mt_lib.sh"
else
  . "/data/adb/modules/rmg_memtonic/scripts/mt_lib.sh"
fi

# maintenance <标签>：执行一轮内存按需压实（仅息屏且有高压力时）
maintenance() {
  tag=$1
  if [ -f "$CAMERA_ACTIVE_FLAG" ]; then
    logx W "[$tag] 拒绝执行：相机活跃中，严禁内存压实防录像掉帧"
    return 1
  fi
  if [ -f "$SCREENSHOT_ACTIVE_FLAG" ]; then
    logx W "[$tag] 拒绝执行：截屏处理中，严禁内存压实防掉帧"
    return 1
  fi
  if ! screen_off; then
    logx W "[$tag] 拒绝执行：屏幕处于亮屏/交互状态，严禁内存压实防掉帧"
    return 1
  fi
  _mf_free=$(awk '/MemFree/{print $2+0; exit}' /proc/meminfo 2>/dev/null)
  case "$_mf_free" in ''|*[!0-9]*) _mf_free=0;; esac
  if [ "$_mf_free" -lt 819200 ]; then
    logx S "[$tag] 跳过息屏压实 free_kb=$_mf_free < 800MB msg=物理空闲不足_防高失败率规整停顿"
    return 0
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

# scan_extreme_rogue: 高门槛极端 CPU+IO 熔断器
scan_extreme_rogue() {
  _cur_rogue_ts=$1
  _time_span=$((_cur_rogue_ts - ${last_rogue_scan_ts:-$((_cur_rogue_ts - 180))}))
  [ "$_time_span" -le 0 ] && _time_span=180
  last_rogue_scan_ts=$_cur_rogue_ts

  _tinfo=$(get_top_app_info 2>/dev/null)
  _focus_pkg=""
  [ -n "$_tinfo" ] && _focus_pkg=${_tinfo#* }

  _cur_stats=$(awk '
    FNR==1 {
      pid=FILENAME; sub(/.*\/proc\//,"",pid); sub(/\/stat/,"",pid)
    }
    {
      sub(/^[0-9]+ \([^)]*\) /,"")
      print pid, $10, $12+$13
    }
  ' /proc/[0-9]*/stat 2>/dev/null)

  while read -r _p _flt _ticks; do
    case "$_p" in ''|*[!0-9]*) continue;; esac
    [ -d "/proc/$_p" ] || continue

    eval "_pt=\${_ticks_${_p}:-}"
    eval "_pf=\${_flt_${_p}:-}"
    eval "_ticks_${_p}=\$_ticks"
    eval "_flt_${_p}=\$_flt"
    [ -z "$_pt" ] && continue

    _d_ticks=$((_ticks - _pt))
    _d_flt=$((_flt - _pf))
    [ "$_d_ticks" -lt 0 ] && continue

    eval "_is_r=\${_rogue_${_p}:-0}"
    _cpu_pct=$(( _d_ticks / _time_span ))

    if [ "$_is_r" = "1" ]; then
      _p_pkg=$(pkg_of "$_p")
      if [ "$_p_pkg" = "$_focus_pkg" ] || is_in_top_app_cgroup "$_p"; then
        restore_one_rogue "$_p" "$_p_pkg"
      elif [ "$_cpu_pct" -lt 30 ]; then
        eval "_lcnt=\${_lcnt_${_p}:-0}"
        _lcnt=$((_lcnt + 1))
        eval "_lcnt_${_p}=\$_lcnt"
        if [ "$_lcnt" -ge 2 ]; then
          restore_one_rogue "$_p" "$_p_pkg"
        fi
      else
        eval "_lcnt_${_p}=0"
      fi
      continue
    fi

    if [ "$_cpu_pct" -lt 150 ]; then
      eval "_hcnt_${_p}=0"
      continue
    fi

    is_app_uid "$_p" >/dev/null || continue
    _p_pkg=$(pkg_of "$_p")
    case "$_p_pkg" in ''|*" "*) continue;; esac
    in_whitelist "$_p_pkg" && continue
    [ "$_p_pkg" = "$_focus_pkg" ] && continue
    is_in_top_app_cgroup "$_p" && continue
    is_foreground_service "$_p" && continue
    [ "$_d_flt" -gt 200 ] && continue

    eval "_hcnt=\${_hcnt_${_p}:-0}"
    _hcnt=$((_hcnt + 1))
    eval "_hcnt_${_p}=\$_hcnt"

    if [ "$_cpu_pct" -ge 350 ] || [ "$_hcnt" -ge 3 ]; then
      _orig_nice=$(nice_of "$_p")
      case "$_orig_nice" in ''|*[!0-9-]*) _orig_nice=0;; esac
      apply_rogue_mitigation "$_p" "$_p_pkg"
      echo "$_p $_orig_nice $_p_pkg" >> "$ROGUE_LST" 2>/dev/null
      eval "_rogue_${_p}=1 _hcnt_${_p}=0 _lcnt_${_p}=0"
      logx W "event=cpu_rogue_intervene pid=$_p pkg=$_p_pkg cpu=${_cpu_pct}% majflt_delta=$_d_flt"
      update_module_desc
    fi
  done <<EOF
$_cur_stats
EOF

  if [ -s "$ROGUE_LST" ]; then
    _tmp_rl="$RUN/rogue_tmp_$$"
    while read -r _rpid _ron _rpkg; do
      if [ -d "/proc/$_rpid" ]; then
        echo "$_rpid $_ron $_rpkg" >> "$_tmp_rl" 2>/dev/null
      else
        eval "unset _ticks_${_rpid} _flt_${_rpid} _hcnt_${_rpid} _lcnt_${_rpid} _rogue_${_rpid}"
      fi
    done < "$ROGUE_LST"
    if [ -f "$_tmp_rl" ]; then mv "$_tmp_rl" "$ROGUE_LST" 2>/dev/null; else rm -f "$ROGUE_LST" 2>/dev/null; fi
  fi
}

restore_one_rogue() {
  _rp=$1; _rpkg=$2
  [ -d "/proc/$_rp" ] || return 0
  _on=$(awk -v p="$_rp" '$1==p{print $2; exit}' "$ROGUE_LST" 2>/dev/null)
  case "$_on" in ''|*[!0-9-]*) _on=0;; esac
  _cn=$(nice_of "$_rp")
  case "$_cn" in ''|*[!0-9-]*) ;;
    *) renice -n $((_on - _cn)) -p "$_rp" >/dev/null 2>&1;;
  esac
  ionice -c 2 -n 4 -p "$_rp" 2>/dev/null
  if [ -f "$ROGUE_LST" ]; then
    grep -v "^$_rp " "$ROGUE_LST" > "$ROGUE_LST.t" 2>/dev/null && mv "$ROGUE_LST.t" "$ROGUE_LST" 2>/dev/null
  fi
  eval "_rogue_${_rp}=0 _hcnt_${_rp}=0 _lcnt_${_rp}=0"
  logx I "act=rogue_restore pid=$_rp pkg=$_rpkg msg=高负载回落或切回前台_无损还原"
  update_module_desc
}

case "$1" in
once)
  if [ -d "$STORM_FLAG" ]; then
    logx W "event=maintenance_deferred reason=storm_active mode=once"
    echo "风暴护栏活动期，维护已拒绝（避免负优化）"; exit 1
  fi
  sync 2>/dev/null
  if ! maintenance once; then
    exit 1
  fi
  exit 0
  ;;
optimize)
  if [ -d "$STORM_FLAG" ]; then
    logx W "event=webui_optimize_rejected reason=storm_active"
    echo "风暴护栏活动期，优化已拒绝（避免负优化）。"
    exit 1
  fi
  sync 2>/dev/null
  _op_l=0
  for d in /proc/[0-9]*; do
    _op_p=${d##*/}
    is_app_uid "$_op_p" >/dev/null || continue
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
  sh "$0" stop
  sleep 2
  if [ -f "$MODDIR/service.sh" ]; then
    sh "$MODDIR/service.sh"
  else
    nohup sh "$0" >/dev/null 2>&1 &
  fi
  exit 0
  ;;
stop)
  p=$(cat "$PIDF" 2>/dev/null); p=${p%%:*}
  if alive "$p"; then
    kill "$p" 2>/dev/null
    sleep 1
    alive "$p" && kill -9 "$p" 2>/dev/null
  fi
  fs=$(cat "$RUN/fluencyshield.pid" 2>/dev/null); fs=${fs%%:*}
  if [ -n "$fs" ] && [ -d "/proc/$fs" ] && grep -q fluency_shield "/proc/$fs/cmdline" 2>/dev/null; then kill -9 "$fs" 2>/dev/null; fi
  for _mp in $(pgrep -f "scripts/memtonic.sh" 2>/dev/null); do
    [ "$_mp" != "$$" ] && kill -9 "$_mp" 2>/dev/null
  done
  pkill -9 -f fluency_shield.sh 2>/dev/null
  rm -f "$PIDF" "$GUARD_PIDF" "$RUN/fluencyshield.pid"
  restore_all_on_exit
  logx E "event=stop"
  update_module_desc
  echo "守护循环已停止，所有子进程已终止，所有状态已还原。"
  exit 0
  ;;
status)
  p=$(cat "$PIDF" 2>/dev/null); p=${p%%:*}
  if alive "$p"; then
    echo "主守护：运行中 pid=$p"
  else
    echo "主守护：未运行"
    rm -f "$PIDF" 2>/dev/null
  fi
  fs=$(cat "$RUN/fluencyshield.pid" 2>/dev/null); fs=${fs%%:*}
  if [ -n "$fs" ] && [ -d "/proc/$fs" ] && grep -q fluency_shield "/proc/$fs/cmdline" 2>/dev/null; then
    echo "实时护盾：运行中 pid=$fs"
  else
    echo "实时护盾：未运行"
  fi
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
_existing=$(cat "$PIDF" 2>/dev/null); _existing=${_existing%%:*}
if [ -n "$_existing" ] && [ -d "/proc/$_existing" ] && grep -q memtonic "/proc/$_existing/cmdline" 2>/dev/null; then
  logx W "event=start_rejected reason=already_running pid=$_existing msg=请先stop再start"
  echo "已有实例运行中 (pid=$_existing)，请先执行 stop。"
  exit 1
fi
check_root_liveness
echo "$$:$(pid_starttime $$)" > "$PIDF"
taskset -p 0f $$ >/dev/null 2>&1
logx E "event=start ver=$MT_VERSION pid=$$ mode=DualDaemon(memtonic+fluency_shield)"
boot_postmortem

# 启动初始化：检测并建立基线
check_staged_rollback
env_baseline
check_rollback_disarm
storm_restore_pending session_start
rm -rf "$STORM_FLAG" 2>/dev/null
restore_all_rogue

# 启动即备份一次无障碍服务，确保自愈备份立即就绪
_a11y_init=$(settings get secure enabled_accessibility_services 2>/dev/null)
if [ -n "$_a11y_init" ] && [ "$_a11y_init" != "null" ]; then
  echo "$_a11y_init" > "$RUN/a11y.bak"
fi

# 启动即采集一次真实 Dalvik 堆水位，刷新卡片描述
ss_heap_probe startup
update_module_desc

# 仅拉起实时流畅护盾子进程
pkill -9 -f fluency_shield.sh 2>/dev/null
nohup sh "$MODDIR/scripts/fluency_shield.sh" >/dev/null 2>&1 &
echo "$!" > "$RUN/fluencyshield.pid"
logx E "event=fluencyshield_launched pid=$(cat "$RUN/fluencyshield.pid") msg=实时流畅护盾已启动"

# 初始化时间线变量
IFS='. ' read -r _init_ts _ < /proc/uptime 2>/dev/null
case "$_init_ts" in ''|*[!0-9]*) _init_ts=$(date +%s);; esac
last_health_ts=$_init_ts
last_ss_probe_ts=$_init_ts
last_rogue_ts=$_init_ts
last_rogue_scan_ts=$_init_ts
last_compact_ts=0
last_kswapd_cpu=0
ss_heap_high_count=0
last_tick=""

last_sspid=$(pidof system_server 2>/dev/null); last_sspid=${last_sspid%% *}
touch "$DROPBOX_STATE" 2>/dev/null

# 主循环：亮屏 60 秒 / 息屏 300 秒零 fork 轻节拍
while true; do
  if screen_off; then
    sleep 300
  else
    sleep 60
  fi

  check_root_liveness
  IFS='. ' read -r now_s _ < /proc/uptime 2>/dev/null
  case "$now_s" in ''|*[!0-9]*) now_s=$(date +%s);; esac

  # ---------------------------------------------------------
  # 1. 每轮执行（60s/300s，全零 fork）
  # ---------------------------------------------------------
  # a. 软重启检测与自愈
  if [ -n "$last_sspid" ] && [ ! -d "/proc/$last_sspid" ]; then
    logx W "event=soft_reboot_detected old_sspid=$last_sspid msg=检测到system_server已重启"
    rm -f "$RUN"/*.flag "$RUN"/ss_heap.* 2>/dev/null
    capture_incident soft_reboot
    incident_cleanup
    sleep 15
    _new_sspid=$(pidof system_server 2>/dev/null); _new_sspid=${_new_sspid%% *}
    if [ -n "$_new_sspid" ]; then
      last_sspid=$_new_sspid
    fi
    if [ -s "$RUN/a11y.bak" ]; then
      _saved_a11y=$(cat "$RUN/a11y.bak" 2>/dev/null)
      _cur_a11y=$(settings get secure enabled_accessibility_services 2>/dev/null)
      if [ -n "$_saved_a11y" ] && [ "$_cur_a11y" != "$_saved_a11y" ]; then
        settings put secure enabled_accessibility_services "$_saved_a11y" 2>/dev/null
        logx A "act=a11y_restored msg=软重启后无障碍服务已从备份自动恢复"
      fi
    fi
    ss_heap_probe soft_reboot_recover 2>/dev/null
    last_ss_probe_ts=$now_s
    storm_window soft_reboot
    update_module_desc
  fi

  if [ -z "$last_sspid" ] || [ ! -d "/proc/$last_sspid" ]; then
    _cur_ss=$(pidof system_server 2>/dev/null); _cur_ss=${_cur_ss%% *}
    [ -n "$_cur_ss" ] && last_sspid=$_cur_ss
  fi

  # b. Dropbox 崩溃感知（零 fork 目录时间戳比对）
  if [ -d "/data/system/dropbox" ]; then
    if [ ! -f "$DROPBOX_STATE" ]; then
      touch "$DROPBOX_STATE" 2>/dev/null
    elif [ "/data/system/dropbox" -nt "$DROPBOX_STATE" ]; then
      touch "$DROPBOX_STATE" 2>/dev/null
      logx E "event=crash_detected msg=Dropbox目录更新_捕获新系统事件或崩溃"
      update_module_desc
    fi
  fi

  # ---------------------------------------------------------
  # 2. 每 3 分钟（仅亮屏且非 CAMERA_ACTIVE_FLAG 时）：极端 CPU+IO 熔断器
  # ---------------------------------------------------------
  if [ $((now_s - last_rogue_ts)) -ge 180 ]; then
    last_rogue_ts=$now_s
    if ! screen_off && [ ! -f "$CAMERA_ACTIVE_FLAG" ]; then
      scan_extreme_rogue "$now_s"
    fi
  fi

  # ---------------------------------------------------------
  # 3. 每 30 分钟（且非 CAMERA_ACTIVE_FLAG 时）：Dalvik Java 堆只读预警
  # ---------------------------------------------------------
  if [ $((now_s - last_ss_probe_ts)) -ge 1800 ]; then
    last_ss_probe_ts=$now_s
    if [ ! -f "$CAMERA_ACTIVE_FLAG" ]; then
      ss_heap_probe 30min
      _cur_heap=$(cat "$SS_HEAP_KB_FILE" 2>/dev/null)
      case "$_cur_heap" in ''|*[!0-9]*) _cur_heap=0;; esac
      if [ "$_cur_heap" -ge 450560 ]; then
        ss_heap_high_count=$((ss_heap_high_count + 1))
        if [ "$ss_heap_high_count" -ge 2 ]; then
          _rb_cnt=$(dumpsys rollback 2>/dev/null | grep -c 'state: enabling')
          case "$_rb_cnt" in ''|*[!0-9]*) _rb_cnt=0;; esac
          if [ "$_rb_cnt" -eq 0 ]; then
            echo "advised=$(date '+%m-%d %H:%M:%S') reason=ss_heap_high heap_kb=$_cur_heap" > "$RUN/soft_reboot_advised.flag" 2>/dev/null
            notify_alert advise "MemTonic: system_server Java堆持续过高($(( _cur_heap / 1024 ))MB)——建议择机手动软重启"
            logx W "warn=ss_heap_high heap_kb=$_cur_heap streak=$ss_heap_high_count suggest=soft_reboot"
          else
            echo "heap_kb=$_cur_heap rollback_count=$_rb_cnt ts=$(date '+%m-%d %H:%M:%S')" > "$RUN/reboot_suppressed.flag" 2>/dev/null
            logx W "warn=ss_heap_high heap_kb=$_cur_heap note=suppressed_due_to_rollback"
          fi
        fi
      else
        ss_heap_high_count=0
        if [ -f "$RUN/soft_reboot_advised.flag" ]; then
          case "$(cat "$RUN/soft_reboot_advised.flag" 2>/dev/null)" in
            *reason=ss_heap_high*)
              rm -f "$RUN/soft_reboot_advised.flag" 2>/dev/null
              logx I "act=ss_heap_recovered heap_kb=$_cur_heap msg=Java堆回落_软重启建议已撤除"
              ;;
          esac
        fi
      fi
      check_staged_rollback
      check_rollback_disarm
    fi
  fi

  # ---------------------------------------------------------
  # 4. 每 60 分钟：无障碍自愈备份 + health_snap + description
  # ---------------------------------------------------------
  if [ $((now_s - last_health_ts)) -ge 3600 ]; then
    last_health_ts=$now_s
    a11y=$(settings get secure enabled_accessibility_services 2>/dev/null)
    if [ -n "$a11y" ] && [ "$a11y" != "null" ]; then
      echo "$a11y" > "$RUN/a11y.bak"
    fi

    sw=$(awk '/^SwapTotal/{t=$2}/^SwapFree/{f=$2}END{print t-f}' /proc/meminfo 2>/dev/null)
    ks_pid=$(pgrep -x kswapd0 2>/dev/null | head -n 1)
    if [ -n "$ks_pid" ]; then
      new_kswapd_cpu=$(self_cpu_ms "$ks_pid")
      if [ -n "$new_kswapd_cpu" ] && [ "${last_kswapd_cpu:-0}" -gt 0 ]; then
        ks_delta=$((new_kswapd_cpu - last_kswapd_cpu))
        logx S "health_snap avail_kb=$(avail_kb) swap_used=${sw}KB psi_cpu=$(psi_val cpu some) psi_mem=$(psi_val memory some) psi_io=$(psi_val io some) kswapd_pid=$ks_pid kswapd_delta_ms=$ks_delta"
        if [ "$ks_delta" -ge 90000 ]; then
          logx W "warn=kswapd_growth delta_ms=$ks_delta msg=换页风暴实锤_严禁亮屏压实防allocstall"
        fi
      else
        logx S "health_snap avail_kb=$(avail_kb) swap_used=${sw}KB psi_cpu=$(psi_val cpu some) psi_mem=$(psi_val memory some) psi_io=$(psi_val io some) kswapd_pid=$ks_pid kswapd_delta_ms=NA"
      fi
      last_kswapd_cpu=${new_kswapd_cpu:-0}
    fi
    update_module_desc
    incident_cleanup
  fi

  # 每日心跳
  today=$(date '+%Y%m%d')
  if [ "$today" != "$last_tick" ]; then
    last_tick=$today
    update_module_desc
    log "[tick] 存活检查 avail=$(avail_kb)KB"
  fi

  # 息屏纯按需压实（息屏 + 高 PSI 压力 + 3600s 冷却）
  if screen_off; then
    if psi_mem_pressure_high; then
      if [ $((now_s - last_compact_ts)) -ge 3600 ]; then
        last_compact_ts=$now_s
        maintenance on_demand_pressure
      fi
    fi
  fi
done
