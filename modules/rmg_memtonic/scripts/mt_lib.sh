#!/system/bin/sh
# mt_lib.sh —— RMG MemTonic 公共函数库 (v2.0.1)
MT_VERSION="v2.0.1"

# v2.0.1: 规范路径解析——被 . (source) 调用时 $0 常为 sh 或 /system/bin/sh，
# 严禁盲信 ${0%/*} 导致 MODDIR 退化为 /system/bin！
_mt_resolve_moddir() {
  case "$0" in
    */*)
      _c=${0%/*}
      case "$_c" in */scripts) _c=${_c%/scripts} ;; esac
      if [ -f "$_c/module.prop" ] && [ -f "$_c/scripts/mt_lib.sh" ]; then
        echo "$_c"
        return 0
      fi
      ;;
  esac
  if [ -f "/data/adb/modules/rmg_memtonic/scripts/mt_lib.sh" ]; then
    echo "/data/adb/modules/rmg_memtonic"
  elif [ -f "/data/adb/modules_update/rmg_memtonic/scripts/mt_lib.sh" ]; then
    echo "/data/adb/modules_update/rmg_memtonic"
  else
    echo "/data/adb/modules/rmg_memtonic"
  fi
}
MODDIR=$(_mt_resolve_moddir)
unset -f _mt_resolve_moddir 2>/dev/null || true

RUN=$MODDIR/run
PIDF=$RUN/memtonic.pid
GUARD_PIDF=$RUN/guard.pid
LOG=$RUN/memtonic.log
MODULE_PROP=$MODDIR/module.prop
LOCK=$RUN/compact.lock

CAMERA_ACTIVE_FLAG=$RUN/camera_active.flag
CAMERA_VIP_BAK=$RUN/camera_vip.bak
CAMERA_AFF_BAK=$RUN/camera_affinity.bak
SCREENSHOT_ACTIVE_FLAG=$RUN/screenshot_active.flag
SCREENSHOT_END_TS=$RUN/screenshot_end.ts

SS_HEAP_KB_FILE=$RUN/ss_heap.kb
SS_HEAP_HIST=$RUN/ss_heap.hist
SS_SNAP_TS=$RUN/ss_snap.ts
SS_SNAP_CLEAN_TS=$RUN/ss_snap_clean.ts
SS_HEAP_WARN_KB=450560      # 440MB 预警线
SS_SNAP_CRISIS_KB=491520    # 480MB 危机线
SS_SNAP_COOL=3600           # 非危机态快照每小时最多 1 个

STORM_FLAG=$RUN/storm_active.flag
RLST=/data/local/tmp/memtonic_storm_renice.lst
ROGUE_LST=$RUN/cpu_rogue_renice.lst
DROPBOX=/data/system/dropbox
DROPBOX_STATE=$RUN/dropbox_state.txt

CHECK_INTERVAL=60
STORM_WINDOW=180
STORM_SCAN=5
STORM_EXIT_PSI=20
STORM_MAX_APP=180
STORM_NICE_APP=5

LAUNCHER_PKG="com.sec.android.app.launcher"
LAUNCHER_NICE=-4
RAYNEO_PKG="com.rayneo.venus.pub"
WHITELIST_PKGS="com.rayneo.venus.pub com.google.android.apps.bard com.tencent.wework com.android.bluetooth com.omarea.vtools com.omarea.gesture com.topjohnwu.magisk io.github.vvb2060.magisk com.github.metacubex.clash.meta com.v2ray.ang org.telegram.messenger com.tencent.mm"

mkdir -p "$RUN" 2>/dev/null
chmod 700 "$RUN" 2>/dev/null

notify_alert() {
  _ch=$1; _msg=$2; [ -n "$_msg" ] || return 0
  command -v cmd >/dev/null 2>&1 && cmd notification post -S bigtext -t "RMG MemTonic" "tag_$_ch" "$_msg" >/dev/null 2>&1
}

logx() {
  _lvl=$1; shift; _msg="$*"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$_lvl] $_msg" >> "$LOG" 2>/dev/null
  if [ -f "$LOG" ]; then
    _sz=$(wc -c < "$LOG" 2>/dev/null)
    case "$_sz" in ''|*[!0-9]*) ;; *)
      [ "$_sz" -ge 524288 ] && tail -c 262144 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null;;
    esac
  fi
}
log() { logx I "$*"; }
avail_kb() { awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null; }

