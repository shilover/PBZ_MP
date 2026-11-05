# PBZ_MP —— 影之刃零 1v1 PvP 联机模组 / Phantom Blade Zero 1v1 PvP mod

> **非官方模组**，玩家自制，与 S-GAME / 《影之刃零》官方、Valve 无关。使用风险自负，建议先备份存档。
> Unofficial, fan-made. Not affiliated with S-GAME or Valve. Use at your own risk; back up your saves first.
>
> **状态：测试版（beta）。** 源码：<https://github.com/shilover/PBZ_MP>

《影之刃零》本身没有联机。这个模组让两台电脑上各自运行的单机游戏互相同步，在同一个场地里 1v1 对战。

每台电脑上是"真的你 + 对手的替身"。对手出招时，替身在你这边激活同一个技能；打没打中、有没有弹反，由挨打一方的游戏原生战斗系统判定，结果再发回给对方。

## 需要
- Steam 版《影之刃零》
- UE4SS 的**影之刃零专用版**（KintaroModding 维护）：<https://github.com/KintaroModding/ue4ss/releases/tag/v3.0.1-1195-g1ceefac8>
  下载 `phantombladezero_ue4ss_v3.0.1-1195-g1ceefac8.zip`，整个解压到 `<游戏目录>\platform\steam\`
- Windows 10 / 11（联机程序用系统自带的 .NET Framework 4）

## 安装和使用
发布包里的 `安装说明.txt` 有完整说明（安装、按键、联机、反馈问题）。简单说：
1. 把 `PBZ_MP` 文件夹放到 `<游戏目录>\platform\steam\ue4ss\Mods\`
2. 进游戏按 **Home** 打开联机面板，选连接方式，一边建房、一边加入
3. 双方按 **F1** 准备，先赢 2 回合获胜

连接方式：
| 方式 | 说明 |
|---|---|
| 服务器大厅 | 要有人架一台大厅服务器（`server/`，见下），双方在面板"设置…"里填同一个地址。先打洞直连；服务器开了中转时直连不通会走中转 |
| 局域网 | 同一个路由器下，或者用 Tailscale / ZeroTier 等虚拟局域网 |
| 本地 AI 对战 | 不联网，和电脑控制的对手打 |

可以和第三方模组 [Phantom Pact](https://github.com/yhsharaf/PhantomPact) 同时安装：它联机期间本模组自动暂停。两者是独立的项目，本模组没有使用它的代码。

## 联网和隐私
- 联机程序 `PBZLobby.exe` 随游戏在后台启动、游戏退出几秒后自己退出。它只在你联机时收发对局数据（默认 UDP 27015，局域网发现 27016），不自动更新、不访问任何网站。勾了 UPnP 时会让你的路由器转发端口；装了 Tailscale 时会读本机 Tailscale 的节点列表。
- 联机时对方能看到你的公网 IP（直连）和你填的昵称。
- 大厅服务器由玩家自己架设；架服务器的人能看到连上来的玩家的 IP 和昵称（开了中转还会经手对局数据）。见 `server/README.md`。

## 自己架大厅服务器
`server/pbz-lobby-server.mjs`，只要 Node.js 18+，不用 `npm install`：
```bash
node server/pbz-lobby-server.mjs --port 27020           # 中转默认关
node server/pbz-lobby-server.mjs --port 27020 --relay   # 打开中转（每对玩家约 50 KB/秒）
```
防火墙放行 UDP 27020。详见 [`server/README.md`](server/README.md)。

## 从源码编译
```bat
lobby\build.bat
```
得到 `lobby\PBZLobby.exe`（用 Windows 自带的 csc，不用装 Visual Studio）。发布包里的 exe 就是用这份源码这样编译的。

## 目录
| 路径 | 内容 |
|---|---|
| `mod/PBZ_MP/` | 游戏内模组（UE4SS Lua） |
| `lobby/` | 联机程序 `PBZLobby.exe` 的源码（C#） |
| `server/` | 大厅服务器（Node.js） |

## 许可证
[GPL-3.0](LICENSE)。
