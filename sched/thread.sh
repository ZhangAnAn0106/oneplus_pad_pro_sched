#!/system/bin/sh
# thread.sh - 线程模块：自动识别 + 绑定
#
# 两件事，分开理解：
#   1. 自动识别：不用你输包名，脚本自己找出当前前台应用（dumpsys ->
#      cpuset/top-app -> oom_score_adj 三级兜底），再按线程名把线程
#      分成 主/游戏 / 渲染 / RHI / TaskGraph / 音频语音 / 网络 / Binder /
#      后台工人 / 其他。UE 线程名按子串判（GameThread / RenderThread /
#      RHIThread / TaskGraphThread / AudioMixer / Voice 等，comm 截断
#      到 15 字也能命中）。
#   2. 绑定：按类别绑核，不是一股脑全绑大核。主线程和渲染线程上大核，
#      后台工人只用小核，其他线程放中+小核，避免后台线程抢大核。
#      两款主力游戏（和平精英 pubgmhd，UE4 大逃杀长局；无畏契约：
#      源能行动 codev，5v5 战术 FPS）共用一个游戏档：主/游戏线程独
#      占超大核防迁移，Render/RHI 上大核，TaskGraph/流式加载放中核
#      防卡顿，语音/网络放中核，后台工人放中核。见 profile_for_package /
#      policy_for_class。0.4.15 前 peace / valorant 是两个特调档，
#      现已合并，只剩 game 一个游戏档。
#
# 依赖：root + toybox 的 taskset / renice（ColorOS 自带，一般都有）。
# 绑核走 sched_setaffinity，和 cpuset 是两条线：cpuset 管“进程能去
# 哪组核”，taskset 管“这个线程具体能上哪几个核”，后者更细。
#
# 用法（root，先 su）：
#   thread.sh detect                      # 只识别、不绑定：先跑这个验识别准不准
#   thread.sh gamedetect                  # 只看两款游戏的进程在不在跑（不看前台）
#   thread.sh auto                        # 先看游戏进程在不在跑，再看前台应用，自动分类绑定
#   thread.sh auto [game|daily|background] [--dry-run]  # 强制按档位绑定（也要识别到前台应用；peace|valorant 是 game 的别名）
#   thread.sh game on|off                  # 只切调度模式，不绑核（off=切回均衡；peace|valorant 是 on 的别名）
#   thread.sh watch [秒数] [game|daily]   # 常驻轮询：游戏进程在跑就占着游戏档，前台换了就重绑
#   thread.sh stop                        # 停掉 watch
#   thread.sh list <包名或PID>            # 手动：列线程
#   thread.sh bind <包名或PID> <all|little|mid|big|prime|mid_little>
#   thread.sh unbind <包名或PID>          # 绑回全核
#   thread.sh prio <包名或PID> <nice值>   # 例如 -5，越小越优先，别用 -20
#   thread.sh profile <包名> <game|daily|background>
#
# 安全线：PID 1/2 拒绝；自动模式永远不碰 system_server / surfaceflinger /
# systemui 等系统关键进程（FORCE 也救不了）；手动模式动系统进程才需
# FORCE=1 或 --force。绑核前先跑 detect 确认识别到的是你要的那个应用。
# 新线程是进程启动后陆续创建的，一次 auto 只绑当时已存在的线程；
# 游戏刚启动时跑一次 auto，进游戏后再跑一次，或用 watch 让它自己跟。

MODDIR="${0%/*}/.."
if [ -n "$SCHED_TEST_MODDIR" ]; then MODDIR="$SCHED_TEST_MODDIR"; fi
# shellcheck disable=SC1091
. "$MODDIR/sched/lib.sh"
load_config "$MODDIR/sched/config.conf"

# --- 自动模式的默认配置（config.conf 里可覆盖）---
: "${AUTO_WATCH_INTERVAL:=5}"
: "${AUTO_WATCH_ON_BOOT:=0}"
: "${AUTO_MODE:=1}"
: "${AUTO_MODE_LOW_BATTERY_PCT:=20}"
: "${AUTO_MODE_DEBUG:=0}"
: "${AUTO_MODE_WAKELOCK:=0}"
if [ -z "$PEACE_PACKAGES" ]; then PEACE_PACKAGES="com.tencent.tmgp.pubgmhd com.tencent.tmgp.sgame pubgmhd pubgm sgame gameforpeace"; fi
if [ -z "$VALORANT_PACKAGES" ]; then VALORANT_PACKAGES="com.tencent.tmgp.codev codev valorant playvalorant"; fi
if [ -z "$AUTO_GAME_PACKAGES" ]; then AUTO_GAME_PACKAGES="tmgp.sgame miHoYo HoYoverse unity unreal genshin honkai starrail pubg peace elite wuthering zzz $PEACE_PACKAGES $VALORANT_PACKAGES"; fi
: "${AUTO_CRITICAL_NICE:=0}"
: "${GAME_SCHED_ENABLED:=1}"
# 0.4.14 游戏进程自动检测：1=开（默认）。watch 每轮先扫 /proc 看
# 两款游戏的主进程在不在跑，不只看前台是谁；退出宽限默认 2 轮。
: "${GAME_AUTO_DETECT:=1}"
: "${GAME_EXIT_GRACE_CYCLES:=2}"
# 0.4.16 检测到游戏自动清理后台：1=开（默认）。只清 cached 应用，
# 白名单里的音乐、输入法、GlassMic/MusicMic、启动器、闹钟不动。
# 0.4.17：白名单用 "inputmethod" 子串（讯飞、搜狗都含它，0.4.16 只写
# 了讯飞，结果真机日志里搜狗输入法被清了）；闹钟也加进来（force-stop
# 会取消它设好的闹钟）。
: "${GAME_CLEAN_BACKGROUND:=1}"
if [ -z "$GAME_CLEAN_WHITELIST" ]; then GAME_CLEAN_WHITELIST="com.luna.music com.kugou.android com.tencent.qqmusic com.netease.cloudmusic inputmethod com.baidu.input io.mo.glassmic com.nora.musicmic launcher alarmclock deskclock com.web.czero"; fi
# 0.4.57 游戏后台保活：1=开（默认）。oom 钉位 + 电池白名单 +
# 被杀取证三件都受它总控；watch 每轮用 config_value 现读（和
# GAME_AUTO_DETECT 一个口径，改配置不用重启 watch）。
: "${GAME_KEEPALIVE:=1}"
# 0.4.30 进游戏自动去温控：1=开（默认）。只在手动开关 THERMAL_REMOVE=0
# 时起作用——手动开着就是一直开，自动逻辑不动它。
: "${THERMAL_AUTO_GAME:=1}"
: "${GAME_NICE_PEACE:=-5}"
# O21：死配置已删（config.conf 里没有这个 key，
# nice_for_class 只读 GAME_NICE_PEACE）。
# 哨兵验证（M6）：verify_game_applied / verify_game_restored 由
# lib.sh 提供（回读前台 uclamp.min 与 GPU min_freq 精确比对）。
# C7（0.4.50）：删掉本文件里那两份兜底实现——它们的判据和 lib.sh
# 正版不一致（写死 class/devfreq/kgsl-3d0 路径、只判 min_freq 大于
# 最低 OPP），lib.sh 在时永不触发，但哪天 lib 改了函数名，兜底会
# 用另一套标准判成败且没人发现。缺函数就直接报错退出，不装懂。
if ! command -v verify_game_applied >/dev/null 2>&1 || ! command -v verify_game_restored >/dev/null 2>&1; then
    echo "ERR lib.sh 缺少 verify_game_applied/verify_game_restored，模块文件不完整" >&2
    exit 1
fi

if [ -n "$SCHED_TEST_ROOT" ]; then
    STATEFILE="$SCHED_TEST_ROOT/thread_state"
    WATCH_PIDFILE="$SCHED_TEST_ROOT/thread_watch.pid"
    GAME_SCHED_STATE="$SCHED_TEST_ROOT/game_sched_state"
    AUTO_MODE_STATE="$SCHED_TEST_ROOT/oneplus_auto_mode"
    THERMAL_AUTO_STATE="$SCHED_TEST_ROOT/oneplus_thermal_auto"
else
    STATEFILE="/data/local/tmp/oneplus_thread_state"
    WATCH_PIDFILE="/data/local/tmp/oneplus_thread_watch.pid"
    GAME_SCHED_STATE="/data/local/tmp/oneplus_game_sched_state"
    AUTO_MODE_STATE="/data/local/tmp/oneplus_auto_mode"
    THERMAL_AUTO_STATE="/data/local/tmp/oneplus_thermal_auto"
fi

# 0.4.33：进/退游戏自动去温控已抽到 thermal_auto.sh（S2 统一入口，
# game_sched.sh 和面板都调同一份）。THERMAL_AUTO_STATE 上面已按
# 测试/真机算好，thermal_auto.sh 不会覆盖已设的值。
. "$MODDIR/sched/thermal_auto.sh"

# pid 是否真的是一个在跑的 watch：只看 kill -0 不够——/data/local/tmp
# 跨重启不清，pid 文件里的旧 PID 可能被别的进程重用（0.4.5 实证：
# 重启好几遍仍报“watch 已在运行（PID 8936）”，新 watch 一直起不来）。
# 认 /proc/<pid>/cmdline 里同时有 thread.sh 和 watch 才算；读不到
# cmdline 或对不上号的，一律当残留 pid 文件处理。
_watch_pid_alive() {
    _wp="$1"
    [ -n "$_wp" ] || return 1
    kill -0 "$_wp" 2>/dev/null || return 1
    _wc=$( { tr '\0' ' ' < "/proc/$_wp/cmdline"; } 2>/dev/null )
    case "$_wc" in
        *thread.sh*watch*) return 0 ;;
        *) return 1 ;;
    esac
}

# ================= 0.4.7 自动模式（AUTO_MODE） =================
# 非游戏时，watch 每轮按屏幕/电量自动选基础模式。规则（按优先级）：
#   1. 前台是游戏 → 不动（调用方已排除游戏，游戏档自己管）。
#   2. 屏幕灭 → powersave。
#   3. 电量 <= AUTO_MODE_LOW_BATTERY_PCT 且正在放电 → powersave。
#   4. 否则 → config.conf 的 MODE（默认 balanced）。
# 永远不自动切 performance；只在目标和上次自动应用的不同时才调
# apply_sched.sh，并记一行 INFO auto-mode 日志。

# 从 config.conf 读一个 KEY 的当前值（watch 启动后用户可能经面板
# 改过，不能只用启动时 load 的旧值）。读不到返回空。
config_value() {
    _k="$1"
    grep "^$_k=" "$MODDIR/sched/config.conf" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '"\r' | tr -d ' \t'
}

# 电池电量（0-100），读不到/非数字返回空
battery_capacity() {
    _c=$(read_node "$SYS/class/power_supply/battery/capacity" 2>/dev/null)
    _c=$(printf '%s' "$_c" | tr -d ' \t\r\n')
    case "$_c" in ''|*[!0-9]*) echo "" ;; *) echo "$_c" ;; esac
}

# 电池状态（Charging / Discharging / Full / Not charging），读不到返回空
battery_status() {
    _s=$(read_node "$SYS/class/power_supply/battery/status" 2>/dev/null)
    printf '%s' "$_s" | tr -d ' \t\r\n'
}

