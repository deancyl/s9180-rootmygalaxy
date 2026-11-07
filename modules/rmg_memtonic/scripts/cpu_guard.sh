#!/system/bin/sh
# cpu_guard.sh -- RMG MemTonic CPU 失常护栏 + 崩溃雷达（v1.13.15）
# v1.13.12 (FR-RN1 hardening): P0/P1 五缺陷修复——
#   P0-1: rayneo_restore_all/dead-entry 清理逐条 Tgid 归属校验（/proc/<tid>/status 的
#         Tgid 字段必须等于当前 RayNeo pid；注意 Tgid 不在 stat 文件中——stat 字段 5
#         是 pgrp）。tid 是全局递增可复用资源：进程死亡后旧 tid 可被无关进程复用，
#         仅存在性检查会误伤无辜线程（10-04 审计实弹发现）。进程已死时活 tid=复用 →
#         全部跳过（死线程 nice 随 task_struct 释放，无需还原）。
#   P0-2: 眼镜活跃判据重构——手机屏幕焦点≠眼镜使用状态（投屏场景手机焦点在
#         NotificationShade 等无关窗口）。改用 /proc/<rpid>/oom_score_adj ≤300 探针：
#         top(0)/visible/FGS(perceptible~100-200)/previous 均为低 adj；纯后台 cached
#         为 900+。零 dumpsys 成本，失败安全方向=漏治理不误伤。
#   P1-3: 风暴期 governor 可达——原挂载点在 scan_cpu_rogue 尾部，主循环 STORM continue
#         整轮跳过导致风暴期连还原都不可达。主循环 STORM 分支改为轻量调用
#         rayneo_governor "" storm（仅判定+还原+死条目清理，不新增降权）。
#   P1-5: memo 激活态门控——AlwaysOnAiRunti(VAD) 线程存在时不降权。11-04 实测：
#         激活期 59% CPU 大头为 spdy-0/ACCS/process-memory/HeapTask（不在名单或
#         不可触碰），名单治理上限仅 ~8-10%，误伤面反而扩大。激活期仅保留
#         fluency_shield 既有护航；memo 从激活→未激活切换时自动还原。
# v1.13.10: FR-11 例外升级——fg-service CPU 大户核亲和约束（替代无条件豁免）。
#   缘起：11-01 实测 Syncthing 200% + 群晖相册 209% 双备份马拉松，前台服务豁免
#   让 200% 级大户免检。约束手段用核亲和（cpuset background=小核 0-2）而非降权：
#   大核立即还给前台，任务变慢但不中断，零优先级冲突，可逆（还原原始组）。
#   安全边界：焦点应用/相机/截屏/风暴期永不约束；top-app cgroup 豁免保持；
#   约束上限：CPU<20%×2 窗口自动还原；用户打开被约束应用立即还原。
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
# v1.10.0: 内存风暴探针 mem_probe 挂载本循环（60s 粒度零新增唤醒）：
#   P1-1 常态监测 psi_mem（内建 read 零 fork）；P0-2 连续 2 轮 some≥25 落灾难黑匣子
#   （冷却 900s + 日限 10 份 + 轮转 5 份）；P0-1 风暴级亮屏压实例外（some≥30，共用
#   last_compact.ts 900s 冷却，相机/截屏/启动风暴守卫无条件生效）；P2 前台 majflt
#   差分指纹（≥500/60s 记预警，10min 限频）。

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

