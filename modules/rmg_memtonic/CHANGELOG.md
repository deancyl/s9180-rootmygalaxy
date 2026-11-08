# RMG MemTonic 版本变更日志

---

## [v1.13.18] - 2026-11-08

> C 阶段：WebUI 收敛。审计发现"堆 223MB 显示正常、但整机物理内存已用 99.3%"的误判风险——首屏只有堆水位，看不到真正压力。

### 变更

- **C1 健康分首屏**：以「可用内存 / 堆水位 / swap 已用 / mem PSI / CPU PSI」综合出 0–100 分与一句人话（状态良好 / 内存偏紧 / 内存吃紧 / 随时可能卡死），替代原来三张只讲堆的指标卡。
- **C2 整机内存字段**：`collect_stats` 新增 `swap_total_kb` / `swap_free_kb` / `cpu_psi_s10`（零 fork 读 `/proc/meminfo` 与 `/proc/pressure/cpu`），首屏直接显示"交换已用 X.X GB""CPU 压力 N%"。
- **C3 折叠区 6→4**：合并「内存细节 + 保护记录」为「内存与保护」；「这个模块不会做什么」并入「运行状态与限制」；保留「最近记录」「更多操作」。首屏高度下降约 40%。
- **契约不变**：5 次 `execCmd`、11 段解析、全部 DOM id、`AUTO_SEC=30`、四按钮均保留；单测 266/266（新增 13 项 C 阶段断言，含健康分边界与整机字段）。

### 说明

- 健康分是**相对评估**（用于"要不要现在清后台"），不是医学指标；阈值按本机 12GB+12GB swap 的实测分布定。
- 未做 NoActive 健康检查（需读 1.2MB LSPosed 日志，成本高于收益），留在后续。

## [v1.13.17] - 2026-11-08

> v1.13.16 的 FR-RN1 验收暴露出**真正的瓶颈不是"读"而是"写"**：即使已把 Tgid 校验、`oom_score_adj` 探针、`pidof|awk` 全部零 fork 化，移除旁路后 `cpu_scan` 仍达 **1460–3840ms**。根因是降权循环对 181–221 个线程**逐个执行 `renice`**（每次一个 fork），外加每个 tid 一次 `grep -q` 查重与每线程一条日志，合计约 **600 fork/轮**。

### 修复（B1c 批量 renice）

- **`renice` 批量调用**：实机验证 toybox `renice -n N -p pid1 pid2 ...` 支持多 PID（`MULTI_RENICE=OK`）。按 nice 分桶——绝大多数线程为 0，合并为一次 `renice -n 10 -p <全部 tid>`；非 0 的逐个处理（数量极少）。
- **查重入内存**：`grep -q "^$tid " "$RN_STATE"`（每 tid 一次 fork）改为循环前一次性把已降权 tid 读入 `_known` 字符串，用 shell 模式匹配 `case "$_known" in *" $tid "*)`。
- **日志合并**：每线程一条 `act=rayneo_thread_demote` 改为每轮一条 `act=rayneo_demote_batch threads=N`。
- 预期：fork 从 ~600/轮降到 ~5/轮；FR-RN1 在役时 `cpu_scan` 应回落到 300ms 以内。

### 验证

- 单测 **253/253**（新增 3 项 B1c 断言）。
- FR-RN1 临时启用验收：5 轮 `cpu_scan` 全 <1000ms 才保留启用，否则自动恢复旁路（与 v1.13.16 同一纪律）。

## [v1.13.16] - 2026-11-08

> 阶段 A 审计（v1.13.15 之后、只读）发现两处：① `memtonic.sh stop` 与 `uninstall.sh` 用 `kill -9` 终止子进程，**跳过了子进程的退出清场**，导致 `gc_boost` 提权、相机 provider 亲和、核亲和约束三类改动可能残留到下一次完整重启；② FR-RN1 在役时仍有 **5 处 fork**（Tgid 校验 `awk` ×2、`oom_score_adj` `cat`、`pidof|awk` ×2），是 v1.13.13 验收 0/5 的遗留根因。

### 修复

- **B0 还原完整性**：`stop` 与 `uninstall` 显式补 `gc_boost_off`、`camera_affinity_off`，并按 `affinity_constrained.lst` 逐条把进程写回原 cpuset。此前只还原 rogue / rayneo / camera_vip / bt 四类。
- **B1 零 fork（5 处）**：
  - `nice_of()` 改内建读 `/proc/<pid>/stat`（原 `awk`；一次 renice 循环几十次调用，换页风暴下单次 5–10ms）
  - `is_foreground_service()` 改内建读 `oom_score_adj`（削峰循环每 pid 一次）
  - `cpu_guard` 两处 Tgid 归属校验改 `while IFS=' ' read`
  - 眼镜活跃探针 `cat oom_score_adj` 改内建读
  - 两处 `pidof | awk` 改参数展开 `${var%% *}`
- **B5 探测门控补强**：新增"单 tick（约 60s）RSS 涨 >10MB 也算值得探测"，覆盖"堆缓慢上涨但 |ΔRSS| 未达 30MB"的漏探场景；抑制态与复测期仍完全不受门控限制。

### 验证与底线

- 单测 **250/250**（新增 9 项 B 阶段断言：stop/uninstall 还原、5 处零 fork、门控补强）。
- FR-RN1 采用"先旁路部署 → 临时移除 flag 跑 5 轮 → 全绿才正式启用，否则保持旁路"的验收纪律，避免重演 v1.13.13 的 0/5。
- 底线不变：不杀进程 / 不冻结 / 不动 zram / 不改持久参数 / 不代执行重启 / nice 只提不降。
- 本次部署需一次守护重启。

## [v1.13.15] - 2026-11-08

> 源自 11-08 近 5 次部署审计（628 个堆快照覆盖 19 天 + 37.3h 归档日志）。核心发现：**cpu_scan 的 14 次 >1000ms 尖峰（最高 9220ms）全部紧邻 `dumpsys meminfo` 堆探测**，不是扫描本身；堆快照 275 个/天（设计 144）；cpu_scan 占日志行数 32%，把 512KB 历史窗口压到 37 小时。本版为**纯降本**，零功能损失、不改任何阈值语义。

### 降本（A 包四项）

- **A-1 堆探测条件化**：定期到点后先判断"是否值得 dumpsys"——RSS 变化 <30MB 且 mem PSI <5% 且非抑制态/非复测期则跳过（落 `act=ss_probe_skip`，每 20 次记一条）。预期 98 次/天 → 10–20 次/天，**消除 9s 级尖峰**。
- **A-2 扫描日志降频**：`act=cpu_scan` 慢扫描（≥300ms）立即记，正常扫描每 5 轮记一次；保持 `done_ms=N` 结尾格式以兼容既有验收脚本。预期日志量降 ~80%（60/h → 12/h）。
- **A-3 堆快照限流**：非危机态每小时最多 1 个（危机态 ≥470MB 不受限，保证 OOM 现场不丢）；每天最多清理一次 7 天前快照。预期 275 个/天 → ~24 个/天，628 inode → ~170。
- **A-4 护航复用前台采样**：FR-9 护盾触发时不再单独 `dumpsys window`，改用循环内每 10s 的 `focused_pkg` 采样（空值才兜底）。该调用平时 ~40ms、高压时数百 ms，而护盾恰在高压时刻触发（37h 内 821 次重复调用）。

### 依据（审计数据）

- 19 天堆水位 p50 391–461MB 无下降趋势、`>450MB` 占比 0–69%（三个 OOM 日都在高位）→ FR-SS 的价值在记录与建议，不在降堆；本版不夸大为"治本"。
- 模块自身开销已属优秀（四进程合计 ~1% 单核 / 13MB RSS），本版进一步削减其固定成本。
- 整机真实压力：物理内存 99.3% 用满（free 79MB）、swap 5.5GB、CPU PSI 38%、`compact_fail/stall` 94.8% —— **属容量级问题，模块层无法解决**；容量取舍（`max_cached_processes` 1024 等）留用户决策。

### 兼容性 / 底线

- `collect_stats` 字段与段数不变；`ss_heap_probe` 快照格式不变；`act=cpu_scan` 解析兼容。
- 底线不变：不杀进程 / 不冻结 / 不动 zram / 不改持久参数 / 不代执行重启 / 只提权不降级。
- 本次部署需**一次守护重启**（stop + service.sh 幂等拉起）。

## [v1.13.14] - 2026-11-07

> 源自 11-07 23:03:25 第四起 `system_server_crash`：`OutOfMemoryError: HeapFull, 501MB was used` @ `Watchdog`（与 10-22 / 10-25 / 11-05 三起同型 496–501MB）。当日取证的关键事实：`ss_heap_relief` 尝试 22 次**全部失败**、`ss_heap_trim` **全天 0 次成功**——唯一泄压手段 `am send-trim-memory` 走 binder 到 system_server，在堆濒死时必然不可达；模块实际上只具备「记录 + 建议」，不具备「有效干预」。

### 修复（六项，全部在安全底线内）

- **内核路径兜底 `ss_drop_caches`**：`am` 全部尝试失败后，改走 `echo 3 > /proc/sys/vm/drop_caches`（不经过 framework，确定可达）。作用域为 page cache / dentry / inode 等可回收 slab，**不触碰 Java 堆、不动 zram、不改持久内核参数**；限流 10 分钟 1 次、1 小时最多 6 次。
- **`am` 单轮重试 ×3**：立即 / +4s / +8s（总阻塞 ≤8s），抓 framework 短暂可用窗口；失败必走内核兜底。复测间隔 120s→30s。
- **阈值前移**：450MB 完整泄压链（原 460）、460MB GC 加速（原 480）、470MB 告警（原 485）、480MB 极限压制（新增）、430MB 预备态（新增，仅加密探测不动手）；496MB 仅作 OOM 参考线。11-07 实测堆在 450–480MB 震荡近 50 分钟才崩溃，前移换取 30–60 分钟有效窗口。
- **GC 加速加强**：目标 nice -10 → **-15**，并尝试 `taskset` 绑大核（SM-S9180 cpu5-7，mask `e0`，失败静默降级为仅提权）；还原时 delta 法 renice + `taskset -p ff` 恢复亲和。GEMINI 铁律不变：已 ≤-15 不反向降级。
- **趋势判定替代瞬时判定**：`ss_heap_recovered` 由「单点 <450MB 即撤销」改为「连续 3 次探测均 <430MB 才撤销」。11-07 实测 450MB 撤销后 6 分钟反弹到 477MB，建议反复失效；新逻辑另落 `act=ss_heap_holding` 便于观察。
- **抑制态转极限压制**：检测到 `reboot_suppressed.flag`（有 staged rollback、不能重启）时，探测节奏加密到 **60s**，且每轮把 am 重试 + drop_caches + GC 提权全叠加，落 `ss_heap_extreme.flag`。11-07 取证显示 22:59 抑制建议后模块 4 分钟内再无任何动作，随后 OOM。
- **零 fork 补全**：`gc_boost_on` 的 comm 读取改为 `IFS= read -r`（原 `cat` 子进程，与 P2-A 同源问题）。

### 兼容性 / 底线

