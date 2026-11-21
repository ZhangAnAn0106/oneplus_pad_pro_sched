#!/system/bin/sh
# apply_sched.sh - 性能调度模块（开机由 service.sh 调用，也可手动跑）
# 只做“可逆调校”：全部写 sysfs / cpuset / cpuctl，重启即恢复原厂。
# 热管理、温控、电压一律不碰。任何节点不存在就跳过并记日志。
# （去温控不走这里：0.4.29 起由 thermal.sh 单独管，THERMAL_REMOVE 开关
# 控制，默认关；本脚本自己仍不碰温控。）
#
# 模式：balanced（默认）| performance | powersave | game
#   game 是唯一的游戏模式：和平精英 / 无畏契约的特调（0.4.14 前叫
#   peace / valorant）0.4.15 起统一并进游戏模式，参数就是原来和平
#   精英那套。由 thread.sh watch/auto 在检测到游戏进程时自动切入，
#   退出游戏切回 balanced；也可手动跑：
#     apply_sched.sh game
#   peace / valorant 只留作别名，调它们一样进游戏模式。
#   性能和游戏的差距（都在下面写死的值里）：
#     性能：日常最强——升频拉满、降频 5000us、hispeed 90、uclamp
#       只有 fg 51、GPU 不抬、foreground 全核、不绑线程。
#     游戏：性能那套再加——降频留 10000us（高频拿得更久）、hispeed
#       85（更早拉高频）、uclamp 只有 fg 77、GPU 下限抬到 35%
#       （约 316MHz）、foreground 只放中+大核、再按线程分类绑核
#       （主/游戏线程独占超大核）。
#   0.4.38：top-app min 和所有 uclamp.max 都不写了——这台内核的
#   max 只认字面量 'max'，数字写不进去（1024/512/256 全失败）；
#   top-app min=153 也被拒。只留 foreground min（游戏 77 / 性能
#   51 / 日常 0），诊断已证能写；后台收紧本来就靠 cpuset 限在小核
#   上，不丢效果。见 apply_uclamp 里的拦截注释。
#   游戏模式不锁最高频、不碰温控，只调响应速度、分组、uclamp 下限和 GPU
#   下限，数值见 config.conf 的 GAME_* 项。
#
# 用法（root）：
#   sh /data/adb/modules/oneplus_pad_pro_sched/sched/apply_sched.sh [balanced|performance|powersave|game]
# 日志：内部存储“调度器日志”文件夹/调度日志.log（文件夹建不了时
# 回落 /data/local/tmp；实际路径以 lib.sh 解析的 LOGFILE 为准）

MODDIR="${0%/*}/.."
# 测试时允许用环境变量指定模块根
if [ -n "$SCHED_TEST_MODDIR" ]; then MODDIR="$SCHED_TEST_MODDIR"; fi
# shellcheck disable=SC1091
. "$MODDIR/sched/lib.sh"
load_config "$MODDIR/sched/config.conf"
if [ -n "$1" ]; then MODE="$1"; fi
: "${MODE:=balanced}"
# M16：模式名校验。game/peace/valorant 只认命令行参数（手动进游戏档），
# 配置文件里写游戏模式是配错了：强制按 balanced 处理并告警，避免
# game_sched.sh off 再把游戏档套一遍、永远退不出。
case "$MODE" in
    balanced|performance|powersave|game|peace|valorant) ;;
    *)
        sched_log "FAIL apply_sched: 非法模式 MODE=$MODE（只认 balanced|performance|powersave|game|peace|valorant）"
        exit 2
        ;;
esac
if [ -z "$1" ]; then
    case "$MODE" in
        game|peace|valorant)
            sched_log "WARN apply_sched: 配置文件 MODE=$MODE 是游戏模式，不存进 MODE，强制按 balanced 处理"
            MODE=balanced
            ;;
    esac
fi

sched_log "=== apply_sched start mode=$MODE ==="
detect_clusters

# --- 按模式解析游戏参数（game = 原来和平精英那套值）---
IS_GAME=0
case "$MODE" in
    game|peace|valorant) IS_GAME=1 ;;
