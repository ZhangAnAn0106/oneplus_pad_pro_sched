#!/system/bin/sh
# panel.sh - KernelSU WebUI 面板的后端接口（面板只调它，不直接拼 shell 命令）
# 面板通过 ksu.exec 以 root 身份跑本脚本，本脚本再调 apply_sched.sh /
# thread.sh / game_sched.sh。所有写配置的入口都走白名单 + 范围校验，
# 绝不 eval 面板传来的字符串。
#
# 用法：
#   panel.sh status                    # key=value 状态，含前台识别（dumpsys，较慢）
#   panel.sh status-fast               # key=value 状态，跳过前台识别和温度扫描（快）
#   panel.sh state                     # status-fast + 配置，一次调用（面板日常刷新用）
#   panel.sh get                       # config.conf 原样输出（面板填表单用）
#   panel.sh set KEY VALUE             # 改一个配置项，立即写盘（不立即生效）
#   panel.sh setmany KEY=VALUE ...     # 批量改配置，先全量校验、再逐项写盘
#   panel.sh mode MODE                 # 改 MODE 并立即套用，一次调用
#   panel.sh fg                        # 只输出前台应用识别结果
#   panel.sh apply [MODE]              # 立即套用 MODE（默认 config 的 MODE）
#   panel.sh game on|off               # 只切游戏调度模式（peace|valorant 是 on 的别名）
#   panel.sh thread detect|gamedetect|auto|watch-start|watch-stop|unbind
#   panel.sh zram status|check ALGO SIZE_GB|set ALGO SIZE_GB|apply
#   panel.sh thermal status|on|off   # 去温控（0.4.29，Extreme GT 合并）
#   panel.sh vulkan on|off|status|probe  # 全局 Vulkan 开关与检测（0.4.56，转发 vulkan.sh）
#   panel.sh verify                    # 只读体检输出
#   panel.sh uclamp-diag               # uclamp 诊断（0.4.37）：只记日志，不改调度
#   panel.sh oshare-diag               # 互传诊断（0.4.39，0.4.54 起归入面板“诊断与日志”区）：只记日志，不改任何东西
#   panel.sh log [CAT] [N]            # 某类日志后 N 行（默认 sched 80 行；CAT=sched|thermal|zram|diag）
#   panel.sh clearlog [CAT]            # 清空某类日志（截断为 0 行，不动 watch / 调度）
#
# 约定：set 成功输出 "OK KEY=VALUE"，失败输出 "ERR ..." 且退出码非 0，
# 面板据此显示提示。status 里 game_mode=none 表示当前不是游戏模式。

MODDIR="${0%/*}/.."
if [ -n "$SCHED_TEST_MODDIR" ]; then MODDIR="$SCHED_TEST_MODDIR"; fi
# shellcheck disable=SC1091
. "$MODDIR/sched/lib.sh"
load_config "$MODDIR/sched/config.conf"
# S2：进/退游戏自动去温控的统一入口（thermal_auto.sh）。panel.sh 不
# 设 THERMAL_AUTO_STATE，thermal_auto.sh 按 SCHED_TEST_ROOT 自己算，
# 和 thread.sh 的测试路径一致。
. "$MODDIR/sched/thermal_auto.sh"
: "${MODE:=balanced}"

if [ -n "$SCHED_TEST_ROOT" ]; then
    _game_state="$SCHED_TEST_ROOT/game_sched_state"
    _watch_pid="$SCHED_TEST_ROOT/thread_watch.pid"
    _auto_mode_state="$SCHED_TEST_ROOT/oneplus_auto_mode"
else
    _game_state="/data/local/tmp/oneplus_game_sched_state"
    _watch_pid="/data/local/tmp/oneplus_thread_watch.pid"
    _auto_mode_state="/data/local/tmp/oneplus_auto_mode"
fi

CFG="$MODDIR/sched/config.conf"

