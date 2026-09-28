# 事故记录：rollback_staged_install 硬重启（2026-09-28 14:36）与 v1.4.2 热修

## 时间线（全部证据取自设备实机）

| 时刻 | 事件 | 证据 |
|---|---|---|
| 14:34:57 | 用户执行 KSU 软重启（框架重启，ss 14643→16265），MemTonic 护栏开窗削峰 | memtonic.log `storm_start reason=soft_reboot` |
| 14:35:35–14:36:25 | 风暴 PSI cpu 48→94.5%，psi_mem 峰值 22%，load1 32 | 设备侧采集器 5s 时序（/sdcard 持久化） |
| 14:36:28 | MemTonic 最后一条削峰日志；此后内核死亡 | memtonic.log 断点 |
| ~14:36:29 | **完整重启**（root 丢失）。bootloader 记录原因 `reboot,rollback_staged_install(vendor.fingerprint-default)` | ro.boot.bootreason + SYSTEM_LAST_KMSG 尾部 |
| 14:37–14:48 | 新开机；Android 回滚管理器在新会话完成 3 个回滚会话 | /data/rollback/ 5 目录（2 个 14:36 + 3 个 14:42） |
| 14:57 | 手动重新临时 root（late-load v3.3.0），MemTonic 随 service 阶段自启 | /proc/modules kernelsu Live |

## 根因结论：与模块无关

- MemTonic 全部脚本 grep 无 reboot 能力（2 处命中均为注释/触发标签）
- 上一个内核临终日志（SYSTEM_LAST_KMSG，三星 dropbox 持久化）**无任何 panic/Oops/BUG 痕迹**，重启走 UEFI ExitBootServices 正常关机路径
- reboot 理由由 bootloader 记录为 Android 框架回滚管理器的暂存安装回滚；/data/rollback/ 下回滚会话目录的时间戳（2 个 14:36、3 个 14:42）与执行过程吻合
- 推断链条：14:34:57 框架重启 → RollbackManagerService 初始化发现待执行的暂存安装回滚 → 执行后要求完整重启 → 14:36:29 发起 reboot。软重启只是恰好触发了此前挂起的回滚

## 事故副产品：抓出 v1.4.1 真实缺陷（v1.4.2 修复）

硬重启打死进行中的窗口后，`STORM_FLAG` 目录在 /data 上跨重启残留 → 新守护误报"窗口活动中"→ 每小时维护被 `maintenance_deferred` **无限期压制**。v1.4.2 在守护启动时清理（该时点旧护栏必已死亡，无竞态）。

## 取证方法备注

- 三星未启用 pstore/ramoops（/sys/fs/pstore 为空）；内核临终日志走 dropbox 的 `SYSTEM_LAST_KMSG_*` 条目
- 设备侧自治采集器（写 /sdcard）在整机死亡前的数据完好留存——PC 侧 adb 采集在设备重启期间全部失败，验证了该设计的必要性
