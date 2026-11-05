// 连接方式的辅助（net-ui 分支，docs/NETWORK_UI.md §2.3）：模式名、配置文件、UPnP 端口映射、Tailscale 节点、地址解析。
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Reflection;
using System.Threading;
using System.Web.Script.Serialization;

namespace PbzLobby
{
    // 连接方式。steam / steamlobby 走 Steam P2P；lan 是 UDP；
    // v0.20.3：广域网（wan）并进服务器大厅（用户："广域网没有房间列表，只能一对一输入 IP，作为服务器大厅下的一个子选项就可以"）——
    // 服务器大厅里"输入 IP 直连"走原来广域网的 UDP 直连；主机监听设置里的端口，没人经大厅加入时也接受直接连进来的客机。
    // v0.20.2：虚拟局域网（vlan）并进局域网（用户："虚拟局域网的软件装好连通后，走局域网联机就行"）——局域网顺带单播给
    // Tailscale 节点、列出节点、显示 / 复制虚拟网卡地址。旧配置 / 旧面板发来的 vlan 一律当 lan（Valid）；
    // server 是自建服务器大厅（UDP 打洞，不通走服务器中转，ServerLobby.cs）。顺序 = 游戏内面板按 End 换方式的顺序
    static class Modes
    {
        public static readonly string[] All = { "server", "lan", "ai" };     // §98 发布版（build.bat release）不带 Steam 两种方式

        public static string Valid(string m) { return m == "wan" ? "server" : Array.IndexOf(All, m) >= 0 ? m : "lan"; }     // vlan → lan、wan → server

        // §85 能开房的方式（AI 对战时等人的房间）：除了 ai 都行，顺序同 All
        public static readonly string[] Rooms = { "server", "lan" };
        public static string ValidRoom(string m) { m = Valid(m); return m == "ai" ? "lan" : m; }

        // 要登 Steam 的方式（选了才初始化 Steam，见 Steam.cs 文件头）
        public static bool IsSteam(string m) { return m == "steam" || m == "steamlobby"; }

        public static string Name(string m)
        {
            switch (m)
            {
                case "steam": return L.T("Steam 好友", "Steam friends");
                case "server": return L.T("服务器大厅（含 IP 直连）", "Lobby server (incl. direct IP)");
                case "steamlobby": return L.T("Steam 大厅", "Steam lobby");
                case "ai": return L.T("本地 AI 对战（不联网）", "Local AI battle (offline)");
                default: return L.T("局域网（含 Tailscale / ZeroTier）", "LAN (incl. Tailscale / ZeroTier)");
            }
        }
    }

    // net\netcfg.txt：上次的方式、端口、昵称、UPnP 开关、大厅服务器地址、最近连过的地址（每种方式各 5 个）
    class Cfg
    {
        public string Mode = "lan", Name = Environment.MachineName;
        // 服务器大厅的地址 "域名或IP[:端口]"（默认端口 LobbyServer.DefaultPort）。默认空：发布版不连作者的服务器，
        // 玩家自己架（server/README.md）或填别人架的；netcfg.txt 里有 server= 的以文件为准
        public string Server = "";
        public int Port = Session.GamePort;
        public bool Upnp;
        public int AiLevel = 1;     // §75 本地 AI 难度：0 简单 / 1 普通 / 2 困难（LocalAi.Levels）
        public bool AiRoom;                 // §85 AI 对战时同时开房等真人（开关）
        public string AiRoomMode = "lan";   // §85 等人的房间用哪种连接方式（不能是 ai）
        public string Secret = "";     // v0.22.0 联机密码（明文存这里：只是两个人对局用的共享口令）；空 = 不签名
        public readonly Dictionary<string, List<string>> Recent = new Dictionary<string, List<string>>();
        readonly string path;

