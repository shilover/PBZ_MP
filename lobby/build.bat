@echo off
rem Build lobby\PBZLobby.exe with the csc.exe that ships with Windows (.NET Framework 4); no Visual Studio needed.
chcp 65001 >nul
pushd "%~dp0"
"%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /platform:x64 /optimize+ /codepage:65001 /r:System.IO.Compression.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll /out:PBZLobby.exe Program.cs Transport.cs NetExtras.cs ServerLobby.cs Ranked.cs Reliable.cs LocalAi.cs GamePipe.cs NoSteam.cs
if errorlevel 1 (popd & exit /b 1)
popd
echo BUILD OK
