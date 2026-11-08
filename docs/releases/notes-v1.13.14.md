FR-SS 六项硬化（源自 11-07 第四起 `HeapFull 501MB` 取证）+ WebUI 时效化与 CSS 误伤修复。

**根因铁证**：当日 `ss_heap_relief` 尝试 22 次**全部失败**、`ss_heap_trim` **全天 0 次成功**——唯一泄压手段 `am send-trim-memory` 走 binder 到 system_server，堆濒死时必然不可达。

**FR-SS 六项（均在安全底线内）**
- **内核路径兜底 `ss_drop_caches`**：`am` 全失败后写 `/proc/sys/vm/drop_caches`（不经过 framework，确定可达）；限流 10 分钟 1 次、1 小时≤6 次；只回收 page cache / dentry / inode，不触碰 Java 堆、不动 zram、不改持久内核参数。
- **`am` 单轮重试 ×3**：立即 / +4s / +8s（总阻塞 ≤8s），失败必走内核兜底；复测间隔 120s→30s。
- **阈值前移**：430MB 预备态 / 450MB 完整泄压链 / 460MB GC 加速 / 470MB 告警 / 480MB 极限压制；496MB 仅作 OOM 参考线。
- **GC 加速加强**：nice -10→**-15**，并尝试 `taskset` 绑大核（cpu5-7，失败静默降级）；还原用 delta renice + `taskset -p ff` 恢复亲和。
- **趋势判定**：撤销建议由「单点 <450MB」改为「连续 3 次探测 <430MB」，消除高位震荡下的建议抖动。
- **抑制态→极限压制**：检测到 `reboot_suppressed.flag`（有 staged rollback 不能重启）时，探测加密到 60s，每轮叠加 am 重试 + drop_caches + GC 提权。

**WebUI**
- **flag 时效化**：数据源为每个 flag 追加 `_mtime`，超 24h 的历史提示降级进「技术细节」，不再永久占据首屏告警位（11-06 的 `boot_context.flag` 一直存在，旧实现「存在即告警」）。
- **ⓘ 弹层**点弹层外任意处即关闭；**禁用按钮**写明原因（保护运行中无需重复开启）。
- **修复 CSS 特异性 bug**：`.quick button` / `.oprow button` / `.advbtns button` 误伤圆形 ⓘ（被拉成椭圆且点击错位），全部改为子选择器。
- 阈值刻度同步为 `450 清理 / 460 加速 / 470 告警 / 496 危险`。

**验证**：单测 231/231；8 步部署全绿（`cpu_scan=140ms`、四守护新 pid、`uptime` 连续、未重启系统）；设备读回 `mt_lib.sh` / `index.html` 与本地源逐字节一致；390px 实渲染确认告警只剩「内存很吃紧（刚刚）」「重启建议已被按住（2 小时前）」。

**诚实边界**：system_server 堆泄漏发生在框架内部，用户态手段只能延后与缓解，**不能承诺不再发生**；本次把「几乎无干预」变为「有 30–60 分钟窗口 + 一条可达泄压路径」。真正根治需要系统侧行为改变（深夜 AOD 人脸 / face-service 借相机）。

附件含 `MemTonic-v1.13.14.zip` 与前置 RootMyGalaxy APK（`rootmygalaxy-0.2.36-ksu331.apk`，内嵌 KernelSU v3.3.1，`sha256 b0bd6b5c…fa167`）。安装前请先完成一次临时 root。

