-- base_loadout.lua —— 从 main.lua 搬出来的 配装同步 + 替身换装 + 天赋 / 饰品被动同步（docs/MAIN_SLIM.md）。原来在 main.lua 的 "-- ===… 配装同步（v0.16.0）" 那段
return function(ctx)
local ST, NET, MATCH, ROOT, NET_DIR, G = ctx.ST, ctx.NET, ctx.MATCH, ctx.ROOT, ctx.NET_DIR, ctx.G
local full, pathOf, valid, rawProp, shortName = G.full, G.pathOf, G.valid, G.rawProp, G.shortName
local eachArr, getP1, now, attrSetOf, setAttr = G.eachArr, G.getP1, G.now, G.attrSetOf, G.setAttr
local ascOf, equipWeapon, abilitiesOf = G.ascOf, G.equipWeapon, G.abilitiesOf
-- main.lua 主循环那段会把 out / activeAbilities / attrOf 换成计时包装（PROF.wrap），这几个由 ctx 传"调用时再取"的包装，
-- 和搬出来之前一样走计时（docs/MAIN_SLIM.md 规矩 3）
local out, activeAbilities, attrOf = ctx.out, ctx.activeAbilities, ctx.attrOf

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
-- 11.20 影武：按住蓄力 / 一招里连发 / 驾车的招，出伤害可能在放招 HOLD 秒以后（虎炮满蓄、巨斧三蓄、马车一路撞），
-- 以前 HOLD 一过替身攻击力回到不乘这招系数（11-22 15:48:45 日志"替身攻击力 ×78%（武器平衡 标准数值 …）"没有招名）。
-- 这些招的系数保持到这么多秒（下一招放出来就换，不影响别的招）。秒数：蓄力招 = CHG.JUDGE_MAX 8、§377 连发 = SHOT.END_MAX 12、
-- 马车 = CHG.VEHICLE.MAX 30
-- 火力全开 12：11.22 实机 21:46:44 放招、21:46:47 开炮 -529（3 秒后，系数已回到 ×20% 不带 ×1.2 和标准数值），后面每跳到 6 秒以后
BAL.HOLD_FOR = {
    GA_HorseCart_Charge_C = 30, GA_TigerCannon_C = 12, GA_TigerCannon_QuickCharge_C = 12, GA_TigerCannon_Ultimate_C = 12, GA_UnnamedBow_C = 12,
    GA_BrutalAxe_Normal_C = 8, GA_BrutalAxe_Sprint_C = 8, GA_DuYan_Bow_Normal_C = 8, GA_DuYan_Bow_Laser_C = 8,
    GA_YouLongCha_Normal_C = 8, GA_JinGua_Normal_C = 8, GA_JinGua_RoAttack_C = 8, GA_JinGua_Air_C = 8,
    GA_TanLang_Normal_C = 8, GA_LionHead_C = 8, GA_ZhuoBiDun_C = 8, GA_YouLongHead_Water_C = 8,
    GA_Hun_Lute_SKill_C = 8, GA_Hun_HuoLiuXing_AAAA_C = 8, GA_HuangJinHuoChong_Normal_02_C = 8, GA_HuangJinHuoChong_Normal_04_C = 8,
}
function BAL.holdOf(name) return math.max(BAL.HOLD, name and BAL.HOLD_FOR[name] or 0) end
-- 11.22 实机（21:31:49）：保持期里系数还是这招的，但影武等级系数（标准数值 ×3.90）照旧 EDGE_HOLD 2.5 秒就撤、换成主武器的，
-- 2.5 秒后打中的影武伤害只剩约 1/3.9。保持期内（最后放的还是这招影武）等级系数也按影武算
function BAL.edgeHeld(tn)
    local n = BAL.last
    return n ~= nil and BAL.HOLD_FOR[n] ~= nil and tn - BAL.lastAt < BAL.holdOf(n) and LO.isEdgeAttack(n) == true
end
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
-- §426 GA_ 开头的键 = 那一招放出来起算的冷却秒数（base_wrules MCD 段）：双刃第四段 5 秒（用户 11-24 定）；§435 用户改成冷却组 JueYingTrack = 1（绝影 ABB / AAABB / BBBB 共用 1 秒，组表在 base_wrules MCD.GROUP，原 BBBB 5 秒撤掉）
BAL.CD_DEF, BAL.CD_CAP = { ZiMingJian_HuoQiang = 0.1, ShunYingDodge = 10, JueYingTrack = 1 }, 60
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
-- §228 StaggerHits / StaggerSec = 精防硬直触发次数 / 关输入秒数（STG.need / STG.sec，房间设置 stg 开着才用，不看武器平衡）
-- §406 PoJunDR = 破军冲锋（GA_Hun_PoJun_DB / DB_02）的减伤保留几成：1 = 原版不减，0.25 = 只留 25%（减伤 −75%），0 = 完全不免伤。
-- main.lua PJ 段直接改挨打方自己的承伤倍率（Physical / Elemental / ImpactShachi），只在武器平衡开着、交手中生效。
BAL.COST_DEF, BAL.COST_CAP = { Dodge = 50, SnakeDodge = 50, SwitchKeepShachi = 1, StaggerHits = 3, StaggerSec = 1, PoJunDR = 0.25 }, 1000
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
-- 挨打方把这一下的掉血改成这个数；本地 AI 的 td= 这一下也按这个数报（GDMG / SUMD 段）。现在有紫冥剑 DB 召出的火枪，
-- 以及剑客召集令 / 草偶丝线 / 枯叶丝竹串 / 虚空化山 这 4 件影之武装召出来的东西（用户 11-11：召唤物打中一下只扣 1 点）。
-- 单位 = 每发掉多少血（最终值，不再乘伤害倍率 / 等级 / 系数）；0 = 不管（按召唤那招的系数，§177）；负数 / 坏值不收（按默认）。
-- 单独一行、单独的数值表字段 sd=（不塞进 cd= 等旧字段）；整行没有 / 没写某个键 = 默认 SDMG_DEF（火枪 1）
BAL.SDMG, BAL.SDMG_DEF, BAL.SDMG_CAP = {}, { ZiMingJian_HuoQiang = 1, Summon = 1,
    ShachiWeapon_JianKeZhaoJiLing = 1, ShachiWeapon_CaoOuSiXian = 1, ShachiWeapon_KuYeSiZhuChuan = 1, ShachiWeapon_XuKongHuaShan = 1 }, 10000
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
-- 11.21: per-damage-source multipliers; no whole-move spreading.
BAL.SEGMENTS = {}
function BAL.cleanSegments(t)
    local o = {}
    for k, v in pairs(type(t) == "table" and t or {}) do
        if type(k) == "string" and (k:match("^BD?_[%w_]+$") or k:match("^BulletData_[%w_]+$") or k == "TipsyLight" or k == "TipsyHeavy" or k == "DrunkHeavy" or k == "ChaosFireHeavy" or k == "JueYingClone")   -- §438
            and type(v) == "number" and v > 0 and v <= 10 then o[k] = v end
    end
    return o
end
do
    local okB, T = pcall(require, "pbz_balance")
    if not (okB and type(T) == "table") then okB, T = pcall(function() return dofile((((FORNET or {}).GAME_DIR or (ROOT .. "/Scripts")) .. "/pbz_balance.lua")) end) end
    if okB and type(T) == "table" then
        BAL.FAMILY, BAL.MOVE, BAL.SUMMON = T.family or {}, T.moves or {}, BAL.cleanSummon(T.summon)
        BAL.COOLDOWN = BAL.cleanCooldown(T.cooldown)
        BAL.DOT, BAL.CTRL = BAL.cleanDot(T.dot), BAL.cleanCtrl(T.ctrl)       -- §199
        BAL.CHILL = BAL.cleanChill(T.chill)                                  -- §206
        BAL.SDMG = BAL.cleanSdmg(T.sdmg)                                     -- §212
        BAL.SEGMENTS = BAL.cleanSegments(T.segments)
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

-- 一招的系数（纯函数），返回 系数, 依据。wc = 攻击方手上的武器配置（§371；不传 = 不分武器）
function BAL.moveScale(name, wc)
    local f, why
    local sp = CAP and CAP.SPREAD and name and CAP.SPREAD[name]          -- §359 按段摊开（见 CAP.SPREAD）
    if sp then
        f, why = BAL.moveScale0(name)
        f, why = f * sp, (why or "系数") .. string.format(" × 摊开 %.3f", sp)
    else
        f, why = BAL.moveScale0(name)
    end
    local wm, wwhy = BAL.wpnMul(name, wc)
    if wwhy then f, why = f * wm, (why or "系数") .. string.format(" × %s ×%.2f（§371）", wwhy, wm) end
    return f, why
end
function BAL.moveScale0(name)
    local o = BAL.MOVE[name]
    if o then return o, "单招" end
    local fam = name:match("^GA_Hun_(%w+)_")
    local f = fam and BAL.FAMILY[fam] or 1.0
    if LO.isEdgeAttack(name) then return f * LO.EDGE_SCALE, "影之武装" end
    return f, f ~= 1.0 and ("族 " .. fam) or nil
end

-- §371 同一招按攻击方当时手上的武器再乘（系数表一招一个数：L1+圈 是同类武器共用的一招，单给一把武器调只能在这里分）。
-- wc = 攻击方手上武器配置路径（替身侧 = 对方的 NET.rwc，放招时记进 BAL.lastWc；本地 AI 我打替身 = 我发这招时的 NET.wcStr，记进 NET.evWc）。
-- 认法看配置资产名（游戏包 /Hun/Weapon/Double/ 下 Weapon_Hun_Double = 黑伤双刃、Weapon_Hun_JueYing = 淬炼后的绝影，两把放的都是 GA_Hun_Double_*，
-- 平衡反馈的"绝影（黑伤双刃）"规则也按 GA_Hun_Double_ 落表，所以两把都算；黑魔伤 = /Hun/Weapon/HeiMoShang/Weapon_Hun_HeiMoShang，
-- 没淬炼的黑伤 Weapon_Hun_Tang 放的是 GA_Hun_Tang_*，不算）。各轮倍数**叠乘**（和系数表每轮在现行值上继续乘同一口径）：
--   绝影 L1+圈 影杀 YingSha（双持共用）：第四轮 +10%（§358 没做）× 第五轮"幻影三连斩（防御+处决）"+50% = ×1.65
--   黑魔伤 L1+圈 瞬杀 ShunSha（单手共用）：第三轮 +25%（§346 没做）× 第六轮"瞬杀（防御+处决）"+50%（§379）= ×1.875
-- _C_C 和接着出的 _CB_C 都乘（一招里的几段）。旧版客户端（0.33 等）没有这段，同一份下发表照原样（不乘）
BAL.WPN = {
    { pat = "^GA_GlobalActionAbilit%a*_YingSha_", wc = { Weapon_Hun_Double = true, Weapon_Hun_JueYing = true },
      mult = 1.10 * 1.50, why = "绝影 L1+圈 第四轮 +10% × 第五轮 +50%" },
    { pat = "^GA_GlobalActionAbilit%a*_ShunSha_", wc = { Weapon_Hun_HeiMoShang = true },
      mult = 1.25 * 1.50, why = "黑魔伤 L1+圈 第三轮 +25% × 第六轮 +50%" },
}
function BAL.wcName(wc) return type(wc) == "string" and (wc:match("([%w_]+)$")) or nil end
-- 返回 倍数, 依据（不管 = 1, nil）
function BAL.wpnMul(name, wc)
    local w = name and BAL.wcName(wc)
    if not w then return 1.0, nil end
    for _, r in ipairs(BAL.WPN) do
        if r.wc[w] and name:find(r.pat) then return r.mult, r.why end
    end
    return 1.0, nil
