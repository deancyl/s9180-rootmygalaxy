#!/system/bin/sh
# cpu_guard.sh -- RMG MemTonic CPU 失常护栏 + 崩溃雷达（v1.9.9）
# FR-4: 白名单/前台焦点/桌面/前台服务/top-app cgroup 豁免（FR-11）；风暴期暂停干预。
# FR-5: 旁路监听 dropbox 文件计数，检测 App 崩溃与 ANR。
# FR-11: top-app cgroup 豁免（微信截图处理等合法 CPU 密集工作不应被惩罚）。
# FR-12: 单窗口 CPU > 300% 直接干预，解决脉冲式爆发（如 5270% CPU 进程）漏网问题。
# v1.9.8 功耗优化: cpu_guard scan_cpu_rogue 改为 delta-first——空闲进程跳过 pkg 解析。
# v1.9.9 性能重构（基于分段计时实测）:
#   实测瓶颈定位：is_app_uid 内逐进程 awk 读 /proc/*/status = 956 次 awk × ~17ms = 16s/轮，
#   占扫描墙钟 60%。改为 snapshot_app_pids 一次 awk 批量提取所有 uid>=10000 的 pid 列表，
#   实测单次 awk 全量 = 250ms（提速 65 倍）。整体每轮扫描从 27s → <2s 预期。
#   take_ticks_snapshot 同步重构：改为接收 pid 列表参数，避免重复全盘扫描。

. "$(dirname "$0")/mt_lib.sh"

CPU_SCAN_WIN=60          # 采样窗口（秒）
CPU_ROGUE_THRESH=50      # 触发阈值：连续多窗口 CPU > 50%
CPU_ROGUE_WIN=3          # 触发所需连续高窗口数
CPU_RESTORE_THRESH=20    # 恢复阈值：CPU < 20%
CPU_RESTORE_WIN=2        # 恢复所需连续低窗口数
CPU_EXTREME_THRESH=300   # FR-12: 单窗口 CPU > 300% 直接干预（脉冲式爆发快通道）
ROGUE_LST=$RUN/cpu_rogue_renice.lst
DROPBOX=/data/system/dropbox
DROPBOX_STATE=$RUN/dropbox_state.txt

echo $$ > "$RUN/cpuguard.pid" 2>/dev/null

# ---- FR-4 工具函数 ----

# 读取进程累计 CPU ticks（utime+stime）
cpu_ticks_of() {
  awk '{sub(/^[0-9]+ \([^)]*\) /,""); printf "%d", $12+$13}' /proc/$1/stat 2>/dev/null
}

# 还原所有 CPU 降权记录并清空清单（用于退出清场）
restore_all_rogue() {
  [ -s "$ROGUE_LST" ] || return 0
  while read -r tid on pkg; do
    case "$tid" in ''|*[!0-9]*) continue;; esac
    [ -d /proc/$tid ] || continue
    cur=$(nice_of "$tid"); [ -n "$cur" ] || continue
    renice -n $((on - cur)) -p "$tid" >/dev/null 2>&1
  done < "$ROGUE_LST"
  rm -f "$ROGUE_LST" 2>/dev/null
  logx E "event=cpuguard_exit act=restored_all"
}

# 启动时先补还原上次未完成的 CPU 降权（防止 memtonic 意外崩溃留下残局）
restore_all_rogue

# 对单个毒瘤进程所有可降线程施加 renice +10，写还原清单
rogue_throttle() {
  pid=$1; pkg=$2
  for t in /proc/$pid/task/*; do
    tid=${t##*/}
    on=$(nice_of "$tid")
    case "$on" in ''|*[!0-9-]*) continue;; esac
    [ "$on" -lt 0 ]  && continue  # 高优先级线程（GEMINI.md 铁律：绝不降级）
    [ "$on" -ge 10 ] && continue  # 已是低优，无需重复操作
    if renice -n 10 -p "$tid" >/dev/null 2>&1; then
      echo "$tid $on $pkg" >> "$ROGUE_LST" 2>/dev/null
    fi
  done
  eval "_rogue_${pid}=1"
  eval "_pkg_${pid}=$pkg"   # v1.9.8: 缓存包名，空闲恢复路径免 pkg_of
  logx E "event=cpu_rogue_intervene pid=$pid pkg=$pkg"
}

