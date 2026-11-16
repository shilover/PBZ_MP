-- base_dstat.lua —— §342 招式伤害统计（0.34.1，用户 11-16"增加测伤木桩 AI … 并增加招式伤害统计功能"）
-- 数据来源：对方（本地 AI / 木桩 / 真人）回报的 res= 判定结果。每个结果号 = 我的一招，数是"这招累计伤害"，后几段走追加命中、数变大。
-- 记的是对方回报的完整累计数，不是对方掉了多少血：木桩剩 10 血吃 100 的招记 100（用户 11-16"伤害溢出时按计算出的完整伤害"）。
-- 只在收到结果时记（事件，不轮询）；对手换了人（昵称变了）自动清零；面板"招式伤害统计…"里看 / 写进日志 / 清零。
return function(ctx)
local out, NET = ctx.out, ctx.NET
-- §342.4 T / 颜色调用时再取：这个模块在 main.lua 末尾载入，那里看不见面板段的 local T / COL_*（是 nil，
-- 11-16 实测点"招式伤害统计"每帧报 attempt to call a nil value (upvalue 'T')、游戏卡死）。走全局 EXTCTX（同 ST.ext），测试可经 ctx 传
local function T(zh, en)
    local f = ctx.T or (EXTCTX and EXTCTX.T)
    if type(f) == "function" then return f(zh, en) end
    return zh
end
-- 颜色：EXTCTX.COL 键是小写、没有 gray，取不到用和 fornet_hud 一样的值
local COL_DEF = { ORANGE = { R = 255, G = 140, B = 40, A = 255 }, GREEN = { R = 90, G = 230, B = 110, A = 255 }, GRAY = { R = 170, G = 170, B = 170, A = 255 } }
local function col(k)
    local c = ctx.COL or (EXTCTX and EXTCTX.COL)
    return (c and (c[k] or c[k:lower()])) or COL_DEF[k]
end

local D = { PER_PAGE = 9, MAX_CASTS = 400, WIN = 5.0, CLEARED_SHOW = 1.5 }

function D.reset(why, tn)
    D.casts, D.order, D.rows, D.recent = {}, {}, {}, {}
    D.total, D.segs, D.t0, D.tLast, D.page, D.last = 0, 0, nil, nil, 1, nil
    D.opp = NET.rnm
    D.clearedAt = tn
    if why then out("§342 招式伤害统计清零（%s）", why) end
end
D.reset()

-- 技能名 → 面板上短一点的名字（GA_Hun_Long_AAB_C → Long_AAB；L1+圈 那几招带 L1+ 前缀）
function D.pretty(n)
    n = tostring(n or "?")
    n = n:gsub("^GA_Hun_", ""):gsub("^GA_GlobalActionAbilit%a*_", "L1+"):gsub("^GA_", ""):gsub("_C$", "")
    return n
end

