// §122 pbz_lobby.dll 的入口：游戏里的 Lua 用 package.loadlib(dll, "pbz_lobby_start") 拿到这个导出函数再调用（main.lua 的 netuiLaunch）。
// 它的签名和 Lua 的 C 函数一样（int f(lua_State*)），但我们不碰 lua_State，也就不需要 Lua 的 C 接口、不碰 UE4SS 内部：
// 只起一个后台线程，跑和 `PBZLobby.exe --bg` 完全一样的流程（Program.Main2），返回 0（Lua 那边拿不到返回值）。
// 已经在跑时再调用什么也不做；那个线程结束了（面板"退出"、出错）再调用就重新起。
// 另一个 PBZLobby.exe 已经开着（同一个 net 目录的单实例锁）时 Main2 直接返回，由 exe 继续服务。
// 规矩：这个线程和联机程序里每个后台线程的入口都兜住异常（Safe / Headless 的 Application.Guard），只记 net\lobby_errors.log。
using System;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;

namespace PbzLobby
{
    static unsafe class AotEntry
    {
        static int running;

        [DllImport("kernel32", SetLastError = true)] static extern bool GetModuleHandleExW(uint flags, IntPtr addr, out IntPtr module);
        [DllImport("kernel32", CharSet = CharSet.Unicode)] static extern uint GetModuleFileNameW(IntPtr module, char* buf, uint size);

        // 这个 DLL 自己所在的目录（AppContext.BaseDirectory 在游戏进程里给的是游戏 exe 的目录）
        static string MyDir()
        {
            IntPtr mod;
            delegate* unmanaged[Cdecl]<IntPtr, int> self = &Start;
            if (!GetModuleHandleExW(6 /* FROM_ADDRESS | UNCHANGED_REFCOUNT */, (IntPtr)self, out mod)) return AppContext.BaseDirectory;
            char* buf = stackalloc char[1024];
            uint n = GetModuleFileNameW(mod, buf, 1024);
            return Path.GetDirectoryName(new string(buf, 0, (int)n)) + Path.DirectorySeparatorChar;
        }

        [UnmanagedCallersOnly(EntryPoint = "pbz_lobby_start", CallConvs = new[] { typeof(CallConvCdecl) })]
        static int Start(IntPtr luaState)
        {
            try
            {
                if (Interlocked.CompareExchange(ref running, 1, 0) != 0) return 0;
                string dir = MyDir();
                var t = new Thread(() => Run(dir)) { IsBackground = true, Name = "pbz_lobby" };
                t.Start();
            }
            catch (Exception) { running = 0; }
            return 0;
        }

        static void Run(string dir)
        {
            string errLog = Path.Combine(dir, "net", "lobby_errors.log");
            Action<string> err = m =>
            {
                try { Directory.CreateDirectory(Path.GetDirectoryName(errLog)); File.AppendAllText(errLog, DateTime.Now.ToString("MM-dd HH:mm:ss.fff ") + m + "\r\n", Kv.Utf8); }
                catch (Exception) { }
            };
            try
            {
                Program.BaseDir = dir;
                NetLog.Build = "DLL（游戏进程里）";     // §130 net_conn.log 里写
                Safe.OnError = (where, ex) => err("[" + where + "] " + ex);
                System.Windows.Forms.Application.ThreadException += ex => err("[loop] " + ex);
                System.Windows.Forms.Application.Notice += m => err("[notice] " + m);
                WinTimer.Begin();
                try { Program.Main2(new[] { "--bg" }); }
                finally { WinTimer.End(); }
            }
            catch (Exception ex) { err("[main] " + ex); }
            finally { running = 0; }
        }
    }
}
