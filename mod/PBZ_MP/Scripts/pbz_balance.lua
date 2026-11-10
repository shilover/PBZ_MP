-- PvP 每招独立的伤害系数（HANDOVER §106.4）。**可以手改**：改完重新部署（deploy.bat 会拷这个文件）。
-- 替身放某招期间，替身的攻击力 Attack / ShachiAttack 乘这招的系数（伤害、杀气伤害一起按比例缩放，游戏自己算）；
-- 1 = 原版，0.5 = 一半，2 = 两倍。同一招的几段伤害一起缩，不能分段调。挨打的一方按这张表算，所以两边的表要一样。
-- 注释 "实测 n=…，一下约 …% 血"：docs/BALANCE_EVAL.md 表 3，对方攻击 600、倍率 100%、满血约 3085 时**原版**一下打掉多少（全段中位）。
-- family：只给这张表里**没有**的招（游戏更新后新出的招）当初值 / 兜底；改 family 不会改下面已经列出的招。
-- 重新生成 / 补新招：python -X utf8 -I tools/gen_balance.py（已有的数保留）。
-- §172 粗调（tools/balance/rough_tune.py）：普通招 DPS 300 / 远程 150；大招每格精纯杀气 2000；影武每颗暗源 1000 / 远程 500。
-- summon（§177）：召唤物 / 飞出去的东西留场多少秒，这段时间里召唤物打人也按这招的系数算（一行写完，工具按一行读写）。
-- L1+圈 特殊技（手柄 L1+○ / Xbox LB+B / 键鼠 格挡+处决键；游戏文本 [Stance]+[Execution]，§183）：按武器类型三招通用——单手 瞬杀 ShunSha、
--   双手 裂斩 LieZhan、双持 影杀 YingSha（GA_GlobalActionAbilit*_<名>_C_C，_CB_C 是接着出的重击后段（标签 Heavy.Atk01））。目标（用户 11-09）：伤害 100%、
--   标准数值下一招合计 1000–1100，取 1050；系数 = 1050 ÷ 原版一招。原版 = 11-09 mp_probe.log 掉血行反推（那天伤害 50%、替身攻击 200 × 0.5 × 等级系数）：
--   影杀：Double 装着（游戏 ×3.9）一招 5 段 3423–3628 → 100% 约 6850–7260 → 0.15（旧 0.08）。
--   瞬杀：木剑没装着（模组 ×3.9）一下 2970 / 3245 → 100% 约 5940–6490；黑魔伤一下打满 3857（只知道 ≥ 7715）→ 取保守 0.14（旧 0.08；木剑约 830–910，黑魔伤 ≥ 1080），待实测。
--   裂斩：出招时手上换成占位武器 MoQie、不吃等级倍率，一下 1061 / 1071 → 100% 约 2130 → 0.49（旧 0.08）；main.lua 裂斩期间等级系数按 ×1（STD.flatScale）。
--   _CB_C（第二段）用户 11-09 定一招 500：没有原版数，先按各自 _C_C 系数 × 500/1050（影杀 0.07 / 瞬杀 0.07 / 裂斩 0.23），待实测校正。
-- L1+三角 特殊技（手柄 L1+△ / Xbox LB+Y / 键鼠 格挡+重击；游戏文本 [Stance]+[HeavyAttack]，技能标签多是 Heavy.<武器>.DB，§185）：各武器各一招。
--   目标（用户 11-09）：基础 DPS（§172 普通招 300 / 远程 150）的 1.5 倍 → 近战每秒 450、远程每秒 225；伤害 100%、标准数值，和 §172 同口径。
--   系数 = 目标每秒 × 技能时长 ÷ 原版一招（coll_B.log 里完整打中那次，人工核对，不用 move_table 的第一次）。新系数 ÷ 旧系数 ≈ 1.5 的就是原版数没变。
--   有数（原版 / 时长 / 旧 → 新）：风雷剑闪电风暴 3203（16 段）/4s 远 0.19→0.28；偃月刀旋刃 ≥3086（3 段，第 3 段把血打空被截断）/4s 近 0.39→0.5（算出 ≤0.58，取保守）；
--     斩马刀亡命蓄斩 832/3s 近 1.08→1.62；破军冲锋 DB 1078/5s 近 1.39→2.09、DB_02 1068（2 段）/4s 近 1.12→1.69；
--     天煞双钺 DB 1898（用 20:11:59 DB_SWT 完整那次 4 段；表里 316 是只中一把）/2s 近 1.9→0.47；灵蛇剑花 DB4 / DB5 1335/2s 近 0.45→0.67；
--     白蟒赤练短刃 DB 3167（1217 + 1950 两段，第二段没进表）/2s 远 0.25→0.14；玉双环 DB 1135（2 段）/3s 远 0.4→0.59；邪扇奇术 DB 1025（6 段）/3s 近 0.88→1.32；
--     炽刃火焰波 BSup 1896（3 段刀 984 + 施放后 1.3 秒内 4 跳燃烧 912；表里 2125 混了前一招 ChiRen_BD 的燃烧）/4s 近 0.56→0.95。
--   没数、待实测（保守：按本武器已调招里最高 DPS 当原版每秒）：荡寇刀波 BladeWave 远 1.0→0.3、别离钩架势反制 DB 近 1.0→0.71、紫冥剑布局 DB 远 0.8→0.33（§193 用户定改 0.2）、
--     长形黑伤旋风斩 BSup 近 1.0→0.95（照炽刃）、混沌切形态斩 SwitchForm 火 / 冰 / 物理 新→0.45（物理同动作 SWT 版 1988/2s）、白影刀背敲击 BuffAtk 新→0.54、
--     乱莺鸣剑 Buff / P2_Buff 远 新→0.46、残钢血刃 Iron_Buff 新→0.73（这 6 招以前不算攻击，§185 起算）。
--   不打人、不进表：凝气于刃 Tang_Buff / Double_Buff、绝影分身 JueYing_Clone、痴者残剑喝酒 Drink。切刀斩版 *_DB_SWT、偃月刀青龙附体后的 B_Reinforced 不是 L1+三角，没动。
-- cooldown（§184）：召唤物冷却秒数 = 这件召唤物收掉（打完消失）之后再过多少秒才能再召，在场期间也不能再召；0 = 不冷却。只在武器平衡开着时生效。
--   键是 <武器>_<召唤物>，现在只有 ZiMingJian_HuoQiang（紫冥剑 DB 召唤火枪，main.lua GCD 段），其它键没人认；0–60 秒。一行写完，工具按一行读写。
--   这一行整个没有（旧表 / 旧版主机下发的数值表没有 cd=）按 0.1 秒（§212 前是 15）；有这一行但没写某个键 = 那件不冷却。
--   §212（2026-11-10 用户"火枪冷却去掉"）：ZiMingJian_HuoQiang 15 → 0.1——枪还在场时照样不能再召（GCD 在场挡要秒数 > 0 才开，写 0 会连在场挡一起关）。
--   §200 瞬影冷却也放这一行（用户 11-10："瞬影闪避结束后给 10 秒 cd"）：ShunYingDodge = 瞬影（天赋瞬身，架势 + 闪避，GA_Hun_SpecialDash_*）
--   结束后多少秒才能再放，只挡瞬影自己；main.lua DCD 段。没写（旧表 / 旧版主机下发的 cd= 里没有）= 默认 10 秒，和火枪"没写 = 不冷却"不一样；要关就写 0。
--   §200.10（用户 11-10"能给普通的闪避增加杀气消耗么 但是不给他冷却限制了"）：普通闪避 Dodge / 灵蛇剑架势闪避 SnakeDodge 的冷却撤了（这一行不再有这两个键；
--   旧版主机 / 服务器下发的 cd= 里还带着也没人用），改成下面 cost 行的每段扣杀气。
-- cost（§200.10 / §200.11）：Dodge = 普通闪避（GA_Hun_AdvancedDash_* 第 1 段 / Continuous_02 / 03）每段扣多少杀气，SnakeDodge = 灵蛇剑架势闪避
--   （GA_Hun_StanceDash_*）每段扣多少；杀气不够照样闪、扣到 0 为止（扣到 0 本身不会破防，HANDOVER §200.10.2）。0 = 不扣。
--   SwitchKeepShachi = 1：切武器不回满杀气、保持切之前的值（原版切武器会回满，用户"能改成切换武器继承当前杀气状态么"）；0 = 按原版。
--   只在武器平衡开着、对局交手中生效；随数值表下发（co=）。这一行整个没有 / 没写某个键 = 默认（20 / 20 / 1）。一行写完，工具按一行读写。
-- §186 / §190（2026-11-09）：§187 的临时 ÷2 已撤——family 和普通招用 §186 按根因重算的完整值（取完整打中、剔附加效果、data/move_override.csv 人工核对），
--   L1+圈（§183）/ L1+三角（§185）两组、summon / cooldown 行按 main 现值。
-- §190（2026-11-09 用户"召唤物的伤害按远程伤害倍率算"）：出手后由召唤物 / 飞出去还留在场上的东西接着打人的招，按远程目标定（普通每秒 150、L1+三角 225），
--   名单在 tools/balance/rough_tune.py 的 SUMMON_RANGED，原版数在 data/move_manual.csv。这次变了：玉双环 B_Dash 0.51→0.1（实战 7 段 5906）、
--   玉双环 DB 0.59→0.19（实战 3 段中位 3503，覆盖上面 §185 的 1135）、天煞双钺 DB 0.47→0.24（扔出的幻化双钺追踪，改按远程 225）。
--   召唤物在场期间的命中按召唤那招的系数（summon 行，§177）。
-- §193（2026-11-09 用户定，不等实测）：紫冥剑布局 DB 0.33→0.2（锤 / 火枪 / 伞命中都按它）；data/move_manual.csv 定值 0.2，原版数 3162（实战 16 段那次）照算是 0.21。
--   天煞双钺 DB 0.24 / 玉双环 DB 0.19 按远程 225：用户已确认。
-- §199（2026-11-10 用户"点燃和本身伤害合在一起算，首先削点燃伤害，然后削弱招式，合在一起接近总伤害预算"）：
--   dot = { 招名或族名 = 持续伤害系数 }：这招挂上的点燃 / 流血 / 中毒 / 混沌整个持续期间按 伤害倍率 × 这个系数 × 等级 算（main.lua DOT 段，
--   挂上时钉住，不跟替身后来的招变）；没列的招 = 这招自己的系数、不超过 1。由 tools/balance/rough_tune.py 按 data/move_dot.csv 算：
--   d = min(1, 0.3 × 这招预算 ÷ 挂满一次的原版持续伤害)，直接部分目标 = 预算 − 每招挂上次数 × 原版持续 × d。
--   裂斩定 0.05（只有长形黑伤 / 炽刃的裂斩会点燃，直接系数是所有双手武器共用的、不能扣）；炽刃 / 残钢刃按日志估算的原版持续伤害算，待实测。
--   ctrl = { 异常类型 = 秒 }：控制类异常在交手中最长挂多少秒，到点挨打方撤掉自己的 GE（冰冻 frost 1.5 秒：§199.4 待用户定的保守版，
--   原版约 2.7 秒；白影 Y / 刺骨混沌冰形态 / 邪扇冰都走 GE_Frost）。整行删掉或写 0 = 不管。两行都随数值表下发（d= / cc=）。
-- §199.8（2026-11-10 用户"c也做，要这个武器所有招式都削弱，因为冰冻后可以换招打"）：能挂冰冻的武器整把再乘一个折扣（下面的数已经乘过）：
--   白影 ×0.87、刺骨混沌 ×0.87（只削冰形态能用的招：不分形态的招 + *_Ice + 切形态斩；*_Fire / *_Physics 变体不削）、圣母邪扇 ×0.93。
--   折扣 = 60h ÷ (60h + 每分钟冻住次数 × 冻住秒数 × (1 − h))，冻住秒数 = min(原版 2.7, 上面 ctrl 的 frost)，h = 实战命中效率 0.2；
--   数据和理由在 data/move_ctrl.csv，由 tools/balance/rough_tune.py 算。L1+圈（瞬杀 / 裂斩 / 影杀）全武器共用，不打折。改 ctrl 的 frost 要重跑 rough_tune。
-- §206（2026-11-10 线上反馈"冰缓 buff 可以叠的层数完爆其他所有异常，伤害也十分离谱"，用户"把伤害直接去掉吧"）：
--   chill = { dmg = 倍数 }：白影 / 刺骨混沌冰形态 / 圣母邪扇冰打中后、冻住之前身上的冰缓（GE_Frost_HasAccumulation，每 0.2 秒掉一下血，
--   跟冰冻积累涨）那一下掉血乘多少：0 = 去掉（现在），1 = 原版不管。减速、冰冻积累、冻住都不动。挨打方压自己的 TakenReductionMultiplier_Ice
--   （main.lua DOT.chillRatio），只在武器平衡开着、对局交手中。随数值表下发（ch=）；整行没有 / 旧表 = 默认 0（去掉）。一行写完，工具按一行读写。
-- §209（2026-11-10 用户"大于1的，并且没细调过的招式都先减半"）：粗调按"原版总伤害 ÷ 整段技能时长（1 秒精度）"算 DPS，轻击 / 连段
--   实战 0.5 秒左右就接下一刀，被算成 DPS 低、系数抬过 1（黑魔伤 A 1.49、AAA 2.14，实战两下打死）。当时生效系数 > 1 的 216 招再 ×0.5
--   （下面的数已经乘过）；名单 data/move_halve.csv，由 tools/balance/rough_tune.py 最后乘。没动：人工定值（move_manual）、L1+圈 / L1+三角、
--   大招、玉双环（§203 过过）、炽刃、召唤 / 留场、影之武装、没数据的招。原来 ≥2 的减半后仍可能 > 1（只减一次）。
-- §212（2026-11-10 用户"紫冥剑 DB 召出的火枪伤害降到每发 1 点左右，只压火枪，金瓜锤 / 铁伞不变"）：
--   sdmg = { <武器>_<召唤物> = 每发伤害点数 }：交手中 + 武器平衡开时，认作这件召唤物打的那一下（DB 那一招、火枪在场、锤 / 伞 / 布局反击不在场）
--   挨打方只扣这个数（最终值，不再乘伤害倍率 / 等级 / 系数）；认不准的那几下照原伤害（按 DB 系数 0.2）。现在只有 ZiMingJian_HuoQiang（main.lua GDMG 段）。
--   0 = 不管（照原伤害）；负数 / 坏值不收（按默认）。随数值表下发（sd=，要新客户端才认）；整行没有 / 没写某个键 = 默认（火枪 1）。一行写完，工具按一行读写。
return {
family = { Air = 0.85, Double = 0.85, SlitheringSword = 1.2, YanYueDao = 0.5, ZhanMa = 0.5, ZiMingJian = 0.8 },
summon = { GA_Hun_AdvancedDash_Double_Jade_C = 3, GA_Hun_Jade_B_Dash_C = 4, GA_Hun_Jade_C_Range_C = 5, GA_Hun_Jade_DB_C = 3, GA_Hun_ZiMingJian_New_AAAAA_C = 4, GA_Hun_ZiMingJian_New_AAABB_C = 4, GA_Hun_ZiMingJian_New_AABB_C = 4, GA_Hun_ZiMingJian_New_ABB_C = 4, GA_Hun_ZiMingJian_New_BBB_C = 4, GA_Hun_ZiMingJian_New_CCC_C = 15, GA_Hun_ZiMingJian_New_CC_C = 15, GA_Hun_ZiMingJian_New_DB_C = 15 },
cooldown = { ShunYingDodge = 10, ZiMingJian_HuoQiang = 0.1 },
cost = { Dodge = 50, SnakeDodge = 50, SwitchKeepShachi = 1 },
dot = { ChiRen = 0.29, GA_GlobalActionAbility_LieZhan_CB_C = 0.05, GA_GlobalActionAbility_LieZhan_C_C = 0.05, GA_Hun_ChiRen_AAAABB_C = 0.29, GA_Hun_ChiRen_AAAAB_C = 0.29, GA_Hun_ChiRen_AAAA_C = 0.29, GA_Hun_ChiRen_AAABB_C = 0.29, GA_Hun_ChiRen_AAAB_C = 0.39, GA_Hun_ChiRen_AAA_C = 0.19, GA_Hun_ChiRen_AABB_C = 0.19, GA_Hun_ChiRen_AAB_C = 0.29, GA_Hun_ChiRen_AA_C = 0.19, GA_Hun_ChiRen_ABB_C = 0.29, GA_Hun_ChiRen_AB_C = 0.29, GA_Hun_ChiRen_A_C = 0.19, GA_Hun_ChiRen_A_Draw_C = 0.19, GA_Hun_ChiRen_BBB_C = 0.29, GA_Hun_ChiRen_BB_C = 0.29, GA_Hun_ChiRen_BD_C = 0.29, GA_Hun_ChiRen_BSup_C = 0.45, GA_Hun_ChiRen_B_DashDraw_C = 0.29, GA_Hun_ChiRen_B_Dash_C = 0.29, GA_Hun_ChiRen_B_Draw_C = 0.39, GA_Hun_ChiRen_C_C = 0.64, GA_Hun_ChiRen_SWT_C = 0.19, GA_Hun_Iron_AAAAA_C = 0.89, GA_Hun_Iron_AAAA_C = 1.0, GA_Hun_Iron_AAABB_C = 1.0, GA_Hun_Iron_AAAB_C = 1.0, GA_Hun_Iron_AAA_C = 0.89, GA_Hun_Iron_AABB_C = 1.0, GA_Hun_Iron_AAB_C = 1.0, GA_Hun_Iron_AA_C = 1.0, GA_Hun_Iron_ABB_C = 1.0, GA_Hun_Iron_AB_C = 0.89, GA_Hun_Iron_A_C = 0.89, GA_Hun_Iron_A_DashDraw_C = 0.89, GA_Hun_Iron_A_Dash_C = 0.89, GA_Hun_Iron_A_Draw_C = 0.89, GA_Hun_Iron_BBB_C = 1.0, GA_Hun_Iron_BB_C = 1.0, GA_Hun_Iron_BChargeAttack_C = 0.89, GA_Hun_Iron_B_C = 0.89, GA_Hun_Iron_B_DashDraw_C = 0.89, GA_Hun_Iron_B_Dash_C = 0.89, GA_Hun_Iron_B_Draw_C = 1.0, GA_Hun_Iron_C_C = 1.0, Iron = 0.95 },
ctrl = { frost = 1.5 },
chill = { dmg = 0 },
sdmg = { ZiMingJian_HuoQiang = 1 },
moves = {

-- ==== 黑伤双刃 · 空中（Air，3 招）
  GA_Hun_Air_Double_AAA_C = 0.71,
  GA_Hun_Air_Double_AA_C = 0.79,  -- 实测 n=7，一下约 10% 血
  GA_Hun_Air_Tang_AA_C = 0.89,

-- ==== 白影（BaiYing，22 招）
  GA_Hun_BaiYing_AAAAA_C = 0.66,
  GA_Hun_BaiYing_AAAA_C = 0.51,  -- 实测 n=1，一下约 1% 血
  GA_Hun_BaiYing_AAA_C = 0.6,
  GA_Hun_BaiYing_AA_C = 1.3,
  GA_Hun_BaiYing_A_C = 0.51,  -- 实测 n=3，一下约 25% 血
  GA_Hun_BaiYing_A_DashDraw_C = 1.3,
  GA_Hun_BaiYing_A_Dash_C = 0.52,
  GA_Hun_BaiYing_A_Snap_C = 0.87,
  GA_Hun_BaiYing_Air_A_C = 0.58,
  GA_Hun_BaiYing_Air_A_Draw_C = 0.58,
  GA_Hun_BaiYing_Air_B_C = 0.56,
  GA_Hun_BaiYing_Air_B_Draw_C = 1.3,
  GA_Hun_BaiYing_BBB_C = 0.43,  -- 实测 n=4，一下约 12% 血
  GA_Hun_BaiYing_BB_C = 0.52,  -- 实测 n=6，一下约 13% 血
  GA_Hun_BaiYing_B_C = 0.86,  -- 实测 n=12，一下约 4% 血
  GA_Hun_BaiYing_B_DashDraw_C = 0.47,
  GA_Hun_BaiYing_B_Dash_C = 0.55,
  GA_Hun_BaiYing_B_Snap_C = 0.87,
  GA_Hun_BaiYing_C_C = 0.79,  -- 实测 n=4，一下约 55% 血
  GA_Hun_BaiYing_PerfectDodge_C = 0.87,
  GA_Hun_BaiYing_SWT_Power_C = 0.43,  -- 实测 n=8，一下约 20% 血
  GA_Hun_BaiYing_SpeicalAssault_C = 0.31,  -- 实测 n=1，一下约 25% 血

-- ==== 天玄青铜剑（BronzeSword，22 招）
  GA_Hun_BronzeSword_AAAA_C = 0.58,
  GA_Hun_BronzeSword_AAABB_C = 0.49,
  GA_Hun_BronzeSword_AAAB_C = 0.65,
  GA_Hun_BronzeSword_AAA_C = 0.93,
  GA_Hun_BronzeSword_AABB_C = 0.81,
  GA_Hun_BronzeSword_AAB_C = 0.32,
  GA_Hun_BronzeSword_AA_C = 0.69,
  GA_Hun_BronzeSword_ABB_C = 0.33,
  GA_Hun_BronzeSword_AB_C = 0.44,
  GA_Hun_BronzeSword_A_C = 0.76,
  GA_Hun_BronzeSword_A_Dash_C = 1.37,
  GA_Hun_BronzeSword_A_Draw_C = 1.14,
  GA_Hun_BronzeSword_A_Snap_C = 1.0,
  GA_Hun_BronzeSword_BA_C = 0.46,
  GA_Hun_BronzeSword_BBB_C = 1.17,
  GA_Hun_BronzeSword_BB_C = 0.66,
  GA_Hun_BronzeSword_B_C = 0.69,  -- 实测 n=1，一下约 87% 血
  GA_Hun_BronzeSword_B_Dash_C = 0.82,
  GA_Hun_BronzeSword_B_Hold_C = 0.37,
  GA_Hun_BronzeSword_B_Snap_C = 1.0,
  GA_Hun_BronzeSword_C_C = 1.27,
  GA_Hun_BronzeSword_SWT_C = 1.0,  -- 实测 n=3，一下约 13% 血

-- ==== 刺骨混沌（Chaos，46 招）
  GA_Hun_Chaos_AAAAA_C = 0.86,  -- 实测 n=1，一下约 19% 血
  GA_Hun_Chaos_AAAA_C = 0.68,
  GA_Hun_Chaos_AAABB_Fire_C = 1.0,
  GA_Hun_Chaos_AAABB_Ice_C = 0.87,
  GA_Hun_Chaos_AAABB_Physics_C = 0.43,
  GA_Hun_Chaos_AAAB_Fire_C = 1.0,
  GA_Hun_Chaos_AAAB_Ice_C = 0.87,
  GA_Hun_Chaos_AAAB_Physics_C = 0.43,
  GA_Hun_Chaos_AAA_C = 0.66,  -- 实测 n=2，一下约 15% 血
  GA_Hun_Chaos_AABB_Fire_C = 1.0,
  GA_Hun_Chaos_AABB_Ice_C = 0.87,
  GA_Hun_Chaos_AABB_Physics_C = 0.81,
  GA_Hun_Chaos_AAB_Fire_C = 1.0,
  GA_Hun_Chaos_AAB_Ice_C = 0.87,
  GA_Hun_Chaos_AAB_Physics_C = 0.82,
  GA_Hun_Chaos_AA_C = 0.51,  -- 实测 n=4，一下约 12% 血
  GA_Hun_Chaos_ABB_Fire_C = 1.0,
  GA_Hun_Chaos_ABB_Ice_C = 0.87,
  GA_Hun_Chaos_ABB_Physics_C = 0.61,
  GA_Hun_Chaos_AB_Fire_C = 1.0,  -- 实测 n=1，一下约 47% 血
  GA_Hun_Chaos_AB_Ice_C = 0.87,  -- 实测 n=1，一下约 72% 血
  GA_Hun_Chaos_AB_Physics_C = 0.96,
  GA_Hun_Chaos_A_C = 0.79,  -- 实测 n=3，一下约 28% 血
  GA_Hun_Chaos_A_DashDraw_C = 0.6,
  GA_Hun_Chaos_A_Dash_C = 0.6,
  GA_Hun_Chaos_A_Draw_C = 0.53,
  GA_Hun_Chaos_BBB_Fire_C = 1.0,  -- 实测 n=1，一下约 17% 血
  GA_Hun_Chaos_BBB_Ice_C = 0.87,
  GA_Hun_Chaos_BBB_Physics_C = 0.81,  -- 实测 n=1，一下约 1% 血
  GA_Hun_Chaos_BB_Fire_C = 1.0,  -- 实测 n=1，一下约 14% 血
  GA_Hun_Chaos_BB_Ice_C = 0.87,
  GA_Hun_Chaos_BB_Physics_C = 0.39,  -- 实测 n=1，一下约 6% 血
  GA_Hun_Chaos_B_DashDraw_C = 0.49,
  GA_Hun_Chaos_B_Dash_C = 0.21,
  GA_Hun_Chaos_B_Draw_C = 0.47,
  GA_Hun_Chaos_B_Fire_C = 1.0,  -- 实测 n=5，一下约 2% 血
  GA_Hun_Chaos_B_Hold_Fire_C = 1.0,
  GA_Hun_Chaos_B_Hold_Ice_C = 0.87,  -- 实测 n=1，一下约 71% 血
  GA_Hun_Chaos_B_Hold_Physics_C = 0.55,
  GA_Hun_Chaos_B_Ice_C = 0.87,  -- 实测 n=2，一下约 46% 血
  GA_Hun_Chaos_B_Physics_C = 0.55,  -- 实测 n=2，一下约 25% 血
  GA_Hun_Chaos_C_C = 0.66,  -- 实测 n=5，一下约 15% 血
  GA_Hun_Chaos_SWT_Power_C = 0.87,
  GA_Hun_Chaos_SwitchFormFire_SWT_C = 0.87,
  GA_Hun_Chaos_SwitchFormIce_SWT_C = 0.87,
  GA_Hun_Chaos_SwitchFormPhysic_SWT_C = 0.26,  -- 实测 n=2，一下约 12% 血

-- ==== 炽刃（淬炼长形黑伤）（ChiRen，24 招）
  GA_Hun_ChiRen_AAAABB_C = 0.49,
  GA_Hun_ChiRen_AAAAB_C = 0.49,
  GA_Hun_ChiRen_AAAA_C = 1.2,  -- 实测 n=1，一下约 5% 血
  GA_Hun_ChiRen_AAABB_C = 0.9,
  GA_Hun_ChiRen_AAAB_C = 1.29,
  GA_Hun_ChiRen_AAA_C = 0.96,  -- 实测 n=3，一下约 23% 血
  GA_Hun_ChiRen_AABB_C = 0.76,
  GA_Hun_ChiRen_AAB_C = 1.14,
  GA_Hun_ChiRen_AA_C = 0.96,
  GA_Hun_ChiRen_ABB_C = 0.49,
  GA_Hun_ChiRen_AB_C = 0.68,  -- 实测 n=1，一下约 13% 血
  GA_Hun_ChiRen_A_C = 1.62,  -- 实测 n=2，一下约 24% 血
  GA_Hun_ChiRen_A_Draw_C = 1.62,
  GA_Hun_ChiRen_A_Snap_C = 1.0,
  GA_Hun_ChiRen_BBB_C = 1.03,  -- 实测 n=1，一下约 29% 血
  GA_Hun_ChiRen_BB_C = 1.11,  -- 实测 n=1，一下约 6% 血
  GA_Hun_ChiRen_BD_C = 0.29,  -- 实测 n=1，一下约 19% 血
  GA_Hun_ChiRen_B_C = 1.0,  -- 实测 n=1，一下约 11% 血
  GA_Hun_ChiRen_B_DashDraw_C = 0.84,
  GA_Hun_ChiRen_B_Dash_C = 0.88,
  GA_Hun_ChiRen_B_Draw_C = 0.91,
  GA_Hun_ChiRen_B_Snap_C = 1.0,
  GA_Hun_ChiRen_C_C = 0.78,  -- 实测 n=3，一下约 37% 血
  GA_Hun_ChiRen_SWT_C = 0.11,

-- ==== 痴者残剑（ChiZheCanJian，28 招）
  GA_Hun_ChiZheCanJian_A_Snap_C = 1.0,
  GA_Hun_ChiZheCanJian_B_Snap_C = 1.0,
  GA_Hun_ChiZheCanJian_C_C = 0.79,
  GA_Hun_ChiZheCanJian_C_Zui_C = 1.0,
  GA_Hun_ChiZheCanJian_Drunk_AAAAA_C = 1.0,
  GA_Hun_ChiZheCanJian_Drunk_AAAA_C = 1.0,
  GA_Hun_ChiZheCanJian_Drunk_AAA_C = 0.79,
  GA_Hun_ChiZheCanJian_Drunk_AA_C = 1.0,
  GA_Hun_ChiZheCanJian_Drunk_A_C = 1.32,
  GA_Hun_ChiZheCanJian_Drunk_A_DashChild_C = 0.66,
  GA_Hun_ChiZheCanJian_Drunk_BBB_C = 1.0,
  GA_Hun_ChiZheCanJian_Drunk_BB_C = 1.0,
  GA_Hun_ChiZheCanJian_Drunk_B_C = 1.0,
  GA_Hun_ChiZheCanJian_Normal_AAAAA_C = 1.43,
  GA_Hun_ChiZheCanJian_Normal_AAAA_C = 1.17,
  GA_Hun_ChiZheCanJian_Normal_AAA_C = 0.99,
  GA_Hun_ChiZheCanJian_Normal_AA_C = 1.5,
  GA_Hun_ChiZheCanJian_Normal_AA_DashChild_C = 0.99,
  GA_Hun_ChiZheCanJian_Normal_A_C = 1.5,  -- 实测 n=2，一下约 17% 血
  GA_Hun_ChiZheCanJian_Normal_BBB_C = 1.01,
  GA_Hun_ChiZheCanJian_Normal_BB_C = 0.56,
  GA_Hun_ChiZheCanJian_Normal_B_C = 1.35,
  GA_Hun_ChiZheCanJian_Normal_B_DashChild_C = 0.91,
  GA_Hun_ChiZheCanJian_PerfectDodge_C = 1.0,
  GA_Hun_ChiZheCanJian_SWT_C = 1.0,
  GA_Hun_ChiZheCanJian_Tipsy_BBB_C = 1.0,
  GA_Hun_ChiZheCanJian_Tipsy_BB_C = 1.0,  -- 实测 n=1，一下约 49% 血
  GA_Hun_ChiZheCanJian_Tipsy_B_C = 1.0,  -- 实测 n=2，一下约 26% 血

-- ==== 黑伤双刃（Double，41 招）
  GA_Hun_Double_AAAAAA_C = 0.6,
  GA_Hun_Double_AAAAA_C = 0.62,
  GA_Hun_Double_AAAA_C = 0.71,  -- 实测 n=41，一下约 11% 血
  GA_Hun_Double_AAABBB_C = 0.97,
  GA_Hun_Double_AAABB_C = 0.49,
  GA_Hun_Double_AAAB_C = 0.65,
  GA_Hun_Double_AAA_C = 1.25,  -- 实测 n=98，一下约 10% 血
  GA_Hun_Double_AABB_C = 0.37,
  GA_Hun_Double_AAB_C = 0.96,
  GA_Hun_Double_AA_C = 0.57,  -- 实测 n=255，一下约 24% 血
  GA_Hun_Double_ABB_C = 0.56,  -- 实测 n=1，一下约 13% 血
  GA_Hun_Double_AB_C = 0.52,  -- 实测 n=42，一下约 16% 血
  GA_Hun_Double_ATBBB_C = 0.66,  -- 实测 n=9，一下约 18% 血
  GA_Hun_Double_ATBB_C = 0.53,  -- 实测 n=8，一下约 17% 血
  GA_Hun_Double_ATB_C = 1.4,  -- 实测 n=8，一下约 32% 血
  GA_Hun_Double_A_C = 0.33,  -- 实测 n=223，一下约 23% 血
  GA_Hun_Double_A_DashDraw_Short_C = 1.08,  -- 实测 n=15，一下约 19% 血
  GA_Hun_Double_A_Dash_Short_C = 0.51,  -- 实测 n=1，一下约 8% 血
  GA_Hun_Double_A_Draw_C = 1.5,  -- 实测 n=7，一下约 23% 血
  GA_Hun_Double_A_Snap_C = 0.85,  -- 实测 n=1，一下约 30% 血
  GA_Hun_Double_Air_A_C = 0.69,  -- 实测 n=22，一下约 32% 血
  GA_Hun_Double_Air_A_Draw_C = 0.69,  -- 实测 n=13，一下约 32% 血
  GA_Hun_Double_Air_B_C = 0.43,  -- 实测 n=6，一下约 33% 血
  GA_Hun_Double_Air_B_Draw_C = 0.86,
  GA_Hun_Double_BBBB_C = 0.66,  -- 实测 n=11，一下约 39% 血
  GA_Hun_Double_BBB_C = 0.54,  -- 实测 n=9，一下约 32% 血
  GA_Hun_Double_BB_C = 0.77,  -- 实测 n=60，一下约 16% 血
  GA_Hun_Double_BTA_C = 0.7,  -- 实测 n=17，一下约 24% 血
  GA_Hun_Double_B_C = 1.07,  -- 实测 n=68，一下约 11% 血
  GA_Hun_Double_B_DashDraw_C = 0.98,  -- 实测 n=11，一下约 30% 血
  GA_Hun_Double_B_Dash_C = 0.73,  -- 实测 n=47，一下约 30% 血
  GA_Hun_Double_B_Draw_C = 0.8,  -- 实测 n=13，一下约 18% 血
  GA_Hun_Double_B_Snap_C = 0.85,
  GA_Hun_Double_C_C = 0.72,  -- 实测 n=5，一下约 45% 血
  GA_Hun_Double_JueYing_C_Air_C = 0.85,
  GA_Hun_Double_JueYing_C_C = 0.77,  -- 实测 n=11，一下约 42% 血
  GA_Hun_Double_PerfectDodge_C = 0.85,
  GA_Hun_Double_SWT_C = 0.85,  -- 实测 n=17，一下约 21% 血
  GA_Hun_Double_SWT_Tutorial2_C = 0.85,
  GA_Hun_Double_SWT_Tutorial_C = 0.85,
  GA_Hun_Double_SWT_UI_C = 0.85,

-- ==== 别离残钩（DualHook，32 招）
  GA_Hun_DualHook_AAAAA_C = 0.97,
  GA_Hun_DualHook_AAAA_C = 0.91,  -- 实测 n=1，一下约 28% 血
  GA_Hun_DualHook_AAABB_C = 0.96,
  GA_Hun_DualHook_AAAB_C = 0.66,
  GA_Hun_DualHook_AAA_C = 1.19,  -- 实测 n=2，一下约 11% 血
  GA_Hun_DualHook_AABB_C = 0.48,
  GA_Hun_DualHook_AAB_C = 0.89,
  GA_Hun_DualHook_AA_C = 0.76,  -- 实测 n=9，一下约 25% 血
  GA_Hun_DualHook_ABB_C = 0.79,
  GA_Hun_DualHook_AB_C = 0.76,
  GA_Hun_DualHook_A_C = 0.74,  -- 实测 n=13，一下约 20% 血
  GA_Hun_DualHook_A_DashDraw_C = 0.69,
  GA_Hun_DualHook_A_Dash_C = 1.07,  -- 实测 n=1，一下约 26% 血
  GA_Hun_DualHook_A_Draw_C = 0.74,
  GA_Hun_DualHook_A_Pursure_02_C = 0.6,
  GA_Hun_DualHook_A_Snap_C = 1.0,
  GA_Hun_DualHook_Air_B_C = 0.55,
  GA_Hun_DualHook_Air_B_Draw_C = 0.55,
  GA_Hun_DualHook_BBBB_C = 0.66,
  GA_Hun_DualHook_BBB_C = 0.63,  -- 实测 n=1，一下约 18% 血
  GA_Hun_DualHook_BB_C = 0.51,
  GA_Hun_DualHook_B_C = 0.75,
  GA_Hun_DualHook_B_DashDraw_C = 0.6,
  GA_Hun_DualHook_B_Dash_C = 0.8,
  GA_Hun_DualHook_B_Draw_C = 1.0,
  GA_Hun_DualHook_B_Pursure_C = 0.58,
  GA_Hun_DualHook_B_Snap_C = 1.0,
  GA_Hun_DualHook_C_C = 0.94,
  GA_Hun_DualHook_DB_SWT_C = 1.0,
  GA_Hun_DualHook_PerfectDodge_GEx_C = 1.0,
  GA_Hun_DualHook_PerfectDodge_HeavyAttack_C = 1.0,
  GA_Hun_DualHook_SWT_Power_C = 1.0,

-- ==== 白山风雷剑（FengLeiJian，30 招）
  GA_Hun_FengLeiJian_AAAA_C = 0.5,
  GA_Hun_FengLeiJian_AAABB_C = 0.59,
  GA_Hun_FengLeiJian_AAAB_C = 0.56,
  GA_Hun_FengLeiJian_AAA_C = 0.82,
  GA_Hun_FengLeiJian_AABAB_C = 0.44,
  GA_Hun_FengLeiJian_AABA_C = 0.51,
  GA_Hun_FengLeiJian_AABB_C = 0.4,
  GA_Hun_FengLeiJian_AAB_C = 0.9,
  GA_Hun_FengLeiJian_AA_C = 0.27,
  GA_Hun_FengLeiJian_AB_C = 0.85,
  GA_Hun_FengLeiJian_A_C = 0.34,
  GA_Hun_FengLeiJian_A_DashDraw_C = 1.12,
  GA_Hun_FengLeiJian_A_Dash_C = 0.53,
  GA_Hun_FengLeiJian_A_Draw_C = 1.5,
  GA_Hun_FengLeiJian_A_Snap_C = 1.0,
  GA_Hun_FengLeiJian_Air_A_C = 1.5,
  GA_Hun_FengLeiJian_Air_A_Draw_C = 1.5,
  GA_Hun_FengLeiJian_Air_B_C = 0.47,
  GA_Hun_FengLeiJian_Air_B_Draw_C = 0.23,
  GA_Hun_FengLeiJian_BBBB_C = 0.4,
  GA_Hun_FengLeiJian_BBB_C = 0.39,
  GA_Hun_FengLeiJian_BB_C = 0.63,
  GA_Hun_FengLeiJian_B_C = 0.57,
  GA_Hun_FengLeiJian_B_DashDraw_C = 0.52,
  GA_Hun_FengLeiJian_B_Dash_C = 0.76,
  GA_Hun_FengLeiJian_B_Draw_C = 0.57,
  GA_Hun_FengLeiJian_B_Hold_C = 0.64,
  GA_Hun_FengLeiJian_B_Snap_C = 1.0,
  GA_Hun_FengLeiJian_C_C = 0.82,
  GA_Hun_FengLeiJian_SWT_Power_C = 0.21,

-- ==== 不算攻击、出手后会打人（§203 残影反打，只记平衡）（非攻击，1 招）
  GA_Hun_AdvancedDash_Double_Jade_C = 0.13,

-- ==== L1+圈 特殊技（影杀 / 瞬杀 / 裂斩，§183）（GlobalActionAbilities，6 招）
  GA_GlobalActionAbilities_YingSha_C_C = 0.15,
  GA_GlobalActionAbility_LieZhan_CB_C = 0.23,
  GA_GlobalActionAbility_LieZhan_C_C = 0.49,
  GA_GlobalActionAbility_ShunSha_CB_C = 0.07,
  GA_GlobalActionAbility_ShunSha_C_C = 0.14,
  GA_GlobalActionAbility_YingSha_CB_C = 0.07,

-- ==== 红妆鬼斩（GuiTouBlade，28 招）
  GA_Hun_GuiTouBlade_AAAA_C = 0.73,
  GA_Hun_GuiTouBlade_AAABB_C = 0.5,
  GA_Hun_GuiTouBlade_AAAB_C = 0.57,
  GA_Hun_GuiTouBlade_AAA_C = 0.89,
  GA_Hun_GuiTouBlade_AABB_C = 0.76,
  GA_Hun_GuiTouBlade_AAB_C = 1.0,
  GA_Hun_GuiTouBlade_AA_C = 0.89,
  GA_Hun_GuiTouBlade_ABB_C = 0.57,
  GA_Hun_GuiTouBlade_AB_C = 0.71,  -- 实测 n=2，一下约 45% 血
  GA_Hun_GuiTouBlade_A_C = 1.5,
  GA_Hun_GuiTouBlade_A_DashDraw_C = 0.95,
  GA_Hun_GuiTouBlade_A_Dash_C = 0.68,
  GA_Hun_GuiTouBlade_A_Draw_C = 1.5,
  GA_Hun_GuiTouBlade_A_Snap_C = 1.0,
  GA_Hun_GuiTouBlade_BBB_C = 0.75,
  GA_Hun_GuiTouBlade_BB_C = 0.71,  -- 实测 n=11，一下约 9% 血
  GA_Hun_GuiTouBlade_BB_UnCharge_C = 0.89,
  GA_Hun_GuiTouBlade_BB_UnCharge_Reinforced_C = 0.71,
  GA_Hun_GuiTouBlade_B_C = 0.53,  -- 实测 n=11，一下约 7% 血
  GA_Hun_GuiTouBlade_B_DashDraw_C = 0.51,
  GA_Hun_GuiTouBlade_B_Dash_C = 1.36,
  GA_Hun_GuiTouBlade_B_Draw_C = 0.84,
  GA_Hun_GuiTouBlade_B_Hold_C = 0.25,
  GA_Hun_GuiTouBlade_B_Hold_Start_C = 0.69,
  GA_Hun_GuiTouBlade_B_Hold_Unreinforced_C = 1.0,
  GA_Hun_GuiTouBlade_B_Snap_C = 1.0,
  GA_Hun_GuiTouBlade_C_C = 0.81,
  GA_Hun_GuiTouBlade_SWT_C = 0.69,

-- ==== 黑魔伤（淬炼黑伤）（HeiMoShang，27 招）
  GA_Hun_HeiMoShang_AAAAAA_C = 0.55,  -- 实测 n=1，一下约 38% 血
  GA_Hun_HeiMoShang_AAAAABB_C = 0.47,
  GA_Hun_HeiMoShang_AAAAAB_C = 0.52,  -- 实测 n=1，一下约 43% 血
  GA_Hun_HeiMoShang_AAAAA_C = 0.51,  -- 实测 n=1，一下约 35% 血
  GA_Hun_HeiMoShang_AAAAB_Alt_C = 0.75,
  GA_Hun_HeiMoShang_AAAA_C = 0.65,  -- 实测 n=2，一下约 53% 血
  GA_Hun_HeiMoShang_AAABB_C = 1.05,
  GA_Hun_HeiMoShang_AAAB_C = 0.68,  -- 实测 n=1，一下约 16% 血
  GA_Hun_HeiMoShang_AAA_C = 1.07,  -- 实测 n=5，一下约 12% 血
  GA_Hun_HeiMoShang_AABB_C = 0.39,  -- 实测 n=1，一下约 12% 血
  GA_Hun_HeiMoShang_AAB_C = 0.3,  -- 实测 n=2，一下约 15% 血
  GA_Hun_HeiMoShang_AA_C = 0.59,  -- 实测 n=6，一下约 16% 血
  GA_Hun_HeiMoShang_ABB_C = 0.66,  -- 实测 n=1，一下约 66% 血
  GA_Hun_HeiMoShang_AB_C = 0.97,  -- 实测 n=9，一下约 18% 血
  GA_Hun_HeiMoShang_A_C = 0.74,  -- 实测 n=9，一下约 22% 血
  GA_Hun_HeiMoShang_A_DashDraw_C = 0.65,
  GA_Hun_HeiMoShang_A_Dash_C = 0.86,  -- 实测 n=4，一下约 25% 血
  GA_Hun_HeiMoShang_A_Draw_C = 0.99,
  GA_Hun_HeiMoShang_BBBB_C = 0.49,  -- 实测 n=4，一下约 30% 血
  GA_Hun_HeiMoShang_BBB_C = 0.98,  -- 实测 n=7，一下约 21% 血
  GA_Hun_HeiMoShang_BB_C = 0.55,  -- 实测 n=11，一下约 20% 血
  GA_Hun_HeiMoShang_B_C = 0.64,  -- 实测 n=15，一下约 7% 血
  GA_Hun_HeiMoShang_B_DashDraw_C = 0.44,
  GA_Hun_HeiMoShang_B_Dash_C = 0.27,  -- 实测 n=1，一下约 14% 血
  GA_Hun_HeiMoShang_B_Draw_C = 0.73,
  GA_Hun_HeiMoShang_C1_C = 0.77,  -- 实测 n=1，一下约 113% 血
  GA_Hun_HeiMoShang_SWT_C = 0.45,  -- 实测 n=4，一下约 77% 血

-- ==== 荡寇凶刃（Horizontal，23 招）
  GA_Hun_Horizontal_AAAA_C = 0.57,
  GA_Hun_Horizontal_AAAB_C = 0.51,
  GA_Hun_Horizontal_AAA_C = 1.0,
  GA_Hun_Horizontal_AAB_C = 0.55,
  GA_Hun_Horizontal_AA_C = 0.67,
  GA_Hun_Horizontal_AB_C = 0.57,
  GA_Hun_Horizontal_A_C = 1.0,
  GA_Hun_Horizontal_A_DashDraw_C = 0.94,
  GA_Hun_Horizontal_A_Dash_C = 1.0,
  GA_Hun_Horizontal_A_Draw_C = 0.51,
  GA_Hun_Horizontal_A_Snap_C = 1.0,
  GA_Hun_Horizontal_BB_C = 1.0,
  GA_Hun_Horizontal_B_C = 0.94,
  GA_Hun_Horizontal_B_DashDraw_C = 0.45,
  GA_Hun_Horizontal_B_Dash_C = 0.63,
  GA_Hun_Horizontal_B_Draw_C = 0.94,
  GA_Hun_Horizontal_B_NoCost_C = 0.62,
  GA_Hun_Horizontal_B_Snap_C = 1.0,
  GA_Hun_Horizontal_C_C = 1.02,
  GA_Hun_Horizontal_CounterAttackBase_C = 1.0,
  GA_Hun_Horizontal_CounterAttack_01_C = 0.4,
  GA_Hun_Horizontal_CounterAttack_02_C = 0.62,
  GA_Hun_Horizontal_SWT_Power_C = 1.0,

-- ==== 残钢刃（Iron，27 招）
  GA_Hun_Iron_AAAAA_C = 0.99,
  GA_Hun_Iron_AAAA_C = 0.85,  -- 实测 n=1，一下约 14% 血
  GA_Hun_Iron_AAABB_C = 0.62,
  GA_Hun_Iron_AAAB_C = 0.7,
  GA_Hun_Iron_AAA_C = 0.87,
  GA_Hun_Iron_AABB_C = 0.46,
  GA_Hun_Iron_AAB_C = 0.59,  -- 实测 n=2，一下约 24% 血
  GA_Hun_Iron_AA_C = 1.36,  -- 实测 n=4，一下约 18% 血
  GA_Hun_Iron_ABB_C = 0.47,
  GA_Hun_Iron_AB_C = 0.66,  -- 实测 n=1，一下约 35% 血
  GA_Hun_Iron_A_C = 0.74,
  GA_Hun_Iron_A_DashDraw_C = 0.57,
  GA_Hun_Iron_A_Dash_C = 0.95,  -- 实测 n=2，一下约 5% 血
  GA_Hun_Iron_A_Draw_C = 0.62,
  GA_Hun_Iron_A_Snap_C = 1.0,
  GA_Hun_Iron_BBB_C = 0.95,
  GA_Hun_Iron_BB_C = 0.92,  -- 实测 n=3，一下约 9% 血
  GA_Hun_Iron_BChargeAttack_C = 0.47,
  GA_Hun_Iron_BCharge_C = 1.0,
  GA_Hun_Iron_B_C = 0.55,  -- 实测 n=5，一下约 21% 血
  GA_Hun_Iron_B_DashDraw_C = 0.86,
  GA_Hun_Iron_B_Dash_C = 0.86,
  GA_Hun_Iron_B_Draw_C = 1.2,
  GA_Hun_Iron_B_Snap_C = 1.0,
  GA_Hun_Iron_BreakAct_02_C = 1.0,
  GA_Hun_Iron_C_C = 1.3,  -- 实测 n=1，一下约 216% 血
  GA_Hun_Iron_SWT_C = 1.0,  -- 实测 n=1，一下约 6% 血

-- ==== 玉双环（Jade，27 招）
  GA_Hun_Jade_AAAAAA_C = 1.51,
  GA_Hun_Jade_AAAAA_C = 1.28,
  GA_Hun_Jade_AAAA_C = 1.21,
  GA_Hun_Jade_AAABB_C = 0.3,
  GA_Hun_Jade_AAAB_C = 0.25,  -- 实测 n=1，一下约 21% 血
  GA_Hun_Jade_AAA_C = 0.59,  -- 实测 n=2，一下约 12% 血
  GA_Hun_Jade_AABB_C = 0.28,
  GA_Hun_Jade_AAB_C = 0.18,
  GA_Hun_Jade_AA_C = 1.02,  -- 实测 n=2，一下约 10% 血
  GA_Hun_Jade_ABB_C = 1.08,
  GA_Hun_Jade_AB_C = 0.62,  -- 实测 n=2，一下约 29% 血
  GA_Hun_Jade_A_C = 1.02,  -- 实测 n=3，一下约 24% 血
  GA_Hun_Jade_A_DashDraw_C = 1.62,
  GA_Hun_Jade_A_Dash_C = 1.35,
  GA_Hun_Jade_A_Draw_C = 0.74,
  GA_Hun_Jade_A_Snap_C = 1.0,
  GA_Hun_Jade_BBBB_C = 0.29,  -- 实测 n=3，一下约 22% 血
  GA_Hun_Jade_BBB_C = 1.33,  -- 实测 n=3，一下约 6% 血
  GA_Hun_Jade_BB_C = 0.9,  -- 实测 n=6，一下约 18% 血
  GA_Hun_Jade_B_C = 0.9,  -- 实测 n=5，一下约 8% 血
  GA_Hun_Jade_B_DashDraw_C = 1.2,
  GA_Hun_Jade_B_Dash_C = 0.1,
  GA_Hun_Jade_B_Draw_C = 1.38,
  GA_Hun_Jade_B_Snap_C = 1.0,
  GA_Hun_Jade_C_Range_C = 0.66,
  GA_Hun_Jade_PerfectDodge_C = 1.0,
  GA_Hun_Jade_SWT_C = 0.1,  -- 实测 n=1，一下约 35% 血

-- ==== 断肢锯（另一套名字）（JigSaw，4 招）
  GA_Hun_JigSaw_AAAA_C = 0.51,
  GA_Hun_JigSaw_AAA_C = 0.88,
  GA_Hun_JigSaw_AA_C = 0.88,
  GA_Hun_JigSaw_A_C = 0.65,

-- ==== 断肢锯（Jigsaw，27 招）
  GA_Hun_Jigsaw_AAAB_C = 0.42,
  GA_Hun_Jigsaw_AAB_C = 0.62,
  GA_Hun_Jigsaw_AB_C = 0.87,
  GA_Hun_Jigsaw_A_DashDraw_C = 0.82,
  GA_Hun_Jigsaw_A_Dash_C = 0.82,
  GA_Hun_Jigsaw_A_Draw_C = 0.65,
  GA_Hun_Jigsaw_A_Snap_C = 1.0,
  GA_Hun_Jigsaw_Air_A_C = 0.75,
  GA_Hun_Jigsaw_Air_A_Draw_C = 1.0,
  GA_Hun_Jigsaw_Air_B_C = 0.69,
  GA_Hun_Jigsaw_Air_B_Draw_C = 0.69,
  GA_Hun_Jigsaw_BB_C = 0.62,
  GA_Hun_Jigsaw_B_C = 0.55,
  GA_Hun_Jigsaw_B_DashDraw_C = 0.9,
  GA_Hun_Jigsaw_B_Dash_C = 1.0,
  GA_Hun_Jigsaw_B_Snap_C = 1.0,
  GA_Hun_Jigsaw_BreakAct_C = 1.0,
  GA_Hun_Jigsaw_C_C = 0.5,
  GA_Hun_Jigsaw_PerfectDodge_C = 1.0,
  GA_Hun_Jigsaw_RAAA_C = 0.8,
  GA_Hun_Jigsaw_RAA_C = 0.56,
  GA_Hun_Jigsaw_RA_C = 1.38,
  GA_Hun_Jigsaw_RBB_C = 0.74,
  GA_Hun_Jigsaw_RB_C = 0.6,
  GA_Hun_Jigsaw_SA_C = 1.14,
  GA_Hun_Jigsaw_SB_C = 1.17,
  GA_Hun_Jigsaw_SWT_Power_C = 1.0,

-- ==== L1+三角 特殊技（近战 450/秒、远程 225/秒，§185）（Stance+HeavyAttack，23 招）
  GA_Hun_BaiYing_BuffAtk_C = 0.47,
  GA_Hun_Chaos_SwitchFormFire_C = 0.39,
  GA_Hun_Chaos_SwitchFormIce_C = 0.39,
  GA_Hun_Chaos_SwitchFormPhysic_C = 0.39,
  GA_Hun_ChiRen_BSup_C = 0.2,
  GA_Hun_DualHook_DB_C = 0.71,
  GA_Hun_FengLeiJian_FengLeiState_SpecailAttack_02_C = 0.28,
  GA_Hun_Horizontal_BladeWave_C = 0.3,
  GA_Hun_Iron_Buff_C = 0.73,
  GA_Hun_Jade_DB_C = 0.13,
  GA_Hun_Long_BSup_C = 0.95,
  GA_Hun_LuanYing_Buff_C = 0.46,
  GA_Hun_LuanYing_P2_Buff_C = 0.46,
  GA_Hun_PoJun_DB_02_C = 1.69,  -- 实测 n=1，一下约 109% 血
  GA_Hun_PoJun_DB_C = 2.09,
  GA_Hun_ShuangYue_DB_C = 0.24,
  GA_Hun_SlitheringSword_DB4_C = 0.67,  -- 实测 n=1，一下约 32% 血
  GA_Hun_SlitheringSword_DB5_C = 0.67,
  GA_Hun_SnakeDual_DB_C = 0.14,
  GA_Hun_XieShan_DB_C = 1.23,  -- 实测 n=1，一下约 8% 血
  GA_Hun_YanYueDao_SpecialSkill_C = 0.5,
  GA_Hun_ZhanMa_DB_C = 1.62,  -- 实测 n=2，一下约 118% 血
  GA_Hun_ZiMingJian_New_DB_C = 0.2,

-- ==== 长形黑伤（Long，34 招）
  GA_Hun_Long_AAAAB_C = 1.0,
  GA_Hun_Long_AAAA_C = 1.0,
  GA_Hun_Long_AAAB_C = 1.0,
  GA_Hun_Long_AAA_C = 1.0,
  GA_Hun_Long_AAB_C = 1.0,
  GA_Hun_Long_AA_C = 1.0,
  GA_Hun_Long_AB_C = 1.0,
  GA_Hun_Long_A_C = 1.0,
  GA_Hun_Long_A_DashDraw_C = 0.49,
  GA_Hun_Long_A_Dash_C = 1.0,  -- 实测 n=1，一下约 14% 血
  GA_Hun_Long_A_Draw_C = 1.0,
  GA_Hun_Long_A_Snap_C = 1.0,
  GA_Hun_Long_Air_A_C = 0.59,
  GA_Hun_Long_Air_A_Draw_C = 0.52,
  GA_Hun_Long_Air_B_C = 1.26,
  GA_Hun_Long_Air_B_Draw_C = 1.26,
  GA_Hun_Long_Air_SWT_C = 1.0,
  GA_Hun_Long_BBB_New_C = 1.0,
  GA_Hun_Long_BB_C = 1.0,
  GA_Hun_Long_BCharge_C = 1.0,
  GA_Hun_Long_BD_C = 1.0,
  GA_Hun_Long_B_C = 1.0,
  GA_Hun_Long_B_DashDraw_C = 1.0,
  GA_Hun_Long_B_Dash_C = 1.0,
  GA_Hun_Long_B_Draw_C = 1.0,
  GA_Hun_Long_B_Snap_C = 1.0,
  GA_Hun_Long_C_C = 1.0,
  GA_Hun_Long_CounterA_C = 1.0,
  GA_Hun_Long_CounterB_C = 0.63,
  GA_Hun_Long_Counter_C = 0.75,  -- 实测 n=2，一下约 24% 血
  GA_Hun_Long_PerfectDodge_C = 1.0,
  GA_Hun_Long_SWT_C = 1.0,
  GA_Hun_Long_SWT_Dash_C = 1.0,
  GA_Hun_Long_SWT_UI_C = 1.0,

-- ==== 乱莺剑（LuanYing，25 招）
  GA_Hun_LuanYing_AAAAA_C = 0.77,
  GA_Hun_LuanYing_AAAA_C = 0.77,
  GA_Hun_LuanYing_AAAB_C = 1.0,
  GA_Hun_LuanYing_AAA_C = 0.94,
  GA_Hun_LuanYing_AAB_C = 1.0,
  GA_Hun_LuanYing_AA_C = 0.63,
  GA_Hun_LuanYing_AB_C = 1.0,
  GA_Hun_LuanYing_A_C = 0.68,  -- 实测 n=2，一下约 18% 血
  GA_Hun_LuanYing_A_DashDraw_C = 1.5,
  GA_Hun_LuanYing_BBB_C = 1.0,
  GA_Hun_LuanYing_BB_C = 1.0,
  GA_Hun_LuanYing_B_C = 1.0,
  GA_Hun_LuanYing_B_Draw_C = 1.0,
  GA_Hun_LuanYing_CA_C = 1.0,
  GA_Hun_LuanYing_DashA_C = 0.87,
  GA_Hun_LuanYing_Draw_A_C = 0.68,
  GA_Hun_LuanYing_P2_AAAB_C = 0.85,
  GA_Hun_LuanYing_P2_AAB_C = 0.72,
  GA_Hun_LuanYing_P2_AB_C = 0.71,
  GA_Hun_LuanYing_P2_BBB_C = 0.31,  -- 实测 n=1，一下约 16% 血
  GA_Hun_LuanYing_P2_BB_C = 0.54,
  GA_Hun_LuanYing_P2_B_C = 0.33,
  GA_Hun_LuanYing_P2_CA_C = 0.5,
  GA_Hun_LuanYing_SWT_P1_C = 1.0,
  GA_Hun_LuanYing_SWT_P2_C = 1.0,

-- ==== 破军（PoJun，22 招）
  GA_Hun_PoJun_AAAA_C = 0.57,
  GA_Hun_PoJun_AAAB_C = 0.76,
  GA_Hun_PoJun_AAA_C = 1.0,
  GA_Hun_PoJun_AAB_C = 0.65,
  GA_Hun_PoJun_AA_C = 0.99,
  GA_Hun_PoJun_AB_C = 0.51,
  GA_Hun_PoJun_A_C = 1.0,
  GA_Hun_PoJun_A_DashDraw_C = 0.94,
  GA_Hun_PoJun_A_Dash_C = 0.62,
  GA_Hun_PoJun_A_Draw_C = 0.51,
  GA_Hun_PoJun_A_Snap_C = 1.0,
  GA_Hun_PoJun_BB_C = 1.0,
  GA_Hun_PoJun_B_C = 0.94,
  GA_Hun_PoJun_B_DashDraw_C = 0.63,
  GA_Hun_PoJun_B_Dash_C = 0.63,
  GA_Hun_PoJun_B_Draw_C = 0.94,
  GA_Hun_PoJun_B_Snap_C = 1.0,
  GA_Hun_PoJun_C_C = 0.85,
  GA_Hun_PoJun_PerfectDodge_C = 1.0,
  GA_Hun_PoJun_SWT_02_C = 1.0,
  GA_Hun_PoJun_SWT_C = 1.0,
  GA_Hun_PoJun_SWT_Super_C = 1.0,

-- ==== 天煞双钺（ShuangYue，30 招）
  GA_Hun_ShuangYue_AAAAAA_C = 1.2,
  GA_Hun_ShuangYue_AAAAA_C = 0.69,
  GA_Hun_ShuangYue_AAAA_C = 0.84,
  GA_Hun_ShuangYue_AAABB_C = 0.57,
  GA_Hun_ShuangYue_AAAB_C = 0.66,
  GA_Hun_ShuangYue_AAA_C = 0.88,
  GA_Hun_ShuangYue_AABB_C = 0.81,
  GA_Hun_ShuangYue_AAB_C = 0.51,
  GA_Hun_ShuangYue_AA_C = 0.63,
  GA_Hun_ShuangYue_ABB_C = 0.86,
  GA_Hun_ShuangYue_AB_C = 0.65,
  GA_Hun_ShuangYue_A_C = 0.34,
  GA_Hun_ShuangYue_A_DashDraw_C = 0.57,
  GA_Hun_ShuangYue_A_Dash_C = 0.57,
  GA_Hun_ShuangYue_A_Draw_C = 0.68,
  GA_Hun_ShuangYue_A_Snap_C = 1.0,
  GA_Hun_ShuangYue_BBBB_C = 0.67,
  GA_Hun_ShuangYue_BBB_C = 0.78,
  GA_Hun_ShuangYue_BB_C = 0.65,
  GA_Hun_ShuangYue_B_C = 0.72,
  GA_Hun_ShuangYue_B_DashDraw_C = 1.01,
  GA_Hun_ShuangYue_B_Dash_C = 0.68,
  GA_Hun_ShuangYue_B_Draw_C = 0.88,
  GA_Hun_ShuangYue_B_Snap_C = 1.0,
  GA_Hun_ShuangYue_C_C = 0.32,
  GA_Hun_ShuangYue_DB_SWT_C = 0.47,
  GA_Hun_ShuangYue_PBB_C = 0.89,
  GA_Hun_ShuangYue_PB_C = 0.94,
  GA_Hun_ShuangYue_PerfectDodge_C = 1.0,
  GA_Hun_ShuangYue_SWT_C = 1.0,

-- ==== 灵蛇软剑（SlitheringSword，26 招）
  GA_Hun_SlitheringSword_AAAAA_C = 0.52,  -- 实测 n=3，一下约 5% 血
  GA_Hun_SlitheringSword_AAAA_C = 0.6,  -- 实测 n=5，一下约 5% 血
  GA_Hun_SlitheringSword_AAABB_C = 0.42,
  GA_Hun_SlitheringSword_AAAB_C = 0.6,  -- 实测 n=1，一下约 2% 血
  GA_Hun_SlitheringSword_AAA_C = 0.91,  -- 实测 n=7，一下约 5% 血
  GA_Hun_SlitheringSword_AABB_C = 0.84,
  GA_Hun_SlitheringSword_AAB_C = 0.57,
  GA_Hun_SlitheringSword_AA_C = 0.71,  -- 实测 n=2，一下约 25% 血
  GA_Hun_SlitheringSword_ABB_C = 1.5,  -- 实测 n=1，一下约 27% 血
  GA_Hun_SlitheringSword_AB_C = 0.54,
  GA_Hun_SlitheringSword_A_C = 0.67,  -- 实测 n=10，一下约 18% 血
  GA_Hun_SlitheringSword_A_DashDraw_C = 1.09,
  GA_Hun_SlitheringSword_A_Dash_C = 0.81,  -- 实测 n=2，一下约 26% 血
  GA_Hun_SlitheringSword_A_Snap_C = 1.2,
  GA_Hun_SlitheringSword_BBB_C = 0.82,  -- 实测 n=3，一下约 18% 血
  GA_Hun_SlitheringSword_BB_C = 1.26,  -- 实测 n=7，一下约 5% 血
  GA_Hun_SlitheringSword_B_C = 0.81,  -- 实测 n=3，一下约 5% 血
  GA_Hun_SlitheringSword_B_DashDraw_C = 0.67,
  GA_Hun_SlitheringSword_B_Dash_C = 0.89,
  GA_Hun_SlitheringSword_B_Snap_C = 1.2,
  GA_Hun_SlitheringSword_C_C = 1.12,  -- 实测 n=2，一下约 138% 血
  GA_Hun_SlitheringSword_DA_C = 1.2,
  GA_Hun_SlitheringSword_EvalutionCombo_New_C = 0.63,
  GA_Hun_SlitheringSword_PerfectDodge_C = 1.2,
  GA_Hun_SlitheringSword_Potential_C = 0.85,  -- 实测 n=1，一下约 32% 血
  GA_Hun_SlitheringSword_SWT_C = 1.2,

-- ==== 白蟒赤练（SnakeDual，54 招）
  GA_Hun_SnakeDual_AAA_C = 0.99,
  GA_Hun_SnakeDual_AA_C = 0.66,
  GA_Hun_SnakeDual_ABAA_C = 0.7,
  GA_Hun_SnakeDual_ABABAA_C = 1.15,
  GA_Hun_SnakeDual_ABABA_C = 1.5,
  GA_Hun_SnakeDual_ABABB_C = 0.84,
  GA_Hun_SnakeDual_ABAB_C = 1.18,
  GA_Hun_SnakeDual_ABA_C = 0.82,
  GA_Hun_SnakeDual_ABB_C = 0.52,
  GA_Hun_SnakeDual_AB_C = 0.74,
  GA_Hun_SnakeDual_A_C = 0.61,
  GA_Hun_SnakeDual_A_Dash_C = 1.43,
  GA_Hun_SnakeDual_A_Fast_C = 0.76,
  GA_Hun_SnakeDual_A_Snap_C = 1.0,
  GA_Hun_SnakeDual_Air_A_Double_C = 1.14,
  GA_Hun_SnakeDual_Air_A_Draw_Double_C = 1.14,
  GA_Hun_SnakeDual_Air_A_Draw_Tang_C = 1.0,
  GA_Hun_SnakeDual_Air_A_Tang_C = 1.0,
  GA_Hun_SnakeDual_Air_B_Double_C = 0.69,
  GA_Hun_SnakeDual_Air_B_Draw_Double_C = 0.69,
  GA_Hun_SnakeDual_Air_B_Draw_Tang_C = 1.0,
  GA_Hun_SnakeDual_Air_B_Tang_C = 1.0,
  GA_Hun_SnakeDual_BAA_C = 0.66,
  GA_Hun_SnakeDual_BABAA_C = 1.5,
  GA_Hun_SnakeDual_BABABB_C = 0.77,
  GA_Hun_SnakeDual_BABAB_C = 0.94,
  GA_Hun_SnakeDual_BABA_C = 0.97,
  GA_Hun_SnakeDual_BABB_C = 0.68,
  GA_Hun_SnakeDual_BAB_C = 0.77,
  GA_Hun_SnakeDual_BA_C = 0.99,
  GA_Hun_SnakeDual_BB_C = 0.74,
  GA_Hun_SnakeDual_B_C = 0.91,
  GA_Hun_SnakeDual_B_Dash_C = 0.97,
  GA_Hun_SnakeDual_B_Fast_C = 0.62,
  GA_Hun_SnakeDual_B_Snap_C = 1.0,
  GA_Hun_SnakeDual_C_C = 0.72,
  GA_Hun_SnakeDual_DA_C = 0.52,
  GA_Hun_SnakeDual_PerfectDodge_C = 1.0,
  GA_Hun_SnakeDual_RAAAA_C = 1.0,
  GA_Hun_SnakeDual_RAAABB_C = 1.0,
  GA_Hun_SnakeDual_RAAAB_C = 1.0,
  GA_Hun_SnakeDual_RAAA_C = 1.0,
  GA_Hun_SnakeDual_RAABB_C = 1.0,
  GA_Hun_SnakeDual_RAAB_C = 1.0,
  GA_Hun_SnakeDual_RAA_C = 1.0,
  GA_Hun_SnakeDual_RABB_C = 1.0,
  GA_Hun_SnakeDual_RAB_C = 1.0,
  GA_Hun_SnakeDual_RA_C = 1.0,
  GA_Hun_SnakeDual_RA_Snap_C = 1.0,
  GA_Hun_SnakeDual_RBBB_C = 1.0,
  GA_Hun_SnakeDual_RBB_C = 1.0,
  GA_Hun_SnakeDual_RB_C = 1.0,
  GA_Hun_SnakeDual_RB_Snap_C = 1.0,
  GA_Hun_SnakeDual_SWT_C = 1.0,

-- ==== 黑伤（唐刀）（Tang，35 招）
  GA_Hun_Tang_AAAAAA_C = 1.0,
  GA_Hun_Tang_AAAAAB_C = 1.0,
  GA_Hun_Tang_AAAAA_C = 1.0,
  GA_Hun_Tang_AAAA_C = 1.0,
  GA_Hun_Tang_AAABB_C = 1.0,
  GA_Hun_Tang_AAAB_C = 1.0,
  GA_Hun_Tang_AAA_C = 1.0,
  GA_Hun_Tang_AABB_C = 1.0,
  GA_Hun_Tang_AAB_C = 1.0,
  GA_Hun_Tang_AA_C = 1.0,  -- 实测 n=9，一下约 19% 血
  GA_Hun_Tang_ABB_C = 1.0,
  GA_Hun_Tang_AB_C = 1.0,
  GA_Hun_Tang_A_C = 1.0,
  GA_Hun_Tang_A_DashDraw_C = 0.77,
  GA_Hun_Tang_A_Dash_C = 1.0,
  GA_Hun_Tang_A_Draw_C = 1.0,
  GA_Hun_Tang_A_Snap_C = 1.0,
  GA_Hun_Tang_Air_A_C = 0.75,
  GA_Hun_Tang_Air_A_Draw_C = 1.0,
  GA_Hun_Tang_Air_B_C = 0.69,
  GA_Hun_Tang_Air_B_Draw_C = 0.69,
  GA_Hun_Tang_Air_SWT_C = 1.0,
  GA_Hun_Tang_BBBB_C = 1.0,
  GA_Hun_Tang_BBB_C = 1.0,
  GA_Hun_Tang_BB_C = 1.0,
  GA_Hun_Tang_B_C = 1.0,
  GA_Hun_Tang_B_DashDraw_C = 0.95,
  GA_Hun_Tang_B_Dash_C = 1.0,
  GA_Hun_Tang_B_Draw_C = 1.16,
  GA_Hun_Tang_B_Snap_C = 1.0,
  GA_Hun_Tang_C_C = 1.0,
  GA_Hun_Tang_PerfectDodge_C = 0.45,  -- 实测 n=3，一下约 68% 血
  GA_Hun_Tang_SWT_C = 1.0,
  GA_Hun_Tang_SWT_Dash_C = 1.0,
  GA_Hun_Tang_SWT_UI_C = 0.78,

-- ==== 圣母邪扇（XieShan，24 招）
  GA_Hun_XieShan_AAAAA_C = 0.66,  -- 实测 n=1，一下约 8% 血
  GA_Hun_XieShan_AAAA_C = 1.0,  -- 实测 n=1，一下约 42% 血
  GA_Hun_XieShan_AAABB_C = 0.4,
  GA_Hun_XieShan_AAAB_C = 1.4,
  GA_Hun_XieShan_AAA_C = 0.38,  -- 实测 n=3，一下约 2% 血
  GA_Hun_XieShan_AABB_C = 0.76,
  GA_Hun_XieShan_AAB_C = 0.39,
  GA_Hun_XieShan_AA_C = 1.0,  -- 实测 n=2，一下约 3% 血
  GA_Hun_XieShan_ABB_C = 0.61,  -- 实测 n=1，一下约 5% 血
  GA_Hun_XieShan_AB_C = 1.4,  -- 实测 n=1，一下约 48% 血
  GA_Hun_XieShan_A_C = 0.61,  -- 实测 n=4，一下约 28% 血
  GA_Hun_XieShan_A_DashDraw_New_C = 0.92,
  GA_Hun_XieShan_A_Dash_C = 0.99,  -- 实测 n=1，一下约 3% 血
  GA_Hun_XieShan_A_Draw_New_C = 0.92,
  GA_Hun_XieShan_A_Snap_C = 0.93,
  GA_Hun_XieShan_BBB_C = 0.77,  -- 实测 n=1，一下约 16% 血
  GA_Hun_XieShan_BB_C = 0.53,  -- 实测 n=7，一下约 12% 血
  GA_Hun_XieShan_B_C = 0.43,  -- 实测 n=7，一下约 12% 血
  GA_Hun_XieShan_B_DashDraw_New_C = 0.7,
  GA_Hun_XieShan_B_Dash_C = 0.6,
  GA_Hun_XieShan_B_Draw_New_C = 0.69,
  GA_Hun_XieShan_B_Snap_C = 0.93,
  GA_Hun_XieShan_C_C = 0.8,  -- 实测 n=5，一下约 120% 血
  GA_Hun_XieShan_SWT_02_C = 0.93,  -- 实测 n=3，一下约 17% 血

-- ==== 偃月刀（YanYueDao，14 招）
  GA_Hun_YanYueDao_AAAA_C = 0.77,
  GA_Hun_YanYueDao_AAA_C = 0.88,  -- 实测 n=1，一下约 22% 血
  GA_Hun_YanYueDao_AA_C = 0.88,
  GA_Hun_YanYueDao_A_C = 0.86,
  GA_Hun_YanYueDao_A_Dash_C = 0.82,
  GA_Hun_YanYueDao_BB_C = 0.46,
  GA_Hun_YanYueDao_B_C = 0.82,
  GA_Hun_YanYueDao_B_Dash_C = 0.44,
  GA_Hun_YanYueDao_B_Reinforced_C = 0.68,
  GA_Hun_YanYueDao_B_Snap_C = 0.5,
  GA_Hun_YanYueDao_B_Snap_Reinforced_C = 0.5,
  GA_Hun_YanYueDao_C_C = 0.5,
  GA_Hun_YanYueDao_PerfectDodge_C = 0.5,
  GA_Hun_YanYueDao_SWT_C = 0.5,  -- 实测 n=6，一下约 74% 血

-- ==== 妖锯（YuuBlade，25 招）
  GA_Hun_YuuBlade_AAAAA_C = 1.18,  -- 实测 n=4，一下约 38% 血
  GA_Hun_YuuBlade_AAAAB_C = 0.64,
  GA_Hun_YuuBlade_AAAA_C = 0.66,  -- 实测 n=5，一下约 16% 血
  GA_Hun_YuuBlade_AAAB_C = 0.44,
  GA_Hun_YuuBlade_AAA_C = 0.74,  -- 实测 n=2，一下约 15% 血
  GA_Hun_YuuBlade_AAB_C = 0.53,
  GA_Hun_YuuBlade_AA_C = 0.59,  -- 实测 n=3，一下约 10% 血
  GA_Hun_YuuBlade_AB_C = 0.76,  -- 实测 n=2，一下约 18% 血
  GA_Hun_YuuBlade_A_C = 0.74,  -- 实测 n=1，一下约 6% 血
  GA_Hun_YuuBlade_A_DashDraw_C = 0.57,
  GA_Hun_YuuBlade_A_Dash_C = 0.78,
  GA_Hun_YuuBlade_A_Draw_C = 1.35,
  GA_Hun_YuuBlade_A_Snap_C = 1.0,
  GA_Hun_YuuBlade_BBBB_C = 0.8,  -- 实测 n=1，一下约 4% 血
  GA_Hun_YuuBlade_BBB_C = 0.67,  -- 实测 n=4，一下约 9% 血
  GA_Hun_YuuBlade_BB_C = 0.3,  -- 实测 n=2，一下约 34% 血
  GA_Hun_YuuBlade_B_C = 0.69,  -- 实测 n=2，一下约 8% 血
  GA_Hun_YuuBlade_B_DashDraw_C = 0.8,
  GA_Hun_YuuBlade_B_Dash_C = 0.8,
  GA_Hun_YuuBlade_B_Draw_C = 0.57,
  GA_Hun_YuuBlade_B_Snap_C = 1.0,
  GA_Hun_YuuBlade_C_C = 1.0,
  GA_Hun_YuuBlade_FastHeavyAttack_C = 0.61,
  GA_Hun_YuuBlade_FastLightAttack_C = 0.56,
  GA_Hun_YuuBlade_SWT_C = 1.0,  -- 实测 n=4，一下约 8% 血

-- ==== 亡命斩马刀（ZhanMa，25 招）
  GA_Hun_ZhanMa_AAAA_C = 0.8,
  GA_Hun_ZhanMa_AAAB_C = 1.01,
  GA_Hun_ZhanMa_AAA_C = 0.81,
  GA_Hun_ZhanMa_AAB_C = 0.55,
  GA_Hun_ZhanMa_AA_C = 0.5,  -- 实测 n=2，一下约 22% 血
  GA_Hun_ZhanMa_AB_C = 0.62,  -- 实测 n=1，一下约 42% 血
  GA_Hun_ZhanMa_A_C = 0.56,  -- 实测 n=7，一下约 84% 血
  GA_Hun_ZhanMa_A_DashDraw_C = 0.58,
  GA_Hun_ZhanMa_A_Dash_C = 0.6,
  GA_Hun_ZhanMa_A_Draw_C = 0.53,
  GA_Hun_ZhanMa_A_Snap_C = 0.5,
  GA_Hun_ZhanMa_Air_A_C = 1.41,
  GA_Hun_ZhanMa_Air_A_Draw_C = 1.41,
  GA_Hun_ZhanMa_Air_B_C = 1.26,
  GA_Hun_ZhanMa_Air_B_Draw_C = 0.99,
  GA_Hun_ZhanMa_BB_C = 0.34,  -- 实测 n=1，一下约 39% 血
  GA_Hun_ZhanMa_B_C = 0.67,
  GA_Hun_ZhanMa_B_DashDraw_C = 0.91,
  GA_Hun_ZhanMa_B_Dash_C = 0.4,
  GA_Hun_ZhanMa_B_Draw_C = 0.89,
  GA_Hun_ZhanMa_B_Snap_C = 0.5,
  GA_Hun_ZhanMa_C_C = 0.65,
  GA_Hun_ZhanMa_PerfectDodge_C = 0.5,
  GA_Hun_ZhanMa_SA_C = 0.57,  -- 实测 n=1，一下约 26% 血
  GA_Hun_ZhanMa_SWT_C = 0.25,

-- ==== 紫冥剑（ZiMingJian，28 招）
  GA_Hun_ZiMingJian_New_AAAAA_C = 1.16,  -- 实测 n=1，一下约 135% 血
  GA_Hun_ZiMingJian_New_AAAA_C = 0.58,  -- 实测 n=1，一下约 18% 血
  GA_Hun_ZiMingJian_New_AAABB_C = 0.49,
  GA_Hun_ZiMingJian_New_AAAB_C = 0.75,  -- 实测 n=1，一下约 42% 血
  GA_Hun_ZiMingJian_New_AAA_C = 0.83,  -- 实测 n=2，一下约 27% 血
  GA_Hun_ZiMingJian_New_AABB_C = 0.65,
  GA_Hun_ZiMingJian_New_AAB_C = 0.84,
  GA_Hun_ZiMingJian_New_AA_C = 0.93,  -- 实测 n=2，一下约 104% 血
  GA_Hun_ZiMingJian_New_ABB_C = 0.52,  -- 实测 n=2，一下约 12% 血
  GA_Hun_ZiMingJian_New_AB_C = 0.54,  -- 实测 n=3，一下约 41% 血
  GA_Hun_ZiMingJian_New_A_C = 0.59,  -- 实测 n=2，一下约 62% 血
  GA_Hun_ZiMingJian_New_A_DashDraw_C = 0.86,
  GA_Hun_ZiMingJian_New_A_Dash_C = 0.86,
  GA_Hun_ZiMingJian_New_A_Draw_C = 0.8,
  GA_Hun_ZiMingJian_New_A_Snap_C = 0.8,
  GA_Hun_ZiMingJian_New_BBB_C = 0.87,  -- 实测 n=6，一下约 19% 血
  GA_Hun_ZiMingJian_New_BB_C = 0.44,  -- 实测 n=8，一下约 16% 血
  GA_Hun_ZiMingJian_New_B_C = 0.86,  -- 实测 n=8，一下约 31% 血
  GA_Hun_ZiMingJian_New_B_DashDraw_C = 0.61,
  GA_Hun_ZiMingJian_New_B_Dash_C = 0.8,  -- 实测 n=2，一下约 55% 血
  GA_Hun_ZiMingJian_New_B_Draw_C = 0.86,
  GA_Hun_ZiMingJian_New_B_Snap_C = 0.8,
  GA_Hun_ZiMingJian_New_CCC_C = 0.8,
  GA_Hun_ZiMingJian_New_CC_C = 0.8,
  GA_Hun_ZiMingJian_New_C_C = 0.84,  -- 实测 n=5，一下约 115% 血
  GA_Hun_ZiMingJian_New_PerfectDodge_C = 0.8,
  GA_Hun_ZiMingJian_New_SWT_C = 0.8,
  GA_Hun_ZiMingJian_New_SWT_Power_C = 0.6,  -- 实测 n=8，一下约 42% 血

-- ==== 通用完美闪避反击（对特定敌人招）（PerfectDodge，2 招）
  GA_Hun_PerfectDodge_FireBallCounter_C = 1.0,
  GA_Hun_PerfectDodge_ThunderCounter_C = 1.0,

-- ==== 木制黑伤（序章）（WoodenSword，29 招）
  GA_Hun_WoodenSword_AAAAA_C = 0.87,
  GA_Hun_WoodenSword_AAAA_C = 1.09,
  GA_Hun_WoodenSword_AAABB_C = 0.75,
  GA_Hun_WoodenSword_AAAB_C = 1.5,
  GA_Hun_WoodenSword_AAA_C = 0.96,
  GA_Hun_WoodenSword_AABB_C = 0.83,
  GA_Hun_WoodenSword_AAB_C = 0.78,
  GA_Hun_WoodenSword_AA_C = 0.48,
  GA_Hun_WoodenSword_ABB_C = 1.31,
  GA_Hun_WoodenSword_AB_C = 0.65,
  GA_Hun_WoodenSword_A_C = 0.6,
  GA_Hun_WoodenSword_A_DashDraw_C = 0.92,
  GA_Hun_WoodenSword_A_Dash_C = 0.69,
  GA_Hun_WoodenSword_A_Draw_C = 0.6,
  GA_Hun_WoodenSword_A_Snap_C = 1.0,
  GA_Hun_WoodenSword_Air_A_C = 0.96,
  GA_Hun_WoodenSword_Air_A_Draw_C = 0.66,
  GA_Hun_WoodenSword_Air_B_C = 0.92,
  GA_Hun_WoodenSword_Air_B_Draw_C = 0.69,
  GA_Hun_WoodenSword_BBB_C = 0.34,
  GA_Hun_WoodenSword_BB_C = 1.14,
  GA_Hun_WoodenSword_B_C = 0.69,
  GA_Hun_WoodenSword_B_DashDraw_C = 1.5,
  GA_Hun_WoodenSword_B_Dash_C = 0.71,
  GA_Hun_WoodenSword_B_Draw_C = 0.69,
  GA_Hun_WoodenSword_B_Snap_C = 1.0,
  GA_Hun_WoodenSword_C_C = 1.12,
  GA_Hun_WoodenSword_PerfectDodge_C = 1.0,
  GA_Hun_WoodenSword_SWT_New_C = 1.0,

-- ==== 少年魂（序章）（Young，29 招）
  GA_Hun_Young_AAAAA_C = 1.0,
  GA_Hun_Young_AAAA_C = 1.0,
  GA_Hun_Young_AAABB_C = 1.0,
  GA_Hun_Young_AAAB_C = 1.0,
  GA_Hun_Young_AAA_C = 1.0,
  GA_Hun_Young_AABB_C = 1.0,
  GA_Hun_Young_AAB_C = 1.0,
  GA_Hun_Young_AA_C = 1.0,
  GA_Hun_Young_ABB_C = 1.0,
  GA_Hun_Young_AB_C = 1.0,
  GA_Hun_Young_A_C = 1.0,
  GA_Hun_Young_A_DashDraw_C = 1.0,
  GA_Hun_Young_A_Dash_C = 1.0,
  GA_Hun_Young_A_Draw_C = 1.0,
  GA_Hun_Young_A_Snap_C = 1.0,
  GA_Hun_Young_AdvancedDash_C = 1.0,
  GA_Hun_Young_Air_A_C = 1.0,
  GA_Hun_Young_Air_A_Draw_C = 1.0,
  GA_Hun_Young_Air_B_C = 1.0,
  GA_Hun_Young_Air_B_Draw_C = 1.0,
  GA_Hun_Young_BBB_C = 1.0,
  GA_Hun_Young_BB_C = 1.0,
  GA_Hun_Young_B_C = 1.0,
  GA_Hun_Young_B_DashDraw_C = 1.0,
  GA_Hun_Young_B_Dash_C = 1.0,
  GA_Hun_Young_B_Draw_C = 1.0,
  GA_Hun_Young_B_Snap_C = 1.0,
  GA_Hun_Young_C_C = 1.0,
  GA_Hun_Young_PerfectDodge_C = 1.0,

-- ==== 影之武装 · 巨凶斧（BrutalAxe，3 招）
  GA_BrutalAxe_Combo_C = 0.36,
  GA_BrutalAxe_Normal_C = 0.26,
  GA_BrutalAxe_Sprint_C = 0.35,

-- ==== 影之武装 · 操偶铃铛（CaoOuSiXian，1 招）
  GA_CaoOuSiXian_Normal_01_C = 0.35,

-- ==== 影之武装 · 独眼弓（DuYan，2 招）
  GA_DuYan_Bow_Laser_C = 0.19,
  GA_DuYan_Bow_Normal_C = 0.12,

-- ==== 影之武装 · 黄金火铳（HuangJinHuoChong，4 招）
  GA_HuangJinHuoChong_Dash_C = 0.13,  -- 实测 n=1，一下约 378% 血
  GA_HuangJinHuoChong_DeflectCounter_C = 0.16,
  GA_HuangJinHuoChong_Normal_02_C = 0.06,
  GA_HuangJinHuoChong_Normal_04_C = 0.06,

-- ==== 影之武装 · 火流星（HuoLiuXing，6 招）
  GA_Hun_HuoLiuXing_AAAA_C = 0.06,
  GA_Hun_HuoLiuXing_AAA_C = 0.06,
  GA_Hun_HuoLiuXing_AA_C = 0.06,
  GA_Hun_HuoLiuXing_A_C = 0.06,
  GA_Hun_HuoLiuXing_A_Short_C = 0.95,
  GA_Hun_HuoLiuXing_DB_C = 0.19,

-- ==== 影之武装 · 剑客召集令（JianKeZhaoJiLing，1 招）
  GA_JianKeZhaoJiLing_Normal_01_C = 3.0,

-- ==== 影之武装 · 长柄金瓜（JinGua，4 招）
  GA_JinGua_Air_C = 0.3,
  GA_JinGua_ExtraAttack_C = 0.3,
  GA_JinGua_Normal_C = 0.32,
  GA_JinGua_RoAttack_C = 0.55,

-- ==== 影之武装 · 苦叶寺珠串（KuYeSiZhuChuan，1 招）
  GA_KuYeSiZhuChuan_Normal_01_C = 0.35,

-- ==== 影之武装 · 烈焰狮头（LionHead，4 招）
  GA_LionHead_C = 0.18,
  GA_LionHead_Dash_C = 0.21,
  GA_LionHead_DoubleFireBall_C = 0.15,
  GA_LionHead_FireBall_C = 0.12,

-- ==== 影之武装 · 催心琵琶（Lute，5 招）
  GA_Hun_Lute_AAA_C = 0.11,
  GA_Hun_Lute_AA_C = 0.11,
  GA_Hun_Lute_A_C = 0.11,
  GA_Hun_Lute_SKill_C = 0.54,
  GA_Lute_Dash_C = 0.27,

-- ==== 影之武装 · 妙手飞刀（MiaoShouFeiDao，8 招）
  GA_MiaoShouFeiDao_DB_C = 0.45,
  GA_MiaoShouFeiDao_Escape_01_C = 0.15,
  GA_MiaoShouFeiDao_Escape_02_C = 0.15,
  GA_MiaoShouFeiDao_Escape_03_C = 0.15,
  GA_MiaoShouFeiDao_Escape_C = 0.35,
  GA_MiaoShouFeiDao_Normal_01_C = 0.07,
  GA_MiaoShouFeiDao_Normal_02_C = 0.07,
  GA_MiaoShouFeiDao_Normal_03_C = 0.07,

-- ==== 影之武装 · 墨血无痕（MoJian，6 招）
  GA_Hun_MoJian_PerfectDodge_C = 0.35,
  GA_Hun_Mojian_AAA_C = 0.11,
  GA_Hun_Mojian_AA_C = 0.11,
  GA_Hun_Mojian_A_C = 0.11,
  GA_Hun_Mojian_A_Short_C = 0.59,
  GA_Hun_Mojian_UpRunGEx_01_C = 0.18,

-- ==== 影之武装 · 影之武装通用（ShachiAbility，1 招）
  GA_ShachiAbility_Dash_Base_C = 0.35,

-- ==== 影之武装 · 追命锁镰（ShachiHook，13 招）
  GA_Hun_ShachiHook_Base_C = 0.35,
  GA_Hun_ShachiHook_CAA_C = 0.17,
  GA_Hun_ShachiHook_CA_C = 0.17,
  GA_Hun_ShachiHook_CBB_C = 0.27,
  GA_Hun_ShachiHook_CB_C = 0.27,
  GA_Hun_ShachiHook_CCCC_C = 0.2,
  GA_Hun_ShachiHook_CCC_C = 0.2,
  GA_Hun_ShachiHook_CC_C = 0.2,
  GA_Hun_ShachiHook_CDD_C = 0.59,
  GA_Hun_ShachiHook_CD_C = 0.59,
  GA_Hun_ShachiHook_C_C = 0.2,
  GA_Hun_ShachiHook_Drag_C = 2.99,
  GA_Hun_ShachiHook_HookMove_C = 0.47,

-- ==== 影之武装 · 贪狼（TanLang，3 招）
  GA_TanLang_ExtraAttack_C = 0.14,
  GA_TanLang_Normal_C = 0.38,
  GA_TanLang_SpeicalAttack_C = 0.13,  -- 实测 n=1，一下约 119% 血

-- ==== 影之武装 · 雷霆枪（ThunderSpear，7 招）
  GA_ThunderSpear_Dash_C = 0.26,
  GA_ThunderSpear_DeflectCounter_C = 0.27,
  GA_ThunderSpear_DodgeAttack_01_C = 0.21,
  GA_ThunderSpear_Normal_01_C = 0.06,
  GA_ThunderSpear_Normal_02_C = 0.06,
  GA_ThunderSpear_Normal_03_C = 0.06,
  GA_ThunderSpear_SpecialAttack_04_C = 0.55,

-- ==== 影之武装 · 铁矿拳套（TieKuangQuanTao，3 招）
  GA_TieKuangQuanTao_Charge_AAA_C = 0.13,  -- 实测 n=41，一下约 340% 血
  GA_TieKuangQuanTao_Charge_AA_C = 0.13,  -- 实测 n=18，一下约 204% 血
  GA_TieKuangQuanTao_Charge_A_C = 0.13,  -- 实测 n=31，一下约 204% 血

-- ==== 影之武装 · 虎炮（TigerCannon，4 招）
  GA_TigerCannon_C = 0.17,
  GA_TigerCannon_Counter_C = 0.35,
  GA_TigerCannon_Dash_C = 0.18,
  GA_TigerCannon_Ultimate_C = 0.08,

-- ==== 影之武装 · 羽弓（UnnamedBow，3 招）
  GA_UnnamedBow_C = 0.12,
  GA_UnnamedBow_Dash_C = 0.52,
  GA_UnnamedBow_DeflectCounter_C = 0.35,

-- ==== 影之武装 · 血滴子（XueDiZi，5 招）
  GA_XueDiZi_AAA_C = 0.35,
  GA_XueDiZi_AA_C = 0.16,
  GA_XueDiZi_A_C = 0.16,
  GA_XueDiZi_EvolutionAttack_C = 0.66,
  GA_XueDiZi_SpecialAttack_C = 2.57,

-- ==== 影之武装 · 血色铃铛（残留）（XueSeLingDang，1 招）
  GA_XueSeLingDang_Normal_01_C = 0.35,

-- ==== 影之武装 · 虚空华扇（XuKongHuaShan，2 招）
  GA_XuKongHuaShan_Reborn_C = 0.35,
  GA_XuKongHuaShan_Skill_C = 0.35,

-- ==== 影之武装 · 游龙叉（YouLongCha，2 招）
  GA_YouLongCha_Dash_C = 0.35,
  GA_YouLongCha_Normal_C = 0.1,

-- ==== 影之武装 · 游龙头（YouLongHead，2 招）
  GA_YouLongHead_WaterCannon_C = 0.08,
  GA_YouLongHead_Water_C = 0.69,

-- ==== 影之武装 · 拙壁盾（ZhuoBiDun，2 招）
  GA_ZhuoBiDun_C = 0.35,
  GA_ZhuoBiDun_Slide_C = 0.35,
}
}
