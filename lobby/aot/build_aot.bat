@echo off
rem Build lobby\aot\out\pbz_lobby.dll: the online helper as a NativeAOT native DLL that main.lua loads inside the game.
rem Needs the .NET 8 SDK and the MSVC build tools (C++ workload: NativeAOT links with link.exe and the Windows SDK).
chcp 65001 >nul
pushd "%~dp0"
set "PATH=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer;%PATH%"
dotnet publish PBZLobbyAot.csproj -c Release -nologo -v q -o out || (popd & exit /b 1)
del /q out\*.pdb 2>nul
popd
echo BUILD AOT OK
