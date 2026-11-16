-- base_acc.lua —— 从 main.lua 搬出来的 §170 / §170.1 饰品等级（房间设置 acc=）（docs/MAIN_SLIM.md）。原来在 main.lua 的 "-- ===… §170 / §170.1 饰品等级（房间设置 acc=）" 那段
return function(ctx)
local ST, NET, MATCH, G = ctx.ST, ctx.NET, ctx.MATCH, ctx.G
local full, pathOf, valid, rawProp, shortName = G.full, G.pathOf, G.valid, G.rawProp, G.shortName
local eachArr, getP1, puppet, ascOf = G.eachArr, G.getP1, G.puppet, G.ascOf
-- main.lua 主循环那段会把 out / attrOf 换成计时包装（PROF.wrap），这几个由 ctx 传"调用时再取"的包装，
-- 和搬出来之前一样走计时（docs/MAIN_SLIM.md 规矩 3）
local out, attrOf = ctx.out, ctx.attrOf

-- ============================================================ §170 / §170.1 饰品等级（房间设置 acc=）
-- 饰品效果的资源名带等级：GE_Accessory_<名>_LvN（加属性 / 触发后的增益）、GA_Accessory_* / BP_GA_Accessory_*_LvN_C（触发型被动）。
-- Lv1 = 没精炼，Lv2 / Lv3 = 精炼 1 / 2 次。房间设置 acc（用户 11-09"饰品 初始 / 强化满 / 失效 可作为房间属性设置么"）：
--   0 = 原样（各用各的；§170.5 起和标准数值无关）、1 = 未强化（一律 Lv1）、2 = 强化满（一律最高级）、3 = 失效（饰品效果、技能全摘）。
-- 自己：每回合倒计时 / 开打时换（ACC.apply），对局中每 2 秒再查（触发出来的增益），回自由活动时换回（ACC.restore）。
-- 替身：LO.syncPas 按同一规则换对方 pas= 里的饰品技能；加属性那部分随 att= 过来（对方按同一设置换过了）。
-- 只改运行时，不动存档里的精炼等级。效果等级表从 IoStore 扫（游戏包 Accessories/New，Combo_DamageBuff 在 Combo 子目录）
ACC = { DIR = "/PBZCombatAsset/Prototypes/GameplayEffects/Accessories/New/", COMBO = { Combo_DamageBuff = true }, GE_LV = {} }
for b, l in ("ActHit:12 ActHitShachi:12 AnimMovement:12 Attack:12 BigHit:12 Bleed:12 Bleed_EnemyAmp:12 Bleed_PlayerBuff:12 BreakAttack:12 BreakDrink:12 BreakDrink_MaxShachi:2 BreakRecover:12 BreakRegen:12 BreakShield:12 Chaos:123 Combo:123 Combo_DamageBuff:123 Control:12 Counter:12 Counter_Effect:2 Deflect:12 Double:12 Drink:12 DrinkCost:12 EasyExecution:12 Electrified:12 ElementRegen:123 Elemental:12 ElementalResistance:12 EvadePhantom:12 Execution:12 ExecutionSwitchCool:12 Execution_Effect:2 Frost:12 Health:12 HealthResistance:123 HeavyAttackCost:12 HeavyAttackDamage:12 HeavyAttackShachi:12 Ignite:12 Long:12 Loot:12 LowHealth:12 LowShachi:12 MagicWeapon:123 MagicWeapon_SummonBerserk:123 MartialWeapon:123 PerfectFrame:123 PhysicalResistance:12 Poison:12 PoisonRegen:12 PowerWeapon:123 RandomDrink:123 RandomDrink_FireBreathe:123 RandomDrink_FullRegen:12 RandomDrink_GhostFire:123 RandomDrink_MaxShachi:12 RandomDrink_PoisonFog:123 RandomDrink_Shockwave:23 Ranged:12 RangedWeapon:123 Regen:12 ResistBleed:12 ResistFire:12 ResistIce:12 ResistNonBreak:12 ResistPoison:12 ResistRanged:12 ResistThunder:12 Resistance:12 Rider:12 Shachi:12 ShachiAttack:12 ShachiCool:12 ShachiRegen:12 ShachiWeapon:123 SpiritShadow:123 Stance:123 Stealth:12 Summon:123 SummonDuration:12 SwitchEndure:12 SwitchEndure_Endure:12 Tang:12 TimerEndure:12 TimerEndure_Cooldown:12 UltimateBreak:12 UltimateCharge:123"):gmatch("([%w_]+):(%d+)") do ACC.GE_LV[b] = l end
function ACC.gePath(base, lv)
    local n = "GE_Accessory_" .. base .. "_Lv" .. lv
    return ACC.DIR .. (ACC.COMBO[base] and "Combo/" or "") .. n .. "." .. n .. "_C"
end
-- 这一局按哪种：0 原样 / 1 未强化 / 2 强化满 / 3 失效
function ACC.mode()
    local m = (MATCH.res and MATCH.res.acc) or NET.resOf("acc") or 0
    return m
end
-- 名字 n 在 mode 下该换成什么：nil = 不动、false = 摘掉、字符串 = 换成这个名字
-- n 可以是技能类名（…_LvN_C）或效果短名（GE_Accessory_…_LvN）；off = { AC_X = true } 这一局失效的饰品（§176，不管 mode 都摘）
function ACC.target(n, mode, off)
    if not n:find("_Accessory_", 1, true) then return nil end
    if off and off[ACC.idOf(n) or ""] then return false end
    if mode == 0 then return nil end
    if mode == 3 then return false end
    local tail = n:sub(-2) == "_C" and "_C" or ""
    local pre, lv = n:match("^(.-_Accessory_.+)_Lv(%d)" .. tail .. "$")
    lv = tonumber(lv)
    if not pre then return nil end                       -- 没等级的被动（如 BP_GA_Accessory_Ignite_Passive_C）：原样
    local have                                          -- 某一级存不存在
    if tail == "" then
        local l = ACC.GE_LV[pre:sub(14)] or ""
        have = function(k) return l:find(tostring(k), 1, true) ~= nil end
    else
        local idx = LO.index()
        have = function(k) return idx and idx.map and idx.map[pre .. "_Lv" .. k .. "_C"] ~= nil end
    end
    if mode == 1 then
        if lv <= 1 then return nil end
        return have(1) and (pre .. "_Lv1" .. tail) or false   -- 没有 Lv1 = 只有精炼后才有：摘掉
    end
    for k = 3, lv + 1, -1 do                             -- mode 2：升到存在的最高级
        if have(k) then return pre .. "_Lv" .. k .. tail end
    end
    return nil
end
-- 替身被动同步用：对方 pas= 里的一个名字 → 替身该给的名字（nil = 不给）。
-- §176 禁用名单两边一样，替身这边也摘（对方自己也摘了，pas= 一般已经没有；倒计时刚换那一下可能还带着）；
-- 超出生效数量的看对方的格子顺序，本机算不了，靠对方摘完后的 pas= / att=
function ACC.pasName(n, mode)
    local t = ACC.target(n, mode, ACC.banSet(ACC.banNow()))
    if t == nil then return n end
    return t or nil
