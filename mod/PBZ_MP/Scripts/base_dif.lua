-- base_dif.lua —— 从 main.lua 搬出来的 §266 对局难度 + 整场对局否决存档（docs/MAIN_SLIM.md）。原来在 main.lua 的 "-- ============================================================ §266 对局难度 + 整场对局否决存档" 那段
return function(ctx)
local NET, MATCH, NET_DIR, G = ctx.NET, ctx.MATCH, ctx.NET_DIR, ctx.G
local valid, now = G.valid, G.now
-- main.lua 主循环那段会把 out / fileReadKV 换成计时包装（PROF.wrap），这两个由 ctx 传"调用时再取"的包装，
-- 和搬出来之前一样走计时（docs/MAIN_SLIM.md 规矩 3）
local out, fileReadKV = ctx.out, ctx.fileReadKV

-- ============================================================ §266 对局难度 + 整场对局否决存档
-- ① 否决存档：以前只有标准数值模式进（STD.VETO_ID），普通对局里开局资源、锁血、获取倍率这些临时改动挂着时，铃铛 / 触发器的存档照样能写。
--    现在每场对局第一次进倒计时 / 开打就进（原因 0 + 2，见 G.saveVeto），回自由活动时退。
-- ② 对局难度（房间设置 dif，见 NET.RES_TEXT.dif）：本机存档难度 ≠ 这一场的难度时，把本机当前难度的战斗配置对象
--    （GlobalConfig_Combat_<本机>）上的简单字段改成目标难度那份的值，回自由活动时按记下的原值改回。
--    不切游戏难度（切到入阵者会锁成就 / 六十六天、本周目换不回来）；配置只在内存里，不进存档，游戏崩了重启自己复原，不用记文件。
--    一场只改一次（每回合倒计时 / 开打都调，第二次起直接返回）。结构体 / 表类字段（各类怪的属性倍率）不改，第一次记一行有哪些
-- 全局（不是 local）：主代码块的 local 已满 200 个
DIF = { VETO_ID = "PBZ_MP_Match", saved = nil, veto = false, skipLogged = false, SKIP_SHOW = 40 }
function DIF.name(m)
    local t = NET.RES_TEXT.dif[m]
    return t and t[1] or ("难度 " .. tostring(m))
end
function DIF.val(v)
    if type(v) == "number" then
        if v == math.floor(v) then return string.format("%d", v) end
        return string.format("%.3g", v)
    end
    return tostring(v)
