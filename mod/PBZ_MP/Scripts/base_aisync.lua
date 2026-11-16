-- base_aisync.lua —— §352 本地 AI / 木桩尽量按真人那套判（用户 11-16"让 ai 的机制尽量贴近真人，而不止是这一个招式"）
-- 真人对战：挨打那一方的身体（落空等多久、挨打被打断、冻住）由他自己的游戏说了算。本地 AI 没有游戏，它的"身体"就是
-- 我游戏里的替身。这里把替身 / 我这边游戏的实际状态报给联机程序里的 AI（只在对手是本地 AI / 假对手、不是观战时发）：
--   act=<招式号,...>  我还在放的攻击招（技能还挂在我身上，NET.prevAbs）。AI 等这招放完还没碰到才判落空
--                     （真人那边是替身还在播这一招就接着等，LAT.stillPlaying；以前 AI 固定 1.5 秒，紫冥剑大招 2–4 秒才打到 → §351）
--   pst=0/1           替身在我游戏里正在播受击 / 倒地 / 起身动作（LO.isHitMontage），或身上有控制类异常（BAL.CTRL 里的类型，冰冻）
--                     → AI 这段时间不出招、不喝药、不举架势，被打中也防不了（真人挨打硬直里一样动不了）
-- 旧版联机程序不认这两个键 → 照旧。发包这一帧顺带算，不额外轮询：动作每帧本来就在读，异常标签每 EVERY 帧读一次。
return function(ctx)
local out, NET, ST, G = ctx.out, ctx.NET, ctx.ST, ctx.G
local A = { KEEP = 10.0, EVERY = 3, mine = {}, pst = "0", why = nil, LOG_MAX = 60, logs = 0, n = { busy = 0 } }

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

-- 替身现在为什么动不了（nil = 能动）
function A.busyWhy(pup)
    if not (G.valid(pup)) then return nil end
    local m = LAT and LAT.activeMontage and select(3, LAT.activeMontage(pup)) or nil
    if m and LO and LO.isHitMontage(m) then return m end
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
    return "act=" .. A.wireAct(tn) .. "\npst=" .. A.wirePst(tn) .. "\n"
end

-- 换对手 / 对局结束时清掉
function A.reset()
    A.mine, A.pst, A.why = {}, "0", nil
end

return A
end
