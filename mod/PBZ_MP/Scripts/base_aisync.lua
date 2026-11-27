-- base_aisync.lua —— §352 本地 AI / 木桩尽量按真人那套判（用户 11-16"让 ai 的机制尽量贴近真人，而不止是这一个招式"）
-- 真人对战：挨打那一方的身体（落空等多久、挨打被打断、冻住）由他自己的游戏说了算。本地 AI 没有游戏，它的"身体"就是
-- 我游戏里的替身。这里把替身 / 我这边游戏的实际状态报给联机程序里的 AI（只在对手是本地 AI / 假对手、不是观战时发）：
--   act=<招式号,...>  我还在放的攻击招（技能还挂在我身上，NET.prevAbs）。AI 等这招放完还没碰到才判落空
--                     （真人那边是替身还在播这一招就接着等，LAT.stillPlaying；以前 AI 固定 1.5 秒，紫冥剑大招 2–4 秒才打到 → §351）
--   pst=0/1           替身在我游戏里正在播受击 / 倒地 / 起身动作（LO.isHitMontage），或身上有控制类异常（BAL.CTRL 里的类型，冰冻）
--                     → AI 这段时间不出招、不喝药、不举架势，被打中也防不了（真人挨打硬直里一样动不了）
--   psq=<杀气>        §353 替身在我游戏里的实际杀气。联机程序回 sqp=1 时，交手中不再把替身杀气补满（main.lua 每 10 帧那段），
--                     挨打掉、放技能花、打中涨都是游戏自己算；打空了替身在我这边真的破防（不掐，pst=1 让 AI 停手）
--   tbrk=<招式号,...> / tbrkon=0/1  木桩用（用户 11-23"普通格挡开了就无敌"）：哪几招把替身打破防了（*Break* 动作，KEEP 秒内）、
--                     替身现在是不是在播破防动作。木桩"普通格挡（按住）"据此把破防那一刀和破防后的刀判中招，不再一律普防
-- 旧版联机程序不认这几个键 → 照旧。发包这一帧顺带算，不额外轮询：动作每帧本来就在读，异常标签每 EVERY 帧读一次。
return function(ctx)
local out, NET, ST, G = ctx.out, ctx.NET, ctx.ST, ctx.G
local A = { KEEP = 10.0, EVERY = 3, mine = {}, pst = "0", why = nil, LOG_MAX = 60, logs = 0, n = { busy = 0, brk = 0 }, psq = nil,
            BREAK = { "Break", "MoTian_Dodge" } }

-- Offline gasgraph attack_alert.csv: Players/Hun assets with alert == red.
-- Mixed red+blue assets are deliberately excluded: not every phase is red.
A.RED = {}
for asset in ([[GA_Hun_GuiTouBlade_BBB GA_Hun_GuiTouBlade_C GA_Hun_FengLeiJian_C
GA_Hun_BaiYing_C GA_Hun_BronzeSword_C GA_Hun_Chaos_C GA_Hun_ChiZheCanJian_C
GA_Hun_ChiZheCanJian_C_Zui GA_Hun_Double_C GA_Hun_YuuBlade_C GA_Hun_DualHook_C
GA_Hun_HeiMoShang_C1 GA_Hun_Horizontal_C GA_Hun_Iron_C GA_Hun_Jade_C_Range
GA_Hun_Double_JueYing_C GA_Hun_Double_JueYing_C_Air GA_Hun_Long_C GA_Hun_Jigsaw_C
GA_Hun_LuanYing_CA GA_Hun_LuanYing_P2_CA GA_Hun_PoJun_C GA_Hun_ShuangYue_C
GA_Hun_SlitheringSword_C GA_Hun_SnakeDual_C GA_Hun_Tang_C
GA_Hun_TempMaleThugClub_Ultimate GA_Hun_TempMaleThugTwinAxe_Ultimate
GA_Hun_WoodenSword_C GA_Hun_Young_C GA_Hun_XieShan_C GA_Hun_YanYueDao_C
GA_Hun_ZhanMa_C GA_Hun_ZiMingJian_New_C]]):gmatch("%S+") do A.RED[asset .. "_C"] = true end
function A.isRed(n)
    if type(n) ~= "string" then return false end
    if A.RED[n] then return true end
    -- GEx is an execution, not a red counter (HANDOVER 249 / PDX.NAMES).
    return n:match("^GA_Hun_.*PerfectDodge") ~= nil and not n:find("_GEx", 1, true)
