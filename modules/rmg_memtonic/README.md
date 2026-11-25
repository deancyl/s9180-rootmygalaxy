# RMG MemTonic —— SM-S9180 内存与异常守护模块

- 模块 ID：`rmg_memtonic` ｜ 版本：v2.0.3 (vc73) ｜ 适用：Galaxy S23 Ultra（SM-S9180，dm3q）KernelSU 临时 Root（late-load）方案（其他高通骁龙三星机型理论可用但不保证稳定性与效果）

## 版本历史

- **v2.0.3 (vc73)（2026-11-25）**：基于 34.5 小时卡顿真机审计的精准治本升级。① **修复 `screen_off()` 误缓存假背光节点（P0）**——在 SM-S9180 上 `/sys/class/backlight/panel` 常年读 `0`（`max_brightness=0`），真实节点为 `panel0-backlight`（`max_brightness=612`）。现改为显式优先 `panel0-backlight` 并校验 `max_brightness > 0` + `dumpsys power` 首次交叉验证，彻底恢复亮屏相机护航、FR-9 前台护盾与极端熔断；② **新增高通 PerfHAL 耗尽哨兵与息屏温和重建**——每 30 分钟时间戳去重检索 `logcat -b main` 中 `ANDR-PERF-MPCTL: Perflock Submit request limit reached`，命中告警并带 6h 冷却通知，息屏期平滑重建 `perf-hal-2-3` 释放请求池；③ **修复夜间深度息屏整理条件**——改为连续息屏 ≥30 分钟 + 冷却 ≥6 小时 +（`compact_fail` 增量 ≥500 或触发过 `kswapd_growth`）+ `SwapUsed ≥ 4 GB` + `MemFree ≥ 256 MB` 且 `MemAvailable ≥ 1.5 GB` 时执行单次 `compact_memory`（全生命周期保持零 `drop_caches`）；④ **WebUI 对齐**——`collect_stats()` 补回 `compact` 计数，更新前端卡片文案与全文件版本至 `v2.0.3 (vc73)`。

- **v2.0.2 (vc72)（2026-11-21）**：外部审计（48 小时实测数据）精修升级。① **P0 级 Bug 修复**——`get_top_app_info` 增加 `oom_score_adj == 0` 校验，排除常驻低 PID 绑定服务（`com.samsung.SMT` 等），前台提权精准度提升至 100%；② **fluency_shield 极速省电重构**——0-fork 读取 `/proc/uptime` 单调秒、息屏短路休眠（`sleep 20`）、截屏目录零 fork 时间戳检测（`[ "$sc_dir" -nt "$RUN/sc_dir.ref" ]`）、FR-9 提权温和收敛至 `-10`（严禁 `-15`）并直读 `comm`；自耗 CPU 压缩 90%+；③ **补齐主守护 4 项断链能力**——改为亮屏 60s / 息屏 300s 零 fork 轻节拍；每轮检测软重启自愈与无障碍恢复、Dropbox 崩溃感知；每 3 分钟接入高门槛极端 CPU+IO 熔断器；每 30 分钟接入 system_server 纯 Java 堆只读预警；④ **mt_lib.sh 优雅瘦身**——彻底清除 39 个废弃死函数，代码瘦身至 550 行以内；⑤ **WebUI 同步精修**——移除旧废弃状态，新增相机护航与无障碍自愈展示，清理废弃文件读取，更新口径说明；⑥ **全生命周期零 drop_caches**——彻底移除 once/optimize 残余的 `drop_caches` 写入。

- **v2.0.0 (vc70)（2026-11-19）**：架构收敛至双核心守护（memtonic.sh + fluency_shield.sh）。全域无感相机硬件护航与雷鸟/蓝牙调度平权。

