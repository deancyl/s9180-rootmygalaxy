# MemTonic v1.13.12 一致性评估与治本方案（2026-11-05）

> 范围：WebUI 及现有功能是否仍完整覆盖、准确反映底层实现的能力 / 状态 / 约束。
> 性质：**只读评估 + 方案设计，零代码改动**。设备 SM-S9180 / FZG1，模块 `v1.13.12 / vc52`，旁路 flag PRESENT。

---

## 0. 核对与验证结论（严格流程）

| 轮次 | 内容 | 结论 |
|---|---|---|
| 第 1 轮 需求理解 | 主交付=一致性评估；附带=治本三项+rollback 治理+thermal 跟踪的**方案与风险评估** | 明确**零代码改动** |
| 第 2 轮 约束 | 不变砖 / 蓝牙 / 播放 / 微信实时 / 相机 / 前台 / 省电 / 软重启为倒数第二手段 / GEMINI 铁律 | 全部沿用，无新增放宽 |
| 第 3 轮 状态 | 设备侧只读取证（10:59）：四守护 ALIVE、版本一致、旁路 PRESENT、`collect_stats` 正常、rollback enabling=1、thermal tombstone 22 个 | 线上与源码定义一致 |
| 第 4 轮 预期结果 | 一份逐项评估 + 优先级清单 + 三分类 + 五套方案；发现矛盾/风险则暂停实现并列待确认 | 交付形态明确 |
| **独立旁路验证** | 日志直数 9 项 vs `collect_stats` 9 项：`shield=275 storm=1 rogue=0 compact=11 blackbox=0 crash=2 rollback=3 mjburst=74 bt=25` | **9/9 完全一致**，主流程结论成立，无冲突 |

---

## 1. 覆盖率量化（核心结论：面板严重滞后于底层）

| 维度 | 底层实现 | WebUI 覆盖 | 覆盖率 |
|---|---|---|---|
| 事件标签 | **约 106 种**（`act/event/warn/advise/err`） | 9 个计数（约 10 个标签） | **~10%** |
| `run/` 状态文件 | **约 70 个** | 6 个 flag + 2 类快照文件 | **~10%** |
| 守护进程 | 4（memtonic / cpu_guard / fluency_shield / storm_guard） | 仅 `state=pid`（1 个） | 25%（且无各自健康） |
| 能力族 | FR-9 / FR-SS / FR-C3 / FR-BT / BT2 / BT3 / Camera / Screenshot / Flush / GC 加速 / 预测器 / 压实 / 核亲和 / 毒瘤 / 削峰 / 崩溃雷达 / rollback / FR-RN1 ≈ 18 族 | 8 族（部分计数） | <50% |

**本日志周期实际发生、面板完全不可见的高频事件**（10:59 实测）：

| 事件 | 次数 | 与 09:16 OOM 的关系 |
|---|---:|---|
| `act=deprioritize` 削峰 | 161 | 启动期应用批量降权 |
| `act=ss_heap_probe` | 76 | **堆水位探测（危机主线）** |
| `act=flush_guard_on` 借相机护航 | 65 | **借相机链路（治本①目标）** |
| `warn=majflt_disaster` | 41 | 灾难级换页 |
| `act=ss_heap_relief` | 17 | **泄压（多数 am 不可达失败）** |
| `act=frc3_storm_on` | 12 | 借相机风暴态 |
| `act=screenshot_sentinel_on` | 10 | 截屏护航 |
| `act=mem_forecast_clear` / `forecast_compact` | 6 / 1 | 预测器与前置压实 |
| `advise=soft_reboot` | **4** | **本周期已 4 次建议止损** |
| `act=bt3_guard_on` / `gc_boost_on` | 4 / 3 | 断连护航 / GC 危机加速 |

> 最严重的后果：**09:16 那场 496MB OOM 危机，用户在 WebUI 上从头到尾看不到堆水位、看不到 GC 加速、看不到 trim 失败、看不到 4 次止损建议**（`soft_reboot_advised.flag` 已被清除，横幅为空）。

