# 2026-11-08 开发进度同步核查

> 触发：用户要求「同步一次开发进度至 github」。
> 性质：**纯文档 / 发布状态同步，零模块代码改动**。设备侧未做任何操作，不重启、不刷写、不触碰 root 会话。
> 范围：核对本地开发基线 → 仓库 → 远端 tag/release 的一致性，补齐尚未版本化的进度材料，修正发布状态不一致。

---

## 一、同步前核查结论

| 核查项 | 结果 |
|---|---|
| 分支与提交 | `main`；`HEAD == origin/main == 7cff1b1`，代码与文档已全部推送 |
| 未跟踪文件 | `.zipref/`（约 87MB 发版缓存）、`MemTonic-v1.12.9.zip`（84KB）。均为本地构建 / 参考归档，非源码 |
| 模块代码一致性 | 仓库 `modules/rmg_memtonic/` 的 7 个关键文件 md5 与本地开发基线**逐字节一致** |
| tag | `v1.13.12 / 13 / 14 / 15 / 17 / 18` 均已推送，均为 annotated tag |
| release | 上述 6 个 tag 均有对应 release 与附件 |

### 模块代码指纹对照（同步前，仓库 vs 开发基线）

| 文件 | md5 |
|---|---|
| `module.prop` | `f3d10327ee5dd422971fb4c15c62672c` |
| `webroot/index.html` | `f6208f102817c754a1ec3818ce5ac6fe` |
| `scripts/mt_lib.sh` | `7ab64dcda025932460867b31ec8bc1d5` |
| `scripts/cpu_guard.sh` | `34817b53aeab34edf4c0058fac1c3931` |
| `scripts/fluency_shield.sh` | `27b64f21410b2c4b0888bab2c0b1c989` |
| `scripts/memtonic.sh` | `42b71170346011065d1729ff8ececd90` |
| `uninstall.sh` | `1a98317ec50f8e0fe409b1b624278a06` |

`module.prop`：`version=v1.13.18` / `versionCode=58`。

---

## 二、发现并修正的两个不一致

### 1. Latest 标记错位（真实状态错误）

- **现象**：`gh release list` 显示 `v1.13.17` 带 `Latest`，`v1.13.18` 不带；而 README、模块 README、wiki 版本记录均按 v1.13.18 为最新版描述。
- **原因**：`v1.13.18` 创建于 `08:21:12Z`，`v1.13.17` 是随后 `08:27:19Z` **补发**的历史版本，GitHub 默认把「最后创建的 release」自动标为 Latest。属补发顺序造成的标记漂移，不是发版内容错误。
- **修正**：`gh release edit v1.13.18 --latest`；复核后 `Latest` 已回到 `v1.13.18`。
- **影响面**：仅改发布标记位，不动 tag、不动 commit、不动附件、不动 release 正文；随时可反向改回。

### 2. README 表格标注重复

`v1.13.15` 行仍为「新装首选」，与 `v1.13.18` 行的「新装首选」重复，改为「历史存档」。

---

## 三、本次补齐的版本化材料（纯新增）

| 路径 | 说明 |
|---|---|
| `docs/analysis/MemTonic_v1.13.16_开发部署方案_2026-11-08.md` | 11.2KB 方案文档（8 项需求矩阵 / 12 项已知问题 / A–D 四阶段 / 7 项风险 / 逐目标验证方法），此前仅存于本地分析目录 |
| `docs/releases/notes-v1.13.12.md` ~ `notes-v1.13.18.md` | 6 份 Release 说明，**直接从线上 release 正文导出**，含此前缺归档的 `v1.13.17`；不重写、不美化 |
| `docs/progress/2026-11-08-sync-checkpoint.md` | 本文件 |
| `.gitignore` | 排除 `/.zipref/` 与根目录 `/*.zip`，避免 87MB 本地缓存误提交；**只忽略，不删除任何本地文件** |
| `README.md` | 文档索引新增 `docs/releases/` 与方案文档入口；修正 v1.13.15 标注 |

**脱敏**：全部新增文档已扫描，无设备序列号、无本地盘符路径、无 adb 序列号。

> `v1.13.16` 仍不单独发 tag / release：它与 `v1.13.17` 位于同一提交 `b7451b9`，没有可还原的独立快照，不伪造归档。`v1.13.0 ~ v1.13.11` 同理。

---

## 四、同步后状态

| 项 | 值 |
|---|---|
| 设备运行版本 | `v1.13.18 / vc58`（本次未改动设备） |
| WebUI | 健康分首屏，`f6208f10…` |
| 单测 | 266 / 266（v1.13.18 部署时结果） |
| 四守护 | 存活，uptime 连续 |
| Latest release | **v1.13.18**（已修正） |
| 仓库状态 | `HEAD == origin/main`，工作区干净 |
| 本次提交 | 纯文档同步，不含代码 diff |

---

## 五、诚实边界：仍未闭环的 6 项

| ID | 遗留项 | 当前状态 / 下一步 |
|---|---|---|
| L1 | `cpu_scan` 实测 340–730ms，未达方案 300ms 目标 | 已知瓶颈：`rayneo_memo_active` 与降权循环**各遍历 161 个线程一次**（约 322 次 `/proc` 读取），可合并为单次遍历；尚未实施 |
| L2 | `drop_caches` 至今未实弹触发 | 堆未达 450MB 阈值；首次真实高压需量化 `MemFree` / `pgsteal_kswapd` 前后差值与 IO 抖动 |
| L3 | 整机容量层压力 | 物理内存高位、swap 约 6.8GB、CPU PSI 约 20%、compaction 失败率高；用户已选择「不动系统设置（保守）」，**OOM 风险不因模块版本改变** |
| L4 | NoActive 无自动健康检查 | 已验证注入有效（软重启后 6 秒重新注入 system_server）、frozen 约 108；读 verbose 日志成本高于收益，待低成本 marker 方案 |
| L5 | GitHub Wiki 网页仓库未初始化 | 源页已版本化在 `docs/wiki/`；需先在网页端创建首页，再运行 `docs/wiki/sync.sh` |
| L6 | KernelSU Manager 可能缓存旧 WebUI | 用户需在管理器中关闭并重新打开模块页面刷新 HTML |

---

## 六、验证清单

```sh
git status --short                      # 应为空
git rev-parse HEAD origin/main          # 两个值应相同
gh release list --limit 3               # v1.13.18 应带 Latest
md5sum modules/rmg_memtonic/{module.prop,webroot/index.html,scripts/*.sh,uninstall.sh}
                                        # 应与本文件第一节指纹表一致
```

**底线不变**：不杀进程、不冻结、不动 zram、不持久改内核参数、不刷写分区、不代执行重启、nice 只提不降；本次同步未触碰设备。
