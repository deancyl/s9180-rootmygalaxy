外部审计 9 项修复 + 生命周期收口。**不改变任何阈值与功能语义**，只修正确性：上一版存在"看起来在工作、实际空转"的确定性缺陷。

## 关键修复

**① Tgid Tab 分隔符（P0，影响 FR-RN1 全部）**

`/proc/<tid>/status` 的 Tgid 行是 `Tgid:\t<pid>`（Tab 分隔），而代码写了 `IFS=' '`——显式空格 IFS 不拆 Tab，`_tk` 恒不等于 `Tgid:`，`_tg` 恒空。后果：

- `rayneo_restore_all` **100% 返回 `restored=0`**（日志里 12 次全是 0）
- 死条目清理每轮把 `RN_STATE` 清空 → 已降权线程"失忆" → **每分钟全量重复降权**（`rayneo_demote_batch` 累计 739+）

真机新旧并排对比（同一批真实线程）：

```
tid=10343  old=[]  new=[19615]
tid=12128  old=[]  new=[19615]
tid=13551  old=[]  new=[19615]
tid=14495  old=[]  new=[19615]
```

修复后在真实代码路径上验证：写入 3 条状态 → `act=rayneo_restore restored=3`（写入多少还原多少）。

**② cpuset 只迁主线程（P0）** — `/dev/cpuset/*/tasks` 按线程写，写 tgid 只迁主线程，渲染/解码/网络池线程全留在 foreground。改 `cgroup.procs` 按线程组整迁，stop/uninstall 同步。

**③ 卸载不终止子进程（P0）** — `uninstall.sh` 的 `pkill` 数是 **0**，只 kill 两个 pid 文件；随后 `rm -rf run` 又把 pid 文件和还原清单全删了。`cpu_guard` / `fluency_shield` / `vk_injector` 会变孤儿、无法再 stop、改动无法还原。补 4 条 `pkill`，并把清场移到删目录之前。

**④ `service.sh` 漏看子进程** — 幂等判断只看 `memtonic.pid`。主进程异常死亡后重拉会产生双份 `cpu_guard` 并发 renice。异常终止（pid 文件在、进程不在）先清场再拉起。

**⑤ `renice -n` 是增量不是绝对值** — 真机探针确认 `before=0 → mid=5 → after=0`。所以 `rogue_throttle` 的 `-n 10` 会把 nice=5 的线程推到 15；SurfaceFlinger 提权的 `-n -15` 会在已提权的 SF 上叠成 **-25**。改为 delta 换算到目标值，并补 `> -15` 守卫。护盾提权同时落盘 `run/shield_fg.bak`，`sleep 15` 期间被 kill -9 也能还原。

**⑥ `mem_forecast` 旧值导致误压实（P1）** — 预测态只在首次写 flag，`avail_kb` 永久冻结。真机 08:06 写入 1.38GB，10:39/11:10 实际已回到 1.9–2.4GB 仍触发亮屏压实。改为持续刷新 + 判定读实时 `MemAvailable`，并要求亮屏时 mem PSI ≥10。

**⑦ 减负与健壮性** — `am send-trim-memory` 加 `timeout 2`（缺失自动降级）；`dumpsys rollback` 单次采集 60s 复用（省 3–5 次 binder）；`collect_stats` 14 次 `grep -c` 合单次 awk（键名与顺序不变）；`is_frozen_pid` 让削峰跳过 NoActive 冻结进程；护盾息屏降频（跳过 10s 焦点采样与截屏目录扫描）；`child_heal` 子守护自愈（pid 存活时零 fork）。

**⑧ KernelSU 规范** — `MODDIR=${0%/*}`；新增 `customize.sh` + `hotinstall.sh`（`MODULE_HOT_INSTALL_REQUEST`），刷 zip 后自动"停旧守护 → 起新守护"；`update_module_desc` 同步 `ksud module config set --temp override.description`。

**⑨ WebUI** — 阈值文案统一到 450 泄压 / 460 GC 加速 / 470 告警 / 496 OOM（GC 提权 -15 绑大核）；修 `healthScore()` 把 470MB 写成 481MB 的比较基数错误（481280KB = 470MB，原代码按 481MB 比）。

## 验证

- 单测 **289/289**；12 个脚本 `sh -n` 全过。
- 真机部署 8 步全绿：探针硬门槛确认 `renice` 为**增量语义**（否则自动中止不部署）→ staging md5 7/7 → 备份 `scripts.bak-1319` / `webroot.bak-1319` → stop 清场后**剩余守护 0** → 原子替换 → 设备 md5 7/7 → 启动四守护 → 特性验收。
- 设备：`v1.13.19 / vc59`，四守护存活、`instances=3` 无重复，`uptime` 连续（约 13 天未重启）。
- 功能确认：FR-9 护盾（微信 psi 6.35%）、Camera Sentinel（53 线程 mask=f8）、Face 借相机（79→44 还原）、BT2（42→37 还原）全部正常闭环。

## 诚实边界

- **`cpu_scan` p50=590ms，未达 300ms 目标**。但也没有恶化：v1.13.18 的验收区间就是 340–730ms，本次 350–600ms 同区间。部署初期看到的 190–270ms 是息屏空载态，不能当稳态基线。实测分解：`snapshot_app_pids` 158ms + `focused_pkg` 60ms + 判定逻辑。
- **🔴 新发现 P0（本版未修）：FR-4「CPU 毒瘤检测」自 v1.9.9 起完全失效。** `snapshot_app_pids()` 的 awk 从未给 `pid` 赋值，**且**依赖 `/proc/<pid>/status` 末尾的空行做分隔（实际没有）——两个缺陷任一都足以让输出恒空。真机实测：原函数输出 **0 行**，日志累计 `cpu_scan` **1349 次**、`cpu_rogue_intervene` **0 次**。也就是说 `scan_cpu_rogue` 的主循环从未执行过，面板上的「毒瘤降权 0」是**从未扫描**而不是「没有毒瘤」。
  已验证的修法：`FNR==1` 用 `split(FILENAME,…)` 取 pid + `/^Uid:/` 行直接判断（95 个进程 / 158ms），ticks 改单次 awk 扫全部 `/proc/*/stat`（990 行 / 85ms，替代逐 pid 的 95×16ms≈1.5s）。
  **不在本版修**的原因：它要改 `take_ticks_snapshot` / `scan_cpu_rogue` 的数据结构，和本次 9 项混在一起将无法归因。建议单独一版（v1.13.20）。
- 整机容量压力（swap 约 7.5GB、CPU PSI 约 20%、compaction 失败率高）属容量级问题，按你的选择未动系统设置；**OOM 风险不因本版改变**。

附件含 `MemTonic-v1.13.19.zip` 与前置 RootMyGalaxy APK（`rootmygalaxy-0.2.36-ksu331.apk`，内嵌 KernelSU v3.3.1，`sha256 b0bd6b5c…fa167`）。升级后可热安装（KernelSU 会调用 `hotinstall.sh` 自动重启守护）；若不生效，手动 `memtonic.sh stop` + `service.sh`。
