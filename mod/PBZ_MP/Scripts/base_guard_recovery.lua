-- Combat-usable fallback; timers start at release or confirmed ordinary guard damage.
return function(ctx)
    local G = ctx.G
    local R = { CHECK = 0.1, SNAPSHOT = 0.25, DELAY = 1, WINDOW = 15, GAP = 0.5, COOLDOWN = 10, MAX_FRAMES = 64 }
    local GUARD = "IA_ChangeArmed"
    local GROUND = "CharacterState.Space.Ground"
    local BLOCKED = { GROUND, "CharacterState.Stun", "CharacterState.Stand.Break",
        "CharacterState.AbilityState.Stance.Forbid", "CharacterState.Native.Sequence" }
    local AMBIENT = {}
    for _, n in ipairs({
        "GA_ResotreHealth_Passive_C", "GA_MobUtilitiesPassive_C", "GA_CloseFocus_Passive_C",
        "GA_ChangeShachiWeapon_C", "GA_CommonUtilitiesPassive_C", "GA_PlayerUtilitiesPassive_C",
        "GA_Talent_EnableIntoSuperSprint_C", "GA_Hun_GuiTouBlade_Passive_C", "GA_AddAccessorySlot_HuPo_C",
        "GA_SpaceState", "GA_ASM_CallBackCommon_C", "GA_Talent_PerfectDeflectRecoveryShachi_C",
        "GA_AddAccessorySlot_MemoryFlower_C", "BP_PlayerDeflectPassive_C", "GA_LockCameraPassive_C",
        "BP_PerfectDodgePassive_C", "GA_CombatAimPassive", "GA_AddAccessorySlot_HeiShi_C",
        "GA_Medicine_BuJinShui_Passive_C", "GA_AddMedicineUseTime_C", "GA_FocusControl_Passive_C",
        "GA_AddAccessorySlot_RongShu_C", "GA_SoftLockNext_Passive_C", "GA_PhantomPassive_C",
        "GA_Player_BuffTracker_C", "GA_Hun_BreakEscape_Passive_C", "GA_LocomotionDriver_3DDefault_C",
        "GA_Accessory_ShachiWeapon_Lv3_C", "GA_ZhanMa_SustainedBlood_BP_C", "GA_HeiMoShang_RebornPassive",
        "GA_BronzeSword_DeflectPassive_C", "GA_Talent_EnableTenacity_C",
    }) do AMBIENT[n] = true end
    local function finite(v)
        return type(v) == "number" and v == v and v > -math.huge and v < math.huge
    end
    local function read(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, value = pcall(fn, ...)
        if ok then return value end
    end
    -- 11.22 实机：对局里饰品被标准化成 GA_Accessory_ShachiWeapon_Lv1_C（名单里只有 Lv3），这一个就让兜底永远静默不清。
    -- 常驻被动随配装 / 饰品等级 / 天赋 / 武器变化：饰品、饰品槽、天赋、武器自带被动（GA_Hun_<武器>_Passive_C）这几族算常驻
    -- （它们平时一直激活，而正常状态下标签计数是 0，说明不是这个标签的持有者）。别的未知技能（含不认识的被动）照旧否决。
    local function ambient(name)
        return AMBIENT[name] == true or name:match("^GA_Hun_[%w_]+_Stance_C$") ~= nil
            or name:match("^GA_Accessory_[%w_]+_C$") ~= nil or name:match("^GA_AddAccessorySlot_[%w_]+_C$") ~= nil
            or name:match("^GA_Talent_[%w_]+_C$") ~= nil or name:match("^GA_Hun_%w+_Passive_C$") ~= nil
    end
    local function actionsSafe(all)
        if type(all) ~= "table" or next(all) == nil then return false, "abilities unreadable" end
        for name, active in pairs(all) do
            if type(name) ~= "string" or active ~= true then return false, "abilities unreadable" end
            if not ambient(name) then return false, name end
        end
        return true
    end
    local function montageSafe(m)
        if type(m) ~= "string" then return false end
        if m == "" then return true end
        if m:find("Counter", 1, true) or m:find("Break", 1, true) or m:find("_PD_", 1, true) then return false end
        return m:find("Stance", 1, true) ~= nil or m:find("Deflect", 1, true) ~= nil
    end
    local function tagsSafe(tags)
        if type(tags) ~= "table" then return false end
        local grounded = false
        for _, name in ipairs(tags) do
            if name ~= GROUND then return false end
            grounded = true
        end
        return grounded
    end
    local function invalidate()
        R.held, R.count, R.triggerAt, R.triggerLast, R.reason, R.snapshotAt = nil, nil, nil, nil, nil, nil
        R.frames, R.observedWorld, R.providerReason, R.vetoWhy = {}, nil, nil, nil
    end
    local function arm(reason, tn)
        -- Repeated hits/releases extend observation, but never postpone the first deadline.
        R.triggerAt, R.triggerLast = R.triggerAt or tn, tn
        R.reason = R.reason or reason
    end
    function R.reset()
        R.actor, R.last, R.sampleAt, R.tried, R.attemptAt = nil, nil, nil, false, nil
        invalidate()
    end
    R.reset()
    function R.observe(p1, tn)
        if R.count ~= 1 or R.held ~= true or not R.actor or not G.valid(p1)
            or not G.sameObj(R.actor, p1) or not finite(tn) or not R.last
            or tn < R.last or tn - R.last > R.GAP then return end
        local snapshot = read(G.guardRecoveryReceiveFrames, p1)
        if type(snapshot) ~= "table" or not finite(snapshot.world) or type(snapshot.frames) ~= "table" then
            R.frames, R.observedWorld = {}, nil; return
        end
        local world = snapshot.world
        if R.observedWorld and world < R.observedWorld then invalidate(); return end
        R.observedWorld = world
        for id, fr in pairs(snapshot.frames) do
            if type(fr) ~= "table" or not finite(fr.time) or type(fr.strength) ~= "string" or type(fr.dodge) ~= "boolean" then
                R.frames, R.observedWorld = {}, nil; return
            end
            if fr.time >= world - 0.3 and fr.time <= world + 0.5 then
                local old = R.frames[id]
                R.frames[id] = { time = fr.time, strength = fr.strength, dodge = fr.dodge,
                    used = old and old.time == fr.time and old.used or false }
            end
        end
        local retained = 0
        for id, fr in pairs(R.frames) do
            if fr.time < world - 0.3 then R.frames[id] = nil else retained = retained + 1 end
        end
        if retained > R.MAX_FRAMES then R.frames, R.observedWorld = {}, nil end
    end
    local function ordinaryHit(p1)
        local world = read(G.worldTime, p1)
        if not finite(world) or not R.observedWorld or world < R.observedWorld or world - R.observedWorld > 0.3 then return false end
        local candidate, n = nil, 0
        for _, fr in pairs(R.frames) do
            if not fr.used and fr.time >= world - 0.3 and fr.time <= world + 0.15 then
                fr.used = true -- Ambiguous evidence is consumed too; never reuse a frame for another loss.
                n, candidate = n + 1, fr
            end
        end
        return n == 1 and candidate.dodge == false and candidate.strength == "Deflect.Strength.Normal"
    end
    function R.onDamage(p1, tn, damage, guarding, breaking)
        if not R.actor or not G.valid(p1) or not G.sameObj(R.actor, p1) or not finite(tn)
            or not R.last or tn < R.last or tn - R.last > R.GAP
            or not finite(damage) or damage <= 0.5 or guarding ~= true or breaking ~= false or R.tried then return end
        local hold, count = read(G.holdingInputs, p1, true), read(G.guardRecoveryCount, p1)
        if type(hold) ~= "table" or hold[GUARD] ~= true or count ~= 1 then return end
        local breaks = read(G.tagsMatching, p1, { "CharacterState.Stand.Break" }, true)
        if type(breaks) ~= "table" or next(breaks) ~= nil then return end
        -- Unknown attack classification, DOT and multiple ambiguous frames cannot arm this path.
        if not ordinaryHit(p1) then return end
        arm("guard-damage", tn)
    end
    function R.frame(p1, montage, _filtered, tn)
        if not G.valid(p1) or not finite(tn) then R.reset(); return end
        if not R.actor or not G.sameObj(R.actor, p1) or not R.last or tn < R.last or tn - R.last > R.GAP then
            R.reset()
            R.actor, R.last = p1, tn
            return
        end
        R.last = tn
        if R.sampleAt and tn - R.sampleAt < R.CHECK then return end
        R.sampleAt = tn
        local hold, count = read(G.holdingInputs, p1, true), read(G.guardRecoveryCount, p1)
        if type(hold) ~= "table" or not finite(count) or count < 0 or count % 1 ~= 0 then invalidate(); return end
        local held = hold[GUARD] == true
        R.count = count
        if count == 0 then
            R.tried, R.triggerAt, R.triggerLast, R.reason = false, nil, nil, nil
            R.frames, R.observedWorld, R.providerReason = {}, nil, nil
        elseif count ~= 1 then
            R.frames, R.observedWorld = {}, nil
        end
        if R.held == true and not held and count == 1 then arm("release", tn) end
        R.held = held
        if not R.triggerAt then return end
        if tn - R.triggerLast > R.WINDOW then R.triggerAt, R.triggerLast, R.reason = nil, nil, nil; return end
        if tn - R.triggerAt < R.DELAY or count ~= 1 or R.tried then return end
        if R.attemptAt and tn - R.attemptAt < R.COOLDOWN then return end
        local hp, sh = read(ctx.hpOf, p1), read(ctx.attrOf, p1, "Shachi")
        if read(ctx.locked, tn) ~= false or not finite(hp) or hp <= 0 or not finite(sh) or sh <= 0 then return end
        if not montageSafe(montage) then return end
        if R.snapshotAt and tn - R.snapshotAt < R.SNAPSHOT then return end
        R.snapshotAt = tn
        local tags = read(G.tagsMatching, p1, BLOCKED, true)
        local all = read(G.activeAbilities, p1, nil, true)
        local actualMontage = read(G.guardRecoveryIdleMontage, p1)
        if type(tags) ~= "table" or type(all) ~= "table" or actualMontage == nil then invalidate(); return end
        -- These are instantaneous write vetoes, not a continuous idle interval.
        local actOk, actWhy = actionsSafe(all)
        local veto = (not tagsSafe(tags) and ("tags " .. table.concat(tags, ","))) or (not actOk and ("ability " .. tostring(actWhy)))
            or (not montageSafe(actualMontage) and ("montage " .. tostring(actualMontage))) or nil
        if veto then
            -- Only log when the reason changes, so a persistent veto is visible instead of silent.
            if R.vetoWhy ~= veto then ctx.out("guard recovery waiting: veto=%s", veto); R.vetoWhy = veto end
            return
        end
        local safe, reason
        local ok = pcall(function() safe, reason = G.guardRecoveryEffects(p1) end)
        if not ok or safe ~= true then
            if R.providerReason ~= tostring(reason) then
                ctx.out("guard recovery deferred: providers=%s reason=%s", tostring(safe), tostring(reason))
                R.providerReason = tostring(reason)
            end
            return
        end
        R.tried, R.attemptAt = true, tn
        ctx.out("guard recovery attempt: trigger=%s elapsed=%.2f hp=%s shachi=%s", R.reason,
            tn - R.triggerAt, tostring(hp), tostring(sh))
        local worked, success, before, after = pcall(G.guardRecoveryRemove, p1)
        ctx.out("guard recovery result: callOk=%s cleared=%s before=%s after=%s (not proof of guard recovery)",
            tostring(worked), tostring(worked and success == true), tostring(before), tostring(after))
        R.triggerAt, R.triggerLast, R.reason, R.providerReason = nil, nil, nil, nil
    end
    return R
end