# 屏幕状态：on / off / unknown。dumpsys power 的格式在不同版本/厂商
# 上可能不同，依次试几个已知模式；都对不上就返回 unknown（调用方
# 按亮屏处理，绝不因信号不明而误切省电）。一次 dumpsys 只跑一遍，
# 结果复用，不在同轮里重复调。
# 0.4.13：不许再用 printf '%s' "$_sp" 传整份 dumpsys 输出——
# 0.4.12 日志实证：dumpsys power 的输出能到几百 KB，单个参数超过
# 128KB 上限（/system/bin/printf: Argument list too long），82 次、
# 每次 5 个探测全灭，屏幕状态返回 unknown、灭屏切换被拖到下一轮。
# 改成先落到临时文件再 grep，dumpsys 仍只跑一遍。
screen_state() {
    command -v dumpsys >/dev/null 2>&1 || { echo "unknown"; return 0; }
    _spf="${TMPDIR:-/data/local/tmp}/oneplus_sched_ss.$$"
    _res="unknown"
    if dumpsys power > "$_spf" 2>/dev/null && [ -s "$_spf" ]; then
        _line=$(grep -i "Display Power: state=" "$_spf" | head -n 1)
        case "$_line" in
            *state=OFF*) _res="off" ;;
            *state=ON*) _res="on" ;;
        esac
        if [ "$_res" = "unknown" ]; then
            _line=$(grep -i "mScreenOn=" "$_spf" | head -n 1)
            case "$_line" in
                *mScreenOn=false*) _res="off" ;;
                *mScreenOn=true*) _res="on" ;;
            esac
        fi
        if [ "$_res" = "unknown" ]; then
            _line=$(grep -i "isScreenOn=" "$_spf" | head -n 1)
            case "$_line" in
                *isScreenOn=false*) _res="off" ;;
                *isScreenOn=true*) _res="on" ;;
            esac
        fi
        # 0.4.9：ColorOS 的 dumpsys power 里上面三种都没有（0.4.8 日志
        # screen=unknown）。再试 mWakefulness 和 mHoldingDisplaySuspendBlocker。
        if [ "$_res" = "unknown" ]; then
            _line=$(grep -i "mWakefulness=" "$_spf" | head -n 1)
            case "$_line" in
                *mWakefulness=Awake*) _res="on" ;;
                *mWakefulness=Asleep*|*mWakefulness=Dozing*|*mWakefulness=Dreaming*) _res="off" ;;
            esac
        fi
        if [ "$_res" = "unknown" ]; then
            _line=$(grep -i "mHoldingDisplaySuspendBlocker=" "$_spf" | head -n 1)
            case "$_line" in
                *mHoldingDisplaySuspendBlocker=true*) _res="on" ;;
                *mHoldingDisplaySuspendBlocker=false*) _res="off" ;;
            esac
        fi
    fi
    rm -f "$_spf" 2>/dev/null
    echo "$_res"
}

# 屏幕是否灭（screen_state 的布尔包装，旧调用点兼容）。
screen_is_off() {
    [ "$(screen_state)" = "off" ]
}

# 每轮调用一次。决定目标模式并在变化时应用。
# 0.4.8：AUTO_MODE / 阈值 / DEBUG 每次都从 config.conf 重读（watch
# 启动后用户经面板改过也能立即生效，不用重启 watch）；屏幕状态一次
# dumpsys 复用；DEBUG=1 时每分钟最多记一行 check 日志。
auto_mode_tick() {
    _am=$(config_value AUTO_MODE)
    case "$_am" in "" ) _am=1 ;; esac
    [ "$_am" = "1" ] || return 0
    # S3：屏幕状态每 6 轮查一次 dumpsys，中间轮次沿用上次结果（watch
    # 每 5 秒一轮，一小时 720 次 dumpsys power 太浪费；屏幕状态一秒
    # 变一次都嫌多）。缓存变量未设置时走正常路径。
    if [ -n "${_SCREEN_CACHE:-}" ] && [ "${_SCREEN_CACHE_AGE:-0}" -lt 6 ]; then
        _screen="$_SCREEN_CACHE"
        _SCREEN_CACHE_AGE=$((_SCREEN_CACHE_AGE + 1))
    else
        _screen=$(screen_state)
        _SCREEN_CACHE="$_screen"
        _SCREEN_CACHE_AGE=1
    fi
    _cap=$(battery_capacity)
    _st=$(battery_status)
    _low=$(config_value AUTO_MODE_LOW_BATTERY_PCT)
    case "$_low" in ''|*[!0-9]*) _low=20 ;; esac
    _target=""; _reason=""
    if [ "$_screen" = "off" ]; then
        _target="powersave"; _reason="screen-off"
    elif [ -n "$_cap" ] && [ "$_cap" -le "$_low" ] && [ "$_st" = "Discharging" ]; then
        _target="powersave"; _reason="low-battery"
    else
        _base=$(config_value MODE)
        case "$_base" in balanced|performance|powersave) ;; *) _base="balanced" ;; esac
        _target="$_base"; _reason="normal"
    fi
    # 调试日志：AUTO_MODE_DEBUG=1 时每分钟最多一行，让“静默的 watch”
    # 也能被诊断（屏幕/电量/目标/已应用）。默认关，正常日志保持干净。
    # 0.4.9：screen=unknown 时附一段 dumpsys power 的原文（只取含
    # display/screen/wake/power 的行，最多 3 行），这样下次直接从
    # 日志就能看到这台 ColorOS 的真实格式，不用再让用户跑命令。
    _dbg=$(config_value AUTO_MODE_DEBUG)
    if [ "$_dbg" = "1" ]; then
        _now=$(date +%s)
        if [ -z "$_LAST_DEBUG_LOG" ] || [ $((_now - _LAST_DEBUG_LOG)) -ge 60 ]; then
            if [ "$_screen" = "unknown" ]; then
                _ev=$(dumpsys power 2>/dev/null | grep -i "display\|screen\|wakefulness\|suspendblocker\|power state" | head -n 3 | tr '\n' '|' | tr -s ' ' | cut -c1-300)
                sched_log "INFO auto-mode check screen=$_screen battery=${_cap:-?}%/${_st:-?} target=$_target applied=${_AUTO_APPLIED:-?} evidence=${_ev:-none}"
            else
                sched_log "INFO auto-mode check screen=$_screen battery=${_cap:-?}%/${_st:-?} target=$_target applied=${_AUTO_APPLIED:-?}"
            fi
            _LAST_DEBUG_LOG="$_now"
        fi
    fi
    if [ "$_target" != "$_AUTO_APPLIED" ]; then
        # 0.4.12：apply_sched.sh 的每行输出 sched_log 自己已经写进
        # 日志文件一份了，这里再 >> 到日志就是第二份（0.4.11 日志
        # 里 OK/SKIP/FAIL 各出现 4141 次，全是这么翻倍的）。改丢
        # 到 /dev/null，日志里只留 sched_log 的一份。
        sh "$MODDIR/sched/apply_sched.sh" "$_target" >/dev/null 2>&1 || true
        _AUTO_APPLIED="$_target"
        echo "$_target" > "$AUTO_MODE_STATE" 2>/dev/null || true
        sched_log "INFO auto-mode $_reason -> $_target"
    fi
}

# 0.4.8：自动模式用的部分唤醒锁（默认关，AUTO_MODE_WAKELOCK=1 才开）。
# 原理：watch 是轮询进程，灭屏后系统休眠（doze）会把它冻住，导致
# 屏幕灭了它也跑不起来、永远检测不到 screen-off。持锁能让它在灭屏
# 时继续跑、可靠地切省电，但代价是设备无法深度休眠、耗电上升——
# 省电模式省的那点电可能还抵不上持锁的消耗。所以默认关，只给确实
# 需要“灭屏必切省电”的用户手动开。开之前想清楚：这是拿耗电换可靠。
_WAKELOCK_NAME="oneplus_sched_watch"
_wakelock_acquire() {
    [ -w "$SYS/power/wake_lock" ] || return 1
    echo "$_WAKELOCK_NAME" > "$SYS/power/wake_lock" 2>/dev/null || return 1
    return 0
}
_wakelock_release() {
    [ -w "$SYS/power/wake_unlock" ] || return 1
    echo "$_WAKELOCK_NAME" > "$SYS/power/wake_unlock" 2>/dev/null || return 1
    return 0
}

# --force 既可以是环境变量 FORCE=1，也可以是命令行参数
for _a in "$@"; do
    if [ "$_a" = "--force" ]; then FORCE=1; fi
done

usage() {
    echo "用法:"
    echo "  thread.sh detect | gamedetect | auto [game|daily|background] [--dry-run]"
    echo "  thread.sh game on|off"
    echo "  thread.sh watch [秒数] [game|daily] | stop"
    echo "  thread.sh list|bind|unbind|prio|profile <包名或PID> [参数]"
    echo "示例: thread.sh detect"
    echo "      thread.sh auto --dry-run"
    echo "      thread.sh game on"
    echo "      thread.sh watch 5"
    exit 2
}

# 测试模式（SCHED_TEST_ROOT 已设置）跳过 root 检查，方便在模拟 proc 下验证；
# 真机上没有这个变量，仍要求 root。
if [ -z "$SCHED_TEST_ROOT" ]; then
    [ "$(id -u 2>/dev/null)" = "0" ] || { echo "需要 root：先 su 再跑"; exit 1; }
fi
command -v taskset >/dev/null 2>&1 || { echo "找不到 taskset，本机 toybox 不支持绑核"; exit 1; }

detect_clusters

# ================= 包名 / PID 解析 =================

# 包名 -> PID（pidof 优先，ps 兜底）
resolve_pid() {
    _target="$1"
    case "$_target" in
        ''|*[!0-9]*) ;;
        *) if [ -d "$PROC/$_target" ]; then echo "$_target"; return 0; fi ;;
    esac
    _pid=$(pidof "$_target" 2>/dev/null | awk '{print $1}')
    if [ -n "$_pid" ]; then echo "$_pid"; return 0; fi
    _pid=$(ps -A -o PID,NAME 2>/dev/null | awk -v n="$_target" '$2==n {print $1; exit}')
    if [ -n "$_pid" ]; then echo "$_pid"; return 0; fi
    echo ""
}

# PID -> 包名：先读 cmdline（完整包名），读不到再用 comm（会被截断到 15 字）
package_from_pid() {
    _pid="$1"
    if [ -r "$PROC/$_pid/cmdline" ]; then
        _cmd=$( { tr '\0' ' ' < "$PROC/$_pid/cmdline"; } 2>/dev/null )
        set -- $_cmd
        if [ -n "$1" ]; then echo "$1"; return 0; fi
    fi
    cat "$PROC/$_pid/comm" 2>/dev/null
}

is_valid_package() {
    _p="$1"
    case "$_p" in
        ""|*/*|*" "*|*"{"*|*"}"*) return 1 ;;
        *.*) return 0 ;;
        *) return 1 ;;
    esac
}

# 从 dumpsys 的一行里抠包名：逐词找 "包名/..." 这种词，取 / 前面那段。
# 不依赖 sed 正则，ColorOS / 不同 Android 版本的 dumpsys 格式都能处理。
pkg_from_line() {
    _line="$1"
    for _w in $_line; do
        case "$_w" in
            */*)
                _cand="${_w%%/*}"
                _cand="${_cand##*\{}"
                _cand="${_cand##*\(}"
                if is_valid_package "$_cand"; then echo "$_cand"; return 0; fi
                ;;
        esac
    done
    echo ""
}

# dumpsys 识别：kind=window 或 activity，返回包名或空
pkg_from_dumpsys() {
    _kind="$1"
    command -v dumpsys >/dev/null 2>&1 || return 0
    _out=$(dumpsys "$_kind" 2>/dev/null | grep -e "mCurrentFocus" -e "mFocusedApp" -e "mResumedActivity" -e "topResumedActivity" 2>/dev/null | head -n 8)
    if [ -z "$_out" ]; then return 0; fi
    echo "$_out" | while IFS= read -r _line; do
        _p=$(pkg_from_line "$_line")
        if [ -n "$_p" ]; then echo "$_p"; return 0; fi
    done
}

# 系统关键进程：自动模式永远不碰
# 0.4.2：加上 zygote / usap / webview_zygote。zygote64 是所有应用的
# 父进程，它的 cgroup 里也带 top-app，0.4.1 的 cpuset 扫描按 PID
# 顺序先扫到它，就把它当成了前台应用（0.4.1 日志实证）。
is_denied() {
    _pkg="$1"; _comm="$2"
    case "$_pkg" in
        system_server|surfaceflinger|android|com.android.systemui|com.android.phone|com.android.settings|com.coloros.safecenter|zygote|zygote64|usap32|usap64|webview_zygote) return 0 ;;
    esac
    case "$_comm" in
        system_server|surfaceflinger|android|systemui|zygote|zygote64|usap32|usap64|webview_zygote) return 0 ;;
    esac
    return 1
}

# 输入法：键盘弹起时它会短暂成为前台，但它只是盖在游戏上的浮层，
# 不是用户在用的应用。watch 识别到它时不切换、不绑核、不切调度。
is_ime() {
    case "$1" in
        *inputmethod*|*InputMethod*) return 0 ;;
    esac
    return 1
}

