#!/system/bin/sh
# zram.sh - zram 压缩算法 + 大小切换（0.4.23，和调度模块合在一起）
# 用法：
#   zram.sh status              # key=value：当前算法 / 可用算法 / 大小 / 已用量
#   zram.sh check ALGO SIZE_GB  # 只校验（不改东西），0=能切，2=不行
#   zram.sh set ALGO SIZE_GB    # 校验 → swapoff → reset → 写算法/大小 → mkswap → swapon → 写配置
#   zram.sh apply               # 开机用：按 config.conf 的 ZRAM_ALGO / ZRAM_SIZE_GB 套用，没填就不动
#
# 原理：换算法 / 大小必须先把 zram 里的数据搬回内存（swapoff），再 reset
# 清空，才能写 comp_algorithm / disksize。swapoff 前先查空闲内存：
# 已换出的数据（orig_data_size）必须 <= 空闲内存的 80%，不够就拒绝，
# 不会硬切。算法只认 /sys/block/zram0/comp_algorithm 里列出的，不硬编
# （lz4 一般都有，zstd 得看内核编没编）。KernelSU LKM / GKI 都一样，
# 这活就是 root 写 sysfs 节点，不用另外加载内核模块。

MODDIR="${0%/*}/.."
if [ -n "$SCHED_TEST_MODDIR" ]; then MODDIR="$SCHED_TEST_MODDIR"; fi
# shellcheck disable=SC1091
. "$MODDIR/sched/lib.sh"
load_config "$MODDIR/sched/config.conf"
# 0.4.42：内存自己的日志文件（D）。
SCHED_LOG_CAT=zram

if [ -n "$SCHED_TEST_ROOT" ]; then
    ZRAM_DEV="$SCHED_TEST_ROOT/dev/block/zram0"
else
    ZRAM_DEV="/dev/block/zram0"
fi
ZRAM_SYS="$SYS/block/zram0"
CFG="$MODDIR/sched/config.conf"
ZRAM_LOCK="${SCHED_TEST_ROOT:-/data/local/tmp}/oneplus_sched_zram.lock"

# dmesg 里 zram 的最后 5 行（拼成单行），写大小/mkswap/swapon/回滚
# 失败时都带上——shell 报错里常没有内核原因（S18）。
zram_dmesg() {
    dmesg 2>/dev/null | grep -i "zram" | tail -n 5 | tr '\n' '|'
}

zram_swap_active() { grep -q "$ZRAM_DEV" "$PROC/swaps" 2>/dev/null; }

# M5：mkdir 原子锁。拿不到锁时看 holder 是否还活着（pid 文件里的
# PID 用 kill -0 检查）或锁目录 mtime 是否超过 5 分钟，死了/超期
# 就是残留锁，清掉重拿一次；两次都拿不到才返回“正在切换”。
# 锁只在 cmd_set 入口拿（cmd_apply 调 cmd_set 时自动带上，不重复拿），
# trap 保证异常退出时解锁（先删 pid 文件再 rmdir，不然目录非空
# rmdir 失败）。
zram_lock_acquire() {
    if mkdir "$ZRAM_LOCK" 2>/dev/null; then
        echo "$$" > "$ZRAM_LOCK/pid" 2>/dev/null
        trap 'rm -f "$ZRAM_LOCK/pid" 2>/dev/null; rmdir "$ZRAM_LOCK" 2>/dev/null' EXIT
        return 0
    fi
    _holder=""
    [ -f "$ZRAM_LOCK/pid" ] && _holder=$(cat "$ZRAM_LOCK/pid" 2>/dev/null)
    _stale=0
    case "$_holder" in
        ''|*[!0-9]*) _stale=1 ;;
        *) kill -0 "$_holder" 2>/dev/null || _stale=1 ;;
    esac
    if [ "$_stale" = "0" ] && find "$ZRAM_LOCK" -mmin +5 2>/dev/null | grep -q .; then
        _stale=1
    fi
    if [ "$_stale" = "1" ]; then
        sched_log "WARN zram 锁残留（holder=${_holder:-未知}），清掉重拿"
        rm -rf "$ZRAM_LOCK" 2>/dev/null
        if mkdir "$ZRAM_LOCK" 2>/dev/null; then
            echo "$$" > "$ZRAM_LOCK/pid" 2>/dev/null
            trap 'rm -f "$ZRAM_LOCK/pid" 2>/dev/null; rmdir "$ZRAM_LOCK" 2>/dev/null' EXIT
            return 0
        fi
    fi
    echo "ERR 正在切换，稍后再试"
    return 1
}

