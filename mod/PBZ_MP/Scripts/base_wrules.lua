-- base_wrules.lua —— 从 main.lua 搬出来的 武器平衡规则（§184 / §212 火枪、§242 召唤、§242/§245/§246 火流星、§200 闪避、§200.11 切武器保持杀气，docs/MAIN_SLIM.md）。原来在 main.lua 的 "-- ===… §184 紫冥剑火枪冷却" 和 "-- ===… §200 闪避冷却" 两段
return function(ctx)
local ST, NET, MATCH, NET_DIR, G = ctx.ST, ctx.NET, ctx.MATCH, ctx.NET_DIR, ctx.G
local valid, rawProp, short, sameObj = G.valid, G.rawProp, G.short, G.sameObj
local getP1, puppet, now, setAttr, cutMontage = G.getP1, G.puppet, G.now, G.setAttr, G.cutMontage
-- main.lua 主循环那段会把 out / attrOf / montageOf 换成计时包装（PROF.wrap），这几个由 ctx 传"调用时再取"的包装，
-- 和搬出来之前一样走计时（docs/MAIN_SLIM.md 规矩 3）
local out, attrOf, montageOf = ctx.out, ctx.attrOf, ctx.montageOf

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
function GCD.sec()            -- 冷却秒数：不在对局里 / 房间设置"紫冥剑火枪冷却"关着（§216）= 0（不管）；平衡表 cooldown 里没写 = 0
    if (MATCH.role == nil and not BASEHOOK.inMp()) or not (BAL.on and NET.flagNow("gcd")) then return 0 end
    return BAL.COOLDOWN[GCD.KEY] or 0
end
function GCD.reset(why)
    local had = GCD.side.me.t0 or GCD.side.op.t0
    GCD.side = { me = {}, op = {} }
    GCD.hintTill, GCD.wrote = 0, nil
    GDMG.reset()                     -- §212
    SUMD.reset()                     -- §242
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
        if (MATCH.role ~= nil or (BASEHOOK and BASEHOOK.inMp and BASEHOOK.inMp())) and not (s.t0 and not s.endAt) then GCD.onSummon("me", tn); GDMG.onGun("me", nil, tn) end
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
    -- §314 实测（11-15 01:08）：多人房里 MATCH.role 一直是 nil（那是旧 1v1 的），以前这里每帧"清零（不在对局里）"→ 多人房火枪冷却从来没拦过
    -- （GCD.sec 认 inMp，召出时记了、下一帧就清）。多人房的对手替身走 PEER（观战式重放），对方那一侧本来就不挡，只靠出手方这一侧拦
    if MATCH.role == nil and not BASEHOOK.inMp() then
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
    if not NET.fighting() or not BAL.active() then return nil end
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

-- ============================================================ §242 召唤类影之武装：召唤物打中一下只扣 1 点（用户 11-11 定）
-- 剑客召集令 GA_JianKeZhaoJiLing_*、草偶丝线 GA_CaoOuSiXian_*、枯叶丝竹串 GA_KuYeSiZhuChuan_*、虚空化山 GA_XuKongHuaShan_*
-- 召出来的 NPC / 召唤物打人，每下只算 1 点。做法照 §212 火枪（GDMG）：
--   伤害在挨打方本机算（对方替身召的东西打在我身上），认得出这一下是这几件召出来的 → 把这一下的掉血改成 1；
--   本地 AI / 假对手这边是我的召唤物打替身，td= 这一下也按 1 报；两边规则一致。
-- 认法：① 这一下记在这件影之武装的召唤招上（判定窗口一直在，召唤后 8 秒内的命中都记给它）；
--       ② 没有判定窗口的掉血（召唤物自己打，游戏不开招式窗口）：召唤动作后 FIELD_HOLD 秒内、替身近处有认出来的召唤物 → 也算。
-- 只在交手中 + 武器平衡开 + sdmg 这一项 > 0 时生效（和 GDMG 一样）。数值表 sd= 里可以按件覆盖，没写按 1 点。
-- 全局表（主代码块 local 已满）
SUMD = { KEY = "Summon", FIELD_HOLD = 20.0, LOGS = 40, logs = 0, n = { me = 0, op = 0 }, field = nil, fieldName = nil }
SUMD.OFF = (NET_DIR or "net") .. "/summon_dmg_off.txt"
SUMD.FAM = {
    { pat = "^GA_JianKeZhaoJiLing_", key = "ShachiWeapon_JianKeZhaoJiLing", name = "剑客召集令" },
    { pat = "^GA_CaoOuSiXian_", key = "ShachiWeapon_CaoOuSiXian", name = "草偶丝线" },
    { pat = "^GA_KuYeSiZhuChuan_", key = "ShachiWeapon_KuYeSiZhuChuan", name = "枯叶丝竹串" },
    { pat = "^GA_XuKongHuaShan_", key = "ShachiWeapon_XuKongHuaShan", name = "虚空化山" },
}
-- net/summon_dmg_off.txt 存在 = 不改召唤物伤害（照原版）；只影响这一项，召唤物阵营 / 认出来那套还在
function SUMD.off()
    local f = io.open(SUMD.OFF, "r")
    if f then f:close(); return true end
    return false