psi_val() {
  _res=$(awk -v r="$2" '$1==r{for(i=1;i<=NF;i++) if($i ~ /^avg10=/) {sub(/avg10=/,"",$i); print $i; exit}}' /proc/pressure/$1 2>/dev/null)
  echo "${_res:-0.00}"
}

self_cpu_ms() {
  [ -n "$1" ] && [ -r "/proc/$1/stat" ] || { echo 0; return; }
  awk '{sub(/^[0-9]+ \(.*\) /,""); print int(($12+$13)*10)}' "/proc/$1/stat" 2>/dev/null
}

snapshot() {
  logx S "snap avail_kb=$(avail_kb) psi_cpu=$(psi_val cpu some) psi_mem=$(psi_val memory some) psi_io=$(psi_val io some)"
}

alive() {
  _pid=$1; case "$_pid" in ''|*[!0-9]*) return 1;; esac
  [ -d "/proc/$_pid" ] && grep -q memtonic "/proc/$_pid/cmdline" 2>/dev/null
}

screen_off() {
  if [ -r /sys/class/backlight/panel0-backlight/brightness ]; then
    _bl=""; IFS= read -r _bl < /sys/class/backlight/panel0-backlight/brightness 2>/dev/null
    case "$_bl" in 0) return 0;; ''|*[!0-9]*) ;; *) return 1;; esac
  fi
  dumpsys power 2>/dev/null | awk '
    /mHoldingDisplaySuspendBlocker=(false|true)/ { blk = ($0 ~ /false/) ? 1 : 0 }
    /mWakefulness=(Awake|Asleep|Dozing)/ { wake = ($0 ~ /(Asleep|Dozing)/) ? 1 : 0 }
    END { if (blk == 1 && wake == 1) exit 0; else exit 1; }
  '
}

psi_mem_pressure_high() {
  _p=$(psi_val memory some); _p=${_p%%.*}
  case "$_p" in ''|*[!0-9]*) return 1;; esac
  [ "$_p" -ge 15 ]
}

pid_starttime() {
  [ -r "/proc/$1/stat" ] && awk '{print $22}' "/proc/$1/stat" 2>/dev/null
}

pkg_of() {
  _p=$1; [ -r "/proc/$_p/cmdline" ] || return 1
  _cmd=""
  IFS= read -r _cmd < "/proc/$_p/cmdline" 2>/dev/null
  [ -n "$_cmd" ] || return 1
  _cmd=${_cmd%%:*}
  echo "${_cmd%% *}"
}

is_app_uid() {
  [ -r "/proc/$1/status" ] || return 1
  while IFS=': 	' read -r _k _v _; do
    if [ "$_k" = "Uid" ]; then
      case "$_v" in
        ''|*[!0-9]*) return 1;;
        *) [ "$_v" -ge 10000 ] && return 0 || return 1;;
      esac
    fi
  done < "/proc/$1/status" 2>/dev/null
  return 1
}

nice_of() {
  [ -r "/proc/$1/stat" ] || return 1
  awk '{sub(/^[0-9]+ \(.*\) /,""); print $17}' "/proc/$1/stat" 2>/dev/null
}

in_whitelist() {
  for _w in $WHITELIST_PKGS; do [ "$1" = "$_w" ] && return 0; done; return 1
}

apply_rogue_mitigation() {
  _arm_pid=$1; _arm_pkg=$2
  [ -n "$_arm_pid" ] && [ -d "/proc/$_arm_pid" ] || return 0
  renice -n 10 -p "$_arm_pid" >/dev/null 2>&1
  ionice -c 3 -p "$_arm_pid" >/dev/null 2>&1
  logx W "act=rogue_ionice pid=$_arm_pid pkg=$_arm_pkg msg=后台极端占用_施加renice10与Idle_IO"
}

