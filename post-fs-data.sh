#!/system/bin/sh
# post-fs-data.sh - 开机早期：去温控的配置替换（0.4.29）
# THERMAL_REMOVE=1 时才把 thermal/ 下的替换文件 bind-mount 到原位置，
# 赶在温控服务读配置之前。0（默认）时什么都不做。
# 温度伪装（emul_temp）不在这里做，那是 service.sh 里 thermal.sh apply 的事。
# M15：开机早期 PATH 未必含 /system/bin，文件头固定 PATH；mount 失败
# 要留痕（先写 /data 下的日志，写不了就写 /dev 下的临时标记）。
export PATH=/system/bin:/sbin:$PATH
case "${0%/*}" in
    "$0") MODDIR="." ;;
    *) MODDIR="${0%/*}" ;;
esac
# 0.4.48：失败行写哪个日志文件和 lib.sh 用同一套解析（内部存储
# “调度器日志”文件夹优先、建不了/写不了回落 /data/local/tmp）。
# 这里是开机极早期，LOGFILE 拿
# 不到（source 失败）时不硬写文件，直接走下面的 /dev 标记兜底。
. "$MODDIR/sched/lib.sh" 2>/dev/null || true
if sh "$MODDIR/sched/thermal.sh" mount >/dev/null 2>&1; then
    :
else
    _rc=$?
    if [ -n "${LOGFILE:-}" ] && echo "$(date '+%Y-%m-%d %H:%M:%S') FAIL post-fs-data thermal mount rc=$_rc" >> "$LOGFILE" 2>/dev/null; then
        :
    else
        echo "FAIL post-fs-data thermal mount rc=$_rc" > /dev/oneplus_thermal_mount_fail 2>/dev/null || true
    fi
fi
