# RMG MemTonic Wiki

MemTonic 是配套 **RootMyGalaxy 临时 root 环境**使用的 KernelSU 模块：在临时 root 会话内做内存与异常守护，root 失效即自动停止，不做任何持久化改动。

## 快速导航

| 页面 | 内容 |
|---|---|
| [安装与升级](Installation) | 从零到运行的四步；升级与新代码生效方式 |
| [常见问题](Troubleshooting) | root 丢失、模块不生效、WebUI 空白、软重启、staged rollback |
| [版本记录](Version-History) | 各版本关键变更与缺口说明 |
| [安全边界与工作原理](Architecture) | 模块会做什么、绝不做什么、为什么不能根治 |

## 当前版本

**v1.13.14**（2026-11-08）：FR-SS 六项硬化 + WebUI 时效化与 CSS 修复。详见 [Release](https://github.com/deancyl/s9180-rootmygalaxy/releases/tag/v1.13.14)。

## 一分钟状态自检

```sh
su -c 'sh /data/adb/modules/rmg_memtonic/scripts/memtonic.sh status'
```

或打开 KernelSU 管理器 → 模块 → RMG MemTonic → WebUI。首屏应看到三个状态胶囊：**保护 4/4 / 权限 正常 / 版本 v1.13.14**。

## 一句话定位

它不清理后台、不杀进程、不改系统设置——只做两件事：**按压力调整线程优先级**，以及**在系统内存濒危时尝试泄压并留下取证**。