end
-- §186.3 架势里的同名招：偃月刀先放架势 Stance_C 再按 B，发出来的招名还是 B_C，伤害却是强化版（采集 B_C 1091 / B_Reinforced_C 1771；
-- 11-09 实战 B_C 每点攻击 3.5，采集 1.4）。STANCE_WIN 秒内同族放过架势 → 系数按 <招>_Reinforced_C 算（表里有这一行才换）。
-- 两边各记各的：收到的对方事件记 BAL.rStance（替身放招乘系数），自己发的记 BAL.myStance（TOUCH.scale 回报），规则一样所以对称。
-- 窗口 10 秒是按 11-09 实战日志估的（架势后 2 / 5 / 8 秒的 B 是强化伤害，11 秒的不是），待实测校
BAL.STANCE_WIN, BAL.STANCE_FAM, BAL.rStance, BAL.myStance = 10, { YanYueDao = true }, {}, {}
-- 11.20 影武：子技能按拉起它的那招算系数。巨凶斧疾行斧 GA_BrutalAxe_Sprint 自己没有判定，拉起 Normal 走 SprintRelease 分支；
-- 以前 Normal 一放出来就按 Normal 的系数（和 Sprint 取小也只管 TAIL 1 秒），蓄力疾行吃不到"疾行斧 -50%"。
-- PARENT_WIN 秒内先放过 from → 这一次 Normal 按 from 的系数（用一次就清，之后单独放的 Normal 照旧）。两边各记各的，同 §186.3
BAL.PARENT, BAL.PARENT_WIN = { GA_BrutalAxe_Normal_C = "GA_BrutalAxe_Sprint_C" }, 1.0
BAL.PARENT_FROM = {}
for _, from in pairs(BAL.PARENT) do BAL.PARENT_FROM[from] = true end
function BAL.noteStance(t, name, tn)
    if name and BAL.PARENT_FROM[name] then t["@" .. name] = tn end     -- 11.20 拉起子技能的那招
    local f = name and name:match("^GA_Hun_(%w+)_Stance_C$")
    if f and BAL.STANCE_FAM[f] then t[f] = tn end
end
function BAL.resolve(name, t, tn)
    local from = name and BAL.PARENT[name]
    local pat = from and t["@" .. from]
    if pat then
        t["@" .. from] = nil
        if tn - pat <= BAL.PARENT_WIN and BAL.MOVE[from] then return from end
    end
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
    BAL.prevWc, BAL.lastWc = BAL.lastWc, NET.rwc            -- §371 放招时对方手上的武器（同一招按武器分开的系数）
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
    if BAL.last and tn - BAL.lastAt < BAL.holdOf(BAL.last) then
        f, why = BAL.moveScale(BAL.last, BAL.lastWc)
        name = BAL.last
        if BAL.prev and tn - BAL.prevAt < BAL.TAIL then
            local f2, why2 = BAL.moveScale(BAL.prev, BAL.prevWc)
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
        -- §436 火力全开（用户 11-24："按之前的预期伤害数值给限制"）：11.23 定的预期一招 1500–1550（伤害 20% 房、标准数值、对方攻击 200），
        -- 不破防实测一招累计 1415–1484（11-24 #981 / #1007 / #1011 / #1013 / #1017）；挨打方挡着被破防那一下游戏自己 ×2（-2721，累计 2820 / 2905）。
        -- 按 1550 封顶：TOTAL 是伤害 100% / 攻击 200 口径 → 1550 ÷ 20% = 7750（伤害倍率 / 攻击 / 等级照 CAP.expected 缩放）。系数 0.66 以后再改，这里不会跟着变
        TOTAL = { GA_GlobalActionAbility_LieZhan_C_C = 1050, GA_TigerCannon_Ultimate_C = 7750 }, TOTAL_SLACK = 1.0 }
-- §359 大招"除了第一刀后面都没伤害"（内测反馈 11-16，v0.34.1 日志）：§197 / §203 列的天玄青铜剑 / 荡寇凶刃 / 玉双环大招，
-- 原版是只采到一段（青铜剑 1572、荡寇 1952）或打空下限（玉双环 3039）——整招按游戏数据是 6860 / 8884 / 6365（base_capdata.lua
-- §339.2、data/move_game.csv 1632 × 3.9）。上限 = 原版 × 系数 × …，第一刀就把它吃满，后面每一段都被吃掉（日志"改过之后又吃掉 N 跳"）。
-- 平衡系数当初也是按偏低的原版调的，所以现在**整招总伤害**是对的、只是全压在第一刀。修法：原版改成整招的数，系数乘 旧 / 新（SPREAD）——
-- 上限 = 新原版 × 系数 × 旧 / 新 = 跟以前一样；每一下伤害按同一比例缩小，整招打满正好到上限 → 每段都出伤害，总伤害不变。
-- 只改代码、不动下发的数值表：旧版本（表一样、原版旧）照旧是"第一刀吃满"，同一份表新旧版本总伤害一致，不会因为版本不同差 4 倍
-- §359.2 玉双环大招整招按实战改 17200（v0.34.3 玩家日志 11-16 21:16–21:17 三次打满约 13 段：不截时合计 1991 / 1852 / 1856，
-- 伤害 35%、系数 0.66 × 3039/6365 → 1900 ÷ (0.315 × 0.35) ≈ 17200；6365 = move_game.csv 1632 × 3.9 只算了一部分环，第 7 段起照样被截）
-- §369 大招"前几下有伤害、后半段没伤害"（第五轮内测 11-17，v0.34.3 / v0.34.6 日志 mp_probe (24)(25)）：全是这里截的（本地 AI 侧 AIF.cap，
-- 日志"!! 本地 AI 绕过平衡 … 改成 -0 … 又吃掉 N 跳"）。整招原版还是偏低：不截时合计 ÷ 应有 × 当时原版 = 整招（同口径），
--   绝影 C_C   11367–14084（13 次；最后那下冲击波一下就 2527 / 2982 = 原版约 1 万）→ 原来没摊开，只有 2592（乌鸦一下）
--   青铜剑     12637（4 次 6 段打满）、10550、8248 → 6860 只到 1.84 倍的一半
--   荡寇       9275 / 10442（v0.34.3 4 段，没截但离 8884 × 1.25 只差 6%）
--   玉双环     14540–18052（17200 × 1.25 内，不动）
-- 原则：整招原版取**见过的最大**（不是中位），1.25 倍门槛留给没见过的情况——宁可整招总伤害偏低一点（比旧版上限少，最低约 65%，
-- 下一轮平衡调系数补），也不能后几段被吃掉。绝影空中版没有实战数据，按 §339 总表 11372 × (14084 / 13065) ≈ 12300。
-- 超出 1.25 倍还是会截（只剩防异常：乌鸦一帧结算好几下这类），截到摊开的招时日志带"§369 整招原版偏低"，看到就照这里的算法再调
CAP.SPREAD_RAW = { GA_Hun_BronzeSword_C_C = { 1572, 12700 }, GA_Hun_Horizontal_C_C = { 1952, 10500 }, GA_Hun_Jade_C_Range_C = { 3039, 17200 },
                   GA_Hun_Double_JueYing_C_C = { 2592, 14100 }, GA_Hun_Double_JueYing_C_Air_C = { 2592, 12300 } }
CAP.SPREAD = {}
for n, p in pairs(CAP.SPREAD_RAW) do CAP.RAW[n] = p[2]; CAP.SPREAD[n] = p[1] / p[2] end
-- §369 截到摊开过的招时日志尾巴（CAP.fix / AIF.cap 共用）
function CAP.lowNote(name)
    local p = name and CAP.SPREAD_RAW[name]
    if not p then return "" end
    return string.format("【§369 整招原版 %d 偏低：摊开的招被截 = 后几段又没伤害了，按这次不截合计重算整招原版】", p[2])
end
-- 这一招按表应有的一招总伤害（纯函数）：原版 × 系数 × 伤害倍率 × 对方攻击 / 200 × 等级倍率 / 30 级倍率。
-- 返回 数, 说明, 门槛倍数（超过 数 × 门槛倍数 才改）；不管的招 nil
-- §217 本地 AI（攻击方是我）：atkIn / lmIn = 我的攻击力 / 我这一下的等级倍率（不传 = 挨打方口径，读对方的）
-- 伤害倍率 / 攻击 / 等级（CAP.expected 和 §339 CAP.allExpected 共用）
function CAP.scale(name, atkIn, lmIn)
    local dm = NET.dmgNow() / 100
    local atk = atkIn
    if atk then
    elseif STD.active() then atk = STD.ATTR.Attack
    else atk = tonumber(NET.ratt and (NET.ratt:match("^Attack:([%-%d%.e+]+)") or NET.ratt:match(";Attack:([%-%d%.e+]+)"))) end
    atk = atk or CAP.REF_ATK
    -- 等级：标准数值 = 30 级；对方发了等级 = 对方那把；都没有 = 游戏按本机存档乘（本机没装着 = ×1）
    local ref = STD.mult(30)
    local lm = lmIn
    if lm then
    elseif STD.active() then lm = STD.TARGET_MULT
    elseif NET.rlvW then lm = STD.mult(NET.rlvW)
    else
        local id, shachi = STD.idOf(NET.rwc)
        lm = id and STD.localMult(id, shachi) or ref
    end
    if CAP.FLAT and CAP.FLAT[name] then lm = ref end
    return dm, atk, lm, ref
end
function CAP.expected(name, atkIn, lmIn)
    local raw = name and CAP.RAW[name]
    local total = name and CAP.TOTAL and CAP.TOTAL[name]
    if not (raw or total) or not BAL.active() then return nil end
    local f = not total and BAL.moveScale(name)
    local draw = not total and CAP.DOT_RAW and CAP.DOT_RAW[name]
    local d = draw and BAL.dotScale(name) or 0
    local dm, atk, lm, ref = CAP.scale(name, atkIn, lmIn)
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
-- §339 全招一招总伤害上限（用户 11-16："所有招按平衡表算好上限；保底按 10% 算再按实际倍率放大"——就是 CAP.scale 的伤害倍率项，
-- 输入全来自平衡表 / 房间设置 / 对方包，不读替身身上的攻击力，倍率失效时上限不跟着失效）。数据 base_capdata.lua（tools/balance/gen_cap.py 生成）：
-- RAW 原版一招、DOT 挂上的原版持续伤害、REF 没原版数的招 { 参照招, 倍数 }；系数运行时现取，调表 / 下发新表上限跟着变。
-- 上面手写的 CAP.RAW / TOTAL（§197 / §199 / §203）优先，这里只管它们没列的招。
-- 11-16 拿 137 份历史日志回放：按 1.25 倍门槛，四成出招会被压（乱莺鸣剑状态、风雷状态、多段招实战打得比采集全等，平衡表的原版数偏低；
-- 回放的归一还有 ×3.9 等级口径对不上的），所以**默认只记日志不改血**（ALL_MODE = "dry"，日志"§339 试算"）。
-- net\cap_all.on 存在 = 真改血（"on"）；net\cap_all_off.txt 存在 = 连日志都不记（"off"）。载入时读一次，改了重启游戏生效。
-- §339.1（11-16）原版一招改按实战（data/move_final.csv，tools/balance/final_from_logs.py；gen_cap.py 说明规则），门槛 2 倍：
-- 同一批日志回放 7002 次出招只有 1.16% 超过（1.25 倍 3.2%、3 倍 0.53%），超过的前几名都是要拦的异常（黑伤 A 一招 15 段 12750、鸣剑乱莺 A −1294、玉双环一段打空）
CAP.ALL_SLACK, CAP.ALL_MODE, CAP.dryName, CAP.dryAt, CAP.dryN = 2.0, "dry", nil, -99, 0
do
    local okD, D = pcall(function() return BASEPARTS.load("capdata") end)
    CAP.ALL = okD and type(D) == "table" and D or nil
    local function has(f)
        local h = NET_DIR and io.open(NET_DIR .. "/" .. f, "r")
        if h then h:close(); return true end
        return false
    end
    if has("cap_all_off.txt") then CAP.ALL_MODE = "off" elseif has("cap_all.on") then CAP.ALL_MODE = "on" end
    if not CAP.ALL and BASEPARTS then out("!! §339 全招上限数据 base_capdata.lua 没载入（%s），只用手写的几招", tostring(D)) end
