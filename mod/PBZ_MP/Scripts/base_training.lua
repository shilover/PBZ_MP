-- Local-AI preferences and ephemeral, authenticated room-member resource rules.
return function(ctx)
local R = { cfg = { players = {}, ai = {} }, roster = {}, serial = 0 }
local keys = { "hp", "shachi", "ultimate", "spirit" }
local attrs = { "Health", "Shachi", "UltimateChargeCount", "SpiritShadow" }
local function scope() return ctx.scope and ctx.scope() or {} end
local function T(a, b) return ctx.T and ctx.T(a, b) or a end
local function allowed(s)
    return (s.kind == "room" or s.kind == "local_ai") and s.enabled == true and s.training == true
        and s.ranked == false and s.spectator == false and s.session ~= nil
end
local function decode(v)
    v = tonumber(v)
    if not v or v ~= math.floor(v) or v < 0 or v > 15 then return nil end
    local c = {}
    for i, k in ipairs(keys) do c[k] = math.floor(v / 2 ^ (i - 1)) % 2 == 1 end
    return c
end
local function mask(c)
    local v = 0
    for i, k in ipairs(keys) do if c and c[k] == true then v = v + 2 ^ (i - 1) end end
    return v
end
local function pidOf(v)
    local n = tonumber(v)
    if n and n > 0 and n <= 2147483647 and n == math.floor(n) then return n end
end
R.cfg.ai = decode(0)
local path = ctx.NET_DIR and (ctx.NET_DIR:gsub("[/\\]+$", "") .. "/training_resources.cfg")
function R.save()
    local f = path and io.open(path, "w")
    if not f then return false end
    f:write(string.format("trainAiRes=%d\n", mask(R.cfg.ai))); f:close(); return true
end
if path then
    local f = io.open(path, "r")
    if f then
        for line in f:lines() do
            local v = line:match("^trainAiRes=(%d+)$")
            if v then R.cfg.ai = decode(v) or R.cfg.ai end
        end
        f:close()
    end
end
function R.clearRoom()
    R.cfg.players, R.roster, R.remote, R.remoteSession, R.roomSession = {}, {}, nil, nil, nil
end
local function reconcile(s)
    if s.kind ~= "room" or s.enabled ~= true or s.training ~= true or s.ranked ~= false or s.session == nil then
        R.clearRoom(); return
    end
    if R.roomSession ~= s.session then R.clearRoom(); R.roomSession = s.session end
    local current = {}
    for _, m in ipairs(ctx.members and ctx.members() or {}) do
        local pid = pidOf(m.pid)
        if pid and not current[pid] then
            local identity = tostring(m.identity or m.generation or "") .. ":" .. tostring(m.name or pid) .. ":" .. tostring(m.isAi == true)
            local old = R.roster[pid]
            if not old or old.identity ~= identity then
                R.serial = R.serial + 1
                old = { token = R.serial, identity = identity }
                R.cfg.players[pid] = decode(0)
                if R.remote then R.remote.players[pid] = nil end
            end
            old.name, old.isAi, old.pid = tostring(m.name or pid), m.isAi == true, pid
            current[pid] = old
        end
    end
    for pid in pairs(R.roster) do
        if not current[pid] then
            R.cfg.players[pid] = nil
            if R.remote then R.remote.players[pid] = nil end
        end
    end
    R.roster = current
end
local function state()
    local s = scope(); reconcile(s); return s
end
function R.allowed() return allowed(state()) end
function R.effective()
    local s = state()
    if not allowed(s) then return nil end
    if s.kind == "local_ai" then return s.authoritative == true and { ai = R.cfg.ai, players = {} } or nil end
    if s.authoritative == true then return R.cfg end
    if s.authoritative == false and s.session == R.remoteSession then return R.remote end
end
function R.infinite(key, slot)
    local s, c = state(), R.effective()
    if not c then return false end
    if s.kind == "local_ai" then return slot == "ai" and c.ai[key] == true end
    local pid = pidOf(slot or s.localSlot)
    return pid ~= nil and R.roster[pid] ~= nil and c.players[pid] ~= nil and c.players[pid][key] == true
end
-- Used only for the real local player after room damage accounting.
function R.refillHP(actor)
    local s = state()
    if s.kind ~= "room" or not R.infinite("hp", s.localSlot) or not ctx.G.valid(actor) then return nil end
    local hp, mx = ctx.G.attrOf(actor, "Health"), ctx.G.attrOf(actor, "Health_Max")
    if type(hp) ~= "number" or type(mx) ~= "number" or hp <= 0 or mx <= 0 then return nil end
    if hp >= mx then return hp end
    if ctx.G.attrModSet(actor, "Health", mx) then return ctx.G.attrOf(actor, "Health") end
end
function R.receive(t, trustedHost)
    local s = state()
    if not allowed(s) or s.kind ~= "room" or s.authoritative ~= false or trustedHost ~= true or type(t) ~= "table" or type(t.trainMembers) ~= "string" then return false end
    local text, players, count = t.trainMembers, {}, 0
    if #text > 16384 then return false end
    if text ~= "" then
        if text:sub(-1) == "," then return false end
        for entry in (text .. ","):gmatch("(.-),") do
            local rawPid, rawMask = entry:match("^(%d+):(%d+)$")
            local pid, flags = pidOf(rawPid), decode(rawMask)
            if not pid or not flags or players[pid] or not R.roster[pid] then return false end
            players[pid], count = flags, count + 1
            if count > 512 then return false end
        end
    end
    for pid in pairs(R.roster) do if not players[pid] then return false end end
    R.remote, R.remoteSession = { players = players }, s.session
    return true