# ---------- 配置写入：白名单 + 校验 + 原子替换 ----------
# C1（0.4.50）：set_value 是“读全文件→改一行→mv”，两个 panel 进程
# 同时 set 不同 key 时，后 mv 的会把先者的改动整份覆盖掉、丢一个
# 设置。加和 zram/thermal 同款的 mkdir 锁（带残留自愈：holder 死了
# 或锁超 5 分钟就清掉重拿）；等满约 5 秒还拿不到就报 ERR，不裸奔。
_CFG_LOCKED=""
_cfg_lock() {
    _CFG_LOCKED=""
    if mkdir "$CFG.lock" 2>/dev/null; then
        echo "$$" > "$CFG.lock/pid" 2>/dev/null || true
        _CFG_LOCKED=1
        return 0
    fi
    _holder=$(cat "$CFG.lock/pid" 2>/dev/null)
    _stale=0
    case "$_holder" in
        ''|*[!0-9]*) _stale=1 ;;
        *) kill -0 "$_holder" 2>/dev/null || _stale=1 ;;
    esac
    if [ "$_stale" = "0" ] && find "$CFG.lock" -mmin +5 2>/dev/null | grep -q .; then
        _stale=1
    fi
    if [ "$_stale" = "1" ]; then
        rm -rf "$CFG.lock" 2>/dev/null
        if mkdir "$CFG.lock" 2>/dev/null; then
            echo "$$" > "$CFG.lock/pid" 2>/dev/null || true
            _CFG_LOCKED=1
            return 0
        fi
    fi
    _n=0
    while ! mkdir "$CFG.lock" 2>/dev/null; do
        _n=$((_n + 1))
        [ "$_n" -ge 50 ] && return 1
        sleep 0.1 2>/dev/null || sleep 1
    done
    echo "$$" > "$CFG.lock/pid" 2>/dev/null || true
    _CFG_LOCKED=1
    return 0
}
_cfg_unlock() {
    if [ "$_CFG_LOCKED" = "1" ]; then
        rm -f "$CFG.lock/pid" 2>/dev/null || true
        rmdir "$CFG.lock" 2>/dev/null || true
        _CFG_LOCKED=""
    fi
}

# set_value KEY VALUE：只改 CFG 里 "KEY=..." 这一行（不存在就追加），
# 保留文件其余内容和注释。用临时文件 + mv，避免写一半被中断。
set_value() {
    _key="$1"; _val="$2"
    _cfg_lock || { echo "ERR 写配置失败（配置锁被占用）"; return 1; }
    _tmp="$CFG.tmp.$$"
    _found=0
    printf '' > "$_tmp" 2>/dev/null || { _cfg_unlock; echo "ERR 写配置失败"; return 1; }
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            "$_key="*)
                echo "$_key=$_val" >> "$_tmp"
                _found=1
                ;;
            *) printf '%s\n' "$_line" >> "$_tmp" ;;
        esac
    done < "$CFG"
    if [ "$_found" = "0" ]; then echo "$_key=$_val" >> "$_tmp"; fi
    if mv "$_tmp" "$CFG" 2>/dev/null; then
        backup_config "$CFG"
        _cfg_unlock
        echo "OK $_key=$_val"
        return 0
    fi
    rm -f "$_tmp" 2>/dev/null || true
    _cfg_unlock
    echo "ERR 写配置失败"
    return 1
}

is_int() {
    case "$1" in ''|*[!0-9-]*) return 1 ;; *) return 0 ;; esac
}

# check_int VALUE MIN MAX：整数且在范围内
check_int() {
    is_int "$1" || return 1
    [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

cmd_set() {
    _key="$1"; _val="$2"
    if [ -z "$_key" ] || [ -z "$_val" ]; then echo "ERR 缺少 KEY 或 VALUE"; return 2; fi
    validate_set "$_key" "$_val" || return 2
    set_value "$_key" "$_val"
}

# 批量改配置：先把所有项校验一遍，任何一项不合法就一个都不写，
# 避免面板滑块保存到一半、配置停在中间态。
cmd_setmany() {
    for _pair in "$@"; do
        case "$_pair" in
            *=*) ;;
            *) echo "ERR setmany 参数要是 KEY=VALUE：$_pair"; return 2 ;;
        esac
        _k="${_pair%%=*}"; _v="${_pair#*=}"
        validate_set "$_k" "$_v" || return 2
    done
    for _pair in "$@"; do
        _k="${_pair%%=*}"; _v="${_pair#*=}"
        set_value "$_k" "$_v" >/dev/null || return 1
    done
    echo "OK setmany $#"
}

