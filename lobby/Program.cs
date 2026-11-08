// PBZ 联机窗口（替代 launcher.py：不依赖 Python，用 Windows 自带的 .NET Framework 4 编译成单个 exe）。
// 编译：build.bat（用系统自带的 csc.exe，C# 5 语法：不能用 $"" 插值、?. 这类新语法）。
//
// 游戏里的 Lua 只读写 <exe 所在目录>\net\ 下的文本文件：
//   state_local.txt   游戏写，本程序发给对方（§83 起游戏连得上命名管道时走管道，见 GamePipe.cs；这两个文件是兜底）
//   state_remote.txt  本程序收到对方的包后写，游戏读（同上）
//   pipe.txt          本程序写：管道名（name=），游戏据此连管道
//   session.txt       本程序写：role=host|client|none、connected、peer；游戏据此决定自己是主机还是客机
//   lang.txt          本程序写：lang=zh|en（窗口右上角切换），游戏据此切换屏幕提示的语言
//   lobby.txt         本程序写（每 0.5 秒）：给游戏内联机面板看的状态和可加入目标（net-ui，docs/NETWORK_UI.md §2.5）
//   cmd.txt           游戏内联机面板写：host / join / stop / mode / show，本程序按 id 执行一次
// 房间发现：主机每秒往 UDP 27016 广播 "PBZROOM|名字|端口|地图|是否已满|能观战"，加入方监听同一端口列出来。
// 第 6 段 §141 起有（"1" = 这个主机认观战连接）；旧版主机只有 5 段，满房照旧不能点
// 连接方式（net-ui）：局域网（含 Tailscale / ZeroTier，见 NetExtras.cs）、
// 服务器大厅（自建服务端登记房间 + 打洞，服务器开了中转时不通走中转，含输入 IP 直连，ServerLobby.cs）、本地 AI 对战（LocalAi.cs）。
//
// 命令行（自动化测试用）：PBZLobby.exe --host | --join IP[:端口]  [--seconds N] [--dir 目录] [--log 文件] [--no-backup]
//   --bg          后台运行（不显示窗口；游戏启动时 / 游戏内联机面板用它启动；游戏退出 3 秒后自己退出，给了 --seconds 时不自动退）
//   --sim-no-direct      服务器大厅：丢掉所有不是服务器发来的包（模拟打洞不通，测"直连 3 次失败改走中转"）
//   --secret 密码 / --port 端口      命令行模式的联机密码（窗口模式用 netcfg.txt 的 secret=）/ 主机端口（给了就不广播）
//   --sim-loss 0.3 / --sim-reorder / --sim-skew 秒   v0.22.0 测试：发出的包随机丢 / 30% 延后 20–200ms（乱序）/ 签名时间戳偏移
//   可靠事件：游戏写 net\rel_out.txt、读 net\rel_in.txt（Reliable.cs 文件头）
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Windows.Forms;   // AOT 版（pbz_lobby.dll）里是 Headless.cs 的无界面替身

namespace PbzLobby
{
    // §125 只给离线测试用：环境变量 PBZ_LOOPBACK=1 或命令行 --loopback 时所有 UDP 都只绑 127.0.0.1，
    // 防火墙就不弹"已经阻止此应用的部分功能"；局域网广播也改成发给 127.0.0.1。游戏里的 dll / 玩家开的 exe 不设，照旧绑所有网卡。
    static class NetBind
    {
        public static bool Loopback = Environment.GetEnvironmentVariable("PBZ_LOOPBACK") == "1";
        public static IPAddress Addr { get { return Loopback ? IPAddress.Loopback : IPAddress.Any; } }

        // 单播只送到同一地址上的一个 socket，所以回环下每个联机程序的局域网发现各占一个地址 127.0.0.1~8（端口都是 27016），发房间时挨个发
        public static List<IPAddress> DiscoveryAddrs()
        {
            var list = new List<IPAddress>();
            for (int k = 1; k <= 8; k++) list.Add(new IPAddress(new byte[] { 127, 0, 0, (byte)k }));
            return list;
        }

        public static UdpClient DiscoverySocket()
        {
            foreach (var a in DiscoveryAddrs())
                try { return new UdpClient(new IPEndPoint(a, Session.DiscoveryPort)); } catch (SocketException) { }
            throw new SocketException((int)SocketError.AddressAlreadyInUse);
        }
    }

    // §122 后台线程的入口一律经过这里：没接住的异常只记日志，不往外抛。
    // exe 里出事只是联机程序退出；联机程序编成 DLL 在游戏进程里跑时（pbz_lobby.dll），没接住的异常会直接结束游戏。
    static class Safe
    {
#if AOT
        public static Action<string, Exception> OnError = (w, ex) => { try { Console.Error.WriteLine("[" + w + "] " + ex); } catch (Exception) { } };
#else
        public static Action<string, Exception> OnError = delegate { };
#endif
        public static void Run(string where, Action a)
        {
            try { a(); }
            catch (ThreadAbortException) { }
            catch (Exception ex) { try { OnError(where, ex); } catch (Exception) { } }
        }
        public static Thread Thread(string name, Action a) { return new Thread(() => Run(name, a)) { IsBackground = true, Name = name }; }
        public static void Pool(string where, Action a) { ThreadPool.QueueUserWorkItem(delegate { Run(where, a); }); }
    }

    static class Kv
    {
        public static readonly Encoding Utf8 = new UTF8Encoding(false);   // 不能带 BOM，否则 Lua 读到的第一个键是乱的

        // 状态包里的昵称（nm=，Session 发包时加上）；没有就 null
        public static string NickOf(string packet)
        {
            string v;
            return Parse(packet).TryGetValue("nm", out v) && v.Trim().Length > 0 ? v.Trim() : null;
        }

        public static Dictionary<string, string> Parse(string text)
        {
            var d = new Dictionary<string, string>();
            foreach (var raw in text.Split('\n'))
            {
                var line = raw.TrimEnd('\r');
                int i = line.IndexOf('=');
                if (i > 0) d[line.Substring(0, i).Trim()] = line.Substring(i + 1).Trim();
            }
            return d;
        }

        public static string ReadText(string path)
        {
            try
            {
                using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var sr = new StreamReader(fs, Utf8))
                    return sr.ReadToEnd();
            }
            catch (Exception) { return null; }
        }

        public static Dictionary<string, string> Read(string path)
        {
            var t = ReadText(path);
            if (t == null) return null;
            var d = Parse(t);
            return d.Count > 0 ? d : null;
        }

        public static void WriteAtomic(string path, string text)
        {
            var tmp = path + ".tmp";
            try { File.WriteAllText(tmp, text, Utf8); }
            catch (Exception) { return; }
            // 游戏侧同一时刻可能正开着这个文件，Windows 会拒绝替换，重试几次
            for (int k = 0; k < 6; k++)
            {
                try
                {
                    if (File.Exists(path)) File.Replace(tmp, path, null);
                    else File.Move(tmp, path);
                    return;
                }
                catch (Exception) { Thread.Sleep(1); }
            }
            try { File.WriteAllText(path, text, Utf8); } catch (Exception) { }
            try { File.Delete(tmp); } catch (Exception) { }
        }

