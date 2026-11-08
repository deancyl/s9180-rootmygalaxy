FR-RN1 零 fork 修复 + WebUI P2 四项 + RayNeo 语音链路削峰豁免。

**P2-A 零 fork 修复**
- `rayneo_memo_active()` 与降权循环的 `$(cat comm)` 改为 mksh 内建 `IFS= read -r`（复用 v1.13.2 耗电治理已验证范式）。
- A/B 铁证：恢复旁路 flag 后 `cpu_scan` 从 1770–13010ms 回落到 210–220ms，而 CPU PSI 未同步下降 → 根因确认为每轮约 181 次 `cat` fork。

**WebUI P2 四项**
- HAL tombstone 累计/最近计数（只读文件名统计，不解压）。
- incident 快照摘要（时间 + `reason=`）。
- 「重启守护」按钮（二次确认 + 基线污染提示 + 失败兜底）。
- 自动刷新 15s→30s（省一半 shell 调用）。

**WebUI 审查后 3 项修复**
- 时间值统一格式化（epoch 秒 / 原始文件名 → `MM-DD HH:MM`）。
- 堆危机刻度改 flex 图例（原标签与刻度线错位）。
- 第二次 exec 失败/分段异常不再静默降级（补 errno 与 11 段守卫提示）。

**RayNeo 语音链路削峰豁免**
- 启动风暴窗口内 `renice_tree` 原会把 RayNeo 整进程（含音频采集 / ASR / 网络回调线程）压到 nice+5，实测 `deprioritize_rayneo=1`。
- 在削峰路径新增 `com.rayneo.venus.pub*` 专用豁免与 `act=voice_asr_skip` 审计日志；**不修改全局 `WHITELIST_PKGS`**（它还被 FR-4 毒瘤降权与 optimize 共用），豁免面最小。

**验证**：单测 142/142；全部脚本 `sh -n` 通过；9 步部署（md5 双检 → 备份 → 原子替换 → 单次重启 → 5 轮 `cpu_scan<300ms` 验收 + 自动回滚）。

**诚实边界（重要）**：P2-A 只覆盖 memo 探针与 comm 读取两处；demote 名单在役时仍有逐 tid fork（Tgid 校验 `awk`、`nice_of`、眼镜探针 `cat`），本版验收 0/5 后 `AUTO_ROLLBACK` 按设计恢复旁路 flag，稳态 `cpu_scan` 190–230ms。**FR-RN1 治理仍处旁路态**，第二轮零 fork 化另行评估。

附件含 `MemTonic-v1.13.13.zip` 与前置 RootMyGalaxy APK（`rootmygalaxy-0.2.36-ksu331.apk`，内嵌 KernelSU v3.3.1，`sha256 b0bd6b5c…fa167`）。安装前请先完成一次临时 root。

