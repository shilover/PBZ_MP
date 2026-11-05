-- 由 tools/gen_places.py 从游戏文件生成，不要手改（游戏大版本更新后重跑）。
-- regions：关卡名小写 → { 中文, 英文 } 大区域名（DT_MapData 的 MapName）
-- bells：钟（传送点）{ x, y, z, 中文, 英文 }，世界坐标（DT_BellData），地名来自 Game.locres
return {
  regions = {
    pbz_dengdingshandao_wp = { "枷笼山", "MOUNTAIN OF IMPRISONMENT" },
    pbz_duanhun_wp = { "断魂山", "MOUNT SOULREND" },
    pbz_fujizhilin_wp = { "血色森林", "CRIMSON FOREST" },
    pbz_xigu_wp = { "悲泣溪谷", "WEEPING CREEK VALLEY" },
    pbz_pangzhen_wp = { "庞镇地区", "PANGZHEN" },
    pbz_houjie_wp = { "庞镇地区", "PANGZHEN" },
    pbz_ximeng_wp = { "戏梦山庄", "MIRAGE ESTATE" },
    pbz_huanshuyiji2_wp = { "梅谷湖", "MEIGU LAKE" },
    pbz_zhengdaodaying_wp = { "正道大营", "MANDATE ENCAMPMENT" },
  },
  bells = {
    { 4945, 280573, -32641, "锈刃凉亭", "Rustblade Pavilion" },  -- Bell_NLES_002
    { -24900, 290350, -26580, "驿站", "Outpost" },  -- Bell_NLES_003
    { -41610, 266596, -25230, "溪谷平原入口", "Creek Valley Plains Entrance" },  -- Bell_NLES_004
    { -59904, 235364, -20668, "溪谷杀气塔一层", "Valley Sha-Chi Tower 1st Floor" },  -- Bell_NLES_005
    { -61876, 222885, -15848, "远眺龙柱处", "Lóng Pillar Overlook" },  -- Bell_NLES_006
    { -52359, 227135, -20715, "大瀑布", "Great Waterfall" },  -- Bell_NLES_007
    { -58421, 196992, -17597, "悲泣溪谷龙柱", "Weeping Creek Lóng Pillar" },  -- Bell_NLES_DP_001
    { -36160, 234819, -21551, "圣母像山洞", "The Lady's Cave" },  -- Bell_NLES_010
    { -57816, 284076, -21237, "斧老大关押处", "The Axemaster's Holding Cell" },  -- Bell_NLES_011
    { -64852, 257374, -22083, "溪谷杀气塔顶", "Valley Sha-Chi Tower Summit" },  -- Bell_NLES_012
    { -64848, 219573, -11386, "红丝线障壁", "Red Thread Barrier" },  -- Bell_NLES_013
    { -11137, 282425, -28477, "圣母像裂缝", "The Lady's Rift" },  -- Bell_NLES_014
    { 9443, 288850, -31437, "残偶谷底", "Broken Puppet Valley" },  -- Bell_NLES_015
    { -4124, 294281, -29340, "溪谷杀气塔底", "Valley Sha-Chi Tower Base" },  -- Bell_NLES_016
    { -62272, 221490, -19123, "血肉花田", "Flesh Lily Fields" },  -- Bell_NLES_017
    { -71223, 210868, -19561, "瀑布吊桥", "Waterfall Bridge" },  -- Bell_NLES_018
    { -55527, 213608, -15827, "恶弓手营地", "Ruthless Archer Camp" },  -- Bell_NLES_019
    { -73233, 231409, -16044, "驿站前小院", "Outpost Courtyard" },  -- Bell_NLES_020
    { -24566, 266865, -23614, "红房子", "Crimson Manor" },  -- Bell_NLES_021
    { -4089, 277254, -30487, "斧老大斩落处", "The Axemaster's Fall" },  -- Bell_NLES_023
    { -53239, 258612, -24594, "血色森林", "CRIMSON FOREST" },  -- Levelname_LZSJ_001
    { -71182, 186512, -2772, "荒废官道", "Abandoned Main Road" },  -- Bell_LZSJ_002
    { -98903, 190396, -548, "远眺庞镇之桥", "Pangzhen Bridge Overlook" },  -- Bell_LZSJ_003
    { -128997, 169891, -1464, "亡命徒陷阱", "Outlaw Trap" },  -- Bell_LZSJ_004
    { -78522, 171544, -122, "飞贼营地", "Thieves' Camp" },  -- Bell_LZSJ_005
    { -69921, 155621, -633, "人偶思乡之崖", "Cliff of Longing" },  -- Bell_LZSJ_006
    { -51458, 136650, 3333, "镜林入口", "Mirrorwood Entrance" },  -- Bell_LZSJ_007
    { -40546, 157510, 1493, "迷雾消散处", "Parting Mists" },  -- Bell_LZSJ_008
    { -15702, 196031, -2233, "镜林深处", "Mirrorwood Depths" },  -- Bell_LZSJ_009
    { -1325, 165270, -1277, "丝线缠绕的巨树", "Threadbound Great Tree" },  -- Bell_LZSJ_010
    { 12504, 155748, -1797, "镜林龙柱", "Mirrorwood Lóng Pillar" },  -- Bell_FJZL_DP_002
    { -25145, 156265, 2107, "岔路口", "Crossroads" },  -- Bell_LZSJ_011
    { -14954, 139930, -1531, "梦醒之地", "Place of Awakening" },  -- Bell_LZSJ_012
    { -2351, 146230, 859, "挂笼小道", "Trail of Cages" },  -- Bell_LZSJ_013
    { -105769, 156472, 6, "伏击林路", "Ambush Trail" },  -- Bell_LZSJ_014
    { -59597, 148689, 200, "湖岸拱桥", "Lakeside Arch Bridge" },  -- Bell_LZSJ_015
    { -54176, 157154, -1362, "赤蛇屋", "Red Serpent House" },  -- Bell_LZSJ_016
    { -62844, 144175, -840, "血色森林杀气塔大门", "Crimson Forest Sha-Chi Tower Gate" },  -- Bell_LZSJ_017
    { -41391, 179640, 2116, "血色森林杀气塔底", "Crimson Forest Sha-Chi Tower Base" },  -- Bell_LZSJ_018
    { -44937, 180481, -2198, "血色森林杀气塔六层", "Crimson Forest Sha-Chi Tower 6th Floor" },  -- Bell_LZSJ_019
    { -44879, 176470, 5926, "遗冢地", "Burial Grounds" },  -- Bell_LZSJ_021
    { -28236, 172240, 630, "三人偶水井", "Well of the Three Puppets" },  -- Bell_SXC_01_01
    { -45397, 126148, -2882, "黑蛇屋", "Black Serpent House" },  -- Bell_SXC_01_02
    { -60182, 123185, -434, "残偶弃置坑口", "Broken Puppet Pit Entrance" },  -- Bell_SXC_01_03
    { -27576, 114525, -7536, "残偶弃置坑底", "Broken Puppet Pit Bottom" },  -- Bell_SXC_01_04
    { -47227, 104329, 846, "兰公子藏身处", "Young Master Lan's Hideout" },  -- Bell_SXC_01_07
    { -24294, 135717, -3688, "老根头藏身处", "Old Man Gen's Hideout" },  -- Bell_SXC_01_08
    { -22625, 125663, -3593, "机关巨怪残骸", "Engine Giant Remains" },  -- Bell_SXC_01_09
    { -42430, 92981, 3031, "梯田", "Terraces" },  -- Bell_SXC_01_10
    { -54021, 97431, 1130, "大廊桥", "Covered Bridge" },  -- Bell_SXC_01_11
    { -56329, 124708, -1207, "飞贼藏宝地窖", "Smuggler's Treasure Cellar" },  -- Bell_SXC_01_12
    { -53858, 101682, 590, "幸存者小院", "Survivors' Courtyard" },  -- Bell_SXC_01_13
    { -41698, 111881, -242, "幽蓝萤火之庙", "Temple of Blue Fireflies" },  -- Bell_SXC_01_14
    { -44089, 115648, -2396, "飞贼密道入口", "Smuggler's Tunnel Entrance" },  -- Bell_SXC_02_01
    { -55967, 103102, -1983, "通向庞镇的密道", "Hidden Passage to Pangzhen" },  -- Bell_SXC_02_02
    { -64432, 110328, -1430, "人偶试验场", "Puppet Testing Grounds" },  -- Bell_SXC_02_03
    { -63714, 86319, -5823, "夕阳小径", "Sunset Path" },  -- Bell_YXZR_001
    { -3510, 108109, 1537, "栈道入口", "Cliffside Walkway Entrance" },  -- Bell_YXZR_002
    { 3601, 87142, 4495, "乱葬岗", "Mass Grave" },  -- Bell_YXZR_003
    { -2174, 77991, 7876, "墨玑子衣冠冢", "Moji's Cenotaph" },  -- Bell_YXZR_004
    { 14107, 69330, 6393, "大营正门", "Main Encampment Gate" },  -- Bell_YXZR_005
    { 21081, 73068, 7164, "高塔后方出口", "Tower Rear Exit" },  -- Bell_YXZR_006
    { 29210, 71128, 6832, "大营瀑布后方", "Behind the Encampment Waterfall" },  -- Bell_YXZR_007
    { 44597, 68729, 9621, "通往校场的路", "Road to the Training Grounds" },  -- Bell_YXZR_009
    { 27862, 64529, 8878, "校场", "Training Grounds" },  -- Bell_YXZR_008
    { 32383, 59677, 8171, "幽禁之地", "The Confinement" },  -- Bell_YXZR_019
    { 70668, 65255, 11295, "鸽舍", "Dovecote" },  -- Bell_YXZR_011
    { 22216, 79381, 8432, "三高塔", "Three Towers" },  -- Bell_YXZR_012
    { 28841, 77067, 7799, "栈道眺望台", "Cliffside Walkway Overlook" },  -- Bell_YXZR_013
    { 6907, 79331, 7805, "战场遗迹", "Battlefield Ruins" },  -- Bell_YXZR_015
    { 14360, 83209, 6396, "箭塔之下", "Beneath the Watchtower" },  -- Bell_YXZR_016
    { 18039, 75909, 6374, "校场深处", "Training Grounds Depths" },  -- Bell_YXZR_017
    { 20221, 56585, 5904, "正道大营外门", "Mandate Encampment Outer Gate" },  -- Bell_YXZR_018
    { -11067, 128049, -1662, "白山派的覆灭之路", "Path of the Baishan's Fall" },  -- Bell_YXZR_010
    { 57899, 53979, 11342, "祭拜圣母之路", "The Lady's Path" },  -- Bell_DDSD_001
    { -89130, -47009, 13934, "铁杀营地", "Iron Butcher's Camp" },  -- Bell_DDSD_002
    { -69485, -43900, 14882, "囚笼洞口", "Hanging Cage Cavern" },  -- Bell_DDSD_003
    { -67184, -68173, 15703, "囚笼道", "Cavern Passage" },  -- Bell_DDSD_004
    { -65741, -64282, 19270, "横刀平台", "Commander's Platform" },  -- Bell_DDSD_005
    { -62016, -56023, 18282, "宗祠外山门", "Shrine Outer Gate" },  -- Bell_DDSD_006
    { -61474, -75381, 25145, "圣母娘娘宗祠", "The Lady's Shrine" },  -- Bell_DDSD_007
    { -59980, -93090, 29000, "人偶囚室", "Puppet Cell" },  -- Bell_JJYBP_007
    { -61348, -101338, 20877, "圣母娘娘宗祠", "The Lady's Shrine" },  -- Bell_DDSD_007
    { -160727, 128612, -1895, "南门廊桥", "South Gate Bridge" },  -- Bell_SZ_002
    { -160184, 145382, -8090, "市集", "Marketplace" },  -- Bell_SZ_003
    { -180938, 125045, -6120, "幻鬼酒馆", "Myst's Tavern" },  -- Bell_SZ_004
    { -191053, 122787, -4011, "后街牌坊", "Backstreet Archway" },  -- Bell_SZ_005
    { -206835, 133210, -6046, "后街乘凉处", "Backstreet Rest" },  -- Bell_SZ_006
    { -217748, 120620, -1994, "戏声缥缈的水塘", "Pond of Fading Song" },  -- Bell_SZ_007
    { -248837, 103353, -3598, "贫民窟", "Pangzhen Slums" },  -- Bell_SZ_008
    { -266717, 102496, -8297, "三船殉难井底", "Well of Wei Sanchuan" },  -- Bell_SZ_009
    { -243284, 97511, -4172, "青蛇屋", "Green Serpent House" },  -- Bell_SZ_010
    { -257247, 77702, -5766, "舞狮馆大门", "Lion Dance Hall" },  -- Bell_SZ_011
    { -269226, 60854, -6803, "玉儿家", "Yu'er's House" },  -- Bell_SZ_012
    { -249793, 42770, -6260, "庞镇船坞", "Pangzhen Docks" },  -- Bell_SZ_013
    { -162549, 96415, 872, "后山凉亭", "Back Hill Pavilion" },  -- Bell_SZ_014
    { -261990, 127983, -5338, "镇南水塘", "South Town Pond" },  -- Bell_SZ_015
    { -192466, 133856, -6656, "黄家宅邸前路口", "Huang Manor Crossroads" },  -- Bell_SZ_016
    { -171921, 120932, -4137, "八卦阁前路口", "Pavilion of Knowledge Crossroads" },  -- Bell_SZ_017
    { -174570, 112368, -3068, "正道临时居所", "Mandate Lodgings" },  -- Bell_SZ_018
    { -173184, 106134, 1251, "景炀轩", "Jingyang Hall" },  -- Bell_SZ_019
    { -175274, 133967, -6122, "庞镇杀气塔上部一层", "Pangzhen Sha-Chi Tower Upper Level 1" },  -- Bell_SZ_020
    { -177756, 85563, 4578, "尊主封印地", "The Sealed Lion" },  -- Bell_SZ_021
    { -271528, 46571, -3533, "庞镇杀气塔底部船坞", "Pangzhen Sha-Chi Tower Dock" },  -- Bell_SZ_022
    { -180699, 75408, 926, "祠堂广场", "Ancestral Shrine Square" },  -- Bell_SZ_023
    { -259416, 49062, -5143, "老根头家", "Old Man Gen's House" },  -- Bell_SZ_024
    { -263693, 93501, -4878, "舞狮馆深处", "Lion Dance Hall Depths" },  -- Bell_SZ_025
    { -269112, 50104, -3417, "秘密卸货处", "Hidden Storehouse" },  -- Bell_SZ_026
    { -158412, 122872, -2887, "庞镇杀气塔下部通道", "Pangzhen Sha-Chi Tower Lower Passage" },  -- Bell_SZ_027
    { -181535, 80353, 2722, "庞镇杀气塔下部外侧", "Pangzhen Sha-Chi Tower Lower Exterior" },  -- Bell_SZ_028
    { -175036, 71717, 4737, "庞镇杀气塔顶", "Pangzhen Sha-Chi Tower Summit" },  -- Bell_SZ_029
    { -175092, 74511, 10035, "庞镇杀气塔炉内", "Pangzhen Sha-Chi Tower Furnace" },  -- Bell_SZ_030
    { -228350, 110929, 1052, "码头货栈", "Dockside Warehouse" },  -- Bell_SZ_032
    { -167052, 102321, 2450, "庞镇小张藏身处", "Zhang's Hideout (Pangzhen)" },  -- Bell_PZ_XiaoZhang_003
    { -211117, 123768, -3426, "山庄后门", "Estate Rear Gate" },  -- Bell_XM_001
    { -229890, 55145, 13463, "灵堂", "Mourning Hall" },  -- Bell_XM_003
    { -211342, 73913, 6694, "冷荼书房", "Leng Tu's Study" },  -- Bell_XM_004
    { -209927, 101581, 3723, "戏梦山庄龙柱", "Mirage Estate Lóng Pillar" },  -- Bell_XM_DP_005
    { -230043, 83346, 7126, "圣躯府邸", "Perfect Vessel Estate" },  -- Bell_XM_014
    { -207283, 95403, 4268, "圣躯心池", "Perfect Vessel Pond" },  -- Bell_XM_007
    { -200452, 90552, 4401, "后山", "Back Hill" },  -- Bell_XM_010
    { -214049, 68532, 10097, "戏园", "Opera House" },  -- Bell_XM_011
    { -195831, 76381, 6598, "演武场", "Training Grounds" },  -- Bell_XM_012
    { -184998, 98092, 3139, "连廊", "Covered Corridor" },  -- Bell_XM_013
    { -215086, 84699, 6933, "戏梦山庄正门", "Mirage Estate" },  -- Bell_XM_015
    { -187916, 114639, -1057, "吹火楼下", "Below the Fire Tower" },  -- Bell_XM_020
    { -219380, 73706, 9950, "竹影道", "Shaded Bamboo Path" },  -- Bell_XM_021
    { -198776, 62628, 9448, "柳风亭", "Willow Pavilion" },  -- Bell_XM_022
    { -218158, 97408, 6553, "傩面祭台", "Nuo Mask Altar" },  -- Bell_XM_019
    { -229874, 67442, 15435, "湖中龙柱船坞", "Midlake Lóng Pillar Dock" },  -- Bell_MGH_DP_004
    { 14674, 26221, 722, "山神庙", "Mountain God Temple" },  -- Bell_LYZ_008
    { -194690, -42148, 27747, "冰湖船坞", "Frozen Lake Dock" },  -- Bell_LYZ_010
    { -175100, -1255, 963, "护法四像镜", "Four Guardians' Mirror" },  -- Bell_LYZ_011
    { -187062, -5863, 1873, "禁忌之径", "Forbidden Path" },  -- Bell_LYZ_013
    { -172800, -42852, 929, "白影陨落之处", "Whiteshadow's Fall" },  -- Bell_LYZ_014
    { -153202, -23842, 765, "陆家村小张藏身处", "Zhang's Hideout (Village of Lu)" },  -- Bell_LJC_XiaoZhang_002
    { -58333, 121767, -1512, "泣声传来的雾门", "Weeping Mistgate" },  -- Bell_MGH_001
    { -41689, -8254, 775, "独眼之岛船坞", "One-Eyed Isle Dock" },  -- Bell_MGH_003
    { -7644, -5350, 802, "梅谷乐坊船坞", "Meigu Songhouse Dock" },  -- Bell_MGH_004
    { -127148, 73265, 751, "湖中榕树船坞", "Lake Banyan Dock" },  -- Bell_MGH_005
    { -34098, 56048, 891, "水行帮船坞", "Blackwater Crew Dock" },  -- Bell_MGH_007
    { -107752, 5965, 899, "陆家村浅滩船坞", "Village of Lu Shallows Dock" },  -- Bell_MGH_008
    { -71240, 74912, 717, "白蛇屋", "White Serpent House" },  -- Bell_MGH_011
    { -51351, 15778, 2399, "梅谷村东岛船坞", "Meigu Village East Dock" },  -- Bell_MGH_012
    { -103082, 28191, 802, "银白之路", "Path of Silver" },  -- Bell_DH_001
    { -192128, -66153, 30933, "最后的正道营地", "The Last Mandate Encampment" },  -- Bell_DH_002
    { -200749, -83232, 36429, "巨物盘踞处", "The Giant's Lair" },  -- Bell_DH_010
    { -197828, -103288, 32073, "断魂崖", "Soulrend Cliff" },  -- Bell_DH_004
    { -193480, -103051, 61386, "寒崖冰窟", "Frostcliff Cavern" },  -- Bell_DH_006
    { -206602, -95319, 37424, "大梦倾颓处", "The Fallen Dream" },  -- Bell_DH_007
    { -192498, -112994, 62008, "最后的挽回之地", "The Last Chance" },  -- Bell_DH_008
    { -196920, -98839, 39746, "梅谷村小张藏身处", "Zhang's Hideout (Meigu Village)" },  -- Bell_MGXL_XiaoZhang_004
    { -129431, 33175, 1435, "人面榕树", "Human-Faced Banyan" },  -- Bell_DaRongShu_001
    { -66071, 82941, 927, "灭法之法", "The Acolytes" },  -- Bell_SXC_01_15
    { -198354, -20257, 15966, "幻术师遗迹", "Phantom Illusionist Ruins" },  -- BrokenBell_HSSYJ_01
    { -187849, -14596, 14649, "幻术师遗迹", "Phantom Illusionist Ruins" },  -- BrokenBell_HSSYJ_01
    { -189942, -8761, 2349, "幻术师遗迹", "Phantom Illusionist Ruins" },  -- BrokenBell_HSSYJ_01
    { -175751, -13490, 2213, "幻术师遗迹", "Phantom Illusionist Ruins" },  -- BrokenBell_HSSYJ_01
    { -173251, -43729, -1703, "幻术师遗迹", "Phantom Illusionist Ruins" },  -- BrokenBell_HSSYJ_01
    { -156400, -40489, -1198, "幻术师遗迹", "Phantom Illusionist Ruins" },  -- BrokenBell_HSSYJ_01
    { -178393, -25703, 2738, "庞镇杀气塔下部外侧", "Pangzhen Sha-Chi Tower Lower Exterior" },  -- Bell_SZ_028
    { -202734, 69648, 7440, "故屋幻景", "Phantom of The Old House" },  -- Bell_DH_012
    { -47835, 152968, 1717, "水井之下", "Beneath the Well" },  -- Bell_SXC_01_17
    { -52513, 75790, -6673, "雕像场前", "Statue Grounds Entrance" },  -- Bell_SXC_02_04
    { -49236, 107986, 339, "白蛇屋船坞", "White Serpent House Dock" },  -- Bell_MGH_013
    { -55225, 25278, 1059, "梅谷村西岛船坞", "Meigu Village West  Dock" },  -- Bell_MGH_014
  },
}