-- 对方回报我第 atk 招命中、这招累计 v（第一次 / 追加命中都调，v 是累计值）
function D.hit(atk, v, tn)
    atk, v = tonumber(atk), tonumber(v)
    if not atk or not v or v <= 0 then return end
    if NET.rnm ~= D.opp then D.reset(string.format("对手换了：%s → %s", tostring(D.opp), tostring(NET.rnm))) end
    local c = D.casts[atk]
    if not c then
        local name = (NET.evName and NET.evName[atk]) or NET.lastMyAtk or "?"
        c = { name = name, v = 0 }
        D.casts[atk] = c
        D.order[#D.order + 1] = atk
        if #D.order > D.MAX_CASTS then D.casts[table.remove(D.order, 1)] = nil end
        local r = D.rows[name]
        if not r then r = { name = name, n = 0, total = 0, max = 0, segs = 0 }; D.rows[name] = r end
        r.n = r.n + 1
    end
    local add = v - c.v
    if add <= 0.5 then return end
    c.v = v
    local r = D.rows[c.name]
    r.total, r.segs = r.total + add, r.segs + 1
    if v > r.max then r.max = v end
    D.total, D.segs = D.total + add, D.segs + 1
    D.t0, D.tLast = D.t0 or tn, tn
    D.last = c
    D.recent[#D.recent + 1] = { t = tn, v = add }
    D.prune(tn)
end

function D.prune(tn)
    local r = D.recent
    local k = 1
    while r[k] and tn - r[k].t > D.WIN do k = k + 1 end
    if k > 1 then
        local n = {}
        for i = k, #r do n[#n + 1] = r[i] end
        D.recent = n
    end
end

-- 近 WIN 秒的 DPS：窗口里的伤害 ÷ min(WIN, 从第一下到现在)（刚开打时不被 5 秒除小）；最后一下过去 WIN 秒 = 0
function D.dpsNow(tn)
    D.prune(tn)
    if #D.recent == 0 or not D.t0 then return 0 end
    local sum = 0
    for _, x in ipairs(D.recent) do sum = sum + x.v end
    return sum / math.max(1, math.min(D.WIN, tn - D.t0))
end

-- 屏幕右侧常驻几行（只在对手是木桩时；main.lua 的对局外 / 交手提示末尾接上）。每帧都变，不写【提示】日志
function D.hudRows(tn)
    if not NET.rdummy then return nil end
    local avg = D.dps()
    local rows = {
        { l = T("木桩 DPS：", "DUMMY DPS:"), v = string.format(T("%.0f（近 %d 秒）", "%.0f (LAST %dS)"), D.dpsNow(tn), D.WIN), col = col("ORANGE"), side = true, nolog = true },
        { l = T("平均：", "AVERAGE:"), v = avg and string.format("%.0f", avg) or "-", side = true, nolog = true },
        { l = T("合计：", "TOTAL:"), v = string.format(T("%.0f（%d 招）", "%.0f (%d MOVES)"), D.total, D.casts_n()), side = true, nolog = true },
    }
    if D.last then
        rows[#rows + 1] = { l = T("上一招：", "LAST:"), v = string.format("%s %.0f", D.pretty(D.last.name), D.last.v), side = true, nolog = true }
    end
    local cleared = D.clearedAt and tn - D.clearedAt < D.CLEARED_SHOW
    rows[#rows + 1] = { c = cleared and T("已清零", "CLEARED") or T("End 清零 · Home 看每招明细", "END: RESET · HOME: PER-MOVE TABLE"),
                        col = cleared and col("GREEN") or col("GRAY"), size = 0.7, side = true, nolog = true }
    return rows
end

function D.sorted()
    local l = {}
    for _, r in pairs(D.rows) do l[#l + 1] = r end
    table.sort(l, function(a, b) if a.total ~= b.total then return a.total > b.total end return a.name < b.name end)
    return l
end

function D.casts_n()
    local n = 0
    for _, r in pairs(D.rows) do n = n + r.n end
    return n
end

function D.dps()
    if not (D.t0 and D.tLast) or D.tLast - D.t0 < 1 then return nil end
    return D.total / (D.tLast - D.t0)
end

function D.summary()
    local dps = D.dps()
    return string.format(T("共 %d 招 · 合计 %.0f%s", "%d MOVES · TOTAL %.0f%s"), D.casts_n(), D.total,
        dps and string.format(T(" · 每秒 %.0f（%.0f 秒）", " · %.0f/S (%.0fS)"), dps, D.tLast - D.t0) or "")
end

function D.rowText(r)
    return string.format(T("%s  ×%d  合计 %.0f  平均 %.0f  最高 %.0f", "%s  x%d  TOTAL %.0f  AVG %.0f  MAX %.0f"),
        D.pretty(r.name), r.n, r.total, r.total / math.max(1, r.n), r.max)
end

function D.dump()
    out("========== §342 招式伤害统计（对手 %s；%s）==========", tostring(D.opp or "?"), D.summary())
    out("  每招 = 对方回报的这招完整累计伤害（多段合在一起；溢出不截）")
    for _, r in ipairs(D.sorted()) do
        out("  %-40s ×%-3d 合计 %8.0f  平均 %7.0f  最高 %7.0f  段数 %d", r.name, r.n, r.total, r.total / math.max(1, r.n), r.max, r.segs)
    end
end

-- 面板页 "dstat"
function D.items(lb, items, toPage, flash)
    items[#items + 1] = { label = (D.opp and (T("对手：", "VS: ") .. tostring(D.opp) .. "  ") or "") .. D.summary() }
    local l = D.sorted()
    if #l == 0 then
        items[#items + 1] = { label = T("（还没有命中。打中对手后这里按招式列出伤害；多段招合成一招算）", "(NO HITS YET. MULTI-HIT MOVES COUNT AS ONE)") }
    end
    local pages = math.max(1, math.ceil(#l / D.PER_PAGE))
    D.page = math.min(math.max(D.page or 1, 1), pages)
    local from = (D.page - 1) * D.PER_PAGE
    for i = from + 1, math.min(from + D.PER_PAGE, #l) do items[#items + 1] = { label = D.rowText(l[i]) } end
    if pages > 1 then
        items[#items + 1] = { label = string.format(T("下一页（%d / %d）", "NEXT PAGE (%d / %d)"), D.page, pages),
                              act = function() D.page = D.page % pages + 1 end }
    end
    items[#items + 1] = { label = T("写进日志（mp_probe.log）", "WRITE TO THE LOG"),
                          act = function() D.dump(); if flash then flash(T("已写进日志", "WRITTEN TO THE LOG")) end end }
    items[#items + 1] = { label = T("清零（对手是木桩时面板关着按 End 也行）", "RESET (OR END WITH THE PANEL CLOSED, VS THE DUMMY)"), act = function() D.reset("面板清零") end }
    items[#items + 1] = { label = T("返回", "BACK"), act = toPage("main") }
end

-- §342.4 面板页 / 屏幕几行每帧都调：出错只记一次、这次不画，不让整帧报错卡住游戏（11-16 实测点开统计页卡死）
for _, k in ipairs({ "items", "hudRows" }) do
    local f = D[k]
    D[k] = function(...)
        local ok, r = pcall(f, ...)
        if ok then return r end
        if not D.errLogged then D.errLogged = true; out("!! §342 招式伤害统计出错（只记这一次，之后不画）：%s", tostring(r)) end
        return nil
    end
end

return D
end
