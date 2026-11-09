# RMG MemTonic v1.13.19 —— KernelSU 安装脚本（由 ksud source 执行）
# 只做两件事：补齐执行权限、声明支持热安装。
# 纪律：不 exit / 不 return / 不写 SKIPUNZIP —— 避免中断管理器自身的安装流程。

command -v ui_print >/dev/null 2>&1 && ui_print "- RMG MemTonic v1.13.19 (vc59)"

PM=${MODPATH:-$MODDIR}
if [ -n "$PM" ] && [ -d "$PM" ]; then
  if command -v set_perm_recursive >/dev/null 2>&1; then
    set_perm_recursive "$PM" 0 0 0755 0644
    set_perm_recursive "$PM/scripts" 0 0 0755 0755
    set_perm "$PM/service.sh" 0 0 0755
    set_perm "$PM/uninstall.sh" 0 0 0755
    set_perm "$PM/customize.sh" 0 0 0755
    set_perm "$PM/hotinstall.sh" 0 0 0755
  else
    chmod 0755 "$PM" "$PM/scripts" 2>/dev/null
    chmod 0755 "$PM"/*.sh "$PM"/scripts/*.sh 2>/dev/null
    chmod 0644 "$PM"/module.prop "$PM"/CHANGELOG.md 2>/dev/null
  fi
fi

# KernelSU 原生热安装：刷入后由 hotinstall.sh 完成「停旧守护 → 起新守护」，无需软重启。
# 管理器未实现该特性时这两个变量被忽略，行为退化为"下次 root 会话生效"，无副作用。
export MODULE_HOT_INSTALL_REQUEST=true
export MODULE_HOT_RUN_SCRIPT=hotinstall.sh