# cpuset 扫描：找 cgroup 里带 top-app 的第一个非系统进程
# 0.4.2：同一组里可能同时有游戏和输入法（键盘弹起时），优先取
# oom_score_adj==0 的那个（真前台）；都没有 0 时取第一个。
# zygote 已由 is_denied 排除，不会再被当成前台。
scan_cgroup_top_app() {
    _first=""; _fg=""
    for _d in "$PROC"/[0-9]*; do
        [ -d "$_d" ] || continue
        # 内核线程没有 /proc/PID/mm（用户进程都有）；/proc/PID/comm 里
        # 没有方括号（方括号是 ps 显示时加的），只靠 comm 的 "[" 判断拦不住。
        [ -e "$_d/mm" ] || continue
        _pid="${_d##*/}"
        [ -f "$_d/cgroup" ] || continue
        grep -q "top-app" "$_d/cgroup" 2>/dev/null || continue
        _comm=$(cat "$_d/comm" 2>/dev/null)
        case "$_comm" in "["*) continue ;; esac
        _pkg=$(package_from_pid "$_pid")
        if is_denied "$_pkg" "$_comm"; then continue; fi
        if [ -z "$_first" ]; then _first="$_pid"; fi
        if [ -f "$_d/oom_score_adj" ]; then
            _adj=$(cat "$_d/oom_score_adj" 2>/dev/null)
            if [ "$_adj" = "0" ]; then _fg="$_pid"; break; fi
        fi
    done
    if [ -n "$_fg" ]; then echo "$_fg"; return 0; fi
    echo "$_first"
}

# oom 扫描：oom_score_adj == 0 的一般就是前台应用（system_server 是负数）
# 0.4.22：内核线程的 oom_score_adj 也是 0，且 /proc/PID/comm 里没有
# 方括号，旧的 "[" 判断拦不住 kworker——13:35/13:44/13:55 三次把它当成
# 前台绑核，全败 EINVAL。改成没有 /proc/PID/mm 的一律跳过（内核线程
# 没有 mm，用户进程都有）。
scan_oom_foreground() {
    for _d in "$PROC"/[0-9]*; do
        [ -d "$_d" ] || continue
        [ -e "$_d/mm" ] || continue
        _pid="${_d##*/}"
        [ -f "$_d/oom_score_adj" ] || continue
        _adj=$(cat "$_d/oom_score_adj" 2>/dev/null)
        [ "$_adj" = "0" ] || continue
        _comm=$(cat "$_d/comm" 2>/dev/null)
        case "$_comm" in "["*) continue ;; esac
        _pkg=$(package_from_pid "$_pid")
        if is_denied "$_pkg" "$_comm"; then continue; fi
        echo "$_pid"; return 0
    done
    echo ""
}

# 前台识别：设置全局 DETECTED_PKG / DETECTED_PID / DETECT_METHOD
# order=full（dumpsys 优先，准）或 cheap（cpuset/oom 优先，快，watch 用）
detect_foreground() {
    _order="${1:-full}"
    DETECTED_PKG=""; DETECTED_PID=""; DETECT_METHOD=""
    _try_dumpsys() {
        _pkg=$(pkg_from_dumpsys window)
        if [ -z "$_pkg" ]; then _pkg=$(pkg_from_dumpsys activity); fi
        if [ -n "$_pkg" ]; then
            _pid=$(resolve_pid "$_pkg")
            if [ -n "$_pid" ] && [ -d "$PROC/$_pid" ]; then
                _comm=$(cat "$PROC/$_pid/comm" 2>/dev/null)
                if ! is_denied "$_pkg" "$_comm"; then
                    DETECTED_PKG="$_pkg"; DETECTED_PID="$_pid"; DETECT_METHOD="dumpsys"
                    return 0
                fi
            fi
        fi
        return 1
    }
    _try_cheap() {
        _pid=$(scan_cgroup_top_app)
        if [ -z "$_pid" ]; then _pid=$(scan_oom_foreground); DETECT_METHOD="oom"; else DETECT_METHOD="cpuset/top-app"; fi
        if [ -n "$_pid" ]; then
            DETECTED_PID="$_pid"
            DETECTED_PKG=$(package_from_pid "$_pid")
            return 0
        fi
        return 1
    }
    if [ "$_order" = "cheap" ]; then
        _try_cheap || _try_dumpsys
    else
        _try_dumpsys || _try_cheap
    fi
    if [ -n "$DETECTED_PID" ]; then
        sched_log "INFO detect method=$DETECT_METHOD pkg=$DETECTED_PKG pid=$DETECTED_PID"
        return 0
    fi
    sched_log "WARN detect 失败：dumpsys / cpuset / oom 三路都没找到前台应用"
    return 1
}

# ================= 线程分类 =================

# 线程分类：main / game / render / rhi / taskgraph / audio / net / input /
#           binder / worker / other
# 注意 comm 在内核里截断到 15 字，所以只按子串匹配，不按全名相等。
# 顺序重要：GameThread 先于泛 Game，RHIThread 先于 Render，TaskGraph
# 先于泛 Worker，音频/语音先于泛 Worker（Voice 线程名里常带 pool 字样
# 的变体很少，但 AudioMixer 之类必须先判）。
classify_thread() {
    _tid="$1"; _comm="$2"; _pid="$3"
    if [ "$_tid" = "$_pid" ]; then echo "main"; return 0; fi
    case "$_comm" in
        *GameThread*|*Game*Thread*|*Gamethread*)
            echo "game"; return 0 ;;
        *RHIThread*|*RHI*|*Vulkan*|*vulkan*)
            echo "rhi"; return 0 ;;
        *RenderThread*|*Render*|*render*|*HWUI*|*Hwui*|*hwui*|*Gfx*|*GLThread*|*Adreno*|*GPU*)
            echo "render"; return 0 ;;
        *TaskGraph*|*Taskgraph*|*taskgraph*|*Physics*|*PhysX*|*Streaming*|*AsyncLoading*)
            echo "taskgraph"; return 0 ;;
        *Audio*|*audio*|*AAudio*|*OpenSL*|*Sound*|*sound*|*Voice*|*voice*|*GME*|*Mic*|*VoIP*|*AudioMixer*)
            echo "audio"; return 0 ;;
        *Network*|*network*|*NetThread*|*Socket*|*socket*|*TNet*|*Http*)
            echo "net"; return 0 ;;
        *Input*|*input*|*Touch*|*touch*)
            echo "input"; return 0 ;;
        *Binder*|*binder*)
            echo "binder"; return 0 ;;
        *Unity*|*unity*|*Unreal*|*unreal*)
            echo "render"; return 0 ;;
        *pool*|*Pool*|*Worker*|*worker*|*Async*|*async*|*OkHttp*|*Download*|*download*|*Sync*|*sync*|*IOThread*|*FileIO*)
            echo "worker"; return 0 ;;
        main)
            echo "main"; return 0 ;;
        *)
            echo "other"; return 0 ;;
    esac
}

# 线程名里有没有游戏引擎的痕迹（用来判断是不是游戏）
# 0.4.2：去掉 RenderThread 和 Gfx——所有带硬件加速界面的应用都有
# HWUI RenderThread（MusicMic、输入法都有），不能当游戏证据，
# 0.4.1 因此把非游戏应用误判成 game。只留引擎专属标记：
# Unity / Unreal / Vulkan / Game / RHIThread / TaskGraph。
threads_look_like_game() {
    _pid="$1"
    for _t in "$PROC/$_pid"/task/*; do
        _c=$(cat "$_t/comm" 2>/dev/null)
        case "$_c" in
            *Unity*|*unity*|*Unreal*|*unreal*|*Vulkan*|*Game*|*RHIThread*|*TaskGraph*) return 0 ;;
        esac
    done
    return 1
}

# 档位：game 是唯一的游戏档。和平精英 com.tencent.tmgp.pubgmhd、
# 无畏契约 com.tencent.tmgp.codev 都返回 game。
profile_for_package() {
    _pkg="$1"; _pid="$2"
    if [ -n "$PROFILE_OVERRIDE" ]; then
        case "$PROFILE_OVERRIDE" in peace|valorant) echo "game"; return 0 ;; esac
        echo "$PROFILE_OVERRIDE"; return 0
    fi
    for _pat in $PEACE_PACKAGES $VALORANT_PACKAGES; do
        case "$_pkg" in *"$_pat"*) echo "game"; return 0 ;; esac
    done
    for _pat in $AUTO_GAME_PACKAGES; do
        case "$_pkg" in *"$_pat"*) echo "game"; return 0 ;; esac
    done
    case "$_pkg" in *game*|*Game*) echo "game"; return 0 ;; esac
    if [ -n "$_pid" ] && threads_look_like_game "$_pid"; then echo "game"; return 0; fi
    echo "daily"
}

# 进程级游戏检测（0.4.14）：不看前台是谁，直接扫 /proc 里有没有
# 两款游戏的主进程在跑。cmdline 首字段就是完整包名（comm 只截
# 到 15 字，pidof 对不上全包名，所以必须读 cmdline）；只认完整包名
# 精确相等，带 ":xxx" 后缀的子进程（推送、SDK）不算——主进程退出、
# 只剩子进程时不该继续占着游戏档。
# 设全局 GAME_RUNNING_PID / GAME_RUNNING_PKG / GAME_RUNNING_PROFILE
# （0.4.15 起只有 game 一个值），没找到三者都为空，返回 1。
# 0.4.15：先 grep -l 一次扫出带包名的 cmdline 候选（一个 fork），
# 再逐个验首字段精确相等。0.4.14 是逐 PID fork 一次 tr，600 个进程
# 就是 600 次 fork，实测 1.27 秒，grep -l 只要 0.025 秒——watch
# 每 5 秒一轮 + panel.sh status 都调它，慢扫会拖慢面板。
scan_running_games() {
    GAME_RUNNING_PID=""; GAME_RUNNING_PKG=""; GAME_RUNNING_PROFILE=""
    _pats=""
    for _pat in $PEACE_PACKAGES $VALORANT_PACKAGES; do
        case "$_pat" in *.*) _pats="$_pats -e $_pat" ;; esac
    done
    [ -n "$_pats" ] || return 1
    if command -v grep >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        _cands=$(grep -l $_pats "$PROC"/[0-9]*/cmdline 2>/dev/null)
    else
        _cands=""
        for _d in "$PROC"/[0-9]*; do
            [ -f "$_d/cmdline" ] && _cands="$_cands $_d/cmdline"
        done
    fi
    for _f in $_cands; do
        _d="${_f%/cmdline}"; _pid="${_d##*/}"
        # 0.4.17：进程可能在 grep 和 tr 之间退出，< 重定向失败时
        # shell 会把 "can't open /proc/.../cmdline" 吵到日志里（真机
        # 日志里 115 条都是这个）。先判可读，读的动作再包一层
        # { ...; } 2>/dev/null，让失败的报错也进 /dev/null。
        [ -r "$_f" ] || continue
        _cmd=$( { tr '\0' ' ' < "$_f"; } 2>/dev/null )
        set -- $_cmd
        [ -n "$1" ] || continue
        for _pat in $PEACE_PACKAGES $VALORANT_PACKAGES; do
            case "$_pat" in *.*) ;; *) continue ;; esac
            if [ "$1" = "$_pat" ]; then
                GAME_RUNNING_PID="$_pid"; GAME_RUNNING_PKG="$1"; GAME_RUNNING_PROFILE="game"
                return 0
            fi
        done
    done
    return 1
}

# 类别 + 档位 -> 策略名（再由 policy_to_mask 换成掩码，核号不写死）
# prime = 超大核单核（X4），big = 大核+超大核，mid = 大核，mid_little = 大核+小核。
# 游戏档（和平精英长局大逃杀 + 无畏契约 5v5 共用，原来和平精英那套）：
# GameThread 独占超大核防迁移，Render/RHI 上大核，TaskGraph/流式加载
# 放中核（放小核会加载卡顿），语音/网络放中核，后台工人放中核。
policy_for_class() {
    _profile="$1"; _class="$2"
    case "$_profile" in
        game)
            case "$_class" in
                main|game) echo "prime" ;;
                rhi|render|input) echo "big" ;;
                taskgraph|audio|net) echo "mid" ;;
                binder) echo "mid_little" ;;
                worker) echo "mid" ;;
                *) echo "mid_little" ;;
            esac
            ;;
        background)
            echo "little"
            ;;
        *)
            case "$_class" in
                main|game|rhi|render|input) echo "big" ;;
                audio|net) echo "mid" ;;
                binder) echo "mid_little" ;;
                taskgraph|worker) echo "little" ;;
                *) echo "all" ;;
            esac
            ;;
    esac
}

