-- Read-only pilot. A payload snapshot is never permission to modify damage.
return function(ctx)
local P = { states = {}, logs = 0, scans = 0, nextCheck = 0, nextSample = 0,
    enabled = false, MAX_LOGS = 80, MAX_SCANS = 1200, SAMPLE_PERIOD = 0.05 }
local G, out = ctx.G, ctx.out
local ok, config
if ctx.config ~= nil then
    config, ok = ctx.config, true
else
    ok, config = pcall(require, 'base_damageparts_cfg')
    if not ok and type(ctx.configDir) == 'string' then
        ok, config = pcall(dofile, ctx.configDir .. '/base_damageparts_cfg.lua')
    end
end

function P.validate(c)
    if type(c) ~= 'table' or c.version ~= 1 or c.mode ~= 'observe' then return false end
    if type(c.assets) ~= 'table' or type(c.moves) ~= 'table' or type(c.multipliers) ~= 'table' then return false end
    for name, enabled in pairs(c.moves) do
        if type(name) ~= 'string' or not name:match('^GA_[%w_]+_C$') or enabled ~= true then return false end
    end
    for part, value in pairs(c.multipliers) do
        if type(part) ~= 'string' or type(value) ~= 'number' or not (value >= 0 and value <= 5) then return false end
    end
    for bd, rule in pairs(c.assets) do
        if type(bd) ~= 'string' or not bd:match('^BD_[%w_]+$') or type(rule) ~= 'table'
            or type(rule.part) ~= 'string' or c.multipliers[rule.part] == nil
            or type(rule.branch) ~= 'string' then return false end
    end
    return true
end
P.config = ok and P.validate(config) and config or nil

function P.classify(record)
    if type(record) ~= 'table' then return nil, 'unknown-source' end
    if record.ownership ~= 'match' then return nil, 'owner-' .. tostring(record.ownership or 'unknown') end
    local rule = P.config and P.config.assets[record.bd]
    if not rule then return nil, 'unknown-asset' end
    return rule.part, rule.branch
end

function P.plan(snapshot, drop)
    local result = { diagnostic_only = true, executable = false, reason = 'no-event-identity', records = 0 }
    if not P.config then result.reason = 'invalid-config'; return result end
    if type(snapshot) ~= 'table' or snapshot.complete ~= true then result.reason = 'incomplete-snapshot'; return result end
    local unique, part, blocked = {}, nil, nil
    for _, r in ipairs(snapshot.records or {}) do
        local current, why = P.classify(r)
        -- Deduplicate descriptors from pre/taken phases, not actual hit events.
        local key = tostring(r.source) .. ':' .. tostring(r.bd) .. ':' .. tostring(r.ownership)
        if not unique[key] then
            unique[key] = true
            result.records = result.records + 1
            if not current then blocked = why
            elseif part and current ~= part then blocked = 'mixed-parts'
            else part = current end
            if why == 'unverified' then blocked = 'unverified-branch' end
        end
    end
    if result.records == 0 then blocked = 'no-source' end
    if blocked then result.reason = blocked; return result end
    result.part = part
    result.multiplier = P.config.multipliers[part]
    if type(drop) == 'number' and drop > 0 then result.hypothetical = drop * result.multiplier end
    return result
end

function P.reset() P.states = {} end

function P.probe(tn)
    if ctx.probe then return ctx.probe() == true end
    if tn < P.nextCheck then return P.enabled end
    P.nextCheck = tn + 1
    local f = io.open(ctx.NET_DIR .. '/part_probe.on', 'r')
    P.enabled = f ~= nil
    if f then f:close() end
    return P.enabled
end

local function fingerprint(r)
    return table.concat({ r.source or '', r.bd or '', r.ownership or '', r.actualOwner or '', tostring(r.status) }, '|')
end

function P.observe(side, victim, owner, name, tn)
    if not (P.config and P.config.moves[name]) then P.states[side] = nil; return end
    if P.scans >= P.MAX_SCANS or P.logs >= P.MAX_LOGS then return end
    P.scans = P.scans + 1
    local success, snapshot = pcall(G.damagePartSnapshot, victim, owner)
    if not success or type(snapshot) ~= 'table' then P.states[side] = nil; return end
    local hp = ctx.hpOf(victim)
    if type(hp) ~= 'number' then P.states[side] = nil; return end
    local previous = P.states[side]
    local same = previous and previous.victim == snapshot.victim and previous.owner == snapshot.owner
        and previous.name == name and tn >= previous.at and tn - previous.at <= 0.25
    local marks, changed, descriptors = {}, 0, {}
    for _, r in ipairs(snapshot.records or {}) do
        marks[r.key] = fingerprint(r)
        if same and previous.marks[r.key] ~= marks[r.key] then changed = changed + 1 end
        if #descriptors < 6 then
            descriptors[#descriptors + 1] = (r.bd ~= '' and r.bd or '?') .. '/' .. tostring(r.ownership) .. '/' .. tostring(r.phase)
        end
    end
    P.states[side] = { victim = snapshot.victim, owner = snapshot.owner, name = name, hp = hp, at = tn, marks = marks }
    local drop = same and previous.hp - hp or nil
    if P.logs >= P.MAX_LOGS or (same and changed == 0 and not (drop and drop > 0.5)) then return end
    local plan = P.plan(snapshot, drop)
    P.logs = P.logs + 1
    out('[damageparts] sample=%d side=%s move=%s hp_delta=%s snapshot=%s changed_descriptors=%d records=%d candidate=%s multiplier=%s reason=%s diagnostic_only=true executable=false [%s]',
        P.logs, side, name, drop and string.format('%.3f', drop) or 'baseline', same and 'comparable' or 'baseline',
        changed, plan.records, plan.part or '-', tostring(plan.multiplier or '-'), plan.reason, table.concat(descriptors, ' '))
end

function P.step(p1, tn)
    if not P.probe(tn) then P.reset(); return end
    if P.logs >= P.MAX_LOGS or P.scans >= P.MAX_SCANS then P.reset(); return end
    if not P.config then
        if not P.warned then out('[damageparts] disabled: invalid observe-only configuration'); P.warned = true end
        P.reset(); return
    end
    if not ctx.inScope() then P.reset(); return end
    local token = ctx.mapToken and ctx.mapToken()
    if P.mapToken ~= token then P.reset(); P.mapToken = token end
    if tn < P.nextSample and tn >= P.nextSample - P.SAMPLE_PERIOD then return end
    P.nextSample = tn + P.SAMPLE_PERIOD
    local incoming, outgoing, owner = ctx.sources()
    if owner == nil then P.reset(); return end
    P.observe('incoming', p1, owner, incoming, tn)
    P.observe('outgoing', owner, p1, outgoing, tn)
end

return P
end
