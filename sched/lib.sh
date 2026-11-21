#!/system/bin/sh
# lib.sh - 调度模块 / 线程模块共用函数（POSIX sh，不用 bash 特性）
# 设计原则：
#   1. 节点不存在就跳过并记日志，绝不因一个节点缺失而中断；
#   2. CPU 拓扑优先读 cpu_capacity（设备树静态算力值，不随降频变），
#      读不到或无区分时回退到 cpuinfo_max_freq；再读不到用 0-1/2-6/7 回退；
#   3. 测试时可用 SCHED_TEST_ROOT 指向一个模拟 sysfs 树。
#
# 调用方先 source 本文件，再调 detect_clusters / write_node。

# --- 路径根（生产默认空，测试时覆盖）---
SYS_ROOT="${SCHED_TEST_ROOT:-}"
SYS="${SYS_ROOT}/sys"
DEV="${SYS_ROOT}/dev"
PROC="${SYS_ROOT}/proc"

# --- 日志 ---
# 0.4.12：日志上限。watch 每 5 秒一轮、每次切模式都重打一份
# apply 全表，日志几天就能长到 1.9MB（0.4.11 实测 27821 行，
# 其中一半是 sched_log 回显到 stdout 又被重定向回日志的重复行）。
# LOG_MAX_BYTES 到顶时只保留最后 LOG_KEEP_LINES 行并记一行轮转
# 标记，旧内容丢掉——日志是诊断用的，不值得无限长。改 config.conf
# 里的值可调；LOG_MAX_BYTES=0 表示不限（不推荐）。
: "${LOG_MAX_BYTES:=1048576}"
: "${LOG_KEEP_LINES:=4000}"
# --- 日志目录（0.4.48：日志挪到内部存储，她在文件管理器里好找）---
# 解析顺序收敛在这里一处，service.sh / post-fs-data.sh / panel.sh /
# customize.sh 都用这里的结果，不各自写死路径：
#   1. ONEPLUS_SCHED_LOG_DIR 显式指定（测试/排障用）；
#   2. SCHED_TEST_ROOT（模拟测试）→ 测试目录，行为和以前一样；
#   3. C4（0.4.50）：上次解析落下的标记文件（/data/local/tmp/
#      oneplus_sched_logdir，可用 ONEPLUS_SCHED_LOGDIR_MARKER 改）——
#      开机极早期 media 还没就绪的进程会回落 /data/local/tmp、之后的
#      进程走内部存储文件夹，日志被劈到两处；有标记且它指的目录现在
#      确实可写时优先认标记，全模块的日志落到同一处；
#   4. /data/media/0 可写 → 写那里的“调度器日志”子文件夹（不存在
#      就自动建、chmod 1777；文件管理器里就是内部存储根目录下的
#      /storage/emulated/0/调度器日志/）；探测目录可用
#      ONEPLUS_SCHED_MEDIA_DIR 改（测试用）；解析成功后把结果写进
#      标记文件（内容没变就不重复写）；
#   5. 子文件夹建不了/写不了，或 /data/media 还没就绪（比如
#      post-fs-data 极早期）→ 回落 /data/local/tmp 平铺（回落目录
#      里不再建子文件夹）——日志写不了绝不能影响功能。
# 只挪日志：状态文件、pid、uclamp 原值、配置备份的位置一律不动
# （UCLAMP_ORIG 等仍在 /data/local/tmp / 测试目录）。
# 旧日志不搬不删：/data/local/tmp 里已有的日志文件原样留着，
# 新日志从新位置开始写。
# C5（0.4.50）：文件夹和日志文件的权限收紧一档——文件夹 1777（加
# sticky 位：别的应用不能再删/改名 root 的日志文件，她用文件管理
# 器读、建文件都不受影响）；日志文件 0644（所有人可读、只有 root
# 能写，别的应用不能再往里写假日志）。模块所有写日志的进程都是
# root，0644 不影响轮转/清空。
_LOGDIR_MARKER="${ONEPLUS_SCHED_LOGDIR_MARKER:-/data/local/tmp/oneplus_sched_logdir}"
if [ -n "${ONEPLUS_SCHED_LOG_DIR:-}" ]; then
    LOGDIR="$ONEPLUS_SCHED_LOG_DIR"