# M10：大小非 0 但 swap 未挂时直接 swapon 修复。0=不用修/修好了，
# 1=修失败（调用方决定是回滚/报错还是继续完整切换）。只记日志不
# echo，免得调用方继续走完整切换时先冒一句 ERR。
zram_repair_swap() {
    _rds=$(read_node "$ZRAM_SYS/disksize")
    case "$_rds" in ''|*[!0-9]*) return 0 ;; esac
    _rnz=$(echo "$_rds" | sed 's/^0*//')
    [ -z "$_rnz" ] && return 0
    zram_swap_active && return 0
    sched_log "WARN zram 大小非 0（${_rds}字节）但 swap 未挂，尝试 swapon 修复"
    if _rerr=$(swapon "$ZRAM_DEV" 2>&1); then
        sched_log "OK zram swapon 修复成功，swap 已恢复"
        return 0
    fi
    _rdm=$(zram_dmesg)
    sched_log "FAIL zram swapon 修复失败：$_rerr（dmesg：$_rdm）"
    return 1
}

zram_present() { [ -e "$ZRAM_SYS/comp_algorithm" ] && [ -e "$ZRAM_SYS/disksize" ]; }

# 当前算法（去括号）/ 可用算法列表（空格分隔，去括号）
zram_current_algo() {
    _a=$(read_node "$ZRAM_SYS/comp_algorithm")
    for _t in $_a; do
        case "$_t" in
            \[*\]) _t="${_t#[}"; _t="${_t%]}"; echo "$_t"; return 0 ;;
        esac
    done
    # 没括号（刚写进去还没被内核重写 / 只有一个算法）时取第一个词
    for _t in $_a; do echo "$_t"; return 0; done
    echo ""
}
zram_algos() {
    _a=$(read_node "$ZRAM_SYS/comp_algorithm")
    _out=""
    for _t in $_a; do
        _t="${_t#[}"; _t="${_t%]}"
        [ -n "$_t" ] && _out="$_out $_t"
    done
    echo "${_out# }"
}

# GB → 字节对照表。不要用 $(( GB * 1073741824 )) 算：12GB = 12884901888
# 超过 32 位；设备上的 sh 若是 32 位算术会算成 0，写 0 进 disksize 必败
# （四次 12GB 全败、回滚显示“0GB”，都对得上）。查表最稳，面板只给
# 2/4/6/8/12/16/24/32 这几档，1-32 全列出来，拿不到的返回 0。
zram_gb_to_bytes() {
    case "$1" in
        1) echo 1073741824 ;;
        2) echo 2147483648 ;;
        3) echo 3221225472 ;;
        4) echo 4294967296 ;;
        5) echo 5368709120 ;;
        6) echo 6442450944 ;;
        7) echo 7516192768 ;;
        8) echo 8589934592 ;;
        9) echo 9663676416 ;;
        10) echo 10737418240 ;;
        11) echo 11811160064 ;;
        12) echo 12884901888 ;;
        13) echo 13958643712 ;;
        14) echo 15032385536 ;;
        15) echo 16106127360 ;;
        16) echo 17179869184 ;;
        17) echo 18253611008 ;;
        18) echo 19327352832 ;;
        19) echo 20401094656 ;;
        20) echo 21474836480 ;;
        21) echo 22548578304 ;;
        22) echo 23622320128 ;;
        23) echo 24696061952 ;;
        24) echo 25769803776 ;;
        25) echo 26843545600 ;;
        26) echo 27917287424 ;;
        27) echo 28991029248 ;;
        28) echo 30064771072 ;;
        29) echo 31138512896 ;;
        30) echo 32212254720 ;;
        31) echo 33285996544 ;;
        32) echo 34359738368 ;;
        *) echo 0 ;;
    esac
}