# v2.0.1 P0 修复：get_top_app_info 严格校验 Uid>=10000 与 oom_score_adj == 0，排除系统常驻绑定服务与Root子服务
get_top_app_info() {
  _top_file=""
  if [ -r /dev/cpuset/top-app/cgroup.procs ]; then _top_file=/dev/cpuset/top-app/cgroup.procs
  elif [ -r /dev/cpuctl/top-app/cgroup.procs ]; then _top_file=/dev/cpuctl/top-app/cgroup.procs
  elif [ -r /dev/cpuset/top-app/tasks ]; then _top_file=/dev/cpuset/top-app/tasks; fi
  [ -n "$_top_file" ] || return 1
  _target_pid=""; _target_pkg=""
  while IFS= read -r _tpid; do
    case "$_tpid" in ''|*[!0-9]*) continue;; esac
    [ -d "/proc/$_tpid" ] || continue
    is_app_uid "$_tpid" || continue
    _cmd_raw=""
    IFS= read -r _cmd_raw < "/proc/$_tpid/cmdline" 2>/dev/null
    [ -n "$_cmd_raw" ] || continue
    _cmd_raw=${_cmd_raw%%:*}; _cmd_raw=${_cmd_raw%% *}
    case "$_cmd_raw" in
      system_server|*surfaceflinger*|/system/*|/vendor/*|/apex/*|android.hardware.*|com.android.systemui*|com.samsung.SMT|com.google.android.tts|com.samsung.android.honeyboard) continue ;;
      *.*)
        _adj=""
        read -r _adj < "/proc/$_tpid/oom_score_adj" 2>/dev/null
        if [ "$_adj" = "0" ]; then
          _target_pid=$_tpid; _target_pkg=$_cmd_raw; break
        fi
        ;;
    esac
  done < "$_top_file"
  if [ -n "$_target_pid" ] && [ -n "$_target_pkg" ]; then
    echo "$_target_pid $_target_pkg"; return 0
  fi
  return 1
}

focused_pkg() {
  _tinfo=$(get_top_app_info 2>/dev/null)
  if [ -n "$_tinfo" ]; then echo "${_tinfo#* }"; return 0; fi
  dumpsys window 2>/dev/null | grep -m1 'mCurrentFocus=Window{' | sed -n 's/.* u0 \([^ /}]*\).*//p'
}

is_foreground_service() {
  [ -r "/proc/$1/oom_score_adj" ] || return 1
  read -r _adj < "/proc/$1/oom_score_adj" 2>/dev/null
  case "$_adj" in ''|*[!0-9-]*) return 1;; *) [ "$_adj" -le 200 ];; esac
}

is_in_top_app_cgroup() {
  [ -r "/proc/$1/cpuset" ] && read -r _cs < "/proc/$1/cpuset" 2>/dev/null && [ "$_cs" = "/top-app" ]
}

main_daemon_alive() {
  _mp=$(cat "$PIDF" 2>/dev/null); _mp=${_mp%%:*}
  case "$_mp" in ''|*[!0-9]*) return 1;; *) [ -d "/proc/$_mp" ] && grep -q memtonic "/proc/$_mp/cmdline" 2>/dev/null;; esac
}

rollback_dump_get() { dumpsys rollback 2>/dev/null; }

check_staged_rollback() {
  _rb_cnt=$(dumpsys rollback 2>/dev/null | grep -c 'state: enabling')
  case "$_rb_cnt" in ''|*[!0-9]*) _rb_cnt=0;; esac
  if [ "$_rb_cnt" -gt 0 ]; then
    logx W "warn=staged_rollback active_count=$_rb_cnt msg=检出待生效回滚会话_禁止软重启防丢Root"
    echo "rollback_count=$_rb_cnt ts=$(date '+%m-%d %H:%M:%S')" > "$RUN/reboot_suppressed.flag" 2>/dev/null
    notify_alert rollback "MemTonic: 检出 $_rb_cnt 条staged rollback——严禁重启,避免丢Root"
  else
    [ -f "$RUN/reboot_suppressed.flag" ] && rm -f "$RUN/reboot_suppressed.flag" 2>/dev/null
  fi
}