elif [ -n "$SCHED_TEST_ROOT" ]; then
    LOGDIR="$SCHED_TEST_ROOT"
else
    LOGDIR=""
    if [ -f "$_LOGDIR_MARKER" ]; then
        _marked=$(cat "$_LOGDIR_MARKER" 2>/dev/null | tr -d ' \t\r\n')
        case "$_marked" in
            */调度器日志)
                if [ -d "$_marked" ] && [ -w "$_marked" ]; then LOGDIR="$_marked"; fi
                ;;
        esac
    fi
    if [ -z "$LOGDIR" ] && [ -d "${ONEPLUS_SCHED_MEDIA_DIR:-/data/media/0}" ] && [ -w "${ONEPLUS_SCHED_MEDIA_DIR:-/data/media/0}" ]; then
        _mediadir="${ONEPLUS_SCHED_MEDIA_DIR:-/data/media/0}"
        if [ ! -d "$_mediadir/调度器日志" ]; then
            mkdir -p "$_mediadir/调度器日志" 2>/dev/null || true
        fi
        if [ -d "$_mediadir/调度器日志" ] && [ -w "$_mediadir/调度器日志" ]; then
            chmod 1777 "$_mediadir/调度器日志" 2>/dev/null || true
            LOGDIR="$_mediadir/调度器日志"
            if [ "$(cat "$_LOGDIR_MARKER" 2>/dev/null | tr -d ' \t\r\n')" != "$LOGDIR" ]; then
                # 注意重定向顺序：2>/dev/null 必须写在 > 之前——反过来
                # 时 > 先失败、报错漏到 stderr（父目录不存在时必现，
                # 模拟环境里 /data/local/tmp 不存在就是这么暴露的）。
                # 父目录不在就直接不写标记（回落行为不变）。
                if [ -d "${_LOGDIR_MARKER%/*}" ]; then
                    printf '%s' "$LOGDIR" 2>/dev/null > "$_LOGDIR_MARKER" || true
                fi
            fi
        fi
    fi
    [ -n "$LOGDIR" ] || LOGDIR="/data/local/tmp"
fi
LOGFILE="$LOGDIR/调度日志.log"
if [ -n "$SCHED_TEST_ROOT" ]; then
    UCLAMP_ORIG="$SCHED_TEST_ROOT/oneplus_sched_uclamp_orig"
    GPU_MIN_FREQ_ORIG="$SCHED_TEST_ROOT/oneplus_sched_gpu_min_freq_orig"
else
    UCLAMP_ORIG="/data/local/tmp/oneplus_sched_uclamp_orig"
    GPU_MIN_FREQ_ORIG="/data/local/tmp/oneplus_sched_gpu_min_freq_orig"
fi

# Vulkan 检测缓存（0.4.54）：vulkan.sh probe 写（带时间戳），
# panel.sh 实时状态只读它——probe 要跑 dumpsys，绝不进 panel 的
# 状态查询同步路径（快速和完整都不行，0.4.55）；新鲜度只看时间戳。
if [ -n "$SCHED_TEST_ROOT" ]; then
    VULKAN_PROBE_CACHE="$SCHED_TEST_ROOT/oneplus_vulkan_probe"
else
    VULKAN_PROBE_CACHE="/data/local/tmp/oneplus_vulkan_probe"
fi

# --- 配置备份（0.4.28：升级保留用；0.4.45：主备份换到 /data/adb）---
# 每次保存设置后都同步一份 config.conf 到这里；它在模块目录外面，
# zip 解压盖不到，customize.sh 安装时用它把用户改过的项合并回来。
# 0.4.45：主备份改到 /data/adb——/data/local/tmp 里的备份在真机上
# 丢失过（0.4.44 安装时没找到，zram、互传常开等设置全回了默认），
# tmp 不是可靠的存放点。过渡期主、旧两个位置都写，旧位置只当兜底，
# customize.sh 恢复时按主→旧的顺序找。
# ONEPLUS_SCHED_CONFIG_BAK 可指定位置（测试用）；否则测试走测试目录。
# 测试时只写指定的那一个文件，绝不碰真机的 /data。
if [ -n "${ONEPLUS_SCHED_CONFIG_BAK:-}" ]; then
    CONFIG_BACKUP="$ONEPLUS_SCHED_CONFIG_BAK"
    CONFIG_BACKUP_OLD=""
