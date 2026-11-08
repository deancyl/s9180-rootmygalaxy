FR-RN1 首次成功启用：根因是降权循环对 181–221 个线程逐个 renice（约 600 fork/轮），改为按 nice 分桶批量调用（toybox renice 支持多 PID，实机验证）后，cpu_scan 从 1460–3840ms 降到 520–710ms，5 轮验收 0 bad。

本版同时包含 v1.13.16 的三项修复（stop/uninstall 还原完整性、nice_of/Tgid/adj/pidof 零 fork、探测门控补 RSS 短时斜率）——两者在同一提交，故 v1.13.16 不单独发版。

验证：单测 253/253；设备 v1.13.17/vc57；FR-RN1 在役（161 线程中 31 个降权）；四守护存活、uptime 连续。

附件含 MemTonic-v1.13.17.zip 与前置 APK。
