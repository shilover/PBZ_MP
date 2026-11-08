// v0.22.0：可靠事件通道 + 可选的包签名（HANDOVER §51）。
//
// 两条通道：
//   状态包（位置 / 动作 / 血量 / 准备 / 装备 …）：照旧"最新覆盖"，丢了就丢了，下一包会盖过去
//   可靠事件（弃权、回合结果、对局结果 …）：按序号确认、超时重发、接收端去重并按顺序交付
// 两条都走同一个传输（直连 UDP / Steam / 服务器大厅直连或中转），所以所有连接方式都能用。
//
// Lua ↔ 本程序（游戏没有 socket，只能读写文件）：
//   net\rel_out.txt  Lua 写：b=<Lua 启动号> gb=<它读到的 rel_in 的 b> got=<已处理到的交付号> e<本地号>=<事件> … end=1
//   net\rel_in.txt   本程序写：b=<本次联机的启动号> ob=<took 对应的 Lua 启动号> took=<已收下的本地号> d<交付号>=<事件> … end=1
//   双方各自在自己的文件里确认对方的文件（took / got），对方据此删掉已经处理的行；没有 end=1 的半截文件不读。
//
// 包格式（联机程序 ↔ 联机程序，详见 HANDOVER §51.3）：
//   事件  PBZEV\nsid=<发送方流号>\nbase=<最小未确认号>\ne<号>=<事件>\n…
//   确认  PBZACK\nsid=<对方的流号>\nupto=<连续收到的最大号>\n
//   签名  PBZSIG|<协议版本>|<unix 毫秒>|<HMAC-SHA256 十六进制>\n<原来的包>   （设了密码才有；HMAC 覆盖 "<毫秒>\n<原来的包>"）
//   拒收通知 PBZNAK|<原因>|<协议版本>|<程序版本>   不签名，只用来给对方显示提示（每种原因每秒最多 1 个）
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace PbzLobby
{
    static class Proto
    {
        // 联机程序之间的协议版本：1 = v0.20.x 及以前（状态包里没有 pv=）；2 = v0.22.0 起（可靠事件 + 签名）
        public const int Version = 2;
        public const string App = "0.30.2";        // 和 main.lua 的 VERSION 一致
        public const double MaxSkewSec = 120.0;    // 签名时间戳和本机时钟最多差 2 分钟
    }

    // 包签名（可选）+ 拒收统计 + 给用户看的提示。每个 Session 一个；收包和发包都在 Session 的线程里
    class Wire
    {
        readonly byte[] key;                        // null = 不签名（旧行为）
        public RelChannel Rel;
        public double SimSkewSec;                   // 测试（--sim-skew）：签名时间戳故意偏这么多秒
        public long RejBad, RejTime, RejUnsigned, RejSigned;
        public volatile string PeerApp;             // 对方程序版本（状态包 / 握手 / 拒收通知里带的）
        public volatile int PeerProto;              // 0 = 还不知道；1 = 旧版（状态包没有 pv=）
        long lastHelloTicks;                        // §85.5 最近一次收到对方会话握手（PBZHELLO 带 pv=）的时间（UTC Ticks）
        public volatile string HelloNick;           // §85.5 对方握手里的昵称（nm=，旧版没有）
        DateTime atBad, atTime, atUnsigned, atSigned, atNakNosig, atNakSig, atNakBad, atNakTime;
        readonly Dictionary<string, DateTime> nakAt = new Dictionary<string, DateTime>();

        public Wire(string secret)
        {
            if (!string.IsNullOrEmpty(secret)) key = Kv.Utf8.GetBytes(secret);
        }

        public bool Signed { get { return key != null; } }
        public long Rejected { get { return RejBad + RejTime + RejUnsigned + RejSigned; } }

        static long NowMs() { return (long)(Link.UnixNow() * 1000); }

        byte[] Mac(long ts, byte[] d, int off, int len)
        {
            using (var h = new HMACSHA256(key))
            {
                var t = Encoding.ASCII.GetBytes(ts.ToString(CultureInfo.InvariantCulture) + "\n");
                h.TransformBlock(t, 0, t.Length, null, 0);
                h.TransformFinalBlock(d, off, len);
                return h.Hash;
            }
        }

        static string Hex(byte[] b)
        {
            var sb = new StringBuilder(b.Length * 2);
            foreach (var x in b) sb.Append(x.ToString("x2"));
            return sb.ToString();
        }

        static bool SameText(string a, string b)   // 定长比较，不因为前几位对了就早退
        {
            if (a == null || b == null || a.Length != b.Length) return false;
            int diff = 0;
            for (int i = 0; i < a.Length; i++) diff |= a[i] ^ b[i];
            return diff == 0;
        }

        static bool Starts(byte[] d, int off, int len, string head)
        {
            if (len < head.Length) return false;
            for (int i = 0; i < head.Length; i++) if (d[off + i] != (byte)head[i]) return false;
            return true;
        }

        // 发出去的包：有密码就加签名头
        public byte[] Seal(string body)
        {
            var b = Kv.Utf8.GetBytes(body);
            if (key == null) return b;
            long ts = NowMs() + (long)(SimSkewSec * 1000);
            var head = Kv.Utf8.GetBytes("PBZSIG|" + Proto.Version + "|" + ts.ToString(CultureInfo.InvariantCulture) + "|" + Hex(Mac(ts, b, 0, b.Length)) + "\n");
            var pkt = new byte[head.Length + b.Length];
            Buffer.BlockCopy(head, 0, pkt, 0, head.Length);
            Buffer.BlockCopy(b, 0, pkt, head.Length, b.Length);
            return pkt;
        }

        // 收到的包：验签，返回原来的包；拒收 / 拒收通知返回 null。reply 用来回拒收通知（可以为 null）
        public string Verify(byte[] d, int off, int len, Action<byte[]> reply)
        {
            if (Starts(d, off, len, "PBZNAK|")) { OnNak(Kv.Utf8.GetString(d, off, len)); return null; }
            if (!Starts(d, off, len, "PBZSIG|"))
            {
                if (key == null) return Kv.Utf8.GetString(d, off, len);
                RejUnsigned++; atUnsigned = DateTime.UtcNow; Nak(reply, "nosig");
                return null;
            }
            if (key == null) { RejSigned++; atSigned = DateTime.UtcNow; Nak(reply, "sig"); return null; }
            int nl = Array.IndexOf(d, (byte)'\n', off, len);
            var head = nl < 0 ? new string[0] : Encoding.ASCII.GetString(d, off, nl - off).Split('|');
            long ts;
            if (head.Length < 4 || !long.TryParse(head[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out ts)
                || !SameText(Hex(Mac(ts, d, nl + 1, off + len - nl - 1)), head[3]))
            {
                RejBad++; atBad = DateTime.UtcNow; Nak(reply, "bad");
                return null;
            }
            // 先验签再看时间：只有密码对了才报"时钟差太多"，提示才准
            if (Math.Abs(NowMs() - ts) > Proto.MaxSkewSec * 1000)
            {
                RejTime++; atTime = DateTime.UtcNow; Nak(reply, "time");
                return null;
            }
            return Kv.Utf8.GetString(d, nl + 1, off + len - nl - 1);
        }

        void Nak(Action<byte[]> reply, string why)
        {
            if (reply == null) return;
            DateTime t;
            if (nakAt.TryGetValue(why, out t) && (DateTime.UtcNow - t).TotalSeconds < 1) return;
            nakAt[why] = DateTime.UtcNow;
            try { reply(Kv.Utf8.GetBytes("PBZNAK|" + why + "|" + Proto.Version + "|" + Proto.App)); } catch (Exception) { }
        }

        void OnNak(string s)
        {
            var f = s.Split('|');
            if (f.Length < 2) return;
            var now = DateTime.UtcNow;
            switch (f[1])
            {
                case "nosig": atNakNosig = now; break;    // 对方要签名，我们没签
                case "sig": atNakSig = now; break;        // 我们签了，对方没设密码
                case "bad": atNakBad = now; break;
                case "time": atNakTime = now; break;
            }
            if (f.Length > 3 && f[3].Length > 0 && f[3].Length < 20) PeerApp = f[3].Trim();
        }

        static string Field(string body, string key)
        {
            int i = body.IndexOf("\n" + key + "=", StringComparison.Ordinal);
            if (i < 0) return null;
            i += key.Length + 2;
            int e = body.IndexOf('\n', i);
            return (e < 0 ? body.Substring(i) : body.Substring(i, e - i)).Trim();
        }

        // 验过的、来自当前对端的包：事件 / 确认交给 Rel，返回 true（不是状态包）；握手和状态包顺便记下对方版本
        public bool Control(string body)
        {
            if (body.StartsWith("PBZEV\n", StringComparison.Ordinal)) { if (Rel != null) Rel.OnEvents(body); return true; }
            if (body.StartsWith("PBZACK\n", StringComparison.Ordinal)) { if (Rel != null) Rel.OnAck(body); return true; }
            bool hello = body.StartsWith("PBZHELLO", StringComparison.Ordinal);
            if (hello && body.IndexOf("\npv=", StringComparison.Ordinal) < 0) return true;   // 打洞 / 旧版的握手：看不出版本
            if (!hello && body.IndexOf("\nseq=", StringComparison.Ordinal) < 0) return false;
            int pv;
            var p = Field(body, "pv");
            PeerProto = p != null && int.TryParse(p, out pv) ? pv : 1;
            var av = Field(body, "av");
            if (av != null && av.Length > 0) PeerApp = av;
            if (hello)
            {
                System.Threading.Interlocked.Exchange(ref lastHelloTicks, DateTime.UtcNow.Ticks);
                var nm = Field(body, "nm");     // §85.5 握手带的昵称（只靠握手转正时提示用）
                if (nm != null && nm.Length > 0) HelloNick = nm;
            }
            return hello;
        }

        // §85.5 对方多少秒前握过手（没握过 = 很大）。AI 对战时等人的房间不发包，客机在收到主机的包之前只发握手
        public double SinceHello
        {
            get
            {
                long t = System.Threading.Interlocked.Read(ref lastHelloTicks);
                return t == 0 ? double.MaxValue : (DateTime.UtcNow.Ticks - t) / (double)TimeSpan.TicksPerSecond;
            }
        }

        // 给窗口看的一句提示（空 = 一切正常）。只看最近 5 秒发生的问题。brief = 游戏内面板用的短句（一行只放得下 30 来个字）
        public string Hint(bool brief = false)
        {
            var now = DateTime.UtcNow;
            Func<DateTime, bool> recent = t => (now - t).TotalSeconds < 5;
            if (recent(atTime) || recent(atNakTime))
                return brief ? L.T("两边时钟差超过 2 分钟，包被拒收", "CLOCKS DIFFER BY OVER 2 MIN")
                     : L.T("两台电脑的时钟相差超过 2 分钟，签名的包被拒收：两边都把系统时间设成自动同步",
                           "The two PCs' clocks differ by more than 2 minutes, signed packets are rejected: turn on automatic time sync on both");
            if (recent(atBad) || recent(atNakBad))
                return brief ? L.T("联机密码和对方不一样", "PASSWORD DIFFERS FROM THE OPPONENT'S")
                     : L.T("联机密码和对方的不一样，包被拒收：两边要填同一个密码", "The connection password differs from the opponent's: both must use the same one");
            if (recent(atSigned) || recent(atNakNosig))
                return brief ? L.T("对方设了联机密码，你没设", "OPPONENT HAS A PASSWORD, YOU DON'T")
                     : L.T("对方设了联机密码、你没设：在设置里填上和对方一样的密码", "The opponent set a connection password and you did not: enter the same password in Settings");
            if (recent(atUnsigned) || recent(atNakSig))
                return brief ? L.T("你设了联机密码，对方没设（或是旧版）", "YOU HAVE A PASSWORD, OPPONENT DOESN'T")
                     : L.T("你设了联机密码，对方没设（或对方的联机程序是 v0.20 及以前的旧版本）：两边填同一个密码，或者都清空",
                           "You set a connection password but the opponent did not (or runs v0.20 or older): use the same password on both, or clear both");
            if (PeerProto == 1)
                return brief ? L.T("对方是旧版联机程序（v0.20 及以前）", "OPPONENT RUNS AN OLD VERSION (v0.20-)")
                     : L.T("对方的联机程序是旧版本（v0.20 及以前）：可靠事件和联机密码用不了，请两边都更新到 v" + Proto.App,
                           "The opponent runs an old helper (v0.20 or older): reliable events and passwords are unavailable, update both to v" + Proto.App);
            var pa = PeerApp;
            if (pa != null && pa != Proto.App)
                return brief ? L.T("版本不一致：你 v" + Proto.App + " / 对方 v" + pa, "VERSION: YOU v" + Proto.App + " / THEM v" + pa)
                     : L.T("版本不一致：你 v" + Proto.App + "，对方 v" + pa + "，建议两边更新到同一版本",
                           "Version mismatch: you v" + Proto.App + ", opponent v" + pa + "; update both to the same version");
            return "";
        }

        public string RejText()
        {
            return L.T("被拒 ", "Rejected ") + Rejected + (Rejected == 0 ? "" :
                   L.T("（签名不对 ", " (bad sig ") + RejBad + L.T(" / 时间差 ", " / clock ") + RejTime
                   + L.T(" / 没签名 ", " / unsigned ") + RejUnsigned + L.T(" / 我没设密码 ", " / I have no password ") + RejSigned + L.T("）", ")"));
        }
    }

    // 可靠事件：发送端按序号重发直到确认，接收端去重、攒着乱序的、按顺序交付给 Lua
    class RelChannel
    {
        public const double Rto0 = 0.2, RtoMax = 1.0;   // 重发间隔：0.2 秒起，没进展就翻倍，最多 1 秒
        public const double Ttl = 60.0;                  // 60 秒还没确认就放弃（对方早走了；Lua 那边 5 秒没包就判掉线）
        const int MaxBatch = 32, MaxBatchBytes = 900, MaxInbox = 512, MaxHeld = 1024;

        class Ev { public int Seq; public string Data; public DateTime First; public int Tries; }

        readonly Action<string> send;                    // Session：签名 + 发给对端
        string fOut, fIn;
        public Action<string> Log = delegate { };

        // 发送
        readonly string sid = Guid.NewGuid().ToString("N").Substring(0, 8);
        int nextSeq = 1;
        readonly List<Ev> outq = new List<Ev>();
        double rto = Rto0;
        DateTime lastTx = DateTime.MinValue;
        // 接收
        string peerSid;
        readonly HashSet<string> oldSids = new HashSet<string>();
        int expect = 1;
        readonly SortedDictionary<int, string> held = new SortedDictionary<int, string>();
        bool needAck;
        // 和 Lua 交换
        readonly string boot = DateTime.UtcNow.Ticks.ToString("x");
        string luaBoot;
        int took, dIdx;
        readonly List<KeyValuePair<int, string>> inbox = new List<KeyValuePair<int, string>>();
        bool inDirty = true;

        public long Taken, Sent, Acked, Retx, Expired, Delivered, Dup, OutOfOrder, Skipped;
        public int Pending { get { return outq.Count; } }

        public RelChannel(string dir, Action<string> send)
        {
            this.send = send;
            Retarget(dir);
        }

        // 换和 Lua 交换的目录（§85 等人的房间转正：net\wait\ → net\）。和对方的流号 / 序号不动；
        // 和构造时一样，Lua 在这之前写的事件（AI 对战时的）不发。只在 Session 的收发线程里调
        public void Retarget(string dir)
        {
            fOut = Path.Combine(dir, "rel_out.txt");
            fIn = Path.Combine(dir, "rel_in.txt");
            // 联机开始前 Lua 留下的事件不发（上一次联机 / 上一局的）：记下它当时的启动号和最大本地号
            var d = ReadDone(fOut);
            luaBoot = d != null && d.ContainsKey("b") ? d["b"] : "";
            took = d != null ? MaxNum(d, 'e') : 0;
            inDirty = true;
        }

        static Dictionary<string, string> ReadDone(string path)
        {
            var t = GamePipe.In(path);      // §84 连着管道：游戏经管道发来的 rel_out；没连读文件
            if (t == null) return null;
            var d = Kv.Parse(t);
            return d.ContainsKey("end") ? d : null;     // 没有 end=1 = 对方写到一半，下次再读
        }

        static int MaxNum(Dictionary<string, string> d, char prefix)
        {
            int m = 0, n;
            foreach (var k in d.Keys)
                if (k.Length > 1 && k[0] == prefix && int.TryParse(k.Substring(1), out n) && n > m) m = n;
            return m;
        }

        static List<KeyValuePair<int, string>> Numbered(Dictionary<string, string> d, char prefix)
        {
            var l = new List<KeyValuePair<int, string>>();
            int n;
            foreach (var kv in d)
                if (kv.Key.Length > 1 && kv.Key[0] == prefix && int.TryParse(kv.Key.Substring(1), out n)) l.Add(new KeyValuePair<int, string>(n, kv.Value));
            l.Sort((a, b) => a.Key.CompareTo(b.Key));
            return l;
        }

        // 给测试 / 命令行用：直接塞一个事件（游戏里走 rel_out.txt）
        public void Enqueue(string data)
        {
            data = (data ?? "").Replace("\r", " ").Replace("\n", " ");
            outq.Add(new Ev { Seq = nextSeq++, Data = data, First = DateTime.UtcNow });
            Taken++;
        }

        // 读 Lua 写的 rel_out.txt：收下新事件、按 got 删掉 Lua 已经处理过的交付行
        public void PollLua()
        {
            var d = ReadDone(fOut);
            if (d == null) return;
            string b, v;
            int n;
            if (!d.TryGetValue("b", out b)) b = "";
            if (b != luaBoot)
            {
                // 游戏重开了（Lua 的本地号从 1 重新数）
                luaBoot = b;
                took = 0;
                inDirty = true;
            }
            foreach (var e in Numbered(d, 'e'))
            {
                if (e.Key <= took) continue;
                Enqueue(e.Value);
                took = e.Key;
                inDirty = true;
            }
            if (d.TryGetValue("gb", out v) && v == boot && d.TryGetValue("got", out v) && int.TryParse(v, out n))
            {
                int before = inbox.Count;
                inbox.RemoveAll(x => x.Key <= n);
                if (inbox.Count != before) inDirty = true;
            }
        }

        public void OnAck(string body)
        {
            var d = Kv.Parse(body);
            string s, v;
            int upto;
            if (!d.TryGetValue("sid", out s) || s != sid || !d.TryGetValue("upto", out v) || !int.TryParse(v, out upto)) return;
            int n = outq.RemoveAll(e => e.Seq <= upto);
            if (n > 0) { Acked += n; rto = Rto0; }
        }

        public void OnEvents(string body)
        {
            var d = Kv.Parse(body);
            string s, v;
            int bas;
            if (!d.TryGetValue("sid", out s) || s.Length == 0) return;
            if (!d.TryGetValue("base", out v) || !int.TryParse(v, out bas)) bas = 1;
            if (s != peerSid)
            {
                // 用过的旧流（迟到的包 / 2 分钟内被人重放的签名包）：不理。不然切回旧流再切回来，已交付的会再交付一遍
                if (oldSids.Contains(s)) { Dup++; return; }
                // 新的一条流（对方开了新联机 / 重开了联机程序）：从它最小的未确认号开始收
                if (peerSid != null) { Log(L.T("可靠事件：对方换了新的事件流，重新计数", "Reliable events: peer started a new stream")); oldSids.Add(peerSid); }
                peerSid = s;
                expect = bas;
                held.Clear();
            }
            else if (bas > expect)
            {
                // 对方放弃了（超时）一些我们没收到的事件：跳过去，不然后面的永远交付不了
                Skipped += bas - expect;
                Log(L.T("可靠事件：对方超时放弃了 #" + expect + "–#" + (bas - 1), "Reliable events: peer gave up #" + expect + "-#" + (bas - 1)));
                var drop = new List<int>();
                foreach (var k in held.Keys) if (k < bas) drop.Add(k);
                foreach (var k in drop) held.Remove(k);
                expect = bas;
            }
            foreach (var e in Numbered(d, 'e'))
            {
                if (e.Key < expect || held.ContainsKey(e.Key)) { Dup++; continue; }
                if (held.Count >= MaxHeld) break;
                if (e.Key != expect) OutOfOrder++;
                held[e.Key] = e.Value;
            }
            string data;
            while (held.TryGetValue(expect, out data))
            {
                held.Remove(expect);
                expect++;
                dIdx++;
                inbox.Add(new KeyValuePair<int, string>(dIdx, data));
                Delivered++;
                inDirty = true;
            }
            if (inbox.Count > MaxInbox) inbox.RemoveRange(0, inbox.Count - MaxInbox);   // Lua 太久没读（游戏卡住）：丢最老的
            needAck = true;
        }

        // Session 每圈调一次（约 15 毫秒）
        public void Tick(DateTime now)
        {
            if (outq.Count > 0 && (now - outq[0].First).TotalSeconds > Ttl)
            {
                int n = outq.RemoveAll(e => (now - e.First).TotalSeconds > Ttl);
                Expired += n;
                Log(L.T("可靠事件：" + n + " 个 " + Ttl + " 秒没确认，放弃", "Reliable events: gave up " + n + " unacked after " + Ttl + " s"));
            }
            if (needAck && peerSid != null)
            {
                needAck = false;
                send("PBZACK\nsid=" + peerSid + "\nupto=" + (expect - 1) + "\n");
            }
            if (outq.Count > 0)
            {
                bool fresh = outq.Exists(e => e.Tries == 0);
                if (fresh || (now - lastTx).TotalSeconds >= rto)
                {
                    var sb = new StringBuilder("PBZEV\nsid=" + sid + "\nbase=" + outq[0].Seq + "\n");
                    int k = 0;
                    foreach (var e in outq)
                    {
                        if (k >= MaxBatch || (k > 0 && sb.Length + e.Data.Length > MaxBatchBytes)) break;
                        sb.Append('e').Append(e.Seq).Append('=').Append(e.Data).Append('\n');
                        if (e.Tries > 0) Retx++; else Sent++;
                        e.Tries++;
                        k++;
                    }
                    if (!fresh) rto = Math.Min(rto * 2, RtoMax);
                    lastTx = now;
                    send(sb.ToString());
                }
            }
            if (inDirty) WriteLua();
        }

        void WriteLua()
        {
            inDirty = false;
            var sb = new StringBuilder();
            sb.Append("b=").Append(boot).Append("\nob=").Append(luaBoot).Append("\ntook=").Append(took).Append('\n');
            foreach (var e in inbox) sb.Append('d').Append(e.Key).Append('=').Append(e.Value).Append('\n');
            sb.Append("end=1\n");
            GamePipe.Out(fIn, sb.ToString());       // §84
        }

        public string StatText()
        {
            return L.T("事件 发 ", "Events sent ") + Sent + L.T(" 重发 ", " resent ") + Retx + L.T(" 待确认 ", " unacked ") + outq.Count
                   + L.T(" / 收 ", " / got ") + Delivered + L.T(" 重复 ", " dup ") + Dup + L.T(" 乱序 ", " ooo ") + OutOfOrder;
        }
    }

    // 测试用的"坏网络"：丢包 / 乱序（--sim-loss 0.3 --sim-reorder），只作用于 Session 发出去的包
    class SimNet
    {
        readonly Random rnd = new Random();
        readonly List<KeyValuePair<DateTime, byte[]>> late = new List<KeyValuePair<DateTime, byte[]>>();
        public long Dropped, Delayed;

        public void Send(byte[] b, Action<byte[]> real)
        {
            if (Program.SimLoss > 0 && rnd.NextDouble() < Program.SimLoss) { Dropped++; return; }
            if (Program.SimReorder && rnd.NextDouble() < 0.3)
            {
                Delayed++;
                late.Add(new KeyValuePair<DateTime, byte[]>(DateTime.UtcNow.AddMilliseconds(20 + rnd.Next(180)), b));
                return;
            }
            real(b);
        }

        public void Flush(Action<byte[]> real)
        {
            if (late.Count == 0) return;
            var now = DateTime.UtcNow;
            for (int i = 0; i < late.Count; i++)
                if (late[i].Key <= now) { real(late[i].Value); late.RemoveAt(i); i--; }
        }
    }
}