elif [ -n "${SCHED_TEST_ROOT:-}" ]; then
    CONFIG_BACKUP="$SCHED_TEST_ROOT/oneplus_sched_config.bak"
    CONFIG_BACKUP_OLD=""
else
    CONFIG_BACKUP="/data/adb/oneplus_sched_config.bak"
    CONFIG_BACKUP_OLD="/data/local/tmp/oneplus_sched_config.bak"
fi
backup_config() {
    cp "$1" "$CONFIG_BACKUP" 2>/dev/null || true
    chmod 600 "$CONFIG_BACKUP" 2>/dev/null || true
    if [ -n "$CONFIG_BACKUP_OLD" ]; then
        cp "$1" "$CONFIG_BACKUP_OLD" 2>/dev/null || true
        chmod 600 "$CONFIG_BACKUP_OLD" 2>/dev/null || true
    fi
}

_log_rotate_if_needed() {
    # 0.4.42：分文件轮转。$1 = 要轮转的文件（默认 $LOGFILE）；sched_log
    # 按 SCHED_LOG_CAT 把行写进不同文件后，每个文件各自按 1MB/4000 行轮转。
    _rf="${1:-$LOGFILE}"
    case "$LOG_MAX_BYTES" in ''|0) return 0 ;; esac
    case "$LOG_MAX_BYTES" in *[!0-9]*) return 0 ;; esac
    case "$LOG_KEEP_LINES" in ''|*[!0-9]*) LOG_KEEP_LINES=4000 ;; esac
    [ -f "$_rf" ] || return 0
    _sz=$(wc -c < "$_rf" 2>/dev/null | tr -d ' \t\r\n')
    case "$_sz" in ''|*[!0-9]*) return 0 ;; esac
    [ "$_sz" -ge "$LOG_MAX_BYTES" ] || return 0
    _tmp="$_rf.rot.$$"
    tail -n "$LOG_KEEP_LINES" "$_rf" > "$_tmp" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 0; }
    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO log rotated: kept last $LOG_KEEP_LINES lines (was ${_sz} bytes, cap $LOG_MAX_BYTES)" >> "$_tmp" 2>/dev/null || true
    # 0.4.13：不要 mv 换文件——watch 启动时 >> 重定向绑的是旧 inode，
    # mv 之后 watch 的 stdout/stderr（线程表、detect 回显、报错）会继续
    # 写进已被删的旧文件，新日志里再也看不到（0.4.12 日志实证：轮转后
    # 1488 行带时间戳、0 行裸行，printf 报错轮转后也彻底消失——不是修
    # 好了，是看不见了）。改成原地截断写回，inode 不变，重定向不断。
    cat "$_tmp" > "$_rf" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 0; }
    rm -f "$_tmp" 2>/dev/null || true
    # 0.4.48：轮转是原地写回（inode 不变），权限跟着保住（0.4.50 起
    # 0644，见文件头 C5 说明），她在文件管理器里能直接打开（新建时
    # 的放开在 sched_log 里做）。
    chmod 0644 "$_rf" 2>/dev/null || true
    # 0.4.25：轮转完再验一次大小。正常情况下留下的行肯定比上限小；如果
    # 还超（13:56 那次轮转前文件里就有约 700KB 不是正常日志行，很可能是
    # 之前某次截断留下的空洞/乱数据；或是留的行本身就比上限大），就硬
    # 清空只留一行标记——日志绝不能一直顶着上限，否则下次轮转也白转。
    _sz2=$(wc -c < "$_rf" 2>/dev/null | tr -d ' \t\r\n')
    case "$_sz2" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$_sz2" -ge "$LOG_MAX_BYTES" ]; then
        printf '' > "$_rf" 2>/dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO log rotated: still over cap after trim (${_sz2} bytes), cleared" >> "$_rf" 2>/dev/null || true
        chmod 0644 "$_rf" 2>/dev/null || true
    fi
}