end
function SUMD.log(...)
    if SUMD.logs < SUMD.LOGS then SUMD.logs = SUMD.logs + 1; out(...) end
end
function SUMD.reset()
    SUMD.n, SUMD.field, SUMD.fieldName = { me = 0, op = 0 }, nil, nil
end
-- 这一招是不是这几件的召唤招（被动不算：被动不会打人）
function SUMD.on(name)
    if not name or name:find("Passive", 1, true) then return nil end
    for _, f in ipairs(SUMD.FAM) do
        if name:match(f.pat) then return f end
    end
    return nil
end
function SUMD.per(name)
    if not NET.fighting() or not BAL.active() or SUMD.off() then return nil end
    local f = SUMD.on(name)
    local v = f and BAL.sdmg(f.key) or BAL.sdmg(SUMD.KEY)
    if v == nil then v = BAL.sdmg(SUMD.KEY) end
    if not v or v <= 0 then return nil end
    return v
end
-- 替身刚放了这几件的召唤：这次召唤的东西还在不在（SUMMON.mine 里有它认出来的召唤物；认不出来也算，按召唤动作后 8 秒）
function SUMD.near(tn)
    local at = ST.summonArmAt
    if not (at and tn >= at and tn - at <= SUMD.FIELD_HOLD) then return false end
    local f = SUMD.on(ST.summonName or "")
    if not f then return false end
    for p, a in pairs(SUMMON.mine or {}) do
        if valid(a) then SUMD.field, SUMD.fieldName = a, f.name; return true, f end
    end
    -- 召唤物没认出来（阵营 / 主人读不到）：召唤动作刚放完的 8 秒内也按它算（那时候判定窗口通常还开着）。
    -- 超过 8 秒还没有认出来的召唤物，就不动（免得把摔伤 / 别的伤害当成召唤物）。
    if tn - at <= 8.0 then SUMD.field, SUMD.fieldName = nil, f.name; return true, f end
    return false
end
-- 挨打方（netJudge 掉血那一帧调）：认作对方这几件的召唤物打的 → 这一下只扣每件的数；不管 → nil
function SUMD.fix(p1, name, step, hpBefore, tn)
    local v = SUMD.per(name)
    if not v or not hpBefore or hpBefore <= 0 or not step or step <= v + 1e-3 then return nil end
    if not SUMD.on(name) then return nil end
    if not GDMG.setHp(p1, hpBefore - v) then return nil end
    SUMD.n.op = SUMD.n.op + 1
    SUMD.log("§242 召唤物每下伤害：对方 %s 的召唤物打中我 -%.0f → 改成 -%g（第 %d 次；数值表 sdmg.%s）",
        SUMD.on(name).name, step, v, SUMD.n.op, SUMD.on(name).key)
    return v
end
-- 挨打方、没有判定窗口的掉血（召唤物自己打）：认得出是召唤物 → 只扣每件的数
function SUMD.fixField(p1, step, hpBefore, tn)
    if not hpBefore or hpBefore <= 0 or not step or step <= 0 then return nil end
    local ok, f = SUMD.near(tn)
    if not ok then return nil end
    local v = SUMD.per(ST.summonName) or 1
    if step <= v + 1e-3 then return nil end
    if not GDMG.setHp(p1, hpBefore - v) then return nil end
    SUMD.n.op = SUMD.n.op + 1
    SUMD.log("§242 召唤物每下伤害：%s打中我 -%.0f（没有招式窗口）→ 改成 -%g（召唤后 %.1f 秒，第 %d 次）",
        f.name, step, v, tn - (ST.summonArmAt or tn), SUMD.n.op)
    return v
