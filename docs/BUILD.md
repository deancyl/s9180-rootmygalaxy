# 构建指南：KernelSU v3.3.0 (dm3q / SM-S9180 / FZG1)

本文说明如何从源码构建本仓库的两大产物：

1. **内核模块** `android13-5.15_kernelsu-dm3q-S9180ZHS8FZG1-330.ko`
   （KernelSU v3.3.0 + Samsung KDP/RKP/DEFEX 补丁，late-load 专用）
2. **ksud** `ksud-dm3q-S9180ZHS8FZG1-330-kdp`
   （内嵌上述模块的 v3.3.0 守护/加载器二进制，支持 `--ephemeral`）

## 前置条件

| 路径 | 需要 | 用途 |
|---|---|---|
| GitHub Actions（推荐） | 仅 GitHub 账号 | 零本地环境，Actions 页手动触发 |
| 本地/CI Linux | docker + git | 构建内核模块（kbuild 必须Linux） |
| 本地/CI Linux | Android NDK r27+ + rustup | 交叉编译 ksud |

## 方式一：GitHub Actions（推荐）

仓库自带 [`.github/workflows/build.yml`](../.github/workflows/build.yml)（`workflow_dispatch` 手动触发）：

1. Fork / 使用本仓库，进入 **Actions → ksu-330-dm3q → Run workflow**
2. 两个 job：
   - `module`：检出 KernelSU v3.3.0 → 应用 `patch/KernelSU-v3.3.0-samsung-kdp-rkp-defex.patch` → 在 DDK 容器 `ghcr.io/ylarod/ddk-min:android13-5.15-20260828` 内 kbuild
   - `ksud`：放入模块资产（rust_embed）→ NDK r29 交叉编译
3. 下载 artifacts，继续本地审计与部署

> 若 DDK 镜像 tag 失效，到 https://github.com/ylarod/ddk-min/pkgs 换一个有效的 `android13-5.15-<日期>` tag（同时改 workflow 的 `DDK_IMAGE`）。

## 方式二：本地构建

```sh
# 1) 内核模块（需要 docker）
./scripts/01-build-module.sh
#   -> out/android13-5.15_kernelsu-dm3q-S9180ZHS8FZG1-330.ko

# 2) ksud（需要 NDK r29）
export ANDROID_NDK_HOME=/path/to/android-ndk-r29
./scripts/02-build-ksud.sh
#   -> out/ksud-dm3q-S9180ZHS8FZG1-330-kdp
```

## 审计（部署前必须通过）

对**目标固件的 vmlinux** 做符号审计（vmlinux 需自行从对应固件解包获得）：

```sh
./scripts/03-audit-module.sh /path/to/vmlinux.elf
```

**硬门槛：`missing from target symbol table: 0`**。

- `MISSING_EXPORT` / `CRC_MISMATCH` 行是预期内的：Samsung 内核不导出
  `commit_creds` / `selinux_state` 等核心符号；late-load 手动重定位加载器
  从 `/proc/kallsyms` 解析全部未定义符号，内核不查 exports 与 `__versions` CRC。
- FZG1 实测基线：211 undefined / missing 0 / 0 CRC mismatch。

## 部署到设备

```powershell
./scripts/04-deploy-device.ps1              # 完整流程（推送+exploit+late-load）
./scripts/04-deploy-device.ps1 -Verify      # 仅检查状态
```

脚本期望 `payloads/` 下有 exploit payload 与 root helper
（`dm3q-S9180ZHS8FZG1__payload` / `dm3q-S9180ZHS8FZG1__root`，
可从上游 [Root-My-Galaxy-Payloads](https://github.com/BuSung-dev/Root-My-Galaxy-Payloads) 获取，Apache-2.0）。
真机验证清单见 [VERIFY.md](VERIFY.md)。

## 已知构建坑（均已在本仓库修复）

1. **5.15 无 `enum rlimit_type`**（5.16+ 才引入）：补丁内 typedef 用 `int`（ABI 等价），
   否则新 DDK 镜像的 `-Werror=visibility` 会挂。
2. **`Kernel-SU` GitHub org 已删除**：ksud 的 git 依赖（adb_client / java-properties /
   ksu_props / rustix）需改写为 `ReSukiSU/` 镜像（revision 已验证一致），workflow 内自动处理。
3. **cc-rs 需要 NDK**：NDK bin 加入 PATH + `CC_aarch64_linux_android` + 裸
   `aarch64-linux-android-clang` 符号链接。
4. **ksud 产物位置**：cargo workspace 根的 `target/`，不是 `userspace/ksud/target/`
   （本地构建脚本已按此收集）。
5. **不要 `llvm-strip -s` 模块**：加载器读取 `.symtab`，只允许 `-d`（strip debug）。

## 参考构建结果（2026-09-21，GitHub Actions run 35562312156）

| 产物 | 大小 | md5 |
|---|---|---|
| `android13-5.15_kernelsu-dm3q-S9180ZHS8FZG1-330.ko` | 399,528 | `2bbddfc844d87ee2210ce361a35092c5` |
| `ksud-dm3q-S9180ZHS8FZG1-330-kdp`（含 --ephemeral） | 4,996,008 | `1e909d3f60f77c2739d079f80ad33724` |

验证要点：vermagic 精确匹配目标固件；`__versions` 0 条目；`do_get_info` 内
`movz x8,#0x7f59`(32601) 为 v3.3.0 真实代码；ksud 内嵌模块与 .ko 逐字节一致。
