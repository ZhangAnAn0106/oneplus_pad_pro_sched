# 一加平板 Pro 性能调度模块 + 线程模块

> ⚠️ **仅在一加平板 Pro（OPD2404，骁龙 8 Gen 3）上实测过，其他机型不要刷，后果自负。**
>
> **温控来源**：本模块的温控配置文件（`thermal/` 目录）来自 Extreme GT（作者：嘟嘟ski）4.2.2 版，本模块仅集成其配置文件，版权归原作者所有。
>
> **首发与版权**：作者 桉桉，首发仓库为 github.com/ZhangAnAn0106/oneplus_pad_pro_sched，提交记录即原创凭证；转载请注明出处，禁止换名盗发与商业转售。
>
> **搭配官方调度使用（前提是改过散热）**：本模块是在散热（温控）已经改过的前提下，搭配系统官方调度一起用的——模块自带的去温控就是负责改散热的那部分；调度部分不替换、不绕过官方调度，内核 governor 仍是官方的，只在其之上调整参数、做 cpuset 分组与线程绑核，与官方调度不互抢、不冲突。

## 功能清单

- **四档调度模式**：省电 / 均衡 / 性能 / 游戏，面板一键切换；游戏档与性能档拉开真实差距（GPU 频率下限、uclamp、前台核心分组、降频延迟都不同）
- **游戏自动跟随**：检测到游戏进程自动进游戏档，切去别的 App 不掉档，游戏真退出才恢复
- **线程绑核**：游戏模式下按线程类型自动绑核（主线程/渲染/音频/网络/输入各归其位），日常模式自动绑前台应用
- **游戏后台保活**：四层防护（oom 钉位、电池白名单、系统级后台放行断言、待机分组），切微信几分钟回来游戏不被杀；被杀时自动抓取证日志，分清是内存回收还是厂商强杀
- **进游戏自动清理后台**：每局一次，只清闲置的缓存应用，系统应用和白名单（音乐、输入法等）不动
- **内存（zram）**：预置 lz4 24GB，开机自动生效，升级保留设置
- **去温控**：集成 Extreme GT 配置（来源见上），常开，伪装电池/外壳温度，CPU 真实温度与硬件过热保护不受影响
- **全局 Vulkan 渲染**：面板开关，开启后全局走 skiavk 渲染
- **一加互传常开**：自带 LSPosed 小模块，刷入时自动安装，让一加互传不再 10 分钟自动关（手动关不受影响）
- **WebUI 面板**：KernelSU 管理器内打开，调度页（状态/模式/游戏跟随）+ 功能页（温控/内存/图形/诊断与日志），状态 2 秒自动刷新
- **分类日志与诊断**：调度/温控/内存/诊断四类日志分开记录，各自封顶滚动；带 uclamp 诊断和互传诊断

目标机型：一加平板 Pro（OPD2404），骁龙 8 Gen 3，12.1 英寸 3K 144Hz，ColorOS。
芯片是 1+5+2：1× Cortex-X4 3.3GHz + 5× Cortex-A720 3.2/3.0GHz + 2× Cortex-A520 2.3GHz，GPU Adreno 750。

> 调度这部分已经在真机上实测过（14:00 那局和平精英平均 118.6 帧、基本锁 120）。去温控是 0.4.29 新加的开关，默认关，只有你打开才动温控；打开前先看下面 0.4.29 那节。先跑 `verify.sh`，把输出发出来对一遍拓扑，再决定要不要开 performance。

## 维护说明

- **module.prop 的 description 只写功能清单，永不追加版本改动**（2026-11-21 她定的）。版本流水账只写本 README 的更新记录区。0.4.58 起 description 已整段换成功能清单，后续升版只改 version/versionCode，不动 description，除非功能本身增减。

## 0.4.60 更新（2026-11-22，watch 卡死修复：外部命令超时 + 心跳自愈）

纯 bug 修复。真机现象（2026-11-21 晚）：watch 在 23:00:06 写完最后一行日志后卡死，直到 00:35 重启才恢复，中间约 65 分钟游戏检测、绑核、保活全停（那局的游戏档和去温控是她在面板手动开的）。代码审查定位到两个病根：

- **外部命令无超时**：watch 循环里 dumpsys / cmd / pm / am 全是同步调用，系统服务偶尔卡住一个，watch 就在那一行无限等下去，不报错也不退出。
- **没有守护**：service.sh 开机只启动 watch 一次，之后再没人看它死活，卡死只能靠重启平板恢复。

修法两处：

- **lib.sh 新增 `run_to <秒数> <命令...>`**：命令放后台跑、stdout 落临时文件、轮询等待，正常结束原样返回输出和退出码；超时杀掉、记一行 WARN、返回 124。watch 路径上的调用点全包上：pkg_from_dumpsys 的 dumpsys window/activity、screen_state / 自动模式取证 / 唤醒源的 dumpsys power、被杀取证的 dumpsys activity exit-info、保活④的 cmd appops / cmd activity（及 appops / am 回退）、保活②的 cmd deviceidle、自动清理的 pm list packages（以上 5 秒）和 am force-stop（3 秒）。面板手动命令、诊断脚本这次不动。
- **watch 心跳 + service.sh 守护**：watch 每轮把当前秒数写进 `oneplus_watch_heartbeat`；service.sh 启动 watch 时同时启动一个单实例守护（`service.sh guardian` 子命令），每 60 秒查一次心跳，超过 180 秒没更新就杀掉旧 watch 重新拉起并记一行 WARN，拉起时先垫一拍心跳防误判抖动。thread.sh stop 会落 `oneplus_watch_disabled` 停用标记，守护见标记就自己退出，绝不把手动停掉的 watch 拉回来；watch 正常启动和开机时清标记。守护正常巡检不记日志；模块目录没了（已卸载）守护也自己退出。

harness：新增 T108（run_to 快命令原样返回输出与退出码、慢命令超时被杀返回 124 且不残留临时文件并记 WARN；watch 心跳每轮更新、stop 落停用标记；守护三态：心跳新鲜不动 / 心跳过期无标记自动重启并记 WARN、新 watch 接上后不再重复记 / 有停用标记守护自退不拉起）。version 0.4.60 / versionCode 64，description 不动。

## 0.4.59 更新（2026-11-21，保活补强 + 绑核屡败停放）

两件事，都是 0.4.58 上线当天真机日志逼出来的：

- **保活补强（第 ④ 件）**：0.4.57 的取证当天就抓到实锤——16:40:36 她切去微信约 6 秒，游戏被杀，诊断日志 `[exitinfo]` 记 `reason=13 (OTHER KILLS BY SYSTEM)`、`importance=300`：是厂商后台策略强杀，不是内存回收也不是电池策略，0.4.57 的 ①② 挡不住。④ 在每局开始（和电池白名单同一门控、同样受 `GAME_KEEPALIVE` 总控）对两个游戏包断言系统级放行：`cmd appops set <包> RUN_ANY_IN_BACKGROUND allow`、`RUN_IN_BACKGROUND allow`、`cmd activity set-standby-bucket <包> active`（cmd 不在时回退 `appops` / `am` 裸命令）。全过记一行 INFO，单包失败只记一行 WARN，不阻断游戏模式。边界不变：这层是把系统级放行信号断言到位、降低被强杀概率，主力解法仍是系统设置里给和平精英开电池不受限 + 完全后台行为 + 最近任务锁定（待她操作与复验）。
- **绑核屡败停放**：同一天下午的日志里，她在桌面时启动器一个线程（tid=26434、mask=7c）连败 6+ 轮，watch 每轮整包重绑空转、WARN 刷屏。改成按进程记失败计数（`thread_state.bindfail.<pid>`，每行 tid/mask/连续失败次数）：同一 (tid,mask) 连败满 3 次只记一行“绑核屡败已停放”，后续轮次直接计 skip、不再调 taskset；绑成功清计数，进程消失连档删除、新进程从零开始。停放行计 skip，与 0.4.19 的全败判定（ok=0 且 fail>0 且 skip=0 才退避）兼容，不会把整包拖进 300 秒退避。手动一次性绑核路径不纳入。

harness：新增 T106（④ 的 cmd 主路径每包三条断言每局各一次、单包失败 WARN 一行且游戏档/白名单照常、无 cmd 回退 appops/am、GAME_KEEPALIVE=0 时不做；停放的连败 3 次后停、taskset 真调用恰 3 次、末轮 ok=0 fail=0 skip=3、无全败 WARN、进程消失删档、新 pid 从零重试）。version 0.4.59 / versionCode 63，description 不动。

## 0.4.58 更新（2026-11-21，精简模块介绍）

只改介绍，不动任何功能：module.prop 的 description 整段换成功能清单（历代版本逐版追加的流水账全删），立下维护规矩（见上）。version 0.4.58 / versionCode 62。

## 0.4.57 更新（2026-11-21，游戏后台保活 + 被杀取证）

她反馈：“切个应用两三分钟，然后游戏就被杀后台了。”杀进程分两种：内存回收型（LMK 按 `oom_score_adj` 从高到低杀）和厂商策略强杀（ColorOS 后台管理直接 force-stop）。这版把能挡的挡上，并自动抓证据分清是哪种。**全部自动，面板不加任何控件**（她不要新开关），一个总控配置 `GAME_KEEPALIVE=1`（默认开，只增不覆盖，关了三件全停）：

- **oom 钉位**：游戏模式期间，watch 每轮检查游戏主进程的 `/proc/<pid>/oom_score_adj`，高于 -1000 就写 -1000（最低被杀位），挡 LMK 回收型。只钉游戏主进程；游戏换 PID 跟着新 PID 走；写失败只记一行 WARN（同 PID 只记一次，不刷屏）。进程级设置，进程死了自动没，不需要恢复动作。
- **电池白名单**：每局游戏检测到时（每局一次，和自动清理后台同节奏），对两个游戏包执行 `cmd deviceidle whitelist +<包名>`，等于系统设置里的“电池不受限”，结果记调度日志一行。常驻不撤销。
- **被杀取证**：watch 发现游戏从“在”变“不在”、且当时还在游戏档（restore 还没跑）时，立刻抓一次 `dumpsys activity exit-info`（两个游戏包都查），把最近一条退出记录的时间、reason、subreason、description、status 拼成一行 `[exitinfo]` 写进**诊断日志**。ApplicationExitInfo 是系统给每次进程退出记的原因和来源，是分清 LMK / 策略强杀 / 崩溃的决定性证据。只在消失那一轮跑一次，绝不进常规轮询。她自己正常退游戏也会留一条（reason 是用户退出），汇报口径能区分。

边界：ColorOS 后台管理若直接 force-stop 游戏进程，系统层没有正当接口能拦下来——①②挡的是回收和电池策略，真被强杀就靠③的记录确认，再决定下一步（比如系统设置里给游戏开自启动/后台无限制）。

harness：新增 T105（oom 高于 -1000 被钉、已是 -1000 不重复写看 mtime、电池白名单每局只调一次且两个包都加、游戏消失触发 exit-info 且只跑一次且只取最近一条写进诊断日志、GAME_KEEPALIVE=0 时三件全不做）；customize 合并白名单加 GAME_KEEPALIVE。

下一步：刷 0.4.57 后正常打一局，中途切出去几分钟回来看看游戏还在不在；如果还被杀，把诊断日志发回来，`[exitinfo]` 那行直接写了原因。

## 0.4.56 更新（2026-11-20，Vulkan 改全局 + 互传 hook 打包升 1.4）

两件事：Vulkan 按她纠正改全局；模块打包的互传 hook 换成 1.4。调度行为没动。

- **Vulkan 改全局（她原话：“Vulkan 我要的是全开，而不是给游戏开”“全局”）**：0.4.54/0.4.55 给游戏包开 ANGLE 的方向作废，整体替换。全局 Vulkan = 系统界面（HWUI）渲染走 Vulkan：`vulkan.sh` 重写 on/off/status/probe——on 把 `debug.hwui.renderer=skiavk` 写进模块根目录新文件 `system.prop`（管理器 KernelSU/Magisk 开机自动加载）+ `resetprop` 立即改当前属性并回读校验（新启动的应用先生效，SystemUI 等已运行的要重启才完全生效），off 删 system.prop 里那行 + `resetprop --delete` + 回读校验；配置键改 `VULKAN_GLOBAL`（customize 合并白名单同步加），旧键 `VULKAN_GAME` 改注释退役、键保留不删（只增不删的规矩，同 OSHARE_ALWAYS_ON）。迁移清理：on/off 两个方向都顺手删旧 ANGLE 的两个 Settings.Global 键（`angle_gl_driver_selection_pkgs` / `_values`），她在 0.4.54/0.4.55 开过也不留残留。status 口径写死：`vulkan_global` = system.prop 有 skiavk 行 AND 当前 getprop 已是 skiavk 才报 1，`vulkan_prop_file` / `vulkan_active` 分开报（只写文件没重启生效就是 0，不含糊）。probe 只产系统界面 + vulkan_global，缓存机制照 0.4.55（只读缓存、页面 15 秒定时器刷新、2 秒轮询不碰）。面板图形区开关改名“全局 Vulkan”，说明如实写“开启后重启平板，全系统界面渲染走 Vulkan（游戏内部用不用 Vulkan 由游戏自己决定）”；状态卡渲染组第二行改“全局 Vulkan”（`stVulkanGlobal`）。
- **互传 hook 打包升 1.4/vc5**：`oshare/oshare-hook.apk` 换成独立交付的 1.4（SHA-256 d423dd78…，三层拦 AlarmManager 定时关闭：getSwitchTimeOut 恒 -1、注册闹钟的 q7.e.d() 整体 no-op、TimeoutReceiver 只吞 switch.timeout 广播，手动关不受影响）；`oshare_hook.sh` 的 `HOOK_APK_VC` 4→5、customize.sh 显示名 `_HOOK_VN` 改 1.4（VC 仍从 oshare_hook.sh 动态解析），刷模块装 APK 的逻辑不变、会自动按 vc5 比较安装。

harness：T104 按新机制整体重写（resetprop/getprop/settings/dumpsys 打桩：on 写 prop 文件+调 resetprop+回读、off 删行+--delete、两个方向都验迁移删 ANGLE 键、status 三分量口径含“只写文件没生效”半开态、probe 两行与全缺容错；旧 ANGLE 写入类断言全删，新增红线 vulkan.sh 无 settings put）；T98k/T101h/T102 的版本号期望改动态读（HOOK_APK_VC 从 oshare_hook.sh 读、显示名从 customize.sh 读、T101h 改成脚本值与 APK 清单值动态互比），T98b/T102c 的“已最新”已装 VC 改动态写入；T40f 版本跟到 0.4.56/vc60。全量 1395/1395，zip 复跑 160/160。

下一步：刷 0.4.56。重点看三件：图形区开关是“全局 Vulkan”、开一次重启后状态卡渲染组“全局 Vulkan”显示开；互传刷完即装 1.4（安装时有 ui_print），重启后打开互传放超过 10 分钟不再自动关。

## 0.4.55 更新（2026-11-20，状态卡再删两处 + 面板打开提速）

两件事：按她在 0.4.54 截图上画的红圈删状态行；修她反馈的“面板打开卡半天、状态全是 —”。调度行为没动。