end
-- §389 多段招的整招原版覆盖（只管 §339 的 ALL 这一层，默认 dry 时不影响任何伤害）：
-- 偃月刀 L1+三角（按住旋转）base_capdata 的 4746 只是采集到的一段；整招按住最多 12 段（v0.34.3 玩家日志 (24) 10:25:49
-- #676：12 段 −91…−216 合计 1450，伤害 20%、当时系数 0.53 → 整招原版约 13680）。cap_all 真开（net\cap_all.on）时
-- 原来前 3–4 段就把 4746 的预算吃满、后面每段都被截成 0；这里按整招给预算，每段都留着。表 / 数据文件没改。
CAP.ALL_RAW = { GA_Hun_YanYueDao_SpecialSkill_C = 13700 }
function CAP.allExpected(name, atkIn, lmIn, wc)          -- wc = 攻击方手上的武器（§371 按武器分开的系数；不传 = 不分）
    local A = CAP.ALL
    if not (A and name) or CAP.ALL_MODE == "off" or not BAL.active() then return nil end
    local base, src
    local raw = (CAP.ALL_RAW and CAP.ALL_RAW[name]) or A.RAW[name]
    if raw then
        local f = BAL.moveScale(name, wc)
        local draw = A.DOT[name]
        base = raw * f + (draw and draw * (BAL.dotScale(name) or 0) or 0)
        src = draw and string.format("原版 %d × 系数 %.2f + 持续 %d", raw, f, draw) or string.format("原版 %d × 系数 %.2f", raw, f)
        if CAP.ALL_RAW and CAP.ALL_RAW[name] then src = src .. "（§389 整招多段）" end
    else
        local r = A.REF[name]
        local rr = r and A.RAW[r[1]]
        if not rr then return nil end
        local f = BAL.moveScale(r[1], wc)
        local draw = A.DOT[r[1]]
        base = (rr * f + (draw and draw * (BAL.dotScale(r[1]) or 0) or 0)) * r[2]
        src = string.format("参照 %s 原版 %d × 系数 %.2f × %g", r[1], rr, f, r[2])
    end
    local dm, atk, lm, ref = CAP.scale(name, atkIn, lmIn)
    local v = base * dm * atk / CAP.REF_ATK * lm / ref
    return v, string.format("§339 %s × 伤害 %.0f%% × 攻击 %.0f/%d × 等级 %.2f/%.2f = %.0f", src, dm * 100, atk, CAP.REF_ATK, lm, ref, v), CAP.ALL_SLACK
end
-- 掉血那一帧调：step = 这一帧掉的，total = 这招连这一帧累计，hpBefore = 这一帧之前的血。超了 → 改写血量，返回改后这一帧该掉的；不管 → nil
-- rec = 这招的结果记录（NET.lastHit.r；第一段还没有就 nil）。§199.9：这招改过一次以后（rec.capped）门槛降到 1 倍——
-- 以前改完只把这一跳压到"应有"以内，累计还停在 1.25 倍门槛下面，后面的跳伤每跳都超门槛、每跳记一行"改成 -0"（07:25 那 40 多行），
-- 而且累计一直卡在约 1.25 倍。现在：超过以后整跳吃掉、只记第一次那行，合计在这招结束时（CAP.flush）记一行
function CAP.fix(p1, name, step, total, hpBefore, tn, rec)
    if not NET.fighting() or not hpBefore or hpBefore <= 0 then return nil end     -- 11-17 新版房间交手中也封顶（以前只认 1v1）
    local exp, why, slack = CAP.expected(name)
    local all = false
    if not exp then exp, why, slack = CAP.allExpected(name, nil, nil, BAL.lastWc or NET.rwc); all = exp ~= nil end
    local capped = rec and rec.capped
    if not exp or total <= exp * (capped and 1.0 or slack or CAP.SLACK) then return nil end
    if all and CAP.ALL_MODE ~= "on" then            -- §339 试算：只记日志，同一招 1.5 秒内只记第一次超的那下
        if CAP.dryName == name and tn - CAP.dryAt < 1.5 then CAP.dryAt = tn; return nil end
        CAP.dryName, CAP.dryAt, CAP.dryN = name, tn, CAP.dryN + 1
        out("§339 试算（没开，不改血）：招 %s 这招累计 -%.0f 超过上限 -%.0f × %.2f（%s；第 %d 次）",
            name, total, exp, slack or CAP.SLACK, why, CAP.dryN)
        return nil
    end
    local allow = math.max(0, step - (total - exp))       -- = max(0, 应有 − 这一跳之前的累计)：只补这一跳，前面放过去的不回补
    local hp = hpBefore - allow
    if not setAttr(p1, "Health", hp) then return nil end
    if capped then
        rec.capEatN, rec.capEat = (rec.capEatN or 0) + 1, (rec.capEat or 0) + (step - allow)
        CAP.open = rec
        return allow
    end
    CAP.n = CAP.n + 1
    out("!! 绕过平衡的一下：招 %s / 原扣 -%.0f（这招累计 -%.0f）/ 改成 -%.0f（累计 -%.0f；%s，超过 ×%.2f 才改；之后这招再超出的整跳吃掉、结束时记合计；§197 兜底，第 %d 次）%s",
        name, step, total, allow, total - step + allow, why, slack or CAP.SLACK, CAP.n, CAP.lowNote and CAP.lowNote(name) or "")
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

-- §340 单下受伤上限（用户 11-16 定 7%）：交手中、武器平衡开着，挨打方一帧掉的血不超过 最大血量 × 7% × (伤害倍率 ÷ 10%)
-- （10% 房间 = 7%、30% = 21%，100% = 70%）。不用认招：召唤物 / 持续伤害 / 记错招也管，妖锯妖气爆发这种整招只高 2–3 倍、单下特别大的也拦。
-- 11-16 拿 18427 次单下按现行系数换算回放：超 7% 的约 0.3%，大多是异常（鸣剑乱莺 A −1294 = 10% 房间 42%、妖锯 −307 / −316 ≈ 10%、
-- 玉双环一段打空）；5% 会削到 0.79%（蓄力 / 大招 / 切刀斩打满的那下）。手写 CAP.RAW / TOTAL 的招（绝影乌鸦一帧几下、玉双环 DB 等）不管。
-- 开关跟 §339：默认 dry 只记"§340 试算"；net\cap_all.on 真压；net\cap_all_off.txt 关。
CAP.HIT_PCT, CAP.hitName, CAP.hitAt, CAP.hitN = 0.07, nil, -99, 0
function CAP.hitLimit(p1)
    if CAP.ALL_MODE == "off" or not BAL.active() then return nil end
    local hm = attrOf(p1, "Health_Max")
    if type(hm) ~= "number" or hm <= 0 then return nil end
    return hm * CAP.HIT_PCT * (NET.dmgNow() / 10), hm
end
-- 掉血那一帧调（在 CAP.fix 之前）：step 超过上限 → on 时改写血量、返回改后这一帧该掉的；dry 只记；不管 → nil
function CAP.hitFix(p1, name, step, hpBefore, tn)
    if not NET.fighting() or not hpBefore or hpBefore <= 0 or not step or step <= 0 then return nil end     -- 11-17 同上
    if name and (CAP.RAW[name] or (CAP.TOTAL and CAP.TOTAL[name])) then return nil end
    local lim, hm = CAP.hitLimit(p1)
    if not lim or step <= lim then return nil end
    local why = string.format("最大血量 %.0f × %.0f%% × 伤害 %.0f%% / 10%% = %.0f", hm, CAP.HIT_PCT * 100, NET.dmgNow(), lim)
    if CAP.ALL_MODE ~= "on" then
        if CAP.hitName == name and tn - CAP.hitAt < 1.5 then CAP.hitAt = tn; return nil end
        CAP.hitName, CAP.hitAt, CAP.hitN = name, tn, CAP.hitN + 1
        out("§340 试算（没开，不改血）：招 %s 这一下 -%.0f 超过单下上限 -%.0f（%s；第 %d 次）", tostring(name), step, lim, why, CAP.hitN)
        return nil
    end
    if not setAttr(p1, "Health", hpBefore - lim) then return nil end
    CAP.hitN = CAP.hitN + 1
    out("!! 单下受伤上限：招 %s 这一下 -%.0f 改成 -%.0f（%s；§340，第 %d 次）", tostring(name), step, lim, why, CAP.hitN)
    return lim
end

-- §361 妖锯妖气爆发 −95%（第四轮平衡反馈，用户 11-16"现在做"）。爆发不是一招：妖锯连砍给挨打方挂妖气 GE_YaoJu_Erosion，
-- 它把 GA_YaoJu_MonsterErosion_BP 给到挨打方身上；引爆时这个技能在挨打方身上挂伤害 GE_YaoJu_Explode_Damage_Lv1/Lv2（资源图 _tools/gasgraph/yaoju.json）。
-- 伤害记在替身当时那一招头上，平衡表分不出来 → 挨打方本机认：掉血那一帧身上**刚出现**爆发标签（上一次问的时候还没有，
-- 或上一次问已经是 YQX.GAP 秒前）= 爆发那一下，补回 (1 − MULT)。游戏先扣血、下一帧才挂标签时：掉血先记着，YQX.LATE 秒内
-- 标签出现（那一帧没再掉血）再补。爆发状态里其余的刀照常（标签一直在 = 不是刚出现）。
-- 只在交手中 + 武器平衡开着（和系数表同一个开关）。每帧只读血量；掉血那一帧 / 等标签的 LATE 秒内才问一次标签。
-- §371（第五轮"所有形式的妖气爆发都要调整"）：§361 只认 GE_YaoJu_Explode_CanNotDeflect 的标签 YuuBlade.ExplodeCannotDeflect，
-- 可这个 GE 只有攻击方带"妖气爆发破绽"升级（GE_YaoJu_Upgrade_YaoQiExplodeDebuff，标签 WeaponUpgrade.YuuBlade.YaoQiExplodeDebuff）
-- 才挂——MonsterErosion_BP 的名字表里按 GetSourcePlayerASC + HasMatchingGameplayTag 查 YaoQiExplode.V1/V2/V3 / YaoQiExplodeDebuff，
-- 分 Lv1 / Lv2 两档伤害。内测日志里 485 份状态包带 V1、只有 309 份带 Debuff：没这个升级的人引爆没有这个标签，§361 认不出。
-- 每种爆发都会在挨打方身上挂的是冷却 GE_YaoJu_Cooldown（标签 CharacterState.AbilityState.YaoJu.Cooldown，时长 SetByCaller，
-- 冷却期间不会再爆）：mp_probe (5).log 15:32:44 只有 V1 的妖锯 B 命中后"追加 -388"（Hit_Heavy）、对方马上带上 GE_YaoJu_Cooldown，
-- 前后没有 CanNotDeflect。所以两个标签**任何一个刚出现**都算爆发那一下；同一次爆发两个标签前后脚到，YQX.ONCE 秒内只认一次。
-- 主动引爆（升级 TriggerYaoQiExplode：攻击方 GA_YaoJu_PlayerPassive_BP 按处决键发 GameplayEvent.Ability.YaoJu.TriggerAllExplode）
-- 也是挨打方身上同一个 MonsterErosion_BP 结算，同样挂冷却。
-- §371 本地 AI 方向（我的妖锯打 AI 替身、td= 报数）：同一套认法看替身身上的标签（YQX.mine / YQX.minePend）
-- §384 离线核查（资产 GA_YaoJu_MonsterErosion_BP 默认对象 / 两个 GE，bp_decode）：
--   · 没升级也会爆：DefaultExplodeAttackData 物理 2.0 倍，V1 / V2 / V3 只是改成 2.33 / 2.66 / 3.0 → 本地 AI 方向不能只看 wge= 里有没有 GE_YaoJu_
--     （没升级的妖锯身上一个 GE_YaoJu_ 都没有，整个跳过），改成手上是妖锯（wc= 路径带 /YuuBlade/）也算（YQX.mineOn）
--   · 爆发破绽 GE_YaoJu_Explode_CanNotDeflect 时长 3.0 秒（DurationMagnitude 3.0）；冷却 GE_YaoJu_Cooldown 按 SetByCaller，
--     BP 里 PostExplodeCooldown = 1.0、ExplodeDelay = 0.15。GAP 以前正好 3.0 = 破绽标签的时长，隔 3 秒再砍一刀、标签还没掉那一帧
--     会被当成"刚出现"→ 普通刀只报 5%；改 3.5
--   · 伤害 / 冷却 / 延迟在原生父类里（蓝图只在 GameplayEvent.Ability.YuuBlade.YaoQiExplodeDebuff 事件里挂破绽 GE），
--     标签和掉血谁先到离线定不了：同一帧 / 标签晚到都处理；标签早到的话 YQX.diag 会记"爆发后又掉"
--   · 本地 AI 标签晚到（pend）：以前先把整下记进 td=、下一帧再扣 95%。td= 是累计数、本地 AI 那边取最大值（LocalAi.cs a.Dmg = Max），
--     两帧之间发出去的包（约 30 包 / 秒）已经带了整下 → 扣不回来，后面几刀还被吞掉。现在这一下先不进 td=，LATE_AI 秒内定了再记
YQX = { MULT = 0.05, TAG = "CharacterState.AbilityState.YuuBlade.ExplodeCannotDeflect",
        TAGS = { "CharacterState.AbilityState.YuuBlade.ExplodeCannotDeflect", "CharacterState.AbilityState.YaoJu.Cooldown" },
        TAG_NAME = { ["CharacterState.AbilityState.YuuBlade.ExplodeCannotDeflect"] = "爆发破绽标签",
                     ["CharacterState.AbilityState.YaoJu.Cooldown"] = "爆发冷却标签" },
        GAP = 3.5, LATE = 0.25, LATE_AI = 0.1, ONCE = 1.0, n = 0, nAi = 0,
        -- §384 同一次爆发的另一个标签晚到不再算：窗口按那个标签自己的时长（破绽 3.0 秒）。以前一律 ONCE 1 秒：破绽标签比爆发晚一帧挂上、
        -- 中间没再砍，1–3 秒后再砍一刀时它"头一回看到" → 普通刀当成爆发只报 5%。冷却标签 1 秒就掉，过了 1 秒再出现一定是下一次
        ONCE_TAG = { ["CharacterState.AbilityState.YuuBlade.ExplodeCannotDeflect"] = 3.0 },
        DIAG_WIN = 0.5, diagTags = 0, diagAfter = 0, DIAG_MAX = 12 }
