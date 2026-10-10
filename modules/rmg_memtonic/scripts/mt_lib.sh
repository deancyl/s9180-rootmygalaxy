#!/system/bin/sh
# mt_lib.sh —— RMG MemTonic 公共库（v1.10.0 - 内存风暴监测/快照/亮屏风暴级压实）
# v1.10.0: 新增内存风暴三件套（供 cpu_guard 60s 轮挂载，零新增唤醒）：
#   1. psi_mem_read —— mksh 内建 read 读 /proc/pressure/memory（无 fork，实测 fork 版 9.35ms/次 → 内建 <0.5ms）；
#   2. fg_majflt_sum —— 单次 awk 汇总 top-app 全部 pid 的 majflt（P2 重负载指纹）；
#   3. mem_blackbox —— 灾难快照落盘（PSI+meminfo+RSS/majflt Top10，触发式，稀有事件）。
#   亮屏压实走"风暴级例外"：常规亮屏 GEMINI.md 铁律禁压不变，仅 psi_mem some≥30 例外，
#   相机/截屏守卫无条件生效。
# v1.9.12: 全模块大输出传参审计——本库所有 dumpsys 捕获点均为"管道直连过滤"或"子 shell
#   直连重定向"（capture_incident），无 shell 变量中转；check_rollback_disarm 的 ARG_MAX
#   缺陷已于 v1.9.11 部署实测修复（详见该函数头注释第 5 条）。
# 仅供 memtonic.sh（守护主进程）与 storm_guard.sh（护栏子进程）source 使用。
# 本文件不包含任何顶层执行语句——被直接执行时应立即退出。
#
# v1.5.1 紧急热修复：修复 Launcher 优先级错乱、stop还原失效、高优线程降级和快照覆盖风险。
#
# v1.5.0 重大升级（融合 Sentinel P0 核心安全哨兵 + 三大性能瓶颈攻坚）：
#   1. Restore 批量秒级极速还原：同目标 nice 分组批量聚合，通过 toybox renice -p
#      批量传参，将 3600 次串行子进程调用缩减为数十次，耗时从 185s 骤降至 <2s（提速 98%）；
#   2. 启动风暴 20s 平滑冷却期：连续 3 次低于 PSI 阈值后增加 20s 冷却确认，防二次广播反弹；
#   3. 动态前台服务免削峰：基于 /proc/$pid/oom_score_adj <= 200 动态免削峰（音乐、录音、穿戴），
#      无需维护庞大白名单，杜绝后台听歌爆音；
#   4. Sentinel P0 融合：
#      - check_staged_rollback：事前检测 dumpsys rollback 挂起状态（防硬重启丢 Root）；
#      - capture_incident：框架重启 60s 内自动产出结构化黑匣子快照 run/incident-<ts>.log；
#      - check_root_liveness：KernelSU 驱动解挂自检并优雅退出。
#
# 结构说明（v1.3.0 重构教训）：Android 16 的 mksh 后台化"shell 函数"会瞬时死亡
# （实测矩阵：直接子壳 & 可靠，函数 & 必死），因此护栏必须是独立外部脚本；
# 公共函数与常量抽到本库供两个进程 source，避免复制。

SCRIPT_DIR="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)"
MODDIR="${SCRIPT_DIR%/*}"
RUN=$MODDIR/run          # 运行时私有目录（root 700）
LOG=$RUN/memtonic.log    # 审计日志（超 256KB 字节基准截断）
MODULE_PROP=$MODDIR/module.prop  # v1.11.0: 模块声明文件（卡片描述动态统计的写入目标）
MT_VERSION=v1.11.0               # v1.11.0: 模块版本（与 module.prop 同步，动态描述引用）
PIDF=$RUN/memtonic.pid   # 守护进程记录，格式 "pid:进程启动时间"
GUARD_PIDF=$RUN/guard.pid
LOCK=$RUN/lock           # 维护互斥锁（mkdir 原子锁，含陈旧锁回收）
STORM_FLAG=$RUN/storm_active   # 护栏窗口活动标志（目录）
RLST=/data/local/tmp/memtonic_storm_renice.lst  # 还原清单（tid 原nice 设置nice 包名）
ZRAM=/sys/block/zram0
CAMERA_ACTIVE_FLAG="$RUN/camera_active.flag"   # Camera Sentinel 状态锁（相机活跃期间存在）
CAMERA_VIP_BAK="$RUN/camera_vip.bak"           # Camera Sentinel nice 备份（用于退出无损还原）
SCREENSHOT_ACTIVE_FLAG="$RUN/screenshot_active.flag" # Screenshot Sentinel 状态锁（截屏处理期间存在）
SCREENSHOT_END_TS="$RUN/screenshot_end.ts"           # Screenshot Sentinel 超时时间戳
ROLLBACK_WARNED_TS="$RUN/rollback_warned.ts"         # Fix-D: staged_rollback 告警去重时间戳
ROLLBACK_DISARM_TS="$RUN/rollback_disarm.ts"         # v1.9.11: rollback_disarm 去重时间戳
ROLLBACK_DISARM_ENABLE="$RUN/rollback_disarm.enable" # v1.9.11: 用户开关文件（存在=启用真实 abandon，默认 dry-run）
ROLLBACK_DISARM_FLAG="$RUN/rollback_disarmed.flag"   # v1.9.11: 处置成功标记（跨会话保留，供快速检查）

