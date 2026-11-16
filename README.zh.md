# PBZ_MP — 影之刃零联机 mod（4net 示例）

[English](README.md)

非官方的《影之刃零》（Steam 版，UE4SS）联机对战 mod：1v1、观战、多人（淘汰 / 积分 / 对决）、本地 AI 练习。
它同时是 **[4net](https://github.com/shilover/fornet) 的示例**：一个已经有玩家在用的游戏 mod，是怎么搭在 4net 上的。

> 本仓库 2026-11-16 起重新开始（旧历史已清掉）。这一版不带 Steam 相关插件、不带排位模式。
> 本项目与 S-GAME / 《影之刃零》官方无关。

## 装

看 [安装说明.txt](安装说明.txt)（English: [INSTALL.txt](INSTALL.txt)）。发布页有打好的包，不用自己编。

## 从源码编

```bat
git clone --recursive https://github.com/shilover/PBZ_MP.git
rem 已经克隆过：git submodule update --init
deploy.bat          rem 编联机程序（要 .NET 8 SDK + MSVC 生成工具）并装进游戏；游戏目录写在 game_dir.txt 第一行
```

## 这个 mod 怎么用 4net

| 4net 的层 | 在本仓库 | 内容 |
|---|---|---|
| 4net 本体 | `fornet/`（子模块） | 宿主、网络层、联机程序、大厅服务端。部署成 `Scripts\main.lua` + `fornet_lobby.dll` |
| 适配层 | `mod/PBZ_MP/games/pbz/` + `Scripts/pbz_game.lua` 等 | 调游戏对象：生成替身、放招、读写血量 / 属性、关输入、传送 |
| 玩法 mod | `mod/PBZ_MP/mods/base`、`spec`、`multi` | 基础玩法（面板、1v1、本地 AI、房间设置）、观战、多人。源文件在 `Scripts/`，`deploy.bat` 按 mod 拷到各自目录 |
| 联机程序里的游戏部分 | `mod/PBZ_MP/lobby/` | `PbzGame.cs`：游戏名、进程名、开局备份存档、版本号、**线上协议名**（`WireTag.Configure`）；`LocalAi.cs`：本地 AI 对手 |
| 大厅服务端 | `server/` | 由 `tools/gen_pbz_server.py` 从 `fornet/server` 生成，只换了协议名那一行 |

协议名：这个 mod 在换到 4net 之前就有玩家了，所以它在 `PbzGame.cs` 和服务端里把 4net 的中性名（`4N|` …）设回自己原来的（`PBZS|` …），
新旧版本、已经在跑的服务器照常互通。新游戏用 4net 的默认值就行，见 4net 的使用说明。

## 许可证

GPL-3.0（`LICENSE`）；`server/` 是 AGPL-3.0（`server/LICENSE`）。