end
-- ---- §176 生效饰品数量（accn）/ 禁用饰品（accban）
-- 66 件饰品的中文 / 英文名（catalog.json，房间设置勾选页用）
ACC.NAME = {}
for id, zh, en in ([[ActHit 影动猎杀仪 HUNTER'S_INSIGHT|AnimMovement 舞扇 DANCE_FAN|Attack 筋力绑带 BATTLE_WRAPS|BigHit 绝望护符 TALISMAN_OF_DESPAIR|Bleed 雪与血 SNOW_AND_BLOOD|BreakAttack 追杀令 TOKEN_OF_PURSUIT|BreakDrink 静心小葫芦 CALMING_GOURD|BreakRecover 沉香念珠 AGARWOOD_PRAYER_BEADS|BreakRegen 慈母护符 MOTHER'S_TALISMAN|BreakShield 破盾符 SHIELDBREAKER_TALISMAN|Chaos 混沌狂戒 CHAOS_RING|Combo 碧血云天 CRIMSON_RESOLVE|Control 细线球 FINE_THREAD|Counter 反击护腕 COUNTERSTRIKE_BRACERS|Deflect 神机指环 SHENJI'S_RING|Double 妙手连环 QUICK_HAND_PAIR|Drink 香薰药盒 MEDICINE_CASE|DrinkCost 深宅药罐 MANOR_MEDICINE_POT|Electrified 月雷华灯 THUNDERMOON_LANTERN|ElementRegen 灭法拂尘丝 ACOLYTE_WHISK|Elemental 羽扇残羽 FEATHER_FAN_PLUME|EvadePhantom 影魅面具 WRAITH_MASK|Execution 万杀巧锁 DEATHLOCK|ExecutionSwitchCool 刽子手头巾 EXECUTIONER'S_HEADSCARF|Frost 灭法冰棱 ACOLYTE_ICICLE|Health 珍玩妖织 JEWEL'S_KNOT|HealthResistance 古甲残片 ANCIENT_ARMOR_FRAGMENT|HeavyAttackCost 正气凌然 LINGRAN'S_PENDANT|HeavyAttackDamage 残破容器 BROKEN_VESSEL|HeavyAttackShachi 独孤绝印 SEAL_OF_DUGU|Ignite 瑞狮火球 AUSPICIOUS_LION_FIREBALL|Long 妙手千钧 QUICK_HAND_MIGHT|Loot 聚宝盆 TREASURE_BASIN|LowHealth 绝地求生令 DESPERATE_STAND|LowShachi 同心双鱼佩 TWIN_FISH_PENDANT|MagicWeapon 百相傩面 NUO_MASK|MartialWeapon 粗糙煌心 CRUDE_RADIANT_HEART|PerfectFrame 浑源经脉仪 REFLEX_DEVICE|Poison 猛毒袋 VENOM_POUCH|PoisonRegen 活木符 LIVINGWOOD_TALISMAN|PowerWeapon 力士神像 GUARDIAN_IDOL|RandomDrink 开光玉佩 BLESSED_JADE_PENDANT|Ranged 神射之眼 SHARPSHOOTER'S_EYE|RangedWeapon 无相神镜 FORMLESS_DIVINE_MIRROR|ResistBleed 凝血符 CONGEAL_TALISMAN|ResistFire 辟火符 FLAMEWARD|ResistIce 防冰符 FROSTWARD|ResistNonBreak 坚岩护腕 BOULDERGUARD|ResistPoison 食物防腐罐 PRESERVATION_JAR|ResistRanged 避箭护符 ARROWWARD|ResistThunder 避雷符 THUNDERWARD|Rider 斩骑符 CAVALRYBANE|Shachi 弦音护符 RESONANCE_TALISMAN|ShachiAttack 白山密令 BAISHAN_WRIT|ShachiCool 胭脂盒 ROUGE_BOX|ShachiRegen 杀气头巾 SHA-CHI_HEADSCARF|ShachiWeapon 暗源方块 REMNANT_SPARK_CUBE|SpiritShadow 暗源小笼 REMNANT_SPARK_CAGE|Stance 机簧护心镜 BRASS_CHEST_GUARD|Stealth 屏息绑带 SILENT_WRAP|SummonDuration 人偶木心 A_PUPPET'S_WOODEN_HEART|SwitchEndure 神奇刀鞘 MIRACULOUS_SCABBARD|Tang 妙手在握 QUICK_HAND_PENDANT|TimerEndure 百战魔躯 BATTLEFORGED|UltimateBreak 绝技护符 ULTIMATE_TALISMAN|UltimateCharge 无名大师的扳指 NAMELESS_THUMB_RING]]):gmatch("(%w+) (%S+) ([^|]+)") do
    ACC.NAME["AC_" .. id] = { zh, (en:gsub("_", " ")) }
end
-- 技能 / 效果名 → 饰品 ID：*_Accessory_<X>[_…]_… → AC_X（同 ACC.orphans 的认法；X 只取字母，Bleed_EnemyAmp → AC_Bleed）
function ACC.idOf(n)
    local x = n:match("_Accessory_(%a+)")
    return x and ("AC_" .. x) or nil
end
ACC.banCache = {}
function ACC.banSet(s)                   -- "BreakRegen,MagicWeapon" → { AC_BreakRegen = true, ... }
    s = s or "-"
    if ACC.banCache.s == s then return ACC.banCache.r end
    local r = {}
    for x in s:gmatch("[%w_]+") do r["AC_" .. x:gsub("^AC_", "")] = true end
    ACC.banCache = { s = s, r = r }
    return r
end
function ACC.banNow()                    -- 这一局的禁用名单：对局中 = 开局时定下的
    return (MATCH.res and MATCH.res.accban) or NET.accBanOf()
end
function ACC.limitNow()                  -- 这一局的生效饰品数量（6 = 不限）
    return (MATCH.res and MATCH.res.accn) or NET.resOf("accn") or 6
