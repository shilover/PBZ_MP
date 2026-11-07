// 本地 AI 对手（HANDOVER §75，连接方式"本地 AI"）：tests/fake_remote.py 默认那一套（--ai on --rdy 1 --res-dmg 400，
// 当客机）搬成 C#，玩家不用装 Python。
// 不联网但走真的联机路径：MainForm 在本机开两个 Session——游戏这边当主机（net\），AI 当客机（net\ai\），127.0.0.1 互连；
// 本类只读写 net\ai\ 下的文件，和 fake_remote.py --peer 一样：读 state_remote.txt（= 你），写 state_local.txt（= AI 发给你的包）。
// 所以替身、判定、对局流程（主机 = 游戏的 matchStep）、可靠事件、Boss 血条都和真人联机是同一套代码。
// 规则改了要两边一起改：fake_remote.py 是离线测试用的那份。
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace PbzLobby
{
    class LocalAi
    {
        const string D = "GA_Hun_Double_";
        // 替身靠 wc= 换上双刃（绝影）；不发的话替身拿的是复制你的武器，双刃的招放不出（v0.23.4）
        const string WC = "/PBZCombatAsset/ActorData/Players/Hun/Weapon/Double/Weapon_Hun_JueYing.Weapon_Hun_JueYing";
        const double Dist = 400, Walk = 500, JumpDist = 3000, Hz = 30;
        const double ResDmg = 400, ResDelay = 0.4;                        // 你砍中它一刀扣 400；回报晚 0.4 秒（刀落下才判定）
        const double TouchWait = 1.5, TouchDelay = 0.1;                   // §107 等你的刀碰到它最多 1.5 秒，没碰到 = 落空；碰到后 0.1 秒回报
        const double DmgWait = 0.5;                                       // §115 中招后等模组 td= 报伤害最多 0.5 秒，还没有就按 400
        static readonly double[] DmSteps = { 50, 75, 100, 150, 200, 300 };   // §86 伤害倍率档位（同 main.lua NET.DM_STEPS）
        const double AiAir = 0.15, HopVz = 750, HopG = 1800, HopLead = 0.25;

        static readonly string[][] Combos = {
            new[] { D + "A_C", D + "AA_C", D + "AAA_C" }, new[] { D + "A_C", D + "AA_C", D + "AAA_C", D + "AAAA_C" },
            new[] { D + "B_C", D + "BB_C" }, new[] { D + "A_C", D + "AB_C" }, new[] { D + "B_Dash_C" }, new[] { D + "SWT_C" },
            new[] { D + "A_C", D + "AA_C" } };
        static readonly string[][] Skills = {
            new[] { D + "JueYing_C_C" }, new[] { D + "Buff_C" }, new[] { D + "C_C" },
            new[] { D + "A_Draw_C" }, new[] { D + "B_Draw_C" }, new[] { D + "ATB_C", D + "ATBB_C", D + "ATBBB_C" },
            new[] { D + "BTA_C" }, new[] { D + "A_DashDraw_Short_C" }, new[] { D + "B_DashDraw_C" },
            new[] { D + "A_Snap_C" }, new[] { D + "B_Snap_C" } };
        static readonly string[][] AirCombos = {
            new[] { D + "Air_A_C" }, new[] { D + "Air_B_C" }, new[] { D + "Air_A_Draw_C" }, new[] { D + "Air_A_C", "GA_Hun_Air_Double_AA_C" } };

        // 和 main.lua 的 isAttackAbility 一样（v0.23.4 排除法）
        static readonly string[] NotAttackFam = { "AdvancedDash", "SpecialDash", "StanceDash", "SEx", "SEd", "AEx", "AEd", "BEx", "BEd", "BDEx", "BDEd" };
        static readonly string[] NotAttackPart = { "Passive", "Stance", "Buff", "Drink", "Jump", "Sprint", "Run", "Walk", "ChangeArmed", "BreakEscape",
            "Execution", "UnArmed", "ToZui", "OutZui", "Summon", "Clone", "Reborn", "Deflect", "Dodge", "Switch", "Tutorial", "_UI", "GEd", "GEx", "_Base" };
        static readonly string[] EdgeSkip = { "Passive", "Execution", "Base", "Tutorial", "_UI_", "UpRun" };
        static readonly Regex HunRe = new Regex(@"^GA_Hun_([A-Za-z0-9]+)_(.+)_C$");

        // 难度（用户 2026-11-05："AI 模式分难度三档，通过攻击频率、精防频率之类的参数调整"）。普通 = fake_remote.py 的默认值
        public class Lv
        {
            public string Zh, En;
            public double Gap, Chain;              // 两套招之间停顿的倍率；一套里每一下间隔的倍率（越小越凶）
            public int Hit, Parry, Block;          // 你的刀的结果权重（中招 / 精防 / 普通防御）
            public double StanceP, GuardParry;     // 打完一套举架势的概率；举着架势时精防（其余普防）的概率
        }
        public static readonly Lv[] Levels = {
            new Lv { Zh = "简单", En = "Easy",   Gap = 1.7,  Chain = 1.3,  Hit = 80, Parry = 5,  Block = 15, StanceP = 0.1,  GuardParry = 0.3 },
            new Lv { Zh = "普通", En = "Normal", Gap = 1.0,  Chain = 1.0,  Hit = 60, Parry = 20, Block = 20, StanceP = 0.3,  GuardParry = 0.5 },
            new Lv { Zh = "困难", En = "Hard",   Gap = 0.55, Chain = 0.85, Hit = 35, Parry = 40, Block = 25, StanceP = 0.45, GuardParry = 0.7 } };
        public static string LevelName(int i) { var l = Levels[Math.Max(0, Math.Min(2, i))]; return L.T(l.Zh, l.En); }

        // §114 AI 装备（面板"AI 装备…"，netcfg.txt 的 aiw= / aie= / aio= / aimed= / aiacc=）。整个对象一起换（Load = new …），Run 线程下一帧用新的
        public class Loadout
        {
            public string Fam = "Double", Wc = WC;   // 武器：招式族（GA_Hun_<族>_*）+ 武器配置路径（状态包 w= / wc=）
            public string Edge = "";                 // 影之武装配置路径（wcs=）；空 = 照抄你装的
            public string Outfit = "";               // 皮肤行名（of=）；空 = 不发（替身穿本机的外观）
            public int Potions = 0;                  // 一回合能喝几次药（自己回血 + 发 med= 播喝药动作）；0 = 不喝
            public string Acc = null;                // 饰品被动（逗号分隔的 GA 名）；null = 不发 pas=（替身带的是本机的天赋 / 饰品），"" = 不带饰品

            static readonly Regex PathRe = new Regex(@"^/PBZCombatAsset/[A-Za-z0-9_/]+\.[A-Za-z0-9_]+$");
            static readonly Regex WordRe = new Regex(@"^[A-Za-z0-9_]+$");
            public const int MaxPotions = 10, MaxAcc = 4;

            public static bool ValidPath(string v) { return v != null && v.Length < 200 && PathRe.IsMatch(v); }
            public static bool ValidWord(string v) { return v != null && v.Length < 80 && WordRe.IsMatch(v); }

            // aiw= "<族>|<路径>"
            public bool SetWeapon(string v)
            {
                var p = (v ?? "").Split('|');
                if (p.Length != 2 || !ValidWord(p[0]) || !ValidPath(p[1])) return false;
                Fam = p[0]; Wc = p[1]; return true;
            }
            public bool SetEdge(string v) { v = (v ?? "").Trim(); if (v.Length > 0 && !ValidPath(v)) return false; Edge = v; return true; }
            public bool SetOutfit(string v) { v = (v ?? "").Trim(); if (v.Length > 0 && !ValidWord(v)) return false; Outfit = v; return true; }
            public bool SetPotions(string v)
            {
                int n;
                if (!int.TryParse((v ?? "").Trim(), out n) || n < 0 || n > MaxPotions) return false;
                Potions = n; return true;
            }
            // aiacc= "-"（照抄你的）/ "" / "GA_a,GA_b"
            public bool SetAcc(string v)
            {
                v = (v ?? "").Trim();
                if (v == "-") { Acc = null; return true; }
                var l = new List<string>();
                foreach (var a in v.Split(','))
                {
                    if (a.Length == 0) continue;
                    if (!ValidWord(a) || a.IndexOf("Accessory", StringComparison.Ordinal) < 0 || l.Count >= MaxAcc) return false;
                    if (!l.Contains(a)) l.Add(a);
                }
                Acc = string.Join(",", l); return true;
            }
            public string AccWire() { return Acc ?? "-"; }
            public string WeaponWire() { return Fam + "|" + Wc; }
            public Loadout Clone() { return (Loadout)MemberwiseClone(); }
        }

        class Ev { public int Id; public double T; public string Name; }
        class Ans { public int Rid; public double Seen; public string Kind; public double Dmg, Paid, Last = -1; }   // §115 Dmg 这招累计伤害，Paid 已扣的血，Last 最后一次在 td= 里

        readonly string abilFile;
        readonly GamePipe mb;       // §84 和 AI 那个 Session 的内存交接（GamePipe.StartVirtual）
        Dictionary<string, string> lastMe;
        readonly Random rnd = new Random();
        public volatile int Level = 1;     // Levels 的下标；对战中也能换，下一帧生效
        public volatile Loadout Load = new Loadout();   // §114 AI 装备；对战中也能换，下一帧生效
        public volatile string BackFrom;   // §85 真人离开后重开的 AI：离开的人的昵称（包里 aiback=，模组据此提示"XXX 已离开房间"）
        public Action<string> Log = delegate { };
        volatile bool stop;
        Thread thread;

        // 对局里的状态（只在 Run 线程里动）
        int seq = 500000, evId, resId, dead, curRound = -1;
        double hp = -1, sh = -1, lastT, nextHit, guardUntil, hopT0 = -1;
        double[] fpos;
        List<string> combo = new List<string>();
        List<Ev> events = new List<Ev>();
        Dictionary<int, Ans> answered = new Dictionary<int, Ans>();
        HashSet<int> counted = new HashSet<int>();
        string edgeName;
        List<string[]> edgeCombos = new List<string[]>();
        string movesFam;                                  // §114 当前招式表是哪个族的（换武器时重算）
        Moves mv = Moves.DoubleDefault();
        int medLeft, medN;                                // §114 这回合还能喝几次药；喝药动作计数（med=<次数>:<动作>）
        string medAnim = "-";
        double medNext;

        // dir = AI 那个 Session 的目录（net\ai\）；abilFile = pbz_abilities.lua（列影之武装的招用，找不到就不放影之武装）
        public LocalAi(string dir, string abilFile)
        {
            mb = GamePipe.For(dir);
            this.abilFile = abilFile;
        }

        public LocalAi Start()
        {
            thread = Safe.Thread("local-ai", Run);
            thread.Start();
            return this;
        }

        public void Stop()
        {
            stop = true;
            if (thread != null) thread.Join(1000);
        }

        static double Now() { return Link.UnixNow(); }

        static double Num(Dictionary<string, string> d, string k, double def)
        {
            string v;
            double r;
            return d.TryGetValue(k, out v) && double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out r) ? r : def;
        }

        static string Get(Dictionary<string, string> d, string k)
        {
            string v;
            return d.TryGetValue(k, out v) ? v : "";
        }

        static string F1(double v) { return Kv.F(v, "0.0"); }

        // 你的一刀碰到 AI 时的结果：按难度权重 中招 / 精防 / 普防；它举着架势时只有精防 / 普防
        string Roll(Lv lv, double tnow)
        {
            if (tnow < guardUntil) return rnd.NextDouble() < lv.GuardParry ? "parry" : "block";
            int w = rnd.Next(lv.Hit + lv.Parry + lv.Block);
            return w < lv.Hit ? "hit" : w < lv.Hit + lv.Parry ? "parry" : "block";
        }

        public static bool IsAttack(string n)
        {
            var m = HunRe.Match(n);
            if (!m.Success)
            {
                // 影之武装（GA_<武装>_*）算攻击；被动类不算
                if (!n.StartsWith("GA_") || n.StartsWith("GA_Hun_") || n.StartsWith("GA_Talent_") || n.StartsWith("GA_Add") || n.StartsWith("GA_Accessory_")) return false;
                if (n.Split('_').Length - 1 < 2) return false;
                foreach (var k in new[] { "Passive", "Execution", "GuardPoint", "Stance" }) if (n.Contains(k)) return false;
                return true;
            }
            string fam = m.Groups[1].Value, rest = m.Groups[2].Value;
            if (Array.IndexOf(NotAttackFam, fam) >= 0) return false;
            if (rest.Contains("PerfectDodge") || rest.Contains("SWT") || rest.Contains("Counter")) return true;
            var full = fam + "_" + rest;
            foreach (var k in NotAttackPart) if (full.Contains(k)) return false;
            return true;
        }

        // 影之武装 folder 的招：pbz_abilities.lua 里路径在 ShachiAbility/<folder>/ 下的技能（去掉被动 / 处决 / 基类），
        // A → AA → AAA 同前缀连成一套，其余一招一套（同 fake_remote.py 的 edge_moves）
        public static List<string[]> EdgeMoves(string abilText, string folder)
        {
            var res = new List<string[]>();
            if (string.IsNullOrEmpty(abilText)) return res;
            var names = new SortedSet<string>(StringComparer.Ordinal);
            var pat = new Regex(@"^\s*(\w+)\s*=\s*\{\s*""[^""]*/ShachiAbility/" + Regex.Escape(folder) + "/", RegexOptions.Multiline);
            foreach (Match m in pat.Matches(abilText))
            {
                var n = m.Groups[1].Value;
                bool skip = false;
                foreach (var k in EdgeSkip) if (n.Contains(k)) skip = true;
                if (!skip) names.Add(n);
            }
            var chains = new Dictionary<string, List<string>>();
            var order = new List<string>();
            var singles = new List<string[]>();
            var chainRe = new Regex(@"^(.*_)(A+)_C$");
            foreach (var n in names)
            {
                var m = chainRe.Match(n);
                if (m.Success)
                {
                    var key = m.Groups[1].Value;
                    if (!chains.ContainsKey(key)) { chains[key] = new List<string>(); order.Add(key); }
                    chains[key].Add(n);
                }
                else singles.Add(new[] { n });
            }
            foreach (var key in order)
            {
                var l = chains[key];
                l.Sort((a, b) => a.Length.CompareTo(b.Length));
                res.Add(l.ToArray());
            }
            res.AddRange(singles);
            return res;
        }

        // §114 一个武器族的招式表：地面连招 / 技能（每套一招或几招）/ 空中招 / 架势。双刃用原来手写的那套（§75 起实测过）
        public class Moves
        {
            public string[][] Combos, Skills, Air;
            public string Stance;      // null = 这把武器没有架势：打完一套不举架势（防御概率照旧按难度）
            public static Moves DoubleDefault() { return new Moves { Combos = LocalAi.Combos, Skills = LocalAi.Skills, Air = AirCombos, Stance = D + "Stance_C" }; }
        }

        // 淬炼后的武器（炽刃 / 黑魔伤）自己的招里没有空中招和架势，借原武器的
        static readonly Dictionary<string, string> FamBase = new Dictionary<string, string> { { "ChiRen", "Long" }, { "HeiMoShang", "Tang" } };
        // 地面招里不让 AI 放的：剧情专用（马车战）、二阶段 / 变体、要按住蓄力的（§92）、反击 / 闪避反击（要对方先出招）、占位
        static readonly string[] FamSkip = { "HorseCartCombat", "P2_", "_Alt", "Reborn", "PerfectDodge", "Counter", "HoldDeflect", "Charge", "Placeholder", "SpecialAssault", "SpeicalAssault",
            "_UI", "_Hold", "Drunk_", "Tipsy_", "_Zui" };     // _Hold 要按住；痴者残剑醉态的招要先喝醉（AI 不进醉态）
        // 连招串：可带前缀（紫冥剑 New_、痴者残剑 Normal_）和后缀（刺骨混沌的 _Fire / _Ice / _Physics 分支、长形黑伤 BBB_New）
        static readonly Regex ChainRe = new Regex(@"^(?:(New|Normal)_)?([AB]+)(?:_(New|Fire|Ice|Physics))?$");

        public static Moves FamilyMoves(string abilText, string fam)
        {
            if (fam == "Double" || string.IsNullOrEmpty(abilText)) return Moves.DoubleDefault();
            var names = new SortedSet<string>(StringComparer.Ordinal);
            var pat = new Regex(@"^\s*(GA_Hun_" + Regex.Escape(fam) + @"_(\w+)_C)\s*=", RegexOptions.Multiline);
            foreach (Match m in pat.Matches(abilText)) names.Add(m.Groups[1].Value);
            var chain = new Dictionary<string, string>();     // "前缀|后缀|AAB" → 技能名
            var skills = new List<string[]>();
            var air = new List<string[]>();
            string stance = null;
            string pre = "GA_Hun_" + fam + "_";
            foreach (var n in names)
            {
                var rest = n.Substring(pre.Length, n.Length - pre.Length - 2);
                if (rest == "Stance") { stance = n; continue; }
                if (rest.StartsWith("Air_"))
                {
                    if (rest == "Air_A" || rest == "Air_B" || rest == "Air_A_Draw" || rest == "Air_B_Draw") air.Add(new[] { n });
                    continue;
                }
                bool skip = false;
                foreach (var k in FamSkip) if (rest.Contains(k)) skip = true;
                if (skip) continue;
                var cm = ChainRe.Match(rest);
                if (cm.Success)
                {
                    var suf = cm.Groups[3].Value == "New" ? "" : cm.Groups[3].Value;
                    chain[cm.Groups[1].Value + "|" + suf + "|" + cm.Groups[2].Value] = n;
                    continue;
                }
                if (IsAttack(n) || rest == "Buff") skills.Add(new[] { n });
            }
            // A → AA → AAB：每个 A/B 串连同它所有在表里的前缀成一套（缺了中间一段的不连）；
            // 每一段先找同分支的，没有用不带后缀的（刺骨混沌 A → AA → AAB_Fire）
            var combos = new List<string[]>();
            foreach (var kv in chain)
            {
                var k = kv.Key.Split('|');
                var l = new List<string>();
                bool ok = true;
                for (int i = 1; i <= k[2].Length && ok; i++)
                {
                    string v, s = k[2].Substring(0, i);
                    if (chain.TryGetValue(k[0] + "|" + k[1] + "|" + s, out v) || chain.TryGetValue(k[0] + "||" + s, out v)) l.Add(v); else ok = false;
                }
                if (ok) combos.Add(l.ToArray());
            }
            string bf;
            if (FamBase.TryGetValue(fam, out bf))
            {
                var b = FamilyMoves(abilText, bf);
                if (air.Count == 0) air.AddRange(b.Air);
                if (stance == null) stance = b.Stance;
            }
            if (combos.Count == 0 && skills.Count == 0) return Moves.DoubleDefault();    // 读不到这个族的招：退回双刃（日志会说）
            if (combos.Count == 0) combos.AddRange(skills);
            return new Moves { Combos = combos.ToArray(), Skills = skills.Count > 0 ? skills.ToArray() : combos.ToArray(), Air = air.ToArray(), Stance = stance };
        }

        // §114 喝药动作按武器（§103 实测：双刃 / 长刀 / 唐刀各一个；白蟒赤练有自己的；其余用通用的）
        public static string MedAnim(string fam)
        {
            switch (fam)
            {
                case "Double": return "AM_Hun_Medicine_DoubleBlade";
                case "Long": case "ChiRen": return "AM_Hun_Medicine_LongBlade";
                case "Tang": case "HeiMoShang": return "AM_Hun_Medicine_TangBlade";
                case "SnakeDual": return "AM_Hun_Medicine_SnakeDual";
                default: return "AM_Hun_Medicine_Common";
            }
        }

        void Run()
        {
            lastT = Now();
            nextHit = lastT + 3;
            string abilText = null;
            try { abilText = File.ReadAllText(abilFile, Kv.Utf8); }
            catch (Exception) { Log(L.T("AI：读不到 ", "AI: can't read ") + abilFile + L.T("，不放影之武装", "; no Phantom Edge moves")); }
            while (!stop)
            {
                var t = mb != null ? mb.TakeLatestRemote() : null;     // 没有新包就沿用上一个（以前文件也是一直在那里）
                if (t != null) lastMe = Kv.Parse(t);
                var me = lastMe;
                double due;
                if (me != null && me.ContainsKey("x"))
                {
                    try { Step(me, abilText); } catch (Exception ex) { Log("AI: " + ex.Message); }
                    due = lastT + 1.0 / Hz;
                }
                else due = Now() + 1.0 / Hz;
                while (!stop)
                {
                    double left = due - Now();
                    if (left <= 0) break;
                    Thread.Sleep(Math.Max(1, Math.Min(5, (int)(left * 1000))));
                }
            }
        }

        T Pick<T>(T[] a) { return a[rnd.Next(a.Length)]; }

        // 一帧：照 fake_remote.py main() 的循环体（--ai on、客机、跟着走、照抄你的攻击属性 / 影之武装 / 最大血量）
        void Step(Dictionary<string, string> me, string abilText)
        {
            double yaw = Num(me, "yaw", 0), px = Num(me, "x", 0), py = Num(me, "y", 0), pz = Num(me, "z", 0);
            double tnow = Now();
            double dt = Math.Min(tnow - lastT, 0.2);
            lastT = tnow;
            double vx = 0, vy = 0;
            // 站位：离你超过 Dist 走过来；贴太近慢慢退开；离得太远（你被传送 / 回合开始摆到出生点）直接跳到你前方
            if (fpos == null || Math.Sqrt((fpos[0] - px) * (fpos[0] - px) + (fpos[1] - py) * (fpos[1] - py)) > JumpDist)
            {
                double r = yaw * Math.PI / 180;
                fpos = new[] { px + Dist * Math.Cos(r), py + Dist * Math.Sin(r) };
            }
            else
            {
                double ddx = px - fpos[0], ddy = py - fpos[1];
                double d = Math.Sqrt(ddx * ddx + ddy * ddy);
                if (d > Dist + 50)
                {
                    double step = Math.Min(Walk * dt, d - Dist);
                    vx = ddx / d * Walk; vy = ddy / d * Walk;
                    fpos[0] += ddx / d * step; fpos[1] += ddy / d * step;
                }
                else if (d > 0 && d < Dist * 0.4)
                {
                    double step = Walk * 0.5 * dt;
                    vx = -ddx / d * Walk * 0.5; vy = -ddy / d * Walk * 0.5;
                    fpos[0] -= ddx / d * step; fpos[1] -= ddy / d * step;
                }
            }
            double x = fpos[0], y = fpos[1];
            double face = Math.Atan2(py - y, px - x) * 180 / Math.PI;
            seq++;
            double hpm = Num(me, "hpm", 3085.5);
            if (hpm <= 0) hpm = 3085.5;
            double shm = Num(me, "shm", 800);
            if (shm <= 0) shm = 800;
            sh = sh < 0 ? shm : Math.Min(shm, sh + 150 * dt);
            // 对局流程跟你（主机）的 mt=：倒计时 / 空闲时补满血，新回合重新算
            var mt = Get(me, "mt").Split(':');
            int mround;
            string mstate = "";
            if (mt.Length > 1 && int.TryParse(mt[1], out mround)) mstate = mt[0];
            else mround = 0;
            var ld = Load;
            if (hp < 0 || mstate == "" || mstate == "idle" || mstate == "cd" || mround != curRound)
            {
                hp = hpm; dead = 0; curRound = mround; medLeft = ld.Potions;
            }
            // §114 换了武器：重算招式表，没打完的那套作废
            if (ld.Fam != movesFam)
            {
                movesFam = ld.Fam;
                mv = FamilyMoves(abilText, ld.Fam);
                combo.Clear();
                Log(L.T("AI：武器 ", "AI: weapon ") + ld.Fam + L.T("，", ", ") + mv.Combos.Length + L.T(" 套连招 / ", " combos / ") + mv.Skills.Length
                    + L.T(" 个技能 / ", " skills / ") + mv.Air.Length + L.T(" 个空中招", " air moves") + (mv.Stance == null ? L.T("，没有架势", ", no stance") : ""));
            }
            bool near = Math.Sqrt((px - x) * (px - x) + (py - y) * (py - y)) <= Dist + 200;

            // 影之武装：AI 装备里指定了就用指定的，没指定照抄你装的那件
            var wcs = ld.Edge.Length > 0 ? ld.Edge : Get(me, "wcs");
            var mEdge = Regex.Match(wcs, @"/ShaqiWeapon/(\w+)/");
            if (mEdge.Success && mEdge.Groups[1].Value != edgeName)
            {
                edgeName = mEdge.Groups[1].Value;
                edgeCombos = EdgeMoves(abilText, edgeName);
                Log(L.T("AI：影之武装 ", "AI: Phantom Edge ") + edgeName + L.T("，", ", ") + edgeCombos.Count + L.T(" 套招", " move sets"));
            }
            // 像人一样打：连招里每一下隔 0.55 秒；打完一套停一会儿，按难度的概率举架势（之后 2.1 秒你的刀只会被精防 / 普防）。
            // 间隔 / 概率按难度（Levels）乘
            var lv = Levels[Math.Max(0, Math.Min(2, Level))];
            // §114 喝药：交手中血掉到四成以下、手上没在打一套、还有药、主机没关血瓶（medok=0，§108）→ 回四成血、播喝药动作，1.6 秒不出招
            if (dead == 0 && mstate == "fight" && medLeft > 0 && combo.Count == 0 && hp < hpm * 0.4 && tnow >= medNext && Get(me, "medok") != "0")
            {
                medLeft--; medN++; medAnim = MedAnim(ld.Fam);
                hp = Math.Min(hpm, hp + hpm * 0.4);
                nextHit = Math.Max(nextHit, tnow + 1.6); medNext = tnow + 3;
                Log(L.T("AI：喝药，还剩 ", "AI: drinks a potion, ") + medLeft + L.T(" 次", " left"));
            }
            if (dead == 0 && near && tnow >= nextHit)
            {
                bool skill = false;
                double lead = 0;
                if (combo.Count == 0)
                {
                    double r = rnd.NextDouble();
                    if (mv.Air.Length > 0 && rnd.NextDouble() < AiAir && hopT0 < 0)
                    {
                        combo = new List<string>(Pick(mv.Air)); skill = true; hopT0 = tnow; lead = HopLead;
                        events.Add(new Ev { Id = ++evId, T = tnow, Name = "GA_Hun_Jump_C" });
                    }
                    else if (r < 0.2 && edgeCombos.Count > 0) { combo = new List<string>(edgeCombos[rnd.Next(edgeCombos.Count)]); skill = true; }
                    else if (r < 0.45) { combo = new List<string>(Pick(mv.Skills)); skill = true; }
                    else combo = new List<string>(Pick(mv.Combos));
                }
                events.Add(new Ev { Id = ++evId, T = tnow + lead, Name = combo[0] });
                combo.RemoveAt(0);
                if (combo.Count > 0) nextHit = tnow + lead + (hopT0 >= 0 ? 0.4 : (skill ? 0.9 : 0.55) * lv.Chain);
                else
                {
                    nextHit = tnow + (1.2 + rnd.NextDouble() * ((skill ? 2.5 : 2.0) - 1.2)) * lv.Gap;
                    if (rnd.NextDouble() < lv.StanceP)
                    {
                        if (mv.Stance != null) events.Add(new Ev { Id = ++evId, T = tnow + 0.6, Name = mv.Stance });
                        guardUntil = tnow + 2.1;
                    }
                }
            }
            // 跳起来的弧线：z = 你的 z + 高度，air=1、vz 照实发（替身按这两个字段起跳）
            double hopH = 0, hopV = 0;
            if (hopT0 >= 0)
            {
                double ht = tnow - hopT0;
                hopH = HopVz * ht - HopG * ht * ht / 2; hopV = HopVz - HopG * ht;
                if (hopH <= 0 && ht > 0.05) { hopT0 = -1; hopH = 0; hopV = 0; }
            }
            events.RemoveAll(e => tnow - e.T >= 2.0);
            var ev = new StringBuilder();
            foreach (var e in events)
                if (e.T <= tnow) ev.Append(ev.Length > 0 ? "," : "").Append(e.Id).Append(':').Append(e.Name);

            // 你的每一刀：按难度的权重随机回报 中招 / 精防 / 普防（举着架势时只有精防 / 普防），晚 ResDelay 秒。
            // §107 模组发了 tc=（你哪几招在游戏里真的碰到了 AI 的身体）：只有碰到的招才掷结果，TouchWait 秒内没碰到 = 落空；
            // 旧版模组没有 tc= → 照旧每招都掷（以前对着空气砍 AI 也掉血就是这个）
            bool touchInfo = me.ContainsKey("tc");
            var touched = new HashSet<int>();
            foreach (var tid in Get(me, "tc").Split(',')) { int v; if (int.TryParse(tid, out v)) touched.Add(v); }
            foreach (var part in Get(me, "ev").Split(','))
            {
                int i = part.IndexOf(':'), atk;
                if (i <= 0 || !int.TryParse(part.Substring(0, i), out atk) || answered.ContainsKey(atk) || !IsAttack(part.Substring(i + 1))) continue;
                answered[atk] = new Ans { Rid = ++resId, Seen = tnow, Kind = touchInfo ? null : Roll(lv, tnow) };
            }
            foreach (var kv in answered)
            {
                var a = kv.Value;
                if (a.Kind != null) continue;
                if (touched.Contains(kv.Key)) { a.Kind = Roll(lv, tnow); a.Seen = tnow - ResDelay + TouchDelay; }
                else if (tnow - a.Seen >= TouchWait) { a.Kind = "miss"; a.Seen = tnow - ResDelay; }
            }
            // §115 模组发了 td=<招式号:累计伤害>（你这招在游戏里打在替身身上的真实伤害，已乘伤害倍率 / 武器平衡）：中招按它扣，
            // 多段招后几段累计变大 → 同一条结果的数变大（模组报"追加命中"）、AI 补扣差值。旧版模组没有 td= → 照旧每招 400
            bool dmgInfo = me.ContainsKey("td");
            foreach (var part in Get(me, "td").Split(','))
            {
                int i = part.IndexOf(':'), atk; double d; Ans a;
                if (i <= 0 || !int.TryParse(part.Substring(0, i), out atk) || !answered.TryGetValue(atk, out a)) continue;
                if (!double.TryParse(part.Substring(i + 1), NumberStyles.Float, CultureInfo.InvariantCulture, out d)) continue;
                a.Dmg = Math.Max(a.Dmg, d); a.Last = tnow;
            }
            // 要比 main.lua 的 EV_KEEP（1.5 秒）长，否则还在 ev 里的招式过期后会被当成新招再报一次中招；
            // §115 还在 td= 里的（大招打了好几秒）不过期，不然后几段没处记
            var old = new List<int>();
            foreach (var kv in answered) if (tnow - Math.Max(kv.Value.Seen, kv.Value.Last) >= 3.0) old.Add(kv.Key);
            foreach (var k in old) answered.Remove(k);
            // §86 伤害倍率：游戏是主机，按它包里的 dm= 缩放你砍中 AI 的那 400（旧版 / 坏值 = 100%）
            double dm = Num(me, "dm", 100), dmg = ResDmg * (Array.IndexOf(DmSteps, dm) >= 0 ? dm : 100) / 100;
            var res = new StringBuilder();
            foreach (var kv in answered)
            {
                var a = kv.Value;
                if (a.Kind == null || tnow - a.Seen < ResDelay) continue;
                if (a.Kind == "hit" && a.Dmg <= 0)
                {
                    if (dmgInfo && tnow - a.Seen < ResDelay + DmgWait) continue;     // §115 等 td= 报伤害
                    a.Dmg = dmg;                                                      // 旧版模组 / 等不到：400
                }
                res.Append(res.Length > 0 ? "," : "").Append(a.Rid).Append(':').Append(kv.Key).Append(':').Append(a.Kind).Append(':')
                   .Append(a.Kind == "hit" ? Kv.F(a.Dmg, "0") : "0");
                if (counted.Add(a.Rid) && (a.Kind == "block" || a.Kind == "parry")) sh = Math.Max(0, sh - (a.Kind == "block" ? 300 : 100));
                if (a.Kind == "hit" && a.Dmg > a.Paid + 0.5)
                {
                    if (mstate == "fight" && dead == 0)
                    {
                        hp = Math.Max(0, hp - (a.Dmg - a.Paid));
                        if (hp <= 0) { dead = mround; Log(L.T("AI：第 " + mround + " 回合被打倒", "AI: knocked down in round " + mround)); }
                    }
                    a.Paid = a.Dmg;
                }
            }
            if (counted.Count > 5000) counted.Clear();     // 结果号只增不减，旧的早就不在 answered 里了

            var sb = new StringBuilder();
            sb.Append("v=2\nseq=").Append(seq).Append("\nmap=").Append(Get(me, "map"))
              .Append("\nx=").Append(F1(x)).Append("\ny=").Append(F1(y)).Append("\nz=").Append(F1(pz + hopH))
              .Append("\nyaw=").Append(F1(face)).Append("\nvx=").Append(F1(vx)).Append("\nvy=").Append(F1(vy))
              .Append("\nw=").Append(ld.Fam).Append("\nev=").Append(ev).Append("\nhp=").Append(F1(hp)).Append("\nhpm=").Append(F1(hpm))
              .Append("\nres=").Append(res).Append("\nmt=\narena=\ndead=").Append(dead).Append("\nrdy=1\nquit=0\natt=").Append(Get(me, "att"))
              .Append("\nwc=").Append(ld.Wc).Append("\narm=1\nlk=1\nsh=").Append(F1(sh)).Append("\nshm=").Append(F1(shm))
              .Append("\nai=1")     // v0.26.0 告诉模组对面是 AI：回合倒计时才强制归位（真人对战不归位）
              .Append("\nair=").Append(hopT0 >= 0 ? 1 : 0).Append("\nvz=").Append(F1(hopV)).Append('\n');
            if (wcs.Length > 0) sb.Append("wcs=").Append(wcs).Append('\n');
            // §114 皮肤（§109 of=<行名>:<肤色>:<帽子藏了>）、喝药动作（§103 med=<次数>:<动作>）、饰品被动（v0.17.2 pas=）。
            // pas= 是替身身上天赋 + 饰品的全部，只发饰品会把替身复制来的你的天赋清掉，所以带上你的天赋
            if (ld.Outfit.Length > 0) sb.Append("of=").Append(ld.Outfit).Append(":0:0\n");
            sb.Append("med=").Append(medN).Append(':').Append(medAnim).Append('\n');
            if (ld.Acc != null)
            {
                var pas = new List<string>();
                foreach (var n in Get(me, "pas").Split(',')) if (n.StartsWith("GA_Talent_")) pas.Add(n);
                foreach (var n in ld.Acc.Split(',')) if (n.Length > 0) pas.Add(n);
                sb.Append("pas=").Append(string.Join(",", pas)).Append('\n');
            }
            var back = BackFrom;
            if (back != null) sb.Append("aiback=").Append(back.Replace("\r", " ").Replace("\n", " ")).Append('\n');
            if (mb != null) mb.SetLocal(sb.ToString());
        }
    }
}
