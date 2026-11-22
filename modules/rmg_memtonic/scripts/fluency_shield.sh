#!/system/bin/sh
# fluency_shield.sh —— RMG MemTonic v2.0.1 前台护盾 (FR-9) + Universal Camera Guard + Screenshot Sentinel
#
# v2.0.1 极速省电与闭环重构：
# 1. 0-fork 单调秒：IFS='. ' read -r _tick_ts _ < /proc/uptime 彻底替代 date +%s；
# 2. 息屏短路休眠：息屏且无相机/无护盾/无截屏时 sleep 20 深度休眠，跳过全量轮询；
# 3. 截屏哨兵 0-fork 时间戳比对：[ "$sc_dir" -nt "$RUN/sc_dir.ref" ]，消除每 5s 穿透 FUSE 扫盘；
# 4. 前台护盾温和提权：门槛收紧为 mem PSI >= 15% (1500) 或 cpu PSI >= 35% (3500)，
#    复用 get_top_app_info 零 fork 定位，提权 SurfaceFlinger 与 RenderThread 至 -10（严禁 -15）。

_fs_self_dir=${0%/*}
[ "$_fs_self_dir" = "$0" ] && _fs_self_dir="/data/adb/modules/rmg_memtonic/scripts"
if [ -f "$_fs_self_dir/mt_lib.sh" ]; then
  . "$_fs_self_dir/mt_lib.sh"
else
  . "/data/adb/modules/rmg_memtonic/scripts/mt_lib.sh"
fi
echo $$ > "$RUN/fluencyshield.pid"
taskset -p 0f $$ >/dev/null 2>&1
logx E "event=fluency_shield_start ver=$MT_VERSION msg=UniversalCameraGuard+FR-9+ScreenshotSentinel"

is_boosting=0
shield_cooldown_until=0   # 护盾冷却截止时间戳（单调秒）
cam_state=0               # 0=相机空闲, 1=相机激活
_cam_idle_rounds=0
_last_cam_ticks=0
_cam_prov_pid=""
_tick_ts=0

# FR-S: 截屏目录初始化
sc_dir=""
for _d in "/sdcard/DCIM/Screenshots" "/sdcard/Pictures/Screenshots" "/storage/emulated/0/DCIM/Screenshots"; do
  [ -d "$_d" ] && { sc_dir="$_d"; break; }
done
sc_prev_count=0
if [ -n "$sc_dir" ]; then
  touch "$RUN/sc_dir.ref" 2>/dev/null
  sc_prev_count=$(ls "$sc_dir" 2>/dev/null | wc -l)
fi

# 启动自愈：上一轮异常残留还原
shield_fg_restore
rm -f "$CAMERA_ACTIVE_FLAG" "$SCREENSHOT_ACTIVE_FLAG" "$RUN/screenshot_fg.bak" 2>/dev/null

while true; do
  sleep 5
  main_daemon_alive || break
  IFS='. ' read -r _tick_ts _ < /proc/uptime 2>/dev/null
  case "$_tick_ts" in ''|*[!0-9]*) _tick_ts=$(date +%s);; esac

  # 息屏判定（0-fork 优先读取背光面板亮度）
  _idle_screen=0
  if screen_off; then
    _idle_screen=1
  fi

  # 息屏深度短路休眠（0 fork、跳过后续全部检测，彻底切断息屏无效轮询）
  if [ "$_idle_screen" -eq 1 ] && [ "$cam_state" -eq 0 ] && [ "$is_boosting" -eq 0 ] && [ ! -f "$SCREENSHOT_ACTIVE_FLAG" ]; then
    sleep 20
    continue
  fi

  # =========================================================
  # 1. Universal Camera Guard (0-fork 全域硬件相机护航)
  # =========================================================
  if [ "$_idle_screen" -eq 0 ]; then
    if [ -z "$_cam_prov_pid" ] || [ ! -d "/proc/$_cam_prov_pid" ]; then
      _cam_prov_pid=$(pidof vendor.samsung.hardware.camera.provider-service_64 2>/dev/null)
      _cam_prov_pid=${_cam_prov_pid%% *}
    fi
    _delta=0
    if [ -n "$_cam_prov_pid" ] && [ -r "/proc/$_cam_prov_pid/stat" ]; then
      if read -r _a _b _c _d _e _f _g _h _i _j _k _l _m _ut _st _rest < "/proc/$_cam_prov_pid/stat" 2>/dev/null; then
        case "${_ut:-}${_st:-}" in
          ''|*[!0-9]*) ;;
          *)
            _cam_tot=$(( _ut + _st ))
            if [ "${_last_cam_ticks:-0}" -gt 0 ]; then
              _delta=$(( _cam_tot - _last_cam_ticks ))
              [ "$_delta" -lt 0 ] && _delta=0
            fi
            _last_cam_ticks=$_cam_tot
            ;;
        esac
      fi
    fi

    if [ "$_delta" -ge 3 ]; then
      _cam_idle_rounds=0
      if [ "$cam_state" -eq 0 ]; then
        cam_state=1
        touch "$CAMERA_ACTIVE_FLAG" 2>/dev/null
        ionice -c 2 -n 0 -p "$_cam_prov_pid" 2>/dev/null
        logx A "act=camera_guard_on pid=$_cam_prov_pid delta=$_delta msg=全域相机激活_provider提权至prio0"
      fi
    else
      if [ "$cam_state" -eq 1 ]; then
        _cam_idle_rounds=$(( ${_cam_idle_rounds:-0} + 1 ))
        if [ "$_cam_idle_rounds" -ge 3 ]; then
          cam_state=0
          _cam_idle_rounds=0
          rm -f "$CAMERA_ACTIVE_FLAG" 2>/dev/null
          ionice -c 2 -n 4 -p "$_cam_prov_pid" 2>/dev/null
          logx A "act=camera_guard_off pid=$_cam_prov_pid msg=全域相机退出_provider还原至prio4"
          update_module_desc
        fi
      fi
    fi
  fi

  # =========================================================
  # 2. FR-S Screenshot Sentinel (0-fork 目录时间戳检测)
  # =========================================================
  if [ -n "$sc_dir" ] && [ "$_idle_screen" -eq 0 ]; then
    if [ "$sc_dir" -nt "$RUN/sc_dir.ref" ]; then
      touch "$RUN/sc_dir.ref" 2>/dev/null
      sc_cur_count=$(ls "$sc_dir" 2>/dev/null | wc -l)
      if [ "$sc_cur_count" -gt "$sc_prev_count" ]; then
        sc_prev_count=$sc_cur_count
        touch "$SCREENSHOT_ACTIVE_FLAG" 2>/dev/null
        echo $((_tick_ts + 30)) > "$SCREENSHOT_END_TS" 2>/dev/null
        logx A "act=screenshot_sentinel_on msg=检测到新截屏_启动焦点预护航"

        _sc_tinfo=$(get_top_app_info 2>/dev/null)
        if [ -n "$_sc_tinfo" ]; then
          _sc_p=${_sc_tinfo%% *}
          _sc_pkg=${_sc_tinfo#* }
          if [ -d "/proc/$_sc_p" ]; then
            _sc_orig=$(nice_of "$_sc_p")
            case "$_sc_orig" in ''|*[!0-9-]*) ;; *)
              if [ "$_sc_orig" -gt -10 ]; then
                renice -n $((-10 - _sc_orig)) -p "$_sc_p" >/dev/null 2>&1
                echo "$_sc_p $_sc_orig" > "$RUN/screenshot_fg.bak" 2>/dev/null
              fi
              ;;
            esac
          fi
        fi
      else
        sc_prev_count=$sc_cur_count
      fi
    fi
  fi

  if [ -f "$SCREENSHOT_ACTIVE_FLAG" ]; then
    _sc_end=0
    [ -r "$SCREENSHOT_END_TS" ] && read -r _sc_end < "$SCREENSHOT_END_TS" 2>/dev/null
    case "$_sc_end" in ''|*[!0-9]*) _sc_end=0;; esac
    if [ "$_tick_ts" -ge "$_sc_end" ]; then
      rm -f "$SCREENSHOT_ACTIVE_FLAG" "$SCREENSHOT_END_TS" 2>/dev/null
      if [ -s "$RUN/screenshot_fg.bak" ]; then
        while read -r _sc_p _sc_orig; do
          case "$_sc_p" in ''|*[!0-9]*) continue;; esac
          [ -d "/proc/$_sc_p" ] || continue
          _sc_cur=$(nice_of "$_sc_p")
          case "$_sc_cur" in ''|*[!0-9-]*) continue;; esac
          renice -n $((_sc_orig - _sc_cur)) -p "$_sc_p" >/dev/null 2>&1
        done < "$RUN/screenshot_fg.bak"
        rm -f "$RUN/screenshot_fg.bak" 2>/dev/null
      fi
      logx A "act=screenshot_sentinel_off msg=截屏预护航窗口结束_优先级已还原"
    fi
  fi

  # =========================================================
  # 3. FR-9 Foreground Shield (温和提权 -10 + 0-fork 解析)
  # =========================================================
  if [ "$_tick_ts" -lt "$shield_cooldown_until" ]; then
    continue
  fi

  # 零 fork 读取 memory 与 cpu pressure
  psi_mem_int=0
  if [ -r /proc/pressure/memory ]; then
    while IFS= read -r _line; do
      case "$_line" in
        some*)
          _val=${_line#*avg10=}; _val=${_val%% *}
          _int=${_val%%.*}; _dec=${_val#*.}
          _d1=${_dec:0:1}; _d2=${_dec:1:1}
          [ -z "$_d1" ] && _d1=0; [ -z "$_d2" ] && _d2=0
          psi_mem_int=$(( _int * 100 + _d1 * 10 + _d2 ))
          break
          ;;
      esac
    done < /proc/pressure/memory
  fi

  psi_cpu_int=0
  if [ -r /proc/pressure/cpu ]; then
    while IFS= read -r _line; do
      case "$_line" in
        some*)
          _val=${_line#*avg10=}; _val=${_val%% *}
          _int=${_val%%.*}; _dec=${_val#*.}
          _d1=${_dec:0:1}; _d2=${_dec:1:1}
          [ -z "$_d1" ] && _d1=0; [ -z "$_d2" ] && _d2=0
          psi_cpu_int=$(( _int * 100 + _d1 * 10 + _d2 ))
          break
          ;;
      esac
    done < /proc/pressure/cpu
  fi

  # 门槛：mem PSI >= 1500 (15.00%) 或 cpu PSI >= 3500 (35.00%)
  if [ "$psi_mem_int" -ge 1500 ] || [ "$psi_cpu_int" -ge 3500 ]; then
    is_boosting=1
    _tinfo=$(get_top_app_info 2>/dev/null)
    fg_pid=""; fg_pkg=""
    if [ -n "$_tinfo" ]; then
      fg_pid=${_tinfo%% *}
      fg_pkg=${_tinfo#* }
    fi

    # 1. 提权 SurfaceFlinger 至 -10（严禁 -15）
    sf_pid=$(pidof surfaceflinger 2>/dev/null); sf_pid=${sf_pid%% *}
    sf_orig=""
    if [ -n "$sf_pid" ] && [ -d "/proc/$sf_pid" ]; then
      sf_orig=$(nice_of "$sf_pid")
      case "$sf_orig" in ''|*[!0-9-]*) sf_orig=0;; esac
      if [ "$sf_orig" -gt -10 ]; then
        renice -n $((-10 - sf_orig)) -p "$sf_pid" >/dev/null 2>&1
      fi
    fi

    # 2. 精准提权前台 App 主线程与 RenderThread 至 -10（严禁 -15）
    rt_tid=""
    fg_orig=""
    rt_orig=""
    if [ -n "$fg_pid" ] && [ -d "/proc/$fg_pid" ]; then
      fg_orig=$(nice_of "$fg_pid")
      case "$fg_orig" in ''|*[!0-9-]*) fg_orig=0;; esac
      if [ "$fg_orig" -gt -10 ]; then
        renice -n $((-10 - fg_orig)) -p "$fg_pid" >/dev/null 2>&1
      fi

      # 0-fork 读取 comm 查找 RenderThread
      for _tid_p in /proc/$fg_pid/task/*; do
        _t="${_tid_p##*/}"
        case "$_t" in ''|*[!0-9]*) continue;; esac
        _tcomm=""
        read -r _tcomm < "$_tid_p/comm" 2>/dev/null
        if [ "$_tcomm" = "RenderThread" ]; then
          rt_tid=$_t
          rt_orig=$(nice_of "$rt_tid")
          case "$rt_orig" in ''|*[!0-9-]*) rt_orig=0;; esac
          if [ "$rt_orig" -gt -10 ]; then
            renice -n $((-10 - rt_orig)) -p "$rt_tid" >/dev/null 2>&1
          fi
          break
        fi
      done
      logx W "event=shield_activate psi_mem=$psi_mem_int psi_cpu=$psi_cpu_int pkg=$fg_pkg pid=$fg_pid msg=系统高压_温和护航主线程与渲染线程至-10"
    fi

    : > "$RUN/shield_fg.bak" 2>/dev/null
    [ -n "$sf_pid" ] && [ -n "$sf_orig" ] && echo "sf $sf_pid $sf_orig" >> "$RUN/shield_fg.bak" 2>/dev/null
    [ -n "$fg_pid" ] && [ -n "$fg_orig" ] && echo "fg $fg_pid $fg_orig" >> "$RUN/shield_fg.bak" 2>/dev/null
    [ -n "$rt_tid" ] && [ -n "$rt_orig" ] && echo "rt $rt_tid $rt_orig" >> "$RUN/shield_fg.bak" 2>/dev/null

    sleep 15

    # 差值还原
    if [ -n "$sf_pid" ] && [ -n "$sf_orig" ] && [ -d "/proc/$sf_pid" ]; then
      sf_cur=$(nice_of "$sf_pid")
      case "$sf_cur" in ''|*[!0-9-]*) ;;
        *) renice -n $((sf_orig - sf_cur)) -p "$sf_pid" >/dev/null 2>&1;; esac
    fi
    if [ -n "$fg_pid" ] && [ -n "$fg_orig" ] && [ -d "/proc/$fg_pid" ]; then
      fg_cur=$(nice_of "$fg_pid")
      case "$fg_cur" in ''|*[!0-9-]*) ;;
        *) renice -n $((fg_orig - fg_cur)) -p "$fg_pid" >/dev/null 2>&1;; esac
      if [ -n "$rt_tid" ] && [ -n "$rt_orig" ] && [ -d "/proc/$fg_pid/task/$rt_tid" ]; then
        rt_cur=$(nice_of "$rt_tid")
        case "$rt_cur" in ''|*[!0-9-]*) ;;
          *) renice -n $((rt_orig - rt_cur)) -p "$rt_tid" >/dev/null 2>&1;; esac
      fi
      logx I "event=shield_deactivate pkg=$fg_pkg msg=高压回落_精准还原全部特权"
      update_module_desc
    fi
    rm -f "$RUN/shield_fg.bak" 2>/dev/null

    is_boosting=0
    shield_cooldown_until=$((_tick_ts + 60))
  fi
done

# 退出清场
shield_fg_restore
if [ "$cam_state" -eq 1 ] && [ -n "$_cam_prov_pid" ]; then
  ionice -c 2 -n 4 -p "$_cam_prov_pid" 2>/dev/null
fi
rm -f "$RUN/fluencyshield.pid" "$CAMERA_ACTIVE_FLAG" "$SCREENSHOT_ACTIVE_FLAG" "$RUN/screenshot_fg.bak" 2>/dev/null
exit 0
