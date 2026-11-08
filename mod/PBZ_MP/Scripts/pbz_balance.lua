-- PvP 每招独立的伤害系数（HANDOVER §106.4）。**可以手改**：改完重新部署（deploy.bat 会拷这个文件）。
-- 替身放某招期间，替身的攻击力 Attack / ShachiAttack 乘这招的系数（伤害、杀气伤害一起按比例缩放，游戏自己算）；
-- 1 = 原版，0.5 = 一半，2 = 两倍。同一招的几段伤害一起缩，不能分段调。挨打的一方按这张表算，所以两边的表要一样。
-- 注释 "实测 n=…，一下约 …% 血"：docs/BALANCE_EVAL.md 表 3，对方攻击 600、倍率 100%、满血约 3085 时**原版**一下打掉多少（全段中位）。
-- family：只给这张表里**没有**的招（游戏更新后新出的招）当初值 / 兜底；改 family 不会改下面已经列出的招。
-- 重新生成 / 补新招：python -X utf8 -I tools/gen_balance.py（已有的数保留）。
-- §172 粗调（tools/balance/rough_tune.py）：普通招 DPS 300 / 远程 150；大招每格精纯杀气 2000；影武每颗暗源 1000 / 远程 500。
return {
family = { Air = 0.85, Double = 0.85, SlitheringSword = 1.2, YanYueDao = 0.5, ZhanMa = 0.5, ZiMingJian = 0.8 },
moves = {

-- ==== 黑伤双刃 · 空中（Air，3 招）
  GA_Hun_Air_Double_AAA_C = 1.42,
  GA_Hun_Air_Double_AA_C = 0.79,  -- 实测 n=7，一下约 10% 血
  GA_Hun_Air_Tang_AA_C = 0.89,

-- ==== 白影（BaiYing，22 招）
  GA_Hun_BaiYing_AAAAA_C = 0.76,
  GA_Hun_BaiYing_AAAA_C = 1.16,  -- 实测 n=1，一下约 1% 血
  GA_Hun_BaiYing_AAA_C = 0.69,
  GA_Hun_BaiYing_AA_C = 3.0,
  GA_Hun_BaiYing_A_C = 0.59,  -- 实测 n=3，一下约 25% 血
  GA_Hun_BaiYing_A_DashDraw_C = 3.0,
  GA_Hun_BaiYing_A_Dash_C = 1.18,
  GA_Hun_BaiYing_A_Snap_C = 1.0,
  GA_Hun_BaiYing_Air_A_C = 1.34,
  GA_Hun_BaiYing_Air_A_Draw_C = 1.35,
  GA_Hun_BaiYing_Air_B_C = 1.28,
  GA_Hun_BaiYing_Air_B_Draw_C = 3.0,
  GA_Hun_BaiYing_BBB_C = 0.49,  -- 实测 n=4，一下约 12% 血
  GA_Hun_BaiYing_BB_C = 0.6,  -- 实测 n=6，一下约 13% 血
  GA_Hun_BaiYing_B_C = 0.99,  -- 实测 n=12，一下约 4% 血
  GA_Hun_BaiYing_B_DashDraw_C = 0.54,
  GA_Hun_BaiYing_B_Dash_C = 0.63,
  GA_Hun_BaiYing_B_Snap_C = 1.0,
  GA_Hun_BaiYing_C_C = 0.91,  -- 实测 n=4，一下约 55% 血
  GA_Hun_BaiYing_PerfectDodge_C = 1.0,
  GA_Hun_BaiYing_SWT_Power_C = 0.5,  -- 实测 n=8，一下约 20% 血
  GA_Hun_BaiYing_SpeicalAssault_C = 0.36,  -- 实测 n=1，一下约 25% 血

-- ==== 天玄青铜剑（BronzeSword，22 招）
  GA_Hun_BronzeSword_AAAA_C = 1.16,
  GA_Hun_BronzeSword_AAABB_C = 0.49,
  GA_Hun_BronzeSword_AAAB_C = 0.65,
  GA_Hun_BronzeSword_AAA_C = 0.93,
  GA_Hun_BronzeSword_AABB_C = 0.81,
  GA_Hun_BronzeSword_AAB_C = 0.32,
  GA_Hun_BronzeSword_AA_C = 1.39,
  GA_Hun_BronzeSword_ABB_C = 0.33,
  GA_Hun_BronzeSword_AB_C = 0.86,
  GA_Hun_BronzeSword_A_C = 1.52,
  GA_Hun_BronzeSword_A_Dash_C = 2.74,
  GA_Hun_BronzeSword_A_Draw_C = 2.28,
  GA_Hun_BronzeSword_A_Snap_C = 1.0,
  GA_Hun_BronzeSword_BA_C = 0.46,
  GA_Hun_BronzeSword_BBB_C = 2.34,
  GA_Hun_BronzeSword_BB_C = 0.66,
  GA_Hun_BronzeSword_B_C = 1.37,  -- 实测 n=1，一下约 87% 血
  GA_Hun_BronzeSword_B_Dash_C = 0.82,
  GA_Hun_BronzeSword_B_Hold_C = 0.37,
  GA_Hun_BronzeSword_B_Snap_C = 1.0,
  GA_Hun_BronzeSword_C_C = 1.27,
  GA_Hun_BronzeSword_SWT_C = 1.0,  -- 实测 n=3，一下约 13% 血

-- ==== 刺骨混沌（Chaos，46 招）
  GA_Hun_Chaos_AAAAA_C = 0.99,  -- 实测 n=1，一下约 19% 血
  GA_Hun_Chaos_AAAA_C = 0.78,
  GA_Hun_Chaos_AAABB_Fire_C = 1.0,
  GA_Hun_Chaos_AAABB_Ice_C = 1.0,
  GA_Hun_Chaos_AAABB_Physics_C = 0.43,
  GA_Hun_Chaos_AAAB_Fire_C = 1.0,
  GA_Hun_Chaos_AAAB_Ice_C = 1.0,
  GA_Hun_Chaos_AAAB_Physics_C = 0.43,
  GA_Hun_Chaos_AAA_C = 0.76,  -- 实测 n=2，一下约 15% 血
  GA_Hun_Chaos_AABB_Fire_C = 1.0,
  GA_Hun_Chaos_AABB_Ice_C = 1.0,
  GA_Hun_Chaos_AABB_Physics_C = 0.81,
  GA_Hun_Chaos_AAB_Fire_C = 1.0,
  GA_Hun_Chaos_AAB_Ice_C = 1.0,
  GA_Hun_Chaos_AAB_Physics_C = 1.65,
  GA_Hun_Chaos_AA_C = 1.16,  -- 实测 n=4，一下约 12% 血
  GA_Hun_Chaos_ABB_Fire_C = 1.0,
  GA_Hun_Chaos_ABB_Ice_C = 1.0,
  GA_Hun_Chaos_ABB_Physics_C = 1.22,
  GA_Hun_Chaos_AB_Fire_C = 1.0,  -- 实测 n=1，一下约 47% 血
  GA_Hun_Chaos_AB_Ice_C = 1.0,  -- 实测 n=1，一下约 72% 血
  GA_Hun_Chaos_AB_Physics_C = 1.93,
  GA_Hun_Chaos_A_C = 1.82,  -- 实测 n=3，一下约 28% 血
  GA_Hun_Chaos_A_DashDraw_C = 0.69,
  GA_Hun_Chaos_A_Dash_C = 0.69,
  GA_Hun_Chaos_A_Draw_C = 1.21,
  GA_Hun_Chaos_BBB_Fire_C = 1.0,  -- 实测 n=1，一下约 17% 血
  GA_Hun_Chaos_BBB_Ice_C = 1.0,
  GA_Hun_Chaos_BBB_Physics_C = 0.81,  -- 实测 n=1，一下约 1% 血
  GA_Hun_Chaos_BB_Fire_C = 1.0,  -- 实测 n=1，一下约 14% 血
  GA_Hun_Chaos_BB_Ice_C = 1.0,
  GA_Hun_Chaos_BB_Physics_C = 0.39,  -- 实测 n=1，一下约 6% 血
  GA_Hun_Chaos_B_DashDraw_C = 0.56,
  GA_Hun_Chaos_B_Dash_C = 1.6,
  GA_Hun_Chaos_B_Draw_C = 0.54,
  GA_Hun_Chaos_B_Fire_C = 1.0,  -- 实测 n=5，一下约 2% 血
  GA_Hun_Chaos_B_Hold_Fire_C = 1.0,
  GA_Hun_Chaos_B_Hold_Ice_C = 1.0,  -- 实测 n=1，一下约 71% 血
  GA_Hun_Chaos_B_Hold_Physics_C = 1.09,
  GA_Hun_Chaos_B_Ice_C = 1.0,  -- 实测 n=2，一下约 46% 血
  GA_Hun_Chaos_B_Physics_C = 1.09,  -- 实测 n=2，一下约 25% 血
  GA_Hun_Chaos_C_C = 0.76,  -- 实测 n=5，一下约 15% 血
  GA_Hun_Chaos_SWT_Power_C = 1.0,
  GA_Hun_Chaos_SwitchFormFire_SWT_C = 1.0,
  GA_Hun_Chaos_SwitchFormIce_SWT_C = 1.0,
  GA_Hun_Chaos_SwitchFormPhysic_SWT_C = 0.3,  -- 实测 n=2，一下约 12% 血

-- ==== 炽刃（淬炼长形黑伤）（ChiRen，25 招）
  GA_Hun_ChiRen_AAAABB_C = 0.51,
  GA_Hun_ChiRen_AAAAB_C = 0.51,
  GA_Hun_ChiRen_AAAA_C = 1.25,  -- 实测 n=1，一下约 5% 血
  GA_Hun_ChiRen_AAABB_C = 0.93,
  GA_Hun_ChiRen_AAAB_C = 1.34,
  GA_Hun_ChiRen_AAA_C = 1.0,  -- 实测 n=3，一下约 23% 血
  GA_Hun_ChiRen_AABB_C = 0.79,
  GA_Hun_ChiRen_AAB_C = 1.19,
  GA_Hun_ChiRen_AA_C = 1.0,
  GA_Hun_ChiRen_ABB_C = 0.51,
  GA_Hun_ChiRen_AB_C = 0.7,  -- 实测 n=1，一下约 13% 血
  GA_Hun_ChiRen_A_C = 0.62,  -- 实测 n=2，一下约 24% 血
  GA_Hun_ChiRen_A_Draw_C = 1.69,
  GA_Hun_ChiRen_A_Snap_C = 1.0,
  GA_Hun_ChiRen_BBB_C = 1.07,  -- 实测 n=1，一下约 29% 血
  GA_Hun_ChiRen_BB_C = 1.15,  -- 实测 n=1，一下约 6% 血
  GA_Hun_ChiRen_BD_C = 0.3,  -- 实测 n=1，一下约 19% 血
  GA_Hun_ChiRen_BSup_C = 0.56,
  GA_Hun_ChiRen_B_C = 1.0,  -- 实测 n=1，一下约 11% 血
  GA_Hun_ChiRen_B_DashDraw_C = 0.88,
  GA_Hun_ChiRen_B_Dash_C = 0.91,
  GA_Hun_ChiRen_B_Draw_C = 1.66,
  GA_Hun_ChiRen_B_Snap_C = 1.0,
  GA_Hun_ChiRen_C_C = 0.81,  -- 实测 n=3，一下约 37% 血
  GA_Hun_ChiRen_SWT_C = 0.11,

-- ==== 痴者残剑（ChiZheCanJian，28 招）
  GA_Hun_ChiZheCanJian_A_Snap_C = 1.0,
  GA_Hun_ChiZheCanJian_B_Snap_C = 1.0,
  GA_Hun_ChiZheCanJian_C_C = 0.79,
  GA_Hun_ChiZheCanJian_C_Zui_C = 1.0,
  GA_Hun_ChiZheCanJian_Drunk_AAAAA_C = 1.0,
  GA_Hun_ChiZheCanJian_Drunk_AAAA_C = 1.0,
  GA_Hun_ChiZheCanJian_Drunk_AAA_C = 1.57,
  GA_Hun_ChiZheCanJian_Drunk_AA_C = 1.0,
  GA_Hun_ChiZheCanJian_Drunk_A_C = 2.64,
  GA_Hun_ChiZheCanJian_Drunk_A_DashChild_C = 1.32,
  GA_Hun_ChiZheCanJian_Drunk_BBB_C = 1.0,
  GA_Hun_ChiZheCanJian_Drunk_BB_C = 1.0,
  GA_Hun_ChiZheCanJian_Drunk_B_C = 1.0,
  GA_Hun_ChiZheCanJian_Normal_AAAAA_C = 2.86,
  GA_Hun_ChiZheCanJian_Normal_AAAA_C = 2.33,
  GA_Hun_ChiZheCanJian_Normal_AAA_C = 0.99,
  GA_Hun_ChiZheCanJian_Normal_AA_C = 3.0,
  GA_Hun_ChiZheCanJian_Normal_AA_DashChild_C = 0.99,
  GA_Hun_ChiZheCanJian_Normal_A_C = 3.0,  -- 实测 n=2，一下约 17% 血
  GA_Hun_ChiZheCanJian_Normal_BBB_C = 2.02,
  GA_Hun_ChiZheCanJian_Normal_BB_C = 1.12,
  GA_Hun_ChiZheCanJian_Normal_B_C = 2.71,
  GA_Hun_ChiZheCanJian_Normal_B_DashChild_C = 1.81,
  GA_Hun_ChiZheCanJian_PerfectDodge_C = 1.0,
  GA_Hun_ChiZheCanJian_SWT_C = 1.0,
  GA_Hun_ChiZheCanJian_Tipsy_BBB_C = 1.0,
  GA_Hun_ChiZheCanJian_Tipsy_BB_C = 1.0,  -- 实测 n=1，一下约 49% 血
  GA_Hun_ChiZheCanJian_Tipsy_B_C = 1.0,  -- 实测 n=2，一下约 26% 血

-- ==== 黑伤双刃（Double，41 招）
  GA_Hun_Double_AAAAAA_C = 1.2,
  GA_Hun_Double_AAAAA_C = 1.24,
  GA_Hun_Double_AAAA_C = 1.42,  -- 实测 n=41，一下约 11% 血
  GA_Hun_Double_AAABBB_C = 0.97,
  GA_Hun_Double_AAABB_C = 0.49,
  GA_Hun_Double_AAAB_C = 0.65,
  GA_Hun_Double_AAA_C = 2.51,  -- 实测 n=98，一下约 10% 血
  GA_Hun_Double_AABB_C = 0.37,
  GA_Hun_Double_AAB_C = 0.96,
  GA_Hun_Double_AA_C = 1.15,  -- 实测 n=255，一下约 24% 血
  GA_Hun_Double_ABB_C = 0.56,  -- 实测 n=1，一下约 13% 血
  GA_Hun_Double_AB_C = 0.52,  -- 实测 n=42，一下约 16% 血
  GA_Hun_Double_ATBBB_C = 0.66,  -- 实测 n=9，一下约 18% 血
  GA_Hun_Double_ATBB_C = 1.05,  -- 实测 n=8，一下约 17% 血
  GA_Hun_Double_ATB_C = 2.8,  -- 实测 n=8，一下约 32% 血
  GA_Hun_Double_A_C = 0.33,  -- 实测 n=223，一下约 23% 血
  GA_Hun_Double_A_DashDraw_Short_C = 2.16,  -- 实测 n=15，一下约 19% 血
  GA_Hun_Double_A_Dash_Short_C = 1.02,  -- 实测 n=1，一下约 8% 血
  GA_Hun_Double_A_Draw_C = 3.0,  -- 实测 n=7，一下约 23% 血
  GA_Hun_Double_A_Snap_C = 0.85,  -- 实测 n=1，一下约 30% 血
  GA_Hun_Double_Air_A_C = 1.39,  -- 实测 n=22，一下约 32% 血
  GA_Hun_Double_Air_A_Draw_C = 1.39,  -- 实测 n=13，一下约 32% 血
  GA_Hun_Double_Air_B_C = 0.43,  -- 实测 n=6，一下约 33% 血
  GA_Hun_Double_Air_B_Draw_C = 0.86,
  GA_Hun_Double_BBBB_C = 1.31,  -- 实测 n=11，一下约 39% 血
  GA_Hun_Double_BBB_C = 1.07,  -- 实测 n=9，一下约 32% 血
  GA_Hun_Double_BB_C = 0.77,  -- 实测 n=60，一下约 16% 血
  GA_Hun_Double_BTA_C = 0.7,  -- 实测 n=17，一下约 24% 血
  GA_Hun_Double_B_C = 2.15,  -- 实测 n=68，一下约 11% 血
  GA_Hun_Double_B_DashDraw_C = 0.98,  -- 实测 n=11，一下约 30% 血
  GA_Hun_Double_B_Dash_C = 1.46,  -- 实测 n=47，一下约 30% 血
  GA_Hun_Double_B_Draw_C = 1.59,  -- 实测 n=13，一下约 18% 血
  GA_Hun_Double_B_Snap_C = 0.85,
  GA_Hun_Double_C_C = 0.8,  -- 实测 n=5，一下约 45% 血
  GA_Hun_Double_JueYing_C_Air_C = 0.85,
  GA_Hun_Double_JueYing_C_C = 1.65,  -- 实测 n=11，一下约 42% 血
  GA_Hun_Double_PerfectDodge_C = 0.85,
  GA_Hun_Double_SWT_C = 0.85,  -- 实测 n=17，一下约 21% 血
  GA_Hun_Double_SWT_Tutorial2_C = 0.85,
  GA_Hun_Double_SWT_Tutorial_C = 0.85,
  GA_Hun_Double_SWT_UI_C = 0.85,

-- ==== 别离残钩（DualHook，33 招）
  GA_Hun_DualHook_AAAAA_C = 0.97,
  GA_Hun_DualHook_AAAA_C = 1.82,  -- 实测 n=1，一下约 28% 血
  GA_Hun_DualHook_AAABB_C = 0.96,
  GA_Hun_DualHook_AAAB_C = 0.66,
  GA_Hun_DualHook_AAA_C = 2.37,  -- 实测 n=2，一下约 11% 血
  GA_Hun_DualHook_AABB_C = 0.48,
  GA_Hun_DualHook_AAB_C = 1.77,
  GA_Hun_DualHook_AA_C = 1.52,  -- 实测 n=9，一下约 25% 血
  GA_Hun_DualHook_ABB_C = 1.58,
  GA_Hun_DualHook_AB_C = 0.76,
  GA_Hun_DualHook_A_C = 0.74,  -- 实测 n=13，一下约 20% 血
  GA_Hun_DualHook_A_DashDraw_C = 1.38,
  GA_Hun_DualHook_A_Dash_C = 2.14,  -- 实测 n=1，一下约 26% 血
  GA_Hun_DualHook_A_Draw_C = 0.74,
  GA_Hun_DualHook_A_Pursure_02_C = 1.21,
  GA_Hun_DualHook_A_Snap_C = 1.0,
  GA_Hun_DualHook_Air_B_C = 1.09,
  GA_Hun_DualHook_Air_B_Draw_C = 1.09,
  GA_Hun_DualHook_BBBB_C = 0.66,
  GA_Hun_DualHook_BBB_C = 1.26,  -- 实测 n=1，一下约 18% 血
  GA_Hun_DualHook_BB_C = 1.02,
  GA_Hun_DualHook_B_C = 1.5,
  GA_Hun_DualHook_B_DashDraw_C = 1.2,
  GA_Hun_DualHook_B_Dash_C = 0.8,
  GA_Hun_DualHook_B_Draw_C = 2.0,
  GA_Hun_DualHook_B_Pursure_C = 1.16,
  GA_Hun_DualHook_B_Snap_C = 1.0,
  GA_Hun_DualHook_C_C = 0.94,
  GA_Hun_DualHook_DB_C = 1.0,
  GA_Hun_DualHook_DB_SWT_C = 1.0,
  GA_Hun_DualHook_PerfectDodge_GEx_C = 1.0,
  GA_Hun_DualHook_PerfectDodge_HeavyAttack_C = 1.0,
  GA_Hun_DualHook_SWT_Power_C = 1.0,

-- ==== 白山风雷剑（FengLeiJian，31 招）
  GA_Hun_FengLeiJian_AAAA_C = 0.5,
  GA_Hun_FengLeiJian_AAABB_C = 0.59,
  GA_Hun_FengLeiJian_AAAB_C = 1.12,
  GA_Hun_FengLeiJian_AAA_C = 0.82,
  GA_Hun_FengLeiJian_AABAB_C = 0.44,
  GA_Hun_FengLeiJian_AABA_C = 1.02,
  GA_Hun_FengLeiJian_AABB_C = 0.4,
  GA_Hun_FengLeiJian_AAB_C = 0.9,
  GA_Hun_FengLeiJian_AA_C = 0.27,
  GA_Hun_FengLeiJian_AB_C = 0.85,
  GA_Hun_FengLeiJian_A_C = 0.34,
  GA_Hun_FengLeiJian_A_DashDraw_C = 2.24,
  GA_Hun_FengLeiJian_A_Dash_C = 0.53,
  GA_Hun_FengLeiJian_A_Draw_C = 3.0,
  GA_Hun_FengLeiJian_A_Snap_C = 1.0,
  GA_Hun_FengLeiJian_Air_A_C = 3.0,
  GA_Hun_FengLeiJian_Air_A_Draw_C = 3.0,
  GA_Hun_FengLeiJian_Air_B_C = 0.47,
  GA_Hun_FengLeiJian_Air_B_Draw_C = 0.23,
  GA_Hun_FengLeiJian_BBBB_C = 0.4,
  GA_Hun_FengLeiJian_BBB_C = 0.39,
  GA_Hun_FengLeiJian_BB_C = 0.63,
  GA_Hun_FengLeiJian_B_C = 1.15,
  GA_Hun_FengLeiJian_B_DashDraw_C = 1.04,
  GA_Hun_FengLeiJian_B_Dash_C = 1.52,
  GA_Hun_FengLeiJian_B_Draw_C = 1.15,
  GA_Hun_FengLeiJian_B_Hold_C = 0.64,
  GA_Hun_FengLeiJian_B_Snap_C = 1.0,
  GA_Hun_FengLeiJian_C_C = 0.82,
  GA_Hun_FengLeiJian_FengLeiState_SpecailAttack_02_C = 0.19,
  GA_Hun_FengLeiJian_SWT_Power_C = 0.21,

-- ==== 红妆鬼斩（GuiTouBlade，28 招）
  GA_Hun_GuiTouBlade_AAAA_C = 1.46,
  GA_Hun_GuiTouBlade_AAABB_C = 1.29,
  GA_Hun_GuiTouBlade_AAAB_C = 0.57,
  GA_Hun_GuiTouBlade_AAA_C = 1.78,
  GA_Hun_GuiTouBlade_AABB_C = 0.76,
  GA_Hun_GuiTouBlade_AAB_C = 1.0,
  GA_Hun_GuiTouBlade_AA_C = 1.78,
  GA_Hun_GuiTouBlade_ABB_C = 0.57,
  GA_Hun_GuiTouBlade_AB_C = 0.71,  -- 实测 n=2，一下约 45% 血
  GA_Hun_GuiTouBlade_A_C = 3.0,
  GA_Hun_GuiTouBlade_A_DashDraw_C = 0.95,
  GA_Hun_GuiTouBlade_A_Dash_C = 1.36,
  GA_Hun_GuiTouBlade_A_Draw_C = 3.0,
  GA_Hun_GuiTouBlade_A_Snap_C = 1.0,
  GA_Hun_GuiTouBlade_BBB_C = 0.75,
  GA_Hun_GuiTouBlade_BB_C = 0.71,  -- 实测 n=11，一下约 9% 血
  GA_Hun_GuiTouBlade_BB_UnCharge_C = 1.78,
  GA_Hun_GuiTouBlade_BB_UnCharge_Reinforced_C = 0.71,
  GA_Hun_GuiTouBlade_B_C = 1.69,  -- 实测 n=11，一下约 7% 血
  GA_Hun_GuiTouBlade_B_DashDraw_C = 0.51,
  GA_Hun_GuiTouBlade_B_Dash_C = 2.73,
  GA_Hun_GuiTouBlade_B_Draw_C = 1.69,
  GA_Hun_GuiTouBlade_B_Hold_C = 0.25,
  GA_Hun_GuiTouBlade_B_Hold_Start_C = 0.69,
  GA_Hun_GuiTouBlade_B_Hold_Unreinforced_C = 1.0,
  GA_Hun_GuiTouBlade_B_Snap_C = 1.0,
  GA_Hun_GuiTouBlade_C_C = 0.81,
  GA_Hun_GuiTouBlade_SWT_C = 0.69,

-- ==== 黑魔伤（淬炼黑伤）（HeiMoShang，27 招）
  GA_Hun_HeiMoShang_AAAAAA_C = 1.09,  -- 实测 n=1，一下约 38% 血
  GA_Hun_HeiMoShang_AAAAABB_C = 0.47,
  GA_Hun_HeiMoShang_AAAAAB_C = 0.52,  -- 实测 n=1，一下约 43% 血
  GA_Hun_HeiMoShang_AAAAA_C = 1.02,  -- 实测 n=1，一下约 35% 血
  GA_Hun_HeiMoShang_AAAAB_Alt_C = 0.75,
  GA_Hun_HeiMoShang_AAAA_C = 1.29,  -- 实测 n=2，一下约 53% 血
  GA_Hun_HeiMoShang_AAABB_C = 2.1,
  GA_Hun_HeiMoShang_AAAB_C = 0.68,  -- 实测 n=1，一下约 16% 血
  GA_Hun_HeiMoShang_AAA_C = 2.14,  -- 实测 n=5，一下约 12% 血
  GA_Hun_HeiMoShang_AABB_C = 0.39,  -- 实测 n=1，一下约 12% 血
  GA_Hun_HeiMoShang_AAB_C = 0.3,  -- 实测 n=2，一下约 15% 血
  GA_Hun_HeiMoShang_AA_C = 1.19,  -- 实测 n=6，一下约 16% 血
  GA_Hun_HeiMoShang_ABB_C = 0.66,  -- 实测 n=1，一下约 66% 血
  GA_Hun_HeiMoShang_AB_C = 0.97,  -- 实测 n=9，一下约 18% 血
  GA_Hun_HeiMoShang_A_C = 1.49,  -- 实测 n=9，一下约 22% 血
  GA_Hun_HeiMoShang_A_DashDraw_C = 1.29,
  GA_Hun_HeiMoShang_A_Dash_C = 0.86,  -- 实测 n=4，一下约 25% 血
  GA_Hun_HeiMoShang_A_Draw_C = 0.99,
  GA_Hun_HeiMoShang_BBBB_C = 0.49,  -- 实测 n=4，一下约 30% 血
  GA_Hun_HeiMoShang_BBB_C = 0.98,  -- 实测 n=7，一下约 21% 血
  GA_Hun_HeiMoShang_BB_C = 0.55,  -- 实测 n=11，一下约 20% 血
  GA_Hun_HeiMoShang_B_C = 0.64,  -- 实测 n=15，一下约 7% 血
  GA_Hun_HeiMoShang_B_DashDraw_C = 0.44,
  GA_Hun_HeiMoShang_B_Dash_C = 0.27,  -- 实测 n=1，一下约 14% 血
  GA_Hun_HeiMoShang_B_Draw_C = 0.73,
  GA_Hun_HeiMoShang_C1_C = 0.3,  -- 实测 n=1，一下约 113% 血
  GA_Hun_HeiMoShang_SWT_C = 0.45,  -- 实测 n=4，一下约 77% 血

-- ==== 荡寇凶刃（Horizontal，24 招）
  GA_Hun_Horizontal_AAAA_C = 0.57,
  GA_Hun_Horizontal_AAAB_C = 0.51,
  GA_Hun_Horizontal_AAA_C = 1.0,
  GA_Hun_Horizontal_AAB_C = 0.55,
  GA_Hun_Horizontal_AA_C = 0.67,
  GA_Hun_Horizontal_AB_C = 0.57,
  GA_Hun_Horizontal_A_C = 1.0,
  GA_Hun_Horizontal_A_DashDraw_C = 0.94,
  GA_Hun_Horizontal_A_Dash_C = 1.0,
  GA_Hun_Horizontal_A_Draw_C = 1.01,
  GA_Hun_Horizontal_A_Snap_C = 1.0,
  GA_Hun_Horizontal_BB_C = 1.0,
  GA_Hun_Horizontal_B_C = 0.94,
  GA_Hun_Horizontal_B_DashDraw_C = 0.45,
  GA_Hun_Horizontal_B_Dash_C = 0.63,
  GA_Hun_Horizontal_B_Draw_C = 0.94,
  GA_Hun_Horizontal_B_NoCost_C = 0.62,
  GA_Hun_Horizontal_B_Snap_C = 1.0,
  GA_Hun_Horizontal_BladeWave_C = 1.0,
  GA_Hun_Horizontal_C_C = 1.02,
  GA_Hun_Horizontal_CounterAttackBase_C = 1.0,
  GA_Hun_Horizontal_CounterAttack_01_C = 0.4,
  GA_Hun_Horizontal_CounterAttack_02_C = 0.62,
  GA_Hun_Horizontal_SWT_Power_C = 1.0,

-- ==== 残钢刃（Iron，27 招）
  GA_Hun_Iron_AAAAA_C = 1.08,
  GA_Hun_Iron_AAAA_C = 1.8,  -- 实测 n=1，一下约 14% 血
  GA_Hun_Iron_AAABB_C = 0.66,
  GA_Hun_Iron_AAAB_C = 0.75,
  GA_Hun_Iron_AAA_C = 1.88,
  GA_Hun_Iron_AABB_C = 0.49,
  GA_Hun_Iron_AAB_C = 0.62,  -- 实测 n=2，一下约 24% 血
  GA_Hun_Iron_AA_C = 2.88,  -- 实测 n=4，一下约 18% 血
  GA_Hun_Iron_ABB_C = 0.49,
  GA_Hun_Iron_AB_C = 1.23,  -- 实测 n=1，一下约 35% 血
  GA_Hun_Iron_A_C = 0.8,
  GA_Hun_Iron_A_DashDraw_C = 1.03,
  GA_Hun_Iron_A_Dash_C = 1.03,  -- 实测 n=2，一下约 5% 血
  GA_Hun_Iron_A_Draw_C = 0.67,
  GA_Hun_Iron_A_Snap_C = 1.0,
  GA_Hun_Iron_BBB_C = 0.99,
  GA_Hun_Iron_BB_C = 0.98,  -- 实测 n=3，一下约 9% 血
  GA_Hun_Iron_BChargeAttack_C = 3.0,
  GA_Hun_Iron_BCharge_C = 1.0,
  GA_Hun_Iron_B_C = 1.19,  -- 实测 n=5，一下约 21% 血
  GA_Hun_Iron_B_DashDraw_C = 0.52,
  GA_Hun_Iron_B_Dash_C = 0.93,
  GA_Hun_Iron_B_Draw_C = 2.53,
  GA_Hun_Iron_B_Snap_C = 1.0,
  GA_Hun_Iron_BreakAct_02_C = 1.0,
  GA_Hun_Iron_C_C = 1.33,  -- 实测 n=1，一下约 216% 血
  GA_Hun_Iron_SWT_C = 1.0,  -- 实测 n=1，一下约 6% 血

-- ==== 玉双环（Jade，28 招）
  GA_Hun_Jade_AAAAAA_C = 1.51,
  GA_Hun_Jade_AAAAA_C = 1.28,
  GA_Hun_Jade_AAAA_C = 1.21,
  GA_Hun_Jade_AAABB_C = 0.91,
  GA_Hun_Jade_AAAB_C = 0.25,  -- 实测 n=1，一下约 21% 血
  GA_Hun_Jade_AAA_C = 1.93,  -- 实测 n=2，一下约 12% 血
  GA_Hun_Jade_AABB_C = 0.28,
  GA_Hun_Jade_AAB_C = 0.18,
  GA_Hun_Jade_AA_C = 1.02,  -- 实测 n=2，一下约 10% 血
  GA_Hun_Jade_ABB_C = 1.08,
  GA_Hun_Jade_AB_C = 0.62,  -- 实测 n=2，一下约 29% 血
  GA_Hun_Jade_A_C = 1.02,  -- 实测 n=3，一下约 24% 血
  GA_Hun_Jade_A_DashDraw_C = 1.62,
  GA_Hun_Jade_A_Dash_C = 1.71,
  GA_Hun_Jade_A_Draw_C = 0.74,
  GA_Hun_Jade_A_Snap_C = 1.0,
  GA_Hun_Jade_BBBB_C = 0.18,  -- 实测 n=3，一下约 22% 血
  GA_Hun_Jade_BBB_C = 1.33,  -- 实测 n=3，一下约 6% 血
  GA_Hun_Jade_BB_C = 1.36,  -- 实测 n=6，一下约 18% 血
  GA_Hun_Jade_B_C = 2.41,  -- 实测 n=5，一下约 8% 血
  GA_Hun_Jade_B_DashDraw_C = 1.2,
  GA_Hun_Jade_B_Dash_C = 0.51,
  GA_Hun_Jade_B_Draw_C = 1.38,
  GA_Hun_Jade_B_Snap_C = 1.0,
  GA_Hun_Jade_C_Range_C = 1.34,
  GA_Hun_Jade_DB_C = 0.4,
  GA_Hun_Jade_PerfectDodge_C = 1.0,
  GA_Hun_Jade_SWT_C = 1.0,  -- 实测 n=1，一下约 35% 血

-- ==== 断肢锯（另一套名字）（JigSaw，4 招）
  GA_Hun_JigSaw_AAAA_C = 1.01,
  GA_Hun_JigSaw_AAA_C = 0.88,
  GA_Hun_JigSaw_AA_C = 0.88,
  GA_Hun_JigSaw_A_C = 1.29,

-- ==== 断肢锯（Jigsaw，27 招）
  GA_Hun_Jigsaw_AAAB_C = 0.42,
  GA_Hun_Jigsaw_AAB_C = 1.25,
  GA_Hun_Jigsaw_AB_C = 0.87,
  GA_Hun_Jigsaw_A_DashDraw_C = 0.82,
  GA_Hun_Jigsaw_A_Dash_C = 0.82,
  GA_Hun_Jigsaw_A_Draw_C = 1.29,
  GA_Hun_Jigsaw_A_Snap_C = 1.0,
  GA_Hun_Jigsaw_Air_A_C = 1.5,
  GA_Hun_Jigsaw_Air_A_Draw_C = 1.0,
  GA_Hun_Jigsaw_Air_B_C = 1.39,
  GA_Hun_Jigsaw_Air_B_Draw_C = 1.39,
  GA_Hun_Jigsaw_BB_C = 1.25,
  GA_Hun_Jigsaw_B_C = 1.1,
  GA_Hun_Jigsaw_B_DashDraw_C = 1.8,
  GA_Hun_Jigsaw_B_Dash_C = 1.0,
  GA_Hun_Jigsaw_B_Snap_C = 1.0,
  GA_Hun_Jigsaw_BreakAct_C = 1.0,
  GA_Hun_Jigsaw_C_C = 0.5,
  GA_Hun_Jigsaw_PerfectDodge_C = 1.0,
  GA_Hun_Jigsaw_RAAA_C = 1.6,
  GA_Hun_Jigsaw_RAA_C = 1.13,
  GA_Hun_Jigsaw_RA_C = 2.75,
  GA_Hun_Jigsaw_RBB_C = 1.48,
  GA_Hun_Jigsaw_RB_C = 1.21,
  GA_Hun_Jigsaw_SA_C = 2.28,
  GA_Hun_Jigsaw_SB_C = 2.33,
  GA_Hun_Jigsaw_SWT_Power_C = 1.0,

-- ==== 长形黑伤（Long，35 招）
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
  GA_Hun_Long_Air_A_C = 1.19,
  GA_Hun_Long_Air_A_Draw_C = 1.04,
  GA_Hun_Long_Air_B_C = 2.53,
  GA_Hun_Long_Air_B_Draw_C = 2.53,
  GA_Hun_Long_Air_SWT_C = 1.0,
  GA_Hun_Long_BBB_New_C = 1.0,
  GA_Hun_Long_BB_C = 1.0,
  GA_Hun_Long_BCharge_C = 1.0,
  GA_Hun_Long_BD_C = 1.0,
  GA_Hun_Long_BSup_C = 1.0,
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
  GA_Hun_LuanYing_AAAAA_C = 1.53,
  GA_Hun_LuanYing_AAAA_C = 0.89,
  GA_Hun_LuanYing_AAAB_C = 1.0,
  GA_Hun_LuanYing_AAA_C = 1.88,
  GA_Hun_LuanYing_AAB_C = 1.0,
  GA_Hun_LuanYing_AA_C = 0.63,
  GA_Hun_LuanYing_AB_C = 1.0,
  GA_Hun_LuanYing_A_C = 0.68,  -- 实测 n=2，一下约 18% 血
  GA_Hun_LuanYing_A_DashDraw_C = 3.0,
  GA_Hun_LuanYing_BBB_C = 1.0,
  GA_Hun_LuanYing_BB_C = 1.0,
  GA_Hun_LuanYing_B_C = 1.0,
  GA_Hun_LuanYing_B_Draw_C = 1.0,
  GA_Hun_LuanYing_CA_C = 1.0,
  GA_Hun_LuanYing_DashA_C = 1.03,
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

-- ==== 破军（PoJun，24 招）
  GA_Hun_PoJun_AAAA_C = 1.14,
  GA_Hun_PoJun_AAAB_C = 1.51,
  GA_Hun_PoJun_AAA_C = 1.0,
  GA_Hun_PoJun_AAB_C = 0.65,
  GA_Hun_PoJun_AA_C = 0.99,
  GA_Hun_PoJun_AB_C = 0.51,
  GA_Hun_PoJun_A_C = 1.0,
  GA_Hun_PoJun_A_DashDraw_C = 0.94,
  GA_Hun_PoJun_A_Dash_C = 0.62,
  GA_Hun_PoJun_A_Draw_C = 1.01,
  GA_Hun_PoJun_A_Snap_C = 1.0,
  GA_Hun_PoJun_BB_C = 1.0,
  GA_Hun_PoJun_B_C = 0.94,
  GA_Hun_PoJun_B_DashDraw_C = 0.63,
  GA_Hun_PoJun_B_Dash_C = 0.63,
  GA_Hun_PoJun_B_Draw_C = 0.94,
  GA_Hun_PoJun_B_Snap_C = 1.0,
  GA_Hun_PoJun_C_C = 0.85,
  GA_Hun_PoJun_DB_02_C = 1.12,  -- 实测 n=1，一下约 109% 血
  GA_Hun_PoJun_DB_C = 1.39,
  GA_Hun_PoJun_PerfectDodge_C = 1.0,
  GA_Hun_PoJun_SWT_02_C = 1.0,
  GA_Hun_PoJun_SWT_C = 1.0,
  GA_Hun_PoJun_SWT_Super_C = 1.0,

-- ==== 天煞双钺（ShuangYue，31 招）
  GA_Hun_ShuangYue_AAAAAA_C = 2.4,
  GA_Hun_ShuangYue_AAAAA_C = 1.38,
  GA_Hun_ShuangYue_AAAA_C = 0.84,
  GA_Hun_ShuangYue_AAABB_C = 1.14,
  GA_Hun_ShuangYue_AAAB_C = 0.66,
  GA_Hun_ShuangYue_AAA_C = 0.88,
  GA_Hun_ShuangYue_AABB_C = 1.61,
  GA_Hun_ShuangYue_AAB_C = 0.51,
  GA_Hun_ShuangYue_AA_C = 1.26,
  GA_Hun_ShuangYue_ABB_C = 0.86,
  GA_Hun_ShuangYue_AB_C = 0.65,
  GA_Hun_ShuangYue_A_C = 0.34,
  GA_Hun_ShuangYue_A_DashDraw_C = 1.15,
  GA_Hun_ShuangYue_A_Dash_C = 0.57,
  GA_Hun_ShuangYue_A_Draw_C = 0.68,
  GA_Hun_ShuangYue_A_Snap_C = 1.0,
  GA_Hun_ShuangYue_BBBB_C = 1.33,
  GA_Hun_ShuangYue_BBB_C = 0.78,
  GA_Hun_ShuangYue_BB_C = 1.3,
  GA_Hun_ShuangYue_B_C = 0.72,
  GA_Hun_ShuangYue_B_DashDraw_C = 2.03,
  GA_Hun_ShuangYue_B_Dash_C = 0.68,
  GA_Hun_ShuangYue_B_Draw_C = 0.88,
  GA_Hun_ShuangYue_B_Snap_C = 1.0,
  GA_Hun_ShuangYue_C_C = 0.32,
  GA_Hun_ShuangYue_DB_C = 1.9,
  GA_Hun_ShuangYue_DB_SWT_C = 0.47,
  GA_Hun_ShuangYue_PBB_C = 0.89,
  GA_Hun_ShuangYue_PB_C = 0.94,
  GA_Hun_ShuangYue_PerfectDodge_C = 1.0,
  GA_Hun_ShuangYue_SWT_C = 1.0,

-- ==== 灵蛇软剑（SlitheringSword，28 招）
  GA_Hun_SlitheringSword_AAAAA_C = 1.04,  -- 实测 n=3，一下约 5% 血
  GA_Hun_SlitheringSword_AAAA_C = 1.21,  -- 实测 n=5，一下约 5% 血
  GA_Hun_SlitheringSword_AAABB_C = 0.42,
  GA_Hun_SlitheringSword_AAAB_C = 1.2,  -- 实测 n=1，一下约 2% 血
  GA_Hun_SlitheringSword_AAA_C = 0.91,  -- 实测 n=7，一下约 5% 血
  GA_Hun_SlitheringSword_AABB_C = 1.69,
  GA_Hun_SlitheringSword_AAB_C = 0.57,
  GA_Hun_SlitheringSword_AA_C = 0.71,  -- 实测 n=2，一下约 25% 血
  GA_Hun_SlitheringSword_ABB_C = 1.1,  -- 实测 n=1，一下约 27% 血
  GA_Hun_SlitheringSword_AB_C = 1.08,
  GA_Hun_SlitheringSword_A_C = 0.67,  -- 实测 n=10，一下约 18% 血
  GA_Hun_SlitheringSword_A_DashDraw_C = 2.18,
  GA_Hun_SlitheringSword_A_Dash_C = 1.63,  -- 实测 n=2，一下约 26% 血
  GA_Hun_SlitheringSword_A_Snap_C = 1.2,
  GA_Hun_SlitheringSword_BBB_C = 0.82,  -- 实测 n=3，一下约 18% 血
  GA_Hun_SlitheringSword_BB_C = 2.52,  -- 实测 n=7，一下约 5% 血
  GA_Hun_SlitheringSword_B_C = 1.61,  -- 实测 n=3，一下约 5% 血
  GA_Hun_SlitheringSword_B_DashDraw_C = 1.34,
  GA_Hun_SlitheringSword_B_Dash_C = 1.78,
  GA_Hun_SlitheringSword_B_Snap_C = 1.2,
  GA_Hun_SlitheringSword_C_C = 1.12,  -- 实测 n=2，一下约 138% 血
  GA_Hun_SlitheringSword_DA_C = 1.2,
  GA_Hun_SlitheringSword_DB4_C = 0.45,  -- 实测 n=1，一下约 32% 血
  GA_Hun_SlitheringSword_DB5_C = 0.45,
  GA_Hun_SlitheringSword_EvalutionCombo_New_C = 1.26,
  GA_Hun_SlitheringSword_PerfectDodge_C = 1.2,
  GA_Hun_SlitheringSword_Potential_C = 1.71,  -- 实测 n=1，一下约 32% 血
  GA_Hun_SlitheringSword_SWT_C = 1.2,

-- ==== 白蟒赤练（SnakeDual，55 招）
  GA_Hun_SnakeDual_AAA_C = 0.99,
  GA_Hun_SnakeDual_AA_C = 0.66,
  GA_Hun_SnakeDual_ABAA_C = 1.41,
  GA_Hun_SnakeDual_ABABAA_C = 2.3,
  GA_Hun_SnakeDual_ABABA_C = 3.0,
  GA_Hun_SnakeDual_ABABB_C = 0.84,
  GA_Hun_SnakeDual_ABAB_C = 2.36,
  GA_Hun_SnakeDual_ABA_C = 1.64,
  GA_Hun_SnakeDual_ABB_C = 0.52,
  GA_Hun_SnakeDual_AB_C = 0.74,
  GA_Hun_SnakeDual_A_C = 1.23,
  GA_Hun_SnakeDual_A_Dash_C = 2.85,
  GA_Hun_SnakeDual_A_Fast_C = 1.51,
  GA_Hun_SnakeDual_A_Snap_C = 1.0,
  GA_Hun_SnakeDual_Air_A_Double_C = 2.27,
  GA_Hun_SnakeDual_Air_A_Draw_Double_C = 2.27,
  GA_Hun_SnakeDual_Air_A_Draw_Tang_C = 1.0,
  GA_Hun_SnakeDual_Air_A_Tang_C = 1.0,
  GA_Hun_SnakeDual_Air_B_Double_C = 1.37,
  GA_Hun_SnakeDual_Air_B_Draw_Double_C = 1.37,
  GA_Hun_SnakeDual_Air_B_Draw_Tang_C = 1.0,
  GA_Hun_SnakeDual_Air_B_Tang_C = 1.0,
  GA_Hun_SnakeDual_BAA_C = 1.31,
  GA_Hun_SnakeDual_BABAA_C = 3.0,
  GA_Hun_SnakeDual_BABABB_C = 0.77,
  GA_Hun_SnakeDual_BABAB_C = 0.94,
  GA_Hun_SnakeDual_BABA_C = 0.97,
  GA_Hun_SnakeDual_BABB_C = 1.35,
  GA_Hun_SnakeDual_BAB_C = 0.77,
  GA_Hun_SnakeDual_BA_C = 0.99,
  GA_Hun_SnakeDual_BB_C = 0.74,
  GA_Hun_SnakeDual_B_C = 1.81,
  GA_Hun_SnakeDual_B_Dash_C = 0.97,
  GA_Hun_SnakeDual_B_Fast_C = 0.62,
  GA_Hun_SnakeDual_B_Snap_C = 1.0,
  GA_Hun_SnakeDual_C_C = 0.72,
  GA_Hun_SnakeDual_DA_C = 0.52,
  GA_Hun_SnakeDual_DB_C = 0.25,
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
  GA_Hun_Tang_Air_A_C = 1.5,
  GA_Hun_Tang_Air_A_Draw_C = 1.0,
  GA_Hun_Tang_Air_B_C = 1.39,
  GA_Hun_Tang_Air_B_Draw_C = 1.37,
  GA_Hun_Tang_Air_SWT_C = 1.0,
  GA_Hun_Tang_BBBB_C = 1.0,
  GA_Hun_Tang_BBB_C = 1.0,
  GA_Hun_Tang_BB_C = 1.0,
  GA_Hun_Tang_B_C = 1.0,
  GA_Hun_Tang_B_DashDraw_C = 1.9,
  GA_Hun_Tang_B_Dash_C = 1.0,
  GA_Hun_Tang_B_Draw_C = 2.31,
  GA_Hun_Tang_B_Snap_C = 1.0,
  GA_Hun_Tang_C_C = 1.0,
  GA_Hun_Tang_PerfectDodge_C = 0.45,  -- 实测 n=3，一下约 68% 血
  GA_Hun_Tang_SWT_C = 1.0,
  GA_Hun_Tang_SWT_Dash_C = 1.0,
  GA_Hun_Tang_SWT_UI_C = 0.78,

-- ==== 圣母邪扇（XieShan，25 招）
  GA_Hun_XieShan_AAAAA_C = 1.42,  -- 实测 n=1，一下约 8% 血
  GA_Hun_XieShan_AAAA_C = 2.16,  -- 实测 n=1，一下约 42% 血
  GA_Hun_XieShan_AAABB_C = 0.43,
  GA_Hun_XieShan_AAAB_C = 3.0,
  GA_Hun_XieShan_AAA_C = 0.41,  -- 实测 n=3，一下约 2% 血
  GA_Hun_XieShan_AABB_C = 1.63,
  GA_Hun_XieShan_AAB_C = 0.42,
  GA_Hun_XieShan_AA_C = 1.08,  -- 实测 n=2，一下约 3% 血
  GA_Hun_XieShan_ABB_C = 0.66,  -- 实测 n=1，一下约 5% 血
  GA_Hun_XieShan_AB_C = 3.0,  -- 实测 n=1，一下约 48% 血
  GA_Hun_XieShan_A_C = 0.66,  -- 实测 n=4，一下约 28% 血
  GA_Hun_XieShan_A_DashDraw_New_C = 0.99,
  GA_Hun_XieShan_A_Dash_C = 1.06,  -- 实测 n=1，一下约 3% 血
  GA_Hun_XieShan_A_Draw_New_C = 0.99,
  GA_Hun_XieShan_A_Snap_C = 1.0,
  GA_Hun_XieShan_BBB_C = 1.65,  -- 实测 n=1，一下约 16% 血
  GA_Hun_XieShan_BB_C = 0.57,  -- 实测 n=7，一下约 12% 血
  GA_Hun_XieShan_B_C = 0.46,  -- 实测 n=7，一下约 12% 血
  GA_Hun_XieShan_B_DashDraw_New_C = 0.75,
  GA_Hun_XieShan_B_Dash_C = 0.65,
  GA_Hun_XieShan_B_Draw_New_C = 0.74,
  GA_Hun_XieShan_B_Snap_C = 1.0,
  GA_Hun_XieShan_C_C = 0.86,  -- 实测 n=5，一下约 120% 血
  GA_Hun_XieShan_DB_C = 0.88,  -- 实测 n=1，一下约 8% 血
  GA_Hun_XieShan_SWT_02_C = 1.0,  -- 实测 n=3，一下约 17% 血

-- ==== 偃月刀（YanYueDao，15 招）
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
  GA_Hun_YanYueDao_SpecialSkill_C = 0.39,

-- ==== 妖锯（YuuBlade，25 招）
  GA_Hun_YuuBlade_AAAAA_C = 2.36,  -- 实测 n=4，一下约 38% 血
  GA_Hun_YuuBlade_AAAAB_C = 0.64,
  GA_Hun_YuuBlade_AAAA_C = 1.32,  -- 实测 n=5，一下约 16% 血
  GA_Hun_YuuBlade_AAAB_C = 0.44,
  GA_Hun_YuuBlade_AAA_C = 1.49,  -- 实测 n=2，一下约 15% 血
  GA_Hun_YuuBlade_AAB_C = 0.53,
  GA_Hun_YuuBlade_AA_C = 0.59,  -- 实测 n=3，一下约 10% 血
  GA_Hun_YuuBlade_AB_C = 1.52,  -- 实测 n=2，一下约 18% 血
  GA_Hun_YuuBlade_A_C = 0.74,  -- 实测 n=1，一下约 6% 血
  GA_Hun_YuuBlade_A_DashDraw_C = 0.57,
  GA_Hun_YuuBlade_A_Dash_C = 0.78,
  GA_Hun_YuuBlade_A_Draw_C = 2.71,
  GA_Hun_YuuBlade_A_Snap_C = 1.0,
  GA_Hun_YuuBlade_BBBB_C = 0.8,  -- 实测 n=1，一下约 4% 血
  GA_Hun_YuuBlade_BBB_C = 0.67,  -- 实测 n=4，一下约 9% 血
  GA_Hun_YuuBlade_BB_C = 0.3,  -- 实测 n=2，一下约 34% 血
  GA_Hun_YuuBlade_B_C = 1.38,  -- 实测 n=2，一下约 8% 血
  GA_Hun_YuuBlade_B_DashDraw_C = 0.8,
  GA_Hun_YuuBlade_B_Dash_C = 0.8,
  GA_Hun_YuuBlade_B_Draw_C = 0.57,
  GA_Hun_YuuBlade_B_Snap_C = 1.0,
  GA_Hun_YuuBlade_C_C = 1.0,
  GA_Hun_YuuBlade_FastHeavyAttack_C = 0.61,
  GA_Hun_YuuBlade_FastLightAttack_C = 0.56,
  GA_Hun_YuuBlade_SWT_C = 1.0,  -- 实测 n=4，一下约 8% 血

-- ==== 亡命斩马刀（ZhanMa，26 招）
  GA_Hun_ZhanMa_AAAA_C = 1.59,
  GA_Hun_ZhanMa_AAAB_C = 2.03,
  GA_Hun_ZhanMa_AAA_C = 1.62,
  GA_Hun_ZhanMa_AAB_C = 0.55,
  GA_Hun_ZhanMa_AA_C = 0.5,  -- 实测 n=2，一下约 22% 血
  GA_Hun_ZhanMa_AB_C = 0.86,  -- 实测 n=1，一下约 42% 血
  GA_Hun_ZhanMa_A_C = 0.56,  -- 实测 n=7，一下约 84% 血
  GA_Hun_ZhanMa_A_DashDraw_C = 1.16,
  GA_Hun_ZhanMa_A_Dash_C = 1.2,
  GA_Hun_ZhanMa_A_Draw_C = 1.05,
  GA_Hun_ZhanMa_A_Snap_C = 0.5,
  GA_Hun_ZhanMa_Air_A_C = 2.82,
  GA_Hun_ZhanMa_Air_A_Draw_C = 2.82,
  GA_Hun_ZhanMa_Air_B_C = 2.53,
  GA_Hun_ZhanMa_Air_B_Draw_C = 1.98,
  GA_Hun_ZhanMa_BB_C = 0.34,  -- 实测 n=1，一下约 39% 血
  GA_Hun_ZhanMa_B_C = 0.67,
  GA_Hun_ZhanMa_B_DashDraw_C = 1.81,
  GA_Hun_ZhanMa_B_Dash_C = 0.4,
  GA_Hun_ZhanMa_B_Draw_C = 0.89,
  GA_Hun_ZhanMa_B_Snap_C = 0.5,
  GA_Hun_ZhanMa_C_C = 0.65,
  GA_Hun_ZhanMa_DB_C = 1.08,  -- 实测 n=2，一下约 118% 血
  GA_Hun_ZhanMa_PerfectDodge_C = 0.5,
  GA_Hun_ZhanMa_SA_C = 1.14,  -- 实测 n=1，一下约 26% 血
  GA_Hun_ZhanMa_SWT_C = 0.25,

-- ==== 紫冥剑（ZiMingJian，29 招）
  GA_Hun_ZiMingJian_New_AAAAA_C = 1.16,  -- 实测 n=1，一下约 135% 血
  GA_Hun_ZiMingJian_New_AAAA_C = 1.16,  -- 实测 n=1，一下约 18% 血
  GA_Hun_ZiMingJian_New_AAABB_C = 0.49,
  GA_Hun_ZiMingJian_New_AAAB_C = 0.75,  -- 实测 n=1，一下约 42% 血
  GA_Hun_ZiMingJian_New_AAA_C = 1.66,  -- 实测 n=2，一下约 27% 血
  GA_Hun_ZiMingJian_New_AABB_C = 0.65,
  GA_Hun_ZiMingJian_New_AAB_C = 1.69,
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
  GA_Hun_ZiMingJian_New_DB_C = 0.8,
  GA_Hun_ZiMingJian_New_PerfectDodge_C = 0.8,
  GA_Hun_ZiMingJian_New_SWT_C = 0.8,
  GA_Hun_ZiMingJian_New_SWT_Power_C = 0.6,  -- 实测 n=8，一下约 42% 血

-- ==== 通用完美闪避反击（对特定敌人招）（PerfectDodge，2 招）
  GA_Hun_PerfectDodge_FireBallCounter_C = 1.0,
  GA_Hun_PerfectDodge_ThunderCounter_C = 1.0,

-- ==== 木制黑伤（序章）（WoodenSword，28 招）
  GA_Hun_WoodenSword_AAAAA_C = 0.87,
  GA_Hun_WoodenSword_AAAA_C = 2.18,
  GA_Hun_WoodenSword_AAABB_C = 1.5,
  GA_Hun_WoodenSword_AAAB_C = 3.0,
  GA_Hun_WoodenSword_AAA_C = 0.96,
  GA_Hun_WoodenSword_AABB_C = 0.83,
  GA_Hun_WoodenSword_AAB_C = 1.55,
  GA_Hun_WoodenSword_AA_C = 0.48,
  GA_Hun_WoodenSword_ABB_C = 2.63,
  GA_Hun_WoodenSword_AB_C = 1.29,
  GA_Hun_WoodenSword_A_C = 1.2,
  GA_Hun_WoodenSword_A_DashDraw_C = 0.92,
  GA_Hun_WoodenSword_A_Dash_C = 1.39,
  GA_Hun_WoodenSword_A_Draw_C = 1.2,
  GA_Hun_WoodenSword_A_Snap_C = 1.0,
  GA_Hun_WoodenSword_Air_A_C = 0.96,
  GA_Hun_WoodenSword_Air_A_Draw_C = 0.66,
  GA_Hun_WoodenSword_Air_B_C = 0.92,
  GA_Hun_WoodenSword_Air_B_Draw_C = 1.39,
  GA_Hun_WoodenSword_BBB_C = 0.34,
  GA_Hun_WoodenSword_BB_C = 2.27,
  GA_Hun_WoodenSword_B_C = 1.39,
  GA_Hun_WoodenSword_B_DashDraw_C = 3.0,
  GA_Hun_WoodenSword_B_Dash_C = 1.42,
  GA_Hun_WoodenSword_B_Draw_C = 1.39,
  GA_Hun_WoodenSword_B_Snap_C = 1.0,
  GA_Hun_WoodenSword_C_C = 1.12,
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
  GA_Hun_ShachiHook_CAA_C = 0.13,
  GA_Hun_ShachiHook_CA_C = 0.13,
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
  GA_XueDiZi_AA_C = 0.12,
  GA_XueDiZi_A_C = 0.12,
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