# 字节 → GB 反查（status 显示用）。不用除法，原因同上；去尾数取整的
# 办法在 14GB 以上会算错（16GB 会显示成 17GB），所以直接反查表。
# 不在表里的（比如厂商默认的 512MB）返回 0，面板会改显示原始字节数。
zram_bytes_to_gb() {
    case "$1" in
        1073741824) echo 1 ;;
        2147483648) echo 2 ;;
        3221225472) echo 3 ;;
        4294967296) echo 4 ;;
        5368709120) echo 5 ;;
        6442450944) echo 6 ;;
        7516192768) echo 7 ;;
        8589934592) echo 8 ;;
        9663676416) echo 9 ;;
        10737418240) echo 10 ;;
        11811160064) echo 11 ;;
        12884901888) echo 12 ;;
        13958643712) echo 13 ;;
        15032385536) echo 14 ;;
        16106127360) echo 15 ;;
        17179869184) echo 16 ;;
        18253611008) echo 17 ;;
        19327352832) echo 18 ;;
        20401094656) echo 19 ;;
        21474836480) echo 20 ;;
        22548578304) echo 21 ;;
        23622320128) echo 22 ;;
        24696061952) echo 23 ;;
        25769803776) echo 24 ;;
        26843545600) echo 25 ;;
        27917287424) echo 26 ;;
        28991029248) echo 27 ;;
        30064771072) echo 28 ;;
        31138512896) echo 29 ;;
        32212254720) echo 30 ;;
        33285996544) echo 31 ;;
        34359738368) echo 32 ;;
        *) echo 0 ;;
    esac
}

# 十进制字符串比较（不用算术，大数在 32 位 shell 下会溢出）：
# 去前导 0 后先比位数（位数多就大），位数相同再按字典序比。
zram_num_ge() {
    _na=$(echo "$1" | sed 's/^0*//'); [ -z "$_na" ] && _na=0
    _nb=$(echo "$2" | sed 's/^0*//'); [ -z "$_nb" ] && _nb=0
    [ "${#_na}" -gt "${#_nb}" ] && return 0
    [ "${#_na}" -lt "${#_nb}" ] && return 1
    [ "$_na" = "$_nb" ] && return 0
    [ "$_na" \> "$_nb" ]
}

# 字节 → GB 向下取整（S17：出厂 7.5GB=8053063680 不在精确表里，
# 精确反查会丢成 0）。逐项比对查表值，取不大于输入的最大表项；
# 输入 0 或非法返回 0。不用除法，原因同 zram_gb_to_bytes。
zram_bytes_to_gb_floor() {
    case "$1" in ''|*[!0-9]*) echo 0; return 0 ;; esac
    _v=$(echo "$1" | sed 's/^0*//'); [ -z "$_v" ] && { echo 0; return 0; }
    for _t in 32:34359738368 31:33285996544 30:32212254720 29:31138512896 28:30064771072 27:28991029248 26:27917287424 25:26843545600 24:25769803776 23:24696061952 22:23622320128 21:22548578304 20:21474836480 19:20401094656 18:19327352832 17:18253611008 16:17179869184 15:16106127360 14:15032385536 13:13958643712 12:12884901888 11:11811160064 10:10737418240 9:9663676416 8:8589934592 7:7516192768 6:6442450944 5:5368709120 4:4294967296 3:3221225472 2:2147483648 1:1073741824; do
        _gb=${_t%%:*}; _bv=${_t##*:}
        if zram_num_ge "$_v" "$_bv"; then echo "$_gb"; return 0; fi
    done
    echo 0
}

