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

local VERSION = "0.29.6"
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
HOV = { list = {}, FAR = 5000.0, DROP = 300.0, TRY = 1.0, OK = 1.5, MAX = 30.0, logs = 0, n = 0, unhid = 0 }

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

-- 放到 pos（抬高 20）并悬空
function HOV.hold(actor, pos, why, tn)
    if not valid(actor) then return end
    local key = pathOf(actor)
    local e = HOV.list[key]
    if not e then
        e = { actor = actor, pos = pos, why = why, since = tn, tries = 0 }
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
        elseif tn - e.since > HOV.MAX then
            HOV.list[key] = nil
            G.hover(e.actor, false)
            HOV.log("!! %s：%.0f 秒了地形还是没站住，不再悬空（放回 %d 次）", e.why, HOV.MAX, e.tries)
        elseif e.flying then
            if tn >= e.next then
                G.hover(e.actor, false)
                e.flying, e.okAt = false, tn + HOV.OK
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
        if RMS.pup ~= pathOf(pup) or RMS.cur ~= 0.0 then RMS.pup, RMS.cur = pathOf(pup), 0.0; RMS.set(pup, 0.0) end
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
do
    local okB, T = pcall(require, "pbz_balance")
    if not (okB and type(T) == "table") then okB, T = pcall(function() return dofile(ROOT .. "/Scripts/pbz_balance.lua") end) end
    if okB and type(T) == "table" then
        BAL.FAMILY, BAL.MOVE = T.family or {}, T.moves or {}
        local n = 0
        for _ in pairs(BAL.MOVE) do n = n + 1 end
        out("武器平衡表 pbz_balance.lua：%d 招", n)
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

-- 替身放攻击招时调（AIR.fire，放之前）。返回 系数有没有变（变了调用方马上重写替身攻击力）
function BAL.active() return BAL.on and NET.flagNow("bal") end
function BAL.onFire(name, tn)
    if not BAL.active() then return false end
    local before = BAL.now(tn)
    BAL.prev, BAL.prevAt, BAL.last, BAL.lastAt = BAL.last, BAL.lastAt, name, tn
    return BAL.now(tn) ~= before
end

-- 现在该用的系数：HOLD 秒内放过招 → 这招的（TAIL 秒内的上一招更小就用上一招的）；没有 / 关着 → nil（走原来的影之武装判断）
function BAL.now(tn)
    if not (BAL.active() and BAL.last and tn - BAL.lastAt < BAL.HOLD) then return nil end
    local f, why = BAL.moveScale(BAL.last)
    local name = BAL.last
    if BAL.prev and tn - BAL.prevAt < BAL.TAIL then
        local f2, why2 = BAL.moveScale(BAL.prev)
        if f2 < f then f, why, name = f2, why2, BAL.prev end
    end
    return f, string.format("%s %s ×%.0f%%", name, why or "", f * 100)
end

-- 每次驱动 + 替身放招前：攻击力系数 = 伤害倍率 × （武器平衡系数，没有就按影之武装），写进替身
function LO.rescale(pup, tn)
    LO.atkDm = NET.dmgNow()
    local f, why = BAL.now(tn)
    if f then LO.atkScale, LO.scaleWhy = NET.atkScale(false) * f, why
    else LO.atkScale, LO.scaleWhy = NET.atkScale(ST.pupEdgeAt and tn - ST.pupEdgeAt < LO.EDGE_HOLD), nil end
    LO.apply(pup, NET.ratt)
end

-- 接收：把对方的攻击侧属性整套写进替身。att 变了、换了替身、或每 2 秒（替身自己的 GE 重新聚合会把值改掉）都重写
function LO.apply(pup, att)
    local names = LO.names(pup)
    if not (names and att and att ~= "") then return end
    local attKey = pathOf(pup) .. "|" .. att
    local key = attKey .. "|" .. LO.atkScale
    local first = key ~= LO.appliedKey
    if not first and ST.ticks - (LO.appliedAt or 0) < 60 then return end
    local onlyScale = first and attKey == LO.appliedAttKey      -- 只是系数变了：日志短一点
    local vals = {}
    for n, v in att:gmatch("([%w_]+):([%-%d%.e+]+)") do vals[n] = tonumber(v) end
    local nSet, changed = 0, {}
    for _, n in ipairs(names) do
        local want = (vals[n] or LO.neutral(n)) * (LO.SCALED[n] and LO.atkScale or 1.0)
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
LO.outfitOf, LO.applyOutfit, LO.appcProbe, LO.outfitOk = G.LO.outfitOf, G.LO.applyOutfit, G.LO.appcProbe, G.LO.outfitOk
LO.removeGE, LO.weaponEffects, LO.wgePath = G.LO.removeGE, G.LO.weaponEffects, G.LO.wgePath      -- §118 武器效果同步
LO.activeInstance, LO.funcsLike, LO.callNoArg = G.LO.activeInstance, G.LO.funcsLike, G.LO.callNoArg  -- §119 紫冥剑实验
LO.propsLike, LO.targetingComp, LO.tcSetLock = G.LO.propsLike, G.LO.targetingComp, G.LO.tcSetLock
LO.paramTypes, LO.lockCandidates, LO.paramList, LO.tcStop = G.LO.paramTypes, G.LO.lockCandidates, G.LO.paramList, G.LO.tcStop
LO.spawnFx, LO.fxOn = G.LO.spawnFx, G.LO.fxOn

function LO.short(path) return path and (path:match("([^.]+)$") or path) or "-" end

