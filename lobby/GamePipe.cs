// HANDOVER §83 / §84：游戏 ↔ 联机程序之间的交接走命名管道（内存），不再频繁读写 net\ 下的小文件。
// 起因：每秒各写 30 次 state_local.txt / state_remote.txt，读刚被换掉的文件要等杀毒扫描（平均 3.6–6.5 ms、最长 20+ ms，
// 全压在游戏线程上）；会话 / 面板状态每 0.5 秒重写一次、命令文件每 0.1 秒读一次，白白磨硬盘（用户："不要频繁读写琐碎的硬盘文件"）。
//
// 两根单向管道（Lua 的 io 库只有阻塞读写，一根双向管道在 C 运行库里读写切换不可靠）：
//   \\.\pipe\<Name>.up    游戏 → 本程序
//   \\.\pipe\<Name>.down  本程序 → 游戏
// 协议（头是 ASCII 行，长度都是 UTF-8 字节数）：
//   游戏发 "S <n>\n" + n 字节        = 本机状态包（以前的 state_local.txt）
//   游戏发 "U <文件名> <n>\n" + n 字节 = 以前游戏写的那个文件的新内容（cmd.txt、rel_out.txt）
//   游戏发 "R\n"  = 要远端状态包 + 有变化的状态文件；"B\n" = 只要有变化的状态文件
//   本程序马上回 "N <k> <m>\n" + k 个状态包（"<n>\n" + n 字节，旧到新）+ m 个文件（"<文件名> <n>\n" + n 字节，
//   以前本程序写的 session.txt、lobby.txt、rel_in.txt、lang.txt，只发上次给过之后变了的；刚连上时全给一遍）
// 游戏每次 R / B 都等回话（Lua 没有超时），所以回话只在本线程里做、不碰网络、不等别的线程。
// 游戏怎么找到管道：本程序启动时写 <dir>\pipe.txt（name=…），退出时删。连不上 / 断了，两边都退回文件交接。
//
// 文件镜像：外部工具（tests\fake_join.py 等）还要靠 lobby.txt / session.txt / cmd.txt 操控游戏。<dir>\mirror.on 存在时
// （FileSystemWatcher 盯着，不轮询），连着管道也照写这些文件。cmd.txt 也靠 FileSystemWatcher：文件变了才读，平时不读。
//
// 本地 AI（net\ai\）用 StartVirtual：同一个进程里的 LocalAi 和 AI 那个 Session 直接在内存里交接，不开管道、不写文件。
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;

namespace PbzLobby
{
    class GamePipe
    {
        const int MaxQueue = 8;      // 游戏一次没来取，最多攒这么多状态包（"最新覆盖"，太旧的丢掉）
        static readonly Dictionary<string, GamePipe> byDir = new Dictionary<string, GamePipe>();

        public readonly string Name, Dir;
        readonly bool isVirtual;
        readonly string infoFile;
        readonly Queue<string> remote = new Queue<string>();
        readonly object qLock = new object();
        readonly Dictionary<string, string> down = new Dictionary<string, string>();     // 本程序 → 游戏的文件（最新内容）
        readonly Dictionary<string, string> sent = new Dictionary<string, string>();     // 已经给过游戏的内容
        readonly Dictionary<string, string> up = new Dictionary<string, string>();       // 游戏 → 本程序的文件（最新内容）
        public readonly AutoResetEvent LocalSignal = new AutoResetEvent(false);
        volatile bool connected, stop, mirror;
        volatile string latestLocal, lastRemote;
        FileSystemWatcher watcher;
        public long LocalIn, RemoteOut, Requests, Connects, BlobsOut;
        public Action<string> Log = delegate { };
        public Action CmdFileChanged = delegate { };     // cmd.txt 被外部改了（MainForm 去读一次）

        GamePipe(string dir, string name, bool isVirtual)
        {
            Dir = dir;
            Name = name;
            this.isVirtual = isVirtual;
            infoFile = Path.Combine(dir, "pipe.txt");
        }

        static string Key(string dir) { return Path.GetFullPath(dir).TrimEnd('\\', '/').ToLowerInvariant(); }

        // 给 dir 开管道（一个目录一个；名字按目录算，测试时两个 --dir 互不干扰）
        public static GamePipe Start(string dir, string fnvOfDir)
        {
            var p = new GamePipe(dir, "PBZ_MP_" + fnvOfDir, false);
            lock (byDir) byDir[Key(dir)] = p;
            p.mirror = File.Exists(Path.Combine(dir, "mirror.on"));
            try
            {
                p.watcher = new FileSystemWatcher(dir) { NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite, IncludeSubdirectories = false };
                FileSystemEventHandler h = (s, e) => p.OnFileEvent(e.Name);
                p.watcher.Changed += h;
                p.watcher.Created += h;
                p.watcher.Deleted += h;
                p.watcher.Renamed += (s, e) => { p.OnFileEvent(e.Name); p.OnFileEvent(e.OldName); };
                p.watcher.EnableRaisingEvents = true;
            }
            catch (Exception) { }
            new Thread(p.Serve) { IsBackground = true, Name = "GamePipe" }.Start();
            try { File.WriteAllText(p.infoFile, "name=" + p.Name + "\n", Kv.Utf8); } catch (Exception) { }
            return p;
        }