# v1.10.0: 内存风暴探针参数
MEM_BB_THRESH=25      # P0-2 快照触发：psi_mem some avg10 ≥ 25（风暴级，日常亮屏通常 <10）
MEM_BB_ROUNDS=2       # 连续轮数（60s/轮 → 持续 2 分钟才算风暴）
MEM_BB_COOL=900       # 快照冷却（秒）
MEM_BB_DAYMAX=10      # 每日快照上限（最坏 10 份 × ~5KB/天）
MEM_CMPCT_THRESH=30   # P0-1 风暴级亮屏压实门槛（psi_mem some avg10，铁律例外唯一通道）
CMPCT_COOL=900        # 压实冷却：与 memtonic R3 共用 last_compact.ts，全局统一 900s
FG_MFLT_RATE=500      # P2 前台 majflt 增速预警（次/60s 窗口，转码类负载指纹级别）

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
# v1.13.11 (FR-RN1): 雷鸟全天智记后台治理——Flutter 渲染/池线程降权。
# 背景：全天智记（眼镜拾音+VAD+转写）后台运行时客户端 52% CPU（实测 22s 差分），
# 主线程 20%（memo 计算不可动）+ pool 线程 20-25%（churn+异步工作）+ raster 偶发。
# 设计：仅降「浪费线程」（raster/pool/dispatch/dartworker/executor/AMap）至 +10，
# 【绝不触碰】主线程、AlwaysOnAiRunti(VAD)、音频线程、process-memory(GC 安全)。
# GEMINI 铁律：nice ≤-10 的线程跳过（DartWorker 6542 实测 -10 在保护线内）。
# 触发：后台（非焦点）即降权（幂等，新 churn 线程下轮补齐）；焦点/进程死亡/disable
# flag → 全量还原；守护启动时自愈上一轮残留。通知：每 episode 一次。
# v1.13.12 判定链顺序（顺序不可交换）：disable flag → 进程存在 → memo 激活（P1-5）
# → 眼镜活跃（P0-2）→ 死条目 Tgid 清理（P0-1）→ [storm 模式止步（P1-3）] → 降权循环。
# memo 检查必须在 adj 检查之前：memo 激活必有 FGS → adj 低，adj 先行会短路 memo 门控。
RAYNEO_PKG="com.rayneo.venus.pub"
RN_STATE=$RUN/rayneo_governor.lst
RAYNEO_TARGET_NICE=10
RAYNEO_MEMO_THREAD="AlwaysOnAiRunti"   # v1.13.12(P1-5): VAD 载体线程名（comm 截断 15 字符）
RN_ACTIVE_ADJ_MAX=300                  # v1.13.12(P0-2): top/visible/FGS/perceptible 判活阈
rayneo_restore_all() {
  [ -s "$RN_STATE" ] || return 0
  _rn=0
  _rnrp=$(pidof "$RAYNEO_PKG" 2>/dev/null | awk '{print $1}')
  while read -r tid on comm; do
    [ -d "/proc/$tid" ] || continue
    _tg=$(awk '/^Tgid:/{print $2; exit}' "/proc/$tid/status" 2>/dev/null)
    case "$_tg" in ''|*[!0-9]*) continue ;; esac
    # P0-1: Tgid 归属校验——进程已死（_rnrp 空）或 tid 已复用至其他进程 → 跳过不还原
    { [ -n "$_rnrp" ] && [ "$_tg" = "$_rnrp" ]; } || continue
    cur=$(nice_of "$tid"); [ -n "$cur" ] || continue
    renice -n $((on - cur)) -p "$tid" >/dev/null 2>&1 && _rn=$((_rn+1))
  done < "$RN_STATE"
  rm -f "$RN_STATE" 2>/dev/null
  rm -f "$RUN/rayneo_notified" 2>/dev/null
  logx A "act=rayneo_restore restored=$_rn msg=雷鸟回前台或旁路_渲染池线程优先级已还原_Tgid归属校验防误伤"
  return 0
}
# v1.13.12(P1-5): memo 激活态——VAD 载体线程存在即全天智记运行中。依赖调用方已设 rpid。
# v1.13.13 (P2-A): memo 探针零 fork 化——11-05 性能回归根因修复。
#   旧实现每轮遍历 ~181-221 个 RayNeo 线程，对每个线程 `$(cat comm)` 都会 fork 一次；
#   换页风暴（20-98 万 majflt/60s）下 fork 成本暴涨，cpu_scan 由 160-240ms 升至
#   1770-13010ms。A/B 铁证：恢复旁路 flag 后回落到 210-220ms 而 CPU PSI 未同步下降。
#   改为 mksh 内建 `IFS= read -r`（v1.13.2 耗电治理已验证的零 fork 范式），
#   判定语义、名单、铁律、Tgid 归属校验全部不变。
rayneo_memo_active() {
  for _t in /proc/$rpid/task/*; do
    [ -r "$_t/comm" ] || continue
    IFS= read -r _rn_comm < "$_t/comm" 2>/dev/null || continue
    case "$_rn_comm" in "$RAYNEO_MEMO_THREAD"*) return 0 ;; esac
  done
  return 1
}
# v1.13.12(P0-2): 眼镜活跃——手机焦点=RayNeo 或进程可感知（oom_score_adj≤300，
# top=0/visible/FGS perceptible≈100-200/纯后台 cached 900+）。失败安全=漏治理不误伤。
rayneo_eyewear_active() {
  [ "$_rn_focus" = "$RAYNEO_PKG" ] && return 0
  _adj=$(cat "/proc/$rpid/oom_score_adj" 2>/dev/null)
  case "$_adj" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_adj" -le "$RN_ACTIVE_ADJ_MAX" ]
}
rayneo_governor() {
  _rn_focus=$1
  _rn_mode=${2:-full}
  if [ -f "$RUN/disable_rayneo_guard" ]; then rayneo_restore_all; return 0; fi
  rpid=$(pidof "$RAYNEO_PKG" 2>/dev/null | awk '{print $1}')
  if [ -z "$rpid" ]; then rayneo_restore_all; return 0; fi
  if rayneo_memo_active; then rayneo_restore_all; return 0; fi
  if rayneo_eyewear_active; then rayneo_restore_all; return 0; fi
  if [ -s "$RN_STATE" ]; then
    _rntmp="$RUN/rn_tmp_clean_$$"
    while read -r tid on comm; do
      if [ -d "/proc/$tid" ]; then
        # P0-1: 死条目清理同样带 Tgid 归属校验
        _tg=$(awk '/^Tgid:/{print $2; exit}' "/proc/$tid/status" 2>/dev/null)
        [ "$_tg" = "$rpid" ] && echo "$tid $on $comm" >> "$_rntmp" 2>/dev/null
      fi
    done < "$RN_STATE"
    if [ -f "$_rntmp" ]; then mv "$_rntmp" "$RN_STATE" 2>/dev/null; else rm -f "$RN_STATE" 2>/dev/null; fi
  fi
  [ "$_rn_mode" = "storm" ] && return 0   # P1-3: 风暴期止步——还原/清理可达，不新增降权
  _rn_new=0
  for t in /proc/$rpid/task/*; do
    tid=${t##*/}
    IFS= read -r comm < "$t/comm" 2>/dev/null || continue   # v1.13.13: 零 fork（原 cat 子进程）
    case "$comm" in
      *raster*|pool-*|DefaultDispatch*|DartWorker*|DefaultExecutor*|AMap*) ;;
      *) continue ;;
    esac
    grep -q "^$tid " "$RN_STATE" 2>/dev/null && continue
    on=$(nice_of "$tid"); case "$on" in ''|*[!0-9-]*) continue;; esac
    [ "$on" -le -10 ] && continue
    [ "$on" -ge "$RAYNEO_TARGET_NICE" ] && continue
    renice -n $((RAYNEO_TARGET_NICE - on)) -p "$tid" >/dev/null 2>&1 || continue
    echo "$tid $on $comm" >> "$RN_STATE" 2>/dev/null
    logx I "act=rayneo_thread_demote tid=$tid comm=$comm nice=$on→10 msg=全天智记后台渲染池线程降权_音频与VAD不碰"
    _rn_new=$((_rn_new+1))
  done
  if [ "$_rn_new" -gt 0 ] && [ ! -f "$RUN/rayneo_notified" ]; then
    touch "$RUN/rayneo_notified" 2>/dev/null
    notify_alert rayneo "MemTonic: 雷鸟全天智记后台渲染线程已降权省电（memo功能不受影响，切回前台自动还原）"
  fi
  return 0
}

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

    # v1.13.10: 被约束的应用成为焦点 → 立即还原（用户正在使用，交还大核）
    eval "aff=\${_aff_${pid}:-0}"
    if [ "$aff" = "1" ] && [ "$pkg" = "$focus" ]; then
      affinity_restore_one "$pid" "$pkg"
      eval "_aff_${pid}=0"
    fi

    # v1.12.7: 相机/图库不再无条件豁免。 Samsung 相机或图库退到后台后
    # 仍可能持有相机链路并产生 200%+ CPU；此时必须接受毒瘤扫描。
    # 其他应用在前台调用相机时，焦点/top-app cgroup/前台服务豁免仍然生效。
    if [ -f "$CAMERA_ACTIVE_FLAG" ]; then
      case "$pkg" in
        com.sec.android.app.camera|com.sec.android.gallery3d) continue ;;
      esac
    fi
    in_whitelist "$pkg" && continue
    [ "$pkg" = "$focus" ] && continue
    [ "$pkg" = "$LAUNCHER_PKG" ] && continue
    is_foreground_service "$pid"; _is_fgs=$?
    if [ "$_is_fgs" -eq 0 ]; then
      # v1.13.10: FR-11 例外升级——fg-service 大户核亲和约束（替代无条件豁免）。
      # top-app cgroup 豁免保持（内核认定的最高优先级进程不约束：微信扫码/JIT 等）。
      is_in_top_app_cgroup "$pid" && continue
      cpu_pct=$((delta * 100 / (CLK_TCK * CPU_SCAN_WIN)))
      if [ "$aff" = "1" ]; then
        # 已约束：CPU 回落 < 20% ×2 窗口 → 解除还原
        eval "alcnt=\${_alcnt_${pid}:-0}"
        if [ "$cpu_pct" -lt "$CPU_RESTORE_THRESH" ]; then
          alcnt=$((alcnt + 1))
          eval "_alcnt_${pid}=$alcnt"
          if [ "$alcnt" -ge "$CPU_RESTORE_WIN" ]; then
            affinity_restore_one "$pid" "$pkg"
            eval "_aff_${pid}=0"
            eval "_alcnt_${pid}=0"
          fi
        else
          eval "_alcnt_${pid}=0"
        fi
        continue
      fi
      if [ "$cpu_pct" -ge "$CPU_ROGUE_THRESH" ]; then
        eval "affh=\${_affh_${pid}:-0}"
        affh=$((affh + 1))
        eval "_affh_${pid}=$affh"
        if [ "$affh" -ge "$CPU_ROGUE_WIN" ]; then
          affinity_constrain_one "$pid" "$pkg"
          eval "_aff_${pid}=1"
          eval "_affh_${pid}=0"
        fi
        continue
      fi
      eval "_affh_${pid}=0"
      continue
    fi
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

  # v1.13.11 (FR-RN1): 雷鸟全天智记后台治理——复用本函数的 $focus 上下文
  rayneo_governor "$focus"
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
      update_module_desc   # v1.11.0: 崩溃雷达即时刷新卡片描述
      changed=1
    fi
  done
  [ "$changed" = "1" ] && init_dropbox_state
}

