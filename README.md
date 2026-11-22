# RootMyGalaxy & MemTonic (Samsung Galaxy S23 Ultra Special Edition)

> 🚀 **专为三星 Galaxy S23 Ultra（SM-S9180）打造的免熔断（Zero-Knox）临时 Root 引擎与 MemTonic 深度调优守护生态**  
> 基于上游 [BuSung-dev/Root-My-Galaxy](https://github.com/BuSung-dev/Root-My-Galaxy) 的 v0.2.36，针对港版/国行 `S9180ZHS8FZG1`（骁龙 8 Gen 2 for Galaxy）固件深度移植，内嵌 **KernelSU v3.3.1 (32680)** 晚期加载（late-load）引擎与 **MemTonic v2.0.1** 实时性能与内存守护体系。

> ⚠️ **【核心安全边界：内存态临时 Root】**  
> 本项目所有机制均为**纯内存态运行**：**绝不刷写任何系统只读分区**（`/system`、`/vendor`、`/product`）、**绝不解锁 Bootloader**、**绝对不触发 Knox 物理熔断（0x0 状态恒久保持）**！日常重启后系统瞬间恢复 100% 官方原厂纯净状态，无任何持久化残留与保修风险。

---

## 📱 机型适用范围与兼容性声明 (Compatibility Matrix)

| 分级 | 设备型号 / 平台 | 固件 / SPL 基线 | 状态与支持承诺 |
|---|---|---|---|
| **Tier 1<br>（官方首发 / 深度实测）** | **Samsung Galaxy S23 Ultra**<br>(`SM-S9180`, 港版 / 国行同硬件) | **S9180ZHS8FZG1**<br>(One UI 8.5 / Android 16)<br>SPL: **2026-07-05** 及更早 | **100% 官方验证与深度支持**。<br>全链路经过 ADB 真机压测、KernelSU Manager v3.3.1 兼容、大核调度亲和性与 WebUI 闭环验收。 |
| **Tier 2<br>（社区实验 / 极客探索）** | **其他三星高通骁龙机型**<br>(如 S23/S23+、S24 系列、Z Fold/Flip 系列等) | 骁龙 8 Gen 2 / 8 Gen 3 平台<br>且 SPL ≤ 2026-07-05 | **理论相通，但不做任何可用性与稳定性保证**。<br>CVE-2026-43499 内核利用与 ksud late-load 机制在架构上通用，极客用户可自行尝试，但因 OEM 分区基址、内存映射及调度拓扑差异，**官方不提供测试与效果承诺，请自担风险**。 |
| **Tier 3<br>（明确不支持 / 严禁尝试）** | **Exynos 猎户座芯片机型**<br>非三星厂商设备<br>**2026-08 及以后安全补丁固件** | 任意固件 | **完全不支持**。<br>2026-08 及以后的补丁已封堵 CVE-2026-43499；猎户座芯片内核结构与补丁逻辑完全不同，强行运行必将失败。 |

> 🔍 **真机核对方法**：手机进入「设置」→「关于手机」→「软件信息」，确认「型号名称为 SM-S9180」、「内核版本为 5.15」、「Android 安全补丁级别为 2026-07-05 或更早」。终端执行 `adb shell getprop ro.build.fingerprint` 应含 `S9180ZHS8FZG1`。

---

## 📦 Releases

### 🧩 MemTonic 深度调优模块 Releases（配套临时 Root 使用）

MemTonic 是专门配套本临时 Root 环境运行的高性能 KernelSU 模块：开机/软重启后自动拉起，对前台渲染、相机硬件调度、系统核心堆异常、无障碍自愈进行静默守护，Root 失效后自动停止。

> 💡 **安装提示**：模块需运行在临时 Root 会话中。每个 Release 均附带前置推荐 APK（`rootmygalaxy-0.2.36-ksu331.apk`）。请先安装并打开 APK 激活临时 Root，再于 KernelSU 管理器中刷入模块 ZIP。

| MemTonic 版本 | 状态 | 核心亮点与适用人群 | 推荐度 |
|---|---|---|:---:|
| [`v2.0.1`](https://github.com/deancyl/s9180-RootMyGalaxy-MemTonic/releases/tag/v2.0.1) | **正式最新版 (Latest)** | **里程碑升级：KernelSU 3.3.1 深度合规 + 极简双核心架构 + WebUI 8 项统计完全自愈**<br>① **架构精简收敛**：废除 4 个分散子守护，收敛为 `memtonic.sh`（主调度与系统核心守护）与 `fluency_shield.sh`（前台防掉帧护盾）；<br>② **卡片锁定自愈**：解决临时 Root 热刷入产生的孤儿 `update` 锁，修复卡片 Switch 置灰与按钮隐藏通病；<br>③ **WebUI 状态看板完全自愈**：修复 `mt_lib.sh` 在 source 下 `$0` 路径误算历史根因，模块 8 项核心统计实时精准呈现；<br>④ **相机与截屏硬件护航**：打开相机极速绑定骁龙 8 Gen 2 大核（CPU 4-7），彻底杜绝掉帧；截屏哨兵 0-fork 时间戳检测免扰；<br>⑤ **全生命周期零 drop_caches**：彻底移除盲丢缓存逻辑，保护应用热数据。 | 🌟🌟🌟🌟🌟<br>**全员首选** |
| [`v1.13.20`](https://github.com/deancyl/s9180-RootMyGalaxy-MemTonic/releases/tag/v1.13.20) | 历史稳定版 | FR-4 毒瘤检测全面恢复与全链路零 fork 极速重构。单次 awk 批量采集，活跃进程一级包名缓存，真机 5 轮扫描稳保 < 300ms 预算。 | 历史存档 |
| [`v1.13.19`](https://github.com/deancyl/s9180-RootMyGalaxy-MemTonic/releases/tag/v1.13.19) | 历史版本 | 外部审计 9 项修复：Tgid Tab 分隔符、cpuset 改 `cgroup.procs`、卸载清场补齐、renice 增量语义守卫。 | 历史存档 |
| [`v1.13.18`](https://github.com/deancyl/s9180-RootMyGalaxy-MemTonic/releases/tag/v1.13.18) | 历史版本 | FR-RN1 雷鸟后台治理首次启用 + WebUI 健康分首屏。 | 历史存档 |

---

### 📱 RootMyGalaxy 前置临时 Root APK Releases

| Release | 说明 | 内嵌 KernelSU 版本 | 适用人群 |
|---|---|---|---|
| [`v0.2.36-ksu331`](https://github.com/deancyl/s9180-RootMyGalaxy-MemTonic/releases/tag/v0.2.36-ksu331) | **增强变体（官方推荐）** | 内嵌 **KernelSU v3.3.1 (32680)** | 配套最新 KernelSU Manager v3.3.1 使用（强烈推荐） |
| [`v0.2.36-ksu330`](https://github.com/deancyl/s9180-RootMyGalaxy-MemTonic/releases/tag/v0.2.36-ksu330) | 增强变体 | 内嵌 KernelSU v3.3.0 (32601) | 需要上一代 KSU 驱动环境者 |
| [`v0.2.36-fzg1`](https://github.com/deancyl/s9180-RootMyGalaxy-MemTonic/releases/tag/v0.2.36-fzg1) | 原版基线 | 内嵌 KernelSU v3.2.5 | 仅供基线对比 |

---

## 🛡️ MemTonic v2.0.1 核心技术架构

```
rmg_memtonic/
├── module.prop                  ← 模块声明（v2.0.1 / versionCode 71）
├── customize.sh                 ← KernelSU 安装契约（run/ 用户配置热迁移，不触碰 webroot SELinux）
├── hotinstall.sh                ← 免重启热安装与卡片状态自愈（自动清除孤儿 update 锁）
├── service.sh                   ← 异步守护入口（带 disable/remove 状态自检）
├── action.sh                    ← 管理器 [▶️] 操作按钮原生执行契约（校验双守护 PID 与系统堆）
├── uninstall.sh                 ← 卸载清场与系统调度完整复原
├── webroot/
│   └── index.html               ← 现代自适应 WebUI 状态监控看板与控制面板
└── scripts/
    ├── mt_lib.sh                ← 公共函数库（0-fork 提取、8 项统计采集、系统核心堆只读探测）
    ├── memtonic.sh              ← 调度主守护（内存压实、软重启自愈、无障碍自愈、高负荷熔断）
    └── fluency_shield.sh        ← 前台防线守护（前台调度护盾、相机大核绑定、截屏免扰哨兵）
```

### 1. 启动与前台极致提权（Fluency Shield）
- **前台焦点零延迟护航**：通过内核 `/proc/$pid/cpuset` 极速感知 `/top-app` 分组，赋予前台应用 UI/渲染线程 `-10` 绝对调度权；
- **息屏省电短路**：息屏后自适应转入 20s 深度低功耗睡眠，自身 CPU 占有率压缩 90%+。

### 2. 相机专属大核亲和（Camera Guard）
- 针对 S23 Ultra 高负载计算摄影场景，当相机进程启动时，瞬时将 `cameraserver` 及相关 HAL 服务绑定至骁龙 8 Gen 2 大核心簇（CPU 4-7），杜绝 4K60FPS 录像或快速连拍时的卡顿与跳帧。

### 3. 全生命周期零 `drop_caches` 铁律
- 坚决杜绝粗暴丢缓存引发的整机冷启动雪崩。仅在息屏且 PSI 内存压力指标超标时进行温和内核内存压实，全面保护系统与常用应用的热缓存。

### 4. 系统核心 Java 堆自愈与软重启守护
- 纯内核只读监控 `system_server` 的 Dalvik 堆内存水位，彻底消除 Binder IPC 卡死导致的 Watchdog 重启；
- 软重启（Soft Reboot）后 10 秒内自动自愈：重置状态门闩、自适应重新拉起无障碍服务（Accessibility Services）。

---

## 📲 使用与升级指南

### 首次安装与激活
1. 在 Releases 中下载 `rootmygalaxy-0.2.36-ksu331.apk` 并安装至手机；
2. 安装官方配套的 [KernelSU Manager v3.3.1](https://github.com/ReSukiSU/KernelSU/releases)；
3. 打开 RootMyGalaxy App，点击一键触发临时 Root；
4. 打开 KernelSU Manager 确认显示为「工作中（越狱模式）」；
5. 在 KernelSU 管理器中切至「模块」Tab，点击「安装模块」，选择下载的 `MemTonic-v2.0.1.zip`；
6. 刷入完成后点击模块卡片的 WebUI 按钮 `[< >]`，即可直接查看实时状态面板与健康分！

### 升级说明（免重启热升级）
- 模块原生支持 **越狱模式热部署**：在 KernelSU 管理器中直接刷入新版本 ZIP，`hotinstall.sh` 会自动接管新旧进程切换、热合并文件并消除 `update` 锁，**完全无需重启手机**。

---

## 🧾 二进制产物指纹与校验和

### MemTonic-v2.0.1.zip（模块安装包）
```text
MD5    : 15c5483820c1ea8fd48b9d5d60b2f836
SHA256 : 6d01fc0034ea52bbc972b6e8c0938b1f0e8b8ecde6f2dedc7f393a1e650e67da
大小   : 246,805 字节
```

### rootmygalaxy-0.2.36-ksu331.apk（官方前置推荐 APK）
```text
MD5    : b2ce7bcff966febe7e8965e25c243b0a
SHA256 : b0bd6b5c2ac754efd04cd60e1d83bce438d57b313ebc78dbf7df00bd6e1fa167
大小   : 68,178,226 字节
```

---

## ⚠️ 免责声明 (Disclaimer)

1. 本项目基于公开的安全漏洞（CVE-2026-43499）研究与实现，仅供技术交流与设备所有者个人安全测试使用。
2. 尽管内存态临时 Root 不会触碰设备闪存分区或 Knox 物理保险丝，但任何系统级调试与提权操作均存在潜在风险。作者不对因使用本工具导致的任何数据丢失、系统异常或设备故障承担法律责任。
3. 请在操作前务必备份个人重要数据。请勿将本项目用于任何违法违规用途。

---

## 🙏 致谢 (Credits)

- [BuSung-dev/Root-My-Galaxy](https://github.com/BuSung-dev/Root-My-Galaxy) — 上游临时 Root 核心工程基线
- [KernelSU](https://github.com/ReSukiSU/KernelSU) — 革命性的内核级 Root 解决方案
- CVE-2026-43499 (GhostLock) 内核漏洞的研究者与发现团队
