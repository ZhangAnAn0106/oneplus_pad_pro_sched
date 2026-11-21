#!/system/bin/sh
# customize.sh - 安装时运行：只校验、不强行拦截
_VER=$(grep '^version=' "$MODPATH/module.prop" 2>/dev/null | cut -d= -f2)
ui_print "- OnePlus Pad Pro 性能调度模块 ${_VER:-?}"
ui_print "- 目标：一加平板 Pro (OPD2404)，骁龙 8 Gen 3，ColorOS / Android 12+"
ui_print "- 模式：省电 / 均衡 / 性能 / 游戏（游戏档：和平精英 + 无畏契约），KernelSU WebUI 面板"

MODEL=$(getprop ro.product.model 2>/dev/null)
DEVICE=$(getprop ro.product.device 2>/dev/null)
ui_print "- 检测到 model=$MODEL device=$DEVICE"
case "$MODEL$DEVICE" in
    *OPD2404*)
        ui_print "- 机型匹配，继续安装"
        ;;
    *)
        ui_print "! 机型不是 OPD2404，仍可安装，但 CPU 拓扑靠运行时识别，"
        ui_print "! 请先跑 verify.sh 确认核号/频率再用 performance 模式。"
        ;;
esac

# 权限：脚本可执行，配置只读
set_perm_recursive "$MODPATH/sched" 0 0 0755 0644 2>/dev/null || true
set_perm "$MODPATH/sched/apply_sched.sh" 0 0 0755 2>/dev/null || true
set_perm "$MODPATH/sched/thread.sh" 0 0 0755 2>/dev/null || true
set_perm "$MODPATH/sched/game_sched.sh" 0 0 0755 2>/dev/null || true
set_perm "$MODPATH/sched/panel.sh" 0 0 0755 2>/dev/null || true
set_perm "$MODPATH/sched/verify.sh" 0 0 0755 2>/dev/null || true
# 注意：webroot 目录的权限和 SELinux 由 KernelSU 安装时自动处理，
# 这里不碰它（官方文档要求）。
set_perm "$MODPATH/sched/lib.sh" 0 0 0644 2>/dev/null || true
set_perm "$MODPATH/sched/thermal.sh" 0 0 0755 2>/dev/null || true
set_perm "$MODPATH/sched/zram.sh" 0 0 0755 2>/dev/null || true
set_perm "$MODPATH/sched/oshare_hook.sh" 0 0 0755 2>/dev/null || true
set_perm_recursive "$MODPATH/oshare" 0 0 0755 0644 2>/dev/null || true
set_perm "$MODPATH/uninstall.sh" 0 0 0755 2>/dev/null || true
set_perm_recursive "$MODPATH/thermal" 0 0 0755 0644 2>/dev/null || true
set_perm "$MODPATH/service.sh" 0 0 0755 2>/dev/null || true
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755 2>/dev/null || true