---

## 2. 逐项问题清单（滞后 / 缺失 / 不一致 / 冗余）

### P0 — 直接影响安全决策

| # | 类型 | 具体表现 | 影响 |
|---|---|---|---|
| L2 | **缺失** | `collect_stats` 已输出 `ssheap=228828`，管理器卡片有「SS堆206MB」，**WebUI 的 `renderStatus()` 完全不解析该字段** | 最关键的 OOM 危机指标在面板隐形；用户无法在危机中判断严重度 |
| L3 | **缺失** | 旁路 flag `$RUN/disable_rayneo_guard` 与状态档 `rayneo_governor.lst` 均无展示 | 用户明确要求「保持旁路」，却无法在面板验证；FR-RN1 是否在工作不可知 |
| L4 | **缺失** | 危机链实时态无展示：`ss_heap.kb` 趋势、`gc_boost.bak`、`ss_heap_relief` 失败、`advise=soft_reboot` 历史、`paging_storm.last`、`mem_forecast.flag` | 预警链工作了 30 分钟（08:46 诊断真泄漏），面板只显示「运行中」 |
| L11 | **缺失** | rollback `enabling` 状态只在 `reboot_suppressed.flag` 横幅里间接出现；`rollback_disarm.*` 状态无展示 | 唯一地雷（1842666122）不可见；抑制建议的原因不透明 |

### P1 — 准确性与可操作性

| # | 类型 | 具体表现 | 影响 |
|---|---|---|---|
| L1 | **滞后** | `CARD_DEFS` 触发描述错误：`shield` 写「PSI 内存压力 ≥15%」，实际 09:23 触发时 `psi_int=285`(2.85%) / `cpu_psi_int=5511`(55.11%)，**主因是 CPU PSI**；`bt` 合并了 BT/BT2 但未提 BT3 LE 断连护航；`compact` 未含预测态前置压实；`storm` 未含 FR-C3 风暴态；`mjburst` 写「>500 次」而灾难级是 >10 万/60s | 用户按错误口径理解模块行为 |
| L5 | **缺失** | `ver` 只显示静态「RMG MemTonic…统计口径」，不显示 `v1.13.12 / vc52` | 版本排障、回滚确认无依据 |
| L6 | **缺失** | `event=root_lost_exit` / `cpuguard_exit` / `start_rejected` 无面板提示 | 临时 root 丢失或守护异常退出时，用户只看到「已停止」，不知根因 |
| L7 | **不一致** | `collect_stats` 注释写「日志超 **256KB** 截断后从零重计」，实际 `logx` 与 WebUI hint 均为 **512KB**（v1.13.0 改）；注释未同步 | 文档口径混乱 |
| L8 | **不一致** | 同刻 `collect_stats=护航275/指纹74/可用2889MB/SS堆223MB`，管理器卡片=`274/73/3034MB/206MB`（事件驱动刷新快照） | 两个界面数值不同且无「快照时间」标注，易误判为数据错误 |
| L9 | **不一致** | 安全边界声明仅「不杀进程/不冻结/不动 zram/不持久内核参数；所有**提权**均逐线程且可无损还原」；底层还有**降权**（rogue +5、FR-RN1 +10）、核亲和约束、削峰、GC 提权；未声明「不自动重启 / 不刷分区 / 仅临时 root 会话内生效」 | 约束展示不完整；用户最强调的「软重启是倒数第二手段」无体现 |
| L10 | **冗余** | 底层已有 `event=start_rejected reason=already_running` 与 `service.sh` 幂等保护，但「启动守护并优化」按钮不判断 `state`，恒执行 `sh service.sh; sh memtonic.sh optimize` | 运行中重复点击撞保护、重复执行 optimize；无「重启守护」入口 |
| L14 | **滞后** | 横幅把 `soft_reboot_advised.flag` 的三种来源（trim_ineffective / relief_fail / paging_storm）混成一句文案，未解析 `reason=` | 用户无法判断建议来自堆泄漏还是换页风暴 |
| L15 | **缺失** | 「本日志周期」无起点/轮转次数展示；`incident_files=10` 但面板只列最近 5 个文件名，无原因摘要 | 事后取证需手工翻文件 |

