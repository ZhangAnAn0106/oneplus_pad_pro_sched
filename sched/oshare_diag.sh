#!/system/bin/sh
# oshare_diag.sh - 一加互传诊断（0.4.39，诊断版）：只诊断、不改任何东西。
# 真机上互传（com.coloros.oshare）每次传送都要手动开，因为官方行为是
# 控制中心开后 5 分钟（新版 10 分钟）不用自动关。定案是 watch 轮询补开，
# 但补开需要两条确切命令——“怎么判断互传开着”和“怎么无界面地打开它”——
# 必须先在真机上诊断定下来（研究报告 agent_notes/oshare-always-on-20261119.md）。
# 本脚本全部只读：记互传版本、pm dump 过滤（service 类名 + broadcast
# action）、当前状态（服务在不在跑、wifi p2p/direct、global/secure 设置
# 里 share/oshare 的项）、shared_prefs（时间戳是不是存在文件里）。
# 用户开着跑一次、关着跑一次，两份日志一对比就能定命令。
# 用法：sh sched/oshare_diag.sh（panel.sh oshare-diag 调它）
# 日志：内部存储“调度器日志”文件夹/诊断日志.log（建不了时回落
# /data/local/tmp；sched_log，带时间戳）

MODDIR="${0%/*}/.."
if [ -n "$SCHED_TEST_MODDIR" ]; then MODDIR="$SCHED_TEST_MODDIR"; fi
# shellcheck disable=SC1091
. "$MODDIR/sched/lib.sh"
# 0.4.42：诊断自己的日志文件（D）。
SCHED_LOG_CAT=diag

# 互传应用数据目录。测试时可用 OSHARE_DATA_DIR 指到模拟目录。
_data_dir="${OSHARE_DATA_DIR:-/data/data/com.coloros.oshare}"
_tmp="$LOGFILE.oshare.$$"
_tmp2="$LOGFILE.oshare2.$$"

sched_log "=== oshare diag start ==="

# 把文件里的行逐行记进日志（最多 _max 行，超了记一行截断提示）。
# 空文件记 (none)，文件缺失记 SKIP。只读，不改任何东西。
_diag_logfile() {
    _label="$1"; _max="$2"; _f="$3"
    if [ ! -f "$_f" ]; then
        sched_log "DIAG oshare $_label SKIP 输出缺失"
        return 0
    fi
    if [ ! -s "$_f" ]; then
        sched_log "DIAG oshare $_label (none)"
        return 0
    fi
    _c=0
    while IFS= read -r _l || [ -n "$_l" ]; do
        _c=$((_c+1))
        if [ "$_c" -gt "$_max" ]; then
            sched_log "DIAG oshare $_label ...（已截断到 $_max 行）"
            break
        fi
        sched_log "DIAG oshare $_label: $_l"
    done < "$_f"
    return 0
}

# --- 1. 互传版本 ---
if command -v dumpsys >/dev/null 2>&1; then
    dumpsys package com.coloros.oshare > "$_tmp" 2>/dev/null
    _rc=$?
    if [ "$_rc" = "0" ]; then
        grep -iE "versionName|versionCode" "$_tmp" > "$_tmp2" 2>/dev/null || true
        _diag_logfile "version" 10 "$_tmp2"
    else
        sched_log "DIAG oshare version SKIP dumpsys package 失败 rc=$_rc（应用可能不存在）"
    fi
else
    sched_log "DIAG oshare version SKIP dumpsys 不可用"
fi

# --- 2. pm dump：只留 service / receiver / activity 段和 intent action ---
# 完整输出太大，只留组件名和 action（定“无界面打开它”要用的 service 类名
# 和 broadcast action），其余噪音去掉；最多 150 行。
if command -v pm >/dev/null 2>&1; then
    pm dump com.coloros.oshare > "$_tmp" 2>/dev/null
    _rc=$?
    if [ "$_rc" = "0" ]; then
        grep -E "com\.coloros\.oshare|android\.intent\.action|Services:|Receivers:|Activities:" "$_tmp" > "$_tmp2" 2>/dev/null || true
        _diag_logfile "pm-dump" 150 "$_tmp2"
        # 2b. OshareStateReceiver 的完整 intent-filter Action 行（0.4.42：
        # 以后万一要走广播路线用。receiver 的 Action 可能不是
        # com.coloros.oshare 开头（比如 com.oplus.oshare.*），上面那节
        # 的过滤会漏掉，这里把所有 Action 行都记下来，上限 40 行）。
        grep -E "OshareStateReceiver|Action:" "$_tmp" > "$_tmp2" 2>/dev/null || true
        _diag_logfile "receiver-actions" 40 "$_tmp2"
    else
        sched_log "DIAG oshare pm-dump SKIP pm dump 失败 rc=$_rc（应用可能不存在）"
    fi
