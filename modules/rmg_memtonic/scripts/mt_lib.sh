#!/system/bin/sh
# mt_lib.sh —— RMG MemTonic 公共库（v1.3.0）
# 仅供 memtonic.sh（守护主进程）与 storm_guard.sh（护栏子进程）source 使用。
# 本文件不包含任何顶层执行语句——被直接执行时应立即退出。
#
# 结构说明（v1.3.0 重构教训）：Android 16 的 mksh 后台化"shell 函数"会瞬时死亡
# （实测矩阵：直接子壳 & 可靠，函数 & 必死），因此护栏必须是独立外部脚本；
# 公共函数与常量抽到本库供两个进程 source，避免复制。

MODDIR=/data/adb/modules/rmg_memtonic
RUN=$MODDIR/run          # 运行时私有目录（root 700）
LOG=$RUN/memtonic.log    # 审计日志（超 256KB 字节基准截断）
PIDF=$RUN/memtonic.pid   # 守护进程记录，格式 "pid:进程启动时间"
GUARD_PIDF=$RUN/guard.pid
LOCK=$RUN/lock           # 维护互斥锁（mkdir 原子锁，含陈旧锁回收）
STORM_FLAG=$RUN/storm_active   # 护栏窗口活动标志（目录）
RLST=/data/local/tmp/memtonic_storm_renice.lst  # 还原清单（tid 原nice 包名）
ZRAM=/sys/block/zram0

RECOMPRESS=0
EMERG=0
FULL_INTERVAL=14400
CHECK_INTERVAL=3600
NIGHT_DROP_BELOW=2000000
EMERG_AVAIL=1200000
STORM_WINDOW=480
STORM_POLL=5
STORM_SCAN=15
STORM_SSPID_FRESH=180
STORM_EXIT_PSI=10
STORM_NICE_APP=5
LAUNCHER_NICE=-4
LAUNCHER_PKG=com.sec.android.app.launcher
# 白名单：GKD、NoActive、Scene、Brevent、Rikka 等用户明确要保的服务
# （前缀匹配；root/system 进程本就被 uid 过滤排除，无需列在这里）
# v1.4.0 补充（真实软重启 01:00 窗口实证波及）：com.catalinagroup.（HK 通话录音
# 及其 helper）、com.nutomic.（syncthing）、com.wangc.（记账）——均被风暴削峰过
WHITELIST_PKGS="li.songe.gkd cn.myflv.noactive com.omarea me.piebridge.brevent rikka. com.catalinagroup. com.nutomic. com.wangc."

CLK_TCK=$(getconf CLK_TCK 2>/dev/null)
case "$CLK_TCK" in ''|*[!0-9]*|0) CLK_TCK=100;; esac

# logcat 镜像必须用绝对路径调用系统二进制：
# 写 "log -t MemTonic" 时第一个词会命中本文件的 log() 函数（shell 函数优先于
# PATH），导致无限递归——v1.2.1 已埋雷（fallback 分支未触发所以没炸），v1.3.0
# 首版两次引爆（日志 146MB / 守护卡死）。教训：镜像一律走 /system/bin/log。
KLOG="/system/bin/log -t MemTonic"

# ---- 日志 ----
# logx <级别> <内容>：L=E/A/W/X 同步镜像 logcat（tag MemTonic）；L=S 仅写文件。
# 文件写失败时整行降级到 logcat；超 256KB 截断（字节基准，见下）。
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
    # 字节基准截断：行基准 tail -n 在"单行巨大"时无法缩容（v1.3.0 实测教训）
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
  [ -n "$1" ] && [ -d /proc/$1 ] && grep -q memtonic /proc/$1/cmdline 2>/dev/null
}

# 是否熄屏：真机实测本机熄屏态为 mWakefulness=Dozing（三星特性，非 Asleep）
screen_off() {
  dumpsys power 2>/dev/null | grep -qE 'mWakefulness=(Asleep|Dozing)'
}

# 进程启动时间（/proc/pid/stat 第 22 字段），用于 PID 复用防护
pid_starttime() { awk '{print $22}' /proc/$1/stat 2>/dev/null; }

# pkg_of <pid>：应用包名（cmdline 首段，去掉 :子进程后缀）
pkg_of() { tr -d '\0' < /proc/$1/cmdline 2>/dev/null | cut -d: -f1; }

# is_app_uid <pid>：uid>=10000（u0_a* 应用）时回显 uid，否则输出空
is_app_uid() {
  u=$(awk '/^Uid/{print $2;exit}' /proc/$1/status 2>/dev/null)
  case "$u" in ''|*[!0-9]*) return;; esac
  [ "$u" -ge 10000 ] && echo "$u"
}

# nice_of <pid或tid>：/proc/<t>/stat 第 19 字段
nice_of() { awk '{print $19}' /proc/$1/stat 2>/dev/null; }

# now_ms：毫秒时间戳（/proc/uptime 小数点后两位，秒级 date 不够用）
# v1.4.0 新增：storm_end 记录 scan_ms/restore_ms，归因窗口超限（实测 480 上限被
# 突破至 619s——扫描/还原未分别计时，无法归因）
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