# 游戏档的关键线程 nice 值（只在 auto_bind_pid 里用）
nice_for_class() {
    _profile="$1"; _class="$2"
    case "$_profile" in
        game)
            case "$_class" in main|game) echo "$GAME_NICE_PEACE" ;; *) echo "0" ;; esac
            ;;
        *)
            case "$_class" in main) echo "$AUTO_CRITICAL_NICE" ;; *) echo "0" ;; esac
            ;;
    esac
}

# --- 游戏调度模式切换（只在 GAME_SCHED_ENABLED=1 时生效，幂等）---
# apply_game_sched game：调 apply_sched.sh game，记状态。
# peace / valorant 是 on 的别名。restore_game_sched：切回 config.conf
# 的 MODE（默认 balanced），清状态。
apply_game_sched() {
    _mode="$1"
    if [ "$GAME_SCHED_ENABLED" != "1" ]; then return 0; fi
    case "$_mode" in game|peace|valorant) _mode="game" ;; *) return 0 ;; esac
    if [ -f "$GAME_SCHED_STATE" ] && [ "$(cat "$GAME_SCHED_STATE" 2>/dev/null)" = "$_mode" ]; then return 0; fi
    # 0.4.12：同 auto_mode_tick，stdout 丢 /dev/null 防日志翻倍。
    sh "$MODDIR/sched/apply_sched.sh" "$_mode" >/dev/null 2>&1 || true
    # M6：写状态前回读哨兵验证——apply_sched.sh 自身几乎永远 exit 0，
    # 只凭退出码看不出 sysfs 写没写进去。验证通过才写状态文件、记 INFO、
    # 开自动去温控；验证失败不写状态、不开去温控，记 FAIL 并 return 1，
    # watch 下轮会重试（每轮失败只记一行 FAIL）。
    if verify_game_applied; then
        echo "$_mode" > "$GAME_SCHED_STATE" 2>/dev/null || true
        sched_log "INFO game sched applied mode=$_mode"
        # 0.4.30：切进游戏档 → 自动去温控（THERMAL_AUTO_GAME=1 且手动开关关着时）。
        thermal_auto_on
        return 0
    fi
    sched_log "FAIL game sched apply 失败（哨兵验证未通过），下轮重试"
    return 1
}
restore_game_sched() {
    if [ "$GAME_SCHED_ENABLED" != "1" ]; then return 0; fi
    if [ ! -f "$GAME_SCHED_STATE" ]; then return 0; fi
    # M17：现读 config 的 MODE，不用 watch 启动时加载的旧值（用户在
    # watch 运行期间改了 MODE，退游戏要切回新值）。非法值回退 balanced。
    _restore=$(config_value MODE)
    case "$_restore" in balanced|performance|powersave) ;; *) _restore="balanced" ;; esac
    # 0.4.12：同上，stdout 丢 /dev/null 防日志翻倍。
    sh "$MODDIR/sched/apply_sched.sh" "$_restore" >/dev/null 2>&1 || true
    # 0.4.35：反向验证——切回后游戏档数值必须已撤销。verify_game_restored
    # 返回 1 = 前台 uclamp 仍是 77 或 GPU 下限仍是抬高值（或哨兵节点
    # 读回非数字，无法确认），restore 失败：状态文件保留（它如实反映
    # 游戏档数值还在），不关去温控（下次进游戏时 apply 会因状态已是
    # game 而直接返回，去温控必须保持开着，否则新一局没去温控），
    # 记 FAIL 并 return 1，调用方（game off 命令）据此报错。
    # 注意：watch 循环调 restore 时不看返回值（只看状态文件），所以
    # 这里返回 1 不会破坏 watch；watch 也不会重试 restore（退游戏时
    # 只调一次），失败要靠日志 + 面板状态发现，手动再跑一次 game off。
    if ! verify_game_restored; then
        sched_log "FAIL game sched restore 失败（游戏档数值未撤销 mode=$_restore），状态文件保留"
        return 1
    fi
    rm -f "$GAME_SCHED_STATE" 2>/dev/null || true
    sched_log "INFO game sched restored mode=$_restore"
    # 0.4.30：切回基础档 → 自动关去温控（之前是自动开的才关）。
    thermal_auto_off
}

# （进/退游戏自动去温控已抽到 sched/thermal_auto.sh，见文件头 source；
# 规则不变：THERMAL_AUTO_GAME=1 且手动开关关着时才自动开/关。）

# --- 检测到游戏时自动清理后台（0.4.16 加，0.4.17 大修）---
# 只清一次（每次进游戏会话）：只动 cached 应用（oom_score_adj >= 900，
# 也就是系统已经把它扔到后台缓存里的），不动正在用的。
# 不动：游戏自己（主进程和 :xxx 子进程）、白名单（音乐四款、输入法、
# GlassMic/MusicMic、启动器、闹钟）、系统应用、uid < 10000 的、
# 包名不合法的。清法是 am force-stop 整个包（下次打开自动重起，
# 消息推送不受影响）。
# 0.4.16 的教训（2026-11-16 05:20 真机日志）：uid >= 10000 拦不住
# 系统应用——Play 商店、权限控制器、闹钟、日历这些系统应用的 uid
# 也在 10000 以上，一次清了 37 个，连闹钟（force-stop 会取消它设
# 好的闹钟）和搜狗输入法（白名单里只有讯飞）都杀了。所以 0.4.17
# 改成 pm list packages -s 一次取齐系统包名单，命中就跳过；没有 pm
# 时用厂商前缀兜底。包名也要先过三关：:xxx 子进程只留主包名、
# 必须字母开头带点、不能以点开头（.adservices 这种是 argv[0] 的
# 后缀，不是包名，am force-stop 它是错的）。
clean_background_apps() {
    _game_pkg="$1"
    [ "$GAME_CLEAN_BACKGROUND" = "1" ] || return 0
    command -v am >/dev/null 2>&1 || { sched_log "WARN 清理后台：找不到 am，跳过"; return 0; }
    # 系统包名单：一次 pm 调用取齐，拼成 " package:a package:b "，
    # 两边带空格才能精确匹配（不带空格会把 com.foo 误判进 com.foo.bar）。
    _sys_pkgs=" "
    if command -v pm >/dev/null 2>&1; then
        _sys_pkgs=" $(pm list packages -s 2>/dev/null | tr '\n' ' ')"
    fi
    _cleaned=""
    for _d in "$PROC"/[0-9]*; do
        [ -d "$_d" ] || continue
        [ -r "$_d/oom_score_adj" ] || continue
        { IFS= read -r _adj < "$_d/oom_score_adj"; } 2>/dev/null || continue
        case "$_adj" in ''|*[!0-9]*) continue ;; esac
        [ "$_adj" -ge 900 ] || continue
        [ -r "$_d/cmdline" ] || continue
        _cmd=$( { tr '\0' ' ' < "$_d/cmdline"; } 2>/dev/null )
        set -- $_cmd
        [ -n "$1" ] || continue
        _pkg="$1"
        # 子进程只留主包名：com.foo:bar → com.foo。
        _pkg="${_pkg%%:*}"
        # 包名必须合法：字母开头、带点、不以点开头、只含字母数字点下划线。
        # 注意：dash 里取反是 [!...]，[^...] 是字面量（含 ^ 本身）——
        # 0.4.17 第一版写了 [^a-zA-Z0-9._]，在 dash 下等于“含任意字母
        # 就跳过”，结果一个应用都清不掉（bash 下没问题，坑就坑在这）。
        case "$_pkg" in
            .*|*..*) continue ;;
            *[!a-zA-Z0-9._]*) continue ;;
            *.*) ;;
            *) continue ;;
        esac
        case "$_pkg" in "$_game_pkg") continue ;; esac
        # 系统应用：pm 名单精确匹配 + 厂商前缀兜底（没 pm 时也拦得住）。
        case "$_sys_pkgs" in *" package:$_pkg "*) continue ;; esac
        case "$_pkg" in com.android.*|com.google.android.*|com.coloros.*|com.oplus.*|com.heytap.*|com.oppo.*|android.*) continue ;; esac
        _wl=0
        for _w in $GAME_CLEAN_WHITELIST; do
            case "$_pkg" in *"$_w"*) _wl=1; break ;; esac
        done
        [ "$_wl" = "1" ] && continue
        _uid=""
        { while IFS= read -r _line; do
            case "$_line" in Uid:*) set -- ${_line#Uid:}; _uid="$1"; break ;; esac
        done < "$_d/status"; } 2>/dev/null
        case "$_uid" in ''|*[!0-9]*) continue ;; esac
        [ "$_uid" -ge 10000 ] || continue
        case " $_cleaned " in *" $_pkg "*) continue ;; esac
        _cleaned="$_cleaned $_pkg"
    done
    _n=0
    for _pkg in $_cleaned; do
        if am force-stop "$_pkg" >/dev/null 2>&1; then
            sched_log "INFO 清理后台：force-stop $_pkg"
            _n=$((_n + 1))
        else
            sched_log "WARN 清理后台失败：$_pkg"
        fi
    done
    if [ "$_n" -gt 0 ]; then sched_log "INFO 清理后台完成：清了 $_n 个应用"; else sched_log "INFO 清理后台：没有可清的 cached 应用"; fi
}

# --- 游戏后台保活（0.4.57，都受 GAME_KEEPALIVE 总控）---
# 她反馈：切到别的 App 两三分钟，回来游戏已被杀、要重新进。
# 杀进程分两种：内存回收型（LMK 按 oom_score_adj 从高到低杀）
# 和厂商策略强杀（ColorOS 后台管理直接 force-stop）。前者能挡
# （下面 ①②）；后者 0.4.59 补了 ④ 系统级放行断言尽量降概率，
# 真被杀靠 ③ 留证据分清（主力解法仍是系统设置里的开关）。

# ① oom 钉位：把游戏主进程的 oom_score_adj 钉在 -1000（取值
# 范围 -1000..1000，越低越晚被 LMK 选中，-1000 是最低被杀位）。
# watch 游戏模式期间每轮调一次：已经是 -1000 就不重复写；游戏
# 换 PID 时调用方传新 PID，自然跟着走。进程级设置，进程死了
# 自动没，不需要恢复动作。写失败（SELinux / 进程刚好退出）只
# 记一行 WARN——同一个 PID 只记一次，不每轮刷屏；写成功后把
# 已记标记清掉，下一个 PID 失败还能再记。
_OOM_PIN_WARNED_PID=""
keepalive_pin_game_oom() {
    _pid="$1"
    [ -n "$_pid" ] || return 0
    _f="$PROC/$_pid/oom_score_adj"
    [ -r "$_f" ] || return 0
    { IFS= read -r _adj < "$_f"; } 2>/dev/null || return 0
    # 带符号整数校验（-1000..1000；读回非数字直接跳过，别拿去比较）。
    _n="$_adj"
    case "$_n" in -*) _n="${_n#-}" ;; esac
    case "$_n" in ''|*[!0-9]*) return 0 ;; esac
    [ "$_adj" -gt -1000 ] || return 0
    if printf '%s' "-1000" > "$_f" 2>/dev/null; then
        _OOM_PIN_WARNED_PID=""
        return 0
    fi
    if [ "$_OOM_PIN_WARNED_PID" != "$_pid" ]; then
        _OOM_PIN_WARNED_PID="$_pid"
        sched_log "WARN 保活：写游戏 oom_score_adj=-1000 失败 pid=$_pid（这一局挡不住 LMK，仅记一次）"
    fi
}

# ② 电池白名单：把两个游戏包加进 deviceidle 白名单，等于系统
# 设置里的“电池不受限”，少一个被电池策略限制/杀掉的理由。
# 每局一次（调用点和自动清理同节奏）；已在名单里重复加无害；
# 常驻不撤销。结果只记一行：加上了哪些，或一行 WARN。
keepalive_battery_whitelist() {
    if ! command -v cmd >/dev/null 2>&1; then
        sched_log "WARN 保活：找不到 cmd，电池白名单跳过"
        return 0
    fi
    _done=""
    for _pat in $PEACE_PACKAGES $VALORANT_PACKAGES; do
        case "$_pat" in *.*) ;; *) continue ;; esac
        if cmd deviceidle whitelist "+$_pat" >/dev/null 2>&1; then
            _done="$_done $_pat"
        fi
    done
    if [ -n "$_done" ]; then
        sched_log "INFO 保活：电池白名单已加（deviceidle）：$_done"
    else
        sched_log "WARN 保活：电池白名单一个都没加上（cmd deviceidle 失败）"
    fi
}

