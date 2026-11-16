-- base_diag.lua —— 从 main.lua 搬出来的 §223.8 鬼魅闪身诊断 + §229 红光反击 / 鬼魅闪身（docs/MAIN_SLIM.md）。原来在 main.lua 的 "-- ===… §223.8 鬼魅闪身诊断（只读）" 那段
return function(ctx)
local ST, NET_DIR, G = ctx.ST, ctx.NET_DIR, ctx.G
local valid, rawProp, shortName, full, short, pathOf = G.valid, G.rawProp, G.shortName, G.full, G.short, G.pathOf
local eachArr, sameObj, ascOf, getP1, puppet, yawOf = G.eachArr, G.sameObj, G.ascOf, G.getP1, G.puppet, G.yawOf
local facePlayer, playOn, now = G.facePlayer, G.playOn, G.now
local isAttackAbility, playNamed = ctx.isAttackAbility, ctx.playNamed
-- main.lua 主循环那段会把 out / hpOf / montageOf 换成计时包装（PROF.wrap），这几个由 ctx 传"调用时再取"的包装，
-- 和搬出来之前一样走计时（docs/MAIN_SLIM.md 规矩 3）
local out, hpOf, montageOf = ctx.out, ctx.hpOf, ctx.montageOf

-- ============================================================ §223.8 鬼魅闪身诊断（只读）
-- 11-11 00:36 实测：玩家自己放鬼魅闪身 32 / 32 成功，替身（同武器、同升级、本来就在锁定状态）16 / 16 放不出。
-- 剩下的怀疑：①要按键 / 方向输入 ②技能是模组 K2_GiveAbility 补的、没有来源武器 ③身上缺某个标签。
-- 两边各记前 MAX 次：身上全部标签、这个技能那一格的来源对象 / 等级 / InputID、移动输入、锁定目标；替身放不出时按对方闪避的方向
-- （dg= 的 AM_Hun_*_Dodge_L/R/F/B，没有就往后）喂一下摇杆再放一次。全局（主代码块 local 已满）
local JDIAG = { NAME = "GA_Hun_AdvancedDash_Double_Jade_C", MAX = 6, meN = 0, pupN = 0, fedOk = 0, fedFail = 0 }

-- 这个技能在 actor 技能表里那一格：来源对象、等级、InputID
function JDIAG.spec(actor)
    local asc = ascOf(actor)
    if not valid(asc) then return "没有 ASC" end
    local res = "技能表里没有这个技能"
    eachArr(rawProp(rawProp(asc, "ActivatableAbilities"), "Items"), function(_, spec)
        local ab = rawProp(spec, "Ability")
        local okC, cls = false, nil
        if valid(ab) then okC, cls = pcall(function() return ab:GetClass() end) end
        if okC and shortName(full(cls)) == JDIAG.NAME then
            -- §229 SourceObject 是弱指针（TWeakObjectPtr）：rawProp 拿到的是指针本身，要 :Get() 才是对象（11-11 01:09 第一版全记成"无"）
            local src, so = rawProp(spec, "SourceObject"), nil
            if src ~= nil then
                local okG, o = pcall(function() return src:Get() end)
                if okG and valid(o) then so = o elseif valid(src) then so = src end
            end
            res = string.format("来源 %s / 等级 %s / InputID %s / 在放 %s", so and short(pathOf(so)) or "无",
                tostring(rawProp(spec, "Level")), tostring(rawProp(spec, "InputID")), tostring(rawProp(spec, "ActiveCount")))
        end
    end)
    return res
end

-- §229 这版 UE4SS 读不到"身上全部标签"（GetOwnedGameplayTags 一直 0 个，§14；11-11 01:09 第一版因此全是"标签 0 个"）。
-- 改成按名单逐个问 HasMatchingGameplayTag：名单 = 鬼魅闪身技能 GA_Hun_AdvancedDash_Double_Jade 和它的基类 BP_PlayerDodge_Base
-- 名字表里出现的全部状态标签（11-11 离线读游戏包）
JDIAG.TAGS = { "CharacterState.Armed", "CharacterState.Native.Focusing", "CharacterState.WeaponUpgrade.Jade.Afterimage",
               "CharacterState.WeaponUpgrade.Jade.EnableDA", "Targeting.Target.Combat", "CharacterState.InCombat",
               "CharacterState.AbilityState.Dash.4WayDash", "CharacterState.AbilityState.Dash.Cooldown",
               "CharacterState.AbilityState.Dash.Forbid", "CharacterState.AbilityState.Dash.InDashEscape",
               "CharacterState.AbilityState.Dash.EvadedDamage", "CharacterState.Action.Phase", "CharacterState.Action.Phase.Cancel",
               "CharacterState.Action.Phase.Combo", "CharacterState.Camera.HasWeakFocusTarget", "CharacterState.Hitreact.Phase",
               "CharacterState.Hitreact.Phase.Cancel", "CharacterState.Hitreact.Phase.Combo", "CharacterState.Hitreact.Phase.DashEscape",
               "CharacterState.Locomotion.SportMode.Active", "CharacterState.Native.Direction.Strafe",
               "CharacterState.AbilityState.HorseCart.Player.InCombat", "CharacterState.StatusInfliction.Ignite",
               "Deflect.ReadyForDodge.CanDodge", "Deflect.ReadyForDodge.Dodging" }

