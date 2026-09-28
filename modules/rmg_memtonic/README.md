# RMG MemTonic —— SM-S9180 临时 Root 会话内存维护模块

- 模块 ID：`rmg_memtonic` ｜ 版本：v1.4.1 ｜ 适用：Galaxy S23 Ultra（SM-S9180，dm3q）KernelSU 临时 Root（late-load）方案

## 版本历史

- **v1.4.1（2026-09-28，真实软重启 16 窗日志实证驱动）**：
  1. 修复风暴窗口级联重触发——`storm_restore_pending` 的全局变量 `cur` 改名 `r_cur`，护栏主循环改为窗口前先固化 `base`（双重保险）。此前同一 sspid 会连续重开 4-11 轮窗口（01:00 软重启 5 轮、07:40 软重启 11 轮，共 16 窗 vs 应有 2 窗；沙箱 mt_curtest 实证覆盖机制）。
  2. 白名单补充 `com.catalinagroup.`（HK 通话录音）/ `com.nutomic.`（syncthing）/ `com.wangc.`（记账）——真实窗口日志实证三者曾被削峰（还原 ok / failed=0，但违反"不打断后台服务"意图）；同时新增 `whitelist_skip` 留痕日志（S 级仅写文件），保护机制从不可观测变为可审计。
  3. `storm_end` 增加 `scan_ms` / `restore_ms` 计时——480s 窗口上限实测被突破至 619s，此前的归因（扫描慢 vs 还原数千线程）无数据支撑，现在可归因。

## 一、它解决什么问题

针对临时 Root 场景实测定位出的**两个卡顿问题域**：

1. **启动期**（每次 KSU 软重启后约 10 分钟）：框架重建引发进程拉起风暴（实测 357–374 个 / 3.5 分钟、峰值每秒 11 个），CPU PSI 饱和 73–91%，桌面首帧冻结最长 2.1 秒——与用户操作无关，纯系统驱动；
2. **运行期**（多日不重启）：内核内存碎片渐进累积（实测 4.8 天后 zram 已压实 1900 万页、kswapd 累计 7.5 CPU 小时），表现为"越用越卡"。

v1.3.0 用**启动风暴护栏**（CPU 优先级削峰）与**息屏内存维护**双管齐下——不杀任何进程、不打断任何后台服务。

## 二、功能清单

| 功能 | 触发条件 | 作用范围 |
|---|---|---|
| **启动风暴护栏（storm guard）** | system_server PID 变化（KSU 软重启）/ 新生（<3 分钟） | 8 分钟窗口（CPU PSI 回落可提前退出）：桌面全线程 renice -4 让路；窗口内**新启动**的应用进程 renice +5 削峰（仅限 uid 应用、白名单与前台焦点豁免、仅动 nice=0）；窗口结束逐一还原；期间禁止一切维护动作 |
| 内核内存压实（compact_memory） | 息屏（Asleep/Dozing）且距上次 ≥4 小时 | 全局内存 zone 一次性压实 |
| 丢弃干净页缓存（drop_caches=1） | 息屏维护时可用内存 <2GB | 仅可由存储重建的文件缓存页，App 匿名内存零接触 |
| 结构化日志（E/A/W/X/S 五级） | 事件驱动 + 每小时快照 | key=value 单行；超 256KB 字节基准截断；E/A/W/X 镜像 logcat（tag=MemTonic，无 root 可诊断）；快照含自身 CPU 核算（self_cpu_ms） |
| zram 空闲页重压缩 | 默认关闭（本机内核无接口，自动跳过） | 无 |
| 亮屏应急压实 | 默认关闭（EMERG=0 可开启） | 可用内存 <1.2GB 时轻量压实 |

**护栏削峰的安全边界**：只调 nice（排队位置），不 kill、不冻结、不 SIGSTOP；还原清单持久于 `/data/local/tmp/memtonic_storm_renice.lst`，护栏意外死亡后下次启动补还原。

**明确不做的事**：不杀/不冻结任何进程；不改 CPU 调度、温控、governor；不改 zram 设备参数（RAM Plus 大小/算法零接触）；不持久化任何系统属性；无挂载；无 sepolicy；无 boot 阶段脚本。

## 三、文件结构（v1.3.0 起三文件）

```
scripts/
  mt_lib.sh       公共库：常量 + 日志 + 全部辅助函数（两进程各自 source）
  memtonic.sh     守护主进程：维护调度 + once/status/stop/guarddry
  storm_guard.sh  护栏子进程：风暴检测 + 窗口执行（随守护生死）
```

> ⚠️ Android 16 mksh 实测约束：**后台化"shell 函数"会瞬时死亡**（直接子壳 `&` 可靠、函数 `&` 必死），因此护栏必须独立脚本，勿合并回函数调用。

## 四、安装 / 使用 / 卸载

**安装**（临时 root 会话内，adb 或终端执行）：
```
su -c 'mkdir -p /data/adb/modules/rmg_memtonic/scripts'
su -c 'cp module.prop service.sh uninstall.sh /data/adb/modules/rmg_memtonic/'
su -c 'cp scripts/mt_lib.sh scripts/memtonic.sh scripts/storm_guard.sh /data/adb/modules/rmg_memtonic/scripts/'
su -c 'chown -R root:root /data/adb/modules/rmg_memtonic && chmod -R 755 /data/adb/modules/rmg_memtonic'
```
安装后当次会话即可手动启动：`su -c sh /data/adb/modules/rmg_memtonic/service.sh`

