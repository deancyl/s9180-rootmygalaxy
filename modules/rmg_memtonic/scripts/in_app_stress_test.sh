#!/system/bin/sh
# in_app_stress_test.sh —— RMG MemTonic 应用内深度滑动压力测试工具
#
# 功能：
#   利用系统内置 monkey 工具，在指定重度应用（如小红书、微信）被拉起后，
#   在应用内部生成高频随机的 UI 交互事件（纯滑动与点击），模拟真实用户疯狂刷帖
#   导致的高频内存分配与 UI 渲染压力。测试结束后提取并输出 dumpsys gfxinfo 性能报告。
#
# 权限与安全：
#   * 必须以 root 权限执行 (id -u == 0)；
#   * 严格禁止针对系统核心关键包执行破坏性测试；
#   * 自动屏蔽所有系统按键与应用切换事件，杜绝逃逸出应用；
#   * 注册 trap 信号清理，确保 Ctrl+C 时干净终止子进程。

# 1. 默认参数定义
EVENTS=500
THROTTLE=80
WAIT_SEC=4
SEED=12345
PCT_TOUCH=35
PCT_MOTION=65
COLD=0
OUTPUT_JSON=0
PKG=""

# 2. 命令行参数解析
show_help() {
  cat << 'EOF'
用法: in_app_stress_test.sh [选项] [包名]

参数:
  [包名]                  测试目标包名（默认: com.xingin.xhs；若未安装自动回退到 com.tencent.mm）

选项:
  -n, --events <COUNT>    测试注入的事件总数（默认: 500）
  -t, --throttle <MS>     事件间隔时间毫秒（默认: 80）
  -w, --wait <SEC>        拉起应用后等待渲染稳定的时间（默认: 4）
  -s, --seed <SEED>       随机种子，用于实验完全复现（默认: 12345）
      --touch <PCT>       点击事件百分比（默认: 35）
      --motion <PCT>      滑动事件百分比（默认: 65）
      --cold              测试前先强制停止应用以进行冷启动测试（默认: 热启动/保持当前状态）
      --json              以标准 JSON 格式输出测试结果（供自动化测试解析）
  -h, --help              显示本帮助信息
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--events)
      EVENTS="$2"; shift 2 ;;
    --events=*)
      EVENTS="${1#*=}"; shift ;;
    -t|--throttle)
      THROTTLE="$2"; shift 2 ;;
    --throttle=*)
      THROTTLE="${1#*=}"; shift ;;
    -w|--wait)
      WAIT_SEC="$2"; shift 2 ;;
    --wait=*)
      WAIT_SEC="${1#*=}"; shift ;;
    -s|--seed)
      SEED="$2"; shift 2 ;;
    --seed=*)
      SEED="${1#*=}"; shift ;;
    --touch)
      PCT_TOUCH="$2"; shift 2 ;;
    --touch=*)
      PCT_TOUCH="${1#*=}"; shift ;;
    --motion)
      PCT_MOTION="$2"; shift 2 ;;
    --motion=*)
      PCT_MOTION="${1#*=}"; shift ;;
    --cold)
      COLD=1; shift ;;
    --json)
      OUTPUT_JSON=1; shift ;;
    -h|--help)
      show_help; exit 0 ;;
    -*)
      echo "[ERROR] 未知选项: $1" >&2
      show_help >&2
      exit 1
      ;;
    *)
      if [ -z "$PKG" ]; then
        PKG="$1"
      else
        echo "[ERROR] 多余参数: $1" >&2
        show_help >&2
        exit 1
      fi
      shift
      ;;
  esac
done

# 3. 系统关键包名保护防御 (防变砖与防系统崩溃，优先拦截)
if [ -n "$PKG" ]; then
  case "$PKG" in
    android|system_server|com.android.systemui|*launcher*|zygote|zygote64)
      echo "[ERROR] 目标包名 '$PKG' 为系统核心组件，严禁执行破坏性/交互压测！" >&2
      exit 1
      ;;
  esac
fi

# 4. Root 权限校验
if [ "$(id -u 2>/dev/null)" -ne 0 ]; then
  echo "[ERROR] 本脚本必须以 root 权限运行 (例如: su -c $0)" >&2
  exit 3
fi

# 5. 屏幕唤醒状态校验 (防息屏无效测试)
wake=$(dumpsys power 2>/dev/null | grep -E "mHoldingDisplaySuspendBlocker|mWakefulness" | grep -E "true|Awake")
if [ -z "$wake" ]; then
  echo "[ERROR] 设备屏幕处于休眠或息屏状态，请先解锁屏幕后再执行压测。" >&2
  exit 4
