-- base_charge.lua —— 从 main.lua 搬出来的 §92 蓄力招松手同步（docs/MAIN_SLIM.md）。原来在 main.lua 的 "-- ===… §92 蓄力招松手同步" 那段
return function(ctx)
local NET, NET_DIR, RECM, JUDGE_WIN, playNamed, G = ctx.NET, ctx.NET_DIR, ctx.RECM, ctx.JUDGE_WIN, ctx.playNamed, ctx.G
local full, pathOf, valid, try, rawProp, shortName, sameObj = G.full, G.pathOf, G.valid, G.try, G.rawProp, G.shortName, G.sameObj
local getP1PC, now, tagsOf, setYaw, cutMontage = G.getP1PC, G.now, G.tagsOf, G.setYaw, G.cutMontage
-- main.lua 主循环那段会把 out / activeAbilities / montageOf 换成计时包装（PROF.wrap），这几个由 ctx 传"调用时再取"的包装，
-- 和搬出来之前一样走计时（docs/MAIN_SLIM.md 规矩 3）
local out, activeAbilities, montageOf = ctx.out, ctx.activeAbilities, ctx.montageOf
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
    -- §239 拙壁盾滑步冲刺升级与偃月刀强化闪避反击升级
    GA_ZhuoBiDun_Slide_C = { "/PBZCombatAsset/ActorData/Players/Hun/ShaqiWeapon/ZhuoBiDun/UpgradeData/GE_ShachiWeapon_ZhuoBiDun_Slide.GE_ShachiWeapon_ZhuoBiDun_Slide_C" },
    GA_Hun_YanYueDao_B_Snap_Reinforced_C = { "/PBZCombatAsset/ActorData/Players/Hun/Weapon/YanYueDao/Filed/GE_YanYueDao_SpeicalSkill_CanReinforced.GE_YanYueDao_SpeicalSkill_CanReinforced_C" },
    -- §159 进阶冲刺：双月的要 CharacterState.WeaponUpgrade.ShuangYue.CanSwiftDash（升级 GE 在 WeaponUpgrade/，不在 UpgradeData/）；
    -- 玉双环的名字表里有 Jade.EnableDA（DefaultDash / GhostDash 两个升级都给，取 DefaultDash）
    GA_Hun_AdvancedDash_ShuangYue_C = { CHG.ge("ShuangYue", "GE_ShuangYue_ChargeSpeed_CanSwiftDash", "WeaponUpgrade") },
    -- §229 11-11 01:41 实测：只补 DefaultDash 后替身身上还是没有 Jade.EnableDA；玩家放得出时身上有 EnableDA + Afterimage，
    -- 挂着 DefaultDash / GhostDash / Afterimage 三个。三个都补
    GA_Hun_AdvancedDash_Double_Jade_C = { CHG.ge("JadeDualChakram", "GE_Jade_Upgrade_DefaultDash"),
                                          CHG.ge("JadeDualChakram", "GE_Jade_Upgrade_GhostDash"),
                                          CHG.ge("JadeDualChakram", "GE_Jade_Upgrade_Afterimage") },
}
CHG.DASH_CD = "/PBZCombatAsset/Prototypes/GameplayEffects/GE_DashCooldown.GE_DashCooldown_C"     -- §159
CHG.PRE = {
    GA_Hun_SlitheringSword_Potential_C = { CHG.ge("SlitheringSword", "GE_SlitheringSword_GrantPotential"),
                                           CHG.ge("SlitheringSword", "GE_SlitheringSword_EnablePotentialEnergy") },
    -- §243 铁矿 BChargeAttack：资产名字表里bullet 分 Lv1/Lv2/Lv3，按 CharacterState.AbilityState.Iron.Buff.Lv1/2/3 选；
    -- 这些标签由 Weapon/Iron/UpgradeData/GE_Weapon_Iron_GiveChargeBuff 给。替身没有这个升级时动作照播、子弹不出来
    -- （18:24:51 / 18:25:01 实测：返回 true、Hun_CanGangRen_Skill_02_End_Montage 播了、判定落空）。
    GA_Hun_Iron_BChargeAttack_C = { CHG.ge("Iron", "GE_Weapon_Iron_GiveChargeBuff") },
    -- §243 长兵 BCharge 松手后的 Long_BBB_New 要 CharacterState.AbilityState.Long.CanBBB；武器升级 GE_Weapon_Long_BBB 是入口
    GA_Hun_Long_BBB_New_C = { CHG.ge("Long", "GE_Weapon_Long_BBB") },
}
-- §243 蓄力松手后该放哪一招（资产名字表：BCharge 松手时 ForceActivateExternalActionAbilityByTag/ByClass）：
--   Iron_BCharge：Ability.Action.Hun.Heavy.Iron.BJump → 全包只有 Iron_BChargeAttack 带这个标签
--   Long_BCharge：Ability.Action.Hun.Heavy.Long.BBB → Long_BBB_New（Hun_LongBlade_BBB_Montage / B_Hun_Long_BBB_New_*）
-- 以前只 cutMontage 停蓄力动作，松手那一刀没放出来（18:25:14 / 18:25:26 实测）。
CHG.REL = {
    GA_Hun_Iron_BCharge_C = { name = "GA_Hun_Iron_BChargeAttack_C" },
    GA_Hun_Long_BCharge_C = { name = "GA_Hun_Long_BBB_New_C" },
}
CHG.applied, CHG.POT_LOGS, CHG.potN = {}, 10, 0

-- 给替身上 list 里的升级 GE（同一个替身同一个 GE 只上一次）。返回这次有没有新上的
function CHG.upgrade(pup, name, list)
    local any = false
    for _, ge in ipairs(list or {}) do
        local key = pathOf(pup) .. "|" .. ge
        if not CHG.applied[key] then
            local ok = LO.applyGE(pup, ge, "替身补武器升级 " .. ge:match("([%w_]+)_C$") .. "（" .. name .. "）")
            if ok then CHG.applied[key] = true; any = true end     -- §242 失败不记，下次还试
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
    if INP and INP.heldT then for id in pairs(INP.heldT()) do INP.release(id, "重置") end end
    CHG.out, CHG.rel, CHG.fired, CHG.peerRel = {}, {}, {}, false
    CHG.stgOut, CHG.stg = {}, {}           -- §420.1
    CHG.lastFire = nil
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
        if CHG.STAGE[name] then
            w.stg = CHG.STAGE[name]
            if id then CHG.stgPush(id, 0, nil, tn) end      -- §420.1 先告诉对方"这招我会报档位"（大招压着的在 onEmit 补）
        end
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
            if w.stg then                                      -- §420.1
                CHG.stgPush(id, 0, nil, now())
                if w.stgN then CHG.stgPush(id, w.stgN, w.stgC, now()) end
            end
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

-- §409.2 发送方：我按着蓄力时放了下一招（攻击 / 闪避 / 跳 / 切刀，别的武器族）→ 这一刻就算松手。
-- 以前只有"蓄力 / 探针"类的招会走 CHG.watch 的"放了下一招"；闪避（AdvancedDash）不在里面，只能等按键读数 / 技能列表，
-- 11-22 收方日志里闪避取消的钢形态蓄力重被报成"按了 13.10 秒""20.64 秒"（替身技能 0.8 秒就结束了）
function CHG.onMyFire(n, tn, attack)
    if not CHG.endsHold(n, attack) then return 0 end
    local k = 0
    for _, w in ipairs(CHG.list) do
        if w.who == "我" and w.hold and not w.relAt and w.name ~= n and not CHG.VEHICLE.names[w.name]
            and not CHG.sameFamily(w.name, n) then
            CHG.release(w, tn, "放了下一招 " .. n)
            k = k + 1
        end
    end
    return k
end

