@echo off
rem Build the lobby program and install the mod into the game folder.
rem Keep this file ASCII only: cmd misreads UTF-8 batch files that contain
rem multi-byte characters (lines get cut and run as commands). Explanations
rem in Chinese live in docs/DEPLOY.md.
rem Game folder: env PBZ_GAME_DIR, else first line of game_dir.txt (local, not in git).
setlocal
cd /d "%~dp0"
if "%PBZ_GAME_DIR%"=="" if exist "game_dir.txt" set /p PBZ_GAME_DIR=<"game_dir.txt"
if "%PBZ_GAME_DIR%"=="" (
  echo ERROR: game folder unknown. Create game_dir.txt with the game folder on line 1, e.g. E:\SteamLibrary\steamapps\common\PBZ , or set PBZ_GAME_DIR
  exit /b 1
)
set "MODS=%PBZ_GAME_DIR%\platform\steam\ue4ss\Mods"
set "DST=%MODS%\PBZ_MP"
if not exist "%MODS%" (
  echo ERROR: UE4SS Mods folder not found: %MODS%
  exit /b 1
)

rem fornet\ is a git submodule (github.com/shilover/fornet). A fresh clone / new worktree has it empty.
if not exist "fornet\lobby\build.bat" (
  echo ERROR: fornet\ is empty. Run: git submodule update --init
  exit /b 1
)

rem Game adapter C# (local AI, game info, PBZ wire names in PbzGame.cs) is compiled into the lobby program via FORNET_GAME_CS.
rem Without PbzGame.cs the lobby speaks the neutral 4net names and cannot talk to installed players / the PBZ lobby servers.
set "FORNET_GAME_CS=%CD%\mod\PBZ_MP\lobby\LocalAi.cs;%CD%\mod\PBZ_MP\lobby\PbzGame.cs"
set "FORNET_EXE=PBZLobby"
if not defined FORNET_DOTNET if defined PBZ_DOTNET set "FORNET_DOTNET=%PBZ_DOTNET%"
call fornet\lobby\build.bat
if errorlevel 1 exit /b 1
call fornet\lobby\aot\build_aot.bat
if errorlevel 1 exit /b 1

if not exist "%DST%\Scripts" mkdir "%DST%\Scripts"
if not exist "%DST%\net" mkdir "%DST%\net"
if not exist "%DST%\rec" mkdir "%DST%\rec"
rem Layout (docs/FORNET_LAYERS.md): Scripts\ = 4net, games\pbz\ = adapter, mods\<name>\ = gameplay mods.
rem First install of a mod (no manifest yet) gets on.txt = enabled; later deploys never touch on.txt.
if not exist "%DST%\games\pbz" mkdir "%DST%\games\pbz"
for %%M in (base spec multi) do if not exist "%DST%\mods\%%M" mkdir "%DST%\mods\%%M"
for %%M in (base spec multi) do if not exist "%DST%\mods\%%M\manifest.txt" type nul > "%DST%\mods\%%M\on.txt"

rem 4net (no UI, no gameplay)
copy /y "fornet\lua\fornet_host.lua" "%DST%\Scripts\main.lua" >nul || goto :copyfail
copy /y "fornet\lua\fornet_core.lua" "%DST%\Scripts\fornet_core.lua" >nul || goto :copyfail
copy /y "fornet\lua\fornet_net.lua" "%DST%\Scripts\fornet_net.lua" >nul || goto :copyfail
copy /y "fornet\lua\fornet_log.lua" "%DST%\Scripts\fornet_log.lua" >nul || goto :copyfail
copy /y "fornet\lua\fornet_ext.lua" "%DST%\Scripts\fornet_ext.lua" >nul || goto :copyfail
copy /y "fornet\lua\fornet_mods.lua" "%DST%\Scripts\fornet_mods.lua" >nul || goto :copyfail
for %%F in (fornet_ui fornet_hud fornet_match) do if exist "%DST%\Scripts\%%F.lua" del /f /q "%DST%\Scripts\%%F.lua" >nul 2>&1

rem Adapter: game access only
copy /y "mod\PBZ_MP\games\pbz\manifest.txt" "%DST%\games\pbz\manifest.txt" >nul || goto :copyfail
> "%DST%\games\games.txt" echo pbz
copy /y "mod\PBZ_MP\games\pbz\adapter.lua" "%DST%\games\pbz\adapter.lua" >nul || goto :copyfail
copy /y "mod\PBZ_MP\Scripts\pbz_game.lua" "%DST%\games\pbz\pbz_game.lua" >nul || goto :copyfail
copy /y "mod\PBZ_MP\Scripts\pbz_abilities.lua" "%DST%\games\pbz\pbz_abilities.lua" >nul || goto :copyfail
copy /y "mod\PBZ_MP\Scripts\pbz_places.lua" "%DST%\games\pbz\pbz_places.lua" >nul || goto :copyfail
for %%F in (main pbz_balance pbz_spec pbz_stdgear pbz_multi) do if exist "%DST%\games\pbz\%%F.lua" del /f /q "%DST%\games\pbz\%%F.lua" >nul 2>&1

