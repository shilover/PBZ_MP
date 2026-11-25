-- base_replay.lua —— 从 main.lua 搬出来的 M1：录制 / 回放（docs/MAIN_SLIM.md）。原来在 main.lua 的 "-- ============================================================ M1：录制 / 回放" 那段
return function(ctx)
local ST, NET, MATCH, REC, REP, LO, G = ctx.ST, ctx.NET, ctx.MATCH, ctx.REC, ctx.REP, ctx.LO, ctx.G
local NET_DIR, REC_DIR, REPLAY_DIST = ctx.NET_DIR, ctx.REC_DIR, ctx.REPLAY_DIST
local pupAction, weaponOfAbility = ctx.pupAction, ctx.weaponOfAbility
local pathOf, valid, try, rawProp, short = G.pathOf, G.valid, G.try, G.rawProp, G.short
local getP1, puppet, now, ascOf, montageByName, playOn = G.getP1, G.puppet, G.now, G.ascOf, G.montageByName, G.playOn
local placeInFront, setBraking, equipWeapon, cutMontage, yawOf, abilitiesOf = G.placeInFront, G.setBraking, G.equipWeapon, G.cutMontage, G.yawOf, G.abilitiesOf
-- main.lua 主循环那段会把 out / fileWrite / drivePuppet / activeAbilities / montageOf / attrOf 换成计时包装（PROF.wrap），
-- 这几个由 ctx 传"调用时再取"的包装，和搬出来之前一样走计时（docs/MAIN_SLIM.md 规矩 3）
local out, fileWrite, drivePuppet = ctx.out, ctx.fileWrite, ctx.drivePuppet
local activeAbilities, montageOf, attrOf = ctx.activeAbilities, ctx.montageOf, ctx.attrOf
local activateOnPuppet