# ---- v1.10.0 内存风暴探针 ----

# 风暴级亮屏压实（GEMINI 铁律的唯一例外通道）
# 调用前置条件：P_S10 ≥ MEM_CMPCT_THRESH（本函数不再重复验证压力）。
# 守卫（无条件生效，一个都不能少）：
#   相机活跃 / 截屏处理 —— 压实掉帧不可接受，与 memtonic maintenance 同源 flag；
#   启动风暴期 —— 护栏正在 renice 让路，不添乱；
#   $LOCK 互斥 —— 与 memtonic maintenance（息屏路径）共用 mkdir 原子锁，抢不到就跳过本轮；
#   last_compact.ts —— 两条压实路径共用冷却时间戳，防叠加。
# v1.13.9 (P-A): 内存余量预测器——把「灾难后报」变成「灾难前预警」。
# 触发（连续 MF_CONFIRM 轮确认，防瞬时抖动）：MemAvailable < 2.5GB 且 SwapUsed > 7.5GB
# （11-01 午间实证：avail 3.4→2.0GB 斜率 + swap 6→8.6GB 爬升 = 12:46 灾难峰确定性前兆，
# 预测窗口比灾难峰早 1h+）。动作：通知（2h 限频）+ 落 mem_forecast.flag（前置压实
# 与 WebUI 的信号源）。解除（滞后带）：MemAvailable ≥ 3GB。稳态成本：每 60s 一次
# /proc/meminfo 读（<1ms），无轮询新增。
MF_ON_AVAIL=2560000       # 2.5GB
MF_ON_SWAP=7680000        # 7.5GB
MF_OFF_AVAIL=3072000      # 3GB（滞后带）
MF_CONFIRM=3              # 连续 3 轮确认（60s 节奏 = 3 分钟）
mem_forecast() {
  _mf=$(awk '/MemAvailable/{a=$2}/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print a+0, (t-f)+0}' /proc/meminfo 2>/dev/null)
  set -- $_mf
  _av=$1; _sw=$2
  case "$_av" in ''|*[!0-9]*) return 0;; esac
  case "$_sw" in ''|*[!0-9]*) _sw=0;; esac
  if [ "$_av" -lt "$MF_ON_AVAIL" ] && [ "$_sw" -gt "$MF_ON_SWAP" ]; then
    _mf_c=$(cat "$RUN/mf_confirmed" 2>/dev/null); case "$_mf_c" in ''|*[!0-9]*) _mf_c=0;; esac
    _mf_c=$((_mf_c + 1))
    echo "$_mf_c" > "$RUN/mf_confirmed" 2>/dev/null
    if [ "$_mf_c" -ge "$MF_CONFIRM" ] && [ ! -f "$RUN/mem_forecast.flag" ]; then
      echo "avail_kb=$_av swap_kb=$_sw ts=$(date '+%m-%d %H:%M:%S')" > "$RUN/mem_forecast.flag" 2>/dev/null
      logx E "warn=mem_forecast avail_kb=$_av swap_kb=$_sw msg=内存余量告急_未来1-2h可能严重卡顿_建议关闭后台大型应用或择机软重启"
      notify_alert forecast "MemTonic: 内存余量告急（可用$((_av/1024))MB、swap满载）——未来1-2h可能严重卡顿，建议关闭后台大型应用或择机软重启"
    fi
  else
    echo 0 > "$RUN/mf_confirmed" 2>/dev/null
    if [ "$_av" -ge "$MF_OFF_AVAIL" ] && [ -f "$RUN/mem_forecast.flag" ]; then
      rm -f "$RUN/mem_forecast.flag" 2>/dev/null
      logx I "act=mem_forecast_clear avail_kb=$_av msg=余量恢复_预测清除"
    fi
  fi
  return 0
}

