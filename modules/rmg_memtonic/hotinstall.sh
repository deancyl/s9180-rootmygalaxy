#!/system/bin/sh
# RMG MemTonic v1.13.19 —— KernelSU 热安装钩子
# 由 ksud 在模块文件已就位后调用。此时旧守护仍在用旧代码运行，必须先清场再拉起；
# stop 会还原全部 renice / cpuset 改动，不留残局。
# 失败安全：任一步缺失或失败都不影响模块文件本身，下次 root 会话由 service.sh 兜底。

MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR=/data/adb/modules/rmg_memtonic

if [ -f "$MODDIR/scripts/memtonic.sh" ]; then
  sh "$MODDIR/scripts/memtonic.sh" stop >/dev/null 2>&1
  sleep 1
fi
[ -f "$MODDIR/service.sh" ] && sh "$MODDIR/service.sh" >/dev/null 2>&1
exit 0
