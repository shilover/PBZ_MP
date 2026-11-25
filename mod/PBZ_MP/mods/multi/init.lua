-- mods\multi\init.lua —— 多人 mod（往基础联机包上加；docs/FORNET_LAYERS.md 第 7 节，L5 订阅版）。
-- 自己构造、自己挂到基础联机包发出的事件上（pbz_multi.lua 的 MP.attach）：基础联机包不再按名字调多人。
-- 用到基础联机包的服务 pvp：multiCtx（构造上下文）、setMp（登记成多人房查询口：基础联机包"在不在多人房"这类查询只问它）、panelOpen。
-- 多人 / 对决对局开打时占"对局"（4net 对局占用锁，基础联机包的 ST.mpLock）。
-- 多人房间的收包借观战的驱动（wants=spec：装了观战就排在它后面；没装观战时多人照样加载，只是出局观战没有）。
local M = ...
local mk = M.require("pbz_multi")
if type(mk) ~= "function" then error("pbz_multi.lua 没有返回构造函数") end
-- 新版 1v1 对决（pbz_duel.lua，§293）：多人底座上的玩法，跟着多人 mod 走；没有这个文件就不提供，多人照常
local okD, mkD = pcall(M.require, "pbz_duel")
if okD and type(mkD) == "function" then M.provide("duel", mkD) end
-- 同意项 mp（11-14 用户定：挂在多人 mod 上，没装多人就不问、不进隐私说明）。v2 = v1 + 对决观众那句
local MP_TEXT = {
    mp = { ver = 2,
        zh = { "多人房间里，你会和房里每一位玩家直接互连，所以房里所有玩家（不只是房主）都能看到你的 IP 地址。不想让别人看到：在联机面板的系统设置里开\"多人房隐藏我的 IP\"（服务器大厅），这样只有房主知道，你和其他人之间的包经房主转发（延迟会高一些；房主换人时新房主会知道）。经桥接方式连接时见桥接扩展包的说明。",
               "对决模式里你上场时，你的对局数据（位置、出招、血量 / 杀气、装备外观、快捷语）会经转发机发给房里的观众。" },
        en = { "In a multiplayer room you connect directly to every other player, so everyone in the room (not just the host) can see your IP address. To prevent this, turn on \"Multiplayer: hide my IP\" in the online panel's system settings (lobby server): only the host knows it and your traffic to the others goes through the host (higher latency; a new host learns it if the host changes). Over a bridge, see the bridge extension's notice.",
               "In duel mode, while you are playing, your match data (position, moves, health / energy, outfit, quick phrases) is forwarded to the spectators in the room." } },
}
local MP_PRIVACY_TITLE = { mp = { "多人房间", "Multiplayer rooms" } }
local UIS = M.use("ui")
if UIS and UIS.addConsent then UIS.addConsent({ key = "mp", title = MP_PRIVACY_TITLE.mp, text = MP_TEXT.mp }, M.name) end
local P = M.use("pvp")
if not (P and P.multiCtx and P.setMp) then error("基础联机包没有提供 pvp.multiCtx（版本对不上？）") end
local MP = mk(P.multiCtx())
if not MP then error("多人构造失败") end
P.setMp(MP)     -- 登记成基础联机包的多人房查询口（BASEHOOK.mp）
-- 11-17 多人房 / 对决的观战借观战 mod 的镜头（侧面 / 跟 A / 跟 B / 自由视角）；没装观战就只有多人房自己的跟随镜头
do local ok, SPM = pcall(M.use, "spec"); if ok and type(SPM) == "table" and SPM.extCam then MP.specCam = SPM.extCam end end
-- §309 房间成员单独一页（房间面板里只留一行入口；以前直接列，房主面板 3 人以上挤掉"房间设置… / 系统设置…"）
if UIS and UIS.addPage and UIS.go then
    MP.membersPage = UIS.addPage({ id = "members", title = "房间成员", titleEn = "ROOM MEMBERS", back = "main", room = true,     -- 11-15 room：房间里的页，不列进"已装的玩法"
                                   build = function(items, T, lb, page) MP.memberRows(items, T) end }, M.name)
    MP.rulesPage = UIS.addPage({ id = "rules", title = "玩法设置", titleEn = "GAME MODE", back = "main", room = true,     -- 11-15 玩法相关的设置单独一页
                                 build = function(items, T, lb, page) MP.rulesRows(items, T) end }, M.name)
    MP.resourcesPage = UIS.addPage({ id = "resources", title = "成员特殊资源", titleEn = "MEMBER RESOURCES", back = MP.membersPage, room = true,
        build = function(items)
            if MP.training then MP.training.roomItems(items, function(pid)
                MP.resourcePid = pid; UIS.go(MP.memberResourcesPage)
            end) end
        end }, M.name)
    MP.memberResourcesPage = UIS.addPage({ id = "member_resources", title = "特殊资源设定", titleEn = "SPECIAL RESOURCES", back = MP.resourcesPage, room = true,
        build = function(items)
            if MP.training then MP.training.memberItems(MP.resourcePid, items) end
        end }, M.name)
    MP.uiGo = UIS.go
end
MP.attach({ on = M.on, ask = M.on, bind = function(key, fn, label) return M.keys.bind(key, fn, label) end, panelOpen = P.panelOpen })
M.provide("multi", MP)
M.log("多人已接上（订阅 base.feedMp / wire / chat / mpRows / mapLoad / f1）")