capture_incident() {
  _ts=$(date '+%Y%m%d_%H%M%S')
  _inc_file="$RUN/incident-${_ts}_$$.log"
  (
    echo "=== INCIDENT SNAPSHOT: $_ts reason=$1 ==="
    echo "--- UPTIME ---" && uptime 2>/dev/null
    echo "--- PSI ---" && cat /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io 2>/dev/null
    echo "--- ROLLBACK ACTIVE ---" && dumpsys rollback 2>/dev/null | grep -E '(enabling|committed)'
    echo "--- TOP 20 ---" && top -b -n 1 -m 20 2>/dev/null
    echo "--- MEMTONIC LOG TAIL ---" && tail -c 65536 "$LOG" 2>/dev/null
  ) > "$_inc_file" 2>&1 &
  logx E "event=incident_snapshot path=$_inc_file reason=$1"
}

check_root_liveness() {
  if [ "$(id -u 2>/dev/null)" != "0" ]; then
    logx E "event=root_lost_exit msg=Root会话失效_安全清场退出"
    restore_all_on_exit; exit 0
  fi
}

renice_tree() {
  _rp=$1; _rn=$2; _rpkg=$3; _rec=$4
  [ -d "/proc/$_rp/task" ] || return 0
  for _t in /proc/$_rp/task/*; do
    _tid=${_t##*/}; case "$_tid" in ''|*[!0-9]*) continue;; esac
    _orig=$(nice_of "$_tid"); case "$_orig" in ''|*[!0-9-]*) continue;; esac
    [ "$_orig" -lt 0 ] && [ "$_rn" -gt 0 ] && continue
    [ "$_orig" = "$_rn" ] && continue
    if renice -n $((_rn - _orig)) -p "$_tid" >/dev/null 2>&1; then
      [ "$_rec" = "1" ] && echo "$_tid $_orig $_rn $_rpkg" >> "$RLST" 2>/dev/null
    fi
  done
}

storm_restore_pending() {
  [ -s "$RLST" ] || return 0
  _restored=0
  while read -r _rtid _rorig _rcur _rpkg; do
    case "$_rtid" in ''|*[!0-9]*) continue;; esac
    [ -d "/proc/$_rtid" ] || continue
    _c=$(nice_of "$_rtid"); case "$_c" in ''|*[!0-9-]*) continue;; esac
    [ "$_c" = "$_rorig" ] && continue
    renice -n $((_rorig - _c)) -p "$_rtid" >/dev/null 2>&1 && _restored=$((_restored+1))
  done < "$RLST"
  rm -f "$RLST" 2>/dev/null
  [ "$_restored" -gt 0 ] && logx A "act=storm_restore ctx=$1 count=$_restored msg=风暴期降权线程已批量还原"
}

storm_window() {
  _reason=$1; _t0=$(date +%s)
  logx E "event=storm_start reason=$_reason sspid=$(pidof system_server 2>/dev/null)"
  mkdir "$STORM_FLAG" 2>/dev/null
  : > "$RLST" 2>/dev/null
  _end=$((_t0 + STORM_WINDOW)); _n_app=0; _n_launcher=0; _done_pids=" "; _psi_low=0
  while [ "$(date +%s)" -lt "$_end" ]; do
    sleep $STORM_SCAN
    _p=$(psi_val cpu some); _p=${_p%%.*}
    case "$_p" in ''|*[!0-9]*) _p=99;; esac
    if [ "$_p" -lt "$STORM_EXIT_PSI" ]; then _psi_low=$((_psi_low+1)); else _psi_low=0; fi
    [ "$_psi_low" -ge 3 ] && break

    _focus=$(focused_pkg)
    for _d in /proc/[0-9]*; do
      _pid=${_d##*/}; case "$_done_pids" in *" $_pid "*) continue;; esac
      is_app_uid "$_pid" >/dev/null || { _done_pids="$_done_pids$_pid "; continue; }
      _pkg=$(pkg_of "$_pid"); case "$_pkg" in ''|*" "*) _done_pids="$_done_pids$_pid "; continue;; esac
      if [ "$_pkg" = "$LAUNCHER_PKG" ]; then
        renice_tree "$_pid" "$LAUNCHER_NICE" "$_pkg" 0
        _n_launcher=$((_n_launcher+1)); _done_pids="$_done_pids$_pid "; continue
      fi
      if in_whitelist "$_pkg" || is_frozen_pid "$_pid" || is_foreground_service "$_pid"; then
        _done_pids="$_done_pids$_pid "; continue
      fi
      [ "$_pkg" = "$_focus" ] && { _done_pids="$_done_pids$_pid "; continue; }
      [ "$(nice_of "$_pid")" = "0" ] || { _done_pids="$_done_pids$_pid "; continue; }
      [ "$_n_app" -ge "$STORM_MAX_APP" ] && { _done_pids="$_done_pids$_pid "; continue; }
      renice_tree "$_pid" "$STORM_NICE_APP" "$_pkg" 1
      _n_app=$((_n_app+1)); _done_pids="$_done_pids$_pid "
    done
  done
  storm_restore_pending storm_end
  rm -rf "$STORM_FLAG" 2>/dev/null
  logx E "event=storm_end reason=$_reason duration=$(( $(date +%s) - _t0 )) app_renice=$_n_app launcher_boost=$_n_launcher"
}

