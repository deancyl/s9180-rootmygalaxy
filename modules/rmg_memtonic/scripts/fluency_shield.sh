#!/system/bin/sh
# fluency_shield.sh —— RMG MemTonic 前台绝对护盾 (FR-9) + Camera Sentinel + Screenshot Sentinel (v1.10.0)
# FR-9：PSI 内存压力飙升时精准提权前台渲染链（SurfaceFlinger + 主线程 + RenderThread）。
# FR-C Camera Sentinel：每 5 秒嗅探 media.camera，相机激活时提权 HAL 服务。
# FR-S Screenshot Sentinel：监控截屏目录文件数，截屏后 30 秒内对前台 App 提权防卡顿。
#
# Fix-B: renice 还原使用差值计算（orig - cur），消除原始值被当 increment 累加的经典 Bug。
# Fix-E: 护盾退出后 5 秒冷却防抖，防 PSI 持续高企时连续重触发。
# v1.10.0: 同步版本号（v1.10.0 发布遗漏，自审补齐——v1.9.12 立下的版本串一致性规矩）。
. "$(dirname "$0")/mt_lib.sh"

echo $$ > "$RUN/fluencyshield.pid"
logx E "event=fluency_shield_start ver=1.10.0 msg=FR-9+CameraSentinel(focus)+ScreenshotSentinel已开启"

is_boosting=0
shield_cooldown_until=0   # Fix-E: 护盾冷却截止时间戳
cam_state=0               # Camera Sentinel 状态机：0=无相机 1=相机活跃

# FR-S: 截屏目录初始化（尝试多个常见路径）
sc_dir=""
for _d in "/sdcard/DCIM/Screenshots" "/sdcard/Pictures/Screenshots" "/storage/emulated/0/DCIM/Screenshots"; do
  [ -d "$_d" ] && { sc_dir="$_d"; break; }
done
sc_prev_count=0
[ -n "$sc_dir" ] && sc_prev_count=$(ls "$sc_dir" 2>/dev/null | wc -l)

