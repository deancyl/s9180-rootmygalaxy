# RMG MemTonic 版本变更日志

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


