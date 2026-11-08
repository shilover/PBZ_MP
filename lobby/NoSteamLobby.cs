// Steam 大厅的空壳：发布版（build.bat release、AOT 不带 Steam 的那份）用它。开发版用 SteamLobby.cs（§124，经游戏里的 Steam 桥）。
// 下面这些只是让 Program.cs 里那几处分支能编译；发布版的 Modes 里没有 steamlobby。
using System;
using System.Collections.Generic;

namespace PbzLobby
{
    static class SteamLobby
    {
        public static ulong Mine { get { return 0; } }
        public static bool Hosting { get { return false; } }
        public static string Status = "";
        public static bool Listing { get { return false; } }
        public static Action<string> Log = delegate { };
        public static bool Host(string name) { return false; }
        public static volatile bool AiRoom;
        public static void Update(string name, string map, bool full) { }
        public static void Join(ulong lobby) { }
        public static void Leave() { }
        public static void Refresh() { }
        public static List<string[]> Poll() { return new List<string[]>(); }
        public static ulong OwnerOf(ulong lobby) { return 0; }
        public static int Probe(Action<string> log) { log(Steam.Error); return 1; }
    }
}