end
local function roomWire()
    local pids, entries = {}, {}
    for pid in pairs(R.roster) do pids[#pids + 1] = pid end
    table.sort(pids)
    for _, pid in ipairs(pids) do entries[#entries + 1] = string.format("%d:%d", pid, mask(R.cfg.players[pid])) end
    return "trainMembers=" .. table.concat(entries, ",") .. "\n"
end
function R.configWire()
    local s = state()
    if s.kind == "room" then return roomWire() end
    if s.kind ~= "local_ai" then return "" end
    return string.format("trainAiRes=%d\ntrainAiHp=%d\ntrainAiChi=%d\n", mask(R.cfg.ai), R.cfg.ai.hp and 1 or 0, R.cfg.ai.shachi and 1 or 0)
end
function R.wire()
    local s = state()
    if not allowed(s) or s.authoritative ~= true then return "" end
    return R.configWire()
end
function R.changed()
    local s = state()
    if s.kind == "local_ai" then
        R.save()
        if ctx.onConfig then ctx.onConfig(R.cfg, R.configWire()) end
    end
end
function R.step(tn)
    local s, c = state(), R.effective()
    if not c then return end
    if s.kind == "local_ai" and s.authoritative == true then
        local signature = tostring(s.session) .. ":" .. R.configWire()
        if signature ~= R.applied then R.applied = signature; if ctx.onConfig then ctx.onConfig(R.cfg, R.configWire()) end end
    end
    for _, a in ipairs(ctx.actors and ctx.actors() or {}) do
        local flags, ai = nil, a.kind == "ai"
        if s.kind == "local_ai" then
            if ai and s.authoritative == true then flags = c.ai end
        else
            local pid = pidOf(a.slot)
            local member = pid and R.roster[pid]
            if member and ((ai and member.isAi and ((a.owned == true and s.authoritative == true) or (a.owned == false and s.authoritative == false)))
                or (not ai and not member.isAi and pid == s.localSlot)) then flags = c.players[pid] end
        end
        if flags and ctx.G.valid(a.actor) then
            for i, key in ipairs(keys) do
                -- C# owns AI HP; only room AI need Lua to enforce their Shachi flag.
                if flags[key] and not (ai and (i == 1 or (i == 2 and s.kind ~= "room"))) and not (i == 1 and s.deferHP == true) then
                    local attr = attrs[i]
                    local cur, mx = ctx.G.attrOf(a.actor, attr), ctx.G.attrOf(a.actor, attr .. "_Max")
                    if type(cur) == "number" and type(mx) == "number" and mx > 0 and cur < mx and (i ~= 1 or cur > 0) then ctx.G.attrModSet(a.actor, attr, mx) end
                end
            end
        end
    end
end
function R.roundEnd(id, tn)
    local s = state()
    if not allowed(s) or id == nil then return false end
    local token = tostring(s.session) .. ":" .. tostring(id)
    if token == R.lastRound then return false end
    R.lastRound = token
    if ctx.DSTAT and ctx.DSTAT.finishRound then ctx.DSTAT.finishRound(token, tn) end
    return true
end
local function editable(s, kind) return allowed(s) and s.kind == kind and s.authoritative == true end
local function denied(items) items[#items + 1] = { label = T("仅非排位房主可设置", "UNRANKED HOST ONLY") } end
local function toggles(items, flags, valid)
    local labels = { T("无限HP", "INFINITE HP"), T("无限杀气", "INFINITE SHACHI"), T("无限精纯杀气", "INFINITE ULTIMATE"), T("无限暗源", "INFINITE SPIRIT SHADOW") }
    for i, key in ipairs(keys) do
        items[#items + 1] = { label = labels[i] .. ": " .. (flags[key] and T("开", "ON") or T("关", "OFF")), act = function()
            local current = valid()
            if not current then return end
            current[key] = not current[key]; R.changed()
        end }
    end
end
function R.items(lb, items, toPage, flash)
    local s = state()
    if editable(s, "local_ai") then
        local session = s.session
        toggles(items, R.cfg.ai, function() local now = state(); if editable(now, "local_ai") and now.session == session then return R.cfg.ai end end)
    else denied(items) end
    if toPage then items[#items + 1] = { label = T("返回", "BACK"), act = toPage("main") } end
end
function R.roomItems(items, selectCallback, backCallback)
    local s = state()
    if editable(s, "room") then
        local pids = {}; for pid in pairs(R.roster) do pids[#pids + 1] = pid end; table.sort(pids)
        for _, pid in ipairs(pids) do
            local m, session = R.roster[pid], s.session
            local token = m.token
            items[#items + 1] = { label = string.format("%d  %s", pid, m.name), act = function()
                local now = state(); local current = R.roster[pid]
                if editable(now, "room") and now.session == session and current and current.token == token and selectCallback then selectCallback(pid) end
            end }
        end
    else denied(items) end
    if backCallback then items[#items + 1] = { label = T("返回", "BACK"), act = backCallback } end
end
function R.memberItems(pid, items, backCallback)
    local s = state(); pid = pidOf(pid)
    local m = pid and R.roster[pid]
    if editable(s, "room") and m then
        local session, token = s.session, m.token
        items[#items + 1] = { label = string.format("%d  %s", pid, m.name) }
        toggles(items, R.cfg.players[pid], function()
            local now = state(); local current = R.roster[pid]
            if editable(now, "room") and now.session == session and current and current.token == token then return R.cfg.players[pid] end
        end)
    else denied(items) end
    if backCallback then items[#items + 1] = { label = T("返回", "BACK"), act = backCallback } end
end
return R
end