# 只校验不写盘，供 cmd_set / cmd_setmany 共用。
validate_set() {
    _key="$1"; _val="$2"
    case "$_key" in
        MODE)
            case "$_val" in balanced|performance|powersave) ;; *) echo "ERR MODE 只能是 balanced|performance|powersave"; return 2 ;; esac
            ;;
        SCHEDUTIL_UP_RATE_LIMIT_US)
            check_int "$_val" 0 5000 || { echo "ERR 范围 0-5000"; return 2; }
            ;;
        SCHEDUTIL_DOWN_RATE_LIMIT_US)
            check_int "$_val" 500 100000 || { echo "ERR 范围 500-100000"; return 2; }
            ;;
        SCHEDUTIL_IOWAIT_BOOST|GAME_SCHED_ENABLED|GAME_AUTO_DETECT|GAME_CLEAN_BACKGROUND|AUTO_WATCH_ON_BOOT|AUTO_MODE|AUTO_MODE_DEBUG|AUTO_MODE_WAKELOCK|THERMAL_REMOVE|THERMAL_AUTO_GAME|OSHARE_ALWAYS_ON|VULKAN_GLOBAL)
            case "$_val" in 0|1) ;; *) echo "ERR 只能是 0 或 1"; return 2 ;; esac
            ;;
        AUTO_MODE_LOW_BATTERY_PCT)
            check_int "$_val" 5 50 || { echo "ERR 范围 5-50"; return 2; }
            ;;
        BACKGROUND_UCLAMP_MAX|GAME_BACKGROUND_UCLAMP_MAX)
            check_int "$_val" -1 1024 || { echo "ERR 范围 -1-1024"; return 2; }
            ;;
        GAME_TOP_APP_UCLAMP_MIN_PEACE|GAME_FOREGROUND_UCLAMP_MIN_PEACE)
            check_int "$_val" 0 1024 || { echo "ERR 范围 0-1024"; return 2; }
            ;;
        GAME_GPU_MIN_FREQ_PCT_PEACE|GPU_MIN_FREQ_PCT)
            check_int "$_val" 0 60 || { echo "ERR 范围 0-60"; return 2; }
            ;;
        GAME_HISPEED_LOAD_PEACE)
            check_int "$_val" 50 100 || { echo "ERR 范围 50-100"; return 2; }
            ;;
        GAME_SCHEDUTIL_DOWN_US_PEACE)
            check_int "$_val" 1000 50000 || { echo "ERR 范围 1000-50000"; return 2; }
            ;;
        GAME_NICE_PEACE)
            check_int "$_val" -20 0 || { echo "ERR 范围 -20-0"; return 2; }
            ;;
        AUTO_WATCH_INTERVAL)
            check_int "$_val" 2 60 || { echo "ERR 范围 2-60"; return 2; }
            ;;
        GAME_EXIT_GRACE_CYCLES)
            check_int "$_val" 0 12 || { echo "ERR 范围 0-12"; return 2; }
            ;;
        ZRAM_ALGO)
            case "$_val" in ''|*[!a-zA-Z0-9_-]*) echo "ERR 算法名只能是字母数字 - _"; return 2 ;; esac
            ;;
        ZRAM_SIZE_GB)
            check_int "$_val" 1 32 || { echo "ERR 范围 1-32"; return 2; }
            ;;
        *)
            echo "ERR 不允许改的 KEY：$_key"
            return 2
            ;;
    esac
    return 0
}