# --- 升级保留配置（0.4.28）---
# 用户改过的设置在备份文件里（每次在面板里保存设置时模块自己写一份
# 到模块目录外面，zip 解压盖不到它）。有备份就按“键”合并回新
# config.conf：备份里有的键用备份的值，新版新增的键留新默认值，
# 备份里有、新版没有的键丢掉（新版不要的旧键）。
# 注意：这是第一次留备份，0.4.27 及之前存的设置（比如 lz4 24GB）
# 还没有备份，装完这一版要去面板里重新点一次，之后升级就再也不会丢。
# 0.4.45：备份只放在 /data/local/tmp 不可靠——真机上丢失过一次
# （0.4.44 安装时没找到，zram、互传常开等设置全回了默认）。主备份
# 换到 /data/adb，恢复来源再加旧模块自己的 config.conf 兜底，
# 合并完还回写备份，见下面“三重来源”一段。
# --- 配置合并校验（M13）：备份文件是 root source 的输入，一行恶意
# 内容等于 root 代码执行。合并时按 key 类型白名单校验再写入，不合格
# 的行丢弃、用新默认值，并 ui_print 告警（说明哪个 key 被丢弃、为什么）。
# 含 ; ( ) ` " ' & | 的行一律丢弃；数值类先验格式再验范围。
# 0.4.42：$ 不再算危险字符——命令替换必须靠 (（$(、$((）或反引号，
# 这两个都还在集里拦着；光秃秃的 $VAR 展开无害（AUTO_GAME_PACKAGES
# 里就是 $PEACE_PACKAGES $VALORANT_PACKAGES 引用）。0.4.41 之前
# $ 在集里，带引用的行每次安装都被误杀。
_cfg_bad_chars() {
    case "$1" in
        *';'*|*'('*|*')'*|*'`'*|*'"'*|*"'"*|*'&'*|*'|'*) return 0 ;;
    esac
    return 1
}
# _cfg_num_in_range 值 下限 上限：整数且在闭区间内返回 0。
# 数字超过 9 位直接拒绝（32 位 shell 下大数比较会回绕，见 S10 同源问题）。
_cfg_num_in_range() {
    _v="$1"; _lo="$2"; _hi="$3"
    case "$_v" in
        -*) _d=${_v#-} ;;
        *) _d="$_v" ;;
    esac
    case "$_d" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#_d}" -gt 9 ] && return 1
    [ "$_v" -lt "$_lo" ] && return 1
    [ "$_v" -gt "$_hi" ] && return 1
    return 0
}
# _cfg_validate KEY VALUE：合法返回 0；不合法返回 1，原因写进 _why。
_cfg_validate() {
    _k="$1"; _v="$2"; _why=""
    case "$_k" in
        MODE)
            case "$_v" in balanced|performance|powersave) return 0 ;; *) _why="MODE 只认 balanced|performance|powersave，得到了 $_v"; return 1 ;; esac ;;
        GOVERNOR)
            case "$_v" in ""|schedutil|performance|powersave|ondemand|conservative|userspace) return 0 ;; *) _why="GOVERNOR 不认 $_v"; return 1 ;; esac ;;
        CPUSET_TOP_APP|CPUSET_FOREGROUND|CPUSET_BACKGROUND|CPUSET_SYSTEM_BACKGROUND|CPUSET_RESTRICTED)
            case "$_v" in all|little|mid|prime|big|mid_little) return 0 ;; *) _why="cpuset 策略不认 $_v"; return 1 ;; esac ;;
        IO_SCHEDULER)
            case "$_v" in ""|mq-deadline|bfq|kyber|deadline|cfq|noop|none) return 0 ;; *) _why="IO_SCHEDULER 不认 $_v"; return 1 ;; esac ;;
        ZRAM_ALGO)
            case "$_v" in ""|lz4|zstd|deflate|lzo|lz4hc|842) return 0 ;; *) _why="ZRAM_ALGO 不认 $_v"; return 1 ;; esac ;;
        PEACE_PACKAGES|VALORANT_PACKAGES|AUTO_GAME_PACKAGES|GAME_CLEAN_WHITELIST)
            # 0.4.42：字符集加 $，让 AUTO_GAME_PACKAGES 里
            # $PEACE_PACKAGES $VALORANT_PACKAGES 这种引用能过。
            case "$_v" in *[!A-Za-z0-9._\$\ -]*) _why="包名/白名单只允字母数字 . _ 空格 - \$（\$VAR 引用也行）"; return 1 ;; *) return 0 ;; esac ;;
        TOP_APP_UCLAMP_MIN|TOP_APP_UCLAMP_MAX|FOREGROUND_UCLAMP_MIN|FOREGROUND_UCLAMP_MAX|BACKGROUND_UCLAMP_MIN|BACKGROUND_UCLAMP_MAX|GAME_TOP_APP_UCLAMP_MIN_PEACE|GAME_FOREGROUND_UCLAMP_MIN_PEACE|GAME_BACKGROUND_UCLAMP_MAX)
            _cfg_num_in_range "$_v" -1 1024 || { _why="uclamp 范围 -1~1024，得到了 $_v"; return 1; }; return 0 ;;
        GPU_MIN_FREQ_PCT|GAME_GPU_MIN_FREQ_PCT_PEACE|GAME_HISPEED_LOAD_PEACE)
            _cfg_num_in_range "$_v" 0 100 || { _why="百分比范围 0~100，得到了 $_v"; return 1; }; return 0 ;;
        AUTO_MODE_LOW_BATTERY_PCT)
            _cfg_num_in_range "$_v" 5 50 || { _why="低电量阈值范围 5~50，得到了 $_v"; return 1; }; return 0 ;;
        AUTO_WATCH_INTERVAL)
            _cfg_num_in_range "$_v" 2 60 || { _why="轮询间隔范围 2~60，得到了 $_v"; return 1; }; return 0 ;;
        GAME_EXIT_GRACE_CYCLES)
            _cfg_num_in_range "$_v" 0 12 || { _why="退出宽限范围 0~12，得到了 $_v"; return 1; }; return 0 ;;
        ZRAM_SIZE_GB)
            case "$_v" in "") return 0 ;; esac
            _cfg_num_in_range "$_v" 1 32 || { _why="zram 大小范围 1~32，得到了 $_v"; return 1; }; return 0 ;;
        AUTO_WATCH_ON_BOOT|AUTO_MODE|AUTO_MODE_DEBUG|AUTO_MODE_WAKELOCK|GAME_AUTO_DETECT|GAME_CLEAN_BACKGROUND|GAME_KEEPALIVE|GAME_SCHED_ENABLED|THERMAL_REMOVE|THERMAL_AUTO_GAME|OSHARE_ALWAYS_ON|VULKAN_GAME|VULKAN_GLOBAL|SCHED_TUNABLES|SCHEDUTIL_IOWAIT_BOOST)
            _cfg_num_in_range "$_v" 0 1 || { _why="开关只认 0 或 1，得到了 $_v"; return 1; }; return 0 ;;
        GAME_NICE_PEACE|AUTO_CRITICAL_NICE)
            _cfg_num_in_range "$_v" -20 19 || { _why="nice 范围 -20~19，得到了 $_v"; return 1; }; return 0 ;;
        GAME_SCHEDUTIL_UP_US|GAME_SCHEDUTIL_DOWN_US_PEACE|SCHEDUTIL_UP_RATE_LIMIT_US|SCHEDUTIL_DOWN_RATE_LIMIT_US)
            _cfg_num_in_range "$_v" 0 1000000 || { _why="schedutil 时间范围 0~1000000，得到了 $_v"; return 1; }; return 0 ;;
        SCHED_MIGRATION_COST_NS|SCHED_MIN_GRANULARITY_NS|SCHED_WAKEUP_GRANULARITY_NS|SCHED_LATENCY_NS)
            _cfg_num_in_range "$_v" 0 100000000 || { _why="调度参数范围 0~100000000，得到了 $_v"; return 1; }; return 0 ;;
        READ_AHEAD_KB)
            _cfg_num_in_range "$_v" -1 65536 || { _why="read_ahead 范围 -1~65536，得到了 $_v"; return 1; }; return 0 ;;
        LOG_MAX_BYTES)
            _cfg_num_in_range "$_v" 0 9999999 || { _why="LOG_MAX_BYTES 范围 0~9999999，得到了 $_v"; return 1; }; return 0 ;;
        LOG_KEEP_LINES)
            _cfg_num_in_range "$_v" 0 100000 || { _why="LOG_KEEP_LINES 范围 0~100000，得到了 $_v"; return 1; }; return 0 ;;
        *)
            case "$_v" in *[!A-Za-z0-9._\ -]*) _why="值含非法字符"; return 1 ;; *) return 0 ;; esac ;;
    esac
}