### P2 — 观测补强

| # | 类型 | 具体表现 | 影响 |
|---|---|---|---|
| L12 | **缺失** | 无 HAL tombstone 跟踪：实测 dropbox **22 个** SYSTEM_TOMBSTONE（**20 个 camera.provider-service_64**、2 个 thermal@1.0-service、1 个 cameraserver、1 个 external provider） | 相机链路 HAL 反复崩溃是长期事实，面板零感知 |
| L13 | **缺失** | incident 快照仅列文件名，不含 `reason=soft_reboot` / 堆值 / 时间线摘要 | 10 份事故快照需逐个人工打开 |
| L16 | **冗余** | 每次 `refresh()` 发 2 次 `ksu.exec`（stats + 9 段 flag 串），15s 自动刷新，页面可见时约 8 次/分钟 shell 调用 | 低概率增加前台调度噪声（当前 cpu_scan 170–240ms，未见异常） |

---

## 3. 优先级清单（预期目标 + 验收标准）

| 优先级 | 事项 | 预期目标 | 验收标准（可测） |
|---|---|---|---|
| **P0-1** | 危机态可视化 | 新增「system_server 堆」卡片：`ssheap` 当前值 / **按当前实际常量的阈值带（460 trim · 480 GC · 485 告警 · 496 OOM，单位 MB）** / 最近探测时间；解析 `gc_boost.bak`、`ss_heap_relief` 失败数、`advise=soft_reboot` 历史次数、`paging_storm.last`、`mem_forecast.flag` | 构造 `ss_heap.kb=471040` → 面板显示 460MB 且进入泄压区（黄）；`494508`（09:15 实测值）→ GC 加速区；`advise=soft_reboot` 历史 ≥1 时「本周期止损建议 N 次」可见；与 `collect_stats` 数值偏差 0 |
| **P0-2** | 状态与约束透明 | 顶部状态区显示版本/vc、四守护各自 ALIVE、`root` 状态、FR-RN1 旁路 ON/OFF、rollback enabling 数、软重启策略声明 | `disable_rayneo_guard` 存在 → 面板显示「雷鸟治理：已旁路」；删除 → 「运行中」；`dumpsys rollback` enabling=1 → 面板显示 1 |
| **P0-3** | 一致性校正 | 修 L1 全部描述、L7 注释口径、L9 安全边界文案、L8 快照时间标注 | 逐条文案与源码常量核对表 100% 匹配；面板标注「卡片为定时快照，以本页刷新时间为准」 |
| **P1-1** | 计数卡扩展 | 新增 5 张：借相机护航、GC 加速、堆危机探测/泄压、预测与前置压实、断连护航（BT3）；保留原 9 张 | 每张计数与 `grep -c` 日志直数相等（同独立旁路验证法） |
| **P1-2** | 操作状态机 | running 时禁用 start、提供「重启守护」；stop 提示补充「降权/核亲和也将还原」；解析 `start_rejected` / `root_lost_exit` | running 点击 start 无重复实例；stop 后 `rayneo_governor.lst` 清空且 nice 全还原；root 丢失有明确横幅 |
| **P1-3** | 建议横幅语义化 | 解析 `reason=`，分三套文案；显示来源时间；软重启文案明确「倒数第二手段、需用户手动」 | 造 3 种 flag → 3 种不同文案，均含「模块不代执行」 |
| **P2-1** | HAL tombstone 跟踪 | 卡片显示 camera provider / thermal HAL tombstone 计数与最近时间，关联借相机风暴时序 | 与 `ls dropbox/SYSTEM_TOMBSTONE*` 直数一致；标注「历史累计，非致命」 |
| **P2-2** | incident 摘要 | 列表显示 `reason` / 时间 / 堆值，点击展开头部 20 行 | 10 份快照均能显示原因，不额外增加常驻开销 |
| **P2-3** | 刷新开销 | 合并 2 次 exec 为 1 次脚本输出，或自动刷新降为 30s（可见时） | 单次刷新 shell 调用 2→1；`cpu_scan done_ms` 无上升 |

