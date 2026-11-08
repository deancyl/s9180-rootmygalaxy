FR-RN1 雷鸟治理五缺陷修复（源自 11-04 代码审计 + memo 激活实测）+ WebUI P0/P1 一致性补强。

**五缺陷修复**
- **P0-1 tid 复用误伤防护**：`rayneo_restore_all` 与死条目清理逐条加 Tgid 归属校验（`/proc/<tid>/status` 的 Tgid 必须等于当前 RayNeo pid；Tgid 不在 stat 文件中）。tid 是全局递增可复用资源，仅存在性检查的 renice 会误伤无关线程。
- **P0-2 眼镜活跃判据重构**：手机屏幕焦点 ≠ 眼镜使用状态（投屏场景焦点是 NotificationShade）。改用 `/proc/<rpid>/oom_score_adj ≤300` 探针，零 dumpsys 成本；失败方向＝漏治理不误伤。
- **P1-3 风暴期 governor 可达**：原挂载点在扫描尾部，主循环 STORM continue 会整轮跳过 → 风暴期连还原都不可达。STORM 分支改为轻量调用（判活/还原/死条目清理可达，不新增降权）。
- **P1-4 双路径清场**：`cpu_guard` 退出路径与 `memtonic.sh stop` 兜底都补 FR-RN1 还原，带同语义 Tgid 校验。
- **P1-5 memo 激活门控**：`AlwaysOnAiRunti` VAD 线程存在即全天智记运行中，不做降权。

**WebUI P0/P1 一致性**
- 堆危机可视化：Java Heap 当前值 + 460/480/485/496MB 阈值刻度与水位判定。
- 状态与约束透明：版本/vc、四守护、root、FR-RN1 旁路、staged rollback enabling。
- 5 张能力计数卡（`collect_stats` 追加 flush/gcboost/ssprobe/forecast/bt3）。
- 建议横幅按 `reason=` 三套文案；start 幂等状态机与异常横幅；软重启文案统一为「倒数第二手段 · 模块绝不代执行」。

**验证**：单测 43/43 + 114/114；7 步部署全绿、零守护重启；`collect_stats` 五个新字段与日志直数 5/5 MATCH。

**诚实边界**：FR-RN1 治理上限约 8–10%（实测大头为 spdy-0 / ACCS0 / process-memory 等不可触碰线程）；堆高危时仍只建议、不代执行重启。

附件含 `MemTonic-v1.13.12.zip` 与前置 RootMyGalaxy APK（`rootmygalaxy-0.2.36-ksu331.apk`，内嵌 KernelSU v3.3.1，`sha256 b0bd6b5c…fa167`）。安装前请先完成一次临时 root。