end
-- 本地 AI（TOUCH.mark 记 td= 时调；d = 替身本机这一帧掉的血）：认作我的召唤物打的 → 返回这一下该报的数；不管 → nil
function SUMD.mine(id, d, tn)
    local name = NET.evName and NET.evName[id]
    local v = SUMD.per(name)
    if not v or not d or d <= 0 or not SUMD.on(name) then return nil end
    SUMD.n.me = SUMD.n.me + 1
    SUMD.log("§242 召唤物每下伤害：我的 %s 打中替身（本机掉 %.0f）→ 回报按 %g（#%d，第 %d 次）",
        SUMD.on(name).name, d, v, id, SUMD.n.me)
    return v
end

-- ============================================================ §242/§245/§246 火流星 L1+R2（GA_Hun_HuoLiuXing_DB_C）
-- 资产名字表（11-11 离线，names.py）：
--   GA_Hun_HuoLiuXing_DB 自己引用 NS_HuoLiuXing_Cyclone / NS_HuoLiuXing_Blade_Charged_001 /
--   NS_HuoLiuXing_SafeZone_001_Warning（Niagara）+ BD_Hun_HuoLiuXing_DB_Loop_* / _Final / _GroundFire_01（后续火焰子弹）；
--   GE_ShachiWeapon_HuoLiuXing_Evolution 给 CharacterState.WeaponUpgrade.HuoLiuXing.Evolution（进化后才有地面火）。
-- §242 补的是猜的 NS_HuoLiuXing_Cyclone（包里不存在，真实资产叫 NS_HuoLiuXing_Cyclone_201），日志每次"找不到特效"。
-- §245 改成补 SafeZone_001_Warning + FirePillarBig_001_Main，但用户 11-11 实测形状不对、而且一直不消失（循环特效没寿命）。
-- §246 做两件事：
--   1. 只读对比探针（默认开，前 N 次）：玩家 / 替身放 DB 后 0–4 秒按时间点扫世界，记新出现的 Niagara / 子弹 / 后处理，
--      以及双方放招时身上的 HuoLiuXing 标签 / 升级 GE。关键字 `§246 火流星对比`。不每帧扫，只在下面 TIMES 的时间点扫。
--   2. §246.1 起补的是正确的地火场地 SafeZone_002_Main，默认开；补出来的每个特效都有寿命（到时 Deactivate + DestroyComponent），
--      回合重置 / 对局结束 / 换世界时清掉。net/huoliuxing_fx_off.txt 仍然最高优先（存在 = 什么都不补）。
-- 日志：补特效前 20 条（§245），对比探针单独一个额度（§246，前 N 次、每次最多 MAX_ITEMS 个对象）。
HLFX = { NAME = "GA_Hun_HuoLiuXing_DB_C", LOGS = 20, logs = 0, pend = {}, FWD = 200.0, Z = 20.0,
         LIFE = 4.0, MAX_ACTIVE = 8,
         FX = {
             -- §246.1 用户 11-11 指出 _tools/gasgraph 火流星关系报告：判定 BD_Hun_HuoLiuXing_DB_GroundFire_01（地火）挂的特效是
             -- NS_HuoLiuXing_SafeZone_002_Main = 原版那片"中间空一个圆、圆边燃烧"的场地。§245 的 SafeZone_001_Warning / FirePillarBig 是错的，删掉。
             -- 中心在施法者（替身）脚下；出现时刻 / 寿命先按估计值，探针（§246 我放的那几次）量出原版数后再改
             { key = "SafeZone_002_Main", at = 0.60, life = 6.0,
               path = "/PBZVFXPack/VFX/BattleFX/HuoLiuXing/NS_HuoLiuXing_SafeZone_002_Main.NS_HuoLiuXing_SafeZone_002_Main" },
         },
         PROBE = {
             MAX = 3, LOGS = 480, logs = 0, MAX_ITEMS = 30,
             TIMES = { 0.0, 0.15, 0.35, 0.60, 1.00, 2.00, 4.00 },
             pend = {}, n = { me = 0, pup = 0 },
             TAGS = { "CharacterState.WeaponUpgrade.HuoLiuXing.Evolution", "CharacterState.WeaponUpgrade.HuoLiuXing" },
             KEY = { "HuoLiuXing", "FirePillar", "SafeZone", "GroundFire", "Post_001" },
         } }
