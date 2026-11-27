-- PBZ_MP —— 影之刃零 联机 PvP 原型（版本号见下方 VERSION）
-- 路线：防守方判定。对手在本机用一个"独立角色"代表（SpawnActor 玩家同类 + AIController；v0.13.0 起不再 CreatePlayer，
--       因为多一个本地玩家会让游戏菜单永久打不开）。对手出招 = 在它身上激活同名技能，打没打中、弹没弹开交给游戏原生战斗系统。
-- 网络：UE4SS 的 Lua 没有 socket，读写模组目录 net/ 下的文本文件，由同目录的联机窗口 PBZLobby.exe（或测试用 sidecar.py）收发 UDP。
-- 开发在源码仓库里做，游戏目录里只放部署后的文件
--
-- 正式流程：双方打开模组目录里的"PBZLobby.exe"，一方点"创建房间"，另一方填 IP（或双击局域网房间）点"加入"。
--   连上后对手自动出现，客机自动传送到主机身边；两边都按 F1 准备 → 倒计时 → 先赢 2 回合。
--
-- 键位（单独按 F 键，不带 Ctrl —— Ctrl 在游戏里是影之武装攻击）。v0.17.1 起避开 Phantom Pact（F3 / F4 / F5，
-- 它用 IsInputKeyDown 读，带不带修饰键都算）、UE4SS 控制台 F10、Steam 截图 F12；F9 会被 UHSMFF 的 Ctrl+F9 顺带触发，只放无害的状态：
--   F1  准备 / 取消准备；对局中 3 秒内连按两次 = 弃权
--   F2  把你现在站的位置和朝向存成 PvP 场地中心（主机的为准；两人在中心两侧各 5 米，面对面）
--   F9  状态（调试）
--   F12 手动造对手角色（测试用；正式流程连上会自动出现）。v0.17.8：F11 是游戏自带的全屏切换，不能用（§36）
--   F6  藏起对手角色、回到单人（对局中会先中止）
--   F7  开始 / 停止录制自己的动作（给幽灵对手用）
--   F8  让对手角色回放最近一次录制（单机对练）
--   Home 游戏内联机面板（v0.18.0 net-ui）：选连接方式（Steam 好友 / 局域网 / 服务器大厅 / Steam 大厅；v0.20.2–v0.20.3 虚拟局域网并进局域网、广域网并进服务器大厅）、建房、加入、断开。
--        面板开着时 PgUp/PgDn 选、End 确定（选中连接方式时 End = 换下一种）。联机窗口没开会自动以后台模式启动（docs/NETWORK_UI.md）

local UEHelpers = require("UEHelpers")

local VERSION = "0.34.13"
local TAG = "[PBZ_MP] "
-- v0.14.0：所有文件都放在模组自己的目录（…/Mods/PBZ_MP/），不再写死本机的游戏路径，别人的电脑上也能用。
-- 从本脚本的路径推出模组目录（脚本在 PBZ_MP/Scripts/main.lua）；拿不到时退回 UE4SS 的工作目录（游戏 exe 所在的 platform/steam）下的相对路径
local ROOT_TRIED = {}
local function modRoot()
    local cands = {}
    local function add(d)
        if d and d ~= "" then cands[#cands + 1] = (d:gsub("\\", "/"):gsub("/+$", "")) end
    end
    -- 0) F6：fornet 宿主（Scripts\main.lua）装本文件（games\pbz\main.lua）时给的模组目录
    if type(FORNET) == "table" then add(FORNET.ROOT) end
    -- 1) UE4SS 把本模组 Scripts 目录的绝对路径放进了 package.path
    for entry in tostring(package.path or ""):gmatch("[^;]+") do
        local d = entry:gsub("\\", "/"):match("^(.*[/]PBZ_MP)/[Ss]cripts/")
        add(d)
    end
    -- 2) 本脚本自己的路径
    local ok, info = pcall(debug.getinfo, 1, "S")
    local src = ok and info and info.source or ""
    add((src:gsub("^@", ""):gsub("\\", "/"):match("^(.*)/[Ss]cripts/[^/]+$")))
    -- 3) 相对路径（工作目录不一定是游戏 exe 所在目录，所以要逐个验证）
    add("ue4ss/Mods/PBZ_MP"); add("Mods/PBZ_MP"); add("platform/steam/ue4ss/Mods/PBZ_MP")
    for _, d in ipairs(cands) do
        local f = io.open(d .. "/Scripts/main.lua", "r")
        ROOT_TRIED[#ROOT_TRIED + 1] = d .. (f and " ✓" or " ✗")
        if f then f:close(); return d end
    end
    return cands[1] or "ue4ss/Mods/PBZ_MP"
end
local ROOT = modRoot()
if type(FORNET) ~= "table" then FORNET = { ROOT = ROOT, GAME_DIR = ROOT .. "/Scripts", SCRIPTS = ROOT .. "/Scripts", standalone = true } end     -- F6：老布局 / 测试里没有宿主
local LOG = "mp_probe.log"          -- §219 文件名；实际写 logs/<日期>/<这个名字>（LOGBUF.path）
local NET_DIR = ROOT .. "/net"
local REC_DIR = ROOT .. "/rec"
local F_LOCAL = NET_DIR .. "/state_local.txt"
local F_REMOTE = NET_DIR .. "/state_remote.txt"
-- §147 双开（-allowmultipleinstances）两份游戏共用这个文件夹，日志以前交错写进同一个 mp_probe.log 分不清。
-- 第一份每 5 秒在 net/log_owner.txt 写"编号 时间"（看门狗里写）；启动时发现别人的、15 秒内写过 → 我是第二份，日志写 mp_probe_2.log
INST = { FILE = NET_DIR .. "/log_owner.txt", STALE = 15, BEAT = 5, slot = 1, at = -100,
         id = tostring(os.time()) .. "-" .. tostring({}):gsub("^table: ", "") }
function INST.claim()
    local f = io.open(INST.FILE, "r")
    local line = f and f:read("*l")
    if f then f:close() end
    local oid, ot = (line or ""):match("^(%S+) (%d+)$")
    if oid and oid ~= INST.id and os.time() - tonumber(ot) < INST.STALE then INST.slot = 2 end
    INST.beat()
    return INST.slot
end
function INST.beat()
    if INST.slot ~= 1 or os.time() - INST.at < INST.BEAT then return end
    INST.at = os.time()
    local f = io.open(INST.FILE, "w")
    if f then f:write(INST.id, " ", tostring(INST.at), "\n"); f:close() end
end
-- §151 双开第二份另用一个 net 目录（net2）：联机程序 DLL 按自己所在目录找 net、还有单实例锁，两份游戏抢同一个联机程序
-- （11-08 09:27 实测：先开的那份面板"联机程序没响应"）。第二份改走 PBZLobby.exe --dir net2，管道名 / lobby.txt / 设置都分开
-- §153 第二份也用 DLL：DLL 拿不到"第一份"锁就自己用 net2（锁 / 管道名带 pid，§152）；DLL 不行才退回 exe --dir net2
if INST.claim() == 2 then
    LOG = "mp_probe_2.log"
    NET_DIR = ROOT .. "/net2"
    F_LOCAL, F_REMOTE = NET_DIR .. "/state_local.txt", NET_DIR .. "/state_remote.txt"
    pcall(os.execute, string.format('mkdir "%s" 2>nul', NET_DIR:gsub("/", "\\")))
end

local PLACE_DIST = 300.0     -- 替身归位：你正前方多远
local REPLAY_DIST = 500.0    -- 回放起点：你正前方多远（录制时的"正前方"会朝向你）
local MAX_SPEED = 900.0
local CATCHUP_SPEED, SNAP_DIST = 1400.0, 900.0    -- 落后 200 以上时的追赶速度上限；超过 SNAP_DIST 才直接瞬移
local LAG_DIST, LAG_SEC = 300.0, 2.0               -- 落后 LAG_DIST 以上持续 LAG_SEC 秒（追不上 / 被卡住）也瞬移
-- v0.23.2 出招中不瞬移：替身开始重放对方的攻击后 ATK_HOLD 秒内，只有离得超过 SNAP_ATK 才瞬移，也不按"追不上"瞬移；
-- 这一招打完还远，再照常校正。2026-11-04 23:05–23:19 实测 38 次瞬移里 20 次在替身刚出招时（出招前冲 + 网络位置没跟上），
-- 出招中途被拉回去最难看，攻击判定的位置也跟着被拉走
local ATK_HOLD, SNAP_ATK = 1.8, 2000.0

local ST = {
    p1pc = nil, secondPC = nil, secondPawn = nil, testMonster = nil,
    ticks = 0, stableTicks = 0, lastTickAt = 0, driverGen = 0,
    setCache = {}, ascCache = {},
    tagFn = nil,              -- 能用的取标签方式，nil=没试过，false=都不行
    watch = { p1 = {}, pup = {}, mon = {} },
    hpTrace = 0, hpTraceSeen = nil,
    lastPupAction = nil,      -- { name, at }
    atkList = nil, atkIdx = 0,
    abList = nil, abIdx = 0,
    brakeSaved = nil,
    mapLoads = 0,             -- v0.27.12 加载过几次地图（加载钩子数），界面控件记下自己是哪一次建的（§93）
}

local NET = { seq = 0, lastSeq = -1, lastRecvAt = -100, pos = nil, vel = nil, yaw = 0.0,
              evId = 0, events = {}, prevAbs = nil,           -- 发送：本机技能事件
              lastEvIn = 0, sub = {}, wTried = nil,            -- 接收：已处理到的事件编号
              rx = 0, evIn = 0, evLost = 0, driving = false,
              judges = {}, judgeHp = nil, resId = 0, results = {}, judged = {},   -- M3 防守方判定
              lastResIn = 0, applied = {}, stagger = nil, remoteHp = nil,        -- M3 攻击方收结果
              resSeen = {}, RES_OOO = 64 }                     -- §370 收过的结果号（晚到的照收，比最大的小 RES_OOO 以上当旧包）
-- M4 对局（v0.10.0）。role = nil / "host"（按 F4 发起的一方，说了算）/ "client"（跟随对方的 mt）。
-- me / op = 我 / 对方的回合分；dead = 我在第几回合倒下（0 = 本回合没倒）；wire = 随状态包发出去的字段
local MATCH = { role = nil, state = "idle", round = 0, me = 0, op = 0, t0 = 0, arena = nil, center = nil,
                dead = 0, win = "-", id = 0, lock = nil, hold = {}, pupFell = 0,
                wire = { mt = "", arena = "", dead = 0, rdy = 0, quit = 0, asp = "" }, ready = false }
local REC = { on = false, frames = nil, t0 = 0, ox = 0, oy = 0, oz = 0, oyaw = 0 }
local REP = { on = false, frames = nil, t0 = 0, i = 1, ax = 0, ay = 0, az = 0, ayaw = 0, lastM = "" }
local abilitiesOf   -- 前置声明：回放要用，定义在下面 M0 段
local finishDeflect     -- 前置声明：精防/普通防御分类，定义在 M3 段

-- L3（docs/FORNET_LAYERS.md）：基础联机包发给往上加的 mod 的事件（观战等自己订阅，基础联机包不按名字调它们）+ 对局占用锁。
-- 有 4net 的 mod 机制就走它的事件总线（mod 用 M.on 订阅）；老布局 / 测试（没有 FORNET.emit）走这里的小总线。全局：主块 local 满 200 个
-- 事件：base.feedSrc(t, tn) 带来源的包（主机转发的观战两路）/ base.tick(tn) / base.session(was, kv, wasRelay) / base.mapLoad() /
--       base.matchOver(won, role) / base.roomRows(items, T, lb, cmd, flash) 房间里的面板行 / base.roomCat.spec(sub, T, notHost, flash, lb, cmd) /
--       问一圈 base.navKey(what)（面板关着时 PgUp / PgDn，谁接了谁用）
BASEHOOK = { bus = {}, warned = {} }
-- 多人房的查询口（L5 收尾 11-14）：管多人房的玩法 mod 经 pvp.setMp(对象) 登记到 BASEHOOK.mp；
-- 基础联机包只问这里（"在不在多人房"、多人房设置、对决…），不认具体是哪个 mod。没登记 = 一律按不在多人房
BASEHOOK.mp = nil
function BASEHOOK.setMp(o) BASEHOOK.mp = o end
function BASEHOOK.inMp()
    local p = BASEHOOK.mp
    return (p and p.inMp and p.inMp()) and true or false
end
function BASEHOOK.on(ev, fn)
    if FORNET and FORNET.emit then return FORNET.on(ev, fn) end
    local l = BASEHOOK.bus[ev] or {}
    BASEHOOK.bus[ev] = l
    l[#l + 1] = fn
    return true
end
function BASEHOOK.emit(ev, ...)
    if FORNET and FORNET.emit then return FORNET.emit(ev, ...) end
    local l = BASEHOOK.bus[ev]
    if not l then return 0 end
    for _, fn in ipairs(l) do pcall(fn, ...) end
    return #l
end
function BASEHOOK.ask(ev, ...)
    if FORNET and FORNET.ask then return FORNET.ask(ev, ...) end
    for _, fn in ipairs(BASEHOOK.bus[ev] or {}) do
        local ok, v = pcall(fn, ...)
        if ok and v then return v end
    end
    return nil
end
function BASEHOOK.me() return FORNET_BASE and FORNET_BASE.name or "base" end
-- 对局被别的玩法占着（观战 / 以后的独立玩法驱动替身、藏角色）：返回占用者的名字，没有返回 false。
-- 基础联机包据此不挪角色、不解锁血、不显示对手血条、不换替身……（以前这些地方写死看 ST.spec.on）
function BASEHOOK.otherScene()
    local S = FORNET and FORNET.modsys
    if S and S.holder then
        local h = S.holder("match")
        if h == "multi" then return false end     -- 多人 / 对决对局是真人在打，不是"角色藏着、冻着"的场景（落地检查、防虚空照旧）
        return (h ~= nil and h ~= BASEHOOK.me()) and h or false
    end
    return (ST.spec and ST.spec.on) and "spec" or false      -- 没有 mod 机制（老布局 / 测试）：只有观战会这样
end
function BASEHOOK.title(h)
    local S = FORNET and FORNET.modsys
    local m = S and S.byName and S.byName[h]
    local t = m and m.manifest and m.manifest.title
    if t and t ~= "" then return t end
    return h == "spec" and "观战" or tostring(h)
end
-- 1v1 开局占"对局"：空着 / 自己占着 → 占上；被往基础联机包上加的 mod（needs=base）占着 → 照旧开（以前它们之间靠各自的判断，
-- 比如观战在 MATCH.role 时不开），不占；被独立玩法占着 → 不开局，返回 false + 谁
function BASEHOOK.take()
    local S = FORNET and FORNET.modsys
    if not (S and S.acquire) then return true end
    local me = BASEHOOK.me()
    local ok, who = S.acquire(me, "match")
    if ok then return true end
    local m = S.byName and S.byName[who]
    for _, d in ipairs(m and m.needs or {}) do
        if d.name == me then
            if not BASEHOOK.warned[who] then     -- out 是后面才定义的主块 local，这里看不到，用全局 FNLOG
                BASEHOOK.warned[who] = true
                if FNLOG and FNLOG.out then FNLOG.out("对局占用：%s 占着（它是往基础联机包上加的），1v1 照旧开局", who) end
            end
            return true
        end
    end
    return false, who
end
function BASEHOOK.give()
    local S = FORNET and FORNET.modsys
    if S and S.release then S.release(BASEHOOK.me(), "match") end
end

-- ============================================================ 基础设施

-- §84 日志攒着写：以前每行都 打开 / 追加 / 关闭 一次 mp_probe.log（对局里每秒几行到几十行）。攒到 MAX 行或 SEC 秒写一次
-- （驱动每次也看一眼，没新日志时不会一直攒着）；带 "!!" 的（出错）马上写。游戏崩了最多丢最后 SEC 秒的普通日志。
-- 全局（主代码块的 local 已满 200 个）
-- §89 每行日志以前还 print 一份，UE4SS 再一行一行写进 ue4ss/UE4SS.log（对局里每秒十几行，剩下最频繁的写盘）。
-- 现在只有出错（"!!"）和少数关键行（"==" 开头、管道、版本）进 UE4SS 控制台 / UE4SS.log；全部日志照旧在 mp_probe.log。
-- 要看全部：PRINT_ALL = true
-- F4a（docs/FORNET_SPLIT.md）：LOGBUF / out 原样搬到 fornet_log.lua；这里只装模块、取别名，行为一字不差。全局：主块 local 已满 200 个
FNLOG = (function()
    local ok, mk = pcall(require, "fornet_log")
    if ok and FORNET and FORNET.adopt then mk = FORNET.adopt("fornet_log", mk) end     -- F6：实例登记到宿主（FORNET.mods）
    if not ok then ok, mk = pcall(dofile, ROOT .. "/Scripts/fornet_log.lua") end
    if not (ok and type(mk) == "function") then error("fornet_log.lua 加载失败：" .. tostring(mk)) end
    return mk({ ROOT = ROOT, LOG = LOG, TAG = TAG, keyPrints = { "PBZ_MP v" } })     -- 版本行也进 UE4SS 控制台（§89）
end)()
LOGBUF = FNLOG.LOGBUF
local out = FNLOG.out
if INST.slot == 2 then out("双开：另一份游戏在跑（net/log_owner.txt 15 秒内写过），这份的日志写 logs/<日期>/mp_probe_2.log（§147 / §219）") end

-- main.lua 瘦身（docs/MAIN_SLIM.md）：从这里搬出去的段落在同目录 base_<名>.lua，形如 return function(ctx) … return 导出表 end。
-- 原位置写 X = BASEPARTS.load("<名>", { 要用到的 main.lua 东西 })。载不进来直接报错（基础联机包整个不加载，比缺一块悄悄跑强）。
-- 全局表（最外层 local 已经很多，不再加）
BASEPARTS = { loaded = {} }
function BASEPARTS.load(name, ctx)
    local file = "base_" .. name
    local ok, mk = pcall(require, file)
    if not ok then
        local dir = (FORNET_BASE and FORNET_BASE.dir) or (ROOT .. "/Scripts")
        ok, mk = pcall(dofile, dir .. "/" .. file .. ".lua")
    end
    if not (ok and type(mk) == "function") then error("基础联机包少了 " .. file .. ".lua 或载入失败：" .. tostring(mk)) end
    local api = mk(ctx or {}) or {}
    BASEPARTS.loaded[name] = api
    return api
end


-- F4c-2：桥接 DLL（例如 Steam 扩展包里那一个）由扩展包 ext\<名>\init.lua 经 API.native.load 载进游戏进程；基底不再直接加载任何具体服务的 DLL
-- ============================================================ 游戏适配层（v0.23.0，HANDOVER §59）
-- 直接调游戏的代码在同目录的 pbz_game.lua。和 pbz_abilities 一样靠 UE4SS 放进 package.path 的 Scripts 目录 require；
-- 万一 require 不到，按上面从 package.path 推出的 ROOT 直接加载（不写死路径）
local G
do
    -- L2（docs/FORNET_LAYERS.md）：适配层 games\pbz\adapter.lua 提供服务 game = { new = pbz_game 的构造函数 }；没有（老布局 / 测试）照旧 require
    local svc = FORNET and FORNET.use and FORNET.use("game")
    local ok, mk = true, type(svc) == "table" and svc.new or nil
    if type(mk) ~= "function" then ok, mk = pcall(require, "pbz_game") end
    if not (ok and type(mk) == "function") then
        out("!! require pbz_game 失败（%s），改从 %s 加载", tostring(mk), (((FORNET or {}).GAME_DIR or (ROOT .. "/Scripts")) .. "/pbz_game.lua"))
        mk = dofile((((FORNET or {}).GAME_DIR or (ROOT .. "/Scripts")) .. "/pbz_game.lua"))
    end
    G = mk({ out = out, ST = ST, NET = NET, MATCH = MATCH, PLACE_DIST = PLACE_DIST, NET_DIR = NET_DIR,
             logFlush = LOGBUF.flush })     -- §386 钩子回调里"进入 / 读参数"要立刻落盘（mp_probe.log 是攒着写的）
end
-- 下面这些名字和搬家前一样，调用处不用改
local full, pathOf, valid, try, rawProp, shortName, short, sameObj = G.full, G.pathOf, G.valid, G.try, G.rawProp, G.shortName, G.short, G.sameObj
local fnameStr, eachArr, getP1PC, getP1, puppet, gstat, now, attrSetOf = G.fnameStr, G.eachArr, G.getP1PC, G.getP1, G.puppet, G.gstat, G.now, G.attrSetOf
local attrOf, hpOf, setAttr, ascOf, factionComp, factionValue, factionName, anyToStr = G.attrOf, G.hpOf, G.setAttr, G.ascOf, G.factionComp, G.factionValue, G.factionName, G.anyToStr
local montageOf, montageByName, playOn, tagsOf, activeAbilities, setYaw, facePlayer, placeInFront = G.montageOf, G.montageByName, G.playOn, G.tagsOf, G.activeAbilities, G.setYaw, G.facePlayer, G.placeInFront
local setBraking, equipWeapon, mapName, stateComp, tagReport, noStealthByGE, removePuppet, createPuppet = G.setBraking, G.equipWeapon, G.mapName, G.stateComp, G.tagReport, G.noStealthByGE, G.removePuppet, G.createPuppet
local findMonster, NO_STEALTH_TAGS, montages, cutMontage = G.findMonster, G.NO_STEALTH_TAGS, G.montages, G.cutMontage
local lockingTarget, setLockTarget, yawOf = G.lockingTarget, G.setLockTarget, G.yawOf
abilitiesOf = G.abilitiesOf

-- ============================================================ 文件（→ fornet_core.lua，F3）
-- F3（docs/EXTENSIONS.md §10.4）：文件读写 / 命名管道 / 中英文 / PREF 搬到 fornet_core.lua（UE4SS 网络核的第一块）。
-- 这里只装模块、取别名；行为和搬之前一字不差。包一层函数：主代码块的 local 已满 200 个
local FN = (function()
    local ok, mk = pcall(require, "fornet_core")
    if ok and FORNET and FORNET.adopt then mk = FORNET.adopt("fornet_core", mk) end     -- F6：实例登记到宿主（FORNET.mods）
    if not ok then ok, mk = pcall(dofile, ROOT .. "/Scripts/fornet_core.lua") end
    if not (ok and type(mk) == "function") then error("fornet_core.lua 加载失败：" .. tostring(mk)) end
    return mk({ out = out, NET_DIR = NET_DIR, F_LOCAL = F_LOCAL, valid = valid, short = short, pathOf = pathOf,
                zhFont = "/Game/PBZContent/UI/Fonts/ChineseBlackFont.ChineseBlackFont" })     -- 中文字体是影之刃零的，由适配层给
end)()
local fileWrite, fileReadKV = FN.fileWrite, FN.fileReadKV

-- ============================================================ §83 命名管道：游戏 ↔ 联机程序的状态包走内存（→ fornet_core.lua，F3）
-- 全局（主代码块的 local 已满 200 个）；实现在 fornet_core.lua
PIPE = FN.PIPE

-- ============================================================ 身份：谁是玩家1、谁是替身
-- 身份、属性集 / ASC / 阵营 / 动画、标签：v0.23.0 起在 pbz_game.lua（游戏适配层），上面已取成同名的本地名

-- ============================================================ 观察器：动画 / 血量 / 标签的变化

local function pupNote()
    local a = ST.lastPupAction
    if not a then return "" end
    local dt = now() - a.at
    if dt < 0 or dt > 4 then return "" end
    return string.format("  ← 替身 %.1fs 前: %s", dt, a.name)
end

local function watchActor(label, actor, w)
    if not valid(actor) then
        if w.path then out("[%s] 角色失效", label) end
        w.path, w.hp, w.montage, w.shachi, w.abs = nil, nil, nil, nil, nil
        return
    end
    local p = pathOf(actor)
    if w.path ~= p then
        if w.path then out("[%s] 换人了: %s -> %s", label, short(w.path), short(p)) end
        w.path, w.hp, w.montage, w.shachi, w.abs = p, nil, nil, nil, nil
    end

    local m = montageOf(actor)
    if w.montage ~= nil and m ~= w.montage and m ~= "" then
        out("[%s] 动作 %s", label, m)
        -- v0.9.5 曾在这里"从冲刺/闪避/架势动作学武器类别"，实测不可靠：同一把斩马刀冲刺播 AM_Hun_Long_Dash_F、
        -- 闪避播 AM_Hun_Tang_Dodge_R、C 招失败播 AM_Hun_Double_C_Failed，游戏内部动画是混用的。已去掉，只用静态表
    end
    w.montage = m

    local c = hpOf(actor)
    if c ~= nil then
        if w.hp ~= nil and c ~= w.hp then
            out("[%s] ★ 血量 %.1f -> %.1f (%+.1f)%s", label, w.hp, c, c - w.hp,
                label ~= "替身" and pupNote() or "")
        end
        w.hp = c
    end

    -- 杀气（Shachi）= 架势条，弹反/破防会动它
    local sh = attrOf(actor, "Shachi")
    if sh ~= nil then
        -- §89 只记跳变（弹反 / 破防 / 被打空，≥ 10）：架势条每次 -2 的自然回落以前占了日志的一大半（5 分钟 1400 行）
        if w.shachi ~= nil and math.abs(sh - w.shachi) >= 10.0 then
            out("[%s] 杀气 %.0f -> %.0f (%+.0f)", label, w.shachi, sh, sh - w.shachi)
        end
        w.shachi = sh
    end

    -- 2026-11-05 [耗时]（HANDOVER §82.1）：读技能列表要遍历角色全部技能，是驱动里最贵的一步。
    -- 玩家1：发包这一帧已经读过（NET.prevAbs）就直接用；其他角色（替身 / 对照怪，只为写诊断日志）每 15 次驱动读一次
    local act
    if label == "玩家1" and NET.prevAbsTick and NET.prevAbsTick >= ST.ticks - 1 then act = NET.prevAbs   -- §82.4 发包在下一帧：上一次的也算
    -- §82.6 第五局：替身 / 对照怪每次读全部技能 ~10 ms 一个尖峰，只为写"+技能"日志 → 不读了；玩家1 没有发包数据时只看招式
    elseif label == "玩家1" then act = activeAbilities(actor, NET.wantAb) end
    if act then
        if w.abs then
            local add, del = {}, {}
            for t in pairs(act) do if not w.abs[t] then add[#add + 1] = t end end
            for t in pairs(w.abs) do if not act[t] then del[#del + 1] = t end end
            if #add > 0 then out("[%s] +技能 %s", label, table.concat(add, " ")) end
            if #del > 0 then out("[%s] -技能 %s", label, table.concat(del, " ")) end
            if label == "玩家1" and DIAG and DIAG.JDIAG then        -- §223.8 鬼魅闪身诊断：玩家自己放出来时记下标签 / 技能来源
                for _, t in ipairs(add) do if t == DIAG.JDIAG.NAME then pcall(DIAG.JDIAG.me, actor) end end
            end
            if label == "玩家1" and DIAG and DIAG.XACT then pcall(DIAG.XACT.onMine, add) end      -- §229 我出攻击时看替身收没收到闪避帧
        end
        w.abs = act
    end
end

local function hpTraceStep()
    if ST.hpTrace <= 0 then return end
    ST.hpTrace = ST.hpTrace - 1
    local p1, pup = getP1(), puppet()
    local c1, b1 = hpOf(p1)
    local c2, b2 = hpOf(pup)
    local s1 = attrSetOf(p1)
    local line = string.format("玩家1=%s/%s 替身=%s/%s | 玩家1 属性集=%s",
        tostring(c1), tostring(b1), tostring(c2), tostring(b2), short(pathOf(s1)))
    out("血量追踪[%d] %s", 10 - ST.hpTrace, line)
    local sig = tostring(c1) .. "|" .. tostring(c2) .. "|" .. pathOf(s1)
    if ST.hpTraceSeen == nil then
        ST.hpTraceSeen = sig
    elseif ST.hpTraceSeen ~= sig then
        ST.hpTraceSeen = "CHANGED"
    end
    if ST.hpTrace == 0 then
        if ST.hpTraceSeen == "CHANGED" then
            out("✗ 10 秒内读数或对象变过（如果期间你挨打/攻击过，这是正常的，请站着不动重测）")
        else
            out("✓ 10 秒读数完全不变，血量探针可信")
        end
        ST.hpTraceSeen = nil
    end
end

-- ============================================================ §99 悬空等地形加载

-- 2026-11-05 20:33 内测：两人在同一张大地图（PBZ_Xigu_WP）的不同区域，客机连上后被放到主机身边（22009 外）、
-- 替身也被瞬移到主机那边——那片地形在客机这台电脑上还没加载出来，客机"往下掉了 1537"，替身看不见了
-- （掉出世界被引擎藏起来，重新连一次走"替身复用"才重新显示）。
-- 做法：跳得远（> FAR）或者替身在对方站在地上时往下掉了 DROP 以上 → 放回落点、悬空（G.hover，不受重力）；
-- 每 TRY 秒放回走路试一次，再往下掉就再悬空；落地站住 OK 秒算地形到了；最多 MAX 秒。
-- pos 可以是坐标，也可以是返回坐标的函数（替身跟着对方现在的网络位置）
-- 全局（主代码块的 local 已满 200 个）
-- §168 线上反馈"传送太容易掉虚空"：以前悬空 TRY 秒就放下来试，MAX 秒后不管了直接放手 → 落点下面真没地（两边存档进度不同、
-- 主机脚下在你这边是空的 / 悬崖边）就一直掉。现在放下来之前先探地（G.floorBelow 往下 DEPTH 打射线）：
--   下面没地 → 接着悬空；hold 时给了 alts（旁边的备选点）就看备选点有没有地，有就换过去；
--   MAX 秒还没地、给了 back（传送前站稳的地方）→ 放回 back 再等一轮；back 也没地才按以前放手。
--   探地用不了（nil）或者 GROUND 发现探地对脚下站着的地也说没有（noFloor）→ 按以前的做法
HOV = { list = {}, FAR = 5000.0, DROP = 300.0, TRY = 1.0, OK = 1.5, MAX = 30.0, DEPTH = 1000.0, logs = 0, n = 0, unhid = 0 }

-- 探地：true / false / nil（不知道）。noFloor = 探地不可信，一律当不知道
function HOV.floor(actor, p, depth)
    if HOV.noFloor or not (G.floorBelow and p) then return nil end
    return G.floorBelow(actor, p, depth or HOV.DEPTH)
end

function HOV.posOf(e)
    if type(e.pos) == "function" then return e.pos() end
    return e.pos
end

function HOV.has(actor)
    return valid(actor) and HOV.list[pathOf(actor)] ~= nil
end

function HOV.log(fmt, ...)
    HOV.logs = HOV.logs + 1
    if HOV.logs <= 40 then out(fmt, ...) end
end

-- 放到 pos（抬高 20）并悬空。opt（§168，可不给）：back = 等不到地时放回的点；alts = 落点没地时换过去的备选点
function HOV.hold(actor, pos, why, tn, opt)
    if not valid(actor) then return end
    local key = pathOf(actor)
    local e = HOV.list[key]
    if not e then
        e = { actor = actor, pos = pos, why = why, since = tn, tries = 0, back = opt and opt.back, alts = opt and opt.alts }
        HOV.list[key] = e
        HOV.n = HOV.n + 1
    end
    local p = HOV.posOf(e)
    if p then pcall(function() actor:K2_SetActorLocation({ X = p.X, Y = p.Y, Z = p.Z + 20.0 }, false, {}, true) end) end
    G.hover(actor, true)
    e.flying, e.next, e.okAt = true, tn + HOV.TRY, nil
    HOV.log("%s：先悬空等地形加载（第 %d 次放回）", why, e.tries + 1)
end

-- 每次驱动调
function HOV.step(tn)
    for key, e in pairs(HOV.list) do
        if not valid(e.actor) then
            HOV.list[key] = nil
        elseif tn - e.since > HOV.MAX and e.back then
            -- §168 落点等了 MAX 秒还没站住：放回传送前站稳的地方（那里一定有地），再等一轮
            local b = e.back
            e.pos, e.back, e.alts, e.since, e.tries = b, nil, nil, tn, 0
            HOV.log("!! %s：%.0f 秒了落点下面还是没地（那里在你的世界里可能是虚空），放回传送前站的地方 (%.0f, %.0f, %.0f)",
                e.why, HOV.MAX, b.X, b.Y, b.Z)
            e.why = e.why .. "（放回原处）"
            HOV.hold(e.actor, b, e.why, tn)
        elseif tn - e.since > HOV.MAX then
            HOV.list[key] = nil
            G.hover(e.actor, false)
            HOV.log("!! %s：%.0f 秒了地形还是没站住，不再悬空（放回 %d 次）", e.why, HOV.MAX, e.tries)
        elseif e.flying then
            if tn >= e.next then
                -- §168 下面没地就先别放下来；有备选点有地就换过去
                local p = HOV.posOf(e)
                local fl = HOV.floor(e.actor, p)
                if fl == false and e.alts then
                    for _, a in ipairs(e.alts) do
                        if HOV.floor(e.actor, a) == true then
                            e.pos, fl = a, true
                            pcall(function() e.actor:K2_SetActorLocation({ X = a.X, Y = a.Y, Z = a.Z + 20.0 }, false, {}, true) end)
                            HOV.log("%s：落点下面没地，换到旁边有地的点 (%.0f, %.0f, %.0f)", e.why, a.X, a.Y, a.Z)
                            break
                        end
                    end
                end
                if fl == false then
                    e.next = tn + HOV.TRY
                    if not e.saidNoFloor then
                        e.saidNoFloor = true
                        HOV.log("%s：落点下面还没有地，接着悬空", e.why)
                    end
                else
                    G.hover(e.actor, false)
                    e.flying, e.okAt = false, tn + HOV.OK
                end
            end
        else
            local loc = try("hov loc", function() return e.actor:K2_GetActorLocation() end)
            local p = HOV.posOf(e)
            if loc and p and loc.Z < p.Z - HOV.DROP then
                e.tries = e.tries + 1
                HOV.hold(e.actor, p, e.why, tn)
            elseif e.okAt and tn >= e.okAt then
                HOV.list[key] = nil
                HOV.log("%s：站住了（用时 %.1f 秒，放回 %d 次）", e.why, tn - e.since, e.tries)
            end
        end
    end
end

-- §168 本机角色最近一次站稳的地方（在地上走、不在悬空、连着 STAND 秒）：传送后落点没地 / 掉下去时放回这里。
-- 换地图就作废（GROUND.get 按地图名取）。站稳时每 CHECK 秒顺便探一次脚下：探地说"没地"= 探地不可信（射线打不到这游戏的地面），
-- HOV.noFloor 关掉所有探地判断，按以前只看高度
GROUND = { last = nil, map = nil, since = nil, STAND = 1.0, CHECK = 5.0, checkAt = 0.0, ok = 0 }

function GROUND.step(p1, tn)
    if tn < (GROUND.nextAt or 0) then return end
    GROUND.nextAt = tn + 0.25
    if not valid(p1) or HOV.has(p1) or BASEHOOK.otherScene() then GROUND.since = nil; return end
    local st = G.airOf(p1)
    if not st or st.falling or (st.mode and st.mode ~= 1 and st.mode ~= 2) then GROUND.since = nil; return end
    local loc = try("ground loc", function() return p1:K2_GetActorLocation() end)
    if not loc then return end
    if not GROUND.since then GROUND.since = tn; return end
    if tn - GROUND.since < GROUND.STAND then return end
    GROUND.last, GROUND.map = { X = loc.X, Y = loc.Y, Z = loc.Z }, mapName(p1)
    if not HOV.noFloor and tn >= GROUND.checkAt then
        GROUND.checkAt = tn + GROUND.CHECK
        local fl = HOV.floor(p1, loc, 400.0)
        if fl == false then
            HOV.noFloor = true
            out("!! 地面探测对脚下站着的地也说没地，不可信，传送防虚空退回只看高度（%.0f, %.0f, %.0f）", loc.X, loc.Y, loc.Z)
        elseif fl == true and GROUND.ok == 0 then
            GROUND.ok = 1
            out("地面探测可用（脚下有地）")
        end
    end
end

function GROUND.get(map)
    if GROUND.last and GROUND.map == map then return { X = GROUND.last.X, Y = GROUND.last.Y, Z = GROUND.last.Z } end
    return nil
end

-- 悬空时跟着的"对方网络位置"。§223 观战替身（PEER.run 里）：记住是哪个替身，之后 HOV.step 在外面读也读它自己那份
function HOV.netPos()
    if PEER.on and PEER.cur then
        local st = PEER.cur
        return function() return (PEER.cur == st and NET.pos) or (st.m.NET and st.m.NET.pos) end
    end
    return function() return NET.pos end
end

-- 替身：每次驱动后看一眼。对方在地上（不在空中）、替身却比对方的网络位置低 DROP 以上还在往下掉 → 悬空跟着对方；
-- 被引擎藏起来了（掉出世界）→ 重新显示
function HOV.watchPuppet(pup, tn, remoteAir)
    if ST.ticks % 15 == 0 and G.unhide(pup) then
        HOV.unhid = HOV.unhid + 1
        if HOV.unhid <= 10 then out("!! 替身被引擎藏起来了（掉出世界？），重新显示（第 %d 次）", HOV.unhid) end
    end
    if remoteAir or not NET.pos or HOV.has(pup) then return end
    local st = G.airOf(pup)
    if not (st and st.falling) then return end
    local loc = try("hov pup", function() return pup:K2_GetActorLocation() end)
    if loc and loc.Z < NET.pos.Z - HOV.DROP then
        HOV.hold(pup, HOV.netPos(), "替身往下掉（对方站在地上，这里地形没加载？）", tn)
    end
end

-- ============================================================ 替身移动

-- §128 替身出招冲过头（用户 2026-11-06 22:2x："对方在我本地瞬间移动好几次，他本地一直在原地附近"）。
-- 日志：对方乱影 P2_B / BB / BBB、白影 B 系（前冲大），lk=0（对方没硬锁你，替身没有目标）。对方那边前冲会被他的目标挡住 /
-- 动作扭曲到目标跟前，替身这边没目标就按动画整段冲出去；出招 ATK_HOLD 秒内又不纠正位置，招完再按 1400 追回 → 来回"闪现"。
-- 做法：出招中替身离网络位置超过 LEAD、而且还在往远处走（速度背离网络位置）→ 动画根运动位移倍数置 0（动作照播、人不再冲）；
-- 招结束或回到 LEAD 一半以内恢复 1。对方真冲远了，网络位置跟着走，差距不涨，不会触发
RMS = { LEAD = 200.0, cur = 1.0, n = 0, logs = 0, LOG_MAX = 20 }
RMS.set = G.rootMotionScale

-- 返回这一帧要的倍数（纯计算，测试用）。away = 替身速度背离网络位置
function RMS.want(cur, attacking, dist, away)
    if not attacking then return 1.0 end
    if cur >= 1.0 then return (dist > RMS.LEAD and away) and 0.0 or 1.0 end
    return dist < RMS.LEAD * 0.5 and 1.0 or 0.0
end

function RMS.step(pup, attacking, dist, dx, dy, cmv)
    local away = false
    if attacking and dist > RMS.LEAD and valid(cmv) then
        pcall(function() local v = cmv.Velocity; away = v.X * dx + v.Y * dy < 0 end)
    end
    if RMS.pup ~= pathOf(pup) then RMS.pup, RMS.cur = pathOf(pup), 1.0 end   -- 换了替身：新的一个是 1
    local w = RMS.want(RMS.cur, attacking, dist, away)
    if w == RMS.cur then return end
    local ok = RMS.set(pup, w)
    RMS.cur = w
    if w == 0.0 then RMS.n = RMS.n + 1 end
    if RMS.logs < RMS.LOG_MAX then
        RMS.logs = RMS.logs + 1
        out(w == 0.0 and "替身出招冲过头：离网络位置 %.0f 还在往外走，停住前冲（第 %d 次，%s）"
            or "替身前冲恢复：离网络位置 %.0f（第 %d 次，%s）", dist, RMS.n, ok and "成功" or "失败")
    end
end

-- §128.1 "全程跟网络位置"模式（用户 2026-11-06："做。带开关"；急停急转时的小拉回可以接受，"就跟回滚一个道理"）。
-- 替身任何时候都关掉动画位移（根运动倍数 0，动作照播），位置只跟对方发来的坐标：驱动（约 30 次 / 秒）算目标 =
-- 对方位置 + 速度 × 包龄（急转时不外推），每帧再按速度接着往前推、把替身平滑拉过去（每秒补 K 倍误差），差 SNAP 以上
-- 直接放（对方真瞬移）；高度交给重力 / 起跳，差 Z_SNAP 以上且对方不在空中才摆。跑步动画照旧靠 drivePuppet 设的速度 + 摇杆。
-- §128.2 开关改成房间设置 npos（主机定、客机跟，NET.flagNow；默认开 = 这个模式）。net/follow.txt 留作测试用的强制覆盖：
-- 写 anim / net 就不管房间设置；没有文件 = 按房间设置。文件每 2 秒读一次
NPM = { K = 14.0, SNAP = 600.0, Z_SNAP = 300.0, EXTRA_MAX = 0.25, STALE = 0.5, mode = "net", readAt = -1, logs = 0 }
NPM.FILE = NET_DIR .. "/follow.txt"
-- §436 高度（11-24 庞镇观战：对方站在房顶上，替身一半在屋顶下面）。以前高度全交给替身自己的移动组件，只有差 Z_SNAP（3 米）
-- 以上才摆：XY 每帧是"不扫碰撞"直接放的，对方跳上 1–3 米的房顶时替身 XY 进了屋子、高度还在街上，移动组件迈不上去
-- （台阶上限几十厘米）→ 一直卡在屋顶里，差不到 3 米永远不纠正。现在：对方不在空中、替身也不在空中，高度差 Z_FIX 以上
-- 连着 Z_FIX_SEC 秒 → 摆到包里的高度（同类角色，胶囊一样高，站平地时两边高度一致；走坡 / 台阶的包延迟差不到这么多）。
-- 对方在做场景互动动作（trv= 还在播，NET.rtrv）→ 替身先悬空（不受重力），高度每帧和 XY 一样平滑跟包，播完放回走路
NPM.Z_FIX, NPM.Z_FIX_SEC, NPM.TRV_HOLD, NPM.zLogs, NPM.Z_LOG_MAX = 90.0, 0.3, 0.5, 0, 20
-- §436.2 我在观战（多人房出局 / 只看 = 多人 mod 的 specView.on；旧观战 mod = ST.spec.on）。11-24 双开：包龄 100–180 毫秒，
-- 按包龄外推（最多 EXTRA_MAX 0.25 秒）时对方一停，替身按停之前的速度多跑 1–2 米再拉回来，观战镜头跟着前后晃
NPM.WATCH_EXTRA = 0.06
function NPM.watching()
    local mp = BASEHOOK.mp
    local v = type(mp) == "table" and mp.specView or nil
    return (type(v) == "table" and v.on == true) or (ST.spec ~= nil and ST.spec.on == true) or false
end

-- 每帧的高度（纯计算，测试用）。cur / pz = 替身现在的高度 / 包里的高度；rair = 对方在空中；trav = 对方在做场景动作；
-- pupFalling = 替身自己在不在空中（只在要摆的时候才问，函数）；offAt = 上次开始差得多的时刻。
-- 返回 新高度, 是否直接放, 新的 offAt, 原因（nil / "trav" / "snap" / "fix"）
function NPM.stepZ(cur, pz, dt, tn, rair, trav, offAt, pupFalling)
    if not pz then return cur, false, nil, nil end
    local dz = pz - cur
    if trav then
        if math.abs(dz) > NPM.Z_SNAP then return pz, true, nil, "snap" end
        return cur + dz * math.min(1.0, NPM.K * math.max(dt, 0)), false, nil, "trav"
    end
    if rair == true then return cur, false, nil, nil end
    if math.abs(dz) > NPM.Z_SNAP then return pz + 20.0, true, nil, "snap" end
    if math.abs(dz) <= NPM.Z_FIX then return cur, false, nil, nil end
    offAt = offAt or tn
    if tn - offAt < NPM.Z_FIX_SEC then return cur, false, offAt, nil end
    if pupFalling and pupFalling() then return cur, false, nil, nil end      -- 替身自己正落下来（起跳的弧）：交给重力
    return pz + 5.0, true, nil, "fix"
end

function NPM.parse(text)
    local w = (tostring(text or "")):match("^%s*(%a+)")
    return (w == "anim" or w == "net") and w or nil
end

function NPM.readMode(tn)
    if PEER.on then NPM.mode = "net"; return "net" end      -- §223.2 观战替身：一律严格跟随（观战看的是两人的真实位置，用户 11-09 确认）
    if tn >= NPM.readAt then
        NPM.readAt = tn + 2.0
        NPM.override = nil
        local f = io.open(NPM.FILE, "r")
        if f then NPM.override = NPM.parse(f:read("*l")); f:close() end
    end
    -- §226 本地 AI：它的位置是联机程序编的（站你前方 4 米、出招不挪），全程跟网络位置 = 冲刺 / 位移招原地打空气
    -- （内测 11-11："AI 打我的时候原地卡住自己，位移招式过不来"）。对 AI 一律动画带位移（§128 冲过头 2 米停住照旧）
    local m = (TRAINCTX and TRAINCTX.stay()) and "anim"     -- §456 木桩：除了第 1 回合倒计时归位那一下，都站在原地
        or NPM.override or ((NET.flagNow("npos") and not NET.rai) and "net" or "anim")
    if m ~= NPM.mode or not NPM.told then
        NPM.told = true
        out("替身跟随方式：%s（%s）", m == "net" and "全程跟网络位置（动画不带位移）" or "动画带位移（冲过头 2 米停住）",
            NPM.override and "net/follow.txt 强制" or (NET.rai and "对手是本地 AI" or "房间设置"))
        if NPM.mode == "net" and m == "anim" and valid(RMS.pupObj) then RMS.set(RMS.pupObj, 1.0); RMS.cur = 1.0 end
    end
    NPM.mode = m
    return m
end

function NPM.on() return NPM.mode == "net" end

-- 驱动时记下这一包算出的目标（位置、速度、时刻），每帧从它往前推
function NPM.setTarget(pup, pos, vel, tn, noExtra, rair, trav)
    NPM.pup, NPM.pos, NPM.vel, NPM.at, NPM.noExtra, NPM.rair, NPM.trav = pup, pos, vel, tn, noExtra, rair, trav == true
end

-- 每帧：这一刻该在的 XY（纯计算，测试用）
function NPM.aim(tn)
    local p, v = NPM.pos, NPM.vel or {}
    if NPM.noExtra then return { X = p.X, Y = p.Y } end
    local a = math.min(math.max(tn - NPM.at, 0), NPM.extraMax or NPM.EXTRA_MAX)
    return { X = p.X + (v.X or 0) * a, Y = p.Y + (v.Y or 0) * a }
end

-- 每帧：从 cur 往 aim 走一步（纯计算）。返回 新 XY, 是否直接放
function NPM.stepXY(cur, aim, dt)
    local dx, dy = aim.X - cur.X, aim.Y - cur.Y
    if dx * dx + dy * dy > NPM.SNAP * NPM.SNAP then return { X = aim.X, Y = aim.Y }, true end
    local k = math.min(1.0, NPM.K * math.max(dt, 0))
    return { X = cur.X + dx * k, Y = cur.Y + dy * k }, false
end

function NPM.frame()
    if not NPM.on() or not NPM.pos or REP.on then return end
    local pup, tn = NPM.pup, now()
    if not valid(pup) or tn - NPM.at > NPM.STALE then return end
    local dt = NPM.lastFrame and (tn - NPM.lastFrame) or 0.016
    NPM.lastFrame = tn
    local cur = try("pup loc", function() return pup:K2_GetActorLocation() end)
    if not cur then return end
    local xy, snap = NPM.stepXY(cur, NPM.aim(tn), dt)
    if snap and PHEAL.young(pup) and (xy.X - cur.X) ^ 2 + (xy.Y - cur.Y) ^ 2 > HOV.FAR ^ 2 then return end   -- §162 刚造的先别扔远处
    -- §436 场景动作期间悬空（高度跟包），播完放回走路（悬空等地形加载的 HOV 自己管，不动它）
    -- （NPM 每个替身一份（PEER.GLOB），travFly 记的就是这个替身自己）
    local trav = NPM.trav == true and not HOV.has(pup)
    if trav and not NPM.travFly then
        NPM.travFly = true
        G.hover(pup, true)
    elseif not trav and NPM.travFly then
        NPM.travFly = nil
        if not HOV.has(pup) then G.hover(pup, false) end
    end
    local xySnap = snap
    local z, zSnap, why
    z, zSnap, NPM.zOffAt, why = NPM.stepZ(cur.Z, NPM.pos.Z, dt, tn, NPM.rair, trav, NPM.zOffAt, function()
        local st = G.airOf(pup)
        return st ~= nil and st.falling == true
    end)
    if zSnap then snap = true end
    if why == "fix" and NPM.zLogs < NPM.Z_LOG_MAX then
        NPM.zLogs = NPM.zLogs + 1
        out("%s替身高度和对方差 %.0f 超过 %.1f 秒，摆到包里的高度（第 %d 次）：%.0f → %.0f（被卡在屋顶 / 台阶下？）；动作 %s",
            PEER.on and PEER.cur and ("观战 " .. tostring(PEER.cur.tag) .. " ") or "", NPM.pos.Z - cur.Z, NPM.Z_FIX_SEC, NPM.zLogs,
            cur.Z, z, montageOf(pup))
    end
    pcall(function() pup:K2_SetActorLocation({ X = xy.X, Y = xy.Y, Z = z }, false, {}, snap) end)
    if (xySnap or why == "snap") and NPM.logs < 20 then
        NPM.logs = NPM.logs + 1
        -- §223 记全（11-10 观战一次偏差 60 米，当时日志看不出是包里的位置跳了还是外推推飞了）
        local v = NPM.vel or {}
        out("%s替身跟网络位置：差太远直接放过去（第 %d 次）：偏差 %.0f；(%.0f, %.0f, %.0f) → (%.0f, %.0f, %.0f)；包 (%.0f, %.0f) 速度 (%.0f, %.0f) 包龄 %.2f 秒%s；动作 %s",
            PEER.on and ("观战 " .. PEER.cur.tag .. " ") or "", NPM.logs,
            math.sqrt((xy.X - cur.X) ^ 2 + (xy.Y - cur.Y) ^ 2), cur.X, cur.Y, cur.Z, xy.X, xy.Y, z, NPM.pos.X, NPM.pos.Y,
            v.X or 0, v.Y or 0, tn - NPM.at, NPM.noExtra and "（不外推）" or "", montageOf(pup))
    end
end

-- 速度匹配跟随：v = 目标速度 + 3 × 位置误差（交接文档 §3.8）
local function drivePuppet(pup, pos, vel, yaw)
    local cur = try("pup loc", function() return pup:K2_GetActorLocation() end)
    if not cur then return end
    if TRAINCTX and TRAINCTX.stay() and not (PEER and PEER.on) then     -- §456 木桩只在第 1 回合倒计时归位
        ST.feedLeft, ST.lagSince = 0, nil
        if RMS.pup ~= pathOf(pup) or RMS.cur ~= 1.0 then
            RMS.pup, RMS.cur = pathOf(pup), 1.0
            RMS.set(pup, 1.0)
        end
        setYaw(pup, yaw)
        return 0
    end
    local dx, dy = pos.X - cur.X, pos.Y - cur.Y
    local dist = math.sqrt(dx * dx + dy * dy)
    -- v0.15.0 实测：只把速度写成 1400 没用，移动组件按 MaxWalkSpeed 截断，替身一直落后 7~8 米、刀全打空。
    -- 每个替身第一次驱动时把最大跑速 / 加速度提上去
    local cmv = rawProp(pup, "CharacterMovement")
    if valid(cmv) and ST.speedFor ~= pathOf(pup) then
        ST.speedFor = pathOf(pup)
        local mws, macc = rawProp(cmv, "MaxWalkSpeed"), rawProp(cmv, "MaxAcceleration")
        pcall(function() cmv.MaxWalkSpeed = math.max(tonumber(mws) or 0, CATCHUP_SPEED) end)
        pcall(function() cmv.MaxAcceleration = math.max(tonumber(macc) or 0, 6000.0) end)
        out("替身移动上限：MaxWalkSpeed %s -> %s，MaxAcceleration %s -> %s", tostring(mws), tostring(rawProp(cmv, "MaxWalkSpeed")),
            tostring(macc), tostring(rawProp(cmv, "MaxAcceleration")))
    end
    -- 落后超过 LAG_DIST 持续 LAG_SEC 秒（被地形卡住、追不上）也直接摆过去
    local attacking = ST.pupAtkAt and now() - ST.pupAtkAt < ATK_HOLD
    RMS.pupObj = pup
    if NPM.on() then                                -- §128.1 全程跟网络位置：动画不带位移，位置由 NPM.frame 每帧放
        if RMS.pup ~= pathOf(pup) or RMS.cur ~= 0.0 then
            RMS.pup, RMS.cur = pathOf(pup), 0.0
            local ok, how = RMS.set(pup, 0.0)      -- §167.9 以前不看返回值，观战那边发现会失败：记一次
            if RMS.logs < RMS.LOG_MAX then RMS.logs = RMS.logs + 1; out("替身全程跟网络位置：根运动关 %s（%s）", ok and "成功" or "失败", tostring(how)) end
        end
        attacking = false                           -- 不再有"出招中不纠正"
    else
        RMS.step(pup, attacking, dist, dx, dy, cmv)     -- §128 出招冲过头就停住前冲
    end
    if dist > LAG_DIST and not attacking then ST.lagSince = ST.lagSince or now() else ST.lagSince = nil end
    local stuck = ST.lagSince and now() - ST.lagSince > LAG_SEC
    -- v0.15.0 用户反馈"旁路过一段时间瞬移一次"：旧版误差超过 400 就直接摆过去。误差主要来自替身自己出招的前冲（根运动）
    -- 和被你砍中时的击退，400 很容易超。改成 900 才瞬移（并记日志），200 以上用更高的追赶速度慢慢追回去
    if attacking and dist > SNAP_DIST and dist <= SNAP_ATK then
        ST.heldSnaps = (ST.heldSnaps or 0) + 1
        if not ST.holdLogAt or now() - ST.holdLogAt > 2.0 then
            ST.holdLogAt = now()
            out("替身出招中，离网络位置 %.0f，先不瞬移（出招后 %.1f 秒内 > %.0f 才瞬移；第 %d 次）", dist, ATK_HOLD, SNAP_ATK, ST.heldSnaps)
        end
    elseif dist > HOV.FAR and PHEAL.young(pup) then
        return dist     -- §162 刚造的替身先在你身边待 WARM 秒，再瞬移到远处
    elseif dist > (attacking and SNAP_ATK or SNAP_DIST) or stuck then
        ST.lagSince = nil
        pcall(function() pup:K2_SetActorLocation({ X = pos.X, Y = pos.Y, Z = pos.Z + 20.0 }, false, {}, true) end)
        setYaw(pup, yaw)
        -- §99 跳到远处：那片地形可能还没加载，先悬空跟着对方的网络位置
        if dist > HOV.FAR then HOV.hold(pup, HOV.netPos(), "替身瞬移到远处", now()) end
        ST.snaps = (ST.snaps or 0) + 1
        if not ST.snapLogAt or now() - ST.snapLogAt > 2.0 then
            ST.snapLogAt = now()
            out("替身瞬移校正 #%d：本机位置离网络位置 %.0f（%s）", ST.snaps, dist,
                stuck and string.format("落后 > %.0f 已 %.0f 秒", LAG_DIST, LAG_SEC)
                or string.format(attacking and "出招中 > %.0f" or "> %.0f", attacking and SNAP_ATK or SNAP_DIST))
        end
        return dist
    end
    local vx = (vel and vel.X or 0.0) + dx * 3.0
    local vy = (vel and vel.Y or 0.0) + dy * 3.0
    local sp = math.sqrt(vx * vx + vy * vy)
    local cap = dist > 200.0 and CATCHUP_SPEED or MAX_SPEED
    if sp > cap then vx, vy = vx / sp * cap, vy / sp * cap end
    if dist < 12.0 and math.abs(vel and vel.X or 0) + math.abs(vel and vel.Y or 0) < 30.0 then
        vx, vy = 0.0, 0.0
    end
    local cm = rawProp(pup, "CharacterMovement")
    if valid(cm) then
        local vz = 0.0
        pcall(function() vz = cm.Velocity.Z end)
        pcall(function() cm.Velocity = { X = vx, Y = vy, Z = vz } end)
    end

    -- 喂"摇杆"：让移动组件产生加速度，动画蓝图才会播跑步（只写 Velocity 会平移）。
    -- 位置仍由上面的 Velocity 精确控制；输入大小按目标速度 / 跑步速度(JogSpeed=600) 折算
    local sp2 = math.sqrt(vx * vx + vy * vy)
    if sp2 > 30.0 then
        if valid(ST.secondPC) and ST.inputOpenFor ~= pathOf(pup) then
            ST.inputOpenFor = pathOf(pup)
            pcall(function() ST.secondPC:ResetIgnoreMoveInput() end)   -- 旧版本造的替身是关着的
        end
        -- v0.8.2 实测：只在这里（33ms 一次）喂输入，替身跑步"像连点前进一样抖"——
        -- 移动组件每帧都会消耗并清空输入，游戏 60+ 帧时大部分帧没有输入。
        -- 改成把方向交给每帧循环 feedInputEveryFrame 持续喂，这里只更新方向和力度
        ST.feed = { pup = pup, dir = { X = vx / sp2, Y = vy / sp2, Z = 0.0 }, scale = math.min(1.0, sp2 / 600.0) }
        ST.feedLeft = 12      -- 主循环停更 12 帧（约 0.2 秒）后自动松开摇杆
    else
        ST.feedLeft = 0
    end
    if valid(cm) and ST.ticks % 150 == 0 and sp2 > 30.0 then     -- §89 每 1 秒 → 每 5 秒（诊断行）
        local ax, ay, cvx, cvy = 0, 0, 0, 0
        pcall(function() local a = cm:GetCurrentAcceleration(); ax, ay = a.X, a.Y end)
        pcall(function() cvx, cvy = cm.Velocity.X, cm.Velocity.Y end)
        out("替身驱动 | 目标速度 %.0f 实际速度 %.0f 加速度 %.0f 输入 %.2f 每帧喂输入=%s",
            sp2, math.sqrt(cvx * cvx + cvy * cvy), math.sqrt(ax * ax + ay * ay), math.min(1.0, sp2 / 600.0),
            tostring(ST.feedLoop == true))
    end
    setYaw(pup, yaw)
    return dist
end

local function pupAction(name, how)
    local tn = now()
    ST.lastPupAction = { name = name, at = tn }
    if CTRD then CTRD.onPuppet(name, how, tn) end        -- §396 红反链：对方红光反击（替身放出来的）
    if SUMMON.armName and SUMMON.armName(name) then ST.summonArmAt, ST.summonName = now(), name end   -- §94 / §242 接下来几秒找它的召唤物
    out("替身出招 [%s] %s", how, name)
end

-- ============================================================ 武器同步
-- v0.6.5 探针：当前武器存在 CharacterWeaponsComponent.RuntimeWeaponData（Map，读它有崩溃风险），
-- 两次 F2（斩马刀 / 炽刃）之间可读字段完全没变。所以从技能名推断武器：
--   GA_Hun_<族>_*、GA_<族>_* 里的"族" → 存档/数据表里的武器 ID（catalog.json）
-- 换装用 BP_RenewalPlayer_C:"Add Weapon And SwitchTo"(WeaponID:Name, IsNormalWeapon:Bool, SetArmed:Bool, Index:Int)
local WEAPON_OF_FAMILY = {
    ZhanMa = "ZhanMaBlade",   -- 斩马刀
    ChiRen = "Long",          -- 长形黑伤，淬炼后显示炽刃，ID 不变
    HeiMoShang = "Tang",      -- v0.16.0：黑伤淬炼后显示黑魔伤（12:32 日志 GA_Hun_HeiMoShang_A_C），ID 不变
    Tang = "Tang",            -- §155 没淬炼的黑伤是 GA_Hun_Tang_*（11-08 新档：认不出"玩家1 当前武器"，状态包 w= 一直空）
    Double = "Double",        -- v0.16.0：绝影（双刃），12:45 日志 GA_Hun_Double_AA_C / GA_Hun_Double_SWT_C
}
-- 不收 "Long"：GA_Hun_Long_Stance_C（格挡架势）拿斩马刀时也会用，不代表武器

-- 录制/观察到的技能 → 武器 ID。只认三类：普攻连段 GA_Hun_<族>_A.../B...、
-- 切武器 GA_Hun_<族>_SWT_C（实测切到哪把就激活哪把的 SWT）、武器被动 GA_Hun_<族>_Passive_C
local function weaponOfAbility(abilityName)
    local fam, rest = abilityName:match("^GA_Hun_(%w+)_(.+)_C$")
    if not fam or not WEAPON_OF_FAMILY[fam] then return nil end
    if rest:match("^[AB]") or rest == "SWT" or rest == "Passive" then return WEAPON_OF_FAMILY[fam] end
    return nil
end

-- ============================================================ 配装同步 + 替身换装 + 天赋 / 饰品被动同步（→ base_loadout.lua）
LO = BASEPARTS.load("loadout", { ST = ST, NET = NET, MATCH = MATCH, ROOT = ROOT, NET_DIR = NET_DIR, G = G,
    -- 主循环那段会把这几个换成计时包装（PROF.wrap）：传"调用时再取"，和搬出来之前一样
    out = function(...) return out(...) end, activeAbilities = function(...) return activeAbilities(...) end, attrOf = function(...) return attrOf(...) end })

-- ============================================================ 斩马刀吸血补偿（v0.17.7）
-- 亡命斩马刀的吸血"对人偶、金身、幻体无效"，打替身不回血（§21.7）。16:00 单机打怪实测（HANDOVER §37）：
-- 轻击一路（切刀斩 SWT、A / AA / AAA / AAAA）命中回血合计 453.7 / 伤害 10734.3 ≈ 4.2%（分两跳，约 4:1，隔 0.5 秒）；
-- 杀气重击一路（B、AB）不回血。所以对方回报"我的斩马刀轻击命中 X"时，模组给自己回 ZM_HEAL × X
-- §231.1 用户 11-11 定：PvP 里改成伤害的 10%（原按打怪实测 4.2%）
LO.ZM_HEAL = 0.10
-- v0.17.11：名单改按游戏数据：带 Ability.Property.Weapon.ZhanMa.Lifesteal.LightAttack 标签的 13 个技能（IoStore 扫出来的，
-- 和 16:00 实测一致；比旧规则多了 SA 闪身夺血 / PerfectDodge 完美闪避反击 / Air_A_Draw）
LO.ZM_LIFESTEAL = {}
for _, s in ipairs({ "A", "AA", "AAA", "AAAA", "A_Dash", "A_DashDraw", "A_Draw", "A_Snap", "Air_A", "Air_A_Draw",
                     "PerfectDodge", "SA", "SWT" }) do LO.ZM_LIFESTEAL["GA_Hun_ZhanMa_" .. s .. "_C"] = true end
function LO.isZmLight(n)
    return LO.ZM_LIFESTEAL[n] == true
end

-- ============================================================ 受击动作同步（v0.17.11 → v0.18.3 改法）
-- 以前对方判"中招"时替身固定播中等受击（hitNameFor 左右交替），击倒 / 击飞 / 重击都看不出来。
-- v0.17.11 试过 HitreactComponent:ChangeHitState（Phantom Pact 的做法）：17:21 实测只改了状态、不播动作，
-- 替身还一直停在 Normal.Heavy，出招被挡（17:13 那轮大量 返回=false）；PlayHitreactToAvatar 用玩家当攻击来源直接把游戏弄崩了
-- （17:23:27 dump）。现在照破防同步的做法：挨打方把自己**正在播的受击动作名**发过来，攻击方用 playNamed 在替身上播同一个
-- 11.24 悬浮盾：本地 AI 被我的招真正击飞 / 打倒（本机游戏给替身播的）时，判定回来不再拿普通受击盖掉，照原版倒地起身。
-- 以前盖成 Hit_Middle 后 AI 一直站着，悬浮盾第二下（Final）就能再中；真人被击飞起身时会闪掉这一下，在线只中一下（11.23 双开实测）
-- 11.24 木桩复测（d98ca703）：木桩在挡，第一下是破防 AM_Hun_Break_H_F → 破防挣脱 MoTian_Dodge_B_BanBen2（§356 同一组），
-- 也被盖成 Hit_Middle、站着吃了 Final。破防 / 破防挣脱同样是本机游戏自己的反应，一并不盖
-- §428 11-24 名字带受击关键字、其实是出招的动作：虎炮出手 AM_Hun_TigerCannon_Launch_*（游龙头水炮同名）、万钧 AM_Hun_WanJun_Hit_Montage。
-- 以前发送方出手就发 hr=，收方"对方被打断：替身停招"→ 虎炮不蓄力那一炮偶尔没判定（11-24 14:37:31 远端#968 落空）
LO.NOT_HIT = { "Cannon_Launch", "WanJun_Hit_Montage" }
function LO.notHit(m)
    for _, k in ipairs(LO.NOT_HIT) do if m:find(k, 1, true) then return true end end
    return false
end

function LO.isKnockMontage(m)
    if not m or m == "" or LO.notHit(m) then return false end
    for _, k in ipairs({ "Launch", "Lying", "GetUp", "Getup", "Knock", "Break", "MoTian_Dodge" }) do
        if m:find(k, 1, true) then return true end
    end
    return false
end

function LO.isHitMontage(m)
    if not m or m == "" or LO.notHit(m) then return false end
    for _, k in ipairs({ "_Hit_", "Knock", "Launch", "Lying", "GetUp", "Getup", "Hitreact" }) do   -- §143 马车撞飞后起身是 AM_Hun_Unarmed_Getup_F
        if m:find(k, 1, true) then return true end
    end
    return false
end

-- §111 技能里面按键换的动作：紫冥剑按住重击召唤（GA_Hun_ZiMingJian_New_DB_C）按住时每按一下召唤一件武器，
-- Summon_Loop → Summon_JinGua_03 / Summon_Gun_03 / Summon_TieChi_04 … → Summon_End 都在同一个技能里，没有新的 ev=；
-- 替身没人按键，只播 Start 就收招。起手 Start 是替身放技能自己播的，不发
function LO.isSubMontage(m)
    return m ~= nil and m:find("Hun_ZiMing_Summon_", 1, true) == 1 and not m:find("_Start", 1, true)
end

-- §103 喝药动作：AM_Hun_Medicine_LongBlade / _TangBlade / _DoubleBlade……（按手上武器不同，2026-11-05 日志里见过这三个）
-- §265 还有翻滚中喝药 AM_Hun_Tang_Roll_B_Medicine（11-12 玩家日志 18:31:01：武林盟主禁用血瓶，这个没拦住，一口 +1078）。
-- 游戏包里玩家的喝药动作一共 7 个：AM_Hun_Medicine_{Common,DoubleBlade,LongBlade,SnakeDual,TangBlade,Unarmed} + AM_Hun_Tang_Roll_B_Medicine，
-- 所以改成 AM_Hun_ 开头、名字里带 Medicine 都算
function LO.isMedMontage(m)
    return m ~= nil and m:find("AM_Hun_", 1, true) == 1 and m:find("Medicine", 8, true) ~= nil
end

-- §436 场景互动动作（爬墙 / 翻越 / 爬梯 / 贴墙跑 / 跨栏…）。11-24 庞镇观战：对方爬墙，替身只跟着位置挪、没有动作 ——
-- 状态包只发受击 / 喝药 / 闪避 / 技能内动作，这类动作从没发过。资产（utoc 索引）：Hun/Animation/Interface/Wall_Run/UpRunning
-- Hun_Wall_Run_Up_{Low,Middle,High}_{Run,Idle}Start(_Mantle)_Montage、Traversal/Mantle/Hun_Traversal_Mantle_Stand_Lfoot_Montage、
-- SpecialMove/ClimbLadder AM_Hun_Climb_*（+ AM_Hun_Trigger_Ladder）、WallRun Hun_Unarmed_WallRun_*、SideRunning Hun_Unarmed_LedgeRun*、
-- CrossObstacle Hun_CrossOver_*、DownSliding Hun_Unarmed_SlowFall_*、CloudStep、RopeSwing、AdvancedSpecialMove M_Neutral_Traversal_*
-- （同一目录里的 Hun_TangBlade_Att_N_D02 是攻击、Hun_GASP_Run_Stop 是普通急停，名字不带下面的词，不会算进来）
LO.TRV_KEYS = { "Wall_Run", "WallRun", "Traversal", "AM_Hun_Climb", "Trigger_Ladder", "LedgeRun", "CrossOver", "CloudStep",
                "SlowFall", "RopeSwing", "Mantle" }
-- §436.1 11-24 17:51 双开复测：爬墙在观战那边还是不对。日志：房主 17:51:52 播 Hun_Wall_Run_Up_Middle_RunStart_Montage、
-- 17:51:53 才看到技能 GA_SpecialMove_UpRunning_C；收方 :52 照播了动作，:53 又把这个技能当招式让替身放 →"给技能：找不到类"、
-- 返回=false（放招前那套停招 / 换动作把刚播的爬墙动作打断）。资产：GA_SpecialMove_UpRunning(_Base / _Young) 自己播
-- Hun_Wall_Run_Up_{Low,Middle,Height}_RunStart / Hun_CrossOver_02（Run_Low / Run_Middle / Run_Height 三档），整段爬墙就是这个动作。
-- 所以：GA_SpecialMove_* 不当招式发（替身放不出，也不该放）；这类技能挂着时播的动作一律算场景动作（名单外的也发）
function LO.isSpecialMove(n) return type(n) == "string" and n:find("GA_SpecialMove_", 1, true) ~= nil end
function LO.specialMoveOn(act)
    if type(act) ~= "table" then return false end
    for n in pairs(act) do if LO.isSpecialMove(n) then return true end end
    return false
end
function LO.isTraversalMontage(m)
    if type(m) ~= "string" or m == "" or m == "-" then return false end
    for _, k in ipairs(LO.TRV_KEYS) do if m:find(k, 1, true) then return true end end
    return false
end

function LO.zmHeal(p1, atkId, dmg)
    if PEER.on then return end          -- §223 观战：吸血是对战双方自己的事
    local n = NET.evName and NET.evName[atkId]
    if not (n and dmg and dmg > 0 and LO.isZmLight(n)) then return end
    local hp, hm = hpOf(p1), attrOf(p1, "Health_Max")
    if not (hp and hm and hp > 0) then return end
    local heal = math.min(dmg * LO.ZM_HEAL, hm - hp)
    if heal <= 0.5 then return end
    -- §231 直接写 Health 血条不刷新（用户 11-11）：先走游戏的改属性函数（GE_MA_Health_1_Override，§212 实测可用，ASC 广播 → HUD 刷新），
    -- 不行再直接写；换路时记一行
    local ok, msg = false, "没有 attrModSet"
    if G.attrModSet then
        local okC, r1, r2 = pcall(G.attrModSet, p1, "Health", hp + heal)
        if okC then ok, msg = r1, r2 else msg = tostring(r1) end
    end
    if not ok then setAttr(p1, "Health", hp + heal) end
    local way = ok and "改属性函数" or "直接写"
    if LO.zmWay ~= way then LO.zmWay = way; out("斩马刀吸血补偿：改血走%s（%s）", way, tostring(msg)) end
    out("  斩马刀吸血补偿（%s 命中 -%.0f）：+%.1f", n, dmg, heal)
end

-- ============================================================ debuff 图标排查（v0.17.6，排查用，绑 F12）
-- 用户反馈：给对方上 debuff，自己界面上也显示图标，效果似乎没落到自己身上。猜测：替身是玩家同类角色，
-- 自己也带一个 BP_UIGameplayLogicComponent（§28），它把替身身上的状态推到了唯一的 HUD 上。
-- 每按一次走一步：1 给替身上中毒  2 停用替身的 UI 逻辑组件  3 给替身上点燃（对照）
LO.DEBUFF = { "/PBZCombatAsset/Prototypes/GameplayEffects/Inflictions/GE_Poison_Phase1.GE_Poison_Phase1_C",
              "/PBZCombatAsset/Prototypes/GameplayEffects/Inflictions/GE_Ignite.GE_Ignite_C" }

function LO.debuffTest()
    local pup = ST.secondPawn
    if not valid(pup) then out("!! 先按 F12 造替身（或连上对手）"); return end
    LO.dbStep = (LO.dbStep or 0) % 3 + 1
    if LO.dbStep == 1 then
        out("== debuff 排查 1/3：给替身上中毒 ==")
        LO.applyGE(pup, LO.DEBUFF[1], "替身中毒")
    elseif LO.dbStep == 2 then
        local c = LO.uiCompOf(pup)
        out("== debuff 排查 2/3：停用替身的 UI 逻辑组件（%s）==", c and pathOf(c) or "没找到")
        if c then
            local okD = pcall(function() c:Deactivate() end)
            local okT = pcall(function() c:SetComponentTickEnabled(false) end)
            out("  Deactivate %s，关 Tick %s", okD and "成功" or "失败", okT and "成功" or "失败")
        end
    else
        out("== debuff 排查 3/3：给替身上点燃（对照）==")
        LO.applyGE(pup, LO.DEBUFF[2], "替身点燃")
    end
end

-- ============================================================ M1：录制 / 回放
local RECM = BASEPARTS.load("replay", {
    ST = ST, NET = NET, MATCH = MATCH, REC = REC, REP = REP, LO = LO, G = G,
    NET_DIR = NET_DIR, REC_DIR = REC_DIR, REPLAY_DIST = REPLAY_DIST,
    pupAction = pupAction, weaponOfAbility = weaponOfAbility,
    -- 主循环那段会把这几个换成计时包装（PROF.wrap）：传"调用时再取"，和搬出来之前一样
    out = function(...) return out(...) end,
    fileWrite = function(...) return fileWrite(...) end,
    drivePuppet = function(...) return drivePuppet(...) end,
    activeAbilities = function(...) return activeAbilities(...) end,
    montageOf = function(...) return montageOf(...) end,
    attrOf = function(...) return attrOf(...) end,
})

-- ============================================================ §242 等前摇再补放一次
-- 有些招要在"前置动作 / 空中状态"出现之后才放得出（蛇双 R 要短剑先投出去 = Thrown 标签、空中招要真的离地、
-- 冲刺版切刀斩要冲刺技能还在放）。以前是"先放前置，紧接着 fire 目标招"，同一帧前置还没生效 → 还是 false。
-- 这里把目标招排到 0.15–0.25 秒后再走一次 activateOnPuppet（前置动作已经生效）。每次最多排一次：
-- 重试时 how 带"等前摇"，各个前置分支看到它就不再排。全局表（主代码块 local 已满）
-- §245：可带 opt = { cond = 函数, tries = 次数, gap = 秒 }。cond 不看真就不 fire，隔 gap 秒再等一次（最多 tries 次），
-- 用来看"投出去的短剑 Thrown 标签到没到 / 空中 CanAirSnap 到没到 / Snap 的距离够没够"，比固定 0.2 秒可靠。
PRETRY = { q = {}, DELAY = 0.18, LOGS = 30, logs = 0, MAX = 8 }
PRETRY.OFF = (NET_DIR or "net") .. "/pretry_off.txt"
function PRETRY.off()
    local f = io.open(PRETRY.OFF, "r")
    if f then f:close(); return true end
    return false
end
function PRETRY.push(pup, n, sub, how, delay, why, opt)
    if PRETRY.off() then return false end
    if #PRETRY.q >= PRETRY.MAX then table.remove(PRETRY.q, 1) end
    opt = opt or {}
    PRETRY.q[#PRETRY.q + 1] = { pup = pup, n = n, sub = sub, how = how, at = now() + (delay or PRETRY.DELAY),
        why = why or "-", cond = opt.cond, left = math.max(1, tonumber(opt.tries) or 1),
        gap = tonumber(opt.gap) or tonumber(delay) or PRETRY.DELAY }
    return true
end
function PRETRY.waiting(r)
    if not r.cond then return false end
    local ok, yes = pcall(r.cond)
    return ok and yes == true
end
function PRETRY.step(tn)
    if #PRETRY.q == 0 then return end
    local keep = {}
    for _, r in ipairs(PRETRY.q) do
        if tn < r.at then keep[#keep + 1] = r
        elseif valid(r.pup) then
            if r.cond and not PRETRY.waiting(r) and r.left > 1 then
                -- §245 前置条件还没到（Thrown / 空中 / 距离）：不 fire，再等一次
                r.left, r.at = r.left - 1, tn + r.gap
                keep[#keep + 1] = r
                if PRETRY.logs < PRETRY.LOGS then
                    PRETRY.logs = PRETRY.logs + 1
                    out("  §245 等前摇 %s（%s）：条件还没到，再等 %.2f 秒（还剩 %d 次）", r.n, r.why, r.gap, r.left)
                end
            else
                local ok = RECM.activateOnPuppet(r.pup, r.n, r.sub, (r.how or "") .. " 等前摇")
                if PRETRY.logs < PRETRY.LOGS then
                    PRETRY.logs = PRETRY.logs + 1
                    out("  §242 等前摇再放 %s（%s）：%s", r.n, r.why, ok and "放出来了" or "还是放不出")
                end
            end
        end
    end
    PRETRY.q = keep
end

-- ============================================================ 网络（文件邮箱 → sidecar.py → UDP）

-- 协议 v2（纯文本 key=value，一行一个；sidecar.py 原样转发）：
--   v=2 seq=<包序号> map=<地图> x y z yaw vx vy w=<武器ID> ev=<编号:技能名,...>
-- ev 带最近 EV_KEEP 秒内的全部技能事件，每个包都重复发 —— 丢一两个包也不会漏招；接收方按编号去重。
-- v0.6.2 的结论：伤害挂在技能上，所以同步的是"激活了哪个技能"，不是动画。
local EV_KEEP = 1.5

-- 房间设置的"我是客机"判定：除了联机程序写的 role=client，还要看 MATCH.role。
-- session.txt 每 0.5 秒才刷新一次、main.lua 的 lobbyStep 每 30 tick 才读一次，主机的第一个状态包经常比它早 1 帧到 1 秒；
-- followHost 又正好在这个窗口里开局、把 MATCH.dmPct / flags / res / toWin 定死一整场（§243 复测 95 回合全是客机自己的
-- 40% / 武器平衡 / 标准数值；11-11 15:34 / 18:23 / 19:07）。followHost 先设 MATCH.role 再取规则，所以这里的每个取规则
-- 的地方都认 MATCH.role == "client"，不再被 session.txt 的延迟坑；11-11 之前的普通情况（session 已经是 client）不变。
-- v0.25.0 对手血条显示档位（房间设置，HANDOVER §73）：2 = 血量 + 杀气，1 = 只显示血量，0 = 不显示。
-- 主机说了算：主机用自己的设置，客机按主机状态包里的 bar= 走（主机是旧版、没有 bar= → 2，同 v0.24）。
-- 生效档位不到 2 时两边都不发杀气（sh=-1），改模组的客机也拿不到；血量对局要用，照发
NET.BAR_FILE, NET.barCfg, NET.rbar = NET_DIR .. "/oppbar.txt", 2, nil
function NET.barLoad()
    local t = fileReadKV(NET.BAR_FILE)
    local m = t and tonumber(t.bar)
    if m == 0 or m == 1 or m == 2 then NET.barCfg = m end
end
function NET.barSet(m)
    NET.barCfg = m
    fileWrite(NET.BAR_FILE, "bar=" .. m .. "\n")
end
function NET.barMode()
    -- §295 多人房 / 对决：按对局主机的（NET.ruleClient：非多人房 = 原来的判断，多人房 = 不是对局主机）
    if NET.ruleClient and NET.ruleClient() then return NET.rbar or 2 end
    if not NET.ruleClient and (MATCH.role == "client" or (MATCH.session and MATCH.session.role) == "client") then return NET.rbar or 2 end
    return NET.barCfg
end
-- §276（移植 0.33 分支 §269.1）主机下场（§141.8）时两位选手都是客机，以前谁都不开局（两人准备了也不开战）。主机的联机程序转发时给第一位带 rly=h：
-- 第一位代主机开局 / 判回合 / 发 mt=（规矩照收到的包里主机的那份，NET.dmgPct 等客机读法不变），第二位照常跟随。主机回来打（包里没 rly=h 了）就不再代。
-- 解说模式（§236）不走这个：那边主机发 PBZROLE matchhost=1，sessionRole() 直接是 host
function NET.actHost() return (MATCH.session and MATCH.session.role) == "client" and NET.rrly == "h" end
-- v0.26.3 局数（房间设置）：3 / 5 / 7 / 9 局，先赢过半回合者胜。同血条档位：主机定，客机按主机状态包里的 bo= 走
-- （主机是旧版、没有 bo= → 3）。存在 net/bestof.txt（bo=N）
NET.BO_FILE, NET.boCfg, NET.rbo = NET_DIR .. "/bestof.txt", 3, nil
function NET.boValid(n) return n == 3 or n == 5 or n == 7 or n == 9 end   -- 不用 local：主块 local 快到 200 上限
function NET.boLoad()
    local t = fileReadKV(NET.BO_FILE)
    local n = t and tonumber(t.bo)
    if NET.boValid(n) then NET.boCfg = n end
end
function NET.boSet(n)
    NET.boCfg = n
    fileWrite(NET.BO_FILE, "bo=" .. n .. "\n")
end
function NET.boNext(n) return n >= 9 and 3 or n + 2 end     -- 3 → 5 → 7 → 9 → 3
function NET.bestOf()
    local rk = NET.fixedRules()                 -- §110 武林盟主 / 房间固定规则
    if rk then return rk.bo end
    if BASEHOOK.inMp() then
        if NET.ruleClient() then return NET.boValid(NET.rbo) and NET.rbo or 3 end
        return NET.boCfg
    end
    if MATCH.role == "client" or (MATCH.session and MATCH.session.role) == "client" then return NET.boValid(NET.rbo) and NET.rbo or 3 end
    return NET.boCfg
end
function NET.toWin(bo) return math.floor((bo or NET.bestOf()) / 2) + 1 end
-- §86 全局伤害倍率（房间设置，docs/PVP_RULES_DESIGN.md §1）：10 / 20 / 30 / 40 / 50 / 75 / 100 / 150 / 200 / 300%，默认 100（10–40 是 §209 加的）。
-- 伤害由挨打一方的游戏按"替身攻击属性 × 我的防御"算（§30 对 Attack 线性），所以倍率乘在本机替身的 Attack / ShachiAttack 上，
-- 两边各乘各的，对称。同局数：主机定，客机按主机状态包里的 dm= 走（旧版主机没有 dm= → 100）；对局中改设置下一局生效。
-- 存在 net/rules.txt 的 dm= 键；这个文件还放别的规则（ab= 等），读写只动 dm=，别的行原样留着
NET.RULES_FILE, NET.DM_STEPS, NET.dmCfg, NET.rdm = NET_DIR .. "/rules.txt", { 10, 20, 30, 40, 50, 75, 100, 150, 200, 300 }, 100, nil
function NET.dmValid(n)
    for _, v in ipairs(NET.DM_STEPS) do if n == v then return true end end
    return false
end
-- §213 收到 / 读到的倍率按范围认（和武林盟主 rkParse 的 dm 一样 10–1000），不按本机的档位表：
-- 主机加了新档位（如 §209 的 10–40），没升级的客机也照样按主机的数打，不会悄悄退回 100% 变成两边不对称。档位表只管面板上点着换
function NET.dmOk(n) return type(n) == "number" and n == math.floor(n) and n >= 10 and n <= 1000 end
function NET.dmLoad()
    local t = fileReadKV(NET.RULES_FILE)
    local n = t and tonumber(t.dm)
    if NET.dmOk(n) then NET.dmCfg = n end      -- §213 rules.txt 手写的非档位值（如 25）也认
end
function NET.dmSet(n)
    NET.dmCfg = n
    local lines, done, f = {}, false, io.open(NET.RULES_FILE, "r")
    if f then
        for line in (f:read("*a") or ""):gmatch("[^\r\n]+") do
            if line:match("^dm=") then
                if not done then lines[#lines + 1] = "dm=" .. n; done = true end
            else
                lines[#lines + 1] = line
            end
        end
        f:close()
    end
    if not done then lines[#lines + 1] = "dm=" .. n end
    fileWrite(NET.RULES_FILE, table.concat(lines, "\n") .. "\n")
end
function NET.dmNext(n)       -- 10 → 20 → 30 → 40 → 50 → 75 → 100 → 150 → 200 → 300 → 10
    for i, v in ipairs(NET.DM_STEPS) do if v == n then return NET.DM_STEPS[i % #NET.DM_STEPS + 1] end end
    return 100
end
function NET.ruleClient()
    local sm = BASEHOOK.mp
    if sm and sm.inMp and sm.inMp() then
        return not (sm.isHost and sm.isHost())
    end
    return MATCH.role == "client" or (MATCH.session and MATCH.session.role) == "client"
end
function NET.fighting()
    if MATCH.state == "fight" then return true end
    local sm = BASEHOOK.mp
    if sm and sm.fighting and sm.fighting() then return true end
    return false
end
function NET.dmgPct()        -- 房间设置：主机 / 没联机 = 自己的，客机 = 主机的
    local rk = NET.fixedRules()                 -- §110 武林盟主 / 房间固定规则
    if rk then return rk.dm end
    local sm = BASEHOOK.mp
    if sm and sm.inMp and sm.inMp() then
        if NET.ruleClient() then return NET.dmOk(NET.rdm) and NET.rdm or 100 end
        return NET.dmCfg
    end
    if MATCH.role == "client" or (MATCH.session and MATCH.session.role) == "client" then return NET.dmOk(NET.rdm) and NET.rdm or 100 end    -- §213 按范围认
    return NET.dmCfg
end
function NET.dmgNow()        -- 现在交手用的：对局中 = 开局时定下的 MATCH.dmPct，对局外 = 房间设置
    local sm = BASEHOOK.mp
    local inM = MATCH.state ~= "idle" or (sm and sm.inMatch and sm.inMatch())
    if inM and MATCH.dmPct then return MATCH.dmPct end
    return NET.dmgPct()
end
function NET.atkScale(edge)  -- 替身攻击力系数 = 伤害倍率 × 影之武装系数（v0.23.7）
    return NET.dmgNow() / 100 * (edge and LO.EDGE_SCALE or 1.0)
end
-- §147 中招日志带上替身当时的攻击力和系数（孤人 11-07 两边同一招差 4.5 倍，截图看不出是攻击力、系数还是防御）。
-- 对方发来的 Attack = 替身 Attack ÷ 系数；"我"那一项是挨打方自己的攻击力，只用来对照两个号的成长
function NET.pupAtkNote()
    local pup, p1 = puppet(), getP1()
    local a = valid(pup) and attrOf(pup, "Attack")
    local s = valid(pup) and attrOf(pup, "ShachiAttack")
    local m = valid(p1) and attrOf(p1, "Attack")
    local ra = NET.ratt and (NET.ratt:match("^Attack:([%-%d%.e+]+)") or NET.ratt:match(";Attack:([%-%d%.e+]+)"))   -- 别撞上 ShachiAttack
    -- §338 中招这一刻替身攻击力和模组上次写的对不上 = 游戏刚把它改了，这一下可能没压住：日志写明，并标记下一帧重写
    local w = LO.lastWant and LO.lastWant.Attack
    local bad = type(a) == "number" and w and math.abs(a - w) > math.max(0.5, w * 0.01)
    if bad then LO.dirty = LO.dirty or "中招时发现" end
    return string.format("（替身 Attack %s / ShachiAttack %s，系数 ×%.0f%%%s；对方发来 Attack %s；我 Attack %s%s）",
        type(a) == "number" and string.format("%.1f", a) or "?", type(s) == "number" and string.format("%.1f", s) or "?",
        (LO.atkScale or 1) * 100, (LO.scaleWhy and ("：" .. LO.scaleWhy) or "") .. (LO.lvNote and ("；" .. LO.lvNote) or ""),   -- §207.6
        tostring(ra or "?"),
        type(m) == "number" and string.format("%.1f", m) or "?",
        bad and string.format("；!! §338 替身攻击力和模组写的 %.1f 对不上，这一下可能没压住", w) or "")
end
-- §87 全部可格挡（房间设置，docs/PVP_RULES_DESIGN.md §2–§3）：0 关 / 1 开。同局数：主机定，客机按主机状态包里的 ab= 走
-- （主机是旧版、没有 ab= → 关）；开局时定下 MATCH.ab，对局中改设置下一局生效。
-- 存在 net/rules.txt 的 ab= 键：读写只认自己的键，别的键（伤害倍率 dm= 等）原样保留
NET.AB_FILE, NET.abCfg, NET.rab = NET_DIR .. "/rules.txt", 0, nil
function NET.abLoad()
    local t = fileReadKV(NET.AB_FILE)
    local n = t and tonumber(t.ab)
    if n == 0 or n == 1 then NET.abCfg = n end
end
function NET.abSet(n)
    NET.abCfg = n
    local t, keys, lines = fileReadKV(NET.AB_FILE) or {}, {}, {}
    t.ab = tostring(n)
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do lines[#lines + 1] = k .. "=" .. t[k] end
    fileWrite(NET.AB_FILE, table.concat(lines, "\n") .. "\n")
end
function NET.allBlock()
    local sm = BASEHOOK.mp
    local inM = sm and sm.inMatch and sm.inMatch()     -- 只在多人对局中读开局快照；1v1 照旧（1v1 用 MATCH.ab 的地方自己读快照）
    if inM and MATCH.ab ~= nil then return MATCH.ab == 1 or MATCH.ab == true end
    local rk = NET.fixedRules()                 -- §110 武林盟主 / 房间固定规则
    if rk then return rk.ab == 1 end
    if sm and sm.inMp and sm.inMp() then
        if NET.ruleClient() then return NET.rab == 1 end
        return NET.abCfg == 1
    end
    if MATCH.role == "client" or (MATCH.session and MATCH.session.role) == "client" then return NET.rab == 1 end
    return NET.abCfg == 1
end
-- §105.3 / §106.5 开关型房间设置（用户 2026-11-06"红蓝光的反击也做成可设置成关闭""武器平衡可设置开启"），和"全部可格挡"同一套：
--   主机定，客机按主机状态包里的同名键走（主机是旧版、没有这个键 → 默认值）；开局时定下 MATCH.flags，对局中改设置下一局生效；
--   存在 net/rules.txt 的同名键。ctr = 红蓝光反击（完美闪避反击，默认开 = 原版），bal = 武器平衡（默认关 = 原版伤害）
-- §108 med = 血瓶（喝药，默认开 = 原版；用户 2026-11-06"房间设置里可以做不能使用血瓶的功能么"）
-- §128.2 npos = 对手位置严格跟随（开 = §128.1 全程跟网络位置、动画不带位移，默认；关 = 动画带位移 + §128 冲过头停住）。
--   伤害在挨打方本机判、替身位置影响挨不挨打，所以两边要一致（用户 2026-11-06"改成房主设置吧"）；状态包键 npos=
-- §144 std = 标准数值（双方按基准存档的属性 / 天赋 / 30 级武器打，默认关；武林盟主按服务器的 std=，不发就是关，§169）
NET.FLAG_KEYS, NET.FLAG_DEF = { "ctr", "bal", "med", "npos", "std" }, { ctr = 1, bal = 0, med = 1, npos = 1, std = 0 }
NET.flagCfg, NET.rflag = { ctr = 1, bal = 0, med = 1, npos = 1, std = 0 }, {}
-- §144.1 锁住不让开的设置（用户 2026-11-07"完全平衡功能先锁定成不可打开"）：面板不显示、读到 1 也当关、发出去恒为 0
-- §157.2 用户 11-08 解锁标准数值（§157 双开 6 项全过）。机制留着，要再锁哪项就往表里加
NET.FLAG_LOCKED = {}
NET.FLAG_WIRE = { med = "medok" }      -- 状态包里的键名和 rules.txt 不同的（med= 被 §103 喝药动作占了）
NET.FLAG_NAME = { ctr = { "红蓝光反击", "RED/BLUE COUNTERS" }, bal = { "武器平衡", "WEAPON BALANCE" }, med = { "血瓶", "HEALING POTIONS" },
                 npos = { "对手位置严格跟随（关 = 动画带位移）", "STRICT OPPONENT POSITION (OFF = ANIMATION-DRIVEN)" },
                 std = { "标准数值（不计各自养成）", "STANDARD STATS (IGNORE PROGRESSION)" } }
-- §181 作弊数据采样 cs：0.34 整个删了（TASK_0.34 §2.2，HANDOVER §250.2）。旧版状态包里的 cs= 不认识的键照旧忽略。
NET.FLAG_RKFIX = {}     -- 武林盟主固定的房间设置（键 → 0/1）；0.34 起暂时没有，机制留着
-- §216 三个原来挂在"武器平衡"下面的限制拆成单独的房间设置（用户 11-10"火枪cd，回避减杀气，瞬影cd 都增加到设置里。普通房间默认关闭"）：
--   gcd = 紫冥剑火枪冷却（§184，秒数 cooldown.ZiMingJian_HuoQiang）、dgc = 闪避扣杀气（§200.10，cost.Dodge / SnakeDodge）、
--   sycd = 瞬影冷却（§200 / §200.13，cooldown.ShunYingDodge）。普通房间默认关；武林盟主默认开（NET.RK_DEF，服务器 rkrules 可以写 0 关）。
--   不再看武器平衡开关（数值还是取平衡表 / 下发的 cd= / co=）；火枪每发点数（§212）仍归武器平衡；切武器保持杀气（§200.11）11-16 也拆出去了（swk）
for _, k in ipairs({ "gcd", "dgc", "sycd" }) do
    NET.FLAG_KEYS[#NET.FLAG_KEYS + 1] = k
    NET.FLAG_DEF[k], NET.flagCfg[k] = 0, 0
end
NET.FLAG_NAME.gcd = { "紫冥剑火枪冷却", "ZIMINGJIAN GUN COOLDOWN" }   -- §426 11-24 起火枪冷却只看武器平衡：gcd 还收发（旧版兼容），不再生效、面板不显示
NET.FLAG_NAME.dgc = { "闪避扣杀气", "DODGE COSTS SHACHI" }
NET.FLAG_NAME.sycd = { "瞬影冷却", "FLASH STEP COOLDOWN" }
-- §228 stg = 精防硬直（§161：连续被精防 N 次后 X 秒内关输入、播硬直；N / X 跟数值表 co= 的 StaggerHits / StaggerSec 下发）。
--   用户 11-11"普通房间可以设置是否生效这个功能，默认关闭"；武林盟主默认开（NET.RK_DEF，和以前一直生效一样）
NET.FLAG_KEYS[#NET.FLAG_KEYS + 1] = "stg"
NET.FLAG_DEF.stg, NET.flagCfg.stg = 0, 0
NET.FLAG_NAME.stg = { "精防硬直（连续被精防后短时间不能操作）", "DEFLECT STAGGER (LOCKED AFTER REPEATED PERFECT DEFLECTS)" }
-- 11-16 swk = 切武器保持杀气（§200.11：切武器不回满杀气、保持切之前的值）。以前跟着"武器平衡"，用户"切换武器是否回复杀气是否有开关""加一下"，
--   照 §216 拆成单独的房间设置：普通房间默认关（= 原版切武器回满）；武林盟主默认开（NET.RK_DEF）。
--   对方旧版没发 swk= / 规则串里没有 swk= 时按它的 bal（旧版就是跟着武器平衡走），NET.FLAG_OLD / NET.rkParse
NET.FLAG_KEYS[#NET.FLAG_KEYS + 1] = "swk"
NET.FLAG_DEF.swk, NET.flagCfg.swk = 0, 0
NET.FLAG_NAME.swk = { "切武器保持杀气（关 = 原版切武器回满）", "KEEP SHACHI ON WEAPON SWITCH (OFF = REFILL AS VANILLA)" }
-- §423 pdsh = 精防掉对面杀气（用户 11-23"精防防住攻击都可以掉对面杀气 加一个房间设置，默认关，每次掉100杀气"）：
--   我的招被对方精防 → 我自己扣 pdshv 点杀气（§423.1 房间设置档位，见 RES 段 dif 后面）；对手是本地 AI（杀气按替身，§353）时我精防它 → 扣替身的。
--   普通房间默认关；武林盟主规则串没写 pdsh= 时也关（base_dif 的 RK_DEF 兜底 0）。PDSH 段在 STG 段后面
NET.FLAG_KEYS[#NET.FLAG_KEYS + 1] = "pdsh"
NET.FLAG_DEF.pdsh, NET.flagCfg.pdsh = 0, 0
NET.FLAG_NAME.pdsh = { "精防掉对面杀气", "PERFECT DEFLECT DRAINS SHACHI" }
NET.FLAG_OLD = { swk = "bal" }      -- 主机旧版没发这个键时借哪个键的值
-- 11-23 用户"拿掉"：对手位置严格跟随（npos）没有玩家该关的情况（关了两边替身位置不一致、判定不公平；本地 AI 已自动走
--   动画带位移，观战强制开），面板不再显示，本机设置固定开：rules.txt 里旧的 npos=0、换房主时接过来的旧版主机 npos=0 都不认。
--   状态包照旧发 npos=1；客机照旧按主机发来的走（旧版主机关着时两边仍一致）。测试要强制切换用 net/follow.txt（NPM 段）
NET.FLAG_FIXED = { npos = 1 }
function NET.flagFix()
    for k, v in pairs(NET.FLAG_FIXED) do NET.flagCfg[k] = v end
end
function NET.flagLoad()
    local t = fileReadKV(NET.AB_FILE) or {}
    for _, k in ipairs(NET.FLAG_KEYS) do
        local n = tonumber(t[k])
        if n == 0 or n == 1 then NET.flagCfg[k] = n end
        if NET.FLAG_LOCKED[k] then NET.flagCfg[k] = 0 end
    end
    NET.flagFix()
end
function NET.flagSet(k, n)
    NET.flagCfg[k] = n
    local t, keys, lines = fileReadKV(NET.AB_FILE) or {}, {}, {}
    t[k] = tostring(n)
    for key in pairs(t) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do lines[#lines + 1] = key .. "=" .. t[key] end
    fileWrite(NET.AB_FILE, table.concat(lines, "\n") .. "\n")
end
function NET.flag(k)         -- 房间设置：主机 / 没联机 = 自己的，客机 = 主机的
    if NET.FLAG_LOCKED[k] then return false end     -- §144.1 锁住的：谁设成开都当关（包括旧版主机发来的 std=1）
    if NET.FLAG_RKFIX[k] and NET.locked() then return NET.FLAG_RKFIX[k] == 1 end    -- §181 定死规则（排位）固定开的（规则还没到也一样）
    local rk = NET.fixedRules()                 -- §110 武林盟主 / 房间固定规则
    if rk and rk[k] ~= nil then return rk[k] == 1 end
    local sm = BASEHOOK.mp
    if sm and sm.inMp and sm.inMp() then
        if (PEER and PEER.on) or NET.ruleClient() then
            local rf = ((PEER and PEER.on) and PEER.hostNet() or NET).rflag
            local r = rf[k]
            if r == nil and NET.FLAG_OLD[k] then r = rf[NET.FLAG_OLD[k]] end
            if r == nil then r = NET.FLAG_DEF[k] end
            return r == 1
        end
        return NET.flagCfg[k] == 1
    end
    if (PEER and PEER.on) or MATCH.role == "client" or (MATCH.session and MATCH.session.role) == "client" then      -- §223.6 观战替身：按主机那一路的
        local rf = ((PEER and PEER.on) and PEER.hostNet() or NET).rflag
        local r = rf[k]
        if r == nil and NET.FLAG_OLD[k] then r = rf[NET.FLAG_OLD[k]] end
        if r == nil then r = NET.FLAG_DEF[k] end
        return r == 1
    end
    return NET.flagCfg[k] == 1
end
function NET.flagNow(k)      -- 现在交手用的：对局中 = 开局时定下的，对局外 = 房间设置
    local sm = BASEHOOK.mp
    local inM = MATCH.state ~= "idle" or (sm and sm.inMatch and sm.inMatch())
    if inM and MATCH.flags and MATCH.flags[k] ~= nil then return MATCH.flags[k] end
    return NET.flag(k)
end
function NET.flagsNow()      -- 开局时定下
    local f = {}
    for _, k in ipairs(NET.FLAG_KEYS) do f[k] = NET.flag(k) end
    return f
end
-- §113 回合开始的资源（用户 2026-11-06"精纯杀气每场战斗开始时改到 1 个，之后正常累计；影之武装的释放资源改为 3 个"
-- "默认是 1 和 3，武林盟主模式也是 1 3，其他模式在房间设置里可改"）：
--   ult0 = 精纯杀气 UltimateChargeCount（格数，游戏上限 3），sp0 = 暗源 SpiritShadow（影之武装耗它，游戏上限 6，铃铛处回复）。
--   每回合进倒计时和开打时把自己的写成这个数（UltimateCharge 正在攒的那格清 0），之后游戏自己照常攒 / 扣。
--   和开关型设置同一套：主机定、客机按主机状态包的同名键走（主机旧版没有 → 默认）、开局时定下 MATCH.res、存 net/rules.txt；
--   排位按 rkrules（服务器不发就是默认 1 / 3）
--   §113.2 resm = 什么时候给（用户"能加个设置可以选每场 / 每局回复么""默认是每一场回复而不是每局回复，盟主模式也是"）：
--   0 = 每场（默认）：一场对局只在第 1 回合开始时给，之后的回合接着用剩下的；1 = 每局：每个回合开始都重置成设定值
-- §113.4 ultx = 精纯杀气获取倍率（百分比，只能取 RES_STEPS 里的值；用户"精纯杀气的获取倍率能加房间设置改么"）：
--   对局中把自己的 UltimateChargeGainRateMultiplier（游戏的获取倍率属性，平时 1.0）设成 对局前的值 × ultx%，结束还原；每回合都写，不管每场 / 每局
NET.RES_KEYS, NET.RES_DEF, NET.RES_MAX = { "ult0", "ultx", "sp0", "resm", "acc", "accn" }, { ult0 = 0, ultx = 100, sp0 = 3, resm = 0, acc = 2, accn = 3 },
                                         { ult0 = 3, ultx = 300, sp0 = 6, resm = 1, acc = 3, accn = 6 }   -- §176 accn = 生效饰品数量（6 = 上限；11-19 10:5x 默认 3 = 只生效前 3 件）   -- §170.1 acc = 饰品等级（11-19 10:5x 默认 2 = 强化满）   -- §113.3 默认精纯杀气改 0
NET.RES_STEPS = { ultx = { 0, 25, 50, 75, 100, 150, 200, 300 } }
NET.RES_ATTR = { ult0 = "UltimateChargeCount", sp0 = "SpiritShadow" }
NET.RES_NAME = { ult0 = { "开局精纯杀气", "STARTING ULTIMATE CHARGES" }, ultx = { "精纯杀气获取", "ULTIMATE CHARGE GAIN" },
                 sp0 = { "开局暗源（影之武装）", "STARTING PHANTOM EDGE CHARGES" }, resm = { "开局资源", "STARTING RESOURCES" },
                 acc = { "饰品", "ACCESSORIES" }, accn = { "生效饰品数量", "ACTIVE ACCESSORIES" } }
-- 值显示成文字的（其余显示数字）：{ 中文, 英文 }，调用方自己套 T()（T 在后面才定义）
NET.RES_TEXT = { resm = { [0] = { "每场给一次", "ONCE PER MATCH" }, [1] = { "每局重置", "EVERY ROUND" } },
                 acc = { [0] = { "原样", "AS EQUIPPED" }, [1] = { "未强化", "UNREFINED" },
                         [2] = { "强化满", "FULLY REFINED" }, [3] = { "失效", "DISABLED" } },
                 accn = { [0] = { "0 件（全不生效）", "NONE" }, [6] = { "不限", "ALL" } } }     -- §176 其余显示"前 N 件"
for i = 1, 5 do NET.RES_TEXT.accn[i] = { "前 " .. i .. " 件", "FIRST " .. i } end
NET.resCfg, NET.rres = { ult0 = 0, ultx = 100, sp0 = 3, resm = 0, acc = 2, accn = 3 }, {}
function NET.resValid(k, n)
    if n == nil or n ~= math.floor(n) then return false end
    if NET.RES_STEPS[k] then
        for _, v in ipairs(NET.RES_STEPS[k]) do if v == n then return true end end
        return false
    end
    return n >= 0 and n <= NET.RES_MAX[k]
end
function NET.resNext(k, n)   -- 房间设置点一下：下一档（转一圈）
    local st = NET.RES_STEPS[k]
    if not st then return (n + 1) % (NET.RES_MAX[k] + 1) end
    for i, v in ipairs(st) do if v == n then return st[i % #st + 1] end end
    return NET.RES_DEF[k]
end
function NET.resText(k, n)   -- 返回 { 中文, 英文 }
    if NET.RES_FMT and NET.RES_FMT[k] then return NET.RES_FMT[k](n) end      -- §173 回合时限显示成秒
    if NET.RES_STEPS[k] then return { n .. "%", n .. "%" } end
    local t = NET.RES_TEXT[k] and NET.RES_TEXT[k][n]
    return t or { tostring(n), tostring(n) }
end
function NET.resLoad()
    local t = fileReadKV(NET.AB_FILE) or {}
    for _, k in ipairs(NET.RES_KEYS) do
        local n = tonumber(t[k])
        if NET.resValid(k, n) then NET.resCfg[k] = n end
    end
end
function NET.resSet(k, n)
    NET.resCfg[k] = n
    NET.flagSet(k, n)        -- 同一个 rules.txt 读改写；flagSet 顺手写进 flagCfg[k]，没人看那个键
    NET.flagCfg[k] = nil
end
function NET.resOf(k)        -- 房间设置：主机 / 没联机 = 自己的，客机 = 主机的
    local sm = BASEHOOK.mp
    local inM = sm and sm.inMatch and sm.inMatch()     -- 只在多人对局中读开局快照；1v1 照旧
    if inM and MATCH.res and MATCH.res[k] ~= nil then return MATCH.res[k] end
    local rk = NET.fixedRules()                 -- §110 武林盟主 / 房间固定规则
    if rk and rk[k] ~= nil then return rk[k] end
    if sm and sm.inMp and sm.inMp() then
        if (PEER and PEER.on) or NET.ruleClient() then
            local r = ((PEER and PEER.on) and PEER.hostNet() or NET).rres[k]
            if NET.resValid(k, r) then return r end
            return (NET.RES_MISSING and NET.RES_MISSING[k]) or NET.RES_DEF[k]
        end
        return NET.resCfg[k]
    end
    if (PEER and PEER.on) or MATCH.role == "client" or (MATCH.session and MATCH.session.role) == "client" then      -- §223.6 观战替身：按主机那一路的
        local r = ((PEER and PEER.on) and PEER.hostNet() or NET).rres[k]
        if NET.resValid(k, r) then return r end
        return (NET.RES_MISSING and NET.RES_MISSING[k]) or NET.RES_DEF[k]      -- §266 主机旧版没发这个键：按旧版行为（dif = 各用自己的）
    end
    return NET.resCfg[k]
end
function NET.resNow()        -- 开局时定下
    local r = {}
    for _, k in ipairs(NET.RES_KEYS) do r[k] = NET.resOf(k) end
    r.accban = NET.accBanOf()          -- §176 禁用的饰品（不是数字，单独存）
    for _, k in ipairs(WBAN.KINDS) do r[k] = WBAN.of(k) end   -- §180 禁用武器 / 影之武装（同上）
    return r
end
-- §173 回合时限 tl（秒，0 = 不限；默认 180，武林盟主服务器不发也是 180 —— NET.RK_DEF.tl）。挂在开局资源这一套上：
-- 房间设置面板（"对局"类）、rules.txt、状态包 tl=、客机按主机的、开局定下 MATCH.res.tl 都跟着走。到时判负见 RT 段
NET.RES_KEYS[#NET.RES_KEYS + 1] = "tl"
NET.RES_DEF.tl, NET.RES_MAX.tl, NET.resCfg.tl = 180, 300, 180
NET.RES_STEPS.tl = { 0, 60, 90, 120, 180, 240, 300 }
NET.RES_NAME.tl = { "回合时限（到时受伤多的判负）", "ROUND TIME LIMIT (MORE DAMAGE TAKEN LOSES)" }
NET.RES_FMT = { tl = function(n)
    if (n or 0) <= 0 then return { "不限时", "NONE" } end
    return { n .. " 秒", n .. "s" }
end }
-- §266 dif = 对局难度（用户 11-12"可以配置用哪个，默认入阵者，盟主逆天者，要用游戏里实际难度名字"）。
--   每台电脑按自己存档的难度判防守：精防窗口 入阵者 10 帧 / 破局者 8 / 逆天者 8 / 六十六天 6，破防时窗口 14 / 12 / 6 / 6，
--   入阵者破防僵直 2 秒（其余 3）（Phantom Pact 1.7 读游戏配置得的，我们没核对过）——两人难度不同就不公平。
--   做法见 DIF 段：不切游戏难度，只在内存里把本机当前难度的战斗配置改成目标难度的数值，对局结束改回。
--   0 = 各用自己的（旧版行为；主机旧版没发 dif= 时客机也按 0）；1–4 按游戏的 EDifficultMode（入阵者 / 破局者 / 逆天者 / 六十六天）。
--   和开局资源同一套：存 rules.txt、主机定、状态包 dif=、客机按主机的、开局定下 MATCH.res.dif；武林盟主 NET.RK_DEF.dif = 3（服务器 rkrules 可改）
NET.RES_KEYS[#NET.RES_KEYS + 1] = "dif"
NET.RES_DEF.dif, NET.RES_MAX.dif, NET.resCfg.dif = 1, 4, 1
NET.RES_NAME.dif = { "对局难度（精防窗口等按这个难度判）", "MATCH DIFFICULTY (DEFLECT WINDOWS ETC.)" }
NET.RES_TEXT.dif = { [0] = { "各用自己存档的", "EACH PLAYER'S OWN" }, [1] = { "入阵者", "WAYFARER" }, [2] = { "破局者", "PATHBREAKER" },
                     [3] = { "逆天者", "HELLWALKER" }, [4] = { "六十六天", "66 DAYS" } }
NET.RES_MISSING = { dif = 0 }
-- §423.1 pdshv = 精防掉对面杀气每次扣多少（用户 11-23"加一项，50 / 100 / 150 / 200 四档，默认 100"）。
--   和开局资源同一套：存 rules.txt、主机定、状态包 pdshv=、客机按主机的、开局定下 MATCH.res.pdshv；武林盟主没写 = 100（base_dif RK_DEF）。
--   只在"精防掉对面杀气"（pdsh）开着时有用
NET.RES_KEYS[#NET.RES_KEYS + 1] = "pdshv"
NET.RES_DEF.pdshv, NET.RES_MAX.pdshv, NET.resCfg.pdshv = 100, 200, 100
NET.RES_STEPS.pdshv = { 50, 100, 150, 200 }
NET.RES_NAME.pdshv = { "精防掉杀气数量（每次被精防扣多少）", "SHACHI LOST PER DEFLECT" }
NET.RES_FMT.pdshv = function(n) return { tostring(n) .. " 点", tostring(n) } end
-- §422.1 stgm / stgr = 精防硬直锁几秒：被精防的那招是近战 / 远程（用户 11-23"开启这个功能后，近战和远程都可以通过房间设置 1 到 5 秒的时间，默认都是 1 秒"）。
--   和开局资源同一套：存 rules.txt、主机定、状态包 stgm= / stgr=、客机按主机的、开局定下 MATCH.res；武林盟主没写 = 1（base_dif RK_DEF）。
--   只在"精防硬直"（stg）开着时有用；远程 / 近战怎么分见 STG.RANGED。数值表 co= 的 StaggerSec 不再用（只留房间设置这一个入口，StaggerHits 照旧）
for _, k in ipairs({ "stgm", "stgr" }) do
    NET.RES_KEYS[#NET.RES_KEYS + 1] = k
    NET.RES_DEF[k], NET.RES_MAX[k], NET.resCfg[k] = 1, 5, 1
    NET.RES_STEPS[k] = { 1, 2, 3, 4, 5 }
    NET.RES_FMT[k] = function(n) return { tostring(n) .. " 秒", tostring(n) .. "s" } end
end
NET.RES_NAME.stgm = { "精防硬直秒数（近战招）", "DEFLECT STAGGER (MELEE)" }
NET.RES_NAME.stgr = { "精防硬直秒数（远程招）", "DEFLECT STAGGER (RANGED)" }
NET.RES_MISSING.stgm, NET.RES_MISSING.stgr = 1, 1     -- 主机旧版没发：旧版默认就是 1 秒
-- §176 禁用饰品（房间设置 accban=，内测反馈"慈母护符太强"）：饰品 ID 去掉 AC_、逗号隔开（"-" = 一件都不禁），
-- 只认 STD.ACCESSORIES 里的 66 件、按那个顺序存。全模组默认（普通房间 / 服务器大厅房间 / 武林盟主一样）= 舞扇、慈母护符、古甲残片、百相傩面、神奇刀鞘（§259、11-19 用户"盟主模式的配置就是全 mod 的默认配置"）。
-- 和 RES 键同一套：存 rules.txt、主机定、客机按主机状态包 accban= 走（没收到 = 默认）、开局时定进 MATCH.res.accban
-- §408 默认名单从 NET.RK_RULES（base_dif.lua，唯一真源）的 accban= 来。base_dif 在下面 §266 那段才加载，
-- 这里先占位，加载完再填（见 §266 之后那段）；运行期只会读已经填好的值。
NET.ACCBAN_DEF, NET.ACCBAN_RK = nil, nil
NET.accBanCfg, NET.raccban = nil, nil
function NET.accBanNorm(s)
    local want = {}
    for x in (s or ""):gmatch("[%w_]+") do want["AC_" .. x:gsub("^AC_", "")] = true end
    local out_ = {}
    for _, id in ipairs(STD.ACCESSORIES) do if want[id] then out_[#out_ + 1] = id:sub(4) end end
    return #out_ > 0 and table.concat(out_, ",") or "-"
end
function NET.accBanLoad()
    local t = fileReadKV(NET.AB_FILE) or {}
    NET.accBanCfg = t.accban and NET.accBanNorm(t.accban) or NET.ACCBAN_DEF
end
function NET.accBanSet(s)
    NET.accBanCfg = NET.accBanNorm(s)
    NET.flagSet("accban", NET.accBanCfg)
    NET.flagCfg.accban = nil
end
-- §179.4 定死规则（排位）的禁用饰品由服务器规则串的 accban= 定（NET.rkParse 把名单类的键原串留在表里；"-" = 不禁）；服务器没发 = 默认名单
function NET.accBanOf()
    local sm = BASEHOOK.mp
    local inM = sm and sm.inMatch and sm.inMatch()     -- 只在多人对局中读开局快照；1v1 照旧
    if inM and MATCH.res and MATCH.res.accban ~= nil then return MATCH.res.accban end
    local on, lr = NET.locked()
    if on then return lr and lr.accban and NET.accBanNorm(lr.accban) or NET.accBanDefNow() end     -- 定死规则在生效（规则还没到 = 盟主默认名单）
    local rr = NET.fixedRules()
    if rr and rr.accban then return NET.accBanNorm(rr.accban) end
    if sm and sm.inMp and sm.inMp() then
        if (PEER and PEER.on) or NET.ruleClient() then
            local h = (PEER and PEER.on) and PEER.hostNet() or NET
            return h.raccban and NET.accBanNorm(h.raccban) or NET.ACCBAN_DEF
        end
        return NET.accBanCfg
    end
    if (PEER and PEER.on) or MATCH.role == "client" or (MATCH.session and MATCH.session.role) == "client" then      -- §223.6 观战替身：按主机那一路的
        local h = (PEER and PEER.on) and PEER.hostNet() or NET
        return h.raccban and NET.accBanNorm(h.raccban) or NET.ACCBAN_DEF
    end
    return NET.accBanCfg
end
-- 普通服务器大厅房间未手动改过的规则：默认按当前排位标准，不写盘；切回别的联机方式还原
-- §408 不再在这里抄一份值：dm / flag / res 全部从 NET.RK_RULES → NET.RK_DEF 派生（base_dif.lua 是唯一真源）。
-- base_dif 在本文件后面 §266 那段才加载，所以 NET.SV_DEF 也在加载完之后填（见那段末尾）；这里只先建表。
NET.SV_DEF = { dm = nil, flag = {}, res = {} }
NET.svOn, NET.svMode = false, nil
function NET.accBanDefNow()     -- §408 正常路径是加载完填好的 NET.ACCBAN_DEF；抽段测试 / 加载顺序异常时回落到 RK_DEF / 字面量
    return NET.ACCBAN_DEF or (NET.RK_DEF and NET.RK_DEF.accban) or "AnimMovement,BreakRegen,HealthResistance,MagicWeapon,SwitchEndure"
end
function NET.rulesUnset(k)
    local f = NET.AB_FILE or NET.RULES_FILE
    if not f then return end
    local t, keys, lines = fileReadKV(f) or {}, {}, {}
    t[k] = nil
    for key in pairs(t) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do lines[#lines + 1] = key .. "=" .. t[key] end
    fileWrite(f, #lines > 0 and (table.concat(lines, "\n") .. "\n") or "")
end
function NET.svDefApply(on)
    NET.svOn = on == true
    if not (NET.RULES_FILE and NET.FLAG_KEYS and NET.RES_KEYS) then return end
    local t = fileReadKV(NET.RULES_FILE) or {}
    local dm = tonumber(t.dm)
    NET.dmCfg = (dm and NET.dmOk and NET.dmOk(dm)) and dm or (NET.svOn and NET.SV_DEF.dm or 100)
    for _, k in ipairs(NET.FLAG_KEYS) do
        local n = tonumber(t[k])
        if n == 0 or n == 1 then NET.flagCfg[k] = n
        else NET.flagCfg[k] = (NET.svOn and NET.SV_DEF.flag[k] ~= nil) and NET.SV_DEF.flag[k] or NET.FLAG_DEF[k] end
        if NET.FLAG_LOCKED and NET.FLAG_LOCKED[k] then NET.flagCfg[k] = 0 end
    end
    if NET.flagFix then NET.flagFix() end
    for _, k in ipairs(NET.RES_KEYS) do
        local n = tonumber(t[k])
        if n and NET.resValid and NET.resValid(k, n) then NET.resCfg[k] = n
        else NET.resCfg[k] = (NET.svOn and NET.SV_DEF.res[k] ~= nil) and NET.SV_DEF.res[k] or NET.RES_DEF[k] end
    end
    NET.accBanCfg = t.accban and NET.accBanNorm(t.accban) or NET.accBanDefNow()
end
-- ---- §180 禁用武器（房间设置 wpnban=）/ 禁用影之武装（edgeban=）。用户定的方案："装着禁用武器就不能开局，最安全"：
-- 不在对局中强制换装、不改装备、不写存档，装着禁用的就不让准备 / 开局。名单的存法照 §176 accban：存 rules.txt、主机定、
-- 客机按主机状态包 wpnban= / edgeban= 走（没收到 = 一件不禁）、开局定进 MATCH.res；武林盟主按服务器 rkrules 的 wpnban= / edgeban=（没发 = 不禁）。
-- 值 = 存档 ID 逗号隔开（"-" = 一件不禁，默认）；只认 WBAN.LIST 里的、按那个顺序存，比对不分大小写（存档 MoJian / 表 Mojian 这类，游戏目录 AGENTS.md 第三节）。
-- 武器 25 项 = catalog 里可获取的 27 把，但淬炼不换 ID（AGENTS.md 第二节）：炽刃 XieHuo = 长形黑伤 Long 淬炼、黑魔伤 HeiMoShang = 黑伤 Tang 淬炼，
-- 配装列表里永远是 Long / Tang，所以合成一项（禁"长形黑伤 / 炽刃"两种都禁，分不开）。影之武装 24 个（去掉 XueSeLingDang / BaWangLianQiu / MoShou 三条残留）。
-- 主机复核：各自把装着的（主手副手两格 + 影之武装两格）经状态包 wpn= / edg= 发出去，主机开局前（F1 准备 / startMatchNow，自动开局也走它）
-- 拿对方的和名单比，见 WBAN.gate（在 startMatchNow 前面，那里才看得到 REL / T / 颜色）
WBAN = { KINDS = { "wpnban", "edgeban" }, DEF = "-", cfg = { wpnban = "-", edgeban = "-" }, r = {}, rl = {},
         EQ_SEC = 2.0, eq = { at = -100 }, IDS = {}, LOW = {}, NAME = {},
         KIND_NAME = { wpnban = { "武器", "WEAPON" }, edgeban = { "影之武装", "PHANTOM EDGE" } },
         WIRE = { wpnban = "wpn", edgeban = "edg" } }       -- 名单键 → 状态包里"我装着的"那个键
-- 存档 ID 中文名 英文名（catalog.json，build 26266538；英文名里的空格写成 _）
WBAN.LIST = {
    wpnban = [[WoodenSwordHun 木制黑伤 WOODEN_SANGUINE|Tang 黑伤/黑魔伤 SANGUINE_/_INFERNAL_ROUGE|IronBlade 残钢刃 JAGGED_STEEL|LuanYing 乱莺剑 WILD_ORIOLE_SWORD|CiGuHunDun 刺骨混沌 FREEZING_CHAOS|RenOuQingTongJian 天玄青铜剑 TIANXUAN_BRONZE_SWORD|ChiZheCanJian 痴者残剑 THE_FANATIC'S_BROKEN_BLADE|SlitheringSword 灵蛇软剑 SOFT_SNAKE_SWORD|BaiShanShuangJian 白山风雷剑 BAISHAN_STORMSWORDS|ZiMingJian 紫冥剑 AUREATE|Long 长形黑伤/炽刃 SANGUINE_REACH_/_BLAZING_EDGE|ZhanMaBlade 亡命斩马刀 OUTLAW_WARBLADE|Jigsaw 断肢锯 BONESAW|BaiYing 白影 WHITESHADOW|GuiTouBlade 红妆鬼斩 SCARLET_WRAITHBLADE|PoJun 破军 ARMYBREAKER|HorizontalBlade 荡寇凶刃 JUGGERNAUT|RenOuYanYueDao 偃月刀 CRESCENT_BLADE|Double 黑伤双刃 SANGUINE_TWIN|YuuBlade 妖锯 FIEND_SAWS|TianShaShuangYue 天煞双钺 SUNDERING_DUAL_AXES|SnakeDual 白蟒赤练 WHITE_SERPENT_&_CRIMSON_VIPER|DualHook 别离残钩 PARTING_HOOKS|JadeDualChakram 玉双环 SEAMLESS_DEATH|FangHuaXieShan 圣母邪扇 THE_LADY'S_FAN]],
    edgeban = [[BrutalAxe 巨凶斧 DREAD_AXE|JinGua 长柄金瓜 BASHPOLE|ZhuoBiDun 拙壁盾 BASTION|TanLang 贪狼 WOLFJAW|TigerCannon 虎炮 TIGER_CANNON|HuangJinHuoChong 黄金火铳 GOLDBLAZE|UnnamedBow 羽弓 FEATHER_BOW|MiaoShouFeiDao 妙手飞刀 FLYING_DAGGER|YouLongTou 游龙头 YOU_LOONG'S_DELUGE|LionHead 烈焰狮头 FLAMING_MANE|KuYeSiZhuChuan 苦叶寺珠串 KUYE_TEMPLE_PRAYER_BEADS|ShachiHook 追命锁镰 HUNTER'S_CHAIN_SICKLE|YouLongCha 游龙叉 LOONG_TRIDENT|TieGongZhuQuanTao 铁拳套 IRON_GAUNTLETS|MoJian 墨血无痕 INK_CUT|ThunderSpear 雷霆枪 THUNDER_SPEAR|XueDiZi 血滴子 FLYING_GUILLOTINE|NiTouche 泥头车 WAR_WAGON|XuKongHuaShan 虚空华扇 INANIS'_RADIANT_FAN|CuiXinPiPa 催心琵琶 HEARTREND_PIPA|CaoOuSiXian 操偶铃铛 PUPPETEER'S_BELL|JianKeZhaoJiLing 剑客召集令 SWORDSMAN'S_SUMMON|DuYanGong 独眼弓 ONE-EYED_BOW|HuoLiuXing 火流星 BLAZE]],
}
for _, kind in ipairs(WBAN.KINDS) do
    WBAN.IDS[kind], WBAN.LOW[kind] = {}, {}
    for id, zh, en in WBAN.LIST[kind]:gmatch("(%w+) (%S+) ([^|]+)") do
        WBAN.IDS[kind][#WBAN.IDS[kind] + 1] = id
        WBAN.LOW[kind][id:lower()] = id
        WBAN.NAME[kind .. ":" .. id] = { zh, (en:gsub("_", " ")) }
    end
end
function WBAN.norm(kind, s)              -- 整理名单：不分大小写、不认识的丢掉、按 WBAN.LIST 顺序；空 = "-"
    local want = {}
    for x in (s or ""):gmatch("[%w_]+") do
        local id = WBAN.LOW[kind][x:lower()]
        if id then want[id] = true end
    end
    local o = {}
    for _, id in ipairs(WBAN.IDS[kind]) do if want[id] then o[#o + 1] = id end end
    return #o > 0 and table.concat(o, ",") or "-"
end
function WBAN.load()
    local t = fileReadKV(NET.AB_FILE) or {}
    for _, k in ipairs(WBAN.KINDS) do WBAN.cfg[k] = t[k] and WBAN.norm(k, t[k]) or WBAN.DEF end
end
function WBAN.set(kind, s)
    WBAN.cfg[kind] = WBAN.norm(kind, s)
    NET.flagSet(kind, WBAN.cfg[kind])
    NET.flagCfg[kind] = nil
end
function WBAN.of(kind)                   -- 房间设置：定死规则（排位）= 服务器的（没发 = 不禁）；客机 = 主机的（没收到 = 不禁）；主机 / 没联机 = 自己的
    local sm = BASEHOOK.mp
    local inM = sm and sm.inMatch and sm.inMatch()     -- 只在多人对局中读开局快照；1v1 照旧
    if inM and MATCH.res and MATCH.res[kind] ~= nil then return MATCH.res[kind] end
    local on, lr = NET.locked()
    if on then return lr and lr[kind] and WBAN.norm(kind, lr[kind]) or WBAN.DEF end
    local rr = NET.fixedRules()
    if rr and rr[kind] then return WBAN.norm(kind, rr[kind]) end
    if sm and sm.inMp and sm.inMp() then
        if NET.ruleClient() then return WBAN.r[kind] and WBAN.norm(kind, WBAN.r[kind]) or WBAN.DEF end
        return WBAN.cfg[kind]
    end
    if MATCH.role == "client" or (MATCH.session and MATCH.session.role) == "client" then
        return WBAN.r[kind] and WBAN.norm(kind, WBAN.r[kind]) or WBAN.DEF
    end
    return WBAN.cfg[kind]
end
function WBAN.now(kind)                  -- 这一局的：对局中 = 开局时定下的
    return (MATCH.res and MATCH.res[kind]) or WBAN.of(kind)
end
function WBAN.anyBan()
    for _, k in ipairs(WBAN.KINDS) do if WBAN.of(k) ~= "-" then return true end end
    return false
end
function WBAN.text(kind, s, lang)        -- 名单 → "黑伤/黑魔伤、白影"（lang 1 = 中文、2 = 英文）
    local names = {}
    for x in WBAN.norm(kind, s):gmatch("[%w_]+") do names[#names + 1] = (WBAN.NAME[kind .. ":" .. x] or { x, x })[lang or 1] end
    if #names == 0 then return lang == 2 and "NONE" or "无" end
    return table.concat(names, lang == 2 and ", " or "、")
end
-- 我装着的主武器 / 影之武装（背包配装列表，两格都算；G.loadoutLists 就是 GetEquipmentNormalWeapons / GetShaqiWeapons）。
-- 每 EQ_SEC 秒最多读一次（状态包每帧要），force = 马上重读（按 F1 时）。读不到 = nil
function WBAN.mine(force)
    local tn = os.clock()
    if force or tn - WBAN.eq.at >= WBAN.EQ_SEC then
        local mains, shaqis = G.loadoutLists()
        WBAN.eq = { at = tn, w = mains, s = shaqis }
    end
    return WBAN.eq.w, WBAN.eq.s
end
function WBAN.listWire(l)               -- 列表 → 状态包的值："-" = 空，"?" = 读不到
    if not l then return "?" end
    return #l > 0 and table.concat(l, ",") or "-"
end
function WBAN.wire()                     -- 状态包：我装着的 wpn=<武器,武器> / edg=<影武,影武>
    local w, s = WBAN.mine()
    return "wpn=" .. WBAN.listWire(w) .. "\nedg=" .. WBAN.listWire(s) .. "\n"
end
function WBAN.parse(s)                   -- 对方的 wpn= / edg= → 列表；nil = 没这个字段（旧版），false = 对方读不到（"?"）
    if s == nil then return nil end
    if s == "?" then return false end
    local l = {}
    for x in s:gmatch("[%w_]+") do l[#l + 1] = x end
    return l
end
function WBAN.recv(t)                    -- 收状态包：主机的名单（我是客机时按它）+ 对方装着的
    for _, k in ipairs(WBAN.KINDS) do
        if t[k] ~= WBAN.r[k] then
            if (MATCH.role == "client" or (MATCH.session and MATCH.session.role) == "client") and t[k] then
                out("禁用%s：主机设为 %s（下一局生效）", WBAN.KIND_NAME[k][1], WBAN.text(k, t[k], 1))
            end
            WBAN.r[k] = t[k]
        end
    end
    WBAN.rl.wpnban, WBAN.rl.edgeban = WBAN.parse(t.wpn), WBAN.parse(t.edg)
end
function WBAN.hitsOf(kind, list, ban)    -- list 里禁用的（不分大小写）→ { 中文名们, 英文名们 }；没有 = nil
    local set = {}
    for x in WBAN.norm(kind, ban):gmatch("[%w_]+") do set[x:lower()] = x end
    local zh, en, seen = {}, {}, {}
    for _, id in ipairs(list or {}) do
        local hit = set[tostring(id):lower()]
        if hit and not seen[hit] then
            seen[hit] = true
            local nm = WBAN.NAME[kind .. ":" .. hit] or { hit, hit }
            zh[#zh + 1], en[#en + 1] = nm[1], nm[2]
        end
    end
    if #zh == 0 then return nil end
    return { table.concat(zh, "、"), table.concat(en, ", ") }
end
-- 我自己装着禁用的？返回 { 中文提示, 英文提示 }, 名单键, 名字（nil = 没问题）。名单空不读配装
function WBAN.selfCheck()
    if not WBAN.anyBan() then return nil end
    local w, s = WBAN.mine(true)
    local lists = { wpnban = w, edgeban = s }
    for _, k in ipairs(WBAN.KINDS) do
        local ban = WBAN.of(k)
        if ban ~= "-" then
            local kn = WBAN.KIND_NAME[k]
            if not lists[k] then
                return { "读不到你装着的" .. kn[1] .. "（房间禁用了" .. kn[1] .. "，不能准备）", "CAN'T READ YOUR " .. kn[2] .. "S (THIS ROOM BANS SOME) - CAN'T GET READY" }, k, nil
            end
            local h = WBAN.hitsOf(k, lists[k], ban)
            if h then
                return { "你装着禁用" .. kn[1] .. " " .. h[1] .. "，换掉再准备", "YOU HAVE A BANNED " .. kn[2] .. " EQUIPPED (" .. h[2] .. ") - SWAP IT OUT, THEN GET READY" }, k, h
            end
        end
    end
    return nil
end
-- 主机复核对方装着的（对方状态包 wpn= / edg=）。返回 { 中文, 英文 }（主机看的）, 原因 "hit" / "old"（没这个字段 = 旧版）/ "none"（对方读不到）, 名单键, 名字
-- 本地 AI / 假对手（ai=1）不查：它的配装是 AI 自己的（§114），不是真人
function WBAN.peerCheck(peer)
    if NET.rai then return nil end
    peer = peer or "对方"
    for _, k in ipairs(WBAN.KINDS) do
        local ban = WBAN.of(k)
        if ban ~= "-" then
            local kn, l = WBAN.KIND_NAME[k], WBAN.rl[k]
            if l == nil then
                return { "对方（" .. peer .. "）版本太旧、没上报" .. kn[1] .. "（房间禁用了" .. kn[1] .. "，不能开局；让对方更新模组）",
                         "THE OPPONENT (" .. peer .. ") IS ON AN OLD VERSION WITHOUT " .. kn[2] .. " INFO - CAN'T START WITH BANS" }, "old", k
            end
            if l == false then
                return { "没收到对方（" .. peer .. "）的" .. kn[1] .. "信息（对方读不到配装），不能开局",
                         "NO " .. kn[2] .. " INFO FROM THE OPPONENT (" .. peer .. ") - CAN'T START WITH BANS" }, "none", k
            end
            local h = WBAN.hitsOf(k, l, ban)
            if h then
                return { "对方（" .. peer .. "）装着禁用" .. kn[1] .. " " .. h[1] .. "，不能开局", "THE OPPONENT (" .. peer .. ") HAS A BANNED " .. kn[2] .. " (" .. h[2] .. ")" }, "hit", k, h
            end
        end
    end
    return nil
end
-- §307 D4：这一场"第几回合"（开局资源 resm=每场只给一次时按它判断）。
-- 对决用对决的回合数；多人（非对决）保持现状（每次复活 = 新回合，多人那边 rulesRespawn 已经在管）；其余照旧 MATCH.round。
function NET.duelRoundNow()
    local sm = BASEHOOK.mp
    if sm and sm.inMp and sm.inMp() then
        local d = sm.duelInfo and sm.duelInfo()
        if d then return tonumber(d.round) or 1 end
        return 1
    end
    return MATCH.round or 1
end
-- §307 D4：规则指纹 RFP.build 的 bo / tl 覆盖。对决 = 1v1 的局数 / 时限；多人（非对决）= bo=0、多人时限；
-- 不在多人房 = nil（照旧用 1v1 的 MATCH.toWin / MATCH.tl）。fornet_match.lua 的 ctx.rfpOverride 可选回调也认它。
function NET.duelRfpOverride()
    local sm = BASEHOOK.mp
    if not (sm and sm.inMp and sm.inMp()) then return nil end
    local d = sm.duelInfo and sm.duelInfo()
    if d then return { bo = tonumber(d.bo) or 3, tl = tonumber(d.tl) or 0 } end
    local c = (sm.cfg and sm.cfg()) or {}
    return { bo = 0, tl = tonumber(c.tl) or 300 }
end
-- 进倒计时 / 开打时调：把自己的精纯杀气 / 暗源写成这一局定下的数。第一次调时记下对局前的值，回自由活动时 resRestore 还回去
-- （PvP 不该吃掉单机里攒的大招和暗源）
function NET.resApply(p1, why)
    if not valid(p1) then return end
    local r = MATCH.res or NET.resNow()
    NET.ultxApply(p1, r.ultx or 100)                                      -- §113.4 获取倍率每回合都写
    if (r.resm or 0) == 0 and NET.duelRoundNow() > 1 then return end     -- §113.2 每场：只有第 1 回合给（§307 对决按对决回合数）
    if not MATCH.resSaved then
        MATCH.resSaved = { UltimateChargeCount = attrOf(p1, "UltimateChargeCount"), UltimateCharge = attrOf(p1, "UltimateCharge"),
                           SpiritShadow = attrOf(p1, "SpiritShadow") }
    end
    local want = { UltimateChargeCount = r.ult0, UltimateCharge = 0, SpiritShadow = r.sp0 }
    local parts, prev = {}, {}
    for a, v in pairs(want) do
        local c = attrOf(p1, a)
        if c and math.abs(c - v) > 0.01 then
            if not NET.resWrite(p1, a, v) then prev[a] = c end
            parts[#parts + 1] = string.format("%s %.1f → %d", a, c, v)
        end
    end
    if #parts > 0 then out("回合资源（%s）：%s", why, table.concat(parts, "，")) end
    if next(prev) then NET.resUi(p1, prev) end
end
-- §113.1 写一个属性：先走游戏自己的改属性函数（AttributeUtils.ModifyCharacterAttributeValue，ASC 广播，HUD 自己刷新）；
-- 不行再直接写（setAttr），返回 false 让调用方补刷 HUD（只补得了暗源 / 在攒的那格，格数的回调直接调会崩，实测 4）。
-- 每个属性第一次记一行走的哪条路
NET.resWay = {}
function NET.resWrite(p1, a, v)
    local ok, msg = false, "没有 attrModSet"
    if G.attrModSet then
        local okC, r1, r2 = pcall(G.attrModSet, p1, a, v)
        if okC then ok, msg = r1, r2 else msg = tostring(r1) end
    end
    if not ok then setAttr(p1, a, v) end
    local way = ok and "改属性函数" or "直接写"
    if NET.resWay[a] ~= way then
        NET.resWay[a] = way
        out("回合资源：%s 走%s（%s）", a, way, tostring(msg))
    end
    return ok
end
-- 直接写属性 HUD 收不到通知（W_WeaponUI 听的是 ASC 的属性变化），写完按它自己的回调补一下（pbz_game.lua weaponUiRefresh）。
-- prev = 改之前的值（属性名 → 值），只刷直接写了的
function NET.resUi(p1, prev)
    local old, new = {}, {}
    local KEY = { UltimateChargeCount = "cnt", UltimateCharge = "chg", SpiritShadow = "sp" }
    for a, k in pairs(KEY) do
        if prev[a] ~= nil then old[k], new[k] = prev[a], attrOf(p1, a) end
    end
    local ok, lines = pcall(G.weaponUiRefresh, old, new)
    if not ok then out("!! 回合资源：刷新 HUD 出错 %s", tostring(lines)); return end
    if #lines > 0 then out("回合资源：刷新 HUD")
        for _, l in ipairs(lines) do out("%s", l) end
    end
end
-- §113.4 精纯杀气获取倍率：第一次（倍率不是 100% 时）记下对局前的 UltimateChargeGainRateMultiplier，写成 它 × pct%；
-- MATCH.ultxSaved = 对局前的值 / false（读不到，这一场不管了）/ nil（还没动过）
NET.ULTX_ATTR = "UltimateChargeGainRateMultiplier"
function NET.ultxApply(p1, pct)
    local a = NET.ULTX_ATTR
    if MATCH.ultxSaved == nil then
        if pct == 100 then return end
        local cur, base = attrOf(p1, a)
        MATCH.ultxSaved, MATCH.ultxBase = cur or false, base
        if not MATCH.ultxSaved then out("!! 精纯杀气获取倍率：读不到 %s，这一场不改", a); return end
    end
    if not MATCH.ultxSaved then return end
    local v, c = MATCH.ultxSaved * pct / 100, attrOf(p1, a)
    if c and math.abs(c - v) > 0.001 then
        NET.resWrite(p1, a, v)
        out("精纯杀气获取倍率 %d%%：%s %.3f → %.3f（读回 %s）", pct, a, c, v, tostring(attrOf(p1, a)))
    end
end
function NET.ultxRestore(p1)
    local v, vb = MATCH.ultxSaved, MATCH.ultxBase
    MATCH.ultxSaved, MATCH.ultxBase = nil, nil
    if not (v and valid(p1)) then return end
    local c = attrOf(p1, NET.ULTX_ATTR)
    if c and math.abs(c - v) > 0.001 then NET.resWrite(p1, NET.ULTX_ATTR, v) end
    local _, cb = attrOf(p1, NET.ULTX_ATTR)            -- §170.7 改属性函数连基础值一起改，基础值单独写回
    if vb and cb and math.abs(cb - vb) > 0.0001 then G.setAttrBase(p1, NET.ULTX_ATTR, vb) end
    out("精纯杀气获取倍率：还原成对局前的 %.3f", v)
end
function NET.resRestore(p1)
    NET.ultxRestore(p1)
    local s = MATCH.resSaved
    MATCH.resSaved = nil
    if not (s and valid(p1)) then return end
    local prev = {}
    for a, v in pairs(s) do
        local c = attrOf(p1, a)
        if c and math.abs(c - v) > 0.01 and not NET.resWrite(p1, a, v) then prev[a] = c end
    end
    if next(prev) then NET.resUi(p1, prev) end
    out("回合资源：还原对局前的精纯杀气 %s 格（在攒 %s）、暗源 %s", tostring(s.UltimateChargeCount), tostring(s.UltimateCharge), tostring(s.SpiritShadow))
end
-- §116.2 只读诊断：每场第 1 回合倒计时时比我和替身的全部属性（pbz_game.lua attrDiff），差的记日志"属性对比"。
-- 用户"不确定伤害数值对不对"：本地 AI 扣血按我打在本机替身上的伤害算，替身没抄防御类属性；名字像防御 / 承伤的标 ★
NET.DIFF_DEF = { "Vulnerab", "Resist", "Defen", "Reduc", "Armor", "Tough", "Taken", "Mitig", "Absorb", "Protect" }
function NET.attrDiffLog(p1)
    local pup = puppet()
    if not (G.attrDiff and valid(p1) and valid(pup)) then return end
    local ok, d, total = pcall(G.attrDiff, p1, pup)
    if not ok then out("!! 属性对比出错 %s", tostring(d)); return end
    if not d then out("属性对比：读不到属性集"); return end
    local nDef = 0
    for _, x in ipairs(d) do
        for _, k in ipairs(NET.DIFF_DEF) do if x[1]:find(k, 1, true) then x.def = true end end
        if x.def then nDef = nDef + 1 end
    end
    table.sort(d, function(a, b) if a.def ~= b.def then return a.def == true end return a[1] < b[1] end)
    out("属性对比（你 vs 替身，共 %d 个属性，不一样的 %d 个，其中像防御 / 承伤的 %d 个 ★；格式 当前值(基础值)）：", total or 0, #d, nDef)
    for _, x in ipairs(d) do
        out("  %s%s  你 %.3f(%.3f)  替身 %.3f(%.3f)", x.def and "★ " or "", x[1], x[2], x[4] or 0, x[3], x[5] or 0)
    end
end

-- §144 标准数值模式（房间设置"标准数值"，用户 2026-11-07"不计双方各自成长，都用同一套完整角色的数值""直接拿我存档的数据作为基准"
-- "需要调整平衡的时候再从这个基础上调整不同武器 / 招式的伤害"）。基准 = 用户 11-07 的存档（tools/stat_probe/README.md 两次实测）：
--   属性：血 3086（基础 850 + 三种记忆之花）、攻击 / 杀气攻击 200（+ 杀气核心）、杀气上限 800、状态积累上限 3630、
--         精纯杀气格数上限 3 / 暗源上限 6（天赋）
--   天赋：没开轮回的全满 = 下面 24 个 GE_Talent_* + 天赋树的加药次数 / 大招不清零（饰品槽那 4 个不给，配装用各自的）
--   武器 / 影之武装：全 30 级、轮回 0。等级是伤害倍率 AttackMultipliers = 1 + 0.1 ×（等级 − 1），30 级 3.9
-- 做法（用户选"替身乘系数"，不碰存档）：
--   · 自己：开局把上面的属性写成基准（走 §113 的改属性函数），缺的天赋 GE 临时挂上；结束还原、挂上的摘掉；
--     对局期间进游戏自带的"否决存档"（EnterSaveVeto），结束退出——临时改的东西不会被自动存档写进硬盘
--   · 替身：攻击 / 杀气攻击用基准 200（对方包里的 att= 别的项照用，饰品效果是各自的）；伤害在挨打方本机按本机存档里那把武器的
--     等级算（推测，待低等级存档实测），所以替身攻击力再乘 3.9 ÷ 本机那把的倍率，本机 30 级就是 ×1；天赋按基准补齐
--   · 只用自己存档里有的装备（规则 2）；饰品精炼等级暂不统一（"未强化"待做）
STD = {
    ATTR = { Health_Max = 3086, Infliction_Max = 3630, Attack = 200, ShachiAttack = 200, Shachi_Max = 800,
             UltimateChargeCount_Max = 3, SpiritShadow_Max = 6 },
    ORDER = { "Health_Max", "Infliction_Max", "Shachi_Max", "Attack", "ShachiAttack", "UltimateChargeCount_Max", "SpiritShadow_Max" },
    LEVEL = 30,
    TALENT_GE = { "DecreaseStanceShachiCost", "DecreaseSwitchWeaponCooldown", "DecreaseSwitchWeaponCooldown_2", "EnableDashDuringLightAttack",
                  "EnableDashEscapeWhenBroken", "EnableDashEscapeWhenBroken_GrantGA", "EnableDrawAttack", "EnableExecutionRecoverBullet",
                  "EnableExecutionRecoverHealthAndShachi", "EnableIntoSuperSprint", "EnableNotConsumeBullet", "EnableOffset",
                  "EnablePerfectDeflectRecoveryShachi", "EnableRecoveryMedicine", "EnableShachiAttachWhenNotEnoughShachi", "EnableSkipJump",
                  "EnableTenacity", "EnableUseMedicineWhenHit", "IncreaseShachiWeaponMaxCount", "IncreaseShachiWeaponMaxCount_2",
                  "IncreaseUltimateCharge", "IncreaseUltimateCharge_2", "ShachiWeaponExecution", "UltimateInvulnerable" },
    TALENT_DIR = "/PBZCombatAsset/Prototypes/GameplayEffects/Talent/",
    TREE_GE = { "GE_AddMedcineTime", "GE_NoClearUltimateChrage" },
    TREE_DIR = "/Game/PBZContent/Blueprint/Ability/GameplayEffects/AbilityTree/",
    TALENT_GA = { "GA_Talent_EnableIntoSuperSprint_C", "GA_Talent_EnableTenacity_C", "GA_Talent_PerfectDeflectRecoveryShachi_C" },
    -- 武器配置所在的文件夹 → 存档里的武器 ID（DT_WeaponData / DT_ShaqiWeaponData 引用的配置路径对存档的 25 / 24 个 ID）
    WEAPON = { Tang = "Tang", HeiMoShang = "Tang", Long = "Long", Double = "Double", WoodenSword = "WoodenSwordHun", Iron = "IronBlade",
               GuiTouBlade = "GuiTouBlade", ChiZheCanJian = "ChiZheCanJian", ZhanMaBlade = "ZhanMaBlade", SnakeDual = "SnakeDual",
               BronzeSword = "RenOuQingTongJian", YuuBlade = "YuuBlade", LuanYing = "LuanYing", PoJun = "PoJun", DualHook = "DualHook",
               ShuangYue = "TianShaShuangYue", SlitheringSword = "SlitheringSword", BaiShanFengLeiJian = "BaiShanShuangJian",
               Horizontal = "HorizontalBlade", JadeDualChakram = "JadeDualChakram", BaiYing = "BaiYing", YanYueDao = "RenOuYanYueDao",
               ChaosBlade = "CiGuHunDun", Jigsaw = "Jigsaw", XieShan = "FangHuaXieShan", ZiMingJian = "ZiMingJian" },
    SHACHI = { BrutalAxe = "BrutalAxe", CaoOuSiXian = "CaoOuSiXian", DuYanBow = "DuYanGong", HuangJinHuoChong = "HuangJinHuoChong",
               HuoLiuXing = "HuoLiuXing", JianKeZhaoJiLing = "JianKeZhaoJiLing", JinGua = "JinGua", KuYeSiZhuChuan = "KuYeSiZhuChuan",
               LionHead = "LionHead", Lute = "CuiXinPiPa", MiaoShouFeiDao = "MiaoShouFeiDao", Mojian = "MoJian", NiTouChe = "NiTouche",
               ShachiHook = "ShachiHook", TanLang = "TanLang", ThunderSpear = "ThunderSpear", TieKuangQuanTao = "TieGongZhuQuanTao",
               TigerCannon = "TigerCannon", UnnamedBow = "UnnamedBow", XuKongHuaShan = "XuKongHuaShan", XueDiZi = "XueDiZi",
               YouLongCha = "YouLongCha", YouLongHead = "YouLongTou", ZhuoBiDun = "ZhuoBiDun" },
    VETO_ID = "PBZ_MP_StandardStats",
    lv = {},            -- 本机等级缓存：(w|s):武器 ID → 等级 / false（每场开局清）
    saved = nil,        -- 对局前的属性（属性名 → 值）；nil = 这场还没开始改
    added = nil,        -- 这场给自己挂上的天赋 GE 路径
    pupAdded = {},      -- 替身路径 → 给它挂上的（替身换了自然重新补）
    veto = false,
    enforceAt = -100,
    forced = nil,       -- 我们正套着临时强制配装的武器 ID（nil = 没套）
    forceTried = nil,   -- 这把已经判断过（不用套 / 套不上），换武器前不再试
    cleaned = false,    -- 进游戏后清过残留没有
    -- 主武器临时强制配装的总开关。11-07 20:08 二周目实测：强制配装会把武器组第二把、影之武装、饰品**全部卸掉**（只剩那一把）→ main 上关着。
    -- exp/std-loadout（方案 B，20:27 实测通过）：套完用游戏的临时整套配装快照把两把武器 / 两件影武装回去、逐格装回饰品。
    -- 11-08 01:1x 实测：对局中切武器重新套会"切过去又被拉回来"、而且强制配装同时只能一把 → 改走方案 A+（STD.gearOn），这里关掉，代码留着
    USE_FORCE = false,
    gearSlots = nil,    -- 方案 A+ 换过配置的格子 { { slot, idx, base, cfg, id, label }, … }；nil = 这场还没换
    gearMine = nil,     -- 方案 A+ 我们正挂着的 30 级效果（类路径 → true）；nil = 这场还没开始
    gearKey = nil,      -- 上次按哪把武器 / 哪件影武挂的（"主|影"）
    gearFix = 0,        -- 对局中发现配置被换回去、重新换的次数（到 GEAR_FIX_MAX 不再换）
    GEAR_FIX_MAX = 6,
    pushed = false,     -- 套强制配装后 Push 过配装快照（还原时先 Pop）
    FORCE_EVERY = 0.3,  -- 对局中多久看一次手上的武器（换了就换套）
    forceAt = -100,
    -- 21:06 实测死循环（套 Tang、Push 后读到手上是 Double → 当成切武器 → 套 Double → 读到 Tang …每 0.5 秒一次，30 秒后崩溃）：
    SETTLE = 3.0,       -- 换套后这么多秒内不认"切武器"
    settleUntil = -100,
    seen = nil,         -- 防抖：上一次读到的"新"武器（连续两次读到同一把才算切了）
    GUARD_N = 4,        -- GUARD_SEC 秒内换套到 GUARD_N 次 → 本场停用强制配装
    GUARD_SEC = 20.0,
    forceTimes = {},
    disabled = false,   -- 本场停用了（STD.restore 清）
    -- 正式能拿到的 66 件饰品（catalog 去掉 7 件残留）：游戏没有"读装了哪些"的函数，逐个问 IsEquipAccessory
    ACCESSORIES = { "AC_ActHit", "AC_AnimMovement", "AC_Attack", "AC_BigHit", "AC_Bleed", "AC_BreakAttack", "AC_BreakDrink",
                    "AC_BreakRecover", "AC_BreakRegen", "AC_BreakShield", "AC_Chaos", "AC_Combo", "AC_Control", "AC_Counter", "AC_Deflect",
                    "AC_Double", "AC_Drink", "AC_DrinkCost", "AC_Electrified", "AC_ElementRegen", "AC_Elemental", "AC_EvadePhantom",
                    "AC_Execution", "AC_ExecutionSwitchCool", "AC_Frost", "AC_Health", "AC_HealthResistance", "AC_HeavyAttackCost",
                    "AC_HeavyAttackDamage", "AC_HeavyAttackShachi", "AC_Ignite", "AC_Long", "AC_Loot", "AC_LowHealth", "AC_LowShachi",
                    "AC_MagicWeapon", "AC_MartialWeapon", "AC_PerfectFrame", "AC_Poison", "AC_PoisonRegen", "AC_PowerWeapon",
                    "AC_RandomDrink", "AC_Ranged", "AC_RangedWeapon", "AC_ResistBleed", "AC_ResistFire", "AC_ResistIce",
                    "AC_ResistNonBreak", "AC_ResistPoison", "AC_ResistRanged", "AC_ResistThunder", "AC_Rider", "AC_Shachi",
                    "AC_ShachiAttack", "AC_ShachiCool", "AC_ShachiRegen", "AC_ShachiWeapon", "AC_SpiritShadow", "AC_Stance", "AC_Stealth",
                    "AC_SummonDuration", "AC_SwitchEndure", "AC_Tang", "AC_TimerEndure", "AC_UltimateBreak", "AC_UltimateCharge" },
}
STD.FORCE_FILE = NET_DIR .. "/std_forced.txt"   -- 账本：套着时写武器 ID，还原后删；进游戏时据此清残留（只清我们留下的）
function STD.mult(lv) return (lv and lv > 1) and (1 + 0.1 * (lv - 1)) or 1.0 end
function STD.active() return NET.flagNow("std") end
function STD.talentPath(n) return STD.TALENT_DIR .. "GE_Talent_" .. n .. ".GE_Talent_" .. n .. "_C" end
function STD.treePath(n) return STD.TREE_DIR .. n .. "." .. n .. "_C" end
-- 武器配置路径 → 存档 ID, 是不是影之武装。文件夹名不分大小写（游戏包里是 JigSaw / MoJian，表里是 Jigsaw / Mojian）
function STD.idOf(path)
    if not path then return nil end
    if not STD.lowerMap then
        STD.lowerMap = { w = {}, s = {} }
        for k, v in pairs(STD.WEAPON) do STD.lowerMap.w[k:lower()] = v end
        for k, v in pairs(STD.SHACHI) do STD.lowerMap.s[k:lower()] = v end
    end
    local f = path:match("/Hun/Weapon/([%w_]+)/")
    if f then return STD.WEAPON[f] or STD.lowerMap.w[f:lower()], false end
    f = path:match("/Hun/ShaqiWeapon/([%w_]+)/")
    if f then return STD.SHACHI[f] or STD.lowerMap.s[f:lower()], true end
    return nil
end
-- 本机存档里这把的等级（缓存）；读不到 = nil
function STD.localLevel(id, shachi)
    local k = (shachi and "s:" or "w:") .. id
    if STD.lv[k] == nil then
        local lv, err = G.weaponLevel(id, not shachi)
        STD.lv[k] = lv or false
        out("武器等级：本机%s %s 的等级 %s", shachi and "影之武装" or "武器", id, lv and tostring(lv) or ("读不到（" .. tostring(err) .. "）"))
    end
    return STD.lv[k] or nil
end
-- 本机存档里这把铸魂过没有（缓存）；读不到 = false
function STD.localSnapped(id, shachi)
    local k = (shachi and "S:" or "W:") .. id
    if STD.lv[k] == nil then STD.lv[k] = G.weaponSnapped(id, not shachi) == true end
    return STD.lv[k]
end
-- §148 替身打我时游戏乘的等级倍率（11-08 08:1x–08:27 假对手实测，固定攻击 100、标准数值 / 武器平衡关；HANDOVER §148）：
-- 替身那把**装在我的武器槽里** → 我存档里那把的 1 + 0.1 ×（等级 − 1），铸魂不影响（二周目装着的长形黑伤 30 级铸魂 −312 = 80 × 3.9）；
-- 没装 / 没有 → ×1（二周目没装的木剑 30 级、黑伤 30 级都是 ×1；新档把 3 级黑伤卸下后 −96 → −80）。
-- 以前"铸魂过 = ×1"是把"没装着"误认成了铸魂（§146.3 作废）
STD.EQUIP_SEC = 2.0
STD.eq = { at = -100 }
-- 我现在装着的主武器 / 影之武装（背包的装备列表，存档 ID；每 EQUIP_SEC 秒最多读一次）。读不到 = nil
function STD.equipped(id, shachi)
    local tn = os.clock()
    if tn - STD.eq.at >= STD.EQUIP_SEC then
        local mains, shaqis = G.loadoutLists()
        local function toSet(list)
            if not list then return nil end
            local s = {}
            for _, x in ipairs(list) do s[x:lower()] = true end
            return s
        end
        STD.eq = { at = tn, w = toSet(mains), s = toSet(shaqis) }
    end
    local s = shachi and STD.eq.s or STD.eq.w
    if not s then return nil end
    return s[id:lower()] == true
end
function STD.localMult(id, shachi)
    local lv = STD.localLevel(id, shachi)
    if not lv then return nil, "本机等级读不到" end
    if lv < 1 then return 1.0, "本机没有这把" end
    local eq = STD.equipped(id, shachi)
    if eq == false then return 1.0, string.format("本机 %d 级、没装着", lv) end
    return STD.mult(lv), string.format("本机 %d 级%s", lv, eq == nil and "（装备列表读不到，按装着算）" or "、装着")
end
-- 标准数值的基准 = 30 级装着（×3.9）
STD.TARGET_MULT = STD.mult(STD.LEVEL)
-- 替身这一招的等级系数：目标倍率 ÷ 本机倍率。返回 系数, 说明（认不出 / 读不到 → 1；普通房间对方没发等级 → 1, nil）
-- 目标：标准数值 = 30 级；§148 普通房间 = 对方那把的倍率（状态包 wlv=，对方手上那把一定装着）
function STD.levelScale(edge)
    local std = STD.active()
    local rlv = edge and NET.rlvS or NET.rlvW
    if not std and not rlv then return 1.0, nil end
    local path = edge and NET.rwcs or NET.rwc
    local id, shachi = STD.idOf(path)
    if not id then return 1.0, "认不出武器 " .. tostring(path) end
    local m, why = STD.localMult(id, shachi)
    if not m then return 1.0, id .. " " .. why end
    if std then return STD.TARGET_MULT / m, id .. " " .. why end
    return STD.mult(rlv) / m, string.format("%s 对方 %d 级 / %s", id, rlv, why)
end
-- §183 裂斩（L1+圈，双手武器共用 GA_GlobalActionAbility_LieZhan_*）出招时对方游戏把手上换成占位武器 Weapon_Hun_MoQie，
-- 不吃武器等级倍率（11-09 实测，伤害 50%：替身也换成 MoQie 时一下 1061 / 1071；包里还是 Long、本机没装着 ×3.9 时一下打满 3857）。
-- 裂斩期间按"总倍率 ×1"：游戏按本机存档给替身手上那把乘的倍率 m 除掉（MoQie / 认不出 → 1）。没开标准数值、对方也没发等级 → 和 levelScale 一样不管
function STD.flatScale(edge)
    local rlv = edge and NET.rlvS or NET.rlvW
    if not STD.active() and not rlv then return 1.0, nil end
    local id, shachi = STD.idOf(edge and NET.rwcs or NET.rwc)
    if not id then return 1.0, "裂斩按 ×1（手上是占位武器 / 认不出）" end
    local m = STD.localMult(id, shachi)
    if not m or m <= 0 then return 1.0, "裂斩按 ×1（" .. id .. " 本机等级读不到）" end
    return 1.0 / m, string.format("裂斩按 ×1（%s 本机倍率 %.2f 除掉）", id, m)
end
-- §148 发给对方：我手上武器 / 当前影之武装在我存档里的等级，wlv=<武器>:<影之武装>（认不出 / 读不到 = -）
function STD.wireLv()
    local function one(path)
        local id, shachi = STD.idOf(path)
        local lv = id and STD.localLevel(id, shachi)
        return lv and tostring(lv) or "-"
    end
    return one(NET.wcStr) .. ":" .. one(NET.wcsStr)
end
-- 角色缺的基准天赋 GE 挂上，返回挂上的路径表
function STD.addTalents(actor, label)
    local have = G.geSet(actor)
    if not have then out("!! 标准数值：读不到%s身上的效果，天赋不补", label); return {} end
    local added = {}
    local function one(short, path)
        if not have[short] then
            LO.applyGE(actor, path, "标准数值：给" .. label .. "补天赋 " .. short)
            added[#added + 1] = path
        end
    end
    for _, n in ipairs(STD.TALENT_GE) do
        if not STD.blockOn(n) then one("GE_Talent_" .. n, STD.talentPath(n)) end      -- §232 屏蔽的天赋不补（数值表里写了也不补）
    end
    for _, n in ipairs(STD.TREE_GE) do one(n, STD.treePath(n)) end
    out("标准数值：%s天赋补了 %d 个（基准 %d 个）", label, #added, #STD.TALENT_GE + #STD.TREE_GE)
    return added
end
-- §232 标准数值屏蔽的天赋（用户 11-11："标准模式下，屏蔽绝处逢生天赋效果（参考瞬影的cd做法）"）
-- 绝处逢生 = UI_AbilityName_18"每场战斗，可免疫一次会使生命值降低至 10% 以下的攻击" = GE_Talent_EnableTenacity
--   （资产：GE 用 GrantAndActivateAbilities 给 GA_Talent_EnableTenacity、TargetTags 给 CharacterState.Talent.EnableTenacity；
--    GA 等 GameplayEvent.Damage.Pretake、读血量、HasMatchingGameplayTag(EnableTenacity / .CoolingDown)、播 SFX_Combat_Hun_Buff_Reborn；
--    "每场一次"靠 GE_Talent_EnableTenacity_Cooldown 给 .CoolingDown 标签）
-- 做法照 §200.13 瞬影冷却：标准数值对局期间把天赋 GE 从自己 / 替身身上摘掉（标签跟着没），GA 还挂着就 ClearAbility；
-- 回自由活动挂回去（天赋 GE 是运行时的，存档只记天赋树，不进存档）。对局中每 2 秒查一次，游戏又挂上就再摘。
-- 替身被动同步（LO.syncPas）在标准数值下也不给替身这个 GA。net/talblock_off.txt 存在 = 不屏蔽（出问题时不用重新部署）
STD.BLOCK_TAL = { EnableTenacity = { ga = "GA_Talent_EnableTenacity_C", tag = "CharacterState.Talent.EnableTenacity", zh = "绝处逢生" } }
STD.BLOCK_OFF = NET_DIR .. "/talblock_off.txt"
STD.blocked, STD.pupBlocked, STD.blockN = nil, {}, { off = 0, re = 0 }
function STD.blockOff()
    local f = io.open(STD.BLOCK_OFF, "r")
    if f then f:close(); return true end
    return false
end
function STD.blockOn(n) return STD.BLOCK_TAL[n] ~= nil and not STD.blockOff() end
-- 这个角色的技能格里类名是 ga 的格（ClearAbility 用的 Handle 表）
function STD.gaSpecs(actor, ga)
    local asc = ascOf(actor)
    local items = valid(asc) and rawProp(rawProp(asc, "ActivatableAbilities"), "Items")
    if not items then return asc, {} end
    local hs = {}
    eachArr(items, function(_, spec)
        local ab = rawProp(spec, "Ability")
        local okC, cls = false, nil
        if valid(ab) then okC, cls = pcall(function() return ab:GetClass() end) end      -- 空对象不调 GetClass（v0.27.7）
        if okC and shortName(full(cls)) == ga then hs[#hs + 1] = rawProp(rawProp(spec, "Handle"), "Handle") end
    end)
    return asc, hs
end
-- 摘掉屏蔽的天赋，返回摘掉的 GE 路径表（读不到身上的效果 = nil，下次再来）；quiet = 身上没有时不记日志（每 2 秒复查用）
function STD.blockTalents(actor, label, quiet)
    if not valid(actor) then return nil end
    if STD.blockOff() then
        if not quiet then out("§232 标准数值屏蔽天赋：有 net/talblock_off.txt，%s不屏蔽", label) end
        return {}
    end
    local have = G.geSet(actor)
    if not have then if not quiet then out("!! §232 标准数值屏蔽天赋：读不到%s身上的效果，下次再摘", label) end; return nil end
    local done = {}
    for n, info in pairs(STD.BLOCK_TAL) do
        local short, path = "GE_Talent_" .. n, STD.talentPath(n)
        if have[short] then
            local ok = LO.removeGE(actor, path, "§232 标准数值：摘掉" .. label .. "的天赋 " .. short .. "（" .. info.zh .. "）")
            local still = ok and (G.geSet(actor) or {})[short]
            if ok and not still then done[#done + 1] = path end
            -- GE 摘了 GA 一般跟着撤；还在就清掉（挂回 GE 时游戏会重新给并激活）
            local asc, hs = STD.gaSpecs(actor, info.ga)
            local cleared = 0
            for _, h in ipairs(hs) do
                if LO.clearAbility(asc, h) then cleared = cleared + 1 end
            end
            local tagLeft = false
            for _, t in ipairs(tagsOf(actor) or {}) do if t == info.tag then tagLeft = true end end
            STD.blockN.off = STD.blockN.off + 1
            out("§232 标准数值屏蔽%s %s：GE %s；GA 摘 GE 后还剩 %d 个、清掉 %d 个；标签 %s（第 %d 次）", label, info.zh,
                (ok and not still) and "已摘" or (ok and "!! 调用成功但还在身上" or "!! 摘失败"), #hs, cleared,
                tagLeft and "!! 还在" or "已没有", STD.blockN.off)
        elseif not quiet then
            out("§232 标准数值屏蔽%s %s：身上本来没有 %s", label, info.zh, short)
        end
    end
    return done
end
-- 把摘掉的挂回去（身上已经有了就不挂）
function STD.unblockTalents(actor, list, label)
    if not (list and #list > 0 and valid(actor)) then return end
    local have = G.geSet(actor) or {}
    for _, path in ipairs(list) do
        local short = STD.geShort(path)
        if have[short] then out("§232 %s的天赋 %s 已经在身上，不用挂回", label, short)
        else LO.applyGE(actor, path, "§232 标准数值结束：给" .. label .. "挂回天赋 " .. short) end
    end
end
-- 自己 / 替身：第一次摘（STD.apply）和每 2 秒复查（STD.tick）都走这里
function STD.blockSelf(p1, quiet)
    local got = STD.blockTalents(p1, "自己", quiet)
    if not got then return end
    STD.blocked = STD.blocked or {}
    for _, path in ipairs(got) do
        local dup = false
        for _, x in ipairs(STD.blocked) do if x == path then dup = true end end
        if not dup then STD.blocked[#STD.blocked + 1] = path end
        if quiet then STD.blockN.re = STD.blockN.re + 1 end
    end
end
function STD.blockPup(pup, quiet)
    if not valid(pup) then return end
    local key = pathOf(pup)
    local got = STD.blockTalents(pup, "替身", quiet)
    if not got then return end
    local list = STD.pupBlocked[key] or {}
    for _, path in ipairs(got) do
        local dup = false
        for _, x in ipairs(list) do if x == path then dup = true end end
        if not dup then list[#list + 1] = path end
    end
    STD.pupBlocked[key] = list
end
-- 自己的属性写成基准（第一次碰到的属性记下对局前的值）；health = true 时顺手回满血（回合开始）
-- §170.5 饰品从标准数值里拿出来（用户 11-09"不如彻底把饰品从标准数值里提出来"）：锁的 7 个属性 = 基准 + 身上饰品给的
-- （加的先加、乘的后乘；读饰品效果自己的 Modifiers）。以前直接锁基准，加血 / 加攻击的饰品在标准数值里不起作用
function STD.accBonus(p1)
    local add, mul, madd, parts = {}, {}, {}, {}
    for _, e in ipairs(G.geMods(p1, function(n) return n:find("_Accessory_", 1, true) ~= nil end) or {}) do
        for _, md in ipairs(e.mods) do
            if STD.ATTR[md.a] then
                if md.op == 0 then add[md.a] = (add[md.a] or 0) + md.v
                elseif md.op == 1 then madd[md.a] = (madd[md.a] or 0) + (md.v - 1)      -- MultiplyAdditive：几个 ×1.25 是加起来（实测两份 = ×1.5）
                elseif md.op == 4 then mul[md.a] = (mul[md.a] or 1) * md.v end         -- MultiplyCompound：连乘
                parts[#parts + 1] = string.format("%s %s op%d %.3f", e.n, md.a, md.op, md.v)
            end
        end
    end
    local sig = table.concat(parts, "，")
    if sig ~= STD.bonusSig then STD.bonusSig = sig; out("标准数值：饰品给锁定属性的加成：%s", sig ~= "" and sig or "（无）") end
    for a, v in pairs(madd) do mul[a] = (mul[a] or 1) * (1 + v) end
    return add, mul
end
-- §349 武器状态给锁定属性的加成（黑魔伤魔剑 / 妖锯狂暴 GE_Hun_*_Buff：Attack op1 1.2、ShachiAttack op4 0.33，ABUF.ATK_GE）。
-- 以前锁定属性只算饰品，魔剑 / 狂暴的 ×1.2 每 2 秒被写回基准（11-16 15:37:33 / 15:38:19 / 15:38:41"属性被改回去了，重写：Attack 240→200"）。
-- 本机（STD.writeAttrs）和替身（LO.apply）都用这个。同名效果只算一份（替身自己放出来一份、wge= 又挂一份时）。
-- 返回 加, 乘加（MultiplyAdditive 的 Σ(v-1)）, 连乘, 说明（空 = 没有）
function STD.stateMods(actor)
    local add, madd, comp, parts, seen = {}, {}, {}, {}, {}
    for _, e in ipairs(G.geMods(actor, function(n) return ABUF.ATK_GE[n] ~= nil end) or {}) do
        if not seen[e.n] then
            seen[e.n] = true
            for _, md in ipairs(e.mods) do
                if STD.ATTR[md.a] then
                    if md.op == 0 then add[md.a] = (add[md.a] or 0) + md.v
                    elseif md.op == 1 then madd[md.a] = (madd[md.a] or 0) + (md.v - 1)
                    elseif md.op == 4 then comp[md.a] = (comp[md.a] or 1) * md.v end
                    parts[#parts + 1] = string.format("%s %s op%d %.3f", e.n:gsub("^GE_Hun_", ""), md.a, md.op, md.v)
                end
            end
        end
    end
    return add, madd, comp, table.concat(parts, "，")
end
-- §170.5 对局前的属性要在饰品换级（ACC.apply）之前记：倒计时里先调这个，writeAttrs 记 saved 时优先用它
function STD.capture(p1)
    if not (STD.active() and valid(p1)) or STD.pre then return end
    STD.pre, STD.preBase = {}, {}
    for _, a in ipairs(STD.ORDER) do STD.pre[a], STD.preBase[a] = attrOf(p1, a) end
    local ok, add, mul = pcall(STD.accBonus, p1)
    STD.preAdd, STD.preMul = ok and add or {}, ok and mul or {}
end
-- §170.9 写锁定属性：基础值 = base、当前值 = cur。血 / 攻 / 杀气上限这些直接写——游戏的改属性函数（GE_MA_*_Override）对
-- 带饰品乘法加成的属性会算歪（11-09 08:19 实测 Health_Max 要 3857.5 写成 7616.25），还把加成写进基础值；
-- 两个格数上限照旧走改属性函数（HUD 要通知，§113），写完再把基础值单独摆正
STD.VIA_MOD = { UltimateChargeCount_Max = true, SpiritShadow_Max = true }
-- 11-09 08:28 实测：BaseValue 是"没吃永久道具"的底子（Health_Max 850、Attack 100），记忆之花 / 杀气核心 / 饰品都是效果叠上去的。
-- 所以只改当前值、基础值永远不动（改属性函数顺手改了的就摆回对局前的），游戏重算时自然回到玩家自己的值
function STD.put(p1, a, cur)
    local _, b0 = attrOf(p1, a)
    local keep = STD.savedBase and STD.savedBase[a] or b0
    if STD.VIA_MOD[a] then NET.resWrite(p1, a, cur) end
    local c, cb = attrOf(p1, a)
    if c and math.abs(c - cur) > 0.01 then G.setAttrCur(p1, a, cur) end
    if keep and cb and math.abs(cb - keep) > 0.001 then G.setAttrBase(p1, a, keep) end
end
function STD.writeAttrs(p1, health)
    local parts = {}
    local okB, add, mul = pcall(STD.accBonus, p1)
    if not okB then add, mul = {}, {} end
    local okS, sadd, smadd, scomp, ssig = pcall(STD.stateMods, p1)       -- §349 魔剑 / 狂暴
    if not okS then sadd, smadd, scomp, ssig = {}, {}, {}, "" end
    if ssig ~= (STD.stateSig or "") then
        STD.stateSig = ssig
        STD.stateLogs = (STD.stateLogs or 0) + 1
        if STD.stateLogs <= 60 then out("§349 标准数值：武器状态给锁定属性的加成：%s", ssig ~= "" and ssig or "（无，按基准 + 饰品）") end
    end
    for _, a in ipairs(STD.ORDER) do
        local want, c = (STD.ATTR[a] + (add[a] or 0) + (sadd[a] or 0)) * (mul[a] or 1) * (1 + (smadd[a] or 0)) * (scomp[a] or 1), attrOf(p1, a)
        if c then
            if STD.saved and STD.saved[a] == nil then
                STD.saved[a] = (STD.pre and STD.pre[a]) or c
                STD.savedBase = STD.savedBase or {}
                local _, cb = attrOf(p1, a)
                STD.savedBase[a] = (STD.preBase and STD.preBase[a]) or cb
                if not STD.preAdd then STD.preAdd, STD.preMul = add, mul end
            end
            if math.abs(c - want) > 0.01 then
                STD.put(p1, a, want)
                parts[#parts + 1] = string.format("%s %.0f→%.0f（读回 %s）", a, c, want, tostring(attrOf(p1, a)))
            end
        end
    end
    if health then
        local hm = attrOf(p1, "Health_Max")
        if hm and (attrOf(p1, "Health") or 0) < hm - 0.5 then NET.resWrite(p1, "Health", hm) end
    end
    return parts
end
-- 主武器临时 30 级 + 铸魂：走游戏自带的临时强制配装（HANDOVER §144 18:1x 实测：等级 / 铸魂 / 升级解锁的招和效果都由游戏处理，
-- Restore 干净还原；只认背包里有的；存档会写进去但带 ForcedLoadoutActive / OrigLevel 标记，读回后 Restore 照样能还原）。
-- 手上那把已经 30 级、铸魂过 → 不套（满级玩家什么都不变）；游戏自己正在强制配装（剧情）→ 不套、不碰
function STD.force(p1, tn)
    if not STD.USE_FORCE or STD.disabled then return end
    local id = STD.idOf(LO.heldConfig(p1))
    if tn and STD.verify then                          -- Push 后的确认（见上）
        local v = STD.verify
        if tn < v.at then return end
        if id == v.id then
            out("标准数值：确认手上是 %s（Push 主序号 %d）", id, v.mi)
            STD.verify = nil
        elseif not v.retried and #v.mains > 1 then
            local mi2 = (v.mi == 0) and 1 or 0
            out("!! 标准数值：Push(主序号 %d) 后手上是 %s（要的是 %s），改用序号 %d 再 Push", v.mi, id, v.id, mi2)
            G.loadoutPop()
            local okP = G.loadoutPush(v.mains, v.shaqis, mi2, v.si)
            STD.pushed = okP and G.loadoutSnapshot() == true
            v.mi, v.retried, v.at = mi2, true, tn + 0.6
            STD.settleUntil = tn + STD.SETTLE
        else
            STD.disabled, STD.verify = true, nil
            out("!! 标准数值：两个序号 Push 后手上都不是 %s（是 %s），本场停用强制配装", v.id, id)
            STD.unforce("Push 对不上")
        end
        return
    end
    if not id or id == STD.forced or id == STD.forceTried then STD.seen = nil; return end
    if tn then                                         -- 对局中（STD.tick 来的）：防抖 + 换套后静默
        if tn < STD.settleUntil then return end
        if STD.seen ~= id then STD.seen = id; return end    -- 第一次读到：等下一次还是它再换
        STD.seen = nil
        local recent = {}
        for _, t in ipairs(STD.forceTimes) do if tn - t < STD.GUARD_SEC then recent[#recent + 1] = t end end
        STD.forceTimes = recent
        if #recent >= STD.GUARD_N then
            STD.disabled = true
            out("!! 标准数值：%d 秒内换套 %d 次，本场停用强制配装（还原，伤害只靠替身乘系数）", STD.GUARD_SEC, #recent)
            STD.unforce("换套太频繁")
            return
        end
        STD.forceTimes[#STD.forceTimes + 1] = tn
    end
    local sid = STD.idOf(LO.heldConfig(p1, LO.slotShachi()))     -- 手上的影之武装（Push 时让它还是当前那件）
    if STD.forced then STD.unforce("换武器 → " .. id) end      -- 先回到原配装（Restore 后手上可能变回原来那把，id 已经记下）
    STD.forceTried = id
    local lv = G.weaponLevel(id, true)
    if not lv or lv < 1 then out("标准数值：手上的 %s 本机等级读不到 / 没有（%s），不套强制配装", id, tostring(lv)); return end
    local snapped = G.weaponSnapped(id, true)
    if lv >= STD.LEVEL and snapped ~= false then out("标准数值：手上的 %s 已是 %d 级、铸魂 %s，不用套", id, lv, tostring(snapped)); return end
    if G.forcedActive() then out("!! 标准数值：游戏自己正在强制配装中（剧情？），不套"); return end
    -- 原配装：主武器 / 影武列表就是游戏里的格子顺序；饰品按清单顺序装回 0.. 格
    local mains, shaqis = G.loadoutLists()
    if not (mains and #mains > 0) then out("!! 标准数值：读不到当前配装，不套强制配装（会卸掉配装）"); return end
    shaqis = shaqis or {}
    local accs = G.accEquipped(STD.ACCESSORIES) or {}
    local mi, si = 0, 0
    for i, w in ipairs(mains) do if w == id then mi = i - 1 end end
    for i, w in ipairs(shaqis) do if w == sid then si = i - 1 end end
    local ok, err = G.forcedApply(id, STD.LEVEL, true)
    local after = G.weaponLevel(id, true)
    if not (ok and after == STD.LEVEL) then
        out("!! 标准数值：%s 强制配装没生效（调用 %s %s，之后等级 %s）", id, tostring(ok), tostring(err or ""), tostring(after))
        return
    end
    STD.forced, STD.lv = id, {}       -- 本机等级变了：替身等级系数的缓存作废
    fileWrite(STD.FORCE_FILE, id .. "\n")
    local okP, errP = G.loadoutPush(mains, shaqis, mi, si)
    STD.pushed = okP and G.loadoutSnapshot() == true
    -- 0.6 秒后在 STD.tick 里确认手上是不是这把（游戏切武器要几帧；21:06 死循环就是 Push 后手上不是要的那把）
    STD.verify = { at = (STD.lastTn or 0) + 0.6, id = id, mains = mains, shaqis = shaqis, mi = mi, si = si, retried = false }
    STD.settleUntil = (STD.lastTn or 0) + STD.SETTLE
    local nAcc = 0
    for i, a in ipairs(accs) do if G.accAssemble(a, i - 1) then nAcc = nAcc + 1 end end
    STD.countLog("套上 " .. id)
    out("标准数值：%s 临时强制配装 %d → %d 级、铸魂（原铸魂 %s）；装回配装 主武器 [%s] 第 %d 把、影武 [%s] 第 %d 件 %s；饰品 %d / %d 件",
        id, lv, STD.LEVEL, tostring(snapped), table.concat(mains, ","), mi + 1, table.concat(shaqis, ","), si + 1,
        STD.pushed and "成功" or ("失败 " .. tostring(errP or "快照没开")), nAcc, #accs)
end
-- §144 方案 A+（11-08 02:1x–02:2x 新档实测）：不用强制配装，直接把自己装着的两把武器 / 两件影之武装的配置换成铸魂配置
-- （LO.setSlot，替身换装同一个调用；背包、存档都不动，切武器后保留），再照二周目扫描的标准答案挂 30 级升级效果
-- （pbz_stdgear.lua，tools/gen_stdgear.py 生成）。黑伤实测：铸魂配置后黑魔伤的招一个不缺、补 6 个效果后和标准答案一致。
-- 伤害倍率不在这里（还是替身乘 STD.levelScale）。都是运行时的，崩溃 / 重进游戏后游戏按背包重建，不留东西
do
    local okG, T = pcall(require, "pbz_stdgear")
    if not (okG and type(T) == "table") then okG, T = pcall(function() return dofile((((FORNET or {}).GAME_DIR or (ROOT .. "/Scripts")) .. "/pbz_stdgear.lua")) end) end
    if okG and type(T) == "table" and T.MAIN and T.SHACHI then
        STD.GEAR = T
        local n, s = 0, 0
        for _ in pairs(T.MAIN) do n = n + 1 end
        for _ in pairs(T.SHACHI) do s = s + 1 end
        out("标准数值装备表 pbz_stdgear.lua：主武器 %d、影之武装 %d、常驻效果 %d", n, s, #(T.COMMON or {}))
    else
        out("!! 标准数值：装备表 pbz_stdgear.lua 读不到（%s），只统一属性 / 天赋 / 伤害", tostring(T))
    end
end
function STD.geShort(path) return path:match("/([%w_]+)%.[^/]*$") or path end
-- 开局：装着的两把 / 两件换铸魂配置（一场只做一次；STD.gearOff 还原），再按手上那把挂 30 级效果（STD.gearSync）
function STD.gearOn(p1)
    if STD.gearMine or not STD.GEAR then return end
    STD.gearSlots, STD.gearMine, STD.gearKey, STD.gearFix = {}, {}, nil, 0
    local mains, shaqis = G.loadoutLists()
    if not mains then out("!! 标准数值（装备）：读不到当前配装，不换配置") end
    local function slots(ids, tbl, slot, label)
        for i, id in ipairs(ids or {}) do
            local g = tbl[id]
            if not g then
                out("标准数值（装备）：%s %s 不在装备表里，不补", label, id)
            elseif g.base then
                -- 存档里已经铸魂的：游戏给的本来就是铸魂配置，不换（不然结束时"换回原配置"会把炽刃换成长形黑伤）；读不到当没铸魂
                if G.weaponSnapped(id, slot == LO.slot()) then
                    out("标准数值（装备）：%s第 %d 格 %s 存档里已铸魂，不换配置", label, i, id)
                else
                    local ok, err = LO.setSlot(p1, slot, i - 1, g.cfg)
                    out("标准数值（装备）：%s第 %d 格 %s 换成铸魂配置 %s：%s", label, i, id, LO.short(g.cfg), ok and "成功" or ("失败 " .. tostring(err)))
                    if ok then
                        STD.gearSlots[#STD.gearSlots + 1] = { slot = slot, idx = i - 1, base = g.base, cfg = g.cfg, id = id, label = label }
                    end
                end
            end
        end
    end
    slots(mains, STD.GEAR.MAIN, LO.slot(), "主武器")
    slots(shaqis, STD.GEAR.SHACHI, LO.slotShachi(), "影之武装")
    STD.gearSync(p1)
end
-- 30 级效果跟着手上那把武器 / 那件影之武装走（11-08 02:48 二周目实测：满级存档里没拿在手上的炽刃 / 贪狼的升级效果也不在身上，
-- 游戏是切到哪把挂哪把的）：要的 = 常驻 + 手上主武器的 + 手上影武的；我们挂过、现在不要的摘掉，身上已有的（游戏自己按存档挂的）不挂。
-- 只动我们自己挂的；挂 / 摘效果不新建武器对象。手上那把没变就什么都不做（对局中 STD.tick 每 0.3 秒调）
function STD.gearSync(p1)
    if not (STD.gearMine and STD.GEAR) then return end
    local mid = STD.idOf(LO.heldConfig(p1))
    local sid = STD.idOf(LO.heldConfig(p1, LO.slotShachi()))
    local key = tostring(mid) .. "|" .. tostring(sid)
        .. (SHADOWPASSIVES and SHADOWPASSIVES.blocked(SHADOWPASSIVES.paths[1]) and "|shadow" or "")
    if key == STD.gearKey then return end
    local have = G.geSet(p1)
    if not have then return end                   -- 读不到身上的效果：下次再试
    STD.gearKey = key
    local want, order = {}, {}
    local function addGE(list)
        for _, e in ipairs(list or {}) do
            if not (SHADOWPASSIVES and SHADOWPASSIVES.blocked(e[1])) then
                if not want[e[1]] then order[#order + 1] = e[1] end
                if not want[e[1]] or want[e[1]] < e[2] then want[e[1]] = e[2] end
            end
        end
    end
    addGE(STD.GEAR.COMMON)
    addGE(mid and STD.GEAR.MAIN[mid] and STD.GEAR.MAIN[mid].ge)
    addGE(sid and STD.GEAR.SHACHI[sid] and STD.GEAR.SHACHI[sid].ge)
    local nDel, nAdd, skip = 0, 0, 0
    for path in pairs(STD.gearMine) do
        if not want[path] then
            local allowed = not (SHADOWPASSIVES and SHADOWPASSIVES.blocked(path)) or SHADOWPASSIVES.allowRemove(p1, path)
            if allowed and LO.removeGE(p1, path, "标准数值：摘掉 30 级效果 " .. STD.geShort(path)) then
                STD.gearMine[path] = nil
                nDel = nDel + 1
            else STD.gearKey = nil end
        end
    end
    for _, path in ipairs(order) do
        if not STD.gearMine[path] then
            local short = STD.geShort(path)
            if have[short] then
                skip = skip + 1
            elseif LO.applyGE(p1, path, "标准数值：挂 30 级效果 " .. short, want[path]) then
                STD.gearMine[path] = true
                nAdd = nAdd + 1
            else STD.gearKey = nil
            end
        end
    end
    if STD.gearKey or nAdd + nDel > 0 then
        out("标准数值（装备）：手上 %s / 影武 %s：挂 30 级效果 %d 个、摘 %d 个，本来就有 %d 个", tostring(mid), tostring(sid), nAdd, nDel, skip)
    end
end
-- 对局中（STD.tick 每 2 秒）：手上那格的配置被游戏换回原配置了就再换一次（11-08 实测切武器不会换回，这里是保险）
function STD.gearCheck(p1)
    if not STD.gearSlots or STD.gearFix >= STD.GEAR_FIX_MAX then return end
    for _, s in ipairs(STD.gearSlots) do
        if LO.curIndex(p1, s.slot) == s.idx and LO.heldConfig(p1, s.slot) == s.base then
            STD.gearFix = STD.gearFix + 1
            local ok, err = LO.setSlot(p1, s.slot, s.idx, s.cfg)
            out("!! 标准数值（装备）：%s %s 被换回原配置，重新换成铸魂配置 %s（第 %d 次%s）", s.label, s.id, ok and "成功" or ("失败 " .. tostring(err)),
                STD.gearFix, STD.gearFix >= STD.GEAR_FIX_MAX and "，本场不再换" or "")
        end
    end
end
-- 结束：摘掉挂上的效果、换回原配置
function STD.gearOff(p1)
    if not STD.gearMine then return end
    local slots, mine = STD.gearSlots or {}, STD.gearMine
    STD.gearSlots, STD.gearMine, STD.gearKey = nil, nil, nil   -- 角色没了（切图）也不留状态：游戏按背包重建，不用还原；下面的调用自己 pcall
    local n = 0
    for path in pairs(mine) do LO.removeGE(p1, path, "标准数值：摘掉 30 级效果 " .. STD.geShort(path)); n = n + 1 end
    local bad = 0
    for i = #slots, 1, -1 do
        local s = slots[i]
        local ok, err = LO.setSlot(p1, s.slot, s.idx, s.base)
        if not ok then bad = bad + 1; out("!! 标准数值（装备）：%s %s 换回原配置失败 %s", s.label, s.id, tostring(err)) end
    end
    out("标准数值（装备）：摘掉 30 级效果 %d 个，换回原配置 %d 格%s", n, #slots, bad > 0 and ("（失败 " .. bad .. " 格）") or "")
end
-- ============================================================ §170 / §170.1 饰品等级（房间设置 acc=）（→ base_acc.lua）
ACC = BASEPARTS.load("acc", { ST = ST, NET = NET, MATCH = MATCH, G = G,
    -- 主循环那段会把这几个换成计时包装（PROF.wrap）：传"调用时再取"，和搬出来之前一样
    out = function(...) return out(...) end, attrOf = function(...) return attrOf(...) end })

-- ============================================================ §266 对局难度 + 整场对局否决存档 / §158 数值表下发 / §110 固定规则（→ base_dif.lua）
-- 全局表（最外层 local 已经很多，不再加）；DIF / CFG 在模块里也保持全局，只把主块局部变量经 ctx 传进去
DIFM = BASEPARTS.load("dif", { NET = NET, MATCH = MATCH, NET_DIR = NET_DIR, G = G,
    -- 主循环那段会把这几个换成计时包装（PROF.wrap）：传"调用时再取"，和搬出来之前一样
    out = function(...) return out(...) end, fileReadKV = function(...) return fileReadKV(...) end })

-- §408 base_dif 已加载：盟主默认值（唯一真源 NET.RK_RULES → NET.RK_DEF）现在填进本文件前面占位的两处。
-- 服务器大厅房间默认（NET.SV_DEF）和禁用饰品默认名单（NET.ACCBAN_DEF / NET.ACCBAN_RK）都从同一份派生。
NET.ACCBAN_DEF = NET.RK_DEF.accban or "AnimMovement,BreakRegen,HealthResistance,MagicWeapon,SwitchEndure"
NET.ACCBAN_RK = NET.ACCBAN_DEF
NET.accBanCfg = NET.ACCBAN_DEF
NET.SV_DEF.dm = NET.RK_DEF.dm
for _, k in ipairs(NET.FLAG_KEYS) do if NET.RK_DEF[k] ~= nil then NET.SV_DEF.flag[k] = NET.RK_DEF[k] end end
for _, k in ipairs(NET.RES_KEYS) do if NET.RK_DEF[k] ~= nil then NET.SV_DEF.res[k] = NET.RK_DEF[k] end end

-- ============================================================ M3：判定结果回传
-- 防守方判定（交接文档 §2 方案 C）：对方每出一招，本机开一个 JUDGE_WIN 秒的窗口看结果：
--   血量下降 → hit（附伤害）；出现 *Deflect* 动画且没掉血 → deflect；都没有 → miss
-- 结果 res=<结果号>:<对方招式号>:<hit|deflect|miss>:<伤害> 随状态包重复发 RES_KEEP 秒，对方按结果号去重。
-- 攻击方收到 deflect → 自己吃一个被弹开的硬直；收到 hit/miss 只记录。替身血量以对方回报的 hp 为准
local JUDGE_WIN, RES_KEEP = 1.2, 1.5
local RES_NAME = { hit = "中招", deflect = "格挡", parry = "精防", block = "普通防御", miss = "落空" }

-- v0.23.4 改成"排除法"：以前只认 A / B / DA / DB / Draw_ / SWT… 开头的（v0.17.11 的白名单），pbz_abilities.lua 里很多武器的招
-- 根本不是这种名字——赤者残剑 Normal_A…、双蛇 RA…、紫冥剑 New_A…、乱影 P2_…、偃月刀 SpecialSkill、白影 SpeicalAssault、
-- 霜月 PB / PBB、双刃武器技 JueYing_C——替身用它们砍中你时不开判定窗口，伤害算不上。漏判 = 伤害丢了；
-- 多判只是多开一个判定窗口、到时记"落空"，所以宁可多判：除了明确不是攻击的，都算
local NOT_ATTACK_FAM = { AdvancedDash = 1, SpecialDash = 1, StanceDash = 1, SEx = 1, SEd = 1, AEx = 1, AEd = 1,
                         BEx = 1, BEd = 1, BDEx = 1, BDEd = 1 }   -- 冲刺类、处决 / 被处决（对局里处决都禁用了）
local NOT_ATTACK_PART = { "Passive", "Stance", "Buff", "Drink", "Jump", "Sprint", "Run", "Walk", "ChangeArmed",
                          "BreakEscape", "Execution", "UnArmed", "ToZui", "OutZui", "Summon", "Clone", "Reborn",
                          "Deflect", "Dodge", "Switch", "Tutorial", "_UI", "GEd", "GEx", "_Base" }
local function isAttackAbility(n)
    if ATK_EXTRA[n] then return true end             -- §249 报告 §2.4 的 5 招漏判（表在 LO.isEdgeAttack 上面）
    if LO.isEdgeAttack(n) then return true end      -- v0.17.4：影之武装（GA_<武装>_*，路径在 ShachiAbility/ 下）
    if CHG.VEHICLE.names[n] then return true end    -- §143 泥头车撞人
    -- §182.1 / §182.2 L1+B 特殊技（影杀 YingSha、瞬杀 ShunSha、裂斩 LieZhan，GA_GlobalActionAbilit*_<名>_C_C / _CB_C，_Base 是基类）：
    -- 名字不是 GA_Hun_ 开头，以前不算攻击 → 读秒拦不住、判定窗口不开、武器平衡不管（11-09 实测瞬杀一下 3857 满血）
    -- §183：这就是所有武器的 L1+圈（游戏文本 [Stance]+[Execution]）——单手 / 双手 / 双持分别共用瞬杀 / 裂斩 / 影杀，没有别的武器专属招
    if n:find("^GA_GlobalActionAbilit%a*_") and not n:find("_Base", 1, true) then return true end
    local fam, rest = n:match("^GA_Hun_(%w+)_(.+)_C$")
    if not fam then return false end
    if NOT_ATTACK_FAM[fam] then return false end
    -- 名字里带这些的一定是攻击，哪怕也带下面的排除词：完美闪避反击 PerfectDodge、切刀斩 SWT（含 SwitchForm*_SWT）、反击 Counter
    if rest:find("PerfectDodge", 1, true) or rest:find("SWT", 1, true) or rest:find("Counter", 1, true) then return true end
    -- §185 L1+三角 特殊技里名字带排除词（Switch / Buff）但真出刀的：混沌切形态斩 SwitchForm*、白影刀背敲击 BuffAtk、乱莺鸣剑 / 残钢血刃 *Buff
    -- （以前不算攻击：读秒拦不住、判定窗口不开、武器平衡不管）。凝气于刃 Tang_Buff / Double_Buff 不打人，照旧不算
    if rest:find("^SwitchForm") or rest == "BuffAtk" or ((fam == "LuanYing" or fam == "Iron") and rest:find("Buff$")) then return true end
    local whole = fam .. "_" .. rest      -- 族名也查：喝药是 GA_Hun_Drink_Continuous_C
    for _, k in ipairs(NOT_ATTACK_PART) do
        if whole:find(k, 1, true) then return false end
    end
    return true
end

-- 被格挡时攻击方的硬直。
-- v0.9.0 实测：按 Deflected/Parried/Rebound/Bounce/Recoil/Blocked 搜内存里的 989 个动画，0 个命中；
-- 兜底用的重受击（Hit_Heavy）用户反馈"硬直太大"。改用轻受击，并把名字带 Failed/Stagger/Repel/Clash 的列进日志，
-- 下一轮从里面找真正的"被弹开"（已知有 AM_Hun_Attack_Failed、*_HD_AttackerFailed 这类）
local RECOIL_ANIMS = { "Hun_TangBlade_Hit_Light_F_R_Montage", "Hun_TangBlade_Hit_VeryLight_F_R_Montage",
                       "Hun_LongBlade_Hit_Middle_F_R_Montage" }
-- 防守方格挡成功的动作（v0.6 起玩家格挡时日志里出现的就是这两个）
local DEFLECT_ANIMS = { "Hun_DangKouXiongRen_Deflect_C_Montage", "Hun_DangKouXiongRen_Deflect_D_Montage" }
local RECOIL_HINTS = { "Failed", "Stagger", "Repel", "Clash", "Deflected", "Parried", "Rebound", "Recoil" }

local function firstExisting(list)
    for _, n in ipairs(list) do if montageByName(n) then return n end end
    return nil
end

local function recoilName()
    if NET.stagger ~= nil then return NET.stagger or nil end
    montageByName("")
    local cands = {}
    for n in pairs(montages() or {}) do
        if n:find("Hun") then
            for _, k in ipairs(RECOIL_HINTS) do
                if n:find(k) then cands[#cands + 1] = n; break end
            end
        end
    end
    table.sort(cands)
    out("可能的'被弹开'动作 %d 个（供下一轮挑选）: %s", #cands, table.concat(cands, ", ", 1, math.min(#cands, 60)))
    NET.stagger = firstExisting(RECOIL_ANIMS) or false
    out("被格挡时播: %s", tostring(NET.stagger))
    return NET.stagger or nil
end

local function playNamed(actor, name)
    local asset = name and montageByName(name)
    local ok = (asset and valid(actor) and playOn(actor, asset)) and true or false
    -- 模组自己给替身播的动作，记下来，免得被下面的"掐掉本机反应"误杀
    if ok and sameObj(actor, ST.secondPawn) then ST.pupOwnName, ST.pupOwnFrames = name, 120 end
    return ok
end

-- v0.23.1 替身正在重放对方的攻击招式时返回招式名，否则 nil
local function puppetAttacking(pup)
    if not valid(pup) then return nil end
    for n in pairs(activeAbilities(pup) or {}) do
        if isAttackAbility(n) then return n end
    end
    return nil
end

-- ---- 联网时替身的反应只听对方判定（v0.9.9）
-- 用户反馈"几乎看不到它的精防和防御动作"。日志（20:34:18–21）：我的刀在本机先砍中替身 → 游戏立刻让它播
-- Hun_LongBlade_Hit_* / BreakEscape，对方判定约 0.6 秒后才到，格挡动作一闪就被下一刀的受击盖掉。
-- 不改阵营（改成友方会让锁定失效），而是：本机游戏给替身播的受击 / 破防动作同一帧掐掉，架势保持满值；
-- 对方判定到了再由模组播格挡或受击
local SUPPRESS_PATTERNS = { "_Hit_", "Break", "MoTian_Dodge" }

local function suppressLocalReact()
    if not NET.driving then return end
    local pup = ST.secondPawn
    if not valid(pup) then return end
    if (ST.pupOwnFrames or 0) > 0 then ST.pupOwnFrames = ST.pupOwnFrames - 1 end
    if not PEER.on then TOUCH.watchHp(pup, now()); TOUCH.keepShachi(pup) end      -- §107（§223 观战替身不回报）；§357 木桩不在本机破防
    local m = rawProp(pup, "Mesh")
    if not valid(m) then return end
    local okA, an = pcall(function() return m:GetAnimInstance() end)
    if not (okA and valid(an)) then return end
    local okM, mt = pcall(function() return an:GetCurrentActiveMontage() end)
    if not (okM and valid(mt)) then return end
    local name = shortName(full(mt)) or ""
    if name == ST.pupOwnName and (ST.pupOwnFrames or 0) > 0 then
        if not PEER.on then TOUCH.hitFresh(an, mt, name, now()) end      -- §366 记下它在播，认领期过了接着播也不算新碰到
        return
    end
    -- 禁用对替身的暗杀（用户确认 SEx/SEd 是暗杀）：真人对手不存在"没察觉"。替身没有 AI，游戏把它当未警觉目标，
    -- 两次被暗杀时血量 80% / 满血、架势满、处决血量线 0（21:01:23、18:41:54），血量约 1 秒后被直接写 0。
    -- 替身一开始播 *_SEd_*（被暗杀），同一帧把它和玩家的 *_SEx_*（暗杀）一起停掉
    if name:find("_SEd_", 1, true) then
        pcall(function() an:Montage_Stop(0.0, mt) end)
        local stoppedMe = "（玩家没有在播暗杀动作）"
        local p1 = getP1()
        local pm = valid(p1) and rawProp(p1, "Mesh") or nil
        local okP, pan = pcall(function() return pm:GetAnimInstance() end)
        if okP and valid(pan) then
            local okPM, pmt = pcall(function() return pan:GetCurrentActiveMontage() end)
            local pname = (okPM and valid(pmt)) and (shortName(full(pmt)) or "") or ""
            if pname:find("_SEx_", 1, true) then
                pcall(function() pan:Montage_Stop(0.2, pmt) end)
                stoppedMe = "玩家暗杀 " .. pname .. " 已中断"
            end
        end
        NET.assassBlocked = (NET.assassBlocked or 0) + 1
        NET.reequipIn = 120     -- 约 4 秒后（被暗杀技能结束）重新装武器：GA_Hun_SEd_M_02 里的 GAA_DropWeapon_C 会让替身掉武器
        out("◆ 拦下对替身的暗杀 #%d：替身 %s 已中断，%s（替身血量 %s）", NET.assassBlocked, name, stoppedMe,
            tostring((hpOf(pup))))
        return
    end
    for _, k in ipairs(SUPPRESS_PATTERNS) do
        if name:find(k, 1, true) then
            if k ~= "_Hit_" and not PEER.on then TOUCH.markBreak(name, now()) end       -- §356 破防 / 挣脱也是碰到了
            -- §353 本地 AI 交手中杀气按替身自己的：杀气打空是这边游戏判的破防，照播（真人那边是对方游戏判、发 brk=）
            if k ~= "_Hit_" and AISYNC and AISYNC.ownShachi() then AISYNC.noteBreak(name); return end
            -- §104 受击 = 我的刀在本机碰到替身：按对手历史先播格挡 / 留着受击（破防类照旧一律掐掉，只听对方的 brk=）
            -- §366 同一个受击动作接着播的那些帧不是新碰到：以前每帧都 TOUCH.mark，留着的受击（PRED 只认 40 帧）播到一半我放了下一招，
            -- 下一招马上被记成碰到 → 本地 AI 判中招、0.5 秒等不到 td= 按 400 扣，后来真打中的数比 400 小又被吃掉
            -- （天煞双钺 L1+重击连放：第二下斧子还没飞到就 -400，用户 11-17）
            if k == "_Hit_" and not PEER.on then
                if not TOUCH.hitFresh(an, mt, name, now()) then return end
                TOUCH.mark(now(), nil, true)      -- §107 碰到了（AI 对战据此回报）；§388 新受击动作 = 最近一招
            end
            -- §299 多人：本机游戏给某个替身播了受击 = 我的招碰到了它（只认我自己最近 3 秒出过攻击招的时候；
            -- 替身血量是按对方的包写的，掉血不能当"我打的"，所以不看血量）
            if k == "_Hit_" and PEER.on and NET.myAtkAt and now() - NET.myAtkAt <= 3.0
               and BASEHOOK and BASEHOOK.emit then BASEHOOK.emit("base.puppetContact", pup, now()) end
            if k == "_Hit_" and not PEER.on and PRED.onContact(pup, an, mt, name, now()) then return end      -- §223 观战不预测，挨打只听包里的
            pcall(function() an:Montage_Stop(0.0, mt) end)
            NET.suppressed = (NET.suppressed or 0) + 1
            if NET.suppressed <= 5 or NET.suppressed % 20 == 0 then
                out("掐掉替身的本机反应 #%d：%s", NET.suppressed, name)
            end
            return
        end
    end
end


-- 被格挡时的反应（攻击方本人 + 防守方屏幕上的替身都用同一个）。
-- v0.9.2 用户反馈："收招感觉不是很对，有小硬直么？" → 做成可选：F5 在自己身上逐个预览候选，最后预览的那个生效，存盘
local RETRACT = "收招"
local STAGGER_FILE = REC_DIR .. "/stagger_choice.txt"
local STAGGER_PREFERRED = {
    "Hun_TangBlade_Hit_VeryLight_F_R_Montage", "Hun_TangBlade_Hit_VeryLight_F_L_Montage",
    "Hun_LongBlade_Hit_VeryLight_F_R_Montage", "Hun_LongBlade_Hit_VeryLight_F_L_Montage",
    "Hun_TangBlade_Hit_Light_F_R_Montage", "Hun_TangBlade_Hit_Light_F_L_Montage",
    "Hun_LongBlade_Hit_Light_F_R_Montage", "Hun_LongBlade_Hit_Light_F_L_Montage",
    "AM_Hun_Long_HD_AttackerFailed", "AM_Hun_Tang_HD_AttackerFailed", "AM_Hun_Double_HD_AttackerFailed",
    "AM_Hun_Long_C_Failed", "AM_Hun_Tang_C_Failed", "AM_Hun_Attack_Failed",
}

local function staggerChoices()
    if NET.stChoices then return NET.stChoices end
    montageByName("")
    local list, seen = { RETRACT }, { [RETRACT] = true }
    for _, n in ipairs(STAGGER_PREFERRED) do
        if montageByName(n) and not seen[n] then list[#list + 1] = n; seen[n] = true end
    end
    -- 内存里其他 Hun 的极轻 / 轻受击也补进来
    local extra = {}
    for n in pairs(montages() or {}) do
        if n:find("^Hun_") and (n:find("Hit_VeryLight") or n:find("Hit_Light")) and n:find("_F_") and not seen[n] then
            extra[#extra + 1] = n
        end
    end
    table.sort(extra)
    for _, n in ipairs(extra) do list[#list + 1] = n end
    NET.stChoices = list
    return list
end

local function staggerChoice()
    if NET.stChoice then return NET.stChoice end
    local f = io.open(STAGGER_FILE, "r")
    local v = f and f:read("*l") or nil
    if f then f:close() end
    NET.stChoice = (v and v ~= "") and v or RETRACT
    return NET.stChoice
end

-- 被弹开硬直按武器自动选（用户 2026-11-03 20:25 定）：AM_Hun_<动画大类>_C_Failed，认不出的用通用 AM_Hun_Attack_Failed。
-- 动画大类证据：拿斩马刀放 GA_Hun_ZhanMa_C_C 时游戏自己播的是 AM_Hun_Double_C_Failed（5 次）；
-- 炽刃（存档 ID Long）的技能族就叫 GA_Hun_Long_*；黑伤（Tang）按命名推断
-- 静态表（用户 20:35 指正）：Long = 长兵器（斩马刀、长形黑伤/炽刃），Tang = 唐刀类（黑伤），Double = 各种双刀。
-- 斩马刀放 C 招失败时游戏播的是 AM_Hun_Double_C_Failed（5 次），那是个例外，不代表斩马刀属于 Double；
-- 它的冲刺 / 架势（AM_Hun_Long_Dash_F ×10、AM_Hun_Long_Stance* ×15）和受击（Hun_LongBlade_Hit_*）都是 Long。
-- （v0.9.5 的运行时学习已去掉，见 watchActor 里的说明）；表里没有的武器用通用 AM_Hun_Attack_Failed
-- 2026-11-03 20:45 从游戏数据读出：每把武器的配置资产 Weapon_Hun_<X>.uasset 里有 Weapon.Type.Global.<Single|Two|Dual>Handed
-- 标签（单手 = 唐刀 Tang，双手 = 长兵 Long，双持 = 双刀 Double）。存档 ID → 配置资产按名字对应，见 HANDOVER §19.12
local WEAPON_ANIM_CLASS = {
    -- SingleHanded → Tang
    Tang = "Tang", WoodenSwordHun = "Tang", ZiMingJian = "Tang", SlitheringSword = "Tang", IronBlade = "Tang",
    CiGuHunDun = "Tang", ChiZheCanJian = "Tang", RenOuQingTongJian = "Tang", LuanYing = "Tang",
    -- TwoHanded → Long
    Long = "Long", ZhanMaBlade = "Long", GuiTouBlade = "Long", HorizontalBlade = "Long", Jigsaw = "Long",
    PoJun = "Long", RenOuYanYueDao = "Long", BaiYing = "Long",
    -- DualHanded → Double
    Double = "Double", DualHook = "Double", YuuBlade = "Double", SnakeDual = "Double", JadeDualChakram = "Double",
    TianShaShuangYue = "Double", FangHuaXieShan = "Double", BaiShanShuangJian = "Double",
}
local GENERIC_FAILED = "AM_Hun_Attack_Failed"

local function staggerNameFor(weaponId)
    local cls = weaponId and WEAPON_ANIM_CLASS[weaponId]
    local name = cls and ("AM_Hun_" .. cls .. "_C_Failed") or nil
    if name and montageByName(name) then return name end
    return GENERIC_FAILED
end

-- 对方判定"中招"时由模组给替身播受击（按替身武器的大类选，左右交替）
local function hitNameFor(weaponId, side)
    local cls = weaponId and WEAPON_ANIM_CLASS[weaponId] or "Tang"
    for _, prefix in ipairs({ cls == "Long" and "LongBlade" or "TangBlade", "TangBlade", "LongBlade" }) do
        local n = "Hun_" .. prefix .. "_Hit_Middle_F_" .. side .. "_Montage"
        if montageByName(n) then return n end
    end
    return nil
end

-- §456 本地 AI / 木桩的格挡动作按替身武器大类挑（用户 11-26"AI 木桩的格挡过程没有动作"）。
-- 以前一律播荡寇凶刃的两个精防动作（DEFLECT_ANIMS），这两个动作只有存档里用过荡寇才在内存里，
-- 没加载时 montageByName 拿不到 → "替身格挡 …（失败）"，木桩挡住了却什么都不播。
-- 现在：精防 = <大类>_PD_L1 / PD_R1，普防 = 唐刀 DefenceNormal_A–D / 长兵、双持 DF_L / DF_R（资产在
-- /PBZCombatAsset/ActorData/Players/Hun/Montage/<TangBlade|LongBlade|DoubleBlade>/Deflect/，gasgraph 列出来的）；
-- 内存里没有就按路径加载一次（LO.loadObject，记下来不重复加载）；都不行再退回原来那两个。真人对战不走这里（照旧）
DEFANIM = { n = 0, cache = {}, logs = 0, ROOT = "/PBZCombatAsset/ActorData/Players/Hun/Montage/",
    SETS = {
        Tang = { parry = { "TangBlade/Deflect/New/AM_Hun_Tang_PD_L1", "TangBlade/Deflect/New/AM_Hun_Tang_PD_R1" },
                 block = { "TangBlade/Deflect/New1/Hun_Tang_DefenceNormal_A_Montage", "TangBlade/Deflect/New1/Hun_Tang_DefenceNormal_B_Montage",
                           "TangBlade/Deflect/New1/Hun_Tang_DefenceNormal_C_Montage", "TangBlade/Deflect/New1/Hun_Tang_DefenceNormal_D_Montage" } },
        Long = { parry = { "LongBlade/Deflect/New/AM_Hun_Long_PD_L1", "LongBlade/Deflect/New/AM_Hun_Long_PD_R1" },
                 block = { "LongBlade/Deflect/New/AM_Hun_Long_DF_L", "LongBlade/Deflect/New/AM_Hun_Long_DF_R" } },
        Double = { parry = { "DoubleBlade/Deflect/New/AM_Hun_Double_PD_L1", "DoubleBlade/Deflect/New/AM_Hun_Double_PD_R1" },
                   block = { "DoubleBlade/Deflect/New/AM_Hun_Double_DF_L", "DoubleBlade/Deflect/New/AM_Hun_Double_DF_R" } } } }
function DEFANIM.list(weaponId, kind)
    local set = DEFANIM.SETS[weaponId and WEAPON_ANIM_CLASS[weaponId] or "Tang"] or DEFANIM.SETS.Tang
    return set[kind == "parry" and "parry" or "block"]
end
function DEFANIM.asset(rel)
    local short = rel:match("([^/]+)$")
    local a = montageByName(short)
    if a then return a, short end
    if DEFANIM.cache[rel] == nil then
        DEFANIM.cache[rel] = (LO and LO.loadObject and LO.loadObject(DEFANIM.ROOT .. rel .. "." .. short)) or false
        if DEFANIM.logs < 12 then DEFANIM.logs = DEFANIM.logs + 1; out("§456 格挡动作 %s：内存里没有，按路径加载%s", short, DEFANIM.cache[rel] and "成功" or "失败") end
    end
    return DEFANIM.cache[rel] or nil, short
end
-- §456.1 替身武器 ID：ST.pupWeapon 只在"Add Weapon And SwitchTo"那条路写；对方报了 wc=（SetSlotWeapon 只换替身武器组件，
-- 本地 AI / 木桩都走这条）时它是 nil → 以前一律退成唐刀（11-26 双开：木桩拿双刃 Double 却播 Hun_Tang_DefenceNormal_*）。
-- 退一步用对方包里的武器 ID（NET.rwId）
function DEFANIM.weapon()
    return ST.pupWeapon or NET.rwId
end
-- 给替身播一下格挡动作；返回 是否播了, 动作名
function DEFANIM.play(pup, kind)
    local list = DEFANIM.list(DEFANIM.weapon(), kind)
    DEFANIM.n = DEFANIM.n + 1
    local a, short = DEFANIM.asset(list[(DEFANIM.n - 1) % #list + 1])
    if a and valid(pup) and playOn(pup, a) then
        if sameObj(pup, ST.secondPawn) then ST.pupOwnName, ST.pupOwnFrames = short, 120 end     -- 同 playNamed：别被"掐掉本机反应"误杀
        return true, short
    end
    NET.defIdx = (NET.defIdx or 0) % #DEFLECT_ANIMS + 1
    return playNamed(pup, DEFLECT_ANIMS[NET.defIdx]), DEFLECT_ANIMS[NET.defIdx]
end

-- 让 actor（拿着 weaponId）做"被弹开"的硬直；返回一句描述
local function staggerOn(actor, weaponId)
    local name = staggerNameFor(weaponId)
    return "硬直 " .. name .. "（武器 " .. tostring(weaponId) .. "）" .. (playNamed(actor, name) and "已播" or "失败")
end

-- 连续精防计数。两边按同一串判定结果各自数，所以攻击方本人和防守方屏幕上的替身在同一刀上触发。
-- 被砍中 / 普通防御 / 落空 / 距上次精防超过 STREAK_RESET 秒 → 清零；数到 3 → 触发并清零
-- §228 数到几次跟着数值表（STG.need()，co= 的 StaggerHits，默认 3）；房间设置"精防硬直"关着时数到了也不触发（清零、返回 false）
-- §230.2 用户 11-11 实测（100% 精防的 AI）："我在硬直中却被激活新的硬直""结果导致我最多7-8秒不能动"：
--   多段招每一段都回报一次精防（日志 01:32:35–37 同两招 #878 / #879 来回回报十几次），在硬直里接着数满 3 次又触发、锁重新计时，连了 7 次。
--   ① 同一招（攻击编号 atkId）在这一串里只数一次；② 触发后硬直这段时间（STG.sec() 秒）收到的判定结果都不数（是硬直前出的招的后续段），
--   结束后从 0 重新数。两边各自按同一串结果数，所以攻击方本人和防守方屏幕上的替身仍然在同一刀上触发
local STREAK_RESET = 6.0

-- §432 铁拳套【拳挡四方】GA_TieKuangQuanTao_GuardPoint（用户 11-24"经常会被破招，这是格挡技能，理论上不应当被破招"）：
-- 11-24 IGNIZ 日志 14:06:55–14:07:27：拳挡四方挡住（GpBlock / GpBlock2 → 精防 / 普防，游戏张力会话也记 PerfectDeflect / NormalBlock），
-- 但攻击方要连续 3 次精防才吃硬直（bumpStreak），攻击方本机屏幕写"你继续攻击，替身在出招 GA_TieKuangQuanTao_GuardPoint_C"，
-- 下一刀 0.4–1.2 秒后落在拳套的反击动作（Hun_QuanTao_Deflect_A / D）或还在 GpBlock 上 → 挨打方本机照原生掉血、反击被打断（"破招"）。
-- 原版里拳挡四方挡住后接反击拳（BulletData_TieKuangQuanTao_Counter_01），对手不会接着打。
-- 改：挡住时挨打方正在拳挡四方 → 不数连续精防，攻击方直接吃一次精防硬直（时长同房间设置，STG.secFor），两边按同一条规则：
--   挨打方：格挡动作是拳挡四方的 GpBlock / 反击动作；攻击方：替身（= 挨打方）在播这些动作或拳挡四方技能还挂着
GPD = { GA = "GA_TieKuangQuanTao_GuardPoint_C", logN = 0, LOGS = 30,
        MONS = { RTGHun_Quan_GpAttack_GpBlock = true, RTGHun_Quan_GpAttack_GpBlock2 = true,
                 Hun_QuanTao_Deflect_A_Montage = true, Hun_QuanTao_Deflect_D_Montage = true,
                 Hun_QuanTao_Perfect_Deflect_Attack_03_Montage = true } }
function GPD.isMon(m) return type(m) == "string" and GPD.MONS[m] == true end
-- actor 现在是不是在拳挡四方里（动作或技能）
function GPD.on(actor, m)
    if GPD.isMon(m) then return true end
    if not valid(actor) then return false end
    if GPD.isMon(montageOf(actor)) then return true end
    local ok, acts = pcall(activeAbilities, actor)
    return ok and type(acts) == "table" and acts[GPD.GA] ~= nil
end
function GPD.log(fmt, ...)
    GPD.logN = GPD.logN + 1
    if GPD.logN <= GPD.LOGS then out(fmt, ...) end
end

local function bumpStreak(side, kind, tn, atkId, atkName, gp)   -- §422 atkName = 这一招的技能名（远程招触发时锁得久）；§432 gp = 挨打方在拳挡四方里
    NET.streak = NET.streak or {}
    local s = NET.streak[side] or { n = 0, at = -100, ids = {}, lockUntil = nil }
    NET.streak[side] = s
    s.ids = s.ids or {}
    if s.lockUntil then
        if tn < s.lockUntil then return false, 0 end      -- §230.2 硬直中：不数
        s.lockUntil = nil
    end
    if gp and (kind == "parry" or kind == "block") then   -- §432 拳挡四方挡住：攻击方直接吃硬直，不数连续
        s.n, s.ids, s.at = 0, {}, tn
        if STG.on() then local sec = STG.secFor(atkName); s.lockUntil = tn + sec; return true, 1, sec end
        return false, 0
    end
    if kind == "parry" and atkId ~= nil and s.ids[atkId] and tn - s.at <= STREAK_RESET then return false, s.n end   -- §230.2 同一招的后续段
    if kind ~= "parry" or tn - s.at > STREAK_RESET then s.n, s.ids = 0, {} end
    if kind ~= "parry" then return false, 0 end
    s.n, s.at = s.n + 1, tn
    if atkId ~= nil then s.ids[atkId] = true end
    local need = STG.need()
    if s.n >= need then
        local n = s.n
        s.n, s.ids = 0, {}
        if STG.on() then local sec = STG.secFor(atkName); s.lockUntil = tn + sec; return true, need, sec end
        return false, n
    end
    return false, s.n
end

-- F5：在自己身上预览下一个候选，并把它设为当前选择
local function previewNextStagger()
    local p1 = getP1()
    if not valid(p1) then out("!! 没有玩家1"); return end
    local list = staggerChoices()
    local cur = staggerChoice()
    local idx = 1
    for i, n in ipairs(list) do if n == cur then idx = i end end
    idx = idx % #list + 1
    local pick = list[idx]
    NET.stChoice = pick
    fileWrite(STAGGER_FILE, pick .. "\n")
    if pick == RETRACT then
        out("被格挡反应 [%d/%d] = 收招（中断当前动作，无受击动作）", idx, #list)
    else
        local asset = montageByName(pick)
        local dur = asset and playOn(p1, asset)
        out("被格挡反应 [%d/%d] = %s（时长 %s 秒）—— 仅预览；实战已改为按武器自动选 AM_Hun_<类>_C_Failed",
            idx, #list, pick, dur and string.format("%.2f", dur) or "?")
    end
end

local function addResult(kind, attackId, value, tn)
    if PEER.on then return end          -- §223 观战替身不判定、不回报
    NET.resId = NET.resId + 1
    NET.results[#NET.results + 1] = { id = NET.resId, atk = attackId, kind = kind, v = value or 0, at = tn }
    NET.judged[kind] = (NET.judged[kind] or 0) + 1
    out("判定 远端#%d → %s%s%s", attackId, RES_NAME[kind] or kind,
        (value or 0) > 0 and string.format(" -%.0f", value) or "", (value or 0) > 0 and NET.pupAtkNote() or "")
    -- §347 中招 / 落空也把"我精防对方"这一串清零：攻击方收到结果时（applyRemoteResult 的 bumpStreak("atk")）每种结果都会数，
    -- 防守方以前只在精防 / 普防时数，中间夹一下中招两边就数岔了（防守方屏幕上替身吃硬直、对方本人没吃）
    if kind == "hit" or kind == "miss" then bumpStreak("def", kind, tn, attackId) end
    if kind == "parry" and PDSH and AISYNC and AISYNC.ownShachi and AISYNC.ownShachi() then PDSH.drain(puppet(), "def", attackId, false) end   -- §423 我精防本地 AI：扣替身的（AI 杀气按替身）
    return NET.results[#NET.results]
end

local function openJudge(p1, attackId, tn, name)
    if PEER.on then return end          -- §223 观战替身不判定（p1 是另一个替身）
    if #NET.judges == 0 then NET.judgeHp = hpOf(p1) end
    NET.judges[#NET.judges + 1] = { id = attackId, at = tn, def = false, name = name }
end

-- 精防 / 普通防御的区分（用户 2026-11-03 20:30 定）：
--   格挡后 DEF_OBSERVE 秒内杀气**没有被消耗** → 精防；被消耗了（单次采样下降 ≥ BLOCK_DROP）→ 普通防御。
--   杀气平时只会自然回复（每 0.1 秒约 +10），所以出现下降就是防御消耗。
--   不用"精防回杀气"（实测 +60~+70 的跳涨）判断：那是天赋 GA_Talent_PerfectDeflectRecoveryShachi，不一定会点
local BLOCK_DROP, DEF_OBSERVE = 15, 0.4

finishDeflect = function(p1, tn)
    local pd = NET.pendDef
    NET.pendDef = nil
    if not pd then return end
    -- §425 游戏放的是普通防御动作（DefenceNormal）→ 直接定普通防御：这组动作只在游戏判普防时放，比看杀气准
    --   （杀气在 0.4 秒里没掉的普防以前会被判成精防）；其余格挡动作照旧看杀气
    local gk = BLK.gameKind(pd, tn)     -- §425.7 先按游戏自己记的结果；读不到再按动作 / 杀气
    if gk == "none" then                -- §425.9 游戏没判成格挡：窗口还回去
        NET.judges[#NET.judges + 1] = pd.j
        return
    end
    -- 读不到游戏结果时的兜底（§425.10）：11-23 唐刀实测游戏判精防的 16 次也全是 DefenceNormal 动作，"普通防御动作 = 普防"不成立；
    --   精防那下常有 +60 的跳涨（精防回杀气），先认它；再按普通防御动作 / 杀气降没降
    local kind = gk or ((pd.jump >= BLK.PARRY_JUMP and "parry") or ((pd.normal or pd.drop <= -BLOCK_DROP) and "block" or "parry"))
    addResult(kind, pd.j.id, 0, tn)
    local gp = GPD.isMon(pd.m) or GPD.on(p1)      -- §432 我在拳挡四方里挡住的
    local fire, n, sec = bumpStreak("def", kind, tn, pd.j.id, pd.j.name, gp)     -- §230.2 带攻击编号；§422 带招名
    if gp then GPD.log("§432 拳挡四方挡住 远端#%d %s（%s，动作 %s）→ %s", pd.j.id, tostring(pd.j.name), RES_NAME[kind] or kind,
        tostring(pd.m), fire and "对方直接吃精防硬直（不数连续）" or "精防硬直没开 / 对方还在硬直里") end
    out("  分类依据：%s动作 %s%s，杀气最大单步 %+.0f / 最大单步下降 %+.0f → %s%s", gk and "游戏记的结果（§425.7）；" or "", pd.m, (not gk and pd.normal and pd.jump < BLK.PARRY_JUMP) and "（普通防御动作）" or "",
        pd.jump, pd.drop, RES_NAME[kind], kind == "parry" and string.format("（连续第 %d 次）", n) or "")
    if fire then
        -- 我连续精防对方 3 次：我屏幕上的替身吃硬直。对方机器上它的真身收到同样 3 个 parry 后自己吃
        out("  替身被连续精防 %d 次（%s，对方锁 %.1f 秒）→ %s", n, tostring(pd.j.name), sec or 0, staggerOn(puppet(), ST.pupWeapon))
    end
end

-- §87 全部可格挡（docs/PVP_RULES_DESIGN.md §2）。
-- 第 0 步探针（只记日志）：我正在格挡（动作名带 Deflect / Stance，或架势技能 *Stance* 挂着）却被对方这招掉了血 → 记下这招、
--   我的动作 / 杀气、我身上"不能格挡"标签，最多 BLK.MAX 条；挡住了的也记前 BLK.OK_MAX 条当对照。
--   2026-11-05 实测（§87）：抓到的那条是灵蛇软剑 Potential（资产标 UltraStrong），杀气没耗尽、我身上没有 CanNotDeflect →
--   挡不住靠的是招的力度等级，在游戏里改不到 → 方案 B 软格挡。
--   15:32 那次崩溃之后降风险：每帧只记"最后一次在格挡的时刻"（不调游戏）；查标签只在中招那一刻、最多 MAX 次；不再数 GE
-- 方案 B 软格挡（房间设置"全部可格挡"开着、交手中）：格挡中（或刚松开 GRACE 秒内）被打掉血，杀气没耗尽、不在破防中 →
--   把血补回去、按防御回报（攻击方那边替身播格挡动作）、我播格挡动作；同一招后面几段掉的血也补。
--   精防 / 普防按时机分（用户 2026-11-05：游戏里精防的判断窗口是 0.4 秒）：挨打时距"开始格挡"不到 PARRY_WIN 秒 → 精防，
--   杀气也写回挨打前（原生精防不扣杀气，被打穿时游戏已经扣了）；更早就按住了 → 普防，杀气是游戏自己扣的，照算。
--   精防同样计入连续精防（3 次对方吃硬直）。"开始格挡"= 从不在格挡变成在格挡的那一帧（BLK.watch，发包时每帧看一次，不调游戏）。
--   杀气耗尽 / 破防中（破防挣脱挂着或刚开始 BRK_HOLD 秒内）照常中招（破防保留）。处决 / 抓取不开判定窗口，不管
-- §90.1 实测修（2026-11-05 17:03–17:04 日志）：
--   ① 双钩 A / 灵蛇 A / 醉剑 A / Double B 被误判"格挡中掉血"：挨打前一帧玩家在播 AM_Hun_Long_StanceExit（松开格挡），
--     以前"动作名带 Stance"就算在格挡。现在 StanceExit 不算；受击动作那一帧不改判断（保留上一次看到的）；
--     软格挡要求"最后一次看到时在格挡"（BLK.on），GRACE 只防读数过期，不再给"刚松开"放宽。
--     妖锯 A–AAAAA 一连串照样软格挡是对的：每轮妖锯 A 给我挂 GA_YaoJu_MonsterErosion_BP_C、C（Buff）之后，
--     一直按着的架势（动作空、架势技能挂着 7 秒）也挡不住——这是妖锯本身的机制
--   ② 画面上只看到受击：原生格挡动作是架势技能自己播的（不出"-技能 Stance"）；被打穿时受击已经把架势结束了，
--     我们播的格挡动作马上被按着格挡重进的 StanceEnter 盖掉，同一招后几段的受击动作也没盖。
--     现在受击动作一出现就停掉换成格挡动作（BLK.frame，每帧、只在"可能软格挡"时读一次玩家动作）：
--     软格挡后 COVER 秒内（后几段）、以及判定窗口开着 + 在格挡 + 设置开着时抢先（不等掉血那一跳）。
--     只碰受击动作：StanceEnter / 架势本身一律不碰，不打断真的架势。不用 ChangeHitState（§41：只改状态不改画面）
-- 全局表（主代码块 local 已满 200 个）
BLK = { MAX = 20, OK_MAX = 10, GRACE = 0.3, BRK_HOLD = 1.5, PARRY_WIN = 0.4, n = 0, ok = 0, soft = 0, anim = 0,
        at = -100, start = -100, on = false, why = "",
        COVER = 1.0, coverUntil = -100, swapAt = -100, SWAP_GAP = 0.1, swaps = 0, preSwaps = 0,
        ME_TAGS = { "CharacterState.AIState.CanNotDeflect", "CharacterState.AbilityState.YuuBlade.ExplodeCannotDeflect" },
        -- 资产扫描（docs/PVP_RULES_DESIGN.md §2.1）：技能资产的名字表里带 Deflect.Strength.UltraStrong 的 7 招
        ULTRA = { GA_Hun_ChiZheCanJian_Tipsy_BBB_C = 1, GA_Hun_DualHook_AAAA_C = 1, GA_Hun_DualHook_DB_C = 1,
                  GA_Hun_DualHook_PerfectDodge_HeavyAttack_C = 1, GA_Hun_SlitheringSword_DA_C = 1,
                  GA_Hun_SlitheringSword_EvalutionCombo_New_C = 1, GA_Hun_SlitheringSword_Potential_C = 1 } }

-- §347 "格挡被破"动作（AM_Hun_Deflect_Break_L：我的攻击 / 格挡被对方的防反、UltraStrong 招打破）。名字带 Deflect，
-- 以前被当成"刚切到格挡动作"：判定窗口被拿去按杀气分精防 / 普防，后面防反那一刀掉的血没窗口认领、整段没算（11-16 别离残钩 DB）
function BLK.isBreak(m)
    return m ~= nil and (m:find("Deflect_Break", 1, true) or m:find("DeflectBreak", 1, true)) ~= nil
end

-- §425 刚挨了一下、游戏放的"格挡住"动作（不含格挡被破，那个单独走 §347）：
--   Deflect = 精防 / 防反类；DefenceNormal = 唐刀 / 青铜剑 / 蛇剑等架势里普通防御挨的那一下（Hun_Tang_DefenceNormal_A–D_Montage、AM_Hun_SlitheringSword_DefenceNormal_*）；
--   GpBlock = 铁矿拳套 Guard Point 挡住（RTGHun_Quan_GpAttack_GpBlock / 2）。以前只认 Deflect，普通防御挡住全记落空（外部补丁报的，11-22 日志核实）。
--   不收：AM_Hun_*_DF_/DB_/DH_（举着架势前后左右走）、Special_Defence（鬼柴 / 别离残钩的特殊攻击）、整个 GuardPoint 技能（是攻击）。
function BLK.isReact(m)
    if not m or BLK.isBreak(m) then return false end
    return (m:find("Deflect", 1, true) or m:find("DefenceNormal", 1, true) or m:find("GpBlock", 1, true)) ~= nil
end

-- §425.5 / §425.7 精防 / 普防按游戏自己记的结果判（只读）：张力系统给"boss"开的会话里有 RecentEvents（OutcomeTag + 游戏时间），
--   精防记 Defense.PerfectDeflect（含 .PowerAttack）、普防记 Defense.NormalBlock。11-23 本地 AI 对照 18 次：杀气判精防 13 次游戏只认 3 次。
--   取"这次格挡动作出现前 TEN_PAD 秒到现在"里时间最早的一条 Defense.* 事件：精防 → parry、普防 → block；
--   没会话 / 窗口里没有 / 是破防等别的结果 → 返回 nil，照旧按杀气判。每次启动前 BLK.TEN_MAX 次写对照日志；net/tension_off.txt 整个关掉
BLK.TEN_MAX, BLK.tenN, BLK.TEN_PAD = 200, 0, 0.3
BLK.PARRY_JUMP = 50     -- §425.10 兜底：杀气单步涨这么多算精防（精防回杀气天赋 +60）
-- 只认格挡类事件（§425.9：NoResponseHit / Grabbed 是挨了别的招，19:13 有 4 次排在真格挡前面被当成"最早一条"）
BLK.TEN_GUARD = { PerfectDeflect = true, NormalBlock = true, GuardBreak = true, HitWhileBlocking = true }
function BLK.tenOff()
    if BLK.tenOffV == nil then
        local f = io.open(ROOT .. "/net/tension_off.txt", "r")
        BLK.tenOffV = f ~= nil
        if f then f:close() end
    end
    return BLK.tenOffV
end
function BLK.gameKind(pd, tn)
    if not G.tensionLast or BLK.tenOff() then return nil end
    local ok, r, why = pcall(G.tensionLast, puppet(), 6)
    local note
    local kind
    if not ok then note = "出错 " .. tostring(r)
    elseif not r then note = "替身" .. tostring(why)
    else
        local now = tonumber(r.now) or 0
        if BLK.tenUsed and now < (BLK.tenNow or 0) - 1 then BLK.tenUsed = nil end     -- 换图 / 新会话：游戏时间往回走
        BLK.tenNow = now
        local from = now - (tn - pd.at) - BLK.TEN_PAD
        -- 每条事件只给一次判定用（11-23 19:06:27：两招 0.2 秒内先后被挡，第二次又拿到第一次用过的普防）
        local first
        for _, e in ipairs(r.ev) do
            if e.t >= from and (not BLK.tenUsed or e.t > BLK.tenUsed + 0.001) and BLK.TEN_GUARD[e.tag:match("^Defense%.(%a+)") or ""]
                and (not first or e.t < first.t) then first = e end
        end
        if first then
            BLK.tenUsed = first.t
            if first.tag:find("^Defense%.PerfectDeflect") then kind = "parry"
            elseif first.tag == "Defense.NormalBlock" then kind = "block" end
        end
        local l = {}
        for _, e in ipairs(r.ev) do l[#l + 1] = string.format("%s@%.1f", e.tag, e.t) end
        -- §425.9 有会话、窗口里一条格挡事件都没有 = 游戏没判成格挡（19:11–19:13 六次都是对方打空 Hidden.Whiffed、荡寇按键自己放的格挡动作）
        --   → 不算防住，窗口还回去照常等（打中按中招、到期记落空）；以前按杀气全判成了精防
        if not first then kind = "none" end
        note = string.format("游戏最近 %s（现在 %.1f，从 %.1f 起算）→ %s", table.concat(l, "，"), tonumber(r.now) or -1, from,
            first and (first.tag .. (kind and "" or "（不是精防 / 普防，按杀气）")) or "窗口里没有格挡事件：游戏没判成格挡，不算防住")
    end
    if BLK.tenN < BLK.TEN_MAX then
        BLK.tenN = BLK.tenN + 1
        out("§425.7 游戏判定 #%d 远端#%d：%s", BLK.tenN, pd.j.id, note)
    end
    return kind
end
-- 替身接上输入组件 + 技能输入组件的控制器（和 §140 输入实验同样三步）。11-23 两次都是输入实验接上之后替身才有张力会话，
-- 改成每回合倒计时就接。返回说明（日志用）
function BLK.tenAttach(pup)
    if BLK.tenOff() or not valid(pup) then return nil end
    local parts = {}
    if G.inputEnsure then
        local okE, comp, how = pcall(G.inputEnsure, pup)
        parts[#parts + 1] = "输入组件 " .. (okE and tostring(how) or ("出错 " .. tostring(comp)))
    end
    local aic = rawProp(pup, "Ability Input Component")
    if valid(aic) and not valid(rawProp(aic, "Controller")) then
        local ctl = rawProp(pup, "Controller")
        local okC = valid(ctl) and pcall(function() aic.Controller = ctl end)
        parts[#parts + 1] = "技能输入组件控制器 " .. (okC and "接上" or "没接上")
    end
    return table.concat(parts, "；")
end

-- §425 游戏判了普通防御才放的动作（精防放的是 Deflect 类）
function BLK.isNormal(m)
    return m ~= nil and m:find("DefenceNormal", 1, true) ~= nil
end

-- 我现在算不算在格挡：返回依据（nil = 不在）。m = 我这一帧的动作名，act = 我挂着的招式技能（NET.prevAbs）
-- StanceExit = 松开格挡（收架势），不算（§90.1：松开那一下被打中以前被当成格挡中）；格挡被破（§347）也不算
function BLK.guarding(m, act)
    if m and m:find("StanceExit", 1, true) then return nil end
    if BLK.isBreak(m) then return nil end
    if m and (m:find("Deflect", 1, true) or m:find("Stance", 1, true) or BLK.isReact(m)) then return "动作 " .. m end
    for n in pairs(act or {}) do
        if n:find("Stance", 1, true) or n:find("Deflect", 1, true) then return "技能 " .. n end
    end
    return nil
end

-- 每帧（netSend 发包时、netJudge 有判定窗口时）：记"开始格挡"和"最后一次在格挡"的时刻。只看已经读到的动作名 / 技能表，不调游戏
-- 受击动作那一帧不改判断：挨打这一帧架势技能已经被结束了，要看的是挨打之前在不在格挡（格挡被破 §347 同理：
-- 之前按着格挡的照旧算在格挡、软格挡照常；之前在出招的不会因为这个动作名带 Deflect 被当成在格挡）
function BLK.watch(m, act, tn)
    if LO.isHitMontage(m) or BLK.isBreak(m) then return end
    local why = BLK.guarding(m, act)
    if why then
        if not BLK.on then BLK.start = tn end
        BLK.on, BLK.at, BLK.why = true, tn, why
    else
        BLK.on = false
    end
end
function BLK.track(m, tn) BLK.watch(m, NET.prevAbs, tn) end

function BLK.list(t) return (t and #t > 0) and table.concat(t, " ") or "无" end
function BLK.ultra(name) return BLK.ULTRA[name or ""] and "（资产标 UltraStrong）" or "" end

-- Corrected, uncompensated loss only; native attack-grade evidence stays in the controller.
function BLK.guardLoss(p1, j, dmg, tn, m, shNow)
    if not CTRREC or not LO.isHitMontage(m) then return end
    local guarding = BLK.on == true and tn >= BLK.at and tn - BLK.at <= BLK.GRACE
    local breaking = not (type(shNow) == "number" and shNow > 0) or j.brk ~= nil
        or BLK.isBreak(m) or BLK.ULTRA[j.name or ""] ~= nil or BLK.isCounter(j)
        or tn - (NET.brkAt or -100) < BLK.BRK_HOLD
        or (NET.prevAbs and NET.prevAbs.GA_Hun_BreakEscape_C == true)
    CTRREC.onDamage(p1, tn, dmg, guarding, breaking == true)
end
-- netJudge 判出掉血时调（先于软格挡）。mPrev = 上一帧我的动作
function BLK.onHit(p1, j, dmg, tn, mPrev, m, shPrev, shNow)
    if BLK.n >= BLK.MAX or tn - BLK.at > BLK.GRACE then return end
    BLK.n = BLK.n + 1
    out("格挡探针 #%d/%d：格挡中掉血 远端#%d %s%s -%.0f", BLK.n, BLK.MAX, j.id, j.name or "?", BLK.ultra(j.name), dmg)
    out("  我：格挡依据 %s（%.2f 秒前），动作 %s → %s，杀气 %s → %s，破防挣脱 %s；身上标签 %s；替身动作 %s", BLK.why, tn - BLK.at,
        tostring(mPrev), tostring(m), tostring(shPrev), tostring(shNow),
        (NET.prevAbs and NET.prevAbs["GA_Hun_BreakEscape_C"]) and "挂着" or "没有",
        BLK.list(G.tagsMatching(p1, BLK.ME_TAGS)), montageOf(puppet()))
    if BLK.n == BLK.MAX then out("格挡探针记满 %d 条，不再记", BLK.MAX) end
end

-- 对照：挡住了（切到格挡动作、没掉血）的招。不调游戏
function BLK.onBlock(j, m)
    if BLK.ok >= BLK.OK_MAX then return end
    BLK.ok = BLK.ok + 1
    out("格挡探针（挡住，对照）%d/%d：远端#%d %s%s，我的动作 %s", BLK.ok, BLK.OK_MAX, j.id, j.name or "?", BLK.ultra(j.name), m)
end

-- 软格挡能不能用：返回 是否, 原因
function BLK.softOk(tn, shNow)
    if not (MATCH.ab and NET.fighting()) then return false, "没开" end
    if not BLK.on or tn - BLK.at > BLK.GRACE then return false, "没在格挡" end
    if (NET.prevAbs and NET.prevAbs["GA_Hun_BreakEscape_C"]) or tn - (NET.brkAt or -100) < BLK.BRK_HOLD then return false, "破防中" end
    if not shNow or shNow <= 0 then return false, "杀气耗尽" end
    return true, nil
end

-- 受击动作 → 立刻停掉、换成格挡动作（C / D 轮流）。返回 播的动作名, 是否成功；SWAP_GAP 秒内只换一次（防止每帧来回）
function BLK.swap(p1, m, tn)
    if tn - BLK.swapAt < BLK.SWAP_GAP then return nil, false end
    BLK.swapAt = tn
    cutMontage(p1)
    BLK.anim = BLK.anim % #DEFLECT_ANIMS + 1
    BLK.swaps = BLK.swaps + 1
    local name = DEFLECT_ANIMS[BLK.anim]
    local ok = playNamed(p1, name)
    -- 自己换上的格挡动作不能被 netJudge 当成"原生挡住了下一招"（它只认动作名刚变成 Deflect 的那一帧）
    if ok then NET.judgeMontage = name end
    return name, ok
end

-- 软格挡时盖受击：m 是受击动作才换；不是（已经被换过，或架势已经重进）就不碰。返回日志用的说明
function BLK.cover(p1, m, tn)
    BLK.coverUntil = tn + BLK.COVER
    if BLK.isReact(m) then return "已经是格挡动作 " .. m end      -- §425 普通防御 / GpBlock 也算
    if not (LO.isHitMontage(m) or BLK.isBreak(m)) then return "画面上没在受击（" .. ((m and m ~= "") and m or "架势") .. "），不播" end
    local a, ok = BLK.swap(p1, m, tn)
    if not a then return "刚换过" end
    return string.format("受击 %s → 播 %s %s", m, a, ok and "已播" or "失败")
end

-- 每帧（LoopInGameThreadAfterFrames）：可能软格挡时读一次玩家动作，是受击就换成格挡动作。
-- 条件同软格挡（设置开着、交手中、在格挡、没破防、杀气够），再加：判定窗口开着（抢先，不等 netJudge 看到掉血），
-- 或软格挡后 COVER 秒内（同一招后几段）。条件不满足时一个游戏函数都不调
function BLK.frame()
    if not (MATCH.ab and NET.fighting()) then return end
    local tn = now()
    local after = tn < BLK.coverUntil
    if not after and #NET.judges == 0 then return end
    if not BLK.on or tn - BLK.at > BLK.GRACE then return end
    if (NET.prevAbs and NET.prevAbs["GA_Hun_BreakEscape_C"]) or tn - (NET.brkAt or -100) < BLK.BRK_HOLD then return end
    if (NET.prevSh or 0) <= 0 then return end
    local p1 = getP1()
    if not valid(p1) then return end
    local m = montageOf(p1)
    if not (LO.isHitMontage(m) or BLK.isBreak(m)) then return end     -- §347 格挡被破的动作也盖（按着格挡时才会走到这）
    local sh = attrOf(p1, "Shachi")
    if not sh or sh <= 0 then return end        -- 这一下把杀气打空了 = 破防，不盖
    local a, ok = BLK.swap(p1, m, tn)
    if not a then return end
    if not after then BLK.preSwaps = BLK.preSwaps + 1 end
    if BLK.swaps <= 30 or BLK.swaps % 20 == 0 then
        out("全部可格挡：%s盖受击 %s → %s %s（第 %d 次）", after and "后续一段 " or "抢先 ", m, a, ok and "已播" or "失败", BLK.swaps)
    end
end

-- 掉血那一帧：能软格挡就补血、按时机记精防 / 普防，返回结果；不能返回 nil（照常中招）。shPrev = 上一帧（挨打前）的杀气，
-- m = 这一帧我的动作（nil 时自己读）
function BLK.soften(p1, j, dmg, tn, shNow, shPrev, m)
    local ok, why = BLK.softOk(tn, shNow)
    if not ok then
        if why == "破防中" or why == "杀气耗尽" then
            out("全部可格挡：远端#%d %s 格挡中掉血 -%.0f，但%s → 照常中招（破防保留）", j.id, j.name or "?", dmg, why)
        end
        return nil
    end
    local since = tn - BLK.start
    local kind = since <= BLK.PARRY_WIN + 1e-6 and "parry" or "block"
    setAttr(p1, "Health", NET.judgeHp)
    local shTxt = string.format("杀气 %.0f 照算", shNow)
    if kind == "parry" and shPrev and shPrev > shNow then
        setAttr(p1, "Shachi", shPrev)
        shTxt = string.format("杀气 %.0f → %.0f 补回", shNow, shPrev)
    end
    BLK.soft = BLK.soft + 1
    local cv = BLK.cover(p1, m or montageOf(p1), tn)
    local r = addResult(kind, j.id, 0, tn)
    local fire, n, sec = bumpStreak("def", kind, tn, j.id, j.name)     -- §230.2 带攻击编号；§422 带招名
    out("全部可格挡：远端#%d %s%s 格挡中掉血 -%.0f → 软%s（开始格挡 %.2f 秒后挨打%s，补回血，%s），%s（第 %d 次）",
        j.id, j.name or "?", BLK.ultra(j.name), dmg, kind == "parry" and "精防" or "格挡（普防）", since,
        kind == "parry" and string.format("，连续第 %d 次精防", n) or "",
        shTxt, cv, BLK.soft)
    if fire then out("  替身被连续精防 %d 次（%s，对方锁 %.1f 秒）→ %s", n, tostring(j.name), sec or 0, staggerOn(puppet(), ST.pupWeapon)) end
    return r
end

-- §347 防反 / 完美反击诊断（只记日志，不改伤害）：11-16 别离残钩 DB 防反实际掉血比手算公式高 ×1.56、我破防时 ×2.34，来源没查清。
-- 每一段记：第几段、这一段实际掉血、这招累计、按平衡表算的一招预测（CAP.expected / §339 CAP.allExpected，口径同"§339 试算"）、
-- 累计 / 预测倍数、我在不在破防中、替身当时的攻击力。武器平衡没开 / 表里没这招时预测写"没有"
BLK.BRK_KEEP, BLK.PEND_HIT, BLK.ctrN = 1.2, 20, 0
function BLK.counterDiag(id, name, seg, step, total, brkM, tn)
    BLK.ctrN = BLK.ctrN + 1
    local exp, why
    if CAP.expected then exp, why = CAP.expected(name) end
    if not exp and CAP.allExpected then exp, why = CAP.allExpected(name) end
    local pup = puppet()
    local pa = valid(pup) and attrOf(pup, "Attack")
    out("§347 防反诊断 #%d：远端#%d %s 第 %d 段 实际 -%.0f（这招累计 -%.0f）；按公式一招预测 %s；累计 / 预测 %s；%s；我破防中 %s；替身 Attack %s",
        BLK.ctrN, id, name or "?", seg, step, total,
        exp and string.format("-%.0f（%s）", exp, why or "") or "没有（武器平衡没开或表里没这招）",
        (exp and exp > 0) and string.format("×%.2f", total / exp) or "?",
        brkM and ("先出现格挡被破 " .. brkM) or "没出现格挡被破",
        tn - (NET.brkAt or -100) < BLK.BRK_HOLD and "是" or "否",
        type(pa) == "number" and string.format("%.1f", pa) or "?")
end
-- 这一招算不算防反类（要记诊断）：先出现了格挡被破，或招名带 Counter（DeflectCounter / PerfectCounter 之类）
function BLK.isCounter(j) return j.brk ~= nil or (j.name ~= nil and j.name:find("Counter", 1, true) ~= nil) end

local function netJudge(p1, tn)
    if CTRREC then CTRREC.observe(p1, tn) end -- Copy incoming-frame scalars before consumed frames disappear.
    -- §434 结果按"最后一次变动"起算留 RES_KEEP 秒（r.upd = 追加命中那一刻）。以前按第一下起算：后面的段晚于第一下
    -- 1.5 秒（实际 1.0–1.2 秒后就赶不上最后几个包）累加进 r.v 也发不出去，攻击方看不到。11-24 墨血无痕：AAA 第一下 -24、
    -- AAA_02 -125、AAA_03 -273（+1.1 秒），对方只收到前两下；AA 远端#315 本机累计 -69、对方只收到 -16
    do
        local rs, n, len = NET.results, 0, #NET.results
        for i = 1, len do
            local r = rs[i]
            if tn - (r.upd or r.at) <= RES_KEEP then
                n = n + 1
                if n ~= i then rs[n] = r end
            end
        end
        for i = len, n + 1, -1 do rs[i] = nil end
    end
    local shNow = attrOf(p1, "Shachi")
    local shPrev = NET.prevSh
    NET.prevSh = shNow
    CAP.flush(NET.lastHit and NET.lastHit.r)          -- §199.9 被吃过跳伤的招结束了 → 记合计
    YQX.fix(p1, tn)                                   -- §361 妖锯妖气爆发只留 5%（在早返回之前：爆发不一定落在招式窗口里）
    HQX.fix(p1, puppet(), tn)                         -- §371 黑魔伤魔剑额外剑气只留 75%（同上，剑气飞过来可能在招式窗口外）
    if SHIELD and SHIELD.guard then SHIELD.guard(p1, puppet(), tn) end   -- §455 替身自己的盾反不算（在分段 / 判定之前补回）
    if SLIDE455 and SLIDE455.sync then SLIDE455.sync(NET.fighting()) end  -- §455 悬浮盾第一下交手中按踉跄
    if SEG1121 then SEG1121.fix(p1, puppet(), tn) end
    if #NET.judges == 0 and not NET.pendDef and not NET.lastHit
        and not (NET.fighting() and ST.summonArmAt and tn - ST.summonArmAt <= SUMD.FIELD_HOLD) then return end
    local hp = hpOf(p1)
    local m = montageOf(p1)
    -- §155 回过血（回合开始补满 / 喝药）→ 上一招的多段累加到此为止；倒地动作里掉的血（摔死 / 锁血钳住）不算任何一招打的
    if hp and NET.judgeHp and hp > NET.judgeHp + 0.5 then NET.lastHit = nil end
    if m:find("_Dead", 1, true) then NET.judgeHp = hp; NET.lastHit = nil; return end
    local newDeflect = (BLK.isReact(m) or BLK.isBreak(m)) and m ~= NET.judgeMontage   -- 只认"刚切到格挡动画"那一帧（§425 普通防御 / GpBlock 也算；按住架势不算）
    local mPrev = NET.judgeMontage
    NET.judgeMontage = m
    if #NET.judges > 0 then BLK.track(m, tn) end      -- §87 记最后一次在格挡的时刻
    -- §347 刚切到格挡动作、还在观察杀气分精防 / 普防（pendDef）时本机掉了血 → 这招不算防住：窗口还回去，下面按中招走
    -- （门槛 BLK.PEND_HIT 点，免得冰缓 / 点燃这类每跳几点的持续伤害把真防住的招翻成中招）
    if #NET.judges == 0 and not NET.lastHit and NET.pendDef and hp and NET.judgeHp and hp < NET.judgeHp - BLK.PEND_HIT then
        local pd = NET.pendDef
        NET.pendDef = nil
        out("§347 远端#%d 格挡动作 %s 之后 %.2f 秒内掉血 -%.0f → 不算防住，按中招", pd.j.id, tostring(pd.m), tn - pd.at, NET.judgeHp - hp)
        NET.judges[#NET.judges + 1] = pd.j
    end
    -- 掉血 / 格挡都记给最近开的那个窗口（连招时前一刀的窗口继续等）。中招立即回报；格挡先观察 DEF_OBSERVE 秒分类
    -- §381 窗口开着时掉血，但身上挂着持续伤害、没出受击动作：先等 DTICK.WAIT 秒看是不是刀（hold）；是跳伤（tick）就不占这一招的窗口
    local dtick = (#NET.judges > 0 and not newDeflect and hp and NET.judgeHp and hp < NET.judgeHp - 0.5)
        and DTICK and DTICK.defCheck(p1, m, NET.judges[#NET.judges], NET.judgeHp - hp, tn) or nil
    if dtick == nil and DTICK then DTICK.hold = nil end
    local open = #NET.judges > 0 and dtick ~= "tick"
    if dtick == "hold" then
        -- 这一帧不判，NET.judgeHp 也不动（下面），下一帧带着这次掉的血接着看
    elseif open and hp and NET.judgeHp and hp < NET.judgeHp - 0.5 then
        local j = table.remove(NET.judges)
        BLK.onHit(p1, j, NET.judgeHp - hp, tn, mPrev, m, shPrev, shNow)
        local soft = BLK.soften(p1, j, NET.judgeHp - hp, tn, shNow, shPrev, m)   -- §87 全部可格挡：格挡中掉血 → 补血、按时机判精防 / 普防
        if soft then
            NET.lastHit = { r = soft, at = tn, soft = true }
            hp = NET.judgeHp
            LAT.learnFrom(j.id, "格挡", tn)
        else
            local gun = GDMG.fix(p1, j.id, j.name, NET.judgeHp - hp, NET.judgeHp, tn)   -- §212 对方火枪这一下只扣每发的数
            if gun then hp = NET.judgeHp - gun end
            local zdb = not gun and ZDB.fix(p1, j.id, j.name, NET.judgeHp - hp, NET.judgeHp, tn)   -- §370 紫冥剑布局分件倍数
            if zdb then hp = NET.judgeHp - zdb end
            local torn = not gun and not zdb and TORN.fix(p1, j.id, j.name, NET.judgeHp - hp, NET.judgeHp, tn)   -- §383 刺骨混沌火焰龙卷 ×1.2
            if torn then hp = NET.judgeHp - torn end
            local sum = not gun and not zdb and not torn and SUMD.fix(p1, j.name, NET.judgeHp - hp, NET.judgeHp, tn)   -- §242 对方召唤物每下 1 点
            if sum then hp = NET.judgeHp - sum end
            local cc = not gun and not zdb and not torn and not sum and CARTCAP and CARTCAP.fix(p1, j.id, j.name, NET.judgeHp - hp, NET.judgeHp, tn)   -- §460 马车封顶
            if cc then hp = NET.judgeHp - cc; sum = cc end
            local hcap = not gun and not sum and CAP.hitFix(p1, j.name, NET.judgeHp - hp, NET.judgeHp, tn)   -- §340 单下受伤上限
            if hcap then hp = NET.judgeHp - hcap end
            local capped = not gun and not sum and CAP.fix(p1, j.name, NET.judgeHp - hp, NET.judgeHp - hp, NET.judgeHp, tn)   -- §197 一招总伤害上限
            if capped then hp = NET.judgeHp - capped end
            BLK.guardLoss(p1, j, NET.judgeHp - hp, tn, m, shNow)
            NET.lastHit = { r = addResult("hit", j.id, NET.judgeHp - hp, tn), at = tn, name = j.name }
            if capped then NET.lastHit.r.capped, NET.lastHit.r.capName = true, j.name end   -- §199.9 后面的段 / 跳伤按 1 倍门槛
            LAT.learnFrom(j.id, "中招", tn)       -- v0.27.0 追帧：从实际中招学前摇
            if j.brk then
                out("  §347 远端#%d 格挡被破（%s，%.2f 秒前）之后掉血 → 中招，不算精防 / 普防", j.id, tostring(j.brkM), tn - j.brk)
            end
            if BLK.isCounter(j) then           -- §347 防反诊断（只记日志）
                local v = NET.lastHit.r and NET.lastHit.r.v or (NET.judgeHp - hp)
                NET.lastHit.ctr, NET.lastHit.seg, NET.lastHit.brkM = true, 1, j.brkM
                BLK.counterDiag(j.id, j.name, 1, v, v, j.brkM, tn)
            end
        end
    elseif not open and NET.lastHit and NET.lastHit.soft and hp and NET.judgeHp and hp < NET.judgeHp - 0.5 then
        -- §87 软格挡的那一招后面几段：同样补回去
        out("全部可格挡：远端#%d 后续一段 -%.0f → 补回，%s", NET.lastHit.r.atk, NET.judgeHp - hp, BLK.cover(p1, m, tn))
        setAttr(p1, "Health", NET.judgeHp)
        hp = NET.judgeHp
        NET.lastHit.at = tn
    elseif not open and NET.lastHit and hp and NET.judgeHp and hp < NET.judgeHp - 0.5 then
        -- v0.17.3：多段招式（例：绝影 AA 两段相隔约 0.4 秒）的后几段。中招已经立即回报过（攻击方要马上播受击），
        -- 这里把后面的掉血累加进同一条结果；结果还在重发期内，对方会看到数值变大
        local r = NET.lastHit.r
        local gun = GDMG.fix(p1, r.atk, NET.lastHit.name, NET.judgeHp - hp, NET.judgeHp, tn)   -- §212
        if gun then hp = NET.judgeHp - gun end
        local zdb = not gun and ZDB.fix(p1, r.atk, NET.lastHit.name, NET.judgeHp - hp, NET.judgeHp, tn)   -- §370
        if zdb then hp = NET.judgeHp - zdb end
        local torn = not gun and not zdb and TORN.fix(p1, r.atk, NET.lastHit.name, NET.judgeHp - hp, NET.judgeHp, tn)   -- §383
        if torn then hp = NET.judgeHp - torn end
        local sum = not gun and not zdb and not torn and SUMD.fix(p1, NET.lastHit.name, NET.judgeHp - hp, NET.judgeHp, tn)   -- §242
        if sum then hp = NET.judgeHp - sum end
        local cc = not gun and not zdb and not torn and not sum and CARTCAP and CARTCAP.fix(p1, r.atk, NET.lastHit.name, NET.judgeHp - hp, NET.judgeHp, tn)   -- §460 马车封顶
        if cc then hp = NET.judgeHp - cc; sum = cc end
        local hcap = not gun and not sum and CAP.hitFix(p1, NET.lastHit.name, NET.judgeHp - hp, NET.judgeHp, tn)   -- §340
        if hcap then hp = NET.judgeHp - hcap end
        local capped = not gun and not sum and CAP.fix(p1, NET.lastHit.name, NET.judgeHp - hp, r.v + (NET.judgeHp - hp), NET.judgeHp, tn, r)   -- §197
        if capped then hp = NET.judgeHp - capped end
        BLK.guardLoss(p1, { name = NET.lastHit.name, brk = NET.lastHit.brkM }, NET.judgeHp - hp, tn, m, shNow)
        r.v = r.v + (NET.judgeHp - hp)
        r.upd = tn                                     -- §434 追加了就重新留 RES_KEEP 秒（见 netJudge 开头）
        local inRes = false                            -- 已经过期删掉的放回去（下一段晚于 RES_KEEP 才来）
        for _, x in ipairs(NET.results) do if x == r then inRes = true; break end end
        if not inRes and r.id then NET.results[#NET.results + 1] = r end
        if not (capped and capped < 0.5) and not (cc and cc < 0.5) then          -- §199.9 / §460 封顶吃掉的 CARTCAP 自己记 整跳吃掉的不再记"追加 -0"，合计见 CAP.flush
            out("判定 远端#%d → 中招 追加 -%.0f（这招累计 -%.0f）%s", r.atk, NET.judgeHp - hp, r.v, NET.pupAtkNote())
        end
        if NET.lastHit.ctr then                       -- §347 防反诊断：后面几段
            NET.lastHit.seg = NET.lastHit.seg + 1
            BLK.counterDiag(r.atk, NET.lastHit.name, NET.lastHit.seg, NET.judgeHp - hp, r.v, NET.lastHit.brkM, tn)
        end
        NET.lastHit.at = tn        -- v0.27.1 从最后一段算起：炽刃大招十几段、拖 1.8 秒，从第一段算会把后面的段漏掉
    elseif not open and not NET.lastHit and hp and NET.judgeHp and hp < NET.judgeHp - 0.5 then
        -- §242 召唤物自己打、游戏没开招式窗口：召唤动作后 20 秒内、替身认出来的召唤物还在 → 这一下只扣 1 点。
        -- 没有招式号可以回报（不是玩家出的招），只把血改回去；对方 HUD 按 hp= 同步看到。
        local sum = SUMD.fixField(p1, NET.judgeHp - hp, NET.judgeHp, tn)
        if sum then hp = NET.judgeHp - sum end
    elseif #NET.judges > 0 and newDeflect and BLK.isBreak(m) then
        -- §347 格挡被破（AM_Hun_Deflect_Break_L）：不是防住，不交给下面按杀气分精防 / 普防。窗口留着（最少再等 BLK.BRK_KEEP 秒），
        -- 防反那一刀掉血时走上面的中招（照常带攻击力 / 系数、计中招、上限照管）；一直没掉血到期记中招 -0。都不计连续精防
        local j = NET.judges[#NET.judges]
        if not j.brk then
            j.brk, j.brkM, j.brkUntil = tn, m, tn + BLK.BRK_KEEP
            out("§347 格挡被破：远端#%d %s%s，我的动作 %s → 不算防住，等掉血按中招（%.1f 秒内没掉血也记中招 -0），不计连续精防",
                j.id, j.name or "?", BLK.ultra(j.name), m, BLK.BRK_KEEP)
        end
    elseif #NET.judges > 0 and newDeflect then
        if NET.pendDef then finishDeflect(p1, tn) end
        local j = table.remove(NET.judges)
        LAT.learnFrom(j.id, "格挡", tn)       -- v0.27.0 追帧：从实际格挡学前摇
        BLK.onBlock(j, m)                     -- §87 格挡探针（对照）
        -- 基准用上一帧的杀气：日志里跳涨常和格挡动作出现在同一帧，用本帧当基准会把跳涨吃掉
        NET.pendDef = { j = j, at = tn, m = m, lastSh = shPrev or shNow or 0, jump = 0, drop = 0, normal = BLK.isNormal(m) }
    end
    -- §431 只扣杀气、不扣血的命中（幻术琵琶【移商换羽】GA_Lute_Dash 的蓝弹 BD_GA_Hun_Lute_Dash_*_01(_E)：资产里扣血倍率 0、
    -- 扣杀气 5.28 / 5.81；红弹才扣血）。11-24 14:52 IGNIZ 那边 #634 / #635 / #636 都是受击动作 + 杀气 -159～-165、血不动，
    -- 到期全判成落空 → 发送方看到"判定丢失"、替身预播的受击被收掉。窗口开着、这一帧没掉血、杀气一下掉了 30 以上
    -- 且我在播受击动作 → 记在最近开的那个窗口上；到期还没掉过血就记中招 -0（不是落空）
    if open and not newDeflect and dtick == nil and hp and NET.judgeHp and hp >= NET.judgeHp - 0.5 and shNow and shPrev
        and shPrev - shNow >= 30 and (LO.isHitMontage(m) or LO.isHitMontage(mPrev or "")) then
        local j = NET.judges[#NET.judges]
        if j and not j.shHit then
            j.shHit = { at = tn, d = shPrev - shNow, m = m }
            out("§431 远端#%d %s 打中我只扣了杀气 -%.0f（受击 %s，血没掉）→ 记着，到期没掉血就算中招 -0", j.id, j.name or "?", shPrev - shNow, m)
        end
    end
    local pd = NET.pendDef
    if pd then
        local sh = shNow or pd.lastSh
        local d = sh - pd.lastSh
        if d > pd.jump then pd.jump = d end
        if d < pd.drop then pd.drop = d end
        pd.lastSh = sh
        if BLK.isNormal(m) then pd.normal = true end    -- §425 观察期里换成普通防御动作也算
        if tn - pd.at >= DEF_OBSERVE then finishDeflect(p1, tn) end
    end
    if dtick ~= "hold" then NET.judgeHp = hp end      -- §381 押着的那一下留到下一帧
    if NET.lastHit and tn - NET.lastHit.at > JUDGE_WIN and not FJ.holdHit(NET.lastHit, tn) and not (CHG.holdHit and CHG.holdHit(NET.lastHit, tn)) then NET.lastHit = nil end   -- §370 飞剑还在路上接着累加；蓄力招替身还在放也接着累加
    local keep, pupM = {}, nil
    for _, j in ipairs(NET.judges) do
        if tn - j.at > JUDGE_WIN and not (j.brkUntil and tn <= j.brkUntil) then      -- §347 格挡被破后至少再等 BRK_KEEP 秒
            -- v0.27.1 替身还在播这一招的动作（大招蓄力）→ 接着等，最多 LAT.JUDGE_MAX 秒
            pupM = pupM or select(3, LAT.activeMontage(puppet())) or ""
            if LAT.stillPlaying(j.id, tn - j.at, pupM) or CHG.keepJudge(j, tn, pupM) or FJ.keepJudge(j, tn) then keep[#keep + 1] = j   -- §92 蓄力招等松手；§370 紫冥剑飞剑还在路上
            elseif j.brk then
                out("§347 远端#%d 格挡被破（%s）后 %.2f 秒没掉血 → 记中招 -0（不算精防 / 普防）", j.id, tostring(j.brkM), tn - j.brk)
                addResult("hit", j.id, 0, tn)
            elseif j.shHit then
                out("§431 远端#%d %s 只扣了杀气 -%.0f、没掉血 → 记中招 -0（不算落空）", j.id, j.name or "?", j.shHit.d)
                addResult("hit", j.id, 0, tn)
            else addResult("miss", j.id, 0, tn) end
        else keep[#keep + 1] = j end
    end
    NET.judges = keep
end

local function applyRemoteResult(p1, r)
    if PEER.on then return end          -- §223 观战替身不收判定结果（p1 是另一个替身）
    local kind = r.kind == "deflect" and "parry" or r.kind     -- v0.9.x 的 deflect 当精防
    local tn = now()
    if kind == "parry" and PDSH then PDSH.drain(p1, "atk", r.atk, true) end     -- §423 我的招被精防：扣我自己的杀气
    if r.atk then
        NET.resKind = NET.resKind or {}
        NET.resKind[r.atk], NET.resKind[r.atk - 300] = kind, nil
        NET.resAtkTime = NET.resAtkTime or {}
        NET.resAtkTime[r.atk], NET.resAtkTime[r.atk - 300] = tn, nil
    end
    local myAtkName = r.atk and NET.evName and NET.evName[r.atk] or NET.lastMyAtk    -- §422 被判定的是我哪一招（远程招硬直更久）
    -- §432 对方在拳挡四方里挡住我：我直接吃精防硬直（对方那边 finishDeflect 按同一条规则让替身吃）
    local gp = (kind == "parry" or kind == "block") and not NET.rai and GPD.on(puppet()) or false
    local fire, n, stgSec = bumpStreak("atk", kind, tn, r.atk, myAtkName, gp)     -- §230.2 带攻击编号（同一招的后续段不再数）
    if gp then GPD.log("§432 我的第 #%d 招被对方拳挡四方挡住（%s，替身动作 %s）→ %s", r.atk or -1, RES_NAME[kind] or kind,
        tostring(montageOf(puppet())), fire and "我直接吃精防硬直（不数连续）" or "精防硬直没开 / 我还在硬直里") end
    -- §104 先和接触时的预测对账：pr.skip = 预测对了、替身已经在播（不重播）；pr.seek = 纠正时从第几秒播起（追帧）
    local pr = PRED.onResult(r, kind, tn)
    if kind == "parry" or kind == "block" then
        -- 我屏幕上代表对方的替身播格挡动作；只有连续第 3 次精防我才吃硬直，其余可以继续打
        -- §230.1 硬直动作按被精防的那一招的武器选（ST.p1Weapon 只认 5 个武器族，拿玉双环时还停在黑伤、播了单刀的 C_Failed）；认不出 = 通用 AM_Hun_Attack_Failed
        local me = fire and STG.start(p1, NET.lastMyAtk and weaponOfAbility(NET.lastMyAtk), tn, stgSec, myAtkName) or "继续攻击"     -- §161 / §228 硬直期间关输入
        local pupTxt
        if pr.skip then
            pupTxt = "替身已经预播了格挡 " .. tostring(pr.m) .. "（预测对了）"
        else
            -- §104 优先级：对方已经出了下一招（替身在出招）/ 受击 / 破防时不播格挡——格挡动作会盖掉出招动作，招却还挂着
            local busy = PRED.busy(puppet(), tn)
            if busy then
                pupTxt = "替身" .. busy .. "，不播格挡"
            elseif NET.rai then                                  -- §456 本地 AI / 木桩：按替身武器播精防 / 普防动作
                local okPup, an = DEFANIM.play(puppet(), kind)
                pupTxt = string.format("替身格挡 %s（%s%s）", tostring(an), okPup and "已播" or "失败",
                    okPup and PRED.seek(puppet(), pr.seek) or "")
            else
                NET.defIdx = (NET.defIdx or 0) % #DEFLECT_ANIMS + 1
                local okPup = playNamed(puppet(), DEFLECT_ANIMS[NET.defIdx])
                pupTxt = string.format("替身格挡 %s（%s%s）", DEFLECT_ANIMS[NET.defIdx], okPup and "已播" or "失败",
                    okPup and PRED.seek(puppet(), pr.seek) or "")
            end
        end
        if kind == "block" and TRAINCTX and TRAINCTX.blockChi then
            local okB, msgB = pcall(TRAINCTX.blockChi, puppet(), tn)       -- §456 木桩普防扣杀气（游戏自己没扣时）
            if msgB then pupTxt = pupTxt .. "；" .. (okB and msgB or ("木桩扣杀气出错 " .. tostring(msgB))) end
        end
        out("◆ 你的第 #%d 招被对方%s%s → 你%s，%s", r.atk, RES_NAME[kind],
            kind == "parry" and string.format("（连续第 %d 次）", n) or "", me, pupTxt)
    elseif r.kind == "hit" and NET.lastHrAt and tn - NET.lastHrAt < 0.6 then
        -- v0.17.11：对方的受击状态（hr=）已经同步到替身，用它，不再播固定的中等受击
        out("◆ 你的第 #%d 招命中对方 -%.0f → 替身受击按对方状态 %s", r.atk, r.v, tostring(NET.lastHrTag))
    elseif r.kind == "hit" then
        -- v0.23.1 攻击优先（用户 2026-11-04）：替身正在出招时不播受击。受击动画盖住出招动画，招式本身却没停，
        -- 22:44:16 替身"在受击里"一刀砍中玩家。对方真被打断的话，对方游戏会发 hr=，在那里停招（见下面 hr 段）
        local busy = puppetAttacking(puppet())
        if busy then
            out("◆ 你的第 #%d 招命中对方 -%.0f → 替身正在出招 %s，不播受击（攻击优先）", r.atk, r.v, busy)
        elseif NET.rdummy and AISYNC and AISYNC.inBreak and AISYNC.inBreak(puppet()) then
            out("◆ 你的第 #%d 招命中木桩 -%.0f → 木桩格挡被破、在播破防动作，不播受击", r.atk, r.v)     -- 别拿受击盖掉破防
        elseif pr.skip then
            out("◆ 你的第 #%d 招命中对方 -%.0f → 替身已经在播本机受击 %s（预测对了）", r.atk, r.v, tostring(pr.m))
        elseif NET.rai and LO.isKnockMontage(montageOf(puppet())) then
            out("◆ 你的第 #%d 招命中本地 AI -%.0f → AI 正在播本机游戏的击飞 / 倒地 / 破防（%s），照原版，不播普通受击", r.atk, r.v, montageOf(puppet()))
        else
            NET.hitSide = NET.hitSide == "R" and "L" or "R"
            local hn = hitNameFor(ST.pupWeapon, NET.hitSide)
            local okH = playNamed(puppet(), hn)
            out("◆ 你的第 #%d 招命中对方 -%.0f → 替身受击 %s（%s%s）", r.atk, r.v, tostring(hn),
                okH and "已播" or "失败", okH and PRED.seek(puppet(), pr.seek) or "")
        end
        LO.zmHeal(p1, r.atk, r.v)
    else
        out("◆ 你的第 #%d 招落空%s%s", r.atk, pr.note or "", TOUCH.missNote(r.atk))     -- §357 落空时离替身多远；§385 真人 1v1 也记、带招名 / 最近那一刻
    end
    NET.applied[r.kind] = (NET.applied[r.kind] or 0) + 1
end

-- ============================================================ §104 替身反应预测 / 追帧纠正
-- 用户 2026-11-06："某个玩家经常会成功格挡，那下次攻击时要不要先播放他的格挡，等对面消息回来了再看要不要掐断当前动作追帧到实际动作"。
-- 以前：我的刀在本机碰到替身 → 本机游戏给替身播的受击同一帧掐掉（v0.9.9 suppressLocalReact），替身什么都不播，
--   等对方判定回来（一个往返 + 判定，通常 0.2–0.7 秒）才播格挡 / 受击，画面上刀穿过去、过一会儿才有反应。
-- 现在：碰到的那一帧就按这个对手的历史猜结果——
--   猜格挡（P ≥ DEF_TH）→ 掐掉本机受击、立刻播格挡动作；
--   猜中招（P ≤ HIT_TH）→ 本机游戏的受击留着（时机是准的）；
--   拿不准 → 和以前一样掐掉、等结果。
--   结果回来：猜对了不重播；猜错了停掉预播的、从"碰到之后过了多久"那一秒播起实际的动作（追帧，最多 SEEK_MAX）；落空则收掉预播的。
-- P = 这个对手"被我砍到时防住"的比例，分两桶：碰到时他在不在格挡（gd= 字段，旧版对方没有 → 看最近有没有收到架势招）。
--   每桶带先验（格挡中 3:1 偏防住，不在格挡 0.5:2.5 偏中招），每次观察先乘 DECAY 再加 1，所以跟着这个人最近的习惯走。
--   换对手 / 对方重启时清零（和 LAT.reset 同时）。
-- 替身动作优先级（评估见 HANDOVER §104.1），高的在播时低的不播：
--   倒地 > 破防（brk=）> 受击（hr=，对方真被打断）> 出招（ev=，攻击优先）> 判定结果（格挡 / 受击）> 预测 > 本机游戏的反应（掐掉）
-- 全局表：主代码块的 local 已满 200 个
PRED = { on = true, LOCAL_HIT = true, DEF_TH = 0.6, HIT_TH = 0.35, DECAY = 0.9, WAIT = 1.6,
         SEEK_MAX = 0.25, SEEK_MIN = 0.03, KEEP_FRAMES = 40, HR_HOLD = 0.5, BRK_HOLD = 1.5, STANCE_HOLD = 1.5, LOGS = 40, logs = 0,
         SKILL_MIN_S = 3, SKILL_MISS_TH = 0.5, SKILL_AI_MIN_S = 3, SKILL_AI_MISS_TH = 0.85, SKILL_PRIOR_HIT = 1,
         skillsH = {}, skillsAI = {},
         PRIOR = { g = { 3.0, 1.0 }, n = { 0.5, 2.5 } },     -- { 防住, 中招 } 的初始计数：g = 格挡中，n = 没在格挡
         b = nil, pend = nil, pends = {},
         st = { contact = 0, busy = 0, prior = 0, preDef = 0, preHit = 0, preMiss = 0, wait = 0, right = 0, wrong = 0, fix = 0, undo = 0, nores = 0 } }

function PRED.reset()
    PRED.b = { g = { PRED.PRIOR.g[1], PRED.PRIOR.g[2] }, n = { PRED.PRIOR.n[1], PRED.PRIOR.n[2] } }
    PRED.pend = nil
    PRED.pends = {}
    PRED.skillsH = {}
    PRED.skillsAI = {}
    if NET then
        NET.resKind = {}
        NET.resAtkTime = {}
        NET.rDodgeAt = nil
    end
end

-- §236 在线学习：按我出的招（技能名）分桶的落空率（真人 / AI 分开学）
function PRED.getSkillStats(skill, isAi)
    if not skill or skill == "" then return 0, 0 end
    local tbl = isAi and PRED.skillsAI or PRED.skillsH
    if not tbl then return 0, 0 end
    local s = tbl[skill]
    if not s then return 0, 0 end
    local tot = s.hit + s.miss
    return s.n or 0, (tot > 0 and (s.miss / tot) or 0)
end

function PRED.learnSkill(skill, isMiss, isAi)
    if not skill or skill == "" then return end
    local tbl = isAi and PRED.skillsAI or PRED.skillsH
    if not tbl then return end
    local s = tbl[skill]
    if not s then
        s = { hit = PRED.SKILL_PRIOR_HIT or 1, miss = 0, n = 0 }
        tbl[skill] = s
    end
    s.n = s.n + 1
    if isMiss then
        s.miss = s.miss + 1
    else
        s.hit = s.hit + 1
    end
end

-- 对方这一刻在不在格挡：状态包 gd=（§104 起发）；旧版对方 → 最近 STANCE_HOLD 秒内收到过架势招、之后没出过攻击招
function PRED.guarding(tn)
    if NET.rgd ~= nil then return NET.rgd end
    return NET.rStanceAt ~= nil and tn - NET.rStanceAt < PRED.STANCE_HOLD
end

-- 防住的概率（纯函数）
function PRED.prob(g)
    if not PRED.b then PRED.reset() end
    local c = PRED.b[g and "g" or "n"]
    return c[1] / (c[1] + c[2])
end

function PRED.learn(g, isDef)
    if not PRED.b then PRED.reset() end
    local c = PRED.b[g and "g" or "n"]
    c[1], c[2] = c[1] * PRED.DECAY + (isDef and 1 or 0), c[2] * PRED.DECAY + (isDef and 0 or 1)
end

-- 优先级仲裁：替身现在有更高优先级的动作在播 → 返回原因（不该再播格挡 / 受击 / 预测），否则 nil
-- §456 预播 / 先到的格挡：本地 AI 按替身武器挑（DEFANIM），真人对战照旧荡寇那两个
function PRED.playDef(pup, kind)
    if NET.rai then return DEFANIM.play(pup, kind) end
    NET.defIdx = (NET.defIdx or 0) % #DEFLECT_ANIMS + 1
    local a = DEFLECT_ANIMS[NET.defIdx]
    return playNamed(pup, a), a
end

function PRED.busy(pup, tn)
    if REP.on then return "在回放" end
    if NET.remoteHp and NET.remoteHp <= 0 then return "已倒地" end
    if NET.rbrkAt and tn - NET.rbrkAt < PRED.BRK_HOLD then return "在破防" end
    if NET.lastHrAt and tn - NET.lastHrAt < PRED.HR_HOLD then return "在受击（对方真被打断）" end
    local atk = puppetAttacking(pup)
    if atk then return "在出招 " .. atk end
    return nil
end

-- 我最近一招的招式号（判定结果按它对账）：从最新的往回找 5 个，找第一个攻击招
function PRED.myAttackId()
    local id = NET.evId or 0
    for k = id, math.max(1, id - 4), -1 do
        local n = NET.evName and NET.evName[k]
        if n and isAttackAbility(n) then return k end
    end
    return id
end

-- §107 我的刀在本机真的碰到替身（用户 2026-11-06"跟 AI 对战，对着空气出招 AI 都在掉血"）：
-- 本地 AI 没有游戏，以前对我的每一招都按难度随机回报中招 / 格挡，不管碰没碰到。现在本机看到碰到就记下这招的招式号，
-- 状态包 tc=<招式号,...> 发出去（TOUCH.KEEP 秒），AI 只回报碰到过的招，没碰到的报落空。真人对手不看 tc=（它自己的游戏判定）。
-- 碰到 = 本机游戏给替身播受击动作（suppressLocalReact 的 _Hit_），或替身本机血量掉了（刀落在出招 / 霸体中的替身上不一定播受击）
-- §115 本机真实伤害（用户 2026-11-06"天煞双钺的大招打不掉伤害"：AI 每招固定扣 400、一招只算一次，多段大招也就 400）：
-- 替身本机掉的血按招式号累加，乘上对方给我的替身乘的系数（伤害倍率 × 武器平衡 / 影之武装，同 LO.rescale），
-- 状态包 td=<招式号:累计伤害,...> 发出去；AI 按它扣血、后几段报"追加命中"。没有 td= 的旧模组 AI 照旧按 400。真人对手不看 td=
TOUCH = { ids = {}, dmg = {}, KEEP = 2.0, n = 0, SUM_WIN = 20.0, ATK_LIVE = 3.0, sumLogs = 0,
          -- §388 紫冥剑收尾招的飞剑：飞剑是收尾招放完 0.3–2 秒才打到，掉血时我可能已经接了下一招；
          -- 以前 TOUCH.srcId 一律记在"最近一招"上，飞剑伤害记到下一招头上、收尾招被判落空（§370.2 07:02:16 #995 ABB → #996 B_C -225）。
          -- 现在收尾招放出来就记下它，掉血时飞剑还在场（BP_Hun_ZiMingJian_FlyingSword_Shoot）→ 记回发射它的那一招。
          SWORD = { ["GA_Hun_ZiMingJian_New_ABB_C"] = true, ["GA_Hun_ZiMingJian_New_BBB_C"] = true,
                    ["GA_Hun_ZiMingJian_New_AAAAA_C"] = true, ["GA_Hun_ZiMingJian_New_AABB_C"] = true,
                    ["GA_Hun_ZiMingJian_New_AAABB_C"] = true },
          SWORD_WIN = 3.0, sword = nil, swordAt = nil, swordN = 0, swordLogs = 0, swordMissFor = nil, swordMissLogs = 0,
          -- §388 落空行带招名：NET.evName 只留 300 个号，落空往往 1.5 秒后才回来，那时名字已经清了（旧日志里落空行只有编号）
          names = {}, nameAt = {}, NAME_WIN = 60.0 }
-- §350 我的召唤物（绝影分身 / 召唤类影之武装）打替身：掉血以前记在 PRED.myAttackId()（最近 5 个事件里最后一个攻击招）上——
-- 放分身前那一刀（11-16 15:27 是切刀斩 #133，早已报完落空、在 AI 那边过期），分身那一招 GA_Hun_Double_JueYing_Clone_C 不算攻击招，
-- 本地 AI 也不登记 → 分身打木桩 47 秒一点血没扣。现在：SUM_WIN 秒内放过召唤、而且召唤比最后那个攻击招新（或那一招已经放出去 ATK_LIVE 秒），
-- 这一下记在召唤那一招上（本地 AI 那边 LocalAi.IsSummonCast 登记它、等最多 8 秒碰到、之后 20 秒内接着记）
-- §378 红妆鬼斩的石蒜花（内测反馈 11-17"大招的巨大石蒜花爆炸后没伤害，其他形式的石蒜花有"，打本地 AI）：
-- 花是留场子弹（BP_Hun_GuiTouBlade_Flower_Big / Small），由武器被动 GA_Hun_GuiTouBlade_Passive 引爆；带"手动引爆"升级
-- （GE_Weapon_GuiTouBlade_CanManualExplode）时花不自己炸，要按键引爆，往往是放完招好几秒以后（本机日志 11-16 / 11-17 三次大招，
-- 花放了 5–9 秒到对局结束都还在场上）。引爆那一下替身掉的血以前记在 PRED.myAttackId() 上：早已结算完的那招，
-- 或中间冲刺这类非攻击招 → 本地 AI 那边那招的结果 3 秒没动静就丢了 / 根本不登记 → 整次爆炸没伤害。
-- 连招撒的花多半被下一刀打中时引爆（记在那一刀上），所以"其他形式的有伤害"。
-- 现在：FLOWER_WIN 秒内出过红妆鬼斩的攻击招、而最近没有新出的攻击招（ATK_LIVE 秒内）→ 记在那一招上；
-- 本地 AI 那边 LocalAi.IsLingerCast 让这些招的结果多留 SummonKeep 秒、判了落空后碰到改判中招；
-- 这一招的累计伤害（td=）也多留（TOUCH.wire），不然过期后重新从 0 记、比 AI 那边记的累计小，AI 不补扣
-- §380.1 累计多留不只红妆鬼斩：荡寇凶刃大招第二下（击退）到最后一下（挑飞）隔约 3 秒，中间替身一直在播同一个击退受击，
-- §366（0.34.4 起）接着播的帧不再算碰到 → 2 秒（KEEP）没动静这招的累计就清了，最后一下重新从 0 记（−135 < 已记的 −234），
-- 本地 AI 那边 Math.Max 不补扣 → "大招最后一击没伤害"（玩家 v0.34.6 日志 16:03:46 #1832：−117 / −117，16:03:51 挑飞、杀气 −242，0 追加；
-- 0.34.3 同一招 3 秒的空当里受击帧还在刷碰到，累计没清，最后一下照算）。现在任何招过期时累计都先留 LINGER 秒（= LocalAi.SummonKeep，
-- AI 那边结果最长也只留这么久），同一招号再碰到就接着记；过了 LINGER 才丢、才 AIF.flush（上限记账也接着算）
TOUCH.FLOWER_WIN, TOUCH.flowerLogs, TOUCH.lingerDmg = 20.0, 0, {}
TOUCH.LINGER, TOUCH.lingerAt, TOUCH.lingerLogs = 20.0, {}, 0
function TOUCH.isFlowerCast(n)
    return n ~= nil and n:find("^GA_Hun_GuiTouBlade_") ~= nil
end
-- §388 飞剑还在不在场（只在掉血那一帧问；0.1 秒内复用同一结果）。只认主人是我、状态 2 的 FlyingSword_Shoot
function TOUCH.swordLive(tn)
    if PEER.on or not NET.rai then return false end
    if TOUCH.swordAt and tn - TOUCH.swordAt < 0.1 then return (TOUCH.swordN or 0) > 0 end
    local p1 = getP1 and getP1()
    if not valid(p1) then return false end
    local n = 0
    -- ① 精确类名（LO.bulletsOf 会退回 GetOwner，主人读不到 BulletOwnerAvatar 也认）
    if LO and LO.bulletsOf then
        for _, cls in ipairs({ "BP_Hun_ZIMingJian_FlyingSword_Shoot_C", "BP_ZiMingJian_FlyingSword_Shoot_C" }) do
            local ok, list = pcall(LO.bulletsOf, p1, cls)
            for _, e in ipairs(ok and list or {}) do
                local st = rawProp(e.actor, "BulletStatus")
                if (st == 2 or st == 3) and rawProp(e.actor, "bHidden") ~= true then n = n + 1 end
            end
        end
    end
    -- ② 退回按名字扫 BulletActorBase（类名对不上时）
    if n == 0 and G and G.summonCount then
        local ok, c = pcall(G.summonCount, p1, "FlyingSword_Shoot")
        n = ok and (tonumber(c) or 0) or 0
    end
    TOUCH.swordAt, TOUCH.swordN = tn, n
    return n > 0
end
-- fromHit = true：本机游戏给替身播了新受击动作（真的碰到了，记最近一招）；false / nil：只有掉血（可能是飞剑晚到）
function TOUCH.srcId(tn, fromHit)
    local id = PRED.myAttackId()
    local a = TOUCH.lastAtk
    local fresh = a ~= nil and a.id == id and tn - a.at <= TOUCH.ATK_LIVE
    local s = TOUCH.sum
    -- §350.1 只有"召唤之后我又出了一刀、那一刀放出去不到 ATK_LIVE 秒"才记在那一刀上，其余一律记在召唤上。
    -- 以前看 PRED.myAttackId()：最近 5 个事件里没有攻击招时它退回最新的事件号（架势 / 武器技 Buff 这类非攻击招），
    -- 比召唤新 → 掉血记在架势上，本地 AI 不登记架势、召唤又一直没碰到 → 8 秒后判落空（11-17 内测：绝影放完分身游戏自动再进架势，
    -- 第一次分身有伤害、之后"打着打着没伤害了"，日志里第 2–4 次分身全是"§357 补记成碰到"却没有一条命中）
    if s and tn - s.at < TOUCH.SUM_WIN and not (fresh and a.id > s.id) then
        if TOUCH.sumLogs < 10 and TOUCH.sumLast ~= s.id then
            TOUCH.sumLogs, TOUCH.sumLast = TOUCH.sumLogs + 1, s.id
            out("§350 替身挨的这一下记在我的召唤 #%d %s 上（放出 %.1f 秒；最近的攻击招 #%d）", s.id, s.name, tn - s.at, id)
        end
        return s.id
    end
    local f = TOUCH.flower                               -- §378
    if not fresh and f and tn - f.at < TOUCH.FLOWER_WIN then
        if f.id ~= id and TOUCH.flowerLogs < 30 then
            TOUCH.flowerLogs = TOUCH.flowerLogs + 1
            out("§378 替身挨的这一下（石蒜花引爆等留场伤害）记在我的红妆鬼斩 #%d %s 上（放出 %.1f 秒；最近的事件 #%d 不是新出的攻击招）",
                f.id, f.name, tn - f.at, id)
        end
        return f.id
    end
    -- §388 收尾招的飞剑晚到：最近一招已经换了、新的招还没碰到替身 → 这一下是飞剑，记回发射它的收尾招。
    -- 只认掉血（fromHit=false）；新受击动作（fromHit=true）永远记最近一招，免得把下一刀的受击抢走
    local sw = TOUCH.sword
    if NET.rai and not fromHit and sw and sw.id ~= id and tn - sw.at < TOUCH.SWORD_WIN and not TOUCH.ids[id] then
        if TOUCH.swordLive(tn) then
            if TOUCH.swordLogs < 20 then
                TOUCH.swordLogs = TOUCH.swordLogs + 1
                out("§388 紫冥剑飞剑晚到：这一下记在发射它的第 #%d 招 %s 上（不记在最近的 #%d；放出 %.1f 秒）",
                    sw.id, sw.name, id, tn - sw.at)
            end
            return sw.id
        elseif TOUCH.swordMissFor ~= sw.id and TOUCH.swordMissLogs < 10 then
            TOUCH.swordMissFor, TOUCH.swordMissLogs = sw.id, TOUCH.swordMissLogs + 1
            out("§388 紫冥剑飞剑没数到（收尾招 #%d %s 放出 %.1f 秒；掉血先记最近一招 #%d；FlyingSword_Shoot 可能已停用 / 主人不是自己）",
                sw.id, sw.name, tn - sw.at, id)
        end
    end
    return id
end
function TOUCH.mark(tn, d, fromHit)
    local id = TOUCH.srcId(tn, fromHit)
    if id <= 0 then return end
    if d == nil then                                     -- §381 真碰到（受击 / 破防）：押着的那一下就是这一招的刀
        d = DTICK and DTICK.aiContact(id, tn)
    elseif DTICK and DTICK.aiHold(id, d, tn) then                  -- §381 替身挂着持续伤害、这招还没碰到：先押着，可能只是跳伤
        return
    end
    TOUCH.add(id, tn, d)
end
function TOUCH.add(id, tn, d)
    if not TOUCH.ids[id] then TOUCH.n = TOUCH.n + 1 end
    TOUCH.ids[id] = tn
    if TOUCH.dmg[id] == nil and TOUCH.lingerDmg[id] then           -- §378 / §380.1 接着这招之前的累计记
        if TOUCH.lingerLogs < 30 and TOUCH.lingerAt[id] then
            TOUCH.lingerLogs = TOUCH.lingerLogs + 1
            out("§380.1 我第 #%d 招 %s 隔 %.1f 秒又碰到替身：累计接着 -%.0f 记（不从 0 记，本地 AI 才会补扣）",
                id, tostring((TOUCH.names and TOUCH.names[id]) or (NET.evName and NET.evName[id])), tn - TOUCH.lingerAt[id], TOUCH.lingerDmg[id])
        end
        TOUCH.dmg[id], TOUCH.lingerDmg[id], TOUCH.lingerAt[id] = TOUCH.lingerDmg[id], nil, nil
    end
    if d and d > 0 and TOUCH.counts() then
        local fair = NET.rai and AIF                     -- §217 本地 AI：按挨打方同一套（等级系数 / CAP / 持续伤害钉住）
        local yq
        if NET.rai then                                  -- §371 本地 AI：我的妖锯爆发 / 魔剑剑气打替身，和挨打方同一套认法
            local pup, p1 = puppet(), getP1()
            d, yq = YQX.mine(pup, tn, d)
            d = HQX.mine(p1, pup, tn, d)
            if SEG1121 then d = SEG1121.mine(p1, pup, tn, d, NET.evName[id], id) end
        end
        local add = TOUCH.calc(id, d, tn)
        -- 爆发标签可能下一帧才到：§384 这一下先不进 td=（本地 AI 按累计取最大值，先报全额再扣扣不回来），YQX.minePend 定了再记
        if yq == "pend" then YQX.minePendSet(tn, id, add) else TOUCH.addDmg(id, add) end
    end
end
-- ==== §381 持续伤害的跳伤不算新一招"碰到 / 中招"（内测 11-17"炽刃焰波 / 炽杀命中前对方先僵直"）
-- 炽刃每招都点燃，点燃每 0.3 秒左右跳一下（本机日志里 2–13 点），跳伤不出受击动作。两边以前都把"判定窗口开着 / 刚出的招"期间
-- 掉的血一律算这一招碰到：
--   本地 AI（我打 AI）：替身掉血 → TOUCH.mark 记在最新出的招（PRED.myAttackId）上 → tc= / td= 报给 AI → AI 回报命中 →
--     applyRemoteResult 给替身播受击。焰波 / 炽杀起手慢，刀还没到替身先"僵直"。mp_probe (30)：炽杀 42 次里 30 次第一下"命中"
--     只有 1–13（10:18:15 #492 起手同一秒 -5 → "替身受击…已播"，真正的刀 -146 在第二秒）。
--   挨打方（真人对战 / AI 打我）：netJudge 判定窗口开着时掉 0.5 以上就判这一招中招、回报给对方 → 对方屏幕上的替身先播受击。
--     mp_probe (5) 20:08:51：对方炽杀 远端#733 的事件一到，我身上点燃跳的 -2.8 就判了"中招 -3"。
-- 现在：身上挂着持续伤害（点燃 / 流血 / 中毒 / 混沌，看本机游戏的异常标签）、不在出招（霸体不出受击）、不在格挡、
-- 这一下没出受击 / 破防动作时，先押 WAIT 秒：这段时间里出了受击 / 破防 = 刀到了，照常算这一招；没出 = 跳伤：
--   本地 AI：记在持续伤害的来源招（AIF.src，没有就最近真碰到过的那招）上，跟以前没出新招时的跳伤一样走"追加命中"；
--   挨打方：不占这一招的判定窗口，按没开窗口时的跳伤处理（记进上一招 NET.lastHit 的追加，没有就不回报）
-- 一下掉很多的（本地 AI 替身本机原始掉血超过 AI_MAX、挨打方超过 DEF_MAX）不会是跳伤（炽刃点燃本机原始每跳约 100，挨打方 2–13），不押
DTICK = { WAIT = 0.15, SRC_MAX = 12.0, AI_MAX = 600, DEF_MAX = 200, KINDS = { "ignite", "bleed", "poison", "chaos" }, LOG_MAX = 40, logs = 0,
          ai = 0, def = 0, contact = {}, pend = nil, hold = nil }
function DTICK.say(fmt, ...)
    if DTICK.logs >= DTICK.LOG_MAX then return end
    DTICK.logs = DTICK.logs + 1
    out(fmt, ...)
end
-- 这个角色在本机游戏里挂着哪种持续伤害（nil = 没有）。只在掉血那一帧问
function DTICK.dotOn(actor)
    if not (actor and INF and INF.levels) then return nil end
    local ok, lv = pcall(INF.levels, actor)
    if not (ok and type(lv) == "table") then return nil end
    for _, k in ipairs(DTICK.KINDS) do
        if (lv[k] or 0) > 0 then return k end
    end
    return nil
end
-- 本地 AI，TOUCH.mark 掉血时调：true = 这一下先押着（不算 id 碰到）
function DTICK.aiHold(id, d, tn)
    if not (NET and NET.rai) or (PEER and PEER.on) then return false end
    if DTICK.contact[id] or TOUCH.ids[id] or (TOUCH.lingerDmg and TOUCH.lingerDmg[id]) then return false end   -- 这招已经碰到过（受击 / 掉血记过）：后面的掉血照旧记它
    local p = DTICK.pend
    if p and p.id == id then p.d = p.d + d; return true end
    if p then DTICK.aiFlush(tn) end
    if d > DTICK.AI_MAX then return false end
    local a = TOUCH.lastAtk                              -- 只管我刚出的攻击招（召唤物 §350 / 石蒜花 §378 那几条路不动）
    if not (a and a.id == id) then return false end
    local pup = puppet and puppet()
    if not pup or (puppetAttacking and puppetAttacking(pup)) then return false end        -- 替身在出招（霸体）：刀落上去也不出受击，分不出来，照旧
    local kind = DTICK.dotOn(pup)
    if not kind then return false end
    DTICK.pend = { id = id, d = d, at = tn, kind = kind }
    return true
end
-- 本地 AI，TOUCH.mark 真碰到时调：返回押着的那一下（就是这一招的刀）
function DTICK.aiContact(id, tn)
    DTICK.contact[id] = tn
    for k, t in pairs(DTICK.contact) do
        if tn - t > DTICK.SRC_MAX then DTICK.contact[k] = nil end
    end
    local p = DTICK.pend
    if p and p.id == id then
        DTICK.pend = nil
        return p.d
    end
    return nil
end
-- 每帧（TOUCH.watchHp 开头）：押满 WAIT 秒还没碰到 → 跳伤
function DTICK.aiStep(tn)
    local p = DTICK.pend
    if p and tn - p.at >= DTICK.WAIT then DTICK.aiFlush(tn) end
end
function DTICK.aiFlush(tn)
    local p = DTICK.pend
    DTICK.pend = nil
    if not p then return end
    local s = AIF and AIF.src and AIF.src[p.kind]
    local to, how = nil, nil
    if s and s.id and s.id ~= p.id then to, how = s.id, "持续伤害的来源招"
    elseif s and s.id == p.id then
        -- 11.23 实机（火流星磷火龙卷外圈）：木桩只站在外圈、龙卷本体没碰到，被外圈地火点燃，来源就是这一招自己 →
        -- 以前这里只认"别的招"，跳伤全"找不到来源招，不报"，外圈燃烧等于没生效。这一招点燃了替身就算它碰到了
        to, how = p.id, "这一招自己点燃的持续伤害"
    else
        local at = -1
        for id, t in pairs(DTICK.contact) do
            if id ~= p.id and t > at and tn - t <= DTICK.SRC_MAX then to, at = id, t end
        end
        how = to and "最近真碰到替身的招" or nil
    end
    DTICK.ai = DTICK.ai + 1
    DTICK.say("§381 替身掉血 %.0f 是持续伤害跳的（替身%s中，我第 #%d 招 %.2f 秒内没碰到 / 没出受击）→ %s（第 %d 次）",
        p.d, DOT.NAME[p.kind] or p.kind, p.id, tn - p.at,
        to == p.id and string.format("记在#%d 上（%s）", to, how)
            or to and string.format("记在%s #%d 上，不算 #%d 碰到", how, to, p.id) or "找不到来源招，不报", DTICK.ai)
    if to then TOUCH.add(to, tn, p.d) end
end
-- 挨打方，netJudge 判定窗口开着时掉血调（j = 最近开的窗口，m = 我这一帧的动作）：
-- "hold" = 再等等看出不出受击动作（这一帧不判、ST 基准血量不动）；"tick" = 是跳伤，不判这一招；nil = 照常判
function DTICK.defCheck(p1, m, j, drop, tn)
    if (PEER and PEER.on) or not j or drop > DTICK.DEF_MAX then DTICK.hold = nil; return nil end
    if LO.isHitMontage(m) or BLK.isBreak(m) then DTICK.hold = nil; return nil end      -- 出了受击 / 破防 = 刀到了
    if (BLK.on and tn - BLK.at <= BLK.GRACE) or BLK.guarding(m, NET.prevAbs) then      -- 在格挡：软格挡 / 盖受击照旧
        DTICK.hold = nil; return nil
    end
    for n in pairs(NET.prevAbs or {}) do                  -- 我在出招（霸体可能不出受击）：分不出来，照旧
        if isAttackAbility(n) then DTICK.hold = nil; return nil end
    end
    local h = DTICK.hold
    if not h or h.j ~= j.id then
        local kind = DTICK.dotOn(p1)
        if not kind then DTICK.hold = nil; return nil end
        h = { j = j.id, at = tn, kind = kind }
        DTICK.hold = h
    end
    if tn - h.at < DTICK.WAIT then return "hold" end
    DTICK.hold = nil
    DTICK.def = DTICK.def + 1
    DTICK.say("§381 远端#%d %s 判定窗口开着时掉血 -%.0f 是持续伤害跳的（我%s中，%.2f 秒没出受击动作，动作 %s）→ 不判这一招中招，%s（第 %d 次）",
        j.id, j.name or "?", drop, DOT.NAME[h.kind] or h.kind, tn - h.at, (m and m ~= "") and m or "无",
        NET.lastHit and NET.lastHit.r and string.format("算进上一招 远端#%d 的追加", NET.lastHit.r.atk) or "不回报", DTICK.def)
    return "tick"
end
-- §389 受击动作镜像（hr=）里的同一种跳伤：对方被点燃 / 流血跳一下，游戏也会给他播一个很轻的受击，
-- 他那边就发 hr=；我们照着播，看起来就是"我的刀还没到，对方先僵直"（第六轮"炽刃焰波 / 炽杀命中前对方先僵直"）。
-- §381 只管"掉血被算成中招"（res= / td=），这一条走的是 hr=，以前没管。
-- 判据（四条一起，宁可漏掐也不误掐真刀）：① 动作是 Hit_VeryLight / Hit_Light；② 同一包 hp= 只掉一点点
-- （> 0 且 ≤ HR_MAX，跳伤在日志里是 1–13，真刀 10% 房间也在百以上）；③ 对方自己的 inf= 有持续伤害；
-- ④ 同一包 res= 里没有新的"中招"结果（真刀会带一条；跳伤不会）。④ 是最后一道保险。
DTICK.HR_MAX, DTICK.HR_LOGS, DTICK.hrN = 40, 20, 0
function DTICK.hrSkip(t, tag, tn)
    if not tag then return false end
    if not (tag:find("Hit_VeryLight", 1, true) or tag:find("Hit_Light", 1, true)) then return false end
    local hp = tonumber(t and t.hp)
    local drop = (hp and NET.remoteHp and NET.remoteHp > 0 and hp >= 0) and (NET.remoteHp - hp) or nil
    if not (drop and drop > 0 and drop <= DTICK.HR_MAX) then return false end
    local dot
    for id, _, lv in (t.inf or ""):gmatch("(%a+):(%d+):(%d+)") do
        if tonumber(lv) > 0 then
            for _, k in ipairs(DTICK.KINDS) do if id == k then dot = k; break end end
        end
        if dot then break end
    end
    if not dot then return false end
    for id, _, kind in (t.res or ""):gmatch("(%d+):(%d+):(%a+)") do
        if kind == "hit" and not (NET.resSeen and NET.resSeen[tonumber(id)]) then return false end
    end
    DTICK.hrN = DTICK.hrN + 1
    if DTICK.hrN <= DTICK.HR_LOGS then
        out("§389 对方受击 %s 是%s跳伤带的（这一下只掉 %.0f，没有新的中招结果）→ 先不播（第 %d 次）",
            tag, (DOT.NAME[dot] or dot), drop, DTICK.hrN)
    end
    return true
end
-- §384 这一招的累计 td= 加一笔（YQX.minePend 晚记的那一下也走这里；§380.1 过期后留着的累计接着记）
function TOUCH.addDmg(id, add)
    if TOUCH.dmg[id] == nil and TOUCH.lingerDmg[id] then TOUCH.dmg[id], TOUCH.lingerDmg[id], TOUCH.lingerAt[id] = TOUCH.lingerDmg[id], nil, nil end
    TOUCH.dmg[id] = (TOUCH.dmg[id] or 0) + add
end
-- §356 本机游戏给替身播破防 / 破防挣脱（Break / MoTian_Dodge）= 我的刀碰到了它，只是没播 _Hit_、也不掉血。
-- 以前只掐掉、不记 tc=，本地 AI 一律回报落空（11-16 内测 0.34.0：偃月刀 A 连 12 刀只算 2 刀，同一段"掐掉替身的本机反应"涨了 11 次）。
-- 只认我 BRK_WIN 秒内出过攻击招；同一个动作每帧都会看到，隔 BRK_GAP 秒没看到破防动作 / 换了动作才算新的一次
TOUCH.BRK_WIN, TOUCH.BRK_GAP, TOUCH.brkLogs = 1.5, 0.3, 0
function TOUCH.markBreak(name, tn)
    local fresh = name ~= TOUCH.brkName or tn - (TOUCH.brkSeen or -100) > TOUCH.BRK_GAP
    TOUCH.brkName, TOUCH.brkSeen = name, tn
    if not fresh then return false end
    if not (NET.myAtkAt and tn - NET.myAtkAt <= TOUCH.BRK_WIN) then return false end
    TOUCH.mark(tn, nil, true)          -- §388 破防 / 挣脱是新受击，记最近一招（不抢成飞剑）
    if NET.rdummy and AISYNC and AISYNC.noteBreakId and name:find("Break", 1, true) then AISYNC.noteBreakId(TOUCH.srcId(tn, true), tn) end   -- 木桩普通格挡：这一招打破防了（tbrk=）
    if TOUCH.brkLogs < 30 then
        TOUCH.brkLogs = TOUCH.brkLogs + 1
        out("§356 替身在我这边破防 / 挣脱（%s）→ 算我第 #%d 招碰到了（本地 AI 据此回报）", name, TOUCH.srcId(tn, true))
    end
    return true
end
-- §366 替身这一帧在播的受击是不是"新的一下"：换了动作 / 位置往回跳（同一个受击重播）/ 隔 RX_GAP 秒没看到受击才算。
-- 接着播的帧返回 false；那时我已经换了下一招的，记一行日志（以前这里会把下一招记成碰到）
TOUCH.RX_GAP, TOUCH.rxLogs = 0.25, 0
function TOUCH.hitFresh(an, mt, name, tn)
    local okP, pos = pcall(function() return an:Montage_GetPosition(mt) end)
    pos = (okP and type(pos) == "number") and pos or nil
    local r = TOUCH.rx
    local fresh = not r or r.name ~= name or tn - r.seen > TOUCH.RX_GAP or (pos ~= nil and r.pos ~= nil and pos < r.pos - 0.02)
    if fresh then
        TOUCH.rx = { name = name, pos = pos, seen = tn, atk = PRED.myAttackId() }
        return true
    end
    r.pos, r.seen = pos or r.pos, tn
    local id = PRED.myAttackId()
    if id ~= r.atk and r.loggedFor ~= id and TOUCH.rxLogs < 20 then
        r.loggedFor, TOUCH.rxLogs = id, TOUCH.rxLogs + 1
        out("§366 替身还在播上一下的受击 %s（%.2f 秒），不算我第 #%d 招碰到", name, pos or -1, id)
    end
    return false
end
function TOUCH.calc(id, d, tn, isAi, prevDmg, inFight, capKey)
    if not d or d <= 0 then return 0 end
    local add = d * TOUCH.scale(id)
    local aiFlag = isAi; if aiFlag == nil then aiFlag = NET.rai end
    local fair = aiFlag and AIF
    if fair then add = AIF.level(id, add) end
    local gun = GDMG.mine(id, d, tn)                 -- §212 我的火枪打本地 AI：这一下按每发的数报
    if gun and gun < add then add = gun end
    if not gun then add = ZDB.mine(id, add, tn) or add end   -- §370 紫冥剑布局：我的锤 / 铁伞 / 幻化大锤火焰打本地 AI 按分件倍数
    if not gun then add = TORN.mine(id, add, tn) or add end  -- §383 刺骨混沌：我的火焰龙卷打本地 AI ×1.2
    local sum = SUMD.mine(id, d, tn)                 -- §242 我的召唤物打本地 AI：这一下也按每下 1 点报
    if sum and sum < add then add = sum end
    if fair and (prevDmg ~= nil or inFight ~= nil or capKey ~= nil) then
        AIF.mpCtx = { prev = prevDmg, fight = inFight, key = capKey }
    end
    if fair then add = AIF.cap(id, add, tn); AIF.hitId, AIF.hitAt = id, tn end
    return add
end
-- §116.1 替身本机掉的血什么时候算伤害：对方已经倒下（回报 hp=0）不算；对局里只有交手阶段算（倒计时 / 回合结算 / 结束画面不算）；
-- 对局外的自由陪练照算。2026-11-06 17:13 实测：天煞双钺大招第一段就打死 AI、第 3 回合结束，后面 4 段还在报"追加命中"，
-- 替身本机被一路打到 1 血（AI 那边死了不扣，但大招拖进下一回合开打就会算进下一回合）
function TOUCH.counts()
    if NET.remoteHp and NET.remoteHp <= 0 then return false end
    if MATCH.role and MATCH.state ~= "fight" then return false end
    return true
end
-- 我这一招打到对方该乘的系数 = 对方放我的替身时乘的（NET.atkScale × BAL.moveScale，没开武器平衡按影之武装）
function TOUCH.scale(id)
    local n = NET.evName and NET.evName[id]
    if not n then return NET.atkScale(false) end
    if BAL.active() then return NET.atkScale(false) * (BAL.moveScale((NET.evBal and NET.evBal[id]) or n, NET.evWc and NET.evWc[id])) end   -- §186.3；§371 按我放这招时手上的武器
    return NET.atkScale(LO.isEdgeAttack(n))
end
function TOUCH.wire(tn)
    local out_ = {}
    for id, at in pairs(TOUCH.ids) do
        if tn - at < TOUCH.KEEP then out_[#out_ + 1] = tostring(id)
        else
            -- §378 / §380.1 这招还可能接着碰到（石蒜花晚炸、大招最后一下隔 3 秒）：累计先留着，AIF.flush 等真丢的时候再做
            if TOUCH.dmg[id] then TOUCH.lingerDmg[id], TOUCH.lingerAt[id] = TOUCH.dmg[id], at
            elseif AIF then AIF.flush(id) end            -- §217
            TOUCH.ids[id], TOUCH.dmg[id] = nil, nil
        end
    end
    for id, at in pairs(TOUCH.lingerAt) do               -- §380.1 过了 LINGER 才丢（遍历时置 nil 是允许的）
        if tn - at >= TOUCH.LINGER then
            if AIF then AIF.flush(id, TOUCH.lingerDmg[id]) end
            TOUCH.lingerDmg[id], TOUCH.lingerAt[id] = nil, nil
        end
    end
    table.sort(out_, function(a, b) return tonumber(a) < tonumber(b) end)
    return table.concat(out_, ",")
end
function TOUCH.wireDmg()      -- 在 TOUCH.wire 之后调（过期的已经清掉）
    local out_ = {}
    for id, d in pairs(TOUCH.dmg) do out_[#out_ + 1] = string.format("%d:%.0f", id, d) end
    table.sort(out_, function(a, b) return tonumber(a:match("^%d+")) < tonumber(b:match("^%d+")) end)
    return table.concat(out_, ",")
end
-- 每帧（suppressLocalReact 开头）：替身本机血量比上一帧低 = 碰到（§115 掉多少记多少）。按对方回报校正血量时同步 ST.pupHpSeen，不算碰到
function TOUCH.watchHp(pup, tn)
    if DTICK then DTICK.aiStep(tn) end                   -- §381 押着的那一下到时间还没碰到 → 算跳伤
    local h = hpOf(pup)
    if h and ST.pupHpSeen and h < ST.pupHpSeen - 0.5 then TOUCH.mark(tn, ST.pupHpSeen - h) end
    ST.pupHpSeen = h
    TOUCH.headStep(pup, tn, h)
    if AIF then AIF.step(pup, tn) end                    -- §217 本地 AI：替身身上的持续伤害钉住来源招
    if NET.rai then YQX.minePend(pup, tn); HQX.minePrime(getP1(), pup) end   -- §371 爆发标签晚一帧到 / 我的魔剑刚挂上记底
    if NET.rai and SEG1121 then SEG1121.minePrime(getP1(), pup) end
end
-- §357 驱动那边改替身血量之前先调：上次 watchHp 之后掉的血先记成碰到，再改。
-- watchHp 在每帧循环里，按对方回报校正（recvOne）/ §301 写满（NET.drive）在驱动里（约 30 次 / 秒）；驱动先跑的那一帧，
-- 刀落下掉的血被直接写回去、ST.pupHpSeen 也跟着改了，watchHp 永远看不到 → 没播 _Hit_ 的那刀（霸体 / 同名受击还在播）报落空
function TOUCH.harvest(pup, tn, c)
    if PEER.on then return end
    c = c or hpOf(pup)
    if c and ST.pupHpSeen and c < ST.pupHpSeen - 0.5 then
        TOUCH.mark(tn, ST.pupHpSeen - c)
        TOUCH.harvested = (TOUCH.harvested or 0) + 1
        if TOUCH.harvested <= 20 or TOUCH.harvested % 50 == 0 then
            out("§357 替身掉血 %.0f 在驱动改血量前补记成碰到（第 %d 次）", ST.pupHpSeen - c, TOUCH.harvested)
        end
    end
    if c then ST.pupHpSeen = c end
end
-- §357 木桩 / 交手外的本地 AI：替身杀气每帧补（以前驱动每 10 拍 ≈ 0.33 秒补一次；偃月刀一刀扣 885 / 897，
-- 两刀之间没补上就在本机破防 → 挣脱带无敌帧，后面几刀穿过去报落空）。真人对战 / §353 交手中按游戏自己的都不管
TOUCH.SH_KEEP = 0.6
function TOUCH.keepShachi(pup)
    if not (NET.rai and ST.pupShMax) or PEER.on then return end
    if AISYNC and AISYNC.ownShachi() then return end
    local cur = attrOf(pup, "Shachi")
    if cur and cur < ST.pupShMax * TOUCH.SH_KEEP then setAttr(pup, "Shachi", ST.pupShMax) end
end
-- §357 落空诊断：本地 AI 对手时，每拍记下我最近这招期间和替身的最近距离；AI 报落空时写进日志（找剩下的落空是不是够不着）
-- §385 内测反馈 11-17"重攻击很多都丢判定，是完全碰不到碰撞体那种，不是打到没伤害"：玩家日志 (24)–(30) 落空行只有招式号和距离，
--   对不回是哪一招、最近那一刻替身在干什么。现在：① 落空行带招名；② 够得着的距离（SNAP_REACH 米）内每近 SNAP_STEP 米拍一次
--   "最近那一刻"：替身动作、替身无敌 / 不可选中标签、替身碰撞开没开、我这招还挂没挂着、这招期间替身瞬移校正几次；
--   ③ 真人 1v1 也量（对方游戏判的落空，这里记我这边看到的距离，和对方那边 §385 HMISS 行对照）。只读，不改判定
TOUCH.dmin, TOUCH.DIST_WIN, TOUCH.SNAP_REACH, TOUCH.SNAP_STEP = {}, 3.0, 4.0, 0.25
TOUCH.INV_TAGS = { "CharacterState.Stand.Invulnerable", "CharacterState.Unselectable", "CharacterState.Dead" }
function TOUCH.distStep(p1, pup, tn)
    if PEER.on then return end
    local id, at = NET.myAtkId, NET.myAtkAt
    if not (id and at and tn - at < TOUCH.DIST_WIN) then return end
    local okA, a = pcall(function() return pup:K2_GetActorLocation() end)
    local okB, b = pcall(function() return p1:K2_GetActorLocation() end)
    if not (okA and okB and a and b) then return end
    local d = math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) / 100
    local e = TOUCH.dmin[id]
    if not e then
        e = { d = d, at = tn, d0 = d, t0 = at, sn0 = ST.snaps or 0 }
        TOUCH.dmin[id] = e
        for k, v in pairs(TOUCH.dmin) do if tn - v.at > 30 then TOUCH.dmin[k] = nil end end
    elseif d < e.d then e.d = d end
    e.at = tn
    if d <= TOUCH.SNAP_REACH and (not e.snapD or d < e.snapD - TOUCH.SNAP_STEP) then      -- §385 最近那一刻
        e.snapD = d
        e.snap = TOUCH.snapshot(pup, id, tn - at, p1, a, b)
    end
end
-- §385 一次快照（只在变近时拍，一招最多十几次）：返回一段说明文字
-- §388 多记我朝哪：A_Dash 穿过木桩后下一招打空，日志里只有距离、看不出是不是目标在身后
function TOUCH.snapshot(pup, id, dt, p1, a, b)
    local m = montageOf(pup)
    local inv = G and G.tagsMatching and G.tagsMatching(pup, TOUCH.INV_TAGS) or nil
    local okC, col = pcall(function() return pup:GetActorEnableCollision() end)
    local n = (TOUCH.names and TOUCH.names[id]) or (NET.evName and NET.evName[id])
    local live = n and NET.prevAbs and (NET.prevAbs[n] and "还挂着" or "已收") or "?"
    local ang = ""
    if p1 and a and b then
        local okY, yaw = pcall(function() return yawOf and yawOf(p1) end)
        if okY and type(yaw) == "number" then
            local off = math.abs((math.deg(math.atan(b.Y - a.Y, b.X - a.X)) - yaw + 180.0) % 360.0 - 180.0)
            ang = string.format("、我朝向偏 %.0f°", off)
        end
    end
    return string.format("出招后 %.1f 秒%s，替身动作 %s%s%s，我这招%s", dt, ang, (m and m ~= "") and tostring(m) or "无",
        (inv and #inv > 0) and ("，替身标签 " .. table.concat(inv, "/")) or "",
        (okC and col == false) and "，替身碰撞关" or "", live)
end
function TOUCH.missNote(id)
    local e = TOUCH.dmin[id]
    if not e then return "" end
    local pup = puppet()
    local m = pup and montageOf(pup) or nil
    local n = (TOUCH.names and TOUCH.names[id]) or (NET.evName and NET.evName[id])
    local sn = (ST.snaps or 0) - (e.sn0 or ST.snaps or 0)
    return string.format("（诊断：%s出招时离替身 %.1f 米，这招期间最近 %.1f 米%s%s，替身动作 %s）", n and (n .. "，") or "", e.d0, e.d,
        e.snap and ("（最近时 " .. e.snap .. "）") or "", sn > 0 and string.format("，期间替身瞬移校正 %d 次", sn) or "",
        (m and m ~= "") and tostring(m) or "无")
end

-- §385 挨打方：对方的攻击招在我这边（替身身上）放出来后，到他下一招 / WIN 秒都没碰到我 → 记一行。
-- 真人对战是挨打方本机判定（旧版 1v1 的判定窗口、对决 / 多人房游戏自己扣血），攻击方看到"刀穿过去"时，
-- 要对照这边：替身那时离我多远、朝不朝我、在播什么，我在干什么（闪避无敌 / 破防挣脱）。
-- 开窗口 = AIR.fire 放成功的攻击招（事件）；之后每帧（只在有窗口开着时、GAP 秒一次）量距离、看我掉没掉血 / 播没播受击。
-- 碰到 = 我掉血，或者我的动作换成受击 / 格挡 / 破防类（ME_HIT）。只读，不改判定。本地 AI 的招（NET.rai）不记
HMISS = { open = 0, list = {}, WIN = 3.0, REACH = 4.0, STEP = 0.25, GAP = 0.03, LOG_DIST = 6.0,
          n = 0, miss = 0, near = 0, logs = 0, LOG_MAX = 80,
          ME_HIT = { "_Hit_", "Deflect", "MoTian_", "Break", "Knock", "Launch", "Dead" } }
function HMISS.onFire(pup, e, tn, tag)
    local key = tag or "1v1"
    local old = HMISS.list[key]
    if old then HMISS.close(key, old, tn, "他出了下一招") end
    if HMISS.open <= 0 then HMISS.hp, HMISS.m = nil, nil end      -- 没窗口时不跟血量：第一拍重新记底
    HMISS.list[key] = { id = e.id, name = e.name, pup = pup, at = tn, tag = tag }
    HMISS.open, HMISS.n = HMISS.open + 1, HMISS.n + 1
end
function HMISS.meHit(m)
    if LO.notHit(m) then return false end         -- §428 我自己虎炮出手不算被碰到
    for _, k in ipairs(HMISS.ME_HIT) do if m:find(k, 1, true) then return true end end
    return false
end
function HMISS.step()
    if HMISS.open <= 0 then return end
    local tn = now()
    if HMISS.lastStep and tn - HMISS.lastStep < HMISS.GAP then return end
    HMISS.lastStep = tn
    local p1 = getP1()
    if not valid(p1) then return end
    local okB, b = pcall(function() return p1:K2_GetActorLocation() end)
    if not (okB and b) then return end
    local hp, mm = hpOf(p1), montageOf(p1) or ""
    local hitNow = HMISS.meHit(mm)
    local best, bestD = nil, math.huge
    for key, w in pairs(HMISS.list) do
        local okA, a = false, nil
        if valid(w.pup) then okA, a = pcall(function() return w.pup:K2_GetActorLocation() end) end
        if not (okA and a) then
            HMISS.list[key], HMISS.open = nil, HMISS.open - 1          -- 替身没了（收起 / 换人）：不算
        else
            local d = math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) / 100
            if not w.d0 then w.d0, w.dmin = d, d end
            if d < w.dmin then w.dmin = d end
            if d <= HMISS.REACH and (not w.snapD or d < w.snapD - HMISS.STEP) then
                w.snapD = d
                w.snap = HMISS.snapshot(p1, w.pup, a, b, tn - w.at, mm)
            end
            if d < bestD then best, bestD = w, d end
        end
    end
    -- 掉血 / 换成新的受击类动作 → 算离我最近的那个替身的招碰到了我（对决只有一个对手）
    local seen = HMISS.hp ~= nil
    if best and seen and ((hp and hp < HMISS.hp - 0.5) or (hitNow and mm ~= HMISS.m)) then best.touched = true end
    HMISS.hp, HMISS.m = hp or HMISS.hp, mm
    for key, w in pairs(HMISS.list) do
        if tn - w.at > HMISS.WIN then HMISS.close(key, w, tn, "超时") end
    end
end
-- 一次快照：替身动作、替身朝向偏离"朝我"多少度、我的动作 / 无敌标签
function HMISS.snapshot(p1, pup, a, b, dt, mm)
    local pm = montageOf(pup)
    local yaw = yawOf and yawOf(pup)
    local off = yaw and math.abs((math.deg(math.atan(b.Y - a.Y, b.X - a.X)) - yaw + 180.0) % 360.0 - 180.0) or nil
    local inv = G and G.tagsMatching and G.tagsMatching(p1, TOUCH.INV_TAGS) or nil
    return string.format("放出后 %.1f 秒：替身动作 %s%s；我动作 %s%s", dt, (pm and pm ~= "") and tostring(pm) or "无",
        off and string.format("、朝向偏 %.0f°", off) or "", mm ~= "" and mm or "无",
        (inv and #inv > 0) and ("、我身上 " .. table.concat(inv, "/")) or "")
end
function HMISS.close(key, w, tn, why)
    HMISS.list[key], HMISS.open = nil, HMISS.open - 1
    if w.touched or not w.d0 then return end
    HMISS.miss = HMISS.miss + 1
    if w.dmin <= 2.5 then HMISS.near = HMISS.near + 1 end
    if w.dmin > HMISS.LOG_DIST then return end                    -- 远处空挥（射击 / 离得远）只计数
    HMISS.logs = HMISS.logs + 1
    if HMISS.logs > HMISS.LOG_MAX and HMISS.logs % 20 ~= 0 then return end
    out("§385 对方%s远端#%d %s 在我这边没碰到我（%s，放出 %.1f 秒）：放出时离我 %.1f 米，最近 %.1f 米%s（累计：放出 %d 招，没碰到 %d，其中最近 2.5 米内 %d）",
        w.tag and (w.tag .. " ") or "", w.id, w.name, why, tn - w.at, w.d0, w.dmin,
        w.snap and ("；最近时 " .. w.snap) or "", HMISS.n, HMISS.miss, HMISS.near)
end
-- §207 本地 AI：L1+圈（瞬杀 / 裂斩 / 影杀）打 AI 只剩约一半（用户 11-10"跟 ai 打，L1+圈 几乎没伤害了"）。
-- 原因：td= 按"替身本机掉的血 × 系数"算，替身本机血量 = AI 回报的血量；L1+圈 原版一刀 7000–8000（系数 0.14 / 0.15 就是按这个定的），
-- 远大于替身剩的血，本机掉血被替身血量截住（锁血停在 0.01）→ 回报 = 替身剩血 × 系数。mp_probe.log 11-10：09:04:39 #313 替身 3858 → -270
-- = 3857 × 0.07（伤害 50% × 瞬杀 0.14）；09:01:54 #194 替身 3588 → -251；09:04:49 #322 替身 2834 → -198。真人联机不走这条（对方游戏里替身先乘系数再打）。
-- 修法：对手是本地 AI / 假对手（ai=1）、我刚放了 L1+圈 的 BIG_SEC 秒内，替身本机血量和上限临时多加 HEAD（掉血不再被截住），
-- 按对方回报校正血量时也带上这份（TOUCH.localHp），窗口过了 / 不在交手 / AI 倒下就撤回。真人对手（ai≠1）一律不加
TOUCH.HEAD, TOUCH.BIG_SEC, TOUCH.headNow = 20000, 4.0, 0
TOUCH.BIG = { ShunSha = true, LieZhan = true, YingSha = true }
function TOUCH.isBig(n)
    local k = n and n:match("^GA_GlobalActionAbilit%a*_(%a+)_")
    return k ~= nil and TOUCH.BIG[k] == true
end
function TOUCH.noteFire(n, tn)      -- ULT.emit 发出招事件时调
    if NET.evId then                                 -- §388 名字多留 60 秒：落空回来时 NET.evName 常常已经清掉
        TOUCH.names[NET.evId], TOUCH.nameAt[NET.evId] = n, tn
        for k, t in pairs(TOUCH.nameAt) do
            if tn - t > TOUCH.NAME_WIN then TOUCH.names[k], TOUCH.nameAt[k] = nil, nil end
        end
    end
    if n and TOUCH.SWORD[n] then TOUCH.sword = { id = NET.evId, at = tn, name = n } end     -- §388 紫冥剑收尾招的飞剑
    if TOUCH.isBig(n) then TOUCH.bigAt = tn end
    if SUMMON and SUMMON.armName and SUMMON.armName(n) then TOUCH.sum = { id = NET.evId, at = tn, name = n }      -- §350
    elseif isAttackAbility(n) then
        TOUCH.lastAtk = { id = NET.evId, at = tn }
        if TOUCH.isFlowerCast(n) then                    -- §378（上一招留着的累计不用清：§380.1 起按 LINGER 过期）
            TOUCH.flower = { id = NET.evId, at = tn, name = n }
        end
    end
    if AIF and isAttackAbility(n) then AIF.noteFire(n, NET.evId, tn) end      -- §217
end
-- 现在替身本机该多加多少血（0 = 不加）
function TOUCH.head(tn)
    if PEER.on then return 0 end
    -- §342 木桩：一直留余量（不只 L1+圈 之后 4 秒）。大招 / 绝影大招等一下比替身血量上限（约 3085）还大的，本机掉血也不被截住，
    -- td= 报的是完整伤害（用户 11-16"剩 10 血、100 伤害的招按 100 算"）
    if not (NET.rai and NET.driving and (NET.rdummy or (TOUCH.bigAt and tn - TOUCH.bigAt < TOUCH.BIG_SEC))) then return 0 end
    if not (NET.remoteHp and NET.remoteHp > 0 and NET.remoteHpm and NET.remoteHpm > 0) then return 0 end
    if not TOUCH.counts() then return 0 end
    return TOUCH.HEAD
end
function TOUCH.localHp(v) return v + (PEER.on and 0 or (TOUCH.headNow or 0)) end      -- 对方回报的血量 → 替身本机该写的（上限用这个）
-- §301 本地 AI"血越少越难打"（内测反馈 11-14）：§207 只管 L1+圈，普通招一样被截——替身本机血量 = AI 剩血，一刀原版比剩血大时
-- 本机只掉"剩血那么多"，回报 = 剩血 × 系数；系数 < 1 时每刀只砍掉剩血的固定一截，越打越少、打不到 0（最后靠退回 400 才死）。
-- mp_probe.log 11-13 01:24:45–47（伤害 50%、武器平衡关，系数 0.5）：402 → 200 → 100 → 50，01:25:19–22：210 → 104 → 52 → 26 → 14。
-- 修法：本地 AI / 假对手（ai=1）交手中，替身本机当前血量一直写满（= AI 血量上限 + §207 临时那份），每刀量到的就是原版掉血；
-- 上限不动（按最大血量算的效果不变大）。AI 真实血量照旧只看回报（NET.remoteHp，对手血条也是它）。不在交手 / AI 倒下 / 真人对手照旧
function TOUCH.fullOn()
    if PEER.on then return false end
    if not (NET.rai and NET.driving) then return false end
    if not (NET.remoteHp and NET.remoteHp > 0 and NET.remoteHpm and NET.remoteHpm > 0) then return false end
    return TOUCH.counts()
end
function TOUCH.localCur(rhp)        -- 对方回报的血量 → 替身本机"当前血量"该写的
    if TOUCH.fullOn() then return TOUCH.localHp(NET.remoteHpm) end
    return TOUCH.localHp(rhp)
end
-- watchHp 量完这一帧之后调：要加 / 撤的时候改替身血量和上限，并同步 ST.pupHpSeen（改血不算碰到）
function TOUCH.headStep(pup, tn, h)
    if not h then return end
    local want = TOUCH.head(tn)
    if want == 0 and TOUCH.headNow == 0 then return end                        -- 平时（真人对手 / 没放 L1+圈）到这里就走，不多读
    local key = pathOf(pup)
    if TOUCH.headFor ~= key then TOUCH.headFor, TOUCH.headNow = key, 0 end      -- 换了替身：新替身没加过
    if want == TOUCH.headNow then return end
    local hm, hp = NET.remoteHpm or attrOf(pup, "Health_Max") or h, NET.remoteHp or h
    if want > 0 then
        setAttr(pup, "Health_Max", hm + want)
        setAttr(pup, "Health", h + want)
    else
        if TOUCH.fullOn() then hp = hm end            -- §301 本地 AI 交手中替身本机保持满血
        setAttr(pup, "Health", hp > 0 and hp or 1)
        setAttr(pup, "Health_Max", hm)
        setAttr(pup, "Health", hp > 0 and hp or 1)    -- 先降上限会被钳到上限，再写一次
    end
    TOUCH.headNow = want
    ST.pupHpSeen = hpOf(pup)
    TOUCH.headLogs = (TOUCH.headLogs or 0) + 1
    if TOUCH.headLogs <= 20 then
        out("§207 本地 AI：替身本机血量%s（现在 %s）", want > 0 and string.format(NET.rdummy and "+%d 余量（§342 木桩，一下伤害再大也不被血量截住）" or "临时 +%d，L1+圈 掉血不被剩血截住", want) or "撤回临时加的那份",
            ST.pupHpSeen and string.format("%.0f", ST.pupHpSeen) or "?")
    end
end

function PRED.log(fmt, ...)
    PRED.logs = PRED.logs + 1
    if PRED.logs <= PRED.LOGS or PRED.logs % 25 == 0 then out(fmt, ...) end
end

-- suppressLocalReact 看到本机游戏给替身播受击（= 我的刀在本机碰到替身）时调。
-- 返回 true = 已处理（播了预测的格挡，或留着本机受击，或猜落空掐掉），调用方不再掐；false = 照旧掐掉
function PRED.onContact(pup, an, mt, name, tn)
    if not PRED.on then return false end
    local st = PRED.st
    st.contact = st.contact + 1
    -- 11-24 对方举着拙壁盾：对方那边是盾挡住，不预测受击；返回 false = 调用方照旧掐掉本机受击（SHIELD.onContact 已让替身重摆举盾）
    if SHIELD and SHIELD.onContact and SHIELD.onContact(pup, tn) then
        st.shield = (st.shield or 0) + 1
        return false
    end
    local busy = PRED.busy(pup, tn)
    if busy then st.busy = st.busy + 1; return false end
    local g = PRED.guarding(tn)
    local p = PRED.prob(g)
    local atk = PRED.myAttackId()
    local skill = (NET and NET.evName and NET.evName[atk]) or (NET and NET.lastMyAtk)
    local isAi = (NET and NET.rai == true)

    -- §236 检查远端是否已先行回报本招结果（先到则直接按实际结果处理，回测准确率 100%）
    local rk = NET and NET.resKind and NET.resKind[atk]
    local rkAt = NET and NET.resAtkTime and NET.resAtkTime[atk]
    local hasPrior = (rk ~= nil and rkAt ~= nil and tn - rkAt < PRED.WAIT)

    local kind, reason
    if hasPrior then
        if rk == "miss" then
            kind, reason = "miss", string.format("对方先前已回报落空(Δ=%.2fs)", tn - rkAt)
        elseif rk == "parry" or rk == "block" then
            kind, reason = "deflect", string.format("对方先前已回报%s(Δ=%.2fs)", RES_NAME[rk] or rk, tn - rkAt)
        else
            kind, reason = "hit", string.format("对方先前已回报命中(Δ=%.2fs)", tn - rkAt)
        end
    elseif p >= PRED.DEF_TH then
        kind, reason = "deflect", string.format("对方%s格挡、历史防住 %.0f%%", g and "在" or "没在", p * 100)
    else
        -- 在线学习器：按我出的招（技能名）分桶的落空率（样本够且落空率高于阈值才猜落空）
        local obs, mRate = PRED.getSkillStats(skill, isAi)
        local reqObs = isAi and (PRED.SKILL_AI_MIN_S or 3) or (PRED.SKILL_MIN_S or 3)
        local reqTh = isAi and (PRED.SKILL_AI_MISS_TH or 0.85) or (PRED.SKILL_MISS_TH or 0.5)
        if obs >= reqObs and mRate >= reqTh then
            kind, reason = "miss", string.format("招式 %s 历史落空率高(%.0f%%, N=%d)", skill or "未知", mRate * 100, obs)
        elseif p <= PRED.HIT_TH and PRED.LOCAL_HIT then
            kind, reason = "hit", string.format("对方%s格挡、历史防住 %.0f%%", g and "在" or "没在", p * 100)
        else
            kind, reason = "wait", string.format("拿不准(%.0f%%)", p * 100)
        end
    end

    local featStr = string.format("先到=%s, 招式=%s, 对方格挡=%s(%.0f%%), 动作=%s, 远端闪避=%s",
        hasPrior and (RES_NAME[rk] or rk) or "无", skill or "未知",
        g and "1" or "0", p * 100, name,
        (NET and NET.rDodgeAt and tn - NET.rDodgeAt < 1.0) and string.format("%.2fs前", tn - NET.rDodgeAt) or "无")
    PRED.log("预测特征：我第 #%d 招 | 猜=%s | %s", atk, kind == "deflect" and "格挡" or (kind == "hit" and "命中" or (kind == "miss" and "落空" or "等待")), featStr)

    local pRec = { kind = kind, at = tn, g = g, p = p, atk = atk, m = name, feat = featStr, skill = skill, prior = hasPrior, isAi = isAi }
    PRED.pend = pRec
    PRED.pends = PRED.pends or {}
    PRED.pends[atk] = pRec

    if hasPrior then
        st.prior = (st.prior or 0) + 1
        if rk == "miss" then
            pcall(function() an:Montage_Stop(0.0, mt) end)
            pRec.m = nil
            st.preMiss = (st.preMiss or 0) + 1
            PRED.log("预测：我第 #%d 招碰到替身，%s → 掐掉本机受击 %s", atk, reason, name)
            return true
        elseif rk == "parry" or rk == "block" then
            pcall(function() an:Montage_Stop(0.0, mt) end)
            local ok, a = PRED.playDef(pup, rk)                 -- §456 本地 AI 按武器挑格挡动作
            pRec.m = ok and a or nil
            st.preDef = st.preDef + 1
            PRED.log("预测：我第 #%d 招碰到替身，%s → 播格挡 %s（%s）", atk, reason, a, ok and "已播" or "失败")
            return true
        else
            ST.pupOwnName, ST.pupOwnFrames = name, PRED.KEEP_FRAMES
            st.preHit = st.preHit + 1
            PRED.log("预测：我第 #%d 招碰到替身，%s → 留着本机受击 %s", atk, reason, name)
            return true
        end
    end

    if kind == "deflect" then
        pcall(function() an:Montage_Stop(0.0, mt) end)
        local ok, a = PRED.playDef(pup, (NET.rdummy and NET.rtrainGuard == "perfect") and "parry" or "block")     -- §456
        pRec.m = ok and a or nil
        st.preDef = st.preDef + 1
        PRED.log("预测：我第 #%d 招碰到替身，%s → 先播格挡 %s（%s）", atk, reason, a, ok and "已播" or "失败")
        return true
    elseif kind == "hit" then
        ST.pupOwnName, ST.pupOwnFrames = name, PRED.KEEP_FRAMES     -- 本机游戏的受击留着（suppressLocalReact 认模组自己播的）
        st.preHit = st.preHit + 1
        PRED.log("预测：我第 #%d 招碰到替身，%s → 留着本机受击 %s", atk, reason, name)
        return true
    elseif kind == "miss" then
        pcall(function() an:Montage_Stop(0.0, mt) end)
        pRec.m = nil
        st.preMiss = (st.preMiss or 0) + 1
        PRED.log("预测：我第 #%d 招碰到替身，%s → 猜落空，掐掉本机受击 %s", atk, reason, name)
        return true
    end
    st.wait = st.wait + 1
    return false
end

-- 纠正时追帧：从"碰到之后过了多久"那一秒播起（≥ SEEK_MIN 才跳，最多 SEEK_MAX）。返回日志用的说明
function PRED.seek(pup, s)
    if not (s and s >= PRED.SEEK_MIN) then return "" end
    local ok = LAT.setPos(pup, math.min(s, PRED.SEEK_MAX))
    return ok and string.format("，追帧 %.2f 秒", math.min(s, PRED.SEEK_MAX)) or "，追帧失败"
end

-- applyRemoteResult 开头调：对账 + 学习。返回 { skip = 预测对了不用重播, seek = 纠正时追帧秒数, m = 正在播的预测动作, note = 落空时的说明 }
function PRED.onResult(r, kind, tn)
    local res = {}
    local isDef = kind == "parry" or kind == "block"

    -- 清理超时的待决预测
    if PRED.pends then
        for k, v in pairs(PRED.pends) do
            if tn - v.at > PRED.WAIT then
                PRED.pends[k] = nil
                if PRED.pend == v then PRED.pend = nil end
                if not v.prior then PRED.st.nores = PRED.st.nores + 1 end
            end
        end
    elseif PRED.pend and tn - PRED.pend.at > PRED.WAIT then
        if not PRED.pend.prior then PRED.st.nores = PRED.st.nores + 1 end
        PRED.pend = nil
    end

    local p = (PRED.pends and PRED.pends[r.atk]) or (PRED.pend and PRED.pend.atk == r.atk and PRED.pend) or nil
    if p and r.atk ~= p.atk then
        -- 不是碰到的那一招：更早的招只学不动画面；更新的招（本机没碰到）当没有预测
        if r.atk < p.atk then
            if kind ~= "miss" then PRED.learn(PRED.guarding(tn), isDef) end
            if not p.prior then
                PRED.learnSkill(p.skill or (NET and NET.evName and NET.evName[r.atk]), kind == "miss", p.isAi)
            end
            return res
        end
        p = nil
    end
    if kind ~= "miss" then PRED.learn(p and p.g or PRED.guarding(tn), isDef) end
    if not p then return res end

    if PRED.pends then PRED.pends[r.atk] = nil end
    if PRED.pend == p then PRED.pend = nil end

    if p.prior then
        -- 结果已在接触前处理过，无需重复对账、重复计猜对、重复学习或追帧
        return res
    end

    -- 只有真正预测过（非先到结果）的接触，才在线学习招式落空率
    PRED.learnSkill(p.skill or (NET and NET.evName and NET.evName[r.atk]), kind == "miss", p.isAi)

    local pup = puppet()
    local still = p.m ~= nil and valid(pup) and montageOf(pup) == p.m     -- 预播的动作还在播（没被出招 / 受击换掉）
    local want = isDef and "deflect" or (kind == "hit" and "hit" or "miss")
    local st = PRED.st
    if p.kind == want then
        -- 猜对了：已经播过（哪怕已经播完）就不再重播，晚到的重播只会多一次动作
        st.right = st.right + 1
        res.skip, res.m = p.m ~= nil, p.m
        return res
    end
    if p.kind ~= "wait" then st.wrong = st.wrong + 1 end
    if want == "miss" then
        -- 预播了格挡 / 留着受击，结果是落空：收掉（淡出，不是硬切）
        if still and p.kind ~= "wait" then
            G.retract(pup)
            st.undo = st.undo + 1
            res.note = "（替身预播的 " .. p.m .. " 收掉）"
        end
        return res
    end
    -- 猜错（或没猜/猜落空但实际命中/防御）：停掉预播的，实际动作从碰到之后过了多久那一秒播起
    if still and p.kind ~= "wait" then cutMontage(pup) end
    if p.kind ~= "wait" then st.fix = st.fix + 1 end
    res.seek = tn - p.at
    if p.kind ~= "wait" then
        local guessedName = p.kind == "deflect" and "格挡" or (p.kind == "hit" and "中招" or "落空")
        PRED.log("预测错了：我第 #%d 招 猜%s、实际%s（防住概率 %.0f%%）→ %s", r.atk,
            guessedName, RES_NAME[kind] or kind, (p.p or 0) * 100,
            p.kind == "miss" and "改播实际动作" or ("停掉 " .. tostring(still and p.m or "（已经换掉了）") .. "，改播实际动作"))
    end
    return res
end

-- ============================================================ §105.3 房间设置"红蓝光反击：关"时不出完美闪避反击
-- 机制见 HANDOVER §105：没有哪个 GameplayTag 打开它（红 / 蓝是攻击方子弹动作里的 C++ 开关，PBZDeflectSystem），本机常驻被动
--   BP_PerfectDodgePassive 收到闪避帧后按标签 Ability.Action.Hun.PerfectDodge 激活反击；"精防后再按闪避"、木剑升级两条路也出同一类。
--   Lua 改不了子弹 / C++ 判定、传 GameplayTagContainer 会崩（§19.20），所以设置为关时在本机拦反击技能本身：
--   交手中我身上新出现 *PerfectDodge* 技能 → 立刻 K2_CancelAbility，也不发给对方。闪避本身（Dash、GE_PerfectDash 无敌）不受影响。
-- 设置为开（默认）= 原版，什么都不做。影之武装的 *DeflectCounter 不拦。
-- §249.1 用户 11-11 定：蓝光精防反击也一起拦（attack_alert.csv 里 blue + deflect=True 的玩家武器招）：
--   GA_Hun_Long_CounterB_C、GA_Hun_Horizontal_CounterAttack_01_C / _02_C（核查报告 docs/AUDIT_moves_1111.md §3.3）
NOCTR = { on = true, n = 0, LOGS = 20,
          BLUE = { GA_Hun_Long_CounterB_C = true, GA_Hun_Horizontal_CounterAttack_01_C = true, GA_Hun_Horizontal_CounterAttack_02_C = true } }
function NOCTR.is(name) return name:match("^GA_Hun_.*PerfectDodge") ~= nil or NOCTR.BLUE[name] == true end
function NOCTR.active() return NOCTR.on and NET.fighting() and not NET.flagNow("ctr") end
-- netSend 看到我新出现的技能时调：拦了返回 true（调用方不发这招）
function NOCTR.check(p1, name, tn)
    if not (NOCTR.active() and NOCTR.is(name)) then return false end
    local gone = G.cancelAbilities(p1, NOCTR.is)
    NOCTR.n = NOCTR.n + 1
    if NOCTR.n <= NOCTR.LOGS or NOCTR.n % 20 == 0 then
        out("红蓝光反击已关：%s → %s（第 %d 次）", name, #gone > 0 and ("已取消 " .. table.concat(gone, ",")) or "没取消到实例",
            NOCTR.n)
    end
    return true
end

-- ============================================================ §396 红蓝光反击链诊断（只记日志，不改判定 / 不拦技能）
-- 用户 11-19："红蓝光反击，对面闪避我的红光大招时，会触发完美红光反击，这个完美红光反击还可以被我完美红光闪避反击，
--   之后就无法防御了，要加这个的日志"（例：黑魔伤开大招之后的攻击被红光完美闪避反击）。
-- 抓的是一条链：
--   A 我的攻击被对方完美闪避 → 对方红光反击（替身真放出来，或放不出时 PDX 直接播）
--   B 我完美闪避对方的红光反击 → 我的红光反击技能出现
--   C 之后 12 秒里我能不能进架势：架势进出、破防、Stance.Forbid / HoldingStanceKey 标签、杀气、按住的输入、
--     STG 关输入、当前动作 / 技能。重点两行：Stance.Forbid 挂着、按着格挡键却没进架势。
-- 只读：每帧只用 netSend 已经读到的动作 / 技能表；标签 / 按住输入 / 杀气每秒采样一次（一次链最多 12 次）。
-- 查 net/redlight_off.txt 不影响这段（PDX 关了也照样记 A / B）。
CTRD = { ON = true, MAX_CHAIN = 12, MAX_LINES = 400, WATCH = 12.0, SAMPLE = 1.0, MON = 1.0, SPLOG = 60, spLogs = 0,
         TAGS = { "CharacterState.AbilityState.Stance.Forbid", "CharacterState.AbilityState.Stance.HoldingStanceKey",
                  "CharacterState.AIState.CanNotDeflect", "CharacterState.AbilityState.YuuBlade.ExplodeCannotDeflect",
                  "CharacterState.Stun" },
         n = 0, lines = 0, cur = nil, lastPup = nil }

function CTRD.on()
    if not (CTRD.ON and NET.fighting()) then return false end
    if CTRD.offC == nil then CTRD.offC = io.open((NET_DIR or "net") .. "/ctrdiag_off.txt", "r") ~= nil end   -- 想关：放这个文件
    return not CTRD.offC
end                                                             -- 只在交手阶段记（倒计时 / 结算 / 对局外不记）
function CTRD.log(...)
    if CTRD.lines >= CTRD.MAX_LINES then return end
    CTRD.lines = CTRD.lines + 1
    out(...)
    if CTRD.lines == CTRD.MAX_LINES then out("§396 红反链日志记满 %d 行，这一节不再记", CTRD.MAX_LINES) end
end
-- 完美红光反击 / 蓝光精防反击的技能名（对方放出来、我放出来都算）
function CTRD.isCounter(n)
    return n ~= nil and (n:find("PerfectDodge", 1, true) ~= nil or n:find("DeflectCounter", 1, true) ~= nil)
end
function CTRD.skills(act)
    local t = {}
    for n in pairs(act or {}) do
        if n:find("Stance", 1, true) or n:find("Deflect", 1, true) or n:find("PerfectDodge", 1, true)
            or n:find("BreakEscape", 1, true) or n:find("SWT", 1, true) or n:find("SwitchForm", 1, true)
            or n:find("Execution", 1, true) or n:find("HeiMoShang", 1, true) then
            t[#t + 1] = n
            if #t >= 5 then break end
        end
    end
    return #t > 0 and table.concat(t, ",") or "无"
end
-- 我最近一招（被对面完美闪避的那一招）：招式号 → 名字（名字留 300 个，落空晚回来也有）
function CTRD.myAtk(tn)
    local id = NET.myAtkId
    local nm = (id and NET.evName and NET.evName[id]) or NET.lastMyAtk
    if nm then return string.format("%s（%.2f 秒前）", nm, tn - (NET.myAtkAt or tn)) end
    return "读不到"
end
-- 开一条链 / 接在当前链上（A → B 3 秒内算同一条）；超过上限不再记
function CTRD.open(kind, name, tn)
    local c = CTRD.cur
    if not (c and tn - c.t0 <= 3.0 and tn <= (c.untilT or 0) + 0.1) then
        CTRD.n = CTRD.n + 1
        if CTRD.n > CTRD.MAX_CHAIN then
            if not CTRD.capped then CTRD.capped = true; CTRD.log("§396 红反链记满 %d 条，后面不再记", CTRD.MAX_CHAIN) end
            return nil
        end
        c = { id = CTRD.n, t0 = tn, untilT = tn + CTRD.WATCH, guardN = 0, breakN = 0 }
        CTRD.cur = c
    end
    c.lastKind, c.lastAt = kind, tn
    return c
end
-- 替身放出来的远端技能（base_replay 的 activateOnPuppet → main.lua pupAction）
function CTRD.onPuppet(name, how, tn)
    if not CTRD.on() then return end
    if isAttackAbility(name) then CTRD.lastPup = { name = name, at = tn } end     -- 对方最近一招（我闪避的是它）
    if CTRD.isSpecial(name) then
        CTRD.splog("§396 特殊攻击（对方）：%s；%s；我最近一招 %s", name, tostring(how), CTRD.myAtk(tn))
    end
    if not CTRD.isCounter(name) then return end
    local c = CTRD.open("A", name, tn)
    if not c then return end
    CTRD.log("§396 红反链#%d A 对方红光反击（替身放）：%s；%s；我最近一招 %s", c.id, name, tostring(how), CTRD.myAtk(tn))
end
-- 对方红光反击是模组直接播的（PDX：替身放不出时）；base_diag 的 PDX.start 里调
function CTRD.onPdx(use, tn)
    if not CTRD.on() then return end
    local c = CTRD.open("A", use, tn)
    if not c then return end
    c.pdx = true
    CTRD.log("§396 红反链#%d A 对方红光反击是模组直接播的（PDX）：%s；我最近一招 %s", c.id, tostring(use), CTRD.myAtk(tn))
end
-- 我身上新出现红光反击技能（netSend 技能差里调）
function CTRD.onMine(name, tn)
    if not CTRD.on() then return end
    if CTRD.isSpecial(name) then
        CTRD.sp = { name = name, at = tn, segs = 0 }
        CTRD.splog("§396 特殊攻击（我）：%s 出现（按住续段看后面「第 N 段」，4 秒还没结束会再记一行）", name)
    end
    if not CTRD.isCounter(name) then return end
    local c = CTRD.open("B", name, tn)
    if not c then return end
    c.untilT, c.skill, c.skillEnded, c.sampleAt = tn + CTRD.WATCH, name, false, tn
    local r = CTRD.lastPup
    local prev = (r and tn - r.at <= 3.0) and string.format("%s（%.2f 秒前）", r.name, tn - r.at) or "没有（3 秒内没看到对方出招）"
    CTRD.log("§396 红反链#%d B 我的红光反击出现：%s；对方上一招 %s；ctr=%s；开始观察防御 %.0f 秒",
        c.id, name, prev, NOCTR.active() and "关（这招会被拦）" or "开", CTRD.WATCH)
end
-- 每秒采样：标签 / 按住输入 / 杀气 / 动作 / 技能 / 输入锁
function CTRD.sample(c, p1, m, act, tn)
    local tags = G.tagsMatching(p1, CTRD.TAGS) or {}
    local set = {}
    for _, t in ipairs(tags) do set[t] = true end
    local h = G.holdingInputs(p1)
    local hn = {}
    for k in pairs(h or {}) do hn[#hn + 1] = k end
    table.sort(hn)
    local sh = attrOf(p1, "Shachi")
    CTRD.log("§396 红反链#%d +%.1fs 动作=%s 架势=%s 杀气=%s 按住=%s 标签=%s 输入锁=%s 技能=%s",
        c.id, tn - c.t0, (m and m ~= "") and m or "（空）", c.guard and "在" or "不在",
        sh and string.format("%.0f", sh) or "?", #hn > 0 and table.concat(hn, "+") or "无",
        #tags > 0 and table.concat(tags, ",") or "无", STG.active(tn) and "关着" or "开", CTRD.skills(act))
    if set["CharacterState.AbilityState.Stance.Forbid"] and not c.forbid then
        c.forbid = true
        CTRD.log("§396 红反链#%d !! Stance.Forbid（架势被禁）挂着：动作 %s，杀气 %s",
            c.id, (m and m ~= "") and m or "（空）", tostring(sh))
    end
    if set["CharacterState.AbilityState.Stance.HoldingStanceKey"] and not c.guard then
        c.holdBad = (c.holdBad or 0) + 1
        if c.holdBad == 1 or c.holdBad % 3 == 0 then
            CTRD.log("§396 红反链#%d !! 按着格挡键（HoldingStanceKey）但没进架势：动作 %s，标签 %s",
                c.id, (m and m ~= "") and m or "（空）", #tags > 0 and table.concat(tags, ",") or "无")
        end
    end
    c.lastTags = tags
end
-- 特殊攻击（防御+重攻击，DB / SpecialSkill / GuardPoint）：按住会续段，同一个技能一直挂着时 netSend 的技能差看不到"新一招"，
--   模组只发一次，对方替身只播一次动作（11-19 伊格尼斯："只显示前 3 次攻击旋转的动作，后续按住不给对方显示动作，但实际生效"）。
--   这里只记：我这边的技能出现 / 每换一段动作 / 结束（几段、多少秒）/ 挂了 4 秒还没结束；对方收到的是什么。
function CTRD.isSpecial(n)
    return n ~= nil and (n:find("_DB_C", 1, true) or n:find("_DB_", 1, true) or n:find("SpecialSkill", 1, true)
        or n:find("GuardPoint", 1, true) or n:find("Special_Defence", 1, true))
end
function CTRD.splog(...)
    if CTRD.spLogs >= CTRD.SPLOG then return end
    CTRD.spLogs = CTRD.spLogs + 1
    CTRD.log(...)
end
function CTRD.forget()
    CTRD.monAt, CTRD.monForbid, CTRD.forbidAt, CTRD.holdBad, CTRD.monReadBad = nil, nil, nil, nil, nil
    CTRD.detailActor, CTRD.detailLast, CTRD.detailAt = nil, nil, nil
end
-- Bounded full snapshots only after sustained guard intent, never per normal frame.
function CTRD.detail(p1, m, tn)
    if not CTRD.holdBad or tn - CTRD.holdBad < 2 or (CTRD.detailN or 0) >= 12
        or CTRD.lines >= CTRD.MAX_LINES or tn - (CTRD.detailAt or -100) < 5 then return end
    local okH, held = pcall(G.holdingInputs, p1, true)
    if okH and type(held) == "table" and not held.IA_ChangeArmed then return end
    CTRD.detailAt, CTRD.detailN = tn, (CTRD.detailN or 0) + 1
    local okA, all = pcall(G.activeAbilities, p1)
    local function sortedKeys(t, ok)
        if not ok or type(t) ~= "table" then return "unreadable" end
        local a = {}
        for n in pairs(t) do a[#a + 1] = n end
        table.sort(a)
        return #a > 0 and table.concat(a, ",") or "none"
    end
    CTRD.log("counter guard snapshot: observed=%.1fs montage=%s hp=%s shachi=%s inputLocked=%s held=%s fullAbilities=%s",
        tn - CTRD.holdBad, tostring(m), tostring(attrOf(p1, "Health")), tostring(attrOf(p1, "Shachi")),
        tostring(STG.active(tn)), sortedKeys(held, okH), sortedKeys(all, okA))
end
-- 常驻防御监视（交手中每秒一次，不依赖红反链）：11-19 伊格尼斯"只有黑魔伤会永久无法防御"——
--   gasgraph 显示黑魔伤 SWT / 混沌切形态 / 处决等引用 Stance.Forbid，但不能据此判断谁授予了标签。
--   这里只记观察到的出现 / 解除和格挡意图；异常持续时补全量活动技能快照，不把松键当成恢复。
function CTRD.monFrame(p1, m, act, tn)
    if not CTRD.on() then return end
    if CTRD.monAt and tn < CTRD.monAt then CTRD.forget() end
    if tn - (CTRD.monAt or -100) < CTRD.MON then return end
    CTRD.monAt = tn
    local tags = G.tagsMatching(p1, CTRD.TAGS, true)
    if type(tags) ~= "table" then
        if not CTRD.monReadBad then CTRD.log("counter guard monitor: tags unreadable, no state transition inferred") end
        CTRD.monReadBad, CTRD.holdBad = true, nil
        return
    end
    CTRD.monReadBad = nil
    local set = {}
    for _, t in ipairs(tags) do set[t] = true end
    local forbid = set["CharacterState.AbilityState.Stance.Forbid"] == true
    local hold = set["CharacterState.AbilityState.Stance.HoldingStanceKey"] == true
    local guard = BLK.guarding(m, act) ~= nil
    if forbid ~= (CTRD.monForbid or false) then
        CTRD.monForbid = forbid
        if forbid then CTRD.forbidAt = tn end
        CTRD.log("§396 防御监视：Stance.Forbid %s%s 动作=%s 技能=%s 杀气=%s 按住格挡=%s 标签=%s",
            forbid and "出现" or "解除",
            (not forbid and CTRD.forbidAt) and string.format("（挂了 %.1f 秒）", tn - CTRD.forbidAt) or "",
            (m and m ~= "") and m or "（空）", CTRD.skills(act), tostring(attrOf(p1, "Shachi")),
            hold and "是" or "否", #tags > 0 and table.concat(tags, ",") or "无")
    end
    local sameActor = CTRD.detailActor == p1 or (G.sameObj and CTRD.detailActor and G.sameObj(CTRD.detailActor, p1))
    if not sameActor or (CTRD.detailLast and (tn < CTRD.detailLast or tn - CTRD.detailLast > 2.5)) then CTRD.holdBad = nil end
    CTRD.detailActor, CTRD.detailLast = p1, tn
    if hold and not guard then
        if not CTRD.holdBad then
            CTRD.holdBad = tn
            CTRD.log("§396 防御监视 !! 按着格挡键但没进架势：动作=%s 技能=%s 标签=%s 杀气=%s",
                (m and m ~= "") and m or "（空）", CTRD.skills(act),
                #tags > 0 and table.concat(tags, ",") or "无", tostring(attrOf(p1, "Shachi")))
        end
        CTRD.detail(p1, m, tn)
    elseif CTRD.holdBad then
        if guard then
            CTRD.log("§396 防御监视：架势回来了（按着格挡 %.1f 秒没进）", tn - CTRD.holdBad)
        else
            CTRD.log("counter guard monitor: guard intent ended after %.1fs; recovery not observed", tn - CTRD.holdBad)
        end
        CTRD.holdBad = nil
    end
end
-- 每帧（netSend 读完动作 / 技能表之后）：架势进出、破防、红光反击技能结束、采样、到点收尾
function CTRD.frame(p1, m, act, tn)
    local sp = CTRD.sp
    if sp then
        if m ~= sp.mont and m ~= "" then
            sp.mont = m
            sp.segs = sp.segs + 1
            CTRD.splog("§396 特殊攻击（我）：%s 第 %d 段动作 %s（+%.1f 秒）", sp.name, sp.segs, m, tn - sp.at)
        end
        if not (act and act[sp.name]) then
            CTRD.splog("§396 特殊攻击（我）：%s 结束（%.1f 秒，%d 段动作）", sp.name, tn - sp.at, sp.segs)
            CTRD.sp = nil
        elseif tn - sp.at > 4.0 and not sp.longLogged then
            sp.longLogged = true
            CTRD.splog("§396 特殊攻击（我）：%s 已经挂了 %.1f 秒还在（第 %d 段动作）——按住续段 / 技能没结束；对方只收到第一次",
                sp.name, tn - sp.at, sp.segs)
        end
    end
    local c = CTRD.cur
    if not c then return end
    if tn > (c.untilT or 0) then
        if not c.done then
            c.done = true
            CTRD.log("§396 红反链#%d 观察结束（%.1f 秒）：进架势 %d 次；破防 %s；架势被禁 %s；按着格挡没进架势 %s；最后动作 %s；最后标签 %s",
                c.id, tn - c.t0, c.guardN or 0, (c.breakN or 0) > 0 and tostring(c.breakN) or "没有",
                c.forbid and "有" or "没有", (c.holdBad or 0) > 0 and (c.holdBad .. " 次采样") or "没有",
                (m and m ~= "") and m or "（空）", (c.lastTags and #c.lastTags > 0) and table.concat(c.lastTags, ",") or "无")
        end
        return
    end
    if c.skill and not c.skillEnded and not (act and act[c.skill]) then
        c.skillEnded = true
        CTRD.log("§396 红反链#%d 我的红光反击 %s 结束（%.2f 秒），动作 %s",
            c.id, c.skill, tn - c.t0, (m and m ~= "") and m or "（空）")
    end
    local brk = act and act["GA_Hun_BreakEscape_C"]
    if brk and not c.breakOn then
        c.breakOn, c.breakN = true, (c.breakN or 0) + 1
        CTRD.log("§396 红反链#%d 破防（GA_Hun_BreakEscape_C），动作 %s，杀气 %s",
            c.id, (m and m ~= "") and m or "（空）", tostring(attrOf(p1, "Shachi")))
    elseif not brk then
        c.breakOn = false
    end
    local g = BLK.guarding(m, act)
    if (g ~= nil) ~= (c.guard or false) then
        c.guard = g ~= nil
        if g then c.guardN = (c.guardN or 0) + 1 end
        CTRD.log("§396 红反链#%d 架势%s", c.id, g and ("进入（" .. g .. "）") or ("离开（动作 " .. tostring(m) .. "）"))
    end
    if tn - (c.sampleAt or -100) >= CTRD.SAMPLE then
        c.sampleAt = tn
        CTRD.sample(c, p1, m, act, tn)
    end
end

-- ============================================================ §161 连续 3 次被精防的硬直锁住出招
-- 以前硬直只是给我 PlayAnimMontage 一段 C_Failed，不挂标签、不拦技能：硬直中按攻击，攻击技能的动作直接把它顶掉（用户 2026-11-08）。
-- 现在：硬直开始后 untilT 之前（= 硬直动作时长，读不到用 DEF，最多 MAX 秒），我身上新出现的攻击技能（isAttackAbility，
--   含影之武装 / 完美闪避反击）→ 立刻 K2_CancelAbility、不发给对方，硬直动作被顶掉的话重播并跳回原来播到的位置。
--   被打中（当前是受击动作）就不重播，受击优先；离开交手阶段不拦。闪避 / 格挡不拦（原版被弹开能不能闪还没核对）
-- §228 事后取消有三个毛病（内测反馈 11-11，HANDOVER §228）：招放出来时游戏已经扣了杀气、取消后不退；按了只出一下起手、手感像"第二下取消第一下"；
--   放出来到被取消之间那一小段招是生效的（紫冥剑 L1+三角 布局被打会自动闪避），硬直里能插闪避。用户定（11-11）：
--   ① 硬直期间直接关输入（不能攻击、不能移动、闪避格挡也不行），硬直动作照播；到时间开回来并清掉按着的键。上面的事后取消留着兜底
--      （关输入失败、或者关之前已经按下的），兜底拦到了会记"!! 关着输入还是出招了"。
--   ② 硬直秒数 / 连续精防几次触发 跟着数值表下发（co= 的 StaggerSec / StaggerHits，主机或大厅服务器定，§158）；
--   ③ 房间设置"精防硬直"（stg）：普通房间默认关（关 = 连续精防也不吃硬直，双方都不播）；武林盟主默认开（NET.RK_DEF，服务器 rkrules 可写 0 关）。
--   关输入用 SetInputMode_UIOnlyEx(pc, nil)：引擎 GameViewportClient 不收输入（和鼠标面板不 focusable 时同一个调用，实测角色不动）；
--   面板 / 输入框开着时本来就是 UIOnly，不碰，开回来时也按面板的状态来（STG.restoreInput 在 inputMode 定义后挂上）
STG = { DEF = 1.0, untilT = nil, at = 0, dur = nil, name = nil, n = 0, LOGS = 20, locked = false, leak = 0,
        SEC_DEF = 1.0, SEC_MIN = 0.2, SEC_MAX = 10, HITS_DEF = 3, HITS_MAX = 20 }
function STG.on() return NET.flagNow("stg") end                 -- §228 房间设置"精防硬直"
-- §422.1 秒数改成房间设置 stgm（近战）/ stgr（远程），1–5 秒、默认 1：对局中按开局定下的，对局外按房间设置（客机 = 主机的）
function STG.resSec(k)
    local v = MATCH and MATCH.res and MATCH.res[k]
    if not NET.resValid(k, v) then v = NET.resOf(k) end
    v = tonumber(v) or STG.SEC_DEF
    if v <= 0 then v = STG.SEC_DEF end
    return math.max(STG.SEC_MIN, math.min(STG.SEC_MAX, v))
end
function STG.sec() return STG.resSec("stgm") end          -- 近战招触发（以前是数值表 co= 的 StaggerSec，§422.1 起不用）
-- §422 用户 11-23「精防三次对方硬直，能区分出来对方是近战还是远程招式么 远程的话改为硬直3秒」：
--   触发硬直的那一招（第 N 次被精防的那招）是远程 / 召唤招 → 锁房间设置 stgr 秒，否则 stgm 秒（§422.1：都是 1–5 秒、默认 1；第一版是数值表、远程默认 3）。
--   名单 = data/move_table.csv「攻击方式」为远程 / 召唤的招 + tools/balance/rough_tune.py 的 SUMMON_RANGED（§190，平衡表按远程算的同一套），
--   比较时去掉末尾 _C。两边各按同一招名算：攻击方看自己这招（NET.evName[编号]），防守方看对方这招（判定窗口的 j.name）
STG.RANGED = {}
for _, n in ipairs({
    "GA_CaoOuSiXian_Normal_01", "GA_DuYan_Bow_Laser", "GA_DuYan_Bow_Normal", "GA_HuangJinHuoChong_Dash", "GA_HuangJinHuoChong_DeflectCounter",
    "GA_HuangJinHuoChong_Normal_02", "GA_HuangJinHuoChong_Normal_04", "GA_Hun_AdvancedDash_Double_Jade", "GA_Hun_BronzeSword_BA",
    "GA_Hun_BronzeSword_B_Hold", "GA_Hun_BronzeSword_C", "GA_Hun_BronzeSword_SWT", "GA_Hun_Chaos_AAABB_Fire", "GA_Hun_Chaos_AAAB_Fire",
    "GA_Hun_Chaos_AABB_Fire", "GA_Hun_Chaos_AAB_Fire", "GA_Hun_Chaos_ABB_Fire", "GA_Hun_Chaos_AB_Fire", "GA_Hun_Chaos_BBB_Fire",
    "GA_Hun_Chaos_BB_Fire", "GA_Hun_Chaos_B_DashDraw", "GA_Hun_Chaos_B_Dash", "GA_Hun_Chaos_B_Draw", "GA_Hun_Chaos_B_Fire", "GA_Hun_Chaos_C",
    "GA_Hun_Double_JueYing_C_Air", "GA_Hun_Double_JueYing_C", "GA_Hun_FengLeiJian_FengLeiState_SpecailAttack_02", "GA_Hun_GuiTouBlade_B_Hold",
    "GA_Hun_HeiMoShang_AAAAAB", "GA_Hun_HeiMoShang_AAABB", "GA_Hun_HeiMoShang_AAAB", "GA_Hun_HeiMoShang_AABB", "GA_Hun_HeiMoShang_AAB",
    "GA_Hun_HeiMoShang_ABB", "GA_Hun_HeiMoShang_AB", "GA_Hun_HeiMoShang_BBB", "GA_Hun_HeiMoShang_BB", "GA_Hun_HeiMoShang_B",
    "GA_Hun_HeiMoShang_B_DashDraw", "GA_Hun_HeiMoShang_B_Dash", "GA_Hun_HeiMoShang_B_Draw", "GA_Hun_HeiMoShang_C1", "GA_Hun_Horizontal_BladeWave",
    "GA_Hun_Horizontal_C", "GA_Hun_Jade_AAABB", "GA_Hun_Jade_AAAB", "GA_Hun_Jade_AABB", "GA_Hun_Jade_AAB", "GA_Hun_Jade_A_Snap", "GA_Hun_Jade_BBBB",
    "GA_Hun_Jade_B_Dash", "GA_Hun_Jade_B_Snap", "GA_Hun_Jade_C_Range", "GA_Hun_Jade_DB", "GA_Hun_Jade_SWT", "GA_Hun_LuanYing_AAAB",
    "GA_Hun_LuanYing_AAB", "GA_Hun_LuanYing_AB", "GA_Hun_LuanYing_BBB", "GA_Hun_LuanYing_BB", "GA_Hun_LuanYing_B", "GA_Hun_LuanYing_CA",
    "GA_Hun_LuanYing_P2_AAB", "GA_Hun_LuanYing_P2_AB", "GA_Hun_LuanYing_P2_BBB", "GA_Hun_LuanYing_P2_BB", "GA_Hun_LuanYing_P2_B",
    "GA_Hun_LuanYing_P2_CA", "GA_Hun_LuanYing_SWT_P1", "GA_Hun_LuanYing_SWT_P2", "GA_Hun_Lute_AAA", "GA_Hun_Lute_AA", "GA_Hun_Lute_A",
    "GA_Hun_Lute_SKill", "GA_Hun_ShuangYue_DB", "GA_Hun_SnakeDual_DA", "GA_Hun_SnakeDual_DB", "GA_Hun_SnakeDual_PerfectDodge",
    "GA_Hun_ZiMingJian_New_CCC", "GA_Hun_ZiMingJian_New_CC", "GA_Hun_ZiMingJian_New_DB", "GA_JianKeZhaoJiLing_Normal_01",
    "GA_KuYeSiZhuChuan_Normal_01", "GA_LionHead_DoubleFireBall", "GA_LionHead_FireBall", "GA_Lute_Dash", "GA_MiaoShouFeiDao_DB",
    "GA_MiaoShouFeiDao_Normal_01", "GA_MiaoShouFeiDao_Normal_02", "GA_MiaoShouFeiDao_Normal_03", "GA_TanLang_ExtraAttack", "GA_TanLang_Normal",
    "GA_TanLang_SpeicalAttack", "GA_TigerCannon", "GA_TigerCannon_Dash", "GA_TigerCannon_Ultimate", "GA_UnnamedBow", "GA_UnnamedBow_Dash",
    "GA_UnnamedBow_DeflectCounter", "GA_YouLongCha_Dash", "GA_YouLongCha_Normal", "GA_YouLongHead_WaterCannon",
}) do STG.RANGED[n] = true end
function STG.isRanged(name)
    if type(name) ~= "string" or name == "" then return false end
    return STG.RANGED[(name:gsub("_C$", ""))] == true
end
function STG.secRanged() return STG.resSec("stgr") end    -- §422.1 远程招触发：房间设置 stgr
function STG.secFor(name) return STG.isRanged(name) and STG.secRanged() or STG.sec() end
function STG.need()         -- 连续精防几次触发：数值表 co= 的 StaggerHits（没写 = 3），1–20 的整数
    local v = math.floor(tonumber(BAL.cost("StaggerHits")) or STG.HITS_DEF)
    if v < 1 then v = STG.HITS_DEF end
    return math.min(STG.HITS_MAX, v)
end
function STG.active(tn) return STG.untilT ~= nil and tn < STG.untilT and NET.fighting() end
-- 第 N 次精防触发时调（代替 staggerOn）：播硬直、关输入、记锁到什么时候；返回日志里的一句
function STG.start(p1, weaponId, tn, sec, atkName)   -- §422 sec = 这次锁几秒（按触发那招近战 / 远程算），nil = STG.sec()
    if STG.active(tn) then          -- §230.2 已经在硬直里：不重播、不重新计时（以前连着触发能锁 7–8 秒）
        return string.format("已经在硬直里（还剩 %.2f 秒），不重新计时", STG.untilT - tn)
    end
    local name = staggerNameFor(weaponId)
    local asset = montageByName(name)
    local dur = asset and valid(p1) and playOn(p1, asset)
    sec = sec or STG.sec()
    STG.name, STG.at, STG.dur = dur and name or nil, tn, dur or nil
    STG.untilT = tn + sec              -- §228 播不出动作也照样锁（锁的是输入，不靠动作）
    local how
    if STG.uiBusy and STG.uiBusy() then
        how = "面板 / 输入框开着，输入本来就不进游戏，不另外关"
    else
        local ok, err = G.gameInputBlock(true)
        STG.locked = ok and true or false
        how = ok and "已关输入" or ("!! 关输入失败（" .. tostring(err) .. "），只靠事后取消")
    end
    return string.format("硬直 %s（武器 %s，触发招 %s%s）%s，%.2f 秒内%s", name, tostring(weaponId), tostring(atkName),
        STG.isRanged(atkName) and "，远程" or "",
        dur and string.format("已播（动作 %.2f 秒）", dur) or "动作没播出来", sec, how)
end
-- §228 到时间 / 离开交手 / 换世界后：开回输入（失败就下一帧再试），清掉按着的键
function STG.unlock(p1, why)
    STG.untilT = nil
    if not STG.locked then return end
    local ok, err
    if STG.restoreInput then ok, err = pcall(STG.restoreInput) else ok, err = G.gameInputBlock(false) end
    if not ok then
        STG.failN = (STG.failN or 0) + 1
        if STG.failN <= 3 then out("!! 硬直结束（%s）开回输入失败：%s，下一帧再试", why, tostring(err)) end
        return
    end
    STG.locked, STG.failN = false, nil
    local fl = valid(p1) and G.flushInput(p1) or "没有角色，没清"
    out("硬直结束（%s）：输入已开回；%s；%s", why, tostring(fl), tostring(G.inputFlushMsg and G.inputFlushMsg() or "-"))     -- §276 清按着的键
end
-- §228 每帧（onTick，玩家角色可用时）：锁着输入但已经不在硬直里 → 开回
function STG.frame(p1, tn)
    if not STG.locked then
        if STG.untilT and not STG.active(tn) then STG.untilT = nil end
        return
    end
    if STG.active(tn) then return end
    STG.unlock(p1, NET.fighting() and "到时间" or "离开交手")
end
-- 换世界：只记下"要开回"，不碰游戏对象（M4.forgetWorld 的规矩）；下一次 STG.frame 开回
function STG.forget() STG.untilT = nil end
-- netSend 看到我新出现的技能时调：拦了返回 true（调用方不发这招）
function STG.check(p1, name, tn)
    if not (STG.active(tn) and isAttackAbility(name)) then return false end
    if SHIELD.is(name) then return false end                 -- §302 举盾不取消
    if STG.locked then
        STG.leak = STG.leak + 1
        if STG.leak <= 5 then out("!! 关着输入还是出招了：%s（第 %d 次；多半是关输入之前已经按下的），照旧取消", name, STG.leak) end
    end
    local gone = G.cancelAbilities(p1, SHIELD.cancelable)
    local m = montageOf(p1)
    local back = ""
    if m ~= STG.name and not LO.isHitMontage(m) and STG.name and (not STG.dur or tn - STG.at < STG.dur) then
        local asset = montageByName(STG.name)
        local ok = asset and playOn(p1, asset)
        if ok then G.montageSetPos(p1, tn - STG.at) end
        back = ok and string.format("，硬直从 %.2f 秒处重播", tn - STG.at) or "，硬直重播失败"
    end
    STG.n = STG.n + 1
    if STG.n <= STG.LOGS or STG.n % 20 == 0 then
        out("硬直中出招：%s → %s%s（第 %d 次）", name, #gone > 0 and ("已取消 " .. table.concat(gone, ",")) or "没取消到实例",
            back, STG.n)
    end
    return true
end

-- ============================================================ §423 精防掉对面杀气（房间设置 pdsh，默认关）
-- 每台电脑只改自己身上的：我的招被对方精防（applyRemoteResult 收到 parry）→ 扣我的；对手是本地 AI 时 AI 杀气按替身（§353），我精防它 → 扣替身的。
-- 同一招（攻击编号）只扣一次（多段招每段都可能回报精防）。杀气不够扣到 0。走游戏改属性函数（DCD.setSh = AttributeUtils，§113.1），
-- 扣我自己的计进 DCD.debit，免得"切武器保持杀气"把这一下当成跳变
PDSH = { LOGS = 30, logs = 0, n = 0, done = {}, DEF = 100, CAP = 1000 }
function PDSH.on() return NET.flagNow("pdsh") and NET.fighting() end
function PDSH.amt()        -- §423.1 房间设置档位：对局中按开局定下的，对局外按房间设置（客机 = 主机的）
    local v = MATCH.res and MATCH.res.pdshv
    if not NET.resValid("pdshv", v) then v = NET.resOf("pdshv") end
    v = tonumber(v) or PDSH.DEF
    return math.floor(math.max(0, math.min(PDSH.CAP, v)))
end
function PDSH.drain(actor, side, atkId, mine)
    if not PDSH.on() or not valid(actor) then return end
    local key = side .. ":" .. tostring(atkId)
    if atkId ~= nil and PDSH.done[key] then return end
    local cost = PDSH.amt()
    if cost <= 0 then return end
    local sh = attrOf(actor, "Shachi")
    if not sh then return end
    if atkId ~= nil then
        PDSH.n = PDSH.n + 1
        if PDSH.n % 200 == 0 then PDSH.done = {} end     -- 别越攒越多
        PDSH.done[key] = true
    end
    local new = math.max(0, sh - cost)
    local ok, msg = true, nil
    if new < sh then ok, msg = DCD.setSh(actor, new) end
    if ok and mine then DCD.debit = (DCD.debit or 0) + (sh - new) end
    if PDSH.logs < PDSH.LOGS or not ok then
        PDSH.logs = PDSH.logs + 1
        out("§423 精防掉杀气：%s #%s → %s杀气 %.0f → %.0f（扣 %d）%s", mine and "我的招被精防" or "我精防了本地 AI", tostring(atkId),
            mine and "我" or "替身", sh, ok and new or sh, cost, ok and "" or ("，!! 没写进去：" .. tostring(msg)))
    end
end

-- ============================================================ §173.7 倒计时只能移动、不能出招
-- 找过游戏自带的"禁攻击"（HANDOVER §173.7）：玩家攻击技能都继承 BP_ActionAbilityBase（技能标签 Ability.Action），但没有哪个 GE 用
-- BlockAbilityTagsGameplayEffectComponent（3068 个 GE_ 全扫过），ASC.BlockAbilitiesWithTags 不是蓝图函数、Lua 调不到；对话的
-- GE_StartDialogue 只给 CharacterState.NarrativeDialogue，攻击技能的资产里没有引用它。所以走 §161 那条已实测的路：
-- 倒计时里我身上新出现的攻击技能（isAttackAbility，含影之武装、大招、完美闪避反击）→ 立刻 K2_CancelAbility、不发给对方。
-- 不拦：移动 / 跳跃 / 闪避冲刺（Dash 类、Dodge）/ 架势格挡 / 喝药 / 切武器。状态一离开 cd 就不拦，没有要撤的东西（掉线 / 中止也一样）。
-- 大招 / 影之武装放出来的那一下可能已经扣了精纯杀气 / 暗源：倒计时开始记下，拦掉后少了就写回去
CDL = { n = 0, pn = 0, LOGS = 20, res = nil }
function CDL.active()
    if MATCH.role ~= nil and MATCH.state == "cd" then return true end
    -- §307 D4：新版 1v1 对决里我是选手、对决状态是 cd 时同样禁出招
    local sm = BASEHOOK.mp
    if sm and sm.duelInfo then
        local d = sm.duelInfo()
        if d and d.fighter and d.state == "cd" then return true end
    end
    if sm and sm.cdActive and sm.cdActive() then return true end     -- 11-17 单局淘汰 / 积分赛倒计时
    return false
end
function CDL.snap(p1)
    CDL.res = { UltimateChargeCount = attrOf(p1, "UltimateChargeCount"), UltimateCharge = attrOf(p1, "UltimateCharge"),
                SpiritShadow = attrOf(p1, "SpiritShadow") }
end
-- §173.12 读秒里按下的攻击被游戏缓冲住、开打一瞬间放出来（11-09 实测：12:27:44–47 读秒里按的重击，开打后 12:27:48 放出）。
-- 用户："开打时清掉"。① 开打那一刻 G.flushInput（输入组件 HoldingInputs 清空 + 试几个清缓冲函数；FlushPressedKeys 不是 UFUNCTION 调不到，§173.14）；
-- ② 兜底：读秒里看到过按着的输入（每帧读 HoldingInputs 记下）→ 开打后 POST_SEC 秒内激活的攻击照读秒那样拦；
--    开打那一刻还按着的键（多半是蓄力重击）一直按到松手前（最多 HOLD_MAX 秒）激活的攻击也拦。开打后新按的照常放
CDL.POST_SEC, CDL.HOLD_MAX = 0.3, 2.0
CDL.seen, CDL.stale, CDL.fightAt = {}, nil, nil
-- 读秒里每帧：记下按着的输入
function CDL.sample(p1)
    local h = G.holdingInputs(p1)
    for k in pairs(h or {}) do CDL.seen[k] = true end
end
-- 开打那一刻（RT.fightStart）：记下还按着的、清输入
function CDL.onFight(p1, tn)
    CDL.fightAt = tn
    local h = G.holdingInputs(p1)
    CDL.stale = nil
    for k in pairs(h or {}) do CDL.stale = CDL.stale or {}; CDL.stale[k] = true end
    local any = next(CDL.seen) ~= nil
    out("开打清输入：读秒里按过 %s；开打时还按着 %s；%s", any and "有" or "没有", CDL.stale and "有" or "没有", G.flushInput(p1))
    if not any then CDL.fightAt = nil end           -- 读秒里没按过东西，开打后不用拦
    CDL.seen = {}
end
-- 开打后这一刻还算"读秒里按的"吗
function CDL.postActive(p1, tn)
    local fighting = NET.fighting and NET.fighting() or (MATCH.state == "fight")
    if not (CDL.fightAt and fighting) then return false end
    local dt = tn - CDL.fightAt
    if dt < 0 or dt > CDL.HOLD_MAX then CDL.fightAt, CDL.stale = nil, nil; return false end
    if dt <= CDL.POST_SEC then return true end
    if CDL.stale then
        local h = G.holdingInputs(p1) or {}
        for k in pairs(CDL.stale) do if h[k] then return true end end
        CDL.stale = nil                              -- 全松开了：之后新按的照常放
    end
    return false
end
-- netSend 看到我新出现的技能时调：拦了返回 true（调用方不发这招）
function CDL.check(p1, name, tn)
    if not ((CDL.active() or CDL.postActive(p1, tn)) and isAttackAbility(name)) then return false end
    if SHIELD.is(name) then return false end                 -- §302 举盾不取消（取消会跳过收盾，盾和挡伤留在身上）
    local gone = G.cancelAbilities(p1, SHIELD.cancelable)
    local back = {}
    for a, v in pairs(CDL.res or {}) do
        local c = attrOf(p1, a)
        if v and c and c < v - 0.01 then NET.resWrite(p1, a, v); back[#back + 1] = string.format("%s %.1f→%.1f", a, c, v) end
    end
    CDL.n = CDL.n + 1
    if CDL.n <= CDL.LOGS or CDL.n % 20 == 0 then
        out("%s：%s → %s%s（第 %d 次）", CDL.active() and "倒计时不能出招" or "读秒里按的攻击开打后不放", name, #gone > 0 and ("已取消 " .. table.concat(gone, ",")) or "没取消到实例",
            #back > 0 and ("，资源写回 " .. table.concat(back, "，")) or "", CDL.n)
    end
    return true
end
-- 替身：倒计时里对方发来的攻击（对方是旧版 / 本地 AI 时会有）不放，回报落空
function CDL.puppet(e, tn)
    if not (CDL.active() and isAttackAbility(e.name)) then return false end
    CDL.pn = CDL.pn + 1
    if CDL.pn <= CDL.LOGS then out("倒计时里对方出招 远端#%d %s：替身不放（第 %d 次）", e.id, e.name, CDL.pn) end
    return true
end

-- ============================================================ §302 拙壁盾"带过一次，盾和挡伤效果一直在"（内测反馈 11-14）
-- 拙壁盾举盾 GA_ZhuoBiDun 是按住类：举起时给自己挂 GE_ZhuoBiDun_Blocker（CharacterState.AbilityState.ZhuoBiDun.FromBlocker 标签，
-- 被动 GA_ZhuoBiDun_Passive 看这个标签挡伤）和 GE_InZhuoBiDunLocomotion（举盾走路），松手播收盾动作再收掉。
-- isAttackAbility 把它算影之武装攻击招，读秒禁攻（CDL，§173.7 / §173.12）和精防硬直兜底（STG，§161 / §228）会直接 K2_CancelAbility，
-- 跳过收盾 → 怀疑这就是盾和挡伤留在身上、换了影之武装也不走的来源（游戏里没复现过）。修法：
--   ① 举盾不取消（不在这两处拦、别的招触发取消时也不连带它；举盾本身是防守，读秒里举着不伤人，对方替身读秒里本来也不放）
--   ② 兜底清理：本机 / 替身换下拙壁盾、每回合倒计时开始时，身上没在举盾却还挂着这几个 GE → 摘掉（RemoveActiveGameplayEffectBySourceEffect），记日志
SHIELD = { ABIL = { GA_ZhuoBiDun_C = true }, n = 0, LOGS = 30,
           GE = { "/PBZCombatAsset/ActorData/Players/Hun/Abilities/ShachiAbility/ZhuoBiDun/GE/GE_ZhuoBiDun_Blocker.GE_ZhuoBiDun_Blocker_C",
                  "/PBZCombatAsset/ActorData/Players/Hun/Abilities/ShachiAbility/ZhuoBiDun/GE/GE_InZhuoBiDunLocomotion.GE_InZhuoBiDunLocomotion_C",
                  "/PBZCombatAsset/ActorData/Players/Hun/Abilities/ShachiAbility/ZhuoBiDun/GE/GE_ZhuoBiDun_BlockFire.GE_ZhuoBiDun_BlockFire_C" } }
function SHIELD.is(n) return SHIELD.ABIL[n] == true end
function SHIELD.cancelable(n) return isAttackAbility(n) and not SHIELD.is(n) end     -- CDL / STG 取消时用：举盾不连带
function SHIELD.isCfg(path) return type(path) == "string" and path:find("ZhuoBiDun", 1, true) ~= nil end
-- 没在举盾却还挂着盾的 GE → 摘掉。只在事件上调（换下拙壁盾、回合倒计时），不轮询
function SHIELD.sweep(actor, why)
    if not valid(actor) then return end
    local okA, act = pcall(activeAbilities, actor)
    if okA and type(act) == "table" then
        for n in pairs(act) do if SHIELD.is(n) then return end end      -- 正举着：让它自己收
    end
    local have = G.geSet(actor)
    if not have then return end
    local gone = {}
    for _, path in ipairs(SHIELD.GE) do
        local short = path:match("/([%w_]+)%.[^/]*$")
        if have[short] and LO.removeGE(actor, path, nil) then gone[#gone + 1] = short end
    end
    if #gone == 0 then return end
    SHIELD.n = SHIELD.n + 1
    if SHIELD.n <= SHIELD.LOGS then
        out("§302 拙壁盾残留（%s，%s）：没在举盾却还挂着 %s → 已摘（第 %d 次）", why, pathOf(actor) == pathOf(getP1()) and "我" or "替身",
            table.concat(gone, " "), SHIELD.n)
    end
end
-- 本机换影之武装：发 wge= 时顺手看手上那件（LO.encodeWge 调），从拙壁盾换走就清一次
function SHIELD.watchMine(p1)
    local held = LO.heldConfig(p1, LO.slotShachi())
    if held == nil then return end
    if SHIELD.isCfg(SHIELD.mine) and not SHIELD.isCfg(held) then SHIELD.sweep(p1, "我换下拙壁盾") end
    SHIELD.mine = held
end

-- ------------------------------------------------------------ 11-23 举盾在对方视角撑不住（用户"对面的拿盾牌没能在本地正常显示"）
-- 日志 15:20:07 / 15:20:31 / 15:21:08：替身放出 GA_ZhuoBiDun_C，0.71 秒就播收盾 Exit、1.5–2.2 秒技能结束（盾跟着收），
-- 对方实际举了 15 / 34 秒。原因同 §140：替身没有输入组件，技能里 IsHolding 一开始就是 false。§407 兜底每 1.2 秒重播举盾动作，
-- 画面是"举一下放一下"、手里没盾，9 秒后什么都不补。
-- 做法（只补画面，不碰技能逻辑 / 判定 / 伤害）：替身一进收盾动作，就拉回收盾第一帧暂停——技能要等收盾播完才结束，
-- 盾和技能就一直留着；对方松手（rel=）/ 放了下一招 / 超过 HOLD_MAX 秒 → 继续播收盾，技能照常收掉。
-- 暂停的动作被闪避 / 受击打断、技能已经没了 → 只补姿势：重播举盾，举到位停住（盾不一定在手上，日志里写清楚）
SHIELD.HOLD_MAX, SHIELD.ENTRY_HOLD, SHIELD.RETRY, SHIELD.HLOGS = 45.0, 0.35, 1.0, 40
SHIELD.ENTRY = "Hun_ShaChi_ZhuoBiDun_Entry_Montage"
SHIELD.hold, SHIELD.hn, SHIELD.lastId = {}, 0, {}
function SHIELD.key(pup) local ok, p = pcall(pathOf, pup); return ok and p or tostring(pup) end
function SHIELD.hlog(fmt, ...)
    SHIELD.hn = SHIELD.hn + 1
    if SHIELD.hn <= SHIELD.HLOGS then out(fmt, ...) end
end
function SHIELD.isExit(m) return type(m) == "string" and m:find("ZhuoBiDun_Exit", 1, true) ~= nil end
function SHIELD.isEntry(m) return type(m) == "string" and m:find("ZhuoBiDun_Entry", 1, true) ~= nil end
function SHIELD.fighting() return (NET and NET.fighting and NET.fighting()) and true or false end
-- 替身放出对方的举盾（CHG.onFire 调）
function SHIELD.onFire(pup, e, tn)
    if not (e and e.id and SHIELD.is(e.name)) then return end
    SHIELD.hold[e.id] = { id = e.id, name = e.name, at = tn, pup = pup, entryN = 0, fight = SHIELD.fighting() }
    SHIELD.hold[e.id - 300] = nil
    SHIELD.lastId[SHIELD.key(pup)] = e.id     -- 盾反 / 盾推 / 盾冲的判定窗口记在这一招上（多人房按替身分开）
    local f = CHG and CHG.fired and CHG.fired[e.id]
    if f then f.spin = nil end          -- 不走 §407 续转（它每 1.2 秒重播举盾，会和这里的暂停打架）
end
-- 对方不再举着的原因；还举着返回 nil
function SHIELD.stopWhy(h, tn)
    local secs = CHG and CHG.rel and CHG.rel[h.id]
    if secs and tn >= h.at + secs then return string.format("对方松手（按了 %.2f 秒）", secs) end
    local nf = CHG and CHG.movedOn and CHG.movedOn(h.pup, h.id, h)
    if nf then return string.format("对方放了下一招 远端#%d %s", nf.id, nf.name) end
    if tn - h.at >= SHIELD.HOLD_MAX then return string.format("举了超过 %.0f 秒", SHIELD.HOLD_MAX) end
    local fz = SHIELD.fighting()
    if fz ~= h.fight then return fz and "回合开打" or "交手结束" end      -- 回合切换不把举盾带过去
    return nil
end
-- 多人房每个对手一份 CHG（PEER.run 里驱动），这里只看当前这个替身的记录（CHG.rel / movedOn 是它那份）
function SHIELD.holdStep(tn)
    local cur = puppet()
    for id, h in pairs(SHIELD.hold) do
        if valid(h.pup) and cur ~= nil and not sameObj(h.pup, cur) then
            -- 别的对手的举盾：等驱动它那一份时再看
        elseif valid(h.pup) then
            local ok, err = pcall(SHIELD.holdOne, h, tn)
            if not ok then SHIELD.hold[id] = nil; SHIELD.hlog("举盾保持出错（远端#%d）：%s", id, tostring(err)) end
        else
            SHIELD.hold[id] = nil
        end
    end
end
function SHIELD.holdOne(h, tn)
    local pup = h.pup
    local _, _, m, pos = LAT.activeMontage(pup)
    m = m or ""
    local stop = SHIELD.stopWhy(h, tn)
    if stop then
        SHIELD.hold[h.id] = nil
        -- §439 替身按着的影武键松开（rel= 到点时 pupStep 已经松过，这里只管下一招 / 超时 / 回合切换；没按着的什么都不做）
        if INP and INP.done then INP.done(h.id, stop) end
        local resumed = false
        if h.paused and m == h.pausedM then resumed = G.montagePause(pup, false) and true or false end
        SHIELD.hlog("举盾保持：远端#%d %s，替身停了 %.2f 秒%s", h.id, stop, (h.pausedSum or 0) + (h.paused and (tn - h.pausedAt) or 0),
            h.paused and (m == h.pausedM and (resumed and "，继续播 " .. m or "，继续播失败") or ("，暂停的动作已换成 " .. (m ~= "" and m or "（没动作）"))) or "")
        return
    end
    if h.paused then
        if m ~= h.pausedM then           -- 被闪避 / 受击 / 别的动作打断
            h.paused = false
            h.pausedSum = (h.pausedSum or 0) + (tn - h.pausedAt)
            SHIELD.hlog("举盾保持：远端#%d 停住的 %s 被 %s 打断（放出后 %.2f 秒）", h.id, h.pausedM, m ~= "" and m or "（没动作）", tn - h.at)
        end
        return
    end
    if SHIELD.isExit(m) then
        -- 替身自己松手了：拉回收盾第一帧停住
        local okP = G.montageSetPos(pup, 0)
        local ok = G.montagePause(pup, true)
        local alive = LO.activeInstance and LO.activeInstance(pup, h.name) and true or false
        if ok then h.paused, h.pausedM, h.pausedAt = true, m, tn end
        SHIELD.hlog("举盾保持：远端#%d 替身进了收盾（放出后 %.2f 秒，位置 %.2f）→ 拉回第一帧%s、暂停%s；技能%s", h.id, tn - h.at,
            pos or -1, okP and "成功" or "失败", ok and "成功" or "失败", alive and "还在（盾留着）" or "已经没了")
        return
    end
    if SHIELD.isEntry(m) and h.entryAt then
        -- 只补姿势：重播的举盾动作举到位就停住
        if tn - h.entryAt >= SHIELD.ENTRY_HOLD then
            h.entryAt = nil
            local ok = G.montagePause(pup, true)
            if ok then h.paused, h.pausedM, h.pausedAt = true, m, tn end
            SHIELD.hlog("举盾保持：远端#%d 替身技能已经没了 → 重播举盾停在 %.2f（暂停%s，第 %d 次；盾可能不在手上）", h.id, pos or -1,
                ok and "成功" or "失败", h.entryN)
        end
        return
    end
    if m == "" and tn - h.at > 0.5 and tn >= (h.retryAt or 0) then
        h.retryAt = tn + SHIELD.RETRY
        -- 11-26 §458 §439 起替身按着影武键、举盾技能一直在：举到位后游戏用举盾走路姿势（GE_InZhuoBiDunLocomotion）撑着，
        -- 本来就没有蒙太奇。以前这里把"没动作"当成技能没了，重播举盾停在 0.37 → 盖掉游戏自己的举盾姿势、盾不在手上
        -- （18:39:15 / 18:40:02 / 18:40:37 三次，蓄力探针同时段技能都还在）。技能还在就不补
        if LO.activeInstance and LO.activeInstance(pup, h.name) then
            if not h.liveLogged then
                h.liveLogged = true
                SHIELD.hlog("举盾保持：远端#%d 举到位没有动作、技能还在（游戏自己的举盾姿势）→ 不补", h.id)
            end
            return
        end
        if playNamed(pup, SHIELD.ENTRY) then h.entryAt, h.entryN = tn, h.entryN + 1 end
    end
end

-- ------------------------------------------------------------ 11-23 盾反 / 盾推 / 盾冲（举盾技能里面按键出的招）
-- 这三招都是 GA_ZhuoBiDun 自己的时间线（运行时导出 PBZ_GasDump/actions_byclass.jsonl）：
--   CounterAttack(_02) 播 Hun_ZhuoBi_SpecialAttack_01_A_Montage + 判定 BD_ZhuoBiDun_CounterAttack_KnockBack（_02 = 双重反击升级，数值一样）
--   Push_F 播 Hun_ShaChi_ZhuoBiDun_Skill_01_Montage + BD_ZhuoBiDun_Push_Body_Small、BD_ZhuoBiDun_KnockBack
--   Rush_F 播 Hun_ShaChi_ZhuoBiDun_Skill_02_Montage + BD_ZhuoBiDun_Rush_Body_Small ×5、BD_ZhuoBiDun_Rush_Finish
-- 不是新技能、也不是闪避 / 受击动作，以前对方那边根本不发。现在：
--   发：举盾中动作换成这三个之一 → 走 sub=（§111 技能内动作同一个字段）
--   收：替身照播动作 + 按下面的时间用替身的举盾技能生成判定（§229.5 红光直接播同一套 G.laserEmitterSpawn），
--       每个判定开一个判定窗口（记在对方举盾那一招的编号上），伤害系数按拙壁盾（BAL.onFire）。
--   判定时间是按时间线的前摇估的（资产里没有开始时间），实测看"盾反判定"日志再调
SHIELD.BD = "/PBZCombatAsset/ActorData/Players/Hun/BulletData/ShachiWeapon/ZhuoBiDun/"
function SHIELD.bd(n) return SHIELD.BD .. n .. "." .. n end
SHIELD.SUB = {
    Hun_ZhuoBi_SpecialAttack_01_A_Montage = { what = "盾反", bul = { { 0.30, "BD_ZhuoBiDun_CounterAttack_KnockBack" } } },
    Hun_ShaChi_ZhuoBiDun_Skill_01_Montage = { what = "盾推", bul = { { 0.18, "BD_ZhuoBiDun_Push_Body_Small" }, { 0.30, "BD_ZhuoBiDun_KnockBack" } } },
    Hun_ShaChi_ZhuoBiDun_Skill_02_Montage = { what = "盾冲", bul = { { 0.18, "BD_ZhuoBiDun_Rush_Body_Small" }, { 0.52, "BD_ZhuoBiDun_Rush_Body_Small" },
        { 0.86, "BD_ZhuoBiDun_Rush_Body_Small" }, { 1.20, "BD_ZhuoBiDun_Rush_Body_Small" }, { 1.54, "BD_ZhuoBiDun_Rush_Body_Small" },
        { 1.90, "BD_ZhuoBiDun_Rush_Finish" } } },
}
SHIELD.FWD, SHIELD.GAP, SHIELD.AIM_Z, SHIELD.SLOGS = 100.0, 40.0, 80.0, 40
SHIELD.pend, SHIELD.sn, SHIELD.subN = {}, 0, 0
function SHIELD.isSub(m) return type(m) == "string" and SHIELD.SUB[m] ~= nil end
function SHIELD.slog(fmt, ...)
    SHIELD.sn = SHIELD.sn + 1
    if SHIELD.sn <= SHIELD.SLOGS then out(fmt, ...) end
end
-- 发送方：netSend 看到我的动作换成新的一个时调；是这三招之一返回 true（调用方发 sub=）
function SHIELD.mineSub(hm, prev)
    return hm ~= prev and SHIELD.isSub(hm)
end
-- 11-24 盾反判定时间：资产 GA_ZhuoBiDun CounterAttack 的 LGAAction_DurationBulletWithDeflect PreHitPointDuration = 0.3（和 SUB 表一致），
-- 但那是从对方播动作算起；这边收到 sub= 时已经晚了一个包龄（日志"包龄中位 67–116 ms"），以前再从收到起等满 0.30 秒。
-- 现在判定提前包龄（最多 AGE_MAX），动作也往后跳同样的秒数，判定和对方屏幕上的出手对齐。没有时间戳（旧版对方）= 不补
SHIELD.AGE_MAX, SHIELD.AGE_MIN_LEAD = 0.20, 0.03
-- 收：对方 sub= 是这三招之一（NET.recvOne 调）。age = 这一包的包龄（秒，没有 = nil）
-- （SHIELD.onContact 在下面"每帧"那段前；它返回 true 时 PRED.onContact 返回 false，由 suppressLocalReact 照旧掐掉本机受击）
function SHIELD.onSub(p1, pup, sm, tn, age)
    local sc = SHIELD.SUB[sm]
    if not (sc and valid(pup)) then return end
    SHIELD.subN = SHIELD.subN + 1
    SHIELD.subAt[SHIELD.key(pup)] = tn          -- §455 对方真的出了盾反 / 盾推 / 盾冲：这段时间替身身上的同名动作是真的
    local id = SHIELD.lastId[SHIELD.key(pup)] or 0
    montageByName(sm, true)
    pcall(G.facePlayer, pup)
    local okP = playNamed(pup, sm)
    local lag = (type(age) == "number" and age > 0) and math.min(age, SHIELD.AGE_MAX) or 0
    if okP and lag > 0 then pcall(LAT.setPos, pup, lag) end
    local f = CHG and CHG.fired and CHG.fired[id]
    if f and f.mon then f.mon[sm] = true end
    -- 读秒里不出伤害：只播动作（多人房 / 观战照常生成，和替身放别的招一样；判定窗口 openJudge 自己看 PEER.on）
    local why = (CDL and CDL.active and CDL.active()) and "读秒里不出伤害" or nil
    if not why and BAL and BAL.onFire and BAL.onFire("GA_ZhuoBiDun_C", tn) and LO.rescale then LO.rescale(pup, tn) end
    if not why then
        for i, b in ipairs(sc.bul) do
            local d = math.max(SHIELD.AGE_MIN_LEAD, b[1] - lag)
            SHIELD.pend[#SHIELD.pend + 1] = { t = tn + d, bd = b[2], pup = pup, id = id, n = i, total = #sc.bul, what = sc.what, t0 = tn }
        end
    end
    SHIELD.slog("盾反同步：对方%s %s → 替身%s；%s（记在远端#%d 上；包龄 %s，判定提前 %.2f 秒）", sc.what, sm, okP and "已播" or "播放失败",
        why or string.format("排了 %d 个判定", #sc.bul), id, type(age) == "number" and string.format("%.0f ms", age * 1000) or "不知道", lag)
end
-- 到点生成判定
function SHIELD.subStep(tn)
    if #SHIELD.pend == 0 then return end
    local keep, p1 = {}, getP1()
    for _, q in ipairs(SHIELD.pend) do
        if tn < q.t then keep[#keep + 1] = q
        elseif valid(q.pup) then
            local ok, err = pcall(SHIELD.spawnOne, p1, q, tn)
            if not ok then SHIELD.slog("  盾反判定 %s 出错：%s", q.bd, tostring(err)) end
        end
    end
    SHIELD.pend = keep
end
function SHIELD.spawnOne(p1, q, tn)
    local bd = G.findOrLoad and G.findOrLoad(SHIELD.bd(q.bd)) or nil
    local okL, l = pcall(function() return q.pup:K2_GetActorLocation() end)
    local okP, pl = false, nil
    if valid(p1) then okP, pl = pcall(function() return p1:K2_GetActorLocation() end) end
    local src, srcWay = nil, "没有技能对象"
    if DIAG and DIAG.PDX then src, srcWay = DIAG.PDX.src(q.pup, "GA_ZhuoBiDun_C") end
    local at, yaw, pitch, dist = nil, yawOf(q.pup) or 0.0, 0.0, nil
    if okL and l then
        if okP and pl then
            local dx, dy = pl.X - l.X, pl.Y - l.Y
            dist = math.sqrt(dx * dx + dy * dy)
            local adv = math.min(SHIELD.FWD, math.max(0.0, dist - SHIELD.GAP))
            local ux, uy = (dist > 1e-3) and dx / dist or math.cos(math.rad(yaw)), (dist > 1e-3) and dy / dist or math.sin(math.rad(yaw))
            at = { X = l.X + ux * adv, Y = l.Y + uy * adv, Z = pl.Z + SHIELD.AIM_Z }
            yaw = math.deg(math.atan(uy, ux))
        else
            local r = math.rad(yaw)
            at = { X = l.X + math.cos(r) * SHIELD.FWD, Y = l.Y + math.sin(r) * SHIELD.FWD, Z = l.Z + SHIELD.AIM_Z }
        end
    end
    local em, how
    if bd and at then
        local okS, a, b2 = pcall(G.laserEmitterSpawn, src, q.pup, at, { Pitch = pitch, Yaw = yaw, Roll = 0.0 }, bd)
        if okS then em, how = a, b2 else how = "出错 " .. tostring(a) end
    else
        how = bd and "读不到替身位置" or "找不到判定数据"
    end
    if em and q.id > 0 then openJudge(p1, q.id, tn, "GA_ZhuoBiDun_C") end
    SHIELD.slog("  盾反判定 %s（%s 第 %d/%d 个，+%.2f 秒）：%s（%s；来源 %s；距离 %s）", q.bd, q.what, q.n, q.total, tn - q.t0,
        em and "生成了" or "没生成", tostring(how), tostring(srcWay), dist and string.format("%.0f", dist) or "?")
end
-- 11-24 我的刀在本机碰到举着盾的替身（PRED.onContact 最先问）：对方那边是盾挡住（本机 14:08:06–09 替身停在收盾帧时，
-- 我的木剑连击被预测成"对方没在格挡 → 留着本机受击"，替身一直播 Hit_*、举盾被打断、技能没了；对方本机同一段是盾挡掉、
-- 杀气 -33 / -30 …，4 秒后盾反）。对方举着盾时不留本机受击（这里返回 true → PRED.onContact 返回 false → 照旧掐掉），并让举盾保持马上重摆举盾姿势
-- （不等 RETRY）。对方真被打断时 hr= 会照常让替身播受击，不受影响
SHIELD.cn = 0
function SHIELD.holdingFor(pup)
    for _, h in pairs(SHIELD.hold) do
        if valid(h.pup) and sameObj(h.pup, pup) then return h end
    end
    return nil
end
function SHIELD.onContact(pup, tn)
    if not next(SHIELD.hold) then return false end
    local h = SHIELD.holdingFor(pup)
    if not h or SHIELD.stopWhy(h, tn) then return false end
    h.retryAt = 0
    SHIELD.cn = SHIELD.cn + 1
    if SHIELD.cn <= 20 or SHIELD.cn % 25 == 0 then
        SHIELD.hlog("举盾保持：远端#%d 我的刀在本机碰到举盾的替身 → 不留本机受击，按盾挡住处理（第 %d 次）", h.id, SHIELD.cn)
    end
    return true
end

-- §455 11.25 用户："通常防御情况下触发反击时判定会延迟的非常厉害……盾牌可以反击的瞬间多了一次伤害判定"。
-- 11-25 收方日志 14:35：对方 14:35:04 举盾、按了 9.86 秒、14:35:14 松手才盾反（sub= 到了，-314）；可我这边 14:35:06 / 19 / 30 / 59
-- 替身挡住我的木剑后自己就盾反了（判定 BD_ZhuoBiDun_CounterAttack_KnockBack -314 + 双重反击 _02 -42，前面没有任何"盾反同步"）。
-- 举盾技能 GA_ZhuoBiDun 格挡后看影武键还按没按着（IsHolding / OnRelease），替身没按着 = 格挡完马上"松手反击"。
-- 盾反由对方决定（他松手才有）：替身举盾期间，替身播着盾反动作、对方 GUARD_WIN 秒内没发过盾反 sub= → 这一帧我掉的血补回来。
-- 判法只看替身动作 + 我掉血，不读载荷（便宜）；本地 AI（NET.rai）不管（AI 不发 sub=）。net/shield_guard_off.txt 关
SHIELD.subAt, SHIELD.CTR_M, SHIELD.GUARD_WIN, SHIELD.GUARD_SEEN, SHIELD.GUARD_MIN = {}, { Hun_ZhuoBi_SpecialAttack_01_A_Montage = true }, 1.5, 1.2, 5.0
SHIELD.gn, SHIELD.GUARD_OFF = 0, (NET_DIR or "net") .. "/shield_guard_off.txt"
function SHIELD.guardOff()
    if SHIELD.guardOffC ~= nil then return SHIELD.guardOffC end
    local f = io.open(SHIELD.GUARD_OFF, "r")
    SHIELD.guardOffC = f ~= nil
    if f then f:close() end
    return SHIELD.guardOffC
end
function SHIELD.guard(p1, pup, tn)
    local hp = attrOf(p1, "Health")
    local prev = SHIELD.ghp
    SHIELD.ghp = hp
    if NET.rai or not (next(SHIELD.hold) or (SHIELD.fakeAt and tn - SHIELD.fakeAt <= SHIELD.GUARD_SEEN)) then return end
    if not valid(pup) or SHIELD.guardOff() then return end
    local key = SHIELD.key(pup)
    local sub = SHIELD.subAt[key]
    local legit = sub and tn - sub <= SHIELD.GUARD_WIN
    local okM, _, _, m = pcall(LAT.activeMontage, pup)
    if okM and SHIELD.CTR_M[m] and not legit then
        if not SHIELD.fakeAt or tn - SHIELD.fakeAt > SHIELD.GUARD_SEEN then
            SHIELD.gn = SHIELD.gn + 1
            if SHIELD.gn <= 30 then out("§455 替身自己盾反了（%s，对方没发盾反）：这一下的伤害不算", m) end
        end
        SHIELD.fakeAt = tn
    end
    if legit or not (SHIELD.fakeAt and tn - SHIELD.fakeAt <= SHIELD.GUARD_SEEN) then return end
    if type(hp) ~= "number" or type(prev) ~= "number" or hp >= prev - SHIELD.GUARD_MIN then return end
    if setAttr(p1, "Health", prev) then
        SHIELD.ghp = prev
        SHIELD.gn = SHIELD.gn + 1
        if SHIELD.gn <= 30 then out("§455 替身自己的盾反打中我 -%.0f → 补回（对方最近一次盾反 %s）", prev - hp,
            sub and string.format("%.1f 秒前", tn - sub) or "没有") end
    end
end

-- §455 11.25 用户：悬浮盾在线第二下没伤害 = 第一下把人击飞、第二下打在倒地无敌上；"请把【悬浮盾】第一击恢复到原版的效果
-- （第一段判定踉跄，第二段判定才会击飞对手）"。资产：BD_ZhuoBiDun_Slide_Small.HitStrength = Hitreact.Strength.Income.Launchback.Light
-- （打怪有韧性兜着是踉跄，打玩家直接击飞：11-25 14:27:32 第一下我播 AM_Hun_Unarmed_LaunchStart_B → LaunchEnd → Getup），
-- _Final = Launchback.Heavy。做法：交手中把 _Small 的受击强度临时改成 WANT（站着后退的踉跄档），离开交手改回原值（资产在内存里，
-- 重启游戏也会恢复）。挨打方那台的资产决定挨打反应，所以两边都要是新版。改不上（这版 UE4SS 写不了结构体字段）日志会写；
-- net/slide_stagger_off.txt 关
SLIDE455 = { PATH = SHIELD.bd("BD_ZhuoBiDun_Slide_Small"), WANT = "Hitreact.Strength.Income.Normal.Knockback.Middle",
             on = false, OFF = (NET_DIR or "net") .. "/slide_stagger_off.txt" }
function SLIDE455.tagOf(bd)
    local ok, s = pcall(function() return bd.HitStrength.TagName:ToString() end)
    return ok and type(s) == "string" and s or nil
end
function SLIDE455.setTag(bd, name)
    pcall(function() bd.HitStrength.TagName = FName(name) end)
    if SLIDE455.tagOf(bd) == name then return true, "改字段" end
    pcall(function() bd.HitStrength = { TagName = FName(name) } end)
    if SLIDE455.tagOf(bd) == name then return true, "整个结构体" end
    return false, "读回是 " .. tostring(SLIDE455.tagOf(bd))
end
function SLIDE455.sync(want)
    want = want and true or false
    if want == SLIDE455.on then return end
    SLIDE455.on = want
    if want then
        local f = io.open(SLIDE455.OFF, "r")
        if f then f:close(); return end
        local bd = G.findOrLoad and G.findOrLoad(SLIDE455.PATH) or nil
        if not valid(bd) then out("§455 悬浮盾第一下改踉跄：找不到 %s", SLIDE455.PATH); return end
        local orig = SLIDE455.tagOf(bd)
        if orig == nil then out("§455 悬浮盾第一下改踉跄：读不到受击强度"); return end
        if orig == SLIDE455.WANT then return end
        local ok, how = SLIDE455.setTag(bd, SLIDE455.WANT)
        if ok then SLIDE455.bd, SLIDE455.orig = bd, orig end
        out("§455 悬浮盾第一下（交手中）受击强度 %s → %s：%s（%s）", orig, SLIDE455.WANT, ok and "改上了" or "没改上", how)
    else
        local bd, orig = SLIDE455.bd, SLIDE455.orig
        SLIDE455.bd, SLIDE455.orig = nil, nil
        if orig and valid(bd) then
            local ok, how = SLIDE455.setTag(bd, orig)
            out("§455 悬浮盾第一下受击强度改回 %s：%s（%s）", orig, ok and "成功" or "失败", how)
        end
    end
end

-- 每帧（CHG.step 调）：举盾保持 + 盾反判定。都空的时候什么都不做
function SHIELD.step(tn)
    if next(SHIELD.hold) then SHIELD.holdStep(tn) end
    if #SHIELD.pend > 0 then SHIELD.subStep(tn) end
end

-- ------------------------------------------------------------ §434 泥头车【力荡四方】（处决键最后一击）在线同步
-- 11-24 两边日志（房主 IGNIZ 开车打客机）：力荡在发送方是马车技能 GA_HorseCart_Charge 里按处决键（IA_Execution 增强输入事件）
-- 出的一招：动作 AM_DriveHorseCart（升级 EnableTurnAttack）+ 判定 BulletData_TurnAttack = BD_NiTouChe_Overlap_TurnAttack，
-- 打木桩那一下 -703（普通冲撞 -469，13:41:11–12）。替身没有玩家控制器，增强输入事件根本收不到，等松手任务在
-- 1.86 秒（CanRelease）自己就下车了（收方 14:01:29 / 37 / 57 三次都是 GetOn → 1.86 秒 JumpOff，没有 DriveHorseCart），
-- 以前也不发 sub= → 收方从来没出过力荡的判定。现在：
--   发：马车里动作换成 AM_DriveHorseCart → sub=（§111 同一个字段；旧版收方不认识，忽略）
--   收：用替身的马车技能实例（没了退技能默认对象）在替身身上生成 BD_NiTouChe_Overlap_TurnAttack（同盾反 G.laserEmitterSpawn），
--       伤害记在这一招马车上（还在累加就走追加命中，不然开判定窗口）；对方下车的 rel= 晚到 KEEP 秒内先不取消替身技能
--   判定位置 / 范围是估的（原版挂在车上），实测看日志"力荡同步"
CART = { GA = "GA_HorseCart_Charge_C", MON = "AM_DriveHorseCart", KEEP = 1.2, LOGS = 30, n = 0,
         BD = "/PBZCombatAsset/ActorData/Players/Hun/BulletData/NiTouChe/BD_NiTouChe_Overlap_TurnAttack.BD_NiTouChe_Overlap_TurnAttack" }
function CART.log(fmt, ...)
    CART.n = CART.n + 1
    if CART.n <= CART.LOGS then out(fmt, ...) end
end
function CART.isSub(m) return m == CART.MON end
CART.CART_MON, CART.CART_KEY = "ShaChi_HorseCart_Armed_Skill01_Montage", "HorseCart"
function CART.spinCart(pup, id)
    local mt = montageByName(CART.CART_MON, true)
    if not mt then CART.log("力荡同步：远端#%d 车的动作 %s 不在内存里（没播）", id, CART.CART_MON); return end
    local comp, how = nil, "没有 G.vehicleMesh"
    if G.vehicleMesh then comp, how = G.vehicleMesh(pup, CART.CART_KEY) end
    if not comp then CART.log("力荡同步：远端#%d 找不到替身的车（%s）", id, tostring(how)); return end
    local len, why = G.playOnMesh(comp, mt)
    CART.log("力荡同步：远端#%d 车播 %s → %s（车：%s）", id, CART.CART_MON,
        len and string.format("成功 %.2f 秒", len) or ("没成 " .. tostring(why)), tostring(how))
    return len
end

-- §442 力荡判定收不掉（11-25 用户"对方放完马车后身上有残留攻击判定，我靠近就被打死了，无论是否在对决里"）：
-- 收方日志 15:59:58 / 16:00:12（结算倒计时里）/ 16:03:18 / 16:04:28 / 16:05:44 都是 -1920.4，马车早结束、对方也没回报，
-- 就是 §434 在替身位置生成的 BD_NiTouChe_Overlap_TurnAttack 一直留在原地（原版判定挂在车上随车收掉，我们生成的没人收）。
-- 现在记下来：车的转圈动作时长（读不到按 1.5 秒，夹在 0.8–3 秒），到点 / 对方下车替身收技能 / 回合清场时销毁
CART.live, CART.LIFE, CART.dn = {}, 1.5, 0
function CART.lifeOf(len)
    if type(len) ~= "number" or len <= 0 then return CART.LIFE end
    return math.max(0.8, math.min(3.0, len))
end
function CART.kill(why, tn)
    for i = #CART.live, 1, -1 do
        local x = CART.live[i]
        local ok = G.destroyActor(x.e)
        CART.dn = CART.dn + 1
        if CART.dn <= 30 then
            out("力荡判定收掉：远端#%d（%s，生成后 %.2f 秒）：%s", x.id, why, (tn or now()) - x.t, ok and "成功" or "已经没了")
        end
        table.remove(CART.live, i)
    end
end
function CART.step(tn)
    for i = #CART.live, 1, -1 do
        local x = CART.live[i]
        if tn - x.t >= x.life then
            local ok = G.destroyActor(x.e)
            CART.dn = CART.dn + 1
            if CART.dn <= 30 then out("力荡判定收掉：远端#%d（到点 %.2f 秒）：%s", x.id, x.life, ok and "成功" or "已经没了") end
            table.remove(CART.live, i)
        end
    end
end
-- §460 马车一趟命中封顶（11-26 用户"马车差点秒杀对方，伤害不对"→"封顶吧"）：19:14:47–50 对方一趟车在我这边撞了 7 下
-- （每下 -374，累计 -2621，满血 3086），19:24:58–19:25:00 我一趟车在对方那边撞了 5 下（-2632）。原版开阔地一次冲撞约 3 下；
-- 多出来的是我被撞飞后车还在推（替身的车比对方晚收约 1 秒、又一路瞬移跟网络位置），每落地一次再撞一下。
-- 挨打方这边：同一个远端招号的马车最多认 RAM 下冲撞 + TURN 下力荡（力荡 = §434 生成的力荡判定还在场时的那一下，
-- 认了就把它收掉，免得打两次）；超出的把血补回去、这一下记 0。按招号记（中途换了判定窗口也接着数），30 秒没动的清掉
CARTCAP = { RAM = 3, TURN = 1, KEEP = 30.0, s = {}, n = 0 }
function CARTCAP.log(fmt, ...)
    CARTCAP.n = CARTCAP.n + 1
    if CARTCAP.n <= 40 then out(fmt, ...) end
end
function CARTCAP.state(id, tn)
    for k, v in pairs(CARTCAP.s) do if tn - v.at > CARTCAP.KEEP then CARTCAP.s[k] = nil end end
    local c = CARTCAP.s[id]
    if not c then c = { ram = 0, turn = 0 }; CARTCAP.s[id] = c end
    c.at = tn
    return c
end
-- 返回 nil = 照常算；返回 0 = 超出封顶，血已补回
function CARTCAP.fix(p1, id, name, step, hpBefore, tn)
    if name ~= CART.GA or id == nil or not hpBefore or not step or step <= 0.5 then return nil end
    local c = CARTCAP.state(id, tn)
    if c.turn < CARTCAP.TURN then
        for i, x in ipairs(CART.live) do
            if x.id == id then
                c.turn = c.turn + 1
                local ok = G.destroyActor(x.e)
                table.remove(CART.live, i)
                CARTCAP.log("§460 马车：远端#%d 这一下 -%.0f 算力荡（第 %d 下），力荡判定收掉：%s", id, step, c.turn, ok and "成功" or "已经没了")
                return nil
            end
        end
    end
    if c.ram < CARTCAP.RAM then c.ram = c.ram + 1; return nil end
    if not setAttr(p1, "Health", hpBefore) then return nil end
    c.over = (c.over or 0) + 1
    CARTCAP.log("§460 马车：远端#%d 已撞 %d 下 + 力荡 %d 下，这一下 -%.0f 超出封顶 → 补回（这趟第 %d 次）", id, c.ram, c.turn, step, c.over)
    return 0
end
-- 回合清场时清记录
function CARTCAP.reset() CARTCAP.s = {} end

-- 发送方：动作刚换成 AM_DriveHorseCart（只有马车里会播）
function CART.mineSub(hm, prev) return hm ~= prev and hm == CART.MON end
-- 收：对方 sub=AM_DriveHorseCart
function CART.onSub(p1, pup, sm, tn)
    if not valid(pup) then return end
    local id, f
    for fid, ff in pairs(CHG and CHG.fired or {}) do
        if ff.name == CART.GA and (not id or fid > id) then id, f = fid, ff end
    end
    if not id then CART.log("力荡同步：对方 %s，但这边没有在开的马车（没生成判定）", sm); return end
    f.turnAt = tn                         -- CHG.vehicleOff 等 KEEP 秒再取消替身技能（判定的来源技能还要用）
    if f.mon then f.mon[sm] = true end
    -- §437 替身照播力荡动作（以前只生成判定，替身没动作）；读秒里也播，只是不出伤害
    montageByName(sm, true)
    local okM = playNamed(pup, sm)
    if not okM then CART.log("力荡同步：远端#%d 替身播 %s 没成", id, sm) end
    -- §441 力荡四方的转圈是车自己的动作 ShaChi_HorseCart_Armed_Skill01_Montage（骨架 HorseCart_Skeleton，马车技能引用），
    -- AM_DriveHorseCart 只是人的驾车姿势（替身本来就在播）→ 11-25 收方 8 次判定都生成了、对方看着没转。给替身的车也播一遍
    local spinLen = CART.spinCart(pup, id)
    if CDL and CDL.active and CDL.active() then CART.log("力荡同步：远端#%d 读秒里不出伤害", id); return end
    if BAL and BAL.onFire and BAL.onFire(CART.GA, tn) and LO.rescale then LO.rescale(pup, tn) end
    local bd = G.findOrLoad and G.findOrLoad(CART.BD) or nil
    local src, srcWay = nil, "没有技能对象"
    if DIAG and DIAG.PDX then src, srcWay = DIAG.PDX.src(pup, CART.GA) end
    local okL, l = pcall(function() return pup:K2_GetActorLocation() end)
    local em, how
    if bd and okL and l then
        local okS, a, b2 = pcall(G.laserEmitterSpawn, src, pup, { X = l.X, Y = l.Y, Z = l.Z }, { Pitch = 0.0, Yaw = yawOf(pup) or 0.0, Roll = 0.0 }, bd)
        if okS then em, how = a, b2 else how = "出错 " .. tostring(a) end
    else
        how = bd and "读不到替身位置" or "找不到判定数据"
    end
    local add = NET.lastHit and NET.lastHit.r and NET.lastHit.r.atk == id
    if em and not add then openJudge(p1, id, tn, CART.GA) end
    if em then CART.live[#CART.live + 1] = { e = em, id = id, t = tn, life = CART.lifeOf(spinLen) } end   -- §442 到点收掉
    local dist
    if valid(p1) and okL and l then
        local okP, pl = pcall(function() return p1:K2_GetActorLocation() end)
        if okP and pl then dist = math.sqrt((pl.X - l.X) ^ 2 + (pl.Y - l.Y) ^ 2) end
    end
    CART.log("力荡同步：远端#%d 对方 %s → %s（%s；来源 %s；离我 %s 厘米；%s）", id, sm, em and "生成了力荡判定" or "没生成",
        tostring(how), tostring(srcWay), dist and string.format("%.0f", dist) or "?", add and "接着这一招追加" or "开判定窗口")
end

-- ------------------------------------------------------------ §430 幻术琵琶【破阵曲】（GA_Hun_Lute_SKill）在线同步
-- 11.23 用户反馈："幻术琵琶全部攻击在线模式下会有极高的延迟判定和不同步的问题，【破阵曲】尤其明显"。
-- 资产（_tools/gasgraph/按住松手招_全表.csv）：GA_Hun_Lute_SKill 是 OnRelease 型（等松手任务），三段动作
--   Start（按下）→ Loop（按住：循环里隔一阵打一发 BD_Hun_Lute_Skill_Red_01(_E)，同时持续扣杀气）→ End（松手：BulletData_Hun_Lute_SKill_01–04 那一轮）。
--   技能放出来后一段时间内（11-24 实测 12 秒）再按影武键 = 同一个技能里再来一轮 Start → End，不是新技能、没有新的 ev=。
-- 11-24 14:15–14:16 两边日志（本机客机发，IGNIZ 房主收）：发送方每轮都是点按（Start → End，没进 Loop），一个技能里点 2–5 轮；
--   收方替身没有输入组件、等松手任务永远等不到 → 自己 Start → Loop 一直循环到技能超时（远端#241：Loop 6 秒，多打两发 Red 各 -71，
--   杀气每 0.4 秒 -52；这两发已经出了判定窗口，没人知道）；后面几轮点按根本没发过去（只有第一轮的 ev=）。
--   §407 续转在对方松手时只在"自己补过 Loop"的情况下补收招，替身自己进的 Loop 不管。
-- 现在：
--   发：破阵曲三段任何一段开始 → sub=<次数>:<动作名>-<这一招的招式号>（§111 同一个字段；旧版收方不认识这个名字，忽略）
--   收：照对方的段播。第一轮的 Start 替身放技能时自己会播，不重播；第二轮起每个 Start 照播并开一个判定窗口（记在这一招的编号上），
--       End 来时这一招没有开着的窗口也开一个。替身自己进了 Loop、对方并不在 Loop（最近一段是 End，或者第一轮对方已经松手 rel=）
--       → 马上播 End。§407 续转不再管这一招（CHG.SPIN_SKIP）。对方旧版（不发段）只靠 rel= 停自循环。
--   §440 11-25 15:37 对决：对方按 6.30 秒松手，替身一直循环到 14 秒后倒计时才收、多打 8 发各 -214 把我打死。两个原因：
--     ① 发送方 Start / End 的招式号是 0（Start 时这一招还没发 ev=，End 时"我"那条已松手收掉）→ 收方把 0 当真编号、找不到招 → End 不播；
--     ② 对方 Loop 段到了（r.seg = "Loop"），rel= 到时 LUTE.step 只认"最近一段是 Start / 没段"才停 → 不停。
--     现在：发送方 Loop / End 没号时用最近一次的号；收方 Loop / End 的 0 号当没带号（取替身最近那次破阵曲），Start 的 0 号照旧不猜；
--     第一轮 rel= 到点不管最近一段是 Start 还是 Loop 都收；播了 End 1.5 秒后替身又回到 Loop → 直接取消这一招
--   日志关键字"§430 破阵曲"
LUTE = { GA = "GA_Hun_Lute_SKill_C",
         START = "Hun_ShaChi_Lute_Skill_01_Start_Montage", LOOP = "Hun_ShaChi_Lute_Skill_01_Loop_Montage",
         ENDM = "Hun_ShaChi_Lute_Skill_01_End_Montage", MAX_AGE = 15.0, LOGS = 80, n = 0 }
LUTE.SEG = { [LUTE.START] = "Start", [LUTE.LOOP] = "Loop", [LUTE.ENDM] = "End" }
function LUTE.log(fmt, ...)
    LUTE.n = LUTE.n + 1
    if LUTE.n <= LUTE.LOGS then out(fmt, ...) end
end
-- §407 续转别管破阵曲（base_charge 载入后调一次；替身驱动时也补一次，多人房按对手各一份 CHG）
function LUTE.skipSpin()
    if CHG and CHG.SPIN_SKIP and not CHG.SPIN_SKIP[LUTE.GA] then CHG.SPIN_SKIP[LUTE.GA] = true end
end
-- sub= 里的名字："<动作名>" 或 "<动作名>-<招式号>"。返回 段名, 动作名, 招式号（不是破阵曲的段 → nil）
function LUTE.parse(sm)
    if type(sm) ~= "string" then return nil end
    local mon, rid = sm:match("^([%w_]+)%-(%d+)$")
    mon = mon or sm
    local seg = LUTE.SEG[mon]
    if not seg then return nil end
    return seg, mon, tonumber(rid)
end
function LUTE.isSub(sm) return LUTE.parse(sm) ~= nil end
-- 发送方：我这一招的招式号（CHG.list 里"我"的那条；大招压着还没发时没有 → 0）
function LUTE.myId()
    local best, at = nil, nil
    for _, w in ipairs((CHG and CHG.list) or {}) do
        if w.who == "我" and w.name == LUTE.GA and w.id and (not at or w.at > at) then best, at = w.id, w.at end
    end
    return best or 0
end
-- 发送方：netSend 看到我的动作换成新的一个时调；是破阵曲的段 → 返回要发的 sub 名字（调用方发 sub=），否则 nil
function LUTE.mineSub(hm, prev)
    if hm == prev or not LUTE.SEG[hm or ""] then return nil end
    local id = LUTE.myId()
    if id ~= 0 then LUTE.lastId, LUTE.lastAt = id, now()
    elseif hm ~= LUTE.START and LUTE.lastId and now() - LUTE.lastAt <= LUTE.MAX_AGE then id = LUTE.lastId end   -- §440 ①
    LUTE.log("§430 破阵曲：我 %s（#%d）→ 发给对方", LUTE.SEG[hm], id)
    return hm .. "-" .. id
end
-- 收方每一招的记录（放在 CHG 上：观战 / 多人房按对手各一份）
function LUTE.rec(id)
    CHG.luteR = CHG.luteR or {}
    local r = CHG.luteR[id]
    if not r then r = { starts = 0, round = 1 }; CHG.luteR[id] = r end
    return r
end
function LUTE.judgeOpen(id)
    for _, j in ipairs(NET.judges or {}) do if j.id == id then return true end end
    return false
end
-- 收：对方 sub= 是破阵曲的一段（NET.recvOne 调）
function LUTE.onSub(p1, pup, sm, tn)
    LUTE.skipSpin()
    local seg, mon, rid = LUTE.parse(sm)
    if not (seg and valid(pup)) then return end
    if rid == 0 then                          -- §440 ① 发送方当时没号：Start 不猜（可能是新的一招），Loop / End 取最近那次
        if seg == "Start" then
            LUTE.log("§430 破阵曲：对方 Start 没带招式号 → 放的时候自己会播")
            return
        end
        rid = nil
    end
    local f = rid and CHG.fired and CHG.fired[rid]
    if not rid then          -- 没带招式号：取替身最近放的那一次破阵曲
        for id, x in pairs(CHG.fired or {}) do if x.name == LUTE.GA and (not rid or id > rid) then rid, f = id, x end end
    end
    if not f or f.name ~= LUTE.GA then
        -- 第一轮的 Start 可能比替身放这一招还早到：替身放技能自己会播，不用管；别的段等不到这一招就算了
        LUTE.log("§430 破阵曲：对方 %s（远端#%s），替身还没放这一招 → %s", seg, tostring(rid), seg == "Start" and "放的时候自己会播" or "不播")
        if seg == "Start" and rid then LUTE.rec(rid).starts = 1 end
        return
    end
    if tn - f.at > LUTE.MAX_AGE then
        LUTE.log("§430 破阵曲：对方 %s（远端#%d），这一招放出 %.1f 秒了 → 不播", seg, rid, tn - f.at)
        return
    end
    local r = LUTE.rec(rid)
    local cur = montageOf(pup) or ""
    local play, why = true, nil
    if seg == "Start" then
        r.starts = r.starts + 1
        if r.starts == 1 then play, why = false, "第一轮，替身放技能时自己播"
        else r.round = r.round + 1 end
    elseif seg == "Loop" and cur == LUTE.LOOP then play, why = false, "替身已经在循环"
    elseif seg == "End" and cur == LUTE.ENDM and r.selfEnd == r.round then play, why = false, "替身刚收过招"
    end
    r.seg, r.segAt = seg, tn
    local okP
    if play then
        montageByName(mon, true)
        pcall(G.facePlayer, pup)
        okP = playNamed(pup, mon)
        if f.mon then f.mon[mon] = true end
    end
    -- 判定窗口：第二轮起的 Start；End 时这一招没有开着的窗口（按住久了第一轮的窗口早过了）
    local opened = false
    if p1 and ((seg == "Start" and r.starts > 1) or (seg == "End" and not LUTE.judgeOpen(rid))) then
        openJudge(p1, rid, tn, LUTE.GA)
        opened = true
    end
    LUTE.log("§430 破阵曲：对方第 %d 轮 %s（远端#%d，放出 %.2f 秒）→ 替身%s%s（替身原来 %s）", r.round, seg, rid, tn - f.at,
        play and (okP and "已播" or "播放失败") or ("不播：" .. tostring(why)), opened and "，开判定窗口" or "", cur ~= "" and cur or "没动作")
end
-- 每帧（替身驱动里调）：替身自己进了 Loop、对方不在 Loop → 收招
function LUTE.step(pup, tn)
    if not (CHG and CHG.fired and next(CHG.fired)) then return end
    LUTE.skipSpin()
    local cur
    for id, f in pairs(CHG.fired) do
        if f.name == LUTE.GA and tn - f.at <= LUTE.MAX_AGE then
            cur = cur or (valid(pup) and montageOf(pup)) or ""
            LUTE.endFirst(pup, id, f, cur, tn)          -- §449 替身一放就进收招 → 收完重放
            if cur ~= LUTE.LOOP then return end
            local r = LUTE.rec(id)
            if r.selfEnd == r.round and r.selfAt and tn - r.selfAt > 1.5 and not r.cancelled then    -- §440 播了 End 又回到循环
                r.cancelled = true
                local okC, gone = pcall(G.cancelAbilities, pup, function(n) return n == LUTE.GA end)
                LUTE.log("§430 破阵曲：远端#%d 播了收招 %.1f 秒后替身又回到循环 → 取消这一招（%s）", id, tn - r.selfAt,
                    okC and tostring(gone) or ("出错 " .. tostring(gone)))
                return
            end
            local secs = CHG.rel and CHG.rel[id]
            local stop
            if r.seg == "End" then stop = "对方这一轮已经收招"
            elseif r.round == 1 and secs and tn >= f.at + secs then      -- §440 ② 最近一段是 Loop 也算
                stop = string.format("对方按了 %.2f 秒就松手（替身自己进了循环）", secs)
            end
            if stop and r.selfEnd ~= r.round then
                r.selfEnd, r.selfAt = r.round, tn
                local ok = playNamed(pup, LUTE.ENDM)
                if f.mon then f.mon[LUTE.ENDM] = true end
                LUTE.log("§430 破阵曲：远端#%d 第 %d 轮 %s → 替身停循环、播收招 %s（放出 %.2f 秒）", id, r.round, stop,
                    ok and "成功" or "失败", tn - f.at)
            end
        end
    end
end

-- §449 破阵曲少打（11-25 15:38:06 远端#211 / 15:41:20 远端#350）：对方按住 8.03 秒，替身 GA_Hun_Lute_SKill_C 一放出来
--   动作就是 Hun_ShaChi_Lute_Skill_01_End_Montage（蓄力探针 #10 / #14："0.00 …End… 2.17 -GA"），2.2 秒就自己收完、Loop 一发没打。
--   两次的上一次破阵曲都是没走收招就被掐掉的：#204 被 §364 倒计时取消（15:37:45）、#348 被"对方被打断：替身停招"切掉（15:41:18）；
--   走完收招的那几次（#211 之后的 #348、11-23 / 11-24 全部）下一次都是正常的 Start → Loop。§440"播了 End 又回到循环 → 取消"
--   同样是没走收招就掐掉。推断技能（每个角色一个实例）里松手类的状态没清，下一次放直接走收招；实例变量放之前读一次记日志（LUTE.preFire）。
-- 做法：替身放出 EF_WIN 秒内自己进了收招（不是我们播的、对方这一招也没发 End）→ 记下；等这次收完（技能没了），对方还没松手
--   （没 rel=、最近一段不是 End）就重放一次这一招（走完收招后再放是正常的），每招最多一次；EF_WAIT 秒还没收完就算了。
--   日志关键字"§449 破阵曲"
LUTE.EF_WIN, LUTE.EF_WAIT, LUTE.EF_POLL = 0.5, 4.0, 0.1
LUTE.VARS = { "AlreadyRelease", "CanRelease", "BulletDuration" }
LUTE.preN = 0
-- 放之前（AIR.fire）：只读，实例变量记日志（前 12 次）
function LUTE.preFire(p1, pup, e, tn)
    if e.name ~= LUTE.GA then return end
    LUTE.p1 = p1                                  -- 重放时开判定窗口用
    if LUTE.preN >= 12 then return end
    LUTE.preN = LUTE.preN + 1
    local s = (G.LO and G.LO.instVars) and G.LO.instVars(pup, LUTE.GA, LUTE.VARS) or "（没有读实例的函数）"
    LUTE.log("§449 破阵曲：远端#%d 放之前替身的技能实例：%s；替身动作 %s", e.id or -1, tostring(s), tostring(montageOf(pup) or "无"))
end
function LUTE.endFirst(pup, id, f, cur, tn)
    local r = LUTE.rec(id)
    if r.ef == nil then
        if tn - f.at > LUTE.EF_WIN then r.ef = false; return end
        if cur == LUTE.ENDM and not (f.mon and f.mon[LUTE.ENDM]) and r.seg ~= "End" and not r.selfEnd then
            r.ef = { at = tn, nextT = tn }
            LUTE.log("§449 破阵曲：远端#%d 替身放出 %.2f 秒就自己进了收招（对方最近一段 %s、%s）→ 等收完，对方还按着就重放", id,
                tn - f.at, tostring(r.seg or "没收到"), (CHG.rel and CHG.rel[id]) and "已松手" or "没松手")
        end
        return
    end
    if not r.ef or r.ef.done or tn < r.ef.nextT then return end
    r.ef.nextT = tn + LUTE.EF_POLL
    local why
    if r.seg == "End" then why = "对方这一轮已经收招"
    elseif CHG.rel and CHG.rel[id] then why = string.format("对方按了 %.2f 秒已经松手", CHG.rel[id])
    elseif tn - r.ef.at > LUTE.EF_WAIT then why = "等了太久还没收完"
    elseif tn - f.at > LUTE.MAX_AGE then why = "这一招太久了" end
    if not why then
        local okA, act = pcall(G.activeAbilities, pup)
        if okA and type(act) == "table" and act[LUTE.GA] then return end      -- 还在收招
        if not okA then why = "读不到替身技能" end
    end
    r.ef.done = true
    if why then
        LUTE.log("§449 破阵曲：远端#%d %s → 不重放", id, why)
        return
    end
    local okF, ok = pcall(RECM.activateOnPuppet, pup, LUTE.GA, NET.sub or {}, "§449 重放 远端#" .. id)
    r.refiredAt = tn
    if okF and ok and LUTE.p1 and not LUTE.judgeOpen(id) then openJudge(LUTE.p1, id, tn, LUTE.GA) end   -- 重放的 Loop 照常判定
    LUTE.log("§449 破阵曲：远端#%d 替身的收招走完了（放出 %.2f 秒）、对方还按着 → 重放这一招 %s", id, tn - f.at,
        (okF and ok) and "成功" or ("失败 " .. tostring(ok)))
end

-- ============================================================ §448 幻术琵琶【移商换羽 / 转轴拨弦】（GA_Lute_Dash）诊断（只读）
-- 资产：每个方向一对音刃——蓝 BD_GA_Hun_Lute_Dash_<F/B/L/R>_01(_E)（只有真杀气 5.28 / 5.81、扣血 0）+ 红 BD_Hun_Lute_Dash_<…>_Red_01(_E)
--   （元素 + 真伤 6.6 / 7.26）。在线：蓝的每次都中（受击 + 杀气 -160～-215），红的时有时无——
--   挨打方 11-24 14:46 #1043 红中 -268，#1045 / #1047（隔 3 / 5 秒）只有蓝；发送方 14:49 #603 / 14:52 #632 回报 -206，
--   紧跟着的 #605 / #634 / #635 / #636 都只扣杀气（§431 起记中招 -0）。像是一串里只有第一下出红，原因没查清（替身没出红 /
--   本来就有内置间隔 / 红的被别的挡掉都有可能）。这里两边各记一次：发送方我放这招（动作 Hun_ShaChi_Lute_Dash_*）、
--   挨打方替身放出来以后 AT 秒各扫一次子弹（FindAllOf，一招 3 次），看红 / 蓝音刃到底生成了没有。日志关键字"§448 移商换羽"
LDASH = { GA = "GA_Lute_Dash_C", AT = { 0.35, 0.7, 1.1 }, LOGS = 60, n = 0, pend = nil }
function LDASH.isMon(m) return type(m) == "string" and m:find("^Hun_ShaChi_Lute_Dash") ~= nil end
function LDASH.start(who, actor, tn, tag)
    if LDASH.n >= LDASH.LOGS or not valid(actor) then return end
    LDASH.pend = { who = who, actor = actor, at = tn, k = 1, tag = tag }
end
function LDASH.step(tn)
    local p = LDASH.pend
    if not p or tn - p.at < LDASH.AT[p.k] then return end
    if p.k >= #LDASH.AT then LDASH.pend = nil else p.k = p.k + 1 end
    if not valid(p.actor) then LDASH.pend = nil; return end
    LDASH.n = LDASH.n + 1
    local s = G.bulletScan and G.bulletScan(function(o) if sameObj(o, p.actor) then return p.who end end) or "（没有扫子弹的函数）"
    local mine = {}
    for item in tostring(s):gmatch("%S+") do if item:find(p.who .. ":", 1, true) == 1 then mine[#mine + 1] = item end end
    out("§448 移商换羽 %s %s +%.2f 秒：%s 的子弹 %s", p.who, tostring(p.tag), tn - p.at, p.who, #mine > 0 and table.concat(mine, " ") or "没有")
end

-- ============================================================ §108 房间设置"血瓶：关"时交手中不能喝药
-- 喝药 = 本机玩家开始播 AM_Hun_Medicine_*（§103 同一个判断）；喝药技能 GA_Medicine_* 不在发包看的技能里。回血是开始喝后
-- 约 1 秒内分几跳到（2026-11-05 22:44:50 日志：+15 / +46 交替），可能在我们看到动作前就到了一跳。所以关的时候：
--   ① 动作一出现就停掉、取消喝药技能（名字 ^GA_Medicine_ 且不是 Passive）；② HOLD 秒内血量只许降不许升（升了写回去）；
--   ③ 不发 med=（对方替身不播喝药）。代价：药瓶次数可能已经扣了；HOLD 秒内别的回血（斩马刀吸血补偿等）也被压住
NOMED = { HOLD = 6.0, untilT = nil, cap = nil, n = 0 }
function NOMED.active() return NET.fighting() and not NET.flagNow("med") end
function NOMED.isDrink(name) return name:match("^GA_Medicine_") ~= nil and not name:find("Passive", 1, true) end
-- netSend 看到我开始播喝药动作时调：拦了返回 true（调用方不发 med=）
function NOMED.block(p1, hm, tn)
    if not NOMED.active() then return false end
    local cut = cutMontage(p1)
    local gone = G.cancelAbilities(p1, NOMED.isDrink)
    -- §265 翻滚喝药是动作一出来同一帧就回一大口（+1078）：看到动作时血已经涨了。上一次发包时的血量（0.5 秒内）比现在低 → 压回那个数
    local h, back = hpOf(p1), nil
    if h and NOMED.prevHp and NOMED.prevT and tn - NOMED.prevT <= 0.5 and h > NOMED.prevHp + 0.5 then
        back = NOMED.prevHp
        setAttr(p1, "Health", back)
    end
    NOMED.untilT, NOMED.cap = tn + NOMED.HOLD, back or h
    NOMED.n = NOMED.n + 1
    out("血瓶已禁用：%s → 动作%s，%s，%d 秒内不回血（第 %d 次）%s", hm, cut and "已停" or "没停到",
        #gone > 0 and ("已取消 " .. table.concat(gone, ",")) or "没取消到喝药技能", NOMED.HOLD, NOMED.n,
        back and string.format("；看到动作前已经回了 %.0f，压回 %.0f", h - back, back) or "")
    return true
end
-- 每次发包：HOLD 秒内血量升了就写回上限（降了就跟着降）；§265 交手中最后记下这次（压过之后）的血量，给下一次 NOMED.block 用
function NOMED.frame(p1, tn)
    NOMED.capStep(p1, tn)
    if NET.fighting() then NOMED.prevHp, NOMED.prevT = hpOf(p1), tn else NOMED.prevHp, NOMED.prevT = nil, nil end
end
function NOMED.capStep(p1, tn)
    if not NOMED.untilT then return end
    if tn >= NOMED.untilT or not NET.fighting() then NOMED.untilT, NOMED.cap = nil, nil; return end
    local h = hpOf(p1)
    if not (h and NOMED.cap) then NOMED.cap = h; return end
    if h > NOMED.cap + 0.5 then
        setAttr(p1, "Health", NOMED.cap)
        out("血瓶已禁用：血量 %.0f → %.0f（压回）", h, NOMED.cap)
    else
        NOMED.cap = h
    end
end

-- 每 10 秒统计里的一行
function PRED.report()
    local s = PRED.st
    if s.contact == 0 then return end
    local b = PRED.b or { g = PRED.PRIOR.g, n = PRED.PRIOR.n }
    out("      预测：碰到 %d 次（替身忙 %d），先到结果 %d，先播格挡 %d / 留受击 %d / 猜落空 %d / 等结果 %d；猜对 %d 猜错 %d（纠正 %d，落空收掉 %d，没等到结果 %d）；"
        .. "防住率 格挡中 %.0f%% / 没格挡 %.0f%%", s.contact, s.busy, s.prior or 0, s.preDef, s.preHit, s.preMiss or 0, s.wait, s.right, s.wrong, s.fix, s.undo,
        s.nores, PRED.prob(true) * 100, PRED.prob(false) * 100)
end

-- ============================================================ v0.27.0 延迟：测量 / 外推 / 追帧（docs/LATENCY_DESIGN.md）
-- A 测量：状态包加 ts=<我的毫秒>、tse=<对方最近一包的 ts>:<我收到它之后又过了多少毫秒>，NTP 式四个时间戳算往返和时钟差。
--   在 Lua 层算，两边的驱动节拍和文件邮箱都算在里面；不依赖两台电脑的系统时钟。旧版对方不发 ts = 不知道包龄，B / C 都不做
-- B 外推：替身追 对方位置 + 速度 × 包龄（最多 EXTRA_MAX 秒）；出招 / 受击 / 急转时不外推
-- C 追帧：替身放出对方的攻击后，蒙太奇往后跳"这招晚到了多久"（最多 SKIP_MAX），但防守方看到的前摇不少于
--   max(WINDUP_FLOOR, 前摇 × WINDUP_KEEP)；不知道前摇的招不跳。
--   前摇（v0.27.0 第二版，§78.2）：实战里学——替身的招在我这边打中我 / 被我格挡的那一刻，它的蒙太奇播到第几秒，就是这招的前摇
--   （多段招、闪掉第一段会偏大，所以取最小值，攒够 LEARN_MIN 次才用），存进 rec\windup.txt 下次接着用。
--   手填的 LAT.WINDUP 优先；还没学够时再试读蒙太奇的通知（第一次实机全是空的，留着当诊断）
-- 全局（不是 local）：主代码块的 local 已满 200 个
-- F3c-3（docs/FORNET_SPLIT.md）：LAT 的 A 测量 / B 外推（ms / reset / wire / onPacket / age / rttMs / extrapolate，不认识游戏）在 fornet_net.lua；
-- C 追帧 / 前摇学习（蒙太奇、判定、招式）是影之刃零的，留在这里，往同一张表上补字段和函数
FNET = (function()     -- fornet 网络封装模块（全局：主块 local 已满）；REL 在它里面，可靠事件通道那段取别名
    local ok, mk = pcall(require, "fornet_net")
    if ok and FORNET and FORNET.adopt then mk = FORNET.adopt("fornet_net", mk) end     -- F6：实例登记到宿主（FORNET.mods）
    if not ok then ok, mk = pcall(dofile, ROOT .. "/Scripts/fornet_net.lua") end
    if not (ok and type(mk) == "function") then error("fornet_net.lua 加载失败：" .. tostring(mk)) end
    return mk({ out = out, NET_DIR = NET_DIR, fileWrite = fileWrite, fileReadKV = fileReadKV })
end)()
LAT = FNET.LAT
LAT.SKIP_MAX, LAT.SKIP_MIN, LAT.WINDUP_FLOOR, LAT.WINDUP_KEEP, LAT.SKIP_WAIT, LAT.NOTE_LOGS = 0.10, 0.03, 0.25, 0.6, 0.25, 10
LAT.LEARN_MIN, LAT.LEARN_LO, LAT.LEARN_HI, LAT.SAVE_EVERY, LAT.LEARN_LOGS = 2, 0.08, 2.0, 60, 60     -- §84 学到的前摇 10 → 60 秒落一次盘
-- 通知状态类名里带这些（不分大小写）算攻击判定窗口；带 BAD 里的不算
LAT.HINTS = { "attack", "damage", "hitbox", "hitcheck", "trace", "collision", "weaponhit", "hurt" }
LAT.BAD = { "react", "cancel", "input", "combo", "buffer", "sound", "fx", "camera" }
LAT.WINDUP = {}      -- 手填：蒙太奇短名 → 前摇秒数（优先于学到的）
LAT.learned = {}     -- 学到的：蒙太奇短名 → { min = 秒, n = 次数 }
LAT.byId = {}        -- 远端招式号 → 替身为它播的蒙太奇名（判定结果回来时对得上才学）
LAT.notified = {}    -- 蒙太奇短名 → 从通知读到的前摇；false = 读过没找到
LAT.loaded, LAT.dirty, LAT.savedAt, LAT.learnLogs = false, false, -100, 0
LAT.pend, LAT.notes = nil, 0
LAT.activeMontage = G.activeMontage or function() return nil end
LAT.setPos = G.montageSetPos or function() return false end
LAT.notifies = G.montageNotifies or function() return nil end


-- 这一帧替身追的目标位置。返回 位置, 不外推的原因（外推了 = nil）
function LAT.target(tn)
    local pos = NET.pos
    if ST.pupAtkAt and tn - ST.pupAtkAt < LAT.EXTRA_ATK then return pos, "出招" end
    if NET.lastHrAt and tn - NET.lastHrAt < LAT.EXTRA_HIT then return pos, "受击" end
    if NET.turnAt and tn - NET.turnAt < LAT.EXTRA_TURN then return pos, "急转" end
    if NET.stopAt and tn - NET.stopAt < LAT.EXTRA_TURN then return pos, "急停" end     -- §436.2
    local age = LAT.age(LAT.peerTs, tn)
    if not age then return pos, "没有时间戳" end
    LAT.st.extra = LAT.st.extra + 1
    return LAT.extrapolate(pos, NET.vel, age), nil
end

-- 收到新速度：和上一包方向相反（夹角 > 90°，两次都在跑）= 急转，EXTRA_TURN 秒内不外推
function LAT.onVel(old, new, tn)
    if not (old and new) then return end
    local s1, s2 = math.sqrt(old.X ^ 2 + old.Y ^ 2), math.sqrt(new.X ^ 2 + new.Y ^ 2)
    if s1 > 100 and s2 > 100 and old.X * new.X + old.Y * new.Y < 0 then NET.turnAt = tn end
    -- §436.2 急停：速度一包里掉到原来的 STOP_RATIO 以下（松开摇杆 / 撞墙）= 对方停了，EXTRA_TURN 秒内不外推（不然按停之前的速度往前推，
    -- 替身冲出去再被拉回来）；停着的时候（新速度很小）也一直算
    if (s1 > 150 and s2 < s1 * LAT.STOP_RATIO) or (s2 < 30 and s1 >= 30) then NET.stopAt = tn end
end
LAT.STOP_RATIO = 0.4

-- C：这招最多能跳多少秒（纯函数）。age = 晚到的秒数，windup = 前摇秒数（不知道 = nil）。返回 秒数（0 = 不跳）, 原因
function LAT.skipFor(age, windup)
    if not age then return 0, "没有时间戳" end
    if not windup then return 0, "不知道前摇" end
    local keep = math.max(LAT.WINDUP_FLOOR, windup * LAT.WINDUP_KEEP)
    local s = math.min(age, LAT.SKIP_MAX, windup - keep)
    if s < LAT.SKIP_MIN then return 0, age < LAT.SKIP_MIN and "晚得不多" or "前摇太短" end
    return s, nil
end

-- 通知状态类名像不像攻击判定窗口
function LAT.isHitWindow(cls)
    local c = (cls or ""):lower()
    for _, b in ipairs(LAT.BAD) do if c:find(b, 1, true) then return false end end
    for _, h in ipairs(LAT.HINTS) do if c:find(h, 1, true) then return true end end
    return false
end

-- 替身正在播的蒙太奇的前摇（秒）：手填 > 学够了的 > 通知里读到的；都没有 = nil
function LAT.windupOf(pup, name)
    LAT.load()
    if LAT.WINDUP[name] then return LAT.WINDUP[name] end
    local l = LAT.learned[name]
    if l and l.n >= LAT.LEARN_MIN then return l.min end
    local w = LAT.notified[name]
    if w ~= nil then return w or nil end
    local list, _, diag = LAT.notifies(pup)
    w = false
    local parts = {}
    for _, n in ipairs(list or {}) do
        if n.state and w == false and n.t > 0.05 and LAT.isHitWindow(n.cls) then w = n.t end
        parts[#parts + 1] = string.format("%s%s@%.2f%s", n.state and "" or "·", n.cls, n.t, n.d > 0 and string.format("+%.2f", n.d) or "")
    end
    LAT.notified[name] = w
    if LAT.notes < LAT.NOTE_LOGS then
        LAT.notes = LAT.notes + 1
        out("追帧：%s 通知里的前摇 %s；通知 %s%s；学到 %s", name, w and string.format("%.2f 秒", w) or "没找到",
            list and (#parts > 0 and table.concat(parts, " ") or "（空）") or "（读不到 Notifies）",
            diag and string.format("（数组长度 %s，遍历 %s）", tostring(diag.num), diag.ok and "成功" or "失败") or "",
            l and string.format("%.2f 秒 × %d 次（不够 %d 次）", l.min, l.n, LAT.LEARN_MIN) or "还没有")
    end
    return w or nil
end

-- 学到的前摇存在 rec\windup.txt：一行一个"蒙太奇名 最小秒数 次数"
function LAT.file() return REC_DIR .. "/windup.txt" end

function LAT.load()
    if LAT.loaded then return end
    LAT.loaded = true
    local f = io.open(LAT.file(), "r")
    if not f then return end
    local n = 0
    for line in f:lines() do
        local name, mn, cnt = line:match("^([%w_]+)%s+([%d%.]+)%s+(%d+)")
        if name then LAT.learned[name] = { min = tonumber(mn), n = tonumber(cnt) }; n = n + 1 end
    end
    f:close()
    out("追帧：读入学过的前摇 %d 个（%s）", n, LAT.file())
end

-- tn = nil：不管隔了多久都存（每 10 秒的统计行调）
function LAT.save(tn)
    if not LAT.dirty or (tn and tn - LAT.savedAt < LAT.SAVE_EVERY) then return end
    tn = tn or LAT.savedAt + LAT.SAVE_EVERY
    local names, lines = {}, {}
    for k in pairs(LAT.learned) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do lines[#lines + 1] = string.format("%s %.3f %d", k, LAT.learned[k].min, LAT.learned[k].n) end
    if fileWrite(LAT.file(), table.concat(lines, "\n") .. "\n") then LAT.dirty, LAT.savedAt = false, tn end
end

-- 判定：远端第 id 招在我这边打中我 / 被我格挡了（netJudge 调）。替身还在播这招的蒙太奇 → 现在的位置就是一个前摇样本
function LAT.learnFrom(id, kind, tn)
    local want = LAT.byId[id]
    if not want then return end
    LAT.byId[id] = nil
    local _, _, name, pos = LAT.activeMontage(puppet())
    if name ~= want or not pos then return end
    if pos < LAT.LEARN_LO or pos > LAT.LEARN_HI then return end
    LAT.load()
    local l = LAT.learned[name] or { n = 0 }
    local was = l.min
    l.min, l.n = was and math.min(was, pos) or pos, l.n + 1
    LAT.learned[name], LAT.dirty = l, true
    if LAT.learnLogs < LAT.LEARN_LOGS then
        LAT.learnLogs = LAT.learnLogs + 1
        out("追帧：学前摇 %s（远端#%d %s）蒙太奇在 %.2f 秒 → 最小 %.2f 秒 × %d 次%s", name, id, kind, pos, l.min, l.n,
            l.n == LAT.LEARN_MIN and "，够了，以后追帧" or "")
    end
    LAT.save(tn)
end

-- 替身放出一招之后调（AIR.fire）。before = 放之前替身在播的蒙太奇名
function LAT.afterFire(pup, e, before, tn)
    if not isAttackAbility(e.name) or e.name:find("_Air", 1, true) then return end    -- 空中招有起跳时机，不跳
    local age = e.age and (e.age + (tn - (e.rcv or tn))) or nil
    LAT.pend = { pup = pup, name = e.name, id = e.id, age = age, before = before, at = tn }
    LAT.step(tn)
end

-- 每帧：等替身真的开始播这招的蒙太奇了再跳（激活技能和开始播放可能差一帧）
function LAT.step(tn)
    local p = LAT.pend
    if not p then return end
    local an, _, name, pos = LAT.activeMontage(p.pup)
    local started = an and pos and (name ~= p.before or pos < 0.15)
    if not started then
        if tn - p.at > LAT.SKIP_WAIT then LAT.pend = nil; LAT.noSkip("没等到蒙太奇") end
        return
    end
    LAT.pend = nil
    LAT.byId[p.id], LAT.byId[p.id - 200] = name, nil          -- 判定结果回来时学前摇用
    if name:find("C_Failed", 1, true) or name:find("Unique_Skill", 1, true) then     -- v0.27.1 大招资源诊断
        ULT.watch(p.pup, true, "替身 " .. p.name .. " → " .. name, tn)
    end
    local s, why = LAT.skipFor(p.age, LAT.windupOf(p.pup, name))
    if s <= 0 then LAT.noSkip(why); return end
    local ok = LAT.setPos(p.pup, pos + s)
    if not ok then LAT.noSkip("Montage_SetPosition 失败"); return end
    LAT.st.skip, LAT.st.skipMs = LAT.st.skip + 1, LAT.st.skipMs + s * 1000
    if LAT.st.skip <= 20 then
        out("追帧 远端#%d %s：晚了 %.0f ms，%s 从 %.2f 跳到 %.2f", p.id, p.name, (p.age or 0) * 1000, name, pos, pos + s)
    end
end

function LAT.noSkip(why)
    LAT.st.noSkip = LAT.st.noSkip + 1
    LAT.st.noWhy[why] = (LAT.st.noWhy[why] or 0) + 1
end

-- 每 10 秒一行统计
function LAT.report()
    if not LAT.peerTs then return end
    local ages = {}
    for _, a in ipairs(LAT.ages) do ages[#ages + 1] = a end
    table.sort(ages)
    local why = {}
    for k, v in pairs(LAT.st.noWhy) do why[#why + 1] = k .. " " .. v end
    table.sort(why)
    local nl, nok = 0, 0
    for _, l in pairs(LAT.learned) do nl = nl + 1; if l.n >= LAT.LEARN_MIN then nok = nok + 1 end end
    LAT.save(nil)
    out("延迟 | 往返 %s ms（最小 %s 最大 %s，%d 样本）时钟差 %s ms | 包龄中位 %s ms | 外推 %d 帧 | 追帧 %d 次 平均 %.0f ms，不追 %d 次%s | 学到前摇 %d 个（够用 %d）",
        tostring(LAT.rtt or "-"), tostring(LAT.rttMin or "-"), tostring(LAT.rttMax or "-"), #LAT.samples,
        LAT.off and string.format("%+.0f", LAT.off) or "-",
        #ages > 0 and string.format("%.0f", ages[math.floor((#ages + 1) / 2)] * 1000) or "-",
        LAT.st.extra, LAT.st.skip, LAT.st.skip > 0 and LAT.st.skipMs / LAT.st.skip or 0, LAT.st.noSkip,
        #why > 0 and ("（" .. table.concat(why, "，") .. "）") or "", nl, nok)
end

-- ============================================================ §100 替身放招成功却没换动作（v0.27.20）（→ base_fixplay.lua）
-- 全局表（最外层 local 已经很多，不再加）
FIXP = BASEPARTS.load("fixplay", {
    NET = NET, RECM = RECM, G = G,
    isAttackAbility = isAttackAbility, playNamed = playNamed,
    -- 主循环那段会把这几个换成计时包装（PROF.wrap）：传"调用时再取"，和搬出来之前一样
    out = function(...) return out(...) end,
    activeAbilities = function(...) return activeAbilities(...) end,
})

-- ============================================================ v0.27.1 大招资源诊断（§78.6）
-- 大招（C_C，炽刃 Hun_ZhiRen_Unique_Skill_01）不耗杀气、耗另一种资源；替身用一次就 C_Failed，之后再也放不出。
-- 不知道那个资源叫什么，所以：我放大招 / 我播 C_Failed / 替身放大招或 C_Failed 时，记下全部属性，WAIT 秒后再记一次，
-- 日志写变化了的属性；替身的那条另外写"替身比你低"的属性（缺的资源多半在里面）。全局：主代码块 local 已满。最多 LOGS 条
ULT = { WAIT = 1.5, LOGS = 12, FULL = 2, n = 0, full = 0, pend = {} }

function ULT.snap(actor)
    if not (G.attrAll and actor) then return nil end
    local ok, list, how = pcall(G.attrAll, actor)
    if not ok or not list then return nil end
    local t = {}
    for _, a in ipairs(list) do t[a.name] = a.cur end
    return t, list, how
end

function ULT.watch(actor, isPup, why, tn)
    if ULT.n >= ULT.LOGS then return end
    local s0, list, how = ULT.snap(actor)
    if not s0 then return end
    ULT.n = ULT.n + 1
    ULT.pend[#ULT.pend + 1] = { actor = actor, isPup = isPup, why = why, at = tn, s0 = s0, k = ULT.n }
    if ULT.full < ULT.FULL then
        ULT.full = ULT.full + 1
        local parts = {}
        for _, a in ipairs(list) do parts[#parts + 1] = string.format("%s=%s", a.name, tostring(a.cur)) end
        out("大招诊断 #%d %s：全部属性（%d 个，%s）%s", ULT.n, why, #list, tostring(how), table.concat(parts, " "))
    end
end

-- ---- v0.27.2 大招充能（§78.7）：大招耗 UltimateChargeCount（充能格数，上限 3；UltimateCharge 0–100 攒满一格）。
-- 没充能时按大招，游戏照样激活 C_C 技能、播 C_Failed——以前这也当一招发出去，假对手随机回"中招"，真人对战时对面的替身
-- 若有充能会真放出来。现在：发送方把大招压住，看到 C_Failed 就丢掉，放出来了（动作带 Unique，或压满 HOLD_TICKS 帧没失败）才发；
-- 接收方收到大招 = 对方一定放成功了，激活前把替身的充能补到至少 1 格（替身自己不攒充能，以前用一次就再也放不出）
-- §165.3 大招不全叫 _C_C：黑魔伤 C1、玉双轮 C_Range、乱影 CA / P2_CA（没充能时都播 *_C_Failed，2026-11-08 双开实测）；
-- 绝影空中大招 JueYing_C_Air：替身没充能时返回 true 但不变鸟、什么动作都没有（用户 20:29 实测）
-- §343 痴者残剑 C_ToZui（微醺 → 醉剑）/ C_Zui（醉剑 C）和 C_C 一样是 GA_Hun_Tang_C 的子类（资产 Super，11-16 离线核对；
--   GA_Hun_Tang_C 的子类一共 5 个，另 3 个 C_C 已被 _C_C$ 认出），替身没充能时 ToZui 播 AM_Hun_Tang_C_Failed、进不了醉剑
-- §348 大招的根是 BP_CombatArt_Base（CDO Ultimate Charge Cost = 1）。11-16 离线扫全部 1222 个 GA_Hun_*：它的子类 34 个，
--   只有紫冥剑 CC（BP_CC_Base）/ CCC（BP_CCC_Base）这里认不出 → 替身 0 格充能放出来没动作（"放成功 0.42 秒，替身动作还是 nil"）、
--   假对手和两开都 0 伤害。其余 32 个都已被下面的名字认出（清单见 HANDOVER §348）
ULT.PAT, ULT.HOLD_TICKS, ULT.held, ULT.dropped, ULT.topped =
    { "_C_C$", "_C_Air_C$", "^GA_Hun_HeiMoShang_C1_C$", "^GA_Hun_Jade_C_Range_C$", "^GA_Hun_LuanYing_P?2?_?CA_C$",
      "^GA_Hun_ChiZheCanJian_C_ToZui_C$", "^GA_Hun_ChiZheCanJian_C_Zui_C$", "^GA_Hun_ZiMingJian_New_CCC?_C$" }, 3, {}, 0, 0

function ULT.isUlt(n)
    for _, p in ipairs(ULT.PAT) do if n:find(p) then return true end end
    return false
end

-- 发一个出招事件（以前写在 netSend 里）
function ULT.emit(n, tn, ts)
    NET.evId = NET.evId + 1
    NET.events[#NET.events + 1] = { id = NET.evId, name = n, at = tn, ts = ts }
    NET.evName = NET.evName or {}                   -- v0.17.7 招式号 → 技能名（斩马刀吸血补偿要查）
    NET.evName[NET.evId], NET.evName[NET.evId - 300] = n, nil
    if isAttackAbility(n) then NET.myAtkAt = tn; NET.myAtkId = NET.evId end     -- §299 多人"谁打的"：我最近一次出攻击招的时间与招式编号
    BAL.noteStance(BAL.myStance, n, tn)             -- §186.3 我放的这招在架势里 → 回报按强化版的系数（和对方替身那边一样）
    NET.evBal = NET.evBal or {}
    NET.evBal[NET.evId], NET.evBal[NET.evId - 300] = BAL.resolve(n, BAL.myStance, tn), nil
    NET.evWc = NET.evWc or {}                       -- §371 我放这招时手上的武器（同一招按武器分开的系数，TOUCH.scale 回报用）
    NET.evWc[NET.evId], NET.evWc[NET.evId - 300] = NET.wcStr, nil
    if TOUCH then TOUCH.noteFire(n, tn) end         -- §207 本地 AI：L1+圈 窗口
    if n == TORN.CLS then TORN.start("me", tn) end  -- §383 我放火蓄力：开始数火焰龙卷
    if AISYNC then AISYNC.noteFire(NET.evId, n, tn) end   -- §352 本地 AI：这招放完前不判落空（act=）
    CHG.onEmit(n, NET.evId)                         -- §92 压着的大招：松手记录要用发出去的招式号
end

function ULT.flushHeld(p1, hm, tn)
    if #ULT.held == 0 then return end
    local keep = {}
    for _, h in ipairs(ULT.held) do
        h.n = h.n + 1
        if hm:find("C_Failed", 1, true) then
            ULT.dropped = ULT.dropped + 1
            if ULT.dropped <= 10 then out("大招没放出来（%s，动作 %s，没充能）：不发给对方（第 %d 次）", h.name, hm, ULT.dropped) end
        elseif hm:find("Unique", 1, true) or h.n >= ULT.HOLD_TICKS then
            ULT.emit(h.name, tn, h.ts)                 -- ts 用按下那一帧的：追帧照算晚了多久
            ULT.watch(p1, false, "我放大招 " .. h.name, tn)
        else
            keep[#keep + 1] = h
        end
    end
    ULT.held = keep
end

-- §375 影之武装暗源不够：游戏照样激活这招（GA 挂 2–3 秒），只播 AM_Hun_ShachiWeapon_Failed_*。以前照发，
--   对方替身暗源一直补满（§113）就真放了出来、打掉血（v0.34.6 玩家日志：失败的虎炮照样 −783）。
--   和大招一样先压住：看到失败动作就不发；动作换成别的（放出来了）当帧就发，不加延迟；HOLD_TICKS 帧都没变也发。
--   m0 = 按下前一帧的动作：连按几次失败时动作名不变，没变的失败动作要等它换，换不了才算失败
ULT.edgeHeld, ULT.edgeDropped = {}, 0
function ULT.holdEdge(n, tn)
    ULT.edgeHeld[#ULT.edgeHeld + 1] = { name = n, ts = LAT.ms(tn), n = 0, m0 = NET.edgeM }
end
function ULT.flushEdge(p1, hm, tn)
    if #ULT.edgeHeld > 0 then
        local keep = {}
        for _, h in ipairs(ULT.edgeHeld) do
            h.n = h.n + 1
            local failed, changed = hm:find("ShachiWeapon_Failed", 1, true) ~= nil, hm ~= h.m0 and hm ~= ""
            if failed and (changed or h.n >= ULT.HOLD_TICKS) then
                ULT.edgeDropped = ULT.edgeDropped + 1
                if ULT.edgeDropped <= 20 then out("影之武装没放出来（%s，动作 %s，暗源不够）：不发给对方（第 %d 次）", h.name, hm, ULT.edgeDropped) end
            elseif (changed and not failed) or h.n >= ULT.HOLD_TICKS then
                ULT.emit(h.name, tn, h.ts)
            else
                keep[#keep + 1] = h
            end
        end
        ULT.edgeHeld = keep
    end
    NET.edgeM = hm
end

-- §165.7 补放只认对方发来过的大招：对方压住大招、确认没 C_Failed 才发（ULT.flushHeld），收到时记下招式号 → 招名；补放用掉就删
ULT.ok, ULT.okN = {}, 0
function ULT.mark(id, name)
    if id == nil then return end
    ULT.ok[id] = name
    ULT.okN = ULT.okN + 1
    if ULT.okN > 64 then ULT.ok, ULT.okN = { [id] = name }, 1 end     -- 只留最近的，防止越攒越多
end
function ULT.okFor(id, name)
    if id == nil or ULT.ok[id] ~= name then return false end
    ULT.ok[id] = nil
    return true
end

function ULT.topUp(pup)
    if TRAINCTX and TRAINCTX.ultCapped and TRAINCTX.ultCapped() then return end     -- §456 木桩精纯杀气定了个数：用完就没有
    local c = attrOf(pup, "UltimateChargeCount")
    if c == nil or c >= 1 then return end
    setAttr(pup, "UltimateChargeCount", 1)
    ULT.topped = ULT.topped + 1
    if ULT.topped <= 10 then out("替身大招充能 %.0f → 1 格（对方放成功了才会发来，第 %d 次）", c, ULT.topped) end
end

-- 每帧调；只有等着的诊断到时间了才读属性
function ULT.step(p1, tn)
    if #ULT.pend == 0 then return end
    local keep = {}
    for _, w in ipairs(ULT.pend) do
        if tn - w.at < ULT.WAIT then keep[#keep + 1] = w else
            local s1 = ULT.snap(w.actor) or {}
            local ch, low = {}, {}
            local names = {}
            for k in pairs(s1) do names[#names + 1] = k end
            table.sort(names)
            for _, k in ipairs(names) do
                local a, b = w.s0[k], s1[k]
                if a and b and math.abs(b - a) > 0.01 then ch[#ch + 1] = string.format("%s %.1f→%.1f", k, a, b) end
            end
            if w.isPup then
                local mine = ULT.snap(p1) or {}
                for _, k in ipairs(names) do
                    if mine[k] and s1[k] and mine[k] - s1[k] > 0.5 then low[#low + 1] = string.format("%s 替身 %.1f / 你 %.1f", k, s1[k], mine[k]) end
                end
            end
            out("大招诊断 #%d %s：%.1f 秒内变化 %s%s", w.k, w.why, ULT.WAIT, #ch > 0 and table.concat(ch, "，") or "（无）",
                w.isPup and ("；替身比你低：" .. (#low > 0 and table.concat(low, "，") or "（无）")) or "")
        end
    end
    ULT.pend = keep
end

-- ============================================================ §92 蓄力招松手同步
CHGM = BASEPARTS.load("charge", {
    NET = NET, NET_DIR = NET_DIR, RECM = RECM, JUDGE_WIN = JUDGE_WIN, playNamed = playNamed, G = G,
    -- 主循环那段会把这几个换成计时包装（PROF.wrap）：传"调用时再取"，和搬出来之前一样
    out = function(...) return out(...) end,
    activeAbilities = function(...) return activeAbilities(...) end,
    montageOf = function(...) return montageOf(...) end,
})
LUTE.skipSpin()      -- §430 破阵曲按对方的段播，§407 续转不管

-- ============================================================ v0.24.2 空中同步（→ base_air.lua）
local AIR = BASEPARTS.load("air", {
    ST = ST, NET = NET, MATCH = MATCH, REP = REP, RECM = RECM, LO = LO, FN = FN, G = G,
    ROOT = ROOT, NET_DIR = NET_DIR,
    isAttackAbility = isAttackAbility, openJudge = openJudge, addResult = addResult, playNamed = playNamed,
    -- 主循环那段会把这几个换成计时包装（PROF.wrap）：传"调用时再取"，和搬出来之前一样
    out = function(...) return out(...) end,
    hpOf = function(...) return hpOf(...) end,
    attrOf = function(...) return attrOf(...) end,
    montageOf = function(...) return montageOf(...) end,
})

CTRREC = BASEPARTS.load("guard_recovery", { G = G,
    out = function(...) return out(...) end,
    hpOf = function(...) return hpOf(...) end,
    attrOf = function(...) return attrOf(...) end,
    locked = function(tn) return STG.active(tn) or CDL.active() end })

-- ============================================================ 武器平衡规则（§184 / §212 火枪、§242 召唤、§242/§245/§246 火流星、§200 闪避、§200.11 切武器保持杀气 → base_wrules.lua）
-- 全局表（最外层 local 已经很多，不再加；GCD / GDMG / SUMD / HLFX / DCD / SWK 各自仍为全局）
WRULES = BASEPARTS.load("wrules", { ST = ST, NET = NET, MATCH = MATCH, NET_DIR = NET_DIR, G = G,
    -- 主循环那段会把这几个换成计时包装（PROF.wrap）：传"调用时再取"，和搬出来之前一样
    out = function(...) return out(...) end, attrOf = function(...) return attrOf(...) end, montageOf = function(...) return montageOf(...) end })

-- Reversible local and replay-actor passive rules; original equipment assets remain unchanged.
SHADOWPASSIVES = BASEPARTS.load('shadowpassives', {
    active = function() return NET.fighting() and BAL.active() end,
    actorKey = function(actor) return valid(actor) and full(actor) or nil end,
    mapToken = function() return ST.mapLoads end,
    equipped = function(actor) return valid(actor) and STD.idOf(LO.heldConfig(actor, LO.slotShachi())) or nil end,
    snapshot = function(actor, paths)
        local snap = G.snapshotEffects(actor, paths)
        if sameObj(actor, getP1()) and STD.gearMine then
            for path, e in pairs(snap.effects) do if STD.gearMine[path] then e.restore = false end end
        end
        if SHADOWPASSIVES and SHADOWPASSIVES.blocked(paths[1]) then
            if not SHADOWPASSIVES.snapshotKeys or SHADOWPASSIVES.snapshotMap ~= ST.mapLoads then
                SHADOWPASSIVES.snapshotKeys, SHADOWPASSIVES.snapshotLogs, SHADOWPASSIVES.snapshotMap = {}, 0, ST.mapLoads
            end
            for path, e in pairs(snap.effects) do
                local note = string.format('%s %s active=%s level=%s policy=%s safe=%s complete=%s', full(actor), STD.geShort(path),
                    tostring(e.active), tostring(e.level), tostring(e.removalPolicy), tostring(e.safeRemoval), tostring(snap.complete))
                if not SHADOWPASSIVES.snapshotKeys[note] and SHADOWPASSIVES.snapshotLogs < 40 then
                    SHADOWPASSIVES.snapshotKeys[note], SHADOWPASSIVES.snapshotLogs = true, SHADOWPASSIVES.snapshotLogs + 1
                    out('11.20 passive snapshot: %s', note)
                end
            end
        end
        return snap
    end,
    remove = function(actor, path) return LO.removeGE(actor, path, '11.20 disable passive') end,
    apply = function(actor, path, level)
        local ok, handle = LO.applyGE(actor, path, '11.20 restore passive', level)
        local value = rawProp(handle, 'Handle')
        return ok and type(value) == 'number' and value >= 0
    end,
    out = function(...) return out(...) end,
})
function SHADOWPASSIVES.forActor(actor)
    if sameObj(actor, getP1()) then return SHADOWPASSIVES end
    if not SHADOWPASSIVES.puppets or SHADOWPASSIVES.puppetMap ~= ST.mapLoads then
        SHADOWPASSIVES.puppetMap, SHADOWPASSIVES.puppets = ST.mapLoads, {}
    end
    local key = full(actor)
    local api = SHADOWPASSIVES.puppets[key]
    if not api then api = SHADOWPASSIVES.fork(); SHADOWPASSIVES.puppets[key] = api end
    return api
end
function SHADOWPASSIVES.puppetStep(actor, tn)
    if not valid(actor) then return end
    local api = SHADOWPASSIVES.forActor(actor)
    api.step(actor, tn)
end
function SHADOWPASSIVES.allowRemove(actor, path)
    local api = SHADOWPASSIVES.forActor(actor)
    if api.canRemove(actor, path) then return true end
    -- A successful journal removal may precede the old STD/wge bookkeeping cleanup.
    local snap = G.snapshotEffects(actor, {path})
    local e = snap.effects[path]
    return snap.complete and e and e.active == false
end

-- Local read-only part pilot; no connection to damage correction or CFG wire values.
DAMAGEPARTS = BASEPARTS.load('damageparts', { NET_DIR = NET_DIR, G = G,
    configDir = (FORNET_BASE and FORNET_BASE.dir) or (ROOT .. '/Scripts'),
    mapToken = function() return ST.mapLoads end,
    out = function(...) return out(...) end, hpOf = function(...) return hpOf(...) end,
    inScope = function()
        return NET.fighting() and BAL.active() and not PEER.on
            and not (BASEHOOK.inMp and BASEHOOK.inMp())
    end,
    sources = function()
        local j = NET.judges and NET.judges[#NET.judges]
        local incoming = (j and j.name) or (NET.lastHit and NET.lastHit.name) or BAL.last
        local id = PRED.myAttackId()
        return incoming, NET.evName and NET.evName[id], puppet()
    end })

-- §132 我锁没锁定对手（发 lk=）：GetLockingTarget 读不到时问瞄准组件；变了记一行（前 60 次），真人对战时好确认读对了
function NET.myLk(p1)
    local t, from = lockingTarget(p1)
    local v = t and 1 or 0
    if v ~= NET.myLkV then
        NET.myLkV = v
        NET.myLkLogs = (NET.myLkLogs or 0) + 1
        if NET.myLkLogs <= 60 then out("我%s锁定对手（%s）", v == 1 and "" or "取消", from or "两种都读不到锁定") end
    end
    return v
end

local function netSend(p1, tn)
    if CDL.active() then CDL.sample(p1) end         -- §173.12 读秒里记下按着的输入
    local act = activeAbilities(p1, NET.wantAb) or {}
    if NET.prevAbs then
        for n in pairs(act) do
            if not NET.prevAbs[n] then CTRD.onMine(n, tn) end      -- §396 红反链：我的红光反击出现
            if not NET.prevAbs[n] and HLFX and n == HLFX.NAME then pcall(HLFX.cast, "me", p1, n, tn) end  -- §246 火流星 DB：我放招（事件触发）
            if not NET.prevAbs[n] then SWK.note(n, tn); ABUF.onAbility(n, tn, true) end   -- §200.11 切武器（切刀斩）；§349 武器状态 / 放血计时
            if not NET.prevAbs[n] and SUMMON.armName and SUMMON.armName(n) then ST.p1SummonAt = tn end   -- §118 / §242 我放了召唤（认替身分身时用）
            if not NET.prevAbs[n] and isAttackAbility(n) then NET.lastMyAtk = n end   -- §230.1 最近一招攻击（硬直动作按它的武器选）
            if not NET.prevAbs[n] and RECM.replayable(n) and not LO.isSpecialMove(n)       -- §436.1 爬墙等走 trv= 发动作，不当招式发
                and not NOCTR.check(p1, n, tn)                                        -- §105.3 红蓝光反击关着时拦掉
                and not STG.check(p1, n, tn)                                          -- §161 硬直中出招拦掉
                and not CDL.check(p1, n, tn)                                          -- §173.7 倒计时里出招拦掉
                and not DCD.check(p1, n, act, tn)                                     -- §200 瞬影冷却中拦掉（普通闪避在这里扣杀气，§200.10）
                and not MCD.check(p1, n, tn) then                                     -- §426 招式冷却中拦掉（双刃第四段等）
                -- v0.27.2 大招先压住，看这一帧 / 下几帧的动作：C_Failed（没充能）就不发，放出来了才发（ULT.flushHeld）
                -- §375 影之武装同理：暗源不够播 ShachiWeapon_Failed 就不发（ULT.flushEdge）
                local held = ULT.isUlt(n) or LO.isEdgeAttack(n)
                if ULT.isUlt(n) then ULT.held[#ULT.held + 1] = { name = n, ts = LAT.ms(tn), n = 0 }
                elseif held then ULT.holdEdge(n, tn)
                else ULT.emit(n, tn, LAT.ms(tn)) end
                CHG.onMyFire(n, tn, isAttackAbility(n))     -- §409.2 我按着蓄力时放了下一招 = 松手
                if CHG.watched(n) then CHG.watch(p1, "我", n, tn, not held and NET.evId or nil) end   -- §92 松手检测 / 探针
            end
        end
    end
    -- v0.17.5 破防：本机游戏让我破防时（杀气被打空）会激活 GA_Hun_BreakEscape_C（破防挣脱）、播 MoTian_Dodge_*。
    -- 破防期间我本机不能防御 / 精防，这是游戏原生的；要做的只是让对方看见：发 brk=<次数>:<动作>
    if act["GA_Hun_BreakEscape_C"] and not (NET.prevAbs and NET.prevAbs["GA_Hun_BreakEscape_C"]) then
        local m = montageOf(p1)
        NET.brkN, NET.brkAt = (NET.brkN or 0) + 1, tn      -- §87 brkAt：破防期间软格挡不生效
        NET.brkM = (m:find("MoTian", 1, true) or m:find("Break", 1, true)) and m or "MoTian_Dodge_B_BanBen2_Montage"
        out("◆ 我破防了（第 %d 次，动作 %s）", NET.brkN, NET.brkM)
    end
    DCD.frame(p1, act, tn)          -- §200 我的瞬影停没停（停了开始冷却）
    if NET.prevAbs then for n in pairs(NET.prevAbs) do if not act[n] then ABUF.onAbility(n, tn, false) end end end   -- §349 招收掉：状态多在这时已挂上
    NET.prevAbs, NET.prevAbsTick = act, ST.ticks       -- 同一次驱动里观察玩家1 直接用（§82.1）
    if not NET.driving then CHG.mineStep(tn) end       -- §420 多人房 / 对决：我的蓄力松手检测（CHG.step 只在驱动替身时跑、跑的是对手那份）
    -- v0.18.3 受击动作：我本机游戏给我播的受击动作（轻击小顿 / 重击 / 击倒 / 击飞……）换成新的一个时次数 +1，
    -- 发 hr=<次数>:<动作名>，对方让替身播同一个
    local hm = montageOf(p1)
    if DSTAT then DSTAT.frame(p1) end
    BLK.watch(hm, act, tn)          -- §87 记"开始格挡"的时刻（软格挡按它分精防 / 普防）
    CTRD.frame(p1, hm, act, tn)     -- §396 红反链：之后能不能进架势
    CTRD.monFrame(p1, hm, act, tn)  -- §396 防御监视：Stance.Forbid 出现 / 解除、按着格挡没进架势
    CTRREC.frame(p1, hm, act, tn)   -- Guard-release fallback; never cancel skills or reset the input stack.
    if hm ~= NET.hrPrev and LO.isHitMontage(hm) then
        NET.hrN, NET.hrT = (NET.hrN or 0) + 1, hm
    end
    -- §103 喝药：喝药技能 GA_Medicine_* 被 replayable 排除了（替身真激活会扣药 / 回血），对面以前只看到血条涨。
    -- 改成发动作：喝药动作换成新的一个时次数 +1，发 med=<次数>:<动作名>，对方替身只播这个动作
    if hm ~= NET.hrPrev and LO.isMedMontage(hm) and not NOMED.block(p1, hm, tn) then   -- §108 禁用血瓶时拦掉、不发
        NET.medN, NET.medT = (NET.medN or 0) + 1, hm
    end
    NOMED.frame(p1, tn)
    -- §436 场景互动动作（爬墙 / 翻越…）：换成新的一个时次数 +1，发 trv=<次数>:<动作名>:<现在还在不在播>，对方替身照播、
    -- 播的时候高度也跟着包走（不然替身贴着墙根、到顶才一下摆上去）
    NET.trvOn = LO.isTraversalMontage(hm) or (hm ~= "" and LO.specialMoveOn(act))     -- §436.1 爬墙技能挂着时播的也算
    -- （按"这一段场景动作里发过的那个"比，不按上一帧：技能比动作晚一两帧才读到时，名单外的动作也能补发）
    if NET.trvOn and hm ~= NET.trvCur then NET.trvN, NET.trvT = (NET.trvN or 0) + 1, hm end
    NET.trvCur = NET.trvOn and hm or nil
    -- §111 技能里面按键换的动作（紫冥剑召唤）：换成新的一个时次数 +1，发 sub=<次数>:<动作名>，对方替身照播
    if hm ~= NET.hrPrev and (LO.isSubMontage(hm) or CHG.isLaserSub(hm, NET.hrPrev)) and GCD.mine(hm, tn) then    -- §139 加独眼弓激光；§184 冷却里的火枪不发
        NET.subN, NET.subT = (NET.subN or 0) + 1, hm
    end
    if SHIELD.mineSub(hm, NET.hrPrev) then NET.subN, NET.subT = (NET.subN or 0) + 1, hm end   -- 11-23 拙壁盾盾反 / 盾推 / 盾冲
    if CART.mineSub(hm, NET.hrPrev) then NET.subN, NET.subT = (NET.subN or 0) + 1, hm end     -- §434 泥头车力荡四方
    NET.luteSub = LUTE.mineSub(hm, NET.hrPrev)            -- §430 破阵曲每一段（带招式号）
    if NET.luteSub then NET.subN, NET.subT = (NET.subN or 0) + 1, NET.luteSub end
    SHOT.mine(p1, hm, NET.hrPrev, tn)   -- §377 羽弓 / 虎炮：每一发出手（带档位）和收招也走 sub=
    if hm ~= NET.hrPrev and LDASH.isMon(hm) then LDASH.start("我", p1, tn, hm) end   -- §448 移商换羽：我这边生成了哪些音刃
    GCD.frame(p1, hm, tn)           -- §184 火枪收没收掉（两边）+ 本机冷却里拦召唤 / 提示
    -- §118 闪避动作（往哪边翻）：换成新的一个时次数 +1，发 dg=<次数>:<动作名>，对方替身翻同一个方向
    if hm ~= NET.hrPrev and DGE.isDodge(hm) and not DCD.muted(tn) then     -- §200 刚拦掉的瞬影动作不发
        NET.dgN, NET.dgT = (NET.dgN or 0) + 1, hm
        NET.ddir = DDIR.mine(p1, hm)       -- §421 这次闪避身上的方向标签（对方替身放影武闪避招要用）
    end
    ZMX.fxProbe(p1, hm ~= NET.hrPrev and hm or nil, tn)     -- §119 以后查布局闪避的金光
    if hm ~= NET.hrPrev and hm:find("C_Failed", 1, true) then ULT.watch(p1, false, "我大招失败 " .. hm, tn) end   -- v0.27.1
    ULT.flushHeld(p1, hm, tn)          -- v0.27.2 压住的大招：放出来了才发
    ULT.flushEdge(p1, hm, tn)          -- §375 压住的影之武装：暗源不够（ShachiWeapon_Failed）不发
    NET.hrPrev = hm
    while #NET.events > 0 and tn - NET.events[1].at > EV_KEEP do table.remove(NET.events, 1) end

    local loc = try("net loc", function() return p1:K2_GetActorLocation() end)
    local rot = try("net rot", function() return p1:K2_GetActorRotation() end)
    if not (loc and rot) then return end
    local vx, vy = 0.0, 0.0
    local cm = rawProp(p1, "CharacterMovement")
    if valid(cm) then pcall(function() vx, vy = cm.Velocity.X, cm.Velocity.Y end) end
    local evs = {}
    for _, e in ipairs(NET.events) do evs[#evs + 1] = e.id .. ":" .. e.name end
    local res = {}
    for _, r in ipairs(NET.results) do res[#res + 1] = string.format("%d:%d:%s:%.0f", r.id, r.atk, r.kind, r.v) end
    local hp, hpm = hpOf(p1), attrOf(p1, "Health_Max")
    local sh, shm = attrOf(p1, "Shachi"), attrOf(p1, "Shachi_Max")    -- v0.24.0 对方用 Boss 血条显示我的杀气
    sh = SWK.frame(p1, tn, sh, shm)                                    -- §200.11 切武器保持杀气（写回了就发写回后的）
    if NET.barMode() < 2 then sh, shm = nil, nil end                   -- v0.25.0 房间设置不显示杀气 → 不发
    -- v0.16.0：攻击侧属性（配装同步），每 30 帧重算一次
    if not NET.attStr or ST.ticks % 30 == 0 then NET.attStr = LO.encode(p1) end
    -- v0.17.0：手上武器的 WeaponConfig 路径（每 0.5 秒读一次）和是否拔刀
    if not NET.wcStr or ST.ticks % 15 == 0 then
        NET.wcStr = LO.heldConfig(p1) or NET.wcStr
        NET.wcsStr = LO.heldConfig(p1, LO.slotShachi()) or NET.wcsStr      -- v0.17.4 当前影之武装
    end
    -- v0.17.2：生效的天赋 / 饰品被动（每 3 秒重算）
    if not NET.pasStr or ST.ticks % 90 == 0 then NET.pasStr = LO.encodePas(p1) end
    -- §163 换了武器 / 影之武装（wc= / wcs= 变了）5 帧后也重算：影之武装的升级只在装着时挂在身上，换上马上放招时别等 3 秒
    if NET.wgeW ~= (NET.wcStr or "") .. "|" .. (NET.wcsStr or "") then
        NET.wgeW, NET.wgeAt = (NET.wcStr or "") .. "|" .. (NET.wcsStr or ""), ST.ticks + 5
    end
    if ABUF.wgeDue(ST.ticks) or not NET.wgeStr or ST.ticks % 90 == 30 or ST.ticks == NET.wgeAt then NET.wgeStr = LO.encodeWge(p1) end    -- §118 武器效果（升级 / 形态 GE）；§349 这几把武器的招放 / 收后几帧也算
    -- §109 皮肤（每 3 秒读一次；只在菜单里能换）
    if NET.ofStr == nil or ST.ticks % 90 == 45 then NET.ofStr = LO.encodeOutfit(p1) or "" end
    NET.seq = NET.seq + 1
    fileWrite(F_LOCAL, string.format(
        "v=2\nseq=%d\nmap=%s\nx=%.1f\ny=%.1f\nz=%.1f\nyaw=%.1f\nvx=%.1f\nvy=%.1f\nw=%s\nev=%s\nhp=%.1f\nhpm=%.1f\nres=%s\n"
        .. "mt=%s\narena=%s\ndead=%d\nrdy=%d\nquit=%d\natt=%s\nwc=%s\narm=%d\npas=%s\nwcs=%s\nbrk=%d:%s\nhr=%d:%s\nlk=%d\nsq=%.1f\nshm=%.1f\nasp=%s\n",     -- §276 杀气走 sq=（sh= 是 §174 身份字段，联机程序发包前会删）
        NET.seq, mapName(p1), loc.X, loc.Y, loc.Z, rot.Yaw, vx, vy, ST.p1Weapon or STD.idOf(NET.wcStr) or "",     -- §155 没切过武器时按手上配置
        table.concat(evs, ","),
        hp or -1, hpm or -1, table.concat(res, ","), MATCH.wire.mt, MATCH.wire.arena, MATCH.wire.dead,
        MATCH.wire.rdy, MATCH.wire.quit, NET.attStr or "", NET.wcStr or "", LO.armed(p1) and 1 or 0, NET.pasStr or "", NET.wcsStr or "", NET.brkN or 0, NET.brkM or "-", NET.hrN or 0, NET.hrT or "-",
        NET.myLk(p1),                    -- v0.23.3 lk=1：我锁定着对手（对方据此让替身出招时追着他）；§132 也问瞄准组件
        sh or -1, shm or -1, MATCH.wire.asp or "")         -- §238 开战点
        .. AIR.wire(AIR.airOf(p1))      -- v0.24.2 air= / vz=：我在不在空中、竖直速度
        .. "bar=" .. NET.barCfg .. "\n"    -- v0.25.0 我的对手血条档位（只有主机的算数）
        .. FMATCH.wireExtra()              -- 规则来源 / 扩展加的字段（排位：rkd= 客机复核对不上的次数，pbz_ranked.lua）
        .. "bo=" .. NET.boCfg .. "\n"      -- v0.26.3 我的局数设置（只有主机的算数）
        .. "dm=" .. NET.dmCfg .. "\n"      -- §86 我的伤害倍率设置（只有主机的算数）
        .. "ab=" .. NET.abCfg .. "\n"      -- §87 我的"全部可格挡"设置（只有主机的算数）
        .. "ctr=" .. NET.flagCfg.ctr .. "\n"   -- §105.3 我的"红蓝光反击"设置（只有主机的算数）
        .. "bal=" .. NET.flagCfg.bal .. "\n"   -- §106.5 我的"武器平衡"设置（只有主机的算数）
        .. "medok=" .. NET.flagCfg.med .. "\n"   -- §108 我的"血瓶"设置（只有主机的算数；med= 已经是喝药动作）
        .. "npos=" .. NET.flagCfg.npos .. "\n"  -- §128.2 我的"对手位置严格跟随"设置（只有主机的算数）
        .. "std=" .. NET.flagCfg.std .. "\n"    -- §144 我的"标准数值"设置（只有主机的算数）
        .. "gcd=" .. NET.flagCfg.gcd .. "\ndgc=" .. NET.flagCfg.dgc .. "\nsycd=" .. NET.flagCfg.sycd .. "\nstg=" .. NET.flagCfg.stg .. "\nswk=" .. NET.flagCfg.swk .. "\npdsh=" .. NET.flagCfg.pdsh .. "\n"   -- §216 / §228 精防硬直 我的火枪冷却 / 闪避扣杀气 / 瞬影冷却设置（只有主机的算数）
        .. "cfgh=" .. CFG.wire() .. "\n"       -- §158 我的数值表哈希（只有主机的算数；客机对不上就来要）
        .. "rfp=" .. RFP.wire() .. "\n"       -- §210 这一场的规则指纹（对方比；联机程序排位时报给服务器）
        .. "ult0=" .. NET.resCfg.ult0 .. "\nsp0=" .. NET.resCfg.sp0 .. "\nresm=" .. NET.resCfg.resm .. "\n"   -- §113 我的开局精纯杀气 / 暗源 / 每场每局（只有主机的算数）
        .. "ultx=" .. NET.resCfg.ultx .. "\n"   -- §113.4 我的精纯杀气获取倍率 %（只有主机的算数）
        .. "acc=" .. NET.resCfg.acc .. "\n"     -- §170.1 我的饰品等级设置（只有主机的算数）
        .. (ST.ext and ST.ext.wire() or "")     -- X1 扩展包的 x.<包>.<键>= 段（基底不解释，对方没装就忽略）
        .. (FORNET and FORNET.modsys and FORNET.modsys.wire() or "")   -- L1 玩法 mod 的 x.<mod>.<键>= 段（对方没装那个 mod 就不发）
        .. "accn=" .. NET.resCfg.accn .. "\naccban=" .. NET.accBanCfg .. "\n"   -- §176 我的生效饰品数量 / 禁用饰品（只有主机的算数）
        .. "wpnban=" .. WBAN.cfg.wpnban .. "\nedgeban=" .. WBAN.cfg.edgeban .. "\n"   -- §180 我的禁用武器 / 影之武装（只有主机的算数）
        .. WBAN.wire()                                                        -- §180 我装着的 wpn=<武器,武器> / edg=<影武,影武>（主机开局前复核）
        .. "med=" .. (NET.medN or 0) .. ":" .. (NET.medT or "-") .. "\n"   -- §103 喝药动作（次数:动作名）
        .. "trv=" .. (NET.trvN or 0) .. ":" .. (NET.trvT or "-") .. ":" .. (NET.trvOn and 1 or 0) .. "\n"   -- §436 场景互动动作（次数:动作名:还在播）
        .. "sub=" .. (NET.subN or 0) .. ":" .. (NET.subT or "-") .. "\n"   -- §111 技能里面换的动作（紫冥剑召唤；次数:动作名）
        .. "dg=" .. (NET.dgN or 0) .. ":" .. (NET.dgT or "-") .. "\n"     -- §118 闪避动作（次数:动作名）
        .. "ddir=" .. (NET.ddir or "-") .. "\n"                           -- §421 那次闪避的方向标签 F/B/L/R/N
        .. "tl=" .. NET.resCfg.tl .. "\n"                                  -- §173 我的回合时限设置（只有主机的算数）
        .. "pdshv=" .. NET.resCfg.pdshv .. "\n"                            -- §423.1 我的精防掉杀气数量（只有主机的算数）
        .. "stgm=" .. NET.resCfg.stgm .. "\nstgr=" .. NET.resCfg.stgr .. "\n"   -- §422.1 我的精防硬直秒数 近战 / 远程（只有主机的算数）
        .. "dif=" .. NET.resCfg.dif .. "\n"                             -- §266 我的对局难度设置（只有主机的算数）
        .. "tk=" .. RT.wire() .. "\n"                                      -- §173 这一回合交手后我受到的伤害（回合:累计），主机按它判时间到
        .. "inf=" .. INF.mine(p1, tn) .. "\n"                               -- §160 我身上的异常状态（类型:次数:段:积累,…），对方替身跟着
        .. "wge=" .. (NET.wgeStr or "") .. "\n"                                -- §118 我身上的武器效果 GE（替身也上）
        .. ABUF.zmWire(tn)                                                 -- §349 zmb=<伤害加成>:<杀气加成>：我的斩马刀损血增伤（有这件升级才发）
        .. "gd=" .. (BLK.on and 1 or 0) .. "\n"                            -- §104 我在不在格挡（对方据此预测替身的反应）
        .. "tc=" .. TOUCH.wire(tn) .. "\n"                                 -- §107 我哪几招在本机碰到了替身（本地 AI 据此回报）
        .. "td=" .. TOUCH.wireDmg() .. "\n"                                -- §115 这几招在本机打出的伤害（已乘系数，本地 AI 按它扣血）
        .. (AISYNC and AISYNC.wire(tn) or "")                              -- §352 act= / pst=：我还在放的招、替身挨打 / 被控（只对本地 AI 发）
        .. "aim=" .. BOWAIM.wire() .. "\n"                                 -- §139.3 放独眼弓时我的镜头朝向（俯仰:左右）
        .. "eye=" .. BOWEYE.wire(p1, tn) .. "\n"                              -- §139.9 我的光柱有没有眼睛（1 / 0 / - 还没数过）
        .. SHOT.wire()                                                     -- §377 shs=1：我会把羽弓 / 虎炮的每一发发出来
        .. "wlv=" .. STD.wireLv() .. "\n"                                 -- §148 我手上武器 / 影之武装的等级（对方替身按它补等级倍率）
        .. (NET.ofStr ~= "" and ("of=" .. NET.ofStr .. "\n") or "")        -- §109 我的皮肤（行名:肤色:帽子）
        .. LAT.wire(tn, NET.events)        -- v0.27.0 ts= / tse= / evt=：测往返和包龄
        .. CHG.wire(tn)                    -- §92 rel=<招式号>:<按了几秒>：蓄力招松手
        .. (BASEHOOK.ask("base.wire", tn) or ""))     -- L5：往上加的 mod 往状态包里加字段（多人：mpd= 我这回合倒没倒；主机另带 mpm= 对局状态 / 比分）
end

-- §83 连着管道：这次驱动之前收到的每个包都按顺序过一遍（LAT.onPacket 每个包一次，包龄 / 往返照算）；
-- 没连：照旧读文件里最新的那一个
-- §性能（11-19 用户"动不动突然卡住"）：一帧最多处理 RX_MAX 个包，剩下的按原顺序排到下一帧。
-- 切图 / 卡顿后联机程序一次能给 48 个（GamePipe.MaxQueue），以前一帧全做完 → 单帧 200–1000 ms（日志 收包 344/580/993 ms），
-- 越卡下一帧越重。单包报错也只丢那一个，不再让整个收包循环中断。
NET.RX_MAX, NET.rxq, NET.rxErrN = 12, nil, 0
local function netRecv(p1, tn)
    local list = PIPE and PIPE.recv()
    if not list then list = { fileReadKV(F_REMOTE) } end
    local q = NET.rxq
    if q and #q > 0 then
        for i = 1, #q do list[#list + 1] = q[i] end
        NET.rxq = nil
    end
    local n, maxn = #list, NET.RX_MAX
    if n > maxn then
        local rest = {}
        for i = maxn + 1, n do rest[#rest + 1] = list[i] end
        while #rest > 120 do table.remove(rest, 1) end      -- 保险：真积压太多就丢最旧的（位置类包下一包会补上）
        NET.rxq = rest
        n = maxn
    end
    for i = 1, n do
        local t = list[i]
        local ok, err = pcall(function()
            if t.src and t.src:match("^%d+$") then
                -- 多人混战 ②b：多人房间的包（src = 玩家编号，主机 1）交给 pbz_multi.lua，每个编号一个替身
                BASEHOOK.emit("base.feedMp", t, tn)     -- L5：多人 mod 订阅
            elseif t.src then
                BASEHOOK.emit("base.feedSrc", t, tn)     -- L3：观战 mod 订阅
            else
                NET.recvOne(p1, tn, t)
            end
        end)
        if not ok then
            NET.rxErrN = (NET.rxErrN or 0) + 1
            if NET.rxErrN <= 20 then out("!! 收包 -> %s", tostring(err)) end
        end
    end
end

-- §295 多人 / 对决的屏幕文字：对决的比分行 + 规则指纹对不上的横幅（1v1 那条在 matchStep 的对局分支里）
function NET.mpHudRows(tn)
    local sm = BASEHOOK.mp
    if not sm then return nil end
    local rows = sm.hudRows and sm.hudRows(tn) or nil
    -- §310（11-14 实测）：计分板 / 剩余时间 / 对决排队这类常驻信息放屏幕右侧；要你马上做事的（center=true）和一次性提示留在中间
    -- 11-17 排查补齐：房间倒计时里我上场时，同旧版 1v1 显示"不是默认值的规则"（伤害倍率、全部可格挡、禁用血瓶、数值表、饰品、禁用名单、开局资源…）
    if rows and sm.inMatch and sm.inMatch() then
        local d = sm.duelInfo and sm.duelInfo()
        local inCd = (d and d.fighter and d.state == "cd") or (sm.cdActive and sm.cdActive())
        if inCd then
            for _, r in ipairs(NET.rulesRows(0.75, true)) do rows[#rows + 1] = r end     -- 这里看不见下面的 T / COL_* / CFG，全在 NET.rulesRows 里拼
        end
    end
    for _, r in ipairs(rows or {}) do if not r.center then r.side = true end end
    local on = sm.rfpCtx and sm.inMp and sm.inMp() and sm.rfpCtx()
    local rr = on and RFP.rows() or nil
    -- §309（11-14 实测）：屏幕上只画 panel / mpHudRows / idleRows 三选一，一次性提示（MATCH.toast）只在 idleRows 里，
    -- 所以对决 / 多人对局有常驻行时所有提示都看不见（"再按一次 F1 认输"、"开战！"、"本回合胜 / 负"、"你倒下了"、
    -- 出生保护、"离战场太远"……）。有提示时放在常驻行上面一起画
    local toast = (rows or rr) and MATCH.toast and tn < (MATCH.toast.till or 0) and MATCH.toast.rows or nil
    -- §319（11-15 实测）"火枪还在场 / 火枪冷却中"、"瞬影冷却中"以前只挂在旧 1v1 的 matchRows，多人房 / 新版 1v1 拦住了也没字；
    -- 交手中有常驻行时放在中间（要你马上知道的）
    local cdr = nil
    if rows and NET.fighting() then
        local orange = { R = 255, G = 140, B = 40, A = 255 }
        local X = EXTCTX                                   -- 这里看不见面板段的 local T（main-lua 末尾块规矩），走 EXTCTX
        local tr = (X and X.T) or function(zh) return zh end
        local gh = GCD.hint(tn)
        if gh then cdr = { { c = tr(gh[1], gh[2]), col = orange, size = 0.8, nolog = true, center = true } } end
        for _, dh in ipairs(DCD.hintRows(tn) or {}) do
            cdr = cdr or {}
            cdr[#cdr + 1] = { c = tr(dh[1], dh[2]), col = orange, size = 0.8, nolog = true, center = true }
        end
    end
    if not rr and not toast and not cdr then return rows end
    local o = {}
    for _, r in ipairs(cdr or {}) do o[#o + 1] = r end
    for _, r in ipairs(toast or {}) do o[#o + 1] = r end
    for _, r in ipairs(rows or {}) do o[#o + 1] = r end
    for _, r in ipairs(rr or {}) do o[#o + 1] = r end
    return o
end

function NET.recvRules(t)
    if not t then return end
    -- v0.25.0 对方的血条档位（我是客机时按它走）、对方联机程序版本（av=，v0.22.0 起才有；空 = 更旧）
    local rb = tonumber(t.bar)
    if rb ~= NET.rbar then
        if NET.ruleClient() and rb then out("对手血条：主机设为 %d（2 血量+杀气 / 1 只显示血 / 0 不显示）", rb) end
        NET.rbar = rb
    end
    if not PEER.on then
        CFG.onPacket(t.cfgh, now())     -- §158 主机的数值表哈希：对不上就经可靠通道要一份
        RFP.onPacket(t.rfp, now())      -- §210 对方这一场的规则指纹：和我的比
    end
    local rbo = tonumber(t.bo)      -- v0.26.3 对方的局数设置（我是客机时按它走）
    if rbo ~= NET.rbo then
        if NET.ruleClient() and rbo then out("局数：主机设为 %d 局（先赢 %d 回合）", rbo, NET.toWin(rbo)) end
        NET.rbo = rbo
    end
    local rdm = tonumber(t.dm)      -- §86 对方的伤害倍率（我是客机时按它走）
    if rdm ~= NET.rdm then
        if NET.ruleClient() and rdm then out("伤害倍率：主机设为 %d%%（下一局生效）", rdm) end
        NET.rdm = rdm
    end
    local rab = tonumber(t.ab)      -- §87 对方的"全部可格挡"设置（我是客机时按它走）
    if rab ~= NET.rab then
        if NET.ruleClient() and rab then out("全部可格挡：主机设为%s", rab == 1 and "开" or "关") end
        NET.rab = rab
    end
    for _, k in ipairs(NET.FLAG_KEYS) do   -- §105.3 / §106.5 / §108 对方的开关型设置（我是客机时按它走）
        local r = tonumber(t[NET.FLAG_WIRE[k] or k])
        if r ~= NET.rflag[k] then
            if NET.ruleClient() and r then
                out("%s：主机设为%s（下一局生效）", NET.FLAG_NAME[k][1], r == 1 and "开" or "关")
            end
            NET.rflag[k] = r
        end
    end
    for _, k in ipairs(NET.RES_KEYS) do    -- §113 对方的开局精纯杀气 / 暗源（我是客机时按它走）
        local r = tonumber(t[k])
        if r ~= NET.rres[k] then
            if NET.ruleClient() and r then out("%s：主机设为 %s（下一局生效）", NET.RES_NAME[k][1], NET.resText(k, r)[1]) end
            NET.rres[k] = r
        end
    end
    if t.accban ~= NET.raccban then        -- §176 对方的禁用饰品（我是客机时按它走）
        if NET.ruleClient() and t.accban then out("禁用饰品：主机设为 %s（下一局生效）", ACC.banText(t.accban, 1)) end
        NET.raccban = t.accban
    end
    if PEER.on then return end
    WBAN.recv(t)                           -- §180 主机的禁用武器 / 影之武装名单 + 对方装着的 wpn= / edg=
    -- §453：对决房的规则串（pbz_duel feedRules，@duel@1:ru|…）和多人房房主的包也走这里，它们不带 av=；
    -- 以前把"没带"当"v0.21 及以前"，11-25 22:29:18 对 0.34.13 的房主误报版本不一致。没带 av= 就不判断
    -- （多人房每人的版本由 pbz_multi 按状态包的 av= 单独比）
    if t.av ~= nil and t.av ~= NET.rav then
        NET.rav = t.av
        if NET.rav ~= VERSION then out("!! 版本不一致：我 v%s，对方 v%s", VERSION, NET.rav ~= "" and NET.rav or "0.21 及以前") end
    end
end

-- §436 对方的场景互动动作 trv=<次数>:<动作名>:<还在播 1/0>（旧版没有这个字段 = 什么都不做）。
-- 新的一个 → 替身照播（第一次收到只记次数，同 med=）；还在播 → NET.rtrv：NPM.frame 这段时间高度也跟包走、替身不受重力，
-- AIR 不按"对方在空中"让替身起跳（爬墙那几秒对方的移动组件可能报在空中，替身起跳会画一道弧）
NET.TRV_LOG_MAX = 60
function NET.recvTrv(t, tn)
    local n, m, on = (t.trv or ""):match("^(%d+):([%w_%-]+):?([01]?)$")
    n = tonumber(n)
    if not n then NET.rtrv = false; return end
    if NET.trvIn and n > NET.trvIn and m ~= "-" and not REP.on then      -- §436.1 发送方已把关（爬墙技能挂着时名单外的动作也发）
        montageByName(m, true)          -- 表里没有就重扫一次（最多 2 秒一次）
        local ok = playNamed(puppet(), m)
        NET.trvLogs = (NET.trvLogs or 0) + 1
        if NET.trvLogs <= NET.TRV_LOG_MAX then
            out("  %s对方场景动作 %s%s → 替身 %s", PEER.on and PEER.cur and ("[" .. tostring(PEER.cur.tag) .. "] ") or "", m,
                n > NET.trvIn + 1 and string.format("（中间漏了 %d 个）", n - NET.trvIn - 1) or "",
                ok and "已播" or "播放失败（本机没有这个动作）")
        end
    end
    NET.trvIn = n
    NET.rtrv = on == "1"
    if NET.rtrv then
        NET.rtrvAt = tn
        AIR.rair = false
    end
end

function NET.recvOne(p1, tn, t)
    if not (t and t.x and t.v == "2") then return end
    local seq = tonumber(t.seq) or -1
    -- §85 对手从 AI 换成真人（AI 对战时开着的房间有人进来，联机程序把它转正了）：序号 / 事件号都是另一个人的，当新连接；
    -- 结束 AI 那局、换替身在 aiSwapStep。§85.5：昵称变了也算（tests\fake_remote.py 当真人时自己也带 ai=1，序号还和 AI 一样从 500000 起）
    local swap = not PEER.on and NET.rai and (t.ai ~= "1" or (t.nm or "") ~= (NET.rnm or ""))
    if swap then
        out("对手从 AI 换成真人（%s），按新连接处理", tostring(t.nm))
        NET.lastSeq, NET.aiSwap = -1, "real"
        NET.swapName = (t.nm and t.nm ~= "") and t.nm or nil
        -- §116 我是客机 = 是我从 AI 对战里去加入了别人的房间（16:36 实测：点了大厅里 Q317 的房间，却提示"Q317 加入了你的房间"）
        NET.swapAsClient = MATCH.role == "client" or (MATCH.session and MATCH.session.role) == "client"
    elseif not PEER.on and not NET.rai and t.ai == "1" and (t.aiback or "") ~= "" then
        -- 真人离开后联机程序重开的 AI（包里 aiback= 离开的人的昵称）：提示"XXX 已离开房间，AI 对战已重新开始"
        out("真人对手 %s 离开，AI 对战重新开始", t.aiback)
        NET.lastSeq, NET.aiSwap, NET.swapName = -1, "ai", t.aiback
    end
    if seq == NET.lastSeq then return end
    if seq < NET.lastSeq then
        if seq > NET.lastSeq - 100 then return end   -- 乱序到达的旧包，丢掉
        out("远端序号回退 %d -> %d（对方重启了？），重置", NET.lastSeq, seq)
        NET.lastEvIn, NET.wTried, NET.lastResIn, NET.brkIn, NET.hrIn, NET.medIn, NET.subIn, NET.resAtk = 0, nil, 0, nil, nil, nil, nil, {}
        NET.resSeen = {}                              -- §370 收过的结果号跟着清
        LAT.reset(); CHG.reset(); PRED.reset(); DGE.nIn = nil; DDIR.nIn, DDIR.dir = nil, nil; INF.reset(); GCD.reset("对方重启"); DCD.reset("对方重启")     -- §184 / §200
    end
    if NET.lastSeq == -1 or NET.lastRecvAt < tn - 5 then
        out("开始收到远端 v2 状态 seq=%d 地图=%s 武器=%s", seq, tostring(t.map), tostring(t.w))
        NET.rwcCur, NET.rwcOff = nil, nil       -- v0.26.1 新连接：另一把等对方切一次武器才知道
        LO.switchBad, LO.has = nil, nil         -- §195 切序号这条路每次连接重新试
        -- v0.18.2（17:13 实测）：换了个对手 / 对方重启后序号反而更大时，上面的"序号回退"不触发，招式号还停在上一个对手的 #14，
        -- 新对手的 #1–#14 全被当成"已处理"丢掉。断了 5 秒以上再收到就算新连接，各计数清零（旧事件早超过 EV_KEEP 了）
        NET.lastEvIn, NET.wTried, NET.lastResIn, NET.brkIn, NET.hrIn, NET.medIn, NET.subIn, NET.resAtk = 0, nil, 0, nil, nil, nil, nil, {}
        NET.resSeen = {}                              -- §370 收过的结果号跟着清
        LAT.reset(); CHG.reset(); PRED.reset(); DGE.nIn = nil; DDIR.nIn, DDIR.dir = nil, nil; INF.reset()      -- §104 换了对手：防住率从先验重新学
        if not PEER.on then                   -- §223 观战替身（PEER.run 里）不碰对局 / 判定的状态（LAT / PRED / INF 是它自己那份）
            GCD.reset("换对手 / 新连接")      -- §184 火枪冷却清零
            DCD.reset("换对手 / 新连接")      -- §200 闪避冷却清零
            RFP.reset()                       -- §210 上一个对手的规则指纹不算
        end
    end
    NET.lastSeq, NET.lastRecvAt, NET.rx = seq, tn, NET.rx + 1
    if FORNET and FORNET.modsys and not PEER.on then FORNET.modsys.onPacket(t) end   -- L1 玩法 mod 的 x.<mod>.<键>= 字段（值变了才通知）
    local pktAge = LAT.onPacket(t, tn)                                        -- v0.27.0 往返 / 时钟差 / 包龄
    -- v0.27.0 evt=<招式号:对方出招时的 ts>：这招晚到了多久（没有 = 按这一包的包龄）
    local evt = {}
    for id, ts in (t.evt or ""):gmatch("(%d+):(%-?%d+)") do evt[tonumber(id)] = tonumber(ts) end
    local list = {}
    for id, name in (t.ev or ""):gmatch("(%d+):([%w_]+)") do
        local ets = evt[tonumber(id)]
        list[#list + 1] = { id = tonumber(id), name = name, rcv = tn, age = ets and LAT.age(ets, tn) or pktAge }
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    NET.pos = { X = tonumber(t.x) or 0, Y = tonumber(t.y) or 0, Z = tonumber(t.z) or 0 }
    NET.yaw = tonumber(t.yaw) or 0.0
    local vel = { X = tonumber(t.vx) or 0, Y = tonumber(t.vy) or 0 }
    LAT.onVel(NET.vel, vel, tn)                                                -- v0.27.0 急转 → 暂不外推
    NET.vel = vel
    NET.rmt, NET.rarena, NET.rdead = t.mt, t.arena, tonumber(t.dead) or 0     -- M4 对局字段，matchStep 处理
    if t.asp ~= NET.rasp then NET.rasp = t.asp; ARN.refresh(p1, "主机的开战点变了") end      -- §238 主机的开战点（旧版没有）
    if not PEER.on then RT.onPacket(t) end                                     -- §173 对方这一回合受到的伤害 tk=
    BOWAIM.recv(t.aim, tn)
    SHOT.recv(t.shs, t.dyb)                                                    -- §377 对方会不会发羽弓 / 虎炮的每一发（§427 dyb= 普通独眼弓）
    BOWEYE.recv(t.eye)                                                     -- §139.9 对方的光柱有没有眼睛                                                     -- §139.3 对方放独眼弓时的镜头朝向
    NET.rlk = t.lk == "1"                                                      -- v0.23.3 对方锁定着我（旧版没有这个字段 = 不追）
    if not PEER.on then
        NET.rai = t.ai == "1"                                                      -- v0.26.0 对方是 AI（本地 AI / 测试假对手）：回合倒计时才强制归位
        NET.rdummy = NET.rai and t.dummy == "1"                                    -- §342 对方是测伤木桩（本地 AI 难度"木桩"）
        NET.rtrainReturn = NET.rdummy and t.trainReturn ~= "0"
        NET.rtrainHpRegen = NET.rdummy and t.trainHpRegen ~= "0"
        NET.rtrainChi = NET.rdummy and t.trainChi or nil
        NET.rtrainGuard = NET.rdummy and t.trainGuard or nil                        -- §456 木桩自动格挡（预播格挡动作挑精防 / 普防）
        NET.rtrainUlt = NET.rdummy and t.trainUlt or nil                            -- §456 木桩精纯杀气：inf / 3 / 2 / 1
        NET.rtrainSp = NET.rdummy and t.trainSp or nil                              -- §456 木桩暗源：inf / 6 / 3 / 2 / 1
        NET.rtrainAiChi = NET.rai and t.trainAiChi == "1"
        NET.rtrainUnsupported = NET.rdummy and t.trainUnsupported or nil
    end
    NET.rrly = t.rly                                                           -- §276 主机下场时我是第一位（h）：代主机开局
    NET.rnm = t.nm                                                             -- §85.5 对方昵称（联机程序加的 nm=）：AI 换人看它变没变
    if t.gd == "1" then NET.rgd = true elseif t.gd == "0" then NET.rgd = false else NET.rgd = nil end   -- §104 对方在不在格挡（旧版 = nil）
    AIR.rair, AIR.rvz = AIR.parse(t)                                           -- v0.24.2 对方在不在空中（旧版 = nil）
    NET.rrdy, NET.rquit, NET.rmap = tonumber(t.rdy) or 0, tonumber(t.quit) or 0, t.map  -- v0.13.1 准备 / 退出 / 对方地图
    NET.ratt = t.att                                                                    -- v0.16.0 对方攻击侧属性
    -- v0.17.5 对方破防：替身只播破防动作（模组自己播，不会被"掐掉本机反应"掐掉），不让它真进破防状态 → 本机不会出处决提示。
    -- 第一次收到只记次数不播（刚连上 / 对方重启）
    local bn, bm = (t.brk or ""):match("^(%d+):([%w_]+)$")
    bn = tonumber(bn)
    if bn then
        if NET.brkIn and bn > NET.brkIn and bm ~= "-" then
            local pupB = puppet()
            local okB = valid(pupB) and not REP.on and playNamed(pupB, bm)
            NET.rbrkAt = tn       -- §104 破防动作优先级高于判定结果 / 预测
            out("◆ 对方破防（第 %d 次）→ 替身播 %s：%s", bn, bm, okB and "已播" or "失败")
        end
        NET.brkIn = bn
    end
    -- §103 对方喝药 → 替身只播喝药动作，不激活喝药技能（不扣药、不回血；血量照旧按 hp=）。第一次收到只记次数
    local mn, mm = (t.med or ""):match("^(%d+):([%w_%-]+)$")   -- 还没喝过 = "0:-"
    mn = tonumber(mn)
    if mn then
        if NET.medIn and mn > NET.medIn and LO.isMedMontage(mm) and not REP.on then
            local okM = playNamed(puppet(), mm)
            out("  对方喝药 %s → 替身 %s", mm, okM and "已播" or "播放失败（本机没有这个动作）")
        end
        NET.medIn = mn
    end
    NET.recvTrv(t, tn)          -- §436 对方的场景互动动作（爬墙 / 翻越…）：替身照播；还在播时不按"在空中"起跳
    -- §111 对方技能里面换的动作（紫冥剑召唤武器）→ 替身照播（动作自己带召唤 / 伤害的通知）。第一次收到只记次数。
    -- 动作是替身放 DB 时才加载的，表里没有就重扫一次；播过的记进这一招的 f.mon，判定窗口接着等（CHG.keepJudge）
    local sn, sm = (t.sub or ""):match("^(%d+):([%w_%-]+)$")
    sn = tonumber(sn)
    if sn then
        local laser = CHG.isLaserIn(sm)                  -- §139 独眼弓激光的光束 / 松手那一箭
        if NET.subIn and sn > NET.subIn and SHOT.isWire(sm) and not REP.on then      -- §377 羽弓 / 虎炮的一发 / 收招
            local okW, errW = pcall(SHOT.onSub, puppet(), sm, tn)
            if not okW then out("§377 对方出手 %s 处理出错：%s", sm, tostring(errW)) end
        elseif NET.subIn and sn > NET.subIn and SHIELD.isSub(sm) and not REP.on then          -- 11-23 拙壁盾盾反 / 盾推 / 盾冲
            local okZ, errZ = pcall(SHIELD.onSub, p1, puppet(), sm, tn, pktAge)
            if not okZ then out("盾反同步出错：%s", tostring(errZ)) end
        elseif NET.subIn and sn > NET.subIn and CART.isSub(sm) and not REP.on then            -- §434 泥头车力荡四方
            local okC, errC = pcall(CART.onSub, p1, puppet(), sm, tn)
            if not okC then out("力荡同步出错：%s", tostring(errC)) end
        elseif NET.subIn and sn > NET.subIn and LUTE.isSub(sm) and not REP.on then            -- §430 破阵曲每一段
            local okL, errL = pcall(LUTE.onSub, p1, puppet(), sm, tn)
            if not okL then out("§430 破阵曲同步出错：%s", tostring(errL)) end
        elseif NET.subIn and sn > NET.subIn and (laser or LO.isSubMontage(sm)) and not REP.on then
            local pupS = puppet()
            montageByName(sm, true)
            local called, how, skip
            if not laser and sn > NET.subIn + 1 and not PEER.on then GDMG.noteOther("op", "中间漏了召唤动作", tn) end   -- §212 漏掉的可能是锤 / 伞
            if not laser then called, how, skip = ZMX.onSub(pupS, sm, tn) end   -- §119 让替身的技能自己召唤；调成了就不再照播动作（§184 火枪冷却 skip）
            local okS = called or playNamed(pupS, sm)
            if okS and not skip then
                local want, fid = laser and CHG.LASER.name or "GA_Hun_ZiMingJian_New_DB_C", nil
                for id, f in pairs(CHG.fired) do if f.name == want and (not fid or id > fid) then fid = id end end
                if fid then CHG.fired[fid].mon[sm] = true end
                if fid and laser and sm == CHG.LASER.shoot then CHG.fired[fid].shotAt = tn end   -- §139 对方光束照完（松手 / 暗源用完）
            end
            out("  对方技能内动作 %s%s → 替身 %s", sm, sn > NET.subIn + 1 and string.format("（中间漏了 %d 个）", sn - NET.subIn - 1) or "",
                called and how or okS and "已播" or "播放失败（本机没有这个动作）")
        end
        NET.subIn = sn
    end
    -- v0.18.3 对方的受击动作 → 替身播同一个（模组自己播的不会被"掐掉本机反应"掐掉）。第一次收到只记次数
    local hn2, ht2 = (t.hr or ""):match("^(%d+):([%w_%.]+)$")
    hn2 = tonumber(hn2)
    if hn2 then
        -- §389 对方只是被点燃 / 流血跳了一下：hr= 不镜像（不播受击、也不记成"对方被打断"）。真刀同一包会带新的中招结果
        local tickHr = DTICK and DTICK.hrSkip and DTICK.hrSkip(t, ht2, tn)
        if NET.hrIn and hn2 > NET.hrIn and LO.isHitMontage(ht2) and not REP.on and not tickHr then
            -- v0.23.1 对方在自己的游戏里真被打出受击 = 他那一刀被打断了：替身正在重放的招式立刻停掉（不淡出），
            -- 不然受击动画盖在上面、伤害窗口还开着，照样砍中玩家
            local busy = puppetAttacking(puppet())
            if busy then
                out("  对方被打断：替身停招 %s（动作 %s）", busy, tostring(cutMontage(puppet())))
            end
            local okH = playNamed(puppet(), ht2)
            NET.lastHrAt, NET.lastHrTag = tn, ht2
            out("  对方受击动作 %s → 替身 %s", ht2, okH and "已播" or "播放失败（本机没有这个动作）")
        end
        NET.hrIn = hn2
    end
    NET.rwc = (t.wc and t.wc ~= "") and t.wc or nil                                     -- v0.17.0 对方手上的 WeaponConfig
    if t.w and t.w ~= "" then NET.rwId = t.w end      -- §456.1 对方武器 ID：走 SetSlotWeapon 那条路时 ST.pupWeapon 不写，DEFANIM 靠它挑大类
    if NET.rwcPin then                                  -- §165.4 切刀斩刚换上的那把，1.5 秒内不让旧的 wc= 换回去
        if now() < NET.rwcPin.t then NET.rwc = NET.rwcPin.cfg else NET.rwcPin = nil end
    end
    -- v0.26.1 对方武器组的另一把（§76）：真人在组里两把之间切，上一把拿过的不同武器就是另一格。LO.dressOff 给替身装上
    if NET.rwc and NET.rwc ~= NET.rwcCur then
        if NET.rwcCur then NET.rwcOff = NET.rwcCur end
        NET.rwcCur = NET.rwc
    end
    if t.arm == "1" then NET.rarm = true elseif t.arm == "0" then NET.rarm = false else NET.rarm = nil end
    NET.rwcs = (t.wcs and t.wcs ~= "") and t.wcs or nil -- v0.17.4 对方当前的影之武装
    local lvW, lvS = (t.wlv or ""):match("^([^:]*):(.*)$")  -- §148 对方那两把的等级；旧版本 / 本地 AI 没有 = nil，不补
    NET.rlvW, NET.rlvS = tonumber(lvW), tonumber(lvS)
    NET.rwge = t.wge                                    -- §118 对方的武器效果；旧版本 = nil，不动替身
    NET.rzmb = t.zmb                                    -- §349 对方的斩马刀损血增伤；旧版本 / 没这件升级 = nil
    NET.rpas = t.pas                                    -- v0.17.2 对方的天赋 / 饰品被动；没有这个字段（旧版本）= nil，不动替身
    NET.rof = LO.decodeOutfit(t.of)                     -- §109 对方的皮肤；没有这个字段（旧版本 / 本地 AI）= nil，不动替身

    local myMap = mapName(p1)
    if not PEER.on and t.map and t.map ~= myMap and NET.mapWarned ~= t.map then
        NET.mapWarned = t.map
        out("!! 两边不在同一张地图：本机 %s / 远端 %s。坐标是绝对坐标，替身会出现在奇怪的位置", myMap, t.map)
    end

    local pup = puppet()
    -- 每个"替身 × 武器"组合只试一次，失败也不刷屏。
    -- v0.8.0 实测：只按武器记的话，替身死后 F3 重建，新替身不会再换刀（19:24:30 重建后全程走"武器不匹配"兜底）
    local wKey = valid(pup) and (pathOf(pup) .. "|" .. (t.w or "")) or nil
    if t.w and t.w ~= "" and wKey ~= NET.wTried and valid(pup) then
        NET.wTried = wKey
        if NET.rwc then
            out("对方武器 %s（%s）：用 SetSlotWeapon 只换替身自己的武器组件", t.w, LO.short(NET.rwc))
        elseif not LO.EQUIP_REMOTE then
            out("对方武器 %s：不给替身换装（会连带改掉本机玩家的装备，见 HANDOVER §29），替身出招走武器不匹配兜底", t.w)
        elseif ST.pupWeapon ~= t.w then
            equipWeapon(pup, t.w, "远端武器")
        end
    end

    -- §223.7 武器效果（形态 / 升级）变了：放这个包里的招之前马上同步（以前只每 15 帧一次，刚切混沌形态就出招的第一招赶不上）
    if NET.rwge and NET.rwge ~= NET.wgeNow and valid(pup) and not REP.on then
        NET.wgeNow = NET.rwge
        local okW, errW = pcall(LO.syncWge, pup)
        if not okW and errW ~= LO.wgeErr then LO.wgeErr = errW; out("!! 替身武器效果同步出错：%s", tostring(errW)) end
    end
    DDIR.onPacket(t, tn)           -- §421 对方最近一次闪避的方向（要在放这个包的招之前）
    -- 出招事件（evt / list 在 LAT.onPacket 后面已经解析好）
    for _, e in ipairs(list) do
        if e.id > NET.lastEvIn then
            if NET.lastEvIn > 0 and e.id > NET.lastEvIn + 1 then
                out("  !! 事件跳号 %d -> %d（中间 %d 个超过 %.1f 秒没送到，已丢）",
                    NET.lastEvIn, e.id, e.id - NET.lastEvIn - 1, EV_KEEP)
                NET.evLost = NET.evLost + (e.id - NET.lastEvIn - 1)
            end
            NET.lastEvIn = e.id
            NET.evIn = NET.evIn + 1
            -- §104 旧版对方没有 gd= 时的退路：收到架势招 = 开始格挡，收到攻击招 = 不在格挡了
            if e.name:find("_Stance", 1, true) then NET.rStanceAt = tn elseif isAttackAbility(e.name) then NET.rStanceAt = nil end
            if valid(pup) and not REP.on and not AIR.onEvent(p1, pup, e, tn) then   -- v0.24.2 空中招可能先排队
                AIR.fire(p1, pup, e, tn)
            end
        end
    end

    DGE.onPacket(t, tn)            -- §118 dg=：对方往哪边翻（出招事件已经在上面放了）
    INF.onPacket(t, tn)            -- §160 inf=：对方身上的异常状态
    CHG.onPacket(t, tn)            -- §92 rel=：对方的蓄力招松手了

    -- 对方对"我的招式"的判定
    local rl = {}
    for id, atk, kind, v in (t.res or ""):gmatch("(%d+):(%d+):(%a+):([%d%.]+)") do
        rl[#rl + 1] = { id = tonumber(id), atk = tonumber(atk), kind = kind, v = tonumber(v) }
    end
    table.sort(rl, function(a, b) return a.id < b.id end)
    NET.resV = NET.resV or {}
    -- v0.23.1：一招只认一个结果号。对方每招只判一次（后几段走"追加命中"，同一个结果号），第二个不同的结果号 = 重复回报：
    -- 2026-11-04 22:42 实测 116 招里 47 招被报了两次（假对手 fake_remote.py 记"已回报"只记 1.5 秒），替身在你收刀后
    -- 又播一次受击、斩马刀吸血补偿也算两次
    NET.resAtk = NET.resAtk or {}
    -- §370 结果号不一定按到达顺序变大：本地 AI（LocalAi.cs）在登记我这招时就给结果号，碰到了 0.1 秒回报、没碰到要等 TouchWait / act= 放完
    -- 才判落空（§351 晚到的改判也沿用老结果号）。以前只收"比收过的都大"的结果号 → 先判完的后一招把前一招的结果整条吃掉：
    -- 玩家日志 mp_probe (24).log 07:02:12 / 07:02:13 紫冥剑 AB（#991 / #994）既没"命中"也没"落空"（AI 血量也没扣，判的是落空）。
    -- 现在按"收过哪些结果号"去重，晚到的照收；比最大的小 RES_OOO 以上的才当旧包
    NET.resSeen = NET.resSeen or {}
    local oldMax = NET.lastResIn
    for _, r in ipairs(rl) do
        if not NET.resSeen[r.id] and r.id > oldMax - NET.RES_OOO then
            NET.resSeen[r.id] = true
            if r.id < NET.lastResIn then
                NET.resLate = (NET.resLate or 0) + 1
                if NET.resLate <= 20 or NET.resLate % 50 == 0 then
                    out("§370 我第 #%d 招的结果 #%d（%s）比后面的招晚到（已收到 #%d），照收（第 %d 次；以前会被丢掉）",
                        r.atk, r.id, RES_NAME[r.kind] or r.kind, NET.lastResIn, NET.resLate)
                end
            end
            if r.id > NET.lastResIn then NET.lastResIn = r.id end
            local first = NET.resAtk[r.atk]
            if first and first ~= r.id then
                NET.resDup = (NET.resDup or 0) + 1
                out("  !! 我第 #%d 招又收到一个结果 #%d（%s，先前是 #%d），重复回报，忽略（第 %d 次）",
                    r.atk, r.id, RES_NAME[r.kind] or r.kind, first, NET.resDup)
            else
                NET.resAtk[r.atk], NET.resAtk[r.atk - 300] = r.id, nil
                NET.resV[r.id] = r.v
                applyRemoteResult(p1, r)
                if r.kind == "hit" and not PEER.on and DSTAT then DSTAT.hit(r.atk, r.v, tn) end     -- §342 招式伤害统计
            end
        elseif r.kind == "hit" and NET.resV[r.id] and r.v > NET.resV[r.id] + 0.5 then
            -- v0.17.3：同一招后几段的伤害由对方累加进同一条结果（见 netJudge）
            out("◆ 你的第 #%d 招追加命中 -%.0f（这招累计 -%.0f）", r.atk, r.v - NET.resV[r.id], r.v)
            LO.zmHeal(p1, r.atk, r.v - NET.resV[r.id])
            NET.resV[r.id] = r.v
            if not PEER.on and DSTAT then DSTAT.hit(r.atk, r.v, tn) end                                -- §342
        end
    end
    for k = math.max(1, oldMax - NET.RES_OOO), NET.lastResIn - NET.RES_OOO do NET.resV[k], NET.resSeen[k] = nil, nil end   -- §370 窗口外的清掉

    -- 替身血量以对方回报为准（本机砍替身掉的血只是预测，会被这里覆盖）
    local rhp, rhpm = tonumber(t.hp), tonumber(t.hpm)
    if valid(pup) and rhp and rhp >= 0 then
        TOUCH.harvest(pup, tn)                        -- §357 改血量 / 上限之前先把没看到的掉血记成碰到
        if rhpm and rhpm > 0 and math.abs((attrOf(pup, "Health_Max") or 0) - TOUCH.localHp(rhpm)) > 1 then setAttr(pup, "Health_Max", TOUCH.localHp(rhpm)) end   -- §207 本地 AI 临时加的那份带上
        local c = hpOf(pup)
        local full = TOUCH.fullOn()                   -- §301 本地 AI 交手中：替身本机写满，不写 AI 剩血
        local want = full and TOUCH.localHp(NET.remoteHpm) or TOUCH.localHp(rhp)
        if c and c > 0 and math.abs(c - want) > 1 then
            if rhp > 0 then setAttr(pup, "Health", want); ST.pupHpSeen = want end   -- §107 校正不算碰到
            if not full and NET.remoteHp ~= rhp then out("替身血量按对方回报校正 %.0f -> %.0f", c - (TOUCH.headNow or 0), rhp) end
        end
        if full and NET.remoteHp ~= rhp then out("替身血量按对方回报校正 %.0f -> %.0f（本地 AI：替身本机保持满血量，§301）", NET.remoteHp, rhp) end
        if rhp <= 0 and (NET.remoteHp or 1) > 0 then out("◆ 对方阵亡（回报 hp=0）") end
        NET.remoteHp = rhp
    end
    -- v0.24.0 对手血条（OPPBAR）用：最大血量、对方自己的杀气 / 杀气上限（旧版没有 sh= = 血条杀气不动）
    if rhpm and rhpm > 0 then NET.remoteHpm = rhpm end
    -- §276（移植 0.33 分支 §269.3）杀气改走 sq=：§174 的身份字段也叫 sh=（SteamID 哈希），联机程序发包前把游戏的 sh= 整行删掉、换成身份那行 →
    -- §174 起对方的杀气从来没到过（黄条一直是替身自己的、每 10 帧补满 = 一直满）。不读 t.sh：那是身份哈希，全数字时会被当成杀气
    NET.rsh, NET.rshm = tonumber(t.sq), tonumber(t.shm)
    NET.rsqp = t.sqp == "1"         -- §353 本地 AI：交手中替身杀气按游戏自己的（不补满），AI 跟着 psq= 走
    if not PEER.on and NET.rai and valid(pup) then
        local epoch = tonumber(t.trainChiEpoch)
        local refillChi = epoch and NET.trainChiEpoch and epoch ~= NET.trainChiEpoch
        if NET.rtrainAiChi or NET.rtrainChi == "locked" or (NET.rtrainChi == "refill" and refillChi) then
            local mx = attrOf(pup, "Shachi_Max")
            if mx then setAttr(pup, "Shachi", mx) end
        elseif NET.rtrainChi == "empty" and NET.fighting() then
            setAttr(pup, "Shachi", 0)
        end
        if TRAINCTX then TRAINCTX.emptyBreak(pup) end
        if TRAINCTX and TRAINCTX.packet then
            local okP, errP = pcall(TRAINCTX.packet, pup, tn)                     -- §456 杀气损耗后不恢复 / 精纯杀气、暗源数量
            if not okP and not TRAINCTX.packetErr then TRAINCTX.packetErr = true; out("!! §456 木桩资源出错：%s", tostring(errP)) end
        end
        NET.trainChiEpoch = epoch
    elseif not PEER.on then NET.trainChiEpoch = nil end
    -- §223.6 观战替身：判定结果在 applyRemoteResult / LO.zmHeal 里自己不做；下面的房间设置照记（记进这个替身自己那份，
    -- NET.flag / resOf / accBanOf 观战时按主机那一路记下的，两个替身都按主机的规则，同真实对局）；会对外要东西 / 改共用状态的跳过
    NET.recvRules(t)
end

local PUPPET_NO_LOCAL_DAMAGE = false
-- 联网时替身在本机不吃伤害：把属性集里所有 TakenVulnerabilityMultiplier_*（承受伤害倍率，默认 1.0）设为 0。
-- 每个替身只做一次。替身的血量完全由对方回报决定
local function protectPuppet(pup)
    local key = pathOf(pup)
    if ST.protectedFor == key then return end
    ST.protectedFor = key
    local set = attrSetOf(pup)
    if not valid(set) then return end
    local names = {}
    local okC, c = pcall(function() return set:GetClass() end)
    for _ = 1, 4 do
        if not (okC and valid(c)) then break end
        pcall(function()
            c:ForEachProperty(function(p)
                local n = "?"
                pcall(function() n = p:GetFName():ToString() end)
                if n:find("^TakenVulnerabilityMultiplier_") then names[#names + 1] = n end
            end)
        end)
        local okS, sup = pcall(function() return c:GetSuperStruct() end)
        okC, c = okS, sup
    end
    -- v0.10.13 用户反馈：斩马刀杀气重击的耗血 / 吸血在 PvP 里不更新血条（打怪正常）。原因是这里把替身的
    -- 承受伤害倍率设成 0，我的刀在本机打出 0 伤害，按伤害算的吸血 / 耗血也都是 0。
    -- 现在替身有 GE_LockHealth（血量最低 0.01）兜底不会死，血量每帧按对方回报改回去，不再需要本机免伤。
    -- 代价：吸血按"本机替身"的防御算（属性抄的是我自己），被对方精防的那一刀本机也可能吸到血 —— 近似值
    local done = 0
    if PUPPET_NO_LOCAL_DAMAGE then
        for _, n in ipairs(names) do if setAttr(pup, n, 0.0) then done = done + 1 end end
    end
    out("替身本机伤害：%s（%d 个承受伤害倍率）", PUPPET_NO_LOCAL_DAMAGE and "免伤（倍率设 0）" or "正常吃伤害，血量再按对方回报改回",
        #names)
    -- 保底：血量下限设为 1。暗杀等"直接把血量写 0"的效果绕过伤害倍率；如果属性集按 Health_Min 钳制血量，替身就死不了
    -- （是否真的钳制待实测：被打到 1 停住即有效）
    local okMin = setAttr(pup, "Health_Min", 1.0)
    out("替身血量下限 Health_Min -> %s（%s）", tostring(attrOf(pup, "Health_Min")), okMin and "写入成功" or "写入失败")
end

-- 锁定点：替身身上的 LockViewTarget（ATPCLockOnTargetLocationComponent）本来由那个玩家自己的锁定系统摆放，
-- 替身没人管，一直在地图原点 (0,0,0)。v0.9.10 锁定探针：镜头锁的正是它，离替身 118693 → 镜头对着"场地中央"。
-- 每帧把它放到替身胸口
local LOCK_Z = 40.0

local function fixPuppetLockPoint()
    local pup = ST.secondPawn
    if not valid(pup) then return end
    local comp = rawProp(pup, "LockViewTarget")
    if not valid(comp) then return end
    local okL, l = pcall(function() return pup:K2_GetActorLocation() end)
    if not (okL and l) then return end
    local ok = pcall(function()
        comp:K2_SetWorldLocation({ X = l.X, Y = l.Y, Z = l.Z + LOCK_Z }, false, {}, true)
    end)
    if ST.lockFixLogged ~= pathOf(pup) then        -- 每个替身记一次
        ST.lockFixLogged = pathOf(pup)
        local okA, a = pcall(function() return comp:K2_GetComponentLocation() end)
        out("替身锁定点每帧跟随：设置%s，现在在 %s（替身 %s）", ok and "成功" or "失败",
            okA and a and string.format("(%.0f, %.0f, %.0f)", a.X, a.Y, a.Z) or "?",
            string.format("(%.0f, %.0f, %.0f)", l.X, l.Y, l.Z))
    end
end

-- 替身保持"战斗中"状态，使其不可被暗杀（v0.9.17）。
-- v0.9.16 只读探针：全局配置 GetCharacterCombatStateTag() = CharacterState.InCombat；
-- 角色状态组件 ActorStateComponent 有 TryActivateNewState(NewStateTag:GameplayTag) / CanActivateNewState / InExactState。
-- 参数是单个 GameplayTag 简单结构体（同 HasMatchingGameplayTag，安全），不需要传 GameplayTagContainer（会崩）。
-- 推测暗杀（Execution.Type.Stealth）要求目标未进入战斗；替身没有 AI 永远不进战斗，所以随时能被暗杀
local COMBAT_TAG = "CharacterState.InCombat"

local function inCombatInfo(actor)
    local sc = stateComp(actor)
    local tag = { TagName = FName(COMBAT_TAG) }
    local okE, e = pcall(function() return sc:InExactState(tag) end)
    local okC, c = pcall(function() return sc:InChildState(tag) end)
    local okH, h = pcall(function() return ascOf(actor):HasMatchingGameplayTag(tag) end)
    return string.format("状态=%s 子状态=%s 标签=%s", okE and tostring(e) or "?", okC and tostring(c) or "?",
        okH and tostring(h) or "?"), (okE and e) or (okC and c) or (okH and h)
end

local function keepPuppetInCombat(pup, force)
    local sc = stateComp(pup)
    if not valid(sc) then return end
    local info, inCombat = inCombatInfo(pup)
    if inCombat and not force then return end
    local tag = { TagName = FName(COMBAT_TAG) }
    local okCan, can = pcall(function() return sc:CanActivateNewState(tag) end)
    local okTry, r = pcall(function() return sc:TryActivateNewState(tag) end)
    local after = inCombatInfo(pup)
    NET.combatTries = (NET.combatTries or 0) + 1
    if NET.combatTries <= 5 or NET.combatTries % 30 == 0 or force then
        out("替身切入战斗状态 #%d：之前 %s；CanActivateNewState=%s；TryActivateNewState=%s；之后 %s；玩家1 %s",
            NET.combatTries, info, okCan and tostring(can) or "调用失败", okTry and tostring(r) or ("调用失败 " .. tostring(r)),
            after, (inCombatInfo(getP1())))
    end
end

-- ---- v0.22.0 可靠事件通道（HANDOVER §51）。逐帧的位置 / 动作 / 准备 / 装备照旧走状态包（最新覆盖：丢一包下一包就补上）；
-- F3c-1（docs/FORNET_SPLIT.md）：通道本身（REL 表 / write / readIn / send / poll / 加载时读旧 rel_in）搬到 fornet_net.lua；
-- 事件处理（REL.on.xxx）留在各段里。这里只装模块、取别名，行为一字不差
local REL = FNET.REL     -- 模块在上面 v0.27.0 延迟那段装（FNET），这里只取别名

-- §82.4 驱动的后一半：发包。startDriver 在驱动之后的下一帧调；帧率 ≤ 30 没有空帧时，下一次驱动之前先补上。
-- 全局字段（主代码块 local 已满 200 个）
function NET.sendStep()
    if not NET.sendDue then return end
    NET.sendDue = false
    if ST.travel then return end            -- 切图冻结中不碰游戏对象
    local p1 = getP1()
    if valid(p1) then netSend(p1, now()) end
end

local function netStep()
    local p1 = getP1()
    if not valid(p1) then return end
    local tn = now()
    REL.poll()
    netRecv(p1, tn)
    netJudge(p1, tn)
    if TRAINING then
        TRAINING.step(tn)
        if TRAINING.infinite("hp") and NET.judgeHp then NET.judgeHp = hpOf(p1) end
    end
    -- 2026-11-05：以前每 2 次发一包（驱动又只有 15.6 次 / 秒，对面只收到 7.8 帧 / 秒）。现在每次都发，约 30 包 / 秒
    -- §82.4：ST.SPLIT 时发包挪到下一帧（NET.sendStep），和收包 / 驱动替身错开，单帧不再一口气做完
    if ST.SPLIT then NET.sendDue = true else netSend(p1, tn) end

    -- 远端数据 1 秒内新鲜才驱动，避免旧文件把替身钉在过期位置
    local pup = puppet()
    local fresh = NET.pos and tn - NET.lastRecvAt < 1.0
    if not REP.on and valid(pup) and fresh then
        if not NET.driving then setBraking(pup, true); NET.driving = true end
        NET.drive(p1, pup, tn)
    elseif NET.driving then
        NET.driving = false
        AIR.queue, AIR.launched = {}, false
        if valid(pup) then setBraking(pup, false) end
        out("远端数据中断，替身停止跟随（共收包 %d，事件 %d，丢事件 %d）", NET.rx, NET.evIn, NET.evLost)
    end
    if fresh and ST.ticks % 150 == 0 then
        -- v0.9.5 实测：统计行还按旧的 deflect 计数，精防/普通防御一直显示 0，改按新类型
        out("网络 | 收包 %d 事件 %d 丢事件 %d 跟随误差 %.0f 瞬移 %d | 我判定 中%d 精防%d 普防%d 空%d | 对方回报 中%d 精防%d 普防%d 空%d",
            NET.rx, NET.evIn, NET.evLost, NET.lastErr or -1, ST.snaps or 0,
            NET.judged.hit or 0, NET.judged.parry or 0, NET.judged.block or 0, NET.judged.miss or 0,
            NET.applied.hit or 0, (NET.applied.parry or 0) + (NET.applied.deflect or 0), NET.applied.block or 0,
            NET.applied.miss or 0)
        if (NET.suppressed or 0) > 0 then out("      已掐掉替身的本机受击/破防动作 %d 次", NET.suppressed) end
        ANIM.report()
        if FIREK then FIREK.report() end      -- §243 真技能 / 画面兜底分开计数
        PRED.report()      -- §104
    end
    if fresh and ST.ticks % 300 == 150 then LAT.report() end      -- v0.27.0 每 10 秒一行延迟统计
end

-- §223 驱动替身的这一帧（以前写在 netStep 里）。观战的两个替身也走这里（PEER.run 里，p1 = 另一个替身，不判定），
-- 对战时 p1 = 玩家1。§223.2 起观战连位置 / 跑步 / 朝向也走这里（drivePuppet / NPM，观战一律严格跟随），和对战完全同一份
function NET.drive(p1, pup, tn)
    -- v0.23.3 锁定：用户 2026-11-04"我躲开之后它锁不到我，一直向着空气连"。对方在他那边锁定着我（lk=1）时，他的招式由
    -- 他的游戏追着我打；替身在这边没有目标，只会照包里的朝向直直砍出去。所以：替身的锁定目标设成我（让游戏自己的
    -- 追踪生效），出招期间（ATK_HOLD 秒）朝向也不用包里的，而是每帧对准我
    local lockKey = pathOf(pup) .. (NET.rlk and "|1" or "|0")
    if ST.lockSetKey ~= lockKey then
        ST.lockSetKey = lockKey
        local okL = setLockTarget(pup, NET.rlk and p1 or nil)
        -- §132 替身的瞄准组件（火枪等按它找目标）也跟着：对方锁你 → 锁你（你的锁定点每驱动一次放到你胸口，ZMX.step）；
        -- 不锁 → 撤掉（§119 原来只在不锁时撤、锁的时候只有召唤才锁）
        local tcP = LO.targetingComp(pup)
        if tcP then
            if NET.rlk then ZMX.p1Lock(true, "对方锁定你"); ZMX.tcLock(tcP) else LO.tcStop(tcP) end
        end
        out("替身锁定目标 → %s（%s）", NET.rlk and "玩家1（对方锁定着你）" or "无", okL and "写入成功" or "写入失败")
    end
    local spec = PEER.on
    local yaw = NET.yaw
    if NET.rlk and ST.pupAtkAt and tn - ST.pupAtkAt < ATK_HOLD then
        local a = try("pup loc", function() return pup:K2_GetActorLocation() end)
        local b = try("p1 loc", function() return p1:K2_GetActorLocation() end)
        if a and b then
            yaw = math.deg(math.atan(b.Y - a.Y, b.X - a.X))
            -- 诊断：上一帧对准的朝向有没有被招式自己的转向盖掉（差很多 = 要换办法，比如动作扭曲目标）
            local cur = yawOf(pup)
            if cur and ST.lockAim and (not ST.lockLogAt or tn - ST.lockLogAt > 1.0) and (ST.lockLogs or 0) < 30 then
                local d = math.abs((cur - ST.lockAim + 180) % 360 - 180)
                ST.lockLogAt, ST.lockLogs = tn, (ST.lockLogs or 0) + 1
                out("替身出招对准你：上一帧要的朝向 %.0f，实际 %.0f（差 %.0f°%s），包里的朝向 %.0f",
                    ST.lockAim, cur, d, d > 20 and "，被招式转向盖掉了？" or "", NET.yaw)
            end
            ST.lockAim = yaw
        end
    else
        ST.lockAim = nil
    end
    local tgt, why = LAT.target(tn)                                 -- v0.27.0 追外推后的位置
    if NPM.readMode(tn) == "net" then           -- §128.1 全程跟网络位置：出招 / 受击时也外推，急转 / 没时间戳不外推
        local age = LAT.age(LAT.peerTs, tn)
        -- §436.2 我在观战：不按包龄往前推（看的人不需要"预测对方现在在哪"，推了对方一停替身就冲出去再拉回），
        -- 只从收到包起推 WATCH_EXTRA 秒补两包之间的空当
        local watch = NPM.watching()
        NPM.extraMax = watch and NPM.WATCH_EXTRA or nil
        NPM.setTarget(pup, NET.pos, NET.vel, watch and (NET.lastRecvAt or tn) or (tn - (age or 0)),
            why == "急转" or why == "急停" or not age, AIR.rair,
            NET.rtrv == true and tn - (NET.rtrvAt or -100) < NPM.TRV_HOLD)     -- §436 对方在爬墙 / 翻越：高度也跟
        local a = NPM.aim(tn)
        tgt = { X = a.X, Y = a.Y, Z = NET.pos.Z }
    end
    NET.lastErr = drivePuppet(pup, tgt, NET.vel, yaw)
    DGE.step(pup, tn)          -- §118 替身闪避方向跟对方一样
    DDIR.step(pup, tn)         -- §421 挂上的闪避方向标签到时撤回
    INF.step(pup, tn)          -- §160 替身的冰冻 / 点燃 / 中毒…跟对方一样（本机自己积出来的撤掉）
    AIR.step(p1, pup, tn)      -- v0.24.2 对方在空中 → 替身起跳；排队的空中招
    HOV.watchPuppet(pup, tn, AIR.rair == true)   -- §99 对方在地上替身却往下掉 / 被引擎藏起 → 悬空、重新显示
    LAT.step(tn)               -- v0.27.0 追帧：等替身开始播这招的蒙太奇
    ANIM.step(tn)              -- §100 放成功却没换动作：重放 / 直接播
    if DIAG and DIAG.PDX then pcall(DIAG.PDX.step, tn) end      -- §229.5 红光直接播的子弹按时间生成
    if TAGD then pcall(TAGD.step, tn) end    -- §249 状态对比：到点前只比一个时间戳，排过才做事
    if not spec then ULT.step(p1, tn) end      -- v0.27.1 大招资源诊断（只在有等着的诊断时读属性）
    CHG.step(p1, pup, tn)      -- §92 蓄力探针（只在有在记的条目时读）
    LUTE.step(pup, tn)         -- §430 破阵曲：替身自己进了循环、对方没在按 → 收招
    ZMX.step(pup, tn)          -- §119 紫冥剑实验（只在替身刚放 DB 时读）
    if LDASH.pend then pcall(LDASH.step, tn) end      -- §448 移商换羽：到点扫一次子弹
    -- 替身的架势在本机保持满值：破防应由对方判定，不能被我本机的刀打出来（v0.9.5 日志里有本机 BreakEscape）
    if ST.ticks % 10 == 0 then
        local mx, cur = attrOf(pup, "Shachi_Max"), attrOf(pup, "Shachi")
        ST.pupShMax = mx                                                  -- §357 每帧补杀气（TOUCH.keepShachi）用，省得每帧读上限
        if mx and cur and cur < mx and not (AISYNC and AISYNC.ownShachi()) then setAttr(pup, "Shachi", mx) end   -- §353 本地 AI 交手中不补
        -- §113 暗源同理：对方放成功了才会发来，替身自己不在铃铛回复，以前打几局就耗光、影之武装放不出来
        local smx, scur = attrOf(pup, "SpiritShadow_Max"), attrOf(pup, "SpiritShadow")
        if smx and scur and scur < smx and not (NET.rai and TRAINING and TRAINING.allowed()) then setAttr(pup, "SpiritShadow", smx) end
    end
    protectPuppet(pup)
    -- v0.16.0 配装同步：对方的攻击属性写进替身；替身被本机玩家换装带偏就重装对方武器
    -- v0.23.7 替身在放对方的影之武装（EDGE_HOLD 秒内）：攻击力乘 PvP 系数，放完恢复（LO.apply 里乘）
    -- §86 再乘房间的伤害倍率（对局中用开局时定下的）
    LO.rescale(pup, tn)        -- §106 再乘武器平衡系数（族 / 单招）
    if ST.ticks % 15 == 0 then LO.guard(pup) end
    if ST.ticks % 8 == 0 then
        local okD, errD = pcall(LO.dress, pup, spec and getP1() or p1)      -- 第二个参数是本机玩家（换装后核对它没被带偏）
        if not okD and errD ~= LO.dressErr then LO.dressErr = errD; out("!! 替身换装出错：%s", tostring(errD)) end
    end
    if ST.ticks % 15 == 7 then
        local okP, errP = pcall(LO.syncPas, pup)
        if not okP and errP ~= LO.pasErr then LO.pasErr = errP; out("!! 替身被动同步出错：%s", tostring(errP)) end
    end
    if ST.ticks % 15 == 11 then
        local okW, errW = pcall(LO.syncWge, pup)
        if not okW and errW ~= LO.wgeErr then LO.wgeErr = errW; out("!! 替身武器效果同步出错：%s", tostring(errW)) end
    end
    -- v0.9.17 / §239 替身战斗状态：原先尝试 ActorStateComponent 恒 false；§239 改走 ASC 施加 GE_InBossFight（赋予 CharacterState.InCombat.Boss）
    if ST.ticks % 30 == 3 and not LO.chaosOff() then
        pcall(LO.ensureCombat, pup)
    end
    if NET.reequipIn then
        NET.reequipIn = NET.reequipIn - 1
        if NET.reequipIn <= 0 then
            NET.reequipIn = nil
            local w = ST.pupWeapon
            ST.pupWeapon, NET.wTried = nil, nil      -- 强制下一包重新装备远端武器
            out("暗杀拦截后重新给替身装武器（之前 %s）", tostring(w))
        end
    end
    -- 血量只听对方：本机掉的血补回对方回报的值（v0.9.10 实测：被校正成 600 后本机三刀砍死）
    local c = hpOf(pup)
    if c and c > 0 and NET.remoteHp and NET.remoteHp > 0 then
        local want = TOUCH.localCur(NET.remoteHp)                -- §207 / §301
        if c < want - 1 then
            TOUCH.harvest(pup, tn, c)                            -- §357 写回去之前先把这次掉血记成碰到
            setAttr(pup, "Health", want)
            if not PEER.on then ST.pupHpSeen = want end
        end
    end
    TOUCH.distStep(p1, pup, tn)                                  -- §357 落空诊断（只在本地 AI、出招 3 秒内）
end


-- ============================================================ M0：状态 / dump / 实验
local PROBE = BASEPARTS.load("probe", { ST = ST, VERSION = VERSION, G = G,
    -- 主循环那段会把这几个换成计时包装（PROF.wrap）：传"调用时再取"，和搬出来之前一样
    out = function(...) return out(...) end, hpOf = function(...) return hpOf(...) end, attrOf = function(...) return attrOf(...) end,
    factionName = function(...) return factionName(...) end, montageOf = function(...) return montageOf(...) end })

-- ============================================================ 让替身不能被暗杀（v0.9.21）
-- v0.9.20 读出处决条件表：Execution 通道里 Execution.Type.Stealth（暗杀）的 TargetIgnoredTags 含
--   AI.State.Combat、CharacterState.Forbid.StealthExecuteTarget、CharacterState.CanNotBeExecuted、CharacterState.Unselectable、
--   CharacterState.Stand.Invulnerable、CharacterState.Dead、CharacterType.AI.Boss …（目标有其一就不能被暗杀）
-- 而 Execution.Type.Combat（普通处决）的忽略表里没有 Forbid.StealthExecuteTarget —— 它只禁暗杀，最理想。
-- 方案 A（F2，零风险）：状态机能切就切（TryActivateNewState 单标签参数）
-- 方案 B（F4）：施加 /PBZCombatAsset/Prototypes/GameplayEffects/GE_LockHealth —— 名字表：TargetTagsGameplayEffectComponent +
--   CharacterState.CanNotBeExecuted + Health_Min（同时锁血）。用 ASC:BP_ApplyGameplayEffectToSelf(类, 等级, 空上下文)；
--   UE 源码里空上下文由函数内部 MakeEffectContext 补上。代价：CanNotBeExecuted 也禁普通处决（普通处决本来还没做同步）
local GE_LOCKHEALTH = "/PBZCombatAsset/Prototypes/GameplayEffects/GE_LockHealth"

local function noStealthByState()
    local pup = puppet()
    if not valid(pup) then out("!! 先按 F12 造替身"); return end
    local sc = stateComp(pup)
    out("== 方案 A：状态机 == 之前 %s", tagReport(pup))
    for _, t in ipairs(NO_STEALTH_TAGS) do
        local tag = { TagName = FName(t) }
        local okC, can = pcall(function() return sc:CanActivateNewState(tag) end)
        local okT, r = false, nil
        if okC and can then okT, r = pcall(function() return sc:TryActivateNewState(tag) end) end
        out("  %s：CanActivateNewState=%s TryActivateNewState=%s", t, okC and tostring(can) or "调用失败",
            (okC and can) and (okT and tostring(r) or "调用失败") or "（没试）")
    end
    out("  之后 %s", tagReport(pup))
end

-- v0.9.24 实测：LoadAsset 加载成功 → 施加后 CanNotBeExecuted false→true，整局再没触发暗杀（无暗杀按钮）。
-- v0.9.25：每秒检查一次，新替身自动施加一次（每个替身最多试 3 次，失败间隔 5 秒）；F2 保留手动
local function startNoStealthLoop()
    if type(LoopInGameThreadWithDelay) ~= "function" then return end
    LoopInGameThreadWithDelay(1000, function()
        pcall(function()
            if ST.travel then return end    -- 切图冻结中（MAPGO.freeze）
            local pup = puppet()
            if not valid(pup) or ST.bareTest then return end
            local key = tostring(pathOf(pup))
            local g = ST.noStealth
            if not g or g.key ~= key then g = { key = key, tries = 0, at = 0, done = false }; ST.noStealth = g end
            if g.done or g.tries >= 3 or os.time() - g.at < 5 then return end
            g.tries, g.at = g.tries + 1, os.time()
            g.done = noStealthByGE(pup, "自动 第" .. g.tries .. "次") and true or false
        end)
    end)
end

-- ============================================================ M4：对局流程（v0.10.0）
-- 主机（按 F4 的一方）说了算：倒计时 → 交手 → 回合结束 → …… 先赢 MATCH.toWin 回合者胜（v0.26.3 起按局数设置，开局时定下）。
-- 每台机器只管自己倒没倒：对局期间自己挂 GE_LockHealth（血量最低 0.01，不会真死、不回篝火），
-- 血量 ≤ DEAD_HP 就算本回合倒下，发 dead=<回合>。主机据此判回合胜负，用
--   mt=<状态>:<回合>:<主机分>:<客机分>:<本回合赢家 h|c|d|->:<局号>   arena=<中心 x:y:z:yaw>
-- 广播，客机跟随。双方出生点在中心两侧各 SPAWN_D，面对面。
-- 处决对局里双方都禁用：替身挂 GE_LockHealth（v0.9.25 起），自己对局期间也挂（同一个 GE 带 CanNotBeExecuted）。
-- 处决是双人配对动画，两边位置 / 时机都要对齐，单机无法验证同步，留到有第二台机器再做
-- 包在一个函数里：主块的 local 已经接近 Lua 的 200 个上限（v0.10.0 加进来直接超了）
local M4 = (function()
local CD_SEC, REND_SEC, END_SEC, FIGHT_SHOW = FMATCH.TIMES.CD, FMATCH.TIMES.REND, FMATCH.TIMES.END, FMATCH.TIMES.FIGHT_SHOW     -- F4a：定义在 fornet_match.lua
local SPAWN_D, DEAD_HP, TEXT_Z, LOST_SEC = 500.0, 1.0, 230.0, FMATCH.TIMES.LOST
-- v0.10.2 用户反馈：文字"打印在游戏场景里而不是 UI 上"。改成每帧摆到镜头正前方 HUD_D、往上 HUD_UP，朝向镜头
local HUD_D, HUD_UP, HUD_SIZE = 200.0, 38.0, 12.0     -- v0.14.2：16 → 12，长句在 1600 宽窗口里会贴边 / 出屏
local ARENA_FILE = REC_DIR .. "/arena.txt"
local DEATH_ANIMS = { "AM_Hun_Dead_F", "AM_Hun_Dead_B" }
-- v0.23.1 慈母护符（AC_BreakRegen：破防时回复最大生命 10%，精炼 20%）。2026-11-04 22:42:56 / 22:43:24 实测：致命一刀同时
-- 打破架势，锁血把血量钳在 0.01，同一帧护符又补回 20%，每帧轮询只看到 617.1（= 0.01 + 3085.5 × 20%），永远到不了 DEAD_HP。
-- 所以：戴着它的话，血量刚变成"下限 + 回血量"也算倒下（不是致命的一刀落不到下限上，回完血不会正好是这个数）
local BREAK_REGEN = { GA_Accessory_BreakRegen_Lv1_C = 0.10, GA_Accessory_BreakRegen_Lv2_C = 0.20 }
local function breakRegenFrac(p1, tn)
    local c = MATCH.brCache
    if not c or c.key ~= pathOf(p1) or tn - c.at > 10.0 then
        c = { key = pathOf(p1), at = tn, frac = nil }
        for _, a in ipairs(abilitiesOf(p1) or {}) do
            if BREAK_REGEN[a.name] then c.frac = math.max(c.frac or 0, BREAK_REGEN[a.name]) end
        end
        if c.frac and not (MATCH.brCache and MATCH.brCache.frac) then
            out("戴着慈母护符（破防回复 %.0f%% 最大生命）：致命一刀同时破防也算倒下", c.frac * 100)
        end
        MATCH.brCache = c
    end
    return c.frac
end
local function savedByBreakRegen(p1, hp, tn)
    local frac = breakRegenFrac(p1, tn)
    local max = attrOf(p1, "Health_Max")
    if not (frac and max and max > 0) then return false end
    local floor = attrOf(p1, "Health_Min") or 0
    return math.abs(hp - (floor + frac * max)) < 0.5
end

-- v0.23.0：动画实例 / 站起 / 补满 / 背包 / 自己锁血搬到 pbz_game.lua（游戏适配层）
local animOf, standUp, refill, backpack, lockSelf, unlockSelf = G.animOf, G.standUp, G.refill, G.backpack, G.lockSelf, G.unlockSelf

local function deathAnim()
    if MATCH.deathName == nil then
        MATCH.deathName = firstExisting(DEATH_ANIMS) or false
        if not MATCH.deathName then
            montageByName("")
            for n in pairs(montages() or {}) do
                if n:find("Hun") and n:find("Dead") then MATCH.deathName = n; break end
            end
        end
        out("倒地动作: %s", tostring(MATCH.deathName))
    end
    return MATCH.deathName or nil
end

-- 播倒地动作，快播完时暂停在最后一帧（holdStep），下一回合 standUp 再停掉
local function fallDown(actor, who)
    local name = deathAnim()
    local dur = (name and valid(actor)) and playOn(actor, montageByName(name)) or nil
    if dur and sameObj(actor, ST.secondPawn) then ST.pupOwnName, ST.pupOwnFrames = name, 300 end
    out("  %s倒地 %s（%s）", who, tostring(name), dur and string.format("%.2f 秒", dur) or "播放失败")
    if dur then MATCH.hold[#MATCH.hold + 1] = { actor = actor, at = now() + math.max(0.1, dur - 0.15) } end
end

local function holdStep(tn)
    local keep = {}
    for _, h in ipairs(MATCH.hold) do
        if tn >= h.at then
            local an = animOf(h.actor)
            local ok, mt = pcall(function() return an:GetCurrentActiveMontage() end)
            if ok and valid(mt) then pcall(function() an:Montage_Pause(mt) end) end
        else
            keep[#keep + 1] = h
        end
    end
    MATCH.hold = keep
end

-- v0.10.10 实测：ClearMedicineUseTime 之后药不仅没回，剩下的也用不了了（开新局数字看着回了，但仍不能用）。
-- 这个函数不是"补满"，已停用。v0.10.11 起 refillPotions 什么都不调
local POTION_REFILL_ENABLED = false

local function refillPotions(why)
    if not POTION_REFILL_ENABLED then
        if why == "F2 手动" then out("补药瓶已停用（ClearMedicineUseTime 会让药用不了）") end
        return
    end
    local bp = backpack()
    if not bp then out("!! 补药瓶：找不到背包子系统 PBZBackPackSubsystem"); return end
    local done = {}
    for _, k in ipairs({ "TopMedicineID", "BottomMedicineID" }) do
        local id = fnameStr(rawProp(bp, k))
        if id and id ~= "" and id ~= "None" then
            local ok, err = pcall(function() bp:ClearMedicineUseTime(FName(id)) end)
            done[#done + 1] = string.format("%s=%s", id, ok and "已清" or ("失败 " .. tostring(err)))
        end
    end
    out("补药瓶（%s）：ClearMedicineUseTime %s", why, #done > 0 and table.concat(done, "，") or "没有装备药")
end

-- ---- v0.26.2 安全放置（§79）。用户 2026-11-05："4 做个保护"——11:50 回合归位把人放进了墙里（K2_SetActorLocation 不查碰撞）。
-- 回合归位（只对 AI）、连上时放到主机身边、切图后掉出地图拉回、退出观战都走这里：
--   1) G.teleportTo（引擎的传送：落点卡进几何体就在附近找空位，找不到返回 false）
--   2) 放不下就沿"起点 → 落点"往起点缩：2/3、1/3 处再试。起点是对方站着的地方（主机身上 / 开局时主机站的点），能站
--   3) 都放不下就留在原地，只记日志，不硬塞
--   4) 放下后 SAFE_GUARD 秒内掉出地图 → 放回去（见 SAFE.step）
-- §168 线上反馈"传送太容易掉虚空"，加强：
--   a) 落点先探地（HOV.floor 往下 SAFE.DEPTH）：近处（传送距离 ≤ HOV.FAR，地形肯定加载了）下面没地的点直接不用；
--      有地的点优先；都没地就留在原地（以前照放 → 悬崖边 / 主机脚下在你这边是空的就掉下去）
--   b) 远处（地形可能还没加载，探不出来）照放，但由这里统一悬空等地（HOV.hold，带 back = 传送前站稳的地方、alts = 其余候选点）
--   c) 防掉落 3 → 10 秒；除了掉了 SAFE_FALL，还看"在往下掉、掉了 SAFE.VOID 以上、下面 SAFE.VOID_DEPTH 都没地"= 虚空，早点拉回
--   d) 拉回时：起点下面有地 → 起点；否则传送前站稳的地方（GROUND）；都没有才按以前放回起点。拉回后悬空等地站住
local SAFE_FALL, SAFE_GUARD = 1500.0, 10.0
local SAFE = { guard = nil, VOID = 400.0, DEPTH = 800.0, VOID_DEPTH = 3000.0 }

local function safePlace(actor, target, anchor, yaw, why, alts)
    if not valid(actor) then return nil end
    local was = try("safe from", function() return actor:K2_GetActorLocation() end)
    local from = anchor or was
    local back = GROUND.get(mapName(actor))
    local cands = { target }
    for _, a in ipairs(alts or {}) do cands[#cands + 1] = a end
    if anchor then
        for _, f in ipairs({ 2 / 3, 1 / 3 }) do
            cands[#cands + 1] = { X = anchor.X + (target.X - anchor.X) * f, Y = anchor.Y + (target.Y - anchor.Y) * f,
                                  Z = anchor.Z + (target.Z - anchor.Z) * f }
        end
    end
    local far = was ~= nil and math.sqrt((target.X - was.X) ^ 2 + (target.Y - was.Y) ^ 2) > HOV.FAR
    -- 试的顺序：下面有地的 → 不知道的 → （只有远处）探出来没地的
    local order, fls, noFloor = {}, {}, 0
    for i, c in ipairs(cands) do fls[i] = HOV.floor(actor, c, SAFE.DEPTH) end
    for _, want in ipairs({ true, "nil", false }) do
        for i = 1, #cands do
            local f = fls[i]
            if (want == "nil" and f == nil) or (want ~= "nil" and f == want) then
                if f == false and not far then noFloor = noFloor + 1 else order[#order + 1] = i end
            end
        end
    end
    for _, i in ipairs(order) do
        local c = cands[i]
        local ok, how = G.teleportTo(actor, c, yaw)
        if ok then
            local cm = rawProp(actor, "CharacterMovement")
            if valid(cm) then pcall(function() cm.Velocity = { X = 0.0, Y = 0.0, Z = 0.0 } end) end
            if from then SAFE.guard = { actor = actor, from = from, back = back, z = c.Z, till = now() + SAFE_GUARD, why = why } end
            if i > 1 then out("%s：原落点放不下（会卡进地形 / 下面没地），改放到第 %d 个候选点 (%.0f, %.0f, %.0f)", why, i, c.X, c.Y, c.Z) end
            if how then out("%s：%s", why, how) end
            if far then     -- §99 / §168 跳得远：落点的地形可能还没加载，先悬空等地；等不到放回传送前站稳的地方
                local rest = {}
                for j, o in ipairs(cands) do if j ~= i then rest[#rest + 1] = o end end
                HOV.hold(actor, { X = c.X, Y = c.Y, Z = c.Z }, why, now(), { back = back, alts = rest })
            end
            return c
        end
    end
    if noFloor > 0 then
        out("!! %s：%d 个落点下面没地（悬崖 / 虚空，存档进度不同时主机脚下在你这边可能是空的），%d 个放不下，留在原地",
            why, noFloor, #cands - noFloor)
    else
        out("!! %s：%d 个落点都放不下（会卡进地形），留在原地", why, #cands)
    end
    return nil
end

-- lobbyStep 每次调：放下后掉出地图 → 放回起点 / 传送前站稳的地方
function SAFE.step()
    local g = SAFE.guard
    if not g then return end
    if BASEHOOK.otherScene() then SAFE.guard = nil; return end      -- §141 观战（别的玩法占着对局）时角色藏着、冻着，不挪它
    if now() > g.till or not valid(g.actor) then SAFE.guard = nil; return end
    if HOV.has(g.actor) then return end     -- 悬空等地中，HOV 管
    local loc = try("safe guard", function() return g.actor:K2_GetActorLocation() end)
    if not loc then return end
    local drop = g.z - loc.Z
    local void = drop > SAFE_FALL
    if not void and drop > SAFE.VOID then
        local st = G.airOf(g.actor)
        void = st ~= nil and st.falling and HOV.floor(g.actor, loc, SAFE.VOID_DEPTH) == false
    end
    if not void then return end
    SAFE.guard = nil
    local to, what = g.from, "起点"
    if g.back and HOV.floor(g.actor, g.from, SAFE.DEPTH) ~= true then to, what = g.back, "传送前站的地方" end
    pcall(function() g.actor:K2_SetActorLocation(to, false, {}, true) end)
    local cm = rawProp(g.actor, "CharacterMovement")
    if valid(cm) then pcall(function() cm.Velocity = { X = 0.0, Y = 0.0, Z = 0.0 } end) end
    out("!! %s 之后掉出地图（往下掉了 %.0f，落点外面是虚空？），放回%s (%.0f, %.0f, %.0f)", g.why, drop, what, to.X, to.Y, to.Z)
    HOV.hold(g.actor, to, g.why .. "（掉下去放回）", now(), { back = (to ~= g.back) and g.back or nil })
end

local function setArena(x, y, z, yaw)
    MATCH.arena = { x = x, y = y, z = z, yaw = yaw }
    local r = math.rad(yaw)
    -- 中心在主机按 F4 时所站位置的正前方 SPAWN_D：主机出生点 = 原地，客机在中心另一侧 SPAWN_D
    MATCH.center = { X = x + math.cos(r) * SPAWN_D, Y = y + math.sin(r) * SPAWN_D, Z = z }
end

local function spawnPoint()
    local sp = MATCH.sp      -- §238 检查过的开战点
    if sp then
        local p = MATCH.role == "host" and sp.host or sp.cli
        return { X = p.X, Y = p.Y, Z = p.Z }, MATCH.role == "host" and sp.yaw or sp.yaw + 180.0
    end
    local c, r = MATCH.center, math.rad(MATCH.arena.yaw)
    local s = MATCH.role == "host" and -1 or 1
    local yaw = MATCH.role == "host" and MATCH.arena.yaw or MATCH.arena.yaw + 180.0
    return { X = c.X + math.cos(r) * SPAWN_D * s, Y = c.Y + math.sin(r) * SPAWN_D * s, Z = c.Z + 20.0 }, yaw
end

-- ---- v0.15.0 中英文切换（用户 2026-11-04："exe 加中英文切换，游戏里新增的文字也一起切"）。（→ fornet_core.lua，F3）
-- LANG / langPoll / T 在 fornet_core.lua；中文字体路径在上面装模块时给（LANG.umg 由 UMG 那段设）
local LANG, langPoll, T = FN.LANG, FN.langPoll, FN.T

-- ---- 屏幕文字：在场地中心上方生成一个 TextRenderActor，每帧转向镜头。
-- 引擎默认字体没有中文字形；中文走 LANG.font（见上）
local function textActor(p1)
    if valid(MATCH.text) then return MATCH.text end
    if MATCH.textFailed then return nil end
    MATCH.textFailed = true            -- 只试一次，失败就只写日志
    local cls = StaticFindObject("/Script/Engine.TextRenderActor")
    local world = try("text world", function() return p1:GetWorld() end)
    out("  [步骤] 生成文字 TextRenderActor（类 %s，世界 %s）", tostring(valid(cls)), tostring(valid(world)))
    local a = (valid(cls) and valid(world)) and try("spawn text", function()
        return world:SpawnActor(cls, { X = 0.0, Y = 0.0, Z = 0.0 }, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 })
    end) or nil
    local comp = valid(a) and rawProp(a, "TextRender") or nil
    if not valid(comp) then out("!! 生成屏幕文字失败，比分只写日志"); return nil end
    pcall(function() comp:SetWorldSize(HUD_SIZE) end)
    pcall(function() comp:SetHorizontalAlignment(1) end)     -- EHTA_Center
    pcall(function() comp:SetVerticalAlignment(1) end)       -- EVRTA_TextCenter
    pcall(function() comp:SetTextRenderColor({ R = 255, G = 215, B = 90, A = 255 }) end)
    MATCH.text, MATCH.textComp, MATCH.textFailed, MATCH.shown = a, comp, false, false
    out("  文字已生成：%s", short(pathOf(a)))
    return a
end

local function setText(s)
    local comp = MATCH.textComp
    if s == MATCH.shown or not valid(comp) then return end
    MATCH.shown = s
    pcall(function() MATCH.text:SetActorHiddenInGame(s == nil) end)
    if not s then return end
    -- v0.10.0 / v0.10.2 两次"倒计时第一行字一出来就崩"的真正原因：这个 UE4SS 里 FText 的类型是 userdata（可调用），
    -- 不是 function，旧写法于是把 Lua 字符串直接传给了 FText 参数 → UE4SS 崩。F2 测试里先 FText(...) 再传就没事（5/5）
    local okF, ft = pcall(function() return FText(s) end)
    if not okF then
        if not MATCH.textErr then MATCH.textErr = true; out("!! 构造 FText 失败：%s，不显示文字", tostring(ft)) end
        return
    end
    local ok, err = pcall(function() comp:K2_SetText(ft) end)
    if not ok and not MATCH.textErr then MATCH.textErr = true; out("!! 设置文字失败：%s", tostring(err)) end
end

-- v0.14.1 HUD（用户 2026-11-04："分两行，NOT READY 红字、READY 绿字"，"其他部分的文字也做一下"）。
-- F3b-6（docs/FORNET_SPLIT.md）：屏幕文字底座（颜色 / UMG / 3D TextRender 退路 / hudLog）搬到 fornet_hud.lua；这里只装模块、取别名，行为一字不差
local HD = (function()
    local ok, mk = pcall(require, "fornet_hud")
    if ok and FORNET and FORNET.adopt then mk = FORNET.adopt("fornet_hud", mk) end     -- F6：实例登记到宿主（FORNET.mods）
    if not ok then ok, mk = pcall(dofile, ROOT .. "/Scripts/fornet_hud.lua") end
    if not (ok and type(mk) == "function") then error("fornet_hud.lua 加载失败：" .. tostring(mk)) end
    -- 11-26：fornet_hud 只拿 gstat 问 IsGamePaused（游戏菜单开着就藏屏幕文字 / 准备对局中取消暂停）→ 换成"游戏菜单真开着"，UUU 相机 mod 的暂停不算
    local menuStat = { IsGamePaused = function() return G.menuOpen() == true end }
    return mk({ out = out, valid = valid, try = try, rawProp = rawProp, getP1PC = getP1PC, gstat = function() return menuStat end, LANG = LANG, HUD_SIZE = HUD_SIZE,
                MATCH = MATCH, setText = setText, ST = ST })
  end)()     -- 缩进：这段在 M4 闭包里，test_forget_world 用第 0 列的 end)() 找闭包结尾
local COL_LABEL, COL_WHITE, COL_GRAY, COL_GREEN, COL_RED, COL_ORANGE = HD.COL_LABEL, HD.COL_WHITE, HD.COL_GRAY, HD.COL_GREEN, HD.COL_RED, HD.COL_ORANGE
FMATCH.COL.RED = COL_RED     -- F4a：RFP.rows（双方规则不一致的横幅）用
local HUD, HUD_PX, HUD_ROWS, HUD_Y = HD.HUD, HD.HUD_PX, HD.HUD_ROWS, HD.HUD_Y
local hudLog, setHud, showHud, umgColor, umgRoot, umgSet = HD.hudLog, HD.setHud, HD.showHud, HD.umgColor, HD.umgRoot, HD.umgSet

-- v0.10.3 用户反馈"文字非常晃"：主循环 33ms 才摆一次，镜头每帧都在动，文字总慢半拍。
-- 改成摆好一次后挂到 PlayerCameraManager 上（KeepWorld），由引擎每帧带着走。
-- 挂之前先确认 PlayerCameraManager 自己的位置就是镜头位置；不是的话退回"每帧摆一次"（startFeedLoop 里调 M4.place）
local function hudPose()
    local cm, cam, cr
    pcall(function()
        cm = getP1PC().PlayerCameraManager
        cam, cr = cm:GetCameraLocation(), cm:GetCameraRotation()
    end)
    if not (cam and cr) then return nil end
    local yw, pt = math.rad(cr.Yaw), math.rad(cr.Pitch)
    local fx, fy, fz = math.cos(pt) * math.cos(yw), math.cos(pt) * math.sin(yw), math.sin(pt)
    -- 文字正面朝 +X（v0.10.1 的 F2 测试：转向镜头后能正常读），所以朝向 = 镜头方向反过来
    return cm, cam, { X = cam.X + fx * HUD_D, Y = cam.Y + fy * HUD_D, Z = cam.Z + fz * HUD_D + HUD_UP },
        { Pitch = -cr.Pitch, Yaw = cr.Yaw + 180.0, Roll = 0.0 }
end

local function placeText()
    local a = MATCH.text
    if not (valid(a) and MATCH.shown) then return end
    if MATCH.hudMode == "attached" and valid(MATCH.hudParent) then return end
    local cm, cam, pos, rot = hudPose()
    if not pos then return end
    pcall(function() a:K2_SetActorLocationAndRotation(pos, rot, false, {}, true) end)
    if MATCH.hudMode ~= nil and not (MATCH.hudMode == "attached" and not valid(MATCH.hudParent)) then return end
    -- 第一次（或挂的镜头管理器没了）：试着挂上去
    local okL, cml = pcall(function() return cm:K2_GetActorLocation() end)
    local d = (okL and cml) and math.sqrt((cml.X - cam.X) ^ 2 + (cml.Y - cam.Y) ^ 2 + (cml.Z - cam.Z) ^ 2) or -1
    if d < 0 or d > 50.0 then
        MATCH.hudMode = "frame"
        out("文字跟镜头：镜头管理器位置离镜头 %.0f，不能挂，改为每帧摆位", d)
        return
    end
    out("  [步骤] 文字 K2_AttachToActor(PlayerCameraManager, None, KeepWorld×3, false)")
    local ok, r = pcall(function() return a:K2_AttachToActor(cm, FName("None"), 1, 1, 1, false) end)
    if ok and r ~= false then
        MATCH.hudMode, MATCH.hudParent = "attached", cm
        out("文字已挂到镜头上（镜头管理器离镜头 %.0f），返回 %s", d, tostring(r))
    else
        MATCH.hudMode = "frame"
        out("文字挂到镜头失败（%s），改为每帧摆位", ok and tostring(r) or tostring(r))
    end
end

-- 每帧调用（startFeedLoop）：只在挂不上镜头时才摆位
local function placeTextFrame()
    if MATCH.hudMode == "frame" and MATCH.shown then
        local _, _, pos, rot = hudPose()
        if pos then pcall(function() MATCH.text:K2_SetActorLocationAndRotation(pos, rot, false, {}, true) end) end
    end
end

-- 2) 替身阵营跟着对局走（用户 2026-11-03 23:5x）：对局外和玩家同阵营（友方，不会互砍），
--    倒计时开始到对局结束是敌对。替身由 CreatePlayer 造出来时本来就是 Faction.Player
local FRIEND, FOE = "Faction.Player", "Faction.Enemy"

-- §194.2 替身的阵营组件：按替身路径记一个（换了替身重找）。11-10 双开复测：分身放完以后 替身·召唤物 一直 ~24 ms/秒，
-- 是召唤物跟随每 6 次驱动读一次替身阵营 factionName(pup)，替身没有 FactionComponent 属性就退回 FindAllOf("FactionComponent")
-- 全图扫（syncFaction 每 15 次驱动也这样读一次）
PUPFC = { key = nil, fc = nil }
function PUPFC.of(pup)
    local k = pathOf(pup)
    if PUPFC.key ~= k or not valid(PUPFC.fc) then PUPFC.key, PUPFC.fc = k, factionComp(pup) end
    return PUPFC.fc
end

local function syncFaction(force)
    local pup = puppet()
    if not valid(pup) or MATCH.zmHold then return end
    if not force and ST.ticks % 15 ~= 0 then return end
    -- §173 倒计时无敌没挂上（RT.shield == false）：倒计时里替身当友方，不互砍
    local want = (MATCH.role and MATCH.state ~= "idle" and not (MATCH.state == "cd" and RT.shield == false)) and FOE or FRIEND
    local pfc = PUPFC.of(pup)          -- §194.2 替身的阵营组件记着用（替身身上没有 FactionComponent 属性时 factionComp 每次全图扫）
    local cur = factionName(pup, pfc)
    if cur == want or (MATCH.facRetryAt and now() < MATCH.facRetryAt) then return end
    local fc = pfc
    local ok = valid(fc) and pcall(function() fc:SetFaction({ TagName = FName(want) }) end)
    local rel = "?"
    pcall(function() rel = tostring(factionComp(getP1()):GetFactionRelation(pup)) end)
    out("替身阵营 %s -> %s（%s）；玩家1→替身 关系=%s（%s）", cur, want, ok and "成功" or "失败", rel,
        want == FOE and "对局中：敌对，2=敌对" or "对局外：友方")
    MATCH.facRetryAt = (not ok) and now() + 5.0 or nil
end

-- 3) §94 替身的召唤物阵营跟着替身（v0.27.14）。绝影分身 GA_Hun_Double_JueYing_Clone_C 这类召唤物生成时是玩家阵营，
--    替身对局中是敌对 → 本机看到的是对方的分身回头砍替身（2026-11-05 19:13 日志：替身放分身后自己一直掉杀气），
--    对方那边看到的是砍你。替身放名字带 Clone / Summon 的招后 WINDOW 秒内、对局中每 BG_EVERY 次驱动（影之武装的召唤被动不走出招事件）
--    扫一遍带阵营组件的角色：主人（Owner / Instigator）是替身或替身控制器的，阵营改成和替身一样
-- 全局（不是 local）：主代码块的 local 已满 200 个
SUMMON = { WINDOW = 5.0, EVERY = 6, BG_EVERY = 150, LOG_MAX = 8, kind = {}, nKind = 0, mine = {}, fc = {}, fail = {}, GIVE_UP = 3, oldLogged = {},
           st = {}, REVERT_MAX = 4, AFTER_FOUND = 0.5, found = nil, EDGE = { "JianKeZhaoJiLing", "CaoOuSiXian", "KuYeSiZhuChuan", "XuKongHuaShan" } }
-- §242 哪些招之后要去找替身的召唤物：名字带 Clone / Summon 的（§94），以及 4 件召唤类影之武装的召唤招
-- （GA_JianKeZhaoJiLing_Normal_01 / GA_CaoOuSiXian_Normal_01 / GA_KuYeSiZhuChuan_Normal_01 / GA_XuKongHuaShan_Skill / Reborn；
--  这 4 件的名字里没有 Summon，以前 ST.summonArmAt 不置位 → 召出来的东西永远认不出、阵营不改，打不到人）
-- net/summon_fix_off.txt 存在 = 只保留 §94 原来的（名字带 Clone / Summon、只认 BP_Monster_Hun_Summon_*）
SUMMON.FIX_OFF = (NET_DIR or "net") .. "/summon_fix_off.txt"
function SUMMON.fixOff()
    local f = io.open(SUMMON.FIX_OFF, "r")
    if f then f:close(); return true end
    return false
end
function SUMMON.armName(name)
    if not name or name:find("Passive", 1, true) then return false end
    if name:find("Clone", 1, true) or name:find("Summon", 1, true) then return true end
    if SUMMON.fixOff() then return false end
    for _, fam in ipairs(SUMMON.EDGE) do
        if name:find(fam, 1, true) then return true end
    end
    return false
end

-- §194 线上"绝影分身有几率大卡顿"（宇 11-09 日志）：分身认出来以后每 EVERY 次驱动（~15 次/秒）对一遍阵营，
-- 分身身上没有 FactionComponent 属性，factionName / factionComp 每次都退回 FindAllOf("FactionComponent") 全图扫；
-- 改阵营又一直失败（4584 行"阵营 -> Faction.Enemy（失败）：跟着替身"，一个分身 ~300 次），3–4 个分身同时在时
-- 光这一项 44 ms/秒、怪多的图更重。现在：阵营组件用扫描时拿到的那个（SUMMON.fc）；失败后隔 1 / 2 / 4 秒再试，
-- 连败 GIVE_UP 次就不再管这个召唤物；成功的照记日志，失败只记第一次和放弃那次
function SUMMON.set(a, want, why, tn)
    local p = pathOf(a)
    local f = SUMMON.fail[p]
    if f and (f.n >= SUMMON.GIVE_UP or (tn and tn < f.at)) then return false end
    local fc = SUMMON.fc[p]
    if not valid(fc) then fc = factionComp(a); SUMMON.fc[p] = fc end
    local ok, err = false, "没有阵营组件"
    if valid(fc) then ok, err = pcall(function() fc:SetFaction({ TagName = FName(want) }) end) end
    if ok then
        SUMMON.fail[p] = nil
        -- §194.1 设完马上读回：读回不是要的（游戏不认这次写 / 我们读的不是同一个东西）→ 记一次、不再设，免得每次核对都"要改"
        local rb = factionName(a, fc)
        local s = SUMMON.st[p] or { reverts = 0 }
        SUMMON.st[p] = s
        if rb ~= want then
            s.stuck, s.want = true, want
            SUMMON.mine[p], SUMMON.fc[p] = nil, nil       -- §194.2 不再跟（读回 None 多半是分身正在消失）：跟随循环里也不再碰它
            out("替身的召唤物 %s 阵营设成 %s 调用成功，但马上读回是 %s：读写对不上，不再反复设（%s）", short(a), want, tostring(rb), why)
            return false
        end
        s.want, s.setAt = want, tn
        -- §245 每次设成功都把锁定目标重指你（AI 会自己转身 / 回主人身边）：以前只记日志那一次设，
        -- 之后召唤物再锁回替身就不管了 → 用户看到"都围着替身、不打本机玩家"。
        if want == FOE then setLockTarget(a, PEER.tgt()) end
        if s.logged ~= want then        -- 每个召唤物每种阵营只记一次成功（对局开始 / 结束翻转时各记一次）
            s.logged = want
            out("替身的召唤物 %s 阵营 -> %s（成功，读回 %s）：%s", short(a), want, tostring(rb), why)
        end
        return true
    end
    f = f or { n = 0 }
    f.n, f.at = f.n + 1, (tn or 0) + 2 ^ f.n
    SUMMON.fail[p] = f
    if f.n == 1 then out("替身的召唤物 %s 阵营 -> %s（失败 %s）：%s", short(a), want, tostring(err), why)
    elseif f.n == SUMMON.GIVE_UP then out("替身的召唤物 %s 阵营连续 %d 次改不了，不再管它", short(a), f.n) end
    return false
end

-- §118 绝影分身 BP_Monster_Hun_Summon_Double_C 的 Owner 是它自己的 AI 控制器、Instigator 是它自己（2026-11-05 21:54–22:18
-- 日志 8 次"主人不是替身，不改"），按主人认不出。替身刚放召唤后新出现的算替身的；
-- §242 剑客召集令 / 草偶丝线 / 枯叶丝竹串 / 虚空化山 召出来的 NPC / 场地物也是主人认不出（不是 BP_Monster_Hun_Summon_ 开头），
-- 以前这条直接 return nil → 阵营一直是玩家方，不打人（实测 4 件召唤后 5 秒 0 伤害）。现在召唤窗口里新出现的阵营角色都算，
-- 只有"我自己这几秒也放过召唤"时才按离谁近分；主人明确是我 / 替身的仍然按主人（上面先判过，进不来）。
-- §450 这几样永远不是召唤物（11-25 mp_probe(43) 观战：把观众自己的角色、另一位选手的替身、关卡里摆的柴堆 BP_Firewood_003_C 都认成了
-- "替身刚放召唤后新出现"、改了阵营，还一直跟着替身改）：玩家角色类（自己 / 所有替身都是 BP_Renewal_Hun_C）、
-- 关卡里摆好的东西（世界分区的 Actor 名带 _UAID_，运行时生成的召唤物没有）、本机自己的角色
function SUMMON.never(e)
    if e.cls == "BP_Renewal_Hun_C" then return "玩家角色类" end
    if e.path and e.path:find("_UAID_", 1, true) then return "关卡里摆的" end
    local okM, me = pcall(getP1)
    if okM and valid(me) and e.path == pathOf(me) then return "本机角色" end
    return nil
end

-- §451 11-25 mp_probe(45)/(46) 两边都用绝影：本机自己几秒前放的分身被认成"替身的"、改成敌方、锁定我
-- （一个分身不动 / 两个分身都打一个人）。原因：替身一放召唤，第一遍扫描只当基准、不记已有的，
-- 下一遍我那个还活着的分身就成了"第一次见"→ 类名直接认（我放的超过 5 秒）或"离替身更近"（对打时常常更近）。
-- 冷却中空放的分身招也会照发过来，同样开扫描把我的分身认走。
-- 修：召唤物存在的时间比替身这招放出到现在还长（+ AGE_SLACK）= 替身放之前就在了，不是这次召出来的。
-- 读不到存在时间就照旧判。慢动作时游戏时间走得慢，读到的偏短 → 只会退回照旧判，不会把真召唤物挡掉。
SUMMON.AGE_SLACK = 0.5
function SUMMON.ageOf(actor)
    local ok, v = pcall(function() return actor:GetGameTimeSinceCreation() end)
    if ok and type(v) == "number" then return v end
    return nil
end

function SUMMON.byClass(e, pup, p1, tn)
    if not (ST.summonArmAt and tn - ST.summonArmAt < SUMMON.WINDOW) then return nil end
    if SUMMON.never and SUMMON.never(e) then return nil end
    local age = e.actor and SUMMON.ageOf and SUMMON.ageOf(e.actor)
    if age and age > tn - ST.summonArmAt + (SUMMON.AGE_SLACK or 0.5) then
        SUMMON.oldLogged = SUMMON.oldLogged or {}
        if not SUMMON.oldLogged[e.path] then
            SUMMON.oldLogged[e.path] = true
            out("  §451 %s 已经存在 %.1f 秒，替身这招才放出 %.1f 秒：放之前就在（多半是我自己的），不算替身的",
                short(e.actor), age, tn - ST.summonArmAt)
        end
        return nil
    end
    if SUMMON.fixOff() then
        if not (e.cls and e.cls:find("^BP_Monster_Hun_Summon_")) then return nil end
        if not (ST.p1SummonAt and tn - ST.p1SummonAt < SUMMON.WINDOW) then return "类名，替身刚放召唤" end
    end
    local p1Path = valid(p1) and pathOf(p1) or nil
    if p1Path and (e.owner == p1Path or e.inst == p1Path) then return nil end
    local a = try("summon loc", function() return e.actor:K2_GetActorLocation() end)
    local b = try("pup loc", function() return pup:K2_GetActorLocation() end)
    local c = valid(p1) and try("p1 loc", function() return p1:K2_GetActorLocation() end)
    if not (a and b) then return nil end
    if ST.p1SummonAt and tn - ST.p1SummonAt < SUMMON.WINDOW and c then
        local function d2(u, v) return (u.X - v.X) ^ 2 + (u.Y - v.Y) ^ 2 end
        if d2(a, b) < d2(a, c) then return "两边都放了召唤、离替身更近" end
        return nil
    end
    if e.cls and e.cls:find("^BP_Monster_Hun_Summon_") then return "类名，替身刚放召唤" end
    return "替身刚放召唤后新出现"
end

function SUMMON.step(p1, pup, tn)
    if not valid(pup) then return end
    local want
    for p, a in pairs(SUMMON.mine) do         -- 已认出的：对局开始 / 结束时替身阵营会变，跟着改
        if not valid(a) then SUMMON.mine[p], SUMMON.fc[p], SUMMON.fail[p], SUMMON.st[p] = nil, nil, nil, nil
        elseif ST.ticks % SUMMON.EVERY == 0 and not (SUMMON.fail[p] and SUMMON.fail[p].n >= SUMMON.GIVE_UP) then
            local s = SUMMON.st[p]
            want = want or factionName(pup, PUPFC.of(pup))
            -- §245 每轮核对都重指锁定目标（阵营没变也指）：召唤物的 AI 会自己转身 / 回主人身边，
            -- 只改一次阵营不够，用户看到的是"围着替身、不打本机玩家"。
            if want == FOE then setLockTarget(a, PEER.tgt()) end
            if s and s.want and s.want ~= want then s.stuck, s.gaveUp, s.next, s.reverts, s.setAt = nil, nil, nil, 0, nil end   -- 对局开始 / 结束翻了：重新来
            if not (s and (s.stuck or s.gaveUp or (s.next and tn < s.next))) then
                local cur = factionName(a, SUMMON.fc[p])
                if cur ~= want then
                    -- §194.1 11-10 双开：设成功后下一次核对又不是 Enemy，同一个分身每秒设 4–5 次（264 行），替身·召唤物 26–44 ms/秒。
                    -- 设成功过、读回也对，现在又变了 = 被游戏改回：记第一次（改回成什么、隔了几秒），1 / 2 / 4 / 8 秒后再设，REVERT_MAX 次后不管
                    if s and s.want == want and s.setAt then
                        s.reverts = s.reverts + 1
                        if s.reverts == 1 then
                            out("替身的召唤物 %s 阵营被改回 %s（设成 %s 后 %.1f 秒）", short(a), tostring(cur), want, tn - s.setAt)
                        end
                        if s.reverts > SUMMON.REVERT_MAX then
                            s.gaveUp = true
                            SUMMON.mine[p], SUMMON.fc[p] = nil, nil      -- §194.2 不再跟
                            out("替身的召唤物 %s 阵营被改回 %d 次，不再管它（最后是 %s）", short(a), s.reverts - 1, tostring(cur))
                        else
                            s.next = tn + 2 ^ (s.reverts - 1)
                        end
                    end
                    if not (s and s.gaveUp) then SUMMON.set(a, want, "跟着替身", tn) end
                end
            end
        end
    end
    -- §245 召唤窗口结束记一行：认出来几个、几个已经是敌对（下次实测一眼看出阵营 / 锁定有没有生效）。
    -- 放在扫描的节流判断前面：扫描每 BG_EVERY 次才来一遍，窗口结束那一刻不一定正好撞上。
    if ST.summonArmAt and tn - ST.summonArmAt >= SUMMON.WINDOW and SUMMON.sumAt ~= ST.summonArmAt then
        SUMMON.sumAt = ST.summonArmAt
        local n, foes, names = 0, 0, {}
        for p, a in pairs(SUMMON.mine) do
            if valid(a) then
                n = n + 1
                local f = factionName(a, SUMMON.fc[p])
                if f == FOE then foes = foes + 1 end
                if #names < 6 then names[#names + 1] = short(a) .. "=" .. tostring(f) end
            end
        end
        out("§245 召唤窗口结束（%s）：认出来 %d 个召唤物，其中敌对 %d 个%s", tostring(ST.summonName or "?"),
            n, foes, #names > 0 and ("：" .. table.concat(names, " ")) or "")
    end
    local armed = ST.summonArmAt ~= nil and tn - ST.summonArmAt < SUMMON.WINDOW
    -- §194.3 这次放召唤已经认出替身的召唤物了：再多扫 AFTER_FOUND 秒（一招出好几个的接着认），之后这一招不再每 6 次驱动全图扫
    -- （11-10 13:49 实测：放分身后那 5 秒 ·召唤物扫描 19.8 / 12.1 ms/秒，几乎全是找到之后还在扫）。漏掉的晚出现的由对局中后台扫描兜
    local f = SUMMON.found
    if armed and f and f.arm == ST.summonArmAt and tn - f.at > SUMMON.AFTER_FOUND then armed = false end
    if armed then
        if ST.ticks % SUMMON.EVERY ~= 0 then return end
    elseif not (MATCH.role and MATCH.state ~= "idle" and ST.ticks % SUMMON.BG_EVERY == 0) then
        return
    end
    -- 刚放召唤的第一遍只当基准（召唤物要等动作放到那一帧才出来），之后新出现又不是替身的写进日志，认不出主人时好查
    local quiet = SUMMON.armSeen ~= ST.summonArmAt
    SUMMON.armSeen = ST.summonArmAt
    if quiet then SUMMON.logged = 0 end
    if SUMMON.nKind > 3000 then SUMMON.kind, SUMMON.nKind = {}, 0 end
    local pupPath, p1Path = pathOf(pup), pathOf(p1)
    local pcPath = valid(ST.secondPC) and pathOf(ST.secondPC) or nil
    for _, e in ipairs(G.factionActors(SUMMON.kind)) do
        if e.cls and e.path ~= pupPath and e.path ~= p1Path then        -- 第一次见
            local link = (e.owner == pupPath and "Owner=替身") or (e.inst == pupPath and "Instigator=替身")
                or (pcPath and (e.owner == pcPath or e.inst == pcPath) and "主人=替身控制器")
                or (armed and not quiet and SUMMON.byClass(e, pup, p1, tn)) or nil
            -- §245 刚放召唤的第一遍是基准帧，这时新出现的先别记成 other（记了以后再也不看它；
            -- 召唤物经常正好在这一帧生成 → 整个窗口都认不出来）。下一帧再看。
            if link or not (armed and quiet) then
                SUMMON.kind[e.path], SUMMON.nKind = link and "pup" or "other", SUMMON.nKind + 1
            end
            if link then
                if armed and not (SUMMON.found and SUMMON.found.arm == ST.summonArmAt) then SUMMON.found = { arm = ST.summonArmAt, at = tn } end   -- §194.3
                SUMMON.mine[e.path], SUMMON.fc[e.path] = e.actor, e.fc
                SUMMON.set(e.actor, factionName(pup, PUPFC.of(pup)), string.format("%s，%s", e.cls, link), tn)
            elseif armed and not quiet and SUMMON.logged < SUMMON.LOG_MAX then
                SUMMON.logged = SUMMON.logged + 1
                out("  替身放召唤后新出现 %s（%s）Owner=%s Instigator=%s 阵营=%s：主人不是替身，不改",
                    short(e.actor), e.cls, short(e.owner or "-"), short(e.inst or "-"), factionName(e.actor))
            end
        end
    end
end

-- ---- v0.21.0 和 Phantom Pact（第三方合作模组，装在同级的 PBZCoop）共存。两边同时联机 = 它给对方生成友方无敌幽灵、
-- 我们再生成敌对替身，画面上两个对手、锁血 / 死亡流程互相干扰。它的中继每秒重写一行 PBZCoop/net_status.txt：
--   role=host via=steam connected=no peer=- … stopped=… time=<unix 秒>
-- connected=yes（且没有 stopped=yes、time 不旧于 PP_STALE 秒）= 它在联机：我们不生成 / 藏起替身、F1 不能准备、面板状态行提示。
-- 文件不存在 = 没装；读不到 / 格式不对（它写到一半）沿用上次结果，坏满 PP_STALE 秒才当断开。每秒最多读一次，全程不报错
local PP = { on = false, at = 0, goodAt = 0, info = nil, why = "未检测", warnTill = 0 }
local PP_STALE = 10
PP.FILE = (ROOT:match("^(.*)/[^/]+$") or "..") .. "/PBZCoop/net_status.txt"

-- 一行 k=v（空格分隔）→ 表；没有合法的 connected 字段 = 格式不对，返回 nil
function PP.parse(text)
    local t = {}
    for k, v in (tostring(text or "")):match("^[^\r\n]*"):gmatch("([%w_]+)=(%S*)") do t[k] = v end
    if t.connected ~= "yes" and t.connected ~= "no" then return nil end
    return t
end

local function ppRead()
    local okO, f = pcall(io.open, PP.FILE, "r")
    if not okO or not f then return nil, "missing" end
    local okR, data = pcall(f.read, f, "*a")
    pcall(f.close, f)
    local info = okR and PP.parse(data) or nil
    if not info then return nil, "bad" end
    return info
end

-- 返回 PP.on。状态变化写一行日志；我们的对局中它连上 → 再记一行 + 屏幕提示一次（PP.warnTill）
function PP.poll()
    local t = os.time()
    if t < PP.at then return PP.on end
    PP.at = t + 1
    local info, err = ppRead()
    local on, why = PP.on, PP.why
    if info then
        PP.goodAt, PP.info = t, info
        local ts = tonumber(info.time)
        if info.connected ~= "yes" then on, why = false, "connected=no"
        elseif info.stopped == "yes" then on, why = false, "stopped=yes"
        elseif ts and math.abs(t - ts) > PP_STALE then on, why = false, string.format("状态文件 %d 秒没更新", t - ts)
        else on, why = true, "connected=yes" end
    elseif err == "missing" then
        on, why = false, "没有 net_status.txt"
    elseif t - PP.goodAt > PP_STALE then
        on, why = false, "net_status.txt 格式不对"
    end
    if on ~= PP.on then
        PP.on = on
        local i = PP.info or {}
        if on then
            out("Phantom Pact 合作联机已连上（role=%s via=%s peer=%s）：PvP 暂停——不生成替身、不能准备",
                tostring(i.role), tostring(i.via), tostring(i.peer))
            if MATCH.role then
                out("!! PvP 对局 #%d 进行中检测到 Phantom Pact 也连上了：两个模组的对手会叠在一起，建议认输后在 F5 面板里离开 Phantom Pact", MATCH.id)
                PP.warnTill = t + 5
            end
        else
            out("Phantom Pact 合作联机已断开（%s），PvP 恢复正常", why)
        end
    end
    PP.why = why
    return on
end

function PP.text()
    return T("Phantom Pact 联机中，先在 F5 面板离开", "PHANTOM PACT CO-OP IS ON - LEAVE IT IN ITS PANEL FIRST")
end

function PP.rows()
    return { { c = T("Phantom Pact 合作联机中", "PHANTOM PACT CO-OP IS ON"), col = COL_ORANGE, size = 1.3 },
             { c = T("请先在 F5 面板里离开", "LEAVE IT IN ITS F5 PANEL FIRST"), col = COL_LABEL } }
end

-- 对局中它刚连上时的一次性提示（5 秒）
function PP.warnRows()
    return os.time() < PP.warnTill and PP.rows() or nil
end

local function iWon()
    return (MATCH.role == "host" and MATCH.win == "h") or (MATCH.role == "client" and MATCH.win == "c")
end

local QUIT_SEC = 3

local function scoreRow()
    return { c = string.format(T("我方   %d : %d   对方", "YOU   %d : %d   OPPONENT"), MATCH.me, MATCH.op), col = COL_WHITE }
end

-- 对局中的提示（HUD 行，见 setHud）
-- 11-17 排查补齐：倒计时里"不是默认值的规则"一行（§86）从旧版 1v1 的 matchRows 拆出来，新版房间（多人 / 对决）倒计时也显示
function NET.rulesList(room)
    local rules = {}
    local dm = MATCH.dmPct or 100
    if dm ~= 100 then rules[#rules + 1] = string.format(T("伤害 %d%%", "DAMAGE %d%%"), dm) end
    if MATCH.ab then rules[#rules + 1] = T("全部可格挡", "ALL MOVES BLOCKABLE") end
    if not room and (MATCH.tl or 0) ~= NET.RES_DEF.tl then       -- §173 回合时限不是默认 180 秒时写出来（房间的时限另有显示，不在这里写）
        local tx = NET.resText("tl", MATCH.tl or 0)
        rules[#rules + 1] = (MATCH.tl or 0) > 0 and string.format(T("限时 %s", "TIME LIMIT %s"), T(tx[1], tx[2])) or T("不限时", "NO TIME LIMIT")
    end
    if MATCH.flags and MATCH.flags.ctr == false then rules[#rules + 1] = T("无红蓝光反击", "NO RED/BLUE COUNTERS") end   -- §105.3
    if MATCH.flags and MATCH.flags.bal then rules[#rules + 1] = T("武器平衡", "WEAPON BALANCE") end                     -- §106.5
    if MATCH.flags and MATCH.flags.med == false then rules[#rules + 1] = T("禁用血瓶", "NO POTIONS") end                -- §108
    if MATCH.flags and MATCH.flags.dgc then rules[#rules + 1] = T("闪避扣杀气", "DODGE COSTS SHACHI") end             -- §216
    if MATCH.flags and MATCH.flags.sycd then rules[#rules + 1] = T("瞬影冷却", "FLASH STEP COOLDOWN") end             -- §216
    if MATCH.flags and MATCH.flags.swk then rules[#rules + 1] = T("切武器保持杀气", "SWITCH KEEPS SHACHI") end         -- 11-16
    if MATCH.flags and MATCH.flags.pdsh then rules[#rules + 1] = string.format(T("被精防扣 %d 杀气", "DEFLECTED: -%d SHACHI"), PDSH.amt()) end   -- §423
    if MATCH.flags and MATCH.flags.stg then rules[#rules + 1] = string.format(T("连续精防 %d 次硬直：近战招 %g 秒 / 远程招 %g 秒", "%d DEFLECTS → STAGGER %gS MELEE / %gS RANGED"), STG.need(), STG.sec(), STG.secRanged()) end   -- §228 / §422
    if STD.active() then rules[#rules + 1] = T("标准数值", "STANDARD STATS") end
    do   -- 0.34：这一局用哪份数值表（主机那份 / 本地）、和服务器下发的是否一致（TASK_0.34 §4 边界：主机表同步保留但要告知）
        local role = MATCH.session and MATCH.session.role
        local fromHost = role == "client" and CFG.rHash and CFG.rHash ~= CFG.localHash and CFG.haveHash == CFG.rHash
        local h = fromHost and CFG.rHash or CFG.localHash
        if h and h ~= "" then
            local srv = CFG.srvHash
            local same = (not fromHost) and CFG.localSrc == "大厅服务器"      -- 本地这份就是大厅服务器下发的那份（localHash 是重编码后的，不能和下发文件的哈希直接比）
            local hostDiff = role == "client" and CFG.rHash and CFG.rHash ~= CFG.localHash and not fromHost     -- §255.4 B：主机的表和我不同、又没收到 → 这一场两边不对称，横幅不能写"一致"
            local note = hostDiff and T("，主机的 " .. tostring(CFG.rHash):sub(1, 8) .. " 未收到，用本地", ", HOST " .. tostring(CFG.rHash):sub(1, 8) .. " NOT RECEIVED, USING LOCAL")
                or same and T("，与服务器一致", ", MATCHES SERVER") or (srv and srv ~= "" and T("，与服务器不同", ", DIFFERS FROM SERVER") or "")
            rules[#rules + 1] = string.format(T("数值表 %s%s%s", "STAT TABLE %s%s%s"), fromHost and T("主机 ", "HOST ") or "", tostring(h):sub(1, 8), note)
        end
    end
    do local am = ACC.mode(); if am ~= 0 then rules[#rules + 1] = T("饰品" .. ACC.MODE_NAME[am], "ACCESSORIES " .. ({ "UNREFINED", "FULLY REFINED", "DISABLED" })[am]) end end   -- §170.1                                         -- §144
    do local an = ACC.limitNow(); if an < 6 then rules[#rules + 1] = string.format(T("饰品只生效前 %d 件", "FIRST %d ACCESSORIES ONLY"), an)
        .. (ACC.slotGuess and T("（按图鉴顺序）", " (BY CATALOG ORDER)") or "") end end   -- §176；§176.1 读不到格子顺序时写明
    if ACC.banNow() ~= NET.ACCBAN_DEF then rules[#rules + 1] = T("禁用饰品：", "BANNED: ") .. T(ACC.banText(ACC.banNow(), 1), ACC.banText(ACC.banNow(), 2)) end   -- §176 和默认名单不一样才显示
    for _, k in ipairs(WBAN.KINDS) do      -- §180 禁用武器 / 影之武装：名单非空才显示
        local b, kn = WBAN.now(k), WBAN.KIND_NAME[k]
        if b ~= "-" then rules[#rules + 1] = T("禁用" .. kn[1] .. "：", "BANNED " .. kn[2] .. "S: ") .. T(WBAN.text(k, b, 1), WBAN.text(k, b, 2)) end
    end
    if CFG.srcNote and (STD.active() or (MATCH.flags and MATCH.flags.bal)) then
        rules[#rules + 1] = T("数值表用本地（和主机不一致）", "LOCAL TABLES (HOST MISMATCH)")                               -- §158
    end
    if MATCH.res then   -- §113 / §113.2
        local tx = NET.resText("resm", MATCH.res.resm or 0)
        rules[#rules + 1] = string.format(T("精纯杀气 %d · 暗源 %d（%s）", "ULT %d · EDGE %d (%s)"), MATCH.res.ult0, MATCH.res.sp0, T(tx[1], tx[2]))
        if (MATCH.res.ultx or 100) ~= 100 then rules[#rules] = rules[#rules] .. string.format(T(" · 精纯杀气获取 %d%%", " · ULT GAIN %d%%"), MATCH.res.ultx) end   -- §113.4（§142 用户：写全"精纯杀气"，"杀气"是另一样东西）
    end
    return rules
end
-- 折好行的规则行（size 可选；房间里放右侧用小一点的字）
function NET.rulesRows(size, room)
    local rows = {}
    for _, ln in ipairs(RT.wrapRules(NET.rulesList(room), RT.RULE_W)) do rows[#rows + 1] = { c = ln, col = COL_ORANGE, size = size } end
    if room and CFG.srvNewer then        -- 旧版 1v1 的倒计时自己另写这一行
        rows[#rows + 1] = { c = T("服务器数值表比模组新，本场用模组自带的，请更新模组", "SERVER TABLE IS NEWER THAN YOUR MOD: UPDATE"),
                            col = COL_RED, size = size, nolog = true }
    end
    return rows
end

local function matchRows(tn)
    local s, el = MATCH.state, tn - MATCH.t0
    if MATCH.quitArm then
        local left = QUIT_SEC - (tn - MATCH.quitArm)
        if left > 0 then
            return { { c = T("认输？", "SURRENDER?"), col = COL_RED, size = 1.6 },
                     { c = string.format(T("再按一次 F1 确认（%d）", "PRESS F1 AGAIN TO CONFIRM  (%d)"), math.ceil(left)), col = COL_LABEL } }
        end
        MATCH.quitArm = nil
        out("认输确认超时，继续对局")
    end
    if s == "cd" then
        local bo = (MATCH.toWin or 2) * 2 - 1     -- v0.26.3 回合数后面带上局数
        local rows = { { c = string.format(T("第 %d 回合 · %d 局 %d 胜", "ROUND %d · BEST OF %d"), MATCH.round, bo, MATCH.toWin or 2), col = COL_LABEL, size = 1.2 } }
        -- §86 第二行：不是默认值的规则（免得双方不知道）；11-17 拆到 NET.rulesList，房间倒计时共用
        for _, r in ipairs(NET.rulesRows()) do rows[#rows + 1] = r end
        for _, r in ipairs(RFP.rows() or {}) do rows[#rows + 1] = r end     -- §210 双方规则不一致
        if CFG.srvNewer then         -- §210 大厅服务器的数值表比我的模组新、没用上（规则指纹也会和新版本对不上）
            rows[#rows + 1] = { c = T("服务器数值表比模组新，本场用模组自带的，请更新模组", "SERVER TABLE IS NEWER THAN YOUR MOD: UPDATE"),
                                col = COL_RED, size = 0.8, nolog = true }
        end
        for _, r in ipairs(FMATCH.rowsOf("cd", tn)) do rows[#rows + 1] = r end     -- 规则来源 / 扩展加的行（排位：我的积分 / 名次）
        rows[#rows + 1] = { c = tostring(math.max(1, math.ceil(CD_SEC - el))), col = COL_WHITE, size = 2.2 }
        return rows
    elseif s == "fight" then
        local rows = {}
        if el < FIGHT_SHOW then rows[1] = { c = T("开战！", "FIGHT!"), col = COL_ORANGE, size = 2.4 } end
        local left = RT.left(tn)          -- §173 回合时限：剩余时间（最后 10 秒红色放大）；每秒都变，不写【提示】日志
        if left then
            local sec = math.ceil(left)
            rows[#rows + 1] = { c = string.format("%d:%02d", math.floor(sec / 60), sec % 60), col = sec <= 10 and COL_RED or COL_WHITE,
                                size = sec <= 10 and 1.2 or 0.8, nolog = true }
        end
        local gh = GCD.hint(tn)           -- §184 我在紫冥剑 DB 里、火枪还在场 / 冷却中（每秒都变，不写日志）
        if gh then rows[#rows + 1] = { c = T(gh[1], gh[2]), col = COL_ORANGE, size = 0.8, nolog = true } end
        for _, dh in ipairs(DCD.hintRows(tn) or {}) do       -- §200 刚拦掉的闪避：冷却还剩几秒
            rows[#rows + 1] = { c = T(dh[1], dh[2]), col = COL_ORANGE, size = 0.8, nolog = true }
        end
        for _, r in ipairs(RFP.rows() or {}) do rows[#rows + 1] = r end     -- §210 双方规则不一致（交手中也挂着）
        for _, r in ipairs(DSTAT and DSTAT.hudRows(tn) or {}) do rows[#rows + 1] = r end     -- §342 木桩 DPS（右侧）
        return #rows > 0 and rows or nil
    elseif s == "rend" then
        local head
        if MATCH.win == "d" then head = { c = T("平局", "DRAW"), col = COL_GRAY, size = 1.8 }
        elseif iWon() then head = { c = T("本回合胜", "ROUND WON"), col = COL_GREEN, size = 1.8 }
        else head = { c = T("本回合负", "ROUND LOST"), col = COL_RED, size = 1.8 } end
        local ri = RT.info
        if ri and ri.round == MATCH.round then      -- §173 时间到判的
            local me, op = ri.h, ri.c
            if MATCH.role == "client" then me, op = ri.c, ri.h end
            return { head, { c = string.format(T("时间到 · 受到伤害 我 %.0f / 对方 %.0f", "TIME UP · DAMAGE TAKEN YOU %.0f / OPPONENT %.0f"), me, op),
                             col = COL_ORANGE }, scoreRow() }
        end
        return { head, scoreRow() }
    elseif s == "end" then
        local won = MATCH.me > MATCH.op
        return { { c = won and T("胜利", "VICTORY") or T("败北", "DEFEAT"), col = won and COL_GREEN or COL_RED, size = 2.4 }, scoreRow() }
    end
    return nil
end


-- 对局非正常结束时的一次性提示，显示 TOAST_SEC 秒
local TOAST_SEC = 3.0
-- 值是函数：按显示那一刻的语言生成
local TOAST_OF = {
    ["按 F1 弃权"] = function() return { { c = T("你已认输", "YOU SURRENDERED"), col = COL_RED, size = 1.6 },
                                        { c = T("对局结束", "MATCH OVER"), col = COL_GRAY } } end,
    ["对方弃权"] = function() return { { c = T("对方认输", "OPPONENT SURRENDERED"), col = COL_GREEN, size = 1.6 },
                                      { c = T("你赢了", "YOU WIN"), col = COL_LABEL } } end,
    -- v0.22.0：客机错过了结算画面（那几秒没收到包），靠主机的可靠事件 mend 补上结果
    ["对局结果"] = function() local won = MATCH.me > MATCH.op
                       return { { c = won and T("胜利", "VICTORY") or T("败北", "DEFEAT"), col = won and COL_GREEN or COL_RED, size = 2.0 },
                                scoreRow() } end,
    ["对方掉线"] = function() return { { c = T("对方掉线", "OPPONENT DISCONNECTED"), col = COL_ORANGE, size = 1.6 },
                                      { c = T("对局取消", "MATCH CANCELLED"), col = COL_GRAY } } end,
    ["主机结束了对局"] = function() return { { c = T("主机结束了对局", "MATCH ENDED BY HOST"), col = COL_ORANGE, size = 1.6 } } end,
    -- §85 用户："从 AI 切换到真人时要给一个提示，XXXX 加入你的房间，AI 对战已关闭"。名字 = 对方状态包的 nm=（没有就不写名字；
    -- 联机程序限 24 字。clipText 定义在后面，这里用不了——lint_order 会报）
    ["真人玩家加入"] = function()
        local nm = NET.swapName
        local head
        if NET.swapAsClient then      -- §116 我是客机：是我加入了别人的房间
            head = nm and string.format(T("你加入了 %s 的房间", "YOU JOINED %s'S ROOM"), nm) or T("你加入了对方的房间", "YOU JOINED THE ROOM")
        else
            head = nm and string.format(T("%s 加入了你的房间", "%s JOINED YOUR ROOM"), nm) or T("有玩家加入了你的房间", "A PLAYER JOINED YOUR ROOM")
        end
        return { { c = head, col = COL_GREEN, size = 1.6 },
                 { c = T("AI 对战已关闭，两边按 F1 准备开打", "AI BATTLE CLOSED - BOTH PRESS F1 TO FIGHT"), col = COL_LABEL } } end,
    -- §85 用户："XXXX 已离开房间。AI 对战已重新开始"
    ["真人玩家离开"] = function()
        local nm = NET.swapName
        return { { c = nm and string.format(T("%s 已离开房间", "%s LEFT THE ROOM"), nm) or T("对方已离开房间", "THE PLAYER LEFT THE ROOM"),
                   col = COL_ORANGE, size = 1.6 },
                 { c = T("AI 对战已重新开始，按 F1 准备开打", "AI BATTLE RESTARTED - PRESS F1 TO FIGHT"), col = COL_LABEL } } end,

}

local function wireUpdate()
    local w = MATCH.wire
    if MATCH.role == "host" then
        w.mt = FMATCH.mtEncode()
        local a = MATCH.arena
        w.arena = FMATCH.arenaEncode(a)
        w.asp = ARN.encode(MATCH.sp)          -- §238 开战点（对局外 ARN.refresh 填存过的）
    else
        w.mt, w.arena, w.asp = "", "", ""
    end
    w.dead = MATCH.role and MATCH.dead or 0
    w.rdy = MATCH.ready and 1 or 0
end

-- §260 用户 11-12："按 F1 确认后，到本场战斗结束前，不能 Esc 进菜单"，细化成"任何打开界面的操作都不能进行"。
--   准备（F1）或在对局里（倒计时 / 交手 / 回合结算 / 结算）时，把游戏开界面的输入映射摘掉（G.uiCtxStrip：Esc 菜单 / 地图 / 拍照 / 感知 + 交互键），
--   取消准备 / 回自由活动挂回。只在事件上调（F1、enter、开局被拒、地图 / 对手变化、掉线），不轮询。
--   兜底（用户："不好做的话，打开界面依然受到伤害也行"）：界面还是开出来、游戏暂停了 → 取消暂停（umgHud 本来就在看暂停切换）
-- 11-19：新版房间（多人房 / 对决）不写 MATCH.ready / MATCH.role，所以这里再问一句玩法 mod（BASEHOOK.mp.uiWant）；
--   want 也可以由调用方显式给（测试 / 特殊场景）
MATCH.uib = { on = false, list = nil, pauseN = 0 }
function MATCH.uiSync(why, want)
    local u = MATCH.uib
    if want == nil then
        want = (MATCH.ready or MATCH.role ~= nil) and true or false
        if not want then
            local mp = BASEHOOK and BASEHOOK.mp
            if mp and mp.uiWant then
                local ok, w = pcall(mp.uiWant)
                want = (ok and w) and true or false
            end
        end
    end
    if want == u.on then return end
    if want then
        local okS, list, desc = pcall(G.uiCtxStrip)
        if not okS then out("!! §260 摘输入映射失败：%s（%s）", tostring(list), why or "-"); return end
        u.on, u.list = true, list
        out("§260 准备 / 对局中不能开界面（%s）：%s", why or "-", tostring(desc))
        -- 兜底：开始屏蔽时游戏已经暂停（开局前菜单就开着）= 不会再触发暂停翻转，这里补一次取消暂停
        if list and #list > 0 then
            local okP, paused = pcall(function() return G.menuOpen() end)     -- 11-26 游戏菜单真开着（UUU 相机 mod 的暂停不算）
            if okP and paused == true then MATCH.uiPaused() end
        end
    else
        local okR, ok, desc = pcall(G.uiCtxRestore, u.list)
        if not okR then out("!! §260 挂回输入映射失败：%s（%s）", tostring(ok), why or "-"); return end
        out("§260 开界面恢复（%s）：%s", why or "-", tostring(desc))
        if ok then u.on, u.list = false, nil end     -- 挂不回：留着 on，下一个事件再试
    end
end
function MATCH.uiPaused()
    local u = MATCH.uib
    if not u.on then return end
    local ok, err = G.unpause()
    u.pauseN = u.pauseN + 1
    if u.pauseN <= 20 then out("§260 准备 / 对局中游戏被暂停（界面开出来了）→ 取消暂停，照常挨打：%s（第 %d 次）", ok and "成功" or ("!! " .. tostring(err)), u.pauseN) end
end

-- ============================================================ §291 1v1 与多人共用规则生命周期函数
function NET.adoptHostRules()
    if NET.rdm then NET.dmCfg = NET.rdm end
    if NET.rab ~= nil then NET.abCfg = NET.rab end
    if NET.rbar ~= nil then NET.barCfg = NET.rbar end
    if NET.rbo ~= nil then NET.boCfg = NET.rbo end
    for _, k in ipairs(NET.FLAG_KEYS) do
        if NET.rflag[k] ~= nil then NET.flagCfg[k] = NET.rflag[k] end
    end
    if NET.flagFix then NET.flagFix() end
    for _, k in ipairs(NET.RES_KEYS) do
        if NET.rres[k] ~= nil then NET.resCfg[k] = NET.rres[k] end
    end
    if NET.raccban ~= nil then NET.accBanCfg = NET.raccban end
    if WBAN and WBAN.r then
        if WBAN.r.wpnban then WBAN.cfg.wpnban = WBAN.r.wpnban end
        if WBAN.r.edgeban then WBAN.cfg.edgeban = WBAN.r.edgeban end
    end
    if CFG and CFG.have and CFG.haveHash then
        CFG.local_ = CFG.decode(CFG.encode(CFG.have))
        CFG.localStr = CFG.encode(CFG.have)
        CFG.localHash = CFG.haveHash
        CFG.use(CFG.have)
    end
end

function NET.restoreLocalRules()
    NET.barLoad()
    NET.boLoad()
    NET.dmLoad()
    NET.flagLoad()
    NET.abLoad()
    NET.resLoad()
    NET.accBanLoad()
    if WBAN and WBAN.load then WBAN.load() end
    if CFG and CFG.pick then CFG.pick() end
end

function NET.rulesSnapshot()
    NET.rulesClear()              -- 先清：多人对局里 allBlock / resOf 等会读快照，不清就拿到上一场的
    MATCH.dmPct = NET.dmgPct()
    MATCH.ab = NET.allBlock()
    MATCH.flags = NET.flagsNow()
    MATCH.res = NET.resNow()
end

function NET.rulesClear()
    MATCH.dmPct = nil
    MATCH.ab = nil
    MATCH.flags = nil
    MATCH.res = nil
end

function NET.rulesBegin(p1, phase, why, first, tn)
    if not valid(p1) then p1 = getP1() end
    if not valid(p1) then return end
    tn = tn or now()
    local okZ, errZ = pcall(ZMC.apply, p1, why or (phase == "cd" and "倒计时" or "开打"))     -- §372 斩马刀重击不扣自己血（幂等）
    if not okZ then out("!! §372 斩马刀重击自伤改不了：%s", tostring(errZ)) end
    if phase == "cd" then
        if first == nil then first = (MATCH.round == 1) end
        if first then
            CFG.begin()                    -- §158 这一场用主机的数值表（客机收齐了）还是本地的（1v1 first = 第 1 回合；多人 = 每场开局）
            RFP.begin(tn)                  -- §210 规则都定下了：算这一场的规则指纹、发给对方
            STD.lv, STD.eq.at = {}, -100   -- §148 两场之间可能升过级 / 换过配装：等级缓存每场重读
        end
        STD.capture(p1)                                                 -- §170.5 先记对局前的属性（饰品还没换）
        ACC.apply(p1)                                                   -- §170.1（§170.5 先于标准数值：锁定属性要按换过的饰品算） 饰品等级
        if why then
            DIF.apply(why)
            STD.apply(p1, why)
            NET.resApply(p1, why)
        else
            DIF.apply("第 " .. MATCH.round .. " 回合倒计时")              -- §266 整场否决存档 + 对局难度（一场只改一次）
            STD.apply(p1, "第 " .. MATCH.round .. " 回合倒计时")         -- §144 标准数值（先于 §113：精纯杀气 / 暗源的上限由它定）
            NET.resApply(p1, "第 " .. MATCH.round .. " 回合倒计时")      -- §113
        end
        CDL.snap(p1)                                                    -- §173.7 倒计时里拦掉的大招 / 影武扣的资源按这个写回
        GCD.reset(why or ("第 " .. MATCH.round .. " 回合开局"))                   -- §184 火枪冷却每回合清零
        DCD.reset(why or ("第 " .. MATCH.round .. " 回合开局"))                   -- §200 闪避冷却每回合清零
        if first then NET.attrDiffLog(p1) end             -- §116.2 只读：我和替身的属性差在哪
    elseif phase == "fight" then
        STD.capture(p1)                                                 -- §170.5 先记对局前的属性（饰品还没换）
        ACC.apply(p1)                                                   -- §170.1（§170.5 先于标准数值：锁定属性要按换过的饰品算）
        if why then
            DIF.apply(why)
            STD.apply(p1, why)
            NET.resApply(p1, why)
        else
            DIF.apply("第 " .. MATCH.round .. " 回合开打")                -- §266 客机直接从交手跟进来的（没经过倒计时）
            STD.apply(p1, "第 " .. MATCH.round .. " 回合开打")           -- §144
            NET.resApply(p1, "第 " .. MATCH.round .. " 回合开打")        -- §113 倒计时里的回满效果可能补满了它们，开打再写一次
        end
    end
end

function NET.rulesEnd(p1, why)
    if not valid(p1) then p1 = getP1() end
    local okC, errC = pcall(RT.endCleanse, p1, why or "对局结束")      -- §362 打完清 buff / debuff（妖气侵蚀等），先于饰品 / 标准数值还原
    if not okC then out("!! §362 对局结束清状态失败：%s", tostring(errC)) end
    GCD.reset(why or "对局结束")      -- §184 火枪冷却清零
    DCD.reset(why or "对局结束")      -- §200 闪避冷却清零
    local okZ, errZ = pcall(ZMC.restore, p1, why or "对局结束")     -- §372 斩马刀重击自伤写回原值（单机照旧）
    if not okZ then out("!! §372 斩马刀重击自伤写回失败：%s", tostring(errZ)) end
    if valid(p1) then ACC.restore(p1) end          -- §170.1 饰品换回（§170.5 先于标准数值还原：还原的属性是饰品没换时记的）
    if valid(p1) then STD.restore(p1) end          -- §144 先还原血上限等，再回满
    CFG.finish()             -- §158 数值表换回本地
    if valid(p1) then refill(p1) end
    if valid(p1) then NET.resRestore(p1) end       -- §113 还原对局前的精纯杀气 / 暗源
    DIF.restore(why or "对局结束")      -- §266 难度配置改回；临时改动都还原完了再退否决存档（放最后）
    local okU, errU = pcall(UICH.rebind, p1, why or "对局结束")     -- §372 我的充能对象重新注册：buff 栏 / 血条重新绑上（虚血显示）
    if not okU then out("!! §372 充能重绑失败：%s", tostring(errU)) end
end

function NET.rulesRespawn(p1)
    if not valid(p1) then p1 = getP1() end
    if not valid(p1) then return end
    local r = MATCH.res or NET.resNow()
    if (r.resm or 0) == 1 then
        local want = { UltimateChargeCount = r.ult0, UltimateCharge = 0, SpiritShadow = r.sp0 }
        local parts, prev = {}, {}
        for a, v in pairs(want) do
            local c = attrOf(p1, a)
            if c and math.abs(c - v) > 0.01 then
                if not NET.resWrite(p1, a, v) then prev[a] = c end
                parts[#parts + 1] = string.format("%s %.1f → %d", a, c, v)
            end
        end
        if #parts > 0 then out("复活资源（多人每局重置）：%s", table.concat(parts, "，")) end
        if next(prev) then NET.resUi(p1, prev) end
    end
end

local function enter(p1, s, tn, why)
    if s == "cd" then      -- L3 对局占用锁：被独立玩法占着就不开局，直接回自由活动（把这一场的状态清干净）
        local okT, who = BASEHOOK.take()
        if not okT then
            out("!! 对局被 %s 占着，不开局", tostring(who))
            if s ~= MATCH.state then return enter(p1, "idle", tn, "对局被别的玩法占着") end
            return
        end
    end
    MATCH.state, MATCH.t0 = s, tn
    MATCH.uiSync("对局 " .. s)                                         -- §260 进对局（回自由活动在最后清完 role 再调）
    FMATCH.fire("enter", s, why, p1, tn)     -- F4b：对局事件（规则来源 / 扩展可挂：排位计分、第三方统计……）
    if s ~= "cd" then ARN.unlock(s == "fight" and "开打" or s) end     -- §238 开打先开回输入（下面 RT.fightStart 再清按着的键）
    ARN.mine = false
    ARN.refresh(p1, "对局 " .. s)                                         -- §238 交手收标记、其余按这一场的点标
    syncFaction(true)
    if s == "cd" then
        if HLFX then pcall(HLFX.clearFx, "第 " .. tostring(MATCH.round) .. " 回合") end   -- §246 回合重置：清掉上一回合补出来的火流星特效
        FMATCH.roundReset()     -- F4a：清这一回合的记录；第 1 回合把"准备"用掉（§110.12，实现在 fornet_match.lua）
        NET.streak = {}
        standUp(p1); standUp(puppet())
        -- §364 倒计时开始：两边还在放的招式技能取消（用户 11-16"开打前放偃月刀大招、马上开战，大招第二刀还能放出来，没刷新掉"）
        for _, who in ipairs({ { p1, "自己" }, { puppet(), "替身" } }) do
            local okC, gone = pcall(G.cancelMoves, who[1])
            if okC and gone and #gone > 0 then out("§364 倒计时取消%s还在放的招：%s", who[2], table.concat(gone, ",")) end
        end
        do local okT, msgT = pcall(BLK.tenAttach, puppet())     -- §425.7 让游戏给替身开张力会话（精防 / 普防按游戏结果判要用）
            if msgT then out("§425.7 倒计时给替身接输入：%s", okT and msgT or ("出错 " .. tostring(msgT))) end end
        local pos, yaw = spawnPoint()
        -- v0.26.0 强制归位只对 AI 对手（用户："主要是为了给 AI 在开战前保持一定距离，真人对战不需要"）：
        -- AI 只会跟着你走，不归位就贴着脸开打；真人自己会拉开距离，各自留在原地
        -- §238 用户 11-11："倒计时开始时各自归位"：有检查过的开战点（MATCH.sp）时真人对战也归位
        if (NET.rai or MATCH.sp) and not (NET.rdummy and not TRAINCTX.returns(MATCH.round)) then     -- §456 木桩只在第 1 回合归位
            -- v0.26.2 安全放置（§79）：起点 = 开局时主机站的点（主机自己的出生点就是它，不用缩）
            local a = MATCH.arena
            local anchor = (MATCH.role ~= "host" and a) and { X = a.x, Y = a.y, Z = a.z + 20.0 } or nil
            safePlace(p1, pos, anchor, yaw, "第 " .. MATCH.round .. " 回合归位")
            setYaw(p1, yaw)
            pcall(function() getP1PC():SetControlRotation({ Pitch = -10.0, Yaw = yaw, Roll = 0.0 }) end)
        end
        ARN.lock()                                         -- §238 倒计时里不能操作，开打开回
        refillPotions("第 " .. MATCH.round .. " 回合")     -- 已停用，只留着日志入口
        if MATCH.round == 1 and MATCH.rebuildPuppet and not (NET.rdummy and NET.rtrainReturn == false) then
            local okR, errR = pcall(MATCH.rebuildPuppet, "对局 #" .. MATCH.id .. " 开始")
            if not okR then out("!! 重建替身 -> %s", tostring(errR)) end
        end
        if not lockSelf(p1) then
            out("!! 锁血失败，为了不真死，对局中止")
            MATCH.state = "idle"
        end
        refill(p1)
        if MATCH.round == 1 then MATCH.tl = NET.rdummy and 0 or RT.limit() end   -- §173 回合时限这一场定下（客机按主机的 tl=）；§342 木桩不限时
        RT.cdStart(p1)                                              -- §173 倒计时无敌（挂不上 → 替身倒计时里当友方）
        pcall(SHIELD.sweep, p1, "第 " .. MATCH.round .. " 回合倒计时")         -- §302 拙壁盾残留
        pcall(SHIELD.sweep, puppet(), "第 " .. MATCH.round .. " 回合倒计时")
        syncFaction(true)
        NET.rulesBegin(p1, "cd", "第 " .. MATCH.round .. " 回合倒计时", MATCH.round == 1, tn)
        out("== 第 %d 回合 倒计时 %.0f 秒（我 %d : %d 对方）；我是%s，%s ==",
            MATCH.round, CD_SEC, MATCH.me, MATCH.op, MATCH.role == "host" and "主机" or "客机",
            (NET.rai or MATCH.sp) and not (NET.rdummy and not TRAINCTX.returns(MATCH.round)) and string.format("%s，归位到出生点 (%.0f, %.0f) 朝向 %.0f%s", NET.rai and "对手是 AI" or "真人对战",
                pos.X, pos.Y, yaw, MATCH.sp and string.format("（开战点，两人相距 %.0f 米）", MATCH.sp.d * 2 / 100.0) or "")
                or "本回合不强制归位")
        if MATCH.state ~= "idle" then return end
        s = "idle"
    end
    FMATCH.sendResult(s)     -- v0.22.0 主机的回合 / 对局结果另发一份可靠事件（客机结算那几秒丢包时靠它补上；F4a：实现在 fornet_match.lua）
    if s == "fight" then
        if MATCH.tl == nil then MATCH.tl = RT.limit() end              -- §173 客机直接从交手跟进来的（没经过倒计时）
        RT.fightStart(p1)                                               -- §173 撤倒计时无敌、清掉异常状态 / 增益（自己 + 替身）
        -- 规则开打：STD.capture(p1) -> ACC.apply -> DIF.apply -> STD.apply -> NET.resApply
        NET.rulesBegin(p1, "fight", "第 " .. MATCH.round .. " 回合开打", false, tn)
        refill(p1)                                                      -- §173 清完状态回满（血 / 杀气）
        RT.begin(p1)                                                    -- §173 受伤从这里开始算
        PCB.on(p1, "第 " .. MATCH.round .. " 回合开打")                -- §261 交手中自己是战斗状态（风雷剑等增益要它）
        out("== 第 %d 回合 开打 ==", MATCH.round)
        if TAGD then pcall(TAGD.schedule, tn) end      -- §249 状态对比：第 1 回合开打后 3 秒（只排一次）
    elseif s == "rend" then
        if TRAINING and NET.rdummy then TRAINING.roundEnd(tostring(MATCH.id) .. ":" .. tostring(MATCH.round), tn) end
        PCB.off(p1, "第 " .. tostring(MATCH.round) .. " 回合结束")      -- §261
        if HLFX then pcall(HLFX.clearFx, "第 " .. tostring(MATCH.round) .. " 回合结束") end   -- §246 回合结束也清
        out("== 第 %d 回合结束：%s（我 %d : %d 对方）==", MATCH.round,
            MATCH.win == "d" and ((RT.info and RT.info.round == MATCH.round) and "时间到、受伤一样，平局不计分" or "同时倒下，平局不计分")
                or (iWon() and "我赢" or "对方赢"), MATCH.me, MATCH.op)      -- §173.9 限时判的平局不是"同时倒下"
    elseif s == "end" then
        if NET.rdummy and NET.rtrainHpRegen == false and TRAINING and TRAINING.allowed() then
            TRAINCTX.restartAt = tn + 1
        end
        PCB.off(p1, "对局结束")                                          -- §261
        if HLFX then pcall(HLFX.clear, "对局结束") end   -- §246 对局结束：补出来的特效全清、探针次数归零
        out("== 对局结束：%s %d : %d ==", MATCH.me > MATCH.op and "胜利" or "失败", MATCH.me, MATCH.op)
    elseif s == "idle" then
        if HLFX then pcall(HLFX.clear, "对局结束") end   -- §246 回自由活动也清（弃权 / 掉线可能没经过 end）
        out("== 对局结束（%s），回到自由活动 ==", why or "-")
        -- v0.17.10：对局外不再锁血（见下面"陪练保护"），对局一结束就解锁，不管还连没连着
        if not LO.IDLE_LOCK or tn - NET.lastRecvAt > 1.0 then unlockSelf(p1, why or "对局结束") end
        RT.unshield(p1)          -- §173 倒计时里结束的（弃权 / 掉线）：无敌撤掉
        PCB.off(p1, why or "回自由活动")      -- §261 交手中断开 / 弃权直接回自由活动的也撤
        MATCH.tl, RT.info, MATCH.sp = nil, nil, nil       -- §238 开战点每场重定
        standUp(p1); standUp(puppet())
        NET.rulesEnd(p1, why or "对局结束")      -- 规则还原：ACC.restore -> STD.restore -> CFG.finish -> refill -> NET.resRestore(p1) -> DIF.restore(why or "对局结束")
        -- 1v1 不清快照（MATCH.res 等对局后照旧留着，ACC 的空闲扫描等会读它；和以前一样）。多人对局结束才清（pbz_multi 的 enter idle）
        FMATCH.idleReset()       -- res / role / hold / dead / lastTx / ready / quitArm 清掉（F4a：实现在 fornet_match.lua）
        MATCH.toast = TOAST_OF[why or ""] and { rows = TOAST_OF[why](), till = tn + TOAST_SEC } or nil
        showHud(nil)
        syncFaction(true)
        ARN.refresh(p1, "回自由活动")       -- §238 这一场的点清掉了，换回存的
        MATCH.uiSync("回自由活动")          -- §260 界面开回
        BASEHOOK.give()                    -- L3 放开对局占用
    end
end

local function startMatchNow()
    local p1 = getP1()
    if not valid(p1) then return end
    local tn = now()
    if HLFX then pcall(HLFX.clear, "新对局") end     -- §246 新对局从干净的计数开始
    if not valid(puppet()) then out("!! 对手还没生成，不能开局"); return end
    if (hpOf(p1) or 0) <= 0 and not MATCH.lock then
        out("!! 你现在是真死状态（血量 0），不能开局：等游戏复活你，或者重启游戏")
        return
    end
    if FMATCH.rulesWaiting() then   -- 定死的规则（排位）还没从服务器拿到，不开局（F1 那里也拦，这里兜底：准备后规则才丢的情况）
        out("!! %s", FMATCH.rulesWaitLog("start"))
        MATCH.ready = false
        MATCH.uiSync("排位规则没到")                     -- §260
        MATCH.toast = { rows = FMATCH.rulesWaitRows(), till = tn + TOAST_SEC }
        return
    end
    if not WBAN.gate(tn) then wireUpdate(); return end     -- §180 自己 / 对方装着禁用武器、影之武装 → 不开局
    local loc = try("arena loc", function() return p1:K2_GetActorLocation() end)
    local rot = try("arena rot", function() return p1:K2_GetActorRotation() end)
    if not (loc and rot) then return end
    MATCH.role, MATCH.round, MATCH.me, MATCH.op = "host", 1, 0, 0
    MATCH.toWin = NET.toWin()     -- v0.26.3 局数开局时定下，对局中改设置不影响这一局
    NET.rulesSnapshot()           -- §291 伤害倍率、可格挡、开关、开局资源等开局时定下
    MATCH.id = (MATCH.id or 0) + 1
    do local lk = FMATCH.lockedBy(); if lk and lk.rules() and lk.startLog then out("%s", lk.startLog(false)) end end     -- 定死规则（排位）：用的是哪份
    if MATCH.dmPct ~= 100 then out("伤害倍率 %d%%（这一局）", MATCH.dmPct) end
    out("红蓝光反击：%s；武器平衡：%s；血瓶：%s；开局精纯杀气 %d（获取 %d%%）、暗源 %d、%s（这一局）", MATCH.flags.ctr and "开" or "关",
        MATCH.flags.bal and "开" or "关", MATCH.flags.med and "开" or "关", MATCH.res.ult0, MATCH.res.ultx, MATCH.res.sp0, NET.resText("resm", MATCH.res.resm)[1])
    local saved, myMap = fileReadKV(ARENA_FILE), mapName(p1)
    local cx, cy, cz, cyaw = saved and tonumber(saved.x), saved and tonumber(saved.y), saved and tonumber(saved.z),
        saved and tonumber(saved.yaw)
    if cx and cy and cz and cyaw and saved.map == myMap then
        -- 存的是场地中心；setArena 要的是"主机出生点"（中心往回 SPAWN_D）
        local r = math.rad(cyaw)
        setArena(cx - math.cos(r) * SPAWN_D, cy - math.sin(r) * SPAWN_D, cz, cyaw)
        out("== 发起对局 #%d（先赢 %d 回合），用 F2 存的场地：中心 (%.0f, %.0f) ==", MATCH.id, MATCH.toWin, cx, cy)
        MATCH.sp = ARN.decode(saved.sp)       -- §238 F2 时检查过的开战点；旧的 arena.txt 没有就现查
        if not MATCH.sp then
            local why
            MATCH.sp, why = ARN.check(p1, cx, cy, cz, cyaw)
            if not MATCH.sp then out("!! 开战点：存的场地放不下两个点（%s），这一场真人对战不强制归位", tostring(why and why[1])) end
        end
    else
        setArena(loc.X, loc.Y, loc.Z, rot.Yaw)
        out("== 发起对局 #%d（先赢 %d 回合）：%s，场地中心在你正前方 %.0f ==", MATCH.id, MATCH.toWin,
            saved and ("存的场地在别的地图 " .. tostring(saved.map)) or "没有用 F2 存过场地", SPAWN_D)
        local why
        MATCH.sp, why = ARN.check(p1, MATCH.center.X, MATCH.center.Y, loc.Z, rot.Yaw)     -- §238 现查
        if not MATCH.sp then out("!! 开战点：你面前放不下两个点（%s），这一场真人对战不强制归位", tostring(why and why[1])) end
    end
    if MATCH.sp then out("开战点：两人各离中心 %.0f 米（蓝 = 主机，橙 = 客机）", MATCH.sp.d / 100.0) end
    textActor(p1)
    enter(p1, "cd", tn)
    wireUpdate()
end

-- §180 禁用武器 / 影之武装的开局关卡（WBAN 段在房间设置那里）。屏幕提示 = 一条橙字 + 一行灰字
function WBAN.toast(msg, tn)
    MATCH.toast = { rows = { { c = T(msg[1], msg[2]), col = COL_ORANGE, size = 1.3 },
                             { c = T("房间设置禁用了这些武器 / 影之武装", "BANNED BY THE ROOM RULES (PANEL -> ROOM SETTINGS)"), col = COL_GRAY } },
                    till = tn + TOAST_SEC }
end
-- 主机开局前（F1 准备、startMatchNow——两边都准备好的自动开局也走它）：先查自己，再复核对方状态包的 wpn= / edg=（以主机为准，
-- 不只靠对方自己查）。不通过 → 主机取消准备、屏幕提示，经可靠事件 wban 告诉客机（客机取消准备并提示）。返回 true = 可以开
function WBAN.gate(tn)
    local msg, k, h = WBAN.selfCheck()
    local code = "host"
    if not msg then
        msg, code, k, h = WBAN.peerCheck(NET.rnm)
    end
    if not msg then return true end
    out("!! 不能开局：%s", msg[1])
    MATCH.ready = false
    MATCH.uiSync("禁用武器不开局")                     -- §260
    WBAN.toast(msg, tn)
    -- 给客机：wban <原因> <名单键> <中文名>|<英文名>（原因 host = 主机自己装着、hit = 你装着、none = 主机收不到你的配装）
    if code ~= "old" and (MATCH.session and MATCH.session.role) ~= "client" and tn - NET.lastRecvAt <= 1.0 then
        REL.send("wban", string.format("%s %s %s|%s", code, k or "-", h and h[1] or "-", h and h[2] or "-"))
    end
    return false
end

-- §291 多人对局开局前复核：主机自己 + 所有参战者
function WBAN.gateMulti(parts, getSide, getName, skipSelf)
    -- §307 skipSelf：对决里房主只当观众时不查房主自己（他不上场），只查传进来的选手
    local msg, k, h
    if not skipSelf then msg, k, h = WBAN.selfCheck() end
    if msg then
        out("!! 不能开局：%s", msg[1])
        return false, msg[1]
    end
    for pid in pairs(parts or {}) do
        local myId = (BASEHOOK.mp and BASEHOOK.mp.myPid and BASEHOOK.mp.myPid()) or 1
        if pid ~= myId then
            local s = getSide and getSide(pid)
            local peerName = (getName and getName(pid)) or (s and s.nick) or (pid .. " 号")
            local wpnList = s and s.wpn and WBAN.parse(s.wpn)
            local edgList = s and s.edg and WBAN.parse(s.edg)
            local lists = { wpnban = wpnList, edgeban = edgList }
            for _, kind in ipairs(WBAN.KINDS) do
                local ban = WBAN.of(kind)
                if ban ~= "-" then
                    local kn = WBAN.KIND_NAME[kind]
                    local l = lists[kind]
                    if l == nil then
                        local m = string.format("%s 版本太旧、没上报%s（房间禁用了%s，不能开局）", peerName, kn[1], kn[1])
                        out("!! 不能开局：%s", m)
                        return false, m
                    end
                    if l == false then
                        local m = string.format("%s 读不到装着的%s（房间禁用了%s，不能开局）", peerName, kn[1], kn[1])
                        out("!! 不能开局：%s", m)
                        return false, m
                    end
                    local hit = WBAN.hitsOf(kind, l, ban)
                    if hit then
                        local m = string.format("%s 装着禁用%s %s，换掉再开局", peerName, kn[1], hit[1])
                        out("!! 不能开局：%s", m)
                        return false, m
                    end
                end
            end
        end
    end
    return true
end

-- ============================================================ §210 规则指纹（用户 11-10："之前 30.2 没拿到 30.3 服务器配置……这种能做保底方案么"
-- → 选了"规则指纹 + 表版本号"）。11-09 服务器排位规则加了 std=1 / acc=1，0.30.2 不认就跳过，和 0.30.3 对打时两边按不同数值打、谁也看不出来。
-- 新字段旧版不认 = 悄悄跳过，这是根子；这里不靠"记得改最低版本"，而是比"两边这一场实际用上的规则"：
--   每场第 1 回合倒计时（MATCH.* 和数值表都定下以后）把局数 / 伤害 / 可格挡 / 时限 / 各开关 / 开局资源 / 饰品 / 禁用名单 /
--   这一场用的数值表哈希拼成一串（RFP.text），算个短指纹。状态包发 rfp=<局号>:<指纹>，可靠事件 rfpx 发整串一次（对不上时说清哪项不一样）。
--   对方指纹不一样 → 横幅写哪几项不一样；对方 RFP.WAIT 秒还没发指纹（旧版本）→ 横幅写"对方版本旧"。普通房间只提示不拦（v0.25.0 用户定）。
--   武林盟主：联机程序把我的指纹报给服务器（RFP），服务器自己比两边的——指纹在开局那一刻就报了，打输了再改也没用；
--   对不上 → 这一场不计分（服务器配置 rfp=check：两边都报了才比；rfp=require：没报的（旧版）也不计分；rfp=off：不管）。
-- 以后新加"影响数值的房间规则 / 排位规则"，要把它加进 RFP.text（或放进 MATCH.flags / MATCH.res，那两张表整张都进），不然新旧版本对打又看不出来
RFP = FMATCH.RFP     -- F4a（docs/FORNET_SPLIT.md）：§210 规则指纹的实现在 fornet_match.lua（NAME 表在装模块时给；横幅颜色由 FMATCH.COL.RED）
REL.on.rfpx = function(rest) RFP.onText(rest) end        -- §210 对方这一场的规则整串（对不上时说清哪项）

REL.on.wban = function(rest)       -- §180 客机：主机复核没通过（结果以主机为准）
    local code, k, zh, en = rest:match("^(%S+)%s+(%S+)%s+(.-)|(.*)$")
    local kn = WBAN.KIND_NAME[k or ""] or WBAN.KIND_NAME.wpnban
    local msg
    if code == "hit" then
        msg = { "你装着禁用" .. kn[1] .. " " .. zh .. "，换掉再准备", "YOU HAVE A BANNED " .. kn[2] .. " EQUIPPED (" .. en .. ") - SWAP IT OUT, THEN GET READY" }
    elseif code == "host" then
        msg = { "主机装着禁用" .. kn[1] .. " " .. zh .. "，等主机换掉", "THE HOST HAS A BANNED " .. kn[2] .. " (" .. en .. ")" }
    else
        msg = { "主机收不到你装着的" .. kn[1] .. "（读不到配装），不能开局", "THE HOST CAN'T SEE YOUR " .. kn[2] .. "S - CAN'T START" }
    end
    out("!! 主机拒绝开局：%s", msg[1])
    MATCH.ready = false
    MATCH.uiSync("主机拒绝开局")                     -- §260
    WBAN.toast(msg, now())
    wireUpdate()
end

-- v0.13.1：联机会话（旁车 / 联机窗口写 net/session.txt：role=host|client，connected=0|1，peer=…）。
-- 没有这个文件（幽灵测试）时按主机处理
local SESSION_FILE = NET_DIR .. "/session.txt"
local sessionRole = FMATCH.sessionRole     -- F4a：实现在 fornet_match.lua（MATCH.session 的 matchhost / role）

-- ============================================================ §238 开战点（用户 11-11）
-- "选场地的时候同时选中两个点位作为双方的开战点，地图上用游戏里的特效标记，确定点位没卡墙里；倒计时开始时各自归位、不能操作，
--  正式开始时返还控制权"。
--   ① F2 存场地 / 主机开局时（没存过场地或者旧存档没点位）：沿场地朝向在中心两侧各找一个点（先 5 米，放不下缩到 4 米、3 米，两边同距），
--      每个点要：下面有地、和中心地面高低差 ≤ HDIFF、从中心到点（膝盖 / 胸口两条线）中间没有墙、点四周 胶囊半径 + 15 以内没有墙；
--      从高处往下打到的第一个面就是落脚面，所以头顶有遮挡也会被认成"高低差太大"。都过了才存，没过就不存、屏幕上写哪一边为什么不行。
--   ② 标记：主机点蓝色光柱、客机点橙色光柱（游戏场景特效 NS_Blue/OrangeLightBeam_301）。不在交手阶段、并且 连着对手 或者 刚按过 F2 时显示；
--      客机显示主机发来的点（状态包 asp=，主机和客机在同一张图时）。用户 11-11："尽量不要做定时检查，用事件通知"——
--      不轮询，只在这些事件里 ARN.refresh：F2 存场地、对局状态变化（enter）、对手替身生成 / 收起（= 连上 / 断开 / 换图后重新生成）、
--      主机发来的 asp= 变了。特效要是循环的（不循环放完就没了，不会自己补，实测时确认）。
--   ③ 倒计时：有点位时真人对战也归位（以前只对 AI，v0.26.0），走原来的 safePlace（引擎传送查卡墙 + 防掉虚空）；
--      倒计时里关输入（G.gameInputBlock，§228 硬直同一个调用，键盘 / 鼠标 / 手柄都不进游戏），开打 / 离开倒计时开回。
--   对方是旧版：它不发 asp=、不锁，只有自己这边归位 / 锁。
-- 全局表（主代码块的 local 已满）
ARN = { STEPS = { 500.0, 400.0, 300.0 }, HDIFF = 150.0, FX_SCALE = 1.0,
        FX = { host = "/Game/PBZContent/VFX/SceneFX/Common/NS_BlueLightBeam_301.NS_BlueLightBeam_301",
               cli = "/Game/PBZContent/VFX/SceneFX/Common/NS_OrangeLightBeam_301.NS_OrangeLightBeam_301" },
        fx = {}, fxKey = nil, fxN = 0, saved = nil, conn = false, mine = false, locked = false, failN = 0, unlockPending = false }

-- 点位 ↔ 字符串（状态包 asp= / arena.txt 的 sp=）：主机 x:y:z:地面z，客机 x:y:z:地面z，间距，朝向
function ARN.encode(sp)
    if not sp then return "" end
    local h, c = sp.host, sp.cli
    if not (h and c) then return "" end
    local function n(v) return tonumber(v) or 0.0 end      -- 11-17：缺字段不再整段报错（F2 存场地被拦）
    return string.format("%.1f:%.1f:%.1f:%.1f:%.1f:%.1f:%.1f:%.1f:%.0f:%.1f", n(h.X), n(h.Y), n(h.Z or h.fz), n(h.fz or h.Z),
        n(c.X), n(c.Y), n(c.Z or c.fz), n(c.fz or c.Z), n(sp.d), n(sp.yaw))
end
function ARN.decode(s)
    if type(s) ~= "string" or s == "" then return nil end
    local v = {}
    for x in s:gmatch("[^:]+") do v[#v + 1] = tonumber(x) end
    if #v ~= 10 then return nil end
    for i = 1, 10 do if not v[i] then return nil end end
    return { host = { X = v[1], Y = v[2], Z = v[3], fz = v[4] }, cli = { X = v[5], Y = v[6], Z = v[7], fz = v[8] }, d = v[9], yaw = v[10] }
end

-- 在中心 (cx, cy, cz)（cz = 角色胶囊中心高度）、朝向 yaw 两侧找开战点。返回 点位表 / nil, 原因（{zh, en}；射线用不了时 why.noTrace = true）
function ARN.check(p1, cx, cy, cz, yaw)
    if not valid(p1) then return nil, { "没有玩家角色", "NO PLAYER" } end
    local half, rad = G.capsuleSize(p1)
    local ign = {}
    local pup = puppet()
    if valid(pup) then ign[1] = pup end
    local errSeen
    local function ray(a, b)
        local h, err = G.traceHit(p1, a, b, ign)
        if err and not errSeen then errSeen = err end
        if h then return h end
        if err and err:find("OutHit", 1, true) then return { X = b.X, Y = b.Y, Z = b.Z, noLoc = true } end
        return nil
    end
    local h0 = ray({ X = cx, Y = cy, Z = cz }, { X = cx, Y = cy, Z = cz - half - 300.0 })
    if not h0 then
        if errSeen then return nil, { noTrace = true, "射线用不了：" .. tostring(errSeen), "TRACE UNAVAILABLE" } end
        return nil, { "你脚下没有地", "NO GROUND UNDER YOU" }
    end
    local z0 = h0.noLoc and (cz - half) or h0.Z
    local r = math.rad(yaw)
    local fx, fy = math.cos(r), math.sin(r)
    local last
    for _, d in ipairs(ARN.STEPS) do
        local pts, bad = {}, nil
        for _, sd in ipairs({ { k = "host", s = -1, zh = "主机（蓝）", en = "HOST (BLUE)" }, { k = "cli", s = 1, zh = "客机（橙）", en = "GUEST (ORANGE)" } }) do
            local dx, dy = fx * sd.s, fy * sd.s
            local px, py = cx + dx * d, cy + dy * d
            local f = ray({ X = px, Y = py, Z = z0 + half * 2 + 100.0 }, { X = px, Y = py, Z = z0 - 300.0 })
            local why
            if not f then
                why = { "下面没有地（悬崖 / 水面 / 虚空）", "NO GROUND" }
            else
                local fz = f.noLoc and z0 or f.Z
                if math.abs(fz - z0) > ARN.HDIFF then
                    why = { string.format("高低差 %.1f 米（台阶 / 坡太陡，或头顶有遮挡）", math.abs(fz - z0) / 100.0), "HEIGHT DIFFERENCE TOO BIG" }
                else
                    for _, up in ipairs({ 60.0, half * 1.5 }) do
                        if not why and ray({ X = cx, Y = cy, Z = z0 + up }, { X = px + dx * rad, Y = py + dy * rad, Z = fz + up }) then
                            why = { "和场地中心之间有墙 / 障碍", "BLOCKED FROM THE CENTER" }
                        end
                    end
                    if not why then
                        for _, a in ipairs({ 0, 90, 180, 270 }) do
                            local ra = math.rad(yaw + a)
                            local L = rad + 15.0
                            if not why and ray({ X = px, Y = py, Z = fz + half }, { X = px + math.cos(ra) * L, Y = py + math.sin(ra) * L, Z = fz + half }) then
                                why = { "离墙太近（会卡进去）", "TOO CLOSE TO A WALL" }
                            end
                        end
                    end
                    pts[sd.k] = { X = px, Y = py, Z = fz + half + 5.0, fz = fz }
                end
            end
            if why then bad = { sd.zh .. "：" .. why[1], sd.en .. ": " .. why[2] }; break end
        end
        if not bad then return { host = pts.host, cli = pts.cli, d = d, yaw = yaw } end
        last = bad
    end
    return nil, last
end

-- 这张图存过的点位（arena.txt 的 sp=；读一次缓存，F2 存时刷新）
function ARN.fromSaved(p1)
    if ARN.saved == nil then ARN.saved = fileReadKV(ARENA_FILE) or false end
    local s = ARN.saved
    if not (s and s.sp and valid(p1) and s.map == mapName(p1)) then return nil end
    return ARN.decode(s.sp)
end

-- 现在要标记哪两点（nil = 不标）。conn = 对手替身在（ARN.onOpponent），mine = 刚按过 F2（到下一次对局状态变化）
function ARN.want(p1)
    if MATCH.state == "fight" then return nil end
    -- 11-17 排查补齐：新版对决叫号 / 倒计时标两位选手的开战点（BASEHOOK.mp.duelMarkers）；房间里别的时候照旧只有刚按 F2 时标存的点
    local sm = BASEHOOK.mp
    if sm and sm.inMp and sm.inMp() then
        local m = sm.duelMarkers and sm.duelMarkers(mapName(p1))
        if m then return m end
        if ARN.mine then return ARN.fromSaved(p1) end
        return nil
    end
    if MATCH.role then return MATCH.sp end
    if ARN.conn and sessionRole() == "client" and not ARN.mine then
        if NET.rasp and NET.rmap == mapName(p1) then return ARN.decode(NET.rasp) end
        return nil
    end
    if ARN.conn or ARN.mine then return ARN.fromSaved(p1) end
    return nil
end

function ARN.fxClear()
    for _, e in pairs(ARN.fx) do if e and valid(e.c) then G.destroyComps({ e.c }) end end
    ARN.fx = {}
end

-- 事件里调（不轮询）：按现在的状态放 / 收标记；对局外主机顺带把存的点位放进状态包
function ARN.refresh(p1, why)
    p1 = p1 or getP1()
    if not valid(p1) then return end
    if ARN.unlockPending then ARN.unlockPending = false; ARN.unlock("换世界后") end
    if (sessionRole() ~= "client" or NET.actHost()) and not MATCH.role then MATCH.wire.asp = ARN.encode(ARN.fromSaved(p1)) end     -- 对局外主机也发，客机好标出来（§276 代主机也发）
    local sp = ARN.want(p1)
    local key = sp and ARN.encode(sp) or nil
    local intact = true
    for _, k in ipairs({ "host", "cli" }) do if not (ARN.fx[k] and valid(ARN.fx[k].c)) then intact = false end end
    if key == ARN.fxKey and (key == nil or intact) then return end
    local had = ARN.fxKey ~= nil
    ARN.fxClear()
    ARN.fxKey = key
    if not sp then
        if had then out("开战点标记收起（%s）", why) end
        return
    end
    local res = {}
    for _, k in ipairs({ "host", "cli" }) do
        local p = sp[k]
        local c, err = G.spawnFxAt(p1, ARN.FX[k], { X = p.X, Y = p.Y, Z = p.fz }, ARN.FX_SCALE)
        ARN.fx[k] = { c = c }
        res[#res + 1] = string.format("%s (%.0f, %.0f, %.0f) %s", k == "host" and "主机蓝" or "客机橙", p.X, p.Y, p.fz, c and "已放" or ("!! " .. tostring(err)))
    end
    ARN.fxN = ARN.fxN + 1
    if ARN.fxN <= 20 or ARN.fxN % 50 == 0 then out("开战点标记（%s）：%s（第 %d 次）", why, table.concat(res, "；"), ARN.fxN) end
end

-- 对手替身生成 / 收起（MATCH.autoCreate / autoRemove 包一层调这里）
function ARN.onOpponent(on, why)
    ARN.conn = on and true or false
    ARN.refresh(nil, why or (on and "对手来了" or "对手走了"))
end

-- 倒计时关输入 / 开回（§228 同一套：面板 / 输入框开着时本来就不进游戏，不另外关）
function ARN.lock()
    if ARN.locked then return end
    if STG.uiBusy and STG.uiBusy() then out("倒计时锁操作：面板 / 输入框开着，输入本来就不进游戏，不另外关"); return end
    local ok, err = G.gameInputBlock(true)
    ARN.locked = ok and true or false
    out("倒计时锁操作：%s", ok and ("已关输入（开打时开回）；" .. tostring(G.inputFlushMsg and G.inputFlushMsg() or "-")) or ("!! 关输入失败：" .. tostring(err)))     -- §276 关的时候也清按着的键
end
function ARN.unlock(why)
    if not ARN.locked then return end
    local ok, err
    if STG.restoreInput then ok, err = pcall(STG.restoreInput) else ok, err = G.gameInputBlock(false) end
    if not ok then
        ARN.failN = ARN.failN + 1
        if ARN.failN <= 3 then out("!! 倒计时锁操作开回失败（%s）：%s，下一帧再试", why, tostring(err)) end
        return
    end
    ARN.locked, ARN.failN = false, 0
    out("倒计时锁操作结束（%s）：输入已开回；%s", why, tostring(G.inputFlushMsg and G.inputFlushMsg() or "-"))     -- §276 清按着的键
end
-- 换世界（M4.forgetWorld，不碰游戏对象）：特效跟着旧世界没了，丢引用；锁着的输入记下，下一个事件（替身重新生成 / 状态变化）开回
function ARN.forget()
    ARN.fx, ARN.fxKey = {}, nil
    if ARN.locked then ARN.unlockPending = true end
end

-- v0.24.1 客机去主机所在的地图（HANDOVER §69）。只有客机切图，主机不动。
-- 切图走游戏敲钟传送（G.travelTo：先自动存档再加载），所以要玩家确认：对局外 F1 连按两次，或联机面板里的"前往主机所在地图"。
-- 主机地图不在游戏地图表里（测试图）→ 不传、提示手动去。加载期间玩家 / 替身 / 替身控制器都会失效：
-- onTick 已有"玩家不可用 → 暂停""替身控制器失效 → 清掉"，到了以后 lobbyStep 照常自动生成对手、再把客机放到主机身边。
-- 到达后 MAPGO_GUARD 秒内比主机低 MAPGO_FALL 以上（落点地面还没加载出来、掉出地图）→ 拉回主机身边
local MAPGO = { pending = nil, armAt = nil, guardTill = nil, warned = nil }
local MAPGO_ARM_SEC = 5        -- 第一次按 F1 后多少秒内再按算确认
local MAPGO_TIMEOUT = 120      -- 发起后这么久（os.time 秒）还没到目标地图 = 失败
local MAPGO_GUARD = 20         -- 到达后防掉落检查的秒数
local MAPGO_NEAR = 5000        -- §156 同一张地图、离主机这么近（50 米）就不传送；远了先提示，F1 连按两次确认再传
local MAPGO_FALL = 1500.0      -- 比主机低这么多算掉出地图
local MAPGO_LIFT = 150.0       -- 落点抬高，别卡进地面
MAPGO.TIMEOUT = MAPGO_TIMEOUT  -- 切图冻结（驱动段，M4 外面）用
-- 屏幕上用游戏里的地名（用户 2026-11-05："地图名可以使用游戏里的名字而不是开发文件名么"，"大区域 - 具体区块"两层都要）：
-- "大区域 · 离主机最近的钟（传送点）"，例如"枷笼山 · 圣母娘娘宗祠"。数据在同目录的 pbz_places.lua（tools/gen_places.py 从游戏文件生成）。
-- 所有关卡共用一套世界坐标，按主机位置找最近的钟；超过 MAPGO.BELL_MAX（300 米）就只显示大区域；不在表里的关卡照旧显示关卡名
do
    local okP, P = pcall(require, "pbz_places")
    if not okP then okP, P = pcall(function() return dofile((((FORNET or {}).GAME_DIR or (ROOT .. "/Scripts")) .. "/pbz_places.lua")) end) end
    if not (okP and type(P) == "table") then
        out("!! 地名表 pbz_places.lua 加载失败（%s），只显示关卡名", tostring(P))
        P = {}
    end
    MAPGO.PLACES = { regions = P.regions or {}, bells = P.bells or {} }
end
MAPGO.BELL_MAX = 30000.0
-- 离 pos 最近的钟 { x, y, z, 中文, 英文 }；没有 / 太远 = nil
function MAPGO.bellNear(pos)
    if not (pos and pos.X and pos.Y) then return nil end
    local best, bd = nil, MAPGO.BELL_MAX * MAPGO.BELL_MAX
    for _, b in ipairs(MAPGO.PLACES.bells) do
        local dx, dy, dz = b[1] - pos.X, b[2] - pos.Y, b[3] - (pos.Z or b[3])
        local d = dx * dx + dy * dy + dz * dz
        if d < bd then best, bd = b, d end
    end
    return best
end
function MAPGO.label(level, pos)
    local r = MAPGO.PLACES.regions[string.lower(tostring(level))]
    local s = r and T(r[1], r[2]) or string.upper(tostring(level))
    local b = MAPGO.bellNear(pos)
    return b and (s .. " · " .. T(b[4], b[5])) or s
end
-- 日志用："枷笼山 · 圣母娘娘宗祠（PBZ_DengDingShanDao_WP）"
function MAPGO.logName(level, pos)
    local r = MAPGO.PLACES.regions[string.lower(tostring(level))]
    local b = MAPGO.bellNear(pos)
    if not (r or b) then return tostring(level) end
    return (r and r[1] or tostring(level)) .. (b and (" · " .. b[4]) or "") .. "（" .. tostring(level) .. "）"
end

-- 现在能不能去主机的地图："ok" 或原因（same / host / match / pp / lost / pending / nomap / notstory）。p1 不给 = 玩家1
-- §141 观战者也能"前往主机所在地图"：观战收到的主机包（src=h）不进 NET.recvOne，SP.feed 只填 NET.rmap / pos / yaw 和 NET.specAt
function NET.since()
    return now() - ((sessionRole() == "spec") and (NET.specAt or -100) or NET.lastRecvAt)
end

function MAPGO.check(p1)
    local target = NET.rmap
    if not target or target == "" or target == mapName(p1 or getP1()) then return "same" end
    local role = sessionRole()
    if role ~= "client" and role ~= "spec" then return "host" end
    if MATCH.role then return "match" end
    if PP.on then return "pp" end
    if NET.since() >= 1.0 then return "lost" end
    if MAPGO.pending then return "pending" end
    if not NET.pos then return "nomap" end
    if not G.isStoryMap(target) then return "notstory" end
    return "ok"
end

local MAPGO_WHY = { host = "你是主机，主机不切图（等客机过来）", match = "对局中不能切图", pp = "Phantom Pact 合作联机中",
                    lost = "和主机断开了", pending = "已经在前往了", nomap = "还没收到主机位置",
                    notstory = "主机所在地图不在游戏地图表里（测试图？），请手动前往", same = "已经在同一张地图" }

-- 把客机放到主机右侧 300、面向主机（连上时一次；到达新地图后、掉出地图时再来）。
-- v0.26.2 走 safePlace（§79）：起点 = 主机身上；放不下返回 nil、留在原地
function MAPGO.besideHost(p1)
    local r = math.rad(NET.yaw or 0)
    local want = { X = NET.pos.X + math.cos(r + math.pi / 2) * 300.0, Y = NET.pos.Y + math.sin(r + math.pi / 2) * 300.0,
                   Z = NET.pos.Z + 30.0 }
    local face0 = math.deg(math.atan(NET.pos.Y - want.Y, NET.pos.X - want.X))
    -- §168 右边 3 米下面没地（悬崖边 / 虚空）就试左、后、前、近一点的两侧；safePlace 挑下面有地的
    local alts = {}
    for _, o in ipairs({ { -math.pi / 2, 300.0 }, { math.pi, 300.0 }, { 0.0, 300.0 }, { math.pi / 2, 150.0 }, { -math.pi / 2, 150.0 } }) do
        alts[#alts + 1] = { X = NET.pos.X + math.cos(r + o[1]) * o[2], Y = NET.pos.Y + math.sin(r + o[1]) * o[2], Z = NET.pos.Z + 30.0 }
    end
    -- §99 同一张大地图里跳得远：落点的地形可能还没加载（20:33 内测"往下掉了 1537"）→ safePlace 里悬空等它（§168 挪进 safePlace）
    local pos = safePlace(p1, want, { X = NET.pos.X, Y = NET.pos.Y, Z = NET.pos.Z + 30.0 }, face0, "放到主机身边", alts)
    if not pos then return nil end
    local face = math.deg(math.atan(NET.pos.Y - pos.Y, NET.pos.X - pos.X))
    setYaw(p1, face)
    pcall(function() getP1PC():SetControlRotation({ Pitch = -10.0, Yaw = face, Roll = 0.0 }) end)
    return pos
end

-- 发起切图。confirmed = 面板按钮（已确认）；F1 要连按两次
function MAPGO.go(p1, confirmed)
    local why = MAPGO.check(p1)
    if why ~= "ok" then
        out("!! 不能前往主机所在地图 %s：%s", MAPGO.logName(NET.rmap, NET.pos), MAPGO_WHY[why] or why)
        return false
    end
    local tc = os.time()
    if not confirmed and not (MAPGO.armAt and tc - MAPGO.armAt <= MAPGO_ARM_SEC) then
        MAPGO.armAt = tc
        out("== 前往主机所在地图 %s 会自动存档：%d 秒内再按一次 F1 确认 ==", MAPGO.logName(NET.rmap, NET.pos), MAPGO_ARM_SEC)
        return false
    end
    MAPGO.armAt = nil
    local dirty = MAPGO.dirty()       -- §168.1 切图也会自动存档
    if dirty then
        out("!! 不能前往主机所在地图：游戏会自动存档，%s（会被写进存档）", dirty)
        return false
    end
    local target, pos = NET.rmap, MAPGO.landPos()
    -- 2026-11-05 09:07 实测崩溃：传送后加载中（09:07:34）模组还在动旧世界的对象。先藏替身、丢掉旧引用、冻结所有循环（MAPGO.freeze，驱动段）再传
    MAPGO.freeze(target, mapName(p1))
    local ok, err = G.travelTo(target, pos, NET.yaw, MAPGO_LIFT)
    if not ok then
        ST.travel = nil
        out("!! 前往 %s 失败：%s（解除冻结）", target, tostring(err))
        return false
    end
    MAPGO.pending = { map = target, from = mapName(p1), at = tc }
    MATCH.ready, MATCH.joined = false, nil        -- 到了以后重新放到主机身边、重新准备
    MATCH.uiSync("去主机地图")                     -- §260
    out("== 前往主机所在地图 %s（%.0f, %.0f, %.0f）：游戏会先自动存档再加载 ==", target, pos.X, pos.Y, pos.Z)
    wireUpdate()
    return true
end

-- 11-17 用户"进入房间后的跨地图传送还在么"→"都接上"：新版房间（多人 / 对决）的包不走 NET.recvOne，NET.rmap 是空的，
-- 上面的 MAPGO.go 用不了。这里按房主包里的地图 / 位置 / 朝向直接走游戏传送（同一套冻结、会自动存档；落点房主右侧 1.5 米）。
-- 面板按钮点一下 = 已确认。返回 true / false, 原因
function MAPGO.goToPeer(target, hostPos, hostYaw, same)
    local p1 = getP1()
    if not (valid(p1) and target and target ~= "" and hostPos) then return false, "还没收到房主位置" end
    if target == mapName(p1) and not same then return false, "已经在同一张地图" end      -- same = 11-17 房间同图离得远也走游戏传送
    if ST.travel or (MAPGO.peerAt and os.time() - MAPGO.peerAt < MAPGO_TIMEOUT and MAPGO.peerTo == target) then return false, "已经在前往了" end
    if MATCH.role then return false, "对局中不能切图" end
    if not G.isStoryMap(target) then return false, "房主所在地图不在游戏地图表里，请手动前往" end
    local dirty = MAPGO.dirty()
    if dirty then return false, "游戏会自动存档，" .. dirty end
    local r = math.rad((hostYaw or 0) + 90.0)
    local pos = { X = hostPos.X + math.cos(r) * MAPGO.LAND_SIDE, Y = hostPos.Y + math.sin(r) * MAPGO.LAND_SIDE, Z = hostPos.Z }
    if same then MAPGO.freeze(target, target, pos) else MAPGO.freeze(target, mapName(p1)) end
    local ok, err = G.travelTo(target, pos, hostYaw or 0, MAPGO_LIFT)
    if not ok then
        ST.travel = nil
        out("!! 前往房主所在地图 %s 失败：%s（解除冻结）", target, tostring(err))
        return false, tostring(err)
    end
    MAPGO.peerAt, MAPGO.peerTo = os.time(), target
    out("== 前往房主所在地图 %s（%.0f, %.0f, %.0f）：游戏会先自动存档再加载 ==", MAPGO.logName(target, hostPos), pos.X, pos.Y, pos.Z)
    return true
end

-- §168.5 游戏传送的落点：主机右侧 1.5 米（游戏放好人以后模组不挪，所以在这里就避开和主机叠在一起）
MAPGO.LAND_SIDE = 150.0
function MAPGO.landPos()
    local r = math.rad((NET.yaw or 0) + 90.0)
    return { X = NET.pos.X + math.cos(r) * MAPGO.LAND_SIDE, Y = NET.pos.Y + math.sin(r) * MAPGO.LAND_SIDE, Z = NET.pos.Z }
end

-- lobbyStep 每次（已连上）调：等待到达 / 超时；到达后的防掉落。返回 true = 刚到达
function MAPGO.step(p1, myMap)
    local tc, arrived = os.time(), false
    local pd = MAPGO.pending
    -- §168.2 同地图走游戏传送：地图名一直相同，不能按地图名算到达（11-09 实测：调完游戏传送同一帧就"到了"，
    -- 模组自己先把人挪到主机身边，游戏随后才出加载画面、重建世界）。等解冻（frozenSame 置 done）才算到；
    -- 到了也不再自己改坐标（用户 11-09："只用游戏的传送功能，不要自己改坐标"）：不放到主机身边、不开防掉落拉回
    if pd and pd.same and not pd.done then pd = nil end
    -- §168.5 跨地图也统一：到了不挪、不开防掉落拉回（落点已经在调游戏传送时定在主机侧面，MAPGO.landPos）
    if pd and (pd.same or myMap == pd.map) then
        MAPGO.pending, arrived = nil, true
        MAPGO.gameTp = sessionRole() == "client" or nil      -- 观战者不走"已加入主机"那段
        out(pd.same and "== 同地图传送到了 %s（用时 %d 秒，位置由游戏定，模组不挪）==" or "== 已到达主机所在地图 %s（用时 %d 秒，位置由游戏定，模组不挪）==",
            myMap, tc - pd.at)
    elseif MAPGO.pending and tc - MAPGO.pending.at > MAPGO_TIMEOUT then
        pd = MAPGO.pending
        MAPGO.pending = nil
        out("!! 前往 %s 超过 %d 秒还没到（现在在 %s），放弃；可以再试一次", pd.map, MAPGO_TIMEOUT, myMap)
    end
    if MAPGO.guardTill and tc > MAPGO.guardTill then MAPGO.guardTill = nil end
    if MAPGO.guardTill and MATCH.joined and NET.pos and myMap == NET.rmap and not HOV.has(p1) then
        local loc = try("mapgo loc", function() return p1:K2_GetActorLocation() end)
        if loc and loc.Z < NET.pos.Z - MAPGO_FALL then
            local pos = MAPGO.besideHost(p1)
            if not pos then     -- v0.26.2：身边放不下也不能让人一直掉
                -- §168 主机身边都没地（主机脚下在你这边是空的）：放回自己最近站稳的地方，没有才放到主机站的地方；悬空等地
                local back = GROUND.get(myMap)
                pos = back or { X = NET.pos.X, Y = NET.pos.Y, Z = NET.pos.Z + 30.0 }
                pcall(function() p1:K2_SetActorLocation(pos, false, {}, true) end)
                HOV.hold(p1, pos, "掉出地图拉回", now())
                if back then MAPGO.guardTill = nil end      -- 回到自己的地面了，不再按主机高度拉
            end
            local cm = rawProp(p1, "CharacterMovement")
            if valid(cm) then pcall(function() cm.Velocity = { X = 0.0, Y = 0.0, Z = 0.0 } end) end
            out("!! 掉出地图（Z %.0f，主机 %.0f）：拉回主机身边 (%.0f, %.0f, %.0f)", loc.Z, NET.pos.Z, pos.X, pos.Y, pos.Z)
        end
    end
    return arrived
end

-- §156 同一张地图离主机多远（米）；读不到 = nil
function MAPGO.dist(p1)
    local loc = NET.pos and try("mapgo dist", function() return p1:K2_GetActorLocation() end)
    if not loc then return nil end
    local dx, dy = loc.X - NET.pos.X, loc.Y - NET.pos.Y
    return math.sqrt(dx * dx + dy * dy) / 100.0
end

-- §156 同地图但离得远：传送到主机身边要确认（11-08 双开：两边存档进度不同，主机脚下那块地在客机的世界里是虚空，自动传送直接摔死）。
-- confirmed = 面板按钮；F1 要连按两次。传过去后照样有 MAPGO_GUARD 秒防掉落
function MAPGO.toHost(p1, confirmed)
    if MATCH.role then out("!! 对局中不能传送"); return false end
    local tc = os.time()
    if not confirmed and not (MAPGO.farArmAt and tc - MAPGO.farArmAt <= MAPGO_ARM_SEC) then
        MAPGO.farArmAt = tc
        out("== 传送到主机身边（离主机 %.0f 米%s）：%d 秒内再按一次 F1 确认 ==", MAPGO.dist(p1) or -1,
            MAPGO.loadOff() and "" or "，走游戏的传送：会自动存档、出加载画面", MAPGO_ARM_SEC)
        return false
    end
    MAPGO.farArmAt = nil
    local went, why = MAPGO.viaLoad(p1, tc)
    if went then return true end
    -- §168.4 用户 11-09："不确定那传送就都走游戏传送"：游戏传送用不了就不传（不再退回模组自己挪），只有 net/tp_load_off.txt 开着才照以前直接挪
    if why ~= "off" then
        out("!! 不能传送到主机身边：%s。自己走过去，或者处理好再按", why or "?")
        MATCH.toast = { rows = { { c = T("不能传送", "CAN'T TELEPORT"), col = COL_ORANGE }, { c = why or "?", col = COL_LABEL } }, till = now() + TOAST_SEC }
        return false
    end
    local pos = MAPGO.besideHost(p1)
    MAPGO.far, MAPGO.guardTill = nil, tc + MAPGO_GUARD
    if pos then out("== 传送到主机身边 (%.0f, %.0f) ==", pos.X, pos.Y)
    else out("== 主机身边放不下，留在原地（自己走过去）==") end
    return true
end

-- §168.1 同一张地图离得很远（> LOAD_DIST）：也走游戏敲钟传送（G.travelTo 同一个关卡），让游戏出加载画面、等落点的地形加载完再放人。
-- 用户 11-08："基本都是同地图传送容易这样吧，跨地图会走游戏的 loading"。以前同地图只改坐标，落点那片还没加载就往下掉。
-- 冻结 / 解冻和切图一样（MAPGO.freeze），解冻条件按同地图改（M4.mapgo.frozen）；到了以后照切图那样放到主机身边 + 防掉落。
-- 游戏会先自动存档（确认提示里说了）。net/tp_load_off.txt 存在 = 不用这条，照以前直接挪（出问题时不用重新部署）
MAPGO.LOAD_DIST = MAPGO_NEAR     -- §168.4 以前 200 米（估的、没实测）；现在要传就走游戏传送
MAPGO.LOAD_OFF = NET_DIR .. "/tp_load_off.txt"
function MAPGO.loadOff()
    local f = io.open(MAPGO.LOAD_OFF, "r")
    if f then f:close(); return true end
    return false
end
-- 返回 nil = 能走游戏传送；否则原因（"off" = 开关关了，照以前直接挪）
function MAPGO.loadable(p1)
    if MAPGO.loadOff() then return "off" end
    local d = MAPGO.dist(p1)
    if not (d and d * 100.0 > MAPGO.LOAD_DIST) then return "离主机不到 50 米" end
    if not G.isStoryMap(mapName(p1)) then return "这张图不能用游戏的传送" end
    return nil
end
-- §168.1 游戏传送会先自动存档：模组的临时改动还挂着时不能触发（会被永久写进档）。
-- 用户 11-08："只要没更改存档里有关养成的数据就行"。挂着 = 标准数值的强制配装 / 属性 / 否决存档、开局精纯杀气 / 暗源（还没还原）、
-- 锁血、观战中、游戏自己在强制配装中。返回原因；nil = 干净
function MAPGO.dirty()
    if MATCH.role then return "对局中" end
    if STD.saved or STD.veto then return "标准数值的临时配装 / 属性还没还原" end
    if DIF and (DIF.saved or DIF.veto) then return "对局难度 / 否决存档还没还原" end      -- §266
    if MATCH.resSaved then return "开局精纯杀气 / 暗源还没还原" end
    if MATCH.lock then return "锁血还挂着" end
    local sc = BASEHOOK.otherScene()
    if sc then return BASEHOOK.title(sc) .. "中" end
    if G.forcedActive() == true then return "游戏正在强制配装中" end
    return nil
end
function MAPGO.viaLoad(p1, tc)
    local no = MAPGO.loadable(p1)
    if no then return false, no end
    local dirty = MAPGO.dirty()
    if dirty then return false, "游戏传送会自动存档，" .. dirty end
    local map, pos = mapName(p1), MAPGO.landPos()
    MAPGO.freeze(map, map, pos)
    local ok, err = G.travelTo(map, pos, NET.yaw, MAPGO_LIFT)
    if not ok then
        ST.travel = nil
        return false, "游戏传送失败：" .. tostring(err) .. "（已解除冻结）"
    end
    MAPGO.pending = { map = map, from = map, at = tc, same = true }
    MAPGO.far = nil
    MATCH.ready, MATCH.joined = false, nil        -- 到了以后放到主机身边（MAPGO.guardTill）、重新准备
    MATCH.uiSync("传送到主机身边")                     -- §260
    out("== 传送到主机身边：同地图离得远，走游戏的传送 (%.0f, %.0f, %.0f)，会自动存档、等地形加载 ==", pos.X, pos.Y, pos.Z)
    wireUpdate()
    return true
end

-- §233 开局先走游戏传送（用户 11-11："查一下刚刚开战的传送，好像没走游戏系统传送"→"改，先传送再开局"）。
-- 02:38 本地 AI 对局：按 F1 时离 F2 存的场地 50 米以外，回合归位走 safePlace（G.teleportTo，引擎直接挪坐标）+ HOV 悬空等地，
-- 那片地形没加载，悬空放回 6 次、12 秒才站住，开打后还悬了 9 秒。归位在倒计时里做，这时对局已经开始（MATCH.role 有了、
-- 马上挂锁血 / 标准数值），游戏传送会自动存档，不能在那里调。所以挪到开局之前：双方都准备好、还没开局、模组没有临时改动时，
-- 出生点离得远（> HOV.FAR）就先调游戏传送（G.travelTo，同 MAPGO.viaLoad 的冻结 / 解冻），到了再照常开局。
-- 只管本地 AI（只有 AI 对局才强制归位）；游戏传送用不了（tp_load_off.txt / 不是剧情图 / 有临时改动 / 调用失败）就照以前开局。
-- 同一次准备只传一次：传完还是远（游戏把人放到别处）也照以前开局，不来回传。全局（主代码块的 local 已满）
RTP = { WAIT = 90, STALE = 300 }
-- 主机出生点（和 startMatchNow / setArena / spawnPoint 同一套算法）；没在这张图存过场地 = nil（场地就是你脚下，不用传）
function RTP.target(p1)
    local saved, myMap = fileReadKV(ARENA_FILE), mapName(p1)
    local cx, cy, cz, cyaw = saved and tonumber(saved.x), saved and tonumber(saved.y), saved and tonumber(saved.z),
        saved and tonumber(saved.yaw)
    if not (cx and cy and cz and cyaw and saved.map == myMap) then return nil end
    local sp = ARN.decode(saved.sp)      -- §238 检查过的主机开战点
    if sp then return { X = sp.host.X, Y = sp.host.Y, Z = sp.host.Z }, cyaw end
    local r = math.rad(cyaw)
    return { X = cx - math.cos(r) * SPAWN_D, Y = cy - math.sin(r) * SPAWN_D, Z = cz + 20.0 }, cyaw
end
-- 主机双方都准备好时每次调。"go" = 现在开局；"wait" = 传送中 / 刚到、替身还没回来，先别开局
function RTP.gate(p1)
    local st = RTP.st
    if st and os.time() - st.at > RTP.STALE then st, RTP.st = nil, nil end       -- 传送后取消过准备，很久以后才又准备
    if st then
        if ST.travel then return "wait" end
        if not valid(puppet()) and os.time() - st.at < RTP.WAIT then return "wait" end      -- 冻结时藏了替身，等自动生成
        RTP.st = nil
        local loc = try("rtp dist", function() return p1:K2_GetActorLocation() end)
        local d = loc and math.sqrt((loc.X - st.pos.X) ^ 2 + (loc.Y - st.pos.Y) ^ 2) or nil
        out("== 开局前游戏传送到了（用时 %d 秒，离出生点 %s 米）%s ==", os.time() - st.at, d and string.format("%.0f", d / 100.0) or "?",
            (d and d <= HOV.FAR) and "，开局" or "，还是远，照以前归位开局（不再传）")
        return "go"
    end
    if not NET.rai then return "go" end
    local pos, yaw = RTP.target(p1)
    local loc = pos and try("rtp loc", function() return p1:K2_GetActorLocation() end)
    if not loc then return "go" end
    local d = math.sqrt((loc.X - pos.X) ^ 2 + (loc.Y - pos.Y) ^ 2)
    if d <= HOV.FAR then return "go" end
    local map = mapName(p1)
    local no = (MAPGO.loadOff() and "有 net/tp_load_off.txt") or (not G.isStoryMap(map) and "这张图不能用游戏的传送") or nil
    local dirty = not no and MAPGO.dirty() or nil
    if no or dirty then
        out("开局前离出生点 %.0f 米，但不走游戏传送（%s），照以前归位", d / 100.0, no or ("会自动存档，" .. dirty))
        return "go"
    end
    MAPGO.freeze(map, map, pos)
    local ok, err = G.travelTo(map, pos, yaw, MAPGO_LIFT)
    if not ok then
        ST.travel = nil
        out("!! 开局前游戏传送失败：%s（已解除冻结），照以前归位", tostring(err))
        return "go"
    end
    RTP.st = { at = os.time(), pos = pos }
    out("== 双方都已准备；离出生点 %.0f 米，先走游戏传送到出生点 (%.0f, %.0f, %.0f)，会自动存档、等地形加载，到了再开局 ==",
        d / 100.0, pos.X, pos.Y, pos.Z)
    MATCH.toast = { rows = { { c = T("先传送到场地", "TELEPORTING TO THE ARENA"), col = COL_LABEL },
                             { c = T("到了自动开局", "THE MATCH STARTS ON ARRIVAL"), col = COL_GRAY } }, till = now() + TOAST_SEC }
    return "wait"
end

-- 地图不同时只提示一次（日志）；屏幕提示在 idleRows
function MAPGO.notice(myMap)
    if MAPGO.warned == NET.rmap then return end
    MAPGO.warned = NET.rmap
    local why = MAPGO.check()
    if why == "ok" then
        out("!! 主机在地图 %s，你在 %s：对局外连按两次 F1（或联机面板\"前往主机所在地图\"）过去，会自动存档", MAPGO.logName(NET.rmap, NET.pos), MAPGO.logName(myMap))
    else
        out("!! 主机在地图 %s，你在 %s：%s", MAPGO.logName(NET.rmap, NET.pos), MAPGO.logName(myMap), MAPGO_WHY[why] or why)
    end
end

-- 屏幕提示（idleRows 在两边地图不同时用）
function MAPGO.rows(tn)
    local client = sessionRole() == "client" or sessionRole() == "spec"
    local why = MAPGO.check()
    local title = client and T("主机在另一张地图", "HOST IS ON ANOTHER MAP") or T("对方在另一张地图", "OPPONENT IS ON ANOTHER MAP")
    local mapUp = MAPGO.label(NET.rmap, NET.pos)
    local sub
    if why == "pending" or MAPGO.pending then
        return { { c = T("正在前往主机所在地图…", "TRAVELLING TO THE HOST'S MAP..."), col = COL_ORANGE, size = 1.3 },
                 { c = mapUp, col = COL_LABEL } }
    elseif why == "ok" and MAPGO.armAt and os.time() - MAPGO.armAt <= MAPGO_ARM_SEC then
        sub = T("会自动存档：再按一次 F1 确认", "AUTO-SAVES: PRESS F1 AGAIN TO GO")
    elseif why == "ok" then
        sub = string.format(T("按 F1 前往 %s（会自动存档）", "F1: GO TO %s (AUTO-SAVES)"), mapUp)
    elseif why == "notstory" then
        sub = string.format(T("不能自动前往，请手动去 %s", "CAN'T AUTO-TRAVEL: GO TO %s YOURSELF"), mapUp)
    elseif why == "host" then
        sub = T("等对方过来", "WAITING FOR THE OPPONENT")
    else
        sub = string.format(T("请先前往 %s", "GO TO %s FIRST"), mapUp)
    end
    return { { c = title, col = COL_ORANGE, size = 1.3 }, { c = sub, col = COL_LABEL } }
end
-- v0.24.1 切图段结束

-- F4（用户 2026-11-04 定）：开战要两边都确认。对局外 = 准备 / 取消准备；对局中 = 弃权（对方收到后结束对局）
local function matchStart()
    local p1 = getP1()
    if not valid(p1) then out("!! 没有玩家1"); return end
    local tn = now()
    if MATCH.role then
        -- v0.14.1（用户 2026-11-04）：认输要 3 秒内连按两次 F4，防误触。第一次只提示
        if not (MATCH.quitArm and tn - MATCH.quitArm <= QUIT_SEC) then
            MATCH.quitArm = tn
            out("== 再按一次 F1（%d 秒内）认输 ==", QUIT_SEC)
            return
        end
        MATCH.quitArm = nil
        if MATCH.role == "client" then
            MATCH.wire.quit = MATCH.id
            REL.send("quit", tostring(MATCH.id))      -- v0.22.0：弃权一定要送到；状态包里的 quit= 留着兼容旧版主机
            out("== 弃权：通知主机结束对局 #%d ==", MATCH.id)
        end
        enter(p1, "idle", tn, "按 F1 弃权")
        wireUpdate()
        return
    end
    if PP.poll() then
        out("!! Phantom Pact 合作联机中，不能准备：请先在 F5 面板里离开")
        MATCH.ready = false
        MATCH.uiSync("取消准备")                     -- §260
        MATCH.toast = { rows = PP.rows(), till = tn + TOAST_SEC }
        wireUpdate()
        return
    end
    if sessionRole() == "spec" then      -- §141 观战者：F1 只用来前往主机所在地图
        if MAPGO.check(p1) ~= "same" then MAPGO.go(p1) else out("观战中：F1 不用来准备") end
        return
    end
    if tn - NET.lastRecvAt > 1.0 then out("!! 还没连上对手"); return end
    if sessionRole() == "client" and MAPGO.check(p1) ~= "same" then    -- v0.24.1 地图不同：F1 = 前往主机所在地图
        MAPGO.go(p1)
        return
    end
    if sessionRole() == "client" and MAPGO.far and not MATCH.role then     -- §156 同地图但离得远：F1 = 传送到主机身边
        MAPGO.toHost(p1)
        return
    end
    if (hpOf(p1) or 0) <= 0 and not MATCH.lock then
        out("!! 你现在是真死状态（血量 0），不能准备：等游戏复活你，或者重启游戏")
        return
    end
    if not MATCH.ready and sessionRole() ~= "client" and FMATCH.rulesWaiting() then    -- 定死的规则（排位）：主机等服务器的规则到了才能开局
        out("!! %s", FMATCH.rulesWaitLog("ready"))
        MATCH.toast = { rows = FMATCH.rulesWaitRows(), till = tn + TOAST_SEC }
        return
    end
    if not MATCH.ready then          -- §180 要准备了：查禁用武器 / 影之武装。主机连对方一起复核（WBAN.gate），客机先查自己（更早提示，结果以主机为准）
        if sessionRole() == "client" then
            local msg = WBAN.selfCheck()
            if msg then out("!! 不能准备：%s", msg[1]); WBAN.toast(msg, tn); return end
        elseif not WBAN.gate(tn) then
            wireUpdate()
            return
        end
    end
    MATCH.ready = not MATCH.ready
    MATCH.uiSync("F1")                     -- §260
    out("== %s（对方：%s）==", MATCH.ready and "我已准备" or "取消准备", (NET.rrdy or 0) == 1 and "已准备" or "未准备")
    textActor(p1)
    wireUpdate()
end

-- 客机的对局被主机结束时显示什么：收到过这局的 mend（可靠事件）就是正常打完了——看过结算画面就不再弹，
-- 没看到（那几秒丢包 / 卡住）补一个胜负提示；没收到（主机是旧版 / 真的被主机中止）照旧"主机结束了对局"
function REL.endWhy()
    local fin = REL.ended[MATCH.id]
    if not fin then return "主机结束了对局" end
    MATCH.me, MATCH.op = fin.cs, fin.hs
    return MATCH.state == "end" and "打完了" or "对局结果"
end

-- 客机：跟随主机的 mt。返回 false 表示没有要跟随的对局。
-- F4a：框架部分（解析 mt= / 成为客机 / 比分 / 进状态）在 fornet_match.lua；这里只给游戏那边的回调（建一次，不每帧造闭包）
FMATCH.followDeps = {
    becomeClient = function(p1, id)     -- 刚跟进来：记下这局的规则（主机的 / 排位固定的）、日志、文字
        MATCH.toWin = NET.toWin()     -- v0.26.3 主机的局数（bo=），只用来显示
        MATCH.dmPct = NET.dmgPct()    -- §86 主机的伤害倍率（dm=），这一局就用它
        NET.rulesSnapshot()           -- §291 主机的规则快照，这一局就用它
        local lk = FMATCH.lockedBy()
        if lk and lk.rules() and lk.startLog then out("%s", lk.startLog(true)) end     -- 定死规则（排位）：用的是服务器的，不看主机的房间设置
        out("== 对方发起了对局 #%d（先赢 %d 回合），跟随 ==", id, MATCH.toWin)
        local src = (lk and lk.rules() and lk.label) and lk.label[1] or "主机设置"     -- 规则是谁定的
        if MATCH.dmPct ~= 100 then out("伤害倍率 %d%%（%s，这一局）", MATCH.dmPct, src) end
        out("红蓝光反击：%s；武器平衡：%s；血瓶：%s；开局精纯杀气 %d（获取 %d%%）、暗源 %d、%s（%s，这一局）", MATCH.flags.ctr and "开" or "关",
            MATCH.flags.bal and "开" or "关", MATCH.flags.med and "开" or "关", MATCH.res.ult0, MATCH.res.ultx, MATCH.res.sp0, NET.resText("resm", MATCH.res.resm)[1], src)
        textActor(p1)
    end,
    arena = function(ax, ay, az, ayaw) setArena(ax, ay, az, ayaw) end,
    sp = function(rasp) MATCH.sp = ARN.decode(rasp) end,        -- §238 主机发来的开战点（旧版主机没有 = 不强制归位）
    endWhy = function() return REL.endWhy() end,
    enter = function(p1, st, tn, why) enter(p1, st, tn, why) end }
local function followHost(p1, tn)
    return FMATCH.followHost(p1, NET.rmt, NET.rasp, NET.rarena, tn, FMATCH.followDeps)
end

-- v0.22.0 可靠事件的处理（REL.poll 按顺序调，每个只调一次）
REL.on.quit = function(rest)      -- 客机弃权 → 主机结束对局
    local id = tonumber(rest)
    if MATCH.role == "host" and id and id == MATCH.id and MATCH.id > 0 then
        out("== 对方弃权（可靠事件）==")
        enter(getP1(), "idle", now(), "对方弃权")
    end
end
REL.on.rend = function(rest)      -- 主机：第几回合谁赢、比分（客机记日志，结果以 mt= 为准）
    local id, rd, w, hs, cs = rest:match("^(%d+) (%d+) (%S) (%d+) (%d+)$")
    if id then out("  主机回报：对局 #%s 第 %s 回合 %s，比分 主机 %s : %s 客机", id, rd, w == "d" and "平局" or (w == "h" and "主机赢" or "客机赢"), hs, cs) end
end
REL.on.rtime = function(rest)     -- §173 主机：这一回合时间到，两边受到的伤害（客机屏幕上显示）
    local id, rd, h, c = rest:match("^(%d+) (%d+) ([%d%.]+) ([%d%.]+)$")
    if not id or tonumber(id) ~= MATCH.id then return end
    RT.info = { round = tonumber(rd), h = tonumber(h), c = tonumber(c) }
    out("  主机回报：第 %s 回合时间到，受伤 主机 %s / 客机 %s（我这边记的 %.0f）", rd, h, c, RT.taken)
end
REL.on.chat = function(rest) CHAT.recvText(rest) end    -- §112 旧版的自由文本聊天：0.34 起只计数不显示（§250.4）
REL.on.chatq = function(rest) CHAT.recvQ(rest) end      -- §250.4 快捷语：只传编号 q=<id>（CHAT 在联机面板段）
REL.on.chatn = function(rest) if BASEHOOK.ask("base.chat", rest) then return end; if CHAT.recvn then CHAT.recvn(rest) end end     -- mesh 多人房 / 解说房：谁|内容；对决控制先截走，其余只认快捷语
REL.on.cfgreq = function(rest)    -- §158 客机要我的数值表
    local hasRoomRules = NET.roomRules and NET.roomRules() ~= nil
    if hasRoomRules then
        local isHostSpecHost = MATCH.session and MATCH.session.hostspec == "1" and (MATCH.session.role or "host") == "host"
        if not isHostSpecHost then return end
    elseif (MATCH.session and MATCH.session.role) == "client" then
        return
    end
    out("数值表：对方要 %s（我现在是 %s）", tostring(rest), tostring(CFG.localHash))
    CFG.sendAll()
end
REL.on.cfg = function(rest) CFG.onChunk(rest) end     -- §158 主机发来的数值表（一块）
CFG.rel = REL     -- §158 CFG 段在 REL 前面定义，看不到这个 local
REL.on.mend = function(rest)      -- 主机：对局打完了、最终比分
    local id, hs, cs = rest:match("^(%d+) (%d+) (%d+)$")
    id = tonumber(id)
    if not id then return end
    REL.ended[id] = { hs = tonumber(hs), cs = tonumber(cs) }
    REL.ended[id - 20] = nil
    out("  主机回报：对局 #%d 结束，主机 %s : %s 客机", id, hs, cs)
end

-- "已加入主机"那句：传送到达后对手角色重新生成会把 MATCH.joined 清掉、再判一次，5 秒内不重复记
function MAPGO.joinedLog(fmt, ...)
    local now = os.clock()
    if MAPGO.joinLogAt and now - MAPGO.joinLogAt < 5 then return end
    MAPGO.joinLogAt = now
    out(fmt, ...)
end

local function lobbyStep(p1, tn, lost)
    SAFE.step()     -- v0.26.2 放下后掉出地图 → 放回原处（§79）
    GROUND.step(p1, tn)     -- §168 记最近站稳的地方（传送掉虚空时放回）
    BASEHOOK.emit("base.tick", tn)      -- L3：观战 mod 订阅（§141.7 对手不准备超时 → 换下一位）
    HOV.step(tn)    -- §99 悬空等地形加载（客机放到主机身边、替身瞬移到远处）
    if PHEAL.want and lost < 1.0 and not PP.on and not BASEHOOK.otherScene() then PHEAL.step() end    -- §162 替身坏了换一个
    -- §310 换房主接任慢：会话平时每 30 帧读一次（两开时帧率低要 1 秒多）；管道送来的会话里房主 / 角色 / 编号变了就当帧读
    local sesNow = ST.ticks % 30 == 0
    if not sesNow and PIPE and PIPE.on and PIPE.rev and PIPE.rev["session.txt"] ~= MATCH.sesRev then
        MATCH.sesRev = PIPE.rev["session.txt"]
        local b, cur = PIPE.blob["session.txt"] or "", MATCH.session or {}
        local function f(k) return b:match("\n" .. k .. "=([^\r\n]*)") or b:match("^" .. k .. "=([^\r\n]*)") end
        if f("mphost") ~= cur.mphost or f("role") ~= cur.role or f("mpid") ~= cur.mpid or f("mp") ~= cur.mp then sesNow = true end
    end
    if sesNow then
        local kv = fileReadKV(SESSION_FILE)
        local was = MATCH.session and MATCH.session.role
        local wasRelay = MATCH.session and MATCH.session.relay
        MATCH.session = kv
        if kv and kv.role ~= was then
            out("联机会话：%s（对端 %s）", tostring(kv.role), tostring(kv.peer))
        end
        -- L3：观战 mod 订阅——§141.8 主机回来打收起观战、§141 / §141.7 换了会话（上场 / 下场）
        if kv and (kv.role ~= was or (wasRelay == "1" and kv.relay ~= "1")) then BASEHOOK.emit("base.session", was, kv, wasRelay) end
    end
    local fresh = lost < 1.0
    local isHostSpecHost = MATCH.session and MATCH.session.hostspec == "1" and (MATCH.session.role or "host") == "host"
    if isHostSpecHost and MATCH.session and MATCH.session.connected == "1" and (MATCH.state or "idle") == "idle" then
        local nowWall = os.time()
        local curKey = (MATCH.session.peer or "") .. ":" .. (MATCH.session.specs or "") .. ":" .. (MATCH.session.qmsg or "")
        if curKey ~= CFG.lastCasterKey or (nowWall - (CFG.lastCasterSendAt or 0) >= 3 and (CFG.casterSendCount or 0) < 3) then
            if curKey ~= CFG.lastCasterKey then
                CFG.lastCasterKey = curKey
                CFG.casterSendCount = 0
            end
            CFG.lastCasterSendAt = nowWall
            CFG.casterSendCount = (CFG.casterSendCount or 0) + 1
            CFG.sendAll()
        end
    end
    if isHostSpecHost and MATCH.autoPup and valid(puppet()) and not MATCH.role and MATCH.autoRemove then
        MATCH.autoRemove()
        MATCH.autoPup, MATCH.joined = nil, nil
    end
    -- §116.1 对手断开超过 LOST_SEC 秒就忘掉"上一个对手是 AI / 叫什么"：不然下一个连接被当成 AI 房间换人（§85.5 按昵称变没变）。
    -- 2026-11-06 17:11 实测：假对手 17:10 断开，17:11 开本地 AI 对战，弹"AI 对手 加入了你的房间，AI 对战已关闭"。
    -- 真正的 AI 房间换人是联机程序当场交接，断不到 LOST_SEC
    if lost > LOST_SEC and (NET.rai ~= nil or NET.rnm ~= nil) then NET.rai, NET.rnm, NET.rdummy = nil, nil, nil end
    -- 2026-11-05 09:07 实测：主机在另一张地图时也生成了替身（站到 298070 外的主机坐标上，跟着对方动）。对方在别的地图 = 不生成，有就藏起
    local otherMap = NET.rmap ~= nil and NET.rmap ~= "" and NET.rmap ~= mapName(p1)
    -- 连上就自动生成对手；断开 LOST_SEC 秒后藏起（只藏自动生成的；F3 手动造的测试替身不动）
    if fresh and otherMap and MATCH.autoPup and valid(puppet()) and not MATCH.role and MATCH.autoRemove then
        out("== 对方在另一张地图（%s），藏起对手角色 ==", tostring(NET.rmap))
        MATCH.autoRemove()
        MATCH.autoPup, MATCH.joined = nil, nil
    elseif fresh and not isHostSpecHost and not otherMap and not valid(puppet()) and ST.stableTicks > 150 and MATCH.autoCreate and not PP.on then
        out("== 对手已连上，自动生成对手角色 ==")
        PHEAL.reset()       -- §162 新连接：换替身次数重新算
        MATCH.autoCreate()
        MATCH.autoPup = true
        MATCH.joined = nil
    elseif not fresh and lost > LOST_SEC and MATCH.autoPup and valid(puppet()) and not MATCH.role and MATCH.autoRemove then
        out("== 对手断开，藏起对手角色 ==")
        MATCH.autoRemove()
        MATCH.autoPup, MATCH.joined, MATCH.ready = nil, nil, false
        MATCH.uiSync("对手换了")                     -- §260
    elseif PP.on and MATCH.autoPup and valid(puppet()) and not MATCH.role and MATCH.autoRemove then
        -- v0.21.0：Phantom Pact 在联机（它会给对方生成自己的幽灵）→ 藏起我们的替身；它断开后上面的"自动生成"会再造出来
        out("== Phantom Pact 合作联机中，藏起对手角色（它断开后自动恢复）==")
        MATCH.autoRemove()
        MATCH.autoPup, MATCH.joined, MATCH.ready = nil, nil, false
        MATCH.uiSync("对手换了")                     -- §260
    end
    if not fresh then return end
    if PP.on and not MATCH.role then MATCH.ready = false; MATCH.uiSync("Phantom Pact"); return end     -- 不传送、不开局
    -- 客机：连上后瞬移到主机身边（同一张地图时）；地图不同就提示，玩家确认后切图（v0.24.1，MAPGO 段）
    local myMap = mapName(p1)
    if sessionRole() == "client" or sessionRole() == "spec" then MAPGO.step(p1, myMap) end
    -- §141 观战者：主机在别的地图就提示（观战代码这时不摆替身）
    -- §276.12（移植 0.33 分支 §269.17）地图名为空 = 不知道（0.33 11-13 双开：两个测试机器人互打时包里 map= 是空的，下场的人收到
    -- "主机在地图（）… 已经在同一张地图"），同 otherMap
    if sessionRole() == "spec" and NET.rmap and NET.rmap ~= "" and NET.rmap ~= myMap and NET.since() < 1.0 then MAPGO.notice(myMap) end
    if sessionRole() == "client" and not MATCH.joined and NET.pos then
        if NET.rmap and NET.rmap ~= "" and NET.rmap ~= myMap then
            MAPGO.notice(myMap)
        else
            -- §156 不再自动传送：近就不动，远就提示（F1 连按两次 / 面板按钮）
            local d = MAPGO.dist(p1)
            MATCH.joined = true
            if MAPGO.gameTp then        -- §168.2 刚走游戏传送过来：位置由游戏定，不挪
                MAPGO.gameTp = nil
                MAPGO.joinedLog("== 已加入主机：走游戏传送过来，离主机 %s 米，不挪 ==", d and string.format("%.0f", d) or "?")
            elseif MAPGO.guardTill then     -- 刚切图过来（落在主机脚下）：照旧放到主机身边，防掉落继续管
                local pos = MAPGO.besideHost(p1)
                if pos then MAPGO.joinedLog("== 已加入主机：传送到主机身边 (%.0f, %.0f) ==", pos.X, pos.Y)
                else MAPGO.joinedLog("== 已加入主机：主机身边放不下，留在原地（自己走过去）==") end
            elseif d and d <= MAPGO_NEAR / 100.0 then
                MAPGO.joinedLog("== 已加入主机：离主机 %.0f 米，不传送 ==", d)
            else
                MAPGO.far = true
                MAPGO.joinedLog("== 已加入主机：离主机 %s 米，对局外连按两次 F1（或联机面板\"传送到主机身边\"）过去 ==", d and string.format("%.0f", d) or "?")
            end
        end
    end
    -- §156 自己走近了就不再提示（不是客机了也清掉）
    if MAPGO.far and sessionRole() ~= "client" then MAPGO.far = nil end
    if MAPGO.far and sessionRole() == "client" then
        local d = MAPGO.dist(p1)
        if d and d <= MAPGO_NEAR / 100.0 then MAPGO.far = nil; out("== 已走到主机附近（%.0f 米），不用传送了 ==", d) end
    elseif sessionRole() == "client" and MATCH.joined and not MATCH.role and not MAPGO.pending and NET.rmap == myMap then
        -- §168.3 加入以后自己跑远了（11-09 实测：传过去以后又跑到地图另一边，还是显示准备、没有传送提示）：
        -- 以前"离得远"只在刚加入时判一次。离开超过 2 倍 MAPGO_NEAR 就重新提示（留余量，别在边上来回闪）
        local d = MAPGO.dist(p1)
        if d and d > 2 * MAPGO_NEAR / 100.0 then MAPGO.far = true; out("== 离主机 %.0f 米了：对局外连按两次 F1（或联机面板\"传送到主机身边\"）过去 ==", d) end
    end
    -- 主机：双方都准备好就开局
    if not MATCH.role and (sessionRole() ~= "client" or NET.actHost()) and MATCH.ready and (NET.rrdy or 0) == 1 then     -- §276 主机下场时第一位代开
        if RTP.gate(p1) == "go" then        -- §233 对手是 AI、出生点离得远：先走游戏传送，到了再开局
            out("== 双方都已准备，开局 ==")
            startMatchNow()
        end
    end
    -- 主机：客机弃权
    if MATCH.role == "host" and (NET.rquit or 0) == MATCH.id and MATCH.id > 0 then
        out("== 对方弃权 ==")
        enter(p1, "idle", tn, "对方弃权")
    end
end

-- ---- net-ui 游戏内联机面板（docs/NETWORK_UI.md §2.4–2.5）。Home 开 / 关；开着时 PgUp/PgDn 选、End 确定（v0.18.4 起不再用方向键 / 回车，见文件末尾）。
-- F3b（docs/FORNET_SPLIT.md）：net-ui 核心段（联机程序拉起 / lobby.txt / cmd.txt 协议 / 方式名 / 节流读取）搬到 fornet_ui.lua；
-- 这里只装模块、取别名，行为一字不差。CONSENT 是全局、定义在后面，模块经 consent() 在调用时取
local UI = (function()
    local ok, mk = pcall(require, "fornet_ui")
    if ok and FORNET and FORNET.adopt then mk = FORNET.adopt("fornet_ui", mk) end     -- F6：实例登记到宿主（FORNET.mods）
    if not ok then ok, mk = pcall(dofile, ROOT .. "/Scripts/fornet_ui.lua") end
    if not (ok and type(mk) == "function") then error("fornet_ui.lua 加载失败：" .. tostring(mk)) end
    return mk({ out = out, now = now, ROOT = ROOT, NET_DIR = NET_DIR, INST = INST, T = T, fileWrite = fileWrite, fileReadKV = fileReadKV, PIPE = PIPE,
                consent = function() return CONSENT end,
                LOBBY_EXE = "PBZLobby.exe",     -- §360：4net 默认叫 FornetLobby.exe；影之刃零的退路 exe 一直是这个名字
                -- F3b-2 输入框 / GUI 要的（都在上面定义过；COL_* / HUD 在屏幕文字段，G 适配层，MAPGO 切图，STG 精防硬直，FRIEND 好友）
                G = G, HUD = HUD, HUD_Y = HUD_Y, umgColor = umgColor, umgRoot = umgRoot, MAPGO = MAPGO, STG = STG, FRIEND = FRIEND, ST = ST, full = full, status = PROBE.status,
                valid = valid, getP1PC = getP1PC,     -- 11-13 冒烟：这两个以前模块里裸用（main.lua 的 local → 游戏里 nil），鼠标面板静默退回文字面板
                COL_GRAY = COL_GRAY, COL_LABEL = COL_LABEL, COL_ORANGE = COL_ORANGE, COL_RED = COL_RED, COL_WHITE = COL_WHITE, COL_GREEN = COL_GREEN,
                LANG = LANG, PREF = FN.PREF, HUD_ROWS = HUD_ROWS })     -- F3b-4 CONSENT 框架要的（PREF 全局在后面才赋值，这里直接给 fornet_core 的那份）；F3b-5 行数
  end)()     -- 缩进：在 M4 闭包里，test_forget_world 用第 0 列的 end)() 找闭包结尾
-- F3b-5：状态行的前置钩子（Phantom Pact 共存盖过一切）和往返毫秒（v0.27.0 模组自己量的，含两边节拍和文件邮箱）由这份适配层给
UI.statusPre[#UI.statusPre + 1] = function() if PP.on then return PP.text(), COL_ORANGE end end
UI.pingMs = function() return LAT.rttMs() end
local NETUI, NETUI_QUICK, NETUI_PER_PAGE, GUI_PER_PAGE = UI.NETUI, UI.NETUI_QUICK, UI.NETUI_PER_PAGE, UI.GUI_PER_PAGE

-- §314（移植 0.33 线 §269.26）界面三态（用户 2026-11-14"加一个 UI 三态切换：1 游戏本身 UI + mod 文字 UI 都不要、2 只保留游戏本体 UI、3 和现在一样"；
-- "mod 的呼出面板不受影响"）。3 = 全显示（默认）；2 = 藏模组的提示文字（准备 / 倒计时 / 比分 / 状态行 / 多人计分板和右侧栏）、聊天、头顶名字 / 血条；
-- 1 = 再藏游戏 HUD（PBZHUDLayout 整个，对手血条在它里面一起藏）。联机面板（Home / P）和面板开着时的聊天照常显示。
-- Insert 循环 3 → 2 → 1 → 3；系统设置里也有一行。存 net/uimode.txt（切换时写一次）。全局（main.lua 最外层 local 快满了；面板 / 观战 / 多人也要读）
-- 1 档：游戏暂停（Esc / 角色菜单）时把 HUD 还回去，免得菜单在 HUD 里面跟着藏了；每 10 次驱动看一次（只在 1 档 / 还藏着时），
-- 换地图后新的 HUD、游戏自己改了可见性也靠它再藏回去
UIM = { FILE = NET_DIR .. "/uimode.txt", mode = 3, gameHidden = false, failLogged = false }
UIM.NAMES = { [1] = { "全部隐藏", "ALL HIDDEN" }, [2] = { "只留游戏界面", "GAME UI ONLY" }, [3] = { "全部显示", "SHOW ALL" } }
function UIM.name() local n = UIM.NAMES[UIM.mode]; return T(n[1], n[2]) end
function UIM.hideMod() return UIM.mode < 3 end
do
    local f = io.open(UIM.FILE, "r")
    if f then
        local v = tonumber((f:read("*l") or ""):match("%d"))
        f:close()
        if v and UIM.NAMES[v] then UIM.mode = v end
    end
end
-- 11-26 游戏菜单真开着（G.menuOpen：UUU 相机 mod 的暂停不算，以前把藏着的 HUD 放回来，客户反馈）
function UIM.menuOpen() local ok, v = pcall(function() return G.menuOpen() end); return ok and v == true end
-- 游戏 HUD 按现在的档位摆（1 档藏，打开游戏菜单时还回去；其余档位显示）
function UIM.applyGame()
    local paused = false
    if UIM.mode == 1 then paused = UIM.menuOpen() end
    local hide = UIM.mode == 1 and not paused
    if not hide and not UIM.gameHidden then return end
    local okC, ok = pcall(function() return G.hudShow(not hide) end)
    ok = okC and ok
    if ok then UIM.gameHidden = hide
    elseif hide and not UIM.failLogged then UIM.failLogged = true; out("!! §314 界面三态：游戏 HUD（PBZHUDLayout）找不到 / 藏不了，只藏模组文字") end
end
function UIM.tick()
    if UIM.mode == 1 or UIM.gameHidden then UIM.applyGame() end
end
function UIM.set(m, why)
    if not UIM.NAMES[m] then return end
    UIM.mode = m
    local f = io.open(UIM.FILE, "w")
    if f then f:write(tostring(m), "\n"); f:close() end
    UIM.applyGame()
    out("§314 界面：%s（%s）", UIM.NAMES[m][1], why or "-")
    NETUI.flash = { text = T("界面：", "HUD: ") .. UIM.name(), till = os.time() + 2 }
end
function UIM.next(why) UIM.set(UIM.mode == 1 and 3 or UIM.mode - 1, why) end
-- 模组文字：1 / 2 档只留面板（panel 非空 = 面板开着，原样给）
function UIM.rows(rows, panel)
    if panel or not UIM.hideMod() then return rows end
    return nil
end
local netModeName, netRouteName, clipText, lobbyAlive = UI.netModeName, UI.netRouteName, UI.clipText, UI.lobbyAlive
local netuiRead, netuiCmd, netuiLaunch, netuiStarting, netuiEnsure, netuiMode = UI.netuiRead, UI.netuiCmd, UI.netuiLaunch, UI.netuiStarting, UI.netuiEnsure, UI.netuiMode
-- M2 段的解说房间规则（NET.roomRules）从这里拿 lobby.txt：照 netuiRead 的节流（面板关着 1 秒读一次），不额外读盘。排位的在 pbz_ranked.lua 自己读
NET.lobby = function() return netuiRead(now()) end
UI.onLobby = function(kv)
    local m = kv and kv.mode
    if m and m ~= "" and m ~= NET.svMode and NET.svDefApply then
        NET.svMode = m
        NET.svDefApply(m == "server")
    end
end

-- ---- v0.18.6 游戏内输入框（用户 2026-11-04："所有操作都可以在游戏内实现"）：输入地址 / 昵称 / 端口不再弹联机窗口。
-- F3b-2（docs/FORNET_SPLIT.md）：输入框整段搬到 fornet_ui.lua（和鼠标面板 GUI 一起）；这里只取别名，行为一字不差
local GUI, editBox, editCommit, editEnd, editStart, editTick, inputMode = UI.GUI, UI.editBox, UI.editCommit, UI.editEnd, UI.editStart, UI.editTick, UI.inputMode
local joinItem, netuiFlash, netuiTargets, perPage, roomOpen, roomPages = UI.joinItem, UI.netuiFlash, UI.netuiTargets, UI.perPage, UI.roomOpen, UI.roomPages

-- ---- §110 武林盟主（排位）：排行榜 / 账号 / 规则说明 / 统计四页、客机复核、积分行、结算提示、规则来源、同意文案 → pbz_ranked.lua（F4b），经 UI.addMode / FMATCH 的钩子接回
RANKED = (function()
    -- 11-13 拆干净（HANDOVER §273）：排位客户端在排位扩展包里（ext\ranked\client.lua，manifest adapter=pbz client=client.lua）。
    -- 包启用才加载；没装 / 停用 = 没有排位。扩展包框架（ST.ext）在文件末尾才装，这里直接看包目录
    local ok, mk
    local d = tostring(ROOT) .. "/ext/ranked"
    -- L3（docs/FORNET_LAYERS.md）：排位是往基础联机包上加的玩法 mod（mods\ranked\），不再是 4net 的插件。
    -- 排位客户端织在面板 / 对局里，这里当场接：mod 机制已经扫过 mods\（需要 base、启用了 = state on），直接载它目录里的 client.lua
    -- 基础联机包作为 mod 运行（FORNET_BASE）时：排位是往上加的 mod，自己的入口载 client.lua；这里只把它要的面板 / 对局表交出去（服务 pvp.rankedCtx）
    BASEX = BASEX or {}
    function BASEX.rankedCtx()
        return { out = out, T = T, NET = NET, MATCH = MATCH, RT = RT, UI = UI, NETUI = NETUI, FMATCH = FMATCH, GUI = GUI,
                 netuiRead = netuiRead, netuiCmd = netuiCmd, netuiFlash = netuiFlash, clipText = clipText, lobbyAlive = lobbyAlive, now = now, VERSION = VERSION,
                 WBAN = WBAN, ACC = ACC, HUD_ROWS = HUD_ROWS,
                 COL = { LABEL = COL_LABEL, ORANGE = COL_ORANGE, RED = COL_RED, GRAY = COL_GRAY, GREEN = COL_GREEN, WHITE = COL_WHITE } }
    end
    if FORNET_BASE then return nil end
    local mf = {}
    local fm = io.open(d .. "/manifest.txt", "r")
    if fm then for line in fm:lines() do local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$"); if k then mf[k] = v end end; fm:close() end
    local onf = io.open(d .. "/on.txt", "r")     -- 11-13：扩展包默认停用，有 on.txt（插件页点过启用）才装；和 fornet_ext.lua / Ext.cs 同一条规则
    local off = not onf
    if onf then onf:close() end
    if fm and mf.adapter == "pbz" and (mf.client or ""):match("^[%w_%-]+%.lua$") and not off then
        ok, mk = pcall(dofile, d .. "/" .. mf.client)
    elseif fm then
        out("排位扩展包%s，没有武林盟主", off and "已停用" or "不是给影之刃零的（manifest 没有 adapter=pbz）"); return nil
    else
        ok, mk = pcall(require, "pbz_ranked")     -- 测试 / 没装扩展包的开发目录（游戏里 games\pbz\ 没有这个文件 = 跳过）
    end
    if not (ok and type(mk) == "function") then out("没有排位扩展包（ext/ranked/client.lua），跳过：%s", tostring(mk)); return nil end
    local okR, r = pcall(mk, BASEX.rankedCtx())
    if not okR then out("!! 排位扩展包 client.lua 初始化失败：%s", tostring(r)); return nil end
    return r
  end)()     -- 缩进：在 M4 闭包里，test_forget_world 用第 0 列的 end)() 找闭包结尾

-- ---- §114 AI 装备页（NETUI.page = "aiload"）和选择页（"aipick"）。设置存在联机程序（netcfg.txt 的 aiw= / aie= / aio= / aimed= / aiacc=），
-- 面板只发 cmd=aiload、按 lobby.txt 回报的值标出当前选的是哪个；AI 自己在 lobby/LocalAi.cs 里按这些值出招 / 发包。
-- AIL 是全局（主代码块 local 满 200 个，同 LAT）。名字来自游戏文本（_tools/catalog），路径来自游戏资源目录（utoc）。
AIL = { HUN = "/PBZCombatAsset/ActorData/Players/Hun/Weapon/", EDGE = "/PBZCombatAsset/ActorData/Players/Hun/ShaqiWeapon/", PER_PAGE = 12 }
-- 武器：{ 招式族（GA_Hun_<族>_*）, 资源（目录/文件）, 中文, 英文 }。族和资源名不一定一样（如 斩马刀 = ZhanMa / ZhanMaBlade/Weapon_Hun_ZhanMaBlade）
AIL.WEAPONS = {
    { "Double", "Double/Weapon_Hun_JueYing", "黑伤双刃（绝影）", "SANGUINE TWIN (JUEYING)" },
    { "Double", "Double/Weapon_Hun_Double", "黑伤双刃", "SANGUINE TWIN" },
    { "Tang", "Tang/Weapon_Hun_Tang", "黑伤", "SANGUINE" },
    { "HeiMoShang", "HeiMoShang/Weapon_Hun_HeiMoShang", "黑魔伤", "INFERNAL ROUGE" },
    { "Long", "Long/Weapon_Hun_Long", "长形黑伤", "SANGUINE REACH" },
    { "ChiRen", "Long/Weapon_Hun_ChiRen", "炽刃", "BLAZING EDGE" },
    { "Iron", "Iron/Weapon_Hun_Iron", "残钢刃", "JAGGED STEEL" },
    { "GuiTouBlade", "GuiTouBlade/Weapon_Hun_GuiTouBlade", "红妆鬼斩", "SCARLET WRAITHBLADE" },
    { "ChiZheCanJian", "ChiZheCanJian/Weapon_Hun_ChiZheCanJian", "痴者残剑", "THE FANATIC'S BROKEN BLADE" },
    { "ZhanMa", "ZhanMaBlade/Weapon_Hun_ZhanMaBlade", "亡命斩马刀", "OUTLAW WARBLADE" },
    { "SnakeDual", "SnakeDual/Weapon_Hun_SnakeDual", "白蟒赤练", "WHITE SERPENT & CRIMSON VIPER" },
    { "BronzeSword", "BronzeSword/Weapon_Hun_TianXuanQingTongJian", "天玄青铜剑", "TIANXUAN BRONZE SWORD" },
    { "DualHook", "DualHook/Weapon_Hun_DualHook", "别离残钩", "PARTING HOOKS" },
    { "ShuangYue", "ShuangYue/Weapon_Hun_ShuangYue", "天煞双钺", "SUNDERING DUAL AXES" },
    { "PoJun", "PoJun/Weapon_Hun_PoJun", "破军", "ARMYBREAKER" },
    { "SlitheringSword", "SlitheringSword/Weapon_Hun_SlitheringSword", "灵蛇软剑", "SOFT SNAKE SWORD" },
    { "FengLeiJian", "BaiShanFengLeiJian/Weapon_Hun_BaiShanFengLeiJian", "白山风雷剑", "BAISHAN STORMSWORDS" },
    { "Horizontal", "Horizontal/Weapon_Hun_Horizontal", "荡寇凶刃", "JUGGERNAUT" },
    { "Jade", "JadeDualChakram/Weapon_Hun_JadeDual", "玉双环", "SEAMLESS DEATH" },
    { "YuuBlade", "YuuBlade/Weapon_Hun_YuuBlade", "妖锯", "FIEND SAWS" },
    { "Jigsaw", "JigSaw/Weapon_Hun_Jigsaw", "断肢锯", "BONESAW" },
    { "YanYueDao", "YanYueDao/Weapon_Hun_YanYueDao", "偃月刀", "CRESCENT BLADE" },
    { "Chaos", "ChaosBlade/Weapon_Hun_CiGuHunDunJian", "刺骨混沌", "FREEZING CHAOS" },
    { "BaiYing", "BaiYing/Weapon_Hun_BaiYing", "白影", "WHITESHADOW" },
    { "XieShan", "XieShan/Weapon_Hun_XieShan", "圣母邪扇", "THE LADY'S FAN" },
    { "ZiMingJian", "ZiMingJian/Weapon_Hun_ZiMingJian", "紫冥剑", "AUREATE" },
    { "LuanYing", "LuanYing/Weapon_Hun_LuanYing_Evolution", "乱莺剑", "WILD ORIOLE SWORD" },
}
-- 影之武装：{ 资源（目录/文件）, 中文, 英文 }（目录名 = 技能所在的 ShachiAbility/<目录>，AI 按它列招）
AIL.EDGES = {
    { "BrutalAxe/Weapon_BrutalAxe", "巨凶斧", "DREAD AXE" }, { "UnnamedBow/Weapon_UnnamedBow", "羽弓", "FEATHER BOW" },
    { "ShachiHook/Weapon_ShachiHook", "追命锁镰", "HUNTER'S CHAIN SICKLE" }, { "MiaoShouFeiDao/Weapon_MiaoShouFeiDao", "妙手飞刀", "FLYING DAGGER" },
    { "TieKuangQuanTao/Weapon_TieKuangQuanTao", "铁拳套", "IRON GAUNTLETS" }, { "ZhuoBiDun/Weapon_ZhuoBiDun", "拙壁盾", "BASTION" },
    { "KuYeSiZhuChuan/Weapon_KuYeSiZhuChuan", "苦叶寺珠串", "KUYE TEMPLE PRAYER BEADS" }, { "CaoOuSiXian/Weapon_CaoOuSiXian", "操偶铃铛", "PUPPETEER'S BELL" },
    { "Lute/Weapon_Lute", "催心琵琶", "HEARTREND PIPA" }, { "HuoLiuXing/Weapon_HuoLiuXing", "火流星", "BLAZE" },
    { "LionHead/Weapon_LionHead", "烈焰狮头", "FLAMING MANE" }, { "XuKongHuaShan/Weapon_XuKongHuaShan", "虚空华扇", "INANIS' RADIANT FAN" },
    { "JinGua/Weapon_JinGua", "长柄金瓜", "BASHPOLE" }, { "JianKeZhaoJiLing/Weapon_JianKeZhaoJiLing", "剑客召集令", "SWORDSMAN'S SUMMON" },
    { "DuYanBow/Weapon_DuYan_Bow", "独眼弓", "ONE-EYED BOW" }, { "YouLongCha/Weapon_YouLongCha", "游龙叉", "LOONG TRIDENT" },
    { "YouLongHead/Weapon_YouLongHead", "游龙头", "YOU LOONG'S DELUGE" }, { "HuangJinHuoChong/Weapon_HuangJinHuoChong", "黄金火铳", "GOLDBLAZE" },
    { "MoJian/Weapon_Mojian", "墨血无痕", "INK CUT" }, { "TanLang/Weapon_TanLang", "贪狼", "WOLFJAW" },
    { "XueDiZi/Weapon_XueDiZi", "血滴子", "FLYING GUILLOTINE" }, { "ThunderSpear/Weapon_ThunderSpear", "雷霆枪", "THUNDER SPEAR" },
    { "TigerCannon/Weapon_TigerCannon", "虎炮", "TIGER CANNON" }, { "NiTouChe/Weapon_NiTouChe", "泥头车", "WAR WAGON" },
}
-- 皮肤：{ 外观表行名, 中文, 英文 }（§109.1）
AIL.OUTFITS = {
    { "Hun_OutFit_Default", "黑伤（逃亡）", "SANGUINE (FUGITIVE)" }, { "Hun_OutFit_Climax", "黑伤", "SANGUINE" },
    { "Hun_OutFit_MoTian", "传承", "LEGACY" }, { "Hun_OutFit_YaYu", "武林传说", "WULIN LEGEND" },
    { "Hun_OutFit_FengXue", "风雪", "SNOWSTORM" }, { "Hun_OutFit_ZhuiMing", "追命", "ZHUIMING" },
    { "Hun_OutFit_GuYou", "故友", "OLD FRIEND" }, { "Hun_OutFit_JiGuanMoQu", "机械魔躯", "MECHANICAL BODY" },
}
-- 饰品：{ 值, 中文, 英文 }。11-26 AI 木桩 V2（用户"可携带饰品补全"）：正式能拿到的 66 件全列（名字同 ACC.NAME / catalog）。
-- 值：挂技能的（29 件）= 精炼满级那一档的技能类名（以前那 20 件的值没变，旧的 netcfg aiacc= 照认）；
-- 纯加属性的（37 件）= 满级那一档的效果短名 GE_Accessory_<名>_LvN，替身同步时按效果挂上（LO.syncPas）。
-- 注意：替身的攻击侧属性每 2 秒按 att= 重写（AI 照抄你的），所以加攻击那部分会被盖掉；防御 / 抗性 / 血量等照常生效。
-- 喝药类（香薰药盒等）AI 的喝药是联机程序模拟的，挂上了也触发不了；慈母护符（§60 曾让真人替身死不掉）AI 血量由联机程序管
AIL.ACCS = {
    { "GA_Accessory_ActHit_Lv2_C", "影动猎杀仪", "HUNTER'S INSIGHT" },
    { "GA_Accessory_AnimMovement_Lv2_C", "舞扇", "DANCE FAN" },
    { "GE_Accessory_Attack_Lv2", "筋力绑带", "BATTLE WRAPS" },
    { "GA_Accessory_BigHit_Lv2_C", "绝望护符", "TALISMAN OF DESPAIR" },
    { "BP_GA_Accessory_Bleed_Lv2_C", "雪与血", "SNOW AND BLOOD" },
    { "GA_Accessory_BreakAttack_Lv2_C", "追杀令", "TOKEN OF PURSUIT" },
    { "GA_Accessory_BreakDrink_Lv2_C", "静心小葫芦", "CALMING GOURD" },
    { "GE_Accessory_BreakRecover_Lv2", "沉香念珠", "AGARWOOD PRAYER BEADS" },
    { "GA_Accessory_BreakRegen_Lv2_C", "慈母护符", "MOTHER'S TALISMAN" },
    { "GE_Accessory_BreakShield_Lv2", "破盾符", "SHIELDBREAKER TALISMAN" },
    { "GA_Accessory_Chaos_Lv3_C", "混沌狂戒", "CHAOS RING" },
    { "BP_GA_Accessory_Combo_Passive_Lv3_C", "碧血云天", "CRIMSON RESOLVE" },
    { "GE_Accessory_Control_Lv2", "细线球", "FINE THREAD" },
    { "GA_Accessory_Counter_Lv2_C", "反击护腕", "COUNTERSTRIKE BRACERS" },
    { "GE_Accessory_Deflect_Lv2", "神机指环", "SHENJI'S RING" },
    { "GE_Accessory_Double_Lv2", "妙手连环", "QUICK HAND PAIR" },
    { "GA_Accessory_Drink_Lv2_C", "香薰药盒", "MEDICINE CASE" },
    { "GA_Accessory_DrinkCost_Lv2_C", "深宅药罐", "MANOR MEDICINE POT" },
    { "BP_GA_Accessory_Electrified_Passive_C", "月雷华灯", "THUNDERMOON LANTERN" },
    { "GA_Accessory_ElementRegen_Lv3_C", "灭法拂尘丝", "ACOLYTE WHISK" },
    { "GE_Accessory_Elemental_Lv2", "羽扇残羽", "FEATHER FAN PLUME" },
    { "BP_GA_Accessory_EvadePhantom_Passive_Lv2_C", "影魅面具", "WRAITH MASK" },
    { "GA_Accessory_Execution_Lv2_C", "万杀巧锁", "DEATHLOCK" },
    { "GA_Accessory_ExecutionSwitchCool_Lv2_C", "刽子手头巾", "EXECUTIONER'S HEADSCARF" },
    { "GE_Accessory_Frost_Lv2", "灭法冰棱", "ACOLYTE ICICLE" },
    { "GE_Accessory_Health_Lv2", "珍玩妖织", "JEWEL'S KNOT" },
    { "GE_Accessory_HealthResistance_Lv3", "古甲残片", "ANCIENT ARMOR FRAGMENT" },
    { "GE_Accessory_HeavyAttackCost_Lv2", "正气凌然", "LINGRAN'S PENDANT" },
    { "GE_Accessory_HeavyAttackDamage_Lv2", "残破容器", "BROKEN VESSEL" },
    { "GE_Accessory_HeavyAttackShachi_Lv2", "独孤绝印", "SEAL OF DUGU" },
    { "BP_GA_Accessory_Ignite_Passive_C", "瑞狮火球", "AUSPICIOUS LION FIREBALL" },
    { "GE_Accessory_Long_Lv2", "妙手千钧", "QUICK HAND MIGHT" },
    { "GE_Accessory_Loot_Lv2", "聚宝盆", "TREASURE BASIN" },
    { "GE_Accessory_LowHealth_Lv2", "绝地求生令", "DESPERATE STAND" },
    { "GE_Accessory_LowShachi_Lv2", "同心双鱼佩", "TWIN FISH PENDANT" },
    { "GE_Accessory_MagicWeapon_Lv3", "百相傩面", "NUO MASK" },
    { "BP_GA_Accessory_MartialWeapon_FreeShachi_Passive_Lv3_C", "粗糙煌心", "CRUDE RADIANT HEART" },
    { "GE_Accessory_PerfectFrame_Lv3", "浑源经脉仪", "REFLEX DEVICE" },
    { "GA_Accessory_Poison_Lv2_C", "猛毒袋", "VENOM POUCH" },
    { "GE_Accessory_PoisonRegen_Lv2", "活木符", "LIVINGWOOD TALISMAN" },
    { "GE_Accessory_PowerWeapon_Lv3", "力士神像", "GUARDIAN IDOL" },
    { "GA_Accessory_RandomDrink_Lv3_C", "开光玉佩", "BLESSED JADE PENDANT" },
    { "GA_Accessory_Ranged_Lv2_C", "神射之眼", "SHARPSHOOTER'S EYE" },
    { "BP_GA_Accessory_RangedWeapon_Passive_C", "无相神镜", "FORMLESS DIVINE MIRROR" },
    { "GE_Accessory_ResistBleed_Lv2", "凝血符", "CONGEAL TALISMAN" },
    { "GE_Accessory_ResistFire_Lv2", "辟火符", "FLAMEWARD" },
    { "GE_Accessory_ResistIce_Lv2", "防冰符", "FROSTWARD" },
    { "GE_Accessory_ResistNonBreak_Lv2", "坚岩护腕", "BOULDERGUARD" },
    { "GE_Accessory_ResistPoison_Lv2", "食物防腐罐", "PRESERVATION JAR" },
    { "GA_Accessory_ResistRanged_Lv2_C", "避箭护符", "ARROWWARD" },
    { "GE_Accessory_ResistThunder_Lv2", "避雷符", "THUNDERWARD" },
    { "GA_Accessory_Rider_Lv2_C", "斩骑符", "CAVALRYBANE" },
    { "GE_Accessory_Shachi_Lv2", "弦音护符", "RESONANCE TALISMAN" },
    { "GE_Accessory_ShachiAttack_Lv2", "白山密令", "BAISHAN WRIT" },
    { "GE_Accessory_ShachiCool_Lv2", "胭脂盒", "ROUGE BOX" },
    { "GE_Accessory_ShachiRegen_Lv2", "杀气头巾", "SHA-CHI HEADSCARF" },
    { "GA_Accessory_ShachiWeapon_Lv3_C", "暗源方块", "REMNANT SPARK CUBE" },
    { "GE_Accessory_SpiritShadow_Lv3", "暗源小笼", "REMNANT SPARK CAGE" },
    { "GE_Accessory_Stance_Lv3", "机簧护心镜", "BRASS CHEST GUARD" },
    { "GE_Accessory_Stealth_Lv2", "屏息绑带", "SILENT WRAP" },
    { "GE_Accessory_SummonDuration_Lv2", "人偶木心", "A PUPPET'S WOODEN HEART" },
    { "GA_Accessory_SwitchEndure_Passive_C", "神奇刀鞘", "MIRACULOUS SCABBARD" },
    { "GE_Accessory_Tang_Lv2", "妙手在握", "QUICK HAND PENDANT" },
    { "GA_Accessory_TimerEndure_Lv2_C", "百战魔躯", "BATTLEFORGED" },
    { "GA_Accessory_UltimateBreak_Lv2_C", "绝技护符", "ULTIMATE TALISMAN" },
    { "GE_Accessory_UltimateCharge_Lv3", "无名大师的扳指", "NAMELESS THUMB RING" },
}
AIL.ACC_SLOTS, AIL.MAX_MED = 4, 10

function AIL.wPath(w) return AIL.HUN .. w[2] .. "." .. w[2]:match("[^/]+$") end      -- lobby.txt 的 aiw=（族在 aiwf=）
function AIL.eWire(e) return AIL.EDGE .. e[1] .. "." .. e[1]:match("[^/]+$") end
function AIL.accList(lb)       -- 当前自选的饰品（nil = 照抄你的）
    local v = lb.aiacc or "-"
    if v == "-" then return nil end
    local l = {}
    for a in v:gmatch("[^,]+") do l[#l + 1] = a end
    return l
end
-- 按回报的值找名字；找不到（表里没有 / 联机程序是旧版）显示原值
function AIL.nameOf(kind, lb, v)
    if kind == "w" then
        for _, w in ipairs(AIL.WEAPONS) do if AIL.wPath(w) == v then return T(w[3], w[4]) end end
        return v ~= "" and (v:match("([^/.]+)$") or v) or "?"
    end
    local list = kind == "e" and AIL.EDGES or kind == "o" and AIL.OUTFITS or AIL.ACCS
    for _, x in ipairs(list) do
        if (kind == "e" and AIL.eWire(x) or x[1]) == v then return T(x[2], x[3]) end
    end
    return v
end
-- 选择页的选项：{ 值, 显示名 }
function AIL.options(kind)
    local o = {}
    if kind == "w" then
        for _, w in ipairs(AIL.WEAPONS) do o[#o + 1] = { AIL.wPath(w), T(w[3], w[4]) } end
    elseif kind == "e" then
        o[1] = { "", T("照抄你装的", "SAME AS YOURS") }
        for _, e in ipairs(AIL.EDGES) do o[#o + 1] = { AIL.eWire(e), T(e[2], e[3]) } end
    elseif kind == "o" then
        o[1] = { "", T("跟你一样（不换）", "SAME AS YOURS") }
        for _, x in ipairs(AIL.OUTFITS) do o[#o + 1] = { x[1], T(x[2], x[3]) } end
    else
        o[1] = { "", T("（空）", "(EMPTY)") }
        for _, x in ipairs(AIL.ACCS) do o[#o + 1] = { x[1], T(x[2], x[3]) } end
    end
    return o
end
function AIL.current(kind, lb)
    if kind == "w" then return lb.aiw or "" elseif kind == "e" then return lb.aie or "" elseif kind == "o" then return lb.aio or "" end
    local l = AIL.accList(lb) or {}
    return l[tonumber(kind:sub(2)) or 1] or ""
end
function AIL.choose(kind, lb, v)
    if kind == "w" then
        for _, w in ipairs(AIL.WEAPONS) do
            if AIL.wPath(w) == v then netuiCmd("aiload", "w=" .. w[1] .. "|" .. v .. "\n") end     -- cmd.txt 里是 <族>|<路径>
        end
    elseif kind == "e" then netuiCmd("aiload", "e=" .. v .. "\n")
    elseif kind == "o" then netuiCmd("aiload", "o=" .. v .. "\n")
    else
        local l, slot = AIL.accList(lb) or {}, tonumber(kind:sub(2)) or 1
        local out_ = {}
        for i = 1, AIL.ACC_SLOTS do
            local a = (i == slot) and v or (l[i] or "")
            if a ~= "" then
                local dup = false
                for _, b in ipairs(out_) do if b == a then dup = true end end
                if not dup then out_[#out_ + 1] = a end
            end
        end
        netuiCmd("aiload", "acc=" .. table.concat(out_, ",") .. "\n")
    end
end

function NETUI.aiLoadItems(lb, items, toPage)
    local function toPick(kind) return function() NETUI.aiPick, NETUI.aiPickPage = kind, nil; NETUI.page = "aipick"; NETUI.sel = 1 end end
    items[#items + 1] = { label = T("武器：", "WEAPON: ") .. AIL.nameOf("w", lb, lb.aiw or ""), act = toPick("w") }
    items[#items + 1] = { label = T("影之武装：", "PHANTOM EDGE: ") .. ((lb.aie or "") == "" and T("照抄你装的", "SAME AS YOURS") or AIL.nameOf("e", lb, lb.aie)), act = toPick("e") }
    items[#items + 1] = { label = T("皮肤：", "OUTFIT: ") .. ((lb.aio or "") == "" and T("跟你一样（不换）", "SAME AS YOURS") or AIL.nameOf("o", lb, lb.aio)), act = toPick("o") }
    local med = tonumber(lb.aimed) or 0
    items[#items + 1] = { label = T("喝药：", "POTIONS: ") .. (med == 0 and T("不喝", "NONE") or string.format(T("每回合 %d 次", "%d PER ROUND"), med)),
                          act = function() netuiCmd("aiload", "med=" .. ((med + 1) % (AIL.MAX_MED + 1)) .. "\n") end }
    local acc = AIL.accList(lb)
    items[#items + 1] = { label = T("饰品：", "ACCESSORIES: ") .. (acc and T("自选", "CUSTOM") or T("照抄你的", "SAME AS YOURS")),
                          act = function() netuiCmd("aiload", "acc=" .. (acc and "-" or "") .. "\n") end }
    if acc then
        for i = 1, AIL.ACC_SLOTS do
            local a = acc[i]
            items[#items + 1] = { label = string.format(T("  饰品 %d：", "  SLOT %d: "), i) .. (a and AIL.nameOf("a", lb, a) or T("（空）", "(EMPTY)")), act = toPick("a" .. i) }
        end
    end
    items[#items + 1] = { label = T("（改了下招生效；血低于四成喝；房间关了血瓶就不喝）",
                                    "(APPLIES MID-FIGHT; DRINKS UNDER 40% HP; NOT WHEN POTIONS ARE OFF)") }
    items[#items + 1] = { label = T("返回", "BACK"), act = toPage("training") }     -- 11-26 V2：AI 装备从"AI 训练设置"进
end

function NETUI.aiPickItems(lb, items, toPage)
    local kind = NETUI.aiPick or "w"
    local opts, cur = AIL.options(kind), AIL.current(kind, lb)
    local pages = math.max(1, math.ceil(#opts / AIL.PER_PAGE))
    if not NETUI.aiPickPage then         -- 第一次打开：翻到当前选的那一页
        NETUI.aiPickPage = 1
        for i, o in ipairs(opts) do if o[1] == cur then NETUI.aiPickPage = math.ceil(i / AIL.PER_PAGE) end end
    end
    NETUI.aiPickPage = math.min(math.max(NETUI.aiPickPage, 1), pages)
    local from = (NETUI.aiPickPage - 1) * AIL.PER_PAGE
    for i = from + 1, math.min(from + AIL.PER_PAGE, #opts) do
        local o = opts[i]
        items[#items + 1] = { label = (o[1] == cur and "● " or "   ") .. o[2],
                              act = function() AIL.choose(kind, lb, o[1]); NETUI.page = "aiload"; NETUI.sel = 1 end }
    end
    if pages > 1 then
        items[#items + 1] = { label = string.format(T("下一页（%d / %d）", "NEXT PAGE (%d / %d)"), NETUI.aiPickPage, pages),
                              act = function() NETUI.aiPickPage = NETUI.aiPickPage % pages + 1; NETUI.sel = 1 end }
    end
    items[#items + 1] = { label = T("返回", "BACK"), act = toPage("aiload") }
end

-- §171 房间设置的一项（用户 11-09"标准数值 / 武器平衡 / 饰品在最上，其他分类折叠，严格跟随挪到系统设置"）。
-- k = bar / bo / dm / ab / NET.FLAG_KEYS / NET.RES_KEYS 里的键；s.lbl(值) = 显示，s.cli() = 客机看到的（主机定的），
-- s.cfg() = 自己设的，s.click() = 换下一档，s.rk(规则) = 武林盟主服务器定的（noRk = 排位也按主机定）
local function roomSpec(k)
    local function onOff(on) return on and T("开", "ON") or T("关", "OFF") end
    if k == "bar" then      -- v0.25.0 对手血条档位（HANDOVER §73）
        local BARN = { [2] = T("血量 + 杀气", "HEALTH + SHACHI"), [1] = T("只显示血量", "HEALTH ONLY"), [0] = T("不显示", "HIDDEN") }
        return { lbl = function(m) return T("对手血条：", "OPPONENT BAR: ") .. BARN[m] end, noRk = true,
                 cli = NET.barMode, cfg = function() return NET.barCfg end, who = T("对手血条由主机设置", "THE HOST DECIDES THE OPPONENT BAR"),
                 tail = T("（主机设置，客机照此显示）", " (HOST SETS IT FOR BOTH)"),
                 click = function()
                     local m = (NET.barCfg + 2) % 3     -- 2 → 1 → 0 → 2
                     NET.barSet(m)
                     out("联机面板：对手血条设为 %d（%s）", m, BARN[m])
                 end }
    elseif k == "bo" then   -- v0.26.3 局数：3 → 5 → 7 → 9 → 3
        return { lbl = function(n) return string.format(T("局数：%d 局 %d 胜", "MATCH: BEST OF %d"), n, NET.toWin(n)) end,
                 cli = NET.bestOf, cfg = function() return NET.boCfg end, rk = function(r) return r.bo end,
                 who = T("局数由主机设置", "THE HOST DECIDES THE MATCH LENGTH"),
                 click = function()
                     local n = NET.boNext(NET.boCfg)
                     NET.boSet(n)
                     out("联机面板：局数设为 %d 局（先赢 %d 回合）", n, NET.toWin(n))
                 end }
    elseif k == "dm" then   -- §86 伤害倍率：10 → 20 → 30 → 40 → 50 → 75 → 100 → 150 → 200 → 300 → 10
        return { lbl = function(n) return string.format(T("伤害倍率：%d%%", "DAMAGE: %d%%"), n) end,
                 cli = NET.dmgPct, cfg = function() return NET.dmCfg end, rk = function(r) return r.dm end,
                 who = T("伤害倍率由主机设置", "THE HOST DECIDES THE DAMAGE"),
                 click = function()
                     local n = NET.dmNext(NET.dmCfg)
                     NET.dmSet(n)
                     out("联机面板：伤害倍率设为 %d%%", n)
                 end }
    elseif k == "ab" then   -- §87 全部可格挡
        return { lbl = function(on) return T("全部可格挡：", "ALL MOVES BLOCKABLE: ") .. onOff(on) end,
                 cli = NET.allBlock, cfg = function() return NET.abCfg == 1 end, rk = function(r) return r.ab == 1 end,
                 who = T("全部可格挡由主机设置", "THE HOST DECIDES THIS RULE"),
                 click = function()
                     local n = 1 - NET.abCfg
                     NET.abSet(n)
                     out("联机面板：全部可格挡设为%s", n == 1 and "开" or "关")
                 end }
    elseif NET.FLAG_NAME[k] then    -- §105.3 红蓝光反击 / §106.5 武器平衡 / §108 血瓶 / §128.2 严格跟随 / §144 标准数值
        if NET.FLAG_LOCKED[k] then return nil end      -- §144.1 锁住的不显示
        local nm = NET.FLAG_NAME[k]
        return { lbl = function(on) return T(nm[1] .. "：", nm[2] .. ": ") .. onOff(on) end,
                 cli = function() return NET.flag(k) end, cfg = function() return NET.flagCfg[k] == 1 end,
                 rk = function(r) if NET.FLAG_RKFIX[k] then return NET.FLAG_RKFIX[k] == 1 end return r[k] == 1 end,   -- §181 cs 武林盟主固定开
                 who = T(nm[1] .. "由主机设置", "THE HOST DECIDES THIS RULE"),
                 click = function()
                     local n = 1 - NET.flagCfg[k]
                     NET.flagSet(k, n)
                     out("联机面板：%s设为%s", nm[1], n == 1 and "开" or "关")
                 end }
    elseif NET.RES_NAME[k] then     -- §113 开局精纯杀气 / 暗源、§113.2 每场 / 每局、§113.4 获取倍率、§170.1 饰品：点一下下一档
        local nm = NET.RES_NAME[k]
        return { lbl = function(n) local tx = NET.resText(k, n); return T(nm[1] .. "：", nm[2] .. ": ") .. T(tx[1], tx[2]) end,
                 cli = function() return NET.resOf(k) end, cfg = function() return NET.resCfg[k] end,
                 rk = function(r) if r[k] ~= nil then return r[k] end return NET.RES_DEF[k] end,
                 who = T(nm[1] .. "由主机设置", "THE HOST DECIDES THIS RULE"),
                 click = function()
                     local n = NET.resNext(k, NET.resCfg[k])
                     NET.resSet(k, n)
                     out("联机面板：%s设为 %s", nm[1], NET.resText(k, n)[1])
                 end }
    elseif k == "accban" then       -- §176 禁用饰品：点进勾选页（客机 / 武林盟主也能进去看，只是改不了）
        local function banPage() NETUI.page, NETUI.sel = "accban", 1 end
        return { lbl = function(v) return T("禁用饰品：", "BANNED ACCESSORIES: ") .. clipText(T(ACC.banText(v, 1), ACC.banText(v, 2)), 18) .. " >" end,
                 cli = NET.accBanOf, cfg = function() return NET.accBanCfg end, rk = function(r) return (r and r.accban and NET.accBanNorm(r.accban)) or NET.accBanDefNow() end,
                 who = T("禁用饰品由主机设置", "THE HOST DECIDES THIS RULE"), click = banPage, view = banPage }
    elseif WBAN.LIST[k] then        -- §180 禁用武器 / 影之武装：同禁用饰品，点进勾选页
        local kn = WBAN.KIND_NAME[k]
        local function banPage() NETUI.page, NETUI.sel = k, 1 end
        return { lbl = function(v) return T("禁用" .. kn[1] .. "：", "BANNED " .. kn[2] .. "S: ") .. clipText(T(WBAN.text(k, v, 1), WBAN.text(k, v, 2)), 18) .. " >" end,
                 cli = function() return WBAN.of(k) end, cfg = function() return WBAN.cfg[k] end, rk = function(r) return r and r[k] and WBAN.norm(k, r[k]) or WBAN.DEF end,     -- 定死规则（排位）：服务器发了就按它，没发 = 不禁
                 who = T("禁用" .. kn[1] .. "由主机设置", "THE HOST DECIDES THIS RULE"), click = banPage, view = banPage }
    end
end
-- 一行：武林盟主 = 服务器定的（点了只提示）；客机只看主机定的；主机 / 没联机点一下换下一档。没有这项 / 排位规则还没到 = nil
function NETUI.roomItem(k, lb)
    local s = roomSpec(k)
    if not s then return nil end
    local it
    local lk = FMATCH.lockedBy()
    if lk and not s.noRk then     -- §110 定死规则的来源（排位）在生效：按它的值显示、不能改
        local rk = lk.rules()
        if not rk then return nil end
        it = { label = s.lbl(s.rk(rk)),
               act = s.view or function() netuiFlash(T(lk.fixedMsg[1], lk.fixedMsg[2]), COL_ORANGE) end }
    elseif NET.roomRules() and (lb.role == "client" or (MATCH.session and MATCH.session.matchhost == "1")) then
        it = { label = s.lbl(s.cli()) .. T("（解说设置）", " (CASTER)"),
               act = s.view or function() netuiFlash(T("规则由解说（房主）定，不能改", "RULES DECIDED BY CASTER (HOST)"), COL_ORANGE) end }
    elseif lb.role == "client" then
        it = { label = s.lbl(s.cli()) .. T("（主机设置）", " (HOST'S SETTING)"), act = s.view or function() netuiFlash(s.who) end }
    else
        it = { label = s.lbl(s.cfg()) .. (s.tail or T("（主机设置，下一局生效）", " (HOST, NEXT MATCH)")), act = s.click }
    end
    return it
end
-- §171 房间设置页：全部按类折叠（一次只展开一类，展开最多的一类也不超出面板行数）。
-- 11-18 用户"顶部这些（标准数值 / 武器平衡 / 饰品 / 生效饰品数量 / 禁用饰品 / 禁用武器 / 禁用影之武装）
-- 合并成一个叫'对局平衡设置'的分类里"：原来置顶的 7 项收进第一个折叠类
-- npos（严格跟随）11-23 起不在任何页显示（固定开）；没归类的新键自动进"其他"
NETUI.ROOM_TOP = {}
NETUI.ROOM_CATS = {
    -- 11-18 用户"房间设置里的几局几胜 / 对局时间移到旧版 1v1 分类里"：bo / tl 挪去最后一类；
    -- 对决的这两项在"玩法设置"页里改（同一个 NET.boCfg / NET.resCfg.tl，两边都是入口）
    { id = "balance", zh = "对局平衡设置", en = "MATCH BALANCE", keys = { "std", "bal", "acc", "accn", "accban", "wpnban", "edgeban" } },   -- §176 / §180
    { id = "match", zh = "对局", en = "MATCH", keys = { "dm", "bar" } },
    { id = "combat", zh = "战斗规则", en = "COMBAT", keys = { "dif", "ab", "ctr", "med", "dgc", "swk", "sycd", "stg", "stgm", "stgr", "pdsh", "pdshv" } },     -- §216 / §228 / §266 对局难度
    { id = "res", zh = "开局资源", en = "STARTING RESOURCES", keys = { "ult0", "ultx", "sp0", "resm" } },
    { id = "spec", zh = "旧版 1v1", en = "CLASSIC 1V1", spec = true, keys = { "bo", "tl" } },   -- 11-18 局数 / 时限 + 观战排队（旧版 1v1 才显示）
}
NETUI.ROOM_ELSEWHERE = { npos = true }
-- §176 禁用饰品勾选页（NETUI.page = "accban"）：66 件按 STD.ACCESSORIES 顺序，每页 NETUI.ACCBAN_PER 件。
-- 主机 / 没联机点一下勾上 / 去掉（存 rules.txt，下一局生效）；客机看主机的、武林盟主看固定默认名单，点了只提示
NETUI.ACCBAN_PER, NETUI.accBanPage = 10, 1      -- 标题 + 10 件 + 翻页 / 默认 / 返回 = 14 行（文字面板放得下）
function NETUI.accBanItems(lb, items, toPage)
    local lk = FMATCH.lockedBy()
    local ranked, client = lk ~= nil, lb.role == "client"     -- ranked = 定死规则的来源在生效（排位）
    local ro = ranked or client
    local cur = ACC.banSet(ro and NET.accBanOf() or NET.accBanCfg)
    local ids = STD.ACCESSORIES
    local pages = math.ceil(#ids / NETUI.ACCBAN_PER)
    NETUI.accBanPage = math.max(1, math.min(NETUI.accBanPage or 1, pages))
    local n = 0
    for _ in pairs(cur) do n = n + 1 end
    items[#items + 1] = { label = string.format(T("禁用饰品（勾上 = 对局中失效；已禁 %d 件）", "BANNED ACCESSORIES (CHECKED = NO EFFECT IN MATCHES; %d)"), n)
                                  .. (ranked and T(lk.fixedTag[1], lk.fixedTag[2]) or client and T("：主机设置", ": HOST'S SETTING") or T("：下一局生效", ": NEXT MATCH")),
                          col = COL_LABEL }
    local from = (NETUI.accBanPage - 1) * NETUI.ACCBAN_PER
    for i = from + 1, math.min(from + NETUI.ACCBAN_PER, #ids) do
        local id = ids[i]
        local nm = ACC.NAME[id] or { id, id }
        items[#items + 1] = { label = (cur[id] and "[x] " or "[  ] ") .. T(nm[1], nm[2]),
                              act = function()
                                  if ranked then netuiFlash(T(lk.fixedMsg[1], lk.fixedMsg[2]), COL_ORANGE); return end
                                  if client then netuiFlash(T("禁用饰品由主机设置", "THE HOST DECIDES THIS RULE")); return end
                                  local l = {}
                                  for x in pairs(cur) do if x ~= id then l[#l + 1] = x end end
                                  if not cur[id] then l[#l + 1] = id end
                                  NET.accBanSet(table.concat(l, ","))
                                  out("联机面板：禁用饰品设为 %s", ACC.banText(NET.accBanCfg))
                              end }
    end
    items[#items + 1] = { label = string.format(T("下一页（%d / %d）", "NEXT PAGE (%d / %d)"), NETUI.accBanPage, pages),
                          act = function() NETUI.accBanPage = NETUI.accBanPage % pages + 1 end }
    if not ro then
        items[#items + 1] = { label = T("恢复默认（", "DEFAULT (") .. T(ACC.banText(NET.accBanDefNow(), 1), ACC.banText(NET.accBanDefNow(), 2)) .. T("）", ")"),
                              act = function() NET.accBanCfg = NET.accBanDefNow(); NET.rulesUnset("accban"); if NET.flagCfg then NET.flagCfg.accban = nil end; out("联机面板：禁用饰品恢复默认") end }
    end
    items[#items + 1] = { label = T("返回", "BACK"), act = toPage("room") }
end
-- §180 禁用武器 / 影之武装勾选页（NETUI.page = "wpnban" / "edgeban"）：同 §176 禁用饰品那页，按 WBAN.LIST 顺序、每页 NETUI.ACCBAN_PER 件。
-- 默认一件不禁，"恢复默认" = 全去掉。勾上 = 装着它不能准备 / 开局（不换装）
NETUI.wbanPage = {}
function NETUI.wbanItems(kind, lb, items, toPage)
    local lk = FMATCH.lockedBy()
    local ranked, client = lk ~= nil, lb.role == "client"     -- ranked = 定死规则的来源在生效（排位）
    local ro = ranked or client
    local kn = WBAN.KIND_NAME[kind]
    local cur = {}
    for x in (ro and WBAN.of(kind) or WBAN.cfg[kind]):gmatch("[%w_]+") do cur[x] = true end
    local ids = WBAN.IDS[kind]
    local pages = math.ceil(#ids / NETUI.ACCBAN_PER)
    local pg = math.max(1, math.min(NETUI.wbanPage[kind] or 1, pages))
    NETUI.wbanPage[kind] = pg
    local n = 0
    for _ in pairs(cur) do n = n + 1 end
    items[#items + 1] = { label = string.format(T("禁用" .. kn[1] .. "（勾上 = 装着不能开局；已禁 %d 件）", "BANNED " .. kn[2] .. "S (CHECKED = CAN'T START WITH IT; %d)"), n)
                                  .. (ranked and T(lk.fixedTag[1], lk.fixedTag[2]) or client and T("：主机设置", ": HOST'S SETTING") or T("：下一局生效", ": NEXT MATCH")),
                          col = COL_LABEL }
    for i = (pg - 1) * NETUI.ACCBAN_PER + 1, math.min(pg * NETUI.ACCBAN_PER, #ids) do
        local id = ids[i]
        local nm = WBAN.NAME[kind .. ":" .. id] or { id, id }
        items[#items + 1] = { label = (cur[id] and "[x] " or "[  ] ") .. T(nm[1], nm[2]),
                              act = function()
                                  if ranked then netuiFlash(T(lk.fixedMsg[1], lk.fixedMsg[2]), COL_ORANGE); return end
                                  if client then netuiFlash(T("禁用" .. kn[1] .. "由主机设置", "THE HOST DECIDES THIS RULE")); return end
                                  local l = {}
                                  for x in pairs(cur) do if x ~= id then l[#l + 1] = x end end
                                  if not cur[id] then l[#l + 1] = id end
                                  WBAN.set(kind, table.concat(l, ","))
                                  out("联机面板：禁用%s设为 %s", kn[1], WBAN.text(kind, WBAN.cfg[kind], 1))
                              end }
    end
    items[#items + 1] = { label = string.format(T("下一页（%d / %d）", "NEXT PAGE (%d / %d)"), pg, pages),
                          act = function() NETUI.wbanPage[kind] = (NETUI.wbanPage[kind] or 1) % pages + 1 end }
    if not ro then
        items[#items + 1] = { label = T("恢复默认（无）", "DEFAULT (NONE)"),
                              act = function() WBAN.set(kind, WBAN.DEF); out("联机面板：禁用%s恢复默认（无）", kn[1]) end }
    end
    items[#items + 1] = { label = T("返回", "BACK"), act = toPage("room") }
end
-- 11-16 用户"一键改成武林盟主模式的设置，直接加在任何房间设置中"：房间设置页"返回"上面一行，点两下（3 秒内）把本机房间设置整套写成盟主规则。
-- 规则来源：联机程序拿到过的盟主规则（lobby.txt rkrules=，当前是武林盟主方式时才有）优先，没有就用 NET.RK_PRESET
-- §408 NET.RK_PRESET 就是 NET.RK_RULES（base_dif.lua，唯一真源；= 排位服务端 RULES）；串里没写的键按 NET.RK_DEF。
-- 只写本机 rules.txt（和逐项点一样，下一局生效）；客机 / 定死规则生效时不显示
NET.RK_PRESET = NET.RK_RULES
function NET.rkPresetApply(lb)
    local fromSrv = lb and lb.rkrules and lb.rkrules ~= ""
    local src = fromSrv and lb.rkrules or NET.RK_PRESET
    local r = NET.rkParse(src) or NET.rkParse(NET.RK_PRESET)
    if not r then return false end
    if NET.boValid(r.bo) then NET.boSet(r.bo) end
    if NET.dmOk(r.dm) then NET.dmSet(r.dm) end
    if r.ab == 0 or r.ab == 1 then NET.abSet(r.ab) end
    for _, k in ipairs(NET.FLAG_KEYS) do
        if (r[k] == 0 or r[k] == 1) and not NET.FLAG_LOCKED[k] then NET.flagSet(k, r[k]) end
    end
    for _, k in ipairs(NET.RES_KEYS) do
        if r[k] ~= nil and NET.resValid(k, r[k]) then NET.resSet(k, r[k]) end
    end
    NET.accBanSet(r.accban or NET.accBanDefNow())
    WBAN.set("wpnban", r.wpnban or WBAN.DEF)
    WBAN.set("edgeban", r.edgeban or WBAN.DEF)
    out("联机面板：一键套用武林盟主规则（%s）：%s", fromSrv and "服务器给的" or "内置", src)
    return true
end
-- 0.34 最终方案 4：数值表不再自动下发，玩家点一下才向大厅服务器要（先二次确认）；显示本地缓存的哈希 / 时间和上次结果。
-- 11-18 用户"获取最新数值表的功能，移到一键套用盟主规则下面"：从系统设置 → 对局 挪到房间设置页底部（"一键套用武林盟主规则…"和"返回"之间）。
local function cfgFetchItems(lb, items)
    if not (CFG and CFG.SERVER_TABLE) then return end      -- 11-22 这个版本不用服务器下发的数值表：不显示获取按钮
    local ch, cat = (lb.cfgh or "") ~= "" and lb.cfgh or nil, tonumber(lb.cfgat) or 0
    items[#items + 1] = { label = T("服务器数值表：", "SERVER TABLE: ")
                              .. (ch and (ch .. (cat > 0 and ("  " .. os.date("%m-%d %H:%M", cat)) or "")) or T("没有（用模组自带的）", "NONE (BUILT-IN)"))
                              .. T("  → 点击获取", "  → CLICK TO FETCH"),
                          act = function() CONSENT.ask("cfg_fetch", function() netuiCmd("cfgfetch") end) end }
    if (lb.cfgst or "") ~= "" then items[#items + 1] = { label = clipText(lb.cfgst, 44) } end
end
-- 11-18 用户"现在的房间设置里有些选项是旧版 1v1 专用的，重新整理一版分类"：联机省流三种玩法都用，单独"联机"分类。
-- 以前它在 pbz_spec 的"观战 / 排队"里，观战 mod 没装 / 旧版 1v1 之外容易被当成观战专用；现在由 base 自己写。
local function netRows(lb, items)
    local notHost = lb.role == "client" or lb.role == "spec"
    local val = notHost and lb.dzhost or lb.dz
    local state
    if lb.role == "spec" then
        state = (lb.dzact == "1") and T("开（现在收的是省流包）", "ON (RECEIVING SAVED PACKETS)") or T("现在收的是完整包", "RECEIVING FULL PACKETS")
    elseif val == "-1" then
        state = T("未知（主机是旧版，或还没收到主机的包）", "UNKNOWN (OLD HOST OR NOT YET HEARD)")
    else
        state = (val ~= "0" and T("开", "ON") or T("关", "OFF"))
                .. (lb.role and lb.role ~= "" and lb.role ~= "none" and (lb.dzact == "1" and T("（现在：省流中）", " (NOW: ON)") or T("（现在：完整包）", " (NOW: FULL)")) or "")
    end
    local dzOn = val ~= "0"
    items[#items + 1] = { label = T("联机省流：", "SAVE BANDWIDTH: ") .. state
                                  .. (notHost and T("（主机设置）", " (HOST'S SETTING)") or T("（主机设置）", " (HOST)")),
                          act = function()
                              if notHost then netuiFlash(T("联机省流由主机设置", "THE HOST DECIDES THIS")); return end
                              netuiCmd("dz", "on=" .. (dzOn and "0" or "1") .. "\n")
                              out("联机面板：联机省流设为 %s", dzOn and "关" or "开")
                          end }
end
local function roomPageItems(lb, items)
    local lk = FMATCH.lockedBy()
    local ranked = lk ~= nil     -- 定死规则的来源（排位）在生效
    -- 11-18：新版房间 = 玩法设置里另有局数 / 时限（多人房还有命数 / 时限），
    -- 房间设置 → 旧版 1v1 这两项不显示（它们在玩法设置页里改，存的是同一份）
    local function inNewModeRoom()
        local sm = BASEHOOK.mp
        if sm and sm.isDuel and sm.isDuel() then return true end
        if sm and sm.inMp and sm.inMp() then return true end
        local ses = MATCH.session
        return ses ~= nil and (ses.mp == "1" or ses.duel == "1")
    end
    if ranked then
        if lk.headerItems then lk.headerItems(lb, items) end     -- 来源自己写顶上的说明（排位：固定规则 / 最低版本 / 正在获取）
    elseif NET.roomRules() then
        items[#items + 1] = { label = T("规则由解说（房主）定：", "RULES DECIDED BY CASTER (HOST):"), col = COL_LABEL }
    end
    local used = {}
    for k in pairs(NETUI.ROOM_ELSEWHERE) do used[k] = true end
    local cats = {}
    for _, c in ipairs(NETUI.ROOM_CATS) do
        cats[#cats + 1] = c
        for _, k in ipairs(c.keys or {}) do used[k] = true end
    end
    local rest = {}
    for _, k in ipairs(NET.FLAG_KEYS) do if not used[k] then rest[#rest + 1] = k end end
    for _, k in ipairs(NET.RES_KEYS) do if not used[k] then rest[#rest + 1] = k end end
    if #rest > 0 then cats[#cats + 1] = { id = "other", zh = "其他", en = "OTHER", keys = rest } end
    for _, c in ipairs(cats) do
        local sub = {}
        if c.spec then      -- 旧版 1v1：局数 / 时限 + 排队规矩（排位房间只显示固定规则，不显示排队）
            if not inNewModeRoom() then
                for _, k in ipairs(c.keys or {}) do
                    local it = NETUI.roomItem(k, lb)
                    if it then sub[#sub + 1] = it end
                end
            end
            if not ranked then BASEHOOK.emit("base.roomCat.spec", sub, T, lb.role == "client" or lb.role == "spec", netuiFlash, lb, netuiCmd) end     -- L3：观战 mod 订阅
        else
            for _, k in ipairs(c.keys or {}) do
                local it = NETUI.roomItem(k, lb)
                if it then sub[#sub + 1] = it end
            end
        end
        if #sub > 0 then
            local open = NETUI.roomOpen == c.id
            items[#items + 1] = { label = (open and "[-] " or "[+] ") .. T(c.zh, c.en) .. string.format(T("（%d 项）", " (%d)"), #sub),
                                  act = function() NETUI.roomOpen = (NETUI.roomOpen ~= c.id) and c.id or nil; NETUI.roomFocus = c.id end }
            -- 展开 / 收起后光标跟着这一类的标题（上面一类收起时标题会往上挪）
            local focused = NETUI.roomFocus == c.id
            if focused then NETUI.sel, NETUI.roomFocus = #items, nil end
            if open then
                for _, it in ipairs(sub) do
                    it.label = "      " .. it.label
                    items[#items + 1] = it
                end
                if focused then NETUI.roomShowTo = #items end     -- 11-16 鼠标面板滚动：刚展开的这一类尽量整类露出来
            end
        end
    end
    if not ranked and lb.role ~= "client" and not (NET.roomRules() and MATCH.session and MATCH.session.matchhost == "1") then
        local armed = NETUI.rkPresetAt and (now() - NETUI.rkPresetAt) < 3
        items[#items + 1] = { label = armed and T(">> 再点一次：全部改成盟主规则 <<", ">> CLICK AGAIN TO SET EVERYTHING BELOW TO RANKED RULES <<")
                                            or T("一键套用武林盟主规则…", "APPLY RANKED (WULIN MENGZHU) RULES…"),
                              act = function()
                                  if not armed then NETUI.rkPresetAt = now(); return end
                                  NETUI.rkPresetAt = nil
                                  if NET.rkPresetApply(lb) then
                                      netuiFlash(T("已套用武林盟主规则（下一局生效）", "RANKED RULES APPLIED (NEXT MATCH)"))
                                  end
                              end }
    end
    -- 11-18：获取服务器数值表挪到这里（客机 / 排位也显示：本机换表随时可用，不影响主机下发的那份）
    cfgFetchItems(lb, items)
end

-- 面板里可选的行：{ label, act = function() } ；没有 act 的是说明行。NETUI.page = main / rooms / settings（系统设置）/ room（房间设置）/ thanks
-- F3b-5：调度骨架在 fornet_ui.lua（U.netuiItems：没响应提示、page / settingsBtns、按名字找注册页）；这里只剩默认内容：
-- 主页 / 房间列表 / 系统设置 / 房间设置（都是影之刃零这份模组的具体项），由核心在没有注册页接手时调
local function netuiDefaultItems(lb, tn, items, page, mode, settingsBtns)
    -- 11-18 用户"旧版的 2 个选项并入一个子项":旧版 1v1 的开房 / 加入收进这一页
    if NETUI.page == "classic" then
        items[#items + 1] = { label = T("创建旧版房间（1v1）", "HOST A CLASSIC 1V1 ROOM"), act = function() netuiCmd("host") end }
        local prompt, hint
        if NETUI.viaServer(mode) then
            prompt, hint = T("房间号，或 IP:端口 / [IPv6]:端口", "ROOM CODE, OR IP:PORT / [IPV6]:PORT"), "ABC234"
        elseif mode == "bridge" then
            prompt, hint = T("输入主机的" .. NETUI.bridgeSvc() .. " ID", "ENTER THE HOST'S " .. NETUI.bridgeSvc():upper() .. " ID"), ""
        else
            prompt, hint = T("房主地址（IPv6 写 [地址]:端口）", "HOST ADDRESS (IPV6: [ADDR]:PORT)"), "192.168.1.8"
        end
        items[#items + 1] = { label = T("加入旧版房间…", "JOIN A CLASSIC ROOM..."), act = function() editStart("join", prompt, "", hint) end }
        items[#items + 1] = { label = T("返回", "BACK"), act = page("main") }
        return items
    end
    -- 房间设置页（用户 2026-11-06"单独出个页面放房间设置"）：主机 / 没联机时点了换值，客机只看主机定的；都是下一局生效。
    -- §110 武林盟主：规则是服务器定的固定值，只显示、点了不改。§171 入口挪到各页"系统设置…"上面，返回回主页
    if NETUI.page == "room" then
        roomPageItems(lb, items)
        items[#items + 1] = { label = T("返回", "BACK"), act = page("main") }
        return items
    end
    -- 11-15 用户："设置界面也多到返回按钮按不到了，要不要做个分类"：系统设置首页只留昵称 + 分类入口 + 扩展 / 玩法 / 隐私 / 感谢 / 拉黑，
    -- 网络与连接（settings:net）、对局（settings:match）、界面与语言（settings:ui）各一页，返回回系统设置
    if NETUI.page == "settings" then
        items[#items + 1] = { label = T("昵称：", "NAME: ") .. clipText(lb.name or "?", 20),
                              act = function() editStart("name", T("输入新昵称（空着回车 = 不改）", "NEW NAME (EMPTY = KEEP)"), "", lb.name or "") end }
        items[#items + 1] = { label = T("网络与连接…", "NETWORK..."), act = page("settings:net") }
        items[#items + 1] = { label = T("界面与语言…", "DISPLAY & LANGUAGE..."), act = page("settings:ui") }
        if ST.ext then ST.ext.rows("settings", items, lb) end                               -- X1 扩展包加在系统设置的行
        BASEUI.rowsOf("settings", items, lb)                                                -- L3 玩法 mod 加在系统设置的行
        items[#items + 1] = { label = T("已加载的扩展…", "EXTENSIONS..."), act = page("ext") }   -- X1 docs/EXTENSIONS.md §7.3
        if BASEUI.hasMods() then items[#items + 1] = { label = T("已装的玩法…", "GAME MODES..."), act = page("mods") } end   -- L3 docs/FORNET_LAYERS.md 第 3 节
        items[#items + 1] = { label = T("隐私说明…", "PRIVACY..."), act = function() NETUI.privPg = 1; page("privacy")() end }
        items[#items + 1] = { label = T("感谢名单…", "THANKS..."), act = page("thanks") }
        OPP.entry(lb, items, page)      -- §174 拉黑：只放在系统设置、感谢名单下面（用户 11-11"不要放在首页"）
        items[#items + 1] = { label = T("返回", "BACK"), act = page("main") }
        return items
    end
    if NETUI.page == "settings:net" then
        local on = lb.upnpon == "1"
        items[#items + 1] = { label = T("端口：", "PORT: ") .. (lb.cfgport or "?") .. T("（IP 直连用）", " (DIRECT IP)"),
                              act = function() editStart("port", T("新端口 1–65535（回车不改）", "NEW PORT 1-65535 (EMPTY = KEEP)"), "", lb.cfgport or "27015") end }
        items[#items + 1] = { label = T("UPnP 自动转发端口：", "UPNP PORT FORWARDING: ") .. (on and T("开", "ON") or T("关", "OFF")),
                              act = function()
                                  local function upnpGo() netuiCmd("upnp", "on=" .. (on and "0" or "1") .. "\n") end
                                  if on then upnpGo() else CONSENT.ask("upnp", upnpGo) end      -- 0.34：开之前确认（改路由器）
                              end }
        -- 服务器大厅用的服务器地址（域名或 IP[:端口]，默认端口 27020）
        local srv = (lb.srv or "") ~= "" and lb.srv or T("未填", "NOT SET")
        items[#items + 1] = { label = T("大厅服务器：", "LOBBY SERVER: ") .. clipText(srv, 24),
                              act = function() editStart("server", T("大厅服务器 域名或 IP[:端口]（回车不改）", "LOBBY SERVER HOST[:PORT] (EMPTY = KEEP)"), "",
                                                         (lb.srv or "") ~= "" and lb.srv or "1.2.3.4:27020") end }
        -- §102 的"直连不通时用服务器中转"0.34 去掉了（TASK_0.34 最终方案 3：对局不经服务器中转；替代是房间设置"对局走 Steam"）
        -- v0.22.0 联机密码（可选，两边填同一个；空 = 不签名）。面板只显示设没设，密码本身不回传给游戏
        items[#items + 1] = { label = T("联机密码：", "PASSWORD: ") .. (lb.secret == "1" and T("已设置", "SET") or T("未设置", "NONE")),
                              act = function() editStart("secret", T("联机密码，两边一样（回车不改，- 清除）", "PASSWORD, SAME ON BOTH SIDES (EMPTY = KEEP, - = CLEAR)"), "",
                                                         T("对方也要填同一个", "BOTH SIDES USE THE SAME ONE")) end }
        -- §294 多人房隐藏我的 IP（§306 用户 11-14 要求从首页挪到系统设置；只对服务器大厅的多人房有用，局域网里大家本来同一个网）
        local hideip = lb.hideip == "1"
        items[#items + 1] = { label = T("隐藏我的 IP（仅服务器大厅）：", "HIDE MY IP (LOBBY ROOMS): ") .. (hideip and T("开", "ON") or T("关", "OFF")),
                              act = function()
                                  netuiCmd("hideip", "on=" .. (hideip and "0" or "1") .. "\n")
                                  netuiFlash(T("下次开 / 进房间生效", "TAKES EFFECT IN THE NEXT ROOM"))
                              end }
        -- 11-18 用户"对局走桥接 / 联机省流 / 对手位置严格跟随 是不是应该放网络里"：挪到网络与连接页。
        -- 这三项都是"开房时才算数"的联机设置（省流 / 桥接存 netcfg，严格跟随是房间规则 npos），客机跟主机
        items[#items + 1] = { label = T("开房时的联机：", "HOSTING NETWORK:"), col = COL_LABEL }
        netRows(lb, items)
        if NETUI.hasBridge() then
            local m = tonumber(lb.bridgeroom or "1") or 1
            if m < 0 or m > 2 then m = 1 end
            local names = { [0] = { "关闭", "OFF" }, [1] = { "直连优先，不通或明显更慢时走桥接", "DIRECT FIRST, BRIDGE IF IT FAILS OR IS MUCH SLOWER" }, [2] = { "一直桥接", "ALWAYS BRIDGE" } }
            items[#items + 1] = { label = T("对局走桥接：< ", "PLAY OVER BRIDGE: < ") .. T(names[m][1], names[m][2]) .. " >",
                                  act = function()
                                      local nx = (m + 1) % 3
                                      local function go() netuiCmd("bridgeroom", "mode=" .. nx .. "\n") end
                                      if nx == 0 then go() else CONSENT.ask("bridge_match", go) end
                                  end }
            if not lb.role or lb.role == "none" or lb.role == "" then
                items[#items + 1] = { label = T("  客机跟主机；桥接要双方都启用并同意", "  Guests follow the host; the bridge needs both sides"), col = COL_LABEL }
            end
        end
        -- 11-23 对手位置严格跟随（npos）从面板拿掉、固定开（NET.FLAG_FIXED）
        -- §125 桥接连接自检（单机能跑，约 12 秒）：看游戏有没有把外部服务的连接回调送到，结果写进 net\bridge_conn.log（F4c-2：只在装了桥接扩展包时显示）
        if NETUI.hasBridge() then
            local svc = NETUI.bridgeSvc()
            items[#items + 1] = { label = T(svc .. "连接自检（约 12 秒）", svc:upper() .. " SELF-TEST (~12 S, SEE NET\\BRIDGE_CONN.LOG)"),
                                  act = function() netuiCmd("bridgetest") end }
        end
        -- 0.34 §2.4：安全模式 L0（本地硬开关，只留局域网 / 本地 AI、不连大厅服务器、不碰 Steam）；隐私说明页（和 PRIVACY.md 同一份文字）
        local safe = lb.safe == "1"
        items[#items + 1] = { label = T("仅本地模式（只留局域网 / 本地 AI）：", "LOCAL-ONLY MODE (LAN / LOCAL AI): ") .. (safe and T("开", "ON") or T("关", "OFF")),
                              act = function() netuiCmd("safemode", "on=" .. (safe and "0" or "1") .. "\n") end }
        items[#items + 1] = { label = T("返回", "BACK"), act = page("settings") }
        return items
    end
    if NETUI.page == "settings:ui" then
        items[#items + 1] = { label = T("界面显示：", "ON-SCREEN UI: ") .. UIM.name() .. T("（Insert 切换）", " (INSERT)"),
                              act = function() UIM.next("面板") end }      -- §314 界面三态
        items[#items + 1] = { label = T("语言：中文", "LANGUAGE: ENGLISH"),
                              act = function() netuiCmd("lang", "lang=" .. (LANG.zh and "en" or "zh") .. "\n") end }
        -- §122 游戏里的 fornet_lobby.dll 没有窗口（lobby.txt win=0），只有退回 exe 时才有这个按钮；旧版联机程序不写 win，照旧显示
        if lb.win ~= "0" then
            items[#items + 1] = { label = T("打开电脑上的联机窗口", "OPEN THE DESKTOP WINDOW"), act = function() netuiCmd("show") end }
        end
        items[#items + 1] = { label = T("返回", "BACK"), act = page("settings") }
        return items
    end
    -- §75 本地 AI 对战：联机程序在本机跑一个 AI 对手当客机（lobby/LocalAi.cs），面板只有开始 / 结束和难度（0 简单 / 1 普通 / 2 困难）
    local aiLv = tonumber(lb.ailevel) or 1
    local dstatBtn = { label = T("招式伤害统计…", "DAMAGE PER MOVE..."), act = page("dstat") }      -- §342
    -- 11-26 AI 木桩 V2：AI 难度（改叫"AI 行为状态"）/ §354 跟随 / §114 装备 / 特殊资源 都挪进"AI 训练设置"（原"木桩训练设置"，base_training_ui.lua），
    -- 首页只留一个入口，括号里写当前的行为状态
    local trainBtn = { label = T("AI训练设置…（", "AI TRAINING SETTINGS... (")
                           .. (({ [0] = T("1级难度", "LEVEL 1"), T("2级难度", "LEVEL 2"), T("3级难度", "LEVEL 3"), T("测试木桩", "TRAINING DUMMY") })[aiLv] or "?")
                           .. T("）", ")"), act = page("training") }
    -- §85 AI 对战时同时开房等真人（开关）+ 开房方式（开关开着才显示；按一下换下一种，跳过 ai）；
    -- 有人进来联机程序就停掉 AI、改成和他联机（lobby.txt 的 mode 跟着变成房间的方式）
    local roomOn, roomMode = lb.airoom == "1", lb.airoommode or "lan"
    local function aiRoomItems()
        items[#items + 1] = { label = T("同时开房等真人：", "ALSO HOST A ROOM: ") .. (roomOn and T("开", "ON") or T("关", "OFF")),
                              act = function() netuiCmd("airoom", "on=" .. (roomOn and "0" or "1") .. "\n") end }
        if not roomOn then return end
        items[#items + 1] = { label = T("开房方式：", "ROOM VIA: ") .. "< " .. netModeName(roomMode) .. " >",
                              act = function()
                                  local i, ms = 1, NETUI.modes()
                                  for k, m in ipairs(ms) do if m == roomMode then i = k end end
                                  -- 跳过 ai 和不能当 AI 等人房间的方式（§110 只剩 AI 自己；11-19 起武林盟主也能当等人的房间）
                                  local nx = ms[i % #ms + 1]
                                  for _ = 1, #ms do
                                      if not UI.MODE_NO_AIROOM[nx] then break end
                                      i = i % #ms + 1
                                      nx = ms[i % #ms + 1]
                                  end
                                  netuiCmd("airoommode", "mode=" .. nx .. "\n")
                              end }
        if roomMode == "ranked" then     -- 11-19：排位房间（排位确实激活时才轮得到它，见 mods\ranked\client.lua 的注册）。
                                         -- 文案按半角 56 格以内（论坛 / 1080p 全屏都放得下；写长会把整个面板撑出屏幕，见 §398）
            items[#items + 1] = { label = T("（排位房：AI 对打中也等真人，进来就转成排位对局、计分）",
                                            "(RANKED ROOM: WAITS DURING THE AI FIGHT, RATED)") }
        end
    end
    if mode == "ai" and NETUI.page == "rooms" then NETUI.page = "main" end
    if mode == "ai" and (lb.role or "none") == "none" then
        items[#items + 1] = { label = T("连接方式：", "VIA: ") .. "< " .. netModeName(mode) .. " >", mode = true,
                              act = function() NETUI.step(1) end }
        items[#items + 1] = { label = T("开始 AI 对战", "START AI BATTLE"), act = function() netuiCmd("host") end }
        items[#items + 1] = trainBtn
        items[#items + 1] = dstatBtn
        aiRoomItems()
        if aiLv == 3 then
            -- 两条都控制在半角 56 格以内：一条写太长会把整个文字面板撑出屏幕（§398）
            items[#items + 1] = { label = T("（木桩：出招、防御与资源可在训练设置中调整）",
                                            "(DUMMY: CONFIGURABLE MOVES, DEFENSE AND RESOURCES)") }
            items[#items + 1] = { label = T("（默认不带饰品；伤害按完整一招算）",
                                            "(NO ACCESSORIES; DAMAGE COUNTS THE WHOLE MOVE)") }
        end
        items[#items + 1] = { label = roomOn and T("（有人进来就结束 AI 对战、改成和他打）", "(A PLAYER WHO JOINS REPLACES THE AI)")
                                         or T("（AI 照抄你的属性，装备在「AI训练设置」里选；F1 开打）", "(COPIES YOUR STATS; GEAR IN AI TRAINING; F1 TO FIGHT)") }
        settingsBtns()
        return items
    end
    if lb.mode == "ai" and (lb.role or "none") ~= "none" then
        items[#items + 1] = { label = T("结束 AI 对战", "END AI BATTLE"), act = function() netuiCmd("stop") end }
        items[#items + 1] = trainBtn
        items[#items + 1] = dstatBtn
        aiRoomItems()
        if lb.aiwait == "1" then
            items[#items + 1] = { label = NETUI.viaServer(roomMode) and T("复制房间号（发给朋友）", "COPY MY ROOM CODE") or T("复制房间地址（发给朋友）", "COPY MY ADDRESS"),
                                  act = function() netuiCmd("copy"); netuiFlash(T("已复制到剪贴板", "COPIED TO THE CLIPBOARD")) end }
        end
        settingsBtns()
        return items
    end
    local copy = { label = NETUI.viaServer(mode) and T("复制房间号（发给朋友）", "COPY MY ROOM CODE") or T("复制我的地址（发给朋友）", "COPY MY ADDRESS"),
                   act = function() netuiCmd("copy"); netuiFlash(T("已复制到剪贴板", "COPIED TO THE CLIPBOARD")) end }
    local quick, allRooms = netuiTargets(lb)
    local rooms = (NETUI.filterRooms and NETUI.filterRooms(allRooms)) or allRooms
    if NETUI.page == "rooms" then
        if (lb.role or "none") ~= "none" then NETUI.page = "main"; return UI.netuiItems(lb, tn) end   -- 联机了就回主页
        local curF = NETUI.roomFilter and NETUI.roomFilter() or "all"
        if mode == "server" or curF ~= "all" or (NETUI.hasMpRooms and NETUI.hasMpRooms(allRooms)) then
            local fNames = {
                all = T("全部", "ALL"),
                ["1v1"] = "1v1",
                multi = T("多人", "MULTI"),
                open = T("可加入", "JOINABLE")
            }
            local fName = fNames[curF] or T("全部", "ALL")
            items[#items + 1] = {
                label = T("筛选：< ", "FILTER: < ") .. fName .. " >",
                nav = "filter",
                act = function()
                    local nextF = { all = "1v1", ["1v1"] = "multi", multi = "open", open = "all" }
                    local cur = curF
                    if not nextF[cur] then cur = "all" end
                    if NETUI.setRoomFilter then NETUI.setRoomFilter(nextF[cur]) end
                    NETUI.roomPage = 1
                end
            }
        end
        -- 11-18 用户"像筛选那样加一个独立的 2 态按钮（观战 / 上场）"：进列表方式，点一下切换；点房间按当前方式走
        if mode ~= "ai" and mode ~= "ranked" and not (GUI and GUI.on) then
            local w = (NETUI.roomWatch == true)
            items[#items + 1] = { label = T("进入方式：< ", "ENTER AS: < ") .. (w and T("只观战", "SPECTATE") or T("上场", "PLAY")) .. " >",
                                  act = function()
                                      local nw = not w
                                      NETUI.roomWatch = nw
                                      netuiCmd("specq", "on=" .. (nw and "1" or "0") .. "\n")
                                      netuiFlash(nw and T("进入方式：只观战", "ENTER AS: SPECTATE") or T("进入方式：上场", "ENTER AS: PLAY"))
                                  end }
        end
        local pages = roomPages(rooms)
        NETUI.roomPage = math.min(math.max(NETUI.roomPage or 1, 1), pages)
        local from = (NETUI.roomPage - 1) * perPage()
        for i = from + 1, math.min(from + perPage(), #rooms) do
            local it = joinItem(rooms[i], true)
            it.room = true
            items[#items + 1] = it
        end
        if #rooms == 0 then items[#items + 1] = { label = NETUI.noRooms(lb, mode, tn) } end
        if NETUI.roomPage < pages then
            items[#items + 1] = { label = T("下一页", "NEXT PAGE"), nav = "next", act = function() NETUI.roomPage = NETUI.roomPage + 1; NETUI.sel = 1 end }
        end
        if NETUI.roomPage > 1 then
            items[#items + 1] = { label = T("上一页", "PREVIOUS PAGE"), nav = "prev", act = function() NETUI.roomPage = NETUI.roomPage - 1; NETUI.sel = 1 end }
        end
        items[#items + 1] = { label = T("返回", "BACK"), nav = "back", act = page("main") }
        return items
    end
    if (lb.role or "none") == "none" then
        -- 11-15 用户定的首页顺序（服务器大厅 / 武林盟主 / 局域网一样，这种方式没有的行跳过）：
        -- 房间列表 → 创建多人房间 → 加入多人房间 → 创建房间（旧版）→ 加入房间（旧版）→ 最近一起玩过的人 → 输入房间号加入 → 输入 IPv4 / IPv6 加入（11-15 新版挪到旧版上面）
        -- → 方式自己的行（排位：排行榜等）→ 房间设置 → 系统设置。§281 桥接好友不在首页了，是单独一个标签（NETUI.TABS 的 friends）
        items[#items + 1] = { label = T("连接方式：", "VIA: ") .. "< " .. netModeName(mode) .. " >", mode = true,
                              act = function() NETUI.step(1) end }
        -- v0.20.1：房间列表一律单独一页（用户："房间列表需要一个新的界面，不然显示不全服务器可能有的房间"）。
        -- 没有房间时也能进（列表页里显示"没有房间"，房间来了自动出现）
        local open = 0
        for _, r in ipairs(allRooms) do if roomOpen(r) then open = open + 1 end end
        items[#items + 1] = { label = #allRooms == 0 and (T("房间列表", "ROOM LIST") .. " " .. NETUI.noRooms(lb, mode, tn) .. "…")
                                     or string.format(T("房间列表（%d 个，可加入 %d）…", "ROOM LIST (%d, %d OPEN)..."), #allRooms, open),
                              act = function()      -- 11-18：按当前"进入方式"显示（2 态按钮在列表页里切换）
                                  NETUI.roomWatch = (lb.specnoq == "1")
                                  NETUI.openRooms()
                              end }
        local steam = mode == "bridge"     -- F4c-2：桥接方式（输入对方在外部服务里的 ID）
        local isSrv = mode == "server"
        -- 11-18 用户："旧版入口从大厅和局域网里隐藏，功能留着"：这两种方式不再显示旧版 1v1 入口 / 新版推荐分隔线
        local showClassic = not (mode == "lan" or isSrv)
        -- 11-19 用户："只装基础包时开房开不出来"：没装 / 没启用多人模块（BASEHOOK.mp 是它登记进来的）时，
        -- 下面的几个按钮以前照样发 mphost / mpjoin，可 mp 那条同意是多人模块登记的 → 面板翻到"文案缺失"的同意页、
        -- 联机程序也回"要先同意 mp"，房开不出来。这种时候改成开 / 加入旧版 1v1 房间（走 play 那条同意，基础包自己有）。
        local mpOn = BASEHOOK.mp ~= nil
        if mode == "lan" or isSrv or steam then      -- 多人混战 ②（docs/MULTI.md）：局域网与服务器大厅与桥接
            local mpn = BASEHOOK.mp and BASEHOOK.mp.cfg and BASEHOOK.mp.cfg.size or 4
            -- §306 用户 11-14："房间人数能不能在房间里设置而不是在主面板"：首页只留开房按钮（按上次存的人数开），
            -- 人数在房间里房主的多人面板改（pbz_multi.lua MP.panel → 联机程序 mpsize）；隐藏 IP 挪到系统设置
            -- 11-17 用户：新版两行上下各加一排分隔线强调，旧版直接在标题上写"即将下线"、去掉单独的提示行
            if not mpOn then
                -- 没多人模块：直接给旧版 1v1 的开 / 加入（和「旧版 1v1…」子页同一套；那块子页这时也不另显示）
                local cp, ch
                if isSrv then cp, ch = T("房间号，或 IP:端口 / [IPv6]:端口", "ROOM CODE, OR IP:PORT / [IPV6]:PORT"), "ABC234"
                elseif steam then cp, ch = T("输入主机的" .. NETUI.bridgeSvc() .. " ID", "ENTER THE HOST'S " .. NETUI.bridgeSvc():upper() .. " ID"), ""
                else cp, ch = T("房主地址（IPv6 写 [地址]:端口）", "HOST ADDRESS (IPV6: [ADDR]:PORT)"), "192.168.1.8" end
                items[#items + 1] = { label = T("创建房间（旧版 1v1）", "HOST A ROOM (CLASSIC 1V1)"),
                                      act = function() netuiCmd("host") end }
                items[#items + 1] = { label = T("加入房间…（旧版 1v1）", "JOIN A ROOM... (CLASSIC 1V1)"),
                                      act = function() editStart("join", cp, "", ch) end }
                items[#items + 1] = { label = T("（没装多人模块：只能开 / 加入旧版 1v1 房间）",
                                                "(NO MULTIPLAYER MODULE: CLASSIC 1V1 ROOMS ONLY)"), col = COL_ORANGE }
            else
                if showClassic then
                    items[#items + 1] = { label = T("---------------- 新版房间（推荐） ----------------", "---------------- NEW ROOMS (RECOMMENDED) ----------------"), col = COL_GREEN, sep = true }
                else
                    items[#items + 1] = { label = "--------------------------------------------------", col = COL_GREEN, sep = true }     -- 11-19 只留线、不写字
                end
                -- 11-17 用户：按钮不再写人数 / "进房后可改"
                local hostMpLabel = steam and T("创建房间（桥接）", "HOST A ROOM (BRIDGE)") or T("创建房间", "HOST A ROOM")
                items[#items + 1] = { label = hostMpLabel,
                                      act = function() netuiCmd("mphost", "n=" .. mpn .. "\n") end }
                -- 加入多人房间（联机程序 mpjoin：服务器大厅认房间号或 IP，局域网认地址，桥接认 ID）
                local mpPrompt = isSrv and T("房间号，或 IP:端口 / [IPv6]:端口", "ROOM CODE, OR IP:PORT / [IPV6]:PORT")
                              or steam and T("输入主机的" .. NETUI.bridgeSvc() .. " ID", "ENTER THE HOST'S " .. NETUI.bridgeSvc():upper() .. " ID")
                              or T("房主地址（IPv6 写 [地址]:端口）", "HOST ADDRESS (IPV6: [ADDR]:PORT)")
                items[#items + 1] = { label = T("加入房间…", "JOIN A ROOM..."),
                                      act = function() editStart("mpjoin", mpPrompt, "", isSrv and "ABC234" or steam and "" or "192.168.1.8") end }
            end
            items[#items + 1] = { label = "--------------------------------------------------", col = COL_GREEN, sep = true }
        end
        -- 11-15 用户："新版的创建和加入放在旧版的上面"。11-18 用户："旧版的 2 个选项并入一个子项里"：
        -- 旧版创建 / 加入收进"旧版 1v1（即将下线）…"一页；排位（hl）保持自己的开房按钮 + 加入（房号）
        local hl = UI.MODE_HOST_LABEL[mode]     -- 注册进来的方式（排位）自己的开房按钮文字
        if hl then
            items[#items + 1] = { label = T(hl[1], hl[2]), act = function() netuiCmd("host") end }
            items[#items + 1] = { label = T("加入房间…（房号）", "JOIN A ROOM... (CODE)"),
                                  act = function() editStart("join", T("输入房间号（6 位）", "ENTER THE ROOM CODE"), "", "ABC234") end }
        elseif showClassic and mpOn then      -- 没多人模块时上面已经给了旧版开 / 加入，不再重复一个子页入口
            items[#items + 1] = { label = T("旧版 1v1（即将下线）…", "CLASSIC 1V1 (RETIRING)..."), act = page("classic") }
        end
        for i = 1, math.min(#quick, NETUI_QUICK) do items[#items + 1] = joinItem(quick[i]) end
        items[#items + 1] = { label = T("最近一起玩过的人…", "RECENTLY PLAYED WITH..."), act = page("recent") }     -- 0.34 §3.1（§281 起只有联机记录）
        -- 11-18 用户："房间号和 IP 加入也不会因此少功能，去掉"：服务器大厅不再单列两个快捷入口，旧版加入里都能填
        -- v0.20.1：没建房时一律不显示"复制地址 / 房间号"（用户："我没创建房间，复制功能应该是不能用的"）。
        -- v0.19.1 只对服务器大厅这样做，其他方式当时觉得建房前就有地址可复制
        local mr = UI.MODE_ROWS[mode]     -- 注册进来的方式自己的行（排位：排行榜 / 统计 / 规则说明 / 规则没到）
        if mr then mr(lb, items, page, false) end
    else
        local SEP = "----------------------------------------"     -- 11-18 用户：房间里按组分隔
        BASEHOOK.emit("base.roomHead", items, T, lb)      -- 房间：我是 X 号 / 对局主机（显示在第一条分隔线上面）
        local grp = {}
        if MAPGO.check() == "ok" then     -- v0.24.1 客机、地图不同、主机地图在地图表里
            grp[#grp + 1] = { label = T("前往主机所在地图（会自动存档）", "GO TO THE HOST'S MAP (AUTO-SAVES)"),
                              act = function() MAPGO.go(getP1(), true) end }
        end
        if MAPGO.far and sessionRole() == "client" and not MATCH.role then     -- §156
            grp[#grp + 1] = { label = T("传送到主机身边", "TELEPORT TO THE HOST"), act = function() MAPGO.toHost(getP1(), true) end }
        end
        if CHAT.can(lb) then       -- §112 / §250.4：只有快捷语，没有自由文本
            grp[#grp + 1] = { label = T("快捷语…（Delete）", "QUICK PHRASES... (DELETE)"), act = function() CHAT.open(true) end }
        end
        BASEHOOK.emit("base.roomRows", grp, T, lb, netuiCmd, netuiFlash)      -- L3：往上加的 mod 在房间里加行（观战：换下一位 / 我下去观战 / 排第几）
        BASEHOOK.emit("base.mpRows", grp, T)              -- L5：多人 mod 订阅（命数 / 时限 / 开始）
        if #grp > 0 then
            for _, it in ipairs(grp) do items[#items + 1] = it end
        end
        local cp = {}
        if lb.role == "host" then cp[#cp + 1] = copy end      -- 客机复制自己的地址没用
        if lb.role == "host" and (lb.myv6 or "") ~= "" then     -- §280 本机有公网 IPv6：不在同一个网络的朋友可以"输入 IP 直连"填它
            cp[#cp + 1] = { label = T("复制 IPv6 地址（直连用）", "COPY IPV6 (DIRECT JOIN)"),
                            act = function() netuiCmd("copy", "v6=1\n"); netuiFlash(T("已复制到剪贴板", "COPIED TO THE CLIPBOARD")) end }
        end
        -- 11-15 复制我的 IPv4 地址（服务器大厅房主；"输入 IPv4 / IPv6 加入"用）。公网 IPv4 只有 UPnP 成功时才知道（联机程序 lobby.txt myv4=）。
        -- 11-18 用户："UPnP 失败提示不要常驻，点复制 IPv4 失败时再弹"：面板不再列 UPnP 状态行，只在这里按需提示。
        if lb.role == "host" and lb.mode == "server" then
            local v4 = lb.myv4 or ""
            cp[#cp + 1] = { label = v4 ~= "" and T("复制 IPv4 地址（直连用）", "COPY IPV4 (DIRECT JOIN)")
                                              or T("复制 IPv4 地址（需 UPnP）", "COPY IPV4 (NEEDS UPNP)"),
                            act = function()
                                if v4 == "" then
                                    if lb.upnpon ~= "1" then
                                        netuiFlash(T("UPnP 没开：先去 系统设置 → 网络与连接 打开", "UPNP IS OFF: TURN IT ON IN SETTINGS → NETWORK"), COL_ORANGE)
                                    else
                                        local why = (lb.upnp or "")
                                        if why == "" then why = T("路由器没开 UPnP（或网络发现关了）", "ROUTER UPNP IS OFF") end
                                        netuiFlash(T("UPnP 失败：", "UPNP FAILED: ") .. why .. T("；请在路由器里把 UDP 27015 转发到本机", "; FORWARD UDP 27015 IN YOUR ROUTER"), COL_ORANGE)
                                    end
                                    return
                                end
                                netuiCmd("copy", "v4=1\n")
                                if lb.myv4np == "1" then
                                    netuiFlash(T("已复制；这个地址可能不是公网 IP（多层路由 / 运营商 NAT）", "COPIED; THIS MAY NOT BE A PUBLIC IP (DOUBLE NAT)"), COL_ORANGE)
                                else netuiFlash(T("已复制到剪贴板", "COPIED TO THE CLIPBOARD")) end
                            end }
        end
        if #cp > 0 then
            if #grp > 0 then items[#items + 1] = { label = SEP, col = COL_GREEN, sep = true } end
            for _, it in ipairs(cp) do items[#items + 1] = it end
        end
        items[#items + 1] = { label = T("断开", "DISCONNECT"), act = function() netuiCmd("stop") end }
        UI.modeRowsInRoom(lb, items, page)     -- 房间里也能看注册方式自己的行（排位：排行榜 / 统计 / 规则说明；靠 rk=1 认出排位房间）
    end
    if ST.ext then ST.ext.rows("main", items, lb) end                                      -- X1 扩展包加在首页的行
    BASEUI.rowsOf("main", items, lb)                                                       -- L3 玩法 mod 加在首页的行
    BASEHOOK.emit("base.playBtns", items, T)     -- 11-15 玩法设置…（多人 mod）放在房间设置… / 系统设置…上面，三个并排
    settingsBtns()
    return items
end
UI.defaultItems = netuiDefaultItems
-- F3b-5：影之刃零的面板页按名字注册回核心（内容还在上面各段里）；排位四页在排位扩展包 ext/ranked/client.lua 里注册（F4b；11-13 搬进扩展包）
UI.page("training", function(lb, tn, items, page) if lb.mode ~= "ai" then return false end; TRAINUI.items(lb, items, page) end, { "联机 · AI 训练设置", "ONLINE · AI TRAINING" })     -- 11-26 V2：所有难度都能进
UI.page("training:actions", function(lb, tn, items, page) if lb.mode ~= "ai" or tonumber(lb.ailevel) ~= 3 then return false end; TRAINUI.actions(lb, items, page) end, { "木桩 · 重复出招", "DUMMY · REPEATED MOVES" })
-- §456 防御闪避 / 血量杀气两页并进"木桩训练"那一页；重复间隔单独一页（拖动条）
UI.page("training:interval", function(lb, tn, items, page) if lb.mode ~= "ai" or tonumber(lb.ailevel) ~= 3 then return false end; TRAINUI.interval(lb, items, page) end, { "木桩 · 重复间隔", "DUMMY · REPEAT INTERVAL" })
UI.page("training:resources", function(lb, tn, items, page)
    if lb.mode ~= "ai" or (BASEHOOK.mp and BASEHOOK.mp.inMp and BASEHOOK.mp.inMp()) then return false end
    if TRAINING then TRAINING.items(lb, items, page, netuiFlash) end
end, { "本地AI · 特殊资源", "LOCAL AI · RESOURCES" })
UI.page("aiload", function(lb, tn, items, page) NETUI.aiLoadItems(lb, items, page) end, { "联机 · AI 装备", "ONLINE · AI LOADOUT" })     -- §114 AI 装备
UI.page("aipick", function(lb, tn, items, page) NETUI.aiPickItems(lb, items, page) end, { "联机 · AI 装备 · 选择", "ONLINE · AI LOADOUT · PICK" })
UI.page("dstat", function(lb, tn, items, page) if not DSTAT then return false end; DSTAT.items(lb, items, page, netuiFlash) end, { "联机 · 招式伤害统计", "ONLINE · DAMAGE PER MOVE" })     -- §342
UI.page("accban", function(lb, tn, items, page) NETUI.accBanItems(lb, items, page) end)     -- §176 禁用饰品
for k in pairs(WBAN.LIST) do UI.page(k, function(lb, tn, items, page) NETUI.wbanItems(k, lb, items, page) end) end     -- §180 禁用武器 / 影之武装
UI.page("phrases", function(lb, tn, items, page) if not CHAT.phraseItems(lb, items, page) then return false end end, { "联机 · 快捷语", "ONLINE · QUICK PHRASES" })     -- §150 快捷短语
UI.page("thanks", function(lb, tn, items, page)     -- v0.27.21 感谢名单（设置里的一页）：参与测试并反馈了 bug 的玩家
        items[#items + 1] = { label = T("参与测试并反馈了 bug 的玩家（B 站/QQ，以首字拼音排序）：", "PLAYERS WHO TESTED AND REPORTED BUGS (BILIBILI/QQ, BY PINYIN):") }     -- 11-27 用户：一个列表、按首字拼音排序（同音看第二个字，"、"没拼音放最后）
        for _, n in ipairs({ "成步堂芦苇", T("Decision of Fate 与其小伙伴", "Decision of Fate and friends"), "肥格fager、苏苏、风魔唯以及其工作室的小伙伴们", "化境", "絡訸", "谦逊的刘恒宇",
                             T("伊格尼斯：一直以来对数值平衡做出的贡献", "伊格尼斯 - for the ongoing contributions to damage balance"), "一一清梦以及他的小伙伴们", "亦如黎明中的花朵_", "、（你没看错）" }) do items[#items + 1] = { label = "  " .. n } end
        items[#items + 1] = { label = T("返回", "BACK"), act = page("settings") }
end, { "联机 · 感谢名单", "ONLINE · THANKS" })
-- ---- L3（docs/FORNET_LAYERS.md）：基础联机包给其他玩法 mod 的面板接口（服务 ui）+ "已装的玩法"页。全局：主块 local 满 200 个
BASEUI = { rows = { main = {}, settings = {} }, modRows = {}, want = {} }
function BASEUI.addRows(owner, pageId, fn)
    local l = BASEUI.rows[pageId]
    if not (l and type(fn) == "function") then return false end
    l[#l + 1] = { owner = owner, fn = fn }
    return true
end
function BASEUI.addModRows(owner, fn) if type(fn) ~= "function" then return false end; BASEUI.modRows[owner] = fn; return true end
function BASEUI.rowsOf(pageId, items, lb)
    for _, r in ipairs(BASEUI.rows[pageId] or {}) do
        local ok, err = pcall(r.fn, items, T, lb)
        if not ok and r.err ~= err then r.err = err; out("!! 玩法 mod %s 的面板行出错：%s", tostring(r.owner), tostring(err)) end
    end
end
function BASEUI.hasMods() local S = FORNET and FORNET.modsys; return S and S.list and #S.list > 0 or false end
-- L3 服务 ui.addPage：mod 自己的一整页（页 id = mod:<名>:<id>），底下自动加"返回"；"已装的玩法"页本 mod 那一栏列出它的页
BASEUI.pages = {}
-- 11-14：玩法 mod 自己的同意项（多人 mp、观战 spec）。这里看得见面板段的 UI（main.lua 末尾的服务表看不见）
function BASEUI.addConsent(owner, d) return UI.addConsent(d, owner) end
function BASEUI.lmbDown() if UI.lmbDown then UI.lmbDown() end end     -- 11-14 快速点击：文件末尾的左键钩子经这里（末尾看不见 UI）
function BASEUI.addPage(owner, d)
    if type(d) ~= "table" or type(d.build) ~= "function" then return nil end
    local id = "mod:" .. tostring(owner) .. ":" .. tostring(d.id or (#(BASEUI.pages[owner] or {}) + 1))
    UI.page(id, function(lb, tn, items, page)
        local ok, err = pcall(d.build, items, T, lb, page)
        if not ok then out("!! 玩法 mod %s 的页 %s 出错：%s", tostring(owner), id, tostring(err)) end
        items[#items + 1] = { label = T("返回", "BACK"), act = page(d.back or ("modinfo:" .. tostring(owner))) }
    end, { "联机 · " .. tostring(d.title or owner), "ONLINE · " .. tostring(d.titleEn or d.title or owner) })
    local l = BASEUI.pages[owner] or {}
    BASEUI.pages[owner] = l
    -- 11-15 用户："我的队伍设置为什么在（已装的玩法）这里，而不是在联机菜单里"：房间里的页（room = true，或返回首页的）不列进玩法详情页
    l[#l + 1] = { id = id, title = d.title, titleEn = d.titleEn, room = d.room == true or d.back == "main" }
    return id
end
function BASEUI.go(pageId)
    local X = EXTCTX
    if not (X and X.NETUI) then return false end
    X.NETUI.page, X.NETUI.sel = pageId, 1
    return true
end
-- 启用开关看 on.txt：第一次显示时读一次、点了按点的记，不每次刷新都开文件
function BASEUI.wanted(S, name)
    if BASEUI.want[name] == nil then
        local f = io.open(S.onFile(name) or "", "r")
        BASEUI.want[name] = f ~= nil
        if f then f:close() end
    end
    return BASEUI.want[name]
end
-- 11-15 用户："这种多个平级的确认会导致界面放不下，要么多一层"、"同意协议和启用应该是一个意思"：
-- "已装的玩法"页每个玩法只占一行，点进 modinfo:<名> 详情页（状态 / 条款标题 / 它自己的页 / 启用停用）；条款全文再点进 ctext 页。
-- 启用 = 同意它的全部条款，停用 = 一起撤回
function BASEUI.modKeys(S, name)     -- 这个玩法的同意键：manifest consent=@<键> + addConsent 登记的（TEXT[k].ext = 名）
    local keys, seen = {}, {}
    local mm = S and S.byName and S.byName[name]
    for key in tostring(mm and mm.manifest and mm.manifest.consent or ""):gmatch("@?([%w_]+)") do
        if CONSENT.TEXT[key] and not seen[key] then seen[key] = true; keys[#keys + 1] = key end
    end
    local more = {}
    for k, t in pairs(CONSENT.TEXT) do if type(t) == "table" and t.ext == name and t.mod and not seen[k] then more[#more + 1] = k end end
    table.sort(more)
    for _, k in ipairs(more) do keys[#keys + 1] = k end
    return keys
end
function BASEUI.modState(S, m)
    -- 状态说的是"这次游戏里加载了没有"；点了开关还没重启时不能写成"已停用 / 已启用"（用户 11-19：
    -- "设置启用后这里应该显示未加载，而不是已停用"）。状态和按钮都按同一份 want 算，免得上面写停用、下面按钮也是停用。
    local on = m.state == "on"
    local st = on and T("已加载", "LOADED") or m.state == "off" and T("已停用", "DISABLED") or T("没加载", "NOT LOADED")
    local pend = false
    if m.name ~= "base" then
        local want = BASEUI.wanted(S, m.name)
        pend = want ~= on
        if pend then
            st = want and T("未加载（重启游戏后加载）", "NOT LOADED (LOADS AFTER RESTART)")
                      or T("已加载（重启游戏后停用）", "LOADED (DISABLES AFTER RESTART)")
        end
    end
    return st, pend
end
function BASEUI.modOf(S, name)
    for _, x in ipairs(S and S.status() or {}) do if x.name == name then return x end end
    return nil
end
UI.page("mods", function(lb, tn, items, page)
    local S = FORNET and FORNET.modsys
    local X = EXTCTX or {}
    local C = X.COL or {}
    items[#items + 1] = { label = T("已装的玩法：点进去看说明 / 条款 / 开关（改后重启生效）", "GAME MODES: OPEN ONE FOR INFO / TERMS / ON-OFF (RESTART TO APPLY)"), col = C.label }
    for _, m in ipairs(S and S.status() or {}) do
        local st, pend = BASEUI.modState(S, m)
        local title = T(m.title or m.name, m.titleEn or m.title or m.name)
        items[#items + 1] = { label = string.format("%s（%s）v%s  %s…", title, m.name, tostring(m.version), st),
                              col = pend and C.orange or m.state == "on" and C.green or C.label, act = page("modinfo:" .. m.name) }
    end
    for _, k in ipairs(S and S.keyTable() or {}) do
        for _, c in ipairs(k.conflicts or {}) do
            items[#items + 1] = { label = string.format(T("键位冲突：%s 想用 %s，已经归 %s", "KEY CONFLICT: %s WANTS %s, OWNED BY %s"), tostring(c.owner), k.id, tostring(k.owner)), col = C.orange }
        end
    end
    items[#items + 1] = { label = T("返回", "BACK"), act = page("settings") }
end, { "联机 · 已装的玩法", "ONLINE · GAME MODES" })
UI.pagePrefixReg("modinfo:", function(lb, tn, items, page)
    local S = FORNET and FORNET.modsys
    local X = EXTCTX or {}
    local C = X.COL or {}
    local m = BASEUI.modOf(S, ((X.NETUI and X.NETUI.page) or ""):match("^modinfo:(.+)$"))
    if not m then items[#items + 1] = { label = T("返回", "BACK"), act = page("mods") }; return end
    local st, pend = BASEUI.modState(S, m)
    local on = m.state == "on"
    local want = m.name ~= "base" and BASEUI.wanted(S, m.name) or on
    items[#items + 1] = { label = string.format("■ %s  v%s  %s", T(m.title or m.name, m.titleEn or m.title or m.name), tostring(m.version), st),
                          col = pend and C.orange or on and C.green or C.label }
    if pend then
        items[#items + 1] = { label = "  " .. (want and T("请重启游戏加载", "RESTART THE GAME TO LOAD IT")
                                                    or T("请重启游戏生效", "RESTART THE GAME TO APPLY")), col = C.orange }
    end
    if m.why and m.state ~= "off" then items[#items + 1] = { label = "  " .. tostring(m.why), col = C.orange } end
    local keys = BASEUI.modKeys(S, m.name)
    if #keys > 0 then
        items[#items + 1] = { label = T("启用 = 同意这些条款（点开看全文）：", "ENABLING = AGREEING TO THESE TERMS (OPEN TO READ):"), col = C.label }
        CONSENT.titleRows(items, keys)
    end
    for _, pg in ipairs(BASEUI.pages[m.name] or {}) do
        if not pg.room then items[#items + 1] = { label = T(tostring(pg.title or pg.id), tostring(pg.titleEn or pg.title or pg.id)) .. "…", act = page(pg.id) } end
    end
    local fn = BASEUI.modRows[m.name]
    if fn then
        local ok, err = pcall(fn, items, T, lb)
        if not ok then out("!! 玩法 mod %s 的说明行出错：%s", m.name, tostring(err)) end
    end
    if m.name ~= "base" then     -- 基础联机包停了，这个面板也就没了；真要停就删它目录里的 on.txt
        local missing = false
        for _, k in ipairs(keys) do if not CONSENT.has(k) then missing = true end end
        if want and missing then
            items[#items + 1] = { label = T("同意上面的条款", "AGREE TO THE TERMS"),
                                  act = function() CONSENT.grantKeys(keys); out("玩法 mod %s：同意 %s", m.name, table.concat(keys, ",")) end }
        end
        -- 点了还没重启（on.txt 和这次加载状态对不上）时按钮写清是"取消这次启用"，不要写"停用"让人以为在关一个已启用的
        local lbl
        if want and not on then     -- 点了启用、还没重启：按钮是"取消这次启用"，不是"停用"
            lbl = #keys > 0 and T("取消启用（撤回同意）", "CANCEL ENABLE (WITHDRAW TERMS)") or T("取消启用", "CANCEL ENABLE")
        else
            lbl = want and (#keys > 0 and T("停用（同时撤回同意，重启生效）", "DISABLE (ALSO WITHDRAWS TERMS; RESTART)") or T("停用（重启生效）", "DISABLE (RESTART)"))
                        or (#keys > 0 and T("同意并启用（重启生效）", "AGREE AND ENABLE (RESTART)") or T("启用（重启生效）", "ENABLE (RESTART)"))
        end
        items[#items + 1] = { label = lbl,
                              act = function()
                                  local f = S.onFile(m.name)
                                  if want then os.remove(f); CONSENT.revokeKeys(keys) else fileWrite(f, ""); CONSENT.grantKeys(keys) end
                                  BASEUI.want[m.name] = not want
                                  out("玩法 mod %s：%s（重启游戏生效）%s", m.name, want and "停用" or "启用", #keys > 0 and ((want and "，撤回 " or "，同意 ") .. table.concat(keys, ",")) or "")
                                  if X.netuiFlash then X.netuiFlash(T("重启游戏生效", "TAKES EFFECT AFTER A RESTART")) end
                              end }
    end
    items[#items + 1] = { label = T("返回", "BACK"), act = page("mods") }
end, { "联机 · 玩法", "ONLINE · GAME MODE" }, function(lb, tn)
    local m = BASEUI.modOf(FORNET and FORNET.modsys, ((EXTCTX and EXTCTX.NETUI and EXTCTX.NETUI.page) or ""):match("^modinfo:(.+)$"))
    return m and (T("联机 · 玩法 · ", "ONLINE · MODE · ") .. T(m.title or m.name, m.titleEn or m.title or m.name)) or T("联机 · 玩法", "ONLINE · GAME MODE")
end)
UI.pagePrefixReg("ext", function(lb, tn, items, page)     -- X1 扩展包（fornet_ext.lua）的页：ext / ext:<名>
    if not ST.ext then return false end
    lb._page = NETUI.page; ST.ext.pageItems(lb, items, page)
end, nil, function() return ST.ext and ST.ext.pageTitle(NETUI.page) or nil end)
UI.pollHooks[#UI.pollHooks + 1] = function(lb) if ST.ext then ST.ext.poll(lb) end end

-- ---- 0.34 本地偏好 PREF：存 net/rules.txt 的任意键（只动自己的键，别的行原样留着；和 NET.dmSet 同一套写法）（→ fornet_core.lua，F3）
PREF = FN.PREF

-- ---- 0.34 "最近"页（TASK_0.34 最终方案 2 / §3.1）：最近一起玩过的人（联机程序本地 history.txt，不上传）+ 开了设置时正在开房的 Steam 好友。
-- F3b-3（docs/FORNET_SPLIT.md）：整段搬到 fornet_ui.lua；RECENT 在这里仍是全局（CONSENT 段 / 隐私说明用）
RECENT = UI.RECENT

-- ---- 0.34 二次确认 CONSENT（TASK_0.34 总原则：任何改模组行为 / 任何数据传输都要玩家同意一次；原来的例外"下线标志"X3 删了）。
-- F3b-4（docs/FORNET_SPLIT.md）：CONSENT 框架 / 文案表 / EXTCTX / OPP 整段搬到 fornet_ui.lua；三个名字在这里仍是全局（文件末尾 ST.ext、隐私说明、pbz_ext 在用）
CONSENT, EXTCTX, OPP = UI.CONSENT, UI.EXTCTX, UI.OPP

-- F3b-5（docs/FORNET_SPLIT.md）：netuiStatus / netuiRows / netuiItems 骨架 / NETUI.step / setMode 搬到 fornet_ui.lua；这里取别名
local netuiStatus, netuiRows = UI.netuiStatus, UI.netuiRows

-- F3b-2（docs/FORNET_SPLIT.md）：鼠标面板 GUI 整段搬到 fornet_ui.lua；这里只取别名
local BG_DOWN, BG_HOVER, BG_NONE, BG_OFF, BG_ROW, BG_SEL = UI.BG_DOWN, UI.BG_HOVER, UI.BG_NONE, UI.BG_OFF, UI.BG_ROW, UI.BG_SEL
local guiBg, guiClicked, guiLabel, guiRoot, guiVis, netuiSetOpen = UI.guiBg, UI.guiClicked, UI.guiLabel, UI.guiRoot, UI.guiVis, UI.netuiSetOpen

-- ---- §112 房内聊天 → §250.4 快捷语（TASK_0.34 §2.5，用户 2026-11-12 定："聊天只保留固定短语，去掉自由文本输入 / 粘贴"）。
-- 协议：只传短语编号 REL.send("chatq", "<id>")，不传文本；收方按自己的表渲染，编号不在表里就丢。旧版发来的 "chat" 自由文本只计数不显示。
-- 限流：发 / 收各自每 2 秒 1 条、每分钟 10 条，超了丢。可静音（系统设置 / 快捷语页"不看对手的快捷语"，存 rules.txt qmute=）；
-- 拉黑的对手（lobby.txt op1 已拉黑）发来的不显示。不落盘、日志只记编号不记文字。
-- 发：Delete 键（Insert 被 BPModLoaderMod 占，F 键全满）或面板"快捷语…"→ 面板翻到快捷语页，点一句就发。
-- 显示：屏幕左下角最近 CHAT.LINES 条，每条 CHAT.SHOW_SEC 秒后藏起来；面板开着时一直显示最近几条。
-- 字挂在屏幕文字那层（HUD.w）上：游戏暂停时跟着藏，换地图后 HUD 重建、这里跟着重建。
-- 全局表（主代码块的 local 已满 200 个）
CHAT = { log = {}, HIST = 30, LINES = 6, SHOW_SEC = 15, MAX_BYTES = 150, X = 0.015, Y = 0.80, SIZE = 0.55,
         RATE_GAP = 2.0, RATE_MIN = 10,          -- 每 2 秒 1 条、每 60 秒 10 条（发、收各算）
         sentAt = {}, recvAt = {}, mute = nil, textWarned = nil,
         COL_ME = { R = 150, G = 205, B = 255, A = 255 }, COL_SYS = { R = 255, G = 140, B = 40, A = 255 } }

-- 固定短语表（中性；这是模组作者提供的内容，别放嘲讽 / 地域 / 人身 / 广告）。编号就是下标，两边同一版才对得上；
-- 加新句只能往后追加，不能改旧句的位置
CHAT.PHRASES = {
    { "你好，请多指教", "HI, GOOD LUCK" }, { "打得好", "WELL PLAYED" }, { "GG", "GG" },
    { "再来一局？", "REMATCH?" }, { "等我一下", "WAIT A SEC" }, { "准备好了", "READY" },
    { "我这边网有点卡", "LAGGING ON MY SIDE" }, { "抱歉", "SORRY" }, { "谢谢", "THANKS" },
    { "好险", "CLOSE ONE" }, { "可惜", "SO CLOSE" },
}
function CHAT.phrase(id) local p = CHAT.PHRASES[id]; return p and T(p[1], p[2]) or nil end

-- 一行文字：去掉控制字符和首尾空白；超过 MAX_BYTES 字节按 UTF-8 字边界截断（中文一个字 3 字节）。只给系统提示 / 昵称用
function CHAT.clean(s)
    s = tostring(s or ""):gsub("%c", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #s <= CHAT.MAX_BYTES then return s end
    local n = CHAT.MAX_BYTES
    while n > 0 do
        local b = s:byte(n + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end     -- 下一个字节不是续字节：在这里切是完整的字
        n = n - 1
    end
    return s:sub(1, n)
end

-- kind = me / peer / sys；id 有就只记编号（文字不进日志）
function CHAT.add(who, text, kind, id)
    CHAT.log[#CHAT.log + 1] = { who = who, text = text, kind = kind, at = os.time() }
    while #CHAT.log > CHAT.HIST do table.remove(CHAT.log, 1) end
    if id then out("【快捷语】%s#%d", who and (who .. " ") or "", id) else out("【聊天】%s", text) end
end

-- 能发：联机程序活着、连上了真人（本地 AI 不算）
function CHAT.can(lb)
    return lb and lobbyAlive(lb) and lb.connected == "1" and lb.mode ~= "ai"
end

-- 限流：list 里记最近的时间，返回 true = 这一条放行（并记下来）
function CHAT.allow(list, tn)
    local keep = {}
    for _, t in ipairs(list) do if tn - t < 60 then keep[#keep + 1] = t end end
    if #keep > 0 and tn - keep[#keep] < CHAT.RATE_GAP then return false, keep end
    if #keep >= CHAT.RATE_MIN then return false, keep end
    keep[#keep + 1] = tn
    return true, keep
end

-- 静音开关：存 rules.txt 的 qmute=（只动自己的键）
CHAT.RULES_FILE = NET_DIR .. "/rules.txt"
function CHAT.muted()
    if CHAT.mute == nil then
        local t = fileReadKV(CHAT.RULES_FILE)
        CHAT.mute = (t and t.qmute == "1") or false
    end
    return CHAT.mute
end
function CHAT.setMute(on)
    CHAT.mute = on and true or false
    PREF.set("qmute", on and 1 or 0)
end

-- 发第 id 句（面板点 / 以后的键位都走这里）
function CHAT.sendPhrase(id)
    id = tonumber(id)
    local text = id and id == math.floor(id) and CHAT.phrase(id)
    if not text then return false end
    if not CHAT.can(netuiRead(now())) then
        CHAT.add(nil, T("没连上对方，没发出去", "NOT CONNECTED, NOT SENT"), "sys")
        return false
    end
    local ok, keep = CHAT.allow(CHAT.sentAt, now())
    CHAT.sentAt = keep
    if not ok then CHAT.add(nil, T("发得太快了，歇一下", "TOO FAST, SLOW DOWN"), "sys"); return false end
    -- §309（11-14 实测）：多人房（全互连）的联机程序只转发 chat 事件（房主广播成 chatn "谁|内容"），chatq 编号到房主那里就丢了
    -- → 多人房里快捷语谁都收不到。多人房发短语原文：收的那边 CHAT.recvn 只认和短语表完全一样的，自由文本照样不显示
    local sm = BASEHOOK.mp
    if sm and sm.inMp and sm.inMp() then REL.send("chat", text) else REL.send("chatq", tostring(id)) end
    CHAT.add(T("我", "ME"), text, "me", id)
    if CHAT.autoClose then CHAT.autoClose = nil; CHAT.close("快捷语已发") end     -- 按 Delete 开的面板：发完就关
    return true
end

-- 面板"快捷语"页（NETUI.page = "phrases"）；按 Delete 也翻到这页
function CHAT.phraseItems(lb, items, page)
    if not CHAT.can(lb) then NETUI.page = "main"; return false end
    for i = 1, #CHAT.PHRASES do
        items[#items + 1] = { label = i .. ". " .. CHAT.phrase(i), act = function() CHAT.sendPhrase(i) end }
    end
    items[#items + 1] = { label = T("不看对手的快捷语：", "HIDE OPPONENT'S PHRASES: ") .. (CHAT.muted() and T("开", "ON") or T("关", "OFF")),
                          act = function() CHAT.setMute(not CHAT.muted()) end }
    items[#items + 1] = { label = T("（只能发这些固定短语，不能打字）", "(FIXED PHRASES ONLY, NO TYPING)") }
    items[#items + 1] = { label = T("返回", "BACK"), act = page("main") }
    return true
end

-- 对方发来的编号（REL.on.chatq）：不在表里 / 静音 / 对手已拉黑 / 太频繁 → 丢
function CHAT.recvQ(rest)
    local id = tonumber((tostring(rest or ""):match("^%s*(%d+)%s*$")))
    local text = id and CHAT.phrase(id)
    if not text then out("快捷语：收到不认识的编号 %s，忽略", tostring(rest):sub(1, 20)); return end
    if CHAT.muted() then return end
    local lb = netuiRead(now()) or {}
    if (lb.op1 or ""):sub(1, 2) == "1|" then return end      -- §174 当前对手在我的黑名单里
    local ok, keep = CHAT.allow(CHAT.recvAt, now())
    CHAT.recvAt = keep
    if not ok then return end
    local who = (lb.peername or "") ~= "" and lb.peername or T("对方", "PEER")
    CHAT.add(clipText(who, 16), text, "peer", id)
end

-- 旧版客户端发来的自由文本（REL.on.chat）：不显示、不记内容，每个对手只提示一次
function CHAT.recvText(rest)
    if CHAT.textWarned == CHAT.peer then return end
    CHAT.textWarned = CHAT.peer
    CHAT.add(nil, T("对方模组太旧，文字聊天不显示", "PEER RUNS AN OLD VERSION; TYPED CHAT IS NO LONGER SHOWN"), "sys")
end

-- Delete 键 / 面板按钮：打开面板翻到快捷语页。面板关着时先打开，发完一句后再关上（CHAT.autoClose）
-- mesh 多人房 / 解说房的聊天（REL.on.chatn）：谁|内容。0.34 规矩：不显示自由文本——内容必须和某条快捷语原文一致才显示，否则按旧版文本处理
function CHAT.recvn(rest)
    if not rest or rest == "" then return end
    local who, text = rest:match("^([^|]+)|(.*)$")
    if not who then who, text = "", rest end
    local s = CHAT.clean(text)
    if s == "" then return end
    local id
    for i = 1, 64 do local ph = CHAT.phrase(i); if not ph then break end; if ph == s then id = i; break end end
    if not id then return CHAT.recvText(rest) end
    if CHAT.muted() then return end
    -- 11-17 排查补齐：房间聊天也按黑名单滤（1v1 那条看 op1；房里看发言人的名字在不在黑名单 blN 里）
    if who ~= "" then
        local lb = netuiRead(now()) or {}
        local base = who:gsub("（%d+号）$", "")
        for i = 1, tonumber(lb.bln) or 0 do
            local nick = (lb["bl" .. i] or ""):match("^[^|]*|[^|]*|(.*)$")
            if nick and nick ~= "" and (nick == who or nick == base) then return end
        end
    end
    local ok, keep = CHAT.allow(CHAT.recvAt, now())
    CHAT.recvAt = keep
    if not ok then return end
    CHAT.add(clipText(who ~= "" and who or T("对方", "PEER"), 16), s, "peer", id)
end

-- 输入框在下一轮 CHAT.step 才开：刚打开的鼠标面板这一轮才建好，建的时候会关掉已经开着的输入框（guiRoot）
function CHAT.open(fromPanel)
    if NETUI.edit then return end            -- 在输入框里按 Delete 是删字
    local okP, paused = pcall(function() return G.menuOpen() end)     -- 11-26 游戏菜单真开着（UUU 相机 mod 的暂停不算）
    if okP and paused == true then return end
    if not CHAT.can(netuiRead(now())) then
        CHAT.add(nil, T("没连上对方，不能发快捷语", "NOT CONNECTED, NO QUICK PHRASES"), "sys")
        return
    end
    if not NETUI.open then netuiSetOpen(true, "快捷语"); CHAT.autoClose = true
    elseif not fromPanel then CHAT.autoClose = nil end
    CHAT.pending = true
end

function CHAT.close(why)
    netuiSetOpen(false, "快捷语" .. tostring(why or ""))
end

function CHAT.piece(cv)
    local tb = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), HUD.w.WidgetTree)
    local sl = cv:AddChildToCanvas(tb)
    sl:SetAnchors({ Minimum = { X = CHAT.X, Y = CHAT.Y }, Maximum = { X = CHAT.X, Y = CHAT.Y } })
    sl:SetAlignment({ X = 0.0, Y = 1.0 })
    sl:SetAutoSize(true)
    tb:SetVisibility(1)
    return { tb = tb, sl = sl }
end

-- 每帧（驱动循环，M4.step 之后）
function CHAT.step(tn)
    -- §116 连接断了 / 换了对手就清掉上一场的聊天（16:4x 实测：断开后打开面板，左下角还显示上一场假对手的招呼，看着像还在房间里）。
    -- 联机程序暂时没回话（lobbyAlive 假）时不动，免得聊到一半被清
    local lb = netuiRead(tn)
    if lobbyAlive(lb) then
        local key = lb.connected == "1" and (lb.peer or "?") or nil
        if key ~= CHAT.peer then
            if CHAT.peer and #CHAT.log > 0 then out("聊天：%s，清掉上一场的 %d 条", key and "换了对手" or "连接断了", #CHAT.log); CHAT.log = {} end
            CHAT.peer = key
        end
    end
    if CHAT.pending then
        CHAT.pending = nil
        if NETUI.open and not NETUI.edit then NETUI.page, NETUI.sel = "phrases", 1 end     -- §250.4 翻到快捷语页，点一句就发
    end
    if HUD.failed then return end
    local all = NETUI.open
    local t, show = os.time(), {}
    for i = math.max(1, #CHAT.log - CHAT.LINES + 1), #CHAT.log do
        local m = CHAT.log[i]
        if all or (t - m.at < CHAT.SHOW_SEC and not UIM.hideMod()) then show[#show + 1] = m end     -- §314 1 / 2 档只在面板开着时显示
    end
    if #show == 0 then
        if CHAT.w ~= HUD.w or not CHAT.p then return end
        if HUD.gen ~= ST.mapLoads or not valid(HUD.w) then return end     -- §93 旧地图的控件不碰
        for _, p in ipairs(CHAT.p) do umgSet(p, nil) end
        return
    end
    local cv = umgRoot()
    if not cv then return end
    if CHAT.w ~= HUD.w then CHAT.w, CHAT.p = HUD.w, {} end
    local lineH = HUD_PX * CHAT.SIZE * 1.3
    for i = 1, CHAT.LINES do
        local m = show[i]
        if m and not CHAT.p[i] then CHAT.p[i] = CHAT.piece(cv) end
        local p = CHAT.p[i]
        if p then
            local s = m and ((m.who and (m.who .. "：") or "") .. m.text) or nil
            local col = m and (m.kind == "me" and CHAT.COL_ME or m.kind == "sys" and CHAT.COL_SYS or COL_WHITE) or COL_WHITE
            umgSet(p, s, col, CHAT.SIZE, -(#show - i) * lineH)
        end
    end
end

local GUI_TAB = UI.GUI_TAB     -- F4b：标签文字在 fornet_ui（注册进来的方式经 UI.addMode 加）

-- v0.26.4 用户 2026-11-05："开着 mod 的 UI，切出游戏再回来鼠标就丢了，要按 Home 关了再开"。
-- 切回窗口时游戏把输入模式改回只给游戏（指针藏起、被视口抓住），面板不知道。面板开着（不在输入）时每轮查：
-- ① 鼠标指针被关了；② 面板（和里面的按钮）丢了焦点超过 0.3 秒 → 重新放鼠标。焦点一直拿不到（GUI.focusable 但从没见过有焦点）
-- 时 ② 每 3 秒最多重放一次，免得一直抢鼠标点不了按钮。输入框自己的丢焦点由 editTick 管
GUI.mouseTick = function()      -- 表字段不占 local（M4 里 local 也快满了）
    if not (NETUI.open and GUI.on) or NETUI.edit then return end
    if not GUI.fresh() then return end              -- v0.27.12 旧地图的面板：等 guiRoot 重建（§93）
    local pc = GUI.pc
    if valid(pc) then
        local okS, shown = pcall(function() return pc.bShowMouseCursor end)
        if okS and shown == false then out("鼠标面板：鼠标指针被关了，重新放出"); inputMode(false); return end
    end
    if not GUI.focusable then return end
    local okF, focus = pcall(function() return GUI.w:HasAnyUserFocus() or GUI.w:HasFocusedDescendants() end)
    if not okF then return end
    local t = now()
    if focus then GUI.lostAt, GUI.focusSeen = nil, true; return end
    if not GUI.lostAt then GUI.lostAt = t; return end
    if t - GUI.lostAt > (GUI.focusSeen and 0.3 or 3.0) then
        out("鼠标面板：焦点被抢走（切出窗口回来？），重新放出鼠标")
        GUI.focusSeen = false
        inputMode(false)            -- 里面清 GUI.lostAt
    end
end

-- §456 鼠标面板的拖动条（用户 11-26"点击切换太麻烦，改成鼠标拖动条"）：面板项带 slider = { drag = fn(比例), commit = fn(比例) }。
-- 按住那一行左右拖：整行宽度 = 最小值 … 最大值，拖的时候 drag 改显示，松手 commit。
-- 鼠标位置用 WidgetLayoutLibrary:GetMousePositionOnViewport（Slate 单位，PBZ_MC 实测鼠标坐标能读到；按钮的
-- GetCachedGeometry 读出来全是 0、不能用）；面板水平居中、宽 GUI.sizeW → 行的左右边按视口宽算。读不到就返回 nil（只剩 ± 按钮）
SLIDER = { off = false }
function SLIDER.frac()
    if SLIDER.off then return nil end
    local ok, r = pcall(function()
        local wll = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        if not valid(wll) then error("找不到 WidgetLayoutLibrary") end
        local pc = getP1PC()
        local m = wll:GetMousePositionOnViewport(pc)
        local size, scale = wll:GetViewportSize(pc), wll:GetViewportScale(pc)
        if not (m and size and type(scale) == "number" and scale > 0) then error("读不到视口") end
        local vw, w = size.X / scale, GUI.sizeW or UI.GUI_W or 640
        local left = (vw - w) / 2
        if not SLIDER.logged then
            SLIDER.logged = true
            out("§456 拖动条：鼠标 %.0f，视口宽 %.0f（缩放 %.2f），面板 %.0f–%.0f", m.X, vw, scale, left, left + w)
        end
        return math.max(0, math.min(1, (m.X - left) / w))
    end)
    if not ok then SLIDER.off = true; out("!! §456 拖动条读不到鼠标位置（%s），只能用加减按钮", tostring(r)); return nil end
    return r
end

-- 每 33ms 一次：按 NETUI.view 摆内容、查点击。点了东西就执行并结束这一轮（内容下一轮按新状态重摆）
local function guiTick(v)
    if UI.guiTickBegin then UI.guiTickBegin() end     -- 11-14 快速点击：这一拍有没有左键钩子记到的按下
    local okP, paused = pcall(function() return G.menuOpen() end)     -- 11-26 游戏菜单真开着（UUU 相机 mod 的暂停不算）
    local vis = (okP and paused == true) and 1 or 4     -- 游戏菜单打开时藏起来（同屏幕文字）
    if GUI.shownVis ~= vis then
        -- v0.26.4 游戏暂停（菜单 / 切出窗口）回来时游戏会把输入模式改回去：重新放鼠标
        if vis == 4 and GUI.shownVis == 1 and NETUI.open then inputMode(NETUI.edit and true or false); GUI.lostAt = nil end
        GUI.shownVis = vis; GUI.w:SetVisibility(vis)
    end
    if vis == 1 then return end
    if not v.edit then GUI.mouseTick() end
    guiLabel(GUI.title, v.title or "", COL_LABEL)
    guiLabel(GUI.close, T("关闭", "CLOSE"), COL_WHITE)
    guiBg(GUI.close, GUI.close.hov and BG_HOVER or BG_ROW)
    if guiClicked(GUI.close) then netuiSetOpen(false, "点关闭"); return end
    if v.edit then
        guiLabel(GUI.status, v.prompt or "", COL_WHITE)
        guiVis(GUI.tabBox, 1)
        guiVis(GUI.navBox, 1)
        for _, r in ipairs(GUI.rows) do guiVis(r, 1) end
        guiVis(GUI.editBox, 0)
        guiLabel(GUI.ok, T("确定", "OK"), COL_WHITE)
        guiLabel(GUI.cancel, T("取消", "CANCEL"), COL_WHITE)
        guiBg(GUI.ok, GUI.ok.hov and BG_DOWN or BG_SEL)
        guiBg(GUI.cancel, GUI.cancel.hov and BG_HOVER or BG_ROW)
        guiLabel(GUI.hint, T("回车 确定   Esc 取消   Ctrl+V 粘贴", "ENTER OK   ESC CANCEL   CTRL+V PASTE"), COL_LABEL)
        if guiClicked(GUI.ok) then editCommit(); return end
        if guiClicked(GUI.cancel) then editEnd("点取消"); return end
        return
    end
    guiVis(GUI.editBox, 1)
    guiLabel(GUI.status, v.status or "", v.col or COL_GRAY)
    -- 11-15 房间列表页面板加宽（名字长的房间看得全），别的页回到原来的宽度；只在变了时设
    local wantW = v.rooms and UI.GUI_W_ROOMS or UI.GUI_W
    if GUI.size and wantW and GUI.sizeW ~= wantW then
        GUI.sizeW = wantW
        pcall(function() GUI.size:SetMinDesiredWidth(wantW) end)
    end
    -- §141.14 "只观战"开着：点没满的房间也是观战，主机不认观战的不加入（联机程序判断）
    guiLabel(GUI.hint, v.rooms and v.noq and T("开着「只观战」：点房间 = 观战，不能观战的不加入   Esc / Home 关闭",
                                               "WATCH-ONLY IS ON: CLICK A ROOM TO WATCH IT   ESC / HOME CLOSES")
                               or v.rooms and T("点房间直接加入；房间每 2 秒自动刷新   Esc / Home 关闭",
                                     "CLICK A ROOM TO JOIN; REFRESHES EVERY 2 S   ESC / HOME CLOSES")
                               or v.hint and T(v.hint[1], v.hint[2])     -- 注册页自己的提示（head 的 extra.hint；排位的排行榜 / 统计 / 规则页）
                               or v.priv and T("翻页看完；最后一页可以撤回全部同意   Esc / Home 关闭",
                                               "PAGE THROUGH; THE LAST PAGE CAN WITHDRAW ALL CONSENT   ESC / HOME CLOSES")
                               or T("鼠标点选；也可以 PgUp/PgDn 选、End 确定   Esc / Home 关闭",
                                    "CLICK TO CHOOSE; OR PGUP/PGDN + END   ESC / HOME CLOSES"), COL_LABEL)
    local items = v.items or {}
    -- 房间列表页 / §110 排行榜页 / 统计页：上一页 / 下一页 / 返回 放进底下的翻页栏，不占行；没有的那个按钮变灰、点不了
    local paged = v.rooms or v.priv or v.paged     -- 注册页经 head 的 extra.paged 说明自己有翻页栏
    guiVis(GUI.navBox, paged and 4 or 1)
    if paged then
        local nav = {}
        for i, it in ipairs(items) do if it.nav then nav[it.nav] = { it = it, i = i } end end
        guiLabel(GUI.pageNo, string.format(T("第 %d / %d 页", "PAGE %d / %d"), v.roomPage or 1, v.pages or 1), COL_WHITE)
        -- 11-18 房间列表：进入方式做成翻页栏里的小按钮（上场 / 只观战）
        if GUI.enterMode then
            guiVis(GUI.enterMode, v.rooms and 0 or 1)
            if v.rooms then
                local w = NETUI.roomWatch == true
                guiLabel(GUI.enterMode, w and T("进入方式：只观战", "ENTER: SPECTATE") or T("进入方式：上场", "ENTER: PLAY"), COL_WHITE)
                guiBg(GUI.enterMode, GUI.enterMode.hov and BG_HOVER or BG_ROW)
                if guiClicked(GUI.enterMode) then
                    NETUI.roomWatch = not w
                    netuiCmd("specq", "on=" .. (w and "0" or "1") .. "\n")
                    netuiFlash(w and T("进入方式：上场", "ENTER AS: PLAY") or T("进入方式：只观战", "ENTER AS: SPECTATE"))
                    return
                end
            end
        end
        for _, k in ipairs({ "prev", "next", "filter", "back" }) do
            local p, n = GUI[k], nav[k]
            if p then
                local it = n and n.it
                local live = it and it.act     -- §91.1 等回话时翻页栏也点不了（以前照样能点，调到空的 act 会崩）
                local text = k == "prev" and T("上一页", "PREV") or k == "next" and T("下一页", "NEXT") or k == "back" and T("返回", "BACK") or (it and it.label or "")
                guiVis(p, (live or (k == "filter" and it)) and 0 or (k == "filter" and 1 or 3))
                guiLabel(p, text, live and COL_WHITE or COL_GRAY)
                if live then
                    local clicked = guiClicked(p)
                    if p.entered then NETUI.sel = n.i; NETUI.selTarget = nil end
                    guiBg(p, (p.down and BG_DOWN) or (n.i == NETUI.sel and BG_SEL) or (p.hov and BG_HOVER) or BG_ROW)
                    if clicked then out("联机面板：点击「%s」", it.label); it.act(); return end
                else
                    guiBg(p, it and BG_OFF or BG_NONE)
                end
            end
        end
    end
    -- 连接方式那一行画成一排标签页；§110 统计页的种类行（it.tabs）借同一排标签页画（两者不在同一页）
    local modeAt, tabsAt
    for i, it in ipairs(items) do if it.mode then modeAt = i elseif it.tabs then tabsAt = i end end
    guiVis(GUI.tabBox, (modeAt or tabsAt) and 4 or 1)
    if tabsAt and not modeAt then
        local kt = items[tabsAt].tabs
        for i, t in ipairs(GUI.tabs) do
            local k = kt[i]
            if not k then guiVis(t, 1)
            else
                guiVis(t, 0)
                guiLabel(t, k.label, k.cur and COL_WHITE or COL_GRAY)
                guiBg(t, (k.cur and BG_SEL) or (v.busy and BG_OFF) or (t.down and BG_DOWN) or (t.hov and BG_HOVER) or BG_ROW)
                if guiClicked(t) and not k.cur and not v.busy then
                    out("联机面板：点统计种类「%s」", k.label)
                    k.act()
                    return
                end
            end
        end
    end
    if modeAt then
        local onFriends = NETUI.page == "bfriends"
        for _, t in ipairs(GUI.tabs) do
            local fr = t.mode == "friends"     -- 11-15 好友标签：不是连接方式，点了换到好友页（NETUI.pickTab）
            if fr and not NETUI.friendsTab(NETUI.lobby) or not fr and not NETUI.hasMode(t.mode) then guiVis(t, 1)     -- §98 联机程序没有这种方式：标签藏起；好友标签要桥在
            else
                guiVis(t, 0)
                local cur = fr and onFriends or not fr and not onFriends and t.mode == v.mode
                guiLabel(t, fr and NETUI.friendsName() or UI.svc(T(GUI_TAB[t.mode][1], GUI_TAB[t.mode][2])), cur and COL_WHITE or COL_GRAY)
                guiBg(t, (cur and BG_SEL) or (v.busy and BG_OFF) or (t.down and BG_DOWN) or (t.hov and BG_HOVER) or BG_ROW)
                if guiClicked(t) and not cur and not v.busy then
                    out("联机面板：点连接方式「%s」", t.mode)
                    NETUI.sel = fr and 1 or modeAt
                    NETUI.pickTab(t.mode)
                    return
                end
            end
        end
    end
    -- 11-16 项目比面板行多（房间设置页展开"战斗规则"后超过 17 行，后面几项直接看不到）：滚动窗口。
    -- 顶 / 底各留一行写"上面 / 下面还有 N 项"，点了翻一屏；键盘 / 鼠标选中的项一直在窗口里；刚展开一类时尽量整类露出来
    local nRows, nItems = #GUI.rows, #items
    local off, body = 0, nRows
    if not paged and not modeAt and not tabsAt and nItems > nRows then
        body = nRows - 2
        if GUI.scrollPage ~= NETUI.page then GUI.scrollPage, GUI.scrollOff, GUI.scrollSel = NETUI.page, 0, nil end
        off = GUI.scrollOff or 0
        local function show(k) if k then if k <= off then off = k - 1 elseif k > off + body then off = k - body end end end
        if NETUI.roomShowTo then show(NETUI.roomShowTo); NETUI.roomShowTo = nil; GUI.scrollSel = nil end
        if GUI.scrollSel ~= NETUI.sel then show(NETUI.sel); GUI.scrollSel = NETUI.sel end     -- 只在选中项变了时拉（不然点"下面还有"翻过去又被拉回）
        off = math.max(0, math.min(off, nItems - body))
        GUI.scrollOff = off
    else
        GUI.scrollPage, GUI.scrollOff, GUI.scrollSel = nil, 0, nil
    end
    for ri, r in ipairs(GUI.rows) do
        local scrolled = body < nRows
        local i = scrolled and (off + ri - 1) or ri
        local it = items[i]
        -- 11-19 用户："分割线要居中"：分隔行在按钮里居中，普通行仍靠左（只改对齐，不动坐标）
        local wantJ = (it and it.sep) and 2 or 1
        if r.s and r.just ~= wantJ then r.just = wantJ; pcall(function() r.s:SetHorizontalAlignment(wantJ) end) end
        if scrolled and (ri == 1 or ri == nRows) then
            local up = ri == 1
            local more = up and off or (nItems - off - body)
            if more <= 0 then guiVis(r, 1)
            else
                guiVis(r, 0)
                guiLabel(r, up and string.format(T("▲ 上面还有 %d 项（点这里往上翻）", "▲ %d MORE ABOVE (CLICK TO SCROLL UP)"), more)
                               or string.format(T("▼ 下面还有 %d 项（点这里往下翻）", "▼ %d MORE BELOW (CLICK TO SCROLL DOWN)"), more), COL_LABEL)
                guiBg(r, (r.down and BG_DOWN) or (r.hov and BG_HOVER) or BG_ROW)
                if guiClicked(r) then
                    GUI.scrollOff = up and math.max(0, off - body) or math.min(nItems - body, off + body)
                    return
                end
            end
        elseif not it or it.mode or it.nav or it.tabs then
            guiVis(r, 1)
        else
            guiVis(r, it.act and 0 or 3)
            if it.act then
                guiLabel(r, it.label, UI.netuiItemCol(it) or COL_WHITE)     -- 11-18 结束 / 退出类按钮红字（其余照旧白）
                local clicked = guiClicked(r)
                if r.entered then NETUI.sel = i; NETUI.selTarget = nil end    -- 鼠标移上去 = 选中（键盘接着从这里走）
                guiBg(r, (r.down and BG_DOWN) or (i == NETUI.sel and BG_SEL) or (r.hov and BG_HOVER) or BG_ROW)
                if it.slider then                                              -- §456 拖动条：按住拖改显示、松手生效
                    local f = (r.down or clicked) and SLIDER.frac() or nil
                    if f and r.down and it.slider.drag then it.slider.drag(f) end
                    if clicked then
                        NETUI.sel = i
                        if f and it.slider.commit then out("联机面板：拖动条「%s」松手（%.2f）", it.label, f); it.slider.commit(f) end
                        return
                    end
                end
                if clicked then
                    out("联机面板：点击「%s」", it.label)
                    NETUI.sel = i
                    it.act()
                    return
                end
            else
                guiLabel(r, it.label, it.col or COL_GRAY)     -- §110 说明行可以带颜色（排行榜的盟主行、错误提示）
                guiBg(r, it.off and BG_OFF or BG_NONE)
            end
        end
    end
end

-- 面板开着时每 33ms：鼠标面板画出来了返回 true（屏幕文字那边就不画面板了）
local function guiShow()
    if GUI.failed or HUD.failed or not NETUI.view then return false end
    if not guiRoot() then return false end
    local ok, err = pcall(guiTick, NETUI.view)
    if not ok then
        GUI.failed, GUI.on = true, false
        out("!! 鼠标面板出错：%s，改用文字面板", tostring(err))
        pcall(function() GUI.w:RemoveFromParent() end)
        if NETUI.box and NETUI.box.gui then editEnd("鼠标面板出错"); NETUI.box = nil end
        inputMode(false)
        return false
    end
    return true
end

-- 两处调用（对局外 / 对局中）：面板的屏幕文字；鼠标面板画出来了就只留空表（屏幕文字收起面板）
local function netuiPanel(tn)
    local rows = netuiRows(tn)
    if guiShow() then return {} end
    return rows
end

-- 按键入口（M4.netui）：toggle / up / down / left / right / ok / enter / esc；autostart = 模组加载时调一次
local function netuiKey(what)
    local tn = now()
    if what == "autostart" then netuiEnsure("模组加载", tn); return end
    if what == "toggle" then netuiSetOpen(not NETUI.open, "Home"); return end
    -- 用户 2026-11-08：P 也开 / 关面板；输入框里 P 是要打的字母，跳过
    if what == "ptoggle" then if not NETUI.edit then netuiSetOpen(not NETUI.open, "P") end; return end
    -- 回车 / Esc 只给输入框用（不在输入时什么都不做：回车、Esc 是游戏自己的键）
    if NETUI.edit then
        if what == "enter" then editCommit() elseif what == "esc" then editEnd("Esc") end
        return
    end
    -- §141 观战中、面板关着：PgDn / PgUp 换下一个 / 上一个视角（用户 2026-11-07："有些人没小键盘"）。L3：问一圈，谁接了谁用
    if not NETUI.open and BASEHOOK.ask("base.navKey", what) then return end
    if not NETUI.open then return end
    -- 鼠标面板开着时游戏收不到 Esc（UIOnly），Esc 关面板；文字面板时 Esc 是游戏的菜单键，不管
    if what == "esc" then if GUI.on then netuiSetOpen(false, "Esc") end; return end
    NETUI.roomsFresh = nil        -- 自己动过光标：不再自动跳到第一个房间
    NETUI.selTarget = nil         -- 自己动了光标：下一帧按新位置重新记（不然刷新时会被拉回原来那个房间）
    local it = NETUI.items[NETUI.sel]
    if (what == "up" or what == "down") and NETUI.page == "rooms" and it and it.room then
        -- 房间列表页：在本页第一个房间再往上 = 上一页（顶部无筛选行时），最后一个房间再往下 = 下一页（选中第一个房间）
        local firstRoom, lastRoom = 0, 0
        for i, x in ipairs(NETUI.items) do
            if x.room then if firstRoom == 0 then firstRoom = i end; lastRoom = i end
        end
        local _, allRooms = netuiTargets(NETUI.lobby)
        local rooms = (NETUI.filterRooms and NETUI.filterRooms(allRooms)) or allRooms
        if what == "down" and NETUI.sel == lastRoom and (NETUI.roomPage or 1) < roomPages(rooms) then
            NETUI.roomPage, NETUI.sel = NETUI.roomPage + 1, firstRoom
            return
        elseif what == "up" and NETUI.sel == firstRoom and (NETUI.roomPage or 1) > 1 then
            NETUI.roomPage, NETUI.sel = NETUI.roomPage - 1, firstRoom + perPage() - 1     -- 上一页是满页：选它最后一个房间（顶上有筛选行时序号顺移）
            return
        end
    end
    if what == "up" or what == "down" then
        local d, n = what == "up" and -1 or 1, #NETUI.items
        for _ = 1, n do                     -- 跳过说明行
            NETUI.sel = (NETUI.sel - 1 + d) % math.max(n, 1) + 1
            if NETUI.items[NETUI.sel] and NETUI.items[NETUI.sel].act then break end
        end
    elseif (what == "left" or what == "right") and it and it.mode then
        NETUI.step(what == "left" and -1 or 1)
    elseif what == "ok" and it and it.act then
        out("联机面板：确定「%s」", it.label)
        it.act()
    end
end

-- 面板关着、对手也没连上时：当主机在等 / 客机在连，给一行小提示（不然看不出联机程序在干什么）
local function netuiIdleRows(tn)
    local lb = netuiRead(tn)
    if not lobbyAlive(lb) or (lb.role or "none") == "none" or lb.connected == "1" then return nil end
    local st, col = netuiStatus(lb, tn)
    return { { c = st, col = col, size = 0.7, side = true }, { c = T("[Home] 联机面板", "[HOME] ONLINE PANEL"), col = COL_LABEL, size = 0.55, side = true } }     -- §310 常驻状态放右侧
end

-- 对局外的提示：先放一次性提示（弃权 / 掉线），再是地图不一致，再是准备面板（用户定：两行，NOT READY 红、READY 绿）
local function idleRows(tn)
    local extra = FMATCH.rowsOf("idle", tn)     -- 规则来源 / 扩展的一次性提示（排位结算：一般在"胜利 / 败北"画面那几秒里到，回到自由活动时显示）
    if #extra > 0 then MATCH.toast = { rows = extra, till = tn + 6.0 } end
    if MATCH.toast then
        if tn < MATCH.toast.till then return MATCH.toast.rows end
        MATCH.toast = nil
    end
    -- §141 观战者：主机在别的地图时显示"前往主机所在地图"的提示
    if sessionRole() == "spec" and NET.since() < 1.0 and NET.rmap and NET.rmap ~= "" and NET.rmap ~= mapName(getP1()) then return MAPGO.rows(tn) end     -- §276.12
    if now() - NET.lastRecvAt >= 1.0 then return nil end
    if PP.on then return PP.rows() end     -- 只在我们的对手连着时提示（只玩 Phantom Pact 的人不受打扰）
    if NET.rmap and NET.rmap ~= "" and NET.rmap ~= mapName(getP1()) then return MAPGO.rows(tn) end   -- v0.24.1 切图提示（MAPGO 段）；§276.12 空 = 不知道
    if MAPGO.far and sessionRole() == "client" and not MATCH.role then         -- §156 同地图离得远
        local d = MAPGO.dist(getP1())
        local sub = (MAPGO.farArmAt and os.time() - MAPGO.farArmAt <= MAPGO_ARM_SEC)
            and T("再按一次 F1 确认", "PRESS F1 AGAIN TO CONFIRM") or T("按 F1 传送到主机身边", "F1: TELEPORT TO THE HOST")
        return { { c = string.format(T("离主机 %s 米", "%s M FROM THE HOST"), d and string.format("%.0f", d) or "?"), col = COL_ORANGE, size = 1.3 },
                 { c = sub, col = COL_LABEL } }
    end
    local function readyOf(b) return b and T("已准备", "READY") or T("未准备", "NOT READY"), b and COL_GREEN or COL_RED end
    local s1, c1 = readyOf(MATCH.ready)
    local s2, c2 = readyOf((NET.rrdy or 0) == 1)
    -- v0.14.2：标签右对齐到中线，长标签会把整行推出屏幕左边（用户截图）→ 标签只留 YOU / OPPONENT，操作提示单独一行居中
    -- v0.15.0：场地以主机为准，所以 F5 提示只给主机看
    local hint = (sessionRole() == "host" or NET.actHost()) and T("按 F1 准备      按 F2 把这里设为场地", "F1: READY      F2: SET ARENA HERE")
                                          or T("按 F1 准备", "PRESS F1 TO READY")
    -- §310 准备状态是常驻信息：放右侧
    local rows = { { l = T("我方：", "YOU:"), v = s1, col = c1, side = true }, { l = T("对方：", "OPPONENT:"), v = s2, col = c2, side = true },
                   { c = hint, col = COL_LABEL, size = 0.75, side = true } }
    -- v0.25.0 版本不一致只提示、不拦（用户定）：写出对方当前版本（av= 是 v0.22.0 起才有的，没有 = 更旧）
    if NET.rav and NET.rav ~= VERSION then
        local them = NET.rav ~= "" and ("v" .. NET.rav) or T("v0.21 或更旧", "v0.21 OR OLDER")
        rows[#rows + 1] = { c = string.format(T("版本不一致：你 v%s，对方 %s", "VERSION MISMATCH: YOU v%s, OPPONENT %s"), VERSION, them),
                            col = COL_ORANGE, size = 0.6, side = true }
    end
    for _, r in ipairs(DSTAT and DSTAT.hudRows(tn) or {}) do rows[#rows + 1] = r end     -- §342 木桩 DPS（对局外也打得了）
    return rows
end

-- §85 AI 对战时开着的房间有真人进来（netRecv 看到对手的包不再带 ai=1，aiSwap = "real"）/ 真人离开后联机程序重开了 AI
-- （包里又有 ai=1 且带 aiback=，aiSwap = "ai"）：结束当前那局（对局外也弹提示），藏起旧对手的替身——lobbyStep 马上按新对手的
-- 装备 / 昵称重新生成；准备状态清掉，重新按 F1
local function aiSwapStep(p1, tn)
    local kind = NET.aiSwap
    if not kind then return end
    NET.aiSwap = nil
    local why = kind == "real" and "真人玩家加入" or "真人玩家离开"
    if kind == "real" and NET.swapAsClient then out("== 你加入了 %s 的房间，AI 对战已关闭 ==", tostring(NET.swapName or "对方"))
    elseif kind == "real" then out("== %s 加入了你的房间，AI 对战已关闭 ==", tostring(NET.swapName or "真人玩家"))
    else out("== %s 已离开房间，AI 对战已重新开始 ==", tostring(NET.swapName or "对方")) end
    if MATCH.role then
        enter(p1, "idle", tn, why)
    else
        MATCH.ready = false
        MATCH.uiSync("对手断开")                     -- §260
        MATCH.toast = { rows = TOAST_OF[why](), till = tn + TOAST_SEC }
    end
    if MATCH.autoPup and valid(puppet()) and MATCH.autoRemove then
        MATCH.autoRemove()
        MATCH.autoPup, MATCH.joined = nil, nil
    end
end

local function matchStep(p1, tn)
    langPoll(tn)
    NETUI.watchPipe(tn)
    PP.poll()
    holdStep(tn)
    aiSwapStep(p1, tn)
    if TRAINCTX and TRAINCTX.restartAt then
        if not (NET.rdummy and NET.rtrainHpRegen == false and TRAINING.allowed()) then
            TRAINCTX.restartAt = nil
        elseif not MATCH.role and tn >= TRAINCTX.restartAt and tn - NET.lastRecvAt < 1 then
            TRAINCTX.restartAt = nil
            startMatchNow()
        end
    end
    local lost = tn - NET.lastRecvAt
    lobbyStep(p1, tn, lost)
    if MATCH.role == "client" then
        FMATCH.clientStep(p1, tn, lost, FMATCH.stepDeps)      -- F4a：状态机在 fornet_match.lua（掉线 / 跟随主机）
    elseif MATCH.role == "host" then
        if sessionRole() == "client" and not NET.actHost() and lost < 1.0 then
            enter(p1, "idle", tn, "主机回来打了")     -- §276 代主机开的局：主机回来（包里没 rly=h 了）就结束，听主机的
        else
            FMATCH.hostStep(p1, tn, lost, FMATCH.stepDeps)    -- F4a：cd → fight → rend → cd / end → idle，比分、时间到
        end
    elseif lost < 1.0 and not PP.on and sessionRole() ~= "host" then
        -- 只跟随新鲜的包：掉线后 NET.rmt 还留着对方最后一包，不判新鲜会"加入→掉线→再加入"来回跳（离线测试抓到）
        -- §276.11（移植 0.33 分支 §269.14）主机不跟随：以前客机的 mt= 永远是空的，主机跟了也没事；§276.2 起第一位会代主机开局、发 mt=，
        -- 0.33 11-13 双开实测主机交手中"回来打"，真主机同一秒把第一位的局当成"对方发起了对局"跟进去（清状态、改回合资源），再"主机结束了对局"退出。
        -- 解说模式（§236）的真主机也是 host、在观战，本来就不该跟进对局；第一位（matchhost=1）自己开局，也不跟第二位
        followHost(p1, tn)
    end

    if not MATCH.role then
        -- v0.10.1 实测：对局结束、锁血解除后幽灵继续追打，23:24:40 把玩家真打死（血量 23.5 → 0），之后一直没复活
        -- v0.17.10（2026-11-04 16:41 实测）：锁血 GE_LockHealth 在身上时 Esc 菜单打不开（Phantom Pact eval 只去掉锁血、
        -- 替身留着 → 菜单马上能开）。现在替身只在对局中敌对（syncFaction），对局外打不到人，对局外的陪练锁血关掉（LO.IDLE_LOCK）
        if LO.IDLE_LOCK and lost < 1.0 and valid(puppet()) and (hpOf(p1) or 0) > 0 then
            if (not MATCH.lock or MATCH.lockFor ~= pathOf(p1)) and tn >= (MATCH.lockRetryAt or 0) then
                out("对手已连接：进入陪练保护（锁血，不会真死）")
                if not lockSelf(p1) then MATCH.lockRetryAt = tn + 10.0 end
            end
            local hp = hpOf(p1)
            if MATCH.lock and hp and hp <= DEAD_HP then
                out("陪练中被打倒（血量 %.2f），补满", hp)
                refill(p1)
            end
        elseif MATCH.lock and (not LO.IDLE_LOCK or lost > LOST_SEC or not valid(puppet())) and not BASEHOOK.otherScene()
               and not (BASEHOOK.mp and (BASEHOOK.mp.on or BASEHOOK.mp.netp.on)) then   -- §141 观战时留着自己的锁血；混战原型 / 多人联机同样
            unlockSelf(p1, not LO.IDLE_LOCK and "对局外不锁血" or (valid(puppet()) and "对手断开" or "替身已移除"))
        end
    end

    if not MATCH.role then
        -- net-ui：联机面板开着时盖过准备提示（面板内容不写【提示】日志，操作另有日志）
        local panel = NETUI.open and netuiPanel(tn) or nil
        local rows = panel or NET.mpHudRows(tn) or idleRows(tn) or netuiIdleRows(tn)
        if rows and not valid(MATCH.text) then textActor(p1) end
        local tx = panel and MATCH.lastIdleTx or hudLog(rows)
        if tx ~= MATCH.lastIdleTx then
            MATCH.lastIdleTx = tx
            if tx then out("【提示】%s", tx) end
        end
        showHud(UIM.rows(rows, panel))      -- §314 界面三态：1 / 2 档只留面板（提示照样记日志）
        placeText()
        -- 11-17 排查补齐：新版房间（多人 / 对决）交手中也把子弹时间放慢的全局时间强制回 1.0（同下面旧版 1v1 那段）
        if NET.fighting() and ST.ticks % 5 == 0 then
            local okD, d = pcall(function() return gstat():GetGlobalTimeDilation(p1) end)
            if okD and type(d) == "number" and math.abs(d - 1.0) > 0.01 then
                pcall(function() gstat():SetGlobalTimeDilation(p1, 1.0) end)
                MATCH.dilFix = (MATCH.dilFix or 0) + 1
                if MATCH.dilFix <= 5 then out("房间交手中全局时间被放慢到 %.2f（子弹时间？），已恢复 1.0 #%d", d, MATCH.dilFix) end
            end
        end
    end

    if MATCH.role then
        if MATCH.state == "cd" and ST.ticks % 3 == 0 then refill(p1) end
        if MATCH.state == "fight" then
            local hp = hpOf(p1)
            -- §165 测试用：net 目录里有 nodeath.on 就不让自己倒下（血低于一半回满），采招式数据时一回合打到底
            if NET.noDeath == nil then local f = io.open(NET_DIR .. "/nodeath.on", "r"); NET.noDeath = f ~= nil; if f then f:close() end end
            if NET.noDeath and hp then
                local mx = attrOf(p1, "Health_Max")
                if mx and hp < mx * 0.5 then
                    setAttr(p1, "Health", mx)
                    -- 判定按"回过血"截断多段累加（§155）；测试补的血不算，不然多段招后几段都记不进回报（§165.5）
                    if NET.judgeHp then NET.judgeHp = mx end
                    out("测试不死：血量 %.0f → %.0f（nodeath.on）", hp, mx)
                    hp, MATCH.fightHp = mx, mx
                end
            end
            RT.track(hp)          -- §173 本回合受到的伤害（时间到时比）
            local regen = hp and hp > DEAD_HP and MATCH.fightHp and hp ~= MATCH.fightHp and savedByBreakRegen(p1, hp, tn)
            if hp and (hp <= DEAD_HP or regen) and MATCH.dead ~= MATCH.round and not (TRAINING and TRAINING.infinite("hp")) then
                MATCH.dead = MATCH.round
                if regen then
                    out("◆ 我在第 %d 回合倒下（血量 %.2f -> %.2f：致命一刀同时破防，慈母护符补回的血不算）",
                        MATCH.round, MATCH.fightHp, hp)
                else
                    out("◆ 我在第 %d 回合倒下（血量 %.2f，被锁血钳住，没有真死）", MATCH.round, hp)
                end
                fallDown(p1, "我")
            end
            MATCH.fightHp = hp
            -- 完美闪避的子弹时间会放慢全局时间，两边时钟就对不上了：对局中强制 1.0
            if ST.ticks % 5 == 0 then
                local okD, d = pcall(function() return gstat():GetGlobalTimeDilation(p1) end)
                if okD and type(d) == "number" and math.abs(d - 1.0) > 0.01 then
                    pcall(function() gstat():SetGlobalTimeDilation(p1, 1.0) end)
                    MATCH.dilFix = (MATCH.dilFix or 0) + 1
                    if MATCH.dilFix <= 5 then out("全局时间被放慢到 %.2f（子弹时间？），已恢复 1.0 #%d", d, MATCH.dilFix) end
                end
            end
        end
        if NET.rdead == MATCH.round and MATCH.round > 0 and MATCH.pupFell ~= MATCH.round
            and (MATCH.state == "fight" or MATCH.state == "rend") then
            MATCH.pupFell = MATCH.round
            out("◆ 对方在第 %d 回合倒下", MATCH.round)
            fallDown(puppet(), "对方")
        end
        -- v0.10.0 进倒计时同一秒崩过一次；v0.10.1 的 F2 测试里文字的每一步都成功（5 次），那次崩溃原因未定。
        -- 文字变化照样写日志，崩了能对上
        local panel = NETUI.open and netuiPanel(tn) or nil
        local rows = panel or PP.warnRows() or matchRows(tn)
        if rows and not valid(MATCH.text) then textActor(p1) end
        local tx = panel and MATCH.lastTx or hudLog(rows)
        if tx ~= MATCH.lastTx then
            MATCH.lastTx = tx
            if tx then out("【提示】%s", tx) end
        end
        showHud(UIM.rows(rows, panel))      -- §314
        placeText()
    end
    syncFaction(false)
    wireUpdate()
end

-- F4a：状态机（matchStep 的主机 / 客机分支）在 fornet_match.lua；这里只给游戏那边的回调（建一次，不每帧造闭包）
FMATCH.stepDeps = {
    enter = function(p1, st, tn, why) enter(p1, st, tn, why) end,
    peerDead = function() return NET.rdead == MATCH.round end,
    timeUp = function(tn)
        if NET.rdummy then return nil end                        -- §342 木桩不按时限判负（中途从别的难度换成木桩时）
        local tw = RT.check(tn)       -- §173 时间到：受伤多的判负
        if tw then REL.send("rtime", string.format("%d %d %.0f %.0f", MATCH.id, MATCH.round, RT.info.h, RT.info.c)) end
        return tw
    end,
    matchOver = function(won) BASEHOOK.emit("base.matchOver", won, sessionRole()) end,     -- L3：观战 mod 订阅（§141.7 打完换人；§276 代主机开的不管排队）
    lostWhy = function() return REL.ended[MATCH.id] and REL.endWhy() or "对方掉线" end,
    follow = function(p1, tn) return followHost(p1, tn) end }

-- F5：把你现在站的位置和朝向存成 PvP 场地中心。之后发起对局都用它：主机在中心后方 SPAWN_D、客机在前方 SPAWN_D，面对面
local function saveArena()
    local p1 = getP1()
    if not valid(p1) then out("!! 没有玩家1"); return end
    local loc = try("sa loc", function() return p1:K2_GetActorLocation() end)
    local rot = try("sa rot", function() return p1:K2_GetActorRotation() end)
    if not (loc and rot) then return end
    local m = mapName(p1)
    -- §238 先找两个开战点：放不下就不存（射线用不了时照以前存，只是没有点位）
    local sp, why = ARN.check(p1, loc.X, loc.Y, loc.Z, rot.Yaw)
    if not sp and not (why and why.noTrace) then
        out("!! 场地没存：放不下两个开战点（%s），换个开阔平整的地方再按 F2", tostring(why and why[1]))
        MATCH.toast = { rows = { { c = T("这里不能当场地", "CAN'T USE THIS SPOT"), col = COL_RED, size = 1.4 },
                                 { c = T(why and why[1] or "", why and why[2] or ""), col = COL_ORANGE, size = 0.8 },
                                 { c = T("换个开阔平整的地方再按 F2", "FIND A FLAT OPEN SPOT AND PRESS F2 AGAIN"), col = COL_GRAY, size = 0.75 } },
                        till = now() + 4.0 }
        return
    end
    fileWrite(ARENA_FILE, string.format("map=%s\nx=%.1f\ny=%.1f\nz=%.1f\nyaw=%.1f\nsp=%s\n", m, loc.X, loc.Y, loc.Z, rot.Yaw, ARN.encode(sp)))
    ARN.saved, ARN.mine = nil, true                          -- 重读、马上标出来
    ARN.refresh(p1, "F2 存场地")
    out("== 场地已保存：地图 %s，中心 (%.0f, %.0f, %.0f)，朝向 %.0f。%s ==", m, loc.X, loc.Y, loc.Z, rot.Yaw,
        sp and string.format("开战点：主机（蓝）在你身后 %.0f 米、客机（橙）在你前方 %.0f 米，都检查过不卡墙", sp.d / 100.0, sp.d / 100.0)
            or ("射线用不了，没有检查开战点（" .. tostring(why and why[1]) .. "），按以前两侧各 5 米"))
    -- v0.15.0（用户："按 F5 选择场地要不要也在这里写一份"）：屏幕上确认一下
    if not MATCH.role then
        local sub = sp and (sp.d < ARN.STEPS[1] and string.format(T("地方不够大，两人相距缩到 %.0f 米", "SPACE IS TIGHT: %.0f M APART"), sp.d * 2 / 100.0)
                or T("蓝光 = 主机开战点，橙光 = 客机开战点", "BLUE = HOST SPOT, ORANGE = GUEST SPOT"))
            or T("对局时双方在这里两侧出生", "BOTH PLAYERS SPAWN HERE")
        MATCH.toast = { rows = { { c = T("场地已保存", "ARENA SAVED"), col = COL_GREEN, size = 1.4 },
                                 { c = sub, col = COL_LABEL, size = 0.75 } },
                        till = now() + 3.0 }
    end
end

-- F2：药瓶探针（只读）。用户想要"每局开始药瓶补满"。药的次数不在属性集里（属性只有 UltimateCharge 之类）；
-- 存档里有 PotionCount=3、MedicineInfos.<药>.CurrentTime/MaxTime。找运行时存它们的组件 / 字段 / 补满函数
local MED_KW = { "Medicine", "Potion", "Hulu", "Gourd", "Heal", "Recover", "Refill", "Restore", "Bonfire", "Rest", "Drug" }
local function medWord(n)
    for _, k in ipairs(MED_KW) do if n:find(k) then return true end end
    return false
end

local function medProbe()
    out("========== 药瓶探针（只读）==========")
    local p1, pc = getP1(), getP1PC()
    if not valid(p1) then out("!! 没有玩家1"); return end
    PROBE.walkClass(p1, medWord, 40, 60, "[角色]")
    local okS, ps = pcall(function() return pc.PlayerState end)
    for _, e in ipairs({ { "控制器", pc }, { "PlayerState", okS and ps or nil } }) do
        if valid(e[2]) then PROBE.walkClass(e[2], medWord, 40, 60, "[" .. e[1] .. "]") end
    end
    -- 角色身上的全部组件：名字或类名带关键词的整个展开，其余只列名字
    local cls = StaticFindObject("/Script/Engine.ActorComponent")
    local okG, comps = pcall(function() return p1:K2_GetComponentsByClass(cls) end)
    out("[组件] K2_GetComponentsByClass %s", okG and "成功" or ("失败 " .. tostring(comps)))
    local names = {}
    if okG and comps then
        eachArr(comps, function(_, c)
            if valid(c) then
                local n = full(c)
                names[#names + 1] = shortName(n) or n
                if medWord(n) then PROBE.walkClass(c, nil, 60, 80, "[组件 " .. (shortName(n) or "?") .. "]") end
            end
        end)
    end
    out("[组件] 共 %d 个：%s", #names, table.concat(names, ", "))
    out("========== 药瓶探针结束 ==========")
end

-- F2：共享数据探针（只读，v0.15.1）。v0.15.0 实测（12:45:19）：玩家换武器，替身的武器被动同时没了；
-- 给替身装斩马刀，玩家身上也挂上了 GA_ZhanMa_Passive_C；用户反馈给对方上 debuff 自己也显示图标。
-- 替身 = 玩家同类角色，怀疑两者的武器 / 饰品 / buff 数据指向同一个对象。这里把两人（角色、全部组件、
-- 控制器、PlayerState）上所有对象引用读出来对比，报告：同一个组件实例、指向同一个运行时对象、互相指向对方
local SHARE_KW = { "Weapon", "Equip", "Accessor", "Buff", "Effect", "Inventory", "Talent", "Phantom", "Item",
                   "Status", "Medicine", "Skill", "Save", "Hud", "HUD", "UI" }
local function shareWord(n)
    for _, k in ipairs(SHARE_KW) do if n:find(k) then return true end end
    return false
end

-- 对象上所有 Object / Array<Object> 属性 → { [属性名] = { 完整名, ... } }。其余类型（Map/Set/Weak/结构体…）不读
local function objRefs(obj)
    local refs, n = {}, 0
    local okC, c = pcall(function() return obj:GetClass() end)
    c = okC and c or nil
    for _ = 1, 12 do
        if not valid(c) then break end
        local cname = shortName(full(c)) or "?"
        if cname == "Object" then break end
        pcall(function()
            c:ForEachProperty(function(p)
                local pn = "?"
                pcall(function() pn = p:GetFName():ToString() end)
                local t = PROBE.propType(p)
                local list = {}
                if t:match("^Object<") then
                    local v = rawProp(obj, pn)
                    if valid(v) then list[1] = full(v) end
                elseif t == "Array" then
                    local arr = rawProp(obj, pn)
                    if type(arr) == "userdata" and not valid(arr) then
                        eachArr(arr, function(i, e)
                            if i <= 50 and type(e) == "userdata" and valid(e) then list[#list + 1] = full(e) end
                        end)
                    end
                end
                if #list > 0 then refs[cname .. "." .. pn] = list; n = n + 1 end
            end)
        end)
        local okS, sup = pcall(function() return c:GetSuperStruct() end)
        c = okS and sup or nil
    end
    return refs, n
end

-- 一个角色的"来源对象"：角色本身、全部组件、控制器、PlayerState。key 用对象名（两人的组件同名可对齐）
local function shareSources(actor)
    local src, order = {}, {}
    local function add(key, o)
        if valid(o) and not src[key] then src[key] = o; order[#order + 1] = key end
    end
    add("<角色>", actor)
    local cls = StaticFindObject("/Script/Engine.ActorComponent")
    local okG, comps = pcall(function() return actor:K2_GetComponentsByClass(cls) end)
    if okG and comps then
        eachArr(comps, function(_, c)
            if valid(c) then add(shortName(full(c)) or full(c), c) end
        end)
    end
    local okP, ctl = pcall(function() return actor:GetController() end)
    add("<控制器>", okP and ctl or nil)
    add("<PlayerState>", rawProp(actor, "PlayerState"))
    return src, order
end

-- 运行时对象（关卡里 / 临时包 / GameInstance 下）才算"共享出问题"；资产（/Game/…、/PBZCombatAsset/… 的蓝图类、数据表、GE 类）本来就共用
local function runtimeObj(fullName)
    return (fullName:find("PersistentLevel", 1, true) or fullName:find("/Engine/Transient", 1, true)
        or fullName:find("GameInstance", 1, true)) ~= nil
end

local function shareProbe()
    out("========== 共享数据探针（只读）==========")
    local p1, pup = getP1(), puppet()
    if not valid(p1) then out("!! 没有玩家1"); return end
    if not valid(pup) then out("!! 没有替身：先按 F12 造替身（或进对局）再按探针键（默认不绑，见文件末尾）"); return end
    local p1Path, pupPath = pathOf(p1), pathOf(pup)
    out("玩家1 %s", full(p1))
    out("替身  %s", full(pup))
    local s1, o1 = shareSources(p1)
    local s2, o2 = shareSources(pup)
    out("[来源] 玩家1 %d 个：%s", #o1, table.concat(o1, ", "))
    out("[来源] 替身  %d 个：%s", #o2, table.concat(o2, ", "))

    local r1, r2 = {}, {}
    local nAsset, nBad = 0, 0
    -- 1) 同名来源是不是同一个实例；替身的来源是不是挂在玩家1下面（或反过来）
    for _, k in ipairs(o2) do
        local a, b = s1[k], s2[k]
        if a and sameObj(a, b) then nBad = nBad + 1; out("!! 同一个实例 [%s]：%s", k, full(b)) end
        local bp = pathOf(b)
        if k ~= "<角色>" and bp:sub(1, #p1Path + 1) == p1Path .. "." then
            nBad = nBad + 1; out("!! 替身的 [%s] 挂在玩家1下面：%s", k, full(b))
        end
    end
    for _, k in ipairs(o1) do
        local ap = pathOf(s1[k])
        if k ~= "<角色>" and ap:sub(1, #pupPath + 1) == pupPath .. "." then
            nBad = nBad + 1; out("!! 玩家1的 [%s] 挂在替身下面：%s", k, full(s1[k]))
        end
    end
    for _, k in ipairs(o1) do r1[k] = objRefs(s1[k]) end
    for _, k in ipairs(o2) do r2[k] = objRefs(s2[k]) end

    -- 2) 每个引用：互相指向对方 / 两人指向同一个运行时对象
    local function scan(refs, selfName, otherPath, otherName)
        for k, props in pairs(refs) do
            for pn, list in pairs(props) do
                for _, f in ipairs(list) do
                    local fp = f:match("^%S+ (.+)$") or f
                    if fp == otherPath or fp:sub(1, #otherPath + 1) == otherPath .. "." then
                        nBad = nBad + 1
                        out("!! %s 的 [%s] %s → 指向%s的 %s", selfName, k, pn, otherName, short(fp))
                    end
                end
            end
        end
    end
    scan(r2, "替身", p1Path, "玩家1")
    scan(r1, "玩家1", pupPath, "替身")
    for k, props in pairs(r2) do
        local other = r1[k]
        for pn, list in pairs(props) do
            local mine = other and other[pn]
            if mine then
                local set = {}
                for _, f in ipairs(mine) do set[f] = true end
                for _, f in ipairs(list) do
                    if set[f] then
                        if runtimeObj(f) then
                            nBad = nBad + 1
                            out("!! 共用运行时对象 [%s] %s = %s", k, pn, f)
                        else
                            nAsset = nAsset + 1
                        end
                    end
                end
            end
        end
    end

    -- 3) 和武器 / 饰品 / buff / 背包 / 界面相关的来源，两人的引用全列出来（人工对比用）
    for _, pair in ipairs({ { "玩家1", o1, r1 }, { "替身", o2, r2 } }) do
        for _, k in ipairs(pair[2]) do
            if k == "<角色>" or shareWord(k) then
                for pn, list in pairs(pair[3][k] or {}) do
                    if shareWord(pn) or shareWord(k) then
                        local s = {}
                        for i, f in ipairs(list) do if i <= 8 then s[#s + 1] = short(f) end end
                        out("  [%s %s] %s = %s%s", pair[1], k, pn, table.concat(s, " | "), #list > 8 and (" …共 " .. #list) or "")
                    end
                end
            end
        end
    end
    out("共享数据探针结果：可疑 %d 处，两人共用资产 %d 处（资产共用是正常的）", nBad, nAsset)
    out("========== 共享数据探针结束 ==========")
end

-- F2 第二版（v0.15.2）：换装互相影响实验。v0.15.1 探针：两人各有自己的 Character Weapons Component /
-- BP_UIGameplayLogicComponent 实例（不是同一个对象），所以共享在更深处。这里每按一次 F2 走一步：
--   1 快照 → 给替身装斩马刀；2 快照（看玩家1变没变）→ 给玩家1装双刃；3 快照（看替身变没变）→ 玩家1装回原武器
-- 快照 = 两人武器组件的简单字段 + 无参 Get/Is 函数结果 + 正在生效的技能（被动）
local SWAP = { step = 0 }

local function snapObj(obj)
    local s = {}
    local okC, c = pcall(function() return obj:GetClass() end)
    c = okC and c or nil
    for _ = 1, 6 do
        if not valid(c) then break end
        local cname = shortName(full(c)) or "?"
        if cname == "ActorComponent" or cname == "Object" then break end
        pcall(function()
            c:ForEachProperty(function(p)
                local n = "?"
                pcall(function() n = p:GetFName():ToString() end)
                local base = PROBE.propType(p):match("^(%w+)")
                if ({ Int = 1, Float = 1, Double = 1, Bool = 1, Byte = 1, Enum = 1, Name = 1, Str = 1, Object = 1 })[base] then
                    s["." .. n] = PROBE.fnameOrStr(rawProp(obj, n))
                elseif base == "Array" then
                    local items = {}
                    eachArr(rawProp(obj, n), function(i, e) if i <= 20 then items[#items + 1] = PROBE.fnameOrStr(e) end end)
                    s["." .. n] = "[" .. table.concat(items, ", ") .. "]"
                end
            end)
        end)
        pcall(function()
            c:ForEachFunction(function(f)
                local n = "?"
                pcall(function() n = f:GetFName():ToString() end)
                local sig = PROBE.signature(f)
                if #sig == 1 and sig[1].ret and (n:sub(1, 3) == "Get" or n:sub(1, 2) == "Is") then
                    local ok, r = pcall(function() return obj[n](obj) end)
                    if ok then s[n .. "()"] = PROBE.fnameOrStr(r) end
                end
            end)
        end)
        local okS, sup = pcall(function() return c:GetSuperStruct() end)
        c = okS and sup or nil
    end
    return s
end

local function swapSnap(tag)
    local snap = {}
    for _, e in ipairs({ { "玩家1", getP1() }, { "替身", puppet() } }) do
        local who, a = e[1], e[2]
        local t = {}
        if valid(a) then
            local wc = rawProp(a, "Character Weapons Component")
            if valid(wc) then for k, v in pairs(snapObj(wc)) do t["武器组件" .. k] = v end end
            local abs = activeAbilities(a) or {}
            local names = {}
            for n in pairs(abs) do names[#names + 1] = n end
            table.sort(names)
            t["生效技能"] = table.concat(names, " ")
        end
        snap[who] = t
    end
    out("[换装实验] 快照 %s：玩家1 %d 项，替身 %d 项", tag,
        (function() local n = 0 for _ in pairs(snap["玩家1"]) do n = n + 1 end return n end)(),
        (function() local n = 0 for _ in pairs(snap["替身"]) do n = n + 1 end return n end)())
    return snap
end

local function swapDiff(a, b, label)
    local n = 0
    for _, who in ipairs({ "玩家1", "替身" }) do
        local x, y = a[who] or {}, b[who] or {}
        local keys = {}
        for k in pairs(x) do keys[k] = true end
        for k in pairs(y) do keys[k] = true end
        local sorted = {}
        for k in pairs(keys) do sorted[#sorted + 1] = k end
        table.sort(sorted)
        for _, k in ipairs(sorted) do
            if x[k] ~= y[k] then
                n = n + 1
                out("  [%s] %s %s：%s  →  %s", label, who, k, tostring(x[k]), tostring(y[k]))
            end
        end
    end
    out("  [%s] 共 %d 处变化", label, n)
end

local function swapTest()
    local p1, pup = getP1(), puppet()
    if not (valid(p1) and valid(pup)) then out("!! 换装实验需要玩家1和替身（先按 F12）"); return end
    SWAP.step = SWAP.step + 1
    if SWAP.step == 1 then
        out("========== 换装实验 1/3（玩家1 当前武器 %s）==========", tostring(ST.p1Weapon))
        SWAP.orig = ST.p1Weapon or "Long"
        SWAP.s0 = swapSnap("初始")
        for k, v in pairs(SWAP.s0["玩家1"]) do if k:find("^武器组件") then out("  初始 玩家1 %s = %s", k, v) end end
        for k, v in pairs(SWAP.s0["替身"]) do if k:find("^武器组件") then out("  初始 替身 %s = %s", k, v) end end
        ST.pupWeapon = nil
        equipWeapon(pup, "ZhanMaBlade", "换装实验：只给替身装")
        out("下一步：等 2 秒再按 F2")
    elseif SWAP.step == 2 then
        out("========== 换装实验 2/3 ==========")
        SWAP.s1 = swapSnap("替身装斩马刀后")
        swapDiff(SWAP.s0, SWAP.s1, "替身换装的影响")
        local ok, err = pcall(function() return p1["Add Weapon And SwitchTo"](p1, FName("Double"), true, true) end)
        out("给玩家1装 Double：%s", ok and "调用成功" or ("失败 " .. tostring(err)))
        out("下一步：等 2 秒再按 F2")
    else
        out("========== 换装实验 3/3 ==========")
        local s2 = swapSnap("玩家1装双刃后")
        swapDiff(SWAP.s1, s2, "玩家1换装的影响")
        local ok, err = pcall(function() return p1["Add Weapon And SwitchTo"](p1, FName(SWAP.orig), true, true) end)
        out("玩家1装回 %s：%s", SWAP.orig, ok and "调用成功" or ("失败 " .. tostring(err)))
        out("========== 换装实验结束 ==========")
        SWAP.step = 0
    end
end

-- F2 实验（v0.10.7）：v0.10.6 探针在角色上找到无参函数 BP_RenewalPlayer_C:"Respawn Recover Attributes"()，
-- 没找到存药瓶次数的字段（存档里是 MedicineInfos.<药>.CurrentTime = 剩余次数，用户实测 FeiJiu 5→4 喝了一瓶）。
-- 存档点休息 / 复活时游戏会补满药瓶，这个函数很可能就是那一步。前后打印血量 / 杀气，药瓶数量请用户看屏幕
local function respawnRecover()
    local p1 = getP1()
    if not valid(p1) then out("!! 没有玩家1"); return end
    local hp0, sh0 = hpOf(p1), attrOf(p1, "Shachi")
    out("== 实验：Respawn Recover Attributes() ==（之前 血量 %s 杀气 %s）", tostring(hp0), tostring(sh0))
    out("  [步骤] 调用")
    local ok, err = pcall(function() p1["Respawn Recover Attributes"](p1) end)
    out("  调用%s；之后 血量 %s 杀气 %s。请看屏幕上的药瓶数量有没有回满", ok and "成功" or ("失败 " .. tostring(err)),
        tostring(hpOf(p1)), tostring(attrOf(p1, "Shachi")))
end

-- F2（v0.10.8，只读）：v0.10.7 实测 Respawn Recover Attributes 不补药瓶。PBZ.exe 字符串里有
-- ClearMedicineUseTime / RecoveryMedicineDefinitely / GetCurrentMedicineNum / GM_InfiniteMedicine 等，
-- 按函数名找到它们，打印所属类和参数；再找这些类的活实例，读带药字段（只调无参 Get/Is）
local MED_FNS = { "ClearMedicineUseTime", "RecoveryMedicineDefinitely", "GetCurrentMedicineNum", "GM_InfiniteMedicine",
                  "GM_GiveMedicine", "InitMedicines", "IncreaseMedicine", "RegenPotion", "AddMedicineAmount",
                  "UseMedicine", "GetAllMedicines" }

local function findFunctions(name)
    local res = {}
    if type(FindObjects) == "function" then
        local ok, r = pcall(function() return FindObjects(8, "Function", name, 0, 0, false) end)
        if ok and type(r) == "table" then
            for _, f in pairs(r) do if valid(f) then res[#res + 1] = f end end
            return res, "FindObjects"
        end
    end
    return res, "FindObjects 不可用"
end

local function medProbe2()
    out("========== 药瓶探针 2（只读）==========")
    local owners = {}
    for _, n in ipairs(MED_FNS) do
        local fs, how = findFunctions(n)
        out("[函数] %s：%d 个（%s）", n, #fs, how)
        for _, f in ipairs(fs) do
            local fn = full(f)
            out("    %s (%s)", fn, PROBE.sigStr(PROBE.signature(f)))
            local cls = fn:match("^%S+%s+(.-):[^:]+$")
            if cls then owners[cls] = true end
        end
    end
    for cls in pairs(owners) do
        local short = cls:match("%.([%w_]+)$") or cls
        local okA, all = pcall(function() return FindAllOf(short) end)
        local n = 0
        if okA and all then
            for _, o in pairs(all) do
                if valid(o) then
                    n = n + 1
                    if n <= 2 then
                        out("[实例] %s", full(o))
                        PROBE.walkClass(o, medWord, 60, 0, "[" .. short .. "]")
                        PROBE.walkClass(o, function(x) return x:find("Medicine") ~= nil and (x:sub(1, 3) == "Get" or x:sub(1, 2) == "Is") end,
                            0, 40, "[" .. short .. " Get]")
                    end
                end
            end
        end
        out("[类] %s：活实例 %d 个", cls, n)
    end
    out("========== 药瓶探针 2 结束 ==========")
end

-- 菜单排查（v0.11.4，只读）：游戏用 CommonUI + GameUIPolicy（PBZ.exe 里有 GameUIPolicy / PrimaryGameLayout /
-- ELocalMultiplayerInteractionMode / IsPrimaryPlayer）。每个本地玩家一个根布局，由"本地多人交互模式"决定谁收输入。
-- v0.11.3 实测：只调 CreatePlayer 菜单就坏，移除后也不恢复。对比创建前后各根布局和策略的状态
local UI_KW = { "Dormant", "Layer", "Policy", "Primary", "Multiplayer", "Root", "Owning", "Player", "Active", "Input" }
local function uiWord(n)
    for _, k in ipairs(UI_KW) do if n:find(k) then return true end end
    return false
end

MATCH.uiProbe = function(tag)
    out("========== 界面探针（%s）==========", tag)
    -- v0.11.6：UI 管理器的 PushCachedWidgetToLayer 不带"哪个玩家"参数，推测推给 GetCommonLocalPlayer()。
    -- 每个时间点都读它，和玩家1 自己的 LocalPlayer 对比
    local mgr = FindFirstOf("PBZUIManagerSubsystem")
    local okC, clp = pcall(function() return mgr:GetCommonLocalPlayer() end)
    local mine = rawProp(getP1PC(), "Player")
    out("[关键] UI 管理器 GetCommonLocalPlayer = %s；玩家1 的 LocalPlayer = %s；%s",
        (okC and valid(clp)) and short(pathOf(clp)) or ("<无效> " .. tostring(clp)), short(pathOf(mine)),
        (okC and valid(clp) and sameObj(clp, mine)) and "一致" or "★ 不一致")
    local gi = valid(mgr) and select(2, pcall(function() return mgr:GetOuter() end)) or nil
    local lps = valid(gi) and rawProp(gi, "LocalPlayers") or nil
    local names = {}
    eachArr(lps, function(_, lp) names[#names + 1] = valid(lp) and short(pathOf(lp)) or "<无效>" end)
    out("[关键] GameInstance.LocalPlayers（%d）：%s", #names, table.concat(names, "，"))
    local okL, lays = pcall(function() return FindAllOf("PrimaryGameLayout") end)
    local n = 0
    if okL and lays then
        for _, w in pairs(lays) do
            if valid(w) then
                n = n + 1
                local function call(fn)
                    local ok, r = pcall(function() return w[fn](w) end)
                    return ok and anyToStr(r) or "?"
                end
                out("[根布局 %d] %s", n, full(w))
                local function objOf(fn)
                    local ok, r = pcall(function() return w[fn](w) end)
                    return (ok and valid(r)) and short(pathOf(r)) or "-"
                end
                out("    IsInViewport=%s Visibility=%s OwningPlayer=%s OwningLocalPlayer=%s", call("IsInViewport"),
                    call("GetVisibility"), objOf("GetOwningPlayer"), objOf("GetOwningLocalPlayer"))
                PROBE.walkClass(w, uiWord, 30, 0, "[根布局 " .. n .. "]")
            end
        end
    end
    out("[根布局] 共 %d 个", n)
    for _, cn in ipairs({ "GameUIPolicy", "GameUIManagerSubsystem" }) do
        local okP, ps = pcall(function() return FindAllOf(cn) end)
        local m = 0
        if okP and ps then
            for _, o in pairs(ps) do
                if valid(o) then
                    m = m + 1
                    out("[%s %d] %s", cn, m, full(o))
                    PROBE.walkClass(o, nil, 30, 0, "[" .. cn .. "]")
                end
            end
        end
        out("[%s] 共 %d 个", cn, m)
    end
    -- v0.12.6：CommonUI 输入过滤（异步推界面会 SuspendInputForPlayer，推完才 Resume；推送被打断就一直挂着）
    do
        local mineLP = rawProp(getP1PC(), "Player")
        local okS, subs = pcall(function() return FindAllOf("CommonInputSubsystem") end)
        local cis
        for _, x in pairs((okS and subs) or {}) do
            local okO, o = pcall(function() return x:GetOuter() end)
            if valid(x) and okO and sameObj(o, mineLP) then cis = x end
        end
        if valid(cis) then
            local parts = {}
            for t, nm in pairs({ [0] = "键鼠", [1] = "手柄", [2] = "触屏" }) do
                local okF, f = pcall(function() return cis:GetInputTypeFilter(t) end)
                parts[#parts + 1] = string.format("%s 过滤=%s", nm, okF and tostring(f) or "?")
            end
            local okT, cur = pcall(function() return cis:GetCurrentInputType() end)
            out("[输入过滤] 玩家1 CommonInputSubsystem：%s；当前输入类型 %s", table.concat(parts, "，"), okT and tostring(cur) or "?")
        else
            out("[输入过滤] 没找到玩家1 的 CommonInputSubsystem")
        end
        local okA, acts = pcall(function() return FindAllOf("AsyncAction_PushContentToLayerForPlayer") end)
        local na = 0
        for _, a in pairs((okA and acts) or {}) do if valid(a) then na = na + 1 end end
        out("[输入过滤] 未完成 / 存活的异步推界面任务 %d 个", na)
    end
    -- v0.12.4：系统菜单控件是否被全局缓存、归属谁（假设：替身初始化时 Init Push Widget 把缓存的菜单控件归属改成了它）
    do
        local mine = getP1PC()
        for _, cn in ipairs({ "W_Systembase_C", "CommonActivatableWidget" }) do
            local okA, ws = pcall(function() return FindAllOf(cn) end)
            local n, lines = 0, {}
            if okA and ws then
                for _, w in pairs(ws) do
                    if valid(w) then
                        n = n + 1
                        local okO, o = pcall(function() return w:GetOwningPlayer() end)
                        local own = (okO and valid(o)) and (sameObj(o, mine) and "玩家1" or short(pathOf(o))) or "<无>"
                        local okV, inv = pcall(function() return w:IsInViewport() end)
                        if cn == "W_Systembase_C" or own ~= "玩家1" then
                            lines[#lines + 1] = string.format("%s[归属 %s，在视口 %s]", shortName(full(w)) or "?", own,
                                okV and tostring(inv) or "?")
                        end
                    end
                end
            end
            out("[菜单控件] %s 共 %d 个；%s：%s", cn, n, cn == "W_Systembase_C" and "全部" or "归属不是玩家1 的",
                table.concat(lines, " "))
        end
    end
    -- v0.12.1：BP_Player_Base 名字表里菜单逻辑引用 CanOpenSystemUI / CanOpenMapUI / CanOpen / IsOpen / PushSystemUI。
    -- v0.12.0 实测：恢复输入焦点后 Esc 能触发角色的菜单事件，但之后不调 PushContentToLayer_ForPlayer → 被某个条件拦下
    do
        local p1 = getP1()
        for _, fnName in ipairs({ "CanOpenSystemUI", "CanOpenMapUI", "CanOpen", "IsOpen", "PushSystemUI", "BeforePushSystemV1" }) do
            local okF, fs = pcall(function() return FindObjects(6, "Function", fnName, 0, 0, false) end)
            local where = {}
            if okF and type(fs) == "table" then
                for _, f in pairs(fs) do if valid(f) then where[#where + 1] = full(f) .. " (" .. PROBE.sigStr(PROBE.signature(f)) .. ")" end end
            end
            local okP, pv = pcall(function() return rawProp(p1, fnName) end)
            out("[菜单条件] %s：函数 %d 个 %s；角色上同名属性 = %s", fnName, #where, table.concat(where, " | "),
                okP and anyToStr(pv) or "?")
            -- 只有返回值、没有参数的就调一次（查询类）
            for _, f in pairs((okF and type(fs) == "table") and fs or {}) do
                local sig = valid(f) and PROBE.signature(f) or {}
                if #sig == 1 and sig[1].ret then
                    local owner = full(f):match("^%S+%s+(.-):[^:]+$") or ""
                    local target
                    if owner:find("BP_Player_Base", 1, true) or owner:find("Renewal", 1, true) then target = p1 end
                    if not target then
                        local okO, o = pcall(function() return FindFirstOf(owner:match("%.([%w_]+)$") or "") end)
                        target = okO and valid(o) and o or nil
                    end
                    if target then
                        local okC, r = pcall(function() return target[fnName](target) end)
                        out("    调用 %s.%s() = %s", short(pathOf(target)), fnName, okC and anyToStr(r) or ("失败 " .. tostring(r)))
                    end
                end
            end
        end
    end
    -- v0.11.9：① 玩家1 的 Enhanced Input 子系统上挂了哪些映射上下文（对所有已加载的 IMC 调 HasMappingContext）
    local mine2 = rawProp(getP1PC(), "Player")
    local sub
    local okS, subs = pcall(function() return FindAllOf("EnhancedInputLocalPlayerSubsystem") end)
    if okS and subs then
        for _, x in pairs(subs) do
            local okO, o = pcall(function() return x:GetOuter() end)
            if valid(x) and okO and sameObj(o, mine2) then sub = x end
        end
    end
    local okI, imcs = pcall(function() return FindAllOf("InputMappingContext") end)
    local on, off = {}, {}
    if valid(sub) and okI and imcs then
        for _, c in pairs(imcs) do
            if valid(c) then
                local nm = shortName(full(c)) or "?"
                local okH, has = pcall(function() return sub:HasMappingContext(c, {}) end)
                if okH and has == true then on[#on + 1] = nm else off[#off + 1] = nm .. (okH and "" or "(调用失败)") end
            end
        end
    end
    table.sort(on); table.sort(off)
    out("[映射] 玩家1 子系统 %s；已挂 %d 个：%s", valid(sub) and "找到" or "没找到", #on, table.concat(on, " "))
    out("[映射] 已加载但没挂 %d 个：%s", #off, table.concat(off, " "))
    -- ② 第一次时给角色蓝图里和菜单有关的输入事件挂钩子
    if not MATCH.menuEvtHooked then
        MATCH.menuEvtHooked = true
        local names = {}
        local okC, cls = pcall(function() return getP1():GetClass() end)
        local c = okC and cls or nil
        for _ = 1, 8 do
            if not valid(c) then break end
            local cpath = pathOf(c)
            pcall(function()
                c:ForEachFunction(function(f)
                    local n = "?"
                    pcall(function() n = f:GetFName():ToString() end)
                    if n:find("InpActEvt") and (n:find("Menu") or n:find("System") or n:find("Push") or n:find("Option")) then
                        names[#names + 1] = cpath .. ":" .. n
                    end
                end)
            end)
            local okP, sup = pcall(function() return c:GetSuperStruct() end)
            c = okP and sup or nil
        end
        -- v0.12.3 挂的"菜单流程"钩子（带 post 回调读蓝图函数参数）在 PushSystemUI 触发时直接崩（02:12:14），已删
        out("[菜单事件] 找到 %d 个：%s", #names, table.concat(names, " "))
        for _, path in ipairs(names) do
            local short2 = path:match(":(.+)$")
            local okR, errR = pcall(function()
                RegisterHook(path, function(ctx)
                    local who = "?"
                    pcall(function() who = short(pathOf(ctx:get())) end)
                    out("【菜单事件】%s 触发（角色 %s）", short2, who)
                end)
            end)
            out("  挂钩子 %s：%s", short2, okR and "成功" or ("失败 " .. tostring(errR)))
        end
    end
    -- v0.11.5：只在第一次（创建之前）列函数：找"注册玩家 / 设菜单归属"一类的入口。
    -- v0.11.4 实测：自己的根布局全程在视口、归属不变；第二玩家的根布局移除后也离开了视口 → 问题不在根布局
    if tag == "CreatePlayer 之前" then
        local FN_KW = { "Player", "Owner", "Owning", "Menu", "Pause", "Input", "Register", "Layout", "Root", "Push",
                        "Open", "Esc", "Back", "Controller", "Primary", "Focus", "Show" }
        local function fnWord(nm)
            for _, k in ipairs(FN_KW) do if nm:find(k) then return true end end
            return false
        end
        local pc = getP1PC()
        local okLP, lp = pcall(function() return pc:GetLocalPlayer() end)
        local targets = {
            { "UI 管理器", FindFirstOf("PBZUIManagerSubsystem") },
            { "UI 策略", FindFirstOf("PBZUIPolicy_C") },
            { "玩家控制器", pc },
            { "本地玩家", okLP and lp or nil },
        }
        for _, t in ipairs(targets) do
            if valid(t[2]) then
                out("[函数表 %s] %s", t[1], full(t[2]))
                PROBE.walkClass(t[2], fnWord, 40, 120, "[" .. t[1] .. "]")
            else
                out("[函数表 %s] 没找到", t[1])
            end
        end
    end
    out("========== 界面探针结束 ==========")
end

-- F2 实验（v0.11.0）：不用 CreatePlayer（会让游戏多一个本地玩家，菜单打不开），
-- 直接 SpawnActor 一个和玩家同类的角色代表对手，看它有没有技能、能不能出招伤人、菜单还能不能开。
-- 每按一次进一步：1 生成并检查  2 改敌对并出一招  3 销毁
local function npcExperiment()
    local p1 = getP1()
    if not valid(p1) then out("!! 没有玩家1"); return end
    MATCH.npcStep = (MATCH.npcStep or 0) % 3 + 1
    local st = MATCH.npcStep
    local npc = MATCH.npc
    if st == 1 and valid(npc) then
        -- v0.11.0 实测：销毁（K2_DestroyActor）玩家类角色直接崩。不再销毁，第 3 步只藏起来，这里拿出来复用
        local loc = try("npc loc", function() return p1:K2_GetActorLocation() end)
        local rot = try("npc rot", function() return p1:K2_GetActorRotation() end)
        if loc and rot then
            local r = math.rad(rot.Yaw)
            pcall(function() npc:K2_SetActorLocation({ X = loc.X + math.cos(r) * 300.0, Y = loc.Y + math.sin(r) * 300.0,
                Z = loc.Z + 50.0 }, false, {}, true) end)
        end
        pcall(function() npc:SetActorHiddenInGame(false) end)
        pcall(function() npc:SetActorEnableCollision(true) end)
        local cm = rawProp(npc, "CharacterMovement")
        if valid(cm) then pcall(function() cm:SetMovementMode(1, 0) end) end      -- MOVE_Walking
        out("== 实验 1/3：复用已生成的实验角色 %s，移到你前方 ==", short(pathOf(npc)))
        return
    end
    if st == 1 then
        local okC, cls = pcall(function() return p1:GetClass() end)
        local world = try("npc world", function() return p1:GetWorld() end)
        local loc = try("npc loc", function() return p1:K2_GetActorLocation() end)
        local rot = try("npc rot", function() return p1:K2_GetActorRotation() end)
        if not (okC and valid(cls) and valid(world) and loc and rot) then out("!! 实验：取类 / 世界 / 位置失败"); return end
        local r = math.rad(rot.Yaw)
        local pos = { X = loc.X + math.cos(r) * 300.0, Y = loc.Y + math.sin(r) * 300.0, Z = loc.Z + 50.0 }
        out("== 实验 1/3：SpawnActor(%s) 在你前方 300 ==", short(pathOf(cls)))
        out("  [步骤] SpawnActor")
        npc = try("spawn npc", function()
            return world:SpawnActor(cls, pos, { Pitch = 0.0, Yaw = rot.Yaw + 180.0, Roll = 0.0 })
        end)
        MATCH.npc = npc
        if not valid(npc) then out("!! 生成失败"); MATCH.npcStep = 0; return end
        out("  生成：%s；生成后控制器 %s", full(npc), full(rawProp(npc, "Controller")))
        out("  [步骤] SpawnDefaultController()")
        local okD, errD = pcall(function() npc:SpawnDefaultController() end)
        out("  SpawnDefaultController %s；现在控制器 %s", okD and "调用成功" or ("失败 " .. tostring(errD)),
            full(rawProp(npc, "Controller")))
        -- v0.11.0 实测：SpawnDefaultController 后仍没有控制器（玩家类的 AIControllerClass 大概是空的）。手动生成 AIController 再 Possess
        if not valid(rawProp(npc, "Controller")) then
            local aic = StaticFindObject("/Script/AIModule.AIController")
            out("  [步骤] SpawnActor(AIController)（类 %s）", tostring(valid(aic)))
            local ctl = valid(aic) and try("spawn aic", function()
                return world:SpawnActor(aic, pos, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }) end) or nil
            out("  [步骤] Possess（控制器 %s）", full(ctl))
            local okP, errP = pcall(function() ctl:Possess(npc) end)
            out("  Possess %s；现在控制器 %s", okP and "调用成功" or ("失败 " .. tostring(errP)), full(rawProp(npc, "Controller")))
        end
        -- v0.11.0 实测：血量 0/0（属性没初始化）。抄玩家的属性，再用回满效果走一次通知
        for _, n in ipairs({ "Level", "Health_Max", "Health", "Attack", "Shachi_Max", "Shachi", "ShachiAttack", "Infliction_Max" }) do
            local v = attrOf(p1, n)
            if v then setAttr(npc, n, v) end
        end
        out("  抄属性后：血量 %s/%s 攻击 %s 杀气 %s/%s", tostring(hpOf(npc)), tostring(attrOf(npc, "Health_Max")),
            tostring(attrOf(npc, "Attack")), tostring(attrOf(npc, "Shachi")), tostring(attrOf(npc, "Shachi_Max")))
        local abs = abilitiesOf(npc) or {}
        local names = {}
        for i, a in ipairs(abs) do if i <= 12 then names[#names + 1] = a.name end end
        out("  ASC=%s 血量=%s/%s 阵营=%s 技能 %d 个：%s", tostring(valid(ascOf(npc))), tostring(hpOf(npc)),
            tostring(attrOf(npc, "Health_Max")), factionName(npc), #abs, table.concat(names, " "))
        out("  请看：1) 现在能不能打开菜单  2) 镜头还在你身上吗  3) 它站着还是倒着 / 有没有拿武器")
    elseif st == 2 then
        if not valid(npc) then out("!! 实验角色不在了"); MATCH.npcStep = 0; return end
        local fc = factionComp(npc)
        local okF = valid(fc) and pcall(function() fc:SetFaction({ TagName = FName("Faction.Enemy") }) end)
        out("== 实验 2/3：改敌对（%s，阵营 %s），朝你出一招 ==", okF and "成功" or "失败", factionName(npc))
        facePlayer(npc)
        local asc, used = ascOf(npc), nil
        for _, a in ipairs(abilitiesOf(npc) or {}) do
            if not used and a.name:match("^GA_Hun_%w+_A_C$") then
                local ok, r = pcall(function() return asc:TryActivateAbilityByClass(a.cls, true) end)
                out("  [步骤] TryActivateAbilityByClass(%s) -> %s", a.name, ok and tostring(r) or ("失败 " .. tostring(r)))
                if ok and r then used = a.name end
            end
        end
        if not used then out("  没有能激活的普攻（GA_Hun_*_A_C）") end
        out("  请看：它有没有挥刀？站在它面前会不会掉血？")
    else
        -- v0.11.0 实测：K2_DestroyActor 玩家类角色直接崩（01:18:32）。改成原地藏起来：隐藏 + 关碰撞 + 停掉移动
        -- （不能往地下挪：关了碰撞会一直掉到 KillZ，被引擎自动销毁 = 同样会崩）
        out("== 实验 3/3：原地藏起实验角色（不销毁，销毁会崩）==")
        if valid(npc) then
            local cm = rawProp(npc, "CharacterMovement")
            if valid(cm) then pcall(function() cm:DisableMovement() end) end
            pcall(function() npc:SetActorHiddenInGame(true) end)
            pcall(function() npc:SetActorEnableCollision(false) end)
        end
    end
end

-- v0.13.2 斩马刀对比实验（F2）：用户反馈 PvP 里杀气重击的耗血 / 吸血不显示（打怪正常）；v0.10.13 日志里放 ZhanMa_B/BB/DB
-- 时玩家血量完全不变。怀疑常驻的陪练锁血 GE_LockHealth。按 F2：第 1 次在"不锁血"下放一次 GA_Hun_ZhanMa_B_C，
-- 第 2 次在"锁血"下放一次；各自 2 秒后记血量变化
local function zhanmaTest()
    local p1 = getP1()
    if not valid(p1) then return end
    -- v0.13.3：空挥不耗血也不吸血（v0.13.2 实测 3085.5 → 3085.5，锁不锁血都一样）→ 只在命中时生效。
    -- 改测"砍中替身"：没联网时造替身放面前、设敌对（暂停阵营同步）、转身朝它放杀气重击
    if not valid(puppet()) and MATCH.autoCreate then MATCH.autoCreate() end
    local pup = puppet()
    if not valid(pup) then out("!! 实验：替身没造出来"); return end
    MATCH.zmHold = true
    placeInFront(pup, 180.0)
    local fc = factionComp(pup)
    pcall(function() fc:SetFaction({ TagName = FName("Faction.Enemy") }) end)
    local a = try("zm loc", function() return p1:K2_GetActorLocation() end)
    local b = try("zm pup", function() return pup:K2_GetActorLocation() end)
    if a and b then setYaw(p1, math.deg(math.atan(b.Y - a.Y, b.X - a.X))) end
    MATCH.zmStep = (MATCH.zmStep or 0) % 2 + 1
    local name = MATCH.zmStep == 1 and "GA_Hun_ZhanMa_B_C" or "GA_Hun_ZhanMa_A_C"
    local cls
    for _, x in ipairs(abilitiesOf(p1) or {}) do if x.name == name then cls = x.cls end end
    if not cls then out("!! 实验：玩家身上没有 %s（先换上斩马刀）", name); return end
    -- v0.13.4：满血时吸血看不出来（v0.13.3 实测命中替身 -1577，玩家仍 3085.5 = 上限），先把玩家血量压到一半
    local hm = attrOf(p1, "Health_Max")
    if hm then setAttr(p1, "Health", hm * 0.5) end
    local hp0, php0 = hpOf(p1), hpOf(pup)
    local ok, r = pcall(function() return ascOf(p1):TryActivateAbilityByClass(cls, true) end)
    out("== 斩马刀命中实验 %d/2：%s -> %s；之前 玩家血量 %.1f，替身血量 %.1f，替身阵营 %s ==", MATCH.zmStep, name,
        ok and tostring(r) or ("失败 " .. tostring(r)), hp0 or -1, php0 or -1, factionName(pup))
    MATCH.zmCheck = { at = now() + 3.0, hp0 = hp0, php0 = php0, name = name }
end

local function zhanmaCheck()
    local c = MATCH.zmCheck
    if not c or now() < c.at then return end
    MATCH.zmCheck = nil
    local hp1 = hpOf(getP1())
    local php1 = hpOf(puppet())
    out("== 斩马刀命中实验结果（%s）：玩家血量 %.1f → %.1f（%+.1f）；替身血量 %.1f → %.1f（%+.1f）==", c.name,
        c.hp0 or -1, hp1 or -1, (hp1 or 0) - (c.hp0 or 0), c.php0 or -1, php1 or -1, (php1 or 0) - (c.php0 or 0))
end

-- §154 测试用"自动出招"：真人对真人测伤害时，由外部工具让本机角色贴近对手、面向它、放指定招 N 次（双开时两份各自执行，
-- 不用电脑控制走位）。只在模组目录有 autohit.on 时才开（加载时看一次）；开着时每秒读一次 <net>/autohit.txt：
--   id=任意（换了才算新任务）  move=技能名（如 GA_Hun_WoodenSword_A_C）  n=次数  gap=间隔秒  close=1 先瞬移到对手面前 dist 远
local AUTOHIT = { on = false, id = nil, job = nil, readAt = -100, hold = nil, holdAt = -100,
                  -- §196 临时配装（equip=）不能被游戏存档写进去（11-09 实测：AutoSave0/1 的 MainWeapons 成了 [None, ZiMingJian]）
                  pushed = false, IDLE_POP = 15, CHECK_EVERY = 2.0, checkAt = -100, busyAt = -100, lastEquip = nil,
                  hooks = {}, SAVE_FNS = { TrySave = true, ForceSave = true, SaveAdvancedSaveGameNow = true } }
function AUTOHIT.xyz(v)
    local x, y, z = tostring(v or ""):match("^%s*(-?[%d.]+)%s*,%s*(-?[%d.]+)%s*,%s*(-?[%d.]+)")
    return x and { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) } or nil
end
do local f = io.open(ROOT .. "/autohit.on", "r"); if f then f:close(); AUTOHIT.on = true end end
AUTOHIT.LEDGER = NET_DIR .. "/autohit_pushed.txt"

-- §196 equip= / sequip= 用的是游戏的临时整套配装（PushEquippedWeapons）。它只是把当前配装换掉、另存一份快照等 Pop——
-- 换着的时候游戏自动存档（敲钟传送 / 过图 / 定时）会把换上的配装当成真配装写进存档（11-09 实测：autohit 换了 ZiMingJian 后
-- 一场打完没 pop，23:05 传送到主机身边时自动存档，AutoSave0/1 写成 MainWeapons=[None, ZiMingJian]、ShaqiWeapons[1]=None）。
-- 所以以前"不碰存档"的说法是错的。现在：
--   · 能挂就挂：换着的时候在 PBZSaveLoadSubsystem 的 TrySave / ForceSave / SaveAdvancedSaveGameNow 上挂前置钩子，存档前先 Pop；
--     存完 3 秒后任务还在跑就再 Push 回去。UE4SS 只拦经过 ProcessEvent 的调用，游戏 C++ 里直调的拦不到（没实测过拦不拦得到）
--   · 挂不挂得到都兜底：回合结束（离开交手）、换地图、我们自己发起的游戏传送（G.travelTo 先存档）之前、
--     没有任务空闲 IDLE_POP 秒，一律 Pop；push 期间每 CHECK_EVERY 秒查一次
--   · 自动 Pop 后再来的任务没写 equip= 也没写 pop=1：按上次的 equip 自动重新换上（测试工具照旧"换一次、连测几招"）
--   · 游戏退出拦不到：push 时写账本 net/autohit_pushed.txt（原配装），pop 删；下次进游戏账本还在 → 游戏还有快照就 Pop，
--     没有了就在日志里写明原配装，请手动换回
--   · 测完照旧写 pop=1（立刻换回、也不再自动重新换上）
function AUTOHIT.push(m, sq, why)
    local okP, errP = G.loadoutPush(m, sq, 0, 0)
    out("== 自动出招：配装换成 主 %s / 影 %s（%s）：%s ==", table.concat(m, ","), tostring(sq[1]), why, okP and "成功" or tostring(errP))
    if not okP then return false end
    AUTOHIT.pushed, AUTOHIT.lastEquip, AUTOHIT.pushMap = true, { m = m, sq = sq }, ST.mapLoadAt
    AUTOHIT.wasFight = NET.fighting()
    local o = AUTOHIT.orig or {}
    local f = io.open(AUTOHIT.LEDGER, "w")
    if f then f:write("m=", table.concat(o.m or {}, ","), "\ns=", table.concat(o.s or {}, ","), "\n"); f:close() end
    AUTOHIT.hookSave()
    return true
end
-- keep = true：记住这套，之后没写 equip= 的任务自动重新换上；false（pop=1 / 换下一套）：忘掉
function AUTOHIT.pop(why, keep)
    if not AUTOHIT.pushed then return false end
    local okP, errP = G.loadoutPop()
    AUTOHIT.pushed = false
    if not keep then AUTOHIT.lastEquip = nil end
    os.remove(AUTOHIT.LEDGER)
    out("== 自动出招：换回原配装（%s）%s ==", why, okP and "成功" or tostring(errP))
    AUTOHIT.unhookSave()
    return okP
end
-- 存档前置钩子：只 Pop、记一笔；日志、删账本、撤钩子、再 Push 都回到主循环里做（钩子里越轻越好，也不在钩子里撤钩子）
function AUTOHIT.preSave(fn)
    if not AUTOHIT.pushed then return end
    pcall(function()
        local okP = G.loadoutPop()
        AUTOHIT.pushed = false
        AUTOHIT.hookNote = { fn = fn, ok = okP }
    end)
end
-- 只在换着配装时挂（平时正常玩的存档不过我们的钩子），Pop 后撤（G.hookSaveFns / G.unhookAll 在 pbz_game.lua）
function AUTOHIT.hookSave()
    if next(AUTOHIT.hooks) then return end
    local hooks, got = G.hookSaveFns(AUTOHIT.SAVE_FNS, AUTOHIT.preSave)
    if not hooks then out("自动出招：没挂存档钩子（%s），只靠兜底 Pop", tostring(got)); return end
    AUTOHIT.hooks = hooks
    out("自动出招：换着配装期间挂存档钩子 %d 个：%s", #got, table.concat(got, " "))
end
function AUTOHIT.unhookSave()
    if not next(AUTOHIT.hooks) then return end
    local n = G.unhookAll(AUTOHIT.hooks)
    AUTOHIT.hooks = {}
    out("自动出招：撤了存档钩子 %d 个", n)
end
-- 我们自己发起的游戏传送（切图 / 同图远距离，G.travelTo）会先自动存档：调之前先 Pop
if AUTOHIT.on and G.travelTo then
    AUTOHIT.travel0 = G.travelTo
    G.travelTo = function(...)
        if AUTOHIT.pushed then AUTOHIT.pop("游戏传送前，它会先自动存档", true) end
        return AUTOHIT.travel0(...)
    end
end
-- 每帧调：存档钩子 Pop 过的补日志 / 再换上；换着配装期间每 CHECK_EVERY 秒查：离开交手、换了地图、空闲太久 → Pop
function AUTOHIT.guard(tn)
    local hn = AUTOHIT.hookNote
    if hn then
        AUTOHIT.hookNote = nil
        out("== 自动出招：游戏存档（%s）前换回了原配装：%s ==", hn.fn, hn.ok and "成功" or "失败")
        os.remove(AUTOHIT.LEDGER)
        if AUTOHIT.job and AUTOHIT.lastEquip then AUTOHIT.repushAt = tn + 3.0 else AUTOHIT.unhookSave() end
    end
    if AUTOHIT.repushAt and tn >= AUTOHIT.repushAt then
        AUTOHIT.repushAt = nil
        if AUTOHIT.job and AUTOHIT.lastEquip and not AUTOHIT.pushed then
            AUTOHIT.push(AUTOHIT.lastEquip.m, AUTOHIT.lastEquip.sq, "存档完了换回测试配装")
            AUTOHIT.job.at = math.max(AUTOHIT.job.at, tn + 2.5)
        else AUTOHIT.unhookSave() end
    end
    if AUTOHIT.job or AUTOHIT.anim then AUTOHIT.busyAt = tn end
    if not AUTOHIT.pushed or tn - AUTOHIT.checkAt < AUTOHIT.CHECK_EVERY then return end
    AUTOHIT.checkAt = tn
    local fight = NET.fighting()
    if AUTOHIT.wasFight and not fight then
        AUTOHIT.pop("回合 / 对局结束", true)
        if AUTOHIT.job then out("== 自动出招 %s 停了（回合结束）==", tostring(AUTOHIT.id)); AUTOHIT.job = nil end
    elseif AUTOHIT.pushMap ~= ST.mapLoadAt then
        AUTOHIT.pop("换了地图", true)
    elseif tn - AUTOHIT.busyAt >= AUTOHIT.IDLE_POP and not AUTOHIT.keep then
        AUTOHIT.pop(string.format("没有任务 %d 秒", AUTOHIT.IDLE_POP), true)
    elseif G.loadoutSnapshot() == false then
        AUTOHIT.pushed = false
        os.remove(AUTOHIT.LEDGER)
        AUTOHIT.unhookSave()
        out("== 自动出招：游戏已经没有临时配装快照（读档 / 剧情 / 别处 Pop 了），不再 Pop ==")
    end
    if AUTOHIT.pushed and fight then AUTOHIT.wasFight = true end
end
-- 进游戏后（有玩家角色）第一次调：上次没换回就退出了（游戏退出拦不到）
function AUTOHIT.cleanup()
    if AUTOHIT.cleaned then return end
    AUTOHIT.cleaned = true
    local kv = fileReadKV(AUTOHIT.LEDGER)
    if not kv then return end
    os.remove(AUTOHIT.LEDGER)
    if G.loadoutSnapshot() then
        local okP = G.loadoutPop()
        out("== 自动出招：上次的临时配装还在，换回原配装 %s ==", okP and "成功" or "失败")
    else
        out("!! 自动出招：上次的临时配装没换回就退出了，可能已经被存档写进去；原配装 主 %s / 影 %s，配装不对请在游戏里手动换回",
            kv.m or "?", kv.s or "?")
    end
end
-- §165.6 读动画：长度（GetPlayLength / SequenceLength）、段落（CompositeSections）、通知（Notifies：类名、时刻、时长）。每帧 8 个
function AUTOHIT.animStep()
    local A = AUTOHIT.anim
    for _ = 1, 8 do
        A.i = A.i + 1
        local path = A.list[A.i]
        if not path then
            local fh = io.open(NET_DIR .. "/anim_dump.txt", "w")
            if fh then fh:write(table.concat(A.lines, "\n"), "\n"); fh:close() end
            out("== 自动出招：动画数据写完 %d 行 ==", #A.lines); AUTOHIT.anim = nil; return
        end
        local mt = LO.loadObject(path)
        if not valid(mt) then A.lines[#A.lines + 1] = path .. "\t?"
        else
            local len
            pcall(function() len = mt:GetPlayLength() end)
            if type(len) ~= "number" then len = tonumber(G.rawProp(mt, "SequenceLength")) end
            local secs, nts = {}, {}
            local cs = G.rawProp(mt, "CompositeSections")
            if cs then pcall(G.eachArr, cs, function(_, e)
                secs[#secs + 1] = string.format("%s@%.3f", G.fnameStr(G.rawProp(e, "SectionName")) or "?", tonumber(G.rawProp(e, "LinkValue")) or -1)
            end) end
            local ns = G.rawProp(mt, "Notifies")
            if ns then pcall(G.eachArr, ns, function(_, e)
                local st, nf, cls = G.rawProp(e, "NotifyStateClass"), G.rawProp(e, "Notify"), "?"
                if valid(st) then cls = G.shortName(G.full(st)) elseif valid(nf) then cls = G.shortName(G.full(nf)) end
                nts[#nts + 1] = string.format("%s@%.3f+%.3f", cls, tonumber(G.rawProp(e, "LinkValue")) or -1, tonumber(G.rawProp(e, "Duration")) or 0)
            end) end
            A.lines[#A.lines + 1] = string.format("%s\t%s\t%s\t%s", path, len and string.format("%.3f", len) or "?", table.concat(secs, " "), table.concat(nts, " "))
        end
    end
end

local function autoHitStep()
    if not AUTOHIT.on then return end
    local tn = now()
    AUTOHIT.cleanup()           -- §196 上次没换回就退出了
    AUTOHIT.guard(tn)           -- §196 换着配装期间：存档前 / 回合结束 / 换图 / 空闲 → 换回
    if tn - AUTOHIT.readAt >= 1.0 then
        AUTOHIT.readAt = tn
        local kv = fileReadKV(NET_DIR .. "/autohit.txt")
        if kv and kv.id and kv.id ~= AUTOHIT.id then
            AUTOHIT.id = kv.id
            AUTOHIT.job = { move = kv.move or "", n = tonumber(kv.n) or 3, gap = tonumber(kv.gap) or 2.0,
                            close = kv.close == "1", dist = tonumber(kv.dist) or 180.0, i = 0, at = tn,
                            all = kv.all, list = nil, home = AUTOHIT.xyz(kv.home) }
            -- §165.6 animdump=1：读 <net>/anim_list.txt（一行一个动画路径），逐个 LoadAsset，记长度 / 段落 / 通知到 <net>/anim_dump.txt
            if kv.animdump == "1" then
                local list, fh = {}, io.open(NET_DIR .. "/anim_list.txt", "r")
                if fh then for l in fh:lines() do l = l:gsub("%s+$", ""); if l ~= "" then list[#list + 1] = l end end; fh:close() end
                AUTOHIT.anim = { list = list, i = 0, lines = {} }
                out("== 自动出招：读动画数据 %d 个 ==", #list)
            end
            -- §165.1 采数据防跑偏：hold=x,y,z 挨打方离这点太远 / 掉下去就拉回；hold=0 关掉
            if kv.hold then AUTOHIT.hold = AUTOHIT.xyz(kv.hold); out("== 自动出招：定点 %s ==", kv.hold) end
            -- §165 采数据：equip=主武器 ID / sequip=影武 ID 先用游戏的临时整套配装换上（Push）；测完写 pop=1 换回原来的。
            -- §196 换着的时候游戏存档会把它写进存档（以前注释写"不碰存档"是错的）：存档前 / 回合结束 / 换图 / 传送前 / 空闲都会自动 Pop，见上面
            -- §314 keep=1：临时配装空闲也不自动换回（手动按键测试用，比如多人房里自己召紫冥剑火枪——没有 1v1 替身，任务马上停）；
            -- 存档前 / 换地图 / 对局结束照样换回
            AUTOHIT.keep = kv.keep == "1"
            if kv.pop == "1" then
                if AUTOHIT.pushed then AUTOHIT.pop("pop=1", false) end
                AUTOHIT.lastEquip, AUTOHIT.repushAt = nil, nil
            end
            if (kv.equip or "") ~= "" or (kv.sequip or "") ~= "" then
                if AUTOHIT.pushed then AUTOHIT.pop("换下一套", false) end
                local mains, shaqis = G.loadoutLists()      -- 先 Pop 再读：读到的是真配装（账本记它）
                mains, shaqis = mains or {}, shaqis or {}
                AUTOHIT.orig = { m = mains, s = shaqis }
                local m = { mains[1] }                  -- §165.4 equip=A,B 两把（测切刀斩要能真切刀）
                if (kv.equip or "") ~= "" then m = {}; for w in kv.equip:gmatch("[^,%s]+") do m[#m + 1] = w end end
                local sq = (kv.sequip or "") ~= "" and { kv.sequip } or { shaqis[1] }
                AUTOHIT.push(m, sq, "equip=")
                AUTOHIT.job.at = tn + (tonumber(kv.settle) or 2.5)
            elseif kv.pop ~= "1" and AUTOHIT.lastEquip and not AUTOHIT.pushed then
                AUTOHIT.push(AUTOHIT.lastEquip.m, AUTOHIT.lastEquip.sq, "接着用上次的 equip=")
                AUTOHIT.job.at = tn + (tonumber(kv.settle) or 2.5)
            end
            out("== 自动出招 %s：%s × %d，间隔 %.1f 秒%s ==", kv.id, AUTOHIT.job.move, AUTOHIT.job.n, AUTOHIT.job.gap,
                AUTOHIT.job.close and "，先贴到对手面前" or "")
        end
    end
    if AUTOHIT.anim then AUTOHIT.animStep() end
    if AUTOHIT.hold and tn - AUTOHIT.holdAt >= 0.5 then
        AUTOHIT.holdAt = tn
        local p0, h = getP1(), AUTOHIT.hold
        local c = valid(p0) and try("ah hold", function() return p0:K2_GetActorLocation() end)
        if c and (math.sqrt((c.X - h.X) ^ 2 + (c.Y - h.Y) ^ 2) > 250 or c.Z < h.Z - 300) then
            pcall(function() p0:K2_SetActorLocation(h, false, {}, true) end)
            out("== 自动出招：离定点太远，拉回 (%.0f, %.0f, %.0f) ==", c.X, c.Y, c.Z)
        end
    end
    local j = AUTOHIT.job
    if not j or tn < j.at then return end
    local p1, pup = getP1(), puppet()
    if not valid(p1) or not valid(pup) then out("!! 自动出招：没有玩家或对手，停"); AUTOHIT.job = nil; return end
    if j.home then pcall(function() p1:K2_SetActorLocation(j.home, false, {}, true) end) end
    local a = j.home or try("ah loc", function() return p1:K2_GetActorLocation() end)
    local b = try("ah pup", function() return pup:K2_GetActorLocation() end)
    if not a or not b then return end
    local dx, dy = a.X - b.X, a.Y - b.Y
    local d = math.sqrt(dx * dx + dy * dy)
    if j.close and d > j.dist + 60 then
        local k = d > 1 and j.dist / d or 0
        local to = { X = b.X + dx * k, Y = b.Y + dy * k, Z = b.Z }
        pcall(function() p1:K2_SetActorLocation(to, false, {}, true) end)
        a, d = to, j.dist
    end
    setYaw(p1, math.deg(math.atan(b.Y - a.Y, b.X - a.X)))
    -- §165 all=main / edge：列出手上武器（或影武）的全部攻击招，每招放 n 次
    if j.all and not j.list then
        j.list = {}
        for _, x in ipairs(abilitiesOf(p1) or {}) do
            if isAttackAbility(x.name) and (LO.isEdgeAttack(x.name) == (j.all == "edge")) then j.list[#j.list + 1] = x.name end
        end
        table.sort(j.list)
        out("== 自动出招：%s 共 %d 招：%s ==", j.all, #j.list, table.concat(j.list, ","))
        if #j.list == 0 then AUTOHIT.job = nil; out("== 自动出招 %s 完成 ==", AUTOHIT.id); return end
        j.total = #j.list * j.n
    end
    if j.list then j.move = j.list[math.floor(j.i / j.n) + 1] end
    -- §165 采数据：每招前把杀气 / 暗源 / 精纯杀气补满（重招、影武、大招要资源，不然放不出）
    do     -- 单招（move=）补测也补，以前只在 all= 时补，大招没精纯杀气放不出
        for _, k in ipairs({ "Shachi", "SpiritShadow", "UltimateChargeCount" }) do
            local mx = attrOf(p1, k .. "_Max")
            if mx and (attrOf(p1, k) or mx) < mx then setAttr(p1, k, mx) end
        end
    end
    local cls
    for _, x in ipairs(abilitiesOf(p1) or {}) do if x.name == j.move then cls = x.cls end end
    local ok, r = false, "玩家身上没有这个技能"
    if cls then ok, r = pcall(function() return ascOf(p1):TryActivateAbilityByClass(cls, true) end) end
    j.i = j.i + 1
    out("== 自动出招 %d/%d：%s -> %s（离对手 %.0f）==", j.i, j.total or j.n, j.move, tostring(r), d)
    if j.i >= (j.total or j.n) then out("== 自动出招 %s 完成 ==", AUTOHIT.id); AUTOHIT.job = nil else j.at = tn + j.gap end
end

return { step = matchStep, start = matchStart, saveArena = saveArena, place = placeTextFrame, medProbe = medProbe,
         zhanmaTest = zhanmaTest, zhanmaCheck = zhanmaCheck, autoHitStep = autoHitStep, autohit = AUTOHIT,
         npcExperiment = npcExperiment, uiProbe = function(tag) MATCH.uiProbe(tag) end,
         respawnRecover = respawnRecover, medProbe2 = medProbe2, shareProbe = shareProbe, swapTest = swapTest,
         refillPotions = function() refillPotions("F2 手动") end, netui = netuiKey,
         -- v0.24.0 对手血条（OPPBAR，在这个函数外面）要用：Phantom Pact 连着没、对方昵称
         ppOn = function() return PP.on end, T = T,
         -- 2026-11-05 切图冻结（驱动段，在这个函数外面）要用：MAPGO 是这里的局部表，导出同一张表
         mapgo = MAPGO,
         -- §141 观战代码（pbz_spec.lua，在这个函数外面）要用：给联机程序发命令、面板闪一行字（2026-11-07 19:03 实测：
         -- 以前在外面直接写 netuiCmd / netuiFlash 拿到的是 nil，观战断开 / 排队换人 / 准备超时的命令都没发出去）
         cmd = netuiCmd, flash = netuiFlash, panelOpen = function() return NETUI.open end,
         -- §149.1 读档换世界时清掉落地保护记着的旧角色（SAFE 是这里的局部表，M4.forgetWorld 在外面看不到）
         forgetSafe = function() SAFE.guard = nil end,
         -- §141.14 退出观战时把玩家安全放到主机站过的地面旁边（safePlace 是这里的局部函数）
         safePlace = safePlace,
         -- 多人混战 ②d（pbz_multi.lua）：倒下判定（含慈母护符那种"致命一刀同时破防回血"）、倒地动作停在最后一帧
         mpDead = function(p1, hp, tn) return not (TRAINING and TRAINING.infinite("hp")) and (hp <= DEAD_HP or savedByBreakRegen(p1, hp, tn)) end, fallDown = fallDown,
         peerName = function() local lb = netuiRead(now()) or {}; return (lb.peername or "") ~= "" and lb.peername or nil end }
end)()

local function readExecConditions()
    out("========== 处决条件表 ==========")
    local p1, pup = getP1(), puppet()
    for _, e in ipairs({ { "玩家1", p1 }, { "替身", pup } }) do
        local sc = stateComp(e[2])
        if valid(sc) then
            out("[步骤] %s GetCurrentStates(out 数组)", e[1])
            local arr = {}
            local ok, r = pcall(function() return sc:GetCurrentStates(arr) end)
            out("  调用%s，返回 %s", ok and "成功" or ("失败 " .. tostring(r)), tostring(r))
            PROBE.dumpAny("  " .. e[1] .. " 当前状态(out)", arr)
            if type(r) == "table" then PROBE.dumpAny("  " .. e[1] .. " 当前状态(返回)", r) end
            for _, t in ipairs({ "CharacterState.InCombat", "CharacterState.Native.Focusing", "Targeting.Target.Combat",
                                 "CharacterState.Native.Attitude.Jogging" }) do
                local okC, c = pcall(function() return sc:CanActivateNewState({ TagName = FName(t) }) end)
                out("  %s CanActivateNewState(%s) = %s", e[1], t, okC and tostring(c) or "调用失败")
            end
        end
    end
    local wc = rawProp(p1, "Character Weapons Component")
    local gc = valid(wc) and rawProp(wc, "GlobalConfig") or nil
    if valid(gc) then
        out("[步骤] 全局配置 GetExecutionConditions(out Map)")
        local m = {}
        local ok, r = pcall(function() return gc:GetExecutionConditions(m) end)
        out("  调用%s，返回 %s", ok and "成功" or ("失败 " .. tostring(r)), tostring(r))
        PROBE.dumpAny("  条件表(out)", m)
        if type(r) == "table" then PROBE.dumpAny("  条件表(返回)", r) end
    end
    out("========== 处决条件表结束 ==========")
end

local function deepDump()
    out("========== 深度 dump ==========")
    local p1, pup = getP1(), puppet()
    for _, e in ipairs({ { "玩家1", p1 }, { "替身", pup } }) do
        if valid(e[2]) then
            PROBE.dumpAttrs(e[2], e[1])
            local tags = tagsOf(e[2])
            out("[%s] 当前标签(%d): %s", e[1], tags and #tags or -1, tags and table.concat(tags, " ") or "-")
            local abs = abilitiesOf(e[2])
            if abs then
                out("[%s] 技能 %d 个:", e[1], #abs)
                for i, a in ipairs(abs) do out("    [%d] %s", i, a.name) end
            end
        end
    end
    PROBE.weaponProbe()
    out("-- 阵营函数签名 --")
    for _, f in ipairs({ "GetFactionRelation", "GetFactionRelationWithTag", "SetFactionRelationOverride",
                         "SetFaction", "GetCurrnetFaction" }) do
        PROBE.dumpFnParams("/Script/SGameCombatSystem.FactionComponent:" .. f)
    end
    out("========== dump 结束 ==========")
end

local ENEMY = "Faction.Enemy"

local function makeHostileQuiet()
    local pup, p1 = puppet(), getP1()
    local fc = factionComp(pup)
    if not valid(fc) then out("!! 替身没有阵营组件"); return end
    local ok, err = pcall(function() return fc:SetFaction({ TagName = FName(ENEMY) }) end)
    local rel = "?"
    pcall(function() rel = tostring(factionComp(p1):GetFactionRelation(pup)) end)
    out("替身阵营 -> %s（SetFaction %s%s）；玩家1→替身 关系=%s（2=敌对）",
        factionName(pup), tostring(ok), ok and "" or (" " .. tostring(err)), rel)
end

-- v0.10.12 曾靠"每局重建第二玩家"让游戏补满药瓶；v0.13.0 改独立角色后不再有这个副作用，每局开始不再重建
MATCH.rebuildPuppet = nil
-- §238 对手替身生成 / 收起 = 对手连上 / 断开（换图后重新生成也算）：开战点标记跟着（事件，不轮询）
-- §247 红光 / 蓝光出招提示放大 ×3（钩子在 pbz_game.lua E.alertScaleHook）。替身生成时挂（那时技能蓝图肯定加载了），挂上一次就不再挂；
-- net/alert_scale_off.txt 存在 = 不放大（已挂的钩子不撤，只关开关）。全局表：main.lua 顶层 local 已满
ALS = { OFF = NET_DIR .. "/alert_scale_off.txt" }
function ALS.ensure(why)
    local f = io.open(ALS.OFF, "r")
    if f then f:close(); G.ALERT.on = false; return end
    G.ALERT.on = true
    if G.ALERT.hooked then return end
    local ok, r, info = pcall(G.alertScaleHook)
    if not ok then out("!! §247 出招提示放大挂钩子出错（%s）：%s", why, tostring(r))
    elseif not r then out("§247 出招提示放大（%s）：%s，下次替身生成再试", why, tostring(info)) end
end
MATCH.autoCreate = function(...)
    local r = table.pack(createPuppet(...))
    local ok, err = pcall(ARN.onOpponent, true)
    if not ok then out("!! 开战点标记出错：%s", tostring(err)) end
    pcall(ALS.ensure, "替身生成")
    return table.unpack(r, 1, r.n)
end
pcall(ALS.ensure, "模组加载")      -- 游戏里重载脚本时蓝图已加载，直接挂上；刚开游戏还没加载就等替身生成
MATCH.autoRemove = function(...)
    local r = table.pack(removePuppet(...))
    local ok, err = pcall(ARN.onOpponent, false)
    if not ok then out("!! 开战点标记出错：%s", tostring(err)) end
    return table.unpack(r, 1, r.n)
end

-- 对练期间替身不能死：血量低于 30% 就补满（掉血仍会照常记进日志）
local function keepPuppetAlive()
    local pup = puppet()
    if not valid(pup) then return end
    if NET.driving then return end   -- 联网时替身血量以对方回报为准，不自动补满
    local c = hpOf(pup)
    local m = attrOf(pup, "Health_Max")
    if c and m and c > 0 and c < m * 0.3 then
        setAttr(pup, "Health", m)
        out("替身血量 %.0f < 30%%，补满到 %.0f", c, m)
    end
end

local function makeHostile()
    local pup, p1 = puppet(), getP1()
    if not valid(pup) then out("!! 先按 F12 造替身"); return end
    out("===== 替身改敌对 =====")
    out("改前: 玩家1=%s 替身=%s", factionName(p1), factionName(pup))
    PROBE.relationProbe(p1, pup, "改前 玩家1→替身")
    local mon = valid(ST.testMonster) and ST.testMonster or findMonster()
    local vm = mon and factionValue(mon) or nil
    out("参照怪物: %s 阵营=%s", short(pathOf(mon)), mon and factionName(mon) or "?")
    if vm == nil then out("!! 场景里没找到怪物，先按 F12 生成一只"); return end
    local fc = factionComp(pup)
    local ok, err = pcall(function() return fc:SetFaction(vm) end)
    out("SetFaction -> %s %s", tostring(ok), ok and "" or tostring(err))
    out("改后: 替身=%s", factionName(pup))
    PROBE.relationProbe(p1, pup, "改后 玩家1→替身")
    PROBE.relationProbe(pup, p1, "改后 替身→玩家1")
    PROBE.relationProbe(mon, p1, "对照 怪物→玩家1")
    placeInFront(pup, PLACE_DIST)
    out("===== 完成：试试锁定替身、砍它，看日志有没有 [替身] ★ 血量 =====")
end

-- v0.6 实测按名字筛出来的前几个是 AM_Hun_Attack_Failed / *_HD_Attacker* 这类交互动画，不是真攻击；
-- 改成优先用你录制里出现过的 *_Attack_* 动画
local function attackCandidates()
    if ST.atkList and #ST.atkList > 0 then return ST.atkList end
    local list, seen = {}, {}
    for _, f in ipairs(RECM.loadRecording(REC_DIR .. "/last.txt") or {}) do
        if f.m:find("_Attack_") and not seen[f.m] then seen[f.m] = true; list[#list + 1] = f.m end
    end
    if #list > 0 then
        out("攻击动画候选 %d 个（来自最近录制）: %s", #list, table.concat(list, ", "))
    else
        montageByName("")
        for n in pairs(montages() or {}) do
            if n:match("^Hun_.+_Attack_[AB]+_Montage$") then list[#list + 1] = n end
        end
        table.sort(list)
        out("攻击动画候选 %d 个（没有录制，按 Hun_*_Attack_A/B 筛）", #list)
    end
    ST.atkList = list
    return list
end

local function testMontageAttack()
    local pup = puppet()
    if not valid(pup) then out("!! 先按 F12"); return end
    local list = attackCandidates()
    if #list == 0 then out("!! 没有候选动画"); return end
    ST.atkIdx = ST.atkIdx % #list + 1
    local name = list[ST.atkIdx]
    placeInFront(pup, 200.0)
    facePlayer(pup)
    local asset = montageByName(name)
    local r = asset and playOn(pup, asset)
    if r then pupAction(name, string.format("①a 动画 %d/%d 时长%.2fs", ST.atkIdx, #list, r))
    else out("!! 播放失败: %s", name) end
end

local function testAbility()
    local pup = puppet()
    if not valid(pup) then out("!! 先按 F12"); return end
    if not ST.abList then
        -- 只挑普攻连段（GA_Hun_<武器>_A/AA/B... _C），别去激活被动、处决、复活这类技能
        ST.abList = {}
        for _, a in ipairs(abilitiesOf(pup) or {}) do
            if a.name:match("^GA_Hun_%w+_[AB]+_C$") then ST.abList[#ST.abList + 1] = a end
        end
        local names = {}
        for _, a in ipairs(ST.abList) do names[#names + 1] = a.name end
        out("替身普攻技能 %d 个: %s", #ST.abList, table.concat(names, " "))
    end
    if #ST.abList == 0 then out("!! 替身没有可激活技能"); return end
    ST.abIdx = ST.abIdx % #ST.abList + 1
    local a = ST.abList[ST.abIdx]
    placeInFront(pup, 200.0)
    facePlayer(pup)
    local asc = ascOf(pup)
    local ok, r = pcall(function() return asc:TryActivateAbilityByClass(a.cls, true) end)
    pupAction(a.name, string.format("①b 技能 %d/%d 返回=%s", ST.abIdx, #ST.abList, ok and tostring(r) or ("错误 " .. tostring(r))))
end

local function spawnTestMonster()
    local p1 = getP1()
    local mon = findMonster()
    if not (valid(p1) and valid(mon)) then out("!! 场景里没有可复制的怪物"); return end
    local world = try("world", function() return p1:GetWorld() end)
    local cls = try("mon class", function() return mon:GetClass() end)
    local loc = try("p1 loc", function() return p1:K2_GetActorLocation() end)
    local rot = try("p1 rot", function() return p1:K2_GetActorRotation() end)
    if not (world and cls and loc and rot) then return end
    local r = math.rad(rot.Yaw)
    local pos = { X = loc.X + math.cos(r) * 400.0, Y = loc.Y + math.sin(r) * 400.0, Z = loc.Z + 50.0 }
    local a = try("spawn monster", function() return world:SpawnActor(cls, pos, rot) end)
    ST.testMonster = a
    ST.watch.mon = {}
    out("对照怪: %s 阵营=%s 血量=%s", short(pathOf(a)), factionName(a), tostring((hpOf(a))))
end

-- v0.17.7 斩马刀吸血比例实测（排查用，临时绑 F12）。说明里写着吸血"对人偶、金身、幻体无效"，替身大概被当成其中之一，
-- 所以先在单机打怪量出"怪掉多少血、我回多少血"，PvP 里再按对方回报的伤害由模组给自己补。
-- 怪用 Phantom Pact 的 cmd.txt：spawnenemy BP_Monster_MaleThug_Sword_Blue 300。每按一次走一步，血量变化看 [玩家1] / [对照怪] ★ 行
LO.ZM_STEPS = { "准备", "GA_Hun_ZhanMa_SWT_C", "GA_Hun_ZhanMa_A_C", "GA_Hun_ZhanMa_AA_C", "GA_Hun_ZhanMa_AAA_C",
                "GA_Hun_ZhanMa_AAAA_C", "GA_Hun_ZhanMa_AB_C", "GA_Hun_ZhanMa_B_C" }
function LO.zmProbe()
    local p1 = getP1()
    if not valid(p1) then return end
    LO.zmStep = (LO.zmStep or 0) % #LO.ZM_STEPS + 1
    local step = LO.ZM_STEPS[LO.zmStep]
    local mon = valid(ST.testMonster) and ST.testMonster or nil
    if step == "准备" or not mon then
        -- 离我最近的怪
        local best, bestD = nil, 1e12
        local a = try("zm loc", function() return p1:K2_GetActorLocation() end)
        for _, m in ipairs(FindAllOf("PBZCharacter") or {}) do
            if valid(m) and not sameObj(m, p1) and not sameObj(m, ST.secondPawn) and (hpOf(m) or 0) > 0 then
                local b = try("zm m", function() return m:K2_GetActorLocation() end)
                local d = (a and b) and ((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) or 1e12
                if d < bestD then best, bestD = m, d end
            end
        end
        ST.testMonster, ST.watch.mon = best, {}
        mon = best
        -- 第一轮（15:56）怪只有 500 血，切刀一下就死了，还一直打我：把怪的血抬到 30000、停掉它的 AI
        if valid(mon) then
            setAttr(mon, "Health_Max", 30000); setAttr(mon, "Health", 30000)
            pcall(function() mon:GetController().BrainComponent:StopLogic("PBZ_MP zm probe") end)
        end
        local hm = attrOf(p1, "Health_Max")
        if hm then setAttr(p1, "Health", hm * 0.5) end
        out("== 斩马刀吸血实测 准备：对照怪 %s（距离 %.0f，血量 %s），我的血量压到一半 %.1f ==",
            mon and short(pathOf(mon)) or "没有", math.sqrt(bestD), tostring(mon and hpOf(mon)), hpOf(p1) or -1)
        if step == "准备" then return end
    end
    -- 怪拉到我正前方 220、我转向它
    local a = try("zm loc", function() return p1:K2_GetActorLocation() end)
    local rot = try("zm rot", function() return p1:K2_GetActorRotation() end)
    if a and rot and valid(mon) then
        local r = math.rad(rot.Yaw)
        pcall(function() mon:K2_SetActorLocation({ X = a.X + math.cos(r) * 220, Y = a.Y + math.sin(r) * 220, Z = a.Z }, false, {}, true) end)
    end
    local cls
    for _, x in ipairs(abilitiesOf(p1) or {}) do if x.name == step then cls = x.cls end end
    local ok, r = false, "玩家身上没有这个技能"
    if cls then ok, r = pcall(function() return ascOf(p1):TryActivateAbilityByClass(cls, true) end) end
    out("== 斩马刀吸血实测 %d/%d：%s → %s；我 %.1f，怪 %s ==", LO.zmStep, #LO.ZM_STEPS, step,
        ok and tostring(r) or tostring(r), hpOf(p1) or -1, tostring(valid(mon) and hpOf(mon)))
end

-- ============================================================ 对手血条（v0.24.0，HANDOVER §68）
-- 用户 2026-11-05："能调用 boss 的血条杀气条的 ui 显示对手的血量和杀气状态么"。
-- 替身驱动中（联机、对方数据新鲜）就给替身注册一条游戏自带的 Boss 血条（PBZHUDLayout:RegisterBossHPBar），
-- 数值不靠血条自己听替身属性（替身杀气在本机每 10 帧补满，见 netStep），而是按对方回报直接写：
-- 血量 = hp / hpm，杀气 = sh / shm（对方旧版没有 sh= 就不写杀气），名字 = 对方昵称。
-- 血条 Init 时会绑替身的属性变化，替身属性一变它会把条拉回替身的值，所以替身的血量 / 杀气一变就重写一次，另外每秒兜底重写。
local OPPBAR = { on = true, actor = nil, bar = nil, at = 0.0, tries = 0, gaveUp = false, last = {}, pupHp = nil, pupSh = nil,
                 nameAt = nil }
OPPBAR.RETRY = 3.0            -- 注册后几秒内没找到血条就重新注册
OPPBAR.TRIES = 3              -- 连续几次找不到就放弃（重连 / 换替身后再试）

function OPPBAR.hide(why)
    if OPPBAR.actor then
        if OPPBAR.bar then pcall(G.bossBarShachiShow, OPPBAR.bar, true) end   -- v0.25.0 还回去：真 Boss 可能用同一个控件
        G.bossBarHide(OPPBAR.actor)
        out("对手血条：收起（%s）", why)
    end
    OPPBAR.actor, OPPBAR.bar, OPPBAR.last, OPPBAR.nameAt = nil, nil, {}, nil
end

function OPPBAR.name()
    -- §276.8（移植 0.33 分支 §269.9）主机下场（rly=）时对面是第一 / 第二位选手，lobby.txt 的 peername 是主机；用包里的 nm=（对方联机程序加的昵称）
    if NET.rrly and (NET.rnm or "") ~= "" then return NET.rnm end
    return M4.peerName() or M4.T("对手", "OPPONENT")
end

function OPPBAR.step(tn)
    local function clamp01(x) return math.max(0.0, math.min(1.0, x)) end
    local pup = puppet()
    local mode = NET.barMode()      -- v0.25.0 房间设置：2 血量+杀气 / 1 只显示血 / 0 不显示
    -- §276.8（移植 0.33 分支 §269.9）观战时不注册（11-13 内测日志：切到观战的同一秒晚到一个对战包、又生成了对战替身并注册血条，观战 A 认领到同一个控件，
    -- 1 秒后对手血条收起 → A 那条没了，22 分钟没名字 / 不扣血）。观战的两条血条归 pbz_spec 管
    local specOn = BASEHOOK.otherScene()      -- L3：观战（别的玩法占着对局）时不注册
    local want = OPPBAR.on and NET.driving and valid(pup) and not M4.ppOn() and mode > 0 and not specOn
    if not want then
        if OPPBAR.actor then
            OPPBAR.hide(not valid(pup) and "替身不在了" or (specOn and (BASEHOOK.title(specOn) .. "中")) or (M4.ppOn() and "Phantom Pact 连着")
                        or (mode == 0 and "房间设置不显示") or "对方数据中断")
        end
        OPPBAR.gaveUp, OPPBAR.tries = false, 0
        return
    end
    if OPPBAR.actor and not sameObj(OPPBAR.actor, pup) then OPPBAR.hide("换了替身") end
    if OPPBAR.gaveUp then return end
    -- 找血条；没有就（每 OPPBAR.RETRY 秒最多一次）注册
    -- v0.24.0 实机：给替身注册后 HUD 显示的是自己 WidgetTree 里那条 WB_BossHPBar，Character 一直是空的（没绑到替身）→
    -- 实例表里 Character 空的那条也认（真 Boss 的条都有 Character）
    -- 2026-11-05 [耗时]（§82.1）：替身的血条 Character 是空的，bossBarOf 每次都走 FindAllOf("WB_BossHPBar_C")，约 150 ms/秒。
    -- 找到后缓存，每 30 次驱动（约 1 秒）复核一次
    local bar = nil
    if OPPBAR.actor then
        if valid(OPPBAR.bar) and ST.ticks % 30 ~= 0 then bar = OPPBAR.bar else bar = G.bossBarOf(pup, true) end
    end
    if not bar then
        if OPPBAR.actor and tn - OPPBAR.at < OPPBAR.RETRY then return end    -- 刚注册，等 HUD 生成
        if OPPBAR.tries >= OPPBAR.TRIES then
            OPPBAR.gaveUp = true
            out("!! 对手血条：注册 %d 次都没找到血条，放弃（重连后再试）", OPPBAR.tries)
            return
        end
        if OPPBAR.actor then
            out("对手血条：注册后 %.0f 秒还没找到血条，诊断：", OPPBAR.RETRY)
            for _, l in ipairs(G.bossBarDiag(pup)) do out("  %s", l) end
        end
        OPPBAR.tries, OPPBAR.at = OPPBAR.tries + 1, tn
        local ok, err = G.bossBarShow(pup)
        OPPBAR.actor = ok and pup or nil
        OPPBAR.bar, OPPBAR.last, OPPBAR.nameAt = nil, {}, nil
        out("对手血条：注册第 %d 次 %s", OPPBAR.tries, ok and "成功" or ("失败：" .. tostring(err)))
        return
    end
    if not sameObj(bar, OPPBAR.bar) then
        OPPBAR.bar, OPPBAR.last, OPPBAR.nameAt, OPPBAR.tries = bar, {}, tn, 0
        out("对手血条：已显示（%s）", short(pathOf(bar)))
        if G.bossBarSweep then G.bossBarSweep(nil, { bar }) end     -- §443 同一个 HUD 上没人认领的空血条收起来
    end
    -- 替身自己的属性变了 → 血条被拉回替身的值了，重写
    local pHp, pSh = hpOf(pup), attrOf(pup, "Shachi")
    local dirty = pHp ~= OPPBAR.pupHp or pSh ~= OPPBAR.pupSh or ST.ticks % 30 == 0
    OPPBAR.pupHp, OPPBAR.pupSh = pHp, pSh
    local v, L = {}, OPPBAR.last
    if NET.remoteHp and NET.remoteHpm and NET.remoteHpm > 0 then
        local p = clamp01(NET.remoteHp / NET.remoteHpm)
        if dirty or not L.hp or math.abs(p - L.hp) > 0.0005 then v.hp = p end
    end
    -- v0.25.0 只显示血：杀气条藏起来（档位变了或血条被拉回时重做）；对方本来也不发杀气了
    local shOn = mode >= 2 or NET.rdummy == true      -- §456 木桩一律显示杀气条（用户 11-26"AI 木桩的杀气完全看不见"）
    if shOn ~= L.shOn or (dirty and not shOn) then
        if G.bossBarShachiShow(bar, shOn) then
            if shOn ~= L.shOn and L.shOn ~= nil or not shOn and L.shOn == nil then out("对手血条：杀气条%s", shOn and "显示" or "藏起（房间设置只显示血）") end
            L.shOn = shOn
        elseif not OPPBAR.shErr then
            OPPBAR.shErr = true
            out("!! 对手血条：藏 / 显示杀气条失败（WB_BossHPBar_C.BreakmeterBar 不在？）")
        end
    end
    if shOn and NET.rsh and NET.rshm and NET.rshm > 0 and NET.rsh >= 0 then
        local p = clamp01(NET.rsh / NET.rshm)
        if dirty or not L.sh or math.abs(p - L.sh) > 0.0005 then v.sh = p end
    end
    -- §276 诊断（0.33 内测"对方黄条一直是满的"）：每 15 秒记一次包里的杀气和写进血条的比例；该显示却没收到杀气记原因
    if tn - (OPPBAR.diagAt or -100) > 15.0 then
        OPPBAR.diagAt = tn
        local why = not shOn and ("档位 " .. tostring(mode) .. " 不显示杀气")
                    or (not NET.rsh and "包里没有 sq=（对方是 §276 之前的版本：杀气被联机程序当身份字段删了）")
                    or ((NET.rsh < 0 or not NET.rshm or NET.rshm <= 0) and "对方发的杀气 -1（对方那边的档位 < 2）") or nil
        out("对手血条诊断：血 %s/%s，杀气 %s/%s → 杀气条 %s；替身自己的杀气 %s",
            tostring(NET.remoteHp), tostring(NET.remoteHpm), tostring(NET.rsh), tostring(NET.rshm),
            why or string.format("写 %.2f", L.sh or v.sh or -1), tostring(pSh))
    end
    local name = OPPBAR.name()
    -- 名字：换了就写；血条刚出来 1 秒后再写一次（Init 可能晚于我们，把名字改回角色名）
    if name ~= L.name or (OPPBAR.nameAt and tn - OPPBAR.nameAt > 1.0) then
        v.name = name
        if OPPBAR.nameAt and tn - OPPBAR.nameAt > 1.0 then OPPBAR.nameAt = nil end
    end
    if v.hp or v.sh or v.name then
        if G.bossBarSet(bar, v) then
            L.hp, L.sh, L.name = v.hp or L.hp, v.sh or L.sh, v.name or L.name
            if v.name then out("对手血条：名字写成 %s", v.name) end
        elseif not OPPBAR.setErr then
            OPPBAR.setErr = true
            out("!! 对手血条：写数值失败（ForSeq_UpdateHealth / ForSeq_UpdateShachi / ForSeq_SetNameText）")
        end
    end
end

-- ============================================================ §406 破军冲锋减伤（改成真正削承伤倍率）

-- §406 破军冲锋减伤：改成真正削承伤倍率（§269.25 那版是给攻击方补攻击力，实测冲锋中 m=0 时无效，已整段撤掉）。
-- 资产：DB 挂 GE_PoJun_ChargeDamageReduction（Physical / ImpactShachi ×0.2）和 GE_StrongDefence（×0.7）；
-- 铸魂 Evolution 后 DB 还挂 GE_IgnoreAllDamage（五个承伤倍率 Override 0 = 完全免伤，实测起手约 1.8 秒）。
-- 做法：不撤 GE、也不动攻击力，只在冲锋期间把**挨打方自己**的承伤倍率当前值改成
--   m0 × (1 − r × keep)：m0 = 不在冲锋时的值（每 3 帧空闲时刷新，饰品 / 护体都算进去），
--   m = 冲锋中游戏算出来的值，r = 1 − m/m0 是原减伤，keep = 数值表 co= 的 PoJunDR（默认 0.25）。
--   只写 CurrentValue（BaseValue 不动，游戏重算时还能回到原样）；结束后写回 m0（游戏自己重算过就不写）。
-- 只在武器平衡开着（BAL.active）且交手中（NET.fighting）时做。另：结束后 0.3 秒还有 EndurePhase → 撤 GE（§269.25 的"用一次一直减伤"兜底）。
PJ = { GA = { GA_Hun_PoJun_DB_C = true, GA_Hun_PoJun_DB_02_C = true },
       ATTR = { "TakenReductionMultiplier_Physical", "TakenReductionMultiplier_Elemental", "TakenReductionMultiplier_ImpactShachi" },
       TAG = "CharacterState.AbilityState.PoJun.EndurePhase",
       GE = "/PBZCombatAsset/ActorData/Players/Hun/Weapon/PoJun/GE_PoJun_ChargeDamageReduction.GE_PoJun_ChargeDamageReduction_C",
       on = false, base = {}, want = {}, r = {}, checkAt = nil, logged = false, n = 0, removed = 0, skipped = 0 }
function PJ.keep()
    local v = tonumber(BAL.cost("PoJunDR"))
    if not v then v = 0.25 end
    if v < 0 then v = 0 elseif v > 1 then v = 1 end
    return v
end
function PJ.inCharge()
    local abs = ST.watch and ST.watch.p1 and ST.watch.p1.abs
    if type(abs) ~= "table" then return false end
    for n in pairs(PJ.GA) do if abs[n] then return true end end
    return false
end
-- 不在冲锋时刷新 m0（当前值 = 那时游戏算出来的承伤倍率）
function PJ.readBase(p1)
    for _, n in ipairs(PJ.ATTR) do
        local m = attrOf(p1, n)
        if type(m) == "number" and m > 0.001 then PJ.base[n] = m end
    end
end
function PJ.scale(p1)
    local keep, done = PJ.keep(), {}
    for _, n in ipairs(PJ.ATTR) do
        local m0, m = PJ.base[n], attrOf(p1, n)
        if m0 and type(m) == "number" and m < m0 - 0.0001 then
            if not PJ.want[n] or math.abs(m - PJ.want[n]) > 0.0001 then PJ.r[n] = 1 - m / m0 end
            local r = PJ.r[n] or 0
            local want = m0 * (1 - r * keep)
            PJ.want[n] = want
            if math.abs(m - want) > 0.001 then
                local ok = G.setAttrCur and G.setAttrCur(p1, n, want) or setAttr(p1, n, want)
                if ok then done[#done + 1] = string.format("%s %.2f→%.2f（原减伤 %.0f%%）",
                    (n:gsub("TakenReductionMultiplier_", "")), m, want, r * 100) end
            end
        end
    end
    if #done > 0 and not PJ.logged then
        PJ.logged = true
        out("§406 破军冲锋减伤：保留原减伤的 %.0f%%（co= PoJunDR）；%s", keep * 100, table.concat(done, "，"))
    end
end
-- 结束 / 中途改设置：把写过的那几个写回 m0（游戏自己重算过就不碰）
function PJ.clearWant(p1, restore)
    for _, n in ipairs(PJ.ATTR) do
        local w, m0 = PJ.want[n], PJ.base[n]
        if restore and w and m0 then
            local cur = attrOf(p1, n)
            if type(cur) == "number" and math.abs(cur - w) < 0.01 then
                if G.setAttrCur then G.setAttrCur(p1, n, m0) else setAttr(p1, n, m0) end
            end
        end
        PJ.want[n], PJ.r[n] = nil, nil
    end
end
function PJ.tagLeft(p1)
    if not (G.tagsMatching and valid(p1)) then return nil end
    local ok, t = pcall(G.tagsMatching, p1, { PJ.TAG })
    if not ok or type(t) ~= "table" or #t == 0 then return nil end
    return table.concat(t, ",")
end
function PJ.step(p1, tn)
    if not valid(p1) then PJ.on, PJ.want, PJ.r, PJ.checkAt = false, {}, {}, nil; return end
    if PJ.inCharge() then
        if not PJ.on then PJ.on, PJ.logged, PJ.n = true, false, PJ.n + 1 end
        if BAL.active() and NET.fighting() and PJ.keep() < 1 then
            if not next(PJ.base) then
                if PJ.skipped < 3 then
                    PJ.skipped = PJ.skipped + 1
                    out("§406 破军冲锋减伤：还没记到基础承伤（不在冲锋时没读到），这次不削")
                end
            else
                PJ.scale(p1)
            end
        elseif PJ.want[PJ.ATTR[1]] then
            PJ.clearWant(p1, true)      -- 打到一半把武器平衡关了 / 离开交手 / keep 改成 1：写回去
        end
    else
        if PJ.on then
            PJ.on = false
            PJ.clearWant(p1, true)
            PJ.checkAt = tn + 0.3
        end
        PJ.readBase(p1)
    end
    if PJ.checkAt and tn >= PJ.checkAt then
        PJ.checkAt = nil
        local left = PJ.tagLeft(p1)
        if left then
            PJ.removed = PJ.removed + 1
            out("§406 破军冲锋结束 0.3 秒后减伤还挂着（%s），撤掉（第 %d 次）", left, PJ.removed)
            LO.removeGE(p1, PJ.GE, "§406 撤破军冲锋减伤")
        end
    end
end
-- §406 end

-- ============================================================ 主循环

local function onTick()
    ST.ticks = ST.ticks + 1
    FMATCH.guard(CFG, "err", "数值表刷新", CFG.refresh, now())     -- §158 / §196 联机程序从大厅服务器拿到新数值表了没有（对局外、5 秒看一次文件头）
    local p1 = getP1()
    if valid(p1) and not STD.cleaned and ST.stableTicks > 30 then STD.cleanup() end     -- §144 上次没还原的强制配装
    if not valid(p1) then
        if ST.stableTicks > 0 then out("玩家角色不可用（读档/切图？），暂停") end
        if DAMAGEPARTS then DAMAGEPARTS.reset() end
        ST.stableTicks = 0
        REC.on = false
        RECM.stopReplay("玩家不可用")
        ST.setCache, ST.ascCache = {}, {}
        return
    end
    ST.stableTicks = ST.stableTicks + 1
    FMATCH.guard(STG, "err", "硬直开回输入", STG.frame, p1, now())   -- §228 硬直关输入：到时间 / 离开交手开回
    FMATCH.guard(ACC, "dgErr", "饰品诊断", ACC.diag, p1, now())    -- §170.3 饰品份数诊断
    FMATCH.guard(ACC, "duErr", "饰品去重", ACC.dedupe, p1, now())  -- §170.4 替身出来后我身上的饰品多一份 → 去掉
    if ST.stableTicks < 90 then return end
    if ST.secondPC ~= nil and not valid(ST.secondPC) then
        out("替身控制器失效（切图？），清掉")
        ST.secondPC, ST.secondPawn, ST.abList = nil, nil, nil
    end

    RECM.recordStep()
    RECM.replayStep()
    if SHADOWPASSIVES then FMATCH.guard(SHADOWPASSIVES, 'err', 'shadow passives', SHADOWPASSIVES.step, p1, now()) end
    if DAMAGEPARTS then FMATCH.guard(DAMAGEPARTS, 'err', 'damage part probe', DAMAGEPARTS.step, p1, now()) end
    netStep()
    FMATCH.guard(OPPBAR, "err", "对手血条", OPPBAR.step, now())
    if ST.uiProbeAt and ST.ticks >= ST.uiProbeAt then
        local tag = ST.uiProbeTag
        ST.uiProbeAt = nil
        local okU, errU = pcall(M4.uiProbe, tag)
        if not okU then out("!! 界面探针 -> %s", tostring(errU)) end
    end
    -- v0.10.9：v0.10.8 按 F2 时 UE4SS 报 "Ref was not function"，探针没跑；改成读档后约 10 秒自动跑一次
    if false and ST.stableTicks == 300 and not ST.medProbed then     -- v0.10.10：探针已跑过，关掉
        ST.medProbed = true
        local okP, errP = pcall(M4.medProbe2)
        if not okP then out("!! 药瓶探针2 -> %s", tostring(errP)) end
    end
    M4.step(p1, now())
    M4.zhanmaCheck()
    FMATCH.guard(ST, "ahErr", "自动出招", M4.autoHitStep)     -- §154 测试用自动出招（没有 autohit.on 时直接返回）
    FMATCH.guard(SUMMON, "err", "替身召唤物", SUMMON.step, p1, puppet(), now())
    pcall(CHFX.step, now())                        -- §242 混沌形态校验（补被门槛撤掉的 Buff / 特效）
    pcall(HLFX.step, now())                        -- §242 火流星 DB 大特效补播
    pcall(PRETRY.step, now())                      -- §242 等前摇（投剑 / 起跳 / 冲刺）再补放一次
    if ST.ticks % 10 == 0 and (UIM.mode == 1 or UIM.gameHidden) then pcall(UIM.tick) end     -- §314 界面三态：只在 1 档 / 还藏着时
    FMATCH.guard(CHAT, "err", "聊天", CHAT.step, now())     -- §112 聊天

    if ST.ticks % 3 == 0 then
        local monPrev = ST.watch.p1.montage
        watchActor("玩家1", p1, ST.watch.p1)
        FMATCH.guard(PJ, "err", "§406 破军冲锋减伤", PJ.step, p1, now())   -- 冲锋期间按 co= PoJunDR 改自己的承伤倍率
        -- 玩家1 当前武器 = 最近一次新激活的、能认出武器族的技能
        local abs = ST.watch.p1.abs
        if abs then
            local monNew = ST.watch.p1.montage ~= monPrev and ST.watch.p1.montage or nil
            for n in pairs(abs) do
                if not (ST.p1AbsPrev and ST.p1AbsPrev[n]) then
                    if monNew and isAttackAbility(n) then ANIM.learn(n, monNew) end    -- §100 同一次看到新招 + 新动作
                    if ZMC and n:find(ZMC.PAT) then FMATCH.guard(ZMC, "err", "§372 斩马刀自伤", ZMC.onAbility, n, now()) end   -- §372 事件触发补改 / 写回 / 单机重绑
                    local wid = weaponOfAbility(n)
                    if wid and wid ~= ST.p1Weapon then
                        ST.p1Weapon = wid
                        out("玩家1 当前武器 -> %s（依据 %s）", wid, n)
                    end
                end
            end
            ST.p1AbsPrev = abs
        end
        local pup = puppet()
        -- §82.4 替身 / 对照怪只为写诊断日志：每 9 次驱动看一次（玩家1 还是每 3 次，当前武器靠它）
        if pup and ST.ticks % 9 == 0 then watchActor("替身", pup, ST.watch.pup) end
        if ST.ticks % 9 == 0 and valid(ST.testMonster) then watchActor("对照怪", ST.testMonster, ST.watch.mon) end
    end
    if ST.ticks % 30 == 0 then
        hpTraceStep()
        keepPuppetAlive()
        if ZMC then FMATCH.guard(ZMC, "err", "§372 斩马刀自伤守门", ZMC.step, now()) end   -- §389.1 交手中补扫实例 / 虚血结算延后；对局外写回
        if REP.on and REP.lastErr then out("回放跟随误差 %.0f", REP.lastErr) end
    end
end

-- 旧版用 ExecuteWithDelay 链，回调跑在异步线程上，在那里碰 UObject 容易崩；
-- 这个 UE4SS 构建有 LoopInGameThreadWithDelay，直接在游戏线程循环
-- ---- 切图冻结（2026-11-05 09:07 实测崩溃，HANDOVER §72.2）
-- 传送 = 游戏先存档再加载新关卡，旧世界的对象在加载中被销毁。崩溃线程栈上有 UE4SS 的 Lua 调用：加载画面期间游戏线程仍会跑我们的
-- 定时循环（09:07:33 看门狗还重启了驱动），去碰替身 / 血条 / 输入这些旧对象 → 访问违例。所以传送前：藏替身、丢旧引用；
-- 之后所有循环（驱动、每帧输入、去暗杀、看门狗重启）什么都不做，直到新地图加载完（UE4SS 的 LoadMap 钩子，没有就等 25 秒）
-- 再过 3 秒、找到新的玩家1 且地图变了并稳定 1 秒，才恢复
M4.mapgo.LOADED_WAIT, M4.mapgo.NOHOOK_WAIT, M4.mapgo.OK_TICKS = 3, 25, 30
function M4.mapgo.freeze(target, from, pos)
    if HLFX then pcall(HLFX.clearFx, "切图") end   -- §246 走游戏传送 / 切图前先把补出来的火流星特效收掉（那时对象还有效）
    if valid(puppet()) and MATCH.autoRemove then MATCH.autoRemove() end
    MATCH.autoPup = nil
    ST.feed, ST.feedLeft = nil, 0
    ST.npcStore, ST.npcCtl, ST.p1pc, ST.testMonster = nil, nil, nil, nil   -- 旧世界的，新地图用不上
    OPPBAR.actor, OPPBAR.bar, OPPBAR.last, OPPBAR.nameAt = nil, nil, {}, nil
    ST.travel = { at = os.time(), target = target, from = from, loadedAt = nil, ok = 0, same = target == from, pos = pos }
    out("== 切图冻结：替身已藏起，加载完之前模组不碰游戏对象 ==")
end

-- §149 2026-11-08 08:51:34 崩溃：菜单里读档换了世界（不走上面的冻结），蓄力探针 CHG.list 里还留着上一个世界的替身
-- （对方 08:49:45 掉线时那一招没记完，CHG.step 只在驱动替身时跑），重新连上后 CHG.step → montageSection(w.actor) 读已销毁
-- 角色的 Mesh → UE4SS 里访问违例。加载钩子来了就把所有"跨帧记着的角色"丢掉；只清 Lua 状态，不碰任何游戏对象。
-- 旧世界的对象别指望 valid() 兜住：UE4SS 的 IsValid 也要先读对象自己的内存（序号），对象已释放时读到的是别的数据
function M4.forgetWorld()
    ST.secondPC, ST.secondPawn, ST.abList, ST.abIdx, ST.pupWeapon, ST.bareTest = nil, nil, nil, 0, nil, nil
    ST.watch.pup = {}
    ST.npcStore, ST.npcCtl, ST.p1pc, ST.testMonster = nil, nil, nil, nil
    MATCH.autoPup, MATCH.hold = nil, {}
    OPPBAR.actor, OPPBAR.bar, OPPBAR.last, OPPBAR.nameAt = nil, nil, {}, nil
    CHG.list, CHG.fired, CHG.LASER.beams, BOWN.wait = {}, {}, {}, {}
    LAT.pend, ANIM.pend, ZMX.cur = nil, nil, nil
    GCD.reset("换世界")          -- §184 只清 Lua 状态（记着的技能实例是旧世界的）
    DCD.reset("换世界")          -- §200
    STG.forget()                 -- §228 锁着的输入下一次 STG.frame 开回
    if CTRREC then CTRREC.reset() end -- Drop observations only; never touch old-world objects.
    if CTRD then CTRD.forget() end
    if SEG1121 then SEG1121.reset() end
    ARN.forget()                 -- §238 标记跟着旧世界没了；锁着的输入下一个事件开回
    if HLFX then pcall(HLFX.clear, "换世界", true) end   -- §246 换世界：只丢 Lua 引用，不碰旧世界对象（同 ARN.forget 的规矩）
    M4.forgetSafe()
    HOV.list, ULT.pend, SUMMON.mine, SUMMON.fc, SUMMON.fail = {}, {}, {}, {}, {}
    SUMMON.st = {}              -- §194.1
end

-- 驱动每次调：true = 冻结中（这次什么都不做）
function M4.mapgo.frozen()
    local tr = ST.travel
    if not tr then return false end
    local tc = os.time()
    if tc - tr.at > M4.mapgo.TIMEOUT then
        ST.travel = nil
        out("!! 切图冻结 %d 秒还没加载完，解除", tc - tr.at)
        return false
    end
    if tr.same then return M4.mapgo.frozenSame(tr, tc) end      -- §168.1 同地图走游戏传送
    local since = tr.loadedAt or (tc - tr.at >= M4.mapgo.NOHOOK_WAIT and tr.at + M4.mapgo.NOHOOK_WAIT - M4.mapgo.LOADED_WAIT) or nil
    if not since or tc - since < M4.mapgo.LOADED_WAIT then return true end
    if ST.ticks % 15 ~= 0 then ST.ticks = ST.ticks + 1; return true end     -- 加载后每 0.5 秒看一次
    ST.ticks = ST.ticks + 1
    ST.p1pc = nil
    local p1 = getP1()
    local m = valid(p1) and mapName(p1) or nil
    tr.ok = (m and m ~= tr.from) and tr.ok + 1 or 0
    if tr.ok < M4.mapgo.OK_TICKS / 15 then return true end
    ST.travel = nil
    ST.stableTicks = 0
    out("== 切图冻结解除：新地图 %s（用时 %d 秒）==", tostring(m), tc - tr.at)
    return false
end

-- §168.1 同地图走游戏传送的解冻：地图名不会变，没法按"换了地图"判断。游戏不一定重新加载整个世界——
-- 加载钩子来了：照切图等 LOADED_WAIT 秒；没来：至少等 SAME_MIN 秒（别在可能的世界切换中途碰对象）。
-- 然后玩家1 在落点 SAME_NEAR 以内、而且不在往下掉，连着 OK_TICKS → 解冻（之后 MAPGO.step 当作到达，放到主机身边 + 防掉落）
M4.mapgo.SAME_MIN, M4.mapgo.SAME_NEAR = 3, 5000.0
function M4.mapgo.frozenSame(tr, tc)
    local since = tr.loadedAt and tr.loadedAt + M4.mapgo.LOADED_WAIT or tr.at + M4.mapgo.SAME_MIN
    if tc < since then return true end
    if ST.ticks % 15 ~= 0 then ST.ticks = ST.ticks + 1; return true end
    ST.ticks = ST.ticks + 1
    ST.p1pc = nil
    local p1 = getP1()
    local loc = valid(p1) and try("same tp loc", function() return p1:K2_GetActorLocation() end) or nil
    local near = loc and tr.pos and math.sqrt((loc.X - tr.pos.X) ^ 2 + (loc.Y - tr.pos.Y) ^ 2) <= M4.mapgo.SAME_NEAR
    local st = near and G.airOf(p1) or nil
    tr.ok = (near and st and not st.falling) and tr.ok + 1 or 0
    if tr.ok < M4.mapgo.OK_TICKS / 15 then return true end
    ST.travel = nil
    ST.stableTicks = 0
    local pd = M4.mapgo.pending
    if pd and pd.same then pd.done = true end      -- §168.2 现在才算到达（MAPGO.step）
    out("== 同地图传送冻结解除（用时 %d 秒，%s）==", tc - tr.at, tr.loadedAt and "游戏重新加载了世界" or "没重新加载世界")
    return false
end

ST.SPLIT = true               -- §82.4 驱动拆两帧：这一帧收包 / 替身 / 对局，下一帧发包（netStep / NET.sendStep）
ST.TICK_SEC = 1 / 30          -- 驱动目标频率（很多地方按"30 次 = 1 秒"写的：ST.ticks % 30）
local function startDriver()
    ST.driverGen = ST.driverGen + 1
    local gen = ST.driverGen
    local function tick()
        if ST.driverGen ~= gen then return end
        ST.lastTickAt = os.time()
        if LOGBUF and #LOGBUF.lines > 0 and os.clock() - LOGBUF.at >= LOGBUF.SEC then LOGBUF.flush() end    -- §84 攒着的日志
        if M4.mapgo.frozen() then
            if ST.keyQueue and #ST.keyQueue > 0 then
                out("切图中，丢掉 %d 个按键", #ST.keyQueue)
                ST.keyQueue = {}
            end
            return
        end
        while ST.keyQueue and #ST.keyQueue > 0 do
            local job = table.remove(ST.keyQueue, 1)
            local okK, errK = pcall(job.fn)
            if not okK then out("!! %s -> %s", job.name, tostring(errK)) end
        end
        local ok, err = pcall(onTick)
        if not ok then out("!! tick -> %s", tostring(err)) end
        -- 实际频率（2026-11-05：录到的状态包只有 7.8 帧 / 秒）：每 10 秒记一次，每次加载记 3 次
        local r = ST.rate
        if not r then r = { at = os.clock(), n = 0, seq = NET.seq, logs = 0 }; ST.rate = r end
        r.n = r.n + 1
        local el = os.clock() - r.at
        if el >= 10 then
            if r.logs < 3 then
                r.logs = r.logs + 1
                out("驱动 %.1f 次 / 秒，发状态包 %.1f 个 / 秒", r.n / el, (NET.seq - r.seq) / el)
            end
            r.at, r.n, r.seq = os.clock(), 0, NET.seq
        end
    end
    -- F6 第二步：调度机制在 fornet 宿主（fornet_host.lua FORNET.loop.paced，和下面老路一字不差地搬过去）；没有宿主（老布局 / 测试）走下面老路
    if FORNET and FORNET.loop and FORNET.loop.paced then
        local mode = FORNET.loop.paced(ST.TICK_SEC, tick, function() return ST.driverGen == gen end, function()
            if NET.sendDue then          -- §82.4 上一次驱动剩下的发包：空帧里做；没有空帧（帧率 ≤ 30）就在这次驱动前补上
                local okS, errS = pcall(NET.sendStep)
                if not okS then out("!! 发包 -> %s", tostring(errS)) end
            end
        end)
        if mode == "frame" then out("driver gen=%d（游戏线程，每帧检查，约 %d 次 / 秒；宿主调度）", gen, math.floor(1 / ST.TICK_SEC + 0.5))
        elseif mode == "delay" then out("driver gen=%d（游戏线程；宿主调度）", gen)
        elseif mode == "async" then out("driver gen=%d（异步线程，兜底；宿主调度）", gen)
        else out("!! 没有可用的定时器") end
        return
    end
    -- 2026-11-05：以前用 LoopInGameThreadWithDelay(33)，只能在帧边界上触发、每次从触发时重新计时，实测只有约 15.6 次 / 秒
    -- （再每 2 次发一包 = 对面只收到 7.8 帧 / 秒，回放录像"掉帧"）。改成每帧检查、按时钟累加到点就跑：平均 min(帧率, 30) 次 / 秒
    if type(LoopInGameThreadAfterFrames) == "function" then
        local due = 0.0
        LoopInGameThreadAfterFrames(1, function()
            if ST.driverGen ~= gen then return true end      -- 看门狗重启了：旧的循环自己停
            local c = os.clock()
            if NET.sendDue then          -- §82.4 上一次驱动剩下的发包：空帧里做；没有空帧（帧率 ≤ 30）就在这次驱动前补上
                local okS, errS = pcall(NET.sendStep)
                if not okS then out("!! 发包 -> %s", tostring(errS)) end
                if c < due then return end
            end
            if c < due then return end
            due = (c - due > 0.1) and (c + ST.TICK_SEC) or (due + ST.TICK_SEC)   -- 落后太多（卡顿 / 加载）就不补
            tick()
        end)
        out("driver gen=%d（游戏线程，每帧检查，约 %d 次 / 秒）", gen, math.floor(1 / ST.TICK_SEC + 0.5))
        return
    end
    if type(LoopInGameThreadWithDelay) == "function" then
        LoopInGameThreadWithDelay(33, tick)
        out("driver gen=%d（游戏线程）", gen)
        return
    end
    if type(ExecuteWithDelay) ~= "function" then out("!! 没有可用的定时器"); return end
    local function chain()
        if ST.driverGen ~= gen then return end
        tick()
        pcall(function() ExecuteWithDelay(33, chain) end)
    end
    pcall(function() ExecuteWithDelay(1000, chain) end)
    out("driver gen=%d（异步线程，兜底）", gen)
end

-- 每帧给替身喂一次摇杆输入（方向由 drivePuppet 更新）。只做这一件事，保持轻量
local function startFeedLoop()
    if type(LoopInGameThreadAfterFrames) ~= "function" then
        out("!! 没有 LoopInGameThreadAfterFrames，替身跑步会抖")
        return
    end
    local frameLoop = (FORNET and FORNET.loop and FORNET.loop.frame) or function(fn) LoopInGameThreadAfterFrames(1, fn) end     -- F6：经宿主
    frameLoop(function()
        if ST.travel then return end    -- 切图冻结中（M4.mapgo.freeze）
        if (ST.feedLeft or 0) > 0 and ST.feed then
            ST.feedLeft = ST.feedLeft - 1
            local f = ST.feed
            if valid(f.pup) then pcall(function() f.pup:AddMovementInput(f.dir, f.scale, true) end) end
        end
        pcall(suppressLocalReact)   -- 也要每帧做：受击动作哪怕只播几帧也看得见
        pcall(BLK.frame)            -- §90.1 软格挡时玩家的受击动作换成格挡动作（只在可能软格挡时读动作）
        pcall(fixPuppetLockPoint)   -- 锁定点跟着替身走
        pcall(NPM.frame)            -- §128.1 全程跟网络位置：每帧把替身放过去
        if HMISS.open > 0 then pcall(HMISS.step) end      -- §385 对方的招有没有碰到我（只在有窗口开着时）
        pcall(M4.place)             -- 对局文字挂不上镜头时，每帧摆位
    end)
    ST.feedLoop = true
    out("每帧输入循环已启动")
end

local function startWatchdog()
    if type(LoopAsync) ~= "function" then return end
    local asyncLoop = (FORNET and FORNET.loop and FORNET.loop.async) or LoopAsync     -- F6：经宿主
    asyncLoop(2000, function()
        INST.beat()                    -- §147 双开：告诉第二份"我还在"
        local last = ST.lastTickAt or 0
        -- 切图加载时游戏线程本来就停着，这时重启驱动只会在加载中多跑一个循环（09:07:33 重启后 1 秒就崩了）
        if ST.travel then return false end
        if last > 0 and (os.time() - last) > 6 then
            -- §88 诊断（2026-11-05 15:32 游戏线程卡了 35 秒、没留下原因）：卡的时候是不是在等联机程序经管道回话
            out("!! 驱动停摆 %d 秒，重启%s", os.time() - last,
                (PIPE and PIPE.waiting) and ("（游戏线程卡在管道：" .. tostring(PIPE.waiting) .. "）") or "（不在管道读写里）")
            startDriver()
        end
        return false
    end)
end

-- v0.6 实测：游戏把 Ctrl 绑成了影之武装（铁矿拳套）攻击，每按一次 Ctrl+Fx 你都会出一拳，
-- 还顺手打伤了替身和对照怪。v0.6.1 起改成不带修饰键的 F 键（F9 留给 UHSMFF 的 Ctrl+F9，F10 是 UE4SS 控制台）
-- v0.12.2：按键回调不再经 ExecuteInGameThread（v0.10.8、v0.12.1 两次 UE4SS 报 "Ref was not function"，那次按键整个丢了），
-- 只往队列里放一条，由游戏线程上的驱动循环（33ms 一次，见 startDriver）取出来执行
ST.keyQueue = {}
-- quiet = true：不写"按键"日志（联机面板的方向键 / 回车平时玩游戏也会按，面板关着时什么都不做，不刷日志）
local function bind(key, fn, name, quiet)
    if type(fn) ~= "function" then out("!! 键 %s（%s）绑定的不是函数：%s", tostring(key), name, type(fn)) end
    if key == nil then out("!! 这个 UE4SS 没有键（%s），跳过", name); return end
    if FORNET and FORNET.modsys then FORNET.modsys.claimKey(FORNET.GAME or "pbz", key, name) end   -- L1 键位仲裁：先占上，玩法 mod 来抢会被拒
    RegisterKeyBind(key, function()
        if not quiet then out("按键 %s（%s）", tostring(key), name) end
        ST.keyQueue[#ST.keyQueue + 1] = { fn = fn, name = name }
    end)
end

NET.barLoad()        -- v0.25.0 对手血条档位（房间设置）
NET.boLoad()         -- v0.26.3 局数（房间设置）
NET.dmLoad()         -- §86 伤害倍率（房间设置，net/rules.txt 的 dm=）
NET.flagLoad()       -- §105.3 / §106.5 红蓝光反击 ctr=、武器平衡 bal=（房间设置）
NET.abLoad()         -- §87 全部可格挡（房间设置）
NET.resLoad()        -- §113 开局精纯杀气 ult0=、暗源 sp0=（房间设置）
NET.accBanLoad()     -- §176 禁用饰品 accban=
WBAN.load()          -- §180 禁用武器 wpnban= / 影之武装 edgeban=
out("v%s loaded，模组目录 %s（候选：%s；package.path=%s）", VERSION, ROOT, table.concat(ROOT_TRIED, " | "), tostring(package.path))

-- v0.11.7 菜单排查：给可能参与"按 Esc 开菜单"的函数挂钩子，被调用就记一行。
-- v0.11.6 实测：UI 管理器的 GetCommonLocalPlayer 全程都是玩家1，LocalPlayers 移除后恢复 1 个 → 推送目标没问题
local MENU_HOOKS = {
    "/Script/ProjectPBZ.PBZUIManagerSubsystem:PushCachedWidgetToLayer",
    "/Script/CommonGame.CommonUIExtensions:PushContentToLayer_ForPlayer",
    "/Script/CommonGame.CommonUIExtensions:PushStreamedContentToLayer_ForPlayer",
    "/Script/CommonUI.CommonActivatableWidgetContainerBase:BP_AddWidget",
    "/Script/Engine.PlayerController:Pause",
    "/Script/Engine.GameplayStatics:SetGamePaused",
}
-- 2026-11-05：这些是 v0.11.7 菜单排查留下的、早就不用了；09:07:34 切图崩溃那一秒 PushContentToLayer_ForPlayer 钩子刚触发过，关掉
ST.menuHooks = false        -- 不能再加顶层 local（main.lua 已到 200 个上限）
-- 切图冻结（M4.mapgo.freeze）靠它知道新地图加载完了：回调只记时间，不碰任何游戏对象
for _, nm in ipairs({ "RegisterLoadMapPostHook", "RegisterInitGameStatePostHook" }) do
    local fn = _G[nm]
    if type(fn) == "function" then
        local okH, errH = pcall(fn, function()
            if ST.travel and not ST.travel.loadedAt then ST.travel.loadedAt = os.time() end
            -- v0.27.12 一次加载两个钩子都会来：2 秒内只算一次（§93）
            local c = os.clock()
            if not ST.mapLoadAt or c - ST.mapLoadAt > 2 then ST.mapLoads = ST.mapLoads + 1 end
            ST.mapLoadAt = c
            BASEHOOK.emit("base.mapLoad")      -- L3：观战 mod 订阅（§141 旧世界的替身 / 镜头作废，只清 Lua 状态）
            M4.forgetWorld()       -- §149 菜单读档也换世界，不只是我们自己切图
        end)
        out("挂加载钩子 %s：%s", nm, okH and "成功" or ("失败 " .. tostring(errH)))
        if okH then M4.mapgo.loadHook = nm end
    end
end
if not M4.mapgo.loadHook then out("没有加载钩子：切图冻结改成等 %d 秒", M4.mapgo.NOHOOK_WAIT) end
if ST.menuHooks and type(RegisterHook) == "function" then
    for _, path in ipairs(MENU_HOOKS) do
        local name = path:match(":(.+)$")
        local ok, err = pcall(function()
            RegisterHook(path, function(ctx)
                local who = "?"
                pcall(function() who = short(pathOf(ctx:get())) end)
                out("【钩子】%s 被调用（对象 %s，当前本地玩家数 %s）", name, who,
                    tostring(ST.secondPC and valid(ST.secondPC) and 2 or 1))
            end)
        end)
        out("挂钩子 %s：%s", name, ok and "成功" or ("失败 " .. tostring(err)))
    end
end
-- ---- 耗时统计（2026-11-05 用户："联机时帧率从 60 掉到 30 左右"）：模组在游戏线程上每秒花多少毫秒、花在哪一步
-- 调用处一行不改：把要量的函数在这里换成"计时 + 原函数"（local 函数重新赋值后，所有引用它的闭包都跟着变；表里的函数换字段）。
-- os.clock 在 Windows 上是 QueryPerformanceCounter 的墙钟（不是 CPU 时间），够量毫秒以下的耗时。
-- 每帧数一次帧、记最长一帧；联机（远端数据 1 秒内新鲜）时每 REPORT_SEC 秒写一行"[耗时]"，没联机每 IDLE_SEC 秒。
-- 分项有嵌套："文件" / "日志" 算在调用它们的那一步里；"替身·*" "收包" "发包" 等算在"网络+替身"里；"网络+替身" 等算在"驱动合计"里
-- 全局（不是 local）：主代码块的 local 已满 200 个
-- F3c-2（docs/FORNET_SPLIT.md）：PROF 本体（计时 / wrap / 每帧统计 / 尖峰 / 报告）在 fornet_core.lua；这里给它游戏这边的三样 + 要包的函数
PROF = FN.PROF
PROF.setTop({ "驱动合计", "驱动·发包帧", "每帧·压受击", "每帧·锁定点", "每帧·摆文字" })
PROF.online = function() return NET.pos and NET.lastRecvAt and (now() - NET.lastRecvAt < 1.0) end
PROF.frozen = function() return ST.travel end
PROF.tag = TAG
out = PROF.wrap("日志", out)
fileWrite, fileReadKV = PROF.wrap("文件·写", fileWrite), PROF.wrap("文件·读", fileReadKV)     -- §82.7 读写分开记（读刚被联机程序替换的文件要等杀毒扫描）
onTick = PROF.wrap("驱动合计", onTick)
NET.sendStep = PROF.wrap("驱动·发包帧", NET.sendStep)
PIPE.send, PIPE.recv = PROF.wrap("·管道发", PIPE.send), PROF.wrap("·管道收", PIPE.recv)     -- §83
RECM.recordStep, RECM.replayStep, netStep = PROF.wrap("录制", RECM.recordStep), PROF.wrap("回放", RECM.replayStep), PROF.wrap("网络+替身", netStep)
netRecv, netJudge, netSend = PROF.wrap("收包", netRecv), PROF.wrap("判定", netJudge), PROF.wrap("发包", netSend)
drivePuppet, protectPuppet = PROF.wrap("替身·移动", drivePuppet), PROF.wrap("替身·保护", protectPuppet)
watchActor, hpTraceStep, keepPuppetAlive = PROF.wrap("观察角色", watchActor), PROF.wrap("血量跟踪", hpTraceStep), PROF.wrap("替身保活", keepPuppetAlive)
suppressLocalReact, fixPuppetLockPoint = PROF.wrap("每帧·压受击", suppressLocalReact), PROF.wrap("每帧·锁定点", fixPuppetLockPoint)
REL.poll, OPPBAR.step = PROF.wrap("可靠事件", REL.poll), PROF.wrap("对手血条", OPPBAR.step)
AIR.step, LAT.step = PROF.wrap("替身·空中", AIR.step), PROF.wrap("替身·追帧", LAT.step)
LO.apply, LO.guard, LO.dress, LO.syncPas = PROF.wrap("替身·属性", LO.apply), PROF.wrap("替身·武器守护", LO.guard), PROF.wrap("替身·换装", LO.dress), PROF.wrap("替身·被动", LO.syncPas)
SUMMON.step = PROF.wrap("替身·召唤物", SUMMON.step)
-- §194.2 召唤物段的分项：扫描（FindAllOf 阵营组件）/ 设阵营 / 读阵营（所有调 factionName 的地方都算）
G.factionActors, SUMMON.set = PROF.wrap("·召唤物扫描", G.factionActors), PROF.wrap("·召唤物设阵营", SUMMON.set)
factionName = PROF.wrap("·读阵营", factionName)
-- §205 onTick 里以前没分项的几段（"单帧尖峰只有驱动合计"查不出是谁）
ACC.diag, ACC.dedupe, ACC.snap, ACC.orphans = PROF.wrap("饰品诊断", ACC.diag), PROF.wrap("饰品去重", ACC.dedupe), PROF.wrap("·饰品扫描", ACC.snap), PROF.wrap("·饰品孤儿", ACC.orphans)
CFG.refresh, CHAT.step, M4.autoHitStep, STD.cleanup = PROF.wrap("数值表刷新", CFG.refresh), PROF.wrap("聊天", CHAT.step), PROF.wrap("自动出招", M4.autoHitStep), PROF.wrap("标准数值清理", STD.cleanup)
M4.step, M4.place, M4.zhanmaCheck = PROF.wrap("对局", M4.step), PROF.wrap("每帧·摆文字", M4.place), PROF.wrap("斩马检查", M4.zhanmaCheck)
-- §82.1 底层调用（名字带"·"开头，被上面各步嵌套）
activeAbilities, montageOf = PROF.wrap("·技能列表", activeAbilities), PROF.wrap("·当前动作", montageOf)
hpOf, attrOf = PROF.wrap("·读属性", hpOf), PROF.wrap("·读属性", attrOf)
G.bossBarOf = PROF.wrap("·找血条", G.bossBarOf)
LO.encode, LO.encodePas, LO.heldConfig = PROF.wrap("·编码属性", LO.encode), PROF.wrap("·编码被动", LO.encodePas), PROF.wrap("·武器配置", LO.heldConfig)
PROF.start()

startDriver()
startWatchdog()
startFeedLoop()
-- F6 第二步：游戏适件接口表（docs/FORNET_ADAPTER.md 第 4 节）。放在这里是因为这些函数在这之后的块里看不见（主块 local 的作用域）
if FORNET then
    FORNET.adapter = {
        name = "pbz", version = VERSION,
        tick = onTick,                    -- 每拍（宿主 FORNET.loop.paced → startDriver 的 tick → onTick）
        makePacket = netSend,             -- (p1, tn) 生成并发出我的状态包
        applyPacket = netRecv,            -- (p1, tn) 收对方的包、驱动替身
        spawnPuppet = createPuppet,       -- () 生成替身
        removePuppet = removePuppet,      -- () 收起替身
        matchDeps = function() return { step = FMATCH.stepDeps, follow = FMATCH.followDeps } end,     -- 对局判定钩子（倒下 / 关输入 / 归位 …）
        onMapChange = function(...) return M4.mapgo.freeze(...) end,     -- 切图：先冻结、藏替身、丢旧引用（MAPGO 是 M4 闭包里的 local，这里经 M4.mapgo 拿）
    }
    -- L1（docs/FORNET_LAYERS.md）：玩法 mod 的日志进 mp_probe.log、按键回调进同一个游戏线程队列
    if FORNET.modsys then
        FORNET.modsys.bindAdapter({ out = out, enqueue = function(fn, name) ST.keyQueue[#ST.keyQueue + 1] = { fn = fn, name = name } end })
    end
    -- L2 / L3：基础联机包对其他玩法 mod 提供的服务（快路线：先给现成的表，瘦身时再收窄）
    if FORNET.provide then
        local prov = FORNET_BASE and FORNET_BASE.provide or function(n, t) return FORNET.provide(n, t) end
        prov("ui", {          -- 面板：往首页 / 系统设置加行、往"已装的玩法"页自己那一栏加说明；文案 / 命令 / 提示经 EXTCTX
            addRows = function(pageId, fn, owner) return BASEUI.addRows(owner or "?", pageId, fn) end,
            addModRows = function(owner, fn) return BASEUI.addModRows(owner, fn) end,
            addPage = function(d, owner) return BASEUI.addPage(owner or "?", d) end,      -- 整页：{ id, title, titleEn, build(items, T, lb, page) }，返回页 id
            addConsent = function(d, owner) return BASEUI.addConsent(owner or "?", d) end,  -- 11-14：玩法 mod 自己的同意项（manifest 也写 consent=@<键>）
            go = function(pageId) return BASEUI.go(pageId) end,                            -- 翻到某页（加在首页 / 系统设置的行用它进自己的页）
            T = function(zh, en) local X = EXTCTX; return (X and X.T) and X.T(zh, en) or zh end,
            cmd = function(c, extra) local X = EXTCTX; if X and X.netuiCmd then return X.netuiCmd(c, extra) end end,
            flash = function(s) local X = EXTCTX; if X and X.netuiFlash then return X.netuiFlash(s) end end,
        })
        prov("match", FMATCH)          -- 对局框架实例（回合状态机 / 规则指纹 / 时限）
        prov("pvp", { ST = ST, MATCH = MATCH, NET = NET, G = G, LO = LO, activate = RECM.activateOnPuppet, out = out, version = VERSION,
                      hook = BASEHOOK,                                                         -- L3 基础联机包发出的事件（名字见 BASEHOOK 定义处）
                      driverCtx = function() return BASEX.driverCtx() end,                    -- 观战这类"自己驱动替身"的 mod 用
                      multiCtx = function() return BASEX.multiCtx() end,                      -- L5：多人 mod 构造用的上下文
                      rankedCtx = function() return BASEX.rankedCtx and BASEX.rankedCtx() end,   -- 排位客户端要的面板 / 对局表
                      panelOpen = function() return M4.panelOpen() end,
                      multi = function() return BASEHOOK.mp end, setMp = BASEHOOK.setMp })
    end
end
startNoStealthLoop()
pcall(M4.netui, "autostart")   -- v0.18.5：一加载就在后台拉起联机程序，不用等打开面板

-- v0.17.1：键位避开 Phantom Pact 的 F3 / F4 / F5（见文件开头）。旧键位：F3 造替身、F1 状态、F2 探针、F4 准备、F5 存场地
bind(Key.F12, createPuppet, "造替身")      -- v0.17.8：F11 是游戏的全屏切换，改 F12（Steam 会顺带截图）
bind(Key.F9, PROBE.status, "状态")
-- v0.9.21 实测：方案 A 三个标签 CanActivateNewState 全 false（不是状态机状态），已排除。
-- F4 按下后方案 B 一行日志都没有、也无报错（用户看到角色播了受击动画）—— 改用确定可用的 F2
-- v0.10.8：F2 = 药瓶探针 2（只读）。Respawn Recover Attributes 实测不补药瓶
-- v0.13.5：F2 不绑定。斩马刀实验（会把玩家血量压到一半）只在排查时临时绑：bind(Key.F2, M4.zhanmaTest, "斩马刀对比实验")
-- v0.15.1：F2 = 共享数据探针（只读）。结果：两人的武器组件 / UI 逻辑组件各是各的实例
-- v0.15.2 换装实验（13:22 Claude 自测，结论见 HANDOVER §28）会改玩家的装备槽，只在排查时临时绑：
--   bind(Key.F2, M4.swapTest, "换装实验")
-- v0.16.0 排查用（会改玩家装备，只在排查时临时绑）：bind(Key.F2, LO.debugSwap, "排查：模拟玩家换武器")
-- v0.17.1：F2 让给存场地，探针不再常驻；排查时临时绑一个空键：bind(Key.<键>, M4.shareProbe, "共享数据探针")
-- 多人混战 ②d：多人房间里 F1 = 主机开始 / 结束多人对局（pbz_multi.lua）；不在多人房间照旧是 1v1 的准备 / 弃权
bind(Key.F1, function() if not BASEHOOK.ask("base.f1") then M4.start() end end, "准备 / 弃权")     -- L5：多人房里多人 mod 接走
-- v0.10.2：被格挡硬直早已按武器自动选，F5 改成存场地
bind(Key.F2, M4.saveArena, "存 PvP 场地")
bind(Key.F7, RECM.toggleRecord, "录制")
bind(Key.F8, RECM.startReplay, "回放")
-- v0.11.2：F6 = 移除替身、回到单人。用户确认（2026-11-04）：F3 造第二玩家后游戏菜单打不开，F3 之前正常；
-- 独立角色（F2 实验）菜单正常但打不出伤害、浮在半空，用户决定继续用 2P，需要一个回到单人的办法
-- v0.17.6 debuff 排查（HANDOVER §36），排查时临时绑一个空键：bind(Key.<键>, LO.debuffTest, "排查：debuff 图标")
-- v0.17.7 斩马刀吸血实测（HANDOVER §37），排查时临时绑一个空键：bind(Key.<键>, LO.zmProbe, "排查：斩马刀吸血实测")
bind(Key.F6, function()
    RECM.stopReplay("手动停止")
    if MATCH.role then M4.start() end            -- 对局中先中止（M4.start 在对局中 = 中止）
    if valid(puppet()) then
        removePuppet()
        out("已移除替身，回到单人。请试试菜单能不能打开")
    else
        out("没有替身")
    end
end, "移除替身")
-- net-ui 游戏内联机面板（docs/NETWORK_UI.md §2.4）。F1–F12 都被占了（F3/F4/F5 Phantom Pact、F10 控制台、F11 全屏），
-- Insert 被 BPModLoaderMod 占，Ctrl+小键盘 5–9 / Ctrl+H 被 UE4SS Keybinds 占 → Home。
-- 面板开着时：PgUp/PgDn 选择，End 确定（选中"连接方式"那行按 End = 换下一种）；面板关着时这些键什么都不做。
-- v0.18.4：去掉方向键和回车——17:09 实测面板开着按 ↑↓ 角色会转身（yaw 159.7 → −20.3），方向键是游戏的移动键；
-- 回车没测过，同样可能被游戏用。PgUp / PgDn / End 实测不影响角色（HANDOVER §42）
bind(Key.HOME, function() M4.netui("toggle") end, "联机面板")
bind(Key.P, function() M4.netui("ptoggle") end, "联机面板 P")
-- §112 / §250.4 快捷语：Delete（输入框里按 Delete 是删字，CHAT.open 自己跳过）
bind(Key.DEL, function() CHAT.open(false) end, "快捷语")
bind(Key.INS, function() UIM.next("Insert") end, "界面三态")       -- §314 3 全显示 → 2 只留游戏界面 → 1 全藏
-- ============================================================ §223.8 鬼魅闪身诊断（只读） / §229 替身放不出红光反击 / 鬼魅闪身
-- 全局表（最外层 local 已经很多，不再加）
-- §342 招式伤害统计（base_dstat.lua；面板页 "dstat"，在本地 AI 那两页里进）
-- §352 本地 AI 按真人那套：我还在放的招（act=）、替身挨打 / 被控（pst=）（base_aisync.lua）
AISYNC = BASEPARTS.load("aisync", { out = function(...) return out(...) end, NET = NET, ST = ST, G = G, isAttackAbility = isAttackAbility,
    dummyStay = function() return TRAINCTX ~= nil and TRAINCTX.stay() end,     -- §456 木桩什么时候报 trainPos=
    attrOf = function(...) return attrOf(...) end })      -- §353 psq=：替身本机杀气
DSTAT = BASEPARTS.load("dstat", { out = function(...) return out(...) end, NET = NET, G = G,
    touchTotal = function(id) return (TOUCH.dmg and TOUCH.dmg[id]) or (TOUCH.lingerDmg and TOUCH.lingerDmg[id]) end })     -- §342.4 T / 颜色模块里经 EXTCTX 现取（这里的 T / COL_* 是 nil）
TRAINUI = BASEPARTS.load("training_ui", {
    command = function(...) local X = EXTCTX; if X and X.netuiCmd then return X.netuiCmd(...) end end,
    training = function() return TRAINING end, now = function() return now() end,     -- §456 木桩页的无限 HP；拖动条计时
    status = function() return NET.rtrainUnsupported end })
TRAINCTX = {}
function TRAINCTX.roomScope()
    local X = EXTCTX
    local lb = X and X.NETUI and X.NETUI.lobby or {}
    local known = lb.mode ~= nil and lb.mode ~= ""
    local ranked = lb.mode == "ranked" or lb.rk == "1"
    return { enabled = known and not ranked, training = known and not ranked, ranked = ranked }
end
function TRAINCTX.scope()
    local mp = BASEHOOK.mp
    if mp and mp.inMp and mp.inMp() and mp.trainingScope then return mp.trainingScope() end
    local X = EXTCTX
    local lb = X and X.NETUI and X.NETUI.lobby or {}
    local ai = lb.mode == "ai" and lb.rk ~= "1" and NET.rai ~= false
    return { kind = "local_ai", enabled = ai, training = ai, ranked = not ai, authoritative = true,
        spectator = false, localSlot = 1, session = ai and ("ai:" .. tostring(MATCH.id or 0)) or nil }
end
function TRAINCTX.emptyBreak(pup)
    if not (TRAINING and TRAINING.allowed() and NET.rdummy and MATCH.state == "fight"
        and NET.rtrainChi == "empty" and not NET.rtrainAiChi) then
        TRAINCTX.emptyBreakToken = nil
        return
    end
    if not valid(pup) then return end
    local token = tostring(MATCH.id) .. ":" .. tostring(MATCH.round) .. ":" .. pathOf(pup)
    if TRAINCTX.emptyBreakToken == token then return end
    TRAINCTX.emptyBreakToken = token
    setAttr(pup, "Shachi", 0)
    local ok = RECM.activateOnPuppet(pup, "GA_Hun_BreakEscape_C", NET.sub, "木桩空杀气破防")
    if not ok then out("木桩空杀气：本轮破防技能未激活，不重复强制播放") end
end
-- ============================================================ §456 木桩（用户 11-26 新功能单）
-- 木桩的杀气以替身为准（psq=，§353）。替身在你游戏里并没有真的举架势挡下（替身没有输入，架势技能撑不住），
-- 普防是联机程序判的 → 游戏不扣替身杀气，杀气条一直满、格挡也永远不会被打破（"杀气完全看不见"）。
-- 普防结果回来时，最近 BLOCK_SEEN 秒里替身杀气没掉过（游戏自己没扣）就由模组扣 BLOCK_CHI（同联机程序 §353 之前的模型）；
-- 扣到 0 播破防（同"清空（破防）"那条路）。杀气锁满（无限杀气）时不扣
TRAINCTX.BLOCK_CHI, TRAINCTX.BLOCK_SEEN = 300, 0.6
function TRAINCTX.on() return NET.rdummy == true and TRAINING ~= nil and TRAINING.allowed() end
function TRAINCTX.blockChi(pup, tn)
    if not TRAINCTX.on() or NET.rtrainChi == "locked" or not valid(pup) then return nil end
    if not (AISYNC and AISYNC.ownShachi and AISYNC.ownShachi()) then return nil end
    if TRAINCTX.chiDropAt and tn - TRAINCTX.chiDropAt < TRAINCTX.BLOCK_SEEN then return "游戏已扣替身杀气" end
    local cur = attrOf(pup, "Shachi")
    if type(cur) ~= "number" then return nil end
    local after = math.max(0, cur - TRAINCTX.BLOCK_CHI)
    setAttr(pup, "Shachi", after)
    TRAINCTX.chiSeen, TRAINCTX.chiFloor = after, after
    if after <= 0 then
        local ok = RECM.activateOnPuppet(pup, "GA_Hun_BreakEscape_C", NET.sub, "木桩普防杀气打空")
        return string.format("木桩普防扣杀气 %.0f → 0，破防%s", cur, ok and "" or "（破防技能没激活）")
    end
    return string.format("木桩普防扣杀气 %.0f → %.0f", cur, after)
end
-- 每收一包（NET.recvOne）：① 记替身杀气什么时候掉过；② 杀气"损耗后不恢复"（trainChi=normal）：交手中只许往下走；
-- ③ 精纯杀气 / 暗源：无限 = 一直补满；N 个 = 每回合（换回合 / 改设置时）定成 N、之后不补（大招 / 影之武装用掉就没了）
function TRAINCTX.packet(pup, tn)
    if not (TRAINCTX.on() and valid(pup)) then TRAINCTX.chiFloor, TRAINCTX.chiSeen, TRAINCTX.resTok = nil, nil, nil; return end
    local cur = attrOf(pup, "Shachi")
    if type(cur) == "number" then
        -- §456.2 完美招架：替身没举架势也会被游戏按中招 / 普通格挡扣杀气（每刀约 300；11-26 实测 800 → 500 → 51 → 0 破防），
        -- 而一套连段只回一次"精防"结果、回来时杀气已经扣了。完美招架本来每刀都精防、不该掉杀气 → 交手中掉的杀气一律补回
        -- （包括被不可防御招打中那几下；木桩自己出招一般用精纯杀气 / 暗源，不吃杀气）
        if NET.rtrainGuard == "perfect" and MATCH.state == "fight" and TRAINCTX.chiSeen and cur < TRAINCTX.chiSeen - 0.5 then
            setAttr(pup, "Shachi", TRAINCTX.chiSeen)
            TRAINCTX.parryKept = (TRAINCTX.parryKept or 0) + 1
            if TRAINCTX.parryKept <= 5 then out("§456.2 木桩完美招架：游戏扣的杀气 %.0f → %.0f 补回（第 %d 次）", TRAINCTX.chiSeen, cur, TRAINCTX.parryKept) end
            cur = TRAINCTX.chiSeen
        end
        if TRAINCTX.chiSeen and cur < TRAINCTX.chiSeen - 0.5 then TRAINCTX.chiDropAt = tn end
        if NET.rtrainChi == "normal" and MATCH.state == "fight" then
            if TRAINCTX.chiFloor and cur > TRAINCTX.chiFloor + 0.5 then setAttr(pup, "Shachi", TRAINCTX.chiFloor); cur = TRAINCTX.chiFloor
            else TRAINCTX.chiFloor = cur end
        else TRAINCTX.chiFloor = nil end
        TRAINCTX.chiSeen = cur
    end
    TRAINCTX.resTok = TRAINCTX.resTok or {}
    for _, r in ipairs({ { "UltimateChargeCount", NET.rtrainUlt }, { "SpiritShadow", NET.rtrainSp } }) do
        local attr, want = r[1], r[2]
        local c, mx = attrOf(pup, attr), attrOf(pup, attr .. "_Max")
        if want == "normal" then
            TRAINCTX.resTok[attr] = nil      -- 11-26 AI 木桩 V2"通常"：不补也不定数，按游戏原样
        elseif type(c) == "number" and type(mx) == "number" and mx > 0 then
            if want == nil or want == "inf" then
                if c < mx then setAttr(pup, attr, mx) end
                TRAINCTX.resTok[attr] = nil
            else
                local n = math.min(tonumber(want) or mx, mx)
                local tok = tostring(MATCH.id) .. ":" .. tostring(MATCH.round) .. ":" .. tostring(want)
                if TRAINCTX.resTok[attr] ~= tok then
                    TRAINCTX.resTok[attr] = tok
                    if math.abs(c - n) > 0.01 then setAttr(pup, attr, n) end
                    out("§456 木桩%s：定成 %d 个（第 %s 回合，原来 %.0f，上限 %.0f）", attr == "SpiritShadow" and "暗源" or "精纯杀气", n, tostring(MATCH.round), c, mx)
                end
            end
        end
    end
end
-- 精纯杀气是有限个数时，替身放大招不再自动补 1 格（ULT.topUp）
function TRAINCTX.ultCapped() return TRAINCTX.on() and NET.rtrainUlt ~= nil and NET.rtrainUlt ~= "inf" end
-- §456 自动归位（用户 11-26）：准备后进入对局的那一下（第 1 回合倒计时）归位一次，之后不再归位
function TRAINCTX.returns(round) return NET.rdummy == true and NET.rtrainReturn ~= false and (round or 1) <= 1 end
-- 木桩站在游戏把它放的地方（不归位、不跟随）：除了第 1 回合倒计时（开了自动归位时）那一下，一直如此
function TRAINCTX.stay() return NET.rdummy == true and not (MATCH.state == "cd" and TRAINCTX.returns(MATCH.round)) end
TRAINING = BASEPARTS.load("training", { G = G, DSTAT = DSTAT, NET_DIR = NET_DIR,
    dummy = function() return NET.rdummy == true end,     -- §456
    T = function(a, b) local X = EXTCTX; return X and X.T and X.T(a, b) or a end,
    scope = TRAINCTX.scope,
    members = function()
        local mp = BASEHOOK.mp
        if mp and mp.inMp and mp.inMp() and mp.trainingMembers then return mp.trainingMembers() end
        return {}
    end,
    actors = function()
        local mp = BASEHOOK.mp
        if mp and mp.inMp and mp.inMp() and mp.trainingActors then return mp.trainingActors() end
        return { { actor = puppet(), kind = "ai" } }
    end,
    onConfig = function(cfg, wire)
        local X, s = EXTCTX, TRAINCTX.scope()
        if X and X.netuiCmd and s.kind == "local_ai" and s.authoritative then X.netuiCmd("aicfg", wire) end
    end })

DIAG = BASEPARTS.load("diag", { ST = ST, NET_DIR = NET_DIR, G = G,
    isAttackAbility = isAttackAbility, playNamed = playNamed, dge = function() return DGE end,
    -- 主循环那段会把这几个换成计时包装（PROF.wrap）：传"调用时再取"，和搬出来之前一样
    out = function(...) return out(...) end, hpOf = function(...) return hpOf(...) end, montageOf = function(...) return montageOf(...) end })

-- ============================================================ §223 观战：两个替身各自完整走对战替身那一套
-- 用户 11-10："观战理论上就应该是两个替身完整的播放自己的事实状态。对战时候是一个替身一个自己"。
-- 对战替身收包（NET.recvOne）和驱动（NET.drive）的状态散在 NET / ST / LO 和各模块表里，只有一份（给唯一的对手用）。
-- 观战的每个替身一份：PEER.new 时把这些表的字段深拷一份；PEER.run 时把这一份换进去、跑完换回来（只换字段，表本身不换，
-- 函数里引用的还是同一张表）。跑的时候 PEER.on = true：不判定、不回报、不改攻击力；"你"（锁定、瞄准、光柱）= 另一个替身（PEER.tgt）。
-- 全局（主代码块 local 已满 200 个）
PEER = { on = false, cur = nil,
         MODS = { "NET", "AIR", "DGE", "DDIR", "INF", "CHG", "ANIM", "ZMX", "BOWN", "BOWAIM", "BOWEYE", "ULT", "PHEAL", "LAT", "PRED",
                  "NPM", "RMS", "SUMMON", "PUPFC" },
         -- ST / LO 太大、大部分是本机自己的：只换替身用的这些
         STK = { "ticks", "secondPC", "secondPawn", "pupAtkAt", "lockSetKey", "lockAim", "lockLogAt", "lockLogs", "pupEdgeAt",
                 "pupWeapon", "summonArmAt", "lastPupAction", "abMap", "abMapKey", "pupHpSeen", "failN", "dashCd", "cutForNew",
                 "cancelForNew", "unarmForNew", "snapAlt", "dressForSwt", "armForNew", "alreadyOn", "swtDiag", "snapLockN",
                 "protectedFor", "reequipIn", "feed", "feedLeft", "inputOpenFor", "speedFor", "lagSince", "heldSnaps", "holdLogAt",
                 "snaps", "snapLogAt", "lockFixLogged", "pupOwnName", "pupOwnFrames", "pupFell", "chaosTry", "swtPin", "pupSig", "pupSigAt" },
         -- 每帧那次（PEER.frame：喂摇杆、掐本机反应、锁定点、严格跟随）只用到这些
         STK_FRAME = { "ticks", "secondPC", "secondPawn", "feed", "feedLeft", "pupOwnName", "pupOwnFrames", "lockFixLogged" },
         NETK_FRAME = { "driving", "suppressed", "assassBlocked", "reequipIn" },
         -- §223.6 LO 上每个替身各自的状态（审查：以前误放了 outfitOk / switchTo / fxOn 三个函数，换的时候被置 nil，
         -- 每个带 of= 的包收到一半就报错；还漏了 appliedKey / appliedAttKey）。名单按"LO 上运行时赋值、不是函数"的全部字段逐个定的：
         -- 常量（EDGE_SCALE / ZM_HEAL …）、按类 / 路径做键的缓存（edgeCache / sigCache / abIndex / geMiss / appc）、只限制日志条数的计数共用
         LOK = { "appliedAt", "appliedKey", "appliedAttKey", "atkDm", "atkScale", "dressed", "gaveTried", "guardAt", "has", "lastEdge",
                 "offKey", "stMain", "stOutfit", "stShachi", "switchBad", "switchOffAt", "swtHold", "wgeKey", "wgeFor", "wgeOn",
                 "wgePendingKey", "wgeRetryAt", "wgeRetryFrom",
                 "pasKey", "pasReportAt", "dressErr", "pasErr", "wgeErr", "outfitErr", "scaleWhy", "lvNote" },
         LO_INIT = { atkScale = 1.0 } }     -- 新替身那份的初值（其余 nil，代码里都按 "or {}" / "or 0" 用）

-- §223.6 保险：名单里混进了函数（换的时候会把函数置 nil）→ 去掉并记一行
-- （包在函数里：主代码块的 local 已满 200 个）
;(function()
    for _, pair in ipairs({ { "STK", ST }, { "STK_FRAME", ST }, { "LOK", LO } }) do
        local keep = {}
        for _, k in ipairs(PEER[pair[1]]) do
            if type(pair[2][k]) == "function" then out("!! PEER.%s 里的 %s 是函数，不能当状态换，已去掉", pair[1], k)
            else keep[#keep + 1] = k end
        end
        PEER[pair[1]] = keep
    end
end)()

PEER.ST = ST          -- tests/test_spec_peer.py 看对战那份 ST 有没有被动过
PEER.LOT = LO         -- tests/test_spec_peer.py 看 LO 上的函数有没有被换掉
-- 全局模块：换的时候直接把全局名字指向这个替身自己那张表（只放状态；函数经元表取原模块的），换回来再指回原表 ——
-- 不抄字段，换一次几微秒（11-10 第一版逐个抄 259 个字段，一次 1.2 毫秒，观战每秒 240 次 ≈ 280 毫秒，不能用）。
-- NET / AIR 是主代码块的 local（函数里是上值，换不了名字）：逐个换字段，不新建表
PEER.GLOB = { "DGE", "DDIR", "INF", "CHG", "ANIM", "ZMX", "BOWN", "BOWAIM", "BOWEYE", "ULT", "PHEAL", "LAT", "PRED", "NPM", "RMS", "SUMMON", "PUPFC" }
PEER.ORIG = {}
for _, n in ipairs(PEER.GLOB) do PEER.ORIG[n] = _G[n] end

-- F4a：换入换出的机制（tables / deep / fields / meta / swapIn / swapOut / hostNet / note / run / get）在 fornet_match.lua，装到这张表上；
-- 名单（GLOB / ORIG / STK / STK_FRAME / NETK_FRAME / LOK）和 PEER.new 里"对手相关的从头来"是影之刃零的，留在这里
FMATCH.peerInstall(PEER, { NET = NET, AIR = AIR, LO = LO, ST = ST })

-- 一个观战替身的一份状态。pup / ctl = 替身和它的 AI 控制器，tag = "A" / "B"
function PEER.new(tag, pup, ctl)
    local mods, skip = PEER.tables(), {}
    for _, v in pairs(_G) do if type(v) == "table" then skip[v] = true end end
    for _, m in pairs(mods) do skip[m] = true end
    skip[ST], skip[LO], skip[MATCH], skip[G] = true, true, true, true
    local st = { tag = tag, m = {}, st = { ticks = 0, secondPC = ctl, secondPawn = pup }, lo = {}, fired = 0, failed = 0,
                 save = { NET = {}, AIR = {}, st = {}, lo = {} } }
    for name, m in pairs(mods) do st.m[name] = PEER.deep(PEER.fields(m), {}, skip) end
    for _, n in ipairs(PEER.GLOB) do setmetatable(st.m[n], PEER.meta(PEER.ORIG[n])) end
    -- 对手相关的从头来：第一个包按"新连接"清计数（NET.recvOne），NET.sub 是替身自己的招式替代表
    local n = st.m.NET
    for _, k in ipairs({ "rab", "raccban", "rai", "raim", "raimAt", "rarm", "ratt", "rav", "rbar", "rbo", "rbrkAt", "rdead", "rdm",
                         "remoteHp", "remoteHpm", "reye", "rgd", "rlk", "rlvS", "rlvW", "rmap", "rnm", "rof", "rpas", "rsh", "rshm",
                         "rwc", "rwcCur", "rwcOff", "rwcPin", "rwcs", "rwge", "rzmb", "rmt", "rarena", "rasp", "rrdy", "rquit", "rrly", "rStanceAt", "reequipIn",
                         "pos", "vel", "brkIn", "hrIn", "medIn", "subIn", "lastHrAt", "lastHrTag",
                         "trvIn", "rtrv", "rtrvAt" }) do n[k] = nil end     -- 对方的（§436 trv= 场景动作）
    st.m.NPM.travFly, st.m.NPM.zOffAt, st.m.NPM.trav = nil, nil, nil       -- §436 这个替身自己的悬空 / 高度计时从头来
    n.lastSeq, n.lastRecvAt, n.driving, n.sub, n.wTried, n.rx, n.evIn, n.evLost = -1, -100, false, {}, nil, 0, 0, 0
    n.results, n.resId, n.resV, n.resAtk, n.remoteHp, n.rflag, n.rres = {}, 0, {}, {}, nil, {}, {}
    st.m.INF.r, st.m.INF.pup = nil, {}
    for _, k in ipairs(PEER.LOK) do st.lo[k] = PEER.LO_INIT[k] end
    if tag == "A" then PEER.host = st end      -- A = 主机那一路（主机下场时是第一位选手，房间规矩字段主机转发时换成了主机的）
    return st
end

function PEER.tgt()
    return PEER.on and PEER.cur and PEER.cur.tgt or getP1()
end

-- 观战代码用（tgt = 另一个替身）。收包 + 驱动一次换完：inbox = 上次以来攒下的包（同 netStep：先 netRecv 再驱动）
function PEER.recv(st, tgt, t, tn)
    st.tgt = tgt
    return PEER.run(st, function() NET.recvOne(tgt, tn, t) end)
end

function PEER.step(st, tgt, tn, inbox)
    st.tgt = tgt
    st.st.ticks = (st.st.ticks or 0) + 1
    return PEER.run(st, function()
        for i = 1, #(inbox or {}) do
            local okR, errR = pcall(NET.recvOne, tgt, tn, inbox[i])
            if not okR then out("!! 观战 %s 收包出错：%s", st.tag, tostring(errR)) end
        end
        PEER.driveNow(tgt, tn)
    end)
end

function PEER.drive(st, tgt, tn) return PEER.step(st, tgt, tn, nil) end

function PEER.driveNow(tgt, tn)
    local pup = puppet()
    if valid(pup) and NET.pos and tn - (NET.lastRecvAt or -100) < 1.0 then
        if not NET.driving then setBraking(pup, true); NET.driving = true end      -- 同 netStep
        NET.drive(tgt, pup, tn)
    elseif NET.driving then
        NET.driving = false
        AIR.queue, AIR.launched = {}, false
        if valid(pup) then setBraking(pup, false) end
    end
    SUMMON.step(tgt, pup, tn)       -- 同 onTick：替身的召唤物跟着替身的阵营
end

-- 每帧（同 startFeedLoop 里替身的那几件）：喂摇杆、掐掉本机打出来的反应、锁定点跟着走、严格跟随放位置
function PEER.frame(st, tgt)
    st.tgt = tgt
    return PEER.run(st, PEER.frameNow, true)
end

function PEER.frameNow()
    if (ST.feedLeft or 0) > 0 and ST.feed then
        ST.feedLeft = ST.feedLeft - 1
        local f = ST.feed
        if valid(f.pup) then pcall(function() f.pup:AddMovementInput(f.dir, f.scale, true) end) end
    end
    pcall(suppressLocalReact)
    pcall(fixPuppetLockPoint)
    pcall(NPM.frame)
end

-- §141 观战：小键盘 * 换镜头（侧面中点 / 跟 A / 跟 B / 自由视角）。代码在 pbz_spec.lua；
-- 小键盘数字和 + - 是 PBZ_MC 的。包一层函数：主代码块的 local 已满 200 个
-- L3（docs/FORNET_LAYERS.md）：观战 / 多人是往基础联机包上加的 mod（mods\spec、mods\multi，各自提供服务 spec / multi = 构造函数）。
-- 基础联机包作为 mod 运行时，等全部 mod 装完（事件 4n.modsLoaded）再接上；老布局 / 测试照旧当场 require
ST.underMods = FORNET and FORNET.modsys and FORNET.modsys.DIR and FORNET_BASE ~= nil or false
function ST.whenMods(fn) if ST.underMods then FORNET.on("4n.modsLoaded", fn) else fn() end end
function ST.optMk(svc, file)
    if ST.underMods then
        local mk = FORNET.use(svc)
        if type(mk) == "function" then return true, mk end
        return false, "mod " .. svc .. " 没装 / 没启用"
    end
    local ok, mk = pcall(require, file)
    if not ok then ok, mk = pcall(dofile, (((FORNET or {}).GAME_DIR or (ROOT .. "/Scripts")) .. "/" .. file .. ".lua")) end
    return ok, mk
end
-- L3：观战是往基础联机包上加的 mod（mods\spec）：自己构造、自己订阅 BASEHOOK 的事件（pbz_spec.lua 的 SP.attach）。
-- 基础联机包只提供"驱动替身 / 藏角色要用的上下文"（服务 pvp.driverCtx），不再按名字调观战。老布局 / 测试（没有 mod 机制）在这里当场接上
BASEX = BASEX or {}
function BASEX.driverCtx()
    return { out = out, ST = ST, MATCH = MATCH, G = G, activate = RECM.activateOnPuppet, isAttack = isAttackAbility,
                loadRecording = RECM.loadRecording, recDir = REC_DIR, LO = LO,
                replayable = RECM.replayable, playNamed = playNamed, netCmd = M4.cmd, readKV = fileReadKV, writeFile = fileWrite,
                rulesFile = NET.RULES_FILE, flash = M4.flash, NET = NET, safePlace = M4.safePlace,
                -- §223 观战的两个替身各自完整走对战替身那一套（PEER）
                peer = PEER,
                mapGo = function() local p1 = getP1(); if M4.mapgo.check(p1) == "ok" then M4.mapgo.go(p1, true) end end,
                -- §168.5 观战也走游戏传送：离主机多远（米）、同图传到主机身边、是不是在传送中
                hostDist = function() return M4.mapgo.dist(getP1()) end,
                toHost = function() return M4.mapgo.toHost(getP1(), true) end,
                -- 观战者收的包不走 NET.recvOne，lobbyStep 不调 MAPGO.step（11-09 实测：传到了，观战一直不开）：这里替它确认到达
                -- §168.6 屏幕中间的提示（观战者连着时联机面板的状态行不显示，用对局外提示那一块）
                notice = function(title, sub, sec)
                    MATCH.toast = { rows = { { c = title, col = COL_ORANGE, size = 1.3 }, sub and { c = sub, col = COL_LABEL } or nil }, till = now() + (sec or 2.0) }
                end,
                travelling = function()
                    if ST.travel then return true end
                    local p1, pd = getP1(), M4.mapgo.pending
                    if pd and valid(p1) and (pd.done or (not pd.same and mapName(p1) == pd.map)) then M4.mapgo.step(p1, mapName(p1)) end
                    return M4.mapgo.pending ~= nil
                end }
end
if not ST.underMods then
    local ok, mk = pcall(require, "pbz_spec")
    if not ok then ok, mk = pcall(dofile, (((FORNET or {}).GAME_DIR or (ROOT .. "/Scripts")) .. "/pbz_spec.lua")) end
    if ok and type(mk) == "function" then
        ST.spec = mk(BASEX.driverCtx())
        local S = FORNET and FORNET.modsys
        ST.spec.attach({ on = BASEHOOK.on, ask = BASEHOOK.on, bind = bind, me = "spec",
                         activity = (S and S.acquire) and { acquire = function(k) return S.acquire("spec", k) end, release = function(k) return S.release("spec", k) end, owner = S.holder } or nil,
                         panelOpen = function() return M4.panelOpen() end, multi = function() return BASEHOOK.mp end })
    else
        out("!! 加载 pbz_spec.lua 失败，观战：%s", tostring(mk))
    end
end
-- L5：多人 / 对决对局的占用锁（owner = multi）。没有 mod 机制（老布局 / 测试）只记日志。
-- 离开房间（会话 role=none）时兜底放开（对局中掉线不一定走得到 onMatchEnd）
function ST.mpLock(on, what)
    local S = FORNET and FORNET.modsys
    if not (S and S.acquire) then out("对局占用锁：%s", what); return end
    if on then
        local ok, who = S.acquire("multi", "match")
        ST.mpLockHeld = ok and true or nil
        out("对局占用锁：%s，%s", what, ok and "已占" or ("没占上（" .. tostring(who) .. " 占着），照常开"))
    elseif ST.mpLockHeld then
        S.release("multi", "match"); ST.mpLockHeld = nil
        out("对局占用锁：%s，已放开", what)
    end
end
BASEHOOK.on("base.session", function(was, kv)
    if ST.mpLockHeld and (kv and kv.role or "none") == "none" then ST.mpLock(false, "离开房间") end     -- 多人房 connected 不一定是 1（换房主时 role 也会变），只认离开
    if MATCH.uiSync then MATCH.uiSync("联机会话变化") end     -- §260 兜底：离开房间 / 换房主 / 掉线时重算一次（幂等）
end)
-- 多人混战 / 2v2 单机原型（pbz_multi.lua）：小键盘 / 开关、小键盘 . 换模式（观战原型以前用这两个键，现在没绑）。
-- 文件不在（发布包不带）就不绑。包一层函数：主代码块的 local 已满
-- L5：多人是往基础联机包上加的 mod（mods\multi）：自己构造、自己订阅 BASEHOOK 的事件（pbz_multi.lua 的 MP.attach）。
-- 基础联机包只提供构造用的上下文（服务 pvp.multiCtx）；老布局 / 测试（没有 mod 机制）在这里当场接上
function BASEX.multiCtx()
    return { out = out, ST = ST, MATCH = MATCH, G = G, activate = RECM.activateOnPuppet, LO = LO, prof = PROF.wrap,
                cmd = function(c, extra) local X = EXTCTX; if X and X.netuiCmd then X.netuiCmd(c, extra) end end,
                T = function(zh, en) local X = EXTCTX; return (X and X.T) and X.T(zh, en) or zh end,
                specOn = function() return ST.spec and ST.spec.on end, ppOn = function() return M4.ppOn() end,   -- PP 是 M4 里的 local，这里看不到（11-10 实测报 nil）
                spec = function() return ST.spec end, session = function() return MATCH.session end,     -- 多人混战 ②b：借观战的收包驱动；会话里的 mp= / mpid=
                mpDead = M4.mpDead, fallDown = M4.fallDown, safePlace = M4.safePlace,      -- ②d 倒下判定 / 倒地动作（1v1 那套）
                -- 11-17 跨地图去房主那里（旧版 MAPGO 那套游戏传送）；mapLabel = 游戏里的地名
                goToMap = function(map, pos, yaw, same) return M4.mapgo.goToPeer(map, pos, yaw, same) end,
                version = VERSION,     -- 11-17 房间里比各人的版本
                arnRefresh = function(why) ARN.refresh(nil, why) end,     -- 11-17 对决开战点光柱
                mapLabel = function(map, pos) return M4.mapgo.label(map, pos) end,
                readKV = fileReadKV, writeFile = fileWrite, mpFile = NET_DIR .. "/mp.txt",     -- ②d 多人房间设置（人数 / 命数 / 时限）
                hasAi = function() local X = EXTCTX; local N = X and X.NETUI; return N and N.lobby and N.lobby.hasai == "1" end,
                aiLevel = function() local X = EXTCTX; local N = X and X.NETUI; return tonumber(N and N.lobby and N.lobby.ailevel) end,
                myAtkInfo = function() local id = NET.myAtkId or 0; return id, NET.myAtkAt or 0, NET.evName and NET.evName[id] end,
                -- §357 我最近这一招的技能还挂在我身上（还在放）：多人房 AI 掉血归属用，起手慢 / 后段才打到的招不再过了 0.6 秒就不算
                myAtkLive = function() local n = NET.evName and NET.evName[NET.myAtkId or 0]; return n ~= nil and NET.prevAbs ~= nil and NET.prevAbs[n] ~= nil end,
                calcTouch = function(id, d, tn, prevDmg, capKey) return TOUCH.calc(id, d, tn, true, prevDmg, true, capKey) end,
                flushTouchCap = function(capKey, dmg) if AIF and AIF.flush then AIF.flush(capKey, dmg) end end,
                -- ②d 多行提示（排名）：rows = { { 文字, "title" | "me" | "row" [, 字号] }, … }
                toast = function(rows, sec)
                    local r = {}
                    for i, x in ipairs(rows) do
                        r[#r + 1] = { c = x[1], col = x[2] == "title" and COL_ORANGE or x[2] == "me" and COL_GREEN or COL_WHITE, size = x[3] or (i == 1 and 1.3 or nil) }     -- 11-15 第三项 = 字号（结算人多时变小）
                    end
                    MATCH.toast = { rows = r, till = now() + (sec or 3.0) }
                end,
                notice = function(title, sub, sec)
                    MATCH.toast = { rows = { { c = title, col = COL_ORANGE, size = 1.3 }, sub and { c = sub, col = COL_LABEL } or nil }, till = now() + (sec or 2.0) }
                end,
                -- §291 多人房间规则接线与生命周期
                recvRules = NET.recvRules,
                adoptHostRules = NET.adoptHostRules,
                restoreLocalRules = NET.restoreLocalRules,
                rulesSnapshot = NET.rulesSnapshot,
                rulesClear = NET.rulesClear,
                rulesBegin = function(phase, why, first, tn) return NET.rulesBegin(nil, phase, why, first, tn) end,
                rulesEnd = function(why) return NET.rulesEnd(nil, why) end,
                rulesRespawn = function() return NET.rulesRespawn(nil) end,
                wbanGateMulti = WBAN.gateMulti,
                -- L5：多人 / 对决对局开打占"对局"、结束放开（独立玩法据此不开局；1v1 照旧，见 BASEHOOK.take）
                onMatchStart = function(mid) ST.mpLock(true, "多人对局 mid=" .. tostring(mid) .. " 开始") end,
                onMatchEnd = function(mid, why) ST.mpLock(false, "多人对局 mid=" .. tostring(mid) .. " 结束（" .. tostring(why) .. "）") end,
                arnLock = function() ARN.lock() end,
                arnUnlock = function(why) ARN.unlock(why) end,
                getArena = function()
                    local p1 = getP1()
                    if not valid(p1) then return nil end
                    local sp = ARN.fromSaved(p1)
                    if not sp then return nil end
                    local s = ARN.saved
                    if not (s and s.x and s.y and s.z) then return nil end
                    -- §307 D1：多给朝向 / 地图（对决定场地、判同图）
                    return { cx = tonumber(s.x), cy = tonumber(s.y), cz = tonumber(s.z), radius = tonumber(sp.d) or 400.0,
                             yaw = tonumber(s.yaw) or 0.0, map = s.map }
                end,
                setYaw = setYaw,
                setControlRotation = function(pitch, yaw, roll)
                    pcall(function() getP1PC():SetControlRotation({ Pitch = pitch or -10.0, Yaw = yaw, Roll = roll or 0.0 }) end)
                end,
                -- 新版 1v1 对决（pbz_duel.lua）额外服务钩子
                loadDuel = function(c, base)
                    local okD, mkD = ST.optMk("duel", "pbz_duel")     -- L3：mod 布局下由多人 mod 提供服务 duel
                    return (okD and type(mkD) == "function") and mkD(c, base) or nil
                end,
                relSend = function(...) return REL.send(...) end,
                barMode = function() return NET.barMode() end,      -- §295 对手血条档位（2 血量+杀气 / 1 只显示血 / 0 不显示）
                -- §295 观众上限 = 观战 / 排队人数上限。§312 实测：这里（文件末尾块）看不见面板段的 local NETUI，以前恒为 nil →
                -- 面板一直显示 4、点一下永远改成 6；经全局 EXTCTX 拿
                maxSpec = function() local X = EXTCTX; local N = X and X.NETUI; return tonumber(N and N.lobby and N.lobby.maxspec) end,
                rfpPeer = function(v) if not PEER.on then RFP.onPacket(v, now()) end end,     -- §295 对决：选手按对手包里的 rfp= 比（房主当观众时没有房主的）
                myRfp = function() return RFP and RFP.wire and RFP.wire() or "-" end,     -- §299 "局号:指纹"，不在对局里是 "-"
                -- §307 D6：对决 cd / fight 的清理照旧版 enter() 补齐（只对我自己；替身不在 ST.secondPawn 里）。
                -- 都用 pcall 包，失败记日志，不让一处挂不上把整个对决阶段卡住。
                cdStart = function(p1)
                    if not valid(p1) then return end
                    if HLFX then
                        local ok, err = pcall(HLFX.clearFx, "对决回合倒计时")
                        if not ok then out("!! §307 对决回合倒计时清特效失败：%s", tostring(err)) end
                    end
                    local okS, errS = pcall(SHIELD.sweep, p1, "对决回合倒计时")
                    if not okS then out("!! §307 对决回合倒计时清拙壁盾失败：%s", tostring(errS)) end
                    local okU, errU = pcall(G.standUp, p1)
                    if not okU then out("!! §307 对决回合倒计时站起失败：%s", tostring(errU)) end
                    local okR, errR = pcall(G.refill, p1)
                    if not okR then out("!! §307 对决回合倒计时补满失败：%s", tostring(errR)) end
                    -- 验收改：main.lua 里没有 ctx（原来写成 ctx.cdStart，进对决倒计时就报错、RT.cdStart 根本没调）
                    local okC, errC = pcall(RT.cdStart, p1)
                    if not okC then out("!! §307 对决 RT.cdStart 失败：%s", tostring(errC)) end
                end,
                fightStart = function(p1)
                    if not valid(p1) then return end
                    local okF, errF = pcall(RT.fightStart, p1)      -- 验收改：同上，不是 ctx.fightStart
                    if not okF then out("!! §307 对决 RT.fightStart 失败：%s", tostring(errF)) end
                    local okR, errR = pcall(G.refill, p1)
                    if not okR then out("!! §307 对决开打补满失败：%s", tostring(errR)) end
                    local okB, errB = pcall(RT.begin, p1)
                    if not okB then out("!! §307 对决 RT.begin 失败：%s", tostring(errB)) end
                    local okP, errP = pcall(PCB.on, p1, "对决回合开打")
                    if not okP then out("!! §307 对决战斗状态挂不上：%s", tostring(errP)) end
                end,
                pcbOff = function(why)
                    local p1 = getP1()
                    if not valid(p1) then return end
                    local ok, err = pcall(PCB.off, p1, why or "对决结束")
                    if not ok then out("!! §307 对决撤战斗状态失败：%s", tostring(err)) end
                end,
                wbanSelf = function()
                    local m = WBAN.selfCheck()
                    if m then return m[1], m[2] end
                end,
                rfpOverride = function()
                    -- §307 D4：多人实例（pbz_multi）手里有对决 / 多人的准确值（多人时限用对局里收到的 RULE.tl）；
                    -- 没有实例时退回本文件按 cfg 算的版本
                    local sm = BASEHOOK.mp
                    if sm and sm.rfpOverride then
                        local v = sm.rfpOverride()
                        if v then return v end
                    end
                    return NET.duelRfpOverride()
                end,
                unshield = function(p1) return RT.unshield(p1) end,
                deadHp = DEAD_HP,
                bestOf = NET.bestOf,
                boCfg = function() return NET.boCfg end,
                boSet = function(n) NET.boSet(n) end,
                boNext = NET.boNext,
                tlCfg = function() return NET.resCfg.tl end,
                tlSet = function(n) NET.resSet("tl", n) end,
                tlNext = function(n) return NET.resNext("tl", n) end,
                resText = NET.resText,
                toWin = NET.toWin,
                tlLimit = RT.limit,
                rdyTimeout = function()
                    -- §309（11-14 实测）：FORNET.ask 返回两个值（答案、谁答的），直接塞进 tonumber 就成了 tonumber(答案, "spec")
                    -- → 报错，准备超时变 0："[0s]"、刚叫号就"准备超时且无人可替补，已暂停轮换"。只取第一个值
                    local r = tonumber((BASEHOOK.ask("base.rdyto")))        -- 观战 mod 的排队规矩（rdyto）；没装观战按 10 秒
                    return (r and r > 0) and r or 10
                end,
                hostRulesKv = function()
                    -- §293.1 按状态包同一套键表生成（以后加的规则键自动带上，不用再改这里）
                    local parts = { "bar=" .. tostring(NET.barCfg), "bo=" .. tostring(NET.boCfg), "dm=" .. tostring(NET.dmCfg), "ab=" .. tostring(NET.abCfg) }
                    for _, k in ipairs(NET.FLAG_KEYS) do parts[#parts + 1] = (NET.FLAG_WIRE[k] or k) .. "=" .. tostring(NET.flagCfg[k]) end
                    for _, k in ipairs(NET.RES_KEYS) do parts[#parts + 1] = k .. "=" .. tostring(NET.resCfg[k]) end
                    parts[#parts + 1] = "accban=" .. tostring(NET.accBanCfg or "")
                    parts[#parts + 1] = "cfgh=" .. tostring(CFG.wire())      -- §295 房主当观众时不发状态包：数值表哈希也得经这里给，选手才会来要表
                    for _, k in ipairs(WBAN.KINDS) do parts[#parts + 1] = k .. "=" .. tostring(WBAN.cfg[k] or "") end
                    return table.concat(parts, ";")
                end }
end
if not ST.underMods then
    local ok, mk = ST.optMk("multi", "pbz_multi")
    if ok and type(mk) == "function" then
        BASEHOOK.setMp(mk(BASEX.multiCtx()))
        if BASEHOOK.mp.attach then BASEHOOK.mp.attach({ on = BASEHOOK.on, ask = BASEHOOK.on, bind = bind, panelOpen = function() return M4.panelOpen() end }) end
    else
        out("没有多人（%s），跳过", tostring(mk))
    end
end
-- X1 扩展包（docs/EXTENSIONS.md）：扫 ext\<名>\，沙箱里跑 init.lua；没有目录就只多一页"无扩展"。包一层函数：主代码块的 local 已满
ST.ext = (function()
    local ok, mk = pcall(require, "fornet_ext")     -- F5：扩展包框架归 fornet（以前 pbz_ext.lua）
    if ok and FORNET and FORNET.adopt then mk = FORNET.adopt("fornet_ext", mk) end     -- F6：实例登记到宿主（FORNET.mods）
    if not ok then ok, mk = pcall(dofile, ROOT .. "/Scripts/fornet_ext.lua") end
    if not (ok and type(mk) == "function") then out("没有 fornet_ext.lua（扩展包），跳过：%s", tostring(mk)); return nil end
    local X = EXTCTX     -- 面板那段导出的 T / netuiCmd / NETUI / 颜色（那些是它的 local，这里看不见）
    if not X then out("!! EXTCTX 没定义（面板那段没跑到？），扩展包跳过"); return nil end
    local okM, ext = pcall(mk, { out = out, ROOT = ROOT, T = X.T, CONSENT = CONSENT, PREF = PREF, VERSION = VERSION, COL = X.COL,
                                 readKV = fileReadKV, writeFile = fileWrite, netuiCmd = X.netuiCmd, flash = X.netuiFlash,
                                 transport = function() local r = (X.NETUI.lobby or {}).route; return (r == "bridge" or r == "bridgewait") and "bridge" or "udp" end })     -- F4c-2："bridge" = 经扩展包的桥接 DLL   -- lb.route 同 netRouteName
    if not okM then out("!! fornet_ext.lua 初始化失败：%s", tostring(ext)); return nil end
    local okS, e = pcall(ext.scan)
    if not okS then out("!! 扩展包扫描出错：%s", tostring(e)) end
    return ext
end)()
if CONSENT and CONSENT.betaSweep then pcall(CONSENT.betaSweep) end     -- 11-15 内测包（有 beta_defaults.txt）：已登记的同意项默认同意；后登记的打开面板时再过一遍
-- v0.18.6：回车 / Esc 只在游戏内输入框打开时有用（确定 / 取消），平时直接忽略
-- 11-14 快速点击：左键钩子只记"按下了一次"（面板关着时不记），哪个按钮被点由面板每拍按悬停判断（fornet_ui.lua guiClicked）。注册不上只记日志
do
    local okL, errL = pcall(function()
        if Key.LEFT_MOUSE_BUTTON == nil then error("没有 Key.LEFT_MOUSE_BUTTON") end
        bind(Key.LEFT_MOUSE_BUTTON, function() if BASEUI.lmbDown then BASEUI.lmbDown() end end, "联机面板 左键", true)
    end)
    if not okL then out("!! 左键钩子注册不上（%s），联机面板只靠 IsPressed 判断点击", tostring(errL)) end
end
for _, kb in ipairs({ { "PAGE_UP", "up" }, { "PAGE_DOWN", "down" }, { "END", "ok" }, { "RETURN", "enter" }, { "ESCAPE", "esc" } }) do
    bind(Key[kb[1]], function()
        -- §342 面板关着、对手是木桩：End = 招式伤害统计清零（面板开着照旧是确定；平时面板关着 End 什么都不做）
        -- §342.4 这里在 M4 闭包外，看不见面板段的 local NETUI（11-16 前写成 NETUI.open = 每按 End 报错、连面板确定都没了），走 EXTCTX
        if kb[2] == "ok" and NET.rdummy and DSTAT then
            local X = EXTCTX
            if not (X and X.NETUI and X.NETUI.open) then DSTAT.reset("End", now()); return end
        end
        M4.netui(kb[2])
    end, "联机面板 " .. kb[2], true)
end


