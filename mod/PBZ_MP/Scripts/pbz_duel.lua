-- pbz_duel.lua —— LanBattle 新版 1v1 对决模式逻辑（TASK_duel / HANDOVER §290-§291）
-- 与多人联机基底（pbz_multi.lua）仅通过小服务接口 mp 交互，不直接碰 UE4 / NETP 内部细节。
-- 状态机：idle -> ready -> cd -> fight -> rend -> cd / end -> (8秒后) ready
return function(ctx, mp)
local out = (ctx and ctx.out) or function() end
local T = (ctx and ctx.T) or function(zh, _) return zh end
local nowFn = (ctx and ctx.now) or os.clock

local CD_SEC = 3.0
local REND_SEC = 2.5
local NEXT_WAIT_SEC = 8.0
local RULES_BC_SEC = 3.0
local STATE_BC_SEC = 1.0
local HP_TIE_EPS = 1e-4

local DUEL = {
    -- 配置选项档位（由 pbz_multi cfgLoad/cfgSave 持久化到 net/mp.txt）
    ROTS = { "loser", "both", "fixed" },      -- 11-17 fixed = 只有前两位上场、其他人一直观战（旧版"只观战不排队"）

    state = "idle",      -- idle | ready | cd | fight | rend | end
    loop = false,        -- 房主按 F1 开启轮换后保持为 true，直到手动停或人数 < 2
    mid = 0,
    fa = 0,
    fb = 0,
    round = 0,
    winsA = 0,
    winsB = 0,
    stateAt = 0,
    stateTill = nil,
    remSync = 0,
    remSyncAt = 0,

    order = {},          -- pid 数组（按加入顺序）
    watch = {},          -- [pid] = true 表示"只看不上场"
    myWatch = false,
    readySet = {},       -- [pid] = true（ready 阶段已按 F1 准备）
    stats = {},          -- [pid] = { w = 0, l = 0 } 房间内临时战绩（不落盘、不排位）

    myDown = false,
    downRound = nil,
    downMid = nil,
    fightHp = nil,
    fellA = nil,
    fellB = nil,

    duelCmdSent = false,
    lastSentCap = nil,
    duelLiveSent = false,
    lastSetFa = 0,
    lastSetFb = 0,

    matchStarted = false,
    activeMid = nil,
    wasFighter = false,
    rulesSnappedMid = nil,

    lastWinPid = 0,
    lastLoserPid = 0,
    lastEndWhy = "",
    remoteDuel = false,
    lastBcAt = 0,
    lastBcKey = "",
    lastRuAt = 0,
    lastRemSec = nil,
    tlSec = 0,
    peerPkts = {},       -- [pid] = { hp, hpm, mpd, nm } 状态包快照（测试无替身时也可用）

    appliedKey = nil,    -- 记录已在本机生效的 "mid:round:state" 避免重复触发阶段钩子
    prevHost = nil,
    prevInMp = false,

    -- §307 D1：这一场的场地（房主在第 1 回合 cd 定：F2 存的场地，否则房主当前位置 + 朝向、半径 400）
    arena = nil,         -- { cx, cy, cz, yaw, radius, map }
    arenaMid = nil,
    arenaKv = nil,       -- 发给别人的 "cx:cy:cz:yaw:radius"
    arenaMap = nil,      -- 场地在哪张图（和本地 G.mapName 比，判断观众 / 选手是不是同图）
    lastArenaBc = nil,   -- 上一次经可靠聊天广播的场地
    placedKey = nil,     -- "mid:round"：这一回合已经归位过（场地晚到也不会再挪）
    -- §307 D5：本回合自己掉的血（只算掉，回血不抵）
    dtk = 0,
    dtkMid = nil,
    dtkRound = nil,
    peerDtk = {},        -- [pid] = { mid, rd, v }
    -- §307 D8：这一回合已经播过倒地（按 "mid:round" 去重）
    fellKey = nil,
    -- §307 D3：F1 双击确认（认输 / 房主停止轮换）
    f1Arm = nil,         -- { kind = "surrender" | "stop", at = tn }
    infoCache = nil,     -- 给 BASEHOOK.mp.duelInfo 复用，别每次造表
}

local function ensureStats(pid)
    if not pid or pid <= 0 then return nil end
    local s = DUEL.stats[pid]
    if not s then s = { w = 0, l = 0 }; DUEL.stats[pid] = s end
    return s
end

local function listHas(arr, val)
    for i = 1, #arr do if arr[i] == val then return i end end
    return nil
end

local function listRemove(arr, val)
    for i = #arr, 1, -1 do
        if arr[i] == val then table.remove(arr, i) end
    end
end

