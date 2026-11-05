// §98 发布版（build.bat release）用这个代替 Steam.cs / SteamLobby.cs：不调 Steam、不载入 Steam 的 DLL。
// Modes.All 里没有 Steam 两种方式，下面这些只是让 Program.cs 里那几处分支能编译；Init 一律失败。
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
    }

    static class SteamLobby
    {
        public static ulong Mine { get { return 0; } }
        public static bool Hosting { get { return false; } }
        public static string Status = "";
        public static bool Listing { get { return false; } }
        public static Action<string> Log = delegate { };
        public static bool Host(string name) { return false; }
        public static void Update(string name, string map, bool full) { }
        public static void Join(ulong lobby) { }
        public static void Leave() { }
        public static void Refresh() { }
        public static List<string[]> Poll() { return new List<string[]>(); }
        public static ulong OwnerOf(ulong lobby) { return 0; }
        public static int Probe(Action<string> log) { log(Steam.Error); return 1; }
    }
}