# ④ 后台运行放行（0.4.59）：0.4.57 上线当天真机抓到实锤——
# 16:40:36 游戏切后台约 6 秒被杀，③ 的 exit-info 记 reason=13
# (OTHER KILLS BY SYSTEM)、importance=300，是厂商后台策略强杀，
# ①② 都挡不住。这一层把系统级“允许后台运行”的信号一次断言
# 到位：appops 的 RUN_ANY_IN_BACKGROUND / RUN_IN_BACKGROUND 都
# 设 allow，待机分组（app standby bucket）拉到 active（系统最
# 不倾向限制的一组）。和 ② 同节奏、每局一次；cmd 在走 cmd，
# cmd 不在回退 appops / am 裸命令。全包都成功才记一行 INFO；
# 单个包失败只记一行 WARN，不阻断游戏模式、不影响 ①②③。
_keepalive_assert_pkg() {
    _pkg="$1"
    if command -v cmd >/dev/null 2>&1; then
        cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1 || return 1
        cmd appops set "$_pkg" RUN_IN_BACKGROUND allow >/dev/null 2>&1 || return 1
        cmd activity set-standby-bucket "$_pkg" active >/dev/null 2>&1 || return 1
    else
        command -v appops >/dev/null 2>&1 || return 1
        appops set "$_pkg" RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1 || return 1
        appops set "$_pkg" RUN_IN_BACKGROUND allow >/dev/null 2>&1 || return 1
        am set-standby-bucket "$_pkg" active >/dev/null 2>&1 || return 1
    fi
    return 0
}
keepalive_allow_background() {
    _done=""
    _all_ok=1
    for _pat in $PEACE_PACKAGES $VALORANT_PACKAGES; do
        case "$_pat" in *.*) ;; *) continue ;; esac
        if _keepalive_assert_pkg "$_pat"; then
            _done="$_done $_pat"
        else
            _all_ok=0
            sched_log "WARN 保活：后台运行放行失败 pkg=$_pat（appops/待机分组断言未全过，仅记一次）"
        fi
    done
    if [ "$_all_ok" = "1" ] && [ -n "$_done" ]; then
        sched_log "INFO 保活：后台运行已放行（appops+待机分组）：$_done"
    fi
}

# ③ 被杀取证：抓 dumpsys activity exit-info 写进诊断日志。
# ApplicationExitInfo 是系统给每次进程退出记的原因和来源
# （reason=LOW_MEMORY 是 LMK 回收、APP CRASH 是崩溃、reason
# 里带厂商包名的多半是策略强杀），是分清杀法的决定性证据。
# 两个游戏包都查；每个包只取最近一条记录（dumpsys 按时间
# 倒序，第一条就是最近的）的关键行——时间、reason、subreason、
# description、status——拼成一行 [exitinfo] 写诊断日志。慢就
# 慢这一次：调用点保证只在游戏消失的转折轮跑，绝不进轮询。
diag_log() {
    ( SCHED_LOG_CAT=diag; sched_log "$*" )
}
capture_game_exit_info() {
    command -v dumpsys >/dev/null 2>&1 || return 0
    for _pkg in $PEACE_PACKAGES $VALORANT_PACKAGES; do
        case "$_pkg" in *.*) ;; *) continue ;; esac
        _out=$(dumpsys activity exit-info "$_pkg" 2>/dev/null)
        [ -n "$_out" ] || continue
        # 只留第一条记录：记录以 ApplicationExitInfo #N 或 #N:
        # 起头，第二条出现就停；没有这种分行时兜底只看前 12 行。
        _rec=$(printf '%s\n' "$_out" | awk '
            /ApplicationExitInfo *#/ { n++; if (n > 1) exit }
            /^[ \t]*#[0-9]+:/ { n++; if (n > 1) exit }
            { print }
        ' | head -n 12)
        _fields=$(printf '%s\n' "$_rec" | grep -iE 'timestamp|reason|subreason|description|status' | sed 's/^[ \t]*//' | tr '\n' ' ' | cut -c1-300)
        [ -n "$_fields" ] || continue
        diag_log "[exitinfo] pkg=$_pkg $_fields"
    done
}

# ================= 绑定 =================

# --- state 文件写保护（S5）---
# STATEFILE 的 grep+mv 是读-改-写：watch 主循环和一次手动 auto 并发
# 时会互相覆盖丢记录。mkdir 是原子的，拿它当锁；等满约 10 秒还没拿到
# 就直接继续（宁可冒险写也不卡死 watch）。只在自己拿到锁时才解锁。
# S4（0.4.50）：补残留自愈（zram/thermal 的锁在 M5 就有了，这把漏
# 了）：持锁进程被 SIGKILL/OOM 杀掉后锁目录会残留，旧写法每次状态
# 操作先白等约 10 秒且永不自愈。拿到锁时写 pid 文件；发现残留时
# 照 zram_lock_acquire 判断：holder 已死、pid 非法、或锁超 5 分钟
# → 清掉重拿，并记一行 WARN 让日志里有解释。
_STATE_LOCKED=""
_state_lock() {
    _STATE_LOCKED=""
    if mkdir "$STATEFILE.lock" 2>/dev/null; then
        echo "$$" > "$STATEFILE.lock/pid" 2>/dev/null || true
        _STATE_LOCKED=1
        return 0
    fi
    _holder=$(cat "$STATEFILE.lock/pid" 2>/dev/null)
    _stale=0
    case "$_holder" in
        ''|*[!0-9]*) _stale=1 ;;
        *) kill -0 "$_holder" 2>/dev/null || _stale=1 ;;
    esac
    if [ "$_stale" = "0" ] && find "$STATEFILE.lock" -mmin +5 2>/dev/null | grep -q .; then
        _stale=1
    fi
    if [ "$_stale" = "1" ]; then
        sched_log "WARN thread state 锁残留（holder=${_holder:-未知}），清掉重拿"
        rm -rf "$STATEFILE.lock" 2>/dev/null
        if mkdir "$STATEFILE.lock" 2>/dev/null; then
            echo "$$" > "$STATEFILE.lock/pid" 2>/dev/null || true
            _STATE_LOCKED=1
            return 0
        fi
    fi
    _n=0
    while ! mkdir "$STATEFILE.lock" 2>/dev/null; do
        _n=$((_n + 1))
        [ "$_n" -ge 100 ] && return 1
        sleep 0.1 2>/dev/null || sleep 1
    done
    echo "$$" > "$STATEFILE.lock/pid" 2>/dev/null || true
    _STATE_LOCKED=1
    return 0
}
_state_unlock() {
    if [ "$_STATE_LOCKED" = "1" ]; then
        rm -f "$STATEFILE.lock/pid" 2>/dev/null || true
        rmdir "$STATEFILE.lock" 2>/dev/null || true
        _STATE_LOCKED=""
    fi
}

state_has() {
    _pid="$1"; _tid="$2"; _mask="$3"
    [ -f "$STATEFILE" ] || return 1
    grep -q "^$_pid $_tid $_mask\$" "$STATEFILE" 2>/dev/null
}

state_clear_pid() {
    _pid="$1"
    _state_lock || true
    if [ -f "$STATEFILE" ]; then
        grep -v "^$_pid " "$STATEFILE" > "$STATEFILE.tmp.$$" 2>/dev/null || true
        if [ -f "$STATEFILE.tmp.$$" ]; then
            mv "$STATEFILE.tmp.$$" "$STATEFILE" 2>/dev/null || true
        fi
    fi
    # 0.4.59：绑核屡败计数档跟着进程一起清（新进程同 pid 也从零开始）。
    rm -f "${STATEFILE}.bindfail.${_pid}" 2>/dev/null || true
    _state_unlock
}