- **状态卡再删**：内存组整组删掉（可用内存、zram 两行），后端 `panel.sh status` 一并停产 `mem_avail_kb` / `zram_algo` / `zram_disksize` 三个字段（fast 和完整版都没有；功能页的 zram 区还在，删的只是状态卡显示）。渲染组里的游戏行全删（和平精英、和平精英（渠道）、无畏契约），只剩系统界面 + ANGLE 强制两行；状态卡底下说明文字同步改。状态只剩调度 / 游戏 / 渲染三组。
- **vulkan probe 相应精简**：`vulkan.sh probe` 只产系统界面 + ANGLE 强制，不再扫 /proc、不读游戏进程 maps、不再产 `game_renderer_*` 和进程签名；缓存新鲜度只看时间戳（60 秒内新鲜，过期显示“检测中”），游戏进程变化不再让缓存失效。`vulkan on/off/status` 不动。
- **面板打开提速（慢点清单）**：① 完整 `status` 不再同步跑 vulkan probe——0.4.54 时完整 status 先跑一次 probe 再返回，probe 的 dumpsys gfxinfo 以秒计，这是打开后卡半天的主嫌疑；现在完整版和 fast 一样只读缓存，probe 只由页面约 15 秒定时器异步刷新。② `_emit_render_state` 不再每次状态查询都子进程调 `vulkan.sh sig` 扫 /proc 判签名（签名机制随游戏行一起删了）。③ 页面启动顺序重排：旧顺序是 probeHost 探测 → state → 完整 status 全落定才开轮询（S40 的 bootDoneFlag 门），任何一环卡住整页冻住、状态全是 —；现在配置先行（`get` 是纯文件读 cat config.conf，回来立刻渲染开关/模式，读路径不加锁、不等锁）、2 秒轮询立刻起并马上跑一拍、完整 status 和 zram 状态各自异步补、probeHost 只在后台探测不再串在启动链上，各通道互不阻塞。④ 审过读路径：`panel.sh get` 本来就是纯 cat；配置锁只守写路径（set），读不碰；lib.sh source 时只有日志目录解析的文件探测，无 sleep/外部重命令；thermal_auto.sh source 时只设变量。

harness：T104 更新到新结构（probe 只产系统界面、缓存只按时间三态、完整 status 不再刷新缓存、内存组字段进停产清单、状态卡三组小标题和被删行 id 负向断言），新增 T104g 读路径红线静态守卫（cmd_status 函数体无 dumpsys/vulkan 直调、_emit_render_state 只读缓存、vulkan.sh 无 game_renderer_/probe_gamesig//maps、get 是纯 cat、页面无 bootDoneFlag 门和 probeHost 串行链）；T40a/T40e/T74e/T77f–h/T99e 的启动时序断言更新到 0.4.55 新顺序；T40f 版本跟到 0.4.55/vc59。全量 1371/1371，zip 复跑 160/160。

下一步：刷 0.4.55。重点看两件：面板打开应该立刻有数、不再卡半天；状态卡只剩三组、渲染组只有系统界面和 ANGLE 两行。

## 0.4.54 更新（2026-11-19，面板分类重排 + 状态精简 + Vulkan 开关与检测 + 删面板互传区）

四件事，都是面板/显示层和新增的 vulkan.sh，调度行为本身没动。

- **面板按功能分类重排**：调度页 = 实时状态 / 模式 / 游戏跟随（跟随开关、游戏进程自动检测、进游戏自动清理后台、游戏调度联动、开机自动跟随，顺序按这个排）；功能页 = 温控 / 内存 / 图形（新）/ 诊断与日志。每类一个带标题的区、标题在卡片外，现有控件只是搬位置，行为不变。
- **实时状态精简 + 分组**：调频器、GPU 频率上下限、温度、CPU 拓扑四类行整段删除，后端 `panel.sh status` 一并停产这几个字段（fast 和完整版都没有）。剩下的按调度（日常模式、跟随 watch）/ 游戏（游戏模式、运行中的游戏、前台应用）/ 内存（可用内存、zram 算法+大小）/ 渲染（见下）四组显示，组间有小标题分隔，值改成单行短文本，卡片高度不再忽长忽短。2 秒轮询仍只走快速状态。
- **Vulkan 开关与检测**：功能页图形区一个开关。开 = 走系统官方 ANGLE 通道：把游戏包名（PEACE/VALORANT 配置展开去重）写进 Settings.Global 的 `angle_gl_driver_selection_pkgs` / `angle_gl_driver_selection_values`（每个包对应一个 angle），回读校验后写配置 `VULKAN_GAME=1`；关 = 删这两个键。不用 skiavk 那套（那只换系统界面渲染，跟游戏无关），不动游戏文件、重启保留，切换后要重进游戏才生效。检测（`sched/vulkan.sh probe`）进实时状态渲染组：系统界面一行（gfxinfo 的 Pipeline 行判 Skia Vulkan/OpenGL，取不到退 hwui renderer 属性）、每个游戏一行（读主进程 /proc/<pid>/maps：有 angle 库且该包在 ANGLE 列表里 → OpenGL·ANGLE，有 libvulkan → Vulkan，只有 GLES 库 → OpenGL，没运行 → 未运行，maps 读不到退 gfxinfo，再不行给未知不硬判）、ANGLE 强制一行。**性能红线**：probe 太重（dumpsys/读 maps），绝不进 2 秒快速轮询——结果带时间戳和游戏进程签名缓存到状态文件，快速状态只读缓存；缓存由完整 status（慢路径）和页面每约 15 秒单独调一次 probe 刷新；缓存超过 60 秒或游戏进程变了，状态显示“检测中”而不是旧值。
- **删面板互传区**：功能页互传区整段删除（hook 状态行、互传诊断按钮原位置），`panel.sh oshare status` 子命令、状态输出里的 oshare/hook_apk 字段、后端 `sched/oshare.sh` 一并删净。**互传诊断保留**：按钮并入“诊断与日志”区同一张卡（和日志类别 chips、查看/清空日志并列），`panel.sh oshare-diag` 和 `sched/oshare_diag.sh` 不动。**hook 本体不受影响**：oshare/oshare-hook.apk 照常打包、customize.sh 刷模块时照常装、service.sh 开机 ensure 照常——删的只是面板上的显示和状态命令。

harness：T87g/T88/T89b/T89e/T95b/T98/T99/T101e 更新到新结构（互传诊断位置、oshare 面板面负向断言、开关数 8、fmtHz 随 GPU 行删除退役）；新增 T104（vulkan on/off/status 打桩 settings 验键值与包名/angle 对应、probe 四种游戏情形 + gfxinfo 兜底 + 命令全缺容错、缓存新鲜/过期/换 pid 三态、完整 status 刷新缓存、状态字段停产清单、内存组新字段、页面分类静态 + pollTick 不调 probe 的红线断言）、T40f 版本跟到 0.4.54/vc58。全量 1349/1349，zip 复跑 160/160。

下一步：刷 0.4.54。面板结构变了但调度行为与 0.4.53 一致；Vulkan 开关默认关，想试再开（开完重进游戏，调度页渲染组会显示游戏实际跑的渲染器）。

## 0.4.53 更新（2026-11-19，温控数据升 Extreme GT 4.2.2）

只换一个文件，其余一律不动。

- **换了什么**：thermal/odm/etc/devices_config/devices_config.json 换成 Extreme GT 4.2.2 的版本。两版逐文件比对：9 个温控配置里 8 个逐字节相同，只有这个 JSON 变了——第 69 行 `"high.capacity.threshold": 85` 后面补了一个逗号。合并后 thermal/ 9 个文件与 4.2.2 包逐字节一致（已逐个 cmp 验过）。
- **这是修什么**：4.2.1 那份（模块里一直在用的那份）是坏 JSON——严格解析器读到第 70 行就报错；4.2.2 那份能完整解析通过。这个文件是充电参数配置（charge 段），值本身一个数字都没变，所以行为上不该有任何变化；旧文件随模块跑了很久、无实测异常，厂商解析器应是容忍了这个缺逗号。这次是把文件本身修对，顺手消掉“哪天碰上严格解析的组件就出事”的隐患。
- **他们的脚本不合**：4.2.2 的 post-fs-data.sh、service.sh、system.prop 与 4.2.1 全相同，本来也不在合并范围里（horae 仍由我们 thermal.sh 用 resetprop 管）。

harness：新增 T103（thermal/ 下所有 .json 必须能被 python3 严格解析；无 python3 时整段跳过并注明未验，不假过）、T40f 版本跟到 0.4.53/vc57。全量 1262/1262，zip 复跑 160/160。

下一步：刷 0.4.53，行为应与 0.4.52 完全一致（温控挂载 9/9、伪装 14/14 照旧）。

## 0.4.52 更新（2026-11-19，刷模块时当场装好互传 hook APK）

只改 customize.sh 一处，0.4.51 的其余内容原样保留。

- **她的要求**：“在安装模块时把 apk 安装完成，然后模块完成。”之前 hook APK 是开机后由 service.sh 调 oshare_hook.sh ensure 才装的——刷完模块还得等一次开机才装上。现在 customize.sh 在安装过程的末尾（模块文件、配置恢复都处理完之后）就把 oshare/oshare-hook.apk（com.nora.osharehook，1.3/vc4）直接装好，刷完即完成。
- **怎么装**：要装的 versionCode 不写第二份——从 sched/oshare_hook.sh 的 HOOK_APK_VC 解析；已装版本用 dumpsys package 查。未装或更旧 → `pm install -r` 装上，ui_print 报“互传常开 APK：已安装 1.3”；已是最新 → 报“已是最新版 1.3，跳过”；dumpsys/pm 不可用时查不到版本也照样装一次试试，不会因为查不到就跳过。
- **失败不拦安装**：pm install 失败只 ui_print 告警“安装失败（不影响模块，开机后会自动再装）”，模块安装照常走完；service.sh 开机 ensure 原样保留作兜底。

harness：新增 T102（打桩 pm/dumpsys 跑 customize 全程：未装→装、旧版 vc3→装、已最新 vc4→跳过且不调 install、pm 失败→只告警且安装走完、无 dumpsys→照样装；静态断言 customize 里有这段、VC 从 oshare_hook.sh 解析、没写死第二份 HOOK_APK_VC=4）、T40f 版本跟到 0.4.52/vc56。全量 1260/1260，zip 复跑 160/160。

下一步：刷 0.4.52，安装界面里应直接出现“互传常开 APK：已安装 1.3”（或“已是最新版 1.3，跳过”），不用再等开机才装。

## 0.4.51 更新（2026-11-19，互传 hook 1.3 修熄屏久置概率失效）

只换打包的互传 hook APK（1.2/vc3 → 1.3/vc4，HOOK_APK_VC=4），调度/WebUI/配置一律不动，0.4.50 的 23 项修复不回退。

- **症状**：她反馈 hook 有概率失效——熄屏一段时间，开屏就失效了（互传又变回 10 分钟自动关）。
- **证据**：她 22:28 导出的 LSPosed 日志里，hook 全天只装过两次（19:08、22:27），都是 installed=true/true、精确定位成功、无任何报错。主进程每次装载都没问题，失效只可能发生在没被 hook 覆盖到的进程里。
- **嫌疑与改法**：0.4.50 的 C13 把 hook 收窄成“只装互传主进程、子进程跳过 DexKit”。管自动关闭的那部分如果有时跑在互传的子进程里，vc3 就漏了它——vc2 是全进程覆盖、当时真机验过可用。1.3 撤销这条主进程限制：凡包名 com.coloros.oshare 的进程（主进程和任何 :子进程）都装，回到 vc2 的覆盖面。S6 精确签名、C12 多 dex、C14 每方法单独 try/catch 全部保留不回退。
- **取证加强**：每次 handleLoadPackage 命中 com.coloros.oshare，先打一行 `OShareHook: load: process=<进程名>`（在装 hook 之前打，子进程也有痕迹），installed 行保留并带 process=。再失效时导一份 LSPosed 日志，就能看清是哪个进程在管自动关闭。

harness：T98k badging 跟 1.3/vc4、T98d 已装版本号跟 4、T101h 的 C13 静态断言反转（断言源码里无主进程限制、且有 load: process= 取证行）、HOOK_APK_VC 期望跟 4、T40f 版本跟到 0.4.51/vc55。全量 1243/1243，zip 复跑 160/160。

下一步：装 0.4.51 → 重启 → hook 自动升到 1.3/vc4（LSPosed 里不用重新勾）→ 正常用，熄屏久置后开屏看互传是否还开着；手机单独装 your_files 里的 oshare-hook-1.3.apk 升同样的 1.3。若再失效，导出 LSPosed 日志发我，load 行能定位问题进程。

## 0.4.50 更新（2026-11-19，0.4.49 代码审查 23 项全修）

对 0.4.49 做了一次全量审查（报告在目标目录 agent_notes/code-review-0.4.49.md），2 必须修 + 6 应该修 + 15 可以改，共 23 项，本版全修：

- **M1** 建临时文件的“冒号+重定向”写法全仓 10 处统一改 `printf '' >`：`:` 是特殊内建命令，重定向失败时 dash 整个进程直接退出，写的 `||`/`if` 兜底全是死的（安装中途死会跳过配置备份回写、watch 里那处会让 watch 静默死亡）。
- **M2** uninstall.sh 补删 /data/adb 的配置主备份（0.4.45 新增、卸载清单漏了它），否则卸载重装旧配置全套复活；顺带删日志目录标记文件。
- **S1** service.sh 开机四步失败时记的退出码恒为 0 的问题修了：命令跑完立刻存 rc 再判，临时文件从 `${TMPDIR:-/tmp}` 换到 /data/local/tmp。
- **S2** 面板每 2 秒轮询经子进程 thread.sh 往调度日志灌的 2 行拓扑噪音没了：panel 调 fg/gamedetect 时用 env 把 DETECT_QUIET/SCHED_LOG_QUIET 显式传给子进程。
- **S3** 面板 GPU 频率显示单位修对：fmtHz 改按 Hz 分档，366 MHz 不再显示成“366.00 GHz”。
- **S4** thread.sh 的 STATEFILE 锁补残留自愈（和 zram/thermal 同款：holder 已死或锁超 5 分钟清掉重拿），持锁进程被杀后不再每次白等约 10 秒。
- **S5** 进游戏自动去温控失败后同一局内会补重试了：watch 游戏保持分支里状态文件还没出现时每 60 秒补调一次 thermal_auto_on，成功即止。
- **S6 + hook 升 1.2/vc3** “互传常开”hook 收紧：Hook A 只认精确签名 (Context, long|Long)，找不到不再拿任意方法兜底乱改参数；timeParamIndex 找不到 long 参数返回 -1 不改参数。另含 C12 多 dex 兜底扫描、C13 子进程跳过 DexKit、C14 每方法单独 try/catch、C10 build.sh 校验 HOOK_APK_VC 与清单一致并自动拷进模块、C11 签名口令移出脚本（环境变量或本地 .keystore-pass 文件）。libdexkit.so 仍是 Stored 不压缩 + zipalign（T98l 继续守）。
- **C1** panel set_value 加配置锁（mkdir + 残留自愈），两个 panel 进程同时改不同 key 不再互相覆盖丢设置。
- **C2** customize.sh 回写配置备份失败不再静默，ui_print 告警。
- **C3** customize.sh 的日志路径提示和 lib.sh 实际解析对齐：子文件夹被同名文件挡住时会回落，提示跟着报 /data/local/tmp，不再指错地方。
- **C4** 日志目录解析变粘性：解析结果落标记文件（/data/local/tmp/oneplus_sched_logdir），开机早期回落和后续进程走内部存储文件夹的“日志劈两处”没了。
- **C5** 日志文件夹/文件权限收紧一档：文件夹 1777（加 sticky 位，别的应用不能删/改名日志）、日志文件 0644（所有人可读、只有 root 能写）；文件管理器打开看不受影响。
- **C6** 删死代码 state_set。**C7** 删 game_sched.sh/thread.sh 里两份与 lib.sh 正版判据不一致的 verify 兜底，缺函数直接报错。**C8** 4 个文件头过时的日志路径注释更新。**C9** prio 的 nice 值校验只认 `-?[0-9]+`，`--5` 不再放过。**C15** panel 开去温控部分成功又失败时，除回滚配置外补跑 thermal.sh off 卸掉已生效的那半（原本就是手动常开的不拆）。