# 0.4.42：日志按类别分文件（D）。SCHED_LOG_CAT 由调用脚本设：
#   main（默认，调度/线程/游戏/模式）→ 调度日志.log（路径不变，
#   只是名字从 oneplus_sched.log 改成中文）
#   thermal（thermal.sh）→ 温控日志.log
#   zram（zram.sh）→ 内存日志.log
#   diag（uclamp_diag.sh / oshare_diag.sh）→ 诊断日志.log
# 0.4.47：oshare 类别退役（互传日志.log 不再写）——面板互传开关和
# watch 补开删了之后没有谁再按这个类别写日志，oshare_hook.sh 的
# ensure 结果改记主日志。传进来 oshare 也回主文件（下面的 *) 分支）。
# 四个文件都在 LOGFILE 同一个目录下（LOGDIR：0.4.48 起生产默认
# /data/media/0/调度器日志 即内部存储根目录下的“调度器日志”文件夹，
# 建不了/写不了回落 /data/local/tmp；测试时是
# SCHED_TEST_ROOT）。中文文件名在 shell 里就是字节串，cat/grep/
# tail 照常用；panel.sh 的 log 命令对外仍用英文类别键（sched/
# thermal/zram/diag），到这里才映射成中文文件名，不经过
# WebUI 的 exec 桥传中文。
# 每个文件各自轮转（同样 1MB / 4000 行）。SCHED_LOG_CAT 没设或
# 不是上面四个值时走主文件。panel.sh log / clearlog 也用它定位文件。
sched_log_file() {
    _d="${LOGFILE%/*}"
    case "${SCHED_LOG_CAT:-main}" in
        thermal) printf '%s\n' "$_d/温控日志.log" ;;
        zram) printf '%s\n' "$_d/内存日志.log" ;;
        diag) printf '%s\n' "$_d/诊断日志.log" ;;
        *) printf '%s\n' "$LOGFILE" ;;
    esac
}

sched_log() {
    # sched_log "OK ... " / "SKIP ... " / "FAIL ..."
    _lf=$(sched_log_file)
    _log_rotate_if_needed "$_lf"
    # 0.4.48：日志在内部存储里，文件是 root 建的，默认权限她在文件
    # 管理器里打不开——新建的日志文件放开到所有人可读（0.4.50 起
    # 0644，不再 0666，见文件头 C5 说明；轮转后在轮转函数里同样
    # 处理）。已存在的文件不重复 chmod，省开销。
    if [ -f "$_lf" ]; then _isnew=0; else _isnew=1; fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$_lf" 2>/dev/null || true
    if [ "$_isnew" = "1" ]; then chmod 0644 "$_lf" 2>/dev/null || true; fi
    # 0.4.28：stdout 回显只在前台有用（面板看结果）。watch / 后台任务的
    # stdout 本来就重定向回了日志文件，回显等于同一行写两遍——0.4.11
    # 的日志一半就是这么来的。那些入口把 SCHED_LOG_QUIET=1 传进来，
    # 这里就不回显，日志只留带时间戳的那一份；线程表是 plain echo，
    # 不走这里，不受影响。
    if [ -z "${SCHED_LOG_QUIET:-}" ]; then echo "$*"; fi
}

# 只在文件存在时写，写失败记 FAIL 不中断。
write_node() {
    _path="$1"; _val="$2"
    if [ ! -e "$_path" ]; then
        sched_log "SKIP missing $_path (want=$_val)"
        return 0
    fi
    if echo "$_val" > "$_path" 2>/dev/null; then
        sched_log "OK $_path=$_val"
        return 0
    else
        sched_log "FAIL $_path (want=$_val)"
        return 1
    fi
}

read_node() {
    _path="$1"
    if [ -r "$_path" ]; then cat "$_path" 2>/dev/null; fi
}

