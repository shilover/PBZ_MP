// 本地 AI 对手（HANDOVER §75，连接方式"本地 AI"）：tests/fake_remote.py 默认那一套（--ai on --rdy 1 --res-dmg 400，
// 当客机）搬成 C#，玩家不用装 Python。
// 不联网但走真的联机路径：MainForm 在本机开两个 Session——游戏这边当主机（net\），AI 当客机（net\ai\），127.0.0.1 互连；
// 本类只读写 net\ai\ 下的文件，和 fake_remote.py --peer 一样：读 state_remote.txt（= 你），写 state_local.txt（= AI 发给你的包）。
// 所以替身、判定、对局流程（主机 = 游戏的 matchStep）、可靠事件、Boss 血条都和真人联机是同一套代码。
// 规则改了要两边一起改：fake_remote.py 是离线测试用的那份。
// F5（docs/FORNET_F5_F6.md）：这份是影之刃零适配的一部分（mod/PBZ_MP/lobby/），基底 fornet 只有 LocalAiApi.cs 的接口；
// 编 PBZ 版联机程序时加进源文件（tools/build_lobby_pbz.bat），文件末尾 LocalAiSupport.Register 把自己登记给基底。
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace ForNet
{
    class LocalAi : ILocalAi
    {
        const string D = "GA_Hun_Double_";
        // 替身靠 wc= 换上双刃（绝影）；不发的话替身拿的是复制你的武器，双刃的招放不出（v0.23.4）
        const string WC = "/PBZCombatAsset/ActorData/Players/Hun/Weapon/Double/Weapon_Hun_JueYing.Weapon_Hun_JueYing";
        // §335.1 停在目标前 1.8 米、3 米内才出招（以前 4 米停、6 米内就出招：替身关了根运动不往前冲，用户 11-15 "隔着很远就在打、没走到面前"）
        internal const double Dist = 180, Reach = 300;
        const double Walk = 500, JumpDist = 3000, Hz = 30;
        const double ResDmg = 400, ResDelay = 0.4;                        // 你砍中它一刀扣 400；回报晚 0.4 秒（刀落下才判定）
        const double TouchWait = 1.5, TouchDelay = 0.1;                   // §107 等你的刀碰到它最多 1.5 秒，没碰到 = 落空；碰到后 0.1 秒回报
        const double DmgWait = 0.5;                                       // §115 中招后等模组 td= 报伤害最多 0.5 秒，还没有就按 400
        // §350 你的召唤（绝影分身 / 召唤类影之武装）：召出来的东西过一两秒才开打、断断续续打十几秒。召唤招最多等 SummonTouchWait 秒碰到，
        // 碰到过以后 SummonKeep 秒内还有 td= 就一直接着记（普通招 3 秒没动静就丢）
        const double SummonTouchWait = 8.0, SummonKeep = 20.0;
        // §382 召唤招 8 秒没碰到先报落空，但不算完：之后 SummonKeep 秒内碰到照样改判中招（同 §351）。
        // 放完分身我接着连砍，分身前几秒打的都记在我那几刀上（模组 TOUCH.srcId：我刚出的刀优先），分身这一招 8 秒里一下没碰到；
        // 以前判了落空 3 秒就丢，我停手后分身再打的那些（记回分身这一招）找不到结果 = 没伤害（玩家日志 mp_probe (30).log 16:21:00–16:21:20）
        // §351 起手长的招（紫冥剑大招 C_C 放出后 2–4 秒才开始打到，用户 11-16"紫冥剑大招没伤害"）：TouchWait 一过先报落空，
        // 之后 LateTouch 秒内这招又碰到 / 报了伤害 → 同一个结果号改判（模组那边走"追加命中"，0.34.1 起的模组不用改）。以前判了落空就再也不看
        const double LateTouch = 6.0;
        // §352 模组发了 act=（你还在放的攻击招）：这招放完还没碰到才判落空（同真人那边替身还在播就接着等），最多 ActMax 秒；
        // 没有 act= 的旧版模组照旧 TouchWait。pst=1（替身在你游戏里挨打 / 倒地 / 冻住）：AI 停手、不喝药、放下架势、这段时间防不了
        const double ActMax = 8.0;
        // §353 模组发了 psq=（替身在你游戏里的实际杀气）：AI 的杀气就用它（挨打掉、放技能花、打中涨，都是游戏自己算的），
        // 不再自己每秒回 150、不再按格挡扣；杀气不到 SkillSh 不放技能（武器技 / 招式技能，影之武装花的是暗源不受影响）。
        // 包里带 sqp=1 告诉模组"交手中别再把替身杀气补满"，杀气打空了替身在你游戏里真的破防（AI 那段时间停手，§352 pst=）
        const double SkillSh = 120;
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
            public bool Dummy;                     // §342 测伤木桩：不动、不出招、不防、不喝药、不死（空血回满），默认不带饰品
        }
        public static readonly Lv[] Levels = {
            new Lv { Zh = "简单", En = "Easy",   Gap = 1.7,  Chain = 1.3,  Hit = 80, Parry = 5,  Block = 15, StanceP = 0.1,  GuardParry = 0.3 },
            new Lv { Zh = "普通", En = "Normal", Gap = 1.0,  Chain = 1.0,  Hit = 60, Parry = 20, Block = 20, StanceP = 0.3,  GuardParry = 0.5 },
            new Lv { Zh = "困难", En = "Hard",   Gap = 0.55, Chain = 0.85, Hit = 35, Parry = 40, Block = 25, StanceP = 0.45, GuardParry = 0.7 },
            // §342 测伤木桩（用户 11-16，0.34.1）：只在 1v1 本地 AI 用；多人房的 AI 选到它按普通（MpLocalAi.Level）
            new Lv { Zh = "木桩", En = "Dummy",  Gap = 1.0,  Chain = 1.0,  Hit = 100, Parry = 0, Block = 0, StanceP = 0,  GuardParry = 0, Dummy = true } };
        public const int DummyLevel = 3;
        internal static Lv LevelOf(int i) { return Levels[Math.Max(0, Math.Min(Levels.Length - 1, i))]; }
        public static string LevelName(int i) { var l = LevelOf(i); return L.T(l.Zh, l.En); }

        // §114 AI 装备（面板"AI 装备…"，netcfg.txt 的 aiw= / aie= / aio= / aimed= / aiacc=）。整个对象一起换（Load = new …），Run 线程下一帧用新的
        public class Loadout : IAiLoad
        {
            public string Fam = "Double", Wc = WC;   // 武器：招式族（GA_Hun_<族>_*）+ 武器配置路径（状态包 w= / wc=）
            public string Edge = "";                 // 影之武装配置路径（wcs=）；空 = 照抄你装的
            public string Outfit = "";               // 皮肤行名（of=）；空 = 不发（替身穿本机的外观）
            public int Potions = 0;                  // 一回合能喝几次药（自己回血 + 发 med= 播喝药动作）；0 = 不喝
            public string Acc = null;                // 饰品被动（逗号分隔的 GA 名）；null = 不发 pas=（替身带的是本机的天赋 / 饰品），"" = 不带饰品
            // §354 AI 跟随你（玩家反馈 11-16："AI 会自动瞬移到我脸上"，木桩测攻击距离 / 对战练习拉开身位打远程都要能关）：
            // 开（默认）= 照旧走到你面前、离你超过 30 米瞬移到你面前；关 = 原地不动、不瞬移（第一次出现 / 换图 / 回合开战点照旧摆）。存 netcfg aifol=
            public bool Follow = true;

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
            public bool SetFollow(string v) { v = (v ?? "").Trim(); if (v != "0" && v != "1") return false; Follow = v == "1"; return true; }
            public string AccWire() { return Acc ?? "-"; }
            public string WeaponWire() { return Fam + "|" + Wc; }
            public Loadout Clone() { return (Loadout)MemberwiseClone(); }

            // F5：基底经 IAiLoad 存取，键名 / 顺序和以前写死在联机程序里的一字不差
            static readonly string[] Cmd = { "w", "e", "o", "med", "acc", "fol" };
            string[] IAiLoad.CmdKeys { get { return Cmd; } }
            bool IAiLoad.Set(string k, string v)
            {
                switch (k) { case "w": return SetWeapon(v); case "e": return SetEdge(v); case "o": return SetOutfit(v); case "med": return SetPotions(v); case "acc": return SetAcc(v); case "fol": return SetFollow(v); }
                return false;
            }
            bool IAiLoad.LoadCfg(string k, string v)
            {
                switch (k) { case "aiw": return SetWeapon(v); case "aie": return SetEdge(v); case "aio": return SetOutfit(v); case "aimed": return SetPotions(v); case "aiacc": return SetAcc(v); case "aifol": return SetFollow(v); }
                return false;
            }
            void IAiLoad.SaveCfg(StringBuilder sb)
            {
                sb.Append("aiw=").Append(WeaponWire()).Append('\n').Append("aie=").Append(Edge).Append('\n')
                  .Append("aio=").Append(Outfit).Append('\n').Append("aimed=").Append(Potions).Append('\n')
                  .Append("aiacc=").Append(AccWire()).Append('\n').Append("aifol=").Append(Follow ? 1 : 0).Append('\n');
            }
            void IAiLoad.LobbyKv(Action<string, string> kv)
            {
                kv("aiw", Wc);               // §114 AI 装备（面板按这些值标出当前选的是哪个）。Clean 会把 | 换掉，武器拆成路径 + 族两项
                kv("aiwf", Fam);
                kv("aie", Edge);
                kv("aio", Outfit);
                kv("aimed", Potions.ToString());
                kv("aiacc", AccWire());
                kv("aifol", Follow ? "1" : "0");     // §354
            }
            IAiLoad IAiLoad.Clone() { return Clone(); }
        }

        internal class Ev { public int Id; public double T; public string Name; }
        class Ans { public int Rid; public double Seen; public string Kind; public double Dmg, Paid, Last = -1; public bool Summon, Late, Linger; }   // §115 Dmg 这招累计伤害，Paid 已扣的血，Last 最后一次在 td= 里

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
        internal int seq = 500000, evId, resId, dead, curRound = -1;
        internal double hp = -1, sh = -1, lastT, nextHit, guardUntil, hopT0 = -1, holdZ = double.NaN;
        internal bool pupBusy;
        internal bool shGate;                            // §353 杀气以替身为准（psq=）：技能要看杀气够不够                           // §352 包里 pst=1：替身在你游戏里挨打 / 被控
        internal int busyN;                              // §352 停手过几次（测试 / 日志看）
        internal double[] fpos;
        double stayZ = double.NaN;                       // §354 不跟随时站着的高度（摆到你面前 / 开战点那一刻的）
        string stayMap;                                  // §354 不跟随时换了图要重新摆
        internal List<string> combo = new List<string>();
        internal List<Ev> events = new List<Ev>();
        Dictionary<int, Ans> answered = new Dictionary<int, Ans>();
        HashSet<int> counted = new HashSet<int>();
        string edgeName;
        List<string[]> edgeCombos = new List<string[]>();
        string movesFam;                                  // §114 当前招式表是哪个族的（换武器时重算）
        Moves mv = Moves.DoubleDefault();
        internal int medLeft, medN;                                // §114 这回合还能喝几次药；喝药动作计数（med=<次数>:<动作>）
        string medAnim = "-";
        double medNext;

        // dir = AI 那个 Session 的目录（net\ai\）；abilFile = pbz_abilities.lua（列影之武装的招用，找不到就不放影之武装）
        public LocalAi(string dir, string abilFile)
        {
            mb = string.IsNullOrEmpty(dir) ? null : GamePipe.For(dir);
            this.abilFile = abilFile;
        }

        public LocalAi Start()
        {
            thread = Safe.Thread("local-ai", Run);
            thread.Start();
            return this;
        }

        int ILocalAi.Level { set { Level = value; } }
        IAiLoad ILocalAi.Load { set { Load = (Loadout)value; } }
        Action<string> ILocalAi.Log { set { Log = value; } }
        void ILocalAi.Start() { Start(); }

        public void Stop()
        {
            stop = true;
            if (thread != null) thread.Join(1000);
        }

        internal static double Now() { return Link.UnixNow(); }

        internal static double Num(Dictionary<string, string> d, string k, double def)
        {
            string v;
            double r;
            return d.TryGetValue(k, out v) && double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out r) ? r : def;
        }

        internal static string Get(Dictionary<string, string> d, string k)
        {
            string v;
            return d.TryGetValue(k, out v) ? v : "";
        }

        static string F1(double v) { return Kv.F(v, "0.0"); }

        // 你的一刀碰到 AI 时的结果：按难度权重 中招 / 精防 / 普防；它举着架势时只有精防 / 普防
        string Roll(Lv lv, double tnow)
        {
            if (pupBusy) return "hit";                   // §352 挨打硬直 / 冻住时防不了（真人一样）
            if (tnow < guardUntil) return rnd.NextDouble() < lv.GuardParry ? "parry" : "block";
            int w = rnd.Next(lv.Hit + lv.Parry + lv.Block);
            return w < lv.Hit ? "hit" : w < lv.Hit + lv.Parry ? "parry" : "block";
        }

        // §367 和 main.lua 的 §249 ATK_EXTRA 一样：资产上会打人、但被下面的排除词挡住的 5 招
        static readonly HashSet<string> AttackExtra = new HashSet<string> {
            "GA_Hun_ChiZheCanJian_C_ToZui_C", "GA_Hun_YanYueDao_Stance_C", "GA_TieKuangQuanTao_GuardPoint_C",
            "GA_XieShan_LightningIce_PerfectDeflect_C", "GA_XieShan_LightningIce_PerfectDeflect_FullCharge_C" };

        public static bool IsAttack(string n)
        {
            if (AttackExtra.Contains(n)) return true;
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
            // §367 和 main.lua 的 §185 例外一样：L1+三角 里名字带 Switch / Buff 但真出刀的（混沌切形态斩 SwitchForm*、白影刀背敲击 BuffAtk、
            // 乱莺鸣剑 / 残钢血刃 *Buff）。以前这里漏了 → 本地 AI 不登记这几招：碰到了也不判、不扣血，招式统计里也没有名字（内测 11-17 残钢血刃）
            if (rest.StartsWith("SwitchForm") || rest == "BuffAtk" || ((fam == "LuanYing" || fam == "Iron") && rest.EndsWith("Buff"))) return true;
            var full = fam + "_" + rest;
            foreach (var k in NotAttackPart) if (full.Contains(k)) return false;
            return true;
        }

        // §350 你放的召唤招（和 main.lua 的 SUMMON.armName 一样）：名字带 Clone / Summon（被动除外），或 4 件召唤类影之武装。
        // 绝影分身 GA_Hun_Double_JueYing_Clone_C 不算攻击招（IsAttack 排除 Clone），以前 ev= 里看到也不登记 → 分身打木桩 / 本地 AI 的
        // td= 全被丢掉（用户 11-16 15:27 木桩 47 秒一点血没掉）
        static readonly string[] SummonEdge = { "JianKeZhaoJiLing", "CaoOuSiXian", "KuYeSiZhuChuan", "XuKongHuaShan" };
        public static bool IsSummonCast(string n)
        {
            if (string.IsNullOrEmpty(n) || n.Contains("Passive")) return false;
            if (n.Contains("Clone") || n.Contains("Summon")) return true;
            foreach (var k in SummonEdge) if (n.Contains(k)) return true;
            return false;
        }

        // §378 红妆鬼斩的招：撒下的石蒜花（留场子弹）可能放完好几秒才引爆（带"手动引爆"升级时要按键），
        // 模组把引爆那一下的 td= 记在最近那招红妆鬼斩上（main.lua TOUCH.srcId）。这些招的结果多留 SummonKeep 秒；
        // 判了落空之后又碰到 = 花炸到了，改判中招（不再按难度掷，花不按难度防）。判了格挡 / 精防的那招，之后花的伤害还是不算（没做）
        public static bool IsLingerCast(string n)
        {
            return !string.IsNullOrEmpty(n) && n.StartsWith("GA_Hun_GuiTouBlade_", StringComparison.Ordinal);
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

        internal static string ReadAbilText(string abilFile, Action<string> log)
        {
            if (string.IsNullOrEmpty(abilFile)) return null;
            try { return File.ReadAllText(abilFile, Kv.Utf8); }
            catch (Exception)
            {
                if (log != null) log(L.T("AI：读不到 ", "AI: can't read ") + abilFile + L.T("，不放影之武装", "; no Phantom Edge moves"));
                return null;
            }
        }

        internal void SyncWeaponAndEdge(Loadout ld, Dictionary<string, string> me, string abilText, out string wcs)
        {
            if (ld.Fam != movesFam)
            {
                movesFam = ld.Fam;
                mv = FamilyMoves(abilText, ld.Fam);
                combo.Clear();
                Log(L.T("AI：武器 ", "AI: weapon ") + ld.Fam + L.T("，", ", ") + mv.Combos.Length + L.T(" 套连招 / ", " combos / ") + mv.Skills.Length
                    + L.T(" 个技能 / ", " skills / ") + mv.Air.Length + L.T(" 个空中招", " air moves") + (mv.Stance == null ? L.T("，没有架势", ", no stance") : ""));
            }
            wcs = ld.Edge.Length > 0 ? ld.Edge : Get(me, "wcs");
            var mEdge = Regex.Match(wcs, @"/ShaqiWeapon/(\w+)/");
            if (mEdge.Success && mEdge.Groups[1].Value != edgeName)
            {
                edgeName = mEdge.Groups[1].Value;
                edgeCombos = EdgeMoves(abilText, edgeName);
                Log(L.T("AI：影之武装 ", "AI: Phantom Edge ") + edgeName + L.T("，", ", ") + edgeCombos.Count + L.T(" 套招", " move sets"));
            }
        }

        internal string AdvanceCombat(double tnow, bool hold, bool near, bool allowAttack, bool allowPotion, string mstate, string medok, double hpm, Loadout ld, out double hopH, out double hopV)
        {
            var lv = LevelOf(Level);
            if (allowPotion && mstate == "fight" && medLeft > 0 && combo.Count == 0 && hp < hpm * 0.4 && tnow >= medNext && medok != "0")
            {
                medLeft--; medN++; medAnim = MedAnim(ld.Fam);
                hp = Math.Min(hpm, hp + hpm * 0.4);
                nextHit = Math.Max(nextHit, tnow + 1.6); medNext = tnow + 3;
                Log(L.T("AI：喝药，还剩 ", "AI: drinks a potion, ") + medLeft + L.T(" 次", " left"));
            }
            if (hold || !allowAttack)
            {
                combo.Clear();
                events.Clear();
                nextHit = Math.Max(nextHit, tnow + 0.3);
            }
            else if (near && tnow >= nextHit)
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
                    else if (r < 0.45 && (!shGate || sh >= SkillSh)) { combo = new List<string>(Pick(mv.Skills)); skill = true; }   // §353 杀气不够不放技能
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
            hopH = 0; hopV = 0;
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
            return ev.ToString();
        }

        // follow = false（§354 AI 不跟随）：已经摆好了就原地不动，离多远都不瞬移；第一次（fpos 还是 null）照旧摆到你面前
        internal void StepApproach(double dt, double px, double py, double yaw, double[] spot, bool hold, out double vx, out double vy, out double holdZ, bool follow = true)
        {
            vx = 0; vy = 0; holdZ = double.NaN;
            if (spot != null) { fpos = new[] { spot[0], spot[1] }; holdZ = spot[2]; }
            else if (!follow && fpos != null) { }
            else if (hold && fpos != null && Math.Sqrt((fpos[0] - px) * (fpos[0] - px) + (fpos[1] - py) * (fpos[1] - py)) <= JumpDist) { }
            else if (fpos == null || Math.Sqrt((fpos[0] - px) * (fpos[0] - px) + (fpos[1] - py) * (fpos[1] - py)) > JumpDist)
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
        }

        internal string BuildPacketBody(Dictionary<string, string> me, double x, double y, double z, double face, double vx, double vy, Loadout ld, string evStr, double hpm, string resStr, int deadVal, double shm, double hopV, string wcs)
        {
            var sb = new StringBuilder();
            sb.Append("v=2\nseq=").Append(seq).Append("\nmap=").Append(Get(me, "map"))
              .Append("\nx=").Append(F1(x)).Append("\ny=").Append(F1(y)).Append("\nz=").Append(F1(z))
              .Append("\nyaw=").Append(F1(face)).Append("\nvx=").Append(F1(vx)).Append("\nvy=").Append(F1(vy))
              .Append("\nw=").Append(ld.Fam).Append("\nev=").Append(evStr).Append("\nhp=").Append(F1(hp)).Append("\nhpm=").Append(F1(hpm))
              .Append("\nres=").Append(resStr).Append("\nmt=\narena=\ndead=").Append(deadVal).Append("\nrdy=1\nquit=0\natt=").Append(Get(me, "att"))
              .Append("\nwc=").Append(ld.Wc).Append("\narm=1\nlk=1\nsq=").Append(F1(sh))
              .Append("\nshm=").Append(F1(shm))
              .Append("\nai=1")
              .Append("\nair=").Append(hopT0 >= 0 ? 1 : 0).Append("\nvz=").Append(F1(hopV)).Append('\n');
            if (wcs.Length > 0) sb.Append("wcs=").Append(wcs).Append('\n');
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
            return sb.ToString();
        }

        void Run()
        {
            lastT = Now();
            nextHit = lastT + 3;
            string abilText = ReadAbilText(abilFile, Log);
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

        // §238 主机状态包的 asp=（主机 x:y:z:地面z、客机 x:y:z:地面z、半距、朝向）→ 客机点 {x, y, z}；格式不对 = null
        static double[] AspGuest(string asp)
        {
            var p = (asp ?? "").Split(':');
            if (p.Length != 10) return null;
            var v = new double[10];
            for (int i = 0; i < 10; i++)
                if (!double.TryParse(p[i], NumberStyles.Float, CultureInfo.InvariantCulture, out v[i])) return null;
            return new[] { v[4], v[5], v[6] };
        }

        // 一帧：照 fake_remote.py main() 的循环体（--ai on、客机、跟着走、照抄你的攻击属性 / 影之武装 / 最大血量）
        void Step(Dictionary<string, string> me, string abilText)
        {
            double yaw = Num(me, "yaw", 0), px = Num(me, "x", 0), py = Num(me, "y", 0), pz = Num(me, "z", 0);
            double tnow = Now();
            double dt = Math.Min(tnow - lastT, 0.2);
            lastT = tnow;
            // 对局流程跟你（主机）的 mt=：倒计时 / 空闲时补满血，新回合重新算
            var mt = Get(me, "mt").Split(':');
            int mround;
            string mstate = "";
            if (mt.Length > 1 && int.TryParse(mt[1], out mround)) mstate = mt[0];
            else mround = 0;
            // §238 倒计时：站到主机发来的客机开战点（asp= 第 5–7 个数）不动、不出招；没有开战点（旧版模组 / 场地放不下）就原地不动
            bool hold = mstate == "cd";
            var lv = LevelOf(Level);
            bool dummy = lv.Dummy;                           // §342 木桩：一直按"倒计时站着不动"走（离你超过 30 米 / 换图才挪到你面前）
            double[] spot = hold ? AspGuest(Get(me, "asp")) : null;
            double vx, vy, holdZ;
            bool follow = Load.Follow;                       // §354
            string map = Get(me, "map");
            if (!follow && map.Length > 0 && map != stayMap) { if (stayMap != null) fpos = null; stayMap = map; }     // 换图：重新摆到你面前
            var fpos0 = fpos;
            StepApproach(dt, px, py, yaw, spot, hold || dummy, out vx, out vy, out holdZ, follow);
            if (!follow)
            {
                // 站着不动时高度定住（以前跟你的高度走：你跳起来 / 上坡它跟着上下）；刚摆到你面前用你那时的高度，开战点用开战点的
                if (!double.IsNaN(holdZ)) stayZ = holdZ;
                else if (fpos != fpos0 || double.IsNaN(stayZ)) stayZ = pz;
                holdZ = stayZ;
            }
            else stayZ = double.NaN;
            double x = fpos[0], y = fpos[1];
            double face = Math.Atan2(py - y, px - x) * 180 / Math.PI;
            seq++;
            double hpm = Num(me, "hpm", 3085.5);
            if (hpm <= 0) hpm = 3085.5;
            double shm = Num(me, "shm", 800);
            if (shm <= 0) shm = 800;
            shGate = !dummy && me.ContainsKey("psq");                                  // §353
            if (shGate) sh = Math.Max(0, Math.Min(shm, Num(me, "psq", sh < 0 ? shm : sh)));
            else sh = sh < 0 ? shm : Math.Min(shm, sh + 150 * dt);
            var ld = Load;
            // §342 木桩对局外也扣血（血条看得到掉了多少），只在倒计时 / 换回合时补满
            if (hp < 0 || (!dummy && (mstate == "" || mstate == "idle")) || mstate == "cd" || mround != curRound)
            {
                hp = hpm; dead = 0; curRound = mround; medLeft = dummy ? 0 : ld.Potions;
            }
            if (dummy) { dead = 0; sh = shm; }
            string wcs;
            SyncWeaponAndEdge(ld, me, abilText, out wcs);
            bool near = Math.Sqrt((px - x) * (px - x) + (py - y) * (py - y)) <= Reach;
            double hopH, hopV;
            if (dummy) guardUntil = 0;                       // 从别的难度换过来时可能还举着架势
            bool busyNow = !dummy && Get(me, "pst") == "1" && mstate == "fight";     // §352
            if (busyNow != pupBusy)
            {
                pupBusy = busyNow;
                if (busyNow) { guardUntil = Math.Min(guardUntil, tnow); busyN++; }
            }
            string evStr = AdvanceCombat(tnow, hold, near, dead == 0 && !dummy && !pupBusy, dead == 0 && !dummy && !pupBusy, mstate, Get(me, "medok"), hpm, ld, out hopH, out hopV);

            // 你的每一刀：按难度的权重随机回报 中招 / 精防 / 普防（举着架势时只有精防 / 普防），晚 ResDelay 秒。
            // §107 模组发了 tc=（你哪几招在游戏里真的碰到了 AI 的身体）：只有碰到的招才掷结果，TouchWait 秒内没碰到 = 落空；
            // 旧版模组没有 tc= → 照旧每招都掷（以前对着空气砍 AI 也掉血就是这个）
            bool touchInfo = me.ContainsKey("tc");
            var touched = new HashSet<int>();
            foreach (var tid in Get(me, "tc").Split(',')) { int v; if (int.TryParse(tid, out v)) touched.Add(v); }
            bool actInfo = me.ContainsKey("act");             // §352 你还在放的攻击招
            var acting = new HashSet<int>();
            foreach (var tid in Get(me, "act").Split(',')) { int v; if (int.TryParse(tid, out v)) acting.Add(v); }
            foreach (var part in Get(me, "ev").Split(','))
            {
                int i = part.IndexOf(':'), atk;
                if (i <= 0 || !int.TryParse(part.Substring(0, i), out atk) || answered.ContainsKey(atk)) continue;
                string evn = part.Substring(i + 1);
                bool summon = IsSummonCast(evn);                 // §350
                if (!summon && !IsAttack(evn)) continue;
                // §350 召唤招：没有 tc= 的旧版模组照旧不掷（召唤招本身不出刀）；碰到了一律算中招（召出来的东西不按难度防）
                if (summon && !touchInfo) continue;
                answered[atk] = new Ans { Rid = ++resId, Seen = tnow, Kind = touchInfo ? null : Roll(lv, tnow), Summon = summon, Linger = IsLingerCast(evn) };
            }
            foreach (var kv in answered)
            {
                var a = kv.Value;
                if (a.Kind == "miss" && a.Late && touched.Contains(kv.Key))     // §351 落空后又碰到：改判，结果号不变
                {
                    a.Late = false; a.Kind = a.Summon || a.Linger ? "hit" : Roll(lv, tnow); a.Seen = tnow - ResDelay + TouchDelay;   // §378 石蒜花晚炸 = 中招
                    Log(L.T("AI：你的第 " + kv.Key + " 招先判落空、后来碰到了，改判 " + a.Kind, "AI: your move #" + kv.Key + " hit late, now " + a.Kind));
                    continue;
                }
                if (a.Kind != null) continue;
                if (touched.Contains(kv.Key)) { a.Kind = a.Summon ? "hit" : Roll(lv, tnow); a.Seen = tnow - ResDelay + TouchDelay; }
                else if (a.Summon ? tnow - a.Seen >= SummonTouchWait
                         : actInfo ? (tnow - a.Seen >= TouchWait && !acting.Contains(kv.Key)) || tnow - a.Seen >= ActMax     // §352
                         : tnow - a.Seen >= TouchWait) { a.Kind = "miss"; a.Seen = tnow - ResDelay; a.Late = touchInfo; }      // §382 召唤招也能改判
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
            // §363 判完了、招还在 act= 里放（偃月刀大招：第一下拉人判中招 400，被拉开 3–4 秒后才砍下那一刀）别丢：
            // 以前判完 3 秒就丢，后面那刀的 td= 找不到这条结果、整招只剩 400（用户 11-16"第一下打到，第二下砍刀没伤害"）
            foreach (var kv in answered)
                if (tnow - Math.Max(kv.Value.Seen, kv.Value.Last) >= (kv.Value.Kind == null ? ActMax + 1.0 : kv.Value.Summon || kv.Value.Linger ? SummonKeep : kv.Value.Late ? LateTouch : 3.0)   // §378 Linger
                    && !(kv.Value.Kind != null && actInfo && acting.Contains(kv.Key) && tnow - kv.Value.Seen < ActMax + 1.0)) old.Add(kv.Key);   // §350 / §351 / §352 还没判的（act= 里还在放）别先丢了
            foreach (var k in old) answered.Remove(k);
            // §86 伤害倍率：游戏是主机，按它包里的 dm= 缩放你砍中 AI 的那 400（旧版 / 坏值 = 100%）
            // §366 按范围认（同 main.lua §213 / 武林盟主 10–1000），不按档位表：盟主 dm=35 以前不在表里 → 退回值按 100% 扣 400
            double dm = Num(me, "dm", 100), dmg = ResDmg * (dm >= 10 && dm <= 1000 ? dm : 100) / 100;
            var res = new StringBuilder();
            foreach (var kv in answered)
            {
                var a = kv.Value;
                if (a.Kind == null || tnow - a.Seen < ResDelay) continue;
                if (a.Kind == "hit" && a.Dmg <= 0)
                {
                    if (a.Summon) continue;                                           // §350 召唤物只按 td= 报的真实掉血，不退回 400
                    if (dmgInfo && tnow - a.Seen < ResDelay + DmgWait) continue;     // §115 等 td= 报伤害
                    a.Dmg = dmg;                                                      // 旧版模组 / 等不到：400
                }
                res.Append(res.Length > 0 ? "," : "").Append(a.Rid).Append(':').Append(kv.Key).Append(':').Append(a.Kind).Append(':')
                   .Append(a.Kind == "hit" ? Kv.F(a.Dmg, "0") : "0");
                if (counted.Add(a.Rid) && !shGate && (a.Kind == "block" || a.Kind == "parry")) sh = Math.Max(0, sh - (a.Kind == "block" ? 300 : 100));   // §353 杀气以替身为准时不自己扣
                if (a.Kind == "hit" && a.Dmg > a.Paid + 0.5)
                {
                    if (dummy && mstate != "cd")
                    {
                        // §342 木桩不死：扣到 0 就回满。回报的 res= 照旧是这招的完整累计伤害 a.Dmg（不按剩的血截，用户 11-16
                        // "剩 10 血、100 伤害的招按 100 算"）；这里只管血条
                        hp -= a.Dmg - a.Paid;
                        if (hp <= 0) { hp = hpm; Log(L.T("AI：木桩空血，回满", "AI: dummy emptied, refilled")); }
                    }
                    else if (mstate == "fight" && dead == 0)
                    {
                        hp = Math.Max(0, hp - (a.Dmg - a.Paid));
                        if (hp <= 0) { dead = mround; Log(L.T("AI：第 " + mround + " 回合被打倒", "AI: knocked down in round " + mround)); }
                    }
                    a.Paid = a.Dmg;
                }
            }
            if (counted.Count > 5000) counted.Clear();     // 结果号只增不减，旧的早就不在 answered 里了

            if (dummy && ld.Acc == null) { ld = ld.Clone(); ld.Acc = ""; }      // §342 木桩默认不带饰品（AI 装备里自选了饰品就用自选的）
            var body = BuildPacketBody(me, x, y, (double.IsNaN(holdZ) ? pz : holdZ) + hopH, face, vx, vy, ld, evStr, hpm, res.ToString(), dead, shm, hopV, wcs);
            if (dummy) body += "dummy=1\n";
            else body += "sqp=1\n";                         // §353 交手中替身杀气按游戏自己的（模组别补满）                 // §342 游戏据此：不按回合时限判负、替身本机一直留伤害余量、面板写木桩
            if (mb != null) mb.SetLocal(body);
        }
    }

    // 多人本地 AI 的一个机器人实例（在主机进程内 30Hz 跑，复用 LocalAi 的出招/站位/喝药/配装核心）
    sealed class MpLocalAi : IMpAiBot
    {
        sealed class PeerSnapshot
        {
            public int Pid;
            public Dictionary<string, string> Kv;
            public double LastRx;
        }

        double lastZOut = double.NaN;     // §326.4 上一次发出去的高度（不含起跳）
        const double Hz = 30.0;
        const double StickySec = 4.0;
        const double AliveTimeout = 4.0;
        const double KillerWindow = 8.0;
        const double DefaultHpm = 3085.5;
        const double DefaultShm = 800.0;
        const double FallbackDmg = 400.0;

        readonly LocalAi core;
        readonly string abilFile;
        readonly object mpLock = new object();
        readonly AutoResetEvent wake = new AutoResetEvent(false);
        readonly Dictionary<int, PeerSnapshot> peers = new Dictionary<int, PeerSnapshot>();
        readonly Dictionary<string, double> mtdSeen = new Dictionary<string, double>();
        readonly Dictionary<string, int> mtcSeen = new Dictionary<string, int>();
        readonly HashSet<int> aiPids = new HashSet<int>();
        readonly HashSet<int> parts = new HashSet<int>();
        readonly Dictionary<int, int> teamOf = new Dictionary<int, int>();

        volatile bool stop;
        Thread th;
        int hostPid = 1;
        string hostMatchSt = "idle";
        string hostMode = "elim";
        int hostLives = 3;
        int curMid;
        int benchedMid;
        bool seenHostMpm;
        int curSpawnGen = -1;
        double curYaw;
        bool hasHostSpot;
        double spotX, spotY, spotZ, spotYaw;
        double lastHpm = DefaultHpm;
        int myDeaths, lastKiller, hrN;
        string hrAnim = "-";
        bool myDown, myOut;
        int lastAttackerPid;
        double lastAttackerAt = -999;
        int stickyTargetPid;
        double stickyUntil = -999;
        double lastT;

        public int Pid { get; private set; }
        public string Name { get; private set; }
        public int Level { set { core.Level = value == LocalAi.DummyLevel ? 1 : value; } }     // §342 木桩只做 1v1，多人房按普通
        public IAiLoad Load { set { if (value is LocalAi.Loadout) core.Load = (LocalAi.Loadout)value; } }
        public Action<int, string> OnState { set; private get; }
        public Action<string> Log { set { core.Log = value; } }

        public MpLocalAi(int pid, string name, string abilitiesFile)
        {
            Pid = pid;
            Name = name ?? ("[AI] AI" + pid);
            abilFile = abilitiesFile;
            core = new LocalAi("", abilitiesFile);
            core.hp = -1;
        }

        public void Start()
        {
            lastT = LocalAi.Now();
            th = Safe.Thread("mp-ai-" + Pid, Run);
            th.Start();
        }

        public void Stop()
        {
            stop = true;
            try { wake.Set(); } catch (Exception) { }
            if (th != null) th.Join(2000);
        }

        public void SetMeta(int host, ICollection<int> ais)
        {
            lock (mpLock)
            {
                if (host > 0) hostPid = host;
                aiPids.Clear();
                if (ais != null) foreach (var id in ais) aiPids.Add(id);
            }
        }

        public void RemovePlayer(int pid)
        {
            var deadKeys = new List<string>();
            string prefix = pid + ":";
            lock (mpLock)
            {
                peers.Remove(pid);
                foreach (var k in mtdSeen.Keys) if (k.StartsWith(prefix, StringComparison.Ordinal)) deadKeys.Add(k);
                foreach (var k in deadKeys) mtdSeen.Remove(k);
                deadKeys.Clear();
                foreach (var k in mtcSeen.Keys) if (k.StartsWith(prefix, StringComparison.Ordinal)) deadKeys.Add(k);
                foreach (var k in deadKeys) mtcSeen.Remove(k);
                if (stickyTargetPid == pid) stickyTargetPid = 0;
            }
        }

        bool SameTeamLocked(int a, int b)
        {
            int ta, tb;
            return teamOf.TryGetValue(a, out ta) && teamOf.TryGetValue(b, out tb) && ta > 0 && ta == tb;
        }

        static void ParseIntMap(string csv, Dictionary<int, int> dst)
        {
            dst.Clear();
            if (string.IsNullOrEmpty(csv)) return;
            foreach (var part in csv.Split(','))
            {
                var p = part.Split(':');
                int k, v;
                if (p.Length >= 2 && int.TryParse(p[0], out k) && int.TryParse(p[1], out v)) dst[k] = v;
            }
        }

        void ResetForNewMatchLocked(int newMid)
        {
            curMid = newMid;
            benchedMid = 0;
            curSpawnGen = -1;
            mtdSeen.Clear();
            mtcSeen.Clear();
            myDeaths = 0;
            lastKiller = 0;
            hrN = 0;
            hrAnim = "-";
            myDown = false;
            myOut = false;
            lastAttackerPid = 0;
            lastAttackerAt = -999;
            stickyTargetPid = 0;
            stickyUntil = -999;
            core.hp = lastHpm > 0 ? lastHpm : DefaultHpm;
            core.medLeft = core.Load.Potions;
            core.combo.Clear();
            core.events.Clear();
        }

        public void FeedPacket(int pid, string body)
        {
            if (pid <= 0 || pid == Pid || string.IsNullOrEmpty(body)) return;
            var kv = Kv.Parse(body);
            double now = LocalAi.Now();
            bool urgent = false;
            lock (mpLock)
            {
                PeerSnapshot snap;
                if (!peers.TryGetValue(pid, out snap)) { snap = new PeerSnapshot { Pid = pid }; peers[pid] = snap; }
                snap.Kv = kv;
                snap.LastRx = now;

                if (pid == hostPid)
                {
                    double hm = LocalAi.Num(kv, "hpm", 0);
                    if (hm > 0) lastHpm = hm;
                    string mpm = LocalAi.Get(kv, "mpm");
                    if (mpm.Length > 0)
                    {
                        var mp = mpm.Split(':');
                        if (mp.Length >= 1 && mp[0].Length > 0) hostMatchSt = mp[0];
                        int newMid;
                        if (mp.Length >= 2 && int.TryParse(mp[1], out newMid) && newMid > 0 && newMid != curMid) ResetForNewMatchLocked(newMid);
                        int lv;
                        if (mp.Length >= 3 && int.TryParse(mp[2], out lv) && lv > 0) hostLives = lv;
                        parts.Clear();
                        if (mp.Length >= 6 && mp[5].Length > 0)
                        {
                            foreach (var ps in mp[5].Split(',')) { int pId; if (int.TryParse(ps, out pId) && pId > 0) parts.Add(pId); }
                        }
                        if (hostMatchSt == "idle") benchedMid = 0;
                        else if (!seenHostMpm && curMid > 0) benchedMid = curMid;
                        seenHostMpm = true;
                    }
                    else
                    {
                        // §326 复测 1：房主只在对局里发 mpm=（MP.wire），没有 = 对局外。以前没有这一支，补进来的 AI 收不到 idle、
                        // 一直带着 mwo=1（benched），房主下一局开局按 §318 把它当"只看不上场"排掉
                        hostMatchSt = "idle";
                        parts.Clear();
                        benchedMid = 0;
                    }
                    string mpx = LocalAi.Get(kv, "mpx");
                    if (mpx.Length > 0)
                    {
                        var xp = mpx.Split(':');
                        if (xp.Length >= 1 && xp[0].Length > 0) hostMode = xp[0];
                    }
                    if (kv.ContainsKey("mpt")) ParseIntMap(LocalAi.Get(kv, "mpt"), teamOf);

                    // §335 AI 打 AI：房主游戏里看到的 mta=<出手 AI>:<挨打 AI>:<段>:<累计>，只认打我、出手的是别的 AI、不同队的
                    string mta = LocalAi.Get(kv, "mta");
                    if (mta.Length > 0)
                    {
                        foreach (var item in mta.Split(','))
                        {
                            var f = item.Split(':');
                            int apid, vpid; double cum;
                            if (f.Length >= 4 && int.TryParse(f[0], out apid) && int.TryParse(f[1], out vpid) && vpid == Pid && apid != Pid
                                && aiPids.Contains(apid) && !SameTeamLocked(apid, Pid) && f[2].Length > 0
                                && double.TryParse(f[3], NumberStyles.Float, CultureInfo.InvariantCulture, out cum))
                            {
                                ApplyCumulativeDamageLocked(apid, "a" + f[2], cum, now, out urgent);
                            }
                        }
                    }

                    string mpai = LocalAi.Get(kv, "mpai");
                    if (mpai.Length > 0)
                    {
                        foreach (var seg in mpai.Split(','))
                        {
                            var f = seg.Split(':');
                            int apid, egen; double ax, ay, az, ayaw;
                            if (f.Length >= 7 && int.TryParse(f[0], out apid) && apid == Pid
                                && int.TryParse(f[2], out egen)
                                && double.TryParse(f[3], NumberStyles.Float, CultureInfo.InvariantCulture, out ax)
                                && double.TryParse(f[4], NumberStyles.Float, CultureInfo.InvariantCulture, out ay)
                                && double.TryParse(f[5], NumberStyles.Float, CultureInfo.InvariantCulture, out az)
                                && double.TryParse(f[6], NumberStyles.Float, CultureInfo.InvariantCulture, out ayaw))
                            {
                                string est = f[1];
                                benchedMid = 0;
                                hasHostSpot = true;
                                spotX = ax; spotY = ay; spotZ = az; spotYaw = ayaw;
                                if (egen != curSpawnGen)
                                {
                                    curSpawnGen = egen;
                                    core.fpos = new[] { ax, ay };
                                    core.holdZ = az;
                                    curYaw = ayaw;
                                    if (est == "cd" || est == "fight")
                                    {
                                        myDown = false; myOut = false;
                                        core.hp = lastHpm > 0 ? lastHpm : DefaultHpm;
                                        core.medLeft = core.Load.Potions;
                                        core.combo.Clear();
                                        core.events.Clear();
                                    }
                                    if (est == "cd")
                                    {
                                        myDeaths = 0; lastKiller = 0; hrN = 0; hrAnim = "-"; mtdSeen.Clear(); mtcSeen.Clear();
                                        lastAttackerPid = 0; lastAttackerAt = -999;
                                    }
                                }
                                if (est == "out") { myOut = true; myDown = true; }
                                else if (est == "down") { myDown = true; }
                                break;
                            }
                        }
                    }
                }

                // 处理伤害上报（仅认非同队真人玩家对我发来的 mtd= / mtc=；按 (攻击者, 招式号) 累计扣差值）
                if (!aiPids.Contains(pid) && !SameTeamLocked(pid, Pid))
                {
                    bool hadMtd = false;
                    string mtd = LocalAi.Get(kv, "mtd");
                    if (mtd.Length > 0)
                    {
                        foreach (var item in mtd.Split(','))
                        {
                            var f = item.Split(':');
                            int tpid; double cum;
                            if (f.Length >= 3 && int.TryParse(f[0], out tpid) && tpid == Pid && f[1].Length > 0
                                && double.TryParse(f[2], NumberStyles.Float, CultureInfo.InvariantCulture, out cum))
                            {
                                hadMtd = true;
                                ApplyCumulativeDamageLocked(pid, f[1], cum, now, out urgent);
                            }
                        }
                    }
                    string mtc = LocalAi.Get(kv, "mtc");
                    if (mtc.Length > 0)
                    {
                        foreach (var item in mtc.Split(','))
                        {
                            var f = item.Split(':');
                            int tpid, cnt;
                            if (f.Length >= 3 && int.TryParse(f[0], out tpid) && tpid == Pid && f[1].Length > 0 && int.TryParse(f[2], out cnt))
                            {
                                string k = pid + ":" + f[1];
                                if (hadMtd && mtdSeen.ContainsKey(k)) continue;
                                int prev = 0;
                                mtcSeen.TryGetValue(k, out prev);
                                if (cnt > prev)
                                {
                                    mtcSeen[k] = cnt;
                                    double prevDmg = 0;
                                    mtdSeen.TryGetValue(k, out prevDmg);
                                    if (prevDmg <= 0.001)
                                    {
                                        double estDmg = (cnt - prev) * FallbackDmg;
                                        ApplyDamageDeltaLocked(pid, estDmg, now, out urgent);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if (urgent) { try { wake.Set(); } catch (Exception) { } }
        }

        void ApplyCumulativeDamageLocked(int attackerPid, string moveId, double cumDmg, double now, out bool fatal)
        {
            fatal = false;
            string k = attackerPid + ":" + moveId;
            double prev = 0;
            mtdSeen.TryGetValue(k, out prev);
            double delta = cumDmg - prev;
            if (delta <= 0.001) return;
            mtdSeen[k] = cumDmg;
            ApplyDamageDeltaLocked(attackerPid, delta, now, out fatal);
        }

        static string PickHitMontage(string fam, int seqN, bool heavy)
        {
            string side = (seqN % 2 == 0) ? "L" : "R";
            if (heavy) return "Hun_LongBlade_Hit_Middle_F_" + side + "_Montage";
            string blade = (fam == "Long" || fam == "ChiRen") ? "Hun_LongBlade" : "Hun_TangBlade";
            return blade + "_Hit_Light_F_" + side + "_Montage";
        }

        void ApplyDamageDeltaLocked(int attackerPid, double delta, double now, out bool fatal)
        {
            fatal = false;
            if (delta <= 0.001) return;
            lastAttackerPid = attackerPid;
            lastAttackerAt = now;
            if (hostMatchSt != "fight" || myDown || myOut) return;
            double hpmRef = lastHpm > 0 ? lastHpm : DefaultHpm;
            if (core.hp < 0) core.hp = hpmRef;
            core.hp = Math.Max(0, core.hp - delta);
            if (core.hp <= 0)
            {
                fatal = true;
                myDown = true;
                myDeaths++;
                myOut = (hostMode != "score" && hostLives > 0 && myDeaths >= hostLives);
                int killer = (lastAttackerPid > 0 && (now - lastAttackerAt) <= KillerWindow && !SameTeamLocked(lastAttackerPid, Pid))
                    ? lastAttackerPid : 0;
                lastKiller = killer;
                core.combo.Clear();
                core.events.Clear();
                if (core.Log != null)
                    core.Log(L.T("多人 AI #" + Pid + " 倒地（击倒者=" + killer + "，死亡=" + myDeaths + "）",
                                 "MP AI #" + Pid + " down (killer=" + killer + ", deaths=" + myDeaths + ")"));
            }
            else
            {
                hrN++;
                hrAnim = PickHitMontage(core.Load != null ? core.Load.Fam : "Double", hrN, delta >= hpmRef * 0.15);
                core.combo.Clear();
            }
        }

        static bool IsTargetAlive(Dictionary<string, string> kv)
        {
            if (kv == null) return false;
            if (LocalAi.Get(kv, "mwo") == "1") return false;
            var mpd = LocalAi.Get(kv, "mpd").Split(':');
            if (mpd.Length >= 3 && mpd[2] == "1") return false;
            double hp = LocalAi.Num(kv, "hp", -1);
            if (kv.ContainsKey("hp") && hp <= 0) return false;
            return kv.ContainsKey("x") && kv.ContainsKey("y");
        }

        // §335 离 (x, y) 最近、还在发包的真人的高度；没有就用房主的；都没有就用 fallback
        double HumanZLocked(double x, double y, double now, PeerSnapshot hostSnap, double fallback)
        {
            double best = double.NaN, bestD2 = double.MaxValue;
            foreach (var c in peers.Values)
            {
                if (c.Pid == Pid || aiPids.Contains(c.Pid) || c.Kv == null || now - c.LastRx > AliveTimeout) continue;
                if (!c.Kv.ContainsKey("z") || !c.Kv.ContainsKey("x")) continue;
                double cx = LocalAi.Num(c.Kv, "x", 0), cy = LocalAi.Num(c.Kv, "y", 0);
                double d2 = (cx - x) * (cx - x) + (cy - y) * (cy - y);
                if (d2 < bestD2) { bestD2 = d2; best = LocalAi.Num(c.Kv, "z", fallback); }
            }
            if (!double.IsNaN(best)) return best;
            if (hostSnap != null && hostSnap.Kv != null && hostSnap.Kv.ContainsKey("z")) return LocalAi.Num(hostSnap.Kv, "z", fallback);
            return fallback;
        }

        PeerSnapshot PickTargetLocked(double now)
        {
            if (hostMatchSt != "fight" || myDown || myOut) { stickyTargetPid = 0; return null; }
            double myX = core.fpos != null ? core.fpos[0] : spotX;
            double myY = core.fpos != null ? core.fpos[1] : spotY;
            PeerSnapshot sticky = null;
            PeerSnapshot best = null;
            double bestD2 = double.MaxValue;
            foreach (var c in peers.Values)
            {
                // §335 别的队的 AI 也算目标（以前只打真人：只有一个真人时队友 AI 站着不动、两个不同队的敌方 AI 都只打真人）
                if (c.Pid == Pid) continue;
                if (now - c.LastRx > AliveTimeout) continue;
                if (parts.Count > 0 && !parts.Contains(c.Pid)) continue;
                if (SameTeamLocked(c.Pid, Pid)) continue;
                if (!IsTargetAlive(c.Kv)) continue;
                if (c.Pid == stickyTargetPid && now < stickyUntil) sticky = c;
                double cx = LocalAi.Num(c.Kv, "x", 0), cy = LocalAi.Num(c.Kv, "y", 0);
                double d2 = (cx - myX) * (cx - myX) + (cy - myY) * (cy - myY);
                if (d2 < bestD2) { bestD2 = d2; best = c; }
            }
            if (sticky != null) return sticky;
            if (best != null) { stickyTargetPid = best.Pid; stickyUntil = now + StickySec; }
            else stickyTargetPid = 0;
            return best;
        }

        string StepOnce(string abilText)
        {
            double tnow = LocalAi.Now();
            double dt = Math.Min(Math.Max(0.001, tnow - lastT), 0.2);
            lastT = tnow;
            lock (mpLock)
            {
                PeerSnapshot hostSnap;
                peers.TryGetValue(hostPid, out hostSnap);
                var tgt = PickTargetLocked(tnow);
                var refKv = tgt != null ? tgt.Kv : (hostSnap != null && hostSnap.Kv != null ? hostSnap.Kv : new Dictionary<string, string>());

                double px = LocalAi.Num(refKv, "x", spotX);
                double py = LocalAi.Num(refKv, "y", spotY);
                double pz = LocalAi.Num(refKv, "z", spotZ);
                // §335 目标是别的 AI 时，它的高度也是抄来的（不是真地面）：AI 互相抄会一直停在出生点高度，客机替身落地又被拉回、上下跳
                //（优化会话 20:10 实测"差太远直接放过去"一秒几十次）。改用离目标最近的真人的高度（真人报的是游戏里真的地面），没有就用房主的
                if (tgt != null && aiPids.Contains(tgt.Pid)) pz = HumanZLocked(px, py, tnow, hostSnap, pz);
                double yaw = LocalAi.Num(refKv, "yaw", spotYaw);

                bool benched = (hostMatchSt != "idle" && ((parts.Count > 0 && !parts.Contains(Pid)) || (benchedMid > 0 && benchedMid == curMid)));
                bool hold = (hostMatchSt == "cd") || myDown || myOut || benched || (hostMatchSt == "fight" && tgt == null);
                double[] spot = null;
                if (hasHostSpot && (hostMatchSt == "cd" || core.fpos == null))
                    spot = new[] { spotX, spotY, spotZ };
                else if (core.fpos == null && !refKv.ContainsKey("x"))
                    spot = new[] { spotX, spotY, spotZ };

                double vx, vy, holdZ;
                if (hold && core.fpos != null)
                {
                    // 站着不动：用站点高度；没有站点高度时定在上一次发出去的高度（别跟着目标上下）
                    vx = 0; vy = 0;
                    holdZ = !double.IsNaN(core.holdZ) ? core.holdZ : (!double.IsNaN(lastZOut) ? lastZOut : pz);
                }
                else
                {
                    core.StepApproach(dt, px, py, yaw, spot, hold, out vx, out vy, out holdZ);
                    // §326.4 复测：以前站点高度设上以后一直沿用（这里还会把它补回 holdZ），AI 走到地势低的地方发出去的高度还是出生点的，
                    // 客机替身落到地面又被"跟网络位置"拉回去，上下跳（优化会话 14:43 双开实测，z 20 ↔ -335）。
                    // 改成照 1v1：只有站在站点上（StepApproach 给了站点高度）才用它，一走动就跟目标的高度，站点高度作废
                    if (!double.IsNaN(holdZ)) core.holdZ = holdZ;
                    else core.holdZ = double.NaN;
                    if (spot != null && hostMatchSt == "cd") curYaw = spotYaw;
                }
                double x = core.fpos[0], y = core.fpos[1];
                double face = (tgt != null) ? (Math.Atan2(py - y, px - x) * 180 / Math.PI)
                    : (hostMatchSt == "cd" && hasHostSpot ? spotYaw : curYaw);
                curYaw = face;

                core.seq++;
                double hpm = LocalAi.Num(refKv, "hpm", lastHpm > 0 ? lastHpm : DefaultHpm);
                if (hpm <= 0) hpm = DefaultHpm;
                lastHpm = hpm;
                double shm = LocalAi.Num(refKv, "shm", DefaultShm);
                if (shm <= 0) shm = DefaultShm;
                core.sh = core.sh < 0 ? shm : Math.Min(shm, core.sh + 150 * dt);
                var ld = core.Load;
                if (core.hp < 0 || hostMatchSt == "idle" || hostMatchSt == "cd")
                {
                    core.hp = hpm;
                    core.medLeft = ld.Potions;
                }

                string wcs;
                core.SyncWeaponAndEdge(ld, refKv, abilText, out wcs);
                bool hasTgt = (hostMatchSt == "fight" && tgt != null && !myDown && !myOut && !benched);
                bool near = hasTgt && Math.Sqrt((px - x) * (px - x) + (py - y) * (py - y)) <= LocalAi.Reach;
                double hopH, hopV;
                string evStr = core.AdvanceCombat(tnow, hold, near, hasTgt, hasTgt, hostMatchSt, LocalAi.Get(refKv, "medok"), hpm, ld, out hopH, out hopV);

                double zOut = (double.IsNaN(holdZ) ? pz : holdZ) + hopH;
                lastZOut = zOut - hopH;
                int mpdSt = myOut ? 2 : (myDown ? 1 : 0);
                string body = core.BuildPacketBody(refKv, x, y, zOut, face, vx, vy, ld, evStr, hpm, "", (myDown || myOut) ? 1 : 0, shm, hopV, wcs);
                var sb = new StringBuilder(body);
                sb.Append("nm=").Append(Name).Append('\n');
                sb.Append("mt3=1\n");
                // §335 我在打谁（游戏里替身照它对准出招；以前游戏猜，猜的时候不算 AI，队友 AI 没候选就对着真人砍）
                sb.Append("atg=").Append(hasTgt && tgt != null ? tgt.Pid : 0).Append('\n');
                sb.Append("hr=").Append(hrN).Append(':').Append(hrAnim).Append('\n');
                if (benched) sb.Append("mwo=1\n");
                sb.Append("mpd=").Append(curMid).Append(':').Append(myDeaths).Append(':').Append(mpdSt).Append('\n');
                sb.Append("mpk=").Append(curMid).Append(':').Append(myDeaths).Append(':').Append(lastKiller).Append('\n');
                return sb.ToString();
            }
        }

        void Run()
        {
            string abilText = LocalAi.ReadAbilText(abilFile, core.Log);
            while (!stop)
            {
                try
                {
                    string body = StepOnce(abilText);
                    var cb = OnState;
                    if (cb != null && !string.IsNullOrEmpty(body)) cb(Pid, body);
                }
                catch (Exception ex)
                {
                    if (core.Log != null) core.Log("MP AI #" + Pid + ": " + ex.Message);
                }
                wake.WaitOne((int)(1000.0 / Hz));
            }
        }
    }

    // F5：编进联机程序时把影之刃零的本地 AI 登记给基底（fornet/lobby/LocalAiApi.cs）
    static partial class LocalAiSupport
    {
        static partial void Register(ref ILocalAiImpl impl) { impl = new PbzLocalAi(); }
    }

    sealed class PbzLocalAi : ILocalAiImpl
    {
        static string FindAbilitiesPath()
        {
            var abil = Path.Combine(Program.BaseDir, "games", "pbz", "pbz_abilities.lua");
            if (!File.Exists(abil)) abil = Path.Combine(Program.BaseDir, "Scripts", "pbz_abilities.lua");
            if (!File.Exists(abil)) abil = Path.Combine(Program.BaseDir, "..", "..", "mod", "PBZ_MP", "Scripts", "pbz_abilities.lua");
            if (!File.Exists(abil)) abil = Path.Combine(Program.BaseDir, "..", "mod", "PBZ_MP", "Scripts", "pbz_abilities.lua");
            return abil;
        }
        public int LevelCount { get { return LocalAi.Levels.Length; } }
        public string LevelName(int i) { return LocalAi.LevelName(i); }
        public IAiLoad NewLoad() { return new LocalAi.Loadout(); }
        public ILocalAi Create(string aiDir, int level, IAiLoad load, string backFrom)
        {
            return new LocalAi(aiDir, FindAbilitiesPath()) { Level = level, Load = (LocalAi.Loadout)load.Clone(), BackFrom = backFrom };
        }
        public IMpAiBot CreateMp(int pid, string name, int level, IAiLoad load)
        {
            return new MpLocalAi(pid, name, FindAbilitiesPath()) { Level = level, Load = load != null ? load.Clone() : NewLoad() };
        }
        public string[] SetupLogPrefixes() { return new[] { L.T("AI：武器 ", "AI: weapon "), L.T("AI：影之武装 ", "AI: Phantom Edge "), L.T("AI：读不到 ", "AI: can't read ") }; }
    }
}
