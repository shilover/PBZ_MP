-- base_air.lua —— 从 main.lua 搬出来的 v0.24.2 空中同步（docs/MAIN_SLIM.md）。原来在 main.lua 的 "-- ============================================================ v0.24.2 空中同步" 那段
return function(ctx)
local ST, NET, MATCH, REP, RECM, FN, G = ctx.ST, ctx.NET, ctx.MATCH, ctx.REP, ctx.RECM, ctx.FN, ctx.G
local LO = ctx.LO or _G.LO
local ROOT, NET_DIR = ctx.ROOT, ctx.NET_DIR
local isAttackAbility, openJudge, addResult, playNamed = ctx.isAttackAbility, ctx.openJudge, ctx.addResult, ctx.playNamed
local pathOf, valid, try, rawProp, short, sameObj = G.pathOf, G.valid, G.try, G.rawProp, G.short, G.sameObj
local getP1, puppet, now, setAttr = G.getP1, G.puppet, G.now, G.setAttr
-- main.lua 主循环那段会把 out / hpOf / attrOf / montageOf 换成计时包装（PROF.wrap），这几个由 ctx 传"调用时再取"的包装，
-- 和搬出来之前一样走计时（docs/MAIN_SLIM.md 规矩 3）
local out, hpOf, attrOf, montageOf = ctx.out, ctx.hpOf, ctx.attrOf, ctx.montageOf

-- ============================================================ v0.24.2 空中同步
-- 以前替身只跟 XY（drivePuppet），Z 交给重力：对方跳起来、替身还在地上，对方的空中攻击（Air_A…）在替身身上恒 返回=false
-- （§41 漏判招式、§63 假对手不会跳）。现在：
--   发送：状态包加 air=1/0（我在不在空中，CharacterMovement.IsFalling）+ vz=竖直速度；旧版不发 = 不按状态起跳，和以前一样
--   接收：对方在空中、往上走（vz > LIFT_VZ）或比替身高出 LIFT_DZ，替身在地上，这一跳还没起过 → LaunchCharacter 起跳
--         （AI 控制的替身 Jump() 不起作用）。初速按对方现在的竖直速度和高度差折算：同一个角色类、同样的重力，弧线和对方一样。
--         drivePuppet 只改 XY、保留 Velocity.Z，瞬移也是摆到对方的 Z，都不会把替身拉回地面
--   空中招事件到了而替身还在地上：先起跳，招排队，等替身离地（最多 WAIT 秒）再放；排队期间后面的事件也排着，保持顺序
local AIR = { LIFT_VZ = 150.0, LIFT_DZ = 60.0, MAX_VZ = 2000.0, WAIT = 0.35, JUMP_GRACE = 0.2, LAND_GRACE = 0.3,
              queue = {}, launched = false, launchAt = -100, jumpGAAt = -100, gaLogged = -100, gaLogs = 0,
              rair = nil, rvz = 0.0, n = 0, airOf = G.airOf, launch = G.launch }

-- 状态包里的两个字段（st = G.airOf 的结果；读不到就不发，对方按旧版处理）
function AIR.wire(st)
    if not st then return "" end
    return string.format("air=%d\nvz=%.1f\n", st.falling and 1 or 0, st.vz or 0.0)
end

-- 解包：旧版没有 air= → nil（不知道对方在不在空中：不按状态起跳；空中招照样先起跳再放）
function AIR.parse(t)
    local air = nil
    if t.air == "1" then air = true elseif t.air == "0" then air = false end
    return air, tonumber(t.vz) or 0.0
end

-- 起跳初速：让替身赶上对方的弧线。对方现在比替身高 dz、竖直速度 vz（往上为正）：
--   v0² = max(vz, 0)² + 2·g·max(dz, 0)（和对方同一个最高点）；不低于 minVz，不超过 MAX_VZ
function AIR.launchVz(vz, dz, g, minVz)
    local up = math.max(vz or 0, 0)
    local v = math.sqrt(up * up + 2 * (g or 980.0) * math.max(dz or 0, 0))
    return math.min(math.max(v, minVz or 0), AIR.MAX_VZ)
end

-- 现在要不要按对方的状态起跳。s = { rair, rvz, dz, pupFalling, launched, sinceJumpGA }；返回 是否, 原因
function AIR.shouldLaunch(s)
    if s.rair ~= true then return false, "对方不在空中" end
    if s.pupFalling then return false, "替身已在空中" end
    if s.launched then return false, "这一跳已经起过" end                       -- 不连跳两次
    if (s.sinceJumpGA or 99) < AIR.JUMP_GRACE then return false, "等替身自己的跳跃技能" end
    if (s.rvz or 0) > AIR.LIFT_VZ then return true, "对方在往上跳" end
    if (s.dz or 0) > AIR.LIFT_DZ then return true, "对方比替身高" end
    return false, "对方在往下落（走下台阶 / 快落地）"
end

-- 空中招：名字带 _Air（GA_Hun_ZhanMa_Air_A_C、GA_Hun_Double_JueYing_C_Air_C、GA_Hun_BaiYing_Air_B_C…）
function AIR.isAirMove(n)
    return n:find("_Air", 1, true) ~= nil and isAttackAbility(n)
end

-- 远端一个出招事件在替身身上放出来（以前直接写在 netRecv 里；排队的空中招到时也走这里，判定窗口从真放出来时开）
function AIR.fire(p1, pup, e, tn)
    -- §223 观战替身（PEER.on）：对方那边已经按规则放出来了才会发来，照放（不挡倒计时 / 闪避冷却）；
    -- 不判定、不回报（addResult / openJudge 自己看 PEER.on）
    local spec = PEER.on
    if not spec then
        BAL.noteStance(BAL.rStance, e.name, tn)                    -- §186.3 对方放了架势
        if CDL.puppet(e, tn) then addResult("miss", e.id, 0, tn); return true end      -- §173.7 倒计时里替身不出招
        if DCD.puppet(e, tn) then addResult("miss", e.id, 0, tn); return true end      -- §200 对方闪避冷却中：替身不放
    end
    if not RECM.replayable(e.name) then addResult("miss", e.id, 0, tn); return true end   -- §182 旧版对方发来的不该放的（处决等）替身不放
    if BOWN.defer(pup, e, tn, AIR.fire) then return true end      -- §139.3 独眼弓 R2：等对方松手再射
    if ULT.isUlt(e.name) then ULT.topUp(pup); ULT.mark(e.id, e.name) end    -- v0.27.2 对方放成功了才会发来：替身充能至少 1 格；§165.7 记下可补放
    local before = select(3, LAT.activeMontage(pup))
    if CHG.PRE[e.name] then
        CHG.upgrade(pup, e.name, CHG.PRE[e.name])    -- §92.7 / §243 放之前补前置 GE
        if e.name == "GA_Hun_SlitheringSword_Potential_C" then CHG.potDiag(pup, "放之前") end
    end
    if e.name == TORN.CLS then TORN.start("op", tn) end      -- §383 对方火蓄力：开始数替身的火焰龙卷
    if LO.isEdgeAttack(e.name) then ST.pupEdgeAt = tn end      -- v0.23.7 影之武装伤害系数
    -- §106 武器平衡：放之前就把这招的系数写进替身攻击力（以前等下一次驱动，前摇极短的招可能先出伤害）
    -- §203 summon 行里有的招不算攻击也记（玉双环鬼魅闪身：残影反打的追踪飞环按闪身那一下的系数 + 留场秒数算，闪身本身不进 isAttackAbility）
    if (isAttackAbility(e.name) or BAL.SUMMON[e.name]) and BAL.onFire(BAL.resolve(e.name, BAL.rStance, tn), tn) then LO.rescale(pup, tn) end   -- §186.3 架势里按强化版
    local inp = INP.press(pup, e.name, e.id)                -- §140 实验：先按住键
    local ok, real, pend = RECM.activateOnPuppet(pup, e.name, NET.sub, (spec and "观战 " .. PEER.cur.tag .. " " or "") .. "远端#" .. e.id)
    PEER.note(ok)
    -- §155 替身根本没放出来的招不开判定窗口（11-08 双开：替身悬在虚空放不出招，我摔死掉的血全被记成这招打中），直接回报落空
    -- §243 pending（Snap 先闪避、0.20 秒后再放）：判定窗口按事件时刻先开着，重试放出来时还在窗口里
    if isAttackAbility(e.name) then
        if ok then openJudge(p1, e.id, tn, e.name); ST.pupAtkAt = tn else addResult("miss", e.id, 0, tn) end
    end
    -- §385 挨打方诊断：对方这招在我这边有没有碰到我（本地 AI 的招不记）
    if ok and HMISS and isAttackAbility(e.name) and (spec or not NET.rai) then
        HMISS.onFire(pup, e, tn, spec and PEER.cur and PEER.cur.tag or nil)
    end
    if pend and SNAP then SNAP.log("  §243 %s 先排到闪避后重放，判定窗口已开（等前摇）", e.name) end
    if ok and not pend and not CHG.isHold(e.name) then LAT.afterFire(pup, e, before, tn) end     -- v0.27.0 追帧（§92 蓄力招不追：跳前摇会把蓄力段跳乱）
    if ok and not pend then ANIM.afterFire(pup, e, before, tn) end     -- §100 放成功却没换动作 → 补
    if ok and not pend and CHG.isHold(e.name) then CHG.onFire(pup, e, tn) end        -- §92 替身按对方的松手时刻松手
    if ok and not pend and SHOT.FAM[e.name] then SHOT.onFire(pup, e, tn) end         -- §377 羽弓 / 虎炮：按对方每一发出手
    if CHG.fired[e.id] then CHG.fired[e.id].inp = inp end
    if ok and inp then INP.log("输入实验：远端#%d 替身技能接上 Ability Input Component：%s", e.id, G.linkAbilityInput(pup, e.name)) end
    if not ok and inp then INP.release(e.id, "没放出来") end
    if ok and not pend then ZMX.onFire(pup, e, tn) end                               -- §119 紫冥剑 DB：起手停住等对方召唤
    if ok and not pend and CHG.watched(e.name) then CHG.watch(pup, "替身", e.name, tn, e.id) end
    if ok and not pend and e.name:find("_Jump", 1, true) then AIR.jumpGAAt = tn end
    return ok
end

function AIR.doLaunch(pup, vz, dz, why, tn)
    local v = NET.vel or {}
    local ok = AIR.launch(pup, { X = v.X or 0.0, Y = v.Y or 0.0, Z = vz })
    AIR.launched, AIR.launchAt, AIR.n = true, tn, AIR.n + 1
    out("替身起跳 #%d（%s）：竖直初速 %.0f；对方 air=%s vz=%.0f、比替身高 %.0f；LaunchCharacter %s",
        AIR.n, why, vz, tostring(AIR.rair), AIR.rvz, dz, ok and "成功" or "失败")
end