# --- 配置恢复来源（0.4.45：三重来源，按优先级取第一个存在的）---
# ① 主备份 /data/adb/oneplus_sched_config.bak（0.4.45 起 backup_config
#    写这里）；② 旧备份 /data/local/tmp/oneplus_sched_config.bak
#    （0.4.44 及之前的位置，真机上这个位置的备份丢失过，只剩它
#    一个不够稳）；③ 旧模块自己的 sched/config.conf（升级安装时
#    旧模块目录还在，两个备份都没了也能从它恢复；和本次要写的新
#    config.conf 是同一个文件时跳过，别自己合并自己）。
# 三个路径都可用环境变量覆盖（仅测试用）。不管来源是哪个，合并
# 都走上面同一套 _cfg_bad_chars / _cfg_validate 校验。
_BAK_MAIN="${ONEPLUS_SCHED_CONFIG_BAK:-/data/adb/oneplus_sched_config.bak}"
_BAK_OLD="${ONEPLUS_SCHED_CONFIG_BAK_OLD:-/data/local/tmp/oneplus_sched_config.bak}"
_OLDMOD_CFG="${ONEPLUS_SCHED_CONFIG_OLDMOD:-/data/adb/modules/oneplus_pad_pro_sched/sched/config.conf}"
_NEWCFG="$MODPATH/sched/config.conf"
_SRC=""
_SRC_NAME=""
if [ -f "$_BAK_MAIN" ]; then
    _SRC="$_BAK_MAIN"; _SRC_NAME="主备份"