fi


# 5. 目标包名自适应回退选择
if [ -z "$PKG" ]; then
  if pm path com.xingin.xhs >/dev/null 2>&1; then
    PKG="com.xingin.xhs"
  elif pm path com.tencent.mm >/dev/null 2>&1; then
    PKG="com.tencent.mm"
  elif pm path com.sec.android.app.popupcalculator >/dev/null 2>&1; then
    PKG="com.sec.android.app.popupcalculator"
  else
    echo "[ERROR] 未指定包名，且常见候选包均未安装！" >&2
    exit 2
  fi
fi

# 6. 系统关键包名保护防御 (防变砖与防系统崩溃)
case "$PKG" in
  android|system_server|com.android.systemui|*launcher*|zygote|zygote64)
    echo "[ERROR] 目标包名 '$PKG' 为系统核心组件，严禁执行破坏性/交互压测！" >&2
    exit 1
    ;;
esac

# 7. 验证目标包是否确实已安装
if ! pm path "$PKG" >/dev/null 2>&1; then
  echo "[ERROR] 目标包名 '$PKG' 未在系统中安装！" >&2
  exit 2
fi

# 8. 信号捕获与进程清理 (Ctrl+C 时干净回收子进程)
cleanup() {
  pkill -P $$ monkey 2>/dev/null
  pkill -f "com.android.commands.monkey" 2>/dev/null
  rm -f "/data/local/tmp/memtonic_gfx_snap_$$.tmp" 2>/dev/null  # v1.9.12: gfxinfo 快照兜底清理
  exit 130
}
trap cleanup INT TERM HUP

# 9. 冷启动处理 (如果指定 --cold)
if [ "$COLD" -eq 1 ]; then
  am force-stop "$PKG" >/dev/null 2>&1
  sleep 1
fi

# 10. 拉起目标应用
monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep "$WAIT_SEC"

# 11. 前置快照与计数器归零
avail_before=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
psi_before=$(awk -v t="some" '$1==t{for(i=2;i<=NF;i++)if($i~/^avg10=/){split($i,a,"=");print a[2];exit}}' /proc/pressure/memory 2>/dev/null)

# 重置 gfxinfo 统计，消除启动加载期及开机历史帧干扰
dumpsys gfxinfo "$PKG" reset >/dev/null 2>&1

# 12. 高频事件注入 (纯触控与滑动，全量封禁系统按键以防逃逸)
monkey -s "$SEED" -p "$PKG" \
  --pct-touch "$PCT_TOUCH" --pct-motion "$PCT_MOTION" \
  --pct-syskeys 0 --pct-appswitch 0 --pct-anyevent 0 \
  --pct-nav 0 --pct-majornav 0 --pct-trackball 0 \
  --pct-flip 0 --pct-pinchzoom 0 --pct-permission 0 \
  --ignore-crashes --ignore-timeouts --ignore-security-exceptions \
  --throttle "$THROTTLE" "$EVENTS" >/dev/null 2>&1

# 13. 等待最后一批 RenderThread 渲染指令排空
sleep 1

# 14. 后置快照
avail_after=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
psi_after=$(awk -v t="some" '$1==t{for(i=2;i<=NF;i++)if($i~/^avg10=/){split($i,a,"=");print a[2];exit}}' /proc/pressure/memory 2>/dev/null)

# 15. 提取并解析 dumpsys gfxinfo 数据
# v1.9.12 ARG_MAX 防御（全模块审计修复）：gfxinfo 输出（含超长 HISTOGRAM 行，压测后
#     可达数十 KB）完整捕获进 shell 变量再经 echo 传参，会触发 "Argument list too long"
#     （同日 check_rollback_disarm 同型缺陷）；改为落临时文件快照，且保证崩溃判定与
#     字段解析消费同一份数据，快照一致性更优。
_gfx_tmp="/data/local/tmp/memtonic_gfx_snap_$$.tmp"
dumpsys gfxinfo "$PKG" > "$_gfx_tmp" 2>/dev/null
if [ ! -s "$_gfx_tmp" ] || grep -q "No process found for:" "$_gfx_tmp"; then
  rm -f "$_gfx_tmp" 2>/dev/null
  echo "[CRITICAL] 目标应用 '$PKG' 在压测期间崩溃或被 LMK 终止，无法读取帧率数据！" >&2
  exit 2
fi