camera_guard_restore() {
  _cgp=$(pidof vendor.samsung.hardware.camera.provider-service_64 2>/dev/null); _cgp=${_cgp%% *}
  [ -n "$_cgp" ] && ionice -c 2 -n 4 -p "$_cgp" 2>/dev/null
  rm -f "$CAMERA_ACTIVE_FLAG" "$CAMERA_VIP_BAK" "$CAMERA_AFF_BAK" 2>/dev/null
  logx A "act=camera_guard_off pid=${_cgp:-NA} msg=全域相机退出_provider还原至prio4"
}

ss_get_pss_kb() {
  [ -r "/proc/$1/smaps" ] || return 1
  awk '
    /^[0-9a-f]+-[0-9a-f]+ / { in_j = ($0 ~ /\[anon:dalvik-(main space|.*large object space|non moving space|zygote space)\]/) }
    in_j && /^Pss:/ { p += $2 }
    in_j && /^SwapPss:/ { s += $2 }
    END { print p + s + 0 }
  ' "/proc/$1/smaps" 2>/dev/null
}

ss_heap_probe() {
  _trig=${1:-manual}
  _ss=$(pidof system_server 2>/dev/null); _ss=${_ss%% *}
  [ -n "$_ss" ] || return 0
  _java_heap=$(ss_get_pss_kb "$_ss")
  case "$_java_heap" in ''|*[!0-9]*|0) return 0;; esac
  echo "$_java_heap" > "$SS_HEAP_KB_FILE" 2>/dev/null
  echo "$_java_heap" >> "$SS_HEAP_HIST" 2>/dev/null
  tail -n 6 "$SS_HEAP_HIST" > "$SS_HEAP_HIST.t" 2>/dev/null && mv "$SS_HEAP_HIST.t" "$SS_HEAP_HIST" 2>/dev/null

  if [ "$_java_heap" -ge "$SS_HEAP_WARN_KB" ]; then
    _snap_ok=1
    if [ "$_java_heap" -lt "$SS_SNAP_CRISIS_KB" ]; then
      _snow=$(date +%s); _st=0
      [ -r "$SS_SNAP_TS" ] && IFS= read -r _st < "$SS_SNAP_TS" 2>/dev/null
      case "$_st" in ''|*[!0-9]*) _st=0;; esac
      [ $((_snow - _st)) -ge "$SS_SNAP_COOL" ] || _snap_ok=0
    fi
    if [ "$_snap_ok" = "1" ]; then
      _ssbb="$RUN/ssheap-$(date '+%Y%m%d_%H%M%S').log"
      { echo "# MemTonic ssheap _trigger=$_trig _ts=$(date '+%m-%d %H:%M:%S') pss_kb=$_java_heap";
        [ -r "/proc/$_ss/status" ] && head -n 35 "/proc/$_ss/status"; } > "$_ssbb" 2>/dev/null
      date +%s > "$SS_SNAP_TS" 2>/dev/null
      logx A "act=ss_heap_probe trigger=$_trig ss_pss_kb=$_java_heap path=$(basename "$_ssbb")"
      _cl=0; [ -r "$SS_SNAP_CLEAN_TS" ] && IFS= read -r _cl < "$SS_SNAP_CLEAN_TS" 2>/dev/null
      case "$_cl" in ''|*[!0-9]*) _cl=0;; esac
      if [ $(( $(date +%s) - _cl )) -ge 86400 ]; then
        find "$RUN" -maxdepth 1 -name 'ssheap-*.log' -mtime +7 -delete 2>/dev/null
        date +%s > "$SS_SNAP_CLEAN_TS" 2>/dev/null
        logx S "act=ss_snap_cleanup msg=已清理7天前堆快照"
      fi
    fi
  fi
  return 0
}

