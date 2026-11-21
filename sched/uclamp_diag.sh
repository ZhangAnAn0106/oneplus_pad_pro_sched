#!/system/bin/sh
# uclamp_diag.sh - uclamp 诊断（0.4.37，诊断版）：只诊断、不改调度行为。
# 真机日志里 top-app min=153 / background max=256、512 两组写失败，
# 前台 min=77、min=0、后台 min=0 都写成功，两个根都失败——根因未定，
# 先把现场（权限、当前值、试写报错原文、dmesg）记进日志，再定修法。
# 试写安全规则：先读原值，读不到/为空就不试写；写完无论成功失败都
# 把原值写回去（恢复现场，不改变系统状态）；任何一项失败不影响其他
# 项；脚本本身永不 crash（逐项 try，退出码恒为 0）。
# 用法：sh sched/uclamp_diag.sh（panel.sh uclamp-diag 调它）
# 日志：内部存储“调度器日志”文件夹/诊断日志.log（建不了时回落
# /data/local/tmp；sched_log，带时间戳）

MODDIR="${0%/*}/.."
if [ -n "$SCHED_TEST_MODDIR" ]; then MODDIR="$SCHED_TEST_MODDIR"; fi
# shellcheck disable=SC1091
. "$MODDIR/sched/lib.sh"
# 0.4.42：诊断自己的日志文件（D）。
SCHED_LOG_CAT=diag

sched_log "=== uclamp diag start ==="

# --- 1. 现状：每个组、每个根、min/max 的权限 + 当前值 ---
# 组 "" = 根组本身（$root/cpu.uclamp.min），其余是 top-app/foreground/background。
_diag_stat() {
    _f="$1"
    if [ ! -e "$_f" ]; then
        sched_log "DIAG SKIP $_f 不存在"
        return 0
    fi
    _ls=$(ls -l "$_f" 2>&1)
    _v=$(cat "$_f" 2>/dev/null)
    _rc=$?
    _v=$(printf '%s' "$_v" | tr -d '\r\n')
    if [ "$_rc" != "0" ]; then
        sched_log "DIAG $_f ls='$_ls' val=READ_FAIL"
    else
        sched_log "DIAG $_f ls='$_ls' val='$_v'"
    fi
    return 0
}
for _root in "$DEV/cpuctl" "$SYS/fs/cgroup/cpu"; do
    for _g in "" top-app foreground background; do
        for _fld in min max; do
            if [ -z "$_g" ]; then
                _diag_stat "$_root/cpu.uclamp.$_fld"
            else
                _diag_stat "$_root/$_g/cpu.uclamp.$_fld"
            fi
        done
    done
done

# --- 2. 试写：每写一次记退出码和 stderr，写完把原值写回去 ---
# dash 坑（0.4.24 教训）：$(echo X > 文件 2>&1) 抓不到重定向失败的
# 报错——重定向失败时 2>&1 还没生效。必须写成 echo X 2>&1 > 文件，
# 先把 stderr 指到当前 stdout（命令替换的管道），再重定向 stdout
# 到文件，这样打开文件失败的报错才进管道、退出码才非 0。
_diag_try() {
    _g="$1"; _fld="$2"; _tv="$3"; _root="$4"
    _f="$_root/$_g/cpu.uclamp.$_fld"
    if [ ! -e "$_f" ]; then
        sched_log "DIAG TRY SKIP $_f 不存在"
        return 0
    fi
    _orig=$(cat "$_f" 2>/dev/null)
    _orc=$?
    if [ "$_orc" != "0" ]; then
        sched_log "DIAG TRY SKIP $_f 原值读不到（rc=$_orc），不试写"
        return 0
    fi
    _orig=$(printf '%s' "$_orig" | tr -d '\r\n')
    if [ -z "$_orig" ]; then
        sched_log "DIAG TRY SKIP $_f 原值为空，不试写"
        return 0
    fi
    _err=$(echo "$_tv" 2>&1 > "$_f")
    _rc=$?
    if [ "$_rc" = "0" ]; then
        sched_log "DIAG TRY $_f 写 $_tv 成功 rc=0"
    else
        sched_log "DIAG TRY $_f 写 $_tv 失败 rc=$_rc err='$_err'"
    fi
    # 恢复现场：把原值写回去（无论试写成功失败）。
    _rerr=$(echo "$_orig" 2>&1 > "$_f")
    _rrc=$?
    if [ "$_rrc" = "0" ]; then
        sched_log "DIAG RESTORE $_f 写回原值 '$_orig' 成功 rc=0"
    else
        sched_log "DIAG RESTORE $_f 写回原值 '$_orig' 失败 rc=$_rrc err='$_rerr'"
    fi
    return 0
}
for _root in "$DEV/cpuctl" "$SYS/fs/cgroup/cpu"; do
    _diag_try top-app min 153 "$_root"
    _diag_try top-app max 1024 "$_root"
    _diag_try background max 512 "$_root"
    _diag_try background max 256 "$_root"
    _diag_try background min 0 "$_root"
    _diag_try foreground min 77 "$_root"
done

# --- 3. dmesg 最后 20 行（能读到才记）---
_dmt="$LOGFILE.dmesg.$$"
if dmesg > "$_dmt" 2>/dev/null && [ -s "$_dmt" ]; then
    sched_log "DIAG dmesg 最后 20 行："
    tail -n 20 "$_dmt" 2>/dev/null | while IFS= read -r _dl; do
        sched_log "DIAG dmesg: $_dl"
    done
else
    sched_log "DIAG dmesg SKIP 读不到"
fi
rm -f "$_dmt" 2>/dev/null || true

sched_log "=== uclamp diag done ==="
exit 0
