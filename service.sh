#!/system/bin/sh
# service.sh - Magisk / KernelSU / APatch 开机服务
# 等系统启动完成后再调，避免和开机初期的厂商调度打架、避免被覆盖后
# 还没生效就被误判。调完只记日志，不常驻、不轮询。
# M15：开机早期 PATH 未必含 /system/bin，裸命令可能找不到——
# 文件头固定 PATH，getprop 也用绝对路径。
export PATH=/system/bin:/sbin:$PATH
case "${0%/*}" in
    "$0") MODDIR="." ;;
    *) MODDIR="${0%/*}" ;;
esac

# 0.4.28：日志去重。watch 的 stdout 本来就重定向回了日志文件，
# sched_log 再回显一次等于同一行写两遍；这里关掉回显，日志只留
# 带时间戳的那一份（线程表是 plain echo，不走 sched_log，不受影响）。
# 开机 apply 本来就丢到 /dev/null，不受影响。
export SCHED_LOG_QUIET=1

# S27：service.sh 也要 load_config 再判值（grep 原文会把
# AUTO_WATCH_ON_BOOT=10 误判成开、把带空格的写法误判成关，
# 还和 source 认最后一行的规则打架）。
# shellcheck disable=SC1091
. "$MODDIR/sched/lib.sh"
load_config "$MODDIR/sched/config.conf"

if [ -n "${SCHED_TEST_ROOT:-}" ]; then _td="$SCHED_TEST_ROOT"; else _td="/data/local/tmp"; fi

# --- watch 守护（0.4.60）---
# 病根之二：以前 service.sh 把 watch 拉起来就再也不管，watch 卡死
# （多半是某个系统命令无限等，见 lib.sh 的 run_to）后永远没人拉起，
# 只能靠重启平板（2026-11-21 真机卡死约 65 分钟）。守护每 60 秒
# 看一眼 watch 的心跳文件：超过 180 秒没更新、且没有停用标记
# （thread.sh stop 落的，用户手动停的不许拉回），就杀掉旧 watch
# 重新拉起，并记一行 WARN。正常巡检不记日志。
# WATCH_GUARD_INTERVAL / WATCH_GUARD_STALE 只给模拟测试调小，
# 生产不设、走默认 60 / 180。
WATCH_GUARDIAN_PIDFILE="$_td/oneplus_watch_guardian.pid"
_watch_guardian() {
    echo $$ > "$WATCH_GUARDIAN_PIDFILE" 2>/dev/null || true
    _g_interval="${WATCH_GUARD_INTERVAL:-60}"
    case "$_g_interval" in ''|*[!0-9]*|0) _g_interval=60 ;; esac
    _g_stale="${WATCH_GUARD_STALE:-180}"
    case "$_g_stale" in ''|*[!0-9]*|0) _g_stale=180 ;; esac
    while true; do
        sleep "$_g_interval"
        # 停用标记在：用户手动停的，守护自己退出，不跟 stop 打架。
        if [ -f "$_td/oneplus_watch_disabled" ]; then
            rm -f "$WATCH_GUARDIAN_PIDFILE" 2>/dev/null
            return 0
        fi
        # 模块目录没了（已卸载）：守护跟着退出，别再试图拉起。
        if [ ! -f "$MODDIR/sched/thread.sh" ]; then
            rm -f "$WATCH_GUARDIAN_PIDFILE" 2>/dev/null
            return 0
        fi
        _g_last=$(cat "$_td/oneplus_watch_heartbeat" 2>/dev/null | tr -d ' \t\r\n')
        case "$_g_last" in ''|*[!0-9]*) _g_last=0 ;; esac
        _g_now=$(date +%s 2>/dev/null)
        case "$_g_now" in ''|*[!0-9]*) continue ;; esac
        [ $((_g_now - _g_last)) -le "$_g_stale" ] && continue
        # 心跳过期：watch 卡死或已死。pidfile 里的旧 pid 还活着先
        # 杀（TERM 等 2 秒，不行就 -9——卡在系统调用里的 watch 收
        # 不到 TERM 的 trap，只能强杀），确认死了再拉新的。
        _g_old=$(cat "$_td/oneplus_thread_watch.pid" 2>/dev/null | tr -d ' \t\r\n')
        case "$_g_old" in ''|*[!0-9]*) _g_old="" ;; esac
        if [ -n "$_g_old" ] && kill -0 "$_g_old" 2>/dev/null; then
            kill "$_g_old" 2>/dev/null
            sleep 2
            kill -9 "$_g_old" 2>/dev/null
            _g_k=0
            while kill -0 "$_g_old" 2>/dev/null && [ "$_g_k" -lt 30 ]; do
                sleep 0.1 2>/dev/null || sleep 1
                _g_k=$((_g_k + 1))
            done
        fi
        rm -f "$_td/oneplus_thread_watch.pid" 2>/dev/null
        nohup sh "$MODDIR/sched/thread.sh" watch >> "$LOGFILE" 2>&1 &
        # 拉起时刻先替新 watch 垫一拍心跳：它自己几秒内就会接上，
        # 垫这一拍是防守护下一轮巡检抢在它第一拍之前、把刚拉起
        # 的又误判成卡死（防重启抖动）。
        date +%s > "$_td/oneplus_watch_heartbeat" 2>/dev/null || true
        sched_log "WARN watch 心跳超时（>${_g_stale}s），已自动重启"
    done
}
# 守护子命令：service.sh guardian 只跑守护循环，不走开机流程。
if [ "${1:-}" = "guardian" ]; then
    _watch_guardian
    exit 0