- **v1.13.22 (vc62)（2026-11-17）**：防御体系深度重构与软重启根因消除（针对 13:45:48 Watchdog OOM 493MB 取证闭环）。① **R1 软重启状态清理与削峰配额倍增**——`storm_guard.sh` 在软重启与冷启时刻立即清除上一代遗留的 8 个状态/标志文件（`reboot_suppressed.flag`、`soft_reboot_advised.flag`、`ss_heap_extreme.flag`、`paging_storm.flag`、`mem_forecast.flag`、`ss_heap.kb`、`ss_heap.hist`、`ss_gc_boost.pids`），并将 `STORM_MAX_APP` 从 60 提升至 180，全量纳入软重启后自启应用；② **R2 废除 dumpsys meminfo 轮询与消除 Binder 阻塞**——`ss_heap_probe` 改为直读内核 `/proc/$ss_pid/smaps_rollup`（Pss + SwapPss）或 `/proc/$ss_pid/status`，彻底消除 Binder IPC 诱发的 Watchdog OOM；彻底删除 `ss_heap_relief` 函数及其 `am send-trim-memory` 失败重试与 `drop_caches` 调用；`ss_heap_recovered` 分支清除 3 个 flag 并归零 `_ss_crit_streak`；`gc_boost_on` 仅提权 `HeapTaskDaemon*` 至 nice -10，CPU 亲和设为 `7f`（0-6 核，严禁 `e0` 抢占 CPU7 Prime 超大核）；③ **R3 全面清除自动循环中的 drop_caches**——彻底删除后台自动 `drop_caches=3` 回退机制，仅保留用户手动 `once`/`optimize` 触发时 `echo 1 > /proc/sys/vm/drop_caches`（仅回收 dentry/inode，严禁写入 2 或 3）；④ **R4 前台焦点零 dumpsys 与 ps_scan O(1) 重构**——`get_top_app_info` 直读 top-app cgroup；`fluency_shield.sh` 彻底删除 3 处 `/proc/[0-9]*` 全盘遍历，以 `pidof`/`pgrep` 的 `get_bt_hal_pid` O(1) 命中；⑤ **R5 换页感知与核亲和核心白名单**——`cpu_guard.sh` 读取 `/proc/$pid/stat` 第 12 项 `majflt`，10s 增量 > 200 时仅施加 `renice 5` 并跳过锁小核，保障中核并发解压；严格豁免 `system_server` 与 `surfaceflinger` 亲和性设置；⑥ **R6 VM 参数调优与全量版本同步**——新增 `apply_vm_params` 设置 `vm.watermark_scale_factor=80`、`vm.page-cluster=0`、`vm.swappiness=100`；全量同步版本至 `v1.13.22` (vc62)。

- **v1.13.20 (vc60)（2026-11-09）**：外部复核收尾热修 + **FR-4 毒瘤检测全面恢复与全链路零 fork 极速重构**。① **攻克历史遗留 P0**——修复 `snapshot_app_pids` 的 awk 实现中 `FNR==1` 未给 `pid` 赋值且依赖不存在的 status 末尾空行导致恒为空的缺陷，全面恢复全量约 95 个应用进程的真实扫描；② **snapshot_app_ticks 批量采集**——单次 awk 扫描 `status` 配合 `getline` 提取 `stat`，将 95 次 `cpu_ticks_of` 子进程 fork（~1700ms 严重拥堵）缩减至单次 90ms 批量完成；③ **核心辅助函数全链路零 fork 化**——`pkg_of` 改内建 `read` 并引入 `_pkg_${pid}` 一级包名缓存、`is_in_top_app_cgroup` 改内建 `read`、`nice_of` 免子 shell 提取 `_nice_val`、`rayneo_governor` 死条目清洗重构为单次快速 awk（200ms → 5ms）；④ **作用域修复**——`mt_lib.sh` 定义 `RAYNEO_PKG`，彻底解决停止/卸载时跳过雷鸟线程还原的缺陷；⑤ **KSU 规范**——`update_module_desc` 显式注入 `KSU_MODULE=rmg_memtonic` 前缀；⑥ **一致性收尾**——消除启动日志硬编码版本号，清理调试残留。真机实测 5 轮 `cpu_scan` 平均 **263ms**，全量真实扫描稳保 < 300ms 预算。单测断言 100% 通过。