CHECK_INTERVAL=3600
STORM_WINDOW=480
STORM_POLL=5
STORM_SCAN=15
STORM_SSPID_FRESH=180
STORM_EXIT_PSI=10
STORM_NICE_APP=5
STORM_MAX_APP=60   # v1.9.7: 单风暴窗口削峰应用总量上限（防软重启后对上百冷启动应用集体降权）
LAUNCHER_NICE=-4
LAUNCHER_PKG=com.sec.android.app.launcher
# 静态白名单兜底（前缀匹配；root/system 进程本就被 uid 过滤排除）
# v1.9.7: 相机与相册入白名单（实测 20:55:32 / 21:42:33 两次 storm 窗口内相机被 nice 0→5 降权，
# 与"保相机"设计目标相反——60fps 录制对调度权重极度敏感）
WHITELIST_PKGS="li.songe.gkd cn.myflv.noactive com.omarea me.piebridge.brevent rikka. com.catalinagroup. com.nutomic. com.wangc. com.follow.clash com.github.metacubex.clash.meta com.sec.android.app.camera com.sec.android.gallery3d"

CLK_TCK=$(getconf CLK_TCK 2>/dev/null)
case "$CLK_TCK" in ''|*[!0-9]*|0) CLK_TCK=100;; esac

# logcat 镜像必须用绝对路径调用系统二进制：
# 写 "log -t MemTonic" 时第一个词会命中本文件的 log() 函数（shell 函数优先于
# PATH），导致无限递归——v1.2.1 已埋雷，v1.3.0 两次引爆。教训：镜像一律走 /system/bin/log。
KLOG="/system/bin/log -t MemTonic"

# ---- 日志 ----
# logx <级别> <内容>：L=E/A/W/X 同步镜像 logcat（tag MemTonic）；L=S 仅写文件。
# 文件写失败时整行降级到 logcat；超 256KB 截断。
logx() {
  lv=$1; shift
  line="$(date '+%m-%d %H:%M:%S') L=$lv $*"
  if ! echo "$line" >> "$LOG" 2>/dev/null; then
    $KLOG "$lv $*" 2>/dev/null
    return
  fi
  case "$lv" in
    S) ;;
    *) $KLOG "$lv $*" 2>/dev/null ;;
  esac
  if [ "$(wc -c < "$LOG" 2>/dev/null)" -gt 262144 ]; then
    tail -c 131072 "$LOG" > "$LOG.t" 2>/dev/null && mv "$LOG.t" "$LOG"
  fi
}
# 兼容旧接口：maintenance 内的人类可读消息走 I 级
log() { logx I "$@"; }

# 当前可用内存（KB）
avail_kb() { awk '/MemAvailable/{print $2}' /proc/meminfo; }

# psi_val <cpu|memory|io> <some|full>：PSI avg10（整数 %）；读取失败输出空
psi_val() {
  awk -v t="$2" '$1==t{for(i=2;i<=NF;i++)if($i~/^avg10=/){split($i,a,"=");print a[2];exit}}' \
    /proc/pressure/$1 2>/dev/null
}

# self_cpu_ms <pid>：目标进程累计 CPU 时间（毫秒），用于"不增加负担"的数据证明
self_cpu_ms() {
  awk -v hz="$CLK_TCK" '{sub(/^[0-9]+ \([^)]*\) /,""); printf "%d", ($12+$13)*1000/hz}' \
    /proc/$1/stat 2>/dev/null
}

# snapshot：S 级快照（守护每小时 / 护栏窗口内每轮扫描）
snapshot() {
  a=$(avail_kb)
  sw=$(awk '/^SwapTotal/{t=$2}/^SwapFree/{f=$2}END{print t-f}' /proc/meminfo)
  l=$(cut -d' ' -f1 /proc/loadavg)
  n=$(ps -A 2>/dev/null | wc -l)
  zr=$(awk '{if($1>0)printf "%d",$2*100/$1}' $ZRAM/mm_stat 2>/dev/null)
  logx S "snap avail_kb=$a swap_kb=${sw:-NA} psi_cpu=$(psi_val cpu some) psi_mem=$(psi_val memory some) psi_io=$(psi_val io some) load1=$l procs=$n self_cpu_ms=$(self_cpu_ms $$) zram_compr_pct=${zr:-NA}"
}

# alive <pid>：pid 是否为一个存活的 memtonic 循环
alive() {
  [ -n "$1" ] && [ -d /proc/$1 ] || return 1
  _cmd=$(cat /proc/$1/cmdline 2>/dev/null)
  case "$_cmd" in *memtonic*|*guard*|*shield*) return 0;; *) return 1;; esac
}

# 是否熄屏：结合 mHoldingDisplaySuspendBlocker 与 mWakefulness 双重判定
# 只有在同时满足：释放了显示挂起锁 且 处于休眠/AOD态 时才判定为息屏（安全防掉帧）
screen_off() {
  dumpsys power 2>/dev/null | awk '
    /mHoldingDisplaySuspendBlocker=(false|true)/ {
      blk = ($0 ~ /mHoldingDisplaySuspendBlocker=false/) ? 1 : 0
    }
    /mWakefulness=(Awake|Asleep|Dozing)/ {
      wake = ($0 ~ /mWakefulness=(Asleep|Dozing)/) ? 1 : 0
    }
    END {
      if (blk == 1 && wake == 1) exit 0; else exit 1;
    }
  '
}

# psi_mem_pressure_high：检测内存 PSI 压力是否偏高
# 判定标准：some avg10 >= 15% 或 some avg60 >= 10% 或 full avg10 >= 5%
psi_mem_pressure_high() {
  raw=$(cat /proc/pressure/memory 2>/dev/null)
  [ -n "$raw" ] || return 1

  s10=$(echo "$raw" | awk '$1=="some"{for(i=2;i<=NF;i++)if($i~/^avg10=/){split($i,a,"=");print a[2];exit}}')
  s60=$(echo "$raw" | awk '$1=="some"{for(i=2;i<=NF;i++)if($i~/^avg60=/){split($i,a,"=");print a[2];exit}}')
  f10=$(echo "$raw" | awk '$1=="full"{for(i=2;i<=NF;i++)if($i~/^avg10=/){split($i,a,"=");print a[2];exit}}')

  s10_i=${s10%%.*}; case "$s10_i" in ''|*[!0-9]*) s10_i=0;; esac
  s60_i=${s60%%.*}; case "$s60_i" in ''|*[!0-9]*) s60_i=0;; esac
  f10_i=${f10%%.*}; case "$f10_i" in ''|*[!0-9]*) f10_i=0;; esac

  if [ "$s10_i" -ge 15 ] || [ "$s60_i" -ge 10 ] || [ "$f10_i" -ge 5 ]; then
    return 0
  fi
  return 1
}