# v1.13.10: 核亲和约束工具（FR-11 例外升级的动作端）
# AFF_LST 记录被约束进程的原始 cpuset 组（还原依据）；死进程条目自动清理。
AFF_LST=$RUN/affinity_constrained.lst
affinity_constrain_one() {
  pid=$1; pkg=$2
  grep -q "cpuset:/background" "/proc/$pid/cgroup" 2>/dev/null && return 0
  # v1.13.10 修正: cgroup 行为冒号分隔无空格（4:cpuset:/），须 cut -d: 取第 3 段——
  # awk $NF 会把整行当路径（实弹往返实测还原拼出 /dev/cpuset/4:cpuset://tasks 失败）
  orig=$(grep "cpuset:" "/proc/$pid/cgroup" 2>/dev/null | head -n 1 | cut -d: -f3)
  [ -n "$orig" ] || return 0
  echo "$pid" > /dev/cpuset/background/tasks 2>/dev/null || return 0
  grep -q "cpuset:/background" "/proc/$pid/cgroup" 2>/dev/null || return 0
  echo "$pid $pkg $orig" >> "$AFF_LST" 2>/dev/null
  logx E "event=cpu_affinity_constrain pid=$pid pkg=$pkg orig=$orig msg=前台服务CPU大户_核亲和约束至小核(0-2)_大核还前台"
  notify_alert affinity "MemTonic: $pkg 后台任务占用过高CPU——已约束至小核（前台保大核），任务变慢不中断；可在应用内暂停"
  return 0
}
affinity_restore_one() {
  pid=$1; pkg=$2
  orig=$(grep "^$pid $pkg " "$AFF_LST" 2>/dev/null | awk '{print $3}' | head -n 1)
  [ -n "$orig" ] || return 0
  echo "$pid" > "/dev/cpuset/$orig/tasks" 2>/dev/null
  sed -i "\|^$pid $pkg |d" "$AFF_LST" 2>/dev/null
  logx A "act=cpu_affinity_restore pid=$pid pkg=$pkg cpuset=$orig msg=CPU回落或用户使用_核亲和已还原"
  return 0
}

