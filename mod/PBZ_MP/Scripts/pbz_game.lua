-- PBZ_MP 游戏适配层（v0.23.0 从 main.lua 原样搬出来，HANDOVER §59）
-- 这里放"直接调游戏"的代码：找玩家 / 替身、属性集（血量 / 杀气 / 攻击侧属性）、ASC 技能与 GameplayEffect、阵营、
-- 动画蒙太奇、武器组件 / 影之武装、替身生成 / 藏起、地图名、对局锁血。网络、对局流程、UI、面板都留在 main.lua。
-- 思路参考 Phantom Pact（pbz.lua 当适配层、coop.lua 通过 api.game.xxx 调）；它没有 LICENSE，只借结构，没有抄代码。
--
-- 用法（main.lua）：local G = require("pbz_game")({ out = out, ST = ST, NET = NET, MATCH = MATCH, PLACE_DIST = PLACE_DIST })
--   返回表 G 里是下面的函数（原名不变）；G.LO 是武器 / GAS 的几个 LO.xxx（main.lua 再挂回自己的 LO 表）。
--   ST / NET / MATCH 是 main.lua 的状态表，同一张表传进来，读写的字段和搬家前完全一样：缓存（setCache、ascCache、tagFn、
--   brakeSaved、MATCH.healPath / bp …）、替身（createPuppet / removePuppet 设 secondPC / secondPawn / pupWeapon / npcStore）、
--   换装后作废技能缓存（ST.abMapKey、NET.sub）、对局锁血（MATCH.lock）。
-- 每个函数上面一行【适配】注释写它用到的游戏类 / 字段；函数体与 v0.20.0 main.lua 逐字相同（只改了所在文件）。
-- 技能路径表 pbz_abilities.lua 不动，只在 LO.index 里 require。

local UEHelpers = require("UEHelpers")

return function(ctx)
local out, ST, NET, MATCH, PLACE_DIST = ctx.out, ctx.ST, ctx.NET, ctx.MATCH, ctx.PLACE_DIST
local LO = {}               -- 武器组件 / GAS 那几个函数原来挂在 main.lua 的 LO 表上，函数体里仍写 LO.xxx
local montageMap = nil      -- 蒙太奇 名字→资产 缓存（montageByName 建）
local abilitiesOf           -- 前置声明：定义在下面"技能列表"段

-- ============================================================ UObject 小工具（UE4SS 对象：GetFullName / IsValid / 属性读取 / TArray 遍历）

-- §145 2026-11-07 16:28:53 崩溃（和 11-05 09:07:34 同一处 PBZ.exe+0x144c660）：对已销毁的对象调 GetFullName，UE4SS 去读
-- 它的类指针 → 访问违例，外面的 pcall 接不住（不是 Lua 错误）。调 GetFullName 前先问 IsValid（查 GUObjectArray，不读类指针）。
-- 只有 IsValid 明确返回 false 才算失效：结构体 / 属性 / RemoteUnrealParam 这类没有 IsValid 的包装照旧走 GetFullName
-- 【适配】UObject:IsValid() == false
local function dead(o)
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == false
end

-- 【适配】UObject:GetFullName()（失效对象返回 <invalid>）
local function full(o)
    if o == nil then return "<nil>" end
    if dead(o) then return "<invalid>" end
    local ok, r = pcall(function() return o:GetFullName() end)
    if ok and r ~= nil then return r end
    return "<invalid>"
end

-- 去掉类名前缀，只留对象路径
-- 【适配】full() 去掉类名前缀，只留对象路径（缓存键都用它）
local function pathOf(o)
    local f = full(o)
    return f:match("^%S+ (.+)$") or f
end

-- 【适配】UObject:IsValid()，pcall 包住
local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

-- 【适配】pcall 包一层，失败写日志返回 nil
local function try(desc, fn, ...)
    local ok, r = pcall(fn, ...)
    if not ok then
        out("  !! %s -> %s", desc, tostring(r))
        return nil
    end
    return r
end

-- 【适配】obj[key] 读 UPROPERTY（读不到返回 nil，不抛错）
local function rawProp(obj, key)
    if obj == nil then return nil end
    local ok, v = pcall(function() return obj[key] end)
    if ok then return v end
    return nil
end

-- 【适配】路径最后一段（类名 / 资产名）
local function shortName(n)
    if not n then return nil end
    return n:match("([^%.]+)$")
end

-- 【适配】PersistentLevel 之后的部分，日志用
local function short(o)
    local s = type(o) == "string" and o or pathOf(o)
    return s:match("PersistentLevel%.(.+)$") or s
end

-- 【适配】按 GetFullName 比较两个 UObject 是不是同一个
local function sameObj(a, b)
    if a == nil or b == nil or dead(a) or dead(b) then return false end     -- §145 失效对象不调 GetFullName
    local ok1, x = pcall(function() return a:GetFullName() end)
    local ok2, y = pcall(function() return b:GetFullName() end)
    return ok1 and ok2 and x ~= nil and x == y
end

-- 【适配】FName / FText:ToString()
local function fnameStr(n)
    if n == nil then return "nil" end
    local ok, s = pcall(function() return n:ToString() end)
    if ok and s ~= nil then return tostring(s) end
    return tostring(n)
end

-- 遍历 TArray（userdata 用 ForEach，Lua table 用 ipairs）
-- 【适配】TArray:ForEach（元素 :get()），Lua 表走 ipairs
local function eachArr(arr, fn)
    if arr == nil then return false end
    if type(arr) == "table" then
        for i, v in ipairs(arr) do fn(i, v) end
        return true
    end
    local ok = pcall(function()
        arr:ForEach(function(i, e)
            local v = e
            pcall(function() v = e:get() end)
            fn(i, v)
        end)
    end)
    return ok
end

-- ============================================================ 身份：谁是玩家1、谁是替身

-- 旧版用 UEHelpers.GetPlayerController()，它返回 FindAllOf 的第一个本地控制器；
-- CreatePlayer 之后有两个本地控制器，顺序不固定，"玩家1"会在两个角色之间跳。

-- 【适配】FindAllOf("PlayerController") 里 IsLocalPlayerController() 且有 Pawn、不是替身控制器的那个
local function getP1PC()
    if valid(ST.p1pc) and not sameObj(ST.p1pc, ST.secondPC) then return ST.p1pc end
    ST.p1pc = nil
    local pcs = FindAllOf("PlayerController")
    if not pcs then return nil end
    for _, pc in pairs(pcs) do
        if valid(pc) and not sameObj(pc, ST.secondPC) then
            local ok, isLocal = pcall(function() return pc:IsLocalPlayerController() end)
            if ok and isLocal and valid(rawProp(pc, "Pawn")) then
                ST.p1pc = pc
                return pc
            end
        end
    end
    return nil
end

-- 【适配】玩家1 控制器的 Pawn
local function getP1()
    local pc = getP1PC()
    if not pc then return nil end
    local p = rawProp(pc, "Pawn")
    if valid(p) then return p end
    return nil
end

-- 【适配】替身：ST.secondPC.Pawn / ST.secondPawn（v0.13.0 起是 SpawnActor + AIController）
local function puppet()
    if valid(ST.secondPC) then
        local p = rawProp(ST.secondPC, "Pawn")
        if valid(p) then ST.secondPawn = p end
    end
    if valid(ST.secondPawn) then return ST.secondPawn end
    return nil
end

-- 【适配】UEHelpers.GetGameplayStatics()（GameplayStatics 默认对象）
local function gstat()
    if not valid(ST.gs) then ST.gs = UEHelpers.GetGameplayStatics() end
    return ST.gs
end

-- 墙钟时间（秒）。os.clock 是 CPU 时间，多线程下会比真实时间快，不能用
-- §116 GetRealTimeSeconds 是"这张地图加载以来"的秒数，换地图从 0 重算（2026-11-06 16:36 实测：客机"前往主机所在地图"后，
-- 换图前定下的 3 秒提示按新地图的时钟算成还剩 670 秒，"Q317 加入了你的房间"在断开后还挂了十来分钟）。
-- 倒退超过 1 秒就把旧地图走过的时间并进 nowBase，返回值一直往前走；不换图时和原来完全一样
local nowBase, nowLast = 0, nil
-- 【适配】GameplayStatics:GetRealTimeSeconds(玩家1控制器) + 换图归零补偿，拿不到用 os.time
local function now()
    local pc = getP1PC()
    if pc then
        local ok, t = pcall(function() return gstat():GetRealTimeSeconds(pc) end)
        if ok and type(t) == "number" then
            if nowLast and t < nowLast - 1.0 then nowBase = nowBase + nowLast end
            nowLast = t
            return nowBase + t
        end
    end
    return os.time()
end

