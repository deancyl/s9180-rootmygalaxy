# 常见问题

## 模块显示「已停止」

临时 root 会随**完整重启**失效。重新跑一次 exploit，然后：

```sh
su -c 'sh /data/adb/modules/rmg_memtonic/service.sh'
```

## WebUI 空白 / 仍是旧界面

1. **KernelSU 管理器会缓存旧 HTML**：把 Manager 从最近任务里划掉，再重新打开。
2. 核对版本：`su -c 'grep ^version= /data/adb/modules/rmg_memtonic/module.prop'`
3. 新版首屏应显示三个胶囊：**保护 4/4 / 权限 正常 / 版本 vX.Y.Z**。看不到胶囊说明加载的还是旧文件。

## 一直显示「禁止重启」

表示存在 staged rollback（`/data/rollback/*/rollback.json` 中 `state: enabling`）。此时重启可能触发完整重启并**丢失临时 root**。

这不是模块故障，而是它按安全铁律在提醒你：先确认系统更新/回滚状态，再决定是否重启。

## 内存条显示「正常」但手机很卡

看两个地方：
- **内存压力**：`some/full` 两个百分比，≥30% 会标红；
- **已做的保护**：`N / 14` 表示 14 类保护里有几类真的动过手；点开「保护记录」可看每类次数。

如果两者都低，卡顿更可能来自换页风暴或单个应用自身，而不是系统内存危机。

## 出现「建议由你手动重启一次」

表示堆处于高位且两次清理都无效（真泄漏特征）。**模块不会代执行重启**——请自行判断时机，并先确认没有 staged rollback。

## 软重启后模块还在吗

在。framework 软重启不会杀掉模块守护进程。判断依据：`uptime` 连续（`cat /proc/uptime`），且四守护 pid 不变。

## 怎么知道模块到底做了什么

- WebUI →「保护记录」：14 类动作的累计次数与口径
- WebUI →「最近记录」：内存异常快照与系统重启记录（时间/类型/原因）
- 完整审计日志：`/data/adb/modules/rmg_memtonic/run/memtonic.log`

## 关掉 WebUI 会自动刷新吗

不会。WebUI 只在页面可见时每 30 秒读取一次状态；`drop_caches`、trim 等动作由守护进程独立执行，与页面是否打开无关。

## 升级后还需要重新获取 root 吗

升级模块不需要。只有**完整重启**（含系统更新）才会丢临时 root，需要在开机后重新 exploit。