# zram_save_config ALGO SIZE_GB：只改 CFG 里这两行（不存在就追加），
# 临时文件 + mv，和 panel.sh set_value 同一个写法、同一逻辑——
# 两处改一处要同步另一处（O12：不跨文件抽公共函数，只留这句注释）。
zram_save_config() {
    _algo="$1"; _size_gb="$2"
    # S7：配置文件丢了就拒绝，绝不重建——否则会把全配置覆盖成只剩两行。
    if [ ! -f "$CFG" ]; then echo "ERR 配置文件不存在，拒绝重建：$CFG"; return 1; fi
    _tmp="$CFG.tmp.$$"
    # 不用 : > 建临时文件：: 是特殊内建命令，重定向失败时 dash 直接
    # 退出整个脚本（exit 2），|| 接不住；printf 是普通内建，失败才
    # 会走下面的 || 分支返回 1（S8 的 WARN 路径就靠这个）。
    printf '' > "$_tmp" 2>/dev/null || { echo "ERR 写配置失败"; return 1; }
    _fa=0; _fs=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            ZRAM_ALGO=*) echo "ZRAM_ALGO=$_algo" >> "$_tmp"; _fa=1 ;;
            ZRAM_SIZE_GB=*) echo "ZRAM_SIZE_GB=$_size_gb" >> "$_tmp"; _fs=1 ;;
            *) printf '%s\n' "$_line" >> "$_tmp" ;;
        esac
    done < "$CFG"
    [ "$_fa" = "0" ] && echo "ZRAM_ALGO=$_algo" >> "$_tmp"
    [ "$_fs" = "0" ] && echo "ZRAM_SIZE_GB=$_size_gb" >> "$_tmp"
    mv "$_tmp" "$CFG" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; echo "ERR 写配置失败"; return 1; }
    backup_config "$CFG"
    return 0
}

cmd_status() {
    if ! zram_present; then
        echo "zram=no"
        echo "zram_msg=本机没有 zram（/sys/block/zram0 不存在）"
        return 1
    fi
    echo "zram=yes"
    echo "algo=$(zram_current_algo)"
    echo "algos=$(zram_algos)"
    _ds=$(read_node "$ZRAM_SYS/disksize")
    case "$_ds" in ''|*[!0-9]*) _ds=0 ;; esac
    echo "disksize=$_ds"
    echo "disksize_gb=$(zram_bytes_to_gb "$_ds")"
    echo "disksize_gb_approx=$(zram_bytes_to_gb_floor "$_ds")"
    _orig=$(read_node "$ZRAM_SYS/orig_data_size")
    case "$_orig" in ''|*[!0-9]*) _orig=0 ;; esac
    echo "orig_data_size=$_orig"
    _used=$(read_node "$ZRAM_SYS/mem_used_total")
    case "$_used" in ''|*[!0-9]*) _used=0 ;; esac
    echo "mem_used_total=$_used"
    _compr=$(read_node "$ZRAM_SYS/compr_data_size")
    case "$_compr" in ''|*[!0-9]*) _compr=0 ;; esac
    echo "compr_data_size=$_compr"
    _avail=$(sed -n 's/^MemAvailable:[[:space:]]*\([0-9]*\).*/\1/p' "$PROC/meminfo" 2>/dev/null | head -n 1)
    case "$_avail" in ''|*[!0-9]*) _avail=0 ;; esac
    echo "mem_avail_kb=$_avail"
    if zram_swap_active; then echo "swap_active=yes"; else echo "swap_active=no"; fi
    return 0
}

