# RMG MemTonic —— SM-S9180 内存与异常守护模块

- 模块 ID：`rmg_memtonic` ｜ 版本：v1.9.12 ｜ 适用：Galaxy S23 Ultra（SM-S9180，dm3q）KernelSU 临时 Root（late-load）方案

## 版本历史

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