- `collect_stats` 字段与段数不变；旁路 flag / RN_STATE 格式不变；`ss_heap_probe` 快照格式不变（新增 `ss_heap.hist` 趋势文件，可选消费）。
- 底线不变：不杀进程 / 不冻结 / 不动 zram / 不持久修改内核参数 / 不刷写任何分区 / 软重启仍只建议不代执行 / nice≤-15 不反向降级 / 前台与相机优先 / 蓝牙与播放中应用不干预。
- **诚实边界**：堆泄漏发生在 system_server 内部，用户态手段只能延后与缓解，不能承诺不再发生；本次改造把「几乎无干预」变为「有 30–60 分钟窗口 + 一条可达泄压路径」。
- 本次部署需**一次守护重启**（stop + service.sh 幂等拉起）以加载新 `mt_lib.sh`。

## [WebUI UI-R1 / UI-R2 修订] - 2026-11-07

> 本轮**仅重写 `webroot/index.html` 一个文件**（KernelSU WebUI），模块版本仍为 `v1.13.13 / vc53`，无脚本、阈值、旁路 flag 或守护变更；设备侧为单文件热替换、零守护重启。源自 11-06 用户截图反馈「WebUI 有大问题」，以及 11-07 追加的状态行排版与全站用语傻瓜化要求。

### 修复（UI-R1：信息架构，11-06）

- **告警不再倾倒原始日志**：7 类 flag 原用 `msgs.join(' ｜ ')` 拼成一段橙黄文字墙，改为按 critical/warn/info 排序的独立卡片，最多直显 2 条、其余折叠；原始 `key=value` 收进「查看原始诊断数据」。
- **最近快照结构化**：新增 `fmtSnapshot()`，把 `incident-*.zip | 首行日志` 解析为「时间 / 类型 / 原因」三列；移除 `word-break:break-all` 任意折行，原始文件名与 `===` 装饰串不再直出。
- **文字墙消解**：14 张计数卡由「数字 + 标题 + 口径说明 + 触发条件」4 行瘦身为 3 行信息，默认折叠为摘要；口径与触发条件收进二级折叠。
- **安全信息置顶**：`rb_enabling > 0` 时新增红色「禁止重启」条（按安全铁律此时严禁重启）；危险操作收进「高级操作」折叠，刷新按钮常驻首屏。
- **对比度与刻度**：小字 `opacity:.55`（≈2.6:1）改为 `--tx3:#8d99a6` 12px（≈5.6:1）；修正旧 CSS `.ticks span{position:absolute}` 与 flex 图例冲突导致的刻度堆叠。
- 指标区改「2 列 + 堆卡整行」稳定布局，避免窄屏半张空卡与刻度挤压。

### 修复（UI-R2：排版与用语，11-07）

- **状态行重排**：`v1.13.13 / vc53 · 主✓ 风暴✓ CPU✓ 护盾✓ 4/4 · root 正常` 挤成一行的小字，改为三个状态胶囊「保护 4/4 / 权限 正常 / 版本 v1.13.13」；四守护徽章明细、pid、vc 值收进隐藏数据源，由 ⓘ 弹层动态读取。
- **ⓘ 信息层**：新增通用弹层与 `INFO_DEFS` 25 条说明；PSI、Java 堆、trim/GC、staged rollback、HAL tombstone、FR-RN1、majflt、RSS、versionCode、KernelSU 等术语全部集中于此，主界面零术语。
- **全站白话化**：副标题一句话说清模块作用；指标、刻度、水位判定、14 类计数名、告警标题与动作、折叠标题、4 个按钮名称全部改成人话；每个操作按钮配一行「这会做什么」+ ⓘ；确认弹窗主文案白话、技术细节单列。
- **底层语义逐条核对**：四守护命名对齐 `memtonic / storm_guard / cpu_guard / fluency_shield`；FR-RN1 描述由易误导的「眼镜语音保护」更正为「眼镜相关治理：后台渲染/池线程温和降权 + 语音链路削峰豁免」；按钮说明与真实命令一致（`service.sh` + `memtonic.sh optimize` / `memtonic.sh stop` / `stop → service.sh`）。

### 兼容性 / 验证 / 回滚

- **数据契约分毫未动**：5 次 `execCmd`、11 段解析、纯函数块、全部 DOM id、`CARD_DEFS` 14 项、`AUTO_SEC=30`、四个 `data-act` 均保留；从新旧两份 HTML 提取出的设备命令 **2671 字符逐字节完全一致**。
- 单元测试 `197/197`（142 原有 + 29 UI-R1 + 26 UI-R2）；全部脚本 `sh -n` 通过；45 个 id 唯一、单 script 块、标签平衡；390px 无头浏览器实渲染（含 ⓘ 弹层）无溢出。
- 设备部署 7/7 全绿（md5 双检、备份、原子替换、设备侧结构守卫、数据源 11 段、四守护 pid 不变）；独立旁路验证：从设备读回文件与本地源 **逐字节一致**。
- 回滚：设备 `cp -p webroot.bak-uir2/index.html webroot/index.html; chmod 644 webroot/index.html`（备份 md5 `eb1bd04e…`）；仓库 `git revert <本次提交>`。

## [v1.13.13] - 2026-11-05

> 源自 11-05 FR-RN1 移除旁路后的性能回归 A/B 取证：恢复 flag 后 `cpu_scan` 从 1770–13010ms 回落到 210–220ms 而 CPU PSI 未同步下降，确证根因是 `rayneo_memo_active()` 每轮约 181 次 `cat` fork（v1.13.12 引入 P1-5 门控时的实现缺陷）。

### 修复

- **P2-A 零 fork 探针**：`rayneo_memo_active()` 与降权循环的 `cat "$t/comm"` 改为 mksh 内建 `IFS= read -r`（复用 v1.13.2 耗电治理已验证范式）；判定语义、降权名单、nice≤-10 铁律、Tgid 归属校验**全部不变**。验收：移除旁路后 `cpu_scan < 300ms` 连续 5 轮。
- **P2 WebUI 四项**：HAL tombstone 计数卡（只读文件名统计、不解压）、incident 快照摘要（reason/时间）、「重启守护」按钮（二次确认 + 全量清场说明）、自动刷新 15s→30s（省一半 shell 调用）。
- **WebUI 四维审查后 3 项修复**：`fmtStamp()` 统一时间格式（epoch 秒/原始文件名 → `MM-DD HH:MM`）、堆危机刻度改 flex 图例（原标签 88/94/97% 与刻度线 92.7/96.8% 错位）、第二次 exec 失败/分段异常不再静默降级（补 errno 与 11 段守卫提示）。
- **RayNeo 削峰豁免（11-06 ASR 取证）**：启动风暴窗口内 `renice_tree` 原会把 RayNeo 整进程（含音频采集 / ASR / 网络回调线程）压到 nice+5，实测 `deprioritize_rayneo=1`。在削峰路径新增 `com.rayneo.venus.pub*` 专用豁免与 `act=voice_asr_skip` 审计日志；**不修改全局 `WHITELIST_PKGS`**（它还被 FR-4 毒瘤降权与 optimize 共用），豁免面最小。

### 兼容性

- 无接口变更；旁路 flag / RN_STATE 格式不变；`collect_stats` 字段不变（P1 的 5 个新字段保持）。
- 本次部署需**一次守护重启**（`memtonic.sh stop` + `service.sh` 幂等拉起）以加载新 `cpu_guard.sh`；stop 会清场还原全部降权，状态档由启动自愈处理。24h A/B 基线从部署完成时刻重新起算。

## [v1.13.12] - 2026-11-04

> 源自 v1.13.11 FR-RN1 代码审计（结合 11-04 memo 正式激活实测）：五处缺陷修复。当日实测推翻一个前提——memo 激活期 59% CPU 的大头是 spdy-0(14%)/ACCS0(9%)/process-memory(7%)/HeapTaskDaemon(4%)，**均不在降权名单且不可触碰**，名单治理上限仅 ~8-10%，误伤面反而扩大——由此 P1-5 从候选升级为必修。

### 修复（P0/P1 五项）

- **P0-1 tid 复用误伤防护**：rayneo_restore_all 与死条目清理逐条加 Tgid 归属校验（/proc/\<tid\>/status 的 Tgid 字段 == 当前 RayNeo pid；Tgid 不在 stat 文件中）。tid 是全局递增可复用资源：进程死亡后旧 tid 可被无关进程复用，仅存在性检查的 renice 会误伤无辜线程。进程已死时活 tid=复用 → 全部跳过（死线程 nice 随 task_struct 释放，无需还原）
- **P0-2 眼镜活跃判据重构**：手机屏幕焦点≠眼镜使用状态（11-04 实测投屏场景焦点=NotificationShade）。改用 /proc/\<rpid\>/oom_score_adj ≤300 探针（top=0/visible/FGS perceptible≈100-200/纯后台 cached 900+），零 dumpsys 成本；失败安全方向=漏治理不误伤
- **P1-3 风暴期 governor 可达**：原挂载点在 scan_cpu_rogue 尾部，主循环 STORM continue 整轮跳过导致风暴期连还原都不可达。STORM 分支新增轻量调用 rayneo_governor "" storm（判活/还原/死条目清理可达，不新增降权）
- **P1-4 守护退出清场补漏（双路径）**：cpu_guard 退出路径补 rayneo_restore_all（原只还原 rogue 降权，漏 FR-RN1 状态）；memtonic.sh stop 兜底同样补 FR-RN1 还原块（cpu_guard 被 pkill -9 时退出清场不可达），带同语义 Tgid 归属校验
- **P1-5 memo 激活态门控**：rayneo_memo_active() 探测 VAD 载体线程（AlwaysOnAiRunti*）存在 → 跳过降权并还原历史降权。激活期治理交给 fluency_shield 既有护航（实测 15:51-15:54 三轮 activate/deactivate 循环工作正常）。判定链顺序固定：flag → 进程 → memo → 眼镜活跃 → 清理 → [storm 止步] → 降权（memo 检查必须在 adj 之前，否则被 adj 短路）

### 兼容性

- 无接口变更；RN_STATE/disable flag 文件格式不变（状态档 3 列格式保持，Tgid 动态校验无需存档）；旁路 flag 语义不变
- 部署后 governor 保持旁路（disable_rayneo_guard 存在），移除时点由用户决定——移除后 memo 未激活且眼镜闲置期开始治理

## [v1.13.11] - 2026-11-03

> 源自用户提供的 RayNeo 全天智记能效提案（另一会话 RFC）评审：后台 Flutter 渲染/池线程空转实测 52% CPU（22s 差分，pid 5635），主线程 20% 为 memo 本体不可动。v1.0-RFC 的 taskset 单核方案经评审否决（与 AMS cpuset 管理竞态 + 单核钉死危及 memo 音频路径），改为线程级降权方案。

### 新增

- **FR-RN1 雷鸟全天智记后台治理**：后台（非焦点）时对浪费线程降权至 +10——仅匹配显式命名（raster/pool-*/DefaultDispatch*/DartWorker*/DefaultExecutor*/AMap*），**绝不触碰**主线程、AlwaysOnAiRunti(VAD)、音频线程、process-memory(GC)。GEMINI 铁律：nice≤-10 跳过（实测 DartWorker -10 在保护线内）。幂等设计：新 churn 线程下轮自动补齐（22s 实测 245→252 线程 churn）。还原三通道：焦点切回秒级还原/进程死亡自动清理/disable flag 一键旁路+启动自愈
- **通知**：每 episode 首次降权通知一次（还原时清除标记）

