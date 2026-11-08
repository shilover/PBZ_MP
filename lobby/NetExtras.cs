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
#if !AOT
using System.Web.Script.Serialization;
#endif

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
        public static readonly string[] All = { "server", "ranked", "lan", "ai" };     // §98 发布版（build.bat release）不带 Steam 两种方式
        public static readonly string[] Known = All;

        public static string Valid(string m) { return m == "wan" ? "server" : Array.IndexOf(All, m) >= 0 ? m : "lan"; }     // vlan → lan、wan → server

        // §85 能开房的方式（AI 对战时等人的房间）：除了 ai 都行，顺序同 All
        public static readonly string[] Rooms = { "server", "lan" };
        public static string ValidRoom(string m) { m = Valid(m); return Array.IndexOf(Rooms, m) >= 0 ? m : "lan"; }     // ai / ranked（§110）不能开等人的房间

        // 要登 Steam 的方式（选了才初始化 Steam，见 Steam.cs 文件头）
        public static bool IsSteam(string m) { return m == "steam" || m == "steamlobby"; }

        // 走服务器大厅那一套（ServerLink）的方式：服务器大厅、§110 武林盟主（排位房间只在服务器大厅里登记）
        public static bool IsServer(string m) { return m == "server" || m == "ranked"; }

        public static string Name(string m)
        {
            switch (m)
            {
                case "steam": return L.T("Steam 好友", "Steam friends");
                case "server": return L.T("服务器大厅（含 IP 直连）", "Lobby server (incl. direct IP)");
                case "ranked": return L.T("武林盟主（排位，经大厅服务器）", "Ranked (via the lobby server)");
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
        public bool Relay;          // §102 服务器大厅：允许走服务器中转（默认关；服务器也得开 --relay）
        public int MaxSpec = 4;     // §141 房间设置：观战 / 排队人数上限（0 = 不让观战；0 / 2 / 4 / 8）
        public int AiLevel = 1;     // §75 本地 AI 难度：0 简单 / 1 普通 / 2 困难（LocalAi.Levels）
        public LocalAi.Loadout AiLoad = new LocalAi.Loadout();   // §114 AI 装备（aiw= / aie= / aio= / aimed= / aiacc=；不合法的值不认，用默认）
        public bool AiRoom;                 // §85 AI 对战时同时开房等真人（开关）
        public string AiRoomMode = "lan";   // §85 等人的房间用哪种连接方式（不能是 ai）
        public bool Steam;             // 公开版没有 Steam 方式
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
            if (d.TryGetValue("steam", out v)) Steam = v == "1";     // 要在认 mode 之前：藏着时 mode=steam 会被当成 lan
            if (d.TryGetValue("mode", out v)) Mode = Modes.Valid(v);
            if (d.TryGetValue("name", out v) && v.Length > 0) Name = v;
            if (d.TryGetValue("port", out v) && int.TryParse(v, out n) && n > 0 && n < 65536) Port = n;
            if (d.TryGetValue("upnp", out v)) Upnp = v == "1";
            if (d.TryGetValue("relay", out v)) Relay = v == "1";
            if (d.TryGetValue("maxspec", out v) && int.TryParse(v, out n) && n >= 0 && n <= 8) MaxSpec = n;
            SpecCfg.Max = MaxSpec;
            if (d.TryGetValue("specnoq", out v)) SpecCfg.NoQueue = v == "1";
            int lv;
            if (d.TryGetValue("ailevel", out v) && int.TryParse(v, out lv) && lv >= 0 && lv <= 2) AiLevel = lv;
            if (d.TryGetValue("aiw", out v)) AiLoad.SetWeapon(v);
            if (d.TryGetValue("aie", out v)) AiLoad.SetEdge(v);
            if (d.TryGetValue("aio", out v)) AiLoad.SetOutfit(v);
            if (d.TryGetValue("aimed", out v)) AiLoad.SetPotions(v);
            if (d.TryGetValue("aiacc", out v)) AiLoad.SetAcc(v);
            if (d.TryGetValue("airoom", out v)) AiRoom = v == "1";
            if (d.TryGetValue("airoommode", out v)) AiRoomMode = Modes.ValidRoom(v);
            if (d.TryGetValue("server", out v)) Server = v.Trim();
            if (d.TryGetValue("secret", out v)) Secret = v.Trim();
            foreach (var m in Modes.Known)
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
              .Append("relay=").Append(Relay ? 1 : 0).Append('\n').Append("steam=").Append(Steam ? 1 : 0).Append('\n')
              .Append("maxspec=").Append(MaxSpec).Append('\n').Append("specnoq=").Append(SpecCfg.NoQueue ? 1 : 0).Append('\n')
              .Append("steamset=1\n")     // §136 这一版起 steam= 是认真的（见构造函数）
              .Append("server=").Append(Server.Replace("\n", " ")).Append('\n')
              .Append("secret=").Append(Secret.Replace("\n", " ")).Append('\n')
              .Append("ailevel=").Append(AiLevel).Append('\n')
              .Append("aiw=").Append(AiLoad.WeaponWire()).Append('\n').Append("aie=").Append(AiLoad.Edge).Append('\n')
              .Append("aio=").Append(AiLoad.Outfit).Append('\n').Append("aimed=").Append(AiLoad.Potions).Append('\n')
              .Append("aiacc=").Append(AiLoad.AccWire()).Append('\n')
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

    // §130 非 Steam 方式（服务器大厅 / 输入 IP 直连 / 局域网）的连接诊断：net\net_conn.log，仿 §125 的 steam_conn.log。
    // 一行一个事件（带毫秒时间），只在事件发生时写，不每帧写；游戏里的联机程序每个进程第一次 Start 时把上一份改名成 net_conn.prev.log。
    // IP 一律经 Ip() 脱敏：只留前两段 + 本进程随机盐的短哈希（同一份日志里看得出是不是同一个地址，盐不落盘）。写失败吞掉
    static class NetLog
    {
        static string path;
        static bool rotated;
        static readonly object lk = new object();
        static readonly string salt = Guid.NewGuid().ToString("N");
        // 联机程序是哪种：csc 编的 exe / NativeAOT 编的无界面 exe（测试用）/ 游戏进程里的 pbz_lobby.dll（AotEntry 改成 DLL）
        public static string Build =
#if AOT
            "AOT exe";
#else
            "exe";
#endif

        // rotate：游戏里的联机程序（--bg / DLL）改名；命令行测试（RunCli）不改名（两个进程可能共用一个 net 目录）
        public static void Start(string dir, bool rotate)
        {
            try
            {
                lock (lk)
                {
                    path = Path.Combine(dir, "net_conn.log");
                    if (!rotate || rotated) return;
                    rotated = true;     // DLL 版面板"退出"后再开，还在同一个游戏进程里：不再改名
                    var prev = Path.Combine(dir, "net_conn.prev.log");
                    if (File.Exists(path)) { File.Delete(prev); File.Move(path, prev); }
                }
            }
            catch (Exception) { }
        }

        public static void W(string m)
        {
            var p = path;
            if (p == null) return;
            try
            {
                lock (lk)
                {
                    var b = Kv.Utf8.GetBytes(DateTime.Now.ToString("HH:mm:ss.fff ") + m + "\r\n");
                    using (var f = new FileStream(p, FileMode.Append, FileAccess.Write, FileShare.ReadWrite)) f.Write(b, 0, b.Length);
                }
            }
            catch (Exception) { }
        }

        // 203.0.113.7:27015 → "[公网]203.0.*.*#3fa2:27015"；内网 / 回环 / CGNAT（Tailscale 等）另标
        public static string Ip(IPEndPoint ep) { return ep == null ? "-" : Ip(ep.Address) + ":" + ep.Port; }
        public static string Ip(IPAddress a)
        {
            if (a == null) return "-";
            if (a.IsIPv4MappedToIPv6) a = a.MapToIPv4();
            var s = a.ToString();
            uint h = 2166136261;
            foreach (var c in salt + s) { h ^= c; h *= 16777619; }
            var tag = (h & 0xffff).ToString("x4");
            if (a.AddressFamily != AddressFamily.InterNetwork)
            {
                var g = s.Split(':');
                return "[IPv6]" + (g.Length > 1 ? g[0] + ":" + g[1] : "?") + ":*#" + tag;
            }
            var b = a.GetAddressBytes();
            string kind = b[0] == 127 ? "回环" : b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] < 32) || (b[0] == 192 && b[1] == 168) ? "内网"
                        : b[0] == 100 && b[1] >= 64 && b[1] < 128 ? "CGNAT/虚拟网" : "公网";
            return "[" + kind + "]" + b[0] + "." + b[1] + ".*.*#" + tag;
        }
        // 服务器发来的 "IP:端口" 文本；认不出也不原样写
        public static string Ip(string ipPort)
        {
            if (string.IsNullOrEmpty(ipPort)) return "（空）";
            var ep = LobbyServer.ParseEp(ipPort);
            return ep != null ? Ip(ep) : "（认不出的地址）";
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
            NetLog.W("UPnP：请求路由器转发 UDP " + port);
            Safe.Pool("upnp-map", delegate
            {
                try
                {
                    var local = Addr.PrimaryLocal();
                    if (local == null) throw new Exception(L.T("没找到有网关的网卡", "no adapter with a gateway"));
                    if (!Nat.Available()) throw new Exception(L.T("路由器没开 UPnP（或 Windows 的网络发现关了）", "the router has UPnP off (or Windows network discovery is off)"));
                    Nat.Remove(port);
                    string ext = Nat.Add(port, local.ToString());
                    mapped = port;
                    PublicIp = ext ?? "";
                    Status = L.T("UPnP：已转发 UDP ", "UPnP: forwarding UDP ") + port + " → " + local
                             + (PublicIp.Length > 0 ? L.T("，公网 IP ", ", public IP ") + PublicIp : "");
                    IPAddress pub;
                    NetLog.W("UPnP 成功：UDP " + port + " → " + NetLog.Ip(local) + "，路由器报的公网 IP "
                             + (IPAddress.TryParse(PublicIp, out pub) ? NetLog.Ip(pub) : "（没给）"));
                }
                catch (Exception ex)
                {
                    var e = ex is TargetInvocationException && ex.InnerException != null ? ex.InnerException : ex;
                    Status = L.T("UPnP 失败：", "UPnP failed: ") + e.Message + L.T("。请在路由器里手动把 UDP ", ". Forward UDP ") + port
                             + L.T(" 转发到本机", " to this PC in your router");
                    NetLog.W("UPnP 失败（UDP " + port + "）：" + e.Message);
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
            Safe.Pool("upnp-unmap", delegate
            {
                try
                {
                    Nat.Remove(port);
                }
                catch (Exception) { }
            });
        }

    }

    // 路由器的静态端口映射表（HNetCfg.NATUPnP 的 StaticPortMappingCollection）。
    // exe：COM 晚绑定（InvokeMember）。AOT 版（pbz_lobby.dll）：NativeAOT 不支持 COM 晚绑定，按接口的虚表直接调
    // （IUPnPNAT / IStaticPortMappingCollection / IStaticPortMapping 都是 IDispatch 双接口，前 7 格是 IUnknown + IDispatch）
    static class Nat
    {
#if !AOT
        static object Collection()
        {
            var t = Type.GetTypeFromProgID("HNetCfg.NATUPnP");
            if (t == null) return null;
            var nat = Activator.CreateInstance(t);
            return t.InvokeMember("StaticPortMappingCollection", BindingFlags.GetProperty, null, nat, null);
        }

        public static bool Available() { return Collection() != null; }

        public static void Remove(int port)
        {
            try
            {
                var maps = Collection();
                if (maps != null) maps.GetType().InvokeMember("Remove", BindingFlags.InvokeMethod, null, maps, new object[] { port, "UDP" });
            }
            catch (Exception) { }
        }

        // 返回路由器报的公网 IP（拿不到给 ""）
        public static string Add(int port, string local)
        {
            var maps = Collection();
            if (maps == null) throw new Exception("UPnP");
            var m = maps.GetType().InvokeMember("Add", BindingFlags.InvokeMethod, null, maps, new object[] { port, "UDP", port, local, true, "PBZ_MP" });
            try { return (string)m.GetType().InvokeMember("ExternalIPAddress", BindingFlags.GetProperty, null, m, null) ?? ""; } catch (Exception) { return ""; }
        }
#else
        static readonly Guid ClsidNat = new Guid("AE1E00AA-3FD5-403C-8A27-2BBDC30CD0E1"), IidNat = new Guid("B171C812-CC76-485A-94D8-B6B3A2794E99");
        [System.Runtime.InteropServices.DllImport("ole32")] static extern int CoInitializeEx(IntPtr reserved, uint model);
        [System.Runtime.InteropServices.DllImport("ole32")] static extern int CoCreateInstance(in Guid clsid, IntPtr outer, uint ctx, in Guid iid, out IntPtr obj);
        [System.Runtime.InteropServices.DllImport("oleaut32", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] static extern IntPtr SysAllocString(string s);
        [System.Runtime.InteropServices.DllImport("oleaut32")] static extern void SysFreeString(IntPtr b);

        static unsafe IntPtr Slot(IntPtr obj, int i) { return (*(IntPtr**)obj)[i]; }
        static unsafe void Release(IntPtr obj) { if (obj != IntPtr.Zero) ((delegate* unmanaged[Stdcall]<IntPtr, uint>)Slot(obj, 2))(obj); }

        // 线程池线程默认没进 COM 套间：进多线程套间（已经进过返回 S_FALSE / RPC_E_CHANGED_MODE，都能用）
        static unsafe IntPtr Collection()
        {
            CoInitializeEx(IntPtr.Zero, 0 /* COINIT_MULTITHREADED */);
            IntPtr nat, maps = IntPtr.Zero;
            if (CoCreateInstance(ClsidNat, IntPtr.Zero, 1 /* CLSCTX_INPROC_SERVER */, IidNat, out nat) < 0 || nat == IntPtr.Zero) return IntPtr.Zero;
            try
            {
                int hr = ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr*, int>)Slot(nat, 7))(nat, &maps);   // get_StaticPortMappingCollection
                return hr < 0 ? IntPtr.Zero : maps;   // 路由器没开 UPnP 时这里是 S_OK + NULL
            }
            finally { Release(nat); }
        }

        public static bool Available()
        {
            var maps = Collection();
            Release(maps);
            return maps != IntPtr.Zero;
        }

        public static unsafe void Remove(int port)
        {
            var maps = Collection();
            if (maps == IntPtr.Zero) return;
            var udp = SysAllocString("UDP");
            try { ((delegate* unmanaged[Stdcall]<IntPtr, int, IntPtr, int>)Slot(maps, 10))(maps, port, udp); }   // Remove(lExternalPort, bstrProtocol)
            finally { SysFreeString(udp); Release(maps); }
        }

        public static unsafe string Add(int port, string local)
        {
            var maps = Collection();
            if (maps == IntPtr.Zero) throw new Exception("UPnP");
            IntPtr udp = SysAllocString("UDP"), client = SysAllocString(local), desc = SysAllocString("PBZ_MP"), m = IntPtr.Zero;
            try
            {
                // Add(lExternalPort, bstrProtocol, lInternalPort, bstrInternalClient, bEnabled (VARIANT_BOOL), bstrDescription, ppSPM)
                int hr = ((delegate* unmanaged[Stdcall]<IntPtr, int, IntPtr, int, IntPtr, short, IntPtr, IntPtr*, int>)Slot(maps, 11))(maps, port, udp, port, client, -1, desc, &m);
                if (hr < 0) throw new Exception("UPnP Add 0x" + hr.ToString("X8"));
                if (m == IntPtr.Zero) return "";
                IntPtr ext = IntPtr.Zero;
                int hr2 = ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr*, int>)Slot(m, 7))(m, &ext);         // get_ExternalIPAddress
                string s = hr2 >= 0 && ext != IntPtr.Zero ? System.Runtime.InteropServices.Marshal.PtrToStringBSTR(ext) : "";
                if (ext != IntPtr.Zero) SysFreeString(ext);
                return s ?? "";
            }
            finally { SysFreeString(udp); SysFreeString(client); SysFreeString(desc); Release(m); Release(maps); }
        }
#endif
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
#if AOT
        // AOT 版没有 JavaScriptSerializer：用 System.Text.Json 读同样的字段
        public static List<string[]> Parse(string json)
        {
            var list = new List<string[]>();
            try
            {
                using (var doc = System.Text.Json.JsonDocument.Parse(json))
                {
                    System.Text.Json.JsonElement peers;
                    if (!doc.RootElement.TryGetProperty("Peer", out peers) || peers.ValueKind != System.Text.Json.JsonValueKind.Object) return list;
                    foreach (var kv in peers.EnumerateObject())
                    {
                        var n = kv.Value;
                        System.Text.Json.JsonElement on, ips, host;
                        if (!n.TryGetProperty("Online", out on) || on.ValueKind != System.Text.Json.JsonValueKind.True) continue;
                        if (!n.TryGetProperty("TailscaleIPs", out ips) || ips.ValueKind != System.Text.Json.JsonValueKind.Array) continue;
                        string h = n.TryGetProperty("HostName", out host) && host.ValueKind == System.Text.Json.JsonValueKind.String ? host.GetString() : null;
                        foreach (var ip in ips.EnumerateArray())
                        {
                            var s = ip.ValueKind == System.Text.Json.JsonValueKind.String ? ip.GetString() : null;
                            if (s != null && s.IndexOf(':') < 0) { list.Add(new[] { s, h ?? s }); break; }
                        }
                    }
                }
            }
            catch (Exception) { }
            list.Sort((a, b) => string.CompareOrdinal(a[1], b[1]));
            return list;
        }
#else
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
#endif
    }
}