        // 同一个进程里的交接（本地 AI）：不开管道，一直算"连着"，读写都在内存里
        public static GamePipe StartVirtual(string dir)
        {
            var p = new GamePipe(dir, "", true) { connected = true };
            lock (byDir) byDir[Key(dir)] = p;
            return p;
        }

        public static void Remove(string dir)
        {
            lock (byDir) byDir.Remove(Key(dir));
        }

        public static GamePipe For(string dir)
        {
            if (dir == null) return null;
            GamePipe p;
            lock (byDir) return byDir.TryGetValue(Key(dir), out p) ? p : null;
        }

        void OnFileEvent(string name)
        {
            if (name == null) return;
            if (name.Equals("mirror.on", StringComparison.OrdinalIgnoreCase))
            {
                bool m = File.Exists(Path.Combine(Dir, "mirror.on"));
                if (m != mirror) { mirror = m; Log("[管道] 文件镜像 " + (m ? "开" : "关")); }
            }
            else if (name.Equals("cmd.txt", StringComparison.OrdinalIgnoreCase)) CmdFileChanged();
        }

        public bool Connected { get { return connected; } }
        public bool Mirror { get { return mirror; } }

        // ---- 状态包
        public string LatestLocal { get { return latestLocal; } }     // 游戏最近一次发来的本机状态包（SendLoop 取）
        public string LastRemote { get { return lastRemote; } }       // 最近一个远端状态包（窗口显示对方地图用）

        // 收到的远端状态包：连着就排队等游戏来取，返回 true；没连着返回 false（调用方照旧写文件）
        public bool PushRemote(string s)
        {
            if (!connected) return false;
            lastRemote = s;
            lock (qLock)
            {
                remote.Enqueue(s);
                while (remote.Count > MaxQueue) remote.Dequeue();
            }
            return true;
        }

        // 本地 AI：取对方（游戏）最近的状态包，没有新的返回 null
        public string TakeLatestRemote()
        {
            lock (qLock)
            {
                string s = null;
                while (remote.Count > 0) s = remote.Dequeue();
                return s;
            }
        }

        // 本地 AI：AI 的状态包交给它的 Session 发出去
        public void SetLocal(string s)
        {
            latestLocal = s;
            LocalIn++;
            LocalSignal.Set();
        }

        // ---- 以前的小文件
        // 本程序要给游戏的文件（session.txt / lobby.txt / rel_in.txt / lang.txt）：内存里留最新一份，游戏来取；
        // 没连管道、或开着文件镜像，才写硬盘
        public static void Out(string path, string text)
        {
            var p = For(Path.GetDirectoryName(path));
            if (p != null)
            {
                p.SetDown(Path.GetFileName(path), text);
                if (p.connected && !p.mirror) return;
                if (p.isVirtual) return;
            }
            Kv.WriteAtomic(path, text);
        }

        // 游戏给本程序的文件（rel_out.txt）：连着管道用游戏经管道发来的；没连读文件
        public static string In(string path)
        {
            var p = For(Path.GetDirectoryName(path));
            if (p != null && p.connected)
            {
                string t;
                lock (p.qLock) return p.up.TryGetValue(Path.GetFileName(path), out t) ? t : null;
            }
            return Kv.ReadText(path);
        }

        // 游戏经管道发来的某个文件的最新内容（cmd.txt）；没有返回 null
        public string UpText(string name)
        {
            string t;
            lock (qLock) return up.TryGetValue(name, out t) ? t : null;
        }

        public void SetDown(string name, string text)
        {
            lock (qLock) down[name] = text;
        }

        public void Stop()
        {
            stop = true;
            if (watcher != null) try { watcher.Dispose(); } catch (Exception) { }
            if (!isVirtual) try { File.Delete(infoFile); } catch (Exception) { }
            Remove(Dir);
        }

