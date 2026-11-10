-- PBZ_MP 观战原型（HANDOVER §141 第 0 步）：不碰网络，验证"一台电脑上同时驱动两个替身互打 + 藏起本地角色 + 镜头挂上去"。
-- 小键盘 / 开关，小键盘 . 换动作来源（AI 对打 / 录像包，§141 第 1 步），小键盘 * 换镜头（侧面中点 → 跟 A → 跟 B → 自由视角：鼠标转、WASD 飞、Shift 加速）。
-- 两个替身 A / B 各自生成（SpawnActor 玩家类 + AIController，和 createPuppet 一样），不占 ST.secondPawn，对战用的代码不会碰它们。
-- 动作来源：rec\spec_a.txt / rec\spec_b.txt 有就按录制回放（F7 录两段、把 rec\rec_*.txt 改名过来），没有就用本地 AI（§75 LocalAi.cs）那套：两人都换绝影，连段 + 武器技随机出。
-- A 是敌方阵营、B 是玩家阵营，互相打得到；两边都挂 GE_LockHealth、血量低了补满 —— 出伤害、有受击动作，但谁都不死。
-- 第 1 步起血量 / 受击改按状态包写，这里的本机伤害只是原型里用来看受击动作的。
--
-- 用法（main.lua）：ST.spec = require("pbz_spec")({ out = out, ST = ST, MATCH = MATCH, G = G, activate = activateOnPuppet,
--   isAttack = isAttackAbility, loadRecording = loadRecording, recDir = REC_DIR, LO = LO,
--   replayable = replayable, playNamed = playNamed, netCmd = netuiCmd, readKV = fileReadKV, writeFile = fileWrite,
--   rulesFile = NET.RULES_FILE, flash = netuiFlash, NET = NET })

return function(ctx)
local out, ST, MATCH, G = ctx.out, ctx.ST, ctx.MATCH, ctx.G
local valid, try, rawProp, now, pathOf, short = G.valid, G.try, G.rawProp, G.now, G.pathOf, G.short
local getP1, getP1PC = G.getP1, G.getP1PC

local FRIEND, FOE = "Faction.Player", "Faction.Enemy"
-- main.lua 传进来的函数缺了不报错就静默不干活（19:03 实测：netCmd 是 nil，断开 / 换人命令全没发）。缺了记一行，check_lua 认这行
for _, k in ipairs({ "activate", "playNamed", "replayable", "netCmd", "flash", "mapGo", "readKV", "writeFile", "hostDist", "toHost", "travelling", "notice" }) do
    if type(ctx[k]) ~= "function" then out("!! 观战：main.lua 没传 %s", k) end
end
local SP = {
    on = false, gen = 0, side = {}, store = {}, cam = 1, camActor = nil, lastLogic = 0.0, p1Saved = nil,
    AHEAD = 500.0,          -- 场地中心：玩家正前方多远（18:46 断魂山实测 9 米外是悬崖，两人一生成就掉下去）
    GAP = 400.0,            -- 开场两人相距
    FALL = 800.0,           -- 比开场位置低这么多 = 掉下去了，放回开场位置
    SINK = 300.0,           -- §141.14 联机观战：替身比包里的高度低这么多 = 掉穿地面了，拉回
    TP_NEAR = 50.0, TP_FAR = 100.0,  -- §168.5 联机观战：离主机超过 50 米先走游戏传送过去再开始看；看着看着主机跑出 100 米，停下传过去再接着看
    LOAD_WAIT = 15.0,       -- §168.6 开始看之前最多等场地地面加载这么多秒
    REACH = 230.0,          -- 脚本对打：走到这么近就出招
    CAM_SIDE = 650.0, CAM_UP = 230.0, CAM_BACK = 420.0, CAM_PAD = 40.0,
    TICK = 1 / 30,
}
local CAM_NAMES = { "侧面中点", "跟 A（看向 B）", "跟 B（看向 A）", "自由视角（鼠标转、WASD 飞、Shift 加速）" }
local FREE = 4
local FREE_SPEED, FREE_FAST = 900.0, 2700.0          -- 自由视角飞行速度（厘米 / 秒），按住 Shift 用快的

local function LO_short(path) return path and (path:match("([^.]+)$") or path) or "?" end
local function loc(a) return try("spec loc", function() return a:K2_GetActorLocation() end) end
local function d2(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end

-- 【适配】SpawnActor(玩家1 的类) + SpawnActor(AIController) + Possess；藏起来的旧的复用（玩家类角色销毁会崩，v0.11.0）
local function spawnOne(i, pos)
    local p1 = getP1()
    local st = SP.store[i]
    local pup, ctl
    if st and valid(st.pup) then
        pup, ctl = st.pup, st.ctl
        pcall(function() pup:SetActorHiddenInGame(false) end)
        pcall(function() pup:SetActorEnableCollision(true) end)
        local cm = rawProp(pup, "CharacterMovement")
        if valid(cm) then pcall(function() cm:SetMovementMode(1, 0) end) end
        pcall(function() pup:K2_SetActorLocation(pos, false, {}, true) end)
    else
        local okC, cls = pcall(function() return p1:GetClass() end)
        local world = try("spec world", function() return p1:GetWorld() end)
        if not (okC and valid(cls) and valid(world)) then return nil end
        pup = try("spec spawn", function() return world:SpawnActor(cls, pos, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }) end)
        if not valid(pup) then return nil end
        local aic = StaticFindObject("/Script/AIModule.AIController")
        ctl = valid(aic) and try("spec aic", function()
            return world:SpawnActor(aic, pos, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }) end) or nil
        if valid(ctl) then pcall(function() ctl:Possess(pup) end) end
        SP.store[i] = { pup = pup, ctl = ctl }
    end
    G.copyStats(p1, pup)
    -- 和 drivePuppet 一样把跑速上限提上去，不然追不上录制里的位置
    local cm = rawProp(pup, "CharacterMovement")
    if valid(cm) then
        pcall(function() cm.MaxWalkSpeed = math.max(tonumber(rawProp(cm, "MaxWalkSpeed")) or 0, 1400.0) end)
        pcall(function() cm.MaxAcceleration = math.max(tonumber(rawProp(cm, "MaxAcceleration")) or 0, 6000.0) end)
    end
    if valid(ctl) then pcall(function() ctl:ResetIgnoreMoveInput() end) end
    return pup, ctl
end

-- 【适配】藏起来留着复用：DisableMovement + SetActorHiddenInGame + 关碰撞（同 removePuppet）
local function hideOne(pup)
    if not valid(pup) then return end
    G.cancelMoves(pup)
    G.cutMontage(pup)
    local cm = rawProp(pup, "CharacterMovement")
    if valid(cm) then pcall(function() cm:DisableMovement() end) end
    pcall(function() pup:SetActorHiddenInGame(true) end)
    pcall(function() pup:SetActorEnableCollision(false) end)
end

-- 【适配】FactionComponent:SetFaction
local function setFaction(pup, want)
    local fc = G.factionComp(pup)
    return valid(fc) and pcall(function() fc:SetFaction({ TagName = FName(want) }) end)
end

-- 本地角色：藏起来、冻住、不吃移动 / 视角输入、锁血（锁血在身上时 Esc 菜单打不开，§39，关观战时解除）
-- 【适配】SetActorHiddenInGame / SetActorEnableCollision / CharacterMovement:DisableMovement / PC:SetIgnoreMoveInput / SetIgnoreLookInput
local function hideSelf(p1, pc)
    pcall(function() p1:SetActorHiddenInGame(true) end)
    local cm = rawProp(p1, "CharacterMovement")
    if valid(cm) then pcall(function() cm.Velocity = { X = 0.0, Y = 0.0, Z = 0.0 } end); pcall(function() cm:DisableMovement() end) end
    -- 碰撞不关（2026-11-07 18:45 实测：关了碰撞，"掉出地图保护"一挪位置人就穿地掉下去摔死）
    if valid(pc) then
        pcall(function() pc:SetIgnoreMoveInput(true) end)
        pcall(function() pc:SetIgnoreLookInput(true) end)
    end
    SP.locked = G.lockSelf(p1)
end

local function showSelf(p1, pc)
    if valid(p1) then
        pcall(function() p1:SetActorEnableCollision(true) end)
        local cm = rawProp(p1, "CharacterMovement")
        if valid(cm) then pcall(function() cm:SetMovementMode(1, 0) end) end
        pcall(function() p1:SetActorHiddenInGame(false) end)
        if SP.locked then G.unlockSelf(p1, "观战原型结束") end
        SP.locked = nil     -- 玩家1 无效时留着，下次（SP.feed 前往主机地图前）再解，不然锁血挂着、切图会被 MAPGO.dirty 拒
    end
    if valid(pc) then
        pcall(function() pc:ResetIgnoreMoveInput() end)
        pcall(function() pc:ResetIgnoreLookInput() end)
        if valid(p1) then pcall(function() pc:SetViewTargetWithBlend(p1, 0.3, 0, 0.0, false) end) end
    end
end

-- ============================================================ 镜头：一个 CameraActor，每帧按模式摆

-- 【适配】SpawnActor(/Script/Engine.CameraActor) + PlayerController:SetViewTargetWithBlend
local function ensureCam(p1)
    if valid(SP.camActor) then return SP.camActor end
    local cls = StaticFindObject("/Script/Engine.CameraActor")
    local world = try("cam world", function() return p1:GetWorld() end)
    if not (valid(cls) and valid(world)) then out("!! 观战镜头：找不到 CameraActor 类"); return nil end
    local l = loc(p1) or { X = 0, Y = 0, Z = 0 }
    SP.camActor = try("cam spawn", function() return world:SpawnActor(cls, l, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }) end)
    out("观战镜头：%s", short(pathOf(SP.camActor)))
    return SP.camActor
end

-- 自由视角：鼠标转的是玩家控制器的朝向（进自由视角时恢复视角输入、把控制器朝向对齐镜头当前朝向），镜头每帧照着它转；
-- 移动看 WASD / Shift 有没有按着（PlayerController:IsInputKeyDown，角色本身忽略了移动输入、不会动）。离开自由视角再忽略视角输入
-- 【适配】PC:ResetIgnoreLookInput / SetIgnoreLookInput / SetControlRotation、CameraActor:K2_GetActorLocation / K2_GetActorRotation
local function freeMode(pc, on)
    if on then
        local r = try("cam rot", function() return SP.camActor:K2_GetActorRotation() end)
        if r then pcall(function() pc:SetControlRotation({ Pitch = r.Pitch, Yaw = r.Yaw, Roll = 0.0 }) end) end
        pcall(function() pc:ResetIgnoreLookInput() end)
        SP.freeAt = os.clock()
    else
        pcall(function() pc:SetIgnoreLookInput(true) end)
    end
end

local function viewCam()
    local pc, cam = getP1PC(), SP.camActor
    if not (valid(pc) and valid(cam)) then return end
    freeMode(pc, SP.cam == FREE)
    local ok, err = pcall(function() pc:SetViewTargetWithBlend(cam, SP.cam == FREE and 0.0 or 0.4, 0, 0.0, false) end)
    out("观战镜头 → %s（SetViewTargetWithBlend %s）", CAM_NAMES[SP.cam], ok and "成功" or tostring(err))
end

local KEYS = {}
-- 【适配】PlayerController:IsInputKeyDown(FKey{KeyName})
local function keyDown(pc, name)
    local k = KEYS[name]
    if not k then k = { KeyName = FName(name) }; KEYS[name] = k end
    local ok, v = pcall(function() return pc:IsInputKeyDown(k) end)
    return ok and v == true
end

