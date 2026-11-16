-- base_probe.lua —— 从 main.lua 搬出来的 M0：状态 / dump / 实验（docs/MAIN_SLIM.md）。原来在 main.lua 的 "-- ============================================================ M0：状态 / dump / 实验" 那段
return function(ctx)
local out, ST, VERSION, G = ctx.out, ctx.ST, ctx.VERSION, ctx.G
local full, pathOf, valid, rawProp, shortName, short, sameObj = G.full, G.pathOf, G.valid, G.rawProp, G.shortName, G.short, G.sameObj
local eachArr, getP1PC, getP1, puppet, attrSetOf = G.eachArr, G.getP1PC, G.getP1, G.puppet, G.attrSetOf
local ascOf, factionComp, factionValue, anyToStr = G.ascOf, G.factionComp, G.factionValue, G.anyToStr
-- main.lua 主循环那段会把 out / hpOf / attrOf / factionName / montageOf 换成计时包装（PROF.wrap），这几个由 ctx 传"调用时再取"的包装，
-- 和搬出来之前一样走计时（docs/MAIN_SLIM.md 规矩 3）
local attrOf, hpOf, factionName, montageOf = ctx.attrOf, ctx.hpOf, ctx.factionName, ctx.montageOf

local function relationProbe(fromActor, toActor, label)
    local fc1, fc2 = factionComp(fromActor), factionComp(toActor)
    if not (valid(fc1) and valid(fc2)) then out("  关系[%s]: 阵营组件缺失", label); return end
    local v2 = factionValue(toActor)
    local tries = {
        { "GetFactionRelation(对方组件)", function() return fc1:GetFactionRelation(fc2) end },
        { "GetFactionRelation(对方角色)", function() return fc1:GetFactionRelation(toActor) end },
        { "GetFactionRelationWithTag(对方阵营)", function() return fc1:GetFactionRelationWithTag(v2) end },
    }
    for _, t in ipairs(tries) do
        local ok, r = pcall(t[2])
        if ok then out("  关系[%s] %s = %s", label, t[1], anyToStr(r))
        else out("  关系[%s] %s 失败: %s", label, t[1], tostring(r)) end
    end
end

local function status()
    out("========== 状态 v%s ==========", VERSION)
    local pc, p1, pup = getP1PC(), getP1(), puppet()
    out("玩家1 控制器: %s", short(pathOf(pc)))
    out("玩家1 角色  : %s", short(pathOf(p1)))
    out("替身控制器  : %s", short(pathOf(ST.secondPC)))
    out("替身角色    : %s", short(pathOf(pup)))
    local n = 0
    local pcs = FindAllOf("PlayerController")
    if pcs then for _ in pairs(pcs) do n = n + 1 end end
    out("PlayerController 总数: %d", n)
    for _, e in ipairs({ { "玩家1", p1 }, { "替身", pup }, { "对照怪", ST.testMonster } }) do
        if valid(e[2]) then
            local c, b = hpOf(e[2])
            out("[%s] 血量 %s/%s  阵营 %s  动画 %s", e[1], tostring(c), tostring(b),
                factionName(e[2]), montageOf(e[2]))
        end
    end
    if valid(p1) and valid(pup) then
        relationProbe(p1, pup, "玩家1→替身")
        relationProbe(pup, p1, "替身→玩家1")
    end
    out("接下来 10 秒做血量稳定性追踪，请站着别动")
    ST.hpTrace, ST.hpTraceSeen = 10, nil
end