# 自动绑定一个进程的全部线程。
# dry_run=1 只打印表，不调用 taskset；use_state=1 时跳过已按同一掩码绑过的线程（watch 用）。
# 设置全局 AUTO_OK / AUTO_FAIL / AUTO_SKIP。
auto_bind_pid() {
    _pid="$1"; _pkg="$2"; _profile="$3"; _dry_run="$4"; _use_state="$5"
    AUTO_OK=0; AUTO_FAIL=0; AUTO_SKIP=0
    FIRST_TS_ERR=""
    # S5：批量写回——本轮新绑的记录先攒到临时文件，循环结束后再一次
    # 合并进 STATEFILE，而不是每个线程都全文件 grep+mv 一次。
    _state_batch="$STATEFILE.new.$$"
    if [ "$_dry_run" != "1" ]; then printf '' > "$_state_batch" 2>/dev/null || true; fi
    # 0.4.59：绑核屡败停放——同一个 (tid,mask) 连续真失败满 3 次，
    # 后续轮次直接计 skip、不再调 taskset。真机证据（2026-11-21
    # 16:42–16:47）：桌面启动器 tid=26434 mask=7c 连败 6+ 轮，每轮
    # 整包重绑空转、WARN 刷屏。计数按 pid 存档
    # $STATEFILE.bindfail.<pid>，每行 "tid mask 连续失败次数"；
    # 载入时剔掉线程已消失的行、次数封顶 3；绑成功清掉对应行；
    # 有变动才在函数末尾落盘，清空则删档；进程消失由
    # state_clear_pid 连档一起删。dry_run 不碰这套。
    _bf_file="${STATEFILE}.bindfail.${_pid}"
    _bf_work=""
    _bf_dirty=0
    if [ "$_dry_run" != "1" ]; then
        _bf_work="${_bf_file}.work.$$"
        if printf '' > "$_bf_work" 2>/dev/null; then
            if [ -f "$_bf_file" ]; then
                while IFS= read -r _bfr || [ -n "$_bfr" ]; do
                    set -- $_bfr
                    [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || continue
                    [ -d "$PROC/$_pid/task/$1" ] || continue
                    case "$3" in ''|*[!0-9]*) continue ;; esac
                    _bfn="$3"
                    if [ "$_bfn" -gt 3 ]; then _bfn=3; fi
                    echo "$1 $2 $_bfn" >> "$_bf_work" 2>/dev/null || true
                done < "$_bf_file"
            fi
        else
            _bf_work=""
        fi
    fi
    echo "PID $_pid pkg=${_pkg:-?} profile=$_profile 线程分类绑定："
    echo "  tid comm 类别 策略 掩码"
    for _t in "$PROC/$_pid"/task/*; do
        [ -d "$_t" ] || continue
        _tid="${_t##*/}"
        _comm=$(cat "$_t/comm" 2>/dev/null)
        _class=$(classify_thread "$_tid" "${_comm:-?}" "$_pid")
        _policy=$(policy_for_class "$_profile" "$_class")
        _mask=$(policy_to_mask "$_policy")
        if [ "$_use_state" = "1" ] && state_has "$_pid" "$_tid" "$_mask"; then
            AUTO_SKIP=$((AUTO_SKIP + 1))
            continue
        fi
        # 0.4.59：停放判断——这个 (tid,mask) 已连败满 3 次，本轮
        # 直接计 skip，不再调 taskset 空转（停放行计 skip，正好和
        # watch 的全败判定兼容：skip>0 就不会被当成全败退避）。
        if [ -n "$_bf_work" ] && [ -f "$_bf_work" ]; then
            _bfc=$(awk -v t="$_tid" -v m="$_mask" '$1==t && $2==m {print $3; exit}' "$_bf_work" 2>/dev/null)
            if [ "$_bfc" = "3" ]; then
                AUTO_SKIP=$((AUTO_SKIP + 1))
                continue
            fi
        fi
        echo "  $_tid ${_comm:-?} $_class $_policy $_mask"
        if [ "$_dry_run" = "1" ]; then
            AUTO_OK=$((AUTO_OK + 1))
            continue
        fi
        # 0.4.2：taskset 的报错不再丢弃，记下第一次失败的完整报错，
        # 下次看日志就知道是权限、掩码还是别的（0.4.1 只记 ok/fail 数，
        # 失败原因完全不可见）。
        _ts_out=$(taskset -p "$_mask" "$_tid" 2>&1)
        if [ $? -eq 0 ]; then
            AUTO_OK=$((AUTO_OK + 1))
            # S5：只往本轮临时文件追加，不 grep、不写 STATEFILE。
            echo "$_pid $_tid $_mask" >> "$_state_batch" 2>/dev/null || true
            # 0.4.59：绑成功了，把这个 (tid,mask) 的屡败计数清掉。
            if [ -n "$_bf_work" ] && [ -f "$_bf_work" ] && grep -q "^$_tid $_mask " "$_bf_work" 2>/dev/null; then
                grep -v "^$_tid $_mask " "$_bf_work" > "$_bf_work.t" 2>/dev/null || true
                mv "$_bf_work.t" "$_bf_work" 2>/dev/null || true
                _bf_dirty=1
            fi
            # 关键线程才调 nice：游戏档按 nice_for_class，日常档只动 main
            # 且默认 AUTO_CRITICAL_NICE=0 表示不调。
            _nice=$(nice_for_class "$_profile" "$_class")
            if [ "$_nice" != "0" ]; then
                renice -n "$_nice" -p "$_tid" >/dev/null 2>&1 || true
            fi
        else
            # 0.4.19：线程在列出后、taskset 前退出了——/proc 里已没
            # 它的目录，不是绑不上，是没东西可绑，算跳过不算失败。
            # 06:36 真机日志：tid 14014 退出中 taskset 报 EINVAL，
            # 被记成 fail=1，watch 又把 ok=0 当全败、停了 300 秒重试。
            # （僵尸线程目录还在时仍算真失败，第二层防线是 watch 的
            # 全败判断也要 skip=0 才触发，见 watch 两处。）
            if [ ! -d "$PROC/$_pid/task/$_tid" ]; then
                AUTO_SKIP=$((AUTO_SKIP + 1))
                continue
            fi
            AUTO_FAIL=$((AUTO_FAIL + 1))
            # 0.4.59：真失败（线程还在）计数 +1；恰达 3 时记一行
            # 停放日志，后续轮次在循环开头直接计 skip。
            if [ -n "$_bf_work" ] && [ -f "$_bf_work" ]; then
                _bfc=$(awk -v t="$_tid" -v m="$_mask" '$1==t && $2==m {print $3; exit}' "$_bf_work" 2>/dev/null)
                case "$_bfc" in ''|*[!0-9]*) _bfc=0 ;; esac
                _bfc=$((_bfc + 1))
                if [ "$_bfc" -gt 3 ]; then _bfc=3; fi
                grep -v "^$_tid $_mask " "$_bf_work" > "$_bf_work.t" 2>/dev/null || true
                echo "$_tid $_mask $_bfc" >> "$_bf_work.t" 2>/dev/null || true
                mv "$_bf_work.t" "$_bf_work" 2>/dev/null || true
                _bf_dirty=1
                if [ "$_bfc" = "3" ]; then
                    sched_log "INFO 绑核屡败已停放 tid=$_tid mask=$_mask（连败 3 次，后续轮次跳过）"
                fi
            fi
            if [ -z "$FIRST_TS_ERR" ]; then
                FIRST_TS_ERR="tid=$_tid mask=$_mask: ${_ts_out:-taskset 失败（无输出）}"
            fi
        fi
    done
    # S5：一次合并——旧 STATEFILE 里不在本轮新记录里的行（按 pid tid
    # 去重）保留，再把新记录追加，最后 mv 覆盖。state_has 的跳过判断
    # 仍在循环里读旧 STATEFILE，不受影响；dry-run 不写 STATEFILE。
    if [ "$_dry_run" != "1" ] && [ -s "$_state_batch" ]; then
        _state_lock || true
        _merge_pat="$STATEFILE.pat.$$"
        printf '' > "$_merge_pat" 2>/dev/null || true
        while IFS= read -r _mr || [ -n "$_mr" ]; do
            set -- $_mr
            echo "^$1 $2 " >> "$_merge_pat" 2>/dev/null || true
        done < "$_state_batch"
        _merged="$STATEFILE.merge.$$"
        if [ -f "$STATEFILE" ]; then
            grep -v -f "$_merge_pat" "$STATEFILE" > "$_merged" 2>/dev/null || true
        else
            printf '' > "$_merged" 2>/dev/null || true
        fi
        cat "$_state_batch" >> "$_merged" 2>/dev/null || true
        mv "$_merged" "$STATEFILE" 2>/dev/null || true
        rm -f "$_merge_pat" "$_merged" 2>/dev/null || true
        _state_unlock
    fi
    # 0.4.59：屡败计数有变动才落盘；工作副本空了就把档删掉。
    if [ -n "$_bf_work" ]; then
        if [ "$_bf_dirty" = "1" ]; then
            if [ -s "$_bf_work" ]; then
                mv "$_bf_work" "$_bf_file" 2>/dev/null || true
            else
                rm -f "$_bf_file" 2>/dev/null || true
            fi
        fi
        rm -f "$_bf_work" "$_bf_work.t" 2>/dev/null || true
    fi
    rm -f "$_state_batch" 2>/dev/null || true
    echo "绑定完成：成功 $AUTO_OK，失败 $AUTO_FAIL，跳过(已绑) $AUTO_SKIP"
    sched_log "INFO thread auto pid=$_pid pkg=$_pkg profile=$_profile ok=$AUTO_OK fail=$AUTO_FAIL skip=$AUTO_SKIP dry_run=$_dry_run"
    if [ "$AUTO_FAIL" -gt 0 ] && [ -n "$FIRST_TS_ERR" ]; then
        sched_log "WARN taskset 失败示例：$FIRST_TS_ERR"
    fi
}

check_pid() {
    _pid="$1"
    if [ -z "$_pid" ] || [ ! -d "$PROC/$_pid" ]; then
        echo "找不到进程：$2（没运行？包名写错？）"; exit 1
    fi
    if [ "$_pid" = "1" ] || [ "$_pid" = "2" ]; then
        echo "拒绝操作 PID $_pid"; exit 1
    fi
    _comm=$(cat "$PROC/$_pid/comm" 2>/dev/null)
    # S1：手动命令也复用自动模式 is_denied 的同一张表（包名 + comm
    # 双判），zygote64 / systemui 这些也要 FORCE 才动。
    _pkg=$(package_from_pid "$_pid")
    if is_denied "$_pkg" "$_comm"; then
        if [ "$FORCE" != "1" ]; then
            echo "警告：${_pkg:-$_comm} 是系统关键进程，绑错会影响全部应用甚至卡死/重启。"
            echo "确认要动它，再加环境变量 FORCE=1 或 --force 重跑。"
            exit 1
        fi
    fi
    case "$_comm" in
        system_server|surfaceflinger)
            if [ "$FORCE" != "1" ]; then
                echo "警告：$_comm 是系统关键进程，绑错会卡死/重启。"
                echo "确认要动它，再加环境变量 FORCE=1 或 --force 重跑。"
                exit 1
            fi
            ;;
    esac
    echo "目标 PID=$_pid comm=${_comm:-?}"
}

list_threads() {
    _pid="$1"
    echo "PID $_pid 的线程（tid comm 当前亲和性）："
    for _t in "$PROC/$_pid"/task/*; do
        _tid="${_t##*/}"
        _comm=$(cat "$_t/comm" 2>/dev/null)
        _aff=$(taskset -pc "$_tid" 2>/dev/null)
        echo "  tid=$_tid comm=${_comm:-?} ${_aff:-?}"
    done
}

bind_threads() {
    _pid="$1"; _mask="$2"
    _ok=0; _fail=0; _first_err=""
    for _t in "$PROC/$_pid"/task/*; do
        _tid="${_t##*/}"
        _ts_out=$(taskset -p "$_mask" "$_tid" 2>&1)
        if [ $? -eq 0 ]; then
            _ok=$((_ok+1))
        else
            _fail=$((_fail+1))
            if [ -z "$_first_err" ]; then _first_err="tid=$_tid mask=$_mask: ${_ts_out:-taskset 失败（无输出）}"; fi
        fi
    done
    echo "绑核完成：成功 $_ok，失败 $_fail，mask=$_mask"
    sched_log "INFO thread bind pid=$_pid mask=$_mask ok=$_ok fail=$_fail"
    if [ "$_fail" -gt 0 ] && [ -n "$_first_err" ]; then
        sched_log "WARN taskset 失败示例：$_first_err"
    fi
}

# ================= 命令分发 =================

CMD="${1:-}"
case "$CMD" in
    ""|help|-h|--help) usage ;;
esac