# cmd_check ALGO SIZE_GB：只校验，不改东西。0=能切，2=不行。
cmd_check() {
    _algo="$1"; _size_gb="$2"
    if ! zram_present; then echo "ERR 本机没有 zram"; return 2; fi
    # S9：设备节点 / reset 可写在校验阶段就查，别拖到 swapoff 之后才暴露。
    if [ ! -e "$ZRAM_DEV" ]; then echo "ERR zram 设备节点不存在：$ZRAM_DEV"; return 2; fi
    if [ ! -w "$ZRAM_SYS/reset" ]; then echo "ERR zram reset 节点不可写：$ZRAM_SYS/reset"; return 2; fi
    case "$_algo" in ''|*[!a-zA-Z0-9_-]*) echo "ERR 算法名不对：$_algo"; return 2 ;; esac
    case "$_size_gb" in ''|*[!0-9]*) echo "ERR 大小要是 1-32 的整数 GB：$_size_gb"; return 2 ;; esac
    # S10：大小先做长度检查（超过 2 位数字直接拒绝，即 3 位及以上），再做 -lt/-gt。
    # 注意：??* 是“2 位及以上”，会误拒 10-32，必须用 ???*（3 位及以上）。
    case "$_size_gb" in ???*) echo "ERR 大小只能是 1-32 GB：$_size_gb"; return 2 ;; esac
    if [ "$_size_gb" -lt 1 ] || [ "$_size_gb" -gt 32 ]; then echo "ERR 大小只能是 1-32 GB"; return 2; fi
    _ok=0
    for _t in $(zram_algos); do [ "$_t" = "$_algo" ] && _ok=1; done
    if [ "$_ok" = "0" ]; then echo "ERR 内核没有这个算法：$_algo（可用：$(zram_algos)）"; return 2; fi
    _orig=$(read_node "$ZRAM_SYS/orig_data_size")
    case "$_orig" in ''|*[!0-9]*) _orig=0 ;; esac
    # S10：_orig 是字节数（最大 32GB），不用 -gt 数值比较（32 位 shell
    # 下会回绕）；去前导 0 后非空即视为有数据。
    _orig_nz=$(echo "$_orig" | sed 's/^0*//')
    if [ -n "$_orig_nz" ]; then
        _avail_kb=$(sed -n 's/^MemAvailable:[[:space:]]*\([0-9]*\).*/\1/p' "$PROC/meminfo" 2>/dev/null | head -n 1)
        case "$_avail_kb" in ''|*[!0-9]*)
            echo "ERR 读不到空闲内存，拒绝切换（不敢在不知道的情况下 swapoff）"
            return 2 ;;
        esac
        # 空闲的 80% 和已换出的数据都按十进制 MB 比（O13：两边统一，
        # 之前空闲是 MiB、已换出是 MB，差 4.86%）：已换出是字节数，
        # 去掉末 6 位 ≈ 除以 10^6 取 MB（不用乘法，字节数超 32 位会溢出）；
        # 空闲是 KB/1000 ≈ MB。两边都是约数。
        _orig_mb=${_orig%??????}
        case "$_orig_mb" in ''|*[!0-9]*) _orig_mb=0 ;; esac
        _avail_mb=$(( _avail_kb / 1000 ))
        if [ "$_orig_mb" -gt $(( _avail_mb * 4 / 5 )) ]; then
            echo "ERR 空闲内存不够：已换出约 ${_orig_mb} MB，空闲约 ${_avail_mb} MB，swapoff 搬不回来，先清后台再试"
            return 2
        fi
    fi
    echo "OK 能切：$_algo ${_size_gb}GB"
    return 0
}