end
function DIF.apply(why)
    if not DIF.veto then
        local okV, msg = G.saveVeto(true, DIF.VETO_ID)
        DIF.veto = okV
        out("对局：进否决存档 %s（%s）", okV and "成功" or "失败", tostring(msg))
    end
    if DIF.saved then return end
    DIF.saved = { list = {} }
    local want = MATCH.res and MATCH.res.dif
    if not want or want == 0 then
        out("对局难度：各用自己存档的难度（%s）", why)
        return
    end
    local cur, err = G.difficultyMode()
    if not cur then
        out("!! 对局难度：读不到本机难度（%s），这一场按本机自己的", tostring(err))
        return
    end
    if cur == want then
        out("对局难度：本机存档就是%s，不用改（%s）", DIF.name(cur), why)
        return
    end
    local dst, src = G.combatConfig(cur), G.combatConfig(want)
    if not (dst and src) then
        out("!! 对局难度：找不到战斗配置（本机%s %s，目标%s %s），这一场按本机自己的",
            DIF.name(cur), dst and "有" or "没有", DIF.name(want), src and "有" or "没有")
        return
    end
    local changed, skipped = G.configCopy(dst, src)
    DIF.saved = { cfg = dst, list = changed, cur = cur, want = want }
    local parts = {}
    for _, c in ipairs(changed) do parts[#parts + 1] = string.format("%s %s→%s", c[1], DIF.val(c[2]), DIF.val(c[3])) end
    out("对局难度：本机存档是%s，这一场按%s（%s）：改了 %d 项%s", DIF.name(cur), DIF.name(want), why, #changed,
        #parts > 0 and ("：" .. table.concat(parts, "，")) or "（两份配置的简单字段一样）")
    if #skipped > 0 and not DIF.skipLogged then
        DIF.skipLogged = true
        local shown = {}
        for i = 1, math.min(#skipped, DIF.SKIP_SHOW) do shown[i] = skipped[i] end
        out("对局难度：没改的字段 %d 个（结构体 / 表 / 引用，不是简单数字）：%s%s", #skipped, table.concat(shown, " "),
            #skipped > DIF.SKIP_SHOW and " …" or "")
    end
end
function DIF.restore(why)
    local s = DIF.saved
    DIF.saved = nil
    if s and s.cfg and #s.list > 0 then
        local n = valid(s.cfg) and G.configRestore(s.cfg, s.list) or 0
        out("%s对局难度：%s的配置改回（%s）：%d / %d 项", n == #s.list and "" or "!! ", DIF.name(s.cur), why or "-", n, #s.list)
    end
    if DIF.veto then
        local okV, msg = G.saveVeto(false, DIF.VETO_ID)
        DIF.veto = false
        out("对局：退出否决存档 %s（%s）", okV and "成功" or "失败", tostring(msg))
    end
end

-- §158 数值表下发（用户 11-08"完全平衡数据 / 武器平衡数据改成从服务器下发 / 从主机下发"）。
-- 伤害在挨打方本机按它自己的表算，两边的 pbz_balance.lua / 标准数值基准不一样就不对称、谁也看不出来。
-- 现在：主机状态包带 cfgh=<哈希>；客机的哈希对不上就经可靠通道要（cfgreq），主机把配置拆成块发（cfg <哈希> <第几块> <共几块> <内容>）；
-- 每场第 1 回合倒计时定下这一场用哪份（主机 = 本地；客机 = 收齐、哈希对得上的主机那份，不然用本地并在横幅上标出来），结束换回本地。
-- 只下发可调的数：标准数值的属性 / 等级 / 统一给的天赋、武器平衡的族系数 / 单招系数 / 影之武装系数。
-- pbz_stdgear.lua（每把武器 30 级该挂什么，是从游戏里读出来的事实）不下发。
-- 收到的东西都过白名单：属性名只认 STD.ORDER、天赋只认本地基准里有的、系数 0–5、招式名只认 GA_ 开头的字母数字下划线。
CFG = { CHUNK = 600, REQ_EVERY = 3.0, local_ = nil, localStr = nil, localHash = nil,
        rHash = nil,            -- 对方（主机）状态包里报的哈希
        have = nil, haveHash = nil, parts = nil, partsHash = nil, reqAt = -100, srcNote = nil }

-- §210 表版本号 fv=：每加一组新字段（下面 CFG.KEYS 加键）就把 FV 加 1。旧版本解码不认 fv=、照旧跳过；新版本看到比自己新的 fv、
-- 或者不认识的键，整份不收（服务器那份 → 用模组文件、横幅提示更新；主机那份 → 用本地、规则指纹会对不上）。
-- 1 = §158 基础（a / lv / t / tr / e / f / m）、2 = §177 s=、3 = §184 cd=、4 = §199 d= / cc=、5 = §200.10 co=、6 = §206 ch=、7 = §212 sd=
CFG.FV = 7
CFG.KEYS = { v = true, fv = true, a = true, lv = true, t = true, tr = true, e = true, f = true, m = true, s = true, cd = true,
             d = true, cc = true, co = true, ch = true, sd = true }

function CFG.hash(s)            -- FNV-1a 32 位，十六进制
    local h = 0x811c9dc5
    for i = 1, #s do h = ((h ~ s:byte(i)) * 0x01000193) & 0xffffffff end
    return string.format("%08x", h)
end

function CFG.num(v) return string.format("%.6g", v) end
function CFG.short(n)       -- 招式名缩写：GA_Hun_X_C → ~X，GA_X_C → ^X
    local m = n:match("^GA_Hun_(.+)_C$")
    if m then return "~" .. m end
    m = n:match("^GA_(.+)_C$")
    if m then return "^" .. m end
    return n
end
function CFG.long(s)
    if s:sub(1, 1) == "~" then return "GA_Hun_" .. s:sub(2) .. "_C" end
    if s:sub(1, 1) == "^" then return "GA_" .. s:sub(2) .. "_C" end
    return s
end
function CFG.fallback(name, fam, edge)     -- 表里没有这招时的系数（和 BAL.moveScale 一样的兜底）
    local f = name:match("^GA_Hun_(%w+)_")
    local v = f and fam[f] or 1.0
    if LO.isEdgeAttack(name) then v = v * edge end
    return v
end

-- 现在本机用着的这份（STD / BAL / LO.EDGE_SCALE）
function CFG.snapshot()
    local c = { attr = {}, lv = STD.LEVEL, tal = {}, tree = {}, fam = {}, mv = {}, edge = LO.EDGE_SCALE, sum = {}, cd = {}, dot = {}, ctrl = {}, co = {}, chill = {}, sd = {} }
    for k, v in pairs(STD.ATTR) do c.attr[k] = v end
    for _, n in ipairs(STD.TALENT_GE) do c.tal[#c.tal + 1] = n end
    for _, n in ipairs(STD.TREE_GE) do c.tree[#c.tree + 1] = n end
    for k, v in pairs(BAL.FAMILY) do c.fam[k] = v end
    for k, v in pairs(BAL.MOVE) do c.mv[k] = v end
    for k, v in pairs(BAL.SUMMON) do c.sum[k] = v end
    for k, v in pairs(BAL.COOLDOWN) do c.cd[k] = v end      -- §184
    for k, v in pairs(BAL.DOT) do c.dot[k] = v end          -- §199
    for k, v in pairs(BAL.CTRL) do c.ctrl[k] = v end
    for k, v in pairs(BAL.COST) do c.co[k] = v end          -- §200.10
    for k, v in pairs(BAL.CHILL_DEF) do c.chill[k] = v end  -- §206（没写的项按默认，编码出来总是完整的）
    for k, v in pairs(BAL.CHILL) do c.chill[k] = v end
    for k, v in pairs(BAL.SDMG_DEF) do c.sd[k] = v end     -- §212（同 chill：编码出来总是完整的）
    for k, v in pairs(BAL.SDMG) do c.sd[k] = v end
    return c
end

-- 规范化成一行（排好序，同样的内容哈希一样）。单招只发和兜底不一样的
function CFG.encode(c)
    local function sortedKV(t, fmtKey)
        local ks = {}
        for k in pairs(t) do ks[#ks + 1] = k end
        table.sort(ks)
        local o = {}
        for _, k in ipairs(ks) do o[#o + 1] = (fmtKey and fmtKey(k) or k) .. ":" .. CFG.num(t[k]) end
        return table.concat(o, ",")
    end
    local mv = {}
    for k, v in pairs(c.mv) do
        if math.abs(v - CFG.fallback(k, c.fam, c.edge)) > 1e-6 then mv[k] = v end
    end
    local tal, tree = {}, {}
    for _, n in ipairs(c.tal) do tal[#tal + 1] = n end
    for _, n in ipairs(c.tree) do tree[#tree + 1] = n end
    table.sort(tal); table.sort(tree)
    return table.concat({ "v=1", "fv=" .. CFG.FV, "a=" .. sortedKV(c.attr), "lv=" .. CFG.num(c.lv), "t=" .. table.concat(tal, ","),
        "tr=" .. table.concat(tree, ","), "e=" .. CFG.num(c.edge), "f=" .. sortedKV(c.fam), "m=" .. sortedKV(mv, CFG.short),
        "s=" .. sortedKV(c.sum or {}, CFG.short),        -- §177 召唤留场秒数（旧版解码不认 s=，直接跳过）
        "cd=" .. sortedKV(c.cd or BAL.CD_DEF),              -- §184 召唤物冷却秒数（同上，旧版跳过）
        "d=" .. sortedKV(c.dot or {}, CFG.short),           -- §199 持续伤害系数（招名缩写 / 族名；旧版跳过）
        "cc=" .. sortedKV(c.ctrl or {}),                    -- §199 控制类异常时长上限（旧版跳过）
        "co=" .. sortedKV(c.co or BAL.COST_DEF),            -- §200.10 闪避扣杀气 / 切武器保持杀气（旧版跳过）
        "ch=" .. sortedKV(c.chill or BAL.CHILL_DEF),        -- §206 冰缓伤害倍数（旧版跳过；不放进 cc=：cc= 的旧解码不认新键会整张表不认）
        "sd=" .. sortedKV(c.sd or BAL.SDMG_DEF) }, "|")     -- §212 召唤物每发伤害点数（0.31.0 及更早跳过；§210 起的旧版见 fv=7 整份不收）
end

-- 解析 + 白名单；不对返回 nil, 原因
function CFG.decode(s)
    local p = {}
    for part in (s or ""):gmatch("[^|]+") do
        local k, v = part:match("^(%w+)=(.*)$")
        if k then p[k] = v end
    end
    if p.v ~= "1" then return nil, "版本不认识：" .. tostring(p.v) end
    -- §210 表版本号：表里的格式比我的模组新 / 有我不认识的项 → 整份不收（不半套地用：新加的项被跳过就是"悄悄不一样"）
    local fv = tonumber(p.fv)
    if fv and fv > CFG.FV then return nil, string.format("表比你的模组新（格式 %d，你的模组只认到 %d），请更新模组", fv, CFG.FV), "newer" end
    for k in pairs(p) do
        if not CFG.KEYS[k] then return nil, "表里有你的模组不认识的项 " .. k .. "，请更新模组", "newer" end
    end
    local okAttr, okTal, okTree = {}, {}, {}
    for _, a in ipairs(STD.ORDER) do okAttr[a] = true end
    for _, n in ipairs(CFG.file_.tal) do okTal[n] = true end
    for _, n in ipairs(CFG.file_.tree) do okTree[n] = true end
    local function pairsOf(str, fn)
        for item in (str or ""):gmatch("[^,]+") do
            local k, v = item:match("^([^:]+):([%-%d%.eE+]+)$")
            v = tonumber(v)
            if not (k and v) then return false, "坏项 " .. item end
            local ok, why = fn(k, v)
            if not ok then return false, why end
        end
        return true
    end
    local c = { attr = {}, tal = {}, tree = {}, fam = {}, mv = {}, sum = {}, cd = {}, dot = {}, ctrl = {}, co = {}, chill = {}, sd = {} }
    local ok, why = pairsOf(p.a, function(k, v)
        if not okAttr[k] then return false, "属性不认识 " .. k end
        if v < 1 or v > 100000 then return false, "属性超范围 " .. k end
        c.attr[k] = v; return true
    end)
    if not ok then return nil, why end
    for _, a in ipairs(STD.ORDER) do if not c.attr[a] then return nil, "缺属性 " .. a end end
    c.lv = tonumber(p.lv)
    if not (c.lv and c.lv >= 1 and c.lv <= 30) then return nil, "等级超范围" end
    for n in (p.t or ""):gmatch("[^,]+") do
        if not okTal[n] then return nil, "天赋不认识 " .. n end
        c.tal[#c.tal + 1] = n
    end
    for n in (p.tr or ""):gmatch("[^,]+") do
        if not okTree[n] then return nil, "天赋树效果不认识 " .. n end
        c.tree[#c.tree + 1] = n
    end
    c.edge = tonumber(p.e)
    if not (c.edge and c.edge >= 0 and c.edge <= 5) then return nil, "影之武装系数超范围" end
    ok, why = pairsOf(p.f, function(k, v)
        if not k:match("^%w+$") or v < 0 or v > 5 then return false, "族系数不对 " .. k end
        c.fam[k] = v; return true
    end)
    if not ok then return nil, why end
    ok, why = pairsOf(p.m, function(k, v)
        local n = CFG.long(k)
        if not n:match("^GA_[%w_]+$") or v < 0 or v > 5 then return false, "单招系数不对 " .. k end
        c.mv[n] = v; return true
    end)
    if not ok then return nil, why end
    -- §177 召唤留场秒数：没有 s=（旧版主机 / 服务器发的）就用本地文件的
    if p.s == nil then
        for k, v in pairs(CFG.file_.sum or {}) do c.sum[k] = v end
    else
        ok, why = pairsOf(p.s, function(k, v)
            local n = CFG.long(k)
            if not n:match("^GA_[%w_]+$") or v <= 0 or v > BAL.SUM_CAP then return false, "召唤留场不对 " .. k end
            c.sum[n] = v; return true
        end)
        if not ok then return nil, why end
    end
    -- §184 召唤物冷却：没有 cd=（旧版主机 / 服务器发的表）= 默认（火枪 15 秒，BAL.CD_DEF）；cd= 空 = 都不冷却
    if p.cd == nil then
        for k, v in pairs(BAL.CD_DEF) do c.cd[k] = v end
    else
        ok, why = pairsOf(p.cd, function(k, v)
            if not k:match("^[%w_]+$") or v < 0 or v > BAL.CD_CAP then return false, "召唤冷却不对 " .. k end
            c.cd[k] = v; return true
        end)
        if not ok then return nil, why end
    end
    -- §199 持续伤害系数 / 控制类上限：没有 d= / cc=（旧版主机 / 服务器发的）就用本地文件的
    if p.d == nil then
        for k, v in pairs(CFG.file_.dot or {}) do c.dot[k] = v end
    else
        ok, why = pairsOf(p.d, function(k, v)
            local n = CFG.long(k)
            if not (n:match("^GA_[%w_]+$") or n:match("^%w+$")) or v < 0 or v > BAL.DOT_CAP then return false, "持续系数不对 " .. k end
            c.dot[n] = v; return true
        end)
        if not ok then return nil, why end
    end
    if p.cc == nil then
        for k, v in pairs(CFG.file_.ctrl or {}) do c.ctrl[k] = v end
    else
        ok, why = pairsOf(p.cc, function(k, v)
            if not BAL.CTRL_IDS[k] or v < 0 or v > BAL.CTRL_CAP then return false, "控制上限不对 " .. k end
            c.ctrl[k] = v; return true
        end)
        if not ok then return nil, why end
    end
    -- §200.10 闪避扣杀气 / 切武器保持杀气：没有 co=（旧版主机 / 服务器发的表）= 默认（20 / 20 / 开，BAL.COST_DEF）
    if p.co == nil then
        for k, v in pairs(BAL.COST_DEF) do c.co[k] = v end
    else
        ok, why = pairsOf(p.co, function(k, v)
            if not k:match("^[%w_]+$") or v < 0 or v > BAL.COST_CAP then return false, "消耗不对 " .. k end
            c.co[k] = v; return true
        end)
        if not ok then return nil, why end
    end
    -- §206 冰缓伤害倍数：没有 ch=（旧版主机 / 服务器发的表）= 默认（去掉伤害，BAL.CHILL_DEF）；不认识的键跳过（以后加项旧版不至于整张不认）
    for k, v in pairs(BAL.CHILL_DEF) do c.chill[k] = v end
    if p.ch ~= nil then
        ok, why = pairsOf(p.ch, function(k, v)
            if not BAL.CHILL_IDS[k] then return true end
            if v < 0 or v > 1 then return false, "冰缓倍数不对 " .. k end
            c.chill[k] = v; return true
        end)
        if not ok then return nil, why end
    end
    -- §212 召唤物每发伤害：没有 sd=（旧版主机 / 服务器发的表）= 默认（火枪 1，BAL.SDMG_DEF）；键 [%w_]+、0–SDMG_CAP，坏的整份不收（同 cd=）
    for k, v in pairs(BAL.SDMG_DEF) do c.sd[k] = v end
    if p.sd ~= nil then
        ok, why = pairsOf(p.sd, function(k, v)
            if not k:match("^[%w_]+$") or v < 0 or v > BAL.SDMG_CAP then return false, "召唤物每发伤害不对 " .. k end
            c.sd[k] = v; return true
        end)
        if not ok then return nil, why end
    end
    -- 没列出来的招按兜底：把兜底不是 1 的那些招也补成表里的数，解出来和 snapshot 一样完整
    for k in pairs(CFG.file_.mv) do
        if c.mv[k] == nil then c.mv[k] = CFG.fallback(k, c.fam, c.edge) end
    end
    return c
end

-- 让 STD / BAL 用这一份
function CFG.use(c)
    STD.ATTR, STD.LEVEL = {}, c.lv
    for k, v in pairs(c.attr) do STD.ATTR[k] = v end
    STD.TARGET_MULT = STD.mult(STD.LEVEL)
    STD.TALENT_GE, STD.TREE_GE = {}, {}
    for _, n in ipairs(c.tal) do STD.TALENT_GE[#STD.TALENT_GE + 1] = n end
    for _, n in ipairs(c.tree) do STD.TREE_GE[#STD.TREE_GE + 1] = n end
    BAL.FAMILY, BAL.MOVE = {}, {}
    for k, v in pairs(c.fam) do BAL.FAMILY[k] = v end
    for k, v in pairs(c.mv) do BAL.MOVE[k] = v end
    BAL.SUMMON = {}
    for k, v in pairs(c.sum or {}) do BAL.SUMMON[k] = v end
    BAL.COOLDOWN = {}
    for k, v in pairs(c.cd or BAL.CD_DEF) do BAL.COOLDOWN[k] = v end     -- §184
    BAL.DOT, BAL.CTRL = {}, {}
    for k, v in pairs(c.dot or {}) do BAL.DOT[k] = v end                 -- §199
    for k, v in pairs(c.ctrl or {}) do BAL.CTRL[k] = v end
    BAL.COST = {}
    for k, v in pairs(c.co or BAL.COST_DEF) do BAL.COST[k] = v end      -- §200.10
    BAL.CHILL = {}
    for k, v in pairs(c.chill or BAL.CHILL_DEF) do BAL.CHILL[k] = v end  -- §206
    BAL.SDMG = {}
    for k, v in pairs(c.sd or BAL.SDMG_DEF) do BAL.SDMG[k] = v end      -- §212
    LO.EDGE_SCALE = c.edge
end

-- 本机的基准：大厅服务器给过的那份（联机程序缓存在 net/srvcfg.txt，§158 服务器下发）优先，没有 / 坏了用模组目录里的文件
function CFG.init()
    CFG.file_ = CFG.snapshot()      -- 模组文件里的（也是解码时的白名单）
    CFG.pick()
end

function CFG.pick()
    local base, src = CFG.file_, "模组文件"
    local t = fileReadKV(NET_DIR .. "/srvcfg.txt")
    CFG.srvHash, CFG.srvAt, CFG.srvSig, CFG.srvPend = t and t.h, CFG.clock(), CFG.peek(), nil
    if t and t["end"] and t.h and t.s then
        if CFG.hash(t.s) ~= t.h then
            out("!! 数值表：srvcfg.txt 哈希对不上（%s ≠ %s），不用", CFG.hash(t.s), t.h)
        else
            local c, why, kind = CFG.decode(t.s)
            if c then base, src = c, "大厅服务器" else out("!! 数值表：大厅服务器那份不认（%s），用模组文件", tostring(why)) end
            CFG.srvNewer = (not c and kind == "newer") and why or nil      -- §210 横幅提示更新
        end
    end
    CFG.local_ = CFG.decode(CFG.encode(base))       -- 复制一份（下面测试开关会改）
    -- 测试用：net 目录里有 cfg_test.txt 就按它改本地这份（双开两份共用一个模组目录，造"两边表不一样"）。hp=血上限，mv=招名:系数
    local tt = fileReadKV(NET_DIR .. "/cfg_test.txt")
    if tt then
        if tonumber(tt.hp) then CFG.local_.attr.Health_Max = tonumber(tt.hp) end
        local mk, mvv = (tt.mv or ""):match("^([%w_]+):([%d%.]+)$")
        if mk then CFG.local_.mv[mk] = tonumber(mvv) end
        out("!! 数值表：测试用 cfg_test.txt 改了本地这份（hp=%s mv=%s）", tostring(tt.hp), tostring(tt.mv))
    end
    CFG.use(CFG.local_)
    CFG.localStr = CFG.encode(CFG.local_)
    CFG.localHash = CFG.hash(CFG.localStr)
    CFG.localSrc = src
    out("数值表（标准数值基准 + 武器平衡）：本地 %s，%d 字节，来自%s", CFG.localHash, #CFG.localStr, src)
end

-- §196 对局外每 SRV_EVERY 秒看一下联机程序有没有从服务器拿到新的。
-- 11-09 实测"游戏开着换了 srvcfg.txt、几分钟都没换上，只有重启才生效"，根因：以前按游戏时钟 now() 节流，
-- now() 在拿不到玩家控制器时（读档 / 切图的加载画面）退回 os.time()（≈ 17 亿秒），这一下把 srvAt 记成了 17 亿，
-- 加载完 now() 又回到游戏秒数，"tn - srvAt < 15" 永远成立 → 这一局游戏里再也不查。现在节流改用墙钟 CFG.clock（os.time），
-- 跟游戏时钟无关；墙钟倒退（改系统时间）也当到点。
-- 只读文件头：第一行 h=<哈希> + 文件大小（seek 到尾，不读内容），和上次一样就不往下读；变了才整份重读（CFG.pick）。
-- 对局中（MATCH.state 不是 idle）发现变了只记一行"等对局结束"，不换（这一场用的表不能中途变）；回自由活动（CFG.finish）后下一次检查就换
CFG.SRV_EVERY = 5
CFG.clock = os.time
-- srvcfg.txt 的"签名"：哈希行 + 大小；没有文件 = ""
function CFG.peek()
    local f = io.open(NET_DIR .. "/srvcfg.txt", "r")
    if not f then return "" end
    local h
    for _ = 1, 3 do         -- 联机程序写的第一行就是 h=；手写的文件可能前面有空行 / BOM，多看两行
        local l = f:read("l")
        if not l then break end
        h = l:match("h=(%x+)")
        if h then break end
    end
    local size = f:seek("end")
    f:close()
    return tostring(h) .. ":" .. tostring(size)
end
function CFG.refresh(tn)
    local w = CFG.clock()
    if CFG.srvAt and w >= CFG.srvAt and w - CFG.srvAt < CFG.SRV_EVERY then return end
    CFG.srvAt = w
    local sig = CFG.peek()
    if sig == CFG.srvSig then CFG.srvPend = nil; return end
    if MATCH.state ~= "idle" then
        if CFG.srvPend ~= sig then
            CFG.srvPend = sig
            out("数值表：srvcfg.txt 变了（%s → %s），对局中先不换，回到自由活动再换", tostring(CFG.srvSig), sig)
        end
        return
    end
    out("数值表：srvcfg.txt 变了（%s → %s），重新挑", tostring(CFG.srvSig), sig)
    CFG.pick()
end

-- 状态包里报的哈希
function CFG.wire()
    CFG.refresh(now())
    return CFG.localHash or ""
end

-- 收到对方状态包（我是客机或解说房间有房间规则时才管）
function CFG.onPacket(h, tn)
    local rr = NET.roomRules and NET.roomRules()
    if rr and rr.cfgh and rr.cfgh ~= "" and rr.cfgh ~= "0" then
        h = rr.cfgh
    end
    CFG.rHash = (h and h ~= "") and h or nil
    local isClient = (MATCH.session and MATCH.session.role) == "client"
    local sm = BASEHOOK.mp
    if sm and sm.inMp and sm.inMp() then isClient = NET.ruleClient() end      -- §295 多人房 / 对决：不是对局主机 = 要主机的表（服务器房的对局主机 session 也是 client）
    local hasRoomRules = rr ~= nil
    if (not isClient and not hasRoomRules) or not CFG.rHash then return end
    if CFG.rHash == CFG.localHash or CFG.rHash == CFG.haveHash then return end
    if tn - CFG.reqAt < CFG.REQ_EVERY then return end
    CFG.reqAt = tn
    CFG.rel.send("cfgreq", CFG.rHash)
end

-- 主机：把本地这份拆块发出去
function CFG.sendAll()
    local s, h = CFG.localStr, CFG.localHash
    local n = math.ceil(#s / CFG.CHUNK)
    for i = 1, n do CFG.rel.send("cfg", string.format("%s %d %d %s", h, i, n, s:sub((i - 1) * CFG.CHUNK + 1, i * CFG.CHUNK))) end
    out("数值表：发给对方 %s，%d 块", h, n)
end

-- 客机：收一块
function CFG.onChunk(rest)
    local h, i, n, data = rest:match("^(%x+) (%d+) (%d+) (.*)$")
    i, n = tonumber(i), tonumber(n)
    if not (h and i and n and n >= 1 and n <= 200 and i >= 1 and i <= n) then out("!! 数值表：坏块 %s", rest:sub(1, 40)); return end
    if CFG.partsHash ~= h then CFG.parts, CFG.partsHash = {}, h end
    CFG.parts[i] = data
    for k = 1, n do if not CFG.parts[k] then return end end
    local s = table.concat(CFG.parts, "", 1, n)
    CFG.parts, CFG.partsHash = nil, nil
    if CFG.hash(s) ~= h then out("!! 数值表：收齐了但哈希对不上（%s ≠ %s），不用", CFG.hash(s), h); return end
    local c, why = CFG.decode(s)
    if not c then out("!! 数值表：主机那份不认（%s），不用", tostring(why)); return end
    CFG.have, CFG.haveHash = c, h
    out("数值表：收到主机的 %s（%d 字节）", h, #s)
end

-- 每场第 1 回合倒计时：定下这一场用哪份
function CFG.begin()
    local role = MATCH.role
    local sm = BASEHOOK.mp
    if sm and sm.inMp and sm.inMp() then role = NET.ruleClient() and "client" or "host" end     -- §295 多人房 / 对决：MATCH.role 一直是空的，按对局主机定（1v1 照旧看 MATCH.role）
    local rr = NET.roomRules and NET.roomRules()
    local hasRoomRules = rr ~= nil
    if hasRoomRules and rr and rr.cfgh and rr.cfgh ~= "" and rr.cfgh ~= "0" then
        CFG.rHash = rr.cfgh
    end
    CFG.srcNote = nil
    if (role == "client" or hasRoomRules) and CFG.rHash and CFG.rHash ~= CFG.localHash then
        if CFG.haveHash == CFG.rHash then
            CFG.use(CFG.have)
            CFG.usedHash = CFG.rHash         -- §210 这一场用的是哪份（进规则指纹）
            out("数值表：这一场用主机的 %s", CFG.rHash)
        else
            CFG.use(CFG.local_)
            CFG.usedHash = CFG.localHash
            CFG.srcNote = "本地"
            out("!! 数值表：主机的 %s 还没收到 / 不认，这一场用本地的 %s（伤害可能不对称）", CFG.rHash, CFG.localHash)
        end
    else
        CFG.use(CFG.local_)
        CFG.usedHash = CFG.localHash
    end
end

-- 回到自由活动：换回本地
function CFG.finish()
    CFG.use(CFG.local_)
    CFG.srcNote = nil
    CFG.srvAt = nil        -- §196 回自由活动马上查一次 srvcfg.txt（对局中变了的这时换上）
end
CFG.init()
-- §110 武林盟主（排位）固定规则：联机程序在 lobby.txt 里给 rk=1（当前连接方式是 ranked）和 rkrules=bo=3;dm=150;med=0;bal=1;ctr=1;ab=0
-- （服务器下发）。这时上面的 NET.bestOf / dmgPct / allBlock / flag 一律按 rkrules 返回，主机、客机一样，不看本机 rules.txt / 主机状态包；
-- 开局 / 跟随时定下 MATCH.* 的地方调的就是它们，不用改。规则还没拿到（rk=1 但 rkrules 空）时不拿本机设置冒充：主机不让开局
-- （F1 / startMatchNow），那时各取值函数照旧。rkrules 里缺的键按原版默认，坏值不认（也按默认）。
-- lobby.txt 在 NETUI 段才读得到（netuiRead），这里先放个空的，那边换掉
NET.RK_DEF = { bo = 3, dm = 100, ab = 0, ctr = 1, bal = 0, med = 1, npos = 1, std = 0, ult0 = 0, ultx = 100, sp0 = 3, resm = 0, acc = 0, accn = 3 }   -- §176 accn 生效饰品数量：服务器 rkrules 的 accn=（moecn 写明 3，§169.5），不发也按 3（武林盟主默认只生效前 3 件）；禁用名单走 rkrules 的 accban=（§179.4，pbz_ranked.lua RK.accBan / NET.accBanOf）；§170.1 acc 饰品等级：服务器不发就是原样；§169 std 标准数值：服务器发 std=1 就开，不发就关（以前不在表里，排位写死关）；§113 ult0 / sp0 / resm：服务器不发就是 0 / 3 / 每场（§113.3）；§113.4 ultx 获取倍率 100%；§138 npos 对手位置严格跟随（以前不在表里：排位跟主机自己的设置，固定规则页还误显示"关"）
NET.RK_DEF.tl = 180      -- §173 武林盟主回合时限：服务器不发 tl= 就是 180 秒
NET.RK_DEF.gcd, NET.RK_DEF.dgc, NET.RK_DEF.sycd = 1, 1, 1     -- §216 武林盟主：火枪冷却 / 闪避扣杀气 / 瞬影冷却服务器不发就开（和以前跟着 bal=1 一样）
NET.RK_DEF.swk = 1      -- 11-16 武林盟主：切武器保持杀气服务器不发就开（以前跟着 bal=1）
NET.RK_DEF.stg = 1      -- §228 武林盟主：精防硬直服务器不发就开（以前一直生效）
NET.RK_DEF.dif = 3      -- §266 武林盟主：对局难度服务器不发就是逆天者
NET.rkCache = {}
function NET.rkParse(s)      -- "bo=3;dm=150;…" → { bo = 3, dm = 150, … }；空 / 一个认识的键都没有 → nil
    if not s or s == "" then return nil end
    if NET.rkCache.s == s then return NET.rkCache.r end
    local r, any = {}, false
    for k, v in pairs(NET.RK_DEF) do r[k] = v end
    for k, v in s:gmatch("([%w_]+)=([%w_,%-]+)") do
        if k == "accban" or k == "wpnban" or k == "edgeban" or k == "cfgh" then
            r[k], any = v, true
        else
            local n, ok = tonumber(v), false
            if k == "bo" then ok = n and n >= 1 and n <= 99 and n % 2 == 1
            elseif k == "dm" then ok = n and n >= 10 and n <= 1000
            elseif NET.RES_MAX[k] then ok = n and NET.resValid(k, n)          -- §113
            elseif NET.RK_DEF[k] ~= nil then ok = n and (n == 0 or n == 1) end
            if ok then r[k], any = n, true end
        end
    end
    if not any then r = nil end
    if r and not s:find("swk=", 1, true) and (r.bal == 0 or r.bal == 1) then r.swk = r.bal end     -- 11-16 旧规则串没有 swk：按旧版跟着武器平衡
    NET.rkCache = { s = s, r = r }
    return r
end
function NET.roomRules()
    local ms = MATCH.session
    -- §309（11-14 实测）：联机程序给每个主机都写 roomrules=（把主机自己的设置格式化一遍），那不是"别人定的房间规则"。
    -- 真正的房间规则只从对方来：解说房房主发的 PBZRULES、服务器房的 SRULES（我是 client）。以前主机也当成房间规则：
    -- ① 规则来源"room"在主机上一直生效，rkParse 从排位默认值 RK_DEF 起算、又不认 medok → 主机自己"血瓶 关"被当成开（规则指纹 med=1）；
    -- ② REL.on.cfgreq 以为是解说房、不是解说房主就不回 → 客机永远拿不到主机的数值表（9335e8f 起，1v1 也一样）；
    -- ③ 主机的房间设置页顶上写"规则由解说（房主）定"
    if ms and ms.role == "host" then return nil end
    local s = (ms and ms.roomrules and ms.roomrules ~= "") and ms.roomrules
              or (NET.lobby and NET.lobby() and NET.lobby().roomrules and NET.lobby().roomrules ~= "" and NET.lobby().roomrules)
              or nil
    return s and NET.rkParse(s) or nil
end
-- F4b：定死的规则（武林盟主排位：lobby.txt 的 rk= / rkrules=）和解说房间规则都是 FMATCH.rules 里登记的"规则来源"（排位那份在 pbz_ranked.lua）。
-- 这两个包装给上面的取值函数用：fixedRules() = 第一个给出规则表的来源（排位规则还没到时退到解说房间规则，和以前 rkRules() or roomRules() 一样）；
-- locked() = 有没有"定死规则"的来源在生效（规则还没到也算）, 它的规则表（和以前的 NET.rk() 一样）
function NET.fixedRules() return FMATCH.fixedRules() end
function NET.locked() local p = FMATCH.lockedBy(); return p ~= nil, p and p.rules() or nil end

-- §181 作弊数据采样（CS 段，含 705 招的招表）0.34 整个删了：TASK_0.34 §2.2 / HANDOVER §250.2。

return { DIF = DIF, CFG = CFG }
end