### 诚实预期

- 实测基线 52%（22s 差分）；可回收空间 = pool 线程 20-25%，现实预期 **52%→~35%**（非 RFC 声称的 8%——主线程 20% 为 memo 本体不可降）。收益为电池/发热（小核 0-2 的持续燃烧），前台流畅度本就不受小核直接影响
- **风险与验收**：pool 线程可能承载 memo 异步工作（转写上传/缓存写入）——降权后 memo 保存可能变慢（用户已接受「变慢不要紧」）；**验收项 = 转写内容完整性**（用户次日核对智记记录）

### 兼容性

- 无接口变更；rayneo_governor.lst 新文件（$RUN 内）；disable flag = $RUN/disable_rayneo_guard（touch 即旁路+全量还原）

## [v1.13.10] - 2026-11-01

> 源自 11-01 晚间实时诊断：Syncthing 200% + 群晖相册 209% 双备份马拉松（前台服务豁免 FR-11 盲区），手工核亲和约束立竿见影（200%→12.9%）——本版将该手工操作机制化。

### 新增

- **FR-11 例外升级：fg-service CPU 大户核亲和约束**。前台服务应用 CPU >50%×3 窗口（与毒瘤同阈值）→ 约束至 /dev/cpuset/background（小核 0-2）而非无条件豁免——大核立即还给前台，任务变慢但不断，零优先级冲突。解除：CPU <20%×2 窗口自动还原原始 cpuset 组；用户打开被约束应用立即还原；被约束进程死亡自动清理记录。top-app cgroup 豁免保持（微信扫码/JIT 等内核最高优先级场景不受影响）；焦点/白名单/相机豁免全部前置保持
- **通知**：约束时 notify（2h 限频，含应用名与还原说明）

### 安全论证

- 核亲和 = 调度约束非优先级惩罚：不影响其他进程、任务正确性无损、完全可逆（还原原始组一条 echo）；约束上限 2 并发（多大户排队逐个处理）；相机/截屏/风暴/焦点/白名单/top-app 六重豁免全部保持

## [v1.13.9] - 2026-11-01

> 源自 11-01 午间卡顿审计：12-13 时高拥堵 41 次/2h（cpu_psi≥40%），majflt 峰值 89 万/min，前兆（avail 3.4→2.0GB 斜率 + swap 6→8.6GB）在 12:00 前已可见——但当时模块只报灾难不预测。

### 新增

- **内存余量预测器（P-A）**：cpu_guard 60s 循环读 /proc/meminfo（<1ms），MemAvailable <2.5GB 且 SwapUsed >7.5GB 连续 3 轮确认 → 预测态：通知推送（2h 限频）+ mem_forecast.flag；MemAvailable ≥3GB 滞后带解除。以 11-01 为例：通知会在 12:15 前到达，比 12:46 灾难峰早 30 分钟+
- **预测态前置压实（P-B）**：预测态内 MemAvailable <2.2GB → 前置压实（30min 限频）——把 13:50 型弱杠杆压实提前到峰值之前。复用 do_fg_compact 全套保护（mkdir 锁/共用冷却/相机与截屏/风暴让位）
- **通知行动分级**（承接 v1.13.8）：fails≥2 建议措辞已升级

### 安全论证

- 预测器稳态成本：每 60s 一次 /proc/meminfo awk（<1ms），无新增进程；前置压实走 do_fg_compact 既有锁与冷却（与息屏/风暴压实共用 last_compact.ts 防叠加），相机/截屏/风暴活动时自动让位；滞后带（2.5 开 / 3.0 关）防抖动

### 兼容性

- 无接口变更；mem_forecast.flag / mf_confirmed / mf_compact.ts 新文件（$RUN 内）；亮屏禁压实铁律的例外边界扩展至「预测态 + avail<2.2GB」（两害相权：短暂压实 vs 持续换页风暴）

## [v1.13.8] - 2026-10-30

> 源自第三次同型 OOM（10-30 14:13 HeapFull 495MB）的机制链复盘：三次 OOM 共同死因是「CPU 饱和饿死 GC」——堆满不是分配太多，是回收被饿死。现有手段全部作用在链路两端，未触及中间环节。

### 新增

- **GC 危机加速（gc_boost，核心前置干预）**：堆 ≥480MB（距 495MB OOM 线 15MB）或泄压失败≥2 时，将 system_server 内 ART GC 守护线程（HeapTaskDaemon/ReferenceQueue*/Finalizer*，comm 前缀识别容忍 15 字符截断）提权至 -10——让 GC 在 CPU 争抢中插队、加快回收、压制死亡螺旋；堆 <450MB 自动还原。GEMINI 铁律（已 ≤-10 跳过）+ 差分 bak + 还原 delta 法，与既有护航同构。成本模型：纯事件驱动（仅危机窗口一次线程扫描 + 4 次 renice），稳态零开销
- **通知行动分级**：fails≥2 的软重启建议措辞升级（「择机」→「尽快止损」）并注明 GC 加速已介入；gc_boost 介入/解除各发一次通知（2h 限频）

### 安全论证

- renice 可逆、只动 GC 守护线程（不影响其他线程优先级）、堆 <450MB 自动还原、软重启后 bak 含死 tid 自动无害化（既有 delta 还原模式天然处理）
- 诚实边界：不保证救活（分配速度可能超过提权后的 GC）——救不活时通知链仍是兜底；本次干预的目标是把 13:19 型预警到 14:13 型 OOM 之间的 54 分钟窗口变成可缓解窗口

### 兼容性

- 无接口变更；gc_state 进程内变量（cpu_guard 作用域）；gc_boost.bak 新文件（$RUN 内）

## [v1.13.7] - 2026-10-30

> 源自 10-30 深度巡检：日志并发写撕裂实锤 + bt3 死亡间隙盲区实锤（RayNeo 25279→5628 换代 0 触发）。

### 修复

- **R2 bt3 死亡间隙盲区**：旧触发条件要求新旧 pid 双非空——app 死亡>5 秒（崩溃重启典型时长）时基线被清空、复活瞬间漏检（实证：RayNeo 25279→5628 换代整窗口零触发）。改用 `_rn_seen` 常驻存活标志：**见过→复活即触发，不限间隙**；死亡滞留不误触发；守护重启首轮只建基线不触发。覆盖：快换代（同 tick）、死亡复活（跨 tick）、应用更新三类场景
- **R3 日志并发写撕裂**：logx 轮转由 `tail+mv`（孤儿化并发写者 fd，10-30 实证 1/4041 行撕裂）改为 **cp+truncate 保 inode**——mkdir 锁防多进程同时轮转、cp 全量留档 `.old`（比旧方案 tail-256KB 保留更多历史）、truncate 原地清空使并发 append 无损续写

### 运营

- **R1 rollback 拆雷（部分）**：tzdata6 孤儿会话（1380526714/originalSessionId 1655757987）已 `pm install-abandon` 成功拆除；adservices 套件会话（1666563512/357665197）**属主为 Google Play services，root/system uid 均被 SecurityException 拒绝**，shell 不可拆除——残留风险由 F3/I5 门控缓解（rollback 武装期间软重启建议正确抑制），boot_postmortem 持续监控 boot reason

### 兼容性

- 无接口变更；bt3 触发语义扩展（死亡复活场景新增，原快换代场景不变）；日志轮转对外行为不变（memtonic.log 路径/格式不变，新增 memtonic.log.old 存档）

## [v1.13.6] - 2026-10-29

> 源自「用户没有收到任何提示」审计：告警旗标被 FR-SS 误删（30 分钟存活期）+ 模块无主动推送通道（提示只在 WebUI 内可见）。

### 修复

- **F1 旗标属主保护**：soft_reboot_advised.flag 曾被 FR-SS 恢复路径无条件清除（堆 <460MB 时每 30min 清一次），换页/kswapd 的建议存活期 ≤30min、横幅窗口随之消失——现在每条路径只清自己落的旗标（按 reason= 前缀判属主）：FR-SS 清 trim_ineffective/relief_fail，paging_storm 清 paging_storm（新增：风暴解除时连建议一起清），kswapd 清 memory_thrashing（新增：健康时清）
- **F3 paging_storm 门控补修**：换页风暴持续建议软重启前先查 `dumpsys rollback`（与 kswapd 路径对齐）——rollback 武装时改落 reboot_suppressed 抑制提示，不再给出「软重启→回滚应用→全量重启丢 root」的危险建议

### 新增

- **F2 通知推送（核心）**：`notify_alert <类型> <文本>`——关键告警发生时经 `cmd notification post`（root 通道，10-29 实测 exit=0）直接推送 Android 通知；按类型 tag 区分、每类 2h 限频去重。覆盖：软重启建议（堆 trim 无效/泄压失败/换页持续/kswapd 恶化）、开机善后（非常规重启原因）、回滚征兆（CrashRecovery 回滚中/建议被抑制）、换页风暴 onset。**纯事件驱动零稳态开销**（无新增轮询/进程，仅在告警落旗标时刻一次 binder 调用）
- **WebUI 无需改动**（横幅渲染 v1.13.5 已就绪，F1 修复后旗标存活期恢复设计语义）

### 兼容性

- 通知权限：Samsung shell_cmd 通道免授权（系统级）；无接口变更；旗标文件格式向后兼容（新增 reason= 前缀仅用于属主判定）

## [v1.13.5] - 2026-10-28

> 源自 10-27→10-28 23h 巡检取证：两次软重启（换页压力→system_server 饿死）、BT2 churn（每 40 分钟一轮 boost/restore）、软重启建议被门控抑制但只在日志不可见。

### 新增（I1/I2/I4/I5）

- **I1 BT2 风暴态**：1h 窗口 ≥4 次 bt2 触发进入维持模式（不反复 boost/restore），15 分钟无触发或 30min 硬顶一次性还原——复用 FR-C3 风暴态同型机制，治 churn（昨晚 18:50-23:25 实测 11 轮 → 预期 0 轮/小时）
- **I2 换页风暴前置泄压**：majflt 灾难级（>10 万/60s，10-28 11:31 实证 13.6 万→11:37 软重启）落 `paging_storm.flag`（WebUI 横幅）+ 持续 2 次/10min 落 `soft_reboot_advised.flag`（reason=paging_storm）；换页回落 300s 自动清旗标
- **I4 RSS 趋势告警**：ss_health_probe 连续 3 次探测 RSS>900MB 且斜率上升 → `rss_warn.flag`（WebUI 横幅）；RSS 回落自动清除（Java 堆水位管不了 native，纯预警）
- **I5 门控透明化**：soft_reboot 建议被 staged_rollback 抑制时同步落 `reboot_suppressed.flag`（WebUI 横幅）；未被抑制时落 `soft_reboot_advised.flag`（此前只写日志用户看不见）
- **WebUI 横幅扩展**：合并六类信号（软重启建议/开机善后/回滚征兆/换页风暴/RSS 膨胀/抑制提示）

### 兼容性

- 无接口变更；新增旗标文件（paging_storm/rss_warn/reboot_suppressed）为纯增量；I1 复用既有批量引擎与 BT2 备份语义；fluency/cpu_guard 主循环结构零改动

