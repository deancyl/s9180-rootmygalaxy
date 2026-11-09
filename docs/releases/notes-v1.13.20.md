外部复核收尾热修 + **FR-4 毒瘤检测全面恢复与全链路零 fork 极速重构**。

在 v1.13.19 发布的「诚实边界」中，我们确认了 FR-4「CPU 毒瘤检测」自 v1.9.9 起因 `snapshot_app_pids()` 恒空而从未实际执行。本版正式攻克该历史缺陷，并在开启整机约 95 个应用进程全量真实扫描的背景下，通过全链路零 fork 重构，首次达成 **`cpu_scan` 稳态压入 300ms 预算（实测平均 263ms）**。

## 关键修复与性能攻坚

**① 攻克历史遗留 P0：FR-4 CPU 毒瘤检测根因修复（`cpu_guard.sh`）**

- **根因分析**：自 v1.9.9 以来，`snapshot_app_pids()` 的 awk 实现中 `FNR==1` 从未给 `pid` 变量赋值，**且**逻辑依赖 `/proc/<pid>/status` 尾部的空行 `^$` 进行输出（Linux/Android 内核 status 文件末尾无空行）。两个缺陷叠加导致该函数输出恒为空，`scan_cpu_rogue` 外层循环从未执行过。
- **修复方案**：`FNR==1 { split(FILENAME, p, "/"); pid=p[3] }`，匹配到 `^Uid:` 且 `$2 >= 10000` 时输出 `pid` 并立即 `nextfile`，实测提取 95 个应用仅需 **80ms**。

**② snapshot_app_ticks 单次批量采集（`cpu_guard.sh`）**

- 恢复真实应用扫描后，若采用逐进程 `cpu_ticks_of "$pid"`，每轮将产生 95 次 awk 子进程 fork（95 × 18ms ≈ 1700ms 严重拥堵）。
- 重构为单次 awk 扫描 `status`，仅对 `Uid >= 10000` 的应用进程通过 `getline` 读取对应 `stat` 的 `utime+stime`，**1 次 fork 90ms 一网打尽**。

**③ 核心辅助函数全链路零 fork 化与一级缓存**

- **`pkg_of()` 零 fork 化**（`mt_lib.sh`）：由 `strings | head | cut`（3 次 fork ≈ 15ms）改用 `mksh` 内建 `IFS= read -r` 读 `/proc/<pid>/cmdline`；并在 `cpu_guard.sh` 中对 `_pkg_${pid}` 引入一级包名缓存，活跃进程无需每轮重复查询。
- **`is_in_top_app_cgroup()` 零 fork 化**（`mt_lib.sh`）：由 `$(cat /proc/$1/cpuset)` 改为内建 `read`，完全消除子 shell。
- **`nice_of()` 零子 shell**（`mt_lib.sh`）：同步设置 `_nice_val` 变量，内部调用免除 `$(nice_of)` 命令替换子 shell。
- **`rayneo_governor` 死条目清洗**（`cpu_guard.sh`）：由原本每轮 2400+ 次 Shell read 读 60 行文件重构为单次 awk 快速过滤，清洗耗时由 **200ms 骤降至 5ms**。

**④ 作用域与环境细节修复（P0 / KSU 规范）**

- **`RAYNEO_PKG` 作用域修复**（`mt_lib.sh`）：将包名常量上移至 `mt_lib.sh` 顶部全局常量区，修复 `restore_all_on_exit` 无法读取雷鸟 PID 导致 stop/uninstall 100% 跳过雷鸟线程还原的缺陷。
- **补齐 `KSU_MODULE` 环境变量**（`mt_lib.sh`）：`update_module_desc` 调用 `ksud module config set` 时显式注入 `KSU_MODULE=rmg_memtonic`，确保手动 Shell 与 WebUI 刷新时卡片覆盖层设置成功。
- **消除硬编码版本**：`memtonic.sh` 与 `fluency_shield.sh` 启动日志中的 `ver=1.13.18` 改为动态 `${MT_VERSION#v}`；同步更新 `fluency_shield.sh` 头部版本。
- **清理调试残留**：移除发布包内的 `.bak-1319-pre/`、`.t/` 目录与 `scripts/zz_probe.sh`；移除 `cpu_guard.sh` 内重复的 `RAYNEO_PKG`。
- **KernelSU WebUI 权限隔离规范**（`customize.sh`）：遵循官方规范，移除顶层递归权限覆盖，绝不触碰 `webroot` 目录及其 SELinux 标签。
- **PID 复用换皮与死线程缓存泄漏修复**（`cpu_guard.sh`）：在 `delta < 0` 时清除旧状态与 `_pkg_`；对 `delta > 0` 的活跃进程实时校验包名，包名变动时立即重置状态；死线程清理补齐 `unset _pkg_${tid}`。
- **pkg_of NUL 字节截断重构**（`mt_lib.sh`）：改用 `read -r -d ''` 截断 `/proc/<pid>/cmdline` 首段参数并设计零 fork fallback，规避多参数拼接风险。
- **启动冗余扫描剥离**（`cpu_guard.sh`）：移除 L806-807 无用的 `snapshot_app_pids` 调用，直接调用 `take_ticks_snapshot`。
- **子守护防孤儿化探活加固**（`mt_lib.sh` / 三大子守护）：新增 `main_daemon_alive()` 零 fork 探活函数，淘汰 `kill -0 "$PPID"`，彻底消除 `child_heal` 重拉后脱钩 `PPID=1` 的失控孤儿隐患。
- **零子 shell 活跃包名内建提取**（`cpu_guard.sh`）：将活跃进程扫描由 `$(pkg_of)` 改为内建直接读取，杜绝子进程 fork，实测 90 次调用耗时由 700ms 降至 60ms（提速 11.6 倍）。
- **非阻塞平滑 `restart` 重构**（`memtonic.sh`）：由 `exec sh "$0"` 改为调用 `service.sh` 异步解耦退出，彻底防止调用方挂死。

## 验证与性能实测数据

- **单测与断言套件**：6 项真机断言 **100% 全部通过**（`RAYNEO_PKG` 存在、`MT_VERSION` 正常、`snapshot_app_pids` 正确输出 96 个 UID≥10000 进程、`snapshot_app_ticks` 格式准确、`pkg_of` 零 fork 解析无误、连续 5 轮耗时达标）。
- **真机 5 轮连续 `cpu_scan` 耗时压测（Samsung SM-S9180 实测）**：
  - 第 1 轮（首次包名加载 + 雷鸟建表）：384ms
  - 第 2 轮：299ms
  - 第 3 轮：131ms
  - 第 4 轮：269ms
  - 第 5 轮：233ms
  - **5 轮平均耗时：263ms**（稳态达标率 100%），开启全量应用真实扫描后稳稳压入 300ms 性能预算之内。
- **版本一致性校验（memtonic_version_check）**：
  - `module.prop` 声明：`version=v1.13.20`、`versionCode=60`
  - 启动日志回显：`event=start ver=1.13.20` 与 `event=fluency_shield_start ver=1.13.20` 完全一致。
  - `collect_stats` 正常输出，四守护进程稳定常驻。

附件含 `MemTonic-v1.13.20.zip` 与配套前置 `rootmygalaxy-0.2.36-ksu331.apk`。已装 v1.13.19 可直接通过 KernelSU 管理器刷入热安装更新。
