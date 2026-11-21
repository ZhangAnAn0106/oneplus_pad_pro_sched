#!/system/bin/sh
# vulkan.sh - 全局 Vulkan 开关 + 渲染检测（0.4.56）
#
# 她原话：“Vulkan 我要的是全开，而不是给游戏开”“全局”。
# 0.4.54/0.4.55 做的是给游戏包开 ANGLE（Settings.Global 的
# angle_gl_driver_selection 两个键），方向错了，0.4.56 整体
# 替换。全局 Vulkan = 系统界面（HWUI）渲染走 Vulkan：属性
# debug.hwui.renderer=skiavk。游戏内部用不用 Vulkan 由游戏
# 自己决定，这个开关管不到游戏，面板文案也如实写明。
#
# 实现：
#   on：把 debug.hwui.renderer=skiavk 写进模块根目录的
#     system.prop（管理器 KernelSU/Magisk 开机自动加载），再
#     resetprop 立即改当前 boot 的属性——新启动的应用先
#     生效，SystemUI 等已在跑的要重启才完全生效；写配置
#     VULKAN_GLOBAL=1。
#   off：删 system.prop 里那一行 + resetprop --delete 删
#     当前属性；写配置 VULKAN_GLOBAL=0。
#   on/off 都顺手清旧残留：ANGLE 的两个 Settings.Global 键
#     只要还设着就删掉（她在 0.4.54/0.4.55 可能开过），不留
#     残留。清理是尽力而为，失败不拦开关本身。
#
# status 口径（写死在这，别含糊）：
#   vulkan_prop_file=1 当且仅当 system.prop 里有
#     debug.hwui.renderer=skiavk 这一整行；
#   vulkan_active=1 当且仅当 getprop debug.hwui.renderer
#     现在就是 skiavk；
#   vulkan_global 两者都为 1 才报 1（文件写了但还没重启
#     生效 → 0，重启后转 1）；
#   vulkan_cfg 是配置里的 VULKAN_GLOBAL 原值。
#
# 用法：
#   vulkan.sh on       # 开全局 Vulkan
#   vulkan.sh off      # 关全局 Vulkan
#   vulkan.sh status   # vulkan_global / vulkan_prop_file / vulkan_active / vulkan_cfg
#   vulkan.sh probe    # 渲染检测，结果写缓存 $VULKAN_PROBE_CACHE 并回显
#
# probe 的消费者是 panel.sh 的实时状态渲染组（系统界面 +
# 全局 Vulkan 两行）：panel 的状态查询只读缓存、绝不直接跑
# probe；缓存只由页面每约 15 秒的 probe 定时器异步刷新，
# 新鲜度只看时间戳（60 秒）。probe 全程容错：外部命令缺失/
# 失败退化成 unknown，退出码恒 0，不许把状态查询带崩。

MODDIR="${0%/*}/.."
if [ -n "$SCHED_TEST_MODDIR" ]; then MODDIR="$SCHED_TEST_MODDIR"; fi
# shellcheck disable=SC1091
. "$MODDIR/sched/lib.sh"
load_config "$MODDIR/sched/config.conf"
CFG="$MODDIR/sched/config.conf"

SYS_PROP="$MODDIR/system.prop"
PROP_KEY="debug.hwui.renderer"
PROP_VAL="skiavk"
PROP_LINE="$PROP_KEY=$PROP_VAL"
SETTINGS_PKGS_KEY="angle_gl_driver_selection_pkgs"
SETTINGS_VALS_KEY="angle_gl_driver_selection_values"

# system.prop 里有没有生效的那一整行。
_vk_propfile() {
    if [ -f "$SYS_PROP" ] && grep -q -x -F "$PROP_LINE" "$SYS_PROP" 2>/dev/null; then
        echo 1
    else
        echo 0
    fi
}

# 当前属性是不是 skiavk（getprop 不可用/没设都算 0）。
_vk_active() {
    _r=""
    if command -v getprop >/dev/null 2>&1; then
        _r=$(getprop "$PROP_KEY" 2>/dev/null | tr -d ' \t\r\n')
    fi
    if [ "$_r" = "$PROP_VAL" ]; then echo 1; else echo 0; fi
}

# 全局 Vulkan 的综合状态：文件有行 AND 当前属性已生效才 1。
vk_global_state() {
    if [ "$(_vk_propfile)" = "1" ] && [ "$(_vk_active)" = "1" ]; then
        echo 1
    else
        echo 0
    fi
}

# 把 system.prop 里所有 debug.hwui.renderer= 行换成 PROP_LINE
# （$1=1 写）或全删（$1=0 删）。其他行（注释和以后的属性）
# 原样保留。临时文件 + mv，写一半不许被管理器读到。
_vk_prop_apply() {
    _tmp="$SYS_PROP.vk.$$"
    printf '' > "$_tmp" 2>/dev/null || return 1
    if [ -f "$SYS_PROP" ]; then
        while IFS= read -r _line || [ -n "$_line" ]; do
            case "$_line" in
                "$PROP_KEY="*) ;;
                *) printf '%s\n' "$_line" >> "$_tmp" ;;
            esac
        done < "$SYS_PROP"
    fi
    if [ "$1" = "1" ]; then echo "$PROP_LINE" >> "$_tmp"; fi
    if mv "$_tmp" "$SYS_PROP" 2>/dev/null; then
        return 0
    fi
    rm -f "$_tmp" 2>/dev/null || true
    return 1
}

# settings get：没设过时系统回 "null"，统一成空。
_vk_get() {
    _v=$(settings get global "$1" 2>/dev/null)
    case "$_v" in ''|null) echo "" ;; *) echo "$_v" ;; esac
}