# 还原单个进程的降权并从清单中移除其记录
rogue_restore_one() {
  pid=$1; pkg=$2
  tmpf="$RUN/cpurogue_tmp_$$"
  while read -r tid on rpkg; do
    case "$tid" in ''|*[!0-9]*) continue;; esac
    if [ "$rpkg" = "$pkg" ]; then
      [ -d /proc/$tid ] || continue
      cur=$(nice_of "$tid"); [ -n "$cur" ] || continue
      renice -n $((on - cur)) -p "$tid" >/dev/null 2>&1
    else
      echo "$tid $on $rpkg" >> "$tmpf" 2>/dev/null
    fi
  done < "$ROGUE_LST" 2>/dev/null
  if [ -f "$tmpf" ]; then
    mv "$tmpf" "$ROGUE_LST" 2>/dev/null
  else
    rm -f "$ROGUE_LST" 2>/dev/null
  fi
  eval "_rogue_${pid}=0"
  eval "_lcnt_${pid}=0"
  # v1.9.0: 清理动态 eval 变量，防止 PID 复用时状态污染新进程（消除 VmData 膨胀）
  # v1.9.8: 一并清理 _pkg_ 缓存
  eval "unset _ticks_${pid} _hcnt_${pid} _pkg_${pid}"
  logx E "event=cpu_rogue_restored pid=$pid pkg=$pkg"

}

# v1.9.9: 单次 awk 批量提取所有 uid>=10000 的 pid（实测 956 次 awk × 17ms = 16s
# vs 单次 awk = 250ms，提速 65 倍）。输出到 stdout，调用方用 $() 捕获。
snapshot_app_pids() {
  awk '
    FNR==1 { pid=""; uid=""; }
    /^Uid:/ { uid=$2+0; next }
    /^$/ {
      if (pid != "" && uid >= 10000) print pid
      pid=""; uid=""
    }
    { next }
  ' /proc/[0-9]*/status 2>/dev/null
}

# 初始快照：记录所有用户进程当前的 CPU ticks 基线
# v1.9.9: 接收 snapshot_app_pids 输出的 pid 列表，避免重复全盘 awk 扫描
take_ticks_snapshot() {
  app_list="${1:-$(snapshot_app_pids)}"
  for pid in $app_list; do
    ticks=$(cpu_ticks_of "$pid"); [ -n "$ticks" ] || continue
    eval "_ticks_${pid}=$ticks"
  done
}