## [v1.13.4] - 2026-10-27

> 源自 10-27 重启循环（8+ 次干净重启，CrashRecovery 回滚 adservices.api 触发 `reboot,rollback_staged_install()`）的全链条取证与代码级复盘。

### 修复

- **ss_heap_relief 冷却 bug（W1，10-27 09:53 实证）**：旧实现在 `am send-trim-memory` 调用前就写冷却时间戳——system_server 饱和期 am 不可达时泄压失败，却照样消耗 600s 冷却，二次泄压被静默拦截，直至崩溃期间堆完全失明。现改为：**冷却戳仅在成功后写入**；失败计入 `SS_TRIM_FAILS` + 120s 短退避强制复测（新常量 `SS_TRIM_RETRY=120`）；**ALERT 水位（485MB）下失败**（system_server 连 trim 都收不到的恶化信号）直接落 `soft_reboot_advised.flag`（reason=relief_fail）+ E 级日志。复测路径落旗标前增加防覆盖判断（不覆盖 relief_fail 旗标）。

### 新增

- **boot_postmortem 启动善后横幅（W3）**：模块启动时一次性读取 `sys.boot.reason(.last)` + `sys.rescue_boot_count` + `persist.sys.rescue_level`，结合 `.clean_stop` 标记判断上次会话是否被异常终止；回滚/内核 panic/watchdog 类原因落 E 级，非常规原因（如 shell 级重启）落 W 级，均写 `boot_context.flag` 供 WebUI 横幅展示；常规原因仅 I 级留档。stop 路径新增 `.clean_stop` 标记（正常收尾证据）。
- **CrashRecovery 回滚征兆观察（W2，cpu_guard）**：对 `/data/system/crashrecovery-events.txt` 做 stat 级 size-diff（300s 节奏，单次 `wc -c` <1ms），文件增长才 tail 增量解析 `Rolling back <pkg>. Reason:` 行，命中即 E 级日志 + `rollback_warn.flag`。10-11 事件中救助链从回滚到重启仅 ~25 秒，v1.9.11 孤儿回滚哨兵（小时级 poll）无法覆盖此窗口，本观察器负责在案发瞬间把警报到眼前；自动拆除（install-abandon）默认不做，决策留给用户。
- **WebUI 横幅扩展**：advise 横幅合并展示软重启建议 / 开机善后 / 回滚征兆三类信号。

### 兼容性

- 无接口变更：`collect_stats`/`memtonic.sh` 动作集/`module.prop` 结构/`update_module_desc` 均未动；新增旗标文件（boot_context.flag、rollback_warn.flag）为纯增量读取；fluency_shield.sh 本版零改动。

## [v1.13.3] - 2026-10-27
### Fixed（v1.13.2 部署后实测仍 ~64% 单核——剖析修正锁定真凶，耗电治理第二轮）
- **find_camera_provider 缓存化（最大单项）**：原实现每次调用全盘 /proc 扫描（~900 进程 × strings+head ≈ 2.2s CPU），被 FR-C3 每 20s 探测调用 = **均摊 ~560ms/tick ≈ 11% 单核**。改为缓存：命中且 /proc/<pid> 存活 + cmdline 校验（camera.provider）+ TTL<300s → 直接返回（~2ms）；provider 重启由存活/cmdline 兜底。
- **FR-C3 D 状态扫描单次 awk**：原 66 tid × 66 awk fork 每 20s → 单 awk 读全部 task stat（FNR==1 逐文件，comm 剥离后 f[1]==D）。
- **PSI 零 fork 化**：FR-9 与 FR-C3 的 4 次 psi_val（awk）改 mksh read 直读 /proc/pressure/*（零 fork）。**口径统一变更：PSI 百分整数 0-10000**（35%=3500）——高 CPU 退避（bt1/bt2 `-lt 35`→`-lt 3500`）与 FR-C3 触发（`-ge 35`/`-ge 10`→`-ge 3500`/`-ge 1000`）阈值同步换算；shield_activate 日志字段改 psi_int/cpu_psi_int。
### Verified
- 剖析账本修正（v1.13.1 bench 公式 20 倍偏差纠正后重测）：find_camera_provider ~560ms/tick 均摊 + focused_pkg 40ms + bt3 80ms + date/pidof/psi 等小件 ≈ 每 tick 1s 量级 → 解释 fluency 50-64% 单核；部署后以 120s CPU 增速采样验证（目标 <10%）。

---

## [v1.13.2] - 2026-10-27
### Fixed（耗电治理——10-27 用户报告耗电异常，取证 fluency 日均 CPU 28,489s = 7.9h = 50% 单核，占整机 cpu 功耗桶的主要份额之一）
- **tick 时间合并**：循环顶部一次 `date +%s` 全循环复用（原 6 次 date fork+exec ≈120ms/tick——fork+exec 二进制含动态链接开销，是 tick 内单项最大开销）。
- **focused_pkg(dumpsys window ~40ms) 降频 5s→10s**：非采样 tick 沿用上一状态；相机激活/退出判定延迟 ≤10s（相机启动到可拍摄 >2s，可接受，如实记录 trade-off）。
- **FR-BT3 logcat 辅助通道降频 5s→20s**（实测 ~80ms/次）：pid 换代主通道仍在 5s 层兜底；20s 采样周期 < 3000 行≈60s 窗口，不致盲。
- **bt1/bt2/bt3 触发段复用同一次 com.android.bluetooth pidof**（省 2 fork/触发）。
- **logx 截断检查节流**：wc -c 全文件读 + fork 从每次写都查改为每 64 次写查一次（风暴期最热的隐藏 fork；日志超限最多多滞留 ~10KB）。
- 目标：tick CPU ~400ms → ~120ms（-70%），风暴期放大同比例收敛；预期 fluency 日均 CPU 从 7.9h 降至 <1h。
### Verified
- 剖析数据（修正了此前 bench 公式 20 倍偏差后的重测）：focused_pkg 40ms / bt3 80ms / date 20ms×6 / pidof 20ms×2，tick 合计 ~300-400ms，风暴期放大 3-5 倍 = 50% 单核的构成解释；风暴期 fork/exec 单价暴涨（缺页）解释了"平静期组件便宜但日均 CPU 高"的表观矛盾。
- 本次雷鸟断联（10-26 晚）双通道均未触发：应用未死（pid 未换代）+ ACL 广播未入 main buffer——logcat 广播通道在 One UI 16 确认无效化，pid 换代通道语义正确、等待首次真实样本。当前蓝牙已回连（RayNeo iO-1477 ACL BR/EDR:Y）。

---

## [v1.13.1] - 2026-10-26
### Fixed
- **FR-BT3 断联检测双通道**：新增 RayNeo 应用 pid 换代通道（16:05 实战铁证：换页风暴压死应用 26856→14948 → 伴随连接断开 → BLE 重扫；应用死亡重启是断联可靠前奏，pidof 基线每 tick 比对，+1 fork）；logcat ACL 广播通道降为辅助（One UI 16 实测断联窗口 main buffer 无广播行）。两通道任一命中即 25s 护航；logcat 通道仅在无换代时评估（短路保持 3 fork）。
### Verified
- 部署回归全绿（ver=1.13.1 四处统一 / 4 进程 / collect_stats）；双通道触发样本待下次断连采集。

---

## [v1.13.0] - 2026-10-26
### Added（三天两起 OOM + 护航风暴取证后的干预经济学重构）
- **护航批量引擎 guard_boost_batch / guard_restore_batch**：flush/bt/bt2 六函数内循环从逐 tid renice（每 tid 2 fork，66-110 线程 = 每轮 130-220 fork）改为两级 awk 管道（单次批量读 /proc/*/stat 去 comm 后第 17 字段=nice → sort 按增量分组 → 按组批量 renice，toybox 重复 -p 传参 ≤40 tid/批，同 storm_restore_pending 实证模式）——单轮 fork 降至 ~6。GEMINI 铁律（已优跳过）与 v1.7.0 Fix-B 差分还原语义逐字保持；bak 行格式不变。
- **FR-C3 风暴态**：1h 滑动窗口借相机 ≥6 次进入护航维持模式——首提权后不再反复提权-还原，风暴解除（过期且触发条件消失）或 30min 硬顶一次性还原；触发判定抽为 `_frc3_trig` 供两分支复用。深夜(00-06)借相机命中记 `act=frc3_night_hit`（A 级）。
- **FR-SS 升级链**：trim 成功后 300s 强制复测 → 未回落追加 trim（force 跳冷却）→ 连续 2 次无效=真泄漏特征 → 落 `run/soft_reboot_advised.flag` + E 级日志；堆回落自动撤除。深夜兜底探测间隔 1800→600s（小时由 epoch 换算，零新增 fork）。
- **WebUI 软重启建议横幅**：`#advise` 卡片读取 flag 醒目展示（建议只递到眼前，绝不代重启）。
### Fixed
- **FR-BT3 窗口 160→3000 行**：10-23 取证致盲机制（ClashMeta DNS 风暴下 160 行 ≈1-2s 历史 < 5s 采样周期，断连广播在两次采样间老化出局）；护航结束加 90s 冷却防同一广播重复触发。dumpsys 状态差分方案否决（断连后 3-5s 即重连，30s 采样来不及护航）。
- **日志取证窗口翻倍**：logx 截断基准 256KB→512KB（10-25 04:15 OOM 窗口审计行被风暴期流量挤出 128KB 保留面）；capture_incident 追加 64KB 主日志尾部快照。
### Verified（真机 2026-10-26 13:31 部署，13:31-16:09 首战）
- 批量引擎无损往返实测 PASS（自身 pid 0→-5→0）；bt2 实跑 boost 105/restore 97；FR-C3 风暴态两次完整闭环（14:03 on cnt=6 → 14:33 off 一次性还原 49；14:36 on cnt=7 → 15:06 off 51）；主护盾 16:05:54 cpu_psi 58.21% 精准护航 RayNeo 前台；日志无异常。

---

## [v1.12.9] - 2026-10-23
### Fixed（10-22 15:47 system_server OOM 498MB 取证后修复；接手 Codex 线程收口）
- **FR-SS system_server 堆双水位主动防护**（`mt_lib.sh` `ss_health_probe` 重构）：`SS_TRIM_KB=471040`（460MB）→ trim+审计；`SS_ALERT_KB=496640`（485MB）→ 告警+trim；trim 冷却 600s 限频；定期兜底探测 `SS_PROBE_EVERY=1800`——修复「堆爬升但 RSS/线程未越限」的探测盲区（10-22 事故堆 472→498MB 期间 RSS 门控未触发）。
- **ss_heap_probe 探测经济性**：旧实现连续两次 `dumpsys meminfo system_server`（判定+快照各一），堆高水位上执行等于火上浇油 → 单次 dumpsys 落临时文件，判定与快照共用，结果落 `SS_HEAP_KB_FILE`。
- **FR-BT2 防抖入**：psi≥5% 需连续 2 tick（10s）确认（`bt2_should_boost` 内计数），防 PSI 0.5-16% 高频抖动导致单 tick 触发的起落风暴。
- **高 CPU 退避**（fluency_shield.sh）：cpu PSI some ≥35% 时抑制 FR-BT/FR-BT2 新增提权（活跃护航照常还原）——防干预风暴在高 CPU 饱和窗口叠加 fork 负载饿死 GC（10-22 事故 cpu_psi 26-44% 下 flush×4/bt2×5/shield×5 约 1000+ fork 是共犯之一）；FR-C3 不退避（cpu≥35 本就是其正向触发条件）。FR-BT2 还原冷却 30s→90s。
- **可观测**：`collect_stats` 新增 `ssheap=` 字段，卡片描述追加 `·SS堆NMB`。
- **版本串全量统一**：v1.12.2-v1.12.8 期间残留的 mt_lib/memtonic/fluency/module.prop/cpu_guard 版本全部对齐 v1.12.9（versionCode=38）。

