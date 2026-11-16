# PBZ_MP — online-play mod for Phantom Blade Zero (a 4net example)

[中文](README.zh.md)

An unofficial online-play mod for Phantom Blade Zero (Steam, UE4SS): 1v1, spectating, multiplayer (elimination / points / duel), local AI practice.
It is also an **example for [4net](https://github.com/shilover/fornet)**: how a mod that real players already use is built on 4net.

> This repository restarted on 2026-11-16 (old history removed). This edition has no Steam plugin and no ranked mode.
> Not affiliated with S-GAME or Phantom Blade Zero.

## Install

See [INSTALL.txt](INSTALL.txt) (中文：[安装说明.txt](安装说明.txt)). Ready-made packages are on the releases page; no need to build.

## Build from source

```bat
git clone --recursive https://github.com/shilover/PBZ_MP.git
rem already cloned: git submodule update --init
deploy.bat          rem builds the lobby helper (.NET 8 SDK + MSVC build tools) and installs into the game; game folder on line 1 of game_dir.txt
```

## How this mod uses 4net

| 4net layer | In this repository | What it is |
|---|---|---|
| 4net itself | `fornet/` (submodule) | Host, network layer, lobby helper, lobby server. Deployed as `Scripts\main.lua` + `fornet_lobby.dll` |
| Adapter | `mod/PBZ_MP/games/pbz/` + `Scripts/pbz_game.lua` etc. | Touches game objects: spawn puppets, play moves, read / write health and attributes, block input, teleport |
| Play mods | `mod/PBZ_MP/mods/base`, `spec`, `multi` | Base play (panel, 1v1, local AI, room settings), spectating, multiplayer. Sources live in `Scripts/`; `deploy.bat` copies each into its mod folder |
| The game's part of the lobby helper | `mod/PBZ_MP/lobby/` | `PbzGame.cs`: game name, process name, save backup before a match, version, **wire names** (`WireTag.Configure`); `LocalAi.cs`: local AI opponent |
| Lobby server | `server/` | Generated from `fornet/server` by `tools/gen_pbz_server.py`; only the wire-names line differs |

Wire names: this mod had players before it moved to 4net, so `PbzGame.cs` and the server set 4net's neutral names (`4N|` …) back to the
mod's original ones (`PBZS|` …), and old and new versions and running servers keep working together. A new game keeps 4net's defaults
(see 4net's usage guide).

## License

GPL-3.0 (`LICENSE`); `server/` is AGPL-3.0 (`server/LICENSE`).