-- 【适配】PC:GetControlRotation、CameraActor:K2_GetActorLocation / K2_SetActorLocationAndRotation
local function placeFree(cam)
    local pc = getP1PC()
    if not valid(pc) then return end
    local c = os.clock()
    local dt = math.min(0.1, c - (SP.freeAt or c))
    SP.freeAt = c
    local okR, r = pcall(function() return pc:GetControlRotation() end)
    local p = loc(cam)
    if not (okR and r and p) then return end
    local pitch = r.Pitch > 180.0 and r.Pitch - 360.0 or r.Pitch
    local cp, sp_, cy, sy = math.cos(math.rad(pitch)), math.sin(math.rad(pitch)), math.cos(math.rad(r.Yaw)), math.sin(math.rad(r.Yaw))
    local f = { X = cp * cy, Y = cp * sy, Z = sp_ }             -- 朝哪看就往哪飞
    local rt = { X = -sy, Y = cy, Z = 0.0 }
    local mf = (keyDown(pc, "W") and 1 or 0) - (keyDown(pc, "S") and 1 or 0)
    local mr = (keyDown(pc, "D") and 1 or 0) - (keyDown(pc, "A") and 1 or 0)
    local v = (keyDown(pc, "LeftShift") and FREE_FAST or FREE_SPEED) * dt
    if mf ~= 0 and mr ~= 0 then v = v * 0.7071 end
    p = { X = p.X + (f.X * mf + rt.X * mr) * v, Y = p.Y + (f.Y * mf + rt.Y * mr) * v, Z = p.Z + f.Z * mf * v }
    pcall(function() cam:K2_SetActorLocationAndRotation(p, { Pitch = pitch, Yaw = r.Yaw, Roll = 0.0 }, false, {}, true) end)
end

-- §167.1 线上反馈"视角会卡到虚空里"：固定视角摆在两人侧面 / 身后几米，旁边有石头、崖壁就钻进去，从里面看是一片虚空。
-- 从看的点往镜头位置打射线，打到东西就把镜头拉到碰撞点前面 SP.CAM_PAD（同游戏的弹簧臂镜头）。
-- §167.3 用户 11-09："第三方视角在没办法屏蔽场景建筑的情况下，其实在小地图挺不好用的"，两样都做：
--   ① 挡视线的小物件（墙、柱子、树、杂物）只在本机画面上藏起来（SetActorHiddenInGame，不改碰撞、不进存档），1 秒不挡了再显示；
--      地形、大块建筑（包围盒半边长 > HIDE_MAX）、角色不藏 —— 藏了会露出天空 / 少一大片
--   ② 侧面中点视角被藏不了的东西挡住时，围着两人中间换个角度（AUTO_OFFS 里挑离现在最近的、看得到的），平滑转过去
-- 自由视角不管（玩家自己飞）。射线调用出错就记一行、以后不再打
SP.HIDE_MAX, SP.HIDE_KEEP, SP.SIGHT_SEC, SP.PICK_SEC, SP.TURN = 1500.0, 1.0, 0.1, 0.5, 1.5
SP.TURN_WAIT, SP.TURN_HOLD = 1.0, 2.0
-- §167.5 用户 11-09："为什么我看竹子、栅栏的还在挡着"→"如果你直接改摄像头范围内的所有物件呢"：
-- 一条射线会从缝里漏过去、看不到没碰撞的植被。改成镜头到两人之间连一串 TUBE_R 的球（"管子"），管子里：
--   有碰撞的物件 → SphereOverlapActors 找出来，能藏的整件藏（样条墙 / 栅栏放宽到 HIDE_MAX_WALL）；
--   实例化网格（竹子、草等植被）→ 问组件哪几个实例在球里，只把那几个缩到看不见（只改本机画面），离开管子 HIDE_KEEP 秒恢复原样
SP.TUBE_R, SP.HIDE_MAX_WALL, SP.HISM_SEC, SP.INST_MAX = 150.0, 5000.0, 10.0, 60
SP.instHidden, SP.meshHalf = {}, {}
-- §167.4 用户 11-09："很晕，几乎无法看……位置移动带来的不应该是视角即时移动，也应该有个速度曲线移动到新的目标点"：
-- 镜头位置 / 看的点 / 换角度都按指数曲线追目标（时间常数越大越慢越稳）；拉近要快（别看穿墙），放远慢
SP.EYE_T, SP.LOOK_T, SP.TURN_T, SP.CLIP_IN_T, SP.CLIP_OUT_T = 0.6, 0.3, 0.8, 0.08, 0.6
SP.AUTO_OFFS = { 0.0, 0.6, -0.6, 1.2, -1.2, math.pi, math.pi - 0.6, math.pi + 0.6 }
SP.hidden, SP.hideOk, SP.camOff, SP.camOffT, SP.clipK = {}, {}, 0.0, 0.0, 1.0
local HIDE_SKIP = { "Landscape", "HLOD", "WorldPartition", "Water", "Sky", "Character", "Pawn", "Volume", "Renewal", "Hun_C" }

-- 能不能藏：类名不在 HIDE_SKIP 里、包围盒不大。按路径缓存（同一个物件只问一次）
local function hideable(act, comp)
    if SP.hideOff or not (G.actorInfo and G.setHidden) then return false end
    local key = pathOf(act)
    local c = SP.hideOk[key]
    if c ~= nil then return c end
    local cls, ext = G.actorInfo(act, comp)
    local lim = (cls and (cls:find("SplineWall", 1, true) or cls:find("Fence", 1, true))) and SP.HIDE_MAX_WALL or SP.HIDE_MAX
    local ok = cls ~= nil and ext ~= nil and ext <= lim
    if ok then for _, k in ipairs(HIDE_SKIP) do if cls:find(k, 1, true) then ok = false; break end end end
    SP.hideOk[key] = ok
    if ok and not SP.hideLogged then SP.hideLogged = true; out("观战镜头：挡视线的 %s（半边长 %.0f）藏起来了（以后不再记）", tostring(cls), ext) end
    return ok
end