# 迁移清理：旧 ANGLE 的两个键只要还设着就删。尽力而为，
# settings 不可用/删除失败都不拦开关本身。
_vk_cleanup_angle() {
    command -v settings >/dev/null 2>&1 || return 0
    if [ -n "$(_vk_get "$SETTINGS_PKGS_KEY")" ] || [ -n "$(_vk_get "$SETTINGS_VALS_KEY")" ]; then
        settings delete global "$SETTINGS_PKGS_KEY" 2>/dev/null || true
        settings delete global "$SETTINGS_VALS_KEY" 2>/dev/null || true
    fi
    return 0
}

# 写 VULKAN_GLOBAL 进 config（只改这一行、临时文件 + mv、
# 写完备份，升级不丢）。
_vk_set_config() {
    _tmp="$CFG.vk.$$"
    printf '' > "$_tmp" 2>/dev/null || return 1
    _found=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            VULKAN_GLOBAL=*) echo "VULKAN_GLOBAL=$1" >> "$_tmp"; _found=1 ;;
            *) printf '%s\n' "$_line" >> "$_tmp" ;;
        esac
    done < "$CFG"
    if [ "$_found" = "0" ]; then echo "VULKAN_GLOBAL=$1" >> "$_tmp"; fi
    if mv "$_tmp" "$CFG" 2>/dev/null; then
        backup_config "$CFG"
        return 0
    fi
    rm -f "$_tmp" 2>/dev/null || true
    return 1
}

vk_on() {
    _vk_prop_apply 1 || { echo "ERR 写 system.prop 失败"; return 1; }
    _note=""
    if command -v resetprop >/dev/null 2>&1; then
        resetprop "$PROP_KEY" "$PROP_VAL" 2>/dev/null || { echo "ERR resetprop 设置 $PROP_KEY 失败"; return 1; }
        # 回读校验：当前属性必须已经是 skiavk，不然不许报成功。
        if [ "$(_vk_active)" != "1" ]; then
            echo "ERR 回读校验失败：resetprop 后 $PROP_KEY 不是 $PROP_VAL"
            return 1
        fi
    else
        _note="（resetprop 不可用，当前属性未改，重启后由 system.prop 生效）"
    fi
    _vk_cleanup_angle
    _vk_set_config 1 || { echo "ERR 写配置 VULKAN_GLOBAL=1 失败"; return 1; }
    rm -f "$VULKAN_PROBE_CACHE" 2>/dev/null || true
    echo "OK 全局 Vulkan 已开启：system.prop 已写入 $_note（重启平板完全生效）"
}

vk_off() {
    _vk_prop_apply 0 || { echo "ERR 改 system.prop 失败"; return 1; }
    if command -v resetprop >/dev/null 2>&1; then
        # --delete 对不存在的属性在个别实现上返回非 0，容忍；
        # 以删完后的回读为准。
        resetprop --delete "$PROP_KEY" 2>/dev/null || true
        if [ "$(_vk_active)" = "1" ]; then
            echo "ERR 回读校验失败：删属性后 $PROP_KEY 仍是 $PROP_VAL"
            return 1
        fi
    fi
    _vk_cleanup_angle
    _vk_set_config 0 || { echo "ERR 写配置 VULKAN_GLOBAL=0 失败"; return 1; }
    rm -f "$VULKAN_PROBE_CACHE" 2>/dev/null || true
    echo "OK 全局 Vulkan 已关闭（重启平板完全生效）"
}

vk_status() {
    echo "vulkan_global=$(vk_global_state)"
    echo "vulkan_prop_file=$(_vk_propfile)"
    echo "vulkan_active=$(_vk_active)"
    echo "vulkan_cfg=${VULKAN_GLOBAL:-0}"
}

# ---------- probe（检测） ----------

# 系统界面渲染：gfxinfo 的 Pipeline 行最准（Skia Vulkan/OpenGL）；
# 取不到退 hwui renderer 属性（skiavk=Vulkan，其余=OpenGL 默认）；
# 都没有 → unknown，不硬判。
vk_sys_renderer() {
    if command -v dumpsys >/dev/null 2>&1; then
        _pl=$(dumpsys gfxinfo com.android.systemui 2>/dev/null | grep -i 'pipeline' | head -n 1)
        case "$_pl" in
            *[Vv]ulkan*) echo "vulkan"; return ;;
            *[Oo]penGL*) echo "opengl"; return ;;
        esac
    fi
    if command -v getprop >/dev/null 2>&1; then
        _r=$(getprop debug.hwui.renderer 2>/dev/null | tr -d ' \t\r\n')
        case "$_r" in
            skiavk) echo "vulkan" ;;
            *) echo "opengl" ;;
        esac
        return
    fi
    echo "unknown"
}

vk_probe() {
    _ts=$(date +%s 2>/dev/null)
    case "$_ts" in ''|*[!0-9]*) _ts=0 ;; esac
    _out="probe_ts=$_ts
vulkan_global=$(vk_global_state)
sys_renderer=$(vk_sys_renderer)"
    # 先写缓存（临时文件 + mv，别让 panel 读到写一半的）；写缓存
    # 失败不影响回显，状态顶多继续显示“检测中”。
    _tmp="$VULKAN_PROBE_CACHE.tmp.$$"
    if printf '%s\n' "$_out" > "$_tmp" 2>/dev/null; then
        mv "$_tmp" "$VULKAN_PROBE_CACHE" 2>/dev/null || rm -f "$_tmp" 2>/dev/null || true
    fi
    printf '%s\n' "$_out"
    return 0
}

case "${1:-status}" in
    on) vk_on ;;
    off) vk_off ;;
    status) vk_status ;;
    probe) vk_probe ;;
    *) echo "用法: vulkan.sh on|off|status|probe"; exit 2 ;;
esac