# --- CPU 拓扑自动识别 ---
# 输出（全局变量，空格分隔的核号列表 + 逗号列表 + 掩码）：
#   LITTLE_CPUS / MID_CPUS / PRIME_CPUS / ALL_CPUS
#   LITTLE_LIST / MID_LIST / PRIME_LIST / ALL_LIST   （逗号分隔，给 cpuset）
#   LITTLE_MASK / MID_MASK / PRIME_MASK / ALL_MASK   （十六进制、无 0x 前缀，给 taskset；toybox 不认 0x）
# 规则：优先按 cpu_capacity 分档（最小=小核 A520，最大=超大核 X4，
# 中间=大核 A720）。capacity 是设备树里的静态算力值，不随降频/温控变；
# 旧的 cpuinfo_max_freq 在游戏降频时会被内核下调，导致 2/3/4 号核被
# 误认成超大核（0.4.1 日志实证）。capacity 读不到/无区分时回退到
# 频率法，再读不到用骁龙 8 Gen 3 的常见布局 0-1 小核、2-6 大核、
# 7 超大核，并记日志说明是回退值。
detect_clusters() {
    ALL_CPUS=""
    _i=0
    while [ "$_i" -le 7 ]; do
        if [ -d "$SYS/devices/system/cpu/cpu$_i" ]; then
            ALL_CPUS="$ALL_CPUS $_i"
        fi
        _i=$((_i + 1))
    done
    if [ -z "$ALL_CPUS" ]; then ALL_CPUS="0 1 2 3 4 5 6 7"; fi

    LITTLE_CPUS=""; MID_CPUS=""; PRIME_CPUS=""
    _min_cap=""; _max_cap=""
    for _c in $ALL_CPUS; do
        _cap=$(read_node "$SYS/devices/system/cpu/cpu$_c/cpu_capacity")
        case "$_cap" in
            ''|*[!0-9]*) _cap="" ;;
        esac
        if [ -n "$_cap" ]; then
            if [ -z "$_min_cap" ] || [ "$_cap" -lt "$_min_cap" ]; then _min_cap="$_cap"; fi
            if [ -z "$_max_cap" ] || [ "$_cap" -gt "$_max_cap" ]; then _max_cap="$_cap"; fi
        fi
    done
    if [ -n "$_min_cap" ] && [ -n "$_max_cap" ] && [ "$_min_cap" != "$_max_cap" ]; then
        if [ -z "${DETECT_QUIET:-}" ]; then sched_log "INFO topology method=cpu_capacity cap min=${_min_cap} max=${_max_cap}"; fi
        for _c in $ALL_CPUS; do
            _cap=$(read_node "$SYS/devices/system/cpu/cpu$_c/cpu_capacity")
            case "$_cap" in
                ''|*[!0-9]*) _cap="$_min_cap" ;;
            esac
            if [ "$_cap" = "$_min_cap" ]; then
                LITTLE_CPUS="$LITTLE_CPUS $_c"
            elif [ "$_cap" = "$_max_cap" ]; then
                PRIME_CPUS="$PRIME_CPUS $_c"
            else
                MID_CPUS="$MID_CPUS $_c"
            fi
        done
    else
        # 回退：频率法（0.4.1 的原逻辑）
        _min_freq=""; _max_freq=""
        for _c in $ALL_CPUS; do
            _f=$(read_node "$SYS/devices/system/cpu/cpu$_c/cpufreq/cpuinfo_max_freq")
            case "$_f" in
                ''|*[!0-9]*) _f="" ;;
            esac
            if [ -n "$_f" ]; then
                if [ -z "$_min_freq" ] || [ "$_f" -lt "$_min_freq" ]; then _min_freq="$_f"; fi
                if [ -z "$_max_freq" ] || [ "$_f" -gt "$_max_freq" ]; then _max_freq="$_f"; fi
            fi
        done
        if [ -z "$_min_freq" ] || [ -z "$_max_freq" ] || [ "$_min_freq" = "$_max_freq" ]; then
            sched_log "WARN cpu_capacity 与 cpuinfo_max_freq 都读不到/无区分，用回退布局 0-1小核 2-6大核 7超大核"
            for _c in $ALL_CPUS; do
                case "$_c" in
                    0|1) LITTLE_CPUS="$LITTLE_CPUS $_c" ;;
                    7)   PRIME_CPUS="$PRIME_CPUS $_c" ;;
                    *)   MID_CPUS="$MID_CPUS $_c" ;;
                esac
            done
        else
            if [ -z "${DETECT_QUIET:-}" ]; then sched_log "INFO topology method=cpuinfo_max_freq freq min=${_min_freq}kHz max=${_max_freq}kHz"; fi
            for _c in $ALL_CPUS; do
                _f=$(read_node "$SYS/devices/system/cpu/cpu$_c/cpufreq/cpuinfo_max_freq")
                case "$_f" in
                    ''|*[!0-9]*) _f="$_min_freq" ;;
                esac
                if [ "$_f" = "$_min_freq" ]; then
                    LITTLE_CPUS="$LITTLE_CPUS $_c"
                elif [ "$_f" = "$_max_freq" ]; then
                    PRIME_CPUS="$PRIME_CPUS $_c"
                else
                    MID_CPUS="$MID_CPUS $_c"
                fi
            done
        fi
    fi
    # 兜底：任何一组为空，就用全核，避免 cpuset 被写成空
    if [ -z "$LITTLE_CPUS" ]; then LITTLE_CPUS="$ALL_CPUS"; fi
    if [ -z "$MID_CPUS" ]; then MID_CPUS="$ALL_CPUS"; fi
    if [ -z "$PRIME_CPUS" ]; then PRIME_CPUS="$ALL_CPUS"; fi

    # 空格列表 -> 逗号列表 / 掩码
    _to_list() {
        _out=""; for _c in $1; do
            if [ -z "$_out" ]; then _out="$_c"; else _out="$_out,$_c"; fi
        done; echo "$_out"
    }
    _to_mask() {
        _m=0; for _c in $1; do _m=$((_m + (1 << _c))); done
        # 0.4.5：掩码不带 0x 前缀。0.4.4 日志实证：toybox taskset
        # 拒绝 "0x7c"（bad mask '0x7c'），0/184 线程全败；纯十六进
        # 制（7c）toybox 与 util-linux 都认。
        printf "%x" "$_m"
    }
    ALL_LIST=$(_to_list "$ALL_CPUS");       ALL_MASK=$(_to_mask "$ALL_CPUS")
    LITTLE_LIST=$(_to_list "$LITTLE_CPUS"); LITTLE_MASK=$(_to_mask "$LITTLE_CPUS")
    MID_LIST=$(_to_list "$MID_CPUS");       MID_MASK=$(_to_mask "$MID_CPUS")
    PRIME_LIST=$(_to_list "$PRIME_CPUS");   PRIME_MASK=$(_to_mask "$PRIME_CPUS")
    # 组合
    BIG_CPUS="$MID_CPUS $PRIME_CPUS"
    BIG_LIST=$(_to_list "$BIG_CPUS");       BIG_MASK=$(_to_mask "$BIG_CPUS")
    MID_LITTLE_CPUS="$MID_CPUS $LITTLE_CPUS"
    MID_LITTLE_LIST=$(_to_list "$MID_LITTLE_CPUS")
    MID_LITTLE_MASK=$(_to_mask "$MID_LITTLE_CPUS")

    if [ -z "${DETECT_QUIET:-}" ]; then sched_log "INFO all=[$ALL_LIST] little=[$LITTLE_LIST] mid=[$MID_LIST] prime=[$PRIME_LIST]"; fi
}