- **v1.13.19（2026-11-09）**：外部审计 9 项修复 + 生命周期收口（**不改阈值、不改功能语义**）。① **Tgid Tab 分隔符**——`IFS=' '` 不拆 `/proc/<tid>/status` 的 `Tgid:\t<pid>`，`rayneo_restore` 100% 返回 `restored=0`，且每轮把 `RN_STATE` 清空导致重复降权；真机新旧并排对比 4/4 `old=[] new=[19615]`，修复后实测 `restored=3`（写入 3 条、还原 3 条）。② **cpuset 全线程迁移**——`tasks` 只迁主线程，改 `cgroup.procs`。③ **卸载不终止子进程**——`uninstall.sh` 原 `pkill` 数为 0，`cpu_guard`/`fluency_shield`/`vk_injector` 会变孤儿且清单被 `rm -rf run` 删光；补 4 条 pkill 并把清场前移到删目录之前。④ **`service.sh` 漏看子进程**——异常终止后重拉会产生双实例，改为先清场再拉起。⑤ **`renice` 增量语义**——`rogue_throttle` 的 `-n 10` 与 SurfaceFlinger 提权 `-n -15` 会在已有 nice 上继续叠加（实测可到 -25），改 delta 换算 + `> -15` 守卫；护盾提权落盘 `shield_fg.bak` 供自愈/停止还原。⑥ **`mem_forecast` 旧值**——预测态只在首次落盘，压实判定读的是几小时前的 `avail_kb`；改持续刷新 + 读实时 `MemAvailable` + 亮屏需 mem PSI≥10。⑦ 减负：`am` 加 `timeout 2`、`dumpsys rollback` 单次采集 60s 复用、`collect_stats` 14 次 `grep -c` 合单次 awk、`is_frozen_pid` 跳过冻结进程、护盾息屏降频、`child_heal` 子守护自愈（pid 存活时零 fork）。⑧ KernelSU 规范：`MODDIR=${0%/*}`、`customize.sh` + `hotinstall.sh` 支持热安装、`ksud module config set --temp override.description`。⑨ WebUI 阈值文案对齐 450/460/470/496，并修 `healthScore` 把 470MB 误写成 481MB。单测 **289/289**；真机部署 8 步全绿，探针确认 `renice -n` 为**增量语义**。**诚实边界**：`cpu_scan` p50=590ms 未达 300ms 目标（与 v1.13.18 的 340–730ms 同区间，非退步）；**新发现 P0——FR-4 毒瘤检测自 v1.9.9 起完全失效**（`snapshot_app_pids` 的 awk 从未给 `pid` 赋值，且依赖并不存在的 status 末尾空行；1349 次扫描 0 次干预），本版未修，留独立一版处理。

- **v1.13.18（2026-11-08）**：**FR-RN1 首次成功启用** + WebUI 健康分。① FR-RN1 真因是"写"不是"读"——降权循环对 181–221 个线程逐个 `renice`（每次一个 fork）+ 每 tid 一次 `grep -q` + 每线程一条日志 ≈ 600 fork/轮；实机验证 toybox `renice` 支持多 PID 后改为按 nice 分桶批量调用、查重集合入内存、日志每轮一条，`cpu_scan` 从 1770–13010ms（v1.13.13，验收 0/5）→ **340–730ms**（5 轮验收 0 bad），实测 161 个 RayNeo 线程中 32 个降至 nice=10。② WebUI 健康分首屏：可用内存/堆/swap/mem PSI/CPU PSI 综合 0–100 分 + 一句人话，解决"堆 249MB 正常但物理内存 99.3% 用满"的误判；`collect_stats` 新增 `swap_total_kb`/`swap_free_kb`/`cpu_psi_s10`；折叠区 6→4。单测 266/266；模块总 RSS 12.8MB、CPU 1.5% 单核；快照 628→257（7 天清理生效）。**诚实边界**：cpu_scan 340–730ms 仍高于 300ms 目标（memo 探针与降权循环各遍历 161 线程一次），`drop_caches` 仍未实弹触发。

- **v1.13.17（2026-11-08）**：FR-RN1 批量 renice——首次通过验收（上游根因见 v1.13.18 条目）；同提交含 v1.13.16 的还原完整性与零 fork 修复，故 v1.13.16 不单独发版。