HLFX.OFF = (NET_DIR or "net") .. "/huoliuxing_fx_off.txt"
HLFX.ON = (NET_DIR or "net") .. "/huoliuxing_fx_on.txt"
HLFX.PROBE.OFF = (NET_DIR or "net") .. "/huoliuxing_probe_off.txt"
function HLFX.fileOn(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end
function HLFX.off()
    return HLFX.fileOn(HLFX.OFF)
end
-- §246.2 用户 11-11 22:3x 实测：假对手 --wge 报上 GE_ShachiWeapon_HuoLiuXing_DB / _Evolution 等升级后，替身放 DB 游戏自己就画出地火场地
-- （"效果看起来对了"）。根因是替身缺对方的影之武装升级，真人联机走 §118 wge= 同步会带上。补特效用不着了：默认关，
-- 建 net/huoliuxing_fx_on.txt 才补（对方客户端太旧、不发 wge= 时的兜底）
function HLFX.fxOn()
    return HLFX.fileOn(HLFX.ON) and not HLFX.off()
end
function HLFX.probeOff()
    return HLFX.fileOn(HLFX.PROBE.OFF)
end
function HLFX.log(...)
    if HLFX.logs < HLFX.LOGS then HLFX.logs = HLFX.logs + 1; out(...) end
end
function HLFX.plog(...)
    local P = HLFX.PROBE
    if P.logs < P.LOGS then P.logs = P.logs + 1; out(...) end
end
function HLFX.counts(list)
    local c = { Niagara = 0, Bullet = 0, PostProcess = 0 }
    for _, it in ipairs(list or {}) do
        if it.kind then c[it.kind] = (c[it.kind] or 0) + 1 end
    end
    return c
end
function HLFX.countsText(list)
    local c = HLFX.counts(list)
    return string.format("Niagara %d / 子弹 %d / 后处理 %d", c.Niagara, c.Bullet, c.PostProcess)
end
function HLFX.locOf(a)
    if not valid(a) then return nil end
    local ok, l = pcall(function() return a:K2_GetActorLocation() end)
    return ok and l or nil
end
function HLFX.rel(loc, base)
    if not (loc and base) then return "?" end
    return string.format("(%.0f,%.0f,%.0f)", (loc.X or 0) - (base.X or 0), (loc.Y or 0) - (base.Y or 0), (loc.Z or 0) - (base.Z or 0))
end
function HLFX.tagsOf(a)
    if not (G.tagsMatching and valid(a)) then return "读不到" end
    local ok, hit = pcall(G.tagsMatching, a, HLFX.PROBE.TAGS)
    if not ok then return "读不到" end
    return (hit and #hit > 0) and table.concat(hit, ",") or "无"
end
function HLFX.geOf(a)
    if not (G.geCounts and valid(a)) then return "读不到" end
    local ok, cnt = pcall(G.geCounts, a)
    if not (ok and cnt) then return "读不到" end
    local list = {}
    for k, n in pairs(cnt) do
        if type(k) == "string" and k:find("HuoLiuXing", 1, true) then list[#list + 1] = k .. "×" .. n end
    end
    table.sort(list)
    return #list > 0 and table.concat(list, " ") or "无"
end
-- 跟火流星有关的对象（用于"放招时就已经在场上"的场地特效：基线里也有，但必须列出来）
function HLFX.isRelevant(it)
    local s = tostring(it.cls or "") .. " " .. tostring(it.asset or "") .. " " .. tostring(it.owner or "")
    for _, k in ipairs(HLFX.PROBE.KEY) do
        if s:find(k, 1, true) then return true end
    end
    return false
end
function HLFX.itemText(it, q)
    local s = string.format("%s 类=%s", tostring(it.kind or "?"), tostring(it.cls or "?"))
    if it.asset then s = s .. " 资产=" .. tostring(it.asset) end
    s = s .. " Owner=" .. tostring(it.owner or "?")
    s = s .. " 相对施法者" .. HLFX.rel(it.loc, q.loc)
    if it.scale then s = s .. " 缩放=" .. tostring(it.scale) end
    if it.radius then s = s .. string.format(" 半径=%.0f", it.radius) end
    if it.active ~= nil then s = s .. " 激活=" .. tostring(it.active) end
    if it.status ~= nil then s = s .. " 子弹状态=" .. tostring(it.status) end
    return s
end
-- 探针：放招时刻已经在了的相关对象也记（标"放招时已在"），其余只记新出现的
function HLFX.probeAt(q, t, tn)
    local P = HLFX.PROBE
    local list = (G.worldFx and G.worldFx()) or {}
    for _, it in ipairs(list) do
        if it.id then
            local known = q.base[it.id]
            local s = q.seen[it.id]
            if not s and (not known or HLFX.isRelevant(it)) then
                if q.noteCount < P.MAX_ITEMS then
                    q.seen[it.id] = { first = t, last = t, it = it }
                    q.order[#q.order + 1] = it.id
                    q.noteCount = q.noteCount + 1
                    HLFX.plog("§246 火流星对比：%s #%d %s%.3fs %s", q.label, q.n,
                        known and "放招时已在 " or "新 ", t, HLFX.itemText(it, q))
                elseif not q.trunc then
                    q.trunc = true
                    HLFX.plog("§246 火流星对比：%s #%d 新对象超过 %d 个，后面的不逐条列（看汇总）", q.label, q.n, P.MAX_ITEMS)
                end
            elseif s then
                s.last = t
                s.it = it
            end
        end
    end
    if t == 0.0 then
        HLFX.plog("§246 火流星对比：%s #%d 0.000s 基线 %s；标签 %s；HuoLiuXing GE %s",
            q.label, q.n, HLFX.countsText(list), HLFX.tagsOf(q.actor), HLFX.geOf(q.actor))
    elseif t == P.TIMES[#P.TIMES] then
        HLFX.plog("§246 火流星对比：%s #%d %.2fs 结束：本刻 %s；新增 %d 个；标签 %s；HuoLiuXing GE %s",
            q.label, q.n, t, HLFX.countsText(list), #q.order, HLFX.tagsOf(q.actor), HLFX.geOf(q.actor))
        for _, id in ipairs(q.order) do
            local s = q.seen[id]
            if s then
                local life = s.last - s.first
                local live = s.last >= t - 0.001
                HLFX.plog("§246 火流星对比：  %s 首次 %.2fs 最后 %.2fs 存活 %s%.2fs  %s",
                    q.label, s.first, s.last, live and "≥" or "", life, HLFX.itemText(s.it, q))
            end
        end
    end
end
function HLFX.probeStep(tn)
    local P = HLFX.PROBE
    if #P.pend == 0 then return end
    local keep = {}
    for _, q in ipairs(P.pend) do
        if not valid(q.actor) then
            HLFX.plog("§246 火流星对比：%s #%d 施法者失效，停止记录", q.label, q.n)
        else
            local t = tn - q.t0
            while q.next <= #P.TIMES and t >= P.TIMES[q.next] do
                HLFX.probeAt(q, P.TIMES[q.next], tn)
                q.next = q.next + 1
            end
            if q.next <= #P.TIMES then keep[#keep + 1] = q end
        end
    end
    P.pend = keep
end
-- 替身身上有没有某一类 HuoLiuXing 的 Niagara（key 是资产短名里的关键字）
function HLFX.has(pup, key)
    local list = (LO.fxOn and LO.fxOn(pup)) or {}
    for _, n in ipairs(list) do
        local s = tostring(n)
        if s:find("HuoLiuXing", 1, true) and s:find(key, 1, true) then return s end
    end
    return nil
end
-- 场地中心：你在放招那一刻站的地面；读不到用替身前方 FWD 厘米
function HLFX.place(pup)
    -- §246.1 地火场地以施法者为中心（GroundFire 子弹 BP_PBZ_OverlapBulletData，跟着施法者生成）
    local ok, l = pcall(function() return pup:K2_GetActorLocation() end)
    if not (ok and l) then return nil, "读不到位置" end
    return { X = l.X, Y = l.Y, Z = l.Z - 90.0 + HLFX.Z }, "替身脚下"
end
-- §246 角色放招事件（只在 cast 时调；不每帧轮询世界）：探针 + 可选补特效
function HLFX.cast(side, actor, use, tn)
    if use ~= HLFX.NAME or not valid(actor) then return end
    if not (MATCH and MATCH.state == "fight") then return end
    local P = HLFX.PROBE
    if P and not HLFX.probeOff() and (P.n[side] or 0) < P.MAX then
        local dup = nil
        for _, q in ipairs(P.pend) do
            if q.side == side and sameObj(q.actor, actor) and tn - q.t0 < 1.0 then dup = q; break end
        end
        if not dup then
            P.n[side] = (P.n[side] or 0) + 1
            local all = (G.worldFx and G.worldFx()) or {}
            local base = {}
            for _, it in ipairs(all) do if it.id then base[it.id] = true end end
            local q = { side = side, label = side == "me" and "我" or "替身", actor = actor, t0 = tn,
                        n = P.n[side], base = base, seen = {}, order = {}, noteCount = 0, next = 1,
                        loc = HLFX.locOf(actor), tags0 = HLFX.tagsOf(actor), ge0 = HLFX.geOf(actor) }
            P.pend[#P.pend + 1] = q
            HLFX.plog("§246 火流星对比：%s 放 %s（对局 #%s 第 %s 回合，这一边第 %d/%d 次，0–4 秒）；起手 %s；现在 %s；标签 %s；HuoLiuXing GE %s",
                q.label, use, tostring(MATCH.id or "?"), tostring(MATCH.round or "?"), q.n, P.MAX,
                q.loc and string.format("(%.0f,%.0f,%.0f)", q.loc.X or 0, q.loc.Y or 0, q.loc.Z or 0) or "读不到",
                HLFX.countsText(all), q.tags0, q.ge0)
        end
    end
    if HLFX.fxOn() then HLFX.note(actor, use, tn) end
end
-- 补地火场地特效（§246.2 起默认关，net/huoliuxing_fx_on.txt 才补）
function HLFX.note(pup, use, tn)
    if use ~= HLFX.NAME or not HLFX.fxOn() or not valid(pup) then return end
    for _, q in ipairs(HLFX.pend) do
        -- 同一次放招的"补放 / 重放"会再 note 一次（19:26:26 日志两行）：1 秒内同一个替身只排一次
        if sameObj(q.pup, pup) and tn - q.t0 < 1.0 then return end
    end
    local at, where = HLFX.place(pup)
    if not at then return end
    HLFX.pend[#HLFX.pend + 1] = { pup = pup, t0 = tn, at = at, where = where, done = {}, spawned = {} }
end
function HLFX.fxStep(tn)
    if #HLFX.pend == 0 then return end
    local keep = {}
    local active = 0
    for _, q2 in ipairs(HLFX.pend) do active = active + #(q2.spawned or {}) end
    for _, q in ipairs(HLFX.pend) do
        if not valid(q.pup) then
            active = math.max(0, active - #(q.spawned or {}))
        else
            local left = 0
            for _, fx in ipairs(HLFX.FX) do
                local t = tn - q.t0
                if t < fx.at then
                    left = left + 1
                elseif not q.done[fx.key] then
                    local have = HLFX.has(q.pup, fx.key)
                    if have then
                        q.done[fx.key] = true
                        HLFX.log("§245 火流星场地特效：替身身上已经有 %s，不补（%.2f 秒）", have, t)
                    elseif active >= HLFX.MAX_ACTIVE then
                        q.done[fx.key] = true
                        HLFX.log("§245 火流星场地特效：%s 不补（同时最多 %d 个）", fx.key, HLFX.MAX_ACTIVE)
                    else
                        local c, err = nil, "没有 G.spawnFxAt"
                        if G.spawnFxAt then c, err = G.spawnFxAt(q.pup, fx.path, q.at, 1.0, true) end
                        if c then
                            q.done[fx.key] = true
                            active = active + 1
                            q.spawned[#q.spawned + 1] = { c = c, born = tn, at = t, life = fx.life or HLFX.LIFE }
                            HLFX.log("§245 火流星场地特效：补 %s 在%s（%.2f 秒，寿命 %.1f 秒）", fx.key, q.where, t, fx.life or HLFX.LIFE)
                        else
                            HLFX.log("§245 火流星场地特效：%s 没补成（%s）", fx.key, tostring(err))
                        end
                    end
                end
            end
            -- §246 寿命到点：Deactivate + DestroyComponent（SpawnSystemAtLocation 也传了 bAutoDestroy=true）
            local killed, alive = 0, {}
            for _, s in ipairs(q.spawned or {}) do
                if not valid(s.c) then
                    active = math.max(0, active - 1)       -- 已经没了
                elseif tn >= s.born + s.life then
                    if G.destroyComps then pcall(G.destroyComps, { s.c }) end
                    killed = killed + 1
                    active = math.max(0, active - 1)
                else
                    alive[#alive + 1] = s
                end
            end
            q.spawned = alive
            if killed > 0 then
                HLFX.log("§245 火流星场地特效：到时收掉 %d 个（放招后 %.2f 秒）", killed, tn - q.t0)
            end
            if left > 0 or #q.spawned > 0 then keep[#keep + 1] = q end
        end
    end
    HLFX.pend = keep
end
-- 清掉补出来的特效（回合重置用 clearFx：不动探针次数；对局结束 / 换世界用 clear）
function HLFX.clearFx(why, safe)
    local n = 0
    if not safe then
        for _, q in ipairs(HLFX.pend) do
            local cs = {}
            for _, s in ipairs(q.spawned or {}) do if valid(s.c) then cs[#cs + 1] = s.c end end
            if #cs > 0 and G.destroyComps then pcall(G.destroyComps, cs); n = n + #cs end
        end
    end
    HLFX.pend = {}
    HLFX.PROBE.pend = {}
    if n > 0 then HLFX.log("§245/§246 火流星：清掉补出来的特效 %d 个（%s）", n, why or "-") end
    return n
end
function HLFX.clear(why, safe)
    local n = HLFX.clearFx(why, safe)
    HLFX.PROBE.n = { me = 0, pup = 0 }
    HLFX.PROBE.logs = 0          -- 新一场 / 回自由活动：探针日志额度也重新算（上一场的已经写进 mp_probe.log）
    if why then HLFX.plog("§246 火流星对比：计数清零（%s）", why) end
    return n
end
function HLFX.step(tn)
    HLFX.probeStep(tn)
    HLFX.fxStep(tn)
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
function DCD.on() return (MATCH.role ~= nil or (BASEHOOK.inMp())) and NET.fighting() end
function DCD.syOn() return BAL.on and NET.flagNow("sycd") end     -- §216 房间设置"瞬影冷却"（以前看武器平衡）
function DCD.dgOn() return BAL.on and NET.flagNow("dgc") end      -- §216 房间设置"闪避扣杀气"（以前看武器平衡）
function DCD.secKey(key)    -- 瞬影冷却秒数：不在交手里 / 房间设置"瞬影冷却"关着（§216）= 0；表里没写 = 默认 10
    if not DCD.on() or not DCD.syOn() then return 0 end
    local v = BAL.COOLDOWN[key]
    if v == nil then v = DCD.DEF[key] end
    return v or 0
end
function DCD.costOf(n)      -- 普通闪避这一段扣多少杀气：不在交手里 / 房间设置"闪避扣杀气"关着（§216）/ 不是普通闪避 = 0
    if DCD.kind(n) ~= "dg" or not DCD.on() or not DCD.dgOn() then return 0 end
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
    if not k or not DCD.on() then return false end
    if k == "dg" then if DCD.dgOn() then DCD.charge(p1, n, tn) end; return false end
    if not DCD.syOn() then return false end
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
    if DCD.kind(e.name) ~= "sy" or not DCD.on() or not DCD.syOn() then return false end
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
-- 写回后发包的 sh= 就是写回后的值，对方的 Boss 血条跟着对。只在房间设置"切武器保持杀气"开着（11-16 起，以前看武器平衡）、对局交手中；SwitchKeepShachi = 0 关掉
-- §337 "跳到上限"放宽到差 NEAR 点以内（11-15 玩家日志 22:07:38：破防挣脱后切到妖锯，杀气 250 → 796，上限 800，
--   同一帧被扣掉了几点，以前要求差 1 点以内 → 没认出来、没写回，杀气一直是满的）。误判靠"PEND 秒内有切武器证据"挡住
SWK = { PEND = 0.35, NEAR = 40, IDX_EVERY = 8, LOGS = 40, logs = 0, k = 0, last = nil, idx = nil, swtAt = -100, pend = nil, n = 0 }
function SWK.on() return DCD.on() and BAL.on and NET.flagNow("swk") and BAL.cost("SwitchKeepShachi") ~= 0 end     -- 11-16 房间设置"切武器保持杀气"（以前看武器平衡）
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
    if SWK.last and shm and sh + debit >= shm - SWK.NEAR and sh + debit > SWK.last + 1 then     -- 这一包里闪避先扣过的也算回去；§337 差 NEAR 以内算到上限
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

return {
    GCD = GCD,
    GDMG = GDMG,
    SUMD = SUMD,
    HLFX = HLFX,
    DCD = DCD,
    SWK = SWK,
}
end
