#!/system/bin/sh
# vk_injector.sh —— RMG MemTonic 渲染管线监视器 (FR-8, v1.9.7 重写为只读探测)
#
# v1.9.7 破坏性变更（根因修复）：
#   v1.9.6 及之前版本的"全局 Vulkan 注入 + UI 重载 + 无障碍清空回写"被实测证实为
#   线上事故的直接元凶之一：
#   1. debug.hwui.renderer=skiavk 为全局属性，Adreno 740 + Android 16 下引发大规模
#      "Pipeline create failed"（SystemUI/微信/桌面/GKD/KernelSU 管理器均命中，34+ 次）；
#   2. settings 清空→1s→回写会撞上 AMS 初始化窗口，导致无障碍服务永久掉绑
#      （对照实验：拦截本脚本后软重启，GKD/一木记账/Cube 三服务自动绑定成功）；
#   3. kill -9 SystemUI / force-stop 桌面属越界系统干预，防变砖红线不允许。
#   本版本仅做只读监视与一次性告警，不执行任何 setprop / kill / settings / am 操作。

. "$(dirname "$0")/mt_lib.sh"

FLAG="$RUN/vk_injected.flag"
if [ -f "$FLAG" ]; then
  exit 0
fi

# 等待系统完全启动
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 5
done

cur=$(getprop debug.hwui.renderer)
case "$cur" in
  skiavk|vulkan)
    logx W "event=vk_monitor_detect renderer=$cur msg=全局Vulkan渲染激活_曾实测引发Adreno管线创建失败_建议恢复默认渲染后重启"
    ;;
  ""|opengl|skiagl)
    logx I "event=vk_monitor_detect renderer=${cur:-default} msg=渲染管线正常_无需干预"
    ;;
  *)
    logx I "event=vk_monitor_detect renderer=$cur msg=非标准渲染器_仅记录不干预"
    ;;
esac

touch "$FLAG"
exit 0
