# RMG MemTonic 版本变更日志

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