elif [ -f "$_BAK_OLD" ]; then
    _SRC="$_BAK_OLD"; _SRC_NAME="旧备份"
elif [ -f "$_OLDMOD_CFG" ] && [ "$_OLDMOD_CFG" != "$_NEWCFG" ]; then
    _SRC="$_OLDMOD_CFG"; _SRC_NAME="旧模块配置"
fi
if [ -n "$_SRC" ] && [ -f "$_NEWCFG" ]; then
    _TMP="$_NEWCFG.merge.$$"
    if printf '' > "$_TMP" 2>/dev/null; then
        while IFS= read -r _line || [ -n "$_line" ]; do
            case "$_line" in
                \#*|"") printf '%s\n' "$_line" >> "$_TMP" ;;
                *=*)
                    _k="${_line%%=*}"
                    # S26：grep -F（_k 不再当正则），再锚定行首取最后一行
                    # （备份里同一 key 出现多次时，后写的值才是新值）。
                    _bv=$(grep -F -e "${_k}=" "$_SRC" 2>/dev/null | grep "^${_k}=" | tail -n 1)
                    if [ -n "$_bv" ]; then
                        _bv_v="${_bv#*=}"
                        # 0.4.42：config.conf 里列表值存的时候带双引号
                        # （PEACE_PACKAGES="com.tencent..."），引号只是
                        # source 时的语法、不是值的一部分——校验前先剥掉
                        # 首尾一对双引号再验，验完通过后写回的还是备份原
                        # 行（保持原样，source 时照旧展开）。不剥的话
                        # _cfg_bad_chars 见 " 就误杀，0.4.41 之前每次安装
                        # 都丢这 4 个键。只剥首尾一对：内嵌引号（如
                        # "a"b"）剥完还剩引号，照样被 _cfg_bad_chars 拦住。
                        case "$_bv_v" in
                            \"*\") _bv_v="${_bv_v#\"}"; _bv_v="${_bv_v%\"}" ;;
                        esac
                        if _cfg_bad_chars "$_bv_v"; then
                            ui_print "! 配置恢复：已丢弃 ${_k}（值含 ; ( ) \` \" ' & | 等危险字符），用新默认值"
                            printf '%s\n' "$_line" >> "$_TMP"
                        elif _cfg_validate "$_k" "$_bv_v"; then
                            printf '%s\n' "$_bv" >> "$_TMP"
                        else
                            ui_print "! 配置恢复：已丢弃 ${_k}（${_why}），用新默认值"
                            printf '%s\n' "$_line" >> "$_TMP"
                        fi
                    else
                        printf '%s\n' "$_line" >> "$_TMP"
                    fi
                    ;;
                *) printf '%s\n' "$_line" >> "$_TMP" ;;
            esac
        done < "$_NEWCFG"
        if mv "$_TMP" "$_NEWCFG" 2>/dev/null; then
            ui_print "- 已恢复上个版本的配置（来源：${_SRC_NAME}）"
        else
            rm -f "$_TMP" 2>/dev/null
            ui_print "! 配置恢复失败，已保留新默认配置"
        fi
    else
        ui_print "! 配置恢复失败（写临时文件失败），已保留新默认配置"
    fi