-- 从 look 看 eye 能不能看到：返回 true（看得到；挡着的都是能藏的，doHide 时顺手藏掉）/ false + 第一个藏不了的碰撞点
local function sight(look, eye, a, b, doHide, tn)
    if SP.traceOff or not G.traceActor then return true end
    local ign = {}
    for _, x in ipairs({ a and a.pup, b and b.pup, getP1() }) do if valid(x) then ign[#ign + 1] = x end end
    for _ = 1, 6 do
        local hp, act, err, comp = G.traceActor(SP.camActor, look, eye, ign)
        if err then SP.traceOff = true; out("!! 观战镜头碰撞关掉了：%s", err); return true end
        if not hp then return true end
        local hx, hy, hz = hp.X - look.X, hp.Y - look.Y, hp.Z - look.Z
        if hx * hx + hy * hy + hz * hz < 80.0 * 80.0 then return true end    -- 起点就在东西里（替身 / 自己的胶囊）：不算
        if not (act and hideable(act, comp)) then
            -- §167.3 实测（02:12）一次都没藏：记下挡视线的是什么（拿不到物件 / 类名 + 大小），每种只记一次
            local key = act and pathOf(act) or "?"
            SP.blockSeen = SP.blockSeen or {}
            if not SP.blockSeen[key] and (SP.blockN or 0) < 12 then
                SP.blockSeen[key], SP.blockN = true, (SP.blockN or 0) + 1
                if act then
                    local cls, ext = G.actorInfo(act, comp)
                    out("观战镜头：挡视线的 %s（类 %s，半边长 %s）不能藏", short(key), tostring(cls), ext and string.format("%.0f", ext) or "?")
                else
                    out("观战镜头：射线打到东西，但拿不到是哪个物件（第 %d 种）", SP.blockN)
                end
            end
            return false, hp
        end
        if doHide then
            local key = pathOf(act)
            local h = SP.hidden[key]
            if not h then
                if not G.setHidden(act, true) then SP.hideOk[key] = false; return false, hp end
                h = { actor = act }
                SP.hidden[key] = h
            end
            h.at = tn
        end
        ign[#ign + 1] = act
    end
    return true
end

-- 不挡了 HIDE_KEEP 秒的显示回来；all = 观战结束全显示回来
local function unhide(tn, all)
    for key, h in pairs(SP.hidden) do
        if all or tn - h.at > SP.HIDE_KEEP then
            if valid(h.actor) then G.setHidden(h.actor, false) end
            SP.hidden[key] = nil
        end
    end
    for key, h in pairs(SP.instHidden) do      -- §167.5 植被实例：恢复原来的变换
        if all or tn - h.at > SP.HIDE_KEEP then
            if valid(h.comp) then G.hismSetXf(h.comp, h.idx, h.xf) end
            SP.instHidden[key] = nil
        end
    end
end

-- §167.5 管子：镜头和两人之间每隔 2×TUBE_R 一个球，球里能藏的物件、植被实例都藏起来
local function tubeHide(look, eye, a, b, tn)
    if SP.tubeOff or not (G.overlapActors and G.hismList) then return end
    local dx, dy, dz = eye.X - look.X, eye.Y - look.Y, eye.Z - look.Z
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len < SP.TUBE_R * 2 then return end
    local ign = {}
    for _, x in ipairs({ a and a.pup, b and b.pup, getP1() }) do if valid(x) then ign[#ign + 1] = x end end
    if not SP.hism or tn - (SP.hismAt or -99) > SP.HISM_SEC then SP.hism, SP.hismAt = G.hismList(), tn end
    local newInst = 0
    -- 第一个球离两人 1.5×TUBE_R（别把两人脚下的东西藏了），一直到镜头
    local t = SP.TUBE_R * 1.5
    while t <= len do
        local k = t / len
        local c = { X = look.X + dx * k, Y = look.Y + dy * k, Z = look.Z + dz * k }
        local acts, err = G.overlapActors(SP.camActor, c, SP.TUBE_R, ign)
        if err then SP.tubeOff = true; out("!! 观战镜头管子关掉了：%s", err); return end
        for _, act in ipairs(acts) do
            local okH = hideable(act)
            -- §167.5 实测（03:34）：管子找到 6 个物件，截图里栅栏还挡着 —— 每个物件第一次进管子记一行（最多 30 个）
            local dk = pathOf(act)
            SP.tubeSeen = SP.tubeSeen or {}
            if not SP.tubeSeen[dk] and (SP.tubeSeenN or 0) < 30 then
                SP.tubeSeen[dk], SP.tubeSeenN = true, (SP.tubeSeenN or 0) + 1
                local cls, ext = G.actorInfo(act)
                out("观战镜头管子：碰到 %s（类 %s，半边长 %s）→ %s", short(dk), tostring(cls), ext and string.format("%.0f", ext) or "?", okH and "藏" or "不藏")
            end
            if okH then
                local key = pathOf(act)
                local h = SP.hidden[key]
                if not h then
                    if G.setHidden(act, true) then h = { actor = act }; SP.hidden[key] = h end
                end
                if h then h.at = tn end
            end
        end
        for _, e in ipairs(SP.hism) do
            local ex, ey, ez = e.o.X - c.X, e.o.Y - c.Y, e.o.Z - c.Z
            if valid(e.comp) and ex * ex + ey * ey + ez * ez < (e.r + SP.TUBE_R) ^ 2 then
                local half = SP.meshHalf[e.comp]
                if half == nil then
                    half = G.meshHalf(e.comp) or false; SP.meshHalf[e.comp] = half
                    if (SP.compSeenN or 0) < 15 then
                        SP.compSeenN = (SP.compSeenN or 0) + 1
                        out("观战镜头管子：靠近实例组件 %s（网格半边长 %s，组件包围球 %.0f）", short(pathOf(e.comp)), half and string.format("%.0f", half) or "?", e.r)
                    end
                end
                for _, i in ipairs(G.hismInstancesIn(e.comp, c, SP.TUBE_R)) do
                    local key = pathOf(e.comp) .. "#" .. i
                    local h = SP.instHidden[key]
                    if h then h.at = tn
                    elseif newInst < SP.INST_MAX then
                        local xf = G.hismXf(e.comp, i)
                        local big = xf and half and half * math.max(xf.Scale3D.X, xf.Scale3D.Y, xf.Scale3D.Z) > SP.HIDE_MAX
                        if xf and not big then
                            local tiny = { Rotation = xf.Rotation, Translation = xf.Translation, Scale3D = { X = 0.001, Y = 0.001, Z = 0.001 } }
                            if G.hismSetXf(e.comp, i, tiny) then
                                SP.instHidden[key] = { comp = e.comp, idx = i, xf = xf, at = tn }
                                newInst = newInst + 1
                                SP.instN = (SP.instN or 0) + 1
                                if SP.instN == 1 then out("观战镜头管子：第一次藏植被 / 实例（%s 第 %d 个）", short(pathOf(e.comp)), i) end
                            end
                        end
                    end
                end
            end
        end
        if t >= len then break end
        t = math.min(t + SP.TUBE_R * 2, len)      -- 最后一个球就在镜头上（03:34 截图：贴着镜头的栅栏没包进管子）
    end
end
SP.unhideAll = function() unhide(0.0, true); SP.hideOk = {}; SP.hism, SP.meshHalf, SP.probed = nil, {}, nil end

-- 拉近比例：看不到时拉到碰撞点前面 CAM_PAD
local function clipK(look, eye, hp)
    local dx, dy, dz = eye.X - look.X, eye.Y - look.Y, eye.Z - look.Z
    local full = math.sqrt(dx * dx + dy * dy + dz * dz)
    if full < 1.0 then return 1.0 end
    local hx, hy, hz = hp.X - look.X, hp.Y - look.Y, hp.Z - look.Z
    local d = math.sqrt(hx * hx + hy * hy + hz * hz)
    if not SP.clipLogged then SP.clipLogged = true; out("观战镜头：撞到地形，拉近到 %.0f / %.0f（以后不再记）", d - SP.CAM_PAD, full) end
    return math.max(0.0, d - SP.CAM_PAD) / full
end

-- 角度差折到 -pi..pi
local function wrap(x) return (x + math.pi) % (2 * math.pi) - math.pi end

-- 【适配】CameraActor:K2_SetActorLocationAndRotation
local function placeCam()
    local cam, a, b = SP.camActor, SP.side[1], SP.side[2]
    if SP.cam == FREE then
        if next(SP.hidden) or next(SP.instHidden) then unhide(0.0, true) end      -- §167.3 自由视角不藏东西
        if valid(cam) then placeFree(cam) end
        return
    end
    if not (valid(cam) and a and b and valid(a.pup) and valid(b.pup)) then return end
    local la, lb = loc(a.pup), loc(b.pup)
    if not (la and lb) then return end
    -- §141 一路没人（主机 + 观战者、没有客机）：那个替身藏着，镜头只对着在的那个（当另一个在它前面 3 米）
    if a.idle and not b.idle then local r = math.rad(G.yawOf and G.yawOf(b.pup) or 0); la = { X = lb.X + math.cos(r) * 300, Y = lb.Y + math.sin(r) * 300, Z = lb.Z }
    elseif b.idle and not a.idle then local r = math.rad(G.yawOf and G.yawOf(a.pup) or 0); lb = { X = la.X + math.cos(r) * 300, Y = la.Y + math.sin(r) * 300, Z = la.Z } end
    local dx, dy = lb.X - la.X, lb.Y - la.Y
    local len = math.max(1.0, math.sqrt(dx * dx + dy * dy))
    local ux, uy = dx / len, dy / len
    local eye, look
    local tn = now()
    if SP.cam == 1 then
        local mx, my, mz = (la.X + lb.X) / 2, (la.Y + lb.Y) / 2, (la.Z + lb.Z) / 2
        local side = SP.CAM_SIDE + len * 0.5          -- 两人拉开时镜头往后退
        look = { X = mx, Y = my, Z = mz + 60.0 }
        local base = math.atan(ux, -uy)               -- 侧面（两人连线的垂直方向）
        local function eyeAt(off) local r = base + off; return { X = mx + math.cos(r) * side, Y = my + math.sin(r) * side, Z = mz + SP.CAM_UP } end
        -- §167.3 ② 现在的角度被藏不了的东西挡住：挑离现在最近、看得到的角度
        if tn - (SP.pickAt or 0) >= SP.PICK_SEC then
            SP.pickAt = tn
            -- 实测（02:12）30 秒换了 20 次：现在的角度连着挡 1 秒才换，换完至少停 2 秒
            local blocked = not sight(look, eyeAt(SP.camOffT), a, b, false, tn)
            if blocked then SP.blockedAt = SP.blockedAt or tn else SP.blockedAt = nil end
            if blocked and tn - SP.blockedAt >= SP.TURN_WAIT and tn - (SP.turnedAt or -99) >= SP.TURN_HOLD then
                local best, bd
                for _, off in ipairs(SP.AUTO_OFFS) do
                    local d = math.abs(wrap(off - SP.camOff))
                    if (not bd or d < bd - 1e-6) and sight(look, eyeAt(off), a, b, false, tn) then best, bd = off, d end      -- 一样近取先列的
                end
                if best and best ~= SP.camOffT then
                    SP.camOffT, SP.turnedAt, SP.blockedAt = best, tn, nil
                    SP.turns = (SP.turns or 0) + 1
                    if SP.turns <= 3 or SP.turns % 20 == 0 then out("观战镜头：侧面被挡，换个角度（%.0f°，第 %d 次）", math.deg(best), SP.turns) end
                end
            end
        end
        local dt = math.min(0.1, math.max(0.0, tn - (SP.turnAt or tn))); SP.turnAt = tn     -- 每帧调，按真实间隔转
        local diff = wrap(SP.camOffT - SP.camOff)
        SP.camOff = math.abs(diff) < 0.001 and SP.camOffT or SP.camOff + diff * (1 - math.exp(-dt / SP.TURN_T))   -- §167.4 先快后慢
        eye = eyeAt(SP.camOff)
    else
        local me, other, s = la, lb, 1
        if SP.cam == 3 then me, other, s = lb, la, -1 end
        eye = { X = me.X - ux * s * SP.CAM_BACK, Y = me.Y - uy * s * SP.CAM_BACK, Z = me.Z + SP.CAM_UP }
        look = { X = other.X, Y = other.Y, Z = other.Z + 60.0 }
    end
    -- §167.4 平滑：镜头位置、看的点按指数曲线追目标（切视角时也是平滑过去）
    local dt = math.min(0.1, math.max(0.0, tn - (SP.smAt or tn))); SP.smAt = tn
    local function ease(cur, tgt, T)
        if not cur then return tgt end
        local k = 1 - math.exp(-dt / T)
        return { X = cur.X + (tgt.X - cur.X) * k, Y = cur.Y + (tgt.Y - cur.Y) * k, Z = cur.Z + (tgt.Z - cur.Z) * k }
    end
    SP.eyeS, SP.lookS = ease(SP.eyeS, eye, SP.EYE_T), ease(SP.lookS, look, SP.LOOK_T)
    eye, look = SP.eyeS, SP.lookS
    -- §167.3 ① 挡视线的小物件藏起来，藏不了的才拉近（每 SIGHT_SEC 查一次，中间沿用上次的拉近比例）
    if tn - (SP.sightAt or 0) >= SP.SIGHT_SEC then
        SP.sightAt = tn
        -- §167.6 观战开始 3 秒后探一次镜头附近有什么（竹子到底是哪类东西）
        if not SP.probed and G.tubeProbe and tn - (SP.statAt or tn) > 3.0 then SP.probed = true; pcall(G.tubeProbe, eye) end
        local okT, errT = pcall(tubeHide, look, eye, a, b, tn)     -- §167.5 先把管子里的藏掉，射线再看还有没有挡的
        if not okT and not SP.tubeErr then SP.tubeErr = true; out("!! 观战镜头管子出错：%s", tostring(errT)) end
        local ok, hp = sight(look, eye, a, b, true, tn)
        SP.clipK = ok and 1.0 or clipK(look, eye, hp)
        unhide(tn, false)
    end
    local cs = SP.clipS or SP.clipK
    SP.clipS = cs + (SP.clipK - cs) * (1 - math.exp(-dt / (SP.clipK < cs and SP.CLIP_IN_T or SP.CLIP_OUT_T)))   -- §167.4 拉近快、放远慢
    if SP.clipS < 0.999 then
        eye = { X = look.X + (eye.X - look.X) * SP.clipS, Y = look.Y + (eye.Y - look.Y) * SP.clipS, Z = look.Z + (eye.Z - look.Z) * SP.clipS }
    end
    local hx, hy, hz = look.X - eye.X, look.Y - eye.Y, look.Z - eye.Z
    local rot = { Pitch = math.deg(math.atan(hz, math.sqrt(hx * hx + hy * hy))), Yaw = math.deg(math.atan(hy, hx)), Roll = 0.0 }
    pcall(function() cam:K2_SetActorLocationAndRotation(eye, rot, false, {}, true) end)
end

-- ============================================================ 驱动：每帧喂摇杆，30 次 / 秒更新目标、出招

-- 走向目标点：写速度 + 喂摇杆（动画蓝图要有加速度才播跑步，同 drivePuppet）
-- 【适配】CharacterMovement.Velocity、Pawn:AddMovementInput（每帧）
local function steer(s, target)
    local cur = loc(s.pup)
    if not cur then return end
    local dx, dy = target.X - cur.X, target.Y - cur.Y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist > 1500.0 then                                -- 离太远（录制起点 / 被打飞）直接摆过去
        pcall(function() s.pup:K2_SetActorLocation({ X = target.X, Y = target.Y, Z = (target.Z or cur.Z) + 20.0 }, false, {}, true) end)
        s.feed = nil
        return
    end
    if dist < 20.0 then s.feed = nil; return end
    local sp = math.min(dist * 3.0, dist > 200.0 and 1400.0 or 600.0)
    local vx, vy = dx / dist * sp, dy / dist * sp
    local cm = rawProp(s.pup, "CharacterMovement")
    if valid(cm) then
        local vz = 0.0
        pcall(function() vz = cm.Velocity.Z end)
        pcall(function() cm.Velocity = { X = vx, Y = vy, Z = vz } end)
    end
    s.feed = { dir = { X = dx / dist, Y = dy / dist, Z = 0.0 }, scale = math.min(1.0, sp / 600.0), left = 12 }
end

-- G.setYaw 只给对战替身设控制器朝向；这里的替身自己设，不然 AI 控制器会把人转回去
-- 【适配】Actor:K2_SetActorRotation（G.setYaw）+ AIController:SetControlRotation
local function turn(s, yaw)
    G.setYaw(s.pup, yaw)
    if valid(s.ctl) then pcall(function() s.ctl:SetControlRotation({ Pitch = 0.0, Yaw = yaw, Roll = 0.0 }) end) end
end

local function face(s, other)
    local a, b = loc(s.pup), loc(other.pup)
    if a and b then turn(s, G.yawTo(a, b)) end
end

-- 内置对打 = 本地 AI（§75，lobby\LocalAi.cs）那一套：两个替身都换上绝影（双刃），招式表照搬 LocalAi 的 Combos / Skills
-- （空中招先不放）。两边各自出手，不轮流：走到 AI.DIST 以内、冷却到了就随机挑一套（7 成连段、3 成武器技），
-- 一招接一招放，打完冷却 0.6–1.6 秒；离得远就走过去，近了就绕着对方横移。用户 2026-11-07："直接让 AI 对打"
local D = "GA_Hun_Double_"
local AI = {
    WC = "/PBZCombatAsset/ActorData/Players/Hun/Weapon/Double/Weapon_Hun_JueYing.Weapon_Hun_JueYing",
    DIST = 300.0, GAP = 0.45,
    COMBOS = {
        { D .. "A_C", D .. "AA_C", D .. "AAA_C" }, { D .. "A_C", D .. "AA_C", D .. "AAA_C", D .. "AAAA_C" },
        { D .. "B_C", D .. "BB_C" }, { D .. "A_C", D .. "AB_C" }, { D .. "B_Dash_C" }, { D .. "SWT_C" },
        { D .. "A_C", D .. "AA_C" } },
    SKILLS = {
        { D .. "JueYing_C_C" }, { D .. "Buff_C" }, { D .. "C_C" },
        { D .. "A_Draw_C" }, { D .. "B_Draw_C" }, { D .. "ATB_C", D .. "ATBB_C", D .. "ATBBB_C" },
        { D .. "BTA_C" }, { D .. "A_DashDraw_Short_C" }, { D .. "B_DashDraw_C" },
        { D .. "A_Snap_C" }, { D .. "B_Snap_C" } },
}

-- 换武器：只改替身自己的武器组件（同对战替身的 wc= 换装，LO.dressSlot，不碰玩家装备）；对不上每 5 秒重装一次
local function dress(s)
    local cwc = rawProp(s.pup, "Character Weapons Component")
    if not valid(cwc) then return end
    s.dressSt = s.dressSt or {}
    ctx.LO.dressSlot(s.pup, getP1(), cwc, ctx.LO.slot(), AI.WC, "观战原型 " .. s.tag .. " 武器", s.dressSt)
    local held = ctx.LO.heldConfig(s.pup)
    local ok = held == AI.WC
    if ok ~= s.armed then
        s.armed = ok
        out("观战原型 %s 手上武器 %s%s", s.tag, LO_short(held), ok and "（绝影 ✓）" or "（还不是绝影）")
    end
end

local function scriptStep(s, other, tn)
    local a, b = loc(s.pup), loc(other.pup)
    if not (a and b) then return end
    local dist = d2(a, b)
    if s.seq then                                              -- 正在打一套
        s.feed = nil
        if tn < s.nextAt then return end
        local n = s.seq[s.si]
        if not n then
            s.seq, s.cdUntil = nil, tn + 0.6 + math.random()
            return
        end
        face(s, other)
        local ok = ctx.activate(s.pup, n, s.sub, "观战原型 AI " .. s.tag)
        s.fired, s.failed = (s.fired or 0) + (ok and 1 or 0), (s.failed or 0) + (ok and 0 or 1)
        s.si, s.nextAt = s.si + 1, tn + AI.GAP + math.random() * 0.2
        if not ok then s.seq, s.cdUntil = nil, tn + 0.5 end   -- 一套里断了就收手，别空放后面几段
        return
    end
    if G.montageOf(s.pup) ~= "" then s.feed = nil; return end
    if dist > AI.DIST then
        steer(s, { X = b.X - (b.X - a.X) / dist * (AI.DIST - 60), Y = b.Y - (b.Y - a.Y) / dist * (AI.DIST - 60) })
        face(s, other)
        return
    end
    if tn >= (s.cdUntil or 0) and s.armed then
        local pool = math.random() < 0.7 and AI.COMBOS or AI.SKILLS
        s.seq, s.si, s.nextAt = pool[math.random(#pool)], 1, tn
        return
    end
    -- 等冷却：绕着对方慢慢横移（两人方向相反）
    local ang = math.atan(a.Y - b.Y, a.X - b.X) + (s.idx == 1 and 0.06 or -0.06)
    steer(s, { X = b.X + math.cos(ang) * AI.DIST * 0.8, Y = b.Y + math.sin(ang) * AI.DIST * 0.8 })
    face(s, other)
end

-- 录制回放（格式同 F7 录制：相对起点的 前|右|高|朝向|动画|技能）；起点放在各自的开场位置、"往前"朝着对方
local function recStep(s, other, tn)
    local fr = s.frames
    local t = tn - s.t0
    if t > fr[#fr].t then                                  -- 播完从头再来
        s.t0, s.i, s.abI = tn, 1, 0
        return
    end
    while s.i < #fr and fr[s.i + 1].t <= t do s.i = s.i + 1 end
    local f = fr[s.i]
    local r = math.rad(s.ayaw)
    steer(s, { X = s.ax + f.x * math.cos(r) - f.y * math.sin(r), Y = s.ay + f.x * math.sin(r) + f.y * math.cos(r) })
    if G.montageOf(s.pup) == "" then turn(s, s.ayaw + f.yaw) end
    while s.abI < s.i do
        s.abI = s.abI + 1
        for n in fr[s.abI].ab:gmatch("[^,]+") do ctx.activate(s.pup, n, s.sub, "观战原型回放 " .. s.tag) end
    end
end

-- ============================================================ 第 1 步：按状态包驱动（§141.5）
-- 包流文件 rec\spec_a.pkt / spec_b.pkt（tests/make_spec_stream.py 从录下的真人状态包 jsonl 转出来：一帧一行
-- "相对秒数<tab>键=值<tab>…"）。按开始时读一次，之后只在内存里播。观战者不判定：两个替身同一阵营、互相打不出伤害，
-- 受击 / 破防 / 喝药 / 技能内动作 / 闪避都按包里的 n:动作名 照播，血量 / 杀气按包里的 hp / hpm / sh / shm 写血条。
-- 位置：每路包流第一帧摆到各自的开场位置，第一帧的朝向转成"面朝对方"，之后按录制的相对移动走；播完从头再来。
-- 第 2 步起换成主机转发过来的两路实时状态包，这里的 pktApply / pktStep 照用
local PKT_FILES = { "/spec_a.pkt", "/spec_b.pkt" }
local CNT_KEYS = { "hr", "brk", "med", "sub", "dg" }      -- n:动作名，n 变大 = 新的一次

local function loadPkt(i)
    local path = ctx.recDir .. PKT_FILES[i]
    local f = io.open(path, "r")
    if not f then return nil, path end
    local frames, head = {}, nil
    for line in f:lines() do
        if line:sub(1, 1) == "#" then
            head = head or line
        else
            local t, rest = line:match("^([%d%.%-]+)\t(.*)$")
            if t then
                local p = {}
                for k, v in rest:gmatch("([%w_]+)=([^\t]*)") do p[k] = v end
                if p.x then frames[#frames + 1] = { t = tonumber(t), p = p } end
            end
        end
    end
    f:close()
    if #frames < 2 then return nil, path end
    return frames, path, head
end

local function pktWorld(s, p)
    local dx, dy = (tonumber(p.x) or s.x0) - s.x0, (tonumber(p.y) or s.y0) - s.y0
    local r = math.rad(s.rot)
    return { X = s.ax + dx * math.cos(r) - dy * math.sin(r), Y = s.ay + dx * math.sin(r) + dy * math.cos(r) }
end

-- 一帧包里的"事件"：新招式（ev= 编号:技能名）、各种 n:动作名 计数、武器 / 外观、血 / 杀气。
-- 第一帧（刚开始 / 循环回到头）只记编号和计数，不放（同 NET.recvOne"第一次收到只记次数"）
local function pktApply(s, p, tn)
    local first = s.evMax == nil
    local maxId = s.evMax or -1
    for id, name in (p.ev or ""):gmatch("(%d+):([%w_]+)") do
        id = tonumber(id)
        if id > (s.evMax or math.huge) and ctx.replayable(name) then
            local ok = ctx.activate(s.pup, name, s.sub, "观战包 " .. s.tag)
            s.fired, s.failed = (s.fired or 0) + (ok and 1 or 0), (s.failed or 0) + (ok and 0 or 1)
        end
        if id > maxId then maxId = id end
    end
    s.evMax = maxId
    for _, k in ipairs(CNT_KEYS) do
        local n, m = (p[k] or ""):match("^(%d+):([%w_%.%-]+)$")
        n = tonumber(n)
        if n then
            if not first and s.cnt[k] and n > s.cnt[k] and m ~= "-" then
                if k == "hr" or k == "brk" then G.cutMontage(s.pup) end      -- 挨打了 = 那一刀被打断（同 NET.recvOne）
                local ok = ctx.playNamed(s.pup, m)
                s.acts = (s.acts or 0) + 1
                if not ok then
                    s.actFail = (s.actFail or 0) + 1
                    if s.actFail <= 5 then out("  观战包 %s：%s 动作 %s 播不出（本机没有这个动作）", s.tag, k, m) end
                end
            end
            s.cnt[k] = n
        end
    end
    if p.wc and p.wc ~= "" then s.wantWc = p.wc end
    if p.wcs and p.wcs ~= "" then s.wantWcs = p.wcs end
    if p.of and p.of ~= s.ofCur then
        s.ofCur = p.of
        local o = ctx.LO.decodeOutfit(p.of)
        if o then
            local ok, msg = ctx.LO.applyOutfit(s.pup, o.outfit, o.skin, o.hat)
            out("观战包 %s 皮肤 %s：%s（%s）", s.tag, p.of, ok and "已换" or "没换成", tostring(msg))
        end
    end
    s.hp, s.hpm = tonumber(p.hp) or s.hp, tonumber(p.hpm) or s.hpm
    s.sh, s.shm = tonumber(p.sh) or s.sh, tonumber(p.shm) or s.shm
end

local function pktStep(s, other, tn)
    local fr = s.pkt
    local t = tn - s.t0
    if t > fr[#fr].t + 0.5 then                            -- 播完停半秒从头再来
        s.t0, s.i, s.evMax, s.cnt, s.loops = tn, 1, nil, {}, (s.loops or 0) + 1
        pktApply(s, fr[1].p, tn)
        out("观战包 %s 第 %d 遍", s.tag, s.loops + 1)
        return
    end
    while s.i < #fr and fr[s.i + 1].t <= t do
        s.i = s.i + 1
        pktApply(s, fr[s.i].p, tn)
    end
    local a, b = fr[s.i], fr[math.min(s.i + 1, #fr)]
    local span = b.t - a.t
    local k = span > 0 and math.max(0, math.min(1, (t - a.t) / span)) or 0
    local pa, pb = pktWorld(s, a.p), pktWorld(s, b.p)
    local target = { X = pa.X + (pb.X - pa.X) * k, Y = pa.Y + (pb.Y - pa.Y) * k }
    local mont, cur = G.montageOf(s.pup), loc(s.pup)
    -- 出招 / 受击中动作自己带位移：离得不远就先不拉（同对战替身"出招中不瞬移"的意思）
    if mont ~= "" and cur and d2(cur, target) < 400.0 then s.feed = nil else steer(s, target) end
    if mont == "" then turn(s, (tonumber(a.p.yaw) or 0) + s.rot) end
end

-- 包里的武器 / 影之武装：同对战替身的 wc= / wcs= 换装（LO.dressSlot 只改替身自己的武器组件）
local function dressPkt(s)
    local cwc = rawProp(s.pup, "Character Weapons Component")
    if not valid(cwc) then return end
    s.dressSt, s.dressStS = s.dressSt or {}, s.dressStS or {}
    if s.wantWc then ctx.LO.dressSlot(s.pup, getP1(), cwc, ctx.LO.slot(), s.wantWc, "观战包 " .. s.tag .. " 武器", s.dressSt) end
    if s.wantWcs then ctx.LO.dressSlot(s.pup, getP1(), cwc, ctx.LO.slotShachi(), s.wantWcs, "观战包 " .. s.tag .. " 影之武装", s.dressStS) end
end

-- ============================================================ 第 2 步：联机观战（主机转发的实时包，src=h 主机 / src=c 对手）
-- 联机程序在观战会话（role = spec）里把两路包原样交给游戏，main.lua 的 netRecv 见到 src= 就交给 SP.feed，不进 NET.recvOne。
-- 收到第一个包就自动开观战（A = 主机、B = 对手）；坐标是绝对坐标（观战者要在主机那张图），按最新的包 + 速度外推一点点走。
-- 两路都 LIVE_LOST 秒没包 = 主机断了 / 房间散了，结束观战
local LIVE_LOST, LIVE_AHEAD = 8.0, 0.2
SP.live = { want = false, userStop = false }

-- 一路 LIVE_IDLE 秒没包（没有客机 / 掉线）：替身和血条藏起来，不留个不动的假人；包又来了再显示（SP.feed）
local LIVE_IDLE = 10.0      -- 用户 2026-11-07：10 秒（网络一卡就藏起来会闪现）
local function setIdle(s, on)
    if s.idle == on then return end
    s.idle = on
    pcall(function() s.pup:SetActorHiddenInGame(on) end)
    pcall(function() s.pup:SetActorEnableCollision(not on) end)
    if on then
        if s.barReg then G.bossBarHide(s.pup) end
        s.barReg, s.bar, s.barMiss = false, nil, 0      -- 显示时重新注册血条
    end
    out("观战 %s：%s", s.tag, on and "没包了，藏起来" or "又有包了，显示")
end

local function liveStep(s, other, tn)
    local p = s.last
    if not p or tn - (s.lastAt or 0) > LIVE_IDLE then setIdle(s, true); return end
    local dt = math.min(LIVE_AHEAD, math.max(0, tn - (s.lastAt or tn)))
    local x, y = tonumber(p.x), tonumber(p.y)
    if not (x and y) then return end
    local target = { X = x + (tonumber(p.vx) or 0) * dt, Y = y + (tonumber(p.vy) or 0) * dt, Z = tonumber(p.z) }
    local mont, cur = G.montageOf(s.pup), loc(s.pup)
    -- §141.14 线上反馈"人在虚空里 / 离很远打空气"：摆过去时那块地面还没加载出来，替身掉穿地面；之后水平距离近、steer 不再拉，
    -- 就一直待在地面以下。比包里的高度低 SINK 以上 = 掉下去了：拉回包里的位置（地面加载出来之前会反复拉，限速）
    if cur and target.Z and cur.Z < target.Z - SP.SINK and tn - (s.sinkAt or 0) > 0.5 then
        s.sinkAt = tn
        pcall(function() s.pup:K2_SetActorLocation({ X = target.X, Y = target.Y, Z = target.Z + 50.0 }, false, {}, true) end)
        local cm = rawProp(s.pup, "CharacterMovement")
        if valid(cm) then pcall(function() cm.Velocity = { X = 0.0, Y = 0.0, Z = 0.0 } end) end
        s.sinks = (s.sinks or 0) + 1
        if s.sinks <= 3 or s.sinks % 20 == 0 then out("观战 %s 掉到地面以下（Z %.0f，包里 %.0f），拉回（第 %d 次）", s.tag, cur.Z, target.Z, s.sinks) end
        s.feed = nil
        return
    end
    -- §167.9 跟真人一样"严格跟随"：位置由 SP.followFrame 每帧拉过去，这里的 steer 只给跑步动画速度 / 摇杆
    s.aim = { X = x, Y = y, Z = tonumber(p.z), vx = tonumber(p.vx) or 0, vy = tonumber(p.vy) or 0, at = s.lastAt or tn, air = p.air == "1" }
    SP.followPrep(s)
    steer(s, target)
    if mont == "" then turn(s, tonumber(p.yaw) or 0) end
end

-- §167.9 线上反馈（11-09 视频）：观战里两人隔着十几米各打各的。原因：观战替身只靠 steer 写速度追位置（移动组件按 MaxWalkSpeed
-- 截断，追不上），出招时动画根运动带着人走、离目标 4 米内也不纠正、15 米外才摆过去 —— 一打快了就越漂越远。
-- 改成和对战替身的"对手位置严格跟随"（main.lua NPM，§128.1）一样：根运动倍数 0（动作照播、人不被动画带走），
-- 每帧把替身往"包里位置 + 速度 × 包龄（最多 FOLLOW_AHEAD 秒）"拉，每秒补 FOLLOW_K 倍误差，差 FOLLOW_SNAP 以上直接摆
SP.FOLLOW_K, SP.FOLLOW_SNAP, SP.FOLLOW_AHEAD, SP.FOLLOW_ZSNAP = 14.0, 600.0, 0.25, 300.0

-- 每个替身第一次跟随时：根运动关掉、跑速 / 加速度上限提上去（同 drivePuppet）
-- 【适配】G.rootMotionScale（AnimInstance 根运动倍数）、CharacterMovement.MaxWalkSpeed / MaxAcceleration
function SP.followPrep(s)
    if s.followReady then return end
    s.followReady = true
    local ok, how = G.rootMotionScale(s.pup, 0.0)
    local cm = rawProp(s.pup, "CharacterMovement")
    if valid(cm) then
        pcall(function() cm.MaxWalkSpeed = math.max(tonumber(rawProp(cm, "MaxWalkSpeed")) or 0, 1400.0) end)
        pcall(function() cm.MaxAcceleration = math.max(tonumber(rawProp(cm, "MaxAcceleration")) or 0, 6000.0) end)
    end
    out("观战 %s：严格跟随位置（根运动关 %s：%s）", s.tag, ok and "成功" or "失败", tostring(how))
end

-- 纯计算（测试用）：这一刻该在的 XY、从 cur 走一步后的 XY、是否直接摆
-- §167.9.2 总控复测：冲刺（双月 AdvancedDash）时还会落后 5–6 米。只按误差追，匀速时稳态落后 = 速度 ÷ K（80 米/秒 ≈ 5.7 米）。
-- 加速度前馈：包还新（外推没到头）时先按包里的速度走 dt，再按误差补（离线模拟 80 米/秒冲刺落后 5.7 → 1.2 米）
function SP.followStep(cur, aim, tn, dt)
    local age = math.max(tn - aim.at, 0)
    local a = math.min(age, SP.FOLLOW_AHEAD)
    local ax, ay = aim.X + aim.vx * a, aim.Y + aim.vy * a
    local cx, cy = cur.X, cur.Y
    if age < SP.FOLLOW_AHEAD then cx, cy = cx + aim.vx * math.max(dt, 0), cy + aim.vy * math.max(dt, 0) end
    local dx, dy = ax - cx, ay - cy
    local err = math.sqrt((ax - cur.X) ^ 2 + (ay - cur.Y) ^ 2)
    if err > SP.FOLLOW_SNAP then return ax, ay, true, err end
    local k = math.min(1.0, SP.FOLLOW_K * math.max(dt, 0))
    return cx + dx * k, cy + dy * k, false, err
end

-- 每帧（frame() 里摆镜头之前）。【适配】Actor:K2_GetActorLocation / K2_SetActorLocation
function SP.followFrame()
    local tn = now()
    for _, s in ipairs(SP.side) do
        local aim = s.aim
        if s.live and aim and not s.idle and valid(s.pup) and tn - aim.at < 1.0 then
            local cur = loc(s.pup)
            if cur then
                local dt = s.followAt and (tn - s.followAt) or 0.016
                s.followAt = tn
                local x, y, snap, err = SP.followStep(cur, aim, tn, dt)
                local z = cur.Z
                if not aim.air and aim.Z and math.abs(aim.Z - cur.Z) > SP.FOLLOW_ZSNAP then z, snap = aim.Z + 20.0, true end
                pcall(function() s.pup:K2_SetActorLocation({ X = x, Y = y, Z = z }, false, {}, snap) end)
                s.errMax = math.max(s.errMax or 0, err)
                if snap then s.snaps = (s.snaps or 0) + 1 end
            end
        end
    end
end

-- 【适配】G.bossBarShow / bossBarOf / bossBarSet / bossBarShachiShow（PBZHUDLayout:RegisterBossHPBar、WB_BossHPBar_C:ForSeq_*）
-- §68 实测：给替身注册后显示的那条 WB_BossHPBar 的 Character 一直是空的（13:42 两条都空），只能认空的：
-- 先给 A 注册、认领一条空的，A 认到了再给 B 注册、认领另一条空的
local function bossBarStep(s, tn)
    if s.idle then return end
    local first = SP.side[1]
    if s.idx == 2 and not valid(first.bar) and not first.idle then return end
    if not s.barReg then
        if tn < (s.barTryAt or 0) then return end
        s.barTryAt = tn + 2.0
        local ok, err = G.bossBarShow(s.pup)
        s.barReg = ok
        out("观战原型 %s 血条：RegisterBossHPBar %s", s.tag, ok and "成功" or tostring(err))
        return
    end
    if not valid(s.bar) then
        s.bar = G.bossBarOf(s.pup, true, s.idx == 2 and first.bar or nil)
        if not valid(s.bar) then
            s.barMiss = (s.barMiss or 0) + 1
            if s.barMiss == 15 then
                out("!! 观战原型 %s 血条：注册了但找不到控件", s.tag)
                for _, l in ipairs(G.bossBarDiag(s.pup)) do out("  %s", l) end
            end
            return
        end
        G.bossBarShachiShow(s.bar, true)
        s.nameAt = nil
        out("观战原型 %s 血条：%s", s.tag, short(pathOf(s.bar)))
    end
    local hp, hm = G.attrOf(s.pup, "Health"), G.attrOf(s.pup, "Health_Max")
    local sc, sm = G.attrOf(s.pup, "Shachi"), G.attrOf(s.pup, "Shachi_Max")
    if s.pkt or s.live then hp, hm, sc, sm = s.hp, s.hpm, s.sh, s.shm end       -- 第 1 / 2 步：按包写，不看替身自己的
    local v = { hp = (hp and hm and hm > 0) and hp / hm or nil, sh = (sc and sm and sm > 0) and sc / sm or nil }
    -- 名字每秒重写一次：刚注册时血条自己的初始化可能晚于我们、把名字清掉（同 OPPBAR 的 nameAt）
    if not s.nameAt or tn - s.nameAt > 1.0 then
        s.nameAt = tn
        v.name = s.name or (s.tag == "A" and "A（敌方阵营）" or "B（玩家阵营）")
    end
    local ok = G.bossBarSet(s.bar, v)
    if not ok and not s.setErr then s.setErr = true; out("!! 观战原型 %s 血条：写数值失败", s.tag) end
end

-- §141.14 以前观战期间把藏着的自己挪到主机旁边悬着、退出时放到主机旁边（模组自己改坐标）。
-- §168.5 用户 11-09："统一，并且观战模式也可以用这套传送机制"：改成离主机远就走游戏传送（见 SP.onPacket），自己的角色一直站在游戏放的地方
local function logic()
    local tn = now()
    local a, b = SP.side[1], SP.side[2]
    if not (valid(a.pup) and valid(b.pup)) then SP.stop("替身没了"); return end
    for _, s in ipairs(SP.side) do
        local o = SP.side[3 - s.idx]
        if not s.frames and tn - (s.dressAt or 0) > 0.25 then s.dressAt = tn; if s.pkt or s.live then dressPkt(s) else dress(s) end end
        if s.live then liveStep(s, o, tn) elseif s.pkt then pktStep(s, o, tn) elseif s.frames then recStep(s, o, tn) else scriptStep(s, o, tn) end
        -- 掉下去了（悬崖 / 地图外）：放回开场位置。联机观战跟着主机的坐标走，不管
        if not s.live and s.az then
            local l = loc(s.pup)
            if l and l.Z < s.az - SP.FALL then
                pcall(function() s.pup:K2_SetActorLocation({ X = s.ax, Y = s.ay, Z = s.az + 50.0 }, false, {}, true) end)
                local cm = rawProp(s.pup, "CharacterMovement")
                if valid(cm) then pcall(function() cm.Velocity = { X = 0.0, Y = 0.0, Z = 0.0 } end) end
                s.falls = (s.falls or 0) + 1
                if s.falls <= 3 then out("观战原型 %s 掉下去了（Z %.0f），放回开场位置", s.tag, l.Z) end
            end
        end
        -- 锁定对方（出招追踪、朝向用）；血量低于 40% 补满，杀气补满（放影之武装要）
        if tn - (s.lockAt or 0) > 1.0 then
            s.lockAt = tn
            G.setLockTarget(s.pup, o.pup)
            local hp, mx = G.attrOf(s.pup, "Health"), G.attrOf(s.pup, "Health_Max")
            if hp and mx and hp < mx * 0.4 then
                G.setAttr(s.pup, "Health", mx)
                s.refills = (s.refills or 0) + 1
            end
            local sm, sc = G.attrOf(s.pup, "Shachi_Max"), G.attrOf(s.pup, "Shachi")
            if sm and sc and sc < sm * 0.2 then G.setAttr(s.pup, "Shachi", sm) end
            if G.hpOf(s.pup) and G.hpOf(s.pup) <= 0 then
                out("!! 观战原型 %s 倒下了（锁血没挡住）", s.tag)
            end
        end
    end
    -- 两条 Boss 血条：A / B 各一条（§68 对手血条那套，RegisterBossHPBar 两次）。第 1 步起按状态包写，现在按替身自己的属性写
    if tn - (SP.barAt or 0) > 0.2 then
        SP.barAt = tn
        for _, s in ipairs(SP.side) do bossBarStep(s, tn) end
    end
    if a.live and math.max(tn - (a.lastAt or 0), tn - (b.lastAt or 0)) > LIVE_LOST
        and math.min(tn - (a.lastAt or 0), tn - (b.lastAt or 0)) > LIVE_LOST then
        SP.stop(string.format("%.0f 秒没收到主机转发的包", LIVE_LOST))
        return
    end
    if tn - (SP.statAt or 0) > 10.0 and a.live then
        SP.statAt = tn
        out("观战（联机）| A 主机 包 %d 招 %d 失败 %d 动作 %d 血 %s/%s 偏差最大 %.0f 直接摆 %d | B 对手 包 %d 招 %d 失败 %d 动作 %d 血 %s/%s 偏差最大 %.0f 直接摆 %d | 两人相距 %s | 镜头 %s",
            a.n or 0, a.fired or 0, a.failed or 0, a.acts or 0, tostring(a.hp), tostring(a.hpm), a.errMax or 0, a.snaps or 0,
            b.n or 0, b.fired or 0, b.failed or 0, b.acts or 0, tostring(b.hp), tostring(b.hpm), b.errMax or 0, b.snaps or 0,
            (function() local la, lb = loc(a.pup), loc(b.pup); return (la and lb) and string.format("%.0f", d2(la, lb)) or "?" end)(),
            CAM_NAMES[SP.cam])
        a.errMax, b.errMax = 0, 0
    elseif tn - (SP.statAt or 0) > 10.0 and a.pkt then
        SP.statAt = tn
        out("观战包 | A 第 %d/%d 帧 招 %d 失败 %d 动作 %d 血 %s/%s 当前 %s | B 第 %d/%d 帧 招 %d 失败 %d 动作 %d 血 %s/%s 当前 %s | 镜头 %s",
            a.i, #a.pkt, a.fired or 0, a.failed or 0, a.acts or 0, tostring(a.hp), tostring(a.hpm), G.montageOf(a.pup),
            b.i, #b.pkt, b.fired or 0, b.failed or 0, b.acts or 0, tostring(b.hp), tostring(b.hpm), G.montageOf(b.pup), CAM_NAMES[SP.cam])
    elseif tn - (SP.statAt or 0) > 10.0 then
        SP.statAt = tn
        out("观战原型 | A 血 %s 补血 %d 次 出招 %d 失败 %d 动作 %s | B 血 %s 补血 %d 次 出招 %d 失败 %d 动作 %s | 镜头 %s",
            tostring(math.floor(G.attrOf(a.pup, "Health") or -1)), a.refills or 0, a.fired or 0, a.failed or 0, G.montageOf(a.pup),
            tostring(math.floor(G.attrOf(b.pup, "Health") or -1)), b.refills or 0, b.fired or 0, b.failed or 0, G.montageOf(b.pup),
            CAM_NAMES[SP.cam])
    end
end

-- §167.8 用户 11-09："观战时显示一个 UI 面板写名字挂替身头上"：每人一个小 UMG 界面，每帧按头顶位置投到屏幕上。
-- 联机观战写玩家名字（没收到写"主机" / "对手"），录像 / AI 对打写原来的标签。游戏暂停（菜单）时藏
SP.TAG_UP = 120.0           -- 替身中心往上这么多 = 名字底边（胶囊半高约 90）
local function headName(s)
    if s.live then return (s.nick and s.nick ~= "") and s.nick or (s.tag == "A" and "主机" or "对手") end
    return s.name or s.tag
end
function SP.tagFrame()
    local pc = getP1PC()
    if not valid(pc) then return end
    local paused = false
    pcall(function()
        SP.gs = SP.gs or StaticFindObject("/Script/Engine.Default__GameplayStatics")
        paused = SP.gs:IsGamePaused(pc) == true
    end)
    local tn = now()
    for _, s in ipairs(SP.side) do
        if not (s.nameTag and valid(s.nameTag.w)) and tn >= (s.nameTagTry or 0) then
            s.nameTagTry = tn + 5.0                     -- 建不起来别每帧重试
            s.nameTag = G.nameTagNew(pc)
            if s.nameTag then out("观战头顶名字 %s：界面已建好", s.tag) end
        end
        if s.nameTag then
            G.nameTagSet(s.nameTag, headName(s))
            local pos = nil
            if not paused and not s.idle and valid(s.pup) then
                local l = loc(s.pup)
                if l then pos = { X = l.X, Y = l.Y, Z = l.Z + SP.TAG_UP } end
            end
            G.nameTagPlace(s.nameTag, pc, pos)
        end
    end
end

local function frame()
    for _, s in ipairs(SP.side) do
        local f = s.feed
        if f and f.left > 0 and valid(s.pup) then
            f.left = f.left - 1
            pcall(function() s.pup:AddMovementInput(f.dir, f.scale, true) end)
        end
    end
    pcall(SP.followFrame)
    pcall(placeCam)
    pcall(SP.tagFrame)
    local c = os.clock()
    if c - SP.lastLogic >= SP.TICK then
        SP.lastLogic = c
        local ok, err = pcall(logic)
        if not ok then out("!! 观战原型 -> %s", tostring(err)) end
    end
end

local function loadSide(i)
    local f = ctx.recDir .. (i == 1 and "/spec_a.txt" or "/spec_b.txt")
    local fr = ctx.loadRecording(f)
    if fr and #fr >= 2 then return fr end
    return nil
end

function SP.start()
    if SP.on then return end
    local p1, pc = getP1(), getP1PC()
    if not (valid(p1) and valid(pc)) then out("!! 观战原型：没有玩家1"); return end
    if MATCH.role then out("!! 观战原型：对局中不能开"); return end
    if valid(G.puppet()) then out("!! 观战原型：先按 F6 移除对战用的替身"); return end
    if ST.stableTicks < 90 then out("观战原型：世界还在加载，等几秒再按"); return end
    local l = loc(p1)
    local rot = try("spec rot", function() return p1:K2_GetActorRotation() end)
    if not (l and rot) then return end
    local r = math.rad(rot.Yaw)
    local fx, fy = math.cos(r), math.sin(r)
    local cx, cy = l.X + fx * SP.AHEAD, l.Y + fy * SP.AHEAD
    -- A 在近处、B 在远处，一条线上面对面（横着看就是侧面）
    local spots = { { X = cx - fx * SP.GAP / 2, Y = cy - fy * SP.GAP / 2, Z = l.Z + 50.0, yaw = rot.Yaw },
                    { X = cx + fx * SP.GAP / 2, Y = cy + fy * SP.GAP / 2, Z = l.Z + 50.0, yaw = rot.Yaw + 180.0 } }
    local pkts, live = nil, SP.live.want
    -- §141.14 联机观战：直接在主机的位置生成（以前在自己正前方生成再走过去，路上地面没加载就掉下去）
    local hp = live and ctx.NET and ctx.NET.pos
    if hp and hp.X then
        spots[1] = { X = hp.X, Y = hp.Y, Z = (hp.Z or l.Z) + 50.0, yaw = spots[1].yaw }
        spots[2] = { X = hp.X + fx * SP.GAP, Y = hp.Y + fy * SP.GAP, Z = (hp.Z or l.Z) + 50.0, yaw = spots[2].yaw }
    end
    if live then
        out("观战原型：联机观战，等主机转发的包（A = 主机，B = 对手）")
    elseif SP.src == "pkt" then
        local fa, pa, ha = loadPkt(1)
        local fb, pb, hb = loadPkt(2)
        if fa and fb then
            pkts = { fa, fb }
            out("观战原型：按录像包驱动；A %s %s；B %s %s", pa, tostring(ha), pb, tostring(hb))
        else
            out("!! 观战原型：录像包缺 %s，改用 AI 对打（用 tests\\make_spec_stream.py 生成）", not fa and pa or pb)
        end
    end
    SP.side = {}
    for i = 1, 2 do
        local sp = spots[i]
        local pup, ctl = spawnOne(i, { X = sp.X, Y = sp.Y, Z = sp.Z })
        if not valid(pup) then
            out("!! 观战原型：替身 %s 生成失败", i == 1 and "A" or "B")
            for _, s in ipairs(SP.side) do hideOne(s.pup) end
            SP.side = {}
            return
        end
        local s = { idx = i, tag = i == 1 and "A" or "B", pup = pup, ctl = ctl, sub = {}, ax = sp.X, ay = sp.Y, az = l.Z, ayaw = sp.yaw, cnt = {} }
        turn(s, sp.yaw)
        if live then
            s.live, s.name, s.n = true, s.tag == "A" and "A（主机）" or "B（对手）", 0
        elseif pkts then
            local fr = pkts[i]
            local p0 = fr[1].p
            s.pkt = fr
            s.x0, s.y0 = tonumber(p0.x) or 0, tonumber(p0.y) or 0
            s.rot = sp.yaw - (tonumber(p0.yaw) or 0)                  -- 第一帧的朝向 → 面朝对方
            s.t0, s.i = now(), 1
            s.name = string.format("%s（录像 %s）", s.tag, (LO_short(p0.wc):gsub("^Weapon_Hun_", "")))
            pktApply(s, p0, now())
        else
            s.frames = loadSide(i)
            if s.frames then s.t0, s.i, s.abI = now(), 1, 0 end
        end
        SP.side[i] = s
    end
    -- 按包驱动时两人同一阵营：本机互相打不出伤害，挨打全看包里的 hr=（观战者不判定）
    local fa, fb = setFaction(SP.side[1].pup, (pkts or live) and FRIEND or FOE), setFaction(SP.side[2].pup, FRIEND)
    for _, s in ipairs(SP.side) do G.noStealthByGE(s.pup, "观战原型 " .. s.tag .. " 锁血") end
    out("观战原型开始：A %s（%s，阵营 %s %s），B %s（%s，阵营 %s %s）；A 和 B 的关系 %s",
        short(pathOf(SP.side[1].pup)), live and "联机" or pkts and "录像包" or SP.side[1].frames and "回放 spec_a.txt" or "内置对打",
        (pkts or live) and FRIEND or FOE, fa and "成功" or "失败",
        short(pathOf(SP.side[2].pup)), live and "联机" or pkts and "录像包" or SP.side[2].frames and "回放 spec_b.txt" or "内置对打",
        FRIEND, fb and "成功" or "失败",
        tostring((function()
            local ok, v = pcall(function() return G.factionComp(SP.side[1].pup):GetFactionRelation(SP.side[2].pup) end)
            return ok and v or "?"
        end)()))
    hideSelf(p1, pc)
    SP.statAt = now()
    SP.cam = 1
    if ensureCam(p1) then placeCam(); viewCam() end
    SP.on = true
    SP.gen = SP.gen + 1
    local gen = SP.gen
    if type(LoopInGameThreadAfterFrames) == "function" then
        LoopInGameThreadAfterFrames(1, function()
            if not SP.on or SP.gen ~= gen or ST.travel then return true end
            frame()
        end)
    else
        out("!! 观战原型：没有 LoopInGameThreadAfterFrames")
    end
end

function SP.stop(why)
    if not SP.on then return end
    SP.on = false
    for _, s in ipairs(SP.side) do
        if s.barReg then G.bossBarHide(s.pup) end
        G.nameTagRemove(s.nameTag)
        if s.followReady then G.rootMotionScale(s.pup, 1.0) end     -- §167.9 替身留着复用（AI 对打要根运动）
        hideOne(s.pup)
    end
    SP.side = {}
    SP.unhideAll()                -- §167.3 藏起来的场景物件都显示回来
    SP.camOff, SP.camOffT, SP.clipK, SP.blockedAt, SP.turnedAt = 0.0, 0.0, 1.0, nil, nil
    SP.eyeS, SP.lookS, SP.clipS, SP.smAt, SP.turnAt = nil, nil, nil, nil, nil
    local p1 = getP1()
    showSelf(p1, getP1PC())
    SP.live.want = false
    SP.score = nil
    out("观战原型结束（%s）", why or "")
end

function SP.toggle()
    -- 18:56 实测：联机观战中按 / 退出没发 stop（只看 SP.live.want 不可靠），再按一次又开成了 AI 对打。
    -- 改成按联机会话的角色判断：观战会话里按 / = 退出观战并断开；退出后的观战会话里按 / = 重新开始看
    local inSpec = (MATCH.session and MATCH.session.role) == "spec"
    if SP.on then
        local wasLive = SP.live.want or (SP.side[1] and SP.side[1].live) or inSpec
        SP.stop("小键盘 /")
        if wasLive then
            SP.live.want, SP.live.userStop = false, true
            if ctx.netCmd then ctx.netCmd("stop") end     -- 联机观战：顺便退出观战会话
        end
    elseif inSpec then
        SP.live.userStop = false            -- 还在观战会话里：下一个包到了就重新开始看（不开 AI 对打）
        out("观战：重新开始看")
    else
        SP.live.want = false
        SP.start()
    end
end

-- §141 第 2 步：netRecv 收到带 src= 的包（主机转发）交到这里。第一次收到就自动开观战（按过 / 退出的不再自动开）
function SP.feed(t, tn)
    -- 主机的位置 / 地图给"前往主机所在地图"用（不进 NET.recvOne，不算连上对手）
    local NETT = ctx.NET
    if t.src == "h" and NETT then
        NETT.rmap = t.map
        local x, y, z = tonumber(t.x), tonumber(t.y), tonumber(t.z)
        if x and y then NETT.pos = { X = x, Y = y, Z = z or 0 } end
        NETT.yaw = tonumber(t.yaw) or NETT.yaw
        NETT.specAt = tn
    end
    -- 主机在别的地图：不摆替身（坐标在这张图上是空的），等玩家按 F1 过去
    local myMap = G.mapName and G.mapName(getP1()) or nil
    local otherMap = NETT and NETT.rmap and NETT.rmap ~= "" and myMap and NETT.rmap ~= myMap
    if otherMap then
        if SP.on and SP.live.want then SP.stop("主机在另一张地图") end
        -- 用户 2026-11-07："传送应该在刚进地图的时候，而不是需要上场的时候"：观战者一进来就自动去主机那张图（每个会话一次）
        -- §167.2 停观战时玩家1 无效，锁血没解（MAPGO.dirty 会拒切图）：这里补解；没切成 15 秒后再试，最多 3 次
        if SP.locked and valid(getP1()) then G.unlockSelf(getP1(), "观战结束（补解）"); SP.locked = nil end
        local lv = SP.live
        if ctx.mapGo and not ST.travel and (lv.mapGoN or 0) < 3 and (not lv.mapGo or tn - (lv.mapGoAt or 0) > 15.0) then
            lv.mapGo, lv.mapGoAt, lv.mapGoN = true, tn, (lv.mapGoN or 0) + 1
            lv.groundAt, lv.groundOk = nil, nil
            ctx.notice("主机在另一张地图，传送过去观战", "会出加载画面、自动存档", 5.0)
            out("观战：主机在 %s，自动前往（会先自动存档；第 %d 次）", tostring(NETT.rmap), lv.mapGoN)
            ctx.mapGo()
        end
        return
    end
    SP.live.mapGo, SP.live.mapGoN = false, 0      -- 和主机同图了：主机以后再换图还能再自动跟过去
    -- §168.5 同图但离主机远：走游戏传送过去（会自动存档、出加载画面），到了再看。观战中主机跑出 TP_FAR：先停观战（解锁血，存档检查才放行）再传
    if ctx.travelling() then return end
    local lv, d = SP.live, ctx.hostDist()
    if d and SP.on and SP.live.want and d > SP.TP_FAR then SP.stop(string.format("主机跑远了（%.0f 米），走游戏传送跟过去", d)) end
    if d and not SP.on and d > SP.TP_NEAR and not (lv.userStop or MATCH.role) then
        if SP.locked and valid(getP1()) then G.unlockSelf(getP1(), "观战结束（补解）"); SP.locked = nil end
        if (lv.tpN or 0) < 3 and tn - (lv.tpAt or 0) > 15.0 then
            lv.tpAt, lv.tpN = tn, (lv.tpN or 0) + 1
            out("观战：离主机 %.0f 米，走游戏传送过去（会先自动存档；第 %d 次）", d, lv.tpN)
            ctx.notice(string.format("离主机 %.0f 米，传送过去观战", d), "会出加载画面、自动存档", 5.0)
            lv.groundAt, lv.groundOk = nil, nil
            ctx.toHost()
        end
        return
    end
    if d and d <= SP.TP_NEAR then lv.tpN = 0 end
    if not SP.on then
        if SP.live.userStop or MATCH.role then return end
        if not (NETT and NETT.rmap and NETT.rmap ~= "") then return end      -- 先收到主机的包、知道它在哪张图再开（19:02 实测先摆了一次又收掉）
        -- §168.6 用户 11-09：传到以后先是一片白（地图细节还在加载），B 一生成就陷进地里。主机脚下探到地面再开，最多等 LOAD_WAIT 秒；
        -- 等的时候每秒提示一次，不然玩家以为游戏坏了。探地用不了（nil）就不等
        local lv, p1 = SP.live, getP1()
        if not lv.groundOk and NETT.pos and valid(p1) and G.floorBelow then
            lv.groundAt = lv.groundAt or tn
            local fl = G.floorBelow(p1, NETT.pos, 1000.0)
            local waited = tn - lv.groundAt
            if fl == false and waited < SP.LOAD_WAIT then
                if tn - (lv.groundMsgAt or 0) >= 1.0 then
                    lv.groundMsgAt = tn
                    ctx.notice("正在加载观战场地…", string.format("地图还在加载，最多再等 %d 秒", math.max(0, math.ceil(SP.LOAD_WAIT - waited))), 1.5)
                end
                return
            end
            lv.groundOk = true
            out("观战：场地地面%s（等了 %.1f 秒）", fl == true and "已加载" or (fl == nil and "探测不了，不等" or "还没加载，等够了照样开始"), waited)
        end
        if (SP.live.tryAt or 0) > tn then return end
        SP.live.tryAt = tn + 3.0
        if valid(G.puppet()) then G.removePuppet() end      -- 观战者不需要对战替身
        SP.live.want = true
        SP.start()
        if not SP.on then SP.live.want = false; return end
    end
    if not SP.live.want then return end
    local s = SP.side[t.src == "h" and 1 or 2]
    if not (s and s.live) then return end
    pktApply(s, t, tn)
    s.last, s.lastAt, s.n = t, tn, (s.n or 0) + 1
    if s.idle then setIdle(s, false) end
    if t.nm and t.nm ~= "" then s.nick = t.nm end
    -- 比分：主机说了算，看主机包里的 mt=<状态>:<回合>:<主机分>:<客机分>:<本回合赢家>:<局号>（同 M4）
    if t.src == "h" and t.mt then
        local st, rd, h, c, w = t.mt:match("^(%a+):(%d+):(%d+):(%d+):(%a)")
        if st then
            local sc = { st = st, rd = tonumber(rd), h = tonumber(h), c = tonumber(c), w = w }
            local old = SP.score
            if not old or old.st ~= st or old.rd ~= sc.rd or old.h ~= sc.h or old.c ~= sc.c then
                out("观战比分：%s 第 %d 回合 主机 %d : %d 对手%s", SP.STATE_NAME[st] or st, sc.rd, sc.h, sc.c,
                    (st == "rend" or st == "end") and ("，本回合赢家 " .. (w == "h" and "主机" or w == "c" and "对手" or "平局")) or "")
            end
            if old and old.st ~= "end" and st == "end" then pcall(SP.relayOver, sc) end     -- §141.8 主机下场时谁输谁下
            SP.score = sc
        end
    end
    for _, x in ipairs(SP.side) do
        local nm = (x.nick and x.nick ~= "") and x.nick or (x.tag == "A" and "主机" or "对手")      -- 头顶只显示玩家名字，不带 A / B
        local sc = SP.score
        if sc and sc.st ~= "idle" then
            nm = string.format("%s  %d 分", nm, x.tag == "A" and sc.h or sc.c)
            if x.tag == "A" then nm = nm .. "  · 第 " .. sc.rd .. " 回合 " .. (SP.STATE_NAME[sc.st] or sc.st) end
        end
        local ses = MATCH.session
        local qp = ses and tonumber(ses.qpos)
        if x.tag == "B" and qp and qp > 0 then nm = string.format("%s  · 你排第 %d / %s", nm, qp, tostring(ses.qlen or "?")) end
        if nm ~= x.name then x.name, x.nameAt = nm, nil end
    end
end
SP.STATE_NAME = { cd = "倒计时", fight = "交手中", rend = "回合结束", ["end"] = "打完了", idle = "没开打" }

-- 观战会话结束 / 换了会话：下次再收到包可以重新自动开
function SP.liveReset() SP.live.userStop = false; SP.live.mapGo, SP.live.mapGoN = false, 0; SP.live.groundAt, SP.live.groundOk = nil, nil end

-- ============================================================ §141.7 排队 / 打完换人（房间规矩由主机定，存 net\rules.txt）
-- rot：0 = 不换（默认），1 = 每打完一场客机位就换给队首，2 = 客机输了才换（主机是房主，不下场）
-- rotw：客机位连赢几场强制换（0 = 不限；只在 rot ≠ 0 时看）
-- 换人由联机程序做（cmd=rotate：对手下场排到队尾、队首上场）；对手掉线后的补位联机程序自己做，不用规矩
-- rdyto：轮到的对手多久不按准备算放弃（秒，0 = 不限）：主机自己准备好了、对方迟迟不准备、有人排队 → 换下一位
SP.Q = { cfg = { rot = 0, rotw = 0, rdyto = 0 }, streak = 0, ROT = { 0, 1, 2 }, ROTW = { 0, 2, 3, 5 }, RDYTO = { 0, 30, 60, 120 },
         ROT_NAME = { [0] = { "不换", "OFF" }, [1] = { "每场换", "EVERY MATCH" }, [2] = { "客机输了换", "WHEN THE GUEST LOSES" } } }

function SP.Q.load()
    local t = ctx.readKV and ctx.readKV(ctx.rulesFile) or nil
    for _, k in ipairs({ "rot", "rotw", "rdyto" }) do
        local n = t and tonumber(t[k])
        if n then SP.Q.cfg[k] = n end
    end
end

function SP.Q.set(k, n)
    SP.Q.cfg[k] = n
    local lines, done, f = {}, false, io.open(ctx.rulesFile, "r")
    if f then
        for line in (f:read("*a") or ""):gmatch("[^\r\n]+") do
            if line:match("^" .. k .. "=") then
                if not done then lines[#lines + 1] = k .. "=" .. n; done = true end
            else
                lines[#lines + 1] = line
            end
        end
        f:close()
    end
    if not done then lines[#lines + 1] = k .. "=" .. n end
    ctx.writeFile(ctx.rulesFile, table.concat(lines, "\n") .. "\n")
end

local function nextOf(list, v)
    for i, x in ipairs(list) do if x == v then return list[i % #list + 1] end end
    return list[1]
end

-- 房间设置页：排队几项（主机 / 没联机时点一下换下一档；客机 / 观战者只看）。
-- 观战人数上限存在联机程序里（netcfg.txt maxspec=，lobby.txt 报回来），改的时候发 cmd=maxspec
SP.Q.MAXSPEC = { 0, 2, 4, 8 }
function SP.Q.items(items, T, notHost, flash, lb, cmd)
    local c = SP.Q.cfg
    if lb and cmd then
        -- §141 我自己观战时：排队上场 / 只观战（个人设置，不是房间规矩，谁都能改）
        local noq = lb.specnoq == "1"
        items[#items + 1] = { label = T("我观战时：", "WHEN I WATCH: ") .. (noq and T("只观战，不排队上场", "WATCH ONLY") or T("排队等上场", "QUEUE TO PLAY")),
                              act = function() cmd("specq", "on=" .. (noq and "1" or "0") .. "\n") end }
        local m = tonumber(lb.maxspec) or 4
        items[#items + 1] = { label = T("观战 / 排队人数上限：", "SPECTATOR / QUEUE LIMIT: ") .. (m == 0 and T("不让观战", "NO SPECTATORS") or tostring(m))
                                      .. (notHost and T("（主机设置）", " (HOST'S SETTING)") or T("（主机设置）", " (HOST)")),
                              act = function()
                                  if notHost then flash(T("观战人数由主机设置", "THE HOST DECIDES THIS")); return end
                                  local n = nextOf(SP.Q.MAXSPEC, m)
                                  cmd("maxspec", "n=" .. n .. "\n")
                                  out("联机面板：观战人数上限设为 %s", n == 0 and "不让观战" or tostring(n))
                              end }
    end
    local rn = SP.Q.ROT_NAME[c.rot] or SP.Q.ROT_NAME[0]
    local function rotwText(n) return n == 0 and T("不限", "NO LIMIT") or string.format(T("%d 场", "%d"), n) end
    local tail = notHost and T("（主机设置）", " (HOST'S SETTING)") or T("（主机设置）", " (HOST)")
    items[#items + 1] = { label = T("观战排队，打完换人：", "QUEUE ROTATION: ") .. T(rn[1], rn[2]) .. tail,
                          act = function()
                              if notHost then flash(T("排队规矩由主机设置", "THE HOST DECIDES THIS RULE")); return end
                              local n = nextOf(SP.Q.ROT, c.rot)
                              SP.Q.set("rot", n)
                              out("联机面板：打完换人设为 %s", SP.Q.ROT_NAME[n][1])
                          end }
    items[#items + 1] = { label = T("轮到的人不准备多久算放弃：", "SKIP A GUEST WHO IS NOT READY AFTER: ")
                                  .. (c.rdyto == 0 and T("不限", "NEVER") or string.format(T("%d 秒", "%ds"), c.rdyto)) .. tail,
                          act = function()
                              if notHost then flash(T("排队规矩由主机设置", "THE HOST DECIDES THIS RULE")); return end
                              local n = nextOf(SP.Q.RDYTO, c.rdyto)
                              SP.Q.set("rdyto", n)
                              out("联机面板：不准备算放弃设为 %s", n == 0 and "不限" or (n .. " 秒"))
                          end }
    items[#items + 1] = { label = T("客机连赢几场强制换：", "GUEST WIN STREAK LIMIT: ") .. rotwText(c.rotw) .. tail,
                          act = function()
                              if notHost then flash(T("排队规矩由主机设置", "THE HOST DECIDES THIS RULE")); return end
                              local n = nextOf(SP.Q.ROTW, c.rotw)
                              SP.Q.set("rotw", n)
                              out("联机面板：客机连赢强制换设为 %s", n == 0 and "不限" or (n .. " 场"))
                          end }
end

-- 主机每次驱动调（main.lua lobbyStep）：对手不准备超时 → 换下一位。只在没开打、我已准备、对方连着、有人排队时计时
function SP.Q.tick(tn)
    local c, ses, NET = SP.Q.cfg, MATCH.session, ctx.NET
    local specs = tonumber(ses and ses.specs) or 0
    local fresh = NET and (tn - (NET.lastRecvAt or -100)) < 2.0
    local waiting = c.rdyto > 0 and (ses and ses.role) == "host" and specs > 0 and fresh and MATCH.state == "idle"
                    and not MATCH.role and MATCH.ready and (NET.rrdy or 0) == 0
    if not waiting then SP.Q.waitAt = nil; return end
    SP.Q.waitAt = SP.Q.waitAt or tn
    if tn - SP.Q.waitAt >= c.rdyto then
        SP.Q.waitAt = nil
        SP.Q.streak = 0
        out("排队：对手 %d 秒没准备，换下一位", c.rdyto)
        if ctx.netCmd then ctx.netCmd("rotate", "why=对手没准备\n") end
    end
end

-- §141.8 主机下场（两位对打、主机转发）时一场打完：按规矩让输的下（主机观战，不打，所以 SP.matchOver 不会被调）。
-- 输的 = 最后一回合倒下的（包里的 dead= 等于那一回合）；A = 第一位（h）、B = 第二位（c）。规矩不换（rot = 0）就不换
function SP.relayOver(sc)
    local ses = MATCH.session
    if not (ses and ses.relay == "1") then return end
    local c = SP.Q.cfg
    local a, b = SP.side[1], SP.side[2]
    local function lost(s) return s and s.last and tonumber(s.last.dead) == sc.rd end
    local la, lb = lost(a), lost(b)
    local who = (la and not lb) and "h" or (lb and not la) and "c" or nil
    out("排队（主机下场）：这场打完，%s", who == "h" and "第一位输" or who == "c" and "第二位输" or "分不出谁输（平局 / 没收到倒下）")
    if c.rot == 0 or not who or (tonumber(ses.specs) or 0) == 0 then return end
    -- 连赢：赢的那位连赢 rotw 场也下
    SP.Q.rstreak = SP.Q.rstreak or { h = 0, c = 0 }
    local win = who == "h" and "c" or "h"
    SP.Q.rstreak[win], SP.Q.rstreak[who] = SP.Q.rstreak[win] + 1, 0
    if c.rotw > 0 and SP.Q.rstreak[win] >= c.rotw then
        SP.Q.rstreak[win] = 0
        if ctx.netCmd then ctx.netCmd("rotate", "why=连赢 " .. c.rotw .. " 场\nwho=" .. win .. "\n") end
        return
    end
    if ctx.netCmd then ctx.netCmd("rotate", "why=输了下场\nwho=" .. who .. "\n") end
end

-- 联机面板（连着时）：房主"换下一位上场" / "我也下场" / "我回来打"、对手"我下去观战"
function SP.Q.panel(items, T, lb, cmd, flash)
    local ses = MATCH.session
    local specs = tonumber(ses and ses.specs) or 0
    if lb.role == "host" and ses and ses.relay == "1" then
        items[#items + 1] = { label = T("我回来打（第二位回去观战）", "I'M BACK (SECOND PLAYER WATCHES)"), act = function() cmd("hostup") end }
    elseif lb.role == "host" and specs > 0 and (lb.connected == "1") then
        items[#items + 1] = { label = T("我也下场（让对手和排队第一位对打，我观战）", "STEP DOWN (OPPONENT VS NEXT IN QUEUE)"),
                              act = function() cmd("hostdown"); flash(T("你下场观战了", "YOU ARE WATCHING NOW")) end }
    end
    if lb.role == "host" and specs > 0 then
        items[#items + 1] = { label = string.format(T("换下一位上场（排队 %d 人）", "NEXT IN QUEUE PLAYS (%d WAITING)"), specs),
                              act = function() SP.Q.streak = 0; cmd("rotate", "why=房主换人\n") end }
    elseif lb.role == "client" and lb.connected == "1" then     -- 还在"正在连接"时没有主机可下，不给这个按钮
        -- §141 自己下去 = 观战开关自动切成"只观战"，想再打自己切回"排队"（房主换人 / 补位不碰这个开关）
        items[#items + 1] = { label = T("我下去观战（之后只观战，想打再切回排队）", "STEP DOWN AND WATCH (SWITCH BACK TO QUEUE TO PLAY AGAIN)"),
                              act = function() cmd("tospec"); flash(T("下去观战了（只观战）", "YOU ARE WATCHING NOW (WATCH ONLY)")) end }
    elseif lb.role == "spec" then
        items[#items + 1] = { label = T("换视角：面板关着时 PgUp / PgDn（或小键盘 *）", "CAMERA: PGUP / PGDN WITH THE PANEL CLOSED (OR NUMPAD *)") }
        local qp = ses and tonumber(ses.qpos)
        local noq = lb.specnoq == "1"
        items[#items + 1] = { label = noq and T("只观战（不排队）", "WATCHING ONLY (NOT IN QUEUE)")
                                          or (qp and qp > 0) and string.format(T("观战中，排第 %d / %s", "WATCHING, #%d OF %s IN QUEUE"), qp, tostring(ses.qlen or "?"))
                                          or T("观战中", "WATCHING") }
    end
    -- §141 观战者自己选：排队上场 / 只观战（不在观战时也能先设好，记在联机程序里）
    if lb.role == "spec" then
        local noq = lb.specnoq == "1"
        items[#items + 1] = { label = T("观战时：", "WHEN WATCHING: ") .. (noq and T("只观战，不排队上场", "WATCH ONLY") or T("排队等上场", "QUEUE TO PLAY")),
                              act = function() cmd("specq", "on=" .. (noq and "1" or "0") .. "\n") end }
    end
end

-- 主机打完一场（M4 回到 idle 前调）：按规矩决定要不要让联机程序换人
function SP.matchOver(hostWon)
    local c, ses = SP.Q.cfg, MATCH.session
    local specs = tonumber(ses and ses.specs) or 0
    if hostWon then SP.Q.streak = 0 else SP.Q.streak = SP.Q.streak + 1 end
    if c.rot == 0 or specs == 0 then
        out("排队：这场打完（%s），规矩 %s、观战 %d 人，不换", hostWon and "主机赢" or "客机赢", SP.Q.ROT_NAME[c.rot][1], specs)
        return
    end
    local why = nil
    if c.rot == 1 then why = "每场换"
    elseif c.rot == 2 and hostWon then why = "客机输了"
    end
    if not why and c.rotw > 0 and SP.Q.streak >= c.rotw then why = string.format("客机连赢 %d 场", SP.Q.streak) end
    if not why then
        out("排队：这场打完（%s），按规矩不换（客机连赢 %d 场）", hostWon and "主机赢" or "客机赢", SP.Q.streak)
        return
    end
    SP.Q.streak = 0
    out("排队：这场打完，换人（%s）", why)
    if ctx.netCmd then ctx.netCmd("rotate", "why=" .. why .. "\n") end
end

-- 联机会话角色变了（main.lua lobbyStep 调）：观战者轮到上场 → 收起观战，按普通客机走；下场 → 收到转发包后自动开观战
function SP.onRole(old, new)
    SP.liveReset()
    -- 用户 2026-11-07："为啥不是走离开房间？"：面板"断开"（离开房间）后会话变成 none → 马上收起观战、把角色还回来（以前要等 8 秒没包）
    if old == "spec" and new ~= "spec" and new ~= "client" and SP.on then SP.stop("离开房间") end
    if old == "spec" and new == "client" then
        if SP.on then SP.stop("轮到你上场了") end
        out("排队：轮到你上场了")
        if ctx.flash then ctx.flash("轮到你上场了") end
    elseif old == "client" and new == "spec" then
        out("排队：你下场观战了")
        if ctx.flash then ctx.flash("你下场观战了") end
    end
end

SP._pkt = { load = loadPkt, apply = pktApply, step = pktStep, world = pktWorld }   -- 给 tests/test_spec_pkt.py 用
SP._cam = { place = placeCam }                       -- 给 tests/test_spec_cam.py 用

-- 小键盘 .：换动作来源（AI 对打 ↔ 录像包）；开着时立刻重开
SP.src = "ai"
function SP.nextSrc()
    SP.src = SP.src == "ai" and "pkt" or "ai"
    out("观战原型动作来源 → %s", SP.src == "pkt" and "录像包（rec\\spec_a.pkt / spec_b.pkt）" or "AI 对打")
    if SP.on then SP.stop("换动作来源"); SP.start() end
end

function SP.nextCam() SP.stepCam(1) end

-- 换视角：d = 1 下一个（PgDn / 小键盘 *）、-1 上一个（PgUp）。没在观战什么都不做
function SP.stepCam(d)
    if not SP.on then return end
    SP.cam = (SP.cam - 1 + d) % #CAM_NAMES + 1
    viewCam()
end

-- 切图：旧世界里的替身 / 镜头都没了，别再碰
function SP.onMapLoad()
    if SP.on then SP.on = false; SP.side = {}; out("观战原型：切图，结束") end
    SP.store, SP.camActor = {}, nil
end

return SP
end