### Verified（真机实测，2026-10-22/23）
- `am send-trim-memory <sspid> RUNNING_CRITICAL` 对 system_server 可用（RC=0），2s 内堆无变化——定性为弱杠杆，泄压主力是哨兵降载防饿死 GC；`COMPLETE` 被拒（"Unable to set a background trim level on a foreground process"）。
- 部署回归：staging md5 预检 5/5 → 备份 `scripts.bak-129` → 原子替换 → 设备侧 md5 5/5 → 重启；`event=start ver=1.12.9` + fluency start ver=1.12.9 双确认；WebUI 同路径 `collect_stats` 含 ssheap 字段；`ss_health_probe` 实跑 rc=0（当前堆 291MB，远低于 460MB 水位，双水位正确静默）。
- 诚实边界：SS 堆基线 450MB+ 为固件+LSPosed 结构体量，模块无法缩小；真泄漏（trim 后 485MB+ 持续 30min）只能黑匣子+建议软重启，不代执行。

---

## [v1.12.8] - 2026-10-20
### Added
- **FR-BT3 RayNeo BR/EDR 主动断连后的 LE 重连护航**：logcat 近 160 行出现 RayNeo 的 ACL_DISCONNECTED → BT 栈/HAL/audioserver 提权 25s，护航 LE 直连重连窗口，窗口结束差分还原。真机部署验证：v1.12.8 启动、四 worker 健康、观察期无新增错误/tombstone。

## [v1.12.7] - 2026-10-20
### Changed
- **cpu_guard 相机/图库白名单改为活跃态门控**：退到后台后不再无条件豁免（防后台相机进程持续高 CPU 无法干预）。

## [v1.12.6] - 2026-10-19
### Fixed（设备漂移热修）
- FR-9 触发口径纳入 CPU PSI（mem 或 cpu 双通道）；`ss_health_probe` 接入 cpu_guard 巡检挂载点；`memtonic.sh` 生命周期修复（先清理 history 孤儿 fluency_shield 再启动，防旧实例继续跑而新主守护误判子进程已托管）；FR-C3 预判性提权（face-service 存活 + cpu≥35%/mem≥10% 时提前介入，不等 D 状态）；`fg_majflt` 虚报封顶。

---

## [v1.12.5] - 2026-10-18
### Fixed
- **FR-C3 提权泄漏（P1）**：`flush_guard_restore` 在三个清理路径（`fluency_shield` 启动自愈、`memtonic.sh stop`、`uninstall.sh`）中均未调用，导致进程在 stop 时若正处 FR-C3 护航窗口，face-service/provider 线程可能永久留在 -8。已补齐三个清理路径。
- **FR-C3 每 tick 高开销（P2）**：FR-C3 主循环每 5 秒全盘扫 /proc 找 provider，每日数百万 fork。已降频为每 4 tick 一次（即 20 秒），并且只在 face-service 实际存活时扫。
- **FR-BT2 与 FR-BT 并发竞态（P1）**：FR-BT 和 FR-BT2 共用同一个 `bt_guard.bak`，同一 tick 双触发时可能双重提权/双重还原。FR-BT2 已改为独立状态机和日志路径，`memtonic.sh stop` 同步补齐 `bt_guard_restore` 清理。
- **system_server 堆压取证（P2）**：新增 `ss_heap_probe` 函数（当前未接入周期巡检，只是预置）。观察发现 system_server 的 Dalvik 堆 RSS 高于 300MB 时自动落盘取证。
### Added
- **FR-BT2 蓝牙 LE/GATT 压力护航（观察期）**：RayNeo 应用存活且最近 100 条系统日志内 RayneoForegroundService 出现 ≥2 次时，BT 栈/HAL/audioserver 逐线程提权 -8；PSI mem some avg10 ≥5 时立即触发，回落 <3 连续 2 tick 还原 + 30s 冷却。真机已连续 3 次闭环（21:28 / 21:37 / 21:40）。
### Battery（观察）
- 总耗电 2491 mAh，主要来自屏幕 433、B 站 341、系统 303、Chrome 143、抖音 82.9、微信 77.6、Google 搜索 73.6、淘宝 41.6、蓝牙 62.3。RayNeo 在 21:11-21:17 期间反复从后台拉起前台服务，与 BLE 连接超时重叠。
---

## [v1.12.4] - 2026-10-16
### Fixed
- **计数器恒为 0（P0）**：`collect_stats` 的 `_st_rogue` 与 `_st_compact` 使用 `grep -c 'A\|B'`，但设备上的 toybox grep（0.8.12-android）**不支持 `\|` 交替**（实测：对含 AAA/CCC 的文件 `grep -c 'AAA\|CCC'`=0，而 `grep -cE 'AAA|CCC'`=2）。受影响的两个计数器必然恒为 0。修复为 `grep -cE 'A|B'`。设备实测：内存压实计数由 0 修正为 23（功能实际一直在工作）。
- 全模块排查确认：仅 `collect_stats` 两处使用该模式，其余为单模式 grep（无害）。
### Added（UI 可用性）
- **计数卡新增状态徽标**：每张卡片显示"已触发 N"或"待命中"，并列出白话触发条件（如"连续 3 分钟 >50% CPU""内存压力 ≥25% 持续 2 分钟"）。用户可据此区分"功能待命"与"功能损坏"，避免把未达阈值误判为故障。
### Notes
- 本次不改动任何调度/提权逻辑，只修计数器表达式与前端展示。诊断结论：五项"恒为 0"中，内存压实是计数器 bug（功能正常），毒瘤降权/灾难黑匣子/蓝牙护航是**确实未满足触发条件**（代码逻辑经审查与实测复现均正确），地雷告警为**默认 dry-run 未开启**且无 enabling 回滚可告警。
---

## [v1.12.3] - 2026-10-16
### Fixed
- **WebUI 控制按钮完全失效（P0）**：旧版按钮 HTML 写 `onclick="ctrlStart()"` / `onclick="ctrlStop()"`，但脚本只定义了 `ctrl(op)`，无从定义函数也无 window 挂载 → 点击必抛 ReferenceError，页面毫无反馈。修复：移除全部内联 onclick，改为 `data-act` + 事件委托统一分派（未定义动作会走 default 分支显式报错，而不再静默失效）。
- **刷新可能永久卡死**：`execCmd` 无超时，一旦管理器回调丢失 Promise 永不 resolve，面板永久停在旧数据且不报错（官方 npm `kernelsu@3.0.2` 的 exec 同样无超时，属桥接层固有风险）。修复：execCmd 增加 20s 超时 + settled 双保险，超时以错误态返回并提示可重试。
- **数据不更新的观感**：新增"数据更新时间"与"自动刷新倒计时"，刷新失败展示红色原因；自动刷新仅在页面可见且空闲时执行（原实现 30s 定时无在途去重，可叠加并发命令）。
- **空字段渲染异常**：PSI 字段缺失时渲染成 "% / %"。修复为空值统一回落 `--`。
- **护栏护航计数恒为 0**：卡片 kv 键误写为 `perf`（collect_stats 实际输出 `shield`），导致该卡片永远显示 0。修复为正确键名（设备真实数据回归发现）。
### Changed
- **UI/UX 重做**：状态徽章 + 数据更新时间 + 自动刷新倒计时；内存/PSI 进度条（≥15% 转黄、≥30% 转红）；9 张事件计数卡改为带口径副标题的两列网格；操作区按钮改为内联 SVG 图标 + ≥44px 触控高度；确认操作改为页面内自绘弹窗（不再依赖 window.confirm——WebView 未设置 WebChromeClient 时会静默返回 false，等同于按钮失灵）。
- **busy 状态可视化**：操作期间显示转圈 + 秒计 + 全部按钮禁用（单飞），60s 看门狗兜底解锁并提示。
- **启动文案修正**："约 5 秒" → "约 30 秒"（设备实测 optimize 耗时 28.27s）。
- 移除恒为空的"守护自身 CPU"字段（定义了但从未赋值，属死字段）。
### Verified
- `node --check` 语法通过；`data-act` 与 case 分支一一对应（refresh/start/stop），内联 onclick 归零。
- Node 最小 DOM + 假 KSU 桥测试台 16/16 通过：初始化渲染、点击启动→确认弹窗→命令下发、回调丢失→超时错误态（不锁死）、字段缺失不抛异常、busy 期间二次点击被单飞拦截。
- 设备真实 collect_stats 输出回归通过（state/pid/shield/storm/crash/mjburst/avail_kb/psi 全部正确解析，护栏 37·风暴 2·崩溃 3·指纹 221 与设备一致）。
- 部署为单文件热替换（webroot/index.html），回滚点 /data/local/tmp/index.hotfix-backup.html（md5 40880f0073d04114340995b35e0aaefe）。



---

## [v1.12.2] - 2026-10-16
### Fixed
- **fg_majflt_burst 大幅虚高（四个数量级级）**：`mt_lib.sh` 的 `fg_majflt_sum` 原版实现把 cgroup tasks（每行 tid，含主线程+线程）当作 pid 列表逐行读 `/proc/pid/stat` 的 `majflt` 字段，由于多个线程是同 pid 的并行累计，直接求和会把同一段 majflt 活动重复累计。因此 454M/60s、614M/60s 这种"四个数量级"的告警是同线程集合多次重复求和产生的假数据，不是真实的 majflt 增量（真机实测 60s 内 com.tencent.mm:appbrand0 主体 majflt 仅从 25670 → 32047，增量 6377 次，同线程集合错误的求和却是 454M）。
- **fg_majflt_burst 阈值误判**：v1.10 原设计只做单 pid 集合差分，但实际 top-app cgroup 切换一个进程后，`_fg_mflt_prev` 还是旧集合的累计值，导致 454M-454M=0 而跳过告警，而下一次 614M-454M=160M 误报。现在改为顶层 `_fm` 为单线程集合聚合行为，差分仅在"同 pid 子线程集合"内部有意义，切换窗口触发"负值→归零"是正确保护（线程切换只 hinted，不刻意差分跨进程集合）。
- **`local` 语法兼容**：`fg_majflt_sum` 修正后使用 `local _path`（mksh 语法兼容，无需 unset 避免全局值污染）。
### Notes
- 真机复测在 2026-10-16 午后窗口进行。

---

## [v1.12.1] - 2026-10-15
### Fixed
- **WebUI 状态读取根因修复**：`mt_lib.sh` 以 `dirname($0)` 推导模块目录，在 KernelSU WebUI exec（`. mt_lib.sh; collect_stats`）上下文中 `$0` 为 shell 自身 → `MODDIR` 错指 `/system` → pid/日志全部落空，面板恒显「已停止(pid NA)/计数全 0」。修复：派生目录不含本库时回落到模块固定安装路径；常规执行与被守护脚本 source 的路径零影响。真机回归：WebUI 同路径返回 `state=running` + 真实 pid 与计数，跨真实重启稳定。

