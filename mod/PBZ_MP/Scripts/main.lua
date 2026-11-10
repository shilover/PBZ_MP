-- PBZ_MP —— 影之刃零 联机 PvP 原型（版本号见下方 VERSION）
-- 路线：防守方判定。对手在本机用一个"独立角色"代表（SpawnActor 玩家同类 + AIController；v0.13.0 起不再 CreatePlayer，
--       因为多一个本地玩家会让游戏菜单永久打不开）。对手出招 = 在它身上激活同名技能，打没打中、弹没弹开交给游戏原生战斗系统。
-- 网络：UE4SS 的 Lua 没有 socket，读写模组目录 net/ 下的文本文件，由同目录的联机窗口 PBZLobby.exe（或测试用 sidecar.py）收发 UDP。
-- 开发仓库：D:/UEProject/PBZMODS/LanBattle（交接文档 docs/HANDOVER.md）；游戏目录里只放部署后的文件
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

local VERSION = "0.32.0"
local TAG = "[PBZ_MP] "
-- v0.14.0：所有文件都放在模组自己的目录（…/Mods/PBZ_MP/），不再写死本机的游戏路径，别人的电脑上也能用。
-- 从本脚本的路径推出模组目录（脚本在 PBZ_MP/Scripts/main.lua）；拿不到时退回 UE4SS 的工作目录（游戏 exe 所在的 platform/steam）下的相对路径
local ROOT_TRIED = {}
local function modRoot()
    local cands = {}
    local function add(d)
        if d and d ~= "" then cands[#cands + 1] = (d:gsub("\\", "/"):gsub("/+$", "")) end
    end
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
local LOG = ROOT .. "/mp_probe.log"
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
    LOG = ROOT .. "/mp_probe_2.log"
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
              lastResIn = 0, applied = {}, stagger = nil, remoteHp = nil }        -- M3 攻击方收结果
-- M4 对局（v0.10.0）。role = nil / "host"（按 F4 发起的一方，说了算）/ "client"（跟随对方的 mt）。
-- me / op = 我 / 对方的回合分；dead = 我在第几回合倒下（0 = 本回合没倒）；wire = 随状态包发出去的字段
local MATCH = { role = nil, state = "idle", round = 0, me = 0, op = 0, t0 = 0, arena = nil, center = nil,
                dead = 0, win = "-", id = 0, lock = nil, hold = {}, pupFell = 0,
                wire = { mt = "", arena = "", dead = 0, rdy = 0, quit = 0 }, ready = false }
local REC = { on = false, frames = nil, t0 = 0, ox = 0, oy = 0, oz = 0, oyaw = 0 }
local REP = { on = false, frames = nil, t0 = 0, i = 1, ax = 0, ay = 0, az = 0, ayaw = 0, lastM = "" }
local abilitiesOf   -- 前置声明：回放要用，定义在下面 M0 段
local activateOnPuppet  -- 前置声明：回放和网络共用，定义在回放段
local finishDeflect     -- 前置声明：精防/普通防御分类，定义在 M3 段

-- ============================================================ 基础设施

-- §84 日志攒着写：以前每行都 打开 / 追加 / 关闭 一次 mp_probe.log（对局里每秒几行到几十行）。攒到 MAX 行或 SEC 秒写一次
-- （驱动每次也看一眼，没新日志时不会一直攒着）；带 "!!" 的（出错）马上写。游戏崩了最多丢最后 SEC 秒的普通日志。
-- 全局（主代码块的 local 已满 200 个）
-- §89 每行日志以前还 print 一份，UE4SS 再一行一行写进 ue4ss/UE4SS.log（对局里每秒十几行，剩下最频繁的写盘）。
-- 现在只有出错（"!!"）和少数关键行（"==" 开头、管道、版本）进 UE4SS 控制台 / UE4SS.log；全部日志照旧在 mp_probe.log。
-- 要看全部：PRINT_ALL = true
LOGBUF = { lines = {}, at = 0, MAX = 50, SEC = 2.0, PRINT_ALL = false }
function LOGBUF.wantPrint(s)
    if LOGBUF.PRINT_ALL then return true end
    return s:find("!!", 1, true) ~= nil or s:sub(1, 2) == "==" or s:find("管道", 1, true) ~= nil
        or s:find("PBZ_MP v", 1, true) ~= nil
end
function LOGBUF.flush()
    LOGBUF.at = os.clock()
    if #LOGBUF.lines == 0 then return end
    local text = table.concat(LOGBUF.lines)
    LOGBUF.lines = {}
    local ok, f = pcall(io.open, LOG, "a")
    if ok and f then
        f:write(text)
        f:close()
    end
end

local function out(fmt, ...)
    local s = fmt
    if select("#", ...) > 0 then
        local ok, r = pcall(string.format, fmt, ...)
        s = ok and r or tostring(fmt)
    end
    if LOGBUF.wantPrint(tostring(s)) then print(TAG .. tostring(s) .. "\n") end     -- §89
    local ok2, ts = pcall(os.date, "%H:%M:%S")
    local L = LOGBUF.lines
    L[#L + 1] = (ok2 and ts or "??:??:??") .. " " .. tostring(s) .. "\n"
    if #L >= LOGBUF.MAX or os.clock() - LOGBUF.at >= LOGBUF.SEC or tostring(s):find("!!", 1, true) then LOGBUF.flush() end
end
if INST.slot == 2 then out("双开：另一份游戏在跑（net/log_owner.txt 15 秒内写过），这份的日志写 mp_probe_2.log（§147）") end


-- ============================================================ 游戏适配层（v0.23.0，HANDOVER §59）
-- 直接调游戏的代码在同目录的 pbz_game.lua。和 pbz_abilities 一样靠 UE4SS 放进 package.path 的 Scripts 目录 require；
-- 万一 require 不到，按上面从 package.path 推出的 ROOT 直接加载（不写死路径）
local G
do
    local ok, mk = pcall(require, "pbz_game")
    if not (ok and type(mk) == "function") then
        out("!! require pbz_game 失败（%s），改从 %s 加载", tostring(mk), ROOT .. "/Scripts/pbz_game.lua")
        mk = dofile(ROOT .. "/Scripts/pbz_game.lua")
    end
    G = mk({ out = out, ST = ST, NET = NET, MATCH = MATCH, PLACE_DIST = PLACE_DIST })
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

-- ============================================================ 文件

local function fileWrite(path, text)
    -- §83 / §84 连着联机程序的管道：本机状态包、cmd.txt、rel_out.txt 走内存，不写文件
    if PIPE then
        if path == F_LOCAL then
            if PIPE.send(text) then return true end
        else
            local n = PIPE.netName(path)
            if n and PIPE.UP[n] and PIPE.putUp(n, text) then return true end
        end
    end
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false end
    f:write(text)
    f:close()
    for _ = 1, 3 do
        os.remove(path)
        if os.rename(tmp, path) ~= nil then return true end
    end
    local g = io.open(path, "w")
    if g then
        g:write(text)
        g:close()
        os.remove(tmp)
        return true
    end
    return false
end

local function fileReadKV(path)
    -- §84 联机程序给的 session / lobby / rel_in / lang：连着管道就用它经管道给的（内存里最新一份），不读文件
    if PIPE then
        local n = PIPE.netName(path)
        if n and PIPE.DOWN[n] and PIPE.tryConnect() then
            PIPE.poll()
            if PIPE.on then
                local t = PIPE.blob[n]
                return t and PIPE.kv(t) or nil
            end
        end
    end
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a") or ""
    f:close()
    local t = {}
    for k, v in data:gmatch("(%w+)=([^\r\n]*)") do t[k] = v end
    if next(t) == nil then return nil end
    return t
end

-- ============================================================ §83 命名管道：游戏 ↔ 联机程序的状态包走内存
-- 以前每秒各写 30 次 state_local.txt / state_remote.txt：读刚被联机程序换掉的文件要等杀毒扫描（平均 3.6–6.5 ms、
-- 最长 20+ ms，全压在游戏线程上），还磨硬盘。联机程序（lobby\GamePipe.cs，协议见它的文件头）写 net\pipe.txt（name=…），
-- 这里连 \\.\pipe\<name>.up（写）/ .down（读）。连不上 / 读写出错 → 关掉、退回文件交接，PIPE.RETRY 秒后再试。
-- Lua 的读是阻塞的：联机程序收到 "R" / "B" 立刻回话（专门的线程，不碰网络）；它退出了管道就断，读到 nil 不会卡住。
-- §84 以前的小文件也走管道：联机程序给的（DOWN）每次回话时带上变了的；游戏给的（UP）用 "U <文件名>" 发。
--   断开后联机程序把内存里最新的几份写回硬盘，这边照旧读写文件
-- 全局（主代码块的 local 已满 200 个）
PIPE = { on = false, retryAt = 0, RETRY = 5.0, name = nil, blob = {}, blobAt = 0, BLOB_SEC = 0.2, ups = {},
         DOWN = { ["session.txt"] = true, ["lobby.txt"] = true, ["rel_in.txt"] = true, ["lang.txt"] = true },
         UP = { ["cmd.txt"] = true, ["rel_out.txt"] = true },
         RESEND = { ["rel_out.txt"] = true } }     -- 重新连上时补发（可靠事件的状态；命令不补，免得执行两次）
-- net\ 下的文件名；别的目录的返回 nil
function PIPE.netName(path)
    local n = path:match("[^/\\]+$")
    if n and path == NET_DIR .. "/" .. n then return n end
    return nil
end
function PIPE.kv(data)
    local t = {}
    for k, v in data:gmatch("(%w+)=([^\r\n]*)") do t[k] = v end
    if next(t) == nil then return nil end
    return t
end
function PIPE.close(why)
    if PIPE.up then pcall(function() PIPE.up:close() end) end
    if PIPE.down then pcall(function() PIPE.down:close() end) end
    PIPE.up, PIPE.down = nil, nil
    if PIPE.on then out("管道断开（%s），退回文件交接", tostring(why)); PIPE.lostAt = os.time() end   -- §99 NETUI.watchPipe 看着
    PIPE.on = false
    PIPE.retryAt = os.clock() + PIPE.RETRY
end
function PIPE.tryConnect()
    if PIPE.on then return true end
    if os.clock() < PIPE.retryAt then return false end
    PIPE.retryAt = os.clock() + PIPE.RETRY
    local kv = fileReadKV(NET_DIR .. "/pipe.txt")
    local name = kv and kv.name
    if not (name and name:match("^[%w_]+$")) then return false end
    local base = [[\\.\pipe\]] .. name
    local okU, up = pcall(io.open, base .. ".up", "wb")
    if not (okU and up) then return false end
    local okD, down = pcall(io.open, base .. ".down", "rb")
    if not (okD and down) then pcall(function() up:close() end); return false end
    PIPE.up, PIPE.down, PIPE.on, PIPE.name, PIPE.blob, PIPE.blobAt = up, down, true, name, {}, 0
    out("连上联机程序的管道 %s：状态包、联机状态、命令都走内存，不再写文件", name)
    for n, text in pairs(PIPE.ups) do
        if PIPE.RESEND[n] then PIPE.putUp(n, text) end
    end
    return true
end
-- 游戏给联机程序的文件（cmd.txt / rel_out.txt）经管道发；没连返回 false（调用方写文件）
function PIPE.putUp(name, text)
    if not PIPE.tryConnect() then return false end
    local ok, err = pcall(function()
        assert(PIPE.up:write("U ", name, " ", #text, "\n", text))
        assert(PIPE.up:flush())
    end)
    if not ok then PIPE.close("写失败：" .. tostring(err)); return false end
    PIPE.ups[name] = text
    return true
end
-- 问一次联机程序（"R" = 状态包 + 变了的文件，"B" = 只要变了的文件），返回状态包列表（kv 表，旧到新）；出错返回 nil
function PIPE.ask(what)
    local list = {}
    PIPE.waiting = what .. " 等回话"         -- §88 看门狗（另一个线程）据此报"卡在管道"
    local ok, err = pcall(function()
        assert(PIPE.up:write(what, "\n"))
        assert(PIPE.up:flush())
        local h = PIPE.down:read("l")
        local k, m = (h or ""):match("^N (%d+) (%d+)$")
        k, m = tonumber(k), tonumber(m)
        assert(k and m, "回话头不对：" .. tostring(h))
        for _ = 1, k do
            local n = tonumber(PIPE.down:read("l"))
            assert(n, "长度行不对")
            local body = n > 0 and PIPE.down:read(n) or ""
            assert(body and #body == n, "包不完整")
            list[#list + 1] = PIPE.kv(body)
        end
        for _ = 1, m do
            local name, n = (PIPE.down:read("l") or ""):match("^([%w_%.]+) (%d+)$")
            n = tonumber(n)
            assert(name and n, "文件行不对")
            local body = n > 0 and PIPE.down:read(n) or ""
            assert(body and #body == n, "文件不完整")
            PIPE.blob[name] = body
        end
    end)
    PIPE.waiting = nil
    if not ok then PIPE.close("读失败：" .. tostring(err)); return nil end
    PIPE.blobAt = os.clock()
    return list
end
-- 读 DOWN 文件前：上次取过超过 BLOB_SEC 秒就问一次（对局里每次驱动的 R 已经顺带取了）
function PIPE.poll()
    if PIPE.on and os.clock() - PIPE.blobAt >= PIPE.BLOB_SEC then PIPE.ask("B") end
end
-- 发本机状态包；没连管道返回 false（调用方写文件）
function PIPE.send(text)
    if not PIPE.tryConnect() then return false end
    PIPE.waiting = "S 写"
    local ok, err = pcall(function()
        assert(PIPE.up:write("S ", #text, "\n", text))
        assert(PIPE.up:flush())
    end)
    PIPE.waiting = nil
    if not ok then PIPE.close("写失败：" .. tostring(err)); return false end
    return true
end
-- 取这段时间收到的远端状态包（kv 表，旧到新，可能是空表）；没连管道返回 nil（调用方读文件）
function PIPE.recv()
    if not PIPE.tryConnect() then return nil end
    return PIPE.ask("R")
end

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
    if not valid(p1) or HOV.has(p1) or (ST.spec and ST.spec.on) then GROUND.since = nil; return end
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
        HOV.hold(pup, function() return NET.pos end, "替身往下掉（对方站在地上，这里地形没加载？）", tn)
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

function NPM.parse(text)
    local w = (tostring(text or "")):match("^%s*(%a+)")
    return (w == "anim" or w == "net") and w or nil
end

function NPM.readMode(tn)
    if tn >= NPM.readAt then
        NPM.readAt = tn + 2.0
        NPM.override = nil
        local f = io.open(NPM.FILE, "r")
        if f then NPM.override = NPM.parse(f:read("*l")); f:close() end
    end
    local m = NPM.override or (NET.flagNow("npos") and "net" or "anim")
    if m ~= NPM.mode or not NPM.told then
        NPM.told = true
        out("替身跟随方式：%s（%s）", m == "net" and "全程跟网络位置（动画不带位移）" or "动画带位移（冲过头 2 米停住）",
            NPM.override and "net/follow.txt 强制" or "房间设置")
        if NPM.mode == "net" and m == "anim" and valid(RMS.pupObj) then RMS.set(RMS.pupObj, 1.0); RMS.cur = 1.0 end
    end
    NPM.mode = m
    return m
end

function NPM.on() return NPM.mode == "net" end

-- 驱动时记下这一包算出的目标（位置、速度、时刻），每帧从它往前推
function NPM.setTarget(pup, pos, vel, tn, noExtra, rair)
    NPM.pup, NPM.pos, NPM.vel, NPM.at, NPM.noExtra, NPM.rair = pup, pos, vel, tn, noExtra, rair
end

-- 每帧：这一刻该在的 XY（纯计算，测试用）
function NPM.aim(tn)
    local p, v = NPM.pos, NPM.vel or {}
    if NPM.noExtra then return { X = p.X, Y = p.Y } end
    local a = math.min(math.max(tn - NPM.at, 0), NPM.EXTRA_MAX)
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
    local z = cur.Z
    if NPM.rair ~= true and math.abs((NPM.pos.Z or z) - cur.Z) > NPM.Z_SNAP then z, snap = NPM.pos.Z + 20.0, true end
    pcall(function() pup:K2_SetActorLocation({ X = xy.X, Y = xy.Y, Z = z }, false, {}, snap) end)
    if snap and NPM.logs < 20 then
        NPM.logs = NPM.logs + 1
        out("替身跟网络位置：差太远直接放过去（第 %d 次）", NPM.logs)
    end
end

-- 速度匹配跟随：v = 目标速度 + 3 × 位置误差（交接文档 §3.8）
local function drivePuppet(pup, pos, vel, yaw)
    local cur = try("pup loc", function() return pup:K2_GetActorLocation() end)
    if not cur then return end
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
        if dist > HOV.FAR then HOV.hold(pup, function() return NET.pos end, "替身瞬移到远处", now()) end
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
    ST.lastPupAction = { name = name, at = now() }
    if name:find("Clone", 1, true) or name:find("Summon", 1, true) then ST.summonArmAt = now() end   -- §94 接下来几秒找它的召唤物
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

-- ============================================================ 配装同步（v0.16.0）
-- 用户要求：联机时双方配装各自来自自己的存档。v0.15.2 实测（HANDOVER §28）：
--   ① 玩家换装会带着替身一起换（单向），替身换装不影响玩家 → 替身装好对方的武器后要防"被本机玩家带偏"
--   ② 属性集每人一份（替身没有我的饰品效果）→ 对方的攻击属性可以直接写进替身的属性集
-- 伤害由防守方判定：对方打我 = 本机替身的攻击属性 × 我的真实防御，所以只同步攻击侧属性。
-- 主块 local 接近 Lua 200 上限，这一段的函数都挂在一个表上
-- v0.16.0 实测（13:45，HANDOVER §29）：替身 Add Weapon And SwitchTo 一把**我两个槽里没有**的武器（Double），
-- 我自己的 Long 槽同时被换成 Double —— 装备列表是全局一份（存档里的 MainWeapons），所有玩家类角色跟着它走。
-- v0.15.2 替身装 ZhanMaBlade 没影响我，只是因为斩马刀本来就在我的槽里。
-- 所以给替身装对方武器会改我的配装（还可能被自动存档存下来），防带偏会和我的配装来回拉扯 → 两个都关掉，等找到只改替身的换装方法
local LO = { IDLE_LOCK = false,   -- v0.17.10 对局外的陪练锁血（会挡住 Esc 菜单），默认关
             PREFIX = { "Amplification_", "DealtVulnerabilityMultiplier_", "DealtReductionMultiplier_" },
             PLAIN = { Attack = true, ShachiAttack = true },
             EQUIP_REMOTE = false, GUARD = false }

-- 攻击侧属性名（从属性集的类上列，只列一次）
function LO.names(actor)
    if LO.list then return LO.list end
    local set = attrSetOf(actor)
    if not valid(set) then return nil end
    local list = {}
    local okC, c = pcall(function() return set:GetClass() end)
    c = okC and c or nil
    for _ = 1, 4 do
        if not valid(c) then break end
        pcall(function()
            c:ForEachProperty(function(p)
                local n = "?"
                pcall(function() n = p:GetFName():ToString() end)
                local hit = LO.PLAIN[n]
                for _, pre in ipairs(LO.PREFIX) do if n:sub(1, #pre) == pre then hit = true end end
                if hit then list[#list + 1] = n end
            end)
        end)
        local okS, sup = pcall(function() return c:GetSuperStruct() end)
        c = okS and sup or nil
    end
    if #list > 0 then
        LO.list = list
        out("配装同步：攻击侧属性 %d 个", #list)
    end
    return LO.list
end

-- 没写进包里的属性按中性值处理：增伤 0、伤害倍率 1
function LO.neutral(n)
    return n:sub(1, 14) == "Amplification_" and 0.0 or 1.0
end

-- 发送：Attack / ShachiAttack 总是带上，其余只带不是中性值的，包尽量小
function LO.encode(p1)
    local names = LO.names(p1)
    if not names then return "" end
    local parts = {}
    for _, n in ipairs(names) do
        local v = attrOf(p1, n)
        if type(v) == "number" and (LO.PLAIN[n] or math.abs(v - LO.neutral(n)) > 1e-4) then
            parts[#parts + 1] = string.format("%s:%.4g", n, v)
        end
    end
    return table.concat(parts, ";")
end

-- v0.23.7 PvP 影之武装伤害系数（用户 2026-11-05 定"加系数"）。00:36:42 / 00:37:03 / 00:38:46 三次被铁矿拳套蓄力第三拳
-- Charge_AAA 一拳打掉全部血量（满血 3085 → 倒下），双刃普通招每下才 26～275：影之武装的蓄力终结技按打 Boss 设计，PvP 里一拳秒人。
-- 做法：挨打的一方在替身放对方的影之武装招时（EDGE_HOLD 秒内），把替身的攻击力 Attack / ShachiAttack 乘 EDGE_SCALE，
-- 伤害就由游戏自己按比例算小（§30 实测伤害对 Attack 是线性的），致命判断也照常；放完恢复。两边规则一样，所以是对称的
LO.EDGE_SCALE, LO.EDGE_HOLD = 0.35, 2.5
LO.SCALED = { Attack = true, ShachiAttack = true }
LO.atkScale = 1.0

-- §106 武器平衡（用户 2026-11-06"武器平衡需要做一次评估"；评估见 HANDOVER §106）。和影之武装系数同一个办法：
-- 挨打的一方在替身放某招时，把替身的 Attack / ShachiAttack 乘这招的 PvP 系数（伤害、杀气伤害一起缩，游戏自己按比例算）。
-- §106.4 每招独立调参（用户 2026-11-06"加上各自的独立调参"）：系数表搬到同目录的 pbz_balance.lua（可以手改；
--   tools/gen_balance.py 按 isAttackAbility 列出全部 921 个攻击招，每招一行，已有的数重新生成时保留）。
-- 系数 = 表里这一招的数（**就是最终系数**，影之武装的 0.35 已经算在里面）> 表里没有的招：族系数（family，按 GA_Hun_<族>_ 的族名）
--   × 影之武装系数 > 1。表加载不了 → 全按兜底（日志有 !! 行）。
-- 多段招的尾段 / 持续伤害可能落进下一招：TAIL 秒内取这一招和上一招里小的那个。两边规则一样，对称（两边的表要一样）。
-- BAL.on = false 回到 v0.27.23（代码总开关）。§106.5 平时由房间设置"武器平衡"开关：主机定，默认关（NET.flagNow("bal")）
-- 数据：日志里入站 1607 次中招按替身攻击力归一化（每百攻伤害），族之间的相对值主要看 2026-11-05 21:50–23:18 同一场换 17 种武器那段；
-- 目标（对方攻击 600、倍率 100%、我满血约 3085）：普通招一下 ≤ 约 30% 血，大招 / 蓄满 ≤ 约 35–45%
BAL = { on = true, HOLD = 2.5, TAIL = 1.0, last = nil, lastAt = -100, prev = nil, prevAt = -100, FAMILY = {}, MOVE = {} }
-- §177 召唤物 / 飞出去的东西（紫冥剑的锤枪伞、飞剑……）留场比 HOLD 久，以前 HOLD 一过替身攻击力就回到没乘平衡的 100%。
-- 表里 summon = { 招名 = 留场秒数 }：放这招（或对方召唤时替身调 TrySummon*）后这么多秒内，系数至少按这招的算；
-- 期间又放了别的招，取两个里小的（和 TAIL 一个规矩，宁可少打不多打）。留场秒数跟着数值表下发（§158 的 s=），以后只改表就行
BAL.SUMMON, BAL.sums, BAL.SUM_MAX, BAL.SUM_CAP = {}, {}, 4, 60
-- 表里的 summon 段过一遍：只认 GA_ 开头的招名、0–60 秒
function BAL.cleanSummon(t)
    local o = {}
    for k, v in pairs(type(t) == "table" and t or {}) do
        if type(k) == "string" and k:match("^GA_[%w_]+$") and type(v) == "number" and v > 0 and v <= BAL.SUM_CAP then o[k] = v end
    end
    return o
end
-- §184 召唤物冷却（表里 cooldown = { <武器>_<召唤物> = 秒 }，收掉后起算，0 = 不冷却；只在武器平衡开着时生效，见 GCD 段）。
-- 这一行整个没有（旧表 / 旧版主机下发的表没有 cd=）= CD_DEF（火枪 0.1 秒）；有这一行但没写某个键 = 那件不冷却
-- §212 火枪默认 15 → 0.1（用户 11-10"火枪冷却去掉"，但枪还在场时照样不能再召）：GCD.sec() = 0 会把整个 GCD（含在场挡）关掉，
-- 所以写 0.1 不写 0；0 仍是"整个关掉"
-- §200 瞬影冷却 ShunYingDodge（天赋瞬身）也在这一行；没写 = 默认 10 秒（DCD.secKey），写 0 = 不冷却；只挡瞬影自己。
-- §200.10 普通闪避 / 灵蛇剑架势闪避不再冷却（改成扣杀气，见下面 cost 行）：旧版主机 / 服务器下发的 cd= 里还带 Dodge / SnakeDodge，收下、没人用
BAL.CD_DEF, BAL.CD_CAP = { ZiMingJian_HuoQiang = 0.1, ShunYingDodge = 10 }, 60
function BAL.cleanCooldown(t)
    if type(t) ~= "table" then t = BAL.CD_DEF end
    local o = {}
    for k, v in pairs(t) do
        if type(k) == "string" and k:match("^[%w_]+$") and type(v) == "number" and v >= 0 and v <= BAL.CD_CAP then o[k] = v end
    end
    return o
end
BAL.COOLDOWN = BAL.cleanCooldown(nil)
-- §200.10 / §200.11 消耗 / 杀气规则（表里 cost = { Dodge = 50, SnakeDodge = 50, SwitchKeepShachi = 1 }，跟着数值表下发 co=）：
-- Dodge = 普通闪避每段扣多少杀气、SnakeDodge = 灵蛇剑架势闪避每段扣多少（杀气不够照样闪、扣到 0 为止）；
-- SwitchKeepShachi = 1：切武器不回满杀气、保持切之前的值（原版切武器会把杀气回满）；0 = 按原版。
-- 整行没有（旧表 / 旧版主机 / 服务器下发的表没有 co=）或行里没写某个键 = 默认（20 / 20 / 开）。只在武器平衡开着、对局交手中生效
BAL.COST_DEF, BAL.COST_CAP = { Dodge = 50, SnakeDodge = 50, SwitchKeepShachi = 1 }, 1000
function BAL.cleanCost(t)
    local o = {}
    for k, v in pairs(type(t) == "table" and t or {}) do
        if type(k) == "string" and k:match("^[%w_]+$") and type(v) == "number" and v >= 0 and v <= BAL.COST_CAP then o[k] = v end
    end
    return o
end
function BAL.cost(key)       -- 表里这个键的值；没写 = 默认
    local v = BAL.COST[key]
    if v == nil then v = BAL.COST_DEF[key] end
    return v or 0
end
BAL.COST = BAL.cleanCost(nil)
-- §199 持续伤害系数（表里 dot = { 招名或族名 = 系数 }）：这招挂上的点燃 / 流血 / 中毒 / 混沌，整个持续期间按"伤害倍率 × 这个系数 × 等级"算，
-- 不跟着替身后来出的招变（DOT 段）。没列的招按这招自己的系数、但不超过 1（BAL.dotScale）。
-- ctrl = { 异常类型 = 秒 }：控制类异常（冰冻 frost…）在交手中最长挂多少秒，到点挨打方自己撤（0 / 没写 = 不管）。
-- 两行都跟着数值表下发（§158 的 d= / cc=），只在武器平衡开着、对局交手中生效
BAL.DOT, BAL.CTRL, BAL.DOT_CAP, BAL.CTRL_CAP = {}, {}, 5, 30
BAL.CTRL_IDS = { frost = true, elec = true, ignite = true, poison = true, bleed = true, chaos = true }
function BAL.cleanDot(t)
    local o = {}
    for k, v in pairs(type(t) == "table" and t or {}) do
        if type(k) == "string" and (k:match("^GA_[%w_]+$") or k:match("^%w+$")) and type(v) == "number" and v >= 0 and v <= BAL.DOT_CAP then o[k] = v end
    end
    return o
end
function BAL.cleanCtrl(t)
    local o = {}
    for k, v in pairs(type(t) == "table" and t or {}) do
        if type(k) == "string" and BAL.CTRL_IDS[k] and type(v) == "number" and v >= 0 and v <= BAL.CTRL_CAP then o[k] = v end
    end
    return o
end
-- §206 冰缓（白影 / 刺骨混沌冰形态 / 圣母邪扇冰：打中积冰冻值，冻住之前身上挂 GE_Frost_HasAccumulation，每 0.2 秒掉一下血、
-- 跟冰冻积累涨，另有按积累的减速）。chill = { dmg = 倍数 }：交手中 + 武器平衡开时冰缓那一下掉血乘多少（0 = 去掉，1 = 原版不管）；
-- 减速、冰冻积累、冻住都不动。单独一行、单独的数值表字段 ch=（cc= 的旧解码遇到不认识的键会整张表不认，不能塞进 ctrl 行）；
-- 表里 / 下发的表里没有这一行 = 默认 BAL.CHILL_DEF（去掉伤害）
BAL.CHILL, BAL.CHILL_DEF, BAL.CHILL_IDS = {}, { dmg = 0 }, { dmg = true }
function BAL.cleanChill(t)
    local o = {}
    for k, v in pairs(type(t) == "table" and t or {}) do
        if type(k) == "string" and BAL.CHILL_IDS[k] and type(v) == "number" and v >= 0 and v <= 1 then o[k] = v end
    end
    return o
end
function BAL.chill(key)
    local v = BAL.CHILL[key]
    if v == nil then v = BAL.CHILL_DEF[key] end
    return v
end
-- §212 召唤物每发伤害（表里 sdmg = { <武器>_<召唤物> = 每发多少点 }）：交手中 + 武器平衡开时，认得出是这件召唤物打的那一下，
-- 挨打方把这一下的掉血改成这个数；本地 AI 的 td= 这一下也按这个数报（GDMG 段）。现在只有 ZiMingJian_HuoQiang（紫冥剑 DB 召出的火枪）。
-- 单位 = 每发掉多少血（最终值，不再乘伤害倍率 / 等级 / 系数）；0 = 不管（按召唤那招的系数，§177）；负数 / 坏值不收（按默认）。
-- 单独一行、单独的数值表字段 sd=（不塞进 cd= 等旧字段）；整行没有 / 没写某个键 = 默认 SDMG_DEF（火枪 1）
BAL.SDMG, BAL.SDMG_DEF, BAL.SDMG_CAP = {}, { ZiMingJian_HuoQiang = 1 }, 10000
function BAL.cleanSdmg(t)
    local o = {}
    for k, v in pairs(type(t) == "table" and t or {}) do
        if type(k) == "string" and k:match("^[%w_]+$") and type(v) == "number" and v >= 0 and v <= BAL.SDMG_CAP then o[k] = v end
    end
    return o
end
function BAL.sdmg(key)
    local v = BAL.SDMG[key]
    if v == nil then v = BAL.SDMG_DEF[key] end
    return v
end
do
    local okB, T = pcall(require, "pbz_balance")
    if not (okB and type(T) == "table") then okB, T = pcall(function() return dofile(ROOT .. "/Scripts/pbz_balance.lua") end) end
    if okB and type(T) == "table" then
        BAL.FAMILY, BAL.MOVE, BAL.SUMMON = T.family or {}, T.moves or {}, BAL.cleanSummon(T.summon)
        BAL.COOLDOWN = BAL.cleanCooldown(T.cooldown)
        BAL.DOT, BAL.CTRL = BAL.cleanDot(T.dot), BAL.cleanCtrl(T.ctrl)       -- §199
        BAL.CHILL = BAL.cleanChill(T.chill)                                  -- §206
        BAL.SDMG = BAL.cleanSdmg(T.sdmg)                                     -- §212
        BAL.COST = BAL.cleanCost(T.cost)                                     -- §200.10
        local n, ns, nd = 0, 0, 0
        for _ in pairs(BAL.MOVE) do n = n + 1 end
        for _ in pairs(BAL.SUMMON) do ns = ns + 1 end
        for _ in pairs(BAL.DOT) do nd = nd + 1 end
        out("武器平衡表 pbz_balance.lua：%d 招（召唤留场 %d 招，持续伤害系数 %d 项）", n, ns, nd)
    else
        out("!! 武器平衡表 pbz_balance.lua 加载失败（%s），全部按 1 / 影之武装系数", tostring(T))
    end
end

-- 一招的系数（纯函数），返回 系数, 依据
function BAL.moveScale(name)
    local o = BAL.MOVE[name]
    if o then return o, "单招" end
    local fam = name:match("^GA_Hun_(%w+)_")
    local f = fam and BAL.FAMILY[fam] or 1.0
    if LO.isEdgeAttack(name) then return f * LO.EDGE_SCALE, "影之武装" end
    return f, f ~= 1.0 and ("族 " .. fam) or nil
end

-- §186.3 架势里的同名招：偃月刀先放架势 Stance_C 再按 B，发出来的招名还是 B_C，伤害却是强化版（采集 B_C 1091 / B_Reinforced_C 1771；
-- 11-09 实战 B_C 每点攻击 3.5，采集 1.4）。STANCE_WIN 秒内同族放过架势 → 系数按 <招>_Reinforced_C 算（表里有这一行才换）。
-- 两边各记各的：收到的对方事件记 BAL.rStance（替身放招乘系数），自己发的记 BAL.myStance（TOUCH.scale 回报），规则一样所以对称。
-- 窗口 10 秒是按 11-09 实战日志估的（架势后 2 / 5 / 8 秒的 B 是强化伤害，11 秒的不是），待实测校
BAL.STANCE_WIN, BAL.STANCE_FAM, BAL.rStance, BAL.myStance = 10, { YanYueDao = true }, {}, {}
function BAL.noteStance(t, name, tn)
    local f = name and name:match("^GA_Hun_(%w+)_Stance_C$")
    if f and BAL.STANCE_FAM[f] then t[f] = tn end
end
function BAL.resolve(name, t, tn)
    local f = name and name:match("^GA_Hun_(%w+)_")
    local at = f and BAL.STANCE_FAM[f] and t[f]
    if at and tn - at <= BAL.STANCE_WIN and name:find("_C$") and not name:find("Reinforced", 1, true) then
        local alt = (name:gsub("_C$", "_Reinforced_C"))
        if BAL.MOVE[alt] then return alt end
    end
    return name
end

-- 替身放攻击招时调（AIR.fire，放之前）。返回 系数有没有变（变了调用方马上重写替身攻击力）
function BAL.active() return BAL.on and NET.flagNow("bal") end
function BAL.onFire(name, tn)
    if not BAL.active() then return false end
    local before = BAL.now(tn)
    BAL.prev, BAL.prevAt, BAL.last, BAL.lastAt = BAL.last, BAL.lastAt, name, tn
    BAL.noteSummon(name, tn)
    return BAL.now(tn) ~= before
end

-- §177 这招是召唤类（表里 summon 有它）→ 记一条"召唤在场到 tn + 秒数"；同一招再放就续上。最多留 SUM_MAX 条
function BAL.noteSummon(name, tn)
    local hold = name and BAL.SUMMON[name]
    if not hold then return false end
    local keep = {}
    for _, s in ipairs(BAL.sums) do
        if s.untilT > tn and s.name ~= name then keep[#keep + 1] = s end
    end
    keep[#keep + 1] = { name = name, untilT = tn + hold }
    while #keep > BAL.SUM_MAX do table.remove(keep, 1) end
    BAL.sums = keep
    return true
end

-- 现在该用的系数：HOLD 秒内放过招 → 这招的（TAIL 秒内的上一招更小就用上一招的）；召唤还在场 → 和召唤那招的取小的；
-- 都没有 / 关着 → nil（走原来的影之武装判断）
function BAL.now(tn)
    if not BAL.active() then return nil end
    local f, why, name
    if BAL.last and tn - BAL.lastAt < BAL.HOLD then
        f, why = BAL.moveScale(BAL.last)
        name = BAL.last
        if BAL.prev and tn - BAL.prevAt < BAL.TAIL then
            local f2, why2 = BAL.moveScale(BAL.prev)
            if f2 < f then f, why, name = f2, why2, BAL.prev end
        end
    end
    for _, s in ipairs(BAL.sums) do
        if s.untilT > tn then
            local fs, ws = BAL.moveScale(s.name)
            if not f or fs < f then f, why, name = fs, (ws or "") .. "（召唤在场）", s.name end
        end
    end
    if not f then return nil end
    return f, string.format("%s %s ×%.0f%%", name, why or "", f * 100)
end
-- §183 裂斩 HOLD 秒内（替身放的是 GA_GlobalActionAbility_LieZhan_C_C / _CB_C）：等级倍率按 ×1（STD.flatScale），系数表才对得上
function BAL.flatLevel(tn)
    return BAL.active() and BAL.last ~= nil and tn - BAL.lastAt < BAL.HOLD
        and BAL.last:find("^GA_GlobalActionAbilit%a*_LieZhan_") ~= nil
end

-- §197 一招总伤害上限（受击方兜底）。绝影大招 GA_Hun_Double_JueYing_C_C 的乌鸦不是处决：游戏资产 BD_GA_Hun_Double_JueYing_C_Crow_Near
-- 是普通子弹（PhysicalDamage ×8、AngerDamage ×4，没有处决 / 斩杀 / 改血量的东西），子弹本体 BP_JueYing_Crow 有 5 个伤害碰撞体
-- （Damage Collider New…New4，穿透），近身版直接在你身上生成，几个碰撞体同一帧都碰到你 → 一帧里结算 1–5 下"整只乌鸦"。
-- 11-09 实测按攻击力归一（Attack 200、30 级 = 表的口径）一下约 1264：23:24:13 Attack 330 一下 2085 = 1264 × 1.65（1 下）、
-- 11:38:16 Attack 200 一下 2592（2 下）、23:43:10 / 23:43:19 Attack 154 一下 ≥ 3857（≥ 4 下，打空）。系数只能整体缩攻击力，缩不掉"下数"，
-- 所以 0.77 照样一步打空。做法：武器平衡开着、对局交手中，这几招一招累计掉血超过"表里原版 × 系数"的 SLACK 倍 → 按那个数改写血量
-- （锁血把血钳在 0.01，没真死，改回来不影响倒地判断：matchStep 在 netJudge 之后才看血量）。只在联机判定里，单机不走这里。
-- RAW = data/balance_rough.csv 的"原版"（Attack 200、30 级装着 ×3.9、伤害 100%），同结构（多碰撞体的波 / 乌鸦）的大招一起列
CAP = { SLACK = 1.25, REF_ATK = 200, n = 0,
        RAW = { GA_Hun_Double_JueYing_C_C = 2592, GA_Hun_Double_JueYing_C_Air_C = 2592,
                GA_Hun_BronzeSword_C_C = 1572, GA_Hun_Horizontal_C_C = 1952,
                GA_GlobalActionAbility_LieZhan_C_C = 2130,       -- §199 裂斩：§183 的原版（Attack 200、不吃等级、伤害 100%）
                -- §203 玉双环：DB 一次扔好几个环、切刀斩的环也落在 DB 的窗口里，一帧能结算 4–7 下；大招晚落的环 / B_Dash 7 段同理。
                -- 原版 = data/move_manual.csv（DB 3503 实战 3 段中位、大招 3039 打空下限、B_Dash 5906 实战 7 段）
                GA_Hun_Jade_DB_C = 3503, GA_Hun_Jade_C_Range_C = 3039, GA_Hun_Jade_B_Dash_C = 5906 },
        -- §199 裂斩不吃武器等级（§183 STD.flatScale），按表口径等级比按 1 算
        FLAT = { GA_GlobalActionAbility_LieZhan_C_C = true },
        -- §199 这招挂上的持续伤害原版（同口径，挂满一次）。应有 = 直接 × 系数 + 持续 × 持续系数；DOT 段没钉住（游戏没认
        -- Amplification_Ignite 之类）时这里兜底。裂斩 2460 是 22:19:58 一次实测外推的估算（HANDOVER §199.2），待实测
        DOT_RAW = { GA_GlobalActionAbility_LieZhan_C_C = 2460 },
        -- §199.9 直接 + 持续合在一起的总预算（Attack 200、伤害 100%、表口径；用户 §199"两个合在一起接近总伤害预算"）：
        -- 列在这里的招应有 = 预算 × 伤害 × 攻击 / 200（× 等级比），**不留 1.25 倍余量**（TOTAL_SLACK）。11-10 07:24–07:36 实测
        -- 裂斩直接 -917 + 点燃（游戏不认替身增伤）累计到 -1480 才被 1.25 倍门槛（1459）拦住，一招约 1.4 倍预算。
        -- 裂斩 1050 = §183 L1+圈一招预算；第二段 _CB_C（§183.1 预算 500）没有原版数，直接伤害可能自己就到 500，先不列
        TOTAL = { GA_GlobalActionAbility_LieZhan_C_C = 1050 }, TOTAL_SLACK = 1.0 }
-- 这一招按表应有的一招总伤害（纯函数）：原版 × 系数 × 伤害倍率 × 对方攻击 / 200 × 等级倍率 / 30 级倍率。
-- 返回 数, 说明, 门槛倍数（超过 数 × 门槛倍数 才改）；不管的招 nil
function CAP.expected(name)
    local raw = name and CAP.RAW[name]
    local total = name and CAP.TOTAL and CAP.TOTAL[name]
    if not (raw or total) or not BAL.active() then return nil end
    local f = not total and BAL.moveScale(name)
    local draw = not total and CAP.DOT_RAW and CAP.DOT_RAW[name]
    local d = draw and BAL.dotScale(name) or 0
    local dm = NET.dmgNow() / 100
    local atk
    if STD.active() then atk = STD.ATTR.Attack
    else atk = tonumber(NET.ratt and (NET.ratt:match("^Attack:([%-%d%.e+]+)") or NET.ratt:match(";Attack:([%-%d%.e+]+)"))) end
    atk = atk or CAP.REF_ATK
    -- 等级：标准数值 = 30 级；对方发了等级 = 对方那把；都没有 = 游戏按本机存档乘（本机没装着 = ×1）
    local ref = STD.mult(30)
    local lm
    if STD.active() then lm = STD.TARGET_MULT
    elseif NET.rlvW then lm = STD.mult(NET.rlvW)
    else
        local id, shachi = STD.idOf(NET.rwc)
        lm = id and STD.localMult(id, shachi) or ref
    end
    if CAP.FLAT and CAP.FLAT[name] then lm = ref end
    if total then
        local v = total * dm * atk / CAP.REF_ATK * lm / ref
        return v, string.format("直接 + 持续总预算 %d × 伤害 %.0f%% × 攻击 %.0f/%d × 等级 %.2f/%.2f = %.0f", total, dm * 100, atk, CAP.REF_ATK, lm, ref, v),
            CAP.TOTAL_SLACK
    end
    local v = (raw * f + (draw or 0) * d) * dm * atk / CAP.REF_ATK * lm / ref
    if draw then
        return v, string.format("（原版 %d × 系数 %.2f + 持续 %d × 持续系数 %.2f）× 伤害 %.0f%% × 攻击 %.0f/%d × 等级 %.2f/%.2f = %.0f",
            raw, f, draw, d, dm * 100, atk, CAP.REF_ATK, lm, ref, v), CAP.SLACK
    end
    return v, string.format("原版 %d × 系数 %.2f × 伤害 %.0f%% × 攻击 %.0f/%d × 等级 %.2f/%.2f = %.0f", raw, f, dm * 100, atk, CAP.REF_ATK, lm, ref, v),
        CAP.SLACK
end
-- 掉血那一帧调：step = 这一帧掉的，total = 这招连这一帧累计，hpBefore = 这一帧之前的血。超了 → 改写血量，返回改后这一帧该掉的；不管 → nil
-- rec = 这招的结果记录（NET.lastHit.r；第一段还没有就 nil）。§199.9：这招改过一次以后（rec.capped）门槛降到 1 倍——
-- 以前改完只把这一跳压到"应有"以内，累计还停在 1.25 倍门槛下面，后面的跳伤每跳都超门槛、每跳记一行"改成 -0"（07:25 那 40 多行），
-- 而且累计一直卡在约 1.25 倍。现在：超过以后整跳吃掉、只记第一次那行，合计在这招结束时（CAP.flush）记一行
function CAP.fix(p1, name, step, total, hpBefore, tn, rec)
    if MATCH.state ~= "fight" or not hpBefore or hpBefore <= 0 then return nil end
    local exp, why, slack = CAP.expected(name)
    local capped = rec and rec.capped
    if not exp or total <= exp * (capped and 1.0 or slack or CAP.SLACK) then return nil end
    local allow = math.max(0, step - (total - exp))       -- = max(0, 应有 − 这一跳之前的累计)：只补这一跳，前面放过去的不回补
    local hp = hpBefore - allow
    if not setAttr(p1, "Health", hp) then return nil end
    if capped then
        rec.capEatN, rec.capEat = (rec.capEatN or 0) + 1, (rec.capEat or 0) + (step - allow)
        CAP.open = rec
        return allow
    end
    CAP.n = CAP.n + 1
    out("!! 绕过平衡的一下：招 %s / 原扣 -%.0f（这招累计 -%.0f）/ 改成 -%.0f（累计 -%.0f；%s，超过 ×%.2f 才改；之后这招再超出的整跳吃掉、结束时记合计；§197 兜底，第 %d 次）",
        name, step, total, allow, total - step + allow, why, slack or CAP.SLACK, CAP.n)
    if rec then rec.capped, rec.capName = true, name end      -- 第一段（rec 还没建）由 netJudge 建好结果后标上
    return allow
end
-- netJudge 每帧调（cur = 现在的 NET.lastHit.r）：被吃过跳伤的那招结束了（换了招 / 窗口过了）→ 记一行合计
function CAP.flush(cur)
    local r = CAP.open
    if not r or r == cur then return end
    CAP.open = nil
    if (r.capEatN or 0) > 0 then
        out("!! 绕过平衡：招 %s 改过之后又吃掉 %d 跳、共 -%.0f（这招累计停在 -%.0f；§199.9）", r.capName or "?", r.capEatN, r.capEat or 0, r.v or 0)
    end
end

-- §199 持续伤害（点燃 / 流血 / 中毒 / 混沌）按"挂上它的那招"钉住系数（用户 11-10："点燃和本身伤害合在一起算，首先削点燃伤害，
-- 然后削弱招式，两个合在一起接近总伤害预算"）。问题（§196.3）：持续伤害每跳由挨打方本机的 GE 结算，来源是替身，读的是替身**当时的**
-- 攻击力（残钢刃流血每跳 = 替身 Attack × 0.014，换招跟着变，HANDOVER §199.1）；裂斩 HOLD 2.5 秒一过替身攻击力回到 ×3.9，点燃跟着变大，
-- 替身后来出别的招也会把它拉高 / 压低。挨打方只能轮询血量，分不出哪一下是跳伤、哪一下是刀（跳伤 0.2 秒一下、和多段招的小段一样大），
-- 所以不在挨打方改血，而是改替身身上**只管这种持续伤害**的增伤属性 Amplification_<Ignite/Bleed/Poison/Chaos>（攻击侧属性，§102 起随 att=
-- 同步；游戏的伤害原因标签 Damage.Cause.StatusInfliction.<种类> 和它同名）：
--   ① 我身上挂上一种持续伤害（INF.mine 看到"※ 我点燃了"）→ 记来源招（最近 1 秒中招的那招，没有就按 HOLD 内替身放的招）和
--      钉住系数 pin = 当时替身攻击力系数 ÷ 那招的直接系数 × 持续系数（= 伤害倍率 × 等级 × 持续系数）；
--   ② 持续期间替身 Amplification_<种类> = (1 + 对方原值) × pin ÷ 替身现在的攻击力系数 − 1 → 每跳 = 原版 × pin，不管替身后来出什么招；
--   ③ 还没挂上时（替身放招的 HOLD 内）先按 持续系数 ÷ 直接系数 预设好，挂上那一下按快照算的持续伤害（中毒每跳是定死的）也对；
--   ④ 结束 / 不在交手 / 武器平衡关 → 写回对方原值（LO.apply 的 key 带上 DOT.key，变了就重写）。
-- 持续系数 BAL.dotScale：表里 dot 行（招名 > 族名），没列的 = 这招自己的系数、但不超过 1（宁可少打：直接系数 3 的招别把点燃也放大 3 倍）。
-- （①–④ 是 §199 的写法；②④ 改替身增伤那条 07:24 实测游戏不认，§199.9 换成下面挨打方自己的承伤乘法，见 DOT.takeStep。裂斩另有 CAP 兜底。）
-- 单机、对局外、武器平衡关都不动
-- §199.9（11-10 总控实测 main 40853aa，mp_probe.log 07:24–07:36）：游戏**不认**替身身上的 Amplification_Ignite——HOLD 内写成 -0.898、
-- 每跳还是 22–24（Attack 98；§199.2 Attack 200、没写增伤时 41–45，按攻击力归一一样大）；HOLD 后 -0.987、每跳 22–50（是 Attack 98→780 拉上去的，
-- 不是增伤）。资产名字表：每跳 GE_Ignite_Dot 只有 Damage.Attack.Target.FireDamage + SetByCaller.IgniteTickDamage，不带 Amplification_Ignite。
-- 所以改走**挨打方自己**的承伤乘法属性 TakenReductionMultiplier_<伤害类型>（中性 1.0）：游戏饰品辟火符 GE_Accessory_ResistFire_Lv1/2
-- "自身受到的火焰伤害 -50%"改的就是 TakenReductionMultiplier_Fire（同族的 _DefenceShachi 神机指环 0.49 实测生效，§119/§170）。
-- 点燃每跳是 FireDamage → _Fire；流血 GE_BleedSmall 是 BloodDamage → _Blood；中毒（AttackDataProvider_Poison，类型没查到）按 _Toxin；混沌 _Chaos。
-- 只写当前值、基础值不动（§170.9：改属性函数 GE_MA_*_Override 对带饰品乘法加成的属性会算歪、还写进基础值；当前值不进存档，游戏重算就回到自己的值），
-- 只在交手中 + 武器平衡开 + 这种持续伤害钉住了来源招时写，结束 / 不在交手 / 换对手写回。替身另放了一招、那招 HOLD 内先放开
-- （那招直接伤害里的火 / 血部分不能跟着压）。旧的替身增伤（DOT.want）默认关（USE_AMP），游戏以后认了也别两层叠
DOT = { on = true, DEF_MAX = 1.0, SRC_WIN = 1.0, AMP_MIN = -0.999, AMP_MAX = 20, LOG_MAX = 40, logs = 0, tn = 0, cuts = 0,
        USE_AMP = false, TAKEN_MIN = 0.01,
        ATTR = { Amplification_Ignite = "ignite", Amplification_Bleed = "bleed", Amplification_Poison = "poison", Amplification_Chaos = "chaos" },
        TAKEN = { ignite = "TakenReductionMultiplier_Fire", bleed = "TakenReductionMultiplier_Blood",
                  poison = "TakenReductionMultiplier_Toxin", chaos = "TakenReductionMultiplier_Chaos",
                  chill = "TakenReductionMultiplier_Ice" },          -- §206 冰缓（DOT.chillRatio）
        NAME = { ignite = "点燃", bleed = "流血", poison = "中毒", chaos = "混沌", chill = "冰缓" },
        CHILL_ACC = 1, CHILL_LINGER = 1.0, chillAt = nil,
        src = {}, taken = {} }
function DOT.say(fmt, ...)
    if DOT.logs >= DOT.LOG_MAX then return end
    DOT.logs = DOT.logs + 1
    out(fmt, ...)
end
-- 一招挂上的持续伤害按多少算（相对原版）：表里 dot 招名 > 族名 > 这招自己的系数（不超过 DEF_MAX）。返回 系数, 依据
function BAL.dotScale(name)
    if not name then return nil end
    local v = BAL.DOT[name]
    if v then return v, "持续系数（单招）" end
    local fam = name:match("^GA_Hun_(%w+)_")
    v = fam and BAL.DOT[fam]
    if v then return v, "持续系数（族 " .. fam .. "）" end
    local f = BAL.moveScale(name)
    return math.min(f, DOT.DEF_MAX), "跟这招的系数（不超过 1）"
end
function DOT.active() return MATCH.state == "fight" and DOT.on and BAL.active() end

-- 我身上挂上了一种持续伤害（INF.mine 调，tn = 现在）
function DOT.onStart(kind, tn)
    if not DOT.NAME[kind] then return end
    DOT.src[kind] = nil
    if not DOT.active() then return end
    local name, how
    if NET.lastHit and NET.lastHit.name and tn - (NET.lastHit.at or -100) <= DOT.SRC_WIN then
        name, how = NET.lastHit.name, "刚打中我的招"
    elseif BAL.last and tn - BAL.lastAt < BAL.HOLD then
        name, how = BAL.last, "替身刚放的招"
    end
    if not name then
        DOT.say("※ 持续伤害：我%s了，来源招不明（1 秒内没中招、替身没在放招）→ 不钉，跟替身攻击力走", DOT.NAME[kind])
        return
    end
    local f = BAL.now(tn)
    local base = (LO.atkScale or 1.0) / (f and f > 0 and f or 1.0)
    local d, why = BAL.dotScale(name)
    DOT.src[kind] = { name = name, pin = base * d, d = d, at = tn }
    DOT.say("※ 持续伤害：我%s了，来源 %s（%s）%s ×%.2f → 整个持续期间按替身攻击力系数 ×%.2f 算（不跟后来的招变）",
        DOT.NAME[kind], name, how, why, d, base * d)
end
function DOT.onEnd(kind, tn)
    local s = DOT.src[kind]
    if s then DOT.say("※ 持续伤害：我%s结束了（来源 %s，钉了 %.1f 秒）", DOT.NAME[kind] or kind, s.name, tn - s.at) end
    DOT.src[kind] = nil
end
-- 这一种的增伤要乘多少（nil = 不动）：挂着 → pin ÷ 现在的系数；还没挂、替身 HOLD 内在放招 → 持续系数 ÷ 直接系数
function DOT.ratio(kind, tn)
    if not DOT.active() then return nil end
    local s = DOT.src[kind]
    local cur = LO.atkScale or 1.0
    if s then return cur > 0 and s.pin / cur or nil end
    if BAL.last and tn - BAL.lastAt < BAL.HOLD then
        local f = BAL.moveScale(BAL.last)
        local d = BAL.dotScale(BAL.last)
        if f and f > 0 and d then return d / f end
    end
    return nil
end
-- LO.apply 写替身属性时调：Amplification_<种类> 按上面的比例改，其余原样
function DOT.want(n, base)
    local kind = DOT.USE_AMP and DOT.ATTR[n]
    if not kind then return base end
    local k = DOT.ratio(kind, DOT.tn)
    if not k or math.abs(k - 1) < 1e-3 then return base end
    local v = (1 + base) * k - 1
    return math.max(DOT.AMP_MIN, math.min(DOT.AMP_MAX, v))
end
-- 放进 LO.apply 的 key：比例变了就重写替身属性
function DOT.key()
    if not DOT.USE_AMP then return "" end
    local o = {}
    for _, kind in ipairs({ "ignite", "bleed", "poison", "chaos" }) do
        local k = DOT.ratio(kind, DOT.tn)
        if k and math.abs(k - 1) >= 1e-3 then o[#o + 1] = string.format("%s%.3f", kind, k) end
    end
    return #o > 0 and ("|dot:" .. table.concat(o, ",")) or ""
end
-- §199.9 挨打方自己的承伤乘法要乘多少（nil = 不动，第二个返回值是原因）：只在钉住了来源招时；= 钉住系数 ÷ 替身现在的攻击力系数
-- （每跳 = 原版 × 替身系数 × 承伤乘法 = 原版 × 钉住系数）；只压不放大；替身挂上以后又放了别的招、那招 HOLD 内放开
function DOT.takenRatio(kind, tn)
    if kind == "chill" then return DOT.chillRatio(tn) end      -- §206
    local s = DOT.src[kind]
    if not s or not DOT.active() then return nil end
    if BAL.last and BAL.lastAt > s.at and tn - BAL.lastAt < BAL.HOLD then return nil, "替身在放别的招" end
    local cur = LO.atkScale or 1.0
    if cur <= 0 then return nil end
    local k = s.pin / cur
    if k >= 1 - 1e-3 then return nil, "不用压" end
    return math.max(DOT.TAKEN_MIN, k)
end
-- §206 冰缓（线上反馈 11-10："冰缓 buff 可以叠的层数完爆其他所有异常，伤害也十分离谱"；用户"把伤害直接去掉吧"）。
-- 冰缓 = 冰冻积累 Frost_Accumulation > 0、还没冻住时身上的 GE_Frost_HasAccumulation（资产名字表：HitGameplayEfectComponent +
-- AttackDataProvider_FrostAccumulation、Hitreact.Strength.Income.None = 不出受击的一下伤害），每 0.2 秒一跳、大小按积累比例走曲线
-- CV_FrostDamage（积累 15% 以下 0、30% 0.05、90% 1.0），积累不掉的 4 秒左右是平台、之后跟着积累往下掉（mp_probe_2.log 15:45:36–15:45:59
-- 白影 7 → 13.5 → 16 → 18.5 / 跳；15:59:27 邪扇 9.8 / 跳；15:51:56 混沌冰大招 4.3–4.9 / 跳）。减速是另外两条曲线
-- CV_FrostNormalSlow / CV_FrostAttackSlow（按积累比例，移动 / 出招速度 ×1 → 0.5 / 0.6），不走伤害。
-- 伤害类型按 Ice 压：游戏饰品"自身受到的冰缓效果 -50%"（AC_ResistIce，GE_Accessory_ResistIce_Lv1/2）改的就是
-- TakenReductionMultiplier_Ice（+ 冰冻时长 _FrostDuration）；白影 / 混沌 / 邪扇自己的招资产里没有 IceDamage 标签（物理 + 通用 ElementDamage），
-- 所以压 _Ice 不碰它们的刀。挂着冰缓（积累 ≥ CHILL_ACC 或冻住中）+ 之后 CHILL_LINGER 秒内：当前值 = 玩家自己的值 × chill.dmg（下限 TAKEN_MIN）
function DOT.chillRatio(tn)
    if not DOT.active() then DOT.chillAt = nil; return nil, "不在交手 / 武器平衡关" end
    local m = BAL.chill("dmg")
    if not m or m >= 1 - 1e-3 then return nil, "数值表 chill.dmg = 1（冰缓伤害不管）" end
    local s = INF.me and INF.me.frost
    if s and ((s.lv or 0) > 0 or (s.acc or 0) >= DOT.CHILL_ACC) then DOT.chillAt = tn end
    if not DOT.chillAt or tn - DOT.chillAt > DOT.CHILL_LINGER then return nil, "冰缓结束" end
    return math.max(DOT.TAKEN_MIN, m)
end
-- 写回一种：当前值还是我们写的那个才写回（游戏中途重算过 = 已经是玩家自己的值，不碰）
function DOT.takenBack(p1, kind, why)
    local t = DOT.taken[kind]
    if not t then return end
    DOT.taken[kind] = nil
    if not valid(p1) then return end
    local c = attrOf(p1, t.a)
    if type(c) == "number" and t.want and math.abs(c - t.want) < 1e-4 then G.setAttrCur(p1, t.a, t.orig) end
    DOT.say("※ 持续伤害：%s 写回 %.4g（%s）", t.a, t.orig, why)
end
-- INF.mine 每 INF.EVERY 帧调（p1 = 我自己）：按 takenRatio 写 / 写回自己的 TakenReductionMultiplier_<类型> 当前值
function DOT.takeStep(p1, tn)
    DOT.p1 = p1
    for kind, a in pairs(DOT.TAKEN) do
        local k, why = DOT.takenRatio(kind, tn)
        local t = DOT.taken[kind]
        if k then
            local c = attrOf(p1, a)
            if type(c) == "number" then
                -- 第一次 / 游戏中途重算过（当前值不是我们写的）→ 现在的值当作玩家自己的
                if not t then t = { a = a }; DOT.taken[kind] = t end
                if not t.want or math.abs(c - t.want) >= 1e-4 then t.orig = c end
                local want = t.orig * k
                if math.abs(c - want) >= 1e-4 and G.setAttrCur(p1, a, want) then
                    if not t.k or math.abs(t.k - k) > 0.01 * t.k then
                        if kind == "chill" then
                            DOT.say("※ 冰缓：我自己的 %s %.4g→%.4g（×%.3f，数值表 chill.dmg %.2g；只压冰缓每 0.2 秒那一下，减速 / 冰冻积累不动；§206）",
                                a, t.orig, want, k, BAL.chill("dmg"))
                        else
                            DOT.say("※ 持续伤害：%s 我自己的 %s %.4g→%.4g（×%.3f = 钉住 %.3f ÷ 替身现在 ×%.2f；§199.9）",
                                DOT.NAME[kind], a, t.orig, want, k, DOT.src[kind].pin, LO.atkScale or 1.0)
                        end
                    end
                    t.want, t.k = want, k
                end
            end
        elseif t then
            DOT.takenBack(p1, kind, why or (DOT.src[kind] and "不在交手 / 武器平衡关" or "持续伤害结束"))
        end
    end
end
-- 交手中控制类异常（冰冻……）挂满表里 ctrl 的秒数 → 撤掉自己身上那个 GE（INF.mine 每 3 帧调，s = INF.me[类型]）
function DOT.ctrlStep(p1, ty, s, tn)
    local cap = BAL.CTRL[ty.id]
    if not cap or cap <= 0 or s.lv == 0 or not s.onAt or s.cutN == s.n or not DOT.active() then return end
    if tn - s.onAt < cap then return end
    s.cutN = s.n
    local ok = INF.strip(p1, ty)
    DOT.cuts = DOT.cuts + 1
    out("※ %s挂满 %.1f 秒（数值表 ctrl 上限 %.1f 秒，§199）→ 撤掉自己的 %s：%s（第 %d 次；对方替身跟着 inf= 解除）",
        ty.name, tn - s.onAt, cap, ty.lv[1] and ty.lv[1][2] or "?", ok and "已撤" or "撤不掉", DOT.cuts)
end

-- 每次驱动 + 替身放招前：攻击力系数 = 伤害倍率 × （武器平衡系数，没有就按影之武装），写进替身
function LO.rescale(pup, tn)
    LO.atkDm = NET.dmgNow()
    local edge = ST.pupEdgeAt and tn - ST.pupEdgeAt < LO.EDGE_HOLD
    local f, why = BAL.now(tn)
    if f then LO.atkScale, LO.scaleWhy = NET.atkScale(false) * f, why
    else LO.atkScale, LO.scaleWhy = NET.atkScale(edge), nil end
    -- §144 标准数值：再乘 30 级倍率 ÷ 本机倍率；§148 普通房间：乘 对方那把的倍率 ÷ 本机倍率（本机倍率见 STD.localMult）
    local lf, lwhy = STD.levelScale(edge)
    if not edge and BAL.flatLevel(tn) then lf, lwhy = STD.flatScale(false) end   -- §183 裂斩不吃武器等级倍率
    local lname = STD.active() and "标准数值" or "武器等级"
    if lf ~= 1.0 then
        LO.atkScale = LO.atkScale * lf
        LO.scaleWhy = (LO.scaleWhy and (LO.scaleWhy .. "；") or "") .. string.format("%s %s ×%.2f", lname, lwhy or "", lf)
    end
    -- §207.6 等级系数 ×1 也写进中招日志：本机装着同一把时游戏自己按本机等级乘（替身 Attack 200 / ×100% 实际也是 30 级），
    -- 以前这种情况日志里看不出标准数值 / 等级有没有算上
    LO.lvNote = (lf == 1.0 and lwhy) and string.format("%s %s ×1.00，游戏按本机装着的等级自己乘", lname, lwhy) or nil
    if lwhy and lwhy ~= LO.stdWhy then LO.stdWhy = lwhy; out("%s：替身等级系数 ×%.2f（%s）", lname, lf, lwhy) end
    STD.tick(tn)
    ACC.tick(tn)                 -- §170.1
    DOT.tn = tn                  -- §199 LO.apply 里按这个时刻算持续伤害的增伤
    LO.apply(pup, NET.ratt)
end

-- 接收：把对方的攻击侧属性整套写进替身。att 变了、换了替身、或每 2 秒（替身自己的 GE 重新聚合会把值改掉）都重写
function LO.apply(pup, att)
    local names = LO.names(pup)
    if not (names and att and att ~= "") then return end
    local attKey = pathOf(pup) .. "|" .. att .. (STD.active() and "|std" or "")
    local key = attKey .. "|" .. LO.atkScale .. DOT.key()      -- §199 持续伤害的增伤变了也重写
    local first = key ~= LO.appliedKey
    if not first and ST.ticks - (LO.appliedAt or 0) < 60 then return end
    local onlyScale = first and attKey == LO.appliedAttKey      -- 只是系数变了：日志短一点
    local vals = {}
    for n, v in att:gmatch("([%w_]+):([%-%d%.e+]+)") do vals[n] = tonumber(v) end
    if STD.active() then vals.Attack, vals.ShachiAttack = STD.ATTR.Attack, STD.ATTR.ShachiAttack end   -- §144 攻击用基准
    local nSet, changed = 0, {}
    for _, n in ipairs(names) do
        local want = DOT.want(n, (vals[n] or LO.neutral(n)) * (LO.SCALED[n] and LO.atkScale or 1.0))   -- §199
        local cur = attrOf(pup, n)
        if type(cur) == "number" and math.abs(cur - want) > 1e-4 then
            if setAttr(pup, n, want) then
                nSet = nSet + 1
                if first and #changed < 8 then changed[#changed + 1] = string.format("%s %.4g→%.4g", n, cur, want) end
            end
        end
    end
    if onlyScale then
        LO.scaleLogs = (LO.scaleLogs or 0) + 1
        -- §86 系数 = 伤害倍率 × 影之武装系数：比伤害倍率还小 = 正在放影之武装
        local dm = LO.atkDm or 100
        local edge = LO.atkScale < dm / 100 - 1e-6
        if LO.scaleLogs <= 10 or LO.scaleLogs % 20 == 0 then
            local why = LO.scaleWhy and ("武器平衡 " .. LO.scaleWhy) or (edge and "放影之武装，PvP 系数")
                or (LO.lastEdge and "影之武装放完，恢复" or "伤害倍率")    -- §106 武器平衡的系数写明是哪招
            if dm ~= 100 and why ~= "伤害倍率" then why = why .. string.format("；伤害倍率 %d%%", dm) end
            out("  替身攻击力 ×%.0f%%（%s）：%s", LO.atkScale * 100, why, #changed > 0 and table.concat(changed, "，") or "没变")
        end
        LO.lastEdge = edge
    elseif first then
        out("替身攻击属性按对方配装写入：%d 项改动（对方包里 %d 项非中性）%s", nSet,
            (function() local k = 0 for _ in pairs(vals) do k = k + 1 end return k end)(),
            #changed > 0 and ("：" .. table.concat(changed, "，")) or "")
    end
    LO.appliedKey, LO.appliedAttKey, LO.appliedAt = key, attKey, ST.ticks
end

-- 防带偏：装好对方武器 0.5 秒后记下替身的被动技能签名；之后签名变了（本机玩家换装把替身带走了）就按对方武器重装
function LO.passiveSig(pup)
    local names = {}
    for n in pairs(activeAbilities(pup) or {}) do
        if n:find("Passive", 1, true) then names[#names + 1] = n end
    end
    table.sort(names)
    return table.concat(names, " ")
end

function LO.guard(pup)
    if not LO.GUARD or not ST.pupWeapon then return end
    local sig = LO.passiveSig(pup)
    if ST.pupSigAt then
        if ST.ticks >= ST.pupSigAt then ST.pupSig, ST.pupSigAt = sig, nil end
        return
    end
    if not ST.pupSig or sig == ST.pupSig then return end
    if ST.ticks - (LO.guardAt or -1000) < 90 then return end     -- 3 秒内最多重装一次，防来回抖
    LO.guardAt = ST.ticks
    local before, after = {}, {}
    for n in ST.pupSig:gmatch("%S+") do before[n] = true end
    for n in sig:gmatch("%S+") do after[n] = true end
    local d = {}
    for n in pairs(before) do if not after[n] then d[#d + 1] = "-" .. n end end
    for n in pairs(after) do if not before[n] then d[#d + 1] = "+" .. n end end
    local w = ST.pupWeapon
    out("替身配装被改动（%s），按对方武器重装 %s", table.concat(d, " "), w)
    ST.pupWeapon = nil
    equipWeapon(pup, w, "防带偏")
end

-- 排查用（默认不绑键）：模拟"本机玩家换武器"，看防带偏是否生效。第 1 次按：玩家装 Double；第 2 次按：装回。
-- 玩家原配装 [Long, ZhanMaBlade]（v0.15.2 实测 Double 会顶掉第 2 槽）→ 装回 = 先 ZhanMaBlade 再 Long
function LO.debugSwap()
    local p1 = getP1()
    if not valid(p1) then return end
    LO.dbg = not LO.dbg
    local seq = LO.dbg and { "Double" } or { "ZhanMaBlade", "Long" }
    for _, w in ipairs(seq) do
        local ok, err = pcall(function() return p1["Add Weapon And SwitchTo"](p1, FName(w), true, true) end)
        out("[排查] 玩家1 装 %s：%s", w, ok and "调用成功" or ("失败 " .. tostring(err)))
    end
end

-- ============================================================ 替身换装：只改替身自己的武器组件（v0.17.0，pp-weapon 分支）
-- 思路来自 Phantom Pact（moves.lua dressGhost）：不走 Add Weapon And SwitchTo（会写全局装备列表，§29），
-- 而是对替身自己的 Character Weapons Component 调 SetSlotWeapon(槽位, 当前序号, WeaponConfig)。
-- 发送方从自己的武器组件读手上那把的 WeaponConfig 资产路径（wc=），是否拔刀（arm=）。
-- 替身的蓝图会按本机背包把武器改回去，所以每 0.25 秒对一次，不对就重装（同一把失败后 5 秒内不重试）。
-- 每次换装前后都记下"本机玩家手上的 WeaponConfig"，用来实测会不会连带改到玩家。
-- v0.23.0：武器组件 / 影之武装 / 技能路径表 / 给技能 / GE 这几个 LO 函数搬到 pbz_game.lua（游戏适配层）
LO.slot, LO.slotShachi, LO.heldConfig, LO.armed, LO.config = G.LO.slot, G.LO.slotShachi, G.LO.heldConfig, G.LO.armed, G.LO.config
LO.index, LO.give, LO.geClass, LO.applyGE, LO.uiCompOf = G.LO.index, G.LO.give, G.LO.geClass, G.LO.applyGE, G.LO.uiCompOf
LO.setSlot, LO.curIndex, LO.switchTo = G.LO.setSlot, G.LO.curIndex, G.LO.switchTo      -- §144 方案 A+ / §195 切序号
LO.outfitOf, LO.applyOutfit, LO.appcProbe, LO.outfitOk = G.LO.outfitOf, G.LO.applyOutfit, G.LO.appcProbe, G.LO.outfitOk
LO.removeGE, LO.weaponEffects, LO.wgePath = G.LO.removeGE, G.LO.weaponEffects, G.LO.wgePath      -- §118 武器效果同步
LO.activeInstance, LO.funcsLike, LO.callNoArg, LO.callArgs = G.LO.activeInstance, G.LO.funcsLike, G.LO.callNoArg, G.LO.callArgs  -- §119 紫冥剑实验 / §139.4
LO.bulletsOf = G.LO.bulletsOf      -- §179 紫冥剑肩上的飞剑
LO.propsLike, LO.targetingComp, LO.tcSetLock = G.LO.propsLike, G.LO.targetingComp, G.LO.tcSetLock
LO.paramTypes, LO.lockCandidates, LO.paramList, LO.tcStop = G.LO.paramTypes, G.LO.lockCandidates, G.LO.paramList, G.LO.tcStop
LO.clearAbility, LO.giveClass, LO.loadObject = G.LO.clearAbility, G.LO.giveClass, G.LO.loadObject      -- §170 饰品换级 / §165.6 动画探针
LO.spawnFx, LO.fxOn = G.LO.spawnFx, G.LO.fxOn

function LO.short(path) return path and (path:match("([^.]+)$") or path) or "-" end

-- §195 对局中对方切武器时替身大卡顿（宇 11-09 日志：替身·换装 单帧 150–5574 ms，23:01:38 白影 ↔ 乱影进化切一次卡 5.6 秒）。
-- 以前对方在组里两把之间切一次，替身两格都 SetSlotWeapon 重建一遍（当前格换新的、另一格装回旧的），每次 ~200–400 ms，资源没进内存时 1–5 秒。
-- 现在记着替身武器组两格各装了什么（LO.has，按替身路径），要的那把已经在另一格 → 只 SetCurrentWeapon 切序号；
-- 新武器、而当前格那把正好是对方的另一把 → 新武器装进另一格再切过去（另一格不用再装回旧的）。
-- 切完 SWITCH_CHECK 次驱动后手上不是要的那把 = 这条路不灵：这次连接不再用，退回老办法。net/swap_switch_off.txt 存在 = 整个不用（不用重新部署）
LO.SWITCH_CHECK, LO.switchLogs = 15, 0
function LO.hasOf(pup)
    local p = pathOf(pup)
    if not (LO.has and LO.has.pup == p) then LO.has = { pup = p } end
    return LO.has
end
function LO.switchOk()
    if LO.switchBad then return false end
    if not LO.switchOffAt or now() - LO.switchOffAt > 10 then       -- 开关文件 10 秒看一次（换武器才会走到这里）
        LO.switchOffAt = now()
        local f = io.open(NET_DIR .. "/swap_switch_off.txt", "r")
        LO.switchOffFile = f ~= nil
        if f then f:close() end
    end
    return not LO.switchOffFile
end
-- 主武器槽换成 want：能切序号就切（返回 true），不能就返回 nil 走老办法
function LO.trySwitch(pup, slot, idx, want, held, st)
    if slot ~= LO.slot() or not LO.switchOk() then return nil end
    local h = LO.hasOf(pup)
    local other = idx == 0 and 1 or 0
    local how
    if h[other] ~= want then
        if not (h[idx] and h[idx] == NET.rwcOff) then return nil end     -- 当前格不是对方的另一把：照老办法覆盖当前格
        local ok, err = LO.setSlot(pup, slot, other, want)
        if not ok then out("替身换装（武器）新武器装进另一格（序号 %d）失败 %s，退回老办法", other, tostring(err)); return nil end
        h[other], how = want, "装进另一格再切"
    else
        how = "已在另一格，只切"
    end
    local ok, err = LO.switchTo(pup, slot, other)
    if not ok then
        LO.switchBad = true
        out("!! 替身切武器序号 SetCurrentWeapon 报错 %s：这次连接改回 SetSlotWeapon", tostring(err))
        return nil
    end
    LO.switchLogs = LO.switchLogs + 1
    if LO.switchLogs <= 30 then
        out("替身换装（武器）%s：序号 %d → %d，%s → %s", how, idx, other, LO.short(held), LO.short(want))
    end
    st.switchCheck = { want = want, at = ST.ticks + LO.SWITCH_CHECK, from = idx }
    ST.abMapKey, NET.sub = nil, {}
    return true
end

-- 一个槽位的换装。st = 这个槽位自己的状态（重试节流、换装后核对玩家）
function LO.dressSlot(pup, p1, cwc, slot, want, label, st)
    if not (want and want ~= "") then return end
    local key = pathOf(pup) .. "|" .. want
    local held = LO.heldConfig(pup, slot)
    if st.switchCheck and ST.ticks >= st.switchCheck.at then     -- §195 切序号后核对
        local c = st.switchCheck
        st.switchCheck = nil
        if held ~= c.want and c.want == want then
            LO.switchBad = true
            out("!! 替身切武器序号后手上是 %s、不是 %s：这次连接改回 SetSlotWeapon", LO.short(held), LO.short(c.want))
            st.swapAt = 0
        end
    end
    if held ~= want and (key ~= st.swapKey or ST.ticks >= (st.swapAt or 0)) then
        st.swapKey, st.swapAt = key, ST.ticks + 150
        local cfg = LO.config(want)
        if not cfg then
            out("替身换装（%s）：对方的 %s 加载不了（路径不合法或不是 WeaponConfig）", label, want)
            return
        end
        local mine = LO.heldConfig(p1, slot)
        local idx = 0
        pcall(function() idx = math.max(cwc:GetCurrentWeaponIndex(slot, false) or 0, 0) end)
        if LO.trySwitch(pup, slot, idx, want, held, st) then return end
        local ok, err = pcall(function() cwc:SetSlotWeapon(slot, idx, cfg) end)
        out("替身换装（%s）SetSlotWeapon(序号 %d) %s → %s：%s", label, idx, LO.short(held), LO.short(want),
            ok and "调用成功" or ("失败 " .. tostring(err)))
        if ok and slot == LO.slot() then LO.hasOf(pup)[idx] = want end
        ST.abMapKey, NET.sub = nil, {}
        st.checkMine = { before = mine, at = ST.ticks + 30 }     -- 1 秒后看玩家这个槽有没有跟着变
        LO.dressed = (LO.dressed or 0) + 1
    end
    if st.checkMine and ST.ticks >= st.checkMine.at then
        local now = LO.heldConfig(p1, slot)
        out("  换装后本机玩家（%s）：%s → %s %s", label, LO.short(st.checkMine.before), LO.short(now),
            now == st.checkMine.before and "（没变 ✓）" or "（!! 变了：替身换装连带改了玩家）")
        st.checkMine = nil
    end
end

-- v0.26.1 替身武器组的另一格（§76）。LO.dressSlot 只换"当前序号"那一格，另一格一直是替身蓝图按本机背包带来的武器；
-- 架势 GA_Hun_*_Stance_C 看整组武器，所以替身常放不出（2026-11-05 全部日志：双刃架势 113/692 成功；
-- 长刀架势换第 0 格时 10/10、换第 1 格时 43/68）。读不到另一格装的是什么，所以记下装过的（LO.offKey），
-- 当前序号 / 想要的武器变了、或架势放不出（activateOnPuppet 清 LO.offKey）时再装一次
function LO.dressOff(pup, cwc)
    local want = NET.rwcOff
    if not want or want == NET.rwc then return end
    local cur = 0
    pcall(function() cur = math.max(cwc:GetCurrentWeaponIndex(LO.slot(), false) or 0, 0) end)
    local other = cur == 0 and 1 or 0
    local key = pathOf(pup) .. "|" .. other .. "|" .. want
    if key == LO.offKey then return end
    LO.offKey = key
    if LO.hasOf(pup)[other] == want then return end      -- §195 切序号后另一格就是对方的另一把：不用再装
    local cfg = LO.config(want)
    if not cfg then
        out("替身武器组另一格：对方的 %s 加载不了", want)
        return
    end
    local ok, err = pcall(function() cwc:SetSlotWeapon(LO.slot(), other, cfg) end)
    out("替身武器组另一格 SetSlotWeapon(序号 %d) → %s：%s（当前序号 %d）", other, LO.short(want),
        ok and "调用成功" or ("失败 " .. tostring(err)), cur)
    if ok then LO.hasOf(pup)[other] = want end
    ST.abMapKey, NET.sub = nil, {}
end

-- §109 皮肤同步。发送方 of=<皮肤行名>:<肤色>:<帽子藏了 1/0>（读不到的写 -），每 3 秒读一次；
-- 接收方给替身"只改样子"地换上（LO.applyOutfit，签名对上才调），同一个"替身 × 皮肤 × 肤色 × 斗笠"只换一次、3 秒后再补一次
-- （替身蓝图生成后可能按本机存档把外观再刷回去）；换完 1 秒后核对本机玩家的皮肤没被连带改
function LO.encodeOutfit(p1)
    local o = LO.outfitOf(p1)
    if not o then return nil end
    local hat = o.hat == true and "1" or o.hat == false and "0" or "-"
    return string.format("%s:%s:%s", LO.outfitOk(o.outfit) and o.outfit or "-", o.skin and tostring(o.skin) or "-", hat)
end

-- of= 字段 → { outfit, skin, hat }；不合法的部分是 nil，整个没有 = nil（旧版对方 / 本地 AI：替身不动）
function LO.decodeOutfit(s)
    if type(s) ~= "string" or s == "" then return nil end
    local a, b, c = s:match("^([%w_%-]+):([%d%-]+):([01%-])$")
    if not a then return nil end
    local r = { outfit = LO.outfitOk(a) and a or nil, skin = tonumber(b), hat = nil }
    if c == "1" then r.hat = true elseif c == "0" then r.hat = false end
    if r.skin and (r.skin < 0 or r.skin > 3) then r.skin = nil end
    if not (r.outfit or r.skin) then return nil end
    return r
end

function LO.dressOutfit(pup, p1)
    local want = NET.rof
    local st = LO.stOutfit
    if not want then return end
    if not LO.appcProbed then
        LO.appcProbed = true
        out("替身外观组件：%s", LO.appcProbe(pup))
    end
    local key = pathOf(pup) .. "|" .. tostring(want.outfit) .. "|" .. tostring(want.skin) .. "|" .. tostring(want.hat)
    if key ~= st.key or (st.again and ST.ticks >= st.again) then
        local first = key ~= st.key
        st.key, st.again = key, first and ST.ticks + 90 or nil
        local mine = LO.outfitOf(p1)
        local ok, msg = LO.applyOutfit(pup, want.outfit, want.skin, want.hat)
        out("替身皮肤%s → %s 肤色 %s 斗笠%s：%s（%s）", first and "" or "（补一次）", tostring(want.outfit), tostring(want.skin),
            want.hat == true and "藏" or "显示",
            ok and "已换" or "没换成", msg)
        st.checkMine = { before = mine and mine.outfit, at = ST.ticks + 30 }
    end
    if st.checkMine and ST.ticks >= st.checkMine.at then
        local now = LO.outfitOf(p1)
        now = now and now.outfit
        out("  换皮肤后本机玩家：%s → %s %s", tostring(st.checkMine.before), tostring(now),
            now == st.checkMine.before and "（没变 ✓）" or "（!! 变了：替身换皮肤连带改了玩家）")
        st.checkMine = nil
    end
end

function LO.dress(pup, p1)
    LO.stOutfit = LO.stOutfit or {}
    local okO, errO = pcall(LO.dressOutfit, pup, p1)       -- §109 皮肤，出错不影响下面的武器
    if not okO and errO ~= LO.outfitErr then LO.outfitErr = errO; out("!! 替身换皮肤出错：%s", tostring(errO)) end
    local cwc = rawProp(pup, "Character Weapons Component")
    if not valid(cwc) then return end
    LO.stMain, LO.stShachi = LO.stMain or {}, LO.stShachi or {}
    local hold = LO.swtHolding(pup)     -- §166 切刀斩那把在另一格、技能还没切过去：主武器两格都先不动
    if not hold then LO.dressSlot(pup, p1, cwc, LO.slot(), NET.rwc, "武器", LO.stMain) end
    LO.dressSlot(pup, p1, cwc, LO.slotShachi(), NET.rwcs, "影之武装", LO.stShachi)
    if not hold then LO.dressOff(pup, cwc) end
    if NET.rwc and NET.rarm ~= nil and LO.armed(pup) ~= NET.rarm then
        pcall(function() cwc:SetArmed(LO.slot(), NET.rarm) end)
    end
end

-- 影之武装的攻击技能（开判定窗口用）：路径在 ShachiAbility/ 下，排除被动 / 处决 / 架势类
function LO.isEdgeAttack(n)
    LO.edgeCache = LO.edgeCache or {}
    local c = LO.edgeCache[n]
    if c ~= nil then return c end
    local idx, yes = LO.index(), false
    for _, path in ipairs(idx and idx.map[n] or {}) do
        if path:find("/ShachiAbility/", 1, true) then yes = true end
    end
    for _, bad in ipairs({ "Passive", "Execution", "GuardPoint", "Charge_C", "ChargeBase", "Stance", "Equip", "Switch" }) do
        if n:find(bad, 1, true) then yes = false end
    end
    LO.edgeCache[n] = yes
    return yes
end

-- ============================================================ 天赋 / 饰品被动同步（v0.17.2）
-- 伤害只在防守方算一次：对方打我 = 本机替身的攻击属性 × 我的真实防御。改属性的天赋 / 饰品已经随 att= 过来了，
-- 缺的是"触发型"被动（它们是挂在角色身上的 GA）。替身生成时复制的是**本机玩家**的天赋，不对。
-- 做法：发送方 pas= 列出自己生效的天赋 / 饰品被动；接收方把替身身上不在列表里的清掉（ClearAbility），缺的给上（K2_GiveAbility）。
function LO.isPas(n)
    return n:find("^GA_Talent_") or n:find("^GA_Accessory_") or n:find("^BP_GA_Accessory_")
end

function LO.encodePas(p1)
    local list = {}
    for n in pairs(activeAbilities(p1, LO.isPas) or {}) do     -- §82.6 只看天赋 / 饰品那几格（以前每 3 秒读全部，~26 ms 尖峰）
        if LO.isPas(n) then list[#list + 1] = n end
    end
    table.sort(list)
    return table.concat(list, ",")
end

-- §118 武器效果同步（用户转达的内测反馈："白影、刺骨混沌冰冻不同步，A 看 B 冰冻，B 自己不会被冰冻"）。
-- 冰冻积累不全在招式里：白影的升级 GE_Baiying_FrozenReinforced_Lv1–3 / LockFrozenWhileBlocked（攻击加冰冻积累、
-- 被格挡也积累）、混沌冰形态的 GE_Chaos_FrostBuff 都是挂在攻击者身上的 GE。A 本机是真 A 砍替身 B，有这些 GE → 替身冻住；
-- B 本机是替身 A 砍真 B，替身没有 → 积累不够、B 不冻。发送方 wge= 列出自己身上的武器效果（LO.weaponEffects），
-- 接收方给替身补上、对方没有了的（只限我们上的）去掉
function LO.encodeWge(p1)
    local list = LO.weaponEffects(p1)
    if LO.wgeLogs == nil then
        LO.wgeLogs = true
        out("我的武器效果（发给对方的 wge=）：%s", list and (#list > 0 and table.concat(list, " ") or "（无）") or "读不到 ActiveGameplayEffects")
    end
    -- §163 影之武装的升级（只在装着时挂）变了就记一行（前 20 次），实测看贪狼铸魂 GE_TanLang_Evolution 发没发出去
    local sq = {}
    for _, id in ipairs(list or {}) do if id:sub(1, 12) == "ShaqiWeapon/" then sq[#sq + 1] = id:sub(13) end end
    sq = table.concat(sq, " ")
    if list and sq ~= (LO.wgeSq or "") and (LO.wgeSqN or 0) < 20 then
        LO.wgeSqN = (LO.wgeSqN or 0) + 1
        out("我的影之武装升级（wge=）：%s", sq ~= "" and sq or "（无）")
    end
    if list then LO.wgeSq = sq end
    return list and table.concat(list, ",") or ""
end

function LO.syncWge(pup)
    if NET.rwge == nil then return end          -- 旧版对方没有这个字段：不动替身
    local pp = pathOf(pup)
    local key = pp .. "|" .. NET.rwge
    if key == LO.wgeKey then return end
    LO.wgeKey = key
    if LO.wgeFor ~= pp then LO.wgeFor, LO.wgeOn = pp, {} end
    local want, added, removed, n = {}, {}, {}, 0
    for id in NET.rwge:gmatch("[%w_/]+") do want[id], n = true, n + 1 end
    for id in pairs(want) do
        local ck = pp .. "|" .. LO.wgePath(id)            -- 和 CHG.upgrade 同一个记号：§92.7 补过的不再上
        if not LO.wgeOn[id] and not CHG.applied[ck] then
            LO.applyGE(pup, LO.wgePath(id), "替身武器效果 " .. id)
            LO.wgeOn[id], CHG.applied[ck] = true, true
            added[#added + 1] = id
        end
    end
    for id in pairs(LO.wgeOn) do
        if not want[id] then
            LO.removeGE(pup, LO.wgePath(id), "替身去掉武器效果 " .. id)
            LO.wgeOn[id], CHG.applied[pp .. "|" .. LO.wgePath(id)] = nil, nil
            removed[#removed + 1] = id
        end
    end
    if #added + #removed > 0 then
        out("替身武器效果同步：对方 %d 个；补上 %s；去掉 %s", n, #added > 0 and table.concat(added, " ") or "-",
            #removed > 0 and table.concat(removed, " ") or "-")
    end
end

function LO.syncPas(pup)
    if NET.rpas == nil then return end
    local std = STD.active()
    local accMode = ACC.mode()
    local key = pathOf(pup) .. "|" .. NET.rpas .. (std and "|std" or "") .. "|acc" .. accMode .. "|ban" .. ACC.banNow()   -- §176
    if key == LO.pasKey then
        if LO.pasReportAt and ST.ticks >= LO.pasReportAt then
            LO.pasReportAt = nil
            local now = {}
            for n in pairs(activeAbilities(pup) or {}) do if LO.isPas(n) then now[#now + 1] = n end end
            table.sort(now)
            out("  被动同步 2 秒后替身生效的被动：%s；Amplification_Fire=%s", #now > 0 and table.concat(now, " ") or "（无）",
                tostring(attrOf(pup, "Amplification_Fire")))
        end
        return
    end
    LO.pasKey, LO.pasReportAt = key, ST.ticks + 60
    local want = {}
    for n in NET.rpas:gmatch("[%w_]+") do                          -- §170.1 饰品按房间设置换级 / 失效
        local t = ACC.pasName(n, accMode)
        if t then want[t] = true end
    end
    if std then for _, n in ipairs(STD.TALENT_GA) do want[n] = true end end      -- §144 天赋按基准
    local asc = ascOf(pup)
    if not valid(asc) then return end
    local have, cleared = {}, {}
    local items = rawProp(rawProp(asc, "ActivatableAbilities"), "Items")
    local specs = {}
    eachArr(items, function(_, spec)
        local ab = rawProp(spec, "Ability")
        local okC, cls = false, nil
        if valid(ab) then okC, cls = pcall(function() return ab:GetClass() end) end      -- v0.27.7 空对象不调 GetClass（读 [0x10] 崩）
        local n = okC and shortName(full(cls)) or nil
        if n and LO.isPas(n) then
            have[n] = true
            if not want[n] then specs[#specs + 1] = { n = n, h = rawProp(rawProp(spec, "Handle"), "Handle") } end
        end
    end)
    -- 遍历完再清，别在遍历数组时改它
    for _, s in ipairs(specs) do
        local ok, err = pcall(function() asc:ClearAbility({ Handle = s.h }) end)
        cleared[#cleared + 1] = s.n .. (ok and "" or ("（失败 " .. tostring(err) .. "）"))
    end
    local given = {}
    local map = {}      -- puppetAbMap 定义在后面，这里自己列；技能变了，让它下次重建
    for _, a in ipairs(abilitiesOf(pup) or {}) do map[a.name] = a.cls end
    ST.abMapKey = nil
    for n in pairs(want) do
        if not have[n] then
            local cls = LO.give(pup, n, map)
            local okA = false
            if cls then pcall(function() okA = asc:TryActivateAbilityByClass(cls, true) end) end
            given[#given + 1] = n .. (cls and (okA and "（已激活）" or "（已给，激活返回 false，可能本来就自动激活）") or "（给不了）")
        end
    end
    out("替身被动同步：对方 %d 个；清掉替身原有的 %d 个 %s；补上 %d 个 %s；Amplification_Fire=%s",
        (function() local k = 0 for _ in pairs(want) do k = k + 1 end return k end)(),
        #cleared, table.concat(cleared, " "), #given, table.concat(given, " "), tostring(attrOf(pup, "Amplification_Fire")))
end

-- ============================================================ 斩马刀吸血补偿（v0.17.7）
-- 亡命斩马刀的吸血"对人偶、金身、幻体无效"，打替身不回血（§21.7）。16:00 单机打怪实测（HANDOVER §37）：
-- 轻击一路（切刀斩 SWT、A / AA / AAA / AAAA）命中回血合计 453.7 / 伤害 10734.3 ≈ 4.2%（分两跳，约 4:1，隔 0.5 秒）；
-- 杀气重击一路（B、AB）不回血。所以对方回报"我的斩马刀轻击命中 X"时，模组给自己回 4.2% × X
LO.ZM_HEAL = 0.042
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
function LO.isHitMontage(m)
    if not m or m == "" then return false end
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
function LO.isMedMontage(m)
    return m ~= nil and m:find("AM_Hun_Medicine_", 1, true) == 1
end

function LO.zmHeal(p1, atkId, dmg)
    local n = NET.evName and NET.evName[atkId]
    if not (n and dmg and dmg > 0 and LO.isZmLight(n)) then return end
    local hp, hm = hpOf(p1), attrOf(p1, "Health_Max")
    if not (hp and hm and hp > 0) then return end
    local heal = math.min(dmg * LO.ZM_HEAL, hm - hp)
    if heal <= 0.5 then return end
    setAttr(p1, "Health", hp + heal)
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

local function toggleRecord()
    local p1 = getP1()
    if not valid(p1) then out("!! 没有玩家1"); return end
    if not REC.on then
        local loc = try("rec loc", function() return p1:K2_GetActorLocation() end)
        local rot = try("rec rot", function() return p1:K2_GetActorRotation() end)
        if not (loc and rot) then return end
        REC.on, REC.frames, REC.t0 = true, {}, now()
        REC.ox, REC.oy, REC.oz, REC.oyaw = loc.X, loc.Y, loc.Z, rot.Yaw
        REC.prevAbs = activeAbilities(p1) or {}
        out("● 开始录制。建议：先往前走两步，再打一套连招，再按 F7 停")
        return
    end
    REC.on = false
    local fr = REC.frames or {}
    if #fr < 2 then out("录制太短，丢弃"); return end
    local name = os.date("rec_%H%M%S.txt")
    local lines = { "# PBZ_MP 录制 v2  t|前|右|高|相对朝向|动画|本帧新激活的技能(逗号分隔)" }
    local seen, list, abs = {}, {}, {}
    for _, f in ipairs(fr) do
        lines[#lines + 1] = string.format("%.3f|%.1f|%.1f|%.1f|%.1f|%s|%s", f.t, f.x, f.y, f.z, f.yaw, f.m, f.ab)
        if f.m ~= "" and not seen[f.m] then seen[f.m] = true; list[#list + 1] = f.m end
        if f.ab ~= "" then abs[#abs + 1] = string.format("%.1fs %s", f.t, f.ab) end
    end
    local text = table.concat(lines, "\n") .. "\n"
    fileWrite(REC_DIR .. "/" .. name, text)
    fileWrite(REC_DIR .. "/last.txt", text)
    ST.atkList, ST.atkIdx = nil, 0
    out("■ 录制结束：%d 帧 / %.1f 秒，存为 rec/%s", #fr, fr[#fr].t, name)
    out("  录到的技能（F8 回放时替身会按时间依次激活）：%s", #abs > 0 and table.concat(abs, "；") or "无")
end

-- 回放时不该让替身激活的：被动、吃药、处决、复活、破防挣脱（这是挨打后的被动反应）
local function replayable(name)
    for _, bad in ipairs({ "Passive", "Medicine", "Respawn", "ResetAttribute", "Talent", "Tracker",
                           "Locomotion", "SwitchAttack", "Accessory", "Execution", "BreakEscape",
                           "SustainedBlood", "Sense",
                           -- §189 木剑升级的完美闪避：只有慢动作 + 镜头震动（名字表里没有动作 / 子弹），是闪避的人自己的手感，
                           -- 替身放了会让本机也慢下来；以前替身也放不出（找不到类）
                           "WoodenSword_PerfectDodge" }) do
        if name:find(bad, 1, true) then return false end
    end
    return true
end
-- §82.2 发包只看这些技能（招式 + 破防挣脱），activeAbilities 据此只读这几格。全局字段：主代码块 local 已满
NET.wantAb = function(name) return name == "GA_Hun_BreakEscape_C" or replayable(name) end

local function recordStep()
    if not REC.on then return end
    local p1 = getP1()
    if not valid(p1) then return end
    local loc = try("rec loc", function() return p1:K2_GetActorLocation() end)
    local rot = try("rec rot", function() return p1:K2_GetActorRotation() end)
    if not (loc and rot) then return end
    local r = math.rad(REC.oyaw)
    local dx, dy = loc.X - REC.ox, loc.Y - REC.oy
    -- v0.6.1 实测：只播动画不产生伤害（F4/F8 打不到人），激活技能才行（F5 能打中、能被格挡）。
    -- 所以录"本帧新激活了哪些技能"，回放时在替身身上激活同名技能
    local act = activeAbilities(p1) or {}
    local new = {}
    for n in pairs(act) do
        if not REC.prevAbs[n] and replayable(n) then new[#new + 1] = n end
    end
    REC.prevAbs = act
    REC.frames[#REC.frames + 1] = {
        ab = table.concat(new, ","),
        t = now() - REC.t0,
        x = dx * math.cos(r) + dy * math.sin(r),
        y = -dx * math.sin(r) + dy * math.cos(r),
        z = loc.Z - REC.oz,
        yaw = rot.Yaw - REC.oyaw,
        m = montageOf(p1),
    }
    if #REC.frames > 30 * 120 then out("录制超过 2 分钟，自动停止"); toggleRecord() end
end

local function loadRecording(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local frames = {}
    for line in f:lines() do
        if line:sub(1, 1) ~= "#" then
            local t, x, y, z, yaw, m = line:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|(.*)$")
            if t then
                -- v2 多一列技能；v1 没有
                local m2, ab = m:match("^([^|]*)|(.*)$")
                if m2 then m = m2 else ab = "" end
                frames[#frames + 1] = { t = tonumber(t), x = tonumber(x), y = tonumber(y),
                    z = tonumber(z), yaw = tonumber(yaw), m = m, ab = ab }
            end
        end
    end
    f:close()
    return frames
end

local function stopReplay(why)
    if not REP.on then return end
    REP.on = false
    local pup = puppet()
    if valid(pup) then setBraking(pup, false) end
    out("■ 回放结束（%s）", why or "")
end

local function startReplay()
    local pup, p1 = puppet(), getP1()
    if not valid(pup) then out("!! 还没有替身，先按 F12"); return end
    if not valid(p1) then out("!! 没有玩家1"); return end
    if REP.on then stopReplay("重新开始") end
    local frames = loadRecording(REC_DIR .. "/last.txt")
    if not frames or #frames < 2 then out("!! 没有录制，先按 F7 录一段"); return end

    local loc = try("p1 loc", function() return p1:K2_GetActorLocation() end)
    local rot = try("p1 rot", function() return p1:K2_GetActorRotation() end)
    if not (loc and rot) then return end
    local r = math.rad(rot.Yaw)
    -- 起点放在你正前方，朝向你：录制时的"往前"在回放里就是"冲你来"
    REP.ax, REP.ay, REP.az = loc.X + math.cos(r) * REPLAY_DIST, loc.Y + math.sin(r) * REPLAY_DIST, loc.Z
    REP.ayaw = rot.Yaw + 180.0
    REP.frames, REP.i, REP.abI, REP.lastM, REP.t0, REP.on = frames, 1, 0, "", now(), true
    placeInFront(pup, REPLAY_DIST)
    setBraking(pup, true)

    -- 有技能列就按技能回放（能打人）；只有 v1 旧录制才退回播动画（打不到人）
    REP.useAb, REP.sub = false, {}
    for _, f in ipairs(frames) do if f.ab ~= "" then REP.useAb = true; break end end
    -- 先让替身拿上录制里用的武器（取第一个能认出武器的技能）
    for _, f in ipairs(frames) do
        local wid = nil
        for n in f.ab:gmatch("[^,]+") do wid = wid or weaponOfAbility(n) end
        if wid then
            if LO.EQUIP_REMOTE then equipWeapon(pup, wid, "回放录制用的武器") end   -- v0.16.0：会改玩家装备，见 §29
            break
        end
    end
    REP.abMap = {}
    for _, a in ipairs(abilitiesOf(pup) or {}) do REP.abMap[a.name] = a.cls end
    local miss, seen = {}, {}
    for _, f in ipairs(frames) do
        for n in f.ab:gmatch("[^,]+") do
            if not REP.abMap[n] and not seen[n] then seen[n] = true; miss[#miss + 1] = n end
        end
    end
    out("▶ 回放 %d 帧 / %.1f 秒，方式=%s%s", #frames, frames[#frames].t,
        REP.useAb and "激活技能" or "只播动画（旧录制，打不到人，建议按 F7 重录）",
        #miss > 0 and ("；替身没有的技能: " .. table.concat(miss, ", ")) or "")
end

local function toWorld(f)
    local r = math.rad(REP.ayaw)
    return {
        X = REP.ax + f.x * math.cos(r) - f.y * math.sin(r),
        Y = REP.ay + f.x * math.sin(r) + f.y * math.cos(r),
        Z = REP.az + f.z,
    }
end

local function puppetAbMap(pup)
    local key = pathOf(pup)
    if ST.abMapKey ~= key then
        ST.abMap, ST.abMapKey = {}, key
        for _, a in ipairs(abilitiesOf(pup) or {}) do ST.abMap[a.name] = a.cls end
    end
    return ST.abMap
end

-- §162 替身坏了自己换一个（11-08 内测，HANDOVER §162）：对方 16:07 重连，主机这边新建的替身从第一招起放招全返回 false
-- （0/50、1/88、1/109），武器对、拔刀了、有这个技能、杀气满，"正在放"全是被动；同一个替身也锁不上、刀碰不到。
-- 后来再重连走"替身复用"，拿回来的还是这个坏的。结果：对方打我全判落空（§155 放不出 = 落空）。
-- 做法：远端的招在替身身上连续 N 次放不出、中间一次都没放出来过、跨了 SEC 秒以上 → 记一行诊断（G.puppetDiag），
-- 驱动里把它作废（藏起、永不复用，销毁会崩）、新建一个。每次连接最多 MAX 次，两次之间至少 GAP 秒（防"不是替身坏了"时来回换）。
-- 全局（主代码块 local 已满）
PHEAL = { N = 8, SEC = 3.0, GAP = 30.0, MAX = 3, fails = 0, since = nil, want = nil, at = nil, n = 0, diagKey = nil }

-- 远端招在替身上放完一次：ok = 放出来了没有；has = 替身有没有这个技能（没有的不算替身坏了）
function PHEAL.note(pup, ok, has, name)
    if ok then PHEAL.fails, PHEAL.since = 0, nil; return end
    if not has then return end
    PHEAL.fails = PHEAL.fails + 1
    PHEAL.since = PHEAL.since or now()
    local key = pathOf(pup)
    if PHEAL.diagKey ~= key then      -- 每个替身第一次放不出就记一行状态（之后靠 failN 的那三行）
        PHEAL.diagKey = key
        out("  替身状态（第一次放不出 %s）：%s", name, G.puppetDiag(pup))
    end
    if PHEAL.want or PHEAL.fails < PHEAL.N or now() - PHEAL.since < PHEAL.SEC then return end
    if PHEAL.n >= PHEAL.MAX then
        if PHEAL.fails == PHEAL.N then out("!! 替身连续 %d 招放不出，但这次连接已经换过 %d 个替身，不再换", PHEAL.fails, PHEAL.n) end
        return
    end
    if PHEAL.at and now() - PHEAL.at < PHEAL.GAP then return end
    PHEAL.want = string.format("连续 %d 招放不出（%.1f 秒，最后一招 %s）", PHEAL.fails, now() - PHEAL.since, name)
end

-- 预防（猜测，没复现过）：坏掉的那个替身是新建出来后同一秒就被瞬移到 120 km 外、地形没加载的地方（§99 悬空），
-- 16:02 那次没扔远处的新替身是好的。新替身（按对象路径第一次见到算）在本机玩家身边先待 WARM 秒、动画跑起来，再去远处。
-- 只挡 > HOV.FAR 的远距离瞬移，近处跟随照常
PHEAL.WARM, PHEAL.born = 2.0, {}
function PHEAL.young(pup)
    local key = pathOf(pup)
    local t = PHEAL.born[key]
    if not t then
        PHEAL.born[key] = now()
        out("替身 %s 第一次要瞬移到远处：先在你身边待 %.0f 秒（§162）", short(key), PHEAL.WARM)
        return true
    end
    return now() - t < PHEAL.WARM
end

-- 新连接（对手断开后重连 / 换了对手）：次数重新算
function PHEAL.reset()
    PHEAL.fails, PHEAL.since, PHEAL.want, PHEAL.at, PHEAL.n = 0, nil, nil, nil, 0
end

-- 驱动里调（不在放招的调用栈里换替身：调用方放完招还要用 pup）
function PHEAL.step()
    if not PHEAL.want then return end
    local why = PHEAL.want
    PHEAL.want = nil
    local pup = puppet()
    if not valid(pup) or not MATCH.autoCreate then return end
    out("!! 替身坏了：%s；状态 %s → 作废，新建一个（这次连接第 %d 次）", why, G.puppetDiag(pup), PHEAL.n + 1)
    G.discardPuppet()
    MATCH.autoCreate()
    PHEAL.n, PHEAL.at, PHEAL.fails, PHEAL.since, PHEAL.diagKey = PHEAL.n + 1, now(), 0, nil, nil
end

-- §165.4 切刀斩到的时候，状态包里的 wc=（手上 WeaponConfig）还是切之前那把（w= 已经是新的），替身照它把刀又换回去 →
-- 切刀斩被打断、补放也放不出（11-08 双开：GA_Hun_HeiMoShang_SWT_C 先放出来，同一帧"替身换装 → 白影"）。
-- 按招名认出切到哪把（武器组里两格挑名字对得上的），1.5 秒内收到的 wc= 都按这把算
-- §166 切刀斩 = "切到这把并出招"：父类 BP_SwitchAttack_Base 的 K2_CanActivateAbility 调 BPL_PBZCombatUtils 的
-- Can Active Switch Attack（GetChangeWeaponAbilityWeapon 找这招属于武器组哪一格、和 GetCurrentWeapon 的当前序号比、
-- 再看切武器冷却），放出来后 Change Weapon By Ability 自己切过去。所以这把必须在**另一格**：§165.4 把它装进当前格，
-- 两格就只剩"当前格 = 这把、另一格 = 别的"，11-08 20:08–20:12 双开 13 次切刀斩里，切之前另一格恰好也是这把的 2 次
-- （风雷剑、黑魔伤）放出来了，其余全 false。现在改成装进另一格、当前格不动，让技能自己切
LO.SWT_ALIAS = { Chaos = { "CiGuHunDun" }, BronzeSword = { "TianXuanQingTongJian" }, Double = { "Double", "JueYing" },
                 ChiZheCanJian = { "ChiZheCanJian", "ChiZheZuiJian" }, ZhanMa = { "ZhanMaBlade" } }
-- 招名 → 用来认武器配置名的关键词：先查整段族名（ChiZheCanJian），再查第一段（ZiMingJian_New → ZiMingJian、
-- ShuangYue_DB → ShuangYue、Chaos_SwitchFormFire → Chaos 的别名）
function LO.swtKeys(n)
    local fam = n:match("^GA_Hun_(.-)_SWT")
    if not fam then return nil end
    local fam1 = fam:match("^([^_]+)") or fam
    return LO.SWT_ALIAS[fam] or LO.SWT_ALIAS[fam1] or (fam1 ~= fam and { fam, fam1 }) or { fam }
end

-- §166 把切刀斩那把装进替身武器组的另一格（当前格不动）。返回 另一格序号 或 nil, 原因
function LO.swtStage(pup, cfg)
    local slot = LO.slot()
    local cur = LO.curIndex(pup, slot)
    if not cur then return nil, "读不到当前序号" end
    local other = math.max(cur, 0) == 0 and 1 or 0
    local h = LO.hasOf(pup)
    if h[other] == cfg then return other end             -- §195 已经在另一格：不重建
    local ok, err = LO.setSlot(pup, slot, other, cfg)
    if not ok then return nil, err end
    h[other] = cfg
    LO.offKey = nil                 -- 另一格被改了：切完 / 没切成，LO.dressOff 都按对方的另一把重装
    return other
end

-- 返回 true = 已把这把装进另一格（之后放不出要调 LO.swtUnhold 让换装恢复）
function LO.swtPin(pup, n)
    local keys = LO.swtKeys(n)
    if not keys then return end
    -- 先看替身见过的两格；对方组里另一把可能从没拿过（11-08 实测白影），再查标准数值装备表的 30 级 / 铸魂配置、原配置
    local cands, G_ = {}, STD.GEAR and STD.GEAR.MAIN or {}
    local function add(c) if c then cands[#cands + 1] = c end end
    add(NET.rwcCur); add(NET.rwcOff); add(NET.rwc)
    for _, g in pairs(G_) do add(g.cfg) end
    for _, g in pairs(G_) do add(g.base) end
    for _, cfg in ipairs(cands) do do
        local sh = cfg and LO.short(cfg) or ""
        for _, k in ipairs(keys) do
            if sh:find(k, 1, true) then
                NET.rwcPin = { cfg = cfg, t = now() + 1.5 }
                NET.rwc = cfg
                local other, why = LO.swtStage(pup, cfg)
                ST.swtPin = (ST.swtPin or 0) + 1
                if other then
                    -- 技能切过去之前别让 LO.dress 把这把装进当前格 / 把另一格换回去（切过去后手上 = 这把，换装自然不动）
                    LO.swtHold = { cfg = cfg, t = now() + 1.0 }
                    if ST.swtPin <= 10 then out("  切刀斩 %s：%s 装进另一格（序号 %d），让技能自己切过去（第 %d 次）", n, sh, other, ST.swtPin) end
                    return true
                end
                -- 装不进另一格：退回 §165.4 的老办法（当前格直接换上）
                LO.swtHold = nil
                pcall(LO.dress, pup, getP1())
                if ST.swtPin <= 10 then out("  切刀斩 %s：另一格装不上（%s），当前格先换上 %s（第 %d 次）", n, tostring(why), sh, ST.swtPin) end
                return
            end
        end
    end end
end

function LO.swtUnhold() LO.swtHold = nil end

-- §166 换装要不要先等切刀斩自己切过去：手上还不是那把、1 秒内 → 先不动
function LO.swtHolding(pup)
    local h = LO.swtHold
    if not h then return false end
    if now() >= h.t or LO.heldConfig(pup) == h.cfg then LO.swtHold = nil; return false end
    return true
end

-- 在替身身上激活技能（回放、网络共用）。sub = 本次会话的"武器不匹配替代表"
activateOnPuppet = function(pup, n, sub, how)
    local asc, map = ascOf(pup), puppetAbMap(pup)
    local function fire(name)
        local cls = map[name]
        -- 2026-11-05 10:23 崩溃同类风险（见 pbz_game.lua healClass）：缓存的类可能已被回收，失效就重建技能表再查一次
        if cls and not valid(cls) then
            ST.abMapKey = nil
            map = puppetAbMap(pup)
            cls = map[name]
        end
        if not (cls and valid(asc) and valid(cls)) then return false end
        local ok, r = pcall(function() return asc:TryActivateAbilityByClass(cls, true) end)
        return ok and r == true
    end
    local use = sub[n] or n
    local staged = false
    if use:find("_SWT", 1, true) then
        local okP, r = pcall(LO.swtPin, pup, use)
        staged = okP and r == true
        if staged then ST.abMapKey = nil; map = puppetAbMap(pup) end      -- §166 另一格换了武器，技能表跟着变
    end
    -- §189 Snap（离得远时冲上去的那一刀，A_Snap / B_Snap / RA_Snap …）：基类 BP_*Attack_Snap_Base 的 K2_CanActivateAbility
    -- 要瞄准组件里锁着目标、而且离目标够远。替身的瞄准组件平时是空的（§119）→ 一次没放出来过（11-08–11-09 双刃 A_Snap 0/11、
    -- B_Snap 0/9；本机自己"自动出招"按类放也全是 false）。放之前先让替身瞄准组件锁你
    local snap = use:find("_Snap", 1, true) ~= nil
    if snap then LO.snapLock(pup) end
    local okFire = fire(use)
    -- v0.23.4 替代不能一直粘着：2026-11-04 23:46:58 双刃切刀斩第一次被换成斩马刀的成功了，之后 13/14 次都是直接放斩马刀的、
    -- 失败也不回头试原招。替代失败（或替身后来换上了对方的武器）就回到原招，原招成了把替代清掉
    if not okFire and sub[n] then
        if fire(n) or (LO.give(pup, n, map) and fire(n)) then
            out("  原招 %s 现在放得出了，不再用替代 %s", n, sub[n])
            sub[n], use, okFire = nil, n, true
        end
    end
    -- v0.17.0：先给替身这个技能再试（替身已经换成对方的武器时，这才是正路），不行再走下面的替代兜底
    if not okFire and not sub[n] and LO.give(pup, n, map) then okFire = fire(n) end
    -- §189 不是招式的技能（GA_Hun_ 以外：武器 / 影之武装升级给的）在替身身上已经在跑 → 算放出来了。妖锯 GA_YaoJu_MonsterErosion_BP
    -- 给上就自己常驻等事件（0/8，诊断里"正在放"有它）；铁矿拳套 ShaChiAttackMultiple 是替身自己的蓄力招连带出来的
    if not okFire and not use:find("^GA_Hun_") and LO.activeInstance(pup, use) then
        okFire = true
        ST.alreadyOn = (ST.alreadyOn or 0) + 1
        if ST.alreadyOn <= 10 then out("  %s 替身身上已经在跑，算放出来（第 %d 次）", use, ST.alreadyOn) end
    end
    -- §92.7 对方放得出、替身放不出：多半是武器升级（GE 给的 WeaponUpgrade 标签）替身没有。补上再放一次
    if not okFire and CHG.UPG[n] and CHG.upgrade(pup, n, CHG.UPG[n]) then
        okFire = fire(n)
        out("  补了武器升级之后 %s %s", n, okFire and "放出来了" or "还是放不出")
    end
    -- §159 冲刺类（AdvancedDash / SpecialDash / StanceDash …）都受冲刺冷却 GE_DashCooldown（Dash.Cooldown 标签）挡：替身的上一下
    -- 冲刺比对方晚到（延迟 / 补放），对方的下一下来时替身还在冷却。对方已经冲出来了 → 清掉替身的冷却再放一次
    if not okFire and use:match("%u%l+Dash_") and LO.removeGE(pup, CHG.DASH_CD) then    -- 不含 A_Dash 这类冲刺后的攻击
        okFire = fire(use)
        if okFire then
            ST.dashCd = (ST.dashCd or 0) + 1
            if ST.dashCd <= 10 or ST.dashCd % 20 == 0 then out("  清掉冲刺冷却后 %s 放出来了（第 %d 次）", use, ST.dashCd) end
        end
    end
    -- v0.6.2 实测：替身没装备对应武器时同名技能激活恒为 false。武器同步（v0.7.1）之后这里基本不触发，
    -- 留作兜底：换成替身手上武器的同一招（同样的 A/AA/B... 后缀）
    if not okFire and not sub[n] then
        local suffix = n:match("^GA_Hun_%w+_(.+)$")
        local suffixes = suffix and { suffix, (suffix:gsub("_Draw", "")) } or {}
        for _, sfx in ipairs(suffixes) do
            for _, w in ipairs({ "ChiRen", "Long", "ZhanMa" }) do
                local alt = "GA_Hun_" .. w .. "_" .. sfx
                if not okFire and alt ~= n and map[alt] and fire(alt) then
                    sub[n], use, okFire = alt, alt, true
                    out("  武器不匹配：%s 激活失败，改用替身武器的 %s", n, alt)
                end
            end
        end
    end
    -- v0.23.6 上一招还没放完就挡住了新招：2026-11-05 00:27:54–00:28:03 架势 3 次放不出，诊断都是"手上武器 绝影、有这个技能"，
    -- 动作还停在上一招 AM_Hun_Double_B / 铁矿拳套 GpA 上。对方那边已经出了新招，说明他的上一招已经收了——替身跟着收：
    -- 立刻停掉当前动作（cutMontage，不淡出）再放一次
    if not okFire and montageOf(pup) ~= "" then
        local stopped = cutMontage(pup)
        if stopped and fire(use) then
            okFire = true
            ST.cutForNew = (ST.cutForNew or 0) + 1
            if ST.cutForNew <= 10 or ST.cutForNew % 20 == 0 then
                out("  上一招 %s 还没收，停掉后 %s 放出来了（第 %d 次）", stopped, use, ST.cutForNew)
            end
        end
    end
    -- 2026-11-05 10:52:31 回放：架势放不出时动作已经是空的（上面停动作不管用），但上一招 GA_Hun_DualHook_DB_C 的技能还挂着。
    -- 同一个道理：对方已经出了新招，上一招在他那边结束了——把替身还挂着的招式技能取消掉再放一次（G.cancelMoves）
    if not okFire then
        local gone = G.cancelMoves(pup)
        if #gone > 0 and fire(use) then
            okFire = true
            ST.cancelForNew = (ST.cancelForNew or 0) + 1
            if ST.cancelForNew <= 10 or ST.cancelForNew % 20 == 0 then
                out("  上一招的技能 %s 还挂着，取消后 %s 放出来了（第 %d 次）", table.concat(gone, ","), use, ST.cancelForNew)
            end
        end
    end
    -- §157 切刀斩（*_SWT）和对方的 w= 同一个包到：替身换装每 8 帧才轮一次，这时手上还是上一把，SWT 放不出。
    -- 先当场换装再放一次（11-08 双开实测：GA_Hun_Double_SWT_C 比"替身换装 → 绝影"早约 1 秒，放不出）
    if not okFire and use:match("_SWT_C$") then
        LO.swtUnhold()                  -- §166 装进另一格也没放出来：放开换装，走老办法（当前格也换上）
        local p1 = getP1()
        if valid(p1) and pcall(LO.dress, pup, p1) and fire(use) then
            okFire = true
            ST.dressForSwt = (ST.dressForSwt or 0) + 1
            if ST.dressForSwt <= 10 then out("  切刀斩 %s 先换装再放，放出来了（第 %d 次）", use, ST.dressForSwt) end
        end
    end
    -- §189 收刀状态的招（*Unarm*：空手冲刺 / 连续冲刺）对方是收着刀放的，替身却拿着刀 → 放不出（11-09 AdvancedDash_Unarmed、
    -- AdvancedDash_Continuous_02_Unarm，对方 arm=false、替身拔刀）。先收刀再放
    local unarm = use:find("Unarm", 1, true) ~= nil
    if not okFire and unarm and LO.armed(pup) == true then
        local cwc = rawProp(pup, "Character Weapons Component")
        if valid(cwc) and pcall(function() cwc:SetArmed(LO.slot(), false) end) and fire(use) then
            okFire = true
            ST.unarmForNew = (ST.unarmForNew or 0) + 1
            if ST.unarmForNew <= 10 then out("  替身拿着刀，收刀后 %s 放出来了（第 %d 次）", use, ST.unarmForNew) end
        end
    end
    -- §155 对方出了攻击招、替身却还收着刀（对方 arm= 还没跟上 / 从没拔过刀直接出招）：先拔刀再放一次
    if not okFire and not unarm and LO.armed(pup) == false then
        local cwc = rawProp(pup, "Character Weapons Component")
        if valid(cwc) and pcall(function() cwc:SetArmed(LO.slot(), true) end) and fire(use) then
            okFire = true
            ST.armForNew = (ST.armForNew or 0) + 1
            if ST.armForNew <= 10 then out("  替身收着刀，拔刀后 %s 放出来了（第 %d 次）", use, ST.armForNew) end
        end
    end
    -- §189 锁了你还是放不出（多半是替身这边离你太近，Snap 只在远处出）：换成同武器的冲刺攻击（A_Snap → A_Dash / A_Dash_Short，
    -- 双刃 A_Snap 自己播的就是 AM_Hun_Double_A_Dash）。不进替代表，下次照样先试原招
    if not okFire and snap then
        for _, alt in ipairs({ (use:gsub("_Snap", "_Dash")), (use:gsub("_Snap", "_Dash_Short")) }) do
            if not okFire and alt ~= use and (map[alt] or LO.give(pup, alt, map)) and fire(alt) then
                okFire = true
                ST.snapAlt = (ST.snapAlt or 0) + 1
                if ST.snapAlt <= 10 then out("  %s 锁了你也放不出，改放同武器的 %s（第 %d 次）", use, alt, ST.snapAlt) end
                use = alt
            end
        end
    end
    pupAction(use, how .. " 返回=" .. tostring(okFire))
    if tostring(how):match("^远端#%d+$") then PHEAL.note(pup, okFire, map[use] ~= nil, use) end     -- §162 只算第一次放（不算补放 / 续放）
    -- v0.23.4 放不出来时记下替身当时的状态（每招前 3 次），下一轮按这个找原因：手上武器、技能在不在、杀气、在放什么
    if not okFire then
        ST.failN = ST.failN or {}
        ST.failN[use] = (ST.failN[use] or 0) + 1
        if use:match("_Stance_C$") then LO.offKey, LO.has = nil, nil end     -- v0.26.1 架势放不出：另一格可能被蓝图改回去了，下一轮重装（§76）
        -- §166 切刀斩装进另一格还是放不出：剩下的门槛多半是切武器冷却（Can Active Switch Attack 里 GetCurrentChangeWeaponCooldown），
        -- 记一次武器组件上和冷却 / 切武器有关的函数，下次按它查
        if staged and not ST.swtDiag then
            ST.swtDiag = true
            local cwc = rawProp(pup, "Character Weapons Component")
            local fs = {}
            for _, pat in ipairs({ "Cooldown", "ChangeWeapon", "SwitchWeapon" }) do
                for _, f in ipairs(valid(cwc) and LO.funcsLike(cwc, pat) or {}) do fs[#fs + 1] = f end
            end
            out("  切刀斩 %s 装进另一格也放不出；当前序号 %s；武器组件相关函数：%s", use, tostring(LO.curIndex(pup, LO.slot())),
                #fs > 0 and table.concat(fs, " ") or "（没有）")
        end
        if ST.failN[use] <= 3 then
            local act = {}
            for a in pairs(activeAbilities(pup) or {}) do act[#act + 1] = a end
            -- §155 替身身上各武器族的招各有几个、武器组当前序号（查"主机这边替身有对方的武器、却没有这把武器的招"）
            local fams, famList = {}, {}
            for a in pairs(map) do
                local f = a:match("^GA_Hun_(%w+)_[AB]")
                if f then fams[f] = (fams[f] or 0) + 1 end
            end
            for f, c in pairs(fams) do famList[#famList + 1] = f .. "×" .. c end
            local cwc, idx = rawProp(pup, "Character Weapons Component"), "?"
            if valid(cwc) then pcall(function() idx = tostring(cwc:GetCurrentWeaponIndex(LO.slot(), false)) end) end
            out("  替身技能按武器族：%s；武器组当前序号 %s；替身技能表 %d 个", table.concat(famList, " "), idx, (function() local k = 0; for _ in pairs(map) do k = k + 1 end; return k end)())
            out("  !! 替身放不出 %s（第 %d 次）：手上武器 %s（对方 %s），拔刀 %s（对方 %s），替身有这个技能=%s，杀气 %s/%s，动作 %s，正在放 %s",
                use, ST.failN[use], LO.short(LO.heldConfig(pup) or "?"), LO.short(NET.rwc or "?"), tostring(LO.armed(pup)),
                tostring(NET.rarm), tostring(map[use] ~= nil),
                tostring(attrOf(pup, "Shachi")), tostring(attrOf(pup, "Shachi_Max")), tostring(montageOf(pup)),
                #act > 0 and table.concat(act, ",") or "无")
        end
    end
    return okFire
end

local function replayStep()
    if not REP.on then return end
    local pup = puppet()
    if not valid(pup) then stopReplay("替身没了"); return end
    local fr = REP.frames
    local t = now() - REP.t0
    if t > fr[#fr].t then stopReplay("播完"); return end
    while REP.i < #fr and fr[REP.i + 1].t <= t do REP.i = REP.i + 1 end
    local a, b = fr[REP.i], fr[math.min(REP.i + 1, #fr)]
    local span = b.t - a.t
    local k = span > 0 and math.max(0, math.min(1, (t - a.t) / span)) or 0
    local pa, pb = toWorld(a), toWorld(b)
    local pos = { X = pa.X + (pb.X - pa.X) * k, Y = pa.Y + (pb.Y - pa.Y) * k, Z = pa.Z + (pb.Z - pa.Z) * k }
    local vel = span > 0 and { X = (pb.X - pa.X) / span, Y = (pb.Y - pa.Y) / span } or { X = 0, Y = 0 }
    REP.lastErr = drivePuppet(pup, pos, vel, REP.ayaw + a.yaw)

    if REP.useAb then
        -- 两次 tick 之间可能跨过好几帧，跨过的帧里的技能都要补上
        while REP.abI < REP.i do
            REP.abI = REP.abI + 1
            for n in fr[REP.abI].ab:gmatch("[^,]+") do activateOnPuppet(pup, n, REP.sub, "回放技能") end
        end
        return
    end

    if a.m ~= REP.lastM then
        REP.lastM = a.m
        if a.m ~= "" then
            local asset = montageByName(a.m)
            if asset and playOn(pup, asset) then pupAction(a.m, "回放")
            else out("  !! 回放动画失败: %s", a.m) end
        end
    end
end

-- ============================================================ 网络（文件邮箱 → sidecar.py → UDP）

-- 协议 v2（纯文本 key=value，一行一个；sidecar.py 原样转发）：
--   v=2 seq=<包序号> map=<地图> x y z yaw vx vy w=<武器ID> ev=<编号:技能名,...>
-- ev 带最近 EV_KEEP 秒内的全部技能事件，每个包都重复发 —— 丢一两个包也不会漏招；接收方按编号去重。
-- v0.6.2 的结论：伤害挂在技能上，所以同步的是"激活了哪个技能"，不是动画。
local EV_KEEP = 1.5

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
    if (MATCH.session and MATCH.session.role) == "client" then return NET.rbar or 2 end
    return NET.barCfg
end
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
    local rk = NET.rkRules()                 -- §110 武林盟主：服务器定的
    if rk then return rk.bo end
    if (MATCH.session and MATCH.session.role) == "client" then return NET.boValid(NET.rbo) and NET.rbo or 3 end
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
function NET.dmgPct()        -- 房间设置：主机 / 没联机 = 自己的，客机 = 主机的
    local rk = NET.rkRules()                 -- §110 武林盟主：服务器定的
    if rk then return rk.dm end
    if (MATCH.session and MATCH.session.role) == "client" then return NET.dmOk(NET.rdm) and NET.rdm or 100 end    -- §213 按范围认
    return NET.dmCfg
end
function NET.dmgNow()        -- 现在交手用的：对局中 = 开局时定下的 MATCH.dmPct，对局外 = 房间设置
    if MATCH.state ~= "idle" and MATCH.dmPct then return MATCH.dmPct end
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
    return string.format("（替身 Attack %s / ShachiAttack %s，系数 ×%.0f%%%s；对方发来 Attack %s；我 Attack %s）",
        type(a) == "number" and string.format("%.1f", a) or "?", type(s) == "number" and string.format("%.1f", s) or "?",
        (LO.atkScale or 1) * 100, (LO.scaleWhy and ("：" .. LO.scaleWhy) or "") .. (LO.lvNote and ("；" .. LO.lvNote) or ""),   -- §207.6
        tostring(ra or "?"),
        type(m) == "number" and string.format("%.1f", m) or "?")
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
    local rk = NET.rkRules()                 -- §110 武林盟主：服务器定的
    if rk then return rk.ab == 1 end
    if (MATCH.session and MATCH.session.role) == "client" then return NET.rab == 1 end
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
-- §181 cs = 作弊数据采样（用户 11-09"这个按钮叫作弊数据采样开关"）：开着时本机攒对局数据摘要、只在举报时跟着上传（CS 段）。
-- 普通房间默认开；武林盟主固定开（NET.FLAG_RKFIX：服务器 rkrules 发不发、发什么都当开）。静默：倒计时横幅 / 屏幕都不提示
NET.FLAG_KEYS[#NET.FLAG_KEYS + 1] = "cs"
NET.FLAG_DEF.cs, NET.flagCfg.cs = 1, 1
NET.FLAG_NAME.cs = { "作弊数据采样", "CHEAT DATA SAMPLING" }
NET.FLAG_RKFIX = { cs = 1 }
function NET.flagLoad()
    local t = fileReadKV(NET.AB_FILE) or {}
    for _, k in ipairs(NET.FLAG_KEYS) do
        local n = tonumber(t[k])
        if n == 0 or n == 1 then NET.flagCfg[k] = n end
        if NET.FLAG_LOCKED[k] then NET.flagCfg[k] = 0 end
    end
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
    if NET.FLAG_RKFIX[k] and NET.rk() then return NET.FLAG_RKFIX[k] == 1 end    -- §181 武林盟主固定的（规则还没到也一样）
    local rk = NET.rkRules()                 -- §110 武林盟主：服务器定的
    if rk and rk[k] ~= nil then return rk[k] == 1 end
    if (MATCH.session and MATCH.session.role) == "client" then
        local r = NET.rflag[k]
        if r == nil then r = NET.FLAG_DEF[k] end
        return r == 1
    end
    return NET.flagCfg[k] == 1
end
function NET.flagNow(k)      -- 现在交手用的：对局中 = 开局时定下的，对局外 = 房间设置
    if MATCH.state ~= "idle" and MATCH.flags and MATCH.flags[k] ~= nil then return MATCH.flags[k] end
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
NET.RES_KEYS, NET.RES_DEF, NET.RES_MAX = { "ult0", "ultx", "sp0", "resm", "acc", "accn" }, { ult0 = 0, ultx = 100, sp0 = 3, resm = 0, acc = 0, accn = 6 },
                                         { ult0 = 3, ultx = 300, sp0 = 6, resm = 1, acc = 3, accn = 6 }   -- §176 accn = 生效饰品数量（6 = 不限）   -- §170.1 acc = 饰品等级   -- §113.3 默认精纯杀气改 0
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
NET.resCfg, NET.rres = { ult0 = 0, ultx = 100, sp0 = 3, resm = 0, acc = 0, accn = 6 }, {}
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
    local rk = NET.rkRules()                 -- §110 武林盟主：服务器定的
    if rk and rk[k] ~= nil then return rk[k] end
    if (MATCH.session and MATCH.session.role) == "client" then
        local r = NET.rres[k]
        return NET.resValid(k, r) and r or NET.RES_DEF[k]
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
-- §176 禁用饰品（房间设置 accban=，内测反馈"慈母护符太强"）：饰品 ID 去掉 AC_、逗号隔开（"-" = 一件都不禁），
-- 只认 STD.ACCESSORIES 里的 66 件、按那个顺序存。默认禁慈母护符（破防回血）和百相傩面；武林盟主固定默认名单（不走 rkrules）。
-- 和 RES 键同一套：存 rules.txt、主机定、客机按主机状态包 accban= 走（没收到 = 默认）、开局时定进 MATCH.res.accban
NET.ACCBAN_DEF = "BreakRegen,MagicWeapon"
NET.accBanCfg, NET.raccban = NET.ACCBAN_DEF, nil
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
-- §179.4 武林盟主的禁用饰品由服务器 RRULES 的 accban= 定（名单不是数字，NET.rkParse 不收，这里单独取；"-" = 不禁）；服务器没发 = 默认名单
function NET.rkAccBan()
    local lb = NET.rkLobby and NET.rkLobby()
    local v = lb and (lb.rkrules or ""):match("accban=([%w_,%-]+)")
    return v and NET.accBanNorm(v) or NET.ACCBAN_DEF
end
function NET.accBanOf()
    if NET.rk() then return NET.rkAccBan() end            -- 武林盟主（规则还没到 = 默认名单）
    if (MATCH.session and MATCH.session.role) == "client" then
        return NET.raccban and NET.accBanNorm(NET.raccban) or NET.ACCBAN_DEF
    end
    return NET.accBanCfg
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
function WBAN.rkOf(kind)                 -- 武林盟主：服务器 rkrules 发了 wpnban= / edgeban= 就按它（同 §179.4 accban 的取法），没发 = 不禁
    local lb = NET.rkLobby and NET.rkLobby()
    local v = lb and (lb.rkrules or ""):match(kind .. "=([%w_,%-]+)")
    return v and WBAN.norm(kind, v) or WBAN.DEF
end
function WBAN.of(kind)                   -- 房间设置：武林盟主 = 服务器的；客机 = 主机的（没收到 = 不禁）；主机 / 没联机 = 自己的
    if NET.rk() then return WBAN.rkOf(kind) end
    if (MATCH.session and MATCH.session.role) == "client" then
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
            if (MATCH.session and MATCH.session.role) == "client" and t[k] then
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
-- 进倒计时 / 开打时调：把自己的精纯杀气 / 暗源写成这一局定下的数。第一次调时记下对局前的值，回自由活动时 resRestore 还回去
-- （PvP 不该吃掉单机里攒的大招和暗源）
function NET.resApply(p1, why)
    if not valid(p1) then return end
    local r = MATCH.res or NET.resNow()
    NET.ultxApply(p1, r.ultx or 100)                                      -- §113.4 获取倍率每回合都写
    if (r.resm or 0) == 0 and (MATCH.round or 1) > 1 then return end     -- §113.2 每场：只有第 1 回合给
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
    for _, n in ipairs(STD.TALENT_GE) do one("GE_Talent_" .. n, STD.talentPath(n)) end
    for _, n in ipairs(STD.TREE_GE) do one(n, STD.treePath(n)) end
    out("标准数值：%s天赋补了 %d 个（基准 %d 个）", label, #added, #STD.TALENT_GE + #STD.TREE_GE)
    return added
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
    for _, a in ipairs(STD.ORDER) do
        local want, c = (STD.ATTR[a] + (add[a] or 0)) * (mul[a] or 1), attrOf(p1, a)
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
    if not (okG and type(T) == "table") then okG, T = pcall(function() return dofile(ROOT .. "/Scripts/pbz_stdgear.lua") end) end
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
    if key == STD.gearKey then return end
    local have = G.geSet(p1)
    if not have then return end                   -- 读不到身上的效果：下次再试
    STD.gearKey = key
    local want, order = {}, {}
    local function addGE(list)
        for _, e in ipairs(list or {}) do
            if not want[e[1]] then order[#order + 1] = e[1] end
            if not want[e[1]] or want[e[1]] < e[2] then want[e[1]] = e[2] end
        end
    end
    addGE(STD.GEAR.COMMON)
    addGE(mid and STD.GEAR.MAIN[mid] and STD.GEAR.MAIN[mid].ge)
    addGE(sid and STD.GEAR.SHACHI[sid] and STD.GEAR.SHACHI[sid].ge)
    local nDel, nAdd, skip = 0, 0, 0
    for path in pairs(STD.gearMine) do
        if not want[path] then
            LO.removeGE(p1, path, "标准数值：摘掉 30 级效果 " .. STD.geShort(path))
            STD.gearMine[path] = nil
            nDel = nDel + 1
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
            end
        end
    end
    out("标准数值（装备）：手上 %s / 影武 %s：挂 30 级效果 %d 个、摘 %d 个，本来就有 %d 个", tostring(mid), tostring(sid), nAdd, nDel, skip)
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
-- ============================================================ §170 / §170.1 饰品等级（房间设置 acc=）
-- 饰品效果的资源名带等级：GE_Accessory_<名>_LvN（加属性 / 触发后的增益）、GA_Accessory_* / BP_GA_Accessory_*_LvN_C（触发型被动）。
-- Lv1 = 没精炼，Lv2 / Lv3 = 精炼 1 / 2 次。房间设置 acc（用户 11-09"饰品 初始 / 强化满 / 失效 可作为房间属性设置么"）：
--   0 = 原样（各用各的；§170.5 起和标准数值无关）、1 = 未强化（一律 Lv1）、2 = 强化满（一律最高级）、3 = 失效（饰品效果、技能全摘）。
-- 自己：每回合倒计时 / 开打时换（ACC.apply），对局中每 2 秒再查（触发出来的增益），回自由活动时换回（ACC.restore）。
-- 替身：LO.syncPas 按同一规则换对方 pas= 里的饰品技能；加属性那部分随 att= 过来（对方按同一设置换过了）。
-- 只改运行时，不动存档里的精炼等级。效果等级表从 IoStore 扫（游戏包 Accessories/New，Combo_DamageBuff 在 Combo 子目录）
ACC = { DIR = "/PBZCombatAsset/Prototypes/GameplayEffects/Accessories/New/", COMBO = { Combo_DamageBuff = true }, GE_LV = {} }
for b, l in ("ActHit:12 ActHitShachi:12 AnimMovement:12 Attack:12 BigHit:12 Bleed:12 Bleed_EnemyAmp:12 Bleed_PlayerBuff:12 BreakAttack:12 BreakDrink:12 BreakDrink_MaxShachi:2 BreakRecover:12 BreakRegen:12 BreakShield:12 Chaos:123 Combo:123 Combo_DamageBuff:123 Control:12 Counter:12 Counter_Effect:2 Deflect:12 Double:12 Drink:12 DrinkCost:12 EasyExecution:12 Electrified:12 ElementRegen:123 Elemental:12 ElementalResistance:12 EvadePhantom:12 Execution:12 ExecutionSwitchCool:12 Execution_Effect:2 Frost:12 Health:12 HealthResistance:123 HeavyAttackCost:12 HeavyAttackDamage:12 HeavyAttackShachi:12 Ignite:12 Long:12 Loot:12 LowHealth:12 LowShachi:12 MagicWeapon:123 MagicWeapon_SummonBerserk:123 MartialWeapon:123 PerfectFrame:123 PhysicalResistance:12 Poison:12 PoisonRegen:12 PowerWeapon:123 RandomDrink:123 RandomDrink_FireBreathe:123 RandomDrink_FullRegen:12 RandomDrink_GhostFire:123 RandomDrink_MaxShachi:12 RandomDrink_PoisonFog:123 RandomDrink_Shockwave:23 Ranged:12 RangedWeapon:123 Regen:12 ResistBleed:12 ResistFire:12 ResistIce:12 ResistNonBreak:12 ResistPoison:12 ResistRanged:12 ResistThunder:12 Resistance:12 Rider:12 Shachi:12 ShachiAttack:12 ShachiCool:12 ShachiRegen:12 ShachiWeapon:123 SpiritShadow:123 Stance:123 Stealth:12 Summon:123 SummonDuration:12 SwitchEndure:12 SwitchEndure_Endure:12 Tang:12 TimerEndure:12 TimerEndure_Cooldown:12 UltimateBreak:12 UltimateCharge:123"):gmatch("([%w_]+):(%d+)") do ACC.GE_LV[b] = l end
function ACC.gePath(base, lv)
    local n = "GE_Accessory_" .. base .. "_Lv" .. lv
    return ACC.DIR .. (ACC.COMBO[base] and "Combo/" or "") .. n .. "." .. n .. "_C"
end
-- 这一局按哪种：0 原样 / 1 未强化 / 2 强化满 / 3 失效
function ACC.mode()
    local m = (MATCH.res and MATCH.res.acc) or NET.resOf("acc") or 0
    return m
end
-- 名字 n 在 mode 下该换成什么：nil = 不动、false = 摘掉、字符串 = 换成这个名字
-- n 可以是技能类名（…_LvN_C）或效果短名（GE_Accessory_…_LvN）；off = { AC_X = true } 这一局失效的饰品（§176，不管 mode 都摘）
function ACC.target(n, mode, off)
    if not n:find("_Accessory_", 1, true) then return nil end
    if off and off[ACC.idOf(n) or ""] then return false end
    if mode == 0 then return nil end
    if mode == 3 then return false end
    local tail = n:sub(-2) == "_C" and "_C" or ""
    local pre, lv = n:match("^(.-_Accessory_.+)_Lv(%d)" .. tail .. "$")
    lv = tonumber(lv)
    if not pre then return nil end                       -- 没等级的被动（如 BP_GA_Accessory_Ignite_Passive_C）：原样
    local have                                          -- 某一级存不存在
    if tail == "" then
        local l = ACC.GE_LV[pre:sub(14)] or ""
        have = function(k) return l:find(tostring(k), 1, true) ~= nil end
    else
        local idx = LO.index()
        have = function(k) return idx and idx.map and idx.map[pre .. "_Lv" .. k .. "_C"] ~= nil end
    end
    if mode == 1 then
        if lv <= 1 then return nil end
        return have(1) and (pre .. "_Lv1" .. tail) or false   -- 没有 Lv1 = 只有精炼后才有：摘掉
    end
    for k = 3, lv + 1, -1 do                             -- mode 2：升到存在的最高级
        if have(k) then return pre .. "_Lv" .. k .. tail end
    end
    return nil
end
-- 替身被动同步用：对方 pas= 里的一个名字 → 替身该给的名字（nil = 不给）。
-- §176 禁用名单两边一样，替身这边也摘（对方自己也摘了，pas= 一般已经没有；倒计时刚换那一下可能还带着）；
-- 超出生效数量的看对方的格子顺序，本机算不了，靠对方摘完后的 pas= / att=
function ACC.pasName(n, mode)
    local t = ACC.target(n, mode, ACC.banSet(ACC.banNow()))
    if t == nil then return n end
    return t or nil
end
-- ---- §176 生效饰品数量（accn）/ 禁用饰品（accban）
-- 66 件饰品的中文 / 英文名（catalog.json，房间设置勾选页用）
ACC.NAME = {}
for id, zh, en in ([[ActHit 影动猎杀仪 HUNTER'S_INSIGHT|AnimMovement 舞扇 DANCE_FAN|Attack 筋力绑带 BATTLE_WRAPS|BigHit 绝望护符 TALISMAN_OF_DESPAIR|Bleed 雪与血 SNOW_AND_BLOOD|BreakAttack 追杀令 TOKEN_OF_PURSUIT|BreakDrink 静心小葫芦 CALMING_GOURD|BreakRecover 沉香念珠 AGARWOOD_PRAYER_BEADS|BreakRegen 慈母护符 MOTHER'S_TALISMAN|BreakShield 破盾符 SHIELDBREAKER_TALISMAN|Chaos 混沌狂戒 CHAOS_RING|Combo 碧血云天 CRIMSON_RESOLVE|Control 细线球 FINE_THREAD|Counter 反击护腕 COUNTERSTRIKE_BRACERS|Deflect 神机指环 SHENJI'S_RING|Double 妙手连环 QUICK_HAND_PAIR|Drink 香薰药盒 MEDICINE_CASE|DrinkCost 深宅药罐 MANOR_MEDICINE_POT|Electrified 月雷华灯 THUNDERMOON_LANTERN|ElementRegen 灭法拂尘丝 ACOLYTE_WHISK|Elemental 羽扇残羽 FEATHER_FAN_PLUME|EvadePhantom 影魅面具 WRAITH_MASK|Execution 万杀巧锁 DEATHLOCK|ExecutionSwitchCool 刽子手头巾 EXECUTIONER'S_HEADSCARF|Frost 灭法冰棱 ACOLYTE_ICICLE|Health 珍玩妖织 JEWEL'S_KNOT|HealthResistance 古甲残片 ANCIENT_ARMOR_FRAGMENT|HeavyAttackCost 正气凌然 LINGRAN'S_PENDANT|HeavyAttackDamage 残破容器 BROKEN_VESSEL|HeavyAttackShachi 独孤绝印 SEAL_OF_DUGU|Ignite 瑞狮火球 AUSPICIOUS_LION_FIREBALL|Long 妙手千钧 QUICK_HAND_MIGHT|Loot 聚宝盆 TREASURE_BASIN|LowHealth 绝地求生令 DESPERATE_STAND|LowShachi 同心双鱼佩 TWIN_FISH_PENDANT|MagicWeapon 百相傩面 NUO_MASK|MartialWeapon 粗糙煌心 CRUDE_RADIANT_HEART|PerfectFrame 浑源经脉仪 REFLEX_DEVICE|Poison 猛毒袋 VENOM_POUCH|PoisonRegen 活木符 LIVINGWOOD_TALISMAN|PowerWeapon 力士神像 GUARDIAN_IDOL|RandomDrink 开光玉佩 BLESSED_JADE_PENDANT|Ranged 神射之眼 SHARPSHOOTER'S_EYE|RangedWeapon 无相神镜 FORMLESS_DIVINE_MIRROR|ResistBleed 凝血符 CONGEAL_TALISMAN|ResistFire 辟火符 FLAMEWARD|ResistIce 防冰符 FROSTWARD|ResistNonBreak 坚岩护腕 BOULDERGUARD|ResistPoison 食物防腐罐 PRESERVATION_JAR|ResistRanged 避箭护符 ARROWWARD|ResistThunder 避雷符 THUNDERWARD|Rider 斩骑符 CAVALRYBANE|Shachi 弦音护符 RESONANCE_TALISMAN|ShachiAttack 白山密令 BAISHAN_WRIT|ShachiCool 胭脂盒 ROUGE_BOX|ShachiRegen 杀气头巾 SHA-CHI_HEADSCARF|ShachiWeapon 暗源方块 REMNANT_SPARK_CUBE|SpiritShadow 暗源小笼 REMNANT_SPARK_CAGE|Stance 机簧护心镜 BRASS_CHEST_GUARD|Stealth 屏息绑带 SILENT_WRAP|SummonDuration 人偶木心 A_PUPPET'S_WOODEN_HEART|SwitchEndure 神奇刀鞘 MIRACULOUS_SCABBARD|Tang 妙手在握 QUICK_HAND_PENDANT|TimerEndure 百战魔躯 BATTLEFORGED|UltimateBreak 绝技护符 ULTIMATE_TALISMAN|UltimateCharge 无名大师的扳指 NAMELESS_THUMB_RING]]):gmatch("(%w+) (%S+) ([^|]+)") do
    ACC.NAME["AC_" .. id] = { zh, (en:gsub("_", " ")) }
end
-- 技能 / 效果名 → 饰品 ID：*_Accessory_<X>[_…]_… → AC_X（同 ACC.orphans 的认法；X 只取字母，Bleed_EnemyAmp → AC_Bleed）
function ACC.idOf(n)
    local x = n:match("_Accessory_(%a+)")
    return x and ("AC_" .. x) or nil
end
ACC.banCache = {}
function ACC.banSet(s)                   -- "BreakRegen,MagicWeapon" → { AC_BreakRegen = true, ... }
    s = s or "-"
    if ACC.banCache.s == s then return ACC.banCache.r end
    local r = {}
    for x in s:gmatch("[%w_]+") do r["AC_" .. x:gsub("^AC_", "")] = true end
    ACC.banCache = { s = s, r = r }
    return r
end
function ACC.banNow()                    -- 这一局的禁用名单：对局中 = 开局时定下的
    return (MATCH.res and MATCH.res.accban) or NET.accBanOf()
end
function ACC.limitNow()                  -- 这一局的生效饰品数量（6 = 不限）
    return (MATCH.res and MATCH.res.accn) or NET.resOf("accn") or 6
end
function ACC.banText(s, lang)            -- 面板 / 日志：名单 → "慈母护符、百相傩面"（lang 1 = 中文、2 = 英文）
    local names, set = {}, ACC.banSet(NET.accBanNorm(s))
    for _, id in ipairs(STD.ACCESSORIES) do
        if set[id] then names[#names + 1] = (ACC.NAME[id] or { id, id })[lang or 1] end
    end
    if #names == 0 then return lang == 2 and "NONE" or "无" end
    return table.concat(names, lang == 2 and ", " or "、")
end
-- 开局第一次 apply 时算：这一局要失效的饰品 = 装着的里面禁用的 + 按格子顺序数、不算禁用的，第 accn 件之后的。
-- 返回 { AC_X = true }, 日志文字（nil = 没什么要说的）。读不到装了哪些时禁用名单整个算上（摘不到的不碍事）
-- §176.3 eq = 已经读好的"装着的"（对局中重算时传进来，可能只问了禁用名单那几件）；不传 = 这里读全部
function ACC.offNow(eq)
    local ban, lim = ACC.banSet(ACC.banNow()), ACC.limitNow()
    if eq == nil then eq = G.accEquipped(STD.ACCESSORIES) end
    local off, banned, cut = {}, {}, {}
    if not eq then
        for id in pairs(ban) do off[id] = true end
        return off, "饰品：读不到装了哪些，禁用名单整个摘（" .. ACC.banText(ACC.banNow()) .. "）"
    end
    local order, way = eq, nil
    if lim < 6 and #eq > 0 then
        local slots, why, diag = G.accSlots(eq)
        ACC.slotGuess = slots == nil          -- §176.1 读不到 → 倒计时横幅写明"按图鉴顺序"，别让人以为是按格子
        if slots then order, way = slots, why else
            way = "!! 读不到格子顺序（" .. tostring(why) .. "），按图鉴顺序"
            if diag and not ACC.slotDiagLogged then        -- 每次进游戏只写一次，给下次修读法用
                ACC.slotDiagLogged = true
                out("饰品格子顺序探针：装着 %s；%s", table.concat(eq, ","), table.concat(diag, "；"))
            end
        end
    end
    local k = 0
    for _, id in ipairs(order) do
        local nm = (ACC.NAME[id] or { id })[1]
        if ban[id] then
            off[id] = true; banned[#banned + 1] = nm
        else
            k = k + 1
            if k > lim then off[id] = true; cut[#cut + 1] = nm end
        end
    end
    if #banned + #cut == 0 then return off, nil end
    return off, string.format("饰品：装着 %d 件，禁用的 %s；只生效前 %s 件，摘掉 %s%s", #eq,
        #banned > 0 and table.concat(banned, "、") or "-", lim < 6 and tostring(lim) or "不限",
        #cut > 0 and table.concat(cut, "、") or "-", way and ("（格子顺序：" .. way .. "）") or "")
end
-- 读 ASC 上全部技能格：返回 { {n=类短名, h=Handle, cls=类}, ... }，pick(n) 为真的才要
function ACC.specs(asc, pick)
    local specs = {}
    eachArr(rawProp(rawProp(asc, "ActivatableAbilities"), "Items"), function(_, spec)
        local ab = rawProp(spec, "Ability")
        local okC, cls = false, nil
        if valid(ab) then okC, cls = pcall(function() return ab:GetClass() end) end      -- 空对象不调 GetClass（v0.27.7）
        local n = okC and shortName(full(cls)) or nil
        if n and pick(n) then specs[#specs + 1] = { n = n, h = rawProp(rawProp(spec, "Handle"), "Handle"), cls = cls } end
    end)
    return specs
end
-- 倒计时 / 开打 / 对局中每 2 秒：按 ACC.mode() 换自己身上的饰品技能和效果。ACC.mine 记着换掉的东西，回自由活动时换回
function ACC.apply(p1)
    local mode = ACC.mode()
    if not valid(p1) then return end
    local asc = ascOf(p1)
    if not valid(asc) then return end
    local mine = ACC.mine
    local first = mine == nil
    if first then
        local ask = ACC.askIds(mode)                    -- §176.3 对局中每 2 秒问这几件装没装（原样 + 不限数量时只问禁用名单那几件）
        if mode == 0 and #ask == 0 then return end      -- 原样、一件不禁、不限数量：这一局什么都不会摘，不建 ACC.mine（去重照常）
        local eq = G.accEquipped(STD.ACCESSORIES)
        local off, desc = ACC.offNow(eq or false)       -- §176 禁用 / 超出生效数量的饰品（§176.3 交手中装备变了再重算）
        if desc then out("%s", desc) end
        mine = { ga = {}, gaGiven = {}, ge = {}, geAdded = {}, mode = mode, off = off, ask = ask }; ACC.mine = mine
        ACC.eqMark(mine, eq)
    else
        ACC.recheck(p1, asc, mine)                      -- §176.3 交手中换了饰品：重算要摘的
    end
    local off = mine.off
    if mode == 0 and not next(off) then mine.lateNow = nil; return end   -- 只禁不换级、眼下没要摘的：不扫身上（§205 省开销）
    -- ① 技能（先换技能：它自己挂的效果跟着换，下面 ② 再看剩下的）
    local swapped = {}
    -- 11-09 修：先给目标级、给上了再清原来那格（以前先清后给，给不上时这一局身上就少了这件饰品的技能）；
    -- "只试一次"的记录在 pbz_game 的 LO 里，这边清不到 → 用 again 参数
    for _, s in ipairs(ACC.specs(asc, function(n) return not mine.gaGiven[n] and ACC.target(n, mode, off) ~= nil end)) do   -- 遍历完再清
        local t = ACC.target(s.n, mode, off)
        local tag = s.n .. "→"
        local cls1 = t and LO.give(p1, t, {}, true)
        if t and not cls1 then
            tag = tag .. "（给不了，原样保留）"
        elseif LO.clearAbility(asc, s.h) then
            mine.ga[#mine.ga + 1] = { n = s.n, cls = s.cls }
            if cls1 then
                pcall(function() asc:TryActivateAbilityByClass(cls1, true) end)
                mine.gaGiven[t] = true
                tag = tag .. t:match("_Lv%d_C$")
            else tag = tag .. "（摘掉）" end
        else tag = tag .. "（清不掉）" end
        swapped[#swapped + 1] = tag
    end
    -- ② 效果：按份数换（§170.2 同一个效果可能生效两份，二周目饰品增伤实测 0.3 × 2；换成目标级也挂同样份数）
    local cnt = G.geCounts(p1)
    local geTags = {}
    for n, c in pairs(cnt or {}) do
        local t = ACC.target(n, mode, off)
        if t ~= nil and not mine.geAdded[n] then          -- 我们自己挂的不再换
            local base, lv = n:match("^GE_Accessory_(.+)_Lv(%d)$")
            local path = base and ACC.gePath(base, lv) or (ACC.DIR .. n .. "." .. n .. "_C")
            local rec = (first or (mine.lateNow and mine.lateNow[ACC.idOf(n) or ""])) and not ACC.geHas(mine, n)
            if LO.removeGE(p1, path, "饰品（" .. ACC.MODE_NAME[mode] .. "）：摘掉 " .. n .. " ×" .. c) and rec then
                mine.ge[#mine.ge + 1] = { path = path, n = n, c = c }          -- 只还开局时就在的 + §176.3 交手中刚装上的那次（触发出来的临时增益不还）
            end
            local tag = n .. "×" .. c
            if t then
                local tb, tl = t:match("^GE_Accessory_(.+)_Lv(%d)$")
                local tp = ACC.gePath(tb, tl)
                for _ = 1, c - (cnt[t] or 0) do
                    if LO.applyGE(p1, tp, "饰品（" .. ACC.MODE_NAME[mode] .. "）：挂 " .. t) then mine.geAdded[t] = tp end
                end
                tag = tag .. "→Lv" .. tl
            else tag = tag .. "（摘掉）" end
            geTags[#geTags + 1] = tag
        end
    end
    if #swapped + #geTags > 0 then
        out("饰品（%s）：技能 %s；效果 %s", ACC.MODE_NAME[mode], #swapped > 0 and table.concat(swapped, " ") or "-",
            #geTags > 0 and table.concat(geTags, " ") or "-")
    elseif first then
        out("饰品（%s）：身上没有要换的", ACC.MODE_NAME[mode])
    end
    mine.lateNow = nil                                   -- §176.3 刚装上的只在发现后这一次记份数（之后再出现的是触发出来的临时增益）
end
-- ---- §176.3 交手中换饰品（2026-11-10 用户："堵住"）：开局没装、交手中换上的禁用饰品以前不在名单里，照样生效；
-- 卸掉前面一件后"只生效前 N 件"也不再对。现在每次 apply（倒计时 / 开打 / 对局中每 2 秒）先问一遍装着哪些，变了才重算。
-- 对局中要问的：换级（mode ≠ 0）或限数量时问全部 66 件（新装上的也要换级 / 截断、结束时要还）；只禁用时只问名单里那几件（默认 2 次 IsEquipAccessory / 2 秒）
function ACC.askIds(mode)
    if mode ~= 0 or ACC.limitNow() < 6 then return STD.ACCESSORIES end
    local ban, ids = ACC.banSet(ACC.banNow()), {}
    for _, id in ipairs(STD.ACCESSORIES) do if ban[id] then ids[#ids + 1] = id end end
    return ids
end
-- 记下读到的"装着的"（只记 ask 里那几件，和 recheck 读到的同一口径）；eq = nil（读不到）→ 不记，下次读到了当基准、不算"刚装上"
function ACC.eqMark(mine, eq)
    if not eq then mine.eq, mine.eqSig = nil, nil; return end
    if not mine.askSet then
        mine.askSet = {}
        for _, id in ipairs(mine.ask) do mine.askSet[id] = true end
    end
    local set, l = {}, {}
    for _, id in ipairs(eq) do if mine.askSet[id] then set[id] = true; l[#l + 1] = id end end
    mine.eq, mine.eqSig = set, table.concat(l, ",")
end
function ACC.nameList(ids)
    local l = {}
    for _, id in ipairs(ids) do l[#l + 1] = (ACC.NAME[id] or { id })[1] end
    return #l > 0 and table.concat(l, "、") or "-"
end
-- 名字属于 set 里的饰品（只认 66 件里的；HighCycle_Survival 这类不是饰品的名字不归任何一件）
function ACC.inSet(set, n)
    local id = ACC.idOf(n)
    return id ~= nil and ACC.NAME[id] ~= nil and set[id] == true
end
function ACC.geHas(mine, n)
    for _, e in ipairs(mine.ge) do if e.n == n then return true end end
    return false
end
-- 没变：只花 #ask 次 IsEquipAccessory、拼一个短字符串，不读格子顺序、不写日志
function ACC.recheck(p1, asc, mine)
    if #mine.ask == 0 then return end
    local eq = G.accEquipped(mine.ask)
    if not eq then return end
    if table.concat(eq, ",") == mine.eqSig then return end
    local was, now, plus, minus = mine.eq, {}, {}, {}
    for _, id in ipairs(eq) do now[id] = true; if was and not was[id] then plus[#plus + 1] = id end end
    if was then for _, id in ipairs(mine.ask) do if was[id] and not now[id] then minus[#minus + 1] = id end end end
    local off = ACC.offNow(eq)
    local gone, late, back, offL, newOff = {}, {}, {}, {}, {}
    for _, id in ipairs(minus) do gone[id] = true end
    for _, id in ipairs(plus) do late[id] = true end
    for _, id in ipairs(mine.ask) do
        if off[id] and now[id] then
            offL[#offL + 1] = id
            if was and not mine.off[id] then late[id] = true end      -- 本来生效、现在被挤出名额：这次摘的份数也要记（结束还）
            if not mine.off[id] then newOff[id] = true end
        end
        if mine.off[id] and now[id] and not off[id] then back[id] = true end      -- 以前被截掉、现在进了名额（还装着）
    end
    ACC.forget(p1, asc, mine, gone)
    ACC.dropGiven(p1, asc, mine, newOff)                -- 换级模式：被挤出名额的，我们给的换级版本也摘（apply 不碰自己给的）
    local backL = ACC.giveBack(p1, asc, mine, back)
    mine.off, mine.lateNow, mine.changed = off, late, true
    ACC.eqMark(mine, eq)
    out("饰品：%s，重算：摘掉 %s%s", was and string.format("交手中装备变了（多了 %s/少了 %s）", ACC.nameList(plus), ACC.nameList(minus)) or "读到装了哪些了",
        ACC.nameList(offL), #backL > 0 and ("；进了名额、还回 " .. ACC.nameList(backL)) or "")
end
-- 卸下的饰品：游戏自己撤它给的技能 / 效果；我们挂的（换级版本 gaGiven / geAdded、进名额时还回的）游戏不认、不会撤，
-- 所以身上还剩的这件饰品的技能 / 效果一律摘掉（它已经没装着了，留下的只会是我们挂的）；记着要还的那份不再还（不然凭空多一份）
function ACC.forget(p1, asc, mine, gone)
    if not next(gone) then return end
    local hit = function(n) return ACC.inSet(gone, n) end
    if valid(asc) then
        for _, s in ipairs(ACC.specs(asc, hit)) do LO.clearAbility(asc, s.h) end
    end
    for n in pairs(G.geCounts(p1) or {}) do
        local base, lv = n:match("^GE_Accessory_(.+)_Lv(%d)$")
        if base and hit(n) then LO.removeGE(p1, ACC.gePath(base, lv), "饰品：卸下了，摘掉剩在身上的 " .. n) end
    end
    for n in pairs(mine.gaGiven) do if hit(n) then mine.gaGiven[n] = nil end end
    for t in pairs(mine.geAdded) do if hit(t) then mine.geAdded[t] = nil end end
    local ga, ge = {}, {}
    for _, g in ipairs(mine.ga) do if not hit(g.n) then ga[#ga + 1] = g end end
    for _, e in ipairs(mine.ge) do if not hit(e.n) then ge[#ge + 1] = e end end
    mine.ga, mine.ge = ga, ge
end
-- 换级模式下我们给的目标级技能 / 效果（gaGiven / geAdded）：set 里这几件的撤掉（原来那份还记着，结束照还）
function ACC.dropGiven(p1, asc, mine, set)
    if not next(set) then return end
    local hit = function(n) return ACC.inSet(set, n) end
    local giv = false
    for n in pairs(mine.gaGiven) do if hit(n) then giv = true end end
    if giv and valid(asc) then
        for _, s in ipairs(ACC.specs(asc, function(n) return mine.gaGiven[n] and hit(n) end)) do LO.clearAbility(asc, s.h) end
    end
    for n in pairs(mine.gaGiven) do if hit(n) then mine.gaGiven[n] = nil end end
    for t, path in pairs(mine.geAdded) do
        if hit(t) then LO.removeGE(p1, path, "饰品：挤出名额，摘掉对局里挂的 " .. t); mine.geAdded[t] = nil end
    end
end
-- 进了名额的饰品：摘掉的技能现在就还（从 mine.ga 拿掉；换级模式下一次 apply 会再换、再记）；效果补到记下的份数（mine.ge 留着，结束时按份数补，补过的不会多）
function ACC.giveBack(p1, asc, mine, back)
    local l = {}
    if not next(back) then return l end
    for _, id in ipairs(mine.ask) do if back[id] then l[#l + 1] = id end end
    local hit = function(n) return ACC.inSet(back, n) end
    local ga = {}
    for _, g in ipairs(mine.ga) do
        if not (hit(g.n) and valid(asc) and valid(g.cls) and LO.giveClass(asc, g.cls)) then ga[#ga + 1] = g end
    end
    mine.ga = ga
    ACC.reapplied = true                                 -- 还回的不归装备管：之后卸下时靠 §191 ACC.orphans 摘
    local now = G.geCounts(p1) or {}
    for _, e in ipairs(mine.ge) do
        if hit(e.n) then
            for _ = 1, e.c - (now[e.n] or 0) do LO.applyGE(p1, e.path, "饰品：进了名额，还回 " .. e.n) end
        end
    end
    return l
end
-- 结束时还在身上装着吗：记着要还的那几件问一遍，卸下了的不还（recheck 最多晚 2 秒，这里再兜一次）。读不到 = 都当装着（以前的行为）
function ACC.unequipped(mine)
    local ids, seen = {}, {}
    local function add(n)
        local id = ACC.idOf(n)
        if id and ACC.NAME[id] and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
    end
    for _, g in ipairs(mine.ga) do add(g.n) end
    for _, e in ipairs(mine.ge) do add(e.n) end
    local gone = {}
    if #ids == 0 then return gone end
    local eq = G.accEquipped(ids)
    if not eq then return gone end
    local on = {}
    for _, id in ipairs(eq) do on[id] = true end
    for _, id in ipairs(ids) do if not on[id] then gone[id] = true end end
    return gone
end
ACC.MODE_NAME = { [0] = "原样", [1] = "未强化", [2] = "强化满", [3] = "失效" }
-- 回自由活动：摘掉我们给的、把换掉的技能和开局时就在的效果换回去
function ACC.restore(p1)
    local mine = ACC.mine
    ACC.mine = nil
    if not (mine and valid(p1)) then return end
    local asc = ascOf(p1)
    if not valid(asc) then return end
    local cleared = 0
    if next(mine.gaGiven) then
        for _, s in ipairs(ACC.specs(asc, function(n) return mine.gaGiven[n] end)) do
            if LO.clearAbility(asc, s.h) then cleared = cleared + 1 end
        end
    end
    local nAdd = 0
    for _, path in pairs(mine.geAdded) do LO.removeGE(p1, path, "饰品：摘掉对局里挂的"); nAdd = nAdd + 1 end
    if cleared + nAdd + #mine.ga + #mine.ge == 0 and not mine.changed then return end   -- §176.3 这一局什么都没摘过（只建了 mine 用来盯换装）：不写日志
    local gone = ACC.unequipped(mine)                    -- §176.3 交手中卸下了的不还（游戏已经撤了它的，还了就凭空多一份）
    local skip = {}
    for id in pairs(gone) do skip[#skip + 1] = (ACC.NAME[id] or { id })[1] end
    table.sort(skip)
    local back = 0
    for _, g in ipairs(mine.ga) do                       -- 换掉几格还几格（原来同名两格的也还两格）
        if not ACC.inSet(gone, g.n) and valid(g.cls) and LO.giveClass(asc, g.cls) then back = back + 1 end
    end
    -- 效果补到开局前的份数（§170.2；还回的技能自己可能已经挂上了一部分，只补差的）
    local now, nBack, short = G.geCounts(p1) or {}, 0, {}
    for _, e in ipairs(mine.ge) do
        if not ACC.inSet(gone, e.n) then
            for _ = 1, e.c - (now[e.n] or 0) do
                if LO.applyGE(p1, e.path, "饰品：换回 " .. e.n) then nBack = nBack + 1 end
            end
        end
    end
    if back + nBack > 0 then ACC.reapplied = true end   -- §176.3 还回的不归装备管：对局后卸下时靠 §191 ACC.orphans 摘
    local after = G.geCounts(p1) or {}
    for _, e in ipairs(mine.ge) do
        if not ACC.inSet(gone, e.n) and (after[e.n] or 0) ~= e.c then short[#short + 1] = e.n .. " " .. (after[e.n] or 0) .. "/" .. e.c end
    end
    out("饰品（%s）：换回——清掉对局技能 %d 个、摘对局效果 %d 个；还回技能 %d 个、效果 %d 份%s%s", ACC.MODE_NAME[mine.mode] or "?", cleared, nAdd, back, nBack,
        #skip > 0 and ("；已卸下不还：" .. table.concat(skip, "、")) or "",
        #short > 0 and ("；!! 份数对不上：" .. table.concat(short, " ")) or "；份数和开局前一样")
end
-- §170.3 诊断：每次进世界后 1 / 3 / 10 / 30 / 60 秒记一次身上的饰品效果份数和饰品技能格数（查"每个饰品效果挂了两份"从哪来）
ACC.DIAG_AT = { 0, 1, 3, 10, 30, 60 }
function ACC.diag(p1, tn)
    if ST.stableTicks == 1 then ACC.dg = { t0 = tn, i = 1, why = "进世界" } end
    local pup = ST.secondPawn                        -- 新替身出来了也重新记一轮（实测：份数是在 AI 对手出来时变成两份的）
    local pp = valid(pup) and pathOf(pup) or nil
    if pp and pp ~= ACC.dgPup then ACC.dgPup = pp; ACC.dg = { t0 = tn, i = 1, why = "替身 " .. shortName(pp) .. " 出来" } end
    local d = ACC.dg
    if not d or d.i > #ACC.DIAG_AT or tn - d.t0 < ACC.DIAG_AT[d.i] then return end
    local at = ACC.DIAG_AT[d.i]
    d.i = d.i + 1
    local ge, n = {}, 0
    for k, c in pairs(G.geCounts(p1) or {}) do if k:find("_Accessory_", 1, true) then ge[#ge + 1] = k:gsub("^GE_Accessory_", "") .. "×" .. c; n = n + c end end
    table.sort(ge)
    local ga, m = {}, 0
    local asc = ascOf(p1)
    if valid(asc) then
        for _, sp in ipairs(ACC.specs(asc, function(x) return x:find("_Accessory_", 1, true) ~= nil end)) do ga[sp.n] = (ga[sp.n] or 0) + 1; m = m + 1 end
    end
    local gl = {}
    for k, c in pairs(ga) do gl[#gl + 1] = k .. "×" .. c end
    table.sort(gl)
    out("饰品诊断（%s %d 秒，角色 %s）：效果 %d 份 %s；技能 %d 格 %s", d.why, at, shortName(pathOf(p1)), n, table.concat(ge, " "), m, table.concat(gl, " "))
end
-- §170.4 修"替身一出来，我身上的饰品效果 / 技能就多一份"（11-09 诊断：进世界 1–60 秒都是 ×1，替身 BP_Renewal_Hun 生成那一刻变 ×2——
-- 游戏按背包里装着的饰品给"玩家角色"再上一遍）。做法：没替身时每 5 秒记一次自己身上的饰品份数（基准）；有替身、且不在 ACC 换级中时，
-- 多出来的技能格清掉、多出来的效果摘掉再按基准份数挂回（摘一份的接口不确定，所以整个摘、按数补）
ACC.base, ACC.baseAt, ACC.dedupAt, ACC.dedupN = nil, -100, -100, 0
function ACC.snap(p1)
    local ge = {}
    for k, c in pairs(G.geCounts(p1) or {}) do if k:find("_Accessory_", 1, true) then ge[k] = c end end
    local ga = {}
    local asc = ascOf(p1)
    if valid(asc) then
        for _, sp in ipairs(ACC.specs(asc, function(x) return x:find("_Accessory_", 1, true) ~= nil end)) do ga[sp.n] = (ga[sp.n] or 0) + 1 end
    end
    return ge, ga
end
-- 11-09 修：观战一次生成两个替身（A / B，不是 ST.secondPawn），玩家身上的饰品叠到 ×3 还被当成基准记下。
-- 同一件饰品只能装一次，没替身时实测永远 ×1 → 基准一律按 1，不再记录；有没有替身都查（每 1 秒）
-- §205 进世界不联机也每秒顿一下 60–70 ms（11-10 双开日志：单帧尖峰只有"驱动合计"没分项，每次加载 8–25 次——尖峰日志
-- 每次加载只记前 SPIKE_LOGS 条，其实一直在）。就是这里：每秒把玩家身上全部效果（GetFullName 每条）和全部技能格（GetClass + 全名）
-- 扫一遍，都挤在同一帧。现在先只读两个数组的长度（G.arrCounts，不遍历），和上次全量扫完时一样就不扫；
-- 有替身 / 在观战时（饰品会被游戏多挂一份的场合）再每 SAFE_SEC 秒保底扫一次。数组长度变了（挂上 / 摘掉效果、装卸饰品、替身出来）照旧每秒内就扫
ACC.SAFE_SEC, ACC.fullAt, ACC.sig = 10, -100, nil
function ACC.dedupe(p1, tn)
    if not (ACC.base and ACC.base.pp == pathOf(p1)) then ACC.base, ACC.sig = { pp = pathOf(p1), ge = {}, ga = {} }, nil end
    local b = ACC.base
    if (ACC.mine and ACC.mine.mode ~= 0) or tn - ACC.dedupAt < 1 then return end   -- §176 只摘禁用 / 超出数量的（mode 0）时照常去重：两边不碰同一件
    ACC.dedupAt = tn
    local sig = G.arrCounts and G.arrCounts(p1) or nil
    local pawns = valid(puppet()) or (ST.spec and ST.spec.on)
    if sig and sig == ACC.sig and not (pawns and tn - ACC.fullAt >= ACC.SAFE_SEC) then return end     -- §205 身上没变
    ACC.fullAt = tn
    if ACC.reapplied then ACC.orphans(p1) end           -- §191 孤儿效果只会是我们挂回的那份：没挂回过就不查（省掉每秒找背包子系统 + IsEquipAccessory）
    local ge, ga = ACC.snap(p1)
    local asc = ascOf(p1)
    local fixed = {}
    for n, c in pairs(ga) do
        local want = b.ga[n] or 1                     -- 替身在时新装的饰品不在基准里：没替身时饰品从来都是一份（11-09 实测），按 1 算
        if c > want then
            local sps = ACC.specs(asc, function(x) return x == n end)
            local k = 0
            for i = #sps, 1, -1 do                       -- 清后加的那几格
                if c - k <= want then break end
                if LO.clearAbility(asc, sps[i].h) then k = k + 1 end
            end
            fixed[#fixed + 1] = n .. " 技能 " .. c .. "→" .. (c - k)
        end
    end
    -- §191 只管 GE_Accessory_<名>_LvN（装着的饰品的效果）。宇 11-09 日志：GE_Accessory_HighCycle_Survival_1 本来就两份、路径也不在
    -- New/ 下，以前每秒"摘、挂回找不到 GE"一遍（846 次）。另外连着 3 秒去完又回来的效果不再碰（游戏自己要挂两份），份数正常了就重新算
    ACC.churn = ACC.churn or {}
    for n, c in pairs(ge) do
        local want = b.ge[n] or 1
        local base, lv = n:match("^GE_Accessory_(.+)_Lv(%d)$")
        if c <= want then ACC.churn[n] = nil
        elseif base and (ACC.churn[n] or 0) < 3 then
            local path = ACC.gePath(base, lv)
            if LO.geClass(path) then
                ACC.churn[n] = (ACC.churn[n] or 0) + 1
                if ACC.churn[n] == 3 then out("饰品去重：%s 连着 3 秒去完又回来，先不管它", n) end
                LO.removeGE(p1, path, nil)
                for _ = 1, want do if LO.applyGE(p1, path, "饰品去重：挂回 " .. n) then ACC.reapplied = true end end
                fixed[#fixed + 1] = n .. " " .. c .. "→" .. want
            end
        end
    end
    if #fixed > 0 then
        ACC.dedupN = ACC.dedupN + 1
        if ACC.dedupN <= 20 then out("饰品去重（替身出来后我身上多了一份，第 %d 次）：%s", ACC.dedupN, table.concat(fixed, "，")) end
    end
    ACC.sig = (#fixed > 0 or not sig) and (G.arrCounts and G.arrCounts(p1)) or sig     -- §205 按改完的样子记
end
-- 11-09 修：去重是"整个摘、按数挂回"，挂回的那份不归装备管——之后卸下这件饰品，游戏摘不掉它（用户：加血饰品卸了血条还是长）。
-- 所以每秒对一遍：身上有某件饰品的效果 / 技能，但 IsEquipAccessory 说没装 → 摘掉。名字对应 GE_Accessory_X_LvN / *Accessory_X_* ↔ AC_X
function ACC.orphans(p1)
    local ge, ga = ACC.snap(p1)
    local by = {}
    for n in pairs(ge) do local x = n:match("^GE_Accessory_(%a+)_Lv%d$"); if x then by["AC_" .. x] = true end end
    for n in pairs(ga) do local x = n:match("Accessory_(%a+)_"); if x then by["AC_" .. x] = true end end
    -- 只管认识的饰品（STD.ACCESSORIES 里有 AC_X）；同名变体 AC_X_1..4 装着任意一件都算装着，宁可漏摘不误摘
    ACC.known = ACC.known or {}
    if not next(ACC.known) then for _, id in ipairs(STD.ACCESSORIES or {}) do ACC.known[id] = true end end
    local ids = {}
    for id in pairs(by) do
        if ACC.known[id] then
            ids[#ids + 1] = id
            for k = 1, 4 do ids[#ids + 1] = id .. "_" .. k end
        else by[id] = nil end
    end
    if #ids == 0 then return end
    local on = G.accEquipped(ids)
    if not on then return end
    local eq = {}
    for _, id in ipairs(on) do eq[(id:gsub("_%d$", ""))] = true end
    for id in pairs(eq) do by[id] = nil end           -- by 里剩下的 = 认识、且确实没装
    local asc = ascOf(p1)
    local gone = {}
    for n in pairs(ge) do
        local x, lv = n:match("^GE_Accessory_(%a+)_Lv(%d)$")
        if x and by["AC_" .. x] then
            LO.removeGE(p1, ACC.gePath(x, lv), nil)
            gone[#gone + 1] = n
        end
    end
    if valid(asc) then
        for n in pairs(ga) do
            local x = n:match("Accessory_(%a+)_")
            if x and by["AC_" .. x] then
                for _, sp in ipairs(ACC.specs(asc, function(y) return y == n end)) do LO.clearAbility(asc, sp.h) end
                gone[#gone + 1] = n
            end
        end
    end
    if #gone > 0 then out("饰品：没装着的饰品效果还挂在身上，摘掉：%s", table.concat(gone, "，")) end
end
-- 对局中每 2 秒（跟着 STD.tick 的调用点）：触发出来的饰品增益也按设置换
ACC.at = -100
function ACC.tick(tn)
    if not ACC.mine or MATCH.state == "idle" or tn - ACC.at < 2.0 then return end
    ACC.at = tn
    ACC.apply(getP1())
end
-- 诊断：换套前后的 Actor / ActorComponent 数（和上一次比），看新建的武器对象会不会被回收（21:07 崩溃 = UObject 撑满）
function STD.countLog(tag)
    local a, c = G.objCounts()
    local p = STD.lastCount
    out("标准数值·对象计数（%s）：Actor %d（%+d）、ActorComponent %d（%+d）；本场第 %d 次换套", tag, a, a - (p and p[1] or a),
        c, c - (p and p[2] or c), #STD.forceTimes + 1)
    STD.lastCount = { a, c }
end
function STD.unforce(why)
    if not STD.forced then return end
    local id = STD.forced
    if STD.pushed or G.loadoutSnapshot() then         -- 先 Pop 配装快照，再 Restore 强制配装（20:32 实测这个顺序干净）
        local okP, errP = G.loadoutPop()
        if not okP then out("!! 标准数值：Pop 配装快照失败 %s", tostring(errP)) end
    end
    STD.pushed = false
    local ok, err = G.forcedRestore()
    out("标准数值：还原强制配装 %s（%s）：%s，之后等级 %s", id, why, ok and "成功" or ("失败 " .. tostring(err)), tostring(G.weaponLevel(id, true)))
    STD.forced, STD.forceTried, STD.lv, STD.verify = nil, nil, {}, nil
    os.remove(STD.FORCE_FILE)
    STD.countLog("还原后")
end
-- 进游戏（有玩家角色）后调一次：账本还在 = 上次对局没走到还原（崩溃 / 强退 / 存档里带着），游戏仍在强制配装中就还原。
-- 没有账本的强制配装是游戏自己的（剧情），不碰
function STD.cleanup()
    if STD.cleaned then return end
    STD.cleaned = true
    local f = io.open(STD.FORCE_FILE, "r")
    if not f then return end
    local id = (f:read("a") or ""):match("[%w_]+") or "?"
    f:close()
    if G.loadoutSnapshot() then G.loadoutPop() end     -- 方案 B 留下的配装快照
    local act = G.forcedActive()
    if act then
        local ok, err = G.forcedRestore()
        out("标准数值：发现上次留下的强制配装 %s，还原 %s（之后等级 %s）", id, ok and "成功" or ("失败 " .. tostring(err)), tostring(G.weaponLevel(id, true)))
    else
        out("标准数值：账本里有 %s，但游戏不在强制配装中（%s），只删账本", id, tostring(act))
    end
    os.remove(STD.FORCE_FILE)
end
-- 进倒计时 / 开打时调（跟 §113 NET.resApply 一起）
function STD.apply(p1, why)
    if not (STD.active() and valid(p1)) then return end
    if not STD.saved then
        STD.saved, STD.lv = {}, {}
        local okV, msg = G.saveVeto(true, STD.VETO_ID)
        STD.veto = okV
        out("标准数值：进否决存档 %s（%s）", okV and "成功" or "失败", tostring(msg))
        STD.added = STD.addTalents(p1, "自己")
        STD.gearOn(p1)
    end
    STD.force(p1)
    local parts = STD.writeAttrs(p1, true)
    if #parts > 0 then out("标准数值（%s）：%s", why, table.concat(parts, "，")) end
    local pup = puppet()
    if valid(pup) and not STD.pupAdded[pathOf(pup)] then STD.pupAdded[pathOf(pup)] = STD.addTalents(pup, "替身") end
end
-- 对局中每 2 秒查一次（游戏重新聚合属性会把值改回去，同 LO.apply 每 2 秒重写替身）
function STD.tick(tn)
    if not (STD.saved and MATCH.state ~= "idle") then return end
    if tn - STD.forceAt >= STD.FORCE_EVERY then        -- 对局中换了武器：还原上一把、套这一把（用户"能在玩家切换武器的时候换成切换生成么"）
        STD.forceAt = tn
        STD.lastTn = tn
        local p0 = getP1()
        if valid(p0) then STD.force(p0, tn); STD.gearSync(p0) end
    end
    if tn - STD.enforceAt < 2.0 then return end
    STD.enforceAt = tn
    local p1 = getP1()
    if not valid(p1) then return end
    local parts = STD.writeAttrs(p1, false)
    if #parts > 0 then out("标准数值：属性被改回去了，重写：%s", table.concat(parts, "，")) end
    STD.gearCheck(p1)
end
-- 回自由活动时调：属性还原、摘掉挂上的天赋、退出否决存档
function STD.restore(p1)
    STD.unforce("对局结束")
    STD.gearOff(p1)
    STD.disabled, STD.forceTimes, STD.seen, STD.settleUntil, STD.verify = false, {}, nil, -100, nil
    local s, sb = STD.saved, STD.savedBase or {}
    STD.saved, STD.pre, STD.savedBase, STD.preBase = nil, nil, nil, nil
    if s and valid(p1) then
        -- 11-09 修：基础值写回对局前的基础值；当前值按"对局前基础值 + 现在身上的饰品加成"算——
        -- 对局中卸 / 换了饰品，不能再写回对局前的当前值（用户：结束战斗反而比摘掉饰品更长）
        -- 当前值 = 对局前的当前值，换掉对局前的饰品加成、换成现在的（对局中卸 / 换了饰品）；基础值摆回对局前的
        local okB, add, mul = pcall(STD.accBonus, p1)
        if not okB then add, mul = {}, {} end
        local a0, m0 = STD.preAdd or {}, STD.preMul or {}
        STD.savedBase = sb
        for _, a in ipairs(STD.ORDER) do
            local v0 = s[a]
            if v0 then
                local v = (v0 / (m0[a] or 1) - (a0[a] or 0) + (add[a] or 0)) * (mul[a] or 1)
                STD.put(p1, a, v)
            end
        end
        STD.savedBase, STD.preAdd, STD.preMul = nil, nil, nil
        s.Health_Max = attrOf(p1, "Health_Max")
        for _, path in ipairs(STD.added or {}) do LO.removeGE(p1, path, "标准数值：摘掉自己的临时天赋 " .. path:match("([%w_]+)_C$")) end
        out("标准数值：属性还原成对局前（血上限 %s、攻击 %s），摘掉临时天赋 %d 个", tostring(s.Health_Max), tostring(s.Attack), #(STD.added or {}))
    end
    STD.added = nil
    local pup = puppet()
    for key, list in pairs(STD.pupAdded) do      -- 替身身上挂的也摘掉（下一场不是标准数值时替身别多带天赋）
        if valid(pup) and pathOf(pup) == key then
            for _, path in ipairs(list) do LO.removeGE(pup, path, "标准数值：摘掉替身的临时天赋 " .. path:match("([%w_]+)_C$")) end
        end
    end
    STD.pupAdded = {}
    if STD.veto then
        local okV, msg = G.saveVeto(false, STD.VETO_ID)
        out("标准数值：退出否决存档 %s（%s）", okV and "成功" or "失败", tostring(msg))
        STD.veto = false
    end
end

-- §158 数值表下发（用户 11-08"完全平衡数据 / 武器平衡数据改成从服务器下发 / 从主机下发"）。
-- 伤害在挨打方本机按它自己的表算，两边的 pbz_balance.lua / 标准数值基准不一样就不对称、谁也看不出来。
-- 现在：主机状态包带 cfgh=<哈希>；客机的哈希对不上就经可靠通道要（cfgreq），主机把配置拆成块发（cfg <哈希> <第几块> <共几块> <内容>）；
-- 每场第 1 回合倒计时定下这一场用哪份（主机 = 本地；客机 = 收齐、哈希对得上的主机那份，不然用本地并在横幅上标出来），结束换回本地。
-- 只下发可调的数：标准数值的属性 / 等级 / 统一给的天赋、武器平衡的族系数 / 单招系数 / 影之武装系数。
-- pbz_stdgear.lua（每把武器 30 级该挂什么，是从游戏里读出来的事实）不下发。
-- 收到的东西都过白名单：属性名只认 STD.ORDER、天赋只认本地基准里有的、系数 0–5、招式名只认 GA_ 开头的字母数字下划线。
CFG = { CHUNK = 600, REQ_EVERY = 3.0, local_ = nil, localStr = nil, localHash = nil,
        rHash = nil,            -- 对方（主机）状态包里报的哈希
        have = nil, haveHash = nil, parts = nil, partsHash = nil, reqAt = -100, srcNote = nil }

-- §210 表版本号 fv=：每加一组新字段（下面 CFG.KEYS 加键）就把 FV 加 1。旧版本解码不认 fv=、照旧跳过；新版本看到比自己新的 fv、
-- 或者不认识的键，整份不收（服务器那份 → 用模组文件、横幅提示更新；主机那份 → 用本地、规则指纹会对不上）。
-- 1 = §158 基础（a / lv / t / tr / e / f / m）、2 = §177 s=、3 = §184 cd=、4 = §199 d= / cc=、5 = §200.10 co=、6 = §206 ch=、7 = §212 sd=
CFG.FV = 7
CFG.KEYS = { v = true, fv = true, a = true, lv = true, t = true, tr = true, e = true, f = true, m = true, s = true, cd = true,
             d = true, cc = true, co = true, ch = true, sd = true }

function CFG.hash(s)            -- FNV-1a 32 位，十六进制
    local h = 0x811c9dc5
    for i = 1, #s do h = ((h ~ s:byte(i)) * 0x01000193) & 0xffffffff end
    return string.format("%08x", h)
end

function CFG.num(v) return string.format("%.6g", v) end
function CFG.short(n)       -- 招式名缩写：GA_Hun_X_C → ~X，GA_X_C → ^X
    local m = n:match("^GA_Hun_(.+)_C$")
    if m then return "~" .. m end
    m = n:match("^GA_(.+)_C$")
    if m then return "^" .. m end
    return n
end
function CFG.long(s)
    if s:sub(1, 1) == "~" then return "GA_Hun_" .. s:sub(2) .. "_C" end
    if s:sub(1, 1) == "^" then return "GA_" .. s:sub(2) .. "_C" end
    return s
end
function CFG.fallback(name, fam, edge)     -- 表里没有这招时的系数（和 BAL.moveScale 一样的兜底）
    local f = name:match("^GA_Hun_(%w+)_")
    local v = f and fam[f] or 1.0
    if LO.isEdgeAttack(name) then v = v * edge end
    return v
end

-- 现在本机用着的这份（STD / BAL / LO.EDGE_SCALE）
function CFG.snapshot()
    local c = { attr = {}, lv = STD.LEVEL, tal = {}, tree = {}, fam = {}, mv = {}, edge = LO.EDGE_SCALE, sum = {}, cd = {}, dot = {}, ctrl = {}, co = {}, chill = {}, sd = {} }
    for k, v in pairs(STD.ATTR) do c.attr[k] = v end
    for _, n in ipairs(STD.TALENT_GE) do c.tal[#c.tal + 1] = n end
    for _, n in ipairs(STD.TREE_GE) do c.tree[#c.tree + 1] = n end
    for k, v in pairs(BAL.FAMILY) do c.fam[k] = v end
    for k, v in pairs(BAL.MOVE) do c.mv[k] = v end
    for k, v in pairs(BAL.SUMMON) do c.sum[k] = v end
    for k, v in pairs(BAL.COOLDOWN) do c.cd[k] = v end      -- §184
    for k, v in pairs(BAL.DOT) do c.dot[k] = v end          -- §199
    for k, v in pairs(BAL.CTRL) do c.ctrl[k] = v end
    for k, v in pairs(BAL.COST) do c.co[k] = v end          -- §200.10
    for k, v in pairs(BAL.CHILL_DEF) do c.chill[k] = v end  -- §206（没写的项按默认，编码出来总是完整的）
    for k, v in pairs(BAL.CHILL) do c.chill[k] = v end
    for k, v in pairs(BAL.SDMG_DEF) do c.sd[k] = v end     -- §212（同 chill：编码出来总是完整的）
    for k, v in pairs(BAL.SDMG) do c.sd[k] = v end
    return c
end

-- 规范化成一行（排好序，同样的内容哈希一样）。单招只发和兜底不一样的
function CFG.encode(c)
    local function sortedKV(t, fmtKey)
        local ks = {}
        for k in pairs(t) do ks[#ks + 1] = k end
        table.sort(ks)
        local o = {}
        for _, k in ipairs(ks) do o[#o + 1] = (fmtKey and fmtKey(k) or k) .. ":" .. CFG.num(t[k]) end
        return table.concat(o, ",")
    end
    local mv = {}
    for k, v in pairs(c.mv) do
        if math.abs(v - CFG.fallback(k, c.fam, c.edge)) > 1e-6 then mv[k] = v end
    end
    local tal, tree = {}, {}
    for _, n in ipairs(c.tal) do tal[#tal + 1] = n end
    for _, n in ipairs(c.tree) do tree[#tree + 1] = n end
    table.sort(tal); table.sort(tree)
    return table.concat({ "v=1", "fv=" .. CFG.FV, "a=" .. sortedKV(c.attr), "lv=" .. CFG.num(c.lv), "t=" .. table.concat(tal, ","),
        "tr=" .. table.concat(tree, ","), "e=" .. CFG.num(c.edge), "f=" .. sortedKV(c.fam), "m=" .. sortedKV(mv, CFG.short),
        "s=" .. sortedKV(c.sum or {}, CFG.short),        -- §177 召唤留场秒数（旧版解码不认 s=，直接跳过）
        "cd=" .. sortedKV(c.cd or BAL.CD_DEF),              -- §184 召唤物冷却秒数（同上，旧版跳过）
        "d=" .. sortedKV(c.dot or {}, CFG.short),           -- §199 持续伤害系数（招名缩写 / 族名；旧版跳过）
        "cc=" .. sortedKV(c.ctrl or {}),                    -- §199 控制类异常时长上限（旧版跳过）
        "co=" .. sortedKV(c.co or BAL.COST_DEF),            -- §200.10 闪避扣杀气 / 切武器保持杀气（旧版跳过）
        "ch=" .. sortedKV(c.chill or BAL.CHILL_DEF),        -- §206 冰缓伤害倍数（旧版跳过；不放进 cc=：cc= 的旧解码不认新键会整张表不认）
        "sd=" .. sortedKV(c.sd or BAL.SDMG_DEF) }, "|")     -- §212 召唤物每发伤害点数（0.31.0 及更早跳过；§210 起的旧版见 fv=7 整份不收）
end

-- 解析 + 白名单；不对返回 nil, 原因
function CFG.decode(s)
    local p = {}
    for part in (s or ""):gmatch("[^|]+") do
        local k, v = part:match("^(%w+)=(.*)$")
        if k then p[k] = v end
    end
    if p.v ~= "1" then return nil, "版本不认识：" .. tostring(p.v) end
    -- §210 表版本号：表里的格式比我的模组新 / 有我不认识的项 → 整份不收（不半套地用：新加的项被跳过就是"悄悄不一样"）
    local fv = tonumber(p.fv)
    if fv and fv > CFG.FV then return nil, string.format("表比你的模组新（格式 %d，你的模组只认到 %d），请更新模组", fv, CFG.FV), "newer" end
    for k in pairs(p) do
        if not CFG.KEYS[k] then return nil, "表里有你的模组不认识的项 " .. k .. "，请更新模组", "newer" end
    end
    local okAttr, okTal, okTree = {}, {}, {}
    for _, a in ipairs(STD.ORDER) do okAttr[a] = true end
    for _, n in ipairs(CFG.file_.tal) do okTal[n] = true end
    for _, n in ipairs(CFG.file_.tree) do okTree[n] = true end
    local function pairsOf(str, fn)
        for item in (str or ""):gmatch("[^,]+") do
            local k, v = item:match("^([^:]+):([%-%d%.eE+]+)$")
            v = tonumber(v)
            if not (k and v) then return false, "坏项 " .. item end
            local ok, why = fn(k, v)
            if not ok then return false, why end
        end
        return true
    end
    local c = { attr = {}, tal = {}, tree = {}, fam = {}, mv = {}, sum = {}, cd = {}, dot = {}, ctrl = {}, co = {}, chill = {}, sd = {} }
    local ok, why = pairsOf(p.a, function(k, v)
        if not okAttr[k] then return false, "属性不认识 " .. k end
        if v < 1 or v > 100000 then return false, "属性超范围 " .. k end
        c.attr[k] = v; return true
    end)
    if not ok then return nil, why end
    for _, a in ipairs(STD.ORDER) do if not c.attr[a] then return nil, "缺属性 " .. a end end
    c.lv = tonumber(p.lv)
    if not (c.lv and c.lv >= 1 and c.lv <= 30) then return nil, "等级超范围" end
    for n in (p.t or ""):gmatch("[^,]+") do
        if not okTal[n] then return nil, "天赋不认识 " .. n end
        c.tal[#c.tal + 1] = n
    end
    for n in (p.tr or ""):gmatch("[^,]+") do
        if not okTree[n] then return nil, "天赋树效果不认识 " .. n end
        c.tree[#c.tree + 1] = n
    end
    c.edge = tonumber(p.e)
    if not (c.edge and c.edge >= 0 and c.edge <= 5) then return nil, "影之武装系数超范围" end
    ok, why = pairsOf(p.f, function(k, v)
        if not k:match("^%w+$") or v < 0 or v > 5 then return false, "族系数不对 " .. k end
        c.fam[k] = v; return true
    end)
    if not ok then return nil, why end
    ok, why = pairsOf(p.m, function(k, v)
        local n = CFG.long(k)
        if not n:match("^GA_[%w_]+$") or v < 0 or v > 5 then return false, "单招系数不对 " .. k end
        c.mv[n] = v; return true
    end)
    if not ok then return nil, why end
    -- §177 召唤留场秒数：没有 s=（旧版主机 / 服务器发的）就用本地文件的
    if p.s == nil then
        for k, v in pairs(CFG.file_.sum or {}) do c.sum[k] = v end
    else
        ok, why = pairsOf(p.s, function(k, v)
            local n = CFG.long(k)
            if not n:match("^GA_[%w_]+$") or v <= 0 or v > BAL.SUM_CAP then return false, "召唤留场不对 " .. k end
            c.sum[n] = v; return true
        end)
        if not ok then return nil, why end
    end
    -- §184 召唤物冷却：没有 cd=（旧版主机 / 服务器发的表）= 默认（火枪 15 秒，BAL.CD_DEF）；cd= 空 = 都不冷却
    if p.cd == nil then
        for k, v in pairs(BAL.CD_DEF) do c.cd[k] = v end
    else
        ok, why = pairsOf(p.cd, function(k, v)
            if not k:match("^[%w_]+$") or v < 0 or v > BAL.CD_CAP then return false, "召唤冷却不对 " .. k end
            c.cd[k] = v; return true
        end)
        if not ok then return nil, why end
    end
    -- §199 持续伤害系数 / 控制类上限：没有 d= / cc=（旧版主机 / 服务器发的）就用本地文件的
    if p.d == nil then
        for k, v in pairs(CFG.file_.dot or {}) do c.dot[k] = v end
    else
        ok, why = pairsOf(p.d, function(k, v)
            local n = CFG.long(k)
            if not (n:match("^GA_[%w_]+$") or n:match("^%w+$")) or v < 0 or v > BAL.DOT_CAP then return false, "持续系数不对 " .. k end
            c.dot[n] = v; return true
        end)
        if not ok then return nil, why end
    end
    if p.cc == nil then
        for k, v in pairs(CFG.file_.ctrl or {}) do c.ctrl[k] = v end
    else
        ok, why = pairsOf(p.cc, function(k, v)
            if not BAL.CTRL_IDS[k] or v < 0 or v > BAL.CTRL_CAP then return false, "控制上限不对 " .. k end
            c.ctrl[k] = v; return true
        end)
        if not ok then return nil, why end
    end
    -- §200.10 闪避扣杀气 / 切武器保持杀气：没有 co=（旧版主机 / 服务器发的表）= 默认（20 / 20 / 开，BAL.COST_DEF）
    if p.co == nil then
        for k, v in pairs(BAL.COST_DEF) do c.co[k] = v end
    else
        ok, why = pairsOf(p.co, function(k, v)
            if not k:match("^[%w_]+$") or v < 0 or v > BAL.COST_CAP then return false, "消耗不对 " .. k end
            c.co[k] = v; return true
        end)
        if not ok then return nil, why end
    end
    -- §206 冰缓伤害倍数：没有 ch=（旧版主机 / 服务器发的表）= 默认（去掉伤害，BAL.CHILL_DEF）；不认识的键跳过（以后加项旧版不至于整张不认）
    for k, v in pairs(BAL.CHILL_DEF) do c.chill[k] = v end
    if p.ch ~= nil then
        ok, why = pairsOf(p.ch, function(k, v)
            if not BAL.CHILL_IDS[k] then return true end
            if v < 0 or v > 1 then return false, "冰缓倍数不对 " .. k end
            c.chill[k] = v; return true
        end)
        if not ok then return nil, why end
    end
    -- §212 召唤物每发伤害：没有 sd=（旧版主机 / 服务器发的表）= 默认（火枪 1，BAL.SDMG_DEF）；键 [%w_]+、0–SDMG_CAP，坏的整份不收（同 cd=）
    for k, v in pairs(BAL.SDMG_DEF) do c.sd[k] = v end
    if p.sd ~= nil then
        ok, why = pairsOf(p.sd, function(k, v)
            if not k:match("^[%w_]+$") or v < 0 or v > BAL.SDMG_CAP then return false, "召唤物每发伤害不对 " .. k end
            c.sd[k] = v; return true
        end)
        if not ok then return nil, why end
    end
    -- 没列出来的招按兜底：把兜底不是 1 的那些招也补成表里的数，解出来和 snapshot 一样完整
    for k in pairs(CFG.file_.mv) do
        if c.mv[k] == nil then c.mv[k] = CFG.fallback(k, c.fam, c.edge) end
    end
    return c
end

-- 让 STD / BAL 用这一份
function CFG.use(c)
    STD.ATTR, STD.LEVEL = {}, c.lv
    for k, v in pairs(c.attr) do STD.ATTR[k] = v end
    STD.TARGET_MULT = STD.mult(STD.LEVEL)
    STD.TALENT_GE, STD.TREE_GE = {}, {}
    for _, n in ipairs(c.tal) do STD.TALENT_GE[#STD.TALENT_GE + 1] = n end
    for _, n in ipairs(c.tree) do STD.TREE_GE[#STD.TREE_GE + 1] = n end
    BAL.FAMILY, BAL.MOVE = {}, {}
    for k, v in pairs(c.fam) do BAL.FAMILY[k] = v end
    for k, v in pairs(c.mv) do BAL.MOVE[k] = v end
    BAL.SUMMON = {}
    for k, v in pairs(c.sum or {}) do BAL.SUMMON[k] = v end
    BAL.COOLDOWN = {}
    for k, v in pairs(c.cd or BAL.CD_DEF) do BAL.COOLDOWN[k] = v end     -- §184
    BAL.DOT, BAL.CTRL = {}, {}
    for k, v in pairs(c.dot or {}) do BAL.DOT[k] = v end                 -- §199
    for k, v in pairs(c.ctrl or {}) do BAL.CTRL[k] = v end
    BAL.COST = {}
    for k, v in pairs(c.co or BAL.COST_DEF) do BAL.COST[k] = v end      -- §200.10
    BAL.CHILL = {}
    for k, v in pairs(c.chill or BAL.CHILL_DEF) do BAL.CHILL[k] = v end  -- §206
    BAL.SDMG = {}
    for k, v in pairs(c.sd or BAL.SDMG_DEF) do BAL.SDMG[k] = v end      -- §212
    LO.EDGE_SCALE = c.edge
end

-- 本机的基准：大厅服务器给过的那份（联机程序缓存在 net/srvcfg.txt，§158 服务器下发）优先，没有 / 坏了用模组目录里的文件
function CFG.init()
    CFG.file_ = CFG.snapshot()      -- 模组文件里的（也是解码时的白名单）
    CFG.pick()
end

function CFG.pick()
    local base, src = CFG.file_, "模组文件"
    local t = fileReadKV(NET_DIR .. "/srvcfg.txt")
    CFG.srvHash, CFG.srvAt, CFG.srvSig, CFG.srvPend = t and t.h, CFG.clock(), CFG.peek(), nil
    if t and t["end"] and t.h and t.s then
        if CFG.hash(t.s) ~= t.h then
            out("!! 数值表：srvcfg.txt 哈希对不上（%s ≠ %s），不用", CFG.hash(t.s), t.h)
        else
            local c, why, kind = CFG.decode(t.s)
            if c then base, src = c, "大厅服务器" else out("!! 数值表：大厅服务器那份不认（%s），用模组文件", tostring(why)) end
            CFG.srvNewer = (not c and kind == "newer") and why or nil      -- §210 横幅提示更新
        end
    end
    CFG.local_ = CFG.decode(CFG.encode(base))       -- 复制一份（下面测试开关会改）
    -- 测试用：net 目录里有 cfg_test.txt 就按它改本地这份（双开两份共用一个模组目录，造"两边表不一样"）。hp=血上限，mv=招名:系数
    local tt = fileReadKV(NET_DIR .. "/cfg_test.txt")
    if tt then
        if tonumber(tt.hp) then CFG.local_.attr.Health_Max = tonumber(tt.hp) end
        local mk, mvv = (tt.mv or ""):match("^([%w_]+):([%d%.]+)$")
        if mk then CFG.local_.mv[mk] = tonumber(mvv) end
        out("!! 数值表：测试用 cfg_test.txt 改了本地这份（hp=%s mv=%s）", tostring(tt.hp), tostring(tt.mv))
    end
    CFG.use(CFG.local_)
    CFG.localStr = CFG.encode(CFG.local_)
    CFG.localHash = CFG.hash(CFG.localStr)
    CFG.localSrc = src
    out("数值表（标准数值基准 + 武器平衡）：本地 %s，%d 字节，来自%s", CFG.localHash, #CFG.localStr, src)
end

-- §196 对局外每 SRV_EVERY 秒看一下联机程序有没有从服务器拿到新的。
-- 11-09 实测"游戏开着换了 srvcfg.txt、几分钟都没换上，只有重启才生效"，根因：以前按游戏时钟 now() 节流，
-- now() 在拿不到玩家控制器时（读档 / 切图的加载画面）退回 os.time()（≈ 17 亿秒），这一下把 srvAt 记成了 17 亿，
-- 加载完 now() 又回到游戏秒数，"tn - srvAt < 15" 永远成立 → 这一局游戏里再也不查。现在节流改用墙钟 CFG.clock（os.time），
-- 跟游戏时钟无关；墙钟倒退（改系统时间）也当到点。
-- 只读文件头：第一行 h=<哈希> + 文件大小（seek 到尾，不读内容），和上次一样就不往下读；变了才整份重读（CFG.pick）。
-- 对局中（MATCH.state 不是 idle）发现变了只记一行"等对局结束"，不换（这一场用的表不能中途变）；回自由活动（CFG.finish）后下一次检查就换
CFG.SRV_EVERY = 5
CFG.clock = os.time
-- srvcfg.txt 的"签名"：哈希行 + 大小；没有文件 = ""
function CFG.peek()
    local f = io.open(NET_DIR .. "/srvcfg.txt", "r")
    if not f then return "" end
    local h
    for _ = 1, 3 do         -- 联机程序写的第一行就是 h=；手写的文件可能前面有空行 / BOM，多看两行
        local l = f:read("l")
        if not l then break end
        h = l:match("h=(%x+)")
        if h then break end
    end
    local size = f:seek("end")
    f:close()
    return tostring(h) .. ":" .. tostring(size)
end
function CFG.refresh(tn)
    local w = CFG.clock()
    if CFG.srvAt and w >= CFG.srvAt and w - CFG.srvAt < CFG.SRV_EVERY then return end
    CFG.srvAt = w
    local sig = CFG.peek()
    if sig == CFG.srvSig then CFG.srvPend = nil; return end
    if MATCH.state ~= "idle" then
        if CFG.srvPend ~= sig then
            CFG.srvPend = sig
            out("数值表：srvcfg.txt 变了（%s → %s），对局中先不换，回到自由活动再换", tostring(CFG.srvSig), sig)
        end
        return
    end
    out("数值表：srvcfg.txt 变了（%s → %s），重新挑", tostring(CFG.srvSig), sig)
    CFG.pick()
end

-- 状态包里报的哈希
function CFG.wire()
    CFG.refresh(now())
    return CFG.localHash or ""
end

-- 收到对方状态包（我是客机时才管）
function CFG.onPacket(h, tn)
    CFG.rHash = (h and h ~= "") and h or nil
    if (MATCH.session and MATCH.session.role) ~= "client" or not CFG.rHash then return end
    if CFG.rHash == CFG.localHash or CFG.rHash == CFG.haveHash then return end
    if tn - CFG.reqAt < CFG.REQ_EVERY then return end
    CFG.reqAt = tn
    CFG.rel.send("cfgreq", CFG.rHash)
end

-- 主机：把本地这份拆块发出去
function CFG.sendAll()
    local s, h = CFG.localStr, CFG.localHash
    local n = math.ceil(#s / CFG.CHUNK)
    for i = 1, n do CFG.rel.send("cfg", string.format("%s %d %d %s", h, i, n, s:sub((i - 1) * CFG.CHUNK + 1, i * CFG.CHUNK))) end
    out("数值表：发给对方 %s，%d 块", h, n)
end

-- 客机：收一块
function CFG.onChunk(rest)
    local h, i, n, data = rest:match("^(%x+) (%d+) (%d+) (.*)$")
    i, n = tonumber(i), tonumber(n)
    if not (h and i and n and n >= 1 and n <= 200 and i >= 1 and i <= n) then out("!! 数值表：坏块 %s", rest:sub(1, 40)); return end
    if CFG.partsHash ~= h then CFG.parts, CFG.partsHash = {}, h end
    CFG.parts[i] = data
    for k = 1, n do if not CFG.parts[k] then return end end
    local s = table.concat(CFG.parts, "", 1, n)
    CFG.parts, CFG.partsHash = nil, nil
    if CFG.hash(s) ~= h then out("!! 数值表：收齐了但哈希对不上（%s ≠ %s），不用", CFG.hash(s), h); return end
    local c, why = CFG.decode(s)
    if not c then out("!! 数值表：主机那份不认（%s），不用", tostring(why)); return end
    CFG.have, CFG.haveHash = c, h
    out("数值表：收到主机的 %s（%d 字节）", h, #s)
end

-- 每场第 1 回合倒计时：定下这一场用哪份
function CFG.begin()
    local role = MATCH.role
    CFG.srcNote = nil
    if role == "client" and CFG.rHash and CFG.rHash ~= CFG.localHash then
        if CFG.haveHash == CFG.rHash then
            CFG.use(CFG.have)
            CFG.usedHash = CFG.rHash         -- §210 这一场用的是哪份（进规则指纹）
            out("数值表：这一场用主机的 %s", CFG.rHash)
        else
            CFG.use(CFG.local_)
            CFG.usedHash = CFG.localHash
            CFG.srcNote = "本地"
            out("!! 数值表：主机的 %s 还没收到 / 不认，这一场用本地的 %s（伤害可能不对称）", CFG.rHash, CFG.localHash)
        end
    else
        CFG.use(CFG.local_)
        CFG.usedHash = CFG.localHash
    end
end

-- 回到自由活动：换回本地
function CFG.finish()
    CFG.use(CFG.local_)
    CFG.srcNote = nil
    CFG.srvAt = nil        -- §196 回自由活动马上查一次 srvcfg.txt（对局中变了的这时换上）
end
CFG.init()
-- §110 武林盟主（排位）固定规则：联机程序在 lobby.txt 里给 rk=1（当前连接方式是 ranked）和 rkrules=bo=3;dm=150;med=0;bal=1;ctr=1;ab=0
-- （服务器下发）。这时上面的 NET.bestOf / dmgPct / allBlock / flag 一律按 rkrules 返回，主机、客机一样，不看本机 rules.txt / 主机状态包；
-- 开局 / 跟随时定下 MATCH.* 的地方调的就是它们，不用改。规则还没拿到（rk=1 但 rkrules 空）时不拿本机设置冒充：主机不让开局
-- （F1 / startMatchNow），那时各取值函数照旧。rkrules 里缺的键按原版默认，坏值不认（也按默认）。
-- lobby.txt 在 NETUI 段才读得到（netuiRead），这里先放个空的，那边换掉
NET.RK_DEF = { bo = 3, dm = 100, ab = 0, ctr = 1, bal = 0, med = 1, npos = 1, std = 0, ult0 = 0, ultx = 100, sp0 = 3, resm = 0, acc = 0, accn = 3 }   -- §176 accn 生效饰品数量：服务器 rkrules 的 accn=（moecn 写明 3，§169.5），不发也按 3（武林盟主默认只生效前 3 件）；禁用名单走 rkrules 的 accban=（§179.4，NET.rkAccBan）；§170.1 acc 饰品等级：服务器不发就是原样；§169 std 标准数值：服务器发 std=1 就开，不发就关（以前不在表里，排位写死关）；§113 ult0 / sp0 / resm：服务器不发就是 0 / 3 / 每场（§113.3）；§113.4 ultx 获取倍率 100%；§138 npos 对手位置严格跟随（以前不在表里：排位跟主机自己的设置，固定规则页还误显示"关"）
NET.RK_DEF.tl = 180      -- §173 武林盟主回合时限：服务器不发 tl= 就是 180 秒
NET.rkLobby = function() return nil end
NET.rkCache = {}
function NET.rkParse(s)      -- "bo=3;dm=150;…" → { bo = 3, dm = 150, … }；空 / 一个认识的键都没有 → nil
    if not s or s == "" then return nil end
    if NET.rkCache.s == s then return NET.rkCache.r end
    local r, any = {}, false
    for k, v in pairs(NET.RK_DEF) do r[k] = v end
    for k, v in s:gmatch("(%w+)=(%-?%d+)") do
        local n, ok = tonumber(v), false
        if k == "bo" then ok = n >= 1 and n <= 99 and n % 2 == 1
        elseif k == "dm" then ok = n >= 10 and n <= 1000
        elseif NET.RES_MAX[k] then ok = NET.resValid(k, n)          -- §113
        elseif NET.RK_DEF[k] ~= nil then ok = n == 0 or n == 1 end
        if ok then r[k], any = n, true end
    end
    if not any then r = nil end
    NET.rkCache = { s = s, r = r }
    return r
end
function NET.rk()            -- 返回 是不是排位方式, 规则表（还没拿到 = nil）
    local lb = NET.rkLobby()
    if not (lb and lb.rk == "1") then return false, nil end
    return true, NET.rkParse(lb.rkrules)
end
function NET.rkRules() local on, r = NET.rk(); return on and r or nil end
function NET.rkWaiting() local on, r = NET.rk(); return on and r == nil end

-- ---- §181 作弊数据采样（房间设置 cs=，HANDOVER §181）
-- 用户 11-09："举报只保留修改器 / 外挂这个吧，然后我们可以拿到数据看异常，将来给反作弊打底子"；"需要做成房间设置开关"；
-- "这个不用给提示，静默即可"。开着时（普通房间默认开、武林盟主固定开；本地 AI / 假对手不采）本机内存里每场攒一份摘要：
-- 只读现成的数据——对方状态包的 hp= / hpm= / sh= / shm= / med= / att= / 坐标 / ts= / ev= / evt= / res=、本机判定（netJudge）的中招、
-- LAT 往返——不写盘、不加状态包字段，对方是旧版也能采。只有玩家点"提交举报"时，把这个对手当前 / 最近一场的摘要（一行 JSON）
-- 随 report 命令交给联机程序（ev=），联机程序 gzip + Base64 分片发给大厅服务器（PBZS|EVID）。
-- 没举报的：下一场开始、换了对手、对局结束 KEEP 秒后都丢掉。屏幕上什么都不提示（倒计时横幅 / toast 都没有），只在房间设置页有这一项。
-- 防误报（§181.5）：样本带当时往返，超过 LAT_BAD 的不计数（只记进 ux）；标准数值没开的对局不算伤害 / 属性两项；
-- 招表里没有的招、召唤类不算伤害；喝药后 / 刚打中我（吸血、处决回血）/ 刚格挡掉我的招（精防回杀气）的回复不算；开打后几秒不比
CS = { SETTLE = 4.0, KEEP = 900, MAXD = 10, MAX_BYTES = 4000,
       BIG_X = 3.0,              -- ① 单次伤害 > 招表标准 × 3（§181.4）
       LO_X = 1 / 3, LO_CAP = 10,  -- 受伤偏少：对方回报我的招 hit 的伤害 < 标准 ÷ 3（§193 起进服务端排名）；打分封顶 10（回报 0 = 无敌那种）
       CD_X = 0.5,               -- ② 同一招两次间隔 < 技能时长 × 0.5
       LAT_BAD = 300,            -- 往返 / 包龄超过 300 ms 的样本不可信（§181.5）
       HEAL_MIN = 0.03, HEAL_ABS = 60, MED_WIN = 6.0, HIT_WIN = 3.0,    -- ③ 回血：一包里涨 ≥ 血上限 3% 且 ≥ 60；喝药后 6 秒 / 打中我后 3 秒内不算
       SH_MIN = 0.5, PARRY_WIN = 2.0,                                   -- ③ 杀气：一包里涨超过上限一半；格挡 / 精防我的招后 2 秒内不算
       TP_DIST = 1000, TP_SPEED = 3000, TP_DT = 1.0,                    -- ④ 瞬移：相邻两包位移 > 10 米且 > 30 米/秒（包隔 1 秒以上不比）
       FIGHT_GRACE = 2.0,        -- 开打后 2 秒内不比血 / 杀气 / 位置（开打回满、归位）
       ATTR_X = 1.6, ATTR = { "Health_Max", "Shachi_Max", "Attack", "ShachiAttack" },   -- ⑤ 标准数值下对方回报的属性 > 基准 × 1.6（饰品加成留余量）
       EDGE_COLL = 0.35,         -- 招表采集时（§165，关武器平衡）影之武装招的替身攻击力系数 = LO.EDGE_SCALE
       RES_DT = 1.0,             -- ③ 回血 / 回杀气：相邻两包隔 1 秒以上（卡了 / 丢包）不比（中间可能有没看到的喝药 / 吸血）
       CATS = { "big", "cd", "heal", "sh", "tp", "attr", "lo" },
       err = {},                 -- 出过错的接线点（CS.safe 每处只记一次日志）
       cur = nil, last = nil }
-- §181 BEGIN 招表（tools/movedata/gen_cs_table.py 从 data/move_table.csv 生成，705 招，别手改）：{ 总伤害, 技能时长秒, 影之武装 = 1 }
CS.STD = {
    GA_BrutalAxe_Combo_C = { 983, 4, 1 }, GA_BrutalAxe_Normal_C = { 1360, 5, 1 }, GA_BrutalAxe_Sprint_C = { 0, 4, 1 },
    GA_CaoOuSiXian_Normal_01_C = { 0, 4, 1 }, GA_DuYan_Bow_Laser_C = { 922, 2, 1 }, GA_DuYan_Bow_Normal_C = { 1506, 2, 1 },
    GA_HorseCart_Charge_C = { 0, 2, 1 }, GA_HuangJinHuoChong_Dash_C = { 1359, 1, 1 }, GA_HuangJinHuoChong_DeflectCounter_C = { 1121, 3, 1 },
    GA_HuangJinHuoChong_Normal_02_C = { 1359, 2, 1 }, GA_HuangJinHuoChong_Normal_04_C = { 1698, 1, 1 },
    GA_Hun_Air_Double_AAA_C = { 632, 3 }, GA_Hun_Air_Double_AA_C = { 379, 0 }, GA_Hun_Air_Tang_AA_C = { 674, 2 },
    GA_Hun_BaiYing_AAAAA_C = { 793, 2 }, GA_Hun_BaiYing_AAAA_C = { 776, 3 }, GA_Hun_BaiYing_AAA_C = { 867, 2 },
    GA_Hun_BaiYing_AA_C = { 51, 3 }, GA_Hun_BaiYing_A_C = { 1011, 2 }, GA_Hun_BaiYing_A_DashDraw_C = { 9, 3 },
    GA_Hun_BaiYing_A_Dash_C = { 762, 3 }, GA_Hun_BaiYing_Air_A_C = { 670, 3 }, GA_Hun_BaiYing_Air_A_Draw_C = { 667, 3 },
    GA_Hun_BaiYing_Air_B_C = { 701, 3 }, GA_Hun_BaiYing_Air_B_Draw_C = { 9, 3 }, GA_Hun_BaiYing_BBB_C = { 1847, 3 },
    GA_Hun_BaiYing_BB_C = { 1490, 3 }, GA_Hun_BaiYing_B_C = { 609, 2 }, GA_Hun_BaiYing_B_DashDraw_C = { 1121, 2 },
    GA_Hun_BaiYing_B_Dash_C = { 1427, 3 }, GA_Hun_BaiYing_C_C = { 2194, 5 }, GA_Hun_BaiYing_SWT_Power_C = { 0, 2 },
    GA_Hun_BaiYing_SpeicalAssault_C = { 1658, 2 }, GA_Hun_BronzeSword_AAAA_C = { 773, 3 }, GA_Hun_BronzeSword_AAABB_C = { 1847, 3 },
    GA_Hun_BronzeSword_AAAB_C = { 1847, 4 }, GA_Hun_BronzeSword_AAA_C = { 646, 2 }, GA_Hun_BronzeSword_AABB_C = { 1847, 5 },
    GA_Hun_BronzeSword_AAB_C = { 1847, 2 }, GA_Hun_BronzeSword_AA_C = { 646, 3 }, GA_Hun_BronzeSword_ABB_C = { 1822, 2 },
    GA_Hun_BronzeSword_AB_C = { 697, 2 }, GA_Hun_BronzeSword_A_C = { 394, 2 }, GA_Hun_BronzeSword_A_Dash_C = { 438, 4 },
    GA_Hun_BronzeSword_A_Draw_C = { 394, 3 }, GA_Hun_BronzeSword_BA_C = { 646, 2 }, GA_Hun_BronzeSword_BBB_C = { 385, 3 },
    GA_Hun_BronzeSword_BB_C = { 1354, 3 }, GA_Hun_BronzeSword_B_C = { 438, 2 }, GA_Hun_BronzeSword_B_Dash_C = { 1091, 3 },
    GA_Hun_BronzeSword_B_Hold_C = { 809, 2 }, GA_Hun_BronzeSword_C_C = { 1572, 4 }, GA_Hun_BronzeSword_SWT_C = { 0, 3 },
    GA_Hun_Chaos_AAAAA_C = { 912, 3 }, GA_Hun_Chaos_AAAA_C = { 773, 2 }, GA_Hun_Chaos_AAABB_Physics_C = { 2092, 3 },
    GA_Hun_Chaos_AAAB_Physics_C = { 2093, 3 }, GA_Hun_Chaos_AAA_C = { 794, 2 }, GA_Hun_Chaos_AABB_Physics_C = { 738, 2 },
    GA_Hun_Chaos_AAB_Physics_C = { 545, 3 }, GA_Hun_Chaos_AA_C = { 773, 3 }, GA_Hun_Chaos_ABB_Physics_C = { 738, 3 },
    GA_Hun_Chaos_AB_Physics_C = { 467, 3 }, GA_Hun_Chaos_A_C = { 495, 3 }, GA_Hun_Chaos_A_DashDraw_C = { 867, 2 },
    GA_Hun_Chaos_A_Dash_C = { 867, 2 }, GA_Hun_Chaos_A_Draw_C = { 495, 2 }, GA_Hun_Chaos_BBB_Physics_C = { 738, 2 },
    GA_Hun_Chaos_BB_Physics_C = { 1551, 2 }, GA_Hun_Chaos_B_DashDraw_C = { 805, 3 }, GA_Hun_Chaos_B_Dash_C = { 188, 2 },
    GA_Hun_Chaos_B_Draw_C = { 828, 3 }, GA_Hun_Chaos_B_Hold_Physics_C = { 828, 3 }, GA_Hun_Chaos_B_Physics_C = { 828, 3 },
    GA_Hun_Chaos_C_C = { 2631, 4 }, GA_Hun_Chaos_SwitchFormPhysic_SWT_C = { 1988, 2 }, GA_Hun_ChiRen_AAAABB_C = { 1755, 3 },
    GA_Hun_ChiRen_AAAAB_C = { 1756, 3 }, GA_Hun_ChiRen_AAAA_C = { 722, 3 }, GA_Hun_ChiRen_AAABB_C = { 965, 3 },
    GA_Hun_ChiRen_AAAB_C = { 893, 4 }, GA_Hun_ChiRen_AAA_C = { 600, 2 }, GA_Hun_ChiRen_AABB_C = { 759, 2 },
    GA_Hun_ChiRen_AAB_C = { 759, 3 }, GA_Hun_ChiRen_AA_C = { 600, 2 }, GA_Hun_ChiRen_ABB_C = { 1756, 3 }, GA_Hun_ChiRen_AB_C = { 1282, 3 },
    GA_Hun_ChiRen_A_C = { 973, 2 }, GA_Hun_ChiRen_A_Draw_C = { 356, 2 }, GA_Hun_ChiRen_BBB_C = { 843, 3 }, GA_Hun_ChiRen_BB_C = { 780, 3 },
    GA_Hun_ChiRen_BD_C = { 2967, 3 }, GA_Hun_ChiRen_BSup_C = { 2125, 4 }, GA_Hun_ChiRen_B_C = { 0, 3 },
    GA_Hun_ChiRen_B_DashDraw_C = { 1028, 3 }, GA_Hun_ChiRen_B_Dash_C = { 984, 3 }, GA_Hun_ChiRen_B_Draw_C = { 723, 4 },
    GA_Hun_ChiRen_C_C = { 2468, 4 }, GA_Hun_ChiRen_SWT_C = { 5312, 2 }, GA_Hun_ChiZheCanJian_C_C = { 2537, 6 },
    GA_Hun_ChiZheCanJian_Drunk_AAAAA_C = { 0, 4 }, GA_Hun_ChiZheCanJian_Drunk_AAAA_C = { 0, 5 },
    GA_Hun_ChiZheCanJian_Drunk_AAA_C = { 574, 3 }, GA_Hun_ChiZheCanJian_Drunk_AA_C = { 0, 4 }, GA_Hun_ChiZheCanJian_Drunk_A_C = { 454, 4 },
    GA_Hun_ChiZheCanJian_Drunk_A_DashChild_C = { 454, 2 }, GA_Hun_ChiZheCanJian_Normal_AAAAA_C = { 315, 3 },
    GA_Hun_ChiZheCanJian_Normal_AAAA_C = { 387, 3 }, GA_Hun_ChiZheCanJian_Normal_AAA_C = { 913, 3 },
    GA_Hun_ChiZheCanJian_Normal_AA_C = { 296, 3 }, GA_Hun_ChiZheCanJian_Normal_AA_DashChild_C = { 913, 3 },
    GA_Hun_ChiZheCanJian_Normal_A_C = { 113, 2 }, GA_Hun_ChiZheCanJian_Normal_BBB_C = { 593, 4 },
    GA_Hun_ChiZheCanJian_Normal_BB_C = { 807, 3 }, GA_Hun_ChiZheCanJian_Normal_B_C = { 332, 3 },
    GA_Hun_ChiZheCanJian_Normal_B_DashChild_C = { 332, 2 }, GA_Hun_ChiZheCanJian_SWT_C = { 0, 4 },
    GA_Hun_ChiZheCanJian_Tipsy_BBB_C = { 0, 4 }, GA_Hun_ChiZheCanJian_Tipsy_BB_C = { 0, 3 }, GA_Hun_ChiZheCanJian_Tipsy_B_C = { 0, 2 },
    GA_Hun_Double_AAAAAA_C = { 748, 3 }, GA_Hun_Double_AAAAA_C = { 484, 2 }, GA_Hun_Double_AAAA_C = { 634, 3 },
    GA_Hun_Double_AAABBB_C = { 617, 2 }, GA_Hun_Double_AAABB_C = { 2468, 4 }, GA_Hun_Double_AAAB_C = { 1379, 3 },
    GA_Hun_Double_AAA_C = { 358, 3 }, GA_Hun_Double_AABB_C = { 1634, 2 }, GA_Hun_Double_AAB_C = { 938, 3 }, GA_Hun_Double_AA_C = { 521, 2 },
    GA_Hun_Double_ABB_C = { 1600, 3 }, GA_Hun_Double_AB_C = { 1158, 2 }, GA_Hun_Double_ATBBB_C = { 1820, 4 },
    GA_Hun_Double_ATBB_C = { 856, 3 }, GA_Hun_Double_ATB_C = { 321, 3 }, GA_Hun_Double_A_C = { 910, 1 },
    GA_Hun_Double_A_DashDraw_Short_C = { 417, 3 }, GA_Hun_Double_A_Dash_Short_C = { 591, 2 }, GA_Hun_Double_A_Draw_C = { 248, 3 },
    GA_Hun_Double_Air_A_C = { 646, 3 }, GA_Hun_Double_Air_A_Draw_C = { 646, 3 }, GA_Hun_Double_Air_B_C = { 697, 1 },
    GA_Hun_Double_Air_B_Draw_C = { 697, 2 }, GA_Hun_Double_BBBB_C = { 688, 3 }, GA_Hun_Double_BBB_C = { 840, 3 },
    GA_Hun_Double_BB_C = { 784, 2 }, GA_Hun_Double_BTA_C = { 1703, 4 }, GA_Hun_Double_B_C = { 419, 3 },
    GA_Hun_Double_B_DashDraw_C = { 920, 3 }, GA_Hun_Double_B_Dash_C = { 615, 3 }, GA_Hun_Double_B_Draw_C = { 566, 3 },
    GA_Hun_Double_JueYing_C_Air_C = { 0, 4 }, GA_Hun_Double_JueYing_C_C = { 1211, 4 }, GA_Hun_Double_SWT_C = { 0, 2 },
    GA_Hun_Double_SWT_Tutorial_C = { 0, 3 }, GA_Hun_DualHook_AAAAA_C = { 618, 2 }, GA_Hun_DualHook_AAAA_C = { 495, 3 },
    GA_Hun_DualHook_AAABB_C = { 941, 3 }, GA_Hun_DualHook_AAAB_C = { 1355, 3 }, GA_Hun_DualHook_AAA_C = { 379, 3 },
    GA_Hun_DualHook_AABB_C = { 1259, 2 }, GA_Hun_DualHook_AAB_C = { 509, 3 }, GA_Hun_DualHook_AA_C = { 394, 2 },
    GA_Hun_DualHook_ABB_C = { 570, 3 }, GA_Hun_DualHook_AB_C = { 788, 2 }, GA_Hun_DualHook_A_C = { 809, 2 },
    GA_Hun_DualHook_A_DashDraw_C = { 435, 2 }, GA_Hun_DualHook_A_Dash_C = { 421, 3 }, GA_Hun_DualHook_A_Draw_C = { 809, 2 },
    GA_Hun_DualHook_A_Pursure_02_C = { 495, 2 }, GA_Hun_DualHook_Air_B_C = { 551, 2 }, GA_Hun_DualHook_Air_B_Draw_C = { 551, 2 },
    GA_Hun_DualHook_BBBB_C = { 1354, 3 }, GA_Hun_DualHook_BBB_C = { 717, 3 }, GA_Hun_DualHook_BB_C = { 883, 3 },
    GA_Hun_DualHook_B_C = { 601, 3 }, GA_Hun_DualHook_B_DashDraw_C = { 750, 3 }, GA_Hun_DualHook_B_Dash_C = { 750, 2 },
    GA_Hun_DualHook_B_Draw_C = { 601, 4 }, GA_Hun_DualHook_B_Pursure_C = { 774, 3 }, GA_Hun_DualHook_C_C = { 2119, 4 },
    GA_Hun_DualHook_DB_C = { 0, 3 }, GA_Hun_DualHook_DB_SWT_C = { 0, 2 }, GA_Hun_FengLeiJian_AAAA_C = { 1205, 2 },
    GA_Hun_FengLeiJian_AAABB_C = { 1518, 3 }, GA_Hun_FengLeiJian_AAAB_C = { 801, 3 }, GA_Hun_FengLeiJian_AAA_C = { 1096, 3 },
    GA_Hun_FengLeiJian_AABAB_C = { 1373, 2 }, GA_Hun_FengLeiJian_AABA_C = { 588, 2 }, GA_Hun_FengLeiJian_AABB_C = { 1518, 2 },
    GA_Hun_FengLeiJian_AAB_C = { 665, 2 }, GA_Hun_FengLeiJian_AA_C = { 1095, 1 }, GA_Hun_FengLeiJian_AB_C = { 1060, 3 },
    GA_Hun_FengLeiJian_A_C = { 876, 1 }, GA_Hun_FengLeiJian_A_DashDraw_C = { 402, 3 }, GA_Hun_FengLeiJian_A_Dash_C = { 1139, 2 },
    GA_Hun_FengLeiJian_A_Draw_C = { 239, 3 }, GA_Hun_FengLeiJian_Air_A_C = { 113, 3 }, GA_Hun_FengLeiJian_Air_A_Draw_C = { 113, 3 },
    GA_Hun_FengLeiJian_Air_B_C = { 1281, 2 }, GA_Hun_FengLeiJian_Air_B_Draw_C = { 1281, 1 }, GA_Hun_FengLeiJian_BBBB_C = { 1518, 2 },
    GA_Hun_FengLeiJian_BBB_C = { 1519, 2 }, GA_Hun_FengLeiJian_BB_C = { 950, 2 }, GA_Hun_FengLeiJian_B_C = { 522, 2 },
    GA_Hun_FengLeiJian_B_DashDraw_C = { 864, 3 }, GA_Hun_FengLeiJian_B_Dash_C = { 592, 3 }, GA_Hun_FengLeiJian_B_Draw_C = { 522, 2 },
    GA_Hun_FengLeiJian_B_Hold_C = { 940, 2 }, GA_Hun_FengLeiJian_C_C = { 2446, 4 },
    GA_Hun_FengLeiJian_FengLeiState_SpecailAttack_02_C = { 3203, 4 }, GA_Hun_FengLeiJian_SWT_Power_C = { 2918, 2 },
    GA_Hun_GuiTouBlade_AAAA_C = { 618, 3 }, GA_Hun_GuiTouBlade_AAABB_C = { 466, 2 }, GA_Hun_GuiTouBlade_AAAB_C = { 1573, 3 },
    GA_Hun_GuiTouBlade_AAA_C = { 506, 3 }, GA_Hun_GuiTouBlade_AABB_C = { 1573, 4 }, GA_Hun_GuiTouBlade_AAB_C = { 0, 3 },
    GA_Hun_GuiTouBlade_AA_C = { 506, 3 }, GA_Hun_GuiTouBlade_ABB_C = { 1573, 3 }, GA_Hun_GuiTouBlade_AB_C = { 843, 2 },
    GA_Hun_GuiTouBlade_A_C = { 282, 3 }, GA_Hun_GuiTouBlade_A_DashDraw_C = { 943, 3 }, GA_Hun_GuiTouBlade_A_Dash_C = { 440, 2 },
    GA_Hun_GuiTouBlade_A_Draw_C = { 132, 2 }, GA_Hun_GuiTouBlade_BBB_C = { 1208, 3 }, GA_Hun_GuiTouBlade_BB_C = { 843, 2 },
    GA_Hun_GuiTouBlade_BB_UnCharge_C = { 506, 3 }, GA_Hun_GuiTouBlade_BB_UnCharge_Reinforced_C = { 843, 2 },
    GA_Hun_GuiTouBlade_B_C = { 356, 2 }, GA_Hun_GuiTouBlade_B_DashDraw_C = { 1172, 2 }, GA_Hun_GuiTouBlade_B_Dash_C = { 440, 4 },
    GA_Hun_GuiTouBlade_B_Draw_C = { 356, 2 }, GA_Hun_GuiTouBlade_B_Hold_C = { 1208, 2 }, GA_Hun_GuiTouBlade_B_Hold_Start_C = { 871, 2 },
    GA_Hun_GuiTouBlade_C_C = { 2468, 4 }, GA_Hun_GuiTouBlade_SWT_C = { 1310, 3 }, GA_Hun_HeiMoShang_AAAAAA_C = { 551, 2 },
    GA_Hun_HeiMoShang_AAAAABB_C = { 1917, 3 }, GA_Hun_HeiMoShang_AAAAAB_C = { 859, 3 }, GA_Hun_HeiMoShang_AAAAA_C = { 884, 3 },
    GA_Hun_HeiMoShang_AAAAB_Alt_C = { 1199, 3 }, GA_Hun_HeiMoShang_AAAA_C = { 695, 3 }, GA_Hun_HeiMoShang_AAABB_C = { 286, 4 },
    GA_Hun_HeiMoShang_AAAB_C = { 657, 3 }, GA_Hun_HeiMoShang_AAA_C = { 281, 2 }, GA_Hun_HeiMoShang_AABB_C = { 1162, 3 },
    GA_Hun_HeiMoShang_AAB_C = { 1478, 3 }, GA_Hun_HeiMoShang_AA_C = { 505, 2 }, GA_Hun_HeiMoShang_ABB_C = { 684, 3 },
    GA_Hun_HeiMoShang_AB_C = { 464, 3 }, GA_Hun_HeiMoShang_A_C = { 404, 2 }, GA_Hun_HeiMoShang_A_DashDraw_C = { 697, 3 },
    GA_Hun_HeiMoShang_A_Dash_C = { 697, 2 }, GA_Hun_HeiMoShang_A_Draw_C = { 606, 2 }, GA_Hun_HeiMoShang_BBBB_C = { 1847, 3 },
    GA_Hun_HeiMoShang_BBB_C = { 615, 4 }, GA_Hun_HeiMoShang_BB_C = { 822, 3 }, GA_Hun_HeiMoShang_B_C = { 698, 3 },
    GA_Hun_HeiMoShang_B_DashDraw_C = { 1026, 3 }, GA_Hun_HeiMoShang_B_Dash_C = { 1092, 2 }, GA_Hun_HeiMoShang_B_Draw_C = { 618, 3 },
    GA_Hun_HeiMoShang_C1_C = { 0, 3 }, GA_Hun_HeiMoShang_SWT_C = { 0, 2 }, GA_Hun_Horizontal_AAAA_C = { 1051, 2 },
    GA_Hun_Horizontal_AAAB_C = { 2340, 4 }, GA_Hun_Horizontal_AAA_C = { 899, 3 }, GA_Hun_Horizontal_AAB_C = { 2187, 4 },
    GA_Hun_Horizontal_AA_C = { 899, 2 }, GA_Hun_Horizontal_AB_C = { 1569, 3 }, GA_Hun_Horizontal_A_C = { 0, 2 },
    GA_Hun_Horizontal_A_DashDraw_C = { 960, 3 }, GA_Hun_Horizontal_A_Dash_C = { 0, 2 }, GA_Hun_Horizontal_A_Draw_C = { 596, 2 },
    GA_Hun_Horizontal_BB_C = { 0, 4 }, GA_Hun_Horizontal_B_C = { 960, 3 }, GA_Hun_Horizontal_B_DashDraw_C = { 1333, 2 },
    GA_Hun_Horizontal_B_Dash_C = { 1433, 3 }, GA_Hun_Horizontal_B_Draw_C = { 960, 3 }, GA_Hun_Horizontal_B_NoCost_C = { 960, 2 },
    GA_Hun_Horizontal_C_C = { 1952, 5 }, GA_Hun_Horizontal_CounterAttack_01_C = { 2238, 3 },
    GA_Hun_Horizontal_CounterAttack_02_C = { 1945, 4 }, GA_Hun_HuoLiuXing_AAAA_C = { 2505, 4, 1 }, GA_Hun_HuoLiuXing_AAA_C = { 1660, 5, 1 },
    GA_Hun_HuoLiuXing_AA_C = { 1289, 3, 1 }, GA_Hun_HuoLiuXing_A_C = { 262, 3, 1 }, GA_Hun_HuoLiuXing_A_Short_C = { 370, 3, 1 },
    GA_Hun_HuoLiuXing_DB_C = { 1865, 3, 1 }, GA_Hun_Iron_AAAAA_C = { 558, 2 }, GA_Hun_Iron_AAAA_C = { 501, 3 },
    GA_Hun_Iron_AAABB_C = { 1360, 3 }, GA_Hun_Iron_AAAB_C = { 1208, 3 }, GA_Hun_Iron_AAA_C = { 319, 2 }, GA_Hun_Iron_AABB_C = { 1841, 3 },
    GA_Hun_Iron_AAB_C = { 1443, 3 }, GA_Hun_Iron_AA_C = { 312, 3 }, GA_Hun_Iron_ABB_C = { 1825, 3 }, GA_Hun_Iron_AB_C = { 487, 2 },
    GA_Hun_Iron_A_C = { 749, 2 }, GA_Hun_Iron_A_DashDraw_C = { 584, 2 }, GA_Hun_Iron_A_Dash_C = { 584, 2 },
    GA_Hun_Iron_A_Draw_C = { 893, 2 }, GA_Hun_Iron_BBB_C = { 1208, 4 }, GA_Hun_Iron_BB_C = { 919, 3 },
    GA_Hun_Iron_BChargeAttack_C = { 4, 2 }, GA_Hun_Iron_BCharge_C = { 0, 1 }, GA_Hun_Iron_B_C = { 506, 2 },
    GA_Hun_Iron_B_DashDraw_C = { 1159, 2 }, GA_Hun_Iron_B_Dash_C = { 648, 2 }, GA_Hun_Iron_B_Draw_C = { 356, 3 },
    GA_Hun_Iron_C_C = { 1500, 3 }, GA_Hun_Iron_SWT_C = { 0, 3 }, GA_Hun_Jade_AAAAAA_C = { 596, 3 }, GA_Hun_Jade_AAAAA_C = { 470, 2 },
    GA_Hun_Jade_AAAA_C = { 741, 3 }, GA_Hun_Jade_AAABB_C = { 493, 3 }, GA_Hun_Jade_AAAB_C = { 1183, 2 }, GA_Hun_Jade_AAA_C = { 311, 2 },
    GA_Hun_Jade_AABB_C = { 1059, 2 }, GA_Hun_Jade_AAB_C = { 1697, 2 }, GA_Hun_Jade_AA_C = { 586, 2 }, GA_Hun_Jade_ABB_C = { 834, 3 },
    GA_Hun_Jade_AB_C = { 960, 2 }, GA_Hun_Jade_A_C = { 588, 2 }, GA_Hun_Jade_A_DashDraw_C = { 371, 2 }, GA_Hun_Jade_A_Dash_C = { 526, 3 },
    GA_Hun_Jade_A_Draw_C = { 809, 2 }, GA_Hun_Jade_BBBB_C = { 1647, 2 }, GA_Hun_Jade_BBB_C = { 679, 3 }, GA_Hun_Jade_BB_C = { 664, 3 },
    GA_Hun_Jade_B_C = { 373, 3 }, GA_Hun_Jade_B_DashDraw_C = { 750, 3 }, GA_Hun_Jade_B_Dash_C = { 1172, 4 },
    GA_Hun_Jade_B_Draw_C = { 435, 2 }, GA_Hun_Jade_C_Range_C = { 1488, 4 }, GA_Hun_Jade_DB_C = { 1135, 3 }, GA_Hun_Jade_SWT_C = { 0, 1 },
    GA_Hun_JigSaw_AAAA_C = { 1190, 4 }, GA_Hun_JigSaw_AAA_C = { 1026, 3 }, GA_Hun_JigSaw_AA_C = { 1026, 3 }, GA_Hun_JigSaw_A_C = { 697, 3 },
    GA_Hun_Jigsaw_AAAB_C = { 2876, 4 }, GA_Hun_Jigsaw_AAB_C = { 961, 4 }, GA_Hun_Jigsaw_AB_C = { 1035, 3 },
    GA_Hun_Jigsaw_A_DashDraw_C = { 1091, 3 }, GA_Hun_Jigsaw_A_Dash_C = { 1091, 3 }, GA_Hun_Jigsaw_A_Draw_C = { 697, 3 },
    GA_Hun_Jigsaw_Air_A_C = { 600, 3 }, GA_Hun_Jigsaw_Air_A_Draw_C = { 600, 2 }, GA_Hun_Jigsaw_Air_B_C = { 648, 3 },
    GA_Hun_Jigsaw_Air_B_Draw_C = { 648, 3 }, GA_Hun_Jigsaw_BB_C = { 961, 4 }, GA_Hun_Jigsaw_B_C = { 1092, 4 },
    GA_Hun_Jigsaw_B_DashDraw_C = { 833, 5 }, GA_Hun_Jigsaw_B_Dash_C = { 900, 3 }, GA_Hun_Jigsaw_C_C = { 4028, 6 },
    GA_Hun_Jigsaw_RAAA_C = { 749, 4 }, GA_Hun_Jigsaw_RAA_C = { 795, 3 }, GA_Hun_Jigsaw_RA_C = { 437, 4 }, GA_Hun_Jigsaw_RBB_C = { 812, 4 },
    GA_Hun_Jigsaw_RB_C = { 988, 4 }, GA_Hun_Jigsaw_SA_C = { 527, 4 }, GA_Hun_Jigsaw_SB_C = { 386, 3 },
    GA_Hun_Long_A_DashDraw_C = { 1839, 3 }, GA_Hun_Long_A_Dash_C = { 904, 3 }, GA_Hun_Long_Air_A_C = { 506, 2 },
    GA_Hun_Long_Air_A_Draw_C = { 862, 3 }, GA_Hun_Long_Air_B_C = { 356, 3 }, GA_Hun_Long_Air_B_Draw_C = { 356, 3 },
    GA_Hun_Long_BCharge_C = { 0, 3 }, GA_Hun_Long_CounterA_C = { 0, 4 }, GA_Hun_Long_CounterB_C = { 1423, 3 },
    GA_Hun_Long_Counter_C = { 1208, 3 }, GA_Hun_LuanYing_AAAAA_C = { 588, 3 }, GA_Hun_LuanYing_AAAA_C = { 1014, 3 },
    GA_Hun_LuanYing_AAA_C = { 478, 3 }, GA_Hun_LuanYing_AA_C = { 478, 1 }, GA_Hun_LuanYing_A_C = { 876, 2 },
    GA_Hun_LuanYing_A_DashDraw_C = { 294, 3 }, GA_Hun_LuanYing_DashA_C = { 876, 3 }, GA_Hun_LuanYing_Draw_A_C = { 876, 2 },
    GA_Hun_LuanYing_P2_AAAB_C = { 1058, 3 }, GA_Hun_LuanYing_P2_AAB_C = { 625, 3 }, GA_Hun_LuanYing_P2_AB_C = { 633, 3 },
    GA_Hun_LuanYing_P2_BBB_C = { 976, 2 }, GA_Hun_LuanYing_P2_BB_C = { 828, 3 }, GA_Hun_LuanYing_P2_B_C = { 911, 2 },
    GA_Hun_LuanYing_P2_CA_C = { 4001, 4 }, GA_Hun_LuanYing_SWT_P2_C = { 0, 3 }, GA_Hun_Lute_AAA_C = { 464, 4, 1 },
    GA_Hun_Lute_AA_C = { 865, 3, 1 }, GA_Hun_Lute_A_C = { 324, 3, 1 }, GA_Hun_Lute_SKill_C = { 324, 4, 1 },
    GA_Hun_Mojian_AAA_C = { 617, 3, 1 }, GA_Hun_Mojian_AA_C = { 1971, 4, 1 }, GA_Hun_Mojian_A_C = { 590, 3, 1 },
    GA_Hun_Mojian_A_Short_C = { 590, 3, 1 }, GA_Hun_Mojian_UpRunGEx_01_C = { 1906, 3, 1 }, GA_Hun_PoJun_AAAA_C = { 1051, 4 },
    GA_Hun_PoJun_AAAB_C = { 795, 4 }, GA_Hun_PoJun_AAA_C = { 899, 3 }, GA_Hun_PoJun_AAB_C = { 1394, 3 }, GA_Hun_PoJun_AA_C = { 607, 2 },
    GA_Hun_PoJun_AB_C = { 1749, 3 }, GA_Hun_PoJun_A_C = { 0, 2 }, GA_Hun_PoJun_A_DashDraw_C = { 960, 3 },
    GA_Hun_PoJun_A_Dash_C = { 960, 2 }, GA_Hun_PoJun_A_Draw_C = { 596, 2 }, GA_Hun_PoJun_BB_C = { 0, 4 }, GA_Hun_PoJun_B_C = { 960, 3 },
    GA_Hun_PoJun_B_DashDraw_C = { 1433, 3 }, GA_Hun_PoJun_B_Dash_C = { 1433, 3 }, GA_Hun_PoJun_B_Draw_C = { 960, 3 },
    GA_Hun_PoJun_C_C = { 2345, 5 }, GA_Hun_PoJun_DB_02_C = { 1068, 4 }, GA_Hun_PoJun_DB_C = { 1078, 5 },
    GA_Hun_PoJun_SWT_Super_C = { 0, 4 }, GA_Hun_ShachiHook_CAA_C = { 1560, 4, 1 }, GA_Hun_ShachiHook_CA_C = { 1092, 3, 1 },
    GA_Hun_ShachiHook_CBB_C = { 1141, 3, 1 }, GA_Hun_ShachiHook_CB_C = { 164, 4, 1 }, GA_Hun_ShachiHook_CCCC_C = { 547, 4, 1 },
    GA_Hun_ShachiHook_CCC_C = { 875, 3, 1 }, GA_Hun_ShachiHook_CC_C = { 186, 4, 1 }, GA_Hun_ShachiHook_CDD_C = { 184, 4, 1 },
    GA_Hun_ShachiHook_CD_C = { 409, 5, 1 }, GA_Hun_ShachiHook_C_C = { 151, 2, 1 }, GA_Hun_ShachiHook_Drag_C = { 117, 2, 1 },
    GA_Hun_ShachiHook_HookMove_C = { 748, 1, 1 }, GA_Hun_ShuangYue_AAAAAA_C = { 375, 3 }, GA_Hun_ShuangYue_AAAAA_C = { 654, 3 },
    GA_Hun_ShuangYue_AAAA_C = { 711, 2 }, GA_Hun_ShuangYue_AAABB_C = { 788, 3 }, GA_Hun_ShuangYue_AAAB_C = { 904, 2 },
    GA_Hun_ShuangYue_AAA_C = { 685, 2 }, GA_Hun_ShuangYue_AABB_C = { 744, 4 }, GA_Hun_ShuangYue_AAB_C = { 1184, 2 },
    GA_Hun_ShuangYue_AA_C = { 478, 2 }, GA_Hun_ShuangYue_ABB_C = { 699, 2 }, GA_Hun_ShuangYue_AB_C = { 920, 2 },
    GA_Hun_ShuangYue_A_C = { 876, 1 }, GA_Hun_ShuangYue_A_DashDraw_C = { 522, 2 }, GA_Hun_ShuangYue_A_Dash_C = { 522, 1 },
    GA_Hun_ShuangYue_A_Draw_C = { 876, 2 }, GA_Hun_ShuangYue_BBBB_C = { 676, 3 }, GA_Hun_ShuangYue_BBB_C = { 769, 2 },
    GA_Hun_ShuangYue_BB_C = { 461, 2 }, GA_Hun_ShuangYue_B_C = { 833, 2 }, GA_Hun_ShuangYue_B_DashDraw_C = { 296, 2 },
    GA_Hun_ShuangYue_B_Dash_C = { 888, 2 }, GA_Hun_ShuangYue_B_Draw_C = { 1027, 3 }, GA_Hun_ShuangYue_C_C = { 6310, 5 },
    GA_Hun_ShuangYue_DB_C = { 316, 2 }, GA_Hun_ShuangYue_DB_SWT_C = { 1264, 2 }, GA_Hun_ShuangYue_PBB_C = { 1015, 3 },
    GA_Hun_ShuangYue_PB_C = { 961, 3 }, GA_Hun_SlitheringSword_AAAAA_C = { 866, 3 }, GA_Hun_SlitheringSword_AAAA_C = { 494, 2 },
    GA_Hun_SlitheringSword_AAABB_C = { 2134, 3 }, GA_Hun_SlitheringSword_AAAB_C = { 752, 3 }, GA_Hun_SlitheringSword_AAA_C = { 659, 2 },
    GA_Hun_SlitheringSword_AABB_C = { 886, 5 }, GA_Hun_SlitheringSword_AAB_C = { 1582, 3 }, GA_Hun_SlitheringSword_AA_C = { 843, 2 },
    GA_Hun_SlitheringSword_ABB_C = { 821, 3 }, GA_Hun_SlitheringSword_AB_C = { 1114, 4 }, GA_Hun_SlitheringSword_A_C = { 899, 2 },
    GA_Hun_SlitheringSword_A_DashDraw_C = { 551, 4 }, GA_Hun_SlitheringSword_A_Dash_C = { 551, 3 },
    GA_Hun_SlitheringSword_BBB_C = { 1093, 3 }, GA_Hun_SlitheringSword_BB_C = { 357, 3 }, GA_Hun_SlitheringSword_B_C = { 558, 3 },
    GA_Hun_SlitheringSword_B_DashDraw_C = { 674, 3 }, GA_Hun_SlitheringSword_B_Dash_C = { 675, 4 },
    GA_Hun_SlitheringSword_C_C = { 1788, 5 }, GA_Hun_SlitheringSword_DA_C = { 0, 1 }, GA_Hun_SlitheringSword_DB4_C = { 1335, 2 },
    GA_Hun_SlitheringSword_DB5_C = { 1335, 2 }, GA_Hun_SlitheringSword_EvalutionCombo_New_C = { 955, 4 },
    GA_Hun_SlitheringSword_Potential_C = { 876, 5 }, GA_Hun_SlitheringSword_SWT_C = { 0, 2 }, GA_Hun_SnakeDual_AAA_C = { 913, 3 },
    GA_Hun_SnakeDual_AA_C = { 913, 2 }, GA_Hun_SnakeDual_ABAA_C = { 640, 3 }, GA_Hun_SnakeDual_ABABAA_C = { 522, 4 },
    GA_Hun_SnakeDual_ABABA_C = { 387, 4 }, GA_Hun_SnakeDual_ABABB_C = { 718, 2 }, GA_Hun_SnakeDual_ABAB_C = { 508, 4 },
    GA_Hun_SnakeDual_ABA_C = { 365, 2 }, GA_Hun_SnakeDual_ABB_C = { 1162, 2 }, GA_Hun_SnakeDual_AB_C = { 807, 2 },
    GA_Hun_SnakeDual_A_C = { 730, 3 }, GA_Hun_SnakeDual_A_Dash_C = { 316, 3 }, GA_Hun_SnakeDual_A_Fast_C = { 397, 2 },
    GA_Hun_SnakeDual_Air_A_Double_C = { 397, 3 }, GA_Hun_SnakeDual_Air_A_Draw_Double_C = { 397, 3 },
    GA_Hun_SnakeDual_Air_B_Double_C = { 437, 2 }, GA_Hun_SnakeDual_Air_B_Draw_Double_C = { 438, 2 }, GA_Hun_SnakeDual_BAA_C = { 914, 4 },
    GA_Hun_SnakeDual_BABAA_C = { 255, 3 }, GA_Hun_SnakeDual_BABABB_C = { 1164, 3 }, GA_Hun_SnakeDual_BABAB_C = { 635, 2 },
    GA_Hun_SnakeDual_BABA_C = { 927, 3 }, GA_Hun_SnakeDual_BABB_C = { 445, 2 }, GA_Hun_SnakeDual_BAB_C = { 1163, 3 },
    GA_Hun_SnakeDual_BA_C = { 913, 3 }, GA_Hun_SnakeDual_BB_C = { 807, 2 }, GA_Hun_SnakeDual_B_C = { 332, 2 },
    GA_Hun_SnakeDual_B_Dash_C = { 617, 2 }, GA_Hun_SnakeDual_B_Fast_C = { 965, 2 }, GA_Hun_SnakeDual_C_C = { 2778, 5 },
    GA_Hun_SnakeDual_DA_C = { 872, 3 }, GA_Hun_SnakeDual_DB_C = { 1217, 2 }, GA_Hun_SnakeDual_SWT_C = { 0, 1 },
    GA_Hun_Tang_A_DashDraw_C = { 779, 2 }, GA_Hun_Tang_Air_A_C = { 600, 3 }, GA_Hun_Tang_Air_A_Draw_C = { 600, 2 },
    GA_Hun_Tang_Air_B_C = { 648, 3 }, GA_Hun_Tang_Air_B_Draw_C = { 438, 2 }, GA_Hun_Tang_B_DashDraw_C = { 633, 4 },
    GA_Hun_Tang_B_Draw_C = { 389, 3 }, GA_Hun_Tang_SWT_UI_C = { 773, 2 }, GA_Hun_WoodenSword_AAAAA_C = { 687, 2 },
    GA_Hun_WoodenSword_AAAA_C = { 275, 2 }, GA_Hun_WoodenSword_AAABB_C = { 600, 3 }, GA_Hun_WoodenSword_AAAB_C = { 281, 4 },
    GA_Hun_WoodenSword_AAA_C = { 624, 2 }, GA_Hun_WoodenSword_AABB_C = { 1086, 3 }, GA_Hun_WoodenSword_AAB_C = { 581, 3 },
    GA_Hun_WoodenSword_AA_C = { 624, 1 }, GA_Hun_WoodenSword_ABB_C = { 342, 3 }, GA_Hun_WoodenSword_AB_C = { 465, 2 },
    GA_Hun_WoodenSword_A_C = { 499, 2 }, GA_Hun_WoodenSword_A_DashDraw_C = { 649, 2 }, GA_Hun_WoodenSword_A_Dash_C = { 649, 3 },
    GA_Hun_WoodenSword_A_Draw_C = { 499, 2 }, GA_Hun_WoodenSword_Air_A_C = { 624, 2 }, GA_Hun_WoodenSword_Air_A_Draw_C = { 905, 2 },
    GA_Hun_WoodenSword_Air_B_C = { 649, 2 }, GA_Hun_WoodenSword_Air_B_Draw_C = { 649, 3 }, GA_Hun_WoodenSword_BBB_C = { 1765, 2 },
    GA_Hun_WoodenSword_BB_C = { 397, 3 }, GA_Hun_WoodenSword_B_C = { 649, 3 }, GA_Hun_WoodenSword_B_DashDraw_C = { 248, 3 },
    GA_Hun_WoodenSword_B_Dash_C = { 422, 2 }, GA_Hun_WoodenSword_B_Draw_C = { 649, 3 }, GA_Hun_WoodenSword_C_C = { 1783, 7 },
    GA_Hun_WoodenSword_SWT_New_C = { 0, 3 }, GA_Hun_XieShan_AAAAA_C = { 634, 3 }, GA_Hun_XieShan_AAAA_C = { 417, 3 },
    GA_Hun_XieShan_AAABB_C = { 2080, 3 }, GA_Hun_XieShan_AAAB_C = { 285, 3 }, GA_Hun_XieShan_AAA_C = { 737, 1 },
    GA_Hun_XieShan_AABB_C = { 552, 3 }, GA_Hun_XieShan_AAB_C = { 1418, 2 }, GA_Hun_XieShan_AA_C = { 557, 2 },
    GA_Hun_XieShan_ABB_C = { 913, 2 }, GA_Hun_XieShan_AB_C = { 20, 2 }, GA_Hun_XieShan_A_C = { 910, 2 },
    GA_Hun_XieShan_A_DashDraw_New_C = { 910, 3 }, GA_Hun_XieShan_A_Dash_C = { 566, 2 }, GA_Hun_XieShan_A_Draw_New_C = { 910, 3 },
    GA_Hun_XieShan_BBB_C = { 729, 4 }, GA_Hun_XieShan_BB_C = { 1054, 2 }, GA_Hun_XieShan_B_C = { 1302, 2 },
    GA_Hun_XieShan_B_DashDraw_New_C = { 802, 2 }, GA_Hun_XieShan_B_Dash_C = { 1394, 3 }, GA_Hun_XieShan_B_Draw_New_C = { 809, 2 },
    GA_Hun_XieShan_C_C = { 2317, 5 }, GA_Hun_XieShan_DB_C = { 1025, 3 }, GA_Hun_XieShan_SWT_02_C = { 0, 2 },
    GA_Hun_YanYueDao_AAAA_C = { 1172, 3 }, GA_Hun_YanYueDao_AAA_C = { 1026, 3 }, GA_Hun_YanYueDao_AA_C = { 1026, 3 },
    GA_Hun_YanYueDao_A_C = { 697, 2 }, GA_Hun_YanYueDao_A_Dash_C = { 1091, 3 }, GA_Hun_YanYueDao_BB_C = { 1945, 3 },
    GA_Hun_YanYueDao_B_C = { 1091, 3 }, GA_Hun_YanYueDao_B_Dash_C = { 1377, 2 }, GA_Hun_YanYueDao_B_Reinforced_C = { 1771, 4 },
    GA_Hun_YanYueDao_C_C = { 0, 9 }, GA_Hun_YanYueDao_SWT_C = { 0, 3 }, GA_Hun_YanYueDao_SpecialSkill_C = { 3086, 4 },
    GA_Hun_YuuBlade_AAAAA_C = { 254, 2 }, GA_Hun_YuuBlade_AAAAB_C = { 941, 2 }, GA_Hun_YuuBlade_AAAA_C = { 453, 2 },
    GA_Hun_YuuBlade_AAAB_C = { 1355, 2 }, GA_Hun_YuuBlade_AAA_C = { 404, 2 }, GA_Hun_YuuBlade_AAB_C = { 1126, 2 },
    GA_Hun_YuuBlade_AA_C = { 1011, 2 }, GA_Hun_YuuBlade_AB_C = { 394, 2 }, GA_Hun_YuuBlade_A_C = { 809, 2 },
    GA_Hun_YuuBlade_A_DashDraw_C = { 1052, 2 }, GA_Hun_YuuBlade_A_Dash_C = { 765, 2 }, GA_Hun_YuuBlade_A_Draw_C = { 221, 2 },
    GA_Hun_YuuBlade_BBBB_C = { 1126, 3 }, GA_Hun_YuuBlade_BBB_C = { 896, 2 }, GA_Hun_YuuBlade_BB_C = { 1004, 1 },
    GA_Hun_YuuBlade_B_C = { 434, 2 }, GA_Hun_YuuBlade_B_DashDraw_C = { 750, 2 }, GA_Hun_YuuBlade_B_Dash_C = { 750, 2 },
    GA_Hun_YuuBlade_B_Draw_C = { 1051, 2 }, GA_Hun_YuuBlade_C_C = { 0, 1 }, GA_Hun_YuuBlade_FastHeavyAttack_C = { 1974, 4 },
    GA_Hun_YuuBlade_FastLightAttack_C = { 1078, 2 }, GA_Hun_YuuBlade_SWT_C = { 0, 2 }, GA_Hun_ZhanMa_AAAA_C = { 565, 3 },
    GA_Hun_ZhanMa_AAAB_C = { 591, 4 }, GA_Hun_ZhanMa_AAA_C = { 555, 3 }, GA_Hun_ZhanMa_AAB_C = { 2199, 4 }, GA_Hun_ZhanMa_AA_C = { 0, 3 },
    GA_Hun_ZhanMa_AB_C = { 696, 2 }, GA_Hun_ZhanMa_A_C = { 1074, 2 }, GA_Hun_ZhanMa_A_DashDraw_C = { 779, 3 },
    GA_Hun_ZhanMa_A_Dash_C = { 500, 2 }, GA_Hun_ZhanMa_A_Draw_C = { 859, 3 }, GA_Hun_ZhanMa_Air_A_C = { 319, 3 },
    GA_Hun_ZhanMa_Air_A_Draw_C = { 319, 3 }, GA_Hun_ZhanMa_Air_B_C = { 356, 3 }, GA_Hun_ZhanMa_Air_B_Draw_C = { 454, 3 },
    GA_Hun_ZhanMa_BB_C = { 1748, 2 }, GA_Hun_ZhanMa_B_C = { 1339, 3 }, GA_Hun_ZhanMa_B_DashDraw_C = { 664, 4 },
    GA_Hun_ZhanMa_B_Dash_C = { 1515, 2 }, GA_Hun_ZhanMa_B_Draw_C = { 1354, 4 }, GA_Hun_ZhanMa_C_C = { 3084, 5 },
    GA_Hun_ZhanMa_DB_C = { 832, 3 }, GA_Hun_ZhanMa_SA_C = { 787, 3 }, GA_Hun_ZhanMa_SWT_C = { 0, 4 },
    GA_Hun_ZiMingJian_New_AAAAA_C = { 773, 3 }, GA_Hun_ZiMingJian_New_AAAA_C = { 773, 3 }, GA_Hun_ZiMingJian_New_AAABB_C = { 1847, 3 },
    GA_Hun_ZiMingJian_New_AAAB_C = { 1197, 3 }, GA_Hun_ZiMingJian_New_AAA_C = { 542, 3 }, GA_Hun_ZiMingJian_New_AABB_C = { 1846, 4 },
    GA_Hun_ZiMingJian_New_AAB_C = { 710, 4 }, GA_Hun_ZiMingJian_New_AA_C = { 646, 2 }, GA_Hun_ZiMingJian_New_ABB_C = { 1154, 2 },
    GA_Hun_ZiMingJian_New_AB_C = { 1112, 2 }, GA_Hun_ZiMingJian_New_A_C = { 1011, 2 }, GA_Hun_ZiMingJian_New_A_DashDraw_C = { 697, 2 },
    GA_Hun_ZiMingJian_New_A_Dash_C = { 697, 2 }, GA_Hun_ZiMingJian_New_A_Draw_C = { 0, 2 }, GA_Hun_ZiMingJian_New_BBB_C = { 686, 2 },
    GA_Hun_ZiMingJian_New_BB_C = { 1355, 2 }, GA_Hun_ZiMingJian_New_B_C = { 697, 2 }, GA_Hun_ZiMingJian_New_B_DashDraw_C = { 981, 2 },
    GA_Hun_ZiMingJian_New_B_Dash_C = { 0, 2 }, GA_Hun_ZiMingJian_New_B_Draw_C = { 697, 2 }, GA_Hun_ZiMingJian_New_CCC_C = { 0, 4 },
    GA_Hun_ZiMingJian_New_CC_C = { 0, 5 }, GA_Hun_ZiMingJian_New_C_C = { 2378, 4 }, GA_Hun_ZiMingJian_New_DB_C = { 0, 3 },
    GA_Hun_ZiMingJian_New_SWT_Power_C = { 0, 4 }, GA_JianKeZhaoJiLing_Normal_01_C = { 0, 4, 1 }, GA_JinGua_Air_C = { 1152, 3, 1 },
    GA_JinGua_ExtraAttack_C = { 1152, 4, 1 }, GA_JinGua_Normal_C = { 1088, 5, 1 }, GA_JinGua_RoAttack_C = { 633, 4, 1 },
    GA_KuYeSiZhuChuan_Normal_01_C = { 0, 4, 1 }, GA_LionHead_C = { 1958, 5, 1 }, GA_LionHead_Dash_C = { 1701, 4, 1 },
    GA_LionHead_DoubleFireBall_C = { 1135, 4, 1 }, GA_LionHead_FireBall_C = { 1485, 3, 1 }, GA_Lute_Dash_C = { 649, 2, 1 },
    GA_MiaoShouFeiDao_DB_C = { 393, 5, 1 }, GA_MiaoShouFeiDao_Escape_01_C = { 38, 1, 1 }, GA_MiaoShouFeiDao_Escape_02_C = { 1959, 2, 1 },
    GA_MiaoShouFeiDao_Escape_03_C = { 371, 1, 1 }, GA_MiaoShouFeiDao_Normal_01_C = { 883, 1, 1 },
    GA_MiaoShouFeiDao_Normal_02_C = { 729, 2, 1 }, GA_MiaoShouFeiDao_Normal_03_C = { 746, 1, 1 }, GA_TanLang_ExtraAttack_C = { 1213, 4, 1 },
    GA_TanLang_Normal_C = { 459, 4, 1 }, GA_TanLang_SpeicalAttack_C = { 1365, 4, 1 }, GA_ThunderSpear_Dash_C = { 1360, 4, 1 },
    GA_ThunderSpear_DeflectCounter_C = { 1299, 2, 1 }, GA_ThunderSpear_DodgeAttack_01_C = { 1666, 3, 1 },
    GA_ThunderSpear_Normal_01_C = { 1986, 3, 1 }, GA_ThunderSpear_Normal_02_C = { 1690, 3, 1 },
    GA_ThunderSpear_Normal_03_C = { 2228, 4, 1 }, GA_ThunderSpear_SpecialAttack_04_C = { 633, 2, 1 },
    GA_TieKuangQuanTao_Charge_AAA_C = { 1224, 3, 1 }, GA_TieKuangQuanTao_Charge_AA_C = { 734, 3, 1 },
    GA_TieKuangQuanTao_Charge_A_C = { 734, 2, 1 }, GA_TigerCannon_C = { 1000, 4, 1 }, GA_TigerCannon_Dash_C = { 969, 3, 1 },
    GA_TigerCannon_Ultimate_C = { 2208, 2, 1 }, GA_UnnamedBow_C = { 1474, 3, 1 }, GA_UnnamedBow_Dash_C = { 336, 4, 1 },
    GA_UnnamedBow_DeflectCounter_C = { 0, 4, 1 }, GA_XuKongHuaShan_Reborn_C = { 0, 4, 1 }, GA_XuKongHuaShan_Skill_C = { 0, 3, 1 },
    GA_XueDiZi_AAA_C = { 0, 5, 1 }, GA_XueDiZi_AA_C = { 1880, 4, 1 }, GA_XueDiZi_A_C = { 920, 5, 1 },
    GA_XueDiZi_EvolutionAttack_C = { 533, 4, 1 }, GA_XueDiZi_SpecialAttack_C = { 136, 4, 1 }, GA_YouLongCha_Dash_C = { 0, 1, 1 },
    GA_YouLongCha_Normal_C = { 1742, 3, 1 }, GA_YouLongHead_WaterCannon_C = { 2121, 4, 1 }, GA_YouLongHead_Water_C = { 505, 4, 1 },
    GA_ZhuoBiDun_C = { 0, 2, 1 }, GA_ZhuoBiDun_Slide_C = { 0, 4, 1 },
}
-- §181 END

function CS.enabled()            -- 这一场采不采：房间设置（开局定下的；武林盟主固定开）+ 对手是真人
    return NET.flagNow("cs") and not NET.rai
end
function CS.word(s) return (tostring(s or ""):gsub("[^%w_,%.%-]", "")) end     -- 只留 [字母数字_,.-]（JSON 里不用转义）
function CS.begin(tn)
    CS.last = nil                -- 上一场没举报：丢
    if not CS.enabled() then CS.cur = nil; return end
    local lb = (NET.rkLobby and NET.rkLobby()) or {}
    local res = MATCH.res or {}
    CS.cur = { t0 = tn, mid = MATCH.id or 0, nm = NET.rnm or "", rounds = 0, fightAt = nil,
               env = { std = NET.flagNow("std") and 1 or 0, bal = NET.flagNow("bal") and 1 or 0, dm = NET.dmgNow(),
                       acc = res.acc or NET.resOf("acc"), accn = res.accn or NET.resOf("accn"), ban = CS.word(res.accban or NET.accBanOf()),
                       rk = NET.rk() and 1 or 0, mode = CS.word(lb.mode), role = CS.word(MATCH.role) },
               c = { hits = 0, std = 0, res = 0, pk = 0, ux = 0, healAmt = 0 },
               d = {}, pend = {}, resP = {}, use = {}, lat = { n = 0, sum = 0, max = 0 }, lost0 = NET.evLost or 0 }
    for _, k in ipairs(CS.CATS) do CS.cur.c[k], CS.cur.d[k] = 0, {} end
end
-- 进对局状态时调（enter）：第 1 回合倒计时开一份；客机从中途跟进来的也开；回自由活动收尾
function CS.onState(s, tn)
    if s == "cd" and MATCH.round == 1 then CS.begin(tn)
    elseif (s == "cd" or s == "fight") and not CS.cur and not (CS.last and CS.last.mid == MATCH.id) then CS.begin(tn) end
    local c = CS.cur
    if not c then return end
    if s == "fight" then c.fightAt, c.rounds, c.attrDue = tn, c.rounds + 1, true
    else c.fightAt = nil; c.stopAt = tn end                  -- §193 回合停了：之前还没结的回报（lo）可能被截断
    if s == "idle" then CS.finish(tn) end
end
-- 接线点（收包 / 状态切换 / 本机判定）都经这里调：采样出错不打断收包、判定、状态切换；每处只记一次日志
function CS.safe(tag, f, ...)
    local ok, e = pcall(f, ...)
    if not ok and not CS.err[tag] then
        CS.err[tag] = true
        out("!! 作弊数据采样 %s 出错（只记这一次，不影响对局）：%s", tag, tostring(e))
    end
end
-- 一条明细"超出阈值几倍"（和服务端 evDetails 同一算法；lo = 标准 ÷ 3 ÷ max(回报, 1)，封顶 LO_CAP，§193）
function CS.score(cat, r)
    local n = function(i) return tonumber(r[i]) or 0 end
    if cat == "big" then return n(4) > 0 and n(3) / n(4) / CS.BIG_X or 0
    elseif cat == "cd" then return n(4) > 0 and n(4) * CS.CD_X / math.max(n(3), 50) or 0
    elseif cat == "heal" then return n(4) > 0 and (n(3) - n(2)) / n(4) / CS.HEAL_MIN or 0
    elseif cat == "sh" then return n(4) > 0 and (n(3) - n(2)) / n(4) / CS.SH_MIN or 0
    elseif cat == "tp" then return n(4) / CS.TP_SPEED
    elseif cat == "attr" then return n(3) > 0 and n(2) / n(3) / CS.ATTR_X or 0
    elseif cat == "lo" then return math.min(CS.LO_CAP, n(4) * CS.LO_X / math.max(n(3), 1)) end
    return 0
end
-- 记一条：可信的计数 + 明细（每类留"超出阈值几倍"最大的 MAXD 条：满了替换最小的）；不可信的只加 ux
function CS.add(c, cat, row, ok)
    if not ok then c.c.ux = c.c.ux + 1; return end
    c.c[cat] = c.c[cat] + 1
    local d = c.d[cat]
    if #d < CS.MAXD then d[#d + 1] = row; return end
    local mi, mw = 1, CS.score(cat, d[1])
    for i = 2, #d do
        local w = CS.score(cat, d[i])
        if w < mw then mi, mw = i, w end
    end
    if CS.score(cat, row) > mw then d[mi] = row end
end
function CS.exp(name, scale)     -- 招表标准伤害 × 当时的系数（采集时影之武装是 ×0.35，除掉）；表里没有 / 没伤害 = nil
    local s = CS.STD[name]
    if not (s and s[1] > 0) then return nil end
    return s[1] * scale / (s[3] == 1 and CS.EDGE_COLL or 1)
end
-- 本机判定：对方的招打中了我（netJudge 里中招那一下）。r 是回报给对方的那条结果，后几段的伤害还会累加进 r.v，过 SETTLE 秒再定
function CS.onHit(name, r, tn)
    local c = CS.cur
    if not (c and r and MATCH.state == "fight") then return end
    c.lastHitAt = tn
    c.pend[#c.pend + 1] = { name = name or "?", r = r, at = tn, rel = tn - c.t0, sc = LO.atkScale or 1, lat = LAT.rtt }
end
function CS.settle(c, tn, all)
    local keep = {}
    for _, h in ipairs(c.pend) do
        if all or tn - h.at >= CS.SETTLE then
            c.c.hits = c.c.hits + 1
            local exp = c.env.std == 1 and CS.exp(h.name, h.sc)      -- 标准数值没开：各人养成不同，不比伤害（§181.5）
            if exp then
                c.c.std = c.c.std + 1
                if h.r.v > exp * CS.BIG_X then CS.add(c, "big", { h.rel, h.name, h.r.v, exp, h.lat }, true) end
            end
        else keep[#keep + 1] = h end
    end
    c.pend = keep
    for id, p in pairs(c.resP) do
        if all or tn - p.at >= CS.SETTLE then
            c.resP[id] = nil
            c.c.res = c.c.res + 1
            local exp = c.env.std == 1 and p.name and CS.exp(p.name, p.sc)
            -- §193 进排名后防误报：这一下之后回合就停了 / 对方倒了（多段被截断）不比；往返没测出来 / > 300 ms 只记 ux
            local cut = c.stopAt and c.stopAt >= p.at
            if exp and p.v < exp * CS.LO_X and not cut then
                CS.add(c, "lo", { p.rel, p.name, p.v, exp, p.lat or -1 }, p.lat ~= nil and p.lat <= CS.LAT_BAD)
            end
        end
    end
end
-- 我的招在对方那边的系数（对方按同一套房间规则算替身攻击力）：伤害倍率 × 武器平衡（开着）/ 影之武装系数
function CS.myScale(name)
    local s = CS.STD[name]
    local edge = s and s[3] == 1
    local f = (BAL.active() and BAL.moveScale(name)) or (edge and CS.EDGE_COLL or 1)
    return NET.dmgNow() / 100 * f
end
-- 对方每个新状态包（NET.recvOne，LAT.onPacket 之后）。evt / list 是 recvOne 已解析好的 evt= / ev=（招式号 → 对方时钟；
-- { id, name } 按号排好），这里只读、不再解析一遍
function CS.onPacket(t, tn, age, evt, list)
    local c = CS.cur
    if c and MATCH.state == "idle" then CS.finish(tn); c = nil end
    if not c then return end
    if c.nm == "" and t.nm then c.nm = t.nm end
    CS.settle(c, tn, false)
    c.c.pk = c.c.pk + 1
    local rtt = LAT.rtt
    if rtt then c.lat.n, c.lat.sum, c.lat.max = c.lat.n + 1, c.lat.sum + rtt, math.max(c.lat.max, rtt) end
    local ok = rtt ~= nil and rtt <= CS.LAT_BAD and (age or 0) * 1000 <= CS.LAT_BAD    -- 还没测出往返：不可信
    local rel = tn - c.t0
    local fight = MATCH.state == "fight"
    -- ② 对方出招：同一招的间隔（对方时钟 evt= 有就用它，没有按收到的时间，后者受延迟影响）
    evt = evt or {}
    for _, e in ipairs(list or {}) do
        if not c.evLast or e.id > c.evLast or e.id < c.evLast - 50 then     -- 号退回很多 = 对方重启 / 换人
            c.evLast, c.lastEv = e.id, e.name
            local at, u, s = evt[e.id] and evt[e.id] / 1000, c.use[e.name], CS.STD[e.name]
            if fight and u and s and s[2] > 0 then
                local exact = at and u.at
                local gap = exact and (at - u.at) or (tn - u.tn)
                if gap >= 0 and gap < s[2] * CS.CD_X then
                    CS.add(c, "cd", { rel, e.name, gap * 1000, s[2] * 1000, rtt }, exact or ok)
                end
            end
            c.use[e.name] = { at = at, tn = tn }
        end
    end
    -- 参考：对方回报我的招（res=）。格挡 / 精防 → 记时间（精防回杀气不算凭空回复）
    for id, atk, kind, v in (t.res or ""):gmatch("(%d+):(%d+):(%a+):([%d%.]+)") do
        id, v = tonumber(id), tonumber(v)
        local p = c.resP[id]
        if p then
            if v > p.v then p.v = v end
        elseif not (c.resMax and id <= c.resMax) then
            c.resMax = math.max(c.resMax or 0, id)
            if kind == "hit" and fight then
                local name = NET.evName and NET.evName[tonumber(atk)]
                c.resP[id] = { name = name, v = v, at = tn, rel = rel, sc = name and CS.myScale(name) or 1, lat = rtt }
            elseif kind ~= "miss" then c.parryAt = tn end
        end
    end
    local mn = tonumber((t.med or ""):match("^(%d+):"))
    if mn and c.medN and mn > c.medN then c.medAt = tn end
    if mn then c.medN = mn end
    local hp, hpm, sh, shm = tonumber(t.hp), tonumber(t.hpm), tonumber(t.sh), tonumber(t.shm)
    if fight and hp and hp <= 0 then c.stopAt = tn end       -- §193 对方倒了：这之前的回报（lo）不比
    local x, y, z, ts = tonumber(t.x), tonumber(t.y), tonumber(t.z), tonumber(t.ts)
    local p = c.prev
    local live = fight and c.fightAt and tn - c.fightAt >= CS.FIGHT_GRACE
    if live and p then
        -- 包隔太久（卡了 / 丢包）：中间可能漏看了喝药 / 吸血，血 / 杀气不比（当 excused）
        local excused = (c.medAt and tn - c.medAt < CS.MED_WIN) or (c.lastHitAt and tn - c.lastHitAt < CS.HIT_WIN)
                        or tn - p.tn > CS.RES_DT
        -- ③ 血：没喝药、没刚打中我（斩马刀吸血 / 处决回血）时往上跳
        if hp and p.hp and hp > 0 and p.hp > 0 and hpm and hpm > 0 and not excused then
            local up = hp - p.hp
            if up >= math.max(hpm * CS.HEAL_MIN, CS.HEAL_ABS) then
                c.c.healAmt = c.c.healAmt + up
                CS.add(c, "heal", { rel, p.hp, hp, hpm, rtt }, true)
            end
        end
        -- ③ 杀气（对方关了杀气显示时 sh=-1，不比）
        if sh and p.sh and sh >= 0 and p.sh >= 0 and shm and shm > 0 and sh - p.sh > shm * CS.SH_MIN
           and not excused and not (c.parryAt and tn - c.parryAt < CS.PARRY_WIN) then
            CS.add(c, "sh", { rel, p.sh, sh, shm, rtt }, true)
        end
        -- ④ 位移：相邻两包（对方时钟 ts= 算间隔，旧版没有就按收到的时间）
        if x and p.x and t.map == p.map then
            local dt = (ts and p.ts) and (ts - p.ts) / 1000 or (tn - p.tn)
            if dt > 0.02 and dt <= CS.TP_DT then
                local dist = math.sqrt((x - p.x) ^ 2 + (y - p.y) ^ 2 + (z - p.z) ^ 2)
                if dist > CS.TP_DIST and dist / dt > CS.TP_SPEED then
                    CS.add(c, "tp", { rel, dist, dt * 1000, dist / dt, rtt or -1, c.lastEv or "-" }, ok)
                end
            end
        end
    end
    -- ⑤ 属性：每回合开打后第一次比（标准数值开着才比；对方旧版没有 att= / shm= 的项不比）
    if live and c.attrDue then
        c.attrDue = false
        if c.env.std == 1 then
            local vals, n = { Health_Max = hpm, Shachi_Max = shm }, 0
            for k, v in (t.att or ""):gmatch("([%w_]+):([%-%d%.e+]+)") do
                if k == "Attack" or k == "ShachiAttack" then vals[k] = tonumber(v) end
            end
            for _, a in ipairs(CS.ATTR) do
                local v, s = vals[a], STD.ATTR[a]
                if v and s and v > s * CS.ATTR_X then
                    n = n + 1
                    local seen = false
                    for _, d in ipairs(c.d.attr) do if d[1] == a then seen = true; if v > d[2] then d[2] = v end end end
                    if not seen and #c.d.attr < CS.MAXD then c.d.attr[#c.d.attr + 1] = { a, v, s } end
                end
            end
            if n > c.c.attr then c.c.attr = n end           -- 计数 = 哪一回合超标的项数最多
        end
    end
    c.prev = { hp = hp, sh = sh, x = x, y = y, z = z, ts = ts, tn = tn, map = t.map }
end
function CS.finish(tn)
    local c = CS.cur
    if not c then return end
    CS.settle(c, tn, true)
    c.dur, c.endAt, c.score = tn - c.t0, tn, string.format("%d-%d", MATCH.me or 0, MATCH.op or 0)
    CS.cur, CS.last = nil, c
end
-- 摘要 → 一行 JSON（只有数字和 [%w_,-] 的字串，不带昵称 / IP / 地图坐标；明细 maxd 条一类）
function CS.num(v)
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return "null" end
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
    return string.format("%.1f", v)
end
function CS.val(v)
    if type(v) == "string" then return '"' .. CS.word(v) .. '"' end
    if type(v) == "table" then
        local p = {}
        for i = 1, #v do p[i] = CS.val(v[i]) end
        return "[" .. table.concat(p, ",") .. "]"
    end
    return CS.num(v)
end
function CS.json(c, maxd)
    local e, cc = c.env, c.c
    local lat = c.lat.n > 0 and c.lat.sum / c.lat.n or nil
    local env = string.format('{"std":%s,"bal":%s,"dm":%s,"acc":%s,"accn":%s,"ban":%s,"rk":%s,"mode":%s,"role":%s,"lat":%s,"latMax":%s,"lost":%s}',
        CS.num(e.std), CS.num(e.bal), CS.num(e.dm), CS.num(e.acc), CS.num(e.accn), CS.val(e.ban), CS.num(e.rk), CS.val(e.mode), CS.val(e.role),
        CS.num(lat and math.floor(lat + 0.5)), CS.num(c.lat.max), CS.num((NET.evLost or 0) - (c.lost0 or 0)))
    local cnt = { "hits", "std", "res", "pk", "ux", "healAmt" }
    for _, k in ipairs(CS.CATS) do cnt[#cnt + 1] = k end
    local cp, dp = {}, {}
    for _, k in ipairs(cnt) do cp[#cp + 1] = '"' .. k .. '":' .. CS.num(cc[k] or 0) end
    for _, k in ipairs(CS.CATS) do
        local rows = {}
        for i = 1, math.min(maxd, #c.d[k]) do rows[i] = CS.val(c.d[k][i]) end
        dp[#dp + 1] = '"' .. k .. '":[' .. table.concat(rows, ",") .. "]"
    end
    return string.format('{"v":2,"mv":%s,"mid":%s,"r":%s,"dur":%s,"sc":%s,"env":%s,"c":{%s},"d":{%s}}',
        CS.val(VERSION), CS.num(c.mid), CS.num(c.rounds), CS.num(math.floor((c.dur or (now() - c.t0)) + 0.5)), CS.val(c.score or "-"),
        env, table.concat(cp, ","), table.concat(dp, ","))
end
function CS.text(c)              -- 超过 MAX_BYTES 就少带明细（10 → 5 → 2 → 0 条一类；按"超出阈值几倍"从大到小取）
    for _, k in ipairs(CS.CATS) do
        table.sort(c.d[k], function(a, b) return CS.score(k, a) > CS.score(k, b) end)
    end
    for _, m in ipairs({ CS.MAXD, 5, 2, 0 }) do
        local s = CS.json(c, m)
        if #s <= CS.MAX_BYTES then return s end
    end
    return nil
end
-- 面板"提交举报"：这个对手（按昵称认；昵称没收到时只认第 1 个对手）当前这场 / 最近一场的摘要 → 命令多一行 ev=；没有 = ""
function CS.forReport(nick, idx, tn)
    local function ofThis(c) return c and (c.nm == nick or (c.nm == "" and idx == 1)) end
    local c = CS.cur
    if ofThis(c) then CS.settle(c, tn, false)
    else
        c = CS.last
        if not (ofThis(c) and tn - (c.endAt or tn) <= CS.KEEP) then return "" end
    end
    local s = CS.text(c)
    if not s then return "" end
    out("作弊数据采样：举报附带本场摘要 %d 字节（对局 #%s）", #s, tostring(c.mid))
    return "ev=" .. s .. "\n"
end

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
    TOUCH.watchHp(pup, now())      -- §107
    local m = rawProp(pup, "Mesh")
    if not valid(m) then return end
    local okA, an = pcall(function() return m:GetAnimInstance() end)
    if not (okA and valid(an)) then return end
    local okM, mt = pcall(function() return an:GetCurrentActiveMontage() end)
    if not (okM and valid(mt)) then return end
    local name = shortName(full(mt)) or ""
    if name == ST.pupOwnName and (ST.pupOwnFrames or 0) > 0 then return end
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
            -- §104 受击 = 我的刀在本机碰到替身：按对手历史先播格挡 / 留着受击（破防类照旧一律掐掉，只听对方的 brk=）
            if k == "_Hit_" then TOUCH.mark(now()) end      -- §107 碰到了（AI 对战据此回报）
            if k == "_Hit_" and PRED.onContact(pup, an, mt, name, now()) then return end
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

-- 让 actor（拿着 weaponId）做"被弹开"的硬直；返回一句描述
local function staggerOn(actor, weaponId)
    local name = staggerNameFor(weaponId)
    return "硬直 " .. name .. "（武器 " .. tostring(weaponId) .. "）" .. (playNamed(actor, name) and "已播" or "失败")
end

-- 连续精防计数。两边按同一串判定结果各自数，所以攻击方本人和防守方屏幕上的替身在同一刀上触发。
-- 被砍中 / 普通防御 / 落空 / 距上次精防超过 STREAK_RESET 秒 → 清零；数到 3 → 触发并清零
local STREAK_NEED, STREAK_RESET = 3, 6.0

local function bumpStreak(side, kind, tn)
    NET.streak = NET.streak or {}
    local s = NET.streak[side] or { n = 0, at = -100 }
    NET.streak[side] = s
    if kind ~= "parry" or tn - s.at > STREAK_RESET then s.n = 0 end
    if kind ~= "parry" then return false, 0 end
    s.n, s.at = s.n + 1, tn
    if s.n >= STREAK_NEED then s.n = 0; return true, STREAK_NEED end
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
    NET.resId = NET.resId + 1
    NET.results[#NET.results + 1] = { id = NET.resId, atk = attackId, kind = kind, v = value or 0, at = tn }
    NET.judged[kind] = (NET.judged[kind] or 0) + 1
    out("判定 远端#%d → %s%s%s", attackId, RES_NAME[kind] or kind,
        (value or 0) > 0 and string.format(" -%.0f", value) or "", (value or 0) > 0 and NET.pupAtkNote() or "")
    return NET.results[#NET.results]
end

local function openJudge(p1, attackId, tn, name)
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
    local kind = pd.drop <= -BLOCK_DROP and "block" or "parry"
    addResult(kind, pd.j.id, 0, tn)
    local fire, n = bumpStreak("def", kind, tn)
    out("  分类依据：动作 %s，杀气最大单步 %+.0f / 最大单步下降 %+.0f → %s%s", pd.m, pd.jump, pd.drop,
        RES_NAME[kind], kind == "parry" and string.format("（连续第 %d 次）", fire and STREAK_NEED or n) or "")
    if fire then
        -- 我连续精防对方 3 次：我屏幕上的替身吃硬直。对方机器上它的真身收到同样 3 个 parry 后自己吃
        out("  替身被连续精防 %d 次 → %s", STREAK_NEED, staggerOn(puppet(), ST.pupWeapon))
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

-- 我现在算不算在格挡：返回依据（nil = 不在）。m = 我这一帧的动作名，act = 我挂着的招式技能（NET.prevAbs）
-- StanceExit = 松开格挡（收架势），不算（§90.1：松开那一下被打中以前被当成格挡中）
function BLK.guarding(m, act)
    if m and m:find("StanceExit", 1, true) then return nil end
    if m and (m:find("Deflect", 1, true) or m:find("Stance", 1, true)) then return "动作 " .. m end
    for n in pairs(act or {}) do
        if n:find("Stance", 1, true) or n:find("Deflect", 1, true) then return "技能 " .. n end
    end
    return nil
end

-- 每帧（netSend 发包时、netJudge 有判定窗口时）：记"开始格挡"和"最后一次在格挡"的时刻。只看已经读到的动作名 / 技能表，不调游戏
-- 受击动作那一帧不改判断：挨打这一帧架势技能已经被结束了，要看的是挨打之前在不在格挡
function BLK.watch(m, act, tn)
    if LO.isHitMontage(m) then return end
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
    if not (MATCH.ab and MATCH.state == "fight") then return false, "没开" end
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
    if m and m:find("Deflect", 1, true) then return "已经是格挡动作 " .. m end
    if not LO.isHitMontage(m) then return "画面上没在受击（" .. ((m and m ~= "") and m or "架势") .. "），不播" end
    local a, ok = BLK.swap(p1, m, tn)
    if not a then return "刚换过" end
    return string.format("受击 %s → 播 %s %s", m, a, ok and "已播" or "失败")
end

-- 每帧（LoopInGameThreadAfterFrames）：可能软格挡时读一次玩家动作，是受击就换成格挡动作。
-- 条件同软格挡（设置开着、交手中、在格挡、没破防、杀气够），再加：判定窗口开着（抢先，不等 netJudge 看到掉血），
-- 或软格挡后 COVER 秒内（同一招后几段）。条件不满足时一个游戏函数都不调
function BLK.frame()
    if not (MATCH.ab and MATCH.state == "fight") then return end
    local tn = now()
    local after = tn < BLK.coverUntil
    if not after and #NET.judges == 0 then return end
    if not BLK.on or tn - BLK.at > BLK.GRACE then return end
    if (NET.prevAbs and NET.prevAbs["GA_Hun_BreakEscape_C"]) or tn - (NET.brkAt or -100) < BLK.BRK_HOLD then return end
    if (NET.prevSh or 0) <= 0 then return end
    local p1 = getP1()
    if not valid(p1) then return end
    local m = montageOf(p1)
    if not LO.isHitMontage(m) then return end
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
    local fire, n = bumpStreak("def", kind, tn)
    out("全部可格挡：远端#%d %s%s 格挡中掉血 -%.0f → 软%s（开始格挡 %.2f 秒后挨打%s，补回血，%s），%s（第 %d 次）",
        j.id, j.name or "?", BLK.ultra(j.name), dmg, kind == "parry" and "精防" or "格挡（普防）", since,
        kind == "parry" and string.format("，连续第 %d 次精防", fire and STREAK_NEED or n) or "",
        shTxt, cv, BLK.soft)
    if fire then out("  替身被连续精防 %d 次 → %s", STREAK_NEED, staggerOn(puppet(), ST.pupWeapon)) end
    return r
end

local function netJudge(p1, tn)
    while #NET.results > 0 and tn - NET.results[1].at > RES_KEEP do table.remove(NET.results, 1) end
    local shNow = attrOf(p1, "Shachi")
    local shPrev = NET.prevSh
    NET.prevSh = shNow
    CAP.flush(NET.lastHit and NET.lastHit.r)          -- §199.9 被吃过跳伤的招结束了 → 记合计
    if #NET.judges == 0 and not NET.pendDef and not NET.lastHit then return end
    local hp = hpOf(p1)
    local m = montageOf(p1)
    -- §155 回过血（回合开始补满 / 喝药）→ 上一招的多段累加到此为止；倒地动作里掉的血（摔死 / 锁血钳住）不算任何一招打的
    if hp and NET.judgeHp and hp > NET.judgeHp + 0.5 then NET.lastHit = nil end
    if m:find("_Dead", 1, true) then NET.judgeHp = hp; NET.lastHit = nil; return end
    local newDeflect = m:find("Deflect") ~= nil and m ~= NET.judgeMontage   -- 只认"刚切到格挡动画"那一帧
    local mPrev = NET.judgeMontage
    NET.judgeMontage = m
    if #NET.judges > 0 then BLK.track(m, tn) end      -- §87 记最后一次在格挡的时刻
    -- 掉血 / 格挡都记给最近开的那个窗口（连招时前一刀的窗口继续等）。中招立即回报；格挡先观察 DEF_OBSERVE 秒分类
    if #NET.judges > 0 and hp and NET.judgeHp and hp < NET.judgeHp - 0.5 then
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
            local capped = not gun and CAP.fix(p1, j.name, NET.judgeHp - hp, NET.judgeHp - hp, NET.judgeHp, tn)   -- §197 一招总伤害上限
            if capped then hp = NET.judgeHp - capped end
            NET.lastHit = { r = addResult("hit", j.id, NET.judgeHp - hp, tn), at = tn, name = j.name }
            CS.safe("onHit", CS.onHit, j.name, NET.lastHit.r, tn)   -- §181 作弊数据采样：后几段还会累加进这条，过几秒再和招表比（出错不打断判定）
            if capped then NET.lastHit.r.capped, NET.lastHit.r.capName = true, j.name end   -- §199.9 后面的段 / 跳伤按 1 倍门槛
            LAT.learnFrom(j.id, "中招", tn)       -- v0.27.0 追帧：从实际中招学前摇
        end
    elseif #NET.judges == 0 and NET.lastHit and NET.lastHit.soft and hp and NET.judgeHp and hp < NET.judgeHp - 0.5 then
        -- §87 软格挡的那一招后面几段：同样补回去
        out("全部可格挡：远端#%d 后续一段 -%.0f → 补回，%s", NET.lastHit.r.atk, NET.judgeHp - hp, BLK.cover(p1, m, tn))
        setAttr(p1, "Health", NET.judgeHp)
        hp = NET.judgeHp
        NET.lastHit.at = tn
    elseif #NET.judges == 0 and NET.lastHit and hp and NET.judgeHp and hp < NET.judgeHp - 0.5 then
        -- v0.17.3：多段招式（例：绝影 AA 两段相隔约 0.4 秒）的后几段。中招已经立即回报过（攻击方要马上播受击），
        -- 这里把后面的掉血累加进同一条结果；结果还在重发期内，对方会看到数值变大
        local r = NET.lastHit.r
        local gun = GDMG.fix(p1, r.atk, NET.lastHit.name, NET.judgeHp - hp, NET.judgeHp, tn)   -- §212
        if gun then hp = NET.judgeHp - gun end
        local capped = not gun and CAP.fix(p1, NET.lastHit.name, NET.judgeHp - hp, r.v + (NET.judgeHp - hp), NET.judgeHp, tn, r)   -- §197
        if capped then hp = NET.judgeHp - capped end
        r.v = r.v + (NET.judgeHp - hp)
        if not (capped and capped < 0.5) then          -- §199.9 整跳吃掉的不再记"追加 -0"，合计见 CAP.flush
            out("判定 远端#%d → 中招 追加 -%.0f（这招累计 -%.0f）%s", r.atk, NET.judgeHp - hp, r.v, NET.pupAtkNote())
        end
        NET.lastHit.at = tn        -- v0.27.1 从最后一段算起：炽刃大招十几段、拖 1.8 秒，从第一段算会把后面的段漏掉
    elseif #NET.judges > 0 and newDeflect then
        if NET.pendDef then finishDeflect(p1, tn) end
        local j = table.remove(NET.judges)
        LAT.learnFrom(j.id, "格挡", tn)       -- v0.27.0 追帧：从实际格挡学前摇
        BLK.onBlock(j, m)                     -- §87 格挡探针（对照）
        -- 基准用上一帧的杀气：日志里跳涨常和格挡动作出现在同一帧，用本帧当基准会把跳涨吃掉
        NET.pendDef = { j = j, at = tn, m = m, lastSh = shPrev or shNow or 0, jump = 0, drop = 0 }
    end
    local pd = NET.pendDef
    if pd then
        local sh = shNow or pd.lastSh
        local d = sh - pd.lastSh
        if d > pd.jump then pd.jump = d end
        if d < pd.drop then pd.drop = d end
        pd.lastSh = sh
        if tn - pd.at >= DEF_OBSERVE then finishDeflect(p1, tn) end
    end
    NET.judgeHp = hp
    if NET.lastHit and tn - NET.lastHit.at > JUDGE_WIN then NET.lastHit = nil end
    local keep, pupM = {}, nil
    for _, j in ipairs(NET.judges) do
        if tn - j.at > JUDGE_WIN then
            -- v0.27.1 替身还在播这一招的动作（大招蓄力）→ 接着等，最多 LAT.JUDGE_MAX 秒
            pupM = pupM or select(3, LAT.activeMontage(puppet())) or ""
            if LAT.stillPlaying(j.id, tn - j.at, pupM) or CHG.keepJudge(j, tn, pupM) then keep[#keep + 1] = j   -- §92 蓄力招等松手
            else addResult("miss", j.id, 0, tn) end
        else keep[#keep + 1] = j end
    end
    NET.judges = keep
end

local function applyRemoteResult(p1, r)
    local kind = r.kind == "deflect" and "parry" or r.kind     -- v0.9.x 的 deflect 当精防
    local tn = now()
    local fire, n = bumpStreak("atk", kind, tn)
    -- §104 先和接触时的预测对账：pr.skip = 预测对了、替身已经在播（不重播）；pr.seek = 纠正时从第几秒播起（追帧）
    local pr = PRED.onResult(r, kind, tn)
    if kind == "parry" or kind == "block" then
        -- 我屏幕上代表对方的替身播格挡动作；只有连续第 3 次精防我才吃硬直，其余可以继续打
        local me = fire and STG.start(p1, ST.p1Weapon, tn) or "继续攻击"     -- §161 硬直期间锁出招
        local pupTxt
        if pr.skip then
            pupTxt = "替身已经预播了格挡 " .. tostring(pr.m) .. "（预测对了）"
        else
            -- §104 优先级：对方已经出了下一招（替身在出招）/ 受击 / 破防时不播格挡——格挡动作会盖掉出招动作，招却还挂着
            local busy = PRED.busy(puppet(), tn)
            if busy then
                pupTxt = "替身" .. busy .. "，不播格挡"
            else
                NET.defIdx = (NET.defIdx or 0) % #DEFLECT_ANIMS + 1
                local okPup = playNamed(puppet(), DEFLECT_ANIMS[NET.defIdx])
                pupTxt = string.format("替身格挡 %s（%s%s）", DEFLECT_ANIMS[NET.defIdx], okPup and "已播" or "失败",
                    okPup and PRED.seek(puppet(), pr.seek) or "")
            end
        end
        out("◆ 你的第 #%d 招被对方%s%s → 你%s，%s", r.atk, RES_NAME[kind],
            kind == "parry" and string.format("（连续第 %d 次）", fire and STREAK_NEED or n) or "", me, pupTxt)
    elseif r.kind == "hit" and NET.lastHrAt and tn - NET.lastHrAt < 0.6 then
        -- v0.17.11：对方的受击状态（hr=）已经同步到替身，用它，不再播固定的中等受击
        out("◆ 你的第 #%d 招命中对方 -%.0f → 替身受击按对方状态 %s", r.atk, r.v, tostring(NET.lastHrTag))
    elseif r.kind == "hit" then
        -- v0.23.1 攻击优先（用户 2026-11-04）：替身正在出招时不播受击。受击动画盖住出招动画，招式本身却没停，
        -- 22:44:16 替身"在受击里"一刀砍中玩家。对方真被打断的话，对方游戏会发 hr=，在那里停招（见下面 hr 段）
        local busy = puppetAttacking(puppet())
        if busy then
            out("◆ 你的第 #%d 招命中对方 -%.0f → 替身正在出招 %s，不播受击（攻击优先）", r.atk, r.v, busy)
        elseif pr.skip then
            out("◆ 你的第 #%d 招命中对方 -%.0f → 替身已经在播本机受击 %s（预测对了）", r.atk, r.v, tostring(pr.m))
        else
            NET.hitSide = NET.hitSide == "R" and "L" or "R"
            local hn = hitNameFor(ST.pupWeapon, NET.hitSide)
            local okH = playNamed(puppet(), hn)
            out("◆ 你的第 #%d 招命中对方 -%.0f → 替身受击 %s（%s%s）", r.atk, r.v, tostring(hn),
                okH and "已播" or "失败", okH and PRED.seek(puppet(), pr.seek) or "")
        end
        LO.zmHeal(p1, r.atk, r.v)
    else
        out("◆ 你的第 #%d 招落空%s", r.atk, pr.note or "")
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
         PRIOR = { g = { 3.0, 1.0 }, n = { 0.5, 2.5 } },     -- { 防住, 中招 } 的初始计数：g = 格挡中，n = 没在格挡
         b = nil, pend = nil,
         st = { contact = 0, busy = 0, preDef = 0, preHit = 0, wait = 0, right = 0, wrong = 0, fix = 0, undo = 0, nores = 0 } }

function PRED.reset()
    PRED.b = { g = { PRED.PRIOR.g[1], PRED.PRIOR.g[2] }, n = { PRED.PRIOR.n[1], PRED.PRIOR.n[2] } }
    PRED.pend = nil
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
TOUCH = { ids = {}, dmg = {}, KEEP = 2.0, n = 0 }
function TOUCH.mark(tn, d)
    local id = PRED.myAttackId()
    if id <= 0 then return end
    if not TOUCH.ids[id] then TOUCH.n = TOUCH.n + 1 end
    TOUCH.ids[id] = tn
    if d and d > 0 and TOUCH.counts() then
        local add = d * TOUCH.scale(id)
        local gun = GDMG.mine(id, d, tn)                 -- §212 我的火枪打本地 AI：这一下按每发的数报
        if gun and gun < add then add = gun end
        TOUCH.dmg[id] = (TOUCH.dmg[id] or 0) + add
    end
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
    if BAL.active() then return NET.atkScale(false) * (BAL.moveScale((NET.evBal and NET.evBal[id]) or n)) end   -- §186.3
    return NET.atkScale(LO.isEdgeAttack(n))
end
function TOUCH.wire(tn)
    local out_ = {}
    for id, at in pairs(TOUCH.ids) do
        if tn - at < TOUCH.KEEP then out_[#out_ + 1] = tostring(id) else TOUCH.ids[id], TOUCH.dmg[id] = nil, nil end
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
    local h = hpOf(pup)
    if h and ST.pupHpSeen and h < ST.pupHpSeen - 0.5 then TOUCH.mark(tn, ST.pupHpSeen - h) end
    ST.pupHpSeen = h
    TOUCH.headStep(pup, tn, h)
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
    if TOUCH.isBig(n) then TOUCH.bigAt = tn end
end
-- 现在替身本机该多加多少血（0 = 不加）
function TOUCH.head(tn)
    if not (NET.rai and NET.driving and TOUCH.bigAt and tn - TOUCH.bigAt < TOUCH.BIG_SEC) then return 0 end
    if not (NET.remoteHp and NET.remoteHp > 0 and NET.remoteHpm and NET.remoteHpm > 0) then return 0 end
    if not TOUCH.counts() then return 0 end
    return TOUCH.HEAD
end
function TOUCH.localHp(v) return v + (TOUCH.headNow or 0) end      -- 对方回报的血量 → 替身本机该写的
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
        setAttr(pup, "Health", hp > 0 and hp or 1)
        setAttr(pup, "Health_Max", hm)
        setAttr(pup, "Health", hp > 0 and hp or 1)    -- 先降上限会被钳到上限，再写一次
    end
    TOUCH.headNow = want
    ST.pupHpSeen = hpOf(pup)
    TOUCH.headLogs = (TOUCH.headLogs or 0) + 1
    if TOUCH.headLogs <= 20 then
        out("§207 本地 AI：替身本机血量%s（现在 %s）", want > 0 and string.format("临时 +%d，L1+圈 掉血不被剩血截住", want) or "撤回临时加的那份",
            ST.pupHpSeen and string.format("%.0f", ST.pupHpSeen) or "?")
    end
end

function PRED.log(fmt, ...)
    PRED.logs = PRED.logs + 1
    if PRED.logs <= PRED.LOGS or PRED.logs % 25 == 0 then out(fmt, ...) end
end

-- suppressLocalReact 看到本机游戏给替身播受击（= 我的刀在本机碰到替身）时调。
-- 返回 true = 已处理（播了预测的格挡，或留着本机受击），调用方不再掐；false = 照旧掐掉
function PRED.onContact(pup, an, mt, name, tn)
    if not PRED.on then return false end
    local st = PRED.st
    st.contact = st.contact + 1
    local busy = PRED.busy(pup, tn)
    if busy then st.busy = st.busy + 1; return false end
    local g = PRED.guarding(tn)
    local p = PRED.prob(g)
    local atk = PRED.myAttackId()
    local kind = p >= PRED.DEF_TH and "deflect" or ((p <= PRED.HIT_TH and PRED.LOCAL_HIT) and "hit" or "wait")
    PRED.pend = { kind = kind, at = tn, g = g, p = p, atk = atk, m = name }
    if kind == "deflect" then
        pcall(function() an:Montage_Stop(0.0, mt) end)
        NET.defIdx = (NET.defIdx or 0) % #DEFLECT_ANIMS + 1
        local a = DEFLECT_ANIMS[NET.defIdx]
        local ok = playNamed(pup, a)
        PRED.pend.m = ok and a or nil
        st.preDef = st.preDef + 1
        PRED.log("预测：我第 #%d 招碰到替身，对方%s格挡、历史防住 %.0f%% → 先播格挡 %s（%s）", atk, g and "在" or "没在", p * 100, a,
            ok and "已播" or "失败")
        return true
    elseif kind == "hit" then
        ST.pupOwnName, ST.pupOwnFrames = name, PRED.KEEP_FRAMES     -- 本机游戏的受击留着（suppressLocalReact 认模组自己播的）
        st.preHit = st.preHit + 1
        PRED.log("预测：我第 #%d 招碰到替身，对方%s格挡、历史防住 %.0f%% → 留着本机受击 %s", atk, g and "在" or "没在", p * 100, name)
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
    local p = PRED.pend
    if p and tn - p.at > PRED.WAIT then PRED.pend, p = nil, nil; PRED.st.nores = PRED.st.nores + 1 end
    if p and r.atk ~= p.atk then
        -- 不是碰到的那一招：更早的招只学不动画面；更新的招（本机没碰到）当没有预测
        if r.atk < p.atk then
            if kind ~= "miss" then PRED.learn(PRED.guarding(tn), isDef) end
            return res
        end
        p = nil
    end
    if kind ~= "miss" then PRED.learn(p and p.g or PRED.guarding(tn), isDef) end
    if not p then return res end
    PRED.pend = nil
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
    -- 猜错（或没猜）：停掉预播的，实际动作从碰到之后过了多久那一秒播起
    if still and p.kind ~= "wait" then cutMontage(pup) end
    if p.kind ~= "wait" then st.fix = st.fix + 1 end
    res.seek = tn - p.at
    if p.kind ~= "wait" then
        PRED.log("预测错了：我第 #%d 招 猜%s、实际%s（防住概率 %.0f%%）→ 停掉 %s，改播实际动作", r.atk,
            p.kind == "deflect" and "格挡" or "中招", RES_NAME[kind] or kind, p.p * 100, tostring(still and p.m or "（已经换掉了）"))
    end
    return res
end

-- ============================================================ §105.3 房间设置"红蓝光反击：关"时不出完美闪避反击
-- 机制见 HANDOVER §105：没有哪个 GameplayTag 打开它（红 / 蓝是攻击方子弹动作里的 C++ 开关，PBZDeflectSystem），本机常驻被动
--   BP_PerfectDodgePassive 收到闪避帧后按标签 Ability.Action.Hun.PerfectDodge 激活反击；"精防后再按闪避"、木剑升级两条路也出同一类。
--   Lua 改不了子弹 / C++ 判定、传 GameplayTagContainer 会崩（§19.20），所以设置为关时在本机拦反击技能本身：
--   交手中我身上新出现 *PerfectDodge* 技能 → 立刻 K2_CancelAbility，也不发给对方。闪避本身（Dash、GE_PerfectDash 无敌）不受影响。
-- 设置为开（默认）= 原版，什么都不做。不拦：GA_Hun_Long_Counter* / Horizontal_CounterAttack*（普通连段）；影之武装的 *DeflectCounter
NOCTR = { on = true, n = 0, LOGS = 20 }
function NOCTR.is(name) return name:match("^GA_Hun_.*PerfectDodge") ~= nil end
function NOCTR.active() return NOCTR.on and MATCH.state == "fight" and not NET.flagNow("ctr") end
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

-- ============================================================ §161 连续 3 次被精防的硬直锁住出招
-- 以前硬直只是给我 PlayAnimMontage 一段 C_Failed，不挂标签、不拦技能：硬直中按攻击，攻击技能的动作直接把它顶掉（用户 2026-11-08）。
-- 现在：硬直开始后 untilT 之前（= 硬直动作时长，读不到用 DEF，最多 MAX 秒），我身上新出现的攻击技能（isAttackAbility，
--   含影之武装 / 完美闪避反击）→ 立刻 K2_CancelAbility、不发给对方，硬直动作被顶掉的话重播并跳回原来播到的位置。
--   被打中（当前是受击动作）就不重播，受击优先；离开交手阶段不拦。闪避 / 格挡不拦（原版被弹开能不能闪还没核对）
STG = { DEF = 1.0, MAX = 2.0, untilT = nil, at = 0, name = nil, n = 0, LOGS = 20 }
function STG.active(tn) return STG.untilT ~= nil and tn < STG.untilT and MATCH.state == "fight" end
-- 第 3 次精防触发时调（代替 staggerOn）：播硬直、记锁定到什么时候；返回日志里的一句
function STG.start(p1, weaponId, tn)
    local name = staggerNameFor(weaponId)
    local asset = montageByName(name)
    local dur = asset and valid(p1) and playOn(p1, asset)
    STG.name, STG.at = dur and name or nil, tn
    STG.untilT = dur and tn + math.min(dur, STG.MAX) or nil
    return string.format("硬直 %s（武器 %s）%s", name, tostring(weaponId),
        dur and string.format("已播，%.2f 秒内锁出招", math.min(dur, STG.MAX)) or "失败")
end
-- netSend 看到我新出现的技能时调：拦了返回 true（调用方不发这招）
function STG.check(p1, name, tn)
    if not (STG.active(tn) and isAttackAbility(name)) then return false end
    local gone = G.cancelAbilities(p1, isAttackAbility)
    local m = montageOf(p1)
    local back = ""
    if m ~= STG.name and not LO.isHitMontage(m) then
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

-- ============================================================ §173.7 倒计时只能移动、不能出招
-- 找过游戏自带的"禁攻击"（HANDOVER §173.7）：玩家攻击技能都继承 BP_ActionAbilityBase（技能标签 Ability.Action），但没有哪个 GE 用
-- BlockAbilityTagsGameplayEffectComponent（3068 个 GE_ 全扫过），ASC.BlockAbilitiesWithTags 不是蓝图函数、Lua 调不到；对话的
-- GE_StartDialogue 只给 CharacterState.NarrativeDialogue，攻击技能的资产里没有引用它。所以走 §161 那条已实测的路：
-- 倒计时里我身上新出现的攻击技能（isAttackAbility，含影之武装、大招、完美闪避反击）→ 立刻 K2_CancelAbility、不发给对方。
-- 不拦：移动 / 跳跃 / 闪避冲刺（Dash 类、Dodge）/ 架势格挡 / 喝药 / 切武器。状态一离开 cd 就不拦，没有要撤的东西（掉线 / 中止也一样）。
-- 大招 / 影之武装放出来的那一下可能已经扣了精纯杀气 / 暗源：倒计时开始记下，拦掉后少了就写回去
CDL = { n = 0, pn = 0, LOGS = 20, res = nil }
function CDL.active() return MATCH.role ~= nil and MATCH.state == "cd" end
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
    if not (CDL.fightAt and MATCH.state == "fight") then return false end
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
    local gone = G.cancelAbilities(p1, isAttackAbility)
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

-- ============================================================ §108 房间设置"血瓶：关"时交手中不能喝药
-- 喝药 = 本机玩家开始播 AM_Hun_Medicine_*（§103 同一个判断）；喝药技能 GA_Medicine_* 不在发包看的技能里。回血是开始喝后
-- 约 1 秒内分几跳到（2026-11-05 22:44:50 日志：+15 / +46 交替），可能在我们看到动作前就到了一跳。所以关的时候：
--   ① 动作一出现就停掉、取消喝药技能（名字 ^GA_Medicine_ 且不是 Passive）；② HOLD 秒内血量只许降不许升（升了写回去）；
--   ③ 不发 med=（对方替身不播喝药）。代价：药瓶次数可能已经扣了；HOLD 秒内别的回血（斩马刀吸血补偿等）也被压住
NOMED = { HOLD = 6.0, untilT = nil, cap = nil, n = 0 }
function NOMED.active() return MATCH.state == "fight" and not NET.flagNow("med") end
function NOMED.isDrink(name) return name:match("^GA_Medicine_") ~= nil and not name:find("Passive", 1, true) end
-- netSend 看到我开始播喝药动作时调：拦了返回 true（调用方不发 med=）
function NOMED.block(p1, hm, tn)
    if not NOMED.active() then return false end
    local cut = cutMontage(p1)
    local gone = G.cancelAbilities(p1, NOMED.isDrink)
    NOMED.untilT, NOMED.cap = tn + NOMED.HOLD, hpOf(p1)
    NOMED.n = NOMED.n + 1
    out("血瓶已禁用：%s → 动作%s，%s，%d 秒内不回血（第 %d 次）", hm, cut and "已停" or "没停到",
        #gone > 0 and ("已取消 " .. table.concat(gone, ",")) or "没取消到喝药技能", NOMED.HOLD, NOMED.n)
    return true
end
-- 每次发包：HOLD 秒内血量升了就写回上限（降了就跟着降）
function NOMED.frame(p1, tn)
    if not NOMED.untilT then return end
    if tn >= NOMED.untilT or MATCH.state ~= "fight" then NOMED.untilT, NOMED.cap = nil, nil; return end
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
    out("      预测：碰到 %d 次（替身忙 %d），先播格挡 %d / 留受击 %d / 等结果 %d；猜对 %d 猜错 %d（纠正 %d，落空收掉 %d，没等到结果 %d）；"
        .. "防住率 格挡中 %.0f%% / 没格挡 %.0f%%", s.contact, s.busy, s.preDef, s.preHit, s.wait, s.right, s.wrong, s.fix, s.undo,
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
LAT = { N = 32, MAX_RTT = 3000, JUMP = 2000,
              EXTRA_MAX = 0.25, EXTRA_ATK = 0.8, EXTRA_HIT = 0.5, EXTRA_TURN = 0.2,
              SKIP_MAX = 0.10, SKIP_MIN = 0.03, WINDUP_FLOOR = 0.25, WINDUP_KEEP = 0.6, SKIP_WAIT = 0.25, NOTE_LOGS = 10,
              LEARN_MIN = 2, LEARN_LO = 0.08, LEARN_HI = 2.0, SAVE_EVERY = 60, LEARN_LOGS = 60,     -- §84 学到的前摇 10 → 60 秒落一次盘
              -- 通知状态类名里带这些（不分大小写）算攻击判定窗口；带 BAD 里的不算
              HINTS = { "attack", "damage", "hitbox", "hitcheck", "trace", "collision", "weaponhit", "hurt" },
              BAD = { "react", "cancel", "input", "combo", "buffer", "sound", "fx", "camera" },
              WINDUP = {},      -- 手填：蒙太奇短名 → 前摇秒数（优先于学到的）
              learned = {},     -- 学到的：蒙太奇短名 → { min = 秒, n = 次数 }
              byId = {},        -- 远端招式号 → 替身为它播的蒙太奇名（判定结果回来时对得上才学）
              notified = {},    -- 蒙太奇短名 → 从通知读到的前摇；false = 读过没找到
              loaded = false, dirty = false, savedAt = -100, learnLogs = 0,
              samples = {}, off = nil, rtt = nil, rttMin = nil, rttMax = nil, peerTs = nil, peerAt = nil,
              ages = {}, pend = nil, notes = 0,
              st = { extra = 0, skip = 0, skipMs = 0, noSkip = 0, noWhy = {} },
              activeMontage = G.activeMontage or function() return nil end,
              setPos = G.montageSetPos or function() return false end, notifies = G.montageNotifies or function() return nil end }

function LAT.ms(tn) return math.floor(tn * 1000 + 0.5) end

-- 新连接 / 对方重启：对方的时钟换了，样本全作废
function LAT.reset()
    LAT.samples, LAT.off, LAT.rtt, LAT.rttMin, LAT.rttMax, LAT.peerTs, LAT.peerAt, LAT.ages = {}, nil, nil, nil, nil, nil, nil, {}
end

-- 发送端：ts / tse / evt（evt=<招式号:我出这招时的 ts>,...，和 ev= 一一对应；旧版对方不认这几个字段，原样忽略）
function LAT.wire(tn, events)
    local s = string.format("ts=%d\n", LAT.ms(tn))
    if LAT.peerTs then s = s .. string.format("tse=%d:%d\n", LAT.peerTs, math.max(0, LAT.ms(tn) - LAT.peerAt)) end
    local evt = {}
    for _, e in ipairs(events or {}) do if e.ts then evt[#evt + 1] = e.id .. ":" .. e.ts end end
    return s .. "evt=" .. table.concat(evt, ",") .. "\n"
end

-- 接收端：每个新包调一次。返回这一包的包龄（秒，不知道 = nil）
function LAT.onPacket(t, tn)
    local ts = tonumber(t.ts)
    if not ts then LAT.peerTs = nil; return nil end
    local t4 = LAT.ms(tn)
    LAT.peerTs, LAT.peerAt = ts, t4
    local t1, hold = (t.tse or ""):match("^(%-?%d+):(%d+)$")
    t1, hold = tonumber(t1), tonumber(hold)
    if t1 then
        local rtt = t4 - t1 - hold
        if rtt >= 0 and rtt < LAT.MAX_RTT then
            local off = ((ts - hold - t1) + (ts - t4)) / 2       -- 对方时钟 − 我的时钟
            if LAT.off and math.abs(off - LAT.off) > LAT.JUMP then
                out("延迟：对方时钟跳了 %+.0f ms（对方重启游戏？），重新测", off - LAT.off)
                LAT.samples = {}
            end
            local sm = LAT.samples
            sm[#sm + 1] = { rtt = rtt, off = off }
            if #sm > LAT.N then table.remove(sm, 1) end
            -- 时钟差取往返最小的那个样本（排队只会让往返变大，最小的那个最接近对称）；往返显示中位数
            local best, sorted = sm[1], {}
            for _, x in ipairs(sm) do
                if x.rtt < best.rtt then best = x end
                sorted[#sorted + 1] = x.rtt
            end
            table.sort(sorted)
            LAT.off, LAT.rtt = best.off, sorted[math.floor((#sorted + 1) / 2)]
            LAT.rttMin, LAT.rttMax = sorted[1], sorted[#sorted]
        end
    end
    local age = LAT.age(ts, tn)
    if age then
        LAT.ages[#LAT.ages + 1] = age
        if #LAT.ages > 300 then table.remove(LAT.ages, 1) end
    end
    return age
end

-- 对方时钟的 tsMs 那一刻，离我现在多少秒（还没测出时钟差 = nil）
function LAT.age(tsMs, tn)
    if not (LAT.off and tsMs) then return nil end
    return math.max(0, LAT.ms(tn) - (tsMs - LAT.off)) / 1000
end

function LAT.rttMs() return LAT.rtt end

-- B 外推（纯函数）：pos + vel × min(age, EXTRA_MAX)，只动 XY（drivePuppet 只驱动 XY，Z 交给重力 / 起跳）
function LAT.extrapolate(pos, vel, age)
    if not (pos and vel and age and age > 0) then return pos end
    local a = math.min(age, LAT.EXTRA_MAX)
    return { X = pos.X + (vel.X or 0) * a, Y = pos.Y + (vel.Y or 0) * a, Z = pos.Z }
end

-- 这一帧替身追的目标位置。返回 位置, 不外推的原因（外推了 = nil）
function LAT.target(tn)
    local pos = NET.pos
    if ST.pupAtkAt and tn - ST.pupAtkAt < LAT.EXTRA_ATK then return pos, "出招" end
    if NET.lastHrAt and tn - NET.lastHrAt < LAT.EXTRA_HIT then return pos, "受击" end
    if NET.turnAt and tn - NET.turnAt < LAT.EXTRA_TURN then return pos, "急转" end
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
end

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

-- ============================================================ §100 替身放招成功却没换动作（v0.27.20）
-- 2026-11-05 22:31–22:32 实战（对方白影 / 混沌剑）：对方从 BB 接白影 C、火形 B / BBB 时，替身 TryActivateAbilityByClass 返回 true，
-- 技能照自己的时间表出伤害（白影 C 3.8 秒里 −955、−1546，第二次直接把人打倒），替身身上却还是 BB 的动作或者空着——
-- 玩家看到"对方没出招，我一直挨打"。白影 C 7 次里 3 次、火形 BBB 15 次里 11 次这样，前一个动作都是 BB。
-- §65 的"上一招没收先停掉"只在放不出时走，这里放得出，所以没管到。
-- 做法：放成功 CHECK 秒后看替身的动作——
--   换上了新动作（名字变了，或同名但刚从头播）→ 记下"招 → 动作"
--   没换、这招还挂着、而且知道这招该播什么 → ① 停掉旧动作、取消挂着的招，重放一次；② 再过 CHECK 秒还没新动作 → 直接播那个动作
--   不知道这招该播什么的不碰（有的招本来就没有动作），只记一行
-- "招 → 动作"从替身放成功的招、本机玩家自己放的招里学；SEED 是 2026-11-05 日志里玩家自己放出来的（一一对应）
ANIM = { CHECK = 0.15, FRESH = 0.4, LOGS = 30, logs = 0, map = {}, unknown = {},
         st = { ok = 0, stuck = 0, retryOk = 0, playOk = 0, fail = 0, ended = 0 } }
ANIM.SEED = {
    GA_Hun_BaiYing_A_C = "Hun_BaiYing_A_Montage", GA_Hun_BaiYing_AA_C = "Hun_BaiYing_AA_Montage",
    GA_Hun_BaiYing_AAA_C = "Hun_BaiYing_AAA_Montage", GA_Hun_BaiYing_AAAA_C = "Hun_BaiYing_AAAA_Montage",
    GA_Hun_BaiYing_AAAAA_C = "Hun_BaiYing_AAAAA_Montage", GA_Hun_BaiYing_B_C = "Hun_BaiYing_B_Montage",
    GA_Hun_BaiYing_BB_C = "Hun_BaiYing_BB_Montage", GA_Hun_BaiYing_BBB_C = "Hun_BaiYing_BBB_Montage",
    GA_Hun_BaiYing_C_C = "Hun_BaiYing_C_Montage", GA_Hun_BaiYing_SWT_Power_C = "Hun_BaiYing_AAAA_Montage",
    GA_Hun_Chaos_A_C = "Hun_YuCongBlade_Attack_A_Montage", GA_Hun_Chaos_AA_C = "Hun_YuCongBlade_Attack_AA_Montage",
    GA_Hun_Chaos_AAA_C = "Hun_YuCongBlade_Attack_AAA_Montage", GA_Hun_Chaos_AAAA_C = "Hun_YuCongBlade_Attack_AAAA_Montage",
    GA_Hun_Chaos_AAAAA_C = "Hun_YuCongBlade_Attack_AAAAA_Montage", GA_Hun_Chaos_C_C = "Hun_YuCongBlade_Unique_Skill_Montage",
    GA_Hun_Chaos_B_Fire_C = "Hun_YuCongBlade_Type02_B_Montage", GA_Hun_Chaos_BB_Fire_C = "Hun_YuCongBlade_Type02_BB_Montage",
    GA_Hun_Chaos_BBB_Fire_C = "Hun_YuCongBlade_Type02_BBB_Montage", GA_Hun_Chaos_B_Ice_C = "Hun_YuCongBlade_Type01_B_Montage",
    GA_Hun_Chaos_B_Physics_C = "Hun_YuCongBlade_Type03_B_Montage", GA_Hun_Chaos_BB_Physics_C = "Hun_YuCongBlade_Type03_BB_Montage",
    GA_Hun_Chaos_SwitchFormPhysic_SWT_C = "Hun_YuCongBlade_Skill_06_Montage",
}

-- §165.2 BEGIN 动作表（tools/gen_anim_seed.py 生成，704 招，别手改）
ANIM.SEED2 = {
    GA_BrutalAxe_Combo_C = "ShaChi_BrutalAxe_Combo_Montage", GA_BrutalAxe_Normal_C = "ShaChi_BrutalAxe_Charge_Montage",
    GA_BrutalAxe_Sprint_C = "ShaChi_BrutalAxe_Charge_Sprint_Montage", GA_DuYan_Bow_Laser_C = "AM_Hun_UnnamedBow_Charge1",
    GA_DuYan_Bow_Normal_C = "AM_Hun_UnnamedBow_Charge", GA_HorseCart_Charge_C = "AM_GetOnHorseCart",
    GA_HuangJinHuoChong_Dash_C = "Hun_HuangJinHuoChong_SpecialSkill_02_Montage",
    GA_HuangJinHuoChong_DeflectCounter_C = "Hun_HuangJinHuoChong_SpecialAttack_06_Montage1",
    GA_HuangJinHuoChong_Normal_02_C = "Hun_ShaChi_HuoChong_Attack_07_Montage",
    GA_HuangJinHuoChong_Normal_04_C = "Hun_ShaChi_HuoChong_Attack_07_Montage", GA_Hun_Air_Double_AAA_C = "AM_Hun_Air_Double_AAA_Start",
    GA_Hun_Air_Double_AA_C = "AM_Hun_Air_Double_AA", GA_Hun_Air_Tang_AA_C = "AM_Hun_Air_Tang_AA_Start",
    GA_Hun_BaiYing_AAAAA_C = "Hun_BaiYing_AAAAA_Montage", GA_Hun_BaiYing_AAAA_C = "Hun_BaiYing_AAAA_Montage",
    GA_Hun_BaiYing_AAA_C = "Hun_BaiYing_AAA_Montage", GA_Hun_BaiYing_AA_C = "Hun_BaiYing_AA_Montage",
    GA_Hun_BaiYing_A_C = "Hun_BaiYing_A_Montage", GA_Hun_BaiYing_A_DashDraw_C = "AM_Hun_Long_A_DashDraw",
    GA_Hun_BaiYing_A_Dash_C = "AM_Hun_Long_A_Dash", GA_Hun_BaiYing_Air_A_C = "Hun_Long_JumpAttackA_Montage",
    GA_Hun_BaiYing_Air_A_Draw_C = "Hun_Long_JumpAttackA_Montage", GA_Hun_BaiYing_Air_B_C = "Hun_Long_JumpAttackB_Montage",
    GA_Hun_BaiYing_Air_B_Draw_C = "Hun_Long_JumpAttackB_Montage", GA_Hun_BaiYing_BBB_C = "Hun_BaiYing_BBB_Montage",
    GA_Hun_BaiYing_BB_C = "Hun_BaiYing_BB_Montage", GA_Hun_BaiYing_B_C = "Hun_BaiYing_B_Montage",
    GA_Hun_BaiYing_B_DashDraw_C = "AM_Hun_Long_B_DashDraw", GA_Hun_BaiYing_B_Dash_C = "AM_Hun_Long_B_Dash",
    GA_Hun_BaiYing_C_C = "Hun_BaiYing_C_Montage", GA_Hun_BaiYing_SWT_Power_C = "Hun_BaiYing_AAAA_Montage",
    GA_Hun_BaiYing_SpeicalAssault_C = "RTG_Hun_BaiYing_Skill_07_A_Montage",
    GA_Hun_BronzeSword_AAAA_C = "Hun_QingTongJian_Attack_AAAA_Montage",
    GA_Hun_BronzeSword_AAABB_C = "Hun_QingTongJian_Attack_AAABB_Montage",
    GA_Hun_BronzeSword_AAAB_C = "Hun_QingTongJian_Attack_AAAB_Montage", GA_Hun_BronzeSword_AAA_C = "Hun_QingTongJian_Attack_AAA_Montage",
    GA_Hun_BronzeSword_AABB_C = "Hun_QingTongJian_Attack_AABB_Montage", GA_Hun_BronzeSword_AAB_C = "Hun_QingTongJian_Attack_AAB_Montage",
    GA_Hun_BronzeSword_AA_C = "Hun_QingTongJian_Attack_AA_Montage", GA_Hun_BronzeSword_ABB_C = "Hun_QingTongJian_Attack_ABB_Montage",
    GA_Hun_BronzeSword_AB_C = "Hun_QingTongJian_Attack_AB_Montage", GA_Hun_BronzeSword_A_C = "Hun_QingTongJian_Attack_A_Montage",
    GA_Hun_BronzeSword_A_Dash_C = "Hun_QingTongJian_Dash_A_Montage", GA_Hun_BronzeSword_A_Draw_C = "Hun_QingTongJian_Attack_A_Montage",
    GA_Hun_BronzeSword_BA_C = "Hun_QingTongJian_Attack_A_Montage", GA_Hun_BronzeSword_BBB_C = "Hun_QingTongJian_Attack_BBB_Montage",
    GA_Hun_BronzeSword_BB_C = "Hun_QingTongJian_Attack_BB_Montage", GA_Hun_BronzeSword_B_C = "Hun_QingTongJian_Attack_B_Montage",
    GA_Hun_BronzeSword_B_Dash_C = "Hun_QingTongJian_Dash_B_Montage", GA_Hun_BronzeSword_B_Hold_C = "Hun_QingTongJian_Attack_Hold_B_Montage",
    GA_Hun_BronzeSword_C_C = "Hun_QingTongJian_Skill_01_Montage", GA_Hun_BronzeSword_SWT_C = "Hun_QingTongJian_Attack_SWT_Montage",
    GA_Hun_Chaos_AAAAA_C = "Hun_YuCongBlade_Attack_AAAAA_Montage", GA_Hun_Chaos_AAAA_C = "Hun_YuCongBlade_Attack_AAAA_Montage",
    GA_Hun_Chaos_AAABB_Physics_C = "AM_Hun_Tang_AAABB", GA_Hun_Chaos_AAAB_Physics_C = "Hun_YuCongBlade_Type01_BBB_Montage",
    GA_Hun_Chaos_AAA_C = "Hun_YuCongBlade_Attack_AAA_Montage", GA_Hun_Chaos_AABB_Physics_C = "Hun_YuCongBlade_Type03_BBB_Montage",
    GA_Hun_Chaos_AAB_Physics_C = "AM_Hun_Tang_AAB", GA_Hun_Chaos_AA_C = "Hun_YuCongBlade_Attack_AA_Montage",
    GA_Hun_Chaos_ABB_Physics_C = "Hun_YuCongBlade_Type03_BB_Montage", GA_Hun_Chaos_AB_Physics_C = "Hun_CanGangRen_Attack_AB_Montage",
    GA_Hun_Chaos_A_C = "Hun_YuCongBlade_Attack_A_Montage", GA_Hun_Chaos_A_DashDraw_C = "Hun_CanGangRen_Dash_A_Montage",
    GA_Hun_Chaos_A_Dash_C = "Hun_CanGangRen_Dash_A_Montage", GA_Hun_Chaos_A_Draw_C = "Hun_YuCongBlade_Attack_A_Montage",
    GA_Hun_Chaos_BBB_Physics_C = "Hun_YuCongBlade_Type03_BBB_Montage", GA_Hun_Chaos_BB_Physics_C = "Hun_YuCongBlade_Type03_BB_Montage",
    GA_Hun_Chaos_B_DashDraw_C = "Hun_CanGangRen_Dash_B_Montage", GA_Hun_Chaos_B_Dash_C = "Hun_CanGangRen_Dash_B_Montage",
    GA_Hun_Chaos_B_Draw_C = "Hun_YuCongBlade_Type03_B_Montage", GA_Hun_Chaos_B_Hold_Physics_C = "Hun_YuCongBlade_Skill_01_Montage",
    GA_Hun_Chaos_B_Physics_C = "Hun_YuCongBlade_Type03_B_Montage", GA_Hun_Chaos_C_C = "Hun_YuCongBlade_Unique_Skill_Montage",
    GA_Hun_Chaos_SWT_Power_C = "Hun_YuCongBlade_Skill_05_Montage", GA_Hun_Chaos_SwitchFormPhysic_SWT_C = "Hun_YuCongBlade_Skill_06_Montage",
    GA_Hun_ChiRen_AAAABB_C = "Hun_ChiRen_Attack_AAAABB_Montage", GA_Hun_ChiRen_AAAAB_C = "Hun_ChiRen_Attack_AAAAB_Montage",
    GA_Hun_ChiRen_AAAA_C = "Hun_ChiRen_Attack_AAAA_Montage", GA_Hun_ChiRen_AAABB_C = "Hun_ChiRen_Attack_AAABB_Montage",
    GA_Hun_ChiRen_AAAB_C = "Hun_ChiRen_Attack_AAAB_Montage", GA_Hun_ChiRen_AAA_C = "Hun_ChiRen_Attack_AAA_Montage",
    GA_Hun_ChiRen_AABB_C = "Hun_ChiRen_Attack_AABB_Montage", GA_Hun_ChiRen_AAB_C = "Hun_ChiRen_Attack_AAB_Montage",
    GA_Hun_ChiRen_AA_C = "Hun_ChiRen_Attack_AA_Montage", GA_Hun_ChiRen_ABB_C = "Hun_ChiRen_Attack_ABB_Montage",
    GA_Hun_ChiRen_AB_C = "Hun_ChiRen_Attack_AB_Montage", GA_Hun_ChiRen_A_C = "Hun_ChiRen_Attack_A_Montage",
    GA_Hun_ChiRen_A_Draw_C = "Hun_ChiRen_Attack_A_Montage", GA_Hun_ChiRen_BBB_C = "Hun_ChiRen_Attack_BBB_Montage",
    GA_Hun_ChiRen_BB_C = "Hun_ChiRen_Attack_BB_Montage", GA_Hun_ChiRen_BD_C = "Hun_ChiRen_Attack_A_Montage",
    GA_Hun_ChiRen_BSup_C = "Hun_WangMingZhanMaDao_Attack_AAAB_Montage", GA_Hun_ChiRen_B_C = "Hun_ChiRen_Attack_B_Montage",
    GA_Hun_ChiRen_B_DashDraw_C = "Hun_Horizontal_B_DashDraw_Montage", GA_Hun_ChiRen_B_Dash_C = "Hun_Horizontal_B_Dash_Fixed_Montage",
    GA_Hun_ChiRen_B_Draw_C = "Hun_ChiRen_Attack_B_Montage", GA_Hun_ChiRen_C_C = "Hun_ZhiRen_Unique_Skill_01_Montage",
    GA_Hun_ChiRen_SWT_C = "Hun_Horizontal_AAAA_Montage", GA_Hun_ChiZheCanJian_C_C = "Hun_ChiZheCanJian_Drunk_Unique_Skill_Montage",
    GA_Hun_ChiZheCanJian_Drunk_AAAAA_C = "Hun_ChiZheCanJian_Drunk_Attack_EEEEE_Montage",
    GA_Hun_ChiZheCanJian_Drunk_AAAA_C = "Hun_ChiZheCanJian_Drunk_Attack_EEEE_Montage1",
    GA_Hun_ChiZheCanJian_Drunk_AAA_C = "Hun_ChiZheCanJian_Drunk_Attack_EEE_Montage",
    GA_Hun_ChiZheCanJian_Drunk_AA_C = "Hun_ChiZheCanJian_Drunk_Attack_EE_Montage",
    GA_Hun_ChiZheCanJian_Drunk_A_C = "Hun_ChiZheCanJian_Drunk_Attack_E_Montage",
    GA_Hun_ChiZheCanJian_Drunk_A_DashChild_C = "Hun_ChiZheCanJian_Drunk_Attack_E_Montage",
    GA_Hun_ChiZheCanJian_Normal_AAAAA_C = "Hun_ChiZheCanJian_Awake_Attack_AAAAA_Montage",
    GA_Hun_ChiZheCanJian_Normal_AAAA_C = "Hun_ChiZheCanJian_Awake_Attack_AAAA_Montage",
    GA_Hun_ChiZheCanJian_Normal_AAA_C = "Hun_ChiZheCanJian_Awake_Attack_AAA_Montage",
    GA_Hun_ChiZheCanJian_Normal_AA_C = "Hun_ChiZheCanJian_Awake_Attack_AA_Montage",
    GA_Hun_ChiZheCanJian_Normal_AA_DashChild_C = "Hun_ChiZheCanJian_Awake_Attack_AA_Montage",
    GA_Hun_ChiZheCanJian_Normal_A_C = "Hun_ChiZheCanJian_Awake_Attack_A_Montage",
    GA_Hun_ChiZheCanJian_Normal_BBB_C = "Hun_ChiZheCanJian_Awake_Attack_ABBB_Montage",
    GA_Hun_ChiZheCanJian_Normal_BB_C = "Hun_ChiZheCanJian_Awake_Attack_ABB_Montage",
    GA_Hun_ChiZheCanJian_Normal_B_C = "Hun_ChiZheCanJian_Awake_Attack_B_Montage",
    GA_Hun_ChiZheCanJian_Normal_B_DashChild_C = "Hun_ChiZheCanJian_Awake_Attack_B_Montage",
    GA_Hun_ChiZheCanJian_SWT_C = "Hun_ChiZheCanJian_Drunk_Attack_EEFD_Montage",
    GA_Hun_ChiZheCanJian_Tipsy_BBB_C = "Hun_ChiZheCanJian_Tipsy_Attack_ABB_Montage",
    GA_Hun_ChiZheCanJian_Tipsy_BB_C = "Hun_ChiZheCanJian_Tipsy_Attack_BB_Montage",
    GA_Hun_ChiZheCanJian_Tipsy_B_C = "Hun_ChiZheCanJian_Tipsy_Attack_B_Montage", GA_Hun_Double_AAAAAA_C = "AM_Hun_Double_AAAAAA",
    GA_Hun_Double_AAAAA_C = "AM_Hun_Double_AAAAA", GA_Hun_Double_AAAA_C = "AM_Hun_Double_AAAA",
    GA_Hun_Double_AAABBB_C = "AM_Hun_Double_AAABBB", GA_Hun_Double_AAABB_C = "AM_Hun_Double_AAABB",
    GA_Hun_Double_AAAB_C = "AM_Hun_Double_AAAB", GA_Hun_Double_AAA_C = "AM_Hun_Double_AAA", GA_Hun_Double_AABB_C = "AM_Hun_Double_AABB",
    GA_Hun_Double_AAB_C = "AM_Hun_Double_AAB", GA_Hun_Double_AA_C = "AM_Hun_Double_AA", GA_Hun_Double_ABB_C = "AM_Hun_Double_ABB",
    GA_Hun_Double_AB_C = "AM_Hun_Double_AB", GA_Hun_Double_ATBBB_C = "AM_Hun_Double_AAABB", GA_Hun_Double_ATBB_C = "AM_Hun_Double_AB",
    GA_Hun_Double_ATB_C = "AM_Hun_Double_AAB", GA_Hun_Double_A_C = "AM_Hun_Double_A",
    GA_Hun_Double_A_DashDraw_Short_C = "AM_Hun_Double_A_DashDraw", GA_Hun_Double_A_Dash_Short_C = "AM_Hun_Double_A_Dash",
    GA_Hun_Double_A_Draw_C = "AM_Hun_Double_A_Draw", GA_Hun_Double_Air_A_C = "Hun_Tang_JumpAttackB_Montage",
    GA_Hun_Double_Air_A_Draw_C = "Hun_Tang_JumpAttackB_Montage", GA_Hun_Double_Air_B_C = "Hun_Double_JumpAttackA_Montage",
    GA_Hun_Double_Air_B_Draw_C = "Hun_Double_JumpAttackA_Montage", GA_Hun_Double_BBBB_C = "AM_Hun_Double_BBBB",
    GA_Hun_Double_BBB_C = "AM_Hun_Double_BBB", GA_Hun_Double_BB_C = "AM_Hun_Double_BB", GA_Hun_Double_BTA_C = "AM_Hun_Double_A_DashDraw",
    GA_Hun_Double_B_C = "AM_Hun_Double_B", GA_Hun_Double_B_DashDraw_C = "AM_Hun_Double_B_DashDraw",
    GA_Hun_Double_B_Dash_C = "AM_Hun_Double_B_Dash", GA_Hun_Double_B_Draw_C = "AM_Hun_Double_B_Draw",
    GA_Hun_Double_JueYing_C_Air_C = "Hun_Double_Crow_Near_Montage", GA_Hun_Double_JueYing_C_C = "Hun_Double_Crow_Near_Montage",
    GA_Hun_Double_SWT_C = "AM_Hun_Double_PD_L1", GA_Hun_Double_SWT_Tutorial_C = "AM_Hun_Double_A_Draw",
    GA_Hun_DualHook_AAAAA_C = "Hun_BieLiCanGou_AAAAA_Montage", GA_Hun_DualHook_AAAA_C = "Hun_BieLiCanGou_AAAA_Montage",
    GA_Hun_DualHook_AAABB_C = "Hun_BieLiCanGou_AAABB_Montage", GA_Hun_DualHook_AAAB_C = "Hun_BieLiCanGou_AB_Montage",
    GA_Hun_DualHook_AAA_C = "Hun_BieLiCanGou_AAA_Montage", GA_Hun_DualHook_AABB_C = "Hun_BieLiCanGou_AABB_Montage",
    GA_Hun_DualHook_AAB_C = "Hun_BieLiCanGou_AAB_Montage", GA_Hun_DualHook_AA_C = "Hun_BieLiCanGou_AA_Montage",
    GA_Hun_DualHook_ABB_C = "Hun_BieLiCanGou_ABB_Montage", GA_Hun_DualHook_AB_C = "Hun_BieLiCanGou_AAAB_Montage",
    GA_Hun_DualHook_A_C = "Hun_BieLiCanGou_A_Montage", GA_Hun_DualHook_A_DashDraw_C = "Hun_BieLiCanGou_DashA_Montage",
    GA_Hun_DualHook_A_Dash_C = "Hun_BieLiCanGou_DashA_Montage", GA_Hun_DualHook_A_Draw_C = "Hun_BieLiCanGou_A_Montage",
    GA_Hun_DualHook_A_Pursure_02_C = "Hun_BieLiCanGou_A_Pursue_Montage", GA_Hun_DualHook_Air_B_C = "Hun_Double_JumpAttackA_Montage",
    GA_Hun_DualHook_Air_B_Draw_C = "Hun_Double_JumpAttackA_Montage", GA_Hun_DualHook_BBBB_C = "Hun_BieLiCanGou_BBBB_Montage",
    GA_Hun_DualHook_BBB_C = "Hun_BieLiCanGou_BBB_Montage", GA_Hun_DualHook_BB_C = "Hun_BieLiCanGou_AABB_Montage",
    GA_Hun_DualHook_B_C = "Hun_BieLiCanGou_B_Montage", GA_Hun_DualHook_B_DashDraw_C = "Hun_BieLiCanGou_DashB_Montage",
    GA_Hun_DualHook_B_Dash_C = "Hun_BieLiCanGou_DashB_Montage", GA_Hun_DualHook_B_Draw_C = "Hun_BieLiCanGou_B_Montage",
    GA_Hun_DualHook_B_Pursure_C = "Hun_BieLiCanGou_Skill_02_Montage", GA_Hun_DualHook_C_C = "Hun_BieLiCanGou_Unique_Skill_01_Montage",
    GA_Hun_DualHook_DB_C = "GuiChai_Yellow_Special_Defence_Start_Montage",
    GA_Hun_DualHook_DB_SWT_C = "GuiChai_Yellow_Special_Defence_Start_Montage",
    GA_Hun_DualHook_SWT_Power_C = "GuiChai_Yellow_Special_Defence_Start_Montage",
    GA_Hun_FengLeiJian_AAAA_C = "Hun_BaiShanDual_Attack_AAAA_Montage", GA_Hun_FengLeiJian_AAABB_C = "Hun_BaiShanDual_Attack_AAABB_Montage",
    GA_Hun_FengLeiJian_AAAB_C = "Hun_BaiShanDual_Attack_AAAB_Montage", GA_Hun_FengLeiJian_AAA_C = "Hun_BaiShanDual_Attack_AAA_Montage",
    GA_Hun_FengLeiJian_AABAB_C = "Hun_BaiShanDual_Attack_AABAB_Montage", GA_Hun_FengLeiJian_AABA_C = "Hun_BaiShanDual_Attack_AABA_Montage",
    GA_Hun_FengLeiJian_AABB_C = "Hun_BaiShanDual_Attack_AABB_Montage", GA_Hun_FengLeiJian_AAB_C = "Hun_BaiShanDual_Attack_AAB_Montage",
    GA_Hun_FengLeiJian_AA_C = "Hun_BaiShanDual_Attack_AA_Montage", GA_Hun_FengLeiJian_AB_C = "AM_Hun_Double_AB",
    GA_Hun_FengLeiJian_A_C = "Hun_BaiShanDual_Attack_A_Montage", GA_Hun_FengLeiJian_A_DashDraw_C = "AM_Hun_Double_A_DashDraw",
    GA_Hun_FengLeiJian_A_Dash_C = "AM_Hun_Double_A_Dash", GA_Hun_FengLeiJian_A_Draw_C = "AM_Hun_Double_A_Draw",
    GA_Hun_FengLeiJian_Air_A_C = "Hun_Tang_JumpAttackB_Montage", GA_Hun_FengLeiJian_Air_A_Draw_C = "Hun_Tang_JumpAttackB_Montage",
    GA_Hun_FengLeiJian_Air_B_C = "Hun_Double_JumpAttackA_Montage", GA_Hun_FengLeiJian_Air_B_Draw_C = "Hun_Double_JumpAttackA_Montage",
    GA_Hun_FengLeiJian_BBBB_C = "Hun_BaiShanDual_Attack_BBBB_Montage", GA_Hun_FengLeiJian_BBB_C = "Hun_BaiShanDual_Attack_BBB_Montage",
    GA_Hun_FengLeiJian_BB_C = "Hun_BaiShanDual_Attack_BB_Montage", GA_Hun_FengLeiJian_B_C = "Hun_BaiShanDual_Attack_B_Montage",
    GA_Hun_FengLeiJian_B_DashDraw_C = "AM_Hun_Double_B_DashDraw", GA_Hun_FengLeiJian_B_Dash_C = "AM_Hun_Double_B_Dash",
    GA_Hun_FengLeiJian_B_Draw_C = "Hun_BaiShanDual_Attack_B_Montage", GA_Hun_FengLeiJian_B_Hold_C = "Hun_BaiShanDual_Hold_B_02_Montage",
    GA_Hun_FengLeiJian_C_C = "Hun_BaiShanDual_Skill_02_Montage",
    GA_Hun_FengLeiJian_FengLeiState_SpecailAttack_02_C = "Hun_BaiShanDual_Skill_03_Montage",
    GA_Hun_FengLeiJian_SWT_Power_C = "Hun_BaiShanDual_Attack_AABB_Montage", GA_Hun_GuiTouBlade_AAAA_C = "Hun_Horizontal_AAA_Montage",
    GA_Hun_GuiTouBlade_AAABB_C = "Hun_Horizontal_BB_Montage", GA_Hun_GuiTouBlade_AAAB_C = "Hun_Horizontal_B_Montage",
    GA_Hun_GuiTouBlade_AAA_C = "Hun_AHuaBlade_AAA_Montage", GA_Hun_GuiTouBlade_AABB_C = "Hun_AHuaBlade_AAB_Ex_Montage",
    GA_Hun_GuiTouBlade_AAB_C = "Hun_AHuaBlade_AAB_Montage", GA_Hun_GuiTouBlade_AA_C = "Hun_AHuaBlade_AA_Montage",
    GA_Hun_GuiTouBlade_ABB_C = "Hun_AHuaBlade_AB_Ex_Montage", GA_Hun_GuiTouBlade_AB_C = "Hun_AHuaBlade_AB_Montage",
    GA_Hun_GuiTouBlade_A_C = "Hun_AHuaBlade_A_Montage", GA_Hun_GuiTouBlade_A_DashDraw_C = "Hun_Horizontal_A_Dash_Montage",
    GA_Hun_GuiTouBlade_A_Dash_C = "Hun_Horizontal_A_Dash_Montage", GA_Hun_GuiTouBlade_A_Draw_C = "Hun_AHuaBlade_Switch_A_Montage",
    GA_Hun_GuiTouBlade_BBB_C = "Hun_AHuaBlade_BB_Ex_Montage", GA_Hun_GuiTouBlade_BB_C = "Hun_Horizontal_AA_Montage",
    GA_Hun_GuiTouBlade_BB_UnCharge_C = "Hun_Horizontal_AA_Montage",
    GA_Hun_GuiTouBlade_BB_UnCharge_Reinforced_C = "Hun_Horizontal_AA_Montage", GA_Hun_GuiTouBlade_B_C = "Hun_Horizontal_A_Montage",
    GA_Hun_GuiTouBlade_B_DashDraw_C = "Hun_AHuaBlade_Draw_Dash_B_02_Montage",
    GA_Hun_GuiTouBlade_B_Dash_C = "Hun_AHuaBlade_Dash_B_02_Montage", GA_Hun_GuiTouBlade_B_Draw_C = "Hun_Horizontal_A_Draw_Montage",
    GA_Hun_GuiTouBlade_B_Hold_C = "Hun_AHuaBlade_B_Hold_Montage", GA_Hun_GuiTouBlade_B_Hold_Start_C = "Hun_AHuaBlade_B_Hold_Montage",
    GA_Hun_GuiTouBlade_C_C = "Hun_AHuaBlade_C_Montage", GA_Hun_GuiTouBlade_SWT_C = "Hun_AHuaBlade_SnapB_Montage",
    GA_Hun_HeiMoShang_AAAAAA_C = "Hun_HeiMoShang_BBBB_Montage", GA_Hun_HeiMoShang_AAAAABB_C = "Hun_HeiMoShang_Skill_01_Montage",
    GA_Hun_HeiMoShang_AAAAAB_C = "Hun_HeiMoShang_AAABB_Montage", GA_Hun_HeiMoShang_AAAAA_C = "Hun_HeiMoShang_AAAAA_Montage",
    GA_Hun_HeiMoShang_AAAAB_Alt_C = "Hun_HeiMoShang_AAAAB_Montage", GA_Hun_HeiMoShang_AAAA_C = "Hun_HeiMoShang_AAAA_Montage",
    GA_Hun_HeiMoShang_AAABB_C = "Hun_HeiMoShang_AAABB_Montage", GA_Hun_HeiMoShang_AAAB_C = "Hun_HeiMoShang_AAAB_Montage",
    GA_Hun_HeiMoShang_AAA_C = "Hun_HeiMoShang_AAA_Montage", GA_Hun_HeiMoShang_AABB_C = "Hun_HeiMoShang_AABB_Montage",
    GA_Hun_HeiMoShang_AAB_C = "Hun_HeiMoShang_AAB_Montage", GA_Hun_HeiMoShang_AA_C = "Hun_HeiMoShang_AA_Montage",
    GA_Hun_HeiMoShang_ABB_C = "Hun_HeiMoShang_ABB_Montage", GA_Hun_HeiMoShang_AB_C = "Hun_HeiMoShang_AB_Montage",
    GA_Hun_HeiMoShang_A_C = "Hun_HeiMoShang_A_Montage", GA_Hun_HeiMoShang_A_DashDraw_C = "AM_Hun_Tang_A_DashDraw",
    GA_Hun_HeiMoShang_A_Dash_C = "AM_Hun_Tang_A_Dash", GA_Hun_HeiMoShang_A_Draw_C = "Hun_HeiMoShang_A_Montage",
    GA_Hun_HeiMoShang_BBBB_C = "Hun_HeiMoShang_Skill_01_Montage", GA_Hun_HeiMoShang_BBB_C = "Hun_HeiMoShang_BBB_Montage",
    GA_Hun_HeiMoShang_BB_C = "Hun_HeiMoShang_BB_Montage", GA_Hun_HeiMoShang_B_C = "Hun_HeiMoShang_B_Montage",
    GA_Hun_HeiMoShang_B_DashDraw_C = "AM_Hun_Tang_B_DashDraw", GA_Hun_HeiMoShang_B_Dash_C = "AM_Hun_Tang_B_Dash",
    GA_Hun_HeiMoShang_B_Draw_C = "Hun_HeiMoShang_B_Montage", GA_Hun_HeiMoShang_C1_C = "Hun_HeiMoShang_JueXing_Montage",
    GA_Hun_HeiMoShang_SWT_C = "Hun_HeiMoShang_Skill_01_Montage", GA_Hun_Horizontal_AAAA_C = "Hun_Horizontal_AAAA_Montage",
    GA_Hun_Horizontal_AAAB_C = "Hun_Horizontal_AAAB_Montage", GA_Hun_Horizontal_AAA_C = "Hun_Horizontal_AAA_Montage",
    GA_Hun_Horizontal_AAB_C = "Hun_Horizontal_AAB_Montage", GA_Hun_Horizontal_AA_C = "Hun_Horizontal_AA_Montage",
    GA_Hun_Horizontal_AB_C = "Hun_Horizontal_AB_Montage", GA_Hun_Horizontal_A_C = "Hun_Horizontal_A_Montage",
    GA_Hun_Horizontal_A_DashDraw_C = "Hun_Horizontal_A_Dash_Montage", GA_Hun_Horizontal_A_Dash_C = "Hun_Horizontal_A_Dash_Montage",
    GA_Hun_Horizontal_A_Draw_C = "Hun_Horizontal_A_Draw_Montage", GA_Hun_Horizontal_BB_C = "Hun_Horizontal_BB_Montage",
    GA_Hun_Horizontal_B_C = "Hun_Horizontal_B_Montage", GA_Hun_Horizontal_B_DashDraw_C = "Hun_Horizontal_B_DashDraw_Montage",
    GA_Hun_Horizontal_B_Dash_C = "Hun_Horizontal_B_Dash_Fixed_Montage", GA_Hun_Horizontal_B_Draw_C = "Hun_Horizontal_B_Draw_Montage",
    GA_Hun_Horizontal_B_NoCost_C = "Hun_Horizontal_B_Montage", GA_Hun_Horizontal_BladeWave_C = "Hun_DangKouXiongRen_Skill_01_Montage",
    GA_Hun_Horizontal_C_C = "AM_Hun_Horizontal_C", GA_Hun_Horizontal_CounterAttack_01_C = "Hun_Horizontal_CounterAttack_02_Montage",
    GA_Hun_Horizontal_CounterAttack_02_C = "Hun_Horizontal_CounterAttack_02_Placeholder_Montage",
    GA_Hun_Horizontal_SWT_Power_C = "Hun_Horizontal_CounterAttack_02_Montage", GA_Hun_HuoLiuXing_AAAA_C = "Hun_HuoLiuXing_Attack_D_Montage",
    GA_Hun_HuoLiuXing_AAA_C = "Hun_HuoLiuXing_Attack_C_Montage", GA_Hun_HuoLiuXing_AA_C = "Hun_HuoLiuXing_Attack_B_Montage",
    GA_Hun_HuoLiuXing_A_C = "Hun_HuoLiuXing_Attack_A_Montage", GA_Hun_HuoLiuXing_A_Short_C = "Hun_HuoLiuXing_Attack_A_Montage",
    GA_Hun_HuoLiuXing_DB_C = "ShaChi_Hook_CCC_HuoLiuXing_Placeholder_Montage", GA_Hun_Iron_AAAAA_C = "Hun_CanGangRen_Attack_AAAAA_Montage",
    GA_Hun_Iron_AAAA_C = "Hun_CanGangRen_Attack_AAAA_Montage", GA_Hun_Iron_AAABB_C = "Hun_CanGangRen_Attack_AAABB_Montage",
    GA_Hun_Iron_AAAB_C = "Hun_CanGangRen_Attack_AAAB_Montage", GA_Hun_Iron_AAA_C = "Hun_CanGangRen_Attack_AAA_Montage",
    GA_Hun_Iron_AABB_C = "Hun_CanGangRen_Attack_AABB_Montage", GA_Hun_Iron_AAB_C = "Hun_CanGangRen_Attack_AAB_Montage",
    GA_Hun_Iron_AA_C = "Hun_CanGangRen_Attack_AA_Montage", GA_Hun_Iron_ABB_C = "Hun_CanGangRen_Attack_ABB_Montage",
    GA_Hun_Iron_AB_C = "Hun_CanGangRen_Attack_AB_Montage", GA_Hun_Iron_A_C = "Hun_CanGangRen_Attack_A_Montage",
    GA_Hun_Iron_A_DashDraw_C = "Hun_CanGangRen_Dash_A_Montage", GA_Hun_Iron_A_Dash_C = "Hun_CanGangRen_Dash_A_Montage",
    GA_Hun_Iron_A_Draw_C = "Hun_CanGangRen_Attack_A_Montage", GA_Hun_Iron_BBB_C = "Hun_CanGangRen_Attack_BBB_Montage",
    GA_Hun_Iron_BB_C = "Hun_CanGangRen_Attack_BB_Montage", GA_Hun_Iron_BChargeAttack_C = "Hun_CanGangRen_Skill_02_End_Montage",
    GA_Hun_Iron_BCharge_C = "Hun_CanGangRen_Skill_02_Montage", GA_Hun_Iron_B_C = "Hun_CanGangRen_Attack_B_Montage",
    GA_Hun_Iron_B_DashDraw_C = "Hun_CanGangRen_Dash_B_Montage", GA_Hun_Iron_B_Dash_C = "Hun_CanGangRen_Dash_B_Montage",
    GA_Hun_Iron_B_Draw_C = "Hun_CanGangRen_Attack_B_Draw_Montage", GA_Hun_Iron_C_C = "Hun_CanGangRen_Unique_Skill_Montage",
    GA_Hun_Iron_SWT_C = "Hun_CanGangRen_Attack_BB_Montage", GA_Hun_Jade_AAAAAA_C = "Hun_YuShuangHuan_Attack_AAAAAA_Montage",
    GA_Hun_Jade_AAAAA_C = "Hun_YuShuangHuan_Attack_AAAAA_Montage", GA_Hun_Jade_AAAA_C = "AM_Hun_Jade_AAAA",
    GA_Hun_Jade_AAABB_C = "Hun_YuShuangHuan_SimpleExE_Multi_01_Montage", GA_Hun_Jade_AAAB_C = "Hun_Jade_AAAB_New_Montage",
    GA_Hun_Jade_AAA_C = "Hun_YuShuangHuan_Attack_AAA_Montage", GA_Hun_Jade_AABB_C = "Hun_Jade_AAABB_01_Montage",
    GA_Hun_Jade_AA_C = "Hun_YuShuangHuan_Attack_AA_Montage", GA_Hun_Jade_ABB_C = "AM_Hun_Jade_ABB", GA_Hun_Jade_AB_C = "AM_Hun_Jade_AB",
    GA_Hun_Jade_A_C = "AM_Hun_Jade_A", GA_Hun_Jade_A_DashDraw_C = "AM_Hun_Jade_A_DashDraw", GA_Hun_Jade_A_Dash_C = "AM_Hun_Jade_A_Dash",
    GA_Hun_Jade_A_Draw_C = "AM_Hun_Jade_A_Draw", GA_Hun_Jade_BBBB_C = "Hun_Jade_BB_01_Montage", GA_Hun_Jade_BBB_C = "AM_Hun_Jade_BBB",
    GA_Hun_Jade_BB_C = "AM_Hun_Jade_BB", GA_Hun_Jade_B_C = "AM_Hun_Jade_B", GA_Hun_Jade_B_DashDraw_C = "AM_Hun_Jade_B_DashDraw",
    GA_Hun_Jade_B_Dash_C = "Hun_Jade_B_Dash_Montage", GA_Hun_Jade_B_Draw_C = "AM_Hun_Jade_B_Draw",
    GA_Hun_Jade_C_Range_C = "AM_Hun_Jade_C_Range", GA_Hun_Jade_DB_C = "Hun_ShuangYue_Skill_03_BanBen_02_Montage",
    GA_Hun_Jade_SWT_C = "Hun_Jade_B_New_Montage", GA_Hun_JigSaw_AAAA_C = "Hun_Horizontal_AAA_Montage",
    GA_Hun_JigSaw_AAA_C = "Hun_AHuaBlade_AAA_Montage", GA_Hun_JigSaw_AA_C = "Hun_AHuaBlade_AA_Montage",
    GA_Hun_JigSaw_A_C = "Hun_AHuaBlade_A_Montage", GA_Hun_Jigsaw_AAAB_C = "AM_Hun_Jigsaw_AAAB_Miss",
    GA_Hun_Jigsaw_AAB_C = "AM_Hun_Jigsaw_AAB", GA_Hun_Jigsaw_AB_C = "AM_Hun_Jigsaw_AB",
    GA_Hun_Jigsaw_A_DashDraw_C = "Hun_SawBlade_Dash_Switch_A_Miss_Montage", GA_Hun_Jigsaw_A_Dash_C = "Hun_SawBlade_Dash_A_Miss_Montage",
    GA_Hun_Jigsaw_A_Draw_C = "Hun_SawBlade_Switch_A_Miss_Montage", GA_Hun_Jigsaw_Air_A_C = "Hun_Long_JumpAttackA_Montage",
    GA_Hun_Jigsaw_Air_A_Draw_C = "Hun_Long_JumpAttackA_Montage", GA_Hun_Jigsaw_Air_B_C = "Hun_Long_JumpAttackB_Montage",
    GA_Hun_Jigsaw_Air_B_Draw_C = "Hun_Long_JumpAttackB_Montage", GA_Hun_Jigsaw_BB_C = "Hun_SawBlade_BB_Miss_Montage",
    GA_Hun_Jigsaw_B_C = "AM_Hun_Jigsaw_B_Miss", GA_Hun_Jigsaw_B_DashDraw_C = "Hun_SawBlade_Dash_Switch_B_Miss_Montage",
    GA_Hun_Jigsaw_B_Dash_C = "Hun_SawBlade_Dash_B_Miss_Montage", GA_Hun_Jigsaw_C_C = "Hun_SawBlade_Unique_Skill_Montage",
    GA_Hun_Jigsaw_RAAA_C = "Hun_SawBlade_Skill_AAA_Montage", GA_Hun_Jigsaw_RAA_C = "Hun_SawBlade_Skill_AA_Montage",
    GA_Hun_Jigsaw_RA_C = "Hun_SawBlade_Skill_A_Montage", GA_Hun_Jigsaw_RBB_C = "Hun_SawBlade_Skill_BB_Montage",
    GA_Hun_Jigsaw_RB_C = "Hun_SawBlade_Skill_B_Montage", GA_Hun_Jigsaw_SA_C = "Hun_Jigsaw_SA_Montage",
    GA_Hun_Jigsaw_SB_C = "Hun_Jigsaw_SB_Montage", GA_Hun_Long_A_DashDraw_C = "AM_Hun_Long_A_DashDraw",
    GA_Hun_Long_A_Dash_C = "AM_Hun_Long_A_Dash", GA_Hun_Long_Air_A_C = "Hun_Long_JumpAttackA_Montage",
    GA_Hun_Long_Air_A_Draw_C = "Hun_Long_JumpAttackA_Montage", GA_Hun_Long_Air_B_C = "Hun_Long_JumpAttackB_Montage",
    GA_Hun_Long_Air_B_Draw_C = "Hun_Long_JumpAttackB_Montage", GA_Hun_Long_BCharge_C = "AM_Hun_Long_BCharge",
    GA_Hun_Long_CounterA_C = "Hun_WangMingZhanMaDao_Attack_BB_Montage", GA_Hun_Long_CounterB_C = "Hun_Long_CounterB_Montage",
    GA_Hun_LuanYing_AAAAA_C = "Hun_LuanYing_AAAAA_Montage", GA_Hun_LuanYing_AAAA_C = "Hun_LuanYing_AAAA_Montage",
    GA_Hun_LuanYing_AAA_C = "Hun_LuanYing_AAA_Montage", GA_Hun_LuanYing_AA_C = "Hun_LuanYing_AA_Montage",
    GA_Hun_LuanYing_A_C = "Hun_LuanYing_A_Montage", GA_Hun_LuanYing_A_DashDraw_C = "Hun_LuanYing_B_Montage",
    GA_Hun_LuanYing_DashA_C = "AM_Hun_LuanYing_B_Dash", GA_Hun_LuanYing_Draw_A_C = "Hun_LuanYing_A_Montage",
    GA_Hun_LuanYing_P2_AAAB_C = "Hun_LuanYing_P2_AAAB_Montage", GA_Hun_LuanYing_P2_AAB_C = "Hun_LuanYing_P2_AAB_Montage",
    GA_Hun_LuanYing_P2_AB_C = "Hun_LuanYing_P2_AB_Montage", GA_Hun_LuanYing_P2_BBB_C = "Hun_LuanYing_P2_BBB_Montage",
    GA_Hun_LuanYing_P2_BB_C = "Hun_LuanYing_P2_BB_Montage", GA_Hun_LuanYing_P2_B_C = "Hun_LuanYing_P2_B_Montage",
    GA_Hun_LuanYing_P2_CA_C = "Hun_LuanYing_P2_Unique_Skill_Montage", GA_Hun_LuanYing_SWT_P2_C = "Hun_LuanYing_P2_Buff_Montage",
    GA_Hun_Lute_AAA_C = "Hun_ShaChi_Lute_Attack_AAA_Montage", GA_Hun_Lute_AA_C = "Hun_ShaChi_Lute_Attack_AA_Montage",
    GA_Hun_Lute_A_C = "Hun_ShaChi_Lute_Attack_A_Montage", GA_Hun_Lute_SKill_C = "Hun_ShaChi_Lute_Skill_01_Start_Montage",
    GA_Hun_Mojian_AAA_C = "Hun_Shachi_MJZ_AAA_attack_Montage", GA_Hun_Mojian_AA_C = "Hun_Shachi_MJZ_AA_attack_Montage",
    GA_Hun_Mojian_A_C = "Hun_Shachi_MJZ_A_attack_Montage", GA_Hun_Mojian_A_Short_C = "Hun_Shachi_MJZ_A_Attack_Short_Montage1",
    GA_Hun_Mojian_UpRunGEx_01_C = "Hun_Shachi_MJZ_UpRunExecution_0_Montage", GA_Hun_PoJun_AAAA_C = "Hun_PoJun_Attack_AAAA_Montage",
    GA_Hun_PoJun_AAAB_C = "Hun_PoJun_Attack_AAAB_Montage", GA_Hun_PoJun_AAA_C = "Hun_PoJun_Attack_AAA_Montage",
    GA_Hun_PoJun_AAB_C = "Hun_PoJun_Attack_AAB_Montage", GA_Hun_PoJun_AA_C = "Hun_PoJun_Attack_AA_Montage",
    GA_Hun_PoJun_AB_C = "Hun_PoJun_Attack_AB_Montage", GA_Hun_PoJun_A_C = "Hun_PoJun_Attack_A_Montage",
    GA_Hun_PoJun_A_DashDraw_C = "Hun_PoJun_Attack_Draw_A_Montage", GA_Hun_PoJun_A_Dash_C = "Hun_PoJun_Dash_A_Montage",
    GA_Hun_PoJun_A_Draw_C = "Hun_PoJun_Attack_A_Montage", GA_Hun_PoJun_BB_C = "Hun_PoJun_Attack_BB_Montage",
    GA_Hun_PoJun_B_C = "Hun_PoJun_Attack_B_Montage", GA_Hun_PoJun_B_DashDraw_C = "Hun_PoJun_Attack_Draw_B_Montage",
    GA_Hun_PoJun_B_Dash_C = "Hun_PoJun_Attack_Dash_B_Montage", GA_Hun_PoJun_B_Draw_C = "Hun_PoJun_Attack_B_Montage",
    GA_Hun_PoJun_C_C = "Hun_PoJun_Attack_C_Montage", GA_Hun_PoJun_DB_02_C = "Hun_PoJun_Attack_CC_Montage",
    GA_Hun_PoJun_DB_C = "Hun_PoJun_SpecialSkill_01_Montage", GA_Hun_ShachiHook_CAA_C = "ShaChi_Hook_CAA_Montage",
    GA_Hun_ShachiHook_CA_C = "ShaChi_Hook_CA_Montage", GA_Hun_ShachiHook_CBB_C = "ShaChi_Hook_CBB_Montage",
    GA_Hun_ShachiHook_CB_C = "ShaChi_Hook_CB_Montage", GA_Hun_ShachiHook_CCCC_C = "ShaChi_Hook_CCCC_Montage",
    GA_Hun_ShachiHook_CCC_C = "ShaChi_Hook_CCC_Montage", GA_Hun_ShachiHook_CC_C = "ShaChi_Hook_CC_Montage",
    GA_Hun_ShachiHook_CDD_C = "ShaChi_Hook_CDD_Montage", GA_Hun_ShachiHook_CD_C = "ShaChi_Hook_CD_Montage",
    GA_Hun_ShachiHook_C_C = "ShaChi_Hook_C_Montage", GA_Hun_ShachiHook_Drag_C = "ShaChi_Hook_Skill_01_Montage",
    GA_Hun_ShachiHook_HookMove_C = "ShaChi_Hook_Skill_02_Start_Montage", GA_Hun_ShuangYue_AAAAAA_C = "Hun_ShuangYue_Attack_AAAAAA_Montage",
    GA_Hun_ShuangYue_AAAAA_C = "Hun_ShuangYue_Attack_AAAAA_Montage", GA_Hun_ShuangYue_AAAA_C = "Hun_ShuangYue_Attack_AAAA_Montage",
    GA_Hun_ShuangYue_AAABB_C = "Hun_ShuangYue_Attack_AAABB_Montage", GA_Hun_ShuangYue_AAAB_C = "Hun_ShuangYue_Attack_AAAB_Montage",
    GA_Hun_ShuangYue_AAA_C = "Hun_ShuangYue_Attack_AAA_Montage", GA_Hun_ShuangYue_AABB_C = "Hun_ShuangYue_Attack_AABB_Montage",
    GA_Hun_ShuangYue_AAB_C = "Hun_ShuangYue_Attack_AAB_Montage", GA_Hun_ShuangYue_AA_C = "Hun_ShuangYue_Attack_AA_Montage",
    GA_Hun_ShuangYue_ABB_C = "Hun_ShuangYue_Attack_ABB_Montage", GA_Hun_ShuangYue_AB_C = "Hun_ShuangYue_Attack_AB_Montage",
    GA_Hun_ShuangYue_A_C = "Hun_ShuangYue_Attack_A_Montage", GA_Hun_ShuangYue_A_DashDraw_C = "Hun_ShuangYue_Dash_A_Montage",
    GA_Hun_ShuangYue_A_Dash_C = "Hun_ShuangYue_Dash_A_Montage", GA_Hun_ShuangYue_A_Draw_C = "Hun_ShuangYue_Attack_A_Montage",
    GA_Hun_ShuangYue_BBBB_C = "Hun_ShuangYue_Attack_BBBB_Montage", GA_Hun_ShuangYue_BBB_C = "Hun_ShuangYue_Attack_BBB_Montage",
    GA_Hun_ShuangYue_BB_C = "Hun_ShuangYue_Attack_BB_Montage", GA_Hun_ShuangYue_B_C = "Hun_ShuangYue_Attack_B_Montage",
    GA_Hun_ShuangYue_B_DashDraw_C = "Hun_ShuangYue_Dash_B_Montage", GA_Hun_ShuangYue_B_Dash_C = "Hun_ShuangYue_Dash_B_Montage",
    GA_Hun_ShuangYue_B_Draw_C = "Hun_ShuangYue_Attack_B_Montage", GA_Hun_ShuangYue_C_C = "Hun_ShuangYue_Unique_Skill_Montage",
    GA_Hun_ShuangYue_DB_C = "Hun_ShuangYue_Skill_02_Montage", GA_Hun_ShuangYue_DB_SWT_C = "Hun_ShuangYue_Skill_02_Montage",
    GA_Hun_ShuangYue_PBB_C = "Hun_ShuangYue_Skill_03_Montage", GA_Hun_ShuangYue_PB_C = "Hun_ShuangYue_Skill_01_Montage",
    GA_Hun_ShuangYue_SWT_C = "Hun_ShuangYue_Skill_02_Montage", GA_Hun_SlitheringSword_AAAAA_C = "AM_Hun_SlitheringSword_AAAAA",
    GA_Hun_SlitheringSword_AAAA_C = "AM_Hun_SlitheringSword_AAAA", GA_Hun_SlitheringSword_AAABB_C = "AM_Hun_SlitheringSword_AAABB",
    GA_Hun_SlitheringSword_AAAB_C = "AM_Hun_SlitheringSword_AAAB", GA_Hun_SlitheringSword_AAA_C = "AM_Hun_SlitheringSword_AAA",
    GA_Hun_SlitheringSword_AABB_C = "AM_Hun_SlitheringSword_AABB", GA_Hun_SlitheringSword_AAB_C = "AM_Hun_SlitheringSword_AAB",
    GA_Hun_SlitheringSword_AA_C = "AM_Hun_SlitheringSword_AA", GA_Hun_SlitheringSword_ABB_C = "AM_Hun_SlitheringSword_ABB",
    GA_Hun_SlitheringSword_AB_C = "AM_Hun_SlitheringSword_AB", GA_Hun_SlitheringSword_A_C = "AM_Hun_SlitheringSword_A1",
    GA_Hun_SlitheringSword_A_DashDraw_C = "AM_Hun_SlitheringSword_A_DashDraw",
    GA_Hun_SlitheringSword_A_Dash_C = "AM_Hun_SlitheringSword_A_Dash", GA_Hun_SlitheringSword_BBB_C = "AM_Hun_SlitheringSword_BBB",
    GA_Hun_SlitheringSword_BB_C = "AM_Hun_SlitheringSword_BB", GA_Hun_SlitheringSword_B_C = "AM_Hun_SlitheringSword_B",
    GA_Hun_SlitheringSword_B_DashDraw_C = "AM_Hun_SlitheringSword_B_DashDraw",
    GA_Hun_SlitheringSword_B_Dash_C = "AM_Hun_SlitheringSword_B_Dash", GA_Hun_SlitheringSword_C_C = "AM_Hun_SlitheringSword_C_Normal",
    GA_Hun_SlitheringSword_DA_C = "AM_Hun_SlitheringSword_DA_Start",
    GA_Hun_SlitheringSword_DB4_C = "Hun_SoftSword_Stance_Attack_07_Montage",
    GA_Hun_SlitheringSword_DB5_C = "Hun_SoftSword_Stance_Attack_06_Montage",
    GA_Hun_SlitheringSword_EvalutionCombo_New_C = "Hun_SoftSword_Attack_01_Montage",
    GA_Hun_SlitheringSword_Potential_C = "Hun_SoftSword_Skill_03_Montage", GA_Hun_SlitheringSword_SWT_C = "AM_Hun_SlitheringSword_SWT",
    GA_Hun_SnakeDual_AAA_C = "AM_Hun_SnakeDual_AAA", GA_Hun_SnakeDual_AA_C = "AM_Hun_SnakeDual_AA",
    GA_Hun_SnakeDual_ABAA_C = "AM_Hun_SnakeDual_BA2", GA_Hun_SnakeDual_ABABAA_C = "AM_Hun_SnakeDual_AAAA",
    GA_Hun_SnakeDual_ABABA_C = "AM_Hun_SnakeDual_AA", GA_Hun_SnakeDual_ABABB_C = "AM_Hun_SnakeDual_BBBB",
    GA_Hun_SnakeDual_ABAB_C = "AM_Hun_SnakeDual_BABB", GA_Hun_SnakeDual_ABA_C = "AM_Hun_SnakeDual_AB2",
    GA_Hun_SnakeDual_ABB_C = "AM_Hun_SnakeDual_BB", GA_Hun_SnakeDual_AB_C = "AM_Hun_SnakeDual_AB1",
    GA_Hun_SnakeDual_A_C = "AM_Hun_SnakeDual_A", GA_Hun_SnakeDual_A_Dash_C = "AM_Hun_SnakeDual_A_Dash",
    GA_Hun_SnakeDual_A_Fast_C = "AM_Hun_SnakeDual_A", GA_Hun_SnakeDual_Air_A_Double_C = "Hun_Tang_JumpAttackB_Montage",
    GA_Hun_SnakeDual_Air_A_Draw_Double_C = "Hun_Tang_JumpAttackB_Montage",
    GA_Hun_SnakeDual_Air_B_Double_C = "Hun_Double_JumpAttackA_Montage",
    GA_Hun_SnakeDual_Air_B_Draw_Double_C = "Hun_Double_JumpAttackA_Montage", GA_Hun_SnakeDual_BAA_C = "AM_Hun_SnakeDual_BAA",
    GA_Hun_SnakeDual_BABAA_C = "AM_Hun_SnakeDual_BABA", GA_Hun_SnakeDual_BABABB_C = "AM_Hun_SnakeDual_BBBBB",
    GA_Hun_SnakeDual_BABAB_C = "AM_Hun_SnakeDual_BA1", GA_Hun_SnakeDual_BABA_C = "AM_Hun_SnakeDual_BAB",
    GA_Hun_SnakeDual_BABB_C = "AM_Hun_SnakeDual_BBBB", GA_Hun_SnakeDual_BAB_C = "AM_Hun_SnakeDual_BBB",
    GA_Hun_SnakeDual_BA_C = "AM_Hun_SnakeDual_AAA", GA_Hun_SnakeDual_BB_C = "AM_Hun_SnakeDual_BB",
    GA_Hun_SnakeDual_B_C = "AM_Hun_SnakeDual_B", GA_Hun_SnakeDual_B_Dash_C = "AM_Hun_SnakeDual_B_Dash",
    GA_Hun_SnakeDual_B_Fast_C = "AM_Hun_SnakeDual_B", GA_Hun_SnakeDual_C_C = "AM_Hun_SnakeDual_C",
    GA_Hun_SnakeDual_DA_C = "AM_Hun_SnakeDual_AA", GA_Hun_SnakeDual_DB_C = "AM_Hun_SnakeDual_BBBB",
    GA_Hun_SnakeDual_SWT_C = "AM_Hun_SnakeDual_SWT", GA_Hun_Tang_A_DashDraw_C = "AM_Hun_Tang_A_DashDraw",
    GA_Hun_Tang_Air_A_C = "Hun_Tang_JumpAttackB_Montage", GA_Hun_Tang_Air_A_Draw_C = "Hun_Tang_JumpAttackB_Montage",
    GA_Hun_Tang_Air_B_C = "Hun_Tang_JumpAttackA_Montage", GA_Hun_Tang_Air_B_Draw_C = "Hun_Tang_JumpAttackA_Montage",
    GA_Hun_Tang_B_DashDraw_C = "AM_Hun_Tang_B_DashDraw", GA_Hun_Tang_B_Draw_C = "AM_Hun_Tang_B_Draw",
    GA_Hun_Tang_SWT_UI_C = "AM_Hun_Tang_A_Draw", GA_Hun_WoodenSword_AAAAA_C = "Hun_WoodenSword_Light_AAAAA_Montage",
    GA_Hun_WoodenSword_AAAA_C = "Hun_WoodenSword_Light_AAAA_Montage", GA_Hun_WoodenSword_AAABB_C = "Hun_WoodenSword_AAABB_Montage",
    GA_Hun_WoodenSword_AAAB_C = "Hun_WoodenSword_AAAB_Montage", GA_Hun_WoodenSword_AAA_C = "Hun_WoodenSword_Light_AAA_Montage",
    GA_Hun_WoodenSword_AABB_C = "Hun_WoodenSword_AABB_Montage", GA_Hun_WoodenSword_AAB_C = "Hun_WoodenSword_AAAB_Montage",
    GA_Hun_WoodenSword_AA_C = "Hun_WoodenSword_Light_AA_Montage", GA_Hun_WoodenSword_ABB_C = "Hun_Young_AB_Montage",
    GA_Hun_WoodenSword_AB_C = "Hun_WoodenSword_ABB_Montage", GA_Hun_WoodenSword_A_C = "Hun_WoodenSword_Light_A_Montage",
    GA_Hun_WoodenSword_A_DashDraw_C = "Hun_WoodenSword_A_Dash_Montage", GA_Hun_WoodenSword_A_Dash_C = "Hun_WoodenSword_A_Dash_Montage",
    GA_Hun_WoodenSword_A_Draw_C = "Hun_WoodenSword_Light_A_Draw_Placeholder_Montage",
    GA_Hun_WoodenSword_Air_A_C = "Hun_WoodenSword_Tang_JumpAttackB_Montage",
    GA_Hun_WoodenSword_Air_A_Draw_C = "Hun_WoodenSword_Tang_JumpAttackB_Montage",
    GA_Hun_WoodenSword_Air_B_C = "Hun_WoodenSword_Tang_JumpAttackA_Montage",
    GA_Hun_WoodenSword_Air_B_Draw_C = "Hun_WoodenSword_Tang_JumpAttackA_Montage", GA_Hun_WoodenSword_BBB_C = "Hun_WoodenSword_BBB_Montage",
    GA_Hun_WoodenSword_BB_C = "Hun_WoodenSword_BB_Montage", GA_Hun_WoodenSword_B_C = "Hun_WoodenSword_B_Montage",
    GA_Hun_WoodenSword_B_DashDraw_C = "Hun_WoodenSword_B_DashDraw_Montage", GA_Hun_WoodenSword_B_Dash_C = "Hun_WoodenSword_B_Dash_Montage",
    GA_Hun_WoodenSword_B_Draw_C = "Hun_WoodenSword_B_Draw_Montage", GA_Hun_WoodenSword_C_C = "Hun_MaleThug_UniqueSkill_Montage",
    GA_Hun_WoodenSword_SWT_New_C = "AM_Hun_Tang_A_DashDraw", GA_Hun_XieShan_AAAAA_C = "Hun_ShanZi_AAAAA_Montage",
    GA_Hun_XieShan_AAAA_C = "Hun_ShanZi_AAAA_Montage", GA_Hun_XieShan_AAABB_C = "Hun_ShanZi_AAABB_Montage",
    GA_Hun_XieShan_AAAB_C = "Hun_ShanZi_AAAB_Montage", GA_Hun_XieShan_AAA_C = "Hun_ShanZi_AAA_Montage",
    GA_Hun_XieShan_AABB_C = "Hun_ShanZi_AABB_Montage", GA_Hun_XieShan_AAB_C = "Hun_ShanZi_AAB_Montage",
    GA_Hun_XieShan_AA_C = "Hun_ShanZi_AA_Montage", GA_Hun_XieShan_ABB_C = "Hun_ShanZi_ABB_Montage",
    GA_Hun_XieShan_AB_C = "Hun_ShanZi_AB_Montage", GA_Hun_XieShan_A_C = "Hun_ShanZi_A_Montage",
    GA_Hun_XieShan_A_DashDraw_New_C = "Hun_ShanZi_Dash_A_Montage", GA_Hun_XieShan_A_Dash_C = "Hun_ShanZi_Dash_A_Montage",
    GA_Hun_XieShan_A_Draw_New_C = "Hun_ShanZi_A_Montage", GA_Hun_XieShan_BBB_C = "Hun_ShanZi_BBB_Montage",
    GA_Hun_XieShan_BB_C = "Hun_ShanZi_BB_Montage", GA_Hun_XieShan_B_C = "Hun_ShanZi_B_Montage",
    GA_Hun_XieShan_B_DashDraw_New_C = "Hun_ShanZi_Dash_B_Montage", GA_Hun_XieShan_B_Dash_C = "Hun_ShanZi_Dash_B_Montage",
    GA_Hun_XieShan_B_Draw_New_C = "Hun_ShanZi_B_Montage", GA_Hun_XieShan_C_C = "Hun_ShanZi_Unique_Skill_Montage",
    GA_Hun_XieShan_DB_C = "Hun_ShanZi_Skill_05_Montage", GA_Hun_XieShan_SWT_02_C = "Hun_YuuBlade_Unique_Skill_03_Montage",
    GA_Hun_YanYueDao_AAAA_C = "Hun_YanYueDao_Attack_AAAA_Montage", GA_Hun_YanYueDao_AAA_C = "Hun_YanYueDao_Attack_AAA_Montage",
    GA_Hun_YanYueDao_AA_C = "Hun_YanYueDao_Attack_AA_Montage", GA_Hun_YanYueDao_A_C = "Hun_YanYueDao_Attack_A_Montage",
    GA_Hun_YanYueDao_A_Dash_C = "Hun_YanYueDao_Dash_A_Montage", GA_Hun_YanYueDao_BB_C = "Hun_YanYueDao_Attack_BB_Montage",
    GA_Hun_YanYueDao_B_C = "Hun_YanYueDao_Attack_B_Montage", GA_Hun_YanYueDao_B_Dash_C = "Hun_YanYueDao_Dash_B_Montage",
    GA_Hun_YanYueDao_B_Reinforced_C = "RTG_HUN_YuDing_Skill_05_FullEnd", GA_Hun_YanYueDao_C_C = "Hun_YanYueDao_Skill_03_Start_Montage",
    GA_Hun_YanYueDao_SWT_C = "Hun_YanYueDao_SimpleExE_Multi_01_Montage",
    GA_Hun_YanYueDao_SpecialSkill_C = "Hun_YanYueDao_Skill_01_A_Montage", GA_Hun_YuuBlade_AAAAA_C = "Hun_YuuBlade_AAAAAA_Montage",
    GA_Hun_YuuBlade_AAAAB_C = "Hun_YuuBlade_BBBB_Montage", GA_Hun_YuuBlade_AAAA_C = "Hun_YuuBlade_BBB_Montage",
    GA_Hun_YuuBlade_AAAB_C = "Hun_YuuBlade_AB_Montage", GA_Hun_YuuBlade_AAA_C = "Hun_YuuBlade_B_Montage",
    GA_Hun_YuuBlade_AAB_C = "Hun_YuuBlade_AAA_Montage", GA_Hun_YuuBlade_AA_C = "Hun_YuuBlade_AA_Montage",
    GA_Hun_YuuBlade_AB_C = "Hun_YuuBlade_BB_Montage", GA_Hun_YuuBlade_A_C = "Hun_YuuBlade_A_Montage",
    GA_Hun_YuuBlade_A_DashDraw_C = "Hun_YuuBlade_Dash_A_Montage", GA_Hun_YuuBlade_A_Dash_C = "Hun_YuuBlade_Dash_A_Montage",
    GA_Hun_YuuBlade_A_Draw_C = "Hun_YuuBlade_A_Montage", GA_Hun_YuuBlade_BBBB_C = "Hun_YuuBlade_AABB_Montage",
    GA_Hun_YuuBlade_BBB_C = "Hun_YuuBlade_AAAAAB_Montage", GA_Hun_YuuBlade_BB_C = "Hun_YuuBlade_AAAAA_Montage",
    GA_Hun_YuuBlade_B_C = "Hun_YuuBlade_ABB_Montage", GA_Hun_YuuBlade_B_DashDraw_C = "Hun_YuuBlade_Dash_B_Montage",
    GA_Hun_YuuBlade_B_Dash_C = "Hun_YuuBlade_Dash_B_Montage", GA_Hun_YuuBlade_B_Draw_C = "Hun_YuuBlade_ABB_Montage",
    GA_Hun_YuuBlade_C_C = "Hun_YuuBlade_Buff_Montage", GA_Hun_YuuBlade_FastHeavyAttack_C = "Hun_YuuBlade_Heavy_QuickSlash_Montage",
    GA_Hun_YuuBlade_FastLightAttack_C = "Hun_YuuBlade_Light_QuickSlash_Montage",
    GA_Hun_YuuBlade_SWT_C = "Hun_YuuBlade_Unique_Skill_03_Montage", GA_Hun_ZhanMa_AAAA_C = "Hun_WangMingZhanMaDao_Attack_AAAA_Montage",
    GA_Hun_ZhanMa_AAAB_C = "Hun_WangMingZhanMaDao_Attack_AAAB_Montage", GA_Hun_ZhanMa_AAA_C = "Hun_WangMingZhanMaDao_Attack_AAA_Montage",
    GA_Hun_ZhanMa_AAB_C = "Hun_WangMingZhanMaDao_Attack_AAB_Montage", GA_Hun_ZhanMa_AA_C = "Hun_WangMingZhanMaDao_Attack_AA_Montage",
    GA_Hun_ZhanMa_AB_C = "Hun_WangMingZhanMaDao_Attack_AB_Montage", GA_Hun_ZhanMa_A_C = "Hun_WangMingZhanMaDao_Attack_A_Montage",
    GA_Hun_ZhanMa_A_DashDraw_C = "Hun_Horizontal_A_Dash_Montage", GA_Hun_ZhanMa_A_Dash_C = "Hun_Horizontal_A_Dash_Montage",
    GA_Hun_ZhanMa_A_Draw_C = "Hun_WangMingZhanMaDao_Attack_A_Montage", GA_Hun_ZhanMa_Air_A_C = "Hun_Long_JumpAttackA_Montage",
    GA_Hun_ZhanMa_Air_A_Draw_C = "Hun_Long_JumpAttackA_Montage", GA_Hun_ZhanMa_Air_B_C = "Hun_Long_JumpAttackB_Montage",
    GA_Hun_ZhanMa_Air_B_Draw_C = "Hun_Long_JumpAttackB_Montage", GA_Hun_ZhanMa_BB_C = "Hun_WangMingZhanMaDao_Attack_BB_Montage",
    GA_Hun_ZhanMa_B_C = "Hun_WangMingZhanMaDao_Attack_B_Montage", GA_Hun_ZhanMa_B_DashDraw_C = "Hun_Horizontal_B_DashDraw_Montage",
    GA_Hun_ZhanMa_B_Dash_C = "Hun_Horizontal_B_Dash_Fixed_Montage", GA_Hun_ZhanMa_B_Draw_C = "Hun_WangMingZhanMaDao_Attack_B_Montage",
    GA_Hun_ZhanMa_C_C = "Hun_WangMingZhanMaDao_Unique_Skill_02_Montage", GA_Hun_ZhanMa_DB_C = "Hun_WangMingZhanMaDao_Skill_02_Montage",
    GA_Hun_ZhanMa_SA_C = "Hun_WangMingZhanMaDao_Skill_03_Montage", GA_Hun_ZhanMa_SWT_C = "Hun_Horizontal_SWT_Montage",
    GA_Hun_ZiMingJian_New_AAAAA_C = "Hun_ZiMing_AAAAA", GA_Hun_ZiMingJian_New_AAAA_C = "Hun_ZiMing_AAAA",
    GA_Hun_ZiMingJian_New_AAABB_C = "Hun_ZiMing_AAABB", GA_Hun_ZiMingJian_New_AAAB_C = "Hun_ZiMing_AAAB",
    GA_Hun_ZiMingJian_New_AAA_C = "Hun_ZiMing_AAA", GA_Hun_ZiMingJian_New_AABB_C = "Hun_ZiMing_AABB",
    GA_Hun_ZiMingJian_New_AAB_C = "Hun_ZiMing_AAB", GA_Hun_ZiMingJian_New_AA_C = "Hun_ZiMing_AA",
    GA_Hun_ZiMingJian_New_ABB_C = "Hun_ZiMing_ABB", GA_Hun_ZiMingJian_New_AB_C = "Hun_ZiMing_AB",
    GA_Hun_ZiMingJian_New_A_C = "Hun_ZiMing_A", GA_Hun_ZiMingJian_New_A_DashDraw_C = "Hun_ZiMing_A_Dash",
    GA_Hun_ZiMingJian_New_A_Dash_C = "Hun_ZiMing_A_Dash", GA_Hun_ZiMingJian_New_A_Draw_C = "Hun_ZiMing_A",
    GA_Hun_ZiMingJian_New_BBB_C = "Hun_ZiMing_BBB", GA_Hun_ZiMingJian_New_BB_C = "Hun_ZiMing_BB",
    GA_Hun_ZiMingJian_New_B_C = "Hun_ZiMing_B", GA_Hun_ZiMingJian_New_B_DashDraw_C = "Hun_ZiMing_B_Dash",
    GA_Hun_ZiMingJian_New_B_Dash_C = "Hun_ZiMing_B_Dash", GA_Hun_ZiMingJian_New_B_Draw_C = "Hun_ZiMing_B",
    GA_Hun_ZiMingJian_New_CCC_C = "Hun_ZiMing_Unique_Skill_B_Montage", GA_Hun_ZiMingJian_New_CC_C = "Hun_ZiMing_Unique_Skill_A_Montage",
    GA_Hun_ZiMingJian_New_C_C = "Hun_ZiMing_Unique_Skill_Montage", GA_Hun_ZiMingJian_New_DB_C = "Hun_ZiMing_Summon_Start_Montage",
    GA_Hun_ZiMingJian_New_SWT_Power_C = "Hun_ZiMing_SWT_Power", GA_JinGua_Air_C = "Hun_ShaChi_JinGua_SpecialAttack_08_Montage",
    GA_JinGua_ExtraAttack_C = "Hun_ShaChi_JinGua_Skill_05_Montage", GA_JinGua_Normal_C = "Hun_ShaChi_JinGua_SpecialAttack_03_Montage",
    GA_JinGua_RoAttack_C = "Hun_ShaChi_JinGua_Skill_06_Start_Montage", GA_LionHead_C = "AM_Hun_LionHead_Start_1",
    GA_LionHead_Dash_C = "Hun_LionDancer_Skill_02_Montage", GA_LionHead_DoubleFireBall_C = "Hun_LionDancer_Skill_01_Montage",
    GA_LionHead_FireBall_C = "Hun_LionDancer_Skill_01_Montage", GA_Lute_Dash_C = "Hun_ShaChi_Lute_Dash_B_Montage",
    GA_MiaoShouFeiDao_DB_C = "AM_Hun_Unarm_Dash_F", GA_MiaoShouFeiDao_Escape_01_C = "Hun_ShaChi_MiaoShouFeiDao_SpecialAttack_B_Montage",
    GA_MiaoShouFeiDao_Escape_02_C = "Hun_ShaChi_MiaoShouFeiDao_SpecialAttack_B_Montage",
    GA_MiaoShouFeiDao_Escape_03_C = "Hun_ShaChi_MiaoShouFeiDao_SpecialAttack_B_Montage",
    GA_MiaoShouFeiDao_Normal_01_C = "Hun_FeiZei_ZongHuoZei_Attack_01_Montage",
    GA_MiaoShouFeiDao_Normal_02_C = "Hun_FeiZei_NiShuiZei_Attack_01_Montage",
    GA_MiaoShouFeiDao_Normal_03_C = "Hun_FeiZei_NiShuiZei_Attack_01_Montage", GA_TanLang_ExtraAttack_C = "Hun_LangYa_Skill_01_A_Montage",
    GA_TanLang_Normal_C = "Hun_LangYa_Skill_01_Start_Montage", GA_TanLang_SpeicalAttack_C = "Hun_LangYa_Skill_02_Montage",
    GA_ThunderSpear_Dash_C = "Hun_ShaChi_LeiTingQiang_Skill_05_Montage",
    GA_ThunderSpear_DeflectCounter_C = "SpearMan_SpecialAttack_08_BanBen1_Montage",
    GA_ThunderSpear_DodgeAttack_01_C = "Hun_ShaChi_LeiTingQiang_Skill_04_Montage",
    GA_ThunderSpear_Normal_01_C = "Hun_ShaChi_LeiTingQiang_Skill_01_Montage",
    GA_ThunderSpear_Normal_02_C = "Hun_ShaChi_LeiTingQiang_Skill_02_Montage",
    GA_ThunderSpear_Normal_03_C = "Hun_ShaChi_LeiTingQiang_Skill_03_Montage",
    GA_ThunderSpear_SpecialAttack_04_C = "Hun_ShaChi_LeiTingQiang_Skill_06_BanBen01_Montage",
    GA_TieKuangQuanTao_Charge_AAA_C = "Hun_QuanTao_Attack_AAA_Montage", GA_TieKuangQuanTao_Charge_AA_C = "Hun_QuanTao_Attack_AA_Montage",
    GA_TieKuangQuanTao_Charge_A_C = "Hun_QuanTao_Attack_A_Montage", GA_TigerCannon_C = "AM_Hun_TigerCannon_Prepare",
    GA_TigerCannon_Dash_C = "Hun_ShaChi_DonCanon_SpecialSkill_01_Montage", GA_TigerCannon_Ultimate_C = "LeiDang_CriticalArt_02_Montage",
    GA_UnnamedBow_C = "AM_Hun_UnnamedBow_Charge", GA_UnnamedBow_Dash_C = "ArrowMan_DuYan_SpecialAttack_04_B_Montage",
    GA_UnnamedBow_DeflectCounter_C = "ArrowMan_DuYan_SpecialAttack_04_B_Montage", GA_XuKongHuaShan_Reborn_C = "AM_Hun_Tang_DF_L_ForReborn",
    GA_XuKongHuaShan_Skill_C = "Hun_Shaqi_ShanZi_Skill_01_Montage", GA_XueDiZi_AAA_C = "Hun_ShaChi_XueDiZi_Skill_01_C_Montage",
    GA_XueDiZi_AA_C = "Hun_ShaChi_XueDiZi_Skill_01_B_Montage", GA_XueDiZi_A_C = "Hun_ShaChi_XueDiZi_Skill_01_A1_Montage",
    GA_XueDiZi_EvolutionAttack_C = "Hun_ShaChi_XueDiZi_Variants_Skill_01_Montage",
    GA_XueDiZi_SpecialAttack_C = "Hun_ShaChi_XueDiZi_Skill_02_Montage", GA_YouLongCha_Dash_C = "Hun_ShaChi_YouLongCha_Skill_02_Montage",
    GA_YouLongCha_Normal_C = "Hun_ShaChi_YouLongCha_Attack_Montage",
    GA_YouLongHead_WaterCannon_C = "Hun_ShaChi_YouLongTou_Skill_01_Start_Montage",
    GA_YouLongHead_Water_C = "Hun_ShaChi_YouLongTou_Skill_01_Start_Montage", GA_ZhuoBiDun_C = "Hun_ShaChi_ZhuoBiDun_Entry_Montage",
    GA_ZhuoBiDun_Slide_C = "Hun_ShaChi_ZhuoBiDun_Skill_03_Montage",
}
-- §165.2 END

-- 受击 / 格挡 / 破防 / 闪避不是这一招的动作，不学
function ANIM.learn(ga, mon)
    if not (ga and mon and mon ~= "") then return end
    for _, k in ipairs({ "_Hit_", "Deflect", "MoTian_Dodge", "_Dead_" }) do
        if mon:find(k, 1, true) then return end
    end
    ANIM.map[ga] = mon
end

function ANIM.expect(ga) return ANIM.map[ga] or ANIM.SEED[ga] or ANIM.SEED2[ga] end

function ANIM.log(fmt, ...)
    ANIM.logs = ANIM.logs + 1
    if ANIM.logs <= ANIM.LOGS or ANIM.logs % 20 == 0 then out(fmt, ...) end
end

-- AIR.fire 放成功后：before = 放之前替身在播的动作名
function ANIM.afterFire(pup, e, before, tn)
    if not isAttackAbility(e.name) or e.name:find("_Air", 1, true) or CHG.isHold(e.name) then ANIM.pend = nil; return end
    ANIM.pend = { pup = pup, name = e.name, id = e.id, before = before, at = tn, stage = 1 }
end

-- 每次驱动：到点看一眼（没有等着的就什么都不读）
function ANIM.step(tn)
    local p = ANIM.pend
    if not p or tn - p.at < ANIM.CHECK then return end
    if not valid(p.pup) then ANIM.pend = nil; return end
    local an, _, name, pos = LAT.activeMontage(p.pup)
    if an and name and (name ~= p.before or (pos and pos < ANIM.FRESH)) then
        ANIM.pend = nil
        if p.stage == 1 then ANIM.st.ok = ANIM.st.ok + 1; ANIM.learn(p.name, name); return end
        ANIM.st.retryOk = ANIM.st.retryOk + 1
        ANIM.learn(p.name, name)
        ANIM.log("  ◇ 远端#%d %s 重放后换上了 %s", p.id, p.name, name)
        return
    end
    if not (activeAbilities(p.pup) or {})[p.name] then        -- 招已经收了（短招、被打断）
        ANIM.pend = nil
        if p.stage == 1 then ANIM.st.ended = ANIM.st.ended + 1
        else ANIM.st.fail = ANIM.st.fail + 1; ANIM.log("  ◇ 远端#%d %s 重放后技能没挂上，动作也没有", p.id, p.name) end
        return
    end
    local want = ANIM.expect(p.name)
    if p.stage == 1 then
        ANIM.st.stuck = ANIM.st.stuck + 1
        if not want then
            ANIM.pend = nil
            if not ANIM.unknown[p.name] then
                ANIM.unknown[p.name] = true
                out("◇ 远端#%d %s 放成功 %.2f 秒，替身动作还是 %s；不知道这招该播什么，不补", p.id, p.name, tn - p.at, tostring(name))
            end
            return
        end
        local cut = name and cutMontage(p.pup)
        local gone = G.cancelMoves(p.pup)
        -- §165.3 大招补放会再耗一格充能，替身只有 1 格 → 播 C_Failed（黑魔伤 C1 实测）；补放前再补一格
        -- §165.7 只补"对方确认放成功、发来过的那一招"，每个招式号只补一次（ULT.okFor）
        if ULT.isUlt(p.name) then
            if ULT.okFor(p.id, p.name) then ULT.topUp(p.pup)
            else ANIM.pend = nil; out("◇ 远端#%d %s 不是对方确认过的大招，不补放", p.id, p.name); return end
        end
        local ok = activateOnPuppet(p.pup, p.name, NET.sub, "补放 远端#" .. p.id)
        ANIM.log("◇ 远端#%d %s 放成功 %.2f 秒，替身动作还是 %s（该是 %s）：停掉 %s、取消 %s，重放 %s", p.id, p.name, tn - p.at,
            tostring(name), want, tostring(cut), #gone > 0 and table.concat(gone, ",") or "无", ok and "成功" or "失败")
        if ok then p.stage, p.at, p.before = 2, tn, nil; return end
    end
    ANIM.pend = nil       -- 重放也没换上（或重放失败）：直接播
    local okP = playNamed(p.pup, want)
    if okP then ANIM.st.playOk = ANIM.st.playOk + 1 else ANIM.st.fail = ANIM.st.fail + 1 end
    ANIM.log("  ◇ 远端#%d %s 还是没动作 → 直接播 %s：%s", p.id, p.name, want, okP and "已播" or "失败")
end

function ANIM.report()
    local s = ANIM.st
    if s.stuck == 0 then return end
    out("      放招没换动作 %d 次（正常 %d，招自己收了 %d）：重放补上 %d，直接播 %d，没补上 %d", s.stuck, s.ok, s.ended,
        s.retryOk, s.playOk, s.fail)
end

-- 判定窗口跟着替身的动作（v0.27.1，§78.5）：炽刃大招出手 2–3.8 秒后才扣血，1.2 秒的窗口把它判成落空。
-- 过了 JUDGE_WIN、替身还在播为这一招开的蒙太奇（LAT.byId 记的那个）就继续等，最多 JUDGE_MAX 秒
LAT.JUDGE_MAX = 5.0
function LAT.stillPlaying(id, age, pupMontage)
    local want = LAT.byId[id]
    return want ~= nil and age < LAT.JUDGE_MAX and want == pupMontage
end

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
ULT.PAT, ULT.HOLD_TICKS, ULT.held, ULT.dropped, ULT.topped =
    { "_C_C$", "_C_Air_C$", "^GA_Hun_HeiMoShang_C1_C$", "^GA_Hun_Jade_C_Range_C$", "^GA_Hun_LuanYing_P?2?_?CA_C$" }, 3, {}, 0, 0

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
    BAL.noteStance(BAL.myStance, n, tn)             -- §186.3 我放的这招在架势里 → 回报按强化版的系数（和对方替身那边一样）
    NET.evBal = NET.evBal or {}
    NET.evBal[NET.evId], NET.evBal[NET.evId - 300] = BAL.resolve(n, BAL.myStance, tn), nil
    if TOUCH then TOUCH.noteFire(n, tn) end         -- §207 本地 AI：L1+圈 窗口
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
-- 协议以前只发"开始"（ev=编号:技能名）。按住蓄力、松手出招的招读的是游戏自己的输入系统（SGameInputComponent：
-- IsHolding / GetHoldTime / HoldingInputs；技能任务 OnRelease / OnEarlyRelease / OnSuccessHold），替身是 AIController，
-- 身上没有这个组件（18:29 实测：实例只挂在玩家1、玩家1的控制器、武器上）。实测替身三种表现（HANDOVER §92.3）：
--   一直等松手：长兵 / 残钢 BCharge、鬼头 B_Hold_Start、灵蛇 DA——蓄力动作播完（2–3.6 秒）也不出招，按住 0.3 / 2.0 秒一模一样
--   自己马上松手：炽刃大招 C_C 0.87 秒切 _Release、风雷剑 B_Hold 1.56 秒切 _End，按多久都一样
--   本来就在动作里出伤害：斩马刀 DB（1.38 秒打中）
-- 做法：
--   发：我放的蓄力招，松手那一刻 rel=<招式号>:<按了几秒>（和 ev= 一样重发 REL_KEEP 秒）。松手 = 开始时按着的输入
--       （玩家输入组件的 HoldingInputs）都松开了；读不到输入时退回：换到 *Release* / *_End* 动作，或这招的技能结束
--   收：替身照对方按的秒数（从替身放出这招算起）松手。"一直等松手"那几招（WAIT）替身还在这招的蓄力动作上 → 停掉动作
--       （对方松手后出的那一刀是另一个技能，会作为下一个 ev= 到，照常放）；别的蓄力招不碰
--   判定窗口：蓄力招等到松手后 JUDGE_WIN 秒（对方是新版、还没收到 rel= 时一直等，最多 JUDGE_MAX 秒）；
--       替身还在播为这一招开过的任何动作（蓄力 / _Release / _End）也接着等。灵蛇 Potential 的伤害本来就在 2.3–2.9 秒（LATE）
--   追帧：蓄力招不追（跳前摇会把蓄力段跳乱）
-- 探针（第 1 步）照留：每条结束时一行"蓄力探针 #k …"，最多 LOGS 条。全局：主代码块 local 已满
CHG = { DUR = 5.0, QUIET = 0.6, AB_EVERY = 0.1, LOGS = 40, SPEC_LOGS = 8, EV_MAX = 40, n = 0, specN = 0, probed = false, list = {},
        REL_KEEP = 2.0, JUDGE_MAX = 8.0, NO_REL_WAIT = 6.0, HOLD_DIAG = 30, SELF_MAX = 6.0, compDiag = 0,
        out = {},          -- 我发的松手：{ id, secs, at }
        rel = {},          -- 对方的松手：远端招式号 → 秒数
        fired = {},        -- 替身放出对方蓄力招：远端招式号 → { at, name, mon = { 动作名 = true }, first = 第一个动作, done }
        peerRel = false,   -- 对方发过 rel=（新版）
        holdDiag = 0, relN = 0, cutN = 0,
        NOT_TRIGGER = { "Move", "Look", "Camera", "Mouse", "Sprint", "Run", "Walk", "Lock", "Target" },
        -- 资产里用 IsHolding / OnRelease / Ability Input Component / Input System 的技能（类名 = 资产名 + _C）
        HOLD = { GA_Hun_SlitheringSword_DA_C = 1, GA_Hun_PoJun_DB_C = 1, GA_Hun_BronzeSword_B_Hold_C = 1,
                 GA_Hun_Horizontal_BladeWave_C = 1, GA_Hun_YanYueDao_SpecialSkill_C = 1, GA_Hun_Long_BCharge_C = 1,
                 GA_Hun_ChiRen_C_C = 1, GA_Hun_GuiTouBlade_B_Hold_Start_C = 1, GA_Hun_GuiTouBlade_B_Hold_C = 1,
                 GA_Hun_ZiMingJian_New_DB_C = 1, GA_Hun_Iron_BCharge_C = 1, GA_Hun_FengLeiJian_B_Hold_C = 1,
                 GA_Hun_ZhanMa_DB_C = 1, GA_Hun_XieShan_DB_C = 1, GA_ThunderSpear_Normal_01_C = 1, GA_ThunderSpear_Normal_02_C = 1,
                 GA_ThunderSpear_Normal_03_C = 1, GA_TanLang_Normal_C = 1, GA_TigerCannon_C = 1, GA_DuYan_Bow_Laser_C = 1,
                 GA_DuYan_Bow_Normal_C = 1, GA_BrutalAxe_Normal_C = 1, GA_Hun_Lute_SKill_C = 1, GA_JianKeZhaoJiLing_Normal_01_C = 1,
                 GA_ZhuoBiDun_C = 1, GA_JinGua_Air_C = 1, GA_JinGua_RoAttack_C = 1, GA_JinGua_Normal_C = 1,
                 GA_Hun_HuoLiuXing_AAAA_C = 1, GA_YouLongHead_Water_C = 1, GA_XueSeLingDang_Normal_01_C = 1,
                 GA_YouLongCha_Normal_C = 1, GA_HuangJinHuoChong_Normal_02_C = 1, GA_HuangJinHuoChong_Normal_04_C = 1,
                 GA_UnnamedBow_C = 1, GA_KuYeSiZhuChuan_Normal_01_C = 1, GA_CaoOuSiXian_Normal_01_C = 1, GA_LionHead_C = 1 },
        PAT = { "Charge", "Hold" }, SKIP = { "Passive", "HoldDeflect" },  -- 名字带 Charge / Hold 的（铁矿拳套 Charge_A 继承 ChargeBase、邪扇 DB_*FullCharge…）
        -- 18:29 实测替身自己永远不松手的（蓄力动作播完也不出招）：对方松手时替身停掉蓄力动作
        WAIT = { GA_Hun_Long_BCharge_C = 1, GA_Hun_Iron_BCharge_C = 1, GA_Hun_GuiTouBlade_B_Hold_Start_C = 1,
                 GA_Hun_SlitheringSword_DA_C = 1 },
        -- 不是蓄力招、伤害来得晚（子弹）：判定窗口至少开这么久。灵蛇 Potential 17:04:08 在 2.3 / 2.6 / 2.9 秒扣血
        LATE = { GA_Hun_SlitheringSword_Potential_C = 3.3 },
        PROBE = { GA_Hun_SlitheringSword_Potential_C = 1 } }     -- 探针对照（不是蓄力招，只记时间线）

-- §92.7 替身放不出 / 放出来马上没了的招：对方能放 = 对方有这把武器的升级（GE 给的 CharacterState.WeaponUpgrade.* 标签），
-- 替身没有。资产扫描（技能名字表里的升级标签 ↔ UpgradeData 里给这个标签的 GE）：
--   UPG：放不出时给替身上对应的升级 GE 再放一次（每个替身每个 GE 一次）。18:30 / 18:48 青铜剑 B_Hold 两次返回 false，
--        §87.2 妖锯 FastHeavyAttack、双钩 PerfectDodge_HeavyAttack 返回 false，都是这一类
--   PRE：放之前先给（灵蛇 Potential 是升级被动 GA_SlitheringSword_Passive 攒"潜能"后放的；替身只有光秃秃的 Potential，
--        一放就结束，18:31:11 / 18:48:49 动作 0.02 秒就没了）。放的时候记一下被动上的潜能值（前 POT_LOGS 次）
function CHG.ge(dir, name, sub)       -- 升级 GE 的类路径（主代码块 local 已满，挂在 CHG 上）；sub 默认 UpgradeData（§159 双月 / 破军是 WeaponUpgrade）
    return "/PBZCombatAsset/ActorData/Players/Hun/Weapon/" .. dir .. "/" .. (sub or "UpgradeData") .. "/" .. name .. "." .. name .. "_C"
end
CHG.UPG = {
    GA_Hun_BronzeSword_B_Hold_C = { CHG.ge("BronzeSword", "GE_Weapon_BronzeSword_BHold") },
    GA_Hun_BronzeSword_BA_C = { CHG.ge("BronzeSword", "GE_Weapon_BronzeSword_Nsp") },
    GA_Hun_BronzeSword_Stance_C = { CHG.ge("BronzeSword", "GE_Weapon_BronzeSword_DfB") },
    GA_Hun_Chaos_B_Hold_Fire_C = { CHG.ge("ChaosBlade", "GE_Weapon_ChaosBlade_Lv25") },
    GA_Hun_Chaos_B_Hold_Ice_C = { CHG.ge("ChaosBlade", "GE_Weapon_ChaosBlade_Lv15") },
    GA_Hun_Chaos_B_Hold_Physics_C = { CHG.ge("ChaosBlade", "GE_Weapon_ChaosBlade_Lv5") },
    GA_Hun_YuuBlade_FastHeavyAttack_C = { CHG.ge("YuuBlade", "GE_YaoJu_Upgrade_FastHeavyAttack") },
    GA_Hun_DualHook_PerfectDodge_HeavyAttack_C = { CHG.ge("DualHook", "GE_DualHook_Evolution") },
    GA_Hun_DualHook_PerfectDodge_GEx_C = { CHG.ge("DualHook", "GE_DualHook_Evolution") },
    -- §159 进阶冲刺：双月的要 CharacterState.WeaponUpgrade.ShuangYue.CanSwiftDash（升级 GE 在 WeaponUpgrade/，不在 UpgradeData/）；
    -- 玉双环的名字表里有 Jade.EnableDA（DefaultDash / GhostDash 两个升级都给，取 DefaultDash）
    GA_Hun_AdvancedDash_ShuangYue_C = { CHG.ge("ShuangYue", "GE_ShuangYue_ChargeSpeed_CanSwiftDash", "WeaponUpgrade") },
    GA_Hun_AdvancedDash_Double_Jade_C = { CHG.ge("JadeDualChakram", "GE_Jade_Upgrade_DefaultDash") },
}
CHG.DASH_CD = "/PBZCombatAsset/Prototypes/GameplayEffects/GE_DashCooldown.GE_DashCooldown_C"     -- §159
CHG.PRE = {
    GA_Hun_SlitheringSword_Potential_C = { CHG.ge("SlitheringSword", "GE_SlitheringSword_GrantPotential"),
                                           CHG.ge("SlitheringSword", "GE_SlitheringSword_EnablePotentialEnergy") },
}
CHG.applied, CHG.POT_LOGS, CHG.potN = {}, 10, 0

-- 给替身上 list 里的升级 GE（同一个替身同一个 GE 只上一次）。返回这次有没有新上的
function CHG.upgrade(pup, name, list)
    local any = false
    for _, ge in ipairs(list or {}) do
        local key = pathOf(pup) .. "|" .. ge
        if not CHG.applied[key] then
            CHG.applied[key] = true
            any = true
            LO.applyGE(pup, ge, "替身补武器升级 " .. ge:match("([%w_]+)_C$") .. "（" .. name .. "）")
        end
    end
    return any
end

-- 替身放 Potential 前后：升级被动在不在、潜能多少（诊断）
function CHG.potDiag(pup, when)
    if CHG.potN >= CHG.POT_LOGS then return end
    CHG.potN = CHG.potN + 1
    local v, from = G.abilityField(pup, "GA_SlitheringSword_Passive_C", "SlitheringSword_PotentialEnergy")
    out("灵蛇潜能 %s：被动 GA_SlitheringSword_Passive %s，SlitheringSword_PotentialEnergy = %s", when, from, tostring(v))
end

function CHG.isHold(n)
    if CHG.HOLD[n] then return true end
    for _, s in ipairs(CHG.SKIP) do if n:find(s, 1, true) then return false end end
    for _, p in ipairs(CHG.PAT) do if n:find(p, 1, true) then return true end end
    return false
end

-- 要不要记：蓄力招，或探针对照
function CHG.watched(n) return CHG.isHold(n) or CHG.PROBE[n] ~= nil end

function CHG.reset()
    CHG.out, CHG.rel, CHG.fired, CHG.peerRel = {}, {}, {}, false
end

-- 开始记一条。who = "我" / "替身"；id = 招式号（我的 = 发出去的编号，大招压着还没发时是 nil，发的时候 CHG.onEmit 补；替身的 = 远端编号）
function CHG.watch(actor, who, name, tn, id)
    local keep = {}
    for _, w in ipairs(CHG.list) do        -- 同一个人放了下一招：上一条到此为止（我的那条要是还没松手，按现在算松手）
        if w.who == who then
            if who == "我" then CHG.release(w, tn, "放了下一招") end
            CHG.finish(w, tn, "放了下一招 " .. name)
        else keep[#keep + 1] = w end
    end
    if not CHG.isHold(name) and CHG.n >= CHG.LOGS then CHG.list = keep; return end   -- 对照招只为日志记
    local w = { actor = actor, who = who, name = name, id = id, at = tn, last = tn, abAt = -100, ev = {} }
    if CHG.n < CHG.LOGS then
        CHG.n = CHG.n + 1
        w.k = CHG.n
        if CHG.specN < CHG.SPEC_LOGS then
            CHG.specN = CHG.specN + 1
            w.spec0, w.specAt = G.specInput(actor, name), tn + 0.4      -- 0.4 秒后再看一次（多半还按着）
        end
    end
    if CHG.isHold(name) and CHG.compDiag < 6 then
        CHG.compDiag = CHG.compDiag + 1
        out("蓄力探针 输入组件（%s %s）：%s", who, name, G.inputCompInfo(actor))
    end
    if who == "我" and CHG.isHold(name) then
        w.hold = true
        local h, why = G.holdingInputs(actor)
        w.h0 = CHG.trigger(h)                              -- 开始时按着的（去掉移动 / 视角）；空 / 读不到 → 退回看动作 / 技能
        CHG.diag(h, why, "开始 " .. name)
    end
    keep[#keep + 1] = w
    CHG.list = keep
end

-- 出这招的那几个键：开始时按着的输入里去掉移动 / 视角类的（一边跑一边蓄力时移动键一直按着）。没有剩下的 → nil
function CHG.trigger(h)
    if not h then return nil end
    local t = nil
    for k in pairs(h) do
        local skip = false
        for _, p in ipairs(CHG.NOT_TRIGGER) do if k:find(p, 1, true) then skip = true end end
        if not skip then t = t or {}; t[k] = true end
    end
    return t
end

function CHG.diag(h, why, what)
    local key = what:match("(%S+)$") or what
    CHG.diagBy = CHG.diagBy or {}
    if CHG.holdDiag >= CHG.HOLD_DIAG or (CHG.diagBy[key] or 0) >= 6 then return end      -- 每招开始 / 松开各 3 次
    CHG.holdDiag, CHG.diagBy[key] = CHG.holdDiag + 1, (CHG.diagBy[key] or 0) + 1
    local names = {}
    for k in pairs(h or {}) do names[#names + 1] = k end
    table.sort(names)
    out("蓄力松手：%s 时按着的输入 %s", what, h and (#names > 0 and table.concat(names, ",") or "（空）") or ("读不到：" .. tostring(why)))
end

-- 大招压着、过几帧才发（ULT.flushHeld）：发出去时把招式号补给还没号的那条
function CHG.onEmit(n, id)
    for _, w in ipairs(CHG.list) do
        if w.who == "我" and w.name == n and not w.id then
            w.id = id
            if w.relAt then CHG.out[#CHG.out + 1] = { id = id, secs = w.relAt - w.at, at = w.relAt } end    -- 发之前已经松手
        end
    end
end

-- 我这边松手：记下，状态包带 rel=（招式号还没有的——大招没发出去——不发）
function CHG.release(w, tn, why)
    if not w.hold or w.relAt then return end
    w.relAt, w.relWhy = tn, why
    CHG.note(w, tn, "松手（" .. why .. "）")
    if w.id then CHG.out[#CHG.out + 1] = { id = w.id, secs = tn - w.at, at = tn } end
end

-- 状态包字段（没有就空串）
function CHG.wire(tn)
    while #CHG.out > 0 and tn - CHG.out[1].at > CHG.REL_KEEP do table.remove(CHG.out, 1) end
    if #CHG.out == 0 then return "" end
    local s = {}
    for _, r in ipairs(CHG.out) do s[#s + 1] = string.format("%d:%.2f", r.id, r.secs) end
    return "rel=" .. table.concat(s, ",") .. "\n"
end

-- 收包：rel=<远端招式号>:<秒>,...（旧版没有这个字段 → 什么都不做）
function CHG.onPacket(t, tn)
    if not t.rel then return end
    CHG.peerRel = true
    for id, secs in t.rel:gmatch("(%d+):([%d%.]+)") do
        id, secs = tonumber(id), tonumber(secs)
        if CHG.rel[id] == nil then
            CHG.rel[id] = secs
            CHG.rel[id - 300] = nil
            CHG.relN = CHG.relN + 1
            local f = CHG.fired[id]
            if CHG.relN <= 30 then
                out("蓄力松手：远端#%d %s 对方按了 %.2f 秒%s", id, f and f.name or "?", secs,
                    f and string.format("（替身放出 %.2f 秒，%s）", tn - f.at, CHG.WAIT[f.name] and "到点停蓄力" or "替身自己出招") or "（替身没放这招）")
            end
        end
    end
end

-- 替身放出对方的蓄力招（AIR.fire 放成功时）
function CHG.onFire(pup, e, tn)
    CHG.fired[e.id] = { at = tn, name = e.name, mon = {} }
    CHG.fired[e.id - 300] = nil
end

-- §92.8 "自己马上松手"的蓄力招（18:47–18:50 实测替身 0.85–0.94 / 1.56–1.58 秒就出招，对方按 0.3 秒、2.0 秒都一样）：
-- 替身的蓄力动作播到 at 秒（自己出招之前）就暂停，对方松手的秒数到了（或换了动作 / SELF_MAX 秒）再继续。
-- 只对发 rel= 的新版对方（旧版永远等不到松手）。只管出招时机：蓄力等级（炽刃 ChargeCount C1–C3、风雷剑 End_Success / End_Fail）
-- 是技能里按 IsHolding 算的，替身没有输入组件，暂停改变不了，还是最低一级（HANDOVER §92.8）
-- §139.5 独眼弓 R2：替身的技能拉弓 1.7 秒自己射（10:08 蓄力探针 Charge → 1.70 Shoot_Normal，那时 2 根箭），
-- 拉弓到 1.55 秒停住等对方松手（BOWN 先播瞄准动作、松手再放的做法替身手里没弓，已关）
CHG.SELF = { GA_Hun_ChiRen_C_C = { mon = "Hun_ZhiRen_Unique_Skill_01_Montage", at = 0.75 },
             GA_Hun_FengLeiJian_B_Hold_C = { mon = "Hun_BaiShanDual_Hold_B_02_Montage", at = 1.45 },
             GA_DuYan_Bow_Normal_C = { mon = "AM_Hun_UnnamedBow_Charge", at = 1.55 } }
CHG.selfN = 0

function CHG.selfLog(fmt, ...)
    CHG.selfN = CHG.selfN + 1
    if CHG.selfN <= 40 then out(fmt, ...) end
end

function CHG.selfStep(pup, id, f, tn)
    local sc = CHG.SELF[f.name]
    if not sc or f.selfOff or not CHG.peerRel or not valid(pup) then return end
    local secs = CHG.rel[id]
    local due = secs and tn >= f.at + secs
    local _, _, m, pos = LAT.activeMontage(pup)
    if f.paused then
        if due or m ~= sc.mon or tn - f.at > CHG.SELF_MAX then
            if f.name == BOWN.NAME then BOWN.aimNow(pup, tn) end     -- §139.5 R2：松手射之前转到对方的镜头朝向
            local ok = G.montagePause(pup, false)
            f.paused, f.selfOff = false, true
            CHG.selfLog("蓄力等松手：远端#%d %s 替身停了 %.2f 秒，%s → 继续 %s", id, f.name, tn - f.pausedAt,
                due and string.format("对方按了 %.2f 秒", secs) or (m ~= sc.mon and ("动作换成 " .. tostring(m) .. "（暂停没拦住？）") or "等太久"),
                ok and "成功" or "失败")
        end
    elseif m == sc.mon and pos and pos >= sc.at then
        if due then f.selfOff = true; return end            -- 对方早松手了：不停
        local ok = G.montagePause(pup, true)
        if ok then f.paused, f.pausedAt = true, tn else f.selfOff = true end
        CHG.selfLog("蓄力等松手：远端#%d %s 替身蓄力动作到 %.2f 秒 → 暂停 %s（对方%s）", id, f.name, pos, ok and "成功" or "失败",
            secs and string.format("按了 %.2f 秒", secs) or "还没松手")
    elseif m and m ~= sc.mon and f.first then
        f.selfOff = true                                    -- 已经自己出招了（对方松手早于 at 秒）
    end
end

-- §139 独眼弓激光（GA_DuYan_Bow_Laser_C，L1 + R2 / 先按住右键再按 Ctrl）：光束每段 2 秒（CostBulletInstanceDuration），
-- 技能变量 CostBulletRemainTime 倒数到 0 时看还按没按着，按着就再耗一段接着照。替身没有输入，第一段照完（约 2.6 秒）就收——
-- 2026-11-07 01:41 实测：替身和我的技能变量一模一样（0.7 秒时 LaserRiseCurrentDuration 0.69 / 0.72、RemainTime 1.31 / 1.28），
-- 只是我按了 3.8 秒、替身照 2 秒；每发只吃到一段伤害。（之前试过补播光束动作 / 调 SpawnLoopLaserNS：不加伤害；光柱后来按 §139.1 补回来）
-- 做法：对方还按着时，替身激光技能的 CostBulletRemainTime 低于 LOW 就写回 FILL，倒数到不了 0；对方松手到点写 0，让它照常收
-- 01:47 实测：续 RemainTime 读回都对，替身技能还是 2.6 秒收——另一个计时是 LaserRiseCurrentDuration（光束升起，LaserRiseDuration
-- = 2.0）：我自己按 3.8 秒时它涨到 3.8，替身到 2 秒左右没按着就收。所以它也往回拨（超过 RISE_HI 写回 RISE_TO）。
-- 替身身上的动作：对方进光束时照播 AM_Hun_UnnamedBow_Loop（sub=，同 §111 紫冥剑召唤的技能内动作），松手那一箭照播 Shoot_Normal
-- 04:30 实验 3 之后：续计时 / 造输入状态都走不通（§140），改成替身每照完一段、对方还按着就再放一次：每段前面有约 0.7 秒拉弓，
-- 伤害一段一段的。剩下不到 RECAST_MIN 秒不再续；一发最多续 RECAST_MAX 次
-- §143 泥头车（马车）：替身没有按键，GA_HorseCart_Charge_C 永远等不到松手——15:12 实测替身一直挂着这个技能、悬在半空
-- （AM_DriveHorseCart 播完车没了人还在驾车状态），之后的招全部返回 false，对方看着就是"飞天、出招看不见、打不到"。
-- 对方松手到点（rel=）就把替身的这个技能 K2_CancelAbility、放回走路；旧版对方没有 rel=：放出 MAX 秒还挂着也取消。
-- 撞人：这招不在 pbz_abilities 表里、名字又带 Charge_C，以前不算攻击招 → 撞到你不开判定窗口，伤害不算（isAttackAbility 认它）
CHG.VEHICLE = { names = { GA_HorseCart_Charge_C = 1 }, MAX = 8.0, logN = 0 }

function CHG.vehicleOff(pup, id, f, tn, why)
    if f.vehOff then return end
    f.vehOff = true
    local gone = G.cancelAbilities(pup, function(n) return n == f.name end)
    local landed = #gone > 0 and G.hover(pup, false)
    if CHG.VEHICLE.logN < 30 then
        CHG.VEHICLE.logN = CHG.VEHICLE.logN + 1
        out("马车：远端#%d %s 放出 %.2f 秒，%s → 替身取消技能 %s%s", id, f.name, tn - f.at, why,
            #gone > 0 and table.concat(gone, ",") or "（已经没在放）", landed and "，放回走路" or "")
    end
end

CHG.LASER = { name = "GA_DuYan_Bow_Laser_C", var = "CostBulletRemainTime", LOW = 0.6, FILL = 1.0, EVERY = 0.1, max = 15.0, logN = 0,
              RECAST_MIN = 1.2, RECAST_MAX = 8, BEAM_AT = 0.6, beamLogN = 0,
              rise = "LaserRiseCurrentDuration", RISE_HI = 1.6, RISE_TO = 1.2,
              loop = "AM_Hun_UnnamedBow_Loop", shoot = "AM_Hun_UnnamedBow_Shoot_Normal" }

-- 发：我这一帧的动作 m（上一帧 prev）要不要当激光的技能内动作发：进光束、光束后松手那一箭
function CHG.isLaserSub(m, prev)
    return m == CHG.LASER.loop or (m == CHG.LASER.shoot and prev == CHG.LASER.loop)
end

-- 收：sub= 里的动作是不是激光的
function CHG.isLaserIn(m)
    return m == CHG.LASER.loop or m == CHG.LASER.shoot
end

-- §140 输入状态同步第 1 步：只读探针（玩家进光束时、替身放激光 0.3 秒时各记一次，最多 PROBE_MAX 次；函数表只在头一次）
CHG.LASER.probeN, CHG.LASER.PROBE_MAX = 0, 14
function CHG.holdProbe(actor, who)
    if CHG.LASER.probeN >= CHG.LASER.PROBE_MAX then return end
    CHG.LASER.probeN = CHG.LASER.probeN + 1
    for _, l in ipairs(G.holdTaskProbe(actor, who, CHG.LASER.probeN <= 2) or {}) do out("输入探针：%s", l) end
end

-- §140 第 2 步实验：替身放名单里的招之前给它"按着"对应的键（G.inputEnsure / inputHold），对方松手到点松开。
-- 关掉：net/inp_off.txt。实验开着时激光不再续计时（看替身自己会不会照到松手）
-- 04:30 实验 3：组件、技能变量、Controller、按住都接上了，替身的等松手任务还是不建（多半要玩家控制器），实验先关（KEYS 空）
INP = { KEYS = {},     -- 实验时：GA_DuYan_Bow_Laser_C = "/PBZInput/InputActions/IA_ShachiAbility_Hold.IA_ShachiAbility_Hold"
        OFF_FILE = (NET_DIR or "net") .. "/inp_off.txt", logN = 0, held = {} }

function INP.log(fmt, ...)
    INP.logN = INP.logN + 1
    if INP.logN <= 60 then out(fmt, ...) end
end

function INP.off()
    local f = io.open(INP.OFF_FILE, "r")
    if f then f:close(); return true end
    return false
end

-- 放之前：名单里的招 → 替身按住这招的键。返回 是否按上了
function INP.press(pup, name, id)
    local ia = INP.KEYS[name]
    if not ia or INP.off() then return false end
    local comp, how = G.inputEnsure(pup)
    if how ~= "已有" then INP.log("输入实验：替身输入组件 %s", tostring(how)) end
    if not comp then return false end
    local r, isH = G.inputHold(comp, ia, true, G.worldTime(pup) or 0.0)     -- 值 = 按下时的世界时间（同玩家）
    INP.held[id] = { comp = comp, ia = ia }
    INP.log("输入实验：远端#%d %s 放之前替身按住 %s：%s，IsHolding → %s", id, name, ia:match("([%w_]+)$"), r, tostring(isH))
    return isH == true
end

-- 对方松手到点 → 替身松开
function INP.release(id, why)
    local h = INP.held[id]
    if not h then return end
    INP.held[id] = nil
    local r, isH = G.inputHold(h.comp, h.ia, false)
    INP.log("输入实验：远端#%d 替身松开（%s）：%s，IsHolding → %s", id, why, r, tostring(isH))
end

function CHG.laserLog(fmt, ...)
    CHG.LASER.logN = CHG.LASER.logN + 1
    if CHG.LASER.logN <= 40 then out(fmt, ...) end
end

-- 这一招最多等多久（判定窗口 / 记录保留）
function CHG.maxAge(name)
    return name == CHG.LASER.name and CHG.LASER.max or CHG.JUDGE_MAX
end

-- 替身还在播光束动作（Loop 自己不停）就收掉
function CHG.laserStopLoop(pup)
    if valid(pup) and montageOf(pup) == CHG.LASER.loop then return cutMontage(pup) end
    return nil
end

-- 每帧（隔 EVERY 秒读一次）：替身放的激光，对方还按着就续，松手到点收
function CHG.laserStep(pup, id, f, tn)
    local L = CHG.LASER
    if f.name ~= L.name or f.laserDone or tn < (f.laserAt or 0) then return end
    f.laserAt = tn + L.EVERY
    for oid, of in pairs(CHG.fired) do if oid > id and of.name == f.name then f.laserDone = true; return end end  -- 已经放了下一发
    local inst = valid(pup) and LO.activeInstance(pup, L.name)
    local secs = CHG.rel[id]
    -- 对方那边已经射出光束后那一箭（松手或暗源用完都会）也算到点：暗源先用完、键还按着时 rel= 会晚到
    local over = (secs and tn >= f.at + secs) or f.shotAt ~= nil or tn - f.at > L.max
    if inst then
        f.seen = true
        if over then                       -- 对方松手到点：本段照完前收掉
            local ok = pcall(function() inst[L.var] = 0.0 end)
            f.laserDone = true
            CHG.laserStopLoop(pup)
            CHG.laserLog("独眼弓激光：远端#%d 对方%s → 替身光束收（%s 写 0 %s，%.2f 秒，续放 %d 次）", id,
                secs and string.format("按了 %.2f 秒", secs) or "按太久", L.var, ok and "成功" or "失败", tn - f.at, f.recastN or 0)
        elseif not CHG.laserBeamAlive(f) and tn - (f.waitAt or f.at) >= L.BEAM_AT then
            CHG.laserBeamOn(pup, id, f, inst)      -- §139.1 这一段拉弓完了：补上弓射出的光柱
        end
        return
    end
    -- 技能没了：对方还按着、剩下的够再照一段 → 再放一次（§140 实验 3 结论：替身走不了"按着"那条路，只能一段一段续）
    local left = secs and (f.at + secs - tn) or (L.max - (tn - f.at))
    if f.seen and not over and left >= L.RECAST_MIN and (f.recastN or 0) < L.RECAST_MAX then
        f.recastN = (f.recastN or 0) + 1
        local okR = activateOnPuppet(pup, f.name, NET.sub, "远端#" .. id .. " 激光续放")
        CHG.laserLog("独眼弓激光：远端#%d 替身照完一段（%.2f 秒），对方还按着（%s）→ 续放第 %d 次 %s", id, tn - f.at,
            secs and string.format("一共按 %.2f 秒，还剩 %.2f", secs, left) or "还没松手", f.recastN, okR and "成功" or "失败")
        if okR then f.seen, f.waitAt = false, tn; return end
    end
    if over then CHG.laserStopLoop(pup) end
    if f.seen or tn - (f.waitAt or f.at) > 1.0 then        -- 刚放出来时技能可能还没挂上，等 1 秒
        f.laserDone = true
        if f.recastN then CHG.laserLog("独眼弓激光：远端#%d 替身激光结束（%.2f 秒，续放 %d 次）", id, tn - f.at, f.recastN) end
    end
end

-- §139.1 激光柱：真人的激光 = 弓射出的一道持续光柱 + 两只眼睛按节奏打；替身只有眼睛（伤害也是眼睛打的）。
-- 每段拉弓完让替身的激光技能自己调 SpawnLoopLaserNS 生成光柱（01:40 试过：调用成功、光柱一直挂着不收——技能在光柱自己的
-- RemoveLaserNS 之前就结束了），所以光柱归这一发管：每帧对准你（锁定点），对方松手 / 下一发 / 结束时模组自己收掉。
-- 段与段之间光柱还在就接着用，不重复生成
CHG.LASER.beams = {}

function CHG.laserBeamAlive(f)
    for _, c in ipairs(f.beam or {}) do if valid(c) then return true end end
    return false
end

-- 光柱对准的点：你的锁定点（别人锁你时镜头 / 子弹对着的点），没有就你身上往上 50
function CHG.laserAimAt()
    local p1 = getP1()
    if not valid(p1) then return nil end
    local comp = rawProp(p1, "LockViewTarget")
    local a = valid(comp) and try("laser aim", function() return comp:K2_GetComponentLocation() end)
    if a then return a end
    local l = try("laser aim", function() return p1:K2_GetActorLocation() end)
    return l and { X = l.X, Y = l.Y, Z = l.Z + 50 } or nil
end

function CHG.laserBeamOn(pup, id, f, inst)
    local L = CHG.LASER
    local comps, info = G.laserBeamSpawn(inst)
    L.beamLogN = L.beamLogN + 1
    local names = {}
    for _, c in ipairs(comps or {}) do names[#names + 1] = shortName(full(c)) end
    if not comps or #comps == 0 then
        f.beam = {}
        if L.beamLogN <= 20 then out("独眼弓激光：远端#%d 替身光柱生成失败（%s）", id, comps and "没找到组件" or tostring(info)) end
        return
    end
    f.beam = comps
    L.beams[id] = f
    local n = BOWAIM.aimBeam(pup, comps)
    if L.beamLogN <= 20 then
        out("独眼弓激光：远端#%d 替身光柱 %s（%s），转向 %d/%d", id, table.concat(names, ","), tostring(info), n, #comps)
    end
    CHG.laserEmitOn(pup, id, f, inst)        -- §139.7 光柱的伤害
end

-- §139.7 光柱的伤害：替身技能的子弹数据 CreateBullet 生成伤害发射器（见 G.laserEmitterSpawn），每帧跟着光柱挪 / 转，
-- 收光柱时一起收。关掉：net/emit_off.txt
CHG.LASER.EMIT_OFF = (NET_DIR or "net") .. "/emit_off.txt"
CHG.LASER.emitLogN = 0

function CHG.laserEmitLog(fmt, ...)
    CHG.LASER.emitLogN = CHG.LASER.emitLogN + 1
    if CHG.LASER.emitLogN <= 40 then out(fmt, ...) end
end

-- 光柱现在的位置和朝向（第一根光柱组件；朝向 = 对方镜头 / 对准你）
function CHG.laserBeamPose(pup, f)
    local c = f.beam and f.beam[1]
    local at = c and valid(c) and try("beam loc", function() return c:K2_GetComponentLocation() end)
    local r = not NET.rlk and BOWAIM.peer(now())
    if not r and at then
        local me = CHG.laserAimAt()
        if me then
            local dx, dy, dz = me.X - at.X, me.Y - at.Y, me.Z - at.Z
            r = { Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), Yaw = math.deg(math.atan(dy, dx)) }
        end
    end
    return at, r or { Pitch = 0, Yaw = 0 }
end

function CHG.laserEmitOn(pup, id, f, inst)
    local fh = io.open(CHG.LASER.EMIT_OFF, "r")
    if fh then fh:close(); return end
    local at, r = CHG.laserBeamPose(pup, f)
    local e, how = G.laserEmitterSpawn(inst, pup, at, r)
    f.emitter = e
    CHG.laserEmitLog("独眼弓激光：远端#%d 替身光柱伤害发射器 %s（%s）", id, e and G.emitterInfo(e) or "没生成", tostring(how))
    CHG.laserEyesOn(pup, id, f, inst)        -- §139.8
end

-- §139.8 眼睛：激光技能资产引用子弹数据 BD_DuYan_Bow_Eye 和武器升级标签 CharacterState.WeaponUpgrade.DuYanBow.LaserEyes
-- （用户：光柱出来后召唤两只眼睛按节奏打）。替身照发射器的办法用它生成（CreateBullet + Initialize + Start），收光柱时一起收。
-- 日志记你和替身有没有这个标签（11:30 都读不到，先不按它开关）
CHG.LASER.EYE_BD = "/PBZCombatAsset/ActorData/Players/Hun/BulletData/DuYanBow/BD_DuYan_Bow_Eye.BD_DuYan_Bow_Eye"
CHG.LASER.EYE_TAG = "CharacterState.WeaponUpgrade.DuYanBow.LaserEyes"
CHG.LASER.EYES = 2

function CHG.hasTag(actor, tag)
    if not valid(actor) then return false end
    for _, t in ipairs(tagsOf(actor) or {}) do if t == tag then return true end end
    return false
end

-- 12:03 实测：2 只生成在同一点，叠成一只；约 2 秒就结束（状态 3）而光柱还在照 → 一左一右（替身右手方向 ±EYE_SIDE、往上 EYE_UP）生成，
-- 都没了而光柱还在就再生成（CHG.laserBeamStep）。返回 最后一次的说明
-- 12:1x 用户：往上 110 时眼睛约 4 米高、比原版高太多（眼睛自己还往上飘）→ 往下 60（替身位置是胶囊中心，约在腰）
CHG.LASER.EYE_SIDE, CHG.LASER.EYE_UP = 90.0, -60.0

function CHG.laserEyesSpawn(pup, f, inst, bd)
    local L = CHG.LASER
    local loc = try("pup loc", function() return pup:K2_GetActorLocation() end)
    if not loc then return "读不到替身位置" end
    local _, r = CHG.laserBeamPose(pup, f)
    local y = math.rad(r.Yaw or 0)
    local rx, ry = -math.sin(y), math.cos(y)
    local how
    for i = 1, L.EYES do
        local side = (i == 1) and 1 or -1
        local at = { X = loc.X + rx * L.EYE_SIDE * side, Y = loc.Y + ry * L.EYE_SIDE * side, Z = loc.Z + L.EYE_UP }
        local e, h = G.laserEmitterSpawn(inst, pup, at, r, bd)
        if e then f.eyes[#f.eyes + 1] = e end
        how = h
    end
    f.eyeBD = bd
    return how
end

-- 眼睛都没了（无效或状态不是 2）
function CHG.laserEyesGone(f)
    for _, e in ipairs(f.eyes or {}) do
        if valid(e) and rawProp(e, "BulletStatus") == 2 then return false end
    end
    return true
end

-- §139.9 对方的光柱有没有眼睛（点没点 LaserEyes 升级）：对方进光柱 1 秒后数自己名下的眼睛子弹，状态包 eye=1 / 0（还没数过 "-"）。
-- 替身：eye=0 不生成、已经生成的收掉；eye=1 / 没有这个字段（旧版 / 还没数过）照生成
BOWEYE = { CLS = "BP_DuYanBow_Bullet_Eye_C", AFTER = 1.0 }

-- 发
function BOWEYE.wire(p1, tn)
    if NET.hrPrev == CHG.LASER.loop then
        BOWEYE.loopAt = BOWEYE.loopAt or tn
        if not BOWEYE.checked and tn - BOWEYE.loopAt >= BOWEYE.AFTER and valid(p1) then
            BOWEYE.checked = true
            local was = NET.myEyes
            NET.myEyes = G.countBullets(BOWEYE.CLS, p1) > 0
            if was ~= NET.myEyes then out("独眼弓：我的光柱%s眼睛（发 eye=%s）", NET.myEyes and "有" or "没有", NET.myEyes and "1" or "0") end
        end
    else
        BOWEYE.loopAt, BOWEYE.checked = nil, false
    end
    if NET.myEyes == nil then return "-" end
    return NET.myEyes and "1" or "0"
end

-- 收
function BOWEYE.recv(v)
    if v == "1" then NET.reye = true elseif v == "0" then NET.reye = false else NET.reye = nil end
end

function CHG.laserEyesOn(pup, id, f, inst)
    local L = CHG.LASER
    if NET.reye == false then
        CHG.laserEmitLog("独眼弓激光：远端#%d 对方的光柱没有眼睛（eye=0）→ 替身不生成", id)
        return
    end
    local hasP, hasMe = CHG.hasTag(pup, L.EYE_TAG), CHG.hasTag(getP1(), L.EYE_TAG)
    -- 11:30 实测：你和替身都读不到这个标签，可你自己放激光时有眼睛 → 标签读法 / 开关不对，先不看标签、每次都生成

    local bd = LO.geClass(L.EYE_BD)
    if not bd then CHG.laserEmitLog("独眼弓激光：远端#%d 眼睛子弹数据加载不了", id); return end
    -- 11:4x 用户：只出来 1 只（真人 2 只）、朝天上射（同 §119 火枪：替身瞄准组件没锁目标）→ 生成 2 只；
    -- 眼睛在的时候替身瞄准组件锁你（对方没锁你时光柱收了就撤，同火枪）
    local tn = now()
    ZMX.p1Lock(false, "独眼弓眼睛"); ZMX.p1LockUntil = tn + L.max
    local tc = LO.targetingComp(pup)
    if tc then ZMX.tcLock(tc); if not NET.rlk then ZMX.tcUnlockAt = tn + L.max end end
    f.eyes, f.eyesAt = {}, tn
    local how = CHG.laserEyesSpawn(pup, f, inst, bd)
    CHG.laserEmitLog("独眼弓激光：远端#%d 替身眼睛 %d/%d 只（%s；瞄准组件%s；你%s眼睛升级）", id, #f.eyes, L.EYES, tostring(how),
        tc and "锁你" or "没有", hasMe and "有" or "没有")
end

function CHG.laserEmitOff(id, f, why)
    if f.eyes and not NET.rlk then ZMX.p1LockUntil, ZMX.tcUnlockAt = 0, now() end   -- §139.8 眼睛收了：撤掉锁你
    for _, e in ipairs(f.eyes or {}) do G.destroyActor(e) end      -- §139.8
    f.eyes = nil
    if not f.emitter then return end
    local info = G.emitterInfo(f.emitter)
    local ok = G.destroyActor(f.emitter)
    f.emitter = nil
    CHG.laserEmitLog("独眼弓激光：远端#%d 收伤害发射器（%s）%s：收之前 %s", id, why, ok and "成功" or "失败", info)
end

function CHG.laserBeamOff(id, f, why)
    local L = CHG.LASER
    local n = G.destroyComps(f.beam)
    CHG.laserEmitOff(id, f, why)             -- §139.7
    f.beam, L.beams[id] = nil, nil
    L.beamLogN = L.beamLogN + 1
    if L.beamLogN <= 20 then out("独眼弓激光：远端#%d 替身光柱收（%s，收了 %d 个）", id, why, n) end
end

-- 每帧：光柱对准你；这一发收了 / 记录没了 / 替身没了就收光柱
function CHG.laserBeamStep(pup)
    local L = CHG.LASER
    for id, f in pairs(L.beams) do
        if CHG.fired[id] ~= f then CHG.laserBeamOff(id, f, "记录没了")
        elseif f.laserDone or not valid(pup) then CHG.laserBeamOff(id, f, f.laserDone and "这一发收了" or "替身没了")
        else
            BOWAIM.aimBeam(pup, f.beam)
            -- §139.9 对方说他的光柱没有眼睛：收掉
            if f.eyes and NET.reye == false then
                for _, e in ipairs(f.eyes) do G.destroyActor(e) end
                f.eyes = nil
                CHG.laserEmitLog("独眼弓激光：远端#%d 对方的光柱没有眼睛（eye=0）→ 收掉替身的眼睛", id)
            end
            -- §139.8 眼睛都没了、光柱还在 → 再生成一对（真人按着时一直有眼睛）
            if f.eyes and f.eyeBD and now() - (f.eyesAt or 0) > 0.5 and CHG.laserEyesGone(f) then
                local inst = LO.activeInstance(pup, CHG.LASER.name)
                if inst then
                    for _, e in ipairs(f.eyes) do G.destroyActor(e) end
                    f.eyes, f.eyesAt = {}, now()
                    f.eyesN = (f.eyesN or 1) + 1
                    local how = CHG.laserEyesSpawn(pup, f, inst, f.eyeBD)
                    if f.eyesN <= 3 then CHG.laserEmitLog("独眼弓激光：远端#%d 眼睛没了、光柱还在 → 第 %d 对 %d 只（%s）", id, f.eyesN, #f.eyes, tostring(how)) end
                end
            end
            if f.emitter then                 -- §139.7 发射器跟着光柱（位置 + 朝向）
                local at, r = CHG.laserBeamPose(pup, f)
                local okM = G.moveEmitter(f.emitter, at, r)
                if not okM and not f.emitMoveErr then f.emitMoveErr = true; CHG.laserEmitLog("独眼弓激光：远端#%d 发射器跟着光柱挪失败", id) end
            end
        end
    end
end

-- §139.3 独眼弓的瞄准：09:16 实测真人的光柱朝向 = 镜头朝向（俯仰 / 左右都跟，P5 Y44 → P14 Y22 → P6 Y108…；角色左右也跟镜头）。
-- 所以放独眼弓（我的动作带 UnnamedBow）时状态包带 aim=<俯仰>:<左右>（镜头），对方替身的光柱照这个朝向转、
-- 替身控制器也转过去（R2 那一箭 / 眼睛按控制器朝向瞄）。没收到 aim=（旧版 / 没在放）就照旧对准你
BOWAIM = { KEEP = 0.5 }

function BOWAIM.norm(a) a = a % 360; if a > 180 then a = a - 360 end; return a end

-- 发
function BOWAIM.wire()
    if not (type(NET.hrPrev) == "string" and NET.hrPrev:find("UnnamedBow", 1, true)) then return "-" end
    local pc = getP1PC()
    if not valid(pc) then return "-" end
    local ok, r = pcall(function() return pc:GetControlRotation() end)
    if not (ok and r) then return "-" end
    return string.format("%.1f:%.1f", BOWAIM.norm(r.Pitch), BOWAIM.norm(r.Yaw))
end

-- 收
function BOWAIM.recv(v, tn)
    local p, y = tostring(v or ""):match("^(%-?[%d.]+):(%-?[%d.]+)$")
    if p then NET.raim, NET.raimAt = { Pitch = tonumber(p), Yaw = tonumber(y) }, tn end
end

-- 对方的瞄准（KEEP 秒内收到过的）
function BOWAIM.peer(tn)
    if NET.raim and tn - (NET.raimAt or -99) <= BOWAIM.KEEP then return NET.raim end
    return nil
end

-- 光柱按对方镜头朝向转（替身控制器也转过去）；对方锁定着你（lk=1，真人的光柱对着锁定目标）或没收到 aim= 就对准你
function BOWAIM.aimBeam(pup, comps)
    local r = not NET.rlk and BOWAIM.peer(now())
    if r then
        if valid(pup) then G.setControlRot(pup, r) end
        local n = G.rotateComps(comps, r)
        -- 10:0x 用户：光柱连续了但不跟着扫。看写进去的朝向读回来对不对（对 = 特效本身不认组件朝向）
        BOWAIM.diagN = (BOWAIM.diagN or 0) + 1
        if BOWAIM.diagN % 30 == 1 and BOWAIM.diagN < 600 then
            out("独眼弓瞄准：光柱写 (P%.0f Y%.0f) %d 个，读回 %s；替身朝向 %s", r.Pitch, r.Yaw, n,
                G.compRotStr(comps[1]), G.compRotStr(pup))
        end
        return n
    end
    return G.aimComps(comps, CHG.laserAimAt())
end

-- §139.3 独眼弓 R2（GA_DuYan_Bow_Normal_C）：按住是瞄准（Combat Aiming=true、走路速度 300，09:16 探针），松手才射。
-- 替身没有输入，一放就射。改成：对方按住期间替身只播瞄准动作，收到对方松手（rel=）再放这招，放之前控制器转到对方的镜头朝向
BOWN = { NAME = "GA_DuYan_Bow_Normal_C", AIM_MON = "AM_Hun_UnnamedBow_Charge", MAX = 6.0, wait = {}, logN = 0, ON = false,
         REL_FN = "OnRelease_613C82514C82F322FA98A9B9A7C5EC90", REL_TRY = false }
-- 10:0x 用户：R2 按得越久箭越多（1 → 3 根），替身每次只射 1 根。技能变量里没有档位（09:16 探针），多半是松手事件
-- OnRelease_<guid>(TimeHeld) 按按住时长定几根；替身走的是 OnAlreadyRelease。实验：替身放出来后马上调 OnRelease(对方按的秒数)
-- 09:55 实测：调用成功，但一根箭都没了（不调时 1 根、能打中）→ 先关掉（REL_TRY），箭数另查

function BOWN.log(fmt, ...)
    BOWN.logN = BOWN.logN + 1
    if BOWN.logN <= 40 then out(fmt, ...) end
end

-- AIR.fire 一开头问：这一发要不要先等松手（要等就记下、播瞄准动作，返回 true）
-- fire = AIR.fire（AIR 在后面才定义，这里拿不到）
function BOWN.defer(pup, e, tn, fire)
    if not BOWN.ON or e.name ~= BOWN.NAME or e.bownGo or not CHG.peerRel or CHG.rel[e.id] then return false end
    BOWN.wait[e.id] = { e = e, at = tn, fire = fire }
    local ok = playNamed(pup, BOWN.AIM_MON)
    BOWN.log("独眼弓 R2：远端#%d 对方按住瞄准 → 替身先播瞄准动作 %s，等松手再射", e.id, ok and "成功" or "失败")
    return true
end

-- §139.5 替身转到对方的镜头朝向（对方锁定着你就不转，锁定会对准你）
function BOWN.aimNow(pup, tn)
    local r = not NET.rlk and BOWAIM.peer(tn)
    if r and valid(pup) then G.setControlRot(pup, r); setYaw(pup, r.Yaw) end
    BOWN.log("独眼弓 R2：替身松手射，瞄 %s", r and string.format("P%.0f Y%.0f", r.Pitch, r.Yaw) or (NET.rlk and "对方锁定着你" or "没收到 aim="))
end

function BOWN.step(p1, pup, tn)
    for id, w in pairs(BOWN.wait) do
        local secs = CHG.rel[id]
        if secs or tn - w.at > BOWN.MAX or not valid(pup) then
            BOWN.wait[id] = nil
            if valid(pup) then
                if montageOf(pup) == BOWN.AIM_MON then cutMontage(pup) end
                local r = not NET.rlk and BOWAIM.peer(tn)
                if r then G.setControlRot(pup, r); setYaw(pup, r.Yaw) end
                w.e.bownGo = true
                local ok = w.fire(p1, pup, w.e, tn)
                local rel = "没调"
                if ok and secs and BOWN.REL_TRY then
                    local inst = LO.activeInstance(pup, BOWN.NAME)
                    if inst then
                        local okR, errR = LO.callArgs(inst, BOWN.REL_FN, secs)
                        rel = okR and string.format("调 OnRelease(%.2f) 成功", secs) or ("调 OnRelease 失败 " .. tostring(errR):sub(-80))
                    else rel = "技能已经没在放" end
                end
                BOWN.log("独眼弓 R2：远端#%d %s → 替身射 %s（瞄 %s；%s）", id,
                    secs and string.format("对方按了 %.2f 秒", secs) or "等太久", ok and "成功" or "失败",
                    r and string.format("P%.0f Y%.0f", r.Pitch, r.Yaw) or (NET.rlk and "对方锁定着你" or "没收到 aim="), rel)
            end
        end
    end
end

-- 每帧：替身按对方的秒数松手；"一直等松手"的招还在蓄力动作上就停掉
function CHG.pupStep(pup, tn)
    for id, f in pairs(CHG.fired) do
        CHG.selfStep(pup, id, f, tn)
        CHG.laserStep(pup, id, f, tn)       -- §139
        local secs = CHG.rel[id]
        if CHG.VEHICLE.names[f.name] and valid(pup) then
            if secs and tn >= f.at + secs then CHG.vehicleOff(pup, id, f, tn, string.format("对方按了 %.2f 秒", secs))
            elseif not secs and tn - f.at > CHG.VEHICLE.MAX then CHG.vehicleOff(pup, id, f, tn, "没等到松手") end
        end
        if not f.done and secs and tn >= f.at + secs then
            f.done = true
            if CHG.WAIT[f.name] and valid(pup) then
                local m = montageOf(pup)
                if f.first and m == f.first then
                    local stopped = cutMontage(pup)
                    CHG.cutN = CHG.cutN + 1
                    if CHG.cutN <= 30 then
                        out("蓄力松手：远端#%d %s 替身按 %.2f 秒松手（晚 %.2f 秒）→ 停掉蓄力动作 %s", id, f.name, secs,
                            tn - f.at - secs, tostring(stopped))
                    end
                end
            end
        elseif f.at and tn - f.at > CHG.maxAge(f.name) + 2 then CHG.fired[id] = nil end
    end
end

-- 判定窗口过了 JUDGE_WIN 时（netJudge）：这一招还要不要等。j = { id, at, name }，pupM = 替身现在的动作
function CHG.keepJudge(j, tn, pupM)
    local age = tn - j.at
    local late = j.name and CHG.LATE[j.name]
    if late and age < late then return true end
    if not (j.name and CHG.isHold(j.name)) or age > CHG.maxAge(j.name) then return false end
    local f = CHG.fired[j.id]
    if f and pupM and pupM ~= "" and f.mon[pupM] then return true end     -- 替身还在播这一招的动作（蓄力 / 出招）
    local secs = CHG.rel[j.id]
    if secs then return age < secs + JUDGE_WIN end
    if j.name == CHG.LASER.name then return CHG.peerRel end               -- §139 激光对方按多久照多久（maxAge 封顶）
    return CHG.peerRel and age < CHG.NO_REL_WAIT                          -- 新版对方：还没松手，接着等
end

function CHG.note(w, tn, s)
    if #w.ev < CHG.EV_MAX then w.ev[#w.ev + 1] = string.format("%.2f %s", tn - w.at, s) end
end

function CHG.spec(s)
    if not s then return "（找不到这一格）" end
    return string.format("InputID %s 按下 %s 激活 %s", tostring(s.id), tostring(s.pressed), tostring(s.active))
end

function CHG.finish(w, tn, why)
    if not w.k then return end
    out("蓄力探针 #%d %s %s%s：%s；输入 %s → 0.4 秒后 %s；结束 %.2f 秒（%s）", w.k, w.who, w.name,
        w.id and string.format("（%s#%d）", w.who == "替身" and "远端" or "本机", w.id) or "",
        #w.ev > 0 and table.concat(w.ev, "，") or "（没变化）",
        w.spec0 ~= nil and CHG.spec(w.spec0) or "（没查）", w.spec1 ~= nil and CHG.spec(w.spec1) or "（没查）", tn - w.at, why)
end

-- §139.2 只读探针（独眼弓两招）：你和替身放独眼弓激光 / R2 普通招时，每 0.5 秒记一次技能变量、子弹和光柱朝向、你的镜头朝向，
-- 查：光柱伤害从哪来、单发激光的眼睛、光柱朝向怎么定、R2 蓄力的档位存在哪。最多 BOWP.MAX 行，函数表每招只在头一次
BOWP = { NAMES = { "GA_DuYan_Bow_Laser_C", "GA_DuYan_Bow_Normal_C" }, EVERY = 0.5, MAX = 160, n = 0, at = 0, fn = {},
         PROPS = { "Bullet", "Laser", "Lazer", "Charge", "Hold", "Time", "Level", "Damage", "Eye", "Summon", "Aim", "Niagara", "Cost", "Rise", "Count", "Stage" },
         OBJS = { "BulletInstance", "BulletData", "LaserNS", "LazerNSSystem" }, since = {} }

function BOWP.rot(o)
    local ok, r = pcall(function() return o:K2_GetComponentRotation() end)
    if not (ok and r) then ok, r = pcall(function() return o:K2_GetActorRotation() end) end
    return ok and r and string.format("(P%.0f Y%.0f)", r.Pitch, r.Yaw) or "?"
end

function BOWP.str(v) return type(v) == "table" and table.concat(v, " ") or tostring(v) end

function BOWP.one(actor, who, tn)
    for _, name in ipairs(BOWP.NAMES) do
        local inst = valid(actor) and LO.activeInstance(actor, name)
        local key = who .. name
        if not inst then BOWP.since[key] = nil
        else
            BOWP.since[key] = BOWP.since[key] or tn
            BOWP.n = BOWP.n + 1
            if not BOWP.fn[name] then
                BOWP.fn[name] = true
                out("独眼弓探针：%s 技能函数 %s", name, BOWP.str(LO.funcsLike(inst, ".")))
            end
            local objs = {}
            for _, k in ipairs(BOWP.OBJS) do
                local v = rawProp(inst, k)
                if v ~= nil then objs[#objs + 1] = k .. "=" .. (valid(v) and (shortName(full(v)) .. BOWP.rot(v)) or "空") end
            end
            local cam = ""
            if who == "我" then
                local okR, r = pcall(function() return getP1PC():GetControlRotation() end)
                cam = okR and r and string.format("，镜头 (P%.0f Y%.0f)", r.Pitch, r.Yaw) or ""
            end
            out("独眼弓探针：%s %s %.1f 秒：%s；%s；角色朝向 %s%s", who, name, tn - BOWP.since[key],
                BOWP.str(LO.propsLike(inst, name == "GA_DuYan_Bow_Normal_C" and { "" } or BOWP.PROPS)), table.concat(objs, " "), BOWP.rot(actor), cam)
        end
    end
end

-- 光柱伤害发射器（我自己按住时的 BulletInstance = BP_PBZ_ProjectileEmitter_C）的类链、函数、全部变量：看怎么给替身也生成一个
function BOWP.dumpEmitter(bi)
    BOWP.biDone = true
    local chain, c = {}, nil
    local okC, cls = pcall(function() return bi:GetClass() end)
    c = okC and cls or nil
    for _ = 1, 8 do
        if not valid(c) then break end
        chain[#chain + 1] = full(c)
        local okS, sup = pcall(function() return c:GetSuperStruct() end)
        c = okS and sup or nil
    end
    out("独眼弓探针：发射器 %s 类链 %s", full(bi), table.concat(chain, " < "))
    out("独眼弓探针：发射器函数 %s", BOWP.str(LO.funcsLike(bi, ".")))
    out("独眼弓探针：发射器变量 %s", BOWP.str(LO.propsLike(bi, { "" })))
    for _, k in ipairs({ "Owner", "Instigator", "BulletData", "Data", "OwnerAbility", "Ability", "Target", "AttachParent" }) do
        local v = rawProp(bi, k)
        if v ~= nil then out("独眼弓探针：发射器 %s = %s", k, valid(v) and full(v) or tostring(v)) end
    end
end

-- 10:08 实测：160 行全被替身的激光用完，轮到你自己按住时已经不记了 → 读发射器不受行数限制，替身最多 PUP_MAX 行
BOWP.PUP_MAX, BOWP.pupN = 20, 0

function BOWP.emitterCheck(p1)
    local inst = valid(p1) and LO.activeInstance(p1, "GA_DuYan_Bow_Laser_C")
    local bi = inst and rawProp(inst, "BulletInstance")
    if valid(bi) then BOWP.dumpEmitter(bi) end
end

function BOWP.step(p1, pup, tn)
    if (BOWP.n >= BOWP.MAX and BOWP.biDone and BOWP.subDone and (BOWP.scanN or 0) >= 60) or tn < BOWP.at then return end
    -- 只在有独眼弓的招时读：我这边看 netSend 已经记下的当前动作（不另读），替身看在记的远端招
    local mine = type(NET.hrPrev) == "string" and NET.hrPrev:find("UnnamedBow", 1, true) ~= nil
    local his = false
    for _, f in pairs(CHG.fired) do if f.name and f.name:find("GA_DuYan_Bow", 1, true) then his = true end end
    if not (mine or his or next(BOWP.since)) then return end
    BOWP.at = tn + BOWP.EVERY
    -- 探针出错不能拖垮这一帧后面的驱动（09:01 concat 报错每 0.5 秒打断一次 tick）
    local ok, err = pcall(function()
        if not BOWP.biDone and mine then BOWP.emitterCheck(p1) end
        if not BOWP.subDone and his then      -- §139.6 子弹数据（BD_GA_DuYanBow_Laser_Emitter）的全部函数和参数类型（只记一次）
            local inst = valid(pup) and LO.activeInstance(pup, "GA_DuYan_Bow_Laser_C")
            local bd = inst and rawProp(inst, "BulletData")
            if valid(bd) then
                BOWP.subDone = true
                for _, l in ipairs(G.bulletSubsysProbe(bd) or {}) do out("独眼弓探针：%s", l) end
                -- §139.7 10:46：CreateBullet 生成的发射器所有者空、状态 0 → 看子弹接口 BulletInterface 有哪些函数（初始化 / 开始）
                for _, l in ipairs(G.bulletSubsysProbe(G.findObj("/Script/SGameCombatSystem.BulletInterface"), true) or {}) do out("独眼弓探针：接口 %s", l) end
                for _, l in ipairs(G.bulletSubsysProbe(G.findObj("/Script/SGameCombatSystem.BulletActorBase"), true) or {}) do out("独眼弓探针：基类 %s", l) end
            end
        end
        -- §139.7 11:00 替身的发射器 Initialize + Start 后状态 2、所有者对，还是不打人，位置每发都一样 → 对比两边场上的子弹
        if (BOWP.scanN or 0) < 60 then
            BOWP.scanN = (BOWP.scanN or 0) + 1
            local function who(o)
                if valid(o) and sameObj(o, p1) then return "我" end
                if valid(o) and valid(pup) and sameObj(o, pup) then return "替身" end
                return nil
            end
            local li = valid(p1) and LO.activeInstance(p1, "GA_DuYan_Bow_Laser_C")
            local bi = li and rawProp(li, "BulletInstance")
            local myLoc = valid(p1) and try("p1 loc", function() return p1:K2_GetActorLocation() end)
            out("独眼弓子弹：%s%s", G.bulletScan(who), valid(bi) and string.format("；我的发射器 %s，我在 (%.0f, %.0f, %.0f)",
                G.bulletWhere(bi), myLoc and myLoc.X or 0, myLoc and myLoc.Y or 0, myLoc and myLoc.Z or 0) or "")
        end
        if BOWP.n < BOWP.MAX then
            BOWP.one(p1, "我", tn)
            if BOWP.pupN < BOWP.PUP_MAX then
                local n0 = BOWP.n
                BOWP.one(pup, "替身", tn)
                BOWP.pupN = BOWP.pupN + (BOWP.n - n0)
            end
        end
    end)
    if not ok then BOWP.n = BOWP.n + 10; out("独眼弓探针出错：%s", tostring(err)) end
end

-- 每帧调（netStep 驱动替身之后）。没有在记的条目、没有等着松手的替身招时什么都不读
function CHG.step(p1, pup, tn)
    BOWP.step(p1, pup, tn)                 -- §139.2 只读探针
    if next(BOWN.wait) then BOWN.step(p1, pup, tn) end   -- §139.3 R2 等对方松手再射
    if next(CHG.fired) then CHG.pupStep(pup, tn) end
    if next(CHG.LASER.beams) then CHG.laserBeamStep(pup) end    -- §139.1 激光柱对准你 / 到点收
    if #CHG.list == 0 then return end
    if not CHG.probed and valid(pup) then
        CHG.probed = true
        for _, l in ipairs(G.inputProbe(p1, pup) or {}) do out("蓄力探针 输入系统：%s", l) end
    end
    local keep = {}
    for _, w in ipairs(CHG.list) do
        local m, sec, pos = G.montageSection(w.actor)
        local key = m and (m .. "|" .. sec) or ""
        if key ~= w.key then
            CHG.note(w, tn, m and string.format("%s[%s]@%.2f", m, sec, pos or -1) or "（没动作）")
            -- §92.8 不管读没读到输入，换到 Release / _End 动作都算松手：18:49:49 炽刃大招 2.18 秒切 _Release，
            -- 输入里还有别的键按着，拖到 5.06 秒技能结束才算
            if w.who == "我" and w.hold and w.key and m and (m:find("Release", 1, true) or m:find("_End", 1, true)) then
                CHG.release(w, tn, "换到 " .. m)
            end
            w.key = key
        end
        if m then w.last = tn end
        if w.who == "替身" and m and w.id then          -- 为这一招播过的动作：判定窗口认它们
            local f = CHG.fired[w.id]
            if f then f.mon[m] = true; f.first = f.first or m end
        end
        local abs
        if w.who == "我" then abs = NET.prevAbs          -- netSend 这一帧刚读过（只有招式）
        elseif tn - w.abAt >= CHG.AB_EVERY then w.abAt, abs = tn, activeAbilities(w.actor, NET.wantAb) end
        if abs then
            if w.abs then
                for n in pairs(abs) do if not w.abs[n] then CHG.note(w, tn, "+" .. n) end end
                for n in pairs(w.abs) do if not abs[n] then CHG.note(w, tn, "-" .. n) end end
            end
            w.abs = abs
            if abs[w.name] then w.last = tn end
        end
        if w.who == "我" and w.hold and not w.relAt then
            if w.h0 then
                local h, why = G.holdingInputs(w.actor)
                local still = false
                for k in pairs(w.h0) do if h and h[k] then still = true end end
                if not still then
                    CHG.diag(h, why, "松开 " .. w.name)
                    CHG.release(w, tn, h and "松开按键" or ("输入读不到了：" .. tostring(why)))
                end
            end
            if not w.relAt and abs and not abs[w.name] then CHG.release(w, tn, "技能结束") end
        end
        if w.specAt and tn >= w.specAt then w.specAt, w.spec1 = nil, G.specInput(w.actor, w.name) end
        if tn - w.at >= CHG.DUR and not (w.hold and not w.relAt) then CHG.finish(w, tn, "到时间")
        elseif tn - w.at >= CHG.JUDGE_MAX then CHG.release(w, tn, "按太久"); CHG.finish(w, tn, "到时间")
        elseif tn - w.last >= CHG.QUIET then CHG.release(w, tn, "没动作"); CHG.finish(w, tn, "没动作、技能也结束了")
        else keep[#keep + 1] = w end
    end
    CHG.list = keep
end

-- ============================================================ v0.24.2 空中同步
-- 以前替身只跟 XY（drivePuppet），Z 交给重力：对方跳起来、替身还在地上，对方的空中攻击（Air_A…）在替身身上恒 返回=false
-- （§41 漏判招式、§63 假对手不会跳）。现在：
--   发送：状态包加 air=1/0（我在不在空中，CharacterMovement.IsFalling）+ vz=竖直速度；旧版不发 = 不按状态起跳，和以前一样
--   接收：对方在空中、往上走（vz > LIFT_VZ）或比替身高出 LIFT_DZ，替身在地上，这一跳还没起过 → LaunchCharacter 起跳
--         （AI 控制的替身 Jump() 不起作用）。初速按对方现在的竖直速度和高度差折算：同一个角色类、同样的重力，弧线和对方一样。
--         drivePuppet 只改 XY、保留 Velocity.Z，瞬移也是摆到对方的 Z，都不会把替身拉回地面
--   空中招事件到了而替身还在地上：先起跳，招排队，等替身离地（最多 WAIT 秒）再放；排队期间后面的事件也排着，保持顺序
local AIR = { LIFT_VZ = 150.0, LIFT_DZ = 60.0, MAX_VZ = 2000.0, WAIT = 0.35, JUMP_GRACE = 0.2, LAND_GRACE = 0.3,
              queue = {}, launched = false, launchAt = -100, jumpGAAt = -100, gaLogged = -100, gaLogs = 0,
              rair = nil, rvz = 0.0, n = 0, airOf = G.airOf, launch = G.launch }

-- 状态包里的两个字段（st = G.airOf 的结果；读不到就不发，对方按旧版处理）
function AIR.wire(st)
    if not st then return "" end
    return string.format("air=%d\nvz=%.1f\n", st.falling and 1 or 0, st.vz or 0.0)
end

-- 解包：旧版没有 air= → nil（不知道对方在不在空中：不按状态起跳；空中招照样先起跳再放）
function AIR.parse(t)
    local air = nil
    if t.air == "1" then air = true elseif t.air == "0" then air = false end
    return air, tonumber(t.vz) or 0.0
end

-- 起跳初速：让替身赶上对方的弧线。对方现在比替身高 dz、竖直速度 vz（往上为正）：
--   v0² = max(vz, 0)² + 2·g·max(dz, 0)（和对方同一个最高点）；不低于 minVz，不超过 MAX_VZ
function AIR.launchVz(vz, dz, g, minVz)
    local up = math.max(vz or 0, 0)
    local v = math.sqrt(up * up + 2 * (g or 980.0) * math.max(dz or 0, 0))
    return math.min(math.max(v, minVz or 0), AIR.MAX_VZ)
end

-- 现在要不要按对方的状态起跳。s = { rair, rvz, dz, pupFalling, launched, sinceJumpGA }；返回 是否, 原因
function AIR.shouldLaunch(s)
    if s.rair ~= true then return false, "对方不在空中" end
    if s.pupFalling then return false, "替身已在空中" end
    if s.launched then return false, "这一跳已经起过" end                       -- 不连跳两次
    if (s.sinceJumpGA or 99) < AIR.JUMP_GRACE then return false, "等替身自己的跳跃技能" end
    if (s.rvz or 0) > AIR.LIFT_VZ then return true, "对方在往上跳" end
    if (s.dz or 0) > AIR.LIFT_DZ then return true, "对方比替身高" end
    return false, "对方在往下落（走下台阶 / 快落地）"
end

-- 空中招：名字带 _Air（GA_Hun_ZhanMa_Air_A_C、GA_Hun_Double_JueYing_C_Air_C、GA_Hun_BaiYing_Air_B_C…）
function AIR.isAirMove(n)
    return n:find("_Air", 1, true) ~= nil and isAttackAbility(n)
end

-- 远端一个出招事件在替身身上放出来（以前直接写在 netRecv 里；排队的空中招到时也走这里，判定窗口从真放出来时开）
function AIR.fire(p1, pup, e, tn)
    BAL.noteStance(BAL.rStance, e.name, tn)                    -- §186.3 对方放了架势
    if CDL.puppet(e, tn) then addResult("miss", e.id, 0, tn); return true end      -- §173.7 倒计时里替身不出招
    if DCD.puppet(e, tn) then addResult("miss", e.id, 0, tn); return true end      -- §200 对方闪避冷却中：替身不放
    if not replayable(e.name) then addResult("miss", e.id, 0, tn); return true end   -- §182 旧版对方发来的不该放的（处决等）替身不放
    if BOWN.defer(pup, e, tn, AIR.fire) then return true end      -- §139.3 独眼弓 R2：等对方松手再射
    if ULT.isUlt(e.name) then ULT.topUp(pup); ULT.mark(e.id, e.name) end    -- v0.27.2 对方放成功了才会发来：替身充能至少 1 格；§165.7 记下可补放
    local before = select(3, LAT.activeMontage(pup))
    if CHG.PRE[e.name] then CHG.upgrade(pup, e.name, CHG.PRE[e.name]); CHG.potDiag(pup, "放之前") end    -- §92.7
    if LO.isEdgeAttack(e.name) then ST.pupEdgeAt = tn end      -- v0.23.7 影之武装伤害系数
    -- §106 武器平衡：放之前就把这招的系数写进替身攻击力（以前等下一次驱动，前摇极短的招可能先出伤害）
    -- §203 summon 行里有的招不算攻击也记（玉双环鬼魅闪身：残影反打的追踪飞环按闪身那一下的系数 + 留场秒数算，闪身本身不进 isAttackAbility）
    if (isAttackAbility(e.name) or BAL.SUMMON[e.name]) and BAL.onFire(BAL.resolve(e.name, BAL.rStance, tn), tn) then LO.rescale(pup, tn) end   -- §186.3 架势里按强化版
    local inp = INP.press(pup, e.name, e.id)                -- §140 实验：先按住键
    local ok = activateOnPuppet(pup, e.name, NET.sub, "远端#" .. e.id)
    -- §155 替身根本没放出来的招不开判定窗口（11-08 双开：替身悬在虚空放不出招，我摔死掉的血全被记成这招打中），直接回报落空
    if isAttackAbility(e.name) then
        if ok then openJudge(p1, e.id, tn, e.name); ST.pupAtkAt = tn else addResult("miss", e.id, 0, tn) end
    end
    if ok and not CHG.isHold(e.name) then LAT.afterFire(pup, e, before, tn) end     -- v0.27.0 追帧（§92 蓄力招不追：跳前摇会把蓄力段跳乱）
    if ok then ANIM.afterFire(pup, e, before, tn) end     -- §100 放成功却没换动作 → 补
    if ok and CHG.isHold(e.name) then CHG.onFire(pup, e, tn) end        -- §92 替身按对方的松手时刻松手
    if CHG.fired[e.id] then CHG.fired[e.id].inp = inp end
    if ok and inp then INP.log("输入实验：远端#%d 替身技能接上 Ability Input Component：%s", e.id, G.linkAbilityInput(pup, e.name)) end
    if not ok and inp then INP.release(e.id, "没放出来") end
    if ok then ZMX.onFire(pup, e, tn) end                               -- §119 紫冥剑 DB：起手停住等对方召唤
    if ok and CHG.watched(e.name) then CHG.watch(pup, "替身", e.name, tn, e.id) end
    if ok and e.name:find("_Jump", 1, true) then AIR.jumpGAAt = tn end
    return ok
end

function AIR.doLaunch(pup, vz, dz, why, tn)
    local v = NET.vel or {}
    local ok = AIR.launch(pup, { X = v.X or 0.0, Y = v.Y or 0.0, Z = vz })
    AIR.launched, AIR.launchAt, AIR.n = true, tn, AIR.n + 1
    out("替身起跳 #%d（%s）：竖直初速 %.0f；对方 air=%s vz=%.0f、比替身高 %.0f；LaunchCharacter %s",
        AIR.n, why, vz, tostring(AIR.rair), AIR.rvz, dz, ok and "成功" or "失败")
end

-- netRecv 收到一个新事件：要排队就排上返回 true（空中招而替身在地上 → 先起跳；前面有在排的 → 跟着排）
function AIR.onEvent(p1, pup, e, tn)
    if #AIR.queue == 0 then
        if not AIR.isAirMove(e.name) then return false end
        local st = AIR.airOf(pup)
        if not st or st.falling then return false end         -- 已经在空中（或读不到移动组件）：照常放
        if tn - AIR.launchAt > AIR.WAIT then
            local loc = try("pup loc", function() return pup:K2_GetActorLocation() end)
            local dz = (AIR.rair and NET.pos and loc) and (NET.pos.Z - loc.Z) or 0.0
            AIR.doLaunch(pup, AIR.launchVz(AIR.rair and AIR.rvz or 0.0, dz, st.g, st.jumpZ), dz, "空中招 " .. e.name .. " 先起跳", tn)
        end
    end
    AIR.queue[#AIR.queue + 1] = { e = e, at = tn }
    return true
end

-- 每帧（netStep 驱动替身之后）：按对方状态起跳、放排队的招
function AIR.step(p1, pup, tn)
    local st = AIR.airOf(pup)
    if not st then return end
    local loc = try("pup loc", function() return pup:K2_GetActorLocation() end)
    local dz = (NET.pos and loc) and (NET.pos.Z - loc.Z) or 0.0
    -- 这一跳结束：对方不在空中（或旧版不知道）、替身落了地
    if AIR.launched and AIR.rair ~= true and not st.falling and tn - AIR.launchAt > AIR.LAND_GRACE then AIR.launched = false end
    -- 诊断（前 10 次）：替身放了对方的跳跃技能，它自己有没有离地（离地了就不用 LaunchCharacter）
    if AIR.jumpGAAt > AIR.gaLogged and tn - AIR.jumpGAAt >= AIR.JUMP_GRACE and AIR.gaLogs < 10 then
        AIR.gaLogged, AIR.gaLogs = AIR.jumpGAAt, AIR.gaLogs + 1
        out("替身的跳跃技能放出来 %.2f 秒后：%s", tn - AIR.jumpGAAt, st.falling and "已离地（游戏自己跳了）" or "还在地上")
    end
    local go, why = AIR.shouldLaunch({ rair = AIR.rair, rvz = AIR.rvz, dz = dz, pupFalling = st.falling,
                                       launched = AIR.launched, sinceJumpGA = tn - AIR.jumpGAAt })
    if go then AIR.doLaunch(pup, AIR.launchVz(AIR.rvz, dz, st.g, 0.0), dz, why, tn) end
    if #AIR.queue > 0 and (st.falling or tn - AIR.queue[1].at > AIR.WAIT) then
        if not st.falling then
            out("  !! 替身起跳 %.2f 秒还没离地（移动模式 %s），排队的 %d 个招照放", tn - AIR.queue[1].at, tostring(st.mode), #AIR.queue)
        end
        local q = AIR.queue
        AIR.queue = {}
        for _, it in ipairs(q) do AIR.fire(p1, pup, it.e, tn) end
    end
end

-- §118 闪避方向。闪避技能（GA_Hun_AdvancedDash_* 等）往哪边翻看摇杆，替身没有摇杆 → 游戏给它放原地后撤：
-- 日志里替身放对方的闪避 404 次是 Hun_Tang_Dash_BS、158 次 Dodge_B，真人自己翻的是 Dash_F / Dodge_L / Dodge_R 各方向。
-- 方向一反，翻完离对方真实位置差几米，就被拉回 / 瞬移（用户反馈"翻滚越频繁，闪现越严重"）。
-- 做法：发送方闪避动作换成新的一个时次数 +1，发 dg=<次数>:<动作名>；接收方 WAIT 秒内看替身的动作，
-- 和对方的不一样（替身已经放出自己的后撤，或者等了 SWAP 秒还没换上）就照播对方那个。第一次收到只记次数
DGE = { WAIT = 0.4, SWAP_AT = 0.12, LOG_MAX = 30, logs = 0, fixed = 0, same = 0 }

function DGE.isDodge(m)
    if not m or m:find("MoTian", 1, true) or m:find("PerfectDodge", 1, true) then return false end
    return m:find("Dodge_[FBLR]") ~= nil or m:find("_Roll_[FBLR]") ~= nil or m:find("_Dash_[FLR]") ~= nil
        or m:find("_Dash_BS", 1, true) ~= nil or m:find("^AM_Hun_%a+_Dash_B$") ~= nil
end

function DGE.onPacket(t, tn)
    local n, m = (t.dg or ""):match("^(%d+):([%w_%-]+)$")
    n = tonumber(n)
    if not n then return end
    if DGE.nIn and n > DGE.nIn and DGE.isDodge(m) and not REP.on and not DCD.opMuted(tn) then    -- §200 刚挡掉的闪避不照播
        DGE.want = { m = m, at = tn }
        if m:find("ZuoShang_Dodge", 1, true) then ZMX.dodgeFx(puppet(), m) end      -- §119 紫冥剑布局闪避的金光
    end
    DGE.nIn = n
end

function DGE.step(pup, tn)
    local w = DGE.want
    if not w then return end
    local cur = montageOf(pup)
    if cur == w.m then
        DGE.want, DGE.same = nil, DGE.same + 1
        return
    end
    local late = tn - w.at
    if late > DGE.WAIT then DGE.want = nil; return end
    if not (DGE.isDodge(cur) or late >= DGE.SWAP_AT) then return end
    DGE.want = nil
    local ok = playNamed(pup, w.m)
    if ok then DGE.fixed = DGE.fixed + 1 end
    if DGE.logs < DGE.LOG_MAX then
        DGE.logs = DGE.logs + 1
        out("  对方闪避 %s，替身是 %s → 换成对方的：%s（换过 %d 次，本来就对 %d 次）", w.m, cur ~= "" and cur or "（没动作）",
            ok and "已播" or "播放失败（本机没有这个动作）", DGE.fixed, DGE.same)
    end
end

-- §160 冰冻以挨打方为准（内测 2026-11-08 16:24 v0.30.2："落下白影的武技，他身上那个 y 的追加攻击键都出来了，但对面还是在移动"）。
-- Y = 白影的冰冻突袭 GA_Hun_BaiYing_SpeicalAssault（处决类，Weapon_Hun_BaiYing 自带的 SpecialAttack 通道：目标身上有
-- CharacterState.StatusInfliction.Frost.Effect 就出提示；它不看 CanNotBeExecuted，所以对局里禁处决也拦不住）。
-- 冻住 = 冰冻积累 Frost_Accumulation 攒满后上的 GE_Frost（Hitreact.State.Frozen，站住不能动）。积累是各算各的：
-- A 本机是真 A 砍替身 B，每一刀都算（替身不会格挡 / 闪避，B 那边格挡 / 闪开的也算）→ 替身先冻住、出 Y；
-- B 本机是替身 A 砍真 B，B 自己的游戏判 → 没冻。和杀气一样（替身杀气在本机保持满值，破防只听 brk=），只听挨打方。
-- §160.5 扩到所有异常状态（用户 11-08"那异常状态能矫正么"→"好，让它做"）：点燃 / 中毒（四段）/ 感电 / 流血 / 混沌同一个结构
-- （积累属性攒满 → 挂 GE → CharacterState.StatusInfliction.* 标签）；雷 / 血爆是瞬发、水没有挂状态的 GE，只压积累。
-- 发送方 inf=<类型>:<生效次数>:<段 0=没生效>:<积累>,…（只列有东西的类型，全没有 = "-"）；接收方 INF.step 逐类型：
--   对方生效、替身没有 / 段不对 → 给替身上那一段的 GE（冰冻 → 攻击方出 Y；追击照常发 ev=，对方替身放冰冻突袭在他那边判，双开实测打得中）；
--   对方没生效、替身有 → 跟着对方上的马上撤；本机自己积出来的等 grace（含往返）秒对方还没有就撤（对方确实中了的话 inf= 会先到）；
--   替身的积累比对方多 → 压回对方的值（本机多积的是对方没认的刀）。旧版对方没有 inf= → 不动替身（和以前一样）
-- 类型表（资产名字表，HANDOVER §160.5）：lv[i] = 第 i 段 { 标签, 上的 GE, 撤时连带撤的 GE… }
INF = { ROOT = "CharacterState.StatusInfliction", GE_DIR = "/PBZCombatAsset/Prototypes/GameplayEffects/Inflictions/",
        EVERY = 3, ACC_EVERY = 9, GRACE = 0.15, GRACE_MAX = 0.6, ACC_SLACK = 1.0, LOG_MAX = 60, logs = 0,
        st = { mirror = 0, strip = 0, clamp = 0 }, me = {}, pup = {}, r = nil,
        TYPES = {
            { id = "frost", name = "冰冻", acc = "Frost_Accumulation",
              lv = { { "CharacterState.StatusInfliction.Frost.Effect", "GE_Frost" } } },
            { id = "ignite", name = "点燃", acc = "Ignite_Accumulation",
              lv = { { "CharacterState.StatusInfliction.Ignite", "GE_Ignite" } } },
            { id = "poison", name = "中毒", acc = "Poison_Accumulation",
              lv = { { "CharacterState.StatusInfliction.Poison.Phase0", "GE_Poison_Phase0" },
                     { "CharacterState.StatusInfliction.Poison.Phase1", "GE_Poison_Phase1" },
                     { "CharacterState.StatusInfliction.Poison.Phase2", "GE_Poison_Phase2" },
                     { "CharacterState.StatusInfliction.Poison.Phase3", "GE_Poison_Phase3" } } },
            { id = "elec", name = "感电", acc = "Electrified_Accumulation",
              lv = { { "CharacterState.StatusInfliction.Electrified", "GE_Electrified" } } },
            { id = "bleed", name = "流血", acc = "Bleed_Accumulation",
              lv = { { "CharacterState.StatusInfliction.Bleed.Small", "GE_BleedSmall" } } },
            { id = "chaos", name = "混沌",
              lv = { { "CharacterState.StatusInfliction.Chaos", "GE_ChaosEffect", "GE_Chaos" } } },
            { id = "thunder", name = "雷", acc = "Thunder_Accumulation", lv = {} },
            { id = "bburst", name = "血爆", acc = "BloodBurst_Accumulation", lv = {} },
            { id = "water", name = "水", acc = "Water_Accumulation", lv = {} },
        } }

function INF.say(fmt, ...)
    if INF.logs >= INF.LOG_MAX then return end
    INF.logs = INF.logs + 1
    out(fmt, ...)
end

function INF.gePath(short) return INF.GE_DIR .. short .. "." .. short .. "_C" end

-- 每个类型现在在第几段（0 = 没生效）。先问父标签：身上没有任何异常状态时只问一次
function INF.levels(actor)
    local res = {}
    local any = G.tagsMatching(actor, { INF.ROOT })
    if not (any and #any > 0) then return res end
    for _, ty in ipairs(INF.TYPES) do
        local tags = {}
        for i, l in ipairs(ty.lv) do tags[i] = l[1] end
        if #tags > 0 then
            local hit = G.tagsMatching(actor, tags) or {}
            local set = {}
            for _, h in ipairs(hit) do set[h] = true end
            for i = #ty.lv, 1, -1 do
                if set[ty.lv[i][1]] then res[ty.id] = i; break end
            end
        end
    end
    return res
end

-- 发送方：每 EVERY 帧看一次自己身上的异常状态（积累每 ACC_EVERY 帧读一次），返回 inf= 的值
function INF.mine(p1, tn)
    if INF.wire and ST.ticks % INF.EVERY ~= 0 then return INF.wire end
    local lv = INF.levels(p1)
    local readAcc = INF.wire == nil or ST.ticks % INF.ACC_EVERY == 0
    local parts = {}
    for _, ty in ipairs(INF.TYPES) do
        local s = INF.me[ty.id] or { n = 0, lv = 0, acc = 0 }
        INF.me[ty.id] = s
        local l = lv[ty.id] or 0
        if l > s.lv then
            s.n = s.n + 1
            if s.lv == 0 then s.onAt = tn end
            INF.say("※ 我%s了（%s第 %d 次%s，inf= 告诉对方，他那边替身也跟着）", ty.name, s.lv == 0 and "" or "加重，",
                s.n, #ty.lv > 1 and string.format("，第 %d 段", l) or "")
            if s.lv == 0 then DOT.onStart(ty.id, tn) end          -- §199 持续伤害钉住来源招的系数
        elseif l == 0 and s.lv > 0 then
            INF.say("※ 我%s结束了（%.1f 秒）", ty.name, tn - (s.onAt or tn))
            DOT.onEnd(ty.id, tn)
        end
        s.lv = l
        if l > 0 then DOT.ctrlStep(p1, ty, s, tn) end           -- §199 控制类异常时长上限
        if readAcc and ty.acc then s.acc = attrOf(p1, ty.acc) or s.acc end
        if s.n > 0 or s.lv > 0 or s.acc >= 0.5 then
            parts[#parts + 1] = string.format("%s:%d:%d:%.0f", ty.id, s.n, s.lv, s.acc)
        end
    end
    DOT.takeStep(p1, tn)        -- §199.9 持续伤害按钉住系数压自己的承伤乘法
    INF.wire = #parts > 0 and table.concat(parts, ",") or "-"
    return INF.wire
end

-- 接收方：记下对方的异常状态；旧版没有 inf= → INF.r = nil，不动替身。没列出的类型 = 0 次、没生效、积累 0
function INF.onPacket(t, tn)
    if not t.inf or t.inf == "" then INF.r = nil; return end
    local r = {}
    for id, n, l, acc in t.inf:gmatch("(%a+):(%d+):(%d+):([%d%.]+)") do
        r[id] = { n = tonumber(n), lv = tonumber(l), acc = tonumber(acc) }
    end
    INF.r = r
end

function INF.reset()
    INF.r, INF.pup = nil, {}
    DOT.src, DOT.chillAt = {}, nil   -- §199 换对手 / 断开：上一个对手挂的持续伤害不再钉（§206 冰缓也清）
    for kind in pairs(DOT.taken) do DOT.takenBack(DOT.p1, kind, "换对手 / 断开") end   -- §199.9
end

function INF.grace()
    local rtt = LAT.rttMs and LAT.rttMs()
    return math.min(INF.GRACE + (rtt and rtt * 1.5 / 1000 or 0.15), INF.GRACE_MAX)
end

-- 撤掉替身身上这个类型所有段的 GE（含连带的）
function INF.strip(pup, ty)
    local ok = false
    for _, l in ipairs(ty.lv) do
        for k = 2, #l do ok = LO.removeGE(pup, INF.gePath(l[k])) or ok end
    end
    return ok
end

-- 接收方每 EVERY 帧：替身的异常状态逐类型跟对方走。p.ours = 替身这次的状态是跟着对方的（对方一结束马上撤）
function INF.step(pup, tn)
    local R = INF.r
    if not R or REP.on or ST.ticks % INF.EVERY ~= 0 then return end
    local plv = INF.levels(pup)
    local readAcc = ST.ticks % INF.ACC_EVERY == 0
    for _, ty in ipairs(INF.TYPES) do
        local r = R[ty.id] or { n = 0, lv = 0, acc = 0 }
        local p = INF.pup[ty.id] or {}
        INF.pup[ty.id] = p
        if readAcc and ty.acc and r.lv == 0 then
            local pacc = attrOf(pup, ty.acc)
            if pacc and pacc > r.acc + INF.ACC_SLACK then
                setAttr(pup, ty.acc, r.acc)
                INF.st.clamp = INF.st.clamp + 1
                if INF.st.clamp <= 5 or INF.st.clamp % 50 == 0 then
                    INF.say("  替身%s积累 %.0f，对方 %.0f → 压回对方的（本机多积的是对方没认的刀，第 %d 次）", ty.name, pacc, r.acc, INF.st.clamp)
                end
            end
        end
        local cur = plv[ty.id] or 0
        if #ty.lv == 0 then
            -- 瞬发类：只压积累
        elseif r.lv > 0 then
            p.localAt = nil
            local key = r.n .. ":" .. r.lv
            if cur == r.lv then
                p.ours, p.key = true, key
            elseif p.key ~= key or (cur > 0 and tn - (p.fixAt or -1e9) >= INF.grace()) then
                -- 每次生效（每一段）只上一次，上不上去都不反复试（替身的 GE 先到时掉了也不补）；
                -- 替身在别的段上（本机自己积到更重的中毒）→ 隔 grace 换回对方那一段
                p.key, p.fixAt = key, tn
                if cur > 0 then INF.strip(pup, ty) end
                local ge = ty.lv[math.min(r.lv, #ty.lv)][2]
                local ok = LO.applyGE(pup, INF.gePath(ge), "替身" .. ty.name)
                p.ours = ok or nil
                INF.st.mirror = INF.st.mirror + 1
                INF.say("※ 对方%s（第 %d 次%s）→ 替身也%s：%s", ty.name, r.n, #ty.lv > 1 and string.format("，第 %d 段", r.lv) or "",
                    ty.name, ok and ("已上 " .. ge .. (ty.id == "frost" and "（出 Y 追击提示）" or "")) or "上不去")
            end
        elseif cur > 0 then
            local why
            if p.ours then
                why = "对方的结束了"
            else
                p.localAt = p.localAt or tn
                if tn - p.localAt >= INF.grace() then
                    why = string.format("本机自己积出来的，对方没有（对方积累 %.0f，等了 %.2f 秒）", r.acc, tn - p.localAt)
                end
            end
            if why then
                local ok = INF.strip(pup, ty)
                if ty.acc then setAttr(pup, ty.acc, r.acc) end
                p.ours, p.localAt = nil, nil
                INF.st.strip = INF.st.strip + 1
                INF.say("※ 替身撤掉%s（%s）：%s", ty.name, why, ok and "已撤" or "撤不掉")
            end
        else
            p.ours, p.localAt = nil, nil
        end
    end
end

-- §173 回合干净开打 + 回合时限（内测反馈 11-09："倒计时 3 秒里能打人挂 debuff / 控制"、"慈母护符太强，打不死"）。
-- ① 倒计时里双方挂游戏自己的无敌效果（剧情演出用的 GE_FlowInvulnerable，给 CharacterState.Stand.Invulnerable.Debug；
--    Boss 开战前那个 GE_BossInvulnerableBeforeCombat 带 Unselectable，会锁不上，不用）。挂不上就退回让替身倒计时里是友方（不互砍）
-- ② 交手开始那一刻：撤掉无敌；自己和替身身上有有限时长的效果（异常状态、喝药 / 武器技能的增益、冷却）和异常状态的 GE 全撤（G.cleanse，§208），
--    异常积累清 0（自己走游戏的改属性函数 GE_MA_*_Accumulation_*_Override），然后回满（refill）。
--    不撤：锁血 GE_LockHealth（撤了会真死）、饰品 / 标准数值自己挂的（ACC / STD 管）、没有时限的（天赋 / 装备被动）、
--    名字 GE_Talent_* / GE_Accessory_* 的（就算有时限：被动触发的，撤了不一定会再挂）
-- ③ 回合时限（房间设置 tl，秒，0 = 不限；武林盟主固定 180）：交手满 tl 秒还没人倒下 → 本回合受到伤害多的一方判负，一样多平局。
--    受伤 = 交手开始后自己血量每次往下掉的累加（慈母护符 / 喝药回的血不抵）；状态包 tk=<回合>:<受伤> 发给对方。
--    主机判（自己的 + 客机 tk=；对方没有 tk=（本地 AI / 旧版）→ 按对方状态包的 血上限 − 血量），结果照常走 mt= 和可靠事件 rend，
--    另发可靠事件 rtime=<对局> <回合> <主机受伤> <客机受伤>，客机屏幕上显示"时间到"和两边的数
RT = { INV_GE = "/Game/PBZContent/Blueprint/FlowGraph/GameplayEffect/GE_FlowInvulnerable.GE_FlowInvulnerable_C",
       INV_TAG = "CharacterState.Stand.Invulnerable.Debug",
       shield = nil, taken = 0, hp = nil, round = 0, rtk = nil, info = nil, logs = 0,
       -- 不管有没有时限都撤的（INF 段的异常状态 GE + 持续伤害 / 积累标记，资产名字表 Prototypes/GameplayEffects/Inflictions/）
       FORCE = { GE_Ignite_Dot = true, GE_Poison_Dot_Phase1 = true, GE_Poison_Dot_Phase2 = true, GE_Poison_Dot_Phase3 = true,
                 GE_Electrified_VFX = true, GE_Frost_HasAccumulation = true, GE_Thunder_HasAccumulation = true, GE_Suffocation = true } }
for _, ty in ipairs(INF.TYPES) do
    for _, l in ipairs(ty.lv) do for k = 2, #l do RT.FORCE[l[k]] = true end end
end

-- 这一局的时限（秒，0 = 不限）。客机：主机没发 tl=（旧版 / 本地 AI 当主机）= 不限，免得屏幕上倒数到 0 什么也不发生
function RT.limit()
    if NET.rkRules() then return NET.resOf("tl") end
    if (MATCH.session and MATCH.session.role) == "client" and NET.rres.tl == nil then return 0 end
    return NET.resOf("tl") or 0
end

-- 交手还剩几秒（不限时 / 不在交手 = nil）
function RT.left(tn)
    local lim = MATCH.tl or 0
    if lim <= 0 or MATCH.state ~= "fight" then return nil end
    return math.max(0, lim - (tn - MATCH.t0))
end

-- 撤不撤：锁血不撤；饰品 / 标准数值自己挂的不撤；异常状态的撤；其余有时限的撤
function RT.keep()
    local k = {}
    local function add(path) local n = path and path:match("/([%w_]+)%.[^/]*$"); if n then k[n] = true end end
    for _, p in ipairs(G.GE_CANDIDATES or {}) do add(p .. "." .. (p:match("([^/]+)$") or "")) end
    for path in pairs(STD.gearMine or {}) do add(path) end
    for _, path in ipairs(STD.added or {}) do add(path) end
    for _, path in pairs((ACC.mine and ACC.mine.geAdded) or {}) do add(path) end
    return k
end

function RT.cleanse(actor, who, self_)
    if not valid(actor) then return end
    local keep = RT.keep()
    -- §173.11 只读：按规则没撤的（天赋 / 饰品 / 武器无时限的）、留着的有时限效果；§208 加 时长读不到的、其他无时限的
    local ruled, timedLeft, unk, other = { tal = {}, acc = {}, wpn = {} }, {}, {}, {}
    local done, fail = G.cleanse(actor, function(n, timed, left, finite)
        if finite == nil then finite = timed and left ~= nil end      -- 旧适配层没有第 4 个参数
        local function stay()
            if timed then timedLeft[#timedLeft + 1] = left and string.format("%s %.1fs", n, left) or (n .. " ?s") end
            return false
        end
        if keep[n] or n:find("LockHealth", 1, true) then return stay() end
        -- §208（用户 11-10："全部的临时 buff 包括药品和武器的都在开始前清理掉"）：判据改成"有没有有限时长"，不再按名字挑。
        -- 撤 = 异常 / 负面（RT.FORCE，没时限也撤）+ 喝药（GE_Medicine_ 开头，§173.10）+ 其余一切有有限时长的：
        --   武器武技增益（GE_Weapon_Tang_Buff_Lv1、GE_Weapon_Double_Buff、GE_BaiYing_Buff、GE_LuanYing_Buff_P2…）、
        --   影之武装 / 武器的临时状态（GE_ChiZheCanJian_Prezui_3、GE_XuKongHuaSHn_FiledTime、GE_TieKuangQuanTao_Charge…）、冷却。
        --   §173.8 当"武器形态"留下的三个，日志里都是读秒前放招挂上的有时限效果（11:34–11:37 替身），没看到撤了之后少东西，一并撤。
        -- 留 = 天赋 GE_Talent_* / 饰品 GE_Accessory_*（就算有时限：被动触发的，撤了不一定再挂；§173.10）、模组自己挂的（keep / 锁血）、
        --   没有时限的（武器被动 / 等级 / Combo / CanBuff、形态、天赋）、有时限但时长读不到的（GrantPotential 这类每回合都在的）
        if n:match("^GE_Talent_") then ruled.tal[#ruled.tal + 1] = n; return stay() end
        if n:match("^GE_Accessory_") then ruled.acc[#ruled.acc + 1] = n; return stay() end
        if RT.FORCE[n] == true or n:match("^GE_Medicine_") ~= nil then return true end
        if finite then return true end
        if n:match("^GE_Weapon_") then ruled.wpn[#ruled.wpn + 1] = n; return stay() end
        if timed then unk[#unk + 1] = n; return false end
        other[#other + 1] = n
        return false
    end)
    local acc = {}
    for _, ty in ipairs(INF.TYPES) do
        local v = ty.acc and attrOf(actor, ty.acc)
        if v and v > 0.01 then
            local ok = false
            if self_ and G.attrModSet then ok = (pcall(G.attrModSet, actor, ty.acc, 0)) and (attrOf(actor, ty.acc) or 1) < 0.01 end
            if not ok then setAttr(actor, ty.acc, 0) end
            acc[#acc + 1] = string.format("%s %.0f→0%s", ty.name, v, ok and "" or "（直接写）")
        end
    end
    if done == nil then
        out("!! 交手开始清状态（%s）：读不到效果表", who)
    elseif #done + #fail + #acc > 0 or RT.logs < 6 then
        RT.logs = RT.logs + 1
        out("交手开始清状态（%s）：撤掉 %d 个效果 %s%s；异常积累 %s", who, #done, table.concat(done, ","),
            #fail > 0 and ("；撤不掉 " .. table.concat(fail, ",")) or "", #acc > 0 and table.concat(acc, "，") or "无")
    end
    -- §208 替身撤掉的里有对方 wge= 同步来的（LO.wgeOn）：LO.wgeOn 照旧记着"上过了"，对方读秒前的旧 wge= 还带着它时不会马上补回来；
    -- 对方自己开打也撤了、新的 wge= 不带它 → LO.syncWge 走"对方没了"清掉记号；之后对方再放武技 → 新列表带上 → 正常补
    local won = (not self_) and done and LO and LO.wgeOn
    if won then
        local hit = {}
        for id in pairs(won) do
            local short = id:match("([%w_]+)$")
            for _, n in ipairs(done) do if n == short then hit[#hit + 1] = id end end
        end
        if #hit > 0 then
            table.sort(hit)
            out("  替身撤掉的里有对方 wge= 同步来的：%s（等对方新的 wge= 不带它了再按对方的补）", table.concat(hit, " "))
        end
    end
    if done ~= nil then      -- §173.11 每次开打一行（只读，不改行为）：按规则没撤的 + 留着的有时限效果和剩余时间，查漏撤的药 / 误撤
        local function joinOr(t) return #t > 0 and table.concat(t, ",") or "-" end
        out("开打留着的效果（%s）：按规则没撤 天赋 %s；饰品 %s；武器 %s；有时限的 %s；时长读不到的 %s", who, joinOr(ruled.tal),
            joinOr(ruled.acc), joinOr(ruled.wpn), joinOr(timedLeft), joinOr(unk))
        RT.otherLogs = (RT.otherLogs or 0) + 1
        if RT.otherLogs <= 8 then     -- §208 其他没时限的（不是天赋 / 饰品 / 武器开头），前 8 次记全名，查有没有该撤的临时效果漏掉
            out("  开打留着的其他无时限效果（%s）：%s", who, joinOr(other))
        end
    end
end

-- 进倒计时：挂无敌（自己 + 替身），看标签确认；自己挂不上 → RT.shield = false（syncFaction 让替身倒计时里是友方）
function RT.cdStart(p1)
    local pup = puppet()
    RT.shield = LO.applyGE(p1, RT.INV_GE, "倒计时无敌（自己）")
    if valid(pup) then LO.applyGE(pup, RT.INV_GE, "倒计时无敌（替身）") end
    local hit = G.tagsMatching(p1, { RT.INV_TAG })
    RT.shield = RT.shield and hit ~= nil and #hit > 0
    if not RT.shield then out("!! 倒计时无敌没挂上（没有 %s），倒计时里让替身当友方（不互砍）", RT.INV_TAG) end
end

-- 撤无敌（交手开始 / 回自由活动）
function RT.unshield(p1)
    if RT.shield == nil then return end
    RT.shield = nil
    LO.removeGE(p1, RT.INV_GE, "撤掉倒计时无敌（自己）")
    local left = G.tagsMatching(p1, { RT.INV_TAG })      -- 撤不掉 = 交手 / 自由活动里一直无敌，日志要显眼
    if left and #left > 0 then
        LO.removeGE(p1, RT.INV_GE, "再撤一次倒计时无敌（自己）")
        left = G.tagsMatching(p1, { RT.INV_TAG })
        if left and #left > 0 then out("!! 倒计时无敌撤不掉（还有 %s）：这一局你打不掉血，请反馈", RT.INV_TAG) end
    end
    local pup = puppet()
    if valid(pup) then LO.removeGE(pup, RT.INV_GE, "撤掉倒计时无敌（替身）") end
end

-- 交手开始：撤无敌、清状态（回满由调用方在标准数值 / 开局资源之后做，再调 RT.begin 记起点）
function RT.fightStart(p1)
    CDL.onFight(p1, now())                          -- §173.12 先清读秒里按下 / 缓冲住的键
    RT.unshield(p1)
    RT.cleanse(p1, "自己", true)
    NET.wgeStr = nil                                -- §208 武器增益撤了：下一包重算 wge=，别让对方按读秒前的旧列表给替身补回去
    local pup = puppet()
    if valid(pup) then RT.cleanse(pup, "替身", false); INF.pup = {} end
end

-- §173.9 倒计时规则行折行：显示宽度（中文 / 全角算 2，其余算 1）不超过 w，一条规则不拆；单条超长的单独一行
RT.RULE_W = 40
function RT.dispW(s)
    local w = 0
    for _, c in utf8.codes(s) do w = w + (c >= 0x2E80 and 2 or 1) end
    return w
end
function RT.wrapRules(rules, w)
    local lines, cur, cw = {}, nil, 0
    for _, r in ipairs(rules) do
        local rw = RT.dispW(r)
        if cur and cw + 3 + rw <= w then
            cur, cw = cur .. " · " .. r, cw + 3 + rw
        else
            if cur then lines[#lines + 1] = cur end
            cur, cw = r, rw
        end
    end
    if cur then lines[#lines + 1] = cur end
    return lines
end

function RT.begin(p1)
    RT.taken, RT.hp, RT.round, RT.info = 0, hpOf(p1), MATCH.round, nil
    if (MATCH.tl or 0) > 0 then out("第 %d 回合限时 %d 秒（到时受到伤害多的一方判负）", MATCH.round, MATCH.tl) end
end

-- 交手中每帧：自己血量往下掉的累加
function RT.track(hp)
    if hp and RT.hp and hp < RT.hp then RT.taken = RT.taken + (RT.hp - hp) end
    RT.hp = hp
end

function RT.wire()
    if not MATCH.role or RT.round ~= MATCH.round then return "-" end
    return string.format("%d:%.0f", RT.round, RT.taken)
end

function RT.onPacket(t)
    local rd, v = (t.tk or ""):match("^(%d+):([%d%.]+)$")
    RT.rtk = rd and { round = tonumber(rd), v = tonumber(v) } or nil
end

-- 主机：时间到了没有。到了返回 本回合赢家 h / c / d（RT.info 记两边的数，可靠事件 rtime 由 matchStep 发：REL 在后面才定义）；没到 nil
function RT.check(tn)
    local left = RT.left(tn)
    if not left or left > 0 then return nil end
    local mine, theirs, how = RT.taken, nil, "对方回报"
    if RT.rtk and RT.rtk.round == MATCH.round then theirs = RT.rtk.v
    elseif NET.remoteHpm and NET.remoteHp then theirs, how = math.max(0, NET.remoteHpm - NET.remoteHp), "按对方血量算" end
    theirs = theirs or 0
    local w = math.abs(mine - theirs) < 0.5 and "d" or (mine > theirs and "c" or "h")
    RT.info = { round = MATCH.round, h = mine, c = theirs }
    out("== 第 %d 回合时间到（%d 秒）：受伤 我（主机）%.0f / 对方 %.0f（%s）→ %s ==", MATCH.round, MATCH.tl, mine, theirs, how,
        w == "d" and "一样多，平局" or (w == "h" and "对方受伤多，我赢" or "我受伤多，对方赢"))
    return w
end

-- §119 紫冥剑召唤实验（2026-11-06，§118.4）。枪 / 锤 / 伞不在动作里，是 GA_Hun_ZiMingJian_New_DB 按住时再按攻击键
-- 自己做的（TrySummonHuoQiang / TrySummonJinGua / TrySummonTieSan → 时间线段 Summon_* + 子弹 B_ZiMingJian_DBB_*）。
-- 替身没人按住，起手 0.6 秒技能就收了，对方的 sub= 到的时候已经没有技能可调。实验两步：
--   ① 替身放出 DB 后 PAUSE_AT 秒把起手动作停住，看技能是不是跟着挂住（日志"技能还在"）
--   ② 收到对方的召唤动作（sub= 的 Gun / JinGua / TieChi）时对替身的 DB 实例调对应的 TrySummon*（调成了就不再照播动作）
-- 第一轮实测（17:45–17:47，回放用户录的 6 次召唤）：起手停得住、技能多挂 1.4–2.2 秒，TrySummon* 6 次都调用成功、不崩，
-- 但替身动作没换成召唤、用户看不到召唤物也没掉血。第二轮：实验期间对方的 Loop 不再照播（会顶掉技能自己的动作），
-- 调 TrySummon* 时起手还停着（不先继续），调之前 / 0.3 秒后把技能实例里 BuJu / Summon / Loop 等变量记进日志
-- 第二轮实测（17:53）：停住动作拦不住技能（技能按自己的时间线 0.1 秒后照样切 End，看着更短）；技能变量里
-- HasSummoned_HuoQiang / JinGua / TieSan 一开始就是 true（替身没进布局，没被清掉）→ TrySummon* 当成"召过了"。
-- 第三轮：不停起手、Loop 照播；调 TrySummon* 之前把对应的 HasSummoned_* 写成 false
-- 第三轮实测（18:03–18:05）：三件都召出来了、伞打中 -404；枪 / 锤没对着你（回放的录制里 lk=0、替身朝向是录制里的）。
-- 瞄准：对方锁定你（lk=1）时替身出招后 ATK_HOLD 秒内每帧对准你（v0.23.3），但这个计时从放 DB 算起，布局里停一会儿再召唤
-- 就过了（18:07 实测"有一些瞄不准"）→ 每次召唤都重新开始计（ST.pupAtkAt = 召唤那一刻）
-- 18:1x 实测：锤 / 伞没问题，火枪从你头顶平飞过去（截图：三把枪浮在替身头顶上方）。猜：火枪按控制器视角的俯仰瞄，
-- 替身的控制器俯仰一直是 0。召唤后对方锁定你时，俯仰改成从枪的高度指向你（没用，已删，见下）
-- 18:2x 实测：俯仰算出来了（-23.5°）还是平射 → 火枪不按视角瞄。资产：枪 BP_ZiMingJian_FlyingGun 的子弹
-- B_ZiMingJian_FlyingGun_Bullet 用 BP_BulletTargetSelector_LockTarget（打锁定目标）。替身锁定目标早就是你，
-- 怀疑打的是你身上的锁定点 LockViewTarget（替身的那个以前一直在原点，§19 fixPuppetLockPoint）。
-- 召唤火枪时记下你的锁定点在哪，并在对方召唤火枪后 3 秒内每帧把它放到你胸口（P1_LOCK_Z）
-- 18:3x 实测：你的锁定点原来真在 (0,0,0)，放到胸口了还是平射。子弹选目标的 BP_BulletTargetSelector_LockTarget 走的是
-- GetTargetingComponent → HasLockTarget / RequestLockTarget：替身的瞄准组件（Targeting Component）里从来没有锁定目标，
-- 只写了角色的 LockTargetActor 属性不够（用户截图：自己放的火枪斜着指向对方胸口的锁定光点）。
-- 召唤时（对方锁定你）对替身的瞄准组件调 SetLockTarget(你)；第一次把组件上带 Lock 的函数 / 属性记进日志
-- 18:41 实测：SetLockTarget 传角色本身类型不对（参数不是 Actor）。改成记下参数类型，把你身上可能的目标对象
-- （LockViewTarget、名字带 Target / Lock 的组件）挨个试，HasLockTarget 变 true 就记住用哪个
-- 18:53 实测：参数 Target 是结构体（StructProperty），传对象都不行。改成按结构体的字段拼一张表：对象字段里类名 / 字段名
-- 像组件的填你的 LockViewTarget、其余对象字段填你；位置字段填你胸口。另外读你自己的瞄准组件 LockTarget（你锁着替身时
-- 能看到游戏自己是怎么填这个结构体的）
-- 19:18 实测通过：结构体是 ComponentSocket{Component, SocketName}；填 Component = 你的 LockViewTarget（召唤火枪后 3 秒放在
-- 你胸口）→ HasLockTarget=true，火枪瞄着你打（连中 7 下各 -67）。游戏自己的填法（你锁替身时读到）是 Component = 对方的
-- CharacterMesh0 + 某个挂点名。之前试过的"控制器俯仰"不起作用，已删
-- 第一次放时把实例上带 Summon 的函数和参数记进日志。net/zmx_off.txt 存在 = 整个不做（出问题时不用重新部署）
ZMX = { CLS = "GA_Hun_ZiMingJian_New_DB_C", PAUSE_AT = 0.4, HOLD_MAX = 4.0, LOGS = 150, logs = 0,
        FN = { Gun = "TrySummonHuoQiang", JinGua = "TrySummonJinGua", TieChi = "TrySummonTieSan" },
        FLAG = { Gun = "HasSummoned_HuoQiang", JinGua = "HasSummoned_JinGua", TieChi = "HasSummoned_TieSan" },
        NO_PAUSE = true, SKIP_LOOP = false, P1_LOCK_Z = 40.0, p1LockUntil = 0, lockLogs = 0, tcUnlockAt = nil,
        STATE = { "BuJu", "Summon", "Loop", "Can", "Hold", "Timing", "Enhanced", "HuoQiang", "JinGua", "TieSan", "Rate" } }
ZMX.OFF_FILE = NET_DIR .. "/zmx_off.txt"

function ZMX.log(...)
    if ZMX.logs < ZMX.LOGS then ZMX.logs = ZMX.logs + 1; out(...) end
end

function ZMX.off()
    local f = io.open(ZMX.OFF_FILE, "r")
    if f then f:close(); return true end
    return false
end

function ZMX.onFire(pup, e, tn)
    FJ.onFire(pup, e, tn)                -- §179 收尾招射飞剑
    if e.name ~= ZMX.CLS then return end
    if ZMX.off() then ZMX.log("紫冥剑实验：有 net/zmx_off.txt，不做"); return end
    ZMX.cur = { id = e.id, at = tn, paused = false, nextLog = 0 }
    if not ZMX.probed then
        ZMX.probed = true
        local inst = LO.activeInstance(pup, ZMX.CLS)
        out("紫冥剑实验：替身 DB 实例 %s；带 Summon 的函数：%s", inst and "有" or "没有",
            inst and table.concat(LO.funcsLike(inst, "Summon"), " ") or "-")
    end
end

function ZMX.finish(pup, why, tn)
    local c = ZMX.cur
    if c.paused then G.montagePause(pup, false) end
    ZMX.log("紫冥剑实验：远端#%d 结束（%s，%.2f 秒，停过起手=%s）", c.id, why, tn - c.at, tostring(c.paused))
    ZMX.cur = nil
end

-- 你身上的锁定点（别人锁你时镜头 / 子弹对着的点）的位置；fix = true 时放到你胸口
function ZMX.p1Lock(fix, why)
    local p1 = getP1()
    local comp = valid(p1) and rawProp(p1, "LockViewTarget")
    if not valid(comp) then
        if ZMX.lockLogs < 3 then ZMX.lockLogs = ZMX.lockLogs + 1; ZMX.log("  紫冥剑实验：你身上没有 LockViewTarget（%s）", why) end
        return
    end
    local l = try("p1 loc", function() return p1:K2_GetActorLocation() end)
    if not l then return end
    if ZMX.lockLogs < 6 then
        ZMX.lockLogs = ZMX.lockLogs + 1
        local a = try("p1 lock", function() return comp:K2_GetComponentLocation() end)
        ZMX.log("  紫冥剑实验：你的锁定点（%s）在 %s，你在 (%.0f, %.0f, %.0f)", why,
            a and string.format("(%.0f, %.0f, %.0f)，比你高 %.0f", a.X, a.Y, a.Z, a.Z - l.Z) or "?", l.X, l.Y, l.Z)
    end
    if fix then
        pcall(function() comp:K2_SetWorldLocation({ X = l.X, Y = l.Y, Z = l.Z + ZMX.P1_LOCK_Z }, false, {}, true) end)
    end
end

-- 布局中被打的自动闪避（ZuoShang_Dodge_*）：真人那边有一道金光，是 DB 技能自己放的 Niagara（闪避动作里没有通知），
-- 替身的技能早收了 → 模组自己在替身身上放。DB 技能名字表里有 NS_ZuoShangLongTi_TP / _Trail、NS_ZuoShang_CA01_PullOut_002，
-- 具体哪个是金光看不出（TP 有 _201 / _202 两个）。先轮流放 FX 里的候选（每次闪避换下一个，日志写"第 N 个"），用户认出来后固定
-- 19:34 实测：TP_201 / TP_202 / Trail_201 / PullOut_002 四个都放成功了，但都不是（用户：真人身上是条带特效）；
-- 19:4x 换主角完美闪避 BattleFX/Hun/NS_PerfectDodge_001 也不是（用户："更像描边"）。用户定：先用 TP_201，以后有空再查。
-- 以后查：你自己拿紫冥剑在布局里被打出闪避时，ZMX.fxProbe 把你身上挂的特效（Niagara + 叠加材质）记进日志（只记前 3 次）
ZMX.FX = { "/PBZVFXPack/VFX/BattleFX/ZuoShang_LongTi/NS_ZuoShangLongTi_TP_201.NS_ZuoShangLongTi_TP_201" }
ZMX.fxp, ZMX.fxpN = nil, 0

-- 我在布局里被打出闪避（ZuoShang_Dodge_*）：当下 / 0.2 / 0.5 秒扫一遍我身上的特效
function ZMX.fxProbe(p1, hm, tn)
    if hm and hm:find("ZuoShang_Dodge", 1, true) and ZMX.fxpN < 3 then
        ZMX.fxpN = ZMX.fxpN + 1
        ZMX.fxp = { at = tn, left = { 0.0, 0.2, 0.5 } }
    end
    local p = ZMX.fxp
    if not (p and #p.left > 0 and tn - p.at >= p.left[1]) then return end
    table.remove(p.left, 1)
    local list, ov = LO.fxOn(p1)
    out("紫冥剑：我布局闪避 %.1f 秒，身上特效 %s；叠加材质 %s", tn - p.at, #list > 0 and table.concat(list, " ") or "（无）", ov)
end
ZMX.fxN = 0

function ZMX.dodgeFx(pup, m)
    if not valid(pup) or ZMX.off() then return end
    ZMX.fxN = ZMX.fxN + 1
    local i = (ZMX.fxN - 1) % #ZMX.FX + 1
    local path = ZMX.FX[i]
    local ok, how = LO.spawnFx(pup, path)
    out("紫冥剑实验：对方布局闪避 %s → 替身第 %d 次闪避，放候选特效 %d 号 %s：%s", m, ZMX.fxN, i,
        path:match("([%w_]+)$"), ok and ("成功（" .. how .. "）") or ("失败 " .. tostring(how)))
end

-- 按 SetLockTarget 的参数结构体拼"锁定你"的表
function ZMX.lockStruct(tc)
    local pl = LO.paramList(tc, "SetLockTarget")
    local st = pl and pl[1] and pl[1].fields
    if not st then return nil, "参数不是结构体 / 读不到字段" end
    local p1 = getP1()
    local comp = rawProp(p1, "LockViewTarget")
    local l = try("p1 loc", function() return p1:K2_GetActorLocation() end)
    local t, used = {}, {}
    for _, f in ipairs(st) do
        local isObj = f.t:find("ObjectProperty", 1, true) ~= nil
        local nc = (f.n .. " " .. (f.cls or "")):lower()
        if isObj and (nc:find("component") or nc:find("point")) and valid(comp) then t[f.n] = comp; used[#used + 1] = f.n .. "=你的锁定点"
        elseif isObj then t[f.n] = p1; used[#used + 1] = f.n .. "=你"
        elseif f.t == "StructProperty" and f.cls == "Vector" and l then t[f.n] = { X = l.X, Y = l.Y, Z = l.Z + ZMX.P1_LOCK_Z }; used[#used + 1] = f.n .. "=你胸口" end
    end
    return t, table.concat(used, " ")
end

-- 你自己的瞄准组件现在的 LockTarget 结构体（你锁着替身时看游戏怎么填）
function ZMX.p1LockInfo()
    local tc = LO.targetingComp(getP1())
    local v = tc and rawProp(tc, "LockTarget")
    local pl = tc and LO.paramList(tc, "SetLockTarget")
    local st = pl and pl[1] and pl[1].fields
    if not (v and st) then return "读不到" end
    local parts = {}
    for _, f in ipairs(st) do
        local fv = rawProp(v, f.n)
        local s = type(fv) == "userdata" and (valid(fv) and short(pathOf(fv)) or "空/结构体") or tostring(fv)
        parts[#parts + 1] = f.n .. "=" .. s
    end
    return table.concat(parts, " ")
end

-- 给替身瞄准组件锁定你
function ZMX.tcLock(tc)
    local t, used = ZMX.lockStruct(tc)
    if not t then ZMX.log("  紫冥剑实验：替身瞄准组件锁你：%s", used); return end
    local ok, err, has = LO.tcSetLock(tc, t)
    ZMX.log("  紫冥剑实验：替身瞄准组件 SetLockTarget({%s}) %s，HasLockTarget=%s；你自己的 LockTarget：%s", used,
        ok and "调用成功" or ("失败 " .. tostring(err):sub(-80)), tostring(has), ZMX.p1LockInfo())
end

-- §189 替身放 Snap 前：瞄准组件锁你（Snap 的 K2_CanActivateAbility 要有锁定目标）。对方没锁你就 1.5 秒后撤掉（同火枪，ZMX.step 里撤），
-- 免得替身后面的招都追着你。返回 HasLockTarget
function LO.snapLock(pup)
    local tc = LO.targetingComp(pup)
    local t = tc and ZMX.lockStruct(tc)
    if not t then return false end
    local ok, _, has = LO.tcSetLock(tc, t)
    if not NET.rlk then ZMX.tcUnlockAt = math.max(ZMX.tcUnlockAt or 0, now() + 1.5) end
    ST.snapLockN = (ST.snapLockN or 0) + 1
    if ST.snapLockN <= 5 then out("  Snap 前替身瞄准组件锁你：%s，HasLockTarget=%s（第 %d 次）", ok and "调用成功" or "失败", tostring(has), ST.snapLockN) end
    return ok and has == true
end

-- §192 紫冥剑飞剑对面只出不飞（HANDOVER §192）。资产（游戏包名字表，11-09 离线查）：DB（GA_Hun_ZiMingJian_New_DB）生成子弹
-- B_Hun_ZiMingJian_FlyingSword_Aim_Fast → BP_Hun_ZIMingJian_FlyingSword_Aim，挂在肩膀槽 ZiMingJian.HoldingFlyingSword.Slot1–7，
-- 用 WaitGameplayEventToActor 在主人身上等 ZiMingJian.FeiJian.FireInstantly，收到才 Fire 射出去（有 Fired? 标记）；
-- 发这个事件的只有五个收尾招 ABB / BBB / AAAAA / AABB / AAABB（技能里的 GAA_GameplayEvent 动作）。
-- 替身上飞剑生成了（DB 放得出），收尾招替身也放了，但剑没飞：事件没发到 / 没等到（推测，见 §192），Lua 发不了这个事件
-- （SendGameplayEventToActor 的 Payload 带 GameplayTagContainer，传了会崩，§19.20）。
-- 做法：替身放这五招时记下肩上有几把剑；WAIT 秒后还没 Fired? 的，调剑自己的 Fire 补射（游戏自己射过的不动）。
-- 日志写清"自己飞了几把 / 补射几把"，实测一次就知道原因在哪。net/fj_off.txt 存在 = 只记不补射
FJ = { FIN = { GA_Hun_ZiMingJian_New_ABB_C = true, GA_Hun_ZiMingJian_New_BBB_C = true, GA_Hun_ZiMingJian_New_AAAAA_C = true,
               GA_Hun_ZiMingJian_New_AABB_C = true, GA_Hun_ZiMingJian_New_AAABB_C = true },
       CLS = "BP_Hun_ZIMingJian_FlyingSword_Aim_C", FIRED = "Fired?", FIRE = "Fire", WAIT = 1.2, LOGS = 40, logs = 0 }
FJ.OFF_FILE = NET_DIR .. "/fj_off.txt"

function FJ.log(...)
    if FJ.logs < FJ.LOGS then FJ.logs = FJ.logs + 1; out(...) end
end
function FJ.off()
    local f = io.open(FJ.OFF_FILE, "r")
    if f then f:close(); return true end
    return false
end

function FJ.onFire(pup, e, tn)
    if not FJ.FIN[e.name] then return end
    local s = LO.bulletsOf(pup, FJ.CLS, FJ.FIRED)
    FJ.pend = { id = e.id, name = e.name, at = tn, n = #s }
    FJ.log("紫冥剑飞剑：远端#%d %s，替身肩上 %d 把", e.id, e.name, #s)
    if #s > 0 and not FJ.probed then
        FJ.probed = true
        FJ.log("  紫冥剑飞剑：剑上带 Fire 的函数 %s", table.concat(LO.funcsLike(s[1].actor, "Fire"), " "))
    end
end

function FJ.step(pup, tn)
    local p = FJ.pend
    if not p or tn - p.at < FJ.WAIT then return end
    FJ.pend = nil
    local s = LO.bulletsOf(pup, FJ.CLS, FJ.FIRED)
    local left = {}
    for _, b in ipairs(s) do if b.fired == false then left[#left + 1] = b.actor end end
    if #left == 0 then
        FJ.log("  紫冥剑飞剑：远端#%d %.1f 秒后肩上还剩 %d 把，没有待射的（放招时 %d 把）", p.id, FJ.WAIT, #s, p.n)
        return
    end
    if FJ.off() then
        FJ.log("  紫冥剑飞剑：远端#%d %d 把没射（有 net/fj_off.txt，不补射）", p.id, #left)
        return
    end
    local ok, err = 0, nil
    for _, a in ipairs(left) do
        local okF, e = LO.callNoArg(a, FJ.FIRE)
        if okF then ok = ok + 1 else err = e end
    end
    FJ.log("  紫冥剑飞剑：远端#%d %s %.1f 秒后 %d 把没射，补调 Fire：成功 %d%s", p.id, p.name, FJ.WAIT, #left, ok,
        err and ("，失败 " .. tostring(err)) or "")
end

function ZMX.step(pup, tn)
    FJ.step(pup, tn)                     -- §179
    if tn < ZMX.p1LockUntil or NET.rlk then ZMX.p1Lock(true, "每帧放到胸口") end     -- §132 对方锁你时一直放（替身瞄准组件锁的是它）
    if ZMX.tcUnlockAt and tn >= ZMX.tcUnlockAt then          -- 火枪锁的你：对方其实没锁你 → 撤掉，免得替身别的招也追着你
        ZMX.tcUnlockAt = nil
        local tcU = not NET.rlk and LO.targetingComp(pup)
        if tcU then LO.tcStop(tcU); ZMX.log("  紫冥剑：火枪打完，对方没锁定你，撤掉替身瞄准组件的锁定") end
    end
    local c = ZMX.cur
    if not c then return end
    local el = tn - c.at
    if el < ZMX.PAUSE_AT and not c.paused then return end
    local alive = LO.activeInstance(pup, ZMX.CLS) ~= nil
    local m = montageOf(pup)
    if c.watch and tn >= c.watch.at then
        ZMX.log("  紫冥剑实验：调 %s 后 %.2f 秒替身动作 %s，技能还在=%s", c.watch.fn, tn - c.watch.t0, m ~= "" and m or "（没动作）", tostring(alive))
        local inst = alive and LO.activeInstance(pup, ZMX.CLS)
        if inst then ZMX.log("  紫冥剑实验：调完后技能变量 %s", LO.propsLike(inst, ZMX.STATE)) end
        if c.paused and m:find("Summon_Start", 1, true) then       -- 停着调没反应：继续播，看技能自己往下走成什么
            G.montagePause(pup, false); c.paused = false
            ZMX.log("  紫冥剑实验：动作没换，起手继续播")
        end
        c.watch = nil
    end
    if not ZMX.NO_PAUSE and not c.paused and not c.summoned then
        if m:find("Summon_Start", 1, true) and alive then
            local ok = G.montagePause(pup, true)
            c.paused = ok
            ZMX.log("紫冥剑实验：远端#%d 放出 %.2f 秒，停住起手 %s：%s", c.id, el, m, ok and "成功" or "失败")
            local inst = LO.activeInstance(pup, ZMX.CLS)
            if inst then ZMX.log("  紫冥剑实验：停住时技能变量 %s", LO.propsLike(inst, ZMX.STATE)) end
            if not ok then ZMX.finish(pup, "停不住", tn) end
        else
            ZMX.finish(pup, string.format("没来得及停：动作 %s，技能还在=%s", m ~= "" and m or "（没动作）", tostring(alive)), tn)
        end
        return
    end
    if tn >= c.nextLog then
        c.nextLog = tn + 0.5
        ZMX.log("  紫冥剑实验：停着 %.1f 秒，动作 %s，技能还在=%s", el, m ~= "" and m or "（没动作）", tostring(alive))
    end
    if not alive then ZMX.finish(pup, "技能自己没了", tn)
    elseif el > ZMX.HOLD_MAX then ZMX.finish(pup, "等满 " .. ZMX.HOLD_MAX .. " 秒", tn) end
end

-- 收到对方的召唤动作：Gun / JinGua / TieChi → 调替身 DB 实例的 TrySummon*。返回 true, 日志用的说法 = 调用方不再照播动作
function ZMX.onSub(pup, sm, tn)
    local kind = sm:match("Summon_(%a+)_%d")
    local fn = kind and ZMX.FN[kind]
    if not fn and ZMX.SKIP_LOOP and ZMX.cur and sm:find("_Loop", 1, true) then return true, "实验中不照播（让技能自己走）" end
    GDMG.onSub("op", sm, tn)             -- §212 对方的锤 / 伞 / 反击：这段时间火枪的命中不按每发算
    -- §184 火枪冷却（挨打方为准）：对方上一把火枪还在场 / 收掉后没过冷却 → 替身不召、也不照播动作（第三个返回值 = 跳过）
    if kind == "Gun" then
        local why = GCD.blockOp(tn)
        if why then return true, why, true end
    end
    if not fn or ZMX.off() then return false end
    local inst = LO.activeInstance(pup, ZMX.CLS)
    if not inst then
        ZMX.log("紫冥剑实验：对方召唤 %s，替身的 DB 已经没了，照播动作", sm)
        return false
    end
    local c = ZMX.cur
    ZMX.log("  紫冥剑实验：调之前技能变量 %s（替身动作 %s）", LO.propsLike(inst, ZMX.STATE), montageOf(pup))
    if kind == "Gun" then ZMX.p1Lock(false, "召唤火枪时"); ZMX.p1LockUntil = tn + 3.0 end
    local tc, tcKey = LO.targetingComp(pup)
    if not ZMX.tcProbed then
        ZMX.tcProbed = true
        out("紫冥剑实验：替身瞄准组件 %s；带 Lock 的函数：%s；属性：%s", tc and (tcKey .. " " .. short(pathOf(tc))) or "没有",
            tc and table.concat(LO.funcsLike(tc, "Lock"), " ") or "-", tc and LO.propsLike(tc, { "Lock", "Target" }) or "-")
        if tc then out("紫冥剑实验：SetLockTarget 参数 %s；GetLockTarget 参数 %s", LO.paramTypes(tc, "SetLockTarget"), LO.paramTypes(tc, "GetLockTarget")) end
    end
    -- 2026-11-07 真人对战火枪还是打头顶：对方没硬锁你（lk=0）时以前不锁 → 替身火枪没目标平射。对方那边不锁也有软锁定，
    -- 1v1 场上敌人只有你，他的火枪照样瞄你 → 召唤火枪时不管 lk 都锁你，3 秒后对方还是没锁你就撤掉
    if tc and (NET.rlk or kind == "Gun") then
        ZMX.tcLock(tc)
        if not NET.rlk then ZMX.tcUnlockAt = tn + 3.0 end
    end
    local flag = ZMX.FLAG[kind]
    local okF = pcall(function() inst[flag] = false end)
    ZMX.log("  紫冥剑实验：%s 写成 false %s，读回 %s", flag, okF and "成功" or "失败", tostring(rawProp(inst, flag)))
    local ok, err = LO.callNoArg(inst, fn)
    if ok then
        ST.pupAtkAt = tn                 -- 召唤也算出招：对方锁定你时接下来 ATK_HOLD 秒对准你
        if BAL.active() then BAL.noteSummon(ZMX.CLS, tn) end   -- §177 锤枪伞打你时按 DB 的系数算
        if kind == "Gun" then GCD.onSummon("op", tn); GDMG.onGun("op", c and c.id, tn) end   -- §184 替身召出火枪：开始看它什么时候收掉；§212 记是哪次 DB
    end
    ZMX.log("紫冥剑实验：对方召唤 %s → 替身 DB 调 %s：%s", sm, fn, ok and "调用成功" or ("失败 " .. tostring(err)))
    if c then
        c.watch, c.summoned = { at = tn + 0.3, t0 = tn, fn = fn }, true
        c.at = tn - ZMX.PAUSE_AT       -- 再给一段 HOLD_MAX，对方可能接着召唤下一件
    end
    return ok, ok and "已调技能召唤" or nil
end

-- ============================================================ §184 紫冥剑火枪冷却（武器平衡的一部分：平衡表 cooldown.ZiMingJian_HuoQiang，默认 15 秒）
-- 11-09 实测（伤害 50%）：对方连放紫冥剑 DB 召唤火枪 32 次，一次 1–2 秒连射 9–16 发、每发 64–284，最多一次累计 2135。
-- 用户定的规则：火枪召出来 → 在场期间不能再召 → 火枪收掉那一刻起再等 15 秒才能再召。只管火枪，金瓜锤 / 铁伞不管。
-- 用户 11-09 改："不用做配置，这属于武器平衡里的" → 不是房间设置：只在武器平衡开着（BAL.active()）时生效，秒数在 pbz_balance.lua 的
-- cooldown 行，跟着数值表下发（§158 CFG 的 cd=；旧版主机 / 服务器发的表没有 cd= = 15 秒）
-- 两边各记一份："op" = 对方（替身召的那把，挨打方为准）、"me" = 本机玩家。s = { t0 = 召唤成功, endAt = 收掉的时刻, seen, why, nextScan }
-- ① 火枪什么时候算"收掉"：每 SCAN 秒数一次召唤者名下名字带 FlyingGun 的子弹 / 召唤物（G.summonCount：BulletActorBase 状态 2
--    + BP_ZiMingJian_FlyingGun_C 没隐藏），见过之后数到 0 = 收掉；一直没数到（类名不对 / 读不到）或在场超过 CAP 秒 = 按 t0 + CAP 算收掉。
--    CAP 3 秒：日志里一次召唤连射 1–2 秒，召唤后约 0.3 秒开枪；§119 的"火枪打完撤锁定"也是 3 秒（19:18 实测命中在 1 秒内）
-- ② 挨打方（替身侧，ZMX.onSub）：对方的 sub=Summon_Gun_* 来时在挡（在场 / 冷却）→ 不调 TrySummonHuoQiang、也不照播动作，记日志；
--    调成了才开始计（对方 DB 没了 / 调失败只照播动作的，替身那边没有枪，不计）
-- ③ 出手方（本机，GCD.frame / GCD.mine）：挡着时每次驱动把我身上紫冥剑 DB 实例的 HasSummoned_HuoQiang 写成 true —— 技能自己的
--    TrySummonHuoQiang 看到"召过了"就不召（§119.1 第二轮：替身的这个变量一开始是 true，调 TrySummonHuoQiang 不出枪、动作不换）；
--    挡完了把我写的改回 false。万一还是召出来了（拦不住），这个 Gun 动作不发给对方（sub= 不加），对方是旧版也不会召。
--    屏幕提示（对局 HUD）：我在 DB 里时显示"火枪还在场" / "火枪冷却中 还剩 X 秒"
-- 只在对局里、武器平衡开着时管；每回合倒计时开始、对局结束、换对手（新连接 / 序号回退）、换世界都清
GCD = { KEY = "ZiMingJian_HuoQiang", CAP = 3.0, SCAN = 0.25, SEEN_FROM = 0.3, SAME = 1.5, PAT = "FlyingGun", EXTRA = { "BP_ZiMingJian_FlyingGun_C" },
        LOGS = 60, logs = 0, side = { me = {}, op = {} }, hintTill = 0, wrote = nil, probed = {} }
function GCD.log(...)
    if GCD.logs < GCD.LOGS then GCD.logs = GCD.logs + 1; out(...) end
end
function GCD.sec()            -- 冷却秒数：不在对局里 / 武器平衡关着 = 0（不管）；平衡表 cooldown 里没写 = 0
    if MATCH.role == nil or not BAL.active() then return 0 end
    return BAL.COOLDOWN[GCD.KEY] or 0
end
function GCD.reset(why)
    local had = GCD.side.me.t0 or GCD.side.op.t0
    GCD.side = { me = {}, op = {} }
    GCD.hintTill, GCD.wrote = 0, nil
    GDMG.reset()                     -- §212
    if had then GCD.log("火枪冷却清零（%s）", why or "-") end
end
function GCD.onSummon(who, tn)
    GCD.side[who] = { t0 = tn, nextScan = tn + GCD.SEEN_FROM }
    GCD.log("火枪冷却：%s召出火枪（在场期间不能再召，收掉后再等 %g 秒）", who == "me" and "我" or "对方", GCD.sec())
end
-- 返回 "field"（还在场）/ "cd", 剩余秒数 / nil（能召）
function GCD.status(who, tn)
    local sec = GCD.sec()
    local s = GCD.side[who]
    if sec <= 0 or not s.t0 then return nil end
    if not s.endAt then return "field" end
    local left = s.endAt + sec - tn
    if left > 0 then return "cd", left end
    return nil
end
-- 挨打方：对方的火枪该不该挡。挡 → 日志用的说法；不挡 → nil
function GCD.blockOp(tn)
    local st, left = GCD.status("op", tn)
    if not st then return nil end
    local why = st == "field" and "火枪还在场，替身不召" or string.format("火枪冷却中，替身不召（还剩 %.1f 秒）", left)
    GCD.log("§184 %s", why)
    return why
end
-- 看一边的火枪收没收掉（owner = 召唤者：对方的是替身，我的是我）
function GCD.step(who, owner, tn)
    local s = GCD.side[who]
    if not s.t0 or s.endAt then return end
    if tn >= s.t0 + GCD.CAP then
        s.endAt, s.why = s.t0 + GCD.CAP, s.seen and ("在场满 " .. GCD.CAP .. " 秒（上限）") or ("没数到火枪对象，按上限 " .. GCD.CAP .. " 秒")
    elseif tn >= s.nextScan then
        s.nextScan = tn + GCD.SCAN
        local n, info = G.summonCount(owner, GCD.PAT, GCD.EXTRA)
        if n > 0 and not GCD.probed[who] then
            GCD.probed[who] = true
            GCD.log("火枪冷却：%s的火枪对象 %s（召唤后 %.2f 秒）", who == "me" and "我" or "对方", info, tn - s.t0)
        end
        if n > 0 then s.seen = true
        elseif s.seen then s.endAt, s.why = tn, "火枪对象没了" end
    end
    if s.endAt then
        GCD.log("火枪冷却：%s的火枪收掉（%s，在场 %.2f 秒），%g 秒后能再召", who == "me" and "我" or "对方", s.why, s.endAt - s.t0, GCD.sec())
    end
end
-- 出手方：本机的召唤动作要不要发给对方（false = 不发）。火枪以外的照发
function GCD.mine(hm, tn)
    GDMG.onSub("me", hm, tn)                -- §212 我的锤 / 伞 / 布局反击：这段时间我的火枪命中不按每发算
    if not hm:find("Summon_Gun_", 1, true) then return true end
    local s = GCD.side.me
    if GCD.sec() <= 0 then                  -- §212 冷却整个关着也记我的火枪在场（每发伤害要用），不挡、不提示
        if MATCH.role ~= nil and not (s.t0 and not s.endAt) then GCD.onSummon("me", tn); GDMG.onGun("me", nil, tn) end
        return true
    end
    local st, left = GCD.status("me", tn)
    if not st then GCD.onSummon("me", tn); GDMG.onGun("me", nil, tn); return true end
    if st == "field" and tn - s.t0 < GCD.SAME then return false end     -- 同一次召唤的后半段动作（Gun_03 → Gun_02），不算再召
    GCD.hintTill = tn + 2.0
    GCD.log("!! 火枪冷却：本机%s还是召出了火枪 %s（没拦住），不发给对方", st == "field" and "火枪还在场时" or string.format("冷却还剩 %.1f 秒时", left), hm)
    return false
end
-- 每次发包驱动调（hm = 我当前的动作）：两边的收掉检测 + 本机挡着、在 DB 里时写 HasSummoned_HuoQiang = true
function GCD.frame(p1, hm, tn)
    if MATCH.role == nil then
        if GCD.side.me.t0 or GCD.side.op.t0 then GCD.reset("不在对局里") end
        return
    end
    GCD.step("me", p1, tn)
    local pup = puppet()
    GCD.step("op", pup, tn)
    GDMG.frame(p1, pup, hm, tn)     -- §212 锤 / 伞在不在场
    -- 只在我正播紫冥剑 DB 的动作（Hun_ZiMing_Summon_*，布局里都是）时找技能实例：找一次要扫全部技能
    local inDb = (hm or ""):find("Hun_ZiMing_Summon_", 1, true) ~= nil
    local inst = (GCD.side.me.t0 or GCD.wrote) and inDb and LO.activeInstance(p1, ZMX.CLS) or nil
    local st = GCD.status("me", tn)
    if st and inst then
        if rawProp(inst, ZMX.FLAG.Gun) ~= true then
            local ok = pcall(function() inst[ZMX.FLAG.Gun] = true end)
            if not GCD.wrote then GCD.log("火枪冷却：我在紫冥剑 DB 里，%s写成 true（拦召唤）%s", ZMX.FLAG.Gun, ok and "" or " 失败") end
        end
        GCD.wrote = inst
        GCD.hintTill = math.max(GCD.hintTill, tn + 0.3)
    elseif GCD.wrote then
        if not st and inst then pcall(function() inst[ZMX.FLAG.Gun] = false end); GCD.log("火枪冷却：冷却完了，%s改回 false", ZMX.FLAG.Gun) end
        if not (st and inst) then GCD.wrote = nil end
    end
end
-- 对局 HUD 的提示行（文字由 matchRows 套 T()）：nil 或 { 中文, 英文 }
function GCD.hint(tn)
    if tn >= GCD.hintTill then return nil end
    local st, left = GCD.status("me", tn)
    if st == "field" then return { "火枪还在场", "GUNS STILL OUT" } end
    if st == "cd" then
        local n = math.ceil(left)
        return { string.format("火枪冷却中 还剩 %d 秒", n), string.format("GUN COOLDOWN %ds", n) }
    end
    return nil
end

-- ============================================================ §212 紫冥剑火枪每发伤害（武器平衡的一部分：平衡表 sdmg.ZiMingJian_HuoQiang，默认每发 1 点）
-- 用户 11-10："紫冥剑 DB 召出的火枪伤害降到每发 1 点左右，只压火枪，金瓜锤 / 铁伞不变"。三件都是同一招 GA_Hun_ZiMingJian_New_DB_C 召的（§119），
-- 共用系数 0.2（§193 / §177 summon 15 秒），改系数压不了单独一件 → 按"这一下是不是火枪打的"单独改这一下。
-- 伤害在哪台机器算：火枪是替身 / 本人的 DB 技能召的子弹，打谁在谁的本机结算（§184.3）——
--   真人联机：对方替身的枪打我 → 我这边改（GDMG.fix）；我的枪打对方 → 对方机器上替身侧改（对方要是新版，旧版照原伤害）；
--   本地 AI / 假对手：我的枪打在本机替身上、按 td= 回报（TOUCH.mark）→ 这一下按每发的数报（GDMG.mine）。
-- 认不认得出（资产名字表，11-10 离线查，HANDOVER §212.1）：挨打方的掉血里没有"谁打的"，三件的子弹数据都是 PhysicalDamage + ElementDamage，
-- 按伤害类型分不开（不像 §206 冰缓）；能分的是**场上有什么**：火枪本体 BP_ZiMingJian_FlyingGun_C / _HasDisapearSound_C（GCD 在场检测），
-- 锤 BP_ZiMingJian_FlyingHammer(_Enhanced)_C、伞 BP_ZiMingJian_TieSan_C + 飞镖 BP_ZiMIngJian_DBC_Dart_C，都是子弹（BulletOwnerAvatar = 召唤者）。
-- 认作火枪 = ① 这一下记在 DB 那一招上，而且就是召出这把火枪的那次 DB（招式号对得上）② 这把火枪在场（GCD.side，收掉后再宽 LINGER 秒接住
-- 最后几发）③ 同一方的锤 / 伞 / 布局闪避反击这段时间不在场（OTHER：收到召唤动作 / 看到闪避反击动作起算，场上数到它们的对象就跟着，
-- 对象没了再等 OTHER_LINGER 秒；一直没数到按 OTHER_CAP 秒）。三条不全满足就不动——宁可这一下火枪照原伤害，也不碰锤 / 伞。
-- 只在对局交手中 + 武器平衡开 + sdmg 这一项 > 0。挨打方改血先走游戏的改属性函数（G.attrModSet，§113.1），不行再直接写；不调 HUD 回调。
-- 一帧里掉的血算一发（日志里火枪每发各占一帧：mp_probe.log 07:44:03 四发 -65.7）。
GDMG = { KEY = "ZiMingJian_HuoQiang", LINGER = 0.5, OTHER_LINGER = 1.0, OTHER_CAP = 8.0, SCAN = 0.25, SEEN_FROM = 0.3,
         OTHER_PAT = { "FlyingHammer", "TieSan", "Dart" }, OTHER_MON = { "PerfectDodge", "ZuoShang_Dodge" },
         db = {}, other = { me = {}, op = {} }, n = { me = 0, op = 0 }, skip = 0, LOGS = 60, logs = 0, way = nil }
function GDMG.log(...)
    if GDMG.logs < GDMG.LOGS then GDMG.logs = GDMG.logs + 1; out(...) end
end
function GDMG.reset()
    GDMG.db, GDMG.other = {}, { me = {}, op = {} }
end
-- 每发多少点；nil = 不管（不在交手 / 武器平衡关 / 表里写 0）
function GDMG.per()
    if MATCH.state ~= "fight" or not BAL.active() then return nil end
    local v = BAL.sdmg(GDMG.KEY)
    if not v or v <= 0 then return nil end
    return v
end
-- 火枪召出来了（GCD.onSummon 之后调）：记这把枪是哪一次 DB 召的（招式号）。对方的：ZMX.cur 没了就找最近一次 DB 的判定记录
function GDMG.onGun(who, id, tn)
    if not id and who == "me" then id = PRED.myAttackId() end
    if not id and who == "op" then
        for k, f in pairs(CHG.fired or {}) do if f.name == ZMX.CLS and (not id or k > id) then id = k end end
    end
    GDMG.db[who] = id
end
-- 同一方的紫冥剑召唤动作（sub=）：锤 / 伞（以及别的召唤动作，如布局反击 PerfectDodge）可能在场。火枪 / 起手 / Loop / 收招不算
function GDMG.onSub(who, sm, tn)
    if not sm or not sm:find("Hun_ZiMing_Summon_", 1, true) then return end
    for _, k in ipairs({ "_Gun_", "_Start", "_Loop", "_End" }) do if sm:find(k, 1, true) then return end end
    GDMG.noteOther(who, sm, tn)
end
function GDMG.noteOther(who, why, tn)
    if not GDMG.other[who].t0 then
        GDMG.log("§212 火枪每发伤害：%s %s → 锤 / 伞 / 反击可能在场，这段时间%s火枪的命中不改", who == "me" and "我" or "对方", why, who == "me" and "我" or "对方")
    end
    GDMG.other[who] = { t0 = tn, why = why, seen = false, nextScan = tn + GDMG.SEEN_FROM }
end
function GDMG.inField(who, tn)
    local s = GCD.side[who]
    return s ~= nil and s.t0 ~= nil and (not s.endAt or tn - s.endAt <= GDMG.LINGER)
end
function GDMG.busy(who) return GDMG.other[who].t0 ~= nil end
-- 这一下（记在 id / name 这一招上）是不是 who 那一方的火枪打的
function GDMG.isGun(who, id, name, tn)
    return name == ZMX.CLS and id ~= nil and GDMG.db[who] == id and GDMG.inField(who, tn) and not GDMG.busy(who)
end
-- 每次发包驱动（GCD.frame 里）：锤 / 伞那段还在不在。火枪在场时动作是布局闪避 / 反击也算（反击的子弹看不出是谁的）
function GDMG.frame(p1, pup, hm, tn)
    GDMG.step("me", p1, hm, tn)
    GDMG.step("op", pup, nil, tn)
end
function GDMG.step(who, owner, m, tn)
    if GDMG.inField(who, tn) then
        if who == "op" and valid(owner) then m = montageOf(owner) end
        for _, k in ipairs(GDMG.OTHER_MON) do
            if m and m:find(k, 1, true) then
                if not GDMG.busy(who) then GDMG.noteOther(who, m, tn) end
                GDMG.other[who].seen, GDMG.other[who].lastSeen = true, tn
                break
            end
        end
    end
    local o = GDMG.other[who]
    if not o.t0 then return end
    if tn >= o.nextScan then
        o.nextScan = tn + GDMG.SCAN
        local n = valid(owner) and G.summonCount(owner, GDMG.OTHER_PAT) or 0
        if n > 0 then o.seen, o.lastSeen = true, tn end
    end
    local gone = (o.seen and tn - (o.lastSeen or o.t0) > GDMG.OTHER_LINGER) or (not o.seen and tn - o.t0 > GDMG.OTHER_CAP)
    if gone then
        GDMG.log("§212 火枪每发伤害：%s的锤 / 伞 / 反击（%s）%s，火枪的命中照常按每发算", who == "me" and "我" or "对方", o.why or "-",
            o.seen and "收掉了" or ("一直没数到，按上限 " .. GDMG.OTHER_CAP .. " 秒"))
        GDMG.other[who] = {}
    end
end
-- 挨打方改血：先走游戏的改属性函数，不行再直接写；第一次（换路时）记一行走的哪条路
function GDMG.setHp(p1, hp)
    local ok, msg = false, "没有 attrModSet"
    if G.attrModSet then
        local okC, r1, r2 = pcall(G.attrModSet, p1, "Health", hp)
        if okC then ok, msg = r1, r2 else msg = tostring(r1) end
    end
    if not ok and not setAttr(p1, "Health", hp) then return false end
    local way = ok and "改属性函数" or "直接写"
    if GDMG.way ~= way then GDMG.way = way; out("§212 火枪每发伤害：改血走%s（%s）", way, tostring(msg)) end
    return true
end
-- 挨打方（netJudge 掉血那一帧调；step = 这一帧掉的，hpBefore = 这一帧之前的血）：认作对方火枪打的 → 这一下只扣每发的数，
-- 返回改后这一帧该掉的；不管 → nil
function GDMG.fix(p1, id, name, step, hpBefore, tn)
    local v = GDMG.per()
    if not v or not hpBefore or hpBefore <= 0 or not step or step <= v + 1e-3 then return nil end
    if not GDMG.isGun("op", id, name, tn) then
        if name == ZMX.CLS and GDMG.inField("op", tn) and GDMG.busy("op") then
            GDMG.skip = GDMG.skip + 1
            GDMG.log("§212 火枪每发伤害：对方火枪在场时中招 -%.0f，但锤 / 伞 / 反击也可能在场（%s）→ 不改（第 %d 次）", step, GDMG.other.op.why or "-", GDMG.skip)
        end
        return nil
    end
    if not GDMG.setHp(p1, hpBefore - v) then return nil end
    GDMG.n.op = GDMG.n.op + 1
    GDMG.log("§212 火枪每发伤害：对方火枪打中我 -%.0f → 改成 -%g（远端#%d，第 %d 发；数值表 sdmg.%s）", step, v, id, GDMG.n.op, GDMG.KEY)
    return v
end
-- 本地 AI（TOUCH.mark 记 td= 时调；d = 替身本机这一帧掉的血）：认作我的火枪打的 → 返回这一下该报的数；不管 → nil
function GDMG.mine(id, d, tn)
    local v = GDMG.per()
    if not v or not d or d <= 0 then return nil end
    if not GDMG.isGun("me", id, NET.evName and NET.evName[id], tn) then return nil end
    GDMG.n.me = GDMG.n.me + 1
    GDMG.log("§212 火枪每发伤害：我的火枪打中替身（本机掉 %.0f）→ 回报按 %g（#%d，第 %d 发）", d, v, id, GDMG.n.me)
    return v
end

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

-- ============================================================ §200 闪避冷却 / 闪避扣杀气（武器平衡的一部分：平衡表 cooldown.ShunYingDodge、cost.Dodge / SnakeDodge）
-- 用户（11-10）先要了"瞬影结束后 10 秒 cd、普通闪避一套结束后 5 秒 cd"（§200–§200.9），后来改成（§200.10）：
--   "能给普通的闪避增加杀气消耗么 但是不给他冷却限制了"——普通闪避（AdvancedDash / Continuous_02 / 03，灵蛇剑架势闪避 StanceDash）
--   不再冷却，改成每段扣杀气（cost.Dodge / cost.SnakeDodge，默认 50；§200.14 用户 11-10 定，§200.12 是 100，原来 20）；杀气不够照样闪、扣到 0 为止（扣到 0 本身不会破防，§200.10.2）；
--   瞬影（天赋瞬身 GA_Hun_SpecialDash_*）的 10 秒冷却只挡瞬影自己，不再挡普通闪避，普通闪避也不挡瞬影；瞬影自己的杀气消耗是游戏的，不变。
-- 只在对局交手中、武器平衡开着时管。技能判据见 HANDOVER §200.1：
--   瞬影 = GA_Hun_SpecialDash_*；普通闪避 = GA_Hun_AdvancedDash_<武器>（第 1 段）→ _Continuous_02_* → _Continuous_03_*，灵蛇剑 GA_Hun_StanceDash_*；
--   不管：完美闪避反击 *PerfectDodge*、冲刺攻击 *_A_Dash / *_DashDraw、破防后撤 BreakEscape、DeflectEscape、醉态自动闪避 DodgeAuto、影之武装的 Escape / Dash。
-- ① 普通闪避扣杀气（出手方本机，netSend 看到我新出现的闪避技能那一刻）：每段一次；PRESS 秒内又出现的闪避技能（连段中间游戏转接的
--    AdvancedDash_<武器> 和紧接着换上的 Continuous 同一下）算同一段、不重复扣。走游戏的改属性函数（G.attrModSet），不直接写。
-- ② 瞬影冷却（出手方）：瞬影结束后 ShunYingDodge 秒内再放 → K2_CancelAbility 只取消这一个、不发给对方、dg= 不发、瞬影扣的杀气写回；
--    屏幕提示"瞬影冷却中 还剩 X 秒"（拦了之后 HINT 秒）。
-- ③ 挨打方（替身侧，AIR.fire）：只按对方的瞬影事件算对方的瞬影冷却（起点按开始时刻，偏宽松，留 TOL），还剩 > TOL 秒时替身不放、dg= 不照播；
--    普通闪避不挡（不冷却了）。替身闪不闪不影响伤害：我打替身中没中由对方那边判（回报）。
-- ④ §200.13 瞬影冷却改成"激活前挡住"：冷却期间把天赋瞬身的 GE（GE_Talent_EnableSkipJump，给 CharacterState.Talent.EnableGhostStep）
--    从我身上摘掉，瞬影的基类 BP_SpecialDash_Base 在 K2_CanActivateAbility 里要这个标签（资产字节码：HasMatchingGameplayTag(EnableGhostStep)
--    不满足就跳走），没有它就放不出来；冷却到了 / 不在交手里 / 清零时挂回去（身上已经有了就不重复挂）。天赋 GE 是运行时的，
--    存档只记天赋树（AbilityNode_*），不进存档（同 §144 标准数值挂 / 摘天赋）。普通闪避（AdvancedDash / StanceDash）不看这个标签。
--    摘不掉 / 摘了还放出来 → ② 的事后取消照旧兜底。net/sylock_off.txt 存在 = 不摘（出问题时不用重新部署）
-- 每回合倒计时开始、对局结束、换对手 / 对方重启、换世界清零；不在交手里 DCD.frame 自己清
DCD = { TOL = 0.3, HINT = 1.5, PRESS = 0.15, LOGS = 80, logs = 0, CLOGS = 40, clogs = 0,
        DEF = { ShunYingDodge = 10 },
        TAL = "EnableSkipJump", LOCK_OFF = NET_DIR .. "/sylock_off.txt", lk = nil,
        me = { sy = {}, exp = 0, lastAt = -100 }, op = { sy = {} }, hintTill = 0, muteTill = 0, opMuteTill = 0, debit = 0,
        n = { me = 0, op = 0, cost = 0, short = 0, lock = 0, leak = 0 } }
function DCD.log(...)
    if DCD.logs < DCD.LOGS then DCD.logs = DCD.logs + 1; out(...) end
end
-- 哪种闪避：普通 "dg"（含灵蛇剑架势闪避）/ 瞬影 "sy" / 不管 nil
function DCD.kind(n)
    if not n then return nil end
    if n:find("^GA_Hun_SpecialDash_") then return "sy" end
    if n:find("^GA_Hun_AdvancedDash_") or n:find("^GA_Hun_StanceDash_") then return "dg" end
    return nil
end
-- 这一招按平衡表哪个键（瞬影 = cooldown.ShunYingDodge；普通 / 灵蛇剑 = cost.Dodge / cost.SnakeDodge）
function DCD.keyOf(n)
    if n:find("^GA_Hun_SpecialDash_") then return "ShunYingDodge" end
    if n:find("^GA_Hun_StanceDash_") then return "SnakeDodge" end
    return "Dodge"
end
function DCD.on() return MATCH.role ~= nil and MATCH.state == "fight" end
function DCD.secKey(key)    -- 瞬影冷却秒数：不在交手里 / 武器平衡关着 = 0；表里没写 = 默认 10
    if not DCD.on() or not BAL.active() then return 0 end
    local v = BAL.COOLDOWN[key]
    if v == nil then v = DCD.DEF[key] end
    return v or 0
end
function DCD.costOf(n)      -- 普通闪避这一段扣多少杀气：不在交手里 / 武器平衡关着 / 不是普通闪避 = 0
    if DCD.kind(n) ~= "dg" or not DCD.on() or not BAL.active() then return 0 end
    return BAL.cost(DCD.keyOf(n))
end
function DCD.reset(why)
    DCD.unlock(getP1(), why)
    local had = DCD.me.exp > 0 or DCD.me.sy.on or DCD.op.sy.at
    DCD.me, DCD.op = { sy = {}, exp = 0, lastAt = -100 }, { sy = {} }
    DCD.hintTill, DCD.muteTill, DCD.opMuteTill, DCD.debit = 0, 0, 0, 0
    if had then DCD.log("瞬影冷却清零（%s）", why or "-") end
end
-- 本机瞬影冷却还剩几秒（没在冷却 = nil）
function DCD.left(tn)
    local l = (DCD.me.exp or 0) - tn
    if l > 0 then return l end
    return nil
end
-- 写我的杀气：只走游戏的改属性函数（AttributeUtils.ModifyCharacterAttributeValue，§113.1），不直接写；失败返回 false, 原因
function DCD.setSh(p1, v)
    if not G.attrModSet then return false, "没有 attrModSet" end
    local okC, r1, r2 = pcall(G.attrModSet, p1, "Shachi", v)
    if not okC then return false, tostring(r1) end
    return r1, r2
end
-- ④ 冷却开始：摘掉天赋瞬身的 GE（瞬影激活前就被游戏挡住）。身上本来没有 / 读不到 / 有关闭文件 → 不摘，只靠事后取消
function DCD.lock(p1, sec)
    if DCD.lk or not valid(p1) then return end
    local f = io.open(DCD.LOCK_OFF, "r")
    if f then f:close(); DCD.log("§200.13 瞬影冷却：有 net/sylock_off.txt，不摘天赋，只靠事后取消"); return end
    local have = G.geSet(p1)
    local short = "GE_Talent_" .. DCD.TAL
    if not (have and have[short]) then
        DCD.log("§200.13 瞬影冷却：身上%s %s，不摘，只靠事后取消", have and "没有" or "读不到效果、不知道有没有", short)
        return
    end
    local path = STD.talentPath(DCD.TAL)
    local std = false        -- 是标准数值临时补的天赋（STD.added 里有）：还原时要是标准数值已经摘了，就别再挂回去
    for _, x in ipairs(STD.added or {}) do if x == path then std = true end end
    local ok = LO.removeGE(p1, path)
    local still = ok and (G.geSet(p1) or {})[short]
    DCD.n.lock = DCD.n.lock + 1
    if ok and not still then DCD.lk = { at = now(), std = std, p = p1 } end
    DCD.log("§200.13 瞬影冷却 %g 秒：摘掉天赋 %s %s（第 %d 次）", sec, short,
        (ok and not still) and "成功，冷却里瞬影放不出来" or (ok and "调用成功但还在身上，只靠事后取消" or "失败，只靠事后取消"), DCD.n.lock)
end
-- 冷却到了 / 清零：挂回去（身上已经有了就不挂；标准数值补的、标准数值已经还原了就不挂）
function DCD.unlock(p1, why)
    local lk = DCD.lk
    if not lk then return end
    if not valid(p1) then p1 = lk.p end
    if not valid(p1) then return end           -- 角色没了（换世界中）：留着，下次再挂
    DCD.lk = nil
    local short = "GE_Talent_" .. DCD.TAL
    local have = G.geSet(p1)
    if not have then DCD.lk = lk; return end      -- 读不到身上的效果（角色还没好）：留着，下次再挂
    if have[short] then DCD.log("§200.13 瞬影冷却结束（%s）：天赋 %s 已经在身上，不用挂", why, short); return end
    if lk.std and not STD.added then DCD.log("§200.13 瞬影冷却结束（%s）：%s 是标准数值临时补的、已还原，不挂", why, short); return end
    local ok = LO.applyGE(p1, STD.talentPath(DCD.TAL), "§200.13 挂回天赋 " .. short)
    if not ok then out("!! §200.13 瞬影冷却结束（%s）：天赋 %s 没挂回去", why, short) end
    DCD.log("§200.13 瞬影冷却结束（%s）：天赋 %s %s", why, short, ok and "已挂回" or "!! 没挂回")
end
-- ① 普通闪避扣杀气（每段一次；PRESS 秒内的算同一段）
function DCD.charge(p1, n, tn)
    local cost = DCD.costOf(n)
    if cost <= 0 then return end
    if tn - DCD.me.lastAt <= DCD.PRESS then return end     -- 连段转接：同一下
    DCD.me.lastAt = tn
    local sh = attrOf(p1, "Shachi")
    if not sh then return end
    local new = math.max(0, sh - cost)
    DCD.n.cost = DCD.n.cost + 1
    local short = sh < cost
    if short then DCD.n.short = DCD.n.short + 1 end
    local ok, msg = true, nil
    if new < sh then ok, msg = DCD.setSh(p1, new) end
    if ok then DCD.debit = DCD.debit + (sh - new) end
    if DCD.clogs < DCD.CLOGS or not ok then
        DCD.clogs = DCD.clogs + 1
        out("§200.10 闪避扣杀气：%s −%g（杀气 %.0f→%.0f%s%s，第 %d 段）", n, cost, sh, ok and new or sh,
            short and "，杀气不足照样闪、扣到 0" or "", ok and "" or ("，!! 没扣成：" .. tostring(msg)), DCD.n.cost)
    end
end
-- netSend 看到我新出现的技能时调：普通闪避扣杀气、照发（返回 false）；瞬影冷却中拦了返回 true（调用方不发这招）
function DCD.check(p1, n, act, tn)
    local k = DCD.kind(n)
    if not k or not DCD.on() or not BAL.active() then return false end
    if k == "dg" then DCD.charge(p1, n, tn); return false end
    local s = DCD.me.sy
    s.blocked = s.blocked or {}
    local why
    if not s.on then
        local l = DCD.left(tn)
        if l then why = string.format("冷却还剩 %.1f 秒", l)
        else s.on, s.last, s.sec = true, tn, DCD.secKey("ShunYingDodge") end
    end
    if not why then DCD.muteTill = 0; return false end
    -- 拦：只取消这一个技能；动作要是已经换成闪避就停掉；瞬影扣的杀气写回；dg= 不发
    s.blocked[n] = true
    if DCD.lk then      -- §200.13 摘了天赋还放出来了：摘天赋这条路没挡住（日志留证据，事后取消兜底）
        DCD.n.leak = DCD.n.leak + 1
        local has = (G.geSet(p1) or {})["GE_Talent_" .. DCD.TAL]
        DCD.log("!! §200.13 摘了天赋瞬影还是放出来了（天赋%s；第 %d 次）→ 事后取消兜底", has and "又回到身上了" or "确实不在身上", DCD.n.leak)
    end
    local gone = G.cancelAbilities(p1, function(x) return x == n end)
    local m = montageOf(p1)
    local cut = DGE.isDodge(m) and cutMontage(p1)
    local back = ""
    local sh = attrOf(p1, "Shachi")
    if sh and NET.prevSh and sh < NET.prevSh - 0.01 then
        local ok = DCD.setSh(p1, NET.prevSh)
        back = string.format("，杀气 %.0f→%.0f %s", sh, NET.prevSh, ok and "写回" or "没写回成")
    end
    DCD.muteTill = tn + 0.4
    DCD.hintTill = tn + DCD.HINT
    DCD.n.me = DCD.n.me + 1
    DCD.log("§200 瞬影冷却：%s %s → %s%s%s（第 %d 次）", n, why,
        #gone > 0 and ("已取消 " .. table.concat(gone, ",")) or "没取消到实例", cut and "，动作已停" or "", back, DCD.n.me)
    return true
end
-- 每次发包：我的瞬影停没停（停了开始冷却）；不在交手里清零
function DCD.frame(p1, act, tn)
    if not DCD.on() then
        if DCD.me.exp > 0 or DCD.me.sy.on or DCD.op.sy.at or DCD.lk then DCD.reset("不在交手里") end
        return
    end
    if DCD.lk and not DCD.left(tn) then DCD.unlock(p1, "冷却到了") end
    local s = DCD.me.sy
    local any = false
    for x in pairs(act or {}) do
        if DCD.kind(x) == "sy" and not (s.blocked and s.blocked[x]) then any = true end
    end
    if s.blocked then for x in pairs(s.blocked) do if not (act or {})[x] then s.blocked[x] = nil end end end
    if any then
        s.on, s.last = true, tn
    elseif s.on then
        s.on, s.endAt = false, tn
        local sec = s.sec or 0
        if sec > 0 then
            DCD.me.exp = math.max(DCD.me.exp or 0, tn + sec)
            DCD.log("瞬影：停了，冷却 %g 秒（只挡瞬影，普通闪避照常）", sec)
            DCD.lock(p1, sec)
        end
    end
end
-- 发 dg= 前问：刚拦掉一下瞬影（它的动作可能闪了一帧）不发
function DCD.muted(tn) return tn < DCD.muteTill end
-- 屏幕提示（对局 HUD，交手中）：拦了之后 HINT 秒内显示瞬影冷却还剩几秒。普通闪避不提示（不冷却了；杀气不足也照样闪，不提示）
function DCD.hintRows(tn)
    if tn >= DCD.hintTill then return nil end
    local l = DCD.left(tn)
    if not l then return nil end
    local c = math.ceil(l)
    return { { string.format("瞬影冷却中 还剩 %d 秒", c), string.format("FLASH STEP COOLDOWN %ds", c) } }
end
-- ③ 替身：对方发来的瞬影在对方冷却里（按收到的事件算）就不放，返回 true；普通闪避不挡
function DCD.puppet(e, tn)
    if DCD.kind(e.name) ~= "sy" or not DCD.on() or not BAL.active() then return false end
    local y = DCD.op.sy
    local why
    if y.at and (y.sec or 0) > 0 and tn < y.at + y.sec - DCD.TOL then
        why = string.format("冷却还剩约 %.1f 秒（按上一次瞬影开始算）", y.at + y.sec - tn)
    else
        y.at, y.sec = tn, DCD.secKey("ShunYingDodge")
    end
    if not why then return false end
    DCD.opMuteTill = tn + 0.6
    DCD.n.op = DCD.n.op + 1
    DCD.log("§200 对方瞬影冷却中：远端#%s %s %s → 替身不放（第 %d 次）", tostring(e.id), e.name, why, DCD.n.op)
    return true
end
-- dg= 照播前问：刚挡掉对方一下瞬影就不照播
function DCD.opMuted(tn) return tn < DCD.opMuteTill end

-- ============================================================ §200.11 切武器保持杀气（武器平衡的一部分：平衡表 cost.SwitchKeepShachi）
-- 用户（11-10）："原版的切换武器就回满杀气这一条，能改成切换武器继承当前杀气状态么"。
-- 原版机制（HANDOVER §200.11.1）：游戏通用规则，不是天赋 / 武器效果——Game.locres Tutorial_Weapon_3"更换武器可以回满全部杀气"、
--   UI_Tutorial_04"切换武器会恢复一定的杀气，但有一小段的冷却时间"；日志里切刀斩（GA_Hun_*_SWT*，切武器触发的那招）同一秒杀气跳到上限（Shachi_Max），
--   不是每把武器各存一份（跳到的总是上限，不是那把武器上次的值）。
-- 做法：每次发包读杀气时（SWK.frame），看到杀气跳到上限、并且同时（PEND 秒内）有切武器的证据（新出现的切刀斩技能 / 武器组当前序号变了），
--   就把杀气写回切之前的值（上一次发包时的值，减去这期间闪避扣掉的），走游戏的改属性函数。一次切武器只写回一次。
-- 写回后发包的 sh= 就是写回后的值，对方的 Boss 血条跟着对。只在武器平衡开着、对局交手中；SwitchKeepShachi = 0 关掉
SWK = { PEND = 0.35, IDX_EVERY = 8, LOGS = 40, logs = 0, k = 0, last = nil, idx = nil, swtAt = -100, pend = nil, n = 0 }
function SWK.on() return DCD.on() and BAL.active() and BAL.cost("SwitchKeepShachi") ~= 0 end
-- 切武器触发的切刀斩（Ability.Action.Hun.Weapon.Switch.*）：GA_Hun_<武器>_SWT*；不算：混沌切形态斩 SwitchForm*（不切武器，自带回杀气升级）、教学 / UI 版
function SWK.isSwitch(n)
    return n:find("^GA_Hun_") ~= nil and n:find("_SWT", 1, true) ~= nil and not n:find("SwitchForm", 1, true)
        and not n:find("SWT_UI", 1, true) and not n:find("Tutorial", 1, true)
end
-- netSend 新出现的技能里调：记下切武器的时刻
function SWK.note(n, tn) if SWK.isSwitch(n) then SWK.swtAt = tn end end
function SWK.reset() SWK.last, SWK.idx, SWK.swtAt, SWK.pend = nil, nil, -100, nil end
-- 每次发包（读完杀气后）调：返回这一包要发的杀气（写回了就是写回后的）
function SWK.frame(p1, tn, sh, shm)
    local debit = DCD.debit or 0
    DCD.debit = 0
    if not SWK.on() or not sh then SWK.reset(); return sh end
    SWK.k = SWK.k + 1
    local idxNow
    if SWK.idx == nil or SWK.pend or SWK.k % SWK.IDX_EVERY == 0 then idxNow = LO.curIndex(p1) end
    if SWK.pend then SWK.pend.want = math.max(0, SWK.pend.want - debit) end
    if SWK.last and shm and sh + debit >= shm - 1 and sh + debit > SWK.last + 1 then     -- 这一包里闪避先扣过的也算回去
        SWK.pend = { at = tn, want = math.max(0, SWK.last - debit), from = SWK.last }    -- 跳到上限：等切武器的证据
        if not idxNow then idxNow = LO.curIndex(p1) end
    end
    local p = SWK.pend
    if p then
        local why = (tn - SWK.swtAt <= SWK.PEND and "切刀斩") or (idxNow and SWK.idx and idxNow ~= SWK.idx and "武器序号变了") or nil
        if why then
            SWK.pend, SWK.swtAt = nil, -100
            SWK.n = SWK.n + 1
            local ok, msg = DCD.setSh(p1, p.want)
            if ok then sh = p.want end
            if SWK.logs < SWK.LOGS or not ok then
                SWK.logs = SWK.logs + 1
                out("§200.11 切武器保持杀气（%s）：杀气 %.0f → 上限 %.0f → %s %.0f（第 %d 次）", why, p.from, shm or -1,
                    ok and "写回" or ("!! 没写回成（" .. tostring(msg) .. "）"), p.want, SWK.n)
            end
        elseif tn - p.at > SWK.PEND then
            SWK.pend = nil      -- 跳到上限但没有切武器（破防回满 / 喝药 …）：不管
        end
    end
    if idxNow then SWK.idx = idxNow end
    SWK.last = sh
    return sh
end

local function netSend(p1, tn)
    if CDL.active() then CDL.sample(p1) end         -- §173.12 读秒里记下按着的输入
    local act = activeAbilities(p1, NET.wantAb) or {}
    if NET.prevAbs then
        for n in pairs(act) do
            if not NET.prevAbs[n] then SWK.note(n, tn) end                         -- §200.11 切武器（切刀斩）
            if not NET.prevAbs[n] and (n:find("Clone", 1, true) or n:find("Summon", 1, true))
                and not n:find("Passive", 1, true) then ST.p1SummonAt = tn end      -- §118 我放了召唤（认替身分身时用）
            if not NET.prevAbs[n] and replayable(n) and not NOCTR.check(p1, n, tn)   -- §105.3 红蓝光反击关着时拦掉
                and not STG.check(p1, n, tn)                                          -- §161 硬直中出招拦掉
                and not CDL.check(p1, n, tn)                                          -- §173.7 倒计时里出招拦掉
                and not DCD.check(p1, n, act, tn) then                                -- §200 瞬影冷却中拦掉（普通闪避在这里扣杀气，§200.10）
                -- v0.27.2 大招先压住，看这一帧 / 下几帧的动作：C_Failed（没充能）就不发，放出来了才发（ULT.flushHeld）
                if ULT.isUlt(n) then ULT.held[#ULT.held + 1] = { name = n, ts = LAT.ms(tn), n = 0 }
                else ULT.emit(n, tn, LAT.ms(tn)) end
                if CHG.watched(n) then CHG.watch(p1, "我", n, tn, not ULT.isUlt(n) and NET.evId or nil) end   -- §92 松手检测 / 探针
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
    NET.prevAbs, NET.prevAbsTick = act, ST.ticks       -- 同一次驱动里观察玩家1 直接用（§82.1）
    -- v0.18.3 受击动作：我本机游戏给我播的受击动作（轻击小顿 / 重击 / 击倒 / 击飞……）换成新的一个时次数 +1，
    -- 发 hr=<次数>:<动作名>，对方让替身播同一个
    local hm = montageOf(p1)
    BLK.watch(hm, act, tn)          -- §87 记"开始格挡"的时刻（软格挡按它分精防 / 普防）
    if hm ~= NET.hrPrev and LO.isHitMontage(hm) then
        NET.hrN, NET.hrT = (NET.hrN or 0) + 1, hm
    end
    -- §103 喝药：喝药技能 GA_Medicine_* 被 replayable 排除了（替身真激活会扣药 / 回血），对面以前只看到血条涨。
    -- 改成发动作：喝药动作换成新的一个时次数 +1，发 med=<次数>:<动作名>，对方替身只播这个动作
    if hm ~= NET.hrPrev and LO.isMedMontage(hm) and not NOMED.block(p1, hm, tn) then   -- §108 禁用血瓶时拦掉、不发
        NET.medN, NET.medT = (NET.medN or 0) + 1, hm
    end
    NOMED.frame(p1, tn)
    -- §111 技能里面按键换的动作（紫冥剑召唤）：换成新的一个时次数 +1，发 sub=<次数>:<动作名>，对方替身照播
    if hm ~= NET.hrPrev and (LO.isSubMontage(hm) or CHG.isLaserSub(hm, NET.hrPrev)) and GCD.mine(hm, tn) then    -- §139 加独眼弓激光；§184 冷却里的火枪不发
        NET.subN, NET.subT = (NET.subN or 0) + 1, hm
    end
    GCD.frame(p1, hm, tn)           -- §184 火枪收没收掉（两边）+ 本机冷却里拦召唤 / 提示
    -- §118 闪避动作（往哪边翻）：换成新的一个时次数 +1，发 dg=<次数>:<动作名>，对方替身翻同一个方向
    if hm ~= NET.hrPrev and DGE.isDodge(hm) and not DCD.muted(tn) then     -- §200 刚拦掉的瞬影动作不发
        NET.dgN, NET.dgT = (NET.dgN or 0) + 1, hm
    end
    ZMX.fxProbe(p1, hm ~= NET.hrPrev and hm or nil, tn)     -- §119 以后查布局闪避的金光
    if hm ~= NET.hrPrev and hm:find("C_Failed", 1, true) then ULT.watch(p1, false, "我大招失败 " .. hm, tn) end   -- v0.27.1
    ULT.flushHeld(p1, hm, tn)          -- v0.27.2 压住的大招：放出来了才发
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
    if not NET.wgeStr or ST.ticks % 90 == 30 or ST.ticks == NET.wgeAt then NET.wgeStr = LO.encodeWge(p1) end    -- §118 武器效果（升级 / 形态 GE）
    -- §109 皮肤（每 3 秒读一次；只在菜单里能换）
    if NET.ofStr == nil or ST.ticks % 90 == 45 then NET.ofStr = LO.encodeOutfit(p1) or "" end
    NET.seq = NET.seq + 1
    fileWrite(F_LOCAL, string.format(
        "v=2\nseq=%d\nmap=%s\nx=%.1f\ny=%.1f\nz=%.1f\nyaw=%.1f\nvx=%.1f\nvy=%.1f\nw=%s\nev=%s\nhp=%.1f\nhpm=%.1f\nres=%s\n"
        .. "mt=%s\narena=%s\ndead=%d\nrdy=%d\nquit=%d\natt=%s\nwc=%s\narm=%d\npas=%s\nwcs=%s\nbrk=%d:%s\nhr=%d:%s\nlk=%d\nsh=%.1f\nshm=%.1f\n",
        NET.seq, mapName(p1), loc.X, loc.Y, loc.Z, rot.Yaw, vx, vy, ST.p1Weapon or STD.idOf(NET.wcStr) or "",     -- §155 没切过武器时按手上配置
        table.concat(evs, ","),
        hp or -1, hpm or -1, table.concat(res, ","), MATCH.wire.mt, MATCH.wire.arena, MATCH.wire.dead,
        MATCH.wire.rdy, MATCH.wire.quit, NET.attStr or "", NET.wcStr or "", LO.armed(p1) and 1 or 0, NET.pasStr or "", NET.wcsStr or "", NET.brkN or 0, NET.brkM or "-", NET.hrN or 0, NET.hrT or "-",
        NET.myLk(p1),                    -- v0.23.3 lk=1：我锁定着对手（对方据此让替身出招时追着他）；§132 也问瞄准组件
        sh or -1, shm or -1)
        .. AIR.wire(AIR.airOf(p1))      -- v0.24.2 air= / vz=：我在不在空中、竖直速度
        .. "bar=" .. NET.barCfg .. "\n"    -- v0.25.0 我的对手血条档位（只有主机的算数）
        .. "rkd=" .. RKC.wire() .. "\n"    -- §179.3 武林盟主客机复核：对不上的次数（联机程序上报时带上）
        .. "bo=" .. NET.boCfg .. "\n"      -- v0.26.3 我的局数设置（只有主机的算数）
        .. "dm=" .. NET.dmCfg .. "\n"      -- §86 我的伤害倍率设置（只有主机的算数）
        .. "ab=" .. NET.abCfg .. "\n"      -- §87 我的"全部可格挡"设置（只有主机的算数）
        .. "ctr=" .. NET.flagCfg.ctr .. "\n"   -- §105.3 我的"红蓝光反击"设置（只有主机的算数）
        .. "bal=" .. NET.flagCfg.bal .. "\n"   -- §106.5 我的"武器平衡"设置（只有主机的算数）
        .. "medok=" .. NET.flagCfg.med .. "\n"   -- §108 我的"血瓶"设置（只有主机的算数；med= 已经是喝药动作）
        .. "npos=" .. NET.flagCfg.npos .. "\n"  -- §128.2 我的"对手位置严格跟随"设置（只有主机的算数）
        .. "std=" .. NET.flagCfg.std .. "\n"    -- §144 我的"标准数值"设置（只有主机的算数）
        .. "cs=" .. NET.flagCfg.cs .. "\n"      -- §181 我的"作弊数据采样"设置（只有主机的算数）
        .. "cfgh=" .. CFG.wire() .. "\n"       -- §158 我的数值表哈希（只有主机的算数；客机对不上就来要）
        .. "rfp=" .. RFP.wire() .. "\n"       -- §210 这一场的规则指纹（对方比；联机程序排位时报给服务器）
        .. "ult0=" .. NET.resCfg.ult0 .. "\nsp0=" .. NET.resCfg.sp0 .. "\nresm=" .. NET.resCfg.resm .. "\n"   -- §113 我的开局精纯杀气 / 暗源 / 每场每局（只有主机的算数）
        .. "ultx=" .. NET.resCfg.ultx .. "\n"   -- §113.4 我的精纯杀气获取倍率 %（只有主机的算数）
        .. "acc=" .. NET.resCfg.acc .. "\n"     -- §170.1 我的饰品等级设置（只有主机的算数）
        .. "accn=" .. NET.resCfg.accn .. "\naccban=" .. NET.accBanCfg .. "\n"   -- §176 我的生效饰品数量 / 禁用饰品（只有主机的算数）
        .. "wpnban=" .. WBAN.cfg.wpnban .. "\nedgeban=" .. WBAN.cfg.edgeban .. "\n"   -- §180 我的禁用武器 / 影之武装（只有主机的算数）
        .. WBAN.wire()                                                        -- §180 我装着的 wpn=<武器,武器> / edg=<影武,影武>（主机开局前复核）
        .. "med=" .. (NET.medN or 0) .. ":" .. (NET.medT or "-") .. "\n"   -- §103 喝药动作（次数:动作名）
        .. "sub=" .. (NET.subN or 0) .. ":" .. (NET.subT or "-") .. "\n"   -- §111 技能里面换的动作（紫冥剑召唤；次数:动作名）
        .. "dg=" .. (NET.dgN or 0) .. ":" .. (NET.dgT or "-") .. "\n"     -- §118 闪避动作（次数:动作名）
        .. "tl=" .. NET.resCfg.tl .. "\n"                                  -- §173 我的回合时限设置（只有主机的算数）
        .. "tk=" .. RT.wire() .. "\n"                                      -- §173 这一回合交手后我受到的伤害（回合:累计），主机按它判时间到
        .. "inf=" .. INF.mine(p1, tn) .. "\n"                               -- §160 我身上的异常状态（类型:次数:段:积累,…），对方替身跟着
        .. "wge=" .. (NET.wgeStr or "") .. "\n"                                -- §118 我身上的武器效果 GE（替身也上）
        .. "gd=" .. (BLK.on and 1 or 0) .. "\n"                            -- §104 我在不在格挡（对方据此预测替身的反应）
        .. "tc=" .. TOUCH.wire(tn) .. "\n"                                 -- §107 我哪几招在本机碰到了替身（本地 AI 据此回报）
        .. "td=" .. TOUCH.wireDmg() .. "\n"                                -- §115 这几招在本机打出的伤害（已乘系数，本地 AI 按它扣血）
        .. "aim=" .. BOWAIM.wire() .. "\n"                                 -- §139.3 放独眼弓时我的镜头朝向（俯仰:左右）
        .. "eye=" .. BOWEYE.wire(p1, tn) .. "\n"                              -- §139.9 我的光柱有没有眼睛（1 / 0 / - 还没数过）
        .. "wlv=" .. STD.wireLv() .. "\n"                                 -- §148 我手上武器 / 影之武装的等级（对方替身按它补等级倍率）
        .. (NET.ofStr ~= "" and ("of=" .. NET.ofStr .. "\n") or "")        -- §109 我的皮肤（行名:肤色:帽子）
        .. LAT.wire(tn, NET.events)        -- v0.27.0 ts= / tse= / evt=：测往返和包龄
        .. CHG.wire(tn))                   -- §92 rel=<招式号>:<按了几秒>：蓄力招松手
end

-- §83 连着管道：这次驱动之前收到的每个包都按顺序过一遍（LAT.onPacket 每个包一次，包龄 / 往返照算）；
-- 没连：照旧读文件里最新的那一个
local function netRecv(p1, tn)
    local list = PIPE and PIPE.recv()
    if not list then list = { fileReadKV(F_REMOTE) } end
    for _, t in ipairs(list) do
        -- §141 观战：主机转发来的两路包（src=h / src=c）交给观战代码，不当成对手
        if t.src then
            if ST.spec then ST.spec.feed(t, tn) end
        else
            NET.recvOne(p1, tn, t)
        end
    end
end

function NET.recvOne(p1, tn, t)
    if not (t and t.x and t.v == "2") then return end
    local seq = tonumber(t.seq) or -1
    -- §85 对手从 AI 换成真人（AI 对战时开着的房间有人进来，联机程序把它转正了）：序号 / 事件号都是另一个人的，当新连接；
    -- 结束 AI 那局、换替身在 aiSwapStep。§85.5：昵称变了也算（tests\fake_remote.py 当真人时自己也带 ai=1，序号还和 AI 一样从 500000 起）
    local swap = NET.rai and (t.ai ~= "1" or (t.nm or "") ~= (NET.rnm or ""))
    if swap then
        out("对手从 AI 换成真人（%s），按新连接处理", tostring(t.nm))
        NET.lastSeq, NET.aiSwap = -1, "real"
        NET.swapName = (t.nm and t.nm ~= "") and t.nm or nil
        -- §116 我是客机 = 是我从 AI 对战里去加入了别人的房间（16:36 实测：点了大厅里 Q317 的房间，却提示"Q317 加入了你的房间"）
        NET.swapAsClient = (MATCH.session and MATCH.session.role) == "client"
    elseif not NET.rai and t.ai == "1" and (t.aiback or "") ~= "" then
        -- 真人离开后联机程序重开的 AI（包里 aiback= 离开的人的昵称）：提示"XXX 已离开房间，AI 对战已重新开始"
        out("真人对手 %s 离开，AI 对战重新开始", t.aiback)
        NET.lastSeq, NET.aiSwap, NET.swapName = -1, "ai", t.aiback
    end
    if seq == NET.lastSeq then return end
    if seq < NET.lastSeq then
        if seq > NET.lastSeq - 100 then return end   -- 乱序到达的旧包，丢掉
        out("远端序号回退 %d -> %d（对方重启了？），重置", NET.lastSeq, seq)
        NET.lastEvIn, NET.wTried, NET.lastResIn, NET.brkIn, NET.hrIn, NET.medIn, NET.subIn, NET.resAtk = 0, nil, 0, nil, nil, nil, nil, {}
        LAT.reset(); CHG.reset(); PRED.reset(); DGE.nIn = nil; INF.reset(); GCD.reset("对方重启"); DCD.reset("对方重启")     -- §184 / §200
    end
    if NET.lastSeq == -1 or NET.lastRecvAt < tn - 5 then
        out("开始收到远端 v2 状态 seq=%d 地图=%s 武器=%s", seq, tostring(t.map), tostring(t.w))
        NET.rwcCur, NET.rwcOff = nil, nil       -- v0.26.1 新连接：另一把等对方切一次武器才知道
        LO.switchBad, LO.has = nil, nil         -- §195 切序号这条路每次连接重新试
        -- v0.18.2（17:13 实测）：换了个对手 / 对方重启后序号反而更大时，上面的"序号回退"不触发，招式号还停在上一个对手的 #14，
        -- 新对手的 #1–#14 全被当成"已处理"丢掉。断了 5 秒以上再收到就算新连接，各计数清零（旧事件早超过 EV_KEEP 了）
        NET.lastEvIn, NET.wTried, NET.lastResIn, NET.brkIn, NET.hrIn, NET.medIn, NET.subIn, NET.resAtk = 0, nil, 0, nil, nil, nil, nil, {}
        LAT.reset(); CHG.reset(); PRED.reset(); DGE.nIn = nil; INF.reset()      -- §104 换了对手：防住率从先验重新学
        GCD.reset("换对手 / 新连接")      -- §184 火枪冷却清零
        DCD.reset("换对手 / 新连接")      -- §200 闪避冷却清零
        RFP.reset()                       -- §210 上一个对手的规则指纹不算
        CS.cur = nil                                                            -- §181 换了对手：当前这份采样丢掉（不混进下一个人）
    end
    NET.lastSeq, NET.lastRecvAt, NET.rx = seq, tn, NET.rx + 1
    local pktAge = LAT.onPacket(t, tn)                                         -- v0.27.0 往返 / 时钟差 / 包龄
    -- v0.27.0 evt=<招式号:对方出招时的 ts>：这招晚到了多久（没有 = 按这一包的包龄）。§181 提到前面解析一次，作弊数据采样也用
    local evt = {}
    for id, ts in (t.evt or ""):gmatch("(%d+):(%-?%d+)") do evt[tonumber(id)] = tonumber(ts) end
    local list = {}
    for id, name in (t.ev or ""):gmatch("(%d+):([%w_]+)") do
        local ets = evt[tonumber(id)]
        list[#list + 1] = { id = tonumber(id), name = name, rcv = tn, age = ets and LAT.age(ets, tn) or pktAge }
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    CS.safe("onPacket", CS.onPacket, t, tn, pktAge, evt, list)                -- §181 作弊数据采样（只读这个包，开着才采；出错不打断收包）
    NET.pos = { X = tonumber(t.x) or 0, Y = tonumber(t.y) or 0, Z = tonumber(t.z) or 0 }
    NET.yaw = tonumber(t.yaw) or 0.0
    local vel = { X = tonumber(t.vx) or 0, Y = tonumber(t.vy) or 0 }
    LAT.onVel(NET.vel, vel, tn)                                                -- v0.27.0 急转 → 暂不外推
    NET.vel = vel
    NET.rmt, NET.rarena, NET.rdead = t.mt, t.arena, tonumber(t.dead) or 0     -- M4 对局字段，matchStep 处理
    RT.onPacket(t)                                                             -- §173 对方这一回合受到的伤害 tk=
    BOWAIM.recv(t.aim, tn)
    BOWEYE.recv(t.eye)                                                         -- §139.9 对方的光柱有没有眼睛                                                     -- §139.3 对方放独眼弓时的镜头朝向
    NET.rlk = t.lk == "1"                                                      -- v0.23.3 对方锁定着我（旧版没有这个字段 = 不追）
    NET.rai = t.ai == "1"                                                      -- v0.26.0 对方是 AI（本地 AI / 测试假对手）：回合倒计时才强制归位
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
    -- §111 对方技能里面换的动作（紫冥剑召唤武器）→ 替身照播（动作自己带召唤 / 伤害的通知）。第一次收到只记次数。
    -- 动作是替身放 DB 时才加载的，表里没有就重扫一次；播过的记进这一招的 f.mon，判定窗口接着等（CHG.keepJudge）
    local sn, sm = (t.sub or ""):match("^(%d+):([%w_%-]+)$")
    sn = tonumber(sn)
    if sn then
        local laser = CHG.isLaserIn(sm)                  -- §139 独眼弓激光的光束 / 松手那一箭
        if NET.subIn and sn > NET.subIn and (laser or LO.isSubMontage(sm)) and not REP.on then
            local pupS = puppet()
            montageByName(sm, true)
            local called, how, skip
            if not laser and sn > NET.subIn + 1 then GDMG.noteOther("op", "中间漏了召唤动作", tn) end   -- §212 漏掉的可能是锤 / 伞
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
        if NET.hrIn and hn2 > NET.hrIn and LO.isHitMontage(ht2) and not REP.on then
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
    NET.rpas = t.pas                                    -- v0.17.2 对方的天赋 / 饰品被动；没有这个字段（旧版本）= nil，不动替身
    NET.rof = LO.decodeOutfit(t.of)                     -- §109 对方的皮肤；没有这个字段（旧版本 / 本地 AI）= nil，不动替身

    local myMap = mapName(p1)
    if t.map and t.map ~= myMap and NET.mapWarned ~= t.map then
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
    for _, r in ipairs(rl) do
        if r.id > NET.lastResIn then
            NET.lastResIn = r.id
            local first = NET.resAtk[r.atk]
            if first and first ~= r.id then
                NET.resDup = (NET.resDup or 0) + 1
                out("  !! 我第 #%d 招又收到一个结果 #%d（%s，先前是 #%d），重复回报，忽略（第 %d 次）",
                    r.atk, r.id, RES_NAME[r.kind] or r.kind, first, NET.resDup)
            else
                NET.resAtk[r.atk], NET.resAtk[r.atk - 300] = r.id, nil
                NET.resV[r.id] = r.v
                applyRemoteResult(p1, r)
            end
        elseif r.kind == "hit" and NET.resV[r.id] and r.v > NET.resV[r.id] + 0.5 then
            -- v0.17.3：同一招后几段的伤害由对方累加进同一条结果（见 netJudge）
            out("◆ 你的第 #%d 招追加命中 -%.0f（这招累计 -%.0f）", r.atk, r.v - NET.resV[r.id], r.v)
            LO.zmHeal(p1, r.atk, r.v - NET.resV[r.id])
            NET.resV[r.id] = r.v
        end
    end
    NET.resV[NET.lastResIn - 50] = nil

    -- 替身血量以对方回报为准（本机砍替身掉的血只是预测，会被这里覆盖）
    local rhp, rhpm = tonumber(t.hp), tonumber(t.hpm)
    if valid(pup) and rhp and rhp >= 0 then
        if rhpm and rhpm > 0 and math.abs((attrOf(pup, "Health_Max") or 0) - TOUCH.localHp(rhpm)) > 1 then setAttr(pup, "Health_Max", TOUCH.localHp(rhpm)) end   -- §207 本地 AI 临时加的那份带上
        local c = hpOf(pup)
        if c and c > 0 and math.abs(c - TOUCH.localHp(rhp)) > 1 then
            if rhp > 0 then setAttr(pup, "Health", TOUCH.localHp(rhp)); ST.pupHpSeen = TOUCH.localHp(rhp) end   -- §107 校正不算碰到
            if NET.remoteHp ~= rhp then out("替身血量按对方回报校正 %.0f -> %.0f", c - (TOUCH.headNow or 0), rhp) end
        end
        if rhp <= 0 and (NET.remoteHp or 1) > 0 then out("◆ 对方阵亡（回报 hp=0）") end
        NET.remoteHp = rhp
    end
    -- v0.24.0 对手血条（OPPBAR）用：最大血量、对方自己的杀气 / 杀气上限（旧版没有 sh= = 血条杀气不动）
    if rhpm and rhpm > 0 then NET.remoteHpm = rhpm end
    NET.rsh, NET.rshm = tonumber(t.sh), tonumber(t.shm)
    -- v0.25.0 对方的血条档位（我是客机时按它走）、对方联机程序版本（av=，v0.22.0 起才有；空 = 更旧）
    local rb = tonumber(t.bar)
    if rb ~= NET.rbar then
        if (MATCH.session and MATCH.session.role) == "client" and rb then out("对手血条：主机设为 %d（2 血量+杀气 / 1 只显示血 / 0 不显示）", rb) end
        NET.rbar = rb
    end
    CFG.onPacket(t.cfgh, now())     -- §158 主机的数值表哈希：对不上就经可靠通道要一份
    RFP.onPacket(t.rfp, now())      -- §210 对方这一场的规则指纹：和我的比
    local rbo = tonumber(t.bo)      -- v0.26.3 对方的局数设置（我是客机时按它走）
    if rbo ~= NET.rbo then
        if (MATCH.session and MATCH.session.role) == "client" and rbo then out("局数：主机设为 %d 局（先赢 %d 回合）", rbo, NET.toWin(rbo)) end
        NET.rbo = rbo
    end
    local rdm = tonumber(t.dm)      -- §86 对方的伤害倍率（我是客机时按它走）
    if rdm ~= NET.rdm then
        if (MATCH.session and MATCH.session.role) == "client" and rdm then out("伤害倍率：主机设为 %d%%（下一局生效）", rdm) end
        NET.rdm = rdm
    end
    local rab = tonumber(t.ab)      -- §87 对方的"全部可格挡"设置（我是客机时按它走）
    if rab ~= NET.rab then
        if (MATCH.session and MATCH.session.role) == "client" and rab then out("全部可格挡：主机设为%s", rab == 1 and "开" or "关") end
        NET.rab = rab
    end
    for _, k in ipairs(NET.FLAG_KEYS) do   -- §105.3 / §106.5 / §108 对方的开关型设置（我是客机时按它走）
        local r = tonumber(t[NET.FLAG_WIRE[k] or k])
        if r ~= NET.rflag[k] then
            if (MATCH.session and MATCH.session.role) == "client" and r then
                out("%s：主机设为%s（下一局生效）", NET.FLAG_NAME[k][1], r == 1 and "开" or "关")
            end
            NET.rflag[k] = r
        end
    end
    for _, k in ipairs(NET.RES_KEYS) do    -- §113 对方的开局精纯杀气 / 暗源（我是客机时按它走）
        local r = tonumber(t[k])
        if r ~= NET.rres[k] then
            if (MATCH.session and MATCH.session.role) == "client" and r then out("%s：主机设为 %s（下一局生效）", NET.RES_NAME[k][1], NET.resText(k, r)[1]) end
            NET.rres[k] = r
        end
    end
    if t.accban ~= NET.raccban then        -- §176 对方的禁用饰品（我是客机时按它走）
        if (MATCH.session and MATCH.session.role) == "client" and t.accban then out("禁用饰品：主机设为 %s（下一局生效）", ACC.banText(t.accban, 1)) end
        NET.raccban = t.accban
    end
    WBAN.recv(t)                           -- §180 主机的禁用武器 / 影之武装名单 + 对方装着的 wpn= / edg=
    if (t.av or "") ~= NET.rav then
        NET.rav = t.av or ""
        if NET.rav ~= VERSION then out("!! 版本不一致：我 v%s，对方 v%s", VERSION, NET.rav ~= "" and NET.rav or "0.21 及以前") end
    end
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
-- 只发一次、丢了就没了的事件（弃权、回合结果、对局结果）另走联机程序的可靠通道：按序号确认、超时重发、对方去重并按顺序交付。
-- Lua 这边只交换文件：REL.send 把事件写进 net/rel_out.txt（e<本地号>=<类型> <内容>），联机程序收下后在 rel_in.txt 回 took=<本地号>，
-- 这里删掉；对方的事件在 rel_in.txt 的 d<交付号>=，处理完在 rel_out.txt 回 got=<交付号>。两个文件都以 end=1 结尾，读到半截的不算。
-- 联机程序是旧版（不认 rel_out.txt）时事件只是发不出去，状态包里的旧字段（quit= / mt=）照样兜底
-- （顶层 local 已经接近 Lua 的 200 个上限，文件名 / 常量 / 函数都放进 REL 表里）
local REL = { fOut = NET_DIR .. "/rel_out.txt", fIn = NET_DIR .. "/rel_in.txt", maxOut = 64,
              boot = string.format("%x%04x", os.time(), math.random(0, 0xffff)), lid = 0, out = {}, gb = "", got = 0,
              on = {}, ended = {}, n = 0 }

function REL.write()
    local t = { "b=" .. REL.boot, "gb=" .. REL.gb, "got=" .. REL.got }
    for _, e in ipairs(REL.out) do t[#t + 1] = string.format("e%d=%s", e.id, e.data) end
    t[#t + 1] = "end=1"
    fileWrite(REL.fOut, table.concat(t, "\n") .. "\n")
end

function REL.readIn()
    local t = fileReadKV(REL.fIn)
    if not (t and t["end"]) then return nil end
    local ids = {}
    for k in pairs(t) do
        local n = tonumber(k:match("^d(%d+)$") or "")
        if n then ids[#ids + 1] = n end
    end
    table.sort(ids)
    return t, ids
end

do  -- 加载时 rel_in.txt 里已有的是上一次（上一局游戏）的：记下启动号和最大交付号，不处理
    local t, ids = REL.readIn()
    if t then REL.gb, REL.got = t.b or "", ids[#ids] or 0 end
    REL.write()
end

-- kind 不带空格；data 一行文字
function REL.send(kind, data)
    REL.lid = REL.lid + 1
    local line = (kind .. " " .. tostring(data or "")):gsub("[\r\n]", " ")
    REL.out[#REL.out + 1] = { id = REL.lid, data = line }
    while #REL.out > REL.maxOut do table.remove(REL.out, 1) end   -- 联机程序没在收（没开 / 旧版）：只留最近的
    REL.write()
    out("可靠事件 → #%d %s", REL.lid, line)
end

-- 每帧：收对方的事件（按交付号顺序，各处理一次），删掉联机程序已经收下的
function REL.poll()
    local t, ids = REL.readIn()
    if not t then return end
    local changed = false
    if (t.b or "") ~= REL.gb then REL.gb, REL.got, changed = t.b or "", 0, true end   -- 联机程序开了新的一次联机：交付号从 1 重数
    for _, n in ipairs(ids) do
        if n > REL.got then
            REL.got, changed = n, true
            local line = t["d" .. n] or ""
            local kind, rest = line:match("^(%S+)%s*(.*)$")
            local fn = kind and REL.on[kind]
            REL.n = REL.n + 1
            out("可靠事件 ← #%d %s%s", n, line, fn and "" or "（不认识，忽略）")
            if fn then
                local ok, err = pcall(fn, rest)
                if not ok then out("!! 可靠事件 %s 处理出错：%s", tostring(kind), tostring(err)) end
            end
        end
    end
    if t.ob == REL.boot then
        local took = tonumber(t.took) or 0
        while #REL.out > 0 and REL.out[1].id <= took do table.remove(REL.out, 1); changed = true end
    end
    if changed then REL.write() end
end

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
    -- 2026-11-05：以前每 2 次发一包（驱动又只有 15.6 次 / 秒，对面只收到 7.8 帧 / 秒）。现在每次都发，约 30 包 / 秒
    -- §82.4：ST.SPLIT 时发包挪到下一帧（NET.sendStep），和收包 / 驱动替身错开，单帧不再一口气做完
    if ST.SPLIT then NET.sendDue = true else netSend(p1, tn) end

    -- 远端数据 1 秒内新鲜才驱动，避免旧文件把替身钉在过期位置
    local pup = puppet()
    local fresh = NET.pos and tn - NET.lastRecvAt < 1.0
    if not REP.on and valid(pup) and fresh then
        if not NET.driving then setBraking(pup, true); NET.driving = true end
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
            NPM.setTarget(pup, NET.pos, NET.vel, tn - (age or 0), why == "急转" or not age, AIR.rair)
            local a = NPM.aim(tn)
            tgt = { X = a.X, Y = a.Y, Z = NET.pos.Z }
        end
        NET.lastErr = drivePuppet(pup, tgt, NET.vel, yaw)
        DGE.step(pup, tn)          -- §118 替身闪避方向跟对方一样
        INF.step(pup, tn)          -- §160 替身的冰冻 / 点燃 / 中毒…跟对方一样（本机自己积出来的撤掉）
        AIR.step(p1, pup, tn)      -- v0.24.2 对方在空中 → 替身起跳；排队的空中招
        HOV.watchPuppet(pup, tn, AIR.rair == true)   -- §99 对方在地上替身却往下掉 / 被引擎藏起 → 悬空、重新显示
        LAT.step(tn)               -- v0.27.0 追帧：等替身开始播这招的蒙太奇
        ANIM.step(tn)              -- §100 放成功却没换动作：重放 / 直接播
        ULT.step(p1, tn)           -- v0.27.1 大招资源诊断（只在有等着的诊断时读属性）
        CHG.step(p1, pup, tn)      -- §92 蓄力探针（只在有在记的条目时读）
        ZMX.step(pup, tn)          -- §119 紫冥剑实验（只在替身刚放 DB 时读）
        -- 替身的架势在本机保持满值：破防应由对方判定，不能被我本机的刀打出来（v0.9.5 日志里有本机 BreakEscape）
        if ST.ticks % 10 == 0 then
            local mx, cur = attrOf(pup, "Shachi_Max"), attrOf(pup, "Shachi")
            if mx and cur and cur < mx then setAttr(pup, "Shachi", mx) end
            -- §113 暗源同理：对方放成功了才会发来，替身自己不在铃铛回复，以前打几局就耗光、影之武装放不出来
            local smx, scur = attrOf(pup, "SpiritShadow_Max"), attrOf(pup, "SpiritShadow")
            if smx and scur and scur < smx then setAttr(pup, "SpiritShadow", smx) end
        end
        protectPuppet(pup)
        -- v0.16.0 配装同步：对方的攻击属性写进替身；替身被本机玩家换装带偏就重装对方武器
        -- v0.23.7 替身在放对方的影之武装（EDGE_HOLD 秒内）：攻击力乘 PvP 系数，放完恢复（LO.apply 里乘）
        -- §86 再乘房间的伤害倍率（对局中用开局时定下的）
        LO.rescale(pup, tn)        -- §106 再乘武器平衡系数（族 / 单招）
        if ST.ticks % 15 == 0 then LO.guard(pup) end
        if ST.ticks % 8 == 0 then
            local okD, errD = pcall(LO.dress, pup, p1)
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
        -- v0.9.17 实测：CanActivateNewState(InCombat) 恒 false，玩家自己也从不 InCombat —— 它不是角色状态机里的状态，已停用
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
        if c and c > 0 and NET.remoteHp and NET.remoteHp > 0 and c < TOUCH.localHp(NET.remoteHp) - 1 then
            setAttr(pup, "Health", TOUCH.localHp(NET.remoteHp))      -- §207
        end
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
        PRED.report()      -- §104
    end
    if fresh and ST.ticks % 300 == 150 then LAT.report() end      -- v0.27.0 每 10 秒一行延迟统计
end

-- ============================================================ M0：状态 / dump / 实验

local function relationProbe(fromActor, toActor, label)
    local fc1, fc2 = factionComp(fromActor), factionComp(toActor)
    if not (valid(fc1) and valid(fc2)) then out("  关系[%s]: 阵营组件缺失", label); return end
    local v2 = factionValue(toActor)
    local tries = {
        { "GetFactionRelation(对方组件)", function() return fc1:GetFactionRelation(fc2) end },
        { "GetFactionRelation(对方角色)", function() return fc1:GetFactionRelation(toActor) end },
        { "GetFactionRelationWithTag(对方阵营)", function() return fc1:GetFactionRelationWithTag(v2) end },
    }
    for _, t in ipairs(tries) do
        local ok, r = pcall(t[2])
        if ok then out("  关系[%s] %s = %s", label, t[1], anyToStr(r))
        else out("  关系[%s] %s 失败: %s", label, t[1], tostring(r)) end
    end
end

local function status()
    out("========== 状态 v%s ==========", VERSION)
    local pc, p1, pup = getP1PC(), getP1(), puppet()
    out("玩家1 控制器: %s", short(pathOf(pc)))
    out("玩家1 角色  : %s", short(pathOf(p1)))
    out("替身控制器  : %s", short(pathOf(ST.secondPC)))
    out("替身角色    : %s", short(pathOf(pup)))
    local n = 0
    local pcs = FindAllOf("PlayerController")
    if pcs then for _ in pairs(pcs) do n = n + 1 end end
    out("PlayerController 总数: %d", n)
    for _, e in ipairs({ { "玩家1", p1 }, { "替身", pup }, { "对照怪", ST.testMonster } }) do
        if valid(e[2]) then
            local c, b = hpOf(e[2])
            out("[%s] 血量 %s/%s  阵营 %s  动画 %s", e[1], tostring(c), tostring(b),
                factionName(e[2]), montageOf(e[2]))
        end
    end
    if valid(p1) and valid(pup) then
        relationProbe(p1, pup, "玩家1→替身")
        relationProbe(pup, p1, "替身→玩家1")
    end
    out("接下来 10 秒做血量稳定性追踪，请站着别动")
    ST.hpTrace, ST.hpTraceSeen = 10, nil
end

local function dumpFnParams(path)
    local fn = StaticFindObject(path)
    if not valid(fn) then out("  %s: 找不到", path); return end
    local ps = {}
    pcall(function()
        fn:ForEachProperty(function(p)
            local n = "?"
            local c = "?"
            pcall(function() n = p:GetFName():ToString() end)
            pcall(function() c = p:GetClass():GetFName():ToString() end)
            ps[#ps + 1] = n .. ":" .. c
        end)
    end)
    out("  %s(%s)", shortName(path:gsub(":", ".")) or path, table.concat(ps, ", "))
end

local function dumpAttrs(actor, label)
    local set = attrSetOf(actor)
    if not valid(set) then out("[%s] 没有属性集", label); return end
    local cls = set:GetClass()
    local parts = {}
    local c = cls
    for _ = 1, 4 do
        if not valid(c) then break end
        pcall(function()
            c:ForEachProperty(function(p)
                local n = "?"
                pcall(function() n = p:GetFName():ToString() end)
                local cur = attrOf(actor, n)
                if cur ~= nil then parts[#parts + 1] = string.format("%s=%.1f", n, cur) end
            end)
        end)
        local okS, sup = pcall(function() return c:GetSuperStruct() end)
        c = okS and sup or nil
    end
    out("[%s] 属性 %s: %s", label, short(pathOf(set)), table.concat(parts, "  "))
end

-- ============================================================ 武器系统探针（只读）
-- v0.6.3 找到了入口（Character Weapons Component / Add Weapon And SwitchTo / Switch Weapon Func ...），
-- 这一步只打印函数签名和读当前值，不调用任何会改状态的函数；按签名写换武器是下一版的事

local function fnameOrStr(v)
    if type(v) == "userdata" then
        local ok, s = pcall(function() return v:ToString() end)
        if ok and s then return tostring(s) end
        if valid(v) then return short(pathOf(v)) end
    end
    return anyToStr(v)
end

-- v0.6.4 崩溃（crash_2026_11_03_18_48_58，UE4SS.dll+0x2be3a7 读 0xff010019）：
-- 对任意属性盲调 GetPropertyClass/GetStruct/GetEnum/GetInner，类型不对时 UE4SS 把无关字段当指针读，pcall 拦不住。
-- 现在先看类型名，只对确定类型调用对应方法
local function propType(p)
    local c = "?"
    pcall(function() c = p:GetClass():GetFName():ToString() end)
    local extra = nil
    if c == "ObjectProperty" or c == "ClassProperty" then
        pcall(function() extra = p:GetPropertyClass():GetFName():ToString() end)
    elseif c == "StructProperty" then
        pcall(function() extra = p:GetStruct():GetFName():ToString() end)
    end
    c = c:gsub("Property$", "")
    return extra and (c .. "<" .. extra .. ">") or c
end

-- 返回 { {name, type, out=bool, ret=bool}, ... }
local function signature(fn)
    local ps = {}
    pcall(function()
        fn:ForEachProperty(function(p)
            local n = "?"
            pcall(function() n = p:GetFName():ToString() end)
            -- 不调 HasAnyPropertyFlags（同样有读错字段的风险）；蓝图函数的局部变量也会出现在这里，
            -- 名字形如 CallFunc_* / K2Node_* / Temp_*，标成 local
            local isRet = n == "ReturnValue"
            local isLocal = n:match("^CallFunc_") or n:match("^K2Node_") or n:match("^Temp_") or n:match("^Local")
            ps[#ps + 1] = { name = n, type = propType(p), ret = isRet, loc = isLocal and true or false }
        end)
    end)
    return ps
end

local function sigStr(ps)
    local s = {}
    for _, p in ipairs(ps) do
        if not p.loc then s[#s + 1] = (p.ret and "→" or "") .. p.name .. ":" .. p.type end
    end
    return table.concat(s, ", ")
end

local function printValue(prefix, v)
    if type(v) == "userdata" and not valid(v) then
        local items = {}
        local okA = eachArr(v, function(i, e) items[#items + 1] = fnameOrStr(e) end)
        if okA and #items > 0 then out("%s = [%s]", prefix, table.concat(items, ", ")); return end
        local kv = {}
        pcall(function()
            v:ForEach(function(k, x)
                local kk, xx = k, x
                pcall(function() kk = k:get() end)
                pcall(function() xx = x:get() end)
                kv[#kv + 1] = fnameOrStr(kk) .. "=>" .. fnameOrStr(xx)
            end)
        end)
        if #kv > 0 then out("%s = {%s}", prefix, table.concat(kv, ", ")); return end
    end
    out("%s = %s", prefix, fnameOrStr(v))
end

local WEAPON_KW = { "Weapon", "Equip", "Armed", "Inventory", "Loadout", "Sheath" }
local function weaponWord(name)
    for _, k in ipairs(WEAPON_KW) do if name:find(k) then return true end end
    return false
end

-- 遍历对象类链上的属性和函数；filter=nil 表示全部
local function walkClass(obj, filter, maxProps, maxFns, label)
    local okC, c = pcall(function() return obj:GetClass() end)
    c = okC and c or nil
    local np, nf = 0, 0
    for _ = 1, 10 do
        if not valid(c) then break end
        local cname = shortName(full(c)) or "?"
        if cname == "Actor" or cname == "Object" or cname == "Pawn" then break end
        pcall(function()
            c:ForEachProperty(function(p)
                local n = "?"
                pcall(function() n = p:GetFName():ToString() end)
                if (not filter or filter(n)) and np < maxProps then
                    np = np + 1
                    local t = propType(p)
                    local base = t:match("^(%w+)")
                    local prefix = string.format("  %s 属性 %s.%s:%s", label, cname, n, t)
                    -- 只读确定安全的类型；Map/Set/委托/接口等只报类型
                    if ({ Int = 1, Int64 = 1, Float = 1, Double = 1, Bool = 1, Byte = 1, Enum = 1, Name = 1,
                          Str = 1, Object = 1, Class = 1, Array = 1 })[base] then
                        printValue(prefix, rawProp(obj, n))
                    elseif t == "Struct<GameplayTag>" then
                        -- GameplayTag 只有一个 TagName 字段，按简单结构体读（同 HasMatchingGameplayTag 的参数类型）
                        local v = rawProp(obj, n)
                        local okT, tn = pcall(function() return v.TagName:ToString() end)
                        out("%s = %s", prefix, okT and tostring(tn) or "?")
                    else
                        out("%s（不读值）", prefix)
                    end
                end
            end)
        end)
        pcall(function()
            c:ForEachFunction(function(f)
                local n = "?"
                pcall(function() n = f:GetFName():ToString() end)
                if (not filter or filter(n)) and nf < maxFns then
                    nf = nf + 1
                    local sig = signature(f)
                    out("  %s 函数 %s:%s(%s)", label, cname, n, sigStr(sig))
                    -- 只调用"参数表里只有一个 ReturnValue"的 Get/Is 函数（v0.6.4 实测这类调用安全）
                    if #sig == 1 and sig[1].ret and (n:sub(1, 3) == "Get" or n:sub(1, 2) == "Is") then
                        local ok, r = pcall(function() return obj[n](obj) end)
                        if ok then printValue("      调用结果", r) else out("      调用失败: %s", tostring(r)) end
                    end
                end
            end)
        end)
        local okS, sup = pcall(function() return c:GetSuperStruct() end)
        c = okS and sup or nil
    end
    out("  %s 共 %d 属性 / %d 函数", label, np, nf)
end

local function weaponProbe()
    out("========== 武器探针 ==========")
    local p1, pup = getP1(), puppet()
    for _, e in ipairs({ { "玩家1", p1 }, { "替身", pup } }) do
        local a = e[2]
        if valid(a) then
            out("[%s] CurrentWeaponID=%s CurrentWeapon=%s CurrentWeapon_ShaQi=%s HasUnsheathedWeapon=%s",
                e[1], fnameOrStr(rawProp(a, "CurrentWeaponID")), tostring(rawProp(a, "CurrentWeapon")),
                tostring(rawProp(a, "CurrentWeapon_ShaQi")), tostring(rawProp(a, "HasUnsheathedWeapon")))
            printValue(string.format("[%s] WeaponEquipInfos", e[1]), rawProp(a, "WeaponEquipInfos"))
            walkClass(a, weaponWord, 40, 60, "[" .. e[1] .. "]")
            local comp = rawProp(a, "Character Weapons Component")
            out("[%s] 武器组件 %s", e[1], full(comp))
            if valid(comp) then walkClass(comp, nil, 60, 80, "[" .. e[1] .. " 组件]") end
        end
    end
    out("========== 武器探针结束 ==========")
end

-- ============================================================ 锁定探针（F2，只读）
-- 用户反馈：锁定替身后镜头对着一片空地（像场地中央）。读出锁定系统记录的目标和坐标，与替身的实际位置对照
local LOCK_KW = { "Lock", "Target", "Focus", "Aim", "Soft", "Enemy" }

local function locOf(o)
    if not valid(o) then return nil end
    local ok, v = pcall(function() return o:K2_GetActorLocation() end)
    if not (ok and v) then ok, v = pcall(function() return o:K2_GetComponentLocation() end) end
    if ok and v and v.X then return v end
    return nil
end

local function vecStr(v) return v and string.format("(%.0f, %.0f, %.0f)", v.X, v.Y, v.Z) or "?" end

local function lockWalk(obj, label, refs)
    local okC, c = pcall(function() return obj:GetClass() end)
    c = okC and c or nil
    local np, nf = 0, 0
    for _ = 1, 10 do
        if not valid(c) then break end
        local cname = shortName(full(c)) or "?"
        if cname == "Actor" or cname == "Object" or cname == "Pawn" or cname == "ActorComponent" then break end
        pcall(function()
            c:ForEachProperty(function(p)
                local n = "?"
                pcall(function() n = p:GetFName():ToString() end)
                local hit = false
                for _, k in ipairs(LOCK_KW) do if n:find(k) then hit = true; break end end
                if not hit or np >= 60 then return end
                np = np + 1
                local t = propType(p)
                local base = t:match("^(%w+)")
                local s
                if t == "Struct<Vector>" then
                    local v = rawProp(obj, n)
                    local okV, sv = pcall(function() return vecStr(v) end)
                    s = okV and sv or "?"
                elseif base == "Object" then
                    local v = rawProp(obj, n)
                    s = valid(v) and (short(pathOf(v)) .. " @ " .. vecStr(locOf(v))) or "（空）"
                    if valid(v) then refs[#refs + 1] = { label .. "." .. n, v } end
                elseif ({ Int = 1, Float = 1, Double = 1, Bool = 1, Byte = 1, Enum = 1, Name = 1 })[base] then
                    s = fnameOrStr(rawProp(obj, n))
                else
                    s = "（不读值）"
                end
                out("  [%s] %s.%s:%s = %s", label, cname, n, t, s)
            end)
        end)
        pcall(function()
            c:ForEachFunction(function(f)
                local n = "?"
                pcall(function() n = f:GetFName():ToString() end)
                local hit = false
                for _, k in ipairs(LOCK_KW) do if n:find(k) then hit = true; break end end
                if not hit or nf >= 40 then return end
                nf = nf + 1
                local sig = signature(f)
                local line = string.format("  [%s] %s:%s(%s)", label, cname, n, sigStr(sig))
                if #sig == 1 and sig[1].ret and (n:sub(1, 3) == "Get" or n:sub(1, 2) == "Is") then
                    local ok, r = pcall(function() return obj[n](obj) end)
                    if ok then
                        if type(r) == "userdata" and valid(r) then
                            line = line .. " → " .. short(pathOf(r)) .. " @ " .. vecStr(locOf(r))
                            refs[#refs + 1] = { label .. ":" .. n .. "()", r }
                        else
                            local okV, sv = pcall(function() return vecStr(r) end)
                            line = line .. " → " .. ((okV and r and r.X) and sv or fnameOrStr(r))
                        end
                    end
                end
                out("%s", line)
            end)
        end)
        local okS, sup = pcall(function() return c:GetSuperStruct() end)
        c = okS and sup or nil
    end
    out("  [%s] 锁定相关：属性 %d / 函数 %d", label, np, nf)
end

local function lockProbe()
    out("========== 锁定探针 ==========")
    local p1, pc, pup = getP1(), getP1PC(), puppet()
    out("玩家1 @ %s   替身 @ %s   替身控制器 @ %s", vecStr(locOf(p1)), vecStr(locOf(pup)), vecStr(locOf(ST.secondPC)))
    local starts = FindAllOf("PlayerStart")
    if starts then
        for _, s in pairs(starts) do if valid(s) then out("  出生点 %s @ %s", short(pathOf(s)), vecStr(locOf(s))) end end
    end
    local refs = {}
    local cam = rawProp(p1, "NBCamera")
    local pcm = rawProp(pc, "PlayerCameraManager")
    for _, e in ipairs({ { "玩家1", p1 }, { "玩家1控制器", pc }, { "镜头组件", cam }, { "镜头管理器", pcm } }) do
        if valid(e[2]) then out("-- %s %s", e[1], short(pathOf(e[2]))); lockWalk(e[2], e[1], refs) end
    end
    -- 锁定系统指向的对象，逐个和替身 / 替身控制器 / 出生点比对
    out("-- 引用对照（离替身多远）")
    local pl = locOf(pup)
    for _, r in ipairs(refs) do
        local l = locOf(r[2])
        local d = (l and pl) and math.sqrt((l.X - pl.X) ^ 2 + (l.Y - pl.Y) ^ 2) or -1
        out("  %s → %s  是替身=%s 是替身控制器=%s 离替身 %.0f", r[1], short(pathOf(r[2])),
            tostring(sameObj(r[2], pup)), tostring(sameObj(r[2], ST.secondPC)), d)
    end
    out("========== 锁定探针结束 ==========")
end

-- ============================================================ 处决探针 + 禁止处决标签实验（F2）
-- v0.9.12 实测：暗杀动作开始后再中断太晚 —— 用户反馈仍会瞬移过去、替身掉武器、有暗杀音效。
-- 资产数据：GA_Hun_SEx_M_02（父类 PBZ_StealthExecutionAbilityBase）激活即做 LGAAction_ExecutionWarping + InstantWarp（瞬移）、
-- 播 SFX_Combat_Special_Execute_Dagger（音效）；GA_Hun_SEd_M_02 里有 GAA_DropWeapon_C（掉武器）。
-- 要在"能否暗杀"的判定上让替身不合格。判定走 Execution Component；两边技能都检查 CharacterState.Forbid.Ability.Focusing.Execution
local EXEC_KW = { "Sneak", "Stealth", "Aware", "Alert", "Assassin", "Execut", "Perception", "Detect", "Notice" }

local function execComponentOf(actor)
    local c = rawProp(actor, "Execution Component")
    if valid(c) then return c, "属性 Execution Component" end
    local ok, r = pcall(function() return actor:GetExecutionComponent() end)
    if ok and valid(r) then return r, "GetExecutionComponent()" end
    return nil, "没找到"
end



-- 注销替身作为"被执行目标"注册的动作。返回成功调用的次数
local function unregisterPuppetExecAnims(pup, why)
    local comp = valid(pup) and execComponentOf(pup) or nil
    if not valid(comp) then out("!! 替身没有处决组件（%s）", why); return 0 end
    local keys = {}
    local function addKey(label, o) if valid(o) then keys[#keys + 1] = { label, o } end end
    addKey("组件.ActorConfig", rawProp(comp, "ActorConfig"))
    local okA, ac = pcall(function() return pup:GetExecutionActorConfig() end)
    if okA then addKey("GetExecutionActorConfig()", ac) end
    addKey("替身自身", pup)
    addKey("替身 ASC", ascOf(pup))
    addKey("替身武器组件", rawProp(pup, "Character Weapons Component"))
    local n = 0
    for _, k in ipairs(keys) do
        local ok, err = pcall(function() comp:UnregisterExecutionAnims(k[2]) end)
        if ok then n = n + 1 end
        out("  替身 UnregisterExecutionAnims(%s = %s)：%s", k[1], short(pathOf(k[2])), ok and "调用成功" or ("失败 " .. tostring(err)))
    end
    out("替身注销可被执行动作（%s）：%d/%d 次调用成功", why, n, #keys)
    return n
end

local function execProbe()
    out("========== 处决探针 ==========")
    local p1, pup = getP1(), puppet()
    -- 组件探针 v0.9.13 已经拿到完整数据（见 HANDOVER §19.20），每次游戏只跑一次，之后按 F2 只切换标签
    for _, e in ipairs({}) do   -- 处决组件探针 v0.9.13 已拿到完整数据（HANDOVER §19.20），不再重复
        if valid(e[2]) then
            local comp, how = execComponentOf(e[2])
            out("[%s] 处决组件：%s（%s）", e[1], comp and short(pathOf(comp)) or "<无>", how)
            if comp then walkClass(comp, nil, 60, 60, e[1] .. " 处决组件") end
            walkClass(e[2], function(n)
                for _, k in ipairs(EXEC_KW) do if n:find(k) then return true end end
                return false
            end, 40, 40, e[1])
        end
    end
    ST.execProbed = true
    -- 标签路线放弃：v0.9.13 Lua 拼容器崩（crash_21_24_21）；v0.9.14 用 MakeGameplayTagContainerFromTag 生成，
    -- 但 UE4SS 把返回的结构体转成了 Lua table（日志 "table: 00000003D2FACE80"），传回去同样崩（crash_21_27_39）。
    -- 改为：在替身自己的处决组件上 UnregisterExecutionAnims(SourceKey) —— 注销它作为目标注册的"可被执行动作"（含被暗杀 SEd），
    -- 执行方就挑不出能对它用的处决。参数只有一个对象。SourceKey 不确定，几个候选都试，没注册过的 key 应该无效果
    -- v0.9.15 实测：UnregisterExecutionAnims 5 个候选都调用成功，但暗杀照样触发 —— 可被暗杀的资格不由这些注册决定。
    -- 资产数据：暗杀 = Execution.Type.Stealth（ActorConfig_Hun）；条件在全局配置 PDA_GlobalConfig_Combined 的
    -- "Execution Conditions Map"，配置里还有 "Combat State Tag" / GetCharacterCombatStateTag / "Sneaking Tag"。
    -- 推测：目标没进战斗状态才能被暗杀；替身没有 AI，永远不进战斗。读全局配置和双方的角色状态组件（只读）
    local wc = rawProp(p1, "Character Weapons Component")
    local gc = valid(wc) and rawProp(wc, "GlobalConfig") or nil
    out("-- 全局配置 %s", gc and short(pathOf(gc)) or "<没拿到>")
    if valid(gc) then
        walkClass(gc, function(n)
            for _, k in ipairs({ "Combat", "Execut", "Sneak", "Stealth", "Condition", "State", "Aware" }) do
                if n:find(k) then return true end
            end
            return false
        end, 60, 60, "全局配置")
    end
    for _, e in ipairs({ { "玩家1", p1 }, { "替身", pup } }) do
        local sc = valid(e[2]) and rawProp(e[2], "Actor State Component") or nil
        out("-- %s 角色状态组件 %s", e[1], valid(sc) and short(pathOf(sc)) or "<没拿到>")
        if valid(sc) then walkClass(sc, nil, 60, 60, e[1] .. " 状态组件") end
    end
    out("========== 处决探针结束 ==========")
end

-- F2（v0.9.18）：读处决条件表，找暗杀（Execution.Type.Stealth）的真实条件。
-- 带"输出参数"的函数：传一个空 table 让 UE4SS 填回来；返回 Map/Array 的读取有崩溃风险，所以每步之前先写日志
-- v0.9.18 实测：Map / Array 的元素是 UE4SS 的 RemoteUnrealParam / LocalUnrealParam 包装，要 :get() 才拿到值
local function unwrap(x)
    if type(x) == "userdata" then
        local ok, v = pcall(function() return x:get() end)
        if ok and v ~= nil then return v end
    end
    return x
end

-- 把一个值描述成字符串：对象给路径，GameplayTag 给名字，FName 给字符串；结构体试几个常见字段

-- v0.9.19 实测：结构体值（ExecutionConditions、GameplayTag）的 GetFullName 返回的是"ScriptStruct /Script/…"类型名，
-- 不是值。先读 TagName；结构体则用 StaticFindObject 拿到结构体定义，逐个字段读值
local function structFields(v)
    local f = full(v)
    local path = f:match("^ScriptStruct (.+)$")
    if not path then return nil end
    local st = StaticFindObject(path)
    if not valid(st) then return nil end
    local fields = {}
    pcall(function()
        st:ForEachProperty(function(p)
            local n = "?"
            pcall(function() n = p:GetFName():ToString() end)
            fields[#fields + 1] = { name = n, type = propType(p) }
        end)
    end)
    return fields, path
end

local function describe(v, depth)
    depth = depth or 0
    v = unwrap(v)
    if type(v) ~= "userdata" then return fnameOrStr(v) end
    local tn = rawProp(v, "TagName")
    if tn ~= nil then
        local okT, s = pcall(function() return tn:ToString() end)
        if okT and s then return tostring(s) end
    end
    local fields, spath = structFields(v)
    if fields then
        if depth >= 3 then return "<" .. (shortName(spath) or spath) .. ">" end
        local parts = {}
        for _, fd in ipairs(fields) do
            local base = fd.type:match("^(%w+)")
            local fv = rawProp(v, fd.name)
            local s
            if base == "Map" or base == "Set" or base:find("Delegate") or base == "Interface"
                or base == "WeakObject" or base == "SoftObject" or base == "SoftClass" or base == "LazyObject" then
                s = "（" .. fd.type .. "，不读值）"
            elseif base == "Array" then
                local items = {}
                eachArr(fv, function(_, e) if #items < 12 then items[#items + 1] = describe(e, depth + 1) end end)
                s = "[" .. table.concat(items, ", ") .. "]"
            else
                s = describe(fv, depth + 1)
            end
            parts[#parts + 1] = fd.name .. "=" .. s
        end
        return "<" .. (shortName(spath) or spath) .. "> {" .. table.concat(parts, "; ") .. "}"
    end
    if valid(v) then return short(pathOf(v)) end
    local okS, s = pcall(function() return v:ToString() end)
    if okS and s then return tostring(s) end
    return tostring(v)
end

local function dumpAny(prefix, v, depth)
    depth = depth or 0
    if depth > 3 then out("%s …", prefix); return end
    if type(v) == "table" then
        local n = 0
        for k, x in pairs(v) do
            n = n + 1
            if n > 40 then out("%s …（更多省略）", prefix); break end
            if type(x) == "table" then dumpAny(prefix .. "." .. describe(k), x, depth + 1)
            else out("%s[%s] = %s", prefix, describe(k), describe(x)) end
        end
        if n == 0 then out("%s = {}", prefix) end
    else
        out("%s = %s", prefix, describe(v))
    end
end

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
local CD_SEC, REND_SEC, END_SEC, FIGHT_SHOW = 3.0, 3.0, 6.0, 1.0
local SPAWN_D, DEAD_HP, TEXT_Z, LOST_SEC = 500.0, 1.0, 230.0, 5.0
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
    if ST.spec and ST.spec.on then SAFE.guard = nil; return end      -- §141 观战时角色藏着、冻着，不挪它
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
    local c, r = MATCH.center, math.rad(MATCH.arena.yaw)
    local s = MATCH.role == "host" and -1 or 1
    local yaw = MATCH.role == "host" and MATCH.arena.yaw or MATCH.arena.yaw + 180.0
    return { X = c.X + math.cos(r) * SPAWN_D * s, Y = c.Y + math.sin(r) * SPAWN_D * s, Z = c.Z + 20.0 }, yaw
end

-- ---- v0.15.0 中英文切换（用户 2026-11-04："exe 加中英文切换，游戏里新增的文字也一起切"）。
-- 联机窗口右上角选语言 → 写 net/lang.txt（lang=zh|en），这里每秒读一次。
-- 引擎默认字体没有中文字形；游戏自带的 ChineseBlackFont 是离线字体（PF_G8 + 78 页字形贴图，和引擎的
-- RobotoDistanceField 同类），TextRender 能用。加载不到就保持英文
local LANG = { zh = false, checkAt = 0.0, font = nil, fontTried = false }
local LANG_FILE = NET_DIR .. "/lang.txt"
local ZH_FONT = "/Game/PBZContent/UI/Fonts/ChineseBlackFont.ChineseBlackFont"

local function zhFont()
    if LANG.fontTried then return LANG.font end
    LANG.fontTried = true
    local f = StaticFindObject(ZH_FONT)
    if not valid(f) and type(LoadAsset) == "function" then
        out("  [步骤] LoadAsset(%s)", ZH_FONT)
        local ok, r = pcall(function() return LoadAsset(ZH_FONT) end)
        out("  LoadAsset -> %s %s", ok and "成功" or "失败", tostring(r))
        f = StaticFindObject(ZH_FONT)
        if not valid(f) and ok and valid(r) then f = r end
    end
    LANG.font = valid(f) and f or nil
    out("中文字体：%s", LANG.font and short(pathOf(LANG.font)) or "加载不到，游戏内提示保持英文")
    return LANG.font
end

local function langPoll(tn)
    if tn < LANG.checkAt then return end
    LANG.checkAt = tn + 1.0
    local kv = fileReadKV(LANG_FILE)
    local zh = kv ~= nil and kv.lang == "zh"
    if zh ~= LANG.zh then
        LANG.zh = zh
        if zh then zhFont() end
        out("游戏内提示语言 -> %s", (zh and LANG.font) and "中文" or (zh and "中文（字体加载不到，仍显示英文）" or "英文"))
    end
end

-- 只有字体可用时才真的出中文（3D 文字要 ChineseBlackFont；UMG 不用）
local function T(zh, en)
    return (LANG.zh and (LANG.font or LANG.umg)) and zh or en     -- v0.18.6：UMG 显示中文不靠 LANG.font
end

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
-- 一个 TextRender 只能有一种颜色和字号，所以每行准备三个文字物体：标签（右对齐）、值（左对齐）、居中整句。
-- 都挂在主文字物体上（SnapToTarget，跟着它一起贴在镜头前），主文字本身留空串当锚点。
-- 行的写法：{ c = 整句, col = 颜色, size = 字号倍数 } 或 { l = 标签, v = 值, col = 值的颜色 }；最多 HUD_ROWS 行
local COL_LABEL = { R = 255, G = 215, B = 90, A = 255 }    -- 金黄：普通说明
local COL_WHITE = { R = 240, G = 240, B = 240, A = 255 }
local COL_GRAY = { R = 170, G = 170, B = 170, A = 255 }
local COL_GREEN = { R = 90, G = 230, B = 110, A = 255 }
local COL_RED = { R = 255, G = 70, B = 70, A = 255 }
local COL_ORANGE = { R = 255, G = 140, B = 40, A = 255 }

local function hudPiece(align)
    local parent = MATCH.text
    local cls = StaticFindObject("/Script/Engine.TextRenderActor")
    local world = valid(parent) and try("hud world", function() return parent:GetWorld() end)
    local a = (valid(cls) and valid(world)) and try("spawn hud text", function()
        return world:SpawnActor(cls, { X = 0.0, Y = 0.0, Z = 0.0 }, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 })
    end) or nil
    local comp = valid(a) and rawProp(a, "TextRender") or nil
    if not valid(comp) then return nil end
    pcall(function() comp:SetHorizontalAlignment(align) end)   -- 0=左 1=中 2=右
    pcall(function() comp:SetVerticalAlignment(1) end)
    pcall(function() a:K2_AttachToActor(parent, FName("None"), 2, 2, 2, false) end)
    pcall(function() a:SetActorHiddenInGame(true) end)
    return { a = a, c = comp, orig = rawProp(comp, "Font") }
end

local function pieceSet(p, s, col, size, dz)
    if not p or not valid(p.c) then return end
    if s == nil then
        if p.key ~= nil then p.key = nil; pcall(function() p.a:SetActorHiddenInGame(true) end) end
        return
    end
    -- 字体跟着语言：中文用 ChineseBlackFont，英文换回原来的默认字体
    local font = (LANG.zh and LANG.font) or p.orig
    local key = string.format("%s|%d,%d,%d|%.1f|%.1f|%s", s, col.R, col.G, col.B, size, dz, tostring(font == LANG.font))
    if p.key == key then return end
    p.key = key
    if font and p.font ~= font then
        local okS, errS = pcall(function() p.c:SetFont(font) end)
        if okS then p.font = font
        elseif not LANG.fontErr then LANG.fontErr = true; out("!! 文字 SetFont 失败：%s", tostring(errS)) end
    end
    local okF, ft = pcall(function() return FText(s) end)
    if not okF then return end
    pcall(function() p.c:SetWorldSize(HUD_SIZE * size) end)
    pcall(function() p.c:SetTextRenderColor(col) end)
    pcall(function() p.c:K2_SetText(ft) end)
    pcall(function() p.a:K2_SetActorRelativeLocation({ X = 0.0, Y = 0.0, Z = dz }, false, {}, true) end)
    pcall(function() p.a:SetActorHiddenInGame(false) end)
end

-- net-ui：联机面板最多 9 行，所以 3 → 9；文字物体按需要的行数逐步生成（平时还是只有 3 行 × 3 个）
local HUD_ROWS = 17         -- 房间设置拆成单独一页后设置页 11 项、房间设置页 7 项，回到 17；§105.3 / §106.5 曾是 16 项 / 19；v0.18.6：面板加了"输入地址 / 复制地址 / 设置"三行，9 → 12；v0.27.6 设置页 12 项（伤害倍率、全部可格挡），12 → 15；v0.27.21 设置页加感谢名单（13 项），15 → 16；§102 加"直连不通时用服务器中转"（14 项），16 → 17

local function setHud(rows)
    if rows and valid(MATCH.text) and #(MATCH.hud or {}) < math.min(#rows, HUD_ROWS) then
        MATCH.hud = MATCH.hud or {}
        local from = #MATCH.hud + 1
        for i = from, math.min(#rows, HUD_ROWS) do MATCH.hud[i] = { lab = hudPiece(2), val = hudPiece(0), mid = hudPiece(1) } end
        out("  HUD：生成第 %d–%d 行文字物体（每行 3 个）", from, #MATCH.hud)
    end
    -- 行高按字号算；从上往下排，整体居中在锚点
    local n, total, gap = 0, 0.0, HUD_SIZE * 0.25
    local h = {}
    for i = 1, HUD_ROWS do
        h[i] = (rows and rows[i]) and HUD_SIZE * (rows[i].size or 1.0) or 0
        if h[i] > 0 then n = n + 1; total = total + h[i] end
    end
    total = total + gap * math.max(0, n - 1)
    local dz, top = {}, total / 2
    for i = 1, HUD_ROWS do
        dz[i] = 0.0
        if h[i] > 0 then dz[i] = top - h[i] / 2; top = top - h[i] - gap end
    end
    for i, pr in ipairs(MATCH.hud or {}) do
        local r = rows and rows[i]
        local size, col = r and (r.size or 1.0) or 1.0, r and (r.col or COL_WHITE) or COL_WHITE
        pieceSet(pr.mid, r and r.c, col, size, dz[i])
        pieceSet(pr.lab, r and r.l, COL_LABEL, size, dz[i])
        pieceSet(pr.val, r and r.v and (" " .. r.v), col, size, dz[i])
    end
end

-- v0.18.5 屏幕文字改用 UMG（用户 2026-11-04："文字渲染不应该虚化"）：TextRender 是摆在镜头前 2 米的 3D 物体，
-- 会吃景深 / 动态模糊 / TAA，还会被镜头前的草挡住。UMG 是贴在屏幕上的 2D 界面，画在后处理之后，和游戏自己的 UI 一样清楚。
-- 做法（18:15 实机原型验证）：用引擎的空 UserWidget 类 Create，它的 WidgetTree 里放一个 CanvasPanel 当根，
-- 每行按需加 TextBlock（标签 / 值 / 居中整句三个），AddToViewport。默认字体 Roboto 缺的中文字形 Slate 会自动回退，中文能显示。
-- 任何一步失败就退回旧的 TextRender（HUD.failed），不影响对局
local HUD = { w = nil, cv = nil, rows = {}, failed = false }
local HUD_PX = 34          -- 字号倍数 1.0 对应的像素
local HUD_Y = 0.30         -- 整块文字的中心在屏幕高度的这个比例处
local HUD_Z = 450          -- 视口层级（游戏自己的 HUD 在下面）

local function umgColor(c)
    return { SpecifiedColor = { R = c.R / 255, G = c.G / 255, B = c.B / 255, A = (c.A or 255) / 255 }, ColorUseRule = 0 }
end

local function umgRoot()
    -- v0.27.12 换过地图（HUD.gen 对不上）就不碰旧控件，连 IsInViewport 也不调（§93）
    if HUD.gen == ST.mapLoads and valid(HUD.w) and valid(HUD.cv) then
        local okV, inVp = pcall(function() return HUD.w:IsInViewport() end)
        if okV and inVp then return HUD.cv end
    end
    -- 换地图后旧的界面会被引擎回收：重建
    HUD.w, HUD.cv, HUD.rows = nil, nil, {}
    local okP, pc = pcall(getP1PC)
    if not (okP and valid(pc)) then return nil end
    local ok, err = pcall(function()
        local w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, StaticFindObject("/Script/UMG.UserWidget"), pc)
        local wt = w.WidgetTree
        local cv = StaticConstructObject(StaticFindObject("/Script/UMG.CanvasPanel"), wt)
        wt.RootWidget = cv
        w:AddToViewport(HUD_Z)
        w:SetVisibility(3)         -- HitTestInvisible：只显示，不挡鼠标
        HUD.w, HUD.cv, HUD.gen = w, cv, ST.mapLoads
    end)
    if not ok or not valid(HUD.cv) then
        HUD.failed = true
        out("!! 屏幕文字（UMG）建不起来：%s，改用旧的 3D 文字", tostring(err))
        return nil
    end
    out("屏幕文字（UMG）已建好")
    LANG.umg = true            -- UMG 显示中文不用 ChineseBlackFont（Slate 自动回退字体）
    return HUD.cv
end

-- 一个 TextBlock；ax = 水平对齐点（0 左端 / 0.5 中间 / 1 右端 落在屏幕中线上）
local function umgPiece(cv, ax)
    local tb = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), HUD.w.WidgetTree)
    local sl = cv:AddChildToCanvas(tb)
    sl:SetAnchors({ Minimum = { X = 0.5, Y = HUD_Y }, Maximum = { X = 0.5, Y = HUD_Y } })
    sl:SetAlignment({ X = ax, Y = 0.5 })
    sl:SetAutoSize(true)
    tb:SetVisibility(1)
    return { tb = tb, sl = sl }
end

local function umgSet(p, s, col, size, y)
    if s == nil then
        if p.key ~= nil then p.key = nil; p.tb:SetVisibility(1) end      -- Collapsed
        return
    end
    local key = string.format("%s|%d,%d,%d|%.2f|%.1f", s, col.R, col.G, col.B, size, y)
    if p.key == key then return end
    p.key = key
    p.tb:SetText(FText(s))
    p.tb:SetColorAndOpacity(umgColor(col))
    local f = p.tb.Font
    f.Size = math.floor(HUD_PX * size + 0.5)
    f.OutlineSettings.OutlineSize = 2
    f.OutlineSettings.OutlineColor = { R = 0, G = 0, B = 0, A = 0.85 }
    p.tb:SetFont(f)
    p.sl:SetPosition({ X = 0.0, Y = y })
    p.tb:SetVisibility(3)
end

-- 成功返回 true；失败（或已判定 UMG 不可用）返回 false，由调用方走旧的 TextRender
local function umgHud(rows)
    if HUD.failed then return false end
    if rows == nil and not valid(HUD.w) then return true end
    local cv = umgRoot()
    if not cv then return false end
    -- v0.18.6：游戏暂停（Esc / 角色菜单打开）时整层藏起来。18:27 实测：这层字会盖在游戏菜单上面，把层级降到 -100 也一样
    -- （游戏菜单在自己的层上），所以只能藏
    local okP, paused = pcall(function() return gstat():IsGamePaused(getP1PC()) end)
    local hide = okP and paused == true
    if hide ~= HUD.hidden then
        HUD.hidden = hide
        pcall(function() HUD.w:SetVisibility(hide and 1 or 3) end)
    end
    local ok, err = pcall(function()
        local n = rows and math.min(#rows, HUD_ROWS) or 0
        HUD.rowY = {}
        for i = #HUD.rows + 1, n do
            HUD.rows[i] = { lab = umgPiece(cv, 1.0), val = umgPiece(cv, 0.0), mid = umgPiece(cv, 0.5) }
        end
        -- 行高按字号算；从上往下排，整体以 HUD_Y 为中心
        local h, total, gap = {}, 0.0, HUD_PX * 0.25
        for i = 1, n do h[i] = HUD_PX * (rows[i].size or 1.0) * 1.3; total = total + h[i] end
        total = total + gap * math.max(0, n - 1)
        local top = -total / 2
        for i, pr in ipairs(HUD.rows) do
            local r = i <= n and rows[i] or nil
            local y, size, col = 0.0, r and (r.size or 1.0) or 1.0, r and (r.col or COL_WHITE) or COL_WHITE
            if r then y = top + h[i] / 2; top = top + h[i] + gap; HUD.rowY[i] = y end
            umgSet(pr.mid, r and r.c, col, size, y)
            umgSet(pr.lab, r and r.l, COL_LABEL, size, y)
            umgSet(pr.val, r and r.v and (" " .. r.v), col, size, y)
        end
    end)
    if not ok then
        HUD.failed = true
        out("!! 屏幕文字（UMG）出错：%s，改用旧的 3D 文字", tostring(err))
        pcall(function() HUD.w:RemoveFromParent() end)
        return false
    end
    return true
end

-- 统一入口：rows=nil 时隐藏全部；有 rows 时主文字留空串当锚点（不是 nil：placeText 要它"显示中"才会摆位）
local function showHud(rows)
    if umgHud(rows) then
        if MATCH.shown ~= nil then setText(nil); setHud(nil) end     -- 旧的 3D 文字收起来
        return
    end
    setText(rows and "" or nil)
    setHud(rows)
end

local function hudLog(rows)
    if not rows then return nil end
    local parts = {}
    for _, r in ipairs(rows) do
        if not r.nolog then parts[#parts + 1] = r.c or ((r.l or "") .. " " .. (r.v or "")) end     -- §173 倒计时钟每秒变，不进日志
    end
    if #parts == 0 then return nil end
    return table.concat(parts, " / ")
end

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
SUMMON = { WINDOW = 5.0, EVERY = 6, BG_EVERY = 150, LOG_MAX = 8, kind = {}, nKind = 0, mine = {}, fc = {}, fail = {}, GIVE_UP = 3,
           st = {}, REVERT_MAX = 4 }

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
        if s.logged ~= want then        -- 每个召唤物每种阵营只记一次成功（对局开始 / 结束翻转时各记一次）
            s.logged = want
            if want == FOE then setLockTarget(a, getP1()) end
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
-- 日志 8 次"主人不是替身，不改"），按主人认不出。替身刚放召唤后新出现的 BP_Monster_Hun_Summon_* 算替身的；
-- 我自己这几秒也放过召唤 → 离替身比离我近才算
function SUMMON.byClass(e, pup, p1, tn)
    if not e.cls:find("^BP_Monster_Hun_Summon_") then return nil end
    if not (ST.p1SummonAt and tn - ST.p1SummonAt < SUMMON.WINDOW) then return "类名，替身刚放召唤" end
    local a = try("summon loc", function() return e.actor:K2_GetActorLocation() end)
    local b = try("pup loc", function() return pup:K2_GetActorLocation() end)
    local c = try("p1 loc", function() return p1:K2_GetActorLocation() end)
    if not (a and b and c) then return nil end
    local function d2(u, v) return (u.X - v.X) ^ 2 + (u.Y - v.Y) ^ 2 end
    if d2(a, b) < d2(a, c) then return "类名，两边都放了召唤、离替身更近" end
    return nil
end

function SUMMON.step(p1, pup, tn)
    if not valid(pup) then return end
    local want
    for p, a in pairs(SUMMON.mine) do         -- 已认出的：对局开始 / 结束时替身阵营会变，跟着改
        if not valid(a) then SUMMON.mine[p], SUMMON.fc[p], SUMMON.fail[p], SUMMON.st[p] = nil, nil, nil, nil
        elseif ST.ticks % SUMMON.EVERY == 0 and not (SUMMON.fail[p] and SUMMON.fail[p].n >= SUMMON.GIVE_UP) then
            local s = SUMMON.st[p]
            want = want or factionName(pup, PUPFC.of(pup))
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
    local armed = ST.summonArmAt ~= nil and tn - ST.summonArmAt < SUMMON.WINDOW
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
            SUMMON.kind[e.path], SUMMON.nKind = link and "pup" or "other", SUMMON.nKind + 1
            if link then
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
    return T("Phantom Pact 合作联机中，请先在 F5 面板里离开", "PHANTOM PACT CO-OP IS ON - LEAVE IT IN ITS F5 PANEL FIRST")
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
        -- §86 第二行：不是默认值的规则（免得双方不知道）
        local rules = {}
        local dm = MATCH.dmPct or 100
        if dm ~= 100 then rules[#rules + 1] = string.format(T("伤害 %d%%", "DAMAGE %d%%"), dm) end
        if MATCH.ab then rules[#rules + 1] = T("全部可格挡", "ALL MOVES BLOCKABLE") end
        if (MATCH.tl or 0) ~= NET.RES_DEF.tl then       -- §173 回合时限不是默认 180 秒时写出来
            local tx = NET.resText("tl", MATCH.tl or 0)
            rules[#rules + 1] = (MATCH.tl or 0) > 0 and string.format(T("限时 %s", "TIME LIMIT %s"), T(tx[1], tx[2])) or T("不限时", "NO TIME LIMIT")
        end
        if MATCH.flags and MATCH.flags.ctr == false then rules[#rules + 1] = T("无红蓝光反击", "NO RED/BLUE COUNTERS") end   -- §105.3
        if MATCH.flags and MATCH.flags.bal then rules[#rules + 1] = T("武器平衡", "WEAPON BALANCE") end                     -- §106.5
        if MATCH.flags and MATCH.flags.med == false then rules[#rules + 1] = T("禁用血瓶", "NO POTIONS") end                -- §108
        if STD.active() then rules[#rules + 1] = T("标准数值", "STANDARD STATS") end
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
        -- §173.9 规则多了一行放不下（11-09 实测窗口化约 968 像素宽，"限时 60 秒"两头被截）：按显示宽度折成几行，一条规则不拆开
        for _, ln in ipairs(RT.wrapRules(rules, RT.RULE_W)) do rows[#rows + 1] = { c = ln, col = COL_ORANGE } end
        for _, r in ipairs(RFP.rows() or {}) do rows[#rows + 1] = r end     -- §210 双方规则不一致
        if CFG.srvNewer then         -- §210 大厅服务器的数值表比我的模组新、没用上（规则指纹也会和新版本对不上）
            rows[#rows + 1] = { c = T("大厅服务器的数值表比你的模组新，这一场用的是模组自带的，请更新模组", "SERVER BALANCE TABLE IS NEWER THAN YOUR MOD: UPDATE"),
                                col = COL_RED, size = 0.8, nolog = true }
        end
        local rkRow = NET.rkScoreRow()     -- §110 武林盟主：我的积分 / 名次
        if rkRow then rows[#rows + 1] = rkRow end
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

-- §110 用户 2026-11-06"对局的过程看不到我的积分变化么"：倒计时里显示我的积分；打完联机程序收到服务器的结算（rkres=）后
-- 屏幕上提示一次。rkme=<分数>|<名次>|<胜>|<负>|<称号>|<赛季>；rkres=<序号>|<胜 1 / 负 0 / 作废 ->|<变化>|<分数>|<名次>|<ok / cap / void>
function NET.rkScoreRow()
    local lb = NET.rkLobby()
    if not (lb and lb.rk == "1") then return nil end
    local sc, rank, _, _, title = (lb.rkme or ""):match("^(%-?%d+)|(%d*)|(%d*)|(%d*)|([^|]*)")
    if not sc then return nil end
    local s = string.format(T("武林盟主 · 我的积分 %s", "RANKED · RATING %s"), sc)
    if (tonumber(rank) or 0) > 0 then s = s .. string.format(T("（第 %s 名）", " (#%s)"), rank) end
    if title and title ~= "" then s = "【" .. title .. "】" .. s end
    return { c = s, col = COL_LABEL, size = 0.75 }
end
NET.rkResSeen = nil       -- 上次看到的 rkres=（第一次读到的只记下、不提示：那是之前打的）
function NET.rkResultRows()
    local lb = NET.rkLobby()
    local r = lb and lb.rkres or ""
    if NET.rkResSeen == nil then NET.rkResSeen = r; return nil end
    if r == NET.rkResSeen or r == "" then return nil end
    NET.rkResSeen = r
    local _, win, d, sc, rank, code = r:match("^(%d+)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)")
    if not code then return nil end
    out("武林盟主结算：%s %s，现在 %s（第 %s 名）", code, d, sc, rank)
    local tail = (tonumber(rank) or 0) > 0 and string.format(T("现在 %s · 第 %s 名", "NOW %s · #%s"), sc, rank)
                 or string.format(T("现在 %s", "NOW %s"), sc)
    if code == "void" then
        return { { c = T("本局作废", "MATCH VOID"), col = COL_ORANGE, size = 1.6 },
                 { c = T("两边报的结果对不上，不计分", "THE REPORTS DISAGREED - NOT RATED"), col = COL_LABEL } }
    elseif code == "rules" or code == "oldmod" then     -- §210 规则指纹：不计分，写清楚不是封号
        return { { c = T("本局不计分", "NOT RATED"), col = COL_GRAY, size = 1.6 },
                 { c = code == "rules" and T("双方这一场实际用的规则不一致（不是封号）", "THE TWO PLAYERS RAN DIFFERENT RULES (NOT A BAN)")
                       or T("有一方模组版本太旧、没报规则（不是封号），请双方更新到最新版", "ONE PLAYER'S MOD IS OUTDATED (NOT A BAN) - BOTH PLEASE UPDATE"), col = COL_LABEL },
                 { c = tail, col = COL_LABEL, size = 0.75 } }
    elseif code == "cap" then
        return { { c = T("本局不计分", "NOT RATED"), col = COL_GRAY, size = 1.6 },
                 { c = T("今天和这位对手已经记了 3 场", "ALREADY 3 RATED MATCHES WITH THIS OPPONENT TODAY"), col = COL_LABEL },
                 { c = tail, col = COL_LABEL, size = 0.75 } }
    end
    -- §179 不认识的 code（以后服务端加的）：分数没变 = 当不计分显示、带上 code；分数变了照常显示变化（原因行换成 code，不再按 ±16 猜）
    local known = code == "" or code == "ok"      -- 空 = 旧格式没有 code 段，当计分
    local delta = tonumber((tostring(d):gsub("^%+", "")))
    if not known and (delta or 0) == 0 then
        return { { c = T("本局不计分", "NOT RATED"), col = COL_GRAY, size = 1.6 },
                 { c = string.format(T("服务器说明：%s", "SERVER NOTE: %s"), code), col = COL_LABEL },
                 { c = tail, col = COL_LABEL, size = 0.75 } }
    end
    local rows = { { c = string.format(T("武林盟主积分 %s", "RATING %s"), d), col = win == "1" and COL_GREEN or COL_RED, size = 1.8 } }
    local why = known and NET.rkWhy(win, d)
             or code == "dispute" and T("有一方对这局判定有异议，已记录（积分照常）", "A RESULT DISPUTE WAS LOGGED (RATING UNAFFECTED)")     -- §179.3
             or string.format(T("服务器说明：%s", "SERVER NOTE: %s"), code)
    if why then rows[#rows + 1] = { c = why, col = COL_LABEL, size = 0.75 } end
    rows[#rows + 1] = { c = tail, col = COL_LABEL }
    return rows
end
-- §175 结算提示里"为什么是这个数"（内测反馈"加分减分机制不明确"）。服务器（pbz-ranked.mjs）用 Elo、K = 32：
-- 变化 = round(32 ×（1 − 赢家的期望胜率）)，同分是 16，所以光看变化比 16 大还是小就知道赛前谁分高，不用服务器多发对手分数
NET.RK_EVEN = 16
function NET.rkWhy(win, d)
    local n = tonumber((tostring(d or ""):gsub("^%+", "")))
    if not n or n == 0 or (win ~= "1" and win ~= "0") then return nil end
    n = math.abs(n)
    local even = NET.RK_EVEN
    local s
    if n == even then s = T("双方分数相近", "EVENLY RATED")
    elseif (win == "1") == (n > even) then s = T("对手分比你高", "OPPONENT WAS RATED HIGHER")
    else s = T("对手分比你低", "OPPONENT WAS RATED LOWER") end
    if n ~= even then
        s = s .. (win == "1" and (n > even and T("，多加", ", MORE GAINED") or T("，少加", ", LESS GAINED"))
                                  or (n > even and T("，多扣", ", MORE LOST") or T("，少扣", ", LESS LOST")))
    end
    return s .. string.format(T("（同分是 ±%d）", " (EVEN = ±%d)"), even)
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
    -- §110 武林盟主：服务器的固定规则还没到，主机不开局（不拿本机房间设置冒充排位规则）
    ["排位规则未到"] = function()
        local lb = NET.rkLobby() or {}
        if lb.rkold == "1" then      -- §188 版本低于服务器的最低版本：规则永远不会到，直接说要升级
            return { { c = string.format(T("为保护平衡性，请最少使用 v%s 版本", "FOR BALANCE, RANKED NEEDS v%s OR NEWER"), lb.rkminver or "?"),
                       col = COL_RED, size = 1.4 },
                     { c = string.format(T("你现在是 v%s，升级后才能打武林盟主", "YOU HAVE v%s - UPDATE TO PLAY RANKED"), VERSION), col = COL_GRAY } }
        end
        return { { c = T("正在从服务器获取排位规则", "WAITING FOR THE RANKED RULES"), col = COL_ORANGE, size = 1.4 },
                 { c = T("拿到之前不能开局，稍等再按 F1", "CAN'T START YET - PRESS F1 AGAIN IN A MOMENT"), col = COL_GRAY } } end,
}

local function wireUpdate()
    local w = MATCH.wire
    if MATCH.role == "host" then
        w.mt = string.format("%s:%d:%d:%d:%s:%d", MATCH.state, MATCH.round, MATCH.me, MATCH.op, MATCH.win, MATCH.id)
        local a = MATCH.arena
        w.arena = a and string.format("%.1f:%.1f:%.1f:%.1f", a.x, a.y, a.z, a.yaw) or ""
    else
        w.mt, w.arena = "", ""
    end
    w.dead = MATCH.role and MATCH.dead or 0
    w.rdy = MATCH.ready and 1 or 0
end

local function enter(p1, s, tn, why)
    MATCH.state, MATCH.t0 = s, tn
    CS.safe("onState", CS.onState, s, tn)   -- §181 作弊数据采样：第 1 回合倒计时开一份，回自由活动收尾（出错不打断状态切换）
    syncFaction(true)
    if s == "cd" then
        MATCH.dead, MATCH.win, MATCH.pupFell, MATCH.hold = 0, "-", 0, {}
        -- 2026-11-06 用户"每次都是 2 场连战，2 场 3 局 2 胜之后才回到需要按 F1 确认的状态"：准备在开局时就用掉（两边都清），
        -- 以前客机要等看到主机回自由活动才清，主机一回自由活动就看到客机还没清掉的 rdy=1 → 马上又开一局
        if MATCH.round == 1 then MATCH.ready = false end
        NET.streak = {}
        standUp(p1); standUp(puppet())
        local pos, yaw = spawnPoint()
        -- v0.26.0 强制归位只对 AI 对手（用户："主要是为了给 AI 在开战前保持一定距离，真人对战不需要"）：
        -- AI 只会跟着你走，不归位就贴着脸开打；真人自己会拉开距离，各自留在原地
        if NET.rai then
            -- v0.26.2 安全放置（§79）：起点 = 开局时主机站的点（主机自己的出生点就是它，不用缩）
            local a = MATCH.arena
            local anchor = (MATCH.role ~= "host" and a) and { X = a.x, Y = a.y, Z = a.z + 20.0 } or nil
            safePlace(p1, pos, anchor, yaw, "第 " .. MATCH.round .. " 回合归位")
            setYaw(p1, yaw)
            pcall(function() getP1PC():SetControlRotation({ Pitch = -10.0, Yaw = yaw, Roll = 0.0 }) end)
        end
        refillPotions("第 " .. MATCH.round .. " 回合")     -- 已停用，只留着日志入口
        if MATCH.round == 1 and MATCH.rebuildPuppet then
            local okR, errR = pcall(MATCH.rebuildPuppet, "对局 #" .. MATCH.id .. " 开始")
            if not okR then out("!! 重建替身 -> %s", tostring(errR)) end
        end
        if not lockSelf(p1) then
            out("!! 锁血失败，为了不真死，对局中止")
            MATCH.state = "idle"
        end
        refill(p1)
        if MATCH.round == 1 then MATCH.tl = RT.limit() end         -- §173 回合时限这一场定下（客机按主机的 tl=）
        RT.cdStart(p1)                                              -- §173 倒计时无敌（挂不上 → 替身倒计时里当友方）
        syncFaction(true)
        if MATCH.round == 1 then CFG.begin() end                    -- §158 这一场用主机的数值表（客机收齐了）还是本地的
        if MATCH.round == 1 then RFP.begin(tn) end                  -- §210 规则都定下了：算这一场的规则指纹、发给对方
        if MATCH.round == 1 then STD.lv, STD.eq.at = {}, -100 end   -- §148 两场之间可能升过级 / 换过配装：等级缓存每场重读
        STD.capture(p1)                                                 -- §170.5 先记对局前的属性（饰品还没换）
        ACC.apply(p1)                                                   -- §170.1（§170.5 先于标准数值：锁定属性要按换过的饰品算） 饰品等级
        STD.apply(p1, "第 " .. MATCH.round .. " 回合倒计时")         -- §144 标准数值（先于 §113：精纯杀气 / 暗源的上限由它定）
        NET.resApply(p1, "第 " .. MATCH.round .. " 回合倒计时")      -- §113
        CDL.snap(p1)                                                    -- §173.7 倒计时里拦掉的大招 / 影武扣的资源按这个写回
        GCD.reset("第 " .. MATCH.round .. " 回合开局")                   -- §184 火枪冷却每回合清零
        DCD.reset("第 " .. MATCH.round .. " 回合开局")                   -- §200 闪避冷却每回合清零
        if MATCH.round == 1 then NET.attrDiffLog(p1) end             -- §116.2 只读：我和替身的属性差在哪
        out("== 第 %d 回合 倒计时 %.0f 秒（我 %d : %d 对方）；我是%s，%s ==",
            MATCH.round, CD_SEC, MATCH.me, MATCH.op, MATCH.role == "host" and "主机" or "客机",
            NET.rai and string.format("对手是 AI，归位到出生点 (%.0f, %.0f) 朝向 %.0f", pos.X, pos.Y, yaw) or "真人对战，不强制归位")
        if MATCH.state ~= "idle" then return end
        s = "idle"
    end
    -- v0.22.0：主机的回合 / 对局结果另发一份可靠事件。客机平时跟着状态包里的 mt= 走；
    -- 结算画面只有几秒，客机那几秒收不到包（卡顿 / 丢包）时就靠这份补上结果
    if MATCH.role == "host" and s == "rend" then
        REL.send("rend", string.format("%d %d %s %d %d", MATCH.id, MATCH.round, MATCH.win, MATCH.me, MATCH.op))
    elseif MATCH.role == "host" and s == "end" then
        REL.send("mend", string.format("%d %d %d", MATCH.id, MATCH.me, MATCH.op))
    end
    if s == "fight" then
        if MATCH.tl == nil then MATCH.tl = RT.limit() end              -- §173 客机直接从交手跟进来的（没经过倒计时）
        RT.fightStart(p1)                                               -- §173 撤倒计时无敌、清掉异常状态 / 增益（自己 + 替身）
        STD.capture(p1)                                                 -- §170.5 先记对局前的属性（饰品还没换）
        ACC.apply(p1)                                                   -- §170.1（§170.5 先于标准数值：锁定属性要按换过的饰品算）
        STD.apply(p1, "第 " .. MATCH.round .. " 回合开打")           -- §144
        NET.resApply(p1, "第 " .. MATCH.round .. " 回合开打")        -- §113 倒计时里的回满效果可能补满了它们，开打再写一次
        refill(p1)                                                      -- §173 清完状态回满（血 / 杀气）
        RT.begin(p1)                                                    -- §173 受伤从这里开始算
        out("== 第 %d 回合 开打 ==", MATCH.round)
    elseif s == "rend" then
        out("== 第 %d 回合结束：%s（我 %d : %d 对方）==", MATCH.round,
            MATCH.win == "d" and ((RT.info and RT.info.round == MATCH.round) and "时间到、受伤一样，平局不计分" or "同时倒下，平局不计分")
                or (iWon() and "我赢" or "对方赢"), MATCH.me, MATCH.op)      -- §173.9 限时判的平局不是"同时倒下"
    elseif s == "end" then
        out("== 对局结束：%s %d : %d ==", MATCH.me > MATCH.op and "胜利" or "失败", MATCH.me, MATCH.op)
    elseif s == "idle" then
        out("== 对局结束（%s），回到自由活动 ==", why or "-")
        -- v0.17.10：对局外不再锁血（见下面"陪练保护"），对局一结束就解锁，不管还连没连着
        if not LO.IDLE_LOCK or tn - NET.lastRecvAt > 1.0 then unlockSelf(p1, why or "对局结束") end
        RT.unshield(p1)          -- §173 倒计时里结束的（弃权 / 掉线）：无敌撤掉
        MATCH.tl, RT.info = nil, nil
        GCD.reset(why or "对局结束")      -- §184 火枪冷却清零
        DCD.reset(why or "对局结束")      -- §200 闪避冷却清零
        standUp(p1); standUp(puppet())
        ACC.restore(p1)          -- §170.1 饰品换回（§170.5 先于标准数值还原：还原的属性是饰品没换时记的）
        STD.restore(p1)          -- §144 先还原血上限等，再回满
        CFG.finish()             -- §158 数值表换回本地
        refill(p1)
        NET.resRestore(p1)       -- §113 还原对局前的精纯杀气 / 暗源
        MATCH.res = nil
        MATCH.role, MATCH.hold, MATCH.dead = nil, {}, 0
        MATCH.lastTx = nil
        MATCH.ready = false
        MATCH.quitArm = nil
        MATCH.toast = TOAST_OF[why or ""] and { rows = TOAST_OF[why](), till = tn + TOAST_SEC } or nil
        showHud(nil)
        syncFaction(true)
    end
end

local function startMatchNow()
    local p1 = getP1()
    if not valid(p1) then return end
    local tn = now()
    if not valid(puppet()) then out("!! 对手还没生成，不能开局"); return end
    if (hpOf(p1) or 0) <= 0 and not MATCH.lock then
        out("!! 你现在是真死状态（血量 0），不能开局：等游戏复活你，或者重启游戏")
        return
    end
    if NET.rkWaiting() then         -- §110 武林盟主：规则还没从服务器拿到，不开局（F1 那里也拦，这里兜底：准备后规则才丢的情况）
        out("!! 武林盟主：还没拿到服务器的排位规则，不能开局")
        MATCH.ready = false
        MATCH.toast = { rows = TOAST_OF["排位规则未到"](), till = tn + TOAST_SEC }
        return
    end
    if not WBAN.gate(tn) then wireUpdate(); return end     -- §180 自己 / 对方装着禁用武器、影之武装 → 不开局
    local loc = try("arena loc", function() return p1:K2_GetActorLocation() end)
    local rot = try("arena rot", function() return p1:K2_GetActorRotation() end)
    if not (loc and rot) then return end
    MATCH.role, MATCH.round, MATCH.me, MATCH.op = "host", 1, 0, 0
    MATCH.toWin = NET.toWin()     -- v0.26.3 局数开局时定下，对局中改设置不影响这一局
    MATCH.dmPct = NET.dmgPct()    -- §86 伤害倍率也是开局时定下
    MATCH.ab = NET.allBlock()     -- §87 全部可格挡，同样开局时定下
    MATCH.flags = NET.flagsNow()  -- §105.3 / §106.5 红蓝光反击、武器平衡，同样开局时定下
    MATCH.res = NET.resNow()      -- §113 开局精纯杀气 / 暗源，同样开局时定下
    MATCH.id = (MATCH.id or 0) + 1
    if NET.rkRules() then out("武林盟主：用服务器定的固定规则（%s）", tostring(NET.rkCache.s)) end
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
    else
        setArena(loc.X, loc.Y, loc.Z, rot.Yaw)
        out("== 发起对局 #%d（先赢 %d 回合）：%s，场地中心在你正前方 %.0f ==", MATCH.id, MATCH.toWin,
            saved and ("存的场地在别的地图 " .. tostring(saved.map)) or "没有用 F2 存过场地", SPAWN_D)
    end
    textActor(p1)
    enter(p1, "cd", tn)
    wireUpdate()
end

-- §180 禁用武器 / 影之武装的开局关卡（WBAN 段在房间设置那里）。屏幕提示 = 一条橙字 + 一行灰字
function WBAN.toast(msg, tn)
    MATCH.toast = { rows = { { c = T(msg[1], msg[2]), col = COL_ORANGE, size = 1.3 },
                             { c = T("房间设置禁用了这些武器 / 影之武装（联机面板 → 房间设置）", "BANNED BY THE ROOM RULES (PANEL -> ROOM SETTINGS)"), col = COL_GRAY } },
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
    WBAN.toast(msg, tn)
    -- 给客机：wban <原因> <名单键> <中文名>|<英文名>（原因 host = 主机自己装着、hit = 你装着、none = 主机收不到你的配装）
    if code ~= "old" and (MATCH.session and MATCH.session.role) ~= "client" and tn - NET.lastRecvAt <= 1.0 then
        REL.send("wban", string.format("%s %s %s|%s", code, k or "-", h and h[1] or "-", h and h[2] or "-"))
    end
    return false
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
RFP = { WAIT = 3.0, F = 1, mid = nil, fp = nil, text = nil, at = 0, peer = nil, peerText = nil, bad = nil, logged = nil,
        NAME = { bo = { "局数", "BEST OF" }, dm = { "伤害倍率", "DAMAGE" }, ab = { "全部可格挡", "ALL BLOCKABLE" }, tl = { "回合时限", "TIME LIMIT" },
                 ctr = { "红蓝光反击", "COUNTERS" }, bal = { "武器平衡", "WEAPON BALANCE" }, med = { "血瓶", "POTIONS" },
                 npos = { "对手位置严格跟随", "STRICT FOLLOW" }, std = { "标准数值", "STANDARD STATS" }, cs = { "作弊数据采样", "CHEAT SAMPLING" },
                 ult0 = { "开局精纯杀气", "START ULT" }, ultx = { "精纯杀气获取", "ULT GAIN" }, sp0 = { "开局暗源", "START EDGE" },
                 resm = { "资源每场 / 每局", "RESOURCE RESET" }, acc = { "饰品等级", "ACCESSORY LEVEL" }, accn = { "生效饰品数量", "ACCESSORY LIMIT" },
                 accban = { "禁用饰品", "BANNED ACCESSORIES" }, wpnban = { "禁用武器", "BANNED WEAPONS" }, edgeban = { "禁用影之武装", "BANNED EDGES" },
                 cfg = { "数值表", "BALANCE TABLE" }, rk = { "武林盟主", "RANKED" }, f = { "指纹格式", "FORMAT" } } }
local function rfpVal(v)
    if v == nil then return "-" end
    if v == true then return "1" elseif v == false then return "0" end
    if type(v) == "number" then return CFG.num(v) end
    return (tostring(v):gsub("[;=%s]", "_"))
end
-- 这一场实际用上的规则 → "k=v;k=v"（键排好序；两边同一套规则 = 同一串）
function RFP.build()
    local kv = { f = RFP.F, rk = NET.rkRules() and 1 or 0, bo = MATCH.toWin, dm = MATCH.dmPct, ab = MATCH.ab, tl = MATCH.tl or 0 }
    for k, v in pairs(MATCH.flags or {}) do kv[k] = v end
    for k, v in pairs(MATCH.res or {}) do if kv[k] == nil then kv[k] = v end end
    local tbl = MATCH.flags and (MATCH.flags.bal or MATCH.flags.std)
    kv.cfg = tbl and (CFG.usedHash or CFG.localHash) or "-"      -- 武器平衡 / 标准数值都关着时数值表不影响伤害
    local ks = {}
    for k in pairs(kv) do ks[#ks + 1] = k end
    table.sort(ks)
    local o = {}
    for _, k in ipairs(ks) do o[#o + 1] = k .. "=" .. rfpVal(kv[k]) end
    return table.concat(o, ";")
end
function RFP.parse(s)
    local t = {}
    for k, v in (s or ""):gmatch("([%w_]+)=([^;]*)") do t[k] = v end
    return t
end
-- 两串里不一样的键（按 NAME 写成人话，最多 n 个）
function RFP.diff(a, b, n, lang)
    local ta, tb, ks, seen = RFP.parse(a), RFP.parse(b), {}, {}
    for k in pairs(ta) do seen[k] = true end
    for k in pairs(tb) do seen[k] = true end
    for k in pairs(seen) do if ta[k] ~= tb[k] then ks[#ks + 1] = k end end
    table.sort(ks)
    local o = {}
    for i, k in ipairs(ks) do
        if i > (n or 99) then o[#o + 1] = "…"; break end
        o[#o + 1] = RFP.NAME[k] and RFP.NAME[k][lang or 1] or k
    end
    return o
end
-- 每场第 1 回合倒计时、CFG.begin 之后调（主机 / 客机都调）
function RFP.begin(tn)
    RFP.text = RFP.build()
    RFP.fp, RFP.mid, RFP.at, RFP.bad, RFP.logged = CFG.hash(RFP.text), MATCH.id, tn, nil, nil
    out("规则指纹（对局 #%d）：%s = %s", RFP.mid, RFP.fp, RFP.text)
    pcall(REL.send, "rfpx", string.format("%d %s", RFP.mid, RFP.text))
end
function RFP.reset() RFP.mid, RFP.fp, RFP.text, RFP.bad, RFP.logged, RFP.peer, RFP.peerText = nil, nil, nil, nil, nil, nil, nil end
-- 状态包：rfp=<局号>:<指纹>；对局外 / 还没定 = "-"（联机程序也看它，排位时报给服务器）
function RFP.wire()
    if not (RFP.mid and RFP.mid == MATCH.id and MATCH.state ~= "idle") then return "-" end
    return RFP.mid .. ":" .. RFP.fp
end
-- 收包：记下对方的；然后比
function RFP.onPacket(v, tn)
    local mid, fp = (v or ""):match("^(%d+):(%x+)$")
    if mid then RFP.peer = { mid = tonumber(mid), fp = fp } end
    RFP.step(tn)
end
function RFP.step(tn)
    if MATCH.state == "idle" or not RFP.mid or RFP.mid ~= MATCH.id then RFP.bad = nil; return end
    -- §210.3 对方是本地 AI / 测试假对手（状态包 ai=1）：包是本机联机程序 / 测试脚本造的，不发 rfp=，规则就是我自己的 → 不比
    -- （11-10 总控实测：本地 AI 开局 3 秒误报"对方版本旧"，日志里的"对方版本 0.31.0"是联机程序自己的版本号）
    if NET.rai then RFP.bad = nil; return end
    local p = RFP.peer
    local bad
    if p and p.mid == RFP.mid then bad = p.fp ~= RFP.fp and "diff" or nil
    elseif tn - RFP.at > RFP.WAIT then bad = "none" end
    RFP.bad = bad
    if bad and RFP.logged ~= bad then
        RFP.logged = bad
        local pt = RFP.peerText and RFP.peerText.mid == RFP.mid and RFP.peerText.t or nil
        if bad == "diff" then
            out("!! 规则指纹对不上（对局 #%d）：我 %s / 对方 %s；不一样的：%s；对方 %s", RFP.mid, RFP.fp, p.fp,
                pt and table.concat(RFP.diff(RFP.text, pt), "、") or "（对方整串还没到）", pt or "-")
        else
            out("!! 对方 %.0f 秒没报规则指纹（对局 #%d，对方版本 %s 没有这项检查），双方用的规则 / 数值可能不一样", RFP.WAIT, RFP.mid, tostring(NET.rav))
        end
    end
end
-- 对局横幅（倒计时 / 交手中都显示）
function RFP.rows()
    if not RFP.bad then return nil end
    local c
    if RFP.bad == "diff" then
        local pt = RFP.peerText and RFP.peerText.mid == RFP.mid and RFP.peerText.t or nil
        local zh = pt and table.concat(RFP.diff(RFP.text, pt, 3, 1), "、") or "?"
        local en = pt and table.concat(RFP.diff(RFP.text, pt, 3, 2), ", ") or "?"
        c = string.format(T("双方规则不一致：%s", "RULES DIFFER: %s"), T(zh, en))
    else
        c = T("对方模组版本较旧，没报规则，双方数值可能不一致", "OPPONENT'S MOD IS OLD: RULES MAY DIFFER")
    end
    if NET.rkRules() then c = c .. T("（本场武林盟主可能不计分，请双方更新）", " (RANKED MAY NOT COUNT - BOTH UPDATE)") end
    return { { c = c, col = COL_RED, size = 0.8, nolog = true } }
end
REL.on.rfpx = function(rest)        -- §210 对方这一场的规则整串（对不上时说清哪项）
    local mid, txt = rest:match("^(%d+) (.*)$")
    if mid then RFP.peerText = { mid = tonumber(mid), t = txt } end
end

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
    WBAN.toast(msg, now())
    wireUpdate()
end

-- v0.13.1：联机会话（旁车 / 联机窗口写 net/session.txt：role=host|client，connected=0|1，peer=…）。
-- 没有这个文件（幽灵测试）时按主机处理
local SESSION_FILE = NET_DIR .. "/session.txt"
local function sessionRole()
    return (MATCH.session and MATCH.session.role) or "host"
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
    if not okP then okP, P = pcall(function() return dofile(ROOT .. "/Scripts/pbz_places.lua") end) end
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
    out("== 前往主机所在地图 %s（%.0f, %.0f, %.0f）：游戏会先自动存档再加载 ==", target, pos.X, pos.Y, pos.Z)
    wireUpdate()
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
    if MATCH.resSaved then return "开局精纯杀气 / 暗源还没还原" end
    if MATCH.lock then return "锁血还挂着" end
    if ST.spec and ST.spec.on then return "观战中" end
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
    out("== 传送到主机身边：同地图离得远，走游戏的传送 (%.0f, %.0f, %.0f)，会自动存档、等地形加载 ==", pos.X, pos.Y, pos.Z)
    wireUpdate()
    return true
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
    if not MATCH.ready and sessionRole() ~= "client" and NET.rkWaiting() then    -- §110 武林盟主：主机等服务器的规则到了才能开局
        out("!! 武林盟主：还没拿到服务器的排位规则，不能准备开局")
        MATCH.toast = { rows = TOAST_OF["排位规则未到"](), till = tn + TOAST_SEC }
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

-- §179.3 武林盟主客机复核（方案 A1；用户 11-09"先只记争议不作废"）：对局流程全由主机定，改过的主机可以每回合都判自己赢。
-- 客机对照自己知道的事实：主机判我输的回合——倒下判的：我这回合真倒下过没有（MATCH.dead）；时间到判的：主机说我受的伤（rtime 的 c）
-- 比我自己记的（RT.taken）多出 RKC.TOL 以上；打完时主机的分比我看到它赢的回合多。对不上的次数经状态包 rkd=<对局>:<次数> 给联机程序，
-- 联机程序上报时 why 写 dsp:<次数>，服务器只记下来（积分照常）。rtime 是可靠事件、可能比 mt= 的 rend 晚到，所以 rend 后等 RKC.WAIT 秒再判
RKC = { WAIT = 1.5, TOL = 50, TOL_PCT = 0.2, id = nil, n = 0, seenH = 0, pend = nil, done = {}, ended = false }
function RKC.reset(id) RKC.id, RKC.n, RKC.seenH, RKC.pend, RKC.done, RKC.ended = id, 0, 0, nil, {}, false end
function RKC.judge(rd, w)
    RKC.done[rd] = true
    if w ~= "h" then return end
    RKC.seenH = RKC.seenH + 1
    local bad, why
    if RT.info and RT.info.round == rd then
        local mine = RT.round == rd and RT.taken or nil
        local claim = RT.info.c or 0
        bad = mine and claim > mine + math.max(RKC.TOL, mine * RKC.TOL_PCT)
        why = string.format("时间到，主机说我受伤 %.0f、我记的 %s", claim, mine and string.format("%.0f", mine) or "?")
    else
        bad = MATCH.dead ~= rd
        why = "主机判我倒下，我这边没倒"
    end
    if bad then
        RKC.n = RKC.n + 1
        out("!! 武林盟主复核：第 %d 回合主机判我输，对不上（%s），记一次争议（共 %d）", rd, why, RKC.n)
    end
end
function RKC.follow(s, rd, hs, w, id, tn)
    if RKC.id ~= id then RKC.reset(id) end
    if s == "rend" and not RKC.done[rd] and not (RKC.pend and RKC.pend.rd == rd) then RKC.pend = { rd = rd, w = w, at = tn } end
    local p = RKC.pend
    if p and (tn - p.at >= RKC.WAIT or s ~= "rend" or rd ~= p.rd) then RKC.pend = nil; RKC.judge(p.rd, p.w) end
    if s == "end" and not RKC.ended then
        RKC.ended = true
        if hs > RKC.seenH then
            RKC.n = RKC.n + 1
            out("!! 武林盟主复核：主机报 %d 分，我只看到它赢了 %d 回合，记一次争议（共 %d）", hs, RKC.seenH, RKC.n)
        end
    end
end
function RKC.wire()
    if MATCH.role ~= "client" or RKC.id ~= MATCH.id or RKC.n == 0 then return "-" end
    return string.format("%d:%d", RKC.id, RKC.n)
end

-- 客机：跟随主机的 mt。返回 false 表示没有要跟随的对局
local function followHost(p1, tn)
    local rm = NET.rmt
    local s, rd, hs, cs, w, id = (rm or ""):match("^(%a+):(%d+):(%d+):(%d+):(%S):(%d+)$")
    if not s then return false end
    rd, hs, cs, id = tonumber(rd), tonumber(hs), tonumber(cs), tonumber(id)
    if MATCH.role ~= "client" then
        if s ~= "cd" and s ~= "fight" then return false end
        -- 刚弃权的那一局：主机还没收到弃权、仍在发 fight，不要再跟进去（离线测试抓到：会立刻重新加入，弃权标记也被清掉）
        if id == MATCH.wire.quit then return false end
        MATCH.role, MATCH.state, MATCH.id = "client", "idle", id
        MATCH.wire.quit = 0
        MATCH.toWin = NET.toWin()     -- v0.26.3 主机的局数（bo=），只用来显示
        MATCH.dmPct = NET.dmgPct()    -- §86 主机的伤害倍率（dm=），这一局就用它
        MATCH.ab = NET.allBlock()     -- §87 主机的"全部可格挡"（ab=），我这边防守时按它软格挡
        MATCH.flags = NET.flagsNow()  -- §105.3 / §106.5 主机的红蓝光反击（ctr=）、武器平衡（bal=）
        MATCH.res = NET.resNow()      -- §113 主机的开局精纯杀气（ult0=）/ 暗源（sp0=）
        if NET.rkRules() then out("武林盟主：用服务器定的固定规则（%s），不看主机的房间设置", tostring(NET.rkCache.s)) end
        out("== 对方发起了对局 #%d（先赢 %d 回合），跟随 ==", id, MATCH.toWin)
        local src = NET.rkRules() and "武林盟主固定规则" or "主机设置"     -- §110 排位时规则是服务器定的
        if MATCH.dmPct ~= 100 then out("伤害倍率 %d%%（%s，这一局）", MATCH.dmPct, src) end
        out("红蓝光反击：%s；武器平衡：%s；血瓶：%s；开局精纯杀气 %d（获取 %d%%）、暗源 %d、%s（%s，这一局）", MATCH.flags.ctr and "开" or "关",
            MATCH.flags.bal and "开" or "关", MATCH.flags.med and "开" or "关", MATCH.res.ult0, MATCH.res.ultx, MATCH.res.sp0, NET.resText("resm", MATCH.res.resm)[1], src)
        textActor(p1)
    end
    local ax, ay, az, ayaw = (NET.rarena or ""):match("^([%-%d%.]+):([%-%d%.]+):([%-%d%.]+):([%-%d%.]+)$")
    if ax then setArena(tonumber(ax), tonumber(ay), tonumber(az), tonumber(ayaw)) end
    if NET.rkRules() and id == MATCH.id then RKC.follow(s, rd, hs, w, id, tn) end     -- §179.3
    MATCH.me, MATCH.op, MATCH.win = cs, hs, w
    if s == "idle" or id ~= MATCH.id then enter(p1, "idle", tn, REL.endWhy()); return true end
    if (s ~= MATCH.state or rd ~= MATCH.round) and MATCH.center then
        MATCH.round = rd
        enter(p1, s, tn)
    end
    return true
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
REL.on.chat = function(rest) CHAT.recv(rest) end      -- §112 房内聊天（CHAT 在联机面板段）
REL.on.cfgreq = function(rest)    -- §158 客机要我的数值表
    if (MATCH.session and MATCH.session.role) == "client" then return end
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
    if ST.spec then pcall(ST.spec.Q.tick, tn) end      -- §141.7 对手不准备超时 → 换下一位
    HOV.step(tn)    -- §99 悬空等地形加载（客机放到主机身边、替身瞬移到远处）
    if PHEAL.want and lost < 1.0 and not PP.on and not (ST.spec and ST.spec.on) then PHEAL.step() end    -- §162 替身坏了换一个
    if ST.ticks % 30 == 0 then
        local kv = fileReadKV(SESSION_FILE)
        local was = MATCH.session and MATCH.session.role
        local wasRelay = MATCH.session and MATCH.session.relay
        -- §141.8 主机回来打：收起观战（主机下场时收到的两路包已经停了）
        if kv and wasRelay == "1" and kv.relay ~= "1" and ST.spec and ST.spec.on then ST.spec.stop("主机回来打") end
        MATCH.session = kv
        if kv and kv.role ~= was then
            out("联机会话：%s（对端 %s）", tostring(kv.role), tostring(kv.peer))
            if ST.spec then ST.spec.onRole(was, kv.role) end      -- §141 换了会话：观战可以重新自动开；§141.7 上场 / 下场
        end
    end
    local fresh = lost < 1.0
    -- §116.1 对手断开超过 LOST_SEC 秒就忘掉"上一个对手是 AI / 叫什么"：不然下一个连接被当成 AI 房间换人（§85.5 按昵称变没变）。
    -- 2026-11-06 17:11 实测：假对手 17:10 断开，17:11 开本地 AI 对战，弹"AI 对手 加入了你的房间，AI 对战已关闭"。
    -- 真正的 AI 房间换人是联机程序当场交接，断不到 LOST_SEC
    if lost > LOST_SEC and (NET.rai ~= nil or NET.rnm ~= nil) then NET.rai, NET.rnm = nil, nil end
    -- 2026-11-05 09:07 实测：主机在另一张地图时也生成了替身（站到 298070 外的主机坐标上，跟着对方动）。对方在别的地图 = 不生成，有就藏起
    local otherMap = NET.rmap ~= nil and NET.rmap ~= "" and NET.rmap ~= mapName(p1)
    -- 连上就自动生成对手；断开 LOST_SEC 秒后藏起（只藏自动生成的；F3 手动造的测试替身不动）
    if fresh and otherMap and MATCH.autoPup and valid(puppet()) and not MATCH.role and MATCH.autoRemove then
        out("== 对方在另一张地图（%s），藏起对手角色 ==", tostring(NET.rmap))
        MATCH.autoRemove()
        MATCH.autoPup, MATCH.joined = nil, nil
    elseif fresh and not otherMap and not valid(puppet()) and ST.stableTicks > 150 and MATCH.autoCreate and not PP.on then
        out("== 对手已连上，自动生成对手角色 ==")
        PHEAL.reset()       -- §162 新连接：换替身次数重新算
        MATCH.autoCreate()
        MATCH.autoPup = true
        MATCH.joined = nil
    elseif not fresh and lost > LOST_SEC and MATCH.autoPup and valid(puppet()) and not MATCH.role and MATCH.autoRemove then
        out("== 对手断开，藏起对手角色 ==")
        MATCH.autoRemove()
        MATCH.autoPup, MATCH.joined, MATCH.ready = nil, nil, false
    elseif PP.on and MATCH.autoPup and valid(puppet()) and not MATCH.role and MATCH.autoRemove then
        -- v0.21.0：Phantom Pact 在联机（它会给对方生成自己的幽灵）→ 藏起我们的替身；它断开后上面的"自动生成"会再造出来
        out("== Phantom Pact 合作联机中，藏起对手角色（它断开后自动恢复）==")
        MATCH.autoRemove()
        MATCH.autoPup, MATCH.joined, MATCH.ready = nil, nil, false
    end
    if not fresh then return end
    if PP.on and not MATCH.role then MATCH.ready = false; return end     -- 不传送、不开局
    -- 客机：连上后瞬移到主机身边（同一张地图时）；地图不同就提示，玩家确认后切图（v0.24.1，MAPGO 段）
    local myMap = mapName(p1)
    if sessionRole() == "client" or sessionRole() == "spec" then MAPGO.step(p1, myMap) end
    -- §141 观战者：主机在别的地图就提示（观战代码这时不摆替身）
    if sessionRole() == "spec" and NET.rmap and NET.rmap ~= myMap and NET.since() < 1.0 then MAPGO.notice(myMap) end
    if sessionRole() == "client" and not MATCH.joined and NET.pos then
        if NET.rmap and NET.rmap ~= myMap then
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
    if not MATCH.role and sessionRole() ~= "client" and MATCH.ready and (NET.rrdy or 0) == 1 then
        out("== 双方都已准备，开局 ==")
        startMatchNow()
    end
    -- 主机：客机弃权
    if MATCH.role == "host" and (NET.rquit or 0) == MATCH.id and MATCH.id > 0 then
        out("== 对方弃权 ==")
        enter(p1, "idle", tn, "对方弃权")
    end
end

-- ---- net-ui 游戏内联机面板（docs/NETWORK_UI.md §2.4–2.5）。Home 开 / 关；开着时 PgUp/PgDn 选、End 确定（v0.18.4 起不再用方向键 / 回车，见文件末尾）。
-- 画面就是上面的 HUD（最多 9 行）。内容来自联机窗口每 0.5 秒写的 net/lobby.txt；操作写 net/cmd.txt（id 每次不同，窗口只执行一次）。
-- 联机窗口没开着（lobby.txt 的 alive 超过 3 秒没更新）时自动以后台模式启动它（PBZLobby.exe --bg）：
-- v0.18.5 起模组一加载就拉起（用户定：保留联机程序，但要做到完全不用管），打开面板时发现它没响应再拉一次。
-- 自动拉起最多连续 NETUI_AUTO_TRIES 次，之后只在面板上按 End 手动重试。
-- 启动计时一律用 os.time()：now() 在玩家生成前是 os.time、之后换成游戏时间，两种时基相减会算出负数（永远"正在启动"）
local NETUI = { open = false, sel = 1, cmdN = 0, lobby = nil, readAt = 0.0, launchAt = nil, tries = 0, items = {} }
local NETUI_AUTO_TRIES = 3
-- §91 发出后要等联机程序回话的命令（copy / show / refresh 不等：copy 自己闪提示，另两个面板上看不出变化）
NETUI.BUSY_SEC = 5.0
NETUI.BUSY = {
    host = { "正在创建房间", "CREATING THE ROOM" }, ai = { "正在开始 AI 对战", "STARTING THE AI BATTLE" },
    join = { "正在加入", "JOINING" }, stop = { "正在断开", "DISCONNECTING" }, mode = { "正在切换连接方式", "SWITCHING" },
    spectate = { "正在进入观战", "JOINING AS SPECTATOR" }, rotate = { "正在换人", "ROTATING" }, tospec = { "正在下场", "STEPPING DOWN" },
    hostdown = { "正在下场", "STEPPING DOWN" }, hostup = { "正在回来", "COMING BACK" },
}
for _, c in ipairs({ "name", "port", "upnp", "relay", "server", "secret", "lang", "ailevel", "aiload", "airoom", "airoommode" }) do
    NETUI.BUSY[c] = { "正在保存", "SAVING" }
end
local LOBBY_FILE, CMD_FILE = NET_DIR .. "/lobby.txt", NET_DIR .. "/cmd.txt"
-- v0.20.2：虚拟局域网并进局域网（局域网顺带找 Tailscale 节点、显示虚拟网卡地址；联机程序把旧的 vlan 当 lan）
-- v0.20.3：广域网并进服务器大厅（"输入 IP 直连…"；联机程序把旧的 wan 当 server）
local NET_MODES = { "steamlobby", "steam", "server", "lan", "ai" }   -- 顺序同联机程序的 Modes.All（End 按这个顺序换；v0.20.4 用户定：Steam 大厅、Steam 好友、服务器大厅、局域网；§75 本地 AI 在局域网后面）
-- §110 武林盟主（ranked）排在服务器大厅后面。只有报 modes= 的新版联机程序才有它，所以不进上面那个"旧版联机程序"的兜底列表；
-- 鼠标面板的标签页按这个全集建（联机程序没报的方式藏起，见 guiTick）
NETUI.TABS = { "steamlobby", "steam", "server", "ranked", "lan", "ai" }
-- §98 实际能用的方式以联机程序报的 lobby.txt modes= 为准（发布版不带 Steam 方式）；旧版联机程序没这一项时用 NET_MODES
NETUI.modes = function()
    local s = NETUI.lobby and NETUI.lobby.modes or ""
    if s == "" then return NET_MODES end
    if NETUI.modesKey ~= s then
        local l = {}
        for m in s:gmatch("[^,]+") do l[#l + 1] = m end
        NETUI.modesKey, NETUI.modesList = s, (#l > 0 and l or NET_MODES)
    end
    return NETUI.modesList
end
NETUI.hasMode = function(m)
    for _, x in ipairs(NETUI.modes()) do if x == m then return true end end
    return false
end
-- §110 武林盟主（ranked）底下走的就是服务器大厅那一套：房间列表、建房、房间号、复制、线路都和 server 一样（只是没有 IP 直连）
NETUI.viaServer = function(m) return m == "server" or m == "ranked" end
-- v0.19.1：房间多了放到单独的"房间列表"页（用户 2026-11-04："房间多了这个列表会不会很难操作"）。
-- 以前主页最多列 3 个、联机程序最多给 8 个，多出来的根本看不到。现在：主页只放剪贴板 / 最近（快捷加入，最多 NETUI_QUICK 个）
-- 和一行"房间列表（N 个）…"；房间列表页每页 NETUI_PER_PAGE 个，在页首 / 页尾再往上 / 往下自动翻页
local NETUI_QUICK = 2
local NETUI_PER_PAGE = 6
local GUI_PER_PAGE = 8       -- v0.20.1 鼠标面板的房间列表页不受屏幕文字 12 行的限制，每页多放几个

local function netModeName(m)
    if m == "steam" then return T("Steam 好友", "STEAM FRIENDS")
    elseif m == "server" then return T("服务器大厅", "LOBBY SERVER")
    elseif m == "ranked" then return T("武林盟主", "RANKED")
    elseif m == "steamlobby" then return T("Steam 大厅", "STEAM LOBBY")
    elseif m == "ai" then return T("本地 AI", "LOCAL AI") end
    return T("局域网", "LAN")
end

-- 服务器大厅的线路（lobby.txt 的 route）：直连 / 中转 / 第几次直连
local function netRouteName(r)
    if r == "direct" then return T("直连", "DIRECT")
    elseif r == "relay" then return T("服务器中转", "RELAY")
    -- §135 武林盟主的对局走 Steam：Steam 已连上 / 正在经 Steam 连 / 还在向大厅服务器报到
    elseif r == "steam" then return "Steam"
    elseif r == "steamwait" then return T("正在经 Steam 连接", "CONNECTING VIA STEAM")
    elseif r == "join" then return T("向大厅服务器报到", "JOINING VIA LOBBY") end
    local k = (r or ""):match("^punch(%d)$")
    if k then return T("直连第 " .. k .. "/3 次", "DIRECT TRY " .. k .. "/3") end
    return nil
end

-- 按字符截断（中文是多字节）：太长的行会出屏
local function clipText(s, n)
    s = tostring(s or "")
    local ok, len = pcall(utf8.len, s)
    if not ok or not len or len <= n then return s end
    return s:sub(1, utf8.offset(s, n + 1) - 1) .. ".."
end

local function lobbyAlive(lb)
    return lb ~= nil and (tonumber(lb.alive) or 0) > os.time() - 3
end

local function netuiRead(tn, force)
    -- v0.24.0：now() 在玩家控制器就绪前退回 os.time()（约 17 亿秒），之后才是游戏秒数；那时定下的 readAt 会让这里永远不再读文件
    -- （对手血条一直拿不到 peername）。下次读的时间比现在晚 5 秒以上 = 时间基准变了，立即重读
    if not force and tn < NETUI.readAt and NETUI.readAt - tn < 5 then return NETUI.lobby end
    NETUI.readAt = tn + (NETUI.busy and 0.05 or NETUI.open and 0.25 or 1.0)
    if NETUI.busy and PIPE then PIPE.blobAt = 0 end      -- §91 等命令回话：管道这次不按 BLOB_SEC 节流，马上问
    -- v0.18.6：联机程序每 0.5 秒整个替换一次 lobby.txt，正好碰上时读不到 → 以前面板会闪一下红字"没响应"（用户 18:29 反馈）。
    -- 读失败就沿用上一次的内容；程序真没了的话，上一次的 alive 时间戳 3 秒后自然过期
    local kv = fileReadKV(LOBBY_FILE)
    if kv or not NETUI.lobby then NETUI.lobby = kv end
    return NETUI.lobby
end
-- §110 排位固定规则（NET.rk，M2 段）从这里拿 lobby.txt 的 rk= / rkrules=：照 netuiRead 的节流（面板关着 1 秒读一次），不额外读盘
NET.rkLobby = function() return netuiRead(now()) end

local function netuiCmd(cmd, extra)
    NETUI.cmdN = NETUI.cmdN + 1
    local id = string.format("%d-%d", os.time(), NETUI.cmdN)
    local ok = fileWrite(CMD_FILE, string.format("id=%s\ncmd=%s\n%s", id, cmd, extra or ""))
    -- §181 举报的 ev=（一整份对局摘要 JSON）不进日志：只记长度和计数那一段
    local shown = ("\n" .. (extra or "")):gsub("\nev=([^\n]*)", function(j)     -- 只认行首的 ev=（附言里写了 ev= 不算）
        return string.format("\nev=<%d 字节 c=%s>", #j, j:match('"c":(%b{})') or "?")
    end)
    out("联机面板 → 联机窗口：%s %s（id=%s，%s）", cmd, (shown:sub(2):gsub("\n", " ")), id, ok and "已写" or "写失败")
    NETUI.readAt = 0.0
    -- §91 等联机程序回话（lobby.txt 的 ack = 这条命令的 id）：状态行显示"正在…"，按钮变灰点不了，5 秒没回话报错
    local w = ok and NETUI.BUSY[cmd]
    if w then
        if cmd == "host" and (NETUI.lobby or {}).mode == "ai" then w = NETUI.BUSY.ai end
        NETUI.busy = { id = id, cmd = cmd, zh = w[1], en = w[2], at = now() }
    end
end

-- 以后台模式启动联机窗口。v0.23.0 起 exe 叫 PBZLobby.exe（以前叫 PBZ联机.exe：os.execute 走 ANSI 代码页，中文名传不过去，
-- 只能让 cmd 展开 PBZ*.exe 通配符；那样新旧两个 exe 都在时会都被拉起来，所以改成英文名、按全名启动）
-- §122 先试 pbz_lobby.dll：联机程序编成原生 DLL、在游戏进程里跑（不再多一个后台进程）。package.loadlib 拿它导出的
-- pbz_lobby_start 调一次：它只起一个后台线程（已经在跑就什么也不做），不碰 lua_State。没有这个 DLL / 载不进来 /
-- 连着 2 次拉起后还没响应，退回启动 PBZLobby.exe（两者用同一个 net 目录的单实例锁，不会同时跑两份）
local function netuiLaunchDll()
    if NETUI.dllOff then return false end     -- §153 第二份也用 DLL（DLL 自己判断用 net2）
    local dll = (ROOT .. "/pbz_lobby.dll"):gsub("/", "\\")
    local f = io.open(dll, "rb")
    if not f then NETUI.dllOff = true; return false end
    f:close()
    if type(package) ~= "table" or type(package.loadlib) ~= "function" then
        NETUI.dllOff = true
        out("!! 联机面板：这个 UE4SS 的 Lua 没有 package.loadlib，改用 PBZLobby.exe")
        return false
    end
    NETUI.dllTries = (NETUI.dllTries or 0) + 1
    if NETUI.dllTries > 2 then
        NETUI.dllOff = true
        out("!! 联机面板：pbz_lobby.dll 拉起 2 次都没响应，改用 PBZLobby.exe（原因看 net/lobby_errors.log）")
        return false
    end
    local fn, err = package.loadlib(dll, "pbz_lobby_start")
    if type(fn) ~= "function" then
        NETUI.dllOff = true
        out("!! 联机面板：载入 %s 失败 %s，改用 PBZLobby.exe", dll, tostring(err))
        return false
    end
    local ok, e = pcall(fn)
    out("联机面板：启动联机程序（游戏进程内）%s -> %s %s", dll, ok and "已执行" or "失败", tostring(e or ""))
    if not ok then NETUI.dllOff = true; return false end
    return true
end

local function netuiLaunch()
    NETUI.launchAt = os.time()
    NETUI.launchErr = nil
    if netuiLaunchDll() then return end
    if type(os) ~= "table" or type(os.execute) ~= "function" then
        NETUI.launchErr = "no os.execute"
        out("!! 联机面板：这个 UE4SS 的 Lua 没有 os.execute，请手动打开 PBZLobby.exe")
        return
    end
    local dir = ROOT:gsub("/", "\\")
    local cmd = string.format('cmd /c start "" "%s\\PBZLobby.exe" --bg', dir)
    if INST.slot == 2 then cmd = cmd .. string.format(' --dir "%s"', NET_DIR:gsub("/", "\\")) end     -- §151
    local ok, r = pcall(os.execute, cmd)
    NETUI.launchErr = (not ok) and tostring(r) or nil
    out("联机面板：启动联机窗口 %s -> %s %s", cmd, ok and "已执行" or "失败", tostring(r))
end

-- 刚拉起、还在等它写 lobby.txt（8 秒内）
local function netuiStarting()
    return NETUI.launchAt ~= nil and os.time() - NETUI.launchAt < 8 and not NETUI.launchErr
end

-- 联机程序没响应就自动拉起（模组加载时、打开面板时）。10 秒内不重复拉；连续失败 NETUI_AUTO_TRIES 次后不再自动拉
local function netuiEnsure(why, tn)
    if lobbyAlive(netuiRead(tn, true)) then NETUI.tries = 0; NETUI.dllTries = 0; return end
    if NETUI.launchAt and os.time() - NETUI.launchAt < 10 then return end
    if NETUI.tries >= NETUI_AUTO_TRIES then return end
    NETUI.tries = NETUI.tries + 1
    out("联机面板：联机程序没运行（%s），自动启动第 %d 次", why, NETUI.tries)
    netuiLaunch()
end

-- §99 管道断开（联机程序退出 / 崩了）4 秒后还没连回来就自动拉起，不等玩家打开面板。
-- 2026-11-05 19:56 内测：联机窗口点 × 退出后 4 分多钟没有联机程序，直到玩家在面板上手动点"重新启动联机程序"。
-- 每次断开算新的一轮（次数清零）；10 秒内不重复拉、连续 NETUI_AUTO_TRIES 次的限制照旧在 netuiEnsure 里
function NETUI.watchPipe(tn)
    if not PIPE.lostAt then return end
    if PIPE.on then PIPE.lostAt = nil; return end
    if os.time() - PIPE.lostAt < 4 then return end
    PIPE.lostAt, NETUI.tries = nil, 0
    netuiEnsure("管道断开", tn)
end

-- 当前显示的连接方式：刚在面板上换过、窗口还没跟上（2 秒内）时以面板的选择为准，连按左右才不会从旧值算
local function netuiMode(lb, tn)
    local w = NETUI.want
    if w and lb.mode ~= w.mode and tn - w.at < 2.0 then return w.mode end
    NETUI.want = nil
    return lb.mode or "lan"
end

-- ---- v0.18.6 游戏内输入框（用户 2026-11-04："所有操作都可以在游戏内实现"）：输入地址 / 昵称 / 端口不再弹联机窗口。
-- UMG 的 EditableTextBox 放在屏幕文字的界面里；输入时 SetInputMode_UIOnlyEx，键盘只给输入框（游戏收不到，角色不动、Esc 不开菜单）。
-- 18:28 实机原型：打字 / Ctrl+V 正常；按回车后输入框丢焦点、而且读出来的字已经被清空 → 打字时每帧把内容记在 e.text，
-- 回车（UE4SS 键位，见文件末尾）用记下的内容提交；Esc 取消。切出窗口回来焦点会丢：丢焦点 0.3 秒内没等到回车就把焦点拿回来
local WBL = "/Script/UMG.Default__WidgetBlueprintLibrary"

-- v0.29.3 输入框字色（用户 2026-11-07 截图：打字时字是浅灰、看不清）。SetForegroundColor 只改没焦点时的字色，
-- 打字时输入框有焦点，用的是 WidgetStyle.FocusedForegroundColor（引擎默认浅灰）→ 三种状态和 TextStyle 都写成深色。
-- 要在输入框加进界面（建出 Slate 控件）之前写样式；之后再 SetForegroundColor 一次兜底
local EB_DARK = { R = 0.05, G = 0.05, B = 0.05, A = 1.0 }
local function ebStyle(eb)
    local ok, err = pcall(function()
        local st = eb.WidgetStyle
        for _, k in ipairs({ "ForegroundColor", "FocusedForegroundColor", "ReadOnlyForegroundColor" }) do
            st[k] = { SpecifiedColor = EB_DARK, ColorUseRule = 0 }
        end
        st.TextStyle.ColorAndOpacity = { SpecifiedColor = EB_DARK, ColorUseRule = 0 }
    end)
    if not ok then out("!! 输入框字色样式改不了：%s", tostring(err)) end
end
local function ebColor(eb)
    pcall(function() eb:SetForegroundColor(EB_DARK) end)
end

-- v0.20.0 鼠标面板（用户 2026-11-04："mod 还是 TUI 用起来很不好用，能做成 GUI 么"，选了"游戏内鼠标面板"）。
-- 面板开着时放出鼠标（bShowMouseCursor + SetInputMode_UIOnlyEx，Phantom Pact 的面板也是这么放鼠标的），
-- 每行是真的 UMG Button，连接方式是一排标签页。UE4SS 的 Lua 绑不了按钮的 OnClicked 事件，所以每 33ms 查一次
-- IsHovered / IsPressed：上一次按着、这次松开且鼠标还在上面 = 点了一下。键盘 PgUp/PgDn/End 照样能用。
-- 建不起来（GUI.failed）就退回原来的文字面板。函数在 netuiRows 后面（guiShow 等），这里只放状态
local GUI = { on = false, failed = false }

-- v0.27.12 鼠标面板还是这张地图上建的那个（2026-11-05 19:05 崩溃：坐铃切图后按 Home，把旧地图的面板控件交给
-- SetInputMode_UIOnlyEx，引擎对失效控件 TakeWidget 崩了，HANDOVER §93）。换过地图就不碰 GUI.w，只丢掉引用，guiRoot 重建
GUI.fresh = function()
    return GUI.w ~= nil and GUI.gen == ST.mapLoads and valid(GUI.w)
end
GUI.drop = function()
    GUI.w, GUI.on, GUI.shownVis, GUI.pc = nil, false, nil, nil
    if NETUI.box and NETUI.box.gui then NETUI.box = nil end
end

local function editBox()
    if HUD.failed then return nil end
    if GUI.on and GUI.fresh() and valid(GUI.eb) then     -- 鼠标面板里自带输入框
        local b = NETUI.box
        if not (b and b.eb == GUI.eb) then NETUI.box = { eb = GUI.eb, w = GUI.w, gui = true } end
        return NETUI.box
    end
    local b = NETUI.box
    if b and b.w == HUD.w and HUD.gen == ST.mapLoads and valid(HUD.w) and valid(b.eb) then return b end
    local cv = umgRoot()
    if not cv then return nil end
    local ok, r = pcall(function()
        local eb = StaticConstructObject(StaticFindObject("/Script/UMG.EditableTextBox"), HUD.w.WidgetTree)
        ebStyle(eb)
        local sl = cv:AddChildToCanvas(eb)
        sl:SetAnchors({ Minimum = { X = 0.5, Y = HUD_Y }, Maximum = { X = 0.5, Y = HUD_Y } })
        sl:SetAlignment({ X = 0.5, Y = 0.5 })
        sl:SetSize({ X = 460, Y = 44 })
        ebColor(eb)   -- 18:45 实测默认字色太浅
        eb:SetVisibility(1)
        return { eb = eb, sl = sl, w = HUD.w }
    end)
    if not ok then out("!! 输入框建不起来：%s", tostring(r)); return nil end
    NETUI.box = r
    return r
end

local function inputMode(ui)
    local okP, pc = pcall(getP1PC)
    if not (okP and valid(pc)) then return end
    -- 鼠标面板开着：不在输入时也是 UIOnly（游戏收不到键盘鼠标，角色不动），并显示鼠标
    -- v0.27.12 面板是旧地图的：先丢掉、这次按没有面板处理（只给游戏），下一轮 guiShow → guiRoot 重建后再放鼠标（§93）
    if GUI.on and not GUI.fresh() then out("鼠标面板：地图换过了，旧面板不用，重建"); GUI.drop() end
    local mouse = (NETUI.open and GUI.on) and true or false
    local ok, err = pcall(function()
        local lib = StaticFindObject(WBL)
        if ui then
            if not (NETUI.box and valid(NETUI.box.eb)) then error("输入框没了") end
            lib:SetInputMode_UIOnlyEx(pc, NETUI.box.eb, 0, false); NETUI.box.eb:SetKeyboardFocus()
        elseif mouse then lib:SetInputMode_UIOnlyEx(pc, GUI.focusable and GUI.w or nil, 0, false)
        else lib:SetInputMode_GameOnly(pc, false) end
        pc.bShowMouseCursor = mouse
    end)
    GUI.lostAt = nil            -- v0.26.4 guiMouseTick：重新开始数"面板丢焦点"
    if not ok then out("!! 切换输入模式失败：%s", tostring(err)) end
end

local function editEnd(why)
    if not NETUI.edit then return end
    out("联机面板：输入框关闭（%s）", why)
    local kind = NETUI.edit.kind
    NETUI.edit = nil
    if NETUI.box and valid(NETUI.box.eb) then pcall(function() NETUI.box.eb:SetVisibility(1) end) end
    inputMode(false)
    -- §112 按 Delete 开的聊天：发完 / 取消就把顺带打开的面板关上（netuiSetOpen 是后面定义的 local，这里只能经 CHAT 表调）
    if kind == "chat" and CHAT and CHAT.autoClose then CHAT.autoClose = nil; CHAT.close(why) end
end

-- kind = join / name / port。没有 UMG 时只能退回打开电脑上的联机窗口。
-- 不预填当前值（18:45 实测：预填后打字会接在后面，SelectAllTextWhenFocused 不生效），当前值放在灰色提示文字里
local function editStart(kind, prompt, init, hint)
    local b = editBox()
    if not b then out("联机面板：没有游戏内输入框，改为打开联机窗口"); netuiCmd("show"); return end
    local ok, err = pcall(function()
        b.eb:SetText(FText(init or ""))
        b.eb:SetHintText(FText(hint or ""))
        b.eb:SetVisibility(0)             -- Visible：能接收键盘
    end)
    if not ok then out("!! 输入框打不开：%s", tostring(err)); netuiCmd("show"); return end
    pcall(function() b.eb:SetIsPassword(kind == "secret") end)       -- v0.22.0 输密码时显示成圆点（同一个输入框，别的项要关掉）
    NETUI.edit = { kind = kind, prompt = prompt, text = init or "", lostAt = nil }
    inputMode(true)
    out("联机面板：输入框打开（%s）", kind)
end

local function editCommit()
    local e = NETUI.edit
    if not e then return end
    local s = (e.text or ""):gsub("[\r\n|]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    editEnd("回车")
    if s == "" then return end
    if e.kind == "chat" then             -- §112（CHAT.add 自己记日志）；§150 只输一个数字 = 第几句快捷短语
        local n = tonumber(s:match("^[1-9]$") or "")
        if n then CHAT.sendPhrase(n) else CHAT.send(s) end
        return
    end
    out("联机面板：输入「%s」→ %s", e.kind == "secret" and "***" or s, e.kind)   -- 密码不进日志
    if e.kind == "join" then NETUI.sel = 1; netuiCmd("join", "target=" .. s .. "\n")
    elseif e.kind == "name" then netuiCmd("name", "name=" .. s .. "\n")
    elseif e.kind == "port" then netuiCmd("port", "port=" .. s .. "\n")
    elseif e.kind == "server" then netuiCmd("server", "server=" .. s .. "\n")
    elseif e.kind == "secret" then netuiCmd("secret", "secret=" .. (s == "-" and "" or s) .. "\n")
    elseif e.kind == "rnote" then OPP.note = s == "-" and "" or s:sub(1, 360) end     -- §174 举报附言（发的时候联机程序再截到 120 字）
end

-- 每帧（netuiRows）：有焦点时记下内容；丢了焦点等 0.3 秒回车，没等到就拿回焦点
local function editTick()
    local e, b = NETUI.edit, NETUI.box
    if not e then return end
    if not (b and valid(b.eb)) then editEnd("输入框没了"); return end
    local y = (not b.gui) and HUD.rowY and HUD.rowY[3]
    if y and y ~= b.y then b.y = y; pcall(function() b.sl:SetPosition({ X = 0.0, Y = y }) end) end
    local okF, focus = pcall(function() return b.eb:HasKeyboardFocus() end)
    if okF and focus then
        e.lostAt = nil
        local okT, s = pcall(function() return b.eb:GetText():ToString() end)
        if okT and type(s) == "string" then e.text = s end
        return
    end
    local t = now()             -- 墙钟（os.clock 是 CPU 时间，多线程下跑得快）
    if not e.lostAt then e.lostAt = t
    elseif t - e.lostAt > 0.3 then e.lostAt = nil; inputMode(true) end
end

local function netuiFlash(s, col)
    NETUI.flash = { text = s, till = os.time() + 3, col = col }
end

-- §91 每帧（netuiRows）：联机程序回了这条命令（ack）→ 结束等待；超时 → 红字提示
function NETUI.busyStep(lb, tn)
    local b = NETUI.busy
    if not b then return end
    if tn < b.at then b.at = tn end                  -- now() 的时间基准变了（见 netuiRead）
    if lb and lb.ack == b.id then
        NETUI.busy = nil
        out("联机面板：%s 已执行（等了 %d ms）", b.cmd, math.floor((tn - b.at) * 1000 + 0.5))
    elseif tn - b.at > NETUI.BUSY_SEC then
        NETUI.busy = nil
        out("!! 联机面板：%s 等了 %.0f 秒联机程序没回话", b.cmd, NETUI.BUSY_SEC)
        netuiFlash(T("联机程序没回应，再点一次试试", "THE ONLINE HELPER DID NOT ANSWER, TRY AGAIN"), COL_RED)
    end
end

-- §117 房间列表的显示名（用户 2026-11-06）：联机程序给的"地图 PBZ_DengDingShanDao_WP"换成游戏里的大区域名（pbz_places 里没有的照旧）；
-- 已满的房间把末尾的"已满"（长名字会被截掉看不到）挪到最前面做标记。排序（可加入的在前）在 netuiTargets 里
local function roomLabel(kind, label)
    label = label:gsub("(" .. T("地图 ", "map ") .. ")(%S+)", function(pre, lv)
        local r = MAPGO.PLACES and MAPGO.PLACES.regions[string.lower(lv)]
        return pre .. (r and T(r[1], r[2]) or lv)
    end)
    if kind == "full" or kind == "watch" then     -- §141 watch = 满了但能观战
        label = T("[已满] ", "[FULL] ") .. label:gsub(T("  已满", "  full"), "", 1)
    end
    return label
end

-- 能点"加入"的房间：kind = full（已满的房间）、watch（§141 满了、能观战）和 nohost（§123 在玩但没开房的 Steam 好友）列出来但不算"可加入"
local function roomOpen(t) return t.kind ~= "full" and t.kind ~= "nohost" and t.kind ~= "watch" and t.kind ~= "watchf" end

-- lobby.txt 里的加入目标分两类：剪贴板 / 最近（快捷加入，放主页）和房间（局域网房间、开房的 Steam 好友、服务器 / Steam 大厅的房间、
-- Tailscale 节点，放房间列表页）。kind = full 是已满的房间（v0.19.1 起联机程序单独标），列出来但选不中
local function netuiTargets(lb)
    local quick, rooms = {}, {}
    for i = 1, tonumber(lb.n) or 0 do
        local kind, label, target = (lb["t" .. i] or ""):match("^(%w+)|([^|]*)|(.*)$")
        if kind then
            local t = { kind = kind, label = label, target = target }
            if kind == "clip" or kind == "recent" then quick[#quick + 1] = t else
                t.label = roomLabel(kind, label)
                rooms[#rooms + 1] = t
            end
        end
    end
    -- 固定顺序：可加入的在前，再按显示名、target 排。20:32 实测大厅服务器每次给的顺序都不一样，
    -- 列表每 2 秒刷新一次就整个打乱，光标下的房间会突然换成另一个（按 End 可能进错房间）
    table.sort(rooms, function(a, b)
        local oa, ob = roomOpen(a), roomOpen(b)
        if oa ~= ob then return oa end
        if a.label ~= b.label then return a.label < b.label end
        return a.target < b.target
    end)
    return quick, rooms
end

-- inList = 房间列表页：不加"加入"前缀，多留几个字给末尾的房间号
local function joinItem(t, inList)
    if t.kind == "full" then return { label = clipText(t.label, 40), target = t.target } end   -- 已满：说明行（灰、跳过）
    -- §141 满了、主机认观战的局域网房间（联机程序标 watch）/ 开房的 Steam 好友（watchf）：点了以观战者身份连进去
    if t.kind == "watch" or t.kind == "watchf" then
        return { label = clipText(T("观战 ", "WATCH ") .. t.label, 40), target = t.target,
                 act = function() netuiCmd("spectate", "target=" .. t.target .. "\n") end }
    end
    if t.kind == "nohost" then     -- §123 没开房的好友：能点，但只提示，不发起注定超时的连接
        return { label = clipText(t.label, 40), target = t.target,
                 act = function() netuiFlash(T("对方还没开房", "THEY ARE NOT HOSTING YET"), COL_ORANGE) end }
    end
    return { label = inList and clipText(t.label, 40) or (T("加入 ", "JOIN ") .. clipText(t.label, 30)), target = t.target,
             act = function() netuiCmd("join", "target=" .. t.target .. "\n") end }
end

local function noRoomsText(mode)
    return mode == "steam" and T("（没有好友在开房）", "(NO FRIEND IS HOSTING)")
        or mode == "steamlobby" and T("（Steam 大厅里没有房间）", "(NO STEAM LOBBIES)")
        or mode == "server" and T("（大厅里没有房间）", "(NO ROOMS ON THE SERVER)")
        or mode == "ranked" and T("（还没有人开武林盟主房间）", "(NO RANKED ROOMS)")
        or T("（没发现房间）", "(NO ROOMS FOUND)")
end

-- §91 还在取第一份房间列表时说"正在获取"，别说"没有房间"：联机程序说还在取（listing=1，最多 10 秒），
-- 或者刚打开面板 / 进房间列表页 / 换连接方式 1.5 秒内（局域网房间每秒广播一次）
function NETUI.noRooms(lb, mode, tn)
    local age = tn - (NETUI.listFrom or -100)
    if age < 0 then NETUI.listFrom, age = tn, 0 end
    if age < 10 and (lb.listing == "1" or age < 1.5) then return T("（正在获取房间…）", "(LOOKING FOR ROOMS...)") end
    return noRoomsText(mode)
end

-- 进房间列表页：马上让联机程序重新问一次房间（服务器大厅 / Steam 大厅本来 2–3 秒问一次）
function NETUI.openRooms()
    NETUI.page, NETUI.sel, NETUI.roomPage, NETUI.listFrom = "rooms", 1, 1, now()
    netuiCmd("refresh")
end

-- 房间列表页一共几页（至少 1）
-- 每页几个房间：鼠标面板 GUI_PER_PAGE，文字面板 NETUI_PER_PAGE
local function perPage()
    return (GUI.on and not GUI.failed) and GUI_PER_PAGE or NETUI_PER_PAGE
end

local function roomPages(rooms)
    return math.max(1, math.ceil(#rooms / perPage()))
end

-- ---- §110 武林盟主：排行榜页（NETUI.page = "rank"）和排位账号页（"rankkey"）。数据全是联机程序写的 lobby.txt：
--   rkme=<分数>|<名次>|<胜>|<负>|<称号>|<赛季>（名次 0 = 还没打过计分局）、rktop=<赛季>|<页>|<总页数>、rkn=<本页行数>、
--   rkt1..rkt10=<名次>|<昵称>|<分数>|<胜>|<负>|<称号>、rknote=上一局结果一句话、rkerr=错误提示（这几行的 | 是字段分隔）。
-- 打开 / 翻页时发 cmd=ranktop page=N（不等回话：数据到了列表自己换上，5 秒内页码对不上显示"正在获取"）
NETUI.RANK_WAIT = 5.0
function NETUI.rankMe(lb)
    local sc, rk, w, l, title, season = (lb.rkme or ""):match("^(%-?%d+)|(%d+)|(%d+)|(%d+)|([^|]*)|([^|]*)$")
    if not sc then return nil end
    return { score = tonumber(sc), rank = tonumber(rk), w = tonumber(w), l = tonumber(l), title = title, season = season }
end
function NETUI.rankTop(lb)       -- 赛季, 页, 总页数（还没有 = nil）
    local season, pg, pages = (lb.rktop or ""):match("^([^|]*)|(%d+)|(%d+)$")
    if not season then return nil end
    return season, tonumber(pg), math.max(1, tonumber(pages))
end
function NETUI.rankRows(lb)
    local rows = {}
    for i = 1, math.min(tonumber(lb.rkn) or 0, 10) do
        -- 昵称里万一带 |：昵称取中间贪心那段，后面四段从右往左认
        local rk, nick, sc, w, l, title = (lb["rkt" .. i] or ""):match("^(%d+)|(.*)|(%-?%d+)|(%d+)|(%d+)|([^|]*)$")
        if rk then
            -- 用户 2026-11-06"排行榜里能额外显示这个玩家使用率最高的武器么"：rkw<i> 和 rkt<i> 一一对应（空 = 还没有统计）
            rows[#rows + 1] = { rank = tonumber(rk), nick = nick, score = tonumber(sc), w = tonumber(w), l = tonumber(l), title = title,
                                wpn = lb["rkw" .. i] or "" }
        end
    end
    return rows
end
function NETUI.rankLine(r)
    return (r.title ~= "" and ("【" .. r.title .. "】") or "") .. clipText(r.nick, 16)
        .. string.format(T("  %d 分  %d 胜 %d 负", "  %d PTS  %dW %dL"), r.score, r.w, r.l)
        .. ((r.wpn or "") ~= "" and ("  · " .. clipText(r.wpn, 8)) or "")
end
function NETUI.openRank(pg)
    pg = math.max(1, pg or 1)
    NETUI.page, NETUI.rankWant = "rank", { pg = pg, at = now() }
    netuiCmd("ranktop", "page=" .. pg .. "\n")
end
-- 我的排位信息一行（主页 / 排行榜页都用）
function NETUI.rankMeItem(lb)
    local me = NETUI.rankMe(lb)
    if not me then return { label = T("还没连上排位服务器", "NOT CONNECTED TO THE RANKED SERVER YET"), col = COL_ORANGE } end
    local pos = me.rank > 0 and string.format(T("第 %d 名", "#%d"), me.rank) or T("还没打过计分局", "NO RANKED MATCH YET")
    return { label = (me.title ~= "" and ("【" .. me.title .. "】") or "")
                 .. string.format(T("我：%d 分  %s  %d 胜 %d 负  赛季 %s", "ME: %d PTS  %s  %dW %dL  SEASON %s"), me.score, pos, me.w, me.l, me.season)
                 -- §179.2 本赛季作废次数（lobby.txt 的 rkvoid，服务器 RME 第 10 段；0 / 旧服务端没有 = 不显示）。只显示、不扣分
                 .. ((tonumber(lb.rkvoid) or 0) > 0 and string.format(T("  作废 %d", "  VOID %d"), tonumber(lb.rkvoid)) or ""),
             col = me.title ~= "" and COL_LABEL or COL_WHITE }
end
-- 规则没到 / 上一局结果 / 错误：说明行（主页、排行榜页）
function NETUI.rankInfo(lb, items)
    if (lb.rkrules or "") == "" and lb.rkold ~= "1" then     -- §188 版本太旧：下面 rkerr 那行说要升级，不说"正在获取"
        items[#items + 1] = { label = T("（正在从服务器获取排位规则…拿到前不能开局）", "(GETTING THE RANKED RULES FROM THE SERVER...)"), col = COL_ORANGE }
    end
    if (lb.rknote or "") ~= "" then items[#items + 1] = { label = clipText(lb.rknote, 40), col = COL_GREEN } end
    if (lb.rkerr or "") ~= "" then items[#items + 1] = { label = clipText(lb.rkerr, 40), col = COL_RED } end
end
-- §129 主机开了 UPnP：显示联机程序给的结果（lobby.txt 的 upnp=，文案是联机程序按语言给的，这里不另拼）。
-- 正在请求橙、已转发绿、失败红；太长折成两行（先在句号处分开，让"请手动转发"单独一行；每行再长就截断），说明行不占光标。
-- 宽度按半角算（中文 2），鼠标面板一行大约放 46 个半角
NETUI.UPNP_W = 44
-- 宽度 w 以内能放下的字节数，以及其中最后一个能折行的位置（优先 ，, ；之后，其次空格之后；太靠前的不算）
local function upnpFit(s, w)
    local x, last, punct, space = 0, 0, nil, nil
    for p, c in utf8.codes(s) do
        x = x + (c >= 0x1100 and 2 or 1)
        if x > w then return last, punct or space end
        last = p + #utf8.char(c) - 1
        if x > w // 3 then
            if c == 0xFF0C or c == 0x2C or c == 0xFF1B then punct = last elseif c == 0x20 then space = last end
        end
    end
    return #s, nil
end
local function upnpClip(s, w)
    local n = upnpFit(s, w)
    return n >= #s and s or s:sub(1, upnpFit(s, w - 2)) .. ".."
end
function NETUI.upnpInfo(lb, items)
    local s = lb.upnp or ""
    if lb.role ~= "host" or lb.upnpon ~= "1" or s == "" then return end
    local col = (s:find("失败", 1, true) or s:find("failed", 1, true)) and COL_RED
             or (s:find("正在", 1, true) or s:find("asking", 1, true)) and COL_ORANGE or COL_GREEN
    local w = NETUI.UPNP_W
    -- 折成最多 max 行：在逗号 / 空格处折，都没有就硬切；最后一行还放不下就截断
    local function wrap(t, max)
        while t ~= "" and max > 0 do
            local n, brk = upnpFit(t, w)
            if n >= #t then items[#items + 1] = { label = t, col = col }; return end
            if max == 1 then items[#items + 1] = { label = upnpClip(t, w), col = col }; return end
            local cut = brk or n
            items[#items + 1] = { label = (t:sub(1, cut):gsub("%s+$", "")), col = col }
            t, max = t:sub(cut + 1):gsub("^%s+", ""), max - 1
        end
    end
    -- 有句号就在句号处分（失败时第二句是"请手动转发"，单独一行）：前一句最多两行、后一句一行；没有句号就整句最多两行
    local p = s:find("。", 1, true) or s:find(". ", 1, true)
    if p then
        local cut = s:sub(p, p) == "." and p or p + 2
        wrap(s:sub(1, cut), 2)
        wrap((s:sub(cut + 1):gsub("^%s+", "")), 1)
    else
        wrap(s, 2)
    end
end
-- 排行榜页的行。文字面板（屏幕文字最多 HUD_ROWS 行）两个人挤一行，鼠标面板一人一行
function NETUI.rankItems(lb, tn, items, toPage)
    items[#items + 1] = NETUI.rankMeItem(lb)
    NETUI.rankInfo(lb, items)
    local want = NETUI.rankWant or { pg = 1, at = -100 }
    if tn < want.at then want.at = tn end
    local season, pg, pages = NETUI.rankTop(lb)
    local rows = season and NETUI.rankRows(lb) or {}
    local myRank = (NETUI.rankMe(lb) or {}).rank
    if not season or (pg ~= want.pg and tn - want.at < NETUI.RANK_WAIT) then
        items[#items + 1] = { label = T("（正在获取排行榜…）", "(LOADING THE LEADERBOARD...)") }
    elseif #rows == 0 then
        items[#items + 1] = { label = T("（这个赛季还没有人上榜）", "(NOBODY ON THE BOARD THIS SEASON YET)") }
    else
        local gui = GUI.on and not GUI.failed
        local i = 1
        while i <= #rows do
            local r, r2 = rows[i], (not gui) and rows[i + 1] or nil
            local line = string.format("%2d. ", r.rank) .. NETUI.rankLine(r)
            if r2 then line = line .. "    " .. string.format("%2d. ", r2.rank) .. NETUI.rankLine(r2) end
            local titled = r.title ~= "" or (r2 and r2.title ~= "")
            local mine = myRank and myRank > 0 and (r.rank == myRank or (r2 and r2.rank == myRank))
            items[#items + 1] = { label = line, col = titled and COL_LABEL or mine and COL_GREEN or COL_WHITE }
            i = i + (r2 and 2 or 1)
        end
    end
    pg, pages = pg or want.pg, pages or 1
    NETUI.rankShown = { season = season, pg = pg, pages = pages }
    items[#items + 1] = { label = T("排位账号（导出 / 导入密钥）…", "RANKED ACCOUNT (EXPORT / IMPORT KEY)..."), act = toPage("rankkey") }
    if pg < pages then
        items[#items + 1] = { label = T("下一页", "NEXT PAGE"), nav = "next", act = function() NETUI.openRank(pg + 1); NETUI.sel = 1 end }
    end
    if pg > 1 then
        items[#items + 1] = { label = T("上一页", "PREVIOUS PAGE"), nav = "prev", act = function() NETUI.openRank(pg - 1); NETUI.sel = 1 end }
    end
    items[#items + 1] = { label = T("返回", "BACK"), nav = "back", act = toPage("main") }
end
-- 排位账号页：本机随机密钥 = 排位身份（net/rank_key.txt，联机程序管）。导入会换成剪贴板里的账号，要 3 秒内点两次
function NETUI.rankKeyItems(lb, tn, items, toPage)
    items[#items + 1] = { label = T("排位身份是本机的一串随机密钥（不用 Steam）。换电脑：这边导出，那边导入", "YOUR RANKED ID IS A RANDOM KEY ON THIS PC. EXPORT HERE, IMPORT ON THE NEW PC") }
    items[#items + 1] = { label = T("密钥等于账号，别发给别人", "THE KEY IS YOUR ACCOUNT - DON'T SHARE IT"), col = COL_ORANGE }
    items[#items + 1] = { label = T("导出密钥（复制到剪贴板）", "EXPORT KEY (COPY TO CLIPBOARD)"),
                          act = function()
                              netuiCmd("rankexport")
                              netuiFlash(T("排位密钥已复制到剪贴板", "RANKED KEY COPIED TO THE CLIPBOARD"))
                          end }
    local armed = NETUI.rkImportArm and tn - NETUI.rkImportArm <= 3 and tn >= NETUI.rkImportArm
    items[#items + 1] = { label = armed and T("再点一次：确定用剪贴板里的密钥（换账号）", "CLICK AGAIN TO SWITCH TO THE KEY IN THE CLIPBOARD")
                                      or T("从剪贴板导入密钥…", "IMPORT KEY FROM CLIPBOARD..."),
                          act = function()
                              local t = now()
                              if not (NETUI.rkImportArm and t - NETUI.rkImportArm <= 3 and t >= NETUI.rkImportArm) then
                                  NETUI.rkImportArm = t
                                  netuiFlash(T("会换成剪贴板里的账号，3 秒内再点一次确定", "THIS SWITCHES ACCOUNTS - CLICK AGAIN WITHIN 3 S"), COL_ORANGE)
                                  return
                              end
                              NETUI.rkImportArm = nil
                              netuiCmd("rankimport")
                              netuiFlash(T("已让联机程序从剪贴板导入密钥", "IMPORTING THE KEY FROM THE CLIPBOARD"))
                          end }
    if (lb.rkerr or "") ~= "" then items[#items + 1] = { label = clipText(lb.rkerr, 40), col = COL_RED } end
    items[#items + 1] = { label = T("返回", "BACK"), act = function() NETUI.openRank((NETUI.rankShown or {}).pg or 1) end }
end
-- §175 武林盟主规则说明页（NETUI.page = "rankrules"，用户：内测反馈"加分减分机制不明确"）。内容按服务端 pbz-ranked.mjs 写的
-- （Elo K=32 起始 1000、两边上报对上才记、同一对人每天前 3 场、满 5 场的第一名是盟主、按月换赛季），服务端改了这里要跟着改；
-- 固定规则那页按服务器发的 RRULES（NET.rkRules()）现拼。每页最多 NETUI.RULES_LINES 行（文字面板还要放标题 / 状态 / 翻页 / 说明）
NETUI.RULES_LINES = 11
function NETUI.rulesPages(r)
    local function onOff(v) return v == 1 and { "开", "ON" } or { "关", "OFF" } end
    local fixed
    if r then
        local acc = ({ [0] = { "各自原样", "AS EQUIPPED" }, { "一律未强化", "ALL UNREFINED" }, { "一律强化满", "ALL FULLY REFINED" }, { "失效", "DISABLED" } })[r.acc]
                    or { "?", "?" }
        fixed = {
            { string.format("%d 局 %d 胜；伤害 %d%%", r.bo, r.bo // 2 + 1, r.dm), string.format("BEST OF %d; DAMAGE %d%%", r.bo, r.dm) },
            { "血瓶：" .. (r.med == 1 and "能用" or "禁用"), "HEALING POTIONS: " .. (r.med == 1 and "ALLOWED" or "BANNED") },
            { "标准数值：" .. onOff(r.std)[1] .. (r.std == 1 and "（属性统一，不看养成）" or ""),
              "STANDARD STATS: " .. onOff(r.std)[2] .. (r.std == 1 and " (SAME STATS FOR ALL)" or "") },
            { "饰品：" .. acc[1] .. ((r.accn or 6) < 6 and ("，只生效前 " .. r.accn .. " 件") or ""),
              "ACCESSORIES: " .. acc[2] .. ((r.accn or 6) < 6 and (", FIRST " .. r.accn .. " ONLY") or "") },
            { "禁用饰品：" .. ACC.banText(NET.rkAccBan(), 1), "BANNED ACCESSORIES: " .. ACC.banText(NET.rkAccBan(), 2) },   -- §176 / §179.4 服务器 accban=（没发 = 默认名单）
            { "武器平衡：" .. onOff(r.bal)[1] .. "；红蓝光反击：" .. onOff(r.ctr)[1], "WEAPON BALANCE: " .. onOff(r.bal)[2] .. "; COUNTERS: " .. onOff(r.ctr)[2] },
            { "全部可格挡：" .. onOff(r.ab)[1] .. "；对手位置严格跟随：" .. onOff(r.npos)[1], "ALL BLOCKABLE: " .. onOff(r.ab)[2] .. "; STRICT POSITION: " .. onOff(r.npos)[2] },
            { string.format("精纯杀气获取 %d%%，开局精纯杀气 %d", r.ultx, r.ult0), string.format("ULTIMATE GAIN %d%%, START WITH %d", r.ultx, r.ult0) },
            { string.format("开局暗源 %d，", r.sp0) .. (r.resm == 1 and "每局重置" or "每场只给一次"),
              string.format("START WITH %d EDGE CHARGES, ", r.sp0) .. (r.resm == 1 and "EVERY ROUND" or "ONCE PER MATCH") },
            { (r.tl or 0) > 0 and string.format("每局限时 %d 秒，到时受伤多的判负", r.tl) or "每局不限时",
              (r.tl or 0) > 0 and string.format("%ds PER ROUND; MORE DAMAGE TAKEN LOSES", r.tl) or "NO ROUND TIME LIMIT" },   -- §173
            { "自己的房间设置在武林盟主里不起作用", "YOUR OWN ROOM RULES DON'T APPLY HERE" },
        }
        for _, k in ipairs(WBAN.KINDS) do     -- §180 服务器 rkrules 发了 wpnban= / edgeban= 才有这行（没发 = 不禁）
            local b, kn = WBAN.rkOf(k), WBAN.KIND_NAME[k]
            if b ~= "-" then table.insert(fixed, #fixed, { "禁用" .. kn[1] .. "：" .. WBAN.text(k, b, 1), "BANNED " .. kn[2] .. "S: " .. WBAN.text(k, b, 2) }) end
        end
    else
        fixed = { { "（正在从服务器获取规则…）", "(GETTING THE RULES FROM THE SERVER...)" } }
    end
    return {
        { title = { "怎么加减分", "HOW RATING CHANGES" }, lines = {
            { "新账号 1000 分。一场 = 3 局 2 胜，打完记一次", "NEW ACCOUNTS START AT 1000. RATED ONCE PER MATCH" },
            { "用 Elo 算（K = 32）：赢家加的 = 输家扣的", "ELO, K = 32: THE WINNER GAINS WHAT THE LOSER LOSES" },
            { "加减多少只看两人赛前的分差：", "THE AMOUNT DEPENDS ONLY ON THE RATING GAP:" },
            { "  同分：赢 +16 / 输 -16", "  EVEN: WIN +16 / LOSE -16" },
            { "  对手高 100：赢 +20 / 输 -12", "  OPPONENT 100 HIGHER: WIN +20 / LOSE -12" },
            { "  对手高 200：赢 +24 / 输 -8", "  OPPONENT 200 HIGHER: WIN +24 / LOSE -8" },
            { "  对手低 100：赢 +12 / 输 -20", "  OPPONENT 100 LOWER: WIN +12 / LOSE -20" },
            { "  对手低 200：赢 +8 / 输 -24", "  OPPONENT 200 LOWER: WIN +8 / LOSE -24" },
            { "  差 400 以上：赢低分的只 +3 左右", "  400+ APART: BEATING THE LOWER ONE IS ~+3" },
            { "2:0 和 2:1 一样；没有连胜加成", "2-0 AND 2-1 COUNT THE SAME; NO STREAK BONUS" },
        } },
        { title = { "什么时候记分", "WHEN A MATCH COUNTS" }, lines = {
            { "两边各自向服务器报胜负，对得上才记", "BOTH SIDES REPORT; RATED ONLY IF THEY AGREE" },
            { "两边都说自己赢 → 作废，不加不减", "BOTH CLAIM THE WIN -> VOID, NO CHANGE" },
            { "倒计时开始就算开场。之后认输、退出、", "THE MATCH STARTS AT THE COUNTDOWN. AFTER THAT," },
            { "  断开联机 = 这场输", "  SURRENDER / LEAVE / DISCONNECT = LOSS" },
            { "联机断了：两边都报赢，服务器看", "LINK LOST: BOTH REPORT A WIN; WHOEVER'S" },
            { "  谁的心跳先停（早 3 秒以上）谁输；", "  HEARTBEAT STOPPED 3+ S EARLIER LOSES;" },
            { "  分不出看断线时比分：领先的赢，平分作废", "  ELSE THE SCORE AT THE DROP: LEADER WINS, TIE = VOID" },
            { "客机会复核主机的判定，对不上只记录、积分照常", "THE GUEST CHECKS THE HOST'S CALLS; DISPUTES ARE LOGGED" },
            { "对方直接关游戏没报：等 3 分钟按你报的算", "OPPONENT NEVER REPORTS: YOURS COUNTS AFTER 3 MIN" },
            { "同一对人每天（北京时间）只记前 3 场，", "SAME TWO PLAYERS: ONLY 3 RATED MATCHES A DAY" },
            { "  之后照打不计分", "  (BEIJING TIME); MORE ARE UNRATED" },
        } },
        { title = { "排行榜、盟主、赛季", "BOARD, CHAMPION, SEASONS" }, lines = {
            { "打过 1 场计分局就上榜：按分数排，", "1 RATED MATCH PUTS YOU ON THE BOARD: BY RATING," },
            { "  同分比胜场多、再比负场少", "  THEN MORE WINS, THEN FEWER LOSSES" },
            { "第一名且打满 5 场计分局 = 武林盟主：", "#1 WITH 5+ RATED MATCHES IS THE CHAMPION:" },
            { "  名字前加【武林盟主】，房间置顶", "  TITLE BEFORE THE NAME, ROOM LISTED FIRST" },
            { "第一名不满 5 场时暂时没有盟主（不让给第二）", "#1 UNDER 5 MATCHES: NO CHAMPION (NOT PASSED ON)" },
            { "每月 1 日（北京时间）换赛季：", "NEW SEASON ON THE 1ST (BEIJING TIME):" },
            { "  所有人回 1000 分、胜负清零，前三名进历届盟主", "  ALL BACK TO 1000, TOP 3 GO TO THE HALL OF FAME" },
            { "不计分 / 作废的局不算胜负，也不进统计", "UNRATED / VOID MATCHES DON'T COUNT ANYWHERE" },
            { "作废次数显示在\"我\"那一行（只显示、不扣分）", "YOUR VOID COUNT IS SHOWN (NO PENALTY)" },
            { "账号是本机密钥，换电脑去排位账号页导出 / 导入", "YOUR ACCOUNT IS A LOCAL KEY: EXPORT / IMPORT IT" },
        } },
        { title = { "固定规则（服务器定，所有人一样）", "FIXED RULES (SET BY THE SERVER)" }, lines = fixed },
    }
end
function NETUI.rulesItems(lb, tn, items, toPage)
    local pages = NETUI.rulesPages(NET.rkRules())
    local pg = math.min(math.max(1, NETUI.rulesPg or 1), #pages)
    local p = pages[pg]
    NETUI.rulesPg, NETUI.rulesShown = pg, { pg = pg, pages = #pages, title = p.title }
    for i = 1, math.min(#p.lines, NETUI.RULES_LINES) do
        local ln = p.lines[i]
        items[#items + 1] = { label = T(ln[1], ln[2]), col = COL_WHITE }
    end
    if pg < #pages then
        items[#items + 1] = { label = T("下一页", "NEXT PAGE"), nav = "next", act = function() NETUI.rulesPg = pg + 1; NETUI.sel = 1 end }
    end
    if pg > 1 then
        items[#items + 1] = { label = T("上一页", "PREVIOUS PAGE"), nav = "prev", act = function() NETUI.rulesPg = pg - 1; NETUI.sel = 1 end }
    end
    items[#items + 1] = { label = T("返回", "BACK"), nav = "back", act = toPage("main") }
end
-- §110 武林盟主：武器与招式统计页（NETUI.page = "rankstat"）。数据是联机程序写的 lobby.txt（只在 rk=1 时有）：
--   rkstat=<种类>|<赛季>|<页>|<总页数>|<本赛季计入的人次>（种类 w 武器 / e 影之武装 / m 招式；还没拿到 = 空）、rksn=<本页行数>、
--   rks1..rks10：w / e = <名字>|<用了几人次>|<使用率%>|<胜率%>；m = <招式名>|<放出次数>|<命中率%>|<被格挡%>|<平均伤害>（| 是字段分隔）。
-- 打开 / 换种类 / 翻页时发 cmd=rankstat kind=<w|e|m> page=N（同排行榜页：不等回话，5 秒内种类 / 页对不上显示"正在获取统计"）
NETUI.STAT_KINDS = { "w", "e", "m" }
NETUI.STAT_NAME = { w = { "武器", "WEAPONS" }, e = { "影之武装", "PHANTOM EDGES" }, m = { "招式", "MOVES" } }
function NETUI.statTop(lb)       -- { kind, season, pg, pages, n }（还没有 = nil）
    local k, season, pg, pages, n = (lb.rkstat or ""):match("^([wem])|([^|]*)|(%d+)|(%d+)|(%d+)$")
    if not k then return nil end
    return { kind = k, season = season, pg = tonumber(pg), pages = math.max(1, tonumber(pages)), n = tonumber(n) }
end
function NETUI.statRows(lb, kind)
    local rows = {}
    for i = 1, math.min(tonumber(lb.rksn) or 0, 10) do
        local s = lb["rks" .. i] or ""
        -- 名字里万一带 |：名字取前面贪心那段，后面的数字段从右往左认
        if kind == "m" then
            local name, cnt, hit, blk, dmg = s:match("^(.*)|(%d+)|([^|]*)|([^|]*)|([^|]*)$")
            if name then rows[#rows + 1] = { name = name, cnt = tonumber(cnt), hit = tonumber(hit), blk = tonumber(blk), dmg = tonumber(dmg) } end
        else
            local name, cnt, use, win = s:match("^(.*)|(%d+)|([^|]*)|([^|]*)$")
            if name then rows[#rows + 1] = { name = name, cnt = tonumber(cnt), use = tonumber(use), win = tonumber(win) } end
        end
    end
    return rows
end
-- 百分比 / 均伤：整数不带小数，否则一位小数；没给 = "-"
function NETUI.statNum(v)
    if not v then return "-" end
    return v == math.floor(v) and string.format("%d", v) or string.format("%.1f", v)
end
-- 一条统计：{ label, col }。武器 / 影之武装按胜率上色（≥ 50 绿、< 50 红），招式白
function NETUI.statLine(r, kind)
    local f = NETUI.statNum
    if kind == "m" then
        return { label = clipText(r.name, 18) .. string.format(T("  放出 %d  命中 %s%%  被格挡 %s%%  均伤 %s", "  USED %d  HIT %s%%  BLOCKED %s%%  AVG DMG %s"),
                                                             r.cnt, f(r.hit), f(r.blk), f(r.dmg)), col = COL_WHITE }
    end
    return { label = clipText(r.name, 14) .. string.format(T("  使用率 %s%%  胜率 %s%%（%d 人次）", "  USE %s%%  WIN %s%% (%d)"), f(r.use), f(r.win), r.cnt),
             col = not r.win and COL_WHITE or r.win >= 50 and COL_GREEN or COL_RED }
end
function NETUI.openStat(kind, pg)
    kind = NETUI.STAT_NAME[kind or ""] and kind or (NETUI.statWant or {}).kind or "w"
    pg = math.max(1, pg or 1)
    NETUI.page, NETUI.statWant = "rankstat", { kind = kind, pg = pg, at = now() }
    netuiCmd("rankstat", "kind=" .. kind .. "\npage=" .. pg .. "\n")
end
-- 统计页的行。第一行是种类（鼠标面板画成一排标签页 it.tabs，文字面板 End 换下一种）；文字面板屏幕文字最多 HUD_ROWS 行：
-- 赛季 / 人次那句并进种类行，一页 10 条一条一行
function NETUI.statItems(lb, tn, items, toPage)
    local gui = GUI.on and not GUI.failed
    local want = NETUI.statWant or { kind = "w", pg = 1, at = -100 }
    if tn < want.at then want.at = tn end
    local top = NETUI.statTop(lb)
    local waiting = not top or ((top.kind ~= want.kind or top.pg ~= want.pg) and tn - want.at < NETUI.RANK_WAIT)
    local shown = not waiting and top or nil
    local kind = shown and shown.kind or want.kind
    local tabs, names = {}, {}
    for i, k in ipairs(NETUI.STAT_KINDS) do
        local nm = T(NETUI.STAT_NAME[k][1], NETUI.STAT_NAME[k][2])
        tabs[i] = { label = nm, cur = k == kind, act = function() NETUI.openStat(k, 1); NETUI.sel = 1 end }
        names[i] = k == kind and ("[" .. nm .. "]") or nm
    end
    local head = shown and string.format(T("赛季 %s · 计入 %d 人次", "SEASON %s · %d ENTRIES"), shown.season, shown.n) or nil
    local nextKind = NETUI.STAT_KINDS[({ w = 1, e = 2, m = 3 })[kind] % 3 + 1]
    items[#items + 1] = { label = T("种类：", "SHOW: ") .. table.concat(names, " ") .. ((not gui and head) and ("  · " .. head) or ""),
                          tabs = tabs, act = function() NETUI.openStat(nextKind, 1) end }
    if gui and head then items[#items + 1] = { label = head, col = COL_LABEL } end
    local lines = 0
    if not shown then
        items[#items + 1] = { label = T("（正在获取统计…）", "(LOADING THE STATS...)") }; lines = 1
    else
        local rows = NETUI.statRows(lb, kind)
        if #rows == 0 then items[#items + 1] = { label = T("（这个赛季还没有数据）", "(NO DATA THIS SEASON YET)") }; lines = 1 end
        for _, r in ipairs(rows) do items[#items + 1] = NETUI.statLine(r, kind); lines = lines + 1 end
    end
    local pg, pages = shown and shown.pg or want.pg, shown and shown.pages or 1
    NETUI.statShown = { kind = kind, season = shown and shown.season, pg = pg, pages = pages }
    -- rkerr：鼠标面板总显示；文字面板放得下才显示（种类行 + 数据 + 翻页 / 返回，满 10 条时省掉）
    local navN = 1 + (pg < pages and 1 or 0) + (pg > 1 and 1 or 0)
    if (lb.rkerr or "") ~= "" and (gui or 1 + lines + navN + 1 <= HUD_ROWS - 3) then
        items[#items + 1] = { label = clipText(lb.rkerr, 40), col = COL_RED }
    end
    if pg < pages then
        items[#items + 1] = { label = T("下一页", "NEXT PAGE"), nav = "next", act = function() NETUI.openStat(kind, pg + 1); NETUI.sel = 1 end }
    end
    if pg > 1 then
        items[#items + 1] = { label = T("上一页", "PREVIOUS PAGE"), nav = "prev", act = function() NETUI.openStat(kind, pg - 1); NETUI.sel = 1 end }
    end
    items[#items + 1] = { label = T("返回", "BACK"), nav = "back", act = toPage("main") }
end

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
-- 饰品：{ 技能（精炼满级那一档）, 中文, 英文 }。只列挂技能的（AI 发 pas=，替身身上挂上这些被动）；纯加属性的饰品替身用不上
-- （替身的攻击属性照抄你的 att=）。防御类按替身在你游戏里实际掉的血生效（§115 td=：AI 按你本机打出的真实伤害扣血）；
-- 喝药类、慈母护符（§60 曾让人死不掉）不列：AI 的喝药是联机程序模拟的
AIL.ACCS = {
    { "BP_GA_Accessory_Bleed_Lv2_C", "雪与血", "SNOW & BLOOD" }, { "BP_GA_Accessory_Combo_Passive_Lv3_C", "碧血云天", "COMBO" },
    { "BP_GA_Accessory_Electrified_Passive_C", "月雷华灯", "ELECTRIFY" }, { "BP_GA_Accessory_EvadePhantom_Passive_Lv2_C", "影魅面具", "PHANTOM MASK" },
    { "BP_GA_Accessory_Ignite_Passive_C", "瑞狮火球", "IGNITE" }, { "BP_GA_Accessory_MartialWeapon_FreeShachi_Passive_Lv3_C", "粗糙煌心", "MARTIAL HEART" },
    { "BP_GA_Accessory_RangedWeapon_Passive_C", "无相神镜", "RANGED MIRROR" }, { "GA_Accessory_ActHit_Lv2_C", "影动猎杀仪", "ACT HIT" },
    { "GA_Accessory_AnimMovement_Lv2_C", "舞扇", "DANCING FAN" }, { "GA_Accessory_BigHit_Lv2_C", "绝望护符", "BIG HIT" },
    { "GA_Accessory_BreakAttack_Lv2_C", "追杀令", "BREAK ATTACK" }, { "GA_Accessory_Chaos_Lv3_C", "混沌狂戒", "CHAOS RING" },
    { "GA_Accessory_Counter_Lv2_C", "反击护腕", "COUNTER BRACER" }, { "GA_Accessory_Poison_Lv2_C", "猛毒袋", "POISON POUCH" },
    { "GA_Accessory_Ranged_Lv2_C", "神射之眼", "MARKSMAN'S EYE" }, { "GA_Accessory_ShachiWeapon_Lv3_C", "暗源方块", "SHADOW CUBE" },
    { "GA_Accessory_UltimateBreak_Lv2_C", "绝技护符", "ULTIMATE CHARM" }, { "GA_Accessory_TimerEndure_Lv2_C", "百战魔躯", "WAR-HARDENED" },
    { "GA_Accessory_SwitchEndure_Passive_C", "神奇刀鞘", "MAGIC SCABBARD" }, { "GA_Accessory_ResistRanged_Lv2_C", "避箭护符", "ARROWWARD CHARM" },
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
    items[#items + 1] = { label = T("（对战中改了下一招就用新的；药血掉到四成以下喝、回四成；房间设置关了血瓶就不喝）",
                                    "(CHANGES APPLY MID-FIGHT; DRINKS BELOW 40% HP; NOT WHEN POTIONS ARE OFF)") }
    items[#items + 1] = { label = T("返回", "BACK"), act = toPage("main") }
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
                 cli = NET.accBanOf, cfg = function() return NET.accBanCfg end, rk = function() return NET.ACCBAN_DEF end,
                 who = T("禁用饰品由主机设置", "THE HOST DECIDES THIS RULE"), click = banPage, view = banPage }
    elseif WBAN.LIST[k] then        -- §180 禁用武器 / 影之武装：同禁用饰品，点进勾选页
        local kn = WBAN.KIND_NAME[k]
        local function banPage() NETUI.page, NETUI.sel = k, 1 end
        return { lbl = function(v) return T("禁用" .. kn[1] .. "：", "BANNED " .. kn[2] .. "S: ") .. clipText(T(WBAN.text(k, v, 1), WBAN.text(k, v, 2)), 18) .. " >" end,
                 cli = function() return WBAN.of(k) end, cfg = function() return WBAN.cfg[k] end, rk = function() return WBAN.rkOf(k) end,
                 who = T("禁用" .. kn[1] .. "由主机设置", "THE HOST DECIDES THIS RULE"), click = banPage, view = banPage }
    end
end
-- 一行：武林盟主 = 服务器定的（点了只提示）；客机只看主机定的；主机 / 没联机点一下换下一档。没有这项 / 排位规则还没到 = nil
function NETUI.roomItem(k, lb)
    local s = roomSpec(k)
    if not s then return nil end
    if lb.rk == "1" and not s.noRk then     -- §110
        local rk = NET.rkRules()
        if not rk then return nil end
        return { label = s.lbl(s.rk(rk)),
                 act = s.view or function() netuiFlash(T("武林盟主的规则由服务器固定，不能改", "RANKED RULES ARE FIXED BY THE SERVER"), COL_ORANGE) end }
    end
    if lb.role == "client" then
        return { label = s.lbl(s.cli()) .. T("（主机设置）", " (HOST'S SETTING)"), act = s.view or function() netuiFlash(s.who) end }
    end
    return { label = s.lbl(s.cfg()) .. (s.tail or T("（主机设置，下一局生效）", " (HOST, NEXT MATCH)")), act = s.click }
end
-- §171 房间设置页：这三项放最上，其余按类折叠（一次只展开一类，展开最多的一类也不超出面板行数）。
-- npos（严格跟随）在系统设置页；没归类的新键自动进"其他"
NETUI.ROOM_TOP = { "std", "bal", "acc", "accn", "accban", "wpnban", "edgeban" }      -- §176 生效饰品数量 / 禁用饰品跟在饰品后面；§180 禁用武器 / 影之武装再往下
NETUI.ROOM_CATS = {
    { id = "match", zh = "对局", en = "MATCH", keys = { "bo", "dm", "bar", "tl", "cs" } },     -- §173 tl 回合时限；§181 cs 作弊数据采样
    { id = "combat", zh = "战斗规则", en = "COMBAT", keys = { "ab", "ctr", "med" } },
    { id = "res", zh = "开局资源", en = "STARTING RESOURCES", keys = { "ult0", "ultx", "sp0", "resm" } },
    { id = "spec", zh = "观战 / 排队", en = "SPECTATORS / QUEUE", spec = true },
}
NETUI.ROOM_ELSEWHERE = { npos = true }
-- §176 禁用饰品勾选页（NETUI.page = "accban"）：66 件按 STD.ACCESSORIES 顺序，每页 NETUI.ACCBAN_PER 件。
-- 主机 / 没联机点一下勾上 / 去掉（存 rules.txt，下一局生效）；客机看主机的、武林盟主看固定默认名单，点了只提示
NETUI.ACCBAN_PER, NETUI.accBanPage = 10, 1      -- 标题 + 10 件 + 翻页 / 默认 / 返回 = 14 行（文字面板放得下）
function NETUI.accBanItems(lb, items, toPage)
    local ranked, client = lb.rk == "1", lb.role == "client"
    local ro = ranked or client
    local cur = ACC.banSet(ro and NET.accBanOf() or NET.accBanCfg)
    local ids = STD.ACCESSORIES
    local pages = math.ceil(#ids / NETUI.ACCBAN_PER)
    NETUI.accBanPage = math.max(1, math.min(NETUI.accBanPage or 1, pages))
    local n = 0
    for _ in pairs(cur) do n = n + 1 end
    items[#items + 1] = { label = string.format(T("禁用饰品（勾上 = 对局中失效；已禁 %d 件）", "BANNED ACCESSORIES (CHECKED = NO EFFECT IN MATCHES; %d)"), n)
                                  .. (ranked and T("：武林盟主固定", ": RANKED, FIXED") or client and T("：主机设置", ": HOST'S SETTING") or T("：下一局生效", ": NEXT MATCH")),
                          col = COL_LABEL }
    local from = (NETUI.accBanPage - 1) * NETUI.ACCBAN_PER
    for i = from + 1, math.min(from + NETUI.ACCBAN_PER, #ids) do
        local id = ids[i]
        local nm = ACC.NAME[id] or { id, id }
        items[#items + 1] = { label = (cur[id] and "[x] " or "[  ] ") .. T(nm[1], nm[2]),
                              act = function()
                                  if ranked then netuiFlash(T("武林盟主的规则由服务器固定，不能改", "RANKED RULES ARE FIXED BY THE SERVER"), COL_ORANGE); return end
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
        items[#items + 1] = { label = T("恢复默认（", "DEFAULT (") .. T(ACC.banText(NET.ACCBAN_DEF, 1), ACC.banText(NET.ACCBAN_DEF, 2)) .. T("）", ")"),
                              act = function() NET.accBanSet(NET.ACCBAN_DEF); out("联机面板：禁用饰品恢复默认") end }
    end
    items[#items + 1] = { label = T("返回", "BACK"), act = toPage("room") }
end
-- §180 禁用武器 / 影之武装勾选页（NETUI.page = "wpnban" / "edgeban"）：同 §176 禁用饰品那页，按 WBAN.LIST 顺序、每页 NETUI.ACCBAN_PER 件。
-- 默认一件不禁，"恢复默认" = 全去掉。勾上 = 装着它不能准备 / 开局（不换装）
NETUI.wbanPage = {}
function NETUI.wbanItems(kind, lb, items, toPage)
    local ranked, client = lb.rk == "1", lb.role == "client"
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
                                  .. (ranked and T("：武林盟主固定", ": RANKED, FIXED") or client and T("：主机设置", ": HOST'S SETTING") or T("：下一局生效", ": NEXT MATCH")),
                          col = COL_LABEL }
    for i = (pg - 1) * NETUI.ACCBAN_PER + 1, math.min(pg * NETUI.ACCBAN_PER, #ids) do
        local id = ids[i]
        local nm = WBAN.NAME[kind .. ":" .. id] or { id, id }
        items[#items + 1] = { label = (cur[id] and "[x] " or "[  ] ") .. T(nm[1], nm[2]),
                              act = function()
                                  if ranked then netuiFlash(T("武林盟主的规则由服务器固定，不能改", "RANKED RULES ARE FIXED BY THE SERVER"), COL_ORANGE); return end
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
local function roomPageItems(lb, items)
    local ranked = lb.rk == "1"
    if ranked then
        if NET.rkRules() then
            items[#items + 1] = { label = T("武林盟主固定规则（服务器定）：", "RANKED RULES (SET BY THE SERVER):"), col = COL_LABEL }
            if (lb.rkminver or "") ~= "" then      -- §188 服务器配了最低版本
                items[#items + 1] = { label = string.format(T("为保护平衡性，请最少使用 v%s 版本", "FOR BALANCE, RANKED NEEDS v%s OR NEWER"), lb.rkminver), col = COL_LABEL }
            end
        elseif lb.rkold == "1" then
            items[#items + 1] = { label = clipText(lb.rkerr or "", 40), col = COL_RED }
        else
            items[#items + 1] = { label = T("（正在从服务器获取排位规则…拿到前不能开局）", "(GETTING THE RANKED RULES FROM THE SERVER...)"), col = COL_ORANGE }
        end
    end
    local used = {}
    for k in pairs(NETUI.ROOM_ELSEWHERE) do used[k] = true end
    for _, k in ipairs(NETUI.ROOM_TOP) do
        used[k] = true
        local it = NETUI.roomItem(k, lb)
        if it then items[#items + 1] = it end
    end
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
        if c.spec then      -- §141.7 排队规矩（排位房间不显示，同以前）
            if ST.spec and not ranked then ST.spec.Q.items(sub, T, lb.role == "client" or lb.role == "spec", netuiFlash, lb, netuiCmd) end
        else
            for _, k in ipairs(c.keys) do
                local it = NETUI.roomItem(k, lb)
                if it then sub[#sub + 1] = it end
            end
        end
        if #sub > 0 then
            local open = NETUI.roomOpen == c.id
            items[#items + 1] = { label = (open and "[-] " or "[+] ") .. T(c.zh, c.en) .. string.format(T("（%d 项）", " (%d)"), #sub),
                                  act = function() NETUI.roomOpen = (NETUI.roomOpen ~= c.id) and c.id or nil; NETUI.roomFocus = c.id end }
            -- 展开 / 收起后光标跟着这一类的标题（上面一类收起时标题会往上挪）
            if NETUI.roomFocus == c.id then NETUI.sel, NETUI.roomFocus = #items, nil end
            if open then
                for _, it in ipairs(sub) do
                    it.label = "      " .. it.label
                    items[#items + 1] = it
                end
            end
        end
    end
end

-- 面板里可选的行：{ label, act = function() } ；没有 act 的是说明行。NETUI.page = main / rooms / settings（系统设置）/ room（房间设置）/ thanks
local function netuiItems(lb, tn)
    local items = {}
    if not lobbyAlive(lb) then
        if not netuiStarting() then
            items[#items + 1] = { label = T("重新启动联机程序", "RESTART THE ONLINE HELPER"),
                                  act = function() NETUI.tries = 0; netuiLaunch() end }
            -- §122 起发布包没有 PBZLobby.exe（联机程序是游戏里的 pbz_lobby.dll）：只有 exe 真在时才叫人手动打开它
            local exe = io.open((ROOT .. "/PBZLobby.exe"):gsub("/", "\\"), "rb")
            if exe then exe:close() end
            items[#items + 1] = { label = exe and T("（还不行：手动打开 Mods\\PBZ_MP\\PBZLobby.exe）", "(STILL NOT: OPEN Mods\\PBZ_MP\\PBZLobby.exe)")
                                              or T("（还不行：重启游戏；原因在 Mods\\PBZ_MP\\net\\lobby_errors.log）", "(STILL NOT: RESTART THE GAME; SEE Mods\\PBZ_MP\\net\\lobby_errors.log)") }
        end
        return items
    end
    local mode = netuiMode(lb, tn)
    local function page(p) return function() NETUI.page = p; NETUI.sel = 1 end end
    -- §171 每页底下：房间设置… 在 系统设置… 上面（用户 11-09；"设置"改名"系统设置"）
    local function settingsBtns()
        items[#items + 1] = { label = T("房间设置…", "ROOM RULES..."), act = page("room") }
        items[#items + 1] = { label = T("系统设置…", "SYSTEM SETTINGS..."), act = page("settings") }
    end
    -- v0.27.21 感谢名单（设置里的一页）：参与测试并反馈了 bug 的玩家
    if NETUI.page == "thanks" then
        items[#items + 1] = { label = T("参与测试并反馈了 bug 的玩家（B 站）：", "PLAYERS WHO TESTED AND REPORTED BUGS (BILIBILI):") }
        for _, n in ipairs({ "成步堂芦苇", "谦逊的刘恒宇", "亦如黎明中的花朵_", "絡訸", "化境", "一一清梦以及他的小伙伴们", "伊格尼斯", "、（你没看错）" }) do items[#items + 1] = { label = "  " .. n } end
        items[#items + 1] = { label = T("返回", "BACK"), act = page("settings") }
        return items
    end
    -- §110 武林盟主的排行榜页 / 排位账号页 / 统计页：换走了 ranked 方式（又没在排位房间里）就回主页
    local ranked = mode == "ranked" or lb.rk == "1"
    if (NETUI.page == "rank" or NETUI.page == "rankkey" or NETUI.page == "rankstat" or NETUI.page == "rankrules") and not ranked then NETUI.page = "main" end
    if NETUI.page == "rank" then NETUI.rankItems(lb, tn, items, page); return items end
    if NETUI.page == "rankrules" then NETUI.rulesItems(lb, tn, items, page); return items end     -- §175
    if NETUI.page == "rankstat" then NETUI.statItems(lb, tn, items, page); return items end
    if NETUI.page == "rankkey" then NETUI.rankKeyItems(lb, tn, items, page); return items end
    if NETUI.page == "aiload" then NETUI.aiLoadItems(lb, items, page); return items end     -- §114 AI 装备
    if NETUI.page == "aipick" then NETUI.aiPickItems(lb, items, page); return items end
    if NETUI.page == "accban" then NETUI.accBanItems(lb, items, page); return items end     -- §176 禁用饰品
    if WBAN.LIST[NETUI.page] then NETUI.wbanItems(NETUI.page, lb, items, page); return items end     -- §180 禁用武器 / 影之武装
    if NETUI.page == "phrases" and CHAT.phraseItems(lb, items, page) then return items end    -- §150 快捷短语
    if NETUI.page == "opp" then OPP.oppItems(lb, items, page); return items end           -- §174 举报 / 拉黑
    if NETUI.page == "oppact" then OPP.actItems(lb, items, page); return items end
    if NETUI.page == "report" then OPP.reportItems(lb, items, page); return items end
    if NETUI.page == "blist" then OPP.listItems(lb, items, page); return items end
    -- 房间设置页（用户 2026-11-06"单独出个页面放房间设置"）：主机 / 没联机时点了换值，客机只看主机定的；都是下一局生效。
    -- §110 武林盟主：规则是服务器定的固定值，只显示、点了不改。§171 入口挪到各页"系统设置…"上面，返回回主页
    if NETUI.page == "room" then
        roomPageItems(lb, items)
        items[#items + 1] = { label = T("返回", "BACK"), act = page("main") }
        return items
    end
    if NETUI.page == "settings" then
        local on = lb.upnpon == "1"
        items[#items + 1] = { label = T("昵称：", "NAME: ") .. clipText(lb.name or "?", 20),
                              act = function() editStart("name", T("输入新昵称（空着回车 = 不改）", "NEW NAME (EMPTY = KEEP)"), "", lb.name or "") end }
        items[#items + 1] = { label = T("端口：", "PORT: ") .. (lb.cfgport or "?") .. T("（服务器大厅的 IP 直连用）", " (DIRECT IP)"),
                              act = function() editStart("port", T("输入新端口 1–65535（空着回车 = 不改）", "NEW PORT 1-65535 (EMPTY = KEEP)"), "", lb.cfgport or "27015") end }
        items[#items + 1] = { label = T("UPnP 自动转发端口：", "UPNP PORT FORWARDING: ") .. (on and T("开", "ON") or T("关", "OFF")),
                              act = function() netuiCmd("upnp", "on=" .. (on and "0" or "1") .. "\n") end }
        -- 服务器大厅用的服务器地址（域名或 IP[:端口]，默认端口 27020）
        local srv = (lb.srv or "") ~= "" and lb.srv or T("未填", "NOT SET")
        items[#items + 1] = { label = T("大厅服务器：", "LOBBY SERVER: ") .. clipText(srv, 24),
                              act = function() editStart("server", T("输入大厅服务器地址 域名或IP[:端口]（空着回车 = 不改）", "LOBBY SERVER HOST[:PORT] (EMPTY = KEEP)"), "",
                                                         (lb.srv or "") ~= "" and lb.srv or "1.2.3.4:27020") end }
        -- §102 允许走服务器中转（默认关）：直连不通时才用，服务器也得开 --relay；主机关着时别人不能经中转加入它的房间
        local relayOn = lb.relayon == "1"
        items[#items + 1] = { label = T("直连不通时用服务器中转：", "USE SERVER RELAY IF DIRECT FAILS: ") .. (relayOn and T("允许", "ON") or T("不用", "OFF")),
                              act = function() netuiCmd("relay", "on=" .. (relayOn and "0" or "1") .. "\n") end }
        -- v0.22.0 联机密码（可选，两边填同一个；空 = 不签名）。面板只显示设没设，密码本身不回传给游戏
        items[#items + 1] = { label = T("联机密码：", "PASSWORD: ") .. (lb.secret == "1" and T("已设置", "SET") or T("未设置（不签名）", "NONE (UNSIGNED)")),
                              act = function() editStart("secret", T("输入联机密码，两边要一样（空着回车 = 不改，输入 - = 清除）", "PASSWORD, SAME ON BOTH SIDES (EMPTY = KEEP, - = CLEAR)"), "",
                                                         T("对方也要填同一个", "BOTH SIDES USE THE SAME ONE")) end }
        -- §171 对手位置严格跟随（房间规则 npos，主机定）放在系统设置（用户 11-09）；房间设置…入口挪到各页"系统设置…"上面
        local npos = NETUI.roomItem("npos", lb)
        if npos then items[#items + 1] = npos end
        items[#items + 1] = { label = T("语言：中文", "LANGUAGE: ENGLISH"),
                              act = function() netuiCmd("lang", "lang=" .. (LANG.zh and "en" or "zh") .. "\n") end }
        -- §122 游戏里的 pbz_lobby.dll 没有窗口（lobby.txt win=0），只有退回 exe 时才有这个按钮；旧版联机程序不写 win，照旧显示
        if lb.win ~= "0" then
            items[#items + 1] = { label = T("打开电脑上的联机窗口", "OPEN THE DESKTOP WINDOW"), act = function() netuiCmd("show") end }
        end
        items[#items + 1] = { label = T("感谢名单…", "THANKS..."), act = page("thanks") }
        items[#items + 1] = { label = T("返回", "BACK"), act = page("main") }
        return items
    end
    -- §75 本地 AI 对战：联机程序在本机跑一个 AI 对手当客机（lobby/LocalAi.cs），面板只有开始 / 结束和难度（0 简单 / 1 普通 / 2 困难）
    local aiLv = tonumber(lb.ailevel) or 1
    local aiLevel = { label = T("AI 难度：", "AI LEVEL: ") .. (({ [0] = T("简单", "EASY"), T("普通", "NORMAL"), T("困难", "HARD") })[aiLv] or "?"),
                      act = function() netuiCmd("ailevel", "level=" .. ((aiLv + 1) % 3) .. "\n") end }
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
                                  -- 跳过 ai 和 ranked（§110：排位房间不跟 AI 对战混着开）
                                  local nx = ms[i % #ms + 1]
                                  for _ = 1, #ms do
                                      if nx ~= "ai" and nx ~= "ranked" then break end
                                      i = i % #ms + 1
                                      nx = ms[i % #ms + 1]
                                  end
                                  netuiCmd("airoommode", "mode=" .. nx .. "\n")
                              end }
    end
    if mode == "ai" and NETUI.page == "rooms" then NETUI.page = "main" end
    if mode == "ai" and (lb.role or "none") == "none" then
        items[#items + 1] = { label = T("连接方式：", "VIA: ") .. "< " .. netModeName(mode) .. " >", mode = true,
                              act = function() NETUI.step(1) end }
        items[#items + 1] = { label = T("开始 AI 对战", "START AI BATTLE"), act = function() netuiCmd("host") end }
        items[#items + 1] = aiLevel
        items[#items + 1] = { label = T("AI 装备…", "AI LOADOUT..."), act = page("aiload") }     -- §114
        aiRoomItems()
        items[#items + 1] = { label = roomOn and T("（开打后同时开着房间，有人进来就结束 AI 对战、改成和他打）", "(A PLAYER WHO JOINS REPLACES THE AI)")
                                         or T("（AI 照抄你的攻击属性，武器等在\"AI 装备\"里选；开始后按 F1 开打）", "(COPIES YOUR STATS; PICK ITS GEAR IN AI LOADOUT; PRESS F1 TO FIGHT)") }
        settingsBtns()
        return items
    end
    if lb.mode == "ai" and (lb.role or "none") ~= "none" then
        items[#items + 1] = { label = T("结束 AI 对战", "END AI BATTLE"), act = function() netuiCmd("stop") end }
        items[#items + 1] = aiLevel
        items[#items + 1] = { label = T("AI 装备…", "AI LOADOUT..."), act = page("aiload") }     -- §114
        aiRoomItems()
        if lb.aiwait == "1" then
            items[#items + 1] = { label = roomMode == "server" and T("复制房间号（发给朋友）", "COPY MY ROOM CODE") or T("复制房间地址（发给朋友）", "COPY MY ADDRESS"),
                                  act = function() netuiCmd("copy"); netuiFlash(T("已复制到剪贴板", "COPIED TO THE CLIPBOARD")) end }
        end
        settingsBtns()
        return items
    end
    local copy = { label = NETUI.viaServer(mode) and T("复制房间号（发给朋友）", "COPY MY ROOM CODE") or T("复制我的地址（发给朋友）", "COPY MY ADDRESS"),
                   act = function() netuiCmd("copy"); netuiFlash(T("已复制到剪贴板", "COPIED TO THE CLIPBOARD")) end }
    local quick, rooms = netuiTargets(lb)
    if NETUI.page == "rooms" then
        if (lb.role or "none") ~= "none" then NETUI.page = "main"; return netuiItems(lb, tn) end   -- 联机了就回主页
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
        items[#items + 1] = { label = T("连接方式：", "VIA: ") .. "< " .. netModeName(mode) .. " >", mode = true,
                              act = function() NETUI.step(1) end }
        local hostLabel = mode == "server" and T("创建服务器（登记到大厅）", "CREATE A SERVER ROOM")
                       or mode == "ranked" and T("创建武林盟主房间（排位）", "CREATE A RANKED ROOM")
                       or mode == "steamlobby" and T("创建 Steam 大厅（当主机）", "CREATE A STEAM LOBBY")
                       or T("创建房间（当主机）", "HOST A ROOM")
        items[#items + 1] = { label = hostLabel, act = function() netuiCmd("host") end }
        for i = 1, math.min(#quick, NETUI_QUICK) do items[#items + 1] = joinItem(quick[i]) end
        -- v0.20.1：房间列表一律单独一页（用户："房间列表需要一个新的界面，不然显示不全服务器可能有的房间"）。
        -- 没有房间时也能进（列表页里显示"没有房间"，房间来了自动出现）
        local open = 0
        for _, r in ipairs(rooms) do if roomOpen(r) then open = open + 1 end end
        items[#items + 1] = { label = #rooms == 0 and (T("房间列表", "ROOM LIST") .. " " .. NETUI.noRooms(lb, mode, tn) .. "…")
                                     or string.format(T("房间列表（%d 个，可加入 %d）…", "ROOM LIST (%d, %d OPEN)..."), #rooms, open),
                              act = NETUI.openRooms }
        local steam = mode == "steam" or mode == "steamlobby"
        if NETUI.viaServer(mode) then
            items[#items + 1] = { label = T("输入房间号加入…", "JOIN BY ROOM CODE..."),
                                  act = function() editStart("join", T("输入房间号（6 位）", "ENTER THE ROOM CODE"), "", "ABC234") end }
            -- 原来的广域网：主机开了端口转发 / UPnP 时直接连，服务器连不上也能用（§110 武林盟主不支持：结果要经服务器记分）
            if mode == "server" then
                items[#items + 1] = { label = T("输入 IP 直连…", "JOIN BY IP..."),
                                      act = function() editStart("join", T("输入主机的 公网IP:端口（服务器连不上时用）", "HOST PUBLIC-IP:PORT (IF THE SERVER IS DOWN)"), "", "1.2.3.4:27015") end }
            end
        else
            items[#items + 1] = { label = steam and T("输入 SteamID64 加入…", "JOIN BY STEAMID64...") or T("输入地址加入…", "JOIN BY ADDRESS..."),
                                  act = function()
                                      editStart("join", steam and T("输入主机的 SteamID64", "ENTER THE HOST'S STEAMID64") or T("输入主机地址", "ENTER THE HOST ADDRESS"),
                                                "", steam and "7656119xxxxxxxxxx" or "192.168.1.8")
                                  end }
        end
        -- v0.20.1：没建房时一律不显示"复制地址 / 房间号"（用户："我没创建房间，复制功能应该是不能用的"）。
        -- v0.19.1 只对服务器大厅这样做，其他方式当时觉得建房前就有地址可复制
        if mode == "ranked" then        -- §110 排行榜 / 武器与招式统计 + 规则没到 / 上一局结果 / 错误
            items[#items + 1] = { label = T("排行榜…", "LEADERBOARD..."), act = function() NETUI.sel = 1; NETUI.openRank(1) end }
            items[#items + 1] = { label = T("武器与招式统计…", "WEAPON & MOVE STATS..."), act = function() NETUI.sel = 1; NETUI.openStat(nil, 1) end }
            items[#items + 1] = { label = T("规则说明（怎么加减分）…", "RULES (HOW RATING WORKS)..."),       -- §175
                                  act = function() NETUI.sel, NETUI.rulesPg = 1, 1; page("rankrules")() end }
            NETUI.rankInfo(lb, items)
        end
    else
        if MAPGO.check() == "ok" then     -- v0.24.1 客机、地图不同、主机地图在地图表里
            items[#items + 1] = { label = T("前往主机所在地图（会自动存档）", "GO TO THE HOST'S MAP (AUTO-SAVES)"),
                                  act = function() MAPGO.go(getP1(), true) end }
        end
        if MAPGO.far and sessionRole() == "client" and not MATCH.role then     -- §156
            items[#items + 1] = { label = T("传送到主机身边", "TELEPORT TO THE HOST"), act = function() MAPGO.toHost(getP1(), true) end }
        end
        if CHAT.can(lb) then       -- §112
            items[#items + 1] = { label = T("聊天…（Delete）", "CHAT... (DELETE)"), act = function() CHAT.open(true) end }
            items[#items + 1] = { label = T("快捷短语…", "QUICK PHRASES..."),
                                  act = function() CHAT.loadPhrases(); page("phrases")() end }      -- §150
        end
        if ST.spec then ST.spec.Q.panel(items, T, lb, netuiCmd, netuiFlash) end      -- §141.7 换下一位 / 我下去观战 / 排第几
        items[#items + 1] = { label = T("断开", "DISCONNECT"), act = function() netuiCmd("stop") end }
        if lb.role == "host" then items[#items + 1] = copy end      -- 客机复制自己的地址没用
        NETUI.upnpInfo(lb, items)       -- §129
        if lb.rk == "1" then            -- §110 排位房间里也能看排行榜 / 统计
            items[#items + 1] = { label = T("排行榜…", "LEADERBOARD..."), act = function() NETUI.sel = 1; NETUI.openRank(1) end }
            items[#items + 1] = { label = T("武器与招式统计…", "WEAPON & MOVE STATS..."), act = function() NETUI.sel = 1; NETUI.openStat(nil, 1) end }
            items[#items + 1] = { label = T("规则说明（怎么加减分）…", "RULES (HOW RATING WORKS)..."),       -- §175
                                  act = function() NETUI.sel, NETUI.rulesPg = 1, 1; page("rankrules")() end }
            NETUI.rankInfo(lb, items)
        end
    end
    OPP.entry(lb, items, page)      -- §174 举报 / 拉黑对手（有最近对手才显示）
    settingsBtns()
    return items
end

-- §174 举报 / 拉黑（HANDOVER §174）。名单、标识、拒绝连入都在联机程序里（lobby/NetExtras.cs Blacklist / Reporter），面板只发命令：
-- block who=<第几个最近对手> / unblock i=<黑名单第几个> / report who= why=cheat note=<附言>。lobby.txt：
-- opn / op<i> = <已拉黑 0/1>|<连接方式>|<几秒前>|<昵称>；bln / bl<i> = <连接方式>|<拉黑时间 unix>|<昵称>；rpt = 举报结果
-- 用户 11-09："举报只保留修改器 / 外挂这个吧，然后我们可以拿到数据看异常，将来给反作弊打底子" → 原因只有 cheat 一种，不用勾选
-- （服务端 / --dump-reports 照旧认旧的 bug / afk / abuse / other，旧版客户端发来的也收）
OPP = { who = 1, note = "", pg = 1, PER = 8, WHY = { "cheat", "修改器 / 外挂", "CHEATS / HACKS" } }

function OPP.opp(lb, i)
    local b, mode, ago, nick = (lb["op" .. i] or ""):match("^([01])|([^|]*)|(%d+)|(.*)$")
    if not b then return nil end
    return { blocked = b == "1", mode = mode, ago = tonumber(ago) or 0, nick = nick ~= "" and nick or "?" }
end

local function blkAgo(sec)
    if sec < 60 then return T("刚才", "JUST NOW") end
    if sec < 3600 then return string.format(T("%d 分钟前", "%d MIN AGO"), math.floor(sec / 60)) end
    return string.format(T("%d 小时前", "%d H AGO"), math.floor(sec / 3600))
end

-- 主页 / 联机中页底下的入口（有最近对手或黑名单不空才显示；系统设置页已经 12 行，黑名单放在这一页里）
function OPP.entry(lb, items, page)
    local n = tonumber(lb.opn) or 0
    if n == 0 and (tonumber(lb.bln) or 0) == 0 then return end
    local o = OPP.opp(lb, 1)
    items[#items + 1] = { label = T("举报 / 拉黑…", "REPORT / BLOCK...") .. (o and ("  " .. clipText(o.nick, 12)) or ""), act = page("opp") }
end

-- 最近的对手（最多 5 个）：选一个 → 拉黑 / 举报
function OPP.oppItems(lb, items, page)
    local n = tonumber(lb.opn) or 0
    for i = 1, n do
        local o = OPP.opp(lb, i)
        if o then
            items[#items + 1] = { label = clipText(o.nick, 16) .. "  " .. netModeName(o.mode) .. "  " .. blkAgo(o.ago) .. (o.blocked and T("  [已拉黑]", "  [BLOCKED]") or ""),
                                  act = function() OPP.who = i; page("oppact")() end }
        end
    end
    if n == 0 then items[#items + 1] = { label = T("（还没有对手）", "(NO OPPONENT YET)") } end
    items[#items + 1] = { label = string.format(T("黑名单（%d）…", "BLACKLIST (%d)..."), tonumber(lb.bln) or 0), act = function() OPP.pg = 1; page("blist")() end }
    items[#items + 1] = { label = T("返回", "BACK"), act = page("main") }
end

function OPP.actItems(lb, items, page)
    local o = OPP.opp(lb, OPP.who)
    if not o then page("opp")(); return end
    items[#items + 1] = { label = T("对手：", "OPPONENT: ") .. clipText(o.nick, 16) .. "（" .. netModeName(o.mode) .. "，" .. blkAgo(o.ago) .. "）" }
    if o.blocked then
        items[#items + 1] = { label = T("已在黑名单里（上一页的\"黑名单\"里可以解除）", "ALREADY BLOCKED (UNBLOCK IT IN THE BLACKLIST)") }
    else
        items[#items + 1] = { label = T("拉黑（以后不让他进我的房、不列他的房）", "BLOCK (REFUSE HIM, HIDE HIS ROOMS)"),
                              act = function() netuiCmd("block", "who=" .. OPP.who .. "\n"); netuiFlash(T("已拉黑", "BLOCKED")) end }
    end
    items[#items + 1] = { label = T("举报…（经大厅服务器）", "REPORT... (VIA THE LOBBY SERVER)"), act = function() OPP.note = ""; page("report")() end }
    items[#items + 1] = { label = T("返回", "BACK"), act = page("opp") }
end

function OPP.reportItems(lb, items, page)
    local o = OPP.opp(lb, OPP.who)
    if not o then page("opp")(); return end
    items[#items + 1] = { label = T("举报 ", "REPORT ") .. clipText(o.nick, 16) .. T(" 使用", " FOR USING ") .. T(OPP.WHY[2], OPP.WHY[3]) }
    items[#items + 1] = { label = T("附言：", "NOTE: ") .. (OPP.note ~= "" and clipText(OPP.note, 20) or T("（可不填）", "(OPTIONAL)")),
                          act = function() editStart("rnote", T("附言（可不填，120 字以内；输入 - 清空）", "NOTE (OPTIONAL, - = CLEAR)"), "", OPP.note) end }
    items[#items + 1] = { label = T("提交举报", "SEND THE REPORT"),
                          act = function()
                              netuiCmd("report", "who=" .. OPP.who .. "\nwhy=" .. OPP.WHY[1] .. "\nnote=" .. OPP.note .. "\n"
                                  .. CS.forReport(o.nick, OPP.who, now()))      -- §181 作弊数据采样：这个对手这场 / 最近一场的摘要（没有 = 不带）
                              OPP.note = ""
                          end }
    if (lb.rpt or "") ~= "" then items[#items + 1] = { label = clipText(lb.rpt, 34) } end
    items[#items + 1] = { label = T("返回", "BACK"), act = page("oppact") }
end

-- 系统设置 → 黑名单：点一行解除
function OPP.listItems(lb, items, page)
    local n = tonumber(lb.bln) or 0
    local shown = math.min(n, 40)
    local pages = math.max(1, math.ceil(shown / OPP.PER))
    OPP.pg = math.min(math.max(OPP.pg, 1), pages)
    if n == 0 then items[#items + 1] = { label = T("（黑名单是空的）", "(THE BLACKLIST IS EMPTY)") } end
    for i = (OPP.pg - 1) * OPP.PER + 1, math.min(OPP.pg * OPP.PER, shown) do
        local mode, at, nick = (lb["bl" .. i] or ""):match("^([^|]*)|(%d+)|(.*)$")
        if mode then
            items[#items + 1] = { label = T("解除：", "UNBLOCK: ") .. clipText(nick, 16) .. "  " .. netModeName(mode) .. "  " .. os.date("%m-%d", tonumber(at) or 0),
                                  act = function() netuiCmd("unblock", "i=" .. i .. "\n"); netuiFlash(T("已解除", "UNBLOCKED")) end }
        end
    end
    if OPP.pg < pages then items[#items + 1] = { label = T("下一页", "NEXT PAGE"), nav = "next", act = function() OPP.pg = OPP.pg + 1; NETUI.sel = 1 end } end
    if OPP.pg > 1 then items[#items + 1] = { label = T("上一页", "PREVIOUS PAGE"), nav = "prev", act = function() OPP.pg = OPP.pg - 1; NETUI.sel = 1 end } end
    items[#items + 1] = { label = T("返回", "BACK"), act = page("opp") }
end

-- 状态行：文字 + 颜色
local function netuiStatus(lb, tn)
    if PP.on then return PP.text(), COL_ORANGE end          -- v0.21.0：盖过其他状态（见 PP 段）
    if not lobbyAlive(lb) then
        if netuiStarting() then
            return T("正在启动联机程序…", "STARTING THE ONLINE HELPER..."), COL_ORANGE
        end
        if NETUI.launchErr then
            return T("联机程序启动失败：", "HELPER FAILED: ") .. clipText(NETUI.launchErr, 20), COL_RED
        end
        return T("联机程序没响应", "THE ONLINE HELPER IS NOT RESPONDING"), COL_RED
    end
    local b = NETUI.busy
    if b then return T(b.zh, b.en) .. ({ ".", "..", "..." })[math.floor(tn * 3) % 3 + 1], COL_ORANGE end   -- §91 点会动
    if (lb.err or "") ~= "" then return clipText(lb.err, 34), COL_RED end
    -- v0.22.0：密码对不上 / 版本不一致的提示（联机程序给的短句）；没连上时红色，连着时橙色
    if (lb.hint or "") ~= "" then return clipText(lb.hint, 34), lb.connected == "1" and COL_ORANGE or COL_RED end
    if NETUI.flash and os.time() < NETUI.flash.till then return NETUI.flash.text, NETUI.flash.col or COL_GREEN end
    if (lb.mode == "steam" or lb.mode == "steamlobby") and lb.steam ~= "ok" then return clipText(lb.steam, 34), COL_RED end
    -- 服务器大厅：服务器没回应 / 没这个房间 / 没填地址
    if NETUI.viaServer(lb.mode) and (lb.srverr or "") ~= "" and lb.connected ~= "1" then return clipText(lb.srverr, 34), COL_RED end
    local role, conn = lb.role or "none", lb.connected == "1"
    if role == "none" then
        if lb.mode == "ai" then return T("未开始  和本机 AI 对战，不联网", "NOT STARTED  OFFLINE, AGAINST THE COMPUTER"), COL_GRAY end
        return T("未联机", "OFFLINE") .. "  " .. clipText(lb.myaddr, 40), COL_GRAY
    end
    local who = (lb.peername or "") ~= "" and lb.peername or (lb.peer or "")
    local route = NETUI.viaServer(lb.mode) and netRouteName(lb.route) or nil
    if conn then
        local ping = LAT.rttMs() or tonumber(lb.ping) or -1     -- v0.27.0 优先用模组自己量的往返（含两边节拍和文件邮箱）
        return T("已连接 ", "CONNECTED ") .. clipText(who, 18) .. (ping >= 0 and string.format("  %dms", ping) or "")
               .. (route and ("  " .. route) or "")
               .. (lb.aiwait == "1" and (T("  房间开着：", "  ROOM: ") .. clipText(lb.aiwaitaddr, 22)) or ""), COL_GREEN
    end
    if role == "host" then return T("主机：等对方加入  ", "HOSTING: WAITING  ") .. clipText(lb.myaddr, 22), COL_ORANGE end
    if route then return T("正在连接（", "CONNECTING (") .. route .. T("）", ")"), COL_ORANGE end
    return T("正在连接 ", "CONNECTING ") .. clipText(who, 24), COL_ORANGE
end

local function netuiRows(tn)
    local lb = netuiRead(tn)
    if NETUI.edit then
        editTick()
        local e = NETUI.edit
        if e then
            NETUI.view = { edit = true, title = T("联机", "ONLINE"), prompt = e.prompt }
            -- 第 3 行留空给输入框（umgHud 记下每行的位置，输入框摆到这一行）
            local rows = { { c = T("联机   [Home] 关闭", "ONLINE   [HOME] CLOSE"), col = COL_LABEL, size = 0.8 },
                           { c = e.prompt, col = COL_WHITE, size = 0.7 },
                           { c = " ", col = COL_WHITE, size = 1.0 },
                           { c = T("回车 确定   Esc 取消   Ctrl+V 粘贴", "ENTER OK   ESC CANCEL   CTRL+V PASTE"), col = COL_LABEL, size = 0.55 } }
            return rows
        end
    end
    NETUI.busyStep(lb, tn)
    local items = netuiItems(lb, tn)
    -- §91 等回话时按钮点不了；off = 本来是按钮（鼠标面板照样画按钮底、整个变暗，不像说明行那样只剩字，§91.1）
    if NETUI.busy then for _, it in ipairs(items) do if it.act then it.act, it.off = nil, true end end end
    -- 房间列表页：刷新后光标跟着同一个房间（按 target 认）；房间没了就留在原位置
    if NETUI.page == "rooms" and NETUI.selTarget then
        for i, it in ipairs(items) do
            if it.target == NETUI.selTarget and it.act then NETUI.sel = i; break end
        end
    end
    NETUI.items = items
    if NETUI.sel > #items then NETUI.sel = #items end
    if NETUI.sel < 1 then NETUI.sel = 1 end
    -- 光标落在选不中的行（说明行、已满的房间：比如翻到全是已满房间的那一页）就往下找第一个能选的，没有再往上找
    if items[NETUI.sel] and not items[NETUI.sel].act then
        local found
        for i = NETUI.sel, #items do if items[i].act then found = i; break end end
        if not found then for i = NETUI.sel, 1, -1 do if items[i].act then found = i; break end end end
        NETUI.sel = found or NETUI.sel
    end
    local st, col = netuiStatus(lb, tn)
    local title = T("联机   [Home] 关闭", "ONLINE   [HOME] CLOSE")
    local name = NETUI.page == "settings" and T("联机 · 系统设置", "ONLINE · SYSTEM SETTINGS")
              or NETUI.page == "room" and T("联机 · 房间设置", "ONLINE · ROOM RULES")
              or NETUI.page == "thanks" and T("联机 · 感谢名单", "ONLINE · THANKS")
              or NETUI.page == "aiload" and T("联机 · AI 装备", "ONLINE · AI LOADOUT")
              or NETUI.page == "aipick" and T("联机 · AI 装备 · 选择", "ONLINE · AI LOADOUT · PICK")
              or NETUI.page == "phrases" and T("联机 · 快捷短语", "ONLINE · QUICK PHRASES")
              or (NETUI.page == "opp" or NETUI.page == "oppact") and T("联机 · 举报 / 拉黑", "ONLINE · REPORT / BLOCK")
              or NETUI.page == "report" and T("联机 · 举报", "ONLINE · REPORT")
              or NETUI.page == "blist" and T("联机 · 黑名单", "ONLINE · BLACKLIST")
              or NETUI.page == "rankkey" and T("联机 · 排位账号", "ONLINE · RANKED ACCOUNT") or T("联机", "ONLINE")
    if NETUI.page == "rank" then        -- §110 排行榜：页码在翻页栏（鼠标面板）/ 标题行（文字面板）
        local sh = NETUI.rankShown or {}
        name = sh.season and string.format(T("武林盟主排行榜  赛季 %s", "RANKED LEADERBOARD  SEASON %s"), sh.season) or T("武林盟主排行榜", "RANKED LEADERBOARD")
        title = string.format(T("排行榜  第 %d/%d 页   [Home] 关闭", "LEADERBOARD  PAGE %d/%d   [HOME] CLOSE"), sh.pg or 1, sh.pages or 1)
    end
    if NETUI.page == "rankrules" then   -- §175 规则说明：同排行榜页，名字带这一页的小标题
        local sh = NETUI.rulesShown or {}
        name = T("武林盟主规则 · ", "RANKED RULES · ") .. (sh.title and T(sh.title[1], sh.title[2]) or "")
        title = string.format(T("规则说明  第 %d/%d 页   [Home] 关闭", "RULES  PAGE %d/%d   [HOME] CLOSE"), sh.pg or 1, sh.pages or 1)
    end
    if NETUI.page == "rankstat" then    -- §110 统计页：同排行榜页
        local sh = NETUI.statShown or {}
        name = sh.season and string.format(T("武林盟主 · 武器与招式统计  赛季 %s", "RANKED STATS  SEASON %s"), sh.season) or T("武林盟主 · 武器与招式统计", "RANKED STATS")
        title = string.format(T("统计  第 %d/%d 页   [Home] 关闭", "STATS  PAGE %d/%d   [HOME] CLOSE"), sh.pg or 1, sh.pages or 1)
    end
    if NETUI.page == "rooms" then
        local _, rooms = netuiTargets(lb)
        title = string.format(T("房间列表  第 %d/%d 页   [Home] 关闭", "ROOMS  PAGE %d/%d   [HOME] CLOSE"), NETUI.roomPage or 1, roomPages(rooms))
        local open = 0
        for _, r in ipairs(rooms) do if roomOpen(r) then open = open + 1 end end
        name = string.format(T("房间列表（%d 个，可加入 %d）", "ROOM LIST (%d, %d OPEN)"), #rooms, open)   -- 页码在鼠标面板底下的翻页栏
    end
    -- 鼠标面板用的同一份内容（guiShow 读）
    NETUI.view = { title = name, status = st, col = col, items = items, mode = lobbyAlive(lb) and netuiMode(lb, tn) or nil,
                   rooms = NETUI.page == "rooms" and lobbyAlive(lb), roomPage = NETUI.roomPage or 1, busy = NETUI.busy ~= nil }
    if NETUI.view.rooms then NETUI.view.pages = roomPages(select(2, netuiTargets(lb))) end
    -- §110 排行榜页也用底下的翻页栏（rank = true；页码来自 lobby.txt 的 rktop）
    if NETUI.page == "rank" and lobbyAlive(lb) then
        local sh = NETUI.rankShown or {}
        NETUI.view.rank, NETUI.view.roomPage, NETUI.view.pages = true, sh.pg or 1, sh.pages or 1
    end
    if NETUI.page == "rankrules" and lobbyAlive(lb) then    -- §175 规则说明同上（rules = true）
        local sh = NETUI.rulesShown or {}
        NETUI.view.rules, NETUI.view.roomPage, NETUI.view.pages = true, sh.pg or 1, sh.pages or 1
    end
    if NETUI.page == "rankstat" and lobbyAlive(lb) then     -- 统计页同上（stat = true；页码来自 rkstat）
        local sh = NETUI.statShown or {}
        NETUI.view.stat, NETUI.view.roomPage, NETUI.view.pages = true, sh.pg or 1, sh.pages or 1
    end
    local rows = { { c = title, col = COL_LABEL, size = 0.8 },
                   { c = st, col = col, size = 0.7 } }
    NETUI.selTarget = items[NETUI.sel] and items[NETUI.sel].target or nil
    -- 项目比屏幕行多（§176 房间设置页最多 15 项 + 标题 / 状态 / 说明 = 18 > HUD_ROWS）：只显示选中项附近一段，
    -- 上下各留一行"还有 N 项"，PgUp/PgDn 走到哪段就显示哪段（以前是截掉最后几项，"返回"选得到却看不见）
    local cap, first, last = HUD_ROWS - 3, 1, #items
    if #items > cap then
        local w = cap - 2
        first = math.max(1, math.min((NETUI.sel or 1) - w // 2, #items - w + 1))
        last = first + w - 1
        rows[#rows + 1] = first > 1 and { c = T("（上面还有 " .. (first - 1) .. " 项）", "(" .. (first - 1) .. " MORE ABOVE)"), col = COL_GRAY, size = 0.55 } or nil
    end
    for i = first, last do
        local it = items[i]
        local sel = i == NETUI.sel and it.act
        rows[#rows + 1] = { c = sel and ("> " .. it.label .. " <") or it.label, col = sel and COL_WHITE or it.col or COL_GRAY, size = 0.7 }
    end
    if last < #items then
        rows[#rows + 1] = { c = T("（下面还有 " .. (#items - last) .. " 项）", "(" .. (#items - last) .. " MORE BELOW)"), col = COL_GRAY, size = 0.55 }
    end
    rows[#rows + 1] = { c = T("PgUp/PgDn 选择   End 确定 / 换方式", "PGUP/PGDN SELECT   END OK / CHANGE VIA"),
                        col = COL_LABEL, size = 0.55 }
    while #rows > HUD_ROWS do table.remove(rows, #rows - 1) end
    return rows
end

-- 换连接方式（d = ±1）
function NETUI.step(d)
    local lb = NETUI.lobby
    if not lobbyAlive(lb) or NETUI.busy then return end
    if (lb.role or "none") ~= "none" then out("联机面板：联机中不能换连接方式，先断开"); return end
    local cur, shown = 1, netuiMode(lb, now())
    local ms = NETUI.modes()
    for i, m in ipairs(ms) do if m == shown then cur = i end end
    NETUI.setMode(ms[(cur - 1 + d) % #ms + 1])
end

-- 直接换到某种连接方式（鼠标面板点标签页）
function NETUI.setMode(m)
    local lb = NETUI.lobby
    if not lobbyAlive(lb) or NETUI.busy then return end
    NETUI.listFrom = now()
    if (lb.role or "none") ~= "none" then out("联机面板：联机中不能换连接方式，先断开"); return end
    NETUI.want = { mode = m, at = now() }
    netuiCmd("mode", "mode=" .. m .. "\n")
end

-- ---- v0.20.0 鼠标面板（说明见 GUI 的定义处）
local GUI_Z = 460            -- 比屏幕文字（450）高
local GUI_ROWS = 17           -- §171 各页底下多了"房间设置…"一行，16 → 17；房间设置单独一页后最多 11 项，回到 16；§105.3 / §106.5 曾 16 项 / 18；v0.27.6 设置页已有 12 项，留两行余量；v0.27.21 13 项（感谢名单），14 → 15；§102 14 项（服务器中转），15 → 16
local GUI_W = 640            -- 面板最小宽度（Slate 单位）
local BG_ROW = { R = 0.10, G = 0.10, B = 0.12, A = 0.92 }
local BG_HOVER = { R = 0.24, G = 0.24, B = 0.28, A = 0.95 }
local BG_SEL = { R = 0.42, G = 0.30, B = 0.08, A = 0.95 }      -- 键盘选中 / 当前的连接方式：金
local BG_DOWN = { R = 0.60, G = 0.44, B = 0.12, A = 1.0 }
local BG_NONE = { R = 0.0, G = 0.0, B = 0.0, A = 0.0 }
local BG_OFF = { R = 0.10, G = 0.10, B = 0.12, A = 0.45 }      -- §91.1 等回话时的按钮：底色淡一半

local function guiNew(cls)
    return StaticConstructObject(StaticFindObject("/Script/UMG." .. cls), GUI.w.WidgetTree)
end

local function guiFont(tb, size)
    local f = tb.Font
    f.Size = size
    f.OutlineSettings.OutlineSize = 1
    f.OutlineSettings.OutlineColor = { R = 0, G = 0, B = 0, A = 0.8 }
    tb:SetFont(f)
end

local function guiText(size, col)
    local tb = guiNew("TextBlock")
    guiFont(tb, size)
    tb:SetColorAndOpacity(umgColor(col))
    return tb
end

-- 按钮：三种状态都画成白色方块（没贴图的 Image），颜色每帧由 BackgroundColor 按 悬停 / 选中 / 按下 自己染；
-- 改样式失败就用引擎默认样式（照样能点）。halign：1 左 / 2 中
local function guiButton(size, halign)
    local b = guiNew("Button")
    local okS, errS = pcall(function()
        local st = b.WidgetStyle
        for _, k in ipairs({ "Normal", "Hovered", "Pressed", "Disabled" }) do
            st[k].DrawAs = 3
            st[k].TintColor = { SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 }, ColorUseRule = 0 }
        end
        b:SetStyle(st)
    end)
    if not okS and not GUI.styleErr then GUI.styleErr = true; out("!! 鼠标面板：按钮样式改不了（用默认样式）：%s", tostring(errS)) end
    local tb = guiText(size, COL_WHITE)
    local s = b:SetContent(tb)
    pcall(function()
        s:SetPadding({ Left = 14, Top = 5, Right = 14, Bottom = 5 })
        s:SetHorizontalAlignment(halign)
        s:SetVerticalAlignment(2)
    end)
    return { b = b, tb = tb }
end

-- 下面三个只在值变了时才调引擎
local function guiLabel(p, s, col)
    local key = string.format("%s|%d,%d,%d", s, col.R, col.G, col.B)
    if p.key == key then return end
    p.key = key
    p.tb:SetText(FText(s))
    p.tb:SetColorAndOpacity(umgColor(col))
end

local function guiBg(p, c)
    if p.bg == c then return end
    p.bg = c
    p.b:SetBackgroundColor(c)
end

-- 0 Visible（能点）/ 1 Collapsed / 3 HitTestInvisible（只显示）
local function guiVis(p, v)
    if p.vis == v then return end
    p.vis = v
    if v ~= 0 then p.down, p.hov = false, false end
    (p.b or p):SetVisibility(v)
end

-- 这次查询算不算点了一下：上一次按着、这次松开且鼠标还在上面
local function guiClicked(p)
    local okP, pressed = pcall(function() return p.b:IsPressed() end)
    local okH, hov = pcall(function() return p.b:IsHovered() end)
    pressed, hov = okP and pressed == true, okH and hov == true
    local click = p.down == true and not pressed and hov
    p.entered = hov and not p.hov
    p.down, p.hov = pressed, hov
    return click
end

local function guiBuild()
    local okP, pc = pcall(getP1PC)
    if not (okP and valid(pc)) then return false end
    local ok, err = pcall(function()
        GUI.w = StaticFindObject(WBL):Create(pc, StaticFindObject("/Script/UMG.UserWidget"), pc)
        local cv = guiNew("CanvasPanel")
        GUI.w.WidgetTree.RootWidget = cv
        cv:SetVisibility(4)                      -- SelfHitTestInvisible：空白处不挡
        local win = guiNew("Border")
        win:SetBrushColor({ R = 0.02, G = 0.02, B = 0.03, A = 0.88 })
        win:SetPadding({ Left = 22, Top = 16, Right = 22, Bottom = 16 })
        local sl = cv:AddChildToCanvas(win)
        sl:SetAnchors({ Minimum = { X = 0.5, Y = 0.45 }, Maximum = { X = 0.5, Y = 0.45 } })
        sl:SetAlignment({ X = 0.5, Y = 0.5 })
        sl:SetAutoSize(true)
        local size = guiNew("SizeBox")
        size:SetMinDesiredWidth(GUI_W)
        win:SetContent(size)
        local vb = guiNew("VerticalBox")
        size:SetContent(vb)
        local function add(child, top, halign)
            local s = vb:AddChildToVerticalBox(child)
            s:SetPadding({ Left = 0, Top = top or 0, Right = 0, Bottom = 0 })
            s:SetHorizontalAlignment(halign or 0)     -- 0 = 撑满
            return s
        end
        local head = guiNew("HorizontalBox")
        add(head)
        GUI.title = { tb = guiText(26, COL_LABEL) }
        local hs = head:AddChildToHorizontalBox(GUI.title.tb)
        hs:SetSize({ SizeRule = 1, Value = 1.0 })     -- 占满剩下的宽度，关闭按钮靠右
        hs:SetVerticalAlignment(2)
        GUI.close = guiButton(18, 2)
        head:AddChildToHorizontalBox(GUI.close.b)
        GUI.status = { tb = guiText(20, COL_GRAY) }
        add(GUI.status.tb, 8)
        GUI.tabBox = { b = guiNew("HorizontalBox") }
        add(GUI.tabBox.b, 12)
        GUI.tabs = {}
        for i, m in ipairs(NETUI.TABS) do
            local t = guiButton(18, 2)
            t.mode = m
            local ts = GUI.tabBox.b:AddChildToHorizontalBox(t.b)
            ts:SetSize({ SizeRule = 1, Value = 1.0 })
            ts:SetPadding({ Left = i > 1 and 4 or 0, Top = 0, Right = 0, Bottom = 0 })
            GUI.tabs[i] = t
        end
        GUI.rows = {}
        for i = 1, GUI_ROWS do
            GUI.rows[i] = guiButton(22, 1)
            add(GUI.rows[i].b, i == 1 and 12 or 4)
        end
        -- v0.20.1 房间列表页底下的翻页栏：上一页 / 第 p/P 页 / 下一页 …… 返回
        GUI.navBox = { b = guiNew("HorizontalBox") }
        add(GUI.navBox.b, 12)
        GUI.prev, GUI.next, GUI.back = guiButton(20, 2), guiButton(20, 2), guiButton(20, 2)
        GUI.pageNo = { tb = guiText(20, COL_WHITE) }
        GUI.navBox.b:AddChildToHorizontalBox(GUI.prev.b)
        local ps = GUI.navBox.b:AddChildToHorizontalBox(GUI.pageNo.tb)
        ps:SetPadding({ Left = 16, Top = 0, Right = 16, Bottom = 0 })
        ps:SetVerticalAlignment(2)
        GUI.navBox.b:AddChildToHorizontalBox(GUI.next.b)
        local gap = guiNew("Spacer")
        GUI.navBox.b:AddChildToHorizontalBox(gap):SetSize({ SizeRule = 1, Value = 1.0 })   -- 把"返回"推到最右
        GUI.navBox.b:AddChildToHorizontalBox(GUI.back.b)
        GUI.eb = guiNew("EditableTextBox")
        ebStyle(GUI.eb)
        add(GUI.eb, 14)
        ebColor(GUI.eb)
        GUI.eb:SetVisibility(1)
        GUI.editBox = { b = guiNew("HorizontalBox") }
        add(GUI.editBox.b, 10, 3)                    -- 靠右
        GUI.ok, GUI.cancel = guiButton(20, 2), guiButton(20, 2)
        GUI.editBox.b:AddChildToHorizontalBox(GUI.ok.b)
        GUI.editBox.b:AddChildToHorizontalBox(GUI.cancel.b):SetPadding({ Left = 8, Top = 0, Right = 0, Bottom = 0 })
        GUI.hint = { tb = guiText(16, COL_LABEL) }
        add(GUI.hint.tb, 14)
        GUI.w:AddToViewport(GUI_Z)
        GUI.pc, GUI.gen = pc, ST.mapLoads
    end)
    -- v0.26.4 面板能拿键盘焦点：放鼠标时焦点给它，guiMouseTick 看焦点被抢走（切出窗口回来）就重新放鼠标。拿不到焦点也能用，只是少一种检测
    if ok then
        GUI.focusable = pcall(function() GUI.w:SetIsFocusable(true) end)
                        or pcall(function() GUI.w.bIsFocusable = true end)
        if not GUI.focusable then out("鼠标面板：设不了可焦点，切窗口回来只靠鼠标指针 / 暂停检测") end
    end
    if not ok then
        GUI.failed = true
        out("!! 鼠标面板建不起来：%s，改用文字面板", tostring(err))
        pcall(function() GUI.w:RemoveFromParent() end)
        GUI.w = nil
        return false
    end
    out("鼠标面板已建好")
    return true
end

-- 换地图后旧的界面会被引擎回收：重建，并重新放出鼠标（玩家控制器可能也换了）
local function guiRoot()
    if GUI.fresh() then
        local okV, inVp = pcall(function() return GUI.w:IsInViewport() end)
        if okV and inVp then return true end
    end
    GUI.drop()
    if not guiBuild() then return false end
    GUI.on = true
    if NETUI.edit then editEnd("鼠标面板重建") else inputMode(false) end
    return true
end

local function guiHide()
    if GUI.fresh() and GUI.shownVis ~= 1 then
        GUI.shownVis = 1
        pcall(function() GUI.w:SetVisibility(1) end)
    end
end

local function netuiSetOpen(open, why)
    editEnd(why)
    NETUI.open = open
    out("联机面板 %s（%s）", open and "打开" or "关闭", why)
    if open then
        netuiEnsure("打开面板", now())
        NETUI.sel, NETUI.page, NETUI.listFrom = 1, "main", now()
    else
        guiHide()
    end
    if GUI.on then inputMode(false) end             -- 放出 / 收回鼠标
end

-- ---- §112 房内聊天（用户 2026-11-06："给 pvpmod 搞个聊天室"，选了先做房内的：只有连上的两个人）。
-- 发：Delete 键（Insert 被 BPModLoaderMod 占，F 键全满）或面板"聊天…"→ 游戏内输入框 → 回车发。走可靠事件通道
-- REL.send("chat", 文字)，丢了会重发、按顺序到；对方 REL.on.chat 收。对方是旧版（不认 chat）时只记一行"不认识，忽略"。
-- 显示：屏幕左下角最近 CHAT.LINES 条，每条 CHAT.SHOW_SEC 秒后藏起来；面板开着 / 在打字时一直显示最近几条。
-- 字挂在屏幕文字那层（HUD.w）上：游戏暂停时跟着藏，换地图后 HUD 重建、这里跟着重建。
-- 全局表（主代码块的 local 已满 200 个）
CHAT = { log = {}, HIST = 30, LINES = 6, SHOW_SEC = 15, MAX_BYTES = 150, X = 0.015, Y = 0.80, SIZE = 0.55,
         COL_ME = { R = 150, G = 205, B = 255, A = 255 }, COL_SYS = { R = 255, G = 140, B = 40, A = 255 } }

-- 一行文字：去掉控制字符和首尾空白；超过 MAX_BYTES 字节按 UTF-8 字边界截断（中文一个字 3 字节）
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

-- kind = me / peer / sys
function CHAT.add(who, text, kind)
    CHAT.log[#CHAT.log + 1] = { who = who, text = text, kind = kind, at = os.time() }
    while #CHAT.log > CHAT.HIST do table.remove(CHAT.log, 1) end
    out("【聊天】%s%s", who and (who .. "：") or "", text)
end

-- 能发：联机程序活着、连上了真人（本地 AI 不算）
function CHAT.can(lb)
    return lb and lobbyAlive(lb) and lb.connected == "1" and lb.mode ~= "ai"
end

function CHAT.send(s)
    s = CHAT.clean(s)
    if s == "" then return end
    if not CHAT.can(netuiRead(now())) then
        CHAT.add(nil, T("没连上对方，消息没发出去", "NOT CONNECTED, MESSAGE NOT SENT"), "sys")
        return
    end
    REL.send("chat", s)
    CHAT.add(T("我", "ME"), s, "me")
end

-- §150 快捷短语（用户 2026-11-08："聊天不是不能输入中文么，可以增加一个定式短语的功能么"）。
-- 聊天输入框里只输一个数字 1–9 回车 = 发第几句；面板"快捷短语…"页点一下也发。短语在 PBZ_MP\phrases.txt（UTF-8，一行一句，
-- # 开头的是注释，最多 9 句）；没有这个文件时按当前语言写一份默认的，以后用户改的不覆盖。只在打开聊天 / 这一页时读（不每帧读盘）
CHAT.PHRASE_MAX = 9
CHAT.PHRASE_DEF = {
    { "你好，请多指教", "HI, GOOD LUCK" }, { "好打！", "NICE ONE!" }, { "GG", "GG" },
    { "再来一局？", "REMATCH?" }, { "等我一下", "WAIT A SEC" }, { "准备好了", "READY" },
    { "我这边网有点卡", "LAGGING ON MY SIDE" }, { "抱歉", "SORRY" }, { "谢谢", "THANKS" },
}

function CHAT.phraseFile() return ROOT .. "/phrases.txt" end

function CHAT.loadPhrases()
    local list, path = {}, CHAT.phraseFile()
    local f = io.open(path, "r")
    if f then
        for line in f:lines() do
            line = line:gsub("^\239\187\191", "")         -- 记事本存的 UTF-8 带 BOM
            if not line:match("^%s*#") then
                local s = CHAT.clean(line)
                if s ~= "" and #list < CHAT.PHRASE_MAX then list[#list + 1] = s end
            end
        end
        f:close()
    else
        local w = io.open(path, "w")
        if w then
            w:write(T("# 快捷短语：一行一句，最多 9 句，从上到下是 1–9。用记事本改完存成 UTF-8，下次打开聊天生效\n",
                      "# Quick phrases: one per line, up to 9 (numbered 1-9 from the top). Save as UTF-8; applies next time chat opens\n"))
            for _, p in ipairs(CHAT.PHRASE_DEF) do w:write(T(p[1], p[2]), "\n") end
            w:close()
            out("聊天：写了一份默认快捷短语 %s", path)
        end
    end
    if #list == 0 then for _, p in ipairs(CHAT.PHRASE_DEF) do list[#list + 1] = T(p[1], p[2]) end end
    CHAT.phrases = list
    return list
end

-- 发第 n 句；正在聊天输入框里就先关掉它（按 Delete 开的会顺带关面板）
function CHAT.sendPhrase(n)
    local s = (CHAT.phrases or CHAT.loadPhrases())[n]
    if NETUI.edit and NETUI.edit.kind == "chat" then editEnd("快捷短语") end
    if s then CHAT.send(s) end
end

-- 面板"快捷短语…"页（NETUI.page = "phrases"）；按 Delete 开聊天时也翻到这页，边打字边看编号
function CHAT.phraseItems(lb, items, page)
    if not CHAT.can(lb) then NETUI.page = "main"; return false end
    items[#items + 1] = { label = T("点一下发送；聊天框里输数字 1–9 回车也行", "CLICK TO SEND, OR TYPE 1-9 + ENTER IN CHAT") }
    for i, s in ipairs(CHAT.phrases or CHAT.loadPhrases()) do
        items[#items + 1] = { label = i .. ". " .. clipText(s, 40), act = function() CHAT.sendPhrase(i) end }
    end
    items[#items + 1] = { label = T("（自己改：Mods\\PBZ_MP\\phrases.txt）", "(EDIT: Mods\\PBZ_MP\\phrases.txt)") }
    items[#items + 1] = { label = T("返回", "BACK"), act = page("main") }
    return true
end

-- 对方发来的一句（REL.on.chat 在 REL.on.mend 旁边，转到这里）
function CHAT.recv(rest)
    local s = CHAT.clean(rest)
    if s == "" then return end
    local lb = netuiRead(now()) or {}
    local who = (lb.peername or "") ~= "" and lb.peername or T("对方", "PEER")
    CHAT.add(clipText(who, 16), s, "peer")
end

-- Delete 键 / 面板按钮。面板关着时先打开，发完 / 取消后再关上（CHAT.autoClose，见 editEnd）。
-- 输入框在下一轮 CHAT.step 才开：刚打开的鼠标面板这一轮才建好，建的时候会关掉已经开着的输入框（guiRoot）
function CHAT.open(fromPanel)
    if NETUI.edit then return end            -- 在输入框里按 Delete 是删字
    local okP, paused = pcall(function() return gstat():IsGamePaused(getP1PC()) end)
    if okP and paused == true then return end
    if not CHAT.can(netuiRead(now())) then
        CHAT.add(nil, T("没连上对方，不能聊天", "NOT CONNECTED, CHAT IS OFF"), "sys")
        return
    end
    if not NETUI.open then netuiSetOpen(true, "聊天"); CHAT.autoClose = true
    elseif not fromPanel then CHAT.autoClose = nil end
    CHAT.pending = true
end

function CHAT.close(why)
    netuiSetOpen(false, "聊天" .. tostring(why or ""))
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
        if NETUI.open and not NETUI.edit then
            -- 游戏关了输入法（2026-11-06 实测：点了输入框也切不到中文），中文只能在别处打好再粘贴
            -- §150 同时把面板翻到快捷短语页（每次开聊天重读 phrases.txt），输数字 1–9 回车发那一句
            CHAT.loadPhrases()
            NETUI.page, NETUI.sel = "phrases", 1
            editStart("chat", T("说点什么，或输数字 1–9 回车发快捷短语（中文请在别处打好后 Ctrl+V 粘贴）",
                                "SAY SOMETHING, OR TYPE 1-9 + ENTER FOR A QUICK PHRASE"), "",
                      T("回车发送，Esc 取消", "ENTER TO SEND, ESC TO CANCEL"))
        end
    end
    if HUD.failed then return end
    local all = NETUI.open or (NETUI.edit and NETUI.edit.kind == "chat")
    local t, show = os.time(), {}
    for i = math.max(1, #CHAT.log - CHAT.LINES + 1), #CHAT.log do
        local m = CHAT.log[i]
        if all or t - m.at < CHAT.SHOW_SEC then show[#show + 1] = m end
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

local GUI_TAB = {
    steam = { "Steam 好友", "STEAM" }, lan = { "局域网", "LAN" },
    server = { "服务器大厅", "SERVER" }, steamlobby = { "Steam 大厅", "STEAM LOBBY" }, ai = { "本地 AI", "LOCAL AI" },
    ranked = { "武林盟主", "RANKED" },      -- §110
}

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

-- 每 33ms 一次：按 NETUI.view 摆内容、查点击。点了东西就执行并结束这一轮（内容下一轮按新状态重摆）
local function guiTick(v)
    local okP, paused = pcall(function() return gstat():IsGamePaused(getP1PC()) end)
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
    guiLabel(GUI.hint, v.rooms and T("点房间直接加入；房间每 2 秒自动刷新   Esc / Home 关闭",
                                     "CLICK A ROOM TO JOIN; REFRESHES EVERY 2 S   ESC / HOME CLOSES")
                               or v.rank and T("每页 10 人，按分数排；分数在每局结束后更新   Esc / Home 关闭",
                                               "10 PER PAGE, BY SCORE; UPDATED AFTER EACH MATCH   ESC / HOME CLOSES")
                               or v.stat and T("本赛季武林盟主的计分局；每局结束后更新   Esc / Home 关闭",
                                               "RANKED MATCHES THIS SEASON; UPDATED AFTER EACH MATCH   ESC / HOME CLOSES")
                               or v.rules and T("按服务器的武林盟主代码写的；翻页看完   Esc / Home 关闭",
                                                "FROM THE RANKED SERVER'S CODE; USE THE PAGE BUTTONS   ESC / HOME CLOSES")
                               or T("鼠标点选；也可以 PgUp/PgDn 选、End 确定   Esc / Home 关闭",
                                    "CLICK TO CHOOSE; OR PGUP/PGDN + END   ESC / HOME CLOSES"), COL_LABEL)
    local items = v.items or {}
    -- 房间列表页 / §110 排行榜页 / 统计页：上一页 / 下一页 / 返回 放进底下的翻页栏，不占行；没有的那个按钮变灰、点不了
    local paged = v.rooms or v.rank or v.stat or v.rules
    guiVis(GUI.navBox, paged and 4 or 1)
    if paged then
        local nav = {}
        for i, it in ipairs(items) do if it.nav then nav[it.nav] = { it = it, i = i } end end
        guiLabel(GUI.pageNo, string.format(T("第 %d / %d 页", "PAGE %d / %d"), v.roomPage or 1, v.pages or 1), COL_WHITE)
        for _, k in ipairs({ "prev", "next", "back" }) do
            local p, n = GUI[k], nav[k]
            local it = n and n.it
            local live = it and it.act     -- §91.1 等回话时翻页栏也点不了（以前照样能点，调到空的 act 会崩）
            local text = k == "prev" and T("上一页", "PREV") or k == "next" and T("下一页", "NEXT") or T("返回", "BACK")
            guiVis(p, live and 0 or 3)
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
        for _, t in ipairs(GUI.tabs) do
            if not NETUI.hasMode(t.mode) then guiVis(t, 1)     -- §98 联机程序没有这种方式（发布版的 Steam 两种）：标签藏起
            else
                guiVis(t, 0)
                local cur = t.mode == v.mode
                guiLabel(t, T(GUI_TAB[t.mode][1], GUI_TAB[t.mode][2]), cur and COL_WHITE or COL_GRAY)
                guiBg(t, (cur and BG_SEL) or (v.busy and BG_OFF) or (t.down and BG_DOWN) or (t.hov and BG_HOVER) or BG_ROW)
                if guiClicked(t) and not cur and not v.busy then
                    out("联机面板：点连接方式「%s」", t.mode)
                    NETUI.sel = modeAt
                    NETUI.setMode(t.mode)
                    return
                end
            end
        end
    end
    for i, r in ipairs(GUI.rows) do
        local it = items[i]
        if not it or it.mode or it.nav or it.tabs then
            guiVis(r, 1)
        else
            guiVis(r, it.act and 0 or 3)
            if it.act then
                guiLabel(r, it.label, COL_WHITE)
                local clicked = guiClicked(r)
                if r.entered then NETUI.sel = i; NETUI.selTarget = nil end    -- 鼠标移上去 = 选中（键盘接着从这里走）
                guiBg(r, (r.down and BG_DOWN) or (i == NETUI.sel and BG_SEL) or (r.hov and BG_HOVER) or BG_ROW)
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
    -- §141 观战中、面板关着：PgDn / PgUp 换下一个 / 上一个视角（用户 2026-11-07："有些人没小键盘"）
    if not NETUI.open and (what == "up" or what == "down") and ST.spec and ST.spec.on then
        ST.spec.stepCam(what == "down" and 1 or -1)
        return
    end
    if not NETUI.open then return end
    -- 鼠标面板开着时游戏收不到 Esc（UIOnly），Esc 关面板；文字面板时 Esc 是游戏的菜单键，不管
    if what == "esc" then if GUI.on then netuiSetOpen(false, "Esc") end; return end
    NETUI.selTarget = nil         -- 自己动了光标：下一帧按新位置重新记（不然刷新时会被拉回原来那个房间）
    local it = NETUI.items[NETUI.sel]
    if (what == "up" or what == "down") and NETUI.page == "rooms" and it and it.room then
        -- 房间列表页：在本页第一个房间再往上 = 上一页（选中最后一个房间），最后一个房间再往下 = 下一页（选中第一个）
        local lastRoom = 0
        for i, x in ipairs(NETUI.items) do if x.room then lastRoom = i end end
        local _, rooms = netuiTargets(NETUI.lobby)
        if what == "down" and NETUI.sel == lastRoom and (NETUI.roomPage or 1) < roomPages(rooms) then
            NETUI.roomPage, NETUI.sel = NETUI.roomPage + 1, 1
            return
        elseif what == "up" and NETUI.sel == 1 and (NETUI.roomPage or 1) > 1 then
            NETUI.roomPage, NETUI.sel = NETUI.roomPage - 1, perPage()
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
    return { { c = st, col = col, size = 0.7 }, { c = T("[Home] 联机面板", "[HOME] ONLINE PANEL"), col = COL_LABEL, size = 0.55 } }
end

-- 对局外的提示：先放一次性提示（弃权 / 掉线），再是地图不一致，再是准备面板（用户定：两行，NOT READY 红、READY 绿）
local function idleRows(tn)
    local rk = NET.rkResultRows()     -- §110 武林盟主结算：一般在"胜利 / 败北"画面那几秒里到，回到自由活动时显示
    if rk then MATCH.toast = { rows = rk, till = tn + 6.0 } end
    if MATCH.toast then
        if tn < MATCH.toast.till then return MATCH.toast.rows end
        MATCH.toast = nil
    end
    -- §141 观战者：主机在别的地图时显示"前往主机所在地图"的提示
    if sessionRole() == "spec" and NET.since() < 1.0 and NET.rmap and NET.rmap ~= mapName(getP1()) then return MAPGO.rows(tn) end
    if now() - NET.lastRecvAt >= 1.0 then return nil end
    if PP.on then return PP.rows() end     -- 只在我们的对手连着时提示（只玩 Phantom Pact 的人不受打扰）
    if NET.rmap and NET.rmap ~= mapName(getP1()) then return MAPGO.rows(tn) end   -- v0.24.1 切图提示（MAPGO 段）
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
    local hint = sessionRole() == "host" and T("按 F1 准备      按 F2 把这里设为场地", "F1: READY      F2: SET ARENA HERE")
                                          or T("按 F1 准备", "PRESS F1 TO READY")
    local rows = { { l = T("我方：", "YOU:"), v = s1, col = c1 }, { l = T("对方：", "OPPONENT:"), v = s2, col = c2 },
                   { c = hint, col = COL_LABEL, size = 0.75 } }
    -- v0.25.0 版本不一致只提示、不拦（用户定）：写出对方当前版本（av= 是 v0.22.0 起才有的，没有 = 更旧）
    if NET.rav and NET.rav ~= VERSION then
        local them = NET.rav ~= "" and ("v" .. NET.rav) or T("v0.21 或更旧", "v0.21 OR OLDER")
        rows[#rows + 1] = { c = string.format(T("版本不一致：你 v%s，对方 %s", "VERSION MISMATCH: YOU v%s, OPPONENT %s"), VERSION, them),
                            col = COL_ORANGE, size = 0.6 }
    end
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
    local lost = tn - NET.lastRecvAt
    lobbyStep(p1, tn, lost)
    if MATCH.role == "client" then
        if lost > LOST_SEC then enter(p1, "idle", tn, REL.ended[MATCH.id] and REL.endWhy() or "对方掉线")
        elseif not followHost(p1, tn) then enter(p1, "idle", tn, "主机结束了对局") end
    elseif MATCH.role == "host" then
        if lost > LOST_SEC then
            enter(p1, "idle", tn, "对方掉线")
        elseif MATCH.state == "cd" and tn - MATCH.t0 >= CD_SEC then
            enter(p1, "fight", tn)
        elseif MATCH.state == "fight" then
            local mine, theirs = MATCH.dead == MATCH.round, NET.rdead == MATCH.round
            local tw = not (mine or theirs) and RT.check(tn) or nil       -- §173 时间到：受伤多的判负
            if tw then REL.send("rtime", string.format("%d %d %.0f %.0f", MATCH.id, MATCH.round, RT.info.h, RT.info.c)) end
            if mine or theirs or tw then
                MATCH.win = tw or ((mine and theirs) and "d" or (mine and "c" or "h"))
                if MATCH.win == "h" then MATCH.me = MATCH.me + 1 elseif MATCH.win == "c" then MATCH.op = MATCH.op + 1 end
                enter(p1, "rend", tn)
            end
        elseif MATCH.state == "rend" and tn - MATCH.t0 >= REND_SEC then
            local need = MATCH.toWin or 2
            if MATCH.me >= need or MATCH.op >= need then
                enter(p1, "end", tn)
            else
                MATCH.round = MATCH.round + 1
                enter(p1, "cd", tn)
            end
        elseif MATCH.state == "end" and tn - MATCH.t0 >= END_SEC then
            if ST.spec then pcall(ST.spec.matchOver, MATCH.me >= (MATCH.toWin or 2)) end   -- §141.7 打完换人
            enter(p1, "idle", tn, "打完了")
        end
    elseif lost < 1.0 and not PP.on then
        -- 只跟随新鲜的包：掉线后 NET.rmt 还留着对方最后一包，不判新鲜会"加入→掉线→再加入"来回跳（离线测试抓到）
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
        elseif MATCH.lock and (not LO.IDLE_LOCK or lost > LOST_SEC or not valid(puppet())) and not (ST.spec and ST.spec.on) then   -- §141 观战时留着自己的锁血
            unlockSelf(p1, not LO.IDLE_LOCK and "对局外不锁血" or (valid(puppet()) and "对手断开" or "替身已移除"))
        end
    end

    if not MATCH.role then
        -- net-ui：联机面板开着时盖过准备提示（面板内容不写【提示】日志，操作另有日志）
        local panel = NETUI.open and netuiPanel(tn) or nil
        local rows = panel or idleRows(tn) or netuiIdleRows(tn)
        if rows and not valid(MATCH.text) then textActor(p1) end
        local tx = panel and MATCH.lastIdleTx or hudLog(rows)
        if tx ~= MATCH.lastIdleTx then
            MATCH.lastIdleTx = tx
            if tx then out("【提示】%s", tx) end
        end
        showHud(rows)
        placeText()
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
            if hp and (hp <= DEAD_HP or regen) and MATCH.dead ~= MATCH.round then
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
        showHud(rows)
        placeText()
    end
    syncFaction(false)
    wireUpdate()
end

-- F5：把你现在站的位置和朝向存成 PvP 场地中心。之后发起对局都用它：主机在中心后方 SPAWN_D、客机在前方 SPAWN_D，面对面
local function saveArena()
    local p1 = getP1()
    if not valid(p1) then out("!! 没有玩家1"); return end
    local loc = try("sa loc", function() return p1:K2_GetActorLocation() end)
    local rot = try("sa rot", function() return p1:K2_GetActorRotation() end)
    if not (loc and rot) then return end
    local m = mapName(p1)
    fileWrite(ARENA_FILE, string.format("map=%s\nx=%.1f\ny=%.1f\nz=%.1f\nyaw=%.1f\n", m, loc.X, loc.Y, loc.Z, rot.Yaw))
    out("== 场地已保存：地图 %s，中心 (%.0f, %.0f, %.0f)，朝向 %.0f。主机出生点在你身后 %.0f，客机在你前方 %.0f ==",
        m, loc.X, loc.Y, loc.Z, rot.Yaw, SPAWN_D, SPAWN_D)
    -- v0.15.0（用户："按 F5 选择场地要不要也在这里写一份"）：屏幕上确认一下
    if not MATCH.role then
        MATCH.toast = { rows = { { c = T("场地已保存", "ARENA SAVED"), col = COL_GREEN, size = 1.4 },
                                 { c = T("对局时双方在这里两侧出生", "BOTH PLAYERS SPAWN HERE"), col = COL_LABEL, size = 0.75 } },
                        till = now() + 2.5 }
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
    walkClass(p1, medWord, 40, 60, "[角色]")
    local okS, ps = pcall(function() return pc.PlayerState end)
    for _, e in ipairs({ { "控制器", pc }, { "PlayerState", okS and ps or nil } }) do
        if valid(e[2]) then walkClass(e[2], medWord, 40, 60, "[" .. e[1] .. "]") end
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
                if medWord(n) then walkClass(c, nil, 60, 80, "[组件 " .. (shortName(n) or "?") .. "]") end
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
                local t = propType(p)
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
                local base = propType(p):match("^(%w+)")
                if ({ Int = 1, Float = 1, Double = 1, Bool = 1, Byte = 1, Enum = 1, Name = 1, Str = 1, Object = 1 })[base] then
                    s["." .. n] = fnameOrStr(rawProp(obj, n))
                elseif base == "Array" then
                    local items = {}
                    eachArr(rawProp(obj, n), function(i, e) if i <= 20 then items[#items + 1] = fnameOrStr(e) end end)
                    s["." .. n] = "[" .. table.concat(items, ", ") .. "]"
                end
            end)
        end)
        pcall(function()
            c:ForEachFunction(function(f)
                local n = "?"
                pcall(function() n = f:GetFName():ToString() end)
                local sig = signature(f)
                if #sig == 1 and sig[1].ret and (n:sub(1, 3) == "Get" or n:sub(1, 2) == "Is") then
                    local ok, r = pcall(function() return obj[n](obj) end)
                    if ok then s[n .. "()"] = fnameOrStr(r) end
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
            out("    %s (%s)", fn, sigStr(signature(f)))
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
                        walkClass(o, medWord, 60, 0, "[" .. short .. "]")
                        walkClass(o, function(x) return x:find("Medicine") ~= nil and (x:sub(1, 3) == "Get" or x:sub(1, 2) == "Is") end,
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
                walkClass(w, uiWord, 30, 0, "[根布局 " .. n .. "]")
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
                    walkClass(o, nil, 30, 0, "[" .. cn .. "]")
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
                for _, f in pairs(fs) do if valid(f) then where[#where + 1] = full(f) .. " (" .. sigStr(signature(f)) .. ")" end end
            end
            local okP, pv = pcall(function() return rawProp(p1, fnName) end)
            out("[菜单条件] %s：函数 %d 个 %s；角色上同名属性 = %s", fnName, #where, table.concat(where, " | "),
                okP and anyToStr(pv) or "?")
            -- 只有返回值、没有参数的就调一次（查询类）
            for _, f in pairs((okF and type(fs) == "table") and fs or {}) do
                local sig = valid(f) and signature(f) or {}
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
                walkClass(t[2], fnWord, 40, 120, "[" .. t[1] .. "]")
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
    AUTOHIT.wasFight = MATCH.state == "fight"
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
    local fight = MATCH.state == "fight"
    if AUTOHIT.wasFight and not fight then
        AUTOHIT.pop("回合 / 对局结束", true)
        if AUTOHIT.job then out("== 自动出招 %s 停了（回合结束）==", tostring(AUTOHIT.id)); AUTOHIT.job = nil end
    elseif AUTOHIT.pushMap ~= ST.mapLoadAt then
        AUTOHIT.pop("换了地图", true)
    elseif tn - AUTOHIT.busyAt >= AUTOHIT.IDLE_POP then
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
            dumpAny("  " .. e[1] .. " 当前状态(out)", arr)
            if type(r) == "table" then dumpAny("  " .. e[1] .. " 当前状态(返回)", r) end
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
        dumpAny("  条件表(out)", m)
        if type(r) == "table" then dumpAny("  条件表(返回)", r) end
    end
    out("========== 处决条件表结束 ==========")
end

local function deepDump()
    out("========== 深度 dump ==========")
    local p1, pup = getP1(), puppet()
    for _, e in ipairs({ { "玩家1", p1 }, { "替身", pup } }) do
        if valid(e[2]) then
            dumpAttrs(e[2], e[1])
            local tags = tagsOf(e[2])
            out("[%s] 当前标签(%d): %s", e[1], tags and #tags or -1, tags and table.concat(tags, " ") or "-")
            local abs = abilitiesOf(e[2])
            if abs then
                out("[%s] 技能 %d 个:", e[1], #abs)
                for i, a in ipairs(abs) do out("    [%d] %s", i, a.name) end
            end
        end
    end
    weaponProbe()
    out("-- 阵营函数签名 --")
    for _, f in ipairs({ "GetFactionRelation", "GetFactionRelationWithTag", "SetFactionRelationOverride",
                         "SetFaction", "GetCurrnetFaction" }) do
        dumpFnParams("/Script/SGameCombatSystem.FactionComponent:" .. f)
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
MATCH.autoCreate, MATCH.autoRemove = createPuppet, removePuppet

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
    relationProbe(p1, pup, "改前 玩家1→替身")
    local mon = valid(ST.testMonster) and ST.testMonster or findMonster()
    local vm = mon and factionValue(mon) or nil
    out("参照怪物: %s 阵营=%s", short(pathOf(mon)), mon and factionName(mon) or "?")
    if vm == nil then out("!! 场景里没找到怪物，先按 F12 生成一只"); return end
    local fc = factionComp(pup)
    local ok, err = pcall(function() return fc:SetFaction(vm) end)
    out("SetFaction -> %s %s", tostring(ok), ok and "" or tostring(err))
    out("改后: 替身=%s", factionName(pup))
    relationProbe(p1, pup, "改后 玩家1→替身")
    relationProbe(pup, p1, "改后 替身→玩家1")
    relationProbe(mon, p1, "对照 怪物→玩家1")
    placeInFront(pup, PLACE_DIST)
    out("===== 完成：试试锁定替身、砍它，看日志有没有 [替身] ★ 血量 =====")
end

-- v0.6 实测按名字筛出来的前几个是 AM_Hun_Attack_Failed / *_HD_Attacker* 这类交互动画，不是真攻击；
-- 改成优先用你录制里出现过的 *_Attack_* 动画
local function attackCandidates()
    if ST.atkList and #ST.atkList > 0 then return ST.atkList end
    local list, seen = {}, {}
    for _, f in ipairs(loadRecording(REC_DIR .. "/last.txt") or {}) do
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
    return M4.peerName() or M4.T("对手", "OPPONENT")
end

function OPPBAR.step(tn)
    local function clamp01(x) return math.max(0.0, math.min(1.0, x)) end
    local pup = puppet()
    local mode = NET.barMode()      -- v0.25.0 房间设置：2 血量+杀气 / 1 只显示血 / 0 不显示
    local want = OPPBAR.on and NET.driving and valid(pup) and not M4.ppOn() and mode > 0
    if not want then
        if OPPBAR.actor then
            OPPBAR.hide(not valid(pup) and "替身不在了" or (M4.ppOn() and "Phantom Pact 连着")
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
    local shOn = mode >= 2
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

-- ============================================================ 主循环

local function onTick()
    ST.ticks = ST.ticks + 1
    local okC, errC = pcall(CFG.refresh, now())     -- §158 / §196 联机程序从大厅服务器拿到新数值表了没有（对局外、5 秒看一次文件头）
    if not okC and errC ~= CFG.err then CFG.err = errC; out("!! 数值表刷新出错：%s", tostring(errC)) end
    local p1 = getP1()
    if valid(p1) and not STD.cleaned and ST.stableTicks > 30 then STD.cleanup() end     -- §144 上次没还原的强制配装
    if not valid(p1) then
        if ST.stableTicks > 0 then out("玩家角色不可用（读档/切图？），暂停") end
        ST.stableTicks = 0
        REC.on = false
        stopReplay("玩家不可用")
        ST.setCache, ST.ascCache = {}, {}
        return
    end
    ST.stableTicks = ST.stableTicks + 1
    local okD, errD = pcall(ACC.diag, p1, now())    -- §170.3 饰品份数诊断
    if not okD and errD ~= ACC.dgErr then ACC.dgErr = errD; out("!! 饰品诊断出错：%s", tostring(errD)) end
    local okU, errU = pcall(ACC.dedupe, p1, now())  -- §170.4 替身出来后我身上的饰品多一份 → 去掉
    if not okU and errU ~= ACC.duErr then ACC.duErr = errU; out("!! 饰品去重出错：%s", tostring(errU)) end
    if ST.stableTicks < 90 then return end
    if ST.secondPC ~= nil and not valid(ST.secondPC) then
        out("替身控制器失效（切图？），清掉")
        ST.secondPC, ST.secondPawn, ST.abList = nil, nil, nil
    end

    recordStep()
    replayStep()
    netStep()
    local okB, errB = pcall(OPPBAR.step, now())
    if not okB and errB ~= OPPBAR.err then OPPBAR.err = errB; out("!! 对手血条出错：%s", tostring(errB)) end
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
    local okH, errH = pcall(M4.autoHitStep)     -- §154 测试用自动出招（没有 autohit.on 时直接返回）
    if not okH and errH ~= ST.ahErr then ST.ahErr = errH; out("!! 自动出招出错：%s", tostring(errH)) end
    local okS, errS = pcall(SUMMON.step, p1, puppet(), now())
    if not okS and errS ~= SUMMON.err then SUMMON.err = errS; out("!! 替身召唤物出错：%s", tostring(errS)) end
    local okC, errC = pcall(CHAT.step, now())     -- §112 聊天
    if not okC and errC ~= CHAT.err then CHAT.err = errC; out("!! 聊天出错：%s", tostring(errC)) end

    if ST.ticks % 3 == 0 then
        local monPrev = ST.watch.p1.montage
        watchActor("玩家1", p1, ST.watch.p1)
        -- 玩家1 当前武器 = 最近一次新激活的、能认出武器族的技能
        local abs = ST.watch.p1.abs
        if abs then
            local monNew = ST.watch.p1.montage ~= monPrev and ST.watch.p1.montage or nil
            for n in pairs(abs) do
                if not (ST.p1AbsPrev and ST.p1AbsPrev[n]) then
                    if monNew and isAttackAbility(n) then ANIM.learn(n, monNew) end    -- §100 同一次看到新招 + 新动作
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
    LoopInGameThreadAfterFrames(1, function()
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
        pcall(M4.place)             -- 对局文字挂不上镜头时，每帧摆位
    end)
    ST.feedLoop = true
    out("每帧输入循环已启动")
end

local function startWatchdog()
    if type(LoopAsync) ~= "function" then return end
    LoopAsync(2000, function()
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
            if ST.spec then ST.spec.onMapLoad() end      -- §141 观战原型：旧世界的替身 / 镜头作废（只清 Lua 状态）
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
PROF = { on = true, acc = {}, at = nil, frames = 0, worst = 0, last = nil, REPORT_SEC = 10, IDLE_SEC = 60,
         TOP = { "驱动合计", "驱动·发包帧", "每帧·压受击", "每帧·锁定点", "每帧·摆文字" }, isTop = {}, fcur = 0, fmax = 0, fn = 0, fsum = 0,
         fk = {}, SPIKE_MS = 25, SPIKE_LOGS = 30, spikeLogs = 0 }
for _, k in ipairs(PROF.TOP) do PROF.isTop[k] = true end
function PROF.fin(k, t, ...)
    local d = (os.clock() - t) * 1000
    PROF.acc[k] = (PROF.acc[k] or 0) + d
    PROF.fk[k] = (PROF.fk[k] or 0) + d                       -- §82.5 这一帧各分项（尖峰时写出来）
    if PROF.isTop[k] then PROF.fcur = PROF.fcur + d end     -- §82.4 这一帧模组一共花了多少（单帧尖峰）
    return ...
end
function PROF.wrap(k, fn)
    if type(fn) ~= "function" then return fn end
    return function(...)
        if not PROF.on then return fn(...) end
        local t = os.clock()
        return PROF.fin(k, t, fn(...))
    end
end
out = PROF.wrap("日志", out)
fileWrite, fileReadKV = PROF.wrap("文件·写", fileWrite), PROF.wrap("文件·读", fileReadKV)     -- §82.7 读写分开记（读刚被联机程序替换的文件要等杀毒扫描）
onTick = PROF.wrap("驱动合计", onTick)
NET.sendStep = PROF.wrap("驱动·发包帧", NET.sendStep)
PIPE.send, PIPE.recv = PROF.wrap("·管道发", PIPE.send), PROF.wrap("·管道收", PIPE.recv)     -- §83
recordStep, replayStep, netStep = PROF.wrap("录制", recordStep), PROF.wrap("回放", replayStep), PROF.wrap("网络+替身", netStep)
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

function PROF.frame()
    if ST.travel then PROF.at = nil; return end      -- 切图冻结中：重新开始数
    local c = os.clock()
    if not PROF.at then PROF.at, PROF.last, PROF.frames, PROF.worst, PROF.acc = c, c, 0, 0, {}; return end
    PROF.frames = PROF.frames + 1
    local f = PROF.fcur
    PROF.fcur = 0
    -- §82.5 单帧尖峰：模组这一帧花了 SPIKE_MS 以上，写出这一帧的分项（每次加载最多 SPIKE_LOGS 条）
    if f >= PROF.SPIKE_MS and PROF.spikeLogs < PROF.SPIKE_LOGS then
        PROF.spikeLogs = PROF.spikeLogs + 1
        local its = {}
        for k, v in pairs(PROF.fk) do if v >= 1 then its[#its + 1] = { k, v } end end
        table.sort(its, function(x, y) return x[2] > y[2] end)
        local ps = {}
        for _, it in ipairs(its) do ps[#ps + 1] = string.format("%s %.0f", it[1], it[2]) end
        out("[耗时] 单帧尖峰 %.0f ms：%s", f, table.concat(ps, "，"))
    end
    for k in pairs(PROF.fk) do PROF.fk[k] = nil end
    if f > PROF.fmax then PROF.fmax = f end
    if f > 0.5 then PROF.fn, PROF.fsum = PROF.fn + 1, PROF.fsum + f end
    local gap = (c - PROF.last) * 1000
    PROF.last = c
    if gap > PROF.worst then PROF.worst = gap end
    local el = c - PROF.at
    if el < PROF.REPORT_SEC then return end
    local online = NET.pos and NET.lastRecvAt and (now() - NET.lastRecvAt < 1.0)
    if not online and el < PROF.IDLE_SEC then return end
    local a, total, top = PROF.acc, 0, {}
    for _, k in ipairs(PROF.TOP) do total = total + (a[k] or 0); top[k] = true end
    local items = {}
    for k, v in pairs(a) do
        if v / el >= 0.05 then items[#items + 1] = { k, v } end
    end
    table.sort(items, function(x, y) return x[2] > y[2] end)
    local parts = {}
    for _, it in ipairs(items) do parts[#parts + 1] = string.format("%s %.1f", it[1], it[2] / el) end
    local fps, worst = PROF.frames / el, PROF.worst
    local fAvg, fMax = PROF.fn > 0 and PROF.fsum / PROF.fn or 0, PROF.fmax
    PROF.acc, PROF.at, PROF.frames, PROF.worst, PROF.fmax, PROF.fn, PROF.fsum = {}, c, 0, 0, 0, 0, 0
    out("[耗时] %s 帧率 %.1f（最长一帧 %.0f ms）；模组占游戏线程 %.1f ms/秒，单帧平均 %.1f ms、最多 %.1f ms；分项 ms/秒（有嵌套）：%s",
        online and "联机中" or "未联机", fps, worst, total / el, fAvg, fMax, table.concat(parts, "，"))
end

-- 每帧数帧（单独一个循环，不碰每帧输入循环）
function PROF.start()
    if PROF.started or type(LoopInGameThreadAfterFrames) ~= "function" then return end
    PROF.started = true
    LoopInGameThreadAfterFrames(1, function()
        if PROF.on then
            local okP, errP = pcall(PROF.frame)
            if not okP and errP ~= PROF.err then PROF.err = errP; print("[PBZ_MP] 耗时统计出错：" .. tostring(errP) .. "\n") end
        end
    end)
end
PROF.start()

startDriver()
startWatchdog()
startFeedLoop()
startNoStealthLoop()
pcall(M4.netui, "autostart")   -- v0.18.5：一加载就在后台拉起联机程序，不用等打开面板

-- v0.17.1：键位避开 Phantom Pact 的 F3 / F4 / F5（见文件开头）。旧键位：F3 造替身、F1 状态、F2 探针、F4 准备、F5 存场地
bind(Key.F12, createPuppet, "造替身")      -- v0.17.8：F11 是游戏的全屏切换，改 F12（Steam 会顺带截图）
bind(Key.F9, status, "状态")
-- v0.9.21 实测：方案 A 三个标签 CanActivateNewState 全 false（不是状态机状态），已排除。
-- F4 按下后方案 B 一行日志都没有、也无报错（用户看到角色播了受击动画）—— 改用确定可用的 F2
-- v0.10.8：F2 = 药瓶探针 2（只读）。Respawn Recover Attributes 实测不补药瓶
-- v0.13.5：F2 不绑定。斩马刀实验（会把玩家血量压到一半）只在排查时临时绑：bind(Key.F2, M4.zhanmaTest, "斩马刀对比实验")
-- v0.15.1：F2 = 共享数据探针（只读）。结果：两人的武器组件 / UI 逻辑组件各是各的实例
-- v0.15.2 换装实验（13:22 Claude 自测，结论见 HANDOVER §28）会改玩家的装备槽，只在排查时临时绑：
--   bind(Key.F2, M4.swapTest, "换装实验")
-- v0.16.0 排查用（会改玩家装备，只在排查时临时绑）：bind(Key.F2, LO.debugSwap, "排查：模拟玩家换武器")
-- v0.17.1：F2 让给存场地，探针不再常驻；排查时临时绑一个空键：bind(Key.<键>, M4.shareProbe, "共享数据探针")
bind(Key.F1, M4.start, "准备 / 弃权")
-- v0.10.2：被格挡硬直早已按武器自动选，F5 改成存场地
bind(Key.F2, M4.saveArena, "存 PvP 场地")
bind(Key.F7, toggleRecord, "录制")
bind(Key.F8, startReplay, "回放")
-- v0.11.2：F6 = 移除替身、回到单人。用户确认（2026-11-04）：F3 造第二玩家后游戏菜单打不开，F3 之前正常；
-- 独立角色（F2 实验）菜单正常但打不出伤害、浮在半空，用户决定继续用 2P，需要一个回到单人的办法
-- v0.17.6 debuff 排查（HANDOVER §36），排查时临时绑一个空键：bind(Key.<键>, LO.debuffTest, "排查：debuff 图标")
-- v0.17.7 斩马刀吸血实测（HANDOVER §37），排查时临时绑一个空键：bind(Key.<键>, LO.zmProbe, "排查：斩马刀吸血实测")
bind(Key.F6, function()
    stopReplay("手动停止")
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
-- §112 聊天：Delete（输入框里按 Delete 是删字，CHAT.open 自己跳过）
bind(Key.DEL, function() CHAT.open(false) end, "聊天")
-- §141 观战：小键盘 * 换镜头（侧面中点 / 跟 A / 跟 B / 自由视角）。代码在 pbz_spec.lua；
-- 小键盘数字和 + - 是 PBZ_MC 的。包一层函数：主代码块的 local 已满 200 个
ST.spec = (function()
    local ok, mk = pcall(require, "pbz_spec")
    if not ok then ok, mk = pcall(dofile, ROOT .. "/Scripts/pbz_spec.lua") end
    if not (ok and type(mk) == "function") then out("!! 加载 pbz_spec.lua 失败：%s", tostring(mk)); return nil end
    return mk({ out = out, ST = ST, MATCH = MATCH, G = G, activate = activateOnPuppet, isAttack = isAttackAbility,
                loadRecording = loadRecording, recDir = REC_DIR, LO = LO,
                replayable = replayable, playNamed = playNamed, netCmd = M4.cmd, readKV = fileReadKV, writeFile = fileWrite,
                rulesFile = NET.RULES_FILE, flash = M4.flash, NET = NET, safePlace = M4.safePlace,
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
                end })
end)()
if ST.spec then
    pcall(ST.spec.Q.load)       -- §141.7 排队规矩（net/rules.txt 的 rot= / rotw=）
    -- 用户 2026-11-07："观战只需要保留视角快捷键就可以吧"：进出观战走联机面板（满员房间点"观战"、"断开"离开），
    -- 原型的小键盘 / 开关、. 换动作来源（AI 对打 / 录像包）不再绑；要测原型时临时加回：
    --   bind(Key.DIVIDE, ST.spec.toggle, "观战原型 开 / 关")；bind(Key.DECIMAL, ST.spec.nextSrc, "观战原型 换动作来源")
    bind(Key.MULTIPLY, function() if not M4.panelOpen() then ST.spec.nextCam() end end, "观战 换镜头")     -- 面板开着时不换（同 PgUp / PgDn；NETUI 是 M4 里的）
end
-- v0.18.6：回车 / Esc 只在游戏内输入框打开时有用（确定 / 取消），平时直接忽略
for _, kb in ipairs({ { "PAGE_UP", "up" }, { "PAGE_DOWN", "down" }, { "END", "ok" }, { "RETURN", "enter" }, { "ESCAPE", "esc" } }) do
    bind(Key[kb[1]], function() M4.netui(kb[2]) end, "联机面板 " .. kb[2], true)
end