-- netRecv 收到一个新事件：要排队就排上返回 true（空中招而替身在地上 → 先起跳；前面有在排的 → 跟着排）
function AIR.onEvent(p1, pup, e, tn)
    if #AIR.queue == 0 then
        if not AIR.isAirMove(e.name) then return false end
        local st = AIR.airOf(pup)
        if not st or st.falling then return false end         -- 已经在空中（或读不到移动组件）：照常放
        if PUPCC.held(pup) then return false end              -- §237 被控住不先起跳：照常放（游戏自己挡）
        if tn - AIR.launchAt > AIR.WAIT then
            local loc = try("pup loc", function() return pup:K2_GetActorLocation() end)
            local dz = (AIR.rair and NET.pos and loc) and (NET.pos.Z - loc.Z) or 0.0
            AIR.doLaunch(pup, AIR.launchVz(AIR.rair and AIR.rvz or 0.0, dz, st.g, st.jumpZ), dz, "空中招 " .. e.name .. " 先起跳", tn)
        end
    end
    AIR.queue[#AIR.queue + 1] = { e = e, at = tn }
    return true
end

-- 每帧（netStep 驱动替身之后）：按对方状态起跳、放排队的招
function AIR.step(p1, pup, tn)
    local st = AIR.airOf(pup)
    if not st then return end
    local loc = try("pup loc", function() return pup:K2_GetActorLocation() end)
    local dz = (NET.pos and loc) and (NET.pos.Z - loc.Z) or 0.0
    -- 这一跳结束：对方不在空中（或旧版不知道）、替身落了地
    if AIR.launched and AIR.rair ~= true and not st.falling and tn - AIR.launchAt > AIR.LAND_GRACE then AIR.launched = false end
    -- 诊断（前 10 次）：替身放了对方的跳跃技能，它自己有没有离地（离地了就不用 LaunchCharacter）
    if AIR.jumpGAAt > AIR.gaLogged and tn - AIR.jumpGAAt >= AIR.JUMP_GRACE and AIR.gaLogs < 10 then
        AIR.gaLogged, AIR.gaLogs = AIR.jumpGAAt, AIR.gaLogs + 1
        out("替身的跳跃技能放出来 %.2f 秒后：%s", tn - AIR.jumpGAAt, st.falling and "已离地（游戏自己跳了）" or "还在地上")
    end
    local go, why = AIR.shouldLaunch({ rair = AIR.rair, rvz = AIR.rvz, dz = dz, pupFalling = st.falling,
                                       launched = AIR.launched, sinceJumpGA = tn - AIR.jumpGAAt })
    local cc = go and PUPCC.held(pup)
    if cc then                     -- §237 冻住 / 受击 / 眩晕中不起跳（只在要起跳时才问标签）
        go = false
        PUPCC.launchSkips = PUPCC.launchSkips + 1
        if PUPCC.launchSkips <= 5 then out("替身被控住（%s），不跟对方起跳（%s；§237，第 %d 次）", cc, why, PUPCC.launchSkips) end
    end
    if go then AIR.doLaunch(pup, AIR.launchVz(AIR.rvz, dz, st.g, 0.0), dz, why, tn) end
    if #AIR.queue > 0 and (st.falling or tn - AIR.queue[1].at > AIR.WAIT) then
        if not st.falling then
            out("  !! 替身起跳 %.2f 秒还没离地（移动模式 %s），排队的 %d 个招照放", tn - AIR.queue[1].at, tostring(st.mode), #AIR.queue)
        end
        local q = AIR.queue
        AIR.queue = {}
        for _, it in ipairs(q) do AIR.fire(p1, pup, it.e, tn) end
    end
end

-- §118 闪避方向。闪避技能（GA_Hun_AdvancedDash_* 等）往哪边翻看摇杆，替身没有摇杆 → 游戏给它放原地后撤：
-- 日志里替身放对方的闪避 404 次是 Hun_Tang_Dash_BS、158 次 Dodge_B，真人自己翻的是 Dash_F / Dodge_L / Dodge_R 各方向。
-- 方向一反，翻完离对方真实位置差几米，就被拉回 / 瞬移（用户反馈"翻滚越频繁，闪现越严重"）。
-- 做法：发送方闪避动作换成新的一个时次数 +1，发 dg=<次数>:<动作名>；接收方 WAIT 秒内看替身的动作，
-- 和对方的不一样（替身已经放出自己的后撤，或者等了 SWAP 秒还没换上）就照播对方那个。第一次收到只记次数
DGE = { WAIT = 0.4, SWAP_AT = 0.12, LOG_MAX = 30, logs = 0, fixed = 0, same = 0 }

function DGE.isDodge(m)
    if not m or m:find("MoTian", 1, true) or m:find("PerfectDodge", 1, true) then return false end
    return m:find("Dodge_[FBLR]") ~= nil or m:find("_Roll_[FBLR]") ~= nil or m:find("_Dash_[FLR]") ~= nil
        or m:find("_Dash_BS", 1, true) ~= nil or m:find("^AM_Hun_%a+_Dash_B$") ~= nil
end

function DGE.onPacket(t, tn)
    local n, m = (t.dg or ""):match("^(%d+):([%w_%-]+)$")
    n = tonumber(n)
    if not n then return end
    if DGE.nIn and n > DGE.nIn and DGE.isDodge(m) and not REP.on and not DCD.opMuted(tn) then    -- §200 刚挡掉的闪避不照播
        DGE.want = { m = m, at = tn }
        NET.rDodgeAt = tn
        if m:find("ZuoShang_Dodge", 1, true) then ZMX.dodgeFx(puppet(), m) end      -- §119 紫冥剑布局闪避的金光
    end
    DGE.nIn = n
end

function DGE.step(pup, tn)
    local w = DGE.want
    if not w then return end
    local cur = montageOf(pup)
    if cur == w.m then
        DGE.want, DGE.same = nil, DGE.same + 1
        return
    end
    local late = tn - w.at
    if late > DGE.WAIT then DGE.want = nil; return end
    if not (DGE.isDodge(cur) or late >= DGE.SWAP_AT) then return end
    DGE.want = nil
    local ok = playNamed(pup, w.m)
    if ok then DGE.fixed = DGE.fixed + 1 end
    if DGE.logs < DGE.LOG_MAX then
        DGE.logs = DGE.logs + 1
        out("  对方闪避 %s，替身是 %s → 换成对方的：%s（换过 %d 次，本来就对 %d 次）", w.m, cur ~= "" and cur or "（没动作）",
            ok and "已播" or "播放失败（本机没有这个动作）", DGE.fixed, DGE.same)
    end
end

-- §160 冰冻以挨打方为准（内测 2026-11-08 16:24 v0.30.2："落下白影的武技，他身上那个 y 的追加攻击键都出来了，但对面还是在移动"）。
-- Y = 白影的冰冻突袭 GA_Hun_BaiYing_SpeicalAssault（处决类，Weapon_Hun_BaiYing 自带的 SpecialAttack 通道：目标身上有
-- CharacterState.StatusInfliction.Frost.Effect 就出提示；它不看 CanNotBeExecuted，所以对局里禁处决也拦不住）。
-- 冻住 = 冰冻积累 Frost_Accumulation 攒满后上的 GE_Frost（Hitreact.State.Frozen，站住不能动）。积累是各算各的：
-- A 本机是真 A 砍替身 B，每一刀都算（替身不会格挡 / 闪避，B 那边格挡 / 闪开的也算）→ 替身先冻住、出 Y；
-- B 本机是替身 A 砍真 B，B 自己的游戏判 → 没冻。和杀气一样（替身杀气在本机保持满值，破防只听 brk=），只听挨打方。
-- §160.5 扩到所有异常状态（用户 11-08"那异常状态能矫正么"→"好，让它做"）：点燃 / 中毒（四段）/ 感电 / 流血 / 混沌同一个结构
-- （积累属性攒满 → 挂 GE → CharacterState.StatusInfliction.* 标签）；雷 / 血爆是瞬发、水没有挂状态的 GE，只压积累。
-- 发送方 inf=<类型>:<生效次数>:<段 0=没生效>:<积累>,…（只列有东西的类型，全没有 = "-"）；接收方 INF.step 逐类型：
--   对方生效、替身没有 / 段不对 → 给替身上那一段的 GE（冰冻 → 攻击方出 Y；追击照常发 ev=，对方替身放冰冻突袭在他那边判，双开实测打得中）；
--   对方没生效、替身有 → 跟着对方上的马上撤；本机自己积出来的等 grace（含往返）秒对方还没有就撤（对方确实中了的话 inf= 会先到）；
--   替身的积累比对方多 → 压回对方的值（本机多积的是对方没认的刀）。旧版对方没有 inf= → 不动替身（和以前一样）
-- §355 严格只听挨打方（用户 11-16"替身进了冰冻然后还活蹦乱跳的"→"替身绝不自己进异常状态"，同马车 §269.15 的思路）：
--   ① 替身在本机不积异常：对方发 inf= 时把替身的承受积累倍率 TakenReductionMultiplier_<res>（中性 1）写 0，本机砍替身不涨积累、
--      攒不满就不会自己冻住（以前替身先冻住、出 Y，但位置照样跟着没冻的对方走 = "冻住还活蹦乱跳"，等 grace 才撤）；
--      对方不发 inf=（本地 AI / 旧版）→ 写回 1（§237 替身复用给本地 AI 时 AI 要能被真冻住）。雷没有这个属性、混沌没有积累 → 照旧靠下面撤
--   ② 替身身上有、对方没有的（不是跟着对方上的）马上撤，不再等 grace
--   ③ 对方还在、替身那份 GE 自己到时间掉了 → 隔 REAPPLY 秒补上（以前"掉了也不补"→ 替身比真人先解冻）；同一次最多补 REAPPLY_MAX 回
-- 类型表（资产名字表，HANDOVER §160.5）：lv[i] = 第 i 段 { 标签, 上的 GE, 撤时连带撤的 GE… }；res = 承受积累倍率属性的后缀
-- §373 替身在本机被游戏冻住时上的是怪物版 GE_Frost_Mob（父类 GE_Frost，替身身上同时出现 GE_Frost_Resistance_Mob 可证），
-- 感电同理有 GE_Electrified_Mob / 拙壁盾的 GE_Electrified_ZhuoBiDun。RemoveActiveGameplayEffectBySourceEffect 只认**同一个类**
-- （不认子类），以前只撤 GE_Frost → 替身的 GE_Frost_Mob 撤不掉、日志照样写"已撤"（只看调用有没有报错），替身一直冻着放不出招，
-- 位置照样跟网络走 = 内测"冻住后对方还能动，但对方打不出伤害"。变体都列成"撤时连带撤的 GE"，INF.strip 撤完按标签读回确认
INF = { ROOT = "CharacterState.StatusInfliction", GE_DIR = "/PBZCombatAsset/Prototypes/GameplayEffects/Inflictions/",
        EVERY = 3, ACC_EVERY = 9, GRACE = 0.15, GRACE_MAX = 0.6, ACC_SLACK = 1.0, LOG_MAX = 60, logs = 0,
        REAPPLY = 0.3, REAPPLY_MAX = 20, immune = nil, STUCK_LOG_MAX = 12, stuckLogs = 0,
        st = { mirror = 0, strip = 0, clamp = 0, stuck = 0 }, me = {}, pup = {}, r = nil,
        TYPES = {
            { id = "frost", name = "冰冻", acc = "Frost_Accumulation", res = "FrostAccumulation", key = "Frost",
              lv = { { "CharacterState.StatusInfliction.Frost.Effect", "GE_Frost", "GE_Frost_Mob" } } },
            { id = "ignite", name = "点燃", acc = "Ignite_Accumulation", res = "IgniteAccumulation",
              lv = { { "CharacterState.StatusInfliction.Ignite", "GE_Ignite" } } },
            { id = "poison", name = "中毒", acc = "Poison_Accumulation", res = "PoisonAccumulation",
              lv = { { "CharacterState.StatusInfliction.Poison.Phase0", "GE_Poison_Phase0" },
                     { "CharacterState.StatusInfliction.Poison.Phase1", "GE_Poison_Phase1" },
                     { "CharacterState.StatusInfliction.Poison.Phase2", "GE_Poison_Phase2" },
                     { "CharacterState.StatusInfliction.Poison.Phase3", "GE_Poison_Phase3" } } },
            { id = "elec", name = "感电", acc = "Electrified_Accumulation", res = "ElectrifiedAccumulation", key = "Electrified",
              lv = { { "CharacterState.StatusInfliction.Electrified", "GE_Electrified", "GE_Electrified_Mob", "GE_Electrified_ZhuoBiDun" } } },
            { id = "bleed", name = "流血", acc = "Bleed_Accumulation", res = "BleedAccumulation",
              lv = { { "CharacterState.StatusInfliction.Bleed.Small", "GE_BleedSmall" } } },
            { id = "chaos", name = "混沌",
              lv = { { "CharacterState.StatusInfliction.Chaos", "GE_ChaosEffect", "GE_Chaos" } } },
            { id = "thunder", name = "雷", acc = "Thunder_Accumulation", lv = {} },
            { id = "bburst", name = "血爆", acc = "BloodBurst_Accumulation", res = "BloodBurstAccumulation", lv = {} },
            { id = "water", name = "水", acc = "Water_Accumulation", res = "WaterAccumulation", lv = {} },
        } }

function INF.say(fmt, ...)
    if INF.logs >= INF.LOG_MAX then return end
    INF.logs = INF.logs + 1
    out(fmt, ...)
end

function INF.gePath(short) return INF.GE_DIR .. short .. "." .. short .. "_C" end

-- 每个类型现在在第几段（0 = 没生效）。先问父标签：身上没有任何异常状态时只问一次
function INF.levels(actor)
    local res = {}
    local any = G.tagsMatching(actor, { INF.ROOT })
    if not (any and #any > 0) then return res end
    for _, ty in ipairs(INF.TYPES) do
        local tags = {}
        for i, l in ipairs(ty.lv) do tags[i] = l[1] end
        if #tags > 0 then
            local hit = G.tagsMatching(actor, tags) or {}
            local set = {}
            for _, h in ipairs(hit) do set[h] = true end
            for i = #ty.lv, 1, -1 do
                if set[ty.lv[i][1]] then res[ty.id] = i; break end
            end
        end
    end
    return res
end

-- 发送方：每 EVERY 帧看一次自己身上的异常状态（积累每 ACC_EVERY 帧读一次），返回 inf= 的值
function INF.mine(p1, tn)
    if INF.wire and ST.ticks % INF.EVERY ~= 0 then return INF.wire end
    local lv = INF.levels(p1)
    local readAcc = INF.wire == nil or ST.ticks % INF.ACC_EVERY == 0
    local parts = {}
    for _, ty in ipairs(INF.TYPES) do
        local s = INF.me[ty.id] or { n = 0, lv = 0, acc = 0 }
        INF.me[ty.id] = s
        local l = lv[ty.id] or 0
        if l > s.lv then
            s.n = s.n + 1
            if s.lv == 0 then s.onAt = tn end
            INF.say("※ 我%s了（%s第 %d 次%s，inf= 告诉对方，他那边替身也跟着）", ty.name, s.lv == 0 and "" or "加重，",
                s.n, #ty.lv > 1 and string.format("，第 %d 段", l) or "")
            if s.lv == 0 then DOT.onStart(ty.id, tn) end          -- §199 持续伤害钉住来源招的系数
        elseif l == 0 and s.lv > 0 then
            INF.say("※ 我%s结束了（%.1f 秒）", ty.name, tn - (s.onAt or tn))
            DOT.onEnd(ty.id, tn)
        end
        s.lv = l
        if l > 0 then DOT.ctrlStep(p1, ty, s, tn) end           -- §199 控制类异常时长上限
        if readAcc and ty.acc then s.acc = attrOf(p1, ty.acc) or s.acc end
        if s.n > 0 or s.lv > 0 or s.acc >= 0.5 then
            parts[#parts + 1] = string.format("%s:%d:%d:%.0f", ty.id, s.n, s.lv, s.acc)
        end
    end
    DOT.takeStep(p1, tn)        -- §199.9 持续伤害按钉住系数压自己的承伤乘法
    INF.wire = #parts > 0 and table.concat(parts, ",") or "-"
    return INF.wire
end

-- 接收方：记下对方的异常状态；旧版没有 inf= → INF.r = nil，不动替身。没列出的类型 = 0 次、没生效、积累 0
function INF.onPacket(t, tn)
    if not t.inf or t.inf == "" then INF.r = nil; return end
    local r = {}
    for id, n, l, acc in t.inf:gmatch("(%a+):(%d+):(%d+):([%d%.]+)") do
        r[id] = { n = tonumber(n), lv = tonumber(l), acc = tonumber(acc) }
    end
    INF.r = r
end

function INF.reset()
    INF.r, INF.pup = nil, {}
    if PEER.on then return end       -- §223.6 观战替身：只清自己那份（DOT / AIF 是对战双方自己的，DOT.takenBack 会写观战者自己的角色）
    DOT.src, DOT.chillAt = {}, nil   -- §199 换对手 / 断开：上一个对手挂的持续伤害不再钉（§206 冰缓也清）
    for kind in pairs(DOT.taken) do DOT.takenBack(DOT.p1, kind, "换对手 / 断开") end   -- §199.9
    if AIF then AIF.reset(nil, "换对手 / 断开") end                                     -- §217
end

function INF.grace()
    local rtt = LAT.rttMs and LAT.rttMs()
    return math.min(INF.GRACE + (rtt and rtt * 1.5 / 1000 or 0.15), INF.GRACE_MAX)
end

-- 撤掉 actor 身上这个类型所有段的 GE（含连带的、§373 的 _Mob 变体）。
-- §373 撤完按标签读回：返回 true = 这个类型的标签真没了（以前返回"调用没报错"，撤不掉也写"已撤"）；
-- 读回标签还在 → false，并记一行身上还挂着哪些相关 GE（名字带类型关键字的；最多 STUCK_LOG_MAX 行），下回再撤
function INF.strip(actor, ty)
    local called = false
    for _, l in ipairs(ty.lv) do
        for k = 2, #l do called = LO.removeGE(actor, INF.gePath(l[k])) or called end
    end
    if #ty.lv == 0 then return called end
    local tags = {}
    for i, l in ipairs(ty.lv) do tags[i] = l[1] end
    local left = G.tagsMatching(actor, tags)
    if left == nil then return called end            -- 读不到标签（没有 ASC）：只能按调用结果算
    if #left == 0 then return true end
    INF.st.stuck = INF.st.stuck + 1
    if INF.stuckLogs < INF.STUCK_LOG_MAX then
        INF.stuckLogs = INF.stuckLogs + 1
        local names = {}
        local set = G.geSet and G.geSet(actor)
        for n in pairs(set or {}) do
            if ty.key and n:find(ty.key, 1, true) then names[#names + 1] = n end
        end
        table.sort(names)
        out("!! %s撤完标签还在（%s）：身上相关的 GE %s（§373，第 %d 次；下回再撤）", ty.name, table.concat(left, ","),
            set and (#names > 0 and table.concat(names, ",") or "没有名字带 " .. tostring(ty.key) .. " 的") or "读不到", INF.st.stuck)
    end
    return false
end

-- §355 ① 替身不在本机积异常：on = true 把 TakenReductionMultiplier_<res> 写 0（每 ACC_EVERY 帧复查一次，被游戏重算回去就再写），
-- on = false 写回 1。INF.immune = 写过 0 的那个替身的路径
function INF.setImmune(pup, on)
    local key = pathOf(pup)
    if not on then
        if INF.immune ~= key then return end
        INF.immune = nil
        for _, ty in ipairs(INF.TYPES) do
            if ty.res then setAttr(pup, "TakenReductionMultiplier_" .. ty.res, 1.0) end
        end
        INF.say("  替身的异常积累倍率写回 1（对方不发 inf=：本地 AI / 旧版，替身照常在本机积；§355）")
        return
    end
    if INF.immune == key and ST.ticks % INF.ACC_EVERY ~= 0 then return end
    local wrote = {}
    for _, ty in ipairs(INF.TYPES) do
        if ty.res then
            local a = "TakenReductionMultiplier_" .. ty.res
            local v = attrOf(pup, a)
            if v and v > 0.001 then
                setAttr(pup, a, 0.0)
                wrote[#wrote + 1] = string.format("%s %.2f→%s", ty.name, v, tostring(attrOf(pup, a)))
            end
        end
    end
    if INF.immune ~= key or #wrote > 0 then
        INF.say("  替身不在本机积异常（只跟对方的 inf=；§355）：%s", #wrote > 0 and table.concat(wrote, "，") or "已经是 0")
    end
    INF.immune = key
end

-- 接收方每 EVERY 帧：替身的异常状态逐类型跟对方走。p.ours = 替身这次的状态是跟着对方的（对方一结束马上撤）
function INF.step(pup, tn)
    local R = INF.r
    if REP.on or ST.ticks % INF.EVERY ~= 0 then return end
    if not R then
        if INF.immune then INF.setImmune(pup, false) end       -- §355 对方不发 inf=：替身照常在本机积
        return
    end
    INF.setImmune(pup, true)                                   -- §355 ① 替身不在本机积
    local plv = INF.levels(pup)
    local readAcc = ST.ticks % INF.ACC_EVERY == 0
    for _, ty in ipairs(INF.TYPES) do
        local r = R[ty.id] or { n = 0, lv = 0, acc = 0 }
        local p = INF.pup[ty.id] or {}
        INF.pup[ty.id] = p
        if readAcc and ty.acc and r.lv == 0 then
            local pacc = attrOf(pup, ty.acc)
            if pacc and pacc > r.acc + INF.ACC_SLACK then
                setAttr(pup, ty.acc, r.acc)
                INF.st.clamp = INF.st.clamp + 1
                if INF.st.clamp <= 5 or INF.st.clamp % 50 == 0 then
                    INF.say("  替身%s积累 %.0f，对方 %.0f → 压回对方的（本机多积的是对方没认的刀，第 %d 次）", ty.name, pacc, r.acc, INF.st.clamp)
                end
            end
        end
        local cur = plv[ty.id] or 0
        if #ty.lv == 0 then
            -- 瞬发类：只压积累
        elseif r.lv > 0 then
            p.localAt = nil
            local key = r.n .. ":" .. r.lv
            if cur == r.lv then
                p.ours, p.key = true, key
            elseif p.key == key and cur == 0 and p.ours and (p.re or 0) < INF.REAPPLY_MAX
                   and tn - (p.fixAt or -1e9) >= INF.REAPPLY then
                -- §355 ③ 对方还在、替身那份到时间先掉了 → 补上（只认上成功过的那次：上不去的不反复试）
                p.fixAt, p.re = tn, (p.re or 0) + 1
                local ge = ty.lv[math.min(r.lv, #ty.lv)][2]
                local ok = LO.applyGE(pup, INF.gePath(ge), "替身" .. ty.name)
                INF.say("※ 对方还在%s，替身那份先掉了 → 补上 %s（这次第 %d 回）：%s", ty.name, ge, p.re, ok and "已上" or "上不去")
            elseif p.key ~= key or (cur > 0 and tn - (p.fixAt or -1e9) >= INF.grace()) then
                -- 每次生效（每一段）只上一次，上不上去都不反复试（替身的 GE 先到时掉了也不补）；
                -- 替身在别的段上（本机自己积到更重的中毒）→ 隔 grace 换回对方那一段
                p.key, p.fixAt, p.re = key, tn, 0
                if cur > 0 then INF.strip(pup, ty) end
                local ge = ty.lv[math.min(r.lv, #ty.lv)][2]
                local ok = LO.applyGE(pup, INF.gePath(ge), "替身" .. ty.name)
                p.ours = ok or nil
                INF.st.mirror = INF.st.mirror + 1
                INF.say("※ 对方%s（第 %d 次%s）→ 替身也%s：%s", ty.name, r.n, #ty.lv > 1 and string.format("，第 %d 段", r.lv) or "",
                    ty.name, ok and ("已上 " .. ge .. (ty.id == "frost" and "（出 Y 追击提示）" or "")) or "上不去")
            end
        elseif cur > 0 then
            local why
            if p.ours then
                why = "对方的结束了"
            else
                why = string.format("本机自己上的，对方没有（对方积累 %.0f；§355 不等）", r.acc)   -- §355 ② 马上撤
            end
            if why then
                local ok = INF.strip(pup, ty)
                if ty.acc then setAttr(pup, ty.acc, r.acc) end
                p.ours, p.localAt = nil, nil
                INF.st.strip = INF.st.strip + 1
                -- §373 撤不掉的下回（EVERY 帧后）接着撤；同一段撤不掉只记第一次（细节 INF.strip 记）
                if ok or not p.stuck then
                    INF.say("※ 替身撤掉%s（%s）：%s", ty.name, why, ok and "已撤" or "撤不掉（标签还在，接着撤）")
                end
                p.stuck = (not ok) or nil
            end
        else
            p.ours, p.localAt, p.stuck = nil, nil, nil
        end
    end
end

-- F4a（docs/FORNET_SPLIT.md）：对局框架（状态机 / mt= 编解码 / §210 规则指纹 / §173 回合时限的框架半边 / §223 观战状态换入换出 /
-- 看门狗式 pcall）在 fornet_match.lua；游戏那边的事经 deps 表回调。全局：主块 local 已满 200 个。
-- RFP.rows 用的颜色在 HUD 底座装完后填（FMATCH.COL.RED）；CFG / NET / FNET 在这之前都已定义
FMATCH = (function()
    local ok, mk = pcall(require, "fornet_match")
    if ok and FORNET and FORNET.adopt then mk = FORNET.adopt("fornet_match", mk) end     -- F6：实例登记到宿主（FORNET.mods）
    if not ok then ok, mk = pcall(dofile, ROOT .. "/Scripts/fornet_match.lua") end
    if not (ok and type(mk) == "function") then error("fornet_match.lua 加载失败：" .. tostring(mk)) end
    return mk({ out = out, MATCH = MATCH, T = function(zh, en) return FN.T(zh, en) end, relSend = function(...) return FNET.REL.send(...) end,
                hash = function(x) return CFG.hash(x) end, num = function(v) return CFG.num(v) end,
                peerIsAi = function() return NET.rai end, peerVersion = function() return NET.rav end,
                -- §295 规则指纹在多人 / 对决里认它们自己的局号和"我在不在打"（不在多人房 = nil → 照旧用 1v1 的 MATCH）
                matchId = function() local sm = BASEHOOK.mp; if sm and sm.rfpCtx and sm.inMp and sm.inMp() then local _, mid = sm.rfpCtx(); return mid end end,
                matchOn = function() local sm = BASEHOOK.mp; if sm and sm.rfpCtx and sm.inMp and sm.inMp() then local on = sm.rfpCtx(); return on end end,
                -- 这一场数值表影响伤害时（武器平衡 / 标准数值 / §216 三个开关也取表里的秒数 / 杀气）返回用上的表哈希，否则 nil
                cfgHash = function(flags)
                    local tbl = flags and (flags.bal or flags.std or flags.gcd or flags.dgc or flags.sycd or flags.stg or flags.swk)
                    return tbl and (CFG.usedHash or CFG.localHash) or nil
                end,
                -- §210 规则指纹对不上时写成人话的键名
                ruleNames = { bo = { "局数", "BEST OF" }, dm = { "伤害倍率", "DAMAGE" }, ab = { "全部可格挡", "ALL BLOCKABLE" }, tl = { "回合时限", "TIME LIMIT" },
                 ctr = { "红蓝光反击", "COUNTERS" }, bal = { "武器平衡", "WEAPON BALANCE" }, med = { "血瓶", "POTIONS" },
                 npos = { "对手位置严格跟随", "STRICT FOLLOW" }, std = { "标准数值", "STANDARD STATS" }, cs = { "作弊数据采样", "CHEAT SAMPLING" },
                 gcd = { "火枪冷却", "GUN COOLDOWN" }, dgc = { "闪避扣杀气", "DODGE COST" }, sycd = { "瞬影冷却", "FLASH STEP CD" }, stg = { "精防硬直", "DEFLECT STAGGER" }, swk = { "切武器保持杀气", "SWITCH KEEPS SHACHI" },
                 dif = { "对局难度", "MATCH DIFFICULTY" },
                 ult0 = { "开局精纯杀气", "START ULT" }, ultx = { "精纯杀气获取", "ULT GAIN" }, sp0 = { "开局暗源", "START EDGE" },
                 resm = { "资源每场 / 每局", "RESOURCE RESET" }, acc = { "饰品等级", "ACCESSORY LEVEL" }, accn = { "生效饰品数量", "ACCESSORY LIMIT" },
                 accban = { "禁用饰品", "BANNED ACCESSORIES" }, wpnban = { "禁用武器", "BANNED WEAPONS" }, edgeban = { "禁用影之武装", "BANNED EDGES" },
                 cfg = { "数值表", "BALANCE TABLE" }, rk = { "定死的规则", "LOCKED RULES" }, f = { "指纹格式", "FORMAT" } } })     -- 11-13：rk 的名字排位扩展包装上时改成"武林盟主"
end)()
-- F4b：解说 / 主机定死的房间规则（NET.roomRules，session 的 roomrules= 或 lobby.txt 的）登记成规则来源；排位那份在 pbz_ranked.lua 里登记（优先级更高）
FMATCH.addRules({ name = "room", kind = "room", priority = 0, active = function() return NET.roomRules() ~= nil end, rules = function() return NET.roomRules() end })
-- §173 回合干净开打 + 回合时限（内测反馈 11-09："倒计时 3 秒里能打人挂 debuff / 控制"、"慈母护符太强，打不死"）。
-- ① 倒计时里双方挂游戏自己的无敌效果（剧情演出用的 GE_FlowInvulnerable，给 CharacterState.Stand.Invulnerable.Debug；
--    Boss 开战前那个 GE_BossInvulnerableBeforeCombat 带 Unselectable，会锁不上，不用）。挂不上就退回让替身倒计时里是友方（不互砍）
-- ② 交手开始那一刻：撤掉无敌；自己和替身身上有有限时长的效果（异常状态、喝药 / 武器技能的增益、冷却）和异常状态的 GE 全撤（G.cleanse，§208），
--    异常积累清 0（自己走游戏的改属性函数 GE_MA_*_Accumulation_*_Override），然后回满（refill）。
--    不撤：锁血 GE_LockHealth（撤了会真死）、饰品 / 标准数值自己挂的（ACC / STD 管）、没有时限的（天赋 / 装备被动）、
--    名字 GE_Talent_* / GE_Accessory_* 的（就算有时限：被动触发的，撤了不一定会再挂）
-- ③ 回合时限（房间设置 tl，秒，0 = 不限；武林盟主固定 180）：交手满 tl 秒还没人倒下 → 本回合受到伤害多的一方判负，一样多平局。
--    受伤 = 交手开始后自己血量每次往下掉的累加（慈母护符 / 喝药回的血不抵）；状态包 tk=<回合>:<受伤> 发给对方。
--    主机判（自己的 + 客机 tk=；对方没有 tk=（本地 AI / 旧版）→ 按对方状态包的 血上限 − 血量），结果照常走 mt= 和可靠事件 rend，
--    另发可靠事件 rtime=<对局> <回合> <主机受伤> <客机受伤>，客机屏幕上显示"时间到"和两边的数
RT = { INV_GE = "/Game/PBZContent/Blueprint/FlowGraph/GameplayEffect/GE_FlowInvulnerable.GE_FlowInvulnerable_C",
       INV_TAG = "CharacterState.Stand.Invulnerable.Debug",
       shield = nil, taken = 0, hp = nil, round = 0, rtk = nil, info = nil, logs = 0,
       -- 不管有没有时限都撤的（INF 段的异常状态 GE + 持续伤害 / 积累标记，资产名字表 Prototypes/GameplayEffects/Inflictions/）
       FORCE = { GE_Ignite_Dot = true, GE_Poison_Dot_Phase1 = true, GE_Poison_Dot_Phase2 = true, GE_Poison_Dot_Phase3 = true,
                 GE_Electrified_VFX = true, GE_Frost_HasAccumulation = true, GE_Thunder_HasAccumulation = true, GE_Suffocation = true,
                 -- §362 妖锯妖气（挨打方身上的侵蚀 + 引爆后约 3 秒的不可格挡标记，资源图 _tools/gasgraph/yaoju.json）：有没有时限都撤
                 GE_YaoJu_Erosion = true, GE_YaoJu_Explode_CanNotDeflect = true,
                 -- §362.1 其他挂在挨打方身上、DurationPolicy = Infinite 的 debuff（按时限规则撤不掉；bp_decode 读的资产，11-16）：
                 -- 红妆鬼斩石蒜花毒（GuiTouBlade_Debuff* / InDebuffArea*）、血滴子流血、虚空化山、玉簪陷阱
                 GE_Hun_GuiTouBlade_Debuff = true, GE_Hun_GuiTouBlade_Debuff_Tick = true, GE_Hun_GuiTouBlade_Debuff_Effect = true,
                 GE_Hun_GuiTouBlade_Debuff_Effect_BigFlower = true, GE_Hun_GuiTouBlade_Debuff_Effect_UltraFlower = true,
                 GE_Hun_GuiTouBlade_InDebuffArea = true, GE_Hun_GuiTouBlade_InDebuffArea_BigFlower = true, GE_Hun_GuiTouBlade_ExitDebuffArea = true,
                 GE_ShachiWeapon_XueDiZi_BleedInitial = true, GE_ShachiWeapon_XueDiZi_Bleed_Lv1 = true,
                 GE_ShachiWeapon_XueDiZi_Bleed_Lv2 = true, GE_ShachiWeapon_XueDiZi_Bleed_Lv3 = true,
                 GE_ShachiWeapon_XuKongHuaShan_Debuff = true, GE_YuZan_TrapDebuff = true, GE_YuZan_TrapDebuff_Tick = true } }
for _, ty in ipairs(INF.TYPES) do
    for _, l in ipairs(ty.lv) do for k = 2, #l do RT.FORCE[l[k]] = true end end
end

-- F4a：RT 的框架半边（limit / left / 规则行折行 / begin / track / wire / onPacket / check）在 fornet_match.lua，装到这张表上；
-- 游戏那边给：排位 / 房间定死的规则、房间设置、主机发的 tl=、血量、按对方血量算的受伤
FMATCH.rtInstall(RT, { fixedRules = function() return NET.fixedRules() end, resOf = function(k) return NET.resOf(k) end,
                       peerTl = function() return NET.rres.tl end, hpOf = hpOf,
                       peerDamage = function() if NET.remoteHpm and NET.remoteHp then return math.max(0, NET.remoteHpm - NET.remoteHp) end end })

-- 撤不撤：锁血不撤；饰品 / 标准数值自己挂的不撤；异常状态的撤；其余有时限的撤
function RT.keep()
    local k = {}
    local function add(path) local n = path and path:match("/([%w_]+)%.[^/]*$"); if n then k[n] = true end end
    for _, p in ipairs(G.GE_CANDIDATES or {}) do add(p .. "." .. (p:match("([^/]+)$") or "")) end
    for path in pairs(STD.gearMine or {}) do add(path) end
    for _, path in ipairs(STD.added or {}) do add(path) end
    for _, path in pairs((ACC.mine and ACC.mine.geAdded) or {}) do add(path) end
    return k
end

-- phase：日志里的叫法（nil = 交手开始；§362 对局结束也走这里，规则同一套）
function RT.cleanse(actor, who, self_, phase)
    if not valid(actor) then return end
    local keep = RT.keep()
    -- §173.11 只读：按规则没撤的（天赋 / 饰品 / 武器无时限的）、留着的有时限效果；§208 加 时长读不到的、其他无时限的
    local ruled, timedLeft, unk, other = { tal = {}, acc = {}, wpn = {} }, {}, {}, {}
    local done, fail = G.cleanse(actor, function(n, timed, left, finite)
        if finite == nil then finite = timed and left ~= nil end      -- 旧适配层没有第 4 个参数
        local function stay()
            if timed then timedLeft[#timedLeft + 1] = left and string.format("%s %.1fs", n, left) or (n .. " ?s") end
            return false
        end
        if keep[n] or n:find("LockHealth", 1, true) then return stay() end
        -- §208（用户 11-10："全部的临时 buff 包括药品和武器的都在开始前清理掉"）：判据改成"有没有有限时长"，不再按名字挑。
        -- 撤 = 异常 / 负面（RT.FORCE，没时限也撤）+ 喝药（GE_Medicine_ 开头，§173.10）+ 其余一切有有限时长的：
        --   武器武技增益（GE_Weapon_Tang_Buff_Lv1、GE_Weapon_Double_Buff、GE_BaiYing_Buff、GE_LuanYing_Buff_P2…）、
        --   影之武装 / 武器的临时状态（GE_ChiZheCanJian_Prezui_3、GE_XuKongHuaSHn_FiledTime、GE_TieKuangQuanTao_Charge…）、冷却。
        --   §173.8 当"武器形态"留下的三个，日志里都是读秒前放招挂上的有时限效果（11:34–11:37 替身），没看到撤了之后少东西，一并撤。
        -- 留 = 天赋 GE_Talent_* / 饰品 GE_Accessory_*（就算有时限：被动触发的，撤了不一定再挂；§173.10）、模组自己挂的（keep / 锁血）、
        --   没有时限的（武器被动 / 等级 / Combo / CanBuff、形态、天赋）、有时限但时长读不到的（GrantPotential 这类每回合都在的）
        if n:match("^GE_Talent_") then ruled.tal[#ruled.tal + 1] = n; return stay() end
        if n:match("^GE_Accessory_") then ruled.acc[#ruled.acc + 1] = n; return stay() end
        if RT.FORCE[n] == true or n:match("^GE_Medicine_") ~= nil then return true end
        if finite then return true end
        if n:match("^GE_Weapon_") then ruled.wpn[#ruled.wpn + 1] = n; return stay() end
        if timed then unk[#unk + 1] = n; return false end
        other[#other + 1] = n
        return false
    end)
    local acc = {}
    for _, ty in ipairs(INF.TYPES) do
        local v = ty.acc and attrOf(actor, ty.acc)
        if v and v > 0.01 then
            local ok = false
            if self_ and G.attrModSet then ok = (pcall(G.attrModSet, actor, ty.acc, 0)) and (attrOf(actor, ty.acc) or 1) < 0.01 end
            if not ok then setAttr(actor, ty.acc, 0) end
            acc[#acc + 1] = string.format("%s %.0f→0%s", ty.name, v, ok and "" or "（直接写）")
        end
    end
    if done == nil then
        out("!! %s清状态（%s）：读不到效果表", phase or "交手开始", who)
    elseif #done + #fail + #acc > 0 or RT.logs < 6 then
        RT.logs = RT.logs + 1
        out("%s清状态（%s）：撤掉 %d 个效果 %s%s；异常积累 %s", phase or "交手开始", who, #done, table.concat(done, ","),
            #fail > 0 and ("；撤不掉 " .. table.concat(fail, ",")) or "", #acc > 0 and table.concat(acc, "，") or "无")
    end
    -- §208 替身撤掉的里有对方 wge= 同步来的（LO.wgeOn）：LO.wgeOn 照旧记着"上过了"，对方读秒前的旧 wge= 还带着它时不会马上补回来；
    -- 对方自己开打也撤了、新的 wge= 不带它 → LO.syncWge 走"对方没了"清掉记号；之后对方再放武技 → 新列表带上 → 正常补
    local won = (not self_) and done and LO and LO.wgeOn
    if won then
        local hit = {}
        for id in pairs(won) do
            local short = id:match("([%w_]+)$")
            for _, n in ipairs(done) do if n == short then hit[#hit + 1] = id end end
        end
        if #hit > 0 then
            table.sort(hit)
            out("  替身撤掉的里有对方 wge= 同步来的：%s（等对方新的 wge= 不带它了再按对方的补）", table.concat(hit, " "))
        end
    end
    if done ~= nil and not phase then      -- §173.11 每次开打一行（只读，不改行为）：按规则没撤的 + 留着的有时限效果和剩余时间，查漏撤的药 / 误撤
        local function joinOr(t) return #t > 0 and table.concat(t, ",") or "-" end
        out("开打留着的效果（%s）：按规则没撤 天赋 %s；饰品 %s；武器 %s；有时限的 %s；时长读不到的 %s", who, joinOr(ruled.tal),
            joinOr(ruled.acc), joinOr(ruled.wpn), joinOr(timedLeft), joinOr(unk))
        RT.otherLogs = (RT.otherLogs or 0) + 1
        if RT.otherLogs <= 8 then     -- §208 其他没时限的（不是天赋 / 饰品 / 武器开头），前 8 次记全名，查有没有该撤的临时效果漏掉
            out("  开打留着的其他无时限效果（%s）：%s", who, joinOr(other))
        end
    end
end

-- 进倒计时：挂无敌（自己 + 替身），看标签确认；自己挂不上 → RT.shield = false（syncFaction 让替身倒计时里是友方）
function RT.cdStart(p1)
    local pup = puppet()
    RT.shield = LO.applyGE(p1, RT.INV_GE, "倒计时无敌（自己）")
    if valid(pup) then LO.applyGE(pup, RT.INV_GE, "倒计时无敌（替身）") end
    local hit = G.tagsMatching(p1, { RT.INV_TAG })
    RT.shield = RT.shield and hit ~= nil and #hit > 0
    if not RT.shield then out("!! 倒计时无敌没挂上（没有 %s），倒计时里让替身当友方（不互砍）", RT.INV_TAG) end
end

-- 撤无敌（交手开始 / 回自由活动）
function RT.unshield(p1)
    if RT.shield == nil then return end
    RT.shield = nil
    LO.removeGE(p1, RT.INV_GE, "撤掉倒计时无敌（自己）")
    local left = G.tagsMatching(p1, { RT.INV_TAG })      -- 撤不掉 = 交手 / 自由活动里一直无敌，日志要显眼
    if left and #left > 0 then
        LO.removeGE(p1, RT.INV_GE, "再撤一次倒计时无敌（自己）")
        left = G.tagsMatching(p1, { RT.INV_TAG })
        if left and #left > 0 then out("!! 倒计时无敌撤不掉（还有 %s）：这一局你打不掉血，请反馈", RT.INV_TAG) end
    end
    local pup = puppet()
    if valid(pup) then LO.removeGE(pup, RT.INV_GE, "撤掉倒计时无敌（替身）") end
end

-- 交手开始：撤无敌、清状态（回满由调用方在标准数值 / 开局资源之后做，再调 RT.begin 记起点）
function RT.fightStart(p1)
    CDL.onFight(p1, now())                          -- §173.12 先清读秒里按下 / 缓冲住的键
    RT.unshield(p1)
    RT.cleanse(p1, "自己", true)
    NET.wgeStr = nil                                -- §208 武器增益撤了：下一包重算 wge=，别让对方按读秒前的旧列表给替身补回去
    local pup = puppet()
    if valid(pup) then RT.cleanse(pup, "替身", false); INF.pup = {} end
    RT.stopBullets(p1, pup, "交手开始")
    -- §376 开打时切武器冷却归零（用户 11-17："武器切换冷却在进入战斗的瞬间没有恢复到可使用状态"）：
    -- 读秒里 / 上一回合切过武器留下的冷却会带进交手，开打第一下切不了。和 §245 替身放切刀斩前同一个调用。
    if LO.swtCooldown then
        local okW = LO.swtCooldown(p1)
        out("§376 开打清切武器冷却（自己）：%s", okW and "已清" or "!! 调用失败")
    end
end

-- §362 对局结束也清（用户 11-16："玩家身上的各种 buff 和 debuff 在结束一局战斗时清理掉，比如妖气侵蚀"）：
-- 以前只在开打时清，打完带着对方挂的妖气 / 中毒 / 点燃和喝药、武技增益回自由活动。规则和开打一样（RT.cleanse），
-- 在 NET.rulesEnd 开头调（1v1 回自由活动、对决选手离场、多人对局结束都走它），先于饰品 / 标准数值还原（keep 还认得它们挂的），之后照常回满。
function RT.endCleanse(p1, why)
    local phase = "对局结束（" .. tostring(why or "-") .. "）"
    if valid(p1) then RT.cleanse(p1, "自己", true, phase) end
    NET.wgeStr = nil
    local pup = puppet()
    if valid(pup) then RT.cleanse(pup, "替身", false, phase); INF.pup = {} end    RT.stopBullets(p1, pup, phase)
end

-- 留场的召唤子弹（邪扇冰晶、红妆鬼斩石蒜花 BP_Hun_GuiTouBlade_Flower_* 等）：自己的和替身的都收掉；
-- 召唤出来的角色（绝影分身、剑客召集令的 NPC）不动（删角色有崩溃前科，v0.11.0）。
-- §362.1 开打也收一次（用户 11-16："开完大招迅速投降重开一把，石蒜花没有立即刷新掉"）
-- §362.2 按角色类收：自己 + 所有替身（多人房每人一个）放的一次扫完；p1 拿不到时退回只收替身的
function RT.stopBullets(p1, pup, phase)
    if not G.stopBullets then return end
    local who, a = "自己和替身", p1
    if not valid(a) then who, a = "替身", pup end
    if not valid(a) then return end
    local okS, n, info = pcall(G.stopBullets, a, true)
    if not okS then out("!! %s收留场子弹（%s）失败：%s", phase, who, tostring(n))
    elseif n > 0 then out("%s收掉留场子弹（%s）%d 个：%s", phase, who, n, info) end
end

-- §261 交手中给自己挂"战斗中"（玩家反馈 11-12："用白山的双刀好像维持不了他的元素状态"）。
-- 根因：战斗状态 CharacterState.InCombat 是游戏的仇恨系统给的（敌人盯上你才有），替身不是 AI 敌人，
-- 跟替身打的时候玩家自己从来不是 InCombat（v0.9.17 记过）。白山风雷剑的蓄势状态 GE_BaiShanFengLeiJian_ChargeState
-- 带 CombatListener → 没有 InCombat 就转 Lingering → RemoveState 把状态撤掉（资产名字表），所以风剑 / 雷剑攒不住。
-- 同样要 InCombat 的玩家侧效果（名字表带 TargetTagRequirements + CharacterState.InCombat）还有：炽刃 GE_ChiRen_FireState、
-- 混沌 GE_Chaos_FireBuff / FrostBuff、双刃 / 长形 / 黑伤武技增益、乱莺 Buff / Buff_P2、天煞双钺 ChargeState、残钢 ChargeBuff、
-- 三个召唤影武的 DelayDestory、GE_InflictionDecrementOffCombat（异常积累脱战衰减）。
-- 做法同 §239 替身：交手开始挂 GE_InBossFight（只给 CharacterState.InCombat.Boss，父标签匹配 InCombat），
-- 回合结束 / 对局结束 / 回自由活动撤掉——回合之间照旧脱战，和 PvE 打完一波一样；只撤我们自己挂的（本来就在战斗里的不动）。
-- 关掉：net/p1_combat_off.txt
PCB = { OFF = (NET_DIR or "net") .. "/p1_combat_off.txt", TAG = "CharacterState.InCombat", mine = false }
function PCB.on(p1, why)
    if PCB.mine or not valid(p1) then return end
    local f = io.open(PCB.OFF, "r")
    if f then f:close(); out("§261 有 net/p1_combat_off.txt：交手中不给自己挂战斗状态（%s）", why); return end
    local had = G.tagsMatching(p1, { PCB.TAG })
    if had and #had > 0 then out("§261 自己本来就在战斗状态，不挂（%s）", why); return end
    local ok = LO.applyGE(p1, LO.GE_COMBAT, "§261 自己进入战斗状态（" .. why .. "）")
    local now_ = G.tagsMatching(p1, { PCB.TAG })
    PCB.mine = ok and true or false
    if not (now_ and #now_ > 0) then
        out("!! §261 自己的战斗状态没挂上：白山风雷剑风剑 / 雷剑、炽刃火焰等要战斗状态的增益会被游戏撤掉")
    end
end
function PCB.off(p1, why)
    if not PCB.mine then return end
    PCB.mine = false
    if valid(p1) then LO.removeGE(p1, LO.GE_COMBAT, "§261 自己撤掉战斗状态（" .. why .. "）") end
end

-- §173.9 倒计时规则行折行（RT.RULE_W / dispW / wrapRules）、RT.begin / track / wire / onPacket / check：→ fornet_match.lua（F4a，上面 rtInstall 装上）

-- §119 紫冥剑召唤实验（2026-11-06，§118.4）。枪 / 锤 / 伞不在动作里，是 GA_Hun_ZiMingJian_New_DB 按住时再按攻击键
-- 自己做的（TrySummonHuoQiang / TrySummonJinGua / TrySummonTieSan → 时间线段 Summon_* + 子弹 B_ZiMingJian_DBB_*）。
-- 替身没人按住，起手 0.6 秒技能就收了，对方的 sub= 到的时候已经没有技能可调。实验两步：
--   ① 替身放出 DB 后 PAUSE_AT 秒把起手动作停住，看技能是不是跟着挂住（日志"技能还在"）
--   ② 收到对方的召唤动作（sub= 的 Gun / JinGua / TieChi）时对替身的 DB 实例调对应的 TrySummon*（调成了就不再照播动作）
-- 第一轮实测（17:45–17:47，回放用户录的 6 次召唤）：起手停得住、技能多挂 1.4–2.2 秒，TrySummon* 6 次都调用成功、不崩，
-- 但替身动作没换成召唤、用户看不到召唤物也没掉血。第二轮：实验期间对方的 Loop 不再照播（会顶掉技能自己的动作），
-- 调 TrySummon* 时起手还停着（不先继续），调之前 / 0.3 秒后把技能实例里 BuJu / Summon / Loop 等变量记进日志
-- 第二轮实测（17:53）：停住动作拦不住技能（技能按自己的时间线 0.1 秒后照样切 End，看着更短）；技能变量里
-- HasSummoned_HuoQiang / JinGua / TieSan 一开始就是 true（替身没进布局，没被清掉）→ TrySummon* 当成"召过了"。
-- 第三轮：不停起手、Loop 照播；调 TrySummon* 之前把对应的 HasSummoned_* 写成 false
-- 第三轮实测（18:03–18:05）：三件都召出来了、伞打中 -404；枪 / 锤没对着你（回放的录制里 lk=0、替身朝向是录制里的）。
-- 瞄准：对方锁定你（lk=1）时替身出招后 ATK_HOLD 秒内每帧对准你（v0.23.3），但这个计时从放 DB 算起，布局里停一会儿再召唤
-- 就过了（18:07 实测"有一些瞄不准"）→ 每次召唤都重新开始计（ST.pupAtkAt = 召唤那一刻）
-- 18:1x 实测：锤 / 伞没问题，火枪从你头顶平飞过去（截图：三把枪浮在替身头顶上方）。猜：火枪按控制器视角的俯仰瞄，
-- 替身的控制器俯仰一直是 0。召唤后对方锁定你时，俯仰改成从枪的高度指向你（没用，已删，见下）
-- 18:2x 实测：俯仰算出来了（-23.5°）还是平射 → 火枪不按视角瞄。资产：枪 BP_ZiMingJian_FlyingGun 的子弹
-- B_ZiMingJian_FlyingGun_Bullet 用 BP_BulletTargetSelector_LockTarget（打锁定目标）。替身锁定目标早就是你，
-- 怀疑打的是你身上的锁定点 LockViewTarget（替身的那个以前一直在原点，§19 fixPuppetLockPoint）。
-- 召唤火枪时记下你的锁定点在哪，并在对方召唤火枪后 3 秒内每帧把它放到你胸口（P1_LOCK_Z）
-- 18:3x 实测：你的锁定点原来真在 (0,0,0)，放到胸口了还是平射。子弹选目标的 BP_BulletTargetSelector_LockTarget 走的是
-- GetTargetingComponent → HasLockTarget / RequestLockTarget：替身的瞄准组件（Targeting Component）里从来没有锁定目标，
-- 只写了角色的 LockTargetActor 属性不够（用户截图：自己放的火枪斜着指向对方胸口的锁定光点）。
-- 召唤时（对方锁定你）对替身的瞄准组件调 SetLockTarget(你)；第一次把组件上带 Lock 的函数 / 属性记进日志
-- 18:41 实测：SetLockTarget 传角色本身类型不对（参数不是 Actor）。改成记下参数类型，把你身上可能的目标对象
-- （LockViewTarget、名字带 Target / Lock 的组件）挨个试，HasLockTarget 变 true 就记住用哪个
-- 18:53 实测：参数 Target 是结构体（StructProperty），传对象都不行。改成按结构体的字段拼一张表：对象字段里类名 / 字段名
-- 像组件的填你的 LockViewTarget、其余对象字段填你；位置字段填你胸口。另外读你自己的瞄准组件 LockTarget（你锁着替身时
-- 能看到游戏自己是怎么填这个结构体的）
-- 19:18 实测通过：结构体是 ComponentSocket{Component, SocketName}；填 Component = 你的 LockViewTarget（召唤火枪后 3 秒放在
-- 你胸口）→ HasLockTarget=true，火枪瞄着你打（连中 7 下各 -67）。游戏自己的填法（你锁替身时读到）是 Component = 对方的
-- CharacterMesh0 + 某个挂点名。之前试过的"控制器俯仰"不起作用，已删
-- 第一次放时把实例上带 Summon 的函数和参数记进日志。net/zmx_off.txt 存在 = 整个不做（出问题时不用重新部署）
ZMX = { CLS = "GA_Hun_ZiMingJian_New_DB_C", PAUSE_AT = 0.4, HOLD_MAX = 4.0, LOGS = 150, logs = 0,
        FN = { Gun = "TrySummonHuoQiang", JinGua = "TrySummonJinGua", TieChi = "TrySummonTieSan" },
        FLAG = { Gun = "HasSummoned_HuoQiang", JinGua = "HasSummoned_JinGua", TieChi = "HasSummoned_TieSan" },
        NO_PAUSE = true, SKIP_LOOP = false, P1_LOCK_Z = 40.0, p1LockUntil = 0, lockLogs = 0, tcUnlockAt = nil,
        STATE = { "BuJu", "Summon", "Loop", "Can", "Hold", "Timing", "Enhanced", "HuoQiang", "JinGua", "TieSan", "Rate" } }
ZMX.OFF_FILE = NET_DIR .. "/zmx_off.txt"

function ZMX.log(...)
    if ZMX.logs < ZMX.LOGS then ZMX.logs = ZMX.logs + 1; out(...) end
end

function ZMX.off()
    local f = io.open(ZMX.OFF_FILE, "r")
    if f then f:close(); return true end
    return false
end

function ZMX.onFire(pup, e, tn)
    FJ.onFire(pup, e, tn)                -- §179 收尾招射飞剑
    if e.name ~= ZMX.CLS then return end
    if ZMX.off() then ZMX.log("紫冥剑实验：有 net/zmx_off.txt，不做"); return end
    ZMX.cur = { id = e.id, at = tn, paused = false, nextLog = 0 }
    if not ZMX.probed then
        ZMX.probed = true
        local inst = LO.activeInstance(pup, ZMX.CLS)
        out("紫冥剑实验：替身 DB 实例 %s；带 Summon 的函数：%s", inst and "有" or "没有",
            inst and table.concat(LO.funcsLike(inst, "Summon"), " ") or "-")
    end
end

function ZMX.finish(pup, why, tn)
    local c = ZMX.cur
    if c.paused then G.montagePause(pup, false) end
    ZMX.log("紫冥剑实验：远端#%d 结束（%s，%.2f 秒，停过起手=%s）", c.id, why, tn - c.at, tostring(c.paused))
    ZMX.cur = nil
end

-- 你身上的锁定点（别人锁你时镜头 / 子弹对着的点）的位置；fix = true 时放到你胸口
function ZMX.p1Lock(fix, why)
    local p1 = PEER.tgt()
    local comp = valid(p1) and rawProp(p1, "LockViewTarget")
    if not valid(comp) then
        if ZMX.lockLogs < 3 then ZMX.lockLogs = ZMX.lockLogs + 1; ZMX.log("  紫冥剑实验：你身上没有 LockViewTarget（%s）", why) end
        return
    end
    local l = try("p1 loc", function() return p1:K2_GetActorLocation() end)
    if not l then return end
    if ZMX.lockLogs < 6 then
        ZMX.lockLogs = ZMX.lockLogs + 1
        local a = try("p1 lock", function() return comp:K2_GetComponentLocation() end)
        ZMX.log("  紫冥剑实验：你的锁定点（%s）在 %s，你在 (%.0f, %.0f, %.0f)", why,
            a and string.format("(%.0f, %.0f, %.0f)，比你高 %.0f", a.X, a.Y, a.Z, a.Z - l.Z) or "?", l.X, l.Y, l.Z)
    end
    if fix then
        pcall(function() comp:K2_SetWorldLocation({ X = l.X, Y = l.Y, Z = l.Z + ZMX.P1_LOCK_Z }, false, {}, true) end)
    end
end

-- 布局中被打的自动闪避（ZuoShang_Dodge_*）：真人那边有一道金光，是 DB 技能自己放的 Niagara（闪避动作里没有通知），
-- 替身的技能早收了 → 模组自己在替身身上放。DB 技能名字表里有 NS_ZuoShangLongTi_TP / _Trail、NS_ZuoShang_CA01_PullOut_002，
-- 具体哪个是金光看不出（TP 有 _201 / _202 两个）。先轮流放 FX 里的候选（每次闪避换下一个，日志写"第 N 个"），用户认出来后固定
-- 19:34 实测：TP_201 / TP_202 / Trail_201 / PullOut_002 四个都放成功了，但都不是（用户：真人身上是条带特效）；
-- 19:4x 换主角完美闪避 BattleFX/Hun/NS_PerfectDodge_001 也不是（用户："更像描边"）。用户定：先用 TP_201，以后有空再查。
-- 以后查：你自己拿紫冥剑在布局里被打出闪避时，ZMX.fxProbe 把你身上挂的特效（Niagara + 叠加材质）记进日志（只记前 3 次）
ZMX.FX = { "/PBZVFXPack/VFX/BattleFX/ZuoShang_LongTi/NS_ZuoShangLongTi_TP_201.NS_ZuoShangLongTi_TP_201" }
ZMX.fxp, ZMX.fxpN = nil, 0

-- 我在布局里被打出闪避（ZuoShang_Dodge_*）：当下 / 0.2 / 0.5 秒扫一遍我身上的特效
function ZMX.fxProbe(p1, hm, tn)
    if hm and hm:find("ZuoShang_Dodge", 1, true) and ZMX.fxpN < 3 then
        ZMX.fxpN = ZMX.fxpN + 1
        ZMX.fxp = { at = tn, left = { 0.0, 0.2, 0.5 } }
    end
    local p = ZMX.fxp
    if not (p and #p.left > 0 and tn - p.at >= p.left[1]) then return end
    table.remove(p.left, 1)
    local list, ov = LO.fxOn(p1)
    out("紫冥剑：我布局闪避 %.1f 秒，身上特效 %s；叠加材质 %s", tn - p.at, #list > 0 and table.concat(list, " ") or "（无）", ov)
end
ZMX.fxN = 0

function ZMX.dodgeFx(pup, m)
    if not valid(pup) or ZMX.off() then return end
    ZMX.fxN = ZMX.fxN + 1
    local i = (ZMX.fxN - 1) % #ZMX.FX + 1
    local path = ZMX.FX[i]
    local ok, how = LO.spawnFx(pup, path)
    out("紫冥剑实验：对方布局闪避 %s → 替身第 %d 次闪避，放候选特效 %d 号 %s：%s", m, ZMX.fxN, i,
        path:match("([%w_]+)$"), ok and ("成功（" .. how .. "）") or ("失败 " .. tostring(how)))
end

-- 按 SetLockTarget 的参数结构体拼"锁定你"的表
function ZMX.lockStruct(tc)
    local pl = LO.paramList(tc, "SetLockTarget")
    local st = pl and pl[1] and pl[1].fields
    if not st then return nil, "参数不是结构体 / 读不到字段" end
    local p1 = PEER.tgt()
    local comp = rawProp(p1, "LockViewTarget")
    local l = try("p1 loc", function() return p1:K2_GetActorLocation() end)
    local t, used = {}, {}
    for _, f in ipairs(st) do
        local isObj = f.t:find("ObjectProperty", 1, true) ~= nil
        local nc = (f.n .. " " .. (f.cls or "")):lower()
        if isObj and (nc:find("component") or nc:find("point")) and valid(comp) then t[f.n] = comp; used[#used + 1] = f.n .. "=你的锁定点"
        elseif isObj then t[f.n] = p1; used[#used + 1] = f.n .. "=你"
        elseif f.t == "StructProperty" and f.cls == "Vector" and l then t[f.n] = { X = l.X, Y = l.Y, Z = l.Z + ZMX.P1_LOCK_Z }; used[#used + 1] = f.n .. "=你胸口" end
    end
    return t, table.concat(used, " ")
end

-- 你自己的瞄准组件现在的 LockTarget 结构体（你锁着替身时看游戏怎么填）
function ZMX.p1LockInfo()
    local tc = LO.targetingComp(PEER.tgt())
    local v = tc and rawProp(tc, "LockTarget")
    local pl = tc and LO.paramList(tc, "SetLockTarget")
    local st = pl and pl[1] and pl[1].fields
    if not (v and st) then return "读不到" end
    local parts = {}
    for _, f in ipairs(st) do
        local fv = rawProp(v, f.n)
        local s = type(fv) == "userdata" and (valid(fv) and short(pathOf(fv)) or "空/结构体") or tostring(fv)
        parts[#parts + 1] = f.n .. "=" .. s
    end
    return table.concat(parts, " ")
end

-- 给替身瞄准组件锁定你
function ZMX.tcLock(tc)
    local t, used = ZMX.lockStruct(tc)
    if not t then ZMX.log("  紫冥剑实验：替身瞄准组件锁你：%s", used); return end
    local ok, err, has = LO.tcSetLock(tc, t)
    ZMX.log("  紫冥剑实验：替身瞄准组件 SetLockTarget({%s}) %s，HasLockTarget=%s；你自己的 LockTarget：%s", used,
        ok and "调用成功" or ("失败 " .. tostring(err):sub(-80)), tostring(has), ZMX.p1LockInfo())
end

-- §189 替身放 Snap 前：瞄准组件锁你（Snap 的 K2_CanActivateAbility 要有锁定目标）。对方没锁你就 1.5 秒后撤掉（同火枪，ZMX.step 里撤），
-- 免得替身后面的招都追着你。返回 HasLockTarget
-- §223.7 / §239 混沌形态：形态名 → 武器效果 id（同 wge= 里的写法，LO.wgePath 转成类路径）
LO.CHAOS_FORM = { Fire = "ChaosBlade/GE_Chaos_FireBuff", Ice = "ChaosBlade/GE_Chaos_FrostBuff", Physics = "ChaosBlade/GE_Chaos_PhysicsBuff" }
-- §242 火 / 冰蓄力重击（B_Hold_*）的激活标签：资产名字表（11-11 离线）里
--   GA_Hun_Chaos_B_Hold_Fire   要 CharacterState.WeaponUpgrade.ChaosBlade.FireHold  ← GE_Weapon_ChaosBlade_Lv25
--   GA_Hun_Chaos_B_Hold_Ice    要 CharacterState.WeaponUpgrade.ChaosBlade.IceHold   ← GE_Weapon_ChaosBlade_Lv15
--   GA_Hun_Chaos_B_Hold_Physics 要 CharacterState.WeaponUpgrade.ChaosBlade.PhysicHold ← GE_Weapon_ChaosBlade_Lv5
-- 以前只在放不出之后才补升级（CHG.UPG），而且 CHG.upgrade 对已经补过的返回 false → 不再 fire；B_Ice / BB_Ice / BBB_Ice
-- 的整个 B 链在替身上一次都没放出来。换形态时就把对应升级挂上（和形态同进退），放招前先就绪形态，就不靠"失败再补"。
LO.CHAOS_UPG = {
    Fire = "ChaosBlade/UpgradeData/GE_Weapon_ChaosBlade_Lv25",
    Ice = "ChaosBlade/UpgradeData/GE_Weapon_ChaosBlade_Lv15",
    Physics = "ChaosBlade/UpgradeData/GE_Weapon_ChaosBlade_Lv5",
}
LO.CHAOS_EFFECT = { Fire = "ChaosBlade/GE_Chaos_FireEffect", Ice = "ChaosBlade/GE_Chaos_FrostEffect" }
LO.CHAOS_MONT = {
    Fire = "Hun_YuCongBlade_Skill_05_Montage",
    Ice = "Hun_YuCongBlade_Skill_04_Montage",
    Physics = "Hun_YuCongBlade_Skill_06_Montage"
}
LO.CHAOS_MONT_PATH = {
    Fire = "/PBZCombatAsset/ActorData/Players/Hun/Montage/ChaosBlade/Hun_YuCongBlade_Skill_05_Montage.Hun_YuCongBlade_Skill_05_Montage",
    Ice = "/PBZCombatAsset/ActorData/Players/Hun/Montage/ChaosBlade/Hun_YuCongBlade_Skill_04_Montage.Hun_YuCongBlade_Skill_04_Montage",
    Physics = "/PBZCombatAsset/ActorData/Players/Hun/Montage/ChaosBlade/Hun_YuCongBlade_Skill_06_Montage.Hun_YuCongBlade_Skill_06_Montage"
}
LO.CHAOS_OFF = (NET_DIR or "net") .. "/chaos_form_off.txt"
function LO.chaosOff()
    local f = io.open(LO.CHAOS_OFF, "r")
    if f then f:close(); return true end
    return false
end
LO.MOVES_OFF = (NET_DIR or "net") .. "/puppet_moves_off.txt"
function LO.movesOff()
    local f = io.open(LO.MOVES_OFF, "r")
    if f then f:close(); return true end
    return false
end

-- §248 混沌火形态条件探针（只读，前 3 次）：11-11 22:5x / §246.3 实测 GE_Chaos_FireBuff 的
-- BP_ApplyGameplayEffectToSelf 返回"成功"、0.35 秒后 geCounts 0 份、Fire 标签不在 → 火 B 链放不出。
-- 名字表分不出授予 / 要求（gasgraph README §8.2），所以第一次给替身挂 Fire 形态时读 GE / 切形态技能 CDO 上真正的
-- ApplicationTagRequirements / OngoingTagRequirements / RemovalTagRequirements / GrantedApplicationImmunityTags，
-- 以及 ActivationRequiredTags / BlockedTags / Source·Target RequiredTags，再记替身当时身上的相关标签。
-- 只读，不改行为；关键字 `§248 混沌火形态条件`。
CHP = { n = 0, MAX = 3 }
CHP.TAGS = { "CharacterState.AbilityState.ChaosBlade.Fire", "CharacterState.AbilityState.ChaosBlade.Ice",
             "CharacterState.AbilityState.ChaosBlade.Normal", "CharacterState.AbilityState.ChaosBlade.Physics",
             "CharacterState.AbilityState.ChaosBlade.Switch", "CharacterState.InCombat", "CharacterState.InCombat.Boss",
             "CharacterState.WeaponUpgrade.ChaosBlade.Lv5", "CharacterState.WeaponUpgrade.ChaosBlade.Lv15",
             "CharacterState.WeaponUpgrade.ChaosBlade.Lv25", "CharacterState.WeaponUpgrade.ChaosBlade.ZhuHun",
             "CharacterState.WeaponUpgrade.ChaosBlade.FireHold", "CharacterState.WeaponUpgrade.ChaosBlade.IceHold",
             "CharacterState.WeaponUpgrade.ChaosBlade.PhysicHold", "CharacterState.WeaponUpgrade.ChaosBlade.ShaQiReplay" }
CHP.GE_FIELDS = { "ApplicationTagRequirements", "OngoingTagRequirements", "RemovalTagRequirements", "GrantedApplicationImmunityTags" }
CHP.GA_FIELDS = { "ActivationRequiredTags", "ActivationBlockedTags", "SourceRequiredTags", "TargetRequiredTags",
                  "SourceBlockedTags", "TargetBlockedTags" }
CHP.GA_PATH = "/PBZCombatAsset/ActorData/Players/Hun/Abilities/ChaosBlade/GA_Hun_Chaos_SwitchFormFire.GA_Hun_Chaos_SwitchFormFire_C"
function CHP.once(pup, form)
    if form ~= "Fire" or CHP.n >= CHP.MAX then return end
    CHP.n = CHP.n + 1
    local tags = "读不到"
    if G.tagsMatching then
        local ok, t = pcall(G.tagsMatching, pup, CHP.TAGS)
        if ok then tags = t and (#t > 0 and table.concat(t, ",") or "（全都没有）") or "读不到" end
    end
    local cnt = "读不到"
    if G.geCounts then
        local ok, c = pcall(G.geCounts, pup)
        if ok and type(c) == "table" then
            local b, e = (LO.CHAOS_FORM.Fire or ""):match("([%w_]+)$"), (LO.CHAOS_EFFECT.Fire or ""):match("([%w_]+)$")
            cnt = string.format("%s %s 份 / %s %s 份", b or "?", tostring(c[b] or 0), e or "?", tostring(c[e] or 0))
        end
    end
    out("§248 混沌火形态条件 #%d/%d：替身标签 %s；GE %s", CHP.n, CHP.MAX, tags, cnt)
    if not G.cdoTags then out("§248 混沌火形态条件：没有 G.cdoTags（适配层旧）"); return end
    for _, spec in ipairs({ { "GE_Chaos_FireBuff", LO.wgePath(LO.CHAOS_FORM.Fire), CHP.GE_FIELDS },
                            { "GE_Chaos_FireEffect", LO.CHAOS_EFFECT.Fire and LO.wgePath(LO.CHAOS_EFFECT.Fire), CHP.GE_FIELDS },
                            { "GA_Hun_Chaos_SwitchFormFire", CHP.GA_PATH, CHP.GA_FIELDS } }) do
        if spec[2] then
            local ok, s = pcall(G.cdoTags, spec[2], spec[3])
            out("§248 混沌火形态条件：%s CDO %s", spec[1], ok and s or ("读不到 " .. tostring(s)))
        end
    end
end

-- §245 形态切换：游戏自己要求"从上一个形态切过来"（GA_Hun_Chaos_SwitchFormFire 要 Ice、SwitchFormIce 要 Normal、
-- SwitchFormPhysic 要 Fire；名字表里每个切形态招都带着上一个形态的标签）。§242 是先撤旧形态再挂目标形态，
-- 19:22 复测时 GE_Chaos_FireBuff 每次 BP_ApplyGameplayEffectToSelf 都"成功"、0.35 秒后 geCounts 0 份、Fire 标签不在，
-- 补 3 次都一样 → 火 B 链（Chaos_B_Fire / BB / BBB）和 SwitchFormFire 整组放不出（§239 时火 B 链有伤害）。
-- 现在：
--   1) 先看目标形态的标签是不是真的还在（LO.wgeOn 说"上过"但标签不在 = 被游戏撤掉了，清掉重挂，别被记录挡住）；
--   2) 先挂目标形态（这时上一个形态的标签还在，游戏的 GE 门槛才过），再撤别的形态；
--   3) 目标形态挂完标签还不在 → 按切形态招的顺序先补前置形态（Fire←Ice、Ice←Physics、Physics←Fire）再挂一次。
-- 返回 true = 目标形态的 GE 调用成功（或本来就在）。
LO.CHAOS_PRE = { Fire = "Ice", Ice = "Physics", Physics = "Fire" }

-- 目标形态的标签在不在：true / false；读不到（离线测试桩没有 tagsMatching）返回 nil
-- §345 物理形态的标签叫 ChaosBlade.Normal（GE_Chaos_PhysicsBuff 的 OngoingTagRequirements、CHR.tag 都是 Normal），
--   以前拼成 ChaosBlade.Physics（不存在）→ 永远"没挂上"，每次同步都先补 Fire 再换 Physics（11-16 日志每秒刷）
function LO.chaosLive(pup, form)
    if not (G.tagsMatching and form) then return nil end
    local ok, t = pcall(G.tagsMatching, pup, { "CharacterState.AbilityState.ChaosBlade." .. (form == "Physics" and "Normal" or form) })
    if not ok or not t then return nil end
    return #t > 0
end

-- 挂一个形态（升级 + Buff + 特效）；返回 Buff 的 applyGE 成没成功
function LO.chaosApply(pup, form, pp)
    local id, eff, up = LO.CHAOS_FORM[form], LO.CHAOS_EFFECT[form], LO.CHAOS_UPG[form]
    if up then
        if LO.applyGE(pup, LO.wgePath(up), "替身混沌形态升级 " .. form) then
            LO.wgeOn[up], CHG.applied[pp .. "|" .. LO.wgePath(up)] = true, true
        end
    end
    local ok = LO.applyGE(pup, LO.wgePath(id), "替身换混沌形态 " .. form)
    if ok then
        LO.wgeOn[id], CHG.applied[pp .. "|" .. LO.wgePath(id)] = true, true
    end
    if eff and not LO.chaosOff() then
        if LO.applyGE(pup, LO.wgePath(eff), "替身混沌特效 " .. form) then
            LO.wgeOn[eff], CHG.applied[pp .. "|" .. LO.wgePath(eff)] = true, true
        end
    end
    return ok
end

-- 替身换成 form 形态：挂上那个、撤掉另外两个；LO.wgeOn（syncWge 的记录）跟着改，免得下一次同步又换回去。返回 true = 换了 / 本来就是
-- silent = 不往 CHFX 队列里排（CHFX 自己调的时候用，否则每次校验都把 q.i 重置，永远补满 3 次）
function LO.chaosForm(pup, form, silent)
    local want = LO.CHAOS_FORM[form]
    if not want then return false end
    if not LO.chaosOff() then
        if LO.ensureCombat then pcall(LO.ensureCombat, pup) end
        local cwc = rawProp(pup, "Character Weapons Component")
        if valid(cwc) and LO.slot then pcall(function() cwc:SetArmed(LO.slot(), true) end) end
    end
    local pp = pathOf(pup)
    if LO.wgeFor ~= pp then LO.wgeFor, LO.wgeOn = pp, {} end
    LO.wgeOn = LO.wgeOn or {}
    local function noted(ok)
        if ok and CHFX and not silent then pcall(CHFX.note, pup, form) end
        return ok
    end
    local function removeOthers()
        for f, id in pairs(LO.CHAOS_FORM) do
            if f ~= form then      -- 替身自己放切形态招时游戏挂的不在记录里，一律撤
                LO.removeGE(pup, LO.wgePath(id), "替身撤混沌形态 " .. f)
                LO.wgeOn[id], CHG.applied[pp .. "|" .. LO.wgePath(id)] = nil, nil
            end
        end
        for f, id in pairs(LO.CHAOS_EFFECT) do
            if f ~= form then
                LO.removeGE(pup, LO.wgePath(id), "替身撤混沌特效 " .. f)
                LO.wgeOn[id], CHG.applied[pp .. "|" .. LO.wgePath(id)] = nil, nil
            end
        end
    end
    local live = LO.chaosLive(pup, form)
    if live == true then
        -- 形态在：只确认特效（§242 FrostEffect 的门槛要形态标签）
        if not LO.chaosOff() and LO.CHAOS_EFFECT[form] and not LO.wgeOn[LO.CHAOS_EFFECT[form]] then
            local eff = LO.CHAOS_EFFECT[form]
            if LO.applyGE(pup, LO.wgePath(eff), "替身混沌特效 " .. form) then
                LO.wgeOn[eff], CHG.applied[pp .. "|" .. LO.wgePath(eff)] = true, true
            end
        end
        LO.wgeOn[want] = true
        removeOthers()      -- 两个形态标签同时在场（上一次换失败留下的）也清掉
        return noted(true)
    end
    if live == nil and LO.wgeOn[want] then
        -- 读不到标签（老版本 / 测试桩）：沿用旧行为，只信 wgeOn
        return noted(true)
    end
    if live == false then
        -- 记录说上过但标签不在：清掉，让下面重新挂（19:22 Fire 就是被这条挡住：每次 chaosForm 都早退）
        LO.wgeOn[want], CHG.applied[pp .. "|" .. LO.wgePath(want)] = nil, nil
        local upid = LO.CHAOS_UPG[form]
        if upid then LO.wgeOn[upid], CHG.applied[pp .. "|" .. LO.wgePath(upid)] = nil, nil end
    end
    -- 先挂目标形态，再撤别的：撤旧形态放到最后，别让目标形态的 GE 门槛看不到上一个形态
    if form == "Fire" and CHP then CHP.once(pup, form) end
    local ok = LO.chaosApply(pup, form, pp)
    live = LO.chaosLive(pup, form)
    if live == false then
        local pre = LO.CHAOS_PRE[form]
        if pre then
            out("  §245 混沌形态 %s 没挂上（标签不在）→ 先补前置 %s 再换 %s", form, pre, form)
            LO.chaosApply(pup, pre, pp)
            ok = LO.chaosApply(pup, form, pp) or ok
        end
    end
    removeOthers()
    return noted(ok)
end

-- §255 刺骨混沌形态改走游戏自己的切形态招（11-12 第五、六轮复测 §248 探针）：
--   GE_Chaos_FireBuff 的 OngoingTagRequirements 要 CharacterState.AbilityState.ChaosBlade.Fire、RemovalTagRequirements 是
--   "没有 Fire 就撤" → 模组直接挂 GE 时 Fire 标签还没有，挂上立刻被撤（"成功"但 0 份），火 B 链 0/3。
--   Fire 标签是切形态招自己给的；GA_Hun_Chaos_SwitchFormFire 的 ActivationRequiredTags = .Ice、SwitchFormIce 要 .Normal（物理形态）、
--   SwitchFormPhysic 要 .Fire（资产逐招展开 2851–2885 + 探针读 CDO）。替身默认在 .Normal。
-- 现在：这一招要的形态（切形态招 = 它要的前一个形态）不在 → 按 Normal → Ice → Fire → Normal 放下一步的真切形态招，
--   排 PRETRY 等那个形态的标签出现再放原招（每步记 "§255切形态"，最多 3 步）；切不动就退回 §242 挂 GE 的老路。
--   net/chaos_real_off.txt 存在时整个不走（退回老路）。
CHR = { NEXT = { Normal = "Ice", Ice = "Fire", Fire = "Normal" },
        GA = { Ice = "GA_Hun_Chaos_SwitchFormIce_C", Fire = "GA_Hun_Chaos_SwitchFormFire_C", Normal = "GA_Hun_Chaos_SwitchFormPhysic_C" },
        PRE = { Fire = "Ice", Ice = "Normal", Normal = "Fire" },
        MAXSTEP = 3, MAXBUSY = 4, LOGS = 40, logs = 0 }
CHR.OFF = (NET_DIR or "net") .. "/chaos_real_off.txt"
function CHR.off()
    local f = io.open(CHR.OFF, "r")
    if f then f:close(); return true end
    return false
end
function CHR.log(...)
    if CHR.logs < CHR.LOGS then CHR.logs = CHR.logs + 1; out(...) end
end
function CHR.tag(f) return "CharacterState.AbilityState.ChaosBlade." .. f end
-- 替身现在的形态："Fire" / "Ice" / "Normal" / "none"；读不到标签返回 nil。切到一半两个都在时按新的算（Fire > Ice > Normal）
function CHR.cur(pup)
    if not G.tagsMatching then return nil end
    local ok, t = pcall(G.tagsMatching, pup, { CHR.tag("Fire"), CHR.tag("Ice"), CHR.tag("Normal") })
    if not ok or type(t) ~= "table" then return nil end
    local has = {}
    for _, x in ipairs(t) do has[tostring(x):match("(%a+)$") or ""] = true end
    return (has.Fire and "Fire") or (has.Ice and "Ice") or (has.Normal and "Normal") or "none"
end
-- 这一招要替身先在哪个形态：切形态招（不含 _SWT 版）= 它要的前一个形态；形态招 *_Fire_C / *_Ice_C / *_Physics_C = 那个形态
-- §345 切刀斩版（SwitchForm*_SWT，从别的武器切回刺骨时出的那刀）要的是**自己这个形态**（资产 ActivationRequiredTags，11-16 bp_decode：
--   Physic_SWT 要 .Normal、Fire_SWT 要 .Fire、Ice_SWT 要 .Ice），和不带 SWT 的切形态招（要前一个形态）不一样。
--   以前这里不管 SWT → 替身停在上一次的形态（11-16 是 Fire），对方切回来出 Physic_SWT，替身 5/5 放不出、只播画面没伤害
function CHR.need(use)
    local swt = use:match("^GA_Hun_Chaos_SwitchForm(%a+)_SWT_C$")
    if swt then return (swt == "Physic") and "Normal" or swt end
    local sw = use:match("^GA_Hun_Chaos_SwitchForm(%a+)_C$")
    if sw then return CHR.PRE[(sw == "Physic") and "Normal" or sw] end
    local f = use:match("^GA_Hun_Chaos_.+_(Fire)_C$") or use:match("^GA_Hun_Chaos_.+_(Ice)_C$") or use:match("^GA_Hun_Chaos_.+_(Physics)_C$")
    if f == "Physics" then return "Normal" end
    return f
end
function CHR.count(how, key)
    local _, c = tostring(how or ""):gsub(key, "")
    return c
end
-- 返回 true = 已放下一步切形态招并排了 PRETRY（调用方直接返回"等前摇"）；false = 不用切 / 切不动（走老路）
function CHR.lead(pup, use, how, map, fire, n, sub)
    local need = CHR.need(use)
    if not need then return false end
    local cur = CHR.cur(pup)
    if cur == nil or cur == need then return false end
    if cur == "none" then
        CHR.log("  §255 混沌 %s 要 %s 形态，替身身上一个形态标签都没有 → 走老路挂 GE", use, need)
        return false
    end
    local steps = CHR.count(how, "§255切形态步")
    if steps >= CHR.MAXSTEP then
        CHR.log("  §255 混沌 %s：切了 %d 步还没到 %s（现在 %s）→ 走老路挂 GE", use, steps, need, cur)
        return false
    end
    local nxt = CHR.NEXT[cur]
    local ga = nxt and CHR.GA[nxt]
    if not ga or ga == use then return false end
    if not map[ga] then LO.give(pup, ga, map, true) end
    local ok = fire(ga)
    if not ok then
        -- 上一步的切形态动作还没放完时下一步可能被挡：隔 0.2 秒再试（最多 MAXBUSY 次），不算一步
        local busy = CHR.count(how, "§255切形态忙")
        if steps > 0 and busy < CHR.MAXBUSY then
            local q = PRETRY.push(pup, n, sub, (how or "") .. " §255切形态忙", 0.2, "混沌等上一步切形态放完")
            if q then
                CHR.log("  §255 混沌 %s：切 %s 形态的 %s 这会儿放不出（现在 %s，第 %d 次）→ 0.2 秒后再试", use, nxt, ga, cur, busy + 1)
                return true
            end
        end
        CHR.log("  §255 混沌 %s：要 %s 形态，切 %s 的 %s 放不出（现在 %s，替身有这招=%s）→ 走老路挂 GE",
            use, need, nxt, ga, cur, tostring(map[ga] ~= nil))
        return false
    end
    local q = PRETRY.push(pup, n, sub, (how or "") .. " §255切形态步", 0.35, "混沌先切" .. nxt .. "形态",
        { cond = function() return CHR.cur(pup) == nxt end, tries = 12, gap = 0.15 })
    CHR.log("  §255 混沌 %s 要 %s 形态（现在 %s）：先放真切形态招 %s（第 %d 步），等 %s 标签出现再放", use, need, cur, ga, steps + 1, nxt)
    return q and true or false
end

-- §255 替身补拔刀攻击天赋（GE_Talent_EnableDrawAttack → CharacterState.Talent.EnableDrawAttack；冲刺切刀斩要它）。每个替身一次
function LO.drawTalent(pup)
    if not (STD and STD.talentPath) then return false end
    local pp = pathOf(pup)
    if LO.drawTalFor == pp then return true end
    if G.tagsMatching then
        local ok, t = pcall(G.tagsMatching, pup, { "CharacterState.Talent.EnableDrawAttack" })
        if ok and type(t) == "table" and #t > 0 then LO.drawTalFor = pp; return true end
    end
    local ok = LO.applyGE(pup, STD.talentPath("EnableDrawAttack"), "§255 替身补拔刀攻击天赋（冲刺切刀斩要）")
    if ok then LO.drawTalFor = pp end
    return ok
end

-- §348 反过来的两招：切刀斩基类 BP_SwitchAttack_Base 要 CharacterState.Talent.EnableDrawAttack，但破军 SWT_02 / 紫冥剑 SWT
-- 把 Required 清空、改成 ActivationBlockedTags = EnableDrawAttack（资产 CDO，11-16 离线扫全部 GA 只有这两个）——
-- 没点拔刀攻击天赋的人切过去放的是这两招。替身身上有这个天赋（标准数值统一给 / §255 补的 / 生成时带的）就永远放不出
-- （11-16 假对手"§248 出招门槛 GA_Hun_PoJun_SWT_02_C：ActivationBlockedTags=CharacterState.Talent.EnableDrawAttack"）。
-- 对方发来这两招 = 对方没这个天赋 → 放之前先摘掉替身的天赋 GE，放完马上挂回（门槛只在激活那一刻查）
LO.DRAWBLK = { GA_Hun_PoJun_SWT_02_C = true, GA_Hun_ZiMingJian_New_SWT_C = true }
LO.drawDropN = 0
function LO.hasDrawTalent(pup)
    if not G.tagsMatching then return nil end
    local ok, t = pcall(G.tagsMatching, pup, { "CharacterState.Talent.EnableDrawAttack" })
    if not ok or type(t) ~= "table" then return nil end
    return #t > 0
end
-- 返回 true = 摘过（放完要调 LO.drawTalentBack 挂回）
function LO.drawTalentOff(pup, use)
    if not (LO.DRAWBLK[use] and STD and STD.talentPath) then return false end
    if LO.hasDrawTalent(pup) ~= true then return false end
    LO.removeGE(pup, STD.talentPath("EnableDrawAttack"))
    local still = LO.hasDrawTalent(pup)
    LO.drawTalFor = nil
    LO.drawDropN = LO.drawDropN + 1
    if LO.drawDropN <= 10 then
        out("  §348 %s 被拔刀攻击天赋挡着（对方没点这个天赋）：先摘替身的 GE_Talent_EnableDrawAttack%s（第 %d 次）", use,
            still and "——摘完标签还在（不是这个 GE 给的），照样试" or "，放完挂回", LO.drawDropN)
    end
    return true
end
function LO.drawTalentBack(pup)
    if not (STD and STD.talentPath) then return end
    LO.applyGE(pup, STD.talentPath("EnableDrawAttack"))
    LO.drawTalFor = pathOf(pup)
end

-- §242 混沌形态校验：换形态 / 放形态招之后隔 0.35 / 1.2 / 3 秒看一次 Buff、特效、形态标签还在不在，掉了就补。
-- 为什么：GE_Chaos_FrostEffect 自己有 TargetTagRequirements（要 CharacterState.AbilityState.ChaosBlade.Ice），
-- 和 FrostBuff 同一帧挂时 Ice 标签可能还没生效 → 返回"挂上成功"但下一帧被 GE 门槛撤掉，用户看不到冰特效。
-- 只补不撤；net/chaos_form_off.txt 存在时不动。日志前 20 条。
CHFX = { Q = {}, AT = { 0.35, 1.2, 3.0 }, TRIES = 3, LOGS = 20, logs = 0 }
function CHFX.log(...)
    if CHFX.logs < CHFX.LOGS then CHFX.logs = CHFX.logs + 1; out(...) end
end
function CHFX.note(pup, form)
    if not valid(pup) or not form then return end
    for _, q in ipairs(CHFX.Q) do
        if sameObj(q.pup, pup) then q.form, q.i, q.next = form, 1, now() + CHFX.AT[1]; return end
    end
    CHFX.Q[#CHFX.Q + 1] = { pup = pup, form = form, i = 1, next = now() + CHFX.AT[1] }
end
function CHFX.step(tn)
    if #CHFX.Q == 0 then return end
    local keep = {}
    for _, q in ipairs(CHFX.Q) do
        if not valid(q.pup) or LO.chaosOff() then
            -- 替身没了 / 开关关了就丢
        elseif tn < q.next then
            keep[#keep + 1] = q
        else
            local cnt = (G.geCounts and G.geCounts(q.pup)) or {}
            local buff, eff = LO.CHAOS_FORM[q.form], LO.CHAOS_EFFECT[q.form]
            local bn = buff and buff:match("([%w_]+)$")
            local en = eff and eff:match("([%w_]+)$")
            local tags = G.tagsMatching and G.tagsMatching(q.pup, { "CharacterState.AbilityState.ChaosBlade." .. q.form })
            local tagOn = tags and #tags > 0
            local miss = {}
            -- §245 以形态标签为准（WeaponBuff 形态 GE 可能挂在武器 ASC 上，geCounts 看不见，但标签在）；
            -- 标签读不到才退回数份数。标签不在 = 形态真的掉了，走 LO.chaosForm（它会先补前置形态再挂、并清掉 wgeOn 的旧记录）。
            local need = (tags and not tagOn) or ((not tags) and bn and (cnt[bn] or 0) == 0)
            if bn and need then miss[#miss + 1] = bn end
            if en and (cnt[en] or 0) == 0 then miss[#miss + 1] = en end
            local tagTxt = tags and (tagOn and "标签在" or "标签不在") or "标签读不到"
            local upid = LO.CHAOS_UPG and LO.CHAOS_UPG[q.form]
            local un = upid and upid:match("([%w_]+)$")
            if upid and (cnt[un] or 0) == 0 then miss[#miss + 1] = un end
            if #miss > 0 then
                CHFX.log("§242 混沌形态校验 %s：%s %d 份 / %s %d 份 / %s → 补 %s（第 %d 次）", q.form,
                    bn or "-", cnt[bn] or 0, en or "-", cnt[en] or 0, tagTxt, table.concat(miss, "、"), q.i)
                if LO.wgeOn then LO.wgeOn[buff] = nil end
                if LO.chaosForm(q.pup, q.form, true) then
                    LO.wgeOn = LO.wgeOn or {}
                    LO.wgeOn[buff] = true
                end
            elseif q.i == 1 then
                CHFX.log("§242 混沌形态校验 %s：%s 1 份 / %s 1 份 / %s（都在）", q.form, bn or "-", en or "-", tagTxt)
            end
            if #miss == 0 or q.i >= CHFX.TRIES then
                if #miss > 0 then CHFX.log("!! §242 混沌形态校验 %s：补了 %d 次还是缺 %s（形态效果被游戏撤掉？）", q.form, q.i, table.concat(miss, "、")) end
            else
                q.i = q.i + 1
                q.next = tn + (CHFX.AT[q.i] or 3.0)
                keep[#keep + 1] = q
            end
        end
    end
    CHFX.Q = keep
end

-- §249 状态对比（只读，报告 §3.1 / §3.2 的下一步）：每场第 1 回合开打后 3 秒，比较我和替身身上
-- CharacterState.AbilityState.* / CharacterState.WeaponUpgrade.* 的标签，只列"我有、替身没有"的，前 3 次。
-- 不改同步逻辑；目的：先看 wge= 丢掉的到底是哪些标签，再决定要不要做 wtag=。
-- GetOwnedGameplayTags 实测拿不到（§14），所以用 G.geTags 从生效 GE 的 GrantedTags 里取；loose tag 看不到。
-- 事件触发：只在 enter("fight") 第 1 回合排一次（TAGD.schedule），到点由主循环调 TAGD.step，没有周期轮询。
TAGD = { MAX = 3, WAIT = 3.0, LOGS = 3, n = 0, due = nil, at = nil, id = nil, MAX_LOG = 40,
         ROOTS = { "CharacterState.AbilityState.", "CharacterState.WeaponUpgrade." } }
function TAGD.want(t)
    for _, r in ipairs(TAGD.ROOTS) do
        if t:sub(1, #r) == r then return true end
    end
    return false
end
function TAGD.schedule(tn)
    if TAGD.n >= TAGD.MAX then return end
    if MATCH.state ~= "fight" or MATCH.round ~= 1 or TAGD.due then return end
    TAGD.due, TAGD.at, TAGD.id = tn + TAGD.WAIT, tn, MATCH.id
end
function TAGD.step(tn)
    if not TAGD.due then return end
    if MATCH.state ~= "fight" then TAGD.due = nil; return end      -- 3 秒内回合结束 / 退出：作废
    if tn < TAGD.due then return end
    TAGD.due = nil
    TAGD.n = TAGD.n + 1
    local p1, pup = getP1(), puppet()
    if not (G.geTags and valid(p1) and valid(pup)) then
        out("§249 状态对比 #%d/%d：读不到（%s）", TAGD.n, TAGD.MAX, not G.geTags and "没有 G.geTags" or "玩家 / 替身无效")
        return
    end
    local okA, mine, srcA = pcall(G.geTags, p1)
    local okB, theirs = pcall(G.geTags, pup)
    if not (okA and type(mine) == "table" and okB and type(theirs) == "table") then
        out("§249 状态对比 #%d/%d：读不到标签（你 %s / 替身 %s）", TAGD.n, TAGD.MAX,
            okA and "读到" or tostring(mine), okB and "读到" or tostring(theirs))
        return
    end
    local setB, nm, nt = {}, 0, 0
    for _, t in ipairs(theirs) do
        if TAGD.want(t) then nt = nt + 1; setB[t] = true end
    end
    local diff = {}
    for _, t in ipairs(mine) do
        if TAGD.want(t) then
            nm = nm + 1
            if not setB[t] then diff[#diff + 1] = t end
        end
    end
    table.sort(diff)
    out("§249 状态对比 #%d/%d（对局#%s 第 1 回合开打后 %.1f 秒）：你有 %d 个状态标签 / 替身 %d 个；只列你有、替身没有的 %d 个",
        TAGD.n, TAGD.MAX, tostring(MATCH.id or "?"), tn - (TAGD.at or tn), nm, nt, #diff)
    for i = 1, math.min(#diff, TAGD.MAX_LOG) do
        local t = diff[i]
        out("  - %s（GE：%s）", t, (type(srcA) == "table" and srcA[t]) or "?")
    end
    if #diff > TAGD.MAX_LOG then out("  … 还有 %d 个（只列前 %d 个）", #diff - TAGD.MAX_LOG, TAGD.MAX_LOG) end
    if #diff == 0 then out("  （没有差）") end
end

function LO.snapLock(pup)
    local tc = LO.targetingComp(pup)
    local t = tc and ZMX.lockStruct(tc)
    if not t then return false end
    local ok, _, has = LO.tcSetLock(tc, t)
    if not NET.rlk then ZMX.tcUnlockAt = math.max(ZMX.tcUnlockAt or 0, now() + 1.5) end
    ST.snapLockN = (ST.snapLockN or 0) + 1
    if ST.snapLockN <= 5 then out("  Snap 前替身瞄准组件锁你：%s，HasLockTarget=%s（第 %d 次）", ok and "调用成功" or "失败", tostring(has), ST.snapLockN) end
    return ok and has == true
end

-- §192 紫冥剑飞剑对面只出不飞（HANDOVER §192）。资产（游戏包名字表，11-09 离线查）：DB（GA_Hun_ZiMingJian_New_DB）生成子弹
-- B_Hun_ZiMingJian_FlyingSword_Aim_Fast → BP_Hun_ZIMingJian_FlyingSword_Aim，挂在肩膀槽 ZiMingJian.HoldingFlyingSword.Slot1–7，
-- 用 WaitGameplayEventToActor 在主人身上等 ZiMingJian.FeiJian.FireInstantly，收到才 Fire 射出去（有 Fired? 标记）；
-- 发这个事件的只有五个收尾招 ABB / BBB / AAAAA / AABB / AAABB（技能里的 GAA_GameplayEvent 动作）。
-- 替身上飞剑生成了（DB 放得出），收尾招替身也放了，但剑没飞：事件没发到 / 没等到（推测，见 §192），Lua 发不了这个事件
-- （SendGameplayEventToActor 的 Payload 带 GameplayTagContainer，传了会崩，§19.20）。
-- 做法：替身放这五招时记下肩上有几把剑；WAIT 秒后还没 Fired? 的，调剑自己的 Fire 补射（游戏自己射过的不动）。
-- 日志写清"自己飞了几把 / 补射几把"，实测一次就知道原因在哪。net/fj_off.txt 存在 = 只记不补射
FJ = { FIN = { GA_Hun_ZiMingJian_New_ABB_C = true, GA_Hun_ZiMingJian_New_BBB_C = true, GA_Hun_ZiMingJian_New_AAAAA_C = true,
               GA_Hun_ZiMingJian_New_AABB_C = true, GA_Hun_ZiMingJian_New_AAABB_C = true },
       CLS = "BP_Hun_ZIMingJian_FlyingSword_Aim_C", FIRED = "Fired?", FIRE = "Fire", WAIT = 1.2, LOGS = 40, logs = 0,
       FLY = 1.5, win = nil, holdLogs = 0 }
FJ.OFF_FILE = NET_DIR .. "/fj_off.txt"

-- §370 飞剑打到我的时候，收尾招的判定窗口常常已经关了（用户 11-17"B 攻击产生的所有飞剑经常丢失判定"）：
-- 收尾招开窗口后 JUDGE_WIN 1.2 秒没掉血判落空、中过的多段累加也只等最后一段后 1.2 秒；飞剑却是收尾招放出 WAIT 1.2 秒后才补射
-- （游戏自己射也要在收尾招中途），再飞 0.3–1 秒才到（B_Hun_ZiMingJian_FlyingSword_Shoot：初速 500、追踪、第一段最多 1 秒）。
-- 窗口一关，飞剑掉的血不记在任何一招上（攻击方收不到"命中"，替身不播受击、招式统计里没有）。
-- 现在：收尾招放出时替身肩上有剑 → 记一个"飞剑在路上"的窗口（放招后 WAIT + FLY 秒），这段时间这一招的判定窗口 / 多段累加不过期
function FJ.live(id, tn)
    local w = FJ.win
    return w ~= nil and id == w.id and tn <= w.untilT
end
function FJ.holdLog(id, tn, what)
    local w = FJ.win
    if w.logged or FJ.holdLogs >= 30 then return end
    w.logged, FJ.holdLogs = true, FJ.holdLogs + 1
    out("§370 紫冥剑飞剑：远端#%d %s 放出 %.1f 秒，飞剑还在路上 → %s接着等到 %.1f 秒", id, w.name, tn - w.at, what, w.untilT - w.at)
end
-- netJudge：判定窗口到期时问一下（true = 接着等）
function FJ.keepJudge(j, tn)
    if not (j and FJ.live(j.id, tn)) then return false end
    FJ.holdLog(j.id, tn, "判定窗口")
    return true
end
-- netJudge：上一下中招的多段累加到期时问一下（true = 接着累加）
function FJ.holdHit(lh, tn)
    local id = lh and lh.r and lh.r.atk
    if not (id and FJ.live(id, tn)) then return false end
    FJ.holdLog(id, tn, "多段累加")
    return true
end

function FJ.log(...)
    if FJ.logs < FJ.LOGS then FJ.logs = FJ.logs + 1; out(...) end
end
function FJ.off()
    local f = io.open(FJ.OFF_FILE, "r")
    if f then f:close(); return true end
    return false
end

function FJ.onFire(pup, e, tn)
    if not FJ.FIN[e.name] then return end
    local s = LO.bulletsOf(pup, FJ.CLS, FJ.FIRED)
    FJ.pend = { id = e.id, name = e.name, at = tn, n = #s }
    if #s > 0 then FJ.win = { id = e.id, name = e.name, at = tn, untilT = tn + FJ.WAIT + FJ.FLY } end   -- §370
    FJ.log("紫冥剑飞剑：远端#%d %s，替身肩上 %d 把", e.id, e.name, #s)
    if #s > 0 and not FJ.probed then
        FJ.probed = true
        FJ.log("  紫冥剑飞剑：剑上带 Fire 的函数 %s", table.concat(LO.funcsLike(s[1].actor, "Fire"), " "))
    end
end

function FJ.step(pup, tn)
    local p = FJ.pend
    if not p or tn - p.at < FJ.WAIT then return end
    FJ.pend = nil
    local s = LO.bulletsOf(pup, FJ.CLS, FJ.FIRED)
    local left = {}
    for _, b in ipairs(s) do if b.fired == false then left[#left + 1] = b.actor end end
    if #left == 0 then
        FJ.log("  紫冥剑飞剑：远端#%d %.1f 秒后肩上还剩 %d 把，没有待射的（放招时 %d 把）", p.id, FJ.WAIT, #s, p.n)
        return
    end
    if FJ.off() then
        FJ.log("  紫冥剑飞剑：远端#%d %d 把没射（有 net/fj_off.txt，不补射）", p.id, #left)
        return
    end
    local ok, err = 0, nil
    for _, a in ipairs(left) do
        local okF, e = LO.callNoArg(a, FJ.FIRE)
        if okF then ok = ok + 1 else err = e end
    end
    FJ.log("  紫冥剑飞剑：远端#%d %s %.1f 秒后 %d 把没射，补调 Fire：成功 %d%s", p.id, p.name, FJ.WAIT, #left, ok,
        err and ("，失败 " .. tostring(err)) or "")
end

function ZMX.step(pup, tn)
    FJ.step(pup, tn)                     -- §179
    if tn < ZMX.p1LockUntil or NET.rlk then ZMX.p1Lock(true, "每帧放到胸口") end     -- §132 对方锁你时一直放（替身瞄准组件锁的是它）
    if ZMX.tcUnlockAt and tn >= ZMX.tcUnlockAt then          -- 火枪锁的你：对方其实没锁你 → 撤掉，免得替身别的招也追着你
        ZMX.tcUnlockAt = nil
        local tcU = not NET.rlk and LO.targetingComp(pup)
        if tcU then LO.tcStop(tcU); ZMX.log("  紫冥剑：火枪打完，对方没锁定你，撤掉替身瞄准组件的锁定") end
    end
    local c = ZMX.cur
    if not c then return end
    local el = tn - c.at
    if el < ZMX.PAUSE_AT and not c.paused then return end
    local alive = LO.activeInstance(pup, ZMX.CLS) ~= nil
    local m = montageOf(pup)
    if c.watch and tn >= c.watch.at then
        ZMX.log("  紫冥剑实验：调 %s 后 %.2f 秒替身动作 %s，技能还在=%s", c.watch.fn, tn - c.watch.t0, m ~= "" and m or "（没动作）", tostring(alive))
        local inst = alive and LO.activeInstance(pup, ZMX.CLS)
        if inst then ZMX.log("  紫冥剑实验：调完后技能变量 %s", LO.propsLike(inst, ZMX.STATE)) end
        if c.paused and m:find("Summon_Start", 1, true) then       -- 停着调没反应：继续播，看技能自己往下走成什么
            G.montagePause(pup, false); c.paused = false
            ZMX.log("  紫冥剑实验：动作没换，起手继续播")
        end
        c.watch = nil
    end
    if not ZMX.NO_PAUSE and not c.paused and not c.summoned then
        if m:find("Summon_Start", 1, true) and alive then
            local ok = G.montagePause(pup, true)
            c.paused = ok
            ZMX.log("紫冥剑实验：远端#%d 放出 %.2f 秒，停住起手 %s：%s", c.id, el, m, ok and "成功" or "失败")
            local inst = LO.activeInstance(pup, ZMX.CLS)
            if inst then ZMX.log("  紫冥剑实验：停住时技能变量 %s", LO.propsLike(inst, ZMX.STATE)) end
            if not ok then ZMX.finish(pup, "停不住", tn) end
        else
            ZMX.finish(pup, string.format("没来得及停：动作 %s，技能还在=%s", m ~= "" and m or "（没动作）", tostring(alive)), tn)
        end
        return
    end
    if tn >= c.nextLog then
        c.nextLog = tn + 0.5
        ZMX.log("  紫冥剑实验：停着 %.1f 秒，动作 %s，技能还在=%s", el, m ~= "" and m or "（没动作）", tostring(alive))
    end
    if not alive then ZMX.finish(pup, "技能自己没了", tn)
    elseif el > ZMX.HOLD_MAX then ZMX.finish(pup, "等满 " .. ZMX.HOLD_MAX .. " 秒", tn) end
end

-- 收到对方的召唤动作：Gun / JinGua / TieChi → 调替身 DB 实例的 TrySummon*。返回 true, 日志用的说法 = 调用方不再照播动作
function ZMX.onSub(pup, sm, tn)
    local kind = sm:match("Summon_(%a+)_%d")
    local fn = kind and ZMX.FN[kind]
    if not fn and ZMX.SKIP_LOOP and ZMX.cur and sm:find("_Loop", 1, true) then return true, "实验中不照播（让技能自己走）" end
    if not PEER.on then GDMG.onSub("op", sm, tn) end      -- §212 对方的锤 / 伞 / 反击：这段时间火枪的命中不按每发算（§223 观战不记伤害）
    -- §184 火枪冷却（挨打方为准）：对方上一把火枪还在场 / 收掉后没过冷却 → 替身不召、也不照播动作（第三个返回值 = 跳过）。
    -- §223 观战不挡：规则对战双方那边已经执行过，发来的就是真召出来的（GCD 也不是每个观战替身一份）
    if kind == "Gun" and not PEER.on then
        local why = GCD.blockOp(tn)
        if why then return true, why, true end
    end
    if not fn or ZMX.off() then return false end
    local inst = LO.activeInstance(pup, ZMX.CLS)
    if not inst then
        ZMX.log("紫冥剑实验：对方召唤 %s，替身的 DB 已经没了，照播动作", sm)
        return false
    end
    local c = ZMX.cur
    ZMX.log("  紫冥剑实验：调之前技能变量 %s（替身动作 %s）", LO.propsLike(inst, ZMX.STATE), montageOf(pup))
    if kind == "Gun" then ZMX.p1Lock(false, "召唤火枪时"); ZMX.p1LockUntil = tn + 3.0 end
    local tc, tcKey = LO.targetingComp(pup)
    if not ZMX.tcProbed then
        ZMX.tcProbed = true
        out("紫冥剑实验：替身瞄准组件 %s；带 Lock 的函数：%s；属性：%s", tc and (tcKey .. " " .. short(pathOf(tc))) or "没有",
            tc and table.concat(LO.funcsLike(tc, "Lock"), " ") or "-", tc and LO.propsLike(tc, { "Lock", "Target" }) or "-")
        if tc then out("紫冥剑实验：SetLockTarget 参数 %s；GetLockTarget 参数 %s", LO.paramTypes(tc, "SetLockTarget"), LO.paramTypes(tc, "GetLockTarget")) end
    end
    -- 2026-11-07 真人对战火枪还是打头顶：对方没硬锁你（lk=0）时以前不锁 → 替身火枪没目标平射。对方那边不锁也有软锁定，
    -- 1v1 场上敌人只有你，他的火枪照样瞄你 → 召唤火枪时不管 lk 都锁你，3 秒后对方还是没锁你就撤掉
    if tc and (NET.rlk or kind == "Gun") then
        ZMX.tcLock(tc)
        if not NET.rlk then ZMX.tcUnlockAt = tn + 3.0 end
    end
    local flag = ZMX.FLAG[kind]
    local okF = pcall(function() inst[flag] = false end)
    ZMX.log("  紫冥剑实验：%s 写成 false %s，读回 %s", flag, okF and "成功" or "失败", tostring(rawProp(inst, flag)))
    local ok, err = LO.callNoArg(inst, fn)
    if ok then
        ST.pupAtkAt = tn                 -- 召唤也算出招：对方锁定你时接下来 ATK_HOLD 秒对准你
        if BAL.active() then BAL.noteSummon(ZMX.CLS, tn) end   -- §177 锤枪伞打你时按 DB 的系数算
        if kind == "Gun" and not PEER.on then GCD.onSummon("op", tn); GDMG.onGun("op", c and c.id, tn) end   -- §184 替身召出火枪：开始看它什么时候收掉；§212 记是哪次 DB
    end
    ZMX.log("紫冥剑实验：对方召唤 %s → 替身 DB 调 %s：%s", sm, fn, ok and "调用成功" or ("失败 " .. tostring(err)))
    if c then
        c.watch, c.summoned = { at = tn + 0.3, t0 = tn, fn = fn }, true
        c.at = tn - ZMX.PAUSE_AT       -- 再给一段 HOLD_MAX，对方可能接着召唤下一件
    end
    return ok, ok and "已调技能召唤" or nil
end

return AIR
end