harness：新增 T101 回归段（M1 全仓静态断言、M2 卸载行为、S1 抽函数单测、S2 status 后日志无拓扑噪音、S3 fmtHz 静态+node 行为、S4 残留锁自愈行为、S5 保持分支补调静态、C1 残留配置锁自愈、C2/C3 customize 行为、C4 标记粘性行为、hook 源码静态断言、C9 prio 行为）；T40f 版本跟到 0.4.50/vc54，T98d/T98k 跟 hook 1.2/vc3，T100b/T100c 权限期望跟 C5 改 1777/0644，T70f 计数跟 S2 改 4，T72b 改用同构本地写函数（state_set 已删）。全量 1242/1242，zip 复跑 160/160。

下一步：装 0.4.50 → 重启 → 面板状态卡看 GPU 下限应显示 366 MHz（不再是 GHz）；互传 hook 会自动升到 1.2/vc3（LSPosed 里不用重新勾）；其余都是内部健壮性修复，手感应无变化。

## 0.4.49 更新（2026-11-19，去掉 tab 整页淡入修切换卡顿）

只改一处：0.4.48 给 pane 切换加的整页 180ms 淡入，她真机反馈“切换还是有卡顿感”。卡顿源就是这个淡入——动画加在整个 pane（几百个节点的卡片子树）上，WebView 每帧要重绘这个巨型图层；showTab 里为了让动画重播还有一句 `void pane.offsetWidth` 强制同步回流，正卡在点击那一帧。已删：`.tabpane.pane-in` 规则、`@keyframes paneIn`、showTab 里加/删 class 加强制回流那三行。切页恢复 0.4.44 那样纯 display 显隐、点下立刻出；胶囊里的滑动高亮（`.thumb`，transform 250ms ease）和 tab 文字颜色过渡一字未动，切换仍有滑动感。其他区域、logcat chip 的小过渡、所有逻辑都不动。

harness：T100a 的淡入期望翻成负向断言（showTab 无 pane-in、无 offsetWidth；全文无 pane-in / paneIn / translateY(4px)），滑动高亮的检查保留，T40f 版本跟到 0.4.49/vc53。全量 1196/1196，zip 复跑 160/160。

下一步：装 0.4.49 → 在调度/功能之间来回切，应该是点下立刻出、只剩胶囊里的高亮在滑，没有顿感。

## 0.4.48 更新（2026-11-19，tab 胶囊按红线改宽 + 切换滑动动画；日志挪进内部存储“调度器日志”文件夹）

三件事，都是她提的：

1. **tab 胶囊改宽**（她在面板截图上画了两条红线定宽度：左线约在屏宽 35%、右线约在 67.6%，即居中、宽约占屏 33%）：`.tabs` 改成 `width:33%` + `min-width:240px` 防窄屏挤压，去掉 0.4.45 的 `width:max-content` hug；两个 tab 改回 `flex:1` 均分填满。胶囊其余样式不变（居中 left:50% + translateX(-50%)、离底 12px、圆角 24px、细边框、分层阴影、gap 4px、padding 6px、tab 高 36px、字号 14px），内容底边距/toast 高度维持。
2. **切换动画顺滑一点**：选中态不再靠每个按钮自己变背景色（瞬间跳），改成胶囊里一块绝对定位的滑动高亮（`.thumb`，小米蓝药丸，宽 = 半个胶囊内宽），点 tab 时 `transform: translateX` 250ms ease 在两个位置间滑，文字颜色随选中态 250ms 过渡；pane 切换加 180ms 淡入（`paneIn`：opacity 0→1 + translateY 4px→0，重播前先摘 class 强制重排再加回，连点从头播不排队）。动画只用 opacity/transform，不触发布局重排；高亮块位置只由当前选中 tab 决定，动画中途连点直接改目标、不会错位；showTab 仍是纯 display 显隐、不拉数据，状态切换/2 秒轮询/withBusy 逻辑全不变。
3. **日志挪到内部存储的“调度器日志”文件夹**（她：放 /storage/emulated/0/ 方便找，又补充要自动建一个文件夹别散放）：4 个分类日志（调度日志.log / 温控日志.log / 内存日志.log / 诊断日志.log，文件名不变）改写到 `/data/media/0/调度器日志/`（文件管理器里就是 `/storage/emulated/0/调度器日志/`）。日志目录解析仍收敛在 lib.sh 一处：显式覆盖 → SCHED_TEST_ROOT（测试） → /data/media/0 可写时用它的“调度器日志”子文件夹（不存在就 mkdir -p 自动建、文件夹 chmod 0777、日志文件新建/轮转后 chmod 0666，她用文件管理器能进能打开）→ 子文件夹建不了/写不了或 /data/media 还没就绪（post-fs-data 极早期）时回落 `/data/local/tmp` 平铺（回落目录里不再建子文件夹）。service.sh 的 watch 重定向改走 lib.sh 的 LOGFILE、post-fs-data 的失败行改 source lib.sh 用同一解析、panel.sh log/clearlog 本来就走 sched_log_file 自动跟随、customize.sh 安装提示按同一套解析打印（media 时显示 /storage/emulated/0/调度器日志）。只挪日志：状态文件、pid、uclamp 原值、配置备份位置一律不动；/data/local/tmp 里已有的旧日志不删不搬，新日志从新位置开始写。

harness：T92a/T95a 的胶囊几何期望按 33%/flex:1 更新（T89a 高亮改验滑动高亮块）；新增 T100（胶囊 width:33% 且居中、min-width、tab flex:1、高亮块 CSS + tabThumb 元素 + showTab 挪高亮/加淡入、paneIn 关键帧；日志目录解析五分支——测试根/media 子文件夹/自动建文件夹 + 权限 0777/media 不存在回落/子文件夹被占建不了回落/显式覆盖优先、分类文件跟随子文件夹、新建日志 0666、panel log 读解析后目录、service/post-fs-data/customize/WebUI 接线）。全量 1195/1195，zip 复跑 160/160。

下一步：装 0.4.48 → 重启 → 看 tab 胶囊宽度是不是红线那个宽、切换有没有滑动感；打开文件管理器，内部存储根目录下应有“调度器日志”文件夹，4 个日志在里面、能直接打开。

## 0.4.47 更新（2026-11-19，删互传开关/日志分类 + 面板打开提速 + hook APK 修打包、加推荐作用域）

四件事：

1. **删面板互传开关 + 互传日志分类 + watch 补开**（她拍板：“把面板互传开关去掉”“包括日志”）。旧的那套（0.4.40 的 watch 每 5 秒 am 补开）真机已证伪、从来没成过，留着只是白试。删完：WebUI 功能页互传区只剩“互传诊断”按钮和 hook APK 状态行；日志 pill 从 5 个减到 4 个（调度/温控/内存/诊断）；`panel.sh oshare on|off` 删除（再传进来退出 2 报 ERR，不静默成功），只剩只读 `oshare status`；watch 不再读 `OSHARE_ALWAYS_ON`、不再碰互传；`oshare.sh` 只剩 status（on 明确报“已移除”）；lib.sh 日志分类去掉 oshare，`oshare_hook.sh ensure` 的安装结果改记调度日志。设备上已有的 `/data/local/tmp/互传日志.log` 不删（那是她机器上的文件），只是不再写、面板不再显示。配置键 `OSHARE_ALWAYS_ON` 按“只新增、不删”的规矩留在 config.conf 里，注释标了已退役，从此没代码读它。互传诊断按钮不动（走 oshare_diag.sh，写诊断日志）。
2. **面板打开提速**（她：“面板每次点进去他读取配置有点慢”）。审计入口路径：打开时同步走 probeHost（log 0）→ `panel.sh state`（fast 状态 + 配置）→ 后台再补完整 status 和 zram。慢的外部调用全在完整 status 里：前台识别的 dumpsys、温控区逐个扫描、还有 0.4.46 新增的 hook_apk 包查询（dumpsys package，秒级）。前两项本来就只在后台完整 status 里，没动；hook_apk 改成看数据目录在不在（`[ -d /data/data/com.nora.osharehook ]`，装过系统就建这个目录，状态行只需要“装没装”），瞬时完成，并入 fast 状态——首屏和每 2 秒轮询直接带 hook_apk，不用再等完整 status 补这一项，完整 status 也少了一次包查询。入口同步路径（state/fast）里没有任何 dumpsys/pm 调用（harness T99e 静态验了 cmd_status 快路段和 _hook_apk_state 函数体）。service.sh 的 ensure 版本比较仍用 dumpsys/pm（开机时跑，不影响面板），没动。外观、行为、2 秒轮询、tab 纯显隐都不变。
3. **hook APK 升 1.1 / vc2，加 LSPosed 推荐作用域**：清单加 `xposedscope` 元数据指向 `@array/xposed_scope`（只含 com.coloros.oshare），她在 LSPosed 里启用“互传常开”时作用域会推荐/预勾一加互传，不用翻列表找。版本号必须升：ensure 按 versionCode 比较决定装不装，不升的话已装 vc1 的机器不会更新。
4. **修 hook 完全没生效的根因（真机复现，优先级最高）**：她 18:49 发的 LSPosed 日志显示模块已启用、作用域正确、代码进了互传进程，但 `loadLibrary(dexkit) failed: couldn't find "libdexkit.so"`、两个 hook 都是 false。根因是 0.4.46 的 APK 里 lib/arm64-v8a/libdexkit.so 被压缩存储（Defl:N，53%）——APK 以 extractNativeLibs=false 方式从 `base.apk!/lib/arm64-v8a` 直接 dlopen，要求 .so 必须 Stored 不压缩 + 页对齐，压缩了就加载不出来，DexKit 起不来。修法：build.sh 打包时 .so 单独用 `zip -0`（Stored）存入，zipalign 带 `-p` 做 4096 页对齐；构建后自验 `unzip -v` 里 libdexkit.so 的 Method 是 Stored、`zipalign -c -p -v 4` 通过（都验过）。harness 新增 T98l 守这条，压缩即 FAIL。

harness：新增 T99（19 项：WebUI 无开关/无 on-off 调用/无互传 chip、thread.sh 无 oshare 引用、panel oshare on 退出 2、ensure 日志走主分类、快路径纯净、hook_apk 目录查法、state 直接带 hook_apk）和 T98 ⑤⑥（APK 1.1/vc2、xposedscope、作用域数组、libdexkit.so Stored）；T88/T89/T91/T93/T95/T98 里摸到旧行为的期望全部更新（on/补开改成已移除的负向断言、chip 5→4、hook 日志改调度日志、vc1→vc2、fast 带 hook_apk），删 T88b/c、T91a、T95d 组和整个 T96（测的都是已删行为），T40f/T79a 跟版本和开关数更新。全量 1155/1155，zip 复跑 160/160。

下一步：装 0.4.47 → 重启（ensure 会把 hook APK 从 vc1 更新到 vc2）→ LSPosed 里启用“互传常开”（1.1 带推荐作用域，确认一加互传已勾）→ 再重启 → 开互传等 10 分钟以上看还关不关；LSPosed 日志里这次应有 OShareHook 的 hookA/hookB ok（DexKit 能起来了）。

## 0.4.46 更新（2026-11-19，互传常开改走 LSPosed hook：自写最小模块集成进调度模块）

她拍板走自写 hook 这条（网查结论：LuckyTool 的「移除互传关闭倒计时」证据最硬，hook 点是公开的定位方法）。这版把一个自写的最小 LSPosed 模块集成进调度模块，一个 zip 交付：

1. **hook 模块本体**（新工程 `~/workspace/oshare-hook/`）：包名 `com.nora.osharehook`，应用名“互传常开”，versionName 1.0 / versionCode 1。入口只处理 `com.coloros.oshare`，包名不符直接返回。两个 hook（定位字符串来自 LuckyTool 现行公开源码，实现自己写）：A. DexKit 在含 `"SpUtils"`/`"share_config"` 字符串的类里定位同时含 `"updateLastTurnOnTime"`/`"key_last_turn_on_time"` 的方法，before hook 把 long 时间参数改成 0；B. DexKit 定位 `OShareFeatureConfig.getSwitchTimeOut`（参数 Context、返回 long/int），返回值恒为 0。DexKit 找不到时退到按类名扫 dex 的兜底反射 hook；全程 try/catch，失败只用 XposedBridge.log 记 `OShareHook` 标签日志，绝不让互传崩。标准 Xposed 元数据齐全（xposedmodule / xposeddescription / xposedminversion=53，assets/xposed_init 指向入口类）；DexKit 用官方 2.0.7 AAR，arm64 的 libdexkit.so 随 APK 打包。构建不用 Gradle：javac + d8 + aapt2 手工打包，zipalign + 本地 keystore 签名（keystore 在 oshare-hook 工程下，不进模块 zip）。
2. **集成**：APK 放在模块 `oshare/oshare-hook.apk` 随 zip 走；`service.sh` 开机调新脚本 `sched/oshare_hook.sh ensure`——没装或已装 versionCode 低于内置 APK（当前 1）就 `pm install -r`，结果记互传日志，装失败只记日志不影响开机其他流程，APK 不存在整段跳过，已是最新什么都不做（幂等）。`panel.sh oshare status` 和完整 `status` 多带一个字段 `hook_apk=1/0`（fast 状态不带，2 秒轮询不加 dumpsys 调用）；WebUI 功能页互传区多一行小字显示 hook APK 装没装（读 hook_apk 字段，没字段就不显示）。`customize.sh` 安装输出多一行提醒：hook 需在 LSPosed 里启用“互传常开”、作用域勾“一加互传”、再重启一次。
3. **没动的**：0.4.45 定下来的两页 tab、配置备份三重来源、日志分类、旧的互传 am 补开逻辑（watch 轮询 + oshare.sh on）全部原样保留——hook 是多加的一条根因路，am 补开留作没装 LSPosed 时的兜底。

前提：平板要有 LSPosed（有没有仍未确认），且要手动启用模块 + 勾作用域 + 重启一次，hook 才生效；生效后互传开一次就一直开着。harness 新增 T98（25 个检查点：zip/源码树里有 APK、classes.dex/AndroidManifest/assets/xposed_init/libdexkit.so 体检、xposed_init 内容、service.sh 接线、customize 提醒、打桩 pm/dumpsys 验 ensure 的未装→install / 已装→不调 / 无 APK→跳过 / install 失败→记 FAIL 仍返回 0、panel oshare status 与完整 status 的 hook_apk、fast 不带、WebUI 状态行）；T88e 两条 status 精确匹配改看第一行（status 多了 hook_apk 行）；T40f 版本期望改成 0.4.46 / vc 50。全量 1173/1173，zip 复跑 160/160。

下一步：装 0.4.46 → 重启（开机自动装 hook APK，互传日志里应有 “OK oshare-hook”）→ 确认平板上有 LSPosed、启用“互传常开”并勾一加互传作用域 → 再重启 → 开互传等 10 分钟以上看还关不关（LSPosed 日志里应有 OShareHook 的 hookA/hookB ok 记录）。

## 0.4.45 更新（2026-11-19，升级不再丢配置：备份换到 /data/adb + 三重来源恢复 + 合并完回写；tab 栏胶囊改小）

两件事：