boot_postmortem() {
  logx I "event=boot_postmortem bootreason=$(getprop ro.boot.bootreason 2>/dev/null) rescue_count=$(getprop sys.rescue_boot_count 2>/dev/null)"
}

incident_cleanup() {
  _cnt=$(ls "$RUN"/incident-*.log 2>/dev/null | wc -l)
  if [ "$_cnt" -gt 5 ]; then
    ls -t "$RUN"/incident-*.log 2>/dev/null | sed -e '1,5d' | while read -r _f; do
      rm -f "$_f" 2>/dev/null && logx S "act=incident_cleanup file=${_f##*/}"
    done
  fi
}

check_rollback_disarm() {
  _rb_enabling=$(dumpsys rollback 2>/dev/null | grep -c 'state: enabling')
  case "$_rb_enabling" in ''|*[!0-9]*) _rb_enabling=0;; esac
  [ "$_rb_enabling" -gt 0 ] || return 0
  [ ! -f "$RUN/rollback_disarm.enable" ] && { logx W "warn=rollback_disarm_dryrun active_enabling=$_rb_enabling msg=发现enabling回滚但disarm未开启"; return 0; }
  for _j in /data/rollback/*/rollback.json; do
    [ -f "$_j" ] || continue
    _sid=$(awk -F': ' '/"sessionId"/{gsub(/[, ]/,"",$2); print $2; exit}' "$_j" 2>/dev/null)
    case "$_sid" in ''|*[!0-9]*) continue;; esac
    pm install-abandon "$_sid" >/dev/null 2>&1
    logx A "act=rollback_disarm abandoned_session=$_sid msg=已废弃孤儿回滚session"
  done
}

psi_mem_read() {
  [ -r /proc/pressure/memory ] || return 1
  P_S10=$(awk -F'avg10=' '/some/{print $2; exit}' /proc/pressure/memory 2>/dev/null); P_S10=${P_S10%% *}
  P_F10=$(awk -F'avg10=' '/full/{print $2; exit}' /proc/pressure/memory 2>/dev/null); P_F10=${P_F10%% *}
  return 0
}

mem_blackbox() {
  _ts=$(date '+%Y%m%d_%H%M%S')
  _bb="$RUN/blackbox-${_ts}.log"
  (
    echo "=== MEMORY CRISIS BLACKBOX: $_ts reason=$1 ==="
    echo "--- MEMINFO ---" && cat /proc/meminfo 2>/dev/null
    echo "--- PSI ---" && cat /proc/pressure/memory 2>/dev/null
    echo "--- TOP 10 RSS ---"
    for _d in /proc/[0-9]*; do
      _p=${_d##*/}
      [ -r "/proc/$_p/statm" ] && read -r _vmrss _ < "/proc/$_p/statm" 2>/dev/null && echo "$_vmrss $_p $(pkg_of "$_p")"
    done 2>/dev/null | sort -nr | head -n 10
  ) > "$_bb" 2>&1 &
  logx E "act=mem_blackbox path=$_bb reason=$1"
}