do_fg_compact() {
  if [ -f "$CAMERA_ACTIVE_FLAG" ] || [ -f "$SCREENSHOT_ACTIVE_FLAG" ] || [ -d "$STORM_FLAG" ]; then
    return 0
  fi
  # v1.10.0 自审修正：陈旧锁回收——stop 路径 kill -9 cpu_guard 若恰逢压实行进中，
  # $LOCK 残留会使本路径永久静默失效（maintenance 有回收逻辑，但息屏条件不满足时
  # 长期不触发）。与 maintenance 同款：持锁 pid 已死则回收重试一次。
  if ! mkdir "$LOCK" 2>/dev/null; then
    lp=$(cat "$LOCK/pid" 2>/dev/null)
    if alive "$lp"; then return 0; fi
    rm -rf "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || { logx W "act=fg_compact result=fail note=无法获取锁"; return 0; }
  fi
  echo $$ > "$LOCK/pid" 2>/dev/null
  echo "$(date +%s)" > "$RUN/last_compact.ts" 2>/dev/null
  if echo 1 > /proc/sys/vm/compact_memory 2>/dev/null; then
    logx W "act=fg_compact psi_mem_some10=${P_S10}% result=ok note=风暴级例外_psi≥$MEM_CMPCT_THRESH_亮屏铁律放行"
    update_module_desc   # v1.11.0: 压实即时刷新卡片描述
  else
    logx W "act=fg_compact result=fail note=compact_memory写入失败"
  fi
  rm -rf "$LOCK" 2>/dev/null
}