1. **升级丢配置修好**：0.4.44 安装时输出“未找到旧配置备份，将使用默认配置”，zram lz4 24GB、互传常开等设置全回了默认——备份只放在 /data/local/tmp，那个位置的备份在真机上丢失过（模块自己的代码从不删它，但只剩它一个不够稳）。这版改三处：(a) `lib.sh` 的 backup_config 主备份换到 `/data/adb/oneplus_sched_config.bak`，每次保存主、旧（/data/local/tmp）两个位置都写、都 chmod 600（测试环境仍只写测试路径）；(b) `customize.sh` 恢复来源按优先级取第一个存在的：① 主备份、② 旧备份、③ 旧模块自己的 `sched/config.conf`（升级安装时旧模块目录还在；和本次新 config.conf 是同一个文件时跳过，别自己合并自己），安装输出会打出实际用的来源，合并校验沿用 0.4.42 修好的那套（带引号列表值、$VAR 引用能过，危险值照样丢）；(c) 合并完把最终 config.conf 回写到主、旧两个备份位置，保证每次装完备份必定存在。这样就算备份再丢，还有旧模块配置兜底，升级不会再回默认。
2. **tab 栏胶囊改小**（她 17:30 提的：“做那么大干嘛”）：两页 tab 后胶囊还占满整行、两个按钮撑得巨大，改成紧凑居中版——胶囊 hug 内容（`left:50%` + `translateX(-50%)` 居中、`width:max-content` 按内容撑），横向 padding 10px→6px、圆角 28px→24px；tab 不再 flex:1（flex:none、padding 8px 20px、min-height 40px→36px、字号 15px→14px）；0.4.44 的精致化（细边框、分层柔和阴影、过渡、未选中次要文字色、选中蓝底白字 600）都保留；内容底边距 136px→84px、toast 112px→76px 跟着新栏高收小。切换仍是纯 CSS 显隐、瞬间完成、不卡顿。

harness：新增 T97（三重来源：主备份/旧备份/旧模块配置、全缺走默认+警告、主优先于旧、同文件跳过、装完回写两处且主备份权限 600、旧模块配置里的分号/反引号危险值照样被丢而带引号列表值和 $VAR 引用能恢复、backup_config 生产路径主旧两处 + 测试环境只写测试路径）；T92a/T94a 的撑满几何期望按居中紧凑更新（居中 left:50%+translateX(-50%)、width:max-content、圆角 24px、栏高公式 36+6+6、内容底边距下限 72px）；T95a 的尺寸期望按紧凑值更新（胶囊 padding 6px、tab 高 36px、flex:none、padding 8px 20px、字号 14px）；T40f 版本期望改成 0.4.45 / vc 49。全量 1148/1148，zip 复跑 160/160。

下一步：装 0.4.45，安装输出应打出“已恢复上个版本的配置（来源：…）”——她现在 0.4.44 里的配置会被旧模块配置兜底带过来，不再回默认；装完在面板里随便改一个设置，备份就落到 /data/adb 了。再看 tab 胶囊大小顺不顺眼。互传常开打开后等 10 分钟以上的验收、0.4.38 的 uclamp 验收仍待她真机验。

## 0.4.44 更新（2026-11-19，tab 栏只留两页 + 精致化、日志选择改 pill、互传诊断补强、互传开关失败不回滚）

四件事，都是她刚提的：

1. **tab 栏只留调度/功能两个切换页**（她 17:01 定的最终结构，覆盖 0.4.41 的 5 个 tab）：调度页 = “当前状态”卡（实时状态、2 秒刷新，原来常驻顶部，现在移进调度页，切到功能页时跟着藏起来——实时状态只在调度页有）+ 一键模式 + 跟随卡；功能页 = 温控、内存（zram 卡原样）、互传、日志四个区上下叠着，各带各的小标题。tab 栏还是底部悬浮胶囊（位置、圆角不动），只剩两个按钮。切换仍是纯 CSS 显隐、瞬间完成、不重新拉状态；showTab 按 data-tab 通用，跟着新结构走；默认打开调度页。控件 id 和 handler 一个没动，只是挪了位置。
2. **tab 栏精致化 + 文字间距收小**（她 16:57 提的）：胶囊加一层细边框（`var(--line)`，深色模式也看得见）、阴影改柔和分层（`0 4px 16px rgba(0,0,0,.12), 0 1px 4px rgba(0,0,0,.08)`）；tab 加过渡（background/color .15s ease），未选中用次要文字色 + 字重 500，选中小米蓝底白字 + 字重 600；tab 高 44px→40px。文字间距收小：胶囊 gap 8px→4px、tab 横向 padding 4px→2px、胶囊横向 padding 14px→10px；不加 letter-spacing、不改字号。
3. **日志选择器改 pill**：日志区（现在在功能页里）原来的下拉换成一排 5 个分段小 pill（调度/互传/温控/内存/诊断，沿用 tab 的 pill 语言：选中小米蓝底白字、未选中透明底次要文字色），点 chip 就切类别并立即刷一次该类日志；“查看日志”“清空日志”按钮保留；日志仍显示在输出框里；类别键内部仍是英文（sched|oshare|thermal|zram|diag），中文不进 exec 桥；`selLogCat` 已删干净。切换仍是瞬间完成、不重渲染整张卡。
4. **互传诊断补强 + 开关失败不回滚**：跟进她 16:53 发的两份日志——0.4.42 的互传修复真机还是没成：16:50:53 deadline 刷新成功（OK …853000），am 也发出去了（Starting service），但 2 秒后服务还是不在；诊断里 16:51:59 在跑的那个服务是应用自己起的（mCallingUid=10124，创建时间 16:51:48，应用自己写的时间戳 1795078907795 带毫秒）——是她手动点的磁贴，不是模块补开的；OshareStateReceiver 在 pm-dump 里下面没有任何 Action 行，广播这条路走不通；另有 16:40:28 一次 am 返回 rc=255，但 0.4.42 只记了 am 输出第一行，真报错被截掉了。这版改两处：(C) `oshare.sh` 起服务后查两次——am 一返回立刻查一次（不等），再按原有的等 2 秒查一次，两次结果都记进日志（“起服务后即刻：有/无；2秒后：有/无”），分清“根本起不来”还是“起来又被停”；am 输出记全（多行用 ` / ` 拼成一行、截断到 300 字符，不再只取第一行）；不加额外的等待，watch 5 秒一轮不受影响。(D) `panel.sh` oshare on 起服务失败**不再回滚**配置——根因：她 16:40 和 16:50 两次点开都失败回滚，OSHARE_ALWAYS_ON 一直是 0，开关一直是关的，watch 永远不重试，所以 10 分钟一到还是关。现在失败也保持 1，报 WARN，watch 按现有的 60 秒抑制继续重试；off 行为不变（只关自动补开，不关互传本身）。

harness：T89/T92c/T94c 的 5-tab 期望按两页结构更新（状态卡改判在调度 pane 内、功能 pane 默认隐藏数 4→1、TAB_NAMES 改 2 个）；T92a 阴影期望按新阴影更新、tab 栏位置检查改成“不在 main 里”；T93e 选择器期望改成 chip；T88e2 回滚期望改成不回滚（WARN + 配置保持 1）；T87g/T88h 的 pane 范围改到功能页；新增 T95（A/B/C：tab 精致化 CSS 数值、两页结构、日志 pill、互传诊断两次检查 + 多行 am 输出三个场景）和 T96（D：on 失败配置和备份都保持 1、watch 60 秒抑制后真重试）；T40f 版本期望改成 0.4.44 / vc 48。全量 1121/1121，zip 复跑 160/160。

下一步：装 0.4.44，看 tab 栏两页切换和精致度、日志 pill 切换顺不顺；互传常开打开后等 10 分钟以上，看互传日志.log 里两次检查的结果和 am 全输出——这次能分清服务到底是起不来还是起来又被停。0.4.42 的其余验收（配置恢复不丢弃、日志分文件）和 0.4.38 的 uclamp 验收仍待她真机验。

## 0.4.43 更新（2026-11-19，tab 栏改悬浮胶囊）

只改 tab 栏外观，功能逻辑一个字没动：她发了一张别的 App 底部栏参考图，说“tab栏做成悬浮的，而不是紧贴下面”。0.4.42 的 tab 栏是 `position: fixed; bottom: 0` 全宽贴底；0.4.43 改成悬浮胶囊——左右各留 16px、离底边 12px、圆角 28px、四周阴影（`0 8px 24px`），背景还是 MIUIX 卡片色（深色模式也正常）。页面内容底边距 120px→136px（栏高约 64px + 底部空隙 12px + 余量），最后一张卡不会被挡住；toast 从 92px 抬到 112px，在悬浮栏顶沿之上。5 个 tab、id、handler、纯 display 瞬间切换都不变。只改 webroot/index.html。

harness：T92 的旧期望按新样式更新（贴底/全宽/120px/92px → 12px/16px/136px/112px，+1 个圆角检查）；新增 T94（悬浮胶囊：15 个检查点——bottom/left/right 用算术比较验 > 0、圆角 ≥ 24px、四周阴影、卡片底色、底边距 ≥ 96px、toast 在栏顶沿之上、5 个 tab 齐全、showTab 仍是纯 display 切换且无命令调用、JS 语法 node --check）；T40f 版本期望改成 0.4.43 / vc 47。全量 1070/1070，zip 复跑 160/160。

下一步：装 0.4.43，看 tab 栏是不是悬浮胶囊的样子、切换还顺不顺。0.4.42 的其余验收（互传常开、配置恢复、日志分类）仍待她真机验。

## 0.4.42 更新（2026-11-19，配置恢复误杀 + 互传常开重试 + 底部悬浮 tab 栏 + 日志分文件）

四件事，全是她刚提的：

1. **配置恢复误杀修好**：每次安装都丢 PEACE_PACKAGES、VALORANT_PACKAGES、AUTO_GAME_PACKAGES、GAME_CLEAN_WHITELIST，报“值含危险字符”。根因：config.conf 里这 4 个值存的时候带双引号，AUTO_GAME_PACKAGES 里还有 `$PEACE_PACKAGES $VALORANT_PACKAGES` 引用；customize.sh 合并时把备份整行（含引号）拿去过 `_cfg_bad_chars`，`"` 和 `$` 都在危险字符集里，于是每次都误杀。修法：合并前先剥掉备份值首尾一对双引号再校验（通过后写回的还是备份原行）；`$` 从危险字符集里拿掉（命令替换必须靠 `(` 或反引号，这两个还在集里拦着，光秃秃的 `$VAR` 展开无害）；包名列表的字符集加上 `$`。安全没弱：`$(`、反引号、`;`、`&`、`|`、`"`、`'` 还是拦。实际没丢过东西（默认值和她的值一样），但她以后改了这 4 个值的话，升级再也不会丢。dash 坑：`$` 不能直接放进 case pattern 的 `[...]` 里（`$x` 会被当成参数展开、`$-` 是 shell 标志、`$ ` 会把 pattern 拆成两个词），要写成 `\$\ `（`\$` 转义 dollar、`\ ` 转义空格）。
2. **互传常开重试（0.4.40 真机失败的修法）**：10 分钟自动关后，watch 每次补开都 FAIL（am 返回 0 但服务 2 秒后查不到）。最可能的原因是应用自己立刻又把它停了：`key_last_turn_on_time` 是“开到什么时候”的 deadline（= 开机时间 + 600 秒），过期后应用内存里还记着过期值。0.4.42 的 `on` 先做三件事：把 share_config.xml 里的 `key_last_turn_on_time` 刷新成（现在 + 600 秒）的毫秒值（字符串拼 "000"，不用乘法，32 位 shell 乘 1000 会溢出；写回用 cat > 原地写，不换 inode、不改属主，sed -i 会新建文件、属主变 root）；杀掉互传进程（`am kill`），让它重起时重新读 XML 里的新 deadline；再 `am start-service` 起服务，等 2 秒验证。am 的 stdout+stderr 抓出来记进日志（0.4.40 丢到 /dev/null，查不到原因）。60 秒重试抑制保留。oshare-diag 再补一节：OshareStateReceiver 的完整 intent-filter Action 行（以后万一要走广播路线用）。
3. **tab 栏改到底部悬浮**：从状态卡下面移到页面最底下，`position: fixed; bottom: 0`，全宽、带顶阴影、MIUIX 卡片底色。点 tab 还是瞬间显隐、不重新拉状态、不卡顿；状态卡还在最上面；页面内容加底边距（120px），最后一张卡不会被悬浮栏挡住；toast 抬到栏上面（bottom: 92px）。5 个 tab 不变，默认调度。只改 webroot/index.html。
4. **日志按类别分文件，文件名直接用中文**：原来所有日志都在 `/data/local/tmp/oneplus_sched.log`。现在拆成 5 个（都在 `/data/local/tmp/` 下）：调度日志.log（主：调度/线程/游戏/模式）、互传日志.log、温控日志.log、内存日志.log、诊断日志.log（uclamp-diag、oshare-diag）。`sched_log` 按 `SCHED_LOG_CAT` 路由（oshare.sh、thermal.sh、zram.sh、两个 diag 脚本传自己的类别；调度主流程不传，走默认主文件）；每个文件各自轮转（同样 1MB / 4000 行）。面板日志卡加一个选择器切文件（调度/互传/温控/内存/诊断，默认调度），切类别时自动刷一次；`panel.sh log [CAT] [N]` / `clearlog [CAT]` 接类别参数，类别键还是英文（sched/oshare/thermal/zram/diag），中文文件名只在脚本内部映射，不经过 WebUI 的 exec 桥。service.sh 里 watch 的重定向、customize.sh 安装提示、uninstall.sh、post-fs-data.sh 的日志路径都同步改成中文名。调度、zram、thermal、uclamp、哨兵、save/restore 的逻辑一个字没动。

harness 新增 T90（配置恢复：21 个检查点）、T91（互传 on：16 个）、T92（底部 tab 栏：13 个）、T93（日志分文件：37 个）；T40f 版本期望改成 0.4.42 / vc 46；T32/T34/T35/T42/T43/T59/T61/T62/T64d/T85/T87/T88 里读日志的检查按新文件名改（主日志改调度日志.log，zram→内存日志.log，thermal→温控日志.log，diag→诊断日志.log，oshare→互传日志.log；T88f2“默认关时主日志里没 oshare”故意留在主文件，验证的就是分流本身）。全量 1054/1054，zip 复跑 160/160。

下一步：装 0.4.42，(a) 安装时不再报那 4 个键的“配置恢复已丢弃”；(b) 互传开关打开，等 10 分钟以上，看互传还在不在、互传日志里有没有 deadline 刷新 + 杀进程 + 起服务 OK；(c) tab 栏在底部悬浮、切换瞬间、最后一张卡没被挡住；(d) 各类日志进对文件。

## 0.4.41 更新（2026-11-19，面板 tab 栏 + 流畅性）

面板按功能分了 tab：调度 | 温控 | 内存 | 互传 | 日志，状态卡常驻最上面、每 2 秒照常刷新。调度是一键模式 + 跟随开关（游戏跟随、调度联动、自动检测、清理后台、开机自动跟随、立即绑定）；温控是去温控 + 进游戏自动去温控；内存是 zram 卡；互传是一加互传常开开关 + 互传诊断按钮；日志是日志卡 + uclamp 诊断按钮。默认打开调度 tab。

