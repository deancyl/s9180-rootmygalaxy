#!/system/bin/sh
# fluency_shield.sh —— RMG MemTonic 前台护盾 (FR-9) + Camera Sentinel + Screenshot Sentinel + BT Sentinel + FR-C3 Flush Sentinel (v1.12.5)
# FR-9: PSI 内存压力飙升时精准提权前台渲染链（SurfaceFlinger + 主线程 + RenderThread）。
# FR-C Camera Sentinel: 每 5 秒嗅探 media.camera，相机激活时提权 HAL 服务。
# FR-S Screenshot Sentinel: 监控截屏目录文件数，截屏后 30 秒内对前台 App 提权防卡顿。
# FR-BT BT Sentinel (v1.12.0): 蓝牙音频流活跃且（相机活跃或 PSI≥8%）时，BT 栈/HAL/audioserver
#   逐线程提权至 -8，防 CPU 争抢下 A2DP/HFP 环形缓冲欠载（爆音/断联）。
#
# Fix-B: renice 还原使用差值计算（orig - cur），消除原始值被当 increment 累加的经典 Bug。
# Fix-E: 护盾退出后 5 秒冷却防抖，防 PSI 持续高企时连续重触发。
# v1.10.0: 同步版本号。
# v1.11.0: 再次同步版本号。
# v1.12.0: FR-BT 蓝牙音频守卫 + FR-C2 相机 provider 大核亲和。
# v1.12.2: FR-C3 face-service Flush Sentinel——face-service 借相机身份在拥堵窗口快速开关相机
#   ID 4 时，provider 在 CamX::flush 等结果超时触发内部 raise 取证 dump（10-16 四连发取证）。
#   检测：face-service 存活 + provider 任意 tid 处于 D 状态 → 临时给两端逐线程 renice -8，
#   退出 30s 冷却。与 FR-C2 互补（FR-C2 护相机 App 前台，FR-C3 护 face 服务借相机）。
# v1.12.5: FR-BT2 低成本蓝牙 GATT/LE 在系统内存压力下的护栈哨兵（RayNeo 观察期）。
. "$(dirname "$0")/mt_lib.sh"
echo $$ > "$RUN/fluencyshield.pid"
logx E "event=fluency_shield_start ver=1.12.5 msg=FR-9+CameraSentinel+ScreenshotSentinel+BTSentinel+FR-C3FlushSentinel已开启"

flush_state=0
flush_ts=0
flush_cooldown_until=0
FLUSH_COOLDOWN=30
FR_C3_MAX=15
is_boosting=0
shield_cooldown_until=0   # Fix-E: 护盾冷却截止时间戳
cam_state=0               # Camera Sentinel 状态机：0=无相机 1=相机活跃

# FR-BT (v1.12.0): BT Sentinel 状态机
bt_state=0                # 0=未护航 1=护航中
bt_miss=0                 # 条件消失计数（连续 3 tick 才还原，防抖）
bt_last_jf=0              # 上次采样 CPU jiffies（首 tick 只建基线）
bt_last_pid=""            # 上次 BT 栈 pid（变化才重扫 HAL）
bt_hal_pid=""             # 缓存的 BT HAL pid（避免每 tick 全盘扫 cmdline）
bt_cooldown_until=0       # 还原后 30s 冷却

# v1.12.0: HZ 归一化——jiffies 增量阈值必须除以真实时钟频率（内核 CONFIG_HZ 100/250 皆可能）
bt_clk=$(getconf CLK_TCK 2>/dev/null)
case "$bt_clk" in ''|*[!0-9]*) bt_clk=100;; esac
if [ "$bt_clk" -lt 1 ] 2>/dev/null; then bt_clk=100; fi
bt_last_ts=0              # 上次采样 uptime 秒（归一化分母）

