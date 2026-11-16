-- PBZ_MP 多人混战 / 2v2 单机原型（2026-11-10，用户定的路线：替身执行层复用 1v1，网络层以后单独做）。
-- 不碰网络：在你身边生成 2–3 个替身，用本地 AI（同观战原型 pbz_spec.lua 的内置对打，绝影连段 + 武器技）打你，
-- 回答两个只有进游戏才知道的问题：①同时驱动 3 个替身的帧率（看日志 [耗时]）②几个替身同时打你时受击 / 格挡会不会乱。
-- 小键盘 / 开 / 关，小键盘 . 换模式（开着时换 = 按新模式重开）。模式：
--   1 围攻 2 人：两个敌人都打你（= 3 人混战里最坏的情况）
--   2 围攻 3 人：三个敌人都打你（= 4 人混战最坏情况）
--   3 混战 3 人：三个敌人，每隔几秒随机换目标（你 / 别的替身）；替身同阵营，互砍本机不判伤害（联机时靠各自机器的判定）
--   4 2v2：一个队友（玩家阵营，打不到你、你也打不到它）+ 两个敌人；队友打敌人、敌人随机打你或队友，这两边本机真扣血
-- 你自己挂锁血（GE_LockHealth，低于 40% 补满），开着时 Esc 菜单打不开，关掉原型就解除；替身也锁血、低于 40% 补满。
--
-- 用法（main.lua）：ST.multi = require("pbz_multi")({ out = out, ST = ST, MATCH = MATCH, G = G, activate = activateOnPuppet, LO = LO,
--   prof = PROF.wrap, specOn = function() ... end, ppOn = function() ... end })

return function(ctx)
local out, ST, MATCH, G = ctx.out, ctx.ST, ctx.MATCH, ctx.G
local valid, try, rawProp, now, pathOf, short = G.valid, G.try, G.rawProp, G.now, G.pathOf, G.short
local getP1, getP1PC = G.getP1, G.getP1PC

local FRIEND, FOE = "Faction.Player", "Faction.Enemy"
local FX_BLUE = "/Game/PBZContent/VFX/SceneFX/Common/NS_BlueLightBeam_301.NS_BlueLightBeam_301"
local FX_ORANGE = "/Game/PBZContent/VFX/SceneFX/Common/NS_OrangeLightBeam_301.NS_OrangeLightBeam_301"
local T = ctx.T or function(zh, en) return zh end
local RULE
local factionFor, updatePuppetFactions
local hostTakeBuff, onBuffPicked, clearAllBuffFx, updateBuffFx, restoreSpeed
local inMatch, myPid, nameOf, isHost, part, hostPid, lastHostPid
local checkHostChange, enter
local MP = {
    on = false, gen = 0, side = {}, store = {}, lastLogic = 0.0, mode = 1,
    RADIUS = 600.0,         -- 开场替身围着你的半径
    FALL = 800.0,           -- 比开场低这么多 = 掉下去了，放回开场位置
    TICK = 1 / 30,
    RETARGET = { 4.0, 8.0 },-- 混战 / 2v2 敌人多久换一次目标（秒，随机）
    STAT_SEC = 10.0,
}
MP.MODES = {
    { name = "围攻 2 人", n = 2, ally = 0, ffa = false },
    { name = "围攻 3 人", n = 3, ally = 0, ffa = false },
    { name = "混战 3 人", n = 3, ally = 0, ffa = true },
    { name = "2v2",       n = 3, ally = 1, ffa = true },
}
MP.MODES_GAME = { "elim", "score", "duel" }
local DUEL = nil
MP.TEAMS = { 0, 1, 3 }       -- 分队：0 各自为战 / 1 两队（历史值，包里 / mp.txt 都是 1）/ 3 三队（§317）
MP.MIN3 = 4                  -- §317 三队至少几个人才开（3 人 = 一人一队，等于各自为战）
function MP.teamCount(t)     -- 几队：0（不分队）/ 2 / 3
    t = tonumber(t)
    if t == 1 then return 2 elseif t == 3 then return 3 end
    return 0
end
function MP.teamsOn(t) return MP.teamCount(t) > 0 end
function MP.viewTeams()      -- §317 面板看的分队设置：房主看自己的；客机看房主发来的（旧房主没发 = 自己的）
    if MP.hostTeams ~= nil and not (isHost and isHost()) then return MP.hostTeams end
    return MP.cfg and MP.cfg.teams or 0
end
MP.BUFFS = { 1, 0 }
MP.SIEGES = { 1, 0 }
MP.LEASH = 3000.0           -- §306 T4：离场地中心的最小拉回距离（半径 ×5 和它取大）
MP.myTeamPick = 0           -- §306 T6：我选的队（0 自动 / 1 队 / 2 队 / 3 队（§317），只在内存）
MP.myWatch = false          -- §318 只看不上场（只在内存）：开局时不参加，对局里进观战镜头
MP.hostTeams = nil          -- §317 客机：房主对局外的分队设置（包里 mpo=），面板"我的队伍"按它显示；旧房主不发 = 按自己的设置

-- §306 T1：招式名是不是攻击动作。受击 / 破防 / 倒地 / 吃药 / 起身这些名字不算出招窗口里的"正在攻击"
MP.ATK_MONTAGE_BAD = { "_Hit_", "Break", "Knock", "Down", "Stagger", "Repel", "Deflect", "Parry",
                       "Block", "Guard", "Dodge", "Medicine", "Getup", "Dead",
                       -- 验收补：移动 / 换武器 / 表情类动作不是出招（否则站着换武器的人也被当成"正在打"）
                       "Roll", "Jump", "Land", "Equip", "Switch", "Swap", "Emote", "Idle", "Turn", "Walk", "Run", "Sprint" }
function MP.isAtkMontage(name)
    name = tostring(name or "")
    if name == "" then return false end
    for _, k in ipairs(MP.ATK_MONTAGE_BAD) do
        if name:find(k, 1, true) then return false end
    end
    return true
end

