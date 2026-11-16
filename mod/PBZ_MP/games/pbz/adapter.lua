-- games\pbz\adapter.lua —— 影之刃零游戏适配层的入口（docs/FORNET_LAYERS.md L2）。
-- 适配层只做这款游戏的适配，不含任何玩法：同目录 pbz_game.lua（直接调游戏的函数）、pbz_abilities.lua（招式表）、pbz_places.lua（地名表）。
-- 宿主把本目录排在 package.path 最前，玩法 mod 照样能 require 这几个模块。
-- 对外提供服务 game：new = pbz_game 的构造函数（快路线：它还要基础联机包的 ST / NET / MATCH 表，所以由基础联机包构造；瘦身时收窄成不靠玩法状态的 SDK）。
local okG, mk = pcall(require, "pbz_game")
if not (okG and type(mk) == "function") then
    FORNET.log("!! 适配层 pbz：pbz_game.lua 载入失败：%s", tostring(mk))
    return
end
FORNET.provide("game", {
    name = "pbz",
    new = mk,
    dir = FORNET.GAME_DIR,
    abilities = function() local ok, t = pcall(require, "pbz_abilities"); return ok and t or nil end,
    places = function() local ok, t = pcall(require, "pbz_places"); return ok and t or nil end,
})
FORNET.log("适配层 pbz：服务 game 已提供（pbz_game / pbz_abilities / pbz_places）")