---

## 4. 三分类（最终明确）

### ✅ 可沿用（不动或仅微调）
- `collect_stats` 数据契约（`state/pid/9 计数/ssheap/avail_kb/psi_s10/psi_f10`）——旁路验证 9/9 一致，是可靠唯一数据源
- KernelSU exec bridge（`ksu.exec(cmd,'{}',cb)` + 超时 + 兼容老管理器）、busy 单飞与 60s 看门狗、页内确认弹窗、事件委托、`parseKv`/`renderStatus` 定点更新骨架
- 9 张计数卡的**数据链路**、守护 start/stop/refresh 三动作、blackbox/incident 快照列表、15s 可见时自动刷新
- 底层能力本身（106 事件对应的机制）**全部可沿用**，本轮不改动任何守护逻辑

### 🔧 需调整
- `CARD_DEFS` 的 5 处触发描述（L1）；安全边界文案补全降权/不自动重启/临时 root（L9）
- `collect_stats` 注释 256→512KB（L7）；hint 补「周期起点/轮转次数」（L15）
- `ver` 改为动态版本（L5）；建议横幅解析 `reason=`（L14）；卡片数值标注快照时间（L8）
- start 按钮加 running 判定、stop 提示补全（L10）；incident 列表补原因摘要（L13）

### ➕ 需新增
- **危机态区**（P0-1：堆仪表 + 危机链 + 建议历史）——最高价值，直接对应 09:16 教训
- **状态/约束区**（P0-2：四守护健康、root、FR-RN1 旁路、rollback enabling、软重启策略）
- 5 张能力计数卡（P1-1）、「重启守护」按钮与异常退出横幅（P1-2）、HAL tombstone 卡片（P2-1）

---

## 5. 治本五项方案与风险评估（**仅方案，未写代码**）