# _emit_render_state（0.4.54；0.4.55 精简；0.4.56 第二行改
# 全局 Vulkan）：实时状态的渲染组字段，只剩系统界面 + 全局
# Vulkan 两行（游戏渲染行她圈删了）。
# 只读 vulkan.sh probe 写好的缓存 $VULKAN_PROBE_CACHE——probe 要
# 跑 dumpsys，是秒级重活，绝不能进任何状态查询的同步路径（快速
# 和完整都不行）；缓存只由页面每约 15 秒单独调一次 panel.sh
# vulkan probe 异步刷新。缓存判新鲜只看时间戳：60 秒内算新鲜，
# 过期就报 detecting（全局 Vulkan 回配置值），不拿旧值冒充新值。
_emit_render_state() {
    _cache="$VULKAN_PROBE_CACHE"
    _c_ts=""
    if [ -f "$_cache" ]; then
        _c_ts=$(sed -n 's/^probe_ts=//p' "$_cache" 2>/dev/null | head -n 1)
    fi
    case "$_c_ts" in ''|*[!0-9]*) _c_ts=0 ;; esac
    _now=$(date +%s 2>/dev/null)
    case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
    _fresh=0
    if [ "$_now" -gt 0 ] && [ $((_now - _c_ts)) -ge 0 ] && [ $((_now - _c_ts)) -le 60 ]; then
        _fresh=1
    fi
    if [ "$_fresh" = "1" ]; then
        grep -e '^vulkan_global=' -e '^sys_renderer=' "$_cache" 2>/dev/null
        echo "render_stale=0"
    else
        echo "vulkan_global=${VULKAN_GLOBAL:-0}"
        echo "sys_renderer=detecting"
        echo "render_stale=1"
    fi
}