# zram_rollback：swapoff/reset 之后某步失败了，把旧算法和旧大小写回去、
# 重新挂 swap，绝不把没 swap 的状态留给用户。_old_ds=0（原来就没开
# swap）时不用回滚，重启就恢复；_old_ds 为空是读失败，绝不能当成 0。
zram_rollback() {
    if [ -z "${_old_ds:-}" ]; then
        sched_log "FAIL zram 回滚信息丢失，无法回滚，重启恢复"
        echo "ERR zram 回滚信息丢失，无法回滚，重启恢复"
        return 1
    fi
    if [ "$_old_ds" = "0" ]; then
        sched_log "WARN zram 回滚：原来就没开 swap（旧大小 0），不用回滚，重启平板恢复"
        return 0
    fi
    sched_log "WARN zram 回滚：恢复 $_old_algo（旧大小 ${_old_ds}字节）并重新挂 swap"
    _rb_fail=0
    if ! _err=$(echo 1 2>&1 > "$ZRAM_SYS/reset"); then
        sched_log "FAIL zram 回滚 reset 失败：$_err"; _rb_fail=1
    fi
    if ! _err=$(echo "$_old_algo" 2>&1 > "$ZRAM_SYS/comp_algorithm"); then
        sched_log "FAIL zram 回滚写算法失败：$_err"; _rb_fail=1
    fi
    if ! _err=$(echo "$_old_ds" 2>&1 > "$ZRAM_SYS/disksize"); then
        sched_log "FAIL zram 回滚写大小失败：$_err"; _rb_fail=1
    fi
    # mkswap 的输出不要丢掉，失败时记进日志。
    if ! _mkout=$(mkswap "$ZRAM_DEV" 2>&1); then
        _dm=$(zram_dmesg)
        sched_log "FAIL zram 回滚 mkswap 失败：$_mkout（dmesg：$_dm）"
        echo "ERR zram 回滚 mkswap 失败：$_mkout（dmesg：$_dm）"
        return 1
    fi
    if ! _err=$(swapon "$ZRAM_DEV" 2>&1); then
        _dm=$(zram_dmesg)
        sched_log "FAIL zram 回滚 swapon 失败：$_err（dmesg：$_dm）"
        echo "ERR zram 回滚失败，swap 还是关的，重启平板恢复"
        return 1
    fi
    if [ "$(zram_current_algo)" != "$_old_algo" ] || [ "$(read_node "$ZRAM_SYS/disksize")" != "$_old_ds" ]; then
        sched_log "FAIL zram 回滚验读不对：算法=$(zram_current_algo) 大小=$(read_node "$ZRAM_SYS/disksize")，想要 $_old_algo $_old_ds"
        echo "ERR zram 回滚验读不对，重启平板恢复"
        return 1
    fi
    if [ "$_rb_fail" = "1" ]; then
        sched_log "FAIL zram 回滚有步骤失败（见上），但 swap 已挂回、验读也对得上"
        return 1
    fi
    sched_log "OK zram 已回滚到 $_old_algo，swap 已恢复"
    return 0
}

