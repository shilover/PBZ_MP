-- base_fixplay.lua —— 从 main.lua 搬出来的 §100 替身放招成功却没换动作（docs/MAIN_SLIM.md）。原来在 main.lua 的 "-- ===… §100 替身放招成功却没换动作" 那段
return function(ctx)
local NET, RECM, G = ctx.NET, ctx.RECM, ctx.G
local valid, cutMontage = G.valid, G.cutMontage
local isAttackAbility, playNamed = ctx.isAttackAbility, ctx.playNamed
-- main.lua 主循环那段会把 out / activeAbilities 换成计时包装（PROF.wrap），这几个由 ctx 传"调用时再取"的包装，
-- 和搬出来之前一样走计时（docs/MAIN_SLIM.md 规矩 3）
local out, activeAbilities = ctx.out, ctx.activeAbilities

-- ============================================================ §100 替身放招成功却没换动作（v0.27.20）
-- 2026-11-05 22:31–22:32 实战（对方白影 / 混沌剑）：对方从 BB 接白影 C、火形 B / BBB 时，替身 TryActivateAbilityByClass 返回 true，
-- 技能照自己的时间表出伤害（白影 C 3.8 秒里 −955、−1546，第二次直接把人打倒），替身身上却还是 BB 的动作或者空着——
-- 玩家看到"对方没出招，我一直挨打"。白影 C 7 次里 3 次、火形 BBB 15 次里 11 次这样，前一个动作都是 BB。
-- §65 的"上一招没收先停掉"只在放不出时走，这里放得出，所以没管到。
-- 做法：放成功 CHECK 秒后看替身的动作——
--   换上了新动作（名字变了，或同名但刚从头播）→ 记下"招 → 动作"
--   没换、这招还挂着、而且知道这招该播什么 → ① 停掉旧动作、取消挂着的招，重放一次；② 再过 CHECK 秒还没新动作 → 直接播那个动作
--   不知道这招该播什么的不碰（有的招本来就没有动作），只记一行
-- "招 → 动作"从替身放成功的招、本机玩家自己放的招里学；SEED 是 2026-11-05 日志里玩家自己放出来的（一一对应）
ANIM = { CHECK = 0.15, FRESH = 0.4, SWT_CHECK = 0.45, SWT_MAX = 1.6, LOGS = 30, logs = 0, map = {}, unknown = {},
         st = { ok = 0, stuck = 0, retryOk = 0, playOk = 0, fail = 0, ended = 0 } }
-- §345 断肢锯冲刺攻击（A_Dash / B_Dash / *_DashDraw）起手慢：11-16 实战 A_Dash 29 次里 25 次 0.16 秒还读不到动作，
--   按"没换动作"取消重放，重放那下从替身当时的位置重新突进，25 次里 23 次落空（没重放的 4 次中 2）。
--   和切刀斩一样按 gentle 处理：技能还挂着就不取消、不重放，等动作自己出来。
ANIM.GENTLE = { "^GA_Hun_Jigsaw_[AB]_Dash_C$", "^GA_Hun_Jigsaw_[AB]_DashDraw_C$" }
function ANIM.isGentle(n)
    if n:find("_SWT", 1, true) then return true end      -- §243 切刀斩：不取消真技能
    for _, p in ipairs(ANIM.GENTLE) do if n:find(p) then return true end end
    return false
end
ANIM.SEED = {
    GA_Hun_BaiYing_A_C = "Hun_BaiYing_A_Montage", GA_Hun_BaiYing_AA_C = "Hun_BaiYing_AA_Montage",
    GA_Hun_BaiYing_AAA_C = "Hun_BaiYing_AAA_Montage", GA_Hun_BaiYing_AAAA_C = "Hun_BaiYing_AAAA_Montage",
    GA_Hun_BaiYing_AAAAA_C = "Hun_BaiYing_AAAAA_Montage", GA_Hun_BaiYing_B_C = "Hun_BaiYing_B_Montage",
    GA_Hun_BaiYing_BB_C = "Hun_BaiYing_BB_Montage", GA_Hun_BaiYing_BBB_C = "Hun_BaiYing_BBB_Montage",
    GA_Hun_BaiYing_C_C = "Hun_BaiYing_C_Montage", GA_Hun_BaiYing_SWT_Power_C = "Hun_BaiYing_AAAA_Montage",
    GA_Hun_Chaos_A_C = "Hun_YuCongBlade_Attack_A_Montage", GA_Hun_Chaos_AA_C = "Hun_YuCongBlade_Attack_AA_Montage",
    GA_Hun_Chaos_AAA_C = "Hun_YuCongBlade_Attack_AAA_Montage", GA_Hun_Chaos_AAAA_C = "Hun_YuCongBlade_Attack_AAAA_Montage",
    GA_Hun_Chaos_AAAAA_C = "Hun_YuCongBlade_Attack_AAAAA_Montage", GA_Hun_Chaos_C_C = "Hun_YuCongBlade_Unique_Skill_Montage",
    GA_Hun_Chaos_B_Fire_C = "Hun_YuCongBlade_Type02_B_Montage", GA_Hun_Chaos_BB_Fire_C = "Hun_YuCongBlade_Type02_BB_Montage",
    GA_Hun_Chaos_BBB_Fire_C = "Hun_YuCongBlade_Type02_BBB_Montage", GA_Hun_Chaos_B_Ice_C = "Hun_YuCongBlade_Type01_B_Montage",
    GA_Hun_Chaos_B_Physics_C = "Hun_YuCongBlade_Type03_B_Montage", GA_Hun_Chaos_BB_Physics_C = "Hun_YuCongBlade_Type03_BB_Montage",
    GA_Hun_Chaos_SwitchFormPhysic_SWT_C = "Hun_YuCongBlade_Skill_06_Montage",
}