# ---------- 状态 ----------
# cmd_status [fast]：fast 跳过最慢的一项——前台识别（要扫 /proc +
# 读状态，在 ColorOS 上可能慢）。面板每次点击后的刷新和每 2 秒的
# 自动轮询都走 fast，只有“刷新状态”按钮和首次打开才走完整版。
# 运行中的游戏检测（grep -l 扫 /proc，0.4.15 起只要 0.08 秒）fast
# 也带上，不然自动轮询永远刷不出“运行中的游戏”。
# 0.4.54 状态精简：调频器 / GPU 频率上下限 / 温度 / CPU 拓扑四类
# 字段整个停产（页面也不再显示）。0.4.55 再删：内存组（可用内存 /
# zram 现状）停产、渲染组游戏行停产；状态只剩调度 / 游戏 / 渲染
# 三组。渲染组只读 vulkan.sh probe 的缓存（见 _emit_render_state），
# probe 绝不进任何状态查询的同步路径（完整版也不行，0.4.55）。
cmd_status() {
    _fast=""
    [ "$1" = "fast" ] && _fast=1
    # S4：状态查询不刷拓扑日志（lib.sh 的 detect_clusters 据此静默）。
    # 不 export，只影响本次调用。
    DETECT_QUIET=1
    echo "mode=$MODE"
    if [ -f "$_game_state" ]; then
        echo "game_mode=$(cat "$_game_state" 2>/dev/null)"
    else
        echo "game_mode=none"
    fi
    if [ -f "$_watch_pid" ]; then
        _wpid=$(cat "$_watch_pid" 2>/dev/null)
        # 0.4.6：别只看 kill -0——/data/local/tmp 跨重启不清，旧 PID
        # 可能被别的进程重用；认 cmdline 里同时有 thread.sh 和 watch 才算
        # 0.4.18：读 cmdline 包一层 { ...; } 2>/dev/null——PID 已死时
        # < 重定向失败，shell 会把 "can't open" 吵到 stderr 里。
        _wc=$( { tr '\0' ' ' < "/proc/$_wpid/cmdline"; } 2>/dev/null )
        case "$_wc" in
            *thread.sh*watch*)
                echo "watch=running"
                echo "watch_pid=$_wpid"
                ;;
            *) echo "watch=stopped" ;;
        esac
    else
        echo "watch=stopped"
    fi
    echo "cpuset_topapp=$(read_node "$DEV/cpuset/top-app/cpus")"
    echo "cpuset_foreground=$(read_node "$DEV/cpuset/foreground/cpus")"
    echo "cpuset_background=$(read_node "$DEV/cpuset/background/cpus")"
    echo "uclamp_topapp_min=$(read_node "$DEV/cpuctl/top-app/cpu.uclamp.min")"
    if [ -z "$_fast" ]; then
    # 完整版只比 fast 多一项前台识别。0.4.55：vulkan probe 不再在
    # 这里同步跑（0.4.54 时完整 status 先跑一次 probe，gfxinfo
    # 以秒计，是面板打开后卡半天的主嫌疑）——渲染组和 fast 一样
    # 只读缓存，probe 只由页面 15 秒定时器异步刷新。
    # 前台应用（轻量识别，失败也不影响状态其余部分）
    _fg=$(env DETECT_QUIET=1 SCHED_LOG_QUIET=1 sh "$MODDIR/sched/thread.sh" fg 2>/dev/null || true)
    echo "$_fg" | while IFS= read -r _line; do
        case "$_line" in foreground_*) echo "$_line" ;; esac
    done
    fi
    # 渲染组（0.4.54）：只读 probe 缓存，见 _emit_render_state。
    _emit_render_state
    # 运行中的游戏进程（0.4.14，不看前台；只读 /proc，轻量）——
    # 0.4.18 起 fast 也带上：面板每 2 秒自动轮询靠它刷出“运行中的游戏”，
    # 不带的话轮询永远显示旧值，等于没自动刷新。
    # S2（0.4.50）：子进程不继承上面未 export 的 DETECT_QUIET，thread.sh
    # 进门先跑 detect_clusters、每 2 秒往调度日志灌 2 行拓扑噪音——
    # 调子进程时把两个 QUIET 用 env 显式传过去（fg 那处同理）。
    _gd=$(env DETECT_QUIET=1 SCHED_LOG_QUIET=1 sh "$MODDIR/sched/thread.sh" gamedetect 2>/dev/null || true)
    echo "$_gd" | while IFS= read -r _line; do
        case "$_line" in game_running_*) echo "$_line" ;; esac
    done
    echo "game_sched_enabled=${GAME_SCHED_ENABLED:-1}"
    echo "game_auto_detect=${GAME_AUTO_DETECT:-1}"
    echo "game_clean_background=${GAME_CLEAN_BACKGROUND:-1}"
    echo "game_exit_grace=${GAME_EXIT_GRACE_CYCLES:-2}"
    echo "watch_on_boot=${AUTO_WATCH_ON_BOOT:-0}"
    echo "watch_interval=${AUTO_WATCH_INTERVAL:-5}"
    # 0.4.7 自动模式：auto_mode 是配置值（0/1）；auto_mode_applied 是
    # watch 上次自动应用的模式，没应用过或 AUTO_MODE=0 时为 none。
    echo "auto_mode=${AUTO_MODE:-1}"
    _am_applied="none"
    if [ "${AUTO_MODE:-1}" = "1" ] && [ -f "$_auto_mode_state" ]; then
        _am_applied=$(cat "$_auto_mode_state" 2>/dev/null | tr -d ' \t\r\n')
        case "$_am_applied" in balanced|performance|powersave) ;; *) _am_applied="none" ;; esac
    fi
    echo "auto_mode_applied=$_am_applied"
    echo "auto_mode_debug=${AUTO_MODE_DEBUG:-0}"
    echo "auto_mode_wakelock=${AUTO_MODE_WAKELOCK:-0}"
    echo "thermal_remove=${THERMAL_REMOVE:-0}"
    echo "thermal_auto_game=${THERMAL_AUTO_GAME:-1}"
    echo "vulkan_global_cfg=${VULKAN_GLOBAL:-0}"
}