# --- 自动命令：detect / auto / watch / stop / game / fg，不需要手动输包名 ---
case "$CMD" in
    fg)
        # 只输出一行机器可读结果，给面板 status 用，不绑核、不列线程：
        #   foreground_pkg=... foreground_pid=... foreground_profile=... foreground_method=...
        # 识别不到则 foreground_pkg 为空，退出码 1。
        if detect_foreground full; then
            _profile=$(profile_for_package "$DETECTED_PKG" "$DETECTED_PID")
            echo "foreground_pkg=$DETECTED_PKG"
            echo "foreground_pid=$DETECTED_PID"
            echo "foreground_profile=$_profile"
            echo "foreground_method=$DETECT_METHOD"
            exit 0
        else
            echo "foreground_pkg="
            echo "foreground_pid="
            echo "foreground_profile="
            echo "foreground_method=none"
            exit 1
        fi
        ;;
    gamedetect)
        # 只输出运行中的游戏进程（不看前台），给面板 status 和
        # 手动验证用；没找到返回 1，输出空值。
        if scan_running_games; then
            echo "game_running_pkg=$GAME_RUNNING_PKG"
            echo "game_running_pid=$GAME_RUNNING_PID"
            echo "game_running_profile=$GAME_RUNNING_PROFILE"
            exit 0
        else
            echo "game_running_pkg="
            echo "game_running_pid="
            echo "game_running_profile="
            exit 1
        fi
        ;;
    game)
        _mode="${2:-}"
        case "$_mode" in
            game|peace|valorant)
                if [ "$GAME_SCHED_ENABLED" != "1" ]; then echo "GAME_SCHED_ENABLED=0，游戏调度切换已关闭（config.conf 里改）。"; exit 0; fi
                # 0.4.35：apply_game_sched 失败（哨兵未通过）时透传失败，
                # 不再无条件报“已切到 game”。成功才报成功。
                if apply_game_sched "game"; then
                    echo "调度模式已切到 game（只切调度，不绑核）"
                    exit 0
                else
                    echo "ERR 切游戏模式失败：哨兵验证未通过（uclamp/GPU 未生效），未切游戏模式"
                    exit 1
                fi
                ;;
            off)
                # M17：回显也用现读的 MODE，不用启动时加载的旧值。
                _off_restore=$(config_value MODE)
                case "$_off_restore" in balanced|performance|powersave) ;; *) _off_restore="balanced" ;; esac
                # 0.4.35：restore_game_sched 失败时透传失败，不报“已切回”。
                if restore_game_sched; then
                    echo "调度模式已切回 $_off_restore"
                    exit 0
                else
                    echo "ERR 切回 $_off_restore 失败：游戏档数值未撤销，仍在游戏档"
                    exit 1
                fi
                ;;
            *) usage ;;
        esac
        exit 0
        ;;
    detect)
        if detect_foreground full; then
            _profile=$(profile_for_package "$DETECTED_PKG" "$DETECTED_PID")
            echo "识别到前台应用：$DETECTED_PKG (PID $DETECTED_PID，方式 $DETECT_METHOD，档位 $_profile)"
            auto_bind_pid "$DETECTED_PID" "$DETECTED_PKG" "$_profile" 1 0
            echo "上面只是预览，没有真的绑。确认无误再跑：thread.sh auto"
        else
            echo "没识别到前台应用。先打开一个应用放到前台再跑，或用手动命令：thread.sh list <包名>"
            exit 1
        fi
        exit 0
        ;;
    auto)
        DRY_RUN=0; PROFILE_OVERRIDE=""
        shift
        for _a in "$@"; do
            case "$_a" in
                --dry-run) DRY_RUN=1 ;;
                peace|valorant) PROFILE_OVERRIDE="game" ;;
                game|daily|background) PROFILE_OVERRIDE="$_a" ;;
                --force) ;;
                *) echo "auto 不认识参数：$_a"; usage ;;
            esac
        done
        # 0.4.14：先看游戏进程在不在跑（GAME_AUTO_DETECT=1 时），在跑
        # 就以它为目标——前台切到 QQ / 安装器时也不丢游戏档；没在跑
        # 再退回前台识别，和 0.4.13 一样。
        _tpid=""; _tpkg=""; _tprof=""
        if [ "$GAME_AUTO_DETECT" = "1" ] && scan_running_games; then
            _tpid="$GAME_RUNNING_PID"; _tpkg="$GAME_RUNNING_PKG"; _tprof="$GAME_RUNNING_PROFILE"
            echo "检测到游戏进程：$_tpkg (PID $_tpid，档位 $_tprof)"
        elif detect_foreground full; then
            _tpid="$DETECTED_PID"; _tpkg="$DETECTED_PKG"
            _tprof=$(profile_for_package "$DETECTED_PKG" "$DETECTED_PID")
            echo "识别到前台应用：$_tpkg (PID $_tpid，方式 $DETECT_METHOD，档位 $_tprof)"
        else
            echo "没检测到游戏进程，也没识别到前台应用，什么都没绑。"
            exit 1
        fi
        if [ -n "$PROFILE_OVERRIDE" ]; then _tprof="$PROFILE_OVERRIDE"; fi
        if [ "$DRY_RUN" != "1" ]; then
            case "$_tprof" in
                game|peace|valorant)
                    apply_game_sched "$_tprof"
                    # 0.4.16：手动 auto 撞见游戏也清一次后台（和 watch 进游戏时一样）。
                    clean_background_apps "$_tpkg"
                    ;;
                *) restore_game_sched ;;
            esac
        fi
        auto_bind_pid "$_tpid" "$_tpkg" "$_tprof" "$DRY_RUN" 0
        if [ "$DRY_RUN" = "1" ]; then echo "dry-run：没有真的绑，也没有切调度。去掉 --dry-run 再跑一次才生效。"; fi
        exit 0
        ;;
    watch)
        shift
        _interval="${1:-$AUTO_WATCH_INTERVAL}"
        PROFILE_OVERRIDE="${2:-}"
        case "$_interval" in ''|*[!0-9]*) _interval="$AUTO_WATCH_INTERVAL" ;; esac
        if [ "$_interval" -lt 2 ]; then _interval=2; fi
        if [ "$_interval" -gt 60 ]; then _interval=60; fi
        if [ -f "$WATCH_PIDFILE" ]; then
            _old=$(cat "$WATCH_PIDFILE" 2>/dev/null)
            if _watch_pid_alive "$_old"; then
                echo "watch 已在运行（PID $_old），先跑 thread.sh stop 再重开。"
                exit 1
            else
                # 残留 pid 文件（旧 watch 已死、PID 被别的进程重用），删掉再起
                rm -f "$WATCH_PIDFILE" 2>/dev/null || true
            fi
        fi
        echo $$ > "$WATCH_PIDFILE" 2>/dev/null || true
        echo "watch 启动：每 ${_interval}s 识别一次前台应用，换应用就重绑（PID $$，停用：thread.sh stop）"
        LAST_PID=""; LAST_PKG=""; LAST_IME_PID=""
        _bind_broken_until=0
        # 0.4.14 游戏进程占档跟踪：_LAST_GAME_PID 是当前占着游戏档
        # 的游戏主进程；_GAME_MISSING 是连续几轮找不到它的计数。
        _LAST_GAME_PID=""; _LAST_GAME_PKG=""; _GAME_MISSING=0
        _game_bind_broken_until=0
        _thermal_retry_until=0
        # M3：watch 启动时校验一次残留游戏状态——状态文件说 game 但
        # sysfs 不是游戏值（重启后 sysfs 已回原厂、状态文件还在），就
        # 删掉重来，免得首局游戏全程跑均衡档、去温控也不自动开。
        if [ -f "$GAME_SCHED_STATE" ] && [ "$(cat "$GAME_SCHED_STATE" 2>/dev/null)" = "game" ]; then
            if ! verify_game_applied; then
                rm -f "$GAME_SCHED_STATE" 2>/dev/null || true
                sched_log "WARN 残留游戏状态已清，下局重新切游戏档"
            fi
        fi
        _LAST_CYCLE=""; _LAST_DEBUG_LOG=""
        # 0.4.8 唤醒锁（默认关）：AUTO_MODE_WAKELOCK=1 时持部分唤醒锁，
        # 让 watch 在灭屏时也能跑、可靠地检测 screen-off。代价是设备
        # 无法深度休眠、耗电上升，默认不开。
        _WAKELOCK_HELD=0
        _wl=$(config_value AUTO_MODE_WAKELOCK)
        if [ "$_wl" = "1" ]; then
            if _wakelock_acquire; then
                _WAKELOCK_HELD=1
                sched_log "INFO auto-mode wakelock 已持有（AUTO_MODE_WAKELOCK=1，灭屏时 watch 继续跑，耗电会上升）"
            else
                sched_log "WARN auto-mode wakelock 获取失败（/sys/power/wake_lock 不可写），灭屏检测仍按轮询尽力而为"
            fi
        fi
        # 0.4.7 自动模式：上次自动应用的模式（跨 watch 重启不重复应用）。
        # 没记过时默认就是开机时 service.sh 已套用的基础 MODE，避免
        # 启动第一轮就无谓地重套一次。
        _AUTO_APPLIED=""
        if [ -f "$AUTO_MODE_STATE" ]; then
            _AUTO_APPLIED=$(cat "$AUTO_MODE_STATE" 2>/dev/null | tr -d ' \t\r\n')
        fi
        case "$_AUTO_APPLIED" in balanced|performance|powersave) ;; *)
            _AUTO_APPLIED=$(config_value MODE)
            case "$_AUTO_APPLIED" in balanced|performance|powersave) ;; *) _AUTO_APPLIED="balanced" ;; esac
            ;;
        esac
        _cleanup_watch() {
            if [ -n "$LAST_PID" ] && [ -d "$PROC/$LAST_PID" ]; then
                echo "watch 退出，把 PID $LAST_PID 绑回全核"
                bind_threads "$LAST_PID" "$ALL_MASK" >/dev/null 2>&1 || true
            fi
            if [ -n "$_LAST_GAME_PID" ] && [ -d "$PROC/$_LAST_GAME_PID" ] && [ "$_LAST_GAME_PID" != "$LAST_PID" ]; then
                echo "watch 退出，把游戏 PID $_LAST_GAME_PID 绑回全核"
                bind_threads "$_LAST_GAME_PID" "$ALL_MASK" >/dev/null 2>&1 || true
            fi
            restore_game_sched
            if [ "$_WAKELOCK_HELD" = "1" ]; then
                _wakelock_release 2>/dev/null || true
            fi
            rm -f "$WATCH_PIDFILE" 2>/dev/null || true
            exit 0
        }
        trap _cleanup_watch INT TERM