        public static string F(double v, string fmt) { return v.ToString(fmt, CultureInfo.InvariantCulture); }
    }

    // HANDOVER §72.10：收到的状态包排队写 state_remote.txt，Session.Run 每轮（~4ms）写一个，
    // 一批里一起到的几个包不再只留最新一个。积压超过 Max 个就丢最旧的（状态包是"最新覆盖"，不为补帧攒延迟）
    class RemoteOut
    {
        const int Max = 3;
        public volatile string Target;   // §85 等人的房间转正时从 net\wait\ 换到 net\（真人离开再换回去）
        readonly Queue<string> q = new Queue<string>();
        volatile GamePipe pipe;     // §83 游戏连着管道就交给管道，不写文件；§85 跟着 Retarget 换（只有 net\ 有管道）

        public RemoteOut(string path) { Retarget(path); }

        public void Retarget(string path) { Target = path; pipe = GamePipe.For(Path.GetDirectoryName(path)); }

        public void Push(string s)
        {
            if (pipe != null && pipe.PushRemote(s)) return;
            q.Enqueue(s);
            while (q.Count > Max) q.Dequeue();
        }

        public void Flush()
        {
            if (q.Count > 0) Kv.WriteAtomic(Target, q.Dequeue());
        }
    }

    // Windows 默认计时精度 15.6ms：Thread.Sleep(4) 实际睡 15.6ms。整个进程开 1ms 精度，退出时还原
    static class WinTimer
    {
        [System.Runtime.InteropServices.DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
        [System.Runtime.InteropServices.DllImport("winmm.dll")] static extern uint timeEndPeriod(uint ms);
        static bool on;
        public static void Begin() { try { on = timeBeginPeriod(1) == 0; } catch (Exception) { } }
        public static void End() { if (on) { on = false; try { timeEndPeriod(1); } catch (Exception) { } } }
    }

    // 一个 UDP 端点：收包只要比上一个新的序号，排队写进 state_remote.txt（RemoteOut）
    class Link : ITransport, ISpecSink, IQueueHost, IRelayHost
    {
        public readonly UdpClient Udp;
        public IPEndPoint Peer;
        readonly bool lockFirst;
        readonly RemoteOut outq;
        int lastSeq = -1;
        DateTime lastFromPeer = DateTime.MinValue;
        public long Tx, Rx, Stale, Gap;
        public double DelaySum, DelayMax;
        public long DelayN;
        public Action<string> Log = delegate { };
        public bool Diag;      // §130 写 net\net_conn.log（局域网 / 输入 IP 直连；AI 对战的回环不写）
        // §141 观战（第 2 步）。主机：握手带 spec=1 的地址记成观战者（不占对战位、不锁定），Session 把两路状态包转给它们；
        // OnPeerState = 收到对手的一个状态包（Session 加 src=c 转发）。观战者：SpecMode = 收主机转来的两路包（src=h / src=c），
        // 两路各有自己的序号，按来源分别去重
        public const int MaxSpec = 4;
        public const double SpecLost = 6.0;
        readonly Dictionary<IPEndPoint, DateTime> specs = new Dictionary<IPEndPoint, DateTime>();
        readonly List<IPEndPoint> order = new List<IPEndPoint>();     // §141.7 排队：先来的在前
        public Action<string> OnPeerState { get; set; }
        public Action<string> OnRole { get; set; }   // 观战者 / 对手：主机发来 PBZROLE（轮到你上场 / 你下场观战）
        public volatile int QPos, QLen;       // 观战者：主机发来的 PBZQ（排第几、一共几个）
        int ISpecSink.QPos { get { return QPos; } }
        int ISpecSink.QLen { get { return QLen; } }
        List<object> IQueueHost.QueueOrder() { return QueueOrder().ConvertAll(e => (object)e); }
        public bool CanPromote { get { lock (specs) foreach (var ep in order) if (specs.ContainsKey(ep) && !ep.Equals(lastDown)) return true; return false; } }
        bool IQueueHost.CanPromote { get { return CanPromote; } }
        object IQueueHost.PromoteHead() { return PromoteHead(); }
        object IQueueHost.DemotePeer() { return DemotePeer(); }
        void IQueueHost.SendTo(object who, byte[] b) { SendTo(who as IPEndPoint, b); }
        bool IQueueHost.HasPeer { get { return Peer != null; } }
        bool specMode;
        public bool SpecMode { get { return specMode; } set { specMode = value; srcSeq.Clear(); lastSeq = -1; } }
        public long SpecTx, SrcH, SrcC, SpecRefused;
        readonly Dictionary<string, int> srcSeq = new Dictionary<string, int>();

        internal static bool IsSpecHello(string s)
        {
            return s.StartsWith("PBZHELLO", StringComparison.Ordinal) && s.Contains("\nspec=1");
        }

        public int SpecCount
        {
            get
            {
                lock (specs)
                {
                    var now = DateTime.UtcNow;
                    var gone = new List<IPEndPoint>();
                    foreach (var kv in specs) if ((now - kv.Value).TotalSeconds > SpecLost) gone.Add(kv.Key);
                    foreach (var g in gone) { specs.Remove(g); order.Remove(g); Log(L.T("观战者离开：", "Spectator left: ") + g); }
                    return specs.Count;
                }
            }
        }

        // 观战者的握手 / 保活：记下（满了不收）。返回 true = 这个包是观战者的，不再往下处理
        bool NoteSpec(IPEndPoint from, string s)
        {
            bool noq = s.Contains("\nnoq=1");      // §141 只观战、不排队：在 specs 里（照样收转发），不在 order 里（不会被叫上场）
            lock (specs)
            {
                if (specs.ContainsKey(from))
                {
                    specs[from] = DateTime.UtcNow;
                    if (IsSpecHello(s))
                    {
                        if (s.Contains("\nup=1") && from.Equals(lastDown)) lastDown = null;     // §141 刚下场的人切回了排队
                        if (noq) order.Remove(from);
                        else if (!order.Contains(from)) order.Add(from);      // 改回排队：排到队尾
                    }
                    return true;
                }
                if (!IsSpecHello(s)) return false;
                if (specs.Count >= SpecCfg.Max) { SpecRefused++; return true; }     // 房间设置的上限（0 = 不让观战）
                specs[from] = DateTime.UtcNow;
                order.Remove(from);
                if (!noq) order.Add(from);
            }
            Log(L.T("观战者加入：", "Spectator joined: ") + from);
            if (Diag) NetLog.W("观战者加入：" + NetLog.Ip(from));
            return true;
        }

        // §141.7 对手位让给队首：返回顶上来的地址（没人排队 = null）。刚下场的那个跳过（自己下去观战的不会马上又被叫上来）
        IPEndPoint lastDown;
        DateTime promotedAt = DateTime.MinValue;

        // ---- §141.8 主机下场：第二位选手
        public IPEndPoint Peer2;
        int lastSeq2 = -1;
        DateTime lastFrom2 = DateTime.MinValue;
        public Action<string> OnSecondState { get; set; }
        public bool NoOut { get; set; }
        public bool HasSecond { get { return Peer2 != null; } }
        public double SinceFromSecond { get { return (DateTime.UtcNow - lastFrom2).TotalSeconds; } }
        public void SendSecond(byte[] b) { var p = Peer2; if (p != null) { Tx++; try { Udp.Send(b, b.Length, p); } catch (Exception) { } } }
        public object PromoteSecond()
        {
            IPEndPoint head = null;
            lock (specs)
            {
                var now = DateTime.UtcNow;
                foreach (var ep in order)
                    if (specs.ContainsKey(ep) && (now - specs[ep]).TotalSeconds <= SpecLost && !ep.Equals(lastDown)) { head = ep; break; }
                if (head == null) return null;
                specs.Remove(head);
                order.Remove(head);
            }
            Peer2 = head; lastSeq2 = -1; lastFrom2 = DateTime.UtcNow; lastDown = null;
            Log(L.T("第二位选手上场：", "Second player: ") + head);
            if (Diag) NetLog.W("主机下场：第二位选手 " + NetLog.Ip(head));
            return head;
        }
        public object DemoteSecond()
        {
            var old = Peer2;
            if (old == null) return null;
            lock (specs) { specs[old] = DateTime.UtcNow; order.Remove(old); order.Add(old); }
            Peer2 = null;
            lastDown = old;
            Log(L.T("第二位选手下场：", "Second player steps down: ") + old);
            return old;
        }
        public void SecondToPeer()
        {
            if (Peer2 == null) return;
            Peer = Peer2; Peer2 = null; lastSeq = -1; lastFromPeer = lastFrom2;
            Log(L.T("第二位选手改当对手：", "Second player is now the opponent: ") + Peer);
        }
        public const double PromoteGrace = 6.0;
        public IPEndPoint PromoteHead()
        {
            IPEndPoint head = null;
            lock (specs)
            {
                var now = DateTime.UtcNow;
                foreach (var ep in order)
                    if (specs.ContainsKey(ep) && (now - specs[ep]).TotalSeconds <= SpecLost && !ep.Equals(lastDown)) { head = ep; break; }
                if (head == null) return null;
                specs.Remove(head);
                order.Remove(head);
            }
            Peer = head;
            lastSeq = -1;
            lastFromPeer = DateTime.UtcNow;
            lastDown = null;
            promotedAt = DateTime.UtcNow;
            Log(L.T("队首上场：", "Next in queue plays: ") + head);
            if (Diag) NetLog.W("排队：队首上场 " + NetLog.Ip(head));
            return head;
        }

        // §141.7 打完换人：现在的对手下场，排到队尾当观战者。返回下场的地址
        public IPEndPoint DemotePeer()
        {
            var old = Peer;
            if (old == null) return null;
            lock (specs)
            {
                specs[old] = DateTime.UtcNow;
                order.Remove(old);
                order.Add(old);
            }
            Peer = null;
            lastDown = old;
            Log(L.T("对手下场观战：", "Opponent moves to spectators: ") + old);
            if (Diag) NetLog.W("排队：对手下场观战 " + NetLog.Ip(old));
            return old;
        }

        public double SinceFromPeer { get { return (DateTime.UtcNow - lastFromPeer).TotalSeconds; } }
        public bool SpecAlive(IPEndPoint ep) { lock (specs) return ep != null && specs.ContainsKey(ep); }

        // 观战者在队里的位置（1 起），给每个人发 PBZQ 用
        public List<IPEndPoint> QueueOrder()
        {
            lock (specs) return new List<IPEndPoint>(order);
        }

        public void SendTo(IPEndPoint ep, byte[] b)
        {
            if (ep == null) return;
            try { Udp.Send(b, b.Length, ep); } catch (Exception) { }
        }

        public void SendSpecs(byte[] b)
        {
            List<IPEndPoint> to;
            lock (specs) to = new List<IPEndPoint>(specs.Keys);
            foreach (var ep in to)
            {
                SpecTx++;
                try { Udp.Send(b, b.Length, ep); } catch (Exception) { }
            }
        }

        public Link(int port, IPEndPoint peer, string fRemote)
        {
            outq = new RemoteOut(fRemote);
            Peer = peer;
            lockFirst = peer == null;
            Udp = new UdpClient(new IPEndPoint(NetBind.Addr, port));
            // 对方端口还没开时 Windows 会把 ICMP 端口不可达报成下一次 Receive 的异常，关掉这个行为
            try { Udp.Client.IOControl(-1744830452, new byte[] { 0, 0, 0, 0 }, null); } catch (Exception) { }
        }

        public int LocalPort { get { return ((IPEndPoint)Udp.Client.LocalEndPoint).Port; } }
        public string PeerStr { get { var p = Peer; return p == null ? "" : p.ToString(); } }
        public string PeerName { get { return ""; } }
        public string PeerNick { get; private set; }
        long ITransport.Tx { get { return Tx; } }
        long ITransport.Gap { get { return Gap; } }
        public double PingMs { get { return DelayN > 0 ? DelaySum / DelayN * 2000 : -1; } }   // 单程估计 ×2（两边时钟不同步时不准）
        Action<string> ITransport.Log { get { return Log; } set { Log = value ?? delegate { }; } }
        Wire wire = new Wire(null);
        public Wire Wire { get { return wire; } set { wire = value ?? new Wire(null); } }
        public RemoteOut Out { get { return outq; } }
        public void Close() { try { Udp.Close(); } catch (Exception) { } }

        public void Send(byte[] b)
        {
            var p = Peer;
            if (p == null) return;
            Tx++;
            try { Udp.Send(b, b.Length, p); } catch (Exception) { }
        }

        // §130 诊断里只记包的种类，不记内容
        internal static string Head(string s)
        {
            if (s.StartsWith("PBZHELLO", StringComparison.Ordinal)) return "握手";
            if (s.StartsWith("PBZEV", StringComparison.Ordinal) || s.StartsWith("PBZACK", StringComparison.Ordinal)) return "可靠事件";
            return s.Contains("seq=") ? "状态包" : "其他";
        }

        public static double UnixNow()
        {
            return (DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
        }

        // 返回这次收到的有效状态包数
        public int Pump()
        {
            string newest = null;
            int got = 0;
            // 一批里的每个包都排队，Session.Run 每轮写一个（RemoteOut）
            while (true)
            {
                int avail;
                try { avail = Udp.Available; } catch (Exception) { break; }
                if (avail <= 0) break;
                IPEndPoint from = null;
                byte[] data;
                try { data = Udp.Receive(ref from); } catch (Exception) { break; }
                // v0.22.0：先验签再锁定对端，设了密码时伪造的包抢不走主机
                var to = from;
                var s = wire.Verify(data, 0, data.Length, b => { try { Udp.Send(b, b.Length, to); } catch (Exception) { } });
                if (s == null) continue;
                // §141.8 第二位选手的包：状态包交给 Session 转发；握手 / 可靠事件不进主机的可靠通道（它只认第一位）
                var p2 = Peer2;
                if (lockFirst && p2 != null && from.Equals(p2))
                {
                    lastFrom2 = DateTime.UtcNow;
                    if (s.StartsWith("PBZ", StringComparison.Ordinal) || s.Contains("hello=1")) continue;
                    var d2 = Kv.Parse(s);
                    string q2;
                    int sq2;
                    if (!d2.TryGetValue("seq", out q2) || !int.TryParse(q2, out sq2)) continue;
                    if (sq2 <= lastSeq2 && sq2 > lastSeq2 - 100) continue;
                    lastSeq2 = sq2;
                    var cb2 = OnSecondState;
                    if (cb2 != null) cb2(s);
                    continue;
                }
                // §141 主机：观战者的握手 / 保活不锁定、不占对战位（对手本人发来的不算）
                if (lockFirst && !from.Equals(Peer) && NoteSpec(from, s)) continue;
                // §141.7 对手自己说要下去观战（发来观战握手）：下场排到队尾
                // 刚叫上场的人在收到 PBZROLE 之前还会发几个观战握手：上场后 PromoteGrace 秒内的不算
                if (lockFirst && Peer != null && from.Equals(Peer) && IsSpecHello(s))
                {
                    if ((DateTime.UtcNow - promotedAt).TotalSeconds > PromoteGrace) { DemotePeer(); NoteSpec(from, s); }
                    continue;
                }
                // 主机：锁定第一个来的对端；对端 3 秒没动静（比如对方重开了联机窗口，端口变了）就允许换人
                if (lockFirst && (Peer == null || (!from.Equals(Peer) && (DateTime.UtcNow - lastFromPeer).TotalSeconds > 3)))
                {
                    if (Peer == null || !from.Equals(Peer))
                    {
                        Log(L.T("对端锁定为 ", "Peer locked: ") + from);
                        if (Diag) NetLog.W((Peer == null ? "对端锁定为 " : "原对端 3 秒没动静，换成 ") + NetLog.Ip(from) + "（第一个包 " + Head(s) + "）");
                    }
                    Peer = from;
                    lastSeq = -1;
                }
                if (Peer != null && !from.Equals(Peer)) continue;
                // §141.7 主机发来的换角色 / 排队位置（只认主机：观战者 / 客机的 Peer 就是主机）
                if (!lockFirst && s.StartsWith("PBZROLE", StringComparison.Ordinal))
                {
                    string rv;
                    if (Kv.Parse(s).TryGetValue("role", out rv)) { var cb = OnRole; if (cb != null) cb(rv); }
                    continue;
                }
                if (!lockFirst && s.StartsWith("PBZQ", StringComparison.Ordinal))
                {
                    var q = Kv.Parse(s);
                    string a, b2;
                    int pos, len;
                    if (q.TryGetValue("pos", out a) && int.TryParse(a, out pos)) QPos = pos;
                    if (q.TryGetValue("n", out b2) && int.TryParse(b2, out len)) QLen = len;
                    continue;
                }
                lastFromPeer = DateTime.UtcNow;
                if (wire.Control(s)) continue;     // 可靠事件 / 确认 / 握手（握手包只用来让主机知道往哪回）
                if (s.Contains("hello=1")) continue;
                var d = Kv.Parse(s);
                string seqS;
                int seq;
                if (!d.TryGetValue("seq", out seqS) || !int.TryParse(seqS, out seq)) continue;
                string src;
                if (SpecMode && d.TryGetValue("src", out src))
                {
                    // §141 观战者：主机 / 对手两路包各自的序号
                    int ls;
                    if (!srcSeq.TryGetValue(src, out ls)) ls = -1;
                    if (seq <= ls && seq > ls - 100) { Stale++; continue; }
                    if (ls >= 0 && seq > ls + 1) Gap += seq - ls - 1;
                    srcSeq[src] = seq;
                    if (src == "h") SrcH++; else SrcC++;
                }
                else
                {
                    if (seq <= lastSeq && seq > lastSeq - 100) { Stale++; continue; }   // 乱序到达的旧包；回退很多 = 对方重启了游戏
                    if (lastSeq >= 0 && seq > lastSeq + 1) Gap += seq - lastSeq - 1;
                    lastSeq = seq;
                }
                Rx++;
                got++;
                string st;
                double t;
                if (d.TryGetValue("st", out st) && double.TryParse(st, NumberStyles.Float, CultureInfo.InvariantCulture, out t))
                {
                    double delay = UnixNow() - t;
                    DelaySum += delay; DelayN++;
                    if (delay > DelayMax) DelayMax = delay;
                }
                newest = s;
                if (!NoOut) outq.Push(s);
                var fw = OnPeerState;
                if (fw != null && !SpecMode) fw(s);
            }
            outq.Flush();
            if (newest != null && !SpecMode) PeerNick = Kv.NickOf(newest) ?? PeerNick;
            return got;
        }
    }

    // 一次联机：host 监听固定端口、等第一个对端；client 用随机端口连主机。后台线程里跑
    class Session
    {
        public const int GamePort = 27015, DiscoveryPort = 27016, PollMs = 4;
        public readonly string Name, Mode;
        volatile string role;
        public string Role { get { return role; } }     // §141.7 观战者 ↔ 客机会在会话里换（轮到上场 / 下场观战）
        public readonly ITransport T;
        volatile string fLocal, fSession;
        volatile string retargetTo;     // §85 等人的房间转正：Run 线程里换目录
        readonly bool broadcast, doBackup;
        volatile bool stop;
        Thread thread, sendThread;
        readonly object sendLock = new object();   // 发包线程和主循环都会发（SimNet / 传输不保证线程安全）
        DateTime lastRx = DateTime.MinValue;
        public long RxSeen, Loops, SendLoops;   // Run / SendLoop 各转了几轮（命令行日志里算"轮询 X 次/秒"）
        public volatile string LocalMap = "?";
        public volatile string RemoteMap = "?";
        // §110 武林盟主：自己的排位 pid（发包时加 rk=，对方据此上报"和谁打的"）；null = 不是排位房间。
        // LocalMt / LocalQuit = 本机游戏状态包里的 mt= / quit=（主机看自己的 mt= 判开局 / 打完，客机看自己的 quit= 判弃权）
        public volatile string RankPid, LocalMt, LocalQuit;
        public MatchStats Stats;     // §110.11 排位房间：本机每个状态包的武器 / 影之武装 / 放招记进去
        public Action<string> Log = delegate { };
        readonly HashSet<string> backedUp = new HashSet<string>();
        public readonly Wire Wire;            // v0.22.0 包签名（Reliable.cs）
        public readonly RelChannel Rel;       // v0.22.0 可靠事件通道
        readonly SimNet sim = new SimNet();
        // §130 连接诊断（net\net_conn.log）：服务器大厅 / 输入 IP 直连 / 局域网写；Steam 有自己的 steam_conn.log，AI 对战不写
        readonly bool diag;
        DateTime startedAt, connAt = DateTime.MinValue, lostAt = DateTime.MinValue;
        bool wasConn, helloLogged;
        string lastHint = "", lastPeerApp;

        // UDP：peer = null 当主机（监听 port），否则连 peer；t 不为空时用它（Steam）。mode = steam | lan | server（server 只在"输入 IP 直连"的客机走这里）
        public Session(string role, IPEndPoint peer, string name, string dir, bool doBackup)
            : this(role, "lan", null, peer, GamePort, name, dir, doBackup, null) { }

        // secret：联机密码，空 = 不签名
        public Session(string role, string mode, ITransport t, IPEndPoint peer, int port, string name, string dir, bool doBackup, string secret)
        {
            this.role = role;
            Mode = mode;
            Name = string.IsNullOrEmpty(name) ? Environment.MachineName : name;
            fLocal = Path.Combine(dir, "state_local.txt");
            fSession = Path.Combine(dir, "session.txt");
            T = t ?? new Link(role == "host" ? port : 0, peer, Path.Combine(dir, "state_remote.txt"));
            var lk0 = T as Link;
            // §141 观战：主机把对手的包加 src=c 转给观战者；观战者（role = spec）只收不发状态包
            var ss0 = T as ISpecSink;
            if (ss0 != null && role == "host") ss0.OnPeerState = body => { if (RelayOn) RelayForward(body, true); else ForwardSpec(body, "c"); };
            var rh0 = T as IRelayHost;
            if (rh0 != null && role == "host") rh0.OnSecondState = body => { secondRx++; if (RelayOn) RelayForward(body, false); };
            if (ss0 != null && role == "spec") ss0.SpecMode = true;
            if (ss0 != null && role != "host") ss0.OnRole = r => wantRole = r;
            // 局域网 / 虚拟局域网才广播房间（广域网的朋友收不到广播；Steam 用富状态）
            // 测试给了 --lan-port（不是 27015）时不广播，免得开着的游戏的房间列表里冒出测试房间（§85.5）
            broadcast = role == "host" && mode == "lan" && port == GamePort;
            this.doBackup = doBackup;
            Wire = new Wire(secret) { SimSkewSec = Program.SimSkew };
            Rel = new RelChannel(dir, SendText);
            Wire.Rel = Rel;
            T.Wire = Wire;
            diag = mode != "ai" && !Modes.IsSteam(mode);
            var lk = T as Link;
            if (lk != null) lk.Diag = diag;
        }

        string PeerDiag
        {
            get
            {
                var sl = T as ServerLink;
                if (sl != null) return sl.PeerDiag;
                var lk = T as Link;
                return lk != null ? NetLog.Ip(lk.Peer) : "";
            }
        }

        // Session 发出的包都走这里：签名 → （测试时的坏网络）→ 传输
        void SendText(string body) { lock (sendLock) sim.Send(Wire.Seal(body), T.Send); }

        // §141 主机：一个状态包加上来源（h = 主机自己，c = 对手）签名后发给每个观战者；没有观战者不做
        // §141 主机和本地 AI 对打、同时开着等人的房间：AI 会话的两路包（主机 = h、AI = c）交给等人房间的观战者
        public volatile Session SpecRelay;
        // §141 这个会话是"AI 对战时等人的房间"：房间列表里多一行"观战 AI 对战"（局域网广播第 7 段 / 服务器 REG 第 14 段 / Steam 大厅 ai）
        public volatile bool AiWaiting;
        public void ForwardSpecFrom(string body, string src) { ForwardSpec(body, src); }

        void ForwardSpec(string body, string src)
        {
            var relay = SpecRelay;
            if (relay != null && relay != this) { relay.ForwardSpecFrom(body, src); return; }
            var ss = T as ISpecSink;
            if (ss == null || ss.SpecCount == 0) return;
            var sb = new StringBuilder();
            foreach (var raw in SpecCfg.Slim(body).Split('\n'))     // 只留观战用得到的字段
            {
                var line = raw.TrimEnd('\r');
                if (line.Length == 0 || line.StartsWith("src=")) continue;
                sb.Append(line).Append('\n');
            }
            sb.Append("src=").Append(src).Append('\n');
            lock (sendLock) ss.SendSpecs(Wire.Seal(sb.ToString()));
        }
        int QPos { get { var ss = T as ISpecSink; return ss != null && Role == "spec" && !SpecCfg.NoQueue ? ss.QPos : 0; } }
        int QLen
        {
            get
            {
                var q = T as IQueueHost;
                if (Role == "host") return q != null ? q.QueueOrder().Count : 0;
                var ss = T as ISpecSink;
                return ss != null ? ss.QLen : 0;
            }
        }
        public int Spectators
        {
            get
            {
                var ss = T as ISpecSink;
                return ss != null ? ss.SpecCount : 0;
            }
        }

        // §141.7 排队。主机：对手掉线 FillAfter 秒、有人排队 → 队首上场；游戏打完一场按房间规矩发 rotate → 对手下场排队尾、队首上场。
        // 换角色的 PBZROLE 每 0.5 秒重发，直到对方照新角色发包（上场的发状态包 / 下场的发 spec=1 握手），最多 RoleRetry 秒
        public const double FillAfter = 4.0, RoleRetry = 6.0;
        volatile string wantRole;                   // 观战者 / 客机：主机让换成的角色（Run 线程里换）
        object roleTo, roleTo2;                     // 主机：正在通知上场的 / 下场的（IP 端点或 Steam 连接句柄）
        DateTime roleAt, roleSentAt, lastQ;
        public volatile string QueueMsg = "";       // 给面板：最近一次换人
        long rxAtPromote;

        // ---- §141.8 主机下场：两位选手经主机互相转发，主机自己观战（游戏收到 src=h 第一位 / src=c 第二位）。
        // 转发给对面选手时序号改成主机自己的（两边看到的序号一直往上走），房间规矩字段换成主机的（两位都是客机，按"主机"的规矩打）。
        // 可靠事件（聊天 / 回合结果）不转：对局流程靠状态包里的 mt= / dead= / quit= 就能走
        public volatile bool RelayOn;
        volatile string relayReq;           // "down" / "up"：面板的"我也下场" / "我回来打"，Run 线程里做
        long secondRx, relaySeq = 100000;
        readonly Dictionary<string, string> hostRules = new Dictionary<string, string>();
        static readonly string[] RuleKeys = { "bar", "bo", "dm", "ab", "ctr", "bal", "medok", "npos", "ult0", "sp0", "resm", "ultx", "rdyto" };
        public bool HostDown() { if (Role != "host" || !(T is IRelayHost)) return false; relayReq = "down"; return true; }
        public bool HostUp() { if (Role != "host" || !RelayOn) return false; relayReq = "up"; return true; }

        void RelayForward(string body, bool fromFirst)
        {
            var rh = T as IRelayHost;
            if (rh == null) return;
            var side = fromFirst ? "h" : "c";
            ForwardSpec(body, side);
            var strip = new StringBuilder();
            foreach (var raw in body.Split('\n'))
            {
                var line = raw.TrimEnd('\r');
                if (line.Length == 0 || line.StartsWith("src=")) continue;
                strip.Append(line).Append('\n');
            }
            var plain = strip.ToString();
            T.Out.Push(plain + "src=" + side + "\n");        // 主机自己的游戏：观战
            var sb = new StringBuilder();
            foreach (var raw in plain.Split('\n'))
            {
                if (raw.Length == 0) continue;
                int eq = raw.IndexOf('=');
                var k = eq > 0 ? raw.Substring(0, eq) : raw;
                if (k == "seq") continue;
                string hv;
                lock (hostRules) if (hostRules.TryGetValue(k, out hv)) { sb.Append(k).Append('=').Append(hv).Append('\n'); continue; }
                sb.Append(raw).Append('\n');
            }
            sb.Append("seq=").Append(System.Threading.Interlocked.Increment(ref relaySeq)).Append('\n');
            lock (sendLock)
            {
                var b = Wire.Seal(sb.ToString());
                if (fromFirst) rh.SendSecond(b); else T.Send(b);
            }
        }

        void RelayTick(DateTime now)
        {
            var rh = T as IRelayHost;
            var q = T as IQueueHost;
            if (rh == null || q == null) return;
            var req = relayReq;
            relayReq = null;
            if (req == "down" && !RelayOn)
            {
                if (!q.HasPeer || !q.CanPromote) { QueueMsg = L.T("要有对手、也要有人排队才能下场", "Need an opponent and someone waiting"); return; }
                var p2 = rh.PromoteSecond();
                if (p2 == null) return;
                rh.NoOut = true;
                RelayOn = true;
                roleTo = p2; roleTo2 = null; roleAt = now; roleSentAt = DateTime.MinValue; rxAtPromote = RxSeen + secondRx;
                QueueMsg = L.T("主机下场，两位对打", "Host stepped down; two players fight");
                if (diag) NetLog.W("主机下场：两位选手经主机转发");
                return;
            }
            if (req == "up" && RelayOn)
            {
                var old = rh.DemoteSecond();
                rh.NoOut = false;
                RelayOn = false;
                roleTo = null; roleTo2 = old; roleAt = now; roleSentAt = DateTime.MinValue;
                QueueMsg = L.T("主机回来打", "Host is back");
                if (diag) NetLog.W("主机回来打：第二位选手下场");
                return;
            }
            if (!RelayOn) return;
            // 第二位走了：有人排队就补，没人就结束转发（主机回来跟第一位打）
            if (roleTo == null && (!rh.HasSecond || rh.SinceFromSecond > FillAfter))
            {
                var p2 = q.CanPromote ? rh.PromoteSecond() : null;
                if (p2 != null) { roleTo = p2; roleAt = now; roleSentAt = DateTime.MinValue; rxAtPromote = RxSeen + secondRx; QueueMsg = L.T("第二位走了，队首补上", "Second player left; next in queue"); }
                else { rh.NoOut = false; RelayOn = false; QueueMsg = L.T("第二位走了，主机回来打", "Second player left; host is back"); }
                return;
            }
            // 第一位走了、没人补：第二位改当第一位，主机回来跟他打
            if (roleTo == null && (!q.HasPeer || q.SinceFromPeer > FillAfter) && !q.CanPromote && rh.HasSecond)
            {
                rh.SecondToPeer();
                rh.NoOut = false;
                RelayOn = false;
                QueueMsg = L.T("第一位走了，主机回来跟第二位打", "First player left; host plays the second");
            }
        }

        // 打完换人：只记下请求，由 Run 线程的 QueueTick 做（和"对手走了补位"在同一个线程，不会两边同时换）
        volatile string rotateWhy, rotateWho;
        public bool Rotate(string why, string who)
        {
            rotateWho = who;
            return Rotate(why);
        }
        public bool Rotate(string why)
        {
            var lk = T as IQueueHost;
            if (lk == null || Role != "host") return false;
            if (!lk.CanPromote) { QueueMsg = L.T("没人排队，不换", "Nobody is waiting"); return false; }
            rotateWhy = why ?? "";
            return true;
        }

        void DoRotate(IQueueHost lk, string why)
        {
            if (!lk.CanPromote) { QueueMsg = L.T("没人排队，不换", "Nobody is waiting"); return; }
            var who = rotateWho;
            rotateWho = null;
            var rh = T as IRelayHost;
            object old, head;
            if (RelayOn && rh != null && who == "c") { old = rh.DemoteSecond(); head = rh.PromoteSecond(); }     // §141.8 第二位输了
            else { old = lk.DemotePeer(); head = lk.PromoteHead(); }
            roleTo2 = old;
            roleTo = head;
            roleAt = DateTime.UtcNow;
            roleSentAt = DateTime.MinValue;
            rxAtPromote = RxSeen + secondRx;
            QueueMsg = L.T("打完换人（", "Rotated (") + why + "）";
            if (diag) NetLog.W("排队：打完换人（" + why + "）");
        }

        // §141.7 对手自己下去观战（面板"我下去观战"）：本机换成观战者、发观战握手，主机见到就让下一位上场
        public bool StepDown()
        {
            if (Role != "client" || !(T is ISpecSink)) return false;
            SpecCfg.NoQueue = true;     // §141 自己下去 = 观战开关切成"只观战"，想再打自己切回"排队"（房主换人 / 补位不碰这个开关）
            wantRole = "spec";
            return true;
        }

        void QueueTick(DateTime now)
        {
            var lk = T as IQueueHost;
            var ss = T as ISpecSink;
            if (Role == "host")
            {
                if (lk == null) return;
                var rw = rotateWhy;
                if (rw != null) { rotateWhy = null; DoRotate(lk, rw); }
                RelayTick(now);
                // 对手走了（连接断了，或 FillAfter 秒没包）→ 队首上场。从来没有过对手（RxSeen = 0）不补：空房间先来的观战者只是来看
                if (RxSeen > 0 && roleTo == null && (!lk.HasPeer || lk.SinceFromPeer > FillAfter) && lk.CanPromote)
                {
                    var head = lk.PromoteHead();
                    if (head != null)
                    {
                        roleTo = head; roleTo2 = null;
                        roleAt = now; roleSentAt = DateTime.MinValue; rxAtPromote = RxSeen;
                        QueueMsg = L.T("对手走了，队首上场", "Opponent left, next in queue plays");
                    }
                }
                if (roleTo != null || roleTo2 != null)
                {
                    bool upDone = roleTo == null || RxSeen + secondRx > rxAtPromote;   // 新对手开始发状态包了
                    bool downDone = roleTo2 == null || (now - roleAt).TotalSeconds > 3.0;   // 下场通知连发 3 秒（对方收到后不再变）
                    if ((upDone && downDone) || (now - roleAt).TotalSeconds > RoleRetry) { roleTo = null; roleTo2 = null; }
                    else if ((now - roleSentAt).TotalSeconds > 0.5)
                    {
                        roleSentAt = now;
                        lock (sendLock)
                        {
                            if (roleTo != null && !upDone) lk.SendTo(roleTo, Wire.Seal("PBZROLE\nrole=client\n"));
                            if (roleTo2 != null) lk.SendTo(roleTo2, Wire.Seal("PBZROLE\nrole=spec\n"));
                        }
                    }
                }
                // 每 2 秒告诉每个观战者排第几
                if ((now - lastQ).TotalSeconds > 2.0)
                {
                    lastQ = now;
                    var q = lk.QueueOrder();
                    lock (sendLock)
                        for (int i = 0; i < q.Count; i++) lk.SendTo(q[i], Wire.Seal("PBZQ\npos=" + (i + 1) + "\nn=" + q.Count + "\n"));
                }
                return;
            }
            var w = wantRole;
            if (w != null)
            {
                wantRole = null;
                // §141 只观战（不排队）的人：主机 / 服务器叫上场一律不理（刚切成只观战、上场通知已经在路上的情况），主机过几秒会换下一个
                if (w == "client" && Role == "spec" && SpecCfg.NoQueue)
                {
                    Log(L.T("只观战：不上场", "Watch only: not going up"));
                    if (diag) NetLog.W("排队：只观战，主机叫上场不理");
                    w = null;
                }
                if (w != null && w != Role && (w == "client" || w == "spec"))
                {
                    Log(L.T("主机让你换成：", "Host switched you to: ") + w);
                    if (diag) NetLog.W("排队：主机让本机换成 " + w);
                    role = w;
                    if (ss != null) ss.SpecMode = w == "spec";
                    QueueMsg = w == "client" ? L.T("轮到你上场了", "Your turn to play") : L.T("你下场观战了", "You are spectating now");
                }
            }
        }

        public bool Connected { get { return (DateTime.UtcNow - lastRx).TotalSeconds < 2.0; } }
        // §85.5 对方在：收到状态包，或 2 秒内握过手。等人的房间读不到游戏的包、一个状态包都不发，
        // 要先收到主机的包才发自己状态的客户端（tests\fake_remote.py）只会一直握手——只认状态包就两边干等
        public bool PeerSeen { get { return Connected || Wire.SinceHello < 2.0; } }

        // §85 AI 对战时等人的房间（文件在 net\wait\）有真人连进来 → 换到 net\ 当正式联机。连接本身不断：
        // 房间号 / 端口 / Steam 连接都不变，对方不用重连。Run 线程下一轮（≤4ms）生效
        public void Retarget(string dir) { retargetTo = dir; }
        public string PeerStr { get { return T.PeerStr; } }

        public Session Start()
        {
            T.Log = Log;
            Rel.Log = Log;
            startedAt = DateTime.UtcNow;
            if (diag)
            {
                var sl = T as ServerLink;
                var lk = T as Link;
                NetLog.W("会话开始：角色 " + Role + "，方式 " + Mode + "，联机程序 " + NetLog.Build + " v" + Proto.App + "，本地端口 " + T.LocalPort
                         + "，本机 " + NetLog.Ip(Addr.PrimaryLocal()) + "，联机密码 " + (Wire.Signed ? "有" : "无")
                         + (sl != null ? "，大厅服务器 " + sl.ServerDiag + "，允许中转 " + (sl.AllowRelay ? "是" : "否")
                                         + (Role == "client" ? "，加入房间 " + sl.RoomId : "") + (sl.RankPid != null ? "，排位" : "") : "")
                         + (lk != null && Role == "client" ? "，目标 " + NetLog.Ip(lk.Peer) : "")
                         + (NetBind.Loopback ? "，只绑回环（测试）" : ""));
            }
            thread = Safe.Thread("session-recv", Run);
            thread.Start();
            sendThread = Safe.Thread("session-send", SendLoop);     // 观战者也开（§141.7 轮到上场就要发），观战时不发
            sendThread.Start();
            return this;
        }

        public void Stop()
        {
            stop = true;
            if (thread != null) thread.Join(2000);
            if (sendThread != null) sendThread.Join(2000);
            try { T.Close(); } catch (Exception) { }
            if (diag) NetLog.W("会话结束（" + Role + "，" + Mode + "）：共收状态包 " + RxSeen + "，发包 " + T.Tx + "，"
                               + (lastRx == DateTime.MinValue ? "一个状态包都没收到" : "最后收包在 " + Kv.F((DateTime.UtcNow - lastRx).TotalSeconds, "0.0") + " 秒前")
                               + "，被拒 " + Wire.Rejected);
        }

        void Run()
        {
            DateTime lastBcast = DateTime.MinValue, lastSess = DateTime.MinValue, lastHello = DateTime.MinValue;
            UdpClient bsock = null;
            if (broadcast)
            {
                try { bsock = new UdpClient(new IPEndPoint(NetBind.Addr, 0)); bsock.EnableBroadcast = true; } catch (Exception) { bsock = null; }
            }
            while (!stop)
            {
                var now = DateTime.UtcNow;
                var rt = retargetTo;
                if (rt != null)
                {
                    retargetTo = null;
                    fLocal = Path.Combine(rt, "state_local.txt");
                    fSession = Path.Combine(rt, "session.txt");
                    T.Out.Retarget(Path.Combine(rt, "state_remote.txt"));     // 管道（§83）也跟着换：net\ 有、net\wait\ 没有
                    Rel.Retarget(rt);
                    lastSess = DateTime.MinValue;     // session.txt 马上写一份（role / peer / mode 都换了）
                }
                Rel.PollLua();
                // §141 观战者一直每秒发一次握手（带 spec=1）当保活：主机 6 秒没收到就当它走了
                if (Role == "spec" && (now - lastHello).TotalSeconds > 1.0)
                {
                    lastHello = now;
                    SendText("PBZHELLO\npv=" + Proto.Version + "\nav=" + Proto.App + "\nnm=" + Name.Replace("\r", " ").Replace("\n", " ") + "\nspec=1\n"
                             + (SpecCfg.NoQueue ? "noq=1\n" : "") + (SpecCfg.Up ? "up=1\n" : ""));
                }
                // 客机没连上之前每 0.5 秒发一次握手：主机就算游戏还没读档，也能先知道往哪回
                if (Role == "client" && !Connected && (now - lastHello).TotalSeconds > 0.5)
                {
                    lastHello = now;
                    // §85.5 带上昵称：AI 对战时等人的房间可能只靠握手就转正（还没收到状态包里的 nm=）
                    SendText("PBZHELLO\npv=" + Proto.Version + "\nav=" + Proto.App + "\nnm=" + Name.Replace("\r", " ").Replace("\n", " ") + "\n");
                }
                int got = T.Pump();
                if (got > 0)
                {
                    lastRx = now;
                    RxSeen += got;
                }
                QueueTick(now);
                Rel.Tick(now);
                lock (sendLock) sim.Flush(T.Send);
                if (bsock != null && (now - lastBcast).TotalSeconds > 1.0)
                {
                    lastBcast = now;
                    var msg = "PBZROOM|" + Name.Replace("|", " ") + "|" + T.LocalPort + "|" + LocalMap + "|" + (Connected ? "1" : "0") + (SpecCfg.Max > 0 ? "|1" : "|0") + (AiWaiting ? "|1" : "|0");
                    var b = Kv.Utf8.GetBytes(msg);
                    // Windows 发 255.255.255.255 只走一张网卡（实测走了 VMware 虚拟网卡，WLAN 上的朋友收不到），
                    // 所以再往每张网卡自己的子网广播地址各发一份
                    foreach (var dst in BroadcastTargets())
                        try { bsock.Send(b, b.Length, new IPEndPoint(dst, DiscoveryPort)); } catch (Exception) { }
                    // Tailscale 不转发广播（ZeroTier 转发，上面的子网广播就够了）：单播给每个在线节点。没装 Tailscale = 空表
                    if (Mode == "lan" && !NetBind.Loopback)
                        foreach (var pr in Tailscale.Peers())
                        {
                            IPAddress ip;
                            if (IPAddress.TryParse(pr[0], out ip))
                                try { bsock.Send(b, b.Length, new IPEndPoint(ip, DiscoveryPort)); } catch (Exception) { }
                        }
                }
                if ((now - lastSess).TotalSeconds > 0.5)
                {
                    lastSess = now;
                    if (diag) DiagTick(now);
                    // v0.22.0：签名 / 拒收 / 可靠事件的统计（窗口状态、测试读这里；Lua 只用前几个键）
                    GamePipe.Out(fSession, "role=" + Role + "\nconnected=" + (Connected ? 1 : 0) + "\npeer=" + PeerStr + "\nspecs=" + Spectators + "\nrelay=" + (RelayOn ? 1 : 0) + "\nqpos=" + QPos + "\nqlen=" + QLen + "\nqmsg=" + QueueMsg
                                             + "\nmode=" + Mode + "\nt=" + Kv.F(Link.UnixNow(), "0.0")
                                             + "\nsig=" + (Wire.Signed ? 1 : 0) + "\nrej=" + Wire.Rejected + "\nrejbad=" + Wire.RejBad
                                             + "\nrejtime=" + Wire.RejTime + "\nrejunsigned=" + Wire.RejUnsigned + "\nrejsigned=" + Wire.RejSigned
                                             + "\nhint=" + Wire.Hint() + "\npeerapp=" + (Wire.PeerApp ?? "") + "\npeerproto=" + Wire.PeerProto
                                             + "\nrelq=" + Rel.Pending + "\nreltaken=" + Rel.Taken + "\nrelsent=" + Rel.Sent + "\nrelretx=" + Rel.Retx
                                             + "\nrelacked=" + Rel.Acked + "\nrelexpired=" + Rel.Expired + "\nreldelivered=" + Rel.Delivered
                                             + "\nreldup=" + Rel.Dup + "\nrelooo=" + Rel.OutOfOrder + "\nrelskipped=" + Rel.Skipped
                                             + "\nsimdrop=" + sim.Dropped + "\nsimdelay=" + sim.Delayed + "\n");
                }
                // HANDOVER §72.10：15ms → 4ms（配合 WinTimer 的 1ms 精度），一起到的包靠这个间隔各写一次 state_remote.txt
                Thread.Sleep(PollMs);
                Loops++;
            }
            if (bsock != null) bsock.Close();
        }

        // §130 每 0.5 秒看一次连接状态，有变化才写一行
        void DiagTick(DateTime now)
        {
            if (Wire.SinceHello < 1.0 && !helloLogged)
            {
                helloLogged = true;
                var pa = Wire.PeerApp;
                NetLog.W("收到对方握手（HELLO）：协议 " + Wire.PeerProto + "，对方 v" + (pa ?? "?") + (pa != null && pa != Proto.App ? "（本机 v" + Proto.App + "，不一样）" : "")
                         + "，来自 " + PeerDiag);
            }
            var app = Wire.PeerApp;
            if (app != null && app != lastPeerApp)
            {
                if (lastPeerApp != null) NetLog.W("对方版本变成 v" + app);
                lastPeerApp = app;
            }
            bool c = Connected;
            if (c && !wasConn)
            {
                NetLog.W("连上：收到对方状态包，对方 " + PeerDiag + "，对方 v" + (app ?? "?") + " 协议 " + Wire.PeerProto
                         + (lostAt == DateTime.MinValue ? "（会话开始后 " + Kv.F((now - startedAt).TotalSeconds, "0.0") + " 秒）"
                                                        : "（中断 " + Kv.F((now - lostAt).TotalSeconds, "0.0") + " 秒后恢复）"));
                connAt = now;
            }
            else if (!c && wasConn)
            {
                lostAt = now;
                helloLogged = false;
                NetLog.W("断开：2 秒没收到对方状态包（连着 " + Kv.F((now - connAt).TotalSeconds, "0.0") + " 秒，共收 " + RxSeen + " 个）");
            }
            wasConn = c;
            var h = Wire.Hint();
            if (h != lastHint)
            {
                if (h.Length > 0) NetLog.W("提示：" + h + "（被拒 " + Wire.Rejected + "）");
                lastHint = h;
            }
        }

        // HANDOVER §72.10：读 state_local.txt 发出去单独一个线程，每 4ms 一次。模组两次写有时只隔 ~17ms，
        // 原来 Sleep(15)（实际 15.6 / 31ms）会漏读；刚被替换的文件第一次打开要等杀毒扫描（实测常见 ~20ms），
        // 和收包、写 state_remote.txt 放在同一个循环里会互相拖慢
        void SendLoop()
        {
            string lastSeq = null, lastText = null;
            var pipeFor = fLocal;
            var pipe = GamePipe.For(Path.GetDirectoryName(fLocal));     // §83
            while (!stop)
            {
                // §85 等人的房间转正 / 退回等人换了目录：管道跟着换（只有 net\ 有）
                var fl = fLocal;
                if (!ReferenceEquals(fl, pipeFor)) { pipeFor = fl; pipe = GamePipe.For(Path.GetDirectoryName(fl)); }
                bool viaPipe = pipe != null && pipe.Connected;
                if (Role == "spec") { Thread.Sleep(PollMs * 5); SendLoops++; continue; }     // §141 观战者不发自己的状态包
                var text = viaPipe ? pipe.LatestLocal : Kv.ReadText(fl);
                if (text != null && text != lastText)   // 每 4ms 读一次，没变就不解析
                {
                    lastText = text;
                    var loc = Kv.Parse(text);
                    string v, seq;
                    if (loc.TryGetValue("v", out v) && v == "2" && loc.TryGetValue("seq", out seq) && seq != lastSeq)
                    {
                        lastSeq = seq;
                        string m;
                        if (loc.TryGetValue("map", out m)) LocalMap = m;
                        if (loc.TryGetValue("mt", out m)) LocalMt = m;
                        if (loc.TryGetValue("quit", out m)) LocalQuit = m;
                        var st = Stats;
                        if (st != null)
                        {
                            string wc, wcs, ev;
                            loc.TryGetValue("wc", out wc); loc.TryGetValue("wcs", out wcs); loc.TryGetValue("ev", out ev);
                            st.Local(wc, wcs, ev);
                        }
                        MaybeBackup(loc);
                        var sb = new StringBuilder();
                        foreach (var raw in text.Split('\n'))
                        {
                            var line = raw.TrimEnd('\r');
                            if (line.Length == 0 || line.StartsWith("st=") || line.StartsWith("nm=")
                                || line.StartsWith("pv=") || line.StartsWith("av=") || line.StartsWith("rk=")) continue;
                            sb.Append(line).Append('\n');
                        }
                        // v0.22.0：协议版本 / 程序版本，对方据此提示"版本不一致"（旧版没有 pv=）
                        sb.Append("pv=").Append(Proto.Version).Append("\nav=").Append(Proto.App).Append('\n');
                        sb.Append("st=").Append(Kv.F(Link.UnixNow(), "0.0000")).Append('\n');
                        // v0.18.7：带上自己的昵称（用户 2026-11-04 要求连上后面板显示对方昵称；直连方式以前只显示 IP）
                        sb.Append("nm=").Append(Name.Replace("\r", " ").Replace("\n", " ")).Append('\n');
                        var rk = RankPid;
                        if (rk != null) sb.Append("rk=").Append(rk).Append('\n');
                        var body = sb.ToString();
                        lock (hostRules)
                            foreach (var k in RuleKeys) { string rv; if (loc.TryGetValue(k, out rv)) hostRules[k] = rv; }
                        if (!RelayOn)
                        {
                            SendText(body);
                            ForwardSpec(body, "h");     // §141 也给观战者一份
                        }
                    }
                }
                // §83 管道：游戏一发来就醒（不用等 4ms 轮询）
                if (viaPipe) pipe.LocalSignal.WaitOne(PollMs); else Thread.Sleep(PollMs);
                SendLoops++;
            }
        }

        List<IPAddress> bcastCache;
        DateTime bcastAt = DateTime.MinValue;
        List<IPAddress> BroadcastTargets()
        {
            if (bcastCache != null && (DateTime.UtcNow - bcastAt).TotalSeconds < 10) return bcastCache;
            if (NetBind.Loopback) return bcastCache = NetBind.DiscoveryAddrs();   // §125 回环下收不到广播，单播给本机每个发现地址
            var list = new List<IPAddress> { IPAddress.Broadcast };
            try
            {
                foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus != OperationalStatus.Up || ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                    foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                    {
                        if (ua.Address.AddressFamily != AddressFamily.InterNetwork || ua.IPv4Mask == null) continue;
                        var a = ua.Address.GetAddressBytes();
                        var m = ua.IPv4Mask.GetAddressBytes();
                        if (m.Length != 4 || (m[0] == 0 && m[1] == 0 && m[2] == 0 && m[3] == 0)) continue;
                        var bc = new byte[4];
                        for (int k = 0; k < 4; k++) bc[k] = (byte)(a[k] | ~m[k]);
                        var ip = new IPAddress(bc);
                        if (!list.Contains(ip)) list.Add(ip);
                    }
                }
            }
            catch (Exception) { }
            bcastCache = list;
            bcastAt = DateTime.UtcNow;
            return list;
        }

        // 每局开始备份一次存档（对局期间游戏可能自动存档）。mt=<状态>:<回合>:<主机分>:<客机分>:<赢家>:<局号>
        void MaybeBackup(Dictionary<string, string> loc)
        {
            string mt;
            if (!doBackup || !loc.TryGetValue("mt", out mt)) return;
            var p = mt.Split(':');
            if (p.Length != 6 || p[0] != "cd" || backedUp.Contains(p[5])) return;
            backedUp.Add(p[5]);
            var id = p[5];
            Safe.Pool("backup", delegate { Log(L.T("第 " + id + " 局开始：", "Match " + id + " started: ") + Backup.Run()); });
        }
    }

    static class Backup
    {
        // exe 在 <游戏>\platform\steam\ue4ss\Mods\PBZ_MP\ ；存档在 <游戏>\ProjectPBZ\Saved\SaveGames\Steam\<SteamID>\
        public static string Run()
        {
            try
            {
                var game = Path.GetFullPath(Path.Combine(Program.BaseDir, @"..\..\..\..\.."));
                var steam = Path.Combine(game, @"ProjectPBZ\Saved\SaveGames\Steam");
                if (!Directory.Exists(steam)) return L.T("找不到存档目录，跳过备份", "save folder not found, backup skipped");
                var outDir = Path.Combine(steam, "pbz-save-backups");
                Directory.CreateDirectory(outDir);
                var done = new List<string>();
                foreach (var dir in Directory.GetDirectories(steam))
                {
                    if (!File.Exists(Path.Combine(dir, "PBZSaveGame.sav"))) continue;
                    var zip = Path.Combine(outDir, Path.GetFileName(dir) + "-backup-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".zip");
                    using (var fs = new FileStream(zip, FileMode.Create))
                    using (var za = new ZipArchive(fs, ZipArchiveMode.Create))
                    {
                        foreach (var f in Directory.GetFiles(dir, "*", SearchOption.AllDirectories))
                        {
                            var rel = f.Substring(dir.Length + 1).Replace('\\', '/');
                            var e = za.CreateEntry(rel, CompressionLevel.Optimal);
                            using (var es = e.Open())
                            using (var src = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                                src.CopyTo(es);
                        }
                    }
                    done.Add(Path.GetFileName(zip));
                }
                return done.Count > 0 ? L.T("已备份存档（存档目录\\pbz-save-backups）", "save backed up (save folder\\pbz-save-backups)")
                                      : L.T("没有找到存档，跳过备份", "no save found, backup skipped");
            }
            catch (Exception ex) { return L.T("备份失败：", "backup failed: ") + ex.Message; }
        }
    }

    // 界面语言（中文 / English）。选择存在 net\lang.txt（lang=zh|en），游戏里的 Lua 也读这个文件来切换屏幕提示
    static class L
    {
        public static volatile bool En;
        public static string T(string zh, string en) { return En ? en : zh; }

        static string FilePath(string dir) { return Path.Combine(dir, "lang.txt"); }

        public static void Load(string dir)
        {
            var d = Kv.Read(FilePath(dir));
            string v;
            if (d != null && d.TryGetValue("lang", out v)) En = v == "en";
            else En = !CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase);   // 第一次：跟系统语言
        }

        public static void Save(string dir)
        {
            var text = "lang=" + (En ? "en" : "zh") + "\n";
            Kv.WriteAtomic(FilePath(dir), text);         // 设置，下次启动读；只在切换时写
            var p = GamePipe.For(dir);                   // §84 游戏经管道拿（不再每秒读一次文件）
            if (p != null) p.SetDown("lang.txt", text);
        }
    }

    // 监听 27016 上的房间广播
    class Discovery
    {
        class Room { public string Name, Map; public bool Full, Watch, Ai; public DateTime Seen; }
        readonly Dictionary<string, Room> rooms = new Dictionary<string, Room>();
        readonly UdpClient sock;
        public readonly bool Ok;
        volatile bool stop;

        public Discovery()
        {
            try
            {
                if (NetBind.Loopback) sock = NetBind.DiscoverySocket();
                else
                {
                    sock = new UdpClient();
                    sock.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                    sock.Client.Bind(new IPEndPoint(IPAddress.Any, Session.DiscoveryPort));
                }
                Ok = true;
                Safe.Thread("discovery", Run).Start();
            }
            catch (Exception) { Ok = false; }
        }

        void Run()
        {
            while (!stop)
            {
                IPEndPoint from = null;
                byte[] data;
                try { data = sock.Receive(ref from); } catch (Exception) { if (stop) break; Thread.Sleep(200); continue; }
                var p = Kv.Utf8.GetString(data).Split('|');
                int port;
                if (p.Length >= 5 && p[0] == "PBZROOM" && int.TryParse(p[2], out port))
                    lock (rooms) rooms[from.Address + ":" + port] = new Room { Name = p[1], Map = p[3], Full = p[4] == "1", Watch = p.Length >= 6 && p[5] == "1", Ai = p.Length >= 7 && p[6] == "1", Seen = DateTime.UtcNow };
            }
        }

        public List<string[]> Current()   // {地址:端口, 名字, 地图, 已满, 能观战}
        {
            var list = new List<string[]>();
            lock (rooms)
                foreach (var kv in rooms)
                    if ((DateTime.UtcNow - kv.Value.Seen).TotalSeconds < 3.5)
                        list.Add(new[] { kv.Key, kv.Value.Name, kv.Value.Map, kv.Value.Full ? "1" : "0", kv.Value.Watch ? "1" : "0", kv.Value.Ai ? "1" : "0" });
            list.Sort((a, b) => string.CompareOrdinal(a[0], b[0]));
            return list;
        }

        public void Close() { stop = true; try { sock.Close(); } catch (Exception) { } }
    }

    class MainForm : Form
    {
        readonly string dir;
        readonly bool doBackup, bg;
        readonly Cfg cfg;
        Session session;
        Session aiSession;    // §75 本地 AI：AI 那一头的 Session（net\ai\ ，127.0.0.1 连 session）
        LocalAi ai;
        // §85 AI 对战时同时开着的真房间（文件在 net\wait\，真人连进来后转正成 session）；waitMode = 它的连接方式
        Session waitSes;
        string waitMode = "";
        readonly CheckBox aiRoomBox = new CheckBox();
        readonly ComboBox aiRoomModeBox = new ComboBox();
        readonly Discovery disc = new Discovery();
        readonly LobbyList lobbyList = new LobbyList();
        readonly CfgFetch cfgFetch = new CfgFetch();     // §158 数值表从大厅服务器拉
        RankClient rank;     // §110 武林盟主（排位）：密钥、上报、排行榜（Ranked.cs）
        RankClient Rank { get { return rank ?? (rank = new RankClient(dir) { Log = m => { lastLog = DateTime.Now.ToString("HH:mm:ss ") + m; } }); } }

        // 面板 / 窗口里列出的连接方式：大厅服务器没开排位时不列"武林盟主"（用户 2026-11-06"没开就隐藏标签"）；
        // 还在问的时候（-1）只有正选着它才列，免得一开窗口标签闪一下
        string[] ShownModes
        {
            get
            {
                int sup = Rank.Support;
                // §135 武林盟主走 Steam：没有 Steam（发布版 / 游戏里的桥不在）就不列。已经选着它的照样列（游戏刚开时桥可能还没好，
                // 别因此把玩家的选择改掉存盘），建房 / 加入时再提示 Steam 没连上
                bool steamOk = Steam.Available || Mode == "ranked" || Program.RankUdp;
                if (steamOk && (sup == 1 || (sup == -1 && Mode == "ranked"))) return Modes.All;
                return Array.FindAll(Modes.All, x => x != "ranked");
            }
        }
        int shownSupport = -2;     // 上次按哪个 Support / Steam 有没有填的下拉框（变了重填）
        int ShownKey { get { return Rank.Support * 2 + (Steam.Available ? 1 : 0); } }
        readonly TextBox nameBox = new TextBox(), ipBox = new TextBox(), portBox = new TextBox(), srvBox = new TextBox(), secretBox = new TextBox();
        readonly ListBox roomList = new ListBox();
        readonly Label status = new Label(), logLabel = new Label(), roleBig = new Label(), roleSub = new Label();
        readonly Label lblName = new Label(), lblIp = new Label(), lblJoin = new Label(), lblRooms = new Label(), lblHelp = new Label();
        readonly Label lblMode = new Label(), lblPort = new Label(), lblSecret = new Label();
        readonly TextBox ipsBox = new TextBox();
        readonly ComboBox langBox = new ComboBox(), modeBox = new ComboBox(), aiBox = new ComboBox();
        readonly CheckBox upnpBox = new CheckBox();
        Button hostBtn, joinBtn, stopBtn;
        readonly HashSet<string> myIps = new HashSet<string>();
        readonly List<string[]> cands = new List<string[]>();     // 可加入目标 {类型, 显示名, target}
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer(), cmdTimer = new System.Windows.Forms.Timer();
        string lastLog = "", lastErr = "", lastCmd = null, lastPipeCmd = null, ack = "";
        volatile bool cmdFileDirty = true;     // §84 cmd.txt 被改过（FileSystemWatcher）；没有管道时照旧每次读
        DateTime lastErrAt = DateTime.MinValue, noGameSince = DateTime.MinValue;
        bool loadingMode;

        public MainForm(string dir, bool doBackup, string autoJoin, bool bg)
        {
            this.dir = dir;
            this.doBackup = doBackup;
            this.bg = bg;
            cfg = new Cfg(dir);
            L.Save(dir);      // 第一次按系统语言选好后也写下来，游戏端读到的和窗口一致
            Font = new Font("Microsoft YaHei UI", 9f);
            ClientSize = new Size(600, 640);
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;

            int y = 14;
            lblName.SetBounds(14, y + 3, 130, 20); Add(lblName);
            nameBox.SetBounds(150, y, 200, 24); nameBox.Text = cfg.Name; Controls.Add(nameBox);
            nameBox.Leave += delegate { cfg.Name = nameBox.Text.Trim(); cfg.Save(); };
            // v0.22.0 联机密码（可选）：两边填同一个，每个包带 HMAC-SHA256 签名；空 = 不签名（同旧版）
            lblSecret.SetBounds(356, y + 3, 40, 20); Add(lblSecret);
            secretBox.SetBounds(398, y, 82, 24); secretBox.UseSystemPasswordChar = true; secretBox.Text = cfg.Secret; Controls.Add(secretBox);
            secretBox.Leave += delegate { cfg.Secret = secretBox.Text.Trim(); cfg.Save(); };
            // 右上角：语言切换（立即生效并写 net\lang.txt，游戏里的屏幕提示跟着切）
            langBox.DropDownStyle = ComboBoxStyle.DropDownList;
            langBox.Items.AddRange(new object[] { "中文", "English" });
            langBox.SetBounds(486, y, 100, 24);
            langBox.SelectedIndex = L.En ? 1 : 0;
            langBox.SelectedIndexChanged += delegate { L.En = langBox.SelectedIndex == 1; L.Save(dir); ApplyLang(); };
            Add(langBox);
            y += 34;
            // 连接方式（net-ui）：Steam 好友 / 局域网 / 广域网 / 虚拟局域网；游戏内联机面板改的也是这个
            lblMode.SetBounds(14, y + 3, 130, 20); Add(lblMode);
            modeBox.DropDownStyle = ComboBoxStyle.DropDownList;
            modeBox.SetBounds(150, y, 250, 24);
            modeBox.SelectedIndexChanged += delegate { if (!loadingMode) SetMode(ShownModes[Math.Max(0, modeBox.SelectedIndex)]); };
            Add(modeBox);
            lblPort.SetBounds(410, y + 3, 40, 20); Add(lblPort);
            portBox.SetBounds(450, y, 56, 24); portBox.Text = cfg.Port.ToString(); Controls.Add(portBox);
            portBox.Leave += delegate
            {
                int p;
                if (int.TryParse(portBox.Text.Trim(), out p) && p > 0 && p < 65536) { cfg.Port = p; cfg.Save(); }
                portBox.Text = cfg.Port.ToString();
            };
            upnpBox.SetBounds(514, y + 1, 80, 24); upnpBox.Checked = cfg.Upnp; Add(upnpBox);
            upnpBox.CheckedChanged += delegate { cfg.Upnp = upnpBox.Checked; cfg.Save(); };
            // 服务器大厅：端口 / UPnP 的位置换成大厅服务器地址（Tick 里按方式切换显示）
            srvBox.SetBounds(450, y, 136, 24); srvBox.Text = cfg.Server; srvBox.Visible = false; Controls.Add(srvBox);
            // 本地 AI：端口 / UPnP 的位置换成难度
            aiBox.DropDownStyle = ComboBoxStyle.DropDownList;
            aiBox.SetBounds(450, y, 136, 24); aiBox.Visible = false; Add(aiBox);
            aiBox.SelectedIndexChanged += delegate
            {
                if (loadingMode || aiBox.SelectedIndex < 0) return;
                cfg.AiLevel = aiBox.SelectedIndex; cfg.Save();
                if (ai != null) ai.Level = cfg.AiLevel;
            };
            srvBox.Leave += delegate { cfg.Server = srvBox.Text.Trim(); cfg.Save(); };
            y += 34;
            lblIp.SetBounds(14, y, 130, 20); Add(lblIp);
            ipsBox.SetBounds(150, y, 430, 66);
            ipsBox.ReadOnly = true; ipsBox.Multiline = true; ipsBox.ScrollBars = ScrollBars.Vertical; ipsBox.WordWrap = false;
            ipsBox.BorderStyle = BorderStyle.None; ipsBox.TabStop = false;
            Add(ipsBox);
            y += 74;
            hostBtn = new Button { Left = 14, Top = y, Width = 180, Height = 30 };
            hostBtn.Click += delegate { StartSession("host", null); };
            Add(hostBtn);
            // §85 本地 AI：同时开房等真人（开关）+ 开房方式；AI 对战中也能开关、换方式
            aiRoomBox.SetBounds(206, y + 4, 150, 24); aiRoomBox.Checked = cfg.AiRoom; Add(aiRoomBox);
            aiRoomBox.CheckedChanged += delegate { if (!loadingMode) SetAiRoom(aiRoomBox.Checked); };
            aiRoomModeBox.DropDownStyle = ComboBoxStyle.DropDownList;
            aiRoomModeBox.SetBounds(360, y + 3, 226, 24); Add(aiRoomModeBox);
            aiRoomModeBox.SelectedIndexChanged += delegate
            {
                if (!loadingMode && aiRoomModeBox.SelectedIndex >= 0) SetAiRoomMode(Modes.Rooms[aiRoomModeBox.SelectedIndex]);
            };
            y += 44;
            lblJoin.SetBounds(14, y + 3, 130, 20); Add(lblJoin);
            ipBox.SetBounds(150, y, 200, 24); Controls.Add(ipBox);
            joinBtn = new Button { Left = 360, Top = y - 2, Width = 90, Height = 28 };
            joinBtn.Click += delegate { Join(ipBox.Text); };
            Add(joinBtn);
            y += 38;
            lblRooms.SetBounds(14, y, 570, 20); Add(lblRooms);
            y += 22;
            roomList.SetBounds(14, y, 570, 110);
            roomList.DoubleClick += delegate
            {
                int i = roomList.SelectedIndex;
                if (i >= 0 && i < cands.Count && cands[i][0] == "nohost") Warn(L.T("对方还没开房", "They are not hosting yet"));   // §123
                else if (i >= 0 && i < cands.Count && (cands[i][0] == "watch" || cands[i][0] == "watchf")) Spectate(cands[i][2]);   // §141
                else if (i >= 0 && i < cands.Count) { ipBox.Text = cands[i][2]; Join(cands[i][2]); }
            };
            Controls.Add(roomList);
            y += 120;
            status.SetBounds(14, y, 370, 120);
            Add(status);
            // 右侧大字：当前身份（用户 2026-11-04："当前是主机还是客机要明确地用大字显示"）
            roleBig.SetBounds(390, y, 196, 54);
            roleBig.Font = new Font("Microsoft YaHei UI", 26f, FontStyle.Bold);
            roleBig.TextAlign = ContentAlignment.MiddleCenter;
            Add(roleBig);
            roleSub.SetBounds(390, y + 56, 196, 44);
            roleSub.Font = new Font("Microsoft YaHei UI", 10.5f, FontStyle.Bold);
            roleSub.TextAlign = ContentAlignment.TopCenter;
            Add(roleSub);
            y += 124;
            stopBtn = new Button { Left = 14, Top = y, Width = 90, Height = 28 };
            stopBtn.Click += delegate { StopSession(); };
            Add(stopBtn);
            logLabel.SetBounds(116, y + 5, 470, 22);
            logLabel.ForeColor = Color.DimGray;
            logLabel.AutoEllipsis = true;
            Add(logLabel);
            y += 38;
            lblHelp.SetBounds(14, y, 570, 54); lblHelp.ForeColor = Color.DimGray; Add(lblHelp);
            ApplyLang();

            try
            {
                foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
                    foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                        if (ua.Address.AddressFamily == AddressFamily.InterNetwork) myIps.Add(ua.Address.ToString());
            }
            catch (Exception) { }
            WriteNone();
            // 启动时 cmd.txt 里留着的旧命令不执行（上次游戏留下的）
            var old = Kv.Read(CmdPath);
            string oid;
            if (old != null && old.TryGetValue("id", out oid)) lastCmd = oid;
            if (Modes.IsSteam(cfg.Mode)) Steam.Init();
            timer.Interval = 500;
            timer.Tick += delegate { Tick(); };
            timer.Start();
            var gpw = GamePipe.For(dir);
            if (gpw != null) gpw.CmdFileChanged = () => { cmdFileDirty = true; };
            cmdTimer.Interval = 100;
            cmdTimer.Tick += delegate { CheckWait(); CheckBack(); PollCmd(); };
            cmdTimer.Start();
            FormClosing += (s, e) =>
            {
                // §99 后台模式（游戏带起的）被游戏内面板"打开电脑上的联机窗口"显示出来后，点 × 只藏起窗口。
                // 2026-11-05 19:56 内测：点 × 整个联机程序退出，游戏那边管道断开、4 分多钟没有联机程序，直到手动重启
                if (bg && !quitting && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); return; }
                quitting = true;          // 关闭过程中 Tick() 再进 AutoExit 时不要再 Quit
                timer.Stop(); cmdTimer.Stop(); StopSession(); disc.Close(); lobbyList.Close(); cfgFetch.Close(); Steam.Shutdown();
                WriteLobby(false);
            };
            Shown += delegate { ActiveControl = hostBtn; };
            if (autoJoin != null) Shown += delegate { ipBox.Text = autoJoin; Join(autoJoin); };   // 测试用：--gui-join IP
            Tick();
        }

        void Add(Control c) { Controls.Add(c); }
        string CmdPath { get { return Path.Combine(dir, "cmd.txt"); } }
        string Mode { get { return cfg.Mode; } }

        // 固定文字按当前语言重设；会变的文字（状态、身份、房间列表）由 Tick 每次按语言生成
        void ApplyLang()
        {
            Text = L.T("影之刃零 联机", "Phantom Blade Zero - LAN Battle");
            lblName.Text = L.T("昵称", "Nickname");
            lblSecret.Text = L.T("密码", "Pass");
            lblMode.Text = L.T("连接方式", "Connect via");
            lblPort.Text = L.T("端口", "Port");
            upnpBox.Text = "UPnP";
            loadingMode = true;
            modeBox.Items.Clear();
            var shown = ShownModes;
            shownSupport = ShownKey;
            foreach (var m in shown) modeBox.Items.Add(Modes.Name(m));
            modeBox.SelectedIndex = Array.IndexOf(shown, Mode);
            aiBox.Items.Clear();
            for (int i = 0; i < LocalAi.Levels.Length; i++) aiBox.Items.Add(L.T("难度：", "Level: ") + LocalAi.LevelName(i));
            aiBox.SelectedIndex = cfg.AiLevel;
            aiRoomBox.Text = L.T("同时开房等真人", "Also host a room");
            aiRoomBox.Checked = cfg.AiRoom;
            aiRoomModeBox.Items.Clear();
            foreach (var m in Modes.Rooms) aiRoomModeBox.Items.Add(L.T("开房：", "Room: ") + Modes.Name(m));
            aiRoomModeBox.SelectedIndex = Array.IndexOf(Modes.Rooms, cfg.AiRoomMode);
            loadingMode = false;
            lblIp.Text = L.T("你的地址（发给朋友）", "Your address (send it)");
            hostBtn.Text = Mode == "ai" ? L.T("开始 AI 对战", "Start AI battle") : L.T("创建房间（当主机）", "Create room (host)");
            joinBtn.Text = L.T("加入", "Join");
            lblRooms.Text = L.T("可加入（双击加入）", "Joinable (double-click to join)");
            stopBtn.Text = L.T("断开", "Disconnect");
            lblHelp.Text = L.T("游戏里按 Home 打开联机面板（建房 / 加入 / 换连接方式），不用切出来。连上后对手自动出现；两边都按 F1 准备，开始对战。\n主机可以先在场地中心按 F2 存场地。第一次运行 Windows 防火墙会询问，请允许。",
                               "In game, press Home for the online panel (host / join / connection) without leaving the game. The opponent appears once connected; both press F1 to fight.\nHost: press F2 at the arena center to save it. Allow the firewall prompt on first run.");
            if (IsHandleCreated) Tick();
        }

        void WriteNone()
        {
            GamePipe.Out(Path.Combine(dir, "session.txt"), "role=none\nconnected=0\npeer=\nt=" + Kv.F(Link.UnixNow(), "0.0") + "\n");     // §84
        }

        // 出错：窗口开着就弹框，同时记下来给游戏内面板显示
        void Warn(string msg)
        {
            lastErr = msg;
            lastErrAt = DateTime.UtcNow;
            lastLog = DateTime.Now.ToString("HH:mm:ss ") + msg;
            if (Visible) MessageBox.Show(this, msg, L.T("联机", "LAN Battle"));
        }

        void SetMode(string m)
        {
            m = Modes.Valid(m);
            if (m == "ranked" && Rank.Support == 0) { Warn(L.T("这台大厅服务器没开武林盟主排位", "This lobby server has no ranked mode")); ApplyLang(); return; }
            if (m == "ranked" && m != Mode && !Steam.Available && !Program.RankUdp) { Warn(L.T("武林盟主走 Steam：", "Ranked play uses Steam: ") + Steam.Error); ApplyLang(); return; }     // §135
            if (session != null && m != Mode) { Warn(L.T("联机中不能换连接方式，先断开", "Disconnect before changing the connection")); ApplyLang(); return; }
            cfg.Mode = m;
            cfg.Save();
            lastErr = "";
            if (Modes.IsSteam(m) && !Steam.Init()) lastErr = Steam.Error;
            ApplyLang();
            Tick();
        }

        // §116 remember = false：不记进"最近连接"（testsake_join.py 让游戏连本机假主机时带 remember=0，
        // 不然 127.0.0.1:27115 / 27117 这种测试地址会一直留在用户面板的"加入 最近"里）
        void Join(string text, bool remember = true)
        {
            text = (text ?? "").Trim();
            if (Mode == "ai") { StartSession("host", null); return; }     // 本地 AI 没有"加入"，一律当开始
            if (text.Length == 0)
            {
                Warn(Mode == "steam" ? L.T("先选一个开房的好友，或填主机的 SteamID64", "Pick a friend who is hosting, or enter the host's SteamID64")
                     : Modes.IsServer(Mode) ? L.T("先选一个房间，或填房间号", "Pick a room, or enter the room code")
                     : Mode == "steamlobby" ? L.T("先选一个大厅", "Pick a lobby first")
                     : L.T("先填主机 IP", "Enter the host IP first"));
                return;
            }
            // 服务器大厅里填的是 IP / 域名（带 . 或 :）= 输入 IP 直连（原来的广域网）
            if (Modes.IsServer(Mode) && (text.IndexOf('.') >= 0 || text.IndexOf(':') >= 0) && !text.StartsWith("room:"))
            {
                // §110 排位要经服务器（服务器靠会话认两边是谁），不能 IP 直连
                if (Mode == "ranked") { Warn(L.T("武林盟主只能从房间列表 / 房间号加入，不能 IP 直连", "Ranked rooms are joined from the list or by room code, not by IP")); return; }
                var dep = Addr.Parse(text, cfg.Port);
                if (dep == null) { Warn(L.T("认不出这个地址：", "Can't resolve this address: ") + text); return; }
                if (StartSession("client", dep, 0) && remember) cfg.Remember(Mode, dep.ToString());
                return;
            }
            if (Modes.IsServer(Mode))
            {
                // 房间号（6 位）或列表里的 room:<房间号>[@<所在服务器 IP:端口>]（别的服务器互通过来的房间，要去那台加入，§50）；
                // 房间是临时的，不记进最近列表
                var room = text.StartsWith("room:") ? text.Substring(5) : text;
                int at = room.IndexOf('@');
                var code = at >= 0 ? room.Substring(0, at) : room;
                if (code.Length < 4 || code.Length > 16 || code.IndexOfAny(new[] { ' ', '|', ':', '.' }) >= 0
                    || (at >= 0 && LobbyServer.Resolve(room.Substring(at + 1)) == null)) { Warn(L.T("这不是房间号：", "Not a room code: ") + text); return; }
                StartSession("client", null, 0, room);
                return;
            }
            if (Mode == "steamlobby")
            {
                // 列表里的 lobby:<大厅 ID>，或直接填主人的 SteamID64
                ulong owner = Addr.SteamId(text), lobby = 0;
                if (owner == 0 && text.StartsWith("lobby:") && ulong.TryParse(text.Substring(6), out lobby)) owner = SteamLobby.OwnerOf(lobby);
                if (owner == 0) { Warn(L.T("找不到这个大厅的主人（大厅关了？）：", "Can't find the owner of this lobby (closed?): ") + text); return; }
                if (StartSession("client", null, owner) && lobby != 0) SteamLobby.Join(lobby);
                return;
            }
            if (Mode == "steam")
            {
                ulong id = Addr.SteamId(text);
                if (id == 0) { Warn(L.T("这不是 SteamID64（7656 开头的 17 位数字）：", "Not a SteamID64 (17 digits starting with 7656): ") + text); return; }
                if (StartSession("client", null, id) && remember) cfg.Remember(Mode, "steam:" + id);
                return;
            }
            var ep = Addr.Parse(text, Session.GamePort);
            if (ep == null) { Warn(L.T("认不出这个地址：", "Can't resolve this address: ") + text); return; }
            if (StartSession("client", ep, 0) && remember) cfg.Remember(Mode, ep.Port == Session.GamePort ? ep.Address.ToString() : ep.ToString());
        }

        // §141.7 对手自己下去观战：局域网 / IP / Steam 在会话里换角色；服务器大厅的客机要换成观战连接（WatchLink），重开会话
        void ToSpec()
        {
            var s = session;
            if (s == null || s.Role != "client") return;
            if (s.StepDown()) return;
            var sl = s.T as ServerLink;
            if (sl != null && sl.RoomId.Length > 0) { var room = sl.RoomId; nextDown = true; StartSession("spec", null, 0, room); }
        }

        // §141 观战：局域网 / 服务器大厅里输入 IP，连主机当观战者（主机要是局域网开的房，服务器大厅的主机还不支持）
        void Spectate(string text)
        {
            text = (text ?? "").Trim();
            if (Mode == "ranked" || Mode == "ai") { Warn(L.T("这种连接方式不能观战", "Spectating is not available in this mode")); return; }
            if (Modes.IsSteam(Mode))
            {
                // §141 Steam 好友（steam:<SteamID64>）/ Steam 大厅（lobby:<大厅 ID>）：连主机当观战者（不进大厅，大厅只有两个位子）
                ulong owner = Addr.SteamId(text), lobby = 0;
                if (owner == 0 && text.StartsWith("lobby:") && ulong.TryParse(text.Substring(6), out lobby)) owner = SteamLobby.OwnerOf(lobby);
                if (owner == 0 && text.StartsWith("watch:") && ulong.TryParse(text.Substring(6), out lobby)) owner = SteamLobby.OwnerOf(lobby);
                if (owner == 0) { Warn(L.T("找不到主机：", "Can't find the host: ") + text); return; }
                StartSession("spec", null, owner);
                return;
            }
            // §141 服务器大厅房间列表里的 watch:<房间号>[@服务器]，或直接填房间号
            if (Modes.IsServer(Mode) && (text.StartsWith("watch:") || text.StartsWith("room:") || (text.IndexOf('.') < 0 && text.IndexOf(':') < 0)))
            {
                var room = text.StartsWith("watch:") ? text.Substring(6) : text.StartsWith("room:") ? text.Substring(5) : text;
                if (room.Length < 4) { Warn(L.T("这不是房间号：", "Not a room code: ") + text); return; }
                StartSession("spec", null, 0, room);
                return;
            }
            var ep = Addr.Parse(text, Modes.IsServer(Mode) ? cfg.Port : Session.GamePort);
            if (ep == null) { Warn(L.T("认不出这个地址：", "Can't resolve this address: ") + text); return; }
            StartSession("spec", ep, 0);
        }

        bool StartSession(string role, IPEndPoint peer) { return StartSession(role, peer, 0, null); }
        bool StartSession(string role, IPEndPoint peer, ulong steamHost) { return StartSession(role, peer, steamHost, null); }

        string nextToken;       // §141.7 下一次服务器大厅客机会话 JOIN 带的上场口令
        bool nextDown;          // §141.7 下一次服务器大厅观战会话是"刚下场的"

        bool StartSession(string role, IPEndPoint peer, ulong steamHost, string room)
        {
            StopSession();
            cfg.Name = nameBox.Text.Trim();
            cfg.Secret = secretBox.Text.Trim();
            cfg.Save();
            lastErr = "";
            try
            {
                ITransport t = null;
                ServerLink sl = null;
                IRoomLink rl = null;      // §135 经大厅服务器开房 / 加入的（服务器大厅 sl，或武林盟主 RankedLink）
                if (Mode == "ranked" && !Program.RankUdp)
                {
                    // §135 武林盟主的对局只走 Steam（用户 2026-11-07）：大厅服务器只管登记 / 介绍 / 记分，不打洞、不中转
                    int at = room != null ? room.IndexOf('@') : -1;
                    if (at >= 0) room = room.Substring(0, at);       // 排位房间不推给别的服务器（§110），一般不会有 @
                    var srv = LobbyServer.Resolve(cfg.Server);
                    if (srv == null)
                    {
                        Warn(cfg.Server.Length == 0 ? L.T("先在设置里填大厅服务器地址", "Set the lobby server first")
                                                    : L.T("认不出大厅服务器地址：", "Can't resolve the lobby server: ") + cfg.Server);
                        return false;
                    }
                    if (!Steam.Init()) { Warn(L.T("武林盟主走 Steam：", "Ranked play uses Steam: ") + Steam.Error); return false; }
                    Warn(L.T("这一版不带 Steam，没有武林盟主", "This build has no Steam, so no ranked play"));
                    return false;
                }
                else if (Modes.IsSteam(Mode))
                {
                    if (!Steam.Init()) { Warn(Steam.Error); return false; }
                }
                else if (role == "spec" && room != null && Modes.IsServer(Mode))
                {
                    // §141 服务器大厅的房间：观战者只和大厅服务器说话，主机的两路包由服务器转来
                    int at = room.IndexOf('@');
                    var srv = LobbyServer.Resolve(at >= 0 ? room.Substring(at + 1) : cfg.Server);
                    if (at >= 0) room = room.Substring(0, at);
                    if (srv == null) { Warn(L.T("认不出大厅服务器地址：", "Can't resolve the lobby server: ") + cfg.Server); return false; }
                    t = new WatchLink(srv, room, Path.Combine(dir, "state_remote.txt")) { Down = nextDown };
                    nextDown = false;
                }
                else if (Modes.IsServer(Mode) && !((role == "client" || role == "spec") && peer != null))     // 客机输入 IP 直连 = 普通 UDP（下面 t = null）
                {
                    // 客机加入别的服务器的房间（room = 房间号@那台服务器）：去那台 JOIN、打洞、中转
                    int at = room != null ? room.IndexOf('@') : -1;
                    var srv = LobbyServer.Resolve(at >= 0 ? room.Substring(at + 1) : cfg.Server);
                    if (at >= 0) room = room.Substring(0, at);
                    if (srv == null)
                    {
                        Warn(cfg.Server.Length == 0 ? L.T("先在设置里填大厅服务器地址（可自己架设）", "Set or host a lobby server first")
                                                    : L.T("认不出大厅服务器地址：", "Can't resolve the lobby server: ") + cfg.Server);
                        return false;
                    }
                    // 客机端口随机：打洞靠服务器告诉对方地址。主机监听设置里的端口（默认 27015）：朋友可以"输入 IP 直连"，
                    // 开了端口转发 / UPnP 时服务器连不上也能玩（原来的广域网）
                    t = sl = new ServerLink(srv, role == "host" ? null : room, role == "host" ? cfg.Port : 0, cfg.Name,
                                            Path.Combine(dir, "state_remote.txt"), Program.SimNoDirect);
                    sl.AllowRelay = cfg.Relay;
                    sl.ServerName = at >= 0 ? "" : cfg.Server;     // 互通过来的房间去的是别的服务器，只显示 IP
                    if (role == "client") { sl.JoinToken = nextToken; nextToken = null; }
                    if (Mode == "ranked") sl.RankPid = Rank.Pid;     // 只有测试开关 RankUdp 时武林盟主才走到这里（§135）
                    rl = sl;
                }
                if (Mode == "ai") return StartAi();
                int port = Modes.IsServer(Mode) ? cfg.Port : Session.GamePort;
                var ses = new Session(role, Mode, t, peer, port, cfg.Name, dir, doBackup, cfg.Secret);
                if (rl != null && Mode == "ranked")
                {
                    ses.RankPid = Rank.Pid;
                    ses.Stats = Rank.Stats;
                    var rs = Rank.Stats;
                    rl.PeerPacket = d => { string r; if (d.TryGetValue("res", out r)) rs.Peer(r); };     // 对方报我的招打没打中
                }
                if (rl != null) rl.MapOf = () => ses.LocalMap;
                session = ses;
                session.Log = m => { lastLog = DateTime.Now.ToString("HH:mm:ss ") + m; };
                session.Start();
                if (Mode == "server" && role == "host" && cfg.Upnp) Upnp.MapAsync(port);     // §135 武林盟主走 Steam，用不着开端口
                if (Mode == "steamlobby" && role == "host") SteamLobby.Host(cfg.Name);
            }
            catch (SocketException ex)
            {
                session = null;
                WriteNone();
                if (!Modes.IsSteam(Mode) && Mode != "ai") NetLog.W("开会话失败（" + role + "，" + Mode + "）：开不了端口 " + ex.Message);
                Warn(L.T("开不了端口：", "Can't open the port: ") + ex.Message
                     + L.T("（是不是还开着另一个游戏 / 联机程序 / 幽灵测试？）", " (Is another game, online helper or the ghost test still running?)"));
                return false;
            }
            catch (Exception ex)
            {
                session = null;
                WriteNone();
                Warn(ex.Message);
                return false;
            }
            Tick();
            return true;
        }

        // §75 本地 AI 对战：游戏这边当主机（随机端口，不广播、不签名），AI 当客机从 127.0.0.1 连进来，包走真的 Session / 可靠通道；
        // LocalAi 在 net\ai\  里读你的包、写它的包。在 StartSession 的 try 里调（开不了端口照常报错）
        // backFrom：§85 真人离开后重开 AI 时，离开的人的昵称（AI 的包带上，模组提示"XXX 已离开房间，AI 对战已重新开始"）
        bool StartAi(string backFrom = null)
        {
            var aiDir = Path.Combine(dir, "ai");
            Directory.CreateDirectory(aiDir);
            GamePipe.StartVirtual(aiDir);       // §84 AI 和它的 Session 在同一个进程里：内存交接，不写 net\ai\ 的文件（要在建 Session 之前）
            foreach (var f in new[] { "state_local.txt", "state_remote.txt", "session.txt", "rel_in.txt", "rel_out.txt" })
                try { File.Delete(Path.Combine(aiDir, f)); } catch (Exception) { }
            var host = new Session("host", "ai", null, null, 0, cfg.Name, dir, doBackup, null);
            session = host;
            // "对端锁定为 127.0.0.1:…" 对 AI 没意义，还会盖掉"XXX 已离开房间，AI 对战已重新开始"（§85）
            var locked = L.T("对端锁定为 ", "Peer locked: ");
            session.Log = m => { if (!m.StartsWith(locked)) lastLog = DateTime.Now.ToString("HH:mm:ss ") + m; };
            session.Start();
            try
            {
                aiSession = new Session("client", "ai", null, new IPEndPoint(IPAddress.Loopback, host.T.LocalPort), 0,
                                        L.T("AI 对手", "AI opponent"), aiDir, false, null).Start();
            }
            catch (Exception) { StopSession(); throw; }     // 主机那头已经开了，别留着
            // pbz_abilities.lua：部署后在 exe 旁边的 Scripts 里；仓库里 exe 在 lobby 里，回退到 mod/PBZ_MP/Scripts
            var abil = Path.Combine(Program.BaseDir, "Scripts", "pbz_abilities.lua");
            if (!File.Exists(abil)) abil = Path.Combine(Program.BaseDir, "..", "mod", "PBZ_MP", "Scripts", "pbz_abilities.lua");
            ai = new LocalAi(aiDir, abil) { Level = cfg.AiLevel, Load = cfg.AiLoad.Clone(), BackFrom = backFrom };
            // §127 重开时 AI 开局那几行（读招式表、"AI：武器 / 影之武装 …" §114）同样会盖掉"XXX 已离开房间"：
            // 在 AI 说别的话（喝药、被打倒…）之前，这几种不进 msg
            bool quiet = backFrom != null;
            var setup = new[] { L.T("AI：武器 ", "AI: weapon "), L.T("AI：影之武装 ", "AI: Phantom Edge "), L.T("AI：读不到 ", "AI: can't read ") };
            ai.Log = m =>
            {
                if (quiet && Array.Exists(setup, p => m.StartsWith(p))) return;
                quiet = false;
                lastLog = DateTime.Now.ToString("HH:mm:ss ") + m;
            };
            ai.Start();
            lastLog = DateTime.Now.ToString("HH:mm:ss ") + (backFrom != null ? backFrom + L.T(" 已离开房间，AI 对战已重新开始", " left the room; AI battle restarted")
                      : L.T("AI 对手已就位：两边都按 F1 准备后开打（AI 一直是准备好的）", "AI opponent ready: press F1 to fight (the AI is always ready)"));
            if (cfg.AiRoom && waitSes == null) StartWait();     // 真人离开时房间已经退回等人（CheckBack），不重开
            Tick();
            return true;
        }

        bool AiRunning { get { return session != null && session.Mode == "ai"; } }

        // §85 主机连接（等人的房间用）：和 StartSession 里当主机的那一支一样，只是文件放在 d
        Session NewHost(string mode, string d)
        {
            ITransport t = null;
            ServerLink sl = null;
            if (Modes.IsSteam(mode))
            {
                if (!Steam.Init()) throw new InvalidOperationException(Steam.Error);
            }
            else if (mode == "server")
            {
                var srv = LobbyServer.Resolve(cfg.Server);
                if (srv == null)
                    throw new InvalidOperationException(cfg.Server.Length == 0 ? L.T("先在设置里填大厅服务器地址（可自己架设）", "Set or host a lobby server first")
                                                                            : L.T("认不出大厅服务器地址：", "Can't resolve the lobby server: ") + cfg.Server);
                t = sl = new ServerLink(srv, null, cfg.Port, cfg.Name, Path.Combine(d, "state_remote.txt"), Program.SimNoDirect);
                sl.AllowRelay = cfg.Relay;
                sl.ServerName = cfg.Server;
            }
            int port = mode == "server" ? cfg.Port : Program.LanPort;
            var ses = new Session("host", mode, t, null, port, cfg.Name, d, doBackup, cfg.Secret);
            if (sl != null) sl.MapOf = () => ses.LocalMap;
            return ses;
        }

        // §85 AI 对战时同时开一个真房间（cfg.AiRoomMode）。文件在 net\wait\：游戏照常和 AI 打，
        // 有真人连进来（收到它的状态包）→ CheckWait 停掉 AI、把这个房间转正。开不了只提示，AI 对战照常
        void StartWait()
        {
            StopWait();
            if (!AiRunning) return;
            var m = cfg.AiRoomMode;
            var wdir = Path.Combine(dir, "wait");
            try
            {
                Directory.CreateDirectory(wdir);
                foreach (var f in new[] { "state_local.txt", "state_remote.txt", "session.txt", "rel_in.txt", "rel_out.txt" })
                    try { File.Delete(Path.Combine(wdir, f)); } catch (Exception) { }
                var ses = NewHost(m, wdir);
                ses.Log = x => { lastLog = DateTime.Now.ToString("HH:mm:ss ") + L.T("[等人的房间] ", "[Room] ") + x; };
                ses.LocalMap = session.LocalMap;
                ses.AiWaiting = true;
                var wsl = ses.T as ServerLink;
                if (wsl != null) wsl.AiRoom = true;
                ses.Start();
                waitSes = ses;
                var ais = session;
                if (ais != null) ais.SpecRelay = ses;     // §141 AI 对打的两路包给等人房间的观战者
                waitMode = m;
                if (m == "server" && cfg.Upnp) Upnp.MapAsync(cfg.Port);
                if (m == "steamlobby") { SteamLobby.AiRoom = true; SteamLobby.Host(cfg.Name); }
                lastLog = DateTime.Now.ToString("HH:mm:ss ") + L.T("同时开着房间等真人（", "Also hosting a room (") + Modes.Name(m)
                          + L.T("）：有人进来就结束 AI 对战", "): the AI battle ends when a player joins");
            }
            catch (Exception ex)
            {
                waitSes = null;
                Warn(L.T("开不了等人的房间（AI 对战照常）：", "Can't open the room (the AI battle goes on): ") + ex.Message
                     + (ex is SocketException ? L.T("（端口被占用？）", " (port in use?)") : ""));
            }
        }

        void StopWait()
        {
            var w = waitSes;
            if (w == null) return;
            waitSes = null;
            var ais = session;
            if (ais != null && ais.SpecRelay == w) ais.SpecRelay = null;
            SteamLobby.AiRoom = false;
            w.Stop();
            if (waitMode == "steamlobby" && (SteamLobby.Mine != 0 || SteamLobby.Hosting)) SteamLobby.Leave();
            if (waitMode == "server") Upnp.Unmap();
        }

        // §85 等人的房间有真人来了（§85.5 起：状态包或握手都算，PeerSeen）：停掉 AI（两头的连接 + LocalAi），房间转正成正式联机，
        // 连接方式换成房间的方式（面板 / 窗口都按真人联机显示）。游戏那边看到对手不再是 AI（ai=1 没了）就结束 AI 那局（main.lua §85）
        void CheckWait()
        {
            var w = waitSes;
            if (w == null || !w.PeerSeen) return;
            var nick = !string.IsNullOrEmpty(w.T.PeerNick) ? w.T.PeerNick : w.Wire.HelloNick;
            waitSes = null;
            if (ai != null) { ai.Stop(); ai = null; }
            if (aiSession != null) { aiSession.Stop(); aiSession = null; }
            GamePipe.Remove(Path.Combine(dir, "ai"));     // 同 StopSession：AI 的内存交接（§84）不要了
            if (session != null) session.Stop();
            w.Retarget(dir);
            w.Log = x => { lastLog = DateTime.Now.ToString("HH:mm:ss ") + x; };
            session = w;
            fromAi = true;
            realNick = nick;
            lostSince = DateTime.MinValue;
            cfg.Mode = waitMode;
            cfg.Save();
            var who = string.IsNullOrEmpty(nick) ? L.T("有玩家", "A player") : nick + " ";
            lastLog = DateTime.Now.ToString("HH:mm:ss ") + who + L.T("加入了你的房间，AI 对战已关闭（", "joined your room; AI battle closed (") + Modes.Name(waitMode) + L.T("）", ")");
            ApplyLang();
            Tick();
        }

        // §85 从 AI 对战转来的真人联机（用户："XXXX 已离开房间，AI 对战已重新开始"）：对方断了 BackAfter 秒 →
        // 连接方式换回 ai、重开 AI 对战。开关还开着时这个房间退回等人（文件换回 net\wait\，房间号 / 端口不变，
        // 下一个人进来照样转正）；开关关了就关掉房间。自己点"断开"不算（StopSession 清 fromAi）
        bool fromAi;
        string realNick;
        DateTime lostSince = DateTime.MinValue;
        const double BackAfter = 5.0;     // 同模组判"对方掉线"的 LOST_SEC

        void CheckBack()
        {
            var s = session;
            if (!fromAi || s == null || s.Mode == "ai") return;
            if (s.Connected)
            {
                lostSince = DateTime.MinValue;
                if (!string.IsNullOrEmpty(s.T.PeerNick)) realNick = s.T.PeerNick;
                return;
            }
            if (lostSince == DateTime.MinValue) { lostSince = DateTime.UtcNow; return; }
            if ((DateTime.UtcNow - lostSince).TotalSeconds < BackAfter) return;
            fromAi = false;
            lostSince = DateTime.MinValue;
            var nick = string.IsNullOrEmpty(realNick) ? L.T("对方", "The player") : realNick;
            var mode = s.Mode;
            session = null;
            if (cfg.AiRoom && mode == cfg.AiRoomMode)
            {
                var wdir = Path.Combine(dir, "wait");
                s.Retarget(wdir);
                s.Log = x => { lastLog = DateTime.Now.ToString("HH:mm:ss ") + L.T("[等人的房间] ", "[Room] ") + x; };
                waitSes = s;
                waitMode = mode;
            }
            else
            {
                s.Stop();
                if (mode == "steamlobby" && (SteamLobby.Mine != 0 || SteamLobby.Hosting)) SteamLobby.Leave();
                if (mode == "server") Upnp.Unmap();
            }
            cfg.Mode = "ai";
            cfg.Save();
            try { StartAi(nick); }
            catch (Exception ex) { StopSession(); Warn(L.T("重开 AI 对战失败：", "Couldn't restart the AI battle: ") + ex.Message); return; }
            ApplyLang();
            Tick();
        }

        void SetAiRoom(bool on)
        {
            cfg.AiRoom = on;
            cfg.Save();
            if (on && AiRunning && waitSes == null) StartWait();
            else if (!on) StopWait();
            if (aiRoomBox.Checked != on) { loadingMode = true; aiRoomBox.Checked = on; loadingMode = false; }
            Tick();
        }

        void SetAiRoomMode(string m)
        {
            if (Modes.Valid(m) == "ai") { Warn(L.T("开房方式不能是本地 AI", "The room can't use Local AI")); return; }
            m = Modes.ValidRoom(m);
            if (Modes.IsSteam(m) && !Steam.Init()) lastErr = Steam.Error;
            bool changed = m != cfg.AiRoomMode;
            cfg.AiRoomMode = m;
            cfg.Save();
            if (changed && waitSes != null) StartWait();     // 开着的房间换方式：重开
            int i = Array.IndexOf(Modes.Rooms, m);
            if (aiRoomModeBox.SelectedIndex != i) { loadingMode = true; aiRoomModeBox.SelectedIndex = i; loadingMode = false; }
            Tick();
        }

        void StopSession()
        {
            fromAi = false;
            StopWait();
            if (ai != null) { ai.Stop(); ai = null; }
            if (aiSession != null) { aiSession.Stop(); aiSession = null; }
            GamePipe.Remove(Path.Combine(dir, "ai"));
            if (session != null) { session.Stop(); session = null; }
            if (SteamLobby.Mine != 0 || SteamLobby.Hosting) SteamLobby.Leave();
            Upnp.Unmap();
            WriteNone();
            if (IsHandleCreated && !IsDisposed) Tick();
        }

        // 游戏内联机面板的命令：id 变了才执行一次。§84 来源两个，各记各的 id：
        // 游戏经管道发的（内存，每 0.1 秒看一眼不碰硬盘）；cmd.txt（外部工具 / 第二次打开程序写的，FileSystemWatcher 说变了才读；
        // 本程序没开管道时照旧每次读）
        void PollCmd()
        {
            var gp = GamePipe.For(dir);
            if (gp != null && gp.Connected)
            {
                var t = gp.UpText("cmd.txt");
                if (t != null) RunCmd(Kv.Parse(t), true);
            }
            if (gp == null || cmdFileDirty)
            {
                cmdFileDirty = false;
                var d = Kv.Read(CmdPath);
                if (d != null) RunCmd(d, false);
            }
        }

        void RunCmd(Dictionary<string, string> d, bool fromPipe)
        {
            string id, cmd, v;
            if (!d.TryGetValue("id", out id) || id == (fromPipe ? lastPipeCmd : lastCmd)) return;
            if (fromPipe) lastPipeCmd = id; else lastCmd = id;
            ack = id;
            if (!d.TryGetValue("cmd", out cmd)) return;
            lastLog = DateTime.Now.ToString("HH:mm:ss ") + L.T("游戏内面板：", "In-game panel: ") + cmd;
            switch (cmd)
            {
                case "mode": if (d.TryGetValue("mode", out v)) SetMode(v); break;
                case "host": if (session == null || session.Role != "host") StartSession("host", null); break;
                case "join": Join(d.TryGetValue("target", out v) ? v : "", !(d.TryGetValue("remember", out v) && v == "0")); break;   // §116 remember=0 不记最近
                case "spectate": Spectate(d.TryGetValue("target", out v) ? v : ""); break;     // §141 观战（先只有局域网 / 输入 IP）
                case "rotate":     // §141.7 游戏打完一场按规矩换人；§141.8 主机下场时 who = h（第一位）/ c（第二位）谁输了
                    if (session != null) { string who; d.TryGetValue("who", out who); session.Rotate(d.TryGetValue("why", out v) ? v : "", who); }
                    break;
                case "hostdown": if (session != null) session.HostDown(); break;     // §141.8 主机也下场
                case "specq":      // §141 观战者自己：排队上场（on=1）/ 只观战（on=0）。马上生效（下一个观战握手就带上）
                    if (d.TryGetValue("on", out v)) { SpecCfg.NoQueue = v == "0"; if (v != "0") SpecCfg.WantUp(); cfg.Save(); }     // 切回排队：顺带让主机 / 服务器清掉"刚下场、先别叫"
                    break;
                case "maxspec":    // §141 房间设置：观战 / 排队人数上限（马上生效：已经在看的超了也不赶，新来的按新上限）
                    int mx;
                    if (d.TryGetValue("n", out v) && int.TryParse(v, out mx) && mx >= 0 && mx <= 8) { cfg.MaxSpec = mx; SpecCfg.Max = mx; cfg.Save(); }
                    break;
                case "hostup": if (session != null) session.HostUp(); break;
                case "tospec": ToSpec(); SpecCfg.NoQueue = true; cfg.Save(); break;     // §141 自己下去 → 只观战（服务器大厅那条路也一样）     // §141.7 对手自己下去观战
                case "stop": StopSession(); break;
                // v0.18.6：窗口里能改的设置，游戏内面板也都能改（用户 2026-11-04："所有操作都可以在游戏内实现"）
                case "name":
                    if (d.TryGetValue("name", out v) && v.Trim().Length > 0)
                    {
                        v = v.Trim();
                        if (v.Length > 24) v = v.Substring(0, 24);
                        cfg.Name = v; nameBox.Text = v; cfg.Save();
                    }
                    break;
                case "port":
                    int p;
                    if (d.TryGetValue("port", out v) && int.TryParse(v.Trim(), out p) && p > 0 && p < 65536) { cfg.Port = p; portBox.Text = p.ToString(); cfg.Save(); }
                    else Warn(L.T("端口要是 1–65535 的数字", "The port must be a number from 1 to 65535"));
                    break;
                case "secret":   // v0.22.0 联机密码；空 = 清掉（不签名）。联机中不能改：签名是每次联机开始时定的
                    if (d.TryGetValue("secret", out v))
                    {
                        if (session != null) { Warn(L.T("联机中不能改联机密码，先断开", "Disconnect before changing the connection password")); break; }
                        cfg.Secret = v.Trim(); secretBox.Text = cfg.Secret; cfg.Save();
                        lastLog = DateTime.Now.ToString("HH:mm:ss ") + (cfg.Secret.Length > 0 ? L.T("联机密码已设置", "Connection password set") : L.T("联机密码已清除", "Connection password cleared"));
                    }
                    break;
                case "ailevel":   // §75 本地 AI 难度 0–2；对战中也能换
                    {
                        int lv;
                        if (d.TryGetValue("level", out v) && int.TryParse(v.Trim(), out lv) && lv >= 0 && lv <= 2)
                        {
                            cfg.AiLevel = lv; cfg.Save();
                            aiBox.SelectedIndex = lv;
                            if (ai != null) ai.Level = lv;
                            lastLog = DateTime.Now.ToString("HH:mm:ss ") + L.T("AI 难度：", "AI difficulty: ") + LocalAi.LevelName(lv);
                        }
                    }
                    break;
                case "aiload":   // §114 AI 装备：w=<族>|<路径> e=<影之武装路径或空> o=<皮肤行名或空> med=<0–10> acc=<- 或 GA,GA>；给了哪个改哪个，对战中也能换
                    {
                        var nl = cfg.AiLoad.Clone();
                        bool ok = true;
                        if (d.TryGetValue("w", out v)) ok &= nl.SetWeapon(v);
                        if (d.TryGetValue("e", out v)) ok &= nl.SetEdge(v);
                        if (d.TryGetValue("o", out v)) ok &= nl.SetOutfit(v);
                        if (d.TryGetValue("med", out v)) ok &= nl.SetPotions(v);
                        if (d.TryGetValue("acc", out v)) ok &= nl.SetAcc(v);
                        if (!ok) { Warn(L.T("AI 装备的值不合法，没改", "Invalid AI loadout value; nothing changed")); break; }
                        cfg.AiLoad = nl; cfg.Save();
                        if (ai != null) ai.Load = nl.Clone();
                        lastLog = DateTime.Now.ToString("HH:mm:ss ") + L.T("AI 装备已更新", "AI loadout updated");
                    }
                    break;
                case "airoom":       // §85 AI 对战时同时开房等真人：on=0|1
                    if (d.TryGetValue("on", out v)) SetAiRoom(v == "1");
                    break;
                case "airoommode":   // §85 等人的房间的连接方式（不能是 ai）
                    if (d.TryGetValue("mode", out v)) SetAiRoomMode(v);
                    break;
                case "rankudp":   // §135 测试用：武林盟主照旧走 UDP（假对手 fake_join --ranked 开 / 关）
                    if (d.TryGetValue("on", out v)) { Program.RankUdp = v == "1"; lastLog = DateTime.Now.ToString("HH:mm:ss ") + "rankudp=" + v; }
                    break;
                case "relay":   // §102 服务器大厅：允许走服务器中转（连着的也马上生效：主机下次登记时告诉服务器）
                    if (d.TryGetValue("on", out v))
                    {
                        cfg.Relay = v == "1"; cfg.Save();
                        foreach (var x in new[] { session, waitSes })
                        {
                            var xl = x != null ? x.T as ServerLink : null;
                            if (xl != null) xl.AllowRelay = cfg.Relay;
                        }
                    }
                    break;
                case "upnp":
                    if (d.TryGetValue("on", out v)) { cfg.Upnp = v == "1"; upnpBox.Checked = cfg.Upnp; cfg.Save(); }
                    break;
                case "server":   // 大厅服务器地址（服务器大厅方式用）；空 = 清掉
                    if (d.TryGetValue("server", out v))
                    {
                        v = v.Trim();
                        if (v.Length > 0 && LobbyServer.Resolve(v) == null) { Warn(L.T("认不出这个服务器地址：", "Can't resolve this server address: ") + v); break; }
                        cfg.Server = v; srvBox.Text = v; cfg.Save();
                    }
                    break;
                case "lang":
                    if (d.TryGetValue("lang", out v)) { L.En = v == "en"; L.Save(dir); langBox.SelectedIndex = L.En ? 1 : 0; ApplyLang(); }
                    break;
                case "copy":
                    {
                        // §85 AI 对战时开着等人的房间：复制那个房间的地址 / 房间号
                        var a = waitSes != null ? CopyOf(waitMode, waitSes) : CopyAddr();
                        if (a.Length == 0 || a.StartsWith(":")) { Warn(L.T("现在没有可复制的地址（", "No address to copy yet (") + MyAddr() + L.T("）", ")")); break; }
                        try { Clipboard.SetText(a); lastLog = DateTime.Now.ToString("HH:mm:ss ") + L.T("已复制：", "Copied: ") + a; }
                        catch (Exception ex) { Warn(L.T("复制失败：", "Copy failed: ") + ex.Message); }
                    }
                    break;
                case "ranktop":   // §110 排行榜第几页
                    {
                        int pg;
                        Rank.RequestTop(d.TryGetValue("page", out v) && int.TryParse(v.Trim(), out pg) ? pg : 1);
                    }
                    break;
                case "rankstat":   // §110.11 统计页：kind=w 武器 / e 影之武装 / m 招式，page=N
                    {
                        int pg;
                        string kind;
                        d.TryGetValue("kind", out kind);
                        Rank.RequestStats(kind ?? "w", d.TryGetValue("page", out v) && int.TryParse(v.Trim(), out pg) ? pg : 1);
                    }
                    break;
                case "rankexport":   // §110 把排位密钥复制到剪贴板（换电脑用）
                    try { Clipboard.SetText(Rank.ExportKey()); lastLog = DateTime.Now.ToString("HH:mm:ss ") + L.T("排位密钥已复制到剪贴板，别发给别人", "Ranked key copied; keep it private"); }
                    catch (Exception ex) { Warn(L.T("复制失败：", "Copy failed: ") + ex.Message); }
                    break;
                case "rankimport":   // §110 从剪贴板导入排位密钥
                    {
                        string clip = "", why;
                        try { if (Clipboard.ContainsText()) clip = Clipboard.GetText(); } catch (Exception) { }
                        if (Rank.ImportKey(clip, out why)) lastLog = DateTime.Now.ToString("HH:mm:ss ") + L.T("排位密钥已导入", "Ranked key imported");
                        else Warn(why);
                    }
                    break;
                case "steamtest":   // §125 Steam 连接自检（单机），结果在 net\steam_conn.log
                    if (session != null || waitSes != null) Warn(L.T("先断开联机再做 Steam 自检", "Disconnect before the Steam self-test"));
                    else
                    {
                        string tv;
                        ulong target = 0;
                        if (d.TryGetValue("target", out tv)) target = Addr.SteamId(tv);
                        if (Steam.SelfTest(target)) lastLog = DateTime.Now.ToString("HH:mm:ss ") + L.T("Steam 自检开始，约 12 秒，结果写进 net\\steam_conn.log", "Steam self-test started (~12 s), see net\\steam_conn.log");
                        else Warn(Steam.Error);
                    }
                    break;
                case "refresh":   // §91 游戏内面板打开房间列表页：马上重新问一次房间
                    if (Modes.IsServer(Mode)) lobbyList.Refresh();
                    else if (Mode == "steamlobby") SteamLobby.Refresh();
                    break;
                case "show":
                    Show();
                    if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
                    Activate();
                    break;
            }
            Tick();
        }

        // 可加入目标：开房的 Steam 好友 / 局域网房间 → 剪贴板里的地址 → 最近连过的 → Tailscale 在线节点
        void BuildCands()
        {
            cands.Clear();
            var s = session;
            var seen = new HashSet<string>();
            Action<string, string, string> add = (k, label, target) => { if (seen.Add(target)) cands.Add(new[] { k, label, target }); };
            if (Mode == "steam")
            {
                foreach (var f in Steam.FriendsInGame())
                {
                    // §123 没开房的好友单独标 nohost：面板不算"可加入"、排在后面，点了直接提示（以前也标 friend，连过去注定超时）
                    add(f[2] == "1" ? "friend" : "nohost", f[1] + (f[2] == "1" ? L.T("（在开房）", " (hosting)") : L.T("（在玩，没开房）", " (playing, not hosting)")), "steam:" + f[0]);
                    // §141 开房的好友再列一行"观战"（好友状态里看不出满没满：满了就看，没满也能先看着排队）
                    if (f[2] == "1") add("watchf", f[1], "steam:" + f[0]);
                }
            }
            else if (Modes.IsServer(Mode))
            {
                var mine = s != null ? s.T as IRoomLink : null;
                foreach (var r in lobbyList.Poll(cfg.Server))
                {
                    if (mine != null && mine.RoomId == r[0] && (r.Length < 5 || r[4].Trim().Length == 0)) continue;     // 不列自己开的房间
                    // §110 第 6 列 = 排位房间（旧服务器没有这列 = 不是）：服务器大厅只列普通房间，武林盟主只列排位房间；第 7 列 = 称号
                    bool rk = r.Length > 5 && r[5] == "1";
                    if (rk != (Mode == "ranked")) continue;
                    var title = rk && r.Length > 6 && r[6].Trim().Length > 0 ? "【" + r[6].Trim() + "】" : "";
                    // 第 5 列 = 所在服务器（空 = 就是我们连的这台；否则是互通过来的别的服务器，§50）
                    var home = r.Length > 4 ? r[4].Trim() : "";
                    // §141 第 8 列 = 能观战（服务器开了中转、主机认观战）：满了的房间标 watch，点了以观战者身份经服务器看
                    bool watch = r[3] == "1" && r.Length > 7 && r[7] == "1";
                    add(r[3] != "1" ? "room" : watch ? "watch" : "full", (home.Length > 0 ? L.T("[互通] ", "[LINKED] ") : "") + title + r[1] + L.T("  地图 ", "  map ") + r[2]
                                + (r[3] == "1" ? L.T("  已满", "  full") : "") + L.T("  房间号 ", "  code ") + r[0],
                        (watch ? "watch:" : "room:") + r[0] + (home.Length > 0 ? "@" + home : ""));
                    // §141 第 9 列 = 主机在和 AI 对打（没满）：再列一行"观战"
                    if (r[3] != "1" && r.Length > 8 && r[7] == "1" && r[8] == "1" && home.Length == 0)
                        add("watchf", r[1] + L.T("（和 AI 对打中）", " (vs AI)"), "watch:" + r[0]);
                }
            }
            else if (Mode == "steamlobby")
            {
                foreach (var r in SteamLobby.Poll())
                {
                    if (r[0] == SteamLobby.Mine.ToString() || r[4] == Steam.MyId.ToString()) continue;   // 不列自己的大厅
                    // §141 满了、主机认观战（大厅数据 spec=1）的大厅标 watch
                    bool watch = r[3] == "1" && r.Length > 5 && r[5] == "1";
                    add(r[3] != "1" ? "lobby" : watch ? "watch" : "full", r[1] + L.T("  地图 ", "  map ") + r[2] + (r[3] == "1" ? L.T("  已满", "  full") : ""), (watch ? "watch:" : "lobby:") + r[0]);
                    if (r[3] != "1" && r.Length > 6 && r[5] == "1" && r[6] == "1")      // §141 主机在和 AI 对打
                        add("watchf", r[1] + L.T("（和 AI 对打中）", " (vs AI)"), "watch:" + r[0]);
                }
            }
            else if (Mode == "lan")
            {
                foreach (var r in disc.Current())
                {
                    // 不列自己开的房间（同一台机器的每张网卡都会广播一份）
                    if (s != null && s.Role == "host" && r[0].EndsWith(":" + s.T.LocalPort) && myIps.Contains(r[0].Substring(0, r[0].LastIndexOf(':'))))
                        continue;
                    var addr = r[0].EndsWith(":" + Session.GamePort) ? r[0].Substring(0, r[0].LastIndexOf(':')) : r[0];
                    // §141 满了、主机又认观战的房间标 watch（面板上能点"观战"），旧版主机的满房照旧 full（灰）
                    add(r[3] != "1" ? "room" : r[4] == "1" ? "watch" : "full",
                        r[1] + "  " + addr + L.T("  地图 ", "  map ") + r[2] + (r[3] == "1" ? L.T("  已满", "  full") : ""), addr);
                    // §141 主机在和 AI 对打（房间没满、加入 = 替换 AI）：再列一行"观战"
                    if (r[3] != "1" && r[4] == "1" && r.Length > 5 && r[5] == "1")
                        add("watchf", r[1] + L.T("（和 AI 对打中）", " (vs AI)"), addr);
                }
            }
            if (Mode == "ai") return;     // 本地 AI 没有可加入的目标
            string clip = "";
            try { if (Clipboard.ContainsText()) clip = Clipboard.GetText().Trim(); } catch (Exception) { }
            if (Modes.IsServer(Mode))
            {
                if (LooksLikeRoom(clip)) add("clip", L.T("剪贴板：房间号 ", "Clipboard: room ") + clip, "room:" + clip.ToUpperInvariant());
                else if (Addr.LooksLikeIp(clip) && Mode == "server") add("clip", L.T("剪贴板：IP 直连 ", "Clipboard: direct IP ") + clip, clip);
            }
            else if (Modes.IsSteam(Mode) ? Addr.SteamId(clip) != 0 : Addr.LooksLikeIp(clip))
                add("clip", L.T("剪贴板：", "Clipboard: ") + clip, Modes.IsSteam(Mode) ? "steam:" + Addr.SteamId(clip) : clip);
            foreach (var r in cfg.RecentOf(Mode))
                add("recent", L.T("最近：", "Recent: ") + (r.StartsWith("steam:") ? Steam.FriendName(Addr.SteamId(r)) : r), r);
            if (Mode == "lan")
                foreach (var p in Tailscale.Peers()) add("peer", "Tailscale：" + p[1] + "  " + p[0], p[0]);
        }

        // 服务器大厅的房间号：6 位，字母表见服务端 newId
        static bool LooksLikeRoom(string s)
        {
            if (s == null || s.Length != 6) return false;
            foreach (var c in s.ToUpperInvariant()) if ("ABCDEFGHJKMNPQRSTUVWXYZ23456789".IndexOf(c) < 0) return false;
            return true;
        }

        ServerLink MyServerLink { get { var s = session; return s != null ? s.T as ServerLink : null; } }

        // 你的地址（发给朋友）：按连接方式挑
        string MyAddr() { return AddrOf(Mode, session); }

        // m = 连接方式，s = 那种方式的主机连接（§85 等人的房间也用这个）
        string AddrOf(string m, Session s)
        {
            switch (m)
            {
                case "steam": return Steam.Ready ? Steam.MyName + "  SteamID64 " + Steam.MyId : L.T("（Steam 没连上）", "(Steam not connected)");
                case "steamlobby":
                    if (!Steam.Ready) return L.T("（Steam 没连上）", "(Steam not connected)");
                    return SteamLobby.Hosting ? (SteamLobby.Mine != 0 ? L.T("Steam 大厅已公开：", "Steam lobby open: ") + cfg.Name : SteamLobby.Status) : Steam.MyName;
                case "server":
                case "ranked":
                    {
                        var sl = s != null ? s.T as IRoomLink : null;
                        if (cfg.Server.Length == 0) return L.T("（没填大厅服务器：设置里填，可自己架设）", "(no lobby server: set or host one)");
                        // 登记上了只显示房间号（朋友从列表 / 房间号加入，用不着 IP）；还没登记上才给 IP 直连的地址兜底
                        if (sl != null && s.Role == "host")
                            return sl.RoomId.Length > 0 ? L.T("房间号 ", "Room ") + sl.RoomId
                                   : L.T("正在登记到大厅 ", "Listing on ") + cfg.Server + L.T("  IP 直连 ", "  direct IP ") + PublicAddr();
                        return L.T("大厅 ", "Lobby ") + cfg.Server;
                    }
                case "ai": return L.T("本机 AI 对手（不联网）", "Local AI opponent (offline)");
                default:
                    {
                        // 局域网：真实网卡地址；装了 Tailscale / ZeroTier 再带上虚拟网卡地址
                        var lan = BestIp(0);
                        var vl = BestIp(1);
                        if (vl == null) return lan ?? L.T("（没找到局域网网卡）", "(no LAN adapter)");
                        return (lan != null ? lan + "  " : "") + L.T("虚拟 ", "VLAN ") + vl;
                    }
            }
        }

        // 复制给朋友的那一段：Steam 只要 SteamID64，其余是 IP（广域网带端口）
        string CopyAddr() { return CopyOf(Mode, session); }

        string CopyOf(string m, Session s)
        {
            switch (m)
            {
                case "steam": return Steam.Ready ? Steam.MyId.ToString() : "";
                case "steamlobby": return Steam.Ready ? Steam.MyId.ToString() : "";
                // 房间号；还没登记上（大厅服务器连不上）时复制 公网IP:端口，朋友用"输入 IP 直连"
                case "server": { var sl = s != null ? s.T as ServerLink : null; return sl == null ? "" : sl.RoomId.Length > 0 ? sl.RoomId : PublicAddr(); }
                case "ranked": { var sl = s != null ? s.T as IRoomLink : null; return sl == null ? "" : sl.RoomId; }     // §110 排位不能 IP 直连
                case "ai": return "";
                // 局域网：有虚拟网卡（Tailscale / ZeroTier）时复制它——要"发给朋友"的多半不在同一个路由器下，
                // 同一个路由器下的朋友在房间列表里直接能看到房间，用不着地址
                default: return BestIp(1) ?? BestIp(0) ?? "";
            }
        }

        // IP 直连用的地址：UPnP 拿到的公网 IP（没有就本机 IP）+ 设置里的端口
        string PublicAddr()
        {
            return (Upnp.PublicIp.Length > 0 ? Upnp.PublicIp : (BestIp(0) ?? L.T("公网IP", "public-IP"))) + ":" + cfg.Port;
        }

        static string BestIp(int score)
        {
            foreach (var r in IpRows()) if (r.Key == score) return r.Value[0];
            return null;
        }

        string AddrHint()
        {
            switch (Mode)
            {
                case "steam":
                    return L.T("对方在 Steam 好友列表里、也开着游戏和这个模组，选\"Steam 好友\"即可看到你开的房。不用 IP、不用端口转发。",
                               "Your friend sees your room in their list (both need the game with this mod running). No IP or port forwarding needed.")
                           + (Steam.Ready ? "" : "\n" + Steam.Error);
                case "steamlobby":
                    return L.T("用 Steam 自带的大厅：你建房后，所有开着游戏和这个模组、选了\"Steam 大厅\"的人都能在列表里看到（不用加好友）。",
                               "Uses Steam's own lobbies: everyone running the game with this mod on \"Steam lobby\" sees your room (no need to be friends).")
                           + (Steam.Ready ? (SteamLobby.Status.Length > 0 ? "\n" + SteamLobby.Status : "") : "\n" + Steam.Error);
                case "server":
                    return L.T("房间登记在大厅服务器上（右上角填地址）。加入时先试直连（打洞），" + ServerLink.Tries + " 次不通自动改走服务器中转。把房间号发给朋友也行。",
                               "Rooms are listed on the lobby server (address at top right). Joining tries a direct link first (hole punching); after " + ServerLink.Tries + " failures it relays through the server.")
                           + L.T("\n服务器连不上时：主机把路由器的 UDP " + cfg.Port + " 转发到本机（或勾 UPnP），朋友在\"加入\"里填 公网IP:端口 直连。",
                                 "\nIf the server is down: the host forwards UDP " + cfg.Port + " (or ticks UPnP); the friend enters public-IP:port to join directly.")
                           + (Upnp.Status.Length > 0 ? "\n" + Upnp.Status : "")
                           + (lobbyList.Error.Length > 0 ? "\n" + lobbyList.Error : "");
                case "ranked":
                    return L.T("武林盟主（排位）：房间登记在大厅服务器上，和服务器大厅一样建房 / 加入，但只列排位房间；对局走 Steam（两边都要开着 Steam）。打完两边各报结果，对上才记分（Elo，每天同一对人记 3 场）；规则由服务器定（游戏内面板的\"房间设置\"里能看到）。",
                               "Ranked: rooms on the lobby server, host / join like the lobby server but only ranked rooms are listed. Both sides report the result; it counts only if they agree (Elo, 3 rated matches per pair per day). The server sets the rules (see Room rules in the in-game panel).")
                           + (Rank.Me.Length > 0 ? "\n" + L.T("我的分数 ", "My rating ") + Rank.Me.Split('|')[0] : "")
                           + (Rank.Error.Length > 0 ? "\n" + Rank.Error : "")
                           + (lobbyList.Error.Length > 0 ? "\n" + lobbyList.Error : "");
                case "ai":
                    return L.T("和电脑里的 AI 打（照抄你的攻击属性和最大血量，武器 / 影之武装等在游戏内面板的\"AI 装备\"里选），不联网、不用别人。点\"开始 AI 对战\"后 AI 走到你身边，按 F1 开打。",
                               "Fight a computer opponent (copies your attack stats and max health; pick its gear in AI loadout in the in-game panel). Offline. Click \"Start AI battle\", then press F1 to fight.")
                           + L.T("\n勾\"同时开房等真人\"：打 AI 的同时用右边选的方式开一个房间，有人进来就结束 AI 对战、改成和他联机。",
                                 "\nTick \"Also host a room\" to host a room (method on the right) while fighting the AI; when someone joins, the AI battle ends and you play them.")
                           + (waitSes != null ? "\n" + L.T("等人的房间：", "Room: ") + AddrOf(waitMode, waitSes) : "");
                default:
                    return L.T("同一个路由器下，或两边装了同一个 Tailscale / ZeroTier 网络，房间会自动出现在列表里；也可以把地址发给朋友手动加入。",
                               "On the same router, or both on the same Tailscale / ZeroTier network, rooms show up in the list; or send your address.")
                           + "\n" + LocalIps();
            }
        }

        // §141.7 服务器大厅的排队要换连接：观战（WatchLink）轮到上场 → 带口令重新加入；客机被主机换下 → 改成观战连接
        void QueueSwitch()
        {
            var s = session;
            if (s == null) return;
            var wl = s.T as WatchLink;
            if (wl != null && wl.TurnToken != null && SpecCfg.NoQueue) wl.TurnToken = null;     // §141 只观战：服务器叫上场不理
            if (wl != null && wl.TurnToken != null && wl.SpecMode)
            {
                nextToken = wl.TurnToken;
                var room = wl.RoomId;
                NetLog.W("排队：轮到上场，用口令加入房间 " + room);
                StartSession("client", null, 0, room);
                return;
            }
            var sl = s.T as ServerLink;
            if (sl != null && s.Role == "spec" && sl.RoomId.Length > 0)
            {
                nextDown = true;
                var room = sl.RoomId;
                NetLog.W("排队：被换下场，改成观战房间 " + room);
                StartSession("spec", null, 0, room);
            }
        }

        void Tick()
        {
            var s = session;
            QueueSwitch();
            s = session;
            var fLocal = Path.Combine(dir, "state_local.txt");
            var gp = GamePipe.For(dir);      // §83 走管道时 state_local.txt 不再更新
            bool gameOn = (gp != null && gp.Connected) || File.Exists(fLocal) && (DateTime.Now - File.GetLastWriteTime(fLocal)).TotalSeconds < 3;
            var w = waitSes;
            // §110 排位：在武林盟主方式下（或正连着排位房间）往来；不在时也每 30 秒问一下服务器开没开排位（决定列不列这个标签）
            Rank.Poll(cfg.Server, cfg.Name, Mode == "ranked" || (s != null && s.Mode == "ranked"), s);
            cfgFetch.Poll(cfg.Server, dir);     // §158 数值表：填了服务器就拉一份缓存到 srvcfg.txt
            if (ShownKey != shownSupport && !modeBox.DroppedDown)
            {
                if (Mode == "ranked" && Rank.Support == 0 && s == null)
                {
                    lastLog = DateTime.Now.ToString("HH:mm:ss ") + L.T("这台大厅服务器没开武林盟主排位，换回服务器大厅", "This lobby server has no ranked mode; back to the lobby server");
                    cfg.Mode = "server"; cfg.Save();
                }
                ApplyLang();     // 重填连接方式下拉框（里面会再调 Tick，shownSupport 已经更新，不会再进来）
                if (!IsHandleCreated) Tick();
                return;
            }
            if (Modes.IsSteam(Mode) || (w != null && Modes.IsSteam(waitMode))) Steam.Pump();
            if (Mode == "steamlobby" && s != null && s.Role == "host") SteamLobby.Update(cfg.Name, s.LocalMap, s.Connected);
            if (w != null && s != null)
            {
                w.LocalMap = s.LocalMap;     // 等人的房间不读游戏的包，地图跟 AI 对战那边（房间列表里显示）
                if (waitMode == "steamlobby") SteamLobby.Update(cfg.Name, s.LocalMap, false);
            }
            BuildCands();
            ipsBox.Text = MyAddr() + Environment.NewLine + AddrHint().Replace("\n", Environment.NewLine);
            lblJoin.Text = Modes.IsSteam(Mode) ? L.T("加入：SteamID64", "Join: SteamID64")
                         : Modes.IsServer(Mode) ? L.T("加入：房间号", "Join: room code") : L.T("加入：主机 IP[:端口]", "Join: host IP[:port]");
            bool srvMode = Modes.IsServer(Mode);
            bool aiMode = Mode == "ai";
            srvBox.Visible = srvMode;
            aiBox.Visible = aiMode;
            portBox.Visible = upnpBox.Visible = !srvMode && !aiMode;
            aiRoomBox.Visible = aiRoomModeBox.Visible = aiMode;
            lblPort.Text = srvMode ? L.T("大厅", "Lobby") : aiMode ? "AI" : L.T("端口", "Port");
            if (s != null)
            {
                var t = s.T;
                var gpr = GamePipe.For(dir);
                var remote = gpr != null && gpr.Connected ? (gpr.LastRemote != null ? Kv.Parse(gpr.LastRemote) : null)
                                                         : Kv.Read(Path.Combine(dir, "state_remote.txt"));     // §84
                string rmap;
                if (remote != null && remote.TryGetValue("map", out rmap)) s.RemoteMap = rmap;
                var role = s.Role == "host" ? L.T("主机", "Host") : L.T("客机", "Client");
                var nick = !string.IsNullOrEmpty(t.PeerNick) ? t.PeerNick : t.PeerName;
                var who = nick.Length > 0 ? nick + " " : "";
                var conn = s.Connected ? L.T("已连接 ", "Connected ") + who + t.PeerStr
                                       : (s.Role == "host" ? L.T("等待对方…", "Waiting for opponent…") : L.T("连接中… ", "Connecting… ") + who + t.PeerStr);
                var warn = "";
                if (s.Connected && s.RemoteMap != "?" && s.RemoteMap != s.LocalMap)
                    warn = L.T("\n⚠ 两边不在同一张地图：你在 " + s.LocalMap + "，对方在 " + s.RemoteMap + "。请先去同一张地图",
                               "\n⚠ Different maps: you are on " + s.LocalMap + ", opponent on " + s.RemoteMap + ". Go to the same map first");
                var sl = t as IRoomLink;
                if (sl != null) conn += "  [" + RouteName(sl.Route) + "]" + (sl.Error.Length > 0 ? "\n" + sl.Error : "");
                // v0.22.0：签名 / 被拒数 / 可靠事件统计；版本不一致、密码对不上时的提示
                var hint = s.Wire.Hint();
                if (hint.Length > 0) warn += "\n⚠ " + hint;
                status.Text = role + " · " + Modes.Name(s.Mode) + (t.LocalPort > 0 ? L.T("，端口 ", ", port ") + t.LocalPort : "") + "\n" + conn
                              + L.T("\n收包 ", "\nRecv ") + s.RxSeen + L.T("  丢包 ", "  Lost ") + t.Gap
                              + "  ping " + (t.PingMs >= 0 ? Kv.F(t.PingMs, "0") + "ms" : "-")
                              + (s.Wire.Signed ? L.T("  签名开 ", "  Signed ") : "  ") + s.Wire.RejText() + "\n" + s.Rel.StatText() + "\n"
                              + (gameOn ? L.T("游戏运行中，地图 ", "Game running, map ") + s.LocalMap : L.T("游戏未运行 / 未读档", "Game not running / no save loaded")) + warn
                              + (w != null ? L.T("\n同时开着房间等真人（", "\nAlso hosting a room (") + Modes.Name(waitMode) + L.T("）", ")") : "");
            }
            else
            {
                status.Text = L.T("未连接。当主机点“创建房间”；加入别人就填地址点“加入”，或双击下面的一行。\n",
                                  "Not connected. To host, click \"Create room\". To join, enter the address and click \"Join\", or double-click a row below.\n")
                              + (gameOn ? L.T("游戏运行中", "Game running")
                                        : L.T("游戏未运行 / 未读档（先开游戏也行，后开也行）", "Game not running / no save loaded (start it before or after, either works)"));
            }
            logLabel.Text = lastLog;

            // 主机 / 客机互斥：联机中只能"断开"，其余入口灰掉；没联机时"断开"灰掉
            bool busy = s != null;
            hostBtn.Enabled = joinBtn.Enabled = ipBox.Enabled = nameBox.Enabled = roomList.Enabled = modeBox.Enabled = secretBox.Enabled = !busy;
            portBox.Enabled = upnpBox.Enabled = !busy && Modes.IsServer(Mode);
            srvBox.Enabled = !busy;
            stopBtn.Enabled = busy;
            if (s == null)
            {
                roleBig.Text = L.T("未联机", "OFFLINE"); roleBig.ForeColor = Color.Gray;
                roleSub.Text = "";
            }
            else
            {
                bool host = s.Role == "host";
                roleBig.Text = host ? L.T("主  机", "HOST") : L.T("客  机", "CLIENT");
                roleBig.ForeColor = host ? Color.FromArgb(30, 110, 220) : Color.FromArgb(140, 60, 200);
                roleSub.Text = s.Connected ? L.T("● 已连接", "● Connected")
                                           : (host ? L.T("○ 等待对方加入…", "○ Waiting for a player…") : L.T("○ 正在连接主机…", "○ Connecting to host…"));
                roleSub.ForeColor = s.Connected ? Color.FromArgb(20, 150, 60) : Color.FromArgb(200, 120, 0);
            }

            roomList.BeginUpdate();
            roomList.Items.Clear();
            foreach (var c in cands) roomList.Items.Add(c[1]);
            if (cands.Count == 0)
            {
                if (Mode == "lan" && !disc.Ok)
                    roomList.Items.Add(L.T("（房间发现端口 27016 被占用，只能手动输入 IP）", "(Room discovery port 27016 is in use; enter the IP manually)"));
                else if (Mode == "steam")
                    roomList.Items.Add(Steam.Ready ? L.T("（没有好友在玩影之刃零并开着房）", "(No friend is playing and hosting)") : "(" + Steam.Error + ")");
                else if (Mode == "steamlobby")
                    roomList.Items.Add(Steam.Ready ? L.T("（Steam 大厅里没有别人开的房）", "(No rooms in the Steam lobby list)") : "(" + Steam.Error + ")");
                else if (Modes.IsServer(Mode) && lobbyList.Error.Length > 0)
                    roomList.Items.Add("(" + lobbyList.Error + ")");
                else
                    roomList.Items.Add(s != null && s.Role == "host"
                        ? L.T("（你正在当主机；这里只列别人开的房间）", "(You are hosting; only other people's rooms are listed here)")
                        : L.T("（没发现房间。手动输入地址，或者复制到剪贴板）", "(No rooms found. Enter the address, or copy it to the clipboard)"));
            }
            roomList.EndUpdate();
            WriteLobby(true);
            AutoExit(gameOn);
        }

        static string RouteName(string r)
        {
            if (r == "relay") return L.T("服务器中转", "server relay");
            if (r == "steam") return "Steam";                                               // §135 武林盟主
            if (r == "steamwait") return L.T("正在经 Steam 连接", "connecting via Steam");
            if (r == "join") return L.T("向大厅服务器报到", "joining via the lobby server");
            if (r == "direct") return L.T("直连", "direct");
            if (r == "wait") return L.T("等人加入", "waiting");
            if (r == "punch") return L.T("正在打洞", "punching");
            if (r.StartsWith("punch")) return L.T("直连第 " + r.Substring(5) + "/" + ServerLink.Tries + " 次", "direct try " + r.Substring(5) + "/" + ServerLink.Tries);
            return r;
        }

        static string Clean(string v) { return (v ?? "").Replace("\r", " ").Replace("\n", " ").Replace("|", "/"); }

        // net\lobby.txt：给游戏内联机面板（main.lua 的 NETUI）看
        void WriteLobby(bool alive)
        {
            var s = session;
            var sb = new StringBuilder();
            Action<string, string> kv = (k, v) => sb.Append(k).Append('=').Append(Clean(v)).Append('\n');
            kv("alive", alive ? Kv.F(Link.UnixNow(), "0.0") : "0");
            kv("ver", "1");
            kv("lang", L.En ? "en" : "zh");
            kv("mode", Mode);
            kv("role", s == null ? "none" : s.Role);
            kv("connected", s != null && s.Connected ? "1" : "0");
            kv("peer", s == null ? "" : s.T.PeerStr);
            // 对方昵称优先；还没收到（或对方是旧版）时 Steam 用 Steam 名字，直连为空（面板退回显示地址）
            var pn = s == null ? "" : (!string.IsNullOrEmpty(s.T.PeerNick) ? s.T.PeerNick : s.T.PeerName);
            var psl = s != null && s.Mode == "ranked" ? s.T as IRoomLink : null;
            var ptitle = psl != null ? Rank.TitleOf(psl.PeerRk) : "";       // §110 对方是武林盟主：昵称前加称号（称号只由服务器给）
            kv("peername", ptitle.Length > 0 && pn.Length > 0 ? "【" + ptitle + "】" + pn : pn);
            kv("ping", s != null && s.T.PingMs >= 0 ? Kv.F(s.T.PingMs, "0") : "-1");
            kv("port", s == null ? "0" : s.T.LocalPort.ToString());
            kv("myaddr", MyAddr());
            kv("name", cfg.Name);
            kv("cfgport", cfg.Port.ToString());
            kv("upnpon", cfg.Upnp ? "1" : "0");
            kv("relayon", cfg.Relay ? "1" : "0");
            kv("maxspec", cfg.MaxSpec.ToString());     // §141 房间设置：观战人数上限
            kv("specnoq", SpecCfg.NoQueue ? "1" : "0");     // §141 只观战、不排队
            kv("ailevel", cfg.AiLevel.ToString());
            kv("aiw", cfg.AiLoad.Wc);               // §114 AI 装备（面板按这些值标出当前选的是哪个）。Clean 会把 | 换掉，武器拆成路径 + 族两项
            kv("aiwf", cfg.AiLoad.Fam);
            kv("aie", cfg.AiLoad.Edge);
            kv("aio", cfg.AiLoad.Outfit);
            kv("aimed", cfg.AiLoad.Potions.ToString());
            kv("aiacc", cfg.AiLoad.AccWire());
            // §85 AI 对战时同时开房等真人：开关、开房方式、房间开着没有（aiwait=1）、房间地址（服务器大厅 = 房间号）
            var w = waitSes;
            kv("airoom", cfg.AiRoom ? "1" : "0");
            kv("airoommode", cfg.AiRoomMode);
            kv("aiwait", w != null ? "1" : "0");
            kv("aiwaitaddr", w != null ? AddrOf(waitMode, w) : "");
            // v0.22.0：联机密码只告诉游戏"设没设"，不写密码本身；rej = 被拒的包数；hint = 版本 / 密码对不上的提示
            kv("secret", cfg.Secret.Length > 0 ? "1" : "0");
            kv("rej", s != null ? s.Wire.Rejected.ToString() : "0");
            kv("hint", s != null ? s.Wire.Hint(true) : "");     // 短句（面板一行放得下）；窗口里是长句
            kv("app", Proto.App);
            kv("modes", string.Join(",", ShownModes));      // §98 面板只显示联机程序有的方式（发布版没有 Steam 两种）
            // 服务器大厅：srv = 设置里的地址；route = 线路（direct 直连 / relay 中转 / punch1..3 第几次直连 / wait 主机等人）；
            // room = 自己开的房间号；srverr = 服务器那边的问题（没回应 / 没这个房间），面板没联机时也要能看到
            var sl = s != null ? s.T as IRoomLink : null;
            kv("srv", cfg.Server);
            kv("route", sl != null ? sl.Route : "");
            kv("room", sl != null ? sl.RoomId : "");
            kv("srverr", !Modes.IsServer(Mode) ? "" : sl != null ? sl.Error : lobbyList.Error);
            kv("steam", Steam.Ready ? "ok" : (Mode == "steam" ? Steam.Error : "off"));
            kv("upnp", Upnp.Status);
            kv("err", (DateTime.UtcNow - lastErrAt).TotalSeconds < 10 ? lastErr : "");
            kv("msg", lastLog);
            kv("ack", ack ?? "");
            // §91 房间列表还在取第一份：面板显示"正在获取房间…"（局域网 / Steam 好友是现成的，不用等）
            kv("listing", Modes.IsServer(Mode) ? (lobbyList.Listing ? "1" : "0") : Mode == "steamlobby" ? (Steam.Ready && SteamLobby.Listing ? "1" : "0") : "0");
            kv("shown", Visible ? "1" : "0");
#if AOT
            kv("win", "0");     // §122 游戏进程里的 DLL 没有窗口：面板不显示"打开电脑上的联机窗口"
#else
            kv("win", "1");
#endif
            Rank.WriteLobby(sb, Mode == "ranked");     // §110 rk / rkme / rkrules / rktop / rkt1..
            // v0.19.1：8 → 40（跟大厅服务器一次给的上限一样），游戏内面板的"房间列表"页自己分页
            int n = Math.Min(cands.Count, 40);
            kv("n", n.ToString());
            // 目标行自己拼：kv() 会把 | 换掉
            for (int i = 0; i < n; i++)
                sb.Append('t').Append(i + 1).Append('=').Append(cands[i][0]).Append('|').Append(Clean(cands[i][1])).Append('|').Append(Clean(cands[i][2])).Append('\n');
            GamePipe.Out(Path.Combine(dir, "lobby.txt"), sb.ToString());      // §84 连着管道只在内存里（开着文件镜像才写盘）
        }

        // 后台模式（--bg，游戏启动的）：游戏进程没了 3 秒 → 自己退出。
        // v0.18.6：30 秒 → 3 秒，窗口打开过也退。它算游戏的子进程，在跑时 Steam 认为影之刃零还开着、拒绝再启动
        // （18:47 实测：退游戏后马上重开，Steam 报"游戏已在运行"）；v0.18.5 起每次开游戏都会带起它，所以必须跟着游戏一起走
        public bool NoAutoExit;     // 测试用：给了 --seconds 就到时再退，不看游戏进程
        void AutoExit(bool gameOn)
        {
            if (!bg || NoAutoExit) return;
            bool running = gameOn;
            if (!running) { try { running = Process.GetProcessesByName("PBZ").Length > 0; } catch (Exception) { running = true; } }
            if (running) { noGameSince = DateTime.MinValue; return; }
            if (noGameSince == DateTime.MinValue) noGameSince = DateTime.UtcNow;
            else if ((DateTime.UtcNow - noGameSince).TotalSeconds > 3) Quit();
        }

        // 退出。2026-11-04 17:28 实测：从没显示过的窗口调 Close() 不触发 FormClosing / FormClosed，后台进程一直不退
        // （游戏关掉后它还挂在游戏的进程树里，Steam 认为影之刃零还在运行、拒绝再启动）。显示过的走正常关闭；
        // 没显示过的自己做 FormClosing 里的收尾，再直接结束消息循环
        bool quitting;
        public void Quit()
        {
            if (quitting) return;
            // v0.18.7：先立标志再 Close()。19:05 实测窗口打开过时关不掉：Close() → FormClosing → StopSession() → Tick()
            // → AutoExit → Quit() 又 Close() 一次（窗口正在关）→ 抛异常、这次关闭被取消，进程一直挂着，Steam 不让重开游戏
            quitting = true;
            if (Visible) { Close(); return; }
            timer.Stop(); cmdTimer.Stop(); StopSession(); disc.Close(); lobbyList.Close(); cfgFetch.Close(); Steam.Shutdown();
            WriteLobby(false);
            Application.ExitThread();
        }

        // 只读网卡列表，不做主机名解析（Python 版用 getaddrinfo(主机名)，在有些网络环境下要卡好几秒）。
        // 排序：有默认网关的真实网卡 → Tailscale / ZeroTier → 其他 → VMware / Hyper-V 这类虚拟网卡（发给朋友没用）
        static List<KeyValuePair<int, string[]>> IpRows()
        {
            var rows = new List<KeyValuePair<int, string[]>>();
            try
            {
                foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus != OperationalStatus.Up || ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                    var props = ni.GetIPProperties();
                    bool gw = false;
                    foreach (var g in props.GatewayAddresses)
                        if (g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any)) gw = true;
                    var tag = (ni.Name + " " + ni.Description).ToLowerInvariant();
                    foreach (var ua in props.UnicastAddresses)
                    {
                        if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                        var a = ua.Address.ToString();
                        if (a.StartsWith("169.254.")) continue;
                        int score = 5;
                        if (tag.Contains("vmware") || tag.Contains("virtualbox") || tag.Contains("vethernet") || tag.Contains("hyper-v")) score = 9;
                        else if (tag.Contains("tailscale") || tag.Contains("zerotier") || Addr.IsVirtualLan(a)) score = 1;
                        else if (gw) score = 0;
                        rows.Add(new KeyValuePair<int, string[]>(score, new[] { a, ni.Name }));
                    }
                }
            }
            catch (Exception) { }
            rows.Sort((x, z) => x.Key.CompareTo(z.Key));
            return rows;
        }

        static string LocalIps()
        {
            var parts = new List<string>();
            foreach (var r in IpRows())
            {
                var note = r.Key == 0 ? L.T("（局域网）", " (LAN)")
                         : r.Key == 1 ? L.T("（虚拟局域网）", " (virtual LAN)")
                         : r.Key == 9 ? L.T("（虚拟机网卡，一般用不上）", " (VM adapter, usually not useful)") : "";
                parts.Add(r.Value[0] + "  " + r.Value[1] + note);
            }
            return parts.Count > 0 ? string.Join(Environment.NewLine, parts) : "?";
        }
    }


    static class Program
    {
        public static string BaseDir = AppDomain.CurrentDomain.BaseDirectory;   // AOT 版（游戏进程里的 DLL）由 AotEntry 改成 DLL 所在目录
        // §152 单实例锁 / 管道名后缀：exe 版空（一个 net 目录一个联机程序）；DLL 版是 "_p<游戏 pid>"——沙盒里双开时
        // 两份游戏看到的 net 目录路径一样（文件各在各的沙盒里），锁和管道却是全机共用的，不加 pid 第二份就被当成"已经开着"
        public static string InstanceSalt = "";
        public static bool SimNoDirect;     // --sim-no-direct（测试用，见文件头）
        // §135 测试用：武林盟主照旧走 UDP（ServerLink，§110 那条路）。离线测试 / 假对手在一台电脑上没法走 Steam（同一个 Steam 账号连不了自己），
        // 排位上报 / 记分 / 统计靠它测。--rank-udp 或 cmd=rankudp on=1 打开；不存盘、面板里没有
        public static volatile bool RankUdp;
        public static double SimLoss, SimSkew;   // --sim-loss 0..1 / --sim-skew 秒（测试用，见文件头）
        public static bool SimReorder;           // --sim-reorder（测试用）
        public static bool CliSpec;
        public static string CliHostServer, CliJoinRoom;
        public static double CliSpecUpAt = -1;     // --spec-up-at（测试用，§141）：观战者第 N 秒把观战开关切回"排队"
        public static double CliRotateAt = -1, CliStepDownAt = -1, CliHostDownAt = -1, CliHostUpAt = -1;              // --spectate（测试用，§141）：当观战者连 --spectate 给的主机
        public static bool CliSteam;             // --steam（测试用，§120.11）：--host 时经 Steam 桥开房
        public static int LanPort = Session.GamePort;   // --lan-port（测试用，§85.5）：AI 对战时等人的房间用局域网方式时监听的端口，避开开着的游戏占的 27015

        [STAThread]
        static int Main(string[] args)
        {
            WinTimer.Begin();
            try { return Main2(args); }
            finally { WinTimer.End(); }
        }

        internal static int Main2(string[] args)
        {
            string dir = Path.Combine(BaseDir, "net"), log = null, join = null, guiJoin = null, secret = null;
            int port = 0;
            bool host = false, backup = true, bg = false, probe = false, lobbyProbe = false, selfTest = false;
            ulong selfTarget = 0;
            double seconds = 0;
            for (int i = 0; i < args.Length; i++)
            {
                switch (args[i])
                {
                    case "--host": host = true; break;
                    case "--join": join = args[++i]; break;
                    case "--spectate": join = args[++i]; CliSpec = true; break;     // §141 测试：当观战者连主机
                    case "--host-server": CliHostServer = args[++i]; host = true; break;   // §141 测试：经大厅服务器开房
                    case "--join-room": CliJoinRoom = args[++i]; join = "room"; break;     // §141 测试：经大厅服务器加入
                    case "--rotate-at": CliRotateAt = double.Parse(args[++i], CultureInfo.InvariantCulture); break;   // §141.7 测试：主机第 N 秒打完换人
                    case "--spec-up-at": CliSpecUpAt = double.Parse(args[++i], CultureInfo.InvariantCulture); break;
                    case "--step-down-at": CliStepDownAt = double.Parse(args[++i], CultureInfo.InvariantCulture); break;   // §141.7 测试：客机第 N 秒下去观战
                    case "--host-down-at": CliHostDownAt = double.Parse(args[++i], CultureInfo.InvariantCulture); break;   // §141.8 测试：主机第 N 秒下场
                    case "--host-up-at": CliHostUpAt = double.Parse(args[++i], CultureInfo.InvariantCulture); break;
                    case "--max-spec": SpecCfg.Max = int.Parse(args[++i]); break;     // §141 测试：观战人数上限
                    case "--no-queue": SpecCfg.NoQueue = true; break;     // §141 测试：只观战、不排队
                    case "--seconds": seconds = double.Parse(args[++i], CultureInfo.InvariantCulture); break;
                    case "--dir": dir = args[++i]; break;
                    case "--log": log = args[++i]; break;
                    case "--no-backup": backup = false; break;
                    case "--gui-join": guiJoin = args[++i]; break;
                    case "--bg": bg = true; break;
                    case "--steam-probe": probe = true; break;
                    case "--steam-selftest": selfTest = true; if (i + 1 < args.Length && Addr.SteamId(args[i + 1]) != 0) selfTarget = Addr.SteamId(args[++i]); break;
                    case "--steam": CliSteam = true; break;
                    case "--steam-lobby-probe": lobbyProbe = true; break;
                    case "--sim-no-direct": SimNoDirect = true; break;
                    case "--rank-udp": RankUdp = true; break;
                    case "--loopback": NetBind.Loopback = true; break;
                    case "--sim-loss": SimLoss = double.Parse(args[++i], CultureInfo.InvariantCulture); break;
                    case "--sim-reorder": SimReorder = true; break;
                    case "--lan-port": LanPort = int.Parse(args[++i]); break;
                    case "--sim-skew": SimSkew = double.Parse(args[++i], CultureInfo.InvariantCulture); break;
                    case "--secret": secret = args[++i]; break;
                    case "--port": port = int.Parse(args[++i]); break;
                }
            }
            Directory.CreateDirectory(dir);
            Steam.LogDir = dir;     // §125 Steam 连接诊断 net\steam_conn.log
            L.Load(dir);
            if (selfTest)    // §125
            {
                var w2 = new StreamWriter(log ?? Path.Combine(dir, "steam_selftest_cli.log"), false, Kv.Utf8) { AutoFlush = true };
                int r2 = Steam.SelfTestCli(selfTarget, m => w2.WriteLine(DateTime.Now.ToString("HH:mm:ss.fff ") + m));
                w2.Close();
                return r2;
            }
            if (probe || lobbyProbe)
            {
                var w = new StreamWriter(log ?? Path.Combine(dir, lobbyProbe ? "steam_lobby_probe.log" : "steam_probe.log"), false, Kv.Utf8) { AutoFlush = true };
                Action<string> wl = m => w.WriteLine(DateTime.Now.ToString("HH:mm:ss.fff ") + m);
                int r = lobbyProbe ? SteamLobby.Probe(wl) : Steam.Probe(wl);
                w.Close();
                return r;
            }
            if (host || join != null) return RunCli(host, join, seconds, dir, log, backup, secret, port);
            // 单实例（按 net 目录区分，测试时两个 --dir 可以同时开）：已经开着就让它显示窗口，自己退出
            bool created;
            var mutex = new Mutex(true, "Local\\PBZ_MP_Lobby_" + Fnv(Path.GetFullPath(dir).ToLowerInvariant()) + InstanceSalt, out created);
            if (!created)
            {
                if (!bg) Kv.WriteAtomic(Path.Combine(dir, "cmd.txt"), "id=show-" + DateTime.UtcNow.Ticks + "\ncmd=show\n");
                return 0;
            }
            NetLog.Start(dir, true);    // §130 非 Steam 方式的连接诊断 net\net_conn.log（上一份改名 net_conn.prev.log）
            NetLog.W("联机程序启动：" + NetLog.Build + " v" + Proto.App + (bg ? "（后台）" : "（窗口）"));
            var pipe = GamePipe.Start(dir, Fnv(Path.GetFullPath(dir).ToLowerInvariant()) + InstanceSalt);   // §83（§152 DLL 版带 pid）
            pipe.SetDown("lang.txt", "lang=" + (L.En ? "en" : "zh") + "\n");                  // §84 游戏经管道拿语言（只在切换时落盘）
            // §88 诊断：管道的连上 / 断开 / 出错记进 net\pipe_log.txt（只在这些事发生时写，平时不写）
            var pipeLog = Path.Combine(dir, "pipe_log.txt");
            pipe.Log = m => { try { File.AppendAllText(pipeLog, DateTime.Now.ToString("MM-dd HH:mm:ss.fff ") + m + "\r\n", Kv.Utf8); } catch (Exception) { } };
            // §95 诊断：Steam 大厅列表里藏掉的异常大厅记进 net\steamlobby_log.txt（每个大厅只记一次）
            var slLog = Path.Combine(dir, "steamlobby_log.txt");
            SteamLobby.Log = m => { try { File.AppendAllText(slLog, DateTime.Now.ToString("MM-dd HH:mm:ss.fff ") + m + "\r\n", Kv.Utf8); } catch (Exception) { } };
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            var form = new MainForm(dir, backup, guiJoin, bg);
            var hwnd = form.Handle;   // 后台模式不显示窗口，也要先建好句柄：否则 Close() 不触发 FormClosing / FormClosed
            var ctx = new ApplicationContext();
            form.FormClosed += delegate { ctx.ExitThread(); };
            form.NoAutoExit = seconds > 0;
            if (seconds > 0)
            {
                var t = new System.Windows.Forms.Timer { Interval = (int)(seconds * 1000) };
                t.Tick += delegate { t.Stop(); form.Quit(); };
                t.Start();
            }
            if (!bg) form.Show();
            Application.Run(ctx);
            pipe.Stop();
            GC.KeepAlive(mutex);
            return 0;
        }

        internal static string Fnv(string s)
        {
            uint h = 2166136261;
            foreach (var c in s) { h ^= c; h *= 16777619; }
            return h.ToString("x8");
        }

        internal static int RunCli(bool host, string join, double seconds, string dir, string logPath, bool backup, string secret, int port)
        {
            logPath = logPath ?? Path.Combine(dir, "lobby_cli.log");
            var w = new StreamWriter(logPath, false, Kv.Utf8) { AutoFlush = true };
            Action<string> log = m => { lock (w) w.WriteLine(DateTime.Now.ToString("HH:mm:ss.fff ") + m); };
            IPEndPoint peer = null;
            ITransport t = null;
            // §120.11 测试：--steam（主机）/ --join steam:<SteamID64>（客机）走 Steam 桥（tests	est_steam_bridge.py 用假桥）
            if (CliSteam || (join != null && join.StartsWith("steam:")))
            {
                log("这一版不带 Steam"); w.Close(); return 2;
            }
            else if (CliSpec && join.StartsWith("watch:"))
            {
                // §141 测试：--spectate watch:<房间号>@<服务器 IP:端口>
                var rest = join.Substring(6);
                int at = rest.IndexOf('@');
                var sp = rest.Substring(at + 1).Split(':');
                t = new WatchLink(new IPEndPoint(IPAddress.Parse(sp[0]), int.Parse(sp[1])), rest.Substring(0, at), Path.Combine(dir, "state_remote.txt"));
            }
            else if (CliHostServer != null && host)
            {
                // §141 测试：--host-server <服务器 IP:端口> 经服务器大厅开房（ServerLink），房间号写进日志
                var sp = CliHostServer.Split(':');
                var sl = new ServerLink(new IPEndPoint(IPAddress.Parse(sp[0]), int.Parse(sp[1])), null, port, "CLI", Path.Combine(dir, "state_remote.txt"), false);
                sl.AllowRelay = true;
                t = sl;
            }
            else if (CliJoinRoom != null)
            {
                // §141 测试：--join-room <房间号>@<服务器 IP:端口> 经服务器大厅加入
                int at = CliJoinRoom.IndexOf('@');
                var sp = CliJoinRoom.Substring(at + 1).Split(':');
                t = new ServerLink(new IPEndPoint(IPAddress.Parse(sp[0]), int.Parse(sp[1])), CliJoinRoom.Substring(0, at), 0, "CLI", Path.Combine(dir, "state_remote.txt"), false) { AllowRelay = true };
            }
            else if (join != null)
            {
                var p = join.Split(':');
                peer = new IPEndPoint(IPAddress.Parse(p[0]), p.Length > 1 ? int.Parse(p[1]) : Session.GamePort);
            }
            NetLog.Start(dir, false);    // §130 测试：两个进程可能共用一个目录，不改名
            var pipe = GamePipe.Start(dir, Fnv(Path.GetFullPath(dir).ToLowerInvariant()));   // §83（测试里的假游戏也能连）
            pipe.Log = log;
            pipe.SetDown("lang.txt", "lang=" + (L.En ? "en" : "zh") + "\n");
            Session s;
            // 给了 --port 时按非局域网方式（不往 27016 广播房间），不占默认端口，测试可以并行跑
            try { s = new Session(host ? "host" : CliSpec ? "spec" : "client", t is ServerLink || t is WatchLink ? "server" : t != null ? "steam" : port > 0 ? "server" : "lan", t, peer, port > 0 ? port : Session.GamePort, "", dir, backup, secret); }
            catch (SocketException ex) { log("开不了端口：" + ex.Message); return 2; }
            s.Log = log;
            s.Start();
            log("[lobby] " + s.Role + " 端口 " + s.T.LocalPort + " 目录 " + dir);
            var end = seconds > 0 ? DateTime.UtcNow.AddSeconds(seconds) : DateTime.MaxValue;
            var rotateAt = CliRotateAt >= 0 ? DateTime.UtcNow.AddSeconds(CliRotateAt) : DateTime.MaxValue;
            var stepAt = CliStepDownAt >= 0 ? DateTime.UtcNow.AddSeconds(CliStepDownAt) : DateTime.MaxValue;
            var upAt = CliSpecUpAt >= 0 ? DateTime.UtcNow.AddSeconds(CliSpecUpAt) : DateTime.MaxValue;
            var hdAt = CliHostDownAt >= 0 ? DateTime.UtcNow.AddSeconds(CliHostDownAt) : DateTime.MaxValue;
            var huAt = CliHostUpAt >= 0 ? DateTime.UtcNow.AddSeconds(CliHostUpAt) : DateTime.MaxValue;
            var last = DateTime.MinValue;
            long lastLoops = 0, lastSendLoops = 0;
            while (DateTime.UtcNow < end)
            {
                Thread.Sleep(200);
                if (DateTime.UtcNow >= rotateAt) { rotateAt = DateTime.MaxValue; log("[lobby] 打完换人：" + s.Rotate("测试")); }
                if (DateTime.UtcNow >= stepAt) { stepAt = DateTime.MaxValue; log("[lobby] 下去观战：" + s.StepDown()); }
                if (DateTime.UtcNow >= upAt) { upAt = DateTime.MaxValue; SpecCfg.NoQueue = false; SpecCfg.WantUp(); log("[lobby] 切回排队"); }
                if (DateTime.UtcNow >= hdAt) { hdAt = DateTime.MaxValue; log("[lobby] 主机下场：" + s.HostDown()); }
                if (DateTime.UtcNow >= huAt) { huAt = DateTime.MaxValue; log("[lobby] 主机回来打：" + s.HostUp()); }
                // §141.7 测试：服务器大厅排队要换连接（同 MainForm.QueueSwitch）
                var wl = s.T as WatchLink;
                var sl3 = s.T as ServerLink;
                ITransport nt = null;
                string nrole = null;
                if (wl != null && wl.TurnToken != null && SpecCfg.NoQueue) wl.TurnToken = null;
                if (wl != null && wl.TurnToken != null && wl.SpecMode)
                {
                    nt = new ServerLink(wl.Server, wl.RoomId, 0, "CLI", Path.Combine(dir, "state_remote.txt"), false) { AllowRelay = true, JoinToken = wl.TurnToken };
                    nrole = "client";
                }
                else if (sl3 != null && s.Role == "spec" && sl3.RoomId.Length > 0)
                {
                    nt = new WatchLink(sl3.Server, sl3.RoomId, Path.Combine(dir, "state_remote.txt")) { Down = true };
                    nrole = "spec";
                }
                if (nt != null)
                {
                    s.Stop();
                    s = new Session(nrole, "server", nt, null, Session.GamePort, "", dir, backup, secret);
                    s.Log = log;
                    s.Start();
                    log("[lobby] 排队换连接 → " + nrole);
                }
                if ((DateTime.UtcNow - last).TotalSeconds >= 2)
                {
                    double secs = last == DateTime.MinValue ? 0 : (DateTime.UtcNow - last).TotalSeconds;
                    long loops = s.Loops, sendLoops = s.SendLoops;
                    last = DateTime.UtcNow;
                    log("[lobby] " + (s.Connected ? "已连接 " + s.PeerStr : "未连接") + " 收包 " + s.RxSeen + " 发包 " + s.T.Tx
                        + " 地图 " + s.LocalMap + " 缺口 " + s.T.Gap + " " + s.Wire.RejText() + " " + s.Rel.StatText()
                        + (s.Wire.Hint().Length > 0 ? " 提示：" + s.Wire.Hint() : "")
                        + (s.T is Link && s.Role == "host" ? " 观战者 " + s.Spectators + " 转发 " + ((Link)s.T).SpecTx : "")
                        + (s.T is Link && s.Role == "spec" ? " 收到 主机 " + ((Link)s.T).SrcH + " 对手 " + ((Link)s.T).SrcC + " 排第 " + ((Link)s.T).QPos : "")
                        + (s.T is WatchLink ? " 收到 主机 " + ((WatchLink)s.T).SrcH + " 对手 " + ((WatchLink)s.T).SrcC + " 观战人数 " + ((WatchLink)s.T).Watchers + " " + ((WatchLink)s.T).Error : "")
                        + (s.T is ServerLink ? " 房间 " + ((ServerLink)s.T).RoomId + " 观战者 " + ((ServerLink)s.T).Watchers + " 上传 " + ((ServerLink)s.T).WatchTx : "")
                        + " 角色 " + s.Role + " 观战者 " + s.Spectators
                        + (secs > 0 ? " 轮询 收 " + Kv.F((loops - lastLoops) / secs, "0") + " / 发 " + Kv.F((sendLoops - lastSendLoops) / secs, "0") + " 次/秒" : ""));
                    lastLoops = loops;
                    lastSendLoops = sendLoops;
                }
            }
            s.Stop();
            pipe.Stop();
            log("[lobby] 管道：连上 " + pipe.Connects + " 次，收本机包 " + pipe.LocalIn + "，交远端包 " + pipe.RemoteOut + "，取包 " + pipe.Requests + " 次");
            Kv.WriteAtomic(Path.Combine(dir, "session.txt"), "role=none\nconnected=0\npeer=\nt=0\n");
            log("[lobby] 结束");
            w.Close();
            return 0;
        }
    }
}