        public Cfg(string dir)
        {
            path = Path.Combine(dir, "netcfg.txt");
            var d = Kv.Read(path);
            if (d == null) return;
            string v;
            int n;
            if (d.TryGetValue("mode", out v)) Mode = Modes.Valid(v);
            if (d.TryGetValue("name", out v) && v.Length > 0) Name = v;
            if (d.TryGetValue("port", out v) && int.TryParse(v, out n) && n > 0 && n < 65536) Port = n;
            if (d.TryGetValue("upnp", out v)) Upnp = v == "1";
            int lv;
            if (d.TryGetValue("ailevel", out v) && int.TryParse(v, out lv) && lv >= 0 && lv <= 2) AiLevel = lv;
            if (d.TryGetValue("airoom", out v)) AiRoom = v == "1";
            if (d.TryGetValue("airoommode", out v)) AiRoomMode = Modes.ValidRoom(v);
            if (d.TryGetValue("server", out v)) Server = v.Trim();
            if (d.TryGetValue("secret", out v)) Secret = v.Trim();
            foreach (var m in Modes.All)
                if (d.TryGetValue("recent_" + m, out v) && v.Length > 0) Recent[m] = new List<string>(v.Split(','));
            // 旧版虚拟局域网 / 广域网的"最近"并到局域网 / 服务器大厅后面（去重、最多 5 个），下次保存时旧的键就没了
            MergeOld(d, "vlan", "lan");
            MergeOld(d, "wan", "server");
        }

        void MergeOld(Dictionary<string, string> d, string old, string into)
        {
            string v;
            if (!d.TryGetValue("recent_" + old, out v) || v.Length == 0) return;
            var l = RecentOf(into);
            foreach (var t in v.Split(',')) if (t.Length > 0 && !l.Contains(t) && l.Count < 5) l.Add(t);
        }

        public List<string> RecentOf(string mode)
        {
            List<string> l;
            if (!Recent.TryGetValue(mode, out l)) Recent[mode] = l = new List<string>();
            return l;
        }

        public void Remember(string mode, string target)
        {
            var l = RecentOf(mode);
            l.Remove(target);
            l.Insert(0, target.Replace(",", ""));
            while (l.Count > 5) l.RemoveAt(l.Count - 1);
            Save();
        }

        public void Save()
        {
            var sb = new System.Text.StringBuilder();
            sb.Append("mode=").Append(Mode).Append('\n').Append("name=").Append(Name.Replace("\n", " ")).Append('\n')
              .Append("port=").Append(Port).Append('\n').Append("upnp=").Append(Upnp ? 1 : 0).Append('\n')
              .Append("server=").Append(Server.Replace("\n", " ")).Append('\n')
              .Append("secret=").Append(Secret.Replace("\n", " ")).Append('\n')
              .Append("ailevel=").Append(AiLevel).Append('\n')
              .Append("airoom=").Append(AiRoom ? 1 : 0).Append('\n').Append("airoommode=").Append(AiRoomMode).Append('\n');
            foreach (var kv in Recent) sb.Append("recent_").Append(kv.Key).Append('=').Append(string.Join(",", kv.Value)).Append('\n');
            Kv.WriteAtomic(path, sb.ToString());
        }
    }

    static class Addr
    {
        // "IP[:端口]" 或主机名 → 端点；认不出返回 null
        public static IPEndPoint Parse(string text, int defPort)
        {
            text = (text ?? "").Trim();
            if (text.Length == 0) return null;
            int port = defPort;
            int c = text.LastIndexOf(':');
            if (c > 0)
            {
                if (!int.TryParse(text.Substring(c + 1), out port) || port <= 0 || port > 65535) return null;
                text = text.Substring(0, c);
            }
            IPAddress ip;
            if (!IPAddress.TryParse(text, out ip))
            {
                if (text.IndexOf('.') < 0) return null;
                try { ip = Array.Find(Dns.GetHostAddresses(text), a => a.AddressFamily == AddressFamily.InterNetwork); }
                catch (Exception) { ip = null; }
            }
            return ip == null || ip.AddressFamily != AddressFamily.InterNetwork ? null : new IPEndPoint(ip, port);
        }