collect_stats() {
  _st_pid=$(cat "$PIDF" 2>/dev/null); _st_pid=${_st_pid%%:*}
  _st_state=stopped
  case "$_st_pid" in ''|*[!0-9]*) _st_pid=NA;; *) [ -d "/proc/$_st_pid" ] && _st_state=running;; esac
  _st_cnt=$(awk '
    /act=camera_guard_on/ || /act=flush_guard_on/ {cam++}
    /event=shield_activate/ {sh++}
    /act=screenshot_boost/ || /act=screenshot_sentinel_on/ {sc++}
    /event=storm_start/ {st++}
    /event=cpu_rogue_intervene/ || /event=cpu_extreme_intervene/ || /act=rogue_ionice/ {ro++}
    (index($0,"内存压实完成")>0) || (/act=fg_compact/ && /result=ok/) {cp++}
    /event=rollback_disarm/ || /warn=staged_rollback/ {rb++}
    /event=crash_detected/ || /act=mem_blackbox/ {cr++}
    END { print cam+0, sh+0, sc+0, st+0, ro+0, cp+0, rb+0, cr+0 }
  ' "$LOG" 2>/dev/null)
  set -- $_st_cnt
  _st_cam=${1:-0}; _st_shield=${2:-0}; _st_sc=${3:-0}; _st_storm=${4:-0}
  _st_rogue=${5:-0}; _st_compact=${6:-0}; _st_rollback=${7:-0}; _st_crash=${8:-0}
  for _k in _st_cam _st_shield _st_sc _st_storm _st_rogue _st_compact _st_rollback _st_crash; do
    eval "v=\$$_k"; case "$v" in ''|*[!0-9]*) eval "$_k=0";; esac
  done
  psi_mem_read || P_S10=NA P_F10=NA
  _st_ssheap=$(cat "$SS_HEAP_KB_FILE" 2>/dev/null); case "$_st_ssheap" in ''|*[!0-9]*) _st_ssheap=NA;; esac
  _st_st=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null); _st_st=${_st_st:-0}
  _st_sf=$(awk '/^SwapFree:/{print $2}' /proc/meminfo 2>/dev/null); _st_sf=${_st_sf:-0}
  _st_cpsi=$(awk -F'avg10=' '/some/{print $2; exit}' /proc/pressure/cpu 2>/dev/null); _st_cpsi=${_st_cpsi%% *}
  echo "state=$_st_state pid=${_st_pid:-NA} cam=$_st_cam shield=$_st_shield sc=$_st_sc storm=$_st_storm rogue=$_st_rogue compact=$_st_compact rollback=$_st_rollback crash=$_st_crash ssheap=$_st_ssheap avail_kb=$(avail_kb) psi_s10=${P_S10:-NA} psi_f10=${P_F10:-NA} swap_total_kb=$_st_st swap_free_kb=$_st_sf cpu_psi_s10=${_st_cpsi:-NA}"
}

# v2.0.1: update_module_desc —— SS堆缺失时明确显示「待采集」，杜绝假安全感
update_module_desc() {
  [ -f "$MODULE_PROP" ] || return 0
  _cs=$(collect_stats)
  _state=NA; _pid=NA; _cam=0; _shield=0; _sc=0; _storm=0; _rogue=0; _compact=0; _rollback=0; _crash=0; _ssheap=NA; _avail=NA; _psis=NA; _psif=NA
  for kv in $_cs; do
    k=${kv%%=*}; v=${kv#*=}
    case "$k" in
      state) _state=$v;; pid) _pid=$v;; cam) _cam=$v;; shield) _shield=$v;; sc) _sc=$v;; storm) _storm=$v;;
      rogue) _rogue=$v;; compact) _compact=$v;; rollback) _rollback=$v;; crash) _crash=$v;;
      ssheap) _ssheap=$v;; avail_kb) _avail=$v;; psi_s10) _psis=$v;; psi_f10) _psif=$v;;
    esac
  done
  _avgb=$(( ${_avail:-0} / 1024 )) 2>/dev/null || _avgb=NA
  case "$_ssheap" in ''|*[!0-9]*) _ssheap_str="待采集";; *) _ssheap_str="$(( _ssheap / 1024 ))MB";; esac
  _sw=$(awk '/^SwapTotal/{t=$2}/^SwapFree/{f=$2}END{print (t-f)/1024}' /proc/meminfo 2>/dev/null)
  _swi=${_sw%%.*}; case "$_swi" in ''|*[!0-9]*) _swi=NA;; esac
  _nd="description=RMG MemTonic 内存守护 ($MT_VERSION)｜守护:${_state}(pid ${_pid})｜⚡本日志周期:相机${_cam}·护盾${_shield}·截屏${_sc}·风暴${_storm}·熔断${_rogue}·压实${_compact}·回滚${_rollback}·崩溃${_crash}｜可用${_avgb}MB·swap${_swi}MB·PSI ${_psis}/${_psif}·SS堆:${_ssheap_str}｜边界:不杀进程/不冻结/不动zram/不持久内核参数"
  if [ -x /data/adb/ksud ]; then
    KSU_MODULE=rmg_memtonic /data/adb/ksud module config set --temp override.description "${_nd#description=}" >/dev/null 2>&1 && return 0
  fi
  _tmp="$RUN/module.prop.tmp"
  awk -v nd="$_nd" '/^description=/{print nd; next} {print}' "$MODULE_PROP" > "$_tmp" 2>/dev/null || return 0
  if [ -s "$_tmp" ]; then
    mv "$_tmp" "$MODULE_PROP" 2>/dev/null
    chmod 0644 "$MODULE_PROP" 2>/dev/null
  fi
}

