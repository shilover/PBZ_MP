// F5（docs/FORNET_F5_F6.md）：影之刃零给联机程序基底（fornet/lobby/GameInfo.cs）的那几样：名字、进程名、模组目录名、开局前备份存档。
// 编 PBZ 版联机程序时和 LocalAi.cs 一起经 FORNET_GAME_CS 加进去（deploy.bat / moecn_pack.py；公开导出直接放进 lobby/）。
// 值和 F5 之前写死在基底里的一字不差。
// §313 的备份规则（和上一个一样不备份、-mp 自动清理）4net 0.4.0 起在基底 SaveBackup 里，这里只给路径。
// 协议名 / 名字 / 版本仍编在这里、不写进 games\pbz\manifest.txt：测试和工具会在模组目录外单独跑联机程序，读不到 manifest 就会退回中性名、连不上已装的玩家。
// 只用 C# 5 语法（exe 用系统自带 csc 编）。
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;

namespace ForNet
{
    static partial class GameInfo
    {
        static partial void Configure()
        {
            ModName = "PBZ_MP";
            TitleZh = "影之刃零 联机"; TitleEn = "Phantom Blade Zero - LAN Battle";
            GameZh = "影之刃零"; GameEn = "Phantom Blade Zero";
            AppVersion = "0.34.8";     // §360.12 和 main.lua 的 VERSION 一致（以前写在 4net 的 Reliable.cs 里；make_release 会核对）
            ProcessName = "PBZ";
            // 4net 0.4.0：备份存档的代码搬进基底（SaveBackup，和以前这里的 PbzBackup 一样：账号子目录、-mp.zip、和上一个一样就跳过、20 个 / 14 天）
            BackupSave = () => SaveBackup.Run(SaveBackup.Resolve(Program.BaseDir, @"..\..\..\..\..\ProjectPBZ\Saved\SaveGames\Steam"),
                                              "PBZSaveGame.sav", "pbz-save-backups", DateTime.Now);
            RankedZh = "武林盟主"; RankedLongZh = "武林盟主排位"; RankedModeZh = "武林盟主（排位，经大厅服务器）";     // §360.9 提示文字里的排位名（4net 默认"排位"）
        }
    }

    // 线上协议名（fornet/lobby/WireTag.cs）：影之刃零从 0.1x 起就用这套，已装的玩家、已经在跑的大厅服务器都按它认包，一个字节都不能改。
    // 服务端用 tools/gen_pbz_server.py 生成的 server/pbz-lobby-server.mjs（同一套名字写成默认值）。
    static partial class WireTag
    {
        static partial void Configure()
        {
            S = "PBZS"; P = "PBZ"; Salt = "pbzmp"; EnvPrefix = "PBZ_"; Abi = "pbzx_"; Pipe = "pbz_bridge_";
        }
    }
}
