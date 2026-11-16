-- base_aisync.lua —— §352 本地 AI / 木桩尽量按真人那套判（用户 11-16"让 ai 的机制尽量贴近真人，而不止是这一个招式"）
-- 真人对战：挨打那一方的身体（落空等多久、挨打被打断、冻住）由他自己的游戏说了算。本地 AI 没有游戏，它的"身体"就是
-- 我游戏里的替身。这里把替身 / 我这边游戏的实际状态报给联机程序里的 AI（只在对手是本地 AI / 假对手、不是观战时发）：
--   act=<招式号,...>  我还在放的攻击招（技能还挂在我身上，NET.prevAbs）。AI 等这招放完还没碰到才判落空
--                     （真人那边是替身还在播这一招就接着等，LAT.stillPlaying；以前 AI 固定 1.5 秒，紫冥剑大招 2–4 秒才打到 → §351）
--   pst=0/1           替身在我游戏里正在播受击 / 倒地 / 起身动作（LO.isHitMontage），或身上有控制类异常（BAL.CTRL 里的类型，冰冻）
--                     → AI 这段时间不出招、不喝药、不举架势，被打中也防不了（真人挨打硬直里一样动不了）
--   psq=<杀气>        §353 替身在我游戏里的实际杀气。联机程序回 sqp=1 时，交手中不再把替身杀气补满（main.lua 每 10 帧那段），
--                     挨打掉、放技能花、打中涨都是游戏自己算；打空了替身在我这边真的破防（不掐，pst=1 让 AI 停手）
-- 旧版联机程序不认这几个键 → 照旧。发包这一帧顺带算，不额外轮询：动作每帧本来就在读，异常标签每 EVERY 帧读一次。
return function(ctx)
local out, NET, ST, G = ctx.out, ctx.NET, ctx.ST, ctx.G
local A = { KEEP = 10.0, EVERY = 3, mine = {}, pst = "0", why = nil, LOG_MAX = 60, logs = 0, n = { busy = 0, brk = 0 }, psq = nil,
            BREAK = { "Break", "MoTian_Dodge" } }

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
        if tn - r.at > A.KEEP then A.mine[id] = nil
        elseif abs and abs[r.n] and (not latest[r.n] or id > latest[r.n]) then latest[r.n] = id end
    end
    local ids = {}
    for _, id in pairs(latest) do ids[#ids + 1] = id end
    table.sort(ids)
    return table.concat(ids, ",")
end

-- §353 交手中、对手是本地 AI、联机程序说了 sqp=1、不是木桩：替身杀气按游戏自己的（不补满、破防照播）
function A.ownShachi()
    if not (A.on() and NET.rsqp and not NET.rdummy) then return false end
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
end

return A
end