只改了 webroot/index.html 的布局，后端一个字没动（sched/*、panel.sh、配置、watch、oshare、uclamp、thermal、zram 全没动），所有控件 id 和 handler 不变，只是挪了位置。流畅性：切 tab 是纯 CSS 显隐（display 切换），不重新渲染、不重新拉状态、不做任何耗时操作；withBusy 不再禁用 tab 按钮，操作进行中也能瞬间切 tab，切 tab 也不会打断正在进行的操作；2 秒轮询还是只跑轻量的 refreshState，不跑 full status。harness 新增 T89（30 个检查点：tab 顺序和文字、每组卡的位置、默认调度 tab、状态卡在 tab 外面、全部旧控件和 handler 还在、JS 语法、showTab/pollTick 静态审计——切换里没有任何命令调用、轮询里没有重命令调用；另有两个旧期望跟着布局走：T87g 互传诊断按钮改成“在互传 tab 里”、T88h 互传常开开关改成“在互传 tab 里”）。

下一步：装 0.4.41，看 tab 切换顺不顺、互传常开开关还在不在。

## 0.4.40 更新（2026-11-19，一加互传常开）

0.4.39 的互传诊断她跑了两遍（2026-11-19 15:25），两次区别非常干净：关着时 `dumpsys activity services com.coloros.oshare` 是 `(nothing)`、一个服务都没在跑，share_config.xml 里 `key_last_turn_on_time` = 0；开着时 `OShareServer` 在跑（ServiceRecord，intent cmp=com.coloros.oshare/com.oplus.oshare.OShareServer），`key_last_turn_on_time` = 1795073731780（非 0，约等于开机时间 + 600 秒，就是 10 分钟自动关的 deadline）。互传版本 16.4.60（vc 160460）；系统设置里没有任何互传开关项。

定下来的两条命令：判断开没开——`dumpsys activity services com.coloros.oshare | grep -q OShareServer`，有 = 开着，没有 = 关了；无界面打开——`am start-service -n com.coloros.oshare/com.oplus.oshare.OShareServer`（开互传时应用自己就是走这条路起 OShareServer 的，起服务时应用自己会刷新 key_last_turn_on_time，跟点磁贴一个效果）。

新增 `sched/oshare.sh`（`status` 只读打印 on/off/unknown，`on` 起服务、等 ~2 秒再查一次确认、记 OK/FAIL）；配置 `OSHARE_ALWAYS_ON=0`（默认关）；`panel.sh` 加 `oshare on|off|status`（on/off 写配置 + 写备份、升级保留，on 还立即起一次服务，起失败回滚配置；off 只停自动补开，互传本身不会被关掉）；面板跟随卡加“一加互传常开”开关（接 panel.sh oshare on/off）；watch 每轮（5 秒）查一次，掉了就补开，只在真的补开时记日志，起失败 60 秒内不重试。调度、zram、thermal、uclamp（0.4.38 修法）、哨兵、save/restore 都没动。harness 新增 T88（状态分清开/关、on 起服务、am 失败、dumpsys 缺失、panel 开关 + 回滚、watch 补开/开着不动/默认关不查、WebUI 开关 + JS 语法）。

下一步：装 0.4.40，打开“一加互传常开”开关，等 10 分钟以上看互传还在不在，以此验收。

## 0.4.39 更新（2026-11-19，互传诊断版，只加诊断不改任何行为）

一加互传（com.coloros.oshare）每次传送都要手动开，因为官方行为是控制中心开后 5 分钟（新版 10 分钟）不用自动关。定案是 watch 轮询补开，但补开需要两条确切命令——“怎么判断互传开着”和“怎么无界面地打开它”——必须先在真机上诊断定下来（研究报告 agent_notes/oshare-always-on-20261119.md）。

新增 `sched/oshare_diag.sh`：全部只读，不改任何东西。记互传版本（dumpsys package 的 versionName/versionCode）、pm dump 过滤（只留 service/receiver/activity 段和 intent action——定“无界面打开”要用的 service 类名和 broadcast action）、当前状态（dumpsys activity services 看服务在不在跑、dumpsys wifi 的 p2p/direct 行、settings list global/secure 里 share/oshare 的项）、shared_prefs（ls + 各 xml 里 time/switch/enable 的行，看时间戳是不是存在文件里）。`panel.sh` 加 `oshare-diag` 命令（前台跑，几秒完成），面板日志卡旁加“互传诊断”按钮，点完弹“诊断已记入日志”。0.4.38 的 uclamp 修法、哨兵、save/restore、thermal、zram、调度逻辑都没动。harness 新增 T87（58 个检查点：开着/关着两种状态、命令缺失、应用不存在、shared_prefs 缺失/无 xml、panel 命令、WebUI 按钮 + JS 语法）。

下一步：装 0.4.39，互传开着点一次“互传诊断”、关着再点一次，两份日志都发来，对比出状态判断依据和打开命令，再做常开功能。

## 0.4.38 更新（2026-11-19，修 uclamp 写失败）

根因（0.4.37 诊断，2026-11-19 14:38 真机）：/dev/cpuctl 是唯一根，/sys/fs/cgroup/cpu 根本不存在；三组 min 全是 0.00，max 全是字面量 'max'（不限）；数字写 max 全失败（top-app max=1024、background max=512/256，全部 rc=1、stderr 为空），写回字符串 'max' 成功；min=0、min=77 写成功；top-app min=153 被拒。结论：这台内核的 max 只认 'max'，数字写不进去；top-app min=153 被拒。foreground min=77 可用，已是游戏档实际的提速项；后台收紧本就靠 cpuset 限在小核（0,1）上，不丢效果。

修法：不再写任何 uclamp.max、不再写 top-app min，只留 foreground min（游戏 77、性能 51、日常 0）。`apply_uclamp` 里强制拦截（max 一律改 -1、top-app 的 min 一律改 -1），调用点也改掉（性能/游戏/日常只写 foreground min）；配置键 BACKGROUND_UCLAMP_MAX / GAME_BACKGROUND_UCLAMP_MAX 保留备查，默认值改成 -1。拦截是必需的兜底：配置升级保留会留着旧的 512/256，光改调用点和默认值拦不住。哨兵（只验 foreground min + GPU）、save_uclamp_orig / 恢复循环（max 是 'max' 字符串、恢复循环按非数字静默跳过，本来就是对的）、诊断脚本、thermal、zram 都没动。harness 新增 T86（33 个检查点：真机同款夹具 min="0.00"、max="max"，进游戏/退游戏/切均衡全程零 uclamp FAIL，max 和 top-app min 一个都没写，foreground min 照写，恢复仍删原值文件、哨兵仍过，旧配置 512/256 也写不出去）；另更新 T12/T47/T49/T51/T53/T54/T67/T82/T84 里断言旧行为的期望。

## 0.4.37 更新（2026-11-19，uclamp 诊断版，只加诊断不改调度）

真机日志里 top-app min=153 / background max=256、512 两组写失败，前台 min=77、min=0、后台 min=0 都写成功，两个根（/dev/cpuctl 和 /sys/fs/cgroup/cpu）都失败——根因未定，先诊断再修，不猜修法。

新增 `sched/uclamp_diag.sh`：记三组（top-app / foreground / background）加根组本身、在两个根下的 min/max 权限和当前值；试写 6 项（top-app min=153、top-app max=1024、background max=512、background max=256、background min=0、foreground min=77 对照组），每写一次记退出码和 stderr；试写安全规则是先读原值、读不到/为空就不试写，写完无论成功失败都把原值写回去（恢复现场）；末尾记 dmesg 最后 20 行。`panel.sh` 加 `uclamp-diag` 命令（前台跑，几秒完成），面板日志卡旁加“uclamp 诊断”按钮，点完弹“诊断已记入日志”。哨兵逻辑、`_had_orig`、thermal、zram 都没动。harness 新增 T85（49 个检查点：缺文件记 SKIP、写失败记 rc/stderr、试写后原值写回、dmesg 读不到记 SKIP、目录占位、原值为空跳过、panel 命令）。

下一步：装 0.4.37，面板点“uclamp 诊断”，把日志发来，按诊断结果定修法。

## 0.4.36 更新（2026-11-17，修退游戏第一次恢复失败）

真机 2026-11-17：4 次退游戏里 3 次第一次恢复 FAIL（02:13:51、16:39:21、17:11:56；17:10:13 第一次就成功）。根因：这台内核把 uclamp 值报成浮点（"0.00"、"77.00"）。`save_uclamp_orig()` 进游戏前把当前 uclamp 原值存进原值文件，存的是 `cat` 读回的原样字符串，也就是 "0.00"；切回日常档时恢复循环的数字检查（`case "$_v" in ''|*[!0-9]*`）把带小数点的全当非法值跳过，原值一行都写不回去，也没记日志；同时 `_had_orig=1`，日常分支就不走兜底写 0，前台 uclamp.min 就卡在 77，`verify_game_restored` 正确报失败，FAIL、状态文件保留。原值文件又被删掉了（`_restore_fail=0` 就 `rm -f`），所以重试/下次退游戏时没原值文件了，直接写 0，就成功了——第一次总失败、第二次就好。

修法（只改 `apply_sched.sh` 两处，纵深防御）：`save_uclamp_orig()` 存值时把小数部分去掉（`${_v%%.*}`，和 lib.sh 哨兵的读回规范化同款），文件里只留整数；恢复循环读出来先去掉小数再做数字检查，旧版存的浮点原值文件也能正常恢复。哨兵逻辑、`_had_orig` 语义、thermal/zram 都没动。harness 新增 T84（34 个检查点：浮点原值文件恢复、存出来就是整数、完整退游戏第一次就成功、回归）。

## 0.4.35 更新（2026-11-17，`game` 命令不再报假成功）

0.4.34 审查时顺带发现：`thread.sh game` 命令总返回 0、总打印“调度模式已切到 game”，哪怕 apply_game_sched 的哨兵失败了也不透传——面板点“游戏”时 apply 失败了也会报成功。`game off` 也一样，restore 永远报“已切回”。

修法：`thread.sh game game` 在 apply_game_sched 返回非 0 时 exit 1 并打印“ERR 切游戏模式失败：哨兵验证未通过”，成功才报“已切到 game”；`game off` 在 restore_game_sched 返回非 0 时 exit 1 并打印“ERR 切回失败：游戏档数值未撤销”。restore 本来没有任何验证——这次补了一个反向验证 `verify_game_restored`（lib.sh 新加，thread.sh 和 game_sched.sh 各有兜底）：前台 uclamp.min 不再是 77 且 GPU min_freq 不再是游戏抬高值时才算撤销；任一项仍是游戏值、或哨兵节点读回非数字时 restore 失败，状态文件保留（它如实反映游戏档数值还在）、不关去温控（下次进游戏时 apply 会因状态已是 game 而直接返回，去温控必须保持开着）。注意和正向哨兵的区别：正向是“任一项不符就失败”（OR），反向是“两项都不是游戏值才算撤销”（AND）——只一项恢复了、另一项还卡着时 restore 就是没成功。`game_sched.sh off|balanced` 也合并成一个分支、同样验证并透传失败。watch 循环调 restore 时不看返回值（只看状态文件），所以这个改动不破坏 watch；但 watch 退游戏时只调一次 restore，失败不会重试，要靠日志 + 面板状态发现、手动再跑一次 game off。harness 新增 T83。

## 0.4.34 更新（2026-11-17，修 0.4.33 的哨兵回归）

0.4.33 刚装上，真机 01:16 那局和平精英就出问题了：新加的 M6 哨兵验证（verify_game_applied）每轮都失败，10 次“FAIL game sched apply 失败（哨兵验证未通过），下轮重试”。根因：哨兵要求 top-app uclamp.min 读回等于 153，但这台设备上 top-app 的写操作永远失败（两个根都写失败，读回 0.00），是已知内核限制、无帧数影响；foreground 的 77 能写成功、GPU min_freq=366000000 能写成功、cpuset 和绑核都正常。后果不只是刷 FAIL 日志：状态文件永远写不上，watch 每轮重试 apply，更重要的是去温控自动开永远不触发——01:16 整局 0 行 thermal on/off/fake，全程没去温控（0.4.32 的 23:18 那局是正常自动开的）。

修法：哨兵不再验 top-app uclamp.min，改成验前台 uclamp.min 读回等于 77（GAME_FOREGROUND_UCLAMP_MIN_PEACE）+ GPU min_freq 已抬高到游戏档期望值（当前 366000000），两项都通过才算成功、写状态文件、开自动去温控；任一项不通过仍记 FAIL、不写状态、下轮重试，M6“apply 真没生效时不撒谎”的本意不变。top-app/background 的写失败继续当 WARN 处理（S24 的“uclamp 写失败 2 组”汇总日志还在），不阻塞哨兵。另外补了两个细节：uclamp 读回可能是小数格式（真机 "77.00"），比较前先去掉小数点后面的部分；GPU 节点存在且可读时读回非数字也算 FAIL（不能静默跳过，否则节点被软链到只读文件时哨兵会空过——T48b 就是这个场景）。harness 新增 T82（哨兵新逻辑 4 组检查）。

## 0.4.33 更新（2026-11-16，全面代码审查 85 项全修）

她说“全面审查代码一遍”，审出 85 个问题（必须修 19、应该修 45、可优化 21），全部修了。最重的三个：

- 去温控开机挂两层：post-fs-data 挂一次、service 又挂一次，叠了两层；点“关闭”只卸一层，面板显示已关、实际还挂着。现在挂载前查 /proc/mounts，已挂就跳过；卸载循环到卸干净；挂载/伪装/关 horae 每步都记成功失败数，失败返回非 0，面板据此报错不再报假成功；status 逐项查 9 个文件（thermal_mounted_count=N/9）。
- 性能档切回均衡后 uclamp 下限泄漏：性能档把 top-app 下限抬到 102、foreground 抬到 51，但不存原值；切回均衡时因为没存过原值就不恢复，102/51 永久留在 sysfs 里。现在存原值的逻辑抽成函数，性能和游戏两个分支写之前都先调；切回均衡时无原值文件就把 min 显式写回 0。游戏档的 GPU 下限也一样：只在抬高过时才恢复，没抬高过不写最低 OPP。
- 重启后残留状态文件：平板在游戏中重启，状态文件还说“在游戏档”，但 sysfs 已回原厂，首局游戏 watch 看到状态文件就跳过应用，实际全程跑在均衡档。现在 service.sh 启动 watch 前删掉 4 个状态文件；watch 启动时也校验一次；游戏档写状态前回读哨兵节点验证（top-app uclamp.min 是否 153、GPU min_freq 是否抬高），失败不写状态、记 FAIL、下轮重试。

其他：zram/thermal 入口加 mkdir 原子锁（残留锁按 PID/mtime 清掉重拿）；zram 早返回分支补配置保存 + swap 检查、回滚按步验结果、中途被杀后 swap 能修复；配置合并按 key 类型白名单校验（恶意行丢弃 + 告警），备份文件 chmod 600；service/post-fs-data 用绝对路径，失败记日志；面板只读命令才允许 2500ms fallback、写命令绝不重发，启动时探测一次宿主形态并缓存；开关连点不再丢写；“立即绑定”按钮加回来了；配置开关文字可点；卸载会杀 watch、卸去温控、清 5 个残留文件。harness 648 个检查点全过（含新加的 T41–T80）。

待真机验证的 4 件（代码里无法自证）：emul_temp=0 是否被 OPlus 内核接受（退游戏后看各 zone temp 是否回真实值）、fake 白名单是否覆盖全部温控区（thermal_fake 启动时会把实际 zone 类型写进日志）、[ -gt ] 在设备 shell 下是否 32 位、内核是否提供 zstd。

## 0.4.32 更新（2026-11-16，面板提速）

她说面板点什么都卡、每次进面板白屏几秒。根因在启动流程：原来进面板先跑完整 `status`（要调 dumpsys，在 ColorOS 上常以秒计）再跑 `get`，两次 root 命令串行，值出来之前全是“—”。改成：

- 启动先走 fast `state`（一次调用同时拿状态 + 配置，不调 dumpsys），界面一秒内就有数；再并行刷 zram；前台识别和温度（完整版才有）随后在后台补一次，不挡首次显示。首刷失败也继续轮询。
- 模式/游戏按钮点下去先立刻改状态显示（乐观更新），再跑 root 命令；原来是等命令 + 刷新回来才改，点下去要 1 秒多才有反应。命令失败时随后那次刷新会把显示纠回来。
- 白屏本身还有一部分是 KernelSU 管理器启动 WebView 的冷启动，页面里改不了；改掉的是进面板后等数据那几秒。

## 0.4.31 更新（2026-11-16，watch 等 /system/bin 就绪）

她发来 18:59 的日志，里面有个新问题：两次开机时 watch 一启动就找不到 /system/bin 里的工具（printf、tr、date、sleep 全报 No such file or directory），一次开机刷了 2256 行报错。原因是开机早期 /system/bin 还没挂好，sleep 一失效 watch 就空转刷屏；等 /system 挂好自己恢复了，没影响打游戏（18:55 那局自动去温控、绑核都正常）。修法：watch 每轮开头先确认 date 能用——找不到就跳过本轮、不跑任何命令、不记报错，空循环等约 1 秒再试，只记一次“在等”；轮尾的 sleep 也加了兜底，失败就空循环等 1 秒。判断只用 shell 内置命令，不依赖 /system/bin。

- 第一版只认 `/system/bin/date`，结果模拟机上根本没有 /system，watch 全程被拦，T6/T7/T8/T18/T20/T26 全挂——改成认 `command -v date` 或 `/system/bin/date`，真机走 /system/bin，模拟机走 PATH 里的 date，两边都通用。SYSBIN_DATE 是测试用的覆盖，模拟“/system/bin 缺失”。
- 18:59 那局的自动关没在这份日志里：日志截在 18:59:05，退游戏恢复才刚开始，“thermal auto off”那行在恢复跑完之后才记。下份日志里看到那行就全通了。

## 0.4.30 更新（2026-11-16，进游戏自动去温控）

她说“能不能自动检测到游戏就开启”，做了：面板“跟随”卡里多了个“进游戏自动去温控”开关，默认开。不用再手动点了——

- 检测到游戏进游戏档那一刻，自动把去温控打开（挂 9 个替换文件 + 伪装温度 + 关 horae，和手动点“去温控”完全一样）。
- 游戏退了、切回基础档那一刻，自动关掉（卸挂载 + horae 写回 1 + 各温控区的 emul_temp 写回 0 恢复真实温度）。

规则两条，记清楚：

- 手动“去温控”开关开着时，自动逻辑全程不动它——手动开就是一直开，退游戏也不关。
- “进游戏自动去温控”开关关掉后不再自动开，但已经自动开过的那次，退游戏时照样自动关（关是把自动开的动作还原）。

两处不完美，实话说在前头：关的时候 `/proc/shell-temp` 恢复不了（它只记最后一次写的值，真实壳温读不到），重启后才彻底恢复——主力温控区（CPU/电池/主板）恢复真实温度就够了，壳温那一项影响很小。emul_temp 写 0 恢复真实温度是 Linux 温控核心的标准行为（为 0 就是不伪装），但这台 OPlus 内核是否完全照此办，真机上才能确认——退游戏后如果还觉得不降频，重启一次就全恢复了。

## 0.4.29 更新（2026-11-16，Extreme GT 4.2.1 去温控合并进来）

她装的 Extreme GT 4.2.1（SCENE 生成）合进来了，做法原样没改，只把“装了就全开”改成面板开关控制，默认关。面板“跟随”卡里多了个“去温控”开关。

开的时候两件事同时发生：

- **配置替换**：开机早期（post-fs-data.sh）把 `thermal/` 下 9 个文件 bind-mount 到原位置，盖掉 OPlus 的温控/锁帧配置——`sys_thermal_config.xml`（温控开关关掉）、`sys_high_temp_protect_OPPO_23926.xml`（高温保护/关机全关）、`sys_thermal_control_config.xml`（CPU/GPU 降频档全清空）、`thermallevel_to_fps.xml`（所有温控档都映射 144 帧，去锁帧）、充电温控、刷新率配置、分辨率配置。这 9 个文件是 SCENE 按这台机型（项目号 23926）生成的，只对 OPD2404 有效，逐字节照抄，一字没改。
- **温度伪装**：开机后（service.sh）把各 thermal_zone 的 `emul_temp` 写死成 29.5°C（外壳 33°C）、`/proc/shell-temp` 写死 29.5°C，再把 `persist.sys.horae.enable` 置 0（关 horae 温控服务）。温控服务读到的温度永远是“凉的”，就不会降频、不会锁帧。

开关点开会立即伪装温度（不用等重启），但配置替换要重启后才完全生效——温控服务开机时就把配置读进去了。关掉是卸掉挂载 + 把 horae 写回 1，温度伪装重启后完全恢复（emul_temp 是运行时节点，重启就恢复真温度）。

代价说在前头：机器会更烫、电池老得快，只在打游戏时开着、平时关掉最稳妥。装完先把 Extreme GT 卸载掉（不然两个模块干同一件事），再去面板开“去温控”开关、重启一次。fgetpriority 那个是隐藏系统调用的（防检测），不是温控，没合进来。

## 0.4.28 更新（2026-11-16，升级保留配置 + 日志去重）

两件事，都是她点的：

- **升级保留配置**：以前每次装新版都会把 config.conf 盖掉，她改过的设置（比如刚存的 lz4 24GB）下次升级就没了，开机变回系统默认。现在每次在面板里保存设置（改模式、改 zram 等）都会同步一份备份到模块目录外面（`/data/local/tmp/oneplus_sched_config.bak`，zip 解压盖不到）；装新版时 customize.sh 按“键”合并回来：备份里有的键用备份的值，新版新增的键留新默认值，新版不要的旧键丢掉。注意：这是第一次留备份，0.4.27 及之前存的设置还没有备份，**装完这一版要去面板里重新点一次 24GB**，之后升级就再也不会丢。顺手把 customize.sh 里写死的 0.4.23 版本号改成读 module.prop（再也不会过期），config.conf 里 zram 的注释 1-16 改成 1-32。
- **日志去重**：sched_log 每行写两遍（文件里一半是重复行，0.4.11 的日志一半就是这么来的）。现在 watch 和后台任务传 `SCHED_LOG_QUIET=1` 进来，sched_log 就不往 stdout 回显，日志只留带时间戳的那一份；线程表是 plain echo，不走 sched_log，不受影响。前台面板命令照常回显，看结果不受影响。

## 0.4.27 更新（2026-11-16，zram 大小加到 16/24/32GB）

她要 16GB 或者更高。面板大小档从 2/4/6/8/12 加到 2/4/6/8/12/16/24/32；`check` 上限从 16 放到 32GB，查表扩到 32（32 → 34359738368）。另外顺手修了 0.4.26 的一个显示 bug：`status` 的 GB 原来是去掉末 9 位约算的，14GB 以上会算错（16GB 会显示成 17GB），改成字节数反查表，不在表里的（比如厂商默认的 512MB）显示 0，面板会改显示原始字节数。注意：12GB 在真机上还没验过（0.4.26 的算术修法和诊断都还没回音），如果 12GB 的失败不是算术而是内核的大小限制，16GB 也会一样失败——新日志里有要写的数和 dmesg 的原话，能直接定案。

## 0.4.26 更新（2026-11-16，zram 大小改查表 + 写前记数 + dmesg）

她 12GB 连着四次全败在写大小那步（16:07、16:39、17:09、17:10），每次校验都过、写算法都过，偏偏写大小失败，而且报错是空的。最对得上的原因：`$(( 12 * 1073741824 ))` = 12884901888，超过 32 位；设备上的 sh 若是 32 位算术会算成 0，写 0 进 disksize 必然 EINVAL。旁证：四次回滚都显示“恢复 lz4 0GB”——旧大小若真是 4GB，32 位除法 `4294967296 / 1073741824` 正好也是 0。还没实锤（日志里没留下要写的数），所以这一版三管齐下：

- **大小改查表**：GB → 字节不用乘法算，1-16 全列死（12 → 12884901888），32 位还是 64 位都不影响；`status` 的 GB 显示和 `check` 的空闲内存比较也一样去掉大数乘除法（改按 MB 比、去尾数取整）。
- **写前记数**：`set` 一开始就把“当前算法/当前大小（字节）/目标（字节）”记进日志，下次再失败一眼看得出是算错了值还是内核不让写。
- **失败抓 dmesg**：写大小失败时把 `dmesg` 里 zram 的最后 5 行记进日志，内核自己会说清是 EINVAL / ENOMEM 还是 EBUSY——shell 报错靠不住（0.4.24 的四次全是空）。

装完再点一次 12GB：成了就是算术的锅；还失败就把新日志发来，里面有要写的数和 dmesg 的原话。

## 0.4.25 更新（2026-11-16，日志轮转加校验 + 硬清空兜底）

ColorOS / 安卓自己的做法：logd 是固定大小的环形缓冲（一般 256KB 一份，满了就盖掉最旧的）；落盘的 logcatd 按 2048KB 轮转、留 256 份；OPlus 自己的日志中心定期清 /data/persist_log。思路都一样：定个上限，只留最新的。模块里这功能 0.4.12 就有了（1MB 上限、留最后 4000 行，面板“清空日志”仍可手动清零），她 13:56 的日志里真转过一次（1,048,600 字节 → 留最后 4000 行）。这次补的是：轮转完再验一次大小——那次轮转前文件里有约 700KB 不是正常日志行（推断是之前某次截断留下的空洞/乱数据），只靠 tail+写回不够稳；验完还超就硬清空只留一行标记，日志绝不能一直顶着上限。另补了模拟测试 T33（轮转 + 硬清空两条路都测）。上限还是 1MB / 4000 行，没动。

## 0.4.24 更新（2026-11-16，zram 切失败回滚 + 报错原文）

她 16:07 在面板上切 lz4 12GB：校验过了，写大小那步失败了，swap 一直关到了现在——因为 0.4.23 的 set 是“任何一步失败都停在当场”，swapoff + reset 已经跑了，swapon 再也没跑。这一版补两个东西：

- **回滚**：swapoff 之后任何一步（reset / 写算法 / 写大小 / mkswap / swapon / 验读）失败，立刻把切之前记下的旧算法和旧大小写回去，重新 mkswap + swapon，swap 不会再被晾在半路。回滚本身也记日志，滚不回来就明说“重启平板恢复”。
- **报错原文**：每一步写 sysfs / 跑命令失败时，把 shell 报错原样记进日志（比如 Invalid argument / Cannot allocate memory / Device or resource busy），不再只有一句“写大小失败”——下次再失败，日志直接说清是参数不对、内存不够还是设备还忙着。

16:07 那次失败的原因日志里没留下（0.4.23 把 stderr 丢了），只知道是写大小那步。装完这一版先重启一次（swap 肯定回来），再从面板重试 12GB；要是还失败，日志里就是确切原因，发来我再看。

## 0.4.23 更新（2026-11-16，新增 zram 压缩算法 + 大小切换）

她要的 zram 切换，合进调度模块了，不另起模块：新脚本 `sched/zram.sh` + 面板“内存压缩 (zram)”卡。算法只显示设备上真正有的（读 `/sys/block/zram0/comp_algorithm`，lz4 一般都有，zstd 得看内核编没编），大小 2/4/6/8/12 GB 几档。切换流程：校验 → swapoff（只在 zram 正挂着 swap 时）→ reset → 写算法/大小 → mkswap → swapon → 验读 → 写配置；任何一步失败都停在当场。安全检查：已换出的数据（orig_data_size）必须 <= 空闲内存的 80%，不够就拒绝，不会硬切；和当前一样的项不重复切。面板点“应用”先同步跑一次只读校验（原因直接回面板），过了再后台切（swapoff 要几秒，面板 exec 等不起 15 秒超时），6 秒后自动刷新状态确认。开机由 service.sh 按 `ZRAM_ALGO` / `ZRAM_SIZE_GB` 套用一次，两项都没填就不动。KernelSU LKM / GKI 都一样，这活就是 root 写 sysfs 节点，不用另外加载内核模块。

## 0.4.22 更新（2026-11-16，修前台识别把内核线程当成前台）

她 14:00 那局的日志（下面“真机验证”）里发现：13:35、13:44、13:55 三次，watch 把内核线程 kworker（pid 10）当成前台应用去绑核，全败 EINVAL，还记“300 秒内不再重试”。根因：内核线程的 oom_score_adj 也是 0，`scan_oom_foreground` 靠它认前台；而旧的 `comm` 以 `[` 开头的判断根本拦不住——`/proc/PID/comm` 里本来就没有方括号（方括号是 ps 显示时加的）。改成没有 `/proc/PID/mm` 的一律跳过（内核线程没有 mm，用户进程都有），cpuset 扫描也顺手加了同一道。游戏那局本身没受影响（绑核 fail=0），修的是误判本身。

## 0.4.21 更新（2026-11-16，面板换成 MIUIX / HyperOS 风格）

她说旧面板太单调，换成小米 HyperOS 的样子：浅灰底 + 白色大圆角分组卡 + 小米蓝（#0d84ff），分组标题挪到卡片外面（设置页那种小灰标题），开关改成 MIUI 式圆角轨道 + 滑动白圆钮，按钮按下去有缩放回弹。深色跟系统走（WebView 认 prefers-color-scheme 时切深色）。只改了样式，HTML 结构和 JS 一个字没动，所有开关和按钮的 id 都在。真正的 Miuix 库是 Compose/Kotlin 的，塞不进 WebUI 的 HTML 页，这里是按同一套视觉语言手写的，没引外部框架，离线也能用。

## 0.4.20 更新（2026-11-16，删掉已取消路线的探测代码）

她拍板取消那条路线之后，代码里相关的也全删了：`lib.sh` 里的探测函数（只读探测，每次跑脚本在日志里记一行状态）和它在拓扑识别里的调用、`verify.sh` 里的第 11 节（只读体检里的一节）、README 里 0.4.2 的第 8 条。删的只是探测和文档，调度行为一个没动——本来就是只读的。

## 0.4.19 更新（2026-11-16，面板精简 + 修绑核全败误报）

06:36 真机日志（0.4.17）揪出来的 bug：06:35:55 一局里新冒出 37 个线程，06:36:07 其中一个（tid 14014）在 taskset 那一刻刚好退出了，内核报 `Invalid argument`，被记成 fail=1；那轮 ok=0（稳态下本来就没新线程可绑），watch 就当成“绑核全败”，写了 WARN、300 秒内不再重试——其实 180 个线程都还绑着，游戏一点没掉档。这个 EINVAL 竞态在全日志里出现过 17 次左右，都是线程退出那一刻撞上的。修两层：

1. taskset 失败时先看线程还在不在——/proc 里已经没它的目录了，算跳过不算失败；
2. watch 的“全败”改成 ok=0 且 fail>0 且 skip=0 才触发（一个都没绑上、一个也没绑过才是真全败），三处（游戏分支、前台新应用分支、前台同应用补绑分支）都改。

面板再精简一轮：线程自动绑定那张卡里的 5 个按钮（识别预览 / 立即绑定 / 解除绑定 / 开启跟随 / 停止跟随）全拿掉，轮询间隔滑块也拿掉（数值留配置里，默认 5 秒），只剩一个“游戏跟随”开关——点开就是跟随，点关就是停，开关状态每 2 秒按 watch 实际状态同步。四个配置开关（调度联动 / 自动检测 / 清理后台 / 开机跟随）还在，都是拨一次就不用再动的。手动绑别的 App、看线程分类表，后台命令都还在，跟我说一声，我帮你跑。

## 0.4.18 更新（2026-11-16，白名单加 CZero，面板状态自动刷新）

0.4.17 真机验证那局只清了 1 个应用：`com.web.czero`。她发截图认了——这是她自己装的 CZero 缓存清理应用（Android 缓存垃圾清理方案，自己也带后台压制）。进游戏时它正好闲置在后台，就被清了一次。加进白名单，以后进游戏不动它。

面板状态改成**自动刷新**：以前打开面板只刷一次，之后要手动点“刷新状态”才更新。现在打开面板后每 2 秒自动刷一次 fast 状态，检测到游戏 / 游戏退出时弹一次提示，状态卡下面显示“最后更新”时间。fast 状态以前不带“运行中的游戏”字段（只有慢速完整版才有），现在也带上了——游戏检测本身只要 0.08 秒，不拖慢轮询；前台识别（dumpsys）和温度扫描还是只在手动刷新和首次打开时跑。轮询时正在点按钮或上一轮还没回来就跳过这一拍，不堆命令；切到别的 App 时停掉，回来立刻刷一次；正在拖轮询间隔滑块时也不会被轮询打断。

## 0.4.17 更新（2026-11-16，进游戏清理后台大修——真机日志揪出来的 bug）

0.4.16 的清理在 05:20 那局真跑起来了，但清错了东西，一次清了 37 个：

- **系统应用全中招**：Play 商店、权限控制器、闹钟、日历、GMS、天气、日历、手机管家……原因：系统应用的 uid 也在 10000 以上，`uid >= 10000` 这道筛根本拦不住它们。修法：`pm list packages -s` 一次取齐系统包名单，命中就跳过；没有 `pm` 时用厂商前缀（com.android./com.google.android./com.coloros./com.oplus./com.heytap./com.oppo./android.）兜底。
- **搜狗输入法被清了**：白名单里只写了讯飞，她手机上用的是搜狗。修法：白名单改成 `"inputmethod"` 子串（讯飞、搜狗都含它），百度输入法（com.baidu.input）另写一条。
- **闹钟被清了**：force-stop 会取消闹钟应用设好的闹钟，不开一次闹钟应用就不会响。修法：闹钟（alarmclock/deskclock）进白名单。
- **包名解析错了**：`.adservices`（argv[0] 的后缀，不是包名）和 `com.android.vending:background` 这类 `:xxx` 子进程都被当成包去 force-stop。修法：先把 `:xxx` 后缀剥掉只留主包名，再验包名合法性（字母开头、带点、不以点开头、只含字母数字点下划线），去重也按主包名算。
- **日志噪音**：`can't open /proc/<pid>/cmdline` 115 条——进程在扫和读之间退出了，`<` 重定向失败时 shell 会把报错吵到日志里（`2>/dev/null` 拦不住，因为重定向失败在命令执行之前）。修法：先判可读，读的动作再包一层 `{ ...; } 2>/dev/null`。四处都修了（游戏检测、清理、包名解析、watch 残留 pid 检查）。

05:20 那局本身是好的：游戏档从 05:20:34 占到日志末尾 05:24:42 一直没掉，中途切去 KernelSU 也没掉；首次绑核 120 个线程 0 失败，之后每轮只绑新冒出来的 0–3 个；清理跑了，QQ/微信/音乐都没动。

## 0.4.16 更新（2026-11-16，撤参数滑块，加进游戏自动清理后台）

面板上的**日常参数、游戏参数两组滑块全撤了**（她用不到），参数值还留在 `config.conf` 里当默认值，想改数值直接改配置或跟我说。面板只剩：状态、一键模式（省电/均衡/性能/游戏）、线程自动绑定（识别预览、立即绑定、解除绑定、跟随开关、游戏调度联动、游戏进程自动检测、进游戏自动清理后台、开机自动跟随、轮询间隔）、输出/日志。`panel.sh` 的 `set` / `setmany` 后端还在，老 SchedCtl APK 的参数滑块照样能调，只是不在 WebUI 上放了。

新功能：**检测到游戏就自动清理后台**（`GAME_CLEAN_BACKGROUND`，默认 1，面板里能关）。watch 发现游戏进程刚跑起来（新开一局）时清一次，游戏自己重启换 PID 不重复清；手动 `thread.sh auto` 撞见游戏也清一次。只清 cached 应用（`oom_score_adj >= 900`，也就是系统已经把它扔到后台缓存里、没人正在用的），前台应用和正在放音乐的应用 oom 都低，不会误杀；清法是 `am force-stop` 整个包，下次打开自动重起。不清的：游戏自己（主进程和 `:xxx` 子进程）、白名单（音乐四款汽水/酷狗/QQ音乐/网易云、输入法、GlassMic/MusicMic、启动器）、uid < 10000 的系统应用、没有“.”的内核线程。QQ/微信**没在**白名单里：进游戏时会一起清掉，想留就把 `com.tencent.mobileqq` / `com.tencent.mm` 加进 `GAME_CLEAN_WHITELIST`。清了谁、清了几个都记进日志（`清理后台：force-stop <包名>` / `清理后台完成：清了 N 个应用`）。

## 0.4.15 更新（2026-11-16，模式并成 4 个，特调并进游戏模式）

模式改成 4 个：**省电 / 均衡 / 性能 / 游戏**。0.4.14 前和平精英 / 无畏契约各有一个特调档（peace / valorant），现在合并成一个**游戏模式**，参数就是原来和平精英那套值（她只玩和平精英；无畏契约也走同一档）。面板一键模式只剩 4 个按钮，游戏参数只剩一个卡片；`GAME_*_VALORANT` 的配置项和迁移成本（原来只有无畏契约写 1ms）都删了，`GAME_*_PEACE` 的键名没改，老面板 / 老 APK 调它们照样生效。

**性能和游戏的差距**（都在 `apply_sched.sh` 写死的值里，不是感觉）：

| | 性能 | 游戏 |
|---|---|---|
| 降频保留 | 5000µs | 10000µs（高频拿得更久） |
| hispeed_load | 90 | 85（更早拉高频） |
| uclamp top / fg 下限 | 102 / 51 | 153 / 77 |
| 后台 uclamp 上限 | 512 | 256（后台收得更紧） |
| GPU 下限 | 不抬 | 抬到 max 的 35%（366MHz） |
| foreground cpuset | 全核 | 中+大核 |
| 线程绑核 | 不绑 | 按线程分类绑（主/游戏线程独占超大核） |

游戏模式是临时的，不存进 `MODE`：进游戏自动切、退游戏自动切回 `MODE`。手动切：`game_sched.sh game` / `thread.sh game on` / 面板点“游戏”；`peace` / `valorant` 还是别名，调它们一样进游戏模式。老 APK 的和平精英参数滑块照样能用，无畏契约那组滑块会报错（键已删），APK 要按 4 模式重做界面才能跟上。

**面板打不开的隐患也一起修了**（0.4.14 刚交就报面板打不开，zip 本身验过是完好的，HTML/JS 也都没错）：一是 `thread.sh gamedetect` 原来逐 PID fork 一次 `tr`，600 个进程就是 600 次 fork、实测 1.27 秒，`panel.sh status`（慢速版）每调一次就多扫一遍 `/proc`，加上 `dumpsys` 容易拖过面板 15 秒的执行超时；现在先 `grep -l` 一次扫出带包名的候选（一个 fork，实测 0.025 秒），再逐个验首字段精确相等，语义不变。二是 0.4.14 加的“游戏进程自动检测”开关（`tglGameDetect`）忘了接 change 事件，点了没反应；现在接上了。

## 0.4.14 更新（2026-11-16，游戏进程自动检测）

0.4.13 只认**前台**是谁：前台一切走，游戏档立刻切回均衡、回来再切回去。0.4.12 的日志（2026-11-12 00:21 → 01:25）实证：00:27 她切到 QQ（`com.tencent.mobileqq:openSdk`）回消息，23 秒后游戏还在跑（同 PID 28943），档已经掉回 balanced，00:28 回游戏又重新切 peace、重新绑 222 个线程；00:22 切安装器那次也是同款掉档。要求是“自动检测游戏进程，然后自动切换模式”，所以：

1. **进程级检测（`scan_running_games`）**：watch 每轮先扫 `/proc` 里两款特调游戏的**主进程**在不在跑（读 cmdline 首字段的完整包名，comm 只截到 15 字、`pidof` 对不上全包名；只认完整包名精确相等，带 `:xxx` 后缀的子进程不算）。在跑就一直占着游戏档、补绑游戏线程，**不管前台是谁**——切出去回微信/QQ、装应用、弹键盘都不掉档；前台那套这轮跳过，不解绑游戏。
2. **退出宽限（`GAME_EXIT_GRACE_CYCLES`，默认 2 轮 ≈ 10 秒）**：主进程连续 2 轮找不到才算真退了、再切回均衡。游戏自己重启换 PID 的空档里不掉档（0.4.12 日志里游戏 00:22 → 00:24 就换过一次 PID 18877 → 28943）。
3. **开关（`GAME_AUTO_DETECT`，默认 1）**：改 0 回到 0.4.13 的老行为（只认前台）。面板和 WebUI 里都能关；注意：开着的时候，面板里手动点“切回均衡”也会在下一轮（5 秒内）被 watch 重新切回游戏档——自动检测优先于手动切，想手动控档先关这个开关。
4. **新命令 `thread.sh gamedetect`**：只输出运行中的特调游戏进程（包名/PID/档位），不看前台；面板 `status`（慢速版）里多了 `game_running_pkg/pid/profile`，WebUI 状态卡多了“运行中的游戏”一行。`thread.sh auto` 也先看游戏进程、再看前台。
5. **和平精英包名补 `com.tencent.tmgp.sgame`**：同款另一渠道包名，之前只认 `pubgmhd`，装 sgame 渠道的会掉到通用 game 档、切不到 peace 特调；现在两个都走 peace 档。

只覆盖两款特调游戏——通用游戏没有对应的调度模式可切，前台识别那条路仍负责它们的绑核。`thread.sh auto` 手动跑一次也会先找游戏进程。

## 0.4.13 更新（2026-11-12，修 0.4.12 日志实证的两个 bug）

0.4.12 的日志（2026-11-10 19:03 → 11-12 01:42，7360 行）验证了轮转本身能触发（11-11 13:08 到 1MB，保留最后 4000 行），但同时暴露了两个新问题：

1. **screen_state 把整份 dumpsys 当大参数传给 printf**：`_sp=$(dumpsys power)` 再 5 次 `printf '%s' "$_sp" | grep`。dumpsys power 的输出能到几百 KB，单个参数超过 128KB 上限，`/system/bin/printf: Argument list too long`，82 次、每次 5 个探测全灭，屏幕状态返回 unknown、灭屏切换被拖到下一轮（绑定本身不受影响，apply 之后还能正常跑）。0.4.13 改成 dumpsys 先落到临时文件再 grep，dumpsys 仍只跑一遍。
2. **轮转用 mv 换文件，断了 watch 的 stdout**：watch 启动时 `>> 日志` 绑的是旧 inode，`mv tmp 日志` 之后 watch 的 stdout/stderr（线程表、detect 回显、报错）继续写进已被删的旧文件。实证：轮转后 1488 行带时间戳、0 行裸行，printf 报错轮转后也彻底消失——不是修好了，是看不见了。0.4.13 改成原地截断写回（`cat tmp > 日志`），inode 不变，重定向不断。

这次日志的其他结论：唤醒仍无单一凶手（245 次采样：MsgPush 77、微信 74、kernel 45，28% 采样时根本没持有锁）；11-10 夜里中位 86 秒醒一次，和上期一样；11-11 夜里她一直在用平板（00:22 还打了一局和平精英，peace 档、GPU 366MHz、绑核 129/169），不是睡眠夜，没法比。翻倍没复发（OK/SKIP/FAIL 2652 行带时间戳、0 行裸行），0 ERROR，FAIL 只有已知的 uclamp 两项。

## 0.4.12 更新（2026-11-08，给日志加限制）

0.4.11 的日志 3 天长到 1.9MB / 27821 行，从没清过。两个原因：

1. **每行写两遍**：`sched_log` 写一份进文件、又回显一份到 stdout，而 service.sh / thread.sh 又把 stdout 重定向回同一个日志文件——`OK/SKIP/FAIL` 在日志里各出现 4141 次，全是翻倍的；`INFO detect` 3633 行也有 3624 行裸重复；每次换前台应用还多一份约 200 行的线程表。现在后台调 `apply_sched.sh` 的地方 stdout 改丢 `/dev/null`（面板里手动点的 `mode` / `apply` 不动，WebUI 里还要看输出），日志里只留 `sched_log` 的一份。watch 那行重定向保留：它的 echo（新前台、线程表）只走 stdout，不重定向就进不了日志。
2. **没有上限**：新增 `LOG_MAX_BYTES`（默认 1048576 = 1MB）和 `LOG_KEEP_LINES`（默认 4000 行），写日志前检查大小，到顶就只保留最后 4000 行并记一行 `INFO log rotated`。`LOG_MAX_BYTES=0` = 不限（不推荐）。面板里的“清空日志”按钮仍可随时手动清零。

## 0.4.8 更新（2026-11-06，修自动模式灭屏检测）

0.4.7 的 auto-mode 在真机上一次都没触发过（灭屏 15 秒测试，日志里零行 `INFO auto-mode`）。根因有两个，都是 0.4.7 设计上的洞：

1. **调用点被前台识别卡住了**：`auto_mode_tick` 只在“识别成功且前台不是输入法”时才跑。灭屏时根本没有前台应用可识别（或只剩输入法/锁屏），识别失败 → 整个分支跳过 → auto-mode 永远不执行。现在改成**每轮都跑**：只要没在游戏档里（以 `$GAME_SCHED_STATE` 文件为准）就跑，识别失败、输入法前台时也一样按屏幕/电量切模式。
2. **灭屏休眠会把 watch 冻住**：灭屏后系统 doze 会暂停后台进程，日志里 162s / 78s / 227s 的断档就是 watch 被冻住的证据。轮询进程冻住了就什么都检测不到——这是轮询方案的硬上限，不是解析 bug。现在 watch 每轮记上次循环的时间戳，醒来发现间隔 > 30s 就记一行 `INFO auto-mode resumed after <N>s gap`，让休眠缺口在日志里可见。

因此**电量规则才是可靠的主触发**（亮屏用平板时电量一低就切省电，不受休眠影响）；屏幕灭切省电是尽力而为——watch 恰好在灭屏还没休眠的窗口里跑到那一轮才能抓到。

新增两个配置项（都在 `config.conf`，面板 `set` 可改）：

- `AUTO_MODE_DEBUG`（0/1，默认 0）：开 1 后 watch 每分钟最多记一行 `INFO auto-mode check screen=<on|off|unknown> battery=<pct>%/<status> target=<mode> applied=<mode>`，即使模式没变也记。用来诊断“watch 在跑但 auto-mode 一声不吭”。查完设回 0，日志就干净了。
- `AUTO_MODE_WAKELOCK`（0/1，默认 0）：开 1 后 watch 持部分唤醒锁，灭屏时也能继续跑、可靠地检测 screen-off。但代价是设备无法深度休眠、耗电上升——省电模式省的那点电可能还抵不上持锁的消耗。**默认关**，只有确实需要“灭屏必切省电”才手动开。watch 退出 / `thread.sh stop` 时自动放锁；万一 watch 被强杀没放锁，跑一次 `thread.sh stop` 或重启平板即可清掉。

另外 `auto_mode_tick` 现在每轮都从 `config.conf` 重读 `AUTO_MODE` / 阈值 / `AUTO_MODE_DEBUG`，面板改完不用重启 watch 立即生效（0.4.7 用的是启动时的旧值，改完要重启 watch 才生效）。

测试方法（先开调试再测）：`panel.sh set AUTO_MODE_DEBUG 1`，然后重启 watch（或等下一轮），灭屏 15 秒再亮屏，看日志里有没有 `INFO auto-mode check ...` 和 `INFO auto-mode screen-off -> powersave`；查完 `panel.sh set AUTO_MODE_DEBUG 0` 关掉。

## 0.4.7 更新（2026-11-06，自动模式 AUTO_MODE）

基础模式（balanced / performance / powersave）以前要手动点，现在默认全自动。watch 每轮（5 秒）在非游戏前台时按规则自动选，不用再手动切：

1. **前台是游戏**（和平精英 / 无畏契约 / 通用 game）→ 不动基础模式，游戏档自己管 GPU 和调度；
2. **屏幕灭了** → 自动切 `powersave`；
3. **电量 ≤ 20% 且正在放电**（没插充电器）→ 自动切 `powersave`；
4. **其他情况** → 自动切回 `config.conf` 的 `MODE`（默认 balanced）。

屏幕重新亮起、或插上充电器 / 电量回升后，下一轮自动切回基础模式。自动模式永远不切 `performance`（想开性能档仍需手动点）。只在目标模式变了时才真正调用 `apply_sched.sh`，并记一行 `INFO auto-mode <原因> -> <模式>` 日志（原因：screen-off / low-battery / normal）。

想关掉自动、回到全手动：`panel.sh set AUTO_MODE 0`（或面板/APK 里关），watch 就永远不动模式，只绑核、只切游戏档。低电量阈值可改：`panel.sh set AUTO_MODE_LOW_BATTERY_PCT 30`（范围 5-50）。

## 0.4.3 更新（2026-11-06，watch 开机自动跟随）

0.4.2 之前 watch 默认不开机自启，装完重启后必须手动开，不开它就什么都不认（0.4.2 日志实证：装完打了一局和平，watch 没在跑，一个字都没记）。0.4.3 把 `AUTO_WATCH_ON_BOOT` 默认改成 1，开机由 `service.sh` 在后台启动 watch，前台应用换了自动重绑、自动切游戏档，退出切回均衡。想关就把 `config.conf` 里改成 0（或面板里关“开机自动跟随”）。其他内容和 0.4.2 完全一样。

## 0.4.2 更新（2026-11-06，修 0.4.1 日志实证的 bug）

0.4.1 在平板上跑了三天（22501 行日志），结论是模块基本没生效。0.4.2 修的是日志里能确定的问题：

1. **GPU 下限写错值**：`max_freq × 百分比 / 100` 在 32 位 shell 里溢出，和平精英档写进去的是 11001635（约 11MHz）而不是 226MHz。改成先除后乘，再按 `available_frequencies` 取整到真实 OPP。另：25% 算出来 226MHz 低于本机 GPU 最低 OPP 231MHz，等于没抬，和平精英档改成 35%（约 316MHz），和无畏契约一致。
2. **拓扑降频误判**：`cpuinfo_max_freq` 在游戏降频时会被内核下调，一局里 2/3/4 号核被误认成超大核。改成优先按 `cpu_capacity`（设备树静态算力值，不随降频变）分档，读不到再回退到频率法。
3. **zygote64 被当成前台应用**：它是所有应用的父进程，cgroup 里也带 top-app，cpuset 扫描按顺序先扫到它。`is_denied` 加上 zygote / usap / webview_zygote；cpuset 扫描优先取 `oom_score_adj==0` 的那个。
4. **输入法被当成前台游戏**：键盘弹起时输入法短暂成为前台，watch 反复切走又切回。watch 识别到输入法时直接跳过（不切换、不绑核、不切调度），同一个输入法只记一次日志。
5. **RenderThread 误判游戏**：所有带硬件加速界面的应用都有 HWUI RenderThread，0.4.1 因此把 MusicMic、输入法都判成 game。游戏引擎判断去掉 RenderThread 和 Gfx，只留 Unity / Unreal / Vulkan / Game / RHIThread / TaskGraph。
6. **taskset 报错不可见**：0.4.1 只记成功/失败数，失败原因完全丢了。0.4.2 把第一次失败的完整报错记进日志（`WARN taskset 失败示例`），下次看日志就知道是权限、掩码还是别的。
7. **watch 刷屏**：绑核全败时每 5-10 秒重试一次、每轮记一行，日志全是 ok=0。0.4.2 全败后 300 秒内不再重试同一应用（等应用换了或退避到期再试）。

**还没修的（需要平板上实测/确认）**：taskset 全败的根本原因——到底是权限、掩码格式还是游戏内核在拦，0.4.2 的 `WARN taskset 失败示例` 就是为这个留的；top-app / background 的 uclamp 写不进去（节点在但写失败），需要平板上看 cgroup 实际路径。装好 0.4.2 后进一局和平精英，把 `/data/local/tmp/调度日志.log` 发出来再看。

## 这两个模块分别是干什么的

**1. 调度模块（`sched/apply_sched.sh`，开机由 `service.sh` 调用）**

系统层面的调度调校，只写 sysfs / cpuset / cpuctl，重启即恢复：

- 调频器保持 `schedutil`，调它的 `up/down_rate_limit_us` 和 `iowait_boost`，让升频响应更快、降频别太急；
- `cpuset` 分组：前台/顶层应用放宽，后台/受限组只用小核，别抢前台；
- `uclamp`：performance 模式才给前台一个很小的利用率下限，balanced 默认不碰；
- 内核 `sched_*` 参数默认**关闭**（`SCHED_TUNABLES=0`），想试再开；
- GPU、I/O 默认**不锁频率、不改调度器**，只记录现状；
- **温控、电压、热管理一律不碰。** 一加自带的潮汐架构仍在工作，本模块是补充调校，不是替代它；如果厂商 Power HAL 在开机后又覆盖了某些值，日志里会显示，属正常现象。

**2. 线程模块（`sched/thread.sh`）：自动识别前台应用，按线程名分类绑核**

不用输包名。先识别，再分类，最后按类别绑核，不是一股脑全绑大核：

```
su
sh thread.sh detect                       # 只识别、不绑定：先跑这个，验识别准不准
sh thread.sh gamedetect                   # 只看两款游戏的进程在不在跑（不看前台）
sh thread.sh auto --dry-run               # 只打印会怎么绑，不真的绑
sh thread.sh auto                         # 先看游戏进程，再看前台应用，自动分类绑定
sh thread.sh auto game                    # 强制按游戏档
sh thread.sh watch 5                      # 常驻轮询：游戏进程在跑就占着游戏档，前台换了自动重绑
sh thread.sh stop                         # 停掉 watch
```

前台识别三级兜底：`dumpsys window/activity`（最准）→ `cpuset/top-app` → `oom_score_adj==0`（最快，watch 默认先走这条）。识别不到就什么都不绑；系统关键进程（system_server / surfaceflinger / systemui）自动模式永远不碰。**游戏进程检测是另一条线**：watch 每轮先扫 `/proc` 看和平精英 / 无畏契约的主进程在不在跑，在跑就占着游戏档、补绑游戏线程，前台切到别的 App 也不掉档；主进程连续 `GAME_EXIT_GRACE_CYCLES`（默认 2）轮找不到才算真退了、切回均衡。开关 `GAME_AUTO_DETECT`（默认 1），改 0 回到只认前台的老行为。

分类按线程名子串（comm 截断到 15 字，只按子串判）：主线程和 RenderThread / UnityMain / Vulkan 这类渲染线程 → 大核+超大核；音频线程 → 大核；Binder → 中+小核；线程池 / worker / 下载同步类 → 小核；其他线程游戏档放中+小核、日常档放全核。游戏档的判断：包名命中 `AUTO_GAME_PACKAGES`，或线程名里有 Unity / Unreal / Vulkan / Game。**和平精英 / 无畏契约走游戏档（原来和平精英那套值）。**

`big/little/mid/prime` 是优先按 `cpu_capacity` 算出来的（读不到再回退到 `cpuinfo_max_freq`），不是写死的 0-1、7。新线程是进程启动后陆续创建的，一次 `auto` 只绑当时已存在的线程，游戏刚启动时跑一次、进游戏后再跑一次，或用 `watch` 让它自己跟。`watch` 退出时会把当前应用绑回全核。开机自动启动 `watch` 默认开启（0.4.3 起），想关就把 `config.conf` 里 `AUTO_WATCH_ON_BOOT` 改成 0。

手动命令还在：`list / bind / unbind / prio / profile <包名或PID>`，用法见 `thread.sh` 头部注释。PID 1/2 拒绝，手动动 `system_server` / `surfaceflinger` 需要 `FORCE=1` 或 `--force`。

## KernelSU 可调面板（WebUI）

你是 KernelSU：装好模块重启后，在 KernelSU 管理器 → 模块 → 本模块，点 WebUI 打开面板（`webroot/index.html`，单文件、无外部依赖、离线可用）。面板通过 `ksu` 桥以 root 身份调 `sched/panel.sh`，面板本身不直接拼 shell 命令，写配置只走白名单 + 范围校验。

面板里能调的：

- **一键模式**：省电 / 均衡 / 性能（同时保存为开机默认）、游戏（临时，不改开机默认）；
- **线程自动绑定**：识别预览、立即绑定、解除绑定、开启 / 停止跟随、游戏调度联动开关、游戏进程自动检测开关、进游戏自动清理后台开关、开机自动跟随开关、轮询间隔；
- **输出 / 日志**：看日志、只读体检。

不在 WebUI 里打开（比如普通浏览器）时面板会提示并禁用按钮，不会报错乱执行。面板的 `ksu.exec` 做了三参数回调 / 两参数回调 / 同步返回 / Promise 四种形态的兼容，不同 KernelSU / KernelSU-Next / APatch / WebUI X 宿主形态不一样，面板都按同一套命令走，真机上以实际能打开为准。

0.4.1 面板流畅度修复（针对 0.4.0 点按卡顿的反馈）：原来每次点击要串行跑 4 到 10 次 root 命令，而且每次刷新都调一次 `dumpsys` 识别前台应用，`dumpsys` 在 ColorOS 上常以秒计，期间所有按钮还被全局禁用、界面没有任何反馈，看起来就像点下去没反应；800ms 没回包就换形态重发一次，还会把慢命令跑两遍。0.4.1 改成：日常刷新一次 `state` 调用同时拿状态和配置，跳过 `dumpsys` 和温度扫描，只有“刷新状态”和首次打开才跑完整版；模式切换一次 `mode` 调用、滑块保存一次 `setmany` 调用；点按先显示“执行中”，等 30ms 让界面画出来再调 root 命令；重试等待从 800ms 放到 2500ms，避免慢命令被重复执行。

## 游戏模式：和平精英 / 无畏契约共用一个档

包名已核实（小米应用商店 / 应用宝 listing）：和平精英 `com.tencent.tmgp.pubgmhd`【1567444731115147322†L26-L28】，同款另一渠道包名 `com.tencent.tmgp.sgame`，无畏契约：源能行动 `com.tencent.tmgp.codev`【6858244126328562365†L8-L10】。`verify.sh` 第 10 节会先查这两款装了没有，包名对不上游戏档就识别不到。

平时不用手动切：`thread.sh watch` 检测到这两款游戏的进程在跑就自动切游戏模式、自动按线程分类绑核，进程退出后才自动切回 `balanced`——中途切出去回消息、装应用都不会掉档。只想手动试一次：

```
su
sh thread.sh auto game        # 在游戏前台时（peace / valorant 是 game 的别名）
sh game_sched.sh game         # 只切调度，不绑核
sh game_sched.sh off          # 切回均衡
```

游戏档长这样（数值全在 `config.conf` 的 `GAME_*` 项里，改配置就能调；性能和游戏的差距见上面 0.4.15 的表）：

- **调度**：schedutil 升频拉满（up=0）、降频保留 10000us，hispeed_load 85，top-app uclamp 下限 153、foreground 下限 77，后台组 uclamp 上限收紧到 256，GPU 下限抬到 max 的 35%（366MHz），迁移成本不写（保持原厂）。
- **绑核**：GameThread 独占超大核，Render / RHI 上大核+超大核，TaskGraph / 流式加载放中核（放小核加载会卡顿），语音和网络放中核，后台工人放中核；主线程 nice -5。
- **共同点**：都不锁最高频、不碰温控和电压。发热明显上去就先关游戏调度：`GAME_SCHED_ENABLED=0` 只绑核不切调度，或直接 `game_sched.sh off`。

线程分类按 UE 线程名子串判：GameThread、RenderThread、RHIThread、TaskGraphThread、AudioMixer / Voice / GME、Network / Socket、Input / Touch、Binder、线程池 / worker。`comm` 截断到 15 字也能命中。`detect` / `auto --dry-run` 先看分类表对不对，再真绑。

平板需要 root。把 `sched/verify.sh` 推到平板，只读，不写任何东西：

```
adb push sched/verify.sh /sdcard/verify.sh
adb shell su -c "sh /sdcard/verify.sh"
```

看三点：8 个核的 `cpuinfo_max_freq` 是不是 1 大 + 5 中 + 2 小的分档；`cpuset`、`uclamp` 节点在不在；GPU 的 devfreq 路径叫什么。把输出发出来，就能确认模块在你这台上的实际落点。

## 安装

需要 Magisk / KernelSU / APatch 之一，且平板已 root：

1. 在 Magisk / KernelSU / APatch 里选“从本地安装”，选本目录打好的 zip；
2. 重启；
3. 看日志：`/data/local/tmp/调度日志.log`，里面每行都是 `OK / SKIP / FAIL`，SKIP 表示该节点你这台没有，已自动跳过。

卸载/禁用模块后重启，所有调校全部恢复原厂，不留持久修改。

## 换模式

改 `sched/config.conf` 里 `MODE=balanced|performance|powersave`，重启生效；或不重启手动跑一次：

```
su -c "sh /data/adb/modules/oneplus_pad_pro_sched/sched/apply_sched.sh performance"
```

默认 `balanced`。`performance` 只把 rate limit 收得更紧、cpuset 放得更宽、uclamp 给个小下限，**依然不锁最高频**；想锁频、想动 `sched_*`，自己改配置，责任自负，发热和耗电会明显上去。

## 文件结构

```
module.prop                 模块信息
service.sh                  开机等启动完成 + 10 秒后调用调度模块
customize.sh / uninstall.sh 安装校验 / 卸载记日志
META-INF/...                Magisk 安装入口
sched/
  config.conf               全部可调参数，-1/空 = 不碰
  lib.sh                    共用函数：写节点、拓扑识别、策略换算
  apply_sched.sh            调度模块本体（模式：balanced | performance | powersave | game）
  thread.sh                 线程模块：自动识别、分类绑核、watch、game 切换
  game_sched.sh             游戏模式独立入口：game | off | status（peace|valorant 是别名）
  panel.sh                  KernelSU 面板后端：status / set / apply / game / thread / log
  verify.sh                 只读体检（含两款游戏包名检查）
webroot/
  index.html                KernelSU WebUI 面板（单文件，离线可用）
```

## 风险和实话

- 未真机实测：核号顺序、cpuset/uclamp 路径、GPU 节点名在不同 ColorOS 版本上可能不同，脚本靠“存在才写”兜底，但不能保证每项都生效，日志为准。
- 一次只装一个调度类模块。已装 Scene / 慕容调度 / OmniSched 之类的，先别叠加，好归因。
- 觉得发热、掉电快、卡顿，立刻禁用模块重启；重启就是原厂状态。
- 本模块不 root、不解锁、不刷 boot，只在已有 root 环境里写运行时参数。