end
function A.wireRed(tn)
    if type(G.trainingRedEpoch) == "function" and type(G.getP1) == "function" then
        local ok, epoch = pcall(function() return G.trainingRedEpoch(G.getP1()) end)
        if ok and type(epoch) == "number" and epoch >= 0 then
            if A.redEpoch ~= nil and epoch > 0 and epoch ~= A.redEpoch then A.redPending, A.redPendingAt = true, tn end
            A.redEpoch = epoch
        end
    end
    if A.redPendingAt and tn - A.redPendingAt > 0.5 then A.redPending = nil end
    if A.redPending then
        local newest
        for id, r in pairs(A.mine) do
            if tn - r.at <= A.KEEP and NET.prevAbs and NET.prevAbs[r.n] and (not newest or id > newest) then newest = id end
        end
        if newest then A.redIds = A.redIds or {}; A.redIds[newest] = true; A.redPending = nil end
    end
    local latest = {}
    for id, r in pairs(A.mine) do
        if tn - r.at <= A.KEEP and NET.prevAbs and NET.prevAbs[r.n] and (A.isRed(r.n) or (A.redIds and A.redIds[id]))
            and (not latest[r.n] or id > latest[r.n]) then latest[r.n] = id end
    end
    local ids = {}
    for _, id in pairs(latest) do ids[#ids + 1] = id end
    table.sort(ids)
    return table.concat(ids, ",")
end
-- §456 木桩：除了红光，别的不可防御招（用户 11-26"红光技、黑光技等不可防御的招式"）。L1 + 圈 / 三角的特殊技
-- （瞬杀 / 裂斩 / 影杀、杀气钩 C，资产里没有红蓝光提示，HANDOVER 9.3）和处决类。只发给联机程序判木桩格挡用（tunb=），不触发红光闪避
A.UNBLOCK_EXACT = { GA_Hun_ShachiHook_C_C = true }
function A.isUnblock(n)
    if type(n) ~= "string" or A.isRed(n) then return false end
    if A.UNBLOCK_EXACT[n] then return true end
    if n:match("^GA_GlobalActionAbilit[iy]e?s?_%a+_C") then return true end       -- GA_GlobalActionAbility_ShunSha_C_C / _CB_C、GA_GlobalActionAbilities_YingSha_C_C
    return n:find("Execution", 1, true) ~= nil or n:find("_GEx", 1, true) ~= nil
end
function A.wireUnb(tn)
    local latest = {}
    for id, r in pairs(A.mine) do
        if tn - r.at <= A.KEEP and A.isUnblock(r.n) and (not latest[r.n] or id > latest[r.n]) then latest[r.n] = id end
    end
    local ids = {}
    for _, id in pairs(latest) do ids[#ids + 1] = id end
    table.sort(ids)
    return table.concat(ids, ",")
end
function A.trainingBusy()
    if type(G.activeAbilities) ~= "function" then return false end
    local pup = G.puppet()
    if not G.valid(pup) then return false end
    local ok, active = pcall(G.activeAbilities, pup, ctx.isAttackAbility)
    if not ok or type(active) ~= "table" then return false end
    for name, on in pairs(active) do if on and ctx.isAttackAbility(name) then return true end end
    return false
end

function A.log(...)
    if A.logs < A.LOG_MAX then A.logs = A.logs + 1; out(...) end
end

-- 只在对手是本地 AI / 假对手（ai=1）、不在观战时发
function A.on()
    return NET.rai == true and not (PEER and PEER.on)
end

-- ULT.emit 调：记下我放的攻击招（招式号 → 名字、时间）
function A.noteFire(id, n, tn)
    if not (id and n and ctx.isAttackAbility(n)) then return end
    A.mine[id] = { n = n, at = tn }
end

-- act=：最近 KEEP 秒放的攻击招里，技能还挂在我身上的；同名的只算最新那一个（连按两次 A，旧的那个早放完了）
function A.wireAct(tn)
    local abs = NET.prevAbs
    local latest = {}
    for id, r in pairs(A.mine) do
        if tn - r.at > A.KEEP then
            A.mine[id] = nil
            if A.redIds then A.redIds[id] = nil end
        elseif abs and abs[r.n] and (not latest[r.n] or id > latest[r.n]) then latest[r.n] = id end
    end
    local ids = {}
    for _, id in pairs(latest) do ids[#ids + 1] = id end
    table.sort(ids)
    return table.concat(ids, ",")
end

-- §353 交手中、对手是本地 AI、联机程序说了 sqp=1、不是木桩：替身杀气按游戏自己的（不补满、破防照播）
function A.ownShachi()
    if not (A.on() and NET.rsqp) or NET.rtrainAiChi then return false end
    if NET.rdummy and (not NET.rtrainChi or NET.rtrainChi == "locked" or NET.rtrainAiChi) then return false end
    if NET.fighting then return NET.fighting() == true end
    return false
end

-- §353 替身在我这边破防了（suppressLocalReact 看到破防动作、没掐）
function A.noteBreak(name)
    if A.brkM == name then return end
    A.brkM = name
    A.n.brk = A.n.brk + 1
    A.log("§353 替身杀气打空、在你这边破防了（%s，第 %d 次）→ 照播，本地 AI 这段时间停手", tostring(name), A.n.brk)
end

-- 木桩：我第 id 招把替身打破防了（TOUCH.markBreak 调，只认 Break 动作，挣脱 MoTian_Dodge 不算）
function A.noteBreakId(id, tn)
    if type(id) ~= "number" or id <= 0 then return end
    A.brkIds = A.brkIds or {}
    A.brkIds[id] = tn
end

-- 替身这一帧是不是在播破防动作（不含挣脱）
function A.inBreak(pup)
    if not G.valid(pup) then return false end
    local m = LAT and LAT.activeMontage and select(3, LAT.activeMontage(pup)) or nil
    return type(m) == "string" and m:find("Break", 1, true) ~= nil and not m:find("BreakEscape", 1, true)
end

function A.wireBreak(tn)
    local ids = {}
    for id, at in pairs(A.brkIds or {}) do
        if tn - at > A.KEEP then A.brkIds[id] = nil else ids[#ids + 1] = id end
    end
    table.sort(ids)
    return "tbrk=" .. table.concat(ids, ",") .. "\ntbrkon=" .. (A.inBreak(G.puppet()) and "1" or "0") .. "\n"
end

-- 替身现在为什么动不了（nil = 能动）
function A.busyWhy(pup)
    if not (G.valid(pup)) then return nil end
    local m = LAT and LAT.activeMontage and select(3, LAT.activeMontage(pup)) or nil
    if m and LO and LO.isHitMontage(m) then return m end
    if m and A.ownShachi() then
        for _, k in ipairs(A.BREAK) do if m:find(k, 1, true) then return m end end      -- §353 破防 / 挣脱
    end
    if not m then A.brkM = nil end
    if INF and INF.levels and BAL and BAL.CTRL and next(BAL.CTRL) then
        local lv = INF.levels(pup)
        for ty in pairs(BAL.CTRL) do
            if (lv[ty] or 0) > 0 then return ty end
        end
    end
    return nil
end

function A.wirePst(tn)
    if ST.ticks % A.EVERY == 0 then
        local why = A.busyWhy(G.puppet())
        local v = why and "1" or "0"
        if v ~= A.pst then
            if v == "1" then A.n.busy = A.n.busy + 1 end
            A.log("§352 替身%s（%s）→ 本地 AI %s", why and "挨打 / 被控" or "能动了", tostring(why or A.why or "-"),
                why and "停手、这段时间防不了" or "接着打")
        end
        A.pst, A.why = v, why
    end
    return A.pst
end

-- 状态包里接在 tc= / td= 后面；对手不是本地 AI 时什么都不发（省流）
function A.wire(tn)
    if not A.on() then return "" end
    local s = "act=" .. A.wireAct(tn) .. "\npst=" .. A.wirePst(tn) .. "\n"
    if ST.ticks % A.EVERY == 0 or A.trainBusy == nil then A.trainBusy = A.trainingBusy() end
    s = s .. "tred=" .. A.wireRed(tn) .. "\ntrainBusy=" .. (A.trainBusy and "1" or "0") .. "\n"
    if NET.rdummy then s = s .. A.wireBreak(tn) .. "tunb=" .. A.wireUnb(tn) .. "\n" end     -- §456
    -- §456 木桩站在原地时（不归位，或已过第 1 回合倒计时那次归位）报替身实际位置；ctx.dummyStay 由 main.lua 给（TRAINCTX.stay）
    local stay
    if ctx.dummyStay then stay = ctx.dummyStay() else stay = NET.rtrainReturn == false end
    if NET.rdummy and stay and type(G.trainingPosition) == "function" then
        local ok, pos = pcall(G.trainingPosition, G.puppet())
        if ok and type(pos) == "string" then s = s .. "trainPos=" .. pos .. "\n" end
    end
    if ST.ticks % A.EVERY == 0 or A.psq == nil then
        local v = ctx.attrOf and ctx.attrOf(G.puppet(), "Shachi")
        A.psq = type(v) == "number" and v or A.psq
    end
    if A.psq then s = s .. string.format("psq=%.0f\n", A.psq) end          -- §353
    return s
end

-- 换对手 / 对局结束时清掉
function A.reset()
    A.mine, A.pst, A.why, A.psq, A.brkM = {}, "0", nil, nil, nil
    A.trainBusy = nil
    A.brkIds = nil
    A.redEpoch, A.redPending, A.redPendingAt, A.redIds = nil, nil, nil, nil
end

return A
end