local function dumpFnParams(path)
    local fn = StaticFindObject(path)
    if not valid(fn) then out("  %s: 找不到", path); return end
    local ps = {}
    pcall(function()
        fn:ForEachProperty(function(p)
            local n = "?"
            local c = "?"
            pcall(function() n = p:GetFName():ToString() end)
            pcall(function() c = p:GetClass():GetFName():ToString() end)
            ps[#ps + 1] = n .. ":" .. c
        end)
    end)
    out("  %s(%s)", shortName(path:gsub(":", ".")) or path, table.concat(ps, ", "))
end

local function dumpAttrs(actor, label)
    local set = attrSetOf(actor)
    if not valid(set) then out("[%s] 没有属性集", label); return end
    local cls = set:GetClass()
    local parts = {}
    local c = cls
    for _ = 1, 4 do
        if not valid(c) then break end
        pcall(function()
            c:ForEachProperty(function(p)
                local n = "?"
                pcall(function() n = p:GetFName():ToString() end)
                local cur = attrOf(actor, n)
                if cur ~= nil then parts[#parts + 1] = string.format("%s=%.1f", n, cur) end
            end)
        end)
        local okS, sup = pcall(function() return c:GetSuperStruct() end)
        c = okS and sup or nil
    end
    out("[%s] 属性 %s: %s", label, short(pathOf(set)), table.concat(parts, "  "))
end

-- ============================================================ 武器系统探针（只读）
-- v0.6.3 找到了入口（Character Weapons Component / Add Weapon And SwitchTo / Switch Weapon Func ...），
-- 这一步只打印函数签名和读当前值，不调用任何会改状态的函数；按签名写换武器是下一版的事

local function fnameOrStr(v)
    if type(v) == "userdata" then
        local ok, s = pcall(function() return v:ToString() end)
        if ok and s then return tostring(s) end
        if valid(v) then return short(pathOf(v)) end
    end
    return anyToStr(v)
end

-- v0.6.4 崩溃（crash_2026_11_03_18_48_58，UE4SS.dll+0x2be3a7 读 0xff010019）：
-- 对任意属性盲调 GetPropertyClass/GetStruct/GetEnum/GetInner，类型不对时 UE4SS 把无关字段当指针读，pcall 拦不住。
-- 现在先看类型名，只对确定类型调用对应方法
local function propType(p)
    local c = "?"
    pcall(function() c = p:GetClass():GetFName():ToString() end)
    local extra = nil
    if c == "ObjectProperty" or c == "ClassProperty" then
        pcall(function() extra = p:GetPropertyClass():GetFName():ToString() end)
    elseif c == "StructProperty" then
        pcall(function() extra = p:GetStruct():GetFName():ToString() end)
    end
    c = c:gsub("Property$", "")
    return extra and (c .. "<" .. extra .. ">") or c
end

-- 返回 { {name, type, out=bool, ret=bool}, ... }
local function signature(fn)
    local ps = {}
    pcall(function()
        fn:ForEachProperty(function(p)
            local n = "?"
            pcall(function() n = p:GetFName():ToString() end)
            -- 不调 HasAnyPropertyFlags（同样有读错字段的风险）；蓝图函数的局部变量也会出现在这里，
            -- 名字形如 CallFunc_* / K2Node_* / Temp_*，标成 local
            local isRet = n == "ReturnValue"
            local isLocal = n:match("^CallFunc_") or n:match("^K2Node_") or n:match("^Temp_") or n:match("^Local")
            ps[#ps + 1] = { name = n, type = propType(p), ret = isRet, loc = isLocal and true or false }
        end)
    end)
    return ps
end

local function sigStr(ps)
    local s = {}
    for _, p in ipairs(ps) do
        if not p.loc then s[#s + 1] = (p.ret and "→" or "") .. p.name .. ":" .. p.type end
    end
    return table.concat(s, ", ")
end

local function printValue(prefix, v)
    if type(v) == "userdata" and not valid(v) then
        local items = {}
        local okA = eachArr(v, function(i, e) items[#items + 1] = fnameOrStr(e) end)
        if okA and #items > 0 then out("%s = [%s]", prefix, table.concat(items, ", ")); return end
        local kv = {}
        pcall(function()
            v:ForEach(function(k, x)
                local kk, xx = k, x
                pcall(function() kk = k:get() end)
                pcall(function() xx = x:get() end)
                kv[#kv + 1] = fnameOrStr(kk) .. "=>" .. fnameOrStr(xx)
            end)
        end)
        if #kv > 0 then out("%s = {%s}", prefix, table.concat(kv, ", ")); return end
    end
    out("%s = %s", prefix, fnameOrStr(v))
end

local WEAPON_KW = { "Weapon", "Equip", "Armed", "Inventory", "Loadout", "Sheath" }
local function weaponWord(name)
    for _, k in ipairs(WEAPON_KW) do if name:find(k) then return true end end
    return false
end

-- 遍历对象类链上的属性和函数；filter=nil 表示全部
local function walkClass(obj, filter, maxProps, maxFns, label)
    local okC, c = pcall(function() return obj:GetClass() end)
    c = okC and c or nil
    local np, nf = 0, 0
    for _ = 1, 10 do
        if not valid(c) then break end
        local cname = shortName(full(c)) or "?"
        if cname == "Actor" or cname == "Object" or cname == "Pawn" then break end
        pcall(function()
            c:ForEachProperty(function(p)
                local n = "?"
                pcall(function() n = p:GetFName():ToString() end)
                if (not filter or filter(n)) and np < maxProps then
                    np = np + 1
                    local t = propType(p)
                    local base = t:match("^(%w+)")
                    local prefix = string.format("  %s 属性 %s.%s:%s", label, cname, n, t)
                    -- 只读确定安全的类型；Map/Set/委托/接口等只报类型
                    if ({ Int = 1, Int64 = 1, Float = 1, Double = 1, Bool = 1, Byte = 1, Enum = 1, Name = 1,
                          Str = 1, Object = 1, Class = 1, Array = 1 })[base] then
                        printValue(prefix, rawProp(obj, n))
                    elseif t == "Struct<GameplayTag>" then
                        -- GameplayTag 只有一个 TagName 字段，按简单结构体读（同 HasMatchingGameplayTag 的参数类型）
                        local v = rawProp(obj, n)
                        local okT, tn = pcall(function() return v.TagName:ToString() end)
                        out("%s = %s", prefix, okT and tostring(tn) or "?")
                    else
                        out("%s（不读值）", prefix)
                    end
                end
            end)
        end)
        pcall(function()
            c:ForEachFunction(function(f)
                local n = "?"
                pcall(function() n = f:GetFName():ToString() end)
                if (not filter or filter(n)) and nf < maxFns then
                    nf = nf + 1
                    local sig = signature(f)
                    out("  %s 函数 %s:%s(%s)", label, cname, n, sigStr(sig))
                    -- 只调用"参数表里只有一个 ReturnValue"的 Get/Is 函数（v0.6.4 实测这类调用安全）
                    if #sig == 1 and sig[1].ret and (n:sub(1, 3) == "Get" or n:sub(1, 2) == "Is") then
                        local ok, r = pcall(function() return obj[n](obj) end)
                        if ok then printValue("      调用结果", r) else out("      调用失败: %s", tostring(r)) end
                    end
                end
            end)
        end)
        local okS, sup = pcall(function() return c:GetSuperStruct() end)
        c = okS and sup or nil
    end
    out("  %s 共 %d 属性 / %d 函数", label, np, nf)
end

local function weaponProbe()
    out("========== 武器探针 ==========")
    local p1, pup = getP1(), puppet()
    for _, e in ipairs({ { "玩家1", p1 }, { "替身", pup } }) do
        local a = e[2]
        if valid(a) then
            out("[%s] CurrentWeaponID=%s CurrentWeapon=%s CurrentWeapon_ShaQi=%s HasUnsheathedWeapon=%s",
                e[1], fnameOrStr(rawProp(a, "CurrentWeaponID")), tostring(rawProp(a, "CurrentWeapon")),
                tostring(rawProp(a, "CurrentWeapon_ShaQi")), tostring(rawProp(a, "HasUnsheathedWeapon")))
            printValue(string.format("[%s] WeaponEquipInfos", e[1]), rawProp(a, "WeaponEquipInfos"))
            walkClass(a, weaponWord, 40, 60, "[" .. e[1] .. "]")
            local comp = rawProp(a, "Character Weapons Component")
            out("[%s] 武器组件 %s", e[1], full(comp))
            if valid(comp) then walkClass(comp, nil, 60, 80, "[" .. e[1] .. " 组件]") end
        end
    end
    out("========== 武器探针结束 ==========")
end

-- ============================================================ 锁定探针（F2，只读）
-- 用户反馈：锁定替身后镜头对着一片空地（像场地中央）。读出锁定系统记录的目标和坐标，与替身的实际位置对照
local LOCK_KW = { "Lock", "Target", "Focus", "Aim", "Soft", "Enemy" }

local function locOf(o)
    if not valid(o) then return nil end
    local ok, v = pcall(function() return o:K2_GetActorLocation() end)
    if not (ok and v) then ok, v = pcall(function() return o:K2_GetComponentLocation() end) end
    if ok and v and v.X then return v end
    return nil
end

local function vecStr(v) return v and string.format("(%.0f, %.0f, %.0f)", v.X, v.Y, v.Z) or "?" end

local function lockWalk(obj, label, refs)
    local okC, c = pcall(function() return obj:GetClass() end)
    c = okC and c or nil
    local np, nf = 0, 0
    for _ = 1, 10 do
        if not valid(c) then break end
        local cname = shortName(full(c)) or "?"
        if cname == "Actor" or cname == "Object" or cname == "Pawn" or cname == "ActorComponent" then break end
        pcall(function()
            c:ForEachProperty(function(p)
                local n = "?"
                pcall(function() n = p:GetFName():ToString() end)
                local hit = false
                for _, k in ipairs(LOCK_KW) do if n:find(k) then hit = true; break end end
                if not hit or np >= 60 then return end
                np = np + 1
                local t = propType(p)
                local base = t:match("^(%w+)")
                local s
                if t == "Struct<Vector>" then
                    local v = rawProp(obj, n)
                    local okV, sv = pcall(function() return vecStr(v) end)
                    s = okV and sv or "?"
                elseif base == "Object" then
                    local v = rawProp(obj, n)
                    s = valid(v) and (short(pathOf(v)) .. " @ " .. vecStr(locOf(v))) or "（空）"
                    if valid(v) then refs[#refs + 1] = { label .. "." .. n, v } end
                elseif ({ Int = 1, Float = 1, Double = 1, Bool = 1, Byte = 1, Enum = 1, Name = 1 })[base] then
                    s = fnameOrStr(rawProp(obj, n))
                else
                    s = "（不读值）"
                end
                out("  [%s] %s.%s:%s = %s", label, cname, n, t, s)
            end)
        end)
        pcall(function()
            c:ForEachFunction(function(f)
                local n = "?"
                pcall(function() n = f:GetFName():ToString() end)
                local hit = false
                for _, k in ipairs(LOCK_KW) do if n:find(k) then hit = true; break end end
                if not hit or nf >= 40 then return end
                nf = nf + 1
                local sig = signature(f)
                local line = string.format("  [%s] %s:%s(%s)", label, cname, n, sigStr(sig))
                if #sig == 1 and sig[1].ret and (n:sub(1, 3) == "Get" or n:sub(1, 2) == "Is") then
                    local ok, r = pcall(function() return obj[n](obj) end)
                    if ok then
                        if type(r) == "userdata" and valid(r) then
                            line = line .. " → " .. short(pathOf(r)) .. " @ " .. vecStr(locOf(r))
                            refs[#refs + 1] = { label .. ":" .. n .. "()", r }
                        else
                            local okV, sv = pcall(function() return vecStr(r) end)
                            line = line .. " → " .. ((okV and r and r.X) and sv or fnameOrStr(r))
                        end
                    end
                end
                out("%s", line)
            end)
        end)
        local okS, sup = pcall(function() return c:GetSuperStruct() end)
        c = okS and sup or nil
    end
    out("  [%s] 锁定相关：属性 %d / 函数 %d", label, np, nf)
end

local function lockProbe()
    out("========== 锁定探针 ==========")
    local p1, pc, pup = getP1(), getP1PC(), puppet()
    out("玩家1 @ %s   替身 @ %s   替身控制器 @ %s", vecStr(locOf(p1)), vecStr(locOf(pup)), vecStr(locOf(ST.secondPC)))
    local starts = FindAllOf("PlayerStart")
    if starts then
        for _, s in pairs(starts) do if valid(s) then out("  出生点 %s @ %s", short(pathOf(s)), vecStr(locOf(s))) end end
    end
    local refs = {}
    local cam = rawProp(p1, "NBCamera")
    local pcm = rawProp(pc, "PlayerCameraManager")
    for _, e in ipairs({ { "玩家1", p1 }, { "玩家1控制器", pc }, { "镜头组件", cam }, { "镜头管理器", pcm } }) do
        if valid(e[2]) then out("-- %s %s", e[1], short(pathOf(e[2]))); lockWalk(e[2], e[1], refs) end
    end
    -- 锁定系统指向的对象，逐个和替身 / 替身控制器 / 出生点比对
    out("-- 引用对照（离替身多远）")
    local pl = locOf(pup)
    for _, r in ipairs(refs) do
        local l = locOf(r[2])
        local d = (l and pl) and math.sqrt((l.X - pl.X) ^ 2 + (l.Y - pl.Y) ^ 2) or -1
        out("  %s → %s  是替身=%s 是替身控制器=%s 离替身 %.0f", r[1], short(pathOf(r[2])),
            tostring(sameObj(r[2], pup)), tostring(sameObj(r[2], ST.secondPC)), d)
    end
    out("========== 锁定探针结束 ==========")
end

-- ============================================================ 处决探针 + 禁止处决标签实验（F2）
-- v0.9.12 实测：暗杀动作开始后再中断太晚 —— 用户反馈仍会瞬移过去、替身掉武器、有暗杀音效。
-- 资产数据：GA_Hun_SEx_M_02（父类 PBZ_StealthExecutionAbilityBase）激活即做 LGAAction_ExecutionWarping + InstantWarp（瞬移）、
-- 播 SFX_Combat_Special_Execute_Dagger（音效）；GA_Hun_SEd_M_02 里有 GAA_DropWeapon_C（掉武器）。
-- 要在"能否暗杀"的判定上让替身不合格。判定走 Execution Component；两边技能都检查 CharacterState.Forbid.Ability.Focusing.Execution
local EXEC_KW = { "Sneak", "Stealth", "Aware", "Alert", "Assassin", "Execut", "Perception", "Detect", "Notice" }

local function execComponentOf(actor)
    local c = rawProp(actor, "Execution Component")
    if valid(c) then return c, "属性 Execution Component" end
    local ok, r = pcall(function() return actor:GetExecutionComponent() end)
    if ok and valid(r) then return r, "GetExecutionComponent()" end
    return nil, "没找到"
end



-- 注销替身作为"被执行目标"注册的动作。返回成功调用的次数
local function unregisterPuppetExecAnims(pup, why)
    local comp = valid(pup) and execComponentOf(pup) or nil
    if not valid(comp) then out("!! 替身没有处决组件（%s）", why); return 0 end
    local keys = {}
    local function addKey(label, o) if valid(o) then keys[#keys + 1] = { label, o } end end
    addKey("组件.ActorConfig", rawProp(comp, "ActorConfig"))
    local okA, ac = pcall(function() return pup:GetExecutionActorConfig() end)
    if okA then addKey("GetExecutionActorConfig()", ac) end
    addKey("替身自身", pup)
    addKey("替身 ASC", ascOf(pup))
    addKey("替身武器组件", rawProp(pup, "Character Weapons Component"))
    local n = 0
    for _, k in ipairs(keys) do
        local ok, err = pcall(function() comp:UnregisterExecutionAnims(k[2]) end)
        if ok then n = n + 1 end
        out("  替身 UnregisterExecutionAnims(%s = %s)：%s", k[1], short(pathOf(k[2])), ok and "调用成功" or ("失败 " .. tostring(err)))
    end
    out("替身注销可被执行动作（%s）：%d/%d 次调用成功", why, n, #keys)
    return n
end

local function execProbe()
    out("========== 处决探针 ==========")
    local p1, pup = getP1(), puppet()
    -- 组件探针 v0.9.13 已经拿到完整数据（见 HANDOVER §19.20），每次游戏只跑一次，之后按 F2 只切换标签
    for _, e in ipairs({}) do   -- 处决组件探针 v0.9.13 已拿到完整数据（HANDOVER §19.20），不再重复
        if valid(e[2]) then
            local comp, how = execComponentOf(e[2])
            out("[%s] 处决组件：%s（%s）", e[1], comp and short(pathOf(comp)) or "<无>", how)
            if comp then walkClass(comp, nil, 60, 60, e[1] .. " 处决组件") end
            walkClass(e[2], function(n)
                for _, k in ipairs(EXEC_KW) do if n:find(k) then return true end end
                return false
            end, 40, 40, e[1])
        end
    end
    ST.execProbed = true
    -- 标签路线放弃：v0.9.13 Lua 拼容器崩（crash_21_24_21）；v0.9.14 用 MakeGameplayTagContainerFromTag 生成，
    -- 但 UE4SS 把返回的结构体转成了 Lua table（日志 "table: 00000003D2FACE80"），传回去同样崩（crash_21_27_39）。
    -- 改为：在替身自己的处决组件上 UnregisterExecutionAnims(SourceKey) —— 注销它作为目标注册的"可被执行动作"（含被暗杀 SEd），
    -- 执行方就挑不出能对它用的处决。参数只有一个对象。SourceKey 不确定，几个候选都试，没注册过的 key 应该无效果
    -- v0.9.15 实测：UnregisterExecutionAnims 5 个候选都调用成功，但暗杀照样触发 —— 可被暗杀的资格不由这些注册决定。
    -- 资产数据：暗杀 = Execution.Type.Stealth（ActorConfig_Hun）；条件在全局配置 PDA_GlobalConfig_Combined 的
    -- "Execution Conditions Map"，配置里还有 "Combat State Tag" / GetCharacterCombatStateTag / "Sneaking Tag"。
    -- 推测：目标没进战斗状态才能被暗杀；替身没有 AI，永远不进战斗。读全局配置和双方的角色状态组件（只读）
    local wc = rawProp(p1, "Character Weapons Component")
    local gc = valid(wc) and rawProp(wc, "GlobalConfig") or nil
    out("-- 全局配置 %s", gc and short(pathOf(gc)) or "<没拿到>")
    if valid(gc) then
        walkClass(gc, function(n)
            for _, k in ipairs({ "Combat", "Execut", "Sneak", "Stealth", "Condition", "State", "Aware" }) do
                if n:find(k) then return true end
            end
            return false
        end, 60, 60, "全局配置")
    end
    for _, e in ipairs({ { "玩家1", p1 }, { "替身", pup } }) do
        local sc = valid(e[2]) and rawProp(e[2], "Actor State Component") or nil
        out("-- %s 角色状态组件 %s", e[1], valid(sc) and short(pathOf(sc)) or "<没拿到>")
        if valid(sc) then walkClass(sc, nil, 60, 60, e[1] .. " 状态组件") end
    end
    out("========== 处决探针结束 ==========")
end

-- F2（v0.9.18）：读处决条件表，找暗杀（Execution.Type.Stealth）的真实条件。
-- 带"输出参数"的函数：传一个空 table 让 UE4SS 填回来；返回 Map/Array 的读取有崩溃风险，所以每步之前先写日志
-- v0.9.18 实测：Map / Array 的元素是 UE4SS 的 RemoteUnrealParam / LocalUnrealParam 包装，要 :get() 才拿到值
local function unwrap(x)
    if type(x) == "userdata" then
        local ok, v = pcall(function() return x:get() end)
        if ok and v ~= nil then return v end
    end
    return x
end

-- 把一个值描述成字符串：对象给路径，GameplayTag 给名字，FName 给字符串；结构体试几个常见字段

-- v0.9.19 实测：结构体值（ExecutionConditions、GameplayTag）的 GetFullName 返回的是"ScriptStruct /Script/…"类型名，
-- 不是值。先读 TagName；结构体则用 StaticFindObject 拿到结构体定义，逐个字段读值
local function structFields(v)
    local f = full(v)
    local path = f:match("^ScriptStruct (.+)$")
    if not path then return nil end
    local st = StaticFindObject(path)
    if not valid(st) then return nil end
    local fields = {}
    pcall(function()
        st:ForEachProperty(function(p)
            local n = "?"
            pcall(function() n = p:GetFName():ToString() end)
            fields[#fields + 1] = { name = n, type = propType(p) }
        end)
    end)
    return fields, path
end

local function describe(v, depth)
    depth = depth or 0
    v = unwrap(v)
    if type(v) ~= "userdata" then return fnameOrStr(v) end
    local tn = rawProp(v, "TagName")
    if tn ~= nil then
        local okT, s = pcall(function() return tn:ToString() end)
        if okT and s then return tostring(s) end
    end
    local fields, spath = structFields(v)
    if fields then
        if depth >= 3 then return "<" .. (shortName(spath) or spath) .. ">" end
        local parts = {}
        for _, fd in ipairs(fields) do
            local base = fd.type:match("^(%w+)")
            local fv = rawProp(v, fd.name)
            local s
            if base == "Map" or base == "Set" or base:find("Delegate") or base == "Interface"
                or base == "WeakObject" or base == "SoftObject" or base == "SoftClass" or base == "LazyObject" then
                s = "（" .. fd.type .. "，不读值）"
            elseif base == "Array" then
                local items = {}
                eachArr(fv, function(_, e) if #items < 12 then items[#items + 1] = describe(e, depth + 1) end end)
                s = "[" .. table.concat(items, ", ") .. "]"
            else
                s = describe(fv, depth + 1)
            end
            parts[#parts + 1] = fd.name .. "=" .. s
        end
        return "<" .. (shortName(spath) or spath) .. "> {" .. table.concat(parts, "; ") .. "}"
    end
    if valid(v) then return short(pathOf(v)) end
    local okS, s = pcall(function() return v:ToString() end)
    if okS and s then return tostring(s) end
    return tostring(v)
end

local function dumpAny(prefix, v, depth)
    depth = depth or 0
    if depth > 3 then out("%s …", prefix); return end
    if type(v) == "table" then
        local n = 0
        for k, x in pairs(v) do
            n = n + 1
            if n > 40 then out("%s …（更多省略）", prefix); break end
            if type(x) == "table" then dumpAny(prefix .. "." .. describe(k), x, depth + 1)
            else out("%s[%s] = %s", prefix, describe(k), describe(x)) end
        end
        if n == 0 then out("%s = {}", prefix) end
    else
        out("%s = %s", prefix, describe(v))
    end
end

-- 外面用到的经 PROBE 表拿（这一段的其余函数只在段内用）
return {
    relationProbe = relationProbe,
    status = status,
    dumpFnParams = dumpFnParams,
    dumpAttrs = dumpAttrs,
    fnameOrStr = fnameOrStr,
    propType = propType,
    signature = signature,
    sigStr = sigStr,
    walkClass = walkClass,
    weaponProbe = weaponProbe,
    dumpAny = dumpAny,
}
end