esac
if [ "$IS_GAME" = "1" ]; then
    _up="${GAME_SCHEDUTIL_UP_US:-0}"
    _down="${GAME_SCHEDUTIL_DOWN_US_PEACE:-10000}"
    _hispeed="${GAME_HISPEED_LOAD_PEACE:-85}"
    _gpu_pct="${GAME_GPU_MIN_FREQ_PCT_PEACE:-35}"
    # 0.4.38：游戏档 uclamp 只剩 foreground min。GAME_TOP_APP_UCLAMP_MIN_PEACE
    # 和 GAME_BACKGROUND_UCLAMP_MAX 还留在 config 里备查，但这里不再读
    # 它们（top-app min=153 被拒、数字 max 写不进去，见 apply_uclamp）。
    _fg_min="${GAME_FOREGROUND_UCLAMP_MIN_PEACE:-77}"
fi

# ---------- 1. CPU 调频器 + schedutil ----------
for _pol in "$SYS"/devices/system/cpu/cpufreq/policy*; do
    [ -d "$_pol" ] || continue
    _gov="$_pol/scaling_governor"
    if [ -n "$GOVERNOR" ] && [ "$GOVERNOR" != "-1" ]; then
        write_node "$_gov" "$GOVERNOR"
    fi
    _su="$_pol/schedutil"
    if [ -d "$_su" ]; then
        case "$MODE" in
            performance)
                write_node "$_su/up_rate_limit_us" "0"
                write_node "$_su/down_rate_limit_us" "5000"
                ;;
            powersave)
                write_node "$_su/up_rate_limit_us" "2000"
                write_node "$_su/down_rate_limit_us" "50000"
                ;;
            game|peace|valorant)
                write_node "$_su/up_rate_limit_us" "$_up"
                write_node "$_su/down_rate_limit_us" "$_down"
                ;;
            *)
                write_node "$_su/up_rate_limit_us" "${SCHEDUTIL_UP_RATE_LIMIT_US:-500}"
                write_node "$_su/down_rate_limit_us" "${SCHEDUTIL_DOWN_RATE_LIMIT_US:-10000}"
                ;;
        esac
        if [ -n "$SCHEDUTIL_IOWAIT_BOOST" ]; then
            write_node "$_su/iowait_boost_enable" "$SCHEDUTIL_IOWAIT_BOOST"
        fi
        # hispeed_* 只在部分内核存在，存在才写，不存在就跳过。
        # 游戏模式用更低的 hispeed_load（更早拉高频），日常模式用 90。
        if [ "$IS_GAME" = "1" ]; then
            write_node "$_su/hispeed_load" "$_hispeed"
        else
            write_node "$_su/hispeed_load" "90"
        fi
    fi
    # 频率上下限：默认不锁。配置里没有频率项就是故意不锁，
    # 避免和厂商 Power HAL / 潮汐架构打架。
done