### Added
- **`memtonic.sh optimize` 一键系统优化**（WebUI「启动守护+优化」按钮调用）：风暴期拒绝；Launcher 逐进程 `renice_tree` 提权（与风暴护栏同参数）；息屏时执行全套维护（内存压实），亮屏时按 GEMINI 铁律跳过压实（防掉帧）并如实提示；`webui_optimize/_end` 审计行落盘。
- **WebUI 守护启停控制**：状态卡新增「▶ 启动守护+优化 / ■ 停止守护」按钮，执行结果 stdout/stderr 回显（成功绿/失败红）；操作期间暂停 30s 自动刷新防结果被清。

### 边界（不变）
不杀进程 / 不冻结 / 不动 zram / 不持久内核参数 / 亮屏严禁压实。

---

## [v1.12.0] - 2026-10-14
### Added（FR-BT + FR-C2，源自 10-13 晚相机连拍卡顿 + 蓝牙爆音取证）
- **FR-BT 蓝牙音频守卫（BT Sentinel）**：BT 栈 5s CPU jiffies 增量按 `getconf CLK_TCK` 归一化判流活跃（阈值 3% 单核）；相机活跃或 PSI≥8% 时对 BT 栈/HAL/audioserver **逐线程** renice -8（内核语义：renice(taskgid) 只作用主线程）；3 tick 防抖还原 + 30s 冷却；护航中 BT 栈重启立即重护航。GEMINI 铁律：已高于 -8 的线程跳过。
- **FR-C2 相机 provider 大核亲和**：provider 全部线程 `taskset f8`（cpu3-7，SM8550 中核+prime），备份原始 mask 退出逐 tid 无损还原；与 Camera Sentinel 同生命周期。
- **零功耗纪律**：检测搭 fluency_shield 既有 5s 循环便车，`bt_stack_cpu` 用 mksh 内建 read 直读 `/proc/pid/stat`（零 fork），每 tick 仅 1 次 pidof fork；亲和仅相机会话期存在。
- **启动自愈**：启动时先无损还原上一实例可能残留的 bak（提权中途死亡的防御闭环）。

### Fixed（部署前自审 4 项）
- jiffies 阈值未按 HZ 归一化（250Hz 内核空闲即误触发）→ `CLK_TCK` 实测归一；
- toybox awk `tolower` 依赖 → `tr 'A-F' 'a-f'` 替代；
- 护航中 BT 栈重启新进程裸奔 → pid 变化立即重护航；
- mask 备份读取字段校验加固。

---

## [v1.11.0] - 2026-10-10
### Added（状态可视化）
- **卡片动态统计**：`collect_stats`（key=value 单行）+ `update_module_desc`（awk 原位替换 description 行，run/ 临时文件 mv 原子落位；version/versionCode 永不触碰）——事件驱动 + 每小时 + 每日心跳三类刷新点。
- **KernelSU WebUI 状态面板**：`webroot/index.html`（exec 兼容层 + 8 张统计卡 + PSI 进度条 + 黑匣子/incident 列表）。

---

## [v1.10.0] - 2026-10-10
### Added（内存风暴三件套，源自 2026-10-09 Synology Photos 转码事故取证）
- **P1-1 mem PSI 连续监测**：`psi_mem_read` 挂载 cpu_guard 60s 轮——mksh 内建 `read` 复合重定向零 fork（真机实测 fork 版 `cat` 9.35ms/次 → 内建 <0.5ms），零新增唤醒源。常态静默，仅超阈记日志。
- **P0-2 灾难黑匣子**：连续 2 轮 `psi_mem some≥25`（= 持续 2 分钟）落盘 `run/blackbox-*.log`——PSI 三项 + avail/swap + kswapd + RSS/majflt 双 Top10（单次 `/proc/[0-9]*/stat` 遍历同时取双指标，前 3 名补包名）。冷却 900s + 每日 10 份封顶 + 轮转保留 5 份。背景：10-09 事故的关键证据（PSI full 10.6% / majflt 18,486）靠 daagent ANR 报告碰巧带出，黑匣子让取证不再靠运气。最坏开销 0.04% 占空比（对照 10-09 风暴 kswapd 22%）。
- **P0-1 亮屏风暴级压实例外**：`maintenance` 新增 `storm=1` 第二参数——GEMINI"亮屏禁压"铁律保留，唯一例外通道 = `psi_mem some≥30`（cpu_guard 探针硬阈值保证）；相机/截屏/启动风暴守卫**无条件生效**；与息屏 R3 路径共用 `last_compact.ts` 统一 900s 冷却（R3 原冷却 3600s 同步收紧）。
- **P1-2 kswapd_growth 顺手压实**：kswapd 每小时 CPU > 90s（换页风暴实锤）时经风暴级例外通道触发一次压实（1h 判定周期天然限频），不再只写"建议软重启"。
- **P2 前台 majflt 差分指纹**：`fg_majflt_sum` 单次 awk 汇总 top-app 全部 pid 的 majflt，60s 差分 ≥500 记 W 级预警（10min 限频）——转码/媒体导入类负载信号，为 rmg_sentinel 试点铺路。

### Changed
- `mt_lib.sh` 头注释升级 v1.10.0；新增 `psi_mem_read`（变量返回式，杜绝 `$()` 子 shell fork）/ `fg_majflt_sum` / `mem_blackbox`。
- `cpu_guard.sh` 主循环新增 `mem_probe` 挂载点（check_dropbox 之后、风暴短路之前——取证不避风暴期）；新增探针常量组。
- 字段索引推演验证：去 comm 后 stat `majflt=$10`、`rss=$22`（与 `cpu_ticks_of` 的 `$12+$13=utime+stime` 同源核对一致）。

### 边界（不变）
不杀进程 / 不冻结 / 不动 zram / 不持久修改内核参数（`compact_memory` 为一次性动作，非参数写入）/ 无 sepolicy / 无 boot 脚本。

---

## [v1.9.12] - 2026-10-08
### Added（全模块 ARG_MAX 深度审计，7 脚本全覆盖）
- **审计范围**：memtonic.sh / mt_lib.sh / cpu_guard.sh / fluency_shield.sh / storm_guard.sh / vk_injector.sh / in_app_stress_test.sh 的全部"大输出传参"路径——`printf '%s' "$var"`、`echo "$var" |`、`$(cmd)` 完整捕获、批量 renice 传参、字符串累积清单（done_pids / app_list / batch_tids）。

### Fixed
- **in_app_stress_test.sh gfxinfo 捕获（同型预防性封堵）**：`gfx_raw=$(dumpsys gfxinfo)` 完整捕获后经 `echo "$gfx_raw" |` 两次管道传参。实测空闲态 gfxinfo = 6,952 B（最长行 1,325 B）暂未触发，但压测态（500 monkey 事件 + 帧直方图累积）显著更大，且与 v1.9.11 哨兵缺陷同模式 → 改为落临时文件快照 + awk 直读。附带收益：崩溃判定与字段解析消费同一份数据（快照一致性更优）；三处清理（崩溃分支 / 解析完成 / trap 兜底）保证任何退出路径无残留。

### Verified（实测数据支撑，设备探针取证）
| 数据源 | 实测大小 | 判定 |
|---|---|---|
| `dumpsys rollback` | **157,756 B（154KB）** | **>128KB 单参上限 → 证实 v1.9.11 初版哨兵 ARG_MAX 缺陷 100% 必触发**（每次调用必报 Argument list too long；无地雷时因碰巧静默正确而极难察觉）。修复后 stderr 干净、日志错误计数 = 0 |
| `dumpsys gfxinfo`（空闲态 launcher） | 6,952 B（最长行 1,325 B） | 未触发，属同型预防性封堵 |
| `pm list staged-sessions` 单行 | 121 B | 安全（`check_rollback_disarm` session 判定） |
| `/proc/pressure/memory` | 110 B | 安全（`psi_mem_pressure_high` 三处 echo） |
| `storm_restore_pending` 批量 renice | ≤50 tid/批 ≈600 B | 安全（设计即有上限） |
| `cpu_guard app_list` / `storm_window done_pids` | shell 内建（for 展开 / case 匹配） | 不经 execve，无 ARG_MAX 概念 |

### Fixed（归因修正）
- **撤销上轮"stop 还原路径偶发 printf Argument list too long（reniced_tid 大清单）"的错误归因**：报错前缀 `memtonic.sh[223]` 是铁证——L223 正是 `check_rollback_disarm` 调用行，stop→restart→start 时由初版哨兵在启动路径触发；`storm_restore_pending` 批量 renice（≤50/批）设计安全，**无独立缺陷**。

### Changed
- 版本串同步：`fluency_shield.sh` 日志 `ver=1.9.10` → `v1.9.12`（v1.9.11 遗留的不一致，违反 v1.9.4 确立的"各脚本版本号与文档一致"约定）；`mt_lib.sh` / `memtonic.sh` 头注释同步并补审计说明。

## [v1.9.11] - 2026-10-08
### Added（Staged Rollback 自动排除哨兵 + sspid 门闩重置 + 环境基线）
- **check_rollback_disarm 哨兵（P1'）**：2026-10-08 00:16 取证确认软重启被升级为完整重启的根因——RollbackManager 在框架重启时自动应用 enabling 态 staged rollback 并强制 `reboot(rollback_staged_install)`（CrashRecovery Events "Rolling back sdkext/adservices.api, Reason:1" 铁证，8-22 起共 5 次同源事件）。哨兵每 6h 去重检测 `dumpsys rollback` 中 `state: enabling` 的 rollback，通过 `pm install-abandon <originalSessionId>` 自动排除（rollback 依附 install session 生命周期——实测 One UI 16 已移除 `pm rollback-abandon`/`cmd rollback` 全部管理命令，此为唯一有效路径）。session 三分类安全语义：目标 session 已不存在（orphan_gone）或已失败（orphan_failed）仅记录无需处置；活动安装中（active）跳过等待下轮。**默认 dry-run**（仅告警不动手），用户确认后 `touch run/rollback_disarm.enable` 启用真实处置；处置成功复查 enabling 归零才写 `run/rollback_disarmed.flag` 并记录 A 级日志。
- **system_server PID 变化检测（主循环）**：检测到 sspid 变化时自动重置 vk_injector 门闩 flag 并重拉只读监视器（vk_injector 为一次性脚本，PID 变化后 flag 失效需重拉才闭环）。主循环粒度 1h 属审计用途；即时风暴响应与黑匣子快照仍由 storm_guard 5s 粒度负责，职责不重叠。
- **env_baseline 环境基线**：启动时记录 max_cached_processes / ro.lmk.medium / bg_apps_limit / watermark_scale_factor 快照，LMK 属性被外部注入（Scene 类模块）时告警，防环境篡改无感知。
### Verified（2026-10-08 实测）
- 手工处置验证：`pm install-abandon 1995438793` → Success，rollback 475126124 由 enabling 转 deleted，目录清理，35 分钟后复查无复现。
- v1.9.10 防护实战生效：13:56:49 `warn=kswapd_growth ... reason=staged_rollback_active count=1`（soft_reboot 建议被正确抑制）。
- 设备现存 332 个 staged sessions 堆积为 root 环境（Zygisk/LSPosed）干扰 mainline APEX 激活的系统性根源，哨兵上线后自动处置 enabling 态，无需人工介入。
### Fixed（部署实测发现并修复）
- **check_rollback_disarm ARG_MAX 失效缺陷（P0）**：初版用 `printf '%s\n' "$_rb_dump"` 传递整个 dumpsys 输出，设备实测 >140KB（332 个 staged sessions）超过单参数 128KB 上限报 "Argument list too long" → 管道断流 → rb_id 永远为空 → 哨兵完全失效（且无 enabling 时碰巧静默正确，极难察觉）。修复：dumpsys 直连管道不经 shell 变量（与 abandon 复查行同构）；两次 dumpsys 间状态变化的 race 走 "originalSessionId 解析失败" 安全降级，不会误 abandon。修复后手动调用 RC=0 且 stderr 干净。

