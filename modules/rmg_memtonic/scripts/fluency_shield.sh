#!/system/bin/sh
# fluency_shield.sh —— RMG MemTonic 前台护盾 (FR-9) + Camera Sentinel + Screenshot Sentinel + BT Sentinel + FR-C3 Flush Sentinel (v1.13.18)
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
# v1.12.9: 高CPU退避——cpu PSI some ≥35% 时抑制 FR-BT/FR-BT2 新增提权（活跃护航照常还原），
#   防干预风暴在高CPU饱和窗口叠加 fork 负载饿死 GC（10-22 system_server OOM 498MB 教训）；
#   FR-C3 不退避（cpu≥35 本就是其正向触发条件之一）。FR-BT2 还原冷却 30s→90s。
# v1.13.0: FR-C3 风暴态——1h 窗口借相机 ≥6 次进入护航维持模式（首提权后不再反复
#   提权-还原，风暴解除或 30min 硬顶一次性还原；10-26 早高峰 20+ 次护航 churn 实证）；
#   深夜(00-06)借相机命中 A 级日志（两次 OOM 均有深夜借相机前科）；BT3 窗口 3000 行
#   + 90s 冷却（修 10-23 致盲机制）。
# v1.13.1: FR-BT3 断联检测双通道——新增 RayNeo 应用 pid 换代通道（16:05 实战：应用
#   被压死重启是断联可靠前奏，One UI 16 的 ACL 广播不可依赖降为辅助）。
# v1.13.2: 耗电治理（10-27 实测 fluency 日均 CPU 7.9h=50% 单核，用户感知耗电异常）：
#   ① tick 时间合并——循环顶部一次 date，全循环复用（原 6 次 date fork ≈120ms/tick）
#   ② focused_pkg(dumpsys window ~40ms) 降频 5s→10s（相机激活/退出判定延迟 ≤10s）
#   ③ bt3 logcat 通道降频 5s→20s（pid 换代通道仍在 5s 层兜底；20s 采样 < 60s 窗口不盲）
#   ④ bt1/bt2/bt3 触发段复用同一次 com.android.bluetooth pidof
#   目标：tick CPU ~400ms→~120ms，风暴期放大同比例收敛。
# v1.13.3: 部署后实测 v1.13.2 仍有 ~64% 单核——剖析修正锁定真凶：
#   ① find_camera_provider 缓存化（原每 20s 全盘 /proc 扫描 ~900 进程 × strings+head
#     ≈2.2s CPU = 均摊 ~560ms/tick，最大单项）② FR-C3 D 状态扫描改单次 awk（66 fork→1）
#   ③ FR-9/FR-C3 的 4 次 psi_val awk 改 mksh read 零 fork（PSI 口径统一为百分整数
#     0-10000，高CPU退避/FR-C3 触发阈值同步换算 35→3500、10→1000）。
. "$(dirname "$0")/mt_lib.sh"
echo $$ > "$RUN/fluencyshield.pid"
logx E "event=fluency_shield_start ver=1.13.18 msg=FR-9+CameraSentinel+ScreenshotSentinel+BTSentinel+FR-C3FlushSentinel+FR-BT3双通道+FR-C3风暴态+BT2风暴态+批量提权引擎+耗电治理V2+通知推送+死亡间隙修复+GC加速+内存余量预测+核亲和约束+RayNeo治理"

