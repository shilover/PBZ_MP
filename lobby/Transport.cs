// 传输层接口（§98 从 Steam.cs 挪出来：发布版不编译 Steam.cs，见 build.bat release）。
using System;
using System.Collections.Generic;

namespace PbzLobby
{
    // 传输层：UDP（Link、ServerLink）和开发版的 Steam（SteamLink）都实现它；Session 只认这个接口
    interface ITransport
    {
        void Send(byte[] b);
        int Pump();                 // 收包，排队写 state_remote.txt（RemoteOut 每次写一个），返回有效状态包数
        string PeerStr { get; }
        string PeerName { get; }    // 显示用：Steam 名字；UDP 为空
        string PeerNick { get; }    // v0.18.7：对方在联机设置里填的昵称（状态包里的 nm=），还没收到时为空
        int LocalPort { get; }      // UDP 端口；Steam 为 0
        long Tx { get; }
        long Gap { get; }
        double PingMs { get; }      // Steam 报的 ping；UDP 用包里的发送时间估单程 ×2
        Action<string> Log { get; set; }
        RemoteOut Out { get; }      // §85 写 state_remote.txt 的队列（等人的房间转正时换路径）
        Wire Wire { get; set; }     // v0.22.0：收到的包先验签（Reliable.cs），事件 / 确认交给可靠通道；Session 设
        void Close();
    }

    // §141 房间设置：观战 / 排队人数上限（联机程序的 netcfg.txt maxspec=，面板改；0 = 不让观战）。
    // 发给观战者的包只留观战用得到的字段（Slim）：天赋 / 饰品被动、武器效果、攻击属性这些长字段观战用不上，每包小一大半
    static class SpecCfg
    {
        public static volatile int Max = 4;
        // §141 只观战、不排队上场（观战者自己的设置，netcfg specnoq=）：观战握手带 noq=1 / WATCH 第 5 段 noq，主机 / 服务器不把它排进队
        public static volatile bool NoQueue;
        // §141 观战者把开关切回"排队"：之后 3 秒观战握手带 up=1 / WATCH 第 4 段 up，主机 / 服务器去掉"刚下场、先不叫"的标记
        static long upUntil;
        public static void WantUp() { System.Threading.Interlocked.Exchange(ref upUntil, DateTime.UtcNow.AddSeconds(3).Ticks); }
        public static bool Up { get { return DateTime.UtcNow.Ticks < System.Threading.Interlocked.Read(ref upUntil); } }
        static readonly HashSet<string> Keep = new HashSet<string> {
            "v", "pv", "av", "seq", "map", "x", "y", "z", "yaw", "vx", "vy", "ev", "wc", "wcs", "arm", "of", "hr", "brk", "med", "sub", "dg",
            "air", "vz", "hp", "hpm", "sh", "shm", "mt", "dead", "nm", "src" };
        public static string Slim(string body)
        {
            var sb = new System.Text.StringBuilder(body.Length / 2);
            foreach (var raw in body.Split('\n'))
            {
                var line = raw.TrimEnd('\r');
                int eq = line.IndexOf('=');
                if (eq <= 0 || !Keep.Contains(line.Substring(0, eq))) continue;
                sb.Append(line).Append('\n');
            }
            return sb.ToString();
        }
    }

    // §141 观战：能当主机给观战者发包的传输（Link 直接发、ServerLink 经大厅服务器、SteamLink 经 Steam 连接），
    // 以及当观战者收两路包（src=h / src=c，按来源分别去重）
    interface ISpecSink
    {
        int SpecCount { get; }                  // 现在有几个观战者（0 = 不用转发）
        void SendSpecs(byte[] sealedPacket);    // 发给每个观战者
        Action<string> OnPeerState { get; set; }  // 主机：收到对手的一个状态包
        bool SpecMode { get; set; }             // 观战者：收主机转来的两路包
        Action<string> OnRole { get; set; }     // §141.7 观战者 / 对手：主机发来 PBZROLE（轮到你上场 / 你下场观战）
        int QPos { get; }                       // §141.7 观战者：排第几（0 = 不知道）
        int QLen { get; }
    }

    // §141.7 排队：主机这边能让观战者上场 / 让对手下场的传输（Link 按 IP 端点、SteamLink 按连接句柄，都当 object 用）
    interface IQueueHost
    {
        List<object> QueueOrder();              // 排队的观战者，先来的在前
        object PromoteHead();                   // 队首上场当对手，返回它（没人排队 = null）
        object DemotePeer();                    // 现在的对手下场排到队尾，返回它
        void SendTo(object who, byte[] sealedPacket);
        bool HasPeer { get; }
        double SinceFromPeer { get; }
        bool CanPromote { get; }                // 有人能上场（刚下场的那个不算）
    }

    // §141.8 主机下场：队首当第二位选手，两位选手的包都经主机互相转发（主机自己观战）。Link / SteamLink 实现
    interface IRelayHost
    {
        object PromoteSecond();                 // 队首当第二位选手（从队里拿掉），返回它
        object DemoteSecond();                  // 第二位选手下场排到队尾，返回它
        void SecondToPeer();                    // 第一位走了、没人补：第二位改当第一位（主机回来跟他打）
        bool HasSecond { get; }
        double SinceFromSecond { get; }
        Action<string> OnSecondState { get; set; }
        void SendSecond(byte[] sealedPacket);
        bool NoOut { get; set; }                // 转发时不把第一位的包直接交给游戏（Session 加上来源再交）
    }
}