-- 一个槽位的换装。st = 这个槽位自己的状态（重试节流、换装后核对玩家）
function LO.dressSlot(pup, p1, cwc, slot, want, label, st)
    if not (want and want ~= "") then return end
    local key = pathOf(pup) .. "|" .. want
    local held = LO.heldConfig(pup, slot)
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
        local ok, err = pcall(function() cwc:SetSlotWeapon(slot, idx, cfg) end)
        out("替身换装（%s）SetSlotWeapon(序号 %d) %s → %s：%s", label, idx, LO.short(held), LO.short(want),
            ok and "调用成功" or ("失败 " .. tostring(err)))
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
    local cfg = LO.config(want)
    if not cfg then
        out("替身武器组另一格：对方的 %s 加载不了", want)
        return
    end
    local ok, err = pcall(function() cwc:SetSlotWeapon(LO.slot(), other, cfg) end)
    out("替身武器组另一格 SetSlotWeapon(序号 %d) → %s：%s（当前序号 %d）", other, LO.short(want),
        ok and "调用成功" or ("失败 " .. tostring(err)), cur)
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
    LO.dressSlot(pup, p1, cwc, LO.slot(), NET.rwc, "武器", LO.stMain)
    LO.dressSlot(pup, p1, cwc, LO.slotShachi(), NET.rwcs, "影之武装", LO.stShachi)
    LO.dressOff(pup, cwc)
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
    local key = pathOf(pup) .. "|" .. NET.rpas
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
    for n in NET.rpas:gmatch("[%w_]+") do want[n] = true end
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
    for _, k in ipairs({ "_Hit_", "Knock", "Launch", "Lying", "GetUp", "Hitreact" }) do
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
                           "SustainedBlood", "Sense" }) do
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
    -- §92.7 对方放得出、替身放不出：多半是武器升级（GE 给的 WeaponUpgrade 标签）替身没有。补上再放一次
    if not okFire and CHG.UPG[n] and CHG.upgrade(pup, n, CHG.UPG[n]) then
        okFire = fire(n)
        out("  补了武器升级之后 %s %s", n, okFire and "放出来了" or "还是放不出")
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
    pupAction(use, how .. " 返回=" .. tostring(okFire))
    -- v0.23.4 放不出来时记下替身当时的状态（每招前 3 次），下一轮按这个找原因：手上武器、技能在不在、杀气、在放什么
    if not okFire then
        ST.failN = ST.failN or {}
        ST.failN[use] = (ST.failN[use] or 0) + 1
        if use:match("_Stance_C$") then LO.offKey = nil end     -- v0.26.1 架势放不出：另一格可能被蓝图改回去了，下一轮重装（§76）
        if ST.failN[use] <= 3 then
            local act = {}
            for a in pairs(activeAbilities(pup) or {}) do act[#act + 1] = a end
            out("  !! 替身放不出 %s（第 %d 次）：手上武器 %s，替身有这个技能=%s，杀气 %s/%s，动作 %s，正在放 %s",
                use, ST.failN[use], LO.short(LO.heldConfig(pup) or "?"), tostring(map[use] ~= nil),
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
-- §86 全局伤害倍率（房间设置，docs/PVP_RULES_DESIGN.md §1）：50 / 75 / 100 / 150 / 200 / 300%，默认 100。
-- 伤害由挨打一方的游戏按"替身攻击属性 × 我的防御"算（§30 对 Attack 线性），所以倍率乘在本机替身的 Attack / ShachiAttack 上，
-- 两边各乘各的，对称。同局数：主机定，客机按主机状态包里的 dm= 走（旧版主机没有 dm= → 100）；对局中改设置下一局生效。
-- 存在 net/rules.txt 的 dm= 键；这个文件还放别的规则（ab= 等），读写只动 dm=，别的行原样留着
NET.RULES_FILE, NET.DM_STEPS, NET.dmCfg, NET.rdm = NET_DIR .. "/rules.txt", { 50, 75, 100, 150, 200, 300 }, 100, nil
function NET.dmValid(n)
    for _, v in ipairs(NET.DM_STEPS) do if n == v then return true end end
    return false
end
function NET.dmLoad()
    local t = fileReadKV(NET.RULES_FILE)
    local n = t and tonumber(t.dm)
    if NET.dmValid(n) then NET.dmCfg = n end
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
function NET.dmNext(n)       -- 50 → 75 → 100 → 150 → 200 → 300 → 50
    for i, v in ipairs(NET.DM_STEPS) do if v == n then return NET.DM_STEPS[i % #NET.DM_STEPS + 1] end end
    return 100
end
function NET.dmgPct()        -- 房间设置：主机 / 没联机 = 自己的，客机 = 主机的
    local rk = NET.rkRules()                 -- §110 武林盟主：服务器定的
    if rk then return rk.dm end
    if (MATCH.session and MATCH.session.role) == "client" then return NET.dmValid(NET.rdm) and NET.rdm or 100 end
    return NET.dmCfg
end
function NET.dmgNow()        -- 现在交手用的：对局中 = 开局时定下的 MATCH.dmPct，对局外 = 房间设置
    if MATCH.state ~= "idle" and MATCH.dmPct then return MATCH.dmPct end
    return NET.dmgPct()
end
function NET.atkScale(edge)  -- 替身攻击力系数 = 伤害倍率 × 影之武装系数（v0.23.7）
    return NET.dmgNow() / 100 * (edge and LO.EDGE_SCALE or 1.0)
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
NET.FLAG_KEYS, NET.FLAG_DEF = { "ctr", "bal", "med", "npos" }, { ctr = 1, bal = 0, med = 1, npos = 1 }
NET.flagCfg, NET.rflag = { ctr = 1, bal = 0, med = 1, npos = 1 }, {}
NET.FLAG_WIRE = { med = "medok" }      -- 状态包里的键名和 rules.txt 不同的（med= 被 §103 喝药动作占了）
NET.FLAG_NAME = { ctr = { "红蓝光反击", "RED/BLUE COUNTERS" }, bal = { "武器平衡", "WEAPON BALANCE" }, med = { "血瓶", "HEALING POTIONS" },
                 npos = { "对手位置严格跟随（关 = 动画带位移）", "STRICT OPPONENT POSITION (OFF = ANIMATION-DRIVEN)" } }
function NET.flagLoad()
    local t = fileReadKV(NET.AB_FILE) or {}
    for _, k in ipairs(NET.FLAG_KEYS) do
        local n = tonumber(t[k])
        if n == 0 or n == 1 then NET.flagCfg[k] = n end
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
NET.RES_KEYS, NET.RES_DEF, NET.RES_MAX = { "ult0", "ultx", "sp0", "resm" }, { ult0 = 0, ultx = 100, sp0 = 3, resm = 0 },
                                         { ult0 = 3, ultx = 300, sp0 = 6, resm = 1 }   -- §113.3 默认精纯杀气改 0
NET.RES_STEPS = { ultx = { 0, 25, 50, 75, 100, 150, 200, 300 } }
NET.RES_ATTR = { ult0 = "UltimateChargeCount", sp0 = "SpiritShadow" }
NET.RES_NAME = { ult0 = { "开局精纯杀气", "STARTING ULTIMATE CHARGES" }, ultx = { "精纯杀气获取", "ULTIMATE CHARGE GAIN" },
                 sp0 = { "开局暗源（影之武装）", "STARTING PHANTOM EDGE CHARGES" }, resm = { "开局资源", "STARTING RESOURCES" } }
-- 值显示成文字的（其余显示数字）：{ 中文, 英文 }，调用方自己套 T()（T 在后面才定义）
NET.RES_TEXT = { resm = { [0] = { "每场给一次", "ONCE PER MATCH" }, [1] = { "每局重置", "EVERY ROUND" } } }
NET.resCfg, NET.rres = { ult0 = 0, ultx = 100, sp0 = 3, resm = 0 }, {}
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
    return r
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
        MATCH.ultxSaved = attrOf(p1, a) or false
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
    local v = MATCH.ultxSaved
    MATCH.ultxSaved = nil
    if not (v and valid(p1)) then return end
    local c = attrOf(p1, NET.ULTX_ATTR)
    if c and math.abs(c - v) > 0.001 then NET.resWrite(p1, NET.ULTX_ATTR, v) end
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
-- §110 武林盟主（排位）固定规则：联机程序在 lobby.txt 里给 rk=1（当前连接方式是 ranked）和 rkrules=bo=3;dm=150;med=0;bal=1;ctr=1;ab=0
-- （服务器下发）。这时上面的 NET.bestOf / dmgPct / allBlock / flag 一律按 rkrules 返回，主机、客机一样，不看本机 rules.txt / 主机状态包；
-- 开局 / 跟随时定下 MATCH.* 的地方调的就是它们，不用改。规则还没拿到（rk=1 但 rkrules 空）时不拿本机设置冒充：主机不让开局
-- （F1 / startMatchNow），那时各取值函数照旧。rkrules 里缺的键按原版默认，坏值不认（也按默认）。
-- lobby.txt 在 NETUI 段才读得到（netuiRead），这里先放个空的，那边换掉
NET.RK_DEF = { bo = 3, dm = 100, ab = 0, ctr = 1, bal = 0, med = 1, npos = 1, ult0 = 0, ultx = 100, sp0 = 3, resm = 0 }   -- §113 ult0 / sp0 / resm：服务器不发就是 0 / 3 / 每场（§113.3）；§113.4 ultx 获取倍率 100%；§138 npos 对手位置严格跟随（以前不在表里：排位跟主机自己的设置，固定规则页还误显示"关"）
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
    local fam, rest = n:match("^GA_Hun_(%w+)_(.+)_C$")
    if not fam then return false end
    if NOT_ATTACK_FAM[fam] then return false end
    -- 名字里带这些的一定是攻击，哪怕也带下面的排除词：完美闪避反击 PerfectDodge、切刀斩 SWT（含 SwitchForm*_SWT）、反击 Counter
    if rest:find("PerfectDodge", 1, true) or rest:find("SWT", 1, true) or rest:find("Counter", 1, true) then return true end
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
    out("判定 远端#%d → %s%s", attackId, RES_NAME[kind] or kind,
        (value or 0) > 0 and string.format(" -%.0f", value) or "")
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
    if #NET.judges == 0 and not NET.pendDef and not NET.lastHit then return end
    local hp = hpOf(p1)
    local m = montageOf(p1)
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
            NET.lastHit = { r = addResult("hit", j.id, NET.judgeHp - hp, tn), at = tn }
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
        r.v = r.v + (NET.judgeHp - hp)
        out("判定 远端#%d → 中招 追加 -%.0f（这招累计 -%.0f）", r.atk, NET.judgeHp - hp, r.v)
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
        local me = fire and staggerOn(p1, ST.p1Weapon) or "继续攻击"
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
    if d and d > 0 and TOUCH.counts() then TOUCH.dmg[id] = (TOUCH.dmg[id] or 0) + d * TOUCH.scale(id) end
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
    if BAL.active() then return NET.atkScale(false) * (BAL.moveScale(n)) end
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

-- 受击 / 格挡 / 破防 / 闪避不是这一招的动作，不学
function ANIM.learn(ga, mon)
    if not (ga and mon and mon ~= "") then return end
    for _, k in ipairs({ "_Hit_", "Deflect", "MoTian_Dodge", "_Dead_" }) do
        if mon:find(k, 1, true) then return end
    end
    ANIM.map[ga] = mon
end

function ANIM.expect(ga) return ANIM.map[ga] or ANIM.SEED[ga] end

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
ULT.PAT, ULT.HOLD_TICKS, ULT.held, ULT.dropped, ULT.topped = { "_C_C$" }, 3, {}, 0, 0

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
function CHG.ge(dir, name)            -- 升级 GE 的类路径（主代码块 local 已满，挂在 CHG 上）
    return "/PBZCombatAsset/ActorData/Players/Hun/Weapon/" .. dir .. "/UpgradeData/" .. name .. "." .. name .. "_C"
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
}
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
CHG.SELF = { GA_Hun_ChiRen_C_C = { mon = "Hun_ZhiRen_Unique_Skill_01_Montage", at = 0.75 },
             GA_Hun_FengLeiJian_B_Hold_C = { mon = "Hun_BaiShanDual_Hold_B_02_Montage", at = 1.45 } }
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

-- 每帧：替身按对方的秒数松手；"一直等松手"的招还在蓄力动作上就停掉
function CHG.pupStep(pup, tn)
    for id, f in pairs(CHG.fired) do
        CHG.selfStep(pup, id, f, tn)
        local secs = CHG.rel[id]
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
        elseif f.at and tn - f.at > CHG.JUDGE_MAX + 2 then CHG.fired[id] = nil end
    end
end

-- 判定窗口过了 JUDGE_WIN 时（netJudge）：这一招还要不要等。j = { id, at, name }，pupM = 替身现在的动作
function CHG.keepJudge(j, tn, pupM)
    local age = tn - j.at
    local late = j.name and CHG.LATE[j.name]
    if late and age < late then return true end
    if not (j.name and CHG.isHold(j.name)) or age > CHG.JUDGE_MAX then return false end
    local f = CHG.fired[j.id]
    if f and pupM and pupM ~= "" and f.mon[pupM] then return true end     -- 替身还在播这一招的动作（蓄力 / 出招）
    local secs = CHG.rel[j.id]
    if secs then return age < secs + JUDGE_WIN end
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

-- 每帧调（netStep 驱动替身之后）。没有在记的条目、没有等着松手的替身招时什么都不读
function CHG.step(p1, pup, tn)
    if next(CHG.fired) then CHG.pupStep(pup, tn) end
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
    if ULT.isUlt(e.name) then ULT.topUp(pup) end        -- v0.27.2 对方放成功了才会发来：替身充能至少 1 格
    local before = select(3, LAT.activeMontage(pup))
    if CHG.PRE[e.name] then CHG.upgrade(pup, e.name, CHG.PRE[e.name]); CHG.potDiag(pup, "放之前") end    -- §92.7
    if LO.isEdgeAttack(e.name) then ST.pupEdgeAt = tn end      -- v0.23.7 影之武装伤害系数
    -- §106 武器平衡：放之前就把这招的系数写进替身攻击力（以前等下一次驱动，前摇极短的招可能先出伤害）
    if isAttackAbility(e.name) and BAL.onFire(e.name, tn) then LO.rescale(pup, tn) end
    local ok = activateOnPuppet(pup, e.name, NET.sub, "远端#" .. e.id)
    if isAttackAbility(e.name) then openJudge(p1, e.id, tn, e.name); ST.pupAtkAt = tn end
    if ok and not CHG.isHold(e.name) then LAT.afterFire(pup, e, before, tn) end     -- v0.27.0 追帧（§92 蓄力招不追：跳前摇会把蓄力段跳乱）
    if ok then ANIM.afterFire(pup, e, before, tn) end     -- §100 放成功却没换动作 → 补
    if ok and CHG.isHold(e.name) then CHG.onFire(pup, e, tn) end        -- §92 替身按对方的松手时刻松手
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
    if DGE.nIn and n > DGE.nIn and DGE.isDodge(m) and not REP.on then
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

function ZMX.step(pup, tn)
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
    if ok then ST.pupAtkAt = tn end      -- 召唤也算出招：对方锁定你时接下来 ATK_HOLD 秒对准你
    ZMX.log("紫冥剑实验：对方召唤 %s → 替身 DB 调 %s：%s", sm, fn, ok and "调用成功" or ("失败 " .. tostring(err)))
    if c then
        c.watch, c.summoned = { at = tn + 0.3, t0 = tn, fn = fn }, true
        c.at = tn - ZMX.PAUSE_AT       -- 再给一段 HOLD_MAX，对方可能接着召唤下一件
    end
    return ok, ok and "已调技能召唤" or nil
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

local function netSend(p1, tn)
    local act = activeAbilities(p1, NET.wantAb) or {}
    if NET.prevAbs then
        for n in pairs(act) do
            if not NET.prevAbs[n] and (n:find("Clone", 1, true) or n:find("Summon", 1, true))
                and not n:find("Passive", 1, true) then ST.p1SummonAt = tn end      -- §118 我放了召唤（认替身分身时用）
            if not NET.prevAbs[n] and replayable(n) and not NOCTR.check(p1, n, tn) then   -- §105.3 红蓝光反击关着时拦掉
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
    if hm ~= NET.hrPrev and LO.isSubMontage(hm) then
        NET.subN, NET.subT = (NET.subN or 0) + 1, hm
    end
    -- §118 闪避动作（往哪边翻）：换成新的一个时次数 +1，发 dg=<次数>:<动作名>，对方替身翻同一个方向
    if hm ~= NET.hrPrev and DGE.isDodge(hm) then
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
    if not NET.wgeStr or ST.ticks % 90 == 30 then NET.wgeStr = LO.encodeWge(p1) end    -- §118 武器效果（升级 / 形态 GE）
    -- §109 皮肤（每 3 秒读一次；只在菜单里能换）
    if NET.ofStr == nil or ST.ticks % 90 == 45 then NET.ofStr = LO.encodeOutfit(p1) or "" end
    NET.seq = NET.seq + 1
    fileWrite(F_LOCAL, string.format(
        "v=2\nseq=%d\nmap=%s\nx=%.1f\ny=%.1f\nz=%.1f\nyaw=%.1f\nvx=%.1f\nvy=%.1f\nw=%s\nev=%s\nhp=%.1f\nhpm=%.1f\nres=%s\n"
        .. "mt=%s\narena=%s\ndead=%d\nrdy=%d\nquit=%d\natt=%s\nwc=%s\narm=%d\npas=%s\nwcs=%s\nbrk=%d:%s\nhr=%d:%s\nlk=%d\nsh=%.1f\nshm=%.1f\n",
        NET.seq, mapName(p1), loc.X, loc.Y, loc.Z, rot.Yaw, vx, vy, ST.p1Weapon or "", table.concat(evs, ","),
        hp or -1, hpm or -1, table.concat(res, ","), MATCH.wire.mt, MATCH.wire.arena, MATCH.wire.dead,
        MATCH.wire.rdy, MATCH.wire.quit, NET.attStr or "", NET.wcStr or "", LO.armed(p1) and 1 or 0, NET.pasStr or "", NET.wcsStr or "", NET.brkN or 0, NET.brkM or "-", NET.hrN or 0, NET.hrT or "-",
        NET.myLk(p1),                    -- v0.23.3 lk=1：我锁定着对手（对方据此让替身出招时追着他）；§132 也问瞄准组件
        sh or -1, shm or -1)
        .. AIR.wire(AIR.airOf(p1))      -- v0.24.2 air= / vz=：我在不在空中、竖直速度
        .. "bar=" .. NET.barCfg .. "\n"    -- v0.25.0 我的对手血条档位（只有主机的算数）
        .. "bo=" .. NET.boCfg .. "\n"      -- v0.26.3 我的局数设置（只有主机的算数）
        .. "dm=" .. NET.dmCfg .. "\n"      -- §86 我的伤害倍率设置（只有主机的算数）
        .. "ab=" .. NET.abCfg .. "\n"      -- §87 我的"全部可格挡"设置（只有主机的算数）
        .. "ctr=" .. NET.flagCfg.ctr .. "\n"   -- §105.3 我的"红蓝光反击"设置（只有主机的算数）
        .. "bal=" .. NET.flagCfg.bal .. "\n"   -- §106.5 我的"武器平衡"设置（只有主机的算数）
        .. "medok=" .. NET.flagCfg.med .. "\n"   -- §108 我的"血瓶"设置（只有主机的算数；med= 已经是喝药动作）
        .. "npos=" .. NET.flagCfg.npos .. "\n"  -- §128.2 我的"对手位置严格跟随"设置（只有主机的算数）
        .. "ult0=" .. NET.resCfg.ult0 .. "\nsp0=" .. NET.resCfg.sp0 .. "\nresm=" .. NET.resCfg.resm .. "\n"   -- §113 我的开局精纯杀气 / 暗源 / 每场每局（只有主机的算数）
        .. "ultx=" .. NET.resCfg.ultx .. "\n"   -- §113.4 我的精纯杀气获取倍率 %（只有主机的算数）
        .. "med=" .. (NET.medN or 0) .. ":" .. (NET.medT or "-") .. "\n"   -- §103 喝药动作（次数:动作名）
        .. "sub=" .. (NET.subN or 0) .. ":" .. (NET.subT or "-") .. "\n"   -- §111 技能里面换的动作（紫冥剑召唤；次数:动作名）
        .. "dg=" .. (NET.dgN or 0) .. ":" .. (NET.dgT or "-") .. "\n"     -- §118 闪避动作（次数:动作名）
        .. "wge=" .. (NET.wgeStr or "") .. "\n"                                -- §118 我身上的武器效果 GE（替身也上）
        .. "gd=" .. (BLK.on and 1 or 0) .. "\n"                            -- §104 我在不在格挡（对方据此预测替身的反应）
        .. "tc=" .. TOUCH.wire(tn) .. "\n"                                 -- §107 我哪几招在本机碰到了替身（本地 AI 据此回报）
        .. "td=" .. TOUCH.wireDmg() .. "\n"                                -- §115 这几招在本机打出的伤害（已乘系数，本地 AI 按它扣血）
        .. (NET.ofStr ~= "" and ("of=" .. NET.ofStr .. "\n") or "")        -- §109 我的皮肤（行名:肤色:帽子）
        .. LAT.wire(tn, NET.events)        -- v0.27.0 ts= / tse= / evt=：测往返和包龄
        .. CHG.wire(tn))                   -- §92 rel=<招式号>:<按了几秒>：蓄力招松手
end

-- §83 连着管道：这次驱动之前收到的每个包都按顺序过一遍（LAT.onPacket 每个包一次，包龄 / 往返照算）；
-- 没连：照旧读文件里最新的那一个
local function netRecv(p1, tn)
    local list = PIPE and PIPE.recv()
    if not list then list = { fileReadKV(F_REMOTE) } end
    for _, t in ipairs(list) do NET.recvOne(p1, tn, t) end
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
        LAT.reset(); CHG.reset(); PRED.reset(); DGE.nIn = nil
    end
    if NET.lastSeq == -1 or NET.lastRecvAt < tn - 5 then
        out("开始收到远端 v2 状态 seq=%d 地图=%s 武器=%s", seq, tostring(t.map), tostring(t.w))
        NET.rwcCur, NET.rwcOff = nil, nil       -- v0.26.1 新连接：另一把等对方切一次武器才知道
        -- v0.18.2（17:13 实测）：换了个对手 / 对方重启后序号反而更大时，上面的"序号回退"不触发，招式号还停在上一个对手的 #14，
        -- 新对手的 #1–#14 全被当成"已处理"丢掉。断了 5 秒以上再收到就算新连接，各计数清零（旧事件早超过 EV_KEEP 了）
        NET.lastEvIn, NET.wTried, NET.lastResIn, NET.brkIn, NET.hrIn, NET.medIn, NET.subIn, NET.resAtk = 0, nil, 0, nil, nil, nil, nil, {}
        LAT.reset(); CHG.reset(); PRED.reset(); DGE.nIn = nil      -- §104 换了对手：防住率从先验重新学
    end
    NET.lastSeq, NET.lastRecvAt, NET.rx = seq, tn, NET.rx + 1
    local pktAge = LAT.onPacket(t, tn)                                         -- v0.27.0 往返 / 时钟差 / 包龄
    NET.pos = { X = tonumber(t.x) or 0, Y = tonumber(t.y) or 0, Z = tonumber(t.z) or 0 }
    NET.yaw = tonumber(t.yaw) or 0.0
    local vel = { X = tonumber(t.vx) or 0, Y = tonumber(t.vy) or 0 }
    LAT.onVel(NET.vel, vel, tn)                                                -- v0.27.0 急转 → 暂不外推
    NET.vel = vel
    NET.rmt, NET.rarena, NET.rdead = t.mt, t.arena, tonumber(t.dead) or 0     -- M4 对局字段，matchStep 处理
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
        if NET.subIn and sn > NET.subIn and LO.isSubMontage(sm) and not REP.on then
            local pupS = puppet()
            montageByName(sm, true)
            local called, how = ZMX.onSub(pupS, sm, tn)   -- §119 让替身的技能自己召唤；调成了就不再照播动作
            local okS = called or playNamed(pupS, sm)
            if okS then
                local fid
                for id, f in pairs(CHG.fired) do if f.name == "GA_Hun_ZiMingJian_New_DB_C" and (not fid or id > fid) then fid = id end end
                if fid then CHG.fired[fid].mon[sm] = true end
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
    -- v0.26.1 对方武器组的另一把（§76）：真人在组里两把之间切，上一把拿过的不同武器就是另一格。LO.dressOff 给替身装上
    if NET.rwc and NET.rwc ~= NET.rwcCur then
        if NET.rwcCur then NET.rwcOff = NET.rwcCur end
        NET.rwcCur = NET.rwc
    end
    if t.arm == "1" then NET.rarm = true elseif t.arm == "0" then NET.rarm = false else NET.rarm = nil end
    NET.rwcs = (t.wcs and t.wcs ~= "") and t.wcs or nil -- v0.17.4 对方当前的影之武装
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

    -- v0.27.0 evt=<招式号:对方出招时的 ts>：这招晚到了多久（没有 = 按这一包的包龄）
    local evt = {}
    for id, ts in (t.evt or ""):gmatch("(%d+):(%-?%d+)") do evt[tonumber(id)] = tonumber(ts) end
    local list = {}
    for id, name in (t.ev or ""):gmatch("(%d+):([%w_]+)") do
        local ets = evt[tonumber(id)]
        list[#list + 1] = { id = tonumber(id), name = name, rcv = tn, age = ets and LAT.age(ets, tn) or pktAge }
    end
    table.sort(list, function(a, b) return a.id < b.id end)
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
        if rhpm and rhpm > 0 and math.abs((attrOf(pup, "Health_Max") or 0) - rhpm) > 1 then setAttr(pup, "Health_Max", rhpm) end
        local c = hpOf(pup)
        if c and c > 0 and math.abs(c - rhp) > 1 then
            if rhp > 0 then setAttr(pup, "Health", rhp); ST.pupHpSeen = rhp end   -- §107 校正不算碰到
            if NET.remoteHp ~= rhp then out("替身血量按对方回报校正 %.0f -> %.0f", c, rhp) end
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
        if c and c > 0 and NET.remoteHp and NET.remoteHp > 0 and c < NET.remoteHp - 1 then
            setAttr(pup, "Health", NET.remoteHp)
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
-- 回合归位（只对 AI）、连上时放到主机身边、切图后掉出地图拉回都走这里：
--   1) G.teleportTo（引擎的传送：落点卡进几何体就在附近找空位，找不到返回 false）
--   2) 放不下就沿"起点 → 落点"往起点缩：2/3、1/3 处再试。起点是对方站着的地方（主机身上 / 开局时主机站的点），能站
--   3) 都放不下就留在原地，只记日志，不硬塞
--   4) 放下后 SAFE_GUARD 秒内比落点低 SAFE_FALL 以上（落在地图外的虚空里）→ 放回起点（对方站的地方）；没有起点放回传送前的位置。
--      不优先放回传送前：切图到达时"传送前"就是还没加载出地面的落点（MAPGO 防掉落那种情况）
local SAFE_FALL, SAFE_GUARD = 1500.0, 3.0
local SAFE = { guard = nil }