rem Base package: panel + 1v1 + match framework + local AI + room settings
copy /y "mod\PBZ_MP\mods\base\manifest.txt" "%DST%\mods\base\manifest.txt" >nul || goto :copyfail
copy /y "mod\PBZ_MP\mods\base\init.lua" "%DST%\mods\base\init.lua" >nul || goto :copyfail
copy /y "mod\PBZ_MP\Scripts\main.lua" "%DST%\mods\base\main.lua" >nul || goto :copyfail
copy /y "fornet\lua\fornet_ui.lua" "%DST%\mods\base\fornet_ui.lua" >nul || goto :copyfail
copy /y "fornet\lua\fornet_hud.lua" "%DST%\mods\base\fornet_hud.lua" >nul || goto :copyfail
copy /y "fornet\lua\fornet_match.lua" "%DST%\mods\base\fornet_match.lua" >nul || goto :copyfail
copy /y "mod\PBZ_MP\Scripts\pbz_balance.lua" "%DST%\mods\base\pbz_balance.lua" >nul || goto :copyfail
copy /y "mod\PBZ_MP\Scripts\pbz_stdgear.lua" "%DST%\mods\base\pbz_stdgear.lua" >nul || goto :copyfail
rem main.lua slimming (docs/MAIN_SLIM.md): sections moved out of main.lua live in Scripts\base_*.lua and go to mods\base\
for %%F in (mod\PBZ_MP\Scripts\base_*.lua) do copy /y "%%F" "%DST%\mods\base\%%~nxF" >nul || goto :copyfail

rem Spectate / multiplayer mods
copy /y "mod\PBZ_MP\mods\spec\manifest.txt" "%DST%\mods\spec\manifest.txt" >nul || goto :copyfail
copy /y "mod\PBZ_MP\mods\spec\init.lua" "%DST%\mods\spec\init.lua" >nul || goto :copyfail
copy /y "mod\PBZ_MP\Scripts\pbz_spec.lua" "%DST%\mods\spec\pbz_spec.lua" >nul || goto :copyfail
copy /y "mod\PBZ_MP\mods\spec\PRIVACY.md" "%DST%\mods\spec\PRIVACY.md" >nul || goto :copyfail
copy /y "mod\PBZ_MP\mods\spec\PRIVACY.en.md" "%DST%\mods\spec\PRIVACY.en.md" >nul || goto :copyfail
copy /y "mod\PBZ_MP\mods\multi\manifest.txt" "%DST%\mods\multi\manifest.txt" >nul || goto :copyfail
copy /y "mod\PBZ_MP\mods\multi\init.lua" "%DST%\mods\multi\init.lua" >nul || goto :copyfail
copy /y "mod\PBZ_MP\Scripts\pbz_multi.lua" "%DST%\mods\multi\pbz_multi.lua" >nul || goto :copyfail
copy /y "mod\PBZ_MP\Scripts\pbz_duel.lua" "%DST%\mods\multi\pbz_duel.lua" >nul || goto :copyfail
copy /y "mod\PBZ_MP\mods\multi\PRIVACY.md" "%DST%\mods\multi\PRIVACY.md" >nul || goto :copyfail
copy /y "mod\PBZ_MP\mods\multi\PRIVACY.en.md" "%DST%\mods\multi\PRIVACY.en.md" >nul || goto :copyfail
rem Old-layout game scripts left in Scripts\ are removed
for %%F in (pbz_game pbz_abilities pbz_places pbz_balance pbz_spec pbz_stdgear pbz_multi pbz_duel pbz_ext) do if exist "%DST%\Scripts\%%F.lua" del /f /q "%DST%\Scripts\%%F.lua" >nul 2>&1
copy /y "mod\PBZ_MP\enabled.txt" "%DST%\enabled.txt" >nul || goto :copyfail
rem PBZLobby.exe is not deployed (test / debug only); remove an old copy
if exist "%DST%\PBZLobby.exe" del /f /q "%DST%\PBZLobby.exe" >nul 2>&1

copy /y "fornet\lobby\aot\out\dev\fornet_lobby.dll" "%DST%\fornet_lobby.dll" >nul || goto :dllfail
if exist "%DST%\pbz_lobby.dll" del /f /q "%DST%\pbz_lobby.dll" >nul 2>&1
if exist "%DST%\pbz_lobby.dll" echo WARN: old pbz_lobby.dll could not be deleted (game running?)


rem PBZ_MP loads through enabled.txt (mods.txt is optional)
if not exist "%DST%\enabled.txt" findstr /b /c:"PBZ_MP : 1" "%MODS%\mods.txt" >nul 2>&1 || if not exist "%DST%\enabled.txt" echo WARN: neither enabled.txt nor "PBZ_MP : 1" in mods.txt, UE4SS may not load the mod
echo DEPLOY OK: %DST%
exit /b 0

:copyfail
echo ERROR: copying mod files failed
exit /b 2
:dllfail
exit /b 4