# renice_tree <pid> <目标nice> <pkg> <仅限nice0:0|1>
# 遍历进程全部线程（nice 粒度是线程而非进程组），逐 tid 设置并记录还原清单。
# renice 失败静默跳过该 tid（不重试、不刷日志）。
renice_tree() {
  pid=$1; tn=$2; pkg=$3; only0=$4
  for t in /proc/$pid/task/*; do
    tid=${t##*/}
    on=$(nice_of "$tid")
    case "$on" in ''|*[!0-9-]*) continue;; esac
    [ "$on" = "$tn" ] && continue
    [ "$only0" = "1" ] && [ "$on" != "0" ] && continue
    # toybox renice -n 是"相对增量"而非绝对值（压力测试 run2 实测：
    # 还原 -n 0 时 nice 5+0=5 纹丝不动）——用 delta 换算成绝对目标
    if renice -n $((tn - on)) -p "$tid" >/dev/null 2>&1; then
      # 格式：tid 原 nice 我们设置的值 包名（四字段，还原时校验第三字段）
      echo "$tid $on $tn $pkg" >> "$RLST" 2>/dev/null
    fi
  done
}

# storm_restore_pending <原因标签>：还原清单里所有 tid 到原 nice
# tid 已消失 = 进程已退出（无需还原）；当前 nice ≠ 我们设置的值 = 第三方
# （Android 前台调度等）已接管该线程——跳过还原，绝不与系统调度互殴
#（压力测试 run1 实测发现 launcher 主线程会被系统动态调到 -10）
storm_restore_pending() {
  [ -s "$RLST" ] || return 0
  ok=0; skip=0; fail=0; chg=0
  while read -r tid on ap pkg; do
    case "$tid" in ''|*[!0-9]*) continue;; esac
    if [ ! -d /proc/$tid ]; then
      skip=$((skip+1)); continue
    fi
    case "$ap" in ''|*[!0-9-]*) continue;; esac
    # v1.4.0：变量改名 r_cur——曾用名 cur 是全局变量，窗口结束还原后会覆盖
    # 护栏主循环的 cur，导致 base=$cur 存入 nice 值而非 system_server PID，
    # 同一 sspid 级联重开 4-11 轮风暴窗口（2026-09-28 两次真实软重启实证 16 窗；
    # 沙箱 mt_curtest.sh CASE3 实证覆盖）。护栏主循环同时已改为窗口前先存 base。
    r_cur=$(nice_of "$tid")
    if [ "$r_cur" != "$ap" ]; then
      chg=$((chg+1))
      logx W "err=restore_skipped_changed tid=$tid pkg=$pkg ours=$ap now=$r_cur"
      continue
    fi
    if renice -n $((on - ap)) -p "$tid" >/dev/null 2>&1; then
      ok=$((ok+1))
    else
      fail=$((fail+1))
      logx X "err=restore_failed tid=$tid pkg=$pkg nice=$on"
    fi
  done < "$RLST"
  rm -f "$RLST" 2>/dev/null
  logx A "act=restore reason=$1 ok=$ok skipped_exit=$skip changed_3rd_party=$chg failed=$fail"
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
  # 关键：窗口开启瞬间把所有【预存】进程记入已处理名单——护栏只对窗口内
  # 新启动的进程动手（否则 SystemUI/GMS 等常驻应用会在第一轮被误削峰）
  done_pids=" "
  for d in /proc/[0-9]*; do done_pids="$done_pids${d##*/} "; done
  psi_low=0
  while [ "$(date +%s)" -lt "$end" ]; do
    sleep $STORM_SCAN
    # 提前退出：CPU 压力连续 3 次低于阈值
    # 注意：PSI 值带小数（如 2.74），必须先截断小数再判数字——否则小数点命中
    # *[!0-9]* 模式被当成非法值（=99），提前退出永不触发（v1.3.0 压力测试发现的
    # 生产级 Bug：窗口总是跑满 480 秒）
    p=$(psi_val cpu some)
    p=${p%%.*}
    case "$p" in ''|*[!0-9]*) p=99;; esac
    if [ "$p" -lt "$STORM_EXIT_PSI" ]; then psi_low=$((psi_low+1)); else psi_low=0; fi
    [ "$psi_low" -ge 3 ] && break
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
        # v1.4.0：白名单跳过留痕（S 级仅写文件，不刷 logcat）——生产日志此前
        # 无法区分"被白名单保护"与"恰好未出现"，保护机制不可观测
        logx S "act=whitelist_skip pid=$pid pkg=$pkg"
        done_pids="$done_pids$pid "; continue
      fi
      [ "$pkg" = "$focus" ] && { done_pids="$done_pids$pid "; continue; }
      [ "$(nice_of "$pid")" = "0" ] || { done_pids="$done_pids$pid "; continue; }
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
  logx E "event=storm_end reason=$reason duration=$(( $(date +%s) - t0 )) app_renice=$n_app launcher_boost=$n_launcher psi_exit=$([ "$psi_low" -ge 3 ] && echo yes || echo no) scan_ms=${last_scan_ms:-NA} restore_ms=${restore_ms:-NA}"
}

# 直接执行本库文件时退出（防止误运行）
if [ "$(basename "$0")" = "mt_lib.sh" ]; then
  echo "mt_lib.sh 是公共库，请运行 memtonic.sh"; exit 1
fi
