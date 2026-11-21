#!/system/bin/sh
# oshare_hook.sh - 互传常开 hook APK 的开机自装（0.4.46）
# 自写 LSPosed 模块“互传常开”（com.nora.osharehook）的 APK 随调度
# 模块打包在 oshare/oshare-hook.apk 里。开机时 service.sh 调一次
# ensure：没装、或已装的 versionCode 低于内置 APK，就 pm install -r
# 装上；已是最新什么都不做（幂等）。结果记调度日志（0.4.47 起互传
# 日志分类退役，ensure 的结果并入主日志）；装失败也只记日志、返回
# 0，绝不影响开机其他流程。APK 文件不存在时整段跳过。
# hook 本身要在 LSPosed 里启用“互传常开”、作用域勾“一加互传”才
# 生效（APK 1.1 起带推荐作用域，启用时会预勾），这一步只能手动，
# customize.sh 安装时有提醒。
# 用法：sh sched/oshare_hook.sh ensure（只读查询用 panel.sh oshare status）
# 日志：内部存储“调度器日志”文件夹/调度日志.log（建不了时回落
# /data/local/tmp；sched_log，带时间戳）

MODDIR="${0%/*}/.."
if [ -n "$SCHED_TEST_MODDIR" ]; then MODDIR="$SCHED_TEST_MODDIR"; fi
# shellcheck disable=SC1091
. "$MODDIR/sched/lib.sh"
# 0.4.47：互传日志分类退役，ensure 结果写主日志（调度日志.log）。
SCHED_LOG_CAT=main

HOOK_PKG="com.nora.osharehook"
HOOK_APK="$MODDIR/oshare/oshare-hook.apk"
# 内置 APK 的 versionCode。APK 升版时同步改这里（当前 APK 是 5，
# versionName 1.4，0.4.56 随模块升的：三层拦 AlarmManager 定时
# 关闭——getSwitchTimeOut 恒 -1、注册闹钟的 q7.e.d() 整体 no-op、
# TimeoutReceiver 只吞 switch.timeout 广播；手动关不受影响）。
# build.sh 结尾会校验这里和清单里的 versionCode 一致，不一致
# 直接构建失败（C10），不会再靠手工同步。
HOOK_APK_VC=5

# hook_installed_vc：已装的 versionCode，没装/dumpsys 不可用输出 0。
hook_installed_vc() {
    command -v dumpsys >/dev/null 2>&1 || { echo 0; return; }
    _vc=$(dumpsys package "$HOOK_PKG" 2>/dev/null | grep 'versionCode=' | head -n 1 | sed 's/.*versionCode=//;s/[^0-9].*//')
    case "$_vc" in ''|*[!0-9]*) _vc=0 ;; esac
    echo "$_vc"
}

oshare_hook_ensure() {
    [ -f "$HOOK_APK" ] || return 0
    _vc=$(hook_installed_vc)
    if [ "$_vc" -ge "$HOOK_APK_VC" ] 2>/dev/null; then
        return 0
    fi
    if ! command -v pm >/dev/null 2>&1; then
        sched_log "WARN oshare-hook: pm 不可用，跳过 hook APK 安装"
        return 0
    fi
    _out=$(pm install -r "$HOOK_APK" 2>&1)
    _rc=$?
    if [ "$_rc" = "0" ]; then
        sched_log "OK oshare-hook: hook APK 已安装（$HOOK_PKG vc$HOOK_APK_VC，原 vc=$_vc）"
    else
        _flat=$(printf '%s' "$_out" | tr '\n' ' ' 2>/dev/null)
        _flat=$(printf '%.200s' "$_flat")
        sched_log "FAIL oshare-hook: hook APK 安装失败 rc=$_rc out='$_flat'"
    fi
    return 0
}

case "${1:-ensure}" in
    ensure) oshare_hook_ensure ;;
    *) echo "用法: oshare_hook.sh ensure"; exit 2 ;;
esac