function YQX.newSt() return { hp = nil, had = {}, askAt = -100, pend = nil, lastAt = -100 } end
YQX.me, YQX.ai = YQX.newSt(), YQX.newSt()
-- 问一次标签：返回 刚出现的那个标签（没有 = nil）, 身上有没有任何一个
function YQX.ask(st, actor, tn)
    local t = G.tagsMatching(actor, YQX.TAGS) or {}
    local set, has, new = {}, false, nil
    local stale = tn - st.askAt > YQX.GAP
    for _, x in ipairs(t) do
        set[x], has = true, true
        -- 同一次爆发的另一个标签晚到（上次认出爆发后还在这个标签的窗口里）：不再算
        if not new and (stale or not st.had[x]) and tn - st.lastAt >= (YQX.ONCE_TAG[x] or YQX.ONCE) then new = x end
    end
    st.had, st.askAt = set, tn
    if new then st.lastAt = tn end
    return new, has
end
function YQX.refund(p1, hpNow, drop, tn, late, tag)
    local back = drop * (1 - YQX.MULT)
    if not setAttr(p1, "Health", hpNow + back) then return hpNow end
    YQX.n = YQX.n + 1
    out("!! 妖锯妖气爆发：这一下 -%.0f 只留 -%.0f（×%.0f%%，%s%s；§361 / §371，第 %d 次）", drop, drop - back, YQX.MULT * 100,
        YQX.TAG_NAME[tag] or tostring(tag), late and "，标签晚一帧到" or "", YQX.n)
    return hpNow + back
end
-- 一个挨打方的一帧（netJudge 用 YQX.me）：hp = 现在的血。返回 要补的那下, 是不是上一帧那下, 刚出现的标签；不是爆发 = nil
function YQX.step(st, actor, hp, tn)
    local prev = st.hp
    st.hp = hp
    if hp > (prev or hp) + 0.5 then st.pend = nil end              -- 回过血（喝药 / 补满）：等着的那下作废
    local p = st.pend
    if p and tn - p.at > YQX.LATE then st.pend, p = nil, nil end
    local drop = (prev and hp < prev - 0.5) and (prev - hp) or nil
    if not drop and not p then return nil end
    local new, has = YQX.ask(st, actor, tn)
    if not has then
        if drop then st.pend = { drop = drop, at = tn } end          -- 标签可能下一帧才到
        return nil
    end
    st.pend = nil
    if not new then return nil end                                   -- 爆发状态里的后续刀：照常
    -- 这一帧掉了血 → 标签和伤害同一帧到，就是这一下（上一帧记着的那下是普通刀）；这一帧没掉血 → 是上一帧那下
    if drop then return drop, false, new end
    return p.drop, true, new
end
-- netJudge 开头每帧调（在它的早返回之前）：返回补过血之后的血量（没动 = nil）
function YQX.fix(p1, tn)
    local st = YQX.me
    if not (NET.fighting() and BAL.active()) then st.hp, st.pend = nil, nil; return nil end
    local hp = attrOf(p1, "Health")
    if type(hp) ~= "number" then return nil end
    local amount, late, tag = YQX.step(st, p1, hp, tn)
    if not amount then return nil end
    local hp2 = YQX.refund(p1, hp, amount, tn, late, tag)
    st.hp = hp2
    return hp2
end
-- §384 本地 AI 方向要不要问标签：武器平衡开着（和系数表同一个开关；交手 / 对局外木桩由调用方 TOUCH.counts 管，
-- 以前还要 NET.fighting()，对局外打木桩系数表照乘、爆发却不管），而且手上是妖锯或身上有妖锯的 GE（别的武器每刀不多问）
function YQX.mineOn()
    if not BAL.active() then return false end
    local wc, wge = NET.wcStr, NET.wgeStr
    return (type(wc) == "string" and wc:find("/YuuBlade/", 1, true) ~= nil)
        or (type(wge) == "string" and wge:find("GE_YaoJu_", 1, true) ~= nil)
