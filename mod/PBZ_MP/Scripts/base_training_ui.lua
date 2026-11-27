-- Local AI training controls; values are acknowledged through lobby.txt.
-- §456（用户 11-26 木桩新功能单）：防御 / 闪避、血量 / 杀气、精纯杀气 / 暗源、自动归位并进木桩训练这一页；
-- 重复出招加影之武装 / 影之武装特攻 / 精纯杀气招式，改名"防御 + 重攻击"等；重复间隔 0.2–8 秒、拖动条调。
return function(ctx)
local function T(zh, en)
    local f = EXTCTX and EXTCTX.T
    return f and f(zh, en) or zh
end
local U = {}
local actions = {
    {"none", "不出招", "NONE"},
    {"light", "轻攻击", "LIGHT"}, {"light_hold", "轻攻击按住", "HOLD LIGHT"},
    {"heavy", "重攻击", "HEAVY"}, {"heavy_hold", "重攻击按住", "HOLD HEAVY"},
    {"lh", "轻重", "LH"}, {"llh", "轻轻重", "LLH"},
    {"lllh", "轻轻轻重", "LLLH"}, {"llllh", "轻轻轻轻重", "LLLLH"},
    {"hl", "重轻", "HL"}, {"hll", "重轻轻", "HLL"},
    {"hlll", "重轻轻轻", "HLLL"}, {"hllll", "重轻轻轻轻", "HLLLL"},
    {"sprint_l", "冲刺后轻攻击", "SPRINT LIGHT"},
    {"sprint_lh", "冲刺后轻重", "SPRINT LH"},
    {"sprint_h", "冲刺后重攻击", "SPRINT HEAVY"},
    {"sprint_h_hold", "冲刺后重攻击蓄力", "SPRINT HOLD HEAVY"},
    {"sprint_hl", "冲刺后重轻", "SPRINT HL"},
    {"special", "防御+重攻击", "GUARD + HEAVY"},
    {"special_hold", "防御按住+重攻击按住", "HOLD GUARD + HOLD HEAVY"},
    {"advanced", "防御+处决", "GUARD + EXECUTION"},
    {"chi", "炽杀", "CHI KILL"},
    {"jump", "跳跃", "JUMP"}, {"jump_l", "跳跃轻攻击", "JUMP LIGHT"},
    {"jump_h", "跳跃重攻击", "JUMP HEAVY"},
    {"edge", "使用影之武装", "PHANTOM EDGE"},
    {"edge_hold", "使用影之武装（按住）", "PHANTOM EDGE (HOLD)"},
    {"edge_tap", "使用影之武装（连点）", "PHANTOM EDGE (MASH)"},
    {"edge_sp", "使用影之武装特攻", "EDGE SPECIAL"},
    {"edge_sp_hold", "使用影之武装特攻（按住）", "EDGE SPECIAL (HOLD)"},
    {"edge_sp_tap", "使用影之武装特攻（连点）", "EDGE SPECIAL (MASH)"},
    {"ult", "使用精纯杀气招式", "ULTIMATE"},
    {"ult_hold", "使用精纯杀气招式（按住）", "ULTIMATE (HOLD)"},
    {"ult_tap", "使用精纯杀气招式（连点）", "ULTIMATE (MASH)"},
}
U.ACTIONS = actions
U.PER_PAGE = 12
U.INTERVAL_MIN, U.INTERVAL_MAX, U.INTERVAL_DEFAULT = 0.2, 8.0, 2.0
local function send(k, v) ctx.command("aicfg", k .. "=" .. tostring(v) .. "\n") end
local function training() return ctx.training and ctx.training() end
local function clock() return (ctx.now and ctx.now()) or os.clock() end
-- 一行"名字：< 当前 >"，点一下换下一个
local function cycle(items, lb, key, zh, en, opts, default)
    local current, idx = lb[key] or default, 1
    for i, opt in ipairs(opts) do if opt[1] == current then idx = i; break end end
    items[#items + 1] = {label = T(zh, en) .. "< " .. T(opts[idx][2], opts[idx][3]) .. " >",
        act = function() send(key, opts[idx % #opts + 1][1]) end}
end
local function onOff(items, lb, key, zh, en, default)
    local on = lb[key] == nil and default or lb[key] == "1"
    items[#items + 1] = {label = T(zh, en) .. "< " .. (on and T("开", "ON") or T("关", "OFF")) .. " >",
        act = function() send(key, on and "0" or "1") end}
end

-- HP：脱战回血（trainHpRegen=1）/ 无限 HP（本地 AI 的无限 HP，和"AI 特殊资源设定"同一份）/ 损耗后不恢复（trainHpRegen=0：
-- 打空 = 正常判负；木桩里判负没有实际效果，只是像正常对局那样重新开局）
U.HP = { {"regen", "脱战回血", "REGEN OUT OF COMBAT"}, {"inf", "无限HP", "INFINITE HP"}, {"drain", "损耗后不恢复", "NO RECOVERY"} }
function U.hpMode(lb)
    local tr = training()
    if tr and tr.aiFlag and tr.aiFlag("hp") then return "inf" end
    return lb.trainHpRegen == "0" and "drain" or "regen"
end
function U.setHp(lb, mode)
    local tr = training()
    if mode == "inf" then
        return (tr and tr.setAiFlag and tr.setAiFlag("hp", true)) == true
    end
    if tr and tr.aiFlag and tr.aiFlag("hp") and tr.setAiFlag then tr.setAiFlag("hp", false) end
    send("trainHpRegen", mode == "drain" and "0" or "1")
    return true
end
-- 杀气：脱战回杀气（refill）/ 无限杀气（locked，原"无限且不减少"）/ 破防（empty）/ 损耗后不恢复（normal，原"通常"）
U.CHI = { {"refill", "脱战回杀气", "REGEN OUT OF COMBAT"}, {"locked", "无限杀气", "INFINITE CHI"},
          {"empty", "破防", "GUARD BREAK"}, {"normal", "损耗后不恢复", "NO RECOVERY"} }
U.GUARD = { {"none", "通常状态", "NORMAL"}, {"hold", "按住格挡", "HOLD GUARD"}, {"perfect", "完美招架", "PERFECT PARRY"} }
-- 11-26 AI 木桩 V2：加"通常"（normal = 模组不补也不定数，按游戏原样用 / 攒）
U.ULT = { {"normal", "通常", "NORMAL"}, {"inf", "无限", "INFINITE"}, {"3", "3个", "3"}, {"2", "2个", "2"}, {"1", "1个", "1"} }
U.SP = { {"normal", "通常", "NORMAL"}, {"inf", "无限", "INFINITE"}, {"3", "3个", "3"}, {"2", "2个", "2"}, {"1", "1个", "1"}, {"6", "6个", "6"} }
-- 11-26 AI 木桩 V2：AI 行为状态（= 联机程序的 ailevel：3 木桩 / 0 简单 / 1 普通 / 2 困难），按 测试木桩 → 1 级 → 2 级 → 3 级 轮换
U.LEVELS = { {3, "测试木桩", "TRAINING DUMMY"}, {0, "1级难度", "LEVEL 1"}, {1, "2级难度", "LEVEL 2"}, {2, "3级难度", "LEVEL 3"} }

-- 11-26 AI 木桩 V2：这一页改名"AI 训练设置"，所有难度都能进；AI 行为状态 / 跟随 / 装备 从 AI 首页挪进来，
-- 木桩那几项（重复出招、HP、杀气、格挡、闪避、精纯杀气、暗源、自动归位）只在"测试木桩"时显示
function U.common(lb, items, page)
    local lv, idx = tonumber(lb.ailevel) or 1, 1
    for i, o in ipairs(U.LEVELS) do if o[1] == lv then idx = i end end
    items[#items + 1] = {label = T("AI行为状态：", "AI BEHAVIOR: ") .. "< " .. T(U.LEVELS[idx][2], U.LEVELS[idx][3]) .. " >",
        act = function() ctx.command("ailevel", "level=" .. U.LEVELS[idx % #U.LEVELS + 1][1] .. "\n") end}
    local fol = lb.aifol ~= "0"     -- §354（存在 AI 装备里：netcfg aifol=，命令 aiload fol=）
    items[#items + 1] = {label = T("AI跟随行动：", "AI FOLLOWS YOU: ") .. "< " .. (fol and T("开", "ON") or T("关", "OFF")) .. " >",
        act = function() ctx.command("aiload", "fol=" .. (fol and "0" or "1") .. "\n") end}
    items[#items + 1] = {label = T("AI装备设置…", "AI LOADOUT..."), act = page("aiload")}     -- §114
    if not fol then
        items[#items + 1] = {label = T("（不跟随：AI 原地不动、离多远都不瞬移过来）", "(NO FOLLOW: THE AI STAYS PUT, NEVER TELEPORTS)")}
    end
    return lv
end
function U.items(lb, items, page)
    if U.common(lb, items, page) ~= 3 then
        items[#items + 1] = {label = T("AI 特殊资源设定…", "AI RESOURCE OVERRIDES..."), act = page("training:resources")}
        items[#items + 1] = {label = T("返回", "BACK"), act = page("main")}
        return
    end
    items[#items + 1] = {label = T("重复出招…", "REPEATED MOVES..."), act = page("training:actions")}
    local hp, idx = U.hpMode(lb), 1
    for i, o in ipairs(U.HP) do if o[1] == hp then idx = i end end
    items[#items + 1] = {label = T("AI对手HP状态：", "AI HP: ") .. "< " .. T(U.HP[idx][2], U.HP[idx][3]) .. " >", act = function()
        -- 无限 HP 改不了（不是本地 AI 房主）时跳过这一档
        for k = 1, #U.HP do
            if U.setHp(lb, U.HP[(idx + k - 1) % #U.HP + 1][1]) then return end
        end
    end}
    cycle(items, lb, "trainChi", "AI对手杀气状态：", "AI CHI: ", U.CHI, "normal")
    cycle(items, lb, "trainGuard", "AI对手自动格挡状态切换：", "AI AUTO GUARD: ", U.GUARD, "none")
    onOff(items, lb, "trainDodge", "AI对手完美红光闪避：", "AI PERFECT RED DODGE: ", false)
    cycle(items, lb, "trainUlt", "AI对手精纯杀气状态：", "AI ULTIMATE CHARGES: ", U.ULT, "inf")
    cycle(items, lb, "trainSp", "AI对手暗源状态：", "AI SPIRIT SHADOW: ", U.SP, "inf")
    onOff(items, lb, "trainReturn", "AI对手自动归位：", "AI AUTO RETURN: ", true)
    -- 说明行都控制在半角 56 格以内（§398）
    if lb.trainGuard == "hold" or lb.trainGuard == "perfect" then
        items[#items + 1] = {label = T("（红光 / L1 特殊技等不可防御的招挡不住）", "(UNBLOCKABLE MOVES STILL HIT)")}
    end
    if lb.trainUlt == "normal" or lb.trainSp == "normal" then
        items[#items + 1] = {label = T("（通常：按游戏原样，用掉就没了、照常攒）", "(NORMAL: AS IN THE GAME, NO REFILL)")}
    end
    if lb.trainReturn ~= "0" then
        items[#items + 1] = {label = T("（自动归位：准备后开局那一下归位一次）", "(RETURNS ONCE WHEN THE MATCH STARTS)")}
    end
    if hp == "drain" then
        items[#items + 1] = {label = T("（HP 打空 = 判负，木桩里只是重新开局）", "(EMPTY HP = LOSS; THE DUMMY JUST RESTARTS)")}
    end
    items[#items + 1] = {label = T("返回", "BACK"), act = page("main")}
end

local function pages() return math.ceil(#actions / U.PER_PAGE) end
local function fmt(sec) return string.format("%.1f", sec) end
local function clampInterval(v)
    v = tonumber(v) or U.INTERVAL_DEFAULT
    v = math.max(U.INTERVAL_MIN, math.min(U.INTERVAL_MAX, v))
    return math.floor(v * 10 + 0.5) / 10
end
U.clampInterval = clampInterval
-- 拖动中 / 刚松手（联机程序还没回报新值）显示的间隔
function U.shownInterval(lb)
    local d = U.drag
    if d and d.v then
        local cur = clampInterval(lb.trainInterval)
        if (d.sent and (math.abs(cur - d.v) < 0.05 or clock() - d.sent > 3))
            or (not d.sent and clock() - (d.at or 0) > 0.5) then U.drag = nil         -- 拖到行外松手（没算点击）：0.5 秒后退回原值
        else return d.v end
    end
    return clampInterval(lb.trainInterval)
end
function U.actions(lb, items, page)
    if ctx.status and ctx.status() == lb.trainAction then
        items[#items + 1] = {label = T("当前武器 / 影之武装不支持所选动作", "MOVE UNAVAILABLE FOR THIS WEAPON / EDGE")}
    end
    local n = pages()
    local pg = math.max(1, math.min(U.actionPage or 1, n))
    local first, last = (pg - 1) * U.PER_PAGE + 1, math.min(pg * U.PER_PAGE, #actions)
    for i = first, last do
        local a = actions[i]
        items[#items + 1] = {label = ((lb.trainAction or "none") == a[1] and "[X] " or "[ ] ") .. T(a[2], a[3]),
            act = function() send("trainAction", a[1]) end}
    end
    items[#items + 1] = {label = T("下一页", "NEXT PAGE") .. " (" .. pg .. "/" .. n .. ")", act = function() U.actionPage = pg % n + 1 end}
    onOff(items, lb, "trainRepeat", "连续执行：", "CONTINUOUS: ", true)
    items[#items + 1] = {label = T("重复间隔：", "REPEAT INTERVAL: ") .. fmt(U.shownInterval(lb)) .. T(" 秒（点这里拖动调整）", " S (CLICK TO ADJUST)"),
        act = page("training:interval")}
    items[#items + 1] = {label = T("返回", "BACK"), act = page("training")}
end

-- 拖动条：[■■■■□□□□…] 按 0.2–8 秒的比例画；整行宽度对应 0.2–8 秒，鼠标按住左右拖、松手生效
U.BAR_CELLS = 20
function U.bar(sec)
    local k = math.floor((sec - U.INTERVAL_MIN) / (U.INTERVAL_MAX - U.INTERVAL_MIN) * U.BAR_CELLS + 0.5)
    k = math.max(0, math.min(U.BAR_CELLS, k))
    return string.rep("■", k) .. string.rep("□", U.BAR_CELLS - k)
end
local function fromFrac(f) return clampInterval(U.INTERVAL_MIN + (U.INTERVAL_MAX - U.INTERVAL_MIN) * (tonumber(f) or 0)) end
U.fromFrac = fromFrac
local function commit(v)
    v = clampInterval(v)
    U.drag = { v = v, sent = clock() }
    send("trainInterval", fmt(v))
end
U.commitInterval = commit
function U.interval(lb, items, page)
    local cur = U.shownInterval(lb)
    items[#items + 1] = {label = U.bar(cur) .. "  " .. fmt(cur) .. T(" 秒", " S"), act = function() end,
        slider = {
            drag = function(f) U.drag = { v = fromFrac(f), at = clock() } end,
            commit = function(f) commit(fromFrac(f)) end }}
    items[#items + 1] = {label = T("（按住上面一行左右拖，松手生效；0.2–8 秒）", "(DRAG THE BAR ABOVE; RELEASE TO APPLY; 0.2-8 S)")}
    for _, d in ipairs({ { -1, "-1 秒", "-1 S" }, { -0.1, "-0.1 秒", "-0.1 S" }, { 0.1, "+0.1 秒", "+0.1 S" }, { 1, "+1 秒", "+1 S" } }) do
        items[#items + 1] = {label = T(d[2], d[3]), act = function() commit(cur + d[1]) end}
    end
    items[#items + 1] = {label = T("恢复默认 2 秒", "RESET TO 2 S"), act = function() commit(U.INTERVAL_DEFAULT) end}
    items[#items + 1] = {label = T("返回", "BACK"), act = page("training:actions")}
end
return U
end