env_baseline() {
  logx S "env_baseline bg_apps_limit=$(getprop ro.sys.fw.bg_apps_limit 2>/dev/null)"
}

is_frozen_pid() {
  [ -r "/proc/$1/wchan" ] && read -r _w < "/proc/$1/wchan" 2>/dev/null && case "$_w" in *freeze*|*freezer*) return 0;; esac
  return 1
}

shield_fg_restore() {
  [ -s "$RUN/shield_fg.bak" ] || return 0
  _sfr=0
  while read -r _sfr_tag _sfr_p _sfr_o; do
    case "$_sfr_p" in ''|*[!0-9]*) continue;; esac
    case "$_sfr_o" in ''|*[!0-9-]*) continue;; esac
    [ -d "/proc/$_sfr_p" ] || continue
    _sfr_c=$(nice_of "$_sfr_p"); [ -n "$_sfr_c" ] || continue
    [ "$_sfr_c" = "$_sfr_o" ] && continue
    renice -n $((_sfr_o - _sfr_c)) -p "$_sfr_p" >/dev/null 2>&1 && _sfr=$((_sfr+1))
  done < "$RUN/shield_fg.bak"
  rm -f "$RUN/shield_fg.bak" 2>/dev/null
  [ "$_sfr" -gt 0 ] && logx A "act=shield_fg_restore restored=$_sfr msg=护盾提权残留已还原"
  return 0
}

restore_all_rogue() {
  [ -s "$ROGUE_LST" ] || return 0
  _rar=0
  while read -r _rpid _ron _rpkg; do
    case "$_rpid" in ''|*[!0-9]*) continue;; esac
    [ -d "/proc/$_rpid" ] || continue
    _rc=$(nice_of "$_rpid"); case "$_rc" in ''|*[!0-9-]*) continue;; esac
    [ "$_rc" != "$_ron" ] && renice -n $((_ron - _rc)) -p "$_rpid" >/dev/null 2>&1
    ionice -c 2 -n 4 -p "$_rpid" 2>/dev/null
    _rar=$((_rar+1))
  done < "$ROGUE_LST"
  rm -f "$ROGUE_LST" 2>/dev/null
  [ "$_rar" -gt 0 ] && logx I "act=rogue_restore_all restored=$_rar msg=极端CPU降权已全量还原"
}

restore_all_on_exit() {
  storm_restore_pending manual_stop 2>/dev/null
  camera_guard_restore              2>/dev/null
  shield_fg_restore                 2>/dev/null
  restore_all_rogue                 2>/dev/null
  rm -f "$ROGUE_LST" "$CAMERA_ACTIVE_FLAG" "$SCREENSHOT_ACTIVE_FLAG" "$RUN/screenshot_fg.bak" 2>/dev/null
  return 0
}

# 库文件结尾：严禁在被 . (source) 时执行 exit 1 误杀宿主 shell
case "$0" in
  */mt_lib.sh|mt_lib.sh)
    (return 0 2>/dev/null) || { echo "mt_lib.sh 是公共库，请运行 memtonic.sh"; exit 1; }
    ;;
esac
return 0 2>/dev/null || true