elif [ -z "$_SRC" ]; then
    # S26：备份缺失不再静默。0.4.27 及之前存的设置还没有备份，
    # 装完这一版要去面板里重新点一次，之后升级就再也不会丢。
    ui_print "! 未找到旧配置备份，将使用默认配置（zram 等设置需重新设置）"
    ui_print "! 0.4.27 及之前存的设置还没有备份，装完请去面板重新设置一次"
else
    ui_print "! 新配置文件缺失，无法恢复配置"
fi

# 0.4.45：把最终 config.conf（合并后的，或无来源时用的默认配置）
# 回写到主、旧两个备份位置（chmod 600），保证每次装完备份必定
# 存在，下次升级有得恢复。回写失败不拦安装。
# C2（0.4.50）：回写失败不再全程静默——cp 失败要 ui_print 告警，
# 否则 /data/adb 写不了时装完一份备份都没有，要等下次升级丢了
# 配置才发现（和 S26“丢设置要出声”同类，当时只修了恢复侧）。
# 测试时（ONEPLUS_SCHED_CONFIG_BAK 被设置）只写被覆盖的路径：
# 主备份总写；旧备份只有显式设置了 ONEPLUS_SCHED_CONFIG_BAK_OLD
# 才写，绝不写真机的 /data。
if [ -f "$_NEWCFG" ]; then
    _wb_fail=0
    cp "$_NEWCFG" "$_BAK_MAIN" 2>/dev/null || _wb_fail=1
    chmod 600 "$_BAK_MAIN" 2>/dev/null || true
    if [ -z "${ONEPLUS_SCHED_CONFIG_BAK:-}" ] || [ -n "${ONEPLUS_SCHED_CONFIG_BAK_OLD:-}" ]; then
        cp "$_NEWCFG" "$_BAK_OLD" 2>/dev/null || _wb_fail=1
        chmod 600 "$_BAK_OLD" 2>/dev/null || true
    fi
    if [ "$_wb_fail" != "0" ]; then
        ui_print "! 配置备份回写失败，下次升级可能丢配置（请确认 /data/adb 可写）"
    fi
fi

# --- 互传常开 hook APK：刷模块时当场装好（0.4.52）---
# 0.4.46–0.4.51 是开机后 service.sh 调 oshare_hook.sh ensure 才装，
# 刷完还得等一次开机；她要刷完即完成，这里在安装过程中直接装。
# 版本比较不写第二份版本号：要装的 versionCode 从 sched/
# oshare_hook.sh 的 HOOK_APK_VC 解析（解析不到按未装处理，装一次
# 试试）；dumpsys/pm 不可用也一样——查不到就装，装失败只告警，
# 绝不让整个模块安装失败（开机 ensure 原样保留，作兜底）。
# _HOOK_VN 只是打印用的显示名（内置 APK 的 versionName），
# 比较逻辑一律用解析出的 VC，不用它。
_HOOK_PKG="com.nora.osharehook"
_HOOK_APK="$MODPATH/oshare/oshare-hook.apk"
_HOOK_VN="1.4"
_HOOK_VC_WANT=$(grep '^HOOK_APK_VC=' "$MODPATH/sched/oshare_hook.sh" 2>/dev/null | head -n 1 | cut -d= -f2 | tr -d ' \t\r')
case "$_HOOK_VC_WANT" in ''|*[!0-9]*) _HOOK_VC_WANT="" ;; esac
_HOOK_VC_HAVE=0
if command -v dumpsys >/dev/null 2>&1; then
    _hv=$(dumpsys package "$_HOOK_PKG" 2>/dev/null | grep 'versionCode=' | head -n 1 | sed 's/.*versionCode=//;s/[^0-9].*//')
    case "$_hv" in ''|*[!0-9]*) _hv=0 ;; esac
    _HOOK_VC_HAVE="$_hv"