# cmd_set ALGO SIZE_GB：校验 → swapoff → reset → 写算法/大小 →
# mkswap → swapon → 验读 → 写配置。swapoff 之后任何一步失败都回滚
# （0.4.24：16:07 那次写大小失败后 swap 一直关着，就是没回滚的亏；
# 另外写失败时把 shell 报错原样记进日志，不然只剩一句“失败”，
# 根本不知道是 EINVAL / ENOMEM 还是 EBUSY）。
cmd_set() {
    _algo="$1"; _size_gb="$2"
    # M5：入口先拿锁（cmd_apply 调 cmd_set 时自动带上，不重复拿）。
    zram_lock_acquire || return 1
    cmd_check "$_algo" "$_size_gb" || return 2
    _cur_algo=$(zram_current_algo)
    _old_algo="$_cur_algo"
    # _old_ds 保留读到的原值：读失败时 read_node 返回空，_old_ds 为空
    # 字符串（回滚时凭这个区分“读失败”和“原来就没开 swap=0”）。
    _cur_ds_raw=$(read_node "$ZRAM_SYS/disksize")
    case "$_cur_ds_raw" in
        ''|*[!0-9]*) _old_ds=""; _cur_ds=0 ;;
        *) _old_ds="$_cur_ds_raw"; _cur_ds="$_cur_ds_raw" ;;
    esac
    _want_ds=$(zram_gb_to_bytes "$_size_gb")
    # M10：入口先检查“大小非 0 但 swap 未挂”就直接 swapon 修复。
    _repair_rc=0
    zram_repair_swap || _repair_rc=1
    if [ "$_algo" = "$_cur_algo" ] && [ "$_cur_ds" = "$_want_ds" ]; then
        # M8：目标与当前一致也不直接走——仍保存配置，仍检查 swap，
        # swapon 成功后还要验读，读回来对得上才算 OK。
        sched_log "INFO zram 已是 $_algo ${_size_gb}GB，不用切"
        if ! zram_save_config "$_algo" "$_size_gb"; then
            sched_log "WARN zram 已是目标大小但配置保存失败，下次开机将恢复旧大小"
            echo "WARN zram 已是 $_algo ${_size_gb}GB，但配置保存失败，下次开机将恢复旧大小"
        fi
        if [ "$_repair_rc" != "0" ]; then
            echo "ERR swapon 修复失败，看日志"
            zram_rollback
            return 1
        fi
        if [ "$(zram_current_algo)" != "$_algo" ] || [ "$(read_node "$ZRAM_SYS/disksize")" != "$_want_ds" ]; then
            sched_log "FAIL zram 验读不对：算法=$(zram_current_algo) 大小=$(read_node "$ZRAM_SYS/disksize")，想要 $_algo $_want_ds"
            echo "ERR 验读不对，看日志"
            zram_rollback
            return 1
        fi
        echo "OK 已是 $_algo ${_size_gb}GB，不用切"
        return 0
    fi
    if [ "$_repair_rc" != "0" ]; then
        sched_log "WARN zram swapon 修复失败，继续完整切换（mkswap/swapon 会重建）"
    fi
    # 写之前先把数记下来：哪天再失败，日志里直接看得出是算错了值还是
    # 内核不让写（0.4.24 之前四次 12GB 全败，日志里连要写的值都没有）。
    sched_log "INFO zram set：当前算法=$_cur_algo 当前大小=${_cur_ds}字节 目标=$_algo ${_size_gb}GB（${_want_ds}字节）"
    # 1. swapoff：只在 zram 正挂着 swap 时才做；失败就停，数据还在，不动
    if grep -q "$ZRAM_DEV" "$PROC/swaps" 2>/dev/null; then
        if ! _err=$(swapoff "$ZRAM_DEV" 2>&1); then
            sched_log "FAIL zram swapoff 失败：$_err（没动算法和大小）"
            echo "ERR swapoff 失败：$_err"
            return 1
        fi
    fi
    # 2. reset：清空后才能写算法和大小
    if ! _err=$(echo 1 2>&1 > "$ZRAM_SYS/reset"); then
        sched_log "FAIL zram reset 失败：$_err"
        echo "ERR reset 失败：$_err"
        zram_rollback
        return 1
    fi
    # 3. 算法
    if ! _err=$(echo "$_algo" 2>&1 > "$ZRAM_SYS/comp_algorithm"); then
        sched_log "FAIL zram 写算法失败：$_err"
        echo "ERR 写算法失败：$_err"
        zram_rollback
        return 1
    fi
    # 4. 大小
    if ! _err=$(echo "$_want_ds" 2>&1 > "$ZRAM_SYS/disksize"); then
        # 内核拒写的原因 shell 报错里不一定有（0.4.24 的四次失败全是空），
        # 直接问内核：dmesg 里 zram 的那几行会说清是 EINVAL / ENOMEM 还是 EBUSY。
        _dm=$(dmesg 2>/dev/null | grep -i "zram" | tail -n 5 | tr '\n' '|')
        sched_log "FAIL zram 写大小失败：$_err（dmesg：$_dm）"
        echo "ERR 写大小失败：$_err（dmesg：$_dm）"
        zram_rollback
        return 1
    fi
    # 5. mkswap + swapon
    if ! _err=$(mkswap "$ZRAM_DEV" 2>&1); then
        _dm=$(zram_dmesg)
        sched_log "FAIL zram mkswap 失败：$_err（dmesg：$_dm）"
        echo "ERR mkswap 失败：$_err（dmesg：$_dm）"
        zram_rollback
        return 1
    fi
    if ! _err=$(swapon "$ZRAM_DEV" 2>&1); then
        _dm=$(zram_dmesg)
        sched_log "FAIL zram swapon 失败：$_err（算法和大小已写进去，但 swap 没挂上；dmesg：$_dm）"
        echo "ERR swapon 失败：$_err（dmesg：$_dm）"
        zram_rollback
        return 1
    fi
    # 6. 验读：写进去的必须读回来对得上
    if [ "$(zram_current_algo)" != "$_algo" ] || [ "$(read_node "$ZRAM_SYS/disksize")" != "$_want_ds" ]; then
        sched_log "FAIL zram 验读不对：算法=$(zram_current_algo) 大小=$(read_node "$ZRAM_SYS/disksize")，想要 $_algo $_want_ds"
        echo "ERR 验读不对，看日志"
        zram_rollback
        return 1
    fi
    # 7. 写配置（下次开机 service.sh 按这个套用）
    # S8：切换已成功，保存失败不按“切换失败”报——记 WARN，返回成功。
    if ! zram_save_config "$_algo" "$_size_gb"; then
        sched_log "WARN zram 已切到新大小但配置保存失败，下次开机将恢复旧大小"
        echo "WARN zram 已切到 $_algo ${_size_gb}GB，但配置保存失败，下次开机将恢复旧大小"
        return 0
    fi
    sched_log "OK zram 已切到 $_algo ${_size_gb}GB"
    echo "OK zram 已切到 $_algo ${_size_gb}GB"
    return 0
}