else
    sched_log "DIAG oshare pm-dump SKIP pm 不可用"
fi

# --- 3. 当前状态（跑的那一刻是什么状态就记什么状态）---
# 3a. 分享服务在不在跑（空 = 没在跑，很可能就是关着）。
if command -v dumpsys >/dev/null 2>&1; then
    dumpsys activity services com.coloros.oshare > "$_tmp" 2>/dev/null
    _rc=$?
    if [ "$_rc" = "0" ]; then
        _diag_logfile "services" 60 "$_tmp"
    else
        sched_log "DIAG oshare services SKIP dumpsys activity services 失败 rc=$_rc"
    fi
else
    sched_log "DIAG oshare services SKIP dumpsys 不可用"
fi
# 3b. wifi p2p/direct 状态。
if command -v dumpsys >/dev/null 2>&1; then
    dumpsys wifi > "$_tmp" 2>/dev/null
    _rc=$?
    if [ "$_rc" = "0" ]; then
        grep -iE "p2p|direct" "$_tmp" > "$_tmp2" 2>/dev/null || true
        _diag_logfile "wifi-p2p" 30 "$_tmp2"
    else
        sched_log "DIAG oshare wifi-p2p SKIP dumpsys wifi 失败 rc=$_rc"
    fi
else
    sched_log "DIAG oshare wifi-p2p SKIP dumpsys 不可用"
fi
# 3c. global / secure 设置里 share/oshare 的项。
if command -v settings >/dev/null 2>&1; then
    settings list global > "$_tmp" 2>/dev/null
    _rc=$?
    if [ "$_rc" = "0" ]; then
        grep -iE "share|oshare" "$_tmp" > "$_tmp2" 2>/dev/null || true
        _diag_logfile "settings-global" 20 "$_tmp2"
    else
        sched_log "DIAG oshare settings-global SKIP settings list global 失败 rc=$_rc"
    fi
    settings list secure > "$_tmp" 2>/dev/null
    _rc=$?
    if [ "$_rc" = "0" ]; then
        grep -iE "share|oshare" "$_tmp" > "$_tmp2" 2>/dev/null || true
        _diag_logfile "settings-secure" 20 "$_tmp2"
    else
        sched_log "DIAG oshare settings-secure SKIP settings list secure 失败 rc=$_rc"
    fi
else
    sched_log "DIAG oshare settings-global SKIP settings 不可用"
    sched_log "DIAG oshare settings-secure SKIP settings 不可用"
fi

# --- 4. shared_prefs：时间戳是不是存在文件里 ---
_sp="$_data_dir/shared_prefs"
if [ -d "$_sp" ]; then
    ls -l "$_sp" > "$_tmp" 2>/dev/null
    _rc=$?
    if [ "$_rc" = "0" ]; then
        _diag_logfile "shared-prefs-ls" 40 "$_tmp"
    else
        sched_log "DIAG oshare shared-prefs-ls SKIP ls 失败 rc=$_rc"
    fi
    rm -f "$_tmp2" 2>/dev/null || true
    _any=0
    for _xf in "$_sp"/*.xml; do
        [ -e "$_xf" ] || continue
        _any=1
        grep -iE "time|switch|enable" "$_xf" >> "$_tmp2" 2>/dev/null || true
    done
    if [ "$_any" = "0" ]; then
        sched_log "DIAG oshare shared-prefs-xml SKIP 没有 xml 文件"
    else
        _diag_logfile "shared-prefs-xml" 40 "$_tmp2"
    fi
else
    sched_log "DIAG oshare shared-prefs SKIP 目录不存在：$_sp"
fi

rm -f "$_tmp" "$_tmp2" 2>/dev/null || true
sched_log "=== oshare diag done ==="
exit 0