-- 移动输入：冲刺技能读的是 LocomotionDriverComponent:GetCurrentMoveInputWorldSpace（基类名字表），不是 Pawn 的 LastMovementInput
-- （第一版读后者，两边都是 0）。三样都记：驱动组件的、移动组件 GetLastInputVector、速度
function JDIAG.input(actor)
    local parts = {}
    local function jdV2(v) return v and string.format("(%.2f, %.2f)", v.X or 0, v.Y or 0) or "?" end
    local okL, ld = pcall(function() return actor:GetLocomotionDriverComponent() end)
    if not (okL and valid(ld)) then ld = rawProp(actor, "LocomotionDriverComponent") end
    if valid(ld) then
        local ok, v = pcall(function() return ld:GetCurrentMoveInputWorldSpace() end)
        parts[#parts + 1] = "驱动组件 " .. (ok and type(v) ~= "nil" and jdV2(v) or "读不到")
    else
        parts[#parts + 1] = "驱动组件 无"
    end
    local cm = rawProp(actor, "CharacterMovement")
    if valid(cm) then
        local ok, v = pcall(function() return cm:GetLastInputVector() end)
        parts[#parts + 1] = "移动组件 " .. (ok and jdV2(v) or "?")
        local okV, vel = pcall(function() return cm.Velocity end)
        parts[#parts + 1] = "速度 " .. (okV and jdV2(vel) or "?")
    end
    return table.concat(parts, " / ")
end

function JDIAG.state(actor)
    local t = G.tagsMatching and G.tagsMatching(actor, JDIAG.TAGS)
    local tags = t and (#t > 0 and table.concat(t, " ") or "名单里的都没有") or "没有 ASC"
    local okLk, lk = pcall(function() return G.lockingTarget and G.lockingTarget(actor) end)
    return string.format("技能格：%s；移动输入 %s；锁定目标 %s；有的标签（名单 %d 个）：%s", JDIAG.spec(actor), JDIAG.input(actor),
        okLk and valid(lk) and short(pathOf(lk)) or "无", #JDIAG.TAGS, tags)
end

function JDIAG.me(actor)
    if JDIAG.meN >= JDIAG.MAX then return end
    JDIAG.meN = JDIAG.meN + 1
    out("鬼魅闪身诊断 · 玩家放出来了（第 %d 次）：%s", JDIAG.meN, JDIAG.state(actor))
end

-- 替身放不出：记状态，喂方向，再放一次。返回 true = 喂了方向后放出来了
function JDIAG.pupFail(pup, retry)
    local first = JDIAG.pupN < JDIAG.MAX
    if first then
        JDIAG.pupN = JDIAG.pupN + 1
        out("鬼魅闪身诊断 · 替身放不出（第 %d 次）：%s", JDIAG.pupN, JDIAG.state(pup))
    end
    local dge = ctx.dge and ctx.dge() or DGE
    local m = dge and dge.want and dge.want.m or ""
    local side = m:match("_Dodge_([FBLR])") or "B"
    local yaw = yawOf(pup) or 0.0
    local off = ({ F = 0, R = 90, B = 180, L = -90 })[side]
    local r = math.rad(yaw + off)
    local dir = { X = math.cos(r), Y = math.sin(r), Z = 0.0 }
    pcall(function() pup:AddMovementInput(dir, 1.0, true) end)
    local cm = rawProp(pup, "CharacterMovement")
    if valid(cm) then pcall(function() cm.Velocity = { X = dir.X * 600.0, Y = dir.Y * 600.0, Z = 0.0 } end) end
    local ok = retry()
    if ok then JDIAG.fedOk = JDIAG.fedOk + 1 else JDIAG.fedFail = JDIAG.fedFail + 1 end
    if first or (JDIAG.fedOk + JDIAG.fedFail) % 20 == 0 then
        out("鬼魅闪身诊断 · 按对方闪避方向 %s（%s）喂摇杆再放：%s（累计 成 %d / 不成 %d）", side, m ~= "" and m or "没收到 dg=，按往后",
            ok and "放出来了" or "还是放不出", JDIAG.fedOk, JDIAG.fedFail)
    end
    return ok
end

-- ============================================================ §229 替身放不出红光反击 / 鬼魅闪身：换玩家那条路再放
-- 用户 11-11："修"（完美闪避反击 HANDOVER §189 里记着"没修"）。11-11 离线读游戏包名字表：
--   玩家自己出红光的路 = 常驻被动 BP_PerfectDodgePassive 等到"闪避帧"事件后，调 AbilityInputComponent 的
--   TryActivateExternalActionAbilityInterruptLowerByTag(Ability.Action.Hun.PerfectDodge)；反击基类 BP_PlayerPerfectDodge_Base 的
--   K2_CanActivateAbility 用 DeflectComponent:GetNearestValidReceivedFrame 查"收到过的闪避帧"（攻击方子弹命中前发来的）。
--   模组一直用 ASC:TryActivateAbilityByClass 放（全部返回 false），唯一成功的一次（11-10 20:41:42 白影 PerfectDodge）是替身
--   刚被我打中——那时它身上正好有我的子弹发来的帧。
-- 所以这版：①ASC 放不出时改走输入组件（按类 TryActivateExternalActionAbilityByClass；红光再按标签 …InterruptLowerByTag，
-- 和游戏被动一模一样）；②每次记替身 DeflectComponent 里收到的帧数、我当时在放的动作；③第一次把三个组件相关函数的参数名记下来
-- （参数不对时下一版照着改）。鬼魅闪身也走①（它是 BP_PlayerDodge_Base 子类，玩家也是经输入组件放的）。全局（主代码块 local 已满）
local XACT = { PD_TAG = "Ability.Action.Hun.PerfectDodge", LOGS = 30, logs = 0, probed = false, n = 0, okCls = 0, okTag = 0, fail = 0 }

-- 探针（11-11 01:41）：三个都是 (技能类或标签, InputAction, ActionPriority)，第一版只传了一个参数 → 全"出错"。
-- InputAction 传 nil（被动自己调的时候也没有按键）；ActionPriority 是整数，取大值让它能打断替身手上的低优先级动作
XACT.PRIO = 100
function XACT.err(e)
    local t = tostring(e):gsub("^.-main%.lua:%d+:%s*", "")
    return t:sub(1, 240)
end

function XACT.want(use)
    return use:match("^GA_Hun_.*PerfectDodge") ~= nil or use == (JDIAG and JDIAG.NAME)
end

-- 组件：先调角色的 Get…Component（接口函数），不行读同名属性
function XACT.comp(actor, getter, prop)
    local ok, c = pcall(function() return actor[getter](actor) end)
    if ok and valid(c) then return c end
    local v = rawProp(actor, prop)
    if valid(v) then return v end
    return nil
end

-- 组件类（含父类，最多 4 层）里名字匹配 pat 的函数和参数名
function XACT.sig(comp, pat)
    if not valid(comp) then return "（没有组件）" end
    local res, seen = {}, {}
    local okC, c = pcall(function() return comp:GetClass() end)
    c = okC and c or nil
    for _ = 1, 4 do
        if not valid(c) then break end
        pcall(function()
            c:ForEachFunction(function(f)
                local n = full(f):match(":([%w_ ]+)$") or "?"
                if n:find(pat) and not seen[n] then
                    seen[n] = true
                    local ps = {}
                    pcall(function() f:ForEachProperty(function(pp)
                        local pn = "?"
                        pcall(function() pn = pp:GetFName():ToString() end)
                        ps[#ps + 1] = pn
                    end) end)
                    res[#res + 1] = n .. "(" .. table.concat(ps, ", ") .. ")"
                end
            end)
        end)
        local okS, sup = pcall(function() return c:GetSuperStruct() end)
        c = okS and sup or nil
    end
    return #res > 0 and table.concat(res, "  ") or "（没找到 " .. pat .. "）"
end

-- 替身 DeflectComponent 里收到的闪避帧（ReceiveFrames 是 map）：个数；读不到返回说明
function XACT.frames(pup)
    local dc = XACT.comp(pup, "GetDeflectComponent", "DeflectComponent")
    if not dc then return "没有 DeflectComponent" end
    local m = rawProp(dc, "ReceiveFrames")
    if m == nil then return "读不到 ReceiveFrames" end
    local n = 0
    local ok = pcall(function() m:ForEach(function() n = n + 1 end) end)
    return ok and tostring(n) or "ReceiveFrames 数不了"
end

-- §229 01:41 实测替身 25 次放红光 / 鬼魅闪身时"收到的闪避帧"全是 0，连我正在砍它（Jade AAA）那次也是 0。
-- 查是"替身从来收不到帧"还是"帧在对方的红光到之前就过期了"：我每出一个攻击招，接下来几次刷新都数一下替身的帧
XACT.SAMPLE, XACT.sampleN, XACT.samples, XACT.nonzero, XACT.sampleLogs = 8, 0, 0, 0, 0
function XACT.onMine(add)
    for _, t in ipairs(add) do
        if isAttackAbility(t) then XACT.sampleN = XACT.SAMPLE; XACT.sampleAb = t end
    end
    if XACT.sampleN <= 0 then return end
    XACT.sampleN = XACT.sampleN - 1
    local pup = puppet()
    if not valid(pup) then return end
    local f = XACT.frames(pup)
    XACT.samples = XACT.samples + 1
    local n = tonumber(f)
    if n and n > 0 then
        XACT.nonzero = XACT.nonzero + 1
        if XACT.sampleLogs < 20 then
            XACT.sampleLogs = XACT.sampleLogs + 1
            out("红光 · 我出 %s 时替身收到闪避帧 %d 个（累计 %d / %d 次有帧）", tostring(XACT.sampleAb), n, XACT.nonzero, XACT.samples)
            if XACT.sampleLogs <= 3 then
                local okD, d = pcall(XACT.frameDump, pup)
                out("红光 · 帧内容：%s", okD and d or ("出错 " .. XACT.err(d)))
            end
        end
    elseif XACT.samples % 100 == 0 or (not n and XACT.samples <= 3) then
        out("红光 · 我出攻击时数替身闪避帧：%s（累计 %d / %d 次有帧）", f, XACT.nonzero, XACT.samples)
    end
end

-- §229.2 闪避帧里写了什么（只读）：ReceiveFrames 是 map，值的结构体字段名从属性反射里取（取一次缓存），逐个读出来。
-- 用来看替身有帧却放不出红光时，帧是不是过期了 / 不是闪避帧 / 没有反击技能。返回一行文字
XACT.FRAME_TAGS = { "Deflect.ReadyForDodge.CanDodge", "Deflect.ReadyForDodge.Dodging", "CharacterState.AbilityState.Dash.EvadedDamage" }
function XACT.fieldNames(dc)
    if XACT.fnames then return XACT.fnames end
    local names = {}
    local okC, c = pcall(function() return dc:GetClass() end)
    c = okC and c or nil
    for _ = 1, 4 do
        if not valid(c) or #names > 0 then break end
        pcall(function()
            c:ForEachProperty(function(pp)
                local pn = ""
                pcall(function() pn = pp:GetFName():ToString() end)
                if pn == "ReceiveFrames" then
                    pcall(function()
                        pp:GetValueProp():GetStruct():ForEachProperty(function(f)
                            pcall(function() names[#names + 1] = f:GetFName():ToString() end)
                        end)
                    end)
                end
            end)
        end)
        local okS, sup = pcall(function() return c:GetSuperStruct() end)
        c = okS and sup or nil
    end
    XACT.fnames = names
    return names
end

function XACT.val(v)
    local t = type(v)
    if t == "number" then return string.format("%.3f", v):gsub("%.?0+$", "") end
    if t == "boolean" or t == "string" then return tostring(v) end
    if t == "nil" then return "nil" end
    local okN, nm = pcall(function() return v:ToString() end)
    if okN and type(nm) == "string" then return nm end
    local okT, tn = pcall(function() return v.TagName end)
    if okT and tn ~= nil then local okS, sname = pcall(function() return tn:ToString() end); if okS then return sname end end
    if valid(v) then return short(pathOf(v)) end
    return "?"
end

function XACT.frameDump(pup)
    local dc = XACT.comp(pup, "GetDeflectComponent", "DeflectComponent")
    if not dc then return "没有 DeflectComponent" end
    local m = rawProp(dc, "ReceiveFrames")
    if m == nil then return "读不到 ReceiveFrames" end
    local names = XACT.fieldNames(dc)
    local parts = {}
    pcall(function()
        m:ForEach(function(k, v)
            local okV, fr = pcall(function() return v:get() end)
            if not okV then fr = v end
            local fs = {}
            for _, f in ipairs(names) do
                local okF, x = pcall(function() return fr[f] end)
                fs[#fs + 1] = f .. "=" .. (okF and XACT.val(x) or "?")
            end
            parts[#parts + 1] = "{" .. (#fs > 0 and table.concat(fs, " ") or "字段名读不到") .. "}"
        end)
    end)
    local t = G.tagsMatching(pup, XACT.FRAME_TAGS)
    return string.format("帧 %d 个 %s；替身闪避标签 %s", #parts, table.concat(parts, " "),
        t and (#t > 0 and table.concat(t, " ") or "无") or "?")
end

function XACT.probe(pup)
    if XACT.probed then return end
    XACT.probed = true
    out("红光 / 鬼魅闪身探针 · 输入组件：%s", XACT.sig(XACT.comp(pup, "GetAbilityInputComponent", "AbilityInputComponent"), "TryActivate"))
    out("红光 / 鬼魅闪身探针 · 闪避帧组件：%s",
        XACT.sig(XACT.comp(pup, "GetDeflectComponent", "DeflectComponent"), "Frame"))
    out("红光 / 鬼魅闪身探针 · 移动驱动组件：%s",
        XACT.sig(XACT.comp(pup, "GetLocomotionDriverComponent", "LocomotionDriverComponent"), "MoveInput"))
end

-- §229 鬼魅闪身要 CharacterState.Native.Focusing（锁定中）这个标签：11-11 01:41 玩家放出来时 6/6 都有，替身 6/6 没有。
-- 11-10 那版 focusOn 看的是状态组件 InExactState(Native.Focusing) = true 就当"本来就在"——状态机里在，ASC 上却没有标签。
-- 这次看 ASC 标签：没有就 StopState 再 TryActivateNewState，让状态机重新进一次（进的时候才挂标签）。返回 有没有标签, 说明
XACT.FOCUS = "CharacterState.Native.Focusing"
function XACT.focus(pup)
    local function hasFocus() local t = G.tagsMatching(pup, { XACT.FOCUS }); return t and #t > 0 end
    if hasFocus() then return true, "本来就有" end
    local sc = G.stateComp(pup)
    if not valid(sc) then return false, "没有状态组件" end
    local tag = { TagName = FName(XACT.FOCUS) }
    local okE, e = pcall(function() return sc:InExactState(tag) end)
    local steps = { "状态机里" .. (okE and tostring(e) or "?") }
    if okE and e then
        local okS = pcall(function() sc:StopState(tag, false) end)
        steps[#steps + 1] = "StopState " .. (okS and "调了" or "出错")
    end
    local okT, r = pcall(function() return sc:TryActivateNewState(tag) end)
    steps[#steps + 1] = "TryActivateNewState=" .. (okT and tostring(r) or "出错")
    local now = hasFocus()
    steps[#steps + 1] = "之后标签" .. (now and "有了" or "还是没有")
    return now, table.concat(steps, "，")
end

-- §229.4 用户定（11-11）：红光先试"让游戏的检查对替身放行"。反击基类 BP_PlayerPerfectDodge_Base 的 K2_CanActivateAbility 要
-- 替身身上有闪避帧；对方那边已经真的完美闪避了，这边帧早过期 / 远程招根本没帧（§229.3：10 次全 0）。
-- 做法：第一次需要时在这个函数上挂钩子（pre + post 两个回调），只在 XACT.forcing（我们自己调 TryActivate 的那一下，同步）时
-- 回调返回 true（UE4SS 用回调的返回值顶替函数返回值）；第一次把回调收到的参数个数 / 类型记下来。钩子挂上就不撤（§ ue4ss 撤钩子会崩），
-- 平时回调只数次数、什么都不改。net/pd_hook_off.txt 存在 = 不挂
XACT.HOOK_PATH = "/PBZDeflectSystem/Abilities/BP_PlayerPerfectDodge_Base.BP_PlayerPerfectDodge_Base_C:K2_CanActivateAbility"
XACT.HOOK_OFF = NET_DIR .. "/pd_hook_off.txt"
function XACT.hookCb(which)
    return function(ctx, ...)
        XACT.hookCalls = (XACT.hookCalls or 0) + 1
        if not XACT.forcing then return nil end
        XACT.hookForced = (XACT.hookForced or 0) + 1
        if not XACT.argLogged then
            XACT.argLogged = true
            local n, types = select("#", ...), {}
            for i = 1, n do
                local a = select(i, ...)
                local tn = type(a)
                local okG, g = pcall(function() return a:get() end)
                types[#types + 1] = tn .. (okG and ("→" .. type(g) .. "=" .. tostring(g):sub(1, 40)) or "")
            end
            out("红光钩子 · %s 回调：参数 %d 个 %s", which, n, table.concat(types, " / "))
        end
        return true
    end
end
function XACT.hook()
    if XACT.hooked ~= nil then return XACT.hooked end
    XACT.hooked = false
    local f = io.open(XACT.HOOK_OFF, "r")
    if f then f:close(); XACT.hookErr = "pd_hook_off.txt 关着"; return false end
    if type(RegisterHook) ~= "function" then XACT.hookErr = "没有 RegisterHook"; return false end
    local ok, e = pcall(function() RegisterHook(XACT.HOOK_PATH, XACT.hookCb("pre"), XACT.hookCb("post")) end)
    XACT.hooked = ok
    XACT.hookErr = ok and nil or XACT.err(e)
    out("红光钩子 · 挂 %s：%s", XACT.HOOK_PATH:match(":(.+)$"), ok and "成功" or ("失败 " .. tostring(XACT.hookErr)))
    return ok
end
-- 钩子放行下再放一次；返回 是否放出来, 说明
function XACT.forceTry(fire, use)
    if not XACT.hook() then return false, "钩子没挂上（" .. tostring(XACT.hookErr) .. "）" end
    local before = XACT.hookForced or 0
    XACT.forcing = true
    local okF, r = pcall(fire, use)
    XACT.forcing = false
    local hit = (XACT.hookForced or 0) - before
    return okF and r == true, string.format("钩子放行 %d 次，ASC → %s", hit, okF and tostring(r) or ("出错 " .. XACT.err(r)))
end

-- §229.5 红光"直接播动作 + 生成子弹"（用户 11-11 定：钩子不行就走这条）。11-11 08:15 实测钩子放行后 ASC 返回 true 12/12，
-- 但替身一个反击动作都没播（技能里要从闪避帧挑时间线，没帧就直接结束）。所以：对方出了红光、替身这边没真放出来时，
-- ① 直接给替身播这把武器红光的动作（游戏包名字表里各武器 *_PerfectDodge 引用的 L 侧动作；只是改默认值的子类用通用的
--    BP_Hun_PerfectDodge_General 的 AM_Hun_PD_AtkL_Short_01，11-11 01:13 用户自己玉双环红光播的就是它）；
-- ② 按 DELAYS 依次用这把武器 L 侧的子弹数据生成子弹（§139.7 光柱伤害同一套：CreateBullet + Initialize + Start），
--    位置 = 替身前方 FWD 厘米、朝向替身朝向（先转向你）。打没打中照常走判定。表由 tools 读名字表生成，别手改
local PDX = { MAP = {}, LOGS = 30, logs = 0, pend = {}, DELAYS = { 0.25, 0.45, 0.65 }, FWD = 100.0, GAP = 40.0, AIM_Z = 80.0,
        CHECK = 0.6, n = 0, spawned = 0, failed = 0, confirm = {}, srcWay = nil }
PDX.OFF = (NET_DIR or "net") .. "/redlight_off.txt"
PDX.GENERAL = { mon = "/PBZCombatAsset/ActorData/Players/Hun/Montage/PerfectDodge/AM_Hun_PD_AtkL_Short_01.AM_Hun_PD_AtkL_Short_01", bul = { "/PBZCombatAsset/ActorData/Players/Hun/BulletData/PerfectDodge/B_Hun_PerfectDodge_LS_1_01.B_Hun_PerfectDodge_LS_1_01" } }
PDX.MAP.Double = { mon = "/PBZCombatAsset/ActorData/Players/Hun/Montage/DoubleBlade/Deflect/New/AM_Hun_Double_PD_L1.AM_Hun_Double_PD_L1", bul = { "/PBZCombatAsset/ActorData/Players/Hun/BulletData/DoubleBlade/PerfectDodge/B_Hun_Double_PerfectDodge_L1_01.B_Hun_Double_PerfectDodge_L1_01", "/PBZCombatAsset/ActorData/Players/Hun/BulletData/DoubleBlade/PerfectDodge/B_Hun_Double_PerfectDodge_L1_02.B_Hun_Double_PerfectDodge_L1_02", "/PBZCombatAsset/ActorData/Players/Hun/BulletData/DoubleBlade/PerfectDodge/B_Hun_Double_PerfectDodge_L1_03.B_Hun_Double_PerfectDodge_L1_03" } }
PDX.MAP.Jade = { mon = "/PBZCombatAsset/ActorData/Players/Hun/Montage/DoubleBlade/Deflect/New/AM_Hun_Double_PD_L1.AM_Hun_Double_PD_L1", bul = { "/PBZCombatAsset/ActorData/Players/Hun/BulletData/DoubleBlade/PerfectDodge/B_Hun_Double_PerfectDodge_L1_01.B_Hun_Double_PerfectDodge_L1_01", "/PBZCombatAsset/ActorData/Players/Hun/BulletData/DoubleBlade/PerfectDodge/B_Hun_Double_PerfectDodge_L1_02.B_Hun_Double_PerfectDodge_L1_02", "/PBZCombatAsset/ActorData/Players/Hun/BulletData/DoubleBlade/PerfectDodge/B_Hun_Double_PerfectDodge_L1_03.B_Hun_Double_PerfectDodge_L1_03" } }
PDX.MAP.Long = { mon = "/PBZCombatAsset/ActorData/Players/Hun/Montage/LongBlade/Deflect/New/AM_Hun_Long_PD_L1.AM_Hun_Long_PD_L1", bul = { "/PBZCombatAsset/ActorData/Players/Hun/BulletData/LongBlade/PerfectDodge/B_Hun_Long_PerfectDodge_L1.B_Hun_Long_PerfectDodge_L1" } }
PDX.MAP.PoJun = { mon = "/PBZCombatAsset/ActorData/Players/Hun/Montage/PoJun/Hun_PoJun_PerfectDodge_Montage.Hun_PoJun_PerfectDodge_Montage", bul = { "/PBZCombatAsset/ActorData/Players/Hun/BulletData/PoJun/BD_Hun_PoJun_PerfectDodge_01.BD_Hun_PoJun_PerfectDodge_01", "/PBZCombatAsset/ActorData/Players/Hun/BulletData/PoJun/BD_Hun_PoJun_PerfectDodge_02.BD_Hun_PoJun_PerfectDodge_02" } }
PDX.MAP.SlitheringSword = { mon = "/PBZCombatAsset/ActorData/Players/Hun/Montage/SlitheringSword/Deflect/AM_Hun_SlitheringSword_PD_L1.AM_Hun_SlitheringSword_PD_L1", bul = { "/PBZCombatAsset/ActorData/Players/Hun/BulletData/SlitheringSword/Attack/B_Hun_SlitheringSword_PD_L1_01.B_Hun_SlitheringSword_PD_L1_01", "/PBZCombatAsset/ActorData/Players/Hun/BulletData/SlitheringSword/Attack/B_Hun_SlitheringSword_PD_L1_02.B_Hun_SlitheringSword_PD_L1_02" } }
PDX.MAP.SnakeDual = { mon = "/PBZCombatAsset/ActorData/Players/Hun/Montage/SnakeDual/Deflect/AM_Hun_SnakeDual_PD_L1.AM_Hun_SnakeDual_PD_L1", bul = { "/PBZCombatAsset/ActorData/Players/Hun/BulletData/SnakeDual/Attack/B_Hun_SnakeDual_PD_L1_01.B_Hun_SnakeDual_PD_L1_01", "/PBZCombatAsset/ActorData/Players/Hun/BulletData/SnakeDual/Attack/B_Hun_SnakeDual_PD_L1_02.B_Hun_SnakeDual_PD_L1_02", "/PBZCombatAsset/ActorData/Players/Hun/BulletData/SnakeDual/Attack/B_Hun_SnakeDual_PD_L1_03.B_Hun_SnakeDual_PD_L1_03" } }
PDX.MAP.Tang = { mon = "/PBZCombatAsset/ActorData/Players/Hun/Montage/TangBlade/Deflect/New/AM_Hun_Tang_PD_L1.AM_Hun_Tang_PD_L1", bul = { "/PBZCombatAsset/ActorData/Players/Hun/BulletData/TangBlade/PerfectDodge/B_Hun_Tang_PerfectDodge_L1.B_Hun_Tang_PerfectDodge_L1" } }
PDX.MAP.Young = { mon = "/PBZCombatAsset/ActorData/Players/Hun/Montage/TangBlade/Young/Hun_Young_Axial_Change_L_Montage.Hun_Young_Axial_Change_L_Montage", bul = { "/PBZCombatAsset/ActorData/Players/Hun/BulletData/TangBlade/WoodenSword/B_Hun_Young_PerfectDodge_L1.B_Hun_Young_PerfectDodge_L1" } }
-- §249 报告 §2.3：补齐 PDX 只有 8 把武器的问题。每个条目的依据都是 gasgraph 资产（逐招展开 / 名字表）：
-- ① 自己的 GA 有动作 / 判定就用它；② GA 只是子技能壳、自己没有动作 / 判定的，用子技能那套（和游戏里真放时一致）。
-- ③ 资产里查不到专属动作 / 判定的，写明用通用，别假装有。
PDX.MAP.BaiYing = { mon = "/PBZCombatAsset/ActorData/Players/Hun/Montage/LongBlade/Deflect/New/AM_Hun_Long_PD_L1.AM_Hun_Long_PD_L1", bul = { "/PBZCombatAsset/ActorData/Players/Hun/BulletData/LongBlade/PerfectDodge/B_Hun_Long_PerfectDodge_L1.B_Hun_Long_PerfectDodge_L1" } }   -- 子技能 GA_Hun_Long_PerfectDodge，没有白影专属动作 / BD
PDX.MAP.ChiZheCanJian = { mon = "/PBZCombatAsset/ActorData/Players/Hun/Montage/TangBlade/Deflect/New/AM_Hun_Tang_PD_L1.AM_Hun_Tang_PD_L1", bul = { "/PBZCombatAsset/ActorData/Players/Hun/BulletData/TangBlade/PerfectDodge/B_Hun_Tang_PerfectDodge_L1.B_Hun_Tang_PerfectDodge_L1" } }   -- 子技能 GA_Hun_Tang_PerfectDodge
PDX.MAP.DualHook = { mon = "/PBZCombatAsset/ActorData/Players/Hun/Montage/PerfectDodge/AM_Hun_PD_AtkL_Short_01.AM_Hun_PD_AtkL_Short_01", bul = { "/PBZCombatAsset/ActorData/Players/Hun/BulletData/DualHook/BD_Hun_DualHook_DB_02_02.BD_Hun_DualHook_DB_02_02", "/PBZCombatAsset/ActorData/Players/Hun/BulletData/DualHook/BD_Hun_DualHook_DB_02_03.BD_Hun_DualHook_DB_02_03", "/PBZCombatAsset/ActorData/Players/Hun/BulletData/DualHook/BD_Hun_DualHook_DB_02_04.BD_Hun_DualHook_DB_02_04", "/PBZCombatAsset/ActorData/Players/Hun/BulletData/DualHook/BD_Hun_DualHook_DB_02_05.BD_Hun_DualHook_DB_02_05", "/PBZCombatAsset/ActorData/Players/Hun/BulletData/DualHook/BD_Hun_DualHook_DB_02_06.BD_Hun_DualHook_DB_02_06", "/PBZCombatAsset/ActorData/Players/Hun/BulletData/DualHook/BD_Hun_DualHook_DB_02_07.BD_Hun_DualHook_DB_02_07", "/PBZCombatAsset/ActorData/Players/Hun/BulletData/DualHook/BD_Hun_DualHook_DB_02_08.BD_Hun_DualHook_DB_02_08", "/PBZCombatAsset/ActorData/Players/Hun/BulletData/DualHook/BD_Hun_DualHook_DB_02_09.BD_Hun_DualHook_DB_02_09" } }   -- 只给 HeavyAttack（GEx 是处决，不加）；GA 没引动作 → 通用动作
PDX.MAP.Jigsaw = { mon = "/PBZCombatAsset/ActorData/Players/Hun/Montage/LongBlade/Deflect/New/AM_Hun_Long_PD_L1.AM_Hun_Long_PD_L1", bul = { "/PBZCombatAsset/ActorData/Players/Hun/BulletData/LongBlade/PerfectDodge/B_Hun_Long_PerfectDodge_L1.B_Hun_Long_PerfectDodge_L1" } }   -- 子技能 GA_Hun_Long_PerfectDodge
PDX.MAP.MoJian = { mon = "/HuaShira/Characters/Hero/Hero_Hun/Animation/ShaChi_Weapon/MoJiZiSword/Hun_Shachi_MJZ_PerfectDodge_Montage.Hun_Shachi_MJZ_PerfectDodge_Montage", bul = { "/PBZCombatAsset/ActorData/Players/Hun/BulletData/ShachiWeapon/MoJian/B_Hun_Mojian_PerfectDodge_01.B_Hun_Mojian_PerfectDodge_01" } }   -- 动作是墨血无痕专属蒙太奇（GA 没直接引，名字表里只有这一条）；判定是 GA 引的 B_Hun_Mojian_PerfectDodge_01
PDX.MAP.ShuangYue = { mon = "/PBZCombatAsset/ActorData/Players/Hun/Montage/DoubleBlade/Deflect/New/AM_Hun_Double_PD_L1.AM_Hun_Double_PD_L1", bul = { "/PBZCombatAsset/ActorData/Players/Hun/BulletData/DoubleBlade/PerfectDodge/B_Hun_Double_PerfectDodge_L1_01.B_Hun_Double_PerfectDodge_L1_01", "/PBZCombatAsset/ActorData/Players/Hun/BulletData/DoubleBlade/PerfectDodge/B_Hun_Double_PerfectDodge_L1_02.B_Hun_Double_PerfectDodge_L1_02", "/PBZCombatAsset/ActorData/Players/Hun/BulletData/DoubleBlade/PerfectDodge/B_Hun_Double_PerfectDodge_L1_03.B_Hun_Double_PerfectDodge_L1_03" } }   -- 子技能 GA_Hun_Double_PerfectDodge
PDX.MAP.YanYueDao = { mon = "/PBZCombatAsset/ActorData/Players/Hun/Montage/LongBlade/Deflect/New/AM_Hun_Long_PD_L1.AM_Hun_Long_PD_L1", bul = { "/PBZCombatAsset/ActorData/Players/Hun/BulletData/LongBlade/PerfectDodge/B_Hun_Long_PerfectDodge_L1.B_Hun_Long_PerfectDodge_L1" } }   -- 子技能 GA_Hun_Long_PerfectDodge
PDX.MAP.ZhanMa = { mon = "/PBZCombatAsset/ActorData/Players/Hun/Montage/LongBlade/Deflect/New/AM_Hun_Long_PD_L1.AM_Hun_Long_PD_L1", bul = { "/PBZCombatAsset/ActorData/Players/Hun/BulletData/LongBlade/PerfectDodge/B_Hun_Long_PerfectDodge_L1.B_Hun_Long_PerfectDodge_L1" } }   -- 子技能 GA_Hun_Long_PerfectDodge
PDX.MAP.ZiMingJian = { mon = "/HuaShira/Animation/Hero/Hun/SH_Sources/ZiMingJian/Hun_ZiMing_Summon_PerfectDodge_Montage.Hun_ZiMing_Summon_PerfectDodge_Montage", bul = { "/PBZCombatAsset/ActorData/Players/Hun/BulletData/ZiMingJian/B_Hun_ZiMingJian_PerfectDodge_GreatSword_01.B_Hun_ZiMingJian_PerfectDodge_GreatSword_01" } }   -- 动作是紫冥剑专属蒙太奇；判定是 GA 引的 GreatSword 子弹
PDX.MAP.WoodenSword = { mon = "/PBZCombatAsset/ActorData/Players/Hun/Montage/TangBlade/Young/Hun_Young_Axial_Change_L_Montage.Hun_Young_Axial_Change_L_Montage", bul = { "/PBZCombatAsset/ActorData/Players/Hun/BulletData/TangBlade/WoodenSword/B_Hun_Young_PerfectDodge_L1.B_Hun_Young_PerfectDodge_L1" } }   -- 木制黑伤 / 少年魂同一套（PDX.MAP.Young 已有）
-- 招式名 → PDX 表的键。大多数是 GA_Hun_<武器>_PerfectDodge_C，但紫冥剑（_New_）、双钩（HeavyAttack）、木剑（WoodenSword）不是。
PDX.ALIAS = {
    GA_Hun_ZiMingJian_New_PerfectDodge_C = "ZiMingJian",
    GA_Hun_DualHook_PerfectDodge_HeavyAttack_C = "DualHook",
    GA_Hun_WoodenSword_PerfectDodge_C = "WoodenSword",
    GA_Hun_DualHook_PerfectDodge_GEx_C = false,     -- 处决，PDX 也不该给它播红光
}
function PDX.key(use)
    local a = PDX.ALIAS[use]
    if a ~= nil then return a or nil end
    return use:match("^GA_Hun_(%w+)_PerfectDodge_C$")
end

function PDX.log(...)
    if PDX.logs < PDX.LOGS then PDX.logs = PDX.logs + 1; out(...) end
end

-- net/redlight_off.txt 存在 = 不直接播红光（回到 §229 只走 ASC / 输入组件，放不出就落空）
function PDX.off()
    local f = io.open(PDX.OFF, "r")
    if f then f:close(); return true end
    return false
end

-- 资源对象：先找内存里的，没有再 LoadAsset（适配层 G.findOrLoad）
function PDX.obj(path)
    return G.findOrLoad and G.findOrLoad(path) or nil
end

-- 替身身上这个技能的实例（不管在不在放；子弹 Initialize 的来源技能用它，没有就 nil）
function PDX.inst(pup, clsName)
    local asc = ascOf(pup)
    local items = asc and rawProp(rawProp(asc, "ActivatableAbilities"), "Items")
    local found
    if items then
        eachArr(items, function(_, spec)
            if found then return end
            local ab = rawProp(spec, "Ability")
            local okC, cls = false, nil
            if valid(ab) then okC, cls = pcall(function() return ab:GetClass() end) end
            if not (okC and shortName(full(cls)) == clsName) then return end
            for _, key in ipairs({ "NonReplicatedInstances", "ReplicatedInstances" }) do
                eachArr(rawProp(spec, key), function(_, i) if not found and valid(i) then found = i end end)
            end
        end)
    end
    return found
end

-- §242 子弹 Initialize 的来源技能：优先正在放的实例；替身的红光 ASC 根本没放出来，items 里没有实例，
-- 就退到这一格技能的默认对象（spec.Ability）。以前这里直接给 nil，子弹的 SourceAbility 是空的。
function PDX.src(pup, clsName)
    local inst = PDX.inst(pup, clsName)
    if inst then return inst, "技能实例" end
    local asc = ascOf(pup)
    local items = asc and rawProp(rawProp(asc, "ActivatableAbilities"), "Items")
    local cdo
    if items then
        eachArr(items, function(_, spec)
            if cdo then return end
            local ab = rawProp(spec, "Ability")
            local okC, cls = false, nil
            if valid(ab) then okC, cls = pcall(function() return ab:GetClass() end) end
            if okC and shortName(full(cls)) == clsName then cdo = ab end
        end)
    end
    return cdo, cdo and "技能默认对象" or "没有技能对象"
end

function PDX.start(pup, use)
    if use:find("PerfectDodge_GEx", 1, true) then      -- §249 双钩 GEx 是抓取处决，对局里禁用，别给它播红光
        PDX.log("红光 · %s 是处决（GEx），不直接播", use)
        return false
    end
    PDX.n = PDX.n + 1
    local w = PDX.key(use)
    local e = (w and PDX.MAP[w]) or PDX.GENERAL
    if not (w and PDX.MAP[w]) then
        PDX.log("红光 · 这把武器没有 PDX 表（%s，键 %s），用 GENERAL 动作 / 通用子弹", use, tostring(w or "无"))
    end
    pcall(facePlayer, pup)
    local monName = e.mon:match("%.([%w_]+)$")
    local okP = playNamed(pup, monName)
    if not okP then
        local m = PDX.obj(e.mon)
        okP = (m and playOn(pup, m)) and true or false
        if okP and sameObj(pup, ST.secondPawn) then ST.pupOwnName, ST.pupOwnFrames = monName, 120 end
    end
    local tn = now()
    local p1 = getP1()
    for i, b in ipairs(e.bul) do
        PDX.pend[#PDX.pend + 1] = { t = tn + (PDX.DELAYS[i] or (0.25 + 0.2 * (i - 1))), bd = b, pup = pup, use = use,
                                    hp0 = valid(p1) and hpOf(p1) or nil, t0 = tn, n = i, total = #e.bul }
    end
    PDX.log("红光直接播（第 %d 次）%s：动作 %s %s，排了 %d 个子弹", PDX.n, use, monName, okP and "已播" or "播不出", #e.bul)
    return okP
end

function PDX.step(tn)
    if #PDX.pend == 0 then
        -- 子弹都生成完了：CHECK 秒后看挨打方掉没掉血（只记日志，不改判定）
        if #PDX.confirm > 0 then
            local keep = {}
            local p1 = getP1()
            for _, c in ipairs(PDX.confirm) do
                if tn < c.at then keep[#keep + 1] = c
                else
                    local hp = valid(p1) and hpOf(p1) or nil
                    if c.hp0 and hp and hp < c.hp0 - 0.5 then
                        PDX.log("  红光直接播：子弹之后 %.1f 秒你掉了 %.0f 血（打中了）", tn - c.t0, c.hp0 - hp)
                    else
                        PDX.log("  红光直接播：子弹都生成了，但 %.1f 秒内你没掉血（%d 个子弹 / 距离 %.0f cm / 朝向差 ?）→ 下一轮看是不是子弹数据要 DeflectFrame",
                            tn - c.t0, c.n, c.dist or -1)
                    end
                end
            end
            PDX.confirm = keep
        end
        return
    end
    local keep = {}
    local lastAt, lastN, lastDist, lastHp0 = nil, 0, nil, nil
    for _, q in ipairs(PDX.pend) do
        if tn < q.t then keep[#keep + 1] = q
        elseif valid(q.pup) then
            local bd = PDX.obj(q.bd)
            local okL, l = pcall(function() return q.pup:K2_GetActorLocation() end)
            local p1 = getP1()
            local okP, pl = false, nil
            if valid(p1) then okP, pl = pcall(function() return p1:K2_GetActorLocation() end) end
            local src, srcWay = PDX.src(q.pup, q.use)
            local at, yaw, pitch, dist = nil, yawOf(q.pup) or 0.0, 0.0, nil
            if okL and l then
                local aimZ = (okP and pl and (pl.Z + PDX.AIM_Z)) or (l.Z + PDX.AIM_Z)
                if okP and pl then
                    local dx, dy = pl.X - l.X, pl.Y - l.Y
                    dist = math.sqrt(dx * dx + dy * dy)
                    local adv = math.min(PDX.FWD, math.max(0.0, dist - PDX.GAP))
                    local ux, uy = (dist > 1e-3) and dx / dist or math.cos(math.rad(yaw)), (dist > 1e-3) and dy / dist or math.sin(math.rad(yaw))
                    at = { X = l.X + ux * adv, Y = l.Y + uy * adv, Z = aimZ }
                    yaw = math.deg(math.atan(uy, ux))
                    pitch = math.deg(math.atan(aimZ - at.Z, math.max(adv, 1.0)))
                else
                    local r = math.rad(yaw)
                    at = { X = l.X + math.cos(r) * PDX.FWD, Y = l.Y + math.sin(r) * PDX.FWD, Z = aimZ }
                end
            end
            local em, how
            if bd and at then
                local okS, a, b2 = pcall(G.laserEmitterSpawn, src, q.pup, at, { Pitch = pitch, Yaw = yaw, Roll = 0.0 }, bd)
                if okS then em, how = a, b2 else how = "出错 " .. XACT.err(a) end
            else
                how = bd and "读不到替身位置" or "找不到子弹数据"
            end
            if em then PDX.spawned = PDX.spawned + 1 else PDX.failed = PDX.failed + 1 end
            PDX.log("  红光子弹 %s：%s（%s；来源 %s；距离 %s；yaw %.0f pitch %.0f）", q.bd:match("%.([%w_]+)$"),
                em and "生成了" or "没生成", tostring(how), srcWay, dist and string.format("%.0f", dist) or "?",
                yaw, pitch)
            lastAt, lastN, lastDist, lastHp0 = tn, q.total or ((lastN or 0) + 1), dist, q.hp0
        end
    end
    PDX.pend = keep
    if lastAt and #keep == 0 then
        PDX.confirm[#PDX.confirm + 1] = { at = tn + PDX.CHECK, t0 = lastAt, n = lastN,
                                          hp0 = lastHp0, dist = lastDist }
    end
end

-- ASC 放不出之后：（鬼魅闪身先补锁定标签再 ASC 放一次）输入组件按类放；红光再按标签放（和游戏被动同一个调用）。返回 true = 放出来了
function XACT.retry(pup, use, cls, fire)
    XACT.n = XACT.n + 1
    pcall(XACT.probe, pup)
    local ic = XACT.comp(pup, "GetAbilityInputComponent", "AbilityInputComponent")
    local pd = use:match("PerfectDodge") ~= nil
    local frames = XACT.frames(pup)
    local r1, r2, ok = "没有输入组件", "-", false
    local fx = ""
    if not pd then
        local okF, got, how = pcall(XACT.focus, pup)
        fx = "；锁定标签：" .. (okF and tostring(how) or ("出错 " .. XACT.err(got)))
        if okF and got and fire then
            ok = fire(use)
            fx = fx .. "，补上后 ASC 再放 " .. (ok and "放出来了" or "还是不行")
            if ok then XACT.okFocus = (XACT.okFocus or 0) + 1 end
        end
    end
    if not ok and pd and fire then
        local okH, got, how = pcall(XACT.forceTry, fire, use)
        ok = okH and got == true
        fx = fx .. "；" .. (okH and tostring(how) or ("钩子出错 " .. XACT.err(got)))
        if ok then XACT.okHook = (XACT.okHook or 0) + 1; XACT.hookAt = now(); XACT.hookUse = use; XACT.okHookNow = true end
    end
    if ok then
        -- 已经放出来了
    elseif ic and valid(cls) then
        local okC, r = pcall(function() return ic:TryActivateExternalActionAbilityByClass(cls, nil, XACT.PRIO) end)
        r1 = okC and tostring(r) or ("出错 " .. XACT.err(r))
        ok = okC and r == true
        if ok then XACT.okCls = XACT.okCls + 1 end
    elseif ic then
        r1 = "没有技能类"
    end
    if not ok and pd and ic then
        local okT, r = pcall(function() return ic:TryActivateExternalActionAbilityInterruptLowerByTag({ TagName = FName(XACT.PD_TAG) }, nil, XACT.PRIO) end)
        r2 = okT and tostring(r) or ("出错 " .. XACT.err(r))
        ok = okT and r == true
        if ok then XACT.okTag = XACT.okTag + 1 end
    end
    -- §229.5 红光：没真放出来（钩子放行 ASC 也会返回 true，但没帧就马上结束，不播动作）→ 直接播动作 + 生成子弹
    if pd and PDX and not PDX.off() and (not ok or XACT.okHookNow) then
        local okD, r = pcall(PDX.start, pup, use)
        fx = fx .. "；直接播 " .. (okD and (r and "已播" or "播不出") or ("出错 " .. XACT.err(r)))
        ok = true
    end
    XACT.okHookNow = nil
    if not ok then XACT.fail = XACT.fail + 1 end
    if not ok and pd and tonumber(frames) and tonumber(frames) > 0 and (XACT.dumps or 0) < 15 then
        XACT.dumps = (XACT.dumps or 0) + 1
        local okD, d = pcall(XACT.frameDump, pup)
        out("红光 · 替身有帧仍放不出（第 %d 次）：%s", XACT.dumps, okD and d or ("出错 " .. XACT.err(d)))
    end
    if XACT.logs < XACT.LOGS or XACT.n % 20 == 0 then
        XACT.logs = XACT.logs + 1
        local p1 = getP1()
        out("红光 / 鬼魅闪身 · 替身 ASC 放不出 %s：收到的闪避帧 %s；我在放 %s%s；输入组件按类 → %s%s → %s（累计 钩子成 %d / 补锁定成 %d / 按类成 %d / 按标签成 %d / 不成 %d）",
            use, frames, valid(p1) and (montageOf(p1) or "无") or "?", fx, r1, pd and ("，按标签 → " .. r2) or "",
            ok and "放出来了" or "还是放不出", XACT.okHook or 0, XACT.okFocus or 0, XACT.okCls, XACT.okTag, XACT.fail)
    end
    return ok
end

return {
    JDIAG = JDIAG,
    XACT = XACT,
    PDX = PDX,
}
end