# 使用 POSIX/Toybox awk 精确提取关键字段（行首锚点防止混淆 gpu 字段）
# v1.9.12: 直读快照文件，不经 echo 传参（ARG_MAX 防御）
parsed=$(awk '
  /^Total frames rendered:/ { total = $4 }
  /^Janky frames:/ {
    janky = $3
    pct = $4
    gsub(/[()%]/, "", pct)
  }
  /^50th percentile:/ { sub(/ms$/, "", $3); p50 = $3 }
  /^90th percentile:/ { sub(/ms$/, "", $3); p90 = $3 }
  /^95th percentile:/ { sub(/ms$/, "", $3); p95 = $3 }
  /^99th percentile:/ { sub(/ms$/, "", $3); p99 = $3 }
  /^Number Missed Vsync:/ { missed_vsync = $4 }
  /^Number Slow UI thread:/ { slow_ui = $5 }
  /^Number High input latency:/ { high_latency = $5 }
  /^Number Frame deadline missed:/ { missed_deadline = $5 }
  END {
    printf "%s %s %s %s %s %s %s %s %s %s %s\n", \
      (total ? total : "0"), \
      (janky ? janky : "0"), \
      (pct ? pct : "0.00"), \
      (p50 ? p50 : "0"), \
      (p90 ? p90 : "0"), \
      (p95 ? p95 : "0"), \
      (p99 ? p99 : "0"), \
      (missed_vsync ? missed_vsync : "0"), \
      (slow_ui ? slow_ui : "0"), \
      (high_latency ? high_latency : "0"), \
      (missed_deadline ? missed_deadline : "0")
  }
' "$_gfx_tmp")
rm -f "$_gfx_tmp" 2>/dev/null

set -- $parsed
total_frames="$1"
janky_frames="$2"
janky_pct="$3"
p50_ms="$4"
p90_ms="$5"
p95_ms="$6"
p99_ms="$7"
missed_vsync="$8"
slow_ui="$9"
shift 9
high_latency="$1"
missed_deadline="$2"

avail_b="${avail_before:-0}"
avail_a="${avail_after:-0}"
avail_diff=$((avail_a - avail_b))
psi_b="${psi_before:-0.00}"
psi_a="${psi_after:-0.00}"

# 16. 输出报告
if [ "$OUTPUT_JSON" -eq 1 ]; then
  cat << EOF
{
  "package": "$PKG",
  "events": $EVENTS,
  "throttle_ms": $THROTTLE,
  "seed": $SEED,
  "pct_motion": $PCT_MOTION,
  "pct_touch": $PCT_TOUCH,
  "total_frames": $total_frames,
  "janky_frames": $janky_frames,
  "janky_pct": $janky_pct,
  "p50_ms": $p50_ms,
  "p90_ms": $p90_ms,
  "p95_ms": $p95_ms,
  "p99_ms": $p99_ms,
  "missed_vsync": $missed_vsync,
  "slow_ui": $slow_ui,
  "high_input_latency": $high_latency,
  "missed_deadline": $missed_deadline,
  "mem_avail_before_kb": $avail_b,
  "mem_avail_after_kb": $avail_a,
  "mem_avail_diff_kb": $avail_diff,
  "psi_mem_some_before": "$psi_b",
  "psi_mem_some_after": "$psi_a"
}
EOF
else
  cat << EOF
==============================================================
             RMG MemTonic 应用内滑动压力测试报告
==============================================================
测试应用: $PKG
事件总数: $EVENTS (滑动: $PCT_MOTION%, 点击: $PCT_TOUCH%)
事件节流: ${THROTTLE}ms | 随机种子: $SEED
--------------------------------------------------------------
渲染总帧数 (Total Frames)   : $total_frames
掉帧总数 (Janky Frames)     : $janky_frames ($janky_pct%)
中位数延迟 (50th percentile): $p50_ms ms
90%分位延迟 (90th percentile): $p90_ms ms
95%分位延迟 (95th percentile): $p95_ms ms
99%分位延迟 (99th percentile): $p99_ms ms
错失垂直同步 (Missed Vsync) : $missed_vsync
UI主线程卡顿 (Slow UI)      : $slow_ui
高输入延迟 (High Latency)   : $high_latency
错失帧截止 (Deadline Missed): $missed_deadline
可用内存变化: ${avail_b} KB -> ${avail_a} KB (${avail_diff} KB)
Memory PSI (some avg10): $psi_b% -> $psi_a%
==============================================================
EOF
fi

exit 0
