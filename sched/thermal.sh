#!/system/bin/sh
# thermal.sh - 去温控（0.4.29，Extreme GT 4.2.1 合并进来）
# 来源：Extreme GT 4.2.1（SCENE 生成，作者嘟嘟ski & SCENE），原样合并，
# 做法一字没改——只把“装了就全开”改成“面板开关控制，默认关”。
#
# 做法分两半（和 Extreme GT 完全一致）：
#   1. 配置替换：thermal/ 下 9 个文件（温控配置、锁帧映射、充电温控、
#      刷新率配置）bind-mount 到原位置，盖掉 OPlus 的温控/锁帧配置。
#      挂载点是开机早期（post-fs-data.sh），赶在温控服务读配置之前。
#      这 9 个文件按机型生成（项目号 23926），只对这台 OPD2404 有效。
#   2. 温度伪装：开机后（service.sh）把各 thermal_zone 的 emul_temp
#      写死成 29.5°C（外壳 33°C）、/proc/shell-temp 写死 29.5°C，
#      再把 persist.sys.horae.enable 置 0（关 horae 温控服务）。
#      温控服务读到的温度永远是“凉的”，就不会降频、不会锁帧。
#
# 开关：config.conf 的 THERMAL_REMOVE（0=关，默认；1=开）。
#   开：post-fs-data.sh 挂载配置 + service.sh 伪装温度 + 关 horae。
#   关：不挂载、不伪装，horae 保持开。关的时候把 emul_temp 写回 0
#       恢复真实温度（Linux 温控核心里 emul_temp 为 0 就是不伪装），
#       /proc/shell-temp 重启后才彻底恢复。
#   面板开关点开会立即伪装温度（不用等重启），但配置替换要重启后
#   才完全生效——温控服务开机时就把配置读进去了。
# 自动：THERMAL_AUTO_GAME=1（默认）时，进游戏自动开、退游戏自动关，
#   手动开关 THERMAL_REMOVE=1 时自动逻辑不动它（手动开就是一直开）。
#
# 用法：
#   thermal.sh mount     # 只挂载（THERMAL_REMOVE=1 时才挂；post-fs-data.sh 用）
#   thermal.sh unmount   # 卸掉已挂载的替换文件
#   thermal.sh fake      # 温度伪装 + 关 horae（不碰挂载）
#   thermal.sh on        # 挂载 + 伪装 + 关 horae（面板“打开”用）
#   thermal.sh off       # 卸掉挂载 + 恢复 horae（面板“关闭”用）
#   thermal.sh apply     # 开机套用：按 THERMAL_REMOVE 决定开还是关（service.sh 用）
#   thermal.sh status    # key=value：thermal_remove / thermal_fake /
#                         #   shell_temp_fake / thermal_mounted /
#                         #   thermal_mounted_count
#
# 退出码：mount/unmount/fake/on/off/apply 汇总失败个数返回，
#   0=全成功，非 0=有步骤失败（只记日志不报错就是撒谎，见 M7）。
#   status 永远返回 0。
#
# 注意：一切写节点都走“存在才写、失败记 FAIL”的老规矩；节点不存在
# （比如 emul_temp 没编进内核）就跳过，不中断。mount/umount 失败
# 也只记日志——最坏情况就是去温控没生效，不会把调度搞坏。
# 另注意：emul_temp=0 等于恢复真实温度是 Linux 通用语义，在这台
# OPlus 内核上尚未证实——off 后会读回各 zone 的 temp 验证，
# 仍卡在 29500/33000 就记 WARN，别当成已恢复（见 S15）。

MODDIR="${0%/*}/.."
if [ -n "$SCHED_TEST_MODDIR" ]; then MODDIR="$SCHED_TEST_MODDIR"; fi
# shellcheck disable=SC1091
. "$MODDIR/sched/lib.sh"
load_config "$MODDIR/sched/config.conf"
# 0.4.42：温控自己的日志文件（D）。
SCHED_LOG_CAT=thermal
: "${THERMAL_REMOVE:=0}"