# 主扫描：计算每个用户进程的 CPU% 并按规则决定是否干预/解除
# v1.9.8 功耗优化（delta-first）：先算本窗口 CPU 增量，空闲进程（delta=0）零成本跳过
# pkg 解析与全部豁免判定（历史实测每轮全量 pkg_of ≈ 950 进程 × 3 fork，是本守护
# 主要的 sys CPU 开销），仅活动进程做完整判定。
# 关键不变量保留：基线（_ticks_）在任何 continue 之前更新——豁免/空闲进程同样更新，
# 防止前台切后台时 delta 包含前台全量 CPU 时间。
# v1.9.9 性能重构：先一次 awk 批量拿到 app pid 列表（250ms），再据此循环；
# 替代旧版逐进程 awk /proc/*/status（16s/轮）。
scan_cpu_rogue() {
  focus=$(focused_pkg)
  app_list=$(snapshot_app_pids)
  for pid in $app_list; do
    # v1.9.9: is_app_uid 已在 snapshot_app_pids 内批量完成，此处不再调用
    new_ticks=$(cpu_ticks_of "$pid"); [ -n "$new_ticks" ] || continue
    eval "prev=\${_ticks_${pid}:-}"
    eval "_ticks_${pid}=$new_ticks"
    [ -z "$prev" ] && continue       # 新进程首次出现，仅记录基线
    delta=$((new_ticks - prev))
    [ "$delta" -lt 0 ] && continue   # PID 复用（进程已替换），跳过

    eval "throttled=\${_rogue_${pid}:-0}"

    # v1.9.8: 空闲快路径——delta=0 表示本窗口 0% CPU，
    # 不可能是毒瘤也不可能是极端爆发，跳过昂贵的 pkg_of 与豁免判定。
    if [ "$delta" -eq 0 ]; then
      if [ "$throttled" = "1" ]; then
        # 已干预且已安静：CPU=0 < 恢复阈值，累计恢复窗口（包名取缓存）
        eval "lcnt=\${_lcnt_${pid}:-0}"
        lcnt=$((lcnt + 1))
        eval "_lcnt_${pid}=$lcnt"
        if [ "$lcnt" -ge "$CPU_RESTORE_WIN" ]; then
          eval "pkg=\${_pkg_${pid}:-unknown}"
          rogue_restore_one "$pid" "$pkg"
        fi
      else
        eval "_hcnt_${pid}=0"
      fi
      continue
    fi

    # 活动进程：完整判定（pkg 解析 + 豁免 + 阈值）
    pkg=$(pkg_of "$pid"); [ -n "$pkg" ] || continue

    # 豁免：白名单、前台焦点、桌面、前台服务（音乐/录音/穿戴）
    in_whitelist "$pkg" && continue
    [ "$pkg" = "$focus" ] && continue
    [ "$pkg" = "$LAUNCHER_PKG" ] && continue
    is_foreground_service "$pid" && continue
    # FR-11: top-app cgroup 豁免——内核认为的最高优先级进程，不惩罚其合法 CPU 使用
    # 场景：微信截图后后台 AI 解码/QR 识别、浏览器 JIT 编译等
    is_in_top_app_cgroup "$pid" && continue

    cpu_pct=$((delta * 100 / (CLK_TCK * CPU_SCAN_WIN)))

    # FR-12: 极端毒瘤快通道——单窗口 CPU > 300% 直接干预，无需等待 3 个连续窗口
    # 解决脉冲式爆发进程（每次 5000%+ 但持续时间短）通过 hcnt 归零永远漏网的问题
    eval "throttled_ex=\${_rogue_${pid}:-0}"
    if [ "$throttled_ex" = "0" ] && [ "$cpu_pct" -ge "$CPU_EXTREME_THRESH" ]; then
      logx E "event=cpu_extreme_intervene pid=$pid pkg=$pkg cpu=${cpu_pct}% threshold=$CPU_EXTREME_THRESH"
      rogue_throttle "$pid" "$pkg"
      eval "_hcnt_${pid}=0"
      continue
    fi

    eval "throttled=\${_rogue_${pid}:-0}"

    if [ "$throttled" = "0" ]; then
      # 未干预：判断是否达到毒瘤阈值
      eval "hcnt=\${_hcnt_${pid}:-0}"
      if [ "$cpu_pct" -ge "$CPU_ROGUE_THRESH" ]; then
        hcnt=$((hcnt + 1))
        eval "_hcnt_${pid}=$hcnt"
        logx W "warn=cpu_rogue_candidate pid=$pid pkg=$pkg cpu=${cpu_pct}% window=$hcnt/$CPU_ROGUE_WIN"
        if [ "$hcnt" -ge "$CPU_ROGUE_WIN" ]; then
          rogue_throttle "$pid" "$pkg"
          eval "_hcnt_${pid}=0"
        fi
      else
        eval "_hcnt_${pid}=0"
      fi
    else
      # 已干预：判断是否可以解除
      eval "lcnt=\${_lcnt_${pid}:-0}"
      if [ "$cpu_pct" -lt "$CPU_RESTORE_THRESH" ]; then
        lcnt=$((lcnt + 1))
        eval "_lcnt_${pid}=$lcnt"
        if [ "$lcnt" -ge "$CPU_RESTORE_WIN" ]; then
          rogue_restore_one "$pid" "$pkg"
        fi
      else
        eval "_lcnt_${pid}=0"
      fi
    fi
  done
}