| # | 方案 | 机制 | 安全边界 / 风险 | 验收标准 |
|---|---|---|---|---|
| ① | **FR-C3 根治借相机** | 分三期：**A 只读归因**（识别借相机发起者：AOD 人脸 / 智能锁 / 眼镜 / 第三方，输出时序报告）→ **B 联动预警**（风暴态 1h≥6 次时提前触发 `ss_heap_probe` 与 GC 加速，不等 480MB）→ **C 调度侧节流**（仅评估：风暴态期间对非前台重负载做核亲和约束，把 CPU 还给 GC；**明确否决** hook/拦截 binder、杀/冻 face-service 或 provider） | A/B 零风险（只读 + 复用既有机制）；C 有相机流畅度风险，需相机/蓝牙实弹回归后才可立项。依据：本周期 65 次 `flush_guard_on` + 12 次风暴态 + 20 次 camera provider tombstone | A 产出「发起者→频次→堆斜率」报告；B 在堆 430MB 前触发探测；C 未通过相机回归则**不实施** |
| ② | **430MB 阈值前移** | GC 加速触发 480→**430MB**；`SS_TRIM_KB` 460 / `SS_ALERT_KB` 485 重估；堆回落解除线 450→400MB；配合 `SS_PROBE_EVERY` 白天 1800→600s | 风险：GC 线程 `-10` 提权持续时间变长，可能与前台/相机抢大核；需限定时长上限 + nice≤-10 跳过铁律 + A/B ≥24h 观察。**不降低阈值以外的任何保护** | 堆在 430–460MB 区间即触发 `gc_boost_on`；24h 内相机启动/蓝牙播放/微信实时零回归；`cpu_scan` 与 self_cpu 无上升 |
| ③ | **`ss_heap_relief` 去 binder 化兜底** | 根因：`am send-trim-memory` 在堆饱和时 `activity` 服务不可达（事故快照 `activity could not be found`）。**结论：root 用户空间没有安全、可靠、无需 framework 的直接触发 ART GC 的手段**（信号/注入均触及变砖与稳定性红线）。建议改为「**降低依赖 + 显式降级**」：失败即切纯预警 + 提前触发 ② + 落结构化 `relief_fail` 状态供面板展示；**不引入 kill/signal/注入** | 风险最低（只减依赖不增动作）；代价是不再幻想「救回」，改为「更早发现 + 让用户可见」 | `relief_fail` 连续 ≥2 次时面板显示红色危机态；不出现任何新增 `kill`/`am` 重试风暴；`reboot_suppressed` 门控保持 |
| ④ | **rollback 地雷治理** | 精确归因：3 个会话中仅 `1842666122`（adservices.api + sdksandbox）为 `enabling`，`1220127260`(tzdata6) / `391803498`(telemetry+statsd) 已 `committed`；09:17:33 相同 mtime 是框架重启后状态重写，**非新增地雷**。方案：持续只读复核（300s 已有 `cce_watch` 可复用）+ 门控持久化 + WebUI 明示 enabling 数 + 明确标注「该会话属主 Google Play services，shell 拆除被 SecurityException 拒绝，不自动拆」 | 自动拆除已被历史实弹否决（不可行且有风险）；本方案只观测不动作，零变砖面 | enabling 计数与 `dumpsys rollback` 一致；软重启建议在该状态下**始终被抑制**并给出原因；无 `pm install-abandon` 等写操作 |
| ⑤ | **thermal HAL tombstone 跟踪** | 22 个 tombstone 中 20 个 camera provider、2 个 thermal（含 09:16:02 `CameraThermistor::update_temperature` 空指针）。方案：只读统计 HAL 崩溃频次 + 与借相机/堆危机的时序关联 + 面板卡片；**不改 HAL、不重启服务、不清除 dropbox** | 纯只读，零风险；需注明「历史累计，非致命，因果未定」 | 计数与 dropbox 直数一致；能给出「崩溃→借相机→堆斜率」时间线；无写操作 |

**方案与硬约束兼容性**：五项均不改分区/不刷写/不杀进程/不冻结/不触碰播放与蓝牙音频栈/不影响微信白名单/相机与前台优先级保持；③ 明确放弃高风险手段；①C 在未通过回归前不进入实现。

---

## 6. 待确认问题（按流程暂停实现）

1. 是否授权按 **P0 → P1 → P2** 分批进入实现（每批仍需「单元测试 + 部署 + 旁路验证」全流程）？
2. 治本 ② 的 A/B 观察窗是否接受 ≥24h（含相机/蓝牙/微信实时回归）？
3. 治本 ①A 的源头归因需要您配合提供使用场景（AOD 人脸、智能锁、眼镜、后台 App 哪些开启）？
4. 软重启建议文案是否按「倒数第二手段、模块绝不代执行」重写（当前横幅措辞偏中性）？
5. 旁路 flag 移除时点仍由您定；移除后才有 FR-RN1 的 A/B 对照与全天智记内容完整性验收。
6. 本轮所有结论基于 10:59 单次快照 + 09:16 事故取证；若期间发生新的软重启/轮转，需重新核对计数基线。

---

*取证脚本：`analysis/2026-10-22/mt_consistency_verify.sh`、`rollback_state.sh`、`softreboot_forensics{,2,3,4}.sh`；单元测试 `.t/v1312_test.sh`（43/43）。*

---

## 附：P0 批次实现记录（2026-11-05 12:00 起，待部署）