-- §165.2 BEGIN 动作表（tools/gen_anim_seed.py 生成，704 招，别手改）
ANIM.SEED2 = {
    GA_BrutalAxe_Combo_C = "ShaChi_BrutalAxe_Combo_Montage", GA_BrutalAxe_Normal_C = "ShaChi_BrutalAxe_Charge_Montage",
    GA_BrutalAxe_Sprint_C = "ShaChi_BrutalAxe_Charge_Sprint_Montage", GA_DuYan_Bow_Laser_C = "AM_Hun_UnnamedBow_Charge1",
    GA_DuYan_Bow_Normal_C = "AM_Hun_UnnamedBow_Charge", GA_HorseCart_Charge_C = "AM_GetOnHorseCart",
    GA_HuangJinHuoChong_Dash_C = "Hun_HuangJinHuoChong_SpecialSkill_02_Montage",
    GA_HuangJinHuoChong_DeflectCounter_C = "Hun_HuangJinHuoChong_SpecialAttack_06_Montage1",
    GA_HuangJinHuoChong_Normal_02_C = "Hun_ShaChi_HuoChong_Attack_07_Montage",
    GA_HuangJinHuoChong_Normal_04_C = "Hun_ShaChi_HuoChong_Attack_07_Montage", GA_Hun_Air_Double_AAA_C = "AM_Hun_Air_Double_AAA_Start",
    GA_Hun_Air_Double_AA_C = "AM_Hun_Air_Double_AA", GA_Hun_Air_Tang_AA_C = "AM_Hun_Air_Tang_AA_Start",
    GA_Hun_BaiYing_AAAAA_C = "Hun_BaiYing_AAAAA_Montage", GA_Hun_BaiYing_AAAA_C = "Hun_BaiYing_AAAA_Montage",
    GA_Hun_BaiYing_AAA_C = "Hun_BaiYing_AAA_Montage", GA_Hun_BaiYing_AA_C = "Hun_BaiYing_AA_Montage",
    GA_Hun_BaiYing_A_C = "Hun_BaiYing_A_Montage", GA_Hun_BaiYing_A_DashDraw_C = "AM_Hun_Long_A_DashDraw",
    GA_Hun_BaiYing_A_Dash_C = "AM_Hun_Long_A_Dash", GA_Hun_BaiYing_Air_A_C = "Hun_Long_JumpAttackA_Montage",
    GA_Hun_BaiYing_Air_A_Draw_C = "Hun_Long_JumpAttackA_Montage", GA_Hun_BaiYing_Air_B_C = "Hun_Long_JumpAttackB_Montage",
    GA_Hun_BaiYing_Air_B_Draw_C = "Hun_Long_JumpAttackB_Montage", GA_Hun_BaiYing_BBB_C = "Hun_BaiYing_BBB_Montage",
    GA_Hun_BaiYing_BB_C = "Hun_BaiYing_BB_Montage", GA_Hun_BaiYing_B_C = "Hun_BaiYing_B_Montage",
    GA_Hun_BaiYing_B_DashDraw_C = "AM_Hun_Long_B_DashDraw", GA_Hun_BaiYing_B_Dash_C = "AM_Hun_Long_B_Dash",
    GA_Hun_BaiYing_C_C = "Hun_BaiYing_C_Montage", GA_Hun_BaiYing_SWT_Power_C = "Hun_BaiYing_AAAA_Montage",
    GA_Hun_BaiYing_SpeicalAssault_C = "RTG_Hun_BaiYing_Skill_07_A_Montage",
    GA_Hun_BronzeSword_AAAA_C = "Hun_QingTongJian_Attack_AAAA_Montage",
    GA_Hun_BronzeSword_AAABB_C = "Hun_QingTongJian_Attack_AAABB_Montage",
    GA_Hun_BronzeSword_AAAB_C = "Hun_QingTongJian_Attack_AAAB_Montage", GA_Hun_BronzeSword_AAA_C = "Hun_QingTongJian_Attack_AAA_Montage",
    GA_Hun_BronzeSword_AABB_C = "Hun_QingTongJian_Attack_AABB_Montage", GA_Hun_BronzeSword_AAB_C = "Hun_QingTongJian_Attack_AAB_Montage",
    GA_Hun_BronzeSword_AA_C = "Hun_QingTongJian_Attack_AA_Montage", GA_Hun_BronzeSword_ABB_C = "Hun_QingTongJian_Attack_ABB_Montage",
    GA_Hun_BronzeSword_AB_C = "Hun_QingTongJian_Attack_AB_Montage", GA_Hun_BronzeSword_A_C = "Hun_QingTongJian_Attack_A_Montage",
    GA_Hun_BronzeSword_A_Dash_C = "Hun_QingTongJian_Dash_A_Montage", GA_Hun_BronzeSword_A_Draw_C = "Hun_QingTongJian_Attack_A_Montage",
    GA_Hun_BronzeSword_BA_C = "Hun_QingTongJian_Attack_A_Montage", GA_Hun_BronzeSword_BBB_C = "Hun_QingTongJian_Attack_BBB_Montage",
    GA_Hun_BronzeSword_BB_C = "Hun_QingTongJian_Attack_BB_Montage", GA_Hun_BronzeSword_B_C = "Hun_QingTongJian_Attack_B_Montage",
    GA_Hun_BronzeSword_B_Dash_C = "Hun_QingTongJian_Dash_B_Montage", GA_Hun_BronzeSword_B_Hold_C = "Hun_QingTongJian_Attack_Hold_B_Montage",
    GA_Hun_BronzeSword_C_C = "Hun_QingTongJian_Skill_01_Montage", GA_Hun_BronzeSword_SWT_C = "Hun_QingTongJian_Attack_SWT_Montage",
    GA_Hun_Chaos_AAAAA_C = "Hun_YuCongBlade_Attack_AAAAA_Montage", GA_Hun_Chaos_AAAA_C = "Hun_YuCongBlade_Attack_AAAA_Montage",
    GA_Hun_Chaos_AAABB_Physics_C = "AM_Hun_Tang_AAABB", GA_Hun_Chaos_AAAB_Physics_C = "Hun_YuCongBlade_Type01_BBB_Montage",
    GA_Hun_Chaos_AAA_C = "Hun_YuCongBlade_Attack_AAA_Montage", GA_Hun_Chaos_AABB_Physics_C = "Hun_YuCongBlade_Type03_BBB_Montage",
    GA_Hun_Chaos_AAB_Physics_C = "AM_Hun_Tang_AAB", GA_Hun_Chaos_AA_C = "Hun_YuCongBlade_Attack_AA_Montage",
    GA_Hun_Chaos_ABB_Physics_C = "Hun_YuCongBlade_Type03_BB_Montage", GA_Hun_Chaos_AB_Physics_C = "Hun_CanGangRen_Attack_AB_Montage",
    GA_Hun_Chaos_A_C = "Hun_YuCongBlade_Attack_A_Montage", GA_Hun_Chaos_A_DashDraw_C = "Hun_CanGangRen_Dash_A_Montage",
    GA_Hun_Chaos_A_Dash_C = "Hun_CanGangRen_Dash_A_Montage", GA_Hun_Chaos_A_Draw_C = "Hun_YuCongBlade_Attack_A_Montage",
    GA_Hun_Chaos_BBB_Physics_C = "Hun_YuCongBlade_Type03_BBB_Montage", GA_Hun_Chaos_BB_Physics_C = "Hun_YuCongBlade_Type03_BB_Montage",
    GA_Hun_Chaos_B_DashDraw_C = "Hun_CanGangRen_Dash_B_Montage", GA_Hun_Chaos_B_Dash_C = "Hun_CanGangRen_Dash_B_Montage",
    GA_Hun_Chaos_B_Draw_C = "Hun_YuCongBlade_Type03_B_Montage", GA_Hun_Chaos_B_Hold_Physics_C = "Hun_YuCongBlade_Skill_01_Montage",
    GA_Hun_Chaos_B_Physics_C = "Hun_YuCongBlade_Type03_B_Montage", GA_Hun_Chaos_C_C = "Hun_YuCongBlade_Unique_Skill_Montage",
    GA_Hun_Chaos_SWT_Power_C = "Hun_YuCongBlade_Skill_05_Montage", GA_Hun_Chaos_SwitchFormPhysic_SWT_C = "Hun_YuCongBlade_Skill_06_Montage",
    GA_Hun_ChiRen_AAAABB_C = "Hun_ChiRen_Attack_AAAABB_Montage", GA_Hun_ChiRen_AAAAB_C = "Hun_ChiRen_Attack_AAAAB_Montage",
    GA_Hun_ChiRen_AAAA_C = "Hun_ChiRen_Attack_AAAA_Montage", GA_Hun_ChiRen_AAABB_C = "Hun_ChiRen_Attack_AAABB_Montage",
    GA_Hun_ChiRen_AAAB_C = "Hun_ChiRen_Attack_AAAB_Montage", GA_Hun_ChiRen_AAA_C = "Hun_ChiRen_Attack_AAA_Montage",
    GA_Hun_ChiRen_AABB_C = "Hun_ChiRen_Attack_AABB_Montage", GA_Hun_ChiRen_AAB_C = "Hun_ChiRen_Attack_AAB_Montage",
    GA_Hun_ChiRen_AA_C = "Hun_ChiRen_Attack_AA_Montage", GA_Hun_ChiRen_ABB_C = "Hun_ChiRen_Attack_ABB_Montage",
    GA_Hun_ChiRen_AB_C = "Hun_ChiRen_Attack_AB_Montage", GA_Hun_ChiRen_A_C = "Hun_ChiRen_Attack_A_Montage",
    GA_Hun_ChiRen_A_Draw_C = "Hun_ChiRen_Attack_A_Montage", GA_Hun_ChiRen_BBB_C = "Hun_ChiRen_Attack_BBB_Montage",
    GA_Hun_ChiRen_BB_C = "Hun_ChiRen_Attack_BB_Montage", GA_Hun_ChiRen_BD_C = "Hun_ChiRen_Attack_A_Montage",
    GA_Hun_ChiRen_BSup_C = "Hun_WangMingZhanMaDao_Attack_AAAB_Montage", GA_Hun_ChiRen_B_C = "Hun_ChiRen_Attack_B_Montage",
    GA_Hun_ChiRen_B_DashDraw_C = "Hun_Horizontal_B_DashDraw_Montage", GA_Hun_ChiRen_B_Dash_C = "Hun_Horizontal_B_Dash_Fixed_Montage",
    GA_Hun_ChiRen_B_Draw_C = "Hun_ChiRen_Attack_B_Montage", GA_Hun_ChiRen_C_C = "Hun_ZhiRen_Unique_Skill_01_Montage",
    GA_Hun_ChiRen_SWT_C = "Hun_Horizontal_AAAA_Montage", GA_Hun_ChiZheCanJian_C_C = "Hun_ChiZheCanJian_Drunk_Unique_Skill_Montage",
    GA_Hun_ChiZheCanJian_Drunk_AAAAA_C = "Hun_ChiZheCanJian_Drunk_Attack_EEEEE_Montage",
    GA_Hun_ChiZheCanJian_Drunk_AAAA_C = "Hun_ChiZheCanJian_Drunk_Attack_EEEE_Montage1",
    GA_Hun_ChiZheCanJian_Drunk_AAA_C = "Hun_ChiZheCanJian_Drunk_Attack_EEE_Montage",
    GA_Hun_ChiZheCanJian_Drunk_AA_C = "Hun_ChiZheCanJian_Drunk_Attack_EE_Montage",
    GA_Hun_ChiZheCanJian_Drunk_A_C = "Hun_ChiZheCanJian_Drunk_Attack_E_Montage",
    GA_Hun_ChiZheCanJian_Drunk_A_DashChild_C = "Hun_ChiZheCanJian_Drunk_Attack_E_Montage",
    GA_Hun_ChiZheCanJian_Normal_AAAAA_C = "Hun_ChiZheCanJian_Awake_Attack_AAAAA_Montage",
    GA_Hun_ChiZheCanJian_Normal_AAAA_C = "Hun_ChiZheCanJian_Awake_Attack_AAAA_Montage",
    GA_Hun_ChiZheCanJian_Normal_AAA_C = "Hun_ChiZheCanJian_Awake_Attack_AAA_Montage",
    GA_Hun_ChiZheCanJian_Normal_AA_C = "Hun_ChiZheCanJian_Awake_Attack_AA_Montage",
    GA_Hun_ChiZheCanJian_Normal_AA_DashChild_C = "Hun_ChiZheCanJian_Awake_Attack_AA_Montage",
    GA_Hun_ChiZheCanJian_Normal_A_C = "Hun_ChiZheCanJian_Awake_Attack_A_Montage",
    GA_Hun_ChiZheCanJian_Normal_BBB_C = "Hun_ChiZheCanJian_Awake_Attack_ABBB_Montage",
    GA_Hun_ChiZheCanJian_Normal_BB_C = "Hun_ChiZheCanJian_Awake_Attack_ABB_Montage",
    GA_Hun_ChiZheCanJian_Normal_B_C = "Hun_ChiZheCanJian_Awake_Attack_B_Montage",
    GA_Hun_ChiZheCanJian_Normal_B_DashChild_C = "Hun_ChiZheCanJian_Awake_Attack_B_Montage",
    GA_Hun_ChiZheCanJian_SWT_C = "Hun_ChiZheCanJian_Drunk_Attack_EEFD_Montage",
    GA_Hun_ChiZheCanJian_Tipsy_BBB_C = "Hun_ChiZheCanJian_Tipsy_Attack_ABB_Montage",
    GA_Hun_ChiZheCanJian_Tipsy_BB_C = "Hun_ChiZheCanJian_Tipsy_Attack_BB_Montage",
    GA_Hun_ChiZheCanJian_Tipsy_B_C = "Hun_ChiZheCanJian_Tipsy_Attack_B_Montage", GA_Hun_Double_AAAAAA_C = "AM_Hun_Double_AAAAAA",
    GA_Hun_Double_AAAAA_C = "AM_Hun_Double_AAAAA", GA_Hun_Double_AAAA_C = "AM_Hun_Double_AAAA",
    GA_Hun_Double_AAABBB_C = "AM_Hun_Double_AAABBB", GA_Hun_Double_AAABB_C = "AM_Hun_Double_AAABB",
    GA_Hun_Double_AAAB_C = "AM_Hun_Double_AAAB", GA_Hun_Double_AAA_C = "AM_Hun_Double_AAA", GA_Hun_Double_AABB_C = "AM_Hun_Double_AABB",
    GA_Hun_Double_AAB_C = "AM_Hun_Double_AAB", GA_Hun_Double_AA_C = "AM_Hun_Double_AA", GA_Hun_Double_ABB_C = "AM_Hun_Double_ABB",
    GA_Hun_Double_AB_C = "AM_Hun_Double_AB", GA_Hun_Double_ATBBB_C = "AM_Hun_Double_AAABB", GA_Hun_Double_ATBB_C = "AM_Hun_Double_AB",
    GA_Hun_Double_ATB_C = "AM_Hun_Double_AAB", GA_Hun_Double_A_C = "AM_Hun_Double_A",
    GA_Hun_Double_A_DashDraw_Short_C = "AM_Hun_Double_A_DashDraw", GA_Hun_Double_A_Dash_Short_C = "AM_Hun_Double_A_Dash",
    GA_Hun_Double_A_Draw_C = "AM_Hun_Double_A_Draw", GA_Hun_Double_Air_A_C = "Hun_Tang_JumpAttackB_Montage",
    GA_Hun_Double_Air_A_Draw_C = "Hun_Tang_JumpAttackB_Montage", GA_Hun_Double_Air_B_C = "Hun_Double_JumpAttackA_Montage",
    GA_Hun_Double_Air_B_Draw_C = "Hun_Double_JumpAttackA_Montage", GA_Hun_Double_BBBB_C = "AM_Hun_Double_BBBB",
    GA_Hun_Double_BBB_C = "AM_Hun_Double_BBB", GA_Hun_Double_BB_C = "AM_Hun_Double_BB", GA_Hun_Double_BTA_C = "AM_Hun_Double_A_DashDraw",
    GA_Hun_Double_B_C = "AM_Hun_Double_B", GA_Hun_Double_B_DashDraw_C = "AM_Hun_Double_B_DashDraw",
    GA_Hun_Double_B_Dash_C = "AM_Hun_Double_B_Dash", GA_Hun_Double_B_Draw_C = "AM_Hun_Double_B_Draw",
    GA_Hun_Double_JueYing_C_Air_C = "Hun_Double_Crow_Near_Montage", GA_Hun_Double_JueYing_C_C = "Hun_Double_Crow_Near_Montage",
    GA_Hun_Double_SWT_C = "AM_Hun_Double_PD_L1", GA_Hun_Double_SWT_Tutorial_C = "AM_Hun_Double_A_Draw",
    GA_Hun_DualHook_AAAAA_C = "Hun_BieLiCanGou_AAAAA_Montage", GA_Hun_DualHook_AAAA_C = "Hun_BieLiCanGou_AAAA_Montage",
    GA_Hun_DualHook_AAABB_C = "Hun_BieLiCanGou_AAABB_Montage", GA_Hun_DualHook_AAAB_C = "Hun_BieLiCanGou_AB_Montage",
    GA_Hun_DualHook_AAA_C = "Hun_BieLiCanGou_AAA_Montage", GA_Hun_DualHook_AABB_C = "Hun_BieLiCanGou_AABB_Montage",
    GA_Hun_DualHook_AAB_C = "Hun_BieLiCanGou_AAB_Montage", GA_Hun_DualHook_AA_C = "Hun_BieLiCanGou_AA_Montage",
    GA_Hun_DualHook_ABB_C = "Hun_BieLiCanGou_ABB_Montage", GA_Hun_DualHook_AB_C = "Hun_BieLiCanGou_AAAB_Montage",
    GA_Hun_DualHook_A_C = "Hun_BieLiCanGou_A_Montage", GA_Hun_DualHook_A_DashDraw_C = "Hun_BieLiCanGou_DashA_Montage",
    GA_Hun_DualHook_A_Dash_C = "Hun_BieLiCanGou_DashA_Montage", GA_Hun_DualHook_A_Draw_C = "Hun_BieLiCanGou_A_Montage",
    GA_Hun_DualHook_A_Pursure_02_C = "Hun_BieLiCanGou_A_Pursue_Montage", GA_Hun_DualHook_Air_B_C = "Hun_Double_JumpAttackA_Montage",
    GA_Hun_DualHook_Air_B_Draw_C = "Hun_Double_JumpAttackA_Montage", GA_Hun_DualHook_BBBB_C = "Hun_BieLiCanGou_BBBB_Montage",
    GA_Hun_DualHook_BBB_C = "Hun_BieLiCanGou_BBB_Montage", GA_Hun_DualHook_BB_C = "Hun_BieLiCanGou_AABB_Montage",
    GA_Hun_DualHook_B_C = "Hun_BieLiCanGou_B_Montage", GA_Hun_DualHook_B_DashDraw_C = "Hun_BieLiCanGou_DashB_Montage",
    GA_Hun_DualHook_B_Dash_C = "Hun_BieLiCanGou_DashB_Montage", GA_Hun_DualHook_B_Draw_C = "Hun_BieLiCanGou_B_Montage",
    GA_Hun_DualHook_B_Pursure_C = "Hun_BieLiCanGou_Skill_02_Montage", GA_Hun_DualHook_C_C = "Hun_BieLiCanGou_Unique_Skill_01_Montage",
    GA_Hun_DualHook_DB_C = "GuiChai_Yellow_Special_Defence_Start_Montage",
    GA_Hun_DualHook_DB_SWT_C = "GuiChai_Yellow_Special_Defence_Start_Montage",
    GA_Hun_DualHook_SWT_Power_C = "GuiChai_Yellow_Special_Defence_Start_Montage",
    GA_Hun_FengLeiJian_AAAA_C = "Hun_BaiShanDual_Attack_AAAA_Montage", GA_Hun_FengLeiJian_AAABB_C = "Hun_BaiShanDual_Attack_AAABB_Montage",
    GA_Hun_FengLeiJian_AAAB_C = "Hun_BaiShanDual_Attack_AAAB_Montage", GA_Hun_FengLeiJian_AAA_C = "Hun_BaiShanDual_Attack_AAA_Montage",
    GA_Hun_FengLeiJian_AABAB_C = "Hun_BaiShanDual_Attack_AABAB_Montage", GA_Hun_FengLeiJian_AABA_C = "Hun_BaiShanDual_Attack_AABA_Montage",
    GA_Hun_FengLeiJian_AABB_C = "Hun_BaiShanDual_Attack_AABB_Montage", GA_Hun_FengLeiJian_AAB_C = "Hun_BaiShanDual_Attack_AAB_Montage",
    GA_Hun_FengLeiJian_AA_C = "Hun_BaiShanDual_Attack_AA_Montage", GA_Hun_FengLeiJian_AB_C = "AM_Hun_Double_AB",
    GA_Hun_FengLeiJian_A_C = "Hun_BaiShanDual_Attack_A_Montage", GA_Hun_FengLeiJian_A_DashDraw_C = "AM_Hun_Double_A_DashDraw",
    GA_Hun_FengLeiJian_A_Dash_C = "AM_Hun_Double_A_Dash", GA_Hun_FengLeiJian_A_Draw_C = "AM_Hun_Double_A_Draw",
    GA_Hun_FengLeiJian_Air_A_C = "Hun_Tang_JumpAttackB_Montage", GA_Hun_FengLeiJian_Air_A_Draw_C = "Hun_Tang_JumpAttackB_Montage",
    GA_Hun_FengLeiJian_Air_B_C = "Hun_Double_JumpAttackA_Montage", GA_Hun_FengLeiJian_Air_B_Draw_C = "Hun_Double_JumpAttackA_Montage",
    GA_Hun_FengLeiJian_BBBB_C = "Hun_BaiShanDual_Attack_BBBB_Montage", GA_Hun_FengLeiJian_BBB_C = "Hun_BaiShanDual_Attack_BBB_Montage",
    GA_Hun_FengLeiJian_BB_C = "Hun_BaiShanDual_Attack_BB_Montage", GA_Hun_FengLeiJian_B_C = "Hun_BaiShanDual_Attack_B_Montage",
    GA_Hun_FengLeiJian_B_DashDraw_C = "AM_Hun_Double_B_DashDraw", GA_Hun_FengLeiJian_B_Dash_C = "AM_Hun_Double_B_Dash",
    GA_Hun_FengLeiJian_B_Draw_C = "Hun_BaiShanDual_Attack_B_Montage", GA_Hun_FengLeiJian_B_Hold_C = "Hun_BaiShanDual_Hold_B_02_Montage",
    GA_Hun_FengLeiJian_C_C = "Hun_BaiShanDual_Skill_02_Montage",
    GA_Hun_FengLeiJian_FengLeiState_SpecailAttack_02_C = "Hun_BaiShanDual_Skill_03_Montage",
    GA_Hun_FengLeiJian_SWT_Power_C = "Hun_BaiShanDual_Attack_AABB_Montage", GA_Hun_GuiTouBlade_AAAA_C = "Hun_Horizontal_AAA_Montage",
    GA_Hun_GuiTouBlade_AAABB_C = "Hun_Horizontal_BB_Montage", GA_Hun_GuiTouBlade_AAAB_C = "Hun_Horizontal_B_Montage",
    GA_Hun_GuiTouBlade_AAA_C = "Hun_AHuaBlade_AAA_Montage", GA_Hun_GuiTouBlade_AABB_C = "Hun_AHuaBlade_AAB_Ex_Montage",
    GA_Hun_GuiTouBlade_AAB_C = "Hun_AHuaBlade_AAB_Montage", GA_Hun_GuiTouBlade_AA_C = "Hun_AHuaBlade_AA_Montage",
    GA_Hun_GuiTouBlade_ABB_C = "Hun_AHuaBlade_AB_Ex_Montage", GA_Hun_GuiTouBlade_AB_C = "Hun_AHuaBlade_AB_Montage",
    GA_Hun_GuiTouBlade_A_C = "Hun_AHuaBlade_A_Montage", GA_Hun_GuiTouBlade_A_DashDraw_C = "Hun_Horizontal_A_Dash_Montage",
    GA_Hun_GuiTouBlade_A_Dash_C = "Hun_Horizontal_A_Dash_Montage", GA_Hun_GuiTouBlade_A_Draw_C = "Hun_AHuaBlade_Switch_A_Montage",
    GA_Hun_GuiTouBlade_BBB_C = "Hun_AHuaBlade_BB_Ex_Montage", GA_Hun_GuiTouBlade_BB_C = "Hun_Horizontal_AA_Montage",
    GA_Hun_GuiTouBlade_BB_UnCharge_C = "Hun_Horizontal_AA_Montage",
    GA_Hun_GuiTouBlade_BB_UnCharge_Reinforced_C = "Hun_Horizontal_AA_Montage", GA_Hun_GuiTouBlade_B_C = "Hun_Horizontal_A_Montage",
    GA_Hun_GuiTouBlade_B_DashDraw_C = "Hun_AHuaBlade_Draw_Dash_B_02_Montage",
    GA_Hun_GuiTouBlade_B_Dash_C = "Hun_AHuaBlade_Dash_B_02_Montage", GA_Hun_GuiTouBlade_B_Draw_C = "Hun_Horizontal_A_Draw_Montage",
    GA_Hun_GuiTouBlade_B_Hold_C = "Hun_AHuaBlade_B_Hold_Montage", GA_Hun_GuiTouBlade_B_Hold_Start_C = "Hun_AHuaBlade_B_Hold_Montage",
    GA_Hun_GuiTouBlade_C_C = "Hun_AHuaBlade_C_Montage", GA_Hun_GuiTouBlade_SWT_C = "Hun_AHuaBlade_SnapB_Montage",
    GA_Hun_HeiMoShang_AAAAAA_C = "Hun_HeiMoShang_BBBB_Montage", GA_Hun_HeiMoShang_AAAAABB_C = "Hun_HeiMoShang_Skill_01_Montage",
    GA_Hun_HeiMoShang_AAAAAB_C = "Hun_HeiMoShang_AAABB_Montage", GA_Hun_HeiMoShang_AAAAA_C = "Hun_HeiMoShang_AAAAA_Montage",
    GA_Hun_HeiMoShang_AAAAB_Alt_C = "Hun_HeiMoShang_AAAAB_Montage", GA_Hun_HeiMoShang_AAAA_C = "Hun_HeiMoShang_AAAA_Montage",
    GA_Hun_HeiMoShang_AAABB_C = "Hun_HeiMoShang_AAABB_Montage", GA_Hun_HeiMoShang_AAAB_C = "Hun_HeiMoShang_AAAB_Montage",
    GA_Hun_HeiMoShang_AAA_C = "Hun_HeiMoShang_AAA_Montage", GA_Hun_HeiMoShang_AABB_C = "Hun_HeiMoShang_AABB_Montage",
    GA_Hun_HeiMoShang_AAB_C = "Hun_HeiMoShang_AAB_Montage", GA_Hun_HeiMoShang_AA_C = "Hun_HeiMoShang_AA_Montage",
    GA_Hun_HeiMoShang_ABB_C = "Hun_HeiMoShang_ABB_Montage", GA_Hun_HeiMoShang_AB_C = "Hun_HeiMoShang_AB_Montage",
    GA_Hun_HeiMoShang_A_C = "Hun_HeiMoShang_A_Montage", GA_Hun_HeiMoShang_A_DashDraw_C = "AM_Hun_Tang_A_DashDraw",
    GA_Hun_HeiMoShang_A_Dash_C = "AM_Hun_Tang_A_Dash", GA_Hun_HeiMoShang_A_Draw_C = "Hun_HeiMoShang_A_Montage",
    GA_Hun_HeiMoShang_BBBB_C = "Hun_HeiMoShang_Skill_01_Montage", GA_Hun_HeiMoShang_BBB_C = "Hun_HeiMoShang_BBB_Montage",
    GA_Hun_HeiMoShang_BB_C = "Hun_HeiMoShang_BB_Montage", GA_Hun_HeiMoShang_B_C = "Hun_HeiMoShang_B_Montage",
    GA_Hun_HeiMoShang_B_DashDraw_C = "AM_Hun_Tang_B_DashDraw", GA_Hun_HeiMoShang_B_Dash_C = "AM_Hun_Tang_B_Dash",
    GA_Hun_HeiMoShang_B_Draw_C = "Hun_HeiMoShang_B_Montage", GA_Hun_HeiMoShang_C1_C = "Hun_HeiMoShang_JueXing_Montage",
    GA_Hun_HeiMoShang_SWT_C = "Hun_HeiMoShang_Skill_01_Montage", GA_Hun_Horizontal_AAAA_C = "Hun_Horizontal_AAAA_Montage",
    GA_Hun_Horizontal_AAAB_C = "Hun_Horizontal_AAAB_Montage", GA_Hun_Horizontal_AAA_C = "Hun_Horizontal_AAA_Montage",
    GA_Hun_Horizontal_AAB_C = "Hun_Horizontal_AAB_Montage", GA_Hun_Horizontal_AA_C = "Hun_Horizontal_AA_Montage",
    GA_Hun_Horizontal_AB_C = "Hun_Horizontal_AB_Montage", GA_Hun_Horizontal_A_C = "Hun_Horizontal_A_Montage",
    GA_Hun_Horizontal_A_DashDraw_C = "Hun_Horizontal_A_Dash_Montage", GA_Hun_Horizontal_A_Dash_C = "Hun_Horizontal_A_Dash_Montage",
    GA_Hun_Horizontal_A_Draw_C = "Hun_Horizontal_A_Draw_Montage", GA_Hun_Horizontal_BB_C = "Hun_Horizontal_BB_Montage",
    GA_Hun_Horizontal_B_C = "Hun_Horizontal_B_Montage", GA_Hun_Horizontal_B_DashDraw_C = "Hun_Horizontal_B_DashDraw_Montage",
    GA_Hun_Horizontal_B_Dash_C = "Hun_Horizontal_B_Dash_Fixed_Montage", GA_Hun_Horizontal_B_Draw_C = "Hun_Horizontal_B_Draw_Montage",
    GA_Hun_Horizontal_B_NoCost_C = "Hun_Horizontal_B_Montage", GA_Hun_Horizontal_BladeWave_C = "Hun_DangKouXiongRen_Skill_01_Montage",
    GA_Hun_Horizontal_C_C = "AM_Hun_Horizontal_C", GA_Hun_Horizontal_CounterAttack_01_C = "Hun_Horizontal_CounterAttack_02_Montage",
    GA_Hun_Horizontal_CounterAttack_02_C = "Hun_Horizontal_CounterAttack_02_Placeholder_Montage",
    GA_Hun_Horizontal_SWT_Power_C = "Hun_Horizontal_CounterAttack_02_Montage", GA_Hun_HuoLiuXing_AAAA_C = "Hun_HuoLiuXing_Attack_D_Montage",
    GA_Hun_HuoLiuXing_AAA_C = "Hun_HuoLiuXing_Attack_C_Montage", GA_Hun_HuoLiuXing_AA_C = "Hun_HuoLiuXing_Attack_B_Montage",
    GA_Hun_HuoLiuXing_A_C = "Hun_HuoLiuXing_Attack_A_Montage", GA_Hun_HuoLiuXing_A_Short_C = "Hun_HuoLiuXing_Attack_A_Montage",
    GA_Hun_HuoLiuXing_DB_C = "ShaChi_Hook_CCC_HuoLiuXing_Placeholder_Montage", GA_Hun_Iron_AAAAA_C = "Hun_CanGangRen_Attack_AAAAA_Montage",
    GA_Hun_Iron_AAAA_C = "Hun_CanGangRen_Attack_AAAA_Montage", GA_Hun_Iron_AAABB_C = "Hun_CanGangRen_Attack_AAABB_Montage",
    GA_Hun_Iron_AAAB_C = "Hun_CanGangRen_Attack_AAAB_Montage", GA_Hun_Iron_AAA_C = "Hun_CanGangRen_Attack_AAA_Montage",
    GA_Hun_Iron_AABB_C = "Hun_CanGangRen_Attack_AABB_Montage", GA_Hun_Iron_AAB_C = "Hun_CanGangRen_Attack_AAB_Montage",
    GA_Hun_Iron_AA_C = "Hun_CanGangRen_Attack_AA_Montage", GA_Hun_Iron_ABB_C = "Hun_CanGangRen_Attack_ABB_Montage",
    GA_Hun_Iron_AB_C = "Hun_CanGangRen_Attack_AB_Montage", GA_Hun_Iron_A_C = "Hun_CanGangRen_Attack_A_Montage",
    GA_Hun_Iron_A_DashDraw_C = "Hun_CanGangRen_Dash_A_Montage", GA_Hun_Iron_A_Dash_C = "Hun_CanGangRen_Dash_A_Montage",
    GA_Hun_Iron_A_Draw_C = "Hun_CanGangRen_Attack_A_Montage", GA_Hun_Iron_BBB_C = "Hun_CanGangRen_Attack_BBB_Montage",
    GA_Hun_Iron_BB_C = "Hun_CanGangRen_Attack_BB_Montage", GA_Hun_Iron_BChargeAttack_C = "Hun_CanGangRen_Skill_02_End_Montage",
    GA_Hun_Iron_BCharge_C = "Hun_CanGangRen_Skill_02_Montage", GA_Hun_Iron_B_C = "Hun_CanGangRen_Attack_B_Montage",
    GA_Hun_Iron_B_DashDraw_C = "Hun_CanGangRen_Dash_B_Montage", GA_Hun_Iron_B_Dash_C = "Hun_CanGangRen_Dash_B_Montage",
    GA_Hun_Iron_B_Draw_C = "Hun_CanGangRen_Attack_B_Draw_Montage", GA_Hun_Iron_C_C = "Hun_CanGangRen_Unique_Skill_Montage",
    GA_Hun_Iron_SWT_C = "Hun_CanGangRen_Attack_BB_Montage", GA_Hun_Jade_AAAAAA_C = "Hun_YuShuangHuan_Attack_AAAAAA_Montage",
    GA_Hun_Jade_AAAAA_C = "Hun_YuShuangHuan_Attack_AAAAA_Montage", GA_Hun_Jade_AAAA_C = "AM_Hun_Jade_AAAA",
    GA_Hun_Jade_AAABB_C = "Hun_YuShuangHuan_SimpleExE_Multi_01_Montage", GA_Hun_Jade_AAAB_C = "Hun_Jade_AAAB_New_Montage",
    GA_Hun_Jade_AAA_C = "Hun_YuShuangHuan_Attack_AAA_Montage", GA_Hun_Jade_AABB_C = "Hun_Jade_AAABB_01_Montage",
    GA_Hun_Jade_AA_C = "Hun_YuShuangHuan_Attack_AA_Montage", GA_Hun_Jade_ABB_C = "AM_Hun_Jade_ABB", GA_Hun_Jade_AB_C = "AM_Hun_Jade_AB",
    GA_Hun_Jade_A_C = "AM_Hun_Jade_A", GA_Hun_Jade_A_DashDraw_C = "AM_Hun_Jade_A_DashDraw", GA_Hun_Jade_A_Dash_C = "AM_Hun_Jade_A_Dash",
    GA_Hun_Jade_A_Draw_C = "AM_Hun_Jade_A_Draw", GA_Hun_Jade_BBBB_C = "Hun_Jade_BB_01_Montage", GA_Hun_Jade_BBB_C = "AM_Hun_Jade_BBB",
    GA_Hun_Jade_BB_C = "AM_Hun_Jade_BB", GA_Hun_Jade_B_C = "AM_Hun_Jade_B", GA_Hun_Jade_B_DashDraw_C = "AM_Hun_Jade_B_DashDraw",
    GA_Hun_Jade_B_Dash_C = "Hun_Jade_B_Dash_Montage", GA_Hun_Jade_B_Draw_C = "AM_Hun_Jade_B_Draw",
    GA_Hun_Jade_C_Range_C = "AM_Hun_Jade_C_Range", GA_Hun_Jade_DB_C = "Hun_ShuangYue_Skill_03_BanBen_02_Montage",
    GA_Hun_Jade_SWT_C = "Hun_Jade_B_New_Montage", GA_Hun_JigSaw_AAAA_C = "Hun_Horizontal_AAA_Montage",
    GA_Hun_JigSaw_AAA_C = "Hun_AHuaBlade_AAA_Montage", GA_Hun_JigSaw_AA_C = "Hun_AHuaBlade_AA_Montage",
    GA_Hun_JigSaw_A_C = "Hun_AHuaBlade_A_Montage", GA_Hun_Jigsaw_AAAB_C = "AM_Hun_Jigsaw_AAAB_Miss",
    GA_Hun_Jigsaw_AAB_C = "AM_Hun_Jigsaw_AAB", GA_Hun_Jigsaw_AB_C = "AM_Hun_Jigsaw_AB",
    GA_Hun_Jigsaw_A_DashDraw_C = "Hun_SawBlade_Dash_Switch_A_Miss_Montage", GA_Hun_Jigsaw_A_Dash_C = "Hun_SawBlade_Dash_A_Miss_Montage",
    GA_Hun_Jigsaw_A_Draw_C = "Hun_SawBlade_Switch_A_Miss_Montage", GA_Hun_Jigsaw_Air_A_C = "Hun_Long_JumpAttackA_Montage",
    GA_Hun_Jigsaw_Air_A_Draw_C = "Hun_Long_JumpAttackA_Montage", GA_Hun_Jigsaw_Air_B_C = "Hun_Long_JumpAttackB_Montage",
    GA_Hun_Jigsaw_Air_B_Draw_C = "Hun_Long_JumpAttackB_Montage", GA_Hun_Jigsaw_BB_C = "Hun_SawBlade_BB_Miss_Montage",
    GA_Hun_Jigsaw_B_C = "AM_Hun_Jigsaw_B_Miss", GA_Hun_Jigsaw_B_DashDraw_C = "Hun_SawBlade_Dash_Switch_B_Miss_Montage",
    GA_Hun_Jigsaw_B_Dash_C = "Hun_SawBlade_Dash_B_Miss_Montage", GA_Hun_Jigsaw_C_C = "Hun_SawBlade_Unique_Skill_Montage",
    GA_Hun_Jigsaw_RAAA_C = "Hun_SawBlade_Skill_AAA_Montage", GA_Hun_Jigsaw_RAA_C = "Hun_SawBlade_Skill_AA_Montage",
    GA_Hun_Jigsaw_RA_C = "Hun_SawBlade_Skill_A_Montage", GA_Hun_Jigsaw_RBB_C = "Hun_SawBlade_Skill_BB_Montage",
    GA_Hun_Jigsaw_RB_C = "Hun_SawBlade_Skill_B_Montage", GA_Hun_Jigsaw_SA_C = "Hun_Jigsaw_SA_Montage",
    GA_Hun_Jigsaw_SB_C = "Hun_Jigsaw_SB_Montage", GA_Hun_Long_A_DashDraw_C = "AM_Hun_Long_A_DashDraw",
    GA_Hun_Long_A_Dash_C = "AM_Hun_Long_A_Dash", GA_Hun_Long_Air_A_C = "Hun_Long_JumpAttackA_Montage",
    GA_Hun_Long_Air_A_Draw_C = "Hun_Long_JumpAttackA_Montage", GA_Hun_Long_Air_B_C = "Hun_Long_JumpAttackB_Montage",
    GA_Hun_Long_Air_B_Draw_C = "Hun_Long_JumpAttackB_Montage", GA_Hun_Long_BCharge_C = "AM_Hun_Long_BCharge",
    GA_Hun_Long_CounterA_C = "Hun_WangMingZhanMaDao_Attack_BB_Montage", GA_Hun_Long_CounterB_C = "Hun_Long_CounterB_Montage",
    GA_Hun_LuanYing_AAAAA_C = "Hun_LuanYing_AAAAA_Montage", GA_Hun_LuanYing_AAAA_C = "Hun_LuanYing_AAAA_Montage",
    GA_Hun_LuanYing_AAA_C = "Hun_LuanYing_AAA_Montage", GA_Hun_LuanYing_AA_C = "Hun_LuanYing_AA_Montage",
    GA_Hun_LuanYing_A_C = "Hun_LuanYing_A_Montage", GA_Hun_LuanYing_A_DashDraw_C = "Hun_LuanYing_B_Montage",
    GA_Hun_LuanYing_DashA_C = "AM_Hun_LuanYing_B_Dash", GA_Hun_LuanYing_Draw_A_C = "Hun_LuanYing_A_Montage",
    GA_Hun_LuanYing_P2_AAAB_C = "Hun_LuanYing_P2_AAAB_Montage", GA_Hun_LuanYing_P2_AAB_C = "Hun_LuanYing_P2_AAB_Montage",
    GA_Hun_LuanYing_P2_AB_C = "Hun_LuanYing_P2_AB_Montage", GA_Hun_LuanYing_P2_BBB_C = "Hun_LuanYing_P2_BBB_Montage",
    GA_Hun_LuanYing_P2_BB_C = "Hun_LuanYing_P2_BB_Montage", GA_Hun_LuanYing_P2_B_C = "Hun_LuanYing_P2_B_Montage",
    GA_Hun_LuanYing_P2_CA_C = "Hun_LuanYing_P2_Unique_Skill_Montage", GA_Hun_LuanYing_SWT_P2_C = "Hun_LuanYing_P2_Buff_Montage",
    GA_Hun_Lute_AAA_C = "Hun_ShaChi_Lute_Attack_AAA_Montage", GA_Hun_Lute_AA_C = "Hun_ShaChi_Lute_Attack_AA_Montage",
    GA_Hun_Lute_A_C = "Hun_ShaChi_Lute_Attack_A_Montage", GA_Hun_Lute_SKill_C = "Hun_ShaChi_Lute_Skill_01_Start_Montage",
    GA_Hun_Mojian_AAA_C = "Hun_Shachi_MJZ_AAA_attack_Montage", GA_Hun_Mojian_AA_C = "Hun_Shachi_MJZ_AA_attack_Montage",
    GA_Hun_Mojian_A_C = "Hun_Shachi_MJZ_A_attack_Montage", GA_Hun_Mojian_A_Short_C = "Hun_Shachi_MJZ_A_Attack_Short_Montage1",
    GA_Hun_Mojian_UpRunGEx_01_C = "Hun_Shachi_MJZ_UpRunExecution_0_Montage", GA_Hun_PoJun_AAAA_C = "Hun_PoJun_Attack_AAAA_Montage",
    GA_Hun_PoJun_AAAB_C = "Hun_PoJun_Attack_AAAB_Montage", GA_Hun_PoJun_AAA_C = "Hun_PoJun_Attack_AAA_Montage",
    GA_Hun_PoJun_AAB_C = "Hun_PoJun_Attack_AAB_Montage", GA_Hun_PoJun_AA_C = "Hun_PoJun_Attack_AA_Montage",
    GA_Hun_PoJun_AB_C = "Hun_PoJun_Attack_AB_Montage", GA_Hun_PoJun_A_C = "Hun_PoJun_Attack_A_Montage",
    GA_Hun_PoJun_A_DashDraw_C = "Hun_PoJun_Attack_Draw_A_Montage", GA_Hun_PoJun_A_Dash_C = "Hun_PoJun_Dash_A_Montage",
    GA_Hun_PoJun_A_Draw_C = "Hun_PoJun_Attack_A_Montage", GA_Hun_PoJun_BB_C = "Hun_PoJun_Attack_BB_Montage",
    GA_Hun_PoJun_B_C = "Hun_PoJun_Attack_B_Montage", GA_Hun_PoJun_B_DashDraw_C = "Hun_PoJun_Attack_Draw_B_Montage",
    GA_Hun_PoJun_B_Dash_C = "Hun_PoJun_Attack_Dash_B_Montage", GA_Hun_PoJun_B_Draw_C = "Hun_PoJun_Attack_B_Montage",
    GA_Hun_PoJun_C_C = "Hun_PoJun_Attack_C_Montage", GA_Hun_PoJun_DB_02_C = "Hun_PoJun_Attack_CC_Montage",
    GA_Hun_PoJun_DB_C = "Hun_PoJun_SpecialSkill_01_Montage", GA_Hun_ShachiHook_CAA_C = "ShaChi_Hook_CAA_Montage",
    GA_Hun_ShachiHook_CA_C = "ShaChi_Hook_CA_Montage", GA_Hun_ShachiHook_CBB_C = "ShaChi_Hook_CBB_Montage",
    GA_Hun_ShachiHook_CB_C = "ShaChi_Hook_CB_Montage", GA_Hun_ShachiHook_CCCC_C = "ShaChi_Hook_CCCC_Montage",
    GA_Hun_ShachiHook_CCC_C = "ShaChi_Hook_CCC_Montage", GA_Hun_ShachiHook_CC_C = "ShaChi_Hook_CC_Montage",
    GA_Hun_ShachiHook_CDD_C = "ShaChi_Hook_CDD_Montage", GA_Hun_ShachiHook_CD_C = "ShaChi_Hook_CD_Montage",
    GA_Hun_ShachiHook_C_C = "ShaChi_Hook_C_Montage", GA_Hun_ShachiHook_Drag_C = "ShaChi_Hook_Skill_01_Montage",
    GA_Hun_ShachiHook_HookMove_C = "ShaChi_Hook_Skill_02_Start_Montage", GA_Hun_ShuangYue_AAAAAA_C = "Hun_ShuangYue_Attack_AAAAAA_Montage",
    GA_Hun_ShuangYue_AAAAA_C = "Hun_ShuangYue_Attack_AAAAA_Montage", GA_Hun_ShuangYue_AAAA_C = "Hun_ShuangYue_Attack_AAAA_Montage",
    GA_Hun_ShuangYue_AAABB_C = "Hun_ShuangYue_Attack_AAABB_Montage", GA_Hun_ShuangYue_AAAB_C = "Hun_ShuangYue_Attack_AAAB_Montage",
    GA_Hun_ShuangYue_AAA_C = "Hun_ShuangYue_Attack_AAA_Montage", GA_Hun_ShuangYue_AABB_C = "Hun_ShuangYue_Attack_AABB_Montage",
    GA_Hun_ShuangYue_AAB_C = "Hun_ShuangYue_Attack_AAB_Montage", GA_Hun_ShuangYue_AA_C = "Hun_ShuangYue_Attack_AA_Montage",
    GA_Hun_ShuangYue_ABB_C = "Hun_ShuangYue_Attack_ABB_Montage", GA_Hun_ShuangYue_AB_C = "Hun_ShuangYue_Attack_AB_Montage",
    GA_Hun_ShuangYue_A_C = "Hun_ShuangYue_Attack_A_Montage", GA_Hun_ShuangYue_A_DashDraw_C = "Hun_ShuangYue_Dash_A_Montage",
    GA_Hun_ShuangYue_A_Dash_C = "Hun_ShuangYue_Dash_A_Montage", GA_Hun_ShuangYue_A_Draw_C = "Hun_ShuangYue_Attack_A_Montage",
    GA_Hun_ShuangYue_BBBB_C = "Hun_ShuangYue_Attack_BBBB_Montage", GA_Hun_ShuangYue_BBB_C = "Hun_ShuangYue_Attack_BBB_Montage",
    GA_Hun_ShuangYue_BB_C = "Hun_ShuangYue_Attack_BB_Montage", GA_Hun_ShuangYue_B_C = "Hun_ShuangYue_Attack_B_Montage",
    GA_Hun_ShuangYue_B_DashDraw_C = "Hun_ShuangYue_Dash_B_Montage", GA_Hun_ShuangYue_B_Dash_C = "Hun_ShuangYue_Dash_B_Montage",
    GA_Hun_ShuangYue_B_Draw_C = "Hun_ShuangYue_Attack_B_Montage", GA_Hun_ShuangYue_C_C = "Hun_ShuangYue_Unique_Skill_Montage",
    GA_Hun_ShuangYue_DB_C = "Hun_ShuangYue_Skill_02_Montage", GA_Hun_ShuangYue_DB_SWT_C = "Hun_ShuangYue_Skill_02_Montage",
    GA_Hun_ShuangYue_PBB_C = "Hun_ShuangYue_Skill_03_Montage", GA_Hun_ShuangYue_PB_C = "Hun_ShuangYue_Skill_01_Montage",
    GA_Hun_ShuangYue_SWT_C = "Hun_ShuangYue_Skill_02_Montage", GA_Hun_SlitheringSword_AAAAA_C = "AM_Hun_SlitheringSword_AAAAA",
    GA_Hun_SlitheringSword_AAAA_C = "AM_Hun_SlitheringSword_AAAA", GA_Hun_SlitheringSword_AAABB_C = "AM_Hun_SlitheringSword_AAABB",
    GA_Hun_SlitheringSword_AAAB_C = "AM_Hun_SlitheringSword_AAAB", GA_Hun_SlitheringSword_AAA_C = "AM_Hun_SlitheringSword_AAA",
    GA_Hun_SlitheringSword_AABB_C = "AM_Hun_SlitheringSword_AABB", GA_Hun_SlitheringSword_AAB_C = "AM_Hun_SlitheringSword_AAB",
    GA_Hun_SlitheringSword_AA_C = "AM_Hun_SlitheringSword_AA", GA_Hun_SlitheringSword_ABB_C = "AM_Hun_SlitheringSword_ABB",
    GA_Hun_SlitheringSword_AB_C = "AM_Hun_SlitheringSword_AB", GA_Hun_SlitheringSword_A_C = "AM_Hun_SlitheringSword_A1",
    GA_Hun_SlitheringSword_A_DashDraw_C = "AM_Hun_SlitheringSword_A_DashDraw",
    GA_Hun_SlitheringSword_A_Dash_C = "AM_Hun_SlitheringSword_A_Dash", GA_Hun_SlitheringSword_BBB_C = "AM_Hun_SlitheringSword_BBB",
    GA_Hun_SlitheringSword_BB_C = "AM_Hun_SlitheringSword_BB", GA_Hun_SlitheringSword_B_C = "AM_Hun_SlitheringSword_B",
    GA_Hun_SlitheringSword_B_DashDraw_C = "AM_Hun_SlitheringSword_B_DashDraw",
    GA_Hun_SlitheringSword_B_Dash_C = "AM_Hun_SlitheringSword_B_Dash", GA_Hun_SlitheringSword_C_C = "AM_Hun_SlitheringSword_C_Normal",
    GA_Hun_SlitheringSword_DA_C = "AM_Hun_SlitheringSword_DA_Start",
    GA_Hun_SlitheringSword_DB4_C = "Hun_SoftSword_Stance_Attack_07_Montage",
    GA_Hun_SlitheringSword_DB5_C = "Hun_SoftSword_Stance_Attack_06_Montage",
    GA_Hun_SlitheringSword_EvalutionCombo_New_C = "Hun_SoftSword_Attack_01_Montage",
    GA_Hun_SlitheringSword_Potential_C = "Hun_SoftSword_Skill_03_Montage", GA_Hun_SlitheringSword_SWT_C = "AM_Hun_SlitheringSword_SWT",
    GA_Hun_SnakeDual_AAA_C = "AM_Hun_SnakeDual_AAA", GA_Hun_SnakeDual_AA_C = "AM_Hun_SnakeDual_AA",
    GA_Hun_SnakeDual_ABAA_C = "AM_Hun_SnakeDual_BA2", GA_Hun_SnakeDual_ABABAA_C = "AM_Hun_SnakeDual_AAAA",
    GA_Hun_SnakeDual_ABABA_C = "AM_Hun_SnakeDual_AA", GA_Hun_SnakeDual_ABABB_C = "AM_Hun_SnakeDual_BBBB",
    GA_Hun_SnakeDual_ABAB_C = "AM_Hun_SnakeDual_BABB", GA_Hun_SnakeDual_ABA_C = "AM_Hun_SnakeDual_AB2",
    GA_Hun_SnakeDual_ABB_C = "AM_Hun_SnakeDual_BB", GA_Hun_SnakeDual_AB_C = "AM_Hun_SnakeDual_AB1",
    GA_Hun_SnakeDual_A_C = "AM_Hun_SnakeDual_A", GA_Hun_SnakeDual_A_Dash_C = "AM_Hun_SnakeDual_A_Dash",
    GA_Hun_SnakeDual_A_Fast_C = "AM_Hun_SnakeDual_A", GA_Hun_SnakeDual_Air_A_Double_C = "Hun_Tang_JumpAttackB_Montage",
    GA_Hun_SnakeDual_Air_A_Draw_Double_C = "Hun_Tang_JumpAttackB_Montage",
    GA_Hun_SnakeDual_Air_B_Double_C = "Hun_Double_JumpAttackA_Montage",
    GA_Hun_SnakeDual_Air_B_Draw_Double_C = "Hun_Double_JumpAttackA_Montage", GA_Hun_SnakeDual_BAA_C = "AM_Hun_SnakeDual_BAA",
    GA_Hun_SnakeDual_BABAA_C = "AM_Hun_SnakeDual_BABA", GA_Hun_SnakeDual_BABABB_C = "AM_Hun_SnakeDual_BBBBB",
    GA_Hun_SnakeDual_BABAB_C = "AM_Hun_SnakeDual_BA1", GA_Hun_SnakeDual_BABA_C = "AM_Hun_SnakeDual_BAB",
    GA_Hun_SnakeDual_BABB_C = "AM_Hun_SnakeDual_BBBB", GA_Hun_SnakeDual_BAB_C = "AM_Hun_SnakeDual_BBB",
    GA_Hun_SnakeDual_BA_C = "AM_Hun_SnakeDual_AAA", GA_Hun_SnakeDual_BB_C = "AM_Hun_SnakeDual_BB",
    GA_Hun_SnakeDual_B_C = "AM_Hun_SnakeDual_B", GA_Hun_SnakeDual_B_Dash_C = "AM_Hun_SnakeDual_B_Dash",
    GA_Hun_SnakeDual_B_Fast_C = "AM_Hun_SnakeDual_B", GA_Hun_SnakeDual_C_C = "AM_Hun_SnakeDual_C",
    GA_Hun_SnakeDual_DA_C = "AM_Hun_SnakeDual_AA", GA_Hun_SnakeDual_DB_C = "AM_Hun_SnakeDual_BBBB",
    GA_Hun_SnakeDual_SWT_C = "AM_Hun_SnakeDual_SWT", GA_Hun_Tang_A_DashDraw_C = "AM_Hun_Tang_A_DashDraw",
    GA_Hun_Tang_Air_A_C = "Hun_Tang_JumpAttackB_Montage", GA_Hun_Tang_Air_A_Draw_C = "Hun_Tang_JumpAttackB_Montage",
    GA_Hun_Tang_Air_B_C = "Hun_Tang_JumpAttackA_Montage", GA_Hun_Tang_Air_B_Draw_C = "Hun_Tang_JumpAttackA_Montage",
    GA_Hun_Tang_B_DashDraw_C = "AM_Hun_Tang_B_DashDraw", GA_Hun_Tang_B_Draw_C = "AM_Hun_Tang_B_Draw",
    GA_Hun_Tang_SWT_UI_C = "AM_Hun_Tang_A_Draw", GA_Hun_WoodenSword_AAAAA_C = "Hun_WoodenSword_Light_AAAAA_Montage",
    GA_Hun_WoodenSword_AAAA_C = "Hun_WoodenSword_Light_AAAA_Montage", GA_Hun_WoodenSword_AAABB_C = "Hun_WoodenSword_AAABB_Montage",
    GA_Hun_WoodenSword_AAAB_C = "Hun_WoodenSword_AAAB_Montage", GA_Hun_WoodenSword_AAA_C = "Hun_WoodenSword_Light_AAA_Montage",
    GA_Hun_WoodenSword_AABB_C = "Hun_WoodenSword_AABB_Montage", GA_Hun_WoodenSword_AAB_C = "Hun_WoodenSword_AAAB_Montage",
    GA_Hun_WoodenSword_AA_C = "Hun_WoodenSword_Light_AA_Montage", GA_Hun_WoodenSword_ABB_C = "Hun_Young_AB_Montage",
    GA_Hun_WoodenSword_AB_C = "Hun_WoodenSword_ABB_Montage", GA_Hun_WoodenSword_A_C = "Hun_WoodenSword_Light_A_Montage",
    GA_Hun_WoodenSword_A_DashDraw_C = "Hun_WoodenSword_A_Dash_Montage", GA_Hun_WoodenSword_A_Dash_C = "Hun_WoodenSword_A_Dash_Montage",
    GA_Hun_WoodenSword_A_Draw_C = "Hun_WoodenSword_Light_A_Draw_Placeholder_Montage",
    GA_Hun_WoodenSword_Air_A_C = "Hun_WoodenSword_Tang_JumpAttackB_Montage",
    GA_Hun_WoodenSword_Air_A_Draw_C = "Hun_WoodenSword_Tang_JumpAttackB_Montage",
    GA_Hun_WoodenSword_Air_B_C = "Hun_WoodenSword_Tang_JumpAttackA_Montage",
    GA_Hun_WoodenSword_Air_B_Draw_C = "Hun_WoodenSword_Tang_JumpAttackA_Montage", GA_Hun_WoodenSword_BBB_C = "Hun_WoodenSword_BBB_Montage",
    GA_Hun_WoodenSword_BB_C = "Hun_WoodenSword_BB_Montage", GA_Hun_WoodenSword_B_C = "Hun_WoodenSword_B_Montage",
    GA_Hun_WoodenSword_B_DashDraw_C = "Hun_WoodenSword_B_DashDraw_Montage", GA_Hun_WoodenSword_B_Dash_C = "Hun_WoodenSword_B_Dash_Montage",
    GA_Hun_WoodenSword_B_Draw_C = "Hun_WoodenSword_B_Draw_Montage", GA_Hun_WoodenSword_C_C = "Hun_MaleThug_UniqueSkill_Montage",
    GA_Hun_WoodenSword_SWT_New_C = "AM_Hun_Tang_A_DashDraw", GA_Hun_XieShan_AAAAA_C = "Hun_ShanZi_AAAAA_Montage",
    GA_Hun_XieShan_AAAA_C = "Hun_ShanZi_AAAA_Montage", GA_Hun_XieShan_AAABB_C = "Hun_ShanZi_AAABB_Montage",
    GA_Hun_XieShan_AAAB_C = "Hun_ShanZi_AAAB_Montage", GA_Hun_XieShan_AAA_C = "Hun_ShanZi_AAA_Montage",
    GA_Hun_XieShan_AABB_C = "Hun_ShanZi_AABB_Montage", GA_Hun_XieShan_AAB_C = "Hun_ShanZi_AAB_Montage",
    GA_Hun_XieShan_AA_C = "Hun_ShanZi_AA_Montage", GA_Hun_XieShan_ABB_C = "Hun_ShanZi_ABB_Montage",
    GA_Hun_XieShan_AB_C = "Hun_ShanZi_AB_Montage", GA_Hun_XieShan_A_C = "Hun_ShanZi_A_Montage",
    GA_Hun_XieShan_A_DashDraw_New_C = "Hun_ShanZi_Dash_A_Montage", GA_Hun_XieShan_A_Dash_C = "Hun_ShanZi_Dash_A_Montage",
    GA_Hun_XieShan_A_Draw_New_C = "Hun_ShanZi_A_Montage", GA_Hun_XieShan_BBB_C = "Hun_ShanZi_BBB_Montage",
    GA_Hun_XieShan_BB_C = "Hun_ShanZi_BB_Montage", GA_Hun_XieShan_B_C = "Hun_ShanZi_B_Montage",
    GA_Hun_XieShan_B_DashDraw_New_C = "Hun_ShanZi_Dash_B_Montage", GA_Hun_XieShan_B_Dash_C = "Hun_ShanZi_Dash_B_Montage",
    GA_Hun_XieShan_B_Draw_New_C = "Hun_ShanZi_B_Montage", GA_Hun_XieShan_C_C = "Hun_ShanZi_Unique_Skill_Montage",
    GA_Hun_XieShan_DB_C = "Hun_ShanZi_Skill_05_Montage", GA_Hun_XieShan_SWT_02_C = "Hun_YuuBlade_Unique_Skill_03_Montage",
    GA_Hun_YanYueDao_AAAA_C = "Hun_YanYueDao_Attack_AAAA_Montage", GA_Hun_YanYueDao_AAA_C = "Hun_YanYueDao_Attack_AAA_Montage",
    GA_Hun_YanYueDao_AA_C = "Hun_YanYueDao_Attack_AA_Montage", GA_Hun_YanYueDao_A_C = "Hun_YanYueDao_Attack_A_Montage",
    GA_Hun_YanYueDao_A_Dash_C = "Hun_YanYueDao_Dash_A_Montage", GA_Hun_YanYueDao_BB_C = "Hun_YanYueDao_Attack_BB_Montage",
    GA_Hun_YanYueDao_B_C = "Hun_YanYueDao_Attack_B_Montage", GA_Hun_YanYueDao_B_Dash_C = "Hun_YanYueDao_Dash_B_Montage",
    GA_Hun_YanYueDao_B_Reinforced_C = "RTG_HUN_YuDing_Skill_05_FullEnd", GA_Hun_YanYueDao_C_C = "Hun_YanYueDao_Skill_03_Start_Montage",
    GA_Hun_YanYueDao_SWT_C = "Hun_YanYueDao_SimpleExE_Multi_01_Montage",
    GA_Hun_YanYueDao_SpecialSkill_C = "Hun_YanYueDao_Skill_01_A_Montage", GA_Hun_YuuBlade_AAAAA_C = "Hun_YuuBlade_AAAAAA_Montage",
    GA_Hun_YuuBlade_AAAAB_C = "Hun_YuuBlade_BBBB_Montage", GA_Hun_YuuBlade_AAAA_C = "Hun_YuuBlade_BBB_Montage",
    GA_Hun_YuuBlade_AAAB_C = "Hun_YuuBlade_AB_Montage", GA_Hun_YuuBlade_AAA_C = "Hun_YuuBlade_B_Montage",
    GA_Hun_YuuBlade_AAB_C = "Hun_YuuBlade_AAA_Montage", GA_Hun_YuuBlade_AA_C = "Hun_YuuBlade_AA_Montage",
    GA_Hun_YuuBlade_AB_C = "Hun_YuuBlade_BB_Montage", GA_Hun_YuuBlade_A_C = "Hun_YuuBlade_A_Montage",
    GA_Hun_YuuBlade_A_DashDraw_C = "Hun_YuuBlade_Dash_A_Montage", GA_Hun_YuuBlade_A_Dash_C = "Hun_YuuBlade_Dash_A_Montage",
    GA_Hun_YuuBlade_A_Draw_C = "Hun_YuuBlade_A_Montage", GA_Hun_YuuBlade_BBBB_C = "Hun_YuuBlade_AABB_Montage",
    GA_Hun_YuuBlade_BBB_C = "Hun_YuuBlade_AAAAAB_Montage", GA_Hun_YuuBlade_BB_C = "Hun_YuuBlade_AAAAA_Montage",
    GA_Hun_YuuBlade_B_C = "Hun_YuuBlade_ABB_Montage", GA_Hun_YuuBlade_B_DashDraw_C = "Hun_YuuBlade_Dash_B_Montage",
    GA_Hun_YuuBlade_B_Dash_C = "Hun_YuuBlade_Dash_B_Montage", GA_Hun_YuuBlade_B_Draw_C = "Hun_YuuBlade_ABB_Montage",
    GA_Hun_YuuBlade_C_C = "Hun_YuuBlade_Buff_Montage", GA_Hun_YuuBlade_FastHeavyAttack_C = "Hun_YuuBlade_Heavy_QuickSlash_Montage",
    GA_Hun_YuuBlade_FastLightAttack_C = "Hun_YuuBlade_Light_QuickSlash_Montage",
    GA_Hun_YuuBlade_SWT_C = "Hun_YuuBlade_Unique_Skill_03_Montage", GA_Hun_ZhanMa_AAAA_C = "Hun_WangMingZhanMaDao_Attack_AAAA_Montage",
    GA_Hun_ZhanMa_AAAB_C = "Hun_WangMingZhanMaDao_Attack_AAAB_Montage", GA_Hun_ZhanMa_AAA_C = "Hun_WangMingZhanMaDao_Attack_AAA_Montage",
    GA_Hun_ZhanMa_AAB_C = "Hun_WangMingZhanMaDao_Attack_AAB_Montage", GA_Hun_ZhanMa_AA_C = "Hun_WangMingZhanMaDao_Attack_AA_Montage",
    GA_Hun_ZhanMa_AB_C = "Hun_WangMingZhanMaDao_Attack_AB_Montage", GA_Hun_ZhanMa_A_C = "Hun_WangMingZhanMaDao_Attack_A_Montage",
    GA_Hun_ZhanMa_A_DashDraw_C = "Hun_Horizontal_A_Dash_Montage", GA_Hun_ZhanMa_A_Dash_C = "Hun_Horizontal_A_Dash_Montage",
    GA_Hun_ZhanMa_A_Draw_C = "Hun_WangMingZhanMaDao_Attack_A_Montage", GA_Hun_ZhanMa_Air_A_C = "Hun_Long_JumpAttackA_Montage",
    GA_Hun_ZhanMa_Air_A_Draw_C = "Hun_Long_JumpAttackA_Montage", GA_Hun_ZhanMa_Air_B_C = "Hun_Long_JumpAttackB_Montage",
    GA_Hun_ZhanMa_Air_B_Draw_C = "Hun_Long_JumpAttackB_Montage", GA_Hun_ZhanMa_BB_C = "Hun_WangMingZhanMaDao_Attack_BB_Montage",
    GA_Hun_ZhanMa_B_C = "Hun_WangMingZhanMaDao_Attack_B_Montage", GA_Hun_ZhanMa_B_DashDraw_C = "Hun_Horizontal_B_DashDraw_Montage",
    GA_Hun_ZhanMa_B_Dash_C = "Hun_Horizontal_B_Dash_Fixed_Montage", GA_Hun_ZhanMa_B_Draw_C = "Hun_WangMingZhanMaDao_Attack_B_Montage",
    GA_Hun_ZhanMa_C_C = "Hun_WangMingZhanMaDao_Unique_Skill_02_Montage", GA_Hun_ZhanMa_DB_C = "Hun_WangMingZhanMaDao_Skill_02_Montage",
    GA_Hun_ZhanMa_SA_C = "Hun_WangMingZhanMaDao_Skill_03_Montage", GA_Hun_ZhanMa_SWT_C = "Hun_Horizontal_SWT_Montage",
    GA_Hun_ZiMingJian_New_AAAAA_C = "Hun_ZiMing_AAAAA", GA_Hun_ZiMingJian_New_AAAA_C = "Hun_ZiMing_AAAA",
    GA_Hun_ZiMingJian_New_AAABB_C = "Hun_ZiMing_AAABB", GA_Hun_ZiMingJian_New_AAAB_C = "Hun_ZiMing_AAAB",
    GA_Hun_ZiMingJian_New_AAA_C = "Hun_ZiMing_AAA", GA_Hun_ZiMingJian_New_AABB_C = "Hun_ZiMing_AABB",
    GA_Hun_ZiMingJian_New_AAB_C = "Hun_ZiMing_AAB", GA_Hun_ZiMingJian_New_AA_C = "Hun_ZiMing_AA",
    GA_Hun_ZiMingJian_New_ABB_C = "Hun_ZiMing_ABB", GA_Hun_ZiMingJian_New_AB_C = "Hun_ZiMing_AB",
    GA_Hun_ZiMingJian_New_A_C = "Hun_ZiMing_A", GA_Hun_ZiMingJian_New_A_DashDraw_C = "Hun_ZiMing_A_Dash",
    GA_Hun_ZiMingJian_New_A_Dash_C = "Hun_ZiMing_A_Dash", GA_Hun_ZiMingJian_New_A_Draw_C = "Hun_ZiMing_A",
    GA_Hun_ZiMingJian_New_BBB_C = "Hun_ZiMing_BBB", GA_Hun_ZiMingJian_New_BB_C = "Hun_ZiMing_BB",
    GA_Hun_ZiMingJian_New_B_C = "Hun_ZiMing_B", GA_Hun_ZiMingJian_New_B_DashDraw_C = "Hun_ZiMing_B_Dash",
    GA_Hun_ZiMingJian_New_B_Dash_C = "Hun_ZiMing_B_Dash", GA_Hun_ZiMingJian_New_B_Draw_C = "Hun_ZiMing_B",
    GA_Hun_ZiMingJian_New_CCC_C = "Hun_ZiMing_Unique_Skill_B_Montage", GA_Hun_ZiMingJian_New_CC_C = "Hun_ZiMing_Unique_Skill_A_Montage",
    GA_Hun_ZiMingJian_New_C_C = "Hun_ZiMing_Unique_Skill_Montage", GA_Hun_ZiMingJian_New_DB_C = "Hun_ZiMing_Summon_Start_Montage",
    GA_Hun_ZiMingJian_New_SWT_Power_C = "Hun_ZiMing_SWT_Power", GA_JinGua_Air_C = "Hun_ShaChi_JinGua_SpecialAttack_08_Montage",
    GA_JinGua_ExtraAttack_C = "Hun_ShaChi_JinGua_Skill_05_Montage", GA_JinGua_Normal_C = "Hun_ShaChi_JinGua_SpecialAttack_03_Montage",
    GA_JinGua_RoAttack_C = "Hun_ShaChi_JinGua_Skill_06_Start_Montage", GA_LionHead_C = "AM_Hun_LionHead_Start_1",
    GA_LionHead_Dash_C = "Hun_LionDancer_Skill_02_Montage", GA_LionHead_DoubleFireBall_C = "Hun_LionDancer_Skill_01_Montage",
    GA_LionHead_FireBall_C = "Hun_LionDancer_Skill_01_Montage", GA_Lute_Dash_C = "Hun_ShaChi_Lute_Dash_B_Montage",
    GA_MiaoShouFeiDao_DB_C = "AM_Hun_Unarm_Dash_F", GA_MiaoShouFeiDao_Escape_01_C = "Hun_ShaChi_MiaoShouFeiDao_SpecialAttack_B_Montage",
    GA_MiaoShouFeiDao_Escape_02_C = "Hun_ShaChi_MiaoShouFeiDao_SpecialAttack_B_Montage",
    GA_MiaoShouFeiDao_Escape_03_C = "Hun_ShaChi_MiaoShouFeiDao_SpecialAttack_B_Montage",
    GA_MiaoShouFeiDao_Normal_01_C = "Hun_FeiZei_ZongHuoZei_Attack_01_Montage",
    GA_MiaoShouFeiDao_Normal_02_C = "Hun_FeiZei_NiShuiZei_Attack_01_Montage",
    GA_MiaoShouFeiDao_Normal_03_C = "Hun_FeiZei_NiShuiZei_Attack_01_Montage", GA_TanLang_ExtraAttack_C = "Hun_LangYa_Skill_01_A_Montage",
    GA_TanLang_Normal_C = "Hun_LangYa_Skill_01_Start_Montage", GA_TanLang_SpeicalAttack_C = "Hun_LangYa_Skill_02_Montage",
    GA_ThunderSpear_Dash_C = "Hun_ShaChi_LeiTingQiang_Skill_05_Montage",
    GA_ThunderSpear_DeflectCounter_C = "SpearMan_SpecialAttack_08_BanBen1_Montage",
    GA_ThunderSpear_DodgeAttack_01_C = "Hun_ShaChi_LeiTingQiang_Skill_04_Montage",
    GA_ThunderSpear_Normal_01_C = "Hun_ShaChi_LeiTingQiang_Skill_01_Montage",
    GA_ThunderSpear_Normal_02_C = "Hun_ShaChi_LeiTingQiang_Skill_02_Montage",
    GA_ThunderSpear_Normal_03_C = "Hun_ShaChi_LeiTingQiang_Skill_03_Montage",
    GA_ThunderSpear_SpecialAttack_04_C = "Hun_ShaChi_LeiTingQiang_Skill_06_BanBen01_Montage",
    GA_TieKuangQuanTao_Charge_AAA_C = "Hun_QuanTao_Attack_AAA_Montage", GA_TieKuangQuanTao_Charge_AA_C = "Hun_QuanTao_Attack_AA_Montage",
    GA_TieKuangQuanTao_Charge_A_C = "Hun_QuanTao_Attack_A_Montage", GA_TigerCannon_C = "AM_Hun_TigerCannon_Prepare",
    GA_TigerCannon_Dash_C = "Hun_ShaChi_DonCanon_SpecialSkill_01_Montage", GA_TigerCannon_Ultimate_C = "LeiDang_CriticalArt_02_Montage",
    GA_UnnamedBow_C = "AM_Hun_UnnamedBow_Charge", GA_UnnamedBow_Dash_C = "ArrowMan_DuYan_SpecialAttack_04_B_Montage",
    GA_UnnamedBow_DeflectCounter_C = "ArrowMan_DuYan_SpecialAttack_04_B_Montage", GA_XuKongHuaShan_Reborn_C = "AM_Hun_Tang_DF_L_ForReborn",
    GA_XuKongHuaShan_Skill_C = "Hun_Shaqi_ShanZi_Skill_01_Montage", GA_XueDiZi_AAA_C = "Hun_ShaChi_XueDiZi_Skill_01_C_Montage",
    GA_XueDiZi_AA_C = "Hun_ShaChi_XueDiZi_Skill_01_B_Montage", GA_XueDiZi_A_C = "Hun_ShaChi_XueDiZi_Skill_01_A1_Montage",
    GA_XueDiZi_EvolutionAttack_C = "Hun_ShaChi_XueDiZi_Variants_Skill_01_Montage",
    GA_XueDiZi_SpecialAttack_C = "Hun_ShaChi_XueDiZi_Skill_02_Montage", GA_YouLongCha_Dash_C = "Hun_ShaChi_YouLongCha_Skill_02_Montage",
    GA_YouLongCha_Normal_C = "Hun_ShaChi_YouLongCha_Attack_Montage",
    GA_YouLongHead_WaterCannon_C = "Hun_ShaChi_YouLongTou_Skill_01_Start_Montage",
    GA_YouLongHead_Water_C = "Hun_ShaChi_YouLongTou_Skill_01_Start_Montage", GA_ZhuoBiDun_C = "Hun_ShaChi_ZhuoBiDun_Entry_Montage",
    GA_ZhuoBiDun_Slide_C = "Hun_ShaChi_ZhuoBiDun_Skill_03_Montage",
}
-- §165.2 END