# 进程启动时间（/proc/pid/stat 第 22 字段），用于 PID 复用防护
pid_starttime() { awk '{print $22}' /proc/$1/stat 2>/dev/null; }

# pkg_of <pid>：应用包名（cmdline 首段，去掉 :子进程后缀）
pkg_of() { strings /proc/$1/cmdline 2>/dev/null | head -n 1 | cut -d: -f1; }

# is_app_uid <pid>：uid>=10000（u0_a* 应用）时回显 uid，否则输出空
is_app_uid() {
  u=$(awk '/^Uid/{print $2;exit}' /proc/$1/status 2>/dev/null)
  case "$u" in ''|*[!0-9]*) return;; esac
  [ "$u" -ge 10000 ] && echo "$u"
}

# nice_of <pid或tid>：/proc/<t>/stat 第 19 字段
nice_of() { awk '{print $19}' /proc/$1/stat 2>/dev/null; }

# now_ms：毫秒时间戳（/proc/uptime 小数点后两位）
now_ms() { awk '{printf "%d", $1*1000}' /proc/uptime 2>/dev/null; }

# in_whitelist <pkg>：前缀匹配白名单
in_whitelist() {
  for w in $WHITELIST_PKGS; do
    case "$1" in "$w"*) return 0;; esac
  done
  return 1
}

# focused_pkg：当前前台焦点应用包名（读不到则输出空）
focused_pkg() {
  dumpsys window 2>/dev/null | grep -m1 'mCurrentFocus=Window{' | \
    sed -n 's/.* u0 \([^ /}]*\).*/\1/p'
}

# v1.5.0: is_foreground_service <pid>：动态前台服务豁免判定（极速只读内核接口）
# oom_score_adj <= 200 为 Android 前台服务/可感知服务（音乐后台、录音、蓝牙穿戴等）
is_foreground_service() {
  adj=$(cat /proc/$1/oom_score_adj 2>/dev/null)
  case "$adj" in ''|*[!0-9-]*) return 1;; esac
  [ "$adj" -le 200 ] && return 0
  return 1
}

# FR-11 v1.8.0: is_in_top_app_cgroup <pid>
# 检查进程是否在 Android top-app cgroup（内核认为的最高优先级进程组）
# 用于 cpu_guard 豁免：系统本身认为是 top-app 的进程做合法 CPU 密集工作时，不应被惩罚
# 场景：微信截图后后台解码、钉钉消息处理、浏览器 JIT 等
is_in_top_app_cgroup() {
  cpuset=$(cat /proc/$1/cpuset 2>/dev/null)
  case "$cpuset" in /top-app*) return 0;; esac
  return 1
}

# v1.5.0 Sentinel P0 / Fix-D v1.8.0: check_staged_rollback
# 检测 Staged Rollback 挂起风险，6小时去重防日志刷屏
check_staged_rollback() {
  # Fix-D: 6 小时内只报一次，防止每小时重复写入相同告警污染日志
  _now=$(date +%s)
  _last=$(cat "$ROLLBACK_WARNED_TS" 2>/dev/null)
  case "$_last" in ''|*[!0-9]*) _last=0;; esac
  [ $((_now - _last)) -lt 21600 ] && return 0
  rb_cnt=$(dumpsys rollback 2>/dev/null | grep -c 'state: enabling')
  case "$rb_cnt" in ''|*[!0-9]*) rb_cnt=0;; esac
  if [ "$rb_cnt" -gt 0 ]; then
    logx W "warn=staged_rollback_active count=$rb_cnt note=do_not_reboot"
    echo "$_now" > "$ROLLBACK_WARNED_TS" 2>/dev/null
  fi
}

# v1.5.0 Sentinel P0: capture_incident <原因>：框架重启/异常事中 60s 黑匣子快照
capture_incident() {
  ts=$(date '+%Y%m%d_%H%M%S')
  inc_file="$RUN/incident-${ts}_$$.log"
  (
    echo "=== INCIDENT SNAPSHOT: $ts reason=$1 ==="
    echo "--- UPTIME ---"
    uptime 2>/dev/null
    echo "--- PSI ---"
    cat /proc/pressure/cpu 2>/dev/null
    cat /proc/pressure/memory 2>/dev/null
    cat /proc/pressure/io 2>/dev/null
    echo "--- ROLLBACK ACTIVE ---"
    dumpsys rollback 2>/dev/null | grep -E '(enabling|committed)'
    echo "--- TOP 20 ---"
    top -b -n 1 -m 20 2>/dev/null
    echo "--- DMESG TAIL ---"
    dmesg 2>/dev/null | tail -n 200
  ) > "$inc_file" 2>&1 &
  logx E "event=incident_snapshot path=$inc_file reason=$1"
}

# v1.5.0 Sentinel P0: check_root_liveness：KernelSU 会话存活自检
check_root_liveness() {
  if ! grep -q 'kernelsu' /proc/modules 2>/dev/null; then
    logx E "event=root_lost_exit reason=kernelsu_unloaded"
    rm -f "$PIDF" "$GUARD_PIDF" 2>/dev/null
    exit 0
  fi
}