# ---------- 线程动作 ----------
cmd_thread() {
    case "$1" in
        detect)
            sh "$MODDIR/sched/thread.sh" detect
            ;;
        gamedetect)
            sh "$MODDIR/sched/thread.sh" gamedetect
            ;;
        auto)
            sh "$MODDIR/sched/thread.sh" auto
            ;;
        auto-dry)
            sh "$MODDIR/sched/thread.sh" auto --dry-run
            ;;
        watch-start)
            # 后台启动，立即返回（面板 exec 是同步等待的，不能让它卡住）。
            # 已在运行时 thread.sh watch 自己会拒绝并退出。
            nohup env SCHED_LOG_QUIET=1 sh "$MODDIR/sched/thread.sh" watch "${AUTO_WATCH_INTERVAL:-5}" >> "$LOGFILE" 2>&1 &
            sleep 1
            if [ -f "$_watch_pid" ]; then echo "OK watch 已启动"; else echo "ERR watch 启动失败，看日志"; return 1; fi
            ;;
        watch-stop)
            # S35：stop 失败也要报 ERR（之前只 watch-start 检查了）。
            if ! sh "$MODDIR/sched/thread.sh" stop; then
                echo "ERR watch 停止失败"
                return 1
            fi
            restore_game_sched_via_thread
            ;;
        unbind)
            _fg=$(env DETECT_QUIET=1 SCHED_LOG_QUIET=1 sh "$MODDIR/sched/thread.sh" fg 2>/dev/null || true)
            _pid=$(echo "$_fg" | sed -n 's/^foreground_pid=//p' | head -n 1)
            if [ -z "$_pid" ]; then echo "ERR 没识别到前台应用，无法解除绑定"; return 1; fi
            sh "$MODDIR/sched/thread.sh" unbind "$_pid"
            ;;
        *)
            echo "ERR thread 只能是 detect|gamedetect|auto|auto-dry|watch-start|watch-stop|unbind"
            return 2
            ;;
    esac
}

# ---------- zram ----------
# set 先同步跑一次 check（快，只读），校验不过直接把原因回给面板；
# 校验过了再后台跑真正的 set——swapoff 要几秒，面板 exec 等不起
# （15 秒超时），后台跑完看状态确认。apply 只给 service.sh 开机用。
cmd_zram() {
    case "$1" in
        status)
            sh "$MODDIR/sched/zram.sh" status
            ;;
        check)
            sh "$MODDIR/sched/zram.sh" check "$2" "$3"
            ;;
        set)
            _out=$(sh "$MODDIR/sched/zram.sh" check "$2" "$3" 2>&1) || { echo "$_out"; return 2; }
            nohup env SCHED_LOG_QUIET=1 sh "$MODDIR/sched/zram.sh" set "$2" "$3" >> "$LOGFILE" 2>&1 &
            echo "OK 已开始切换（swapoff 要几秒），稍后看状态确认"
            ;;
        apply)
            sh "$MODDIR/sched/zram.sh" apply
            ;;
        *)
            echo "ERR zram 只能是 status|check ALGO SIZE_GB|set ALGO SIZE_GB|apply"
            return 2
            ;;
    esac
}