# 每 60s 一轮的内存风暴探针（挂主循环，零新增唤醒；读取失败静默跳过）
mem_probe() {
  psi_mem_read || return 0

  # P0-2: 连续 MEM_BB_ROUNDS 轮 some≥THRESH → 灾难黑匣子（取证不避风暴期）
  if [ "$P_S10" -ge "$MEM_BB_THRESH" ]; then
    _mem_hi=$((_mem_hi + 1))
  else
    _mem_hi=0
  fi
  if [ "$_mem_hi" -ge "$MEM_BB_ROUNDS" ]; then
    _now=$(date +%s)
    _last=$(cat "$RUN/last_blackbox.ts" 2>/dev/null)
    case "$_last" in ''|*[!0-9]*) _last=0;; esac
    _today=$(date '+%Y%m%d')
    _bd=$(cat "$RUN/blackbox_day.cnt" 2>/dev/null)
    _bday=${_bd%% *}; _bcnt=${_bd##* }
    case "$_bday" in "$_today") :;; *) _bcnt=0;; esac
    case "$_bcnt" in ''|*[!0-9]*) _bcnt=0;; esac
    if [ $((_now - _last)) -ge "$MEM_BB_COOL" ] && [ "$_bcnt" -lt "$MEM_BB_DAYMAX" ]; then
      echo "$_now" > "$RUN/last_blackbox.ts" 2>/dev/null
      echo "$_today $_((_bcnt + 1))" > "$RUN/blackbox_day.cnt" 2>/dev/null
      mem_blackbox "psi_storm" "$P_S10" "$P_S60" "$P_F10"
      _mem_hi=0
    fi
  fi

  # P0-1: 风暴级亮屏压实例外（常规亮屏铁律禁压不变，仅 some≥30 放行）
  if [ "$P_S10" -ge "$MEM_CMPCT_THRESH" ]; then
    _now=$(date +%s)
    _lc=$(cat "$RUN/last_compact.ts" 2>/dev/null)
    case "$_lc" in ''|*[!0-9]*) _lc=0;; esac
    if [ $((_now - _lc)) -ge "$CMPCT_COOL" ]; then
      do_fg_compact
    fi
  fi

  # v1.13.9 (P-B): 预测态前置压实——内存余量告急且 <2.2GB 时压实（30min 限频）。
  # 复用 do_fg_compact 的锁/冷却/相机规避全套保护；相机/截屏/风暴活动时让位（其内部跳过）。
  if [ -f "$RUN/mem_forecast.flag" ]; then
    _mf_av=$(grep -oE "avail_kb=[0-9]+" "$RUN/mem_forecast.flag" 2>/dev/null | head -1 | cut -d= -f2)
    case "$_mf_av" in ''|*[!0-9]*) _mf_av=0;; esac
    if [ "$_mf_av" -gt 0 ] && [ "$_mf_av" -lt 2252800 ]; then
      _now=$(date +%s)
      _pfc=$(cat "$RUN/mf_compact.ts" 2>/dev/null); case "$_pfc" in ''|*[!0-9]*) _pfc=0;; esac
      if [ $((_now - _pfc)) -ge 1800 ]; then
        echo "$_now" > "$RUN/mf_compact.ts" 2>/dev/null
        if [ ! -f "$CAMERA_ACTIVE_FLAG" ] && [ ! -f "$SCREENSHOT_ACTIVE_FLAG" ] && [ ! -d "$STORM_FLAG" ]; then
          do_fg_compact
          logx W "act=forecast_compact avail_kb=$_mf_av msg=预测态前置压实_30min限频"
        else
          logx S "act=forecast_compact skipped msg=相机/截屏/风暴活动中_让位"
        fi
      fi
    fi
  fi

  # v1.12.6: system_server 健康门控（只读 /proc/status，高水位才 dumpsys 取证）
  ss_health_probe 2>/dev/null

  # v1.13.9: 内存余量预测器（P-A/P-B 前置干预）
  mem_forecast

  # P2: 前台 majflt 差分指纹（转码/媒体导入类负载预警，10min 限频）
  _fm=$(fg_majflt_sum 2>/dev/null)
  if [ -n "$_fm" ] && [ -n "$_fg_mflt_prev" ]; then
    _fd=$(($_fm - _fg_mflt_prev))
    [ "$_fd" -lt 0 ] && _fd=0   # PID 身份变更/进程更换顶部 cgroup 时窗口差分可能为负，防负值归零
    # majflt 累计值来自集合差分；切换 pid 集合时理论差分可达全集级，防假告警
    if [ "$_fd" -ge "$FG_MFLT_RATE" ] && [ "$_fd" -lt 1000000 ]; then
      _now=$(date +%s)
      if [ $((_now - _fg_mflt_warn_ts)) -ge 600 ]; then
        logx W "warn=fg_majflt_burst rate=${_fd}/60s total=$_fm note=前台重负载指纹_单 pid 集合窗内差分"
        _fg_mflt_warn_ts=$_now
      fi
      # v1.13.5 (I2): 灾难级换页（>10 万/60s）= 软重启前兆（10-28 11:31 实证 13.6 万→11:37 软重启）
      # 落 paging_storm.flag（WebUI 横幅）+ 持续 2 次/10min 落 soft_reboot_advised（决策留用户）
      if [ "$_fd" -ge 100000 ]; then
        _ps_new_storm=0
        [ -f "$RUN/paging_storm.flag" ] || _ps_new_storm=1
        echo "$_now" > "$RUN/paging_storm.last" 2>/dev/null
        echo "majflt_rate=$_fd/60s total=$_fm ts=$(date '+%m-%d %H:%M:%S')" > "$RUN/paging_storm.flag" 2>/dev/null
        _ps_win=$(cat "$RUN/paging_storm.win" 2>/dev/null); case "$_ps_win" in ''|*[!0-9]*) _ps_win=0;; esac
        if [ $((_now - _ps_win)) -ge 600 ]; then echo "$_now" > "$RUN/paging_storm.win" 2>/dev/null; _ps_cnt=1; echo "1" > "$RUN/paging_storm.cnt" 2>/dev/null; else _ps_cnt=$(( $(cat "$RUN/paging_storm.cnt" 2>/dev/null) + 1 )); echo "$_ps_cnt" > "$RUN/paging_storm.cnt" 2>/dev/null; fi
        if [ "$_ps_cnt" -ge 2 ] && [ ! -f "$RUN/soft_reboot_advised.flag" ]; then
          # v1.13.6 (F3): 落建议前查 rollback 门控（与 kswapd 路径对齐——rollback 武装时
          # 软重启可能触发完整重启丢 root，改落抑制提示而非危险建议）
          _rb_cnt=$(dumpsys rollback 2>/dev/null | grep -c 'state: enabling')
          case "$_rb_cnt" in ''|*[!0-9]*) _rb_cnt=0;; esac
          if [ "$_rb_cnt" -gt 0 ]; then
            echo "source=paging_storm rollback_count=$_rb_cnt ts=$(date '+%m-%d %H:%M:%S')" > "$RUN/reboot_suppressed.flag" 2>/dev/null
            logx W "warn=paging_storm advise_suppressed reason=staged_rollback_active count=$_rb_cnt"
            notify_alert rollback "MemTonic: 换页风暴持续但存在$_rb_cnt条staged rollback——暂缓软重启,先拆rollback雷"
          else
            echo "advised=$(date '+%m-%d %H:%M:%S') reason=paging_storm majflt_rate=$_fd/60s" > "$RUN/soft_reboot_advised.flag" 2>/dev/null
            logx E "advise=soft_reboot reason=paging_storm majflt_rate=$_fd/60s msg=换页风暴持续_软重启前兆_建议择机软重启止损"
            notify_alert advise "MemTonic: 换页风暴持续(majflt $_fd/60s)——建议择机软重启,重启前确认无rollback"
          fi
        fi
        logx E "warn=majflt_disaster rate=$_fd/60s total=$_fm msg=灾难级换页_已落 paging_storm.flag"
        # v1.13.6 (F2): 风暴 onset 通知（旗标从无到有才发，2h 限频）
        [ "$_ps_new_storm" -eq 1 ] && notify_alert paging "MemTonic: 换页风暴进行中(majflt $_fd/60s)——若明显卡顿建议关闭大型后台应用"
      fi
    fi
    # v1.13.5 (I2): 换页回落（<10 万/60s 持续 300s）则清 paging_storm.flag
    if [ "$_fd" -lt 100000 ] && [ -f "$RUN/paging_storm.flag" ]; then
      _now=$(date +%s)
      _ps_last=$(cat "$RUN/paging_storm.last" 2>/dev/null); case "$_ps_last" in ''|*[!0-9]*) _ps_last=0;; esac
      if [ $((_now - _ps_last)) -ge 300 ]; then
        rm -f "$RUN/paging_storm.flag" "$RUN/paging_storm.cnt" "$RUN/paging_storm.win" 2>/dev/null
        # v1.13.6 (F1): 风暴解除时清除自己落的 paging_storm 建议（属主保护，不动他方旗标）
        if [ -f "$RUN/soft_reboot_advised.flag" ]; then
          case "$(cat "$RUN/soft_reboot_advised.flag" 2>/dev/null)" in
            *reason=paging_storm*)
              rm -f "$RUN/soft_reboot_advised.flag" 2>/dev/null
              logx I "act=paging_storm_clear msg=换页回落_风暴标志与建议已清除"
              ;;
          esac
        fi
        logx I "act=paging_storm_clear msg=换页回落_风暴标志清除"
      fi
    fi
  fi
  [ -n "$_fm" ] && _fg_mflt_prev=$_fm
}