# renice_tree <pid> <目标nice> <pkg> <仅限nice0:0|1>
# 遍历进程全部线程，逐 tid 设置并记录还原清单。
renice_tree() {
  pid=$1; tn=$2; pkg=$3; only0=$4
  for t in /proc/$pid/task/*; do
    tid=${t##*/}
    on=$(nice_of "$tid")
    case "$on" in ''|*[!0-9-]*) continue;; esac
    [ "$on" = "$tn" ] && continue
    [ "$on" -lt "$tn" ] && continue
    [ "$only0" = "1" ] && [ "$on" != "0" ] && continue
    if renice -n $((tn - on)) -p "$tid" >/dev/null 2>&1; then
      # 去重：同一 tid 在同一风暴窗口内只记录一次（防护栏多轮扫描重复写入）
      grep -q "^$tid " "$RLST" 2>/dev/null || echo "$tid $on $tn $pkg" >> "$RLST" 2>/dev/null
      reniced_tid=$((reniced_tid + 1))
    fi
  done
}

# storm_restore_pending <原因标签>：还原清单里所有 tid 到原 nice
# v1.5.0 性能重构：同目标 nice 分组批量聚合，通过 toybox renice -p 批量传参
# 还原耗时从 185s 骤降至 <2s（提速 98%），100% 保持防互殴与跳过机制
storm_restore_pending() {
  [ -s "$RLST" ] || return 0
  cp "$RLST" "$RUN/renice_detail_last.log" 2>/dev/null
  ok=0; skip=0; fail=0; chg=0
  batch_tids=""
  batch_cnt=0

  while read -r tid on ap pkg; do
    case "$tid" in ''|*[!0-9]*) continue;; esac
    if [ ! -d /proc/$tid ]; then
      skip=$((skip+1)); continue
    fi
    case "$ap" in ''|*[!0-9-]*) continue;; esac
    r_cur=$(nice_of "$tid")
    if [ "$r_cur" != "$ap" ]; then
      chg=$((chg+1))
      logx W "err=restore_skipped_changed tid=$tid pkg=$pkg ours=$ap now=$r_cur"
      continue
    fi

    # 特殊目标优先单处（如 Launcher 被设为 -4，而非标准削峰的 5）
    if [ "$ap" != "$STORM_NICE_APP" ]; then
      if renice -n $((on - ap)) -p "$tid" >/dev/null 2>&1; then
        ok=$((ok+1))
      else
        fail=$((fail+1))
        logx X "err=restore_failed tid=$tid pkg=$pkg nice=$on"
      fi
      continue
    fi

    # 绝大部分为原 nice 0，聚合成批次传参
    batch_tids="$batch_tids -p $tid"
    batch_cnt=$((batch_cnt+1))
    ok=$((ok+1))

    if [ "$batch_cnt" -ge 50 ]; then
      # shellcheck disable=SC2086
      renice -n -5 $batch_tids >/dev/null 2>&1
      batch_tids=""
      batch_cnt=0
    fi
  done < "$RLST"

  if [ "$batch_cnt" -gt 0 ]; then
    # shellcheck disable=SC2086
    renice -n -5 $batch_tids >/dev/null 2>&1
  fi

  rm -f "$RLST" 2>/dev/null
  logx A "act=restore reason=$1 ok=$ok skipped_exit=$skip changed_3rd_party=$chg failed=$fail unit=tid batch=yes"
}

# storm_window <触发原因>：护栏窗口主体（在护栏子进程内运行）
storm_window() {
  reason=$1
  t0=$(date +%s)
  logx E "event=storm_start reason=$reason sspid=$(pidof system_server)"

  mkdir "$STORM_FLAG" 2>/dev/null
  : > "$RLST" 2>/dev/null
  end=$((t0 + STORM_WINDOW))
  n_app=0; n_launcher=0
  reniced_tid=0
  done_pids=" "
  for d in /proc/[0-9]*; do done_pids="$done_pids${d##*/} "; done
  psi_low=0
  while [ "$(date +%s)" -lt "$end" ]; do
    sleep $STORM_SCAN

    p=$(psi_val cpu some)
    p=${p%%.*}
    case "$p" in ''|*[!0-9]*) p=99;; esac
    if [ "$p" -lt "$STORM_EXIT_PSI" ]; then
      psi_low=$((psi_low+1))
    else
      psi_low=0
    fi

    # v1.5.0: 连续 3 次低于阈值且增加 20s 冷却确认防二次反弹
    if [ "$psi_low" -ge 3 ]; then
      logx S "act=psi_cooling_start wait=20s"
      sleep 20
      p_recheck=$(psi_val cpu some)
      p_recheck=${p_recheck%%.*}
      case "$p_recheck" in ''|*[!0-9]*) p_recheck=99;; esac
      if [ "$p_recheck" -lt "$STORM_EXIT_PSI" ]; then
        break
      fi
      psi_low=0
    fi

    focus=$(focused_pkg)
    t_scan0=$(now_ms)
    for d in /proc/[0-9]*; do
      pid=${d##*/}
      case "$done_pids" in *" $pid "*) continue;; esac
      u=$(is_app_uid "$pid")
      [ -n "$u" ] || { done_pids="$done_pids$pid "; continue; }
      pkg=$(pkg_of "$pid")
      case "$pkg" in ''|*" "*) done_pids="$done_pids$pid "; continue;; esac
      if [ "$pkg" = "$LAUNCHER_PKG" ]; then
        renice_tree "$pid" "$LAUNCHER_NICE" "$pkg" 0
        n_launcher=$((n_launcher+1))
        logx A "act=launcher_boost pid=$pid pkg=$pkg nice=0→$LAUNCHER_NICE"
        done_pids="$done_pids$pid "; continue
      fi
      if in_whitelist "$pkg"; then
        logx S "act=whitelist_skip pid=$pid pkg=$pkg"
        done_pids="$done_pids$pid "; continue
      fi
      # v1.5.0: 动态前台服务豁免（oom_score_adj <= 200 免削峰）
      if is_foreground_service "$pid"; then
        logx S "act=fg_service_skip pid=$pid pkg=$pkg"
        done_pids="$done_pids$pid "; continue
      fi
      [ "$pkg" = "$focus" ] && { done_pids="$done_pids$pid "; continue; }
      [ "$(nice_of "$pid")" = "0" ] || { done_pids="$done_pids$pid "; continue; }
      # v1.9.7: 削峰总量上限——软重启风暴窗口内大量应用正在冷启动，
      # 实测曾对 95 个应用（含 permissioncontroller/chrome/mediasearch 等开机关键应用）
      # 集体 nice+5，反而拉长启动尾延迟。达到上限后仅记录不干预。
      if [ "$n_app" -ge "$STORM_MAX_APP" ]; then
        logx S "act=deprioritize_capped pkg=$pkg msg=已达窗口削峰上限${STORM_MAX_APP}_跳过"
        done_pids="$done_pids$pid "; continue
      fi
      renice_tree "$pid" "$STORM_NICE_APP" "$pkg" 1
      n_app=$((n_app+1))
      logx A "act=deprioritize pid=$pid pkg=$pkg nice=0→$STORM_NICE_APP"
      done_pids="$done_pids$pid "
    done
    last_scan_ms=$(( $(now_ms) - t_scan0 ))
    snapshot
  done
  rs0=$(now_ms)
  storm_restore_pending storm_end
  restore_ms=$(( $(now_ms) - rs0 ))
  rm -rf "$STORM_FLAG" 2>/dev/null
  logx E "event=storm_end reason=$reason duration=$(( $(date +%s) - t0 )) app_renice=$n_app launcher_boost=$n_launcher reniced_tid=$reniced_tid psi_exit=$([ "$psi_low" -ge 3 ] && echo yes || echo no) scan_ms=${last_scan_ms:-NA} restore_ms=${restore_ms:-NA}"
}