        void Serve()
        {
            while (!stop)
            {
                NamedPipeServerStream pu = null, pd = null;
                try
                {
                    pu = new NamedPipeServerStream(Name + ".up", PipeDirection.In, 1, PipeTransmissionMode.Byte);
                    pd = new NamedPipeServerStream(Name + ".down", PipeDirection.Out, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                    pu.WaitForConnection();
                    // 游戏先开 .up 再开 .down；只开了一根就走了的话，别一直占着 .up 让下次连不上
                    var ar = pd.BeginWaitForConnection(null, null);
                    if (!ar.AsyncWaitHandle.WaitOne(3000)) throw new TimeoutException("游戏只连上了 .up");
                    pd.EndWaitForConnection(ar);
                    // 连上了：文件里残留的旧包作废（断开后退回文件时，不会把旧序号当成新包发出 / 读进来）；所有文件重新给一遍
                    try { File.Delete(Path.Combine(Dir, "state_local.txt")); } catch (Exception) { }
                    try { File.Delete(Path.Combine(Dir, "state_remote.txt")); } catch (Exception) { }
                    lock (qLock) { remote.Clear(); sent.Clear(); up.Clear(); }
                    connected = true;
                    Connects++;
                    Log("[管道] 游戏连上了 " + Name);
                    Talk(pu, pd);
                }
                catch (Exception ex)
                {
                    if (!stop) Log("[管道] " + ex.GetType().Name + "：" + ex.Message);
                }
                finally
                {
                    if (connected) Log("[管道] 断开，退回文件交接");
                    connected = false;
                    latestLocal = null;
                    try { if (pu != null) pu.Dispose(); } catch (Exception) { }
                    try { if (pd != null) pd.Dispose(); } catch (Exception) { }
                }
                // 断开后把内存里最新的几个文件写回硬盘：游戏退回文件交接时读得到（之后照常由 Out 写）
                if (!stop) FlushDownToDisk();
                if (!stop) Thread.Sleep(200);
            }
        }

        void FlushDownToDisk()
        {
            KeyValuePair<string, string>[] all;
            lock (qLock) { all = new KeyValuePair<string, string>[down.Count]; ((ICollection<KeyValuePair<string, string>>)down).CopyTo(all, 0); }
            foreach (var kv in all) Kv.WriteAtomic(Path.Combine(Dir, kv.Key), kv.Value);
        }

        void Talk(Stream pu, Stream pd)
        {
            var hdr = new StringBuilder();
            while (!stop)
            {
                string line = ReadLine(pu, hdr);
                if (line == null) return;                       // 游戏关了 / 模组断开
                if (line == "R" || line == "B")
                {
                    string[] list = new string[0];
                    var blobs = new List<KeyValuePair<string, string>>();
                    lock (qLock)
                    {
                        if (line == "R") { list = remote.ToArray(); remote.Clear(); }
                        foreach (var kv in down)
                        {
                            string old;
                            if (!sent.TryGetValue(kv.Key, out old) || !ReferenceEquals(old, kv.Value) && old != kv.Value)
                                blobs.Add(kv);
                        }
                        foreach (var kv in blobs) sent[kv.Key] = kv.Value;
                    }
                    var ms = new MemoryStream();
                    Put(ms, Encoding.ASCII.GetBytes("N " + list.Length + " " + blobs.Count + "\n"));
                    foreach (var s in list)
                    {
                        var body = Kv.Utf8.GetBytes(s);
                        Put(ms, Encoding.ASCII.GetBytes(body.Length + "\n"));
                        Put(ms, body);
                    }
                    foreach (var kv in blobs)
                    {
                        var body = Kv.Utf8.GetBytes(kv.Value);
                        Put(ms, Encoding.ASCII.GetBytes(kv.Key + " " + body.Length + "\n"));
                        Put(ms, body);
                    }
                    var all = ms.ToArray();
                    pd.Write(all, 0, all.Length);
                    pd.Flush();
                    Requests++;
                    RemoteOut += list.Length;
                    BlobsOut += blobs.Count;
                }
                else if (line.StartsWith("S "))
                {
                    var buf = ReadBody(pu, line.Substring(2));
                    if (buf == null) return;                    // 协议乱了：断开重来
                    latestLocal = Kv.Utf8.GetString(buf);
                    LocalIn++;
                    LocalSignal.Set();
                }
                else if (line.StartsWith("U "))
                {
                    var parts = line.Substring(2).Split(' ');
                    if (parts.Length != 2 || !SafeName(parts[0])) return;
                    var buf = ReadBody(pu, parts[1]);
                    if (buf == null) return;
                    var text = Kv.Utf8.GetString(buf);
                    lock (qLock) up[parts[0]] = text;
                }
                else return;
            }
        }

        static bool SafeName(string n)
        {
            if (n.Length == 0 || n.Length > 32) return false;
            foreach (var c in n) if (!(char.IsLetterOrDigit(c) || c == '_' || c == '.')) return false;
            return true;
        }

        static void Put(Stream s, byte[] b) { s.Write(b, 0, b.Length); }

        static byte[] ReadBody(Stream s, string lenText)
        {
            int n;
            if (!int.TryParse(lenText, out n) || n < 0 || n > 1 << 20) return null;
            var buf = new byte[n];
            int got = 0;
            while (got < n)
            {
                int k = s.Read(buf, got, n - got);
                if (k <= 0) return null;
                got += k;
            }
            return buf;
        }

        static string ReadLine(Stream s, StringBuilder sb)
        {
            sb.Length = 0;
            while (true)
            {
                int b = s.ReadByte();
                if (b < 0) return null;
                if (b == '\n') return sb.ToString().TrimEnd('\r');
                sb.Append((char)b);
                if (sb.Length > 96) return null;
            }
        }
    }
}
