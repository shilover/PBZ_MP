-- Local AI training controls; values are acknowledged through lobby.txt.
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
    {"special", "特殊攻击", "SPECIAL"},
    {"special_hold", "特殊攻击按住", "HOLD SPECIAL"},
    {"advanced", "高级特殊攻击", "ADVANCED SPECIAL"},
    {"chi", "炽杀", "CHI KILL"},
    {"jump", "跳跃", "JUMP"}, {"jump_l", "跳跃轻攻击", "JUMP LIGHT"},
    {"jump_h", "跳跃重攻击", "JUMP HEAVY"},
}
local function send(k, v) ctx.command("aicfg", k .. "=" .. tostring(v) .. "\n") end
local function toggle(items, lb, key, zh, en, default)
    local on = lb[key] == nil and default or lb[key] == "1"
    items[#items + 1] = {label = T(zh, en) .. T(on and "开" or "关", on and "ON" or "OFF"),
        act = function() send(key, on and "0" or "1") end}
end
local function cycle(items, lb, key, zh, en, opts, default)
    local current, idx = lb[key] or default, 1
    for i, opt in ipairs(opts) do if opt[1] == current then idx = i; break end end
    items[#items + 1] = {label = T(zh, en) .. "< " .. T(opts[idx][2], opts[idx][3]) .. " >",
        act = function() send(key, opts[idx % #opts + 1][1]) end}
end
function U.items(lb, items, page)
    items[#items + 1] = {label = T("重复出招…", "REPEATED MOVES..."), act = page("training:actions")}
    items[#items + 1] = {label = T("防御与闪避…", "GUARD AND DODGE..."), act = page("training:defense")}
    items[#items + 1] = {label = T("血量与杀气…", "HEALTH AND CHI..."), act = page("training:health")}
    toggle(items, lb, "trainReturn", "自动归位：", "AUTO RETURN: ", true)
    items[#items + 1] = {label = T("返回", "BACK"), act = page("main")}
end
function U.actions(lb, items, page)
    if ctx.status and ctx.status() == lb.trainAction then
        items[#items + 1] = {label = T("当前武器不支持所选动作", "MOVE UNAVAILABLE FOR THIS WEAPON")}
    end
    local pg = U.actionPage or 1
    local first, last = pg == 1 and 1 or 14, pg == 1 and 13 or #actions
    for i = first, last do
        local a = actions[i]
        items[#items + 1] = {label = ((lb.trainAction or "none") == a[1] and "[X] " or "[ ] ") .. T(a[2], a[3]),
            act = function() send("trainAction", a[1]) end}
    end
    items[#items + 1] = {label = T("下一页", "NEXT PAGE") .. " (" .. pg .. "/2)", act = function() U.actionPage = pg == 1 and 2 or 1 end}
    toggle(items, lb, "trainRepeat", "连续执行：", "CONTINUOUS: ", true)
    local sec = tonumber(lb.trainInterval) or 2
    items[#items + 1] = {label = T("重复间隔：", "REPEAT INTERVAL: ") .. sec .. T(" 秒", " S"), act = function()
        local opts, nextSec = {0.5, 1, 2, 3, 5, 8, 10, 15, 20, 30}, 0.5
        for _, v in ipairs(opts) do if v > sec then nextSec = v; break end end
        send("trainInterval", nextSec)
    end}
    items[#items + 1] = {label = T("返回", "BACK"), act = page("training")}
end
function U.defense(lb, items, page)
    cycle(items, lb, "trainGuard", "自动格挡：", "AUTO GUARD: ", {
        {"none", "关闭", "OFF"}, {"hold", "普通格挡（按住）", "HOLD GUARD"}, {"perfect", "完美招架", "PERFECT PARRY"}}, "none")
    toggle(items, lb, "trainDodge", "完美红光闪避：", "PERFECT RED DODGE: ", false)
    if lb.trainGuard == "hold" then          -- 用户 11-23"普通格挡开了就无敌"：讲清楚什么时候挡不住
        items[#items + 1] = {label = T("杀气被打空会破防；红光招挡不住；杀气锁满/无限时不破",
            "EMPTY CHI BREAKS GUARD; RED HITS; LOCKED CHI WON'T")}
    end
    items[#items + 1] = {label = T("返回", "BACK"), act = page("training")}
end
function U.health(lb, items, page)
    toggle(items, lb, "trainHpRegen", "脱战自动回血：", "AUTO HEALTH RECOVERY: ", true)
    cycle(items, lb, "trainChi", "杀气状态：", "CHI MODE: ", {
        {"normal", "通常", "NORMAL"}, {"empty", "清空（破防）", "EMPTY (GUARD BREAK)"},
        {"locked", "无限且不减少", "LOCKED FULL"}, {"refill", "正常扣损，脱战回满", "DELAYED REFILL"}}, "normal")
    items[#items + 1] = {label = T("返回", "BACK"), act = page("training")}
end
return U
end
