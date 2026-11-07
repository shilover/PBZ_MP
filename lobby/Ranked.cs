// §110 武林盟主（排位）的联机程序一侧：本机密钥、和大厅服务器的排位往来（登记 / 我的分数 / 规则 / 排行榜 / 对方称号），
// 以及看主机状态包里的 mt= 判断开局 / 打完 / 弃权 / 掉线并上报。协议见服务端 pbz-ranked.mjs 文件头和 HANDOVER §110.1。
// 模组不用管上报：开局 / 结束都从状态包里看出来（§110.2）。界面线程的 Tick 里调 Poll，不阻塞。
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace PbzLobby
{
    // §110.11 一局里自己的武器 / 影之武装 / 招式统计（用户 2026-11-06"能做武器使用率统计么""招式能统计也可以统计"）。
    // 本机状态包（发包线程）：wc= 手里的武器、wcs= 装着的影之武装、ev=<招式号>:<招式> 放招；
    // 对方状态包（收包线程）：res=<结果号>:<我的招式号>:<hit|deflect|miss>:<伤害> 对方报我的招打没打中。两个线程都会调，所以加锁
    class MatchStats
    {
        readonly object gate = new object();
        bool on;
        int samples;
        readonly Dictionary<string, int> weapons = new Dictionary<string, int>(), edges = new Dictionary<string, int>();
        readonly Dictionary<string, string> moveOf = new Dictionary<string, string>();     // 招式号 → 招式名
        readonly Dictionary<string, int[]> moves = new Dictionary<string, int[]>();         // 招式名 → {放出, 命中, 被格挡, 落空, 伤害}
        readonly HashSet<string> results = new HashSet<string>();

        public void Start()
        {
            lock (gate) { on = true; samples = 0; weapons.Clear(); edges.Clear(); moveOf.Clear(); moves.Clear(); results.Clear(); }
        }

        public void Stop() { lock (gate) on = false; }

        // ".../Weapon/Double/Weapon_Hun_JueYing.Weapon_Hun_JueYing" → "Double/JueYing"（服务端按资源名、文件夹名查中文名）
        public static string WeaponKey(string path)
        {
            if (string.IsNullOrEmpty(path)) return "";
            var p = path.Split('/');
            var asset = p[p.Length - 1];
            int dot = asset.IndexOf('.');
            if (dot >= 0) asset = asset.Substring(0, dot);
            if (asset.StartsWith("Weapon_Hun_")) asset = asset.Substring(11);
            else if (asset.StartsWith("Weapon_")) asset = asset.Substring(7);
            var folder = p.Length >= 2 ? p[p.Length - 2] : asset;
            return Clean(folder) + "/" + Clean(asset);
        }

        // GA_Hun_Double_Air_A_C → Double_Air_A；GA_HuangJinHuoChong_DeflectCounter_C → HuangJinHuoChong_DeflectCounter
        public static string MoveKey(string ga)
        {
            var s = ga ?? "";
            if (s.StartsWith("GA_Hun_")) s = s.Substring(7);
            else if (s.StartsWith("GA_")) s = s.Substring(3);
            if (s.EndsWith("_C")) s = s.Substring(0, s.Length - 2);
            return Clean(s);
        }

        static string Clean(string s) { return (s ?? "").Replace(":", "").Replace(",", "").Replace(";", "").Replace("|", "").Replace("=", ""); }

        public void Local(string wc, string wcs, string ev)
        {
            lock (gate)
            {
                if (!on) return;
                samples++;
                var w = WeaponKey(wc);
                if (w.Length > 1) weapons[w] = (weapons.ContainsKey(w) ? weapons[w] : 0) + 1;
                var e = WeaponKey(wcs);
                if (e.Length > 1) edges[e] = (edges.ContainsKey(e) ? edges[e] : 0) + 1;
                foreach (var one in (ev ?? "").Split(','))
                {
                    int c = one.IndexOf(':');
                    if (c <= 0) continue;
                    var id = one.Substring(0, c);
                    if (moveOf.ContainsKey(id)) continue;      // 同一招会在好几个包里重复
                    var name = MoveKey(one.Substring(c + 1));
                    if (name.Length == 0) continue;
                    moveOf[id] = name;
                    Of(name)[0]++;
                }
            }
        }

        int[] Of(string name)
        {
            int[] m;
            if (!moves.TryGetValue(name, out m)) moves[name] = m = new int[5];
            return m;
        }

        public void Peer(string res)
        {
            if (string.IsNullOrEmpty(res)) return;
            lock (gate)
            {
                if (!on) return;
                foreach (var one in res.Split(','))
                {
                    var p = one.Split(':');
                    if (p.Length < 4 || results.Contains(p[0])) continue;   // 对方会重复发几秒，按结果号去重
                    string name;
                    if (!moveOf.TryGetValue(p[1], out name)) continue;
                    results.Add(p[0]);
                    var m = Of(name);
                    double dmg;
                    if (p[2] == "hit") { m[1]++; if (double.TryParse(p[3], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out dmg)) m[4] += (int)Math.Round(dmg); }
                    else if (p[2] == "deflect") m[2]++;
                    else if (p[2] == "miss") m[3]++;
                }
            }
        }

        // w=<武器>:<占比%>,…;e=<影之武装>;m=<招式>:<放出>:<命中>:<被格挡>:<落空>:<伤害>,…（放出多的在前，太长从后面砍）
        public string Payload()
        {
            lock (gate)
            {
                var sb = new StringBuilder("w=");
                bool first = true;
                foreach (var kv in weapons)
                {
                    int pct = samples > 0 ? (int)Math.Round(kv.Value * 100.0 / samples) : 0;
                    if (pct <= 0) continue;
                    sb.Append(first ? "" : ",").Append(kv.Key).Append(':').Append(pct);
                    first = false;
                }
                string edge = "";
                int best = 0;
                foreach (var kv in edges) if (kv.Value > best) { best = kv.Value; edge = kv.Key; }
                sb.Append(";e=").Append(edge).Append(";m=");
                var list = new List<KeyValuePair<string, int[]>>(moves);
                list.Sort((a, b) => b.Value[0].CompareTo(a.Value[0]));
                first = true;
                foreach (var kv in list)
                {
                    var one = kv.Key + ":" + string.Join(":", Array.ConvertAll(kv.Value, x => x.ToString()));
                    if (sb.Length + one.Length + 1 > 1000) break;
                    sb.Append(first ? "" : ",").Append(one);
                    first = false;
                }
                return sb.ToString();
            }
        }
    }

    class RankClient
    {
        const double HelloEvery = 20, HelloFast = 3, AfterMatchFast = 240;   // 秒：平时 / 还没拿到分数时 / 打完后几分钟内（等结算）
        const double RetryEvery = 3, GiveUpAfter = 600, AliveEvery = 2, LostAfter = 6;

        readonly string keyPath;
        string key;
        public string Pid { get; private set; }
        string sec;

        UdpClient sock;
        IPEndPoint server;
        string serverText;
        DateTime lastResolve = DateTime.MinValue, lastHello = DateTime.MinValue, lastAlive = DateTime.MinValue, lastFromServer = DateTime.MinValue;
        DateTime fastUntil = DateTime.MinValue, startedAt = DateTime.MinValue, probeAt = DateTime.MinValue;
        // 最近一次发出要回话的请求（RHELLO / RTOP）。"没回应"只看问了没回：以前看"8 秒没收到包"，
        // 拿到分数后 20 秒才问一次，中间必然报没回应（用户 2026-11-06 截图，服务器其实好好的）
        DateTime askedAt = DateTime.MinValue;

        // 这台大厅服务器开没开排位：-1 还不知道，0 没开（没开 --ranked 的服务器不回 R 开头的包），1 开了。
        // 用户 2026-11-06："没开就隐藏标签"——0 时连接方式里不列"武林盟主"
        public int Support = -1;
        const double ProbeEvery = 30, ProbeWait = 8;

        // 给游戏内面板看的（WriteLobby 写进 lobby.txt）
        public string Me = "", Rules = "", Error = "", Note = "", TopHead = "";
        // 上一局的结算：<序号>|<胜 1 / 负 0 / 作废 ->|<分数变化>|<现在的分数>|<名次>|<ok / cap / void>；序号每次 +1，游戏看到变了就在屏幕上提示
        public string Result = "";
        int resultSeq;
        public List<string[]> Top = new List<string[]>();
        // §110.11 统计页：<种类 w/e/m>|<赛季>|<页>|<总页数>|<本赛季计入的人次>；行 = 武器 / 影之武装：名字 人次 使用率 胜率，招式：名字 放出 命中率 被格挡率 平均伤害
        public string StatHead = "";
        public List<string[]> StatRows = new List<string[]>();
        public Action<string> Log = delegate { };
        int rating = -1, ratingBefore = -1;
        string nick = "";

        readonly Dictionary<string, string[]> who = new Dictionary<string, string[]>();     // pid → {昵称, 分数, 名次, 称号}
        readonly Dictionary<string, DateTime> whoAsked = new Dictionary<string, DateTime>();

        class Match { public string Sid, Mid, Opp; public Session Ses; public bool Ended; public DateTime LostSince = DateTime.MinValue; }
        public readonly MatchStats Stats = new MatchStats();     // §110.11 Session（本机包）/ ServerLink（对方包）往里记
        Match cur;
        class Pending { public string Kind, Sid, Mid; public string[] Fields; public DateTime Next, Until; }
        readonly List<Pending> pend = new List<Pending>();

        public RankClient(string dir)
        {
            keyPath = Path.Combine(dir, "rank_key.txt");
            LoadKey();
        }

        // ---- 密钥：net\rank_key.txt（key=64 位十六进制）。pid = sha256(sec) 前 16 位，sec = sha256("pbz-rank|" + key)
        void LoadKey()
        {
            string k = null;
            try { if (File.Exists(keyPath)) foreach (var line in File.ReadAllLines(keyPath)) if (line.StartsWith("key=")) k = line.Substring(4).Trim(); }
            catch (Exception) { }
            if (!ValidKey(k))
            {
                var b = new byte[32];
                using (var rng = new RNGCryptoServiceProvider()) rng.GetBytes(b);
                k = Hex(b);
                SaveKey(k);
            }
            SetKey(k);
        }

        void SaveKey(string k)
        {
            try { File.WriteAllText(keyPath, "key=" + k + "\n", Kv.Utf8); }
            catch (Exception ex) { Error = L.T("存不了排位密钥：", "Can't save the ranked key: ") + ex.Message; }
        }

        void SetKey(string k)
        {
            key = k;
            sec = Sha(Kv.Utf8.GetBytes("pbz-rank|" + k));
            Pid = Sha(Kv.Utf8.GetBytes(sec)).Substring(0, 16);
            Me = ""; rating = -1; ratingBefore = -1; Note = "";
            lastHello = DateTime.MinValue;
        }

        static bool ValidKey(string k)
        {
            if (k == null || k.Length != 64) return false;
            foreach (var c in k) if ("0123456789abcdef".IndexOf(c) < 0) return false;
            return true;
        }

        public string ExportKey() { return key; }

        // 换电脑：导入别处导出的密钥。联机中不能换（上报用的是开局时的身份）
        public bool ImportKey(string k, out string why)
        {
            k = (k ?? "").Trim().ToLowerInvariant();
            if (k.StartsWith("key=")) k = k.Substring(4);
            if (!ValidKey(k)) { why = L.T("剪贴板里不是排位密钥（64 位十六进制）", "The clipboard does not hold a ranked key (64 hex digits)"); return false; }
            if (cur != null && !cur.Ended) { why = L.T("排位对局中不能换密钥", "Can't change the key during a ranked match"); return false; }
            SaveKey(k);
            SetKey(k);
            why = "";
            return true;
        }

        static string Hex(byte[] b)
        {
            var sb = new StringBuilder(b.Length * 2);
            foreach (var x in b) sb.Append(x.ToString("x2"));
            return sb.ToString();
        }

        static string Sha(byte[] b) { using (var h = SHA256.Create()) return Hex(h.ComputeHash(b)); }

        static string Clean(string s) { return LobbyServer.Clean(s ?? "").Trim(); }
        static string Ts() { return ((long)Link.UnixNow()).ToString(); }

        // 签名：HMAC-SHA256(sec, 字段从命令名起用 | 连起来)
        string Signed(params string[] f)
        {
            var body = string.Join("|", f);
            using (var h = new HMACSHA256(Kv.Utf8.GetBytes(sec))) return "PBZS|" + body + "|" + Hex(h.ComputeHash(Kv.Utf8.GetBytes(body)));
        }

        void Raw(string text)
        {
            if (sock == null || server == null) return;
            var b = Kv.Utf8.GetBytes(text);
            try { sock.Send(b, b.Length, server); } catch (Exception) { }
        }

        // ---- 每个 Tick 调一次。active = 现在选的是武林盟主方式（或者正连着排位房间）；s = 当前联机（可以是 null）
        public void Poll(string addr, string myNick, bool active, Session s)
        {
            var now = DateTime.UtcNow;
            nick = Clean(myNick);
            if (addr != serverText)
            {
                serverText = addr;
                server = null;
                lastResolve = DateTime.MinValue;
                probeAt = DateTime.MinValue;
                Support = addr.Trim().Length == 0 ? 0 : -1;
                Me = ""; Rules = ""; Top.Clear(); TopHead = "";
            }
            if (addr.Trim().Length == 0) { Support = 0; return; }
            if (server == null)
            {
                if ((now - lastResolve).TotalSeconds < 5) return;
                lastResolve = now;
                server = LobbyServer.Resolve(addr);
                if (server == null)
                {
                    Support = 0;
                    Error = addr.Trim().Length == 0 ? L.T("先在设置里填大厅服务器地址", "Set the lobby server first") : L.T("认不出大厅服务器地址：", "Can't resolve the lobby server: ") + addr;
                    return;
                }
                Error = "";
                lastHello = DateTime.MinValue;
                startedAt = now;
            }
            if (sock == null)
            {
                try
                {
                    sock = new UdpClient(new IPEndPoint(NetBind.Addr, 0));
                    try { sock.Client.IOControl(-1744830452, new byte[] { 0, 0, 0, 0 }, null); } catch (Exception) { }
                }
                catch (Exception ex) { Error = ex.Message; return; }
            }
            Receive(now);
            // 问一下服务器开没开排位（顺带拿排行榜第 1 页）：问了 8 秒没回 R 开头的包 = 没开；之后每 30 秒再问，开了标签会出来
            if (probeAt != DateTime.MinValue && Support != 1 && lastFromServer < probeAt && (now - probeAt).TotalSeconds > ProbeWait) Support = 0;
            if ((now - probeAt).TotalSeconds > ProbeEvery && !(active && Support == 1))
            {
                probeAt = askedAt = now;
                Raw("PBZS|RTOP|1");
            }
            double every = Me.Length == 0 ? HelloFast : now < fastUntil ? 5 : HelloEvery;
            if (active && (now - lastHello).TotalSeconds > every)
            {
                lastHello = askedAt = now;
                Raw(Signed("RHELLO", Pid, Ts(), nick));
            }
            if (active && askedAt > lastFromServer && (now - askedAt).TotalSeconds > 6)
                Error = NoAnswer();
            Track(s, now);
            foreach (var p in pend.ToArray())
            {
                if (now > p.Until) { pend.Remove(p); Log(L.T("排位上报一直没收到回音，放弃：", "Ranked report never acknowledged, gave up: ") + p.Kind + " " + p.Mid); continue; }
                if (now < p.Next) continue;
                p.Next = now.AddSeconds(RetryEvery);
                var f = (string[])p.Fields.Clone();
                f[2] = Ts();       // 每次重发换时间戳（服务器按签名去重，同一局的结果只认第一次）
                Raw(Signed(f));
            }
        }

        void Receive(DateTime now)
        {
            while (true)
            {
                int avail;
                try { avail = sock.Available; } catch (Exception) { break; }
                if (avail <= 0) break;
                IPEndPoint from = null;
                byte[] data;
                try { data = sock.Receive(ref from); } catch (Exception) { break; }
                if (!from.Equals(server)) continue;
                lastFromServer = now;
                Support = 1;
                if (Error == NoAnswer()) Error = "";
                var text = Kv.Utf8.GetString(data);
                var lines = text.Split('\n');
                var f = lines[0].Split('|');
                if (f.Length < 2 || f[0] != "PBZS") continue;
                switch (f[1])
                {
                    case "RME":       // RME|pid|分数|名次|胜|负|称号|赛季
                        if (f.Length < 9 || f[2] != Pid) break;
                        int r;
                        if (int.TryParse(f[3], out r))
                        {
                            // 旧服务端不推 RRESULT：看打完后分数变了多少
                            if (ratingBefore >= 0 && r != ratingBefore && (cur == null || cur.Ended))
                                SetResult(r > ratingBefore ? "1" : "0", r - ratingBefore, r, f[4], "ok");
                            rating = r;
                        }
                        Me = f[3] + "|" + f[4] + "|" + f[5] + "|" + f[6] + "|" + f[7] + "|" + f[8];
                        if (Error.Length > 0 && !Error.StartsWith(L.T("存不了", "Can't save"))) Error = "";
                        break;
                    case "RRULES":
                        if (f.Length > 2) Rules = f[2];
                        break;
                    case "RERR":
                        var why = f.Length > 2 ? f[2] : "";
                        if (why == "unknown") { Raw("PBZS|RREG|" + Pid + "|" + sec + "|" + nick); break; }
                        Error = why == "taken" ? L.T("排位账号冲突（密钥对不上），换一个密钥", "Ranked account conflict: use another key")
                              : why == "stale" ? L.T("电脑时间和服务器差太多，校准一下系统时间", "Your clock is off: sync the system time")
                              : why == "badsig" ? L.T("排位签名不对（密钥坏了？）", "Bad ranked signature (broken key?)")
                              : L.T("排位服务器报错：", "Ranked server error: ") + why;
                        break;
                    case "RACK":      // RACK|sid|mid|start / res / nosession
                        if (f.Length < 5) break;
                        pend.RemoveAll(p => p.Sid == f[2] && p.Mid == f[3] && (p.Kind == f[4] || f[4] == "nosession"));
                        if (f[4] == "nosession") Log(L.T("服务器不认这局排位（会话不对），这局不计分", "The server doesn't know this ranked session; not rated"));
                        break;
                    case "RRESULT":   // RRESULT|sid|mid|胜负|变化|分数|名次|ok / cap / void：服务器结算后推过来
                        if (f.Length < 9) break;
                        int dr, nr;
                        if (!int.TryParse(f[5], out dr) || !int.TryParse(f[6], out nr)) break;
                        rating = nr;
                        SetResult(f[4], dr, nr, f[7], f[8]);
                        lastHello = DateTime.MinValue;     // 马上再问一次我的信息（名次 / 胜负场跟着更新）
                        break;
                    case "RSTATSR":   // §110.11 RSTATSR|种类|赛季|页|总页数|人次 \n 一行一个（\t 分隔）
                        if (f.Length < 7) break;
                        StatHead = f[2] + "|" + f[3] + "|" + f[4] + "|" + f[5] + "|" + f[6];
                        StatRows = new List<string[]>();
                        for (int i = 1; i < lines.Length; i++)
                        {
                            var p = lines[i].Split('\t');
                            if (p.Length >= 4) StatRows.Add(p);
                        }
                        break;
                    case "RTOPS":     // RTOPS|赛季|页|总页数 \n 名次\t昵称\t分数\t胜\t负\t称号
                        if (f.Length < 5) break;
                        TopHead = f[2] + "|" + f[3] + "|" + f[4];
                        Top = new List<string[]>();
                        for (int i = 1; i < lines.Length; i++)
                        {
                            var p = lines[i].Split('\t');
                            if (p.Length >= 6) Top.Add(p);
                        }
                        break;
                    case "RWHOIS":    // RWHOIS|pid|昵称|分数|名次|称号
                        if (f.Length >= 7) who[f[2]] = new[] { f[3], f[4], f[5], f[6] };
                        break;
                }
            }
        }

        void SetResult(string win, int d, int r, string rank, string code)
        {
            ratingBefore = -1;
            var ds = (d > 0 ? "+" : "") + d;
            Note = code == "void" ? L.T("上一局两边报的结果对不上，作废", "Last match: reports disagreed, not rated")
                 : code == "cap" ? L.T("上一局不计分（今天和这位对手已经记了 3 场），现在 " + r, "Last match not rated (3 rated matches with this opponent today), now " + r)
                 : L.T("上一局 " + ds + "，现在 " + r, "Last match " + ds + ", now " + r);
            Result = (++resultSeq) + "|" + win + "|" + ds + "|" + r + "|" + rank + "|" + code;
            Log(Note);
        }

        string NoAnswer() { return L.T("大厅服务器没回应：", "The lobby server is not answering: ") + LobbyServer.Show(serverText, server); }

        public void RequestStats(string kind, int page)
        {
            askedAt = DateTime.UtcNow;
            Raw("PBZS|RSTATS|" + (kind == "e" || kind == "m" ? kind : "w") + "|" + Math.Max(1, page));
        }

        public void RequestTop(int page)
        {
            if (page < 1) page = 1;
            askedAt = DateTime.UtcNow;
            Raw("PBZS|RTOP|" + page);
        }

        // 对方的称号（"武林盟主" / 空）；没问过就问一次（30 秒内不重复问）
        public string TitleOf(string pid)
        {
            if (string.IsNullOrEmpty(pid)) return "";
            string[] w;
            if (who.TryGetValue(pid, out w)) return w[3];
            DateTime t;
            if (!whoAsked.TryGetValue(pid, out t) || (DateTime.UtcNow - t).TotalSeconds > 30)
            {
                whoAsked[pid] = DateTime.UtcNow;
                Raw("PBZS|RWHO|" + pid);
            }
            return "";
        }

        void Queue(string kind, string sid, string mid, params string[] fields)
        {
            pend.Add(new Pending { Kind = kind, Sid = sid, Mid = mid, Fields = fields, Next = DateTime.MinValue, Until = DateTime.UtcNow.AddSeconds(GiveUpAfter) });
        }

        void Report(bool win, string why)
        {
            cur.Ended = true;
            fastUntil = DateTime.UtcNow.AddSeconds(AfterMatchFast);
            Queue("res", cur.Sid, cur.Mid, "RRES", Pid, "", cur.Sid, cur.Mid, cur.Opp, win ? "1" : "0", why);
            Stats.Stop();
            Queue("stat", cur.Sid, cur.Mid, "RSTAT", Pid, "", cur.Sid, cur.Mid, Stats.Payload());     // §110.11 只有记了分的局服务器才算
            Log(L.T("排位对局 #" + cur.Mid + " 上报：" + (win ? "胜" : "负") + "（" + why + "）",
                    "Ranked match #" + cur.Mid + " reported: " + (win ? "win" : "loss") + " (" + why + ")"));
        }

        // §110.2 从主机的 mt=<状态>:<回合>:<主机分>:<客机分>:<赢家>:<局号> 判开局 / 打完；弃权看 quit=，掉线看连接
        void Track(Session s, DateTime now)
        {
            var sl = s != null ? s.T as IRoomLink : null;     // §135 武林盟主是 RankedLink（对局走 Steam），服务器大厅是 ServerLink
            bool ranked = sl != null && s.Mode == "ranked" && sl.Sid != null;
            // 2026-11-06 用户在对局中点"断开"测试，两局都作废了：以前会话号一变就当"自己走了"报输，可主机这边会话号变
            // 是对方断了又重新加入（主机的连接一直在），两边都报输 → 对不上。现在分开：
            //   我这边的联机没了 / 换了一个（点了断开、换了房间）→ 算我输；同一个联机、会话号变了（对方走了又回来 / 客机掉线后自动重连）→ 当对方掉线，报赢
            if (cur != null && !cur.Ended && (!ranked || !ReferenceEquals(s, cur.Ses)))
            {
                Report(false, "quit");
                return;
            }
            if (cur != null && !cur.Ended && sl.Sid != cur.Sid)
            {
                Report(true, "drop");
                return;
            }
            if (!ranked) return;
            bool host = s.Role == "host";
            var mt = host ? s.LocalMt : sl.PeerMt;
            var p = (mt ?? "").Split(':');
            string state = p.Length == 6 ? p[0] : "", id = p.Length == 6 ? p[5] : "";
            bool fighting = state == "cd" || state == "fight" || state == "rend";
            var opp = sl.PeerRk;
            // 新的一局只认"第 1 回合倒计时"：断线重连后主机那边还停在上一局的回合里，不能当成新的一局（2026-11-06 第二局作废就是这么来的）
            bool begin = state == "cd" && p[1] == "1";
            if (begin && !string.IsNullOrEmpty(opp) && opp != Pid && (cur == null || cur.Mid != id || cur.Sid != sl.Sid))
            {
                if (cur != null && !cur.Ended) Report(false, "quit");
                cur = new Match { Sid = sl.Sid, Mid = id, Opp = opp, Ses = s };
                Stats.Start();
                ratingBefore = rating;
                Queue("start", cur.Sid, cur.Mid, "RSTART", Pid, "", cur.Sid, cur.Mid, opp);
                Log(L.T("排位对局 #" + id + " 开始", "Ranked match #" + id + " started"));
            }
            if (cur == null || cur.Ended) return;
            if ((now - lastAlive).TotalSeconds > AliveEvery)
            {
                lastAlive = now;
                Raw("PBZS|RALIVE|" + Pid + "|" + cur.Sid + "|" + cur.Mid);
            }
            if (!s.Connected)
            {
                if (cur.LostSince == DateTime.MinValue) cur.LostSince = now;
                if ((now - cur.LostSince).TotalSeconds > LostAfter) Report(true, "drop");
                return;
            }
            cur.LostSince = DateTime.MinValue;
            if (id != cur.Mid && !fighting && state != "idle") return;
            int me, op;
            if (state == "end" && id == cur.Mid && int.TryParse(p[2], out me) && int.TryParse(p[3], out op))
                Report(host ? me > op : op > me, "end");
            else if (state == "idle" || (id != cur.Mid && state.Length > 0))
            {
                // 没经过 end 就回到自由活动 = 有人弃权。客机弃权会在自己的状态包里带 quit=<局号>；主机弃权没有这个标记
                bool clientQuit = (host ? sl.PeerQuit : s.LocalQuit) == cur.Mid;
                Report(host ? clientQuit : !clientQuit, "quit");
            }
        }

        // 给 lobby.txt：rk / rkpid / rkrules / rkme / rkerr / rknote / rktop / rkn / rkt1..（rk* 行里的 | 是字段分隔，原样写）
        public void WriteLobby(StringBuilder sb, bool active)
        {
            Action<string, string> raw = (k, v) => sb.Append(k).Append('=').Append((v ?? "").Replace("\r", " ").Replace("\n", " ")).Append('\n');
            raw("rk", active ? "1" : "0");
            if (!active) return;
            raw("rkpid", Pid);
            raw("rkrules", Rules);
            raw("rkme", Me);
            raw("rkerr", Error);
            raw("rknote", Note);
            raw("rkres", Result);
            raw("rktop", TopHead);
            raw("rkn", Top.Count.ToString());
            for (int i = 0; i < Top.Count && i < 10; i++)
            {
                raw("rkt" + (i + 1), string.Join("|", Top[i], 0, 6).Replace("\t", " "));
                raw("rkw" + (i + 1), Top[i].Length > 6 ? Top[i][6] : "");     // §110.11 这名玩家本赛季用得最多的武器（旧服务端没有这列）
            }
            // §110.11 统计页：rkstat=<种类>|<赛季>|<页>|<总页数>|<人次>，rksn=行数，rks1..rks10=<列…>（| 分隔）
            raw("rkstat", StatHead);
            raw("rksn", StatRows.Count.ToString());
            for (int i = 0; i < StatRows.Count && i < 10; i++)
                raw("rks" + (i + 1), string.Join("|", StatRows[i]).Replace("\t", " "));
        }

        public void Close() { if (sock != null) { try { sock.Close(); } catch (Exception) { } sock = null; } }
    }
}