# cmd_apply：开机用。缺的那项用当前值补齐再调 cmd_set（S16）：
# 算法空时用当前算法，大小空时用当前 disksize 的 GB 数；反查得 0
# 说明当前是非整 GB 大小，没法用 GB 数表示，仍记 WARN 不动。
# 两项都空时仍不动（INFO 未配置）。
cmd_apply() {
    # M10：入口先检查“大小非 0 但 swap 未挂”就直接 swapon 修复；
    # 修失败也不在这里死扛——继续按配置调 cmd_set，里面还会再修/报错。
    zram_repair_swap || sched_log "WARN zram apply 修复失败，继续按配置切换"
    if [ -z "${ZRAM_ALGO:-}" ] && [ -z "${ZRAM_SIZE_GB:-}" ]; then
        sched_log "INFO zram 未配置（ZRAM_ALGO/ZRAM_SIZE_GB 都空着），不动"
        return 0
    fi
    _apply_algo="${ZRAM_ALGO:-}"
    _apply_size="${ZRAM_SIZE_GB:-}"
    if [ -z "$_apply_algo" ]; then
        _apply_algo=$(zram_current_algo)
        if [ -z "$_apply_algo" ]; then
            sched_log "WARN zram 只配了大小，当前算法读不到，不动"
            return 0
        fi
    fi
    if [ -z "$_apply_size" ]; then
        _apply_size=$(zram_bytes_to_gb "$(read_node "$ZRAM_SYS/disksize")")
        if [ "$_apply_size" = "0" ]; then
            sched_log "WARN zram 只配了算法，当前大小是非整 GB（反查得 0），没法补齐，不动"
            return 0
        fi
    fi
    cmd_set "$_apply_algo" "$_apply_size"
}

case "${1:-}" in
    status) cmd_status ;;
    check) cmd_check "$2" "$3" ;;
    set) cmd_set "$2" "$3" ;;
    apply) cmd_apply ;;
    *) echo "用法: zram.sh status|check ALGO SIZE_GB|set ALGO SIZE_GB|apply"; exit 2 ;;
esac