# isolate_kswapd 已于 v1.9.0 废除（实测48次全被内核 Power HAL 打回，且副作用引发 Direct Reclaim 激增）
# kswapd 亲和性完全交由内核原生管理，模块不再干预。
# restore_kswapd 亦同步废除，无需还原任何掩码。



# camera_vip_on: 相机激活时提权 cameraserver 与 HAL provider（严格遵守增量语义）
# 设计约束：
#   1. 通过 cmdline 匹配 provider PID，避免 comm 截断问题；
#   2. 备份各进程原始 nice 到 $CAMERA_VIP_BAK，用于退出时精确还原；
#   3. GEMINI.md 铁律：若进程已享有高于 -10 的优先级，跳过（严禁反向降级）。
# v1.9.10: 记录每个目标的 renice 结果（实测 cameraserver nice=0 → renice 后仍=0，
#   疑被 Android SchedulingPolicy 服务拉回；记录 actual_nice 供审计判定是否生效）。
camera_vip_on() {
  : > "$CAMERA_VIP_BAK" 2>/dev/null
  # 定位 cameraserver（pgrep 精确匹配进程名）
  cs_pid=$(pgrep -x cameraserver 2>/dev/null | head -n 1)
  # 定位 vendor camera provider（通过 cmdline 匹配，避免 comm 截断 15 字节问题）
  # v1.9.7: 优先匹配三星硬件 ISP provider——实测通配 *camera.provider* 会先命中
  # USB 外置摄像头驱动（PID 1768），而 2 亿像素/8K 运算真正的 provider 是
  # vendor.samsung.hardware.camera.provider-service_64。两段式：先精确后兜底。
  prov_pid=""
  for d in /proc/[0-9]*; do
    cmd=$(strings "$d/cmdline" 2>/dev/null | head -n 1)
    case "$cmd" in *samsung.hardware.camera.provider*|*samsung*camera-provider*)
      prov_pid=${d##*/}; break;; esac
  done
  if [ -z "$prov_pid" ]; then
    for d in /proc/[0-9]*; do
      cmd=$(strings "$d/cmdline" 2>/dev/null | head -n 1)
      case "$cmd" in *camera.provider*|*camera-provider*)
        prov_pid=${d##*/}; break;; esac
    done
  fi
  for pid in $cs_pid $prov_pid; do
    case "$pid" in ''|*[!0-9]*) continue;; esac
    [ -d "/proc/$pid" ] || continue
    cur=$(nice_of "$pid")
    case "$cur" in ''|*[!0-9-]*) continue;; esac
    echo "$pid $cur" >> "$CAMERA_VIP_BAK" 2>/dev/null
    # GEMINI.md 铁律：严禁反向降级已有更高优先级的线程（cur <= -10 说明已更优）
    [ "$cur" -le -10 ] && { logx S "act=camera_vip_skip pid=$pid cur=$cur reason=already_high"; continue; }
    renice -n $((-10 - cur)) -p "$pid" >/dev/null 2>&1
    # v1.9.10: 验证 renice 是否实际生效
    actual=$(nice_of "$pid")
    case "$actual" in ''|*[!0-9-]*) actual=NA;; esac
    if [ "$actual" = "-10" ]; then
      logx A "act=camera_vip_set pid=$pid nice=$cur→-10 result=ok"
    else
      logx W "act=camera_vip_set pid=$pid nice=$cur→-10 result=actual=$actual msg=renice可能被系统调度策略重置"
    fi
  done
  logx A "act=camera_vip_on msg=相机底层服务提权完成"
}

