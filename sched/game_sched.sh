#!/system/bin/sh
# game_sched.sh - 游戏模式的独立入口（薄 wrapper，真正调校在 apply_sched.sh）
#   game_sched.sh game      切到游戏模式（和平精英 / 无畏契约共用一个游戏档）
#   game_sched.sh off       切回 config.conf 的 MODE（默认 balanced）
#   game_sched.sh balanced  切回均衡模式（字面 balanced，不读 MODE）
#   game_sched.sh status    只显示当前是不是游戏模式，不写任何节点
# 平时不需要手动跑：thread.sh watch/auto 识别到这两款游戏会自动切，
# 退出游戏自动切回。手动跑主要用来进游戏前预热、或验证游戏模式有没有写进去。
# peace / valorant 是 game 的别名，老脚本调它们一样进游戏模式。
MODDIR="${0%/*}/.."
if [ -n "$SCHED_TEST_MODDIR" ]; then MODDIR="$SCHED_TEST_MODDIR"; fi
# shellcheck disable=SC1091
. "$MODDIR/sched/lib.sh"
load_config "$MODDIR/sched/config.conf"
# S2：进/退游戏的去温控统一入口（和 thread.sh watch 同一套逻辑，
# 面板手动进游戏也能自动开去温控，退游戏自动关）。
# shellcheck disable=SC1091
. "$MODDIR/sched/thermal_auto.sh"
: "${MODE:=balanced}"
if [ -n "$SCHED_TEST_ROOT" ]; then
    _state="$SCHED_TEST_ROOT/game_sched_state"
else
    _state="/data/local/tmp/oneplus_game_sched_state"
fi

# M6/S2：lib.sh 提供 verify_game_applied() / verify_game_restored()
# （无参数，回读哨兵节点精确验证游戏模式真写进去了：前台 uclamp
# min 和 GPU min_freq 按百分比算期望值比对）。
# C7（0.4.50）：删掉本文件里那两份兜底实现——判据和 lib.sh 正版不
# 一致（写死 class/devfreq/kgsl-3d0 路径、只判 min_freq 大于最低
# OPP），lib.sh 在时永不触发，留着只会在 lib 改名时用另一套标准
# 判成败。缺函数就报错退出，不装懂。
if ! command -v verify_game_applied >/dev/null 2>&1 || ! command -v verify_game_restored >/dev/null 2>&1; then
    sched_log "FAIL game_sched: lib.sh 缺少 verify_game_applied/verify_game_restored"
    echo "ERR lib.sh 缺少哨兵验证函数，模块文件不完整"
    exit 1
fi

case "${1:-}" in
    game|peace|valorant)
        echo "切到游戏模式：schedutil up=${GAME_SCHEDUTIL_UP_US:-0}us down=${GAME_SCHEDUTIL_DOWN_US_PEACE:-10000}us hispeed=${GAME_HISPEED_LOAD_PEACE:-85} GPU下限=${GAME_GPU_MIN_FREQ_PCT_PEACE:-35}%"
        sh "$MODDIR/sched/apply_sched.sh" "game"
        _rc=$?
        if [ "$_rc" -ne 0 ]; then
            sched_log "FAIL game_sched apply game rc=$_rc"
            echo "ERR 游戏模式应用失败（apply_sched.sh rc=$_rc）"
            exit 1
        fi
        if verify_game_applied; then
            echo "game" > "$_state" 2>/dev/null || true
            thermal_auto_on || true
        else
            sched_log "FAIL game_sched 哨兵验证失败，未写状态文件"
            echo "ERR 游戏模式验证失败（uclamp/GPU 未生效），未切游戏模式"
            exit 1
        fi
        ;;
    off|balanced)
        if [ "$1" = "balanced" ]; then _target="balanced"; else _target="$MODE"; fi
        sh "$MODDIR/sched/apply_sched.sh" "$_target"
        # 0.4.35：反向验证——切回后游戏档数值必须已撤销。verify_game_restored
        # 返回 1 = 前台 uclamp 仍是 77 或 GPU 下限仍是抬高值（或哨兵
        # 节点读回非数字），切回失败：状态文件保留、不关去温控，
        # 报 ERR 并 exit 1，不再无条件报“已切回”。
        # 注意：apply_sched.sh 自身几乎永远 exit 0（write_node 恒返回 0），
        # 只凭它的退出码看不出写没写进去，哨兵回读才是真正的判断。
        if ! verify_game_restored; then
            sched_log "FAIL game_sched restore 失败（游戏档数值未撤销 mode=$_target），状态文件保留"
            echo "ERR 切回 $_target 失败：游戏档数值未撤销，仍在游戏档"
            exit 1
        fi
        rm -f "$_state" 2>/dev/null || true
        thermal_auto_off || true
        echo "已切回 $_target"
        ;;
    status)
        if [ -f "$_state" ]; then echo "当前游戏模式：$(cat "$_state" 2>/dev/null)"; else echo "当前不是游戏模式（均衡/日常：$MODE）"; fi
        ;;
    *)
        echo "用法: game_sched.sh game|off|balanced|status（peace|valorant 是 game 的别名）"
        exit 2
        ;;
esac