# 策略名 -> 逗号列表（cpuset 用）
policy_to_list() {
    case "$1" in
        all)        echo "$ALL_LIST" ;;
        little)     echo "$LITTLE_LIST" ;;
        mid)        echo "$MID_LIST" ;;
        prime)      echo "$PRIME_LIST" ;;
        big)        echo "$BIG_LIST" ;;
        mid_little) echo "$MID_LITTLE_LIST" ;;
        *)          echo "$ALL_LIST" ;;
    esac
}

# 策略名 -> 掩码（taskset 用）
policy_to_mask() {
    case "$1" in
        all)        echo "$ALL_MASK" ;;
        little)     echo "$LITTLE_MASK" ;;
        mid)        echo "$MID_MASK" ;;
        prime)      echo "$PRIME_MASK" ;;
        big)        echo "$BIG_MASK" ;;
        mid_little) echo "$MID_LITTLE_MASK" ;;
        *)          echo "$ALL_MASK" ;;
    esac
}

# verify_game_applied - 只读验证游戏档是否真的套上了（thread.sh /
# game_sched.sh 调）：前台 uclamp.min 与 GPU min_freq 两项都对上
# 才返回 0；任一项对不上记 FAIL 并返回 1。
# 0.4.34：不再验 top-app uclamp.min——这台设备上 top-app 的写操作
# 永远失败（两个根都写失败，读回 0.00），是已知内核限制、无帧数
# 影响；0.4.33 用它当哨兵导致每轮都 FAIL、状态文件写不上、去温控
# 自动开也永远不触发。top-app/background 的写失败仍由 apply 侧
# 的 S24 汇总 WARN 处理，不阻塞哨兵。
# uclamp 读回可能是小数格式（真机 "77.00"），比较前先去空格、
# 再去掉小数点后面的部分；节点不存在时该项跳过（无法验证，不阻塞）。
# GPU 节点存在且可读时，读回非数字或与期望不符都算 FAIL（不能像
# 旧版那样静默跳过，否则节点被软链到只读文件时哨兵会空过）。
verify_game_applied() {
    _vexp_fg="${GAME_FOREGROUND_UCLAMP_MIN_PEACE:-77}"
    _vexp_pct="${GAME_GPU_MIN_FREQ_PCT_PEACE:-35}"
    # --- 前台 uclamp.min：第一个存在的根 ---
    for _vroot in "$DEV/cpuctl" "$SYS/fs/cgroup/cpu"; do
        _vf="$_vroot/foreground/cpu.uclamp.min"
        if [ -f "$_vf" ]; then
            _vv=$(read_node "$_vf")
            _vv=$(printf '%s' "$_vv" | tr -d ' \t\r\n')
            _vv=${_vv%%.*}
            case "$_vv" in ''|*[!0-9]*)
                sched_log "FAIL verify_game_applied: 前台 uclamp.min 读回非数字（$_vf）"
                return 1 ;;
            esac
            if [ "$_vv" != "$_vexp_fg" ]; then
                sched_log "FAIL verify_game_applied: 前台 uclamp.min=$_vv，期望 $_vexp_fg（$_vf）"
                return 1
            fi
            break
        fi
    done
    # --- GPU：pct 为 0 / 非数字 / >100 时不验（apply 也不会抬）---
    case "$_vexp_pct" in
        ''|0) return 0 ;;
        *[!0-9]*) return 0 ;;
    esac
    if [ "$_vexp_pct" -gt 100 ]; then return 0; fi
    for _vgpu in "$SYS"/class/devfreq/*kgsl-3d0* "$SYS"/class/kgsl/kgsl-3d0; do
        [ -e "$_vgpu" ] || continue
        [ -r "$_vgpu/min_freq" ] || continue
        [ -r "$_vgpu/max_freq" ] || continue
        [ -r "$_vgpu/available_frequencies" ] || continue
        _vmax=$(read_node "$_vgpu/max_freq")
        _vmin=$(read_node "$_vgpu/min_freq")
        case "$_vmax" in ''|*[!0-9]*)
            sched_log "FAIL verify_game_applied: GPU max_freq 读回非数字（$_vgpu）"
            return 1 ;;
        esac
        case "$_vmin" in ''|*[!0-9]*)
            sched_log "FAIL verify_game_applied: GPU min_freq 读回非数字（$_vgpu）"
            return 1 ;;
        esac
        _vexp_min=$((_vmax / 100 * _vexp_pct))
        _vclamped=""
        for _vf in $(cat "$_vgpu/available_frequencies" 2>/dev/null); do
            case "$_vf" in ''|*[!0-9]*) ;; *)
                if [ "$_vf" -ge "$_vexp_min" ]; then
                    if [ -z "$_vclamped" ] || [ "$_vf" -lt "$_vclamped" ]; then _vclamped="$_vf"; fi
                fi ;;
            esac
        done
        if [ -n "$_vclamped" ]; then
            _vexp_min="$_vclamped"
        else
            _vexp_min="$_vmax"
        fi
        if [ "$_vmin" != "$_vexp_min" ]; then
            sched_log "FAIL verify_game_applied: GPU min_freq=$_vmin，期望 $_vexp_min（$_vgpu）"
            return 1
        fi
        break
    done
    return 0
}

# verify_game_restored - 反向验证游戏档是否已撤销（restore_game_sched /
# game_sched.sh off|balanced 调）：前台 uclamp.min 与 GPU min_freq
# 两项都不是游戏值时返回 0（已撤销）；任一项仍是游戏值、或哨兵
# 节点存在但读回非数字（无法确认已撤销）时返回 1（未撤销）。
# 注意和 verify_game_applied 的区别：那个是“任一项不符就返回 1”
# （OR），这里要两项都不是游戏值才算撤销（AND）——只一项恢复了、
# 另一项还卡着游戏值时，restore 就是没成功。
# 节点不存在时该项跳过（无法验证，不阻塞）；两项都无节点可验时
# 返回 0。游戏抬高值等于最低 OPP 时（GAME_GPU_MIN_FREQ_PCT 很小，
# 游戏档本来就没抬 GPU），GPU 项无法区分游戏/日常，跳过该项。
# 0.4.35 新加：之前 restore 没有任何验证，`game off` 永远报
# “已切回”，哪怕 sysfs 写根本没生效。
verify_game_restored() {
    _rfg="${GAME_FOREGROUND_UCLAMP_MIN_PEACE:-77}"
    _rpct="${GAME_GPU_MIN_FREQ_PCT_PEACE:-35}"
    # --- 前台 uclamp.min：读回等于游戏值 → 未撤销 ---
    for _rroot in "$DEV/cpuctl" "$SYS/fs/cgroup/cpu"; do
        _rf="$_rroot/foreground/cpu.uclamp.min"
        if [ -f "$_rf" ]; then
            _rv=$(read_node "$_rf")
            _rv=$(printf '%s' "$_rv" | tr -d ' \t\r\n')
            _rv=${_rv%%.*}
            case "$_rv" in ''|*[!0-9]*) return 1 ;; esac
            if [ "$_rv" = "$_rfg" ]; then return 1; fi
            break
        fi
    done
    # --- GPU min_freq：读回等于游戏抬高值 → 未撤销 ---
    # pct 为 0 / 非数字 / >100 时游戏档不会抬 GPU，跳过该项。
    case "$_rpct" in ''|0) return 0 ;; *[!0-9]*) return 0 ;; esac
    if [ "$_rpct" -gt 100 ]; then return 0; fi
    for _rgpu in "$SYS"/class/devfreq/*kgsl-3d0* "$SYS"/class/kgsl/kgsl-3d0; do
        [ -e "$_rgpu" ] || continue
        [ -r "$_rgpu/min_freq" ] || continue
        [ -r "$_rgpu/max_freq" ] || continue
        [ -r "$_rgpu/available_frequencies" ] || continue
        _rmax=$(read_node "$_rgpu/max_freq")
        _rmin=$(read_node "$_rgpu/min_freq")
        case "$_rmax" in ''|*[!0-9]*) return 1 ;; esac
        case "$_rmin" in ''|*[!0-9]*) return 1 ;; esac
        _rexp=$((_rmax / 100 * _rpct))
        _rclamped=""; _rlow=""
        for _rf2 in $(cat "$_rgpu/available_frequencies" 2>/dev/null); do
            case "$_rf2" in ''|*[!0-9]*) ;; *)
                if [ -z "$_rlow" ] || [ "$_rf2" -lt "$_rlow" ]; then _rlow="$_rf2"; fi
                if [ "$_rf2" -ge "$_rexp" ]; then
                    if [ -z "$_rclamped" ] || [ "$_rf2" -lt "$_rclamped" ]; then _rclamped="$_rf2"; fi
                fi ;;
            esac
        done
        if [ -n "$_rclamped" ]; then _rexp="$_rclamped"; else _rexp="$_rmax"; fi
        # 游戏抬高值等于最低 OPP 时，游戏档本来就没抬 GPU，跳过该项。
        if [ -n "$_rlow" ] && [ "$_rexp" = "$_rlow" ]; then break; fi
        if [ "$_rmin" = "$_rexp" ]; then return 1; fi
        break
    done
    return 0
}

# 读配置：只认 KEY=VALUE 行，# 开头忽略，值去引号/回车。
load_config() {
    _cfg="$1"
    if [ ! -f "$_cfg" ]; then
        sched_log "WARN config 不存在：$_cfg，用内置均衡默认值"
        return 0
    fi
    # shellcheck disable=SC1090
    . "$_cfg"
}