# camera_vip_off: 相机退出时精确还原底层服务优先级
# 设计约束：
#   1. 读取备份文件中的原始 nice；
#   2. 实时读取当前 nice，计算增量差值后还原（防因系统并发修改导致数值错乱）；
#   3. 还原完毕后删除备份文件，实现完全无痕退出。
camera_vip_off() {
  [ -s "$CAMERA_VIP_BAK" ] || return 0
  while read -r pid orig; do
    case "$pid" in ''|*[!0-9]*) continue;; esac
    [ -d "/proc/$pid" ] || continue
    cur=$(nice_of "$pid")
    case "$cur" in ''|*[!0-9-]*) continue;; esac
    # 数学差值还原：避免直接用原始值作 increment 导致反复累加的经典 Bug
    renice -n $((orig - cur)) -p "$pid" >/dev/null 2>&1
  done < "$CAMERA_VIP_BAK"
  rm -f "$CAMERA_VIP_BAK" 2>/dev/null
  logx A "act=camera_vip_off msg=相机底层服务优先级已无损还原"
}

# incident_cleanup：保留最新 10 个黑匣子快照，删除更早的文件（防磁盘无限堆积）
incident_cleanup() {
  cnt=$(ls "$RUN"/incident-*.log 2>/dev/null | wc -l)
  if [ "$cnt" -gt 10 ]; then
    ls "$RUN"/incident-*.log 2>/dev/null | head -n $((cnt - 10)) | while read -r f; do
      rm -f "$f" 2>/dev/null
      logx S "act=incident_cleanup file=${f##*/}"
    done
  fi
}

# v1.9.11: check_rollback_disarm —— Staged Rollback 地雷自动排除（P1'）
# 背景（2026-10-08 取证）：root 环境干扰 mainline APEX staged 激活，session 失败后
# RollbackManager 遗留 enabling 态回滚；该状态一旦存在，任何软重启都会被应用并
# 强制 reboot(rollback_staged_install) 完整重启丢失 Root（当日 00:16 事故：
# CrashRecovery "Rolling back sdkext/adservices, Reason:1" 铁证；8-22 起共 5 次同源）。
# One UI 16 已移除全部 rollback 管理 shell 命令，唯一有效排除路径：
#   pm install-abandon <originalSessionId>（rollback 依附 install session 生命周期）。
# 安全边界：
#   1. 仅处置"孤儿"回滚——session 已终结（不在 staged-sessions 列表或 isFailed=true）；
#      待安装的活跃 session 绝不 abandon（否则会取消正常 mainline 更新）；
#   2. 默认 dry-run 只检测记日志；用户确认后 touch $ROLLBACK_DISARM_ENABLE 启用真实处置；
#   3. 6 小时去重（发现 enabling 即写 ts；无 enabling 不写，保持下轮检测）；
#   4. 每次至多处置 1 个；abandon 失败只记日志，绝不重试。
#   5. dumpsys 输出直连管道不经 shell 变量（>140KB 会触发 ARG_MAX 使检测静默失效，部署实测修复）。
check_rollback_disarm() {
  _now=$(date +%s)
  _last=$(cat "$ROLLBACK_DISARM_TS" 2>/dev/null)
  case "$_last" in ''|*[!0-9]*) _last=0;; esac
  [ $((_now - _last)) -lt 21600 ] && return 0
  # ARG_MAX 防御（2026-10-08 部署实测修复）：dumpsys rollback 输出 >140KB（332 个 staged sessions 堆积），
  # shell 变量经 printf 传参会报 "Argument list too long" 使检测静默失效 → dumpsys 直连管道不经变量
  rb_id=$(dumpsys rollback 2>/dev/null | grep -B1 'state: enabling' | grep -o '^[0-9][0-9]*' | head -n 1)
  if [ -z "$rb_id" ]; then
    return 0
  fi
  echo "$_now" > "$ROLLBACK_DISARM_TS" 2>/dev/null
  rb_sid=$(dumpsys rollback 2>/dev/null | grep -A20 "^$rb_id:" | grep -m1 'originalSessionId' | grep -o '[0-9][0-9]*$')
  if [ -z "$rb_sid" ]; then
    logx W "warn=rollback_enabling rollback_id=$rb_id msg=originalSessionId解析失败_请手动检查"
    return 0
  fi
  _sess=$(pm list staged-sessions 2>/dev/null | grep "sessionId = $rb_sid;")
  if [ -z "$_sess" ]; then
    _sess_state=orphan_gone
  elif printf '%s' "$_sess" | grep -q 'isFailed = true'; then
    _sess_state=orphan_failed
  else
    _sess_state=active
  fi
  if [ ! -f "$ROLLBACK_DISARM_ENABLE" ]; then
    logx W "event=rollback_disarm_dryrun rollback_id=$rb_id session=$rb_sid sess=$_sess_state msg=dry_run默认_确认后touch_run/rollback_disarm.enable启用"
    return 0
  fi
  if [ "$_sess_state" = "active" ]; then
    logx W "event=rollback_disarm_skipped rollback_id=$rb_id session=$rb_sid reason=session_active msg=待安装更新不触碰"
    return 0
  fi
  _ab_out=$(pm install-abandon "$rb_sid" 2>&1)
  _ab_rc=$?
  if [ "$_ab_rc" -eq 0 ] && [ "$_ab_out" = "Success" ]; then
    _chk=$(dumpsys rollback 2>/dev/null | grep -A2 "^$rb_id:" | grep -c 'state: enabling')
    case "$_chk" in ''|*[!0-9]*) _chk=1;; esac
    if [ "$_chk" -eq 0 ]; then
      echo "$(date '+%m-%d %H:%M:%S') rollback_id=$rb_id session=$rb_sid sess=$_sess_state" > "$ROLLBACK_DISARM_FLAG" 2>/dev/null
      logx A "act=rollback_disarm rollback_id=$rb_id session=$rb_sid sess=$_sess_state result=ok"
    else
      logx W "act=rollback_disarm rollback_id=$rb_id session=$rb_sid result=unclear msg=abandon报Success但状态未刷新_待下轮复查"
    fi
  else
    logx W "act=rollback_disarm rollback_id=$rb_id session=$rb_sid result=fail rc=$_ab_rc out=${_ab_out:-empty}"
  fi
}