fi
if [ ! -f "$_HOOK_APK" ]; then
    ui_print "! 互传常开 APK：模块内未找到 hook APK，跳过（不影响模块）"
elif [ -n "$_HOOK_VC_WANT" ] && [ "$_HOOK_VC_HAVE" -ge "$_HOOK_VC_WANT" ] 2>/dev/null; then
    ui_print "- 互传常开 APK：已是最新版 $_HOOK_VN，跳过"
else
    _hook_rc=1
    if command -v pm >/dev/null 2>&1; then
        pm install -r "$_HOOK_APK" >/dev/null 2>&1
        _hook_rc=$?
    fi
    if [ "$_hook_rc" = "0" ]; then
        ui_print "- 互传常开 APK：已安装 $_HOOK_VN"
    else
        ui_print "! 互传常开 APK：安装失败（不影响模块，开机后会自动再装）"
    fi
fi

ui_print "- 互传常开 hook：APK 已在安装时装好（开机还会自动检查一遍）；要真正生效，"
ui_print "  还需在 LSPosed 里启用“互传常开”模块、作用域勾“一加互传”、再重启一次。"
ui_print "- 安装完成，重启生效。默认 balanced 模式。"
# 0.4.48：日志路径和 lib.sh 同一套解析（ONEPLUS_SCHED_LOG_DIR →
# SCHED_TEST_ROOT → /data/media/0/调度器日志 → /data/local/tmp）；
# 打印时把 /data/media/0 换成她在文件管理器里看到的 /storage/emulated/0。
# C3（0.4.50）：不能只验 media 根目录可写就报内部存储——lib.sh 还
# 要求“调度器日志”子文件夹能建出来且可写，子文件夹被同名文件挡住
# 时实际是回落 /data/local/tmp 的，提示要跟着回落，别指错地方。
# C4 的标记文件也先看一眼（和 lib.sh 同一个标记，指哪报哪）。
_LOGSHOW="${ONEPLUS_SCHED_LOG_DIR:-}"
if [ -z "$_LOGSHOW" ]; then
    if [ -n "${SCHED_TEST_ROOT:-}" ]; then
        _LOGSHOW="$SCHED_TEST_ROOT"
    else
        _marker="${ONEPLUS_SCHED_LOGDIR_MARKER:-/data/local/tmp/oneplus_sched_logdir}"
        if [ -f "$_marker" ]; then
            _mv=$(cat "$_marker" 2>/dev/null | tr -d ' \t\r\n')
            case "$_mv" in
                */调度器日志)
                    if [ -d "$_mv" ] && [ -w "$_mv" ]; then
                        case "$_mv" in
                            /data/media/0/*) _LOGSHOW="/storage/emulated/0/${_mv#/data/media/0/}" ;;
                            *) _LOGSHOW="$_mv" ;;
                        esac
                    fi
                    ;;
            esac
        fi
        if [ -z "$_LOGSHOW" ]; then
            _md="${ONEPLUS_SCHED_MEDIA_DIR:-/data/media/0}"
            if [ -d "$_md" ] && [ -w "$_md" ]; then
                if [ ! -d "$_md/调度器日志" ]; then
                    mkdir -p "$_md/调度器日志" 2>/dev/null || true
                fi
                if [ -d "$_md/调度器日志" ] && [ -w "$_md/调度器日志" ]; then
                    _LOGSHOW="/storage/emulated/0/调度器日志"
                else
                    _LOGSHOW="/data/local/tmp"
                fi
            else
                _LOGSHOW="/data/local/tmp"
            fi
        fi
    fi
fi
ui_print "- 先看日志：$_LOGSHOW/调度日志.log"
ui_print "- 卸载/禁用后重启即恢复原厂。"