fi
# 单实例启动：已有一个守护在跑（pid 还活着、且确实是 service.sh）
# 就不重复起。
_guardian_start() {
    if [ -f "$WATCH_GUARDIAN_PIDFILE" ]; then
        _gold=$(cat "$WATCH_GUARDIAN_PIDFILE" 2>/dev/null | tr -d ' \t\r\n')
        case "$_gold" in
            ''|*[!0-9]*) ;;
            *)
                if kill -0 "$_gold" 2>/dev/null && tr '\0' ' ' < "/proc/$_gold/cmdline" 2>/dev/null | grep -q 'service\.sh'; then
                    return 0
                fi
                ;;
        esac
    fi
    nohup sh "$MODDIR/service.sh" guardian >> "$LOGFILE" 2>&1 &
}

# 等待启动完成，最多 90 秒；超时也继续（部分平板 boot_completed 晚到）
i=0
while [ "$(/system/bin/getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ $i -lt 90 ]; do
    sleep 1
    i=$((i + 1))
done
if [ "$(/system/bin/getprop sys.boot_completed 2>/dev/null)" != "1" ]; then
    sched_log "WARN service 等启动完成超时 90 秒，继续开机流程"
fi
sleep 5

# 再等 10 秒让厂商 Power HAL / 潮汐架构先落好它的默认值，我们后写
sleep 10

# M15：三个步骤失败时记一行 FAIL（不要 >/dev/null 2>&1 || true 全吞
# 掉）。成功时输出丢弃——apply_sched.sh 的 sched_log 自己已经写进
# 日志文件一份了，这里再 >> 到日志就是第二份；失败时才把输出追加
# 进日志，方便定位。
# S1（0.4.50）：退出码必须在命令跑完后立刻存——旧写法把 "$@" 放进
# if 条件、fi 之后再取 $?，无 else 的 if 条件为假时整体退出码是 0，
# 失败也永远记 rc=0，排障会被误导。临时文件也从 ${TMPDIR:-/tmp}
# 换到 $_td（/data/local/tmp）：那边写不了时重定向先失败、命令根本
# 没被执行，同样只剩一行假 rc。
_service_step() {
    _sname="$1"; shift
    _sout="$_td/service_step.$$.log"
    "$@" >"$_sout" 2>&1
    _src=$?
    if [ "$_src" = "0" ]; then
        rm -f "$_sout" 2>/dev/null
        return 0
    fi
    sched_log "FAIL service $_sname 失败 rc=$_src"
    cat "$_sout" >> "$LOGFILE" 2>/dev/null || true
    rm -f "$_sout" 2>/dev/null
    return "$_src"
}

# 0.4.12：apply_sched.sh 的输出 sched_log 自己已经写进日志文件
# 一份了，这里再 >> 到日志就是第二份。改丢到 /dev/null，日志里
# 只留一份。watch 那行不动：它的 echo（新前台、线程表）只走
# stdout，不重定向就进不了日志。
_service_step "apply_sched" sh "$MODDIR/sched/apply_sched.sh"

# zram：0.4.23 起按 config.conf 的 ZRAM_ALGO / ZRAM_SIZE_GB 套用一次
# （都没填就不动）。失败也不影响开机，日志里有原因。
_service_step "zram apply" sh "$MODDIR/sched/zram.sh" apply

# 去温控：0.4.29 起按 config.conf 的 THERMAL_REMOVE 套用一次
# （0=不动，horae 写回开；1=挂载温控配置替换 + 伪装温度 + 关 horae）。
# 配置替换其实在 post-fs-data.sh 里已经挂过了，这里再跑一次是兜底。
_service_step "thermal apply" sh "$MODDIR/sched/thermal.sh" apply

# 互传常开 hook APK（0.4.46）：没装/版本旧就装模块内置的 APK。
# oshare_hook.sh 自己把结果记进调度日志（0.4.47 起互传日志分类
# 退役）、永远返回 0，装失败不影响开机其他流程；APK 不在就整段跳过。
_service_step "oshare_hook ensure" sh "$MODDIR/sched/oshare_hook.sh" ensure

# M3：开机清理残留状态文件。重启后 sysfs 已回原厂，残留的状态文件
# 会撒谎（watch 见 state=game 就跳过 apply，首局游戏跑在均衡档；
# 残留的 thermal_auto 状态也会让自动去温控跳过）。套用基础模式后、
# 启动 watch 前清掉，开机即“不在游戏档”是确定的事实。
# 0.4.60：心跳和停用标记也一起清——残留的旧心跳会让守护误判，
# 残留的停用标记会让守护开机就退出（停用是上次手动停的会话级
# 决定，不跨重启）。
rm -f "$_td/oneplus_game_sched_state" "$_td/oneplus_thermal_auto" "$_td/oneplus_thread_state" "$_td/oneplus_auto_mode" "$_td/oneplus_watch_heartbeat" "$_td/oneplus_watch_disabled"
sched_log "INFO service 已清残留状态文件（开机重建）"

# 线程自动绑定：0.4.3 起默认开（AUTO_WATCH_ON_BOOT=1），开机在后台
# 启动 watch，前台应用换了自动重绑。想关就把 config.conf 里改成 0。
# 0.4.48：重定向目标用 lib.sh 解析好的 LOGFILE（内部存储的
# “调度器日志”文件夹，建不了/写不了才回落 /data/local/tmp），
# 不再写死 $_td 下的路径。
if [ "${AUTO_WATCH_ON_BOOT:-1}" = "1" ]; then
    nohup sh "$MODDIR/sched/thread.sh" watch >> "$LOGFILE" 2>&1 &
    # 0.4.60：守护跟着 watch 一起起（单实例），watch 卡死自动拉起；
    # AUTO_WATCH_ON_BOOT=0 时守护也不起（上面那个分支管）。
    _guardian_start
else
    sched_log "INFO service AUTO_WATCH_ON_BOOT=0，watch 不启动"
fi
