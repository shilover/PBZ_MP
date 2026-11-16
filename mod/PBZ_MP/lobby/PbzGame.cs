// F5（docs/FORNET_F5_F6.md）：影之刃零给联机程序基底（fornet/lobby/GameInfo.cs）的那几样：名字、进程名、模组目录名、开局前备份存档。
// 编 PBZ 版联机程序时和 LocalAi.cs 一起经 FORNET_GAME_CS 加进去（deploy.bat / moecn_pack.py；公开导出直接放进 lobby/）。
// 值和 F5 之前写死在基底里的一字不差。
// §313：存档和上一个备份一样就不备份；模组自己的备份（文件名带 -mp）自动清理：最近 20 个全留，14 天内每天留最后一个，更早的删。
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
            ProcessName = "PBZ";
            BackupSave = PbzBackup.Run;
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

    static class PbzBackup
    {
        const string SaveName = "PBZSaveGame.sav";
        const string MpSuffix = "-mp.zip";     // 模组自己打的备份；pbzsave.py 打的是 <id>-backup-<时间>.zip，不带 -mp，清理不碰
        public const int KeepRecent = 20;      // 最近这么多个全留
        public const int KeepDays = 14;        // 再往前：这么多天内每天留最后一个，更早的删

        // 联机程序在 <游戏>\platform\steam\ue4ss\Mods\PBZ_MP\ ；存档在 <游戏>\ProjectPBZ\Saved\SaveGames\Steam\<SteamID>\
        public static string Run()
        {
            try
            {
                var game = Path.GetFullPath(Path.Combine(Program.BaseDir, @"..\..\..\..\.."));
                return RunIn(Path.Combine(game, @"ProjectPBZ\Saved\SaveGames\Steam"), DateTime.Now);
            }
            catch (Exception ex) { return L.T("备份失败：", "backup failed: ") + ex.Message; }
        }

        // steam = SaveGames\Steam；拆出来给离线测试用
        public static string RunIn(string steam, DateTime now)
        {
            try
            {
                if (!Directory.Exists(steam)) return L.T("找不到存档目录，跳过备份", "save folder not found, backup skipped");
                var outDir = Path.Combine(steam, "pbz-save-backups");
                Directory.CreateDirectory(outDir);
                int made = 0, same = 0, removed = 0;
                foreach (var dir in Directory.GetDirectories(steam))
                {
                    var sav = Path.Combine(dir, SaveName);
                    if (!File.Exists(sav)) continue;
                    var id = Path.GetFileName(dir);
                    if (SameAsLatest(outDir, id, sav)) same++;
                    else
                    {
                        WriteZip(dir, Path.Combine(outDir, id + "-backup-" + now.ToString("yyyyMMdd-HHmmss") + MpSuffix));
                        made++;
                    }
                    removed += Prune(outDir, id, now);
                }
                string msg;
                if (made > 0) msg = L.T("已备份存档（存档目录\\pbz-save-backups）", "save backed up (save folder\\pbz-save-backups)");
                else if (same > 0) msg = L.T("存档和上一个备份一样，没再备份", "save unchanged since last backup, skipped");
                else msg = L.T("没有找到存档，跳过备份", "no save found, backup skipped");
                if (removed > 0) msg += L.T("；清掉 " + removed + " 个旧的自动备份", "; removed " + removed + " old automatic backups");
                return msg;
            }
            catch (Exception ex) { return L.T("备份失败：", "backup failed: ") + ex.Message; }
        }

        static void WriteZip(string dir, string zip)
        {
            var tmp = zip + ".part";
            using (var fs = new FileStream(tmp, FileMode.Create))
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
            File.Move(tmp, zip);     // 写完才改名：写一半出错不会留下一个看着正常的坏备份
        }

        // <id>-backup-yyyyMMdd-HHmmss... 里的时间；认不出返回 false
        static bool Stamp(string file, string id, out DateTime t)
        {
            t = DateTime.MinValue;
            var name = Path.GetFileName(file);
            var pre = id + "-backup-";
            if (!name.StartsWith(pre, StringComparison.OrdinalIgnoreCase) || name.Length < pre.Length + 15) return false;
            return DateTime.TryParseExact(name.Substring(pre.Length, 15), "yyyyMMdd-HHmmss",
                System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out t);
        }

        // 最新的那个备份（模组的、pbzsave 的都算）里的 PBZSaveGame.sav 和现在的逐字节一样？读不出来就当不一样、照常备份
        static bool SameAsLatest(string outDir, string id, string sav)
        {
            string latest = null; DateTime best = DateTime.MinValue;
            foreach (var f in Directory.GetFiles(outDir, id + "-backup-*.zip"))
            {
                DateTime t;
                if (Stamp(f, id, out t) && t >= best) { best = t; latest = f; }
            }
            if (latest == null) return false;
            try
            {
                byte[] cur;
                using (var src = new FileStream(sav, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    cur = new byte[src.Length];
                    int n = 0, r;
                    while (n < cur.Length && (r = src.Read(cur, n, cur.Length - n)) > 0) n += r;
                    if (n != cur.Length) return false;
                }
                using (var zs = new FileStream(latest, FileMode.Open, FileAccess.Read, FileShare.Read))
                using (var za = new ZipArchive(zs, ZipArchiveMode.Read))     // 不用 ZipFile：exe 版没引用 System.IO.Compression.FileSystem
                {
                    var e = za.GetEntry(SaveName);
                    if (e == null || e.Length != cur.Length) return false;
                    using (var es = e.Open())
                    {
                        var buf = new byte[65536];
                        int pos = 0, r;
                        while ((r = es.Read(buf, 0, buf.Length)) > 0)
                        {
                            if (pos + r > cur.Length) return false;
                            for (int i = 0; i < r; i++) if (buf[i] != cur[pos + i]) return false;
                            pos += r;
                        }
                        return pos == cur.Length;
                    }
                }
            }
            catch { return false; }
        }

        // 只清模组自己的备份（-mp.zip）：最近 KeepRecent 个全留；再往前 KeepDays 天内每天留最后一个；其余删
        static int Prune(string outDir, string id, DateTime now)
        {
            var list = new List<KeyValuePair<DateTime, string>>();
            foreach (var f in Directory.GetFiles(outDir, id + "-backup-*" + MpSuffix))
            {
                DateTime t;
                if (Stamp(f, id, out t)) list.Add(new KeyValuePair<DateTime, string>(t, f));
            }
            list.Sort(delegate (KeyValuePair<DateTime, string> a, KeyValuePair<DateTime, string> b) { return b.Key.CompareTo(a.Key); });
            var days = new HashSet<DateTime>();
            var cutoff = now.Date.AddDays(-(KeepDays - 1));
            int removed = 0;
            for (int i = 0; i < list.Count; i++)
            {
                var day = list[i].Key.Date;
                bool firstOfDay = days.Add(day);
                if (i < KeepRecent) continue;
                if (firstOfDay && day >= cutoff) continue;
                try { File.Delete(list[i].Value); removed++; } catch { }
            }
            return removed;
        }
    }
}
