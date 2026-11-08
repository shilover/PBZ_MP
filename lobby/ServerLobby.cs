// 服务器大厅（mode=server，docs/HANDOVER.md §47）：自建服务端 server/pbz-lobby-server.mjs 登记 / 列出房间，
// 加入时把双方的公网地址互相告诉对方，两边往对方的地址互发包打洞（UDP hole punching）；
// 直连试 3 次（每次 2.5 秒）都没收到对方的包，就改走服务器中转（服务器开了 --relay 才有，没开会回 ERR …|norelay，客机就一轮轮接着试直连；状态包加 PBZR|<会话号> 头，由服务器转给对方）。
// 协议见服务端文件头。REG / JOIN / 中转都从游戏用的那个 UDP 端口发，服务器看到的才是 NAT 给这个端口的公网地址。
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace PbzLobby
{
    static class LobbyServer
    {
        public const int DefaultPort = 27020;

        // 设置里填的 "域名或IP[:端口]" → 端点；没填或认不出返回 null
        public static IPEndPoint Resolve(string addr) { return Addr.Parse(addr, DefaultPort); }

        // 告诉服务器自己的局域网地址：两边在同一个路由器后面时，公网地址互发不一定通（路由器不支持回环），局域网地址能通
        public static string LocalAddr(int port)
        {
            var ip = Addr.PrimaryLocal();
            return ip == null ? "" : ip + ":" + port;
        }

        public static IPEndPoint ParseEp(string s)
        {
            s = (s ?? "").Trim();
            int c = s.LastIndexOf(':');
            IPAddress ip;
            int port;
            if (c <= 0 || !IPAddress.TryParse(s.Substring(0, c), out ip) || !int.TryParse(s.Substring(c + 1), out port) || port <= 0 || port > 65535) return null;
            return new IPEndPoint(ip, port);
        }

        // 提示里显示的服务器：设置里填的是域名就显示域名（括号里带解析出的 IP），填的是 IP 就只显示 IP（用户 2026-11-06 截图：填的域名，报错却只有 IP）
        public static string Show(string text, IPEndPoint ep)
        {
            text = (text ?? "").Trim();
            if (ep == null) return text;
            int c = text.LastIndexOf(':');
            IPAddress ip;
            if (text.Length == 0 || IPAddress.TryParse(c > 0 ? text.Substring(0, c) : text, out ip)) return ep.ToString();
            return text + "（" + ep + "）";
        }

        public static string Clean(string s) { return (s ?? "").Replace("|", " ").Replace("\t", " ").Replace("\r", " ").Replace("\n", " "); }
    }

    // 收状态包的公共部分（同 Link.Pump）：只要比上一个新的序号、数缺口、按发送时间估延迟、取昵称
    class RxState
    {
        int lastSeq = -1;
        public long Rx, Gap;
        public double DelaySum;
        public long DelayN;
        public string Newest, PeerNick;

        public void Reset() { lastSeq = -1; }

        public bool Take(string s)
        {
            if (s.StartsWith("PBZHELLO") || s.StartsWith("PBZPUNCH") || s.Contains("hello=1")) return false;
            var d = Kv.Parse(s);
            string v;
            int seq;
            if (!d.TryGetValue("seq", out v) || !int.TryParse(v, out seq)) return false;
            if (seq <= lastSeq && seq > lastSeq - 100) return false;
            if (lastSeq >= 0 && seq > lastSeq + 1) Gap += seq - lastSeq - 1;
            lastSeq = seq;
            Rx++;
            double t;
            if (d.TryGetValue("st", out v) && double.TryParse(v, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out t))
            {
                DelaySum += Link.UnixNow() - t;
                DelayN++;
            }
            Newest = s;
            return true;
        }
    }

    // 服务器大厅的一条连接。host：登记房间、等服务器介绍客机；client：JOIN 房间号 → 打洞 → 不通就中转
    // §135 经大厅服务器开房 / 加入的连接共有的那一侧：服务器大厅（ServerLink，UDP 打洞 / 中转）和武林盟主（RankedLink，对局数据走 Steam）。
    // 主程序（房间号、线路、报错、对方昵称前的称号）和排位上报（RankClient.Track：会话号、对方状态包里的 rk= / mt= / quit=）只认这个
    interface IRoomLink
    {
        string RoomId { get; }
        string Sid { get; }                 // 服务器给的会话号（排位上报用）
        string Route { get; }               // 面板的线路（RouteName 翻成文字）
        string Error { get; }
        string RankPid { get; set; }        // 排位房间：自己的 pid（登记 / 加入带上）；null = 普通服务器大厅
        string PeerRk { get; }              // 对方状态包里的 rk= / mt= / quit=（排位房间才取）
        string PeerMt { get; }
        string PeerQuit { get; }
        Action<Dictionary<string, string>> PeerPacket { get; set; }     // §110.11 每个新的对方状态包（排位统计看 res=）
        string ServerName { get; set; }     // 设置里填的服务器地址（提示里显示用，LobbyServer.Show）
        Func<string> MapOf { get; set; }
    }

    class ServerLink : ITransport, IRoomLink, ISpecSink, IQueueHost, IRelayHost
    {
        public const int Tries = 3;              // 用户 2026-11-04 定：直连重试 3 次连不上改走服务器中转
        public const double TryWindow = 2.5;     // 每次直连等多少秒
        const double LostAfter = 6.0;            // 连上后多久没收到对方的包算断了（客机重新走一遍加入，主机重新等人）
        // §134 客机直连 3 次不通、中转也一个包没收到：多半有一方在校园网 / 公司网（严格 NAT、对海外服务器的高频 UDP 限流），只能主动连出去
        public static string BlockedHint { get { return L.T("连不上：如果有一方在校园网 / 公司网，请让对方建房、你来加入",
                                                            "Can't connect: if either of you is on a campus / office network, let the other player host and you join"); } }

        readonly UdpClient udp;
        readonly IPEndPoint server;
        readonly string name, key;
        readonly RemoteOut outq;
        readonly bool host;
        public readonly bool SimNoDirect;        // 测试用（--sim-no-direct）：丢掉所有不是服务器发来的包 = 模拟打洞不通
        public Func<string> MapOf { get; set; }
        public string ServerName { get; set; }
        readonly RxState rx = new RxState();
        long tx;
        Action<string> log = delegate { };
        Wire wire = new Wire(null);
        public Wire Wire { get { return wire; } set { wire = value ?? new Wire(null); } }
        public RemoteOut Out { get { return outq; } }

        string roomId = "", sid, error = "";
        readonly List<IPEndPoint> cands = new List<IPEndPoint>();
        IPEndPoint peer;
        bool relay, relayOk, joined;
        bool blocked;      // §134 中转一直没收到对方的包：BlockedHint 留着，直到直连或中转真的通了
        bool noRelay;      // 服务器没开 --relay（回了 ERR …|norelay / hostnorelay）或自己关了中转：不再进中转，提示留着，一轮轮接着试直连
        // 自己允不允许走服务器中转（设置里的"允许中转"，默认关，HANDOVER §102）。客机关着：直连不通也不请求中转；
        // 主机关着：登记房间时告诉服务器（REG 第 7 段 0），服务器拒绝给这个房间中转；旧服务器不认这一段，主机就不理中转来的包
        public bool AllowRelay;
        // §110 武林盟主：排位房间（主机 REG 第 8、9 段 / 客机 JOIN 第 4 段带上自己的 pid）。null = 普通服务器大厅
        public string RankPid { get; set; }
        // §110 对方状态包里的 rk=（对方 pid）、mt=（主机的对局状态，客机看这个）、quit=（客机弃权的局号，主机看这个）
        public string PeerRk { get; private set; }
        public string PeerMt { get; private set; }
        public string PeerQuit { get; private set; }
        public Action<Dictionary<string, string>> PeerPacket { get; set; }
        // §141 观战：主机把两路包经服务器发给观战者（PBZW|房间号）。Watchers = 服务器在 REGOK 里报的观战人数；
        // OnPeerState = 收到对手的一个状态包（Session 加 src=c 转发）
        public volatile int Watchers;
        public Action<string> OnPeerState { get; set; }
        public long WatchTx;
        public int SpecCount { get { return Watchers; } }
        public void SendSpecs(byte[] b) { SendWatch(b); }
        public bool SpecMode { get { return false; } set { } }      // 服务器大厅的观战者走 WatchLink，不走这里
        public Action<string> OnRole { get; set; }
        public int QPos { get { return 0; } }
        public int QLen { get { return 0; } }
        public string JoinToken;          // §141.7 客机：服务器叫我上场时给的口令（JOIN 第 7 段）
        public volatile bool AiRoom;      // §141 AI 对战时等人的房间：REG 第 14 段 = 1（列表第 9 列，别人能观战 AI 对打）

        // ---- §141.7 排队（主机）：上场由服务器叫（YOURTURN），这里只管让现在的对手下场：发 PBZROLE spec，3 秒后丢掉这个对手
        DateTime demoteAt = DateTime.MinValue;
        public List<object> QueueOrder() { var l = new List<object>(); for (int i = 0; i < Watchers; i++) l.Add(i); return l; }
        public object PromoteHead() { return null; }
        public object DemotePeer()
        {
            if (peer == null && !relay) return null;
            demoteAt = DateTime.UtcNow;
            NetLog.W("排队：让对手下场观战（3 秒后断开，服务器叫队首上场）");
            return "peer";
        }
        public void SendTo(object who, byte[] b) { if ("peer".Equals(who)) Send(b); }
        public bool HasPeer { get { return peer != null || relay; } }
        public double SinceFromPeer { get { return (DateTime.UtcNow - lastFromPeer).TotalSeconds; } }
        public bool CanPromote { get { return Watchers > 0; } }
        void DropPeer()
        {
            demoteAt = DateTime.MinValue;
            sid = null; peer = null; relay = false; relayOk = false; rx.Reset();
            lastFromPeer = DateTime.MinValue;
            cands.Clear();
            NetLog.W("排队：对手已下场，等服务器介绍下一位");
        }

        // ---- §141.8 主机下场：第二位选手由服务器挑（队首）、双向转发（PBZU 发出去 / PBZV 收进来）
        public volatile bool SecondOn;          // 服务器 REGOK 第 6 段
        DateTime lastFrom2 = DateTime.MinValue, lastSecondReq = DateTime.MinValue;
        int lastSeq2 = -1;
        bool wantSecond;
        public Action<string> OnSecondState { get; set; }
        public bool NoOut { get; set; }
        public bool HasSecond { get { return wantSecond && (SecondOn || (DateTime.UtcNow - lastFrom2).TotalSeconds < 3); } }
        public double SinceFromSecond { get { return (DateTime.UtcNow - lastFrom2).TotalSeconds; } }
        public object PromoteSecond()
        {
            if (Watchers == 0) return null;
            wantSecond = true; lastSeq2 = -1; lastFrom2 = DateTime.UtcNow; lastSecondReq = DateTime.MinValue;
            NetLog.W("主机下场：请服务器挑第二位选手");
            return "second";      // 上场通知由服务器发（SECOND），Session 发的 PBZROLE 这里不发（SendTo 只认 "peer"）
        }
        public object DemoteSecond()
        {
            if (!wantSecond) return null;
            wantSecond = false;
            Raw("PBZS|HOSTUP|" + key, server);
            NetLog.W("主机回来打：第二位选手回去观战");
            return null;
        }
        public void SecondToPeer() { DemoteSecond(); }
        public void SendSecond(byte[] b)
        {
            if (!wantSecond || roomId.Length == 0) return;
            var head = Kv.Utf8.GetBytes("PBZU|" + roomId + "\n");
            var pkt = new byte[head.Length + b.Length];
            Buffer.BlockCopy(head, 0, pkt, 0, head.Length);
            Buffer.BlockCopy(b, 0, pkt, head.Length, b.Length);
            tx++;
            Raw(pkt, server);
        }

        // 主机发来的换角色（客机这边）：直连和中转两条路都要看
        bool RoleCtl(string s)
        {
            if (host || !s.StartsWith("PBZROLE", StringComparison.Ordinal)) return false;
            string rv;
            if (Kv.Parse(s).TryGetValue("role", out rv)) { var cb = OnRole; if (cb != null) cb(rv); }
            return true;
        }
        public void SendWatch(byte[] b)
        {
            if (!host || roomId.Length == 0 || Watchers == 0) return;
            var head = Kv.Utf8.GetBytes("PBZW|" + roomId + "\n");
            var pkt = new byte[head.Length + b.Length];
            Buffer.BlockCopy(head, 0, pkt, 0, head.Length);
            Buffer.BlockCopy(b, 0, pkt, head.Length, b.Length);
            WatchTx++;
            Raw(pkt, server);
        }
        int attempt = 1;
        DateTime attemptAt, lastJoin, lastPunch, lastReg, lastRelayReq, lastFromPeer = DateTime.MinValue, lastFromServer = DateTime.MinValue, punchUntil;
        // §130 连接诊断（net\net_conn.log）：只在状态变化时写；计数在每轮打洞 / 每个会话开始时清零
        readonly DateTime born = DateTime.UtcNow;
        DateTime relayAt, relayReqAt, joinAt;
        bool srvAnswered, srvQuietLogged, regLogged, joinLogged, punchEndLogged;
        int unknownPkts, noAckPkts, relayIgnored, relayBadSid;
        long relayRx;
        string noRelayWhy = "", lastErrWhy = "", peerPub = "", peerLocal = "", busySid = "";

        // host：roomOrNull = null；client：要加入的房间号
        public ServerLink(IPEndPoint server, string roomOrNull, int port, string name, string fRemote, bool simNoDirect)
        {
            this.server = server;
            outq = new RemoteOut(fRemote);
            this.name = name;
            MapOf = () => "?";
            ServerName = "";
            SimNoDirect = simNoDirect;
            host = roomOrNull == null;
            if (!host) roomId = roomOrNull.Trim().ToUpperInvariant();
            key = Guid.NewGuid().ToString("N");
            udp = new UdpClient(new IPEndPoint(NetBind.Addr, port));
            try { udp.Client.IOControl(-1744830452, new byte[] { 0, 0, 0, 0 }, null); } catch (Exception) { }   // 同 Link：忽略 ICMP 端口不可达
            attemptAt = DateTime.UtcNow;
        }

        public string RoomId { get { return roomId; } }
        public IPEndPoint Server { get { return server; } }
        public string Sid { get { return sid; } }       // §110 服务器给的会话号（排位上报用）
        public bool Relay { get { return relay; } }
        public string Error { get { return error; } }
        public int LocalPort { get { return ((IPEndPoint)udp.Client.LocalEndPoint).Port; } }
        public string PeerStr { get { return relay ? L.T("经服务器中转", "via server relay") : (peer != null ? peer.ToString() : ""); } }
        // §130 诊断里写的（地址脱敏）
        public string PeerDiag { get { return relay ? "经服务器中转" : peer != null ? NetLog.Ip(peer) : "（还没有）"; } }
        public string ServerDiag
        {
            get
            {
                var t = (ServerName ?? "").Trim();
                foreach (var c in t) if (char.IsLetter(c)) return t + "（" + NetLog.Ip(server) + "）";
                return NetLog.Ip(server);     // 填的是 IP（或互通过来的房间）：也脱敏
            }
        }
        static string Ms(DateTime from, DateTime now) { return (int)(now - from).TotalMilliseconds + " ms"; }
        string Cand(IPEndPoint ep) { int i = cands.IndexOf(ep); return i == 0 ? "公网候选" : i == 1 ? "内网候选" : "不在候选里"; }
        public string PeerName { get { return ""; } }
        public string PeerNick { get { return rx.PeerNick; } }
        public long Tx { get { return tx; } }
        public long Gap { get { return rx.Gap; } }
        public double PingMs { get { return rx.DelayN > 0 ? rx.DelaySum / rx.DelayN * 2000 : -1; } }
        public Action<string> Log { get { return log; } set { log = value ?? delegate { }; } }

        // 给面板看的线路：host = wait / punch / direct / relay；client = punch1..3 / relay / direct；服务器没回应 = noserver
        public string Route
        {
            get
            {
                if (relay) return "relay";
                if (peer != null) return "direct";
                if (host) return sid != null && DateTime.UtcNow < punchUntil ? "punch" : "wait";
                return "punch" + attempt;
            }
        }

        bool ServerQuiet { get { return (DateTime.UtcNow - lastFromServer).TotalSeconds > 5; } }

        static bool Starts(byte[] d, string head)
        {
            if (d.Length < head.Length) return false;
            for (int i = 0; i < head.Length; i++) if (d[i] != (byte)head[i]) return false;
            return true;
        }

        void Raw(string text, IPEndPoint to) { Raw(Kv.Utf8.GetBytes(text), to); }
        void Raw(byte[] b, IPEndPoint to) { try { udp.Send(b, b.Length, to); } catch (Exception) { } }

        public void Send(byte[] b)
        {
            if (relay)
            {
                if (sid == null) return;
                var head = Kv.Utf8.GetBytes("PBZR|" + sid + "\n");
                var pkt = new byte[head.Length + b.Length];
                Buffer.BlockCopy(head, 0, pkt, 0, head.Length);
                Buffer.BlockCopy(b, 0, pkt, head.Length, b.Length);
                tx++;
                Raw(pkt, server);
                return;
            }
            if (peer == null) return;   // 还在打洞：握手包由 Pump 里的打洞代替
            tx++;
            Raw(b, peer);
        }

        public int Pump()
        {
            var now = DateTime.UtcNow;
            int got = 0;
            while (true)
            {
                int avail;
                try { avail = udp.Available; } catch (Exception) { break; }
                if (avail <= 0) break;
                IPEndPoint from = null;
                byte[] data;
                try { data = udp.Receive(ref from); } catch (Exception) { break; }
                if (from.Equals(server)) { got += FromServer(data, now); continue; }
                if (SimNoDirect) continue;
                if (relay) continue;     // 已经改走中转：之后到的直连包不理（免得两条路来回切）
                // v0.20.3 输入 IP 直连：主机还没有客机时，也收陌生地址发来的包（握手 / 状态），其余只收认识的地址
                bool known = from.Equals(peer) || cands.Contains(from);
                if (!known && !(host && peer == null && sid == null))
                {
                    if (unknownPkts++ == 0)
                        NetLog.W("收到不在候选里的地址 " + NetLog.Ip(from) + " 的包，丢掉（对方的 NAT 可能给这次连接换了端口）；候选："
                                 + string.Join(" / ", cands.ConvertAll(NetLog.Ip).ToArray()));
                    continue;
                }
                // 打洞包（PBZPUNCH / 打洞用的 PBZHELLO sid=）是这一层自己的，不签名；其余先验签（v0.22.0）
                string text;
                if (Starts(data, "PBZPUNCH") || Starts(data, "PBZHELLO\nsid=")) text = Kv.Utf8.GetString(data);
                else
                {
                    var to = from;
                    text = wire.Verify(data, 0, data.Length, b => Raw(b, to));
                    if (text == null) continue;
                }
                if (!known && (text.StartsWith("PBZHELLO") || text.Contains("hello=1") || text.Contains("seq=")))
                {
                    peer = from;
                    rx.Reset();
                    log(L.T("客机用 IP 直连进来：", "Direct-IP client: ") + from);
                    NetLog.W("客机用 IP 直连进来：" + NetLog.Ip(from) + "（第一个包 " + Link.Head(text) + "）");
                }
                if (!from.Equals(peer) && !cands.Contains(from)) continue;
                if (peer == null)
                {
                    // 客机要确认是双向通的：主机的打洞包带 ack=1（= 主机收到过我们的包）或已经是状态包才算直连。
                    // 只有"主机 → 客机"通的时候（客机的包到不了主机），没有这一步客机会以为连上了、永远不改走中转
                    if (!host && text.StartsWith("PBZ") && text.IndexOf("ack=1", StringComparison.Ordinal) < 0)
                    {
                        if (noAckPkts++ == 0) NetLog.W("收到主机的打洞包（" + Cand(from) + "）但没带 ack：主机→客机通了，客机→主机还没通，接着打洞");
                        continue;
                    }
                    peer = from;
                    rx.Reset();
                    log(L.T("直连成功：", "Direct connection: ") + from + (host ? "" : L.T("（第 " + attempt + " 次）", " (try " + attempt + ")")));
                    NetLog.W("直连成功：" + NetLog.Ip(from) + "（" + Cand(from) + (host ? "" : "，第 " + attempt + " 次，这次打洞 " + Ms(attemptAt, now)) + "）");
                    if (noRelay || blocked) { error = ""; blocked = false; }
                }
                lastFromPeer = now;
                if (RoleCtl(text) || wire.Control(text)) continue;
                if (rx.Take(text)) { got++; if (!NoOut) outq.Push(text); var fw = OnPeerState; if (fw != null) fw(text); }
            }
            outq.Flush();   // 每轮写一个（RemoteOut，HANDOVER §72.10）
            if (got > 0) TakeNewest();
            if (host && demoteAt != DateTime.MinValue && (now - demoteAt).TotalSeconds > 3.2) DropPeer();
            if (host && wantSecond && !SecondOn && (now - lastSecondReq).TotalSeconds > 2) { lastSecondReq = now; Raw("PBZS|HOSTDOWN|" + key, server); }
            if (host) HostTick(now); else ClientTick(now);
            ServerWatch(now);
            return got;
        }

        // §130 大厅服务器有没有回应：第一次回应、5 秒没回应、恢复各写一行
        void ServerWatch(DateTime now)
        {
            if (lastFromServer != DateTime.MinValue && !ServerQuiet)
            {
                if (!srvAnswered) NetLog.W(srvQuietLogged ? "大厅服务器恢复回应" : "大厅服务器有回应（开始后 " + Ms(born, lastFromServer) + "）");
                srvAnswered = true; srvQuietLogged = false;
                return;
            }
            if (srvQuietLogged || (lastFromServer == DateTime.MinValue && (now - born).TotalSeconds < 5)) return;
            srvQuietLogged = true; srvAnswered = false;
            NetLog.W(lastFromServer == DateTime.MinValue ? "大厅服务器 5 秒都没回应：服务器 " + ServerDiag + "（地址填错 / 服务器没开 / 本机防火墙挡了 UDP）"
                                                         : "大厅服务器 5 秒没回应了");
        }

        // 最新的对方状态包：昵称；§110 排位房间再取 rk= / mt= / quit=
        void TakeNewest()
        {
            var s = rx.Newest;
            rx.PeerNick = Kv.NickOf(s) ?? rx.PeerNick;
            if (RankPid == null || s == null) return;
            var d = Kv.Parse(s);
            string v;
            if (d.TryGetValue("rk", out v)) PeerRk = v;
            if (d.TryGetValue("mt", out v)) PeerMt = v;
            if (d.TryGetValue("quit", out v)) PeerQuit = v;
            var cb = PeerPacket;
            if (cb != null) cb(d);
        }

        int FromServer(byte[] data, DateTime now)
        {
            lastFromServer = now;
            if (host && data.Length > 5 && data[0] == 'P' && data[1] == 'B' && data[2] == 'Z' && data[3] == 'V' && data[4] == '|')
            {
                // §141.8 第二位选手经服务器发来的包
                int nl2 = Array.IndexOf(data, (byte)'\n');
                if (nl2 < 0 || !wantSecond) return 0;
                var b2 = wire.Verify(data, nl2 + 1, data.Length - nl2 - 1, x => { });
                if (b2 == null) return 0;
                lastFrom2 = now;
                if (b2.StartsWith("PBZ", StringComparison.Ordinal) || b2.Contains("hello=1")) return 0;
                string q2s;
                int q2;
                if (!Kv.Parse(b2).TryGetValue("seq", out q2s) || !int.TryParse(q2s, out q2)) return 0;
                if (q2 <= lastSeq2 && q2 > lastSeq2 - 100) return 0;
                lastSeq2 = q2;
                var cb2 = OnSecondState;
                if (cb2 != null) cb2(b2);
                return 0;
            }
            if (data.Length > 5 && data[0] == 'P' && data[1] == 'B' && data[2] == 'Z' && data[3] == 'R' && data[4] == '|')
            {
                // 中转来的状态包：PBZR|<会话号>\n<包>
                int nl = Array.IndexOf(data, (byte)'\n');
                if (nl < 0 || sid == null || Encoding.ASCII.GetString(data, 5, nl - 5) != sid)
                {
                    if (relayBadSid++ == 0) NetLog.W("收到中转包但会话号对不上（本机 " + (sid ?? "没有会话") + "），丢掉");
                    return 0;
                }
                if (!relay)
                {
                    if (!host || !AllowRelay)
                    {
                        if (relayIgnored++ == 0) NetLog.W(host ? "收到中转来的包，但本机设置里没允许中转，丢掉" : "还在打洞时收到中转包，丢掉");
                        return 0;
                    }
                    relay = true; peer = null; rx.Reset(); relayAt = now; relayRx = 0;
                    log(L.T("对方改走服务器中转", "Peer switched to server relay"));
                    NetLog.W("对方改走服务器中转（收到第一个中转包时切过来）");
                }
                var body = wire.Verify(data, nl + 1, data.Length - nl - 1, Send);
                if (body == null) return 0;
                if (blocked) { error = ""; blocked = false; }
                if (relayRx++ == 0) NetLog.W("中转收到对方第一个包（" + Link.Head(body) + "，切到中转后 " + Ms(relayAt, now) + "）");
                lastFromPeer = now;
                if (RoleCtl(body) || wire.Control(body) || !rx.Take(body)) return 0;
                if (!NoOut) outq.Push(body);   // 中转来的也要排队写（§72.10 漏了这条路，中转时对方状态一帧都写不出去）
                var fw2 = OnPeerState;
                if (fw2 != null) fw2(body);
                TakeNewest();
                return 1;
            }
            var f = Kv.Utf8.GetString(data).Split('|');
            if (f.Length < 2 || f[0] != "PBZS") return 0;
            switch (f[1])
            {
                case "REGOK":
                    int wn;
                    if (f.Length > 4 && int.TryParse(f[4], out wn)) Watchers = wn;     // §141 观战人数（旧服务器没有这段）
                    SecondOn = f.Length > 5 && f[5] == "1";                             // §141.8 有没有第二位
                    if (f.Length > 2 && roomId != f[2])
                    {
                        roomId = f[2]; log(L.T("房间已登记到大厅：", "Room listed on the lobby server: ") + roomId);
                        NetLog.W("房间已登记：房间号 " + roomId + "（开始后 " + Ms(born, now) + "）");
                    }
                    error = "";
                    break;
                case "PEER":
                    if (f.Length < 6) break;
                    OnPeer(f[3], f[4], f[5], now);
                    break;
                case "ERR":
                    var why = f.Length > 3 ? f[3] : "";
                    if (why != lastErrWhy)
                    {
                        lastErrWhy = why;
                        NetLog.W("大厅服务器报错 " + why + "：" + (why == "norelay" ? "服务器没开中转" : why == "hostnorelay" ? "主机关了中转"
                                 : why == "nofound" ? "没有这个房间（" + roomId + "）" : why == "full" ? "房间已满" : "（见面板提示）")
                                 + (relay && !relayOk ? "（请求中转后 " + Ms(relayReqAt, now) + "）" : ""));
                    }
                    if (why == "norelay" || why == "hostnorelay")
                    {
                        bool byHost = why == "hostnorelay";
                        if (!noRelay) log(byHost ? L.T("主机关了中转，接着试直连", "The host does not allow relay; retrying direct")
                                                 : L.T("大厅服务器没开中转，接着试直连", "The lobby server has no relay; retrying direct"));
                        noRelay = true;
                        noRelayWhy = why;
                        error = byHost ? L.T("直连不通，主机关了中转：主机转发端口或用 Tailscale", "Direct failed, the host does not allow relay")
                                       : L.T("直连不通，服务器没开中转：主机转发端口或用 Tailscale", "Direct failed, server has no relay");
                        if (!host && relay && !relayOk)   // 中转等不来：回去重新加入、再打几轮洞（等中转时直连包是不收的）
                        {
                            NetLog.W("中转用不了（" + why + "），重新加入再试直连");
                            Restart(now);
                        }
                        break;
                    }
                    error = why == "nofound" ? L.T("大厅里没有这个房间（" + roomId + "）", "No such room on the lobby server (" + roomId + ")")
                          : why == "full" ? L.T("房间已满", "The room is full")
                          // §110 排位房间
                          : why == "noranked" ? L.T("这台大厅服务器没开武林盟主排位", "This lobby server has no ranked mode")
                          : why == "unknown" ? L.T("排位账号还没登记上，稍等几秒", "Ranked account not registered yet, wait a few seconds")
                          : why == "ranked" ? L.T("这是武林盟主排位房间：用\"武林盟主\"方式加入", "This is a ranked room: join it from Ranked")
                          : L.T("大厅服务器报错：", "Lobby server error: ") + why;
                    break;
                case "RELAYOK":
                    if (f.Length > 2 && f[2] == sid && !relayOk)
                    {
                        relayOk = true; log(L.T("服务器中转已就绪", "Server relay ready"));
                        NetLog.W("服务器同意中转（RELAYOK，请求后 " + Ms(relayReqAt, now) + "）");
                    }
                    break;
                case "RELAYON":
                    // 刚切过来时还没收到中转的包：从现在起算"多久没动静"，不然主机会马上当成对方走了
                    if (f.Length > 2 && f[2] == sid && !relay && AllowRelay)
                    {
                        relay = true; peer = null; rx.Reset(); lastFromPeer = now; relayAt = now; relayRx = 0;
                        log(L.T("对方改走服务器中转", "Peer switched to server relay"));
                        NetLog.W("服务器通知对方改走中转（RELAYON）");
                    }
                    else if (f.Length > 2 && f[2] == sid && !relay && relayIgnored++ == 0) NetLog.W("服务器通知对方改走中转，但本机设置里没允许中转，不理");
                    break;
            }
            return 0;
        }

        void OnPeer(string newSid, string pub, string local, DateTime now)
        {
            if (host)
            {
                // 正连着一个人（3 秒内有包）时不换人；服务器那边也会因为"已满"拒掉新的加入
                if (newSid != sid && (now - lastFromPeer).TotalSeconds < 3)
                {
                    if (busySid != newSid) { busySid = newSid; NetLog.W("正连着人，忽略新的加入（会话 " + newSid + "）"); }
                    return;
                }
                if (newSid != sid)
                {
                    sid = newSid; peer = null; relay = false; rx.Reset();
                    log(L.T("有人要加入（", "A player is joining (") + pub + L.T("），开始打洞", "), punching"));
                    NetLog.W("有人要加入：会话 " + newSid + "，对方公网 " + NetLog.Ip(pub) + "，内网 " + NetLog.Ip(local) + "，开始打洞");
                    peerPub = pub; peerLocal = local; unknownPkts = noAckPkts = relayIgnored = relayBadSid = 0; relayRx = 0;
                }
                else if (pub != peerPub || local != peerLocal)
                {
                    NetLog.W("客机重试，地址变了：公网 " + NetLog.Ip(pub) + "，内网 " + NetLog.Ip(local) + "（NAT 每次换端口 = 对称型 NAT，打洞很难通）");
                    peerPub = pub; peerLocal = local;
                }
                else NetLog.W("客机重试（同一会话），再打一轮洞");
                punchEndLogged = false;
                punchUntil = now.AddSeconds(Tries * TryWindow + 2);
            }
            else
            {
                if (sid == null) log(L.T("服务器介绍主机地址 ", "Host address from the lobby server: ") + pub + (local.Length > 0 ? " / " + local : ""));
                if (sid != newSid || pub != peerPub || local != peerLocal)
                    NetLog.W("服务器给主机地址：公网 " + NetLog.Ip(pub) + "，内网 " + NetLog.Ip(local) + "（会话 " + newSid + "，JOIN 后 " + Ms(joinAt, now) + "），开始第 " + attempt + " 次打洞");
                peerPub = pub; peerLocal = local;
                sid = newSid;
                joined = true;
                if (!noRelay && !blocked) error = "";      // 没中转 / 连不上的提示留着，直到直连真的通了
            }
            cands.Clear();
            var a = LobbyServer.ParseEp(pub);
            var b = LobbyServer.ParseEp(local);
            if (a != null) cands.Add(a);
            if (b != null && !b.Equals(a)) cands.Add(b);
        }

        void Punch(DateTime now, string what)
        {
            if ((now - lastPunch).TotalSeconds < 0.2 || sid == null) return;
            lastPunch = now;
            foreach (var c in cands) Raw(what, c);
        }

        void HostTick(DateTime now)
        {
            if ((now - lastReg).TotalSeconds > 2)
            {
                lastReg = now;
                bool full = (now - lastFromPeer).TotalSeconds < 3;
                if (!regLogged) { regLogged = true; NetLog.W("开始登记房间：大厅服务器 " + ServerDiag + "，本机内网 " + NetLog.Ip(LobbyServer.LocalAddr(LocalPort)) + "，允许中转 " + (AllowRelay ? "是" : "否") + "（每 2 秒一次）"); }
                Raw("PBZS|REG|" + key + "|" + LobbyServer.Clean(name) + "|" + LobbyServer.Clean(MapOf()) + "|" + (full ? "1" : "0")
                    + "|" + LobbyServer.LocalAddr(LocalPort) + "|" + (AllowRelay ? "1" : "0")
                    + (RankPid != null ? "|1|" + RankPid + "||" : "|0|||") + (SpecCfg.Max > 0 ? "1" : "0") + "|" + SpecCfg.Max + "|" + (AiRoom ? "1" : "0"), server);     // §141 第 12 段 = 认观战（排位房间服务器不给看），第 13 段 = 人数上限
                if (lastFromServer == DateTime.MinValue ? (now - attemptAt).TotalSeconds > 5 : ServerQuiet)
                    error = L.T("大厅服务器没回应：", "The lobby server is not answering: ") + LobbyServer.Show(ServerName, server);
            }
            // 收到客机的包之后也接着打：带 ack=1 告诉客机"你的包我收到了"（客机靠它确认双向通）
            if (!relay && now < punchUntil) Punch(now, "PBZPUNCH\nsid=" + sid + "\n" + (peer != null ? "ack=1\n" : ""));
            if (sid != null && peer == null && !relay && now >= punchUntil && !punchEndLogged)
            {
                punchEndLogged = true;
                NetLog.W("打洞时间到了，还没收到客机的包（不在候选里的包 " + unknownPkts + " 个）：等客机重试或改走中转");
            }
            // 对方走了：清掉，等下一个人
            if ((peer != null || relay) && (now - lastFromPeer).TotalSeconds > LostAfter)
            {
                log(L.T("对方 " + LostAfter + " 秒没动静，房间重新开放", "No packets for " + LostAfter + " s, room open again"));
                NetLog.W("对方 " + LostAfter + " 秒没动静，房间重新开放（之前" + (relay ? "经中转，中转收包 " + relayRx + " 个" : "直连 " + NetLog.Ip(peer))
                         + "，这个会话收状态包 " + rx.Rx + " 个）");
                peer = null; relay = false; relayOk = false; sid = null; cands.Clear();
            }
        }

        void ClientTick(DateTime now)
        {
            if (relay)
            {
                if (!relayOk && !noRelay && (now - lastRelayReq).TotalSeconds > 0.5) { lastRelayReq = now; Raw("PBZS|RELAY|" + sid, server); }
                if ((now - lastFromPeer).TotalSeconds > LostAfter + (relayOk ? 0 : 4))
                {
                    log(L.T("中转也断了，重新加入", "Relay lost, joining again"));
                    NetLog.W((relayRx == 0 ? "中转一直没收到对方的包" : "中转断了") + "，重新加入（服务器同意中转 " + (relayOk ? "是" : "否")
                             + "，中转收包 " + relayRx + " 个，" + (relayRx == 0 ? "切到中转后 " + Ms(relayAt, now) : "最后收包在 " + Ms(lastFromPeer, now) + " 前") + "）");
                    if (relayRx == 0) { blocked = true; error = BlockedHint; }
                    Restart(now);
                }
                return;
            }
            if (peer != null)
            {
                if ((now - lastFromPeer).TotalSeconds > LostAfter)
                {
                    log(L.T("直连断了，重新加入", "Direct link lost, joining again"));
                    NetLog.W("直连断了：" + LostAfter + " 秒没收到对方的包，重新加入");
                    Restart(now);
                }
                return;
            }
            // 打洞中：没拿到会话前每 0.5 秒发 JOIN；拿到后每 0.2 秒往主机的公网 / 局域网地址发握手
            if (!joined && (now - lastJoin).TotalSeconds > 0.5)
            {
                lastJoin = now;
                if (!joinLogged) { joinLogged = true; joinAt = now; NetLog.W("发加入请求（JOIN）：房间 " + roomId + "，本机内网 " + NetLog.Ip(LobbyServer.LocalAddr(LocalPort)) + "，第 " + attempt + " 次"); }
                Raw("PBZS|JOIN|" + roomId + "|" + LobbyServer.LocalAddr(LocalPort) + (RankPid != null ? "|" + RankPid : "")
                    + (JoinToken != null ? (RankPid != null ? "" : "|") + "||" + JoinToken : ""), server);     // §141.7 第 7 段 = 上场口令
            }
            Punch(now, "PBZHELLO\nsid=" + sid + "\n");
            if ((now - attemptAt).TotalSeconds < TryWindow) return;
            if (sid == null)
            {
                // 连服务器都没回：没法中转，一直重试 JOIN
                if (error.Length == 0 || ServerQuiet) error = L.T("大厅服务器没回应：", "The lobby server is not answering: ") + LobbyServer.Show(ServerName, server);
                attemptAt = now;
                return;
            }
            if (attempt < Tries)
            {
                attempt++;
                attemptAt = now;
                joined = false;                // 重新 JOIN 一次：服务器重发 PEER 给主机，主机再打一轮洞
                joinLogged = false;
                log(L.T("直连没通，第 " + attempt + " 次重试", "No direct link yet, try " + attempt));
                NetLog.W("第 " + (attempt - 1) + " 次直连 " + TryWindow + " 秒没通（不在候选里的包 " + unknownPkts + " 个，没带 ack 的打洞包 " + noAckPkts + " 个）");
                unknownPkts = noAckPkts = 0;
                return;
            }
            if (!AllowRelay && !noRelay)
            {
                noRelay = true;
                noRelayWhy = "本机没允许中转";
                error = L.T("直连不通，你关了中转：主机转发端口、用 Tailscale，或在设置里允许中转", "Direct failed and relay is off in your settings");
                log(L.T("直连 " + Tries + " 次都没通，设置里没允许中转，重新加入再试", "Direct failed " + Tries + " times, relay is off in settings; joining again"));
                NetLog.W("直连 " + Tries + " 次都没通，本机设置里没允许中转，重新加入再试");
                Restart(now);
                return;
            }
            if (noRelay)
            {
                // 已经知道服务器没开中转：不再进中转，从头再来一轮直连（对方开了端口转发 / UPnP 之后就能连上）
                log(L.T("直连 " + Tries + " 次都没通，服务器没开中转，重新加入再试", "Direct failed " + Tries + " times, no relay on the server; joining again"));
                NetLog.W("直连 " + Tries + " 次都没通，中转用不了（" + noRelayWhy + "），重新加入再试");
                Restart(now);
                return;
            }
            relay = true;
            relayOk = false;
            lastFromPeer = now;
            rx.Reset();
            relayAt = relayReqAt = now; relayRx = 0;
            log(L.T("直连 " + Tries + " 次都没通，改走服务器中转", "Direct failed " + Tries + " times, using server relay"));
            NetLog.W("直连 " + Tries + " 次都没通（最后一次：不在候选里的包 " + unknownPkts + " 个，没带 ack 的打洞包 " + noAckPkts + " 个），请求服务器中转（RELAY）");
        }

        void Restart(DateTime now)
        {
            peer = null; relay = false; relayOk = false; joined = false; sid = null; cands.Clear();
            attempt = 1; attemptAt = now; rx.Reset();
            joinLogged = false; lastErrWhy = ""; unknownPkts = noAckPkts = relayIgnored = relayBadSid = 0; relayRx = 0;
        }

        public void Close()
        {
            if (host) Raw("PBZS|UNREG|" + key, server);
            NetLog.W(host ? "关房间：向大厅服务器注销" : "客机离开");
            try { udp.Close(); } catch (Exception) { }
        }
    }

    // 不在联机时也要列房间：自己一个 UDP 口，每 2 秒问一次服务器（界面线程的 Tick 里调，不阻塞）
    // §141 服务器大厅观战：观战者只跟大厅服务器说话（PBZS|WATCH 保活），主机上传的两路包由服务器原样转来（PBZW|房间号\n<包>）。
    // 不打洞、不连主机，所以观战者在什么网络都能看；要服务器开了中转。观战者不发状态包（Send 什么都不做）
    class WatchLink : ITransport, ISpecSink
    {
        readonly UdpClient udp;
        readonly IPEndPoint server;
        readonly string roomId;
        readonly RemoteOut outq;
        readonly Dictionary<string, int> srcSeq = new Dictionary<string, int>();
        DateTime lastWatch = DateTime.MinValue, lastFromServer = DateTime.MinValue;
        Action<string> log = delegate { };
        Wire wire = new Wire(null);
        long tx, gap;
        public long SrcH, SrcC, Stale;
        public volatile int Watchers;
        public string Error = "";
        string nick;
        public bool Down;                       // §141.7 刚下场的：WATCH 带 down，服务器先不叫我上场
        public volatile string TurnToken;       // §141.7 服务器叫我上场（YOURTURN）的口令
        public int SpecCount { get { return 0; } }
        public void SendSpecs(byte[] b) { }
        public Action<string> OnPeerState { get; set; }
        bool specMode = true;
        public bool SpecMode { get { return specMode; } set { specMode = value; } }      // §141.8 false = 当第二位选手（经服务器和主机互发）
        public Action<string> OnRole { get; set; }
        public int QPos { get; private set; }
        int lastSeqU = -1;
        public int QLen { get { return Watchers; } }

        public IPEndPoint Server { get { return server; } }

        public WatchLink(IPEndPoint server, string room, string fRemote)
        {
            this.server = server;
            roomId = (room ?? "").Trim().ToUpperInvariant();
            outq = new RemoteOut(fRemote);
            udp = new UdpClient(new IPEndPoint(NetBind.Addr, 0));
            try { udp.Client.IOControl(-1744830452, new byte[] { 0, 0, 0, 0 }, null); } catch (Exception) { }
        }

        public string RoomId { get { return roomId; } }
        public int LocalPort { get { return ((IPEndPoint)udp.Client.LocalEndPoint).Port; } }
        public string PeerStr { get { return L.T("观战房间 ", "watching room ") + roomId; } }
        public string PeerName { get { return ""; } }
        public string PeerNick { get { return nick; } }
        public long Tx { get { return tx; } }
        public long Gap { get { return gap; } }
        public double PingMs { get { return -1; } }
        public Action<string> Log { get { return log; } set { log = value ?? delegate { }; } }
        public Wire Wire { get { return wire; } set { wire = value ?? new Wire(null); } }
        public RemoteOut Out { get { return outq; } }
        // §141.8 当第二位选手时：自己的状态包经服务器发给主机（PBZV）；观战时什么都不发
        public void Send(byte[] b)
        {
            if (specMode) return;
            var head = Kv.Utf8.GetBytes("PBZV|" + roomId + "\n");
            var pkt = new byte[head.Length + b.Length];
            Buffer.BlockCopy(head, 0, pkt, 0, head.Length);
            Buffer.BlockCopy(b, 0, pkt, head.Length, b.Length);
            tx++;
            try { udp.Send(pkt, pkt.Length, server); } catch (Exception) { }
        }
        public void Close()
        {
            try { var b = Kv.Utf8.GetBytes("PBZS|UNWATCH|" + roomId); udp.Send(b, b.Length, server); } catch (Exception) { }
            try { udp.Close(); } catch (Exception) { }
        }

        public int Pump()
        {
            var now = DateTime.UtcNow;
            if ((now - lastWatch).TotalSeconds > 2)
            {
                lastWatch = now;
                tx++;
                // 第 4 段 down = 刚下场；第 5 段 noq = 只观战、不排队（§141）
                try { var b = Kv.Utf8.GetBytes("PBZS|WATCH|" + roomId + "|" + (SpecCfg.Up ? "up" : Down ? "down" : "") + (SpecCfg.NoQueue ? "|noq" : "")); udp.Send(b, b.Length, server); } catch (Exception) { }
                if (lastFromServer != DateTime.MinValue && (now - lastFromServer).TotalSeconds > 6)
                    Error = L.T("大厅服务器没回应", "The lobby server is not answering");
            }
            int got = 0;
            while (true)
            {
                int avail;
                try { avail = udp.Available; } catch (Exception) { break; }
                if (avail <= 0) break;
                IPEndPoint from = null;
                byte[] data;
                try { data = udp.Receive(ref from); } catch (Exception) { break; }
                if (!from.Equals(server)) continue;
                lastFromServer = now;
                if (data.Length > 5 && data[0] == 'P' && data[1] == 'B' && data[2] == 'Z' && data[3] == 'U' && data[4] == '|')
                {
                    // §141.8 主机经服务器转给我（第二位选手）的包：对手的状态包，不带 src
                    if (specMode) continue;
                    int nlu = Array.IndexOf(data, (byte)'\n');
                    if (nlu < 0) continue;
                    var bu = wire.Verify(data, nlu + 1, data.Length - nlu - 1, x => { });
                    if (bu == null || wire.Control(bu)) continue;
                    string qs;
                    int qu;
                    if (!Kv.Parse(bu).TryGetValue("seq", out qs) || !int.TryParse(qs, out qu)) continue;
                    if (qu <= lastSeqU && qu > lastSeqU - 100) continue;
                    lastSeqU = qu;
                    got++;
                    nick = Kv.NickOf(bu) ?? nick;
                    outq.Push(bu);
                    continue;
                }
                if (data.Length > 5 && data[0] == 'P' && data[1] == 'B' && data[2] == 'Z' && data[3] == 'W' && data[4] == '|')
                {
                    if (!specMode) continue;
                    int nl = Array.IndexOf(data, (byte)'\n');
                    if (nl < 0) continue;
                    var body = wire.Verify(data, nl + 1, data.Length - nl - 1, b => { });
                    if (body == null || wire.Control(body)) continue;
                    var d = Kv.Parse(body);
                    string seqS, src;
                    int seq;
                    if (!d.TryGetValue("seq", out seqS) || !int.TryParse(seqS, out seq) || !d.TryGetValue("src", out src)) continue;
                    int ls;
                    if (!srcSeq.TryGetValue(src, out ls)) ls = -1;
                    if (seq <= ls && seq > ls - 100) { Stale++; continue; }
                    if (ls >= 0 && seq > ls + 1) gap += seq - ls - 1;
                    srcSeq[src] = seq;
                    if (src == "h") { SrcH++; nick = Kv.NickOf(body) ?? nick; } else SrcC++;
                    got++;
                    outq.Push(body);
                    continue;
                }
                var f = Kv.Utf8.GetString(data).Split('|');
                if (f.Length < 3 || f[0] != "PBZS") continue;
                int n;
                if (f[1] == "WATCHOK")
                {
                    Error = "";
                    if (f.Length > 3 && int.TryParse(f[3], out n)) Watchers = n;
                    if (f.Length > 4 && int.TryParse(f[4], out n)) QPos = n;
                }
                else if (f[1] == "SECOND" && f.Length > 3)
                {
                    bool on = f[3] == "1";
                    if (on == specMode) { lastSeqU = -1; var cb = OnRole; if (cb != null) cb(on ? "client" : "spec"); }
                }
                else if (f[1] == "YOURTURN" && f.Length > 3 && TurnToken == null)
                {
                    TurnToken = f[3];
                    log(L.T("轮到你上场了", "Your turn to play"));
                    NetLog.W("排队：服务器叫我上场");
                }
                else if (f[1] == "ERR")
                {
                    var why = f.Length > 3 ? f[3] : "";
                    var e = why == "nofound" ? L.T("大厅里没有这个房间（" + roomId + "）", "No such room (" + roomId + ")")
                          : why == "nowatch" ? L.T("这个房间的主机是旧版，不能观战", "The host's version does not support spectating")
                          : why == "norelay" ? L.T("这台大厅服务器没开中转，不能观战", "This lobby server has no relay, so no spectating")
                          : why == "watchfull" ? L.T("观战人数满了", "Too many spectators")
                          : why == "ranked" ? L.T("武林盟主排位房间不能观战", "Ranked rooms can't be watched")
                          : L.T("大厅服务器报错：", "Lobby server error: ") + why;
                    if (e != Error) { Error = e; log(e); NetLog.W("观战：" + e); }
                }
            }
            outq.Flush();
            return got;
        }
    }

    // §158 数值表（标准数值基准 + 武器平衡）从大厅服务器拉：填了服务器地址就问一次 PBZS|CFGQ|<我有的哈希>，之后每 10 分钟再问（服务器上的表可能改了）。
    // 服务器回 PBZS|CFG|<哈希>|<第几块>|<共几块>|<内容>（内容里本来就有 |，只按前 5 个 | 切）；共 0 块 = 我的已经是最新 / 服务器没有（哈希 -）。
    // 收齐、FNV-1a 哈希对得上才写 net\srvcfg.txt（h= / s=），Lua 启动和每场开局前读它；服务器没开 --cfg 时不回，什么都不写。
    class CfgFetch
    {
        UdpClient sock;
        IPEndPoint server;
        string serverText = null, have = "", partsHash = null;
        string[] parts;
        DateTime lastAsk = DateTime.MinValue, nextAsk = DateTime.MinValue;
        public const int AskEverySec = 600, RetrySec = 5;

        public static string Fnv(string s)
        {
            uint h = 0x811c9dc5;
            foreach (var b in Kv.Utf8.GetBytes(s)) { h ^= b; h *= 0x01000193; }
            return h.ToString("x8");
        }

        public void Poll(string addr, string dir)
        {
            var now = DateTime.UtcNow;
            addr = (addr ?? "").Trim();
            if (addr != serverText)
            {
                serverText = addr;
                server = null;
                nextAsk = now;
                Close();
                have = ReadHave(dir);
            }
            if (addr.Length == 0) return;
            if (server == null)
            {
                if (now < nextAsk) return;
                server = LobbyServer.Resolve(addr);
                if (server == null) { nextAsk = now.AddSeconds(30); return; }
            }
            if (sock == null)
            {
                try
                {
                    sock = new UdpClient(new IPEndPoint(NetBind.Addr, 0));
                    try { sock.Client.IOControl(-1744830452, new byte[] { 0, 0, 0, 0 }, null); } catch (Exception) { }
                }
                catch (Exception) { sock = null; nextAsk = now.AddSeconds(30); return; }
            }
            while (true)
            {
                int avail;
                try { avail = sock.Available; } catch (Exception) { break; }
                if (avail <= 0) break;
                IPEndPoint from = null;
                byte[] data;
                try { data = sock.Receive(ref from); } catch (Exception) { break; }
                if (!from.Equals(server)) continue;
                var f = Kv.Utf8.GetString(data).Split(new[] { '|' }, 6);
                if (f.Length < 6 || f[0] != "PBZS" || f[1] != "CFG") continue;
                int i, n;
                if (!int.TryParse(f[3], out i) || !int.TryParse(f[4], out n)) continue;
                if (n == 0)
                {
                    nextAsk = now.AddSeconds(AskEverySec);     // 已经是最新 / 服务器没有
                    if (f[2] != have && f[2] != "-") NetLog.W("数值表：服务器说是 " + f[2] + "，本地缓存 " + (have == "" ? "（没有）" : have));
                    continue;
                }
                if (n > 200 || i < 1 || i > n) continue;
                if (partsHash != f[2] || parts == null || parts.Length != n) { partsHash = f[2]; parts = new string[n]; }
                parts[i - 1] = f[5];
                bool all = true;
                foreach (var x in parts) if (x == null) { all = false; break; }
                if (!all) continue;
                var text = string.Concat(parts);
                parts = null;
                if (Fnv(text) != partsHash) { NetLog.W("数值表：服务器发来的收齐了但哈希对不上（" + Fnv(text) + " ≠ " + partsHash + "），不用"); continue; }
                try
                {
                    var tmp = Path.Combine(dir, "srvcfg.txt.tmp");
                    File.WriteAllText(tmp, "h=" + partsHash + "\ns=" + text + "\nend=1\n", Kv.Utf8);
                    var dst = Path.Combine(dir, "srvcfg.txt");
                    if (File.Exists(dst)) File.Delete(dst);
                    File.Move(tmp, dst);
                    have = partsHash;
                    NetLog.W("数值表：从服务器拿到 " + have + "（" + text.Length + " 字节），写进 srvcfg.txt");
                }
                catch (Exception ex) { NetLog.W("数值表：写 srvcfg.txt 失败：" + ex.Message); }
                nextAsk = now.AddSeconds(AskEverySec);
            }
            if (now >= nextAsk && (now - lastAsk).TotalSeconds >= RetrySec)
            {
                lastAsk = now;
                var b = Kv.Utf8.GetBytes("PBZS|CFGQ|" + (have == "" ? "-" : have));
                try { sock.Send(b, b.Length, server); } catch (Exception) { }
            }
        }

        static string ReadHave(string dir)
        {
            try
            {
                foreach (var line in File.ReadAllLines(Path.Combine(dir, "srvcfg.txt"), Kv.Utf8))
                    if (line.StartsWith("h=")) return line.Substring(2).Trim();
            }
            catch (Exception) { }
            return "";
        }

        public void Close() { if (sock != null) { try { sock.Close(); } catch (Exception) { } sock = null; } }
    }

    class LobbyList
    {
        UdpClient sock;
        IPEndPoint server;
        string serverText = "";
        DateTime lastAsk = DateTime.MinValue, lastAnswer = DateTime.MinValue;
        List<string[]> rooms = new List<string[]>();   // {房间号, 名字, 地图, 已满[, 所在服务器（空 = 这台）]}
        public string Error = "";

        public List<string[]> Poll(string addr)
        {
            var now = DateTime.UtcNow;
            if (addr != serverText)
            {
                serverText = addr;
                server = null;
                rooms = new List<string[]>();
                lastAnswer = DateTime.MinValue;
                lastAsk = DateTime.MinValue;
                startedAt = DateTime.MinValue;
                listOk = listQuietLogged = false;
                Error = "";
            }
            if (server == null && (now - lastAsk).TotalSeconds > 5)
            {
                lastAsk = now;
                server = LobbyServer.Resolve(addr);
                if (server == null)
                {
                    Error = addr.Trim().Length == 0 ? L.T("先在设置里填大厅服务器地址（可自己架设）", "Set or host a lobby server first")
                                                     : L.T("认不出大厅服务器地址：", "Can't resolve the lobby server: ") + addr;
                    return rooms;
                }
                lastAsk = DateTime.MinValue;
            }
            if (server == null) return rooms;
            if (sock == null)
            {
                try
                {
                    sock = new UdpClient(new IPEndPoint(NetBind.Addr, 0));
                    try { sock.Client.IOControl(-1744830452, new byte[] { 0, 0, 0, 0 }, null); } catch (Exception) { }
                }
                catch (Exception ex) { Error = ex.Message; return rooms; }
            }
            while (true)
            {
                int avail;
                try { avail = sock.Available; } catch (Exception) { break; }
                if (avail <= 0) break;
                IPEndPoint from = null;
                byte[] data;
                try { data = sock.Receive(ref from); } catch (Exception) { break; }
                if (!from.Equals(server)) continue;
                var lines = Kv.Utf8.GetString(data).Split('\n');
                if (lines[0] != "PBZS|ROOMS") continue;
                var list = new List<string[]>();
                for (int i = 1; i < lines.Length; i++)
                {
                    var p = lines[i].Split('\t');
                    if (p.Length >= 4) list.Add(p);
                }
                rooms = list;
                if (!listOk) { listOk = true; NetLog.W("房间列表：大厅服务器有回应（" + list.Count + " 个房间）"); }
                lastAnswer = now;
                Error = "";
            }
            if ((now - lastAsk).TotalSeconds > 2)
            {
                lastAsk = now;
                var b = Kv.Utf8.GetBytes("PBZS|LIST");
                try { sock.Send(b, b.Length, server); } catch (Exception) { }
            }
            if (startedAt == DateTime.MinValue) startedAt = now;
            // 刚开始问的 4 秒内不报；之后 6 秒没回答 = 服务器没开 / 地址填错 / 被防火墙挡
            if ((now - startedAt).TotalSeconds > 4 && (now - lastAnswer).TotalSeconds > 6)
            {
                Error = L.T("大厅服务器没回应：", "The lobby server is not answering: ") + LobbyServer.Show(serverText, server);
                rooms = new List<string[]>();
                if (listOk || !listQuietLogged)
                {
                    listOk = false; listQuietLogged = true;
                    NetLog.W("房间列表：大厅服务器没回应（" + (lastAnswer == DateTime.MinValue ? "一直" : "6 秒") + "没回答列表请求；服务器 "
                             + NetLog.Ip(server) + "）");
                }
            }
            return rooms;
        }

        DateTime startedAt = DateTime.MinValue;
        bool listOk, listQuietLogged;     // §130 net_conn.log 只记有回应 / 没回应的变化

        // §91 第一份房间列表还没回来（也没报错）：面板显示"正在获取房间…"而不是"没有房间"
        public bool Listing { get { return serverText.Trim().Length > 0 && lastAnswer == DateTime.MinValue && Error.Length == 0; } }
        // §91 面板打开房间列表页时：下次 Poll 马上问，不等 2 秒
        public void Refresh() { lastAsk = DateTime.MinValue; }

        public void Close() { if (sock != null) { try { sock.Close(); } catch (Exception) { } sock = null; } }
    }
}
