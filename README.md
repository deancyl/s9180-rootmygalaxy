# RootMyGalaxy for Galaxy S23 Ultra (SM-S9180 / FZG1)

针对 **三星 Galaxy S23 Ultra（SM-S9180）** 的 RootMyGalaxy 移植与增强版本发布仓库。
基于上游 [BuSung-dev/Root-My-Galaxy](https://github.com/BuSung-dev/Root-My-Galaxy) 的 v0.2.36，针对 `S9180ZHS8FZG1` 固件完成适配，并提供内嵌 **KernelSU v3.3.0** 的增强变体。

> ⚠️ **本仓库所有版本均为「内存态临时 root」**：不刷写任何分区、不解锁 bootloader、**不触发 Knox e-fuse**，重启后 root 失效，手机恢复完全原厂状态。

---

## 📦 Releases

| Release | 说明 | 适用人群 |
|---|---|---|
| [`v0.2.36-fzg1`](https://github.com/deancyl/s9180-rootmygalaxy/releases/tag/v0.2.36-fzg1) | **原版基线**：上游 0.2.36（已实测可成功临时 root 的版本），内嵌 KernelSU **v3.2.5** | 求稳、只求能用 |
| [`v0.2.36-ksu330`](https://github.com/deancyl/s9180-rootmygalaxy/releases/tag/v0.2.36-ksu330) | **增强变体**：同一基线，内嵌 ksud 换为 **KernelSU v3.3.0（32601）**，其余逐字节一致 | 想用最新版 KernelSU |

两个版本**exploit 链路完全相同**（逐字节一致），区别仅在于 late-load 的 KernelSU 版本。

## ✅ 适用范围（务必核对）

| 项目 | 要求 |
|---|---|
| 机型 | Samsung **Galaxy S23 Ultra SM-S9180**（港版/国行同硬件） |
| 固件（PDA/CSC） | **S9180ZHS8FZG1**（FZG1） |
| 系统版本 | One UI 8.5 / Android 16 |
| 内核版本 | `5.15.189-android13-8-33413713-abS9180ZHS8FZG1` |
| 安全补丁级别（SPL） | **2026-07-05**（或更早的 ZHS 系固件） |

### ❌ 不适用的情况

- 其他任何机型（含 S23 Ultra 其他销售地区固件的未验证版本）
- **2026-08 安全补丁及以后的固件** —— CVE-2026-43499（GhostLock）预计在该批补丁中被封堵，升级后本工具将永久失效
- 已解锁/已刷机的设备（未测试，后果自负）

**核对方法**：设置 → 关于手机 → 软件信息，确认「One UI 版本 / Android 版本 / 内核版本 / 安全补丁程序级别」与上表一致；或 `adb shell getprop ro.build.fingerprint` 应包含 `S9180ZHS8FZG1`。

## 🔧 工作原理

1. 利用内核漏洞 **CVE-2026-43499（GhostLock）** 获取内存态临时 root（uid=0）
2. 通过 ksud 以 **late-load（LKM）** 方式向内核加载 KernelSU 模块（手动重定位，无需修改任何分区）
3. 全程 **SELinux 保持 Enforcing**、**Knox 不受影响**、无任何持久化写入

## 📲 使用方法

1. 下载 Release 中的 APK，安装（需允许安装未知来源应用）
2. 打开 App，按界面提示触发临时 root
3. 打开 KernelSU Manager（v3.3.0 变体请使用 [KernelSU v3.3.0 Manager](https://github.com/ReSukiSU/KernelSU/releases)）确认状态为「工作中」
4. **重启后 root 失效**，需要时重新打开 App 再跑一次即可

## 🧾 校验和

### v0.2.36-ksu330（增强变体）

```
MD5    : 102f5dd4dbbab7fb7babbbb5a8bac8a2
SHA256 : 03135340607fba9d4f15c3183af62d83f64c87e311e8d6deef38de5edf9a8d00
大小    : 68,141,362 字节
```

### v0.2.36-fzg1（原版基线）

```
MD5    : 3b334cdad520f5d6f990ae661661824b
SHA256 : 17a88b2ed053bc1e54439a841b744bb2ee10f4ab90492ad431827db1f390b457
大小    : 69,820,722 字节
```

## ⚠️ 风险声明

- 本工具利用公开的内核漏洞实现临时 root，**任何 root 操作均有风险**，包括但不限于系统不稳定、数据丢失、极小概率的设备损坏
- Knox e-fuse 理论上不会被触发（不刷分区、不碰 bootloader），但**作者不对任何意外后果负责**
- root 后的内核模块行为（KDP/RKP/DEFEX 交互）已在目标固件上实测，但**不保证在其他固件版本上的行为**
- 请勿将本工具用于非法用途；仅供设备所有者在自己的设备上研究与使用

## 🙏 致谢

- [BuSung-dev/Root-My-Galaxy](https://github.com/BuSung-dev/Root-My-Galaxy) — 上游项目
- [KernelSU](https://github.com/ReSukiSU/KernelSU) — 内核级 root 方案
- CVE-2026-43499 (GhostLock) 的发现者