local function safePlace(actor, target, anchor, yaw, why)
    if not valid(actor) then return nil end
    local from = anchor or try("safe from", function() return actor:K2_GetActorLocation() end)
    local cands = { target }
    if anchor then
        for _, f in ipairs({ 2 / 3, 1 / 3 }) do
            cands[#cands + 1] = { X = anchor.X + (target.X - anchor.X) * f, Y = anchor.Y + (target.Y - anchor.Y) * f,
                                  Z = anchor.Z + (target.Z - anchor.Z) * f }
        end
    end
    for i, c in ipairs(cands) do
        local ok, how = G.teleportTo(actor, c, yaw)
        if ok then
            local cm = rawProp(actor, "CharacterMovement")
            if valid(cm) then pcall(function() cm.Velocity = { X = 0.0, Y = 0.0, Z = 0.0 } end) end
            if from then SAFE.guard = { actor = actor, from = from, z = c.Z, till = now() + SAFE_GUARD, why = why } end
            if i > 1 then out("%s：原落点放不下（会卡进地形），改放到往回缩的第 %d 个点 (%.0f, %.0f, %.0f)", why, i - 1, c.X, c.Y, c.Z) end
            if how then out("%s：%s", why, how) end
            return c
        end
    end
    out("!! %s：%d 个落点都放不下（会卡进地形），留在原地", why, #cands)
    return nil
end

-- lobbyStep 每次调：放下后往下掉太多 → 放回起点 / 原处
function SAFE.step()
    local g = SAFE.guard
    if not g then return end
    if now() > g.till or not valid(g.actor) then SAFE.guard = nil; return end
    local loc = try("safe guard", function() return g.actor:K2_GetActorLocation() end)
    if loc and loc.Z < g.z - SAFE_FALL then
        SAFE.guard = nil
        pcall(function() g.actor:K2_SetActorLocation(g.from, false, {}, true) end)
        local cm = rawProp(g.actor, "CharacterMovement")
        if valid(cm) then pcall(function() cm.Velocity = { X = 0.0, Y = 0.0, Z = 0.0 } end) end
        out("!! %s 之后掉出地图（往下掉了 %.0f，落点外面是虚空？），放回 (%.0f, %.0f, %.0f)", g.why, g.z - loc.Z, g.from.X, g.from.Y, g.from.Z)
    end
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
    for _, r in ipairs(rows) do parts[#parts + 1] = r.c or ((r.l or "") .. " " .. (r.v or "")) end
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

local function syncFaction(force)
    local pup = puppet()
    if not valid(pup) or MATCH.zmHold then return end
    if not force and ST.ticks % 15 ~= 0 then return end
    local want = (MATCH.role and MATCH.state ~= "idle") and FOE or FRIEND
    local cur = factionName(pup)
    if cur == want or (MATCH.facRetryAt and now() < MATCH.facRetryAt) then return end
    local fc = factionComp(pup)
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
SUMMON = { WINDOW = 5.0, EVERY = 6, BG_EVERY = 90, LOG_MAX = 8, kind = {}, nKind = 0, mine = {} }

function SUMMON.set(a, want, why)
    local fc = factionComp(a)
    local ok = valid(fc) and pcall(function() fc:SetFaction({ TagName = FName(want) }) end)
    if ok and want == FOE then setLockTarget(a, getP1()) end
    out("替身的召唤物 %s 阵营 -> %s（%s）：%s", short(a), want, ok and "成功" or "失败", why)
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
        if not valid(a) then SUMMON.mine[p] = nil
        elseif ST.ticks % SUMMON.EVERY == 0 then
            want = want or factionName(pup)
            if factionName(a) ~= want then SUMMON.set(a, want, "跟着替身") end
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
                SUMMON.mine[e.path] = e.actor
                SUMMON.set(e.actor, factionName(pup), string.format("%s，%s", e.cls, link))
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
        if MATCH.flags and MATCH.flags.ctr == false then rules[#rules + 1] = T("无红蓝光反击", "NO RED/BLUE COUNTERS") end   -- §105.3
        if MATCH.flags and MATCH.flags.bal then rules[#rules + 1] = T("武器平衡", "WEAPON BALANCE") end                     -- §106.5
        if MATCH.flags and MATCH.flags.med == false then rules[#rules + 1] = T("禁用血瓶", "NO POTIONS") end                -- §108
        if MATCH.res then   -- §113 / §113.2
            local tx = NET.resText("resm", MATCH.res.resm or 0)
            rules[#rules + 1] = string.format(T("精纯杀气 %d · 暗源 %d（%s）", "ULT %d · EDGE %d (%s)"), MATCH.res.ult0, MATCH.res.sp0, T(tx[1], tx[2]))
            if (MATCH.res.ultx or 100) ~= 100 then rules[#rules] = rules[#rules] .. string.format(T(" · 杀气获取 %d%%", " · ULT GAIN %d%%"), MATCH.res.ultx) end   -- §113.4
        end
        if #rules > 0 then rows[#rows + 1] = { c = table.concat(rules, " · "), col = COL_ORANGE } end
        local rkRow = NET.rkScoreRow()     -- §110 武林盟主：我的积分 / 名次
        if rkRow then rows[#rows + 1] = rkRow end
        rows[#rows + 1] = { c = tostring(math.max(1, math.ceil(CD_SEC - el))), col = COL_WHITE, size = 2.2 }
        return rows
    elseif s == "fight" then
        return el < FIGHT_SHOW and { { c = T("开战！", "FIGHT!"), col = COL_ORANGE, size = 2.4 } } or nil
    elseif s == "rend" then
        local head
        if MATCH.win == "d" then head = { c = T("平局", "DRAW"), col = COL_GRAY, size = 1.8 }
        elseif iWon() then head = { c = T("本回合胜", "ROUND WON"), col = COL_GREEN, size = 1.8 }
        else head = { c = T("本回合负", "ROUND LOST"), col = COL_RED, size = 1.8 } end
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
    elseif code == "cap" then
        return { { c = T("本局不计分", "NOT RATED"), col = COL_GRAY, size = 1.6 },
                 { c = T("今天和这位对手已经记了 3 场", "ALREADY 3 RATED MATCHES WITH THIS OPPONENT TODAY"), col = COL_LABEL },
                 { c = tail, col = COL_LABEL, size = 0.75 } }
    end
    return { { c = string.format(T("武林盟主积分 %s", "RATING %s"), d), col = win == "1" and COL_GREEN or COL_RED, size = 1.8 },
             { c = tail, col = COL_LABEL } }
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
        NET.resApply(p1, "第 " .. MATCH.round .. " 回合倒计时")      -- §113
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
        NET.resApply(p1, "第 " .. MATCH.round .. " 回合开打")        -- §113 倒计时里的回满效果可能补满了它们，开打再写一次
        out("== 第 %d 回合 开打 ==", MATCH.round)
    elseif s == "rend" then
        out("== 第 %d 回合结束：%s（我 %d : %d 对方）==", MATCH.round,
            MATCH.win == "d" and "同时倒下，平局不计分" or (iWon() and "我赢" or "对方赢"), MATCH.me, MATCH.op)
    elseif s == "end" then
        out("== 对局结束：%s %d : %d ==", MATCH.me > MATCH.op and "胜利" or "失败", MATCH.me, MATCH.op)
    elseif s == "idle" then
        out("== 对局结束（%s），回到自由活动 ==", why or "-")
        -- v0.17.10：对局外不再锁血（见下面"陪练保护"），对局一结束就解锁，不管还连没连着
        if not LO.IDLE_LOCK or tn - NET.lastRecvAt > 1.0 then unlockSelf(p1, why or "对局结束") end
        standUp(p1); standUp(puppet())
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
function MAPGO.check(p1)
    local target = NET.rmap
    if not target or target == "" or target == mapName(p1 or getP1()) then return "same" end
    if sessionRole() ~= "client" then return "host" end
    if MATCH.role then return "match" end
    if PP.on then return "pp" end
    if now() - NET.lastRecvAt >= 1.0 then return "lost" end
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
    local was = try("beside from", function() return p1:K2_GetActorLocation() end)
    local pos = safePlace(p1, want, { X = NET.pos.X, Y = NET.pos.Y, Z = NET.pos.Z + 30.0 }, face0, "放到主机身边")
    if not pos then return nil end
    -- §99 同一张大地图里跳得远：落点的地形可能还没加载（20:33 内测"往下掉了 1537"），先悬空等它
    if was and math.sqrt((pos.X - was.X) ^ 2 + (pos.Y - was.Y) ^ 2) > HOV.FAR then
        HOV.hold(p1, { X = pos.X, Y = pos.Y, Z = pos.Z }, "放到主机身边", now())
    end
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
    local target, pos = NET.rmap, { X = NET.pos.X, Y = NET.pos.Y, Z = NET.pos.Z }
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

-- lobbyStep 每次（已连上）调：等待到达 / 超时；到达后的防掉落。返回 true = 刚到达
function MAPGO.step(p1, myMap)
    local tc, arrived = os.time(), false
    local pd = MAPGO.pending
    if pd and myMap == pd.map then
        MAPGO.pending, MAPGO.guardTill, arrived = nil, tc + MAPGO_GUARD, true
        out("== 已到达主机所在地图 %s（用时 %d 秒）==", myMap, tc - pd.at)
    elseif pd and tc - pd.at > MAPGO_TIMEOUT then
        MAPGO.pending = nil
        out("!! 前往 %s 超过 %d 秒还没到（现在在 %s），放弃；可以再试一次", pd.map, MAPGO_TIMEOUT, myMap)
    end
    if MAPGO.guardTill and tc > MAPGO.guardTill then MAPGO.guardTill = nil end
    if MAPGO.guardTill and MATCH.joined and NET.pos and myMap == NET.rmap then
        local loc = try("mapgo loc", function() return p1:K2_GetActorLocation() end)
        if loc and loc.Z < NET.pos.Z - MAPGO_FALL then
            local pos = MAPGO.besideHost(p1)
            if not pos then     -- v0.26.2：身边放不下也不能让人一直掉，最后放到主机站的地方（主机能站）
                pos = { X = NET.pos.X, Y = NET.pos.Y, Z = NET.pos.Z + 30.0 }
                pcall(function() p1:K2_SetActorLocation(pos, false, {}, true) end)
            end
            local cm = rawProp(p1, "CharacterMovement")
            if valid(cm) then pcall(function() cm.Velocity = { X = 0.0, Y = 0.0, Z = 0.0 } end) end
            out("!! 掉出地图（Z %.0f，主机 %.0f）：拉回主机身边 (%.0f, %.0f, %.0f)", loc.Z, NET.pos.Z, pos.X, pos.Y, pos.Z)
        end
    end
    return arrived
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
    local client = sessionRole() == "client"
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
    if tn - NET.lastRecvAt > 1.0 then out("!! 还没连上对手"); return end
    if sessionRole() == "client" and MAPGO.check(p1) ~= "same" then    -- v0.24.1 地图不同：F1 = 前往主机所在地图
        MAPGO.go(p1)
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
REL.on.chat = function(rest) CHAT.recv(rest) end      -- §112 房内聊天（CHAT 在联机面板段）
REL.on.mend = function(rest)      -- 主机：对局打完了、最终比分
    local id, hs, cs = rest:match("^(%d+) (%d+) (%d+)$")
    id = tonumber(id)
    if not id then return end
    REL.ended[id] = { hs = tonumber(hs), cs = tonumber(cs) }
    REL.ended[id - 20] = nil
    out("  主机回报：对局 #%d 结束，主机 %s : %s 客机", id, hs, cs)
end

local function lobbyStep(p1, tn, lost)
    SAFE.step()     -- v0.26.2 放下后掉出地图 → 放回原处（§79）
    HOV.step(tn)    -- §99 悬空等地形加载（客机放到主机身边、替身瞬移到远处）
    if ST.ticks % 30 == 0 then
        local kv = fileReadKV(SESSION_FILE)
        local was = MATCH.session and MATCH.session.role
        MATCH.session = kv
        if kv and kv.role ~= was then out("联机会话：%s（对端 %s）", tostring(kv.role), tostring(kv.peer)) end
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
    if sessionRole() == "client" then MAPGO.step(p1, myMap) end
    if sessionRole() == "client" and not MATCH.joined and NET.pos then
        if NET.rmap and NET.rmap ~= myMap then
            MAPGO.notice(myMap)
        else
            local pos = MAPGO.besideHost(p1)
            MATCH.joined = true
            if pos then out("== 已加入主机：传送到主机身边 (%.0f, %.0f) ==", pos.X, pos.Y)
            else out("== 已加入主机：主机身边放不下，留在原地（自己走过去）==") end
        end
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
    out("联机面板 → 联机窗口：%s %s（id=%s，%s）", cmd, (extra or ""):gsub("\n", " "), id, ok and "已写" or "写失败")
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
    if NETUI.dllOff then return false end
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
    if e.kind == "chat" then CHAT.send(s); return end      -- §112（CHAT.add 自己记日志）
    out("联机面板：输入「%s」→ %s", e.kind == "secret" and "***" or s, e.kind)   -- 密码不进日志
    if e.kind == "join" then NETUI.sel = 1; netuiCmd("join", "target=" .. s .. "\n")
    elseif e.kind == "name" then netuiCmd("name", "name=" .. s .. "\n")
    elseif e.kind == "port" then netuiCmd("port", "port=" .. s .. "\n")
    elseif e.kind == "server" then netuiCmd("server", "server=" .. s .. "\n")
    elseif e.kind == "secret" then netuiCmd("secret", "secret=" .. (s == "-" and "" or s) .. "\n") end
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
    if kind == "full" then
        label = T("[已满] ", "[FULL] ") .. label:gsub(T("  已满", "  full"), "", 1)
    end
    return label
end

-- 能点"加入"的房间：kind = full（已满的房间）和 nohost（§123 在玩但没开房的 Steam 好友）列出来但不算"可加入"
local function roomOpen(t) return t.kind ~= "full" and t.kind ~= "nohost" end

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
                 .. string.format(T("我：%d 分  %s  %d 胜 %d 负  赛季 %s", "ME: %d PTS  %s  %dW %dL  SEASON %s"), me.score, pos, me.w, me.l, me.season),
             col = me.title ~= "" and COL_LABEL or COL_WHITE }
end
-- 规则没到 / 上一局结果 / 错误：说明行（主页、排行榜页）
function NETUI.rankInfo(lb, items)
    if (lb.rkrules or "") == "" then
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

-- 面板里可选的行：{ label, act = function() } ；没有 act 的是说明行。NETUI.page = main / rooms / settings / thanks
local function netuiItems(lb, tn)
    local items = {}
    if not lobbyAlive(lb) then
        if not netuiStarting() then
            items[#items + 1] = { label = T("重新启动联机程序", "RESTART THE ONLINE HELPER"),
                                  act = function() NETUI.tries = 0; netuiLaunch() end }
            items[#items + 1] = { label = T("（还不行：手动打开 Mods\\PBZ_MP\\PBZLobby.exe）", "(STILL NOT: OPEN Mods\\PBZ_MP\\PBZLobby.exe)") }
        end
        return items
    end
    local mode = netuiMode(lb, tn)
    local function page(p) return function() NETUI.page = p; NETUI.sel = 1 end end
    -- v0.27.21 感谢名单（设置里的一页）：参与测试并反馈了 bug 的玩家
    if NETUI.page == "thanks" then
        items[#items + 1] = { label = T("参与测试并反馈了 bug 的玩家（B 站）：", "PLAYERS WHO TESTED AND REPORTED BUGS (BILIBILI):") }
        for _, n in ipairs({ "成步堂芦苇", "谦逊的刘恒宇", "亦如黎明中的花朵_" }) do items[#items + 1] = { label = "  " .. n } end
        items[#items + 1] = { label = T("返回", "BACK"), act = page("settings") }
        return items
    end
    -- §110 武林盟主的排行榜页 / 排位账号页 / 统计页：换走了 ranked 方式（又没在排位房间里）就回主页
    local ranked = mode == "ranked" or lb.rk == "1"
    if (NETUI.page == "rank" or NETUI.page == "rankkey" or NETUI.page == "rankstat") and not ranked then NETUI.page = "main" end
    if NETUI.page == "rank" then NETUI.rankItems(lb, tn, items, page); return items end
    if NETUI.page == "rankstat" then NETUI.statItems(lb, tn, items, page); return items end
    if NETUI.page == "rankkey" then NETUI.rankKeyItems(lb, tn, items, page); return items end
    if NETUI.page == "aiload" then NETUI.aiLoadItems(lb, items, page); return items end     -- §114 AI 装备
    if NETUI.page == "aipick" then NETUI.aiPickItems(lb, items, page); return items end
    -- 房间设置页（用户 2026-11-06"单独出个页面放房间设置"）：主机 / 没联机时点了换值，客机只看主机定的；都是下一局生效
    if NETUI.page == "room" then
        -- v0.25.0 对手血条档位（房间设置，HANDOVER §73）：主机 / 没联机时点一下换下一档；客机只看主机定的
        local BARN = { [2] = T("血量 + 杀气", "HEALTH + SHACHI"), [1] = T("只显示血量", "HEALTH ONLY"), [0] = T("不显示", "HIDDEN") }
        if lb.role == "client" then
            items[#items + 1] = { label = T("对手血条：", "OPPONENT BAR: ") .. BARN[NET.barMode()] .. T("（主机设置）", " (HOST'S SETTING)"),
                                  act = function() netuiFlash(T("对手血条由主机设置", "THE HOST DECIDES THE OPPONENT BAR")) end }
        else
            items[#items + 1] = { label = T("对手血条：", "OPPONENT BAR: ") .. BARN[NET.barCfg] .. T("（主机设置，客机照此显示）", " (HOST SETS IT FOR BOTH)"),
                                  act = function()
                                      local m = (NET.barCfg + 2) % 3     -- 2 → 1 → 0 → 2
                                      NET.barSet(m)
                                      out("联机面板：对手血条设为 %d（%s）", m, BARN[m])
                                  end }
        end
        -- v0.26.3 局数（房间设置）：主机 / 没联机时点一下 3 → 5 → 7 → 9 → 3；客机只看主机定的
        local function boLabel(n) return string.format(T("局数：%d 局 %d 胜", "MATCH: BEST OF %d"), n, NET.toWin(n)) end
        -- §110 武林盟主：局数 / 伤害倍率 / 全部可格挡 / 红蓝光反击 / 武器平衡 / 血瓶 都是服务器定的固定规则（主机客机一样），只显示、点了不改
        if lb.rk == "1" then
            local rk = NET.rkRules()
            local fixed = function() netuiFlash(T("武林盟主的规则由服务器固定，不能改", "RANKED RULES ARE FIXED BY THE SERVER"), COL_ORANGE) end
            if not rk then
                items[#items + 1] = { label = T("（正在从服务器获取排位规则…拿到前不能开局）", "(GETTING THE RANKED RULES FROM THE SERVER...)"), col = COL_ORANGE }
            else
                items[#items + 1] = { label = T("武林盟主固定规则（服务器定）：", "RANKED RULES (SET BY THE SERVER):"), col = COL_LABEL }
                local function onOff(on) return on and T("开", "ON") or T("关", "OFF") end
                items[#items + 1] = { label = boLabel(rk.bo), act = fixed }
                items[#items + 1] = { label = string.format(T("伤害倍率：%d%%", "DAMAGE: %d%%"), rk.dm), act = fixed }
                items[#items + 1] = { label = T("全部可格挡：", "ALL MOVES BLOCKABLE: ") .. onOff(rk.ab == 1), act = fixed }
                for _, k in ipairs(NET.FLAG_KEYS) do
                    local nm = NET.FLAG_NAME[k]
                    items[#items + 1] = { label = T(nm[1] .. "：", nm[2] .. ": ") .. onOff(rk[k] == 1), act = fixed }
                end
                for _, k in ipairs(NET.RES_KEYS) do     -- §113
                    local nm = NET.RES_NAME[k]
                    local tx = NET.resText(k, rk[k])
                    items[#items + 1] = { label = T(nm[1] .. "：", nm[2] .. ": ") .. T(tx[1], tx[2]), act = fixed }
                end
            end
            items[#items + 1] = { label = T("返回", "BACK"), act = page("settings") }
            return items
        end
        if lb.role == "client" then
            items[#items + 1] = { label = boLabel(NET.bestOf()) .. T("（主机设置）", " (HOST'S SETTING)"),
                                  act = function() netuiFlash(T("局数由主机设置", "THE HOST DECIDES THE MATCH LENGTH")) end }
        else
            items[#items + 1] = { label = boLabel(NET.boCfg) .. T("（主机设置，下一局生效）", " (HOST, NEXT MATCH)"),
                                  act = function()
                                      local n = NET.boNext(NET.boCfg)
                                      NET.boSet(n)
                                      out("联机面板：局数设为 %d 局（先赢 %d 回合）", n, NET.toWin(n))
                                  end }
        end
        -- §86 伤害倍率（房间设置）：主机 / 没联机时点一下 50 → 75 → 100 → 150 → 200 → 300 → 50；客机只看主机定的
        local function dmLabel(n) return string.format(T("伤害倍率：%d%%", "DAMAGE: %d%%"), n) end
        if lb.role == "client" then
            items[#items + 1] = { label = dmLabel(NET.dmgPct()) .. T("（主机设置）", " (HOST'S SETTING)"),
                                  act = function() netuiFlash(T("伤害倍率由主机设置", "THE HOST DECIDES THE DAMAGE")) end }
        else
            items[#items + 1] = { label = dmLabel(NET.dmCfg) .. T("（主机设置，下一局生效）", " (HOST, NEXT MATCH)"),
                                  act = function()
                                      local n = NET.dmNext(NET.dmCfg)
                                      NET.dmSet(n)
                                      out("联机面板：伤害倍率设为 %d%%", n)
                                  end }
        end
        -- §87 全部可格挡（房间设置）：主机 / 没联机时点一下开 / 关；客机只看主机定的
        local function abLabel(on) return T("全部可格挡：", "ALL MOVES BLOCKABLE: ") .. (on and T("开", "ON") or T("关", "OFF")) end
        if lb.role == "client" then
            items[#items + 1] = { label = abLabel(NET.allBlock()) .. T("（主机设置）", " (HOST'S SETTING)"),
                                  act = function() netuiFlash(T("全部可格挡由主机设置", "THE HOST DECIDES THIS RULE")) end }
        else
            items[#items + 1] = { label = abLabel(NET.abCfg == 1) .. T("（主机设置，下一局生效）", " (HOST, NEXT MATCH)"),
                                  act = function()
                                      local n = 1 - NET.abCfg
                                      NET.abSet(n)
                                      out("联机面板：全部可格挡设为%s", n == 1 and "开" or "关")
                                  end }
        end
        -- §105.3 红蓝光反击 / §106.5 武器平衡（房间设置）：主机 / 没联机时点一下开 / 关；客机只看主机定的
        for _, k in ipairs(NET.FLAG_KEYS) do
            local nm = NET.FLAG_NAME[k]
            local function lbl(on) return T(nm[1] .. "：", nm[2] .. ": ") .. (on and T("开", "ON") or T("关", "OFF")) end
            if lb.role == "client" then
                items[#items + 1] = { label = lbl(NET.flag(k)) .. T("（主机设置）", " (HOST'S SETTING)"),
                                      act = function() netuiFlash(T(nm[1] .. "由主机设置", "THE HOST DECIDES THIS RULE")) end }
            else
                items[#items + 1] = { label = lbl(NET.flagCfg[k] == 1) .. T("（主机设置，下一局生效）", " (HOST, NEXT MATCH)"),
                                      act = function()
                                          local n = 1 - NET.flagCfg[k]
                                          NET.flagSet(k, n)
                                          out("联机面板：%s设为%s", nm[1], n == 1 and "开" or "关")
                                      end }
            end
        end
        -- §113 开局精纯杀气 0 → 1 → 2 → 3 → 0、§113.4 精纯杀气获取 0% → 25% → … → 300% → 0%、开局暗源 0 → … → 6 → 0、开局资源 每场 ↔ 每局（房间设置）：主机 / 没联机时点一下加一；客机只看主机定的
        for _, k in ipairs(NET.RES_KEYS) do
            local nm = NET.RES_NAME[k]
            local function lbl(n) local tx = NET.resText(k, n); return T(nm[1] .. "：", nm[2] .. ": ") .. T(tx[1], tx[2]) end
            if lb.role == "client" then
                items[#items + 1] = { label = lbl(NET.resOf(k)) .. T("（主机设置）", " (HOST'S SETTING)"),
                                      act = function() netuiFlash(T(nm[1] .. "由主机设置", "THE HOST DECIDES THIS RULE")) end }
            else
                items[#items + 1] = { label = lbl(NET.resCfg[k]) .. T("（主机设置，下一局生效）", " (HOST, NEXT MATCH)"),
                                      act = function()
                                          local n = NET.resNext(k, NET.resCfg[k])
                                          NET.resSet(k, n)
                                          out("联机面板：%s设为 %s", nm[1], NET.resText(k, n)[1])
                                      end }
            end
        end
        items[#items + 1] = { label = T("返回", "BACK"), act = page("settings") }
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
        -- 房间设置（对手血条 / 局数 / 伤害倍率 / 全部可格挡 / 红蓝光反击 / 武器平衡）单独一页（用户 2026-11-06，设置页太长）
        items[#items + 1] = { label = T("房间设置…", "ROOM RULES..."), act = page("room") }
        items[#items + 1] = { label = T("语言：中文", "LANGUAGE: ENGLISH"),
                              act = function() netuiCmd("lang", "lang=" .. (LANG.zh and "en" or "zh") .. "\n") end }
        items[#items + 1] = { label = T("打开电脑上的联机窗口", "OPEN THE DESKTOP WINDOW"), act = function() netuiCmd("show") end }
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
        items[#items + 1] = { label = T("设置…", "SETTINGS..."), act = page("settings") }
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
        items[#items + 1] = { label = T("设置…", "SETTINGS..."), act = page("settings") }
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
            NETUI.rankInfo(lb, items)
        end
    else
        if MAPGO.check() == "ok" then     -- v0.24.1 客机、地图不同、主机地图在地图表里
            items[#items + 1] = { label = T("前往主机所在地图（会自动存档）", "GO TO THE HOST'S MAP (AUTO-SAVES)"),
                                  act = function() MAPGO.go(getP1(), true) end }
        end
        if CHAT.can(lb) then       -- §112
            items[#items + 1] = { label = T("聊天…（Delete）", "CHAT... (DELETE)"), act = function() CHAT.open(true) end }
        end
        items[#items + 1] = { label = T("断开", "DISCONNECT"), act = function() netuiCmd("stop") end }
        if lb.role == "host" then items[#items + 1] = copy end      -- 客机复制自己的地址没用
        NETUI.upnpInfo(lb, items)       -- §129
        if lb.rk == "1" then            -- §110 排位房间里也能看排行榜 / 统计
            items[#items + 1] = { label = T("排行榜…", "LEADERBOARD..."), act = function() NETUI.sel = 1; NETUI.openRank(1) end }
            items[#items + 1] = { label = T("武器与招式统计…", "WEAPON & MOVE STATS..."), act = function() NETUI.sel = 1; NETUI.openStat(nil, 1) end }
            NETUI.rankInfo(lb, items)
        end
    end
    items[#items + 1] = { label = T("设置…", "SETTINGS..."), act = page("settings") }
    return items
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
    local name = NETUI.page == "settings" and T("联机 · 设置", "ONLINE · SETTINGS")
              or NETUI.page == "room" and T("联机 · 房间设置", "ONLINE · ROOM RULES")
              or NETUI.page == "thanks" and T("联机 · 感谢名单", "ONLINE · THANKS")
              or NETUI.page == "aiload" and T("联机 · AI 装备", "ONLINE · AI LOADOUT")
              or NETUI.page == "aipick" and T("联机 · AI 装备 · 选择", "ONLINE · AI LOADOUT · PICK")
              or NETUI.page == "rankkey" and T("联机 · 排位账号", "ONLINE · RANKED ACCOUNT") or T("联机", "ONLINE")
    if NETUI.page == "rank" then        -- §110 排行榜：页码在翻页栏（鼠标面板）/ 标题行（文字面板）
        local sh = NETUI.rankShown or {}
        name = sh.season and string.format(T("武林盟主排行榜  赛季 %s", "RANKED LEADERBOARD  SEASON %s"), sh.season) or T("武林盟主排行榜", "RANKED LEADERBOARD")
        title = string.format(T("排行榜  第 %d/%d 页   [Home] 关闭", "LEADERBOARD  PAGE %d/%d   [HOME] CLOSE"), sh.pg or 1, sh.pages or 1)
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
    if NETUI.page == "rankstat" and lobbyAlive(lb) then     -- 统计页同上（stat = true；页码来自 rkstat）
        local sh = NETUI.statShown or {}
        NETUI.view.stat, NETUI.view.roomPage, NETUI.view.pages = true, sh.pg or 1, sh.pages or 1
    end
    local rows = { { c = title, col = COL_LABEL, size = 0.8 },
                   { c = st, col = col, size = 0.7 } }
    NETUI.selTarget = items[NETUI.sel] and items[NETUI.sel].target or nil
    for i, it in ipairs(items) do
        local sel = i == NETUI.sel and it.act
        rows[#rows + 1] = { c = sel and ("> " .. it.label .. " <") or it.label, col = sel and COL_WHITE or it.col or COL_GRAY, size = 0.7 }
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
local GUI_ROWS = 16           -- 房间设置单独一页后最多 11 项，回到 16；§105.3 / §106.5 曾 16 项 / 18；v0.27.6 设置页已有 12 项，留两行余量；v0.27.21 13 项（感谢名单），14 → 15；§102 14 项（服务器中转），15 → 16
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
            editStart("chat", T("说点什么（发给对方；中文请在别处打好后 Ctrl+V 粘贴）", "SAY SOMETHING TO YOUR OPPONENT"), "",
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
                               or T("鼠标点选；也可以 PgUp/PgDn 选、End 确定   Esc / Home 关闭",
                                    "CLICK TO CHOOSE; OR PGUP/PGDN + END   ESC / HOME CLOSES"), COL_LABEL)
    local items = v.items or {}
    -- 房间列表页 / §110 排行榜页 / 统计页：上一页 / 下一页 / 返回 放进底下的翻页栏，不占行；没有的那个按钮变灰、点不了
    local paged = v.rooms or v.rank or v.stat
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
    -- 回车 / Esc 只给输入框用（不在输入时什么都不做：回车、Esc 是游戏自己的键）
    if NETUI.edit then
        if what == "enter" then editCommit() elseif what == "esc" then editEnd("Esc") end
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
    if now() - NET.lastRecvAt >= 1.0 then return nil end
    if PP.on then return PP.rows() end     -- 只在我们的对手连着时提示（只玩 Phantom Pact 的人不受打扰）
    if NET.rmap and NET.rmap ~= mapName(getP1()) then return MAPGO.rows(tn) end   -- v0.24.1 切图提示（MAPGO 段）
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
            if mine or theirs then
                MATCH.win = (mine and theirs) and "d" or (mine and "c" or "h")
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
        elseif MATCH.lock and (not LO.IDLE_LOCK or lost > LOST_SEC or not valid(puppet())) then
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

return { step = matchStep, start = matchStart, saveArena = saveArena, place = placeTextFrame, medProbe = medProbe,
         zhanmaTest = zhanmaTest, zhanmaCheck = zhanmaCheck,
         npcExperiment = npcExperiment, uiProbe = function(tag) MATCH.uiProbe(tag) end,
         respawnRecover = respawnRecover, medProbe2 = medProbe2, shareProbe = shareProbe, swapTest = swapTest,
         refillPotions = function() refillPotions("F2 手动") end, netui = netuiKey,
         -- v0.24.0 对手血条（OPPBAR，在这个函数外面）要用：Phantom Pact 连着没、对方昵称
         ppOn = function() return PP.on end, T = T,
         -- 2026-11-05 切图冻结（驱动段，在这个函数外面）要用：MAPGO 是这里的局部表，导出同一张表
         mapgo = MAPGO,
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
    local p1 = getP1()
    if not valid(p1) then
        if ST.stableTicks > 0 then out("玩家角色不可用（读档/切图？），暂停") end
        ST.stableTicks = 0
        REC.on = false
        stopReplay("玩家不可用")
        ST.setCache, ST.ascCache = {}, {}
        return
    end
    ST.stableTicks = ST.stableTicks + 1
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
function M4.mapgo.freeze(target, from)
    if valid(puppet()) and MATCH.autoRemove then MATCH.autoRemove() end
    MATCH.autoPup = nil
    ST.feed, ST.feedLeft = nil, 0
    ST.npcStore, ST.npcCtl, ST.p1pc, ST.testMonster = nil, nil, nil, nil   -- 旧世界的，新地图用不上
    OPPBAR.actor, OPPBAR.bar, OPPBAR.last, OPPBAR.nameAt = nil, nil, {}, nil
    ST.travel = { at = os.time(), target = target, from = from, loadedAt = nil, ok = 0 }
    out("== 切图冻结：替身已藏起，加载完之前模组不碰游戏对象 ==")
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
-- §112 聊天：Delete（输入框里按 Delete 是删字，CHAT.open 自己跳过）
bind(Key.DEL, function() CHAT.open(false) end, "聊天")
-- v0.18.6：回车 / Esc 只在游戏内输入框打开时有用（确定 / 取消），平时直接忽略
for _, kb in ipairs({ { "PAGE_UP", "up" }, { "PAGE_DOWN", "down" }, { "END", "ok" }, { "RETURN", "enter" }, { "ESCAPE", "esc" } }) do
    bind(Key[kb[1]], function() M4.netui(kb[2]) end, "联机面板 " .. kb[2], true)
end