local function moveToTail(pid)
    if not pid or pid <= 0 then return end
    listRemove(DUEL.order, pid)
    DUEL.order[#DUEL.order + 1] = pid
end

-- 11-17 用户"旧版有房主设置，其他人只能观战，从 3 号开始永远不下场"：轮换规则 fixed。
-- 房主算：自己没开只看不上场的人里排在前两位的上场，其余的人当只看不上场（不出现、一直观战）；
-- 发给客机的 mdq= 里只看不上场那一位就是这个结果，客机不用知道规则
local function fixedPair()
    return mp.isHost() and mp.cfg() and mp.cfg().duelRot == "fixed"
end
local function personalQueue()
    local q = {}
    for i = 1, #DUEL.order do
        local pid = DUEL.order[i]
        if pid and pid > 0 and not DUEL.watch[pid] then
            q[#q + 1] = pid
        end
    end
    return q
end
function DUEL.isWatch(pid)
    if not pid or pid <= 0 then return false end
    if DUEL.watch[pid] then return true end
    if not fixedPair() then return false end
    local q = personalQueue()
    return pid ~= q[1] and pid ~= q[2]
end
local function activeQueue()
    local q = personalQueue()
    if fixedPair() then q = { q[1], q[2] } end
    return q
end

local function syncRoster(rosterList)
    local present = {}
    local sorted = {}
    for _, p in ipairs(rosterList or {}) do
        local pid = tonumber(p.pid)
        if pid and pid > 0 and not present[pid] then
            present[pid] = true
            sorted[#sorted + 1] = pid
        end
    end
    table.sort(sorted)
    -- 新人按 pid 递增（即加入顺序）追加到队尾
    for _, pid in ipairs(sorted) do
        if not listHas(DUEL.order, pid) then
            DUEL.order[#DUEL.order + 1] = pid
        end
        ensureStats(pid)
    end
    -- 已离开房间的人移出队列与临时表（保留或清理：按离开移除 watch/ready）
    for i = #DUEL.order, 1, -1 do
        local pid = DUEL.order[i]
        if not present[pid] then
            table.remove(DUEL.order, i)
            DUEL.watch[pid] = nil
            DUEL.readySet[pid] = nil
        end
    end
    -- 本地 myWatch 同步给自己对应的 pid（房主或待广播时用）
    local me = mp.myPid()
    if me and me > 0 and DUEL.myWatch then
        DUEL.watch[me] = true
    end
    return present
end

local function sendDuelCmd(fa, fb, live)
    fa = fa or 0
    fb = fb or 0
    if fa ~= DUEL.lastSetFa or fb ~= DUEL.lastSetFb then
        DUEL.lastSetFa, DUEL.lastSetFb = fa, fb
        mp.cmd("duelset", string.format("fa=%d\nfb=%d\n", fa, fb))
    end
    if live ~= nil and live ~= DUEL.duelLiveSent then
        DUEL.duelLiveSent = live
        mp.cmd("duelphase", string.format("live=%d\n", live and 1 or 0))
    end
end

local function fireMatchStart(mid)
    if DUEL.matchStarted and DUEL.activeMid == mid then return end
    if DUEL.matchStarted then
        mp.onMatchEnd(DUEL.activeMid, "重新开始")
    end
    DUEL.matchStarted = true
    DUEL.activeMid = mid
    mp.onMatchStart(mid)
end

local function fireMatchEnd(why)
    if not DUEL.matchStarted then return end
    local mid = DUEL.activeMid
    DUEL.matchStarted = false
    DUEL.activeMid = nil
    mp.onMatchEnd(mid, why or "对局结束")
end

local function remainNow(tn)
    if DUEL.isHostCache then
        if not DUEL.stateTill then return 0 end
        return math.max(0, DUEL.stateTill - tn)
    end
    if not DUEL.remSyncAt or DUEL.remSync <= 0 then return 0 end
    return math.max(0, DUEL.remSync - (tn - DUEL.remSyncAt))
end

local function remSecInt(tn)
    return math.max(0, math.ceil(remainNow(tn)))
end

local function oppOf(myPid)
    if myPid == DUEL.fa then return DUEL.fb end
    if myPid == DUEL.fb then return DUEL.fa end
    return 0
end

-- ---- §307 D1：开战点 / 归位 / 观众摆位 / 同图判定
-- 房主在第 1 回合 cd 定场地：有 F2 存的就用，否则用房主当前位置 + 当前朝向、半径 400。
-- 两位选手沿场地朝向面对面：fa 在中心 − 朝向×半径，fb 在中心 + 朝向×半径；观众同图且离中心 > 30 米时放到侧面 8 米、面朝中心。
local function normYaw(yaw)
    yaw = tonumber(yaw) or 0.0
    return (yaw + 180.0) % 360.0 - 180.0
end

-- §307 D7：HUD 剩余时间用 m:ss；最后 10 秒照旧按秒显示
local function mmss(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end
local function remText(rem)
    rem = math.max(0, math.floor(tonumber(rem) or 0))
    if rem <= 10 then return string.format("[%ds]", rem) end
    return "[" .. mmss(rem) .. "]"
end

local function arenaToken(a)
    if not a then return nil end
    return string.format("%.1f:%.1f:%.1f:%.2f:%.1f", a.cx or 0, a.cy or 0, a.cz or 0, a.yaw or 0, a.radius or 400.0)
end

local function parseArena(tok)
    if type(tok) ~= "string" or tok == "" then return nil end
    local cx, cy, cz, yaw, r = tok:match("^([%d%.%-]+):([%d%.%-]+):([%d%.%-]+):([%d%.%-]+):([%d%.%-]+)$")
    if not cx then return nil end
    return { cx = tonumber(cx) or 0.0, cy = tonumber(cy) or 0.0, cz = tonumber(cz) or 0.0,
             yaw = normYaw(yaw), radius = tonumber(r) or 400.0 }
end

local function setArena(a, map)
    if not (a and a.cx and a.cy and a.cz) then return false end
    a.map = (map and map ~= "") and map or nil
    local kv = arenaToken(a)
    local changed = (DUEL.arenaKv ~= kv or DUEL.arenaMap ~= a.map)
    DUEL.arena, DUEL.arenaKv, DUEL.arenaMap = a, kv, a.map
    return true, changed
end

-- 房主选场地（只在每场第 1 回合 cd 调）
local function pickArenaHost(tn)
    if not mp.isHost() then return end
    local cx, cy, cz, r, yaw, map = mp.getArena()
    if not (cx and cy and cz) then
        local sx, sy, sz, syaw, smap = mp.selfPos()
        if not sx then return end
        cx, cy, cz, r, yaw, map = sx, sy, sz, 400.0, syaw or 0, smap
    end
    setArena({ cx = tonumber(cx) or 0.0, cy = tonumber(cy) or 0.0, cz = tonumber(cz) or 0.0,
               yaw = normYaw(yaw), radius = tonumber(r) or 400.0 }, map)
    DUEL.arenaMid = DUEL.mid
    DUEL.placedKey = nil
    out("对决：第 %d 场第 1 回合场地 中心 (%.0f, %.0f, %.0f)，朝向 %.0f，半径 %.0f，地图 %s",
        DUEL.mid or 0, DUEL.arena.cx, DUEL.arena.cy, DUEL.arena.cz, DUEL.arena.yaw, DUEL.arena.radius,
        tostring(DUEL.arena.map or "?"))
end

local function sameArenaMap()
    local a = DUEL.arena
    if not (a and a.map) then return true end           -- 场地是哪张图不知道：不拦
    local myMap = mp.mapName()
    return not (myMap and myMap ~= a.map)
end

-- 选手每回合 cd 归位（两人沿场地朝向面对面；朝向对方）
local function placeFighterRound(tn)
    local a = DUEL.arena
    if not a then return false end
    local me = mp.myPid()
    if me ~= DUEL.fa and me ~= DUEL.fb then return false end
    if not sameArenaMap() then
        mp.notice(T("你不在对决的地图：连按两次 F1 前往房主所在地图，到了再按 F1 准备", "NOT ON THE DUEL MAP: PRESS F1 TWICE TO GO TO THE HOST'S MAP, THEN F1 TO READY"), "", 4.0)
        return false
    end
    local rad = math.rad(a.yaw or 0.0)
    local side = (me == DUEL.fa) and -1.0 or 1.0
    local x = a.cx + math.cos(rad) * (a.radius or 400.0) * side
    local y = a.cy + math.sin(rad) * (a.radius or 400.0) * side
    local yaw = (me == DUEL.fa) and (a.yaw or 0.0) or normYaw((a.yaw or 0.0) + 180.0)
    mp.placeSelf(x, y, a.cz, yaw, a.cx, a.cy, a.cz)
    DUEL.placedKey = string.format("%d:%d", DUEL.mid or 0, DUEL.round or 0)
    out("对决：我 %s，归位到 (%.0f, %.0f) 朝向 %.0f（场地中心 %.0f, %.0f）", me == DUEL.fa and "fa" or "fb",
        x, y, yaw, a.cx, a.cy)
    return true
end

-- 观众：同图、离场地中心 > 30 米 → 放到侧面 8 米（不在两位选手连线上），面朝中心；不同图提示（D1）
local function placeSpectatorRound(tn)
    local a = DUEL.arena
    if not a then return end
    local me = mp.myPid()
    if me == DUEL.fa or me == DUEL.fb then return end
    local myMap = mp.mapName()
    if a.map and myMap and a.map ~= myMap then
        mp.notice(T("对决在另一张地图（连按两次 F1 前往）", "THE DUEL IS ON ANOTHER MAP (PRESS F1 TWICE TO GO)"), "", 4.0)
        return
    end
    local x, y = mp.selfPos()
    if not (x and y) then return end
    local dx, dy = x - a.cx, y - a.cy
    if dx * dx + dy * dy <= 3000.0 * 3000.0 then return end      -- 30 米内不挪
    local ang = math.rad(a.yaw or 0.0) + math.pi / 2.0            -- 场地朝向的侧面
    local px, py = a.cx + math.cos(ang) * 800.0, a.cy + math.sin(ang) * 800.0
    local face = math.deg((math.atan2 or math.atan)(a.cy - py, a.cx - px))
    mp.placeSelf(px, py, a.cz, face, a.cx, a.cy, a.cz)
    out("对决：观众离场地 %.0f 米，摆到侧面 (%.0f, %.0f) 面朝中心", math.sqrt(dx * dx + dy * dy) / 100.0, px, py)
end

-- 每回合 cd 两人都站起来（选手自己的用 Self，观众 / 另一位用 Peer）
local function standBoth()
    local me = mp.myPid()
    for _, pid in ipairs({ DUEL.fa, DUEL.fb }) do
        if pid and pid > 0 then
            if pid == me then mp.standSelf() else mp.standPeer(pid) end
        end
    end
end

-- §307 D8：按这一回合的赢家给输家播倒地（自己输了用 fallSelf，其余用 fallPeer；平局两边都倒）
local function applyRoundFall(winner, mid, rd)
    mid, rd = mid or DUEL.mid, rd or DUEL.round
    local key = string.format("%d:%d", mid or 0, rd or 0)
    if DUEL.fellKey == key then return end
    DUEL.fellKey = key
    local me = mp.myPid()
    local targets = {}
    if winner == DUEL.fa or winner == DUEL.fb then
        targets[1] = (winner == DUEL.fa) and DUEL.fb or DUEL.fa
    else
        targets = { DUEL.fa, DUEL.fb }
    end
    for _, pid in ipairs(targets) do
        if pid and pid > 0 then
            if pid == me then mp.fallSelf() else mp.fallPeer(pid) end
        end
    end
end

-- §307 D3 / D8：屏幕提示（本地 + 可靠聊天广播一份；旧客户端不认 kind 就忽略）
local function announceText(kind, pid)
    local nm = mp.nameOf(pid)
    if kind == "surr" then
        return string.format(T("%s 认输", "%s SURRENDERS"), nm)
    elseif kind == "leave" then
        return string.format(T("%s 掉线，这一场不计", "%s DISCONNECTED; THIS MATCH DOES NOT COUNT"), nm)
    end
    return nil
end
local function showAnnounce(kind, pid)
    local msg = announceText(kind, pid)
    if msg then mp.notice(msg, msg, 3.5) end
end
local function announce(kind, pid)
    showAnnounce(kind, pid)
    mp.relChat(string.format("t|%s|%d", kind, tostring(pid or 0)))
end

-- 回合 / 一场的结果另发一份（房主当观众时状态包走可靠聊天，这份保证各端都知道赢家 / 输家）
local function sendOutcome(winner, loser, mid, rd)
    mid, rd = mid or DUEL.mid, rd or DUEL.round
    DUEL.lastWinPid, DUEL.lastLoserPid = winner or 0, loser or 0
    mp.relChat(string.format("o|%d|%d|%d|%d", winner or 0, loser or 0, mid or 0, rd or 0))
end

-- §307 D3：F1 双击确认（3 秒内第二次）
local function f1ArmCheck(kind, tn)
    local a = DUEL.f1Arm
    if a and a.kind == kind and tn - (a.at or 0) <= 3.0 then
        DUEL.f1Arm = nil
        return true
    end
    DUEL.f1Arm = { kind = kind, at = tn }
    return false
end

-- 叫号时：选手和房主 / 对手不在同一张图 → 提示（F1 那里会拒绝准备）
local function mapWarnReady()
    if DUEL.state ~= "ready" then return end
    local me = mp.myPid()
    if me ~= DUEL.fa and me ~= DUEL.fb then return end
    local ref = mp.isHost() and oppOf(me) or mp.hostPid()
    if ref and ref > 0 and not mp.sameMapAs(ref) then
        if mp.isHost() then     -- 11-17：房主自己就在对决地图，以前也提示"去房主所在地图"
            mp.notice(string.format(T("对手 %s 不在你这张地图，等对方过来", "OPPONENT %s IS NOT ON YOUR MAP - WAIT FOR THEM"), mp.nameOf(ref)), "", 4.0)
        else
            mp.notice(T("你不在对决的地图：连按两次 F1 前往房主所在地图，到了再按 F1 准备", "NOT ON THE DUEL MAP: PRESS F1 TWICE TO GO TO THE HOST'S MAP, THEN F1 TO READY"), "", 4.0)
        end
    end
end

-- 11-17：不交手的阶段（待机 / 即将对决 / 一场结束）大家都在场上；只看不上场的人一直观战
local freePhaseView
-- 只看不上场的结果变了（房主改轮换规则 / 有人进出改变了前两位）：不交手的阶段马上进 / 出观战
local function recheckView()
    if not (DUEL.state == "idle" or DUEL.state == "ready" or DUEL.state == "end") then return end
    local me = mp.myPid()
    if not me or me <= 0 then return end
    local w = DUEL.myWatch or DUEL.isWatch(me) or false
    if w ~= (DUEL.viewWatch or false) then freePhaseView("只看不上场变了") end
end
function freePhaseView(why)
    local me = mp.myPid()
    local w = DUEL.myWatch or (me and me > 0 and DUEL.isWatch(me)) or false
    DUEL.viewWatch = w
    if w then mp.specStart() else mp.specStop(why) end
end

local function cleanupFighter(why)
    if DUEL.wasFighter then
        local opp = oppOf(mp.myPid())
        if opp > 0 then mp.setPeerFaction(opp, false) end
        mp.pcbOff(why or "结束对决")       -- §307 D6：离开交手撤掉 §261 的战斗状态
        mp.unshield()
        mp.arnUnlock(why or "结束对决")
        mp.rulesEnd(why or "结束对决")
        mp.unlockSelf(why or "观众/闲置不锁血")
        DUEL.wasFighter = false
        DUEL.rulesSnappedMid = nil
    end
    DUEL.myDown = false
    DUEL.downRound = nil
    DUEL.downMid = nil
    DUEL.fightHp = nil
end

-- 本机进入对决阶段时统一执行规则 / 位置 / 观战镜头（房主与客机共用这一处逻辑）
local function applyLocalPhase(tn)
    local st, mid, rd, fa, fb = DUEL.state, DUEL.mid, DUEL.round, DUEL.fa, DUEL.fb
    local key = string.format("%d:%d:%s:%d:%d", mid, rd, st, fa, fb)
    if DUEL.appliedKey == key then return end
    DUEL.appliedKey = key
    if mp.arnRefresh then mp.arnRefresh("对决 " .. tostring(st)) end     -- 11-17 开战点光柱跟着阶段放 / 收

    local myPid = mp.myPid()
    local fighter = myPid > 0 and (myPid == fa or myPid == fb)

    if st == "idle" then
        fireMatchEnd(DUEL.lastEndWhy ~= "" and DUEL.lastEndWhy or "回到待机")
        standBoth()
        cleanupFighter("回到待机")
        freePhaseView("回到待机")
        DUEL.fellA, DUEL.fellB, DUEL.fellKey = nil, nil, nil
        return
    end

    if st == "ready" then
        -- 11-17 用户定（贴近旧版）：叫号（即将对决）时所有人都还在场上、可见；两人都按 F1 开打（倒计时）起其他人才进观战；
        -- 只看不上场的人全程观战
        standBoth()
        cleanupFighter("等待准备")
        freePhaseView("等待准备")
        mapWarnReady()                    -- §307 D1：不在房主那张图 → 提示（F1 准备会拒绝）
        DUEL.fellA, DUEL.fellB, DUEL.fellKey = nil, nil, nil
        return
    end

    if st == "end" then
        fireMatchEnd(DUEL.lastEndWhy ~= "" and DUEL.lastEndWhy or "对局结束")
        cleanupFighter("对局结束")
        freePhaseView("对局结束")      -- 11-17：一场打完所有人再出现（只看不上场的除外）
        -- §307 D7：一场结束（选手看胜负，观众看谁赢）
        if DUEL.lastWinPid and DUEL.lastWinPid > 0 then
            local nm = mp.nameOf(DUEL.lastWinPid)
            if fighter then
                if ctx.notice then
                    ctx.notice(DUEL.lastWinPid == myPid and T("胜利", "VICTORY") or T("败北", "DEFEAT"),
                               DUEL.lastWinPid == myPid and T("你赢下了这一场", "YOU WON THIS MATCH") or T("这一场输了", "YOU LOST THIS MATCH"), 4.0)
                end
            else
                mp.notice(string.format(T("%s 获胜", "%s WINS"), nm), "", 4.0)
            end
        else
            mp.notice(DUEL.lastEndWhy ~= "" and T(DUEL.lastEndWhy, DUEL.lastEndWhy) or T("本场结束", "MATCH ENDED"), "", 4.0)
        end
        return
    end

    -- active match: cd | fight | rend
    mp.pruneNonFighters(fa, fb)
    if st == "cd" then
        fireMatchStart(mid)
        standBoth()                       -- §307 D8：下回合 cd 两人都站起来
        if mp.cancelAllMoves then mp.cancelAllMoves("对决倒计时") end     -- §364 开打前放的招别带进交手
        DUEL.fellA, DUEL.fellB, DUEL.fellKey = nil, nil, nil
        DUEL.dtk, DUEL.dtkMid, DUEL.dtkRound = 0, mid, rd      -- §307 D5：新回合重新累计受伤
        if fighter then
            local opp = oppOf(myPid)
            mp.specStop("上场对决")
            DUEL.wasFighter = true
            if rd == 1 or DUEL.rulesSnappedMid ~= mid then
                mp.rulesSnapshot()
                DUEL.rulesSnappedMid = mid
            end
            mp.refillSelf()
            mp.lockSelf()
            -- §307 D1：每回合都锁操作；有场地就归位（没有场地也锁）
            if DUEL.arena and DUEL.placedKey ~= string.format("%d:%d", mid or 0, rd or 0) then
                placeFighterRound(tn)
            end
            mp.arnLock()
            mp.cdStart()
            mp.rulesBegin("cd", "第 " .. rd .. " 回合倒计时", rd == 1, tn)
            if opp > 0 then mp.setPeerFaction(opp, false) end
            DUEL.myDown = false
            DUEL.downRound = nil
            DUEL.downMid = nil
        else
            cleanupFighter("观众不锁血")
            mp.specStart({ fa, fb }, tn)
            placeSpectatorRound(tn)       -- §307 D1：观众太远就摆到场地侧面
        end
        -- §307 D7：cd 开始（选手和观众都提示）
        if ctx.notice then
            ctx.notice(string.format(T("第 %d 回合", "ROUND %d"), rd), T("3 秒后开打", "STARTS IN 3 S"), 2.5)
        end
    elseif st == "fight" then
        fireMatchStart(mid)
        if fighter then
            local opp = oppOf(myPid)
            mp.specStop("上场对决")
            if not DUEL.wasFighter then
                DUEL.wasFighter = true
                if DUEL.rulesSnappedMid ~= mid then
                    mp.rulesSnapshot()
                    DUEL.rulesSnappedMid = mid
                end
                mp.lockSelf()
            end
            mp.arnUnlock("开打")
            mp.fightStart()
            mp.rulesBegin("fight", "第 " .. rd .. " 回合开打", false, tn)
            if opp > 0 then mp.setPeerFaction(opp, true) end
            DUEL.myDown = false
            DUEL.downRound = nil
            DUEL.downMid = nil
            DUEL.fightHp = select(1, mp.selfHp())
        else
            cleanupFighter("观众不锁血")
            mp.specStart({ fa, fb }, tn)
        end
        mp.notice(T("开战！", "FIGHT!"), "", 1.5)       -- §307 D7：开打（选手和观众）
    elseif st == "rend" then
        if fighter then
            local opp = oppOf(myPid)
            if opp > 0 then mp.setPeerFaction(opp, false) end
            mp.pcbOff("第 " .. tostring(rd) .. " 回合结束")      -- §307 D6：和旧版 rend 一样撤掉战斗状态
            -- §307 D7：回合结果（胜 / 负 / 平局重打）
            if DUEL.lastWinPid and DUEL.lastWinPid > 0 then
                if DUEL.lastWinPid == myPid then
                    mp.notice(T("本回合胜", "ROUND WON"), "", 2.5)
                else
                    mp.notice(T("本回合负", "ROUND LOST"), "", 2.5)
                end
            else
                mp.notice(T("平局，重打", "DRAW - REPLAY"), "", 2.5)
            end
        else
            mp.specStart({ fa, fb }, tn)
            if DUEL.lastWinPid and DUEL.lastWinPid > 0 then
                mp.notice(string.format(T("%s 赢下本回合", "%s WINS THE ROUND"), mp.nameOf(DUEL.lastWinPid)), "", 2.5)
            else
                mp.notice(T("本回合平局，重打", "ROUND DRAW - REPLAY"), "", 2.5)
            end
        end
    end
end

-- 场地比 cd 状态晚到时（可靠聊天 / 状态包分两条路），补一次归位；已经归位过就不再挪
local function placeIfNeeded(tn)
    if DUEL.state ~= "cd" then return end
    local me = mp.myPid()
    local key = string.format("%d:%d", DUEL.mid or 0, DUEL.round or 0)
    if me == DUEL.fa or me == DUEL.fb then
        if DUEL.placedKey ~= key then placeFighterRound(tn) end
    else
        placeSpectatorRound(tn)
    end
end

-- ---- 序列化 / 解析网络消息（状态包 mdu=/mdq= 与 REL @duel:）

local function formatMdu(tn)
    return string.format("%d:%d:%d:%d:%d:%d:%s:%d",
        DUEL.mid or 0, DUEL.fa or 0, DUEL.fb or 0, DUEL.round or 0,
        DUEL.winsA or 0, DUEL.winsB or 0, DUEL.state or "idle", remSecInt(tn))
end

local function formatMdq()
    local parts = {}
    for i = 1, #DUEL.order do
        local pid = DUEL.order[i]
        local st = ensureStats(pid)
        parts[#parts + 1] = string.format("%d:%d:%d:%d:%d",
            pid,
            DUEL.isWatch(pid) and 1 or 0,
            st and st.w or 0,
            st and st.l or 0,
            DUEL.readySet[pid] and 1 or 0)
    end
    return table.concat(parts, ",")
end

local function parseMdq(str)
    if not str or str == "" then
        if str == "" then DUEL.order = {} end
        return
    end
    local ord, watch, rdy = {}, {}, {}
    for tok in str:gmatch("[^,]+") do
        local pid, w, wn, ls, r = tok:match("^(%d+):([01]):(%d+):(%d+):([01])$")
        pid = tonumber(pid)
        if pid and pid > 0 then
            ord[#ord + 1] = pid
            if w == "1" then watch[pid] = true end
            if r == "1" then rdy[pid] = true end
            local st = ensureStats(pid)
            st.w, st.l = tonumber(wn) or 0, tonumber(ls) or 0
        end
    end
    if #ord > 0 then
        DUEL.order = ord
        DUEL.watch = watch
        DUEL.readySet = rdy
        -- 11-17 实测：客机切"只看不上场"的那条消息房主没收到，房主一直按旧的算。房主名单里我的标记和本机对不上就补发（最多 3 次、隔 3 秒）
        local me = mp.myPid()
        if me and me > 0 and not mp.isHost() and listHas(ord, me) then
            local hostW = watch[me] and true or false
            local mine = DUEL.myWatch and true or false
            if hostW ~= mine and (DUEL.watchResendN or 0) < 3 then
                local t = nowFn()
                if not DUEL.watchResendAt or t - DUEL.watchResendAt >= 3.0 then
                    DUEL.watchResendAt = t
                    DUEL.watchResendN = (DUEL.watchResendN or 0) + 1
                    mp.relChat(string.format("w|%d|%d", me, mine and 1 or 0))
                end
            end
            if mine then DUEL.watch[me] = true end
        end
    end
end

local function applyNetState(mduStr, mdqStr, tn, mdaStr, mdmStr)
    if mdqStr ~= nil then parseMdq(mdqStr) end
    if not mduStr or mduStr == "" then return false end
    local mid, fa, fb, rd, wa, wb, st, rem = mduStr:match("^(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%a+):(%d+)$")
    if not st then return false end
    local nMid = tonumber(mid) or 0
    local nFa = tonumber(fa) or 0
    local nFb = tonumber(fb) or 0
    local nRd = tonumber(rd) or 0
    local nWa = tonumber(wa) or 0
    local nWb = tonumber(wb) or 0
    local nRem = tonumber(rem) or 0

    local changed = (DUEL.mid ~= nMid or DUEL.fa ~= nFa or DUEL.fb ~= nFb or DUEL.round ~= nRd or DUEL.state ~= st)
    DUEL.mid, DUEL.fa, DUEL.fb = nMid, nFa, nFb
    DUEL.round, DUEL.winsA, DUEL.winsB = nRd, nWa, nWb
    DUEL.state = st
    DUEL.remoteDuel = true

    if changed or math.abs(remainNow(tn) - nRem) > 1.5 then
        DUEL.remSync = nRem
        DUEL.remSyncAt = tn
    end
    if changed then DUEL.stateAt = tn end
    -- §307 D1：新的第 1 回合前把上一场的旧场地清掉（场地在 a| 里先到的话已经标了 arenaMid，不会被清）
    if st == "ready" and DUEL.arena and DUEL.arenaMid ~= nMid then
        DUEL.arena, DUEL.arenaKv, DUEL.arenaMap, DUEL.lastArenaBc = nil, nil, nil, nil
    end
    -- §307 D1：场地跟着状态一起到（mda= / mdm=；旧客户端不认这两个字段，忽略也不报错）
    local arenaChanged = false
    if mdaStr and mdaStr ~= "" then
        local okA, ch = setArena(parseArena(mdaStr), mdmStr)
        arenaChanged = okA and ch
        if okA then DUEL.arenaMid = nMid end
    end
    applyLocalPhase(tn)
    if arenaChanged then placeIfNeeded(tn) end
    if mp.renameBars then mp.renameBars() end      -- 11-17 头顶"（即将对决）"
    recheckView()
    return true
end

local function broadcastHostState(tn, force)
    if not mp.isHost() or not DUEL.isDuel() then return end
    local mdu = formatMdu(tn)
    local mdq = formatMdq()
    local key = mdu .. "|" .. mdq
    local gap = (DUEL.state == "idle") and 2.5 or STATE_BC_SEC
    if force or key ~= DUEL.lastBcKey or (tn - DUEL.lastBcAt) >= gap then
        DUEL.lastBcAt = tn
        DUEL.lastBcKey = key
        if DUEL.arenaKv and (force or DUEL.arenaKv ~= DUEL.lastArenaBc) then
            DUEL.lastArenaBc = DUEL.arenaKv
            mp.relChat(string.format("a|%d|%s|%s", DUEL.mid or 0, DUEL.arenaKv, tostring(DUEL.arenaMap or "")))
        end
        mp.relChat("s|" .. mdu .. "|" .. mdq)
        if mp.renameBars then mp.renameBars() end
        recheckView()
    end
    if force or (tn - DUEL.lastRuAt) >= RULES_BC_SEC then
        local rkv = mp.hostRulesKv()
        if rkv and rkv ~= "" then
            DUEL.lastRuAt = tn
            mp.relChat("ru|" .. rkv)
        end
    end
end

-- ---- 房主推进状态机

local function resetToIdle(why, tn)
    DUEL.loop = false
    DUEL.state = "idle"
    DUEL.fa, DUEL.fb = 0, 0
    DUEL.round, DUEL.winsA, DUEL.winsB = 0, 0, 0
    DUEL.stateTill = nil
    DUEL.readySet = {}
    DUEL.lastEndWhy = why or ""
    sendDuelCmd(0, 0, false)
    mp.notifyTag("idle")
    applyLocalPhase(tn)
    broadcastHostState(tn, true)
end

local function startReadyPair(fa, fb, tn)
    DUEL.mid = (DUEL.mid or 0) + 1
    DUEL.fa, DUEL.fb = fa, fb
    DUEL.round = 0
    DUEL.winsA, DUEL.winsB = 0, 0
    DUEL.readySet = {}
    DUEL.state = "ready"
    DUEL.stateAt = tn
    DUEL.stateTill = nil          -- 11-17：叫号后没有期限，一直等两人按 F1
    DUEL.lastEndWhy = ""
    DUEL.lastWinPid, DUEL.lastLoserPid = 0, 0
    -- §307 D1：新一场由房主在第 1 回合 cd 重新选场地（上一场的作废）
    DUEL.arena, DUEL.arenaKv, DUEL.arenaMap, DUEL.arenaMid = nil, nil, nil, nil
    DUEL.lastArenaBc, DUEL.placedKey = nil, nil
    DUEL.fellKey, DUEL.peerDtk = nil, {}
    -- 11-17 排查补齐：叫号时就定场地（以前第 1 回合倒计时才定），即将对决时两边就能看到蓝 / 橙开战点光柱（同旧版 1v1）
    if mp.isHost() then pickArenaHost(tn) end
    sendDuelCmd(fa, fb, false)
    mp.notifyTag("idle")
    applyLocalPhase(tn)
    broadcastHostState(tn, true)
end

local function startRoundCd(rd, tn)
    DUEL.round = rd
    DUEL.state = "cd"
    DUEL.stateAt = tn
    DUEL.stateTill = tn + CD_SEC
    DUEL.tlSec = mp.tlLimit()
    if rd == 1 and mp.isHost() and not (DUEL.arena and DUEL.arenaMid == DUEL.mid) then pickArenaHost(tn) end      -- §307 D1：房主第 1 回合定场地（11-17 起叫号时已定，这里兜底）
    -- 11-17：倒计时起就算开打（联机程序 live=1 → 只有两位选手发包、其他人看不到也不发），以前到交手才 live
    if mp.isHost() then sendDuelCmd(DUEL.fa, DUEL.fb, true) end
    mp.notifyTag("cd")
    applyLocalPhase(tn)
    broadcastHostState(tn, true)
end

local function startFight(tn)
    DUEL.state = "fight"
    DUEL.stateAt = tn
    local tl = DUEL.tlSec and DUEL.tlSec > 0 and DUEL.tlSec or mp.tlLimit()
    DUEL.tlSec = tl
    DUEL.stateTill = (tl and tl > 0) and (tn + tl) or nil
    sendDuelCmd(DUEL.fa, DUEL.fb, true)
    mp.notifyTag("fight")
    applyLocalPhase(tn)
    broadcastHostState(tn, true)
end

local function finishMatch(winnerPid, loserPid, why, tn)
    local mid, rd = DUEL.mid, DUEL.round
    if winnerPid and winnerPid > 0 and loserPid and loserPid > 0 then
        local sw, sl = ensureStats(winnerPid), ensureStats(loserPid)
        if sw then sw.w = sw.w + 1 end
        if sl then sl.l = sl.l + 1 end
        local rot = (mp.cfg() and mp.cfg().duelRot) or "loser"
        if rot ~= "fixed" then         -- fixed：前两位一直是这两位，不轮换
            moveToTail(loserPid)
            if rot == "both" then moveToTail(winnerPid) end
        end
        applyRoundFall(winnerPid, mid, rd)       -- §307 D8：最后这一回合也按输家播倒地
    end
    DUEL.lastEndWhy = why or "对局结束"
    -- §307 D7 / D8：先把赢家 / 输家发给各端（状态包 mdw= 也会带一份），旧客户端不认就不认
    sendOutcome(winnerPid or 0, loserPid or 0, mid, rd)
    DUEL.state = "end"
    DUEL.stateAt = tn
    DUEL.stateTill = DUEL.loop and (tn + NEXT_WAIT_SEC) or nil
    sendDuelCmd(DUEL.fa, DUEL.fb, false)
    mp.notifyTag("idle")
    applyLocalPhase(tn)
    broadcastHostState(tn, true)
end

-- §307 D2：房主从 ready 进 cd 前复核两位选手的禁用武器 / 影之武装。
-- 不过 = 那位当作没准备（走现有的准备超时换人路径），横幅点名，并给本人发一条提示。
local function tellPid(pid, code)
    if not (pid and pid > 0) then return end
    mp.relChat(string.format("e|%d|%s", pid, code))
end

local function wbanGateBeforeCd(tn)
    if not mp.wbanGateMulti then return true end
    local me = mp.myPid()
    local meFighter = (me == DUEL.fa or me == DUEL.fb)
    if meFighter then
        local okSelf, msgSelf = mp.wbanGateMulti({})       -- 房主自己也是选手：先查自己
        if not okSelf then
            DUEL.readySet[me] = nil
            mp.notice(msgSelf, msgSelf, 4.0)
            broadcastHostState(tn, true)
            return false
        end
    end
    -- 验收改：房主是观众时 gateMulti 带 skipSelf（不查房主自己），下面照样逐个查两位选手；
    -- 原来这里直接 return true，房主装着禁用武器时两位选手就完全不查了
    local bad = false
    for _, pid in ipairs({ DUEL.fa, DUEL.fb }) do
        if pid > 0 and pid ~= me and DUEL.readySet[pid] then
            local ok, msg = mp.wbanGateMulti({ [pid] = true }, not meFighter)
            if not ok then
                DUEL.readySet[pid] = nil
                bad = true
                mp.notice(msg, msg, 4.0)
                tellPid(pid, "wban")
                out("对决：%d 号复核没通过（%s），当作没准备", pid, tostring(msg))
            end
        end
    end
    if bad then broadcastHostState(tn, true); return false end
    return true
end

local function tryStartCd(tn)
    if not (DUEL.readySet[DUEL.fa] and DUEL.readySet[DUEL.fb]) then return false end
    if not wbanGateBeforeCd(tn) then return false end
    startRoundCd(1, tn)
    return true
end

local function callNextMatch(tn, reason)
    local q = activeQueue()
    if #q < 2 then
        resetToIdle(reason or "可上场人数不足 2 人", tn)
        mp.toast("可上场人数不足 2 人，暂停轮换", "FEWER THAN 2 ELIGIBLE PLAYERS; PAUSED")
        return false
    end
    startReadyPair(q[1], q[2], tn)
    return true
end

local function resolveFightHp(pid, pkt)
    if pid == mp.myPid() then
        local hp, hpm = mp.selfHp()
        return hp, hpm
    end
    if pkt then return pkt.hp, pkt.hpm end
    return nil, nil
end

local function isFighterDown(pid, pkt)
    local tag = string.format("%d:%d", DUEL.mid, DUEL.round)
    if pid == mp.myPid() then
        return DUEL.myDown and DUEL.downMid == DUEL.mid and DUEL.downRound == DUEL.round
    end
    return pkt and pkt.mpd == tag
end

local function resolvePkt(pid)
    local pkt = mp.peerPacket(pid)
    if pkt then return pkt end
    return DUEL.peerPkts[pid]
end

-- §307 D5：这一回合自己掉了多少血（只算掉；对手旧版没发 dtk= 就是 nil → 退回血量比）
local function takenOf(pid, pkt)
    if pid == mp.myPid() then
        if DUEL.dtkMid == DUEL.mid and DUEL.dtkRound == DUEL.round then return DUEL.dtk end
        return nil
    end
    local d = DUEL.peerDtk[pid]
    if d and d.mid == DUEL.mid and d.rd == DUEL.round then return d.v end
    return nil
end

local function tickHost(tn)
    local present = syncRoster(mp.roster())

    -- 掉线 / 离开检查（ready / cd / fight / rend）
    if DUEL.state == "ready" or DUEL.state == "cd" or DUEL.state == "fight" or DUEL.state == "rend" then
        local aOk = DUEL.fa > 0 and present[DUEL.fa]
        local bOk = DUEL.fb > 0 and present[DUEL.fb]
        if not aOk or not bOk then
            if DUEL.state == "ready" then
                DUEL.fa, DUEL.fb = 0, 0
                DUEL.readySet = {}
                if DUEL.loop then
                    callNextMatch(tn, "待选选手离开")
                else
                    resetToIdle("待选选手离开", tn)
                end
                return
            else
                local survivor = aOk and DUEL.fa or (bOk and DUEL.fb or 0)
                local leaver = aOk and DUEL.fb or DUEL.fa
                -- §307 D8：选手中途离开（MP.members 名单里没了）= 这一场不计胜负（同旧版"对方掉线，对局取消"），
                -- 留下的选手留在队首，8 秒后叫下一位（finishMatch 0/0 不记战绩、不轮换）
                out("对决：选手 pid=%d 离开房间，这一场不计（留下的 pid=%d）", leaver, survivor)
                announce("leave", leaver)
                finishMatch(0, 0, "选手离开，本场取消", tn)
                if #activeQueue() < 2 then
                    DUEL.loop = false
                    DUEL.stateTill = nil
                end
                return
            end
        end
    end

    if DUEL.state == "ready" then
        -- 若某位被点名选手切了只看不上场，立即重抽
        if DUEL.watch[DUEL.fa] or DUEL.watch[DUEL.fb] then
            callNextMatch(tn, "选手切为观战")
            return
        end
        if DUEL.readySet[DUEL.fa] and DUEL.readySet[DUEL.fb] then
            if tryStartCd(tn) then return end      -- §307 D2：进 cd 前房主再复核禁用武器 / 影之武装
        end
        -- 11-17 用户："30 秒自动轮换机制去掉，人不在房主可以给他换下去"：叫号后一直等两人按 F1，不再准备超时换人
        -- （房主在成员页调顺序换人；对决不再用房间设置"轮到的人不准备多久算放弃"）
    elseif DUEL.state == "cd" then
        if DUEL.stateTill and tn >= DUEL.stateTill then
            startFight(tn)
            return
        end
    elseif DUEL.state == "fight" then
        local pktA = resolvePkt(DUEL.fa)
        local pktB = resolvePkt(DUEL.fb)
        local downA = isFighterDown(DUEL.fa, pktA)
        local downB = isFighterDown(DUEL.fb, pktB)

        local roundWin = nil   -- 0 = 平局重打，fa / fb = 胜方 pid
        local why = nil
        if downA and downB then
            roundWin, why = 0, "双方同时倒下，平局重打"
        elseif downA then
            roundWin, why = DUEL.fb, "击倒"
        elseif downB then
            roundWin, why = DUEL.fa, "击倒"
        elseif DUEL.stateTill and tn >= DUEL.stateTill then
            -- §307 D5：先比这一回合各自掉的血（多的输，一样平局）；对手旧版没发 dtk= 才退回血量百分比
            local ta, tb = takenOf(DUEL.fa, pktA), takenOf(DUEL.fb, pktB)
            if ta and tb then
                if ta < tb - HP_TIE_EPS then
                    roundWin, why = DUEL.fa, string.format(T("时间到，本回合受伤少者胜（%.0f : %.0f）", "TIME UP, LESS DAMAGE TAKEN WINS (%.0f : %.0f)"), ta, tb)
                elseif tb < ta - HP_TIE_EPS then
                    roundWin, why = DUEL.fb, string.format(T("时间到，本回合受伤少者胜（%.0f : %.0f）", "TIME UP, LESS DAMAGE TAKEN WINS (%.0f : %.0f)"), tb, ta)
                else
                    roundWin, why = 0, string.format(T("时间到，本回合受伤一样（%.0f），平局重打", "TIME UP, SAME DAMAGE TAKEN (%.0f) - REPLAY"), ta)
                end
            else
                local missA = not ta and ((DUEL.fa == mp.myPid()) and "自己" or "对方")
                local missB = not tb and ((DUEL.fb == mp.myPid()) and "自己" or "对方")
                out("对决：没收到%s的本回合受伤（旧版 / 还没到），时间到按血量比判",
                    (missA and missB) and (missA .. "、" .. missB) or (missA or missB or "?"))
                local hpA, hpmA = resolveFightHp(DUEL.fa, pktA)
                local hpB, hpmB = resolveFightHp(DUEL.fb, pktB)
                local pctA = (hpA and hpmA and hpmA > 0) and (hpA / hpmA) or 1.0
                local pctB = (hpB and hpmB and hpmB > 0) and (hpB / hpmB) or 1.0
                if pctA > pctB + HP_TIE_EPS then
                    roundWin, why = DUEL.fa, string.format("时间到，血量比占优（%.0f%% : %.0f%%）", pctA * 100, pctB * 100)
                elseif pctB > pctA + HP_TIE_EPS then
                    roundWin, why = DUEL.fb, string.format("时间到，血量比占优（%.0f%% : %.0f%%）", pctB * 100, pctA * 100)
                else
                    roundWin, why = 0, string.format("时间到且血量比相同（%.0f%%），平局重打", pctA * 100)
                end
            end
        end

        if roundWin ~= nil then
            local loser = (roundWin == DUEL.fa) and DUEL.fb or (roundWin == DUEL.fb) and DUEL.fa or 0
            if roundWin == DUEL.fa then DUEL.winsA = DUEL.winsA + 1
            elseif roundWin == DUEL.fb then DUEL.winsB = DUEL.winsB + 1 end
            local need = mp.toWin(mp.bestOf())
            if DUEL.winsA >= need or DUEL.winsB >= need then
                local w = (DUEL.winsA >= need) and DUEL.fa or DUEL.fb
                local l = (w == DUEL.fa) and DUEL.fb or DUEL.fa
                finishMatch(w, l, why, tn)
            else
                -- §307 D8：各端按这一回合的输家播倒地（选手自己是输家就 fallSelf）
                sendOutcome(roundWin, loser, DUEL.mid, DUEL.round)
                applyRoundFall(roundWin, DUEL.mid, DUEL.round)
                DUEL.lastEndWhy = why or ""
                DUEL.state = "rend"
                DUEL.stateAt = tn
                DUEL.stateTill = tn + REND_SEC
                mp.notifyTag("fight")
                applyLocalPhase(tn)
                broadcastHostState(tn, true)
            end
            return
        end
    elseif DUEL.state == "rend" then
        if DUEL.stateTill and tn >= DUEL.stateTill then
            startRoundCd(DUEL.round + 1, tn)
            return
        end
    elseif DUEL.state == "end" then
        if DUEL.loop and DUEL.stateTill and tn >= DUEL.stateTill then
            callNextMatch(tn, "可上场人数不足 2 人")
            return
        end
    end
    -- 11-17 用户定（贴近旧版）：没有"开启对决轮换"这一步。房里能上场的够 2 人就自动叫先进来的两位进"即将对决"，各自按 F1 开打
    if (DUEL.state == "idle" or (DUEL.state == "end" and not DUEL.stateTill)) and #activeQueue() >= 2 then
        DUEL.loop = true
        callNextMatch(tn, "自动叫号")
        return
    end

    broadcastHostState(tn, false)
end

-- ---- 公共接口

function DUEL.isDuel()
    if not mp.inMp() then return false end
    if mp.isHost() then
        return (mp.cfg() and mp.cfg().mode == "duel") or false
    end
    local sd = mp.sessionDuel()
    if sd and sd.duel then return true end
    -- §331 客机只认房主那边（联机程序的对决行 / 房主状态包），不看自己 mp.txt 的玩法：
    -- 上次自己开过对决房、这次进别人的淘汰 / 积分房时，以前会被当成对决，发对决包（不带 mt3= / mpd= / mpk=），
    -- 房主开三队说"版本太旧"、倒下 / 击杀也报不上去（11-15 双开实测）
    return DUEL.remoteDuel or false
end

function DUEL.active()
    return DUEL.isDuel() and DUEL.state ~= "idle"
end

function DUEL.fighting()
    return DUEL.isDuel() and DUEL.state == "fight"
end

-- 11-17 真正在打（倒计时 / 交手 / 回合之间）；叫号"即将对决"不算，那时还能传送去房主那里
function DUEL.liveMatch()
    if not DUEL.isDuel() then return false end
    return DUEL.state == "cd" or DUEL.state == "fight" or DUEL.state == "rend"
end

function DUEL.inMatch()
    if not DUEL.isDuel() then return false end
    return DUEL.state == "ready" or DUEL.state == "cd" or DUEL.state == "fight" or DUEL.state == "rend"
end

function DUEL.isFighter(pid)
    if not DUEL.isDuel() then return false end
    pid = pid or mp.myPid()
    return pid ~= nil and pid > 0 and (pid == DUEL.fa or pid == DUEL.fb)
end

function DUEL.shouldLockSelf()
    if not DUEL.isDuel() then return true end
    if not DUEL.isFighter() then return false end
    return DUEL.state == "cd" or DUEL.state == "fight" or DUEL.state == "rend"
end

-- 11-17 排查补齐：开战点光柱（main.lua ARN 那套：蓝 = fa、橙 = fb）。即将对决 / 倒计时时标两位选手站的位置，交手中收起
function DUEL.markers(myMap)
    if not DUEL.isDuel() then return nil end
    if not (DUEL.state == "ready" or DUEL.state == "cd") then return nil end
    local a = DUEL.arena
    if not (a and DUEL.fa > 0 and DUEL.fb > 0) then return nil end
    if a.map and myMap and a.map ~= myMap then return nil end
    local rad, r = math.rad(a.yaw or 0.0), a.radius or 400.0
    -- 11-17 修：补齐 Z / d / yaw（ARN.encode 要这几个，缺了 F2 存场地和叫号时都报 format nil）
    return { host = { X = a.cx - math.cos(rad) * r, Y = a.cy - math.sin(rad) * r, Z = a.cz, fz = a.cz },
             cli  = { X = a.cx + math.cos(rad) * r, Y = a.cy + math.sin(rad) * r, Z = a.cz, fz = a.cz },
             d = r, yaw = a.yaw or 0.0 }
end

function DUEL.allowSpawn(pid)
    if not DUEL.isDuel() then return true end
    -- 11-17 用户定（贴近旧版）：只看不上场的人全程不出现；待机 / 即将对决 / 一场结束时其他人都可见；
    -- 两人按 F1 开打（倒计时 / 交手 / 回合之间）才只留两位选手
    if pid and DUEL.isWatch(pid) then return false end
    if DUEL.state == "idle" or DUEL.state == "ready" or DUEL.state == "end" then return true end
    return pid ~= nil and pid > 0 and (pid == DUEL.fa or pid == DUEL.fb)
end

-- §307 D4：给基础联机包（BASEHOOK.mp.duelInfo）用的轻量快照；不在对决里 = nil
function DUEL.info()
    if not DUEL.isDuel() then return nil end
    local t = DUEL.infoCache or {}
    t.fighter = DUEL.isFighter()
    t.state = DUEL.state
    t.round = DUEL.round or 0
    t.bo = mp.bestOf()
    t.tl = (DUEL.tlSec and DUEL.tlSec > 0) and DUEL.tlSec or mp.tlLimit()
    DUEL.infoCache = t
    return t
end

function DUEL.canAttack()
    if not DUEL.isDuel() then return true end
    return DUEL.isFighter() and DUEL.state == "fight"
end

function DUEL.getOrder()
    local copy = {}
    for i = 1, #DUEL.order do copy[i] = DUEL.order[i] end
    return copy
end

function DUEL.getQueueNext()
    local q = activeQueue()
    for i = 1, #q do
        if q[i] ~= DUEL.fa and q[i] ~= DUEL.fb then return q[i] end
    end
    return nil
end

function DUEL.setWatchOnly(on)
    -- 11-17 实测：一次点击被处理了两次（关了又马上开回去），0.5 秒内重复切换不认
    local tnow = nowFn()
    if DUEL.watchToggleAt and tnow - DUEL.watchToggleAt < 0.5 then return end
    DUEL.watchToggleAt = tnow
    DUEL.myWatch = on and true or false
    DUEL.watchResendN = 0
    local me = mp.myPid()
    if me and me > 0 then
        if mp.isHost() then
            DUEL.watch[me] = DUEL.myWatch or nil
            if DUEL.state == "ready" and DUEL.myWatch and (me == DUEL.fa or me == DUEL.fb) then
                callNextMatch(nowFn(), "房主切为只看不上场")
            else
                broadcastHostState(nowFn(), true)
            end
        else
            DUEL.watch[me] = DUEL.myWatch or nil
            mp.relChat(string.format("w|%d|%d", me, DUEL.myWatch and 1 or 0))
        end
    end
    -- 11-17 用户"开了仅观战，场上就一直看不到这个人，全流程都是观战"：不交手的阶段马上进 / 出观战
    -- （交手阶段本来就在观战，选手切只看不上场由房主重新叫号）
    -- 11-17 实测：被点名的选手关掉只看不上场后还卡在观战视角（以前选手不处理），现在不交手的阶段谁都马上切
    if DUEL.isDuel() and (DUEL.state == "idle" or DUEL.state == "ready" or DUEL.state == "end") then
        freePhaseView("只看不上场切换")
    end
end

function DUEL.stopRotation(why)
    if mp.isHost() then
        resetToIdle(why or "停止轮换", nowFn())
    end
end

function DUEL.syncModeCmd(tn)
    if not mp.inMp() or not mp.isHost() then return end
    local wantDuel = (mp.cfg() and mp.cfg().mode == "duel")
    if wantDuel then
        if not DUEL.duelCmdSent then
            DUEL.duelCmdSent = true
            -- 11-15 观众上限 = 房间人数 − 2（三个玩法同一个房间人数，不再跟"观战 / 排队人数上限"走，那项只管旧版 1v1）
            local size = tonumber(mp.cfg() and mp.cfg().size) or 4
            mp.cmd("duel", "on=1\ncap=" .. math.max(0, size - 2) .. "\n")
            mp.notifyTag(DUEL.state == "cd" and "cd" or (DUEL.state == "fight" and "fight" or "idle"))
        end
    elseif DUEL.duelCmdSent then
        resetToIdle("切换出对决模式", tn or nowFn())
        mp.cmd("duel", "on=0\n")
        DUEL.duelCmdSent = false
        DUEL.lastSentCap = nil
        DUEL.stats = {}
        DUEL.remoteDuel = false
        mp.relChat("off|")
        mp.notifyTag("idle")
    end
end

local function wbanBlockSelf()
    if not mp.wbanSelf then return false end
    local zh, en = mp.wbanSelf()
    if not zh then return false end
    mp.notice(zh, en, 4.0)
    return true
end

function DUEL.f1()
    local tn = nowFn()
    if not mp.inMp() or not DUEL.isDuel() then return false end
    local me = mp.myPid()
    if mp.isHost() then
        DUEL.syncModeCmd(tn)
        syncRoster(mp.roster())
        -- 11-17 用户定：没有"开启 / 停止对决轮换"。够 2 人自动叫号（tickHost）；F1 只给被叫到的人准备、选手两下认输
        if DUEL.state == "idle" then
            local q = activeQueue()
            if #q >= 2 then
                DUEL.loop = true
                callNextMatch(tn, "自动叫号")
            else
                mp.notice(T("能上场的不到 2 人，等人进来", "NEED AT LEAST 2 PLAYERS"), "", 2.5)
            end
            return true
        elseif DUEL.state == "ready" then
            if (me == DUEL.fa or me == DUEL.fb) and not DUEL.readySet[me] then
                if wbanBlockSelf() then return false end                    -- §307 D2：自己装着禁用的不让准备
                local ref = oppOf(me)
                if ref > 0 and not mp.sameMapAs(ref) then                   -- §307 D1：对手不在房主（我）这张图
                    mp.notice(string.format(T("对手 %s 不在你这张地图，等对方过来再按 F1", "OPPONENT %s IS NOT ON YOUR MAP - WAIT, THEN PRESS F1"), mp.nameOf(ref)), "", 4.0)
                    return false
                end
                DUEL.readySet[me] = true
                if not tryStartCd(tn) then broadcastHostState(tn, true) end
                return true
            end
            return true
        elseif DUEL.state == "cd" or DUEL.state == "fight" or DUEL.state == "rend" then
            if me == DUEL.fa or me == DUEL.fb then
                -- §307 D3：选手 3 秒内按两次 F1 = 认输
                if f1ArmCheck("surrender", tn) then
                    local opp = oppOf(me)
                    if opp > 0 then
                        announce("surr", me)
                        finishMatch(opp, me, "认输", tn)
                    end
                else
                    mp.notice(T("再按一次 F1 认输", "PRESS F1 AGAIN TO SURRENDER"), "", 2.5)
                end
                return true
            end
            -- §307 D3：房主不是选手：3 秒内按两次取消这一场（不计胜负），之后照常叫下一组
            if f1ArmCheck("stop", tn) then
                finishMatch(0, 0, "房主取消了这一场（不计）", tn)
                mp.notice(T("已取消这一场", "MATCH CANCELLED"), "", 2.5)
            else
                mp.notice(T("再按一次 F1 取消这一场（不计胜负）", "PRESS F1 AGAIN TO CANCEL THIS MATCH (NOT COUNTED)"), "", 3.0)
            end
            return true
        elseif DUEL.state == "end" then
            -- 11-17：一场打完等下一组时，房主按 F1 不用等，直接叫下一组（人不够会提示并回待机）
            syncRoster(mp.roster())
            DUEL.loop = true
            callNextMatch(tn, "房主按 F1 叫下一组")
            return true
        else
            return true
        end
    else
        -- 客机：cd / fight / 回合之间选手按两次 F1 认输（第一条提示第二次才发）
        if DUEL.state == "cd" or DUEL.state == "fight" or DUEL.state == "rend" then
            if me == DUEL.fa or me == DUEL.fb then
                if f1ArmCheck("surrender", tn) then
                    mp.relChat(string.format("q|%d|%d", me, DUEL.mid))
                    mp.notice(T("已认输，等房主结算", "SURRENDERED - WAITING FOR THE HOST"), "", 2.5)
                else
                    mp.notice(T("再按一次 F1 认输", "PRESS F1 AGAIN TO SURRENDER"), "", 2.5)
                end
                return true
            end
            return false
        end
        -- 客机只有当前被点名的选手在 ready 阶段按 F1 准备
        if DUEL.state == "ready" and (me == DUEL.fa or me == DUEL.fb) and me > 0 and not DUEL.readySet[me] then
            -- 11-17 实测：离房主 120 米时第一下 F1 提示"再按一次传送"，第二下赶上叫号就成了准备。离得远（别的图 / 50 米外）F1 先管传送
            if mp.travelF1 and mp.travelF1() then return true end
            if wbanBlockSelf() then return false end                        -- §307 D2
            local hp = mp.hostPid()
            if hp and hp > 0 and not mp.sameMapAs(hp) then                  -- §307 D1
                if mp.travelF1 and mp.travelF1() then return true end      -- 11-17 连按两次 F1 去房主那里
                mp.notice(T("你不在对决的地图：连按两次 F1 前往房主所在地图，到了再按 F1 准备", "NOT ON THE DUEL MAP: PRESS F1 TWICE TO GO TO THE HOST'S MAP, THEN F1 TO READY"), "", 4.0)
                return false
            end
            DUEL.readySet[me] = true
            mp.relChat(string.format("r|%d|%d", me, DUEL.mid))
            return true
        end
        if mp.travelF1 and mp.travelF1() then return true end              -- 11-17 没在打时离房主太远 / 在别的图：连按两次 F1 传过去
        return false
    end
end

function DUEL.step(tn)
    tn = tn or nowFn()
    local inMp = mp.inMp()
    if not inMp then
        if DUEL.prevInMp then DUEL.onLeave("退出多人房间", tn) end
        DUEL.prevInMp = false
        return
    end
    DUEL.prevInMp = true

    if mp.isHost() then
        DUEL.isHostCache = true
        DUEL.syncModeCmd(tn)
        if not DUEL.isDuel() then return end
        tickHost(tn)
    else
        DUEL.isHostCache = false
        -- §324 从"观战"进的房（联机程序 mpwatch=1）：对决里一拿到编号就当"只看不上场"，告诉房主一次（淘汰 / 积分那份在 pbz_multi 的 MP.wire）。
        -- 这里自动开的离开房间时关掉，下次正常加入不受影响
        if mp.joinWatch and mp.joinWatch() and not DUEL.joinWatchDone and DUEL.isDuel() then
            local me = mp.myPid()
            if me and me > 0 then
                DUEL.joinWatchDone = true
                if DUEL.myWatch then mp.relChat(string.format("w|%d|1", me)) else DUEL.joinWatchSetDuel = true; DUEL.setWatchOnly(true) end
                out("对决：从观战进房，设为只看不上场（pid=%d）", me)
            end
        end
        if not DUEL.isDuel() then return end
        -- 客机/观众维护本地队列视图（当仅 session 有名单、还没收到 mdq 时也保持有序）
        if #DUEL.order == 0 then syncRoster(mp.roster()) end
        -- 观众镜头持续跟随两位选手（每帧检查/维持视角）
        if DUEL.state == "cd" or DUEL.state == "fight" or DUEL.state == "rend" then
            if not DUEL.isFighter() then
                mp.specStart({ DUEL.fa, DUEL.fb }, tn)
            end
        end
    end

    -- 本机上场选手在 fight 阶段查自己倒地（含慈母护符防秒）
    if DUEL.state == "fight" and DUEL.isFighter() and DUEL.downRound ~= DUEL.round then
        local hp = select(1, mp.selfHp())
        -- §307 D5：累计本回合自己掉的血（只算掉；回血不抵）
        if hp and DUEL.fightHp and hp < DUEL.fightHp - 0.01 then
            if DUEL.dtkMid == DUEL.mid and DUEL.dtkRound == DUEL.round then
                DUEL.dtk = (DUEL.dtk or 0) + (DUEL.fightHp - hp)
            else
                DUEL.dtk, DUEL.dtkMid, DUEL.dtkRound = DUEL.fightHp - hp, DUEL.mid, DUEL.round
            end
        end
        local regen = hp and hp > mp.deadHp() and DUEL.fightHp and hp ~= DUEL.fightHp and mp.isSelfDeadRegen(DUEL.fightHp, tn)
        if hp and (hp <= mp.deadHp() or regen) then
            DUEL.myDown = true
            DUEL.downRound = DUEL.round
            DUEL.downMid = DUEL.mid
            mp.fallSelf()
        end
        DUEL.fightHp = hp
    end
end

function DUEL.wire(tn)
    if not DUEL.isDuel() then return "" end
    local s = ""
    if DUEL.isFighter() then
        -- §307 D5：本回合自己掉的血（房主在时限到时比两人的；旧客户端不认这个字段）
        s = s .. string.format("dtk=%d:%d:%.0f\n", DUEL.mid or 0, DUEL.round or 0, DUEL.dtk or 0)
    end
    if DUEL.state == "fight" and DUEL.isFighter() and DUEL.myDown and DUEL.downMid == DUEL.mid and DUEL.downRound == DUEL.round then
        s = s .. string.format("mpd=%d:%d\n", DUEL.mid, DUEL.round)
    end
    if mp.isHost() then
        s = s .. "mdu=" .. formatMdu(tn or nowFn()) .. "\n"
              .. "mdq=" .. formatMdq() .. "\n"
              .. "mdw=" .. string.format("%d:%d", DUEL.lastWinPid or 0, DUEL.lastLoserPid or 0) .. "\n"
        if DUEL.arenaKv then
            s = s .. "mda=" .. DUEL.arenaKv .. "\n"
                  .. "mdm=" .. tostring(DUEL.arenaMap or "") .. "\n"
        end
    end
    return s
end

function DUEL.onPacket(t, tn)
    if not t then return false end
    tn = tn or nowFn()
    local src = tonumber(t.src)
    if src == mp.myPid() then return false end
    if src and src > 0 then
        DUEL.peerPkts[src] = {
            hp = tonumber(t.hp),
            hpm = tonumber(t.hpm),
            mpd = t.mpd,
            nm = t.nm,
        }
        -- §307 D5：对手本回合掉的血（旧版没有 dtk= → 这个表里就没有）
        if t.dtk and t.dtk ~= "" then
            local mid, rd, v = t.dtk:match("^(%d+):(%d+):([%d%.%-]+)$")
            if mid then
                DUEL.peerDtk[src] = { mid = tonumber(mid), rd = tonumber(rd), v = tonumber(v) }
            end
        elseif DUEL.peerDtk[src] then
            DUEL.peerDtk[src] = nil
        end
    end
    if t.mdu and not mp.isHost() and src == mp.hostPid() then      -- §293.1 只认当前房主（换房主后旧 1 号的不认）
        if t.mdw and t.mdw ~= "" then
            local w, l = t.mdw:match("^(%d+):(%d+)$")
            if w then DUEL.lastWinPid, DUEL.lastLoserPid = tonumber(w), tonumber(l) or 0 end
        end
        applyNetState(t.mdu, t.mdq, tn, t.mda, t.mdm)
    end
    -- 若房主收到倒下字段，立即可在下一次 tickHost 结算；也可以等 tickHost 统一扫 peerPacket
    return DUEL.isDuel()
end

function DUEL.onChat(rest)
    if type(rest) ~= "string" then return false end
    local _, body = rest:match("^([^|]+)|(.*)$")
    body = body or rest
    if body:sub(1, 6) == "@duel:" then return true end      -- 没盖章的（不该出现：房主的联机程序一定盖）不认、也不当聊天显示
    if body:sub(1, 6) ~= "@duel@" then return false end
    local tn = nowFn()
    -- §293.1 房主的联机程序盖的发送人真编号：@duel@<编号>:<kind>|<data>
    local fromStr, payload = body:match("^@duel@(%d+):(.*)$")
    local from = tonumber(fromStr)
    if not (from and payload) then return true end
    local kind, data = payload:match("^([^|]+)|(.*)$")
    if not kind then return true end
    -- 房主才能发的：对决状态 / 关对决 / 规则 / 场地 / 提示 / 结果；不是房主发的丢掉
    if (kind == "s" or kind == "off" or kind == "ru" or kind == "a" or kind == "e" or kind == "t" or kind == "o")
        and from ~= mp.hostPid() then return true end

    if kind == "s" and not mp.isHost() then
        local mdu, mdq = data:match("^([^|]+)|(.*)$")
        if mdu then applyNetState(mdu, mdq, tn) end
    elseif kind == "a" and not mp.isHost() then
        -- §307 D1：场地（可靠聊天这一路；状态包 mda= 是另一路）。data = 局号|cx:cy:cz:yaw:radius|地图
        local midStr, tok, map = data:match("^(%d+)|(.-)|(.*)$")
        if tok and setArena(parseArena(tok), map) then
            DUEL.arenaMid = tonumber(midStr) or DUEL.mid
            placeIfNeeded(tn)
            if mp.arnRefresh then mp.arnRefresh("对决场地到了") end
        end
    elseif kind == "e" and not mp.isHost() then
        -- §307 D1 / D2：房主点名（只处理发给我的）
        local pidStr, code = data:match("^(%d+)|(%a+)$")
        local pid = tonumber(pidStr)
        if pid and pid == mp.myPid() then
            DUEL.readySet[pid] = nil
            if code == "map" then
                mp.notice(T("你不在对决的地图：连按两次 F1 前往房主所在地图，到了再按 F1 准备", "NOT ON THE DUEL MAP: PRESS F1 TWICE TO GO TO THE HOST'S MAP, THEN F1 TO READY"), "", 4.0)
            elseif code == "wban" then
                mp.notice(T("房主复核：你装着禁用武器 / 影之武装，换掉再准备", "HOST CHECK: YOU HAVE A BANNED WEAPON / PHANTOM EDGE - SWAP IT OUT, THEN READY"), "", 4.0)
            end
        end
    elseif kind == "t" and not mp.isHost() then
        -- §307 D3 / D8：认输 / 掉线的广播提示
        local code, pidStr = data:match("^(%a+)|(%d+)$")
        if code and pidStr then showAnnounce(code, tonumber(pidStr)) end
    elseif kind == "o" and not mp.isHost() then
        -- §307 D7 / D8：这一回合 / 这一场的赢家 + 输家；各端据此播倒地（平局 = 两边都倒）
        local w, l, mid, rd = data:match("^(%d+)|(%d+)|(%d+)|(%d+)$")
        if w then
            DUEL.lastWinPid, DUEL.lastLoserPid = tonumber(w), tonumber(l)
            if tonumber(mid) == DUEL.mid and tonumber(rd) == (DUEL.round or 0) then
                applyRoundFall(DUEL.lastWinPid, tonumber(mid), tonumber(rd))
            end
        end
    elseif kind == "off" and not mp.isHost() then
        DUEL.remoteDuel = false
        DUEL.lastEndWhy = "房主切换模式"
        DUEL.state = "idle"
        DUEL.fa, DUEL.fb = 0, 0
        DUEL.order = {}
        DUEL.arena, DUEL.arenaKv, DUEL.arenaMap = nil, nil, nil
        applyLocalPhase(tn)
    elseif kind == "ru" and not mp.isHost() then
        local tbl = {}
        for kv in (data .. ";"):gmatch("([^;]*);") do
            local k, v = kv:match("^([^=]+)=(.*)$")
            if k then tbl[k] = v end
        end
        mp.feedRules(tbl)
    elseif kind == "w" and mp.isHost() and DUEL.isDuel() then
        local pidStr, onStr = data:match("^(%d+)|([01])$")
        local pid = tonumber(pidStr)
        if pid and pid > 0 and pid == from then        -- 只能改自己的"只看不上场"
            local on = (onStr == "1")
            DUEL.watch[pid] = on or nil
            if DUEL.state == "ready" and on and (pid == DUEL.fa or pid == DUEL.fb) then
                callNextMatch(tn, "选手切为只看不上场")
            else
                broadcastHostState(tn, true)
            end
        end
    elseif kind == "r" and mp.isHost() and DUEL.isDuel() then
        local pidStr, midStr = data:match("^(%d+)|(%d+)$")
        local pid, mid = tonumber(pidStr), tonumber(midStr)
        if pid and pid == from and mid == DUEL.mid and DUEL.state == "ready" and (pid == DUEL.fa or pid == DUEL.fb) then     -- 只能替自己准备
            -- §307 D1：不在房主那张图的选手不认准备（提示本人）
            if not mp.sameMapAs(pid) then
                tellPid(pid, "map")
                out("对决：%d 号准备时不在对决地图，已拒绝并提示", pid)
                broadcastHostState(tn, true)
            else
                DUEL.readySet[pid] = true
                if not tryStartCd(tn) then broadcastHostState(tn, true) end
            end
        end
    elseif kind == "q" and mp.isHost() and DUEL.isDuel() then
        -- §307 D3：客机选手认输（3 秒内按两次 F1 才发；这里再核一次发送人 / 局号 / 阶段）
        local pidStr, midStr = data:match("^(%d+)|(%d+)$")
        local pid, mid = tonumber(pidStr), tonumber(midStr)
        if pid and pid == from and mid == DUEL.mid and (DUEL.state == "cd" or DUEL.state == "fight" or DUEL.state == "rend")
            and (pid == DUEL.fa or pid == DUEL.fb) then
            local opp = oppOf(pid)
            if opp > 0 then
                announce("surr", pid)
                finishMatch(opp, pid, "认输", tn)
            end
        end
    end
    return true
end

function DUEL.onHostChanged(newHost, isNowHost, tn, oldHost)
    tn = tn or nowFn()
    if not DUEL.isDuel() and not DUEL.matchStarted and DUEL.state == "idle" then return end

    -- 沿用旧房主规则，不写进本地设置文件
    if isNowHost and ctx.adoptHostRules then
        ctx.adoptHostRules()
    end

    -- 移除离开的前房主
    if oldHost and oldHost > 0 then
        local newOrder = {}
        for _, p in ipairs(DUEL.order) do
            if p ~= oldHost then newOrder[#newOrder + 1] = p end
        end
        DUEL.order = newOrder
        DUEL.watch[oldHost] = nil
        DUEL.readySet[oldHost] = nil
        DUEL.peerPkts[oldHost] = nil
        DUEL.peerDtk[oldHost] = nil
        DUEL.f1Arm = nil
    end
    syncRoster(mp.roster())

    local hName = mp.nameOf(newHost)
    local msg = string.format(T("%s 成为房主", "%s IS NOW THE HOST"), hName)
    if ctx.notice then ctx.notice(msg, "", 2.0) end
    out("对决：%s", msg)

    local inFight = (DUEL.state == "cd" or DUEL.state == "fight" or DUEL.state == "rend")
    local wasFighter = oldHost and (oldHost == DUEL.fa or oldHost == DUEL.fb)

    if inFight and wasFighter then
        -- 房主是上场选手时走了：这场按他认输结束、对手赢、接着叫下一位
        local survivor = (oldHost == DUEL.fa) and DUEL.fb or DUEL.fa
        out("对决：选手房主 pid=%d 离开，对手 pid=%d 获胜", oldHost, survivor)
        if isNowHost then
            DUEL.loop = true
            finishMatch(survivor, oldHost, "选手离开，对手获胜", tn)
        end
    elseif inFight and not wasFighter then
        -- 房主当观众时走了：正在打的这场照常打完、比分/排队顺序不变
        out("对决：观众房主 pid=%d 离开，对局继续", oldHost or 0)
        if isNowHost then
            DUEL.loop = true
            DUEL.syncModeCmd(tn)
            sendDuelCmd(DUEL.fa, DUEL.fb, DUEL.state == "cd" or DUEL.state == "fight" or DUEL.state == "rend")
            broadcastHostState(tn, true)
        end
    elseif DUEL.state == "ready" then
        if wasFighter then
            if isNowHost then
                DUEL.readySet = {}
                DUEL.fa, DUEL.fb = 0, 0
                if DUEL.loop then
                    callNextMatch(tn, "待选选手离开")
                else
                    resetToIdle("待选选手离开", tn)
                end
            end
        else
            if isNowHost then
                broadcastHostState(tn, true)
            end
        end
    elseif DUEL.state == "end" then
        if isNowHost then
            DUEL.loop = true
            DUEL.stateTill = tn + NEXT_WAIT_SEC
            broadcastHostState(tn, true)
        end
    else
        -- idle
        if isNowHost and mp.cfg() and mp.cfg().mode == "duel" then
            DUEL.syncModeCmd(tn)
            sendDuelCmd(0, 0, false)
            mp.notifyTag("idle")
            broadcastHostState(tn, true)
            local msg2 = T("你已成为新房主", "YOU ARE NOW HOST")
            if ctx.notice then ctx.notice(msg2, "", 2.0) end
            out("对决：%s", msg2)
        end
    end
end

function DUEL.onLeave(why, tn)
    tn = tn or nowFn()
    fireMatchEnd(why or "离开房间")
    cleanupFighter(why or "离开房间")
    mp.specStop(why or "离开房间")
    DUEL.loop = false
    DUEL.state = "idle"
    DUEL.fa, DUEL.fb = 0, 0
    DUEL.round, DUEL.winsA, DUEL.winsB = 0, 0, 0
    DUEL.stateTill = nil
    DUEL.readySet = {}
    DUEL.order = {}
    DUEL.watch = {}
    DUEL.stats = {}
    DUEL.duelCmdSent = false
    DUEL.duelLiveSent = false
    DUEL.lastSetFa, DUEL.lastSetFb = 0, 0
    DUEL.lastSentCap = nil
    DUEL.remoteDuel = false
    DUEL.appliedKey = nil
    DUEL.peerPkts = {}
    -- §307：场地 / 受伤累计 / 倒地 / 双击确认 / 结果都清掉
    DUEL.arena, DUEL.arenaKv, DUEL.arenaMap, DUEL.arenaMid = nil, nil, nil, nil
    DUEL.lastArenaBc, DUEL.placedKey, DUEL.fellKey = nil, nil, nil
    DUEL.dtk, DUEL.dtkMid, DUEL.dtkRound, DUEL.peerDtk = 0, nil, nil, {}
    DUEL.f1Arm = nil
    DUEL.lastWinPid, DUEL.lastLoserPid = 0, 0
    -- §324 从观战进房时自动开的"只看不上场"随离开关掉（自己手动开的不动）
    if DUEL.joinWatchSetDuel then DUEL.myWatch = false end
    DUEL.joinWatchDone, DUEL.joinWatchSetDuel = nil, nil
end

function DUEL.onMapLoad()
    DUEL.onLeave("换地图", nowFn())
end

function DUEL.hudRows(tn)
    if not DUEL.isDuel() then return nil end
    tn = tn or nowFn()
    local rows = {}
    local colTitle = { R = 255, G = 215, B = 90, A = 255 }
    local colInfo  = { R = 240, G = 240, B = 240, A = 255 }
    local colWarn  = { R = 255, G = 140, B = 40,  A = 255 }
    local colMute  = { R = 170, G = 170, B = 170, A = 255 }

    local me = mp.myPid()
    local nA = DUEL.fa > 0 and mp.nameOf(DUEL.fa) or "-"
    local nB = DUEL.fb > 0 and mp.nameOf(DUEL.fb) or "-"
    local nxt = DUEL.getQueueNext()
    local nxtName = nxt and mp.nameOf(nxt) or T("无", "NONE")
    local rem = remSecInt(tn)
    local isF = DUEL.isFighter()

    if DUEL.state == "idle" then
        local q = activeQueue()
        local roleTxt = (#q < 2) and T("等人进来（够 2 人自动叫号）", "WAITING FOR PLAYERS")
                        or T("马上叫号…", "CALLING THE NEXT PAIR...")
        -- 11-17 用户："1v1 对决 · 可上场 4 人"读着像 4 个人上场：人数不写，只有不够 2 人开不了时提示
        rows[#rows + 1] = { c = (#q < 2) and T("1v1 对决 · 还差人（能上场的不到 2 人）", "1V1 DUEL · NEED AT LEAST 2 PLAYERS")
                                       or T("1v1 对决", "1V1 DUEL"), col = colTitle }
        rows[#rows + 1] = { c = roleTxt .. (DUEL.myWatch and T("  [只看不上场]", "  [WATCH ONLY]") or ""), col = colInfo }
        if nxt then
            rows[#rows + 1] = { c = T("下一位：", "NEXT: ") .. nxtName, col = colMute }
        end
    elseif DUEL.state == "ready" then
        -- 11-17 用户"能换成以前的布局 / 颜色区分么，然后移到右边"：同旧版 1v1 的准备面板（main.lua idleRows）——
        -- 每人一行"名字：已准备 / 未准备"，已准备绿、未准备红；都放右侧（mpHudRows 把非 center 的行放右边）
        local colGreen = { R = 90, G = 230, B = 110, A = 255 }
        local colRed   = { R = 255, G = 70, B = 70, A = 255 }
        local function readyRow(pid, name)
            local ok = DUEL.readySet[pid] and true or false
            return { l = name .. T("：", ":"), v = ok and T("已准备", "READY") or T("未准备", "NOT READY"), col = ok and colGreen or colRed }
        end
        rows[#rows + 1] = { c = T("1v1 对决 · 即将对决", "1V1 DUEL · UP NEXT"), col = colTitle }
        if isF then
            local opp = oppOf(me)
            rows[#rows + 1] = readyRow(me, T("我方", "YOU"))
            rows[#rows + 1] = readyRow(opp, mp.nameOf(opp))
            if not DUEL.readySet[me] then
                rows[#rows + 1] = { c = T("按 F1 准备", "PRESS F1 TO READY"), col = colInfo, size = 0.75 }
            end
        else
            rows[#rows + 1] = readyRow(DUEL.fa, nA)
            rows[#rows + 1] = readyRow(DUEL.fb, nB)
            rows[#rows + 1] = { c = T("等两人按 F1 开打  下一位：", "WAITING FOR F1  NEXT: ") .. nxtName, col = colMute, size = 0.75 }
        end
    elseif DUEL.state == "fight" and isF then
        -- 11-17 用户："战斗过程中这么多文字有点碍眼，跟之前一样统一在结束后 / 未战斗期播报"：
        -- 上场选手交手中只留剩余时间（同旧 1v1：小字，最后 10 秒红色放大）；比分 / 下一位在倒计时、回合结束、本场结束时显示
        if rem > 0 then
            rows[#rows + 1] = { c = remText(rem),
                                col = rem <= 10 and { R = 255, G = 70, B = 60, A = 255 } or colInfo,
                                size = rem <= 10 and 1.2 or 0.8, nolog = true }
        end
    else
        -- 11-17 用户"新的提示也压缩在右边"：以前一行写满"第 N 回合（抢 K） A 0 : 0 B [时间]"再加一长行观看 / 下一位，
        -- 现在拆成短行：回合 + 时间 / 每人一行比分（同旧版 1v1 面板的"名字：值"）/ 小字提示
        local bo = mp.bestOf()
        local head = string.format(T("第 %d 回合（抢 %d）", "ROUND %d (FT%d)"), math.max(1, DUEL.round), mp.toWin(bo))
        if (DUEL.state == "cd" or DUEL.state == "fight") and rem > 0 then
            head = head .. "  " .. remText(rem)
        end
        rows[#rows + 1] = { c = head, col = colTitle }
        local function scoreRow(pid, name, wins)
            return { l = name .. T("：", ":"), v = tostring(wins or 0), col = colInfo }
        end
        if isF then
            local meIsA = (me == DUEL.fa)
            rows[#rows + 1] = scoreRow(me, T("我方", "YOU"), meIsA and DUEL.winsA or DUEL.winsB)
            rows[#rows + 1] = scoreRow(oppOf(me), mp.nameOf(oppOf(me)), meIsA and DUEL.winsB or DUEL.winsA)
        else
            rows[#rows + 1] = scoreRow(DUEL.fa, nA, DUEL.winsA)
            rows[#rows + 1] = scoreRow(DUEL.fb, nB, DUEL.winsB)
        end
        local small = 0.75
        if DUEL.state == "cd" then
            if isF then
                rows[#rows + 1] = { c = T("准备开打！", "GET READY!"), col = colWarn, center = true }
            else
                rows[#rows + 1] = { c = T("PgUp / PgDn 换视角", "PGUP / PGDN: CAMERA"), col = colMute, size = small }
            end
        elseif DUEL.state == "fight" then
            -- 选手交手中走上面那个分支（只留时间）；这里是观众
            rows[#rows + 1] = { c = T("PgUp / PgDn 换视角", "PGUP / PGDN: CAMERA"), col = colMute, size = small }
            rows[#rows + 1] = { c = T("下一位：", "NEXT: ") .. nxtName, col = colMute, size = small }
        elseif DUEL.state == "rend" then
            local msg = (DUEL.lastWinPid == 0) and T("本回合平局，准备重打", "ROUND DRAW, REPLAY")
                        or string.format(T("%s 赢下本回合", "%s WINS THE ROUND"), mp.nameOf(DUEL.lastWinPid))
            rows[#rows + 1] = { c = msg, col = colInfo }
        elseif DUEL.state == "end" then
            -- 实测（11-14）：客机拿不到房主的结束原因，以前显示成"胜者：你 ()"；没原因就不带括号
            local why = (DUEL.lastEndWhy or "") ~= "" and ("  (" .. DUEL.lastEndWhy .. ")") or ""
            local msg = (DUEL.lastWinPid > 0)
                        and (string.format(T("胜者：%s", "WINNER: %s"), mp.nameOf(DUEL.lastWinPid)) .. why)
                        or (DUEL.lastEndWhy ~= "" and DUEL.lastEndWhy or T("本场结束", "MATCH ENDED"))
            rows[#rows + 1] = { c = msg, col = colTitle }
            if DUEL.stateTill or DUEL.remSync > 0 then
                rows[#rows + 1] = { c = string.format(T("%d 秒后下一场", "NEXT MATCH IN %ds"), rem), col = colMute, size = small }
                rows[#rows + 1] = { c = T("下一位：", "NEXT: ") .. nxtName, col = colMute, size = small }
            else
                rows[#rows + 1] = { c = T("等人进来（够 2 人自动叫号）", "WAITING FOR PLAYERS"), col = colMute, size = small }
            end
        end
    end
    return rows
end

-- 11-17 用户"上场顺序可以在房间里调整么"：房主在成员页点一个人选中，再点"往前 / 往后 / 设为下一位"。
-- 叫号 / 交手中两位选手的位置锁住（不和他们换，免得打完轮换把赢家挤下去）；空闲时谁都能挪。改完立刻广播 mdq=
-- 11-17 用户"开战前房主可以切换登场顺序和即将对决的 2 人"：只在开打后（倒计时 / 交手 / 回合之间）锁住两位选手
local function fighterLocked(pid)
    if not (DUEL.state == "cd" or DUEL.state == "fight" or DUEL.state == "rend") then return false end
    return pid == DUEL.fa or pid == DUEL.fb
end
function DUEL.moveInQueue(pid, how, tn)
    if not mp.isHost() then return false end
    local idx
    for i = 1, #DUEL.order do if DUEL.order[i] == pid then idx = i end end
    if not idx or fighterLocked(pid) then return false end
    local o = DUEL.order
    local function swapWith(step)
        local j = idx + step
        while j >= 1 and j <= #o and fighterLocked(o[j]) do j = j + step end
        if j < 1 or j > #o then return false end
        o[idx], o[j] = o[j], o[idx]
        return true
    end
    local ok
    if how == "up" then ok = swapWith(-1)
    elseif how == "down" then ok = swapWith(1)
    elseif how == "next" then
        -- 挪到第一个不是在场选手的位置（= 下一位上场）
        table.remove(o, idx)
        local at = 1
        while at <= #o and fighterLocked(o[at]) do at = at + 1 end
        table.insert(o, at, pid)
        ok = true
    end
    if ok then
        out("对决：房主调整上场顺序 %d 号 %s → %s", pid, how, table.concat(o, ","))
        local t = tn or nowFn()
        -- 即将对决时换了排在最前的两位 → 重新叫号（两人的准备清掉）
        if DUEL.state == "ready" then
            local q = activeQueue()
            if #q >= 2 and not ((q[1] == DUEL.fa and q[2] == DUEL.fb) or (q[1] == DUEL.fb and q[2] == DUEL.fa)) then
                out("对决：房主换了即将对决的人 → %d vs %d", q[1], q[2])
                startReadyPair(q[1], q[2], t)
                return ok
            end
        end
        broadcastHostState(t, true)
    end
    return ok
end

-- 排队次序与房间战绩（成员页列全；11-15 以前直接列在房间面板、最多 6 行）
function DUEL.queueRows(items, pT)
    local T_ = pT or T
    local me = mp.myPid()
    local isH = mp.isHost()
    syncRoster(mp.roster())
    if isH and #DUEL.order > 1 then
        items[#items + 1] = { label = T_("（房主：点一个人选中，再调上场顺序）", "(HOST: CLICK A PLAYER, THEN REORDER)") }
    end
    if DUEL.selPid and not listHas(DUEL.order, DUEL.selPid) then DUEL.selPid = nil end
    for i = 1, #DUEL.order do
        local pid = DUEL.order[i]
        local st = DUEL.stats[pid] or { w = 0, l = 0 }
        local tag
        if pid == DUEL.fa or pid == DUEL.fb then tag = T_("[在场]", "[IN]")
        elseif DUEL.isWatch(pid) then tag = T_("[只看]", "[WATCH]")
        else tag = "#" .. i end
        local meMark = (pid == me) and T_("（我）", " (ME)") or ""
        local sel = isH and DUEL.selPid == pid
        local it = { label = string.format(T_("  %s%s %s%s  %d胜 %d负", "  %s%s %s%s  %dW %dL"), sel and "> " or "", tag, mp.nameOf(pid), meMark, st.w, st.l) }
        if isH and not fighterLocked(pid) then
            it.act = function() DUEL.selPid = (DUEL.selPid ~= pid) and pid or nil end
        end
        items[#items + 1] = it
        if sel and not fighterLocked(pid) then
            items[#items + 1] = { label = T_("      ↑ 往前一位", "      ↑ MOVE UP"), act = function() DUEL.moveInQueue(pid, "up") end }
            items[#items + 1] = { label = T_("      ↓ 往后一位", "      ↓ MOVE DOWN"), act = function() DUEL.moveInQueue(pid, "down") end }
            items[#items + 1] = { label = T_("      设为下一位上场", "      MAKE NEXT UP"), act = function() DUEL.moveInQueue(pid, "next") end }
        end
    end
end

-- 11-15 用户："玩法相关的要不要合并一个分类里，跟房间、系统设置平级，现在太长了"：
-- part = "settings" → 玩法设置页里的那几项（房间人数 / 轮换规则，房主才能改，别人只看）；part = "room"（默认）→ 房间面板里的（只看不上场 / 在场 / 开始）。
-- 排队次序和战绩挪到成员页（DUEL.queueRows），房间面板不再列
function DUEL.panel(items, pT, part, entry)
    local T_ = pT or T
    local me = mp.myPid()
    local isH = mp.isHost()
    local c = mp.cfg() or {}

    if part == "settings" then     -- 房间人数是三个玩法共用的一行（MP.rulesRows），这里只有轮换规则
        local rotName = (c.duelRot == "both") and T_("两人都下场", "BOTH ROTATE")
                        or (c.duelRot == "fixed") and T_("只有前两位上场（其他人只观战）", "FIRST TWO ONLY (OTHERS WATCH)")
                        or T_("败者下场（胜者守擂）", "LOSER ROTATES")
        items[#items + 1] = {
            label = string.format(T_("轮换规则：< %s >", "ROTATION: < %s >"), rotName),
            act = isH and function() mp.stepCfg("duelRot", DUEL.ROTS) end or nil
        }
        return
    end

    local watchName = DUEL.myWatch and T_("开", "ON") or T_("关", "OFF")
    items[#items + 1] = {
        label = string.format(T_("只看不上场：< %s >", "WATCH ONLY: < %s >"), watchName),
        act = function() DUEL.setWatchOnly(not DUEL.myWatch) end
    }

    if DUEL.fa and DUEL.fa ~= 0 and DUEL.fb and DUEL.fb ~= 0 then
        items[#items + 1] = { label = string.format(T_("在场：%s  对  %s", "FIGHTING: %s  VS  %s"), mp.nameOf(DUEL.fa), mp.nameOf(DUEL.fb)) }
    end
    if entry then entry(items, T_) end      -- 房间成员（排队次序 / 战绩）…，pbz_multi 传进来（MP.membersEntry）

    -- 11-17 用户"多了一层开启对决轮换的操作，感觉没必要"：去掉"开始 / 停止对决轮换"按钮，够 2 人自动叫号
    if DUEL.state == "ready" and (me == DUEL.fa or me == DUEL.fb) and not DUEL.readySet[me] then
        items[#items + 1] = {
            label = T_("准备上场（F1）", "READY TO FIGHT (F1)"),
            act = function() DUEL.f1() end
        }
    end
end

return DUEL
end