# v1.13.4: CrashRecovery 回滚征兆观察（P3，源自 10-27 10:11 硬重启取证）——
# 救助链对 mainline APEX 的回滚在 request→reboot 仅 ~25 秒窗口内完成，v1.9.11 的
# 孤儿回滚哨兵（小时级 poll）追不上。本观察器对 crashrecovery-events.txt 做 stat 级
# size-diff（300s 节奏，单次 wc -c <1ms），文件增长才 tail 增量解析 "Rolling back" 行，
# 命中即 E 级日志 + rollback_warn.flag（WebUI 横幅）。自动拆除（install-abandon）默认
# 不做——只递警报到眼前，拆除决策留给用户。
CCE_FILE=/data/system/crashrecovery-events.txt
CCE_EVERY=300
cce_watch() {
  _now=$(date +%s)
  _lt=$(cat "$RUN/cce_ts" 2>/dev/null); case "$_lt" in ''|*[!0-9]*) _lt=0;; esac
  [ $((_now - _lt)) -ge "$CCE_EVERY" ] || return 0
  echo "$_now" > "$RUN/cce_ts" 2>/dev/null
  [ -r "$CCE_FILE" ] || return 0
  _sz=$(wc -c < "$CCE_FILE" 2>/dev/null); case "$_sz" in ''|*[!0-9]*) return 0;; esac
  _old=$(cat "$RUN/cce_size" 2>/dev/null); case "$_old" in ''|*[!0-9]*) _old=$_sz;; esac
  echo "$_sz" > "$RUN/cce_size" 2>/dev/null
  [ "$_sz" -gt "$_old" ] || return 0
  _delta=$((_sz - _old))
  [ "$_delta" -gt 8192 ] && _delta=8192
  _new=$(tail -c "$_delta" "$CCE_FILE" 2>/dev/null | grep -a "Rolling back" 2>/dev/null)
  [ -n "$_new" ] || return 0
  echo "$_new" > "$RUN/rollback_warn.flag" 2>/dev/null
  echo "$_new" | while IFS= read -r _ln; do
    [ -n "$_ln" ] && logx E "warn=crashrecovery_rollback detail=$_ln msg=救助链正在回滚模块_完整重启将丢root_请立即核查"
  done
  notify_alert rollback "MemTonic: CrashRecovery 正在回滚模块(救助链)——完整重启将丢root,请立即查看WebUI"
  return 0
}