end
function ACC.banText(s, lang)            -- 面板 / 日志：名单 → "慈母护符、百相傩面"（lang 1 = 中文、2 = 英文）
    local names, set = {}, ACC.banSet(NET.accBanNorm(s))
    for _, id in ipairs(STD.ACCESSORIES) do
        if set[id] then names[#names + 1] = (ACC.NAME[id] or { id, id })[lang or 1] end
    end
    if #names == 0 then return lang == 2 and "NONE" or "无" end
    return table.concat(names, lang == 2 and ", " or "、")
end
-- 开局第一次 apply 时算：这一局要失效的饰品 = 装着的里面禁用的 + 按格子顺序数、不算禁用的，第 accn 件之后的。
-- 返回 { AC_X = true }, 日志文字（nil = 没什么要说的）。读不到装了哪些时禁用名单整个算上（摘不到的不碍事）
-- §176.3 eq = 已经读好的"装着的"（对局中重算时传进来，可能只问了禁用名单那几件）；不传 = 这里读全部
function ACC.offNow(eq)
    local ban, lim = ACC.banSet(ACC.banNow()), ACC.limitNow()
    if eq == nil then eq = G.accEquipped(STD.ACCESSORIES) end
    local off, banned, cut = {}, {}, {}
    if not eq then
        for id in pairs(ban) do off[id] = true end
        return off, "饰品：读不到装了哪些，禁用名单整个摘（" .. ACC.banText(ACC.banNow()) .. "）"
    end
    local order, way = eq, nil
    if lim < 6 and #eq > 0 then
        local slots, why, diag = G.accSlots(eq)
        ACC.slotGuess = slots == nil          -- §176.1 读不到 → 倒计时横幅写明"按图鉴顺序"，别让人以为是按格子
        if slots then order, way = slots, why else
            way = "!! 读不到格子顺序（" .. tostring(why) .. "），按图鉴顺序"
            if diag and not ACC.slotDiagLogged then        -- 每次进游戏只写一次，给下次修读法用
                ACC.slotDiagLogged = true
                out("饰品格子顺序探针：装着 %s；%s", table.concat(eq, ","), table.concat(diag, "；"))
            end
        end
    end
    local k = 0
    for _, id in ipairs(order) do
        local nm = (ACC.NAME[id] or { id })[1]
        if ban[id] then
            off[id] = true; banned[#banned + 1] = nm
        else
            k = k + 1
            if k > lim then off[id] = true; cut[#cut + 1] = nm end
        end
    end
    if #banned + #cut == 0 then return off, nil end
    return off, string.format("饰品：装着 %d 件，禁用的 %s；只生效前 %s 件，摘掉 %s%s", #eq,
        #banned > 0 and table.concat(banned, "、") or "-", lim < 6 and tostring(lim) or "不限",
        #cut > 0 and table.concat(cut, "、") or "-", way and ("（格子顺序：" .. way .. "）") or "")
end
-- 读 ASC 上全部技能格：返回 { {n=类短名, h=Handle, cls=类}, ... }，pick(n) 为真的才要
function ACC.specs(asc, pick)
    local specs = {}
    eachArr(rawProp(rawProp(asc, "ActivatableAbilities"), "Items"), function(_, spec)
        local ab = rawProp(spec, "Ability")
        local okC, cls = false, nil
        if valid(ab) then okC, cls = pcall(function() return ab:GetClass() end) end      -- 空对象不调 GetClass（v0.27.7）
        local n = okC and shortName(full(cls)) or nil
        if n and pick(n) then specs[#specs + 1] = { n = n, h = rawProp(rawProp(spec, "Handle"), "Handle"), cls = cls } end
    end)
    return specs
end
-- 倒计时 / 开打 / 对局中每 2 秒：按 ACC.mode() 换自己身上的饰品技能和效果。ACC.mine 记着换掉的东西，回自由活动时换回
function ACC.apply(p1)
    local mode = ACC.mode()
    if not valid(p1) then return end
    local asc = ascOf(p1)
    if not valid(asc) then return end
    local mine = ACC.mine
    local first = mine == nil
    if first then
        local ask = ACC.askIds(mode)                    -- §176.3 对局中每 2 秒问这几件装没装（原样 + 不限数量时只问禁用名单那几件）
        if mode == 0 and #ask == 0 then return end      -- 原样、一件不禁、不限数量：这一局什么都不会摘，不建 ACC.mine（去重照常）
        local eq = G.accEquipped(STD.ACCESSORIES)
        local off, desc = ACC.offNow(eq or false)       -- §176 禁用 / 超出生效数量的饰品（§176.3 交手中装备变了再重算）
        if desc then out("%s", desc) end
        mine = { ga = {}, gaGiven = {}, ge = {}, geAdded = {}, hc = {}, hcList = {}, mode = mode, off = off, ask = ask }; ACC.mine = mine
        ACC.eqMark(mine, eq)
    else
        ACC.recheck(p1, asc, mine)                      -- §176.3 交手中换了饰品：重算要摘的
    end
    local off = mine.off
    if mode == 0 and not next(off) and not ACC.hcOn(mode) then mine.lateNow = nil; return end   -- 只禁不换级、眼下没要摘的：不扫身上（§205 省开销）；§225.1 生效 0 件还要摘周目加成
    -- ① 技能（先换技能：它自己挂的效果跟着换，下面 ② 再看剩下的）
    local swapped = {}
    -- 11-09 修：先给目标级、给上了再清原来那格（以前先清后给，给不上时这一局身上就少了这件饰品的技能）；
    -- "只试一次"的记录在 pbz_game 的 LO 里，这边清不到 → 用 again 参数
    for _, s in ipairs(ACC.specs(asc, function(n) return not mine.gaGiven[n] and ACC.target(n, mode, off) ~= nil end)) do   -- 遍历完再清
        local t = ACC.target(s.n, mode, off)
        local tag = s.n .. "→"
        local cls1 = t and LO.give(p1, t, {}, true)
        if t and not cls1 then
            tag = tag .. "（给不了，原样保留）"
        elseif LO.clearAbility(asc, s.h) then
            mine.ga[#mine.ga + 1] = { n = s.n, cls = s.cls }
            if cls1 then
                pcall(function() asc:TryActivateAbilityByClass(cls1, true) end)
                mine.gaGiven[t] = true
                tag = tag .. t:match("_Lv%d_C$")
            else tag = tag .. "（摘掉）" end
        else tag = tag .. "（清不掉）" end
        swapped[#swapped + 1] = tag
    end
    -- ② 效果：按份数换（§170.2 同一个效果可能生效两份，二周目饰品增伤实测 0.3 × 2；换成目标级也挂同样份数）
    local cnt = G.geCounts(p1)
    local geTags = {}
    for n, c in pairs(cnt or {}) do
        local t = nil
        if not ACC.isHc(n) then t = ACC.target(n, mode, off) end   -- §225 周目加成按路径摘不掉（失效模式以前在这里"摘"了个空），归 ACC.hcStrip
        if t ~= nil and not mine.geAdded[n] then          -- 我们自己挂的不再换
            local base, lv = n:match("^GE_Accessory_(.+)_Lv(%d)$")
            local path = base and ACC.gePath(base, lv) or (ACC.DIR .. n .. "." .. n .. "_C")
            local rec = (first or (mine.lateNow and mine.lateNow[ACC.idOf(n) or ""])) and not ACC.geHas(mine, n)
            if LO.removeGE(p1, path, "饰品（" .. ACC.MODE_NAME[mode] .. "）：摘掉 " .. n .. " ×" .. c) and rec then
                mine.ge[#mine.ge + 1] = { path = path, n = n, c = c }          -- 只还开局时就在的 + §176.3 交手中刚装上的那次（触发出来的临时增益不还）
            end
            local tag = n .. "×" .. c
            if t then
                local tb, tl = t:match("^GE_Accessory_(.+)_Lv(%d)$")
                local tp = ACC.gePath(tb, tl)
                for _ = 1, c - (cnt[t] or 0) do
                    if LO.applyGE(p1, tp, "饰品（" .. ACC.MODE_NAME[mode] .. "）：挂 " .. t) then mine.geAdded[t] = tp end
                end
                tag = tag .. "→Lv" .. tl
            else tag = tag .. "（摘掉）" end
            geTags[#geTags + 1] = tag
        end
    end
    if ACC.hcOn(mode) then ACC.hcStrip(p1, mine, first) end   -- §225 周目饰品加成
    if #swapped + #geTags > 0 then
        out("饰品（%s）：技能 %s；效果 %s", ACC.MODE_NAME[mode], #swapped > 0 and table.concat(swapped, " ") or "-",
            #geTags > 0 and table.concat(geTags, " ") or "-")
    elseif first then
        out("饰品（%s）：身上没有要换的", ACC.MODE_NAME[mode])
    end
    mine.lateNow = nil                                   -- §176.3 刚装上的只在发现后这一次记份数（之后再出现的是触发出来的临时增益）
end
-- ---- §225 周目饰品加成：GE_Accessory_HighCycle_<类别>_<N>。饰品多周目重复收集后图鉴显示 +N（如慈母护符 +2"受到的伤害减少 3%"），
-- 存档里没有 +N（饰品只有 CurrentLevel / AcquiredCycle），游戏按周目现算、挂成单独的效果。名字不带 _LvN，ACC.target 认不出，
-- 以前换级模式下也原样留着。11-10 内测：8 周目对 2 周目开"饰品未强化 + 标准数值"，8 周目满血承伤 0.753（饰品原样时 0.466），
-- 两边血上限一样、掉血不一样。现在换级模式（未强化 / 强化满 / 失效）一律摘，回自由活动按开局时读到的类 / 等级 / 份数挂回；原样不动。
-- 路径加载不到（§191），类从身上那份拿（G.geFind）
ACC.HC_PAT = "^GE_Accessory_HighCycle_"
-- §225.1 "只生效 0 件" = 一件饰品都不算，周目加成也摘（11-10 内测：生效 0 件的房间里 6 周目玩家承伤还是 0.092）。
-- 只生效 1–5 件 / 禁用名单不动它：周目加成按类别合成一条，分不出是哪件饰品给的
function ACC.hcOn(mode) return mode ~= 0 or ACC.limitNow() == 0 end
function ACC.modeText(mine) return (mine.mode == 0 and "只生效 0 件") or ACC.MODE_NAME[mine.mode] or "?" end
function ACC.isHc(n) return n:find(ACC.HC_PAT) ~= nil end
function ACC.trText(p1)
    local a, b = attrOf(p1, "TakenReductionMultiplier_Physical"), attrOf(p1, "TakenReductionMultiplier_Elemental")
    return string.format("物理 %s / 元素 %s", a and string.format("%.3f", a) or "?", b and string.format("%.3f", b) or "?")
end
-- rec = 这一局第一次（倒计时开局那次）：记下来结束时挂回；之后再出现的（游戏又挂上的）照摘、不记
function ACC.hcStrip(p1, mine, rec)
    local list = G.geFind and G.geFind(p1, ACC.isHc)
    if not list or #list == 0 then return end
    mine.hcN = (mine.hcN or 0) + 1
    local say = rec or mine.hcN <= 5
    local before = say and ACC.trText(p1)
    local modTxt = {}
    if say then
        for _, e in ipairs(G.geMods(p1, ACC.isHc) or {}) do
            for _, md in ipairs(e.mods) do modTxt[#modTxt + 1] = string.format("%s op%d %.3f", md.a, md.op or -1, md.v) end
        end
    end
    local tags = {}
    for _, e in ipairs(list) do
        local ok = e.cls and G.geRemoveCls(p1, e.cls)
        if ok and rec and not mine.hc[e.n] then mine.hc[e.n] = e; mine.hcList[#mine.hcList + 1] = e end
        tags[#tags + 1] = string.format("%s ×%d（等级 %s）%s", e.n, e.c, tostring(e.lv),
            ok and "" or (e.cls and "（!! 摘失败）" or "（!! 拿不到类）"))
    end
    if say then
        out("饰品（%s）：摘周目加成 %s；它们改的属性 %s；承伤 %s → %s%s", ACC.modeText(mine), table.concat(tags, "，"),
            #modTxt > 0 and table.concat(modTxt, "，") or "（没读到 Modifiers）", before, ACC.trText(p1),
            rec and "" or string.format("（对局中又出现，第 %d 次）", mine.hcN))
    end
end
-- 回自由活动：开局时摘的按份数挂回（身上已经有的不重复挂）
function ACC.hcRestore(p1, mine)
    if not (mine.hcList and #mine.hcList > 0) then return end
    local before = ACC.trText(p1)
    local now = {}
    for _, e in ipairs((G.geFind and G.geFind(p1, ACC.isHc)) or {}) do now[e.n] = e.c end
    local tags = {}
    local base = ACC.base and ACC.base.hc or {}
    for _, e in ipairs(mine.hcList) do
        local want = base[e.n] and math.min(e.c, base[e.n]) or e.c   -- §225.1 开局时可能已经被替身叠多了：按没替身时的份数还
        local need, ok = want - (now[e.n] or 0), 0
        for _ = 1, need do if G.geApplyCls(p1, e.cls, e.lv) then ok = ok + 1 end end
        tags[#tags + 1] = string.format("%s %d/%d%s", e.n, ok, math.max(need, 0), (need > 0 and ok < need) and "（!! 没挂全，重进游戏 / 换图后游戏会自己挂回）" or "")
    end
    local after = {}
    for _, e in ipairs((G.geFind and G.geFind(p1, ACC.isHc)) or {}) do after[#after + 1] = e.n .. " ×" .. e.c end
    out("饰品：挂回周目加成 %s；现在身上 %s；承伤 %s → %s", table.concat(tags, "，"),
        #after > 0 and table.concat(after, "，") or "-", before, ACC.trText(p1))
end
-- §225.1 周目加成也去重（11-10 内测 6 周目玩家日志：进世界 ×3，连人 / 观战时每生成一次替身游戏就再挂一遍 → ×6 / ×9 / ×12，
-- 承伤 0.304 → 0.092；§170.4 去重只认 _LvN，周目加成一直叠，换图 / 重进才回 ×3）。
-- 基准 b.hc = 这个角色没出过替身时身上的份数（跟着装卸饰品变）；出过替身之后基准只往小记（断开后替身没了、多的还在身上，不能当基准）。
-- 出过替身之后份数比基准多 → 整个摘掉、按基准份数挂回。对局里正摘着（hcStrip）时不管。连着 3 次去完又回来就不碰（同 §191）
-- 已知代价：连过人之后再新装一件同类饰品，多出来的那份会被当成叠加去掉，换图后恢复
function ACC.hcDedupe(p1, b, pawns, fixed)
    if ACC.mine and ACC.mine.hc and next(ACC.mine.hc) then return end
    local list = G.geFind and G.geFind(p1, ACC.isHc)
    if not list then return end
    b.hc, b.hcChurn = b.hc or {}, b.hcChurn or {}
    if pawns then b.hcSpawned = true end
    for _, e in ipairs(list) do
        local want = b.hc[e.n]
        if not b.hcSpawned or want == nil or e.c < want then
            b.hc[e.n] = e.c; b.hcChurn[e.n] = nil
        elseif e.c == want then
            b.hcChurn[e.n] = nil
        elseif (b.hcChurn[e.n] or 0) < 3 then
            b.hcChurn[e.n] = (b.hcChurn[e.n] or 0) + 1
            if b.hcChurn[e.n] == 3 then out("饰品去重：周目加成 %s 连着 3 次去完又回来，先不管它", e.n) end
            local ok = e.cls and G.geRemoveCls(p1, e.cls)
            local put = 0
            if ok then for _ = 1, want do if G.geApplyCls(p1, e.cls, e.lv) then put = put + 1 end end end
            fixed[#fixed + 1] = string.format("周目加成 %s %d→%d%s", e.n, e.c, ok and put or e.c,
                ok and (put < want and "（!! 没挂全）" or "") or (e.cls and "（!! 摘失败）" or "（!! 拿不到类）"))
        end
    end
end
-- ---- §176.3 交手中换饰品（2026-11-10 用户："堵住"）：开局没装、交手中换上的禁用饰品以前不在名单里，照样生效；
-- 卸掉前面一件后"只生效前 N 件"也不再对。现在每次 apply（倒计时 / 开打 / 对局中每 2 秒）先问一遍装着哪些，变了才重算。
-- 对局中要问的：换级（mode ≠ 0）或限数量时问全部 66 件（新装上的也要换级 / 截断、结束时要还）；只禁用时只问名单里那几件（默认 2 次 IsEquipAccessory / 2 秒）
function ACC.askIds(mode)
    if mode ~= 0 or ACC.limitNow() < 6 then return STD.ACCESSORIES end
    local ban, ids = ACC.banSet(ACC.banNow()), {}
    for _, id in ipairs(STD.ACCESSORIES) do if ban[id] then ids[#ids + 1] = id end end
    return ids
end
-- 记下读到的"装着的"（只记 ask 里那几件，和 recheck 读到的同一口径）；eq = nil（读不到）→ 不记，下次读到了当基准、不算"刚装上"
function ACC.eqMark(mine, eq)
    if not eq then mine.eq, mine.eqSig = nil, nil; return end
    if not mine.askSet then
        mine.askSet = {}
        for _, id in ipairs(mine.ask) do mine.askSet[id] = true end
    end
    local set, l = {}, {}
    for _, id in ipairs(eq) do if mine.askSet[id] then set[id] = true; l[#l + 1] = id end end
    mine.eq, mine.eqSig = set, table.concat(l, ",")
end
function ACC.nameList(ids)
    local l = {}
    for _, id in ipairs(ids) do l[#l + 1] = (ACC.NAME[id] or { id })[1] end
    return #l > 0 and table.concat(l, "、") or "-"
end
-- 名字属于 set 里的饰品（只认 66 件里的；HighCycle_Survival 这类不是饰品的名字不归任何一件）
function ACC.inSet(set, n)
    local id = ACC.idOf(n)
    return id ~= nil and ACC.NAME[id] ~= nil and set[id] == true
end
function ACC.geHas(mine, n)
    for _, e in ipairs(mine.ge) do if e.n == n then return true end end
    return false
end
-- 没变：只花 #ask 次 IsEquipAccessory、拼一个短字符串，不读格子顺序、不写日志
function ACC.recheck(p1, asc, mine)
    if #mine.ask == 0 then return end
    local eq = G.accEquipped(mine.ask)
    if not eq then return end
    if table.concat(eq, ",") == mine.eqSig then return end
    local was, now, plus, minus = mine.eq, {}, {}, {}
    for _, id in ipairs(eq) do now[id] = true; if was and not was[id] then plus[#plus + 1] = id end end
    if was then for _, id in ipairs(mine.ask) do if was[id] and not now[id] then minus[#minus + 1] = id end end end
    local off = ACC.offNow(eq)
    local gone, late, back, offL, newOff = {}, {}, {}, {}, {}
    for _, id in ipairs(minus) do gone[id] = true end
    for _, id in ipairs(plus) do late[id] = true end
    for _, id in ipairs(mine.ask) do
        if off[id] and now[id] then
            offL[#offL + 1] = id
            if was and not mine.off[id] then late[id] = true end      -- 本来生效、现在被挤出名额：这次摘的份数也要记（结束还）
            if not mine.off[id] then newOff[id] = true end
        end
        if mine.off[id] and now[id] and not off[id] then back[id] = true end      -- 以前被截掉、现在进了名额（还装着）
    end
    ACC.forget(p1, asc, mine, gone)
    ACC.dropGiven(p1, asc, mine, newOff)                -- 换级模式：被挤出名额的，我们给的换级版本也摘（apply 不碰自己给的）
    local backL = ACC.giveBack(p1, asc, mine, back)
    mine.off, mine.lateNow, mine.changed = off, late, true
    ACC.eqMark(mine, eq)
    out("饰品：%s，重算：摘掉 %s%s", was and string.format("交手中装备变了（多了 %s/少了 %s）", ACC.nameList(plus), ACC.nameList(minus)) or "读到装了哪些了",
        ACC.nameList(offL), #backL > 0 and ("；进了名额、还回 " .. ACC.nameList(backL)) or "")
end
-- 卸下的饰品：游戏自己撤它给的技能 / 效果；我们挂的（换级版本 gaGiven / geAdded、进名额时还回的）游戏不认、不会撤，
-- 所以身上还剩的这件饰品的技能 / 效果一律摘掉（它已经没装着了，留下的只会是我们挂的）；记着要还的那份不再还（不然凭空多一份）
function ACC.forget(p1, asc, mine, gone)
    if not next(gone) then return end
    local hit = function(n) return ACC.inSet(gone, n) end
    if valid(asc) then
        for _, s in ipairs(ACC.specs(asc, hit)) do LO.clearAbility(asc, s.h) end
    end
    for n in pairs(G.geCounts(p1) or {}) do
        local base, lv = n:match("^GE_Accessory_(.+)_Lv(%d)$")
        if base and hit(n) then LO.removeGE(p1, ACC.gePath(base, lv), "饰品：卸下了，摘掉剩在身上的 " .. n) end
    end
    for n in pairs(mine.gaGiven) do if hit(n) then mine.gaGiven[n] = nil end end
    for t in pairs(mine.geAdded) do if hit(t) then mine.geAdded[t] = nil end end
    local ga, ge = {}, {}
    for _, g in ipairs(mine.ga) do if not hit(g.n) then ga[#ga + 1] = g end end
    for _, e in ipairs(mine.ge) do if not hit(e.n) then ge[#ge + 1] = e end end
    mine.ga, mine.ge = ga, ge
end
-- 换级模式下我们给的目标级技能 / 效果（gaGiven / geAdded）：set 里这几件的撤掉（原来那份还记着，结束照还）
function ACC.dropGiven(p1, asc, mine, set)
    if not next(set) then return end
    local hit = function(n) return ACC.inSet(set, n) end
    local giv = false
    for n in pairs(mine.gaGiven) do if hit(n) then giv = true end end
    if giv and valid(asc) then
        for _, s in ipairs(ACC.specs(asc, function(n) return mine.gaGiven[n] and hit(n) end)) do LO.clearAbility(asc, s.h) end
    end
    for n in pairs(mine.gaGiven) do if hit(n) then mine.gaGiven[n] = nil end end
    for t, path in pairs(mine.geAdded) do
        if hit(t) then LO.removeGE(p1, path, "饰品：挤出名额，摘掉对局里挂的 " .. t); mine.geAdded[t] = nil end
    end
end
-- 进了名额的饰品：摘掉的技能现在就还（从 mine.ga 拿掉；换级模式下一次 apply 会再换、再记）；效果补到记下的份数（mine.ge 留着，结束时按份数补，补过的不会多）
function ACC.giveBack(p1, asc, mine, back)
    local l = {}
    if not next(back) then return l end
    for _, id in ipairs(mine.ask) do if back[id] then l[#l + 1] = id end end
    local hit = function(n) return ACC.inSet(back, n) end
    ACC.reapplied = true                                 -- 还回的不归装备管：之后卸下时靠 §191 ACC.orphans 摘
    local now = G.geCounts(p1) or {}                     -- §218 先补效果（效果自己会带回技能），再按缺的份数还技能
    for _, e in ipairs(mine.ge) do
        if hit(e.n) then
            for _ = 1, e.c - (now[e.n] or 0) do LO.applyGE(p1, e.path, "饰品：进了名额，还回 " .. e.n) end
        end
    end
    local ga = {}
    for _, g in ipairs(mine.ga) do if not hit(g.n) then ga[#ga + 1] = g end end
    if valid(asc) then ACC.giveShort(asc, mine.ga, function(g) return hit(g.n) end) end
    mine.ga = ga
    return l
end
-- §218 还技能只补缺的：list 里 pick 选中的每个名字记着几格就要几格，身上已有的（效果挂回时自己带回的）不再手给。
-- 手给的那份（K2_GiveAbility）实测不起作用（慈母护符破防不回血），效果带回的才是游戏自己的；返回 手给几个, 效果带回几个
function ACC.giveShort(asc, list, pick)
    local want, cls, order = {}, {}, {}
    for _, g in ipairs(list) do
        if pick(g) and valid(g.cls) then
            if not want[g.n] then order[#order + 1] = g.n end
            want[g.n], cls[g.n] = (want[g.n] or 0) + 1, g.cls
        end
    end
    if #order == 0 then return 0, 0 end
    local have = {}
    for _, s in ipairs(ACC.specs(asc, function(n) return want[n] ~= nil end)) do have[s.n] = (have[s.n] or 0) + 1 end
    local given, via = 0, 0
    for _, n in ipairs(order) do
        local h = math.min(have[n] or 0, want[n])
        via = via + h
        for _ = 1, want[n] - h do if LO.giveClass(asc, cls[n]) then given = given + 1 end end
    end
    return given, via
end
-- 结束时还在身上装着吗：记着要还的那几件问一遍，卸下了的不还（recheck 最多晚 2 秒，这里再兜一次）。读不到 = 都当装着（以前的行为）
function ACC.unequipped(mine)
    local ids, seen = {}, {}
    local function add(n)
        local id = ACC.idOf(n)
        if id and ACC.NAME[id] and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
    end
    for _, g in ipairs(mine.ga) do add(g.n) end
    for _, e in ipairs(mine.ge) do add(e.n) end
    local gone = {}
    if #ids == 0 then return gone end
    local eq = G.accEquipped(ids)
    if not eq then return gone end
    local on = {}
    for _, id in ipairs(eq) do on[id] = true end
    for _, id in ipairs(ids) do if not on[id] then gone[id] = true end end
    return gone
end
ACC.MODE_NAME = { [0] = "原样", [1] = "未强化", [2] = "强化满", [3] = "失效" }
-- 回自由活动：摘掉我们给的、把换掉的技能和开局时就在的效果换回去
function ACC.restore(p1)
    local mine = ACC.mine
    ACC.mine = nil
    if not (mine and valid(p1)) then return end
    local asc = ascOf(p1)
    if not valid(asc) then return end
    local cleared = 0
    if next(mine.gaGiven) then
        for _, s in ipairs(ACC.specs(asc, function(n) return mine.gaGiven[n] end)) do
            if LO.clearAbility(asc, s.h) then cleared = cleared + 1 end
        end
    end
    local nAdd = 0
    for _, path in pairs(mine.geAdded) do LO.removeGE(p1, path, "饰品：摘掉对局里挂的"); nAdd = nAdd + 1 end
    pcall(ACC.hcRestore, p1, mine)                       -- §225 周目饰品加成（出错不挡下面的换回）
    if cleared + nAdd + #mine.ga + #mine.ge == 0 and not mine.changed then return end   -- §176.3 这一局什么都没摘过（只建了 mine 用来盯换装）：不写日志
    local gone = ACC.unequipped(mine)                    -- §176.3 交手中卸下了的不还（游戏已经撤了它的，还了就凭空多一份）
    local skip = {}
    for id in pairs(gone) do skip[#skip + 1] = (ACC.NAME[id] or { id })[1] end
    table.sort(skip)
    -- §218 先补效果、再按缺的份数还技能（以前先还技能再挂效果：效果自己又给一份技能 → 两份，§170.4 去重清掉后加的那份
    -- = 效果给的那份，留下我们手给的那份不起作用。11-10 实测慈母护符换回后破防不回血，重新装上才好）
    local now, nBack, short = G.geCounts(p1) or {}, 0, {}
    for _, e in ipairs(mine.ge) do
        if not ACC.inSet(gone, e.n) then
            for _ = 1, e.c - (now[e.n] or 0) do
                if LO.applyGE(p1, e.path, "饰品：换回 " .. e.n) then nBack = nBack + 1 end
            end
        end
    end
    local back, viaGE = ACC.giveShort(asc, mine.ga, function(g) return not ACC.inSet(gone, g.n) end)
    if back + nBack > 0 then ACC.reapplied = true end   -- §176.3 还回的不归装备管：对局后卸下时靠 §191 ACC.orphans 摘
    local after = G.geCounts(p1) or {}
    for _, e in ipairs(mine.ge) do
        if not ACC.inSet(gone, e.n) and (after[e.n] or 0) ~= e.c then short[#short + 1] = e.n .. " " .. (after[e.n] or 0) .. "/" .. e.c end
    end
    out("饰品（%s）：换回——清掉对局技能 %d 个、摘对局效果 %d 个；还回效果 %d 份、技能 %d 个（效果自己带回 %d 个）%s%s", ACC.MODE_NAME[mine.mode] or "?", cleared, nAdd, nBack, back, viaGE,
        #skip > 0 and ("；已卸下不还：" .. table.concat(skip, "、")) or "",
        #short > 0 and ("；!! 份数对不上：" .. table.concat(short, " ")) or "；份数和开局前一样")
end
-- §170.3 诊断：每次进世界后 1 / 3 / 10 / 30 / 60 秒记一次身上的饰品效果份数和饰品技能格数（查"每个饰品效果挂了两份"从哪来）
ACC.DIAG_AT = { 0, 1, 3, 10, 30, 60 }
function ACC.diag(p1, tn)
    if ST.stableTicks == 1 then ACC.dg = { t0 = tn, i = 1, why = "进世界" } end
    local pup = ST.secondPawn                        -- 新替身出来了也重新记一轮（实测：份数是在 AI 对手出来时变成两份的）
    local pp = valid(pup) and pathOf(pup) or nil
    if pp and pp ~= ACC.dgPup then ACC.dgPup = pp; ACC.dg = { t0 = tn, i = 1, why = "替身 " .. shortName(pp) .. " 出来" } end
    local d = ACC.dg
    if not d or d.i > #ACC.DIAG_AT or tn - d.t0 < ACC.DIAG_AT[d.i] then return end
    local at = ACC.DIAG_AT[d.i]
    d.i = d.i + 1
    local ge, n = {}, 0
    for k, c in pairs(G.geCounts(p1) or {}) do if k:find("_Accessory_", 1, true) then ge[#ge + 1] = k:gsub("^GE_Accessory_", "") .. "×" .. c; n = n + c end end
    table.sort(ge)
    local ga, m = {}, 0
    local asc = ascOf(p1)
    if valid(asc) then
        for _, sp in ipairs(ACC.specs(asc, function(x) return x:find("_Accessory_", 1, true) ~= nil end)) do ga[sp.n] = (ga[sp.n] or 0) + 1; m = m + 1 end
    end
    local gl = {}
    for k, c in pairs(ga) do gl[#gl + 1] = k .. "×" .. c end
    table.sort(gl)
    out("饰品诊断（%s %d 秒，角色 %s）：效果 %d 份 %s；技能 %d 格 %s", d.why, at, shortName(pathOf(p1)), n, table.concat(ge, " "), m, table.concat(gl, " "))
end
-- §170.4 修"替身一出来，我身上的饰品效果 / 技能就多一份"（11-09 诊断：进世界 1–60 秒都是 ×1，替身 BP_Renewal_Hun 生成那一刻变 ×2——
-- 游戏按背包里装着的饰品给"玩家角色"再上一遍）。做法：没替身时每 5 秒记一次自己身上的饰品份数（基准）；有替身、且不在 ACC 换级中时，
-- 多出来的技能格清掉、多出来的效果摘掉再按基准份数挂回（摘一份的接口不确定，所以整个摘、按数补）
ACC.base, ACC.baseAt, ACC.dedupAt, ACC.dedupN = nil, -100, -100, 0
function ACC.snap(p1)
    local ge = {}
    for k, c in pairs(G.geCounts(p1) or {}) do if k:find("_Accessory_", 1, true) then ge[k] = c end end
    local ga = {}
    local asc = ascOf(p1)
    if valid(asc) then
        for _, sp in ipairs(ACC.specs(asc, function(x) return x:find("_Accessory_", 1, true) ~= nil end)) do ga[sp.n] = (ga[sp.n] or 0) + 1 end
    end
    return ge, ga
end
-- 11-09 修：观战一次生成两个替身（A / B，不是 ST.secondPawn），玩家身上的饰品叠到 ×3 还被当成基准记下。
-- 同一件饰品只能装一次，没替身时实测永远 ×1 → 基准一律按 1，不再记录；有没有替身都查（每 1 秒）
-- §205 进世界不联机也每秒顿一下 60–70 ms（11-10 双开日志：单帧尖峰只有"驱动合计"没分项，每次加载 8–25 次——尖峰日志
-- 每次加载只记前 SPIKE_LOGS 条，其实一直在）。就是这里：每秒把玩家身上全部效果（GetFullName 每条）和全部技能格（GetClass + 全名）
-- 扫一遍，都挤在同一帧。现在先只读两个数组的长度（G.arrCounts，不遍历），和上次全量扫完时一样就不扫；
-- 有替身 / 在观战时（饰品会被游戏多挂一份的场合）再每 SAFE_SEC 秒保底扫一次。数组长度变了（挂上 / 摘掉效果、装卸饰品、替身出来）照旧每秒内就扫
ACC.SAFE_SEC, ACC.fullAt, ACC.sig = 10, -100, nil
function ACC.dedupe(p1, tn)
    if not (ACC.base and ACC.base.pp == pathOf(p1)) then ACC.base, ACC.sig = { pp = pathOf(p1), ge = {}, ga = {} }, nil end
    local b = ACC.base
    if (ACC.mine and ACC.mine.mode ~= 0) or tn - ACC.dedupAt < 1 then return end   -- §176 只摘禁用 / 超出数量的（mode 0）时照常去重：两边不碰同一件
    -- 多人联机（没有 1v1 替身）：只在多人替身刚生成后的一阵子去重（pbz_multi MP.accSkip）。11-10 18:08 实测一直按"有替身"每秒全扫 35–58 ms/秒
    if BASEHOOK.mp and BASEHOOK.mp.accSkip and BASEHOOK.mp.accSkip(tn) and not valid(puppet()) then return end
    ACC.dedupAt = tn
    local sig = G.arrCounts and G.arrCounts(p1) or nil
    local pawns = valid(puppet()) or BASEHOOK.otherScene() or (BASEHOOK.mp and (BASEHOOK.mp.on or BASEHOOK.mp.netp.on))
    if sig and sig == ACC.sig and not (pawns and tn - ACC.fullAt >= ACC.SAFE_SEC) then return end     -- §205 身上没变
    ACC.fullAt = tn
    if ACC.reapplied then ACC.orphans(p1) end           -- §191 孤儿效果只会是我们挂回的那份：没挂回过就不查（省掉每秒找背包子系统 + IsEquipAccessory）
    local ge, ga = ACC.snap(p1)
    local asc = ascOf(p1)
    local fixed = {}
    for n, c in pairs(ga) do
        local want = b.ga[n] or 1                     -- 替身在时新装的饰品不在基准里：没替身时饰品从来都是一份（11-09 实测），按 1 算
        if c > want then
            local sps = ACC.specs(asc, function(x) return x == n end)
            local k = 0
            for i = #sps, 1, -1 do                       -- 清后加的那几格
                if c - k <= want then break end
                if LO.clearAbility(asc, sps[i].h) then k = k + 1 end
            end
            fixed[#fixed + 1] = n .. " 技能 " .. c .. "→" .. (c - k)
        end
    end
    -- §191 只管 GE_Accessory_<名>_LvN（装着的饰品的效果）。宇 11-09 日志：GE_Accessory_HighCycle_Survival_1 本来就两份、路径也不在
    -- New/ 下，以前每秒"摘、挂回找不到 GE"一遍（846 次）。另外连着 3 秒去完又回来的效果不再碰（游戏自己要挂两份），份数正常了就重新算
    ACC.churn = ACC.churn or {}
    for n, c in pairs(ge) do
        local want = b.ge[n] or 1
        local base, lv = n:match("^GE_Accessory_(.+)_Lv(%d)$")
        if c <= want then ACC.churn[n] = nil
        elseif base and (ACC.churn[n] or 0) < 3 then
            local path = ACC.gePath(base, lv)
            if LO.geClass(path) then
                ACC.churn[n] = (ACC.churn[n] or 0) + 1
                if ACC.churn[n] == 3 then out("饰品去重：%s 连着 3 秒去完又回来，先不管它", n) end
                LO.removeGE(p1, path, nil)
                for _ = 1, want do if LO.applyGE(p1, path, "饰品去重：挂回 " .. n) then ACC.reapplied = true end end
                fixed[#fixed + 1] = n .. " " .. c .. "→" .. want
            end
        end
    end
    ACC.hcDedupe(p1, b, pawns, fixed)                   -- §225.1 周目加成（不带 _LvN，上面那段不管）
    if #fixed > 0 then
        ACC.dedupN = ACC.dedupN + 1
        if ACC.dedupN <= 20 then out("饰品去重（替身出来后我身上多了一份，第 %d 次）：%s", ACC.dedupN, table.concat(fixed, "，")) end
    end
    ACC.sig = (#fixed > 0 or not sig) and (G.arrCounts and G.arrCounts(p1)) or sig     -- §205 按改完的样子记
end
-- 11-09 修：去重是"整个摘、按数挂回"，挂回的那份不归装备管——之后卸下这件饰品，游戏摘不掉它（用户：加血饰品卸了血条还是长）。
-- 所以每秒对一遍：身上有某件饰品的效果 / 技能，但 IsEquipAccessory 说没装 → 摘掉。名字对应 GE_Accessory_X_LvN / *Accessory_X_* ↔ AC_X
function ACC.orphans(p1)
    local ge, ga = ACC.snap(p1)
    local by = {}
    for n in pairs(ge) do local x = n:match("^GE_Accessory_(%a+)_Lv%d$"); if x then by["AC_" .. x] = true end end
    for n in pairs(ga) do local x = n:match("Accessory_(%a+)_"); if x then by["AC_" .. x] = true end end
    -- 只管认识的饰品（STD.ACCESSORIES 里有 AC_X）；同名变体 AC_X_1..4 装着任意一件都算装着，宁可漏摘不误摘
    ACC.known = ACC.known or {}
    if not next(ACC.known) then for _, id in ipairs(STD.ACCESSORIES or {}) do ACC.known[id] = true end end
    local ids = {}
    for id in pairs(by) do
        if ACC.known[id] then
            ids[#ids + 1] = id
            for k = 1, 4 do ids[#ids + 1] = id .. "_" .. k end
        else by[id] = nil end
    end
    if #ids == 0 then return end
    local on = G.accEquipped(ids)
    if not on then return end
    local eq = {}
    for _, id in ipairs(on) do eq[(id:gsub("_%d$", ""))] = true end
    for id in pairs(eq) do by[id] = nil end           -- by 里剩下的 = 认识、且确实没装
    local asc = ascOf(p1)
    local gone = {}
    for n in pairs(ge) do
        local x, lv = n:match("^GE_Accessory_(%a+)_Lv(%d)$")
        if x and by["AC_" .. x] then
            LO.removeGE(p1, ACC.gePath(x, lv), nil)
            gone[#gone + 1] = n
        end
    end
    if valid(asc) then
        for n in pairs(ga) do
            local x = n:match("Accessory_(%a+)_")
            if x and by["AC_" .. x] then
                for _, sp in ipairs(ACC.specs(asc, function(y) return y == n end)) do LO.clearAbility(asc, sp.h) end
                gone[#gone + 1] = n
            end
        end
    end
    if #gone > 0 then out("饰品：没装着的饰品效果还挂在身上，摘掉：%s", table.concat(gone, "，")) end
end
-- 对局中每 2 秒（跟着 STD.tick 的调用点）：触发出来的饰品增益也按设置换
ACC.at = -100
function ACC.tick(tn)
    if not ACC.mine or MATCH.state == "idle" or tn - ACC.at < 2.0 then return end
    ACC.at = tn
    ACC.apply(getP1())
end
-- 诊断：换套前后的 Actor / ActorComponent 数（和上一次比），看新建的武器对象会不会被回收（21:07 崩溃 = UObject 撑满）
function STD.countLog(tag)
    local a, c = G.objCounts()
    local p = STD.lastCount
    out("标准数值·对象计数（%s）：Actor %d（%+d）、ActorComponent %d（%+d）；本场第 %d 次换套", tag, a, a - (p and p[1] or a),
        c, c - (p and p[2] or c), #STD.forceTimes + 1)
    STD.lastCount = { a, c }
end
function STD.unforce(why)
    if not STD.forced then return end
    local id = STD.forced
    if STD.pushed or G.loadoutSnapshot() then         -- 先 Pop 配装快照，再 Restore 强制配装（20:32 实测这个顺序干净）
        local okP, errP = G.loadoutPop()
        if not okP then out("!! 标准数值：Pop 配装快照失败 %s", tostring(errP)) end
    end
    STD.pushed = false
    local ok, err = G.forcedRestore()
    out("标准数值：还原强制配装 %s（%s）：%s，之后等级 %s", id, why, ok and "成功" or ("失败 " .. tostring(err)), tostring(G.weaponLevel(id, true)))
    STD.forced, STD.forceTried, STD.lv, STD.verify = nil, nil, {}, nil
    os.remove(STD.FORCE_FILE)
    STD.countLog("还原后")
end
-- 进游戏（有玩家角色）后调一次：账本还在 = 上次对局没走到还原（崩溃 / 强退 / 存档里带着），游戏仍在强制配装中就还原。
-- 没有账本的强制配装是游戏自己的（剧情），不碰
function STD.cleanup()
    if STD.cleaned then return end
    STD.cleaned = true
    local f = io.open(STD.FORCE_FILE, "r")
    if not f then return end
    local id = (f:read("a") or ""):match("[%w_]+") or "?"
    f:close()
    if G.loadoutSnapshot() then G.loadoutPop() end     -- 方案 B 留下的配装快照
    local act = G.forcedActive()
    if act then
        local ok, err = G.forcedRestore()
        out("标准数值：发现上次留下的强制配装 %s，还原 %s（之后等级 %s）", id, ok and "成功" or ("失败 " .. tostring(err)), tostring(G.weaponLevel(id, true)))
    else
        out("标准数值：账本里有 %s，但游戏不在强制配装中（%s），只删账本", id, tostring(act))
    end
    os.remove(STD.FORCE_FILE)
end
-- 进倒计时 / 开打时调（跟 §113 NET.resApply 一起）
function STD.apply(p1, why)
    if not (STD.active() and valid(p1)) then return end
    if not STD.saved then
        STD.saved, STD.lv = {}, {}
        local okV, msg = G.saveVeto(true, STD.VETO_ID)
        STD.veto = okV
        out("标准数值：进否决存档 %s（%s）", okV and "成功" or "失败", tostring(msg))
        STD.added = STD.addTalents(p1, "自己")
        STD.blockSelf(p1)                    -- §232 屏蔽绝处逢生
        STD.gearOn(p1)
    end
    STD.force(p1)
    local parts = STD.writeAttrs(p1, true)
    if #parts > 0 then out("标准数值（%s）：%s", why, table.concat(parts, "，")) end
    local pup = puppet()
    if valid(pup) and not STD.pupAdded[pathOf(pup)] then
        STD.pupAdded[pathOf(pup)] = STD.addTalents(pup, "替身")
        STD.blockPup(pup)                    -- §232
    end
end
-- 对局中每 2 秒查一次（游戏重新聚合属性会把值改回去，同 LO.apply 每 2 秒重写替身）
function STD.tick(tn)
    if not (STD.saved and MATCH.state ~= "idle") then return end
    if tn - STD.forceAt >= STD.FORCE_EVERY then        -- 对局中换了武器：还原上一把、套这一把（用户"能在玩家切换武器的时候换成切换生成么"）
        STD.forceAt = tn
        STD.lastTn = tn
        local p0 = getP1()
        if valid(p0) then STD.force(p0, tn); STD.gearSync(p0) end
    end
    if tn - STD.enforceAt < 2.0 then return end
    STD.enforceAt = tn
    local p1 = getP1()
    if not valid(p1) then return end
    local parts = STD.writeAttrs(p1, false)
    if #parts > 0 then out("标准数值：属性被改回去了，重写：%s", table.concat(parts, "，")) end
    STD.blockSelf(p1, true)                  -- §232 游戏又挂上绝处逢生就再摘
    STD.blockPup(puppet(), true)
    STD.gearCheck(p1)
end
-- 回自由活动时调：属性还原、摘掉挂上的天赋、退出否决存档
function STD.restore(p1)
    STD.unforce("对局结束")
    STD.gearOff(p1)
    STD.disabled, STD.forceTimes, STD.seen, STD.settleUntil, STD.verify = false, {}, nil, -100, nil
    local s, sb = STD.saved, STD.savedBase or {}
    STD.saved, STD.pre, STD.savedBase, STD.preBase = nil, nil, nil, nil
    if s and valid(p1) then
        -- 11-09 修：基础值写回对局前的基础值；当前值按"对局前基础值 + 现在身上的饰品加成"算——
        -- 对局中卸 / 换了饰品，不能再写回对局前的当前值（用户：结束战斗反而比摘掉饰品更长）
        -- 当前值 = 对局前的当前值，换掉对局前的饰品加成、换成现在的（对局中卸 / 换了饰品）；基础值摆回对局前的
        local okB, add, mul = pcall(STD.accBonus, p1)
        if not okB then add, mul = {}, {} end
        local a0, m0 = STD.preAdd or {}, STD.preMul or {}
        STD.savedBase = sb
        for _, a in ipairs(STD.ORDER) do
            local v0 = s[a]
            if v0 then
                local v = (v0 / (m0[a] or 1) - (a0[a] or 0) + (add[a] or 0)) * (mul[a] or 1)
                STD.put(p1, a, v)
            end
        end
        STD.savedBase, STD.preAdd, STD.preMul = nil, nil, nil
        s.Health_Max = attrOf(p1, "Health_Max")
        for _, path in ipairs(STD.added or {}) do LO.removeGE(p1, path, "标准数值：摘掉自己的临时天赋 " .. path:match("([%w_]+)_C$")) end
        STD.unblockTalents(p1, STD.blocked, "自己")      -- §232 屏蔽的天赋挂回去
        out("标准数值：属性还原成对局前（血上限 %s、攻击 %s），摘掉临时天赋 %d 个", tostring(s.Health_Max), tostring(s.Attack), #(STD.added or {}))
    end
    if STD.blocked and #STD.blocked > 0 then out("§232 标准数值屏蔽天赋：这场摘了 %d 次（其中对局中游戏又挂上再摘 %d 次）", STD.blockN.off, STD.blockN.re) end
    STD.added, STD.blocked, STD.blockN = nil, nil, { off = 0, re = 0 }
    local pup = puppet()
    for key, list in pairs(STD.pupBlocked) do
        if valid(pup) and pathOf(pup) == key then STD.unblockTalents(pup, list, "替身") end
    end
    STD.pupBlocked = {}
    for key, list in pairs(STD.pupAdded) do      -- 替身身上挂的也摘掉（下一场不是标准数值时替身别多带天赋）
        if valid(pup) and pathOf(pup) == key then
            for _, path in ipairs(list) do LO.removeGE(pup, path, "标准数值：摘掉替身的临时天赋 " .. path:match("([%w_]+)_C$")) end
        end
    end
    STD.pupAdded = {}
    if STD.veto then
        local okV, msg = G.saveVeto(false, STD.VETO_ID)
        out("标准数值：退出否决存档 %s（%s）", okV and "成功" or "失败", tostring(msg))
        STD.veto = false
    end
end

return ACC
end