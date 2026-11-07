# 安全边界与工作原理

## 会做什么

- **只读观测**：`/proc` 采样、`dumpsys meminfo` 单次快照（判定与快照共用同一份，避免高水位二次 dumpsys）、dropbox 崩溃档案计数
- **逐线程优先级调度**：renice、cpuctl/cpuset 核亲和约束、按压力提权前台渲染与 GC 线程
- **内存泄压**：`am send-trim-memory`（走 framework）；失败时改走内核路径 `echo 3 > /proc/sys/vm/drop_caches`（不经过 framework）
- **取证**：内存危机快照、incident 记录、完整审计日志
- **仅限临时 root 会话**：root 失效即自动退出

## 绝不做什么

- 不杀进程、不冻结应用、不动 zram
- 不持久修改内核参数、不刷写任何分区
- **不代为执行任何重启**（软重启/完整重启都只建议，由用户手动决定）
- 不把 `nice ≤ -15` 的既有特权线程反向降级（只提权）
- 不干预正在播放的应用、蓝牙音频、微信实时消息
- 零数据面干预：不改路由、不改 DNS、不碰防火墙规则

## FR-SS 堆危机链（v1.13.14）

```
430MB 预备态        → 探测加密 + 趋势观察（不动手）
450MB 完整泄压链    → am 重试 ×3 → 失败则 drop_caches 兜底
460MB GC 加速       → HeapTaskDaemon/ReferenceQueue/Finalizer 提权 -15 + 尝试绑大核
470MB 告警          → 面板/通知提示
480MB 极限压制      → 全手段叠加 + 每轮强制链
496MB 参考线        → 仅日志口径（系统 OOM 在 ~501MB）
```

抑制态（存在 staged rollback、不能重启）下，探测节奏从 600/1800s 加密到 **60s**，每轮都跑完整链。

## drop_caches 的边界

`echo 3 > /proc/sys/vm/drop_caches` 只回收 **page cache / dentry / inode 等可回收 slab**，不触碰 Java 堆本身。它的价值在于：当 `am`（binder 到 system_server）完全不可达时，这是唯一确定可达的物理页释放路径。

限流：10 分钟最多 1 次、1 小时最多 6 次，避免 IO 抖动。

## 为什么不能根治

system_server 的 Java 堆泄漏发生在**框架内部**，用户态手段无法回收其堆对象。四起同型 OOM（496–501MB @ `Watchdog`）证明存在稳定的内部泄漏源；历史取证指向 face-service（深夜 AOD 人脸）持续借相机 → GC 饿死 → 堆满。

模块能做的是：
1. 更早介入（阈值前移 30–50MB）
2. 更可靠地泄压（不依赖 framework 的兜底路径）
3. 更真实地记录（快照 + 建议，不代执行）

**真正根治需要系统侧行为改变**（关闭深夜 AOD 人脸/面部服务，或等厂商修复），这属于用户在系统设置层面的选择。
