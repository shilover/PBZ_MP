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
-- §276.9（移植 0.33 分支 §269.11）11-13 观战"人和车没同步"：真人驾车 10 秒多（松了键车照样跑），以前发送方按蓄力招算——松键就发 rel=、
-- 按满 JUDGE_MAX 8 秒也发，接收方 8 秒没等到也自己取消 → 替身提早下车，人（跟着网络位置）和车分开。现在马车发送方只在下车时发 rel=
-- （§276.10：播到下车动作 AM_JumpOffHorseCart，或技能真结束），接收方兜底放宽到 MAX 秒（旧版对方松键就发的 rel= 照旧会让替身提早下车）
CHG.VEHICLE = { names = { GA_HorseCart_Charge_C = 1 }, MAX = 30.0, logN = 0 }

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
            if CHG.WAIT[f.name] and valid(pup) then CHG.releaseTo(pup, id, f, tn, secs) end
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
            if w.who == "我" and w.hold and w.key and m and not CHG.VEHICLE.names[w.name] and (m:find("Release", 1, true) or m:find("_End", 1, true)) then
                CHG.release(w, tn, "换到 " .. m)
            end
            -- §276.10（移植 0.33 分支 §269.15）马车：播到下车动作（AM_JumpOffHorseCart）就是松手。11-13 实测只认"技能结束"太晚：技能清单（NET.prevAbs）
            -- 观战 / 对局外不更新，下车后 93 秒才判出来，观战替身多驾 3 秒车（等自己的驾车动作播完）。持续型招的结束看发送方自己的状态变化
            if w.who == "我" and w.hold and m and CHG.VEHICLE.names[w.name] and m:find("JumpOff", 1, true) then
                CHG.release(w, tn, "下车 " .. m)
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
        local veh = CHG.VEHICLE.names[w.name]      -- §276.9 马车：不认松键 / 8 秒截断，只认下车
        if w.who == "我" and w.hold and not w.relAt then
            if w.h0 and not veh then
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
        elseif tn - w.at >= (veh and CHG.VEHICLE.MAX or CHG.JUDGE_MAX) then CHG.release(w, tn, "按太久"); CHG.finish(w, tn, "到时间")
        elseif tn - w.last >= CHG.QUIET then CHG.release(w, tn, "没动作"); CHG.finish(w, tn, "没动作、技能也结束了")
        else keep[#keep + 1] = w end
    end
    CHG.list = keep
end
return {
    CHG = CHG,
    INP = INP,
    BOWEYE = BOWEYE,
    BOWAIM = BOWAIM,
    BOWN = BOWN,
    BOWP = BOWP,
}
end
