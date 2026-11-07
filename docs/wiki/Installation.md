# 安装与升级

## 前提（务必核对）

| 项目 | 要求 |
|---|---|
| 机型 | Samsung Galaxy S23 Ultra **SM-S9180** |
| 固件 | **S9180ZHS8FZG1**（One UI 8.5 / Android 16） |
| 安全补丁 | 2026-07-05 或更早 |
| 状态 | 未解锁 bootloader、未刷机 |

⚠️ **2026-08 安全补丁及以后固件不再适用**——CVE-2026-43499（GhostLock）在该批补丁中被封堵，升级后本工具永久失效。

## 四步安装

1. **下载前置 APK**：Release 中的 `rootmygalaxy-0.2.36-ksu331.apk`（`sha256 b0bd6b5c…fa167`，内嵌 KernelSU v3.3.1），校验指纹后安装。
2. **获取临时 root**：打开 App，预热 → exploit → late-load。成功后 KernelSU 管理器会出现。exploit 期间 adb/网络可能短暂掉线，属正常。
3. **安装模块**：KernelSU 管理器 →「模块」→ 安装 → 选择 `MemTonic-vX.Y.Z.zip`。
4. **生效**：模块守护随 root 会话启动；在模块页打开 WebUI 查看状态。

## 升级到新版本

直接覆盖安装新 zip 即可；若手动替换脚本文件，必须让新代码生效：

```sh
su -c 'sh /data/adb/modules/rmg_memtonic/scripts/memtonic.sh stop'
su -c 'sh /data/adb/modules/rmg_memtonic/service.sh'
```

- `service.sh` **不会**重跑软重启（会丢 root），必须用 stop + start。
- **v1.13.14 起**改了 FR-SS 阈值与守护脚本，升级后必须重启一次守护（约 10 秒无护航），否则旧逻辑仍在内存中运行。
- 只改 WebUI（`webroot/index.html`）时无需重启守护。

## 回滚

```sh
# 内核侧脚本回滚（示例：v1.13.14）
su -c 'cp -p /data/adb/modules/rmg_memtonic/scripts.bak-1314/mt_lib.sh /data/adb/modules/rmg_memtonic/scripts/'
su -c 'sh /data/adb/modules/rmg_memtonic/service.sh'

# 仅 WebUI 回滚（无需重启守护）
su -c 'cp -p /data/adb/modules/rmg_memtonic/webroot.bak-1314b/index.html /data/adb/modules/rmg_memtonic/webroot/index.html'
```

模块目录内的 `scripts.bak-*` / `webroot.bak-*` 是各次部署前的自动备份。

## 卸载

KernelSU 管理器 → 模块 → 卸载。`uninstall.sh` 会清场并还原所有调度改动。