-- 受击 / 格挡 / 破防 / 闪避不是这一招的动作，不学
function ANIM.learn(ga, mon)
    if not (ga and mon and mon ~= "") then return end
    for _, k in ipairs({ "_Hit_", "Deflect", "MoTian_Dodge", "_Dead_" }) do
        if mon:find(k, 1, true) then return end
    end
    ANIM.map[ga] = mon
end

function ANIM.expect(ga) return ANIM.map[ga] or ANIM.SEED[ga] or ANIM.SEED2[ga] end

function ANIM.log(fmt, ...)
    ANIM.logs = ANIM.logs + 1
    if ANIM.logs <= ANIM.LOGS or ANIM.logs % 20 == 0 then out(fmt, ...) end
end

-- AIR.fire 放成功后：before = 放之前替身在播的动作名
function ANIM.afterFire(pup, e, before, tn)
    if not isAttackAbility(e.name) or e.name:find("_Air", 1, true) or CHG.isHold(e.name) then ANIM.pend = nil; return end
    ANIM.pend = { pup = pup, name = e.name, id = e.id, before = before, at = tn, stage = 1,
                  gentle = ANIM.isGentle(e.name) }    -- §243 切刀斩 / §345 断肢锯冲刺攻击：不取消真技能
end

-- 每次驱动：到点看一眼（没有等着的就什么都不读）
function ANIM.step(tn)
    local p = ANIM.pend
    if not p or tn - p.at < (p.gentle and ANIM.SWT_CHECK or ANIM.CHECK) then return end
    if not valid(p.pup) then ANIM.pend = nil; return end
    local an, _, name, pos = LAT.activeMontage(p.pup)
    if an and name and (name ~= p.before or (pos and pos < ANIM.FRESH)) then
        ANIM.pend = nil
        if p.stage == 1 then ANIM.st.ok = ANIM.st.ok + 1; ANIM.learn(p.name, name); return end
        ANIM.st.retryOk = ANIM.st.retryOk + 1
        ANIM.learn(p.name, name)
        ANIM.log("  ◇ 远端#%d %s 重放后换上了 %s", p.id, p.name, name)
        return
    end
    local alive = (activeAbilities(p.pup) or {})[p.name]
    if p.gentle then
        -- §243 切刀斩（*_SWT）：18:23:58 实测技能放出来了、追帧也看到 Hun_QingTongJian_Attack_SWT_Montage 从 0.00 跳到 0.10，
        -- 0.25 秒后 ANIM 只因为这一帧读不到动作就 cutMontage + G.cancelMoves + 重放（重放时又 swtPin 换了一次武器），
        -- 把已经放出来的技能顶掉，最后直接播蒙太奇——用户看到"有动作没伤害"。
        -- 现在：技能还挂着就不取消、不重放，等动作自己出现（最多 SWT_MAX）；技能已经结束且没动作才播蒙太奇兜底。
        local want = ANIM.expect(p.name)
        if alive then
            if tn - p.at > ANIM.SWT_MAX then
                ANIM.pend = nil
                ANIM.log("  §243 慢起手招 远端#%d %s 技能还在、动作读不到 %.2f 秒 → 不取消（让技能自己出判定）", p.id, p.name, tn - p.at)
            end
            return
        end
        ANIM.pend = nil
        if not want then ANIM.st.ended = ANIM.st.ended + 1; return end
        local okP = playNamed(p.pup, want)
        if okP then ANIM.st.playOk = ANIM.st.playOk + 1 else ANIM.st.fail = ANIM.st.fail + 1 end
        -- 不重复计入 FIREK：技能本身已经按 real 计过，这里只是动作补播
        ANIM.log("  §243 慢起手招 远端#%d %s 技能已经结束、动作还是没有 → 直接播 %s（兜底，只有画面）：%s",
            p.id, p.name, tostring(want), okP and "已播" or "失败")
        return
    end
    if not alive then        -- 招已经收了（短招、被打断）
        ANIM.pend = nil
        if p.stage == 1 then ANIM.st.ended = ANIM.st.ended + 1
        else ANIM.st.fail = ANIM.st.fail + 1; ANIM.log("  ◇ 远端#%d %s 重放后技能没挂上，动作也没有", p.id, p.name) end
        return
    end
    local want = ANIM.expect(p.name)
    if p.stage == 1 then
        ANIM.st.stuck = ANIM.st.stuck + 1
        if not want then
            ANIM.pend = nil
            if not ANIM.unknown[p.name] then
                ANIM.unknown[p.name] = true
                out("◇ 远端#%d %s 放成功 %.2f 秒，替身动作还是 %s；不知道这招该播什么，不补", p.id, p.name, tn - p.at, tostring(name))
            end
            return
        end
        local cut = name and cutMontage(p.pup)
        local gone = G.cancelMoves(p.pup)
        -- §165.3 大招补放会再耗一格充能，替身只有 1 格 → 播 C_Failed（黑魔伤 C1 实测）；补放前再补一格
        -- §165.7 只补"对方确认放成功、发来过的那一招"，每个招式号只补一次（ULT.okFor）
        if ULT.isUlt(p.name) then
            if ULT.okFor(p.id, p.name) then ULT.topUp(p.pup)
            else ANIM.pend = nil; out("◇ 远端#%d %s 不是对方确认过的大招，不补放", p.id, p.name); return end
        end
        local ok = RECM.activateOnPuppet(p.pup, p.name, NET.sub, "补放 远端#" .. p.id)
        ANIM.log("◇ 远端#%d %s 放成功 %.2f 秒，替身动作还是 %s（该是 %s）：停掉 %s、取消 %s，重放 %s", p.id, p.name, tn - p.at,
            tostring(name), want, tostring(cut), #gone > 0 and table.concat(gone, ",") or "无", ok and "成功" or "失败")
        if ok then p.stage, p.at, p.before = 2, tn, nil; return end
    end
    ANIM.pend = nil       -- 重放也没换上（或重放失败）：直接播
    local okP = playNamed(p.pup, want)
    if okP then ANIM.st.playOk = ANIM.st.playOk + 1 else ANIM.st.fail = ANIM.st.fail + 1 end
    ANIM.log("  ◇ 远端#%d %s 还是没动作 → 直接播 %s：%s", p.id, p.name, want, okP and "已播" or "失败")
end

function ANIM.report()
    local s = ANIM.st
    if s.stuck == 0 then return end
    out("      放招没换动作 %d 次（正常 %d，招自己收了 %d）：重放补上 %d，直接播 %d，没补上 %d", s.stuck, s.ok, s.ended,
        s.retryOk, s.playOk, s.fail)
end

-- 判定窗口跟着替身的动作（v0.27.1，§78.5）：炽刃大招出手 2–3.8 秒后才扣血，1.2 秒的窗口把它判成落空。
-- 过了 JUDGE_WIN、替身还在播为这一招开的蒙太奇（LAT.byId 记的那个）就继续等，最多 JUDGE_MAX 秒
LAT.JUDGE_MAX = 5.0
function LAT.stillPlaying(id, age, pupMontage)
    local want = LAT.byId[id]
    return want ~= nil and age < LAT.JUDGE_MAX and want == pupMontage
end

return { ANIM = ANIM, stillPlaying = LAT.stillPlaying }
end
