#!/system/bin/sh
# RMG MemTonic KernelSU Action Script
# 点击 KernelSU 管理器卡片中的【执行】按钮时呼出

MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR="/data/adb/modules/rmg_memtonic"

echo "=========================================="
echo "  RMG MemTonic 内存与异常守护 v2.0.3"
echo "=========================================="
echo ""

echo "[1] 守护进程状态:"
for _pair in "memtonic:memtonic.pid:memtonic.sh" "fluency_shield:fluencyshield.pid:fluency_shield.sh"; do
  _name=${_pair%%:*}
  _rest=${_pair#*:}
  _pf=${_rest%%:*}
  _pat=${_rest#*:}
  _p=$(cat "$MODDIR/run/$_pf" 2>/dev/null); _p=${_p%%:*}
  if [ -n "$_p" ] && [ -d "/proc/$_p" ] && grep -q "$_pat" "/proc/$_p/cmdline" 2>/dev/null; then
    echo "  * $_name: 运行中 (PID $_p)"
  else
    echo "  * $_name: 未运行"
  fi
done
echo ""

echo "[2] 内存与系统指标:"
avail=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
swap_t=$(awk '/^SwapTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
swap_f=$(awk '/^SwapFree:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
echo "  * 可用内存: ${avail:-NA} MB"
if [ -n "$swap_t" ] && [ -n "$swap_f" ]; then
  echo "  * Swap已用: $((swap_t - swap_f)) MB / ${swap_t} MB"
fi

ss_pid=$(pidof system_server); ss_pid=${ss_pid%% *}
if [ -n "$ss_pid" ]; then
  ss_heap=$(awk '
    /^[0-9a-f]+-[0-9a-f]+ / {
      in_j = ($0 ~ /\[anon:dalvik-(main space|.*large object space|non moving space|zygote space)\]/)
    }
    in_j && /^Pss:/ { p += $2 }
    in_j && /^SwapPss:/ { s += $2 }
    END { print int((p + s + 0)/1024) }
  ' "/proc/$ss_pid/smaps" 2>/dev/null)
  echo "  * system_server Dalvik堆: ${ss_heap:-NA} MB (PID $ss_pid)"
fi
echo ""

echo "[3] VM 内核参数 (三星 S9180 原生基线):"
echo "  * watermark_scale_factor: $(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null)"
echo "  * swappiness: $(cat /proc/sys/vm/swappiness 2>/dev/null)"
echo "  * page-cluster: $(cat /proc/sys/vm/page-cluster 2>/dev/null)"
echo ""

echo "[4] 最近运行日志 (最近 6 条):"
tail -n 6 "$MODDIR/run/memtonic.log" 2>/dev/null
echo ""

echo "=========================================="
echo "如需深度图形化监控与调控，请点击卡片上的【<> WebUI】按钮进入面板"