- **v1.13.15（2026-11-08）**：近 5 次部署审计后的**纯降本**版本（审计：628 个堆快照覆盖 19 天 + 37.3h 归档日志）。四项：① **A-1 堆探测条件化**——`dumpsys meminfo` 是唯一的 9s 级扫描尖峰源（14 次 >1000ms 全紧邻 probe），改为「RSS 变化 <30MB 且 mem PSI <5% 且非抑制/复测期」时跳过（落 `act=ss_probe_skip`），预期 98 次/天 → 10–20 次/天；② **A-2 扫描日志降频**——慢扫描（≥300ms）立即记、正常每 5 轮记一次（原占日志 32% 行数）；③ **A-3 堆快照限流**——非危机态每小时 1 个（危机 ≥470MB 不限，OOM 现场不丢），每天清 7 天前；④ **A-4 护航复用前台采样**——FR-9 不再单独 `dumpsys window`（37h 内 821 次重复调用），改用循环内每 10s 的 `focused_pkg`。零功能损失、阈值语义不变、WebUI 未动。单测 241/241；部署 7 步全绿（`cpu_scan` 首轮 100ms、四守护新 pid、`uptime` 连续）；设备读回脚本逐字节一致。

- **v1.13.14（2026-11-08）**：FR-SS 六项硬化，源自 11-07 第四起 `system_server HeapFull 501MB` 取证（当日 `ss_heap_relief` 尝试 22 次**全部失败**、`ss_heap_trim` **0 次成功**——唯一泄压 `am send-trim-memory` 走 binder 到 system_server，堆濒死时必然不可达）——① 新增内核路径兜底 `ss_drop_caches`（`echo 3 > /proc/sys/vm/drop_caches`，限流 10min/次、1h≤6 次；只回收 page cache/slab，不触碰 Java 堆、不动 zram、不改持久参数）；② `am` 单轮重试 ×3（立即/+4s/+8s，总阻塞 ≤8s），失败必走内核兜底，复测 120s→30s；③ 阈值前移 430 预备 / 450 完整链 / 460 GC / 470 告警 / 480 极限压制；④ GC 提权 -10→-15 + `taskset -p e0` 绑大核（失败静默降级），还原 delta renice + 亲和 `ff`；⑤ 趋势判定改为「连续 3 次探测 <430MB 才撤销建议」，消除高位震荡抖动；⑥ 抑制态→极限压制（检测 `reboot_suppressed.flag` 时探测 60s + 每轮全手段叠加）。WebUI：flag `_mtime` 时效化（>24h 降级进技术细节，解决历史提示永久占首屏）、ⓘ 弹层点外部任意处关闭、禁用按钮写明原因、修复 `.quick/.oprow/.advbtns button` 特异性误伤（圆形 ⓘ 被拉成椭圆且点击错位）、阈值刻度同步 450/460/470/496。单测 231/231；8 步部署全绿（`cpu_scan=140ms`、四守护新 pid、`uptime` 连续未重启系统）；设备读回 `mt_lib.sh`/`index.html` 逐字节一致。**诚实边界**：system_server 堆泄漏在框架内部，用户态只能延后与缓解，不能承诺不再发生。

- **v1.13.13（2026-11-05~06）**：① 修复 FR-RN1 memo 探针性能回归——`rayneo_memo_active()` 与降权循环的 `cat comm` 改为 mksh 内建 `IFS= read -r` 零 fork（A/B 铁证：恢复旁路后 `cpu_scan` 从 1770–13010ms 回落到 210–220ms 而 CPU PSI 未同步下降）；② WebUI P2 四项——HAL tombstone 累计/最近、incident 快照 reason 摘要、「重启守护」按钮（二次确认 + 基线污染提示）、自动刷新 15s→30s；③ WebUI 四维审查后 3 项修复——时间值统一格式化、堆危机刻度改图例、第二次 exec 失败/分段异常不再静默降级；④ **RayNeo 语音链路削峰豁免**——启动风暴 `renice_tree` 原会把音频采集/ASR/网络回调线程整进程压到 nice+5（实测 `deprioritize_rayneo=1`），现于削峰路径新增 `com.rayneo.venus.pub*` 专用豁免与 `act=voice_asr_skip` 审计日志，不改全局白名单。单测 142/142，4 脚本 `sh -n` 通过。