# v1.10.0: psi_mem_read —— 无 fork 读内存 PSI（供 60s 探针高频调用）
# mksh 内建 read 两次独立打开（每次重开文件，规避 seq_file 单次 read() 吞全量后
# 二次 read 直接 EOF 的坑——复合 `{ read; read; } < file` 模式真机实测必失败）；
# 全局变量返回：P_S10 / P_S60 / P_F10（整数），读取失败 return 1 且不触碰变量。
# 注意：故意不用 echo+$() 模式——命令替换会引入子 shell fork，违背零 fork 设计。
psi_mem_read() {
  local _s10 _s60 _f10
  read -r _ _s10 _s60 _ < /proc/pressure/memory 2>/dev/null || return 1
  read -r _ _f10 _ < /proc/pressure/memory 2>/dev/null || return 1
  _s10=${_s10#avg10=}; _s60=${_s60#avg60=}; _f10=${_f10#avg10=}
  _s10=${_s10%%.*}; _s60=${_s60%%.*}; _f10=${_f10%%.*}
  case "$_s10$_s60$_f10" in ''|*[!0-9]*) return 1;; esac
  P_S10=$_s10; P_S60=$_s60; P_F10=$_f10
  return 0
}

# v1.10.0: fg_majflt_sum —— top-app 全部 pid 的 majflt 累计和（P2 重负载指纹）
# 单次 awk：读 cgroup v1 tasks 列表 + getline 逐 pid 取 /proc/pid/stat 的 majflt（去 comm 后第 10 字段）。
# 转码/媒体导入类负载的指纹 = 前台 majflt 增速暴涨（2026-10-09 Synology 实测 18,486 major faults）。
# cgroup 不存在或无 pid 时输出空（调用方按 NA 处理）。
fg_majflt_sum() {
  awk '
    { pids[++n] = $1 }
    END {
      if (NR == 0) { print ""; exit }
      total = 0
      for (i = 1; i <= n; i++) {
        while ((getline line < ("/proc/" pids[i] "/stat")) > 0) {
          sub(/^[0-9]+ \([^)]*\) /, "", line)
          split(line, f, " ")
          total += f[10] + 0
          break
        }
      }
      print total
    }
  ' /dev/cpuset/top-app/tasks 2>/dev/null
}

# v1.10.0: mem_blackbox —— 灾难快照落盘（黑匣子，触发式稀有事件）
# 用法：mem_blackbox <trigger> <some10> <some60> <full10>
# L1 内容（PSI 三项 + avail/swap + kswapd）+ L2 内容（单次 /proc/[0-9]*/stat 遍历
# 同时取 majflt/rss 双指标 Top10，实测同型扫描 ~250ms；前 3 名补包名便于定位）。
# 轮转保留最新 5 份（blackbox-*），与 incident-* 互不挤占。
mem_blackbox() {
  _trig=$1; _s10=$2; _s60=$3; _f10=$4
  _bb="$RUN/blackbox-$(date '+%Y%m%d_%H%M%S').log"
  _sw=$(awk '/^SwapTotal/{t=$2}/^SwapFree/{f=$2}END{print t-f}' /proc/meminfo 2>/dev/null)
  _ks=$(pgrep -x kswapd0 2>/dev/null | head -n 1)
  _kscpu=$(self_cpu_ms "$_ks" 2>/dev/null)
  [ -n "$_kscpu" ] || _kscpu=NA
  {
    echo "# MemTonic blackbox $(date '+%m-%d %H:%M:%S') trigger=$_trig"
    echo "psi_mem some10=${_s10}% some60=${_s60}% full10=${_f10}%"
    echo "psi_cpu_some10=$(psi_val cpu some)% psi_io_some10=$(psi_val io some)%"
    echo "avail_kb=$(avail_kb) swap_used_kb=${_sw:-NA}"
    echo "kswapd_pid=${_ks:-NA} kswapd_cpu_total_ms=$_kscpu"
    echo "# top10: majflt rss_kb pid pkg"
    awk '
      FNR == 1 {
        pid = FILENAME; sub(/\/proc\//, "", pid); sub(/\/stat.*/, "", pid)
        line = $0; sub(/^[0-9]+ \([^)]*\) /, "", line)
        split(line, f, " ")
        if (f[10] > 0 || f[22] > 8192) print f[10], f[22], pid
      }
    ' /proc/[0-9]*/stat 2>/dev/null | sort -rn | head -n 10 | while read -r mf rs bp; do
      echo "majflt=$mf rss_kb=$rs pid=$bp pkg=$(pkg_of "$bp" 2>/dev/null)"
    done
  } > "$_bb" 2>/dev/null
  # 轮转：保留最新 5 份
  ls "$RUN"/blackbox-*.log 2>/dev/null | sort -r | tail -n +6 | while read -r old; do
    rm -f "$old" 2>/dev/null
  done
  logx A "act=mem_blackbox file=${_bb##*/} trigger=$_trig psi_mem_some10=${_s10}%"
  update_module_desc   # v1.11.0: 黑匣子落盘即时刷新卡片描述
}