while true; do
  sleep 5

  # =========================================================
  # FR-C Camera Sentinel
  # v1.9.7: 废除 dumpsys media.camera 探针（19,038 行 / 521ms 持锁掉帧根因）→ pidof 探测
  # v1.9.10: pidof 改为前台焦点判定——实测相机退到后台后进程不死，
  #   pidof 仍返回 PID → camera_sentinel_off 永不触发 → VIP 提权永不还原（泄漏）。
  #   改为 focused_pkg == 相机包名 才算活跃，退出前台立即触发还原。
  #   focused_pkg 读 dumpsys window mCurrentFocus（~50ms），无锁无副作用。
  # =========================================================
  cam_now=0
  _cam_focus=$(focused_pkg)
  [ "$_cam_focus" = "com.sec.android.app.camera" ] && cam_now=1

  if [ "$cam_now" -eq 1 ] && [ "$cam_state" -eq 0 ]; then
    # ── 相机刚激活 ────────────────────────────────────────
    cam_state=1
    touch "$CAMERA_ACTIVE_FLAG" 2>/dev/null
    camera_vip_on
    logx A "act=camera_sentinel_on msg=相机已激活_HAL服务已提权"

  elif [ "$cam_now" -eq 0 ] && [ "$cam_state" -eq 1 ]; then
    # ── 相机已退出前台 ────────────────────────────────────
    cam_state=0
    rm -f "$CAMERA_ACTIVE_FLAG" 2>/dev/null
    camera_vip_off
    logx A "act=camera_sentinel_off msg=相机已退出前台_HAL服务优先级已还原"
  fi

  # =========================================================
  # FR-S Screenshot Sentinel
  # 通过文件数变化检测新截屏，O(1)，无 dumpsys/pgrep 开销
  # =========================================================
  if [ -n "$sc_dir" ]; then
    sc_cur_count=$(ls "$sc_dir" 2>/dev/null | wc -l)
    if [ "$sc_cur_count" -gt "$sc_prev_count" ]; then
      # 新截屏检测到
      sc_prev_count=$sc_cur_count
      touch "$SCREENSHOT_ACTIVE_FLAG" 2>/dev/null
      echo $(($(date +%s) + 30)) > "$SCREENSHOT_END_TS" 2>/dev/null
      logx A "act=screenshot_sentinel_on msg=检测到新截屏_启动焦点预护航"

      # 截屏焦点预护航：主动抓取当前前台应用，逐 PID 提权（兼容三星应用分身双 PID）
      sc_fg_pkg=$(dumpsys window 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp' \
        | grep -Eo '[a-zA-Z0-9_.]+/[a-zA-Z0-9_.]+' | head -n 1 | cut -d/ -f1)
      if [ -n "$sc_fg_pkg" ]; then
        sc_fg_pids=$(pidof "$sc_fg_pkg")
        if [ -n "$sc_fg_pids" ]; then
          : > "$RUN/screenshot_fg.bak" 2>/dev/null   # 清空备份文件，准备多行写入
          for _sc_p in $sc_fg_pids; do
            case "$_sc_p" in ''|*[!0-9]*) continue;; esac
            [ -d "/proc/$_sc_p" ] || continue
            # 验证该 PID 确为目标包（防 PID 复用误伤）
            _sc_cmd=$(strings /proc/$_sc_p/cmdline 2>/dev/null | head -n 1 | cut -d: -f1)
            [ "$_sc_cmd" = "$sc_fg_pkg" ] || continue
            _sc_orig=$(nice_of "$_sc_p")
            case "$_sc_orig" in ''|*[!0-9-]*) continue;; esac
            # GEMINI.md 铁律：严禁反向降级（当前优先级已高于 -10 时跳过）
            [ "$_sc_orig" -le -10 ] && continue
            renice -n $((-10 - _sc_orig)) -p "$_sc_p" >/dev/null 2>&1
            echo "$_sc_p:$_sc_orig" >> "$RUN/screenshot_fg.bak" 2>/dev/null
          done
          logx I "act=screenshot_boost pkg=$sc_fg_pkg pids=$sc_fg_pids msg=截屏焦点预护航_逐PID提权"
        fi
      fi
    fi

    # 检查截屏处理是否超时（30 秒后自动还原）
    if [ -f "$SCREENSHOT_ACTIVE_FLAG" ]; then
      _sc_end=$(cat "$SCREENSHOT_END_TS" 2>/dev/null)
      case "$_sc_end" in ''|*[!0-9]*) _sc_end=0;; esac
      if [ "$(date +%s)" -ge "$_sc_end" ]; then
        rm -f "$SCREENSHOT_ACTIVE_FLAG" "$SCREENSHOT_END_TS" 2>/dev/null
        logx A "act=screenshot_sentinel_off msg=截屏处理完成"

        # 截屏焦点预护航还原：逐行读取 bak，逐 PID 差值还原
        if [ -s "$RUN/screenshot_fg.bak" ]; then
          while IFS=: read -r _sc_pid _sc_orig; do
            case "$_sc_pid" in ''|*[!0-9]*) continue;; esac
            case "$_sc_orig" in ''|*[!0-9-]*) continue;; esac
            [ -d "/proc/$_sc_pid" ] || continue
            _sc_cur=$(nice_of "$_sc_pid")
            case "$_sc_cur" in ''|*[!0-9-]*) continue;; esac
            renice -n $((_sc_orig - _sc_cur)) -p "$_sc_pid" >/dev/null 2>&1
          done < "$RUN/screenshot_fg.bak"
          rm -f "$RUN/screenshot_fg.bak" 2>/dev/null
          logx I "act=screenshot_boost_off msg=截屏焦点预护航结束_全部PID已还原"
        fi
      fi
    fi
  fi


  # =========================================================
  # FR-9 前台绝对护盾
  # Fix-E: 冷却期内跳过，防 PSI 持续高企时 4 秒内双触发
  # =========================================================
  _now_s=$(date +%s)
  if [ "$_now_s" -lt "$shield_cooldown_until" ]; then
    continue
  fi

  psi=$(cat /proc/pressure/memory 2>/dev/null | grep "some" | awk '{print $2}' | cut -d= -f2)
  case "$psi" in ''|*[!0-9.]*) continue;; esac
  psi_int=$(echo "$psi" | awk '{print int($1*100)}')

  if [ "$psi_int" -ge 1500 ] && [ "$is_boosting" -eq 0 ]; then
    is_boosting=1

    # 1. 抓取前台焦点 App 包名
    fg_pkg=$(dumpsys window 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp' \
      | grep -Eo '[a-zA-Z0-9_.]+/[a-zA-Z0-9_.]+' | head -n 1 | cut -d/ -f1)

    sf_pid=$(pidof surfaceflinger)
    sf_orig=""; fg_pid=""; fg_orig=""; rt_tid=""; rt_orig=""

    # 2. 备份并提权 SurfaceFlinger
    if [ -n "$sf_pid" ]; then
      sf_orig=$(nice_of "$sf_pid")
      renice -n -15 -p "$sf_pid" >/dev/null 2>&1
    fi

    # 3. 精准提权前台 App 主线程与 RenderThread
    # v1.9.0: 修复三星应用分身双 PID（pidof 可能返回多值，逐个验证取 User 0 主进程）
    if [ -n "$fg_pkg" ]; then
      fg_pids=$(pidof "$fg_pkg")
      fg_pid=""
      for _fp in $fg_pids; do
        case "$_fp" in ''|*[!0-9]*) continue;; esac
        [ -d "/proc/$_fp" ] || continue
        # 验证归属（防 PID 复用），取第一个匹配 PID 作为主进程
        _fp_cmd=$(strings /proc/$_fp/cmdline 2>/dev/null | head -n 1 | cut -d: -f1)
        [ "$_fp_cmd" = "$fg_pkg" ] || continue
        fg_pid=$_fp
        break
      done
      if [ -n "$fg_pid" ]; then
        fg_orig=$(nice_of "$fg_pid")
        case "$fg_orig" in ''|*[!0-9-]*) fg_orig=0;; esac
        # GEMINI.md 铁律：严禁反向降级（已高于 -15 的线程跳过）
        if [ "$fg_orig" -gt -15 ]; then
          renice -n $((-15 - fg_orig)) -p "$fg_pid" >/dev/null 2>&1
        fi
        for tid in /proc/$fg_pid/task/*; do
          t="${tid##*/}"
          case "$t" in ''|*[!0-9]*) continue;; esac
          if grep -q "RenderThread" /proc/$fg_pid/task/$t/comm 2>/dev/null; then
            rt_tid=$t; rt_orig=$(nice_of "$rt_tid")
            case "$rt_orig" in ''|*[!0-9-]*) rt_orig=0;; esac
            [ "$rt_orig" -gt -15 ] && renice -n $((-15 - rt_orig)) -p "$rt_tid" >/dev/null 2>&1
            break
          fi
        done
        logx W "event=shield_activate psi=$psi pkg=$fg_pkg pid=$fg_pid msg=系统拥堵_精准护航主线程与渲染线程"
      fi
    else
      logx W "event=shield_activate psi=$psi pkg=unknown msg=系统拥堵_仅护航系统渲染层"
    fi

    # 4. 维持护航 15 秒
    sleep 15

    # 5. Fix-B: 精确差值还原（防原始值被当 increment 累加的经典 Bug）
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
      logx I "event=shield_deactivate pkg=$fg_pkg msg=压力回落_精准还原全部特权"
    fi


    is_boosting=0
    # Fix-E: 护盾退出后冷却防抖（v1.9.7: 5s→60s，降低高 PSI 持续期的反复提权-还原震荡）
    shield_cooldown_until=$(($(date +%s) + 60))
  fi
done