- **v1.13.12（2026-11-04）**：FR-RN1 雷鸟治理代码审计后五缺陷修复——restore 逐条 Tgid 归属校验（防 tid 复用误伤）、`oom_score_adj ≤300` 眼镜活跃判据（投屏/息屏场景手机焦点不可靠）、风暴期 governor 可达（仅还原不降权）、cpu_guard 退出与 `memtonic.sh stop` 双路径清场、memo 激活态门控（`AlwaysOnAiRunti` VAD 存在即不降权）；WebUI P0/P1 一致性补强：堆危机可视化（`ssheap` 阈值带 460/480/485/496MB）、状态与约束透明（版本/四守护/root/FR-RN1 旁路/rollback enabling）、5 张能力计数卡（`collect_stats` 追加 flush/gcboost/ssprobe/forecast/bt3）、建议横幅按 `reason=` 三套文案、start 幂等状态机与异常横幅、软重启文案统一为「倒数第二手段·模块绝不代执行」。单测 43/43 + 114/114，7 步部署全绿、零守护重启。

- **v1.13.0~1.13.11（2026-10-26~11-03）**：干预经济学重构（批量 renice 引擎，fork ~220→~6/轮）、FR-C3 风暴态（1h≥6 次维持护航、30min 硬顶）、FR-SS 升级链（trim→复测→真泄漏建议）、GC 危机加速（堆≥480MB 提权 ART GC 守护线程）、内存余量预测器与前置压实（avail<2.5GB 且 swap>7.5GB 连续 3 轮）、耗电治理 V2（fluency_shield 日均 CPU 7.9h→7.5% 单核，-88%）、核亲和约束（fg-service CPU 大户迁 background cpuset）、FR-BT3 双通道、日志轮转竞争修复、rollback 拆雷、FR-RN1 雷鸟后台线程降权。完整逐版本记录见 `CHANGELOG.md`。

- **v1.12.9（2026-10-23）**：system_server 堆高水位防护 FR-SS（460MB trim / 485MB 告警双水位 + 1800s 定期兜底探测，封堵"堆爬升但 RSS 未越限"盲区）+ `ss_heap_probe` 探测经济性（单次 dumpsys，判定与快照共用）+ FR-BT2 防抖入与 90s 还原冷却 + 高 CPU 退避（cpu_psi≥35% 抑制 FR-BT/BT2 新增提权，防干预风暴饿死 GC）+ collect_stats/WebUI 新增 `ssheap` 实时字段 + 版本串五处统一。源自 10-22 system_server OOM 498MB 取证；`am send-trim-memory RUNNING_CRITICAL` 实测对 system_server 可用但弱效。

- **v1.12.5~1.12.8（2026-10-18~20）**：FR-C3 Flush Sentinel（face-service 借相机护航，含泄漏/降频修复）、FR-BT2 RayNeo GATT/LE 压力护航、WebUI 重做与 toybox grep 交替语法计数修复（v1.12.3/4）、FR-BT3 断连后 LE 重连护航、相机白名单活跃态门控、设备漂移热修（FR-9 CPU PSI 口径 / ss_health_probe 挂载 / 孤儿生命周期 / FR-C3 预提权 / majflt 虚报封顶）。

- **v1.12.3（2026-10-16）**：WebUI 修复与重做——修复控制按钮因调用未定义函数而完全失效（P0）、exec 无超时导致刷新可永久卡死、PSI 空值渲染异常、护栏护航计数键名错误恒显 0；新增数据更新时间/自动刷新倒计时、busy 秒计与看门狗、页面内确认弹窗、SVG 图标与更大触控区。

- **v1.12.2（2026-10-16）**：修复 `fg_majflt_burst` 虚报。根因：cgroup tasks（含主线程和线程）被误当 pid 列表去累加 `/proc/pid/stat` 的 majflt；同 pid 多线程的活动重复累计，导致 454M/60s 这种"四个数量级"的假数据。现在单次 awk 内逐 tid 读 stat 并汇总真增量。

- **v1.10.0（2026-10-10）**：内存风暴三件套——mem PSI 60s 连续监测（内建 read 零 fork）、灾难黑匣子（连续 2 轮 some≥25 落盘 PSI/meminfo/RSS+majflt Top10）、亮屏风暴级压实例外（psi some≥30 唯一通道，常规亮屏禁压铁律不变，相机/截屏守卫无条件）；kswapd>90s/h 顺手压实；前台 majflt 差分指纹预警。源自 2026-10-09 Synology 转码爆内存事故取证。

