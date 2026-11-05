// 传输层接口（§98 从 Steam.cs 挪出来：发布版不编译 Steam.cs，见 build.bat release）。
using System;

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
}