        // 只认数字的 IPv4[:端口]（剪贴板用：不做 DNS，免得把一段随便的文字当主机名去解析）
        public static bool LooksLikeIp(string s)
        {
            s = (s ?? "").Trim();
            if (s.Length < 7 || s.Length > 21) return false;
            var host = s;
            int c = s.LastIndexOf(':');
            int port;
            if (c > 0) { host = s.Substring(0, c); if (!int.TryParse(s.Substring(c + 1), out port) || port <= 0 || port > 65535) return false; }
            IPAddress ip;
            return host.Split('.').Length == 4 && IPAddress.TryParse(host, out ip);
        }

        // "steam:76561198…" 或 17 位数字 → SteamID64；否则 0
        public static ulong SteamId(string s)
        {
            s = (s ?? "").Trim();
            if (s.StartsWith("steam:")) s = s.Substring(6);
            ulong v;
            return s.Length == 17 && s.StartsWith("7656") && ulong.TryParse(s, out v) ? v : 0;
        }

        // 有默认网关的那张网卡的 IPv4（UPnP 要告诉路由器转发到哪）
        public static IPAddress PrimaryLocal()
        {
            try
            {
                foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus != OperationalStatus.Up) continue;
                    var props = ni.GetIPProperties();
                    bool gw = false;
                    foreach (var g in props.GatewayAddresses)
                        if (g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any)) gw = true;
                    if (!gw) continue;
                    foreach (var ua in props.UnicastAddresses)
                        if (ua.Address.AddressFamily == AddressFamily.InterNetwork) return ua.Address;
                }
            }
            catch (Exception) { }
            return null;
        }

        public static bool IsVirtualLan(string ip)
        {
            // Tailscale 100.64.0.0/10；ZeroTier 地址段是用户自己定的，靠网卡名认（见 Program.LocalIps）
            var p = ip.Split('.');
            int a, b;
            return p.Length == 4 && int.TryParse(p[0], out a) && int.TryParse(p[1], out b) && a == 100 && b >= 64 && b < 128;
        }
    }

    // 广域网：用 Windows 自带的 UPnP（HNetCfg.NATUPnP，COM）让路由器把 UDP 端口转发到本机。路由器没开 UPnP 就失败，提示手动转发
    static class Upnp
    {
        public static volatile string Status = "";
        public static volatile string PublicIp = "";
        static int mapped;

        public static void MapAsync(int port)
        {
            Status = L.T("UPnP：正在请求路由器转发 UDP ", "UPnP: asking the router to forward UDP ") + port + "…";
            ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    var local = Addr.PrimaryLocal();
                    if (local == null) throw new Exception(L.T("没找到有网关的网卡", "no adapter with a gateway"));
                    var maps = Collection();
                    if (maps == null) throw new Exception(L.T("路由器没开 UPnP（或 Windows 的网络发现关了）", "the router has UPnP off (or Windows network discovery is off)"));
                    try { maps.GetType().InvokeMember("Remove", BindingFlags.InvokeMethod, null, maps, new object[] { port, "UDP" }); } catch (Exception) { }
                    var m = maps.GetType().InvokeMember("Add", BindingFlags.InvokeMethod, null, maps,
                                                        new object[] { port, "UDP", port, local.ToString(), true, "PBZ_MP" });
                    mapped = port;
                    string ext = "";
                    try { ext = (string)m.GetType().InvokeMember("ExternalIPAddress", BindingFlags.GetProperty, null, m, null); } catch (Exception) { }
                    PublicIp = ext ?? "";
                    Status = L.T("UPnP：已转发 UDP ", "UPnP: forwarding UDP ") + port + " → " + local
                             + (PublicIp.Length > 0 ? L.T("，公网 IP ", ", public IP ") + PublicIp : "");
                }
                catch (Exception ex)
                {
                    var e = ex is TargetInvocationException && ex.InnerException != null ? ex.InnerException : ex;
                    Status = L.T("UPnP 失败：", "UPnP failed: ") + e.Message + L.T("。请在路由器里手动把 UDP ", ". Forward UDP ") + port
                             + L.T(" 转发到本机", " to this PC in your router");
                }
            });
        }

        public static void Unmap()
        {
            int port = mapped;
            if (port == 0) return;
            mapped = 0;
            PublicIp = "";
            Status = "";
            ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    var maps = Collection();
                    if (maps != null) maps.GetType().InvokeMember("Remove", BindingFlags.InvokeMethod, null, maps, new object[] { port, "UDP" });
                }
                catch (Exception) { }
            });
        }

        static object Collection()
        {
            var t = Type.GetTypeFromProgID("HNetCfg.NATUPnP");
            if (t == null) return null;
            var nat = Activator.CreateInstance(t);
            return t.InvokeMember("StaticPortMappingCollection", BindingFlags.GetProperty, null, nat, null);
        }
    }

    // 虚拟局域网：Tailscale 不转发广播，所以主机把房间广播单播给每个在线节点；加入方也把在线节点列成可加入目标。
    // 节点表来自 `tailscale status --json`（没装 Tailscale 就是空表）；后台刷新，15 秒一次
    static class Tailscale
    {
        static volatile List<string[]> peers = new List<string[]>();   // {IP, 主机名}
        static DateTime at = DateTime.MinValue;
        static int busy;

        public static List<string[]> Peers()
        {
            if ((DateTime.UtcNow - at).TotalSeconds > 15 && Interlocked.Exchange(ref busy, 1) == 0)
            {
                at = DateTime.UtcNow;
                ThreadPool.QueueUserWorkItem(delegate { try { peers = Query(); } catch (Exception) { } finally { busy = 0; } });
            }
            return peers;
        }

        static string Exe()
        {
            var pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            var p = Path.Combine(pf, @"Tailscale\tailscale.exe");
            if (File.Exists(p)) return p;
            foreach (var d in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
            {
                try { var q = Path.Combine(d.Trim(), "tailscale.exe"); if (File.Exists(q)) return q; } catch (Exception) { }
            }
            return null;
        }

        static List<string[]> Query()
        {
            var list = new List<string[]>();
            var exe = Exe();
            if (exe == null) return list;
            var psi = new ProcessStartInfo(exe, "status --json")
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, StandardOutputEncoding = Kv.Utf8
            };
            string json;
            using (var p = Process.Start(psi))
            {
                json = p.StandardOutput.ReadToEnd();
                p.WaitForExit(3000);
            }
            return Parse(json);
        }

        // 只取 Peer 里在线的节点：HostName、TailscaleIPs 里的 IPv4
        public static List<string[]> Parse(string json)
        {
            var list = new List<string[]>();
            var root = new JavaScriptSerializer { MaxJsonLength = 1 << 24 }.DeserializeObject(json) as Dictionary<string, object>;
            object po;
            if (root == null || !root.TryGetValue("Peer", out po) || !(po is Dictionary<string, object>)) return list;
            foreach (var kv in (Dictionary<string, object>)po)
            {
                var n = kv.Value as Dictionary<string, object>;
                if (n == null) continue;
                object on, ips, host;
                if (!n.TryGetValue("Online", out on) || !(on is bool) || !(bool)on) continue;
                if (!n.TryGetValue("TailscaleIPs", out ips) || !(ips is object[])) continue;
                n.TryGetValue("HostName", out host);
                foreach (var ip in (object[])ips)
                {
                    var s = ip as string;
                    if (s != null && s.IndexOf(':') < 0) { list.Add(new[] { s, (host as string) ?? s }); break; }
                }
            }
            list.Sort((a, b) => string.CompareOrdinal(a[1], b[1]));
            return list;
        }
    }
}
