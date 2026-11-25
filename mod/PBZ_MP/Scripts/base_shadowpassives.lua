-- Scoped passive suppression; no shared assets or equipment data are changed.
-- snapshot must certify native granted-ability removal before any GE is removed.
local function make(ctx)
    assert(type(ctx) == "table" and type(ctx.active) == "function", "active callback required")
    local root = "/PBZCombatAsset/ActorData/Players/Hun/ShaqiWeapon/YouLongCha/UpgradeData/"
    local stems = {
        "GE_ShachiWeapon_YouLongCha_Underwater",
        "GE_ShachiWeapon_YouLongCha_UpgradeAttack_1",
        "GE_ShachiWeapon_YouLongCha_UpgradeAttack_2",
        "GE_ShachiWeapon_YouLongCha_UpgradeAttack_3",
    }
    local exact, fullPaths, paths = {}, {}, {}
    for _, name in ipairs(stems) do
        local path = root .. name .. "." .. name .. "_C"
        paths[#paths + 1] = path
        exact[path] = true
        fullPaths[path] = true
        exact[name] = true
        exact[name .. "_C"] = true
        exact["ShaqiWeapon/YouLongCha/UpgradeData/" .. name] = true
    end
    local api = { paths = paths }
    local journal, owner, map, nextAt, lastAt, lastReason = {}, nil, nil, nil, nil, nil
    local function log(reason)
        if reason ~= lastReason then
            lastReason = reason
            if ctx.out then ctx.out("11.20 shadow passives: %s", reason) end
        end
    end
    local function finite(v)
        return type(v) == "number" and v == v and v > -math.huge and v < math.huge
    end
    local function active()
        local ok, value = pcall(ctx.active)
        return ok and value == true
    end
    local function identify(actor)
        local ok, key = pcall(ctx.actorKey, actor)
        local okM, token = pcall(ctx.mapToken)
        if not ok or not okM or key == nil or key == "" or token == nil then
            journal, owner, map, nextAt, lastAt = {}, nil, nil, nil, nil
            return false
        end
        if owner ~= key or map ~= token then
            journal, owner, map, nextAt, lastAt = {}, key, token, nil, nil
        end
        return true
    end
    local function equipped(actor)
        local ok, value = pcall(ctx.equipped, actor)
        return ok and value == "YouLongCha"
    end
    local function snapshot(actor)
        local ok, snap = pcall(ctx.snapshot, actor, paths)
        if not ok or type(snap) ~= "table" or snap.complete ~= true or type(snap.effects) ~= "table" then
            log("snapshot incomplete; unchanged")
            return nil
        end
        -- Validate the whole snapshot first, so an unsafe fourth entry cannot
        -- leave the first three entries removed with only a partial snapshot.
        for _, path in ipairs(paths) do
            local e = snap.effects[path]
            if type(e) ~= "table" or type(e.active) ~= "boolean" then
                log("snapshot entry missing; unchanged")
                return nil
            end
            if e.active and (not finite(e.level) or e.level <= 0 or e.stacks ~= 1 or e.count ~= 1
                or not finite(e.duration) or e.duration >= 0 or e.inhibited ~= false
                or e.safeRemoval ~= true) then
                log("unsafe GE or granted-ability RemovalPolicy; unchanged")
                return nil
            end
        end
        return snap.effects
    end
    function api.blocked(id)
        return active() and type(id) == "string" and exact[id] == true
    end
    function api.canRemove(actor, path)
        if not active() or type(path) ~= "string" or fullPaths[path] ~= true then return false end
        if not identify(actor) then return false end
        local effects = snapshot(actor)
        return effects ~= nil and effects[path].active == true
    end
    function api.fork() return make(ctx) end
    function api.restore(actor)
        if not identify(actor) then return false end
        if active() then return false end
        if not equipped(actor) then journal = {}; return false end
        if next(journal) == nil then return true end
        local effects = snapshot(actor)
        if not effects then return false end
        local complete = true
        for _, path in ipairs(paths) do
            local saved = journal[path]
            if saved then
                local current = effects[path]
                if current.active then
                    -- Another owner already restored it: never stack or
                    -- overwrite a changed effect to force our saved level.
                    if current.level == saved.level then journal[path] = nil
                    else complete = false; log("restore conflicts with current level; retained") end
                else
                    local ok, applied = pcall(ctx.apply, actor, path, saved.level)
                    if ok and applied == true then journal[path] = nil
                    else complete = false; log("restore failed; journal retained") end
                end
            end
        end
        return complete
    end
    function api.step(actor, tn)
        if not identify(actor) or not finite(tn) then return false end
        if lastAt and tn < lastAt then nextAt = nil end
        lastAt = tn
        if nextAt and tn < nextAt then return false end
        nextAt = tn + 0.25
        if not equipped(actor) then journal = {}; return false end
        if not active() then return api.restore(actor) end
        local effects = snapshot(actor)
        if not effects then return false end
        local complete = true
        for _, path in ipairs(paths) do
            local e = effects[path]
            if e.active then
                local ok, removed = pcall(ctx.remove, actor, path)
                if ok and removed == true then
                    if not journal[path] and e.restore ~= false then journal[path] = { level = e.level } end
                else complete = false; log("remove failed; not journaled") end
            end
        end
        return complete
    end
    return api
end
return make
