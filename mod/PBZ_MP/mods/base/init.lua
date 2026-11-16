-- mods\base\init.lua —— 基础联机包（docs/FORNET_LAYERS.md 第 1 节）：联机面板 + 屏幕文字 + 1v1 对战 + 对局框架 + 本地 AI + 房间设置。
-- 快路线：同目录 main.lua 就是原来的影之刃零 PvP 主脚本，整块不拆；fornet_hud / fornet_ui / fornet_match（面板 / 屏幕文字 / 对局框架）和
-- pbz_balance / pbz_stdgear（平衡表 / 标准数值表）也在本目录。
-- 基础联机包是大家都往上加的底座，所以把本目录放进 package.path（其他 mod 的私有模块用 M.require，不进 package.path）。
-- 对外服务（在 main.lua 里提供）：ui（面板行 / 已装的玩法页说明）、match（对局框架实例）、pvp（1v1 的状态表 / 替身驱动）。
local M = ...
FORNET_BASE = M
package.path = M.dir .. "/?.lua;" .. package.path
local chunk, err = loadfile(M.dir .. "/main.lua")
if not chunk then error("基础联机包 main.lua 载入失败：" .. tostring(err)) end
chunk()