- **v1.9.12（2026-10-08）**：全模块 ARG_MAX 深度审计（7 脚本全覆盖，实测取证：`dumpsys rollback`=154KB 超 128KB 上限，证实哨兵缺陷 100% 必触发并已修复）；封堵 gfxinfo 同型捕获点（改临时文件快照）；修正 v1.9.11 部署期 printf 报错的错误归因（实为哨兵缺陷，非 stop 还原路径）；同步 fluency_shield 版本串。
- **v1.9.11（2026-10-08）**：Staged Rollback 自动排除哨兵（6h 去重检测 enabling 态，`pm install-abandon` 自动处置，默认 dry-run，`touch run/rollback_disarm.enable` 启用）；system_server PID 变化自动重置 vk 门闩并重拉监视器；启动时输出环境基线（max_cached/lmk/watermark）。
- **v1.9.6（2026-10-02）**：修复 uninstall.sh 盲杀防变砖；修复 alive() 函数对护栏脚本的匹配逻辑；修复 vk_injector.sh 处理多 PID 空格参数引发的报错问题。
- **v1.9.5（2026-10-01）**：打包发布，包含一系列热修复。
- **v1.9.4（2026-10-01）**：移除无效的 `updateJson`；同步各脚本版本号与文档一致性；修复 service 和 uninstall 的绝对路径解析问题；引入 CPU 护栏死线程清理防泄漏。
- **v1.9.3（2026-10-01）**：修复 `start` 启动被拦截的问题；修正 `CHANGELOG` markdown 格式；去除硬编码路径提升可移植性；新增 `updateJson` 以支持 KernelSU 更新检测。
- **v1.9.2（2026-10-01）**：移除全局 IPv4 TCP sysctl 注入避免副作用，清理遗留失效代码，增加 `memtonic.sh` 控制流兜底。
- **v1.9.1（2026-10-01）**：VPN 进程（FlClash/Clash Meta）加入白名单豁免降权。
- **v1.9.0（2026-10-01）**：废除 kswapd 亲和性强制绑定以防内核冲突；修复微信双开等双 PID 场景提权/还原崩溃；解除 staged rollback 活动时 soft_reboot 建议的逻辑死锁。
- **v1.5.0（2026-09-29，Sentinel P0 融合 + 性能瓶颈攻坚）**：
  1. **Restore 批量秒级极速还原**：同目标 nice 分组批量聚合，通过 toybox `renice -p` 批量传参，将 3600 次串行子进程调用缩减为数十次，耗时从 185s 骤降至 <2s（提速 98%）；
  2. **启动风暴 20s 平滑冷却期**：连续 3 次低于 PSI 阈值后增加 20s 冷却确认，防二次广播反弹；
  3. **动态前台服务免削峰**：基于 `/proc/$pid/oom_score_adj <= 200` 动态免削峰（音乐、录音、蓝牙穿戴），无需维护庞大白名单，杜绝后台听歌爆音；
  4. **常态维护纯按需化**：彻底剔除 `drop_caches`，保护应用热缓存；取消 4 小时机械定时，改为内存高压（PSI mem >= 15% 且息屏空闲）按需压实；
  5. **Sentinel P0 核心融合**：
     - `check_staged_rollback`：事前检测 `dumpsys rollback` 挂起状态（防硬重启丢 Root）；
     - `capture_incident`：框架重启 60s 内自动产出结构化黑匣子快照 `run/incident-<ts>.log`；
     - `check_root_liveness`：KernelSU 驱动解挂自检并优雅退出。
- **v1.4.3（2026-09-29）**：renice 口径显式化（新增线程级 reniced_tid 计数与 unit=tid 标注，还原前保存打击面明细快照）。
- **v1.4.2（2026-09-28）**：清理跨重启残留的 `STORM_FLAG`。
- **v1.4.1（2026-09-28）**：修复级联重触发，白名单补充，增加耗时统计。

## 一、它解决什么问题

针对临时 Root 场景实测定位出的问题：
1. **启动期**：KSU 软重启后大量应用并发启动引发风暴（CPU PSI 饱和 73–91%），桌面卡死最长 2.1 秒；
2. **还原期**：传统单线程逐个调用 renice 耗时漫长（高达 185 秒）；
3. **安全期**：Google Play Mainline 的 Staged Rollback 在重启时会导致整机硬重启丢失临时 Root；
4. **运行期**：日常内存维护缺乏真正按需驱动的机制。