THERMAL_DIR="$MODDIR/thermal"
# 测试时所有真实路径都挂上测试根（和 lib.sh 的 SYS/PROC 一个做法）；
# 真机上 SCHED_TEST_ROOT 为空，路径就是原样。
_ROOT="${SCHED_TEST_ROOT:-}"
THERMAL_LOCK="${SCHED_TEST_ROOT:-/data/local/tmp}/oneplus_sched_thermal.lock"

# 伪装温度（和 Extreme GT service.sh 完全一致）
_FAKE_T=29500
_FAKE_SHELL_T=33000

# ---------- 小工具 ----------
# 目标是否已在 /proc/mounts 里（bind-mount 记录格式：源 目标 ...）。
_thermal_is_mounted() {
    [ -f "$PROC/mounts" ] || return 1
    grep -qF " $1 " "$PROC/mounts" 2>/dev/null
}

# M5：mkdir 原子锁（和 zram.sh 的 zram_lock_acquire 同款）。拿不到锁
# 时看 holder 是否还活着（pid 文件里的 PID 用 kill -0 检查）或锁目录
# mtime 是否超过 5 分钟，死了/超期就是残留锁，清掉重拿一次；两次
# 都拿不到才返回“正在切换”。trap 保证异常退出时解锁（先删 pid
# 文件再 rmdir，不然目录非空 rmdir 失败）。
thermal_lock_acquire() {
    if mkdir "$THERMAL_LOCK" 2>/dev/null; then
        echo "$$" > "$THERMAL_LOCK/pid" 2>/dev/null
        trap 'rm -f "$THERMAL_LOCK/pid" 2>/dev/null; rmdir "$THERMAL_LOCK" 2>/dev/null' EXIT
        return 0
    fi
    _holder=""
    [ -f "$THERMAL_LOCK/pid" ] && _holder=$(cat "$THERMAL_LOCK/pid" 2>/dev/null)
    _stale=0
    case "$_holder" in
        ''|*[!0-9]*) _stale=1 ;;
        *) kill -0 "$_holder" 2>/dev/null || _stale=1 ;;
    esac
    if [ "$_stale" = "0" ] && find "$THERMAL_LOCK" -mmin +5 2>/dev/null | grep -q .; then
        _stale=1
    fi
    if [ "$_stale" = "1" ]; then
        sched_log "WARN thermal 锁残留（holder=${_holder:-未知}），清掉重拿"
        rm -rf "$THERMAL_LOCK" 2>/dev/null
        if mkdir "$THERMAL_LOCK" 2>/dev/null; then
            echo "$$" > "$THERMAL_LOCK/pid" 2>/dev/null
            trap 'rm -f "$THERMAL_LOCK/pid" 2>/dev/null; rmdir "$THERMAL_LOCK" 2>/dev/null' EXIT
            return 0
        fi
    fi
    echo "ERR 正在切换，稍后再试"
    return 1
}

# ---------- 配置替换：挂载 / 卸载 ----------
# 只挂载 thermal/ 下有的文件，且目标文件必须已存在才挂（和
# Extreme GT post-fs-data.sh 的 replace_files 一个逻辑）。
# M1：挂前查 /proc/mounts，已挂就跳过（不叠挂）；返回失败个数。
# O11：find 先存临时文件再循环（find|while 跑在子 shell，失败个数
# 带不回父 shell）；read 加 IFS=，防前导/尾随空白被吃掉。
thermal_mount() {
    _fail=0
    _list="${TMPDIR:-/tmp}/thermal_mount.$$.list"
    if ! printf '' > "$_list" 2>/dev/null; then
        sched_log "FAIL thermal mount：写临时文件失败"
        return 1
    fi
    for _part in my_product my_stock odm vendor; do
        [ -d "$THERMAL_DIR/$_part" ] || continue
        find "$THERMAL_DIR/$_part" -type f 2>/dev/null >> "$_list"
    done
    while IFS= read -r _src || [ -n "$_src" ]; do
        [ -n "$_src" ] || continue
        _rel="${_src#$THERMAL_DIR}"
        _dst="$_ROOT$_rel"
        if [ -f "$_dst" ]; then
            if _thermal_is_mounted "$_dst"; then
                sched_log "SKIP thermal mount $_rel (已挂载)"
            elif _err=$(mount --bind "$_src" "$_dst" 2>&1); then
                sched_log "OK thermal mount $_rel"
            else
                _fail=$((_fail + 1))
                sched_log "FAIL thermal mount $_rel: ${_err:-mount 失败}"
            fi
        else
            sched_log "SKIP thermal mount $_rel (目标不存在)"
        fi
    done < "$_list"
    rm -f "$_list" 2>/dev/null
    return "$_fail"
}