# ---------- 2. cpuset 分组 ----------
# cpuset 在 $DEV/cpuset；个别 ROM 也在 $SYS/fs/cgroup/cpuset 下，
# 两个位置都试，写得进去的那个生效。只写第一个存在的根（两个根常是
# 同一挂载的不同视图，写两遍是重复劳动）；写失败再试第二个根。
apply_cpuset() {
    _group="$1"; _list="$2"
    _tried=0
    for _root in "$DEV/cpuset" "$SYS/fs/cgroup/cpuset"; do
        _f="$_root/$_group/cpus"
        if [ -e "$_f" ]; then
            _tried=1
            if write_node "$_f" "$_list"; then return 0; fi
        fi
    done
    if [ "$_tried" = "0" ]; then
        sched_log "SKIP cpuset $_group 不存在（两个根都没有）"
    fi
}
case "$MODE" in
    game|peace|valorant)
        # CPUSET_* 仅均衡档生效（见 config.conf），本档 cpuset 写死。
        apply_cpuset "top-app" "$ALL_LIST"
        apply_cpuset "foreground" "$BIG_LIST"
        apply_cpuset "background" "$LITTLE_LIST"
        apply_cpuset "system-background" "$LITTLE_LIST"
        apply_cpuset "restricted" "$LITTLE_LIST"
        ;;
    performance)
        # CPUSET_* 仅均衡档生效（见 config.conf），本档 cpuset 写死。
        apply_cpuset "top-app" "$ALL_LIST"
        apply_cpuset "foreground" "$ALL_LIST"
        apply_cpuset "background" "$LITTLE_LIST"
        apply_cpuset "system-background" "$MID_LITTLE_LIST"
        apply_cpuset "restricted" "$LITTLE_LIST"
        ;;
    powersave)
        # CPUSET_* 仅均衡档生效（见 config.conf），本档 cpuset 写死。
        apply_cpuset "top-app" "$BIG_LIST"
        apply_cpuset "foreground" "$MID_LITTLE_LIST"
        apply_cpuset "background" "$LITTLE_LIST"
        apply_cpuset "system-background" "$LITTLE_LIST"
        apply_cpuset "restricted" "$LITTLE_LIST"
        ;;
    *)
        apply_cpuset "top-app" "$(policy_to_list "$CPUSET_TOP_APP")"
        apply_cpuset "foreground" "$(policy_to_list "$CPUSET_FOREGROUND")"
        apply_cpuset "background" "$(policy_to_list "$CPUSET_BACKGROUND")"
        apply_cpuset "system-background" "$(policy_to_list "$CPUSET_SYSTEM_BACKGROUND")"
        apply_cpuset "restricted" "$(policy_to_list "$CPUSET_RESTRICTED")"
        ;;
esac

# ---------- 3. uclamp ----------
# uclamp.min/max 在 /dev/cpuctl/<group>/cpu.uclamp.*，-1 = 不碰。
# 只写第一个存在的根（两个根常是同一挂载的不同视图）；写失败再试
# 第二个根；两个根都不存在才记一行 SKIP（S4：不再每个组刷两行噪音）。
# 两个根都写失败时记 FAIL 并累加到 _UCLAMP_FAIL，apply 末尾汇总告警。
_UCLAMP_FAIL=0
apply_uclamp() {
    _group="$1"; _min="$2"; _max="$3"
    # 0.4.38 拦截：这台内核的 max 只认字面量 'max'，数字写不进去
    # （0.4.37 真机诊断：max=1024/512/256 全 rc=1、stderr 为空，写回
    # 'max' 成功）；top-app min=153 也被拒。min=0、min=77 写成功。
    # 所以 max 永不写，top-app 的 min 也永不写；只留 foreground min
    #（游戏 77 / 性能 51 / 日常 0）。后台收紧本来就靠 cpuset 限在小
    # 核（0,1）上，不丢效果。这里强制拦截，调用点或用户配置里即使还
    # 传了值也不会写出去——配置升级保留会留着旧的 512/256，光改调用
    # 点和默认值拦不住，必须在这里兜底。
    _max="-1"
    if [ "$_group" = "top-app" ]; then _min="-1"; fi
    if [ "$_min" = "-1" ] && [ "$_max" = "-1" ]; then return 0; fi
    _tried=0
    for _root in "$DEV/cpuctl" "$SYS/fs/cgroup/cpu"; do
        _need=0
        if [ "$_min" != "-1" ] && [ -e "$_root/$_group/cpu.uclamp.min" ]; then _need=1; fi
        if [ "$_max" != "-1" ] && [ -e "$_root/$_group/cpu.uclamp.max" ]; then _need=1; fi
        [ "$_need" = "1" ] || continue
        _tried=1
        _ok=1
        if [ "$_min" != "-1" ]; then write_node "$_root/$_group/cpu.uclamp.min" "$_min" || _ok=0; fi
        if [ "$_max" != "-1" ]; then write_node "$_root/$_group/cpu.uclamp.max" "$_max" || _ok=0; fi
        if [ "$_ok" = "1" ]; then return 0; fi
        # 这个根写失败，继续试第二个根
    done
    if [ "$_tried" = "0" ]; then
        sched_log "SKIP uclamp $_group 不存在（两个根都没有）"
        return 0
    fi
    sched_log "FAIL uclamp $_group min=$_min max=$_max 两个根都写失败"
    _UCLAMP_FAIL=$((_UCLAMP_FAIL+1))
    return 0
}
# M2/S30：存 uclamp 原值（只存一次）。先写临时文件再 mv 原子替换，
# 中途被杀也不会留半截文件；存的是“路径 值”一行一条。
# 0.4.36：这台内核把 uclamp 值报成浮点（"0.00"、"77.00"），存原样
# 的话恢复循环的数字检查（*[!0-9]*）会把带小数点的全跳过、原值
# 一行都写不回去。存的时候就把小数部分去掉（${_v%%.*}，和 lib.sh
# 哨兵的读回规范化同款），文件里只留整数。
save_uclamp_orig() {
    [ -f "$UCLAMP_ORIG" ] && return 0
    _tmp="$UCLAMP_ORIG.tmp.$$"
    printf '' > "$_tmp" 2>/dev/null || return 0
    for _g in top-app foreground background; do
        for _root in "$DEV/cpuctl" "$SYS/fs/cgroup/cpu"; do
            for _f in cpu.uclamp.min cpu.uclamp.max; do
                if [ -r "$_root/$_g/$_f" ]; then
                    _v=$(cat "$_root/$_g/$_f" 2>/dev/null)
                    _v=${_v%%.*}
                    echo "$_root/$_g/$_f $_v" >> "$_tmp" 2>/dev/null || true
                fi
            done
        done
    done
    mv "$_tmp" "$UCLAMP_ORIG" 2>/dev/null || rm -f "$_tmp" 2>/dev/null || true
}
if [ "$MODE" = "performance" ]; then
    save_uclamp_orig
    # 0.4.38：只写 foreground min=51。top-app min=102 被拒、background
    # max=512 写不进去，都不写了（apply_uclamp 里也有拦截，双保险）。
    apply_uclamp "foreground" "51" "-1"