**日常使用**：
```
sh /data/adb/modules/rmg_memtonic/scripts/memtonic.sh status    # 状态/护栏/最近日志
sh /data/adb/modules/rmg_memtonic/scripts/memtonic.sh once      # 手动维护（风暴期自动拒绝）
sh /data/adb/modules/rmg_memtonic/scripts/memtonic.sh guarddry  # 干跑：打印削峰候选，不修改
sh /data/adb/modules/rmg_memtonic/scripts/memtonic.sh stop      # 停止（TERM+KILL 双保险）
```

**生命周期**：重启后随临时 Root 一起失效；每次重新 Root 后由 ksud 自动执行 service.sh 拉起。**卸载**：KernelSU 管理器中删除本模块（uninstall.sh 自动清理）。

## 五、与其他调度机制的关系（实测依据）

- **三星官方调度**：compact_memory/drop_caches 为一次性动作触发器，无持久设置可被"覆盖"；root 守护进程不受 lmkd/设备维护管辖。
- **Scene**：Scene 域为 swappiness/cpuset/cpufreq/swap_ratio/watermark_*，与本模块接口零交集。护栏已内置防御：只动 nice=0 的进程、动过即记录、幂等可回退。注意：勿开 scene_swap_controller 的 flash swap 文件功能（与 RAM Plus 的冲突点，与本模块无关）。
- **NoActive / GKD / Brevent / Rikka**：已列入护栏白名单（`WHITELIST_PKGS` 前缀匹配），永不削峰。
- **临时 Root 流程**：不触碰 exploit/late-load 链路；重 root 时由 ksud 自动恢复。护栏跨 KSU 软重启存活（软重启不清内核，root 会话不中断）。

## 六、日志规范（v1.3.0）

- **级别**：`L=E` 事件（start/stop/storm_start/storm_end）、`L=A` 动作（每条 renice/还原，含 tid/包名/nice 前后值）、`L=W` 警告（维护顺延等）、`L=X` 错误（还原失败等，绝不静默吞错）、`L=S` 快照（每小时 + 窗口内每轮扫描）。
- **快照字段**：`avail_kb swap_kb psi_cpu psi_mem psi_io load1 procs self_cpu_ms zram_compr_pct`——`self_cpu_ms` 用数据证明模块自身负担（v1.3.0 实测启动即 <50ms）。
- **产出**：文件 `/data/adb/modules/rmg_memtonic/run/memtonic.log`（超 256KB 字节基准截断）+ logcat `tag=MemTonic`（E/A/W/X）。每日写入量 <100 行，闪光灯写入可忽略。

## 七、可调参数（scripts/mt_lib.sh 头部常量）

| 常量 | 默认值 | 说明 |
|---|---|---|
| CHECK_INTERVAL | 3600 | 守护轮询间隔（秒） |
| FULL_INTERVAL | 14400 | 息屏全套维护最小间隔（秒） |
| NIGHT_DROP_BELOW | 2000000 | 息屏维护时清缓存触发阈值（KB） |
| STORM_WINDOW | 480 | 护栏窗口上限（秒） |
| STORM_POLL | 5 | system_server 监视轮询间隔（秒） |
| STORM_SCAN | 15 | 窗口内进程扫描间隔（秒） |
| STORM_EXIT_PSI | 10 | 提前退出的 CPU PSI some avg10 阈值（%） |
| STORM_NICE_APP | 5 | 风暴进程削峰 nice 值 |
| LAUNCHER_NICE | -4 | 桌面让路 nice 值 |
| WHITELIST_PKGS | （见文件） | 白名单包名前缀 |
| EMERG / EMERG_AVAIL / RECOMPRESS | 0 | 亮屏应急与 zram 重压缩开关（同 v1.2.1） |

## 八、已知边界与说明

- 息屏判定基于 `mWakefulness=(Asleep|Dozing)`（本机熄屏态为 Dozing，三星特性）。
- 深度休眠（doze/suspend）期间 shell 计时器会被挂起，轮询顺延——无害。
- **削峰悖论（设计取舍）**：护栏会让风暴进程变慢，风暴总时长可能延长——这是"交互流畅 ↔ 后台收敛变慢"的交换，窗口上限 8 分钟兜底，实际时长见 `storm_end` 日志。
- **适用范围**：护栏仅在 MemTonic 存活时有效（KSU 软重启场景 / root 已恢复场景）；完整重启后 root 丢失，重 root 时风暴已过，护栏无需也用不上。
- v1.2.x→v1.3.0 实测踩坑记录（详见模块内注释）：mksh 后台化函数瞬时死亡；`log` 函数名遮蔽系统 log 命令导致递归洪水（须用 `/system/bin/log` 绝对路径）；行基准日志轮转对巨行失效（须字节基准）；TERM 对 sleep 中的 mksh 循环可能无效（stop 须 KILL 兜底）；`pidof` 找不到内核线程（kswapd 需按 /proc/stat comm 匹配）。
