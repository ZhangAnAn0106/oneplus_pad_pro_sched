#!/system/bin/sh
# uninstall.sh - 卸载时运行
# sysfs / cpuset / uclamp 的改动本来就不持久，重启即恢复，这里清的是
# 持久态。顺序：先杀 watch、再卸去温控（模块目录还在才能调
# thermal.sh）、最后删状态/备份/pid 文件。日志文件可留。
export PATH=/system/bin:/sbin:$PATH
case "${0%/*}" in
    "$0") MODDIR="." ;;
    *) MODDIR="${0%/*}" ;;
esac
if [ -n "${SCHED_TEST_ROOT:-}" ]; then _td="$SCHED_TEST_ROOT"; else _td="/data/local/tmp"; fi

# 1. 按 pidfile 杀 watch（模块目录删掉后 watch 还在跑会继续切模式、绑核）
if [ -f "$_td/oneplus_thread_watch.pid" ]; then
    _wpid=$(cat "$_td/oneplus_thread_watch.pid" 2>/dev/null | tr -d ' \t\r\n')
    case "$_wpid" in
        ''|*[!0-9]*) : ;;
        *) kill "$_wpid" 2>/dev/null || true ;;
    esac
    rm -f "$_td/oneplus_thread_watch.pid" 2>/dev/null || true
fi

# 2. 去温控：卸掉 9 个 bind-mount + 关温度伪装（horae 写回 1）
if [ -f "$MODDIR/sched/thermal.sh" ]; then
    sh "$MODDIR/sched/thermal.sh" unmount >/dev/null 2>&1 || true
    sh "$MODDIR/sched/thermal.sh" off >/dev/null 2>&1 || true
fi

# 3. 删状态/备份/pid 文件（日志文件可留）
# M2（0.4.50）：0.4.45 起配置主备份在 /data/adb（lib.sh 的
# CONFIG_BACKUP），旧清单只删 /data/local/tmp 的旧备份——主备份留着，
# 重装时 customize.sh 三路恢复第一个就命中它，卸载前的配置全套复活
# （M14 回归）。生产环境把主备份也删掉；测试模式下主备份就在测试
# 目录里（和旧备份同一个文件），已在下面的清单里。
# C4 的日志目录标记文件也一并删（它记着上次解析出的日志目录）。
rm -f "$_td/oneplus_sched_uclamp_orig" "$_td/oneplus_sched_mig_orig" "$_td/oneplus_game_sched_state" "$_td/oneplus_sched_config.bak" "$_td/oneplus_thread_watch.pid" "$_td/oneplus_sched_logdir" 2>/dev/null || true
if [ -z "${SCHED_TEST_ROOT:-}" ]; then
    rm -f "/data/adb/oneplus_sched_config.bak" 2>/dev/null || true
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') oneplus_pad_pro_sched uninstalled, reboot restores stock" >> "$_td/调度日志.log" 2>/dev/null || true