# ---- 初始化 ----
init_dropbox_state
# v1.9.9: 启动时先批量拿一次 app_pids，take_ticks_snapshot 与 scan_cpu_rogue 共用
_init_app_list=$(snapshot_app_pids)
take_ticks_snapshot "$_init_app_list"

# ---- 主循环 ----
rayneo_restore_all   # v1.13.11: 启动自愈——清理上一轮（崩溃/stop）残留的降权状态
_mem_hi=0            # v1.10: 连续超阈轮数
_fg_mflt_prev=       # v1.10: 前台 majflt 上轮基线
_fg_mflt_warn_ts=0   # v1.10: majflt 预警限频时间戳
while kill -0 "$PPID" 2>/dev/null; do
  sleep $CPU_SCAN_WIN
  check_root_liveness
  check_dropbox          # FR-5：每 60s 检查崩溃/ANR 事件
  mem_probe              # v1.10：内存风暴探针（60s 粒度，零新增唤醒，取证不避风暴）
  cce_watch              # v1.13.4：CrashRecovery 回滚征兆（300s stat 级，零新增唤醒）

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
  # v1.13.10: AFF_LST 死条目清理（被约束进程死亡 → 记录移除；cpuset 成员随进程死亡自动失效）
  if [ -s "$AFF_LST" ]; then
    _aftmp="$RUN/aff_tmp_clean_$$"
    while read -r apid apkg aorig; do
      [ -d "/proc/$apid" ] && echo "$apid $apkg $aorig" >> "$_aftmp" 2>/dev/null
    done < "$AFF_LST"
    if [ -f "$_aftmp" ]; then mv "$_aftmp" "$AFF_LST" 2>/dev/null; else rm -f "$AFF_LST" 2>/dev/null; fi
  fi

  # 风暴护栏活动期：刷新 CPU 基线快照但暂停干预（启动高负载期不误判）
  if [ -d "$STORM_FLAG" ]; then
    rayneo_governor "" storm   # v1.13.12(P1-3): 风暴期轻量——眼镜判活/还原/死条目清理可达，不新增降权
    take_ticks_snapshot "$(snapshot_app_pids)"
    continue
  fi

  t_scan0=$(now_ms)
  scan_cpu_rogue         # FR-4：扫描并处置 CPU 毒瘤（v1.9.8: delta-first 低开销）
  # v1.13.15 (A-2): 扫描日志降频——慢扫描（≥300ms）立即记，正常扫描每 5 轮记一次。
  # 原因：cpu_scan 原占日志 32%（1779/5583 行），把 512KB 历史窗口压到 37 小时。
  # 保持 "done_ms=N" 结尾格式，兼容既有验收脚本的 sed 解析。
  _scan_ms=$(( $(now_ms) - t_scan0 ))
  _cs_n=$(( ${_cs_n:-0} + 1 ))
  if [ "$_scan_ms" -ge 300 ] || [ $((_cs_n % 5)) -eq 1 ]; then
    logx S "act=cpu_scan done_ms=$_scan_ms"
  fi
done

# 守护进程已死：清场还原全部 CPU 降权
restore_all_rogue
rayneo_restore_all   # v1.13.12(P1-4): FR-RN1 降权状态同步清场（原版遗漏）
rm -f "$RUN/cpuguard.pid" 2>/dev/null
exit 0