# ---------- 去温控 ----------
# on/off 先写配置（set_value 顺带写备份，升级不丢），再立即应用：
# on = 挂载替换文件 + 伪装温度 + 关 horae；off = 卸掉挂载 + 恢复 horae。
# 细节只写日志，面板只看一句 OK。配置替换要重启后才完全生效（温控
# 服务开机时就把配置读进去了），温度伪装是立即生效的。
cmd_thermal() {
    case "$1" in
        status)
            sh "$MODDIR/sched/thermal.sh" status
            ;;
        on)
            # M7/S35：先写配置，再跑 thermal.sh on，检查退出码；失败
            # 时把配置回滚到原来的值再报 ERR（thermal.sh 本身的退出码
            # 由 thermal.sh 那边保证非 0）。
            _orig="${THERMAL_REMOVE:-0}"
            set_value THERMAL_REMOVE 1 >/dev/null || { echo "ERR 保存配置失败"; return 1; }
            if env SCHED_LOG_QUIET=1 sh "$MODDIR/sched/thermal.sh" on; then
                echo "OK 去温控已开启（温度伪装立即生效，配置替换重启后完全生效）"
            else
                set_value THERMAL_REMOVE "$_orig" >/dev/null 2>&1 || true
                # C15（0.4.50）：thermal.sh on 部分成功（比如挂载成功、
                # 伪装失败）时，已挂的 bind-mount 和已关的 horae 不会
                # 自己退——回滚配置之外再补跑一次 off 把生效的那半
                # 也卸干净，别等重启。_orig 本来就是 1（手动常开）时
                # 不跑 off，那份状态不是这次开出来的，不能拆。
                if [ "$_orig" != "1" ]; then
                    env SCHED_LOG_QUIET=1 sh "$MODDIR/sched/thermal.sh" off >/dev/null 2>&1 || true
                fi
                echo "ERR 去温控开启失败，已回滚配置"
                return 1
            fi
            ;;
        off)
            _orig="${THERMAL_REMOVE:-0}"
            set_value THERMAL_REMOVE 0 >/dev/null || { echo "ERR 保存配置失败"; return 1; }
            if env SCHED_LOG_QUIET=1 sh "$MODDIR/sched/thermal.sh" off; then
                echo "OK 去温控已关闭（重启后完全恢复原厂温控）"
            else
                set_value THERMAL_REMOVE "$_orig" >/dev/null 2>&1 || true
                echo "ERR 去温控关闭失败，已回滚配置"
                return 1
            fi
            ;;
        *)
            echo "ERR thermal 只能是 status|on|off"
            return 2
            ;;
    esac
}

# ---------- 全局 Vulkan（0.4.56） ----------
# 全部转发 vulkan.sh（开关的 system.prop/resetprop 读写、检测
# probe 都在那边，和 zram/thermal 同构）。probe 是只读重活，
# 页面每约 15 秒调一次刷新缓存，实时状态只读缓存（见
# _emit_render_state）。
cmd_vulkan() {
    case "$1" in
        on|off|status|probe)
            sh "$MODDIR/sched/vulkan.sh" "$1"
            ;;
        *)
            echo "ERR vulkan 只能是 on|off|status|probe"
            return 2
            ;;
    esac
}

# watch-stop 后顺手切回均衡（thread.sh stop 本身不切调度，面板帮它切，
# 这样“停止跟随”后不会一直留在游戏调度上）。
restore_game_sched_via_thread() {
    if [ -f "$_game_state" ]; then
        sh "$MODDIR/sched/game_sched.sh" off >/dev/null 2>&1 || true
    fi
}

