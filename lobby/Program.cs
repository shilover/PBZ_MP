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
// 房间发现：主机每秒往 UDP 27016 广播 "PBZROOM|名字|端口|地图|是否已满"，加入方监听同一端口列出来。
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
using System.Windows.Forms;

namespace PbzLobby
{
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
    class Link : ITransport
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

        public Link(int port, IPEndPoint peer, string fRemote)
        {
            outq = new RemoteOut(fRemote);
            Peer = peer;
            lockFirst = peer == null;
            Udp = new UdpClient(new IPEndPoint(IPAddress.Any, port));
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
                // 主机：锁定第一个来的对端；对端 3 秒没动静（比如对方重开了联机窗口，端口变了）就允许换人
                if (lockFirst && (Peer == null || (!from.Equals(Peer) && (DateTime.UtcNow - lastFromPeer).TotalSeconds > 3)))
                {
                    if (Peer == null || !from.Equals(Peer)) Log(L.T("对端锁定为 ", "Peer locked: ") + from);
                    Peer = from;
                    lastSeq = -1;
                }
                if (Peer != null && !from.Equals(Peer)) continue;
                lastFromPeer = DateTime.UtcNow;
                if (wire.Control(s)) continue;     // 可靠事件 / 确认 / 握手（握手包只用来让主机知道往哪回）
                if (s.Contains("hello=1")) continue;
                var d = Kv.Parse(s);
                string seqS;
                int seq;
                if (!d.TryGetValue("seq", out seqS) || !int.TryParse(seqS, out seq)) continue;
                if (seq <= lastSeq && seq > lastSeq - 100) { Stale++; continue; }   // 乱序到达的旧包；回退很多 = 对方重启了游戏
                if (lastSeq >= 0 && seq > lastSeq + 1) Gap += seq - lastSeq - 1;
                lastSeq = seq;
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
                outq.Push(s);
            }
            outq.Flush();
            if (newest != null) PeerNick = Kv.NickOf(newest) ?? PeerNick;
            return got;
        }
    }

    // 一次联机：host 监听固定端口、等第一个对端；client 用随机端口连主机。后台线程里跑
    class Session
    {
        public const int GamePort = 27015, DiscoveryPort = 27016, PollMs = 4;
        public readonly string Role, Name, Mode;
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
        public Action<string> Log = delegate { };
        readonly HashSet<string> backedUp = new HashSet<string>();
        public readonly Wire Wire;            // v0.22.0 包签名（Reliable.cs）
        public readonly RelChannel Rel;       // v0.22.0 可靠事件通道
        readonly SimNet sim = new SimNet();

        // UDP：peer = null 当主机（监听 port），否则连 peer；t 不为空时用它（Steam）。mode = steam | lan | server（server 只在"输入 IP 直连"的客机走这里）
        public Session(string role, IPEndPoint peer, string name, string dir, bool doBackup)
            : this(role, "lan", null, peer, GamePort, name, dir, doBackup, null) { }

        // secret：联机密码，空 = 不签名
        public Session(string role, string mode, ITransport t, IPEndPoint peer, int port, string name, string dir, bool doBackup, string secret)
        {
            Role = role;
            Mode = mode;
            Name = string.IsNullOrEmpty(name) ? Environment.MachineName : name;
            fLocal = Path.Combine(dir, "state_local.txt");
            fSession = Path.Combine(dir, "session.txt");
            T = t ?? new Link(role == "host" ? port : 0, peer, Path.Combine(dir, "state_remote.txt"));
            // 局域网 / 虚拟局域网才广播房间（广域网的朋友收不到广播；Steam 用富状态）
            // 测试给了 --lan-port（不是 27015）时不广播，免得开着的游戏的房间列表里冒出测试房间（§85.5）
            broadcast = role == "host" && mode == "lan" && port == GamePort;
            this.doBackup = doBackup;
            Wire = new Wire(secret) { SimSkewSec = Program.SimSkew };
            Rel = new RelChannel(dir, SendText);
            Wire.Rel = Rel;
            T.Wire = Wire;
        }

        // Session 发出的包都走这里：签名 → （测试时的坏网络）→ 传输
        void SendText(string body) { lock (sendLock) sim.Send(Wire.Seal(body), T.Send); }

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
            thread = new Thread(Run) { IsBackground = true };
            thread.Start();
            sendThread = new Thread(SendLoop) { IsBackground = true };
            sendThread.Start();
            return this;
        }

        public void Stop()
        {
            stop = true;
            if (thread != null) thread.Join(2000);
            if (sendThread != null) sendThread.Join(2000);
            try { T.Close(); } catch (Exception) { }
        }

        void Run()
        {
            DateTime lastBcast = DateTime.MinValue, lastSess = DateTime.MinValue, lastHello = DateTime.MinValue;
            UdpClient bsock = null;
            if (broadcast)
            {
                try { bsock = new UdpClient(); bsock.EnableBroadcast = true; } catch (Exception) { bsock = null; }
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
                Rel.Tick(now);
                lock (sendLock) sim.Flush(T.Send);
                if (bsock != null && (now - lastBcast).TotalSeconds > 1.0)
                {
                    lastBcast = now;
                    var msg = "PBZROOM|" + Name.Replace("|", " ") + "|" + T.LocalPort + "|" + LocalMap + "|" + (Connected ? "1" : "0");
                    var b = Kv.Utf8.GetBytes(msg);
                    // Windows 发 255.255.255.255 只走一张网卡（实测走了 VMware 虚拟网卡，WLAN 上的朋友收不到），
                    // 所以再往每张网卡自己的子网广播地址各发一份
                    foreach (var dst in BroadcastTargets())
                        try { bsock.Send(b, b.Length, new IPEndPoint(dst, DiscoveryPort)); } catch (Exception) { }
                    // Tailscale 不转发广播（ZeroTier 转发，上面的子网广播就够了）：单播给每个在线节点。没装 Tailscale = 空表
                    if (Mode == "lan")
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
                    // v0.22.0：签名 / 拒收 / 可靠事件的统计（窗口状态、测试读这里；Lua 只用前几个键）
                    GamePipe.Out(fSession, "role=" + Role + "\nconnected=" + (Connected ? 1 : 0) + "\npeer=" + PeerStr
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
                        MaybeBackup(loc);
                        var sb = new StringBuilder();
                        foreach (var raw in text.Split('\n'))
                        {
                            var line = raw.TrimEnd('\r');
                            if (line.Length == 0 || line.StartsWith("st=") || line.StartsWith("nm=")
                                || line.StartsWith("pv=") || line.StartsWith("av=")) continue;
                            sb.Append(line).Append('\n');
                        }
                        // v0.22.0：协议版本 / 程序版本，对方据此提示"版本不一致"（旧版没有 pv=）
                        sb.Append("pv=").Append(Proto.Version).Append("\nav=").Append(Proto.App).Append('\n');
                        sb.Append("st=").Append(Kv.F(Link.UnixNow(), "0.0000")).Append('\n');
                        // v0.18.7：带上自己的昵称（用户 2026-11-04 要求连上后面板显示对方昵称；直连方式以前只显示 IP）
                        sb.Append("nm=").Append(Name.Replace("\r", " ").Replace("\n", " ")).Append('\n');
                        SendText(sb.ToString());
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
            ThreadPool.QueueUserWorkItem(delegate { Log(L.T("第 " + id + " 局开始：", "Match " + id + " started: ") + Backup.Run()); });
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
        class Room { public string Name, Map; public bool Full; public DateTime Seen; }
        readonly Dictionary<string, Room> rooms = new Dictionary<string, Room>();
        readonly UdpClient sock;
        public readonly bool Ok;
        volatile bool stop;

        public Discovery()
        {
            try
            {
                sock = new UdpClient();
                sock.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                sock.Client.Bind(new IPEndPoint(IPAddress.Any, Session.DiscoveryPort));
                Ok = true;
                new Thread(Run) { IsBackground = true }.Start();
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
                    lock (rooms) rooms[from.Address + ":" + port] = new Room { Name = p[1], Map = p[3], Full = p[4] == "1", Seen = DateTime.UtcNow };
            }
        }

        public List<string[]> Current()   // {地址:端口, 名字, 地图, 已满}
        {
            var list = new List<string[]>();
            lock (rooms)
                foreach (var kv in rooms)
                    if ((DateTime.UtcNow - kv.Value.Seen).TotalSeconds < 3.5)
                        list.Add(new[] { kv.Key, kv.Value.Name, kv.Value.Map, kv.Value.Full ? "1" : "0" });
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
            modeBox.SelectedIndexChanged += delegate { if (!loadingMode) SetMode(Modes.All[Math.Max(0, modeBox.SelectedIndex)]); };
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
                if (i >= 0 && i < cands.Count) { ipBox.Text = cands[i][2]; Join(cands[i][2]); }
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
            FormClosing += delegate
            {
                quitting = true;          // 关闭过程中 Tick() 再进 AutoExit 时不要再 Quit
                timer.Stop(); cmdTimer.Stop(); StopSession(); disc.Close(); lobbyList.Close(); Steam.Shutdown();
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
            foreach (var m in Modes.All) modeBox.Items.Add(Modes.Name(m));
            modeBox.SelectedIndex = Array.IndexOf(Modes.All, Mode);
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
            if (session != null && m != Mode) { Warn(L.T("联机中不能换连接方式，先断开", "Disconnect before changing the connection")); ApplyLang(); return; }
            cfg.Mode = m;
            cfg.Save();
            lastErr = "";
            if (Modes.IsSteam(m) && !Steam.Init()) lastErr = Steam.Error;
            ApplyLang();
            Tick();
        }

        void Join(string text)
        {
            text = (text ?? "").Trim();
            if (Mode == "ai") { StartSession("host", null); return; }     // 本地 AI 没有"加入"，一律当开始
            if (text.Length == 0)
            {
                Warn(Mode == "steam" ? L.T("先选一个开房的好友，或填主机的 SteamID64", "Pick a friend who is hosting, or enter the host's SteamID64")
                     : Mode == "server" ? L.T("先选一个房间，或填房间号", "Pick a room, or enter the room code")
                     : Mode == "steamlobby" ? L.T("先选一个大厅", "Pick a lobby first")
                     : L.T("先填主机 IP", "Enter the host IP first"));
                return;
            }
            // 服务器大厅里填的是 IP / 域名（带 . 或 :）= 输入 IP 直连（原来的广域网）
            if (Mode == "server" && (text.IndexOf('.') >= 0 || text.IndexOf(':') >= 0) && !text.StartsWith("room:"))
            {
                var dep = Addr.Parse(text, cfg.Port);
                if (dep == null) { Warn(L.T("认不出这个地址：", "Can't resolve this address: ") + text); return; }
                if (StartSession("client", dep, 0)) cfg.Remember(Mode, dep.ToString());
                return;
            }
            if (Mode == "server")
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
                if (StartSession("client", null, id)) cfg.Remember(Mode, "steam:" + id);
                return;
            }
            var ep = Addr.Parse(text, Session.GamePort);
            if (ep == null) { Warn(L.T("认不出这个地址：", "Can't resolve this address: ") + text); return; }
            if (StartSession("client", ep, 0)) cfg.Remember(Mode, ep.Port == Session.GamePort ? ep.Address.ToString() : ep.ToString());
        }

        bool StartSession(string role, IPEndPoint peer) { return StartSession(role, peer, 0, null); }
        bool StartSession(string role, IPEndPoint peer, ulong steamHost) { return StartSession(role, peer, steamHost, null); }

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
                if (Modes.IsSteam(Mode))
                {
                    if (!Steam.Init()) { Warn(Steam.Error); return false; }
                }
                else if (Mode == "server" && !(role == "client" && peer != null))     // 客机输入 IP 直连 = 普通 UDP（下面 t = null）
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
                }
                if (Mode == "ai") return StartAi();
                int port = Mode == "server" ? cfg.Port : Session.GamePort;
                var ses = new Session(role, Mode, t, peer, port, cfg.Name, dir, doBackup, cfg.Secret);
                if (sl != null) sl.MapOf = () => ses.LocalMap;
                session = ses;
                session.Log = m => { lastLog = DateTime.Now.ToString("HH:mm:ss ") + m; };
                session.Start();
                if (Mode == "server" && role == "host" && cfg.Upnp) Upnp.MapAsync(port);
                if (Mode == "steamlobby" && role == "host") SteamLobby.Host(cfg.Name);
            }
            catch (SocketException ex)
            {
                session = null;
                WriteNone();
                Warn(L.T("开不了端口：", "Can't open the port: ") + ex.Message
                     + L.T("（是不是还开着另一个联机窗口 / 幽灵测试？）", " (Is another lobby window or the ghost test still running?)"));
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
            ai = new LocalAi(aiDir, abil) { Level = cfg.AiLevel, BackFrom = backFrom };
            ai.Log = m => { lastLog = DateTime.Now.ToString("HH:mm:ss ") + m; };
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
                ses.Start();
                waitSes = ses;
                waitMode = m;
                if (m == "server" && cfg.Upnp) Upnp.MapAsync(cfg.Port);
                if (m == "steamlobby") SteamLobby.Host(cfg.Name);
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
                case "join": Join(d.TryGetValue("target", out v) ? v : ""); break;
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
                case "airoom":       // §85 AI 对战时同时开房等真人：on=0|1
                    if (d.TryGetValue("on", out v)) SetAiRoom(v == "1");
                    break;
                case "airoommode":   // §85 等人的房间的连接方式（不能是 ai）
                    if (d.TryGetValue("mode", out v)) SetAiRoomMode(v);
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
                case "refresh":   // §91 游戏内面板打开房间列表页：马上重新问一次房间
                    if (Mode == "server") lobbyList.Refresh();
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
                    add("friend", f[1] + (f[2] == "1" ? L.T("（在开房）", " (hosting)") : L.T("（在玩，没开房）", " (playing, not hosting)")), "steam:" + f[0]);
            }
            else if (Mode == "server")
            {
                var mine = s != null ? s.T as ServerLink : null;
                foreach (var r in lobbyList.Poll(cfg.Server))
                {
                    if (mine != null && mine.RoomId == r[0] && (r.Length < 5 || r[4].Trim().Length == 0)) continue;     // 不列自己开的房间
                    // 第 5 列 = 所在服务器（空 = 就是我们连的这台；否则是互通过来的别的服务器，§50）
                    var home = r.Length > 4 ? r[4].Trim() : "";
                    add(r[3] == "1" ? "full" : "room", (home.Length > 0 ? L.T("[互通] ", "[LINKED] ") : "") + r[1] + L.T("  地图 ", "  map ") + r[2]
                                + (r[3] == "1" ? L.T("  已满", "  full") : "") + L.T("  房间号 ", "  code ") + r[0],
                        "room:" + r[0] + (home.Length > 0 ? "@" + home : ""));
                }
            }
            else if (Mode == "steamlobby")
            {
                foreach (var r in SteamLobby.Poll())
                {
                    if (r[0] == SteamLobby.Mine.ToString() || r[4] == Steam.MyId.ToString()) continue;   // 不列自己的大厅
                    add(r[3] == "1" ? "full" : "lobby", r[1] + L.T("  地图 ", "  map ") + r[2] + (r[3] == "1" ? L.T("  已满", "  full") : ""), "lobby:" + r[0]);
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
                    add(r[3] == "1" ? "full" : "room", r[1] + "  " + addr + L.T("  地图 ", "  map ") + r[2] + (r[3] == "1" ? L.T("  已满", "  full") : ""), addr);
                }
            }
            if (Mode == "ai") return;     // 本地 AI 没有可加入的目标
            string clip = "";
            try { if (Clipboard.ContainsText()) clip = Clipboard.GetText().Trim(); } catch (Exception) { }
            if (Mode == "server")
            {
                if (LooksLikeRoom(clip)) add("clip", L.T("剪贴板：房间号 ", "Clipboard: room ") + clip, "room:" + clip.ToUpperInvariant());
                else if (Addr.LooksLikeIp(clip)) add("clip", L.T("剪贴板：IP 直连 ", "Clipboard: direct IP ") + clip, clip);
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
                    {
                        var sl = s != null ? s.T as ServerLink : null;
                        if (cfg.Server.Length == 0) return L.T("（没填大厅服务器：设置里填，可自己架设）", "(no lobby server: set or host one)");
                        if (sl != null && s.Role == "host")
                            return (sl.RoomId.Length > 0 ? L.T("房间号 ", "Room ") + sl.RoomId : L.T("正在登记到大厅 ", "Listing on ") + cfg.Server)
                                   + L.T("  IP 直连 ", "  direct IP ") + PublicAddr();
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
                    return L.T("对方在 Steam 好友列表里、也开着游戏和联机窗口，选\"Steam 好友\"即可看到你开的房。不用 IP、不用端口转发（走 Steam 中继）。",
                               "Your friend sees your room in their list (both need the game and this window open). No IP or port forwarding needed (Steam relay).")
                           + (Steam.Ready ? "" : "\n" + Steam.Error);
                case "steamlobby":
                    return L.T("用 Steam 自带的大厅：你建房后，所有开着游戏和联机窗口、选了\"Steam 大厅\"的人都能在列表里看到（不用加好友）。连接走 Steam 中继。",
                               "Uses Steam's own lobbies: everyone with the game and this window open on \"Steam lobby\" sees your room (no need to be friends). Steam relay.")
                           + (Steam.Ready ? (SteamLobby.Status.Length > 0 ? "\n" + SteamLobby.Status : "") : "\n" + Steam.Error);
                case "server":
                    return L.T("房间登记在大厅服务器上（右上角填地址）。加入时先试直连（打洞），" + ServerLink.Tries + " 次不通自动改走服务器中转。把房间号发给朋友也行。",
                               "Rooms are listed on the lobby server (address at top right). Joining tries a direct link first (hole punching); after " + ServerLink.Tries + " failures it relays through the server.")
                           + L.T("\n服务器连不上时：主机把路由器的 UDP " + cfg.Port + " 转发到本机（或勾 UPnP），朋友在\"加入\"里填 公网IP:端口 直连。",
                                 "\nIf the server is down: the host forwards UDP " + cfg.Port + " (or ticks UPnP); the friend enters public-IP:port to join directly.")
                           + (Upnp.Status.Length > 0 ? "\n" + Upnp.Status : "")
                           + (lobbyList.Error.Length > 0 ? "\n" + lobbyList.Error : "");
                case "ai":
                    return L.T("和电脑里的 AI 打（拿双刃，照抄你的攻击属性、最大血量和影之武装），不联网、不用别人。点\"开始 AI 对战\"后 AI 走到你身边，按 F1 开打。",
                               "Fight a computer opponent (dual blades; copies your attack stats, max health and Phantom Edge). Offline. Click \"Start AI battle\", then press F1 to fight.")
                           + L.T("\n勾\"同时开房等真人\"：打 AI 的同时用右边选的方式开一个房间，有人进来就结束 AI 对战、改成和他联机。",
                                 "\nTick \"Also host a room\" to host a room (method on the right) while fighting the AI; when someone joins, the AI battle ends and you play them.")
                           + (waitSes != null ? "\n" + L.T("等人的房间：", "Room: ") + AddrOf(waitMode, waitSes) : "");
                default:
                    return L.T("同一个路由器下，或两边装了同一个 Tailscale / ZeroTier 网络，房间会自动出现在列表里；也可以把地址发给朋友手动加入。",
                               "On the same router, or both on the same Tailscale / ZeroTier network, rooms show up in the list; or send your address.")
                           + "\n" + LocalIps();
            }
        }

        void Tick()
        {
            var s = session;
            var fLocal = Path.Combine(dir, "state_local.txt");
            var gp = GamePipe.For(dir);      // §83 走管道时 state_local.txt 不再更新
            bool gameOn = (gp != null && gp.Connected) || File.Exists(fLocal) && (DateTime.Now - File.GetLastWriteTime(fLocal)).TotalSeconds < 3;
            var w = waitSes;
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
                         : Mode == "server" ? L.T("加入：房间号", "Join: room code") : L.T("加入：主机 IP[:端口]", "Join: host IP[:port]");
            bool srvMode = Mode == "server";
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
                var sl = t as ServerLink;
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
            portBox.Enabled = upnpBox.Enabled = !busy && Mode == "server";
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
                else if (Mode == "server" && lobbyList.Error.Length > 0)
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
            kv("peername", s == null ? "" : (!string.IsNullOrEmpty(s.T.PeerNick) ? s.T.PeerNick : s.T.PeerName));
            kv("ping", s != null && s.T.PingMs >= 0 ? Kv.F(s.T.PingMs, "0") : "-1");
            kv("port", s == null ? "0" : s.T.LocalPort.ToString());
            kv("myaddr", MyAddr());
            kv("name", cfg.Name);
            kv("cfgport", cfg.Port.ToString());
            kv("upnpon", cfg.Upnp ? "1" : "0");
            kv("ailevel", cfg.AiLevel.ToString());
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
            kv("modes", string.Join(",", Modes.All));      // §98 面板只显示联机程序有的方式（发布版没有 Steam 两种）
            // 服务器大厅：srv = 设置里的地址；route = 线路（direct 直连 / relay 中转 / punch1..3 第几次直连 / wait 主机等人）；
            // room = 自己开的房间号；srverr = 服务器那边的问题（没回应 / 没这个房间），面板没联机时也要能看到
            var sl = s != null ? s.T as ServerLink : null;
            kv("srv", cfg.Server);
            kv("route", sl != null ? sl.Route : "");
            kv("room", sl != null ? sl.RoomId : "");
            kv("srverr", Mode != "server" ? "" : sl != null ? sl.Error : lobbyList.Error);
            kv("steam", Steam.Ready ? "ok" : (Mode == "steam" ? Steam.Error : "off"));
            kv("upnp", Upnp.Status);
            kv("err", (DateTime.UtcNow - lastErrAt).TotalSeconds < 10 ? lastErr : "");
            kv("msg", lastLog);
            kv("ack", ack ?? "");
            // §91 房间列表还在取第一份：面板显示"正在获取房间…"（局域网 / Steam 好友是现成的，不用等）
            kv("listing", Mode == "server" ? (lobbyList.Listing ? "1" : "0") : Mode == "steamlobby" ? (Steam.Ready && SteamLobby.Listing ? "1" : "0") : "0");
            kv("shown", Visible ? "1" : "0");
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
            timer.Stop(); cmdTimer.Stop(); StopSession(); disc.Close(); lobbyList.Close(); Steam.Shutdown();
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
        public static readonly string BaseDir = AppDomain.CurrentDomain.BaseDirectory;
        public static bool SimNoDirect;     // --sim-no-direct（测试用，见文件头）
        public static double SimLoss, SimSkew;   // --sim-loss 0..1 / --sim-skew 秒（测试用，见文件头）
        public static bool SimReorder;           // --sim-reorder（测试用）
        public static int LanPort = Session.GamePort;   // --lan-port（测试用，§85.5）：AI 对战时等人的房间用局域网方式时监听的端口，避开开着的游戏占的 27015

        [STAThread]
        static int Main(string[] args)
        {
            WinTimer.Begin();
            try { return Main2(args); }
            finally { WinTimer.End(); }
        }

        static int Main2(string[] args)
        {
            string dir = Path.Combine(BaseDir, "net"), log = null, join = null, guiJoin = null, secret = null;
            int port = 0;
            bool host = false, backup = true, bg = false, probe = false, lobbyProbe = false;
            double seconds = 0;
            for (int i = 0; i < args.Length; i++)
            {
                switch (args[i])
                {
                    case "--host": host = true; break;
                    case "--join": join = args[++i]; break;
                    case "--seconds": seconds = double.Parse(args[++i], CultureInfo.InvariantCulture); break;
                    case "--dir": dir = args[++i]; break;
                    case "--log": log = args[++i]; break;
                    case "--no-backup": backup = false; break;
                    case "--gui-join": guiJoin = args[++i]; break;
                    case "--bg": bg = true; break;
                    case "--steam-probe": probe = true; break;
                    case "--steam-lobby-probe": lobbyProbe = true; break;
                    case "--sim-no-direct": SimNoDirect = true; break;
                    case "--sim-loss": SimLoss = double.Parse(args[++i], CultureInfo.InvariantCulture); break;
                    case "--sim-reorder": SimReorder = true; break;
                    case "--lan-port": LanPort = int.Parse(args[++i]); break;
                    case "--sim-skew": SimSkew = double.Parse(args[++i], CultureInfo.InvariantCulture); break;
                    case "--secret": secret = args[++i]; break;
                    case "--port": port = int.Parse(args[++i]); break;
                }
            }
            Directory.CreateDirectory(dir);
            L.Load(dir);
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
            var mutex = new Mutex(true, "Local\\PBZ_MP_Lobby_" + Fnv(Path.GetFullPath(dir).ToLowerInvariant()), out created);
            if (!created)
            {
                if (!bg) Kv.WriteAtomic(Path.Combine(dir, "cmd.txt"), "id=show-" + DateTime.UtcNow.Ticks + "\ncmd=show\n");
                return 0;
            }
            var pipe = GamePipe.Start(dir, Fnv(Path.GetFullPath(dir).ToLowerInvariant()));   // §83
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

        static string Fnv(string s)
        {
            uint h = 2166136261;
            foreach (var c in s) { h ^= c; h *= 16777619; }
            return h.ToString("x8");
        }

        static int RunCli(bool host, string join, double seconds, string dir, string logPath, bool backup, string secret, int port)
        {
            logPath = logPath ?? Path.Combine(dir, "lobby_cli.log");
            var w = new StreamWriter(logPath, false, Kv.Utf8) { AutoFlush = true };
            Action<string> log = m => { lock (w) w.WriteLine(DateTime.Now.ToString("HH:mm:ss.fff ") + m); };
            IPEndPoint peer = null;
            if (join != null)
            {
                var p = join.Split(':');
                peer = new IPEndPoint(IPAddress.Parse(p[0]), p.Length > 1 ? int.Parse(p[1]) : Session.GamePort);
            }
            var pipe = GamePipe.Start(dir, Fnv(Path.GetFullPath(dir).ToLowerInvariant()));   // §83（测试里的假游戏也能连）
            pipe.Log = log;
            pipe.SetDown("lang.txt", "lang=" + (L.En ? "en" : "zh") + "\n");
            Session s;
            // 给了 --port 时按非局域网方式（不往 27016 广播房间），不占默认端口，测试可以并行跑
            try { s = new Session(host ? "host" : "client", port > 0 ? "server" : "lan", null, peer, port > 0 ? port : Session.GamePort, "", dir, backup, secret); }
            catch (SocketException ex) { log("开不了端口：" + ex.Message); return 2; }
            s.Log = log;
            s.Start();
            log("[lobby] " + s.Role + " 端口 " + s.T.LocalPort + " 目录 " + dir);
            var end = seconds > 0 ? DateTime.UtcNow.AddSeconds(seconds) : DateTime.MaxValue;
            var last = DateTime.MinValue;
            long lastLoops = 0, lastSendLoops = 0;
            while (DateTime.UtcNow < end)
            {
                Thread.Sleep(200);
                if ((DateTime.UtcNow - last).TotalSeconds >= 2)
                {
                    double secs = last == DateTime.MinValue ? 0 : (DateTime.UtcNow - last).TotalSeconds;
                    long loops = s.Loops, sendLoops = s.SendLoops;
                    last = DateTime.UtcNow;
                    log("[lobby] " + (s.Connected ? "已连接 " + s.PeerStr : "未连接") + " 收包 " + s.RxSeen + " 发包 " + s.T.Tx
                        + " 地图 " + s.LocalMap + " 缺口 " + s.T.Gap + " " + s.Wire.RejText() + " " + s.Rel.StatText()
                        + (s.Wire.Hint().Length > 0 ? " 提示：" + s.Wire.Hint() : "")
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
