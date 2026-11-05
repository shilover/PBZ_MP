// 服务器大厅（mode=server，docs/HANDOVER.md §47）：自建服务端 server/pbz-lobby-server.mjs 登记 / 列出房间，
// 加入时把双方的公网地址互相告诉对方，两边往对方的地址互发包打洞（UDP hole punching）；
// 直连试 3 次（每次 2.5 秒）都没收到对方的包，就改走服务器中转（服务器开了 --relay 才有，没开会回 ERR …|norelay，客机就一轮轮接着试直连；状态包加 PBZR|<会话号> 头，由服务器转给对方）。
// 协议见服务端文件头。REG / JOIN / 中转都从游戏用的那个 UDP 端口发，服务器看到的才是 NAT 给这个端口的公网地址。
using System;
using System.Collections.Generic;
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
    class ServerLink : ITransport
    {
        public const int Tries = 3;              // 用户 2026-11-04 定：直连重试 3 次连不上改走服务器中转
        public const double TryWindow = 2.5;     // 每次直连等多少秒
        const double LostAfter = 6.0;            // 连上后多久没收到对方的包算断了（客机重新走一遍加入，主机重新等人）

        readonly UdpClient udp;
        readonly IPEndPoint server;
        readonly string name, key;
        readonly RemoteOut outq;
        readonly bool host;
        public readonly bool SimNoDirect;        // 测试用（--sim-no-direct）：丢掉所有不是服务器发来的包 = 模拟打洞不通
        public Func<string> MapOf = () => "?";
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
        bool noRelay;      // 服务器没开 --relay（回了 ERR …|norelay）：不再进中转，提示留着，一轮轮接着试直连
        int attempt = 1;
        DateTime attemptAt, lastJoin, lastPunch, lastReg, lastRelayReq, lastFromPeer = DateTime.MinValue, lastFromServer = DateTime.MinValue, punchUntil;

        // host：roomOrNull = null；client：要加入的房间号
        public ServerLink(IPEndPoint server, string roomOrNull, int port, string name, string fRemote, bool simNoDirect)
        {
            this.server = server;
            outq = new RemoteOut(fRemote);
            this.name = name;
            SimNoDirect = simNoDirect;
            host = roomOrNull == null;
            if (!host) roomId = roomOrNull.Trim().ToUpperInvariant();
            key = Guid.NewGuid().ToString("N");
            udp = new UdpClient(new IPEndPoint(IPAddress.Any, port));
            try { udp.Client.IOControl(-1744830452, new byte[] { 0, 0, 0, 0 }, null); } catch (Exception) { }   // 同 Link：忽略 ICMP 端口不可达
            attemptAt = DateTime.UtcNow;
        }

        public string RoomId { get { return roomId; } }
        public bool Relay { get { return relay; } }
        public string Error { get { return error; } }
        public int LocalPort { get { return ((IPEndPoint)udp.Client.LocalEndPoint).Port; } }
        public string PeerStr { get { return relay ? L.T("经服务器中转", "via server relay") : (peer != null ? peer.ToString() : ""); } }
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
                if (!known && !(host && peer == null && sid == null)) continue;
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
                }
                if (!from.Equals(peer) && !cands.Contains(from)) continue;
                if (peer == null)
                {
                    // 客机要确认是双向通的：主机的打洞包带 ack=1（= 主机收到过我们的包）或已经是状态包才算直连。
                    // 只有"主机 → 客机"通的时候（客机的包到不了主机），没有这一步客机会以为连上了、永远不改走中转
                    if (!host && text.StartsWith("PBZ") && text.IndexOf("ack=1", StringComparison.Ordinal) < 0) continue;
                    peer = from;
                    rx.Reset();
                    log(L.T("直连成功：", "Direct connection: ") + from + (host ? "" : L.T("（第 " + attempt + " 次）", " (try " + attempt + ")")));
                    if (noRelay) error = "";
                }
                lastFromPeer = now;
                if (wire.Control(text)) continue;
                if (rx.Take(text)) { got++; outq.Push(text); }
            }
            outq.Flush();   // 每轮写一个（RemoteOut，HANDOVER §72.10）
            if (got > 0) rx.PeerNick = Kv.NickOf(rx.Newest) ?? rx.PeerNick;
            if (host) HostTick(now); else ClientTick(now);
            return got;
        }

        int FromServer(byte[] data, DateTime now)
        {
            lastFromServer = now;
            if (data.Length > 5 && data[0] == 'P' && data[1] == 'B' && data[2] == 'Z' && data[3] == 'R' && data[4] == '|')
            {
                // 中转来的状态包：PBZR|<会话号>\n<包>
                int nl = Array.IndexOf(data, (byte)'\n');
                if (nl < 0 || sid == null || Encoding.ASCII.GetString(data, 5, nl - 5) != sid) return 0;
                if (!relay)
                {
                    if (!host) return 0;
                    relay = true; peer = null; rx.Reset();
                    log(L.T("对方改走服务器中转", "Peer switched to server relay"));
                }
                var body = wire.Verify(data, nl + 1, data.Length - nl - 1, Send);
                if (body == null) return 0;
                lastFromPeer = now;
                if (wire.Control(body) || !rx.Take(body)) return 0;
                outq.Push(body);   // 中转来的也要排队写（§72.10 漏了这条路，中转时对方状态一帧都写不出去）
                return 1;
            }
            var f = Kv.Utf8.GetString(data).Split('|');
            if (f.Length < 2 || f[0] != "PBZS") return 0;
            switch (f[1])
            {
                case "REGOK":
                    if (f.Length > 2 && roomId != f[2]) { roomId = f[2]; log(L.T("房间已登记到大厅：", "Room listed on the lobby server: ") + roomId); }
                    error = "";
                    break;
                case "PEER":
                    if (f.Length < 6) break;
                    OnPeer(f[3], f[4], f[5], now);
                    break;
                case "ERR":
                    var why = f.Length > 3 ? f[3] : "";
                    if (why == "norelay")
                    {
                        if (!noRelay) log(L.T("大厅服务器没开中转，接着试直连", "The lobby server has no relay; retrying direct"));
                        noRelay = true;
                        error = L.T("直连不通，服务器没开中转：主机转发端口或用 Tailscale", "Direct failed, server has no relay");
                        if (!host && relay && !relayOk) Restart(now);   // 中转等不来：回去重新加入、再打几轮洞（等中转时直连包是不收的）
                        break;
                    }
                    error = why == "nofound" ? L.T("大厅里没有这个房间（" + roomId + "）", "No such room on the lobby server (" + roomId + ")")
                          : why == "full" ? L.T("房间已满", "The room is full")
                          : L.T("大厅服务器报错：", "Lobby server error: ") + why;
                    break;
                case "RELAYOK":
                    if (f.Length > 2 && f[2] == sid && !relayOk) { relayOk = true; log(L.T("服务器中转已就绪", "Server relay ready")); }
                    break;
                case "RELAYON":
                    // 刚切过来时还没收到中转的包：从现在起算"多久没动静"，不然主机会马上当成对方走了
                    if (f.Length > 2 && f[2] == sid && !relay) { relay = true; peer = null; rx.Reset(); lastFromPeer = now; log(L.T("对方改走服务器中转", "Peer switched to server relay")); }
                    break;
            }
            return 0;
        }

        void OnPeer(string newSid, string pub, string local, DateTime now)
        {
            if (host)
            {
                // 正连着一个人（3 秒内有包）时不换人；服务器那边也会因为"已满"拒掉新的加入
                if (newSid != sid && (now - lastFromPeer).TotalSeconds < 3) return;
                if (newSid != sid)
                {
                    sid = newSid; peer = null; relay = false; rx.Reset();
                    log(L.T("有人要加入（", "A player is joining (") + pub + L.T("），开始打洞", "), punching"));
                }
                punchUntil = now.AddSeconds(Tries * TryWindow + 2);
            }
            else
            {
                if (sid == null) log(L.T("服务器介绍主机地址 ", "Host address from the lobby server: ") + pub + (local.Length > 0 ? " / " + local : ""));
                sid = newSid;
                joined = true;
                if (!noRelay) error = "";      // 没中转的提示留着，直到直连真的通了
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
                Raw("PBZS|REG|" + key + "|" + LobbyServer.Clean(name) + "|" + LobbyServer.Clean(MapOf()) + "|" + (full ? "1" : "0")
                    + "|" + LobbyServer.LocalAddr(LocalPort), server);
                if (lastFromServer == DateTime.MinValue ? (now - attemptAt).TotalSeconds > 5 : ServerQuiet)
                    error = L.T("大厅服务器没回应：", "The lobby server is not answering: ") + server;
            }
            // 收到客机的包之后也接着打：带 ack=1 告诉客机"你的包我收到了"（客机靠它确认双向通）
            if (!relay && now < punchUntil) Punch(now, "PBZPUNCH\nsid=" + sid + "\n" + (peer != null ? "ack=1\n" : ""));
            // 对方走了：清掉，等下一个人
            if ((peer != null || relay) && (now - lastFromPeer).TotalSeconds > LostAfter)
            {
                log(L.T("对方 " + LostAfter + " 秒没动静，房间重新开放", "No packets for " + LostAfter + " s, room open again"));
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
                    Restart(now);
                }
                return;
            }
            if (peer != null)
            {
                if ((now - lastFromPeer).TotalSeconds > LostAfter) { log(L.T("直连断了，重新加入", "Direct link lost, joining again")); Restart(now); }
                return;
            }
            // 打洞中：没拿到会话前每 0.5 秒发 JOIN；拿到后每 0.2 秒往主机的公网 / 局域网地址发握手
            if (!joined && (now - lastJoin).TotalSeconds > 0.5)
            {
                lastJoin = now;
                Raw("PBZS|JOIN|" + roomId + "|" + LobbyServer.LocalAddr(LocalPort), server);
            }
            Punch(now, "PBZHELLO\nsid=" + sid + "\n");
            if ((now - attemptAt).TotalSeconds < TryWindow) return;
            if (sid == null)
            {
                // 连服务器都没回：没法中转，一直重试 JOIN
                if (error.Length == 0 || ServerQuiet) error = L.T("大厅服务器没回应：", "The lobby server is not answering: ") + server;
                attemptAt = now;
                return;
            }
            if (attempt < Tries)
            {
                attempt++;
                attemptAt = now;
                joined = false;                // 重新 JOIN 一次：服务器重发 PEER 给主机，主机再打一轮洞
                log(L.T("直连没通，第 " + attempt + " 次重试", "No direct link yet, try " + attempt));
                return;
            }
            if (noRelay)
            {
                // 已经知道服务器没开中转：不再进中转，从头再来一轮直连（对方开了端口转发 / UPnP 之后就能连上）
                log(L.T("直连 " + Tries + " 次都没通，服务器没开中转，重新加入再试", "Direct failed " + Tries + " times, no relay on the server; joining again"));
                Restart(now);
                return;
            }
            relay = true;
            relayOk = false;
            lastFromPeer = now;
            rx.Reset();
            log(L.T("直连 " + Tries + " 次都没通，改走服务器中转", "Direct failed " + Tries + " times, using server relay"));
        }

        void Restart(DateTime now)
        {
            peer = null; relay = false; relayOk = false; joined = false; sid = null; cands.Clear();
            attempt = 1; attemptAt = now; rx.Reset();
        }

        public void Close()
        {
            if (host) Raw("PBZS|UNREG|" + key, server);
            try { udp.Close(); } catch (Exception) { }
        }
    }

    // 不在联机时也要列房间：自己一个 UDP 口，每 2 秒问一次服务器（界面线程的 Tick 里调，不阻塞）
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
                    sock = new UdpClient(new IPEndPoint(IPAddress.Any, 0));
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
                Error = L.T("大厅服务器没回应：", "The lobby server is not answering: ") + server;
                rooms = new List<string[]>();
            }
            return rooms;
        }

        DateTime startedAt = DateTime.MinValue;

        // §91 第一份房间列表还没回来（也没报错）：面板显示"正在获取房间…"而不是"没有房间"
        public bool Listing { get { return serverText.Trim().Length > 0 && lastAnswer == DateTime.MinValue && Error.Length == 0; } }
        // §91 面板打开房间列表页时：下次 Poll 马上问，不等 2 秒
        public void Refresh() { lastAsk = DateTime.MinValue; }

        public void Close() { if (sock != null) { try { sock.Close(); } catch (Exception) { } sock = null; } }
    }
}