-- 【适配】角色的 AttributeSetBase 属性（PBZ 的 BasicAttributeSet），没有就 FindAllOf("BasicAttributeSet") 按 GetOuter 找
local function attrSetOf(actor)
    if not valid(actor) then return nil end
    local key = pathOf(actor)
    local c = ST.setCache[key]
    if c and valid(c.set) then return c.set, c.how end

    local set, how = rawProp(actor, "AttributeSetBase"), "prop"
    if not valid(set) then
        set, how = nil, "outer"
        local all = FindAllOf("BasicAttributeSet")
        if all then
            for _, s in pairs(all) do
                if valid(s) then
                    local okO, o = pcall(function() return s:GetOuter() end)
                    if okO and sameObj(o, actor) then set = s; break end
                end
            end
        end
    end
    if not valid(set) then return nil end

    -- 复核：属性集路径必须挂在这个角色下面，否则宁可读不到
    local sp = pathOf(set)
    if sp:sub(1, #key + 1) ~= key .. "." then
        out("!! 属性集不属于目标：%s  vs  %s", short(sp), short(key))
        return nil
    end
    ST.setCache[key] = { set = set, how = how }
    out("属性集锁定 [%s] -> %s (%s)", short(key), short(sp), how)
    return set, how
end

-- 【适配】属性集里的 FGameplayAttributeData：CurrentValue / BaseValue（Health、Shachi、Health_Max、Amplification_* …）
local function attrOf(actor, name)
    local set = attrSetOf(actor)
    if not set then return nil end
    local a = rawProp(set, name)
    if a == nil then return nil end
    return rawProp(a, "CurrentValue"), rawProp(a, "BaseValue")
end

-- 【适配】属性 Health
local function hpOf(actor) return attrOf(actor, "Health") end

-- 属性集里能读到的全部属性名（v0.27.1 找大招用的资源，HANDOVER §78.6）：先按反射列（属性集类和父类的 ForEachProperty，
-- 值带 CurrentValue 的才算），列不出来就试一串猜的名字。名单按第一次的结果缓存（玩家和替身是同一个属性集类）
local ATTR_GUESS = { "Health", "Health_Max", "Shachi", "Shachi_Max", "Infliction", "Infliction_Max", "Anger", "Anger_Max",
                     "Energy", "Energy_Max", "Rage", "Rage_Max", "Ultimate", "Ultimate_Max", "UltimateEnergy", "SpecialEnergy",
                     "Spirit", "Spirit_Max", "Soul", "Soul_Max", "Power", "Power_Max", "Focus", "Focus_Max", "Burst", "Burst_Max" }
-- 【适配】属性集 UClass:ForEachProperty / GetSuperStruct 反射列属性名；返回 { {name, cur, base}, ... }, 名单来源
local function attrAll(actor)
    local set = attrSetOf(actor)
    if not set then return nil end
    if not ST.attrNames then
        local names, seen = {}, {}
        local okC, cls = pcall(function() return set:GetClass() end)
        for _ = 1, 8 do
            if not (okC and valid(cls)) then break end
            pcall(function()
                cls:ForEachProperty(function(p)
                    local n = fnameStr(p:GetFName())
                    local a = rawProp(set, n)
                    if not seen[n] and type(a) == "userdata" and type(rawProp(a, "CurrentValue")) == "number" then
                        seen[n] = true
                        names[#names + 1] = n
                    end
                end)
            end)
            okC, cls = pcall(function() return cls:GetSuperStruct() end)
        end
        local how = "反射"
        if #names == 0 then
            how = "猜名字"
            for _, n in ipairs(ATTR_GUESS) do
                if type(rawProp(rawProp(set, n), "CurrentValue")) == "number" then names[#names + 1] = n end
            end
        end
        ST.attrNames, ST.attrHow = names, how
    end
    local list = {}
    for _, n in ipairs(ST.attrNames) do
        local c, b = attrOf(actor, n)
        list[#list + 1] = { name = n, cur = c, base = b }
    end
    return list, ST.attrHow
end

-- v0.9.0 实测：原先定义在替身段（文件靠后），网络代码校正替身血量时调用它变成调用全局 nil，每帧报错打断判定和发包
-- 【适配】同时写属性的 BaseValue 和 CurrentValue（绕过 GAS 通知，血条可能不刷新，v0.10.5）
local function setAttr(actor, name, v)
    local set = attrSetOf(actor)
    local a = set and rawProp(set, name)
    if a == nil then return false end
    local ok1 = pcall(function() a.BaseValue = v end)
    local ok2 = pcall(function() a.CurrentValue = v end)
    return ok1 and ok2
end

-- 【适配】角色的 AbilitySystemComponent 属性，没有就 FindAllOf("AbilitySystemComponent") 按 GetOwner 找
local function ascOf(actor)
    if not valid(actor) then return nil end
    local key = pathOf(actor)
    local c = ST.ascCache[key]
    if valid(c) then return c end
    local asc = rawProp(actor, "AbilitySystemComponent")
    if not valid(asc) then
        asc = nil
        local all = FindAllOf("AbilitySystemComponent")
        if all then
            for _, a in pairs(all) do
                if valid(a) then
                    local ok, o = pcall(function() return a:GetOwner() end)
                    if ok and sameObj(o, actor) then asc = a; break end
                end
            end
        end
    end
    if valid(asc) then ST.ascCache[key] = asc end
    return asc
end

-- 【适配】角色的 FactionComponent（没有就 FindAllOf 按 GetOwner 找）
local function factionComp(actor)
    if not valid(actor) then return nil end
    local fc = rawProp(actor, "FactionComponent")
    if valid(fc) then return fc end
    local all = FindAllOf("FactionComponent")
    if all then
        for _, c in pairs(all) do
            if valid(c) then
                local ok, o = pcall(function() return c:GetOwner() end)
                if ok and sameObj(o, actor) then return c end
            end
        end
    end
    return nil
end

-- 带阵营组件的角色（§93 找替身的召唤物）。known[路径] 有的只给 actor / fc / path；没有的再读类名、主人（Owner / Instigator）的路径
-- 【适配】FindAllOf("FactionComponent")、ActorComponent:GetOwner()、Actor:GetOwner() / GetInstigator()
local function factionActors(known)
    local list = {}
    for _, c in pairs(FindAllOf("FactionComponent") or {}) do
        local ok, a = pcall(function() return c:GetOwner() end)
        if ok and valid(a) then
            local e = { actor = a, fc = c, path = pathOf(a) }
            if not (known and known[e.path]) then
                e.cls = full(a):match("^(%S+)") or "?"
                local ok1, o = pcall(function() return a:GetOwner() end)
                e.owner = (ok1 and valid(o)) and pathOf(o) or nil
                local ok2, i = pcall(function() return a:GetInstigator() end)
                e.inst = (ok2 and valid(i)) and pathOf(i) or nil
            end
            list[#list + 1] = e
        end
    end
    return list
end

-- 【适配】FactionComponent:GetCurrnetFaction()（游戏里就拼错成 Currnet）→ GameplayTag
local function factionValue(actor)
    local fc = factionComp(actor)
    if not valid(fc) then return nil end
    local ok, v = pcall(function() return fc:GetCurrnetFaction() end)
    if ok then return v, fc end
    return nil, fc
end

-- 【适配】阵营标签的 TagName（Faction.Player / Faction.Enemy）
local function factionName(actor)
    local v = factionValue(actor)
    if v == nil then return "?" end
    local tn = rawProp(v, "TagName")
    if tn ~= nil then return fnameStr(tn) end
    return tostring(v)
end

-- 【适配】把 UE 返回的结构体表 / FName 变成可读字符串（日志用）
local function anyToStr(v)
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    for k, x in pairs(v) do
        local s = tostring(x)
        if type(x) == "userdata" and rawProp(x, "ToString") then s = fnameStr(x) end
        parts[#parts + 1] = tostring(k) .. "=" .. s
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

-- 【适配】Mesh:GetAnimInstance():GetCurrentActiveMontage() 的短名
local function montageOf(actor)
    local m = rawProp(actor, "Mesh")
    if not valid(m) then return "" end
    local ok, an = pcall(function() return m:GetAnimInstance() end)
    if not ok or not valid(an) then return "" end
    local ok2, mt = pcall(function() return an:GetCurrentActiveMontage() end)
    if ok2 and valid(mt) then return shortName(full(mt)) or "" end
    return ""
end

local montageScanAt = -100
-- rescan：表里没有时重扫一次（最多 2 秒一次）。§111 紫冥剑召唤动作是替身第一次放 DB 才加载的，建表时还不在内存里
-- 【适配】FindAllOf("AnimMontage") 建一次 名字→资产 表（缓存失效就重建）
local function montageByName(name, rescan)
    if rescan and montageMap ~= nil and name ~= "" and montageMap[name] == nil and now() - montageScanAt >= 2 then
        montageMap = nil
    end
    if montageMap == nil then
        montageScanAt = now()
        montageMap = {}
        local all = FindAllOf("AnimMontage")
        if all then
            for _, mt in pairs(all) do
                if valid(mt) then
                    local s = shortName(full(mt))
                    if s then montageMap[s] = mt end
                end
            end
        end
        local n = 0
        for _ in pairs(montageMap) do n = n + 1 end
        out("montage 表: %d 个", n)
    end
    local m = montageMap[name]
    if m ~= nil and not valid(m) then montageMap = nil; return montageByName(name) end
    return m
end

-- 【适配】montageByName 建好的 名字→资产 表（原来 main.lua 直接读 montageMap，搬家后换成这个）
local function montages() return montageMap end

-- 【适配】Character:PlayAnimMontage，失败退回 AnimInstance:Montage_Play，返回时长
local function playOn(actor, asset)
    local ok, r = pcall(function() return actor:PlayAnimMontage(asset, 1.0, FName("None")) end)
    if ok and type(r) == "number" and r > 0 then return r end
    local m = rawProp(actor, "Mesh")
    if valid(m) then
        local okA, an = pcall(function() return m:GetAnimInstance() end)
        if okA and valid(an) then
            local ok2, r2 = pcall(function() return an:Montage_Play(asset, 1.0, 0, 0.0, true) end)
            if ok2 and type(r2) == "number" and r2 > 0 then return r2 end
        end
    end
    return nil
end

-- 【适配】GameplayTagContainer.GameplayTags[i].TagName → 字符串数组
local function tagNames(container)
    local res = {}
    if container == nil then return res end
    local arr = rawProp(container, "GameplayTags")
    if arr == nil and type(container) == "table" then arr = container end
    eachArr(arr, function(_, t)
        local tn = rawProp(t, "TagName")
        res[#res + 1] = tn ~= nil and fnameStr(tn) or tostring(t)
    end)
    return res
end

local TAG_WAYS = {
    { "asc:GetOwnedGameplayTags", function(actor, asc) return asc:GetOwnedGameplayTags() end },
    { "asc:K2_GetOwnedGameplayTags", function(actor, asc) return asc:K2_GetOwnedGameplayTags() end },
    { "BlueprintGameplayTagLibrary:GetOwnedGameplayTags", function(actor, asc)
        local lib = StaticFindObject("/Script/GameplayTags.Default__BlueprintGameplayTagLibrary")
        return lib:GetOwnedGameplayTags(actor)
    end },
    { "AbilitySystemBlueprintLibrary:GetOwnedGameplayTags", function(actor, asc)
        local lib = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
        return lib:GetOwnedGameplayTags(actor)
    end },
}

-- 【适配】按 TAG_WAYS 依次试 ASC / 标签库的 GetOwnedGameplayTags（v0.6 实测都是 0 个，§14）
local function tagsOf(actor)
    if ST.tagFn == false then return nil end
    local asc = ascOf(actor)
    if not valid(asc) then return nil end
    if ST.tagFn then
        local ok, c = pcall(ST.tagFn[2], actor, asc)
        if ok then return tagNames(c) end
        return nil
    end
    for _, w in ipairs(TAG_WAYS) do
        local ok, c = pcall(w[2], actor, asc)
        if ok and c ~= nil then
            ST.tagFn = w
            out("取标签方式: %s（当前 %d 个）", w[1], #tagNames(c))
            return tagNames(c)
        end
        out("  取标签 %s 不可用: %s", w[1], tostring(c))
    end
    ST.tagFn = false
    out("!! 所有取标签方式都不可用，只能靠动画名判断受击/弹反")
    return nil
end

-- ============================================================ 观察用：哪些技能处于激活状态

-- v0.6 实测 GameplayTag 三种取法都拿不到（恒为 0 个），改看哪些技能处于激活状态：
-- 出招 / 架势 / 闪避 / 破防都是 GA，ActiveCount 从 0 变 1 就是发生了
-- 2026-11-05 [耗时]（HANDOVER §82.2）：每次遍历全部技能、逐格读 ActiveCount，联机时约 280 ms/秒（每次 ~9.5 ms）。
-- 传 want(技能名) 时：按位置缓存"哪几格是要看的技能"（技能数量变了、want 换了或超过 SPEC.TTL 秒就整遍重建），
-- 平时其他格只过一下 ForEach 回调、不取元素不读属性。激活的格仍现查类名，所以清单过期也不会报错名字，
-- 最坏是 TTL 秒内看不到新加到别的格上的技能
-- §82.5 第四局实测：每 2 秒整遍重建一次（逐格查类名）会造成单帧尖峰，改成 30 秒；数量变了照样马上重建。
-- 要看的格里查到的类名不再是要看的技能（位置挪了）也马上重建
-- §82.6 第五局实测：清单 ~147 格、要看 ~103 格，整遍重建一次 40–50 ms（逐格查类名），30 秒一次还是一次尖峰。
-- 下标直取时改成分批重建：每次调用只查 SPEC.CHUNK 格，旧清单照用到新清单查完再换（数量变了也一样）。
-- 缓存按 角色 + want 分开存（发包看招式、编码被动看天赋 / 饰品，各一份，不互相顶掉）
local SPEC = { cache = {}, TTL = 30.0, CHUNK = 12, logs = 0 }
-- 【适配】ASC.ActivatableAbilities.Items 里 ActiveCount > 0 的技能类短名（want 给了就只看 want 为真的）
local function activeAbilities(actor, want)
    local asc = ascOf(actor)
    local items = asc and rawProp(rawProp(asc, "ActivatableAbilities"), "Items")
    if not items then return nil end
    local act, moved = {}, false
    local function check(spec)
        local n = rawProp(spec, "ActiveCount")
        if type(n) == "number" and n > 0 then
            local ab = rawProp(spec, "Ability")
            -- v0.27.7 先查有效：技能正在加 / 删的格 Ability 可能是空对象，空对象调 GetClass 读 [0x10] 直接崩（pcall 拦不住），
            -- 15:32 / 16:27 两次 UE4SS.dll+0x2be3e7 rd=0x10 都是替身第二次放 GA_Hun_DualHook_DB_C 时
            local okC, cls = false, nil
            if valid(ab) then okC, cls = pcall(function() return ab:GetClass() end) end
            local name = okC and shortName(full(cls)) or "?"
            if want and okC and not want(name) then moved = true      -- §82.5 看的格里冒出不该看的 → 位置挪了，不报
            else act[name] = true end
        end
    end
    if not want then
        eachArr(items, function(_, spec) check(spec) end)
        return act
    end
    local key, t = pathOf(actor) .. "|" .. tostring(want), os.clock()
    local c = SPEC.cache[key]
    if not c or (not c.direct and t - c.at > SPEC.TTL) then
        local t0 = os.clock()
        c = { at = t, want = want, n = 0, watch = {}, names = {} }
        eachArr(items, function(i, spec)
            if i > c.n then c.n = i end
            local ab = rawProp(spec, "Ability")
            local okC, cls = false, nil
            if valid(ab) then okC, cls = pcall(function() return ab:GetClass() end) end      -- v0.27.7 空对象不调 GetClass
            local name = okC and shortName(full(cls)) or "?"
            if okC and want(name) then
                c.watch[i], c.names[i] = true, name
                check(spec)
            end
        end)
        -- §82.4 能按下标直接取（TArray 的 items[i] + GetArrayNum）就不用 ForEach 过每一格：
        -- 拿第一个要看的格对一下名字、对一下数量，对得上才用
        local i1 = next(c.watch)
        if i1 then
            local okE1, e1 = pcall(function() return items[i1] end)          -- 下标取也要在 pcall 里（数量变少会越界）
            local ab1 = okE1 and rawProp(e1, "Ability") or nil
            local okI, nm = false, nil
            if valid(ab1) then okI, nm = pcall(function() return shortName(full(ab1:GetClass())) end) end   -- v0.27.7
            local okN, num = pcall(function() return items:GetArrayNum() end)
            c.direct = okI and nm == c.names[i1] and okN and num == c.n
        end
        SPEC.cache[key] = c
        if SPEC.logs < 20 then         -- §82.5 诊断：清单多大、看几格、下标直取有没有用上、重建花多久
            SPEC.logs = SPEC.logs + 1
            local m = 0
            for _ in pairs(c.watch) do m = m + 1 end
            out("技能清单重建：共 %d 格，要看 %d 格，下标直取 %s，用时 %.1f ms", c.n, m, tostring(c.direct), (os.clock() - t0) * 1000)
        end
        return act
    end
    if c.direct then
        local okN, num = pcall(function() return items:GetArrayNum() end)
        if not okN then SPEC.cache[key] = nil; return act end
        -- §82.6 分批重建：数量变了 / 到期 / 位置挪了 → 开始一轮，每次查 CHUNK 格
        if not c.re and (num ~= c.n or t - c.at > SPEC.TTL or c.stale) then
            c.re, c.stale = { i = 1, n = num, watch = {}, names = {}, ms = 0, calls = 0 }, false
        end
        local re = c.re
        if re then
            local t0 = os.clock()
            local last = math.min(re.n, re.i + SPEC.CHUNK - 1)
            for i = re.i, last do
                local okE, e = pcall(function() return items[i] end)          -- 下标取也要在 pcall 里（重建中数量变少会越界）
                local abI = okE and rawProp(e, "Ability") or nil
                local okC, name = false, nil
                if valid(abI) then okC, name = pcall(function() return shortName(full(abI:GetClass())) end) end   -- v0.27.7
                if okC and name and want(name) then re.watch[i], re.names[i] = true, name end
            end
            re.i, re.calls, re.ms = last + 1, re.calls + 1, re.ms + (os.clock() - t0) * 1000
            if re.i > re.n then
                c.re = nil
                if num == re.n then
                    c.watch, c.names, c.n, c.at = re.watch, re.names, re.n, t
                    if SPEC.logs < 20 then
                        SPEC.logs = SPEC.logs + 1
                        local m = 0
                        for _ in pairs(c.watch) do m = m + 1 end
                        out("技能清单分批重建：共 %d 格，要看 %d 格，%d 次查完，合计 %.1f ms", c.n, m, re.calls, re.ms)
                    end
                end                                  -- 查的过程中数量又变了：下次重来
            end
        end
        for i in pairs(c.watch) do
            if i <= num then
                local okE, e = pcall(function() return items[i] end)
                if okE and e ~= nil then check(e) end
            end
        end
        if moved and not c.re then c.stale = true end
        return act
    end
    local seen = 0
    if type(items) == "table" then
        for i, spec in ipairs(items) do
            seen = i
            if c.watch[i] then check(spec) end
        end
    elseif not pcall(function()
        items:ForEach(function(i, e)
            if i > seen then seen = i end
            if c.watch[i] then
                local v = e
                pcall(function() v = e:get() end)
                check(v)
            end
        end)
    end) then
        seen = -1
    end
    if seen ~= c.n or moved then SPEC.cache[key] = nil end      -- 数量变了（或遍历失败、位置挪了）：下次重建
    return act
end

-- 2026-11-05 10:52:31 回放：替身的架势放不出，动作已经是空的，可上一招 GA_Hun_DualHook_DB_C 的技能还挂着。对方已经出了新招 =
-- 他那边上一招结束了，替身跟着结束：对还挂着的招式技能（GA_Hun_*，不含被动 / 破防挣脱 / 召唤）的实例调 K2_CancelAbility。
-- 只调对象方法、不传结构体（UE4SS 传 GAS 结构体崩过，§19.20）。没有实例的（非实例化技能）取消不了，跳过
-- 【适配】ASC.ActivatableAbilities.Items 里 ActiveCount > 0 的招式技能：NonReplicatedInstances / ReplicatedInstances 的实例 K2_CancelAbility()
local function cancelMoves(actor)
    local asc = ascOf(actor)
    local items = asc and rawProp(rawProp(asc, "ActivatableAbilities"), "Items")
    if not items then return {} end
    local done = {}
    eachArr(items, function(_, spec)
        local n = rawProp(spec, "ActiveCount")
        if not (type(n) == "number" and n > 0) then return end
        local ab = rawProp(spec, "Ability")
        if not valid(ab) then return end      -- v0.27.7 空对象不调 GetClass
        local okC, cls = pcall(function() return ab:GetClass() end)
        local name = okC and shortName(full(cls)) or "?"
        if not name:match("^GA_Hun_") or name:find("Passive", 1, true) or name:find("BreakEscape", 1, true)
            or name:find("Summon", 1, true) then return end
        for _, key in ipairs({ "NonReplicatedInstances", "ReplicatedInstances" }) do
            eachArr(rawProp(spec, key), function(_, inst)
                if valid(inst) and pcall(function() inst:K2_CancelAbility() end) then done[#done + 1] = name end
            end)
        end
    end)
    return done
end

-- §105.3 房间设置"红蓝光反击：关"：只取消名字让 want(name) 返回 true 的、正在跑的技能实例。返回取消掉的名字表。
-- 写法同 cancelMoves：只调对象方法 K2_CancelAbility、不传结构体
-- 【适配】ASC.ActivatableAbilities.Items 里 ActiveCount > 0 且类名符合的技能：各实例 K2_CancelAbility()
local function cancelAbilities(actor, want)
    local asc = ascOf(actor)
    local items = asc and rawProp(rawProp(asc, "ActivatableAbilities"), "Items")
    if not items then return {} end
    local done = {}
    eachArr(items, function(_, spec)
        local n = rawProp(spec, "ActiveCount")
        if not (type(n) == "number" and n > 0) then return end
        local ab = rawProp(spec, "Ability")
        if not valid(ab) then return end
        local okC, cls = pcall(function() return ab:GetClass() end)
        local name = okC and shortName(full(cls)) or "?"
        if not want(name) then return end
        for _, key in ipairs({ "NonReplicatedInstances", "ReplicatedInstances" }) do
            eachArr(rawProp(spec, key), function(_, inst)
                if valid(inst) and pcall(function() inst:K2_CancelAbility() end) then done[#done + 1] = name end
            end)
        end
    end)
    return done
end

-- ============================================================ 替身摆位 / 朝向 / 刹车（CharacterMovement）

-- 【适配】两个位置之间的朝向角（度）
local function yawTo(a, b)
    return math.deg(math.atan(b.Y - a.Y, b.X - a.X))
end

-- §128 动画根运动的位移倍数（1 = 照动画走，0 = 动作照播、人不动）。返回 是否调用成功
-- 【适配】Character:SetAnimRootMotionTranslationScale(倍数)
local function rootMotionScale(actor, s)
    return pcall(function() actor:SetAnimRootMotionTranslationScale(s) end)
end

-- 【适配】Actor:K2_SetActorRotation，替身再 SetControlRotation
local function setYaw(actor, yaw)
    local rot = { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }
    pcall(function() actor:K2_SetActorRotation(rot, false) end)
    if valid(ST.secondPC) and sameObj(actor, ST.secondPawn) then
        pcall(function() ST.secondPC:SetControlRotation(rot) end)
    end
end

-- 【适配】K2_GetActorLocation 求朝向，让角色面向玩家1
local function facePlayer(actor)
    local p1 = getP1()
    if not (valid(actor) and valid(p1)) then return end
    local a = try("face loc", function() return actor:K2_GetActorLocation() end)
    local b = try("face p1", function() return p1:K2_GetActorLocation() end)
    if a and b then setYaw(actor, yawTo(a, b)) end
end

-- 【适配】玩家1 K2_GetActorLocation/Rotation 正前方 dist 处 K2_SetActorLocation，CharacterMovement.Velocity 清零
local function placeInFront(actor, dist)
    local p1 = getP1()
    if not (valid(actor) and valid(p1)) then return false end
    local loc = try("p1 loc", function() return p1:K2_GetActorLocation() end)
    local rot = try("p1 rot", function() return p1:K2_GetActorRotation() end)
    if not (loc and rot) then return false end
    local r = math.rad(rot.Yaw)
    local pos = { X = loc.X + math.cos(r) * dist, Y = loc.Y + math.sin(r) * dist, Z = loc.Z + 20.0 }
    pcall(function() actor:K2_SetActorLocation(pos, false, {}, true) end)
    setYaw(actor, rot.Yaw + 180.0)
    local cm = rawProp(actor, "CharacterMovement")
    if valid(cm) then pcall(function() cm.Velocity = { X = 0.0, Y = 0.0, Z = 0.0 } end) end
    return true
end

-- 没有输入时移动组件会自己刹车，把我们写的速度在两次 tick 之间吃掉；驱动期间关掉刹车
-- 【适配】CharacterMovement.BrakingDecelerationWalking / BrakingFrictionFactor 置 0 / 还原（§3.8）
local function setBraking(actor, off)
    local cm = rawProp(actor, "CharacterMovement")
    if not valid(cm) then return end
    if off and not ST.brakeSaved then
        ST.brakeSaved = {
            dec = rawProp(cm, "BrakingDecelerationWalking"),
            fac = rawProp(cm, "BrakingFrictionFactor"),
        }
        pcall(function() cm.BrakingDecelerationWalking = 0.0 end)
        pcall(function() cm.BrakingFrictionFactor = 0.0 end)
    elseif not off and ST.brakeSaved then
        local s = ST.brakeSaved
        if s.dec then pcall(function() cm.BrakingDecelerationWalking = s.dec end) end
        if s.fac then pcall(function() cm.BrakingFrictionFactor = s.fac end) end
        pcall(function() cm.Velocity = { X = 0.0, Y = 0.0, Z = 0.0 } end)
        ST.brakeSaved = nil
    end
end

-- ============================================================ 武器：Add Weapon And SwitchTo（会改全局装备列表，§29）

-- 【适配】BP_RenewalPlayer_C:"Add Weapon And SwitchTo"(WeaponID, true, true)（§17；§29：会改全局装备列表）
local function equipWeapon(actor, weaponId, why)
    if not valid(actor) or not weaponId then return false end
    if ST.pupWeapon == weaponId and sameObj(actor, ST.secondPawn) then return true end
    local fn = "Add Weapon And SwitchTo"
    -- v0.7.0 实测：UE4SS 报 "expected 3 parameters, received 4" —— Index 是蓝图的输出参数，只传前 3 个
    local ok, err = pcall(function() return actor[fn](actor, FName(weaponId), true, true) end)
    out("替身换武器 -> %s（%s）：%s", weaponId, why or "", ok and "调用成功" or ("失败 " .. tostring(err)))
    if ok then
        ST.pupWeapon = weaponId
        -- v0.16.0：换装会增删替身的技能，技能类缓存和"武器不匹配替代表"都作废；
        -- 15 帧（约 0.5 秒）后技能稳定了再记替身的被动签名，供防带偏比较
        ST.abMapKey, NET.sub = nil, {}
        ST.pupSig, ST.pupSigAt = nil, ST.ticks + 15
    end
    return ok
end

-- ============================================================ 武器组件 / 影之武装：Character Weapons Component（v0.17.0 §30 / v0.17.4 §34）

LO.WC_ROOT = "^/PBZCombatAsset/ActorData/Players/Hun/Weapon/"
-- v0.17.4：影之武装在 Weapon.Slot.Shachi 槽（PBZ.exe 里的标签：Main / Shachi / Item1 / Item2 / Interact），
-- 配置资产 /PBZCombatAsset/ActorData/Players/Hun/ShaqiWeapon/<名>/Weapon_<名>
LO.WCS_ROOT = "^/PBZCombatAsset/ActorData/Players/Hun/ShaqiWeapon/"

-- 【适配】GameplayTag Weapon.Slot.Main（PBZ.exe 里的武器槽标签）
function LO.slot()
    LO.slotTag = LO.slotTag or { TagName = FName("Weapon.Slot.Main") }
    return LO.slotTag
end

-- 【适配】GameplayTag Weapon.Slot.Shachi（影之武装槽，v0.17.4）
function LO.slotShachi()
    LO.slotTagS = LO.slotTagS or { TagName = FName("Weapon.Slot.Shachi") }
    return LO.slotTagS
end

-- 【适配】Character Weapons Component:GetCurrentWeapon(槽) 的 WeaponConfig 资产路径（v0.17.0，§30）
function LO.heldConfig(actor, slot)
    local cwc = rawProp(actor, "Character Weapons Component")
    if not valid(cwc) then return nil end
    local data = {}
    local ok = pcall(function() cwc:GetCurrentWeapon(slot or LO.slot(), data, false, {}) end)
    if ok and valid(data.WeaponConfig) then return pathOf(data.WeaponConfig) end
    return nil
end

-- 【适配】Character Weapons Component:IsArmed(主槽)
function LO.armed(actor)
    local cwc = rawProp(actor, "Character Weapons Component")
    local ok, r = pcall(function() return cwc:IsArmed(LO.slot()) end)
    return ok and r == true
end

-- 【适配】StaticFindObject / LoadAsset 武器配置资产，IsA(PBZ_WeaponConfigBase) 校验，路径白名单 WC_ROOT / WCS_ROOT
function LO.config(path)
    if not (path and #path <= 256 and path:match("^/[%w_/%-]+%.[%w_%-]+$")
            and (path:match(LO.WC_ROOT) or path:match(LO.WCS_ROOT))) then return nil end
    local cfg = StaticFindObject(path)
    if not valid(cfg) and type(LoadAsset) == "function" then
        pcall(LoadAsset, path)
        cfg = StaticFindObject(path)
    end
    if not valid(cfg) then return nil end
    local ok, yes = pcall(function() return cfg:IsA(StaticFindObject("/Script/PBZCombatAsset.PBZ_WeaponConfigBase")) end)
    return (ok and yes) and cfg or nil
end

-- §144 方案 A+：只换某个角色某一格的武器配置（和替身换装同一个调用，不碰背包 / 存档；11-08 实测切武器后保留）。返回 成功, 说明
-- 【适配】Character Weapons Component:SetSlotWeapon(槽, 序号, WeaponConfig)
function LO.setSlot(actor, slot, idx, path)
    local cwc = rawProp(actor, "Character Weapons Component")
    if not valid(cwc) then return false, "没有武器组件" end
    local cfg = LO.config(path)
    if not cfg then return false, "配置加载不了 " .. tostring(path) end
    local ok, err = pcall(function() cwc:SetSlotWeapon(slot, idx, cfg) end)
    return ok, ok and nil or tostring(err)
end

-- 【适配】Character Weapons Component:GetCurrentWeaponIndex(槽, false)；读不到 = nil
function LO.curIndex(actor, slot)
    local cwc = rawProp(actor, "Character Weapons Component")
    if not valid(cwc) then return nil end
    local ok, r = pcall(function() return cwc:GetCurrentWeaponIndex(slot or LO.slot(), false) end)
    return (ok and type(r) == "number") and r or nil
end

-- ============================================================ 外观（皮肤）：UPBZAppearanceComponent（§109）
-- PBZ.exe 字符串：System/Player/PBZAppearanceComponent.cpp，蓝图子类 BP_AppearanceComp；函数 GetEffectiveOutfit /
-- GetEffectiveSkinColor / IsEffectiveHatHidden / ApplyOutfitVisual / BP_ApplySkinColor / EquipOutfit / SetSkinColor …
-- 存档 __Advanced__ 槽 PBZAppearanceComponent.Hun.CurrentOutfit = "Hun_OutFit_FengXue"（DT_PBZAppearanceTable 的行名）。
-- 参数签名不知道（盲调崩过，§17 / §90）：先反射列参数，对得上才调用。EquipOutfit / SetSkinColor 会写存档和全局缓存
-- （Cached* 字段），不用；只用"只改样子"的 ApplyOutfitVisual / BP_ApplySkinColor
LO.APPC_CLASSES = { "BP_AppearanceComp_C", "PBZAppearanceComponent" }
LO.appc = {}
-- 按角色缓存，找不到 5 秒内不再 FindAllOf
-- 【适配】FindAllOf(BP_AppearanceComp_C / PBZAppearanceComponent) + GetOwner 挑出这个角色（或它控制器）的外观组件
function LO.appearanceComp(actor)
    if not valid(actor) then return nil end
    local key = pathOf(actor)
    local c = LO.appc[key]
    if c and c.comp and valid(c.comp) then return c.comp end
    if c and not c.comp and os.clock() - c.at < 5.0 then return nil end
    c = { at = os.clock() }
    local ctl = rawProp(actor, "Controller")
    for _, cn in ipairs(LO.APPC_CLASSES) do
        for _, x in pairs(FindAllOf(cn) or {}) do
            if not c.comp and valid(x) then
                local ok, o = pcall(function() return x:GetOwner() end)
                if ok and (sameObj(o, actor) or (valid(ctl) and sameObj(o, ctl))) then c.comp = x end
            end
        end
    end
    LO.appc[key] = c
    return c.comp
end

-- 外观组件的原生类路径（往父类找第一个 /Script/ 的），函数对象 = 它 .. ":" .. 函数名
-- 【适配】UObject:GetClass / UStruct:GetSuperStruct 往上找 "Class /Script/…" 的类
function LO.appcNative(comp)
    local ok, cls = pcall(function() return comp:GetClass() end)
    for _ = 1, 8 do
        if not (ok and valid(cls)) then return nil end
        local p = full(cls):match("^Class (/Script/.+)$")
        if p then return p end
        ok, cls = pcall(function() return cls:GetSuperStruct() end)
    end
    return nil
end

-- 函数签名：{ {参数名, 属性类型}, ... }（含 ReturnValue），没有这个函数 = nil。按"类:函数"缓存
LO.sigCache = {}
-- 【适配】StaticFindObject(<原生类>:<函数>) + UFunction:ForEachProperty（参数名 + FProperty 类型名），只反射不调用
function LO.funcSig(comp, fname)
    local native = LO.appcNative(comp)
    if not native then return nil end
    local key = native .. ":" .. fname
    local c = LO.sigCache[key]
    if c ~= nil then return c or nil end
    local f = StaticFindObject(key)
    if not valid(f) then LO.sigCache[key] = false; return nil end
    local sig = {}
    pcall(function()
        f:ForEachProperty(function(p)
            local t = "?"
            pcall(function() t = fnameStr(p:GetClass():GetFName()) end)
            sig[#sig + 1] = { fnameStr(p:GetFName()), t }
        end)
    end)
    LO.sigCache[key] = sig
    return sig
end

-- 【适配】签名的文字（日志用）
function LO.sigText(sig)
    if not sig then return "（没有这个函数）" end
    local a = {}
    for _, p in ipairs(sig) do a[#a + 1] = p[1] .. ":" .. p[2] end
    return "(" .. table.concat(a, ", ") .. ")"
end

-- 【适配】签名去掉返回值后的参数类型列表
function LO.sigInputs(sig)
    local r = {}
    for _, p in ipairs(sig or {}) do
        if p[1] ~= "ReturnValue" then r[#r + 1] = p[2] end
    end
    return r
end

-- 【适配】皮肤行名白名单：只接受 Hun_OutFit_* 这种（DT_PBZAppearanceTable 的行名）
function LO.outfitOk(id) return type(id) == "string" and #id <= 64 and id:match("^Hun_OutFit_[%w_]+$") ~= nil end

-- 【适配】FName / 字符串 → 名字；空 / None / 读不出来 = nil
local function nameOrNil(x)
    if x == nil then return nil end
    local s = fnameStr(x)
    if s == "" or s == "None" or s == "nil" or s:find("^table:") or s:find("^userdata") then return nil end
    return s
end

-- 读一个角色现在显示的皮肤：{ outfit = 行名, skin = 肤色(EPBZSkinColor 0~3), hat = 帽子藏没藏 }；没有外观组件 = nil
-- 签名是无参才调，不行退回读属性 CurrentOutfit / CurrentSkinColor
-- 【适配】外观组件 GetEffectiveOutfit() / GetEffectiveSkinColor() / IsEffectiveHatHidden()
function LO.outfitOf(actor)
    local comp = LO.appearanceComp(actor)
    if not valid(comp) then return nil end
    local function call0(fn)
        local sig = LO.funcSig(comp, fn)
        if not sig or #LO.sigInputs(sig) ~= 0 then return nil end
        local ok, r = pcall(function() return comp[fn](comp) end)
        if ok then return r end
        return nil
    end
    local r = {}
    local o = call0("GetEffectiveOutfit")
    r.outfit = nameOrNil(o) or (type(o) == "table" and nameOrNil(o.RowName)) or nameOrNil(rawProp(comp, "CurrentOutfit"))
    local s = call0("GetEffectiveSkinColor")
    if type(s) ~= "number" then s = rawProp(comp, "CurrentSkinColor") end
    r.skin = type(s) == "number" and math.floor(s) or nil
    local h = call0("IsEffectiveHatHidden")
    if type(h) == "boolean" then r.hat = h end
    return r
end

-- 只改样子地给角色换皮肤。2026-11-06 10:34 实测签名（替身的 BP_AppearanceComp）：
--   ApplyOutfitVisual(OutfitID:Name, bShowHat:Bool, SkinColor:Enum, bForceApplyMeshes:Bool)、BP_ApplySkinColor(SkinColor:Enum)
-- 按参数名填：Name = 行名；名字带 Hat 的 Bool = 显示斗笠（hat = 斗笠藏了，不知道就显示）；带 Force 的 Bool = true；
-- 带 Skin 的 Enum / Byte = 肤色（不知道给 0）；别的 Bool 给 false；还有别的类型 = 签名对不上，不调。
-- 没给皮肤（只有肤色）或 ApplyOutfitVisual 没带肤色参数时，肤色走 BP_ApplySkinColor。返回 成没成, 说明（带签名）
-- 【适配】外观组件 ApplyOutfitVisual(行名, 显示斗笠, 肤色, true) / BP_ApplySkinColor(肤色)，反射签名后才调
function LO.applyOutfit(actor, outfit, skin, hat)
    local comp = LO.appearanceComp(actor)
    if not valid(comp) then return false, "没有外观组件" end
    local skinOk = type(skin) == "number" and skin >= 0 and skin <= 3
    local msg, okAll, skinDone = {}, true, false
    if LO.outfitOk(outfit) then
        local sig = LO.funcSig(comp, "ApplyOutfitVisual")
        local args, fit, i = {}, sig ~= nil, 0
        for _, p in ipairs(sig or {}) do
            local n, t = p[1], p[2]
            if n ~= "ReturnValue" then
                i = i + 1
                if i == 1 then
                    if t == "NameProperty" then args[i] = FName(outfit) else fit = false end
                elseif t == "BoolProperty" then
                    if n:find("Hat", 1, true) then args[i] = hat ~= true
                    elseif n:find("Force", 1, true) then args[i] = true
                    else args[i] = false end
                elseif (t == "EnumProperty" or t == "ByteProperty") and n:find("Skin", 1, true) then
                    args[i] = skinOk and skin or 0
                    skinDone = skinOk
                else
                    fit = false
                end
            end
        end
        if fit and i >= 1 then
            local ok, err = pcall(function() comp:ApplyOutfitVisual(table.unpack(args, 1, i)) end)
            msg[#msg + 1] = "ApplyOutfitVisual" .. LO.sigText(sig) .. " " .. (ok and "调用成功" or ("失败 " .. tostring(err)))
            okAll = ok
            if not ok then skinDone = false end
        else
            msg[#msg + 1] = "ApplyOutfitVisual 签名对不上，没调 " .. LO.sigText(sig)
            okAll, skinDone = false, false
        end
    end
    if skinOk and not skinDone then
        local sig = LO.funcSig(comp, "BP_ApplySkinColor")
        local ins = LO.sigInputs(sig)
        if sig and #ins == 1 and (ins[1] == "EnumProperty" or ins[1] == "ByteProperty") then
            local ok, err = pcall(function() comp:BP_ApplySkinColor(skin) end)
            msg[#msg + 1] = "BP_ApplySkinColor" .. LO.sigText(sig) .. " " .. (ok and "调用成功" or ("失败 " .. tostring(err)))
        else
            msg[#msg + 1] = "BP_ApplySkinColor 签名对不上，没调 " .. LO.sigText(sig)
        end
    end
    return okAll, table.concat(msg, "；")
end

-- 外观组件上全部函数的签名（排查用，只反射不调用）
-- 【适配】UStruct:ForEachFunction + UFunction:ForEachProperty（只取名字和类型）
function LO.appcProbe(actor)
    local comp = LO.appearanceComp(actor)
    if not valid(comp) then return "没有外观组件" end
    local native = LO.appcNative(comp)
    local cls = native and StaticFindObject(native)
    local fns = {}
    if valid(cls) then
        pcall(function()
            cls:ForEachFunction(function(f)
                local n = fnameStr(f:GetFName())
                fns[#fns + 1] = n .. LO.sigText(LO.funcSig(comp, n))
            end)
        end)
    end
    return string.format("%s（原生类 %s）函数 %d 个：%s", short(pathOf(comp)), tostring(native), #fns, table.concat(fns, " "))
end

-- ============================================================ GAS：技能路径表 pbz_abilities.lua + 给技能 / GameplayEffect

-- 技能名 → 完整路径表（pbz_abilities.lua），第一次用时加载
-- 【适配】require("pbz_abilities")：技能类名 → 完整路径表（tools/gen_abilities.py 从 IoStore 生成，v0.17.0，§30）
function LO.index()
    if LO.abIndex == nil then
        local ok, t = pcall(require, "pbz_abilities")
        LO.abIndex = (ok and type(t) == "table") and t or false
        out("技能路径表 pbz_abilities：%s", LO.abIndex and "已加载" or ("加载失败 " .. tostring(t)))
    end
    return LO.abIndex
end

-- 替身没有某个技能：按 pbz_abilities.lua 的路径加载并 K2_GiveAbility（Phantom Pact game.playMove 的兜底）。每个"替身×技能"只试一次
-- 【适配】按 pbz_abilities 的路径 StaticFindObject / LoadAsset 技能类，ASC:K2_GiveAbility(cls, 1, -1)（v0.17.0，§30）
function LO.give(pup, name, map)
    local key = pathOf(pup) .. "|" .. name
    LO.gaveTried = LO.gaveTried or {}
    if LO.gaveTried[key] then return nil end
    LO.gaveTried[key] = true
    LO.index()
    local cls = map[name]
    if not valid(cls) and LO.abIndex then
        -- 表里是类的完整路径（v0.17.2）。同名有多份时优先对方武器的目录（例：绝影版 Double 招式在 DoubleBalde/Default/JueYing/）
        local paths = {}
        for _, path in ipairs(LO.abIndex.map[name] or {}) do
            if NET.rwc and NET.rwc:find("JueYing", 1, true) and path:find("JueYing", 1, true) then
                table.insert(paths, 1, path)
            else
                paths[#paths + 1] = path
            end
        end
        for _, path in ipairs(paths) do
            cls = StaticFindObject(path)
            if not valid(cls) and type(LoadAsset) == "function" then
                pcall(LoadAsset, (path:gsub("_C$", "")))
                cls = StaticFindObject(path)
            end
            if valid(cls) then break end
        end
    end
    if not valid(cls) then
        out("  给技能 %s：找不到类", name)
        return nil
    end
    local asc = ascOf(pup)
    local ok, err = pcall(function() asc:K2_GiveAbility(cls, 1, -1) end)
    out("  给替身技能 %s：%s", name, ok and "K2_GiveAbility 成功" or ("失败 " .. tostring(err)))
    if ok then map[name] = cls; return cls end
    return nil
end

-- 【适配】StaticFindObject / LoadAsset 一个 GameplayEffect 类
function LO.geClass(path)
    local cls = StaticFindObject(path)
    if not valid(cls) and type(LoadAsset) == "function" then
        pcall(LoadAsset, (path:gsub("_C$", "")))
        cls = StaticFindObject(path)
    end
    return valid(cls) and cls or nil
end

-- 【适配】ASC:BP_ApplyGameplayEffectToSelf(GE 类, 等级（默认 1）, ASC:MakeEffectContext())；返回成没成功
function LO.applyGE(actor, path, label, lv)
    local cls, asc = LO.geClass(path), ascOf(actor)
    if not (cls and valid(asc)) then out("  %s：%s", label, cls and "没有 ASC" or "找不到 GE"); return false end
    local ok, r = pcall(function() return asc:BP_ApplyGameplayEffectToSelf(cls, lv or 1, asc:MakeEffectContext()) end)
    out("  %s：BP_ApplyGameplayEffectToSelf %s", label, ok and "成功" or ("失败 " .. tostring(r)))
    return ok
end

-- 【适配】ASC:RemoveActiveGameplayEffectBySourceEffect(GE 类, nil, -1)。label 为 nil 时不记日志（§159 冲刺冷却每次都清）；返回调用成没成功
function LO.removeGE(actor, path, label)
    local cls, asc = LO.geClass(path), ascOf(actor)
    if not (cls and valid(asc)) then return false end
    local ok, r = pcall(function() asc:RemoveActiveGameplayEffectBySourceEffect(cls, nil, -1) end)
    if label then out("  %s：RemoveActiveGameplayEffectBySourceEffect %s", label, ok and "成功" or ("失败 " .. tostring(r))) end
    return ok
end

-- §118 身上生效的武器效果 GE：武器升级（白影 GE_Baiying_FrozenReinforced_Lv1–3 / LockFrozenWhileBlocked 加冰冻积累、
-- 混沌 GE_Weapon_ChaosBlade_Lv15 …）和形态 / 增益（混沌冰形态 GE_Chaos_FrostBuff、GE_BaiYing_Buff）。
-- 只要路径在 WGE_ROOT 下、而且不直接改属性的（Def.Modifiers 为空：改属性的已经随 att= 过去，再上一份会算两次）。
-- 返回 { "BaiYing/UpgradeData/GE_Baiying_FrozenReinforced_Lv1", … }（去重、排序）；读不到容器返回 nil
LO.WGE_ROOT, LO.wgeMods = "/PBZCombatAsset/ActorData/Players/Hun/Weapon/", {}

-- 【适配】ASC.ActiveGameplayEffects.GameplayEffects_Internal[i].Spec.Def（只读属性，不调函数）、GE 默认对象的 Modifiers
function LO.weaponEffects(actor)
    local asc = ascOf(actor)
    if not valid(asc) then return nil end
    local arr = rawProp(rawProp(asc, "ActiveGameplayEffects"), "GameplayEffects_Internal")
    if arr == nil then return nil end
    local seen, list = {}, {}
    local okE = eachArr(arr, function(_, age)
        local def = rawProp(rawProp(age, "Spec"), "Def")
        if not valid(def) then return end
        local p = pathOf(def)        -- /PBZCombatAsset/…/GE_X.Default__GE_X_C
        local id = p:sub(1, #LO.WGE_ROOT) == LO.WGE_ROOT and p:sub(#LO.WGE_ROOT + 1):match("^([%w_/]+)%.") or nil
        if not id or seen[id] then return end
        seen[id] = true
        if LO.wgeMods[id] == nil then
            local n = 0
            local okM = eachArr(rawProp(def, "Modifiers"), function() n = n + 1 end)
            LO.wgeMods[id] = okM and n or -1         -- 读不到 Modifiers = 不知道，不发
        end
        -- 只要升级和增益（名字带 Buff）；同目录下还有挨打方身上的效果（白影 GameplayEffects/GE_BaiYing_AssaultTriggered），不发。
        -- §159 升级 GE 多数在 UpgradeData/，双月 / 破军的在 WeaponUpgrade/（双月进阶冲刺要的 CanSwiftDash 就在这里，以前漏了）
        local isUpg = id:find("/UpgradeData/", 1, true) or id:find("/WeaponUpgrade/", 1, true)
            or (id:match("([^/]+)$") or ""):find("Buff", 1, true)
        if LO.wgeMods[id] == 0 and isUpg then list[#list + 1] = id end
    end)
    if not okE then return nil end
    table.sort(list)
    return list
end

-- 【适配】武器效果的短名（"BaiYing/UpgradeData/GE_X"）→ GE 类路径（"/PBZCombatAsset/…/GE_X.GE_X_C"）
function LO.wgePath(id)
    local name = id:match("([%w_]+)$")
    return LO.WGE_ROOT .. id .. "." .. name .. "_C"
end

-- §119 角色身上正在放的某个技能的实例（ActiveCount > 0 那一格的 NonReplicated / Replicated 实例）；没有返回 nil
-- 【适配】ASC.ActivatableAbilities.Items[i].{ActiveCount, Ability:GetClass(), NonReplicatedInstances, ReplicatedInstances}
function LO.activeInstance(actor, clsName)
    local asc = ascOf(actor)
    local items = asc and rawProp(rawProp(asc, "ActivatableAbilities"), "Items")
    if not items then return nil end
    local found
    eachArr(items, function(_, spec)
        if found then return end
        local n = rawProp(spec, "ActiveCount")
        if not (type(n) == "number" and n > 0) then return end
        local ab = rawProp(spec, "Ability")
        if not valid(ab) then return end
        local okC, cls = pcall(function() return ab:GetClass() end)
        if not (okC and shortName(full(cls)) == clsName) then return end
        for _, key in ipairs({ "NonReplicatedInstances", "ReplicatedInstances" }) do
            eachArr(rawProp(spec, key), function(_, inst) if not found and valid(inst) then found = inst end end)
        end
    end)
    return found
end

-- §119 对象的类（含父类）里名字匹配 pat 的函数和参数名（只反射不调用）。返回 { "TrySummonHuoQiang()", … }
-- 【适配】UObject:GetClass() / UStruct:ForEachFunction / GetSuperStruct + UFunction:ForEachProperty
function LO.funcsLike(obj, pat)
    local list = {}
    local okC, c = pcall(function() return obj:GetClass() end)
    c = okC and c or nil
    for _ = 1, 3 do
        if not valid(c) then break end
        pcall(function()
            c:ForEachFunction(function(f)
                local n = fnameStr(f:GetFName())
                if n:find(pat) then
                    local ps = {}
                    pcall(function() f:ForEachProperty(function(p) ps[#ps + 1] = fnameStr(p:GetFName()) end) end)
                    list[#list + 1] = n .. "(" .. table.concat(ps, ",") .. ")"
                end
            end)
        end)
        local okS, sup = pcall(function() return c:GetSuperStruct() end)
        c = okS and sup or nil
    end
    return list
end

-- §119 对象（类含父类）里名字含 pats 里任一段的属性和当前值（只读；数字 / 布尔 / 字符串照写，别的写类型）。返回 "名=值 …"
-- 【适配】UObject:GetClass() / UStruct:ForEachProperty / GetSuperStruct + obj[属性名]
function LO.propsLike(obj, pats)
    local list = {}
    local okC, c = pcall(function() return obj:GetClass() end)
    c = okC and c or nil
    for _ = 1, 3 do
        if not valid(c) then break end
        pcall(function()
            c:ForEachProperty(function(p)
                local n = fnameStr(p:GetFName())
                local hit = false
                for _, s in ipairs(pats) do if n:find(s, 1, true) then hit = true end end
                if hit and not n:find("CallFunc_", 1, true) and not n:find("K2Node_", 1, true) and not n:find("Temp_", 1, true) then
                    local v = rawProp(obj, n)
                    local t = type(v)
                    list[#list + 1] = n .. "=" .. ((t == "number" or t == "boolean" or t == "string") and tostring(v) or t)
                end
            end)
        end)
        local okS, sup = pcall(function() return c:GetSuperStruct() end)
        c = okS and sup or nil
    end
    return table.concat(list, " ")
end

-- §119 角色的瞄准组件（子弹的 BP_BulletTargetSelector_LockTarget 经 GetTargetingComponent 问它锁定了谁）
-- 【适配】角色属性 "Targeting Component"（BP_TargetingComponent_C）/ "PBZTargeting"
function LO.targetingComp(actor)
    if not valid(actor) then return nil end
    for _, k in ipairs({ "Targeting Component", "PBZTargeting", "TargetingComponent" }) do
        local c = rawProp(actor, k)
        if valid(c) then return c, k end
    end
    return nil
end

-- §119 诊断：挂在 actor 身上的特效——NiagaraComponent（主人是它）的特效资产名 + 激活没有，外加模型的 OverlayMaterial。
-- 只读；返回 { "NS_xxx(激活)", … }, 叠加材质名
-- 【适配】FindAllOf("NiagaraComponent") + GetOwner / Asset / IsActive；Mesh.OverlayMaterial
function LO.fxOn(actor)
    local list = {}
    for _, c in pairs(FindAllOf("NiagaraComponent") or {}) do
        local okO, o = pcall(function() return c:GetOwner() end)
        if okO and sameObj(o, actor) then
            local a = rawProp(c, "Asset")
            local okA, act = pcall(function() return c:IsActive() end)
            list[#list + 1] = (valid(a) and shortName(full(a)) or "?") .. ((okA and act) and "(激活)" or "")
        end
    end
    table.sort(list)
    local mesh = rawProp(actor, "Mesh")
    local ov = valid(mesh) and rawProp(mesh, "OverlayMaterial")
    return list, valid(ov) and shortName(full(ov)) or "-"
end

-- §119 在角色身上放一个 Niagara 特效（紫冥剑布局闪避的金光；真人那边是技能自己放的，替身的技能早收了）。
-- 先 SpawnSystemAttached 挂在角色模型上（跟着闪避走），不行退回 SpawnSystemAtLocation。返回 是否成功, 用的哪个 / 错误
-- 【适配】LoadAsset NiagaraSystem + Default__NiagaraFunctionLibrary:SpawnSystemAttached / SpawnSystemAtLocation
function LO.spawnFx(actor, path)
    local sys = LO.geClass(path)
    if not sys then return false, "找不到特效 " .. path end
    local lib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
    if not valid(lib) then return false, "找不到 NiagaraFunctionLibrary" end
    local mesh = rawProp(actor, "Mesh")
    local zero, one = { X = 0.0, Y = 0.0, Z = 0.0 }, { X = 1.0, Y = 1.0, Z = 1.0 }
    local rot0 = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
    if valid(mesh) then
        local ok, err = pcall(function()
            lib:SpawnSystemAttached(sys, mesh, FName("None"), zero, rot0, 0, true, true, 0, true)
        end)
        if ok then return true, "SpawnSystemAttached" end
        LO.fxErr = tostring(err)
    end
    local okL, loc = pcall(function() return actor:K2_GetActorLocation() end)
    if not (okL and loc) then return false, "读不到位置；挂上去失败 " .. tostring(LO.fxErr) end
    local okR, rot = pcall(function() return actor:K2_GetActorRotation() end)
    local ok2, err2 = pcall(function()
        lib:SpawnSystemAtLocation(actor, sys, loc, okR and rot or rot0, one, true, true, 0, true)
    end)
    if ok2 then return true, "SpawnSystemAtLocation（挂上去失败 " .. tostring(LO.fxErr):sub(-60) .. "）" end
    return false, "两种都失败：" .. tostring(LO.fxErr):sub(-60) .. " / " .. tostring(err2):sub(-60)
end

-- §119 让瞄准组件锁定 target：SetLockTarget(target)，再问 HasLockTarget()。返回 是否调用成功, 错误, HasLockTarget 的结果
-- 18:41 实测：传角色本身报"Expected a live, compatible … userdata"——参数不是 Actor
-- 【适配】TargetingComponent:SetLockTarget(对象) / HasLockTarget()
function LO.tcSetLock(tc, target)
    local ok, err = pcall(function() tc:SetLockTarget(target) end)
    local okH, has = pcall(function() return tc:HasLockTarget() end)
    return ok, err, okH and has or ("问不了 " .. tostring(has))
end

-- §119 一个 FProperty 的 名字、类型、对象类 / 结构体名、结构体（只反射）
-- 【适配】FProperty:GetFName / GetClass / GetPropertyClass / GetStruct
function LO.propInfo(p)
    local n, t, pc, st = "?", "?", nil, nil
    pcall(function() n = fnameStr(p:GetFName()) end)
    pcall(function() t = fnameStr(p:GetClass():GetFName()) end)
    pcall(function() pc = fnameStr(p:GetPropertyClass():GetFName()) end)
    if t == "StructProperty" then
        pcall(function() st = p:GetStruct(); pc = fnameStr(st:GetFName()) end)
    end
    return n, t, pc, st
end

-- §119 瞄准组件取消锁定
-- 【适配】TargetingComponent:StopLockTarget()
function LO.tcStop(tc)
    return pcall(function() tc:StopLockTarget() end)
end

-- §119 对象的类（含父类）里函数 fname 的参数：{ {n, t, cls, fields = { {n, t, cls}, … } (结构体才有)}, … }；没找到返回 nil
-- 【适配】UStruct:ForEachFunction / GetSuperStruct + UFunction:ForEachProperty + 结构体 UScriptStruct:ForEachProperty
function LO.paramList(obj, fname)
    local okC, c = pcall(function() return obj:GetClass() end)
    c = okC and c or nil
    local res = nil
    for _ = 1, 4 do
        if res or not valid(c) then break end
        pcall(function()
            c:ForEachFunction(function(f)
                if res or fnameStr(f:GetFName()) ~= fname then return end
                res = {}
                pcall(function()
                    f:ForEachProperty(function(p)
                        local n, t, pc, st = LO.propInfo(p)
                        local e = { n = n, t = t, cls = pc }
                        if st then
                            e.fields = {}
                            pcall(function()
                                st:ForEachProperty(function(q)
                                    local qn, qt, qc = LO.propInfo(q)
                                    e.fields[#e.fields + 1] = { n = qn, t = qt, cls = qc }
                                end)
                            end)
                        end
                        res[#res + 1] = e
                    end)
                end)
            end)
        end)
        local okS, sup = pcall(function() return c:GetSuperStruct() end)
        c = okS and sup or nil
    end
    return res
end

-- §119 paramList 的文字版（日志用）
-- 【适配】同 paramList（只反射）
function LO.paramTypes(obj, fname)
    local l = LO.paramList(obj, fname)
    if not l then return "（没找到）" end
    local ps = {}
    for _, e in ipairs(l) do
        local s = e.n .. ":" .. e.t .. (e.cls and ("<" .. e.cls .. ">") or "")
        if e.fields then
            local fs = {}
            for _, f in ipairs(e.fields) do fs[#fs + 1] = f.n .. ":" .. f.t .. (f.cls and ("<" .. f.cls .. ">") or "") end
            s = s .. "{" .. table.concat(fs, ", ") .. "}"
        end
        ps[#ps + 1] = s
    end
    return table.concat(ps, ", ")
end

-- §119 角色身上可能被别人锁定的目标对象（给 SetLockTarget 试）：LockViewTarget 等组件属性 + 名字带 Target 的组件
-- 【适配】角色属性 LockViewTarget / "Target Component" / TargetComponent + Actor:K2_GetComponentsByClass(ActorComponent)
function LO.lockCandidates(actor)
    local list, seen = {}, {}
    local function add(name, o)
        if valid(o) and not seen[pathOf(o)] then seen[pathOf(o)] = true; list[#list + 1] = { name = name, obj = o } end
    end
    for _, k in ipairs({ "LockViewTarget", "Target Component", "TargetComponent", "LockOnTarget", "TargetableComponent" }) do
        add(k, rawProp(actor, k))
    end
    local cls = StaticFindObject("/Script/Engine.ActorComponent")
    local ok, comps = pcall(function() return actor:K2_GetComponentsByClass(cls) end)
    if ok and comps then
        eachArr(comps, function(_, c)
            local n = shortName(full(c)) or ""
            local cn = (full(c):match("^(%S+)") or "")
            if (n .. cn):find("Target") or (n .. cn):find("Lock") then add(cn .. " " .. n, c) end
        end)
    end
    return list
end

-- §139.4 调对象上一个带参数的蓝图函数（R2 松手事件 OnRelease_<guid>(TimeHeld)）。返回 是否调用成功, 错误
-- 【适配】obj:<函数名>(参数…)
function LO.callArgs(obj, fname, ...)
    if not valid(obj) then return false, "对象无效" end
    local args = { ... }
    return pcall(function() obj[fname](obj, table.unpack(args)) end)
end

-- §119 调对象上一个不带参数的蓝图函数。返回 是否调用成功, 错误
-- 【适配】obj:<函数名>()
function LO.callNoArg(obj, fname)
    if not valid(obj) then return false, "对象无效" end
    return pcall(function() obj[fname](obj) end)
end

-- 替身自己的 UI 逻辑组件（按 Owner 找）
-- 【适配】FindAllOf("BP_UIGameplayLogicComponent_C") 按 GetOwner 找（v0.17.6 debuff 图标排查，§36）
function LO.uiCompOf(actor)
    for _, c in ipairs(FindAllOf("BP_UIGameplayLogicComponent_C") or {}) do
        local ok, owner = pcall(function() return c:GetOwner() end)
        if ok and sameObj(owner, actor) then return c end
    end
    return nil
end

-- §139.1 替身的激光柱：真人的激光 = 弓上射出的一道持续光柱（SpawnLoopLaserNS 生成、挂在弓上）+ 两只眼睛按节奏打。
-- 替身走"早松开了"那条路，只有眼睛、没有光柱。让它的激光技能自己调 SpawnLoopLaserNS，返回这次新生成的 Niagara 组件
-- 【适配】技能实例:SpawnLoopLaserNS() + 技能变量 "Niagara Comps"（数组）/ LaserNS
-- §139.4 照技能生成的那份光柱，自己再生成一份一样的（同特效、同父组件 / 插槽 / 偏移）。返回 组件 或 nil, 错误
-- 【适配】NiagaraComponent:GetAsset / GetAttachParent / GetAttachSocketName / RelativeLocation + Default__NiagaraFunctionLibrary:SpawnSystemAttached
local function ownBeamCopy(c, inst)
    local lib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
    if not valid(lib) then return nil, "找不到 NiagaraFunctionLibrary" end
    local okA, sys = pcall(function() return c:GetAsset() end)
    if not (okA and valid(sys)) then sys = rawProp(inst, "LazerNSSystem") end
    local okP, parent = pcall(function() return c:GetAttachParent() end)
    local okS, sock = pcall(function() return c:GetAttachSocketName() end)
    if not (valid(sys) and okP and valid(parent)) then return nil, "读不到特效 / 父组件" end
    local loc = { X = 0.0, Y = 0.0, Z = 0.0 }
    pcall(function() local r = c.RelativeLocation; loc = { X = r.X, Y = r.Y, Z = r.Z } end)
    local ok, r = pcall(function()
        return lib:SpawnSystemAttached(sys, parent, okS and sock or FName("None"), loc, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }, 0, false, true, 0, true)
    end)
    if ok and valid(r) then return r end
    return nil, tostring(r)
end

-- §139.1 替身的激光柱（说明见上）：让技能调 SpawnLoopLaserNS 生成一份，换成自己生成的（§139.4）。返回 组件列表, 说明
-- 【适配】技能实例:SpawnLoopLaserNS() + 技能变量 "Niagara Comps"（数组）/ LaserNS
local function laserBeamSpawn(inst)
    local function collect()
        local list = {}
        local function add(c)
            if not valid(c) then return end
            for _, o in ipairs(list) do if sameObj(o, c) then return end end
            list[#list + 1] = c
        end
        eachArr(rawProp(inst, "Niagara Comps"), function(_, c) add(c) end)
        add(rawProp(inst, "LaserNS"))
        return list
    end
    local before = collect()
    local ok, err = LO.callNoArg(inst, "SpawnLoopLaserNS")
    if not ok then return nil, tostring(err) end
    local after, new = collect(), {}
    for _, c in ipairs(after) do
        local old = false
        for _, b in ipairs(before) do if sameObj(b, c) then old = true end end
        if not old then new[#new + 1] = c end
    end
    if #new == 0 then new = after end          -- 技能复用了原来的组件
    -- §139.4 技能的那份挂在技能变量上：技能每帧按替身的锁定目标 / AI 朝向转它（光柱一直对着你），一段照完还会把它关掉
    -- （光柱一段一段断开）。换成自己生成的一份，技能的那份收掉；自己生成不了就还用技能的
    local own, err = {}, nil
    for _, c in ipairs(new) do
        local o, e = ownBeamCopy(c, inst)
        if o then
            own[#own + 1] = o
            pcall(function() c:Deactivate() end)
            pcall(function() c:K2_DestroyComponent(c) end)
        else own[#own + 1] = c; err = e end
    end
    return own, string.format("原有 %d 个，自己生成 %d/%d%s", #before, err and 0 or #own, #new, err and ("：" .. err:sub(-80)) or "")
end

-- 组件（光柱）朝向 to 点（同技能自己的 UpdateLaserRotation：FindLookAtRotation → SetWorldRotation）。返回 转了几个
-- 【适配】SceneComponent:K2_GetComponentLocation / K2_SetWorldRotation
local function aimComps(comps, to)
    local n = 0
    if not to then return 0 end
    for _, c in ipairs(comps or {}) do
        local okL, a = pcall(function() return c:K2_GetComponentLocation() end)
        if valid(c) and okL and a then
            local dx, dy, dz = to.X - a.X, to.Y - a.Y, to.Z - a.Z
            local rot = { Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), Yaw = math.deg(math.atan(dy, dx)), Roll = 0.0 }
            if pcall(function() c:K2_SetWorldRotation(rot, false, {}, false) end) then n = n + 1 end
        end
    end
    return n
end

-- 收掉组件（光柱）。返回 收了几个
-- 【适配】NiagaraComponent:Deactivate + ActorComponent:K2_DestroyComponent
local function destroyComps(comps)
    local n = 0
    for _, c in ipairs(comps or {}) do
        if valid(c) then
            pcall(function() c:Deactivate() end)
            if pcall(function() c:K2_DestroyComponent(c) end) then n = n + 1 end
        end
    end
    return n
end

-- §139.3 组件（光柱）直接转到 rot（对方发来的镜头朝向；真人的光柱就是镜头朝向）。返回 转了几个
-- 【适配】SceneComponent:K2_SetWorldRotation
local function rotateComps(comps, rot)
    local n = 0
    for _, c in ipairs(comps or {}) do
        if valid(c) and pcall(function() c:K2_SetWorldRotation({ Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = 0.0 }, false, {}, false) end) then n = n + 1 end
    end
    return n
end

-- §139.4 组件 / 角色的世界朝向，记日志用。返回 "(P.. Y..)" 或 "?"
-- 【适配】SceneComponent:K2_GetComponentRotation / Actor:K2_GetActorRotation
local function compRotStr(o)
    if not valid(o) then return "?" end
    local ok, r = pcall(function() return o:K2_GetComponentRotation() end)
    if not (ok and r) then ok, r = pcall(function() return o:K2_GetActorRotation() end) end
    return ok and r and string.format("(P%.0f Y%.0f)", r.Pitch, r.Yaw) or "?"
end

-- §139.7 光柱的伤害：真人按住激光时技能用子弹数据 BD_GA_DuYanBow_Laser_Emitter 的 CreateBullet(SpawnTransform, WorldContextObject)
-- 生成发射器 BP_PBZ_ProjectileEmitter_C（10:22 / 10:32 探针），替身从来不生成 → 替身光柱没伤害。这里照样让替身技能的子弹数据生成一个：
-- 位置 = 光柱的位置，朝向 = rot，世界上下文 = 替身；再 Initialize + Start（§139.7 下面）。返回 发射器 或 nil, 说明
-- 朝向（度）→ 四元数，CreateBullet 的 Transform 要用
-- 【适配】同 FRotator::Quaternion 的公式（纯计算）
local function rotQuat(r)
    local p, y, ro = math.rad(r.Pitch or 0) / 2, math.rad(r.Yaw or 0) / 2, math.rad(r.Roll or 0) / 2
    local SP, CP, SY, CY, SR, CR = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(ro), math.cos(ro)
    return { X = CR * SP * SY - SR * CP * CY, Y = -CR * SP * CY - SR * CP * SY,
             Z = CR * CP * SY - SR * SP * CY, W = CR * CP * CY + SR * SP * SY }
end

-- 场上所有光柱发射器
-- 【适配】FindAllOf("BP_PBZ_ProjectileEmitter_C")
local function emitterList()
    local ok, l = pcall(function() return FindAllOf("BP_PBZ_ProjectileEmitter_C") end)
    return ok and l or {}
end

-- §139.7 10:56 探针：子弹接口 BulletInterface 有 Initialize(Parent, OwnerAvatar, SourceAbility, Data, bDebug) / Start()。
-- CreateBullet 只造出来（所有者空、状态 0），要再 Initialize(nil, 替身, 替身激光技能, 子弹数据, false) + Start()。返回 说明
-- 【适配】发射器:Initialize(…) / Start()（BulletInterface）
local function bulletInitStart(e, pup, inst, bd)
    local okI, errI = pcall(function() e:Initialize(nil, pup, inst, bd, false) end)
    local okS, errS = pcall(function() e:Start() end)
    return string.format("Initialize %s，Start %s", okI and "成功" or ("失败 " .. tostring(errI):sub(-80)),
        okS and "成功" or ("失败 " .. tostring(errS):sub(-80)))
end

-- 生成（说明见上）
-- 【适配】技能实例.BulletData:CreateBullet(Transform, Object)（返回值是接口，拿不到时按新出现的找）
local function laserEmitterSpawn(inst, pup, at, rot, bdOver)
    local bd = bdOver or rawProp(inst, "BulletData")      -- §139.8 眼睛用另一份子弹数据 BD_DuYan_Bow_Eye
    if not valid(bd) then return nil, "技能没有子弹数据" end
    local loc = at
    if not loc then
        local ok, l = pcall(function() return pup:K2_GetActorLocation() end)
        loc = ok and l or nil
    end
    if not loc then return nil, "读不到位置" end
    local before = {}
    for _, e in ipairs(emitterList()) do before[#before + 1] = e end
    local tf = { Rotation = rotQuat(rot or {}), Translation = { X = loc.X, Y = loc.Y, Z = loc.Z }, Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
    -- 世界上下文给替身 / 技能实例都一样（所有者空、状态 0）：所有者等由下面 Initialize 填
    local ok, r = pcall(function() return bd:CreateBullet(tf, pup) end)
    if not ok then return nil, "CreateBullet 失败 " .. tostring(r):sub(-100) end
    local e, how
    local okR, robj = pcall(function() return r and r:GetObject() end)
    if okR and valid(robj) then e, how = robj, "返回值" end
    if not e and valid(r) and type(r) == "userdata" then
        local okN = pcall(function() return r:GetFullName() end)
        if okN then e, how = r, "返回值" end
    end
    if not e then
        for _, x in ipairs(emitterList()) do
            local old = false
            for _, b in ipairs(before) do if sameObj(b, x) then old = true end end
            if not old and valid(x) then e, how = x, "按新出现的找" end
        end
    end
    if not e then return nil, "调用成功但没找到新的发射器（返回 " .. tostring(r) .. "）" end
    return e, how .. "；" .. bulletInitStart(e, pup, inst, bd)
end

-- 发射器现在的状态（记日志）
-- 【适配】发射器变量 BulletOwnerAvatar / BulletSourceAbility / BulletStatus + K2_GetActorLocation / Rotation
local function emitterInfo(e)
    if not valid(e) then return "无效" end
    local o, a = rawProp(e, "BulletOwnerAvatar"), rawProp(e, "BulletSourceAbility")
    local okL, l = pcall(function() return e:K2_GetActorLocation() end)
    local okR, r = pcall(function() return e:K2_GetActorRotation() end)
    return string.format("%s 所有者 %s 来源技能 %s 状态 %s 位置 %s 朝向 %s", shortName(full(e)),
        valid(o) and shortName(full(o)) or "空", valid(a) and shortName(full(a)) or "空", tostring(rawProp(e, "BulletStatus")),
        okL and l and string.format("(%.0f, %.0f, %.0f)", l.X, l.Y, l.Z) or "?",
        okR and r and string.format("(P%.0f Y%.0f)", r.Pitch, r.Yaw) or "?")
end

-- 发射器转到 rot、挪到 at（光柱扫的时候跟着；11:03 实测发射器停在生成时的位置不动，打人的子弹从那儿出）。返回 是否成功
-- 【适配】发射器:SetBulletTransform(Transform)（BulletInterface），不行退回 Actor:K2_SetActorLocationAndRotation
local function moveEmitter(e, at, rot)
    if not (valid(e) and at) then return false end
    local tf = { Rotation = rotQuat(rot or {}), Translation = { X = at.X, Y = at.Y, Z = at.Z }, Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
    if pcall(function() e:SetBulletTransform(tf) end) then return true end
    return pcall(function() e:K2_SetActorLocationAndRotation(at, { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = 0.0 }, false, {}, true) end)
end

-- 收掉发射器：先按子弹自己的 Deactivate(0)（11:03 只 K2_DestroyActor 时场上发射器一个没少），再删 actor。返回 是否成功
-- 【适配】发射器:Deactivate(TimeToDestroy)（BulletInterface）+ Actor:K2_DestroyActor
local function destroyActor(e)
    if not valid(e) then return false end
    local okD = pcall(function() e:Deactivate(0.0) end)
    local okK = pcall(function() e:K2_DestroyActor() end)
    return okD or okK
end

-- （obj 给了就列它全部函数：10:28 子系统里没有 CreateBullet，exe 里它挨着 GetBulletClass / NewData，多半是子弹数据自己的函数）
-- §139.6 只读：子弹子系统（光柱伤害发射器 BP_PBZ_ProjectileEmitter_C < BulletActorBase 是它生成的）里名字带
-- Bullet / Create / Spawn 的函数和参数（名字:类型）。返回 日志行列表
-- 【适配】FindFirstOf("BulletSubsystem") / StaticFindObject + UStruct:ForEachFunction / UFunction:ForEachProperty
local function bulletSubsysProbe(obj, isClass)
    local lines = {}
    local sub = obj
    if not sub then
        local ok, s1 = pcall(function() return FindFirstOf("BulletSubsystem") end)
        sub = ok and s1 or nil
    end
    if not valid(sub) then return { "BulletSubsystem 找不到" } end
    lines[1] = "对象 " .. full(sub)
    local okC, c = pcall(function() return sub:GetClass() end)
    c = okC and c or nil
    if isClass then c = sub end         -- §139.7 直接给类（接口 /Script/SGameCombatSystem.BulletInterface）：只看它自己
    for _ = 1, isClass and 1 or 6 do
        if not valid(c) then break end
        pcall(function()
            c:ForEachFunction(function(f)
                local n = fnameStr(f:GetFName())
                if obj or n:find("Bullet") or n:find("Create") or n:find("Spawn") then
                    local ps = {}
                    pcall(function() f:ForEachProperty(function(pr)
                        local t = "?"
                        pcall(function() t = fnameStr(pr:GetClass():GetFName()) end)
                        ps[#ps + 1] = fnameStr(pr:GetFName()) .. ":" .. t
                    end) end)
                    lines[#lines + 1] = n .. "(" .. table.concat(ps, ", ") .. ")"
                end
            end)
        end)
        local okS, sup = pcall(function() return c:GetSuperStruct() end)
        c = okS and sup or nil
    end
    return lines
end

-- §139.7 只读：场上所有子弹按"所有者 / 类"数一下（看光柱发射器有没有再生成打人的子弹），who(owner) 返回 "我" / "替身" / nil
-- 【适配】FindAllOf("BulletActorBase") + 子弹变量 BulletOwnerAvatar / BulletStatus
local function bulletScan(who)
    local ok, l = pcall(function() return FindAllOf("BulletActorBase") end)
    if not (ok and l) then return "没有子弹" end
    local cnt = {}
    for _, b in ipairs(l) do
        if valid(b) then
            local w = who(rawProp(b, "BulletOwnerAvatar")) or "别人"
            local k = w .. ":" .. shortName(full(b)):gsub("_%d+$", "") .. "/" .. tostring(rawProp(b, "BulletStatus"))
            cnt[k] = (cnt[k] or 0) + 1
        end
    end
    local out = {}
    for k, n in pairs(cnt) do out[#out + 1] = k .. "×" .. n end
    table.sort(out)
    return #out > 0 and table.concat(out, " ") or "没有子弹"
end

-- §139.7 只读：子弹挂在哪（接口 GetBulletAttachParent）和位置
-- 【适配】发射器:GetBulletAttachParent(ParentComp, Socket) / K2_GetActorLocation
local function bulletWhere(b)
    if not valid(b) then return "无效" end
    local okL, l = pcall(function() return b:K2_GetActorLocation() end)
    local par = "?"
    pcall(function()
        local outp = {}
        local r = b:GetBulletAttachParent(outp, outp)
        par = tostring(r) .. " " .. tostring(outp.ParentComp and full(outp.ParentComp) or "") .. " " .. tostring(outp.Socket or "")
    end)
    return string.format("位置 %s 挂在 %s", okL and l and string.format("(%.0f, %.0f, %.0f)", l.X, l.Y, l.Z) or "?", par)
end

-- §139.9 某个角色名下某类子弹（状态 2 = 在跑）有几颗：我的光柱有没有眼睛（BP_DuYanBow_Bullet_Eye_C）
-- 【适配】FindAllOf(子弹类) + 子弹变量 BulletOwnerAvatar / BulletStatus
local function countBullets(cls, owner)
    local ok, l = pcall(function() return FindAllOf(cls) end)
    local n = 0
    for _, b in ipairs(ok and l or {}) do
        if valid(b) and rawProp(b, "BulletStatus") == 2 and sameObj(rawProp(b, "BulletOwnerAvatar"), owner) then n = n + 1 end
    end
    return n
end

-- §139.7 按路径找对象（类 / 接口），找不到 nil
-- 【适配】StaticFindObject
local function findObj(path)
    local ok, o = pcall(function() return StaticFindObject(path) end)
    return ok and valid(o) and o or nil
end

-- §139.3 角色控制器的朝向（替身 = 它的 AI 控制器；技能瞄准 / 光柱没锁定目标时看 GetControlRotation）。返回 是否成功
-- 【适配】Pawn:GetController():SetControlRotation
local function setControlRot(actor, rot)
    local ok, c = pcall(function() return actor:GetController() end)
    if not (ok and valid(c)) then return false end
    return pcall(function() c:SetControlRotation({ Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = 0.0 }) end)
end

-- ============================================================ 地图名

-- 【适配】Actor:GetWorld() 的短名（= 地图名，双方比对是不是同一张图）
local function mapName(actor)
    local ok, w = pcall(function() return actor:GetWorld() end)
    return ok and (shortName(full(w)) or "?") or "?"
end

-- ============================================================ 动画：收招（Montage_Stop）

-- "收招"：把当前正在播的动作（攻击）淡出 0.3 秒中断掉。
-- 用户建议（v0.9.1）：没有真正的"被弹开"动作时，用收招代替受击硬直。中断攻击动作也会结束这一刀的技能和伤害判定
-- 【适配】AnimInstance:Montage_Stop(0.3, 当前蒙太奇)
local function retract(actor)
    local m = rawProp(actor, "Mesh")
    if not valid(m) then return nil end
    local okA, an = pcall(function() return m:GetAnimInstance() end)
    if not (okA and valid(an)) then return nil end
    local okM, mt = pcall(function() return an:GetCurrentActiveMontage() end)
    if not (okM and valid(mt)) then return "（没有正在播的动作）" end
    local name = shortName(full(mt))
    local ok = pcall(function() an:Montage_Stop(0.3, mt) end)
    return ok and name or nil
end

-- v0.23.1 立刻停招（不淡出）：淡出的那 0.3 秒里招式的伤害窗口还在，22:44:16 替身播了受击，下一秒那刀照样砍中玩家。
-- 返回停掉的动作名；没有正在播的动作返回 nil
-- 【适配】AnimInstance:Montage_Stop(0.0, 当前蒙太奇)
local function cutMontage(actor)
    local m = rawProp(actor, "Mesh")
    if not valid(m) then return nil end
    local okA, an = pcall(function() return m:GetAnimInstance() end)
    if not (okA and valid(an)) then return nil end
    local okM, mt = pcall(function() return an:GetCurrentActiveMontage() end)
    if not (okM and valid(mt)) then return nil end
    local name = shortName(full(mt))
    local ok = pcall(function() an:Montage_Stop(0.0, mt) end)
    return ok and name or nil
end

-- ============================================================ 追帧（v0.27.0，docs/LATENCY_DESIGN.md §5）

-- 角色当前在播的蒙太奇：返回 AnimInstance, 蒙太奇, 短名, 当前位置（秒）；没有返回 nil
-- 【适配】Mesh:GetAnimInstance():GetCurrentActiveMontage() + Montage_GetPosition(蒙太奇)
local function activeMontage(actor)
    local m = rawProp(actor, "Mesh")
    if not valid(m) then return nil end
    local okA, an = pcall(function() return m:GetAnimInstance() end)
    if not (okA and valid(an)) then return nil end
    local okM, mt = pcall(function() return an:GetCurrentActiveMontage() end)
    if not (okM and valid(mt)) then return nil end
    local okP, pos = pcall(function() return an:Montage_GetPosition(mt) end)
    return an, mt, shortName(full(mt)) or "?", (okP and type(pos) == "number") and pos or nil
end

-- 当前蒙太奇往后跳到 pos 秒。返回 是否成功, 短名, 跳之前的位置
-- 【适配】AnimInstance:Montage_SetPosition(蒙太奇, 秒)
local function montageSetPos(actor, pos)
    local an, mt, name, cur = activeMontage(actor)
    if not an then return false, nil, nil end
    local ok = pcall(function() an:Montage_SetPosition(mt, pos) end)
    return ok, name, cur
end

-- 当前蒙太奇的通知（AnimNotify / AnimNotifyState）：{ {cls=类短名, t=开始秒, d=持续秒}, ... }，按开始时间排序；读不到返回 nil
-- 时间：FAnimNotifyEvent 继承 FAnimLinkableElement，LinkMethod 0 = Absolute（LinkValue 就是蒙太奇时间），
-- 其他 = 相对所在片段（SegmentBeginTime + LinkValue）；再加 TriggerTimeOffset。实机还没验证过这几个字段读不读得到
-- 读的字段：Notify / NotifyStateClass / LinkMethod / LinkValue / SegmentBeginTime / TriggerTimeOffset / Duration
-- 【适配】UAnimMontage.Notifies（TArray<FAnimNotifyEvent>）
local function montageNotifies(actor)
    local _, mt, name = activeMontage(actor)
    if not mt then return nil end
    local arr = rawProp(mt, "Notifies")
    if arr == nil then return nil, name end
    local list, num = {}, nil
    pcall(function() num = arr:GetArrayNum() end)
    local okIter = eachArr(arr, function(_, ev)
        local cls
        local st = rawProp(ev, "NotifyStateClass")
        if valid(st) then cls = shortName(full(st)) else
            local n = rawProp(ev, "Notify")
            if valid(n) then cls = shortName(full(n)) end
        end
        local lm = tonumber(rawProp(ev, "LinkMethod")) or 0
        local lv = tonumber(rawProp(ev, "LinkValue")) or 0
        local sb = tonumber(rawProp(ev, "SegmentBeginTime")) or 0
        local t = (lm == 0 and lv or sb + lv) + (tonumber(rawProp(ev, "TriggerTimeOffset")) or 0)
        list[#list + 1] = { cls = cls or "?", t = t, d = tonumber(rawProp(ev, "Duration")) or 0, state = valid(st) }
    end)
    table.sort(list, function(a, b) return a.t < b.t end)
    return list, name, { num = num, ok = okIter }      -- 诊断：§78.1 实机全是空列表，要分清是数组本来就空还是遍历失败
end

-- ============================================================ 锁定（v0.23.3）

-- 这个角色锁定着谁（硬锁定；软锁定不算）。没锁 / 读不到返回 nil；第二个返回值 = 从哪读到的
-- §132（2026-11-07 用户："我锁定他了，但是我的枪打不到他，他的也打不到我"）：真人对战里收到的 lk 一直是 0；
-- 日志里"对方锁定着你"全是假对手发的（它永远发 lk=1），真人锁定从没验证过。§119 实测看到你锁替身时目标存在你的
-- 瞄准组件（Targeting Component.LockTarget = 替身的 CharacterMesh0）——GetLockingTarget 读不到时问瞄准组件
-- 【适配】PBZCharacter:GetLockingTarget(bIgnoreSoftLocking = true)（v0.9.10 锁定探针，§19.15）；TargetingComponent:HasLockTarget()
local function lockingTarget(actor)
    if not valid(actor) then return nil end
    local ok, t = pcall(function() return actor:GetLockingTarget(true) end)
    if ok and valid(t) then return t, "GetLockingTarget" end
    local tc = LO.targetingComp(actor)
    if tc then
        local okH, has = pcall(function() return tc:HasLockTarget() end)
        if okH and has == true then return tc, "瞄准组件" end
    end
    return nil
end

-- 把角色的锁定目标设成 target（替身没有锁定系统在管，让它的招式像对方那样追着你打）。返回是否写成功
-- 【适配】角色的 LockTargetActor / TrueLockTargetActor 属性（§19.15 探针里列出的玩家锁定字段）
local function setLockTarget(actor, target)
    if not valid(actor) then return false end
    local ok1 = pcall(function() actor.LockTargetActor = target end)
    local ok2 = pcall(function() actor.TrueLockTargetActor = target end)
    return ok1 or ok2
end

-- 角色当前朝向（度）
-- 【适配】Actor:K2_GetActorRotation().Yaw
local function yawOf(actor)
    local ok, r = pcall(function() return actor:K2_GetActorRotation() end)
    return (ok and r and type(r.Yaw) == "number") and r.Yaw or nil
end

-- ============================================================ 角色状态组件

-- 【适配】角色的 Actor State Component（ActorStateComponent）
local function stateComp(actor) return valid(actor) and rawProp(actor, "Actor State Component") or nil end

-- ============================================================ 技能列表（ASC.ActivatableAbilities）

-- 【适配】ASC.ActivatableAbilities.Items[i].Ability:GetClass() → { name, cls } 列表
abilitiesOf = function(actor)
    local asc = ascOf(actor)
    if not valid(asc) then return nil end
    local list = {}
    local cont = rawProp(asc, "ActivatableAbilities")
    local items = cont and rawProp(cont, "Items")
    local ok = eachArr(items, function(_, spec)
        local ab = rawProp(spec, "Ability")
        if valid(ab) then
            local okC, cls = pcall(function() return ab:GetClass() end)
            if okC and valid(cls) then
                list[#list + 1] = { name = shortName(full(cls)) or full(cls), cls = cls }
            end
        end
    end)
    if not ok then out("  !! 遍历 ActivatableAbilities.Items 失败 (%s)", type(items)) end
    return list
end

-- ============================================================ 防暗杀 / 锁血：GE_LockHealth（v0.9.21–v0.9.25）

local NO_STEALTH_TAGS = { "CharacterState.Forbid.StealthExecuteTarget", "AI.State.Combat", "CharacterState.CanNotBeExecuted" }

-- 【适配】ASC:HasMatchingGameplayTag 查 NO_STEALTH_TAGS 三个标签（日志用）
local function tagReport(actor)
    local asc = ascOf(actor)
    local parts = {}
    for _, t in ipairs(NO_STEALTH_TAGS) do
        local ok, h = pcall(function() return asc:HasMatchingGameplayTag({ TagName = FName(t) }) end)
        parts[#parts + 1] = t:match("[^.]+$") .. "=" .. (ok and tostring(h) or "?")
    end
    return table.concat(parts, " ")
end

-- v0.9.22 实测：GE_LockHealth 不在内存，旧版 LoadAsset 失败被 pcall 静默吞掉。
-- v0.9.23：多个候选（都挂 CanNotBeExecuted）× 多种路径写法，每一步都记日志
local GE_CANDIDATES = {
    "/PBZCombatAsset/Prototypes/GameplayEffects/GE_LockHealth",
    "/PBZCombatAsset/ActorData/Players/Hun/Weapon/HeiMoShang/GE_Hun_Climax_LockHealth",
    "/PBZCombatAsset/ActorData/Mobs/045_JingYe/GE_JingYe_LockHealth",
    "/PBZCombatAsset/ActorData/Mobs/077_LengTu/GameplayEffect/GE_LengTu_LockHealth",
}
-- 【适配】GE_LockHealth 类：先 StaticFindObject，不在内存就 LoadAsset（几个候选路径，v0.9.23）
local function geLockHealthClass()
    for _, pkg in ipairs(GE_CANDIDATES) do
        local name = pkg:match("([^/]+)$")
        local clsPath = pkg .. "." .. name .. "_C"
        out("  [步骤] StaticFindObject(%s)", clsPath)
        local cls = StaticFindObject(clsPath)
        out("    -> %s", valid(cls) and "找到" or "没有")
        if valid(cls) then return cls, name .. " 已在内存" end
    end
    out("  LoadAsset 类型=%s", type(LoadAsset))
    if type(LoadAsset) ~= "function" then return nil, "没有 LoadAsset" end
    for _, pkg in ipairs(GE_CANDIDATES) do
        local name = pkg:match("([^/]+)$")
        local clsPath = pkg .. "." .. name .. "_C"
        for _, arg in ipairs({ clsPath, pkg .. "." .. name, pkg }) do
            out("  [步骤] LoadAsset(%s)", arg)
            local ok, r = pcall(function() return LoadAsset(arg) end)
            out("  LoadAsset(%s) -> %s %s", arg, ok and "成功" or "失败", ok and anyToStr(r) or tostring(r))
            local cls = StaticFindObject(clsPath)
            if valid(cls) then return cls, name .. " LoadAsset 加载" end
            if ok and valid(r) and tostring(pathOf(r)):find("_C$") then return r, name .. " LoadAsset 返回" end
        end
    end
    return nil, "找不到"
end

-- 【适配】给替身 ASC:BP_ApplyGameplayEffectToSelf(GE_LockHealth, 1.0, {})（挂 CanNotBeExecuted + Health_Min，v0.9.24）
local function noStealthByGE(pup, why)
    pup = pup or puppet()
    if not valid(pup) then out("!! 先按 F12 造替身"); return false end
    local asc = ascOf(pup)
    out("== 方案 B 开始（%s）==", why or "")
    local cls, how = geLockHealthClass()
    out("== 方案 B：施加 GE_LockHealth（%s）== 效果类 %s（%s）；之前 %s；Health_Min=%s",
        why or "", cls and short(pathOf(cls)) or "<无>", how, tagReport(pup), tostring(attrOf(pup, "Health_Min")))
    if not cls then return false end
    out("  [步骤] BP_ApplyGameplayEffectToSelf(GE_LockHealth, 1.0, 空上下文)")
    local ok, r = pcall(function() return asc:BP_ApplyGameplayEffectToSelf(cls, 1.0, {}) end)
    out("  调用%s，返回 %s", ok and "成功" or ("失败 " .. tostring(r)), anyToStr(r))
    out("  之后 %s；Health_Min=%s", tagReport(pup), tostring(attrOf(pup, "Health_Min")))
    return ok and type(r) == "table" and r.bPassedFiltersAndWasExecuted == true
end

-- ============================================================ 对局用（原在 M4 闭包里）：动画实例、补满、背包、自己锁血

-- 【适配】Mesh:GetAnimInstance()
local function animOf(actor)
    local m = valid(actor) and rawProp(actor, "Mesh") or nil
    if not valid(m) then return nil end
    local ok, an = pcall(function() return m:GetAnimInstance() end)
    return (ok and valid(an)) and an or nil
end

-- 【适配】AnimInstance:Montage_Stop(0.2, 当前蒙太奇)（倒地动作停住后站起）
local function standUp(actor)
    local an = animOf(actor)
    if not an then return end
    local ok, mt = pcall(function() return an:GetCurrentActiveMontage() end)
    if ok and valid(mt) then pcall(function() an:Montage_Stop(0.2, mt) end) end
end

-- v0.10.5 用户反馈：补满后血条 UI 不更新（还显示空血，挨一下打才刷新）。直接写属性绕过了 GAS 的属性变化通知。
-- 改成先施加游戏自己的回满效果（会走通知），没补满再直接写兜底。候选来自 pak 扫描（名字表引用 Health/Health_Max）
local HEAL_GES = {
    "/Game/PBZContent/DataTable/Character/GameplayEffects/GE_RevocerHealthAndAnger",   -- 血 + 杀气
    "/Game/PBZContent/Blueprint/Item/GameplayEffect/GE_RegenFullHealth",
}

-- 2026-11-05 10:23:36 崩溃（第 2 回合倒计时补满时）：以前把找到的类对象存在 MATCH.healCls 里永久复用。LoadAsset 来的蓝图类
-- 没有别的东西引用，会被引擎垃圾回收；Lua 手里的引用不拦着回收，之后拿已释放的类去 BP_ApplyGameplayEffectToSelf，
-- 引擎检查"是不是 GameplayEffect 子类"时读到垃圾（dump：PBZ.exe+0x4cabbb8 IsChildOf，栈下面是 UE4SS 的 Lua 调用）。
-- 现在只记"哪个路径能用"，每次用时 StaticFindObject 现找（被回收了就找不到 → 重新 LoadAsset）。类对象不要跨 tick 缓存
-- 【适配】回满 GE 类（GE_RevocerHealthAndAnger / GE_RegenFullHealth），StaticFindObject / LoadAsset（v0.10.5）
local function healClass()
    if MATCH.healPath == false then return nil end        -- 两个候选都没有：不再找
    for _, pkg in ipairs(HEAL_GES) do
        local name = pkg:match("([^/]+)$")
        local path = pkg .. "." .. name .. "_C"
        if MATCH.healPath == nil or MATCH.healPath == path then
            local cls = StaticFindObject(path)
            if not valid(cls) and type(LoadAsset) == "function" then
                if (MATCH.healLoads or 0) < 5 then out("  [步骤] LoadAsset(%s)", path) end
                MATCH.healLoads = (MATCH.healLoads or 0) + 1
                pcall(function() LoadAsset(path) end)
                cls = StaticFindObject(path)
            end
            if MATCH.healPath == nil then out("  回满效果 %s：%s", name, valid(cls) and "找到" or "没有") end
            if valid(cls) then MATCH.healPath = path; return cls, name end
        end
    end
    if MATCH.healPath == nil then MATCH.healPath = false end
    return nil
end

-- 【适配】BP_ApplyGameplayEffectToSelf(回满 GE)，没满再直接写 Health / Shachi
local function refill(actor)
    local hm, sm = attrOf(actor, "Health_Max"), attrOf(actor, "Shachi_Max")
    local hp0, sh0 = hpOf(actor) or 0, attrOf(actor, "Shachi") or 0
    if not ((hm and hp0 < hm - 0.5) or (sm and sh0 < sm - 0.5)) then return end
    local cls, name = healClass()
    local how = "直接写"
    if cls then
        local asc = ascOf(actor)
        local ok, r = pcall(function() return asc:BP_ApplyGameplayEffectToSelf(cls, 1.0, {}) end)
        how = string.format("%s（%s）", name, ok and "已施加" or ("失败 " .. tostring(r)))
    end
    local hp1, sh1 = hpOf(actor) or 0, attrOf(actor, "Shachi") or 0
    if hm and hp1 < hm - 0.5 then setAttr(actor, "Health", hm); how = how .. " + 血量直接写" end
    if sm and sh1 < sm - 0.5 then setAttr(actor, "Shachi", sm); how = how .. " + 杀气直接写" end
    if (MATCH.refillLogs or 0) < 12 then
        MATCH.refillLogs = (MATCH.refillLogs or 0) + 1
        out("补满：%s；血量 %.0f → 效果后 %.0f → %.0f；杀气 %.0f → 效果后 %.0f → %.0f", how, hp0, hp1,
            hpOf(actor) or -1, sh0, sh1, attrOf(actor, "Shachi") or -1)
    end
end

-- 补满药瓶（v0.10.10）。v0.10.9 探针：药瓶归背包子系统 PBZBackPackSubsystem 管，
-- ClearMedicineUseTime(MedicineID:Name) 清掉"已用次数"；当前装备的两瓶是 TopMedicineID / BottomMedicineID
-- 【适配】FindFirstOf("PBZBackPackSubsystem")（药瓶，v0.10.9）
local function backpack()
    if valid(MATCH.bp) then return MATCH.bp end
    local ok, b = pcall(function() return FindFirstOf("PBZBackPackSubsystem") end)
    MATCH.bp = (ok and valid(b)) and b or nil
    return MATCH.bp
end

-- 自己锁血：和替身同一个 GE（v0.9.24 实测能施加，Health_Min → 0.01）
-- 【适配】自己 ASC:BP_ApplyGameplayEffectToSelf(GE_LockHealth)（对局锁血，§20）
local function lockSelf(p1)
    -- 换了角色（读档 / 真死后复活）旧锁就不算数
    if MATCH.lock and MATCH.lockFor == pathOf(p1) then return true end
    MATCH.lock = nil
    local cls = geLockHealthClass()
    local asc = ascOf(p1)
    if not (cls and valid(asc)) then
        out("!! 自己锁血失败：%s", cls and "没有 ASC" or "找不到 GE_LockHealth")
        return false
    end
    out("  [步骤] 自己 BP_ApplyGameplayEffectToSelf(GE_LockHealth)")
    local ok, r = pcall(function() return asc:BP_ApplyGameplayEffectToSelf(cls, 1.0, {}) end)
    MATCH.lock = (ok and type(r) == "table" and r.bPassedFiltersAndWasExecuted == true) and r or nil
    MATCH.lockFor = pathOf(p1)
    out("  自己锁血：%s，返回 %s；之后 %s；Health_Min=%s", ok and "调用成功" or ("失败 " .. tostring(r)),
        anyToStr(r), tagReport(p1), tostring(attrOf(p1, "Health_Min")))
    return MATCH.lock ~= nil
end

-- 解除：按来源效果类移除（参数是类 + 对象 + 整数，都是验证过安全的类型；不传句柄结构体）
-- 【适配】自己 ASC:RemoveActiveGameplayEffectBySourceEffect(GE_LockHealth, nil, -1)
local function unlockSelf(p1, why)
    if not MATCH.lock then return end
    MATCH.lock = nil
    local asc, cls = ascOf(p1), geLockHealthClass()
    out("解除自己的锁血（%s）", why)
    out("  [步骤] RemoveActiveGameplayEffectBySourceEffect(GE_LockHealth, nil, -1)")
    local ok, err = pcall(function() asc:RemoveActiveGameplayEffectBySourceEffect(cls, nil, -1) end)
    local rep = tagReport(p1)
    out("  调用%s；之后 %s；Health_Min=%s", ok and "成功" or ("失败 " .. tostring(err)), rep,
        tostring(attrOf(p1, "Health_Min")))
    if rep:find("CanNotBeExecuted=true", 1, true) then
        out("!! 锁血没解除：你现在打不死、也不能被处决。重启游戏即可清除（这个效果不进存档）")
    end
end

-- ============================================================ 替身：属性对齐、生成 / 藏起（v0.13.0 独立角色）

-- 替身默认是 1 级属性（850 血 / 攻击 100），两刀就死；对练时抄玩家1 的数值
local COPY_ATTRS = { "Level", "Health_Max", "Health", "Attack", "Shachi_Max", "Shachi",
                     "ShachiAttack", "Infliction_Max" }

-- 【适配】按 COPY_ATTRS 把玩家1 的属性写进替身（attrOf / setAttr）
local function copyStats(from, to)
    local parts = {}
    for _, n in ipairs(COPY_ATTRS) do
        local v = attrOf(from, n)
        -- v0.6.3 实测：玩家残血时重建替身，替身也只有残血。血量直接给满
        if n == "Health" then v = attrOf(from, "Health_Max") or v end
        if v ~= nil then
            setAttr(to, n, v)
            parts[#parts + 1] = string.format("%s=%s", n, tostring((attrOf(to, n))))
        end
    end
    out("替身属性已对齐玩家1（写后回读）: %s", table.concat(parts, " "))
end

-- 【适配】替身 Health <= 0
local function puppetDead()
    local c = hpOf(puppet())
    return c ~= nil and c <= 0
end

-- v0.13.0：对手改用"独立角色"（SpawnActor 玩家同类 + AIController），不再 CreatePlayer。
-- 原因（2026-11-04 自测）：CreatePlayer 多出一个本地玩家后游戏菜单永久打不开（移除后也不恢复，根因在 CommonUI 深处没查清）；
-- 独立角色菜单正常、站在地上、124 个技能、出招能伤人（-973.4）。销毁玩家类角色会崩（v0.11.0），所以"移除"= 原地藏起来复用
-- 【适配】替身 CharacterMovement:DisableMovement + SetActorHiddenInGame / SetActorEnableCollision（不销毁，v0.11.0 销毁会崩）
local function removePuppet()
    local pup = puppet()
    if valid(pup) then
        local cm = rawProp(pup, "CharacterMovement")
        if valid(cm) then pcall(function() cm:DisableMovement() end) end
        pcall(function() pup:SetActorHiddenInGame(true) end)
        pcall(function() pup:SetActorEnableCollision(false) end)
        ST.npcStore, ST.npcCtl = pup, ST.secondPC
        out("替身已藏起（不销毁，留着复用）：%s", short(pathOf(pup)))
    end
    ST.secondPC, ST.secondPawn, ST.abList, ST.abIdx, ST.pupWeapon, ST.bareTest = nil, nil, nil, 0, nil, nil
    ST.watch.pup = {}
end

-- 【适配】World:SpawnActor(玩家1 的类) + SpawnActor(/Script/AIModule.AIController) + Possess（v0.13.0）；藏起的旧替身复用
local function createPuppet()
    if valid(puppet()) and not puppetDead() then
        out("替身已存在: %s", short(pathOf(puppet())))
        placeInFront(puppet(), PLACE_DIST)
        return
    end
    if ST.stableTicks < 90 then out("世界还在加载（%d/90），等 3 秒再按", ST.stableTicks); return end
    local p1, pc = getP1(), getP1PC()
    if not (valid(p1) and valid(pc)) then out("!! 没有玩家1"); return end
    local pup, ctl = ST.npcStore, ST.npcCtl
    if valid(pup) then
        -- 复用藏起来的那个
        pcall(function() pup:SetActorHiddenInGame(false) end)
        pcall(function() pup:SetActorEnableCollision(true) end)
        local cm = rawProp(pup, "CharacterMovement")
        if valid(cm) then pcall(function() cm:SetMovementMode(1, 0) end) end      -- MOVE_Walking
        out("替身复用：%s", short(pathOf(pup)))
    else
        local okC, cls = pcall(function() return p1:GetClass() end)
        local world = try("npc world", function() return p1:GetWorld() end)
        local loc = try("npc loc", function() return p1:K2_GetActorLocation() end)
        if not (okC and valid(cls) and valid(world) and loc) then out("!! 造替身：取类 / 世界 / 位置失败"); return end
        local pos = { X = loc.X, Y = loc.Y, Z = loc.Z + 50.0 }
        pup = try("spawn npc", function() return world:SpawnActor(cls, pos, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }) end)
        if not valid(pup) then out("!! 造替身：SpawnActor 失败"); return end
        -- 玩家类的 AIControllerClass 是空的（SpawnDefaultController 不生效），手动生成 AIController 再 Possess
        local aic = StaticFindObject("/Script/AIModule.AIController")
        ctl = valid(aic) and try("spawn aic", function()
            return world:SpawnActor(aic, pos, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }) end) or nil
        local okP = valid(ctl) and pcall(function() ctl:Possess(pup) end)
        out("替身（独立角色）：%s；AI 控制器 %s，Possess %s", short(pathOf(pup)), short(pathOf(ctl)),
            okP and "成功" or "失败")
    end
    ST.secondPC, ST.secondPawn, ST.pupWeapon, ST.npcStore = ctl, pup, nil, nil
    -- 阵营交给 M4 的 syncFaction（对局外友方、对局中敌对）
    out("  ASC=%s  阵营=%s  控制器=%s", tostring(valid(ascOf(pup))), factionName(pup), short(pathOf(rawProp(pup, "Controller"))))
    copyStats(p1, pup)
    placeInFront(pup, PLACE_DIST)
    ST.watch.pup = {}
end

-- §116.2 只读诊断（用户 2026-11-06"不确定伤害数值对不对"）：本地 AI 的扣血 = 我打在本机替身身上、游戏算出的伤害 × 系数，
-- 替身只抄了 COPY_ATTRS（等级 / 血 / 攻击 / 杀气），防御类没抄。比一下我和替身的全部属性，看差在哪。
-- 每局变的（血量 / 杀气 / 精纯杀气 / 暗源 / 积累条）不比。返回 { {名字, 我的当前值, 替身的当前值, 我的基础值, 替身的基础值}, ... }, 属性总数
local ATTR_DIFF_SKIP = { Health = true, Shachi = true, UltimateCharge = true, UltimateChargeCount = true, SpiritShadow = true,
                         Infliction = true }
-- 【适配】attrAll(我) / attrAll(替身) 逐个比当前值和基础值，差超过 0.001 的列出来
local function attrDiff(a, b)
    local la, lb = attrAll(a), attrAll(b)
    if not (la and lb) then return nil end
    local vb = {}
    for _, x in ipairs(lb) do vb[x.name] = x end
    local d = {}
    for _, x in ipairs(la) do
        local y = vb[x.name]
        if y and not ATTR_DIFF_SKIP[x.name] and type(x.cur) == "number" and type(y.cur) == "number"
            and (math.abs(x.cur - y.cur) > 0.001 or math.abs((x.base or 0) - (y.base or 0)) > 0.001) then
            d[#d + 1] = { x.name, x.cur, y.cur, x.base, y.base }
        end
    end
    return d, #la
end

-- 【适配】FindAllOf("Character") 里名字带 Monster、不是玩家1 / 替身的第一个
local function findMonster()
    local chars = FindAllOf("Character")
    if not chars then return nil end
    local p1, pup = getP1(), puppet()
    for _, c in pairs(chars) do
        if valid(c) and not sameObj(c, p1) and not sameObj(c, pup) and full(c):find("Monster") then
            return c
        end
    end
    return nil
end

-- ============================================================ Boss 血条（v0.24.0：对手的血量 / 杀气用游戏自带的 Boss 血条显示，HANDOVER §68）
-- 资源：/Game/PBZContent/UI/Hud/WB_BossHPBar（W_FrontEndHUDLayout 的 BossPoint 槽位里生成），自带过场用的
-- ForSeq_UpdateHealth / ForSeq_UpdateShachi（参数是 0~1 百分比）、ForSeq_SetNameText（FText）。
-- 注册接口参考 Phantom Pact（它给对方那台机器的 Boss 显示血条）；只借思路，没抄代码。

-- 【适配】FindFirstOf("PBZHUDLayout")（W_FrontEndHUDLayout_C 的 C++ 父类）
local function hudLayout()
    local h = FindFirstOf("PBZHUDLayout")
    return valid(h) and h or nil
end

-- 【适配】PBZHUDLayout:RegisterBossHPBar(Actor)；返回是否调用成功（HUD 不在 = false）
local function bossBarShow(actor)
    local hud = hudLayout()
    if not (hud and valid(actor)) then return false, "没有 HUD" end
    local ok, err = pcall(function() hud:RegisterBossHPBar(actor) end)
    return ok, err
end

-- 【适配】PBZHUDLayout:UnRegisterBossHPBar(Actor)
local function bossBarHide(actor)
    local hud = hudLayout()
    if not (hud and valid(actor)) then return false end
    return (pcall(function() hud:UnRegisterBossHPBar(actor) end))
end

-- 刚注册、Init 还没跑时血条的 Character 是空的，allowBlank = true 时也认这种。
-- skip = 已经认领了的血条（§141 观战两条血条都是空 Character，第二条要跳过第一条），空的那条不认它
-- 【适配】PBZHUDLayout:GetBossHPBarInstances()（TArray，元素可能是弱引用要 :get()）里 Character 是 actor 的 WB_BossHPBar_C
local function bossBarOf(actor, allowBlank, skip)
    local hud = hudLayout()
    if not (hud and valid(actor)) then return nil end
    local found, blank = nil, nil
    local okA, bars = pcall(function() return hud:GetBossHPBarInstances() end)
    if not okA then return nil end
    eachArr(bars, function(_, b)
        -- v0.24.0 实机：返回值是 Lua 表，元素是没解包的 RemoteUnrealParam（eachArr 的表分支不 :get()）
        if not valid(b) then pcall(function() b = b:get() end) end
        if found or not valid(b) then return end
        local c = rawProp(b, "Character")
        if valid(c) then
            if sameObj(c, actor) then found = b end
        elseif not blank and not (skip and sameObj(b, skip)) then
            blank = b
        end
    end)
    if not found then
        -- v0.24.0 实机：RegisterBossHPBar(替身) 成功但实例表里 3 次都找不到 → 再到所有 WB_BossHPBar_C 里找 Character 是替身的
        local all = FindAllOf("WB_BossHPBar_C")
        if all then
            for _, w in pairs(all) do
                if not found and valid(w) and sameObj(rawProp(w, "Character"), actor) then found = w end
            end
        end
    end
    return found or (allowBlank and blank or nil)
end

-- 诊断（找不到血条时写日志）：实例表里有什么、场景里所有 WB_BossHPBar_C 的 Character / 在不在屏幕上 / 可见性
-- 【适配】PBZHUDLayout:GetBossHPBarInstances()、FindAllOf("WB_BossHPBar_C")、UserWidget:IsInViewport / GetVisibility / GetOuter
local function bossBarDiag(actor)
    local lines = {}
    local function descBar(w)
        local c = rawProp(w, "Character")
        local okV, vis = pcall(function() return w:GetVisibility() end)
        local okI, inv = pcall(function() return w:IsInViewport() end)
        local okO, outer = pcall(function() return w:GetOuter() end)
        return string.format("%s | Character=%s%s | 可见性=%s | 在视口=%s | Outer=%s", short(pathOf(w)),
            valid(c) and short(pathOf(c)) or "空", valid(c) and (sameObj(c, actor) and "（=替身）" or "（不是替身）") or "",
            okV and tostring(vis) or "?", okI and tostring(inv) or "?", okO and valid(outer) and short(pathOf(outer)) or "?")
    end
    local hud = hudLayout()
    lines[#lines + 1] = "HUD = " .. (hud and short(pathOf(hud)) or "没有")
    if hud then
        local okA, bars = pcall(function() return hud:GetBossHPBarInstances() end)
        local n = 0
        if okA then eachArr(bars, function(_, b) if not valid(b) then pcall(function() b = b:get() end) end; n = n + 1; lines[#lines + 1] = "  实例表[" .. n .. "] " .. (valid(b) and descBar(b) or tostring(b)) end) end
        lines[#lines + 1] = string.format("  GetBossHPBarInstances：%s，%d 个（返回值类型 %s）", okA and "调用成功" or ("失败 " .. tostring(bars)), n, type(bars))
    end
    local all, n = FindAllOf("WB_BossHPBar_C"), 0
    for _, w in pairs(all or {}) do
        n = n + 1
        if valid(w) then lines[#lines + 1] = "  场景[" .. n .. "] " .. descBar(w) end
    end
    lines[#lines + 1] = string.format("  FindAllOf(WB_BossHPBar_C)：%d 个", n)
    return lines
end

-- 【适配】WB_BossHPBar_C:ForSeq_UpdateHealth / ForSeq_UpdateShachi(0~1)、ForSeq_SetNameText(FText)；字段 hp / sh / name，没给的不动
local function bossBarSet(bar, v)
    if not valid(bar) then return false end
    local ok = true
    if v.hp then ok = pcall(function() bar:ForSeq_UpdateHealth(v.hp) end) and ok end
    if v.sh then ok = pcall(function() bar:ForSeq_UpdateShachi(v.sh) end) and ok end
    if v.name then ok = pcall(function() bar:ForSeq_SetNameText(FText(v.name)) end) and ok end
    return ok
end

-- §113.1 探针（只反射、不调用）：游戏自己改属性的原生函数在哪个类、参数是什么。exe 里 ModifyCharacterAttributeValue 和
-- ModiferOp / Instant / GetCharacterAttributeValue / MakeAttributeModEffectSpec 挨着，原生组件用 GE_MA_%s_%d_%s（SetByCaller
-- AttributeOpMagnitude）改属性——走这条路 ASC 会广播属性变化，HUD 自己刷新（直接调 HUD 回调会崩，实测 4）
local ATTR_PROBE_FUNCS = { "ModifyCharacterAttributeValue", "MakeAttributeModEffectSpec", "GetAttributeModEffectName",
                           "GetCharacterAttributeValue", "GetAttributeFromCharacter", "MakeOutgoingSpec", "AssignSetByCallerMagnitude",
                           "BP_ApplyGameplayEffectSpecToSelf" }
local attrProbeDone = false
-- 只读；每个会话只跑一次，返回日志行
-- 【适配】FindObjects(Function, 名字) + UFunction:GetFullName / ForEachProperty + FProperty:HasAnyPropertyFlags / GetStruct / GetPropertyClass
local function attrModProbe()
    if attrProbeDone then return {} end
    attrProbeDone = true
    local lines = {}
    for _, fname in ipairs(ATTR_PROBE_FUNCS) do
        local ok, found = pcall(FindObjects, 4, "Function", fname, 0, 0, true)
        if not ok then lines[#lines + 1] = string.format("  %s：FindObjects 出错 %s", fname, tostring(found)); found = nil end
        local n = 0
        for _, f in pairs(found or {}) do
            if valid(f) then
                n = n + 1
                local full = "?"
                pcall(function() full = f:GetFullName() end)
                local ps = {}
                pcall(function()
                    f:ForEachProperty(function(p)
                        local nm, t, extra, flag = fnameStr(p:GetFName()), "?", "", ""
                        pcall(function() t = fnameStr(p:GetClass():GetFName()) end)
                        pcall(function() extra = "<" .. fnameStr(p:GetStruct():GetFName()) .. ">" end)
                        if extra == "" then pcall(function() extra = "<" .. fnameStr(p:GetPropertyClass():GetFName()) .. ">" end) end
                        pcall(function()
                            if p:HasAnyPropertyFlags(0x400) then flag = " ret" elseif p:HasAnyPropertyFlags(0x100) then flag = " out"
                            elseif not p:HasAnyPropertyFlags(0x80) then flag = " local" end
                        end)
                        ps[#ps + 1] = nm .. ":" .. t .. extra .. flag
                    end)
                end)
                lines[#lines + 1] = string.format("  %s (%s)", full, table.concat(ps, ", "))
            end
        end
        if n == 0 and ok then lines[#lines + 1] = "  " .. fname .. "：没找到" end
    end
    return lines
end

-- §113.1 用游戏自己的改属性函数写属性（实测 5 探针）：
--   /Script/SGameAttributes.AttributeUtils:ModifyCharacterAttributeValue(Character, Attribute:GameplayAttribute, ModiferOp:byte, Value:float)
-- 走 GE_MA_* + ASC，属性变化会广播，HUD（W_WeaponUI 的 WaitForAttributeChanged）自己刷新。
-- GameplayAttribute 结构体不在 Lua 里手搓（里面有 FieldPath）：从游戏自己的 GE_MA_<属性>_<1|0>_Override 的 Modifiers[1].Attribute
-- 读现成的；运算也读它的 ModifierOp（就是 Override），不猜枚举值
local ATTRMOD_DIR = "/PBZCombatAsset/Config/AttributesModifyEffect/"
local ATTRMOD_LIB = "/Script/SGameAttributes.Default__AttributeUtils"
local attrModCache = {}      -- 属性名 → { attr = 结构体, op = 运算, src = 路径 } / false（找不到）
-- 【适配】StaticFindObject / LoadAsset GE_MA_<属性>_<1|0>_Override（GameplayEffect 对象或蓝图类默认对象），读 Modifiers[1].Attribute / ModifierOp
local function attrModInfo(attr)
    if attrModCache[attr] ~= nil then return attrModCache[attr] end
    for _, k in ipairs({ "1", "0" }) do
        local nm = "GE_MA_" .. attr .. "_" .. k .. "_Override"
        local base = ATTRMOD_DIR .. nm
        for _, p in ipairs({ base .. "." .. nm, base .. ".Default__" .. nm .. "_C" }) do
            local o = StaticFindObject(p)
            if not valid(o) and type(LoadAsset) == "function" then
                pcall(LoadAsset, base .. "." .. nm)
                o = StaticFindObject(p)
            end
            if valid(o) then
                local info
                pcall(function()
                    local m = o.Modifiers[1]
                    info = { attr = m.Attribute, op = m.ModifierOp, src = p }
                    info.name = m.Attribute.AttributeName:ToString()
                end)
                if info and info.attr ~= nil and info.op ~= nil and (info.name == nil or info.name == attr) then
                    attrModCache[attr] = info
                    return info
                end
            end
        end
    end
    attrModCache[attr] = false
    return false
end
-- 返回 成功?, 说明。成功 = 调用没报错且读回来等于 value（误差 0.01）；失败时调用方自己退回 setAttr
-- 【适配】AttributeUtils 类默认对象:ModifyCharacterAttributeValue(角色, GE_MA 里的 GameplayAttribute, 它的 ModifierOp, value)
local function attrModSet(actor, attr, value)
    if not valid(actor) then return false, "没有角色" end
    local info = attrModInfo(attr)
    if not info then return false, "找不到 GE_MA_" .. attr .. "_*_Override" end
    local lib = StaticFindObject(ATTRMOD_LIB)
    if not valid(lib) then return false, "找不到 " .. ATTRMOD_LIB end
    local ok, err = pcall(function() lib:ModifyCharacterAttributeValue(actor, info.attr, info.op, value) end)
    if not ok then return false, "调用出错 " .. tostring(err) end
    local now = attrOf(actor, attr)
    if not (now and math.abs(now - value) < 0.01) then
        return false, string.format("调用了但值是 %s（要 %s；%s，op=%s）", tostring(now), tostring(value), info.src, tostring(info.op))
    end
    return true, string.format("%s，op=%s", info.src, tostring(info.op))
end

-- §144 标准数值模式用的三个游戏接口（tools/stat_probe 15:55 实测签名；这版 UE4SS 读不出参数标志，输出参数要占位）

-- 本机存档里某把武器 / 影之武装的等级（0 = 没有这把或读不到）。normal = true 主武器，false 影之武装
-- 【适配】FindFirstOf("PBZBackPackSubsystem"):GetWeaponLevel(WeaponID:Name, bIsNormalWeapon:Bool) → Int
local function weaponLevel(id, normal)
    local okS, sub = pcall(FindFirstOf, "PBZBackPackSubsystem")
    if not (okS and valid(sub)) then return nil, "找不到 PBZBackPackSubsystem" end
    local ok, r = pcall(function() return sub:GetWeaponLevel(FName(id), normal and true or false) end)
    if not ok then return nil, tostring(r) end
    return tonumber(r) or 0
end

-- 游戏自带的临时强制配装（11-07 18:1x 新档实测，HANDOVER §144）：只认背包里已有的主武器（没拿到的调用不报错但什么都不发生）；
-- 套上后等级 / 铸魂 / 升级解锁效果全由游戏处理，存档会带 ForcedLoadoutActive / OrigLevel 标记，读回后 Restore 照样还原
-- 【适配】FindFirstOf("PBZBackPackSubsystem"):ApplyForcedWeaponLoadout(WeaponID:Name, WeaponLevel:Int, bForceSnapSoul:Bool)
local function forcedApply(id, lv, snap)
    local okS, sub = pcall(FindFirstOf, "PBZBackPackSubsystem")
    if not (okS and valid(sub)) then return false, "找不到 PBZBackPackSubsystem" end
    local ok, r = pcall(function() return sub:ApplyForcedWeaponLoadout(FName(id), lv, snap and true or false) end)
    if not ok then return false, tostring(r) end
    return true
end
-- 【适配】PBZBackPackSubsystem:RestoreForcedWeaponLoadout()
local function forcedRestore()
    local okS, sub = pcall(FindFirstOf, "PBZBackPackSubsystem")
    if not (okS and valid(sub)) then return false, "找不到 PBZBackPackSubsystem" end
    local ok, r = pcall(function() return sub:RestoreForcedWeaponLoadout() end)
    if not ok then return false, tostring(r) end
    return true
end
-- 现在是不是在强制配装中；读不到 = nil
-- 【适配】PBZBackPackSubsystem:HasForcedWeaponLoadout() → Bool
local function forcedActive()
    local okS, sub = pcall(FindFirstOf, "PBZBackPackSubsystem")
    if not (okS and valid(sub)) then return nil end
    local ok, r = pcall(function() return sub:HasForcedWeaponLoadout() end)
    if ok and type(r) == "boolean" then return r end
    return nil
end
-- 这把铸魂过没有；读不到 = nil
-- 【适配】PBZBackPackSubsystem:IsWeaponSnapSouled(WeaponID:Name, IsNormalWeapon:Bool) → Bool
local function weaponSnapped(id, normal)
    local okS, sub = pcall(FindFirstOf, "PBZBackPackSubsystem")
    if not (okS and valid(sub)) then return nil end
    local ok, r = pcall(function() return sub:IsWeaponSnapSouled(FName(id), normal and true or false) end)
    if ok and type(r) == "boolean" then return r end
    return nil
end

-- §144 方案 B（11-07 20:27 二周目实测）：强制配装会把配装清空，用游戏的临时整套配装快照把武器组 / 影之武装装回去、逐格装回饰品；
-- 还原时先 Pop 快照、再 Restore 强制配装（游戏从 ForcedLoadout* 备份恢复原配装）

-- 返回的数组元素在这版 UE4SS 里是 RemoteUnrealParam：先 :get() 再 ToString
-- 【适配】RemoteUnrealParam:get() → FName:ToString()
local function nameOfElem(v)
    local x = v
    pcall(function() x = v:get() end)
    local ok, s = pcall(function() return x:ToString() end)
    if ok and type(s) == "string" then return s end
    return type(x) == "string" and x or nil
end
-- 当前配装的主武器 / 影之武装 ID 列表（读不到 = nil）
-- 【适配】PBZBackPackSubsystem:GetEquipmentNormalWeapons() / GetShaqiWeapons() → Array<Name>
local function loadoutLists()
    local okS, sub = pcall(FindFirstOf, "PBZBackPackSubsystem")
    if not (okS and valid(sub)) then return nil end
    local function read(fn)
        local ok, arr = pcall(function() return sub[fn](sub) end)
        if not ok then return nil end
        local t = {}
        eachArr(arr, function(_, v) local n = nameOfElem(v); if n and n ~= "None" then t[#t + 1] = n end end)
        return t
    end
    return read("GetEquipmentNormalWeapons"), read("GetShaqiWeapons")
end
-- 【适配】PBZBackPackSubsystem:PushEquippedWeapons(Array<Name>, Array<Name>, 主序号, 影武序号) / PopEquippedWeapons() / HasEquippedWeaponsSnapshot()
local function loadoutPush(mains, shaqis, mi, si)
    local okS, sub = pcall(FindFirstOf, "PBZBackPackSubsystem")
    if not (okS and valid(sub)) then return false, "找不到 PBZBackPackSubsystem" end
    local a, b = {}, {}
    for _, id in ipairs(mains) do a[#a + 1] = FName(id) end
    for _, id in ipairs(shaqis) do b[#b + 1] = FName(id) end
    local ok, r = pcall(function() return sub:PushEquippedWeapons(a, b, mi or 0, si or 0) end)
    if not ok then return false, tostring(r) end
    return true
end
-- 【适配】PBZBackPackSubsystem:PopEquippedWeapons()
local function loadoutPop()
    local okS, sub = pcall(FindFirstOf, "PBZBackPackSubsystem")
    if not (okS and valid(sub)) then return false, "找不到 PBZBackPackSubsystem" end
    local ok, r = pcall(function() return sub:PopEquippedWeapons() end)
    if not ok then return false, tostring(r) end
    return true
end
-- 【适配】PBZBackPackSubsystem:HasEquippedWeaponsSnapshot() → Bool；读不到 = nil
local function loadoutSnapshot()
    local okS, sub = pcall(FindFirstOf, "PBZBackPackSubsystem")
    if not (okS and valid(sub)) then return nil end
    local ok, r = pcall(function() return sub:HasEquippedWeaponsSnapshot() end)
    if ok and type(r) == "boolean" then return r end
    return nil
end
-- 这些饰品里装着的（按给的顺序）；装一件到第 idx 格
-- 【适配】PBZBackPackSubsystem:IsEquipAccessory(ID) → Bool / AssembleAccessory(ID, Index)
local function accEquipped(ids)
    local okS, sub = pcall(FindFirstOf, "PBZBackPackSubsystem")
    if not (okS and valid(sub)) then return nil end
    local t = {}
    for _, id in ipairs(ids) do
        local ok, on = pcall(function() return sub:IsEquipAccessory(FName(id)) end)
        if ok and on == true then t[#t + 1] = id end
    end
    return t
end
-- 【适配】PBZBackPackSubsystem:AssembleAccessory(AccessoryID:Name, Index:Int)
local function accAssemble(id, idx)
    local okS, sub = pcall(FindFirstOf, "PBZBackPackSubsystem")
    if not (okS and valid(sub)) then return false, "找不到 PBZBackPackSubsystem" end
    local ok, r = pcall(function() return sub:AssembleAccessory(FName(id), idx) end)
    if not ok then return false, tostring(r) end
    return true
end

-- §144 诊断（21:07 崩溃 = 反复强制配装撑爆 UObject 上限）：现在有多少 Actor / ActorComponent，看换套新建的武器对象会不会被回收。
-- FindAllOf 要遍历全部对象（几十毫秒），只在换套前后调
-- 【适配】FindAllOf("Actor") / FindAllOf("ActorComponent")
local function objCounts()
    local function n(cls)
        local ok, all = pcall(FindAllOf, cls)
        if not (ok and all) then return 0 end
        local k = 0
        for _ in pairs(all) do k = k + 1 end
        return k
    end
    return n("Actor"), n("ActorComponent")
end

-- 游戏自带的"否决存档"：on = true 进、false 出；同一个来源 ID 进出成对
-- 【适配】FindFirstOf("PBZSaveLoadSubsystem"):EnterSaveVeto(SourceID:Name, Reason:Enum) / ExitSaveVeto(SourceID:Name)
local function saveVeto(on, id)
    local okS, sub = pcall(FindFirstOf, "PBZSaveLoadSubsystem")
    if not (okS and valid(sub)) then return false, "找不到 PBZSaveLoadSubsystem" end
    local ok, r
    if on then ok, r = pcall(function() return sub:EnterSaveVeto(FName(id), 0) end)
    else ok, r = pcall(function() return sub:ExitSaveVeto(FName(id)) end) end
    if not ok then return false, tostring(r) end
    local st
    pcall(function() st = sub:GetManagerState() end)
    return true, "存档管理状态 " .. tostring(st)
end

-- 角色身上生效的 GameplayEffect 短名集合（"GE_Talent_EnableTenacity" = true）；读不到返回 nil
-- 【适配】ASC.ActiveGameplayEffects.GameplayEffects_Internal[i].Spec.Def（只读，同 LO.weaponEffects）
local function geSet(actor)
    local asc = ascOf(actor)
    local arr = asc and rawProp(rawProp(asc, "ActiveGameplayEffects"), "GameplayEffects_Internal")
    if arr == nil then return nil end
    local set = {}
    local ok = eachArr(arr, function(_, age)
        local def = rawProp(rawProp(age, "Spec"), "Def")
        if valid(def) then
            local n = pathOf(def):match("/([%w_]+)%.[^/]*$")
            if n then set[n] = true end
        end
    end)
    return ok and set or nil
end

-- §113 直接写属性（setAttr）不走 ASC，HUD 的 W_WeaponUI 靠 WaitForAttributeChanged 听属性变化，收不到 → 精纯杀气 / 暗源的显示不动。
-- 写完后按它自己的回调补一下：OnUltimateCharageCountChange / OnUltimateChargeChange（属性变化时它自己调的那两个，NewValue / OldValue），
-- 暗源那格叫 Bullet（BulletNum / BulletText / "Change Bullet"）。参数按反射到的名字填，认不出的参数就不调、只记日志
local WUI_CLASS = "/Game/PBZContent/UI/Hud/W_WeaponUI.W_WeaponUI_C"
local wuiSig, wuiLogged, wuiNArgs = {}, false, {}
-- 蓝图函数的 ForEachProperty 连局部变量一起列（13.1 实测：Temp_* / CallFunc_* / K2Node_*），参数排在最前。
-- 参数先认 CPF_Parm（0x80）标志；UE4SS 不给标志时，按"第一个局部变量名前缀之前的都是参数"
local WUI_LOCAL = { "^Temp_", "^CallFunc_", "^K2Node_" }
-- 返回 { {名字, 类型名, 是不是参数}, ... }，没有这个函数 = false
-- 【适配】StaticFindObject(W_WeaponUI_C:<函数>) + UFunction:ForEachProperty + FProperty:HasAnyPropertyFlags(CPF_Parm)
local function wuiSigOf(fname)
    if wuiSig[fname] ~= nil then return wuiSig[fname] end
    local f = StaticFindObject(WUI_CLASS .. ":" .. fname)
    if not valid(f) then wuiSig[fname] = false; return false end
    local sig, inLocals = {}, false
    pcall(function()
        f:ForEachProperty(function(p)
            local n, t = fnameStr(p:GetFName()), "?"
            pcall(function() t = fnameStr(p:GetClass():GetFName()) end)
            local okF, parm = pcall(function() return p:HasAnyPropertyFlags(0x80) end)
            if not (okF and type(parm) == "boolean") then
                for _, pat in ipairs(WUI_LOCAL) do if n:find(pat) then inLocals = true end end
                parm = not inLocals
            end
            sig[#sig + 1] = { n, t, parm }
        end)
    end)
    wuiSig[fname] = sig
    return sig
end
-- 【适配】按反射到的参数名从 args 里取值、按 FProperty 类型转换（Bool → 布尔，Int → 取整）；局部变量 / 返回值跳过；参数在 args 里找不到 → nil
local function wuiArgs(sig, args)
    local r = {}
    for _, p in ipairs(sig) do
        local n, t = p[1], p[2]
        if p[3] and n ~= "ReturnValue" then
            local v = args[n]
            if v == nil then return nil end
            if t == "BoolProperty" then v = v == true or (type(v) == "number" and v ~= 0)
            elseif t == "IntProperty" or t == "Int64Property" or t == "ByteProperty" then v = math.floor(v + 0.5) end
            r[#r + 1] = v
        end
    end
    return r
end
-- 【适配】签名里的参数部分（日志用）
local function wuiSigText(sig)
    if not sig then return "（没有这个函数）" end
    local a = {}
    for _, p in ipairs(sig) do if p[3] then a[#a + 1] = p[1] .. ":" .. p[2] end end
    return "(" .. table.concat(a, ", ") .. ")"
end
-- old / new = { cnt, chg, sp }（属性值，nil = 没变）；返回日志行（第一次带上各函数的参数和调用结果）
-- 13.1 实测签名：OnUltimateCharageCountChange(OldValue:int, NewValue:int, IsAddUltimateCharge:bool)、
--   OnUltimateChargeChange(NewValue:double, OldValue:double)、Change Bullet()
-- 【适配】FindAllOf("W_WeaponUI_C")（跳过 Default__ 类默认对象）+ 调它的蓝图函数刷新精纯杀气 / 暗源显示
local function weaponUiRefresh(old, new)
    local lines, calls = {}, {}
    local first = not wuiLogged
    wuiLogged = true
    -- 13.1 实测 4（15:37:55）：OnUltimateCharageCountChange 截成 2 个参数真调进去后游戏崩了（Fatal Error + crashdump），撤掉。
    -- 精纯杀气格数的显示另想办法（见 HANDOVER §113.1），别再直接调这个
    if new.chg then calls[#calls + 1] = { "OnUltimateChargeChange", { NewValue = new.chg, OldValue = old.chg or new.chg } } end
    if new.sp then calls[#calls + 1] = { "Change Bullet", {} } end
    local all, n = FindAllOf("W_WeaponUI_C"), 0
    for _, w in pairs(all or {}) do
        local isDefault = false
        pcall(function() isDefault = fnameStr(w:GetFName()):find("^Default__") ~= nil end)
        if valid(w) and not isDefault then
            n = n + 1
            for _, c in ipairs(calls) do
                local sig = wuiSigOf(c[1])
                local args = sig and wuiArgs(sig, c[2])
                if not sig then lines[#lines + 1] = "  " .. c[1] .. "：没有这个函数"
                elseif not args then lines[#lines + 1] = "  " .. c[1] .. wuiSigText(sig) .. "：参数认不出，没调"
                else
                    -- 13.1 实测 3：IsAddUltimateCharge 没有局部变量前缀、其实是局部变量，UE4SS 报"UFunction expected 2 parameters, received 3"。
                    -- 按它说的个数截掉后面的重试，记住个数（wuiNArgs），以后直接按这个数传
                    local k = wuiNArgs[c[1]]
                    if k and k < #args then for i = #args, k + 1, -1 do args[i] = nil end end
                    local ok, err = pcall(function() w[c[1]](w, table.unpack(args)) end)
                    local want = not ok and tonumber(tostring(err):match("expected (%d+) parameters"))
                    if want and want < #args then
                        wuiNArgs[c[1]] = want
                        for i = #args, want + 1, -1 do args[i] = nil end
                        ok, err = pcall(function() w[c[1]](w, table.unpack(args)) end)
                        if first then lines[#lines + 1] = string.format("  %s 实际只收 %d 个参数，截掉后重试", c[1], want) end
                    end
                    if not ok then lines[#lines + 1] = string.format("  %s%s 失败：%s", c[1], wuiSigText(sig), tostring(err))
                    elseif first then lines[#lines + 1] = string.format("  %s%s 已调（%d 个参数）", c[1], wuiSigText(sig), #args) end
                end
            end
        end
    end
    if n == 0 then lines[#lines + 1] = "  没找到 W_WeaponUI_C（HUD 没显示？）" end
    return lines
end

local shachiVisSaved = {}     -- 血条路径 → 藏之前的可见性（按路径记：同一个控件每次取到的 Lua 对象可能不是同一个）
-- v0.25.0 只显示血量时把杀气条藏起来；show = true 时恢复成藏之前的可见性。返回是否成功
-- 【适配】WB_BossHPBar_C.BreakmeterBar（杀气条控件）:GetVisibility / SetVisibility（ESlateVisibility：1 = Collapsed）
local function bossBarShachiShow(bar, show)
    if not valid(bar) then return false end
    local w = rawProp(bar, "BreakmeterBar")
    if not valid(w) then return false end
    local key = pathOf(bar)
    if show then
        local v = shachiVisSaved[key]
        if v == nil then return true end
        shachiVisSaved[key] = nil
        return (pcall(function() w:SetVisibility(v) end))
    end
    if shachiVisSaved[key] == nil then
        local okV, v = pcall(function() return w:GetVisibility() end)
        shachiVisSaved[key] = (okV and v ~= 1 and v) or 4      -- 4 = SelfHitTestInvisible
    end
    return (pcall(function() w:SetVisibility(1) end))
end

-- ============================================================ 切图：客机去主机所在的地图（v0.24.1，HANDOVER §69）
-- 走游戏敲钟传送那一套：PBZSaveLoadSubsystem:TeleportTo(关卡名, 落点, "") —— 游戏先自动存档、再加载目标关卡。
-- 只往地图表 DT_MapData 里列出的关卡传（关卡名来自网络，不在表里的一律不加载）。思路参考 Phantom Pact，代码自己写的

local MAP_TABLE = "/Game/PBZContent/DataTable/UI/DT_MapData.DT_MapData"
local MAP_SKIP = { [""] = true, None = true, Rhm_Test = true }   -- 表里有、但不是能正常玩的地图
local storyMaps = nil       -- 关卡名 → true；第一次用时从 DT_MapData 读（读不到下次再试）

-- 【适配】Default__DataTableFunctionLibrary:GetDataTableColumnAsString(DT_MapData, "LevelName") → 关卡名集合
local function storyMapSet()
    if storyMaps then return storyMaps end
    local tbl = StaticFindObject(MAP_TABLE)
    local lib = StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary")
    if not (valid(tbl) and valid(lib)) then return nil end
    local okC, col = pcall(function() return lib:GetDataTableColumnAsString(tbl, FName("LevelName")) end)
    if not okC or col == nil then return nil end
    local set, n, raw = {}, 0, {}
    eachArr(col, function(_, s)
        -- 09:01 实测原始值全是 "RemoteUnrealParam: 0000…"：返回的是 Lua 表、元素没解包（同 §68 的 Boss 血条），要 :get() 出 FString
        if type(s) ~= "string" then pcall(function() local g = s:get(); if g ~= nil then s = g end end) end
        local str = type(s) == "string" and s or fnameStr(s)
        if #raw < 20 then raw[#raw + 1] = str end
        -- 2026-11-05 实测：读到 15 条，可 PBZ_DengDingShanDao_WP（表里确实有）没认出来——导出的字符串带了引号 / 括号之类的外壳。
        -- 现在只取最后一个标识符（写成路径 /Game/Maps/X/PBZ_X.PBZ_X 时也是它），比较不分大小写
        local name = str:match("([%w_]+)[^%w_]*$")
        if name and not MAP_SKIP[name] then set[string.lower(name)], n = true, n + 1 end
    end)
    if n == 0 then return nil end
    out("地图表 DT_MapData：%d 张剧情地图；原始值：%s", n, table.concat(raw, " | "))
    storyMaps = set
    return set
end

-- 【适配】storyMapSet() 里有没有这个关卡名（地图表读不到 = 不认；不分大小写）
local function isStoryMap(level)
    if type(level) ~= "string" or MAP_SKIP[level] then return false end
    local set = storyMapSet()
    return set ~= nil and set[string.lower(level)] == true
end

-- 返回 true = 游戏接下了（之后会存档 + 加载，玩家角色会失效一阵）；不在地图表里 / 找不到子系统 / 调用报错 = false, 原因
-- 【适配】FindFirstOf("PBZSaveLoadSubsystem"):TeleportTo(FName(关卡), FTransform{ 朝向四元数, 落点 Z+lift }, FName(""))
local function travelTo(level, pos, yaw, lift)
    if not isStoryMap(level) then return false, "不在地图表 DT_MapData 里" end
    if not (pos and pos.X and pos.Y and pos.Z) then return false, "没有落点" end
    local sub = FindFirstOf("PBZSaveLoadSubsystem")
    if not valid(sub) then return false, "找不到 PBZSaveLoadSubsystem" end
    local half = math.rad(yaw or 0.0) / 2
    local xf = { Rotation = { X = 0.0, Y = 0.0, Z = math.sin(half), W = math.cos(half) },
                 Translation = { X = pos.X, Y = pos.Y, Z = pos.Z + (lift or 0.0) },
                 Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
    local ok, err = pcall(function() sub:TeleportTo(FName(level), xf, FName("")) end)
    if not ok then return false, "TeleportTo 报错：" .. tostring(err) end
    return true
end

-- 【适配】CharacterMovement：IsFalling()（拿不到看 MovementMode == 3 MOVE_Falling）、Velocity.Z、GetGravityZ()、JumpZVelocity（v0.24.2 空中同步）
local function airOf(actor)
    local cm = valid(actor) and rawProp(actor, "CharacterMovement") or nil
    if not valid(cm) then return nil end
    local s = { falling = false, vz = 0.0, g = 980.0, jumpZ = 700.0, mode = nil }
    pcall(function() s.mode = tonumber(cm.MovementMode) end)
    local okF, f = pcall(function() return cm:IsFalling() end)
    if okF and type(f) == "boolean" then s.falling = f else s.falling = s.mode == 3 end
    pcall(function() s.vz = tonumber(cm.Velocity.Z) or 0.0 end)
    pcall(function() local gz = tonumber(cm:GetGravityZ()); if gz and gz < -1 then s.g = -gz end end)
    pcall(function() local j = tonumber(cm.JumpZVelocity); if j and j > 1 then s.jumpZ = j end end)
    return s
end

-- §99 悬空：远处的地形还没加载出来（World Partition 按区域加载）时让角色不受重力停在原处，加载出来后再放回走路。
-- 【适配】CharacterMovement:SetMovementMode(5 MOVE_Flying / 1 MOVE_Walking, 0)，Velocity 清零
local function hover(actor, on)
    local cm = valid(actor) and rawProp(actor, "CharacterMovement") or nil
    if not valid(cm) then return false end
    local ok = pcall(function() cm:SetMovementMode(on and 5 or 1, 0) end)
    pcall(function() cm.Velocity = { X = 0.0, Y = 0.0, Z = 0.0 } end)
    return ok
end

-- §99 引擎处理掉出世界的角色（AActor::FellOutOfWorld）会把它藏起来、关碰撞；替身还在用，就重新显示。没被藏返回 false
-- 【适配】actor.bHidden、SetActorHiddenInGame(false)、SetActorEnableCollision(true)
local function unhide(actor)
    if not valid(actor) then return false end
    local h
    pcall(function() h = actor.bHidden end)
    if h ~= true then return false end
    pcall(function() actor:SetActorHiddenInGame(false) end)
    pcall(function() actor:SetActorEnableCollision(true) end)
    return true
end

-- 【适配】Character:LaunchCharacter(速度, XY 覆盖, Z 覆盖)：移动组件下一帧把速度换成它、切到下落（AI 控制的替身 Jump() 不起作用）
local function launch(actor, vel)
    if not valid(actor) then return false end
    return (pcall(function() actor:LaunchCharacter(vel, true, true) end))
end

-- v0.26.2 安全放置用（§79）：K2_SetActorLocation(…, sweep=false) 什么都不查，2026-11-05 11:50 用户被回合归位放进了墙里。
-- TeleportTo 会查落点会不会卡进几何体，卡了就在附近找空位，找不到返回 false。这个游戏里还没实测过：
-- 调用本身出错（不认这个函数 / 参数）时退回 K2_SetActorLocation，返回 true 和原因，日志里能看到
-- 【适配】actor:K2_TeleportTo(落点, {Pitch=0, Yaw=yaw, Roll=0}) → bool；出错退回 K2_SetActorLocation(落点, false, {}, true)
local function teleportTo(actor, pos, yaw)
    if not valid(actor) then return false end
    local ok, r = pcall(function() return actor:K2_TeleportTo(pos, { Pitch = 0.0, Yaw = yaw or 0.0, Roll = 0.0 }) end)
    if ok then return r == true end
    pcall(function() actor:K2_SetActorLocation(pos, false, {}, true) end)
    return true, "K2_TeleportTo 调用出错，退回直接设坐标：" .. tostring(r)
end

-- ============================================================ §92 蓄力招探针（只读，不改玩法）

-- 当前蒙太奇 + 段落名 + 位置；没有在播返回 nil。段落名读不到是 "?"
-- 【适配】AnimInstance:Montage_GetCurrentSection(蒙太奇) → FName
local function montageSection(actor)
    local an, mt, name, pos = activeMontage(actor)
    if not an then return nil end
    local ok, s = pcall(function() return an:Montage_GetCurrentSection(mt) end)
    return name, (ok and s ~= nil) and (fnameStr(s) or "?") or "?", pos
end

-- 技能清单里叫 name 的那一格的输入状态：{ id = InputID, pressed = InputPressed, active = ActiveCount }；找不到 nil。
-- 逐格查类名（和整遍重建一样贵，~10–40 ms），只在探针开头用、有次数上限
-- 【适配】ASC.ActivatableAbilities.Items[i].{Ability:GetClass(), InputID, InputPressed, ActiveCount}
local function specInput(actor, name)
    local asc = ascOf(actor)
    local items = asc and rawProp(rawProp(asc, "ActivatableAbilities"), "Items")
    if not items then return nil end
    local res
    eachArr(items, function(_, spec)
        if res then return end
        local ab = rawProp(spec, "Ability")
        if not valid(ab) then return end          -- v0.27.7 空对象不调 GetClass（§90）
        local okC, cls = pcall(function() return ab:GetClass() end)
        if okC and shortName(full(cls)) == name then
            res = { id = rawProp(spec, "InputID"), pressed = rawProp(spec, "InputPressed"), active = rawProp(spec, "ActiveCount") }
        end
    end)
    return res
end

-- 游戏自己的输入系统（PBZ.exe 字符串：/Script/SGameInputSystem 的 SGameInputComponent / SGameInputHandler / SGameInputUtils，
-- 资产里蓄力招用 GetSGameInputComponent → IsHolding、OnRelease / OnEarlyRelease / OnSuccessHold）和 GAS 的手动按键入口，
-- 只做反射和查找：类上的函数名（带参数名）、属性名；场上每个 SGameInputComponent 挂在谁身上；ASC 的几个函数在不在。
-- 一个游戏函数都不调用（不知道参数就盲调在 UE4SS 里崩过，§17 / §90）。返回若干行文字
local INPUT_CLASSES = { "/Script/SGameInputSystem.SGameInputComponent", "/Script/SGameInputSystem.SGameInputHandler",
                        "/Script/SGameInputSystem.SGameInputUtils" }
local ASC_FUNCS = { "PressInputID", "ReleaseInputID", "ServerSetInputPressed", "ServerSetInputReleased",
                    "AbilityLocalInputPressed", "AbilityLocalInputReleased", "ServerSetReplicatedEvent" }
-- 【适配】StaticFindObject(/Script/…) + UStruct:ForEachFunction / ForEachProperty（只取名字）+ FindAllOf("SGameInputComponent") + GetOwner
local function inputProbe(p1, pup)
    local lines = {}
    for _, path in ipairs(INPUT_CLASSES) do
        local cls = StaticFindObject(path)
        if not valid(cls) then lines[#lines + 1] = path .. "：找不到"
        else
            local fns, props = {}, {}
            pcall(function()
                cls:ForEachFunction(function(f)
                    local args = {}
                    pcall(function() f:ForEachProperty(function(p) args[#args + 1] = fnameStr(p:GetFName()) or "?" end) end)
                    fns[#fns + 1] = (fnameStr(f:GetFName()) or "?") .. "(" .. table.concat(args, ",") .. ")"
                end)
            end)
            pcall(function() cls:ForEachProperty(function(p) props[#props + 1] = fnameStr(p:GetFName()) or "?" end) end)
            lines[#lines + 1] = string.format("%s：函数 %d 个 %s；属性 %d 个 %s", path, #fns, table.concat(fns, " "), #props, table.concat(props, " "))
        end
    end
    local all = FindAllOf("SGameInputComponent")
    local own = {}
    for _, c in pairs(all or {}) do
        if valid(c) then
            local ok, o = pcall(function() return c:GetOwner() end)
            local who = not (ok and valid(o)) and "?" or sameObj(o, p1) and "玩家1" or sameObj(o, pup) and "替身"
                or sameObj(o, rawProp(p1, "Controller")) and "玩家1的控制器" or sameObj(o, rawProp(pup, "Controller")) and "替身的控制器"
                or short(pathOf(o))
            own[#own + 1] = who
        end
    end
    lines[#lines + 1] = string.format("SGameInputComponent 实例 %d 个：%s", #own, #own > 0 and table.concat(own, "，") or "无")
    local have = {}
    for _, f in ipairs(ASC_FUNCS) do
        have[#have + 1] = f .. "=" .. (valid(StaticFindObject("/Script/GameplayAbilities.AbilitySystemComponent:" .. f)) and "有" or "无")
    end
    lines[#lines + 1] = "ASC 函数：" .. table.concat(have, " ")
    return lines
end

-- §92 角色现在按着哪些输入：它自己和它控制器上的 SGameInputComponent 的 HoldingInputs（18:29 实测玩家1 和玩家1的控制器
-- 各有一个，替身没有）。只读属性，不调组件上的函数。返回 { 输入名 = true }；没有组件 / 读不到返回 nil, 原因。
-- 组件按角色缓存；找不到时 5 秒内不再 FindAllOf。容器类型不知道（TArray / TSet / TMap），ForEach 两个参数里取不是下标的那个
local HOLDC = {}
-- 【适配】FindAllOf("SGameInputComponent") + GetOwner 挑出角色 / 控制器的；读 HoldingInputs，ForEach 取元素（RemoteUnrealParam:get）的名字
local function holdingInputs(actor)
    if not valid(actor) then return nil, "没有角色" end
    local key = pathOf(actor)
    local c = HOLDC[key]
    local stale = not c or (c.comps and #c.comps > 0 and not valid(c.comps[1]))
    if stale or (#c.comps == 0 and os.clock() - c.at > 5.0) then
        local ctl = rawProp(actor, "Controller")
        c = { at = os.clock(), comps = {} }
        for _, x in pairs(FindAllOf("SGameInputComponent") or {}) do
            if valid(x) then
                local ok, o = pcall(function() return x:GetOwner() end)
                if ok and (sameObj(o, actor) or (valid(ctl) and sameObj(o, ctl))) then c.comps[#c.comps + 1] = x end
            end
        end
        HOLDC[key] = c
    end
    if #c.comps == 0 then return nil, "没有输入组件" end
    local names, read = {}, false
    local function add(o)
        if o == nil or type(o) == "number" then return end
        local okG, v = pcall(function() return o:get() end)
        if okG and v ~= nil then o = v end
        if valid(o) then names[shortName(full(o)) or "?"] = true end
    end
    for _, comp in ipairs(c.comps) do
        local h = rawProp(comp, "HoldingInputs")
        if h ~= nil and pcall(function() h:ForEach(function(a, b) if type(a) == "number" then add(b) else add(a) end end) end) then
            read = true
        end
    end
    if not read then return nil, "HoldingInputs 读不到 / 遍历失败" end
    return names
end

-- §140 输入状态同步第 1 步（只读探针）：蓄力招的"等松手"是 C++ 任务 UAbilityTask_WaitSInputHold（PBZ.exe 字符串：OnAlreadyRelease /
-- OnSuccessHold / OnEarlyRelease / OnSuccessRelease / RequiredTime，日志串"No InputAction available (CurrentInput=null, HoldInput=null)"）。
-- 替身走 OnAlreadyRelease。要让替身"按着"，先看清：任务上有哪些属性（输入从哪来）、玩家的输入组件里有什么（CurrentInput？）、
-- 组件有哪些函数。只反射 + 读，不调任何会改状态的函数
-- 一个值写成日志里的一小段：数字 / 布尔 / 字符串照写，对象写短路径，FName 写字符串，容器写元素个数和前几个
-- 【适配】UObject:IsValid / FName:ToString / TArray·TSet·TMap:ForEach（元素 :get()）
local function valStr(v)
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" or v == nil then return tostring(v) end
    if t ~= "userdata" then return t end
    if valid(v) then return short(pathOf(v)) end
    -- 容器（TArray / TSet / TMap）：ForEach 给 (下标, 元素) 或 (键, 值)；键值都写出来，值是结构体时列它的字段
    local function elemStr(x)
        local okG, g = pcall(function() return x:get() end)
        if okG and g ~= nil then x = g end
        if type(x) ~= "userdata" then return tostring(x) end
        if valid(x) then return shortName(full(x)) or "?" end
        local okS2, s2 = pcall(function() return x:ToString() end)
        if okS2 and type(s2) == "string" then return s2 end
        return "userdata"
    end
    local items, n = {}, 0
    local okE = pcall(function() v:ForEach(function(a, b)
        n = n + 1
        if n <= 4 then items[#items + 1] = (type(a) == "number" and "" or (elemStr(a) .. "→")) .. (b ~= nil and elemStr(b) or "") end
    end) end)
    if okE then return string.format("[%d 个%s]", n, n > 0 and (" " .. table.concat(items, ",")) or "") end
    local okS, sv = pcall(function() return v:ToString() end)
    if okS and type(sv) == "string" then return '"' .. sv .. '"' end
    return "userdata"
end

-- obj 类（含父类，最多 4 层）的全部属性 = 值，和带"pat"的函数（带参数名）
-- 【适配】UObject:GetClass / UStruct:ForEachProperty / ForEachFunction / GetSuperStruct + obj[属性名]
local function dumpObj(obj, fpat)
    local props, funcs = {}, {}
    local okC, c = pcall(function() return obj:GetClass() end)
    c = okC and c or nil
    for _ = 1, 4 do
        if not valid(c) then break end
        local cn = shortName(full(c)) or "?"
        pcall(function()
            c:ForEachProperty(function(pp)
                local n = fnameStr(pp:GetFName())
                props[#props + 1] = n .. "=" .. valStr(rawProp(obj, n))
            end)
        end)
        if fpat then
            pcall(function()
                c:ForEachFunction(function(f)
                    local n = fnameStr(f:GetFName())
                    if n:find(fpat) then
                        local ps = {}
                        pcall(function() f:ForEachProperty(function(q) ps[#ps + 1] = fnameStr(q:GetFName()) end) end)
                        funcs[#funcs + 1] = cn .. "." .. n .. "(" .. table.concat(ps, ",") .. ")"
                    end
                end)
            end)
        end
        local okS, sup = pcall(function() return c:GetSuperStruct() end)
        c = okS and sup or nil
    end
    return table.concat(props, " "), table.concat(funcs, " ")
end

-- 返回日志行。who 只用来标注；actor 的输入组件（GetSGameInputComponent）+ 场上所有 WaitSInputHold 任务
-- 【适配】Default__SGameInputUtils:GetSGameInputComponent + FindAllOf("AbilityTask_WaitSInputHold") + 反射读属性
local function holdTaskProbe(actor, who, withFuncs)
    local lines = {}
    local lib = StaticFindObject("/Script/SGameInputSystem.Default__SGameInputUtils")
    local ok, comp = pcall(function() return lib:GetSGameInputComponent(actor) end)
    if ok and valid(comp) then
        local pr, fn = dumpObj(comp, withFuncs and "." or nil)
        lines[#lines + 1] = string.format("%s 输入组件 %s 属性：%s", who, short(pathOf(comp)), pr)
        if withFuncs then lines[#lines + 1] = "输入组件函数：" .. fn end
    else
        lines[#lines + 1] = string.format("%s 没有输入组件（%s）", who, ok and "返回空" or tostring(comp))
    end
    -- 激光用的是 WaitSInputRelease（OnRelease / OnAlreadyRelease），另外两个顺带看
    for _, cls in ipairs({ "AbilityTask_WaitSInputRelease", "AbilityTask_WaitSInputHold", "AbilityTask_WaitSInputTrigger" }) do
        local tasks = FindAllOf(cls) or {}
        lines[#lines + 1] = string.format("场上 %s 任务 %d 个", cls, #tasks)
        local k = 0
        for _, t in pairs(tasks) do
            if valid(t) and k < 3 then
                k = k + 1
                local pr, fn = dumpObj(t, (withFuncs and k == 1) and "." or nil)
                lines[#lines + 1] = string.format("任务 %s 属性：%s", short(pathOf(t)), pr)
                if fn ~= "" then lines[#lines + 1] = "任务函数：" .. fn end
            end
        end
    end
    -- 角色身上的蓝图组件"Ability Input Component"（玩家激光技能的同名变量指向它，替身的是空）
    local aic = rawProp(actor, "Ability Input Component")
    if valid(aic) then
        local pr, fn = dumpObj(aic, withFuncs and "." or nil)
        lines[#lines + 1] = string.format("%s 角色的 Ability Input Component = %s（%s）属性：%s", who, short(pathOf(aic)),
            shortName(full(aic:GetClass())) or "?", pr)
        if withFuncs and fn ~= "" then lines[#lines + 1] = "Ability Input Component 函数：" .. fn end
    else
        lines[#lines + 1] = string.format("%s 角色的 Ability Input Component = %s", who, valStr(aic))
    end
    -- 激光技能实例：名字带 Input 的属性 / 函数（SInputAbilityInterface 给技能"我认哪个键"？）
    local asc = ascOf(actor)
    local items = asc and rawProp(rawProp(asc, "ActivatableAbilities"), "Items")
    eachArr(items, function(_, spec)
        local ab = rawProp(spec, "Ability")
        if not valid(ab) or not (shortName(full(ab:GetClass())) or ""):find("DuYan_Bow_Laser", 1, true) then return end
        local inst
        eachArr(rawProp(spec, "NonReplicatedInstances"), function(_, x) if valid(x) then inst = x end end)
        local o = inst or ab
        local list = {}
        pcall(function()
            local c = o:GetClass()
            for _ = 1, 6 do
                if not valid(c) then break end
                local cn = shortName(full(c)) or "?"
                c:ForEachProperty(function(pp)
                    local n = fnameStr(pp:GetFName())
                    if n:find("Input") then list[#list + 1] = cn .. "." .. n .. "=" .. valStr(rawProp(o, n)) end
                end)
                c:ForEachFunction(function(f)
                    local n = fnameStr(f:GetFName())
                    if n:find("Input") then list[#list + 1] = cn .. "." .. n .. "()" end
                end)
                c = c:GetSuperStruct()
            end
        end)
        lines[#lines + 1] = string.format("%s 激光技能（%s）带 Input 的：%s；InputID=%s", who, inst and "实例" or "CDO",
            #list > 0 and table.concat(list, " ") or "无", tostring(rawProp(spec, "InputID")))
    end)
    return lines
end

-- §140 第 2 步：给替身"按着键"。探针（02:16）：玩家的激光等松手任务 AbilityTask_WaitSInputRelease 属性 Input = IA_ShachiAbility_Hold、
-- InputComponent = 角色自己的 PawnInputComponent0（SGameInputComponent，玩家控制时引擎建的）；替身 GetSGameInputComponent 返回空
-- → 任务一开始就 OnAlreadyRelease。做法：替身没有就新建一个 SGameInputComponent 挂在它身上、写进 Pawn.InputComponent，
-- 再往它的 HoldingInputs（键 = InputAction 的表）里加 / 删键。只给实验名单里的招用
-- 【适配】Default__SGameInputUtils:GetSGameInputComponent + StaticConstructObject(SGameInputComponent, 角色) + Pawn.InputComponent
local function inputEnsure(actor)
    if not valid(actor) then return nil, "没有角色" end
    local lib = StaticFindObject("/Script/SGameInputSystem.Default__SGameInputUtils")
    if not valid(lib) then return nil, "找不到 SGameInputUtils" end
    local ok, c = pcall(function() return lib:GetSGameInputComponent(actor) end)
    if ok and valid(c) then return c, "已有" end
    local cls = StaticFindObject("/Script/SGameInputSystem.SGameInputComponent")
    if not valid(cls) then return nil, "找不到 SGameInputComponent 类" end
    local okN, comp = pcall(function() return StaticConstructObject(cls, actor, FName("PBZMP_SInput")) end)
    if not (okN and valid(comp)) then return nil, "建不出来 " .. tostring(comp) end
    local okA = pcall(function() comp.AbilitySystem = ascOf(actor) end)
    local okS = pcall(function() actor.InputComponent = comp end)
    local ok2, c2 = pcall(function() return lib:GetSGameInputComponent(actor) end)
    local got = (ok2 and valid(c2)) and (sameObj(c2, comp) and "就是新建的" or short(pathOf(c2))) or "还是空"
    -- 02:28 探针：玩家角色的 AbilityInputComponent（蓝图变量名 "Ability Input Component"）SGameInput = PawnInputComponent0，
    -- 替身的是空 → 一起接上
    local aic = rawProp(actor, "Ability Input Component")
    local okI = valid(aic) and pcall(function() aic.SGameInput = comp end)
    return comp, string.format("新建 %s（写 AbilitySystem %s、Pawn.InputComponent %s、AbilityInputComponent.SGameInput %s；GetSGameInputComponent → %s）",
        short(pathOf(comp)), okA and "成功" or "失败", okS and "成功" or "失败", okI and "成功" or "失败", got)
end

-- 现在的游戏世界时间（HoldingInputs 的值 = 按下那一刻的世界时间：02:28 玩家按着时 40.40，任务 StartTime 41.06）
-- 【适配】Default__GameplayStatics:GetTimeSeconds(角色)
local function worldTime(actor)
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local ok, t = pcall(function() return gs:GetTimeSeconds(actor) end)
    return (ok and type(t) == "number") and t or nil
end

-- 02:28 探针：玩家的激光技能实例变量 "Ability Input Component" = 角色的 AbilityInputComponent，替身的是空（技能是模组直接激活的，
-- 没经过输入组件），替身的等松手任务根本没建。把替身技能实例的这个变量接上角色自己的。返回说明
-- 【适配】ASC.ActivatableAbilities 找激活中的实例（LO.activeInstance）+ 实例["Ability Input Component"] 写
local function linkAbilityInput(actor, clsName)
    local inst = LO.activeInstance(actor, clsName)
    if not inst then return "技能实例没找到" end
    local aic = rawProp(actor, "Ability Input Component")
    if not valid(aic) then return "角色没有 Ability Input Component" end
    -- §140 实验 3（02:48）：玩家组件的 Controller = 玩家控制器，替身的是空 → 接上替身自己的 AI 控制器
    local ctlNote = ""
    if not valid(rawProp(aic, "Controller")) then
        local ctl = rawProp(actor, "Controller")
        local okC = valid(ctl) and pcall(function() aic.Controller = ctl end)
        ctlNote = string.format("；Controller 接 %s %s，读回 %s", valid(ctl) and short(pathOf(ctl)) or "（替身没控制器）",
            okC and "成功" or "失败", valid(rawProp(aic, "Controller")) and "有" or "空")
    end
    local before = rawProp(inst, "Ability Input Component")
    if valid(before) then return "已经有了" .. ctlNote end
    local ok, err = pcall(function() inst["Ability Input Component"] = aic end)
    local after = rawProp(inst, "Ability Input Component")
    return string.format("写 %s，读回 %s%s", ok and "成功" or ("失败 " .. tostring(err)), valid(after) and "有" or "空", ctlNote)
end

-- 按住 / 松开 iaPath（InputAction 资产路径）。值的类型不知道：按住时先试 value（数字），出错就记下错误。返回 说明, IsHolding 读回
-- 【适配】StaticFindObject(InputAction) + SGameInputComponent.HoldingInputs:Add / Remove + IsHolding(InputAction)
local function inputHold(comp, iaPath, on, value)
    if not valid(comp) then return "没有组件", nil end
    local ia = StaticFindObject(iaPath)
    if not valid(ia) then return "找不到 " .. iaPath, nil end
    local h = rawProp(comp, "HoldingInputs")
    if h == nil then return "读不到 HoldingInputs", nil end
    local ok, err
    if on then ok, err = pcall(function() h:Add(ia, value) end)
    else ok, err = pcall(function() h:Remove(ia) end) end
    local okH, isH = pcall(function() return comp:IsHolding(ia) end)
    return (on and "加键 " or "删键 ") .. (ok and "成功" or ("失败 " .. tostring(err))), okH and isH or ("IsHolding 出错 " .. tostring(isH))
end

-- 角色 HoldingInputs 里每一项的 键 / 值类型（玩家按着时看值是什么，替身加键时照着写）
-- 【适配】HoldingInputs:ForEach（键值 :get()）
local function inputHoldDump(actor)
    local lib = StaticFindObject("/Script/SGameInputSystem.Default__SGameInputUtils")
    local ok, c = pcall(function() return lib:GetSGameInputComponent(actor) end)
    if not (ok and valid(c)) then return "没有组件" end
    local h = rawProp(c, "HoldingInputs")
    local list = {}
    local okE, err = pcall(function() h:ForEach(function(a, b)
        local ka, kb = a, b
        pcall(function() ka = a:get() end)
        pcall(function() kb = b:get() end)
        list[#list + 1] = string.format("%s → %s（%s）", valid(ka) and (shortName(full(ka)) or "?") or tostring(ka), tostring(kb), type(kb))
    end) end)
    if not okE then return "遍历失败 " .. tostring(err) end
    return #list > 0 and table.concat(list, "；") or "空"
end

-- §92.8 暂停 / 继续角色当前的蒙太奇（替身"自己马上松手"的蓄力招：停在蓄力段，等对方松手再放）。返回 是否成功, 动作名
-- 【适配】AnimInstance:Montage_Pause(当前蒙太奇) / Montage_Resume(当前蒙太奇)
local function montagePause(actor, pause)
    local an, mt, name = activeMontage(actor)
    if not an then return false, nil end
    local ok = pcall(function() if pause then an:Montage_Pause(mt) else an:Montage_Resume(mt) end end)
    return ok, name
end

-- §92.8 诊断：游戏自己给这个角色找的是哪个输入组件（SGameInputUtils.GetSGameInputComponent，反射查到的签名 (Actor) → 组件），
-- 挂在角色本身 / 它的控制器 / 别处；外加 HoldingInputs 的容器样子（ForEach 第一个参数是下标 = 数组，否则 = 键值 / 集合）。
-- 想让替身"按着"之前要先知道这两样。只在诊断时调，有次数上限
-- 【适配】Default__SGameInputUtils:GetSGameInputComponent(角色) + GetOwner + HoldingInputs:ForEach
local function inputCompInfo(actor)
    if not valid(actor) then return "没有角色" end
    local lib = StaticFindObject("/Script/SGameInputSystem.Default__SGameInputUtils")
    if not valid(lib) then return "找不到 SGameInputUtils" end
    local ok, c = pcall(function() return lib:GetSGameInputComponent(actor) end)
    if not ok then return "调用出错 " .. tostring(c) end
    if not valid(c) then return "没有组件（返回空）" end
    local okO, o = pcall(function() return c:GetOwner() end)
    local who = not (okO and valid(o)) and "?" or sameObj(o, actor) and "角色本身"
        or sameObj(o, rawProp(actor, "Controller")) and "它的控制器" or short(pathOf(o))
    local kind, n = "读不到", 0
    local h = rawProp(c, "HoldingInputs")
    if h ~= nil then
        pcall(function() h:ForEach(function(a) n = n + 1; kind = type(a) == "number" and "数组" or "键值 / 集合" end) end)
        if n == 0 then kind = "空" end
    end
    return string.format("组件挂在%s，HoldingInputs %s（%d 个）", who, kind, n)
end

-- §92 技能实例上的一个字段（诊断用，只读）：替身技能清单里类名是 clsName 的那一格，先看实例（NonReplicated / Replicated），
-- 没有实例看 Ability（CDO）。返回 值, 来源；没有这个技能返回 nil, "没有这个技能"
-- 【适配】ASC.ActivatableAbilities.Items[i].{Ability:GetClass(), NonReplicatedInstances, ReplicatedInstances}[字段]
local function abilityField(actor, clsName, field)
    local asc = ascOf(actor)
    local items = asc and rawProp(rawProp(asc, "ActivatableAbilities"), "Items")
    if not items then return nil, "没有 ASC" end
    local v, from = nil, "没有这个技能"
    eachArr(items, function(_, spec)
        if from ~= "没有这个技能" then return end
        local ab = rawProp(spec, "Ability")
        if not valid(ab) then return end          -- v0.27.7 空对象不调 GetClass（§90）
        local okC, cls = pcall(function() return ab:GetClass() end)
        if not (okC and shortName(full(cls)) == clsName) then return end
        from = "CDO"
        for _, key in ipairs({ "NonReplicatedInstances", "ReplicatedInstances" }) do
            eachArr(rawProp(spec, key), function(_, inst)
                if from == "CDO" and valid(inst) then v, from = rawProp(inst, field), "实例" end
            end)
        end
        if from == "CDO" then v = rawProp(ab, field) end
    end)
    return v, from
end

-- ============================================================ 导出

-- ============================================================ §87 全部可格挡：格挡探针用

-- GetOwnedGameplayTags 实测拿不到（§14），只能拿已知的标签名逐个问。父标签也算命中。
-- 探针只在"格挡中掉血"那一刻调、最多 20 次（15:32 崩溃后不再每帧调）
-- 【适配】ASC:HasMatchingGameplayTag({TagName=FName(标签)}) 逐个查 → 命中的标签名数组；没有 ASC → nil
local function tagsMatching(actor, list)
    local asc = ascOf(actor)
    if not valid(asc) then return nil end
    local hit = {}
    for _, t in ipairs(list) do
        local ok, h = pcall(function() return asc:HasMatchingGameplayTag({ TagName = FName(t) }) end)
        if ok and h == true then hit[#hit + 1] = t end
    end
    return hit
end

return {
    tagsMatching = tagsMatching,
    montageSection = montageSection, specInput = specInput, inputProbe = inputProbe, holdingInputs = holdingInputs, abilityField = abilityField, montagePause = montagePause, inputCompInfo = inputCompInfo, holdTaskProbe = holdTaskProbe, inputEnsure = inputEnsure, worldTime = worldTime, linkAbilityInput = linkAbilityInput, inputHold = inputHold, inputHoldDump = inputHoldDump,
    teleportTo = teleportTo, laserBeamSpawn = laserBeamSpawn, aimComps = aimComps, destroyComps = destroyComps, rotateComps = rotateComps, setControlRot = setControlRot, compRotStr = compRotStr, bulletSubsysProbe = bulletSubsysProbe, findObj = findObj, countBullets = countBullets, bulletScan = bulletScan, bulletWhere = bulletWhere,
    laserEmitterSpawn = laserEmitterSpawn, emitterInfo = emitterInfo, moveEmitter = moveEmitter, destroyActor = destroyActor,
    full = full, pathOf = pathOf, valid = valid, try = try, rawProp = rawProp, shortName = shortName,
    short = short, sameObj = sameObj, fnameStr = fnameStr, eachArr = eachArr, getP1PC = getP1PC, getP1 = getP1,
    puppet = puppet, gstat = gstat, now = now, attrSetOf = attrSetOf, attrOf = attrOf, hpOf = hpOf,
    rootMotionScale = rootMotionScale,
    setAttr = setAttr, ascOf = ascOf, factionComp = factionComp, factionActors = factionActors, factionValue = factionValue, factionName = factionName, anyToStr = anyToStr,
    montageOf = montageOf, montageByName = montageByName, playOn = playOn, tagNames = tagNames, tagsOf = tagsOf, activeAbilities = activeAbilities, cancelMoves = cancelMoves, cancelAbilities = cancelAbilities,
    yawTo = yawTo, setYaw = setYaw, facePlayer = facePlayer, placeInFront = placeInFront, setBraking = setBraking, equipWeapon = equipWeapon,
    mapName = mapName, retract = retract, cutMontage = cutMontage, lockingTarget = lockingTarget, setLockTarget = setLockTarget, yawOf = yawOf, stateComp = stateComp, abilitiesOf = abilitiesOf, tagReport = tagReport, geLockHealthClass = geLockHealthClass,
    noStealthByGE = noStealthByGE, animOf = animOf, standUp = standUp, healClass = healClass, refill = refill, backpack = backpack,
    lockSelf = lockSelf, unlockSelf = unlockSelf, copyStats = copyStats, puppetDead = puppetDead, removePuppet = removePuppet, createPuppet = createPuppet,
    findMonster = findMonster, TAG_WAYS = TAG_WAYS, NO_STEALTH_TAGS = NO_STEALTH_TAGS, GE_CANDIDATES = GE_CANDIDATES, HEAL_GES = HEAL_GES, COPY_ATTRS = COPY_ATTRS,
    montages = montages, isStoryMap = isStoryMap, travelTo = travelTo, airOf = airOf, launch = launch, hover = hover, unhide = unhide,
    activeMontage = activeMontage, montageSetPos = montageSetPos, montageNotifies = montageNotifies, attrAll = attrAll,
    bossBarShow = bossBarShow, bossBarHide = bossBarHide, bossBarOf = bossBarOf, bossBarSet = bossBarSet, bossBarDiag = bossBarDiag,
    bossBarShachiShow = bossBarShachiShow, weaponUiRefresh = weaponUiRefresh, attrModProbe = attrModProbe, attrModSet = attrModSet, attrDiff = attrDiff,
    weaponLevel = weaponLevel, saveVeto = saveVeto, geSet = geSet,
    forcedApply = forcedApply, forcedRestore = forcedRestore, forcedActive = forcedActive, weaponSnapped = weaponSnapped,
    loadoutLists = loadoutLists, loadoutPush = loadoutPush, loadoutPop = loadoutPop, loadoutSnapshot = loadoutSnapshot,
    accEquipped = accEquipped, accAssemble = accAssemble, objCounts = objCounts,
    LO = LO,
}
end
