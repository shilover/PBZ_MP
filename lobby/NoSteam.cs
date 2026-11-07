// §98 发布版（build.bat release）用这个代替 SteamBridge.cs：不调 Steam、不连游戏里的 Steam 桥。
// Modes.All 里没有 Steam 方式，下面这些只是让 Program.cs 里那几处分支能编译；Init 一律失败。
// Steam 大厅的空壳在 NoSteamLobby.cs（§120.11 起开发版也用它）。
using System;
using System.Collections.Generic;

namespace PbzLobby
{
    static class Steam
    {
        public static bool Ready { get { return false; } }
        public static string Error = L.T("这一版不带 Steam 联机", "This build has no Steam play");
        public static ulong MyId { get { return 0; } }
        public static string MyName = "";
        public static bool Init() { return false; }
        public static void Shutdown() { }
        public static void Pump() { }
        public static string FriendName(ulong id) { return id.ToString(); }
        public static List<string[]> FriendsInGame() { return new List<string[]>(); }
        public static int Probe(Action<string> log) { log(Error); return 1; }
        public static bool Available { get { return false; } }
        public static string LogDir = "";
        public static string SelfTestResult = null;
        public static bool SelfTest(ulong target) { return false; }
        public static int SelfTestCli(ulong target, Action<string> log) { log(Error); return 1; }
    }
}
