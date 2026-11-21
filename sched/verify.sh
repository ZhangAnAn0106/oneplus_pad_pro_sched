#!/system/bin/sh
# verify.sh - 只读体检：不写任何节点，先看清平板真实的拓扑再决定调什么
# 用法（不需要装模块）：
#   adb shell su -c "sh /sdcard/verify.sh"        # 先把文件推到平板
#   或在平板 root shell 里：sh verify.sh
#   输出可加 > /sdcard/verify.txt 再发出来对参数。
# 在普通 Linux 上跑会大量显示“不存在”，那是正常的，只看 Android 真机输出。

echo "=== 1. 设备 / 系统 ==="
getprop ro.product.model 2>/dev/null | sed 's/^/model: /'
getprop ro.product.device 2>/dev/null | sed 's/^/device: /'
getprop ro.build.version.release 2>/dev/null | sed 's/^/android: /'
getprop ro.build.version.sdk 2>/dev/null | sed 's/^/sdk: /'
uname -a 2>/dev/null
echo "root: uid=$(id -u 2>/dev/null) (0=有root)"
ls -d /data/adb/modules/* 2>/dev/null | sed 's/^/module: /'
echo ""
echo "=== 2. CPU 拓扑（核号 / 最高频 / 当前调频器 / 在线）==="
for _d in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -d "$_d" ] || continue
    i=$(basename "$_d" | sed 's/^cpu//')
    _max=$(cat "$_d/cpufreq/cpuinfo_max_freq" 2>/dev/null)
    _min=$(cat "$_d/cpufreq/cpuinfo_min_freq" 2>/dev/null)
    _gov=$(cat "$_d/cpufreq/scaling_governor" 2>/dev/null)
    _on=$(cat "$_d/online" 2>/dev/null)
    _cap=$(cat "$_d/cpu_capacity" 2>/dev/null)
    echo "cpu$i max=${_max:-?}kHz min=${_min:-?}kHz cap=${_cap:-?} gov=${_gov:-?} online=${_on:-?}"
done
grep -m1 "Hardware\|model name" /proc/cpuinfo 2>/dev/null
echo ""
echo "=== 3. cpufreq policy（调频策略组）==="
for p in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$p" ] || continue
    echo "$p cpus=$(cat "$p/related_cpus" 2>/dev/null) gov=$(cat "$p/scaling_governor" 2>/dev/null)"
    for f in "$p"/schedutil/*; do
        [ -f "$f" ] && echo "  schedutil $(basename "$f")=$(cat "$f" 2>/dev/null)"
    done
done
echo ""
echo "=== 4. cpuset 分组（当前各组能上哪些核）==="
for g in top-app foreground background system-background restricted; do
    for r in /dev/cpuset /sys/fs/cgroup/cpuset; do
        [ -f "$r/$g/cpus" ] && echo "$g ($r): $(cat $r/$g/cpus)"
    done
done
echo ""
echo "=== 5. uclamp（存在才显示，不存在=内核/ROM 没开这项）==="
for g in top-app foreground background; do
    for r in /dev/cpuctl /sys/fs/cgroup/cpu; do
        [ -f "$r/$g/cpu.uclamp.min" ] && echo "$g ($r): min=$(cat "$r/$g/cpu.uclamp.min") max=$(cat "$r/$g/cpu.uclamp.max")"
    done
done
echo ""
echo "=== 6. GPU ==="
for gpu in /sys/class/devfreq/*kgsl-3d0* /sys/class/kgsl/kgsl-3d0; do
    [ -e "$gpu" ] || continue
    echo "$gpu gov=$(cat $gpu/governor 2>/dev/null) min=$(cat $gpu/min_freq 2>/dev/null) max=$(cat $gpu/max_freq 2>/dev/null) cur=$(cat $gpu/cur_freq 2>/dev/null)"
    echo "  available_frequencies: $(cat $gpu/available_frequencies 2>/dev/null)"
done
echo ""
echo "=== 7. 调度参数（存在才显示）==="
for k in sched_migration_cost_ns sched_min_granularity_ns sched_wakeup_granularity_ns sched_latency_ns; do
    [ -f "/proc/sys/kernel/$k" ] && echo "$k=$(cat /proc/sys/kernel/$k)"
done
echo ""
echo "=== 8. 温度（只读，判断散热余量）==="
for z in /sys/class/thermal/thermal_zone*; do
    [ -f "$z/temp" ] || continue
    [ -f "$z/type" ] || continue
    _t=$(cat "$z/temp" 2>/dev/null)
    _ty=$(cat "$z/type" 2>/dev/null)
    case "$_t" in
        ''|*[!0-9]*) echo "$_ty: temp 不可读（${_t:-空}）" ;;
        *) echo "$_ty: $((_t / 1000))C" ;;
    esac
done 2>/dev/null
echo ""
echo "=== 9. 内存 ==="
grep -E "MemTotal|MemAvailable|SwapTotal" /proc/meminfo 2>/dev/null
echo ""
echo "=== 10. 两款游戏装了没有（包名对不上，游戏档就识别不到）==="
if command -v pm >/dev/null 2>&1; then
    pm list packages 2>/dev/null | grep -E "pubgmhd|sgame|codev|valorant" || echo "都没装：和平精英 com.tencent.tmgp.pubgmhd / com.tencent.tmgp.sgame / 无畏契约 com.tencent.tmgp.codev 一个都没找到"
else
    echo "没有 pm 命令，跳过（在平板 root shell 里再跑一次）"
fi
echo ""
echo "=== 完成：把上面输出发出来，就能按真实拓扑定 cpuset / 频率参数 ==="