-- §306 T1：挨打方本机按"出招窗口"选打中者（不碰状态，ruleTick 只负责收集 cands 调它）。
-- cands 每项：{ pid, atkAt, atkMontage(bool), hitMeAt, aimMe(bool), dist, valid(bool) }
-- 返回 pid, how：window（只有一个窗口）/ window+tie（多个窗口按回报→朝向→距离）/ carry（沿用上一个打中我的）/
--                report（2 秒内的出招方实测回报）/ guess（4 秒 30 米位置猜测）/ nil
function MP.pickHitter(cands, tn, lastBy, lastAt)
    tn = tonumber(tn) or 0.0
    local list = {}
    for _, c in ipairs(cands or {}) do
        if c.valid ~= false and c.pid then list[#list + 1] = c end
    end
    local function near(a, b)
        local da, db = tonumber(a.dist) or math.huge, tonumber(b.dist) or math.huge
        if da ~= db then return da < db end
        return (a.pid or 0) < (b.pid or 0)
    end
    local win = {}
    for _, c in ipairs(list) do
        -- 出招窗口：1.2 秒内放过招，或者替身当前正在播攻击动作（霸体 / 出招中挨打不播受击时靠这个）
        if (c.atkAt and tn - c.atkAt <= 1.2) or c.atkMontage == true then
            c._rep = (c.hitMeAt and tn - c.hitMeAt <= 1.0) and true or false
            c._aim = c.aimMe == true
            win[#win + 1] = c
        end
    end
    if #win == 1 then return win[1].pid, "window" end
    if #win > 1 then
        -- 多个窗口：按 rep 优先、再 aim 优先、再距离近（最后才按打出时间新）
        table.sort(win, function(a, b)
            if a._rep ~= b._rep then return a._rep end
            if a._aim ~= b._aim then return a._aim end
            local da, db = tonumber(a.dist) or math.huge, tonumber(b.dist) or math.huge
            if da ~= db then return da < db end
            local aa, bb = tonumber(a.hitMeAt) or -math.huge, tonumber(b.hitMeAt) or -math.huge
            return aa > bb
        end)
        return win[1].pid, "window+tie"
    end
    -- 没有窗口：先看 1 秒内的出招方回报（远程 / 飞行物刚打中、出招动作已经收了的那种，回报说的就是这一下）
    do
        local fresh
        for _, c in ipairs(list) do
            if c.hitMeAt and tn - c.hitMeAt <= 1.0 and (not fresh or c.hitMeAt > fresh.hitMeAt) then fresh = c end
        end
        if fresh then return fresh.pid, "report" end
    end
    -- 再沿用 10 秒内上一个打中我的人（持续伤害跳伤 / 召唤物：这类没人回报）
    if lastBy and lastBy ~= 0 and lastAt and tn - lastAt <= 10.0 then
        for _, c in ipairs(list) do
            if c.pid == lastBy then return lastBy, "carry" end
        end
    end
    -- 2 秒内的出招方实测回报：取最近一次
    local rep = {}
    for _, c in ipairs(list) do
        if c.hitMeAt and tn - c.hitMeAt <= 2.0 then rep[#rep + 1] = c end
    end
    if #rep > 0 then
        table.sort(rep, function(a, b)
            local aa, bb = tonumber(a.hitMeAt) or -math.huge, tonumber(b.hitMeAt) or -math.huge
            if aa ~= bb then return aa > bb end
            return near(a, b)
        end)
        return rep[1].pid, "report"
    end
    -- 最后的位置猜测：4 秒内出过招、30 米内最近
    local guess = {}
    for _, c in ipairs(list) do
        if c.atkAt and tn - c.atkAt <= 4.0 and (tonumber(c.dist) or math.huge) <= 3000.0 then
            guess[#guess + 1] = c
        end
    end
    if #guess > 0 then
        table.sort(guess, near)
        return guess[1].pid, "guess"
    end
    return nil, nil
end

-- §306 T2：开局站位（纯函数）。arena = {cx,cy,cz,radius,yaw}；pids 已排序；teamOf = nil 各自为战 / 有则两队。
-- 各自为战：从基准朝向起算等分在圆上、面朝圆心（和 calcArenaSpawn 形状一样，只是角度多了基准朝向）。
-- 两队：1 队以基准朝向 +180° 为中点、2 队以基准朝向为中点；队友之间弦长 250，全部面朝圆心。
-- §317 三队（k = 3）：第 t 队以 基准朝向 +180° + (t-1)×120° 为中点（两队就是 +180° / +360°，和原来一样）。
MP.TEAM_SPAN = 1.44     -- 两队时每队最多占的弧度（约 83°）：π − 1.44 = 1.70，两队最近的敌人弦长 2r·sin(0.85) ≈ 1.5r
MP.TEAM_SPAN3 = 1.0     -- 三队时（中点隔 120°）：2π/3 − 1.0 ≈ 1.09，最近的敌人弦长 ≈ 1.04r
function MP.spawnPlan(arena, pids, teamOf, k)
    local plan = {}
    if not arena then return plan end
    local cx, cy, cz = tonumber(arena.cx) or 0.0, tonumber(arena.cy) or 0.0, tonumber(arena.cz) or 0.0
    local radius = math.max(tonumber(arena.radius) or 400.0, 1.0)
    local base = math.rad(tonumber(arena.yaw) or 0.0)
    local arr = {}
    for _, pid in ipairs(pids or {}) do arr[#arr + 1] = tonumber(pid) end
    table.sort(arr)
    local n = #arr
    if n == 0 then return plan end
    local function add(pid, ang)
        local px, py = cx + radius * math.cos(ang), cy + radius * math.sin(ang)
        local yaw = math.deg((math.atan2 or math.atan)(cy - py, cx - px))
        yaw = (yaw + 180) % 360 - 180
        plan[pid] = { X = px, Y = py, Z = cz, x = px, y = py, z = cz, yaw = yaw }
    end
    if not teamOf then
        for i, pid in ipairs(arr) do add(pid, base + (i - 1) * (2 * math.pi / n)) end
        return plan
    end
    k = (tonumber(k) == 3) and 3 or 2
    local groups = {}
    for t = 1, k do groups[t] = {} end
    for _, pid in ipairs(arr) do
        local tm = tonumber(teamOf[pid]) or 1
        if tm < 1 or tm > k then tm = 1 end
        groups[tm][#groups[tm] + 1] = pid
    end
    local delta = 2 * math.asin(math.min(1.0, 125.0 / radius))    -- 弦长 250（半径太小就按直径摆）
    -- 11-15 房间放到 12 人：一队 5–6 人时按 250 弦长排，两队的两头会在圆上碰到一起（半径 400 的场地 6v6 敌人几乎重叠）。
    -- 每队最多占 TEAM_SPAN（三队 TEAM_SPAN3）弧度，人多就挤近一点、别和别的队碰上
    local function spread(tm, mid)
        local m = #tm
        local span = (k == 3) and MP.TEAM_SPAN3 or MP.TEAM_SPAN
        local d = m > 1 and math.min(delta, span / (m - 1)) or delta
        for i, pid in ipairs(tm) do add(pid, mid + (i - (m + 1) / 2) * d) end
    end
    for t = 1, k do spread(groups[t], base + math.pi + (t - 1) * (2 * math.pi / k)) end
    return plan
end

-- §306 T3：复活点（纯函数）。cands = 候选点（X/Y），enemies = 敌人位置；挑"离最近的敌人最远"的那个。
function MP.pickRespawn(cands, enemies)
    local best, bestD
    for _, c in ipairs(cands or {}) do
        local md = math.huge
        for _, e in ipairs(enemies or {}) do
            local dx = (tonumber(c.X) or 0.0) - (tonumber(e.X) or 0.0)
            local dy = (tonumber(c.Y) or 0.0) - (tonumber(e.Y) or 0.0)
            local d = math.sqrt(dx * dx + dy * dy)
            if d < md then md = d end
        end
        if not best or md > bestD then best, bestD = c, md end
    end
    return best, bestD
end

-- §306 T6：分队（纯函数）。房主指定 force 优先于本人选择 want，剩下"自动"的按编号依次补到人少的一队（一样多补编号小的队）。
-- §317 k = 队数（2 / 3，默认 2）；选了超出队数的（比如三队时选的 3 队、又换回两队）按"自动"
function MP.assignTeams(pids, force, want, k)
    force, want = force or {}, want or {}
    k = (tonumber(k) == 3) and 3 or 2
    local arr = {}
    for _, pid in ipairs(pids or {}) do arr[#arr + 1] = tonumber(pid) end
    table.sort(arr)
    local out, cnt = {}, {}
    for t = 1, k do cnt[t] = 0 end
    local function ok(tm) return tm and tm >= 1 and tm <= k and tm == math.floor(tm) end
    local function take(pid, tm)
        out[pid] = tm
        cnt[tm] = cnt[tm] + 1
    end
    for _, pid in ipairs(arr) do
        local tm = tonumber(force[pid])
        if ok(tm) and not out[pid] then take(pid, tm) end
    end
    for _, pid in ipairs(arr) do
        if not out[pid] then
            local tm = tonumber(want[pid])
            if ok(tm) then take(pid, tm) end
        end
    end
    for _, pid in ipairs(arr) do
        if not out[pid] then
            local best = 1
            for t = 2, k do if cnt[t] < cnt[best] then best = t end end
            take(pid, best)
        end
    end
    return out
end
-- §317 各队人数 → "2 对 2 对 1"
function MP.teamSizes(teamOf, pids, k)
    local cnt = {}
    for t = 1, k do cnt[t] = 0 end
    for _, pid in ipairs(pids) do
        local tm = tonumber(teamOf[pid]) or 1
        if cnt[tm] then cnt[tm] = cnt[tm] + 1 end
    end
    return cnt
end

local function loc(a) return try("multi loc", function() return a:K2_GetActorLocation() end) end
local function d2(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end
local function LO_short(path) return path and (path:match("([^.]+)$") or path) or "?" end

-- 【适配】SpawnActor(玩家1 的类) + SpawnActor(AIController) + Possess；藏起来的旧的复用（玩家类角色销毁会崩，v0.11.0）
-- 和 pbz_spec.lua 的 spawnOne 一样，各自一份存储（不占 ST.secondPawn，也不和观战的替身混）
local function spawnOne(i, pos)
    local p1 = getP1()
    local st = MP.store[i]
    local pup, ctl
    if st and valid(st.pup) then
        pup, ctl = st.pup, st.ctl
        pcall(function() pup:SetActorHiddenInGame(false) end)
        pcall(function() pup:SetActorEnableCollision(true) end)
        local cm = rawProp(pup, "CharacterMovement")
        if valid(cm) then pcall(function() cm:SetMovementMode(1, 0) end) end
        pcall(function() pup:K2_SetActorLocation(pos, false, {}, true) end)
    else
        local okC, cls = pcall(function() return p1:GetClass() end)
        local world = try("multi world", function() return p1:GetWorld() end)
        if not (okC and valid(cls) and valid(world)) then return nil end
        pup = try("multi spawn", function() return world:SpawnActor(cls, pos, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }) end)
        if not valid(pup) then return nil end
        local aic = StaticFindObject("/Script/AIModule.AIController")
        ctl = valid(aic) and try("multi aic", function()
            return world:SpawnActor(aic, pos, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }) end) or nil
        if valid(ctl) then pcall(function() ctl:Possess(pup) end) end
        MP.store[i] = { pup = pup, ctl = ctl }
    end
    G.copyStats(p1, pup)
    local cm = rawProp(pup, "CharacterMovement")
    if valid(cm) then
        pcall(function() cm.MaxWalkSpeed = math.max(tonumber(rawProp(cm, "MaxWalkSpeed")) or 0, 1400.0) end)
        pcall(function() cm.MaxAcceleration = math.max(tonumber(rawProp(cm, "MaxAcceleration")) or 0, 6000.0) end)
    end
    if valid(ctl) then pcall(function() ctl:ResetIgnoreMoveInput() end) end
    return pup, ctl
end

-- 【适配】藏起来留着复用（同 pbz_spec.lua hideOne）
local function hideOne(pup)
    if not valid(pup) then return end
    G.cancelMoves(pup)
    G.cutMontage(pup)
    local cm = rawProp(pup, "CharacterMovement")
    if valid(cm) then pcall(function() cm:DisableMovement() end) end
    -- §320 先挪出锁定范围（§226）：只藏 + 关碰撞，游戏的锁定照样能选中它（11-15 实测：多人联机结束后原地留下 3 个能锁的空气人）
    if G.stashAway then G.stashAway(pup) end
    pcall(function() pup:SetActorHiddenInGame(true) end)
    pcall(function() pup:SetActorEnableCollision(false) end)
end

-- 【适配】FactionComponent:SetFaction
local function setFaction(pup, want)
    local fc = G.factionComp(pup)
    return valid(fc) and pcall(function() fc:SetFaction({ TagName = FName(want) }) end)
end

local function relation(a, b)
    local ok, v = pcall(function() return G.factionComp(a):GetFactionRelation(b) end)
    return ok and tostring(v) or "?"
end

-- ============================================================ AI：照搬观战原型的内置对打（= 本地 AI §75 的招式表）

local function steer(s, target)
    local cur = loc(s.pup)
    if not cur then return end
    local dx, dy = target.X - cur.X, target.Y - cur.Y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist > 1500.0 then
        pcall(function() s.pup:K2_SetActorLocation({ X = target.X, Y = target.Y, Z = (target.Z or cur.Z) + 20.0 }, false, {}, true) end)
        s.feed = nil
        return
    end
    if dist < 20.0 then s.feed = nil; return end
    local sp = math.min(dist * 3.0, dist > 200.0 and 1400.0 or 600.0)
    local vx, vy = dx / dist * sp, dy / dist * sp
    local cm = rawProp(s.pup, "CharacterMovement")
    if valid(cm) then
        local vz = 0.0
        pcall(function() vz = cm.Velocity.Z end)
        pcall(function() cm.Velocity = { X = vx, Y = vy, Z = vz } end)
    end
    s.feed = { dir = { X = dx / dist, Y = dy / dist, Z = 0.0 }, scale = math.min(1.0, sp / 600.0), left = 12 }
end

local function turn(s, yaw)
    G.setYaw(s.pup, yaw)
    if valid(s.ctl) then pcall(function() s.ctl:SetControlRotation({ Pitch = 0.0, Yaw = yaw, Roll = 0.0 }) end) end
end

local function face(s, tgt)
    local a, b = loc(s.pup), loc(tgt)
    if a and b then turn(s, G.yawTo(a, b)) end
end

local D = "GA_Hun_Double_"
local AI = {
    WC = "/PBZCombatAsset/ActorData/Players/Hun/Weapon/Double/Weapon_Hun_JueYing.Weapon_Hun_JueYing",
    DIST = 300.0, GAP = 0.45,
    COMBOS = {
        { D .. "A_C", D .. "AA_C", D .. "AAA_C" }, { D .. "A_C", D .. "AA_C", D .. "AAA_C", D .. "AAAA_C" },
        { D .. "B_C", D .. "BB_C" }, { D .. "A_C", D .. "AB_C" }, { D .. "B_Dash_C" }, { D .. "SWT_C" },
        { D .. "A_C", D .. "AA_C" } },
    SKILLS = {
        { D .. "JueYing_C_C" }, { D .. "Buff_C" }, { D .. "C_C" },
        { D .. "A_Draw_C" }, { D .. "B_Draw_C" }, { D .. "ATB_C", D .. "ATBB_C", D .. "ATBBB_C" },
        { D .. "BTA_C" }, { D .. "A_DashDraw_Short_C" }, { D .. "B_DashDraw_C" },
        { D .. "A_Snap_C" }, { D .. "B_Snap_C" } },
}

-- 换武器：只改替身自己的武器组件（LO.dressSlot，不碰玩家装备）。换上之后技能表作废重读（每个替身一份缓存，ST.abMapKey = nil 全部作废）
local function dress(s)
    local cwc = rawProp(s.pup, "Character Weapons Component")
    if not valid(cwc) then return end
    s.dressSt = s.dressSt or {}
    ctx.LO.dressSlot(s.pup, getP1(), cwc, ctx.LO.slot(), AI.WC, "混战原型 " .. s.tag .. " 武器", s.dressSt)
    local ok = ctx.LO.heldConfig(s.pup) == AI.WC
    if ok ~= s.armed then
        s.armed = ok
        if ok then ST.abMapKey = nil end
        out("混战原型 %s 手上武器 %s%s", s.tag, LO_short(ctx.LO.heldConfig(s.pup)), ok and "（绝影 ✓）" or "（还不是绝影）")
    end
end

-- 目标候选：敌人打你 / 队友 / 别的敌人（混战）；队友只打敌人
local function pickTarget(s, tn)
    local m = MP.MODES[MP.mode]
    local p1 = getP1()
    local cands = {}
    if s.ally then
        for _, o in ipairs(MP.side) do if not o.ally and valid(o.pup) then cands[#cands + 1] = { pup = o.pup, tag = o.tag } end end
    else
        cands[1] = { pup = p1, tag = "你" }
        if m.ffa then
            -- 2v2（有队友）：敌人只打你和队友，不打另一个敌人（11-10 实测日志里"敌2 打敌1"）
            for _, o in ipairs(MP.side) do
                if o ~= s and valid(o.pup) and (m.ally == 0 or o.ally) then cands[#cands + 1] = { pup = o.pup, tag = o.tag } end
            end
        end
    end
    local c = cands[math.random(#cands)]
    if not c then return end
    if s.tgtTag ~= c.tag then
        s.retargets = (s.retargets or 0) + 1
        G.setLockTarget(s.pup, c.pup)
    end
    s.tgt, s.tgtTag = c.pup, c.tag
    s.tgtUntil = m.ffa and tn + MP.RETARGET[1] + math.random() * (MP.RETARGET[2] - MP.RETARGET[1]) or math.huge
end

local function aiStep(s, tn)
    if not valid(s.tgt) or tn >= (s.tgtUntil or 0) then pickTarget(s, tn) end
    if not valid(s.tgt) then return end
    local a, b = loc(s.pup), loc(s.tgt)
    if not (a and b) then return end
    local dist = d2(a, b)
    if s.seq then
        s.feed = nil
        if tn < s.nextAt then return end
        local n = s.seq[s.si]
        if not n then
            s.seq, s.cdUntil = nil, tn + 0.6 + math.random()
            return
        end
        face(s, s.tgt)
        local ok = ctx.activate(s.pup, n, s.sub, "混战原型 " .. s.tag)
        s.fired, s.failed = (s.fired or 0) + (ok and 1 or 0), (s.failed or 0) + (ok and 0 or 1)
        if ok then s.atkAt = tn end
        s.si, s.nextAt = s.si + 1, tn + AI.GAP + math.random() * 0.2
        if not ok then s.seq, s.cdUntil = nil, tn + 0.5 end
        return
    end
    if G.montageOf(s.pup) ~= "" then s.feed = nil; return end
    if dist > AI.DIST then
        steer(s, { X = b.X - (b.X - a.X) / dist * (AI.DIST - 60), Y = b.Y - (b.Y - a.Y) / dist * (AI.DIST - 60) })
        face(s, s.tgt)
        return
    end
    if tn >= (s.cdUntil or 0) and s.armed then
        local pool = math.random() < 0.7 and AI.COMBOS or AI.SKILLS
        s.seq, s.si, s.nextAt = pool[math.random(#pool)], 1, tn
        return
    end
    -- 等冷却：绕着目标横移，几个替身方向错开，免得挤成一团
    local ang = math.atan(a.Y - b.Y, a.X - b.X) + (s.idx % 2 == 1 and 0.06 or -0.06)
    steer(s, { X = b.X + math.cos(ang) * AI.DIST * 0.8, Y = b.Y + math.sin(ang) * AI.DIST * 0.8 })
    face(s, s.tgt)
end

-- ============================================================ 血条：每个替身一条（游戏最多同时 3 条），认领时跳过已经认领的

local function bossBarStep(s, tn, claimed)
    if not s.barReg then
        if tn < (s.barTryAt or 0) then return false end
        s.barTryAt = tn + 2.0
        local ok, err = G.bossBarShow(s.pup)
        s.barReg = ok
        out("混战原型 %s 血条：RegisterBossHPBar %s", s.tag, ok and "成功" or tostring(err))
        return false
    end
    if not valid(s.bar) then
        s.bar = G.bossBarOf(s.pup, true, claimed)
        if not valid(s.bar) then
            s.barMiss = (s.barMiss or 0) + 1
            if s.barMiss == 15 then
                out("!! 混战原型 %s 血条：注册了但找不到控件", s.tag)
                for _, l in ipairs(G.bossBarDiag(s.pup)) do out("  %s", l) end
            end
            return false
        end
        s.barShOn = nil      -- §295 杀气那条显不显示：下面按房间设置写
        s.nameAt = nil
        out("混战原型 %s 血条：%s", s.tag, short(pathOf(s.bar)))
    end
    local hp, hm = G.attrOf(s.pup, "Health"), G.attrOf(s.pup, "Health_Max")
    local sc, sm = G.attrOf(s.pup, "Shachi"), G.attrOf(s.pup, "Shachi_Max")
    if s.live then hp, hm, sc, sm = s.hp, s.hpm, s.sh, s.shm end       -- 联机：按那位玩家包里的血量 / 杀气，不看替身自己的
    -- §295 房间设置"对手血条"：1 = 只显示血（杀气那条藏起来）；队友 / 没在对局里的照常显示
    local shOn = not (s.barMode == 1)
    if s.barShOn ~= shOn then s.barShOn = shOn; G.bossBarShachiShow(s.bar, shOn) end
    local v = { hp = (hp and hm and hm > 0) and hp / hm or nil, sh = (shOn and sc and sm and sm > 0) and sc / sm or nil }
    if not s.nameAt or tn - s.nameAt > 1.0 then s.nameAt = tn; v.name = s.name end
    G.bossBarSet(s.bar, v)
    return true
end

-- ============================================================ 你挨打 / 格挡统计（看动作名的变化，只读）

local HIT_KEYS = { "_Hit_", "Break", "KnockDown", "Knock", "Down", "Stagger", "Repel" }
local GUARD_KEYS = { "Deflect", "Parry", "Block", "Defense", "Guard" }
local function classify(m)
    for _, k in ipairs(GUARD_KEYS) do if m:find(k, 1, true) then return "guard" end end
    for _, k in ipairs(HIT_KEYS) do if m:find(k, 1, true) then return "hit" end end
    return nil
end

local function selfStep(tn)
    local p1 = getP1()
    if not valid(p1) then return end
    local m = G.montageOf(p1) or ""
    local me = MP.me
    if m ~= me.lastM then
        local k = m ~= "" and classify(m) or nil
        if k == "hit" then
            me.hits = me.hits + 1
            -- 受击动作还没放完又换成另一个受击动作 = 连续被打断（几个人同时砍时最容易乱的地方）
            if me.lastKind == "hit" then me.chain = me.chain + 1 end
            me.names[m] = (me.names[m] or 0) + 1
        elseif k == "guard" then
            me.guards = me.guards + 1
            me.names[m] = (me.names[m] or 0) + 1
        end
        me.lastM, me.lastKind = m, k
    end
    -- 同时有几个替身正在对你出招（最近 0.6 秒内放过招、目标是你、身上有动作）
    local n = 0
    for _, s in ipairs(MP.side) do
        if not s.ally and s.tgt and G.valid(s.tgt) and s.tgtTag == "你" and s.atkAt and tn - s.atkAt < 0.6 then n = n + 1 end
    end
    me.ticks = me.ticks + 1
    if n >= 2 then me.multi2 = me.multi2 + 1 end
    if n >= 3 then me.multi3 = me.multi3 + 1 end
    if n > me.multiMax then me.multiMax = n end
    if tn - (me.refillAt or 0) > 0.5 then
        me.refillAt = tn
        local hp, mx = G.hpOf(p1), G.attrOf(p1, "Health_Max")
        if hp and mx and hp < mx * 0.4 then G.refill(p1); me.refills = me.refills + 1 end
    end
end

-- ============================================================ 主循环

local function logic()
    local tn = now()
    for _, s in ipairs(MP.side) do
        if not valid(s.pup) then MP.stop("替身没了"); return end
    end
    for _, s in ipairs(MP.side) do
        if tn - (s.dressAt or 0) > 0.25 then s.dressAt = tn; dress(s) end
        aiStep(s, tn)
        local l = loc(s.pup)
        if l and l.Z < s.az - MP.FALL then
            pcall(function() s.pup:K2_SetActorLocation({ X = s.ax, Y = s.ay, Z = s.az + 50.0 }, false, {}, true) end)
            local cm = rawProp(s.pup, "CharacterMovement")
            if valid(cm) then pcall(function() cm.Velocity = { X = 0.0, Y = 0.0, Z = 0.0 } end) end
            s.falls = (s.falls or 0) + 1
            if s.falls <= 3 then out("混战原型 %s 掉下去了（Z %.0f），放回开场位置", s.tag, l.Z) end
        end
        if tn - (s.hpAt or 0) > 1.0 then
            s.hpAt = tn
            local hp, mx = G.attrOf(s.pup, "Health"), G.attrOf(s.pup, "Health_Max")
            if hp and mx and hp < mx * 0.4 then G.setAttr(s.pup, "Health", mx); s.refills = (s.refills or 0) + 1 end
            local sm, sc = G.attrOf(s.pup, "Shachi_Max"), G.attrOf(s.pup, "Shachi")
            if sm and sc and sc < sm * 0.2 then G.setAttr(s.pup, "Shachi", sm) end
        end
    end
    selfStep(tn)
    if tn - (MP.barAt or 0) > 0.2 then
        MP.barAt = tn
        local claimed = {}
        for _, s in ipairs(MP.side) do
            if valid(s.bar) then claimed[#claimed + 1] = s.bar end
        end
        -- 一个一个认领：前一个没认到之前后一个不注册（同观战原型：新注册的血条 Character 是空的，只能认空的）
        for _, s in ipairs(MP.side) do
            local ok = bossBarStep(s, tn, claimed)
            if valid(s.bar) then
                local dup = false
                for _, c in ipairs(claimed) do if G.sameObj(c, s.bar) then dup = true end end
                if not dup then claimed[#claimed + 1] = s.bar end
            end
            if not ok then break end
        end
    end
    if tn - (MP.statAt or 0) > MP.STAT_SEC then
        local dt = tn - (MP.statAt or tn)
        MP.statAt = tn
        local parts = {}
        for _, s in ipairs(MP.side) do
            parts[#parts + 1] = string.format("%s 打%s 出招 %d 失败 %d 补血 %d 换目标 %d", s.tag, s.tgtTag or "?",
                s.fired or 0, s.failed or 0, s.refills or 0, s.retargets or 0)
            s.fired, s.failed, s.retargets = 0, 0, 0
        end
        local me = MP.me
        local top = {}
        for nm, c in pairs(me.names) do top[#top + 1] = { nm, c } end
        table.sort(top, function(x, y) return x[2] > y[2] end)
        local tops = {}
        for i = 1, math.min(4, #top) do tops[#tops + 1] = string.format("%s×%d", top[i][1], top[i][2]) end
        out("混战原型 [%s] %.0f 秒 | %s | 你：受击 %d（受击中又被打断 %d）格挡类 %d 补血 %d | 同时对你出招 ≥2 人 %.0f%% ≥3 人 %.0f%% 最多 %d 人 | 动作 %s",
            MP.MODES[MP.mode].name, dt, table.concat(parts, "；"), me.hits, me.chain, me.guards, me.refills,
            me.ticks > 0 and me.multi2 * 100 / me.ticks or 0, me.ticks > 0 and me.multi3 * 100 / me.ticks or 0, me.multiMax,
            #tops > 0 and table.concat(tops, " ") or "-")
        MP.me = { hits = 0, chain = 0, guards = 0, refills = 0, ticks = 0, multi2 = 0, multi3 = 0, multiMax = 0, names = {},
                  lastM = me.lastM, lastKind = me.lastKind, refillAt = me.refillAt }
    end
end

-- 锁定点：替身身上的 LockViewTarget 没人摆，一直在地图原点（同 main.lua §19 fixPuppetLockPoint，那个只管对战替身）。
-- 11-10 实测"锁定好像锁了原点"。每帧放到替身胸口
-- 【适配】Actor.LockViewTarget:K2_SetWorldLocation
local LOCK_Z = 40.0
local function fixLockPoint(s)
    local comp = rawProp(s.pup, "LockViewTarget")
    if not valid(comp) then
        if not s.lockWarned then s.lockWarned = true; out("!! 混战原型 %s 没有 LockViewTarget", s.tag) end
        return
    end
    local l = loc(s.pup)
    if not l then return end
    local ok = pcall(function() comp:K2_SetWorldLocation({ X = l.X, Y = l.Y, Z = l.Z + LOCK_Z }, false, {}, true) end)
    if not s.lockLogged then
        s.lockLogged = true
        out("混战原型 %s 锁定点每帧跟随：设置%s", s.tag, ok and "成功" or "失败")
    end
end

local function frame()
    for _, s in ipairs(MP.side) do
        if valid(s.pup) then pcall(fixLockPoint, s) end
        local f = s.feed
        if f and f.left > 0 and valid(s.pup) then
            f.left = f.left - 1
            pcall(function() s.pup:AddMovementInput(f.dir, f.scale, true) end)
        end
    end
    local c = os.clock()
    if c - MP.lastLogic >= MP.TICK then
        MP.lastLogic = c
        local ok, err = pcall(MP.logicP)
        if not ok then out("!! 混战原型 -> %s", tostring(err)) end
    end
end
MP.logicP = ctx.prof and ctx.prof("混战原型", logic) or logic

function MP.start()
    if MP.on then return end
    local p1, pc = getP1(), getP1PC()
    if not (valid(p1) and valid(pc)) then out("!! 混战原型：没有玩家1"); return end
    if MATCH.role then out("!! 混战原型：对局中不能开"); return end
    if valid(G.puppet()) then out("!! 混战原型：先按 F6 移除对战用的替身"); return end
    if ctx.specOn and ctx.specOn() then out("!! 混战原型：观战中不能开"); return end
    if ctx.ppOn and ctx.ppOn() then out("!! 混战原型：Phantom Pact 合作联机中不能开"); return end
    if ST.stableTicks < 90 then out("混战原型：世界还在加载，等几秒再按"); return end
    local l = loc(p1)
    local rot = try("multi rot", function() return p1:K2_GetActorRotation() end)
    if not (l and rot) then return end
    local m = MP.MODES[MP.mode]
    MP.side = {}
    for i = 1, m.n do
        -- 围着你摆一圈：第一个在正前方，其余平均分开
        local ang = math.rad(rot.Yaw) + (i - 1) * (2 * math.pi / m.n)
        local pos = { X = l.X + math.cos(ang) * MP.RADIUS, Y = l.Y + math.sin(ang) * MP.RADIUS, Z = l.Z + 50.0 }
        local pup, ctl = spawnOne(i, pos)
        if not valid(pup) then
            out("!! 混战原型：替身 %d 生成失败", i)
            for _, s in ipairs(MP.side) do hideOne(s.pup) end
            MP.side = {}
            return
        end
        local ally = i <= m.ally
        local tag = ally and "队友" or ("敌" .. (i - m.ally))
        local s = { idx = i, tag = tag, ally = ally, pup = pup, ctl = ctl, sub = {}, ax = pos.X, ay = pos.Y, az = l.Z,
                    name = ally and "队友（玩家阵营）" or ("敌人 " .. (i - m.ally)) }
        turn(s, G.yawTo(pos, l))
        MP.side[i] = s
    end
    local facs = {}
    for _, s in ipairs(MP.side) do
        local ok = setFaction(s.pup, s.ally and FRIEND or FOE)
        G.noStealthByGE(s.pup, "混战原型 " .. s.tag .. " 锁血")
        facs[#facs + 1] = string.format("%s %s%s（和你的关系 %s）", s.tag, s.ally and FRIEND or FOE, ok and "" or " 设置失败", relation(s.pup, p1))
    end
    local rel = {}
    for i = 1, #MP.side do
        for j = i + 1, #MP.side do
            rel[#rel + 1] = string.format("%s-%s %s", MP.side[i].tag, MP.side[j].tag, relation(MP.side[i].pup, MP.side[j].pup))
        end
    end
    MP.locked = G.lockSelf(p1)
    MP.me = { hits = 0, chain = 0, guards = 0, refills = 0, ticks = 0, multi2 = 0, multi3 = 0, multiMax = 0, names = {}, lastM = "" }
    out("混战原型开始：模式 %s，%d 个替身；%s；替身之间 %s；你自己锁血 %s",
        m.name, #MP.side, table.concat(facs, "，"), #rel > 0 and table.concat(rel, "，") or "-", MP.locked and "成功" or "失败")
    MP.statAt = now()
    MP.on = true
    MP.gen = MP.gen + 1
    local gen = MP.gen
    if type(LoopInGameThreadAfterFrames) == "function" then
        LoopInGameThreadAfterFrames(1, function()
            if not MP.on or MP.gen ~= gen or ST.travel then return true end
            frame()
        end)
    else
        out("!! 混战原型：没有 LoopInGameThreadAfterFrames")
    end
    if ctx.notice then ctx.notice("混战原型：" .. m.name, "小键盘 / 关闭，小键盘 . 换模式；开着时 Esc 菜单打不开", 4.0) end
end

function MP.stop(why)
    if not MP.on then return end
    MP.on = false
    for _, s in ipairs(MP.side) do
        if s.barReg then G.bossBarHide(s.pup) end
        hideOne(s.pup)
    end
    MP.side = {}
    local p1 = getP1()
    if MP.locked and valid(p1) then G.unlockSelf(p1, "混战原型结束") end
    MP.locked = nil
    out("混战原型结束（%s）", why or "")
end

function MP.toggle()
    if MP.on then MP.stop("小键盘 /") else MP.start() end
end

function MP.nextMode()
    MP.mode = MP.mode % #MP.MODES + 1
    local m = MP.MODES[MP.mode]
    out("混战原型：模式换成 %s", m.name)
    if MP.on then MP.stop("换模式"); MP.start()
    elseif ctx.notice then ctx.notice("混战原型模式：" .. m.name, "小键盘 / 开始", 2.0) end
end

-- ============================================================ ②b 联机：多人房间里每位玩家一个替身（docs/MULTI.md）
-- 联机程序把每位玩家的状态包加 src=<编号>（主机 1）交给游戏，main.lua 的 netRecv 交到 MP.feed。
-- 收包驱动：§287 起每个替身一份 PEER（同观战，对战替身的 NET.recvOne / NET.drive 整套）；血条的数还借观战的 SP._live.apply；
-- 没有 PEER 时才用下面借观战旧那套的跟随 / 换装兜底（只跟位置，§223 后不出招）。替身都设敌方阵营、挂锁血，
-- 血条按包里的 hp= 写。判定照旧是防守方：替身在我这台机器打到我，本机真扣血，我的 hp= 随包发给别人。
-- 对局规则（②d）还没做：联机多人开着时自己锁血、低于 40% 补满，打不死
local NETP = { side = {}, list = {}, on = false, gen = 0, IDLE = 3.0, DROP = 15.0, STAT_SEC = 10.0, lastLogic = 0.0, warned = {} }
local tagDrop        -- 头顶血条界面（M3）；先声明，netIdle / netDrop 里要用
MP.netp = NETP

function MP.aiSet()
    local s = ctx.session and ctx.session() or {}
    local map, list = {}, {}
    for idStr in (s.mpai or ""):gmatch("(%d+)") do
        local id = tonumber(idStr)
        if id and id > 0 and not map[id] then
            map[id] = true
            list[#list + 1] = id
        end
    end
    table.sort(list)
    return map, list
end

function MP.isAiPid(pid)
    pid = tonumber(pid)
    if not (pid and pid > 0) then return false end
    local set = MP.aiSet()
    if set[pid] then return true end
    local side = NETP.side[pid]
    if side and type(side.nick) == "string" and side.nick:sub(1, 4) == "[AI]" then return true end
    local s = ctx.session and ctx.session() or {}
    for idStr, nm in (s.mpl or ""):gmatch("(%d+):([^,]*)") do
        if tonumber(idStr) == pid and nm:sub(1, 4) == "[AI]" then return true end
    end
    return false
end

local function aiPrefixed(pid, nm)
    if type(nm) ~= "string" then nm = "" end
    if MP.isAiPid(pid) and nm:sub(1, 4) ~= "[AI]" then
        return nm == "" and "[AI]" or ("[AI] " .. nm)
    end
    return nm
end

local function aiSpotFromPlan(target, fallback)
    if not target then target = fallback end
    if not target then return { X = 0.0, Y = 0.0, Z = 0.0, yaw = 0.0 } end
    local tx = tonumber(target.X or target.x) or 0.0
    local ty = tonumber(target.Y or target.y) or 0.0
    local tz = tonumber(target.Z or target.z) or 0.0
    local p1 = getP1 and getP1()
    if valid(p1) and G.floorBelow then
        local hasF, fz = G.floorBelow(p1, { X = tx, Y = ty, Z = tz + 100.0 }, 800.0)
        if hasF and fz then tz = fz + 30.0 end
    end
    return { X = tx, Y = ty, Z = tz, yaw = tonumber(target.yaw) or 0.0 }
end

local function live() local sp = ctx.spec and ctx.spec(); return sp and sp._live end

-- §287 多人替身走对战替身那一套（同观战 §223.1）：每个远端玩家一份 PEER 状态（main.lua 的全局 PEER；ctx.peer 优先，测试注入用）。
-- §223 起观战的 pktApply 对 s.live 只记血条的数就返回（招式等交给 PEER.recv），多人这边一直借它 → 替身只跟位置、不出招 / 不换装（11-13 审查）。
-- 有 PEER 时：出招 / 受击 / 破防 / 喝药 / 技能内动作 / 换装 / 皮肤 / 武器效果 / 被动 / att= 攻击属性 / 锁定 / 空中 / 闪避方向 / 异常状态 /
-- 蓄力松手 / 召唤物 / 位置（NPM 严格跟随）全由 NET.recvOne + NET.drive 做；下面的 followOne / walkTurn / dressOne 只在没有 PEER 时兜底
local function peerMod() local p = ctx.peer or rawget(_G, "PEER"); return type(p) == "table" and type(p.new) == "function" and p or nil end
MP.TGT_RANGE, MP.TGT_ANGLE = 3000.0, 75.0

local function netSpawn(pid, t)
    local x, y, z = tonumber(t.x), tonumber(t.y), tonumber(t.z)
    if not (x and y) then return nil end
    local p1 = getP1()
    local l = valid(p1) and loc(p1)
    local pos = { X = x, Y = y, Z = (z or (l and l.Z) or 0) + 50.0 }
    local pup, ctl = spawnOne("n" .. pid, pos)
    if not valid(pup) then
        if not NETP.warned[pid] then NETP.warned[pid] = true; out("!! 多人：%d 号的替身生成失败", pid) end
        return nil
    end
    local s = { idx = pid, tag = pid .. "号", pup = pup, ctl = ctl, sub = {}, cnt = {}, live = true, ax = pos.X, ay = pos.Y, az = pos.Z,
                name = pid .. "号", cm = rawProp(pup, "CharacterMovement"), lockComp = rawProp(pup, "LockViewTarget") }
    NETP.spawnAt = now()       -- 饰品去重只在替身刚生成后的一阵子做（MP.accWindow）
    local fac = factionFor and factionFor(s) or FOE
    local okF = setFaction(pup, fac)
    G.noStealthByGE(pup, "多人 " .. s.tag .. " 锁血")
    local PM = peerMod()
    if PM then s.peer = PM.new(s.tag, pup, ctl) end     -- §287 这个替身自己那份"对战替身"状态
    NETP.side[pid] = s
    NETP.list = {}
    for _, v in pairs(NETP.side) do NETP.list[#NETP.list + 1] = v end
    table.sort(NETP.list, function(a, b) return a.idx < b.idx end)
    out("多人：%d 号的替身生成（阵营 %s%s，和你的关系 %s；%s）", pid, fac, okF and "" or " 设置失败", valid(p1) and relation(pup, p1) or "?",
        s.peer and "走对战替身那一套" or "!! 没有 PEER，只跟位置")
    return s
end

local function netIdle(s, on, why)
    if s.idle == on then return end
    s.idle = on
    -- §320 藏起来时挪到头顶外、停移动（§226：只藏 + 关碰撞还能被锁定，对局里藏起来的观众也会被正在打的人锁上）；
    -- 显示时摆回最新的包位置（没包就回原处）、恢复走路，再显示
    local cm = rawProp(s.pup, "CharacterMovement")
    if on then
        s.stashFrom = loc(s.pup)
        if valid(cm) then pcall(function() cm:DisableMovement() end) end
        if G.stashAway then G.stashAway(s.pup) end
    else
        local t = s.last or {}
        local x, y, z = tonumber(t.x), tonumber(t.y), tonumber(t.z)
        local back = (x and y and z) and { X = x, Y = y, Z = z + 50.0 } or s.stashFrom
        if valid(cm) then pcall(function() cm:SetMovementMode(1, 0) end) end
        if back then pcall(function() s.pup:K2_SetActorLocation(back, false, {}, true) end) end
        s.stashFrom = nil
    end
    pcall(function() s.pup:SetActorHiddenInGame(on) end)
    pcall(function() s.pup:SetActorEnableCollision(not on) end)
    if on then
        if s.barReg then G.bossBarHide(s.pup) end
        s.barReg, s.bar, s.barMiss = false, nil, 0
        if tagDrop then tagDrop(s) end
    end
    out("多人 %s：%s", s.tag, why or (on and "没包了 / 不在这张图，藏起来" or "又有包了，显示"))
end

local function netDrop(s, why)
    if s.barReg then G.bossBarHide(s.pup) end
    if NETP.boss == s then NETP.boss = nil end
    if tagDrop then tagDrop(s) end
    if s.followReady then G.rootMotionScale(s.pup, 1.0) end
    hideOne(s.pup)
    NETP.side[s.idx] = nil
    local keep = {}
    for _, v in ipairs(NETP.list) do if v ~= s then keep[#keep + 1] = v end end
    NETP.list = keep
    out("多人：%s 的替身收起（%s）", s.tag, why)
end

function MP.netStop(why)
    if not NETP.on then return end
    NETP.on = false
    NETP.noMpAt = nil
    lastHostPid = nil
    for _, s in ipairs(NETP.list) do
        if s.barReg then G.bossBarHide(s.pup) end
        if tagDrop then tagDrop(s) end
        if s.followReady then G.rootMotionScale(s.pup, 1.0) end
        hideOne(s.pup)
    end
    NETP.boss = nil
    NETP.side, NETP.list = {}, {}
    if inMatch and inMatch() and enter then enter("idle", now(), "多人断开: " .. tostring(why or "")) end
    if MP.rule and MP.rule.st ~= "idle" then MP.rule.st, MP.rule.parts, MP.rule.my, MP.rule.deaths = "idle", {}, 0, 0 end
    if MP.rule then MP.rule.protTill, MP.rule.leashTill = nil, nil end
    if MP.rule then
        MP.rule.mtd, MP.rule.aiState, MP.rule.aiAutoSynced = {}, {}, nil
    end
    if restoreSpeed then restoreSpeed() end
    if clearAllBuffFx then clearAllBuffFx() end
    if MP.specStopX then MP.specStopX() end
    local p1 = getP1()
    if NETP.locked and valid(p1) then G.unlockSelf(p1, "多人联机结束") end
    NETP.locked = nil
    pcall(MP.cfgLoad)
    if ctx.restoreLocalRules then ctx.restoreLocalRules() end
    out("多人联机结束（%s）", why or "")
end

-- ---- 每帧 / 每次逻辑的几块，分开计时（[耗时] 里的"·多人*"，§82 PROF）。11-10 18:08 第一次实测：2 个替身时
-- 多人模块 84–113 ms/秒、收包 41–59 ms/秒、饰品去重 35–58 ms/秒，帧率 97 → 45–60
local function wrap(name, fn) return ctx.prof and ctx.prof(name, fn) or fn end

-- §251.2 多人替身自己的跟随预处理 / 一步计算。原来借观战的 SP.followPrep / SP.followStep，0.34 §223.2 把观战改走对战的
-- NET.drive + NPM 后那两个函数删了（integ/0.35 冒烟：pbz_multi.lua:589 每帧 followStep 为 nil）。这里照 9f87d2c 删掉前的原文搬成本地，
-- 多人替身的位置跟随和 mesh 分支上测过的一致；以后多人替身也并进 NET.drive 时整段删掉
local FOLLOW_K, FOLLOW_SNAP, FOLLOW_AHEAD = 14.0, 600.0, 0.25
local FOLLOW_VMAX, FOLLOW_XMAX = 10000.0, 400.0
local function followPrep(s)
    if s.followReady then return end
    s.followReady = true
    local ok, how = G.rootMotionScale(s.pup, 0.0)
    local cm = rawProp(s.pup, "CharacterMovement")
    if valid(cm) then
        pcall(function() cm.MaxWalkSpeed = math.max(tonumber(rawProp(cm, "MaxWalkSpeed")) or 0, 1400.0) end)
        pcall(function() cm.MaxAcceleration = math.max(tonumber(rawProp(cm, "MaxAcceleration")) or 0, 6000.0) end)
    end
    out("多人 %s：严格跟随位置（根运动关 %s：%s）", tostring(s.name or s.tag or "?"), ok and "成功" or "失败", tostring(how))
end
local function followStep(cur, aim, tn, dt)
    local age = math.max(tn - aim.at, 0)
    local a = math.min(age, FOLLOW_AHEAD)
    local vx, vy = aim.vx or 0, aim.vy or 0
    local v = math.sqrt(vx * vx + vy * vy)
    if v > FOLLOW_VMAX then vx, vy = vx / v * FOLLOW_VMAX, vy / v * FOLLOW_VMAX end
    local ex, ey = vx * a, vy * a
    local e = math.sqrt(ex * ex + ey * ey)
    if e > FOLLOW_XMAX then ex, ey = ex / e * FOLLOW_XMAX, ey / e * FOLLOW_XMAX end
    local ax, ay = aim.X + ex, aim.Y + ey
    local cx, cy = cur.X, cur.Y
    dt = math.min(math.max(dt, 0), 0.1)
    if age < FOLLOW_AHEAD then cx, cy = cx + vx * dt, cy + vy * dt end
    local dx, dy = ax - cx, ay - cy
    local err = math.sqrt((ax - cur.X) ^ 2 + (ay - cur.Y) ^ 2)
    if err > FOLLOW_SNAP then return ax, ay, true, err end
    local k = math.min(1.0, FOLLOW_K * math.max(dt, 0))
    return cx + dx * k, cy + dy * k, false, err
end
MP._followStep = followStep     -- 测试用

-- ---- §287 PEER：收包排队（招不算的时候挡掉招式号）、挑"你"、驱动、每帧
-- 招不算（对局里倒计时 / 倒地 / 没参加）：以前只记编号不放。现在包照样交给 PEER（位置 / 血量 / 换装照跟），
-- 只把 ev= 里的招去掉，并记下最大的号（evFloor）；之后的包只放比它大的 —— 不然一开打就把攒着的老招一次全放出来
-- （recvOne 断 5 秒以上按新连接、招式号从 0 重认，所以不能只靠它自己的 lastEvIn）。对方重启（序号倒退）清掉 evFloor
local function evMaxOf(ev)
    local mx
    for id in (ev or ""):gmatch("(%d+):") do id = tonumber(id); if not mx or id > mx then mx = id end end
    return mx
end
function MP.peerQueue(s, t, tn, counts)
    local seq = tonumber(t.seq)
    if seq and s.seqSeen and seq < s.seqSeen and (seq < s.seqSeen - 100 or tn - (s.lastAt or tn) > 5.0) then s.evFloor = nil end
    if seq then s.seqSeen = seq end
    local p = t
    if not counts then
        local mx = evMaxOf(t.ev)
        if mx and mx > (s.evFloor or -1) then s.evFloor = mx end
        if t.ev and t.ev ~= "" then
            p = {}
            for k, v in pairs(t) do p[k] = v end
            p.ev = ""
        end
    elseif s.evFloor and t.ev and t.ev ~= "" then
        local keep = {}
        for id, name in t.ev:gmatch("(%d+):([%w_]+)") do
            if tonumber(id) > s.evFloor then keep[#keep + 1] = id .. ":" .. name end
        end
        local ev = table.concat(keep, ",")
        if ev ~= t.ev then
            p = {}
            for k, v in pairs(t) do p[k] = v end
            p.ev = ev
        end
    end
    s.inbox = s.inbox or {}
    s.inbox[#s.inbox + 1] = p
    if #s.inbox > 90 then table.remove(s.inbox, 1) end      -- 保险：逻辑停了（切图）时别一直攒
end

-- PEER 里的"你"（锁定目标、出招时对准、召唤物 / 火枪 / 独眼弓瞄准）= 这个人现在在打谁。包里只有 lk=1（锁着某人），没说锁的是谁：
-- 按他包里的朝向，在我和别的替身（都按包里 / 实际位置）里挑夹角最小的（TGT_RANGE 内、夹角 TGT_ANGLE 内）；都不像就挑最近的；
-- 一个都没有 = 我。两队时不挑他的队友。cands = { { X =, Y = }, ... }，返回下标或 nil
function MP.pickTgt(from, yaw, cands)
    local best, bestA, near, nearD = nil, math.huge, nil, math.huge
    for i, c in ipairs(cands or {}) do
        local dx, dy = c.X - from.X, c.Y - from.Y
        local d = math.sqrt(dx * dx + dy * dy)
        if d <= MP.TGT_RANGE then
            local a = d > 1.0 and math.abs((math.deg(math.atan(dy, dx)) - yaw + 180.0) % 360.0 - 180.0) or 0.0
            if a < bestA then best, bestA = i, a end
            if d < nearD then near, nearD = i, d end
        end
    end
    if best and bestA <= MP.TGT_ANGLE then return best end
    return near
end

local function teamOfPid(pid)
    if not (RULE and MP.teamsOn(RULE.teams) and RULE.teamOf and inMatch and inMatch()) then return 0 end
    return RULE.teamOf[pid] or 0
end

local function peerTarget(s, tn)
    local p1 = getP1()
    if s.tgtAt and tn - s.tgtAt < 0.25 and valid(s.tgtPup) then return s.tgtPup end
    s.tgtAt = tn
    local chosen, tag = p1, "你"
    local yaw = s.last and tonumber(s.last.yaw)
    -- §335 AI 自己报它在打谁（atg=<编号>，0 = 没目标）：照着它对准。以前靠猜、猜的时候又不算别的 AI，
    -- 结果队友 AI 没候选就默认对着你砍（用户 11-15："刚开局的时候我的队友就是面向我砍的"），打别的 AI 时也是对着你 / 空气出招
    local atg = MP.isAiPid(s.idx) and s.last and tonumber(s.last.atg) or nil
    if atg then
        if atg > 0 and atg == myPid() then
            chosen, tag = p1, "你"
        elseif atg > 0 and NETP.side[atg] and valid(NETP.side[atg].pup) then
            chosen, tag = NETP.side[atg].pup, NETP.side[atg].tag or (atg .. "号")
        else
            return s.tgtPup        -- 没目标 / 目标不在：不换（尤其别默认对着你）
        end
    elseif s.aim and yaw then
        local cands, who = {}, {}
        local sTm = teamOfPid(s.idx)
        -- §326 复测 4：AI 不打 AI（AI 自己选目标只挑真人），猜 AI 在打谁时也不把别的 AI 算进候选
        -- §326.2：游戏里 13:59 复测 AI4 在场时还在出"2号：在打 4号"——只看 MP.aiSet()（会话里的 mpai=）不够，
        -- 改用 MP.isAiPid（会话 mpai= / 替身昵称 [AI] / 成员名单都认，编号先 tonumber）
        local sIsAi = MP.isAiPid(s.idx)
        local function add(pup, at, pid, name)
            if not (valid(pup) and at) then return end
            if sTm ~= 0 and teamOfPid(pid) == sTm then return end
            if sIsAi and pid and MP.isAiPid(pid) then return end
            cands[#cands + 1] = { X = at.X, Y = at.Y }
            who[#who + 1] = { pup = pup, tag = name }
        end
        add(p1, valid(p1) and loc(p1), myPid and myPid(), "你")
        for _, o in ipairs(NETP.list) do
            if o ~= s and not o.idle and not o.fallen then add(o.pup, o.aim, o.idx, o.tag) end
        end
        local i = MP.pickTgt(s.aim, yaw, cands)
        if i then chosen, tag = who[i].pup, who[i].tag end
    end
    local same = valid(chosen) and valid(s.tgtPup) and (G.sameObj and G.sameObj(chosen, s.tgtPup) or chosen == s.tgtPup)
    if not same then
        s.tgtPup = chosen
        -- NET.drive 的锁定只在 替身 × lk 变了时重设：换人了让它下一次重锁
        if s.peer and s.peer.st then s.peer.st.lockSetKey = nil end
        s.tgtN = (s.tgtN or 0) + 1
        if s.tgtTag ~= tag and s.tgtN <= 30 then out("多人 %s：在打 %s", s.tag, tag) end
        s.tgtTag = tag
    end
    return s.tgtPup
end
MP._peerTarget = peerTarget     -- 测试用

function MP.noteContact(pupOrPid, tn)
    tn = tn or now()
    local pid
    if type(pupOrPid) == "number" then
        pid = pupOrPid
    elseif pupOrPid then
        for _, s in ipairs(NETP.list or {}) do
            if s.pup == pupOrPid or (G.sameObj and G.sameObj(s.pup, pupOrPid)) then
                pid = s.idx
                break
            end
        end
        if not pid and NETP.side then
            for id, s in pairs(NETP.side) do
                if s.pup == pupOrPid or (G.sameObj and G.sameObj(s.pup, pupOrPid)) then
                    pid = id
                    break
                end
            end
        end
    end
    -- §299 只在我自己参战的多人对局交手中记（对决只有两位选手，不用归属；出局 / 观战时替身互打不算我）
    if DUEL and DUEL.isDuel() then return end
    if RULE.st ~= "fight" or not part(myPid()) then return end
    if pid and pid ~= myPid() then
        RULE.touched = RULE.touched or {}
        RULE.touched[pid] = tn
        local side = NETP.side[pid]
        if side and MP.isAiPid(pid) then side.aiContactAt = tn end
    end
end

local function myRfp()
    if MP._myRfp then return MP._myRfp() end
    if ctx.myRfp then return ctx.myRfp() end
    return nil
end
MP.myRfp = myRfp

-- §299 对局主机核对每位玩家的规则指纹。rfp= 是"局号:指纹"，不在对局里发 "-"，所以只在对局中、同一局号时比：
--   nil = 还不能比（没开局 / 局号还没对上 / 我不是对局主机）；"none" = 收到过这人的包但从来不带 rfp=（旧版本）
function MP.rfpStatus(pid)
    if not isHost() or pid == myPid() then return nil end
    if MP.isAiPid(pid) then return nil end     -- §326 复测 5：AI 没有规则指纹，跳过检查（不标、不当规则不一致）
    local info = RULE.peerRfp and RULE.peerRfp[pid]
    if not info then
        return (RULE.peerSeen and RULE.peerSeen[pid]) and "none" or nil
    end
    if not info.mid or not info.fp then return nil end
    local mw = myRfp()
    local mmid, mfp = (mw or ""):match("^(%d+):(%x+)$")
    if not mmid or tonumber(mmid) ~= info.mid then return nil end
    return info.fp ~= mfp and "diff" or "match"
end

-- 判定是否是远程 / 召唤物技能（允许在 6m 外且稍长窗口内命中 AI）
MP.AI_ATK_WIN = 0.6
MP.AI_RANGED_WIN = 1.2
MP.AI_MELEE_DIST = 600.0
local function isRangedOrSummon(name)
    if type(name) ~= "string" or name == "" then return false end
    for _, p in ipairs({ "Bow", "Gong", "Arrow", "Gun", "HuoQiang", "Dart", "FeiBiao", "ZiMingJian", "HuoLiuXing",
                         "Summon", "ZhaoJiLing", "SiXian", "SiZhuChuan", "HuaShan", "Remote", "Bullet", "Projectile", "Throw" }) do
        if name:find(p, 1, true) then return true end
    end
    return false
end

-- 本地 AI 受击归因（两队/三队队友替身也能本地打伤敌方 AI；收紧时间+距离+排除近处正在出招的友方替身）
local function shouldAttributeAiDrop(s, tn)
    if RULE.my ~= 0 then return false, nil end      -- §336 我倒地 / 出局时打出的不算我的
    local atkId, atkAt, atkName = nil, nil, nil
    if ctx.myAtkInfo then atkId, atkAt, atkName = ctx.myAtkInfo() end
    if (not atkName or atkName == "") and atkId and atkId > 0 and ctx.atkNameOf then
        atkName = ctx.atkNameOf(atkId)
    end
    local ranged = isRangedOrSummon(atkName)
    local p1 = getP1 and getP1() or nil
    local sLoc = valid(s.pup) and loc(s.pup) or nil
    local p1Loc = (valid(p1) and sLoc) and loc(p1) or nil
    local myDist = (p1Loc and sLoc) and d2(p1Loc, sLoc) or nil
    if myDist and not ranged and myDist > MP.AI_MELEE_DIST then
        return false, nil
    end
    local win = ranged and MP.AI_RANGED_WIN or MP.AI_ATK_WIN
    local recentAtk = atkId and atkAt and (tn - atkAt <= win)
    local recentContact = s.aiContactAt and (tn - s.aiContactAt <= MP.AI_ATK_WIN) and atkId and atkAt and (tn - atkAt <= 1.2)
    if not recentAtk and not recentContact then
        return false, nil
    end
    if MP.teamsOn(RULE.teams) then
        for _, o in ipairs(NETP.list or {}) do
            if o ~= s and not o.idle and not o.fallen and valid(o.pup) and factionFor and factionFor(o) == FRIEND then
                local om = G.montageOf and (G.montageOf(o.pup) or "") or ""
                local oAtking = (o.atkAt and tn - o.atkAt <= 0.8) or (om ~= "" and MP.isAtkMontage(om))
                if oAtking then
                    local oLoc = loc(o.pup)
                    if not oLoc or not sLoc or d2(oLoc, sLoc) <= MP.AI_MELEE_DIST then
                        return false, nil
                    end
                end
            end
        end
    end
    return true, tonumber(atkId) or 0
end

-- §335 AI 打 AI：只有房主报（AI 在房主那边跑，每台都报会重复扣）。AI 替身本机掉血、又不是我打的 →
-- 找附近刚出过招、和挨打的不同队的 AI 替身（近战 6 米 × 1.5、1.2 秒内），最近的那个算出手的
MP.AI_VS_AI_DIST = MP.AI_MELEE_DIST * 1.5
local function aiAttackerOf(s, tn)
    if not (isHost() and MP.isAiPid(s.idx)) then return nil end
    local sLoc = valid(s.pup) and loc(s.pup) or nil
    if not sLoc then return nil end
    local teams = MP.teamsOn(RULE.teams) and RULE.teamOf
    local best, bestD
    for _, o in ipairs(NETP.list or {}) do
        if o ~= s and MP.isAiPid(o.idx) and part(o.idx) and not o.idle and not o.fallen and valid(o.pup)
           and o.atkAt and tn - o.atkAt <= MP.AI_RANGED_WIN
           and not (teams and (teams[o.idx] or 0) == (teams[s.idx] or -1)) then
            local oLoc = loc(o.pup)
            local d = oLoc and d2(oLoc, sLoc) or nil
            if d and d <= MP.AI_VS_AI_DIST and (not bestD or d < bestD) then best, bestD = o, d end
        end
    end
    return best
end
MP._aiAttackerOf = aiAttackerOf

local function noteAiVsAi(atk, vic, drop, tn)
    RULE.mta = RULE.mta or {}
    local pk = atk .. ":" .. vic
    RULE.mtaSeg = RULE.mtaSeg or {}
    local sg = RULE.mtaSeg[pk]
    if not sg or tn - (sg.at or 0) > 0.5 then      -- 停了 0.5 秒算新的一段（联机程序按 出手:段 记累计，别和上一段的累计混）
        sg = { n = ((sg and sg.n) or 0) + 1, at = tn }
        RULE.mtaSeg[pk] = sg
    end
    sg.at = tn
    local key = pk .. ":" .. sg.n
    local e = RULE.mta[key]
    if not e then e = { atk = atk, vic = vic, seg = sg.n, dmg = 0.0, at = tn }; RULE.mta[key] = e end
    e.dmg = e.dmg + drop
    e.at = tn
end
MP._noteAiVsAi = noteAiVsAi

-- 逻辑（30 次 / 秒）：攒下的包 + 驱动，一次 PEER 交换做完（同观战 SP logic）。倒地的不驱动（倒地动作别被跟随 / 受击盖掉），包扔掉
local peerStep = wrap("·多人替身驱动", function(s, tn)
    local PM = peerMod()
    if not (PM and s.peer) then return end
    if s.fallen then s.inbox = nil; s.aiTrackedHp = nil; return end
    if s.idle and not (s.inbox and #s.inbox > 0) then s.aiTrackedHp = nil; return end
    local isAi = MP.isAiPid(s.idx)
    -- §335 房主就算只看不上场也要盯着 AI 掉血（AI 打 AI 只有房主报）
    if isAi and RULE.st == "fight" and (part(myPid()) or isHost()) and not s.idle and valid(s.pup) then
        local curHp = G.hpOf and G.hpOf(s.pup) or nil
        if curHp and s.aiTrackedHp and curHp < s.aiTrackedHp - 0.5 then
            local drop = s.aiTrackedHp - curHp
            local okAttr, atkId = false, nil
            if part(myPid()) then okAttr, atkId = shouldAttributeAiDrop(s, tn) end
            if okAttr then
                local moveId = (atkId and atkId > 0) and atkId or 0
                if moveId == 0 then
                    if not s.aiFbAt or tn - s.aiFbAt > 0.5 then
                        s.aiFbId = (s.aiFbId or 0) + 1
                    end
                    s.aiFbAt = tn
                    moveId = s.aiFbId
                end
                RULE.mtd = RULE.mtd or {}
                local key = s.idx .. ":" .. moveId
                local entry = RULE.mtd[key]
                local prevDmg = entry and entry.dmg or 0.0
                local scaled = drop
                if moveId > 0 and ctx.calcTouch then
                    scaled = ctx.calcTouch(moveId, drop, tn, prevDmg, key)
                end
                if scaled and scaled > 0 then
                    if not entry then
                        entry = { pid = s.idx, mid = moveId, dmg = 0.0, at = tn }
                        RULE.mtd[key] = entry
                    end
                    entry.dmg = entry.dmg + scaled
                    entry.at = tn
                end
            else
                -- §335 不是我打的：房主看是不是别的 AI 打的（替身打替身的伤害已经按对方出招时的倍率算过，不再折算）
                local atk = aiAttackerOf(s, tn)
                if atk then noteAiVsAi(atk.idx, s.idx, drop, tn) end
            end
        end
    end
    local tgt = peerTarget(s, tn)
    local inbox = s.inbox
    s.inbox = nil
    PM.step(s.peer, valid(tgt) and tgt or getP1(), tn, inbox)
    if isAi and valid(s.pup) then
        -- §301 多人本地 AI 战斗期间维持本机当前 Health 为满血（Health_Max 不变），避免 AI 残血时一刀伤害被本机剩余血量截断
        if RULE.st == "fight" and not s.idle and not s.fallen and (s.duelHp == nil or s.duelHp > 0) then
            local hm = (G.attrOf and G.attrOf(s.pup, "Health_Max")) or s.duelHpm
            local chp = G.hpOf and G.hpOf(s.pup) or nil
            if hm and hm > 0 and G.setAttr and (not chp or math.abs(chp - hm) > 0.5) then
                G.setAttr(s.pup, "Health", hm)
            end
        end
        s.aiTrackedHp = G.hpOf and G.hpOf(s.pup) or nil
    else
        s.aiTrackedHp = nil
    end
    local n = (s.peer.fired or 0) + (s.peer.failed or 0)
    if n > (s.peerN or 0) then s.atkAt = tn end      -- 死亡归属（ruleTick 谁打的）看它
    s.peerN = n
end)
MP._peerStep = peerStep

-- 每帧：喂摇杆、掐本机反应、锁定点、NPM 严格跟随（同观战 SP frame）
local peerFrame = wrap("·多人替身每帧", function(s)
    local PM = peerMod()
    if PM and s.peer then PM.frame(s.peer, valid(s.tgtPup) and s.tgtPup or getP1()) end
end)

-- 严格跟随（同观战 SP.followFrame）：每帧往"包里位置 + 速度 × 包龄"拉；锁定点跟着放到同一处（不再单独读一次位置）
local followOne = wrap("·多人跟随", function(s, L, tn)
    local aim = s.aim
    if not (aim and tn - aim.at < 1.0) then return end
    local cur = loc(s.pup)
    if not cur then return end
    local dt = s.followAt and (tn - s.followAt) or 0.016
    s.followAt = tn
    local x, y, snap, err = followStep(cur, aim, tn, dt)
    local z = cur.Z
    if not aim.air and aim.Z and math.abs(aim.Z - cur.Z) > 300.0 then z, snap = aim.Z + 20.0, true end
    pcall(function() s.pup:K2_SetActorLocation({ X = x, Y = y, Z = z }, false, {}, snap) end)
    s.errMax = math.max(s.errMax or 0, err)
    if snap then s.snaps = (s.snaps or 0) + 1 end
    -- 锁定点（main.lua §19 那套，只认对战替身）：每 2 帧放一次就够
    s.lockTick = (s.lockTick or 0) + 1
    if s.lockTick % 2 == 0 and valid(s.lockComp) then
        pcall(function() s.lockComp:K2_SetWorldLocation({ X = x, Y = y, Z = z + LOCK_Z }, false, {}, true) end)
    end
end)

-- 走路动画 / 转身：以前每个包都做（2 人 ×25 包/秒），改成逻辑 10 次 / 秒。
-- 写速度只为了让动画蓝图播跑步（位置由 followOne 拉），用生成时记下的移动组件
local walkTurn = wrap("·多人走路转身", function(s, tn)
    local aim = s.aim
    if not aim or tn - aim.at > 1.0 then s.feed = nil; return end
    local cur = loc(s.pup)
    if not cur then return end
    local vx, vy = aim.vx, aim.vy
    local sp = math.sqrt(vx * vx + vy * vy)
    if valid(s.cm) then
        local vz = 0.0
        pcall(function() vz = s.cm.Velocity.Z end)
        pcall(function() s.cm.Velocity = { X = vx, Y = vy, Z = vz } end)
    end
    s.feed = sp > 20.0 and { dir = { X = vx / sp, Y = vy / sp, Z = 0.0 }, scale = math.min(1.0, sp / 600.0), left = 6 } or nil
    if G.montageOf(s.pup) == "" and s.last then turn(s, tonumber(s.last.yaw) or 0) end
end)

local dressOne = wrap("·多人换装", function(s, L) pcall(L.dress, s) end)
-- M3 血条（用户 11-11 定）：Boss 血条只给"我锁定的那个人"，换锁定就换；其他人用头顶 UMG 小血条
-- （借 obs 观战头顶名字 §167.8 那套投影，pbz_game.lua 的 nameTagNew(withBar=true)）。
-- 人数不再被 3 条 Boss 血条卡住；头顶血条只在数值变了时写，投影 4 次 / 秒。
MP.BAR_MAX = 3
MP.TAG_UP = 120.0
function MP.barPlan(sides, lockPup)
    local boss, overhead = nil, {}
    for _, s in ipairs(sides or {}) do
        if lockPup and valid(s.pup) and G.sameObj(s.pup, lockPup) and not s.idle then
            boss = s
        else
            overhead[#overhead + 1] = s
        end
    end
    return boss, overhead
end
function MP.barKey(s)
    return string.format("%s|%s|%s|%s|%s|%s|%s", tostring(s.name), tostring(s.hp), tostring(s.hpm),
        tostring(s.sh), tostring(s.shm), tostring(s.pst), tostring(s.barMode))
end
local function lockTargetNow()
    local p1 = getP1()
    if not valid(p1) then return nil end
    local t = G.lockTargetActor and G.lockTargetActor(p1) or G.lockingTarget(p1)     -- 11-15 瞄准组件时要取出被锁的角色（以前拿到组件本身，Boss 血条永远不切）
    return valid(t) and t or nil
end
tagDrop = function(s)
    if s.nameTag then G.nameTagRemove(s.nameTag); s.nameTag, s.ohKey = nil, nil end
end
local function overheadStep(s, tn, pc)
    if not valid(pc) then return end
    if not s.nameTag then
        if tn < (s.tagTryAt or 0) then return end
        s.tagTryAt = tn + 5.0
        s.nameTag = G.nameTagNew(pc, true)
        if s.nameTag then out("多人 %s：头顶血条界面已建好", s.tag) end
    end
    if not s.nameTag then return end
    local key = MP.barKey(s)
    if key ~= s.ohKey then
        s.ohKey = key
        G.nameTagSet(s.nameTag, (s.name ~= "" and s.name) or s.tag)
        if G.nameTagBar then G.nameTagBar(s.nameTag, (s.hp and s.hpm and s.hpm > 0) and (s.hp / s.hpm) or nil) end
    end
    -- 11-15 队友（分队开着、同一队，MP.isAlly）绿条，其他红条；nameTagBarColor 自己只在变了时写
    if G.nameTagBarColor then G.nameTagBarColor(s.nameTag, MP.isAlly(s)) end
    s.tagPc = pc      -- 摆位置在 MP.placeTags 里每帧做
end
-- §310（11-14 实测：头顶血条 4 次 / 秒投影，跟着人一卡一卡）：每帧把有血条的投到头顶（血量 / 名字仍只在变了时写）
function MP.placeTags()
    local hide = UIM and UIM.hideMod()
    for _, e in pairs(RULE.myBuffFx or {}) do     -- 11-15 地上道具的文字标签
        if e.tag and e.pc then G.nameTagPlace(e.tag, e.pc, (not hide) and { X = e.x, Y = e.y, Z = (e.z or 0) + MP.BUFF_TAG_UP } or nil) end
    end
    for _, s in ipairs(NETP.list) do
        if s.nameTag and s.tagPc and not s.idle then
            local l = valid(s.pup) and loc(s.pup)
            G.nameTagPlace(s.nameTag, s.tagPc, (l and not (UIM and UIM.hideMod())) and { X = l.X, Y = l.Y, Z = l.Z + MP.TAG_UP } or nil)     -- §314 界面三态 1 / 2 档藏头顶名字 / 血条
        end
    end
end

-- §295 房间设置"对手血条"（2 血量+杀气 / 1 只显示血 / 0 不显示）只管对手：队友（两队模式同阵营）照常显示
function MP.barModeFor(s, mode)
    if mode == nil or mode >= 2 then return 2 end
    if MP.isAlly and MP.isAlly(s) then return 2 end     -- 11-15 按队伍判断（保护期间的临时阵营不算）
    return mode
end
local barsStep = wrap("·多人血条", function(tn)
    local p1 = getP1()
    local pc = getP1PC and getP1PC() or nil
    local lock = lockTargetNow()
    local mode = ctx.barMode and ctx.barMode() or 2
    -- 观战的人（多人里出局在看 / 对决里没上场）看全的；只有正在打的人按"对手血条"设置
    if MP.specView and MP.specView.on then mode = 2 end      -- SPEC 在文件后面才声明，这里用 MP.specView
    local duelBoss = nil
    if DUEL ~= nil and DUEL.isDuel() then
        local me = myPid()
        mode = 2
        -- §307 D9：对决里选手的 Boss 血条一直是对手（不看锁定），同旧版 OPPBAR；观众照旧
        if (me == DUEL.fa or me == DUEL.fb) and (DUEL.state == "cd" or DUEL.state == "fight" or DUEL.state == "rend") then
            local opp = (me == DUEL.fa) and DUEL.fb or DUEL.fa
            local so = NETP.side[opp]
            if so and valid(so.pup) and not so.idle then duelBoss = so end
        end
    end
    local shown = {}
    for _, s in ipairs(NETP.list) do
        s.barMode = MP.barModeFor(s, mode)
        if s.barMode > 0 then shown[#shown + 1] = s end
    end
    if #shown < #NETP.list and not NETP.barHideLogged then
        NETP.barHideLogged = true
        out("多人：房间设置不显示对手血条（%d 个替身不画血条）", #NETP.list - #shown)
    elseif #shown == #NETP.list then NETP.barHideLogged = nil end
    local boss, overhead = MP.barPlan(shown, lock)
    if duelBoss then          -- 对决选手：对手的 Boss 血条一直显示，别让他再叠一个头顶条
        boss, overhead = duelBoss, {}
        for _, s in ipairs(shown) do if s ~= boss then overhead[#overhead + 1] = s end end
    end
    if NETP.boss ~= boss then
        if NETP.boss and NETP.boss.barReg then
            G.bossBarHide(NETP.boss.pup)
            NETP.boss.barReg, NETP.boss.bar, NETP.boss.barMiss = false, nil, 0
        end
        NETP.boss = boss
        if boss then out("多人：Boss 血条换成 %s（锁定）", boss.tag) end
    end
    local claimed = {}
    for _, s in ipairs(overhead) do
        if valid(s.bar) then claimed[#claimed + 1] = s.bar end
    end
    for _, s in ipairs(NETP.list) do
        if s ~= boss and s.barReg then
            G.bossBarHide(s.pup)
            s.barReg, s.bar, s.barMiss, s.barWant = false, nil, 0, false
        end
        if s.idle or not valid(s.pup) or s.barMode == 0 then      -- §295 不显示对手血条：头顶条也收
            tagDrop(s)
        end
    end
    if boss then
        boss.barWant = true
        local key = MP.barKey(boss)
        if not valid(boss.bar) or key ~= boss.barKey then
            if bossBarStep(boss, tn, claimed) and valid(boss.bar) then boss.barKey = key end
        elseif tn - (boss.nameAt or 0) > 1.0 then
            bossBarStep(boss, tn, claimed)
        end
        tagDrop(boss)       -- 锁定的人只留 Boss 血条，别再叠一个头顶条
    end
    for _, s in ipairs(overhead) do
        if not s.idle and valid(s.pup) then
            s.barWant = false
            overheadStep(s, tn, pc)
        end
    end
end)

-- 饰品去重（main.lua ACC.dedupe，§170.4：替身生成会让你的饰品效果多一份）只在多人替身刚生成后的 ACC_WIN 秒里做；
-- 以前多人开着就一直按"有替身"每秒全扫（挨打时效果数一直变），35–58 ms/秒
MP.ACC_WIN = 15.0
function MP.accSkip(tn)
    return NETP.on and not MP.on and tn - (NETP.spawnAt or -100) > MP.ACC_WIN
end

local function netFrame()
    local L = live()
    local tn = now()
    for _, s in ipairs(NETP.list) do
        if valid(s.pup) and not s.idle then
            if s.peer then
                if not s.fallen then peerFrame(s) end               -- §287 ②d 倒下的停在原地
            else
                local f = s.feed
                if f and f.left > 0 then
                    f.left = f.left - 1
                    pcall(function() s.pup:AddMovementInput(f.dir, f.scale, true) end)
                end
                if L and not s.fallen then followOne(s, L, tn) end     -- ②d 倒下的停在原地
            end
        end
    end
    if MP.specFrameP and MP.specView and MP.specView.on then MP.specFrameP() end     -- ②d 出局后的观战镜头
    local c = os.clock()
    if c - NETP.lastLogic < MP.TICK then return end
    NETP.lastLogic = c
    NETP.walkN = (NETP.walkN or 0) + 1
    if NETP.walkN % 3 == 0 then
        for _, s in ipairs(NETP.list) do if valid(s.pup) and not s.idle and not s.fallen and not s.peer then walkTurn(s, tn) end end
    end
    if MP.ruleTickP then MP.ruleTickP(tn) end
    local sess = ctx.session and ctx.session() or {}
    if sess.mp ~= "1" then
        NETP.noMpAt = NETP.noMpAt or tn
        if tn - NETP.noMpAt > 3.0 then MP.netStop("不在多人会话里了"); return end
    else
        NETP.noMpAt = nil
    end
    local p1 = getP1()
    for _, s in ipairs(NETP.list) do
        if not valid(s.pup) then netDrop(s, "替身没了")
        elseif tn - (s.lastAt or 0) > NETP.DROP then netDrop(s, string.format("%.0f 秒没包", NETP.DROP))
        else
            if tn - (s.lastAt or 0) > NETP.IDLE then netIdle(s, true) end
            if s.peer then
                -- §287 换装 / 攻击属性 / 血量（按包写、GE_LockHealth 兜底）都在 NET.drive / recvOne 里
                peerStep(s, tn)
            else
                -- 换装：包里的武器变了马上换，没变每 2 秒核对一次（以前每 0.25 秒）
                local wk = tostring(s.wantWc) .. "|" .. tostring(s.wantWcs)
                if L and (wk ~= s.dressKey or tn - (s.dressAt or 0) > 2.0) then s.dressAt, s.dressKey = tn, wk; dressOne(s, L) end
                if tn - (s.hpAt or 0) > 1.0 then
                    s.hpAt = tn
                    local hp, mx = G.attrOf(s.pup, "Health"), G.attrOf(s.pup, "Health_Max")
                    if hp and mx and hp < mx * 0.4 then G.setAttr(s.pup, "Health", mx) end
                end
            end
        end
    end
    -- 自己：一直挂锁血（不会真死、不回篝火）；对决模式观众不锁血；没在对局里时低于 40% 补满，对局里不补（倒没倒看 ②d 规则）
    local wantSelfLock = not (DUEL and DUEL.isDuel()) or DUEL.shouldLockSelf()
    if valid(p1) and not wantSelfLock and NETP.locked then
        G.unlockSelf(p1, "对决观众/闲置不锁血")
        NETP.locked = nil
    end
    if valid(p1) and wantSelfLock and tn - (NETP.refillAt or 0) > 0.5 then
        NETP.refillAt = tn
        if not NETP.locked then NETP.locked = G.lockSelf(p1) end
        local hp, mx = G.hpOf(p1), G.attrOf(p1, "Health_Max")
        if hp and mx and hp < mx * 0.4 and (not (DUEL and DUEL.isDuel()) and MP.rule and MP.rule.st == "idle" or (DUEL and DUEL.isDuel() and not DUEL.inMatch())) then G.refill(p1) end
    end
    if tn - (NETP.barAt or 0) > 0.25 then
        NETP.barAt = tn
        barsStep(tn)
    end
    MP.placeTags()
    if tn - (NETP.statAt or tn) > NETP.STAT_SEC then
        local parts = {}
        for _, s in ipairs(NETP.list) do
            local fired, failed, extra = s.fired or 0, s.failed or 0, ""
            if s.peer then      -- §287 招数在这个替身那份 PEER 里（PEER.note）；收招 = recvOne 认下的新招式号，偏差 = 离包里位置
                local P, PM = s.peer, peerMod()
                local evIn = PM and PM.get(P, "NET", "evIn") or 0
                local np = PM and PM.get(P, "NET", "pos")
                local l = np and valid(s.pup) and loc(s.pup)
                fired, failed = (P.fired or 0) - (s.pf0 or 0), (P.failed or 0) - (s.pl0 or 0)
                extra = string.format(" 收招 %d 偏差 %.0f", evIn - (s.pe0 or 0), (np and l) and d2(np, l) or 0)
                s.pf0, s.pl0, s.pe0 = P.fired or 0, P.failed or 0, evIn
            end
            parts[#parts + 1] = string.format("%s %s 包 %d 招 %d 失败 %d 动作 %d 血 %s/%s 偏差最大 %.0f 直接摆 %d%s%s", s.tag, s.nick or "?",
                s.n or 0, fired, failed, s.acts or 0, tostring(s.hp), tostring(s.hpm), s.errMax or 0, s.snaps or 0, extra, s.idle and " 藏着" or "")
            s.n, s.fired, s.failed, s.acts, s.errMax, s.snaps = 0, 0, 0, 0, 0, 0
        end
        out("多人联机 | 我是 %s 号，房间 %s 人 | %s", tostring(sess.mpid), tostring(sess.mpn), #parts > 0 and table.concat(parts, "；") or "还没有别人的包")
        NETP.statAt = tn
    end
    NETP.statAt = NETP.statAt or tn
end
MP.netFrameP = ctx.prof and ctx.prof("多人联机", netFrame) or netFrame

local function netEnsureLoop()
    if NETP.on then return end
    NETP.on = true
    -- §309（11-14 实测）：上一个房间留下的"不在多人会话里"计时没清，刚加入时（包先到、session 还没写 mp=1）
    -- netFrame 一看已经过了 3 秒就立刻 netStop → 下一个包又生成替身 → 又停，加入后第一秒来回 12 次
    NETP.noMpAt = nil
    NETP.gen = NETP.gen + 1
    local gen = NETP.gen
    out("多人联机开始：收到别的玩家的包，开始驱动替身")
    if ctx.notice then ctx.notice("多人联机", "收到别的玩家了；房主按 F1 直接开局，房里的人都参加，不用准备", 4.0) end     -- §316 写明不用每人同意
    if type(LoopInGameThreadAfterFrames) == "function" then
        LoopInGameThreadAfterFrames(1, function()
            if not NETP.on or NETP.gen ~= gen or ST.travel then return true end
            local ok, err = pcall(MP.netFrameP)
            if not ok then out("!! 多人联机 -> %s", tostring(err)) end
        end)
    else
        out("!! 多人联机：没有 LoopInGameThreadAfterFrames")
    end
end

-- main.lua netRecv：src=<数字> 的包
function MP.feed(t, tn)
    local pid = tonumber(t.src)
    if not pid then return end
    local sess0 = ctx.session and ctx.session() or {}
    if tonumber(sess0.mpid) == pid then return end           -- 自己的（不该来，保险）
    RULE.peerSeen = RULE.peerSeen or {}
    RULE.peerSeen[pid] = true
    if t.mtp then
        -- §306 T6：本人选的队（房主记下来，开局 / 面板预览用；房主的 teamForce 优先于这个）。
        -- 放在最前面：没替身 / 在别的图的人也能先把选择报过来
        local mtp = tonumber(t.mtp)
        if mtp == 0 or mtp == 1 or mtp == 2 or mtp == 3 then
            RULE.teamWant = RULE.teamWant or {}
            RULE.teamWant[pid] = mtp
        end
    end
    if t.rfp ~= nil then
        RULE.peerRfp = RULE.peerRfp or {}
        local mid, fp = t.rfp:match("^(%d+):(%x+)$")
        RULE.peerRfp[pid] = { mid = tonumber(mid), fp = fp, at = tn }
        -- §299 对局中第一次发现某人规则和我（对局主机）不一致：横幅点名一次（不拦对局，和 1v1 一样只提示）
        if fp and isHost() and inMatch() and MP.rfpStatus(pid) == "diff" then
            RULE.rfpWarned = RULE.rfpWarned or {}
            local key = tostring(mid) .. ":" .. pid
            if not RULE.rfpWarned[key] then
                RULE.rfpWarned[key] = true
                local msg = string.format(T("%s 的规则和你不一致", "%s'S RULES DO NOT MATCH YOURS"), nameOf(pid))
                if ctx.notice then ctx.notice(msg, "", 3.0) end
                out("多人对局：%s（对局 #%s）", msg, tostring(mid))
            end
        end
    end
    if checkHostChange then checkHostChange(tn) end
    if DUEL and DUEL.isDuel() then
        DUEL.onPacket(t, tn)
        -- §295 选手拿对手包里的规则指纹比（房主当观众时不发状态包，不能只比房主的）；和替身无关，放在生成替身之前
        if ctx.rfpPeer and t.rfp then
            local me = myPid()
            if (me == DUEL.fa and pid == DUEL.fb) or (me == DUEL.fb and pid == DUEL.fa) then ctx.rfpPeer(t.rfp) end
        end
        if not DUEL.allowSpawn(pid) then
            if pid == hostPid() and not isHost() and ctx.recvRules then ctx.recvRules(t) end
            return
        end
    end
    local L = live()
    if not L then
        if not NETP.noLive then NETP.noLive = true; out("!! 多人：观战模块没有 _live（pbz_spec.lua 太旧？），没法驱动替身") end
        return
    end
    if MP.on then MP.stop("联机多人的包到了") end
    if ST.stableTicks < 90 then return end                 -- 世界还在加载
    local p1 = getP1()
    if not valid(p1) then return end
    local s = NETP.side[pid]
    -- 自己在哪张图：每 2 秒读一次（以前每个包都 GetWorld 一遍）
    if not NETP.mapAt or tn - NETP.mapAt > 2.0 or tn < NETP.mapAt then NETP.mapAt, NETP.myMap = tn, G.mapName and G.mapName(p1) or nil end
    local myMap = NETP.myMap
    if t.map and t.map ~= "" and myMap and t.map ~= myMap then
        if s then s.lastAt = tn; netIdle(s, true) end
        if not NETP.warnMap or tn - NETP.warnMap > 10 then NETP.warnMap = tn; out("多人：%d 号在另一张地图 %s（我在 %s），先不摆", pid, t.map, myMap) end
        return
    end
    if not s then
        s = netSpawn(pid, t)
        if not s then return end
    end
    netEnsureLoop()
    if t.nm and t.nm ~= "" and not s.nick then s.nick = t.nm end
    if t.mph and t.mph ~= "" then
        s.lastMph = t.mph
        s.lastMphAt = tn
        for idStr in t.mph:gmatch("(%d+)") do
            if tonumber(idStr) == myPid() then
                s.hitMeAt = tn
            end
        end
    end
    if t.mt3 then s.has3 = true end      -- §317 认得三队的版本
    s.watch = (t.mwo == "1") or nil      -- §318 只看不上场
    if t.mpo and not isHost() then MP.hostTeams = tonumber(t.mpo) end      -- §317 房主对局外的分队设置
    if t.mpk and t.mpk ~= "" then
        s.hasMpk = true
        local mid, d, killer = t.mpk:match("^(%d+):(%d+):(%d+)$")
        if mid and tonumber(mid) == RULE.mid and inMatch() then
            d, killer = tonumber(d), tonumber(killer)
            local prevD = s.lastMpkDeaths or 0
            if d > prevD then
                s.lastMpkDeaths = d
                if killer == myPid() then
                    RULE.koVictim = s.idx
                    RULE.koTill = tn + 3.0
                    if ctx.notice then ctx.notice(string.format(T("你击倒了 %s", "YOU KNOCKED DOWN %s"), nameOf(s.idx)), "", 1.5) end
                    out("多人对局：你击倒了 %s", nameOf(s.idx))
                end
                if isHost() then
                    RULE.stats = RULE.stats or {}
                    RULE.stats[s.idx] = RULE.stats[s.idx] or { k = 0, d = 0 }
                    RULE.stats[s.idx].d = d
                    if killer ~= 0 and killer ~= s.idx and part(killer) then
                        local sTm = (MP.teamsOn(RULE.teams) and RULE.teamOf and RULE.teamOf[s.idx]) or 0
                        local kTm = (MP.teamsOn(RULE.teams) and RULE.teamOf and RULE.teamOf[killer]) or 0
                        if not MP.teamsOn(RULE.teams) or sTm == 0 or sTm ~= kTm then
                            RULE.stats[killer] = RULE.stats[killer] or { k = 0, d = 0 }
                            RULE.stats[killer].k = (RULE.stats[killer].k or 0) + 1
                        end
                    end
                end
            end
        end
    end
    if isHost() and inMatch() and RULE.st == "fight" and t.pick and t.pick ~= "" then
        local bid = tonumber(t.pick)
        if bid and hostTakeBuff then hostTakeBuff(bid, pid, tn) end
    end
    if t.wpn then s.wpn = t.wpn end
    if t.edg then s.edg = t.edg end
    s.duelHp, s.duelHpm, s.duelMpd = tonumber(t.hp), tonumber(t.hpm), t.mpd
    if pid == hostPid() and not isHost() and ctx.recvRules then
        ctx.recvRules(t)
    end
    if pid == hostPid() and t.mpm and MP._hostState then MP._hostState(t, tn) end    -- ②d 客机：主机说的对局状态
    if MP._peerDead then MP._peerDead(s, t, tn) end
    local wasFired = s.fired or 0
    MP.applyP = MP.applyP or wrap("·多人包应用", function(s2, t2, tn2) pcall(L.apply, s2, t2, tn2) end)
    local counts = not MP._movesCount or MP._movesCount(s)
    if s.peer then
        MP.applyP(s, t, tn)                 -- §223 联机（s.live）的 pktApply 只记血条要的 hp / sq
        MP.peerQueue(s, t, tn, counts)      -- §287 招式 / 动作 / 换装 / 位置交给这个替身那份 PEER（逻辑里 peerStep）
    elseif counts then
        MP.applyP(s, t, tn)
    else
        -- 招不算的时候也要记下编号 / 计数，不然下一回合一开打就把攒着的老招一次全放出来
        local mx = s.evMax or -1
        for id in (t.ev or ""):gmatch("(%d+):") do id = tonumber(id); if id > mx then mx = id end end
        s.evMax = mx
        for _, k in ipairs({ "hr", "brk", "med", "sub", "dg" }) do
            local n = tonumber(((t[k] or ""):match("^(%d+):")))
            if n then s.cnt[k] = n end
        end
    end
    if (s.fired or 0) ~= wasFired then s.atkAt = tn end
    s.last, s.lastAt, s.n = t, tn, (s.n or 0) + 1
    -- §318 这局没参加的人（只看不上场 / 开局时不在）：对局里藏起来、关碰撞（不挡路、打不到人），对局外照常显示
    local benched = inMatch() and ((RULE.parts and next(RULE.parts) ~= nil and not part(pid)) or (MP.isAiPid(pid) and s.watch))
    if benched then
        if not s.idle then netIdle(s, true, s.watch and "只看不上场，对局里藏起来" or "这局没参加，对局里藏起来") end
    elseif s.idle then
        netIdle(s, false)
    end
    if t.nm and t.nm ~= "" and t.nm ~= s.nick then
        s.nick = t.nm; s.name = aiPrefixed(pid, t.nm) .. "（" .. pid .. "号）"; s.nameAt = nil
        if MP._rename then MP._rename() end     -- ②d 对局里名字带分数
    end
    local x, y = tonumber(t.x), tonumber(t.y)
    if x and y then
        -- 走路动画 / 转身挪到逻辑里（walkTurn，10 次 / 秒），这里只记目标
        s.aim = { X = x, Y = y, Z = tonumber(t.z), vx = tonumber(t.vx) or 0, vy = tonumber(t.vy) or 0, at = tn, air = t.air == "1" }
        if not s.followReady and not s.peer then pcall(followPrep, s) end     -- §287 PEER 的跟随（NPM / RMS）自己管根运动
    end
end

-- ============================================================ ②d 对局规则：单局淘汰（docs/MULTI.md「混战玩法」1，用户 11-10 定）
-- 主机说了算：F1（或面板"开始多人对局"）开始，当时在房间里、有包的人参加 → 倒计时 CD 秒（大家站起、补满、招不算）→ 交手。
-- 每人 lives 条命：倒下（M4.mpDead：血量到底，或慈母护符那种致命一刀同时破防回血）扣一条；还有命 = RESPAWN 秒后原地站起、补满、
-- INVULN 秒内打不掉血；没命了 = 出局，进观战视角（镜头跟着还活着的人，小键盘 * 换人）。
-- 只剩一个人，或时间到（tl 秒），这一局结束 → 显示排名（活到最后的第一；其余按出局先后，后出局的排前；时间到时还活着的按剩余命数、
-- 再按血量百分比）→ ENDS 秒后所有人回到正常状态（退出观战、站起、补满），等下一局。
-- 字段：每人发 mpd=<局号>:<死了几次>:<状态 0 活着 / 1 倒地等复活 / 2 出局>；主机另发 mpm=<状态>:<局号>:<命数>:<时限>:<剩余秒>:<排名 编号,…>
-- 设置（主机）：命数 1 / 2 / 3 / 5、时限 120 / 180 / 300 / 600 秒、房间人数 3 / 4 / 5 / 6 / 8 / 10 / 12（11-15 从最多 6 放到 12），存 net\mp.txt
RULE = {
    st = "idle", mid = 0, lives = 1, tl = 300, remain = 0, rank = {}, at = 0, parts = {},
    deaths = 0, my = 0, downAt = nil, invulnTill = 0, outOrder = {}, warned = {},
    CD = 3.0, ENDS = 8.0, RESPAWN = 3.0, INVULN = 2.0, LOST = 5.0,
    mode = "elim", teams = 0, buffs = 1, siege = 1,
    teamOf = {}, stats = {}, clientDeaths = {}, teamWant = {}, teamForce = {},
    buffsOnField = {}, myBuffFx = {}, knownBuffKinds = {},
    killer = 0, lastHitBy = 0, lastHitAt = 0, lastHp = nil, lastHitHow = nil, killerHow = nil,
    recentHits = {}, siegeActive = false, siegeTill = 0, siegeCdTill = 0, siegeKeepPid = nil,
    protTill = nil, leashTill = nil, leashAt = 0,
    armorTill = 0, hasteTill = 0, origSpeed = nil,
    pickId = nil, pickTill = 0, koVictim = nil, koTill = 0,
    nextBuffAt = 0, lastPickAt = 0, buffGen = 0, lastPickedItem = nil,
    lastMpbRaw = nil, lastHandledMpbt = nil,
    winTeam = nil, teamScore = nil,
    touched = {}, peerRfp = {}, peerSeen = {},
    mtd = {}, aiState = {}, aiGen = 0, aiAutoSynced = nil,
}
MP.rule = RULE
MP.cfg = { size = 4, lives = 1, tl = 300, mode = "elim", teams = 0, buffs = 1, siege = 1, duelRot = "loser", ai = 0 }     -- §295 观众上限不在这里：用房间设置"观战 / 排队人数上限"（联机程序的 maxspec）
MP.SIZES, MP.LIVES, MP.TLS = { 3, 4, 5, 6, 8, 10, 12 }, { 1, 2, 3, 5 }, { 120, 180, 300, 600 }
local ST_NAME = { idle = "没开打", cd = "倒计时", fight = "交手中", ["end"] = "打完了" }

local function ses() return ctx.session and ctx.session() or {} end
function MP.inMp() return ses().mp == "1" end
myPid = function() return tonumber(ses().mpid) or 0 end
hostPid = function()
    local s = ses()
    local h = tonumber(s.mphost)
    if h and h > 0 then return h end
    return 1
end
isHost = function()
    local s = ses()
    if s.mphost ~= nil and s.mphost ~= "" then
        return myPid() == hostPid()
    end
    return s.mp == "1" and s.role == "host" and myPid() == 1
end
inMatch = function() return RULE.st ~= "idle" end
part = function(pid) return RULE.parts[pid] ~= nil end

factionFor = function(s)
    -- §306 T3 / T6：出生保护期间敌方替身一律临时改玩家阵营（打不到我、我也打不到他），
    -- 围攻保护也并进这里算：两个保护同时存在时不管哪个先结束，updatePuppetFactions 都能恢复成正确阵营。
    local prot = RULE.protTill ~= nil and now() < RULE.protTill
    local foe = FOE
    if inMatch() and MP.teamsOn(RULE.teams) then
        local myTm = (RULE.teamOf and RULE.teamOf[myPid()]) or 1
        local sTm = (RULE.teamOf and RULE.teamOf[s.idx]) or 2
        if myTm == sTm then return FRIEND end
        foe = MP.teamFaction(myTm, sTm)
    elseif inMatch() then
        foe = MP.FACTION_CHAOS      -- §335 各自为战：谁都和谁敌对（Chaotic 连同阵营都敌对）
    end
    if prot then return FRIEND end
    if RULE.siegeActive and RULE.siegeKeepPid and s.idx ~= RULE.siegeKeepPid then return FRIEND end
    return foe
end

-- §335 用户 11-15："不应该按分队来分阵营么"。游戏阵营关系表 PBZCombatAsset/Config/Faction/PBZ_FactionCalculator_Compiled（11-15 解出来）：
--   Player / Enemy / Enemy2 / Enemy3 两两敌对、各自同阵营友好；Chaotic 和谁都敌对（连 Chaotic 自己）；Thug / MaskAssassin / NPC 和前四个友好。
-- 所以本机看：我这队 = Player，别的队按队号从小到大 = Enemy / Enemy2 / Enemy3，不同的敌队之间也敌对，AI 之间能真打；各自为战 = Chaotic
MP.FACTION_CHAOS = "Faction.Chaotic"
MP.ENEMY_FACTIONS = { "Faction.Enemy", "Faction.Enemy2", "Faction.Enemy3" }
function MP.teamFaction(myTm, sTm)
    if sTm == myTm then return FRIEND end
    local slot = 0
    for t = 1, 4 do
        if t ~= myTm then
            slot = slot + 1
            if t == sTm then return MP.ENEMY_FACTIONS[slot] or FOE end
        end
    end
    return FOE
end

-- 11-15 实测：队友 = 对局里分队开着、和我同一队（看队伍，不看阵营——出生保护 / 围攻保护会把敌人临时改成玩家阵营，
-- 以前血条颜色 / "对手血条"设置按阵营判断，保护那 1–2 秒里敌人的血条变绿）
function MP.isAlly(s)
    if not (s and inMatch() and MP.teamsOn(RULE.teams) and RULE.teamOf) then return false end
    local myTm = RULE.teamOf[myPid()] or 1
    return (RULE.teamOf[s.idx] or 2) == myTm
end

updatePuppetFactions = function()
    for _, s in ipairs(NETP.list) do
        if valid(s.pup) then
            setFaction(s.pup, factionFor(s))
        end
    end
end

function MP.cfgLoad()
    local kv = ctx.readKV and ctx.mpFile and ctx.readKV(ctx.mpFile) or nil
    if not kv then return end
    local function pick(v, list, def)
        v = tonumber(v)
        for _, x in ipairs(list) do if x == v then return v end end
        return def
    end
    MP.cfg.size = pick(kv.size, MP.SIZES, 4)
    MP.cfg.lives = pick(kv.lives, MP.LIVES, 1)
    MP.cfg.tl = pick(kv.tl, MP.TLS, 300)
    MP.cfg.mode = (kv.mode == "score" or kv.mode == "elim" or kv.mode == "duel") and kv.mode or "elim"
    MP.cfg.duelRot = (kv.duelRot == "both" or kv.duelRot == "loser") and kv.duelRot or "loser"
    MP.cfg.teams = (tonumber(kv.teams) == 1 and 1) or (tonumber(kv.teams) == 3 and 3) or 0     -- §317 三队 = 3
    MP.cfg.buffs = (kv.buffs == "0" or tonumber(kv.buffs) == 0) and 0 or 1
    MP.cfg.siege = (kv.siege == "0" or tonumber(kv.siege) == 0) and 0 or 1
    local maxAi = math.max(0, (MP.cfg.size or 4) - 1)
    MP.cfg.ai = math.max(0, math.min(maxAi, math.floor(tonumber(kv.ai) or 0)))
end

-- §303 只改这一项：换房主后 MP.cfg 里其余各项是沿用旧房主的（只在内存），整份写会把它们存进新房主自己的 mp.txt
local CFG_KEYS = { "size", "lives", "tl", "mode", "teams", "buffs", "siege", "duelRot", "ai" }
local function cfgSave(key)
    if not (ctx.writeFile and ctx.mpFile) then return end
    local disk = ctx.readKV and ctx.readKV(ctx.mpFile)
    if type(disk) ~= "table" then disk = {} end
    if key then disk[key] = tostring(MP.cfg[key]) end
    local lines = {}
    for _, k in ipairs(CFG_KEYS) do
        local v = disk[k]
        if v == nil then v = tostring(MP.cfg[k]) end      -- 文件里还没有的项：用当前值（第一次存）
        lines[#lines + 1] = k .. "=" .. v
    end
    ctx.writeFile(ctx.mpFile, table.concat(lines, "\n") .. "\n")
end

local function hasLocalAi() return ctx.hasAi and ctx.hasAi() == true or false end

local function syncAiCmd(forceN)
    if not (ctx.cmd and isHost()) then return end
    local n = forceN
    if n == nil then
        if MP.cfg.mode == "duel" or (DUEL and DUEL.isDuel()) or not hasLocalAi() then
            n = 0
        else
            n = math.max(0, math.min(tonumber(MP.cfg.ai) or 0, math.max(0, (MP.cfg.size or 4) - 1)))
        end
    end
    ctx.cmd("mpai", "n=" .. tostring(n) .. "\n")
end

local function notifyMpTag()
    if ctx.cmd and isHost() then
        -- 对局中按这局的规则；没开打时按面板当前设置（RULE.mode / teams 开局才写）
        local isD = DUEL and DUEL.isDuel()
        local live = inMatch() or (isD and DUEL.inMatch())
        local m = (isD and "duel") or (live and RULE.mode) or MP.cfg.mode or "elim"
        local tm = (m == "duel") and 0 or (tonumber((live and RULE.teams) or MP.cfg.teams) or 0)
        local st = isD and ((DUEL.state == "cd" or DUEL.state == "fight") and DUEL.state or "idle") or (RULE.st or "idle")
        ctx.cmd("mptag", string.format("m=%s\ntm=%d\nst=%s\n", m, tm, st))
    end
end

function MP.cfgStep(key, list)
    local cur = MP.cfg[key]
    local i = 1
    for k, v in ipairs(list) do if v == cur then i = k end end
    MP.cfg[key] = list[i % #list + 1]
    cfgSave(key)
    if key == "mode" and DUEL then DUEL.syncModeCmd(now and now() or os.clock()) end
    if key == "mode" and MP.cfg.mode == "duel" then
        if (MP.cfg.ai or 0) ~= 0 then
            MP.cfg.ai = 0
            cfgSave("ai")
        end
        syncAiCmd(0)
    elseif key == "size" then
        local maxAi = math.max(0, (MP.cfg.size or 4) - 1)
        if (MP.cfg.ai or 0) > maxAi then
            MP.cfg.ai = maxAi
            cfgSave("ai")
            syncAiCmd()
        end
    end
    notifyMpTag()
    out("多人房间设置：%s → %s", key, tostring(MP.cfg[key]))
end

function MP.stepAi()
    if MP.cfg.mode == "duel" or (DUEL and DUEL.isDuel()) or not hasLocalAi() then return end
    local cap = math.max(0, (MP.cfg.size or 4) - 1)
    MP.cfg.ai = ((tonumber(MP.cfg.ai) or 0) + 1) % (cap + 1)
    MP.aiCfgHold = nil        -- 玩家自己改过：以改的为准，离开房间不再还原
    cfgSave("ai")
    syncAiCmd()
    notifyMpTag()
    out("多人房间设置：ai → %s", tostring(MP.cfg.ai))
end

-- 11-15 用户："3 个模式房间人数是一个配置，只是新版 1v1 拆到对战显示里而已"、"新版 1v1 的观战人数不要超过其他两个模式的上限，不要做特例"：
-- 房间人数只有 MP.cfg.size（3–12）一份；新版 1v1 = 2 人上场 + （人数 − 2）观战排队（pbz_duel 开对决时发 cap = 人数 − 2）。
-- 切玩法后把人数再发一遍（mpsize），联机程序按新玩法换上限 / 观众上限
function MP.roomSize() return MP.cfg.size end
function MP.stepMode()
    MP.cfgStep("mode", MP.MODES_GAME)     -- 里面 DUEL.syncModeCmd 发 duel on / off
    if ctx.cmd then ctx.cmd("mpsize", "n=" .. tostring(MP.cfg.size) .. "\n") end
    return true
end

nameOf = function(pid)
    if pid == myPid() then return "你" end
    local s = NETP.side[pid]
    if s and s.nick and s.nick ~= "" then return aiPrefixed(pid, s.nick) .. "（" .. pid .. "号）" end
    local mpl = ses().mpl or ""
    for idStr, nm in mpl:gmatch("(%d+):([^,]*)") do
        if tonumber(idStr) == pid and nm ~= "" then return aiPrefixed(pid, nm) .. "（" .. pid .. "号）" end
    end
    if MP.isAiPid(pid) then return "[AI] " .. pid .. "号" end
    return pid .. "号"
end

-- 血条名字：对局里带剩余命数（多条命时）/ 出局 / 积分赛 k/d / 两队前缀
local function renameBars()
    for pid, s in pairs(NETP.side) do
        local base = (s.nick and s.nick ~= "") and (aiPrefixed(pid, s.nick) .. "（" .. pid .. "号）")
                     or (MP.isAiPid(pid) and ("[AI] " .. pid .. "号") or (pid .. "号"))
        local prefix = ""
        if inMatch() and MP.teamsOn(RULE.teams) and RULE.teamOf then
            local myTm = (RULE.teamOf and RULE.teamOf[myPid()]) or 1
            local sTm = (RULE.teamOf and RULE.teamOf[pid]) or 2
            prefix = (myTm == sTm) and T("[队友] ", "[ALLY] ") or T("[敌] ", "[FOE] ")
        end
        local suffix = ""
        if inMatch() and part(pid) then
            if RULE.mode == "score" then
                local st = (RULE.stats and RULE.stats[pid]) or { k = 0, d = 0 }
                suffix = string.format("  %d/%d", st.k or 0, st.d or 0)
            else
                if s.pst == 2 then suffix = T("  出局", "  OUT")
                elseif RULE.lives > 1 then suffix = string.format(T("  剩 %d 命", "  %d LIVES"), math.max(0, RULE.lives - (s.pdeaths or 0))) end
            end
        end
        local nm = prefix .. base .. suffix
        if nm ~= s.name then s.name, s.nameAt = nm, nil end
    end
end

-- ---- 观战视角（自己出局后）：藏起自己、冻住、镜头放到还活着的人身后（小键盘 * 换人）
-- 【适配】SetActorHiddenInGame / CharacterMovement:DisableMovement / PC:SetIgnoreMoveInput / SpawnActor(CameraActor) / SetViewTargetWithBlend
local SPEC = { on = false, cam = nil, idx = 1, target = nil }
MP.specView = SPEC
local function specTargets()
    local list = {}
    local isD = DUEL and DUEL.isDuel()
    for _, s in ipairs(NETP.list) do
        if valid(s.pup) and not s.idle then
            if isD then
                if s.idx == DUEL.fa or s.idx == DUEL.fb then list[#list + 1] = s end
            elseif not inMatch() or (part(s.idx) and s.pst ~= 2) then
                list[#list + 1] = s
            end
        end
    end
    return list
end
local function specStart(kind)
    if SPEC.on then return end
    local p1, pc = getP1(), getP1PC()
    if not (valid(p1) and valid(pc)) then return end
    SPEC.on, SPEC.idx = true, 1
    pcall(function() p1:SetActorHiddenInGame(true) end)
    local cm = rawProp(p1, "CharacterMovement")
    if valid(cm) then pcall(function() cm.Velocity = { X = 0.0, Y = 0.0, Z = 0.0 } end); pcall(function() cm:DisableMovement() end) end
    pcall(function() pc:SetIgnoreMoveInput(true) end)
    if not valid(SPEC.cam) then
        local cls = StaticFindObject("/Script/Engine.CameraActor")
        local l = loc(p1)
        SPEC.cam = valid(cls) and l and try("mp spec cam", function()
            return p1:GetWorld():SpawnActor(cls, { X = l.X, Y = l.Y, Z = l.Z + 300.0 }, { Pitch = -20.0, Yaw = 0.0, Roll = 0.0 }) end) or nil
    end
    if valid(SPEC.cam) then pcall(function() pc:SetViewTargetWithBlend(SPEC.cam, 0.5, 0, 0.0, false) end) end
    out("多人：进观战视角（镜头 %s）", valid(SPEC.cam) and "已建" or "建不了，镜头不动")
    if ctx.notice then
        if DUEL and DUEL.isDuel() then
            ctx.notice(T("观战 1v1 对决", "SPECTATING 1V1 DUEL"), T("小键盘 * 切换视角", "NUMPAD * SWITCH TARGET"), 3.0)
        elseif kind == "late" then      -- §322 对局中进房
            ctx.notice(T("对局进行中：这局先观战", "MATCH IN PROGRESS: SPECTATING"), T("打完自动参加下一局 · 小键盘 * 换人看", "YOU JOIN THE NEXT MATCH · NUMPAD * SWITCH TARGET"), 4.0)
        elseif kind == "watch" then     -- §318
            ctx.notice(T("观战中（只看不上场）", "SPECTATING (WATCH ONLY)"), T("小键盘 * 换人看", "NUMPAD * SWITCH TARGET"), 3.0)
        else
            ctx.notice(T("你出局了：观战中", "YOU ARE OUT: SPECTATING"), T("小键盘 * 换人看", "NUMPAD * SWITCH TARGET"), 3.0)
        end
    end
end
local function specStop()
    if not SPEC.on then return end
    SPEC.on = false
    local p1, pc = getP1(), getP1PC()
    if valid(p1) then
        pcall(function() p1:SetActorHiddenInGame(false) end)
        local cm = rawProp(p1, "CharacterMovement")
        if valid(cm) then pcall(function() cm:SetMovementMode(1, 0) end) end
    end
    if valid(pc) then
        pcall(function() pc:ResetIgnoreMoveInput() end)
        if valid(p1) then pcall(function() pc:SetViewTargetWithBlend(p1, 0.4, 0, 0.0, false) end) end
    end
    out("多人：退出观战视角")
end
-- 每帧：镜头放到目标身后 4.5 米、高 2 米，看着他
local function specFrame()
    if not (SPEC.on and valid(SPEC.cam)) then return end
    local list = specTargets()
    if #list == 0 then return end
    if SPEC.idx > #list then SPEC.idx = 1 end
    local s = list[SPEC.idx]
    local l = loc(s.pup)
    if not l then return end
    local yaw = math.rad(G.yawOf and G.yawOf(s.pup) or 0)
    local cx, cy, cz = l.X - math.cos(yaw) * 450.0, l.Y - math.sin(yaw) * 450.0, l.Z + 200.0
    local pitch = math.deg(math.atan(l.Z + 60.0 - cz, 450.0))
    pcall(function() SPEC.cam:K2_SetActorLocationAndRotation({ X = cx, Y = cy, Z = cz }, { Pitch = pitch, Yaw = math.deg(yaw), Roll = 0.0 }, false, {}, true) end)
end
MP.specFrameP = ctx.prof and ctx.prof("·多人观战镜头", specFrame) or specFrame
function MP.nextView()
    if not SPEC.on then return false end
    SPEC.idx = SPEC.idx + 1
    local list = specTargets()
    if SPEC.idx > #list then SPEC.idx = 1 end
    local s = list[SPEC.idx]
    if s and ctx.notice then ctx.notice(T("观战：", "SPECTATING: ") .. nameOf(s.idx), "", 1.5) end
    return true
end

local function getHpRatio(pid)
    local p1 = getP1()
    if pid == myPid() then
        local hp, mx = G.hpOf(p1), G.attrOf(p1, "Health_Max")
        return (hp and mx and mx > 0) and hp / mx or 0
    end
    local s = NETP.side[pid]
    return (s and s.hp and s.hpm and s.hpm > 0) and s.hp / s.hpm or 0
end

local function getLivesLeft(pid)
    if pid == myPid() then return RULE.lives - RULE.deaths end
    local s = NETP.side[pid]
    return RULE.lives - ((s and s.pdeaths) or 0)
end

local function getScoreDiff(pid)
    local st = (RULE.stats and RULE.stats[pid]) or { k = 0, d = 0 }
    return (st.k or 0) - (st.d or 0)
end

-- §334 用户 11-15："击杀优先，同击杀再看谁死的少，死的也一样看剩余血量"（单局淘汰的个人名次；哪一队赢照旧按存活）
local function getKills(pid)
    local st = RULE.stats and RULE.stats[pid]
    return (st and st.k) or 0
end
-- §334.1 排名时算"离开了"：换房主时走掉的前房主（leftSet）+ 现在还连不上、又不是正常出局的
function MP.leftMatch(pid)
    if RULE.leftSet and RULE.leftSet[pid] then return true end
    if pid == myPid() then return false end
    local s = NETP.side[pid]
    if not s then return true end
    return s.pst ~= 2 and (now() - (s.lastAt or 0)) >= RULE.LOST
end
local function eliminationBefore(a, b)
    -- §334.1 对局中离开 / 掉线的人排在最后（以前按击杀排，换房主时走掉的前房主有击杀就排第一）
    local la, lb = MP.leftMatch(a), MP.leftMatch(b)
    if la ~= lb then return lb end
    local ka, kb = getKills(a), getKills(b)
    if ka ~= kb then return ka > kb end
    local da, db = RULE.lives - getLivesLeft(a), RULE.lives - getLivesLeft(b)     -- 死了几次
    if da ~= db then return da < db end
    local ha, hb = getHpRatio(a), getHpRatio(b)
    if ha ~= hb then return ha > hb end
    return a < b
end
MP.eliminationBefore = eliminationBefore

-- ---- 排名提示（多行）
local function showRank()
    local rows = {}
    if MP.teamsOn(RULE.teams) then
        local myTm = (RULE.teamOf and RULE.teamOf[myPid()]) or 1
        local winTm = (RULE.rank and #RULE.rank > 0 and RULE.teamOf and RULE.teamOf[RULE.rank[1]]) or 1
        local titleMsg
        if RULE.mode == "score" then
            local k = MP.teamCount(RULE.teams)
            local ts = {}
            for t = 1, k do ts[t] = 0 end
            if RULE.teamOf then
                for pid, tm in pairs(RULE.teamOf) do
                    local st = RULE.stats and RULE.stats[pid]
                    local diff = st and ((st.k or 0) - (st.d or 0)) or 0
                    ts[tm] = (ts[tm] or 0) + diff
                end
            end
            local tmWon = (winTm == myTm)
            local parts_ = {}
            for t = 1, k do parts_[#parts_ + 1] = string.format(T("%d 队 %d 分", "TEAM %d: %d"), t, ts[t] or 0) end
            local head = tmWon and T("你们队胜", "YOUR TEAM WON") or T("你们队输了", "YOUR TEAM LOST")
            if not part(myPid()) then head = string.format(T("%d 队胜", "TEAM %d WON"), winTm) end      -- §318 观众
            titleMsg = string.format("%s（%s）", head, table.concat(parts_, k == 2 and T(" vs ", " VS ") or " · "))
        else
            local tmWon = (winTm == myTm)
            titleMsg = tmWon and T("你们队胜", "YOUR TEAM WON") or T("你们队输了", "YOUR TEAM LOST")
            if not part(myPid()) then titleMsg = string.format(T("%d 队胜", "TEAM %d WON"), winTm) end    -- §318 观众
        end
        rows[#rows + 1] = { titleMsg, "title" }
    else
        rows[#rows + 1] = { T("这一局结束", "MATCH ENDED"), "title" }
    end

    -- 11-15 用户截图"这个优化下"：两队时每行标 [我队] / [对方]（以前看不出谁是哪队）；行缩短（名次写成 1. 2.、去掉"差"字）、人多时字变小
    local n = #RULE.rank
    local rowSize = n > 8 and 0.7 or n > 4 and 0.8 or 0.9
    local myTm = MP.teamsOn(RULE.teams) and RULE.teamOf and (RULE.teamOf[myPid()] or 1) or nil
    for i, pid in ipairs(RULE.rank) do
        local st = (RULE.stats and RULE.stats[pid]) or { k = 0, d = 0 }
        local k, d = st.k or 0, st.d or 0
        local diff = k - d
        local diffStr = diff >= 0 and ("+" .. diff) or tostring(diff)
        local hpPct = math.floor(getHpRatio(pid) * 100 + 0.5)
        local lab = (i == 1 and not MP.teamsOn(RULE.teams)) and T("1.（获胜）", "1. (WINNER)") or (i .. ".")
        local tm = ""
        if myTm then tm = ((RULE.teamOf[pid] or 2) == myTm) and T("[我队] ", "[MY TEAM] ") or T("[对方] ", "[ENEMY] ") end
        local rowText = string.format(T("%s %s%s   杀 %d  死 %d  %s   血 %d%%", "%s %s%s   K %d  D %d  %s   HP %d%%"),
            lab, tm, nameOf(pid), k, d, diffStr, hpPct)
        rows[#rows + 1] = { rowText, pid == myPid() and "me" or "row", rowSize }
    end

    if ctx.toast then ctx.toast(rows, RULE.ENDS) elseif ctx.notice then ctx.notice(rows[1][1], rows[2] and rows[2][1] or "", RULE.ENDS) end
    local t = {}
    for i, pid in ipairs(RULE.rank) do t[#t + 1] = i .. "." .. nameOf(pid) end
    out("多人对局结束（局号 %d）：%s", RULE.mid, table.concat(t, "  "))
end

-- §336 倒地到复活这段关输入（以前倒地后还能出招、打出的伤害照算：用户 11-15 22:20:51 倒地后连放黑魔伤 A / AA 到复活）
local function downLock(on, why)
    if (on and RULE.downLocked) or (not on and not RULE.downLocked) then return end
    if on and ctx.uiBusy and ctx.uiBusy() then return end      -- 面板开着：输入本来就不进游戏
    local ok, err = false, "没有 gameInputBlock"
    if G.gameInputBlock then ok, err = G.gameInputBlock(on) end
    RULE.downLocked = (on and ok) and true or nil
    out("多人对局：%s输入（%s）%s", on and "关" or "开回", why or "-", ok and "" or ("：!! " .. tostring(err)))
end
MP._downLock = downLock

-- §336 护体改成真减伤：10 秒内把自己的承伤倍率 TakenReductionMultiplier_Physical / _Elemental 乘 0.5，到时间 / 对局收尾写回
-- （以前是挨打后退一半血：一刀致死的挡不住，300% 伤害下几乎感觉不到——用户 11-15）
MP.ARMOR_ATTRS = { "TakenReductionMultiplier_Physical", "TakenReductionMultiplier_Elemental" }
local function armorSet(on)
    local p1 = getP1()
    if not valid(p1) then RULE.armorOrig = nil; return end
    local done = {}
    if on then
        RULE.armorOrig = RULE.armorOrig or {}
        for _, a in ipairs(MP.ARMOR_ATTRS) do
            local cur = G.attrOf and G.attrOf(p1, a)
            if cur then
                if RULE.armorOrig[a] == nil then RULE.armorOrig[a] = cur end
                local v = RULE.armorOrig[a] * 0.5
                if G.setAttr then pcall(G.setAttr, p1, a, v) end
                done[#done + 1] = string.format("%s %.2f→%.2f（读回 %s）", a:gsub("TakenReductionMultiplier_", ""), RULE.armorOrig[a], v, tostring(G.attrOf(p1, a)))
            end
        end
    elseif RULE.armorOrig then
        for a, v in pairs(RULE.armorOrig) do
            if G.setAttr then pcall(G.setAttr, p1, a, v) end
            done[#done + 1] = string.format("%s 写回 %.2f", a:gsub("TakenReductionMultiplier_", ""), v)
        end
        RULE.armorOrig = nil
    end
    if #done > 0 then out("多人：护体%s：%s", on and "生效" or "结束", table.concat(done, "；")) end
end
MP._armorSet = armorSet

restoreSpeed = function()
    downLock(false, "对局收尾")
    if RULE.armorOrig then armorSet(false) end
    if RULE.hasteTill or RULE.origSpeed then
        local p1 = getP1()
        if valid(p1) then
            local cm = rawProp(p1, "CharacterMovement")
            if valid(cm) and RULE.origSpeed then
                pcall(function() cm.MaxWalkSpeed = RULE.origSpeed end)
            end
        end
        RULE.hasteTill, RULE.origSpeed = nil, nil
    end
end

clearAllBuffFx = function()
    if RULE.myBuffFx then
        for _, entry in pairs(RULE.myBuffFx) do
            if entry and valid(entry.comp) and G.destroyComps then
                G.destroyComps({ entry.comp })
            end
            if entry and entry.tag and G.nameTagRemove then G.nameTagRemove(entry.tag) end
        end
        RULE.myBuffFx = {}
    end
end

updateBuffFx = function(newBuffs)
    local p1 = getP1()
    RULE.myBuffFx = RULE.myBuffFx or {}
    local newSet = {}
    for _, b in ipairs(newBuffs or {}) do
        newSet[b.id] = b
    end
    for bid, entry in pairs(RULE.myBuffFx) do
        if not newSet[bid] then
            if entry and valid(entry.comp) and G.destroyComps then
                G.destroyComps({ entry.comp })
            end
            if entry and entry.tag and G.nameTagRemove then G.nameTagRemove(entry.tag) end
            RULE.myBuffFx[bid] = nil
        end
    end
    for _, b in ipairs(newBuffs or {}) do
        if not RULE.myBuffFx[b.id] then
            local path = b.kind == "heal" and FX_BLUE or FX_ORANGE
            local comp = nil
            if G.spawnFxAt then
                comp = G.spawnFxAt(p1, path, { X = b.x, Y = b.y, Z = b.z }, 1.0)
            end
            -- 11-15 用户："地上的道具不太明显"：光柱上加文字标签（借头顶名字那套 UMG 投影，MP.placeTags 每帧摆）
            local tag = nil
            local pc = getP1PC and getP1PC() or nil
            if G.nameTagNew and valid(pc) then
                tag = G.nameTagNew(pc, false)
                local nm = MP.BUFF_LABEL and MP.BUFF_LABEL[b.kind]
                if tag and G.nameTagSet then G.nameTagSet(tag, nm and T(nm[1], nm[2]) or T("道具", "ITEM")) end
                if tag and G.nameTagStyle then G.nameTagStyle(tag, 30, MP.BUFF_COL[b.kind]) end     -- 11-15 实测：白色小字不醒目，放大 + 按种类上色
            end
            RULE.myBuffFx[b.id] = { comp = comp, kind = b.kind, x = b.x, y = b.y, z = b.z, tag = tag, pc = pc }
        end
        RULE.knownBuffKinds = RULE.knownBuffKinds or {}
        RULE.knownBuffKinds[b.id] = b.kind
    end
end

-- 11-15 用户："获得过一次加血道具，似乎没生效"：日志里血其实加上了（433.9 → 1668.1），但直接写 Health 屏幕血条不刷新（§231 同一个坑）。
-- 改我自己的属性先走游戏的改属性函数（G.attrModSet → ModifyCharacterAttributeValue，ASC 广播 → HUD 刷新），不行再直接写；换路时记一行
local function myAttrSet(p1, attr, v)
    local ok, msg = false, "没有 attrModSet"
    if G.attrModSet then
        local okC, r1, r2 = pcall(G.attrModSet, p1, attr, v)
        if okC then ok, msg = r1, r2 else msg = tostring(r1) end
    end
    if not ok then G.setAttr(p1, attr, v) end
    local way = ok and "改属性函数" or "直接写"
    MP.attrWay = MP.attrWay or {}
    if MP.attrWay[attr] ~= way then MP.attrWay[attr] = way; out("多人：改我的 %s 走%s（%s）", attr, way, tostring(msg)) end
end

MP.BUFF_LABEL = { heal = { "＋ 回血", "+ HEAL" }, shachi = { "＋ 杀气", "+ SHACHI" }, armor = { "护体", "ARMOR" }, haste = { "疾行", "HASTE" } }
MP.BUFF_TAG_UP = 160.0      -- 标签离地高度（光柱中段）
MP.BUFF_COL = { heal = { R = 0.35, G = 1.0, B = 0.45 }, shachi = { R = 1.0, G = 0.6, B = 0.2 }, armor = { R = 0.45, G = 0.75, B = 1.0 }, haste = { R = 1.0, G = 0.9, B = 0.3 } }
local BUFF_NAMES = {
    heal = { zh = "回血", en = "HEAL" },
    shachi = { zh = "杀气", en = "SHACHI" },
    armor = { zh = "护体（10 秒）", en = "ARMOR (10S)" },
    haste = { zh = "疾行（10 秒）", en = "HASTE (10S)" },
}

onBuffPicked = function(bid, taker, tn)
    if RULE.pickId == bid then
        RULE.pickId, RULE.pickTill = nil, nil
    end
    local kind = (RULE.knownBuffKinds and RULE.knownBuffKinds[bid]) or "heal"
    local bInfo = BUFF_NAMES[kind] or BUFF_NAMES.heal
    local bName = T(bInfo.zh, bInfo.en)
    local p1 = getP1()
    if taker == myPid() then
        if ctx.notice then ctx.notice(string.format(T("你捡到 %s", "YOU PICKED UP %s"), bName), "", 2.0) end
        out("多人：你捡到 %s", bName)
        if valid(p1) then
            if kind == "heal" then
                local hp, mx = G.hpOf(p1), G.attrOf(p1, "Health_Max")
                if hp and mx then myAttrSet(p1, "Health", math.min(mx, hp + mx * 0.4)) end
            elseif kind == "shachi" then
                local sm = G.attrOf(p1, "Shachi_Max")
                if sm then myAttrSet(p1, "Shachi", sm) end
            elseif kind == "armor" then
                RULE.armorTill = tn + 10.0
                armorSet(true)
            elseif kind == "haste" then
                local cm = rawProp(p1, "CharacterMovement")
                if valid(cm) then
                    if not RULE.hasteTill then
                        RULE.origSpeed = tonumber(rawProp(cm, "MaxWalkSpeed")) or 600.0
                    end
                    pcall(function() cm.MaxWalkSpeed = (RULE.origSpeed or 600.0) * 1.3 end)
                    RULE.hasteTill = tn + 10.0
                    -- §336 读回核对（以前没核对，用户说"没感觉"）；1 秒后再记一次实际跑动速度，看游戏认不认这个值
                    out("多人：疾行 MaxWalkSpeed %.0f → 写 %.0f，读回 %s", RULE.origSpeed or 0, (RULE.origSpeed or 600.0) * 1.3, tostring(rawProp(cm, "MaxWalkSpeed")))
                    RULE.hasteProbeAt = tn + 1.0
                end
            end
        end
    else
        local takerName = nameOf(taker)
        if ctx.notice then ctx.notice(string.format(T("%s 捡到 %s", "%s PICKED UP %s"), takerName, bName), "", 2.0) end
        out("多人：%s 捡到 %s", takerName, bName)
    end
end

hostTakeBuff = function(bid, taker, tn)
    if not part(taker) then return end
    if taker == myPid() then
        if RULE.my ~= 0 then return end
    else
        local s = NETP.side[taker]
        if not s or (s.pst or 0) ~= 0 or s.fallen then return end
    end
    local foundIdx = nil
    for idx, b in ipairs(RULE.buffsOnField or {}) do
        if b.id == bid then foundIdx = idx; break end
    end
    if not foundIdx then return end
    table.remove(RULE.buffsOnField, foundIdx)
    RULE.lastPickedItem = { id = bid, taker = taker }
    onBuffPicked(bid, taker, tn)
    updateBuffFx(RULE.buffsOnField)
end

-- 回到正常状态（开局倒计时 / 一局结束后）
local function restoreAll()
    specStop()
    restoreSpeed()
    clearAllBuffFx()
    RULE.deaths, RULE.my, RULE.downAt, RULE.invulnTill = 0, 0, nil, 0
    RULE.killer = 0
    RULE.lastHitBy, RULE.lastHitAt = nil, nil
    RULE.lastHitHow, RULE.killerHow = nil, nil
    RULE.protTill, RULE.leashTill, RULE.leashAt = nil, nil, 0
    RULE.lastHp = nil
    RULE.armorTill, RULE.hasteTill, RULE.origSpeed = nil, nil, nil
    RULE.siegeActive = false
    RULE.siegeTill, RULE.siegeCdTill = nil, nil
    RULE.recentHits = {}
    RULE.buffsOnField = {}
    RULE.pickId, RULE.pickTill = nil, nil
    RULE.koVictim, RULE.koTill = nil, nil
    RULE.lastPickedItem = nil
    RULE.mtd = {}
    RULE.mta, RULE.mtaSeg = {}, {}     -- §335
    RULE.aiState = {}
    local p1 = getP1()
    if valid(p1) then G.standUp(p1); G.refill(p1) end
    for _, s in pairs(NETP.side) do
        if s.fallen then s.fallen = false; G.standUp(s.pup) end
        s.pst, s.pdeaths, s.lastMpkDeaths = 0, 0, 0
        s.aiTrackedHp, s.aiContactAt = nil, nil
    end
    updatePuppetFactions()
end

local function calcArenaSpawn(cx, cy, cz, radius, idx, total)
    total = (total and total > 0) and total or 1
    idx = (idx and idx >= 1) and idx or 1
    radius = tonumber(radius) or 400.0
    cx, cy, cz = tonumber(cx) or 0.0, tonumber(cy) or 0.0, tonumber(cz) or 0.0
    local angle = (idx - 1) * (2 * math.pi / total)
    local px = cx + radius * math.cos(angle)
    local py = cy + radius * math.sin(angle)
    local pz = cz
    local rad = (math.atan2 or math.atan)(cy - py, cx - px)
    local yaw = math.deg(rad)
    yaw = (yaw + 180) % 360 - 180
    return { X = px, Y = py, Z = pz, x = px, y = py, z = pz }, yaw
end

-- §306 T2：房主开局用的场地。存过场地就用（半径至少 4 米、基准朝向统一 0）；没有就用房主当前位置当中心
-- （半径 6 米、基准朝向 = 房主朝向），这样任何图都总有固定开战点，客机按广播的 mpa/mpay 算出来的点和房主一致。
function MP.buildArena()
    local a = ctx.getArena and ctx.getArena() or nil
    if a and a.cx and a.cy and a.cz then
        return { cx = tonumber(a.cx) or 0.0, cy = tonumber(a.cy) or 0.0, cz = tonumber(a.cz) or 0.0,
                 radius = math.max(tonumber(a.radius) or 400.0, 400.0), yaw = 0.0, auto = false }
    end
    local p1 = getP1()
    local l = valid(p1) and loc(p1) or nil
    if not l then return nil end
    local yaw = 0.0
    if G.yawOf then
        local ok, y = pcall(G.yawOf, p1)
        if ok and tonumber(y) then yaw = tonumber(y) end
    end
    return { cx = l.X, cy = l.Y, cz = l.Z, radius = 600.0, yaw = yaw, auto = true }
end

enter = function(st, tn, why)
    local was = RULE.st
    RULE.st, RULE.at = st, tn
    if st == "cd" then
        if ctx.onMatchEnd and RULE.matchStarted then
            ctx.onMatchEnd(RULE.activeMid or RULE.mid, "重新开始")
            RULE.matchStarted = false
            RULE.activeMid = nil
        end
        if ctx.onMatchStart and not RULE.matchStarted then
            RULE.matchStarted = true
            RULE.activeMid = RULE.mid
            ctx.onMatchStart(RULE.mid)
        end

        restoreAll()
        RULE.outOrder, RULE.rank, RULE.warned = {}, {}, {}
        RULE.leftSet = {}      -- §334.1 对局中离开 / 掉线的人

        if ctx.rulesSnapshot then ctx.rulesSnapshot() end

        -- §306 T2：房主在这一刻定开战点（没存场地 = 房主当前位置），客机用主机包里的 mpa/mpay
        if isHost() then RULE.arena = MP.buildArena() end
        local spawnPlan = nil
        if RULE.arena then
            local ps = {}
            for pid in pairs(RULE.parts) do ps[#ps + 1] = pid end
            table.sort(ps)
            spawnPlan = MP.spawnPlan(RULE.arena, ps, MP.teamsOn(RULE.teams) and RULE.teamOf or nil, MP.teamCount(RULE.teams))
        end
        if isHost() then
            RULE.aiState = {}
            for pid in pairs(RULE.parts) do
                if MP.isAiPid(pid) then
                    RULE.aiGen = (RULE.aiGen or 0) + 1
                    local fallback = RULE.arena and { X = RULE.arena.cx, Y = RULE.arena.cy, Z = RULE.arena.cz, yaw = RULE.arena.yaw or 0.0 }
                    local pt = aiSpotFromPlan(spawnPlan and spawnPlan[pid], fallback)
                    RULE.aiState[pid] = { st = "cd", gen = RULE.aiGen, x = pt.X, y = pt.Y, z = pt.Z, yaw = pt.yaw }
                end
            end
        end
        if RULE.arena and spawnPlan and part(myPid()) then
            local target = spawnPlan[myPid()]
            local p1 = getP1()
            if target and valid(p1) and ctx.safePlace then
                local anchor = { X = RULE.arena.cx, Y = RULE.arena.cy, Z = RULE.arena.cz + 20.0 }
                local yaw = tonumber(target.yaw) or 0.0
                ctx.safePlace(p1, target, anchor, yaw, "多人对局开战归位")
                if ctx.setYaw then ctx.setYaw(p1, yaw) end
                if ctx.setControlRotation then ctx.setControlRotation(-10.0, yaw, 0.0) end
            end
            if ctx.arnLock then ctx.arnLock() end
        end
        -- §318 只看不上场 / §322 对局开始时不在参加名单里（比如倒计时里刚进房）：整局观战镜头，打完 restoreAll 收。
        -- 在别的图的人收不到房主的对局状态（feed 里先按地图挡掉），不会走到这里
        if not part(myPid()) then specStart(MP.myWatch and "watch" or "late") end

        -- §306 T4：房间名单里有、但这次没包 / 不在本图的人点名（不拦开局）
        -- 验收改：不单独弹（会被下面"X 秒后开打"那条马上盖掉），名字并进倒计时提示的第二行
        local absent, watching = {}, {}
        for _, m in ipairs(MP.members and MP.members() or {}) do
            if not RULE.parts[m.pid] then
                local ws = NETP.side[m.pid]
                if (m.pid == myPid() and MP.myWatch) or (ws and ws.watch) then watching[#watching + 1] = m.name     -- §318
                else absent[#absent + 1] = m.name end
            end
        end
        if #absent > 0 then out("多人对局：%s 不在这张图 / 没包，这局不参加", table.concat(absent, "、")) end

        if ctx.rulesBegin then ctx.rulesBegin("cd", "多人对局倒计时", true, tn) end

        local who = {}
        for pid in pairs(RULE.parts) do who[#who + 1] = nameOf(pid) end
        local subInfo
        if RULE.mode == "score" then
            subInfo = string.format(T("%d 人 · 积分赛 · 时限 %d 秒", "%d PLAYERS · SCORE ATTACK · TIME %d S"), #who, RULE.tl)
        else
            subInfo = string.format(T("%d 人 · 每人 %d 条命 · 时限 %d 秒", "%d PLAYERS · %d LIVES · TIME %d S"), #who, RULE.lives, RULE.tl)
        end
        if #absent > 0 then
            subInfo = subInfo .. string.format(T(" · %s 不在这张图，不参加", " · %s NOT ON THIS MAP, SKIPPED"), table.concat(absent, "、"))
        end
        if #watching > 0 then
            subInfo = subInfo .. string.format(T(" · %s 只看不上场", " · %s WATCHING"), table.concat(watching, "、"))
            out("多人对局：%s 只看不上场", table.concat(watching, "、"))
        end
        if ctx.notice then ctx.notice(string.format(T("多人对局 · %d 秒后开打", "STARTING IN %d S"), RULE.CD), subInfo, RULE.CD) end
    elseif st == "fight" then
        if isHost() and RULE.aiState then
            for pid, ast in pairs(RULE.aiState) do
                if part(pid) then ast.st = "fight" end
            end
        end
        if ctx.rulesBegin then ctx.rulesBegin("fight", "多人对局开打", false, tn) end
        if ctx.arnUnlock then ctx.arnUnlock("多人开打") end
        updatePuppetFactions()
        -- §322 中途进房（第一次收到房主的对局状态就是交手中）/ 只看不上场：这局不参加，进观战镜头，不弹"开打！"
        local benchedMe = not part(myPid())
        if benchedMe then specStart(MP.myWatch and "watch" or "late") end
        if ctx.notice and not benchedMe then
            if RULE.mode == "score" then
                ctx.notice(T("开打！", "FIGHT!"), T("积分赛（击倒后附近复活）", "SCORE ATTACK (RESPAWN NEARBY)"), 1.5)
            else
                ctx.notice(T("开打！", "FIGHT!"), string.format(T("每人 %d 条命", "%d LIVES EACH"), RULE.lives), 1.5)
            end
        end
    elseif st == "end" then
        RULE.mtd = {}
        RULE.mta, RULE.mtaSeg = {}, {}     -- §335
        if isHost() and RULE.aiState then
            for _, ast in pairs(RULE.aiState) do ast.st = "idle"; ast.respawnAt = nil end
        end
        if ctx.rulesEnd then ctx.rulesEnd("多人对局结束") end
        if ctx.arnUnlock then ctx.arnUnlock("多人结束") end
        if ctx.onMatchEnd and RULE.matchStarted then
            ctx.onMatchEnd(RULE.activeMid or RULE.mid, "对局结束")
            RULE.matchStarted = false
            RULE.activeMid = nil
        end
        showRank()
        restoreSpeed()
        clearAllBuffFx()
        -- §306 T3/T4：对局结束也要立刻清掉出生保护和拉回倒计时
        RULE.protTill, RULE.leashTill = nil, nil
        updatePuppetFactions()
    elseif st == "idle" then
        if was ~= "end" and was ~= "idle" then
            if ctx.rulesEnd then ctx.rulesEnd(why or "多人对局取消/回自由活动") end
        end
        if ctx.rulesClear then ctx.rulesClear() end
        RULE.arena = nil
        if ctx.arnUnlock then ctx.arnUnlock("多人回自由活动") end
        if ctx.onMatchEnd and RULE.matchStarted then
            ctx.onMatchEnd(RULE.activeMid or RULE.mid, why or "对局取消")
            RULE.matchStarted = false
            RULE.activeMid = nil
        end
        restoreAll()
        RULE.parts = {}
        RULE.teamOf = {}
        updatePuppetFactions()
        if was ~= "end" and was ~= "idle" and ctx.notice then ctx.notice(T("多人对局取消", "MATCH CANCELLED"), "", 2.0) end
    end
    renameBars()
    notifyMpTag()
    out("多人对局：%s → %s（局号 %d）", ST_NAME[was] or was, ST_NAME[st] or st, RULE.mid)
end

checkHostChange = function(tn)
    local curHost = hostPid()
    -- §326.3 开房后按存好的 AI 数量（net\mp.txt 的 ai=）补发一次 mpai。以前这段只在 lastHostPid 第一次赋值时跑：
    -- 游戏一启动（还没开房）就跑过了，之后开房永远不发，AI 要在面板里再点一次才进来（优化会话 14:08 服务器大厅 / 13:5x 局域网实测）。
    -- 现在：每进一个多人房、拿到编号后判一次（只有房主发）；离开房间清标记。换房主时下面那支把标记设成新房主，
    -- 新房主不补发（AI 随旧房主消失，§326 的设计）
    if not MP.inMp() then
        RULE.aiAutoSynced = nil
        lastHostPid = nil         -- 离开房间：下一个房间重新记房主（以前留着，下个房间房主编号不同会被当成换房主）
        if MP.aiCfgHold ~= nil then MP.cfg.ai, MP.aiCfgHold = MP.aiCfgHold, nil end     -- 接任房主时临时归零的 AI 数量还原
    elseif RULE.aiAutoSynced == nil and (tonumber(myPid()) or 0) > 0 then
        local want = isHost() and not (DUEL and DUEL.isDuel()) and (tonumber(MP.cfg.ai) or 0) > 0 and MP.cfg.mode ~= "duel"
        if not want then
            RULE.aiAutoSynced = myPid()
        elseif hasLocalAi() then      -- 联机程序还没报 hasai= 时下一次再判（不记标记）
            RULE.aiAutoSynced = myPid()
            syncAiCmd()
            out("多人：开房按设置补发 AI 数量 %s", tostring(MP.cfg.ai))
        end
    end
    if lastHostPid == nil then
        lastHostPid = curHost
        return
    end
    if lastHostPid ~= nil and curHost ~= lastHostPid then
        local prevHost = lastHostPid
        lastHostPid = curHost
        RULE.aiAutoSynced = curHost
        RULE.aiState = {}
        RULE.mtd = {}
        RULE.mta, RULE.mtaSeg = {}, {}     -- §335
        if isHost() then      -- 接任房主：旧房主的 AI 跟着没了，面板先显示 0；只改内存，离开房间时还原（mp.txt 里的值不动）
            if MP.aiCfgHold == nil then MP.aiCfgHold = MP.cfg.ai end
            MP.cfg.ai = 0
        end
        if DUEL and DUEL.isDuel() then
            DUEL.onHostChanged(curHost, isHost(), tn, prevHost)
            return
        end
        local oldName = nameOf(prevHost)
        local hName = nameOf(curHost)

        if inMatch() then
            local stateAge = RULE.lastHostStateAt and (tn - RULE.lastHostStateAt) or 999.0
            local canSeamless = (RULE.lastHostStateAt ~= nil) and (stateAge <= 5.0)

            if isHost() then
                if not canSeamless then
                    enter("idle", tn)
                    local reason = (RULE.lastHostStateAt == nil) and T("未收到对局状态，本局取消", "NO MATCH STATE, MATCH CANCELLED") or T("对局状态过旧，本局取消", "MATCH STATE TOO OLD, MATCH CANCELLED")
                    local msg = string.format(T("%s 成为房主（%s）", "%s IS NOW THE HOST (%s)"), hName, reason)
                    if ctx.notice then ctx.notice(msg, "", 2.0) end
                    out("多人对局：%s", msg)
                else
                    -- 无缝接任裁判：剩余时间按收到时刻往下扣
                    if RULE.st == "fight" then
                        RULE.at = (RULE.lastHostStateAt or tn) - (RULE.tl - (RULE.remain or RULE.tl))
                    end
                    -- 离开的前房主按出局/离开处理
                    if prevHost and prevHost > 0 then
                        if NETP.side[prevHost] then NETP.side[prevHost].pst = 2 end
                        local seen = false
                        for _, x in ipairs(RULE.outOrder) do if x == prevHost then seen = true end end
                        if not seen then RULE.outOrder[#RULE.outOrder + 1] = prevHost end
                        RULE.leftSet = RULE.leftSet or {}; RULE.leftSet[prevHost] = true
                    end
                    -- 道具 ID 顺延与刷新
                    local maxBid = 0
                    for _, b in ipairs(RULE.buffsOnField or {}) do
                        if b.id and b.id > maxBid then maxBid = b.id end
                        -- §312 实测（11-14 19:32 / 23:43）：客机从房主广播解析的道具没有 dieAt，接任后房主那段按 tn < b.dieAt 过期
                        -- → 每帧报 attempt to compare number with nil（23:43 一次 529 行）。按最长寿命补上（旧房主刷出来最多 30 秒）
                        if not b.dieAt then b.dieAt = tn + 30.0 end
                    end
                    RULE.buffGen = math.max(RULE.buffGen or 0, maxBid)
                    RULE.nextBuffAt = tn + 20.0
                    -- 沿用旧房主规则，不写进本地设置文件
                    if ctx.adoptHostRules then ctx.adoptHostRules() end
                    if RULE.mode then MP.cfg.mode = RULE.mode end
                    if RULE.teams ~= nil then MP.cfg.teams = RULE.teams end
                    if RULE.buffs ~= nil then MP.cfg.buffs = RULE.buffs end
                    if RULE.siege ~= nil then MP.cfg.siege = RULE.siege end
                    if RULE.lives ~= nil then MP.cfg.lives = RULE.lives end
                    if RULE.tl ~= nil then MP.cfg.tl = RULE.tl end

                    local msg = string.format(T("%s 成为房主", "%s IS NOW THE HOST"), hName)
                    if ctx.notice then ctx.notice(msg, "", 2.0) end
                    out("多人对局：%s", msg)
                end
            else
                -- 客机端：标记离开的前房主出局
                if prevHost and prevHost > 0 then
                    if NETP.side[prevHost] then NETP.side[prevHost].pst = 2 end
                    local seen = false
                    for _, x in ipairs(RULE.outOrder) do if x == prevHost then seen = true end end
                    if not seen then RULE.outOrder[#RULE.outOrder + 1] = prevHost end
                    RULE.leftSet = RULE.leftSet or {}; RULE.leftSet[prevHost] = true
                end
                local msg = string.format(T("%s 成为房主", "%s IS NOW THE HOST"), hName)
                if ctx.notice then ctx.notice(msg, "", 2.0) end
                out("多人对局：%s", msg)
            end
        else
            -- 对局外（idle）
            if isHost() then
                if ctx.adoptHostRules then ctx.adoptHostRules() end
                if RULE.mode then MP.cfg.mode = RULE.mode end
                if RULE.teams ~= nil then MP.cfg.teams = RULE.teams end
                if RULE.buffs ~= nil then MP.cfg.buffs = RULE.buffs end
                if RULE.siege ~= nil then MP.cfg.siege = RULE.siege end
                if RULE.lives ~= nil then MP.cfg.lives = RULE.lives end
                if RULE.tl ~= nil then MP.cfg.tl = RULE.tl end
            end
            local msg = string.format(T("%s 成为房主", "%s IS NOW THE HOST"), hName)
            if ctx.notice then ctx.notice(msg, "", 2.0) end
            out("多人对局：%s", msg)
            if isHost() then
                local msg2 = T("你现在是对局主机，按 F1 开始", "YOU ARE NOW MATCH HOST, PRESS F1 TO START")
                if ctx.notice then ctx.notice(msg2, "", 3.0) end
                out("多人对局：%s", msg2)
            end
        end
    end
    lastHostPid = curHost
end

function MP.f1()
    local tn = now()
    if DUEL and DUEL.isDuel() then return DUEL.f1() end
    if not isHost() then
        if ctx.notice then ctx.notice(T("多人对局由房主开始（不用准备）", "THE HOST STARTS THE MATCH (NO READY CHECK)"), inMatch() and ("现在：" .. (ST_NAME[RULE.st] or RULE.st)) or "", 2.0) end
        return
    end
    if inMatch() and RULE.st ~= "end" then
        out("多人对局：主机取消")
        enter("idle", tn)
        return
    end
    -- §318 只看不上场的人（含房主自己）不参加；房主只看时照样当裁判
    local parts, n = {}, 0
    local watchers = {}
    if MP.myWatch then watchers[#watchers + 1] = nameOf(myPid()) else parts[myPid()], n = true, 1 end
    for pid, s in pairs(NETP.side) do
        if not s.idle and tn - (s.lastAt or 0) < RULE.LOST then
            if s.watch then watchers[#watchers + 1] = nameOf(pid) else parts[pid], n = true, n + 1 end
        end
    end
    if n < 2 then
        if ctx.notice then
            if #watchers > 0 then
                ctx.notice(string.format(T("上场的不到 2 人（现在 %d 人）", "FEWER THAN 2 PLAYERS (%d)"), n),
                           string.format(T("只看不上场：%s", "WATCH ONLY: %s"), table.concat(watchers, "、")), 3.0)
            else
                ctx.notice(T("房间里还没有别人", "NO ONE ELSE IN ROOM"), T("等别的玩家连进来、出现在你这张图上再开始", "WAIT FOR OTHERS TO JOIN"), 2.5)
            end
        end
        return
    end

    local wantMode = MP.cfg.mode
    local wantTeams = MP.cfg.teams
    local wantBuffs = MP.cfg.buffs
    local wantSiege = MP.cfg.siege

    -- §317 三队至少 MP.MIN3 人；每个参加者都要认得三队（发过 mt3=）
    if MP.teamCount(wantTeams) == 3 then
        if n < MP.MIN3 then
            local msg = string.format(T("三队至少 %d 人（现在 %d 人）", "THREE TEAMS NEEDS AT LEAST %d PLAYERS (%d NOW)"), MP.MIN3, n)
            if ctx.notice then ctx.notice(msg, "", 3.0) end
            out("多人对局：%s", msg)
            return
        end
        for pid in pairs(parts) do
            if pid ~= myPid() then
                local s = NETP.side[pid]
                if not (s and s.has3) then
                    local msg = string.format(T("%d 号版本太旧，不支持三队", "PLAYER #%d IS ON AN OLD VERSION WITHOUT THREE TEAMS"), pid)
                    if ctx.notice then ctx.notice(msg, "", 3.0) end
                    out("多人对局：%s", msg)
                    return
                end
            end
        end
    end
    -- 版本门槛：主机按 F1 开局时，如果选了积分赛或两队，所有参加者必须发过 mpk=（= 新版本）；有人没发就不开局，提示"X 号版本太旧，只能单局淘汰 / 各自为战"。
    if wantMode == "score" or MP.teamsOn(wantTeams) then
        for pid in pairs(parts) do
            if pid ~= myPid() then
                local s = NETP.side[pid]
                if not (s and s.hasMpk) then
                    local msg = string.format(T("%d 号版本太旧，只能单局淘汰 / 各自为战", "PLAYER #%d IS ON AN OLD VERSION, CAN ONLY PLAY ELIMINATION / FFA"), pid)
                    if ctx.notice then ctx.notice(msg, "", 3.0) end
                    out("多人对局：%s", msg)
                    return
                end
            end
        end
    end

    -- 禁用武器/影之武装检查
    if ctx.wbanGateMulti then
        local ok, errMsg = ctx.wbanGateMulti(parts, function(id) return NETP.side[id] end, nameOf)
        if not ok then
            if ctx.notice then ctx.notice(T(errMsg, errMsg), "", 3.0) end
            return
        end
    end

    -- §318 分队时每队都要有人（11-15 实测：4 人全点进 2 队 → "0 对 4" 照开，一开打就判 2 队胜、当场结束）
    if MP.teamsOn(wantTeams) then
        local k = MP.teamCount(wantTeams)
        local pids = {}
        for pid in pairs(parts) do pids[#pids + 1] = pid end
        table.sort(pids)
        local cnt = MP.teamSizes(MP.assignTeams(pids, RULE.teamForce, RULE.teamWant, k), pids, k)
        for t = 1, k do
            if cnt[t] == 0 then
                local msg = string.format(T("%d 队没人，不能开局", "TEAM %d IS EMPTY, CAN'T START"), t)
                local strs = {}
                for i = 1, k do strs[i] = tostring(cnt[i]) end
                local sub = string.format(T("现在 %s；在\"房间成员\"里改队，或改回自动", "NOW %s; CHANGE TEAMS IN ROOM MEMBERS OR SET AUTO"), table.concat(strs, T(" 对 ", " VS ")))
                if ctx.notice then ctx.notice(msg, sub, 3.0) end
                out("多人对局：%s（%s）", msg, table.concat(strs, " 对 "))
                return
            end
        end
    end

    RULE.parts, RULE.lives, RULE.tl = parts, MP.cfg.lives, MP.cfg.tl
    RULE.mode, RULE.teams, RULE.buffs, RULE.siege = wantMode, wantTeams, wantBuffs, wantSiege
    RULE.mid = RULE.mid + 1

    -- §306 T6：分队用 assignTeams（房主指定 > 本人选择 > 按编号补人少的一队，一样多补 1 队）。
    -- 人数奇数照开，提示"人数不齐：x 对 y"。
    RULE.teamOf = {}
    if MP.teamsOn(wantTeams) then
        local k = MP.teamCount(wantTeams)
        local pids = {}
        for pid in pairs(parts) do pids[#pids + 1] = pid end
        table.sort(pids)
        RULE.teamOf = MP.assignTeams(pids, RULE.teamForce, RULE.teamWant, k)
        local cnt = MP.teamSizes(RULE.teamOf, pids, k)
        local even, strs = true, {}
        for t = 1, k do
            strs[t] = tostring(cnt[t])
            if cnt[t] ~= cnt[1] then even = false end
        end
        if not even then
            local msg = string.format(T("人数不齐：%s", "UNBALANCED TEAMS: %s"), table.concat(strs, T(" 对 ", " VS ")))
            if ctx.notice then ctx.notice(msg, "", 2.0) end
            out("多人对局：%s", msg)
        end
    end

    RULE.stats = {}
    for pid in pairs(parts) do
        RULE.stats[pid] = { k = 0, d = 0 }
    end
    RULE.buffsOnField = {}
    RULE.nextBuffAt = tn + 20.0

    out("多人对局开始（%s%s）：%d 人，每人 %d 条命，时限 %d 秒",
        wantMode == "score" and "积分赛" or "单局淘汰",
        (MP.teamCount(wantTeams) == 3 and "·三队") or (MP.teamsOn(wantTeams) and "·两队") or "",
        n, RULE.lives, RULE.tl)
    enter("cd", tn)
end

-- 状态包字段（main.lua 发包时拼上）
function MP.wire(tn)
    if checkHostChange then checkHostChange(tn) end
    if DUEL and (DUEL.isDuel() or DUEL.prevInMp or DUEL.duelCmdSent) then
        DUEL.step(tn)
    end
    -- §324 从"观战"进的房（联机程序 mpwatch=1）：一拿到编号就开 §318 的"只看不上场"（状态包 mwo=1；对决那份在 pbz_duel）；
    -- 这里自动开的离开房间时关掉，下次正常加入不受影响
    if MP.inMp() then
        if not MP.joinWatchSet and ses().mpwatch == "1" and myPid() > 0 then
            MP.joinWatchSet = true
            MP.myWatch = true
            out("多人：从观战进房，设为只看不上场（编号 " .. myPid() .. "）")
        end
    elseif MP.joinWatchSet then
        MP.joinWatchSet = nil
        MP.myWatch = false
    end
    if not MP.inMp() then return "" end
    if DUEL and DUEL.isDuel() then
        return DUEL.wire(tn)
    end
    local s = string.format("mpd=%d:%d:%d\n", RULE.mid, RULE.deaths, RULE.my)
    s = s .. string.format("mtp=%d\n", tonumber(MP.myTeamPick) or 0)    -- §306 T6：我选的队（0 自动 / 1 / 2 / 3）
    if MP.myWatch and not (DUEL and DUEL.isDuel()) then s = s .. "mwo=1\n" end    -- §318 只看不上场
    s = s .. "mt3=1\n"                                                    -- §317 我认得三队（房主开三队前查）
    if isHost() and not inMatch() then s = s .. string.format("mpo=%d\n", tonumber(MP.cfg.teams) or 0) end    -- §317 对局外的分队设置给客机面板
    s = s .. string.format("mpk=%d:%d:%d\n", RULE.mid, RULE.deaths, RULE.killer or 0)
    local hitList = {}
    for pid, at in pairs(RULE.touched or {}) do
        if tn - at <= 2.0 then
            hitList[#hitList + 1] = pid
        else
            RULE.touched[pid] = nil
        end
    end
    table.sort(hitList)
    if #hitList > 0 then
        s = s .. string.format("mph=%s\n", table.concat(hitList, ","))
    end
    if RULE.koVictim and tn < (RULE.koTill or 0) then
        s = s .. string.format("ko=%d\n", RULE.koVictim)
    end
    if RULE.pickId and tn < (RULE.pickTill or 0) then
        s = s .. string.format("pick=%d\n", RULE.pickId)
    end
    if RULE.st == "fight" and part(myPid()) and RULE.mtd then
        local mArr = {}
        for k, e in pairs(RULE.mtd) do
            if e and (e.dmg or 0) > 0.5 and tn - (e.at or 0) <= 5.0 then
                mArr[#mArr + 1] = e
            else
                if ctx.flushTouchCap then ctx.flushTouchCap(k, e and e.dmg) end
                RULE.mtd[k] = nil
            end
        end
        if #mArr > 0 then
            table.sort(mArr, function(a, b)
                if a.pid ~= b.pid then return a.pid < b.pid end
                return a.mid < b.mid
            end)
            local mStrs = {}
            for _, e in ipairs(mArr) do
                mStrs[#mStrs + 1] = string.format("%d:%d:%.1f", e.pid, e.mid, e.dmg)
            end
            s = s .. "mtd=" .. table.concat(mStrs, ",") .. "\n"
        end
    end
    -- §335 房主报 AI 打 AI：mta=<出手 AI>:<挨打 AI>:<段>:<这一段累计伤害>（联机程序里挨打的 AI 按 出手:段 记累计扣差值）
    if isHost() and RULE.st == "fight" and RULE.mta then
        local arr = {}
        for k, e in pairs(RULE.mta) do
            if e and (e.dmg or 0) > 0.5 and tn - (e.at or 0) <= 5.0 then arr[#arr + 1] = e
            else RULE.mta[k] = nil end
        end
        if #arr > 0 then
            table.sort(arr, function(a, b)
                if a.vic ~= b.vic then return a.vic < b.vic end
                if a.atk ~= b.atk then return a.atk < b.atk end
                return a.seg < b.seg
            end)
            local strs = {}
            for _, e in ipairs(arr) do strs[#strs + 1] = string.format("%d:%d:%d:%.1f", e.atk, e.vic, e.seg, e.dmg) end
            s = s .. "mta=" .. table.concat(strs, ",") .. "\n"
        end
    end
    if isHost() and inMatch() then
        local ps = {}
        for pid in pairs(RULE.parts) do ps[#ps + 1] = pid end
        table.sort(ps)
        local remain = RULE.st == "fight" and math.max(0, math.floor(RULE.tl - (tn - RULE.at))) or RULE.tl
        local livesOut = RULE.mode == "score" and 99 or RULE.lives
        s = s .. string.format("mpm=%s:%d:%d:%d:%d:%s:%s\n", RULE.st, RULE.mid, livesOut, RULE.tl, remain,
                               table.concat(ps, ","), table.concat(RULE.rank, ","))
        s = s .. string.format("mpx=%s:%d:%d:%d\n", RULE.mode or "elim", RULE.teams or 0, RULE.buffs or 1, RULE.siege or 1)
        if MP.teamsOn(RULE.teams) and RULE.teamOf then
            local tArr = {}
            for _, pid in ipairs(ps) do
                tArr[#tArr + 1] = string.format("%d:%d", pid, RULE.teamOf[pid] or 1)
            end
            s = s .. string.format("mpt=%s\n", table.concat(tArr, ","))
        end
        local sArr = {}
        for _, pid in ipairs(ps) do
            local st = (RULE.stats and RULE.stats[pid]) or { k = 0, d = 0 }
            sArr[#sArr + 1] = string.format("%d:%d:%d", pid, st.k or 0, st.d or 0)
        end
        s = s .. string.format("mps=%s\n", table.concat(sArr, ","))
        local bArr = {}
        for _, b in ipairs(RULE.buffsOnField or {}) do
            bArr[#bArr + 1] = string.format("%d@%.1f@%.1f@%.1f@%s", b.id, b.x, b.y, b.z, b.kind)
        end
        s = s .. string.format("mpb=%s\n", table.concat(bArr, ";"))
        if RULE.lastPickedItem then
            s = s .. string.format("mpbt=%d:%d\n", RULE.lastPickedItem.id, RULE.lastPickedItem.taker)
        end
        if RULE.arena then
            s = s .. string.format("mpa=%.1f:%.1f:%.1f:%.1f\n", RULE.arena.cx, RULE.arena.cy, RULE.arena.cz, RULE.arena.radius)
            s = s .. string.format("mpay=%.1f\n", tonumber(RULE.arena.yaw) or 0.0)    -- §306 T2：基准朝向（旧客户端不认）
        end
        if RULE.aiState then
            local aiPids = {}
            for apid in pairs(RULE.aiState) do
                if part(apid) then aiPids[#aiPids + 1] = apid end
            end
            if #aiPids > 0 then
                table.sort(aiPids)
                local aiArr = {}
                for _, apid in ipairs(aiPids) do
                    local ast = RULE.aiState[apid]
                    aiArr[#aiArr + 1] = string.format("%d:%s:%d:%.1f:%.1f:%.1f:%.1f",
                        apid, ast.st or "cd", ast.gen or 1, ast.x or 0.0, ast.y or 0.0, ast.z or 0.0, ast.yaw or 0.0)
                end
                s = s .. "mpai=" .. table.concat(aiArr, ",") .. "\n"
            end
        end
    end
    return s
end

-- 客机：主机包里的 mpm=
local function hostState(t, tn)
    local st, mid, lv, tl, remain, ps, rk = (t.mpm or ""):match("^(%a+):(%d+):(%d+):(%d+):(%d+):([%d,]*):([%d,]*)$")
    if not st then return end
    mid, lv, tl, remain = tonumber(mid), tonumber(lv), tonumber(tl), tonumber(remain)
    RULE.lastHostStateAt = tn
    RULE.remain = remain
    RULE.remainAt = tn       -- §306 T5：客机按收到时刻往下扣剩余时间

    if t.mpa and t.mpa ~= "" then
        local cx, cy, cz, rad = t.mpa:match("^([%d%.%-]+):([%d%.%-]+):([%d%.%-]+):([%d%.%-]+)$")
        if cx and cy and cz and rad then
            local ayaw = 0.0
            if t.mpay and t.mpay ~= "" then ayaw = tonumber(t.mpay) or 0.0 end
            RULE.arena = { cx = tonumber(cx), cy = tonumber(cy), cz = tonumber(cz), radius = tonumber(rad), yaw = ayaw, auto = false }
        end
    else
        RULE.arena = nil
    end

    if t.mpx and t.mpx ~= "" then
        local m_mode, m_teams, m_buffs, m_siege = t.mpx:match("^([%a_]+):(%d+):(%d+):(%d+)$")
        if m_mode then
            RULE.mode = m_mode
            RULE.teams = tonumber(m_teams) or 0
            RULE.buffs = tonumber(m_buffs) or 1
            RULE.siege = tonumber(m_siege) or 1
        end
    end

    if t.mpt and t.mpt ~= "" then
        RULE.teamOf = RULE.teamOf or {}
        local teamsChanged = false
        for pidStr, tmStr in t.mpt:gmatch("(%d+):(%d+)") do
            local pid, tm = tonumber(pidStr), tonumber(tmStr)
            if RULE.teamOf[pid] ~= tm then
                RULE.teamOf[pid] = tm
                teamsChanged = true
            end
        end
        if teamsChanged then
            updatePuppetFactions()
            renameBars()
        end
    end

    if t.mps and t.mps ~= "" then
        RULE.stats = RULE.stats or {}
        local statsChanged = false
        for pidStr, kStr, dStr in t.mps:gmatch("(%d+):(%d+):(%d+)") do
            local pid, k, d = tonumber(pidStr), tonumber(kStr), tonumber(dStr)
            local stEntry = RULE.stats[pid]
            if not stEntry or stEntry.k ~= k or stEntry.d ~= d then
                RULE.stats[pid] = { k = k, d = d }
                statsChanged = true
            end
            local sPeer = NETP.side[pid]
            if sPeer then
                sPeer.lastMpkDeaths = math.max(sPeer.lastMpkDeaths or 0, d)
            end
        end
        if statsChanged and RULE.mode == "score" then
            renameBars()
        end
    end

    if t.mpb ~= nil then
        if t.mpb ~= RULE.lastMpbRaw then
            RULE.lastMpbRaw = t.mpb
            local newBuffs = {}
            for bStr in t.mpb:gmatch("[^;]+") do
                local bid, bx, by, bz, bkind = bStr:match("^(%d+)@([%d.-]+)@([%d.-]+)@([%d.-]+)@(%a+)$")
                if bid then
                    newBuffs[#newBuffs + 1] = {
                        id = tonumber(bid),
                        x = tonumber(bx),
                        y = tonumber(by),
                        z = tonumber(bz),
                        kind = bkind,
                    }
                end
            end
            updateBuffFx(newBuffs)
            RULE.buffsOnField = newBuffs
        end
    end

    if t.mpbt and t.mpbt ~= "" and t.mpbt ~= RULE.lastHandledMpbt then
        RULE.lastHandledMpbt = t.mpbt
        local bid, taker = t.mpbt:match("^(%d+):(%d+)$")
        if bid and taker then
            bid, taker = tonumber(bid), tonumber(taker)
            onBuffPicked(bid, taker, tn)
        end
    end

    RULE.mid, RULE.lives, RULE.tl = mid, lv, tl
    RULE.parts = {}
    for pid in ps:gmatch("%d+") do RULE.parts[tonumber(pid)] = true end
    RULE.rank = {}
    for pid in rk:gmatch("%d+") do RULE.rank[#RULE.rank + 1] = tonumber(pid) end

    if st == RULE.st and mid == RULE.mid then return end
    -- 客机：交手开始的时刻按主机说的剩余秒数对齐（时间提示用）
    enter(st, st == "fight" and (tn - (tl - remain)) or tn)
end

-- 别人包里的 mpd=<局号>:<死了几次>:<状态>
local function peerDead(s, t, tn)
    local mid, d, pst = (t.mpd or ""):match("^(%d+):(%d+):(%d)$")
    if not mid then
        -- §307 D8：对决选手的发 mpd=<局号>:<回合>（2 段）。旧版这里按 3 段解析、对不上就不播；
        -- 现在补一条：这个人这一回合倒了 → 在他机器上播倒地（下回合 cd 由 standPeer 站起）。
        local dmid, drd = (t.mpd or ""):match("^(%d+):(%d+)$")
        if dmid and DUEL and DUEL.isDuel() and tonumber(dmid) == DUEL.mid and tonumber(drd) == DUEL.round
            and s and (s.idx == DUEL.fa or s.idx == DUEL.fb) then
            if not s.fallen then
                s.fallen, s.feed = true, nil
                if ctx.fallDown then ctx.fallDown(s.pup, (s.tag or nameOf(s.idx)) .. " ") end
                out("对决：%s 倒下（第 %d 回合）", nameOf(s.idx), DUEL.round)
                renameBars()
            end
        end
        return
    end
    if tonumber(mid) ~= RULE.mid or not inMatch() then return end
    d, pst = tonumber(d), tonumber(pst)
    local was = s.pst or 0
    s.pdeaths, s.pst = d, pst
    if pst ~= was then
        if pst >= 1 and not s.fallen then
            s.fallen, s.feed = true, nil
            if ctx.fallDown then ctx.fallDown(s.pup, s.tag .. " ") end
            out("多人对局：%s %s（死了 %d 次）", nameOf(s.idx), pst == 2 and "出局" or "倒下", d)
        elseif pst == 0 and s.fallen then
            s.fallen = false
            G.standUp(s.pup)
            out("多人对局：%s 复活", nameOf(s.idx))
        elseif pst == 2 then
            out("多人对局：%s 出局（死了 %d 次）", nameOf(s.idx), d)
        end
        if isHost() and MP.isAiPid(s.idx) and RULE.aiState and RULE.aiState[s.idx] then
            local ast = RULE.aiState[s.idx]
            local nowT = tn or now()
            if pst == 1 then
                ast.st = "down"
                ast.respawnAt = nowT + (RULE.RESPAWN or 3.0)
            elseif pst == 2 then
                ast.st = "out"
                ast.respawnAt = nil
            else
                ast.st = "fight"
                ast.respawnAt = nil
            end
        end
        renameBars()
    end
end

-- 这个包里的招要不要放：对局里只在交手中、参加的、没倒地的人的才放（我出局 / 倒地了照样看别人打）
local function movesCount(s)
    if DUEL and DUEL.isDuel() then
        if not DUEL.inMatch() then return true end
        return DUEL.state == "fight" and DUEL.isFighter(s and s.idx)
    end
    if not inMatch() then return true end
    if RULE.st ~= "fight" then return false end
    return part(s.idx) and not s.fallen
end

-- 时间提示：剩 60 / 30 / 10 秒各一次
local function timeWarn(remain)
    for _, w in ipairs({ 60, 30, 10 }) do
        if remain <= w and remain > w - 2 and not RULE.warned[w] then
            RULE.warned[w] = true
            if ctx.notice then ctx.notice(string.format("还剩 %d 秒", w), "", 1.5) end
        end
    end
end

-- 每次逻辑（30 次 / 秒）：自己的命；主机判结束
local function ruleTick(tn)
    if checkHostChange then checkHostChange(tn) end
    if DUEL and DUEL.isDuel() then
        DUEL.step(tn)
        return
    end
    local p1 = getP1()
    if RULE.st == "fight" and part(myPid()) and valid(p1) then
        local hp = G.hpOf(p1)
        if hp and RULE.lastHp and hp < RULE.lastHp - 0.01 then
            local dmg = RULE.lastHp - hp

            -- 场地增益：护体 §336 改成挨打前减伤（armorSet），这里不再事后退血

            -- §306 T1：谁打的 = 挨打方本机按"出招窗口"判定。候选只收：参战、没倒地、没出局、没藏、不是队友
            local myTm = (MP.teamsOn(RULE.teams) and RULE.teamOf and RULE.teamOf[myPid()]) or 0
            local p1Loc = loc(p1)
            local cands, candTxt = {}, {}
            for _, s in ipairs(NETP.list) do
                if part(s.idx) and not s.idle and valid(s.pup) and not s.fallen and (s.pst or 0) == 0 then
                    local sTm = (MP.teamsOn(RULE.teams) and RULE.teamOf and RULE.teamOf[s.idx]) or 0
                    if not MP.teamsOn(RULE.teams) or myTm == 0 or sTm ~= myTm then
                        local sl = loc(s.pup)
                        local m = ""
                        if G.montageOf then
                            local okm, mm = pcall(G.montageOf, s.pup)
                            if okm then m = mm or "" end
                        end
                        local c = { pid = s.idx, atkAt = s.atkAt, atkMontage = MP.isAtkMontage(m),
                                    hitMeAt = s.hitMeAt, aimMe = (s.tgtTag == "你"),
                                    dist = (p1Loc and sl) and d2(p1Loc, sl) or math.huge, valid = true }
                        cands[#cands + 1] = c
                        local win = (c.atkAt and tn - c.atkAt <= 1.2) or c.atkMontage
                        local rep = c.hitMeAt and tn - c.hitMeAt <= 1.0
                        candTxt[#candTxt + 1] = string.format("%d:%s/%s/%s/%.0f", c.pid,
                            win and "win" or "-", rep and "rep" or "-", c.aimMe and "aim" or "-", c.dist)
                    end
                end
            end
            local bestPid, hitMethod = MP.pickHitter(cands, tn, RULE.lastHitBy, RULE.lastHitAt)
            local candStr = #candTxt > 0 and table.concat(candTxt, " ") or "无"
            if bestPid then
                RULE.lastHitBy, RULE.lastHitAt, RULE.lastHitHow = bestPid, tn, hitMethod
                RULE.recentHits = RULE.recentHits or {}
                RULE.recentHits[#RULE.recentHits + 1] = { pid = bestPid, at = tn }
                out("多人对局：掉血 %.0f，打中者 %s（依据 %s；候选 %s）", dmg, nameOf(bestPid), tostring(hitMethod), candStr)
            else
                out("多人对局：掉血 %.0f，打中者 无（依据 无；候选 %s）", dmg, candStr)
            end

            -- 围攻保护（siege=1）
            if RULE.siege == 1 then
                local validHits = {}
                local distinctPids = {}
                for _, h in ipairs(RULE.recentHits or {}) do
                    if tn - h.at <= 2.0 then
                        validHits[#validHits + 1] = h
                        distinctPids[h.pid] = true
                    end
                end
                RULE.recentHits = validHits
                local distinctList = {}
                for p in pairs(distinctPids) do distinctList[#distinctList + 1] = p end

                if #distinctList >= 2 and not RULE.siegeActive and tn >= (RULE.siegeCdTill or 0) then
                    RULE.siegeActive = true
                    RULE.siegeTill = tn + 1.5
                    RULE.siegeCdTill = tn + 1.5 + 3.0

                    local lockTarget = lockTargetNow()
                    local keepPid = nil
                    if lockTarget then
                        for _, s in ipairs(NETP.list) do
                            if valid(s.pup) and G.sameObj(s.pup, lockTarget) then
                                keepPid = s.idx
                                break
                            end
                        end
                    end
                    if not keepPid then
                        keepPid = RULE.lastHitBy or bestPid
                    end
                    RULE.siegeKeepPid = keepPid

                    -- §306：阵营统一走 factionFor（出生保护 + 围攻保护一起算），别在这里直接写死
                    updatePuppetFactions()

                    local namesArr = {}
                    for _, p in ipairs(distinctList) do namesArr[#namesArr + 1] = nameOf(p) end
                    if ctx.notice then ctx.notice(T("围攻保护 1.5 秒", "SIEGE PROTECTION 1.5S"), "", 1.0) end
                    out("多人：围攻保护（%s 同时打我，保留 %s）", table.concat(namesArr, "、"), nameOf(keepPid))
                end
            end
        end
        RULE.lastHp = hp

        -- 倒地判定
        if RULE.my == 0 then
            if tn < RULE.invulnTill then
                local mx = G.attrOf(p1, "Health_Max")
                if hp and mx and hp < mx - 0.5 then G.refill(p1) end      -- 复活后 INVULN 秒打不掉血
            elseif hp and ctx.mpDead and ctx.mpDead(p1, hp, tn) then
                RULE.deaths = RULE.deaths + 1
                local killer = (RULE.lastHitAt and tn - RULE.lastHitAt <= 8.0) and (RULE.lastHitBy or 0) or 0
                RULE.killer = killer
                RULE.killerHow = (killer ~= 0) and (RULE.lastHitHow or "?") or nil

                if isHost() then
                    RULE.stats = RULE.stats or {}
                    local me = myPid()
                    RULE.stats[me] = RULE.stats[me] or { k = 0, d = 0 }
                    RULE.stats[me].d = RULE.deaths
                    if killer ~= 0 and killer ~= me and part(killer) then
                        local myTm = (MP.teamsOn(RULE.teams) and RULE.teamOf and RULE.teamOf[me]) or 0
                        local kTm = (MP.teamsOn(RULE.teams) and RULE.teamOf and RULE.teamOf[killer]) or 0
                        if not MP.teamsOn(RULE.teams) or myTm == 0 or myTm ~= kTm then
                            RULE.stats[killer] = RULE.stats[killer] or { k = 0, d = 0 }
                            RULE.stats[killer].k = (RULE.stats[killer].k or 0) + 1
                        end
                    end
                end

                if ctx.fallDown then ctx.fallDown(p1, "我") end

                if RULE.mode == "score" then
                    RULE.my, RULE.downAt = 1, tn
                    downLock(true, "我倒下了")
                    if ctx.notice then ctx.notice(T("你倒下了", "YOU DOWNED"), string.format(T("%d 秒后复活", "RESPAWNING IN %d S"), RULE.RESPAWN), RULE.RESPAWN) end
                    out("多人对局：我倒下了（积分赛，死了 %d 次，凶手 %s，依据 %s）", RULE.deaths, nameOf(killer), RULE.killerHow or "无")
                else
                    local left = RULE.lives - RULE.deaths
                    if left > 0 then
                        RULE.my, RULE.downAt = 1, tn
                        downLock(true, "我倒下了")
                        if ctx.notice then ctx.notice(T("你倒下了", "YOU DOWNED"), string.format(T("%d 秒后复活 · 还剩 %d 条命", "RESPAWNING IN %d S · %d LIVES LEFT"), RULE.RESPAWN, left), RULE.RESPAWN) end
                    else
                        RULE.my = 2
                        specStart()
                    end
                    out("多人对局：我倒下了（单局淘汰，死了 %d 次，剩 %d 条命，凶手 %s，依据 %s）", RULE.deaths, math.max(left, 0), nameOf(killer), RULE.killerHow or "无")
                end
            end
        elseif RULE.my == 1 and tn - (RULE.downAt or tn) >= RULE.RESPAWN then
            RULE.my, RULE.invulnTill = 0, tn + RULE.INVULN
            downLock(false, "复活")
            -- §306 T3：复活点 = 圆周 8 等分 + 我的开局点里，挑离最近的活着的敌人最远的一个；
            -- 没有场地（理论上不会）才退回原地附近，方向背离最近的敌人
            local was = loc(p1)
            local myTm2 = (MP.teamsOn(RULE.teams) and RULE.teamOf and RULE.teamOf[myPid()]) or 0
            local enemies = {}
            for _, s in ipairs(NETP.list) do
                if part(s.idx) and (s.pst or 0) ~= 2 and not s.idle and valid(s.pup) then
                    local sTm = (MP.teamsOn(RULE.teams) and RULE.teamOf and RULE.teamOf[s.idx]) or 0
                    if not MP.teamsOn(RULE.teams) or myTm2 == 0 or sTm ~= myTm2 then
                        local sl = loc(s.pup)
                        if sl then enemies[#enemies + 1] = sl end
                    end
                end
            end
            local target, yaw, how = nil, (G.yawOf and G.yawOf(p1) or 0), nil
            if RULE.arena then
                local cands = {}
                local cx, cy, cz = RULE.arena.cx, RULE.arena.cy, RULE.arena.cz
                local rad = RULE.arena.radius or 400.0
                local base = math.rad(RULE.arena.yaw or 0.0)
                for k = 0, 7 do
                    local ang = base + k * (2 * math.pi / 8)
                    local px, py = cx + rad * math.cos(ang), cy + rad * math.sin(ang)
                    local y = math.deg((math.atan2 or math.atan)(cy - py, cx - px))
                    cands[#cands + 1] = { X = px, Y = py, Z = cz, yaw = (y + 180) % 360 - 180 }
                end
                local ps = {}
                for pid in pairs(RULE.parts) do ps[#ps + 1] = pid end
                table.sort(ps)
                local plan = MP.spawnPlan(RULE.arena, ps, MP.teamsOn(RULE.teams) and RULE.teamOf or nil, MP.teamCount(RULE.teams))
                if plan[myPid()] then cands[#cands + 1] = plan[myPid()] end
                local picked, bestD = MP.pickRespawn(cands, enemies)
                target = picked
                if target then yaw = tonumber(target.yaw) or 0.0 end
                how = string.format("出生点（离最近敌人 %.0f）", tonumber(bestD) or 0)
            elseif was then
                local ang = math.random() * 2 * math.pi
                if #enemies > 0 then
                    local best, bestD
                    for _, e in ipairs(enemies) do
                        local d = math.sqrt((was.X - e.X) ^ 2 + (was.Y - e.Y) ^ 2)
                        if not best or d < bestD then best, bestD = e, d end
                    end
                    if best and bestD and bestD > 1.0 then
                        ang = (math.atan2 or math.atan)(was.Y - best.Y, was.X - best.X) + (math.random() - 0.5) * 0.6
                    end
                end
                local dist = 300.0 + math.random() * 300.0
                target = { X = was.X + math.cos(ang) * dist, Y = was.Y + math.sin(ang) * dist, Z = was.Z }
                how = "原地附近（背离最近敌人）"
            end
            if target then
                if ctx.safePlace then
                    local anchor = RULE.arena and { X = RULE.arena.cx, Y = RULE.arena.cy, Z = RULE.arena.cz + 20.0 } or was
                    local ok = ctx.safePlace(p1, target, anchor, yaw, "多人对局复活")
                    if ok then
                        local nowLoc = loc(p1) or target
                        out("多人对局：复活落点 %s（safePlace，X=%.1f Y=%.1f Z=%.1f）", how or "?", nowLoc.X, nowLoc.Y, nowLoc.Z)
                    else
                        out("多人对局：复活落点 %s（safePlace 无安全落点，原地站起）", how or "?")
                    end
                else
                    local hasF, fz = false, nil
                    if G.floorBelow then hasF, fz = G.floorBelow(p1, target, 800.0) end
                    if hasF and fz then target.Z = fz + 30.0 end
                    if G.teleportTo then G.teleportTo(p1, target, yaw) end
                    local nowLoc = loc(p1) or target
                    out("多人对局：复活落点 %s（兜底 floorBelow+teleportTo，X=%.1f Y=%.1f Z=%.1f）", how or "?", nowLoc.X, nowLoc.Y, nowLoc.Z)
                end
            end
            G.standUp(p1)
            G.refill(p1)
            RULE.protTill = tn + 3.0
            updatePuppetFactions()
            if ctx.rulesRespawn then ctx.rulesRespawn() end
            if ctx.notice then ctx.notice(T("复活", "RESPAWNED"), T("出生保护 3 秒（出手即结束）", "SPAWN PROTECTION 3S (ENDS ON ATTACK)"), 1.5) end
            out("多人对局：我复活了（死了 %d 次，出生保护 3 秒）", RULE.deaths)
        end
    end

    -- §306 T3：出生保护——我出攻击招或 3 秒到就结束；阵营恢复统一走 factionFor（和围攻保护一起算）
    if RULE.protTill then
        local outAtk = valid(p1) and G.montageOf and MP.isAtkMontage(G.montageOf(p1) or "") or false
        if tn >= RULE.protTill or outAtk then
            RULE.protTill = nil
            updatePuppetFactions()
            out("多人对局：出生保护结束（%s）", outAtk and "我先出手" or "3 秒到")
        end
    end

    if RULE.siegeActive and tn >= (RULE.siegeTill or 0) then
        RULE.siegeActive = false
        updatePuppetFactions()
        out("多人：围攻保护结束，恢复阵营")
    end

    if RULE.hasteTill and tn >= RULE.hasteTill then
        restoreSpeed()
    end
    if RULE.armorOrig and (not RULE.armorTill or tn >= RULE.armorTill) then armorSet(false) end
    if RULE.hasteProbeAt and tn >= RULE.hasteProbeAt then
        RULE.hasteProbeAt = nil
        local p1 = getP1()
        local cm = valid(p1) and rawProp(p1, "CharacterMovement")
        local v = valid(cm) and rawProp(cm, "Velocity")
        local sp = v and math.sqrt((tonumber(v.X) or 0) ^ 2 + (tonumber(v.Y) or 0) ^ 2) or nil
        out("多人：疾行 1 秒后 MaxWalkSpeed %s，实际水平速度 %s（原上限 %.0f）", tostring(valid(cm) and rawProp(cm, "MaxWalkSpeed")),
            sp and string.format("%.0f", sp) or "?", RULE.origSpeed or 0)
    end

    if inMatch() and RULE.st == "fight" and part(myPid()) and RULE.buffsOnField and #RULE.buffsOnField > 0 then
        if tn - (RULE.lastPickAt or 0) >= 0.2 then
            RULE.lastPickAt = tn
            local l = valid(p1) and loc(p1)
            if l then
                for _, b in ipairs(RULE.buffsOnField) do
                    local d = math.sqrt((l.X - b.x) ^ 2 + (l.Y - b.y) ^ 2 + ((l.Z or 0) - b.z) ^ 2)
                    if d <= 200.0 then
                        if isHost() then
                            hostTakeBuff(b.id, myPid(), tn)     -- §318 以前写死 1：换过房主后新房主捡的记到别人头上
                        else
                            if RULE.pickId ~= b.id then
                                RULE.pickId = b.id
                                RULE.pickTill = tn + 3.0
                            end
                        end
                        break
                    end
                end
            end
        end
    end

    if RULE.st == "fight" then
        local remain = isHost() and (RULE.tl - (tn - RULE.at)) or RULE.remain
        timeWarn(remain)
    end

    -- §306 T4：交手中离场地中心太远（半径 ×5，至少 30 米）→ 提示 5 秒后拉回；回到范围就取消；
    -- 到点用 safePlace 放回我的开局点。只在逻辑 tick 里每 0.5 秒看一次自己的位置，不扫别人。
    if RULE.st == "fight" and part(myPid()) and RULE.arena and valid(p1)
        and (tn - (RULE.leashAt or 0) >= 0.5 or (RULE.leashTill and tn >= RULE.leashTill)) then
        RULE.leashAt = tn
        local l = loc(p1)
        if l then
            local dx = l.X - RULE.arena.cx
            local dy = l.Y - RULE.arena.cy
            local limit = math.max((tonumber(RULE.arena.radius) or 400.0) * 5, MP.LEASH)
            if math.sqrt(dx * dx + dy * dy) > limit then
                if not RULE.leashTill then
                    RULE.leashTill = tn + 5.0
                    if ctx.notice then ctx.notice(T("离战场太远，5 秒后拉回", "TOO FAR FROM THE ARENA, PULLED BACK IN 5S"), "", 2.0) end
                    out("多人对局：离战场太远（%.0f > %.0f），5 秒后拉回", math.sqrt(dx * dx + dy * dy), limit)
                elseif tn >= RULE.leashTill then
                    local ps = {}
                    for pid in pairs(RULE.parts) do ps[#ps + 1] = pid end
                    table.sort(ps)
                    local plan = MP.spawnPlan(RULE.arena, ps, MP.teamsOn(RULE.teams) and RULE.teamOf or nil, MP.teamCount(RULE.teams))
                    local spawn = plan[myPid()] or
                        { X = RULE.arena.cx, Y = RULE.arena.cy, Z = RULE.arena.cz, yaw = RULE.arena.yaw or 0.0 }
                    local yaw = tonumber(spawn.yaw) or 0.0
                    if ctx.safePlace then
                        local anchor = { X = RULE.arena.cx, Y = RULE.arena.cy, Z = RULE.arena.cz + 20.0 }
                        ctx.safePlace(p1, { X = spawn.X, Y = spawn.Y, Z = spawn.Z }, anchor, yaw, "多人对局拉回战场")
                    end
                    if ctx.setYaw then ctx.setYaw(p1, yaw) end
                    if ctx.setControlRotation then ctx.setControlRotation(-10.0, yaw, 0.0) end
                    out("多人对局：离战场太远，已拉回开局点（X=%.1f Y=%.1f）", spawn.X, spawn.Y)
                    RULE.leashTill = nil
                    RULE.leashAt = tn + 0.5       -- 这一拍只拉一次，下一拍再看
                end
            elseif RULE.leashTill then
                RULE.leashTill = nil
                out("多人对局：回到战场范围，取消拉回")
            end
        end
    end

    if not isHost() then return end
    local dt = tn - RULE.at

    if RULE.st == "fight" and (RULE.buffs == 1) then
        if tn >= (RULE.nextBuffAt or 0) then
            RULE.nextBuffAt = tn + 20.0
            RULE.buffsOnField = RULE.buffsOnField or {}
            local kept = {}
            for _, b in ipairs(RULE.buffsOnField) do
                if not b.dieAt then b.dieAt = tn + 30.0 end     -- §312 客机解析来的没有 dieAt（接任 / 迟到的旧房主包）
                if tn < b.dieAt then kept[#kept + 1] = b end
            end
            RULE.buffsOnField = kept

            if #RULE.buffsOnField < 3 then
                local xs, ys, zs, cnt = 0, 0, 0, 0
                if part(myPid()) and RULE.my ~= 2 then
                    local l = valid(p1) and loc(p1)
                    if l then xs, ys, zs, cnt = xs + l.X, ys + l.Y, zs + l.Z, cnt + 1 end
                end
                for _, s in ipairs(NETP.list) do
                    if part(s.idx) and not s.idle and valid(s.pup) and s.pst ~= 2 then
                        local l = loc(s.pup)
                        if l then xs, ys, zs, cnt = xs + l.X, ys + l.Y, zs + l.Z, cnt + 1 end
                    end
                end
                if cnt > 0 then
                    local cx, cy, cz = xs / cnt, ys / cnt, zs / cnt
                    local spawned = false
                    for _ = 1, 5 do
                        local ang = math.random() * 2 * math.pi
                        local r = 500.0 + math.random() * 700.0
                        local tx, ty = cx + math.cos(ang) * r, cy + math.sin(ang) * r
                        local hasFloor, fz = nil, nil
                        if G.floorBelow then
                            hasFloor, fz = G.floorBelow(p1, { X = tx, Y = ty, Z = cz }, 800.0)
                        end
                        if hasFloor ~= false then
                            local bz = (hasFloor == true and fz) and fz or cz
                            RULE.buffGen = (RULE.buffGen or 0) + 1
                            local kinds = { "heal", "shachi", "armor", "haste" }
                            local kind = kinds[math.random(#kinds)]
                            RULE.knownBuffKinds = RULE.knownBuffKinds or {}
                            RULE.knownBuffKinds[RULE.buffGen] = kind
                            RULE.buffsOnField[#RULE.buffsOnField + 1] = {
                                id = RULE.buffGen,
                                x = tx,
                                y = ty,
                                z = bz,
                                kind = kind,
                                dieAt = tn + 30.0,
                            }
                            spawned = true
                            break
                        end
                    end
                    if spawned then
                        updateBuffFx(RULE.buffsOnField)
                    end
                end
            end
        else
            local kept, changed = {}, false
            for _, b in ipairs(RULE.buffsOnField or {}) do
                if not b.dieAt then b.dieAt = tn + 30.0 end     -- §312
                if tn < b.dieAt then kept[#kept + 1] = b else changed = true end
            end
            if changed then
                RULE.buffsOnField = kept
                updateBuffFx(RULE.buffsOnField)
            end
        end
    end

    if RULE.st == "cd" and dt >= RULE.CD then
        enter("fight", tn)
    elseif RULE.st == "fight" then
        if RULE.aiState then
            for apid, ast in pairs(RULE.aiState) do
                if part(apid) and ast.st == "down" and ast.respawnAt and tn >= ast.respawnAt then
                    local enemies = {}
                    local aiTm = (MP.teamsOn(RULE.teams) and RULE.teamOf and RULE.teamOf[apid]) or 0
                    if part(myPid()) and myPid() ~= apid and RULE.my ~= 2 and valid(p1) then
                        local myTm = (MP.teamsOn(RULE.teams) and RULE.teamOf and RULE.teamOf[myPid()]) or 0
                        if not MP.teamsOn(RULE.teams) or aiTm == 0 or myTm ~= aiTm then
                            local ml = loc(p1)
                            if ml then enemies[#enemies + 1] = ml end
                        end
                    end
                    for _, s in ipairs(NETP.list) do
                        if s.idx ~= apid and part(s.idx) and (s.pst or 0) ~= 2 and not s.idle and valid(s.pup) then
                            local sTm = (MP.teamsOn(RULE.teams) and RULE.teamOf and RULE.teamOf[s.idx]) or 0
                            if not MP.teamsOn(RULE.teams) or aiTm == 0 or sTm ~= aiTm then
                                local sl = loc(s.pup)
                                if sl then enemies[#enemies + 1] = sl end
                            end
                        end
                    end
                    local target = { X = ast.x, Y = ast.y, Z = ast.z, yaw = ast.yaw }
                    if RULE.arena then
                        local cands = {}
                        local cx, cy, cz = RULE.arena.cx, RULE.arena.cy, RULE.arena.cz
                        local rad = RULE.arena.radius or 400.0
                        local base = math.rad(RULE.arena.yaw or 0.0)
                        for k = 0, 7 do
                            local ang = base + k * (2 * math.pi / 8)
                            local px, py = cx + rad * math.cos(ang), cy + rad * math.sin(ang)
                            local y = math.deg((math.atan2 or math.atan)(cy - py, cx - px))
                            cands[#cands + 1] = { X = px, Y = py, Z = cz, yaw = (y + 180) % 360 - 180 }
                        end
                        local ps = {}
                        for p in pairs(RULE.parts) do ps[#ps + 1] = p end
                        table.sort(ps)
                        local plan = MP.spawnPlan(RULE.arena, ps, MP.teamsOn(RULE.teams) and RULE.teamOf or nil, MP.teamCount(RULE.teams))
                        if plan[apid] then cands[#cands + 1] = plan[apid] end
                        local picked = MP.pickRespawn(cands, enemies)
                        if picked then target = picked end
                    end
                    local pt = aiSpotFromPlan(target, ast)
                    RULE.aiGen = (RULE.aiGen or 0) + 1
                    ast.st, ast.gen, ast.respawnAt = "fight", RULE.aiGen, nil
                    ast.x, ast.y, ast.z, ast.yaw = pt.X, pt.Y, pt.Z, pt.yaw
                    if NETP.side[apid] then NETP.side[apid].aiTrackedHp = nil end
                end
            end
        end
        local alive = {}
        for pid in pairs(RULE.parts) do
            local out_
            if pid == myPid() then out_ = RULE.my == 2
            else
                local s = NETP.side[pid]
                out_ = not s or tn - (s.lastAt or 0) >= RULE.LOST or s.pst == 2
            end
            if out_ then
                local seen = false
                for _, x in ipairs(RULE.outOrder) do if x == pid then seen = true end end
                if not seen then RULE.outOrder[#RULE.outOrder + 1] = pid end
            else
                alive[#alive + 1] = pid
            end
        end

        local shouldEnd = false
        if dt >= RULE.tl then
            shouldEnd = true
        elseif RULE.mode == "elim" then
            if MP.teamsOn(RULE.teams) then
                -- §317 还有人活着的队只剩一个（或一个都没有）就结束
                local liveT, nLive = {}, 0
                for _, pid in ipairs(alive) do
                    local tm = (RULE.teamOf and RULE.teamOf[pid]) or 1
                    if not liveT[tm] then liveT[tm] = true; nLive = nLive + 1 end
                end
                if nLive <= 1 then
                    shouldEnd = true
                end
            else
                if #alive <= 1 then
                    shouldEnd = true
                end
            end
        end

        if shouldEnd then
            local rank = {}
            if RULE.mode == "score" then
                if MP.teamsOn(RULE.teams) then
                    -- §317 按队数通用：队净胜分之和高的排前，一样按平均血量，再一样编号小的队在前（两队和原来一样）
                    local k = MP.teamCount(RULE.teams)
                    local sc, hpS, cnt, lists = {}, {}, {}, {}
                    for t = 1, k do sc[t], hpS[t], cnt[t], lists[t] = 0, 0, 0, {} end
                    for pid in pairs(RULE.parts) do
                        local tm = (RULE.teamOf and RULE.teamOf[pid]) or 1
                        if not sc[tm] then tm = 1 end
                        sc[tm] = sc[tm] + getScoreDiff(pid); hpS[tm] = hpS[tm] + getHpRatio(pid); cnt[tm] = cnt[tm] + 1
                        lists[tm][#lists[tm] + 1] = pid
                    end
                    local order = {}
                    for t = 1, k do order[t] = t end
                    table.sort(order, function(a, b)
                        if sc[a] ~= sc[b] then return sc[a] > sc[b] end
                        local ha = cnt[a] > 0 and hpS[a] / cnt[a] or 0
                        local hb = cnt[b] > 0 and hpS[b] / cnt[b] or 0
                        if ha ~= hb then return ha > hb end
                        return a < b
                    end)
                    RULE.winTeam = order[1]
                    RULE.teamScore = sc

                    for _, t in ipairs(order) do
                        table.sort(lists[t], function(a, b)
                            local sa, sb = getScoreDiff(a), getScoreDiff(b)
                            if sa ~= sb then return sa > sb end
                            return getHpRatio(a) > getHpRatio(b)
                        end)
                        for _, pid in ipairs(lists[t]) do rank[#rank + 1] = pid end
                    end
                else
                    local allParts = {}
                    for pid in pairs(RULE.parts) do allParts[#allParts + 1] = pid end
                    table.sort(allParts, function(a, b)
                        local sa, sb = getScoreDiff(a), getScoreDiff(b)
                        if sa ~= sb then return sa > sb end
                        return getHpRatio(a) > getHpRatio(b)
                    end)
                    rank = allParts
                end
            else
                if MP.teamsOn(RULE.teams) then
                    -- §317 按队数通用。队的排序：还有人活着的队在前（多个活着 = 时间到：按剩余命数之和、再按血量之和）；
                    -- 全灭的队按最后一个人出局的先后，后灭的在前。两队时和原来一样（只有两队都还活着 / 都灭了时才比命数血量）
                    local k = MP.teamCount(RULE.teams)
                    local aliveL, deadL, nAlive, lives, hp, lastOut = {}, {}, {}, {}, {}, {}
                    for t = 1, k do aliveL[t], deadL[t], nAlive[t], lives[t], hp[t], lastOut[t] = {}, {}, 0, 0, 0, 0 end
                    local function tmOf(pid)
                        local tm = (RULE.teamOf and RULE.teamOf[pid]) or 1
                        return aliveL[tm] and tm or 1
                    end
                    for _, pid in ipairs(alive) do
                        local tm = tmOf(pid)
                        aliveL[tm][#aliveL[tm] + 1] = pid
                        nAlive[tm] = nAlive[tm] + 1
                    end
                    for i = #RULE.outOrder, 1, -1 do
                        local pid = RULE.outOrder[i]
                        local tm = tmOf(pid)
                        deadL[tm][#deadL[tm] + 1] = pid
                        if lastOut[tm] == 0 then lastOut[tm] = i end
                    end
                    for pid in pairs(RULE.parts) do
                        local tm = tmOf(pid)
                        lives[tm] = lives[tm] + getLivesLeft(pid); hp[tm] = hp[tm] + getHpRatio(pid)
                    end
                    local nLiveTeams = 0
                    for t = 1, k do if nAlive[t] > 0 then nLiveTeams = nLiveTeams + 1 end end
                    local order = {}
                    for t = 1, k do order[t] = t end
                    table.sort(order, function(a, b)
                        local la, lb = nAlive[a] > 0, nAlive[b] > 0
                        if la ~= lb then return la end
                        if (la and nLiveTeams > 1) or nLiveTeams == 0 and k == 2 then
                            if lives[a] ~= lives[b] then return lives[a] > lives[b] end
                            if hp[a] ~= hp[b] then return hp[a] > hp[b] end
                            return a < b
                        end
                        if not la and lastOut[a] ~= lastOut[b] then return lastOut[a] > lastOut[b] end
                        return a < b
                    end)
                    RULE.winTeam = order[1]

                    -- §334 队内：活着的和出局的一起，按击杀 → 死得少 → 剩余血量排（以前活着的在前、按剩余命数）
                    for _, t in ipairs(order) do
                        local members = {}
                        for _, pid in ipairs(aliveL[t]) do members[#members + 1] = pid end
                        for _, pid in ipairs(deadL[t]) do members[#members + 1] = pid end
                        table.sort(members, eliminationBefore)
                        for _, pid in ipairs(members) do rank[#rank + 1] = pid end
                    end
                else
                    -- §334 各自为战：所有参加者按击杀 → 死得少 → 剩余血量排（以前活着的在前、出局的按后出局在前）
                    local all = {}
                    for _, pid in ipairs(alive) do all[#all + 1] = pid end
                    for i = #RULE.outOrder, 1, -1 do all[#all + 1] = RULE.outOrder[i] end
                    table.sort(all, eliminationBefore)
                    for _, pid in ipairs(all) do rank[#rank + 1] = pid end
                end
            end
            RULE.rank = rank
            if dt >= RULE.tl then out("多人对局：时间到（%d 秒）结算", RULE.tl) end
            enter("end", tn)
        end
    elseif RULE.st == "end" and dt >= RULE.ENDS then
        enter("idle", tn)
    end
end
MP.ruleTickP = ctx.prof and ctx.prof("·多人对局", ruleTick) or ruleTick

local function hostName(hPid)
    local s = ses()
    if s.mpl then
        for p, n in s.mpl:gmatch("(%d+):([^,]+)") do
            if tonumber(p) == hPid then return n end
        end
    end
    local side = NETP.side[hPid]
    if side and side.nick and side.nick ~= "" then return side.nick end
    if hPid == myPid() then return "你" end
    return "玩家" .. hPid
end

-- §306 T9：房间成员名单（所有人可见）。来源 = 联机程序给的 mpl + 房主 + 我；
-- NETP.side 只补昵称和"同图 / 别的图"状态，不再往名单里加人（走了的人替身还没收也不会再显示）。
function MP.members()
    local s = ses()
    local list, seen = {}, {}
    local function add(pid)
        pid = tonumber(pid)
        if not (pid and pid > 0) or seen[pid] then return end
        seen[pid] = true
        local side = NETP.side[pid]
        local nm = side and side.nick
        if not (nm and nm ~= "") then
            for idStr, n in (s.mpl or ""):gmatch("(%d+):([^,]*)") do
                if tonumber(idStr) == pid and n ~= "" then nm = n; break end
            end
        end
        local isAi = MP.isAiPid(pid)
        if not (nm and nm ~= "") then nm = pid == myPid() and "你" or (pid .. "号") end
        if isAi and nm:sub(1, 4) ~= "[AI]" then nm = "[AI] " .. nm end
        list[#list + 1] = { pid = pid, name = nm, isHost = (pid == hostPid()), isMe = (pid == myPid()), isAi = isAi,
                            state = (pid == myPid() or (side and not side.idle)) and "here" or "away" }
    end
    for idStr in (s.mpl or ""):gmatch("(%d+):") do add(idStr) end
    local _, aiList = MP.aiSet()
    for _, id in ipairs(aiList) do add(id) end
    add(hostPid())
    add(myPid())
    table.sort(list, function(a, b) return a.pid < b.pid end)
    return list
end

-- §306 T5：多人对局屏幕文字（对决照旧走 DUEL.hudRows）；§333 对局外也写一行"按 F1 开始"（以前 idle 不占屏）
local function mmss(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end
local function hudRemain(tn)
    if RULE.st == "cd" then
        return math.max(0, math.ceil(RULE.CD - (tn - (RULE.at or tn))))
    elseif RULE.st == "fight" then
        if isHost() then return math.max(0, math.floor(RULE.tl - (tn - (RULE.at or tn)))) end
        local rem = tonumber(RULE.remain) or 0
        local at = tonumber(RULE.remainAt) or tn
        return math.max(0, math.floor(rem - (tn - at)))
    end
    return 0
end
local function hudAlive()
    local alive, total = 0, 0
    for pid in pairs(RULE.parts) do
        total = total + 1
        local out_ = false
        if pid == myPid() then out_ = RULE.my == 2
        else
            local s = NETP.side[pid]
            out_ = (not s) or (s.pst or 0) == 2
        end
        if not out_ then alive = alive + 1 end
    end
    return alive, total
end
local function hudTeamAlive()
    local t = { [1] = 0, [2] = 0 }
    for pid in pairs(RULE.parts) do
        local out_ = false
        if pid == myPid() then out_ = RULE.my == 2
        else
            local s = NETP.side[pid]
            out_ = (not s) or (s.pst or 0) == 2
        end
        if not out_ then
            local tm = (RULE.teamOf and RULE.teamOf[pid]) or 1
            t[tm] = (t[tm] or 0) + 1
        end
    end
    return t
end
local function hudTeamScore()
    local t = { [1] = 0, [2] = 0 }
    for pid in pairs(RULE.parts) do
        local tm = (RULE.teamOf and RULE.teamOf[pid]) or 1
        local st = (RULE.stats and RULE.stats[pid]) or { k = 0, d = 0 }
        t[tm] = (t[tm] or 0) + ((st.k or 0) - (st.d or 0))
    end
    return t
end
local hudRowsBase
function MP.hudRows(tn)
    local rows = hudRowsBase(tn)
    -- §336 场地道具剩余秒数（以前只有捡到那一下的提示，看不出效果还在不在）
    tn = tn or now()
    if rows and RULE.st == "fight" then
        local parts = {}
        if RULE.hasteTill and tn < RULE.hasteTill then parts[#parts + 1] = string.format(T("疾行 剩 %d 秒", "HASTE %ds"), math.ceil(RULE.hasteTill - tn)) end
        if RULE.armorTill and tn < RULE.armorTill then parts[#parts + 1] = string.format(T("护体 剩 %d 秒（受伤减半）", "GUARD %ds (HALF DAMAGE)"), math.ceil(RULE.armorTill - tn)) end
        if #parts > 0 then
            table.insert(rows, 1, { c = table.concat(parts, "  ·  "), col = { R = 120, G = 220, B = 255, A = 255 }, size = 0.8, nolog = true, center = true })
        end
    end
    return rows
end
hudRowsBase = function(tn)
    if DUEL and DUEL.isDuel() then return DUEL.hudRows(tn) end
    if RULE.st == "idle" then
        -- §333 用户 11-15："按 F1 开始对局，不是应该在屏幕上播报么"：对局外也在屏幕上写怎么开（对决那边 DUEL.hudRows 本来就有）
        if not MP.inMp() then return nil end
        local c = MP.cfg
        local modeName = isHost() and (c.mode == "score" and T("积分赛", "SCORE ATTACK") or T("单局淘汰", "ELIMINATION")) or nil     -- 客机不知道房主选的玩法，不写
        local n = tonumber(ses().mpn) or 0
        local rows = {}
        rows[#rows + 1] = { c = string.format(T("多人房间 · %d 人", "MULTIPLAYER ROOM · %d"), n) .. (modeName and (" · " .. modeName) or ""),
                            col = { R = 255, G = 215, B = 90, A = 255 } }
        local how = isHost() and T("按 F1 开始多人对局（房里的人都参加）", "PRESS F1 TO START (EVERYONE IN THE ROOM PLAYS)")
                    or T("等待房主按 F1 开局（不用准备）", "WAITING FOR THE HOST TO PRESS F1 (NO READY CHECK)")
        rows[#rows + 1] = { c = how .. (MP.myWatch and T("  [只看不上场]", "  [WATCH ONLY]") or ""), col = { R = 240, G = 240, B = 240, A = 255 } }
        return rows
    end
    tn = tn or now()
    local colTitle = { R = 255, G = 215, B = 90, A = 255 }
    local colInfo  = { R = 240, G = 240, B = 240, A = 255 }
    local colMute  = { R = 170, G = 170, B = 170, A = 255 }
    local colMe    = { R = 120, G = 220, B = 120, A = 255 }
    local rows = {}
    local modeName = RULE.mode == "score" and T("积分赛", "SCORE ATTACK") or T("单局淘汰", "ELIMINATION")
    local rem = hudRemain(tn)
    local title
    if RULE.st == "cd" then
        title = string.format(T("%s · %d 秒后开打", "%s · STARTING IN %d S"), modeName, rem)
    elseif RULE.mode == "score" then
        title = string.format(T("%s · 剩 %s", "%s · %s LEFT"), modeName, mmss(rem))
    else
        local alive, total = hudAlive()
        title = string.format(T("%s · 剩 %s · 存活 %d/%d", "%s · %s LEFT · %d/%d ALIVE"), modeName, mmss(rem), alive, total)
    end
    rows[#rows + 1] = { c = title, col = colTitle, center = RULE.st == "cd" or nil }     -- §310 倒计时那行留在中间
    if MP.teamsOn(RULE.teams) then
        local t = (RULE.mode == "score") and hudTeamScore() or hudTeamAlive()
        local line
        if MP.teamCount(RULE.teams) == 3 then     -- §317
            line = string.format(T("1 队 %d · 2 队 %d · 3 队 %d", "TEAM 1 %d · TEAM 2 %d · TEAM 3 %d"), t[1] or 0, t[2] or 0, t[3] or 0)
        else
            line = string.format(T("1 队 %d : %d 2 队", "TEAM 1 %d : %d TEAM 2"), t[1] or 0, t[2] or 0)
        end
        rows[#rows + 1] = { c = line, col = colInfo, size = 0.85 }
    end
    -- 11-15 实测（结算画面右边的玩家行和中间的排名叠在一起）：打完时排名在中间的结算里列全，右边只留标题
    if RULE.st == "end" then return rows end
    local pids = {}
    for pid in pairs(RULE.parts) do pids[#pids + 1] = pid end
    local function pstOf(pid)
        if pid == myPid() then return RULE.my end
        local s = NETP.side[pid]
        if not s then return 2 end
        return s.pst or 0
    end
    local function livesOf(pid)
        if pid == myPid() then return RULE.lives - RULE.deaths end
        local s = NETP.side[pid]
        return RULE.lives - ((s and s.pdeaths) or 0)
    end
    table.sort(pids, function(a, b)
        local pa, pb = pstOf(a), pstOf(b)
        if RULE.mode == "score" then
            local da, db = getScoreDiff(a), getScoreDiff(b)
            if da ~= db then return da > db end
            return getHpRatio(a) > getHpRatio(b)
        end
        if pa ~= pb then return pa < pb end      -- 活着（0）→ 倒地（1）→ 出局（2）
        local la, lb = livesOf(a), livesOf(b)
        if la ~= lb then return la > lb end
        return a < b
    end)
    -- 实测（11-14）：交手中 6 行大字压在屏幕中间挡视线 → 交手中玩家行缩小、最多 4 行（我那行一定在），
    -- 倒计时 / 结束时列全（最多 6 行）
    local fighting = RULE.st == "fight"
    local maxRows, rowSize = fighting and 4 or 6, fighting and 0.7 or 0.85
    if #pids > maxRows then
        local mine = false
        for i = 1, maxRows do if pids[i] == myPid() then mine = true end end
        if not mine then
            for i = maxRows + 1, #pids do
                if pids[i] == myPid() then pids[maxRows] = pids[i] end
            end
        end
    end
    for i, pid in ipairs(pids) do
        if i > maxRows then break end
        local prefix = ""
        if MP.teamsOn(RULE.teams) and RULE.teamOf then
            prefix = string.format(T("[%d队] ", "[TEAM %d] "), RULE.teamOf[pid] or 1)
        end
        local txt
        if RULE.mode == "score" then
            local st = (RULE.stats and RULE.stats[pid]) or { k = 0, d = 0 }
            local diff = (st.k or 0) - (st.d or 0)
            txt = string.format(T("%s  杀 %d 死 %d  %s", "%s  K %d D %d  %s"), nameOf(pid), st.k or 0, st.d or 0,
                                diff >= 0 and ("+" .. diff) or tostring(diff))
        else
            local pst = pstOf(pid)
            if pst == 2 then
                txt = string.format(T("%s  出局", "%s  OUT"), nameOf(pid))
            elseif pst == 1 then
                txt = string.format(T("%s  倒地", "%s  DOWN"), nameOf(pid))
            else
                txt = string.format(T("%s  剩 %d 命", "%s  %d LIVES"), nameOf(pid), math.max(0, livesOf(pid)))
            end
        end
        rows[#rows + 1] = { c = prefix .. txt, col = (pid == myPid()) and colMe or colInfo, size = rowSize }
    end
    -- 11-15 房间放到 12 人：列不下的写一行"还有 N 人"（前 maxRows 行已经保证有我）
    if #pids > maxRows then
        rows[#rows + 1] = { c = string.format(T("……还有 %d 人", "... %d MORE"), #pids - maxRows), col = colInfo, size = 0.6 }
    end
    return rows
end

-- §309（11-14 实测）：成员名单挪到单独一页（多人 mod 用 ui.addPage 登记，返回首页）。原来直接列在房间面板里，
-- 房主面板 3 人以上就超过面板行数上限（17），"房间设置… / 系统设置…"被挤出去、鼠标键盘都点不到。
-- 没有页服务（测试 / 老布局）时面板里照旧直接列（MP.panel 调这个）
function MP.memberRows(items, T_)
    T_ = T_ or T
    if DUEL and DUEL.isDuel() and DUEL.queueRows then DUEL.queueRows(items, T_); return end     -- 11-15 对决：排队次序 / 战绩（以前列在房间面板里）
    local idle = (not inMatch()) and not (DUEL and DUEL.inMatch())
    -- §306 T6：两队开着、对局外时先算一次预分（房主指定 > 本人选择 > 自动补齐），面板预览和点行改队都用它
    local preview = nil
    local vk = MP.teamCount(MP.viewTeams())     -- §317 客机按房主的设置（mpo=）
    local function watching(m)       -- §318
        if m.isMe or m.pid == myPid() then return MP.myWatch end
        local ws = NETP.side[m.pid]
        return ws and ws.watch and true or false
    end
    if vk > 0 and idle and MP.cfg.mode ~= "duel" then
        local pids = {}
        for _, m in ipairs(MP.members()) do if not watching(m) then pids[#pids + 1] = m.pid end end
        preview = MP.assignTeams(pids, RULE.teamForce, RULE.teamWant, vk)
    end

    -- §306 T9：成员名单所有人可见；名单只认 mpl + 房主 + 我，NETP.side 只补昵称 / 同图状态
    for _, m in ipairs(MP.members()) do
        local bits = { string.format("%d号", m.pid), m.name }
        if m.isHost then bits[#bits + 1] = T_("[房主]", "[HOST]") end
        if m.isMe then bits[#bits + 1] = T_("（我）", "(ME)") end
        local line = table.concat(bits, " ")
        line = line .. "  " .. (m.state == "here" and T_("同图", "HERE") or T_("别的图", "ELSEWHERE"))
        -- 对局中：队伍 + 战绩 / 剩命
        if inMatch() and part(m.pid) then
            if MP.teamsOn(RULE.teams) and RULE.teamOf then
                line = line .. string.format(T_(" [%d队]", " [TEAM %d]"), RULE.teamOf[m.pid] or 1)
            end
            if RULE.mode == "score" then
                local st = (RULE.stats and RULE.stats[m.pid]) or { k = 0, d = 0 }
                line = line .. string.format(T_("  杀 %d 死 %d", "  K %d D %d"), st.k or 0, st.d or 0)
            else
                local pst, left
                if m.pid == myPid() then
                    pst, left = RULE.my, RULE.lives - RULE.deaths
                else
                    local ps = NETP.side[m.pid]
                    pst, left = (ps and (ps.pst or 0)) or 2, RULE.lives - ((ps and ps.pdeaths) or 0)
                end
                if pst == 2 then line = line .. T_("  出局", "  OUT")
                elseif pst == 1 then line = line .. T_("  倒地", "  DOWN")
                else line = line .. string.format(T_("  剩 %d 命", "  %d LIVES"), math.max(0, left)) end
            end
        elseif idle and MP.cfg.mode ~= "duel" and watching(m) then
            line = line .. "  " .. T_("只看不上场", "WATCH ONLY")
        elseif preview then
            local tm = preview[m.pid]
            local tname = tm and string.format(T_("%d 队", "TEAM %d"), tm) or T_("自动", "AUTO")
            line = line .. "  " .. string.format(T_("预分：%s", "PRE: %s"), tname)
        end
        local it = { label = "  " .. line }
        -- 房主点成员行 = 改他的队（自动 → 1 队 → 2 队，房主指定优先于本人选择）
        if isHost() and preview and preview[m.pid] then
            it.act = function()
                local cur = RULE.teamForce[m.pid] or 0
                if cur > vk then cur = 0 end
                local nxt = (cur + 1) % (vk + 1)
                if nxt == 0 then RULE.teamForce[m.pid] = nil else RULE.teamForce[m.pid] = nxt end      -- 原来 (nxt == 0) and nil or nxt 永远得 0
                out("多人对局：房主把 %s 分成 %s", m.name, nxt == 0 and "自动" or (nxt .. " 队"))
            end
        end
        -- 房主这边的规则指纹标记（客机看不到房主的指纹，不标）
        if isHost() and m.pid ~= myPid() then
            local stRfp = MP.rfpStatus(m.pid)
            if stRfp == "diff" then it.label = it.label .. "  " .. T_("规则不一致", "RULES MISMATCH")
            elseif stRfp == "none" then it.label = it.label .. "  " .. T_("没有规则指纹（旧版本）", "NO RULE FINGERPRINT (OLD VERSION)") end
        end
        items[#items + 1] = it
    end
    -- §306 T6：两队对局外，每个玩家都能选自己的队
    -- §318 只看不上场（对局外能改；对决有自己的那份）
    if MP.cfg.mode ~= "duel" and not (DUEL and DUEL.isDuel()) then
        items[#items + 1] = { label = string.format(T_("只看不上场：< %s >", "WATCH ONLY: < %s >"), MP.myWatch and T_("开", "ON") or T_("关", "OFF")),
                              act = idle and function()
                                  MP.myWatch = not MP.myWatch
                                  out("多人：只看不上场 %s", MP.myWatch and "开" or "关")
                              end or nil }
    end
    if vk > 0 and idle and MP.cfg.mode ~= "duel" and not MP.myWatch then
        local pick = tonumber(MP.myTeamPick) or 0
        if pick > vk then pick = 0; MP.myTeamPick = 0 end     -- 三队时选的 3 队，换回两队按自动
        local tname = pick > 0 and string.format(T_("%d 队", "TEAM %d"), pick) or T_("自动", "AUTO")
        items[#items + 1] = { label = string.format(T_("我的队伍：< %s >", "MY TEAM: < %s >"), tname),
                              act = function() MP.myTeamPick = ((tonumber(MP.myTeamPick) or 0) + 1) % (vk + 1) end }
    end
end

-- 房间面板里的成员入口：有成员页 → 一行"房间成员（N 人）…"；没有 → 直接列（MP.memberRows）
function MP.membersEntry(items, T_)
    T_ = T_ or T
    if MP.membersPage and MP.uiGo then
        local n = #MP.members()
        local pick = ""
        if MP.cfg.mode ~= "duel" and not inMatch() then     -- §318 成员页里有"只看不上场"
            pick = MP.teamsOn(MP.viewTeams()) and T_("、选队 / 观众", ", TEAMS / WATCH") or T_("、观众", ", WATCH")
        end
        items[#items + 1] = { label = string.format(T_("房间成员（%d 人%s）…", "ROOM MEMBERS (%d%s)..."), n, pick),
                              act = function() MP.uiGo(MP.membersPage) end }
    else
        MP.memberRows(items, T_)
    end
end

-- 11-15 用户："玩法相关的要不要合并一个分类里，跟房间、系统设置平级，现在太长了"：玩法 / 人数 / 命数 / 时限 / 分队 / 增益 / 围攻（对决：房间人数 / 轮换）
-- 挪到"玩法设置"页（mods/multi/init.lua 用 ui.addPage 登记 MP.rulesPage）。只有房主有入口；入口和"房间设置… / 系统设置…"并排（base.playBtns）
function MP.rulesRows(items, pT)
    local T_ = pT or T
    if not MP.inMp() then items[#items + 1] = { label = T_("（不在多人房间里）", "(NOT IN A MULTIPLAYER ROOM)") }; return end
    local isD = DUEL and DUEL.isDuel()
    local idle = (not inMatch()) and not (DUEL and DUEL.inMatch())
    -- 客机的 MP.cfg 是自己本地的 mp.txt，不是房主的（对局开始才收到房主的 RULE），所以客机不列（和以前一样）
    if not isHost() then items[#items + 1] = { label = T_("（玩法由房主设置）", "(THE HOST SETS THE GAME MODE)") }; return
    elseif not idle then items[#items + 1] = { label = T_("（对局中改不了，打完再改）", "(LOCKED DURING A MATCH)") } end
    local actIfIdle = function(fn) return idle and fn or nil end

    local modeName = MP.cfg.mode == "duel" and T_("1v1 对决（测试中）", "1V1 DUEL (BETA)")
                     or (MP.cfg.mode == "score" and T_("积分赛", "SCORE ATTACK") or T_("单局淘汰", "ELIMINATION"))
    items[#items + 1] = { label = string.format(T_("玩法：< %s >", "MODE: < %s >"), modeName),
                          act = actIfIdle(function() MP.stepMode() end) }     -- 11-15 房间人数跟着带过去

    -- §306 T7：房间人数在房间里改，并通知联机程序（C# 那边另外做）。11-15 三个玩法同一行同一个数，新版 1v1 写明几人上场几人观战
    -- §316 上限可以比现在的人数少：在的人不赶，走了的回不来（要等人数降到上限以下）——面板写明
    local nowN = MP.members and #MP.members() or 0
    local duelMode = MP.cfg.mode == "duel" or isD
    local sizeLbl = duelMode and string.format(T_("房间人数：< %d >（2 人上场，%d 人观战排队）", "ROOM SIZE: < %d > (2 FIGHT, %d WATCH / QUEUE)"), MP.cfg.size, MP.cfg.size - 2)
                    or string.format(T_("房间人数：< %d >", "ROOM SIZE: < %d >"), MP.cfg.size)
    if nowN > MP.cfg.size then
        sizeLbl = sizeLbl .. string.format(T_("（现在 %d 人，走了进不来）", " (%d IN ROOM, LEAVERS CAN'T REJOIN)"), nowN)
    end
    items[#items + 1] = { label = sizeLbl,
                          act = actIfIdle(function()
                              MP.cfgStep("size", MP.SIZES)
                              if ctx.cmd then ctx.cmd("mpsize", "n=" .. tostring(MP.cfg.size) .. "\n") end
                          end) }

    if duelMode then
        if DUEL then DUEL.panel(items, T_, "settings") end     -- 对决：轮换规则
        return
    end

    if MP.cfg.mode ~= "score" then
        items[#items + 1] = { label = string.format(T_("命数：< %d >", "LIVES: < %d >"), MP.cfg.lives),
                              act = actIfIdle(function() MP.cfgStep("lives", MP.LIVES) end) }
    end

    items[#items + 1] = { label = string.format(T_("时限：< %d 秒 >", "TIME LIMIT: < %d S >"), MP.cfg.tl),
                          act = actIfIdle(function() MP.cfgStep("tl", MP.TLS) end) }

    local tk = MP.teamCount(MP.cfg.teams)
    local teamName = (tk == 3 and T_("三队", "THREE TEAMS")) or (tk == 2 and T_("两队", "TWO TEAMS")) or T_("各自为战", "FREE FOR ALL")
    items[#items + 1] = { label = string.format(T_("分队：< %s >", "TEAMS: < %s >"), teamName),
                          act = actIfIdle(function() MP.cfgStep("teams", MP.TEAMS) end) }

    local buffName = MP.cfg.buffs == 1 and T_("开", "ON") or T_("关", "OFF")
    items[#items + 1] = { label = string.format(T_("场地增益：< %s >", "FIELD BUFFS: < %s >"), buffName),
                          act = actIfIdle(function() MP.cfgStep("buffs", MP.BUFFS) end) }

    local siegeName = MP.cfg.siege == 1 and T_("开", "ON") or T_("关", "OFF")
    items[#items + 1] = { label = string.format(T_("围攻保护：< %s >", "SIEGE PROTECTION: < %s >"), siegeName),
                          act = actIfIdle(function() MP.cfgStep("siege", MP.SIEGES) end) }

    if hasLocalAi() then
        local aiCap = math.max(0, (MP.cfg.size or 4) - 1)
        items[#items + 1] = { label = string.format(T_("AI 数量：< %d >", "AI BOTS: < %d >"), math.min(tonumber(MP.cfg.ai) or 0, aiCap)),
                              act = actIfIdle(function() MP.stepAi() end) }
        local aiLv = (ctx.aiLevel and tonumber(ctx.aiLevel())) or 1
        local lvName = ({ [0] = T_("简单", "EASY"), [1] = T_("普通", "NORMAL"), [2] = T_("困难", "HARD"),
                          [3] = T_("普通（木桩只在 1v1）", "NORMAL (DUMMY IS 1V1 ONLY)") })[aiLv] or "?"     -- §342 多人房的 AI 选到木桩按普通
        items[#items + 1] = { label = string.format(T_("AI 难度：< %s >", "AI LEVEL: < %s >"), lvName),
                              act = actIfIdle(function()
                                  if ctx.cmd then ctx.cmd("ailevel", "level=" .. tostring((aiLv + 1) % 3) .. "\n") end
                              end) }
    end

end

-- 入口一行：玩法设置…（单局淘汰 · 5 人 · 3 命 · 300 秒 · 两队）。没有页（ui 服务不在）就直接列
function MP.rulesEntry(items, pT)
    local T_ = pT or T
    if not (MP.inMp and MP.inMp() and isHost()) then return end     -- 只给房主（客机看不到房主的设置，见 MP.rulesRows）
    if not (MP.rulesPage and MP.uiGo) then MP.rulesRows(items, T_); return end
    local c = MP.cfg
    local sum
    if c.mode == "duel" or (DUEL and DUEL.isDuel()) then
        sum = T_("1v1 对决", "1V1 DUEL")
    else
        sum = (c.mode == "score" and T_("积分赛", "SCORE") or T_("单局淘汰", "ELIM")) .. " · " .. string.format(T_("%d 人", "%d P"), c.size)
              .. (c.mode ~= "score" and (" · " .. string.format(T_("%d 命", "%d LIVES"), c.lives)) or "")
              .. " · " .. string.format(T_("%d 秒", "%d S"), c.tl)
              .. ((MP.teamCount(c.teams) == 3 and (" · " .. T_("三队", "3 TEAMS"))) or (MP.teamCount(c.teams) == 2 and (" · " .. T_("两队", "2 TEAMS"))) or "")
              .. ((hasLocalAi() and (tonumber(c.ai) or 0) > 0) and string.format(" · %d AI", c.ai) or "")
    end
    items[#items + 1] = { label = string.format(T_("玩法设置…（%s）", "GAME MODE... (%s)"), sum), act = function() MP.uiGo(MP.rulesPage) end }
end

-- 面板（main.lua 连着时那一页调）：多人房间的状态、主机的设置和开始按钮
function MP.panel(items, pT)
    local T_ = pT or T
    if not MP.inMp() then return end
    local s = ses()
    local isD = DUEL and DUEL.isDuel()
    local idle = (not inMatch()) and not (DUEL and DUEL.inMatch())
    local stTxt = ""
    if isD and DUEL.state ~= "idle" then
        stTxt = "  · " .. DUEL.state
    elseif inMatch() then
        stTxt = "  · " .. (ST_NAME[RULE.st] or RULE.st)
    end
    items[#items + 1] = { label = string.format(T_("多人房间：我是 %s 号，房间 %s 人%s", "MULTIPLAYER: I AM #%s, %s IN ROOM%s"),
        tostring(s.mpid), tostring(s.mpn), stTxt) }
    -- §309：房是我开的、我也是对局主机时不再列"对局主机：你"（标题行已经写了房主地址），给面板行数留余量；
    -- 服务器房里当对局主机的玩家照旧显示（标题行看不出来）
    if s.mphost ~= nil and s.mphost ~= "" and not (isHost() and s.role == "host") then
        local hp = hostPid()
        -- §286 只在局域网地址时显示（给同网的人填）；公网地址不上屏
        local a = s.mphostaddr or ""
        local lan = a:match("^192%.168%.") or a:match("^10%.") or a:match("^172%.1[6-9]%.") or a:match("^172%.2%d%.")
            or a:match("^172%.3[01]%.") or a:match("^127%.")
        local extraAddr = lan and (" " .. a) or ""
        items[#items + 1] = { label = string.format(T_("对局主机：%s（%d号%s）", "MATCH HOST: %s (#%d%s)"), hostName(hp), hp, extraAddr) }
    end

    -- §306 T4：对局外的客机，房主替身在同一张图且离我 30 米以上 → 一键传送到房主身边
    local function addTeleport()
        if isHost() or inMatch() or (DUEL and DUEL.inMatch()) then return end
        local hs = NETP.side[hostPid()]
        if not (hs and valid(hs.pup) and not hs.idle) then return end
        local hm = hs.last and hs.last.map
        if hm and hm ~= "" and NETP.myMap and hm ~= NETP.myMap then return end
        local p1, hl = getP1(), loc(hs.pup)
        if not (valid(p1) and hl) then return end
        local l = loc(p1)
        if not l or d2(l, hl) <= 3000.0 then return end
        local yaw = G.yawOf and G.yawOf(hs.pup) or 0
        local ang = math.rad(yaw) - math.pi / 2     -- 房主右手边 1.5 米
        local target = { X = hl.X + math.cos(ang) * 150.0, Y = hl.Y + math.sin(ang) * 150.0, Z = hl.Z }
        items[#items + 1] = { label = T_("传送到房主身边", "TELEPORT TO HOST"), act = function()
            local me = getP1()
            if valid(me) and ctx.safePlace then
                ctx.safePlace(me, target, hl, yaw, "多人传送到房主身边")
                out("多人：传送到房主身边")
            end
        end }
    end

    if not isHost() then
        -- §316 写明：多人对局不用每人准备 / 同意，房主按 F1 就开，当时在房里的人都参加（对决另有叫号准备，DUEL.panel 自己写）
        if not isD and idle then
            items[#items + 1] = { label = T_("开局：房主按 F1 直接开，房里的人都参加，不用准备", "START: HOST PRESSES F1, EVERYONE IN THE ROOM PLAYS, NO READY CHECK") }
            items[#items + 1] = { label = string.format(T_("只看不上场：< %s >", "WATCH ONLY: < %s >"), MP.myWatch and T_("开", "ON") or T_("关", "OFF")),
                                  act = function()      -- §318
                                      MP.myWatch = not MP.myWatch
                                      out("多人：只看不上场 %s", MP.myWatch and "开" or "关")
                                  end }
        end
        if not isD then MP.membersEntry(items, T_) end
        addTeleport()
        if isD and DUEL then DUEL.panel(items, T_, "room", MP.membersEntry) end     -- 11-15 排队名单在成员页，对决面板里给入口
        return
    end
    -- §333 用户 11-15："玩法设置应该放在成员上面"：房主的玩法设置…放在房间成员前；后面 base.playBtns 那次就不再加
    MP.rulesEntry(items, T_)
    MP._rulesInPanel = true
    if isD then
        if DUEL then DUEL.panel(items, T_, "room", MP.membersEntry) end
        return
    end
    MP.membersEntry(items, T_)

    items[#items + 1] = { label = inMatch() and RULE.st ~= "end" and T_("取消多人对局（F1）", "CANCEL THE MATCH (F1)") or T_("开始多人对局（F1，房里的人都参加）", "START THE MATCH (F1, EVERYONE IN THE ROOM PLAYS)"),
                          act = function() MP.f1() end }
end

MP._hostState, MP._peerDead, MP._movesCount, MP._rename = hostState, peerDead, movesCount, renameBars
MP.specStopX = specStop
MP.factionFor = factionFor
MP.hostTakeBuff = hostTakeBuff
MP.onBuffPicked = onBuffPicked
MP.restoreAll = restoreAll
MP.clearAllBuffFx = clearAllBuffFx
MP.updateBuffFx = updateBuffFx
MP.hostPid = hostPid
MP.isHost = isHost
MP.checkHostChange = checkHostChange
MP.hostName = hostName
MP.calcArenaSpawn = calcArenaSpawn
MP.fighting = function()
    if DUEL and DUEL.isDuel() then return DUEL.fighting() and DUEL.isFighter() end
    return RULE.st == "fight"
end
MP.inMatch = function() return inMatch() or (DUEL ~= nil and DUEL.inMatch()) end
MP.isDuel = function() return DUEL ~= nil and DUEL.isDuel() end
MP.onChat = function(rest) return DUEL ~= nil and DUEL.onChat(rest) or false end
-- §295 规则指纹用：我在不在打（多人 = 对局中且我参战；对决 = 我是选手且这一场在进行）、这一场的局号（房主定，各家一样）
MP.rfpCtx = function()
    if DUEL ~= nil and DUEL.isDuel() then
        local me = myPid()
        local st = DUEL.state
        local on = (me == DUEL.fa or me == DUEL.fb) and (st == "cd" or st == "fight" or st == "rend" or st == "end")
        return on and true or false, DUEL.mid
    end
    return (RULE.st ~= "idle" and part(myPid())) and true or false, RULE.mid
end
-- §307 D4：基础联机包（CDL.active / NET.resApply / 规则指纹）问对决的轻量快照；不在对决里 = nil
MP.duelInfo = function() return (DUEL and DUEL.info and DUEL.info()) or nil end
-- §307 D4：规则指纹 RFP.build 的 bo / tl 覆盖（fornet_match.lua 的 ctx.rfpOverride 或 BASEHOOK.mp.rfpOverride）
-- 对决 = 1v1 的局数 / 时限；多人（非对决）= bo=0、多人时限；不在多人房 = nil（照旧用 1v1 的 MATCH）
MP.rfpOverride = function()
    local d = MP.duelInfo()
    if d then return { bo = tonumber(d.bo) or 3, tl = tonumber(d.tl) or 0 } end
    if inMatch() or RULE.st ~= "idle" then return { bo = 0, tl = tonumber(RULE.tl or MP.cfg.tl) or 300 } end
    return nil
end

do
    local mpBase = {
        inMp = function() return MP.inMp() end,
        isHost = function() return isHost() end,
        myPid = function() return myPid() end,
        hostPid = function() return hostPid() end,
        nameOf = function(pid) return nameOf(pid) end,
        roster = function()
            -- §306 T9：和 MP.members() 同一份名单（mpl + 房主 + 我，不拿 NETP.side 补人）
            local list = {}
            for _, m in ipairs(MP.members()) do
                list[#list + 1] = { pid = m.pid, nm = m.name }
            end
            return list
        end,
        cfg = function() return MP.cfg end,
        stepCfg = function(k, list) MP.cfgStep(k, list) end,
        -- §295 观众上限 = 房间设置"观战 / 排队人数上限"（联机程序的 maxspec，lobby.txt 报回来；没有 = 默认 4）
        maxSpec = function() return (ctx.maxSpec and ctx.maxSpec()) or 4 end,
        notifyTag = function(st) notifyMpTag() end,
        cmd = function(c, body) if ctx.cmd then ctx.cmd(c, body) end end,
        relChat = function(payload) if ctx.relSend then ctx.relSend("chat", "@duel:" .. payload) end end,
        joinWatch = function() return ses().mpwatch == "1" end,     -- §324 这次是从"观战"进的房（联机程序 session.txt mpwatch=1）
        feedRules = function(tbl) if ctx.recvRules then ctx.recvRules(tbl) end end,
        hostRulesKv = function() return (ctx.hostRulesKv and ctx.hostRulesKv()) or "" end,
        rfpStatus = function(pid) return MP.rfpStatus(pid) end,
        myRfp = function() return MP.myRfp() end,
        sessionDuel = function()
            local s = ses()
            return {
                duel = s.duel == "1",
                fa = tonumber(s.duelfa) or 0,
                fb = tonumber(s.duelfb) or 0,
                live = s.duellive == "1",
                role = s.duelrole or "",
                cap = tonumber(s.duelcap) or 0,
                relay = tonumber(s.duelrelay) or 0,
            }
        end,
        getArena = function()
            local a = ctx.getArena and ctx.getArena() or nil
            if a and a.cx and a.cy and a.cz then
                return a.cx, a.cy, a.cz, tonumber(a.radius) or 400.0, tonumber(a.yaw) or 0.0, a.map
            end
            return nil
        end,
        -- §307 D1：我的位置 / 朝向 / 地图；房主没存场地时用它当场地（当前位置 + 朝向、半径 400）
        selfPos = function()
            local p1 = getP1()
            if not valid(p1) then return nil end
            local l = loc(p1)
            if not l then return nil end
            local yaw = (G.yawOf and G.yawOf(p1)) or 0.0
            local map = (G.mapName and G.mapName(p1)) or nil
            return l.X, l.Y, l.Z, tonumber(yaw) or 0.0, map
        end,
        mapName = function()
            local p1 = getP1()
            if not (valid(p1) and G.mapName) then return nil end
            return G.mapName(p1)
        end,
        -- §307 D1：他和我是不是同一张图（按 pbz_multi 的 s.idle / 有没有替身判断：
        -- 别的图的包在 MP.feed 里会被 netIdle，替身也不会生成；还没收到过他的包 = 不知道，按同图放行）
        sameMapAs = function(pid)
            pid = tonumber(pid) or 0
            if pid <= 0 or pid == myPid() then return true end
            local s = NETP.side[pid]
            if not s then return true end
            if s.idle then return false end
            return valid(s.pup) and true or false
        end,
        notice = function(zh, en, sec)
            if not ctx.notice then return end
            local txt = (en == nil or en == "") and zh or T(zh, en)
            ctx.notice(txt, "", sec or 3.0)
        end,
        -- §307 D2：自己装没装禁用武器 / 影之武装（返回中英文提示或 nil）
        wbanSelf = function()
            if not ctx.wbanSelf then return nil end
            return ctx.wbanSelf()
        end,
        -- §307 D2：房主复核（只查传进来的 parts；房主自己也会被查，和旧版 gateMulti 一致）
        wbanGateMulti = function(parts, skipSelf)
            if not ctx.wbanGateMulti then return true end
            return ctx.wbanGateMulti(parts, function(id) return NETP.side[id] end, nameOf, skipSelf)
        end,
        pcbOff = function(why) if ctx.pcbOff then ctx.pcbOff(why) end end,
        calcSpawn = function(idx, total, cx, cy, cz, r)
            local pos, yaw = calcArenaSpawn(cx, cy, cz, r, idx, total)
            return pos.X, pos.Y, yaw
        end,
        placeSelf = function(x, y, z, yaw, ax, ay, az)
            local p1 = getP1()
            if not valid(p1) then return end
            local target = { X = x, Y = y, Z = z }
            local anchor = { X = ax or x, Y = ay or y, Z = (az or z) + 20.0 }
            if ctx.safePlace then ctx.safePlace(p1, target, anchor, yaw, "1v1对决归位") end
            if ctx.setYaw then ctx.setYaw(p1, yaw) end
            if ctx.setControlRotation then ctx.setControlRotation(-10.0, yaw, 0.0) end
        end,
        arnLock = function() if ctx.arnLock then ctx.arnLock() end end,
        arnUnlock = function(why) if ctx.arnUnlock then ctx.arnUnlock(why) end end,
        selfHp = function()
            local p1 = getP1()
            if not valid(p1) then return nil, nil end
            return G.hpOf(p1), G.attrOf(p1, "Health_Max")
        end,
        deadHp = function() return ctx.deadHp or 1.0 end,
        isSelfDeadRegen = function(prevHp, tn)
            local p1 = getP1()
            local hp = valid(p1) and G.hpOf(p1) or nil
            if not (hp and ctx.mpDead) then return false end
            return ctx.mpDead(p1, hp, tn) == true
        end,
        peerPacket = function(pid)
            local s = NETP.side[pid]
            if not s then return nil end
            return { hp = s.duelHp, hpm = s.duelHpm, mpd = s.duelMpd, nm = s.nick }
        end,
        lockSelf = function()
            local p1 = getP1()
            if valid(p1) and not NETP.locked then NETP.locked = G.lockSelf(p1) end
        end,
        unlockSelf = function(why)
            local p1 = getP1()
            if valid(p1) and NETP.locked then G.unlockSelf(p1, why or "对决退出战斗"); NETP.locked = nil end
        end,
        refillSelf = function()
            local p1 = getP1()
            if valid(p1) then G.refill(p1) end
        end,
        fallSelf = function()
            local p1 = getP1()
            if valid(p1) and ctx.fallDown then ctx.fallDown(p1, "我") end
        end,
        standSelf = function()
            local p1 = getP1()
            if valid(p1) then G.standUp(p1) end
        end,
        fallPeer = function(pid)
            local s = NETP.side[pid]
            if s and valid(s.pup) and not s.fallen then
                s.fallen = true
                if ctx.fallDown then ctx.fallDown(s.pup, nameOf(pid)) end
            end
        end,
        standPeer = function(pid)
            local s = NETP.side[pid]
            if s and valid(s.pup) and s.fallen then
                s.fallen = false
                G.standUp(s.pup)
            end
        end,
        setPeerFaction = function(pid, isFoe)
            local s = NETP.side[pid]
            if s and valid(s.pup) then setFaction(s.pup, isFoe and FOE or FRIEND) end
        end,
        pruneNonFighters = function(fa, fb)
            for pid, s in pairs(NETP.side) do
                if pid ~= fa and pid ~= fb then netIdle(s, true) end
            end
        end,
        cdStart = function()
            local p1 = getP1()
            if valid(p1) and ctx.cdStart then ctx.cdStart(p1) end
        end,
        fightStart = function()
            local p1 = getP1()
            if valid(p1) and ctx.fightStart then ctx.fightStart(p1) end
        end,
        unshield = function()
            local p1 = getP1()
            if valid(p1) and ctx.unshield then ctx.unshield(p1) end
        end,
        rulesSnapshot = function() if ctx.rulesSnapshot then ctx.rulesSnapshot() end end,
        rulesBegin = function(phase, why, first, tn) if ctx.rulesBegin then ctx.rulesBegin(phase, why, first, tn) end end,
        rulesEnd = function(why) if ctx.rulesEnd then ctx.rulesEnd(why) end end,
        bestOf = function() return (ctx.bestOf and ctx.bestOf()) or 3 end,
        toWin = function(bo) return (ctx.toWin and ctx.toWin(bo)) or (math.floor((bo or 3) / 2) + 1) end,
        tlLimit = function() return (ctx.tlLimit and ctx.tlLimit()) or 0 end,
        rdyTimeout = function() return (ctx.rdyTimeout and ctx.rdyTimeout()) or 10 end,
        specStart = function(targets, tn) specStart() end,
        specStop = function(why) specStop() end,
        specNext = function() return MP.nextView() end,
        specTargetPid = function()
            if not SPEC.on then return nil end
            local list = specTargets()
            local s = list[SPEC.idx]
            return s and s.idx or nil
        end,
        onMatchStart = function(mid) if ctx.onMatchStart then ctx.onMatchStart(mid) end end,
        onMatchEnd = function(mid, why) if ctx.onMatchEnd then ctx.onMatchEnd(mid, why) end end,
        toast = function(zh, en) if ctx.notice then ctx.notice(T(zh, en), "", 2.5) end end,
    }
    MP.base = mpBase
    local mkDuel = ctx.loadDuel
    if not mkDuel then
        local okD, mD = pcall(require, "pbz_duel")
        if okD and type(mD) == "function" then mkDuel = mD end
    end
    if type(mkDuel) == "function" then
        local duelCtx = ctx
        if not ctx.now then
            duelCtx = setmetatable({ now = now or os.clock }, { __index = ctx })
        end
        DUEL = mkDuel(duelCtx, mpBase)
    end
    MP.duel = DUEL
end

-- L5（docs/FORNET_LAYERS.md）：挂到基础联机包发出的事件上，基础联机包不再按名字调多人。
-- opts：on / ask（订阅）、bind（绑键）、panelOpen（面板开着时不响应小键盘）
function MP.attach(opts)
    local on, ask = opts.on, opts.ask or opts.on
    on("base.feedMp", function(t, tn) MP.feed(t, tn) end)                        -- 多人房间的包（src = 玩家编号，主机 1）
    ask("base.wire", function(tn) return MP.wire(tn) end)                          -- ②d：mpd= / mpm=
    ask("base.chat", function(rest) return MP.onChat(rest) end)                   -- 对决控制消息先截走
    on("base.mpRows", function(items, pT) MP.panel(items, pT) end)               -- 状态 / 成员 / 开始
    on("base.playBtns", function(items, pT)          -- 11-15 玩法设置…（和房间设置… / 系统设置…并排）
        if MP._rulesInPanel then MP._rulesInPanel = false; return end     -- §333 房主面板里已经放在成员上面了
        MP.rulesEntry(items, pT)
    end)
    on("base.mapLoad", function() MP.onMapLoad() end)
    on("base.puppetContact", function(pup, tn) MP.noteContact(pup, tn) end)
    ask("base.f1", function() if MP.inMp and MP.inMp() then MP.f1(); return true end end)    -- 多人房里 F1 = 准备 / 开始
    pcall(MP.cfgLoad)
    if opts.bind and Key then
        local open = opts.panelOpen or function() return false end
        opts.bind(Key.DIVIDE, function() if not open() then MP.toggle() end end, "混战原型 开 / 关")
        opts.bind(Key.DECIMAL, function() if not open() then MP.nextMode() end end, "混战原型 换模式")
    end
end

-- 换世界：旧世界的替身都没了，只清 Lua 状态（同观战原型）
function MP.onMapLoad()
    lastHostPid = nil
    if DUEL then DUEL.onMapLoad() end
    if inMatch and inMatch() and enter then enter("idle", now(), "换地图") end
    if MP.on then MP.on = false; out("混战原型：换地图，结束") end
    if NETP.on then NETP.on = false; out("多人联机：换地图，替身作废，收到包会重新生成") end
    MP.side, MP.store, MP.locked = {}, {}, nil
    NETP.side, NETP.list, NETP.locked = {}, {}, nil
    if restoreSpeed then restoreSpeed() end
    if clearAllBuffFx then clearAllBuffFx() end
    if MP.rule then
        MP.rule.st, MP.rule.parts, MP.rule.my, MP.rule.deaths = "idle", {}, 0, 0
        MP.rule.siegeActive = false
        MP.rule.siegeTill, MP.rule.siegeCdTill = nil, nil
        MP.rule.protTill, MP.rule.leashTill = nil, nil
        MP.rule.recentHits = {}
        MP.rule.buffsOnField = {}
        MP.rule.pickId, MP.rule.pickTill = nil, nil
        MP.rule.koVictim, MP.rule.koTill = nil, nil
        MP.rule.lastPickedItem = nil
        MP.rule.touched = {}
        MP.rule.peerRfp = {}
        MP.rule.peerSeen = {}
        MP.rule.rfpWarned = {}
        MP.rule.mtd = {}
        MP.rule.aiState = {}
        MP.rule.aiAutoSynced = nil
    end
    if MP.specView then MP.specView.on, MP.specView.cam = false, nil end
end

return MP
end