# M1+S20+S12：不按 thermal/ 下的文件列表卸——扫描 /proc/mounts，
# 凡是源路径在 $THERMAL_DIR 下的 bind-mount 都卸掉（升级改名后的
# 陈旧挂载也能清掉）；每个目标循环 umount 直到它不在 /proc/mounts
# 里；umount 失败抓 stderr 记 FAIL；卸完复核，仍有残留记 FAIL。
# 返回失败个数。
thermal_unmount() {
    _fail=0
    _list="${TMPDIR:-/tmp}/thermal_unmount.$$.list"
    if ! printf '' > "$_list" 2>/dev/null; then
        sched_log "FAIL thermal unmount：写临时文件失败"
        return 1
    fi
    if [ -f "$PROC/mounts" ]; then
        while IFS= read -r _line || [ -n "$_line" ]; do
            [ -n "$_line" ] || continue
            _msrc=${_line%% *}
            case "$_msrc" in
                "$THERMAL_DIR"/*)
                    _mrest=${_line#* }
                    _mdst=${_mrest%% *}
                    printf '%s\n' "$_mdst" >> "$_list"
                    ;;
            esac
        done < "$PROC/mounts"
    fi
    sort -u "$_list" > "$_list.u" 2>/dev/null && mv "$_list.u" "$_list" 2>/dev/null
    while IFS= read -r _dst || [ -n "$_dst" ]; do
        [ -n "$_dst" ] || continue
        _n=0
        while _thermal_is_mounted "$_dst"; do
            _n=$((_n + 1))
            if [ "$_n" -gt 10 ]; then
                _fail=$((_fail + 1))
                sched_log "FAIL thermal umount $_dst：10 次仍挂着"
                break
            fi
            if _err=$(umount "$_dst" 2>&1); then
                sched_log "OK thermal umount $_dst"
            else
                _fail=$((_fail + 1))
                sched_log "FAIL thermal umount $_dst: ${_err:-umount 失败}"
                break
            fi
        done
    done < "$_list"
    rm -f "$_list" "$_list.u" 2>/dev/null
    if [ -f "$PROC/mounts" ]; then
        _left=0
        while IFS= read -r _line || [ -n "$_line" ]; do
            _msrc=${_line%% *}
            case "$_msrc" in
                "$THERMAL_DIR"/*) _left=$((_left + 1)) ;;
            esac
        done < "$PROC/mounts"
        if [ "$_left" -gt 0 ]; then
            sched_log "FAIL thermal unmount：仍有 $_left 个挂载残留"
            _fail=$((_fail + _left))
        fi
    fi
    return "$_fail"
}

# ---------- 温度伪装 ----------
# S11：按成功/失败的 zone 数记日志。emul_temp 一个都没写进去就记
# FAIL 并返回失败；shell-temp 10 次写、gauge 两次写都按成功次数
# 记 OK/FAIL。返回失败个数（on 汇总用）。
# S19：白名单照搬 Extreme GT，未对照 OPD2404 的实际 zone 列表验证
# 过——启动时把实际扫到的 zone 类型写进日志一行，方便真机核对
# 白名单有没有漏。备选（只写注释，不改行为）：除明确排除的区外
# 全部 fake；改之前必须先核对 INFO thermal zones 那行的类型列表，
# 确认没有不能碰的区（如充电/安全相关），再改这里的行为。
thermal_fake() {
    _fail=0; _ok=0; _tried=0; _types=""
    for _tz in "$SYS"/class/thermal/*; do
        [ -f "$_tz/temp" ] || continue
        _type=$(cat "$_tz/type" 2>/dev/null)
        [ -n "$_type" ] || continue
        case " $_types " in *" $_type "*) ;; *) _types="$_types $_type" ;; esac
    done
    sched_log "INFO thermal zones:${_types:- （无）}"
    for _tz in "$SYS"/class/thermal/*; do
        [ -f "$_tz/temp" ] || continue
        _type=$(cat "$_tz/type" 2>/dev/null)
        case "$_type" in
            pm8550_gpio03_usr|pm8550vs_g_tz|pm8550b_tz|pm8550vs_c_tz|pa-therm2-sys3|rear-tof-therm|cam-flash-therm|wlan-therm|xo-therm|oplus_thermal_ipa|board_temp|ap_ntc|ltepa_ntc|nrpa_ntc|wcn_temp)
                _v="$_FAKE_T"
                ;;
            batt-therm|usb-therm)
                _v="$_FAKE_T"
                ;;
            shell*)
                _v="$_FAKE_SHELL_T"
                ;;
            *) continue ;;
        esac
        if [ -e "$_tz/emul_temp" ]; then
            _tried=$((_tried + 1))
            if echo "$_v" > "$_tz/emul_temp" 2>/dev/null; then
                _ok=$((_ok + 1))
                sched_log "OK thermal fake $_type=$_v"
            else
                _fail=$((_fail + 1))
                sched_log "FAIL thermal fake $_type"
            fi
        fi
    done
    if [ "$_tried" -eq 0 ]; then
        sched_log "FAIL thermal fake：没有可写的 emul_temp"
        _fail=$((_fail + 1))
    else
        sched_log "INFO thermal fake emul_temp 成功 $_ok/$_tried 个 zone"
        if [ "$_ok" -eq 0 ]; then
            sched_log "FAIL thermal fake：emul_temp 一个都没写进去"
            _fail=$((_fail + 1))
        fi
    fi
    # 外壳温度（/proc/shell-temp，Extreme GT 原样：seq 0-9 各写一次）
    if [ -f "$PROC/shell-temp" ]; then
        _sok=0
        for _i in 0 1 2 3 4 5 6 7 8 9; do
            if echo "$_i $_FAKE_T" > "$PROC/shell-temp" 2>/dev/null; then
                _sok=$((_sok + 1))
            fi
        done
        if [ "$_sok" -eq 10 ]; then
            sched_log "OK thermal fake shell-temp=$_FAKE_T (10/10)"
        else
            _fail=$((_fail + (10 - _sok)))
            sched_log "FAIL thermal fake shell-temp：只写进 $_sok/10 次"
        fi
    fi
    # 电池 gauge 强制更新（Extreme GT 原样）
    _gu="$PROC/oplus-votable/GAUGE_UPDATE"
    if [ -d "$_gu" ]; then
        _gok=0
        chmod 666 "$_gu/force_val" 2>/dev/null
        if echo '1000' > "$_gu/force_val" 2>/dev/null; then _gok=$((_gok + 1)); fi
        chmod 666 "$_gu/force_active" 2>/dev/null
        if echo '1' > "$_gu/force_active" 2>/dev/null; then _gok=$((_gok + 1)); fi
        if [ "$_gok" -eq 2 ]; then
            sched_log "OK thermal gauge force (2/2)"
        else
            _fail=$((_fail + (2 - _gok)))
            sched_log "FAIL thermal gauge force：只写进 $_gok/2"
        fi
    fi
    return "$_fail"
}

# ---------- 取消温度伪装 ----------
# 把所有 thermal_zone 的 emul_temp 写回 0。Linux 温控核心里 emul_temp
# 为 0 就是“不伪装”（非 0 才用伪装值代替真实温度），所以写 0 等于
# 恢复真实温度。/proc/shell-temp 没法这样恢复（它只记最后一次写
# 的值，真实值读不到），关掉后它还留在 29.5°C，重启才彻底恢复——
# 主力温控区（CPU/电池/主板）恢复真实温度就够了，壳温那一项影响很小。
# M11：撤销 GAUGE_UPDATE 强制（force_active/force_val 写回 0），
# 并把之前 chmod 666 的两个节点权限尽量恢复 644（失败记 WARN）。
# S15：写回后读回各 zone 的 temp，若仍卡在 29500/33000 就记 WARN
# “emul_temp=0 未生效，重启恢复”——emul_temp=0 在这台 OPlus 内核
# 上是否等于取消伪装尚未证实，代码只做读回验证，不编造结论。
thermal_unfake() {
    _fail=0
    for _tz in "$SYS"/class/thermal/*; do
        if [ -e "$_tz/emul_temp" ]; then
            if echo "0" > "$_tz/emul_temp" 2>/dev/null; then
                sched_log "OK thermal unfake $(cat "$_tz/type" 2>/dev/null)=0"
            else
                _fail=$((_fail + 1))
                sched_log "FAIL thermal unfake $(cat "$_tz/type" 2>/dev/null)"
            fi
        fi
    done
    _gu="$PROC/oplus-votable/GAUGE_UPDATE"
    if [ -d "$_gu" ]; then
        if echo '0' > "$_gu/force_active" 2>/dev/null; then
            sched_log "OK thermal gauge force_active=0"
        else
            _fail=$((_fail + 1))
            sched_log "FAIL thermal gauge force_active 写回 0 失败"
        fi
        if echo '0' > "$_gu/force_val" 2>/dev/null; then
            sched_log "OK thermal gauge force_val=0"
        else
            _fail=$((_fail + 1))
            sched_log "FAIL thermal gauge force_val 写回 0 失败"
        fi
        for _n in force_val force_active; do
            if chmod 644 "$_gu/$_n" 2>/dev/null; then
                sched_log "OK thermal gauge $_n 权限恢复 644"
            else
                sched_log "WARN thermal gauge $_n 权限恢复失败"
            fi
        done
    fi
    for _tz in "$SYS"/class/thermal/*; do
        [ -f "$_tz/temp" ] || continue
        _tv=$(cat "$_tz/temp" 2>/dev/null)
        case "$_tv" in
            "$_FAKE_T"|"$_FAKE_SHELL_T")
                sched_log "WARN thermal unfake：$(cat "$_tz/type" 2>/dev/null) temp 仍是 $_tv，emul_temp=0 未生效，重启恢复"
                ;;
        esac
    done
    return "$_fail"
}
# $1 = 0 关 horae / 1 开 horae。persist 属性，写进去就一直有效，
# 所以关的时候要记得写回 1，不然下次开机 horae 还关着。
# S13：resetprop 不可用或写失败都记 FAIL 并返回 1（不是 SKIP），
# on/apply 汇总后返回非 0，面板如实报错。
thermal_prop() {
    if command -v resetprop >/dev/null 2>&1; then
        if resetprop persist.sys.horae.enable "$1" 2>/dev/null; then
            sched_log "OK thermal prop horae.enable=$1"
            return 0
        else
            sched_log "FAIL thermal prop horae.enable=$1"
            return 1
        fi
    else
        sched_log "FAIL thermal prop (没有 resetprop，horae.enable=$1 没写进去)"
        return 1
    fi
}

# ---------- 状态 ----------
# thermal_remove：配置值（面板开关同步用）。
# thermal_fake：任一 thermal_zone 的 emul_temp 正好是伪装值（29500/33000）。
# shell_temp_fake：/proc/shell-temp 内容是否还是 fake 值（29500）。
# thermal_mounted：9 个目标里已挂载的个数（thermal_mounted_count=N/9，
#   兼容旧面板的 thermal_mounted=yes/no，9/9 才 yes）。
cmd_status() {
    echo "thermal_remove=${THERMAL_REMOVE:-0}"
    _fake="no"
    for _tz in "$SYS"/class/thermal/*; do
        [ -f "$_tz/emul_temp" ] || continue
        _v=$(cat "$_tz/emul_temp" 2>/dev/null)
        case "$_v" in
            "$_FAKE_T"|"$_FAKE_SHELL_T") _fake="yes" ;;
        esac
    done
    echo "thermal_fake=$_fake"
    _stf="no"
    if [ -f "$PROC/shell-temp" ]; then
        case "$(cat "$PROC/shell-temp" 2>/dev/null)" in
            *"$_FAKE_T"*) _stf="yes" ;;
        esac
    fi
    echo "shell_temp_fake=$_stf"
    _mounted_n=0; _mounted_t=0
    _list="${TMPDIR:-/tmp}/thermal_status.$$.list"
    if printf '' > "$_list" 2>/dev/null; then
        for _part in my_product my_stock odm vendor; do
            [ -d "$THERMAL_DIR/$_part" ] || continue
            find "$THERMAL_DIR/$_part" -type f 2>/dev/null >> "$_list"
        done
        while IFS= read -r _src || [ -n "$_src" ]; do
            [ -n "$_src" ] || continue
            _mounted_t=$((_mounted_t + 1))
            _rel="${_src#$THERMAL_DIR}"
            if _thermal_is_mounted "$_ROOT$_rel"; then
                _mounted_n=$((_mounted_n + 1))
            fi
        done < "$_list"
        rm -f "$_list" 2>/dev/null
    fi
    echo "thermal_mounted_count=$_mounted_n/$_mounted_t"
    if [ "$_mounted_t" -gt 0 ] && [ "$_mounted_n" -eq "$_mounted_t" ]; then
        echo "thermal_mounted=yes"
    else
        echo "thermal_mounted=no"
    fi
}

# ---------- 分发 ----------
_rc=0
# M5：写入口（mount/unmount/fake/on/off/apply）先拿锁；status 是只读
# 的，不拿。拿不到锁返回“正在切换，稍后再试”，退出 1。
case "${1:-}" in
    mount|unmount|fake|on|off|apply)
        if ! thermal_lock_acquire; then
            exit 1
        fi
        ;;
esac
case "${1:-}" in
    mount)
        if [ "${THERMAL_REMOVE:-0}" = "1" ]; then
            thermal_mount; _rc=$?
        else
            sched_log "SKIP thermal mount (THERMAL_REMOVE=0)"
        fi
        ;;
    unmount)
        thermal_unmount; _rc=$?
        ;;
    fake)
        thermal_fake; _rc=$?
        thermal_prop 0; _prc=$?
        _rc=$((_rc + _prc))
        ;;
    on)
        thermal_mount; _rc=$?
        thermal_fake; _f=$?
        _rc=$((_rc + _f))
        thermal_prop 0; _prc=$?
        _rc=$((_rc + _prc))
        ;;
    off)
        thermal_unmount; _rc=$?
        thermal_unfake; _f=$?
        _rc=$((_rc + _f))
        thermal_prop 1; _prc=$?
        _rc=$((_rc + _prc))
        sched_log "INFO thermal off：温度伪装已取消（/proc/shell-temp 重启后恢复）"
        ;;
    apply)
        if [ "${THERMAL_REMOVE:-0}" = "1" ]; then
            thermal_mount; _rc=$?
            thermal_fake; _f=$?
            _rc=$((_rc + _f))
            thermal_prop 0; _prc=$?
            _rc=$((_rc + _prc))
        else
            # 关的时候把 horae 写回 1，清掉上次开过留下的 0
            # （persist 属性不写回会一直关着）。
            thermal_prop 1; _rc=$?
        fi
        ;;
    status)
        cmd_status
        ;;
    *)
        echo "用法: thermal.sh mount|unmount|fake|on|off|apply|status"
        exit 2
        ;;
esac
exit "$_rc"