## [v1.9.10] - 2026-10-07
### Fixed（Camera Sentinel 双 bug，2 亿像素拍照实测发现）
- **camera_sentinel_off 永不触发（VIP 泄漏）**：v1.9.7 用 `pidof com.sec.android.app.camera` 检测相机活跃，但实测相机退到后台后进程不死，pidof 仍返回 PID → sentinel_off 永不触发 → camera_vip_off 永不执行 → VIP 提权永不还原。改为 `focused_pkg == com.sec.android.app.camera` 前台焦点判定（读 dumpsys window mCurrentFocus ~50ms，无锁无副作用），退出前台立即触发还原。
- **camera_vip_on renice 结果不可审计**：实测 cameraserver/provider renice 后 nice 仍=0（疑被 Android SchedulingPolicy 服务拉回），但旧版无结果验证。增加 renice 后回读 actual_nice 并记录 `result=ok` 或 `result=actual=N msg=renice可能被系统调度策略重置`。

## [v1.9.9] - 2026-10-07
### Performance（基于分段计时实测的根本性重构）
- **cpu_guard 扫描耗时 16s → 预期 <2s（实测待验证，预期提速 65 倍）**
- 分段计时定位瓶颈：`is_app_uid` 内逐进程启动 awk 读 `/proc/*/status` = 956 次 awk × ~17ms 启动开销 = **16,170ms/轮**（占墙钟 60%）；单次 awk 批量处理全部 status 文件 = **250ms**（实测对比数据）。
- 新增 `snapshot_app_pids()`：一次 awk 批量提取所有 uid>=10000 的 pid 列表，`scan_cpu_rogue` 与 `take_ticks_snapshot` 改为基于列表迭代，消除循环内逐进程 awk 启动开销。
- `scan_cpu_rogue` 循环入口删除冗余 `is_app_uid` 调用（已在 snapshot 内完成）。
- 保留 v1.9.8 delta-first 空闲快路径与 done_ms 审计。

## [v1.9.8] - 2026-10-07
### Optimized（功耗治理）
- `cpu_guard.sh` 主扫描改为 **delta-first**：先算本窗口 CPU 增量，空闲进程（delta=0）零成本跳过 pkg 解析（`pkg_of` 需 strings+head+cut 三次 fork，约 950 进程/轮）与全部豁免判定；仅活动进程做完整判定。毒瘤/极端爆发/恢复语义不变（空闲不可能成为毒瘤；空闲已干预进程经缓存包名走恢复路径）。
- 每轮扫描输出 `act=cpu_scan done_ms=` 耗时审计行，功耗收益可持续量化。
- `rogue_throttle` 缓存 `_pkg_`，空闲恢复路径免重复解析；`rogue_restore_one` 同步清理缓存（防 PID 复用污染）。
- 基线更新不变量保留：任何 continue 之前先更新 `_ticks_` 基线。

## [v1.9.7] - 2026-10-07
### Removed（负优化清除，基于 7 天日志取证 + 多方交叉验证）
- **废除全局 Vulkan 注入**：`vk_injector.sh` 重写为只读监视器。实测 `debug.hwui.renderer=skiavk` 在 Adreno 740 + Android 16 引发 34+ 次 `Pipeline create failed`（命中 SystemUI/微信/桌面/GKD/KernelSU 管理器）；原"settings 清空→1s→回写"撞 AMS 初始化窗口致无障碍永久掉绑（对照实验证实）。不再执行任何 setprop / kill / settings / am 操作。
- **废除 dumpsys media.camera 探针**：实测单次 19,038 行 / 521ms，每 5s 轮询须持 CameraService 全局 mServiceLock，为 60fps→30fps 锁帧直接根因；且原 grep 判定 7 天触发 0 次（状态机全盲）。改为 O(1) `pidof com.sec.android.app.camera` 探测。

### Fixed
- 相机/相册包名加入 WHITELIST_PKGS：实测 10-07 20:55:32 与 21:42:33 两次风暴窗口内相机被 nice 0→5 降权，与"保相机"设计目标相反。
- storm_window 新增 `STORM_MAX_APP=60` 削峰总量上限：软重启风暴窗口实测对 95 个冷启动应用（含 permissioncontroller/chrome/mediasearch）集体降权，反而拉长启动尾延迟。
- `camera_vip_on` provider 匹配修正：通配 `*camera.provider*` 实测误命中 USB 外置摄像头驱动，改为两段式（先精确匹配 `*samsung.hardware.camera.provider*`，无结果再兜底通配）。
- FR-9 护盾冷却 5s→60s，降低高 PSI 持续期反复提权-还原震荡。
- 版本串统一：memtonic.sh start 日志 ver 与 module.prop 同步（修复 1.9.5/1.9.6/1.9.4 三处不一致）。

## [v1.9.6] - 2026-10-02
### Fixed
- 修复 `uninstall.sh` 盲杀问题，强制在 `kill` 之前校验进程的 `cmdline` 以避免 PID 复用导致的变砖风险。
- 修复 `mt_lib.sh` 中 `alive()` 函数逻辑，支持匹配 `storm_guard` 与 `fluency_shield`。
- 修复 `vk_injector.sh` 中的多 PID 参数处理错误，移除包裹变量的引号并改用 for 循环处理每个 PID。

## [v1.9.5] - 2026-10-01
- 版本打包发布与常规更新。

## [v1.9.4] - 2026-10-01
### Fixed
- 移除 module.prop 中无效的 updateJson 配置。
- 同步各脚本版本号与文档说明一致性。
- 修复 service.sh 和 uninstall.sh 中的绝对路径解析问题，统一使用 dirname。
- 修复 cpu_guard.sh 中死线程泄露导致 renice 清单无限增长的问题。

## [v1.9.3] - 2026-10-01
### Fixed
- 修复 memtonic.sh start 无参数调用因为空参数检查逻辑遗漏而无法启动的问题。
- 修复 CHANGELOG.md 中的 markdown 转义错误。
- 移除硬编码路径，提高可移植性。
- 更新 service.sh 和 uninstall.sh 头部注释至 v1.9.3。
### Added
- 增加 updateJson 以支持 KernelSU 更新检测。

## [v1.9.2] - 2026-10-01
### Fixed
- 移除全局 IPv4 TCP sysctl 注入（MTU 和 Keepalive），避免影响整机网络及带来潜在待机耗电问题（真正的 MTU 瓶颈在 IPv6，需在代理客户端解决）。
- 清理 mt_lib.sh 中的死变量 KSWAPD_GROWTH_WARNED_TS。
- 清理 uninstall.sh 中失效的 restore_kswapd 还原逻辑。
- 补全 memtonic.sh 的 case *) exit 1;; 默认兜底分支，并修正为 `""|start)` 以兼容无参拉起和显式 start。

## [v1.9.1] - 2026-10-01
### Added
- 网络假死底层救援：注入激进的 TCP Keepalive (120s) 与 FIN 快速回收参数，缓解代理软件僵尸连接。
- MTU 分片自愈：开启内核 TCP MTU 探测 (`tcp_mtu_probing=1`)，适配 VPN 巨型帧。
- 进程防护：将 FlClash/Clash Meta 加入豁免白名单，杜绝其被降权。

## v1.9.0 — Reclaim Liberator, Dual-PID Fix & Suggestion Mutex（2026-10-01）

### 废除：彻底废除 Kswapd 物理隔离（解放大核，终结 Direct Reclaim 停机）
- **真机实测定论**：设备底层 Power HAL 会周期性自动将 kswapd 打回原生掩码 `7f`（CPU 0-6），模块执行的 48 次 `taskset 0f` 不仅全被内核覆写，且在局部生效期间将 CPU 3-6 大核剥离，诱发直接回收（Direct Reclaim）与 Allocstall 激增。
- **零干预彻底止血**：完全移除 `mt_lib.sh`、`memtonic.sh`、`fluency_shield.sh` 中的 `isolate_kswapd`、`restore_kswapd` 及状态锁，kswapd 亲和性彻底交由内核原生管理，消除无效 taskset churn 与潜在掉帧负优化。

### 修复：双 PID 提权与还原崩溃（三星应用分身/微信前台护盾真正生效）
- **根本原因**：`com.tencent.mm` 在双开（User 95）环境下，`pidof` 返回 `"17577 17976"`。原脚本直接传给 `toybox renice -p` 导致报 `bad pid` 语法错误，导致微信前台护盾与截屏预提权 100% 空跑。
- **重构实现**：
  - **Screenshot Sentinel 焦点预护航**：改为 `for _sc_p in $sc_fg_pids` 逐 PID 检验 cmdline 后操作；备份文件改为多行键值记录；还原时采用 `while IFS=: read` 循环差值还原；严禁对已高优线程反向降级。
  - **FR-9 前台护盾**：遍历 `pidof` 返回列表，校验 cmdline 后锁定主进程 PID 与对应 RenderThread 提权，彻底修复三星多开微信提权失效。

### 修复：消除 do_not_reboot 与 suggest=soft_reboot 矛盾建议
- 在 `memtonic.sh` 的 `kswapd_growth` 告警建议中接入 staged rollback 检测：若当前存在 `state: enabling` 的挂起回滚任务，**严禁输出 `suggest=soft_reboot`**，改为输出 `note=soft_reboot_suppressed`，消除运维建议内部打架，杜绝误导用户软重启而诱发 APEX 回滚导致 Root 丢失。

### 修复：CPU 护栏 ticks 基线更新时序倒置与 eval 变量泄露
- **基线前移**：将 `cpu_guard.sh` 中 `_ticks_${pid}` 基线更新逻辑移动至白名单/前台豁免判断之前，确保应用前台运行期间 ticks 始终跟随刷新，消除前台切后台瞬间 delta 虚高误触发 FR-12 极值降权的问题。
- **状态防污染**：在 `rogue_restore_one` 完成还原后执行 `unset _ticks_${pid} _hcnt_${pid}`，杜绝动态 eval 变量累积导致的 `VmData` 内存膨胀，并防止 PID 复用时的状态污染。

---

## v1.8.0 — Anti-Orphan, Screenshot Sentinel & Smart Cgroup Fusion（2026-09-30）