elif [ "$IS_GAME" = "1" ]; then
    save_uclamp_orig
    # 0.4.38：只写 foreground min=77。top-app min 和 background max
    # 同上，不写。
    apply_uclamp "foreground" "$_fg_min" "-1"
else
    # 切回日常：先把游戏/性能模式存的原值写回去，再按 config 写日常值
    #（日常 foreground 是 -1 不写，原值就保留下来了；0.4.38：top-app
    # min 和所有 max 本来就不写，恢复循环里 max 是 'max' 字符串、按
    # 非数字静默跳过，min=0 写回去是成功的）。
    _had_orig=0
    if [ -f "$UCLAMP_ORIG" ]; then
        _had_orig=1
        _restore_fail=0
        # 0.4.36：读出来先把小数部分去掉再做数字检查。旧版存的原值
        # 文件里可能是 "0.00"/"77.00"（这台内核报浮点），不去掉的话
        # case 的 *[!0-9]* 会把它们全当非法值跳过、原值一行都写不回
        # 去，前台 uclamp.min 就卡在 77，verify_game_restored 报失败。
        while read -r _p _v; do
            _v=${_v%%.*}
            case "$_v" in ''|*[!0-9]*) ;; *) write_node "$_p" "$_v" || _restore_fail=$((_restore_fail+1)) ;; esac
        done < "$UCLAMP_ORIG" 2>/dev/null || true
        if [ "$_restore_fail" = "0" ]; then
            rm -f "$UCLAMP_ORIG" 2>/dev/null || true
        else
            sched_log "WARN uclamp 原值恢复失败 $_restore_fail 处，保留 $UCLAMP_ORIG 以便下次重试"
        fi
    fi
    # M2：无原值文件时，foreground 的 min 显式写回 0 而不是依赖 -1
    #（apply_uclamp 遇到双 -1 直接 return，性能档写的 51 会泄漏）。
    # 0.4.38：top-app min 不再写（性能/游戏档都不写它），这句兜底只剩
    # foreground；config 里配了非 -1 的值时仍以 config 为准。
    _daily_fg_min="${FOREGROUND_UCLAMP_MIN:--1}"
    if [ "$_had_orig" = "0" ] && [ "$_daily_fg_min" = "-1" ]; then _daily_fg_min="0"; fi
    apply_uclamp "foreground" "$_daily_fg_min" "-1"