# 0.4.10：唤醒源取证——每次 watch 从休眠缺口醒来时，记下最耗的
# 前 3 个唤醒源（/sys/kernel/debug/wakeup_sources 按 total_time 排），
# 这样下次直接从日志就能看到是谁总把平板叫醒。total_time 单位是
# 毫秒，wakeup_count 是它叫醒设备的次数。读不到就记一行原因。
log_wakeup_sources() {
    _ws="/sys/kernel/debug/wakeup_sources"
    if [ ! -r "$_ws" ]; then
        # 0.4.11：这台平板的 debugfs 读不到（0.4.10 日志 134 行全是
        # unreadable，可能是没挂载或 SELinux 拦了）。改走 dumpsys power
        # 的唤醒锁列表——那是系统服务给的，不走 debugfs。直接记原文
        # 前 5 行锁名，格式由读日志的人认，不在脚本里猜格式。
        _pw=$(dumpsys power 2>/dev/null | grep -i "WAKE_LOCK" | head -n 5 | cut -c1-120 | tr '\n' '|' | tr -s ' ')
        if [ -n "$_pw" ]; then
            sched_log "INFO wake-locks dumpsys: ${_pw}"
        else
            sched_log "INFO wakeup-sources unreadable ($_ws) and no wake locks in dumpsys power"
        fi
        return 0
    fi
    _top=$(awk 'NR>1 {print $7, $1, $4}' "$_ws" 2>/dev/null | sort -rn | head -n 3 | awk '{printf "%s total=%sms wakeups=%s; ", $2, $1, $3}')
    sched_log "INFO wakeup-sources top: ${_top:-none}"
}

        while true; do
            # 0.4.31：/system/bin 就绪守卫。开机早期（尤其是时钟还没同步
            # 的那次重启）/system/bin 里的工具（toybox 的 date/sleep/
            # printf/tr/cut 等）可能还没挂好，watch 一启动就找不到：
            # date 拿不到时间、sleep 失效让 watch 空转刷屏（一次开机
            # 2256 行报错就是这么来的），等 /system 挂好自己才恢复。
            # 这里只用 shell 内置命令（command、test、算术、echo）判断
            # 和等待，不依赖 /system/bin：date 找不到就跳过本轮、不跑
            # 任何命令、不记报错，空循环等约 1 秒再试；只记一次“在等”。
            # /system/bin 就绪后把标记清掉，下次再缺还会再记一次。
            # SYSBIN_DATE 是测试用的覆盖：设了就按它指的路径（-x）判断；
            # 没设就按 command -v date 或 /system/bin/date 判断——
            # 真机走 /system/bin，模拟机走 PATH 里的 date，两边都通用。
            # （0.4.31 第一版只认 /system/bin/date，模拟机上根本没有
            # /system，watch 全程被拦，T6/T7/T8/T18/T20/T26 全挂。）
            _sysbin_ready=0
            if [ -n "${SYSBIN_DATE:-}" ]; then
                [ -x "$SYSBIN_DATE" ] && _sysbin_ready=1
            elif command -v date >/dev/null 2>&1 || [ -x /system/bin/date ]; then
                _sysbin_ready=1
            fi
            if [ "$_sysbin_ready" != "1" ]; then
                if [ "$_SYSBIN_WARNED" != "1" ]; then
                    echo "watch 等 /system/bin 就绪（开机早期工具还没挂好），先等一会"
                    _SYSBIN_WARNED=1
                fi
                _k=0; while [ $_k -lt 500000 ]; do _k=$((_k + 1)); done
                continue
            fi
            _SYSBIN_WARNED=""
            # 0.4.8 休眠缺口检测：上轮到这轮间隔 >30s 说明进程被冻住过
            # （灭屏休眠 doze），记一行，免得“静默”被误当成 watch 死了。
            _cycle_start=$(date +%s)
            if [ -n "$_LAST_CYCLE" ]; then
                _gap=$((_cycle_start - _LAST_CYCLE))
                if [ "$_gap" -gt 30 ]; then
                    sched_log "INFO auto-mode resumed after ${_gap}s gap (watch was frozen, likely screen-off doze)"
                    # 0.4.10：刚醒来就记唤醒源——是谁叫醒的，当场取证。
                    log_wakeup_sources
                fi
            fi
            # 0.4.14 进程级游戏检测：先看游戏进程在不在跑（不管前台
            # 是谁）。在跑 → 占着游戏档、补绑游戏线程，这轮前台那套
            # 跳过：不切回均衡、不解绑游戏（0.4.13 只认前台，切出去
            # 回 QQ / 装应用一下就掉档，0.4.12 日志 00:27 切 QQ 23 秒
            # 就掉了一次）；连续 GAME_EXIT_GRACE_CYCLES 轮都找不到
            # 才算真退了、再切回（游戏自己重启换 PID 的空档不掉档）。
            # GAME_AUTO_DETECT=0 时整段跳过，回到 0.4.13 的老行为。
            _GAME_HELD=0
            _game_detect_on=$(config_value GAME_AUTO_DETECT)
            case "$_game_detect_on" in "" ) _game_detect_on=1 ;; esac
            # 0.4.57：保活总控，和检测开关一个口径每轮现读。
            _keepalive_on=$(config_value GAME_KEEPALIVE)
            case "$_keepalive_on" in "" ) _keepalive_on=1 ;; esac
            _GAME_GRACE=$(config_value GAME_EXIT_GRACE_CYCLES)
            case "$_GAME_GRACE" in ''|*[!0-9]*) _GAME_GRACE=2 ;; esac
            if [ "$_GAME_GRACE" -gt 12 ]; then _GAME_GRACE=12; fi
            if [ "$_game_detect_on" = "1" ] && scan_running_games; then
                _GAME_HELD=1
                _GAME_MISSING=0
                if [ "$GAME_RUNNING_PID" != "$_LAST_GAME_PID" ]; then
                    _was_running=0
                    if [ -n "$_LAST_GAME_PID" ]; then _was_running=1; state_clear_pid "$_LAST_GAME_PID"; fi
                    sched_log "INFO game running detected pkg=$GAME_RUNNING_PKG pid=$GAME_RUNNING_PID profile=$GAME_RUNNING_PROFILE"
                    # 0.4.16：新开一局才清一次后台（换 PID 只是游戏自己重启，不重复清）。
                    if [ "$_was_running" = "0" ]; then
                        clean_background_apps "$GAME_RUNNING_PKG"
                        # 0.4.57：电池白名单和清理同节奏，每局一次。
                        if [ "$_keepalive_on" = "1" ]; then keepalive_battery_whitelist; fi
                        # 0.4.59：后台运行放行断言，和白名单同一门控、每局一次。
                        if [ "$_keepalive_on" = "1" ]; then keepalive_allow_background; fi
                    fi
                    _LAST_GAME_PID="$GAME_RUNNING_PID"; _LAST_GAME_PKG="$GAME_RUNNING_PKG"
                    # S6：新一局游戏（新 PID）不受上一局的全败退避影响。
                    _game_bind_broken_until=0
                fi
                case "$GAME_RUNNING_PROFILE" in game|peace|valorant) apply_game_sched "$GAME_RUNNING_PROFILE" ;; esac
                # 0.4.57：保活①——游戏在跑的每轮都把主进程 oom 钉在
                # -1000（已钉住就不重复写，函数里判）。
                if [ "$_keepalive_on" = "1" ]; then keepalive_pin_game_oom "$GAME_RUNNING_PID"; fi
                # S5（0.4.50）：进游戏那一刻 thermal_auto_on 失败时，state
                # 已写 game、apply_game_sched 后续每轮都早返回，不会再调
                # 它——一次瞬时失败就是整局没去温控。这里补一条再触发
                # 路径：还在游戏档、自动开的状态文件还不存在、且过了
                # 60 秒退避，就补调一次，成功（状态文件出现）即止；
                # 退避是防 thermal.sh on 持续失败时每 5 秒刷一行 FAIL。
                if [ -f "$GAME_SCHED_STATE" ] && [ ! -f "$THERMAL_AUTO_STATE" ]; then
                    _tnow=$(date +%s)
                    if [ "$_tnow" -ge "${_thermal_retry_until:-0}" ]; then
                        _thermal_retry_until=$((_tnow + 60))
                        thermal_auto_on || true
                    fi
                fi
                _now=$(date +%s)
                if [ "$_now" -ge "$_game_bind_broken_until" ]; then
                    auto_bind_pid "$GAME_RUNNING_PID" "$GAME_RUNNING_PKG" "$GAME_RUNNING_PROFILE" 0 1 >/dev/null 2>&1 || true
                    # 0.4.19：ok=0 不等于全败——稳态下每轮都是 ok=0
                    #（新线程 0 个，老线程全跳过），只有 ok=0 且 fail>0
                    # 且 skip=0（一个都没绑上、一个也没绑过）才算真全败。
                    # 06:36 真机：ok=0 fail=1 skip=180，唯一失败的是
                    # 退出中的线程，游戏其实绑得好好的，却被停了 300 秒重试。
                    if [ "$AUTO_OK" = "0" ] && [ "$AUTO_FAIL" -gt 0 ] && [ "$AUTO_SKIP" = "0" ]; then
                        _game_bind_broken_until=$(( _now + 300 ))
                        sched_log "WARN watch 游戏绑核全败（ok=0），300s 内不再重试 $GAME_RUNNING_PKG"
                    fi
                fi
            elif [ "$_game_detect_on" = "1" ] && [ -n "$_LAST_GAME_PID" ]; then
                _GAME_MISSING=$((_GAME_MISSING + 1))
                if [ "$_GAME_MISSING" -ge "$_GAME_GRACE" ]; then
                    sched_log "INFO game process gone pkg=$_LAST_GAME_PKG pid=$_LAST_GAME_PID (missing ${_GAME_MISSING} cycles), restoring"
                    # 0.4.57：保活③——被杀取证。此刻 restore 还没跑、
                    # 游戏档状态文件还在 = 游戏是局中消失的，先抓一次
                    # exit-info 再切回。她自己正常退游戏也会走到这里、
                    # 也会留一条记录，无妨：reason 写的是用户退出，
                    # 汇报口径能区分。只在这一次转折跑，不进轮询。
                    if [ "$_keepalive_on" = "1" ] && [ -f "$GAME_SCHED_STATE" ]; then
                        capture_game_exit_info
                    fi
                    state_clear_pid "$_LAST_GAME_PID"
                    _LAST_GAME_PID=""; _LAST_GAME_PKG=""; _GAME_MISSING=0
                    restore_game_sched
                fi
            fi
            if [ "$_GAME_HELD" = "1" ]; then
                :
            elif detect_foreground cheap; then
                # 0.4.2：输入法只是盖在游戏上的浮层，不切换、不绑核、
                # 不切调度；同一个输入法只记一次日志，不刷屏。
                if is_ime "$DETECTED_PKG"; then
                    if [ "$DETECTED_PID" != "$LAST_IME_PID" ]; then
                        sched_log "INFO watch 前台是输入法 $DETECTED_PKG (PID $DETECTED_PID)，跳过（不切换游戏绑定）"
                        LAST_IME_PID="$DETECTED_PID"
                    fi
                else
                    LAST_IME_PID=""
                    _profile=$(profile_for_package "$DETECTED_PKG" "$DETECTED_PID")
                    if [ "$DETECTED_PID" != "$LAST_PID" ]; then
                        _bind_broken_until=0
                        if [ -n "$LAST_PID" ] && [ -d "$PROC/$LAST_PID" ]; then
                            echo "前台应用换了：$LAST_PKG -> $DETECTED_PKG，把旧的绑回全核"
                            bind_threads "$LAST_PID" "$ALL_MASK" >/dev/null 2>&1 || true
                            state_clear_pid "$LAST_PID"
                        fi
                        case "$_profile" in
                            game|peace|valorant) apply_game_sched "$_profile" ;;
                            *)
                                # 0.4.14：游戏刚退、还在宽限内时别急着切回——
                                # 游戏进程可能正在重启换 PID，宽限到了上面
                                # 那段会统一切回；从没占过档时直接切回。
                                if [ -z "$_LAST_GAME_PID" ] || [ "$_GAME_MISSING" -ge "$_GAME_GRACE" ]; then
                                    restore_game_sched
                                fi
                                ;;
                        esac
                        echo "新前台：$DETECTED_PKG (PID $DETECTED_PID，档位 $_profile)"
                        auto_bind_pid "$DETECTED_PID" "$DETECTED_PKG" "$_profile" 0 0
                        # 0.4.2：绑核全军覆没（ok=0）说明 taskset 被系统
                        # 拦了，每轮重试只是刷日志，300 秒内不再重试同一
                        # 应用，等应用换了或退避到期再说。
                        # 0.4.19：同游戏分支，ok=0 且 skip>0 只是稳态
                        #（新线程 0 个），必须 skip=0 才算真全败。
                        if [ "$AUTO_OK" = "0" ] && [ "$AUTO_FAIL" -gt 0 ] && [ "$AUTO_SKIP" = "0" ]; then
                            _bind_broken_until=$(( $(date +%s) + 300 ))
                            sched_log "WARN watch 绑核全败（ok=0），300s 内不再重试 $DETECTED_PKG"
                        fi
                        LAST_PID="$DETECTED_PID"; LAST_PKG="$DETECTED_PKG"
                    else
                        # 同一个应用：只补绑新冒出来的线程（游戏启动后陆续创建的）；
                        # 上次全败且在退避期内，直接跳过，不刷日志。
                        _now=$(date +%s)
                        if [ "$_now" -lt "$_bind_broken_until" ]; then
                            :
                        else
                            auto_bind_pid "$DETECTED_PID" "$DETECTED_PKG" "$_profile" 0 1 >/dev/null 2>&1 || true
                            # 0.4.19：同上，skip=0 才算真全败。
                            if [ "$AUTO_OK" = "0" ] && [ "$AUTO_FAIL" -gt 0 ] && [ "$AUTO_SKIP" = "0" ]; then
                                _bind_broken_until=$(( _now + 300 ))
                            fi
                        fi
                    fi
                fi
            fi
            # 0.4.8：自动模式每轮都跑，不再绑在“识别成功且非输入法”后面。
            # 0.4.7 的 bug：灭屏时前台识别失败（没前台应用）或认到输入法，
            # auto_mode_tick 根本不会被调用，screen-off 永远触发不了。
            # 现在只要没在游戏档里就跑——游戏档由 $GAME_SCHED_STATE 文件
            # 判断（文件存在 = 游戏调度已套用，游戏自己管；文件不在 = 跑
            # 自动模式，识别失败/输入法时也能按屏幕/电量切模式）。
            if [ ! -f "$GAME_SCHED_STATE" ]; then
                auto_mode_tick
            fi
            _LAST_CYCLE=$(date +%s)
            # 0.4.31：sleep 兜底。/system/bin 万一在运行中途掉线（极少见），
            # sleep 失效会让 watch 空转；失败就空循环等约 1 秒再继续，
            # 下一轮循环顶的守卫会接着处理。
            sleep "$_interval" 2>/dev/null || { _k=0; while [ $_k -lt 500000 ]; do _k=$((_k + 1)); done; }
        done
        exit 0
        ;;
    stop)
        if [ -f "$WATCH_PIDFILE" ]; then
            _old=$(cat "$WATCH_PIDFILE" 2>/dev/null)
            if _watch_pid_alive "$_old"; then
                kill "$_old" 2>/dev/null || true
                echo "已发停止信号给 watch（PID $_old）"
            else
                echo "watch 没在运行，清理残留 pid 文件"
            fi
            rm -f "$WATCH_PIDFILE" 2>/dev/null || true
        else
            echo "watch 没在运行。"
        fi
        # 0.4.8：顺手释放可能残留的唤醒锁（watch 被 SIGKILL 杀掉时
        # trap 跑不到，锁会一直持有着耗电；stop 时清掉它）。
        _wakelock_release 2>/dev/null || true
        exit 0
        ;;
esac

# --- 手动命令：需要包名或 PID ---
[ $# -ge 2 ] || usage
TARGET="$2"
PID=$(resolve_pid "$TARGET")
check_pid "$PID" "$TARGET"

case "$CMD" in
    list)
        list_threads "$PID"
        ;;
    bind)
        [ -n "$3" ] || usage
        MASK=$(policy_to_mask "$3")
        echo "把 PID $PID 全部线程绑到 $3（mask=$MASK）"
        bind_threads "$PID" "$MASK"
        ;;
    unbind)
        echo "把 PID $PID 全部线程绑回全核（mask=$ALL_MASK）"
        bind_threads "$PID" "$ALL_MASK"
        ;;
    prio)
        [ -n "$3" ] || usage
        _n="$3"
        # C9（0.4.50）：只认 -?[0-9]+。旧的两道 case 能放过 --5 这种
        # 值（第一道 -*[0-9]* 命中、第二道的字符集里有 -），后面的
        # -lt 比较报错被当假跳过，最后 renice 逐个失败还报“成功 0 个”。
        case "$_n" in -*) _nn="${_n#-}" ;; *) _nn="$_n" ;; esac
        case "$_nn" in ''|*[!0-9]*) echo "nice 值要是数字，例如 -5"; exit 2 ;; esac
        if [ "$_n" -lt -20 ] || [ "$_n" -gt 19 ]; then echo "nice 范围 -20..19"; exit 2; fi
        _ok=0
        for _t in "$PROC/$PID"/task/*; do
            _tid="${_t##*/}"
            if renice -n "$_n" -p "$_tid" >/dev/null 2>&1; then _ok=$((_ok+1)); fi
        done
        echo "优先级完成：成功 $_ok 个线程，nice=$_n（越小越优先，-5 已很激进，别用 -20）"
        sched_log "INFO thread prio pid=$PID nice=$_n ok=$_ok"
        ;;
    profile)
        [ -n "$3" ] || usage
        case "$3" in
            game|peace|valorant)
                echo "profile=game，按线程分类绑定（并切游戏调度模式）"
                apply_game_sched "game"
                auto_bind_pid "$PID" "$TARGET" "game" 0 0
                ;;
            daily)      MASK="$ALL_MASK" ;;
            background) MASK="$LITTLE_MASK" ;;
            *) echo "profile 只能是 game|daily|background（peace|valorant 是 game 的别名）"; exit 2 ;;
        esac
        case "$3" in
            game|peace|valorant) ;;
            *) echo "profile=$3，mask=$MASK"; bind_threads "$PID" "$MASK" ;;
        esac
        ;;
    *)
        usage
        ;;
esac