> 用户授权「P0→P1→P2 分批实现」并接受 ≥24h A/B；使用场景输入：拍照 / AOD 人脸 / 美团扫码为前台合法，后台一般不允许相机，智能锁与眼镜场景未知（治本①A 只读归因不预设）；「4 统一」= 软重启文案统一按「倒数第二手段、模块绝不代执行」。

**实现裁定（与本报告正文的两处订正）**
1. 面板阈值带按**当前底层常量**绘制：471040 / 491520 / 496640 / 507904 KB（460 / 480 / 485 / 496MB）。**不画未实施的 430MB 前移**——把方案画成现状会制造新的不一致；430MB 仅在治本② A/B 基线通过后另行实施并同步面板。
2. 「近 1h 趋势」降为「最近探测时间」（读最近 `ssheap-*.log` 文件名）：避免每 15s 刷新多做 6 次 fork，符合省电硬约束；P0-1 验收标准相应改为阈值边界值（`471040`→泄压区、`494508`→GC 加速区）。
3. 报告正文 P0-1 验收用例原写 `470000KB → 黄色带` 有误（470000KB=459MB < 460MB trim 线），已订正为 `471040`。

**已完成（本地）**
- `webroot/index.html` 单文件改动（md5 `18f825e6…a9c`）：新增堆危机卡、状态与约束卡、版本/四守护/root/旁路/rollback 展示；CARD_DEFS 5 处描述校正；安全边界与软重启文案统一；快照时间标注；`ver` 动态；数据缺失三态防误报。
- **所有新增数据并入原有第 2 次 `execCmd`**，调用次数保持 4（原 4），零守护重启、零守护逻辑改动、旁路 flag 不动。
- 单元测试 `.t/webui_p0_test.js` **82/82 全过**（整段 JS 编译、纯函数 27 项、源码守卫 55 项）；`.t/webui_cmd_extract.js` 生成设备命令 `sh -n` 通过（2148B）；HTML 结构校验 div 53/53、34 id 无重复、script 1/1。
- 部署脚本 `analysis/2026-10-22/mt_webui_p0_deploy.sh`（staging md5 → 备份 → 原子替换 → md5 验证+失败回滚 → restorecon → 新数据源实弹 → **旁路双状态模拟（临时文件，不触碰真实 flag）** → 回归）。

**已完成（设备 13:41 部署，7 步全绿）**
- `[1/6]` staging md5 `18f825e6…a9c` OK → `[2/6]` 备份 `webroot.bak-p0` → `[3/6]` 原子替换 → `[4/6]` 设备侧 md5 一致 → `[5/6]` 新数据源实弹 → `[6/6]` 旁路双状态模拟 → `[7/6]` 回归。
- 数据源实弹：`separators=10`（与 parts[0..10] 设计一致）；`ver=v1.13.12 vc=52`、四守护 `g_memtonic/g_guard/g_cpuguard/g_fluencyshield=alive`、`root=0`、`rayneo_bypass=ON`、`relief_fail=16`、`advise_cnt=4`、`forecast=OFF`、`last_probe=ssheap-20261105_091502.log`、**`rb_enabling=1`**（与 `dumpsys rollback` 精确归因一致）。
- **独立旁路验证**：`SIM_ON → rayneo_bypass=ON` / `SIM_OFF → rayneo_bypass=OFF`，用临时文件模拟，**真实 flag 全程未触碰**；部署后 `bypass_flag=PRESENT`。
- 回归：四守护 pid 不变（27344/27406/27413/27441，**零守护重启**）、`version=v1.13.12`、`collect_stats` 正常（ssheap=209060KB≈204MB 正常区）、`cpu_scan done_ms=160`（部署前 170–240ms，**无耗电增加**）。
- 已知小瑕疵（不影响功能、列 P1 待办）：toybox awk 对不存在的文件不执行 `END`，故 `rayneo_lines=` / `gcboost=` 输出空串而非 `0`；JS `int0('')=0` 渲染正确（「未介入」/不显示线程数），后续加 `|| echo 0` 兜底使数据契约更干净。
- 阈值分档未用设备假值实测（避免污染 FR-SS 真实状态），由单测 U5–U14 覆盖全部边界。