### 新增：FR-S Screenshot Sentinel（截屏感知护航与焦点预提权）
- **O(1) 零延迟感知**：监控截图目录文件数变化，毫秒级响应截屏事件，无 pgrep/dumpsys 常驻开销。
- **动态算力扩展**：截屏生成后 30 秒内，自动将 `kswapd0` 扩展至中核（mask `3f`），加速内存回收，防截屏瞬间打穿内存水位导致的 Direct Reclaim / Allocstall 卡顿。
- **截屏焦点预护航 (Proactive Boost)**：截屏瞬间精准抓取前台焦点应用（如微信），主动提权至 `nice=-10`，免疫三星 SmartCapture AI OCR 后台计算造成的 CPU/渲染抢占；30 秒后差值无缝还原。
- **双哨兵状态机协同**：Camera Sentinel 与 Screenshot Sentinel 互斥检查状态锁，退出时交叉校验，避免互相撤销 `kswapd` 掩码。

### 新增：FR-11 Top-App Cgroup 智能豁免
- 在 `cpu_guard.sh` 扫描中接入 `is_in_top_app_cgroup`，直接读取 `/proc/<pid>/cpuset` 判断 `/top-app*` 分组。
- 继承与信任内核调度意图，豁免微信后台截屏后合法高负载（AI 图形解码、二维码扫描），彻底解决误伤降权导致的切回卡顿。

### 新增：FR-12 脉冲毒瘤即时干预通道
- 针对单窗口 CPU > 300% 的瞬发极高突发毒瘤进程（如 5000%+ 脉冲），无需等待连续 3 个窗口，直接在首个窗口触发干预，解决脉冲式漏网问题。

### 修复：外部审计全部 5 项缺陷闭环
1. **彻底消除重复守护进程实例 (Singleton & Orphan Cleanup)**：
   - `memtonic.sh` 补齐 `restart` 控制分支（先执行 `stop`，等待 2 秒后再重启）；
   - 守护入口增加单例自检（PID + cmdline 校验），检测到存活实例直接拒绝启动；
   - `stop` 逻辑增加 `pkill -9 -f` 针对 `storm_guard`、`cpu_guard`、`fluency_shield` 的全量兜底清场，杜绝脱管孤儿进程。
2. **Kswapd 掩码幂等判断与备份值污染修复**：
   - 掩码比较采用 `sed 's/^0//'` 归一化，消除 `0f` 与 `f` 字符串不匹配引起的反复 `taskset` churn；
   - 过滤 `f` 和 `3f` 中间值，确保仅备份系统原生默认掩码（`7f`），避免 stop 时还原错误。
3. **前台护盾防抖与冷却机制 (Shield Cooldown)**：
   - 退出护盾后设置 5 秒静默冷却 `shield_cooldown_until`，彻底消除 PSI 持续高企时的 4 秒内抖动重复触发。
4. **系统级告警去重**：
   - `check_staged_rollback` 与 `kswapd_growth` 告警增加 6 小时时间戳去重，避免每小时刷屏污染日志。
5. **版本与元数据全量对齐**：
   - 同步更新 `module.prop`（`v1.8.0`, `versionCode=14`）、各脚本版本号与日志输出。

---

## v1.7.0 — Camera Sentinel Fusion（2026-09-30）

### 新增：FR-C Camera Sentinel（相机神圣护航）
- **统一感知**：通过轮询 `dumpsys media.camera` 的 `Active Camera Clients`，无论是用户直接打开三星相机，还是微信/支付宝/钉钉等应用内部调起相机，均 100% 覆盖。
- **激活时（相机打开）**：
  - 将 `kswapd0` 从效能小核（mask `0f`）扩展至中核（mask `3f`），防止高通 CamX 图形管线超时崩溃（有 `tombstone_11` 实证）。
  - 将 `cameraserver` 与 `vendor.samsung.hardware.camera.provider-service_64` 提权至 `nice=-10`，保障快门时延与录像帧率。
  - 写入 `camera_active.flag` 状态锁。
- **退出时（相机关闭）**：
  - 读取备份的原始 nice 值，计算数学差值精确还原，杜绝优先级反转。
  - 立即将 `kswapd0` 精准封印回效能小核（mask `0f`），不等 1 小时周期巡检，瞬间恢复桌面大核独享。
  - 删除 `camera_active.flag`。

### 修复：审计排查 5 项问题（全部解决）

**P0 — `isolate_kswapd()` 与 Camera Sentinel 冲突**
- 问题：`storm_window` 每 15 秒调用 `isolate_kswapd` 强行缩小 kswapd 掩码，会在相机录像时切断 CamX 的内存换页通道。
- 修复：函数头增加 `[ -f "$CAMERA_ACTIVE_FLAG" ] && return 0` 协同避让。

**P0 — `maintenance()` 与 Camera Sentinel 冲突**
- 问题：相机拍摄时内存 PSI 飙高，可能恰好触发 `compact_memory`，导致录像掉帧或快门卡顿。
- 修复：函数头增加 `camera_active.flag` 检查，相机活跃期绝对拒绝执行内存压实。

**P1 — Camera Sentinel 检测位置错误**
- 问题：若嵌套在 `is_boosting=1` 的代码块内，相机状态变化会在 15 秒护盾等待期间完全漏检。
- 修复：独立放置于 `fluency_shield.sh` while 循环的最顶部（`sleep 5` 之后），每 5 秒无条件运行。

**P2 — `fluency_shield.sh` renice 还原语义错误（经典 Bug）**
- 问题：还原时直接将保存的原始 nice 值（如 `-2`）作为 `renice -n` 的增量参数，导致每次护盾退出后 SurfaceFlinger/前台 App 优先级持续累积降低。
- 修复：还原时实时读取当前 nice 值，计算 `$((orig - cur))` 差值作为增量，数学精确，无论系统并发修改均能正确还原。

**P2 — `stop` 命令未清理 Camera Sentinel 残留文件**
- 问题：模块停止后 `camera_active.flag` 残留，导致下次启动时 `isolate_kswapd` 永久跳过。
- 修复：`stop` 分支增加 `rm -f camera_active.flag camera_vip.bak`。

---

## v1.6.2 — Toybox tr Hotfix（2026-09-29）

### 紧急修复：`tr -d '\0'` 死循环 CPU 泄漏
- 问题：`mt_lib.sh` 中 `pkg_of()` 使用 `tr -d '\0' < /proc/$pid/cmdline` 解析包名，在 Android Toybox 环境下遇到特殊内核线程或冻结进程时会触发死循环，多个 `tr` 进程同时占用大核 80%+ CPU，这是桌面滑动卡顿的根本原因。
- 修复：替换为 `strings /proc/$pid/cmdline | head -n 1 | cut -d: -f1`，彻底消除死循环风险。

---

## v1.6.1 — Kswapd Self-Healing（2026-09-29）

### 修复：kswapd 亲和性漂移自愈闭环
- 发现 Android Power HAL 在每次亮屏解锁后会强制重置所有系统进程的 CPU 亲和性，将 `kswapd0` 从 `0f`（效能小核）重置回 `7f`（全核）。
- 修复：在 `storm_window` 的 15 秒扫描循环内注入 `isolate_kswapd`，确保风暴窗口期内每 15 秒高频巡检并强制锁回。

---

## v1.6.0 — Sentinel P1 Fusion（2026-09-29）

### 新增：R2 Kswapd 效能小核物理隔离
- 利用 `taskset` 将 `kswapd0` 绑定至效能小核（CPU 0-3，mask `0f`），彻底隔离内核内存压缩任务对大核 UI 渲染算力的抢占。

### 新增：R3 息屏按需内存碎片整理
- 严格遵守双重安全条件（息屏 + PSI 内存高压），才触发 `compact_memory`，并配合 3600 秒冷却防抖，杜绝负优化。

### 新增：FR-4 CPU 失常护栏（`cpu_guard.sh`）
- 连续 3 个 60 秒窗口内 CPU > 50% 的用户应用 → `renice +10` 温和降权；CPU 回落后自动还原；高优线程/前台服务豁免。

### 新增：FR-5 崩溃雷达
- 旁路监听 `/data/system/dropbox`，检测 SYSTEM_TOMBSTONE、system_app_crash、ANR 事件。

### 新增：FR-7 结构性健康追踪
- 每小时打点内存健康指标，kswapd CPU 增量 > 90s/h 触发内存颠簸告警。

### 新增：FR-8 Vulkan 护盾（`vk_injector.sh`）
- 延时注入全局 Vulkan 渲染后端，并实现无障碍服务假死自愈。

### 新增：FR-9 前台绝对护盾（`fluency_shield.sh`）
- PSI 内存压力飙升时精准提权前台 SurfaceFlinger + 主线程 + RenderThread。

### 新增：应用内压力测试脚本（`in_app_stress_test.sh`）

---

## v1.5.x — Sentinel P0 Fusion（历史版本）

- Sentinel P0：`check_staged_rollback`（防硬重启丢 Root）、`capture_incident`（黑匣子快照）、`check_root_liveness`（KernelSU 驱动自检）。
- v1.5.0：还原批量极速重构（185s → <2s），启动风暴 PSI 平滑冷却，动态前台服务豁免（`oom_score_adj <= 200`）。
- v1.5.1：修复 Launcher 优先级错乱、stop 还原失效、高优线程降级、快照覆盖竞争等热修复。



---

## [v1.12.6] - 2026-10-19
### Fixed
- **设备端版本漂移（P0）**：真机 `/data/adb/modules/rmg_memtonic` 仍为 10-18 22:02 的 1.12.5 部署，缺失 FR-9 CPU PSI 分支与 `ss_health_probe`。本轮确认后统一起部署 v1.12.6。
- **fluency_shield 孤儿生命周期（P1）**：主守护重启后未清理旧 fluency_shield 实例，导致 PID 文件残留与旧进程续跑。`start` 前先 `pkill` 再启动，并正确写入新 pid。
- **FR-C3 触发窗口过窄（P1）**：从"provider 已进 D 状态"提前到 "face-service 存活 + CPU PSI ≥35 或 mem PSI ≥10"即可预护航，避免 provider flush raise 时来不及拦截。
- **majflt 计数假告警**：极端集合切换时的累计差分可能达到上亿次，设上限 1,000,000 以内的才合理。
### Verified
- 所有变更均本地脚本语法检查，准备设备部署与真机回归。

## [v1.12.7] - 2026-10-19
### Fixed
- **FR-4 相机白名单后台逃逸（P1）**：Samsung 相机与图库从静态全豁免改为“相机活跃标志存在才豁免”。退出前台后仍占用相机链路且持续高 CPU 时，由普通毒瘤阈值接管，避免后台高 CPU 漏管。
- **相机活跃判定扩展**：Samsung 图库相机入口也触发 Camera Sentinel。其他应用前台调用相机继续由前台焦点/top-app cgroup/前台服务豁免覆盖，不新增重型探针。

## [v1.12.8] - 2026-10-20
### Added
- **FR-BT3：雷鸟断连后 LE 重连护航**。检测 RayNeo iO 的 BR/EDR `ACL_DISCONNECTED` 事件，在随后 25 秒 LE 直连重连窗口内给 BT 栈/HAL/audioserver 逐线程提权 -8，结束后差分还原。
### Verified
- 本地脚本语法检查通过。设备部署与真机 ACL 事件回归待执行。
