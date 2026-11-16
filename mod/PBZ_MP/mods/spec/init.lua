-- mods\spec\init.lua —— 观战 mod（往基础联机包上加；docs/FORNET_LAYERS.md 第 7 节，L3 订阅版）。
-- 自己构造、自己挂到基础联机包发出的事件上（pbz_spec.lua 的 SP.attach）：基础联机包不再按名字调观战。
-- 用到基础联机包的服务 pvp：driverCtx（驱动替身 / 藏角色要的上下文）、ST（多人借观战的收包驱动，多人改成订阅前的过渡）、panelOpen / multi（换镜头键）。
-- 观战开着时占"对局"（4net 对局占用锁），基础联机包据此不挪角色、不解锁血、不显示对手血条。停用（删 on.txt）后基础联机包照常，只是没有观战。
local M = ...
local mk = M.require("pbz_spec")
if type(mk) ~= "function" then error("pbz_spec.lua 没有返回构造函数") end
-- 同意项 spec（11-14 用户定：观战 mod 自己的项；装了观战才问）：1v1 开房 / 加入 / 观战时问
local SPEC_TEXT = {
    spec = { ver = 1,
        zh = { "装了观战时，1v1 房间可以有观众：你上场对局时，房主会把你的对局数据（位置、出招、血量 / 杀气、装备外观、快捷语）和昵称转发给房里的观众；你观战时，会收到两位选手的这些数据。观众只和房主相连，看不到你的 IP 地址。" },
        en = { "With spectating installed, a 1v1 room can have spectators: while you play, the host forwards your match data (position, moves, health / energy, outfit, quick phrases) and your name to them; while you spectate, you receive this data from both players. Spectators connect only to the host and do not see your IP address." } },
}
local SPEC_PRIVACY_TITLE = { spec = { "观战", "Spectating" } }
local UIS = M.use("ui")
if UIS and UIS.addConsent then UIS.addConsent({ key = "spec", title = SPEC_PRIVACY_TITLE.spec, text = SPEC_TEXT.spec }, M.name) end
local P = M.use("pvp")
if not (P and P.driverCtx) then error("基础联机包没有提供 pvp.driverCtx（版本对不上？）") end
local SP = mk(P.driverCtx())
P.ST.spec = SP
SP.attach({ on = M.on, ask = M.on, me = M.name, activity = M.activity,
            bind = function(key, fn, label) return M.keys.bind(key, fn, label) end,
            panelOpen = P.panelOpen, multi = P.multi })
M.provide("spec", SP)
M.log("观战已接上（订阅 base.feedSrc / tick / session / mapLoad / matchOver / roomRows / roomCat.spec / navKey）")