fi

# ---------- 4. 内核调度参数（默认关闭，需配置里 SCHED_TUNABLES=1；
#   0.4.15 起游戏模式不再写迁移成本） ----------
if [ "${SCHED_TUNABLES:-0}" = "1" ]; then
    write_node "$PROC/sys/kernel/sched_migration_cost_ns" "${SCHED_MIGRATION_COST_NS:-500000}"
    write_node "$PROC/sys/kernel/sched_min_granularity_ns" "${SCHED_MIN_GRANULARITY_NS:-1000000}"
    write_node "$PROC/sys/kernel/sched_wakeup_granularity_ns" "${SCHED_WAKEUP_GRANULARITY_NS:-2000000}"
    write_node "$PROC/sys/kernel/sched_latency_ns" "${SCHED_LATENCY_NS:-12000000}"
else
    sched_log "INFO sched_* 内核参数未启用（SCHED_TUNABLES=0），保持原厂"
fi

# ---------- 5. GPU（只读 + 可选 min_freq，日常默认不锁；
#   游戏模式按 GAME_GPU_MIN_FREQ_PCT_PEACE 抬高下限，防 GPU 升频迟） ----------
# M12：抬高前先把原 min_freq 存进 $GPU_MIN_FREQ_ORIG（原子写），切回
# 日常时只在存过原值时才写回；没存过就不写，不洗掉原厂值和手动调过的值。
_gpu_orig_fail=0
_gpu_restored=0
for _gpu in "$SYS"/class/devfreq/*kgsl-3d0* "$SYS"/class/kgsl/kgsl-3d0; do
    [ -e "$_gpu" ] || continue
    _gov_now=$(read_node "$_gpu/governor")
    sched_log "INFO gpu $_gpu governor=${_gov_now:-?} min=$(read_node "$_gpu/min_freq") max=$(read_node "$_gpu/max_freq")"
    _pct="0"
    if [ "$IS_GAME" = "1" ]; then _pct="$_gpu_pct"; else _pct="${GPU_MIN_FREQ_PCT:-0}"; fi
    # S21：百分比校验。非数字在 dash 算术里变 0、超大值 32 位溢出变负数，
    # 都会静默写成最低 OPP——非法值记日志，不写。
    case "$_pct" in
        ''|*[!0-9]*)
            sched_log "FAIL gpu pct 非法：${_pct:-空}（mode=$MODE），不写 min_freq"
            _pct="0"
            ;;
        *)
            if [ "$_pct" -gt 100 ]; then
                sched_log "FAIL gpu pct 超出范围：$_pct（>100），不写 min_freq"
                _pct="0"
            fi
            ;;
    esac
    if [ "$_pct" != "0" ]; then
        _gmax=$(read_node "$_gpu/max_freq")
        case "$_gmax" in ''|*[!0-9]*) ;; *)
            # 0.4.2：先除后乘，避免 32 位 shell 算术溢出。旧式
            # _gmax*_pct/100 在 max=903000000、pct=25 时溢出成
            # 11001635（11MHz）写进 min_freq。再按
            # available_frequencies 取整到真实 OPP，避免写一个
            # 不存在的频率；目标低于最低 OPP 时取最低 OPP。
            _gmin=$((_gmax / 100 * _pct))
            if [ -r "$_gpu/available_frequencies" ]; then
                _clamped=""
                for _f in $(cat "$_gpu/available_frequencies" 2>/dev/null); do
                    case "$_f" in ''|*[!0-9]*) ;; *)
                        if [ "$_f" -ge "$_gmin" ]; then
                            if [ -z "$_clamped" ] || [ "$_f" -lt "$_clamped" ]; then _clamped="$_f"; fi
                        fi ;;
                    esac
                done
                if [ -n "$_clamped" ]; then
                    _gmin="$_clamped"
                else
                    _gmin="$_gmax"
                fi
            fi
            # 抬高前存原值（只存一次，原子写）。
            if [ ! -f "$GPU_MIN_FREQ_ORIG" ]; then
                _cur_min=$(read_node "$_gpu/min_freq")
                case "$_cur_min" in ''|*[!0-9]*) ;; *)
                    _gtmp="$GPU_MIN_FREQ_ORIG.tmp.$$"
                    if echo "$_cur_min" > "$_gtmp" 2>/dev/null; then
                        mv "$_gtmp" "$GPU_MIN_FREQ_ORIG" 2>/dev/null || rm -f "$_gtmp" 2>/dev/null || true
                    else
                        rm -f "$_gtmp" 2>/dev/null || true
                    fi
                    ;;
                esac
            fi
            write_node "$_gpu/min_freq" "$_gmin"
            ;;
        esac
    elif [ "$IS_GAME" != "1" ] && [ -f "$GPU_MIN_FREQ_ORIG" ]; then
        _orig_gpu=$(cat "$GPU_MIN_FREQ_ORIG" 2>/dev/null)
        case "$_orig_gpu" in ''|*[!0-9]*)
            sched_log "WARN gpu 原值文件内容非法：${_orig_gpu:-空}，保留 $GPU_MIN_FREQ_ORIG"
            _gpu_orig_fail=1
            ;;
        *)
            _gpu_restored=1
            write_node "$_gpu/min_freq" "$_orig_gpu" || _gpu_orig_fail=1
            ;;
        esac
    fi
done
# 至少恢复过一个 GPU 节点、且全部成功，才删原值文件；失败则保留并告警。
if [ "$IS_GAME" != "1" ] && [ "$_gpu_restored" = "1" ] && [ -f "$GPU_MIN_FREQ_ORIG" ]; then
    if [ "$_gpu_orig_fail" = "0" ]; then
        rm -f "$GPU_MIN_FREQ_ORIG" 2>/dev/null || true
    else
        sched_log "WARN gpu min_freq 原值恢复失败，保留 $GPU_MIN_FREQ_ORIG 以便下次重试"
    fi
fi

# ---------- 6. I/O（默认不改） ----------
# S25：调度器精确匹配——读出当前列表逐个比对，子串/正则都不认
# （IO_SCHEDULER=deadline 不能匹配 [mq-deadline]）；read_ahead 与调度器
# 走同一循环，遍历全部块设备（排除 zram/loop/ram），不再只写 sda。
for _q in "$SYS"/block/*/queue; do
    [ -d "$_q" ] || continue
    case "$_q" in
        */zram*/queue|*/loop*/queue|*/ram*/queue) continue ;;
    esac
    if [ -n "$IO_SCHEDULER" ]; then
        _sched="$_q/scheduler"
        if [ -e "$_sched" ]; then
            _found=0
            for _s in $(cat "$_sched" 2>/dev/null | tr -d '[]'); do
                if [ "$_s" = "$IO_SCHEDULER" ]; then _found=1; break; fi
            done
            if [ "$_found" = "1" ]; then
                write_node "$_sched" "$IO_SCHEDULER"
            else
                sched_log "SKIP io scheduler $IO_SCHEDULER 不在列表里（$_sched）"
            fi
        fi
    fi
    if [ "${READ_AHEAD_KB:--1}" != "-1" ]; then
        write_node "$_q/read_ahead_kb" "$READ_AHEAD_KB"
    fi
done

# S24：uclamp 汇总——有组两个根都写失败时，末尾记一行汇总告警，
# 别让“游戏档后台收紧未生效”淹没在日志里。
if [ "$_UCLAMP_FAIL" -gt 0 ]; then
    sched_log "WARN uclamp 写失败 $_UCLAMP_FAIL 组（两个根都写失败），部分 uclamp 值未生效；游戏档后台收紧可能未应用"
fi
sched_log "=== apply_sched done mode=$MODE ==="
sched_log "INFO 恢复方法：卸载本模块并重启，或直接重启（sysfs 改动不持久）"