flush_state=0
flush_ts=0
flush_cooldown_until=0
FLUSH_COOLDOWN=30
FR_C3_MAX=15
frc3_cnt_anchor=0         # v1.13.0: 借相机频次窗口锚点（1h 滑动计数）
frc3_cnt=0                # v1.13.0: 窗口内命中次数
frc3_storm=0              # v1.13.0: 风暴态（1=护航维持模式，还原由风暴解除触发）
frc3_storm_until=0        # v1.13.0: 风暴态保持截止（进入时 +1800s）
frc3_hold_ts=0            # v1.13.0: 风暴态护航开始时刻（30min 硬顶基准）
bt2_storm=0               # v1.13.5: BT2 风暴态（1=维持护航不反复 boost/restore churn）
bt2_storm_until=0         # v1.13.5: BT2 风暴态保持截止（进入时 +1800s）
bt2_storm_hold_ts=0       # v1.13.5: BT2 风暴态护航开始时刻（30min 硬顶基准）
bt2_storm_cnt=0           # v1.13.5: BT2 1h 窗口触发计数
bt2_storm_win_ts=0        # v1.13.5: BT2 1h 窗口起点
is_boosting=0
_frc3_cpu=0               # v1.12.9: cpu PSI some 整数%（每 tick 刷新于 FR-C3 探测段；首 tick 兜底 0）
_frc3_mem=0               # v1.12.9: mem PSI some 整数%（同上）
shield_cooldown_until=0   # Fix-E: 护盾冷却截止时间戳
cam_state=0               # Camera Sentinel 状态机：0=无相机 1=相机活跃
bt3_state=0               # FR-BT3 状态机：0=空闲 1=护航中
bt3_ts=0                  # FR-BT3 护航开始时间
bt3_cooldown_until=0      # v1.13.0: 护航结束后 90s 冷却（3000 行窗口下防同一断连广播重复触发）
_rn_pid=""                # v1.13.1: RayNeo 应用 pid 基线（换代=断联前奏通道；空=未建基线）
_rn_seen=0                # v1.13.7: RayNeo 存活标志（1=本会话内见过存活——死亡>5s 后复活也触发护航）
_tick_ts=0                # v1.13.2: 本 tick 时间戳（循环顶一次 date，全循环复用）
_cam_tick=0               # v1.13.2: 相机采样计数（每 2 tick = 10s 采样一次前台焦点）
bt3_tick=0                # v1.13.2: bt3 logcat 采样计数（每 4 tick = 20s 评估一次广播通道）

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
bt2_guard_restore 2>/dev/null
flush_guard_restore 2>/dev/null

# FR-S: 截屏目录初始化（尝试多个常见路径）
sc_dir=""
for _d in "/sdcard/DCIM/Screenshots" "/sdcard/Pictures/Screenshots" "/storage/emulated/0/DCIM/Screenshots"; do
  [ -d "$_d" ] && { sc_dir="$_d"; break; }
done
sc_prev_count=0
[ -n "$sc_dir" ] && sc_prev_count=$(ls "$sc_dir" 2>/dev/null | wc -l)

shield_fg_restore   # v1.13.19: 启动自愈——还原上一轮护盾遗留的 -15 提权