-- 状态包字段（没有就空串）
function CHG.wire(tn)
    while #CHG.out > 0 and tn - CHG.out[1].at > CHG.REL_KEEP do table.remove(CHG.out, 1) end
    local r1 = ""
    if #CHG.out > 0 then
        local s = {}
        for _, r in ipairs(CHG.out) do s[#s + 1] = string.format("%d:%.2f", r.id, r.secs) end
        r1 = "rel=" .. table.concat(s, ",") .. "\n"
    end
    return r1 .. CHG.stgWire(tn)
end

-- 收包：rel=<远端招式号>:<秒>,...（旧版没有这个字段 → 什么都不做）
function CHG.onPacket(t, tn)
    if t.chs then CHG.stgPacket(t.chs, tn) end      -- §420.1
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
    if not (CHG.SPIN_SKIP and CHG.SPIN_SKIP[e.name]) then CHG.fired[e.id].spin = {} end   -- §407/§409 按住持续类：记状态，pupStep 里补中段动作
    CHG.fired[e.id - 300] = nil
    if SHIELD and SHIELD.onFire then SHIELD.onFire(pup, e, tn) end   -- 11-23 举盾：替身停在收盾第一帧等对方松手（不走 §407 续转）
    if HJHC then HJHC.onFire(pup, e, tn) end                        -- §446 火铳连射第二发：替身没出子弹就补
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
    if f.shot then return end                               -- §427 对方会发每一发（独眼弓）：§377 管停住和出箭
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

-- §420.1 巨凶斧蓄力档位（11-23 用户"巨凶斧的蓄力同步有问题，而且蓄力后应该不止 1 段攻击"）。
-- 资产（GA_BrutalAxe_Normal 名字表 / 导出）：技能变量 Current Charge / Released；函数 Can Gain Charge / Gain Charge / Is Holding /
--   To Release；技能自己的时间线（LGATimeline Main / SprintCharge，不跟动作走——蓄力动作里没有任何通知）在固定时刻发
--   GameplayEvent.Ability.Action.BrutalAxe.GainCharge，到时 Can Gain Charge 问输入组件 IsHolding：按着就涨一档，没按着就 To Release。
--   出手 Release1–3 = ShaChi_BrutalAxe_Release_01–03_Montage（01 一刀；02 两刀 + 冲击波；03 三刀 + 两道冲击波，子弹在技能里）；
--   GA_BrutalAxe_Sprint 是它的子类（只多 Sprinting 标签），疾行 Sprint_Combo_01（一刀）/ Sprint_Release_03（蓄满，刀 + 冲击波）。
-- 替身没有输入组件：1.40 秒第一次 GainCharge 就当"没按着"→ 永远一档（11-23 15:15 日志 5 次 Release_01；疾行 16:00 / 17:20 也是一下就出）。
-- 第一版（82f8fae7）暂停蓄力动作等档位：拦不住技能自己的时间线；17:21:18 实测还被发送方 0.20 秒的假松手提前放了（下面 ① 修）。
-- 现在：
--   发：放这招先发 chs=<号>:0；动作换成出手动作 → 读 Current Charge，发 chs=<号>:<档>:<值>，同时算松手（rel=）。
--       ① 这两招的松手只认出手动作：开始那一帧按住的往往只有点按键 IA_ShachiAbility（长按键 _Hold 还没触发），
--          它一松就被当成松手 → 17:21 对方报"按了 0.20 秒"，实际 2.97 秒蓄满三档
--   收：替身放之前按住影武键（INP.KEYS，同 72bae753 贪狼 / 金瓜旋转：给替身建输入组件、IsHolding 读回 true）→ 技能自己照常涨档；
--       收到对方档位 → 写 Current Charge、松开键、调技能的 To Release 当场出手（调不动就等下一次 GainCharge 自己出）；
--       对方旧版（没 chs=）/ 等太久 → 照 rel= / 超时松开
-- 没进游戏验证（日志关键字 §420.1）：IsHolding 能不能让替身涨档、To Release 调不调得动
CHG.AXE_HOLD = { "/PBZInput/InputActions/IA_ShachiAbility_Hold.IA_ShachiAbility_Hold", "/PBZInput/InputActions/IA_ShachiAbility.IA_ShachiAbility" }
CHG.AXE_REL = { ShaChi_BrutalAxe_Release_01_Montage = 1, ShaChi_BrutalAxe_Release_02_Montage = 2, ShaChi_BrutalAxe_Release_03_Montage = 3,
                  ShaChi_BrutalAxe_Sprint_Combo_01_Montage = 1, ShaChi_BrutalAxe_Sprint_Release_03_Montage = 2 }
CHG.AXE = { rel = CHG.AXE_REL, var = "Current Charge", fn = "To Release", wait = 6.0, hold = CHG.AXE_HOLD,
              probe = { "Current Charge", "Released", "No Input Counter" } }
CHG.STAGE = { GA_BrutalAxe_Normal_C = CHG.AXE, GA_BrutalAxe_Sprint_C = CHG.AXE }
CHG.HOLD.GA_BrutalAxe_Sprint_C = 1
CHG.stgOut, CHG.stg, CHG.stgN, CHG.STG_LOGS = {}, {}, 0, 40

function CHG.stgLog(fmt, ...)
    CHG.stgN = CHG.stgN + 1
    if CHG.stgN <= CHG.STG_LOGS then out(fmt, ...) end
end

-- 技能实例上几个变量（诊断）
function CHG.stgProbe(actor, name, sc)
    local inst = LO and LO.activeInstance and LO.activeInstance(actor, name)
    if not inst then return "（没有技能实例）" end
    local t = {}
    for _, k in ipairs(sc.probe) do
        local ok, v = pcall(function() return inst[k] end)
        t[#t + 1] = k .. "=" .. (ok and tostring(v) or "读不到")
    end
    return table.concat(t, " ")
end

-- 发：记一条（同一号同一档只留一条）
function CHG.stgPush(id, n, c, tn)
    for _, r in ipairs(CHG.stgOut) do if r.id == id and r.n == n then return end end
    CHG.stgOut[#CHG.stgOut + 1] = { id = id, n = n, c = c, at = tn or now() }
end

function CHG.stgWire(tn)
    while #CHG.stgOut > 0 and tn - CHG.stgOut[1].at > CHG.REL_KEEP do table.remove(CHG.stgOut, 1) end
    if #CHG.stgOut == 0 then return "" end
    local s = {}
    for _, r in ipairs(CHG.stgOut) do
        s[#s + 1] = r.n == 0 and string.format("%d:0", r.id)
            or string.format("%d:%d:%s", r.id, r.n, type(r.c) == "number" and string.format("%.3f", r.c) or "-")
    end
    return "chs=" .. table.concat(s, ",") .. "\n"
end

-- 发：我的动作换成了出手动作 → 报档位，同时算松手
function CHG.stgMine(w, m, tn)
    local n = w.stg.rel[m]
    if not n then return end
    w.stgN = n
    local inst = LO and LO.activeInstance and LO.activeInstance(w.actor, w.name)
    local okV, v = false, nil
    if inst then okV, v = pcall(function() return inst[w.stg.var] end) end
    w.stgC = (okV and type(v) == "number") and v or nil
    if w.id then CHG.stgPush(w.id, w.stgN, w.stgC, tn) end
    CHG.release(w, tn, "出手 " .. m)
    CHG.stgLog("§420.1 我 %s%s 出手 %s → 第 %d 档，按了 %.2f 秒（%s；%s）", w.name, w.id and ("（本机#" .. w.id .. "）") or "（还没发）", m, w.stgN,
        tn - w.at, w.stgC and string.format("%s = %.3f", w.stg.var, w.stgC) or ("读不到 " .. w.stg.var), CHG.stgProbe(w.actor, w.name, w.stg))
end

-- 收：chs=<号>:0,<号>:<档>:<值>
function CHG.stgPacket(str, tn)
    for id, rest in str:gmatch("(%d+):([^,]+)") do
        id = tonumber(id)
        local n, c = rest:match("^(%d+):?(.*)$")
        n = tonumber(n)
        if id and n then
            local cur = CHG.stg[id]
            if n == 0 then
                if not cur then CHG.stg[id] = { n = 0 } end
            elseif not (cur and cur.n > 0) then
                CHG.stg[id] = { n = n, c = tonumber(c), at = tn }
                local f = CHG.fired[id]
                CHG.stgLog("§420.1 对方 远端#%d %s 出手第 %d 档（%s）%s", id, f and f.name or "?", n,
                    tonumber(c) and string.format("Current Charge = %s", c) or "对方读不到档位变量",
                    f and string.format("，替身放出 %.2f 秒", tn - f.at) or "，替身没放这招")
            end
        end
    end
end

-- 收：把对方的档位写进替身的技能实例，再调 To Release。返回说明
function CHG.stgApply(pup, f, sc, s)
    local inst = LO and LO.activeInstance and LO.activeInstance(pup, f.name)
    if not inst then return "替身没有技能实例" end
    local parts = {}
    if type(s.c) == "number" then
        local okW = pcall(function() inst[sc.var] = s.c end)
        local okR, back = pcall(function() return inst[sc.var] end)
        local good = okW and okR and type(back) == "number" and math.abs(back - s.c) < 0.01
        parts[#parts + 1] = string.format("写 %s = %.3f %s（读回 %s）", sc.var, s.c, good and "成功" or "失败", okR and tostring(back) or "读不到")
    else
        parts[#parts + 1] = "对方没报变量值、不写"
    end
    local okF, err = pcall(function() local fn = inst[sc.fn]; fn(inst) end)
    parts[#parts + 1] = string.format("调 %s %s", sc.fn, okF and "成功" or ("失败：" .. tostring(err)))
    return table.concat(parts, "，")
end

function CHG.stageStep(pup, id, f, tn)
    local sc = CHG.STAGE[f.name]
    if not sc or f.stgOff or not valid(pup) then return end
    local s = CHG.stg[id]
    local held = INP and INP.heldT and INP.heldT()[id] ~= nil
    if s and s.n > 0 then
        f.stgOff = true
        local _, _, m = LAT.activeMontage(pup)
        local out1 = sc.rel[m] and ("替身已经自己出手了（" .. m .. "），不改") or CHG.stgApply(pup, f, sc, s)
        if held then INP.release(id, string.format("对方出手第 %d 档", s.n)) end
        CHG.stgLog("§420.1 远端#%d %s 对方第 %d 档到（替身放出 %.2f 秒，按住 %s）→ %s；%s", id, f.name, s.n, tn - f.at,
            held and "中" or "没按上", out1, CHG.stgProbe(pup, f.name, sc))
        return
    end
    if tn - f.at > sc.wait then
        f.stgOff = true
        if held then INP.release(id, "等档位太久") end
        CHG.stgLog("§420.1 远端#%d %s 等 %.1f 秒没收到档位（%s）→ 松开", id, f.name, sc.wait, s and "对方说会报" or "对方旧版没 chs=")
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
-- §276.9（移植 0.33 分支 §269.11）11-13 观战"人和车没同步"：真人驾车 10 秒多（松了键车照样跑），以前发送方按蓄力招算——松键就发 rel=、
-- 按满 JUDGE_MAX 8 秒也发，接收方 8 秒没等到也自己取消 → 替身提早下车，人（跟着网络位置）和车分开。现在马车发送方只在下车时发 rel=
-- （§276.10：播到下车动作 AM_JumpOffHorseCart，或技能真结束），接收方兜底放宽到 MAX 秒（旧版对方松键就发的 rel= 照旧会让替身提早下车）
CHG.VEHICLE = { names = { GA_HorseCart_Charge_C = 1 }, MAX = 30.0, logN = 0, OFF = "AM_JumpOffHorseCart" }

function CHG.vehicleOff(pup, id, f, tn, why)
    if f.vehOff then return end
    if f.turnAt and CART and tn - f.turnAt < CART.KEEP then return end   -- §434 力荡判定刚生成，来源技能先留着（每帧会再来）
    f.vehOff = true
    local gone = G.cancelAbilities(pup, function(n) return n == f.name end)
    local landed = #gone > 0 and G.hover(pup, false)
    -- §459 11-26 用户"看对方放完马车后，马车消失了人还在播驾驶动作"：§437 力荡时模组自己给替身播的 AM_DriveHorseCart
    -- 不归马车技能管，取消技能车没了、这个动作照播（19:12:39 / 19:13:00 / 19:13:06 / 19:13:27 取消后替身再没换过动作）。
    -- 取消后替身还在上车 / 驾车动作就播下车动作（和发送方一样），播不了就直接收掉
    local am = G.activeMontage or (LAT and LAT.activeMontage)
    local mon = am and select(3, am(pup))
    local stopped
    if type(mon) == "string" and mon:find("HorseCart", 1, true) and not mon:find("JumpOff", 1, true) then
        if playNamed(pup, CHG.VEHICLE.OFF) then stopped = "播下车 " .. CHG.VEHICLE.OFF
        else stopped = (G.retract and G.retract(pup)) and ("收掉 " .. mon) or ("收不掉 " .. mon) end
    end
    if CHG.VEHICLE.logN < 30 then
        CHG.VEHICLE.logN = CHG.VEHICLE.logN + 1
        out("马车：远端#%d %s 放出 %.2f 秒，%s → 替身取消技能 %s%s%s", id, f.name, tn - f.at, why,
            #gone > 0 and table.concat(gone, ",") or "（已经没在放）", landed and "，放回走路" or "",
            stopped and ("，替身动作 " .. stopped) or "")
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
-- 11-23 贪狼按住转圈（用户"蓄力的过程只有开头和结束砸下来，过程中的旋转只有动作没有武器没有判定"）：
-- 替身这招放出 0.61 秒技能自己就进 End（技能在检查点问 GetSGameInputComponent(角色):IsHolding，替身没组件 = 没按着），
-- 之后 §407 补的 Loop 只是动作，技能已在收尾（武器收、旋转判定不生成）。§140 实验 1 实测过：新建的组件
-- GetSGameInputComponent 返回的"就是新建的"、IsHolding 读回 true——激光不行是因为它走的是另一种等松手任务，
-- 贪狼 / 金瓜旋转是直接问 IsHolding（资产里都有 IsHolding + GetSGameInputComponent，没有等松手任务）。
-- 资产看不出问的是重击键还是影武键，两个都按住。对方松手 / 放了下一招 / 技能结束 / 记录过期时松开
local INP_HOLD2 = { "/PBZInput/InputActions/IA_ShachiAbility_Hold.IA_ShachiAbility_Hold", "/PBZInput/InputActions/IA_AttackH_Press.IA_AttackH_Press" }
-- 金瓜按住连击 / 空中下砸（用户 11.23 在线仍"视为不按住"）：资产里同样问 GetSGameInputComponent:IsHolding，导入的键是
-- 影武键 IA_ShachiAbility_Hold / IA_ShachiAbility。按住连击另有一个增强输入事件绑定（只有玩家控制器会触发，替身收不到），
-- 能补的只有 IsHolding 这一路；空中只有 IsHolding
local INP_SHACHI = { "/PBZInput/InputActions/IA_ShachiAbility_Hold.IA_ShachiAbility_Hold", "/PBZInput/InputActions/IA_ShachiAbility.IA_ShachiAbility" }
INP = { KEYS = { GA_TanLang_Normal_C = INP_HOLD2, GA_JinGua_RoAttack_C = INP_HOLD2,
                 GA_JinGua_Normal_C = INP_SHACHI, GA_JinGua_Air_C = INP_SHACHI,
                 GA_BrutalAxe_Normal_C = CHG.AXE_HOLD, GA_BrutalAxe_Sprint_C = CHG.AXE_HOLD,      -- §420.1 巨斧：按住才涨档
                 -- §424 黄金火铳站立第二发（用户 11.23"第二发子弹没伤害"；17:21 IGNIZ 打我 4 轮：Normal_02 每轮 −251.5，
                 -- Normal_04 一次都没中）。第一发资产里有 GAA_ShachiBulletInstant（放出来就出子弹）；第二发没有，
                 -- 靠 Is Holding / Released / Min Duration Reached 那套（GetSGameInputComponent:IsHolding）→ 替身没输入 = 没出子弹。
                 -- 资产里没导入具体的键，按金瓜那组影武键按住；对方松手 / 下一招 / 技能结束时松开
                 GA_HuangJinHuoChong_Normal_04_C = INP_SHACHI,
                 -- §432 铁拳套三段蓄力（用户 11-24"3 段蓄力攻击或者精准释放似乎都是无效的，在线只默认了瞬发"）：Charge_A / AA / AAA 继承
                 -- GA_TieKuangQuanTao_ChargeBase，资产里只有 IsHolding（按住松手招_全表），子弹按档位选 Lv0 / Lv1 / Lv2。
                 -- 11-24 挨打方日志 14:05:25–14:05:40 替身 9 拳全是 *_Lv0（对方 #377 按了 0.75 秒也是 Lv0）= 替身没输入、永远当瞬发。
                 -- 发送方按住的是影武键（"开始 GA_TieKuangQuanTao_Charge_A_C 时按着的输入 IA_ShachiAbility_Hold"），按金瓜那组；
                 -- 对方松手（rel= 到点，pupStep）/ 下一招 / 技能结束时松开 → 档位和"精准释放"按对方按住的秒数由游戏自己算
                 GA_TieKuangQuanTao_Charge_A_C = INP_SHACHI, GA_TieKuangQuanTao_Charge_AA_C = INP_SHACHI,
                 GA_TieKuangQuanTao_Charge_AAA_C = INP_SHACHI,
                 -- §434 游龙头高压水柱（11-24 两边日志：发送方 Start 按住 5.66 秒、13:42 打木桩每 0.5 秒 -70；收方替身
                 -- 远端#310 放出 1.01 秒就进 End、一下没碰到）。资产 GA_YouLongHead_Water 是等松手任务（Release Task / Can Release
                 -- Task，OnRelease / OnAlreadyRelease，导入的键 IA_ShachiAbility_Hold）：放出约 1 秒（CanRelease）才建任务、建的时候
                 -- 没按着就 OnAlreadyRelease 收招，水柱 B_YouLongHead_Loop 那一段根本没出。替身先按住影武键让任务看到"按着"；
                 -- 松开后任务不一定收得到（删键不发松手事件）→ INP.AFTER 兜底收招
                 GA_YouLongHead_Water_C = INP_SHACHI,
                 -- §437 泥头车（用户 11-24"替身没放出来"）：GA_HorseCart_Charge 也是等松手任务（OnRelease / OnAlreadyRelease，
                 -- 导入 IA_ShachiAbility_Hold），替身没按着 → 约 1.86 秒自己下车（收方 14:01:29 / 37 / 57），之后对方的力荡
                 -- 落在已经下车的替身上。按住影武键一直到对方下车的 rel=（§276.10 发送方只在下车时发）/ 技能结束
                 GA_HorseCart_Charge_C = INP_SHACHI,
                 -- §439 拙壁盾举盾（11-25 收方日志 14:35–14:47：对方按 3.4–9.9 秒，替身盾只撑 1.6–4 秒——拉回收盾第一帧暂停
                 -- 约 1 秒后技能照样结束、盾收掉，之后只剩补的举盾姿势）。发送方举盾时按着的是影武键（"开始 GA_ZhuoBiDun_C 时
                 -- 按着的输入 IA_ShachiAbility_Hold"）。替身按住影武键让技能自己一直举着；松开：对方 rel= 到点（pupStep）/
                 -- 下一招 / HOLD_MAX / 回合切换（SHIELD.holdOne 收尾）。拉回暂停留着当兜底（按住不生效时）
                 -- §455 只按影武长按键（发送方举盾时 HoldingInputs 只有 IA_ShachiAbility_Hold）；以前连 IA_ShachiAbility 一起按，
                 -- 和对方实际按着的不一样。举盾技能格挡后看这个键松没松决定要不要盾反（替身没按着 = 格挡完马上自己盾反）
                 GA_ZhuoBiDun_C = { "/PBZInput/InputActions/IA_ShachiAbility_Hold.IA_ShachiAbility_Hold" } },
        -- §432 这些招只在对方发 rel=（新版）时才按住：等不到松手会一直按到记录过期，替身每拳都打满档
        -- §439 举盾同理：旧版对方等不到松手会举满 45 秒
        NEED_REL = { GA_TieKuangQuanTao_Charge_A_C = true, GA_TieKuangQuanTao_Charge_AA_C = true, GA_TieKuangQuanTao_Charge_AAA_C = true,
                     GA_ZhuoBiDun_C = true },
        -- 激光实验时：GA_DuYan_Bow_Laser_C = "/PBZInput/InputActions/IA_ShachiAbility_Hold.IA_ShachiAbility_Hold"
        OFF_FILE = (NET_DIR or "net") .. "/inp_off.txt", logN = 0,
        -- §434 至少按住这么久（秒）才松：对方点按（rel= 0.06–0.09 秒，和出招同一包到）时替身按下马上又松开。
        -- 11-24 14:03 火铳第二发 Normal_04 四次全落空（远端#362：按住 IsHolding true → 同一帧"对方按了 0.09 秒"松开），
        -- 11-23 22:32 双开按到技能结束那次是中的。对方放下一招 / 技能结束 / 重置照常马上松
        MIN_HOLD = { GA_HuangJinHuoChong_Normal_04_C = 1.0 },
        -- §434 松开后 grace 秒技能还在、也没进收招动作 → 取消技能、补播收招（删键不一定让等松手任务收到松手）
        AFTER = { GA_YouLongHead_Water_C = { grace = 0.4, endm = "Hun_ShaChi_YouLongTou_Skill_01_End_Montage" } },
        after = {} }
-- §434 计时（测试桩里 G.now 可能没有）
function INP.now() return (now and now()) or os.clock() end
-- 按住的记录放在 CHG 上（CHG 在观战 / 多人房按对手各一份，PEER.GLOB；远端编号各对手各自从 1 数，放全局会串）
function INP.heldT() CHG.inpHeld = CHG.inpHeld or {}; return CHG.inpHeld end

function INP.log(fmt, ...)
    INP.logN = INP.logN + 1
    if INP.logN <= 200 then out(fmt, ...) end      -- §432 60 → 200：11-24 那局 14:03 就用完，后面贪狼 / 金瓜按没按上看不到
end

function INP.off()
    local f = io.open(INP.OFF_FILE, "r")
    if f then f:close(); return true end
    return false
end

-- 放之前：名单里的招 → 替身按住这招的键。返回 是否按上了
function INP.press(pup, name, id)
    local ia = INP.KEYS[name]
    if not ia or not G.inputEnsure or INP.off() then return false end
    if INP.NEED_REL and INP.NEED_REL[name] and not CHG.peerRel then return false end   -- §432
    local comp, how = G.inputEnsure(pup)
    if how ~= "已有" then INP.log("输入实验：替身输入组件 %s", tostring(how)) end
    if not comp then return false end
    local list = type(ia) == "table" and ia or { ia }
    local any = false
    for _, one in ipairs(list) do
        local r, isH = G.inputHold(comp, one, true, G.worldTime(pup) or 0.0)     -- 值 = 按下时的世界时间（同玩家）
        INP.log("输入实验：远端#%d %s 放之前替身按住 %s：%s，IsHolding → %s", id, name, one:match("([%w_]+)$"), r, tostring(isH))
        any = any or isH == true
    end
    INP.heldT()[id] = { comp = comp, ia = list, name = name, ok = any, pup = pup, at = INP.now(),
                        minUntil = INP.MIN_HOLD[name] and (INP.now() + INP.MIN_HOLD[name]) or nil }
    return any
end

-- 对方松手到点 → 替身松开
function INP.release(id, why)
    local h = INP.heldT()[id]
    if not h then return end
    INP.heldT()[id] = nil
    local af = INP.AFTER[h.name]
    if af and h.pup and why ~= "技能结束" and why ~= "没放出来" and why ~= "重置" then
        INP.after[id] = { name = h.name, pup = h.pup, at = INP.now() + af.grace, endm = af.endm, why = why }
    end
    for _, one in ipairs(type(h.ia) == "table" and h.ia or { h.ia }) do
        -- §432 连招（铁拳套 A→AA→AAA、金瓜按住连击）下一招放之前已经按上同一个键：上一招到点松手别把下一招的也松了
        local other = INP.otherHolder(id, h.comp, one)
        if other then
            INP.log("输入实验：远端#%d 到点（%s）但远端#%d 还按着 %s → 不松", id, why, other, one:match("([%w_]+)$"))
        else
            local r, isH = G.inputHold(h.comp, one, false)
            INP.log("输入实验：远端#%d 替身松开 %s（%s）：%s，IsHolding → %s", id, one:match("([%w_]+)$"), why, r, tostring(isH))
        end
    end
end

-- 别的远端招还按着同一个替身输入组件上的同一个键 → 返回那个招号
function INP.otherHolder(id, comp, one)
    for oid, o in pairs(INP.heldT()) do
        if oid ~= id and (o.comp == comp or (sameObj and sameObj(o.comp, comp))) then
            for _, k in ipairs(type(o.ia) == "table" and o.ia or { o.ia }) do
                if k == one then return oid end
            end
        end
    end
    return nil
end

-- 按住期结束的几个地方都叫这个（没按着的招什么都不做）。soft = 对方松手到点（MIN_HOLD 没到就先记着，INP.tick 到点再松）
function INP.done(id, why, soft)
    local h = INP.heldT()[id]
    if not h then return end
    if soft and h.minUntil and INP.now() < h.minUntil then
        if not h.defer then INP.log("输入实验：远端#%d %s %s，至少按住 %.1f 秒 → 到点再松", id, h.name, why, INP.MIN_HOLD[h.name] or 0) end
        h.defer = why
        return
    end
    INP.release(id, why)
end

-- 每帧（CHG.pupStep 开头）：MIN_HOLD 到点的松开；AFTER 松开后技能还挂着的收掉。都空时不读
function INP.tick(tn)
    local t = INP.now()
    for id, h in pairs(INP.heldT()) do
        if h.defer and h.minUntil and t >= h.minUntil then INP.release(id, h.defer .. "（按满最短时间）") end
    end
    if not next(INP.after) then return end
    for id, a in pairs(INP.after) do
        if t >= a.at then
            INP.after[id] = nil
            local pup = a.pup
            local live = valid(pup) and LO and LO.activeInstance and LO.activeInstance(pup, a.name)
            local m = live and montageOf(pup) or ""
            if live and m ~= a.endm then
                local gone = {}
                if G and G.cancelAbilities then
                    local okC, r = pcall(G.cancelAbilities, pup, function(n) return n == a.name end)
                    if okC and type(r) == "table" then gone = r end
                end
                local okE = a.endm and CHG.spinPlay(pup, a.endm)
                INP.log("输入实验：远端#%d %s 替身松开 %.1f 秒后技能还在（动作 %s）→ 取消技能 %s，补播收招 %s", id, a.name,
                    INP.AFTER[a.name] and INP.AFTER[a.name].grace or 0, m ~= "" and m or "无", #gone > 0 and table.concat(gone, ",") or "（没取消掉）",
                    okE and "成功" or "失败")
            elseif live then
                INP.log("输入实验：远端#%d %s 替身松开后自己进了收招（%s）", id, a.name, m)
            end
        end
    end
end

function CHG.laserLog(fmt, ...)
    CHG.LASER.logN = CHG.LASER.logN + 1
    if CHG.LASER.logN <= 40 then out(fmt, ...) end
end

-- 这一招最多等多久（判定窗口 / 记录保留）
function CHG.maxAge(name)
    if CHG.VEHICLE and CHG.VEHICLE.names[name] then return CHG.VEHICLE.MAX end      -- §437 马车骑 10 秒以上：记录（和按住的键）留到 MAX，不在 8 秒 + 2 过期松键
    if SHOT and SHOT.FAM[name] then return math.max(CHG.JUDGE_MAX, SHOT.FAM[name].endMax or SHOT.END_MAX) end   -- §377 一招里好几发：等到对方收招
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
        local okR = RECM.activateOnPuppet(pup, f.name, NET.sub, "远端#" .. id .. " 激光续放")
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
    local p1 = PEER.tgt()
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
    local hasP, hasMe = CHG.hasTag(pup, L.EYE_TAG), CHG.hasTag(PEER.tgt(), L.EYE_TAG)
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

-- §243 对方松手到点：D 类"一直等松手"的招以前只停蓄力动作，松手后的那一刀没放。
-- 资产名字表里 Iron/Long BCharge 的 K2_ActivateAbility 用 ForceActivateExternalActionAbilityByTag 放另一个技能，
-- 替身没有输入组件 / OnRelease 任务，永远走不到；这里替它做：取消蓄力技能 → 补前置 GE → 激活释放招。
-- 只在一开始那招的蓄力动作上做（已经换成下一刀就不动，避免和对方真发来的释放招重复）。
function CHG.releaseTo(pup, id, f, tn, secs)
    local m = montageOf(pup)
    local onFirst = (not f.first) or m == f.first
    local rel = CHG.REL[f.name]
    if onFirst then
        local stopped = cutMontage(pup)
        CHG.cutN = CHG.cutN + 1
        if CHG.cutN <= 30 then
            out("蓄力松手：远端#%d %s 替身按 %.2f 秒松手（晚 %.2f 秒）→ 停掉蓄力动作 %s", id, f.name, secs,
                tn - f.at - secs, tostring(stopped))
        end
    end
    if not rel or not onFirst or f.relFired then return end
    f.relFired = true
    local gone = {}
    if G and G.cancelAbilities then
        local okC, r = pcall(G.cancelAbilities, pup, function(n) return n == f.name end)
        if okC and type(r) == "table" then gone = r end
    end
    local pre = rel.pre or (CHG.PRE and CHG.PRE[rel.name])
    if pre and CHG.upgrade then pcall(CHG.upgrade, pup, rel.name, pre) end
    local ok = false
    if RECM and RECM.activateOnPuppet then
        local okP, r = pcall(RECM.activateOnPuppet, pup, rel.name, (NET and NET.sub) or {}, "蓄力松手 远端#" .. id)
        ok = okP and r == true
    end
    CHG.relN2 = (CHG.relN2 or 0) + 1
    if CHG.relN2 <= 30 then
        out("  §243 蓄力松手：远端#%d %s → 取消蓄力技能 %s，放释放招 %s %s", id, f.name,
            #gone > 0 and table.concat(gone, ",") or "（已经没在放）", rel.name, ok and "成功" or "失败")
    end
    if not ok and PRETRY then PRETRY.push(pup, rel.name, (NET and NET.sub) or {}, "蓄力松手 远端#" .. id, 0.15, "释放招等标签") end
end

-- ============================================================ §407 / §409 按住持续类：对方屏幕上看不到后续动作
-- 11-19 伊格尼斯："在线 PVP 用特殊攻击（防御+重攻击）只显示前 3 次攻击旋转的动作，后续按住不在对方屏幕上显示动作，但实际生效"。
-- 收方日志（mp_probe (34).log）证实：08:21:17 对方按下特殊攻击，替身放出来 → 1 秒后动作就从
--   Hun_YanYueDao_Skill_01_A_Montage 跳到 Hun_YanYueDao_Skill_01_End_Montage，整段 8.03 秒里 Loop 一次都没出现；
-- 自己放同一招（07:59:24–29）是 A → Loop → End，由 IsHolding 决定停多久。替身是 AIController、没有输入组件（§92 / §140 实验 3），
-- 所以只播开招段就自己收招，后面只剩"平移"。
-- 做法：收方自己把中间那段补上——只播动作，不动技能本身（判定窗口 / 伤害 / 杀气都不碰）。
--   ① 有循环段（Loop）的招：替身动作进了收招 / 空了 / 开招段停太久 → playNamed(Loop)；松手到点补一次 End。
--   ② 没有循环段、中段是几个动作轮着放的（偃月刀大招 = Start → Dodge_L / Dodge_R → End）→ 按 seq 顺序轮播。
--   ③ 表里没有的按住招：只在整段动作真的空了时重播一次开招段（兜底，别乱插）。
--   ④ 显式表没有、但开招段名字能推出 _Loop_Montage 且资产真的在（推导一次、缓存）→ 按 ① 处理。
-- 名字来源：偃月刀两条来自玩家日志；其余带 Start / Loop / End(Stop) 三段的来自资产表
--   `_tools/gasgraph/按住松手招_全表.csv`（GA_JinGua_RoAttack / GA_Hun_Lute_SKill / GA_TanLang_Normal / GA_Hun_ShachiHook_HookMove）。
CHG.SPIN_MAX = 9.0          -- 对方按住的上限（游戏自己 8.02 秒就"按太久"）
CHG.SPIN_A = 1.2            -- 开招段最多停留这么久还没换动作，就当游戏没换、补下一段
CHG.SPIN_TRY = 0.2          -- 补动作 / 补收招的最小间隔
CHG.SPIN_SEQ_GAP = 0.9      -- seq 模式每个动作轮播多久
CHG.SPIN = {
    -- a = 开招段，loop = 按住循环段，endm = 收招段（三段都是独立蒙太奇资产）
    GA_Hun_YanYueDao_SpecialSkill_C = { a = "Hun_YanYueDao_Skill_01_A_Montage",
                                        loop = "Hun_YanYueDao_Skill_01_Loop_Montage",
                                        endm = "Hun_YanYueDao_Skill_01_End_Montage" },
    -- 大招没有循环段：中段是左右闪身突进两个动作交替（自己放：08:00:42 Start → :44 Dodge_L → :44 Dodge_R → :45 End）
    GA_Hun_YanYueDao_C_C = { a = "Hun_YanYueDao_Skill_03_Start_Montage", after = 2.2,
                             seq = { "Hun_YanYueDao_Skill_03_Dodge_L_Montage", "Hun_YanYueDao_Skill_03_Dodge_R_Montage" },
                             endm = "Hun_YanYueDao_Skill_03_End_Montage" },
    -- 资产表里带 Start / Loop / End(Stop) 三段的按住招
    GA_JinGua_RoAttack = { a = "Hun_ShaChi_JinGua_Skill_06_Start_Montage",
                           loop = "Hun_ShaChi_JinGua_Skill_06_Loop_Montage",
                           endm = "Hun_ShaChi_JinGua_Skill_06_Stop_Montage" },
    GA_Hun_Lute_SKill = { a = "Hun_ShaChi_Lute_Skill_01_Start_Montage",
                          loop = "Hun_ShaChi_Lute_Skill_01_Loop_Montage",
                          endm = "Hun_ShaChi_Lute_Skill_01_End_Montage" },
    GA_TanLang_Normal = { a = "Hun_LangYa_Skill_01_Start_Montage",
                          loop = "Hun_LangYa_Skill_01_Loop_Montage",
                          endm = "Hun_LangYa_Skill_01_End_Montage" },
    GA_Hun_ShachiHook_HookMove = { a = "ShaChi_Hook_Skill_02_Start_Montage",
                                   loop = "ShaChi_Hook_Skill_02_Loop_Montage",
                                   endm = "ShaChi_Hook_Skill_02_End_Montage" },
}
-- 这些按住招已经有画面同步，不要抢：紫冥剑召唤（§111 sub= 播召唤循环）、独眼弓激光（§139 一段一段续放）
-- §420.2 巨凶斧蓄力是"蓄 → 一次出手"，不是按住持续：11-23 替身 Release_01 播完、对方松手还没到（§420 之前多人房里要等 7 秒），
-- 兜底把蓄力动作重播一两遍 = 劈完又摆回蓄力姿势。档位 / 出手交给 §420.1
CHG.SPIN_SKIP = { GA_Hun_ZiMingJian_New_DB_C = true, GA_DuYan_Bow_Laser_C = true, GA_BrutalAxe_Normal_C = true }
-- 替身这招的技能自己结束了就不再补播（11-23 贪狼按住转圈：替身技能 3.83–3.90 秒自己结束、狼牙武器跟着收掉，
-- 续转还按对方按住的 6–9.5 秒接着补循环段 → 对方屏幕上只剩角色空手在转。15:13:50 / 15:13:52 两次补播都在技能结束之后）。
-- 只对"技能结束就藏影之武装"的招开（资产里引用 UE_DoHide，按住松手招_全表 38 招里扫出 12 个，加上表里的钩爪 HookMove）：
-- 偃月刀 / 混沌钢形态这类主武器招没有，替身没输入就提前结束技能的正是靠续转补画面，不能一刀切。
-- 11-23 用户"长柄金瓜也看一下"：11-20 / 11-22 日志里金瓜按住连击 / 空中 / 旋转在替身技能结束后还在兜底重播开招段。
CHG.SPIN_STOP_ON_END = {
    GA_TanLang_Normal_C = true,
    GA_JinGua_Normal_C = true, GA_JinGua_Air_C = true, GA_JinGua_RoAttack_C = true,
    GA_HuangJinHuoChong_Normal_02_C = true, GA_HuangJinHuoChong_Normal_04_C = true,
    GA_Hun_Lute_SKill_C = true, GA_Hun_ShachiHook_HookMove_C = true, GA_YouLongHead_Water_C = true, GA_ZhuoBiDun_C = true,
    GA_ThunderSpear_Normal_01_C = true, GA_ThunderSpear_Normal_02_C = true, GA_ThunderSpear_Normal_03_C = true,
}
CHG.SPIN_ENDCHK = 0.25      -- 查技能还在不在的间隔（要遍历技能表，别每帧）
CHG.SPIN_DERIVED = {}
CHG.spinN, CHG.SPIN_LOGS = 0, 30
function CHG.spinLog(fmt, ...)
    CHG.spinN = CHG.spinN + 1
    if CHG.spinN <= CHG.SPIN_LOGS then out(fmt, ...) end
end
-- 开招段名字 → { loop, endm }（推导一次缓存；循环段资产不在内存里就当不认识，返回 nil）
function CHG.spinDerive(a)
    if not a or a == "" then return nil end
    local c = CHG.SPIN_DERIVED[a]
    if c ~= nil then return (c ~= false) and c or nil end
    local function rep(s, from, to) return (s:gsub(from, to)) end
    local loop = rep(rep(rep(a, "_Start_ForBlocker_Montage$", "_Loop_Montage"), "_Start_Montage$", "_Loop_Montage"), "_A_Montage$", "_Loop_Montage")
    local endm = rep(rep(rep(a, "_Start_ForBlocker_Montage$", "_End_Montage"), "_Start_Montage$", "_End_Montage"), "_A_Montage$", "_End_Montage")
    if loop == a or not (G and G.montageByName and G.montageByName(loop, true)) then
        CHG.SPIN_DERIVED[a] = false
        return nil
    end
    c = { a = a, loop = loop, endm = (endm ~= a) and endm or nil }
    CHG.SPIN_DERIVED[a] = c
    return c
end
-- 受击 / 格挡 / 破防这些动作盖在上面时不抢（那是真的在挨打 / 防御）
function CHG.spinBusy(m)
    return m ~= "" and (m:find("_Hit_", 1, true) or m:find("Deflect", 1, true) or m:find("MoTian_Dodge", 1, true)
        or m:find("BreakEscape", 1, true) or m:find("Break_", 1, true))
end
-- 播一个动作。循环段可能还没被加载过（替身从没播到过它）→ 让 montage 表重扫一次再试
function CHG.spinPlay(pup, name)
    if not name or name == "" then return false end
    local ok, r = pcall(playNamed, pup, name)
    if ok and r then return true end
    if G and G.montageByName then pcall(G.montageByName, name, true) end
    local ok2, r2 = pcall(playNamed, pup, name)
    return (ok2 and r2) and true or false
end
-- §409.1 对方已经放了下一招（攻击 / 闪避 / 跳 / 切刀），这一招的按住期就结束了，不再补播任何段。
-- 11-22 实战日志：对方混沌钢形态蓄力重（GA_Hun_Chaos_B_Hold_Physics_C，不在 SPIN 表，走兜底）0.79 秒就闪避取消，
-- 替身技能也在 0.79 秒结束；但对方回报的松手是"按了 13.10 秒"，兜底照样每 1.2 秒重播开招段（13:03:04 第 1 次），
-- 13:03:05 我掉 -696 / 杀气 -272（同一局正常命中的这招 177–180，且那时对方伤害放大更高）。
-- 对方出了下一招时这边还在重播带攻击判定的蓄力动作 = 对方屏幕上不存在的攻击。只看"之后有没有放别的招"，不按伤害封顶。
CHG.lastFire = nil
function CHG.endsHold(name, attack)
    if attack then return true end
    if type(name) ~= "string" then return false end
    return (name:find("Dash", 1, true) or name:find("Dodge", 1, true) or name:find("_Jump", 1, true)
        or name:find("_SWT", 1, true)) and true or false
end
-- 远端每个出招事件（AIR.fire 一进来就记；同一招重放 / 等前摇是同一个编号，不算下一招）
function CHG.onAnyFire(pup, e, tn, attack)
    if not (e and e.id and e.name and tn) or not CHG.endsHold(e.name, attack) then return end
    CHG.lastFire = { id = e.id, name = e.name, at = tn, pup = pup }
end
-- 同一把武器的子技能（按住期间游戏自己激活的同族 GA）不算"下一招"：只认别的武器族 / 通用闪避
function CHG.family(n)
    return type(n) == "string" and n:match("^GA_Hun_([^_]+)_") or nil
end
function CHG.sameFamily(a, b)
    local fa, fb = CHG.family(a), CHG.family(b)
    return fa ~= nil and fa == fb
end
function CHG.movedOn(pup, id, f)
    local lf = CHG.lastFire
    if not (lf and f and f.at and lf.id ~= id and lf.at > f.at) then return nil end
    if CHG.sameFamily(lf.name, f.name) then return nil end
    if lf.pup ~= nil and pup ~= nil and lf.pup ~= pup and not (sameObj and sameObj(lf.pup, pup)) then return nil end
    return lf
end

-- 每帧：替身放的这一招还在按住期，就保证一直有动作
function CHG.spinStep(pup, id, f, tn)
    local s = f.spin
    if not s or not valid(pup) or s.done then return end
    if f.shot and SHOT.FAM[f.name] and SHOT.FAM[f.name].noSpin then return end   -- §427 独眼弓按对方每一发出箭，不重播拉弓
    local nextFire = CHG.movedOn(pup, id, f)
    if nextFire then
        s.done = true
        INP.done(id, "对方放了下一招")
        CHG.spinLog("§409.1 续转停：远端#%d %s 对方已放下一招 远端#%d %s（放出后 %.2f 秒）→ 不再补播", id, f.name,
            nextFire.id, nextFire.name, nextFire.at - f.at)
        return
    end
    local m = montageOf(pup)
    -- 开招段：放出来之后第一次读到的动作（只在这招真的在跑时认，免得拿到上一招的收尾动作）
    if not s.a then
        if m == "" or (LO and LO.activeInstance and not LO.activeInstance(pup, f.name)) then return end
        s.a = m
    end
    if CHG.SPIN_STOP_ON_END[f.name] and LO and LO.activeInstance and tn >= (s.endChkAt or 0) then
        s.endChkAt = tn + CHG.SPIN_ENDCHK
        if not LO.activeInstance(pup, f.name) then
            s.done = true
            INP.done(id, "技能结束")
            CHG.spinLog("§407 续转停：远端#%d %s 替身技能自己结束了（放出后 %.2f 秒，补了 %d 次）→ 不再补播（武器已收）",
                id, f.name, tn - f.at, s.n or 0)
            return
        end
    end
    -- 表里写的是资产名（不带 _C），出招名带 _C：以前一直对不上、全走推导；金瓜旋转推导出的收招 _End_Montage
    -- 不存在（真的是 _Stop_Montage），游戏自己播 Stop 时认不出来，要等 2.5 秒动作空了才补循环段
    -- 11-23 双开：替身按住键生效（IsHolding 读回 true）时游戏自己进 Loop，别再补（金瓜旋转 22:28:20 把开招段当收招多补了一次）
    local h = INP and INP.heldT and INP.heldT()[id]
    if h and h.ok then return end
    local sp = CHG.SPIN[f.name] or CHG.SPIN[(f.name:gsub("_C$", ""))] or CHG.spinDerive(s.a)
    local secs = CHG.rel[id]
    local over = (secs and tn >= f.at + secs) or (tn - f.at >= CHG.SPIN_MAX)
    if over then
        s.done = true
        INP.done(id, secs and "对方松手" or "按住超过上限", secs ~= nil)
        if sp and sp.endm and (s.loop or s.seqI) then
            -- 松手：替身那边早就进过收招了，这里再补一次让它收得干净（技能本身不用管）
            CHG.spinPlay(pup, sp.endm)
            CHG.spinLog("§407 续转：远端#%d %s %s → 补播收招 %s（按了 %.2f 秒，补了 %d 次）", id, f.name,
                secs and "对方松手" or string.format("按住超过 %.0f 秒", CHG.SPIN_MAX), sp.endm, secs or (tn - f.at), s.n or 0)
        end
        return
    end
    if CHG.spinBusy(m) then return end                    -- 真在挨打：不抢
    if not sp then
        -- 不认识的按住招：只有动作真的空了才补一下开招段（别的都不碰）
        if m == "" and tn - f.at > 0.8 and tn >= (s.fbAt or 0) then
            s.fbAt = tn + 1.2
            local okA = CHG.spinPlay(pup, s.a)
            if okA then s.n = (s.n or 0) + 1 end
            CHG.spinLog("§407 续转：远端#%d %s 没动作了（没有循环段可补）→ %s开招段 %s（第 %d 次）", id, f.name,
                okA and "重播" or "也没播成", s.a, s.n or 0)
        end
        return
    end
    if sp.seq then
        -- 没有循环段：中段几个动作按顺序轮播（等开招段放完 after 秒再开始）
        if m == sp.a and (tn - f.at) < (sp.after or CHG.SPIN_A) then return end
        if tn < (s.seqAt or 0) then return end
        local i = ((s.seqI or 0) % #sp.seq) + 1
        local name = sp.seq[i]
        if CHG.spinPlay(pup, name) then
            s.seqI, s.seqAt, s.n = i, tn + CHG.SPIN_SEQ_GAP, (s.n or 0) + 1
            CHG.spinLog("§407 续转：远端#%d %s 替身%s → 补播中段 %s（+%.2f 秒，第 %d 次）", id, f.name,
                (m == sp.a) and "还在开招段" or ((m == "" and "没动作了") or ("进了收招（" .. m .. "）")), name, tn - f.at, s.n)
        end
        return
    end
    if s.loop and m == sp.loop then return end            -- 已经在转
    -- 该补 Loop 的时机：游戏自己进了收招、动作空了、或开招段停太久没换
    local need = (m == sp.endm) or (m == "") or (m == sp.a and (tn - f.at) > CHG.SPIN_A)
    if not need or tn < (s.tryAt or 0) then return end
    s.tryAt = tn + CHG.SPIN_TRY
    if CHG.spinPlay(pup, sp.loop) then
        s.loop, s.n = true, (s.n or 0) + 1
        CHG.spinLog("§407 续转：远端#%d %s 替身%s → 补播循环 %s（+%.2f 秒，第 %d 次）", id, f.name,
            (m == "" and "没动作了") or ("进了收招（" .. m .. "）"), sp.loop, tn - f.at, s.n)
    elseif tn >= (s.fbAt or 0) then
        -- 循环段加载不到：退回每秒重播一次开招段，至少别是"站着平移"
        s.fbAt = tn + 1.0
        local okA = CHG.spinPlay(pup, sp.a)
        CHG.spinLog("§407 续转：远端#%d %s 循环段播不了 → %s开招段 %s（第 %d 次）", id, f.name,
            okA and "重播" or "也没播成", sp.a, (s.fbN or 0) + 1)
        if okA then s.fbN = (s.fbN or 0) + 1 end
    end
end

-- 每帧：替身按对方的秒数松手；"一直等松手"的招还在蓄力动作上就停掉
function CHG.pupStep(pup, tn)
    for id, f in pairs(CHG.fired) do
        CHG.selfStep(pup, id, f, tn)
        CHG.stageStep(pup, id, f, tn)       -- §420.1
        CHG.laserStep(pup, id, f, tn)       -- §139
        CHG.spinStep(pup, id, f, tn)        -- §407
        if f.shot then SHOT.pupStep(pup, id, f, tn) end   -- §377
        if f.hj then HJHC.step(pup, id, f, tn) end        -- §446
        local secs = CHG.rel[id]
        if CHG.VEHICLE.names[f.name] and valid(pup) then
            if secs and tn >= f.at + secs then CHG.vehicleOff(pup, id, f, tn, string.format("对方按了 %.2f 秒", secs))
            elseif not secs and tn - f.at > CHG.VEHICLE.MAX then CHG.vehicleOff(pup, id, f, tn, "没等到松手") end
        end
        if not f.done and secs and tn >= f.at + secs then
            f.done = true
            INP.done(id, string.format("对方按了 %.2f 秒", secs), true)
            if CHG.WAIT[f.name] and valid(pup) then CHG.releaseTo(pup, id, f, tn, secs) end
        elseif f.at and tn - f.at > (((SHIELD and SHIELD.is and SHIELD.is(f.name)) and (SHIELD.HOLD_MAX or CHG.maxAge(f.name)))     -- §439 举盾按住的键留到 HOLD_MAX
                                     or (f.spin and math.max(CHG.maxAge(f.name), CHG.SPIN_MAX) or CHG.maxAge(f.name))) + 2 then
            INP.done(id, "记录过期")
            CHG.fired[id] = nil end        -- §407 按住旋转类的记录留到 SPIN_MAX（判定窗口仍按 maxAge，不改）
    end
end

-- 中招之后的"同一招后续段接着累加"（NET.lastHit）过了 JUDGE_WIN 还要不要留着（11-23 双开实测：金瓜按住连击前三下各 -129 都记上，
-- 第四段下砸 -414 和地波 -129 在第三下后约 2 秒才落，lastHit 已过期 → 血照扣、没记到这一招、也没回报对方）。
-- 蓄力 / 按住类招、替身这招的技能还在放、没超过 maxAge、对方松手后不超过 HOLD_HIT_TAIL 秒 → 留着。查技能每 0.2 秒一次
CHG.HOLD_HIT_TAIL = 2.5
function CHG.holdHit(lh, tn)
    local id = lh and lh.r and lh.r.atk
    local f = id and CHG.fired[id]
    if not (f and f.name and CHG.isHold(f.name)) then return false end
    local age = tn - f.at
    if age > CHG.maxAge(f.name) then return false end
    local secs = CHG.rel[id]
    if secs and age > secs + CHG.HOLD_HIT_TAIL then return false end
    if lh.liveAt and tn - lh.liveAt < 0.2 then return lh.live end
    local pup = G.puppet and G.puppet()
    local live = (valid(pup) and LO and LO.activeInstance and LO.activeInstance(pup, f.name)) and true or false
    lh.liveAt, lh.live = tn, live
    if live and not lh.liveLogged then
        lh.liveLogged = true
        out("  远端#%d %s 中招后过了 %.1f 秒：替身这招还在放（蓄力 / 按住），后续段接着记到这一招", id, f.name, tn - lh.at)
    end
    return live
end

-- 判定窗口过了 JUDGE_WIN 时（netJudge）：这一招还要不要等。j = { id, at, name }，pupM = 替身现在的动作
function CHG.keepJudge(j, tn, pupM)
    local age = tn - j.at
    local late = j.name and CHG.LATE[j.name]
    if late and age < late then return true end
    if not (j.name and CHG.isHold(j.name)) or age > CHG.maxAge(j.name) then return false end
    local f = CHG.fired[j.id]
    if f and f.shot and not f.shot.done then return true end          -- §377 对方还在一发一发地射
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
    if next(INP.heldT()) or next(INP.after) then INP.tick(tn) end   -- §434 最短按住到点松开 / 松开后兜底收招
    if next(CHG.fired) then CHG.pupStep(pup, tn) end
    if CART and CART.live and #CART.live > 0 then CART.step(tn) end   -- §442 力荡判定到点收掉
    if SHIELD and SHIELD.step then SHIELD.step(tn) end     -- 11-23 举盾保持 + 盾反 / 盾推 / 盾冲的判定（都空时直接返回）
    if next(CHG.LASER.beams) then CHG.laserBeamStep(pup) end    -- §139.1 激光柱对准你 / 到点收
    if #CHG.list == 0 then return end
    if not CHG.probed and valid(pup) then
        CHG.probed = true
        for _, l in ipairs(G.inputProbe(p1, pup) or {}) do out("蓄力探针 输入系统：%s", l) end
    end
    local keep = {}
    for _, w in ipairs(CHG.list) do
        if CHG.stepOne(w, tn) then keep[#keep + 1] = w end
    end
    CHG.list = keep
end

-- §420 多人房 / 对决：每个对手一份 CHG（PEER.GLOB），CHG.step 只在 PEER.run 里驱动替身时跑、跑的是对手那份；
-- "我"放的蓄力招记在主状态（netSend 在 PEER 外面）里，以前没人检查 → 松手只能等"放了下一招"（§409.2）才补发，
-- 11-23 巨凶斧对方每次都报"按了 7 秒"。netSend 末尾、主状态没在驱动替身时（多人房 / 旧版 1v1 远端数据断了）调这个，
-- 只看"我"的条目；旧版 1v1 驱动替身时仍由 CHG.step 一起看，不重复
function CHG.mineStep(tn)
    if #CHG.list == 0 then return end
    local keep = {}
    for _, w in ipairs(CHG.list) do
        if w.who ~= "我" or CHG.stepOne(w, tn) then keep[#keep + 1] = w end
    end
    CHG.list = keep
end

-- 发送方"按太久"算松手的上限（秒）。11-24 拙壁盾（用户"没有将玩家释放的盾牌视为按住"）：举盾以前也按 JUDGE_MAX 8 秒截断——
-- 本机 14:20:06 举盾、14:20:24 才盾反（举了约 18 秒），对方日志却是"对方松手（按了 8.04 秒）"，替身 8 秒就收盾；
-- 同一场另两次 11 / 16 秒也都报成 8.01 / 8.02 秒。举盾跟收方的举盾保持（SHIELD.HOLD_MAX）一样等到 45 秒
function CHG.holdCap(name, veh)
    if veh then return CHG.VEHICLE.MAX end
    if SHIELD and SHIELD.is and SHIELD.is(name) then return SHIELD.HOLD_MAX or CHG.JUDGE_MAX end
    return CHG.JUDGE_MAX
end

-- 一条记录走一帧；返回 true = 留着
function CHG.stepOne(w, tn)
    do
        local m, sec, pos = G.montageSection(w.actor)
        local key = m and (m .. "|" .. sec) or ""
        if key ~= w.key then
            CHG.note(w, tn, m and string.format("%s[%s]@%.2f", m, sec, pos or -1) or "（没动作）")
            -- §92.8 不管读没读到输入，换到 Release / _End 动作都算松手：18:49:49 炽刃大招 2.18 秒切 _Release，
            -- 输入里还有别的键按着，拖到 5.06 秒技能结束才算。11-23 拙壁盾收盾叫 _Exit，也算松手（对方以前要等下一招才知道我放下了盾）
            if w.who == "我" and w.hold and w.key and m and not CHG.VEHICLE.names[w.name]
                and (m:find("Release", 1, true) or m:find("_End", 1, true) or (SHIELD and SHIELD.isExit and SHIELD.isExit(m))) then
                CHG.release(w, tn, "换到 " .. m)
            end
            -- §276.10（移植 0.33 分支 §269.15）马车：播到下车动作（AM_JumpOffHorseCart）就是松手。11-13 实测只认"技能结束"太晚：技能清单（NET.prevAbs）
            -- 观战 / 对局外不更新，下车后 93 秒才判出来，观战替身多驾 3 秒车（等自己的驾车动作播完）。持续型招的结束看发送方自己的状态变化
            if w.who == "我" and w.hold and m and CHG.VEHICLE.names[w.name] and m:find("JumpOff", 1, true) then
                CHG.release(w, tn, "下车 " .. m)
            end
            if w.who == "我" and w.stg and m and not w.stgN then CHG.stgMine(w, m, tn) end    -- §420.1 我出手是哪一档
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
        local veh = CHG.VEHICLE.names[w.name]      -- §276.9 马车：不认松键 / 8 秒截断，只认下车
        if w.who == "我" and w.hold and not w.relAt then
            if w.h0 and not veh and not w.stg then    -- §420.1 巨斧只认出手动作（开始时只按着点按键，一松就被当成松手）
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
        elseif tn - w.at >= CHG.holdCap(w.name, veh) then CHG.release(w, tn, "按太久"); CHG.finish(w, tn, "到时间")
        elseif tn - w.last >= CHG.QUIET then CHG.release(w, tn, "没动作"); CHG.finish(w, tn, "没动作、技能也结束了")
        else return true end
    end
    return false
end

-- ============================================================ §377 一个技能里点按出好几发的影之武装（羽弓 / 虎炮）
-- 11-17 玩家：羽弓点 Ctrl 连射三箭（扣 3 点暗源），对面看到的是一发蓄满、只吃一箭伤害；虎炮蓄不蓄力对面都是蓄满那一炮。
-- 日志：发送方一次 GA_UnnamedBow_C 里 Charge → Shoot_Normal 三回；替身 Charge → 2.96 秒 Shoot_Max 一发就收。
-- 原因：出哪一档、出几发是技能里按"现在按没按着"定的，替身没有输入组件（§140 造输入走不通），永远当一直按着 → 蓄满一发。
-- 做法（同 §276.10 马车：看发送方自己的状态变化，不靠按键 / 秒数）：
--   发：我播到这几招的出手动作 → 等最多 WAIT 秒看我名下新出现的子弹是哪一档（子弹数据 / 类名带 Normal / Max / Great / Perfect），
--       发 sub=<次数>:<出手动作>-<档位>；离开这把武器的动作 → 发 sub=<次数>:SHOTEND-<键>。状态包带 shs=1 表示我会发这些
--   收（对方 shs=1）：替身照常放这招（攻击力系数、判定窗口照旧），蓄力动作播到 pauseAt 秒暂停（不让它自己蓄满出手）；
--       每收到一发，用这招技能实例在替身身上生成那一档的子弹（同 §139.7 激光发射器：CreateBullet + Initialize + Start）；
--       收到 SHOTEND / 等太久 → 取消替身的这招、停掉蓄力动作。对方旧版（没有 shs=）照旧
SHOT = {
    FAM = {
        -- §429 羽弓也开 killNative（11.23 用户"羽弓蓄力攻击无效，会视为瞬发"）：本机 11-24 14:13 替身停在 0.5 秒仍自己射一支 Normal
        -- （"暂停没拦住"，对面看到瞬发、#460 还多扣一次），技能随之结束，对方满蓄的第二发 Max 到了"已经不在放了"被跳过。
        -- 三档子弹 B_UnnamedBow_Normal / Max / Perfect 都直接是一支箭（BP_UnnamedBow_*），不再生成别的子弹
        GA_UnnamedBow_C = { key = "UnnamedBow", charge = "AM_Hun_UnnamedBow_Charge", pauseAt = 0.5,
            killNative = true, nativeCls = "BP_UnnamedBow_",
            dir = "/PBZCombatAsset/ActorData/Players/Hun/BulletData/ShachiWeapon/",
            shots = { AM_Hun_UnnamedBow_Shoot_Normal = "Normal", AM_Hun_UnnamedBow_Shoot_Max = "Max" },
            tiers = { Normal = "B_UnnamedBow_Normal", Max = "B_UnnamedBow_Max", Perfect = "B_UnnamedBow_Perfect" } },
        -- §428 11-24 虎炮"蓄力提前出判定 / 偶尔多一发满蓄"：暂停蓄力动作拦不住技能自己的计时，替身约 3 秒自己补一发 Perfect
        -- （11-22 21:36 起每招都有"替身动作换成 AM_Hun_TigerCannon_Launch_Perfect（暂停没拦住）"）→ 用 §427 killNative 收掉它自己的炮弹。
        -- adopt：按对方出手生成后 ADOPT 秒内新出现的炮弹算我们的（生成的若是发射器、再出炮弹，不被当成替身自己的收掉）
        GA_TigerCannon_C = { key = "TigerCannon", charge = "AM_Hun_TigerCannon_Prepare", pauseAt = 0.8,
            killNative = true, nativeCls = "TigerCannon_Bullet", adopt = 0.3, killWin = 1.5,
            dir = "/PBZCombatAsset/ActorData/Players/Hun/BulletData/ShachiWeapon/TigerCannon/",
            shots = { AM_Hun_TigerCannon_Launch_NormalGreat = "Normal", AM_Hun_TigerCannon_Launch_Perfect = "Perfect" },
            tiers = { Normal = "B_TigerCannon_Normal", Great = "B_TigerCannon_Great", Perfect = "B_TigerCannon_Perfect" } },
    },
    TIER_ORDER = { "Perfect", "Great", "Max", "Normal", "Triple", "Double", "Single" },   -- 名字里找档位的顺序（NormalGreat 先认 Great）
    DATA_KEYS = { "BulletData", "Data", "CurrentBulletData", "BulletDataAsset" },
    WAIT = 0.25, END_GAP = 0.2, END_MAX = 12.0, UP = 60.0, FWD = 40.0, RESTART_BACK = 0.1, KILL_WIN = 0.6,
    byMon = {}, bdCache = {}, logN = 0, LOG_MAX = 160, probed = {},
    send = { known = {} },
}
SHOT.FAM.GA_TigerCannon_QuickCharge_C = {
    key = "TigerCannon", aliasOf = "GA_TigerCannon_C",
    charge = "Hun_ShaChi_DonCanon_SpecialAttack_02_Montage_01", pauseAt = 0.1,
    dir = SHOT.FAM.GA_TigerCannon_C.dir,
    shots = SHOT.FAM.GA_TigerCannon_C.shots,
    tiers = SHOT.FAM.GA_TigerCannon_C.tiers,
}
-- §427 普通独眼弓 R2（GA_DuYan_Bow_Normal_C）。11-24 用户"普通独眼弓的蓄力射击的问题"：
--   ① 一次按住射好几箭（拉满自己射、接着再拉），对面只有第一箭掉血：独眼弓借用羽弓的出手动作名，发送方按羽弓发 sub=，
--     收方找不到替身在放羽弓 → "§377 …跳过"；替身那一招只射它自己那 1 箭（11-22 起就这样）。
--   ② 替身一拉弓就射（0.63 秒，不等对方松手）：11-23 起 INP（72bae753）给替身建了输入组件，技能的等松手任务读到"没按着"
--     就马上射；以前没组件时替身 2.96 秒才射，CHG.SELF 在 1.55 秒停得住。资产：技能走 OnRelease / OnAlreadyRelease
--     （不是 IsHolding），子弹数据 BD_GA_DuYan_Bow_Normal_P1_01 / P2_01+P2_02 / P3_01（BP_PBZ_ProjectileBulletData，
--     直接是箭 BP_DuYanBow_Arrow），按住越久箭越多。
--   做法：和羽弓同一套 §377，但动作名和羽弓共用，所以 ① 发送方按"我身上挂着哪个技能"挑家族；② 档位用独眼弓自己的名字
--   （Single / Double / Triple，按子弹数据名里的 _P1_ / _P2_ / _P3_ 认，一档可以是好几支箭）；③ 只有发 shs=2 的新版
--   对方才走这条（旧版发的是羽弓档位，收方照旧让替身自己射）；④ 替身蓄力动作 0.3 秒停住，仍漏出它自己的箭就当场收掉
SHOT.FAM.GA_DuYan_Bow_Normal_C = {
    key = "DuYan_Bow", charge = "AM_Hun_UnnamedBow_Charge", pauseAt = 0.3, shareMon = true, needVer = 2,
    noSpin = true, killNative = true, nativeCls = "DuYanBow_Arrow", endMax = 30.0,
    dir = "/PBZCombatAsset/ActorData/Players/Hun/BulletData/DuYanBow/",
    shots = { AM_Hun_UnnamedBow_Shoot_Normal = "Single" },
    tiers = { Single = { "BD_GA_DuYan_Bow_Normal_P1_01" },
              Double = { "BD_GA_DuYan_Bow_Normal_P2_01", "BD_GA_DuYan_Bow_Normal_P2_02" },
              Triple = { "BD_GA_DuYan_Bow_Normal_P3_01" } },
    match = { Single = "_P1_", Double = "_P2_", Triple = "_P3_" },
}
SHOT.byTier = {}       -- §427 档位名 → 家族（只放独眼弓这种和别人共用动作名的）
for name, fam in pairs(SHOT.FAM) do
    fam.name = name
    if fam.shareMon then
        for t in pairs(fam.tiers) do SHOT.byTier[t] = name end
    elseif not fam.aliasOf then
        for m in pairs(fam.shots) do SHOT.byMon[m] = name end
    end
end

-- §427 这个出手 / 蓄力动作现在算哪一家：共用动作名的家族，技能挂在我身上才算（读不到技能表 → 按原来的）
function SHOT.famForMon(mon, isCharge)
    local abs = NET.prevAbs
    if type(abs) == "table" then
        for n, fam in pairs(SHOT.FAM) do
            if fam.shareMon and abs[n] and ((isCharge and fam.charge == mon) or (not isCharge and fam.shots[mon])) then return n end
        end
    end
    if isCharge then
        for n, fam in pairs(SHOT.FAM) do
            if fam.charge == mon and not fam.shareMon then return n end
        end
        return nil
    end
    return SHOT.byMon[mon]
end

function SHOT.log(fmt, ...)
    SHOT.logN = SHOT.logN + 1
    if SHOT.logN <= SHOT.LOG_MAX then out(fmt, ...) end
end

-- 名字里的档位（按 TIER_ORDER，fam.tiers 里有的才算）
function SHOT.tierIn(fam, s)
    if not s then return nil end
    for _, t in ipairs(SHOT.TIER_ORDER) do
        if fam.tiers[t] and s:find((fam.match and fam.match[t]) or t, 1, true) then return t end
    end
    return nil
end

-- 子弹的数据名（几个可能的变量名挨个试）
function SHOT.dataName(b)
    for _, k in ipairs(SHOT.DATA_KEYS) do
        local v = rawProp(b, k)
        if v ~= nil and valid(v) then return shortName(full(v)), k end
    end
    return nil
end

-- 我名下在跑的、这一招放出来的子弹：{ key = 全名, cls = 类名, data = 数据名 }
function SHOT.myBullets(p1, fam)
    local ok, l = pcall(function() return FindAllOf("BulletActorBase") end)
    local r = {}
    for _, b in ipairs(ok and l or {}) do
        if valid(b) and rawProp(b, "BulletStatus") == 2 and sameObj(rawProp(b, "BulletOwnerAvatar"), p1) then
            local src = rawProp(b, "BulletSourceAbility")
            local sn = valid(src) and shortName(full(src)) or ""
            if sn == "" or sn:find(fam.key, 1, true) then
                r[#r + 1] = { key = full(b), cls = shortName(full(b)), data = SHOT.dataName(b), src = sn }
            end
        end
    end
    return r
end

-- 发：这一发定下档位 → 发出去
function SHOT.emit(p1, s, tn)
    local fam = SHOT.FAM[s.fam]
    local tier, from = nil, "动作默认"
    for _, b in ipairs(SHOT.myBullets(p1, fam)) do
        if not SHOT.send.known[b.key] then
            SHOT.send.known[b.key] = true
            local t = SHOT.tierIn(fam, b.data) or SHOT.tierIn(fam, b.cls)
            if t and not tier then tier, from = t, string.format("子弹 %s / %s", tostring(b.cls), tostring(b.data)) end
        end
    end
    if not tier and tn - s.at < SHOT.WAIT then return false end      -- 子弹还没出来：下一帧再看
    tier = tier or fam.shots[s.mon]
    NET.subN, NET.subT = (NET.subN or 0) + 1, s.mon .. "-" .. tier
    SHOT.send.lastAt = tn
    SHOT.log("§377 我 %s 出手 %s → 发 %s 档（%s，%.2f 秒后）", s.fam, s.mon, tier, from, tn - s.at)
    return true
end

-- §424 这把武器的招还挂在我身上吗（NET.prevAbs = 这一帧 netSend 读的我的技能；读不到返回 nil = 不知道）
function SHOT.famOn(active)
    local abs = NET.prevAbs
    if type(abs) ~= "table" then return nil end
    local key = SHOT.FAM[active] and SHOT.FAM[active].key
    for n in pairs(abs) do
        local fam = SHOT.FAM[n]
        if fam and fam.key == key then return true end
    end
    return false
end

-- §424 同一个出手动作从头又播了一遍（移动中连射：Shoot_Normal 接 Shoot_Normal，动作名没变）→ 算新的一发
function SHOT.restarted(p1, hm)
    local S = SHOT.send
    if not (hm and SHOT.byMon[hm]) then S.shotPos = nil; return false end
    local _, _, m, pos = LAT.activeMontage(p1)
    if m ~= hm or type(pos) ~= "number" then return false end
    local again = S.shotPos ~= nil and pos + SHOT.RESTART_BACK < S.shotPos
    S.shotPos = pos
    return again
end

-- 发：每帧（netSend 里，hm = 我现在的动作，prev = 上一帧的）
function SHOT.mine(p1, hm, prev, tn)
    local S = SHOT.send
    if S.pend and SHOT.emit(p1, S.pend, tn) then S.pend = nil end
    local again = hm == prev and SHOT.restarted(p1, hm)
    if hm ~= prev then S.shotPos = nil; SHOT.restarted(p1, hm) end
    if (hm ~= prev or again) and hm then
        local name = SHOT.famForMon(hm, false)               -- §427 独眼弓和羽弓同名动作：按挂着的技能挑
        local cn = SHOT.famForMon(hm, true)
        if cn and S.active ~= cn then
            S.active, S.known = cn, {}
            for _, b in ipairs(SHOT.myBullets(p1, SHOT.FAM[cn])) do S.known[b.key] = true end   -- 起手时已经在场的不算
        end
        -- 虎炮快速蓄力（aliasOf）自己的蓄力动作照旧认
        for n, fam in pairs(SHOT.FAM) do
            if fam.aliasOf and hm == fam.charge and S.active ~= n then
                S.active, S.known = n, {}
                for _, b in ipairs(SHOT.myBullets(p1, fam)) do S.known[b.key] = true end
            end
        end
        if name then
            S.active = S.active or name
            -- §427 共用动作名的家族（独眼弓）：蓄力那一帧可能还没读到技能、先记成了羽弓，出手时改正，收招才发对的 key
            if SHOT.FAM[name].shareMon and S.active ~= name then S.active = name end
            if S.pend then SHOT.emit(p1, S.pend, tn + SHOT.WAIT); S.pend = nil end    -- 上一发还没定：按动作默认先发
            S.pend = { mon = hm, fam = name, at = tn }
            if SHOT.emit(p1, S.pend, tn) then S.pend = nil end
        end
    end
    -- 离开这把武器的动作：发结束（和上一发隔开 END_GAP，不然同一个包里 sub= 只剩最后一个）
    -- §424 技能还挂着就不算收招（用户 11.23"羽弓移动姿态第二箭和第三箭没伤害"：移动中拉弓是动画层、不播 Charge 蒙太奇，
    -- 两箭之间动作是空的 → 以前第一箭后就发 SHOTEND，对面把替身这招收了，后两箭到了"替身没在放这招，跳过"）。
    -- 读不到技能表时照旧按动作判；独眼弓借用同名出手动作，它放的时候羽弓技能不在 → 照旧马上收
    if S.active and not S.pend and hm ~= SHOT.FAM[S.active].charge
        and not (type(hm) == "string" and hm:find(SHOT.FAM[S.active].key, 1, true))
        and not (hm and SHOT.FAM[S.active].shots[hm])                    -- §427 独眼弓的出手动作名里没有它自己的 key
        and SHOT.famOn(S.active) ~= true
        and tn - (S.lastAt or -99) >= SHOT.END_GAP then
        NET.subN, NET.subT = (NET.subN or 0) + 1, "SHOTEND-" .. SHOT.FAM[S.active].key
        S.lastAt = tn
        SHOT.log("§377 我 %s 收招（动作 %s）→ 发 SHOTEND", S.active, tostring(hm))
        S.active = nil
    end
end

-- §427 dyb=1：另外会发普通独眼弓的每一发（独眼弓档位名）。shs= 不能改成 2：旧版收方只认 shs=1，会把羽弓 / 虎炮也关掉
function SHOT.wire() return "shs=1\ndyb=1\n" end
function SHOT.recv(v, dyb)
    NET.rshs = (v == "1")
    NET.rshsV = (v == "1") and ((dyb == "1") and 2 or 1) or 0
end

-- 收：sub= 里是不是这类（出手 / 结束）
function SHOT.isWire(sm)
    if not sm then return false end
    if sm:find("SHOTEND-", 1, true) == 1 then return true end
    local mon = sm:match("^(.-)%-%a+$")
    return mon ~= nil and SHOT.byMon[mon] ~= nil
end

-- 收：替身放出这一招（AIR.fire 放成功时）
function SHOT.onFire(pup, e, tn)
    local fam = SHOT.FAM[e.name]
    local f = CHG.fired[e.id]
    if not (fam and f) then return end
    if fam.aliasOf and ctx.quickShotCertified ~= true then
        -- Native replay blocks late shared-montage packets from reusing an older manual shot.
        f.nativeShot = true
        return
    end
    if not NET.rshs then return end
    if fam.needVer and (NET.rshsV or 0) < fam.needVer then return end      -- §427 对方旧版不发独眼弓的每一发：替身照旧自己射
    f.shot = { at = tn, n = 0, mine = {} }
    if fam.killNative then f.shot.inst = LO.activeInstance(pup, e.name) end  -- §427 技能自己收了也用这个实例生成箭
    SHOT.log("§377 替身放 远端#%d %s：对方会发每一发（shs=1）→ 蓄力动作到 %.2f 秒停住，按对方出手生成子弹", e.id, e.name, fam.pauseAt)
end

-- 这一招最近一次放出、还没收的那条
function SHOT.latest(name)
    local id, f = nil, nil
    local wanted = name and SHOT.FAM[name]
    for i, x in pairs(CHG.fired) do
        local fam = SHOT.FAM[x.name]
        if ((x.shot and not x.shot.done) or x.nativeShot)
            and (not name or (wanted and fam and fam.key == wanted.key))
            and (not id or i > id) then id, f = i, x end
    end
    return id, f
end

-- 子弹数据：先按数据资产找（B_x.B_x），再找蓝图类的默认对象（B_x.Default__B_x_C）。找到哪种记一次
function SHOT.bd(fam, tier, b)
    b = b or fam.tiers[tier]
    if not b then return nil, "没有这一档" end
    if type(b) == "table" then b = b[1] end
    local c = SHOT.bdCache[b]
    if c and valid(c.o) then return c.o, c.how end
    local p = fam.dir .. b
    local tries = { { p .. "." .. b, "数据资产" }, { p .. "." .. "Default__" .. b .. "_C", "类默认对象" } }
    for _, t in ipairs(tries) do
        local o = G.findOrLoad(t[1])
        if valid(o) then
            SHOT.bdCache[b] = { o = o, how = t[2] }
            SHOT.log("§377 子弹数据 %s：%s（%s）", b, t[2], full(o))
            return o, t[2]
        end
    end
    if type(LoadAsset) == "function" then pcall(LoadAsset, p) end       -- 类默认对象要类先加载
    local o = G.findOrLoad(p .. ".Default__" .. b .. "_C")
    if valid(o) then SHOT.bdCache[b] = { o = o, how = "加载类后的默认对象" }; return o, "加载类后的默认对象" end
    return nil, "找不到 " .. p
end

-- 出手的朝向：对方锁着你 / 没收到镜头朝向 → 对准你；否则对方镜头朝向（羽弓发 aim=）
function SHOT.aim(at, tn)
    local r = not NET.rlk and BOWAIM.peer(tn)
    if r then return { Pitch = r.Pitch, Yaw = r.Yaw }, "对方镜头" end
    local me = CHG.laserAimAt()
    if me and at then
        local dx, dy, dz = me.X - at.X, me.Y - at.Y, me.Z - at.Z
        return { Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), Yaw = math.deg(math.atan(dy, dx)) }, "对准你"
    end
    return { Pitch = 0, Yaw = 0 }, "没有目标"
end

-- 收：对方出手一发 / 收招。返回 是否处理了
function SHOT.onSub(pup, sm, tn)
    local endKey = sm:match("^SHOTEND%-(.+)$")
    if endKey then
        for id, f in pairs(CHG.fired) do
            local fam = SHOT.FAM[f.name]
            if fam and fam.key == endKey and f.shot and not f.shot.done then SHOT.finish(pup, id, f, tn, "对方收招") end
        end
        return true
    end
    local mon, tier = sm:match("^(.-)%-(%a+)$")
    local name = SHOT.byMon[mon]
    if not name then return false end
    local tf = SHOT.byTier[tier]                     -- §427 独眼弓的档位名 → 独眼弓（出手动作名和羽弓一样）
    if tf and SHOT.FAM[tf].shots[mon] then name = tf end
    local id, f = SHOT.latest(name)
    if not f then SHOT.log("§377 对方出手 %s %s 档：替身没在放这招（没放出来 / 对方是旧版放法），跳过", mon, tier); return true end
    if f.nativeShot then return true end
    name = f.name
    local fam = SHOT.FAM[name]
    if not valid(pup) then return true end
    local inst = LO.activeInstance(pup, name)
    if not inst and f.shot and f.shot.inst and valid(f.shot.inst) then inst = f.shot.inst end   -- §427 替身的技能自己收了：用放出时的实例
    if not inst then SHOT.log("§377 对方出手 %s 档：远端#%d 替身的 %s 已经不在放了", tier, id, name); return true end
    if not SHOT.probed[name] then                 -- 第一次：技能里和子弹有关的变量（查子弹数据放在哪）
        SHOT.probed[name] = true
        SHOT.log("§377 探针 %s 技能变量（Bullet）：%s", name, tostring(LO.propsLike(inst, { "Bullet" })))
    end
    local list = fam.tiers[tier]
    list = type(list) == "table" and list or { list }
    local bds = {}
    for _, b in ipairs(list) do
        local bd, how = SHOT.bd(fam, tier, b)
        if not bd then SHOT.log("§377 对方出手 %s 档：子弹数据%s", tier, tostring(how)); return true end
        bds[#bds + 1] = bd
    end
    local loc = try("shot loc", function() return pup:K2_GetActorLocation() end)
    if not loc then SHOT.log("§377 对方出手 %s 档：读不到替身位置", tier); return true end
    local rot0, aimHow = SHOT.aim(loc, tn)
    local y = math.rad(rot0.Yaw or 0)
    local at = { X = loc.X + math.cos(y) * SHOT.FWD, Y = loc.Y + math.sin(y) * SHOT.FWD, Z = loc.Z + SHOT.UP }
    local rot = SHOT.aim(at, tn)
    G.setControlRot(pup, rot); setYaw(pup, rot.Yaw)
    local tc = LO.targetingComp(pup)                 -- 子弹按锁定目标找人（BP_BulletTargetSelector_LockTarget）：同火枪 / 眼睛
    if tc then ZMX.tcLock(tc); if not NET.rlk then ZMX.tcUnlockAt = math.max(ZMX.tcUnlockAt or 0, tn + 3.0) end end
    f.shot.n = f.shot.n + 1
    for k, bd in ipairs(bds) do                      -- §427 独眼弓一档可以是好几支箭（P2 = 两支）
        local e, info = G.laserEmitterSpawn(inst, pup, at, rot, bd)
        if e and f.shot.mine then f.shot.mine[full(e)] = true end
        if fam.adopt then f.shot.adoptUntil = tn + fam.adopt end      -- §428 之后一小段新出的炮弹也算我们的
        SHOT.log("§377 对方出手 %s %s 档 → 远端#%d 替身第 %d 发%s：%s（%s；瞄 %s P%.0f Y%.0f）", mon, tier, id, f.shot.n,
            #bds > 1 and string.format("（第 %d / %d 支）", k, #bds) or "",
            e and G.emitterInfo(e) or "没生成", tostring(info), aimHow, rot.Pitch or 0, rot.Yaw or 0)
    end
    return true
end

-- §427 替身自己射出来的箭（不是按对方出手生成的）：当场收掉，免得多一箭 / 早一箭。返回 收掉几支
function SHOT.killNative(pup, id, f, tn)
    local fam, s = SHOT.FAM[f.name], f.shot
    local ok, l = pcall(function() return FindAllOf("BulletActorBase") end)
    local n = 0
    for _, b in ipairs(ok and l or {}) do
        if valid(b) and rawProp(b, "BulletStatus") == 2 and sameObj(rawProp(b, "BulletOwnerAvatar"), pup) then
            local key = full(b)
            if not s.mine[key] and not s.killed[key] and key:find(fam.nativeCls, 1, true) then
                -- §444 替身自己出手的窗口里（killUntil）不认领：11-25 不蓄力那一发对方 ~1.15 秒就出手，正好和替身自己
                -- 补的 Launch_NormalGreat 同一刻，认领窗口把替身那颗也记成"我们的" → 两颗炮弹两次爆炸（619 / 761，蓄满只有 560）。
                -- 我们生成的那颗已经在 s.mine 里，爆炸是 OverlapBullet（类名不带 TigerCannon_Bullet），都不会被误收
                if s.adoptUntil and tn <= s.adoptUntil and not (s.killUntil and tn <= s.killUntil) then   -- §428 刚按对方出手生成过：这颗算我们的
                    s.mine[key] = true
                    SHOT.log("§428 远端#%d %s 生成后新出现的 %s 记成对方出手那一发（不收）", id, f.name, key:match("^(%S+)") or key)
                else
                    s.killed[key] = true
                    if pcall(function() b:Deactivate(0.0) end) then n = n + 1 end
                end
            end
        end
    end
    if n > 0 then
        s.killN = (s.killN or 0) + n
        SHOT.log("§427 远端#%d %s 替身自己射了 %d 支箭（不是对方出手）→ 收掉（这一招共收 %d 支）", id, f.name, n, s.killN)
    end
    return n
end

-- 收：每帧（CHG.pupStep 里）：蓄力动作到点停住；替身自己出手了记一笔；等太久就收
function SHOT.pupStep(pup, id, f, tn)
    local s = f.shot
    if not s or s.done then return end
    local fam = SHOT.FAM[f.name]
    if not valid(pup) then s.done = true; return end
    if tn - s.at > (fam.endMax or SHOT.END_MAX) then SHOT.finish(pup, id, f, tn, "等太久没收到收招"); return end
    if fam.noSpin then                               -- §427 没等到收招、对方已经放了下一招 → 也收
        local nf = CHG.movedOn(pup, id, f)
        if nf then SHOT.finish(pup, id, f, tn, string.format("对方已放下一招 远端#%d %s", nf.id, tostring(nf.name))); return end
    end
    local _, _, m, pos = LAT.activeMontage(pup)
    if fam.killNative then
        -- 替身动作换成出手动作 = 它自己射了：之后 KILL_WIN 秒里每帧找它自己的箭收掉（只在这段时间扫，不常驻）
        if m ~= s.lastM and fam.shots[m or ""] then s.killUntil = tn + (fam.killWin or SHOT.KILL_WIN) end   -- §444 虎炮 1.5 秒（11-25 #624 0.6 秒没扫到）
        if (s.killUntil and tn <= s.killUntil) or (s.adoptUntil and tn <= s.adoptUntil) then   -- §428 认领窗口里也扫
            s.killed = s.killed or {}; SHOT.killNative(pup, id, f, tn)
        end
    end
    if not s.paused then
        if m == fam.charge and pos and pos >= fam.pauseAt then
            local ok = G.montagePause(pup, true)
            s.paused = ok
            SHOT.log("§377 远端#%d %s 替身蓄力动作到 %.2f 秒 → 暂停 %s", id, f.name, pos, ok and "成功" or "失败")
        end
    elseif m ~= s.lastM and m ~= fam.charge then
        SHOT.log("§377 远端#%d %s 替身动作换成 %s%s", id, f.name, tostring(m),
            SHOT.byMon[m or ""] and "（替身自己出手了：暂停没拦住）" or "")
    end
    s.lastM = m
end

-- 收：收掉替身的这一招（先取消技能再停动作，免得恢复动作后它自己蓄满出手）
function SHOT.finish(pup, id, f, tn, why)
    local s = f.shot
    if not s or s.done then return end
    s.done = true
    local gone = valid(pup) and G.cancelAbilities(pup, function(n) return n == f.name end) or {}
    local m = valid(pup) and montageOf(pup)
    local cut = (m == SHOT.FAM[f.name].charge) and cutMontage(pup) or nil
    SHOT.log("§377 远端#%d %s %s：替身共 %d 发，取消技能 %s%s", id, f.name, why, s.n,
        #gone > 0 and table.concat(gone, ",") or "（已经没在放）", cut ~= nil and ("，停蓄力动作 " .. tostring(cut)) or "")
end

-- ============================================================ §446 黄金火铳连射第二发（Normal_02 → Normal_04）收方没伤害
-- 11-25 用户"原地连射、移动连射后的第二次连射都没有伤害"。"连射"= 点一下 GA_HuangJinHuoChong_Normal_02（第一发，
-- 子弹 BD_..._Normal_02_01），在它的接招窗口（放出约 0.95 秒）再点 → GA_HuangJinHuoChong_Normal_04（第二发，子弹
-- BD_..._Normal_02，时间线从 0.8 秒起跳、1.54 秒出子弹 = 放出后约 0.74 秒）。11-22–11-25 收方日志逐条对过：
--   单独放的 Normal_04（autohit，前面没有 Normal_02）6/6 中（11-22 21:41 三次那时还没有 §424 按住键，照样中）；
--   接在 Normal_02 后面的 Normal_04 14/14 没中（7 次"落空"，7 次观战没判定行），对方按 0.06–3.49 秒、§424 替身按住
--   IsHolding=true、§434 按满 1 秒都一样 → 和按没按住无关，只和"前面刚放过 Normal_02"有关（替身身上具体哪一步把
--   这发子弹弄没了还没查实，见 HANDOVER §446 的两个候选）。
-- 做法（同 §377 / §427：按对方出手由模组自己生成子弹）：接在 Normal_02 后面放出的 Normal_04，到 DUE 秒还没看到替身
-- 自己的火铳子弹（BP_Bullet_GuiChai_Black_Bullet_Common，所有者 = 替身）、这一招也还没判中 → 用这招技能实例生成
-- 一颗 BD_GA_HuangJinHuoChong_Normal_02（瞄你，瞄准组件锁你）。单独放的不碰（原生就中）。关掉：net/hjhc_off.txt
HJHC = { NAME = "GA_HuangJinHuoChong_Normal_04_C", PREV = "GA_HuangJinHuoChong_Normal_02_C",
         CHAIN = 2.0, SCAN_FROM = 0.45, DUE = 1.0, CLS = "GuiChai_Black_Bullet",
         DIR = "/PBZCombatAsset/ActorData/Players/Hun/BulletData/ShachiWeapon/HuangJinHuoChong/",
         BDN = "BD_GA_HuangJinHuoChong_Normal_02",
         OFF_FILE = (NET_DIR or "net") .. "/hjhc_off.txt", logN = 0, LOG_MAX = 80 }

function HJHC.log(fmt, ...)
    HJHC.logN = HJHC.logN + 1
    if HJHC.logN <= HJHC.LOG_MAX then out(fmt, ...) end
end

function HJHC.off()
    local f = io.open(HJHC.OFF_FILE, "r")
    if f then f:close(); return true end
    return false
end

-- 诊断：替身瞄准组件锁没锁着
function HJHC.lockState(pup)
    local tc = valid(pup) and LO and LO.targetingComp and LO.targetingComp(pup)
    if not tc then return "没有瞄准组件" end
    local ok, r = pcall(function() return tc:HasLockTarget() end)
    return ok and tostring(r) or "读不到"
end

-- 放之前（AIR.fire，INP.press 前）：记 Normal_02 的放出时刻；Normal_04 记下替身那时的状态（诊断）
function HJHC.before(pup, e, tn)
    if e.name == HJHC.PREV then CHG.hjLast02 = tn; return end
    if e.name ~= HJHC.NAME then return end
    local chained = CHG.hjLast02 ~= nil and tn - CHG.hjLast02 <= HJHC.CHAIN
    CHG.hjPend = { id = e.id, chained = chained }
    HJHC.log("§446 远端#%d %s 放之前：%s；替身 Normal_02 技能%s，动作 %s，瞄准组件锁定 %s", e.id, e.name,
        chained and string.format("接在 Normal_02 后面（%.2f 秒）", tn - CHG.hjLast02) or "单独放",
        (valid(pup) and LO.activeInstance(pup, HJHC.PREV)) and "还挂着" or "没了", tostring(montageOf(pup)), HJHC.lockState(pup))
end

-- 放成功（CHG.onFire 里，CHG.fired[id] 刚建）
function HJHC.onFire(pup, e, tn)
    if e.name ~= HJHC.NAME then return end
    local p = CHG.hjPend
    CHG.hjPend = nil
    if not (p and p.id == e.id and p.chained) or HJHC.off() then return end
    local f = CHG.fired[e.id]
    if not f then return end
    f.hj = { at = tn, inst = LO.activeInstance(pup, e.name), old = HJHC.bulletKeys(pup) }
end

-- 放出那一刻替身名下已经有的火铳子弹（第一发 Normal_02 留下的），之后不算"这一发自己出了子弹"
function HJHC.bulletKeys(pup)
    local keys = {}
    local ok, l = pcall(function() return FindAllOf("BulletActorBase") end)
    for _, b in ipairs(ok and l or {}) do
        if valid(b) and sameObj(rawProp(b, "BulletOwnerAvatar"), pup) and full(b):find(HJHC.CLS, 1, true) then keys[full(b)] = true end
    end
    return keys
end

-- 替身自己的火铳子弹（这一招放出之后才出现的、还在飞的：BulletStatus = 2）
-- 11-25 双开：只看"名下有火铳子弹"时，第一发 Normal_02 留下的（状态 3 = 已结束）被当成第二发 → "不补" → 落空
function HJHC.nativeBullet(pup, old)
    local ok, l = pcall(function() return FindAllOf("BulletActorBase") end)
    for _, b in ipairs(ok and l or {}) do
        if valid(b) and rawProp(b, "BulletStatus") == 2 and sameObj(rawProp(b, "BulletOwnerAvatar"), pup)
            and full(b):find(HJHC.CLS, 1, true) and not (old and old[full(b)]) then return b end
    end
    return nil
end

-- 每帧（CHG.pupStep）：SCAN_FROM–DUE 秒里看替身有没有自己出子弹；DUE 秒还没有、也没判中 → 补一颗
function HJHC.step(pup, id, f, tn)
    local h = f.hj
    if not h or h.done or not valid(pup) then return end
    local age = tn - h.at
    if age < HJHC.SCAN_FROM then return end
    local lh = NET.lastHit
    if lh and lh.r and lh.r.atk == id then
        h.done = true
        HJHC.log("§446 远端#%d %s 已经判中（替身自己的子弹打到了）→ 不补", id, f.name)
        return
    end
    local b = HJHC.nativeBullet(pup, h.old)
    if b then
        h.done = true
        HJHC.log("§446 远端#%d %s 放出 %.2f 秒替身自己出了子弹 %s（状态 %s）→ 不补", id, f.name, age,
            full(b):match("^(%S+)") or full(b), tostring(rawProp(b, "BulletStatus")))
        return
    end
    if age < HJHC.DUE then return end
    h.done = true
    local inst = LO.activeInstance(pup, f.name)
    if not inst and h.inst and valid(h.inst) then inst = h.inst end
    if not inst then HJHC.log("§446 远端#%d %s 放出 %.2f 秒没子弹，替身这招技能也没了 → 补不了", id, f.name, age); return end
    local fam = { dir = HJHC.DIR, tiers = { One = HJHC.BDN } }
    local bd, how = SHOT.bd(fam, "One")
    if not bd then HJHC.log("§446 远端#%d 补子弹：子弹数据%s", id, tostring(how)); return end
    local loc = try("hjhc loc", function() return pup:K2_GetActorLocation() end)
    if not loc then return end
    local rot0 = SHOT.aim(loc, tn)
    local y = math.rad(rot0.Yaw or 0)
    local at = { X = loc.X + math.cos(y) * SHOT.FWD, Y = loc.Y + math.sin(y) * SHOT.FWD, Z = loc.Z + SHOT.UP }
    local rot = SHOT.aim(at, tn)
    G.setControlRot(pup, rot); setYaw(pup, rot.Yaw)
    local lock0 = HJHC.lockState(pup)
    local tc = LO.targetingComp(pup)                 -- 子弹按锁定目标找人（BP_BulletTargetSelector_LockTarget）
    if tc then ZMX.tcLock(tc); if not NET.rlk then ZMX.tcUnlockAt = math.max(ZMX.tcUnlockAt or 0, tn + 3.0) end end
    local e, info = G.laserEmitterSpawn(inst, pup, at, rot, bd)
    HJHC.log("§446 远端#%d %s 接在 Normal_02 后面、放出 %.2f 秒替身没出子弹 → 补一颗 %s：%s（%s；锁定 %s → %s；P%.0f Y%.0f）",
        id, f.name, age, HJHC.BDN, e and G.emitterInfo(e) or "没生成", tostring(info), lock0, HJHC.lockState(pup),
        rot.Pitch or 0, rot.Yaw or 0)
end

return {
    SHOT = SHOT,
    HJHC = HJHC,
    CHG = CHG,
    INP = INP,
    BOWEYE = BOWEYE,
    BOWAIM = BOWAIM,
    BOWN = BOWN,
    BOWP = BOWP,
}
end