v1.5.0 将启动风暴治理与 Sentinel P0 安全哨兵深度融合，实现全自动防误重启、极速削峰与秒级恢复。

## 二、功能清单（v2.0.1 极简双核心架构）

| 功能 | 触发条件 | 作用范围 |
|---|---|---|
| **前台极速护盾（fluency_shield）** | 前台焦点感知 / 息屏自适应 | 动态监测当前前台应用并赋以 nice -10 调度护航；息屏自动进入 20s 低功耗短路休眠，自耗 CPU 压缩 90%+ |
| **相机硬件级护航（Camera Guard）** | 打开相机 / 录像启动时 | 极速将相机核心服务（`cameraserver`、`provider`）绑定至高通骁龙 8 Gen 2 大核（CPU 4-7），彻底杜绝预览取景与快门掉帧卡顿 |
| **全屏截屏免扰哨兵（Screenshot Sentinel）** | 截屏目录时间戳变化检测 | 0-fork 检测截屏文件生成时刻，动态保护截图处理与悬浮窗绘制，免除后台应用争抢 CPU |
| **系统核心堆高水位防护** | 周期性直读 `/proc/$ss_pid/smaps_rollup` | 纯只读内核统计预警 system_server Java 堆；智能触发 ART GC Boost 与大核亲和，软重启后立即自愈恢复，根除 Binder IPC 阻塞 |
| **软重启自愈与无障碍恢复** | system_server PID 变更时感知 | 软重启发生 10s 内自动触发清理旧标志、重拉状态探针并执行 `settings put secure enabled_accessibility_services` 恢复无障碍服务 |
| **高门槛极端 CPU/IO 熔断** | 每 3 分钟巡检且系统高负荷时 | 仅对失常暴走的应用线程施加单次降权，绝不误伤前台焦点或音乐/蓝牙后台服务 |
| **按需内核内存压实** | 息屏空闲且 Memory PSI some avg10 >= 15% 且距上次 ≥6h | 纯按需压实，全生命周期彻底剔除 `drop_caches` 负优化，保护应用热缓存 |
| **KernelSU 3.x 深度合规 WebUI** | 用户打开 WebUI / Action 按钮 | 现代自适应卡片看板，实时精准呈现 8 项核心统计、健康分与系统核心堆；遵循官方临时描述覆盖与无 favicon 报错规范 |

## 三、文件结构

```text
rmg_memtonic/
├── module.prop         模块元数据（v2.0.1 / versionCode 72）
├── customize.sh        KernelSU 模块安装契约脚本（数据迁移与权限设置）
├── hotinstall.sh       免重启热安装与卡片状态自愈脚本（自动清理孤儿 update 锁）
├── service.sh          KernelSU 开机与软重启异步入口脚本
├── action.sh           KernelSU 管理器 [▶️] 操作按钮原生执行契约脚本
├── uninstall.sh        模块卸载深度清场与配置还原脚本
├── webroot/
│   └── index.html      现代交互式 WebUI 状态面板与控制中心
└── scripts/
    ├── mt_lib.sh       模块公共函数库（常量、日志、Cgroup 与亲和性、8 项统计采集、系统堆只读探测）
    ├── memtonic.sh     核心调度主守护（内存压实、软重启自愈、无障碍恢复、极端高负荷熔断、CLI 状态管理）
    └── fluency_shield.sh 前台防掉帧守护（前台调度护航、相机大核绑定、截屏瞬态削峰、息屏深度休眠）
```

## 四、安全保证与四大底线

1. **零系统修改**：不修改任何系统只读分区（`/system`、`/vendor`、`/product`），所有调优纯运行于内存级参数；
2. **零变砖风险**：严禁仅凭 PID 盲杀进程，校验 `/proc/<pid>/cmdline` 避免系统服务误杀；无同步阻塞启动链；
3. **零模块冲突**：继承内核 Cgroup 与 `/top-app` 调度意图，动态豁免前台音乐、录音、蓝牙，不与 Scene、NoActive、GKD 冲突；
4. **零负优化代码**：彻底剔除 `drop_caches`，绝不在亮屏与前台运行期盲丢缓存，所有机制均有可测指标支撑。