end
function YQX.tagStr(set)
    local l = {}
    for x in pairs(set or {}) do l[#l + 1] = YQX.TAG_NAME[x] or x end
    table.sort(l)
    return #l > 0 and table.concat(l, "+") or "无"
end
-- §384 等着的那一下记进 td=（TOUCH.addDmg 在 main.lua；离线测试没有就直接加）
function YQX.minePay(p, amt)
    if TOUCH.addDmg then TOUCH.addDmg(p.id, amt) else TOUCH.dmg[p.id] = (TOUCH.dmg[p.id] or 0) + amt end
end
-- §384 诊断（前 DIAG_MAX 次）：替身身上这两个标签的变化、认出爆发后 DIAG_WIN 秒内又掉的血（标签比伤害早到时这一下才是爆发）
function YQX.diag(st, tn, d, before)
    local now_ = YQX.tagStr(st.had)
    if now_ ~= before and YQX.diagTags < YQX.DIAG_MAX then
        YQX.diagTags = YQX.diagTags + 1
        out("§384 妖锯：替身身上的爆发标签 %s → %s（这一下 -%.0f）", before, now_, d)
    end
end
-- §371 本地 AI：TOUCH.mark 记 td= 时调（d = 替身本机这一帧掉的血，NET.rai 时）。返回 要报的数, "pend"（标签还没到：调用方这一下先不记，
-- 交给 YQX.minePendSet）。替身血量会被驱动按 AI 回报改写，所以不自己读血量，只在"碰到 + 掉血"那一下问替身身上的标签
function YQX.mine(pup, tn, d)
    local st = YQX.ai
    if not (d and d > 0) then return d end
    if st.pend then local p = st.pend; st.pend = nil; YQX.minePay(p, p.add) end   -- §384 又掉了一下：上一下没等到标签 = 普通刀，照报
    if not YQX.mineOn() then return d end
    if tn > st.lastAt and tn - st.lastAt <= YQX.DIAG_WIN and YQX.diagAfter < YQX.DIAG_MAX then
        YQX.diagAfter = YQX.diagAfter + 1
        out("§384 妖锯：认出爆发后 %.2f 秒替身又掉 -%.0f（照报；要是这一下才是爆发 = 标签比伤害早到，§384 要改）", tn - st.lastAt, d)
    end
    local before = YQX.tagStr(st.had)
    local new, has = YQX.ask(st, pup, tn)
    YQX.diag(st, tn, d, before)
    if not has then return d, "pend" end
    if not new then return d end
    YQX.nAi = YQX.nAi + 1
    out("!! 妖锯妖气爆发（本地 AI，我打替身）：这一下 -%.0f 只报 -%.0f（×%.0f%%，%s；§371 / §384，第 %d 次）", d, d * YQX.MULT, YQX.MULT * 100,
        YQX.TAG_NAME[new] or tostring(new), YQX.nAi)
    return d * YQX.MULT
end
-- TOUCH.mark 算完以后调（YQX.mine 回了 "pend"）：这一下先不进 td=，记着（id = 招式号，add = 这一下该报多少）
function YQX.minePendSet(tn, id, add) YQX.ai.pend = { at = tn, id = id, add = add } end
-- 每帧（TOUCH.watchHp）：等着的那一下 LATE_AI 秒内替身身上标签刚出现 → 只记 MULT；标签一直在（不是刚出现）/ 等过了 → 照记
function YQX.minePend(pup, tn)
    local st = YQX.ai
    local p = st.pend
    if not p then return end
    if tn - p.at > YQX.LATE_AI or not YQX.mineOn() then st.pend = nil; YQX.minePay(p, p.add); return end
    if tn <= p.at then return end                                       -- TOUCH.mark 同一帧刚问过
    local before = YQX.tagStr(st.had)
    local new, has = YQX.ask(st, pup, tn)
    YQX.diag(st, tn, p.add, before)
    if not has then return end
    st.pend = nil
    if not new then YQX.minePay(p, p.add); return end
    YQX.minePay(p, p.add * YQX.MULT)
    YQX.nAi = YQX.nAi + 1
    out("!! 妖锯妖气爆发（本地 AI，我打替身，标签晚一帧到）：第 #%d 招那一下 -%.0f 只报 -%.0f（×%.0f%%，%s；§371 / §384，第 %d 次）",
        p.id, p.add, p.add * YQX.MULT, YQX.MULT * 100, YQX.TAG_NAME[new] or tostring(new), YQX.nAi)
end

-- §371 黑魔伤魔剑（大招 C1 后的 BUFF，GE_Hun_HeiMoShang_Buff，标签 CharacterState.AbilityState.HeiMoShang.Buff）期间的额外剑气 −25%（第五轮）。
-- 剑气不是一招：魔剑期间 45 处动作按标签多放一串子弹，伤害记在当时那一招上，系数表分不开。资产（_tools/gasgraph/heimoshang.json，
-- 判定倍率.csv）：剑气全是名字带 Enhanced 的子弹数据——BD_Hun_HeiMoShang_Enhanced_<招>（重叠判定，0.2 / 0.25 / 0.3，由同名 _Spawner 发射器
-- 飞过去生成，发射器自己没伤害）和 BD_Hun_HeiMoShang_Wave_<招>_Enhanced_NN（剑气波 BP_HeiMoShang_Wave，0.2 / 0.3）；本体刀是
-- BD_Hun_HeiMoShang_<招>_NN（扫掠判定 SweepTrace）和不带 Enhanced 的 Wave_<招>_01（重击自带的波）。木桩实测（实测_木桩_1116）魔剑里
-- 剑气每道单独一帧（AAAAAA 253 / 252 / 552 / 253 / 964 / 253），偶尔和刀同一帧。数值分不开（AAB 本体 0.2 / 0.3 和剑气一样），
-- 只能按"这一下是哪个子弹打的"：挨打方掉血那一帧（攻击方带着魔剑才问）看 ① 游戏的伤害载荷对象 DamageTakenPayload / DamagePreTakePayload
-- （TargetActor = 我、这次新出现的）的 DamageSource 子弹数据名；没有载荷再看 ② 攻击方名下的子弹：剑气子弹跑着 / 刚结束、本体刀没在跑。
-- 只剩剑气 → 这一下补回 25%；刀和剑气同一帧到、认不出 → 不动（宁可这一下照原伤害，也不碰本体刀），记日志。
-- 真人联机：对方魔剑（wge= 带 GE_Hun_HeiMoShang_Buff，§349 替身同步挂上同一个 GE）打我 → netJudge 开头 HQX.fix；
-- 本地 AI：我魔剑打 AI 替身（我发的 wge= 带它）→ TOUCH.mark 里 HQX.mine 把这一下按 75% 报。net/hqx_off.txt 存在 = 整个不做（不用重新部署）
HQX = { MULT = 0.75, BUFF = "GE_Hun_HeiMoShang_Buff", LOGS = 40, logs = 0, n = 0, nAi = 0, hp = nil, seen = nil, seenAi = nil, off = false }
do
    local f = NET_DIR and io.open(NET_DIR .. "/hqx_off.txt", "r")
    if f then f:close(); HQX.off = true; out("§371 有 net/hqx_off.txt：黑魔伤魔剑额外剑气不减") end
end
function HQX.buffOn(wge) return type(wge) == "string" and wge:find(HQX.BUFF, 1, true) ~= nil end
-- 子弹数据名 → "qi"（魔剑剑气）/ "body"（别的有伤害的）/ nil（发射器，不算）
function HQX.kind(bd)
    if not bd then return "body" end
    if bd:find("Spawner", 1, true) then return nil end
    if bd:find("HeiMoShang_Enhanced_", 1, true) or bd:find("^BD_Hun_HeiMoShang_Wave_[%w_]*_Enhanced") then return "qi" end
    return "body"
end
-- G.hitSources 的结果 → "qi" / "body" / "mixed" / "none", 剑气数, 别的数, 认法
function HQX.classify(src)
    local q, b, how = 0, 0, "载荷"
    if src and #src.pay > 0 then
        for _, n in ipairs(src.pay) do
            local k = HQX.kind(n)
            if k == "qi" then q = q + 1 elseif k == "body" then b = b + 1 end
        end
    else
        how = "子弹"
        for _, x in ipairs(src and src.live or {}) do
            local k = HQX.kind(x.bd)
            if k == "qi" and (x.st == 2 or x.st == 3) then q = q + 1
            elseif k == "body" and x.st == 2 then b = b + 1 end
        end
    end
    if q > 0 and b == 0 then return "qi", q, b, how end
    if q > 0 then return "mixed", q, b, how end
    if b > 0 then return "body", q, b, how end
    return "none", q, b, how
end
function HQX.brief(src)
    local p = {}
    for i, n in ipairs(src and src.pay or {}) do if i <= 4 then p[#p + 1] = n end end
    local l = {}
    for _, x in ipairs(src and src.live or {}) do if #l < 6 and (x.st == 2 or x.st == 3) then l[#l + 1] = tostring(x.bd) .. "/" .. tostring(x.st) end end
    return string.format("载荷 %d 个 [%s]，子弹 [%s]", src and #src.pay or 0, table.concat(p, " "), table.concat(l, " "))
end
-- 挨打方（netJudge 开头每帧，YQX.fix 之后）：对方带着魔剑才读血量 / 问来源。返回补过血之后的血量（没动 = nil）
function HQX.fix(p1, pup, tn)
    if HQX.off or not (NET.fighting() and BAL.active()) or not HQX.buffOn(NET.rwge) then HQX.hp, HQX.seen = nil, nil; return nil end
    local hp = attrOf(p1, "Health")
    if type(hp) ~= "number" then return nil end
    local prev = HQX.hp
    HQX.hp = hp
    if prev == nil then HQX.seen = (G.hitSources(p1, pup, nil, true) or {}).seen; return nil end    -- 魔剑刚开：已有的载荷当底
    if not (hp < prev - 0.5) then return nil end
    local drop = prev - hp
    local src = G.hitSources(p1, pup, HQX.seen) or { pay = {}, live = {} }
    HQX.seen = src.seen
    local k, q, b, how = HQX.classify(src)
    if k ~= "qi" then
        if HQX.logs < HQX.LOGS then
            HQX.logs = HQX.logs + 1
            out("§371 黑魔伤魔剑：对方魔剑中我掉血 -%.0f，%s（剑气 %d、别的 %d，按%s）→ 不动；%s", drop,
                k == "mixed" and "刀和剑气同一帧" or (k == "body" and "本体刀" or "认不出来源"), q, b, how, HQX.brief(src))
        end
        return nil
    end
    local back = drop * (1 - HQX.MULT)
    if not setAttr(p1, "Health", hp + back) then return nil end
    HQX.n = HQX.n + 1
    out("!! 黑魔伤魔剑额外剑气：这一下 -%.0f 只留 -%.0f（×%.0f%%，按%s认出剑气 %d 个；§371，第 %d 次）%s", drop, drop - back, HQX.MULT * 100,
        how, q, HQX.n, HQX.n <= 10 and ("；" .. HQX.brief(src)) or "")
    HQX.hp = hp + back
    return HQX.hp
end
-- §371 本地 AI 每帧（TOUCH.watchHp）：我的魔剑刚挂上 → 把场上已有的伤害载荷记成底（之后只看新出现的）；只看状态变化，平时只比一个字符串
function HQX.minePrime(p1, pup)
    local on = not HQX.off and NET.rai and HQX.buffOn(NET.wgeStr) and NET.fighting() and BAL.active() or false
    if on and not HQX.aiOn then HQX.seenAi = (G.hitSources(pup, p1, nil, true) or {}).seen end
    if not on then HQX.seenAi = nil end
    HQX.aiOn = on
end
-- §371 本地 AI（TOUCH.mark，NET.rai 时）：我带着魔剑、我的刀 / 剑气让替身掉了 d → 返回要报的数
function HQX.mine(p1, pup, tn, d)
    if HQX.off or not (d and d > 0 and NET.fighting() and BAL.active()) or not HQX.buffOn(NET.wgeStr) then return d end
    local src = G.hitSources(pup, p1, HQX.seenAi) or { pay = {}, live = {} }
    HQX.seenAi = src.seen
    local k, q, b, how = HQX.classify(src)
    if k ~= "qi" then
        if HQX.logs < HQX.LOGS then
            HQX.logs = HQX.logs + 1
            out("§371 黑魔伤魔剑（本地 AI）：替身掉血 -%.0f，%s（剑气 %d、别的 %d，按%s）→ 照报；%s", d,
                k == "mixed" and "刀和剑气同一帧" or (k == "body" and "本体刀" or "认不出来源"), q, b, how, HQX.brief(src))
        end
        return d
    end
    HQX.nAi = HQX.nAi + 1
    out("!! 黑魔伤魔剑额外剑气（本地 AI，我打替身）：这一下 -%.0f 只报 -%.0f（×%.0f%%，按%s；§371，第 %d 次）", d, d * HQX.MULT, HQX.MULT * 100, how, HQX.nAi)
    return d * HQX.MULT
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
function DOT.active() return NET.fighting() and DOT.on and BAL.active() end

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
        local f = BAL.moveScale(BAL.last, BAL.lastWc)       -- §371 和 BAL.now 同一口径
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
    -- §373 INF.strip 按标签读回：撤掉了才算这一次办完；撤不掉下回（3 帧后）接着撤，日志只记第一次
    local ok = INF.strip(p1, ty)
    local first = s.cutTry ~= s.n
    s.cutTry = s.n
    if ok then s.cutN = s.n end
    if not first and not ok then return end
    DOT.cuts = DOT.cuts + 1
    out("※ %s挂满 %.1f 秒（数值表 ctrl 上限 %.1f 秒，§199）→ 撤掉自己的 %s：%s（第 %d 次；对方替身跟着 inf= 解除）",
        ty.name, tn - s.onAt, cap, ty.lv[1] and ty.lv[1][2] or "?", ok and "已撤" or "撤不掉（标签还在，接着撤）", DOT.cuts)
end

-- §217 本地 AI / 假对手（状态包 ai=1）：td= 按挨打方同一套规则报（用户 11-10 15:02–15:05 炽刃打本地 AI，伤害 100%、武器平衡 + 标准数值：
-- "火焰的 dot 伤害还是太高了""l1+圆圈 现在第一下伤害看起来也是 1500 以上了"）。真人联机里我的招打在对方机器上的替身身上，挨打方按
-- §183.3（裂斩等级 ×1）、§197 / §199.9（CAP 一招上限）、§199.9（持续伤害钉住来源招、压自己的承伤乘法）、§206（冰缓压 _Ice）算；
-- 本地 AI 时是我本机的真角色打本机替身、按"替身掉的血 × 这招系数"报 td=（§115），这几条以前都没做（mp_probe.log）：
--   ① 裂斩第一下 15:02:38 #266 / 15:02:58 #276 报 -3577：替身本机掉约 7300（-3577 ÷ 0.49），是吃了我自己那把 30 级的 ×3.9；
--      真人联机（07:24 双开）挨打方把裂斩按 ×1 算，直接 -917 / -940，3577 ÷ 917 = 3.9。第二段 CB #277 一次 -1246 同理
--      → 报 td= 时按 STD.flatScale 的镜像除掉我那把的本机倍率；标准数值下别的招按 30 级 ÷ 我那把（STD.levelScale 的镜像，30 级的人 ×1）
--   ② CAP：同一套名单 / 应有 / 门槛（攻击力、等级用我的），这招 td= 累计超了按应有报，之后超出的整跳吃掉，招式号过期时记合计
--   ③ 持续伤害：15:04:37 起炽刃 BD 挂的点燃每跳记在我后放的 AB（#376）上、乘 AB 的 0.68 → -72/-73 一跳、累计 -2033。替身是本机对象，
--      像挨打方 §199.9 那样压**替身自己的** TakenReductionMultiplier_<类型> = 钉住 ÷ 我现在这招的报数系数 → td= 每跳 = 掉血 × 现在的系数
--      = 原版 × 钉住（不在 td= 里折算：跳伤和刀同一帧分不开，按伤害类型压只碰跳伤）；我又放了别的招、那招 HOLD 内放开（和挨打方一样，
--      那招本身的火伤 / 血伤不能跟着压）；冰缓按 chill.dmg 压替身的 _Ice
-- 只在 ai=1 + 交手中 + 武器平衡开（DOT.active）时动，只写替身的当前值（不进存档）；真人联机（ai≠1）不进来。跳伤仍记在我当时最新的那招上
-- （td= 只能按招式号报，挨打方 netJudge 也是记在当时开着的判定窗口上），但数按来源招钉住
AIF = { LOG_MAX = 30, logs = 0, SRC_WIN = 1.0, capN = 0, fireAt = -100, hitAt = -100,
        FLAT = "^GA_GlobalActionAbilit%a*_LieZhan_", KINDS = { "ignite", "bleed", "poison", "chaos" },
        src = {}, lvl = {}, taken = {}, capped = {} }
function AIF.say(fmt, ...)
    if AIF.logs >= AIF.LOG_MAX then return end
    AIF.logs = AIF.logs + 1
    out(fmt, ...)
end
-- §359 上限改了伤害的那两条单独计数：以前和等级系数 / 冰缓 / 持续伤害共用 30 行，冰缓来回几次就用完，之后截伤害一行不记
-- （11-16 玩家日志 17:48 之后荡寇 / 青铜剑大招被截全是静默的）。前 60 次都记，之后每 20 次记一次
AIF.CAP_LOG_MAX, AIF.capLogs = 60, 0
function AIF.capSay(fmt, ...)
    AIF.capLogs = AIF.capLogs + 1
    if AIF.capLogs > AIF.CAP_LOG_MAX and AIF.capLogs % 20 ~= 0 then return end
    out(fmt, ...)
end
function AIF.name(id) return id and ((NET.evBal and NET.evBal[id]) or (NET.evName and NET.evName[id])) or nil end
-- 我手上这把（edge = 影之武装）的本机等级倍率（手上的一定装着）；认不出 / 读不到 → nil
function AIF.myMult(edge, id)
    id = id or STD.idOf(edge and NET.wcsStr or NET.wcStr)
    if not id then return nil end
    local m = STD.localMult(id, edge)
    if not m or m <= 0 then return nil end
    return m, id
end
-- 我这一招报 td= 时补的等级系数（挨打方 LO.rescale 里等级那一截的镜像），返回 系数, 说明
function AIF.lvAdj(name)
    if not name then return 1.0 end
    if BAL.active() and name:find(AIF.FLAT) then
        local m, id = AIF.myMult(false, AIF.flatW)
        if not m then return 1.0, "裂斩按 ×1（我那把认不出 / 等级读不到）" end
        return 1.0 / m, string.format("裂斩按 ×1：我 %s 本机倍率 %.2f 除掉（挨打方 §183.3 同一套）", id, m)
    end
    if STD.active() then
        local m, id = AIF.myMult(LO.isEdgeAttack(name))
        if not m then return 1.0 end
        return STD.TARGET_MULT / m, string.format("标准数值 30 级 %.2f ÷ 我 %s 本机倍率 %.2f", STD.TARGET_MULT, id, m)
    end
    return 1.0
end
-- 我这一招 td= 的报数系数（不含 CAP / 火枪）
function AIF.factor(id) return TOUCH.scale(id) * AIF.lvAdj(AIF.name(id)) end
-- TOUCH.noteFire 里、我放攻击招时调：记时刻 / 招式号；记下手上认得出的主武器（裂斩时手上是占位武器 MoQie，认不出）
function AIF.noteFire(n, id, tn)
    AIF.fireAt, AIF.fireId = tn, id
    local w, shachi = STD.idOf(NET.wcStr)
    if w and not shachi then AIF.flatW = w end
end
-- TOUCH.mark 记 td= 时调（add = 已乘系数的这一下）：补等级系数，记日志（每种说明第一次）
function AIF.level(id, add)
    local name = AIF.name(id)
    local k, why = AIF.lvAdj(name)
    if k ~= 1.0 and why and why ~= AIF.lvWhy then
        AIF.lvWhy = why
        AIF.say("§217 本地 AI：我第 #%d 招 %s 报 td= 时等级系数 ×%.3f（%s）", id, tostring(name), k, why)
    end
    return add * k
end
-- 我的攻击力 / 这一招的等级倍率（CAP.expected 用；标准数值时交给 CAP 自己按 30 级）
function AIF.myAtk()
    if STD.active() then return nil end
    local p1 = getP1()
    local a = valid(p1) and attrOf(p1, "Attack")
    return type(a) == "number" and a > 0 and a or nil
end
function AIF.myLm(name)
    if STD.active() then return nil end
    return (AIF.myMult(name and LO.isEdgeAttack(name))) or STD.mult(30)
end
-- §197 / §199.9 CAP 的镜像：这招 td= 累计超过应有 × 门槛 → 这一下只报到应有；改过一次以后门槛 ×1、超出的整跳吃掉
function AIF.cap(id, add, tn)
    local mp = AIF.mpCtx; AIF.mpCtx = nil
    local fight = (mp and mp.fight ~= nil) and mp.fight or (MATCH.state == "fight")
    if not fight or add <= 0 then return add end
    local name = AIF.name(id)
    local exp, why, slack = CAP.expected(name, AIF.myAtk(), AIF.myLm(name))
    if not exp and CAP.ALL_MODE == "on" then exp, why, slack = CAP.allExpected(name, AIF.myAtk(), AIF.myLm(name), NET.evWc and NET.evWc[id]) end   -- §339 只在真开时
    if not exp then return add end
    local ck = (mp and mp.key) or id
    local prev = (mp and mp.prev ~= nil) and mp.prev or (TOUCH.dmg[id] or 0)
    local c = AIF.capped[ck]
    if prev + add <= exp * (c and 1.0 or slack or CAP.SLACK) then return add end
    local allow = math.max(0, exp - prev)
    if c then
        c.n, c.eat = c.n + 1, c.eat + (add - allow)
        return allow
    end
    AIF.capped[ck] = { name = name, n = 0, eat = 0 }
    AIF.capN = AIF.capN + 1
    AIF.capSay("!! 本地 AI 绕过平衡的一下：我第 #%d 招 %s / 本机报 -%.0f（这招累计 -%.0f）/ 改成 -%.0f（累计 -%.0f；%s，超过 ×%.2f 才改；之后这招再超出的整跳吃掉；§197 挨打方同一套，§217，第 %d 次）%s",
        id, name, add, prev + add, allow, prev + allow, why, slack or CAP.SLACK, AIF.capN, CAP.lowNote and CAP.lowNote(name) or "")
    return allow
end
-- TOUCH.wire 把招式号过期时调：被吃过跳的那招记一行合计
function AIF.flush(id, reportedDmg)
    local c = AIF.capped[id]
    if not c then return end
    AIF.capped[id] = nil
    if c.n > 0 then
        AIF.capSay("!! 本地 AI 绕过平衡：我第 #%d 招 %s 改过之后又吃掉 %d 跳、共 -%.0f（td= 这招停在 -%.0f；§217）", id, c.name or "?", c.n, c.eat, reportedDmg or TOUCH.dmg[id] or 0)
    end
end
-- 替身挂上一种持续伤害：来源 = 1 秒内刚打中替身的招，没有就按 HOLD 内我放的招；钉住 = 伤害倍率 × 等级系数 × 持续系数（挨打方 DOT.onStart 的镜像）
function AIF.onStart(kind, tn)
    local id, how
    if AIF.hitId and tn - AIF.hitAt <= AIF.SRC_WIN then id, how = AIF.hitId, "刚打中替身的招"
    elseif AIF.fireId and tn - AIF.fireAt < BAL.HOLD then id, how = AIF.fireId, "我刚放的招" end
    local name = AIF.name(id)
    if not name then
        AIF.src[kind] = nil
        AIF.say("※ 持续伤害（本地 AI）：替身%s了，来源招不明（1 秒内没打中、我没在放招）→ 不钉，跟我当时那招的系数报", DOT.NAME[kind])
        return
    end
    local base = NET.atkScale(false) * AIF.lvAdj(name)
    local d, why = BAL.dotScale(name)
    AIF.src[kind] = { id = id, name = name, pin = base * d, at = tn }
    AIF.say("※ 持续伤害（本地 AI）：替身%s了，来源 我第 #%d 招 %s（%s）%s ×%.2f → 整个持续期间 td= 按 ×%.3f 报（不跟我后来的招变；§199 挨打方同一套，§217）",
        DOT.NAME[kind], id, name, how, why, d, base * d)
end
-- 替身自己的承伤乘法该乘多少（nil = 不动，第二个是原因）
function AIF.ratio(kind, tn)
    if kind == "chill" then
        local m = BAL.chill("dmg")
        if not m or m >= 1 - 1e-3 then return nil, "数值表 chill.dmg = 1（冰缓伤害不管）" end
        if (AIF.lvl.frost or 0) > 0 or (AIF.frostAcc or 0) >= DOT.CHILL_ACC then AIF.chillAt = tn end
        if not AIF.chillAt or tn - AIF.chillAt > DOT.CHILL_LINGER then return nil, "冰缓结束" end
        return math.max(DOT.TAKEN_MIN, m)
    end
    local s = AIF.src[kind]
    if not s then return nil end
    if AIF.fireAt > s.at and tn - AIF.fireAt < BAL.HOLD then return nil, "我在放别的招" end
    local cur = AIF.factor(PRED.myAttackId())
    if not cur or cur <= 0 then return nil end
    local k = s.pin / cur
    if k >= 1 - 1e-3 then return nil, "不用压" end
    return math.max(DOT.TAKEN_MIN, k)
end
-- 写回一种：当前值还是我们写的才写回（游戏中途重算过就不碰）
function AIF.back(pup, kind, why)
    local t = AIF.taken[kind]
    if not t then return end
    AIF.taken[kind] = nil
    if pup and valid(pup) then
        local c = attrOf(pup, t.a)
        if type(c) == "number" and t.want and math.abs(c - t.want) < 1e-4 then G.setAttrCur(pup, t.a, t.orig) end
    end
    AIF.say("※ 持续伤害（本地 AI）：替身的 %s 写回 %.4g（%s）", t.a, t.orig or 1, why)
end
function AIF.reset(pup, why)
    pup = pup or AIF.pup
    for kind in pairs(AIF.taken) do AIF.back(pup, kind, why) end
    AIF.src, AIF.lvl, AIF.chillAt, AIF.frostAcc = {}, {}, nil, nil
end
-- TOUCH.watchHp 每帧调（量完血之后）：每 INF.EVERY 帧看替身身上的异常，按 ratio 写 / 写回替身的 TakenReductionMultiplier_<类型> 当前值
function AIF.step(pup, tn)
    if not (NET.rai and DOT.active()) then
        if next(AIF.taken) or next(AIF.src) or next(AIF.lvl) then AIF.reset(pup, "不在交手 / 武器平衡关 / 不是本地 AI") end
        return
    end
    local key = pathOf(pup)
    if AIF.pupKey ~= key then
        if AIF.pupKey then AIF.reset(nil, "换了替身") end
        AIF.pupKey = key
    end
    AIF.pup = pup
    local ticks = ST.ticks or 0
    if ticks % INF.EVERY ~= 0 then return end
    local lv = INF.levels(pup)
    for _, kind in ipairs(AIF.KINDS) do
        local l, was = lv[kind] or 0, AIF.lvl[kind] or 0
        if l > 0 and was == 0 then AIF.onStart(kind, tn)
        elseif l == 0 and was > 0 then
            local s = AIF.src[kind]
            if s then AIF.say("※ 持续伤害（本地 AI）：替身%s结束了（来源 我第 #%d 招 %s，钉了 %.1f 秒）", DOT.NAME[kind], s.id, s.name, tn - s.at) end
            AIF.src[kind] = nil
        end
        AIF.lvl[kind] = l
    end
    AIF.lvl.frost = lv.frost or 0
    if AIF.frostAcc == nil or ticks % INF.ACC_EVERY == 0 then AIF.frostAcc = attrOf(pup, "Frost_Accumulation") or 0 end
    for kind, a in pairs(DOT.TAKEN) do
        local k, why = AIF.ratio(kind, tn)
        local t = AIF.taken[kind]
        if k then
            local c = attrOf(pup, a)
            if type(c) == "number" then
                if not t then t = { a = a }; AIF.taken[kind] = t end
                if not t.want or math.abs(c - t.want) >= 1e-4 then t.orig = c end
                local want = t.orig * k
                if math.abs(c - want) >= 1e-4 and G.setAttrCur(pup, a, want) then
                    if not t.k or math.abs(t.k - k) > 0.01 * t.k then
                        if kind == "chill" then
                            AIF.say("※ 冰缓（本地 AI）：替身的 %s %.4g→%.4g（×%.3f，数值表 chill.dmg %.2g；§206 挨打方同一套，§217）", a, t.orig, want, k, BAL.chill("dmg"))
                        else
                            local s = AIF.src[kind]
                            AIF.say("※ 持续伤害（本地 AI）：%s 替身的 %s %.4g→%.4g（×%.3f = 钉住 %.3f ÷ 我现在这招 ×%.3f；td= 跳伤按来源 #%d 报；§217）",
                                DOT.NAME[kind], a, t.orig, want, k, s.pin, s.pin / k, s.id)
                        end
                    end
                    t.want, t.k = want, k
                end
            end
        elseif t then
            AIF.back(pup, kind, why or "持续伤害结束")
        end
    end
end

-- 每次驱动 + 替身放招前：攻击力系数 = 伤害倍率 × （武器平衡系数，没有就按影之武装），写进替身
function LO.rescale(pup, tn)
    LO.atkDm = NET.dmgNow()
    local edge = ST.pupEdgeAt and tn - ST.pupEdgeAt < LO.EDGE_HOLD
    if not edge and BAL.active() and BAL.edgeHeld(tn) then edge = true end      -- 11.22 影武长按保持期
    local f, why = BAL.now(tn)
    if f then LO.atkScale, LO.scaleWhy = NET.atkScale(false) * f, why
    else LO.atkScale, LO.scaleWhy = NET.atkScale(edge), nil end
    if CHR and CHR.muted and CHR.muted(tn) then       -- §255.1 切形态中间步：对方没放这招，不出伤害
        LO.atkScale, LO.scaleWhy = 0, "§255.1 切形态中间步（对方没放这招）×0"
    end
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
    -- §性能（11-19）：以前靠一个全局 LO.stdWhy 去重，多替身武器不同时会来回跳（日志 11-19 一天刷 2370 行同样的字）。
    -- 改成按"名字|说明|系数"记，每种只写一次
    if lwhy then
        LO.stdWhy = LO.stdWhy or {}
        local sk = string.format("%s|%s|%.2f", lname, lwhy, lf)
        if not LO.stdWhy[sk] then
            LO.stdWhy[sk] = true
            local cnt = 0
            for _ in pairs(LO.stdWhy) do cnt = cnt + 1 end
            if cnt <= 30 then out("%s：替身等级系数 ×%.2f（%s）", lname, lf, lwhy) end
        end
    end
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
        .. "|zm" .. tostring(NET and NET.rzmb) .. (STD.active() and ("|w" .. tostring(NET and NET.rwge)) or "")   -- §349 对方损血增伤 / 武器状态变了也重写
    local first = key ~= LO.appliedKey
    local forced = LO.dirty                                     -- §338 替身补技能 / 换武器 / 挂摘效果后：不等 60 帧
    if not first and not forced and ST.ticks - (LO.appliedAt or 0) < 60 then return end
    LO.dirty = nil
    local onlyScale = first and attKey == LO.appliedAttKey      -- 只是系数变了：日志短一点
    local vals = {}
    for n, v in att:gmatch("([%w_]+):([%-%d%.e+]+)") do vals[n] = tonumber(v) end
    if STD.active() then vals.Attack, vals.ShachiAttack = STD.ATTR.Attack, STD.ATTR.ShachiAttack end   -- §144 攻击用基准
    -- §349 攻击方状态：标准数值时基准 × 替身身上的魔剑 / 狂暴乘数（不是标准数值时对方 att= 里的攻击力已经带着，不再乘）；
    -- 损血增伤两种都乘（对方 att= 里没有它，游戏是在伤害里加的）
    local why349 = {}
    if STD.active() and STD.stateMods then
        local sadd, smadd, scomp, ssig = STD.stateMods(pup)
        for _, a in ipairs({ "Attack", "ShachiAttack" }) do
            vals[a] = (vals[a] + (sadd[a] or 0)) * (1 + (smadd[a] or 0)) * (scomp[a] or 1)
        end
        if ssig ~= "" then why349[#why349 + 1] = ssig end
    end
    local zd, za = 0, 0
    if ABUF then zd, za = ABUF.rzm() end
    if zd > 0 then vals.Attack = (vals.Attack or LO.neutral("Attack")) * (1 + zd); why349[#why349 + 1] = string.format("损血增伤 +%.0f%%", zd * 100) end
    if za > 0 then vals.ShachiAttack = (vals.ShachiAttack or LO.neutral("ShachiAttack")) * (1 + za); why349[#why349 + 1] = string.format("损血杀气 +%.0f%%", za * 100) end
    local sig349 = table.concat(why349, "，")
    local pk = pathOf(pup)
    if ABUF and sig349 ~= (ABUF.pupSig[pk] or "") then
        ABUF.pupSig[pk] = sig349
        ABUF.pupLogs = (ABUF.pupLogs or 0) + 1
        if ABUF.pupLogs <= 80 or ABUF.pupLogs % 20 == 0 then
            out("§349 替身攻击力跟着对方状态：%s（Attack 按 %.4g、ShachiAttack 按 %.4g 写，再乘系数 ×%.2f）", sig349 ~= "" and sig349 or "没有状态加成",
                vals.Attack or -1, vals.ShachiAttack or -1, LO.atkScale)
        end
    end
    local nSet, changed, reset = 0, {}, {}
    LO.lastWant = LO.lastWant or {}
    for _, n in ipairs(names) do
        local want = DOT.want(n, (vals[n] or LO.neutral(n)) * (LO.SCALED[n] and LO.atkScale or 1.0))   -- §199
        local cur = attrOf(pup, n)
        if type(cur) == "number" and math.abs(cur - want) > 1e-4 then
            -- §338 包和系数都没变（不是 first）还对不上 = 游戏自己把它改了；只记攻击力两项
            if not first and LO.SCALED[n] then reset[#reset + 1] = string.format("%s %.4g（模组写的 %.4g）", n, cur, want) end
            if setAttr(pup, n, want) then
                nSet = nSet + 1
                if first and #changed < 8 then changed[#changed + 1] = string.format("%s %.4g→%.4g", n, cur, want) end
            end
        end
        if LO.SCALED[n] then LO.lastWant[n] = want end
    end
    if #reset > 0 then
        LO.resetN = (LO.resetN or 0) + 1
        if LO.resetN <= 30 or LO.resetN % 20 == 0 then
            out("§338 替身攻击力被游戏改过：%s；距上次写 %d 帧，%s发现，已改回（第 %d 次）", table.concat(reset, "，"),
                ST.ticks - (LO.appliedAt or ST.ticks), forced and ("事件「" .. forced .. "」后") or "定时检查", LO.resetN)
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
LO.removeGE, LO.weaponEffects, LO.wgePath, LO.ensureCombat = G.LO.removeGE, G.LO.weaponEffects, G.LO.wgePath, G.LO.ensureCombat      -- §118 武器效果同步 / §239 战斗状态
LO.WGE_STATE, LO.cdoNums = G.LO.WGE_STATE or {}, G.LO.cdoNums       -- §349 攻击方武器状态 / 读默认对象
LO.GE_COMBAT = G.LO.GE_COMBAT      -- §261 PCB.on / off 要它（11-13 实测：漏拷 → nil → StaticFindObject(nil) 报错，每回合开打 §261 都没挂上）
LO.snapInfo, LO.swtCooldown = G.LO.snapInfo, G.LO.swtCooldown      -- §245 Snap 的 Min Snap Range / 切武器冷却
LO.activeInstance, LO.funcsLike, LO.callNoArg, LO.callArgs = G.LO.activeInstance, G.LO.funcsLike, G.LO.callNoArg, G.LO.callArgs  -- §119 紫冥剑实验 / §139.4
LO.bulletsOf = G.LO.bulletsOf      -- §179 紫冥剑肩上的飞剑
LO.propsLike, LO.targetingComp, LO.tcSetLock = G.LO.propsLike, G.LO.targetingComp, G.LO.tcSetLock
LO.paramTypes, LO.lockCandidates, LO.paramList, LO.tcStop = G.LO.paramTypes, G.LO.lockCandidates, G.LO.paramList, G.LO.tcStop

-- §338 替身补技能 / 换武器 / 切序号 / 挂摘效果成功后，游戏可能重算替身的攻击属性（11-15 玩家日志 22:40:02：补 GA_Hun_Tang_Stance_C
-- 1 秒后乱莺 A 打出 −1294，约等于没压过的攻击力 780 算的一下）。以前 LO.apply 只在系数 / 包变了时立刻重写、否则 60 帧查一次，
-- 中间这段打中的就是没压的。现在这些调用成功、而且对象是替身 → 标记，下一帧 LO.apply 立刻重写（按事件，不加轮询）
function LO.atkDirtyFor(actor, why)
    if LO.dirty then return end
    local pup = G.puppet and G.puppet()
    if valid(pup) and valid(actor) and (actor == pup or pathOf(actor) == pathOf(pup)) then LO.dirty = why end
end
do
    local function wrap(name, label)
        local f = LO[name]
        if type(f) ~= "function" then return end
        LO[name] = function(actor, a2, ...)
            local r1, r2 = f(actor, a2, ...)
            if r1 then LO.atkDirtyFor(actor, label .. (type(a2) == "string" and (" " .. (a2:match("([^./]+)$") or a2)) or "")) end
            return r1, r2
        end
    end
    wrap("give", "补技能"); wrap("applyGE", "挂效果"); wrap("removeGE", "摘效果")
    wrap("setSlot", "换武器"); wrap("switchTo", "切武器序号")
end
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
        local offShield = SHIELD and SHIELD.isCfg(held) and not SHIELD.isCfg(want)      -- §302 替身换下拙壁盾
        if LO.trySwitch(pup, slot, idx, want, held, st) then
            if offShield then SHIELD.sweep(pup, "替身换下拙壁盾") end
            return
        end
        local ok, err = pcall(function() cwc:SetSlotWeapon(slot, idx, cfg) end)
        out("替身换装（%s）SetSlotWeapon(序号 %d) %s → %s：%s", label, idx, LO.short(held), LO.short(want),
            ok and "调用成功" or ("失败 " .. tostring(err)))
        if ok and offShield then SHIELD.sweep(pup, "替身换下拙壁盾") end
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

-- §249 报告 §2.4 与 11.20 QuickCharge：这些招有 BD、会打人，但被 isAttackAbility / LO.isEdgeAttack 的排除词挡住
-- （ToZui / Stance / GuardPoint / 名字不带 GA_Hun_ 前缀）。表驱动，别在函数里再散字符串。
-- 值 "edge" = 影之武装（LO.isEdgeAttack 也认，平衡按 0.35 那套）；"atk" = 只算攻击（主武器，不套影武系数）。
-- 不加 GA_Hun_DualHook_GEx_C：抓取处决，对局里禁用（报告 §2.4 / §3.6）。
ATK_EXTRA = {
    GA_Hun_ChiZheCanJian_C_ToZui_C = "atk",
    GA_Hun_YanYueDao_Stance_C = "atk",
    GA_TieKuangQuanTao_GuardPoint_C = "edge",
    GA_TigerCannon_QuickCharge_C = "edge",
    GA_XieShan_LightningIce_PerfectDeflect_C = "atk",
    GA_XieShan_LightningIce_PerfectDeflect_FullCharge_C = "atk",
}

-- 影之武装的攻击技能（开判定窗口用）：路径在 ShachiAbility/ 下，排除被动 / 处决 / 架势类
function LO.isEdgeAttack(n)
    if ATK_EXTRA[n] == "edge" then return true end      -- §249 铁矿拳套 GuardPoint：路径在 ShachiAbility/，但名字带 GuardPoint
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
    if SHIELD then pcall(SHIELD.watchMine, p1) end           -- §302 我换下拙壁盾：清一次残留
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
    -- §349 我身上的武器状态（魔剑 / 狂暴 / 双钺强化 / 鸣剑）变了记一行（前 60 次）：复测看发没发出去、双钺二阶在不在效果表里
    local stl = {}
    for _, id in ipairs(list or {}) do
        if (LO.WGE_STATE and LO.WGE_STATE[id]) or id:find("LuanYing_Buff", 1, true) then stl[#stl + 1] = id:match("([%w_]+)$") end
    end
    stl = table.concat(stl, " ")
    if list and stl ~= (LO.wgeSt or "") and (LO.wgeStN or 0) < 60 then
        LO.wgeStN = (LO.wgeStN or 0) + 1
        out("§349 我的武器状态（wge= 发给对方）：%s", stl ~= "" and stl or "（无）")
    end
    if list then LO.wgeSt = stl end
    return list and table.concat(list, ",") or ""
end

-- §223 观战替身也用这一套：wge / st 由调用方给（st = 这个替身自己的记录表）；不给 = 对战替身（NET.rwge，记录在 LO 上）
function LO.syncWge(pup, wge, st)
    if st == nil then wge, st = NET.rwge, LO end
    if wge == nil then return end          -- 旧版对方没有这个字段：不动替身
    if SHADOWPASSIVES then SHADOWPASSIVES.puppetStep(pup, G.now()) end
    local pp = pathOf(pup)
    local zmOwn = st == LO and NET.rzmb ~= nil        -- §349 对方自己算损血增伤（zmb=）：替身不挂那个 GE，防算两次
    local key = pp .. "|" .. wge .. (zmOwn and "|zm" or "")
        .. (SHADOWPASSIVES and SHADOWPASSIVES.blocked(SHADOWPASSIVES.paths[1]) and "|shadow" or "")
    if key == st.wgeKey then return end
    local tick = ST and ST.ticks or 0
    if st.wgePendingKey == key and tick >= (st.wgeRetryFrom or 0) and tick < (st.wgeRetryAt or 0) then return end
    st.wgeKey = nil
    if st.wgeFor ~= pp then st.wgeFor, st.wgeOn = pp, {} end
    local want, added, removed, n, complete = {}, {}, {}, 0, true
    for id in wge:gmatch("[%w_/]+") do
        n = n + 1
        if not (zmOwn and id == ABUF.ZM_GE)
            and not (SHADOWPASSIVES and SHADOWPASSIVES.blocked(id)) then want[id] = true end
    end
    for id in pairs(want) do
        local ck = pp .. "|" .. LO.wgePath(id)            -- 和 CHG.upgrade 同一个记号：§92.7 补过的不再上
        if not st.wgeOn[id] and not CHG.applied[ck] then
            local ok, applied, handle = pcall(LO.applyGE, pup, LO.wgePath(id), "替身武器效果 " .. id)
            local value = ok and applied == true and rawProp(handle, "Handle") or nil
            if type(value) == "number" and value >= 0 then
                st.wgeOn[id], CHG.applied[ck] = true, true
                added[#added + 1] = id
            else complete = false end
        end
    end
    for id in pairs(st.wgeOn) do
        if not want[id] then
            local allowed = not (SHADOWPASSIVES and SHADOWPASSIVES.blocked(id)) or SHADOWPASSIVES.allowRemove(pup, LO.wgePath(id))
            local ok, removedGE = false, false
            if allowed then ok, removedGE = pcall(LO.removeGE, pup, LO.wgePath(id), "替身去掉武器效果 " .. id) end
            if ok and removedGE == true then
                st.wgeOn[id], CHG.applied[pp .. "|" .. LO.wgePath(id)] = nil, nil
                removed[#removed + 1] = id
            else complete = false end
        end
    end
    -- A failed add/remove is not cached as success; retries are per actor/state and bounded by ticks.
    if complete then
        st.wgeKey, st.wgePendingKey, st.wgeRetryAt, st.wgeRetryFrom = key, nil, nil, nil
    else
        st.wgePendingKey, st.wgeRetryFrom, st.wgeRetryAt = key, tick, tick + 30
    end
    if #added + #removed > 0 then
        out("替身武器效果同步：对方 %d 个；补上 %s；去掉 %s", n, #added > 0 and table.concat(added, " ") or "-",
            #removed > 0 and table.concat(removed, " ") or "-")
        -- §349 攻击方状态（魔剑 / 狂暴 / 双钺强化 / 鸣剑）挂上 / 摘掉单独记一行，复测看这行
        local sa = {}
        for _, id in ipairs(added) do if LO.WGE_STATE and LO.WGE_STATE[id] or id:find("LuanYing_Buff", 1, true) then sa[#sa + 1] = "+" .. id:match("([%w_]+)$") end end
        for _, id in ipairs(removed) do if LO.WGE_STATE and LO.WGE_STATE[id] or id:find("LuanYing_Buff", 1, true) then sa[#sa + 1] = "-" .. id:match("([%w_]+)$") end end
        if #sa > 0 then
            if st == LO then LO.dirty = LO.dirty or "§349 对方武器状态" end     -- 魔剑 / 狂暴改攻击：下一帧 LO.apply 按新乘数重写
            out("§349 替身武器状态跟着对方：%s", table.concat(sa, " "))
        end
    end
end

-- ============================================================ §349 攻击方身上的武器状态加伤（替身同步 + 斩马刀损血增伤）
-- 原理：挨打方掉多少血由挨打方本机的替身放招算，攻击方自己身上的状态没同步到替身，线上就没有这份加伤
-- （11-16 两开：斩马刀放血后 A 137 = 不放血 137）。分三类：
--  ① 状态 GE（黑魔伤魔剑 / 妖锯狂暴 / 天煞双钺强化一二阶，LO.WGE_STATE；乱莺鸣剑 Buff 以前就发）随 wge= 发，替身挂上同一个 GE →
--     标签门控的额外剑气 / 高倍率判定游戏自己放。发送时机按事件：我放 / 收这几把武器的招后几帧重算 wge=（以前只每 90 帧一次，
--     鸣剑 10 秒的状态前 3 秒的招赶不上）
--  ② 改攻击属性的状态（魔剑 / 狂暴 Attack ×1.2、ShachiAttack ×0.33）：标准数值把攻击锁成基准，STD.writeAttrs（本机）/ LO.apply（替身）
--     都按 STD.stateMods 的乘数锁（以前每 2 秒写回 200：11-16 15:37:31 C1 后 Attack 200→240，15:37:33"属性被改回去了，重写 240→200"）
--  ③ 斩马刀损血增伤（原生 GA_ZhanMa_SustainedBloodPassive：DamageBonusPerSecond / MaxDamageBonus 0.25，按"身上有待结算的虚血"计时；
--     替身血量是同步写进去的、没有虚血，复现不了）：攻击方按模型自己算，发 zmb=<伤害加成>:<杀气加成>；挨打方替身攻击力 ×(1 + 加成)，
--     替身不挂 GE_ZhanMa_SustainedBlood（LO.syncWge）。模型（11-16 木桩 + 两开）：放血招（B / BB / AB …）出手后约 1 秒开始计时，
--     每秒 +0.02（木桩 B 1.04 → B 1.14 → BB 1.16 → A 1.20 → AA 1.22 → AAA 1.24，一秒一下），上限 0.25；最后一次放血 12 秒后
--     虚血结算（两开 B / BB 后都是 12 秒自己掉血 309 / 463），计时结束
ABUF = { TRIG = { "HeiMoShang", "YuuBlade", "ShuangYue", "LuanYing" },
         ATK_GE = { GE_Hun_HeiMoShang_Buff = true, GE_Hun_YuuBlade_Buff = true },
         ZM_GE = "ZhanMaBlade/UpgradeData/GE_ZhanMa_SustainedBlood",
         ZM_CDO = "/PBZCombatAsset/ActorData/Players/Hun/Weapon/ZhanMaBlade/UpgradeData/GA_ZhanMa_SustainedBlood_BP.Default__GA_ZhanMa_SustainedBlood_BP_C",
         ZM_TRIG = "^GA_Hun_ZhanMa_A*B+_C$", ZM_LAG = 1.0, ZM_DELAY = 12.0, ZM_SANE = 0.5,
         ZM_DEF = { DamageBonusPerSecond = 0.02, MaxDamageBonus = 0.25, AngerDamageBonusPerSecond = 0, MaxAngerDamageBonus = 0 },
         ZM_KEYS = { "DamageBonusPerSecond", "MaxDamageBonus", "AngerDamageBonusPerSecond", "MaxAngerDamageBonus" },
         zm = nil, zmP = nil, zmTry = 0, zmLogs = 0, zmCat = "0", due = {}, pupSig = {} }

-- 我放 / 收一个技能（netSend 里新出现 / 消失的那一帧调，事件触发）：这几把武器的招 → 几帧后重算 wge=；放血招 → 开始 / 续上计时
function ABUF.onAbility(n, tn, started)
    for _, k in ipairs(ABUF.TRIG) do
        if n:find(k, 1, true) then
            local t = ST.ticks
            if #ABUF.due < 8 then
                if started then ABUF.due[#ABUF.due + 1] = t + 3; ABUF.due[#ABUF.due + 1] = t + 20     -- 状态多在出手后一会儿才挂上
                else ABUF.due[#ABUF.due + 1] = t + 2 end
            end
            break
        end
    end
    if started and n:match(ABUF.ZM_TRIG) then ABUF.zmHit(tn) end
end

-- netSend 算 wge= 前问：有到点的就重算（到点的清掉）
function ABUF.wgeDue(ticks)
    local hit = false
    for i = #ABUF.due, 1, -1 do
        if ticks >= ABUF.due[i] then hit = true; table.remove(ABUF.due, i) end
    end
    return hit
end

-- 损血增伤的参数：游戏默认对象上读（原生默认值，资产里只写了 MaxDamageBonus 0.25）；读不到 3 次按实测
function ABUF.zmParams()
    if ABUF.zmP then return ABUF.zmP end
    ABUF.zmTry = ABUF.zmTry + 1
    local got = LO.cdoNums and LO.cdoNums(ABUF.ZM_CDO, ABUF.ZM_KEYS)
    local r = got and got.DamageBonusPerSecond
    if r and r > 0 and r < 1 then
        local p = {}
        for _, k in ipairs(ABUF.ZM_KEYS) do p[k] = got[k] or ABUF.ZM_DEF[k] end
        ABUF.zmP = p
        out("§349 斩马刀损血增伤参数（游戏默认对象）：伤害每秒 +%.3f、上限 %.2f；杀气每秒 +%.3f、上限 %.2f", p.DamageBonusPerSecond,
            p.MaxDamageBonus, p.AngerDamageBonusPerSecond, p.MaxAngerDamageBonus)
    elseif ABUF.zmTry >= 3 then
        ABUF.zmP = ABUF.ZM_DEF
        out("§349 斩马刀损血增伤参数：默认对象读不到（%s），按 11-16 木桩实测 每秒 +0.02、上限 0.25（杀气加成不算）",
            got and "DamageBonusPerSecond 不对" or "对象没载入")
    end
    return ABUF.zmP or ABUF.ZM_DEF
end

-- 我放了放血招：没在计时（或上一段虚血已经结算）→ 约 1 秒后开始计时；结束时间往后推到这次 + 12 秒
function ABUF.zmHit(tn)
    local z = ABUF.zm
    if not z or tn >= z.endAt then z = { start = tn + ABUF.ZM_LAG }; ABUF.zm = z end
    z.endAt = tn + ABUF.ZM_LAG + ABUF.ZM_DELAY
end

-- 现在的加成（纯函数）：返回 伤害加成, 杀气加成
function ABUF.zmBonus(z, tn, p)
    if not z or tn >= z.endAt or tn <= z.start then return 0, 0 end
    local s = tn - z.start
    return math.min(p.MaxDamageBonus or 0, (p.DamageBonusPerSecond or 0) * s),
        math.min(p.MaxAngerDamageBonus or 0, (p.AngerDamageBonusPerSecond or 0) * s)
end

-- 发：我身上有损血增伤这件升级（wge= 里有）才发 zmb=（发了 = 新版，对方替身就不挂那个 GE、按这个数乘）
function ABUF.zmWire(tn)
    if not (NET.wgeStr and NET.wgeStr:find(ABUF.ZM_GE, 1, true)) then return "" end
    local p = ABUF.zmParams()
    local d, a = ABUF.zmBonus(ABUF.zm, tn, p)
    if ABUF.zm and tn >= ABUF.zm.endAt then ABUF.zm = nil end
    local cat = d <= 0 and "0" or (d >= (p.MaxDamageBonus or 0) - 1e-6 and "max" or "up")
    if cat ~= ABUF.zmCat then
        ABUF.zmCat, ABUF.zmLogs = cat, ABUF.zmLogs + 1
        if ABUF.zmLogs <= 60 then
            out("§349 我的斩马刀损血增伤：%s（发 zmb=%.2f:%.2f）", cat == "0" and "结束 / 没在损血" or (cat == "max" and "到上限" or "开始计时"), d, a)
        end
    end
    return string.format("zmb=%.2f:%.2f\n", d, a)
end

-- 收：对方的 zmb=（新版才有）→ 伤害加成, 杀气加成；没有 = 0, 0。超过 ZM_SANE 的按 ZM_SANE（游戏上限 0.25）
function ABUF.rzm()
    local s = NET.rzmb
    if type(s) ~= "string" then return 0, 0 end
    local d, a = s:match("^([%d%.]+):([%d%.]+)")
    d, a = tonumber(d) or 0, tonumber(a) or 0
    return math.max(0, math.min(d, ABUF.ZM_SANE)), math.max(0, math.min(a, ABUF.ZM_SANE))
end

-- §223 观战替身也用这一套：pas / st 同 LO.syncWge
function LO.syncPas(pup, pas, st)
    if st == nil then pas, st = NET.rpas, LO end
    if pas == nil then return end
    local std = STD.active()
    local accMode = ACC.mode()
    local key = pathOf(pup) .. "|" .. pas .. (std and "|std" or "") .. "|acc" .. accMode .. "|ban" .. ACC.banNow()   -- §176
    if key == st.pasKey then
        if st.pasReportAt and ST.ticks >= st.pasReportAt then
            st.pasReportAt = nil
            local now = {}
            for n in pairs(activeAbilities(pup) or {}) do if LO.isPas(n) then now[#now + 1] = n end end
            table.sort(now)
            out("  被动同步 2 秒后替身生效的被动：%s；Amplification_Fire=%s", #now > 0 and table.concat(now, " ") or "（无）",
                tostring(attrOf(pup, "Amplification_Fire")))
        end
        return
    end
    st.pasKey, st.pasReportAt = key, ST.ticks + 60
    local want = {}
    for n in pas:gmatch("[%w_]+") do                          -- §170.1 饰品按房间设置换级 / 失效
        local t = ACC.pasName(n, accMode)
        if t then want[t] = true end
    end
    if std then
        for _, n in ipairs(STD.TALENT_GA) do want[n] = true end      -- §144 天赋按基准
        for n, info in pairs(STD.BLOCK_TAL) do if STD.blockOn(n) then want[info.ga] = nil end end     -- §232 屏蔽的天赋替身也不给
    end
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


return LO
end
