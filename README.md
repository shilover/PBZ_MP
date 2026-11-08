# PBZ_MP —— 影之刃零 1v1 PvP 联机模组 / Phantom Blade Zero 1v1 PvP mod

> **非官方模组**，玩家自制，与 S-GAME / 《影之刃零》官方、Valve 无关。使用风险自负，建议先备份存档。
> Unofficial, fan-made. Not affiliated with S-GAME or Valve. Use at your own risk; back up your saves first.
>
> **状态：测试版（beta）。/ Status: beta.** 源码 / Source: <https://github.com/shilover/PBZ_MP>
>
> 下载 / Download: **Nexus Mods** <https://www.nexusmods.com/phantombladezero/mods/591> · [GitHub Releases](https://github.com/shilover/PBZ_MP/releases)

[中文](#中文) | [English](#english)

## 中文

《影之刃零》本身没有联机。这个模组让两台电脑上各自运行的单机游戏互相同步，在同一个场地里 1v1 对战。

每台电脑上是"真的你 + 对手的替身"。对手出招时，替身在你这边激活同一个技能；打没打中、有没有弹反，由挨打一方的游戏原生战斗系统判定，结果再发回给对方。

### 需要
- Steam 版《影之刃零》
- UE4SS 的**影之刃零专用版**，下面两个都可以：
  - **Nexus 版**（测过 1.0.3）：<https://www.nexusmods.com/phantombladezero/mods/5>
  - **KintaroModding 版**：<https://github.com/KintaroModding/ue4ss/releases/tag/v3.0.1-1195-g1ceefac8>，下载 `phantombladezero_ue4ss_v3.0.1-1195-g1ceefac8.zip`（同一页上的 `UE4SS_*.zip` 是通用版，别下错）

  整个解压到 `<游戏目录>\platform\steam\`，解压后应该有 `dwmapi.dll` 和 `ue4ss\` 文件夹
- Windows 10 / 11（联机程序用系统自带的 .NET Framework 4）

### 安装和使用
发布包里的 `安装说明.txt` 有完整说明（安装、按键、联机、反馈问题）。简单说：
1. 把 `PBZ_MP` 文件夹放到 `<游戏目录>\platform\steam\ue4ss\Mods\`
2. 进游戏按 **Home** 打开联机面板，选连接方式，一边建房、一边加入
3. 双方按 **F1** 准备，先赢 2 回合获胜

连接方式：
| 方式 | 说明 |
|---|---|
| 服务器大厅 | 要有人架一台大厅服务器（`server/`，见下），双方在面板"设置…"里填同一个地址。先打洞直连；直连不通时，服务器开了中转、并且双方都在设置里允许"直连不通时用服务器中转"（默认不用），才走中转。校园网 / 公司网等受限网络往往进不来、也走不通中转：在这类网络的一方请让对方建房、自己去加入 |
| 局域网 | 同一个路由器下，或者用 Tailscale / ZeroTier 等虚拟局域网 |
| 本地 AI 对战 | 不联网，和电脑控制的对手打 |

可以和第三方模组 [Phantom Pact](https://github.com/yhsharaf/PhantomPact) 同时安装：它联机期间本模组自动暂停。两者是独立的项目，本模组没有使用它的代码。

### 联网和隐私
- 联机程序 `pbz_lobby.dll` 由模组在游戏里载入，在游戏进程里运行（不另开程序），随游戏一起退出。它只在你联机时收发对局数据（默认 UDP 27015，局域网发现 27016），不自动更新、不访问任何网站。勾了 UPnP 时会让你的路由器转发端口；装了 Tailscale 时会读本机 Tailscale 的节点列表。
- 联机时对方能看到你的公网 IP（直连）和你填的昵称。
- 大厅服务器由玩家自己架设；架服务器的人能看到连上来的玩家的 IP 和昵称（开了中转还会经手对局数据）。见 `server/README.md`。

### 自己架大厅服务器
`server/pbz-lobby-server.mjs`，只要 Node.js 18+，不用 `npm install`：
```bash
node server/pbz-lobby-server.mjs --port 27020           # 中转默认关
node server/pbz-lobby-server.mjs --port 27020 --relay   # 打开中转（每对玩家约 50 KB/秒）
```
防火墙放行 UDP 27020。详见 [`server/README.md`](server/README.md)。

### 从源码编译
```bat
lobby\aot\build_aot.bat
```
得到 `lobby\aot\out\pbz_lobby.dll`（NativeAOT 原生 DLL，玩家不用装 .NET）。要 .NET 8 SDK 和 MSVC 生成工具（Visual Studio Build Tools 的"使用 C++ 的桌面开发"，NativeAOT 链接要用）。发布包里的 DLL 就是用这份源码这样编译的。

同一份源码也能用 Windows 自带的 csc 编成独立的 `PBZLobby.exe`（`lobby\build.bat`，不用装任何东西）：模组目录里没有 DLL、或 DLL 载不进来时，模组会改用这个 exe。

### 目录
| 路径 | 内容 |
|---|---|
| `mod/PBZ_MP/` | 游戏内模组（UE4SS Lua） |
| `lobby/` | 联机程序的源码（C#）；`lobby/aot/` 把它编成 `pbz_lobby.dll` |
| `server/` | 大厅服务器（Node.js） |

### 感谢
参与测试并反馈了 bug 的玩家（B 站）：

- 成步堂芦苇
- 谦逊的刘恒宇
- 亦如黎明中的花朵_
- 絡訸
- 化境
- 一一清风以及他的小伙伴们

### 许可证
[GPL-3.0](LICENSE)；大厅服务器 `server/` 单独用 [AGPL-3.0](server/LICENSE)（改过的服务端对外提供服务，要向玩家提供源码）。

## English

Phantom Blade Zero has no multiplayer. This mod syncs two copies of the single-player game running on two PCs, so the two players can duel 1v1 in the same arena.

Each PC shows the real you plus a puppet of your opponent. When the opponent attacks, the puppet activates the same skill on your side. Whether a hit lands or gets parried is decided by the defending player's own game, using the game's native combat, and the result is sent back to the other side.

### Requirements
- Phantom Blade Zero (Steam)
- **UE4SS for Phantom Blade Zero** – either of these works:
  - **Nexus version** (tested with 1.0.3): <https://www.nexusmods.com/phantombladezero/mods/5>
  - **KintaroModding build**: <https://github.com/KintaroModding/ue4ss/releases/tag/v3.0.1-1195-g1ceefac8> – download `phantombladezero_ue4ss_v3.0.1-1195-g1ceefac8.zip` (the generic `UE4SS_*.zip` on the same page is the wrong file)

  Extract all of it into `<game folder>\platform\steam\`. You should then have `dwmapi.dll` and a `ue4ss\` folder there.
- Windows 10 / 11. The helper program uses the .NET Framework 4 that ships with Windows; nothing else to install.

To find `<game folder>`: in your Steam library, right-click Phantom Blade Zero → Manage → Browse local files.

### Install
1. Put the `PBZ_MP` folder into `<game folder>\platform\steam\ue4ss\Mods\`. You should have:
   - `Mods\PBZ_MP\Scripts\` (four `.lua` files)
   - `Mods\PBZ_MP\enabled.txt`
   - `Mods\PBZ_MP\pbz_lobby.dll` (the online helper, loaded inside the game)
   - empty folders `Mods\PBZ_MP\net\` and `Mods\PBZ_MP\rec\`
2. UE4SS loads the mod because of `enabled.txt`. To be safe you can also add the line `PBZ_MP : 1` to `Mods\mods.txt`.
3. Updating: just overwrite. `net\` and `rec\` hold your settings and recordings; keep them.

Uninstall: delete `Mods\PBZ_MP` (and the `mods.txt` line if you added it).

### How to play
1. Both players start the game and load a save. Different maps are fine: once connected, the guest can jump to the host's map (press **F1** twice, or use the button in the panel; this autosaves first).
2. Press **Home** in game to open the online panel. It shows a mouse cursor and every button is clickable. The online helper `pbz_lobby.dll` is loaded by the mod and runs inside the game process (no separate program); it stops when the game closes. The panel's Settings has a language option (中文 / English).
3. Pick the same connection method on both sides (tabs at the top of the panel):

| Method | Notes |
|---|---|
| Lobby server | Someone has to host a lobby server (`server/`, see below). Both players enter the same address in the panel's Settings; it is empty by default. The host creates a room; the guest clicks it in the room list or joins by room code. The game first tries a direct connection. If that fails, it falls back to the server's relay only when the server has relay turned on and both players allow "Use server relay if direct fails" in Settings (off by default); otherwise the host has to forward the UDP port (or tick UPnP), or both players switch to Tailscale. If the server is down, the guest can use "Join by IP" with the host's `public IP:port`. Campus / office networks often can't accept incoming connections or use the relay: the player on such a network should let the other player host and join their room. |
| LAN | Same router, or a virtual LAN such as Tailscale / ZeroTier. |
| Local AI battle | Offline, against a computer-controlled opponent (for practice). |

4. The host creates a room and shares "Copy my address / room code" with the guest. The first time you host, Windows Firewall asks for permission; allow it.
5. Once connected, the opponent appears and the guest is moved next to the host.
6. Both players press **F1** to get ready → countdown → first to win 2 rounds wins.

Optional: Settings has a match password. If both players enter the same one, every packet is signed; if they don't match, the panel tells you why.

| Key | Action |
|---|---|
| Home | Open / close the online panel (while open: Esc or Close also closes it; PgUp/PgDn to select, End to confirm) |
| Delete | In-room chat: once connected, opens a text box; Enter sends to your opponent, Esc cancels; chat shows at the lower left |
| F1 | Ready / unready. During a match, press twice within 3 seconds to forfeit |
| F2 | Save your current position as the arena center (the host's counts) |
| F6 | Hide the opponent, back to single player |
| F7 / F8 | Record your moves / have the puppet replay them (solo practice) |
| F9 | Write the current state to the log (debugging) |
| F12 | Spawn an opponent manually (testing) |

The mod does not use F3 / F4 / F5. It can be installed alongside [Phantom Pact](https://github.com/yhsharaf/PhantomPact): while Phantom Pact is connected, this mod pauses itself, and resumes after it disconnects. They are separate projects; this mod contains none of Phantom Pact's code.

### During a match
- Both players' health is locked: getting knocked down doesn't kill you, send you back to a shrine, or drop anything.
- Assassinations and executions are disabled in duels.
- Phantom Edge damage is scaled to 35% (their charged finishers are tuned for bosses and would one-shot a player otherwise).
- Your save is backed up automatically at the start of each match, to `ProjectPBZ\Saved\SaveGames\Steam\pbz-save-backups\`.

### Reporting problems
Note roughly when it happened and what you were doing, then send these files:
- `<game folder>\platform\steam\ue4ss\Mods\PBZ_MP\mp_probe.log` (the mod's log; most important)
- `<game folder>\platform\steam\ue4ss\UE4SS.log`
- If the game crashed: the newest `crash_<date>_<time>.dmp` in `<game folder>\platform\steam\ue4ss\`

### Network and privacy
- The online helper `pbz_lobby.dll` only sends and receives match data while you are playing online (UDP 27015 by default; LAN discovery uses 27016). It does not auto-update and does not contact any website. With UPnP ticked, it asks your router to forward the port. If Tailscale is installed, it reads the local Tailscale peer list.
- When playing online, your opponent can see your public IP (direct connection) and the nickname you set.
- Lobby servers are run by players. Whoever runs one can see the IP and nickname of everyone who connects, and also the match traffic if relay is on. See `server/README.md` (in Chinese).

### Hosting a lobby server
`server/pbz-lobby-server.mjs` needs only Node.js 18+; no `npm install`:
```bash
node server/pbz-lobby-server.mjs --port 27020           # relay off (default)
node server/pbz-lobby-server.mjs --port 27020 --relay   # relay on (about 50 KB/s per relayed pair)
```
Open UDP 27020 inbound in your firewall (UDP, not TCP). Relay lets players connect when their NATs block a direct connection, but almost all of the server's bandwidth goes to relayed pairs. Running the server makes you the operator of that service; follow your local laws.

### Building from source
```bat
lobby\aot\build_aot.bat
```
This produces `lobby\aot\out\pbz_lobby.dll`, a NativeAOT native DLL (players don't need .NET installed). It needs the .NET 8 SDK and the MSVC build tools (Visual Studio Build Tools, "Desktop development with C++"; NativeAOT links with them). The DLL in the release zip is built from this source exactly this way.

The same source also builds a standalone `PBZLobby.exe` with the csc.exe that ships with Windows (`lobby\build.bat`, nothing to install). If the mod folder has no DLL, or the DLL can't be loaded, the mod uses this exe instead.

### Layout
| Path | Contents |
|---|---|
| `mod/PBZ_MP/` | In-game mod (UE4SS Lua) |
| `lobby/` | Source of the online helper (C#); `lobby/aot/` builds it into `pbz_lobby.dll` |
| `server/` | Lobby server (Node.js) |

### Thanks
Players who tested the mod and reported bugs (on Bilibili):

- 成步堂芦苇
- 谦逊的刘恒宇
- 亦如黎明中的花朵_
- 絡訸
- 化境
- 一一清风以及他的小伙伴们

### License
[GPL-3.0](LICENSE). The lobby server in `server/` is licensed separately under [AGPL-3.0](server/LICENSE): if you run a modified server for others, you must offer them its source.
