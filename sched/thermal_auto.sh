#!/system/bin/sh
# thermal_auto.sh - 进游戏自动去温控的统一入口（0.4.33 从 thread.sh 抽出来）
# thread.sh（watch 自动检测）和 game_sched.sh（面板/手动进游戏）都调这里，
# 保证手动进游戏和自动检测进游戏的去温控行为一致（S2）。
# 依赖：调用方已 source lib.sh（sched_log）、已设 MODDIR。
# THERMAL_AUTO_STATE：状态文件路径，调用方已设就用它的，没设就按
# SCHED_TEST_ROOT / /data/local/tmp 自己算。

if [ -z "${THERMAL_AUTO_STATE:-}" ]; then
    if [ -n "${SCHED_TEST_ROOT:-}" ]; then
        THERMAL_AUTO_STATE="$SCHED_TEST_ROOT/oneplus_thermal_auto"
    else
        THERMAL_AUTO_STATE="/data/local/tmp/oneplus_thermal_auto"
    fi
fi

# 读配置（thread.sh 的 config_value 同款；game_sched.sh 没有 config_value，
# 这里自带一个，避免两边各写一份）。
_thermal_cfg_value() {
    _k="$1"
    grep "^$_k=" "$MODDIR/sched/config.conf" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '"\r' | tr -d ' \t'
}

# 进游戏自动开去温控。只在 THERMAL_AUTO_GAME=1 且手动开关 THERMAL_REMOVE=0
# 时起作用。thermal.sh on 失败时不写状态文件、记 FAIL，下次进游戏再试。
thermal_auto_on() {
    _tag=$(_thermal_cfg_value THERMAL_AUTO_GAME)
    case "$_tag" in "" ) _tag=1 ;; esac
    [ "$_tag" = "1" ] || return 0
    _man=$(_thermal_cfg_value THERMAL_REMOVE)
    case "$_man" in "" ) _man=0 ;; esac
    [ "$_man" = "0" ] || return 0
    if [ -f "$THERMAL_AUTO_STATE" ]; then return 0; fi
    if env SCHED_LOG_QUIET=1 sh "$MODDIR/sched/thermal.sh" on >/dev/null 2>&1; then
        echo "on" > "$THERMAL_AUTO_STATE" 2>/dev/null || true
        sched_log "INFO thermal auto on（进游戏）"
        return 0
    fi
    sched_log "FAIL thermal auto on（thermal.sh on 失败，去温控没开）"
    return 1
}

# 退游戏自动关去温控（之前是自动开的才关）。中途手动开了去温控时不关它，
# 只把自动开的记录清掉（手动开就是一直开）。
thermal_auto_off() {
    [ -f "$THERMAL_AUTO_STATE" ] || return 0
    _man=$(_thermal_cfg_value THERMAL_REMOVE)
    case "$_man" in "" ) _man=0 ;; esac
    if [ "$_man" != "0" ]; then
        rm -f "$THERMAL_AUTO_STATE" 2>/dev/null || true
        return 0
    fi
    if env SCHED_LOG_QUIET=1 sh "$MODDIR/sched/thermal.sh" off >/dev/null 2>&1; then
        rm -f "$THERMAL_AUTO_STATE" 2>/dev/null || true
        sched_log "INFO thermal auto off（退游戏）"
        return 0
    fi
    sched_log "FAIL thermal auto off（thermal.sh off 失败，去温控可能还开着）"
    return 1
}