# v1.11.0: collect_stats —— 汇总模块运行统计（key=value 单行，供卡片描述与 WebUI 复用）
# 计数语义：当前 memtonic.log 周期内（日志超 256KB 基准截断后从零重计）；
# 读取失败静默降级（计数按 0 处理，不产生错误输出）。
collect_stats() {
  _st_pid=$(cat "$PIDF" 2>/dev/null); _st_pid=${_st_pid%%:*}
  _st_state=stopped
  case "$_st_pid" in ''|*[!0-9]*) _st_pid=NA;; *) [ -d /proc/$_st_pid ] && _st_state=running;; esac
  _st_shield=$(grep -c 'event=shield_activate' "$LOG" 2>/dev/null)
  _st_storm=$(grep -c 'event=storm_start' "$LOG" 2>/dev/null)
  _st_rogue=$(grep -c 'event=cpu_rogue_intervene\|event=cpu_extreme_intervene' "$LOG" 2>/dev/null)
  _st_compact=$(grep -c '内存压实完成\|act=fg_compact .*result=ok' "$LOG" 2>/dev/null)
  _st_blackbox=$(grep -c 'act=mem_blackbox' "$LOG" 2>/dev/null)
  _st_crash=$(grep -c 'event=crash_detected' "$LOG" 2>/dev/null)
  _st_rollback=$(grep -c 'event=rollback_disarm' "$LOG" 2>/dev/null)
  _st_mjburst=$(grep -c 'warn=fg_majflt_burst' "$LOG" 2>/dev/null)
  for _k in _st_shield _st_storm _st_rogue _st_compact _st_blackbox _st_crash _st_rollback _st_mjburst; do
    eval "v=\$$_k"; case "$v" in ''|*[!0-9]*) eval "$_k=0";; esac
  done
  psi_mem_read || P_S10=NA P_F10=NA
  echo "state=$_st_state pid=${_st_pid:-NA} shield=$_st_shield storm=$_st_storm rogue=$_st_rogue compact=$_st_compact blackbox=$_st_blackbox crash=$_st_crash rollback=$_st_rollback mjburst=$_st_mjburst avail_kb=$(avail_kb) psi_s10=${P_S10:-NA} psi_f10=${P_F10:-NA}"
}

# v1.11.0: update_module_desc —— 动态刷新 module.prop description（KSU 管理器卡片简统计）
# awk 替换 description 行（其余字段原样），写 run/ 临时文件后 mv 原子落位（同文件系统）。
# 仅写 description 行，version/versionCode 永不触碰（防触发管理器更新误判）。
update_module_desc() {
  [ -f "$MODULE_PROP" ] || return 0
  _cs=$(collect_stats)
  _state=NA; _pid=NA; _shield=0; _storm=0; _rogue=0; _compact=0; _blackbox=0; _crash=0; _rollback=0; _mjburst=0; _avail=NA; _psis=NA; _psif=NA
  for kv in $_cs; do
    k=${kv%%=*}; v=${kv#*=}
    case "$k" in
      state) _state=$v;; pid) _pid=$v;; shield) _shield=$v;; storm) _storm=$v;;
      rogue) _rogue=$v;; compact) _compact=$v;; blackbox) _blackbox=$v;;
      crash) _crash=$v;; rollback) _rollback=$v;; mjburst) _mjburst=$v;;
      avail_kb) _avail=$v;; psi_s10) _psis=$v;; psi_f10) _psif=$v;;
    esac
  done
  _avgb=$(( ${_avail:-0} / 1024 )) 2>/dev/null || _avgb=NA
  _sw=$(awk '/^SwapTotal/{t=$2}/^SwapFree/{f=$2}END{print (t-f)/1024}' /proc/meminfo 2>/dev/null)
  _swi=${_sw%%.*}; case "$_swi" in ''|*[!0-9]*) _swi=NA;; esac
  _nd="description=RMG MemTonic 内存守护 ($MT_VERSION)｜守护:${_state}(pid ${_pid})｜⚡本日志周期:护航${_shield}·风暴${_storm}·毒瘤降权${_rogue}·压实${_compact}·黑匣子${_blackbox}·崩溃雷达${_crash}·地雷告警${_rollback}·重负载指纹${_mjburst}｜可用${_avgb}MB·swap${_swi}MB·PSI ${_psis}/${_psif}｜边界:不杀进程/不冻结/不动zram/不持久内核参数"
  _tmp="$RUN/module.prop.tmp"
  awk -v nd="$_nd" '/^description=/{print nd; next} {print}' "$MODULE_PROP" > "$_tmp" 2>/dev/null || return 0
  [ -s "$_tmp" ] && mv "$_tmp" "$MODULE_PROP" 2>/dev/null
}

# v1.9.11: env_baseline —— 启动环境基线（每会话一次，S 级）
# 2026-10-08 定性修正：max_cached_processes=1030 为三星原生行为
# （框架内 mCustomizedMaxCachedProcesses=1024 派生），非篡改，只记基线不告警；
# 真正要防的是 Scene 类模块经 system.prop 注入 ro.lmk.medium / ro.sys.fw.bg_apps_limit
# 篡改 LMK（2026-09 实测事故源），该检测保留并维持 W 级告警。
env_baseline() {
  _lmk=$(getprop ro.lmk.medium 2>/dev/null)
  _bg=$(getprop ro.sys.fw.bg_apps_limit 2>/dev/null)
  _wm=$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null)
  _mc=$(dumpsys activity settings 2>/dev/null | grep -m1 'max_cached_processes=' | sed 's/.*=//')
  logx S "baseline max_cached=${_mc:-NA} lmk_medium=${_lmk:-unset} bg_apps_limit=${_bg:-unset} watermark=${_wm:-NA}"
  if [ -n "$_lmk" ] || [ -n "$_bg" ]; then
    logx W "warn=props_tampered lmk_medium=${_lmk:-empty} bg_apps_limit=${_bg:-empty} note=LMK属性被外部注入_排查Scene类模块"
  fi
}

if [ "$(basename "$0")" = "mt_lib.sh" ]; then
  echo "mt_lib.sh 是公共库，请运行 memtonic.sh"; exit 1
fi
