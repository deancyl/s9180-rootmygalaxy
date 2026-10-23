# RMG MemTonic —— SM-S9180 内存与异常守护模块

- 模块 ID：`rmg_memtonic` ｜ 版本：v1.12.9 ｜ 适用：Galaxy S23 Ultra（SM-S9180，dm3q）KernelSU 临时 Root（late-load）方案

## 版本历史

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

## 二、功能清单

| 功能 | 触发条件 | 作用范围 |
|---|---|---|
| **启动风暴护栏（storm guard）** | system_server PID 变化 / 新生（<3 分钟） | 8 分钟上限：桌面全线程 renice -4 让路；窗口内新启动应用 renice +5 削峰（前台服务 oom_score_adj <= 200 动态豁免）；20s 冷却确认防反弹；批量秒级还原 |
| **Staged Rollback 挂起预警** | 周期性检测 `dumpsys rollback` | 发现 `state: enabling` 时高危告警 `W staged_rollback_active`，防止盲目重启丢失临时 Root |
| **Staged Rollback 自动排除（哨兵）** | 每 6h 检测 enabling 态 rollback（`rollback_disarm.enable` 启用后真实处置，默认 dry-run） | `pm install-abandon <originalSessionId>` 自动排除地雷（One UI 16 唯一有效路径）；active 安装中跳过；成功后写 flag 并 A 级日志 |
| **框架重启黑匣子快照** | system_server PID 变化时自动触发 | 60s 内异步生成 `run/incident-<ts>.log`（uptime, PSI, rollback, top 20, dmesg tail） |
| **Root 会话与驱动自检** | 循环自检 `/proc/modules` | 驱动解挂时安全退出，绝不空转 |
| **按需内核内存压实** | 息屏空闲且 Memory PSI some avg10 >= 15% 且距上次 ≥6h | 纯按需压实，彻底剔除 drop_caches |
| **结构化可审计日志** | 事件驱动 + 每小时快照 | E/A/W/X/S 五级；超 256KB 字节基准截断；logcat 镜像 |

## 三、文件结构

```text
scripts/
  mt_lib.sh             公共库：常量 + 日志 + 批量还原 + Rollback/快照/自检核心函数
  memtonic.sh           守护主进程：维护调度 + Rollback 巡检 + status/stop/guarddry
  cpu_guard.sh          CPU失常护栏与崩溃雷达
  fluency_shield.sh     前台绝对护盾防线
  storm_guard.sh        护栏子进程：风暴检测 + 冷却控制 + 黑匣子快照（随守护生死）
  vk_injector.sh        Vulkan强启与无障碍自愈护盾
  in_app_stress_test.sh 应用内压测辅助
```

## 四、安全保证与四大底线

1. 零系统修改：不修改任何系统只读分区；
2. 零变砖风险：无任何 reboot 指令，无阻塞 boot 脚本；
3. 零模块冲突：不碰 Scene 与 NoActive 参数，调度防互殴；
4. 零冗余代码：剔除 drop_caches，所有新增功能均直接生效。