# 启动自愈：上一实例死于提权中残留的 bak → 先无损还原
# （若相机/蓝牙音频此刻正活跃，本轮循环会立刻检测到并重新提权，语义无损）
camera_vip_off 2>/dev/null
camera_affinity_off 2>/dev/null
bt_guard_restore 2>/dev/null
flush_guard_restore 2>/dev/null

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
    camera_affinity_on   # v1.12.0 FR-C2: provider 逐线程绑大核簇 cpu3-7（退出还原）
    logx A "act=camera_sentinel_on msg=相机已激活_HAL服务已提权"

  elif [ "$cam_now" -eq 0 ] && [ "$cam_state" -eq 1 ]; then
    # ── 相机已退出前台 ────────────────────────────────────
    cam_state=0
    rm -f "$CAMERA_ACTIVE_FLAG" 2>/dev/null
    camera_vip_off
    camera_affinity_off   # v1.12.0 FR-C2: 逐 tid 还原原始核亲和 mask
    logx A "act=camera_sentinel_off msg=相机已退出前台_HAL服务优先级已还原"
  fi

  # =========================================================
  # FR-BT BT Sentinel (v1.12.0)
  # 检测：com.android.bluetooth 的单核 CPU 占比（jiffies 增量按 uptime 时间差与
  #   CLK_TCK 归一化）> 5% 判音频流活跃（A2DP 编码/HFP）；首 tick 只建基线。
  # 触发：音频流活跃 且（相机活跃 或 PSI some ≥ 8%）→ 逐线程提权 -8。
  # 还原：条件连续消失 3 tick（~15s）→ 差分还原 + 30s 冷却防抖。
  # 重启：护航中 BT 栈重启（pid 变化）→ 立即重新护航（消除新进程裸奔窗口）。
  # 功耗纪律：完全搭既有 5s 循环便车（零新增唤醒）；每 tick 仅 1 次 pidof fork，
  #   stat/PSI/uptime 读取全部 mksh 内建 read（零 fork）。
  # =========================================================
  bt_now_cond=0
  _btp=$(pidof com.android.bluetooth 2>/dev/null)
  _btp=${_btp%% *}
  case "$_btp" in ''|*[!0-9]*) _btp="";; esac
  if [ -n "$_btp" ]; then
    if [ "$_btp" != "$bt_last_pid" ]; then
      # BT 栈重启（pid 变化）：失效 HAL 缓存并重扫；jiffies/时间基线重建
      bt_last_pid=$_btp; bt_hal_pid=""; bt_last_jf=0; bt_last_ts=0
      for d in /proc/[0-9]*; do
        _bth_cmd=$(strings "$d/cmdline" 2>/dev/null | head -n 1)
        case "$_bth_cmd" in android.hardware.bluetooth@*) bt_hal_pid=${d##*/}; break;; esac
      done
      # 护航中栈重启 → 立即重新护航（旧 bak 内 tid 已死，boost 内部截断 bak 无损）
      if [ "$bt_state" -eq 1 ]; then
        _as=$(pidof audioserver 2>/dev/null); _as=${_as%% *}
        bt_guard_boost "$_btp" "$bt_hal_pid" "$_as"
      fi
    fi
    bt_stack_cpu "$_btp"
    read -r _up _ < /proc/uptime 2>/dev/null
    _up=${_up%%.*}
    case "$_up" in ''|*[!0-9]*) _up=$bt_last_ts;; esac
    bt_stream=0
    if [ -n "$BT_JF" ] && [ "$bt_last_jf" -gt 0 ] && [ "$_up" -gt "$bt_last_ts" ]; then
      # 阈值 = 时间差 × CLK_TCK × 3%（单核占比；SBC 编码可低至 3-4%，5% 会漏检；
      # 误检良性——触发还需叠加相机/PSI 条件）；系统卡顿拉长 tick 时自动等比放大
      _thr=$(( (_up - bt_last_ts) * bt_clk * 3 / 100 ))
      [ $((BT_JF - bt_last_jf)) -gt "$_thr" ] && bt_stream=1
    fi
    bt_last_jf=${BT_JF:-$bt_last_jf}
    bt_last_ts=$_up
    if [ "$bt_stream" -eq 1 ]; then
      # PSI some avg10（mksh read 零 fork）：15.52% → psi_int=1552（阈值 800 = 8%）
      IFS=' ' read -r _ps1 _ps2 _ < /proc/pressure/memory 2>/dev/null
      _psi_x=${_ps2#avg10=}
      _psi_i=${_psi_x%%.*}; _psi_f=${_psi_x#*.}
      case "${_psi_i:-}${_psi_f:-}" in ''|*[!0-9]*) _psi_i=0; _psi_f=0;; esac
      psi_int=$((_psi_i * 100 + _psi_f))
      if [ "$cam_state" -eq 1 ] || [ "$psi_int" -ge 800 ]; then
        bt_now_cond=1
      fi
    fi
  else
    # BT 栈不存在（蓝牙关闭/重启窗口）：清缓存与基线
    bt_last_pid=""; bt_hal_pid=""; bt_last_jf=0; bt_last_ts=0
  fi

  if [ "$bt_now_cond" -eq 1 ]; then
    bt_miss=0
    if [ "$bt_state" -eq 0 ] && [ "$(date +%s)" -ge "$bt_cooldown_until" ]; then
      bt_state=1
      _as=$(pidof audioserver 2>/dev/null); _as=${_as%% *}
      bt_guard_boost "$_btp" "$bt_hal_pid" "$_as"
    fi
  else
    if [ "$bt_state" -eq 1 ]; then
      bt_miss=$((bt_miss + 1))
      if [ "$bt_miss" -ge 3 ]; then
        bt_state=0; bt_miss=0
        bt_guard_restore
        bt_cooldown_until=$(($(date +%s) + 30))
      fi
    fi
  fi

  # =========================================================
  # FR-C3 + FR-BT2 probe tick (v1.12.5)
  # Tick 0（每 20 秒）: 查询 face-service/provider 与 RayNeo 前台服务频次。
  # FR-C3 判定: face-service 存活 + provider 任意线程 D 状态 → 临时提权。
  # FR-BT2 判定: RayNeo 应用存活 + mem PSI some avg10 ≥5 → 临时提权。
  # FR-BT2 (v1.12.5)：RayNeo GATT/LE 场景下的低成本蓝牙栈护航。
  # 触发：RayNeo 前台服务在最近 100 条系统日志里重复启动 ≥2 次 + mem PSI some avg10 ≥5。
  # 还原：PSI some avg10 < 3% 连续 2 tick，或者 BT 栈/HAL 消失。
  # =========================================================
  bt2_now_cond=0
  _frc3_tick=$((_frc3_tick + 1))
  if [ "$_frc3_tick" -ge 4 ]; then
    _frc3_tick=0
    _frc3_face_str=$(find_face_service_pid 2>/dev/null)
    _frc3_face=${_frc3_face_str%% *}
    # Find the provider only when face-service is actually alive.  The old
    # per-tick /proc walk broke the "zero fork" discipline every 5 seconds.
    if [ -n "$_frc3_face" ]; then
      _frc3_prov=$(find_camera_provider 2>/dev/null)
    fi
    bt2_probe_rayneo
  fi
  # FR-C3 state machine: refresh the probe every 20s, but run restore checks
  # each tick so a lingering boost cannot outlive the 15s ceiling.
  _frc3_now=0
  if [ -n "$_frc3_face" ] && [ -n "$_frc3_prov" ]; then
    for _frc3_t in /proc/$_frc3_prov/task/*/stat; do
      _frc3_state=$(awk '{sub(/^[0-9]+ \([^)]*\) /,""); print $1}' "$_frc3_t" 2>/dev/null)
      [ "$_frc3_state" = "D" ] && { _frc3_now=1; break; }
    done
  fi
  if [ "$_frc3_now" -eq 1 ] && [ "$flush_state" -eq 0 ] && [ "$(date +%s)" -ge "$flush_cooldown_until" ]; then
    flush_state=1
    flush_ts=$(date +%s)
    flush_guard_boost "$_frc3_face" "$_frc3_prov"
  elif [ "$flush_state" -eq 1 ]; then
    _frc3_t2=$(date +%s)
    if [ "$_frc3_now" -eq 0 ] || [ $((_frc3_t2 - flush_ts)) -ge "$FR_C3_MAX" ]; then
      flush_state=0
      flush_guard_restore
      flush_cooldown_until=$((_frc3_t2 + FLUSH_COOLDOWN))
    fi
  fi
  if bt2_should_boost; then
    bt2_now_cond=1
  fi
  if [ "$bt2_now_cond" -eq 1 ]; then
    bt2_miss=0
    if [ "$bt2_state" -eq 0 ]; then
      bt2_state=1
      _btp2=$(pidof com.android.bluetooth 2>/dev/null); _btp2=${_btp2%% *}
      _bth2=""
      [ -n "$_btp2" ] && { _btp2=${_btp2%% *}; }
      [ -n "$_btp2" ] || _btp2=""
      _ash2=$(pidof audioserver 2>/dev/null); _ash2=${_ash2%% *}
      if [ -n "$_btp2" ]; then
        for d in /proc/[0-9]*; do
          _bth2_cmd=$(strings "$d/cmdline" 2>/dev/null | head -n 1)
          case "$_bth2_cmd" in android.hardware.bluetooth@*) _bth2=${d##*/}; break;; esac
        done
      fi
      if [ -n "$_btp2" ]; then
        bt_guard_boost "$_btp2" "$_bth2" "$_ash2"
        logx A "act=bt2_guard_on trigger=rayneo_gatt psi_mem=$bt2_psi msg=LE/GATT压力护航"
      fi
    fi
  else
    if [ "$bt2_state" -eq 1 ]; then
      bt2_miss=$((bt2_miss + 1))
      if [ "$bt2_miss" -ge 2 ]; then
        bt2_state=0; bt2_miss=0
        bt_guard_restore
        bt2_cooldown_until=$(($(date +%s) + 30))
        logx A "act=bt2_guard_off psi_mem=$bt2_psi msg=压力回落_蓝牙栈还原"
      fi
    fi
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