# ---------- 分发 ----------
case "${1:-}" in
    status) cmd_status ;;
    status-fast) cmd_status fast ;;
    state) cmd_status fast; echo "---CONFIG---"; cat "$CFG" ;;
    fg) sh "$MODDIR/sched/thread.sh" fg ;;
    get) cat "$CFG" ;;
    set) cmd_set "$2" "$3" ;;
    setmany) shift; cmd_setmany "$@" ;;
    mode)
        _m="$2"
        case "$_m" in balanced|performance|powersave) ;; *) echo "ERR 模式不对：$_m"; exit 2 ;; esac
        # 0.4.7：手动改 MODE 仍立即生效；但 AUTO_MODE=1 时，watch 下
        # 一轮在非游戏前台会按屏幕/电量重新决策，可能把它再切走
        # （这是预期的自动行为，不是 bug；想完全手动就 set AUTO_MODE 0）。
        set_value MODE "$_m" >/dev/null || exit 1
        sh "$MODDIR/sched/apply_sched.sh" "$_m"
        rm -f "$_game_state" 2>/dev/null || true
        # S2：手动切基础模式时，若之前是自动开的去温控，要关掉。
        thermal_auto_off || true
        ;;
    apply)
        _m="${2:-$MODE}"
        case "$_m" in balanced|performance|powersave|game|peace|valorant) ;; *) echo "ERR 模式不对：$_m"; exit 2 ;; esac
        # S2：切游戏档走 game_sched.sh game（它调 thermal_auto_on，
        # 自动去温控走统一入口），不再直接写状态文件；切基础模式
        # 后删状态文件并关掉之前自动开的去温控。
        case "$_m" in
            game|peace|valorant)
                sh "$MODDIR/sched/game_sched.sh" game
                ;;
            *)
                sh "$MODDIR/sched/apply_sched.sh" "$_m"
                rm -f "$_game_state" 2>/dev/null || true
                thermal_auto_off || true
                ;;
        esac
        ;;
    game)
        case "$2" in
            on|game|peace|valorant) sh "$MODDIR/sched/game_sched.sh" game ;;
            off) sh "$MODDIR/sched/game_sched.sh" off ;;
            *) echo "ERR game 只能是 on|off（peace|valorant 是 on 的别名）"; exit 2 ;;
        esac
        ;;
    thread) cmd_thread "$2" ;;
    zram) cmd_zram "$2" "$3" "$4" ;;
    thermal) cmd_thermal "$2" ;;
    vulkan) cmd_vulkan "$2" ;;
    verify) sh "$MODDIR/sched/verify.sh" ;;
    uclamp-diag) sh "$MODDIR/sched/uclamp_diag.sh" ;;
    oshare-diag) sh "$MODDIR/sched/oshare_diag.sh" ;;
    log)
        # 0.4.42：日志按类别分文件。用法：log [CAT] [N]，CAT 是英文键
        # sched（调度日志.log，默认）|thermal（温控）|zram（内存）|
        # diag（诊断），N 默认 80。中文文件名只在脚本内部映射
        # （sched_log_file），不经过 WebUI 的 exec 桥。0.4.47 起
        # oshare 类别退役，传进来按错类别报错。
        # 老用法 log [N]（$2 是数字）照样能用。
        _cat="main"; _n=80
        case "$2" in
            sched) _cat="main"; _n="${3:-80}" ;;
            thermal|zram|diag) _cat="$2"; _n="${3:-80}" ;;
            '') ;;
            *[!0-9]*) echo "ERR log 类别只能是 sched|thermal|zram|diag，行数是数字"; exit 2 ;;
            *) _n="$2" ;;
        esac
        case "$_n" in ''|*[!0-9]*) _n=80 ;; esac
        _lf=$(SCHED_LOG_CAT="$_cat" sched_log_file)
        if [ -f "$_lf" ]; then tail -n "$_n" "$_lf" 2>/dev/null; else echo "暂无日志（还没跑过调度脚本）"; fi
        ;;
    clearlog)
        # 只截断日志文件，不停 watch、不改调度。脚本每次写日志都用 >> 追加，
        # 所以运行中的 watch 不会因为截断丢句柄。
        # 0.4.42：clearlog [CAT]，CAT 同 log（默认 sched）；只清选中的那个文件。
        _cat="main"
        case "$2" in
            sched) _cat="main" ;;
            thermal|zram|diag) _cat="$2" ;;
            '') ;;
            *) echo "ERR clearlog 类别只能是 sched|thermal|zram|diag"; exit 2 ;;
        esac
        _lf=$(SCHED_LOG_CAT="$_cat" sched_log_file)
        if [ -f "$_lf" ]; then
            printf '' > "$_lf" 2>/dev/null && echo "OK 日志已清空" || { echo "ERR 清空失败"; exit 1; }
        else
            echo "暂无日志（还没跑过调度脚本）"
        fi
        ;;
    *)
        echo "用法: panel.sh status|status-fast|state|fg|get|set KEY VALUE|setmany KEY=VALUE...|mode MODE|apply [MODE]|game on|off|thread ...|zram ...|thermal status|on|off|vulkan on|off|status|probe|verify|uclamp-diag|oshare-diag|log [CAT] [N]|clearlog [CAT]"
        exit 2
        ;;
esac