while true; do
  sleep 5
  _tick_ts=$(date +%s)   # v1.13.2: 每 tick 一次时间获取（原循环内 6 次 date fork）

  # v1.13.19: 息屏空闲判定（零 fork）——息屏且蓝牙/相机/截屏均空闲时，跳过 10s 焦点
  # 采样与截屏目录扫描。亮度文件缺失/不可读按"亮屏"处理（失败安全：只多耗电，不漏检）。
  _idle_screen=0
  if [ "$bt_state" -eq 0 ] && [ "$bt2_state" -eq 0 ] && [ "$bt3_state" -eq 0 ] && [ "$flush_state" -eq 0 ]; then
    _bl_v=1
    if [ -r /sys/class/backlight/panel0-backlight/brightness ]; then
      IFS= read -r _bl_v < /sys/class/backlight/panel0-backlight/brightness 2>/dev/null
      case "$_bl_v" in ''|*[!0-9]*) _bl_v=1;; esac
    fi
    [ "$_bl_v" -eq 0 ] && _idle_screen=1
  fi

  # =========================================================
  # FR-C Camera Sentinel
  # v1.9.7: 废除 dumpsys media.camera 探针（19,038 行 / 521ms 持锁掉帧根因）→ pidof 探测
  # v1.9.10: pidof 改为前台焦点判定——实测相机退到后台后进程不死，
  #   pidof 仍返回 PID → camera_sentinel_off 永不触发 → VIP 提权永不还原（泄漏）。
  #   改为 focused_pkg == 相机包名 才算活跃，退出前台立即触发还原。
  # v1.13.2: focused_pkg(dumpsys window ~40ms) 降频至每 2 tick=10s——非采样 tick 沿用
  #   上一状态；相机激活/退出判定延迟 ≤10s（相机启动到可拍摄 >2s，可接受）。
  # =========================================================
  _cam_tick=$((_cam_tick + 1))
  if [ "$_idle_screen" -eq 1 ]; then
    cam_now=$cam_state      # v1.13.19: 息屏时相机不可能在前台，沿用上一状态不采样
  elif [ $((_cam_tick % 2)) -eq 1 ]; then
    cam_now=0
    _cam_focus=$(focused_pkg)
    case "$_cam_focus" in
      com.sec.android.app.camera|com.sec.android.gallery3d) cam_now=1 ;;
    esac
  else
    cam_now=$cam_state
  fi

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
        # v1.12.9 高CPU退避: cpu PSI some ≥35% 时不新增 BT 护航（防干预风暴饿死 GC）
        # v1.13.2: _frc3_cpu 口径为百分整数（35%=3500）
        [ "$_frc3_cpu" -lt 3500 ] && bt_now_cond=1
      fi
    fi
  else
    # BT 栈不存在（蓝牙关闭/重启窗口）：清缓存与基线
    bt_last_pid=""; bt_hal_pid=""; bt_last_jf=0; bt_last_ts=0
  fi

  if [ "$bt_now_cond" -eq 1 ]; then
    bt_miss=0
    if [ "$bt_state" -eq 0 ] && [ "$_tick_ts" -ge "$bt_cooldown_until" ]; then
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
        bt_cooldown_until=$((_tick_ts + 30))
      fi
    fi
  fi

  # =========================================================
  # FR-BT3 (v1.12.8): RayNeo BR/EDR 主动断连后的 LE 重连护航
  # 检测（v1.13.1 双通道，任一命中即触发）：
  #   ① 应用 pid 换代——RayNeo 应用死亡重启是断联的可靠前奏（16:05 实战铁证：
  #     换页风暴压死应用 26856→14948 → 伴随连接断开 → BLE 重扫）。pidof 每 tick
  #     刷新基线（+1 fork），换代即触发；logcat 通道仅在无换代时评估（短路省 3 fork）。
  #   ② ACL_DISCONNECTED 广播 + RayNeo 别名（logcat 3000 行窗口，v1.13.0）——
  #     One UI 16 实测该广播不总在 main buffer（16:09 断联窗口无广播行），降为辅助通道。
  #     v1.13.2: 辅助通道降频至每 4 tick=20s（bt3 实测 ~80ms/次；pid 换代通道仍在
  #     5s 层兜底，20s 采样周期 < 3000 行≈60s 窗口不致盲）。
  # 行为：立即给 BT 栈/HAL/audioserver 提权 25 秒，保护 LE 直连重连窗口。
  # 边界：应用更新/用户强杀等无断联场景误触发 = 25s 无害护航；结束 90s 冷却。
  # =========================================================
  bt3_tick=$((bt3_tick + 1))
  _rn_trig=""
  _rn_new=$(pidof com.rayneo.venus.pub 2>/dev/null); _rn_new=${_rn_new%% *}
  case "$_rn_new" in ''|*[!0-9]*) _rn_new="";; esac
  if [ "$bt3_state" -eq 0 ] && [ "$_tick_ts" -ge "$bt3_cooldown_until" ]; then
    # v1.13.7 (R2): 死亡间隙盲区修复——旧条件要求新旧 pid 双非空，app 死亡>5s（崩溃
    # 重启典型时长）时基线被清、复活漏检（10-30 实证：RayNeo 25279→5628 换代 0 触发）。
    # 改用 _rn_seen 常驻标志：见过→复活即触发不限间隙；死亡滞留不误触发（_rn_new 空）。
    if [ -n "$_rn_new" ] && [ "$_rn_seen" -eq 1 ] && [ "$_rn_new" != "$_rn_pid" ]; then
      _rn_trig=app_restart
    elif [ $((bt3_tick % 4)) -eq 0 ] && bt3_disconnect_seen; then
      _rn_trig=acl_broadcast
    fi
  fi
  [ -n "$_rn_new" ] && _rn_seen=1
  _rn_pid=$_rn_new
  if [ -n "$_rn_trig" ]; then
    bt3_state=1
    bt3_ts=$_tick_ts
    _btp3=$_btp
    _bth3=""
    if [ -n "$_btp3" ]; then
      for d in /proc/[0-9]*; do
        _bth3_cmd=$(strings "$d/cmdline" 2>/dev/null | head -n 1)
        case "$_bth3_cmd" in android.hardware.bluetooth@*) _bth3=${d##*/}; break;; esac
      done
    fi
    _ash3=$(pidof audioserver 2>/dev/null); _ash3=${_ash3%% *}
    if [ -n "$_btp3" ]; then
      bt2_guard_boost "$_btp3" "$_bth3" "$_ash3"
      logx A "act=bt3_guard_on trigger=$_rn_trig msg=雷鸟断连后LE重连护航"
    fi
  fi
  if [ "$bt3_state" -eq 1 ]; then
    _b3t=$_tick_ts
    if [ $((_b3t - bt3_ts)) -ge 25 ]; then
      bt3_state=0
      bt3_cooldown_until=$((_b3t + 90))
      bt2_guard_restore
      logx A "act=bt3_guard_off msg=LE重连护航窗口结束_已还原"
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
  # v1.13.2: D 状态扫描改单次 awk 读全部 task stat（原 66 tid × 66 awk fork/20s）。
  _frc3_now=0
  if [ -n "$_frc3_face" ] && [ -n "$_frc3_prov" ]; then
    if awk 'BEGIN{found=0} FNR==1{ln=$0; sub(/^[0-9]+ \([^)]*\) /,"",ln); split(ln,f," "); if(f[1]=="D"){found=1; exit}} END{if(found)exit 0; exit 1}' /proc/$_frc3_prov/task/*/stat 2>/dev/null; then
      _frc3_now=1
    fi
  fi
  # v1.13.2 耗电治理: PSI 改 mksh read 零 fork 直读（原 2 次 psi_val awk fork），
  # 解析口径与 FR-BT 段一致（小数两位 → 百分整数）。
  IFS=' ' read -r _c1 _c2 _ < /proc/pressure/cpu 2>/dev/null
  _cx=${_c2#avg10=}; _ci=${_cx%%.*}
  case "$_cx" in *.*) _cf=${_cx#*.};; *) _cf=0;; esac
  case "${_ci:-}${_cf:-}" in ''|*[!0-9]*) _ci=0; _cf=0;; esac
  _frc3_cpu=$((_ci * 100 + _cf))
  IFS=' ' read -r _m1 _m2 _ < /proc/pressure/memory 2>/dev/null
  _mx=${_m2#avg10=}; _mi=${_mx%%.*}
  case "$_mx" in *.*) _mf=${_mx#*.};; *) _mf=0;; esac
  case "${_mi:-}${_mf:-}" in ''|*[!0-9]*) _mi=0; _mf=0;; esac
  _frc3_mem=$((_mi * 100 + _mf))
  # v1.13.0: 触发判定抽为 _frc3_trig（风暴态还原判定复用，不再重复长表达式）
  _frc3_trig=0
  if [ "$_frc3_now" -eq 1 ]; then
    _frc3_trig=1
  elif [ -n "$_frc3_face" ] && [ -n "$_frc3_prov" ] && { [ "$_frc3_cpu" -ge 3500 ] || [ "$_frc3_mem" -ge 1000 ]; }; then
    _frc3_trig=1
  fi
  _frc3_tnow=$_tick_ts
  if [ "$_frc3_trig" -eq 1 ] && [ "$flush_state" -eq 0 ] && [ "$_frc3_tnow" -ge "$flush_cooldown_until" ]; then
    flush_state=1
    flush_ts=$_frc3_tnow
    flush_guard_boost "$_frc3_face" "$_frc3_prov"
    # v1.13.0: 借相机频次窗口（1h 滑动）与深夜异常信号
    if [ $((_frc3_tnow - frc3_cnt_anchor)) -gt 3600 ]; then
      frc3_cnt_anchor=$_frc3_tnow
      frc3_cnt=0
    fi
    frc3_cnt=$((frc3_cnt + 1))
    _frc3_hr=$(( ( _frc3_tnow / 3600 + 8 ) % 24 ))
    [ "$_frc3_hr" -le 6 ] && logx A "act=frc3_night_hit hour=$_frc3_hr cnt=$frc3_cnt msg=深夜借相机_异常信号_堆探测已加密"
    # v1.13.0: 1h 内 ≥6 次进入风暴态——护航维持模式（消除提权-还原 churn）
    if [ "$frc3_storm" -eq 0 ] && [ "$frc3_cnt" -ge 6 ]; then
      frc3_storm=1
      frc3_storm_until=$((_frc3_tnow + 1800))
      frc3_hold_ts=$_frc3_tnow
      logx A "act=frc3_storm_on cnt=$frc3_cnt msg=借相机高频_护航维持模式_还原改由风暴解除触发"
    fi
  elif [ "$flush_state" -eq 1 ]; then
    if [ "$frc3_storm" -eq 1 ]; then
      # v1.13.0: 风暴态维持——仅"风暴过期 且 本 tick 触发条件已消失"或 30min 硬顶时还原
      if { [ "$_frc3_tnow" -ge "$frc3_storm_until" ] && [ "$_frc3_trig" -eq 0 ]; } || [ $((_frc3_tnow - frc3_hold_ts)) -ge 1800 ]; then
        frc3_storm=0
        flush_state=0
        flush_guard_restore
        flush_cooldown_until=$((_frc3_tnow + 60))
        logx A "act=frc3_storm_off msg=借相机风暴解除_护航一次性无损还原"
      fi
    else
      if [ "$_frc3_now" -eq 0 ] || [ $((_frc3_tnow - flush_ts)) -ge "$FR_C3_MAX" ]; then
        flush_state=0
        flush_guard_restore
        flush_cooldown_until=$((_frc3_tnow + FLUSH_COOLDOWN))
      fi
    fi
  fi
  # v1.12.9 高CPU退避: cpu PSI some ≥35% 时抑制 BT2 新护航（bt2_should_boost 内部防抖
  # 状态照常推进；活跃护航走 else 分支照常还原）。v1.13.2: 口径百分整数（35%=3500）。
  if bt2_should_boost && [ "$_frc3_cpu" -lt 3500 ]; then
    bt2_now_cond=1
  fi
  if [ "$bt2_now_cond" -eq 1 ]; then
    bt2_miss=0
    if [ "$bt2_state" -eq 0 ]; then
      bt2_state=1
      _btp2=$_btp
      _bth2=""
      _ash2=$(pidof audioserver 2>/dev/null); _ash2=${_ash2%% *}
      if [ -n "$_btp2" ]; then
        for d in /proc/[0-9]*; do
          _bth2_cmd=$(strings "$d/cmdline" 2>/dev/null | head -n 1)
          case "$_bth2_cmd" in android.hardware.bluetooth@*) _bth2=${d##*/}; break;; esac
        done
      fi
      if [ -n "$_btp2" ]; then
        bt2_guard_boost "$_btp2" "$_bth2" "$_ash2"
        logx A "act=bt2_guard_on trigger=rayneo_gatt psi_mem=$bt2_psi msg=LE/GATT压力护航"
        # v1.13.5 (I1): BT2 风暴态——1h 窗口 ≥4 次触发进入维持模式（治 churn：昨晚
        # 18:50-23:25 每 40 分钟一轮 boost/restore 实测，维持后变 0 轮/小时）
        if [ $((_tick_ts - bt2_storm_win_ts)) -ge 3600 ]; then bt2_storm_win_ts=$_tick_ts; bt2_storm_cnt=1; else bt2_storm_cnt=$((bt2_storm_cnt + 1)); fi
        if [ "$bt2_storm" -eq 0 ] && [ "$bt2_storm_cnt" -ge 4 ]; then
          bt2_storm=1; bt2_storm_until=$((_tick_ts + 1800)); bt2_storm_hold_ts=$_tick_ts
          logx A "act=bt2_storm_on cnt=$bt2_storm_cnt msg=BT2高频churn_维持护航模式_还原改由风暴解除触发"
        fi
      fi
    fi
  else
    if [ "$bt2_state" -eq 1 ]; then
      bt2_miss=$((bt2_miss + 1))
      if [ "$bt2_miss" -ge 2 ]; then
        if [ "$bt2_storm" -eq 1 ]; then
          # v1.13.5 (I1): 风暴态维持——仅"风暴过期 且 本 tick 触发条件已消失"或 30min 硬顶时还原
          if { [ "$_tick_ts" -ge "$bt2_storm_until" ] && [ "$bt2_now_cond" -eq 0 ]; } || [ $((_tick_ts - bt2_storm_hold_ts)) -ge 1800 ]; then
            bt2_storm=0; bt2_state=0; bt2_miss=0
            bt2_guard_restore
            bt2_cooldown_until=$((_tick_ts + 90))
            logx A "act=bt2_storm_off msg=蓝牙风暴解除_护航一次性无损还原"
          fi
        else
          bt2_state=0; bt2_miss=0
          bt2_guard_restore
          bt2_cooldown_until=$((_tick_ts + 90))
          logx A "act=bt2_guard_off psi_mem=$bt2_psi msg=压力回落_蓝牙栈还原"
        fi
      fi
    fi
  fi
  # =========================================================
  # FR-S Screenshot Sentinel
  # 通过文件数变化检测新截屏，O(1)，无 dumpsys/pgrep 开销
  # =========================================================
  if [ -n "$sc_dir" ] && [ "$_idle_screen" -eq 0 ]; then
    sc_cur_count=$(ls "$sc_dir" 2>/dev/null | wc -l)
    if [ "$sc_cur_count" -gt "$sc_prev_count" ]; then
      # 新截屏检测到
      sc_prev_count=$sc_cur_count
      touch "$SCREENSHOT_ACTIVE_FLAG" 2>/dev/null
      echo $((_tick_ts + 30)) > "$SCREENSHOT_END_TS" 2>/dev/null
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
      if [ "$_tick_ts" -ge "$_sc_end" ]; then
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
  _now_s=$_tick_ts
  if [ "$_now_s" -lt "$shield_cooldown_until" ]; then
    continue
  fi

  # v1.13.2 耗电治理: PSI 零 fork 直读（原 psi_val×2 + awk×2 = 4 fork/tick），
  # 整数百分口径与 FR-C3 段一致。注意 _frc3_cpu 语义变化：v1.13.2 起为百分整数
  # （0-10000），高CPU退避阈值 35 对应 3500。
  IFS=' ' read -r _m1 _m2 _ < /proc/pressure/memory 2>/dev/null
  _mx=${_m2#avg10=}; _mi=${_mx%%.*}
  case "$_mx" in *.*) _mf=${_mx#*.};; *) _mf=0;; esac
  case "${_mi:-}${_mf:-}" in ''|*[!0-9]*) _mi=0; _mf=0;; esac
  psi_int=$((_mi * 100 + _mf))
  IFS=' ' read -r _c1 _c2 _ < /proc/pressure/cpu 2>/dev/null
  _cx=${_c2#avg10=}; _ci=${_cx%%.*}
  case "$_cx" in *.*) _cf=${_cx#*.};; *) _cf=0;; esac
  case "${_ci:-}${_cf:-}" in ''|*[!0-9]*) _ci=0; _cf=0;; esac
  cpu_psi_int=$((_ci * 100 + _cf))

  if { [ "$psi_int" -ge 1500 ] || [ "$cpu_psi_int" -ge 2500 ]; } && [ "$is_boosting" -eq 0 ]; then
    is_boosting=1

    # 1. 前台焦点 App 包名：v1.13.15 (A-4) 复用循环内每 10s 的 focused_pkg 采样结果，
    #    不再单独 dumpsys window——该调用平时 ~40ms，高压时恶化到数百 ms，而护盾触发
    #    恰在高压时刻（37h 内 821 次重复调用是纯浪费）。采样最多滞后 10s，可接受。
    fg_pkg=$_cam_focus
    [ -n "$fg_pkg" ] || fg_pkg=$(dumpsys window 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp' \
      | grep -Eo '[a-zA-Z0-9_.]+/[a-zA-Z0-9_.]+' | head -n 1 | cut -d/ -f1)

    sf_pid=$(pidof surfaceflinger)
    sf_orig=""; fg_pid=""; fg_orig=""; rt_tid=""; rt_orig=""

    # 2. 备份并提权 SurfaceFlinger
    if [ -n "$sf_pid" ]; then
      sf_orig=$(nice_of "$sf_pid")
      case "$sf_orig" in ''|*[!0-9-]*) sf_orig=0;; esac
      # v1.13.19: renice -n 是增量语义（见下方 Fix-B 注释）。原 `renice -n -15` 会在
      # 已提权过的 SF 上继续累加（实测 -10 → -25），且缺"防反向降级"守卫。
      # 改为增量补齐到 -15，且仅当当前优先级高于 -15 时执行。
      if [ "$sf_orig" -gt -15 ]; then
        renice -n $((-15 - sf_orig)) -p "$sf_pid" >/dev/null 2>&1
      fi
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
        logx W "event=shield_activate psi_int=$psi_int cpu_psi_int=$cpu_psi_int pkg=$fg_pkg pid=$fg_pid msg=系统拥堵_精准护航主线程与渲染线程"
      fi
    else
      logx W "event=shield_activate psi_int=$psi_int cpu_psi_int=$cpu_psi_int pkg=unknown msg=系统拥堵_仅护航系统渲染层"
    fi

    # v1.13.19: 护盾提权持久化——sleep 15 期间若被 kill -9 / 卸载 / 崩溃，内存态变量
    # 全丢，SF 与前台主线程会永久停在 -15（nice 只提不降，越积越高）。落盘供
    # cpu_guard 启动自愈、stop、uninstall 统一还原。
    : > "$RUN/shield_fg.bak" 2>/dev/null
    if [ -n "$sf_pid" ] && [ -n "$sf_orig" ]; then echo "sf $sf_pid $sf_orig" >> "$RUN/shield_fg.bak" 2>/dev/null; fi
    if [ -n "$fg_pid" ] && [ -n "$fg_orig" ]; then echo "fg $fg_pid $fg_orig" >> "$RUN/shield_fg.bak" 2>/dev/null; fi
    if [ -n "$rt_tid" ] && [ -n "$rt_orig" ]; then echo "rt $rt_tid $rt_orig" >> "$RUN/shield_fg.bak" 2>/dev/null; fi

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
    rm -f "$RUN/shield_fg.bak" 2>/dev/null   # v1.13.19: 还原完成，清持久化记录


    is_boosting=0
    # Fix-E: 护盾退出后冷却防抖（v1.9.7: 5s→60s，降低高 PSI 持续期的反复提权-还原震荡）
    shield_cooldown_until=$((_tick_ts + 60))
  fi
done