# ---- FR-5 崩溃雷达工具函数 ----

# 初始化 dropbox 文件计数基线
init_dropbox_state() {
  [ -d "$DROPBOX" ] || return 0
  {
    for tag in SYSTEM_TOMBSTONE system_app_crash system_app_anr system_server_crash; do
      cnt=$(ls "$DROPBOX" 2>/dev/null | grep -c "^${tag}@")
      echo "$tag $cnt"
    done
  } > "$DROPBOX_STATE" 2>/dev/null
}

# 检查 dropbox 文件计数变化，发现新崩溃/ANR 即记录日志
check_dropbox() {
  [ -d "$DROPBOX" ] || return 0
  if [ ! -f "$DROPBOX_STATE" ]; then
    init_dropbox_state
    return 0
  fi
  changed=0
  for tag in SYSTEM_TOMBSTONE system_app_crash system_app_anr system_server_crash; do
    new_cnt=$(ls "$DROPBOX" 2>/dev/null | grep -c "^${tag}@")
    old_cnt=0
    while read -r t c; do
      [ "$t" = "$tag" ] && { old_cnt=$c; break; }
    done < "$DROPBOX_STATE"
    if [ "$new_cnt" -gt "$old_cnt" ]; then
      logx E "event=crash_detected type=$tag new_count=$((new_cnt - old_cnt)) total=$new_cnt"
      changed=1
    fi
  done
  [ "$changed" = "1" ] && init_dropbox_state
}

# ---- 初始化 ----
init_dropbox_state
# v1.9.9: 启动时先批量拿一次 app_pids，take_ticks_snapshot 与 scan_cpu_rogue 共用
_init_app_list=$(snapshot_app_pids)
take_ticks_snapshot "$_init_app_list"

# ---- 主循环 ----
while kill -0 "$PPID" 2>/dev/null; do
  sleep $CPU_SCAN_WIN
  check_root_liveness
  check_dropbox          # FR-5：每 60s 检查崩溃/ANR 事件

  # 清理已死亡的降权线程，防止内存泄漏 (Dead Thread Leak)
  if [ -s "$ROGUE_LST" ]; then
    tmpf="$RUN/cpurogue_tmp_clean_$$"
    while read -r tid on rpkg; do
      if [ -d "/proc/$tid" ]; then
        echo "$tid $on $rpkg" >> "$tmpf" 2>/dev/null
      else
        eval "unset _ticks_${tid} _hcnt_${tid} _rogue_${tid} _lcnt_${tid}"
      fi
    done < "$ROGUE_LST"
    if [ -f "$tmpf" ]; then mv "$tmpf" "$ROGUE_LST" 2>/dev/null; else rm -f "$ROGUE_LST" 2>/dev/null; fi
  fi

  # 风暴护栏活动期：刷新 CPU 基线快照但暂停干预（启动高负载期不误判）
  if [ -d "$STORM_FLAG" ]; then
    take_ticks_snapshot "$(snapshot_app_pids)"
    continue
  fi

  t_scan0=$(now_ms)
  scan_cpu_rogue         # FR-4：扫描并处置 CPU 毒瘤（v1.9.8: delta-first 低开销）
  logx S "act=cpu_scan done_ms=$(( $(now_ms) - t_scan0 ))"
done

# 守护进程已死：清场还原全部 CPU 降权
restore_all_rogue
rm -f "$RUN/cpuguard.pid" 2>/dev/null
exit 0