local function toggleRecord()
    local p1 = getP1()
    if not valid(p1) then out("!! 没有玩家1"); return end
    if not REC.on then
        local loc = try("rec loc", function() return p1:K2_GetActorLocation() end)
        local rot = try("rec rot", function() return p1:K2_GetActorRotation() end)
        if not (loc and rot) then return end
        REC.on, REC.frames, REC.t0 = true, {}, now()
        REC.ox, REC.oy, REC.oz, REC.oyaw = loc.X, loc.Y, loc.Z, rot.Yaw
        REC.prevAbs = activeAbilities(p1) or {}
        out("● 开始录制。建议：先往前走两步，再打一套连招，再按 F7 停")
        return
    end
    REC.on = false
    local fr = REC.frames or {}
    if #fr < 2 then out("录制太短，丢弃"); return end
    local name = os.date("rec_%H%M%S.txt")
    local lines = { "# PBZ_MP 录制 v2  t|前|右|高|相对朝向|动画|本帧新激活的技能(逗号分隔)" }
    local seen, list, abs = {}, {}, {}
    for _, f in ipairs(fr) do
        lines[#lines + 1] = string.format("%.3f|%.1f|%.1f|%.1f|%.1f|%s|%s", f.t, f.x, f.y, f.z, f.yaw, f.m, f.ab)
        if f.m ~= "" and not seen[f.m] then seen[f.m] = true; list[#list + 1] = f.m end
        if f.ab ~= "" then abs[#abs + 1] = string.format("%.1fs %s", f.t, f.ab) end
    end
    local text = table.concat(lines, "\n") .. "\n"
    fileWrite(REC_DIR .. "/" .. name, text)
    fileWrite(REC_DIR .. "/last.txt", text)
    ST.atkList, ST.atkIdx = nil, 0
    out("■ 录制结束：%d 帧 / %.1f 秒，存为 rec/%s", #fr, fr[#fr].t, name)
    out("  录到的技能（F8 回放时替身会按时间依次激活）：%s", #abs > 0 and table.concat(abs, "；") or "无")
end

-- 回放时不该让替身激活的：被动、吃药、处决、复活、破防挣脱（这是挨打后的被动反应）
local function replayable(name)
    for _, bad in ipairs({ "Passive", "Medicine", "Respawn", "ResetAttribute", "Talent", "Tracker",
                           "Locomotion", "SwitchAttack", "Accessory", "Execution", "BreakEscape",
                           "SustainedBlood", "Sense",
                           -- §189 木剑升级的完美闪避：只有慢动作 + 镜头震动（名字表里没有动作 / 子弹），是闪避的人自己的手感，
                           -- 替身放了会让本机也慢下来；以前替身也放不出（找不到类）
                           "WoodenSword_PerfectDodge" }) do
        if name:find(bad, 1, true) then return false end
    end
    return true
end
-- §82.2 发包只看这些技能（招式 + 破防挣脱），activeAbilities 据此只读这几格。全局字段：主代码块 local 已满
NET.wantAb = function(name) return name == "GA_Hun_BreakEscape_C" or replayable(name) end

local function recordStep()
    if not REC.on then return end
    local p1 = getP1()
    if not valid(p1) then return end
    local loc = try("rec loc", function() return p1:K2_GetActorLocation() end)
    local rot = try("rec rot", function() return p1:K2_GetActorRotation() end)
    if not (loc and rot) then return end
    local r = math.rad(REC.oyaw)
    local dx, dy = loc.X - REC.ox, loc.Y - REC.oy
    -- v0.6.1 实测：只播动画不产生伤害（F4/F8 打不到人），激活技能才行（F5 能打中、能被格挡）。
    -- 所以录"本帧新激活了哪些技能"，回放时在替身身上激活同名技能
    local act = activeAbilities(p1) or {}
    local new = {}
    for n in pairs(act) do
        if not REC.prevAbs[n] and replayable(n) then new[#new + 1] = n end
    end
    REC.prevAbs = act
    REC.frames[#REC.frames + 1] = {
        ab = table.concat(new, ","),
        t = now() - REC.t0,
        x = dx * math.cos(r) + dy * math.sin(r),
        y = -dx * math.sin(r) + dy * math.cos(r),
        z = loc.Z - REC.oz,
        yaw = rot.Yaw - REC.oyaw,
        m = montageOf(p1),
    }
    if #REC.frames > 30 * 120 then out("录制超过 2 分钟，自动停止"); toggleRecord() end
end

local function loadRecording(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local frames = {}
    for line in f:lines() do
        if line:sub(1, 1) ~= "#" then
            local t, x, y, z, yaw, m = line:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|(.*)$")
            if t then
                -- v2 多一列技能；v1 没有
                local m2, ab = m:match("^([^|]*)|(.*)$")
                if m2 then m = m2 else ab = "" end
                frames[#frames + 1] = { t = tonumber(t), x = tonumber(x), y = tonumber(y),
                    z = tonumber(z), yaw = tonumber(yaw), m = m, ab = ab }
            end
        end
    end
    f:close()
    return frames
end

local function stopReplay(why)
    if not REP.on then return end
    REP.on = false
    local pup = puppet()
    if valid(pup) then setBraking(pup, false) end
    out("■ 回放结束（%s）", why or "")
end

local function startReplay()
    local pup, p1 = puppet(), getP1()
    if not valid(pup) then out("!! 还没有替身，先按 F12"); return end
    if not valid(p1) then out("!! 没有玩家1"); return end
    if REP.on then stopReplay("重新开始") end
    local frames = loadRecording(REC_DIR .. "/last.txt")
    if not frames or #frames < 2 then out("!! 没有录制，先按 F7 录一段"); return end

    local loc = try("p1 loc", function() return p1:K2_GetActorLocation() end)
    local rot = try("p1 rot", function() return p1:K2_GetActorRotation() end)
    if not (loc and rot) then return end
    local r = math.rad(rot.Yaw)
    -- 起点放在你正前方，朝向你：录制时的"往前"在回放里就是"冲你来"
    REP.ax, REP.ay, REP.az = loc.X + math.cos(r) * REPLAY_DIST, loc.Y + math.sin(r) * REPLAY_DIST, loc.Z
    REP.ayaw = rot.Yaw + 180.0
    REP.frames, REP.i, REP.abI, REP.lastM, REP.t0, REP.on = frames, 1, 0, "", now(), true
    placeInFront(pup, REPLAY_DIST)
    setBraking(pup, true)

    -- 有技能列就按技能回放（能打人）；只有 v1 旧录制才退回播动画（打不到人）
    REP.useAb, REP.sub = false, {}
    for _, f in ipairs(frames) do if f.ab ~= "" then REP.useAb = true; break end end
    -- 先让替身拿上录制里用的武器（取第一个能认出武器的技能）
    for _, f in ipairs(frames) do
        local wid = nil
        for n in f.ab:gmatch("[^,]+") do wid = wid or weaponOfAbility(n) end
        if wid then
            if LO.EQUIP_REMOTE then equipWeapon(pup, wid, "回放录制用的武器") end   -- v0.16.0：会改玩家装备，见 §29
            break
        end
    end
    REP.abMap = {}
    for _, a in ipairs(abilitiesOf(pup) or {}) do REP.abMap[a.name] = a.cls end
    local miss, seen = {}, {}
    for _, f in ipairs(frames) do
        for n in f.ab:gmatch("[^,]+") do
            if not REP.abMap[n] and not seen[n] then seen[n] = true; miss[#miss + 1] = n end
        end
    end
    out("▶ 回放 %d 帧 / %.1f 秒，方式=%s%s", #frames, frames[#frames].t,
        REP.useAb and "激活技能" or "只播动画（旧录制，打不到人，建议按 F7 重录）",
        #miss > 0 and ("；替身没有的技能: " .. table.concat(miss, ", ")) or "")
end

local function toWorld(f)
    local r = math.rad(REP.ayaw)
    return {
        X = REP.ax + f.x * math.cos(r) - f.y * math.sin(r),
        Y = REP.ay + f.x * math.sin(r) + f.y * math.cos(r),
        Z = REP.az + f.z,
    }
end

-- 多人原型（pbz_multi.lua）：几个替身轮流出招时每换一个就整表重建（读技能列表 ~59 ms），改成每个替身各存一份。
-- 只有一个替身时和以前一样；别处把 ST.abMapKey 置 nil = 全部作废（换装 / 换替身后要重读）
local function puppetAbMap(pup)
    local key = pathOf(pup)
    if ST.abMapKey ~= key then
        if ST.abMapKey == nil then ST.abMaps = {} end
        ST.abMaps = ST.abMaps or {}
        local m = ST.abMaps[key]
        if not m then
            m = {}
            for _, a in ipairs(abilitiesOf(pup) or {}) do m[a.name] = a.cls end
            ST.abMaps[key] = m
        end
        ST.abMap, ST.abMapKey = m, key
    end
    return ST.abMap
end

-- §162 替身坏了自己换一个（11-08 内测，HANDOVER §162）：对方 16:07 重连，主机这边新建的替身从第一招起放招全返回 false
-- （0/50、1/88、1/109），武器对、拔刀了、有这个技能、杀气满，"正在放"全是被动；同一个替身也锁不上、刀碰不到。
-- 后来再重连走"替身复用"，拿回来的还是这个坏的。结果：对方打我全判落空（§155 放不出 = 落空）。
-- 做法：远端的招在替身身上连续 N 次放不出、中间一次都没放出来过、跨了 SEC 秒以上 → 记一行诊断（G.puppetDiag），
-- 驱动里把它作废（藏起、永不复用，销毁会崩）、新建一个。每次连接最多 MAX 次，两次之间至少 GAP 秒（防"不是替身坏了"时来回换）。
-- 全局（主代码块 local 已满）
PHEAL = { N = 8, SEC = 3.0, GAP = 30.0, MAX = 3, fails = 0, since = nil, want = nil, at = nil, n = 0, diagKey = nil }

-- §237 替身被控住（冰冻 / 受击 / 眩晕 / 倒下）时放不出招、也不该跳：本地 AI 不知道替身在本机被你冻住了，照样发招和起跳。
-- 以前：冻住时连续放不出被 §162 当成"替身坏了"→ 作废（藏在原地、敌对阵营，锁得上）+ 新建一个没冻住的 → 对手像没被冻住，
-- 打完留下几个看不见的锁定点；空中同步还会对冻住的替身 LaunchCharacter（游戏的冰冻挡不住直接给速度）→ 冻住还能跳。
-- 父标签也算命中（Hitreact.State 含 Hitreact.State.Frozen 等受击状态）。同一次驱动内只问一次
-- 全局（主代码块 local 已满）
PUPCC = { TAGS = { "Hitreact.State", "CharacterState.StatusInfliction.Frost.Effect", "State.Stun", "CharacterState.Stun",
                   "CharacterState.Dead" }, key = nil, at = -1, hit = nil, skipped = 0, launchSkips = 0 }
-- 返回 被控住的标签名（第一个命中的）或 nil
function PUPCC.held(pup)
    if not valid(pup) then return nil end
    local k = pathOf(pup)
    if PUPCC.key ~= k or PUPCC.at ~= ST.ticks then
        local h = G.tagsMatching(pup, PUPCC.TAGS)
        PUPCC.key, PUPCC.at, PUPCC.hit = k, ST.ticks, (h and h[1]) or false
    end
    return PUPCC.hit or nil
end

-- 远端招在替身上放完一次：ok = 放出来了没有；has = 替身有没有这个技能（没有的不算替身坏了）
-- §227 冻住 / 眩晕时放不出是正常的，不算替身坏了（内测反馈 11-11"冰冻一次多一次空气人"：本地 AI 被你冻住后照样一直出招，
-- 冻满 3 秒 8 招 → 被当成坏了作废新建，旧的藏在原地就是一个能锁定的空气人）。连带把之前攒的计数清掉
-- §237 合并后改用 PUPCC.held（多认父标签 Hitreact.State 和 CharacterState.Dead），原 PHEAL.CC_TAGS 去掉
function PHEAL.note(pup, ok, has, name)
    if ok then PHEAL.fails, PHEAL.since = 0, nil; return end
    if not has then return end
    local cc = PUPCC.held(pup)
    if cc then                     -- §237 被控住放不出是正常的，不算坏（连续计数也清掉：解控后重新数）
        PUPCC.skipped = PUPCC.skipped + 1
        if PUPCC.skipped <= 5 or PUPCC.skipped % 50 == 0 then
            out("  替身被控住（%s）放不出 %s，不算替身坏了（§237，第 %d 次）", cc, name, PUPCC.skipped)
        end
        PHEAL.fails, PHEAL.since = 0, nil
        return
    end
    PHEAL.fails = PHEAL.fails + 1
    PHEAL.since = PHEAL.since or now()
    local key = pathOf(pup)
    if PHEAL.diagKey ~= key then      -- 每个替身第一次放不出就记一行状态（之后靠 failN 的那三行）
        PHEAL.diagKey = key
        out("  替身状态（第一次放不出 %s）：%s", name, G.puppetDiag(pup))
    end
    if PHEAL.want or PHEAL.fails < PHEAL.N or now() - PHEAL.since < PHEAL.SEC then return end
    if PHEAL.n >= PHEAL.MAX then
        if PHEAL.fails == PHEAL.N then out("!! 替身连续 %d 招放不出，但这次连接已经换过 %d 个替身，不再换", PHEAL.fails, PHEAL.n) end
        return
    end
    if PHEAL.at and now() - PHEAL.at < PHEAL.GAP then return end
    PHEAL.want = string.format("连续 %d 招放不出（%.1f 秒，最后一招 %s）", PHEAL.fails, now() - PHEAL.since, name)
end

-- 预防（猜测，没复现过）：坏掉的那个替身是新建出来后同一秒就被瞬移到 120 km 外、地形没加载的地方（§99 悬空），
-- 16:02 那次没扔远处的新替身是好的。新替身（按对象路径第一次见到算）在本机玩家身边先待 WARM 秒、动画跑起来，再去远处。
-- 只挡 > HOV.FAR 的远距离瞬移，近处跟随照常
PHEAL.WARM, PHEAL.born = 2.0, {}
function PHEAL.young(pup)
    local key = pathOf(pup)
    local t = PHEAL.born[key]
    if not t then
        PHEAL.born[key] = now()
        out("替身 %s 第一次要瞬移到远处：先在你身边待 %.0f 秒（§162）", short(key), PHEAL.WARM)
        return true
    end
    return now() - t < PHEAL.WARM
end

-- 新连接（对手断开后重连 / 换了对手）：次数重新算
function PHEAL.reset()
    PHEAL.fails, PHEAL.since, PHEAL.want, PHEAL.at, PHEAL.n = 0, nil, nil, nil, 0
end

-- 驱动里调（不在放招的调用栈里换替身：调用方放完招还要用 pup）
function PHEAL.step()
    if not PHEAL.want then return end
    local why = PHEAL.want
    PHEAL.want = nil
    local pup = puppet()
    if not valid(pup) or not MATCH.autoCreate then return end
    out("!! 替身坏了：%s；状态 %s → 作废，新建一个（这次连接第 %d 次）", why, G.puppetDiag(pup), PHEAL.n + 1)
    G.discardPuppet()
    MATCH.autoCreate()
    PHEAL.n, PHEAL.at, PHEAL.fails, PHEAL.since, PHEAL.diagKey = PHEAL.n + 1, now(), 0, nil, nil
end

-- §165.4 切刀斩到的时候，状态包里的 wc=（手上 WeaponConfig）还是切之前那把（w= 已经是新的），替身照它把刀又换回去 →
-- 切刀斩被打断、补放也放不出（11-08 双开：GA_Hun_HeiMoShang_SWT_C 先放出来，同一帧"替身换装 → 白影"）。
-- 按招名认出切到哪把（武器组里两格挑名字对得上的），1.5 秒内收到的 wc= 都按这把算
-- §166 切刀斩 = "切到这把并出招"：父类 BP_SwitchAttack_Base 的 K2_CanActivateAbility 调 BPL_PBZCombatUtils 的
-- Can Active Switch Attack（GetChangeWeaponAbilityWeapon 找这招属于武器组哪一格、和 GetCurrentWeapon 的当前序号比、
-- 再看切武器冷却），放出来后 Change Weapon By Ability 自己切过去。所以这把必须在**另一格**：§165.4 把它装进当前格，
-- 两格就只剩"当前格 = 这把、另一格 = 别的"，11-08 20:08–20:12 双开 13 次切刀斩里，切之前另一格恰好也是这把的 2 次
-- （风雷剑、黑魔伤）放出来了，其余全 false。现在改成装进另一格、当前格不动，让技能自己切
LO.SWT_ALIAS = { Chaos = { "CiGuHunDun" }, BronzeSword = { "TianXuanQingTongJian" }, Double = { "Double", "JueYing" },
                 ChiZheCanJian = { "ChiZheCanJian", "ChiZheZuiJian" }, ZhanMa = { "ZhanMaBlade" } }
-- 招名 → 用来认武器配置名的关键词：先查整段族名（ChiZheCanJian），再查第一段（ZiMingJian_New → ZiMingJian、
-- ShuangYue_DB → ShuangYue、Chaos_SwitchFormFire → Chaos 的别名）
function LO.swtKeys(n)
    local fam = n:match("^GA_Hun_(.-)_SWT")
    if not fam then return nil end
    local fam1 = fam:match("^([^_]+)") or fam
    return LO.SWT_ALIAS[fam] or LO.SWT_ALIAS[fam1] or (fam1 ~= fam and { fam, fam1 }) or { fam }
end

-- §166 把切刀斩那把装进替身武器组的另一格（当前格不动）。返回 另一格序号 或 nil, 原因
function LO.swtStage(pup, cfg)
    local slot = LO.slot()
    local cur = LO.curIndex(pup, slot)
    if not cur then return nil, "读不到当前序号" end
    local other = math.max(cur, 0) == 0 and 1 or 0
    local h = LO.hasOf(pup)
    if h[other] == cfg then return other end             -- §195 已经在另一格：不重建
    local ok, err = LO.setSlot(pup, slot, other, cfg)
    if not ok then return nil, err end
    h[other] = cfg
    LO.offKey = nil                 -- 另一格被改了：切完 / 没切成，LO.dressOff 都按对方的另一把重装
    return other
end

-- 返回 true = 已把这把装进另一格（之后放不出要调 LO.swtUnhold 让换装恢复）
function LO.swtPin(pup, n)
    local keys = LO.swtKeys(n)
    if not keys then return end
    -- 先看替身见过的两格；对方组里另一把可能从没拿过（11-08 实测白影），再查标准数值装备表的 30 级 / 铸魂配置、原配置
    local cands, G_ = {}, STD.GEAR and STD.GEAR.MAIN or {}
    local function add(c) if c then cands[#cands + 1] = c end end
    add(NET.rwcCur); add(NET.rwcOff); add(NET.rwc)
    for _, g in pairs(G_) do add(g.cfg) end
    for _, g in pairs(G_) do add(g.base) end
    for _, cfg in ipairs(cands) do do
        local sh = cfg and LO.short(cfg) or ""
        for _, k in ipairs(keys) do
            if sh:find(k, 1, true) then
                NET.rwcPin = { cfg = cfg, t = now() + 1.5 }
                NET.rwc = cfg
                local other, why = LO.swtStage(pup, cfg)
                ST.swtPin = (ST.swtPin or 0) + 1
                if other then
                    -- 技能切过去之前别让 LO.dress 把这把装进当前格 / 把另一格换回去（切过去后手上 = 这把，换装自然不动）
                    LO.swtHold = { cfg = cfg, t = now() + 1.0 }
                    if ST.swtPin <= 10 then out("  切刀斩 %s：%s 装进另一格（序号 %d），让技能自己切过去（第 %d 次）", n, sh, other, ST.swtPin) end
                    return true
                end
                -- 装不进另一格：退回 §165.4 的老办法（当前格直接换上）
                LO.swtHold = nil
                pcall(LO.dress, pup, getP1())
                if ST.swtPin <= 10 then out("  切刀斩 %s：另一格装不上（%s），当前格先换上 %s（第 %d 次）", n, tostring(why), sh, ST.swtPin) end
                return
            end
        end
    end end
end

function LO.swtUnhold() LO.swtHold = nil end

-- §166 换装要不要先等切刀斩自己切过去：手上还不是那把、1 秒内 → 先不动
function LO.swtHolding(pup)
    local h = LO.swtHold
    if not h then return false end
    if now() >= h.t or LO.heldConfig(pup) == h.cfg then LO.swtHold = nil; return false end
    return true
end

-- §243 放招计数：真技能（ASC 返回 true / 技能本来就在跑）和"只播动作 / 补特效"的画面兜底分开。
-- 以前 okFire 一个布尔混着用，日志里"返回=true"分不出是真放出来还是 §239 / §242 的 playOn 兜底。
-- 主代码块 local 已满，挂全局；activateOnPuppet 里只置 local real，结束时交给 FIREK.note。
FIREK = { real = 0, visual = 0, queued = 0, fail = 0, LOGS = 40, logs = 0 }
function FIREK.note(name, how, ok, real, pending)
    if not ok then FIREK.fail = FIREK.fail + 1; return end
    if pending then FIREK.queued = FIREK.queued + 1; return end
    if real then FIREK.real = FIREK.real + 1; return end
    FIREK.visual = FIREK.visual + 1
    if FIREK.logs < FIREK.LOGS then
        FIREK.logs = FIREK.logs + 1
        out("  §243 画面兜底（只有动作 / 特效，没有技能、没有伤害）：%s（%s）", name, how)
    end
end
function FIREK.report()
    local n = FIREK.real + FIREK.visual + FIREK.queued + FIREK.fail
    if n == 0 then return end
    out("      §243 放招计数：真技能 %d，画面兜底 %d，等前摇 %d，失败 %d", FIREK.real, FIREK.visual, FIREK.queued, FIREK.fail)
end

-- §243 Snap：游戏里 A_Snap / B_Snap 是"闪避后的追击"。资产名字表（11-11，names.py）：
--   基类 BP_LightAttack_Snap_Base / BP_HeavyAttack_Snap_Base 的 K2_CanActivateAbility 里除锁定 /
--   Is Snap Target Near（Min Snap Range）外还调用 IsAbilityActive —— 要先有一次闪避（AdvancedDash）在放。
--   18:24 实测：HasLockTarget=true 仍然 false（1.5 米贴脸），§189 换 _Dash 是另一招，用户否掉。
-- 做法：原招先放；放不出 → 先放同武器 / 默认闪避（没输入时游戏自己往后撤，同时拉开 Min Snap Range 的距离），
--   0.20 秒后再放 Snap 本身（PRETRY）。闪避也放不出就按失败算，不再换 Dash。
-- §255 激活时要拉子技能、替身拿这把武器时技能表里没有的（K2_GiveAbility 先给上）
-- §343 原来这里有 C_ToZui → GA_Hun_Tang_C：那是 ToZui 的父类（资产 Super），不是子技能，给不上也不用给（每次"找不到类"）；
--   ToZui 放出 AM_Hun_Tang_C_Failed 的真正原因是替身没大招充能，改由 ULT.PAT 认出、AIR.fire 先补充能
CHILD_GA = {}
-- §343 名字里没有 Drunk、但要 HuaQianXiao.ZuiJian 的痴者残剑招（资产 ActivationRequiredTags，11-16 离线解）→ 兜底动作（蒙太奇名）
ZUIJIAN_GA = { GA_Hun_ChiZheCanJian_C_Zui_C = "Hun_ChiZheCanJian_Drunk_Unique_Skill_Montage",
               GA_Hun_AdvancedDash_ChiZheCanJian_Zui_Far_C = "Hun_ChiZheCanJian_Drunk_Dodge_R_Far_Montage",
               GA_Hun_SpecialDash_ChiZheCanJian_Zui_C = false }
SNAP = { DELAY = 0.20, LOGS = 30, logs = 0,
         MIN_DEFAULT = 300.0, PAD = 80.0, BACK_GAP = 0.12, BACK_TRIES = 3, info = {},
         DODGE = { Double = "GA_Hun_AdvancedDash_Double_C", Jade = "GA_Hun_AdvancedDash_Double_Jade_C",
                   Double_Jade = "GA_Hun_AdvancedDash_Double_Jade_C", ShuangYue = "GA_Hun_AdvancedDash_ShuangYue_C",
                   Long = "GA_Hun_AdvancedDash_Long_C", ChiRen = "GA_Hun_AdvancedDash_Long_C",
                   ChiZheCanJian = "GA_Hun_AdvancedDash_ChiZheCanJian_C", SnakeDual = "GA_Hun_AdvancedDash_SnakeDual_C",
                   Tang = "GA_Hun_AdvancedDash_Tang_C", HeiMoShang = "GA_Hun_AdvancedDash_Tang_C",
                   SlitheringSword = "GA_Hun_AdvancedDash_SlitheringSword_C",
                   -- §249 报告 §3.4：SNAP.DODGE 以前只有上面 11 项，其余有 Snap 的武器都回落到唐刀冲刺。
                   -- 只有 8 个族有专属 AdvancedDash；下面这些用自己武器的 A_Dash / B_Dash（§248 偃月刀已用 B_Dash）。
                   -- 它们不是中性闪避，是武器冲刺；放不出会照旧往 DEFAULT / UNARMED 退。
                   FengLeiJian = "GA_Hun_FengLeiJian_A_Dash_C", BaiShanFengLeiJian = "GA_Hun_FengLeiJian_A_Dash_C",
                   BaiYing = "GA_Hun_BaiYing_A_Dash_C", DualHook = "GA_Hun_DualHook_A_Dash_C",
                   XieShan = "GA_Hun_XieShan_A_Dash_C", GuiTouBlade = "GA_Hun_GuiTouBlade_A_Dash_C",
                   Horizontal = "GA_Hun_Horizontal_A_Dash_C", Iron = "GA_Hun_Iron_A_Dash_C",
                   Jigsaw = "GA_Hun_Jigsaw_A_Dash_C", PoJun = "GA_Hun_PoJun_A_Dash_C",
                   BronzeSword = "GA_Hun_BronzeSword_A_Dash_C", YanYueDao = "GA_Hun_YanYueDao_B_Dash_C",
                   WoodenSword = "GA_Hun_WoodenSword_A_Dash_C", Young = "GA_Hun_Young_A_Dash_C",
                   YuuBlade = "GA_Hun_YuuBlade_A_Dash_C", ZhanMa = "GA_Hun_ZhanMa_A_Dash_C",
                   ZiMingJian = "GA_Hun_ZiMingJian_New_A_Dash_C" },
         DEFAULT = "GA_Hun_AdvancedDash_Tang_C", UNARMED = "GA_Hun_AdvancedDash_Unarmed_C" }
-- §248 蛇双 R 架势的 Snap：`GA_Hun_SnakeDual_RA_Snap` / `RB_Snap` 自己不生成判定，激活时拉子技能
-- （_tools/gasgraph/逐招展开.md：RA_Snap → GA_Hun_Tang_A_Snap；RB_Snap → GA_Hun_Iron_B_Snap，不是唐刀 B）。
-- 替身拿蛇双时技能表里只有 SnakeDual 族（11-11 21:35 日志：SnakeDual×36、Tang 0、Iron 0），子技能不在 → 激活 false。
-- 放之前先 K2_GiveAbility 补上；然后照 §245 等 Thrown 标签，按子技能自己的 Min Snap Range 退开再放。
SNAP.SUB = { GA_Hun_SnakeDual_RA_Snap_C = "GA_Hun_Tang_A_Snap_C",
             GA_Hun_SnakeDual_RB_Snap_C = "GA_Hun_Iron_B_Snap_C" }
-- §348 技能 CDO 的 Target Handler = Targeting.Handler.CombatSnap（再加旋转修正 RM_FocusTargetOrInput）的招：出手方向 / 飞出去的东西
-- 按瞄准组件里的目标走。真人那边是游戏的软锁定自己挑（场上就你一个敌人）；替身的瞄准组件平时是空的（§119 火枪、§189 Snap 同一个原因），
-- 没目标、也没有输入 → 不转向，血滴子 A / AA 链子、玉双环 DB 飞轮扔空（11-16 假对手 + 两开：替身动作都播了，0 伤害）。
-- 名单 = 11-16 离线扫 pbz_abilities 全部 GA 的名字表里带 Targeting.Handler.CombatSnap 的 53 个（_tools/gasgraph/bp_decode.py），
-- 外加圣母邪扇 DB：不是 CombatSnap，但元素招是 Spawner 在目标处生成，子弹选目标 XieShan_LockThenNearest（先锁定、再最近）。
-- 放之前和 Snap 一样让替身瞄准组件锁你（LO.snapLock；对方没锁你就 1.5 秒后撤，ZMX.step）
SNAP.CSNAP = {
    GA_GlobalActionAbility_ShunSha_C_C = true, GA_Hun_BEx_Common_FemaleDoll_TieChiSan_01_C = true, GA_Hun_BEx_Common_MadDoctor_01_C = true,
    GA_Hun_GuiTouBlade_B_Hold_C = true, GA_Hun_HuoLiuXing_Execution_C = true, GA_Hun_Jade_AAAB_C = true,
    GA_Hun_Jade_AAABB_C = true, GA_Hun_Jade_AAB_C = true, GA_Hun_Jade_AABB_C = true,
    GA_Hun_Jade_BBBB_C = true, GA_Hun_Jade_B_Dash_C = true, GA_Hun_Jade_C_Range_C = true,
    GA_Hun_Jade_DB_C = true, GA_Hun_Jade_SWT_C = true, GA_Hun_LuanYing_AAAB_C = true,
    GA_Hun_LuanYing_AAB_C = true, GA_Hun_LuanYing_AB_C = true, GA_Hun_LuanYing_B_C = true,
    GA_Hun_LuanYing_BB_C = true, GA_Hun_LuanYing_BBB_C = true, GA_Hun_LuanYing_Buff_C = true,
    GA_Hun_LuanYing_CA_C = true, GA_Hun_LuanYing_P2_AAAB_C = true, GA_Hun_LuanYing_P2_AAB_C = true,
    GA_Hun_LuanYing_P2_AB_C = true, GA_Hun_LuanYing_P2_B_C = true, GA_Hun_LuanYing_P2_BB_C = true,
    GA_Hun_LuanYing_P2_BBB_C = true, GA_Hun_LuanYing_P2_Buff_C = true, GA_Hun_LuanYing_P2_CA_C = true,
    GA_Hun_LuanYing_SWT_P1_C = true, GA_Hun_LuanYing_SWT_P2_C = true, GA_Hun_ShachiHook_Drag_C = true,
    GA_Hun_ShuangYue_DB_C = true, GA_Hun_ShuangYue_PBB_C = true, GA_Hun_XieShan_AAAAA_C = true,
    GA_Hun_ZiMingJian_New_AAAAA_C = true, GA_Hun_ZiMingJian_New_AABB_C = true, GA_Hun_ZiMingJian_New_A_Dash_C = true,
    GA_Hun_ZiMingJian_New_BBB_C = true, GA_Hun_ZiMingJian_New_C_C = true, GA_Hun_ZiMingJian_New_CC_C = true,
    GA_Hun_ZiMingJian_New_CCC_C = true, GA_Hun_ZiMingJian_New_DB_C = true, GA_Hun_ZiMingJian_New_SWT_Power_C = true,
    GA_LionHead_FireBall_C = true, GA_Weapon_SnakeDual_Evolution_C = true, GA_XuKongHuaShan_Skill_C = true,
    GA_XueDiZi_A_C = true, GA_XueDiZi_AA_C = true, GA_XueDiZi_AAA_C = true,
    GA_XueDiZi_Execution_C = true, GA_XueDiZi_SpecialAttack_C = true,
    GA_Hun_XieShan_DB_C = true }
SNAP.csN = 0
-- §248 G.airOf 返回的是 { falling, vz, g, jumpZ, mode } 表（不是布尔）。以前 `if not G.airOf(pup)` 永远为假，
-- 空中切刀斩 / 蛇双空中唐刀把"有 CharacterMovement"当成"离地"（11-11 21:37 日志 `离地=table: …`）。
function SNAP.air(pup)
    if not G.airOf then return false end
    local ok, a = pcall(G.airOf, pup)
    if not ok then return false end
    if type(a) == "table" then return a.falling == true end
    return a == true
end
function SNAP.log(fmt, ...)
    SNAP.logs = SNAP.logs + 1
    if SNAP.logs <= SNAP.LOGS then out(fmt, ...) end
end
-- §245 开关：net/snap_range_off.txt 存在 = 不按 Min Snap Range 退（回到 §243 的闪避 + 等前摇）
SNAP.OFF = (NET_DIR or "net") .. "/snap_range_off.txt"
function SNAP.rangeOff()
    local f = io.open(SNAP.OFF, "r")
    if f then f:close(); return true end
    return false
end
-- §245 这一招的 Min Snap Range（游戏自己的距离门槛，只读技能 CDO；读不到按 MIN_DEFAULT）。
-- 名字表：BP_*Attack_Snap_Base.K2_CanActivateAbility 拿 Vector_Distance2D 和 Min Snap Range 比大小。
function SNAP.minRange(pup, name)
    local key = name
    local c = SNAP.info[key]
    if c then return c end
    local m = nil
    if LO.snapInfo then
        local ok, r = pcall(LO.snapInfo, pup, name)
        if ok and type(r) == "table" then m = tonumber(r.min) end
    end
    if m then SNAP.info[key] = m end      -- 只缓存读到的；读不到下次再读（技能可能还没给）
    if SNAP.logs < SNAP.LOGS then
        SNAP.log("  §245 Snap %s：技能 CDO 的 Min Snap Range = %s%s", name,
            m and string.format("%.0f cm", m) or "读不到", m and "" or "（按默认 300 cm）")
    end
    return m
end
-- 替身和你（2D）的距离；读不到返回 nil
function SNAP.dist(pup)
    local p1 = getP1()
    if not (valid(pup) and valid(p1)) then return nil end
    local a = try("snap pup loc", function() return pup:K2_GetActorLocation() end)
    local b = try("snap p1 loc", function() return p1:K2_GetActorLocation() end)
    if not (a and b) then return nil end
    return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2), a, b
end
-- 站到 Snap 的范围外：沿"你 → 替身"的方向，把替身放到离你 want cm 的地方（只动 XY，Z 不变）。
-- 以前只放一次同武器闪避，往后撤多远不知道，1.5 米贴脸经常还不够 Min Snap Range → 0/2。
function SNAP.backOff(pup, want)
    local d, a, b = SNAP.dist(pup)
    if not (d and a and b) then return false end
    if d >= want then return true end
    local dx, dy = a.X - b.X, a.Y - b.Y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1.0 then dx, dy, len = 1.0, 0.0, 1.0 end      -- 完全重叠：往 +X 退
    local at = { X = b.X + dx / len * want, Y = b.Y + dy / len * want, Z = a.Z }
    local ok = false
    if G.teleportTo then
        local okT, r = pcall(G.teleportTo, pup, at, yawOf and yawOf(pup) or 0.0)
        ok = okT and r ~= false
    end
    if not ok then
        local okS = pcall(function() pup:K2_SetActorLocation(at, false, {}, true) end)
        ok = okS
    end
    SNAP.log("  §245 Snap：离你 %.0f cm < Min Snap Range %.0f → 退到 %.0f cm（%s）", d, want, want, ok and "成功" or "失败")
    return ok
end
-- 这把武器先试哪几个闪避：同族 → 唐刀（日志里最常见的默认闪避）→ 空手。都不行返回 nil
function SNAP.cands(n)
    local fam = n:match("^GA_Hun_(%w+)_") or ""
    local list, seen = {}, {}
    for _, d in ipairs({ SNAP.DODGE[fam], SNAP.DEFAULT, SNAP.UNARMED }) do
        if d and not seen[d] then seen[d] = true; list[#list + 1] = d end
    end
    return list
end
-- 用 activateOnPuppet 里的 fire（已经处理了技能表 / 给技能）；返回放出来的闪避类名或 nil
function SNAP.dodge(pup, use, fireFn, map)
    for _, d in ipairs(SNAP.cands(use)) do
        if LO.removeGE then pcall(LO.removeGE, pup, CHG.DASH_CD) end          -- §159 冲刺冷却挡着
        if map[d] or LO.give(pup, d, map) then
            if fireFn(d) then
                SNAP.log("  §243 Snap %s：先放同武器闪避 %s 成功（没输入时游戏自己往后撤）", use, d)
                return d
            end
        end
    end
    return nil
end

-- §248 放不出时的出招门槛探针（只读，每个招名一次，最多 6 条）：名字表分不出授予 / 要求，这里读技能 CDO 上
-- 真正的 ActivationRequiredTags / ActivationBlockedTags / Source·Target Required·BlockedTags。放在放招失败之后，
-- 不改变任何行为；下一轮按读出来的标签再改。关键字 `§248 出招门槛`。
QPROBE = { n = 0, MAX = 6, done = {},
           FIELDS = { "ActivationRequiredTags", "ActivationBlockedTags", "SourceRequiredTags", "TargetRequiredTags",
                      "SourceBlockedTags", "TargetBlockedTags" } }
function QPROBE.note(pup, name, map, why)
    if QPROBE.done[name] or QPROBE.n >= QPROBE.MAX then return end
    QPROBE.done[name] = true
    QPROBE.n = QPROBE.n + 1
    local cls = map and map[name]
    local path = cls and pathOf(cls) or nil
    local s
    if path and G.cdoTags then
        local ok, r = pcall(G.cdoTags, path, QPROBE.FIELDS)
        s = (ok and r) or ("读不到 " .. tostring(r))
    else
        s = path and "没有 G.cdoTags" or "替身技能表里没有这个技能（没有类路径）"
    end
    out("§248 出招门槛 %s（%s）：%s", name, why, s)
end

-- 在替身身上激活技能（回放、网络共用）。sub = 本次会话的"武器不匹配替代表"
-- 返回 okFire, real, pending：real = 技能真的激活了（不是只播动作）；pending = 已排 PRETRY，等前摇再放
activateOnPuppet = function(pup, n, sub, how)
    local asc, map = ascOf(pup), puppetAbMap(pup)
    local function fire(name)
        local cls = map[name]
        -- 2026-11-05 10:23 崩溃同类风险（见 pbz_game.lua healClass）：缓存的类可能已被回收，失效就重建技能表再查一次
        if cls and not valid(cls) then
            ST.abMapKey = nil
            map = puppetAbMap(pup)
            cls = map[name]
        end
        if not (cls and valid(asc) and valid(cls)) then return false end
        local ok, r = pcall(function() return asc:TryActivateAbilityByClass(cls, true) end)
        return ok and r == true
    end
    local use = sub[n] or n
    local real, pending = false, false
    local staged = false
    -- §248 蛇双 R*_Snap 的子技能：技能表里没有就先给（K2_GiveAbility；给完 map 已更新，fire 直接能查到）
    local snapSub = SNAP.SUB[use]
    if snapSub and not map[snapSub] then
        LO.give(pup, snapSub, map, true)
        ST.snapSub = (ST.snapSub or 0) + 1
        if map[snapSub] then
            if ST.snapSub <= 10 then
                out("  §248 蛇双 Snap %s：先给子技能 %s（它自己不生成判定，激活时要拉这个子技能）", use, snapSub)
            end
        elseif ST.snapSub <= 10 then
            out("  §248 蛇双 Snap %s：子技能 %s 给不上（给技能失败 / 找不到类）", use, snapSub)
        end
    end
    -- §255 别的武器也有"激活时拉子技能"的：赤蛰残剑 C_ToZui 子技能是 GA_Hun_Tang_C（资产逐招展开 2509），替身拿赤蛰残剑时没有 → 先给
    local childSub = CHILD_GA[use]
    if childSub and not map[childSub] then
        LO.give(pup, childSub, map, true)
        ST.childSub = (ST.childSub or 0) + 1
        if ST.childSub <= 10 then
            out("  §255 %s：先给子技能 %s（%s）", use, childSub, map[childSub] and "给上了" or "给不上")
        end
    end
    -- §243 补放 / 等前摇 / 蓄力松手 不再重新"装进另一格"：18:23:58 实测补放时又换了一次武器，
    -- 把已经放出来的切刀斩技能顶掉，然后 ANIM 判"没动作"直接播蒙太奇（只画面、没伤害）。
    local replaying = how:find("补放", 1, true) or how:find("等前摇", 1, true) or how:find("蓄力松手", 1, true)
    if use:find("_SWT", 1, true) and not replaying then
        local okP, r = pcall(LO.swtPin, pup, use)
        staged = okP and r == true
        if staged then ST.abMapKey = nil; map = puppetAbMap(pup) end      -- §166 另一格换了武器，技能表跟着变
    end
    -- §189 Snap（离得远时冲上去的那一刀，A_Snap / B_Snap / RA_Snap …）：基类 BP_*Attack_Snap_Base 的 K2_CanActivateAbility
    -- 要瞄准组件里锁着目标、而且离目标够远。替身的瞄准组件平时是空的（§119）→ 一次没放出来过（11-08–11-09 双刃 A_Snap 0/11、
    -- B_Snap 0/9；本机自己"自动出招"按类放也全是 false）。放之前先让替身瞄准组件锁你
    local snap = use:find("_Snap", 1, true) ~= nil
    local snapRetry = snap and how:find("等前摇", 1, true) ~= nil
    if snap then LO.snapLock(pup)
    elseif SNAP.CSNAP and SNAP.CSNAP[use] and LO.snapLock then        -- §348 CombatSnap 招：瞄准组件锁你，出手方向 / 飞出去的东西才对着你
        local okL, r = pcall(LO.snapLock, pup)
        SNAP.csN = SNAP.csN + 1
        if SNAP.csN <= 10 then
            out("  §348 %s 是 CombatSnap 招：放之前替身瞄准组件锁你 %s（第 %d 次）", use,
                okL and (r and "锁上了" or "没锁上") or ("出错 " .. tostring(r)), SNAP.csN)
        end
    end
    -- §255 刺骨混沌形态走游戏自己的切形态招（见 CHR）：要的形态不在就先放下一步的真切形态招，等标签出现再放这一招
    if use:find("^GA_Hun_Chaos_") and CHR and not LO.chaosOff() and not CHR.off() then
        local okL, q = pcall(CHR.lead, pup, use, how, map, fire, n, sub)
        if okL and q then return true, false, true end
        if not okL then out("  §255 混沌切形态出错：%s", tostring(q)) end
        if CHR.unmute then pcall(CHR.unmute, pup) end      -- §255.1 原招要放了：中间步的 0 攻击恢复
    end
    -- §242 刺骨混沌的形态招：先把替身就绪成这一招要的形态（Buff + 特效 + 这一形态的 Hold 升级）再放。
    -- 以前只在放不出之后才补形态（B 链 / B_Hold 的 IceHold 不到位 → 一次都放不出）；现在放之前就挂好。
    local chaosForm = use:match("^GA_Hun_Chaos_.+_(Fire)_C$") or use:match("^GA_Hun_Chaos_.+_(Ice)_C$") or use:match("^GA_Hun_Chaos_.+_(Physics)_C$")
    if chaosForm and not LO.chaosOff() then LO.chaosForm(pup, chaosForm) end
    -- §245 偃月刀 B_Snap_Reinforced：资产要 CharacterState.AbilityState.YanYueDao.SpecialSkillCanReinforce（GE 给）。
    -- §243 是放不出之后才补 GE，补完还是 Snap 的距离门槛挡着；现在放之前补一次（CHG.UPG 后面仍会在失败后补 + 再 fire）。
    if use == "GA_Hun_YanYueDao_B_Snap_Reinforced_C" and CHG.UPG and CHG.UPG[use] and not LO.movesOff() then
        for _, ge in ipairs(CHG.UPG[use]) do pcall(LO.applyGE, pup, ge, "替身补武器升级（预）：" .. use) end
    end
    -- §348 破军 SWT_02 / 紫冥剑 SWT 被拔刀攻击天赋挡着：放的那一刻先摘，放完挂回（LO.drawTalentOff）
    local drawOff = LO.drawTalentOff and LO.DRAWBLK and LO.DRAWBLK[use] and select(2, pcall(LO.drawTalentOff, pup, use)) == true
    local okFire = fire(use)
    if drawOff then pcall(LO.drawTalentBack, pup) end
    if okFire then real = true end
    -- §248 偃月刀强化 Snap：资产（逐招展开）要 CharacterState.AbilityState.YanYueDao.Reinforced.OnDash（冲刺中）。
    -- §245 只补了 CanReinforced GE + Snap 距离，11-11 21:38 实测 2 次（离你 185 / 187 cm，Min Snap Range 450）
    -- 退开后仍然 false，OnDash 从没出现过。现在：先放偃月刀的冲刺（B_Dash；替身没有就 K2_GiveAbility），
    -- 等 OnDash 标签真的出现，再按 §245 的距离门槛退开 / 放强化 Snap。等不到就记一行，按失败算。
    if use == "GA_Hun_YanYueDao_B_Snap_Reinforced_C" and not LO.movesOff() and not pending then
        local retry = how:find("等前摇", 1, true) ~= nil
        local function onDash()
            if not G.tagsMatching then return false end
            local ts = G.tagsMatching(pup, { "CharacterState.AbilityState.YanYueDao.Reinforced.OnDash" })
            return ts and #ts > 0
        end
        local hasTag = onDash()
        if not hasTag and not retry then
            local dash = "GA_Hun_YanYueDao_B_Dash_C"
            if map[dash] or LO.give(pup, dash, map) then
                if LO.removeGE then pcall(LO.removeGE, pup, CHG.DASH_CD) end     -- §159 冲刺冷却
                if fire(dash) then
                    local q = PRETRY.push(pup, n, sub, how, 0.20, "偃月刀强化 Snap 等 OnDash",
                        { cond = onDash, tries = 8, gap = 0.15 })
                    if q then
                        okFire, pending = true, true
                        ST.yydDash = (ST.yydDash or 0) + 1
                        if ST.yydDash <= 10 then
                            out("  §248 偃月刀强化 Snap %s：先放冲刺 %s，等 OnDash 标签出现再放", use, dash)
                        end
                    end
                else
                    ST.yydDashFail = (ST.yydDashFail or 0) + 1
                    if ST.yydDashFail <= 10 then
                        out("  §248 偃月刀强化 Snap %s：冲刺 %s 放不出（OnDash 到不了）", use, dash)
                    end
                end
            end
        elseif hasTag then
            local canRange = not SNAP.rangeOff()
            local minR = canRange and (SNAP.minRange(pup, use) or SNAP.MIN_DEFAULT) or nil
            local d = canRange and SNAP.dist(pup) or nil
            if minR and d and d < minR + SNAP.PAD and SNAP.backOff(pup, minR + SNAP.PAD) then
                local q = PRETRY.push(pup, n, sub, how, SNAP.BACK_GAP, "偃月刀强化 Snap 等距离",
                    { cond = function()
                          local dd = SNAP.dist(pup)
                          return dd ~= nil and dd >= minR + SNAP.PAD * 0.5
                      end, tries = SNAP.BACK_TRIES, gap = SNAP.BACK_GAP })
                if q then okFire, pending = true, true end
            else
                okFire = fire(use)
                if okFire then real = true end
            end
            if not okFire and not pending and retry then
                ST.yydFail = (ST.yydFail or 0) + 1
                if ST.yydFail <= 10 then
                    out("  §248 偃月刀强化 Snap：OnDash 在，退开后还是放不出（离你 %s）",
                        d and string.format("%.0f cm", d) or "?")
                end
            end
        elseif retry then
            ST.yydTagFail = (ST.yydTagFail or 0) + 1
            if ST.yydTagFail <= 10 then
                out("  §248 偃月刀强化 Snap：放了冲刺、等了 8×0.15 秒也没等到 OnDash 标签，按失败算")
            end
        end
    end
    -- §223.7 / §239 刺骨混沌的形态招（GA_Hun_Chaos_*_Fire / _Ice / _Physics）与切形态招
    if not okFire and not LO.chaosOff() then
        local swTarget = use:match("^GA_Hun_Chaos_SwitchForm(Fire)")
            or use:match("^GA_Hun_Chaos_SwitchForm(Ice)")
            or (use:find("^GA_Hun_Chaos_SwitchFormPhysic") and "Physics")
        if swTarget then
            -- §345 切刀斩版（*_SWT）要的是自己这个形态，不是前一个（见 CHR.need）
            local prereq = use:find("_SWT_C$") and swTarget
                or (swTarget == "Fire" and "Ice") or (swTarget == "Ice" and "Physics") or (swTarget == "Physics" and "Fire")
            if prereq then LO.chaosForm(pup, prereq) end
            okFire = fire(use)
            if okFire then real = true end
            if okFire then
                -- 放出来了，也要保证目标形态的 Buff / 特效在（§242：游戏自己的切形态 GE 也可能被门槛撤掉）
            else
                local okF = LO.chaosForm(pup, swTarget)
                local mName = LO.CHAOS_MONT[swTarget]
                local mAsset = mName and (montageByName(mName) or LO.loadObject(LO.CHAOS_MONT_PATH[swTarget]))
                local okM = mAsset and playOn(pup, mAsset)
                okFire = (okF or okM) and true or false
                ST.chaosSwTry = (ST.chaosSwTry or 0) + 1
                if ST.chaosSwTry <= 10 then
                    out("  §239 混沌切形态 %s 放不出 → 兜底切至%s形态(GE=%s, 动作=%s)（第 %d 次）",
                        use, swTarget, tostring(okF), tostring(okM), ST.chaosSwTry)
                end
            end
        end
    end
    -- §242 切形态招放出来之后：不管游戏自己有没有挂目标形态的 GE，都按目标形态补一次（Buff / 特效 / Hold 升级）
    do
        local sw = use:match("^GA_Hun_Chaos_SwitchForm(Fire)") or use:match("^GA_Hun_Chaos_SwitchForm(Ice)")
            or (use:find("^GA_Hun_Chaos_SwitchFormPhysic") and "Physics")
        if sw and okFire and not LO.chaosOff() then LO.chaosForm(pup, sw) end
    end
    if not okFire then
        local form = use:match("^GA_Hun_Chaos_.+_(Fire)_C$") or use:match("^GA_Hun_Chaos_.+_(Ice)_C$") or use:match("^GA_Hun_Chaos_.+_(Physics)_C$")
        if form then
            local okF = LO.chaosForm(pup, form)
            okFire = fire(use)
            if okFire then real = true end
            ST.chaosTry = (ST.chaosTry or 0) + 1
            if ST.chaosTry <= 20 or ST.chaosTry % 50 == 0 then
                out("  混沌 %s 放不出 → 替身换成%s形态再放：%s（第 %d 次）", use, form,
                    not okF and "形态效果挂不上" or okFire and "放出来了" or "还是放不出", ST.chaosTry)
            end
        end
    end
    -- §223.8 鬼魅闪身诊断（只读 + 喂方向重试一次）：替身放不出时记下标签 / 技能来源，按对方闪避的方向喂摇杆再放一次
    if not okFire and DIAG and DIAG.JDIAG and use == DIAG.JDIAG.NAME then
        local okD, r = pcall(DIAG.JDIAG.pupFail, pup, function() return fire(use) end)
        if okD and r then okFire, real = true, true end
    end
    -- §229 完美闪避反击（红光 *PerfectDodge*）/ 鬼魅闪身：替身放不出 → 走玩家那条路（输入组件）再放，并记闪避帧
    if not okFire and DIAG and DIAG.XACT and DIAG.XACT.want(use) then
        local okX, r = pcall(DIAG.XACT.retry, pup, use, map[use], fire)
        if okX and r then okFire, real = true, true end
    end
    -- v0.23.4 替代不能一直粘着：2026-11-04 23:46:58 双刃切刀斩第一次被换成斩马刀的成功了，之后 13/14 次都是直接放斩马刀的、
    -- 失败也不回头试原招。替代失败（或替身后来换上了对方的武器）就回到原招，原招成了把替代清掉
    if not okFire and sub[n] then
        if fire(n) or (LO.give(pup, n, map) and fire(n)) then
            out("  原招 %s 现在放得出了，不再用替代 %s", n, sub[n])
            sub[n], use, okFire, real = nil, n, true, true
        end
    end
    -- v0.17.0：先给替身这个技能再试（替身已经换成对方的武器时，这才是正路），不行再走下面的替代兜底
    if not okFire and not sub[n] and LO.give(pup, n, map) then
        okFire = fire(n)
        if okFire then real = true end
    end
    -- §189 不是招式的技能（GA_Hun_ 以外：武器 / 影之武装升级给的）在替身身上已经在跑 → 算放出来了。妖锯 GA_YaoJu_MonsterErosion_BP
    -- 给上就自己常驻等事件（0/8，诊断里"正在放"有它）；铁矿拳套 ShaChiAttackMultiple 是替身自己的蓄力招连带出来的
    if not okFire and not use:find("^GA_Hun_") and LO.activeInstance(pup, use) then
        okFire, real = true, true
        ST.alreadyOn = (ST.alreadyOn or 0) + 1
        if ST.alreadyOn <= 10 then out("  %s 替身身上已经在跑，算放出来（第 %d 次）", use, ST.alreadyOn) end
    end
    -- §92.7 对方放得出、替身放不出：多半是武器升级（GE 给的 WeaponUpgrade 标签）替身没有。补上再放一次
    -- §242 已经补过也要再 fire 一次：以前 CHG.upgrade 对补过的返回 false，整个 fire 被跳过（B_Hold_Ice 就卡在这）
    if not okFire and CHG.UPG[n] and use ~= "GA_Hun_YanYueDao_B_Snap_Reinforced_C" then
        CHG.upgrade(pup, n, CHG.UPG[n])
        okFire = fire(n)
        if okFire then real = true end
        out("  补了武器升级之后 %s %s", n, okFire and "放出来了" or "还是放不出")
        -- §242 GE 挂上到标签生效可能差一帧（B_Hold_Ice / 偃月刀强化闪反）：等 0.2 秒再试一次
        if not okFire and not tostring(how):find("等前摇", 1, true) then PRETRY.push(pup, n, sub, how, 0.2, "补武器升级等标签") end
    end
    -- §159 冲刺类（AdvancedDash / SpecialDash / StanceDash …）都受冲刺冷却 GE_DashCooldown（Dash.Cooldown 标签）挡：替身的上一下
    -- 冲刺比对方晚到（延迟 / 补放），对方的下一下来时替身还在冷却。对方已经冲出来了 → 清掉替身的冷却再放一次
    if not okFire and use:match("%u%l+Dash_") and LO.removeGE(pup, CHG.DASH_CD) then    -- 不含 A_Dash 这类冲刺后的攻击
        okFire = fire(use)
        if okFire then real = true end
        if okFire then
            ST.dashCd = (ST.dashCd or 0) + 1
            if ST.dashCd <= 10 or ST.dashCd % 20 == 0 then out("  清掉冲刺冷却后 %s 放出来了（第 %d 次）", use, ST.dashCd) end
        end
    end
    -- v0.6.2 实测：替身没装备对应武器时同名技能激活恒为 false。武器同步（v0.7.1）之后这里基本不触发，
    -- 留作兜底：换成替身手上武器的同一招（同样的 A/AA/B... 后缀）
    if not okFire and not sub[n] then
        local suffix = n:match("^GA_Hun_%w+_(.+)$")
        local suffixes = suffix and { suffix, (suffix:gsub("_Draw", "")) } or {}
        for _, sfx in ipairs(suffixes) do
            for _, w in ipairs({ "ChiRen", "Long", "ZhanMa" }) do
                local alt = "GA_Hun_" .. w .. "_" .. sfx
                if not okFire and alt ~= n and map[alt] and fire(alt) then
                    sub[n], use, okFire, real = alt, alt, true, true
                    out("  武器不匹配：%s 激活失败，改用替身武器的 %s", n, alt)
                end
            end
        end
    end
    -- v0.23.6 上一招还没放完就挡住了新招：2026-11-05 00:27:54–00:28:03 架势 3 次放不出，诊断都是"手上武器 绝影、有这个技能"，
    -- 动作还停在上一招 AM_Hun_Double_B / 铁矿拳套 GpA 上。对方那边已经出了新招，说明他的上一招已经收了——替身跟着收：
    -- 立刻停掉当前动作（cutMontage，不淡出）再放一次
    if not okFire and montageOf(pup) ~= "" then
        local stopped = cutMontage(pup)
        if stopped and fire(use) then
            okFire, real = true, true
            ST.cutForNew = (ST.cutForNew or 0) + 1
            if ST.cutForNew <= 10 or ST.cutForNew % 20 == 0 then
                out("  上一招 %s 还没收，停掉后 %s 放出来了（第 %d 次）", stopped, use, ST.cutForNew)
            end
        end
    end
    -- 2026-11-05 10:52:31 回放：架势放不出时动作已经是空的（上面停动作不管用），但上一招 GA_Hun_DualHook_DB_C 的技能还挂着。
    -- 同一个道理：对方已经出了新招，上一招在他那边结束了——把替身还挂着的招式技能取消掉再放一次（G.cancelMoves）
    if not okFire then
        local gone = G.cancelMoves(pup)
        if #gone > 0 and fire(use) then
            okFire, real = true, true
            ST.cancelForNew = (ST.cancelForNew or 0) + 1
            if ST.cancelForNew <= 10 or ST.cancelForNew % 20 == 0 then
                out("  上一招的技能 %s 还挂着，取消后 %s 放出来了（第 %d 次）", table.concat(gone, ","), use, ST.cancelForNew)
            end
        end
    end
    -- §157 切刀斩（*_SWT）和对方的 w= 同一个包到：替身换装每 8 帧才轮一次，这时手上还是上一把，SWT 放不出。
    -- 先当场换装再放一次（11-08 双开实测：GA_Hun_Double_SWT_C 比"替身换装 → 绝影"早约 1 秒，放不出）
    if not okFire and use:match("_SWT_C$") then
        LO.swtUnhold()                  -- §166 装进另一格也没放出来：放开换装，走老办法（当前格也换上）
        local p1 = getP1()
        if valid(p1) and pcall(LO.dress, pup, p1) and fire(use) then
            okFire, real = true, true
            ST.dressForSwt = (ST.dressForSwt or 0) + 1
            if ST.dressForSwt <= 10 then out("  切刀斩 %s 先换装再放，放出来了（第 %d 次）", use, ST.dressForSwt) end
        elseif valid(p1) and not tostring(how):find("等前摇", 1, true) then
            -- SetCurrentWeapon/SetSlotWeapon 往往要到下一帧才让 CanActivate 看到新武器；同帧失败不能直接记落空。
            pending = PRETRY.push(pup, n, sub, how, 0.20, "切刀斩等换装生效") or pending
        end
    end
    -- §230 冲刺版切刀斩（GA_Hun_Tang_SWT_Dash / GA_Hun_Long_SWT_Dash，标签 Ability.Action.Hun.Weapon.Switch.Dash）：日志里替身放了 48 次全 false，
    --   普通版 *_SWT_C 能放。两者都继承 BP_SwitchAttack_Base，它的 K2_CanActivateAbility 按变体标签（Switch.Normal / Switch.Dash）分支、
    --   还调 IsAbilityActive（名字表）——冲刺版要在冲刺技能还在放时才放得出（玩家是闪避中按切换）。本地 AI 只发这一招不发冲刺，
    --   真人那边冲刺事件和它到得有先后。替身先放这把武器的冲刺（清冲刺冷却），紧接着再放一次。不进替代表，下次照样先试原招
    if not okFire and use:match("_SWT_Dash_C$") then
        local fam = use:match("^GA_Hun_(%w+)_SWT_Dash_C$")
        local dash = fam and "GA_Hun_AdvancedDash_" .. fam .. "_C"
        ST.swtDash = ST.swtDash or { ok = 0, bad = 0 }
        local dashOk = false
        if dash and (map[dash] or LO.give(pup, dash, map)) then
            dashOk = fire(dash)
            if not dashOk and LO.removeGE(pup, CHG.DASH_CD) then dashOk = fire(dash) end    -- §159 冲刺冷却挡着
        end
        if dashOk then
            if LO.swtCooldown then pcall(LO.swtCooldown, pup) end      -- §245 换武器冷却（Can Active Switch Attack）
            okFire = fire(use)
            if okFire then real = true end
            -- §242 冲刺技能刚放出来，Switch.Dash 要它还在放才认（同一帧可能还没进 Active）：等 0.18 秒再试
            if not okFire and not tostring(how):find("等前摇", 1, true) then
                pending = PRETRY.push(pup, n, sub, how, 0.18, "冲刺版切刀斩等冲刺") or pending
                ST.swtDash.wait = (ST.swtDash.wait or 0) + 1
            end
        end
        if okFire then ST.swtDash.ok = ST.swtDash.ok + 1 else ST.swtDash.bad = ST.swtDash.bad + 1 end
        local s = ST.swtDash
        if s.ok + s.bad <= 10 or (s.ok + s.bad) % 20 == 0 then
            out("  §230 冲刺版切刀斩 %s：先放冲刺 %s %s → %s（成功 %d / 失败 %d）", use, tostring(dash),
                dashOk and "成功" or "失败", okFire and "放出来了" or "还是放不出", s.ok, s.bad)
        end
    end
    -- §189 收刀状态的招（*Unarm*：空手冲刺 / 连续冲刺）对方是收着刀放的，替身却拿着刀 → 放不出（11-09 AdvancedDash_Unarmed、
    -- AdvancedDash_Continuous_02_Unarm，对方 arm=false、替身拔刀）。先收刀再放
    local unarm = use:find("Unarm", 1, true) ~= nil
    if not okFire and unarm and LO.armed(pup) == true then
        local cwc = rawProp(pup, "Character Weapons Component")
        if valid(cwc) and pcall(function() cwc:SetArmed(LO.slot(), false) end) and fire(use) then
            okFire, real = true, true
            ST.unarmForNew = (ST.unarmForNew or 0) + 1
            if ST.unarmForNew <= 10 then out("  替身拿着刀，收刀后 %s 放出来了（第 %d 次）", use, ST.unarmForNew) end
        end
    end
    -- §155 对方出了攻击招、替身却还收着刀（对方 arm= 还没跟上 / 从没拔过刀直接出招）：先拔刀再放一次
    if not okFire and not unarm and LO.armed(pup) == false then
        local cwc = rawProp(pup, "Character Weapons Component")
        if valid(cwc) and pcall(function() cwc:SetArmed(LO.slot(), true) end) and fire(use) then
            okFire, real = true, true
            ST.armForNew = (ST.armForNew or 0) + 1
            if ST.armForNew <= 10 then out("  替身收着刀，拔刀后 %s 放出来了（第 %d 次）", use, ST.armForNew) end
        end
    end
    -- §243 Snap（闪避后追击）：不再换 _Dash（§189 / §239 的替换是另一招，用户 11-11 明确否掉）。
    -- §245 根因：这个基类的 K2_CanActivateAbility 拿 2D 距离和 Min Snap Range 比（太近不放，Snap 是远距离扑上去的那一刀）。
    -- 1.5 米固定木桩正好在门槛里 → 4 招 0/2；PvP 3–10 米（00:33 / 01:19 / 14:12）能放。所以放之前先量距离：
    --   距离 < Min Snap Range + PAD → 沿"你 → 替身"退到范围外，0.12 秒后再放；读不到 Min Snap Range 才退回老的"同武器闪避"。
    if not okFire and snap and not snapRetry and not snapSub and how:find("远端#", 1, true) and not how:find("补放", 1, true)
        and not PRETRY.off() then
        -- net/snap_range_off.txt 存在 = 不按 Min Snap Range 退，回到 §243 的"同武器闪避 + 等前摇"
        local canRange = not SNAP.rangeOff()
        local minR = canRange and (SNAP.minRange(pup, use) or SNAP.MIN_DEFAULT) or nil
        local d = canRange and SNAP.dist(pup) or nil
        local backed = false
        if minR and d and d < minR + SNAP.PAD then backed = SNAP.backOff(pup, minR + SNAP.PAD) end
        local queued = false
        local why = "Snap等距离"
        if backed then
            queued = PRETRY.push(pup, n, sub, how, SNAP.BACK_GAP, why,
                { cond = function() local dd = SNAP.dist(pup); return dd ~= nil and dd >= minR + SNAP.PAD * 0.5 end,
                  tries = SNAP.BACK_TRIES, gap = SNAP.BACK_GAP })
        else
            local dodge = SNAP.dodge(pup, use, fire, map)
            why = "Snap先闪避 " .. tostring(dodge)
            queued = dodge and PRETRY.push(pup, n, sub, how, SNAP.DELAY, why)
        end
        if queued then
            okFire, pending = true, true
            ST.snapQueued = (ST.snapQueued or 0) + 1
            if ST.snapQueued <= 20 then
                out("  §243/§245 Snap %s 放不出（离你 %s，Min Snap Range %s）→ %s，%.2f 秒后再放 Snap（第 %d 次）",
                    use, d and string.format("%.0f cm", d) or "?", minR and string.format("%.0f cm", minR) or "关（snap_range_off）",
                    backed and "退到范围外" or why, backed and SNAP.BACK_GAP or SNAP.DELAY, ST.snapQueued)
            end
        else
            ST.snapNoDodge = (ST.snapNoDodge or 0) + 1
            if ST.snapNoDodge <= 20 then
                out("  §243 Snap %s 放不出；退不开 / 同武器闪避放不出 / 排不进重试（pretry_off）→ 不换 Dash，按失败算（第 %d 次）", use, ST.snapNoDodge)
            end
        end
    elseif not okFire and snap and snapRetry and not snapSub then
        ST.snapRetryFail = (ST.snapRetryFail or 0) + 1
        if ST.snapRetryFail <= 20 then
            local d = SNAP.dist(pup)
            out("  §243 Snap %s 退开 / 闪避后还是放不出（离你 %s）（第 %d 次）", use,
                d and string.format("%.0f cm", d) or "?", ST.snapRetryFail)
        end
    end
    -- §239 特殊状态招式修复（赤者残剑醉/微醺、乱莺P2、蛇双R架势/空中唐刀、切刀斩Dash/Air等）
    if not okFire and not LO.movesOff() then
        -- A. 赤者残剑（ChiZheCanJian）：Tipsy 需 PreZui，Drunk 需 Zui
        -- §343 醉剑 C（C_Zui）/ 醉剑远闪避（AdvancedDash_..._Zui_Far）/ 醉剑冲刺（SpecialDash_..._Zui）名字里没有 Drunk，
        --   但资产 ActivationRequiredTags 同样是 HuaQianXiao.ZuiJian（GE_ChiZheCanJian_Zui 给 ZuiJian + PreZui）→ 一起补
        if use:find("ChiZheCanJian") then
            local isTipsy = use:find("Tipsy")
            local isDrunk = use:find("Drunk") or ZUIJIAN_GA[use] ~= nil
            if isTipsy or isDrunk then
                local ge = isTipsy and "/PBZCombatAsset/ActorData/Players/Hun/Weapon/ChiZheCanJian/GE/State/GE_ChiZheCanJian_Prezui.GE_ChiZheCanJian_Prezui_C"
                    or "/PBZCombatAsset/ActorData/Players/Hun/Weapon/ChiZheCanJian/GE/State/GE_ChiZheCanJian_Zui.GE_ChiZheCanJian_Zui_C"
                LO.applyGE(pup, ge, "替身醉酒状态")
                okFire = fire(use)
                if okFire then real = true end
                if not okFire then
                    local mSuffix = use:match("ChiZheCanJian_(.+)_C$")
                    local mName = ZUIJIAN_GA[use] or (mSuffix and ("Hun_HuaQianXiao_" .. mSuffix .. "_Montage"))
                    local mAsset = mName and (montageByName(mName) or LO.loadObject("/PBZCombatAsset/ActorData/Players/Hun/Montage/ChiZheCanJian/" .. mName .. "." .. mName))
                    if mAsset and playOn(pup, mAsset) then okFire = true end
                end
                if okFire then
                    ST.chiZheTry = (ST.chiZheTry or 0) + 1
                    if ST.chiZheTry <= 10 then out("  §239 赤者残剑 %s 状态补全/兜底成功（第 %d 次）", use, ST.chiZheTry) end
                end
            end
        end

        -- B. 乱莺（LuanYing P2）：需 GE_LuanYing_Buff_P2
        if not okFire and use:find("LuanYing.*P2") then
            if LO.ensureCombat then pcall(LO.ensureCombat, pup) end
            if LO.applyGE then pcall(LO.applyGE, pup, "/PBZCombatAsset/ActorData/Players/Hun/Weapon/LuanYing/GameplayEffects/GE_LuanYing_Buff_P2.GE_LuanYing_Buff_P2_C", "替身乱莺P2状态") end
            okFire = fire(use)
            if okFire then real = true end
            if not okFire then
                local mSuffix = use:match("LuanYing_(.+)_C$")
                local mName = mSuffix and ("Hun_LuanYing_Attack_" .. mSuffix .. "_Montage")
                local mAsset = mName and (montageByName(mName) or LO.loadObject("/PBZCombatAsset/ActorData/Players/Hun/Montage/LuanYing/" .. mName .. "." .. mName))
                if mAsset and playOn(pup, mAsset) then okFire = true end
            end
            if okFire then
                ST.luanYingP2Try = (ST.luanYingP2Try or 0) + 1
                if ST.luanYingP2Try <= 10 then out("  §239 乱莺P2 %s 补全状态/兜底成功（第 %d 次）", use, ST.luanYingP2Try) end
            end
        end

        -- C. 蛇双（SnakeDual）：ReleaseAttack（R*）及 Air_*_Tang
        -- §242 资产名字表：所有 R* / Air_*_Tang 都要 CharacterState.AbilityState.SnakeDual.Thrown（短剑已经投出去）。
        -- §245 19:09:54 实测：GA_Hun_SnakeDual_DA_C 真的放出来了（"正在放"里有它），但 0.2 秒后 Thrown 还没到，
        -- 目标招还是 false；而且动作兜底把 okFire 置 true，重试日志看起来像"放出来了"，实际 0 伤害。
        -- 现在：投剑后排带 cond 的重试，等到 Thrown 标签真的出现再放（最多 8 次 / 0.15 秒一次）；
        -- 空中唐刀还要 CanAirSnap（空中拔刀斩的门槛，不是"离地"就行），先起跳再等标签。
        if not okFire and use:find("SnakeDual") then
            local isR = use:find("SnakeDual_R") ~= nil
            local isAir = use:find("Air") ~= nil
            local needThrown = isR or (isAir and use:find("Tang") ~= nil)
            local retry = tostring(how):find("等前摇", 1, true) ~= nil
            local hasThrown = false
            if needThrown and G.tagsMatching then
                local ts = G.tagsMatching(pup, { "CharacterState.AbilityState.SnakeDual.Thrown" })
                hasThrown = ts and #ts > 0
            end
            if needThrown and not hasThrown and not retry then
                local thr = "GA_Hun_SnakeDual_DA_C"
                local okT = fire(thr) or (LO.give(pup, thr, map) and fire(thr))
                if not okT then
                    thr = "GA_Hun_SnakeDual_DB_C"
                    okT = fire(thr) or (LO.give(pup, thr, map) and fire(thr))
                end
                if okT then
                    local q = PRETRY.push(pup, n, sub, how, 0.15, "蛇双先投短剑 " .. thr,
                        { cond = function()
                              local ts = G.tagsMatching and G.tagsMatching(pup, { "CharacterState.AbilityState.SnakeDual.Thrown" })
                              return ts and #ts > 0
                          end, tries = 8, gap = 0.15 })
                    if q then
                        okFire, pending = true, true
                        ST.snakeThrow = (ST.snakeThrow or 0) + 1
                        if ST.snakeThrow <= 10 then out("  §245 蛇双 %s 要 Thrown：先投短剑 %s，等到 Thrown 再放（第 %d 次）", use, thr, ST.snakeThrow) end
                    end
                elseif ST.snakeNoThrow == nil or ST.snakeNoThrow <= 10 then
                    ST.snakeNoThrow = (ST.snakeNoThrow or 0) + 1
                    out("  §245 蛇双 %s：短剑 DA / DB 都放不出（投不出去，Thrown 不会有）", use)
                end
            end
            if not okFire and not pending and isAir and not retry then
                -- 空中唐刀：先起跳；起来后等 CanAirSnap（这个标签不是起跳就有，落下来那一段才给）。
                -- 已经在空中、标签也在 → 不用排，直接往下 fire。
                local function airReady()
                    if not SNAP.air(pup) then return false end
                    if not G.tagsMatching then return true end
                    local ts = G.tagsMatching(pup, { "CharacterState.AirState.CanAirSnap" })
                    return (not ts) or #ts > 0
                end
                if not airReady() and G.launch then
                    pcall(G.launch, pup, { X = 0.0, Y = 0.0, Z = 300.0 })
                    local q = PRETRY.push(pup, n, sub, how, 0.30, "蛇双空中等 CanAirSnap",
                        { cond = airReady, tries = 6, gap = 0.15 })
                    if q then okFire, pending = true, true end
                end
            end
            if not okFire and not pending and snapSub then
                -- §248 蛇双 R*_Snap 的子技能本身也是 Snap（BP_*Attack_Snap_Base）：Thrown 到了以后还要在
                -- 子技能自己的 Min Snap Range 外（读不到退回外层 RA_Snap 的 / 默认 300）。太近先退，退完再放。
                if not SNAP.rangeOff() then
                    local minR = SNAP.minRange(pup, snapSub) or SNAP.minRange(pup, use) or SNAP.MIN_DEFAULT
                    local d = SNAP.dist(pup)
                    if d and d < minR + SNAP.PAD and SNAP.backOff(pup, minR + SNAP.PAD) then
                        local q = PRETRY.push(pup, n, sub, how, SNAP.BACK_GAP, "蛇双 Snap 等距离",
                            { cond = function()
                                  local dd = SNAP.dist(pup)
                                  return dd ~= nil and dd >= minR + SNAP.PAD * 0.5
                              end, tries = SNAP.BACK_TRIES, gap = SNAP.BACK_GAP })
                        if q then
                            okFire, pending = true, true
                            if SNAP.logs < SNAP.LOGS then
                                SNAP.log("  §248 蛇双 Snap %s：子技能 %s 要 Min Snap Range %.0f，离你 %.0f → 退到范围外再放",
                                    use, snapSub, minR, d)
                            end
                        end
                    end
                end
            end
            if not okFire and not pending then
                okFire = fire(use)
                if okFire then real = true end
                if not okFire and isR then
                    local mSuffix = use:match("SnakeDual_R(.+)_C$")
                    local mName = mSuffix and ("Hun_SnakeDual_Variant_Release_Attack_" .. mSuffix .. "_Montage")
                    local mAsset = mName and (montageByName(mName) or LO.loadObject("/HuaShira/Animation/Hero/Hun/SH_Sources/SnakeDual/Variant/" .. mName .. "." .. mName))
                    if mAsset and playOn(pup, mAsset) then
                        okFire = true
                        ST.snakeAnimOnly = (ST.snakeAnimOnly or 0) + 1
                        if ST.snakeAnimOnly <= 10 then out("  §242 蛇双 %s 只补播了动作（没有技能、没有伤害），Thrown 等不到（第 %d 次）", use, ST.snakeAnimOnly) end
                    end
                elseif not okFire and isAir and use:find("Tang") then
                    local mSuffix = use:match("SnakeDual_Air_(.+)_Tang_C$")
                    local mName = mSuffix and ("AM_Hun_Tang_Air_" .. mSuffix .. "_Montage")
                    local mAsset = mName and (montageByName(mName) or LO.loadObject("/PBZCombatAsset/ActorData/Players/Hun/Montage/TangBlade/Default/Air/" .. mName .. "." .. mName))
                    if mAsset and playOn(pup, mAsset) then
                        okFire = true
                        ST.snakeAnimOnly = (ST.snakeAnimOnly or 0) + 1
                        if ST.snakeAnimOnly <= 10 then out("  §242 蛇双 %s 只补播了动作（没有技能、没有伤害），Thrown 等不到（第 %d 次）", use, ST.snakeAnimOnly) end
                    end
                end
                if okFire then
                    ST.snakeTry = (ST.snakeTry or 0) + 1
                    if ST.snakeTry <= 10 then out("  §239 蛇双 %s 激活/兜底成功（第 %d 次）", use, ST.snakeTry) end
                end
            end
        end

        -- D. 切刀斩（SWT）：Air_SWT、SWT_Dash、PoJun_SWT_02、ZiMingJian_New_SWT
        -- §248 资产（逐招展开）：GA_Hun_Tang_Air_SWT 要 CharacterState.AirState.CanAir（不是 CanAirSnap，后者是
        -- 蛇双空中唐刀 / 空中拔刀斩那一类）；GA_Hun_Tang_SWT_Dash 要 Action.Hun.Weapon.Switch.Dash（冲刺中切武器）。
        -- 11-11 21:37 日志：Air_SWT 的 `离地=table: …` 是把 airOf 的表当布尔（永远真），等的是 CanAirSnap；
        -- SWT_Dash 冲刺技能确实在放（"正在放"里有 GA_Hun_AdvancedDash_Tang_C）仍然 false → 0.35 秒一次不够。
        -- 现在：Air_SWT 等"真离地 + CanAir"；SWT_Dash 先冲刺，再等冲刺技能还在放（或 Switch.Dash 标签）逐次重试。
        if not okFire and not pending and (use:find("Air_SWT") or use:find("SWT_Dash") or use:find("PoJun_SWT") or use:find("ZiMingJian_New_SWT")) then
            local retry = tostring(how):find("等前摇", 1, true) ~= nil
            local waitAir = false
            if use:find("Air_SWT") and G.airOf then
                local function airReady()
                    if not SNAP.air(pup) then return false end
                    if not G.tagsMatching then return true end
                    local ts = G.tagsMatching(pup, { "CharacterState.AirState.CanAir" })
                    return (not ts) or #ts > 0
                end
                if not airReady() then
                    if G.launch and not retry then
                        pcall(G.launch, pup, { X = 0.0, Y = 0.0, Z = 300.0 })
                        local q = PRETRY.push(pup, n, sub, how, 0.30, "空中切刀斩等 CanAir",
                            { cond = airReady, tries = 6, gap = 0.15 })
                        if q then okFire, pending = true, true end
                        waitAir = true
                    elseif SNAP.air(pup) then
                        -- 已经离地、标签还是读不到：别再等，直接试一次（标签读不到不能把真招永远挡住）
                        ST.swtAirNoTag = (ST.swtAirNoTag or 0) + 1
                        if ST.swtAirNoTag <= 10 then
                            out("  §248 空中切刀斩 %s：已离地但读不到 CanAir 标签，直接试", use)
                        end
                    else
                        ST.swtAirFail = (ST.swtAirFail or 0) + 1
                        if ST.swtAirFail <= 10 then
                            out("  §248 空中切刀斩 %s：等不到 CanAir（离地=%s），按失败算", use, tostring(SNAP.air(pup)))
                        end
                        waitAir = true
                    end
                end
            end
            if not waitAir and not pending then
                if use:find("ZiMingJian") and LO.snapLock then
                    pcall(LO.snapLock, pup)
                end
                -- §255 GA_Hun_Tang_SWT_Dash 的 ActivationRequiredTags = CharacterState.Talent.EnableDrawAttack（11-12 §248 出招门槛实测），
                -- 标签只由天赋 GE_Talent_EnableDrawAttack 给；对方放得出这招就一定点了这个天赋 → 替身补上（每个替身一次）
                if use:find("SWT_Dash") and LO.drawTalent then pcall(LO.drawTalent, pup) end
                if LO.swtUnhold then pcall(LO.swtUnhold) end
                if LO.swtCooldown then pcall(LO.swtCooldown, pup) end      -- §245 换武器冷却（Can Active Switch Attack）
                local p1 = getP1()
                if valid(p1) and LO.dress then pcall(LO.dress, pup, p1) end
                okFire = fire(use)
                if okFire then real = true end
                if not okFire and use:find("SWT_Dash") and not retry then
                    -- §248 冲刺中切武器：等冲刺技能真的在放（或 Switch.Dash 标签在）再放，8×0.15 秒，别同一帧判死。
                    local fam = use:match("^GA_Hun_(%w+)_SWT_Dash_C$")
                    local dash = fam and "GA_Hun_AdvancedDash_" .. fam .. "_C"
                    local function dashOn()
                        if dash and LO.activeInstance and LO.activeInstance(pup, dash) then return true end
                        if G.tagsMatching then
                            local ts = G.tagsMatching(pup, { "Action.Hun.Weapon.Switch.Dash" })
                            return ts and #ts > 0
                        end
                        return false
                    end
                    local q = PRETRY.push(pup, n, sub, how, 0.25, "冲刺切刀斩等冲刺中",
                        { cond = dashOn, tries = 8, gap = 0.15 })
                    if q then okFire, pending = true, true end
                    ST.swtDashRetry = (ST.swtDashRetry or 0) + 1
                    if ST.swtDashRetry <= 10 then
                        out("  §248 冲刺切刀斩 %s：冲刺中重试（冲刺 %s，Switch.Dash 标签=%s）", use, tostring(dash),
                            tostring(G.tagsMatching and (#(G.tagsMatching(pup, { "Action.Hun.Weapon.Switch.Dash" }) or {}) > 0)))
                    end
                end
                if not okFire and not pending then
                    local fam = use:match("^GA_Hun_(%w+)_")
                    if fam then
                        local mName = fam .. "_SWT_Montage"
                        local mAsset = montageByName("Hun_" .. mName) or montageByName("AM_Hun_" .. mName)
                        if mAsset and playOn(pup, mAsset) then okFire = true end
                    end
                end
                if okFire and not pending then
                    ST.swtFixTry = (ST.swtFixTry or 0) + 1
                    if ST.swtFixTry <= 10 then out("  §239 切刀斩 %s 补放/兜底成功（第 %d 次）", use, ST.swtFixTry) end
                end
            end
        end

        -- E. LongounterB 动作兜底
        if not okFire and use == "GA_Hun_Long_CounterB_C" then
            local mAsset = montageByName("Hun_Long_CounterB_Montage") or LO.loadObject("/HuaShira/Animation/Hero/Hun/SH_Sources/AHuaBlade/Hun_Long_CounterB_Montage.Hun_Long_CounterB_Montage")
            if mAsset and playOn(pup, mAsset) then okFire = true end
            if okFire then
                ST.longCounterTry = (ST.longCounterTry or 0) + 1
                if ST.longCounterTry <= 10 then out("  §239 长刀反击 %s 兜底成功（第 %d 次）", use, ST.longCounterTry) end
            end
        end
    end
    local tag = pending and "（已排闪避后重放）" or (okFire and not real and "（画面兜底）" or "")
    pupAction(use, how .. " 返回=" .. tostring(okFire) .. tag)
    if FIREK then FIREK.note(use, how, okFire, real, pending) end     -- §243 真技能 / 画面兜底分开计数
    if okFire and not pending and HLFX then pcall(HLFX.cast, "pup", pup, use, now()) end      -- §246 火流星 DB：对比探针 + 可选补特效
    if not pending and tostring(how):match("^远端#%d+$") then PHEAL.note(pup, okFire, map[use] ~= nil, use) end     -- §162 只算第一次放（不算补放 / 续放）
    -- v0.23.4 放不出来时记下替身当时的状态（每招前 3 次），下一轮按这个找原因：手上武器、技能在不在、杀气、在放什么
    if not okFire then
        ST.failN = ST.failN or {}
        ST.failN[use] = (ST.failN[use] or 0) + 1
        if use:match("_Stance_C$") then LO.offKey, LO.has = nil, nil end     -- v0.26.1 架势放不出：另一格可能被蓝图改回去了，下一轮重装（§76）
        -- §166 切刀斩装进另一格还是放不出：剩下的门槛多半是切武器冷却（Can Active Switch Attack 里 GetCurrentChangeWeaponCooldown），
        -- 记一次武器组件上和冷却 / 切武器有关的函数，下次按它查
        if staged and not ST.swtDiag then
            ST.swtDiag = true
            local cwc = rawProp(pup, "Character Weapons Component")
            local fs = {}
            for _, pat in ipairs({ "Cooldown", "ChangeWeapon", "SwitchWeapon" }) do
                for _, f in ipairs(valid(cwc) and LO.funcsLike(cwc, pat) or {}) do fs[#fs + 1] = f end
            end
            out("  切刀斩 %s 装进另一格也放不出；当前序号 %s；武器组件相关函数：%s", use, tostring(LO.curIndex(pup, LO.slot())),
                #fs > 0 and table.concat(fs, " ") or "（没有）")
        end
        if ST.failN[use] <= 3 then
            local act = {}
            for a in pairs(activeAbilities(pup) or {}) do act[#act + 1] = a end
            -- §155 替身身上各武器族的招各有几个、武器组当前序号（查"主机这边替身有对方的武器、却没有这把武器的招"）
            local fams, famList = {}, {}
            for a in pairs(map) do
                local f = a:match("^GA_Hun_(%w+)_[AB]")
                if f then fams[f] = (fams[f] or 0) + 1 end
            end
            for f, c in pairs(fams) do famList[#famList + 1] = f .. "×" .. c end
            local cwc, idx = rawProp(pup, "Character Weapons Component"), "?"
            if valid(cwc) then pcall(function() idx = tostring(cwc:GetCurrentWeaponIndex(LO.slot(), false)) end) end
            out("  替身技能按武器族：%s；武器组当前序号 %s；替身技能表 %d 个", table.concat(famList, " "), idx, (function() local k = 0; for _ in pairs(map) do k = k + 1 end; return k end)())
            out("  !! 替身放不出 %s（第 %d 次）：手上武器 %s（对方 %s），拔刀 %s（对方 %s），替身有这个技能=%s，杀气 %s/%s，动作 %s，正在放 %s",
                use, ST.failN[use], LO.short(LO.heldConfig(pup) or "?"), LO.short(NET.rwc or "?"), tostring(LO.armed(pup)),
                tostring(NET.rarm), tostring(map[use] ~= nil),
                tostring(attrOf(pup, "Shachi")), tostring(attrOf(pup, "Shachi_Max")), tostring(montageOf(pup)),
                #act > 0 and table.concat(act, ",") or "无")
        end
    end
    -- §248 这几类放不出时读一次技能 CDO 的标签门槛（只读，每个招名一次）：下一轮按真实的 Required / Blocked 改。
    if not okFire and QPROBE and (use:find("_SWT") or use:find("_Snap") or use:find("Air_") or use:find("ToZui") or use:find("^GA_Hun_Chaos_")) then
        QPROBE.note(pup, use, map, "放不出")
    end
    return okFire, real, pending
end

local function replayStep()
    if not REP.on then return end
    local pup = puppet()
    if not valid(pup) then stopReplay("替身没了"); return end
    local fr = REP.frames
    local t = now() - REP.t0
    if t > fr[#fr].t then stopReplay("播完"); return end
    while REP.i < #fr and fr[REP.i + 1].t <= t do REP.i = REP.i + 1 end
    local a, b = fr[REP.i], fr[math.min(REP.i + 1, #fr)]
    local span = b.t - a.t
    local k = span > 0 and math.max(0, math.min(1, (t - a.t) / span)) or 0
    local pa, pb = toWorld(a), toWorld(b)
    local pos = { X = pa.X + (pb.X - pa.X) * k, Y = pa.Y + (pb.Y - pa.Y) * k, Z = pa.Z + (pb.Z - pa.Z) * k }
    local vel = span > 0 and { X = (pb.X - pa.X) / span, Y = (pb.Y - pa.Y) / span } or { X = 0, Y = 0 }
    REP.lastErr = drivePuppet(pup, pos, vel, REP.ayaw + a.yaw)

    if REP.useAb then
        -- 两次 tick 之间可能跨过好几帧，跨过的帧里的技能都要补上
        while REP.abI < REP.i do
            REP.abI = REP.abI + 1
            for n in fr[REP.abI].ab:gmatch("[^,]+") do activateOnPuppet(pup, n, REP.sub, "回放技能") end
        end
        return
    end

    if a.m ~= REP.lastM then
        REP.lastM = a.m
        if a.m ~= "" then
            local asset = montageByName(a.m)
            if asset and playOn(pup, asset) then pupAction(a.m, "回放")
            else out("  !! 回放动画失败: %s", a.m) end
        end
    end
end

return {
    toggleRecord = toggleRecord,
    replayable = replayable,
    recordStep = recordStep,
    loadRecording = loadRecording,
    stopReplay = stopReplay,
    startReplay = startReplay,
    replayStep = replayStep,
    activateOnPuppet = activateOnPuppet,
}
end