---

## 附 2：P1 批次 + 三项授权执行记录（2026-11-05 16:26）

### ① P1 批次（已实现并部署）
- 用户授权「可以开始了」；单测 **114/114**（新增 adviseText 7 项、P1 守卫 27 项）；`mt_lib.sh` / 设备命令 `sh -n` 通过。
- 实现：`collect_stats` 追加 5 字段（flush/gcboost/ssprobe/forecast/bt3，仅追加、旧消费者自动忽略）；CARD_DEFS 扩至 14 张；`startBlocked` 状态机（running 禁用 start + title 提示）、stop 提示补全「降权/核亲和还原」、`start_rejected`/`root_lost_exit` 异常横幅；建议横幅按 `reason=` 三套文案；toybox awk 空串兜底 `${_rl:-0}`/`${_gb:-0}` **生效**。
- **裁定**：新增「重启守护」按钮**未实现**——24h A/B 基线期不应引入可触发守护重启的副作用，顺延至 P2 并已通过单测守卫断言。
- 部署 7 步全绿：staging md5 2/2 → `webroot.bak-p1` + `scripts.bak-p1` → 原子替换 → 设备 md5 2/2 → **`collect_stats` 5 字段与日志直数 5/5 MATCH**（flush 83 / gcboost 3 / ssprobe 76 / forecast 10 / bt3 4）→ 数据源 `separators=10` + **横幅三态模拟 3/3**（trim_ineffective / relief_fail / paging_storm）→ 回归（四守护 pid 不变、**零守护重启**、`cpu_scan=170ms`、旁路 PRESENT）。16:26 复测 230/240/270ms。

### ② 24h A/B 基线
- 用户确认从 13:42 起算；但 14:48 移除 flag、15:38 又恢复旁路，且期间发生性能回归 → **基线暂停计时**，待修复与 flag 状态稳定后重新起算（列为待确认）。基线期内未改动任何阈值、未重启守护。

### ③ 治本 ①A（只读归因，已启动）
- 交付 `FRC3_借相机源头归因_阶段A_2026-11-05.md` + 按需采样器 `frc3_attrib.sh`（**不常驻、零新增唤醒**）。
- 首份结论：借相机 **76 次/约 21h、全天连续分布**（每小时 2–7 次，深夜 23 次，12 次风暴态）；调用者实证为 **KeyguardFace/FaceService（SystemUI 锁屏人脸链路，pid 30602 → face HAL 1783 → camera provider）**，非拍照/扫码；系统级生物识别不受「后台相机权限」约束，解释了息屏/后台仍发生；智能锁/眼镜本轮未观测到，不预设。伴随 20 次 camera provider HAL tombstone 与 20–98 万/60s 灾难换页（时序伴生，因果待阶段 B）。

### ④ 移除旁路 flag（已执行 → 因性能回归安全回退）
- 14:48 移除；memo 激活期 3 轮零 demote（P1-5 门控按设计）；其后 memo 关闭时正常降权 49 次，15:24:56 `restored=32` 还原。
- **性能回归**：`cpu_scan` 从 160–240ms 升至 1770–13010ms。A/B 铁证（恢复 flag 后 210–220ms，而 PSI 未同步下降）→ 根因是 `rayneo_memo_active()` 每轮 ~181 次 `cat` fork。
- **15:38 已恢复旁路 flag**（安全回退）；还原完整性验证：状态档空、名单线程 nice 0/-5、保护线程未碰、16 个 nice≥10 线程全部不在降权名单（系统原生）→ **零残留**。
- 修复方案见 `FR-RN1_性能回归根因与修复方案_2026-11-05.md`（方案 A：`cat` → mksh 内建 `read` 零 fork，复用 v1.13.2 已验证范式）。**未擅自实施**：改 cpu_guard.sh 需重启守护，会污染 24h 基线，待您确认。
