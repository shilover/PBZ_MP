// 4net 服务器大厅：房间登记 / 列表 + UDP 打洞介绍 + 直连不通时的中转。
// 只用 Node 自带的 dgram，一个 UDP 端口干全部的事；不存盘，重启后房间由主机的心跳（每 2 秒一次）自己补回来。
// 许可证 AGPL-3.0（见 server/LICENSE），不提供任何担保。架这台服务器的人是服务运营者，自己负责当地合规（server/README.md）。
//
// node server/fornet-lobby-server.mjs [--port 27020] [--host ::] [--relay] [--quiet] [--upstream 域名或IP:端口 …]
// 环境变量 PORT / HOST / RELAY=1 也行。--upstream 可以写多个（服务器互通）。
// 默认 --host :: 双栈（IPv4 + IPv6 一个端口）；--host 0.0.0.0 = 只听 IPv4（旧行为）；--host 可写多个（逗号分开），
// 机器有好几个公网 IPv6 时写 --host 0.0.0.0,<AAAA 指向的那个 IPv6>（见 socks 那段）。
// 0.34：--relay-watch 只转观战流、不转对局（测试服务器上用这个）；--relay-match 只转对局；--relay 两个都开。REG 第 16 段 = 1 表示"对局走桥接平台"，
// 那种房服务器只把双方平台账号 ID互相介绍一次（PEER 第 7 段），不打洞不中转；房间列表第 11 列 = 1 标出来。
// --room 1v1|mp 开服务器自己开的房：鉴权 / 限速参数 --srate-state / --srate-relay / --srate-chat /
// --srate-pick / --srate-report / --srate-join / --srate-srelay / --smax-packet / --sban-drops / --sban-window / --sban-sec
// （默认值见 server/README.md；只作用于服务器房，普通大厅 / 排位 / 观战老协议不变）。
// --relay：打洞不通时替双方转发状态包。默认关：中转是服务器几乎全部的带宽（每对玩家约 50 KB/秒），
// 关着时服务器只登记房间、介绍地址，客机请求中转会收到 ERR …|norelay。
//
// 协议（文本，一个 UDP 包一条；字段用 | 分开，服务器收到的字段里的 | \t \n 都会被替换掉）：
// 主机 → 4N|REG|<密钥>|<名字>|<地图>|<已满 0/1>|<局域网地址 IP:端口>|<允许中转 0/1>[|<排位 0/1>|<主机 pid>] 每 2 秒；10 秒没收到就删房间
// （第 7 段旧版联机程序不发，当允许；主机发 0 时这个房间的会话一律不中转。第 8、9 段 = 排位排位房间，：
// 服务器没开 --ranked → ERR|-|noranked，主机 pid 没登记 → ERR|-|unknown，都不登记；
// 第 10 段 = 主机的平台账号 ID：排位对局只走桥接平台，服务器只管登记 / 介绍 / 记分，不打洞、不中转）
// （多人房的第 16 段固定发 0（不走桥接，多人房一律直连）；第 17 段 = 多人房人数上限 mpMax，0 / 不发 = 1v1；第 18 段 = 当前人数 mpCur；第 19 段 = 标签 mpTag，如 m=elim;tm=0;st=idle）
// ← 4N|REGOK|<房间号>|<你的公网地址>
// 主机 → 4N|UNREG|<密钥>
// 任何 → 4N|LIST ← 4N|ROOMS\n<房间号>\t<名字>\t<地图>\t<已满>\t<所在服务器>\t<排位 0/1>\t<称号>\t<能观战>\t<AI对打>\t<主机标记>\t<对局走桥接>\t<多人信息>\n…（最多 40 个；
// 所在服务器为空 = 就是这台，否则是别的服务器的 IP:端口，加入要去那台；盟主开的房间排最前；第 12 列 = <cur>/<max>[;<tags>]，1v1 房为空）
// 任何 → 4N|PING ← 4N|PONG|<你的公网地址>
// 客机 → 4N|JOIN|<房间号>|<局域网地址>[|<客机 pid>|<客机平台账号 ID>] → 客机 4N|PEER|<房间号>|<会话号>|<主机公网>|<主机局域网>
// → 主机 4N|PEER|<房间号>|<会话号>|<客机公网>|<客机局域网>
// ← 出错 4N|ERR|<房间号>|nofound / full / ranked（排位房间，客机没带登记过的 pid）
//                                           / needsteam（排位房间走桥接平台，客机没带平台账号 ID）/ oldhost（主机是旧版、没带平台账号 ID）
// 排位房间的 PEER 多第 7 段 = 对方的平台账号 ID
// PEER 第 8 段 = 对方另一族的地址（IPv4 / IPv6，对方用 ALT 报过才有；第 7 段这时可以是空的）
// 双栈：端点写法 IPv4 = a.b.c.d:端口、IPv6 = [地址]:端口（PONG / REGOK / PEER / 列表"所在服务器" / PUSHOK 都是）。
// 主机 → 4N|ALT|h|<密钥>、客机 → 4N|ALT|c|<会话号>：从另一族再报一次自己，← 4N|ALTOK|<h/c>|<看到的地址>
// 客机 → 4N|RELAY|<会话号> ← 4N|RELAYOK|<会话号>；同时发给主机 4N|RELAYON|<会话号>
// ← 没开 --relay 时 4N|ERR|<会话号>|norelay；主机不允许中转时 …|hostnorelay
// 双方 → 4NR|<会话号>\n<原样的状态包> 服务器按来源转给会话的另一方（包原样转发，带着这个头）
// 观战（要开 --relay；主机 REG 第 12 段 = 1 表示认观战，列表第 8 列 = 能观战）：
// 观战者 → 4N|WATCH|<房间号> 每 2 秒（保活） ← 4N|WATCHOK|<房间号>|<观战人数>
// ← 出错 4N|ERR|<房间号>|nofound / nowatch（主机是旧版）/ ranked / norelay / watchfull
// 观战者 → 4N|UNWATCH|<房间号>
// 主机 → 4NW|<房间号>\n<签过名的状态包（带 src=h / src=c）> 服务器原样（带着这个头）发给这个房间每个观战者；没人观战时主机不发
// 主机的 REGOK 第 5 段 = 现在的观战人数（主机靠它决定发不发）
// 排队：观战者按先来后到排队（WATCHOK 第 5 段 = 排第几；WATCH 第 4 段 = down 表示"刚下场的"，先不叫它上场；
// 第 5 段 = noq 表示只观战、不排队：不叫它上场、不挑它当第二位、排第几报 0）。
// 房间有过对手、现在没满（对手走了 / 被主机换下）→ 服务器给队首发 4N|YOURTURN|<房间号>|<口令>（15 秒内每 2 秒重发），
// 这段时间别人 JOIN 一律 full，队首拿口令 JOIN（第 7 段）才放行
// 主机下场（第二位选手经服务器转发）：主机 → 4N|HOSTDOWN|<密钥>：服务器挑队首（跳过刚下场的）当第二位，
// 给它发 4N|SECOND|<房间号>|1；主机 → 4N|HOSTUP|<密钥>：取消，给第二位发 4N|SECOND|<房间号>|0（回去观战）。
// 主机的 REGOK 第 6 段 = 有没有第二位。第二位 → 4NV|<房间号>\n<包> 服务器转给主机；主机 → 4NU|<房间号>\n<包> 服务器转给第二位。
// 观战者 WATCH 第 6 段 = dz 表示会拼省流观战包；主机的 REGOK 第 7 段 = 现在的观战者都会拼（1）/ 不是（0）：
// 主机据此给观战发省流包还是完整包（旧服务器没有第 7 段 = 主机发完整包）。
// 第二位不再收观战包（4NW）
// 主机 / 客机的 REG、JOIN、4NR 都从各自的"游戏 UDP 端口"发出，这样服务器看到的就是 NAT 给游戏端口分配的公网地址，
// 告诉对方后双方往这个地址互发包（打洞）。打洞不通时客机发 RELAY，之后两边的状态包都经服务器转发。
//
// 服务器自己开的房（--room 1v1|mp，默认关）：SHOST / SMHOST / SRULES / SROLE / SROSTER / S / SCHAT / SMPM / SSCORE /
// SPICKED / SPICKERR / SRELAYOK / SRELAYIN / SSTATE / SREPORT / SRELAY / SRLY / SLEAVE（详见）。
// SMHOST|<对局主机编号>（0 = 没有；多人服务器房由第一位玩家当对局主机，进房/退房/超时变动时下发）。
// 鉴权 / 限速（只作用于服务器房）：玩家 JOIN 后服务器发 4N|SHOST|房间|编号|人数|1v1/mp|<会话口令>；
// 之后 4N|SSTATE|编号|口令\n<包>、4N|SRLY|对方编号|口令\n<包>、4N|SRELAY|对方编号|口令、
// 4N|SREPORT|编号|口令|<k=v;…>、4N|SCHAT|口令|<文字>、4N|SLEAVE|口令。
// 口令对不上 / 来源端点变了（JOIN 第 6 段带旧口令重新握手才算）→ 丢弃并计数；超过每秒上限 → 丢弃，
// 持续超限临时拉黑。--srate-* / --smax-packet / --sban-* 调数值。旧版联机程序不进服务器房，老协议不变。
//
// 服务器互通（只要一边配置）：A 用 --upstream 指向 B，A 每 2 秒
// → B 4N|PUSH\n<房间号>\t<名字>\t<地图>\t<已满>\n… 只推 A 自己登记的房间（每包最多 6 个）；B 不用配 A：像收主机登记一样收下，
// 所在服务器 = 包的来源地址，10 秒没再推就删
// ← 4N|PUSHOK|<A 的公网地址> A 由此知道 B 眼里的自己是谁
// → B 4N|LIST，像客户端一样拿 B 的列表（B 自己的 + 别人推给 B 的），跳过所在服务器是 A 自己的，存下来 10 秒
// 两边的玩家都能看到对方的房间；加入别的服务器的房间时，客机直接去那台服务器 JOIN（主机的 NAT 口子只开给它自己那台）。
// 排位房间不推（排位只在本服务器内算）。
//
// --ranked <数据文件>：开排位排位（账号、上报、Elo、排行榜；协议见 fornet-ranked.mjs 文件头）。
// --web <目录>：再把排行榜 + 武器 / 招式统计写成静态网页（index.html + ranked.json，每分钟有变化才写）。
// --cfg <文件>：数值表（标准数值基准 + 武器平衡，一行，客户端 tools/cfg_export.py 导出）。文件改了自动重读（5 秒看一次）。
// 任何 → 4N|CFGQ|<我有的哈希或 -> ← 4N|CFG|<哈希>|<第几块>|<共几块>|<内容>（每块 ≤ 900 字节，内容里本来就有 |，客户端只按前 5 个 | 切）
// ← 已经是最新：4N|CFG|<哈希>|0|0| 没给 --cfg：4N|CFG|-|0|0|
// fornet-ranked.mjs 只在给了 --ranked 时才加载：没有这个文件、不加 --ranked，服务器照常跑（排位不公开源码，不随发布包分发）。
//
// 拉黑 / 封禁（举报 0.34 整个删了，：没有 REPORT / RPTOK / RPTERR / --reports / --dump-reports）：
// REG 第 15 段 = 主机标记（主机安装号的哈希），列表第 10 列原样给出：客户端据此不列自己拉黑的人开的房。
// --bans <文件>：排位封禁名单（作者手动维护，改了自动重读）。一行一个排位 pid（# 后面是注释）；
// 0.34 起**不再按平台账号 ID封**（服务器不存任何桥接平台标识， 总原则 3）。名单里的 pid 登记 / 加入排位房间都回 ERR …|banned。普通房间不管。
import dgram from 'node:dgram';
import crypto from 'node:crypto';
import dns from 'node:dns';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

const arg = (name, def) => {
    const i = process.argv.indexOf(name);
    return i > 0 && i + 1 < process.argv.length ? process.argv[i + 1] : def;
};
// 线上协议名（docs/USAGE.md "协议名字"）。默认是 4net 的中性名；已经有玩家在用某套名字的游戏，用自己的生成脚本把下面这一行
// 换成那套名字的默认值（整行替换，标记 @wire-defaults 别删），或者启动时给 --wire-server / --wire-peer。客户端联机程序要用同一套（WireTag.cs）。
// server：服务器控制包标记 "<server>|REG|…"；peer：对端包前缀（这里只认转发头 "<peer>R|" / W / V / U）；
// alias：另一个也认的控制包标记（回包用对方来时的那个，空 = 不认）；env：环境变量前缀；ranked：排位模块默认文件名；map：服务器房默认地图名
const WIRE_DEFAULTS = { server: 'PBZS', peer: 'PBZ', alias: '4N', env: 'PBZ_', ranked: './pbz-ranked.mjs', map: 'PBZ_Server' };     // @wire-defaults（影之刃零：tools/gen_pbz_server.py 生成，别手改这个文件）
const WS = arg('--wire-server', WIRE_DEFAULTS.server);
const WP = arg('--wire-peer', WIRE_DEFAULTS.peer);
const WALIAS = arg('--wire-alias', WIRE_DEFAULTS.alias) || '';
const env = (name) => process.env[WIRE_DEFAULTS.env + name];
const PORT = Number(arg('--port', process.env.PORT || 27020));
// 默认 :: = 双栈（IPv4 + IPv6）；写多个见下面 socks 那段
const HOSTS = (process.argv.flatMap((a, i) => (a === '--host' && process.argv[i + 1] ? [process.argv[i + 1]] : [])).join(',') || process.env.HOST || '::')
    .split(',').map((h) => h.trim().replace(/^\[(.*)\]$/, '$1')).filter(Boolean);
const HOST_GIVEN = process.argv.includes('--host') || !!process.env.HOST;
const QUIET = process.argv.includes('--quiet');
// 0.34（最终方案 3，排法 B）：中转拆成两个开关。--relay = 两个都开（自建服务器照旧）；
// --relay-watch 只转观战流（测试服务器 0.34 用这个：对局不中转，观战转发保留）；--relay-match 只转对局（没人该用，留着对称）
const RELAY_MATCH = process.argv.includes('--relay') || process.argv.includes('--relay-match');     // 0.34 评审：不再认环境变量 RELAY=1（systemd 里遗留的会悄悄把中转打开）
const RELAY_WATCH = process.argv.includes('--relay') || process.argv.includes('--relay-watch');
const RANKED_FILE = arg('--ranked', process.env.RANKED || '');
const CFG_FILE = arg('--cfg', env('CFG') || '');
const BANS_FILE = arg('--bans', env('BANS') || '');
const UPSTREAMS =process.argv.flatMap((a, i) => (a === '--upstream' && process.argv[i + 1] ? [process.argv[i + 1]] : []));

const ROOM_TTL = 10_000;          // 主机 10 秒没心跳就删房间
const SESSION_TTL = 30_000;       // 会话 30 秒没包就删
const MAX_ROOMS = 1000;
const MAX_LIST = 40;
const MAX_PACKET = 1400;
const MAX_FWD = 8192;              // （0.33 线移植）4NR / 4NW / 4NV / 4NU 转发包的上限（完整状态包 2.4–2.6 KB）
const FWD_HEADS = new Set([`${WP}R|`, `${WP}W|`, `${WP}V|`, `${WP}U|`]);
const FWD_LEN = WP.length + 2;     // 转发头 "<peer>R|" 的长度（别写死）
const SSTATE = `${WS}|SSTATE|`, SRLY = `${WS}|SRLY|`;     // 服务器房的两种带原包的控制包（按字节头认）
const PUSH_CHUNK = 6;             // 每个 PUSH 包几个房间（中文名字 32 字 ≈ 96 字节，6 个也在 1400 以内）
const MAX_REMOTE_PER_SOURCE = 200;
const RELAY_RATE = 120;           // 每个会话每个方向每秒最多转发多少包（游戏 30 包/秒，留余量）
const MAX_WATCH = 8;              // 每个房间最多几个观战者
const WATCH_TTL = 6_000;          // 观战者 6 秒没保活就移出
const WATCH_RATE = 150;           // 主机每秒最多上传多少观战包（两路 × 30 包/秒，留余量）

// M6 服务器房鉴权 / 限速（只作用于 --room 服务器自己开的房；普通大厅 / 排位 / 观战老协议不受影响）。
// 每个玩家加入时服务器发一个随机会话口令（SHOST 第 7 段）；之后 SSTATE / SRLY / SRELAY / SREPORT / SCHAT / SLEAVE
// 都要带口令，且必须从加入时的来源端点发出，否则丢弃并计数。按"来源端点 + 消息类型"做令牌桶，持续超限临时拉黑。
const numArg = (name, def, min, max) => {
    const ev = env(name.replace(/^--/, '').replace(/-/g, '_').toUpperCase());
    const raw = arg(name, ev === undefined ? '' : ev);
    if (raw === '') return def;
    const n = Number(raw);
    return Number.isFinite(n) ? Math.max(min, Math.min(max, n)) : def;
};
const S_RATE = {
    state: numArg('--srate-state', 60, 1, 600),       // 状态包 / 秒（游戏 30 包/秒）
    relay: numArg('--srate-relay', 60, 1, 600),       // SRLY 中转 / 秒（游戏 30 包/秒）
    chat: numArg('--srate-chat', 3, 1, 100),          // 聊天 / 秒
    pick: numArg('--srate-pick', 5, 1, 100),          // 捡道具 / 秒
    report: numArg('--srate-report', 20, 1, 300),     // 低频上报 / 秒（客户端 4 次/秒）
    join: numArg('--srate-join', 10, 1, 100),         // JOIN 握手 / 秒（客户端 1 次/秒）
    srelay: numArg('--srate-srelay', 10, 1, 100),     // SRELAY 请求 / 秒（客户端 5 秒一次）
};
const S_MAX_PACKET = numArg('--smax-packet', MAX_PACKET, 128, MAX_PACKET);   // 服务器房单包上限（整包字节）
const S_BAN_DROPS = numArg('--sban-drops', 100, 1, 100000);                  // 一个端点在一个窗口里被限速丢弃多少次
const S_BAN_WINDOW = numArg('--sban-window', 10, 1, 600);                    // 计这次数的窗口（秒）
const S_BAN_SEC = numArg('--sban-sec', 30, 0, 3600);                         // 临时拉黑多少秒（0 = 不拉黑）

/** @type {Map<string, {id:string,key:string,name:string,map:string,full:boolean,host:string,hostLocal:string,noRelay?:boolean,seen:number}>} */
const rooms = new Map();          // 房间号 → 房间
const byKey = new Map();          // 主机密钥 → 房间号
let serverRoom = null;            // M5 服务器自己开的房间（不属于任何玩家；--room 才建）
/** @type {Map<string, {sid:string,room:string,a:string,b:string,bLocal:string,relay:boolean,seen:number,rate:Object}>} */
const sessions = new Map();       // 会话号 → { a 主机端点, b 客机端点 }
/** @type {Map<string, {id:string,name:string,map:string,full:boolean,home:string,via:string,seen:number}>} */
const remote = new Map();         // "<所在服务器>|<房间号>" → 别的服务器的房间（推过来的 / 从上游拉来的）
/** @type {Map<string, {addr:string, ep:string|null, self:string, lookedUp:number}>} */
const upstreams = new Map(UPSTREAMS.map((a) => [a, { addr: a, ep: null, self: '', lookedUp: 0 }]));
const stats = { rx: 0, relayed: 0, dropped: 0, rebound: 0, sendErr: 0 };

const log = (...a) => { if (!QUIET) console.log(new Date().toISOString().slice(11, 23), ...a); };
// 中转诊断：--quiet 下也写，但只写会话号 / 房间号 / 计数，从不写 IP（中转两个方向各转了多少、为什么丢）
const note = (...a) => console.log(new Date().toISOString().slice(11, 23), ...a);
const ctr = (s) => s.ctr ?? (s.ctr = { ab: 0, ba: 0, early: 0, unk: 0, unkA: 0, unkB: 0, rate: 0, rebA: 0, rebB: 0, logged: '' });
// 日志只写地址前两段：IPv4 前两个数、IPv6 前两组
const ip16 = (e) => { const ip = ipOf(e); return ip.includes(':') ? ip.split(':').slice(0, 2).join(':') : ip.split('.').slice(0, 2).join('.'); };
function relaySummary(s, why) {
    const c = ctr(s);
    const line = `主机→客机 ${c.ab}，客机→主机 ${c.ba}，没开中转前 ${c.early}，认不出 ${c.unk}（像主机 ${c.unkA} / 像客机 ${c.unkB}），限速 ${c.rate}，`
        + `换端口 主机 ${c.rebA} / 客机 ${c.rebB}`;
    if (why !== '定时' || line !== c.logged) note(`[relay-diag] 会话 ${s.sid} 房间 ${s.room} ${why}：${line}`);
    c.logged = line;
}
// F4c-2 桥接传输的对端 id（外部联机服务给的账号号码，服务器只当不透明的数字串介绍一次、不落盘）：5–20 位数字；别的一律当没有
const bridgeIdOf = (s) => (/^\d{5,20}$/.test(String(s ?? '').trim()) ? String(s).trim() : '');
const clean = (s, n) => String(s ?? '').replace(/[|\t\r\n]/g, ' ').slice(0, n);
// 双栈：双栈 socket 收到的 IPv4 包来源是 ::ffff:a.b.c.d，一律还原成 a.b.c.d（不然同一个 IPv4 玩家前后会被当成两个端点）；
// 端点字符串 IPv4 = "a.b.c.d:端口"，IPv6 = "[地址]:端口"（和客户端 Addr.Fmt / ParseEp 一样）
const normAddr = (a) => { const m = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(String(a)); return m ? m[1] : String(a); };
const fmtEp = (addr, port) => (String(addr).includes(':') ? `[${addr}]:${port}` : `${addr}:${port}`);
const ep = (r) => fmtEp(normAddr(r.address), r.port);
const famOf = (e) => (ipOf(e).includes(':') ? 6 : 4);

// M5：服务器自己开房（默认关）。--room 1v1 = 两人 1v1 解说式；--room mp = 多人混战（--room-size 人）。
// 房间不属于任何玩家：服务器管名单 / 编号 / 规则 / 开始结束计分 / 聊天 / 观战，玩家之间仍然直连互发状态。
const ROOM_KIND = (arg('--room', env('ROOM') || '') || '').toLowerCase();
const ROOM_SIZE_RAW = Number(arg('--room-size', env('ROOM_SIZE') || (ROOM_KIND === 'mp' ? 4 : 2)));
const ROOM_SIZE = Number.isFinite(ROOM_SIZE_RAW) ? Math.max(2, Math.min(16, ROOM_SIZE_RAW)) : (ROOM_KIND === 'mp' ? 4 : 2);
const ROOM_ID = clean(arg('--room-id', env('ROOM_ID') || ''), 16).toUpperCase();
const ROOM_NAME = arg('--room-name', env('ROOM_NAME') || '服务器房间');
const ROOM_MAP = arg('--room-map', env('ROOM_MAP') || WIRE_DEFAULTS.map);
const ROOM_TL_RAW = Number(arg('--room-tl', env('ROOM_TL') || 180));
const ROOM_TL = Number.isFinite(ROOM_TL_RAW) ? Math.max(10, ROOM_TL_RAW) : 180;
const ROOM_PICK_RAW = Number(arg('--pick-range', env('PICK_RANGE') || 5));
const ROOM_PICK_RANGE = Number.isFinite(ROOM_PICK_RAW) ? Math.max(0, ROOM_PICK_RAW) : 5;
const ROOM_PROPS = arg('--props', env('PROPS') || 'p1@0,0,0;p2@100,0,0;p3@0,100,0');
// §408 服务器自己开的房：默认规则跟盟主标准（和客户端 NET.RK_RULES、排位 RULES、C# FormatRoomRules 兜底同一份，改一起改）
const ROOM_RULES = arg('--room-rules', env('ROOM_RULES')
    || 'bar=2;bo=3;dm=20;ab=0;ctr=1;bal=1;medok=0;npos=1;std=1;cs=0;gcd=1;dgc=0;sycd=1;stg=1;cfgh=0;acc=2;accn=3;accban=AnimMovement,BreakRegen,HealthResistance,MagicWeapon,SwitchEndure;wpnban=-;edgeban=-;tl=180;ult0=0;sp0=3;resm=0;ultx=200;rdyto=10');
const newId = (len) => {
    // 房间号：去掉容易看错的 0 O 1 I L
    const abc = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    let s = '';
    for (const b of crypto.randomBytes(len)) s += abc[b % abc.length];
    return s;
};

// 作弊数据采样 / 可疑排名：0.34 整个删了
// ---- M5 服务器自己开的房间（AGPL 同一份，--room 才开；默认关）
// 服务器只核对玩家上报的数据，不跑游戏：名单 / 编号 / 规则 / 开始结束 / 计分 / 聊天 / 捡道具判定 / 观战转发。
// 玩家之间仍由服务器介绍后直连互发状态（S → 各自的 MeshMp），打不通可由玩家请求服务器中转（SRELAY）。
function parseProps(s) {
    const out = new Map();
    for (const part of String(s || '').split(';')) {
        const at = part.indexOf('@');
        if (at <= 0) continue;
        const id = clean(part.slice(0, at), 16);
        const xyz = part.slice(at + 1).split(',').map(Number);
        if (!id || xyz.length < 3 || !xyz.every(Number.isFinite)) continue;
        out.set(id, { x: xyz[0], y: xyz[1], z: xyz[2] });
    }
    return out;
}

function createServerRoom() {
    const kind = ROOM_KIND === 'mp' ? 'mp' : '1v1';
    let id = ROOM_ID;
    if (!id) { do id = 'SRV' + newId(3); while (rooms.has(id)); }
    const room = {
        id, key: '', name: clean(ROOM_NAME, 32) || '服务器房间', map: clean(ROOM_MAP, 48), hosted: true,
        kind, size: kind === 'mp' ? ROOM_SIZE : 2, rules: ROOM_RULES, tl: ROOM_TL,
        props: parseProps(ROOM_PROPS), pickRange: ROOM_PICK_RANGE,
        players: new Map(), watchers: new Map(), watch: true, maxWatch: MAX_WATCH,
        full: false, seen: Date.now(), started: 0, match: null, pairs: new Map(), taken: new Map(), nextMid: 0,
        // 多人服务器房第一位玩家当对局主机
        matchHost: 0, mpState: 'idle',
        // 鉴权 / 限速：每个端点的令牌桶、超限计数、临时拉黑、日志节流
        rate: new Map(), over: new Map(), bans: new Map(), secLog: new Map(),
        sec: { badToken: 0, badEp: 0, badSize: 0, rate: 0, banned: 0, ban: 0, rejoin: 0 },
    };
    rooms.set(id, room);
    log(`[room] 服务器自己开房 ${id}（${kind === 'mp' ? '多人混战 ' + room.size + ' 人' : '1v1'}）`
        + `；鉴权 开；限速 状态 ${S_RATE.state}/秒 中转 ${S_RATE.relay}/秒 聊天 ${S_RATE.chat}/秒 捡道具 ${S_RATE.pick}/秒`
        + `；持续超限 ${S_BAN_DROPS} 次 / ${S_BAN_WINDOW} 秒拉黑 ${S_BAN_SEC} 秒`);
    return room;
}

const serverRoomPlayer = (room, from) => {
    for (const p of room.players.values()) if (p.ep === from) return p;
    return null;
};

// 会话口令比较（长度先比，再按字节常量时间比较；口令是 newId(16)）
function sameToken(a, b) {
    const x = String(a ?? ''), y = String(b ?? '');
    if (x.length < 8 || x.length !== y.length) return false;
    try { return crypto.timingSafeEqual(Buffer.from(x, 'utf8'), Buffer.from(y, 'utf8')); } catch { return false; }
}

// 每个端点最多 1 行：非 --quiet 一分钟一行，--quiet 五分钟一行（第一行立即写，便于排查）。
// 只写房间号 / 端点（--quiet 时只写 IP 前两段）/ 原因 / 本房间累计计数，不写聊天内容。
function securityDrop(room, from, why, now) {
    const s = room.sec;
    const e = room.secLog.get(from);
    const every = QUIET ? 300_000 : 60_000;
    if (e && now - e.at < every) { e.n++; return; }
    const who = QUIET ? ip16(from) : from;
    const first = !e;
    if (!e) room.secLog.set(from, { at: now, n: 1 });
    else { e.at = now; e.n++; }
    note(`[room-sec] ${room.id} ${who} ${why}${first ? '' : '（本段累计）'}：令牌 ${s.badToken} 端点 ${s.badEp} 超大 ${s.badSize} 限速 ${s.rate} 拉黑 ${s.ban}`);
}

// 令牌桶：容量 = 每秒上限（允许 1 秒的突发），按"端点 + 消息类型"分开
function takeToken(room, from, kind, now) {
    const rate = S_RATE[kind] || 60;
    const key = from + '|' + kind;
    let b = room.rate.get(key);
    if (!b) { b = { tokens: rate, at: now }; room.rate.set(key, b); }
    else {
        const dt = Math.max(0, now - b.at) / 1000;
        b.at = now;
        b.tokens = Math.min(rate, b.tokens + dt * rate);
    }
    if (b.tokens < 1) return false;
    b.tokens -= 1;
    return true;
}

// 持续超限：S_BAN_WINDOW 秒内被限速丢弃 S_BAN_DROPS 次 → 拉黑 S_BAN_SEC 秒（到期自动恢复）
function rateDrop(room, from, now) {
    room.sec.rate++;
    let o = room.over.get(from);
    if (!o || now - o.win > S_BAN_WINDOW * 1000) {
        o = { win: now, n: 0, until: o ? o.until : 0 };
        room.over.set(from, o);
    }
    if (now < o.until) { room.sec.banned++; return; }
    o.n++;
    if (S_BAN_SEC > 0 && o.n >= S_BAN_DROPS) {
        o.until = now + S_BAN_SEC * 1000;
        o.n = 0;
        o.win = now;
        room.bans.set(from, o.until);
        room.sec.ban++;
        const e = room.secLog.get(from);
        if (e) e.at = now;
        note(`[room-sec] ${room.id} ${QUIET ? ip16(from) : from} 持续超限，临时拉黑 ${S_BAN_SEC} 秒`);
        return;
    }
    securityDrop(room, from, '限速', now);
}

// 鉴权 + 限速：端点必须已经用 JOIN 加入过，口令必须对得上，单包不能超限；通过才更新保活时间。
// 返回玩家对象；失败返回 null（调用方直接丢弃，不回复）。
function serverRoomAuth(room, from, token, kind, size, now) {
    const until = room.bans.get(from);
    if (until && now < until) { room.sec.banned++; return null; }
    if (until) room.bans.delete(from);
    const p = serverRoomPlayer(room, from);
    if (!p) { room.sec.badEp++; securityDrop(room, from, '不在这个房间 / 端点变了', now); return null; }
    if (!sameToken(token, p.token)) { room.sec.badToken++; securityDrop(room, from, '会话口令不对', now); return null; }
    if (size > S_MAX_PACKET) { room.sec.badSize++; securityDrop(room, from, `单包 ${size} 字节超过上限 ${S_MAX_PACKET}`, now); return null; }
    if (!takeToken(room, from, kind, now)) { rateDrop(room, from, now); return null; }
    p.seen = now;
    return p;
}

const serverRoomBanned = (room, from, now) => {
    const until = room.bans.get(from);
    if (!until) return false;
    if (now < until) { room.sec.banned++; return true; }
    room.bans.delete(from);
    return false;
};

const serverRoomHost = (room, p) => `${WS}|SHOST|${room.id}|${p.pid}|${room.players.size}|${room.kind}|${p.token}`;

function serverRoomRoster(room) {
    return [...room.players.values()].sort((a, b) => a.pid - b.pid).map((p) => `${p.pid}:${clean(p.nick, 24) || '玩家' + p.pid}`).join(',');
}

function sendServerRoomRoster(room) {
    const text = `${WS}|SROSTER|${room.players.size}|${serverRoomRoster(room)}`;
    for (const p of room.players.values()) send(text, p.ep);
}

// 多人服务器房交给第一位玩家当对局主机（kind === 'mp' 时不建 match、不发 SMPM/SSCORE、不判 dead/ko/pick）
const isPlayerMatchHost = (room) => room && room.kind === 'mp';

function updateServerRoomMatchHost(room, why) {
    if (room.kind !== 'mp') return;
    let earliest = null;
    for (const p of room.players.values()) {
        if (!earliest || p.joined < earliest.joined || (p.joined === earliest.joined && p.pid < earliest.pid)) {
            earliest = p;
        }
    }
    const nextHost = earliest ? earliest.pid : 0;
    if (room.matchHost !== nextHost) {
        room.matchHost = nextHost;
        room.mpState = 'idle';     // 对局主机变了就把 room.mpState 清成 idle
        log(`[room] ${room.id} 对局主机 → ${nextHost}（${why}）`);
        const msg = `${WS}|SMHOST|${nextHost}`;
        for (const p of room.players.values()) send(msg, p.ep);
    }
}

function serverRoomIntros(room) {
    const ps = [...room.players.values()];
    for (const p of ps) {
        for (const q of ps) {
            if (p === q) continue;
            const key = Math.min(p.pid, q.pid) + '-' + Math.max(p.pid, q.pid);
            let token = room.pairs.get(key);
            if (!token) { token = newId(10); room.pairs.set(key, token); }
            const mh = room.kind === '1v1' && q.pid === 1 ? 1 : 0;
            send(`${WS}|SMESH|${q.pid}|${q.ep}|${clean(q.local, 32)}|${token}|${clean(q.nick, 24) || '玩家' + q.pid}|${mh}`, p.ep);
        }
    }
}

function serverRoomJoin(room, from, f, now) {
    // 服务器房：JOIN 也要限速（正常客户端 1 次/秒）；被临时拉黑的端点直接丢
    if (serverRoomBanned(room, from, now)) return;
    if (!takeToken(room, from, 'join', now)) { rateDrop(room, from, now); return; }
    // JOIN 第 6 段 = 会话口令。第一次加入没有；NAT 换了端口时拿旧口令重新握手，认成同一个人。
    const token = clean(f[5], 32);
    let p = serverRoomPlayer(room, from);
    let isNew = false;
    let rejoin = false;
    if (!p && token) {
        for (const q of room.players.values()) {
            if (!sameToken(token, q.token)) continue;
            if (serverRoomBanned(room, q.ep, now)) return;     // 旧端点已经被拉黑：不许换个端口绕过去
            q.ep = from;
            q.seen = now;
            q.local = clean(f[3], 32) || q.local;
            if (f[4]) q.nick = clean(f[4], 24) || q.nick;
            room.sec.rejoin++;
            p = q;
            rejoin = true;
            log(`[room] ${room.id} 服务器房：${q.nick} 换端点重新握手（编号 ${q.pid}，${from}）`);
            break;
        }
    }
    if (!p) {
        if (room.players.size >= room.size) { send(`${WS}|ERR|${room.id}|full`, from); return; }
        if (room.kind === 'mp') {
            // 多人房（淘汰 / 积分 / 对决）对局中也收：进来的人这局先观战，下局参加（游戏脚本管）
        } else {
            if (room.match && (room.match.state === 'cd' || room.match.state === 'fight')) { send(`${WS}|ERR|${room.id}|inmatch`, from); return; }
        }
        let pid = room.kind === 'mp' ? 2 : 1;
        const used = new Set([...room.players.values()].map((x) => x.pid));
        while (used.has(pid)) pid++;
        p = {
            pid, ep: from, local: clean(f[3], 32), nick: clean(f[4], 24), joined: now, seen: now,
            dead: 0, scored: 0, score: 0, alive: true, deathAt: 0, claimBy: null, pos: null,
            lastPick: '', relayTo: 0, token: newId(16),          // 会话口令（只在 SHOST 里发给本人）
        };
        if (!p.nick) p.nick = `玩家${pid}`;
        room.players.set(pid, p);
        isNew = true;
        log(`[room] ${room.id} 服务器房：${p.nick}（编号 ${pid}，${from}）加入`);
        updateServerRoomMatchHost(room, '加入');
    } else {
        // 同一个端点发来的 JOIN 只是保活；带了口令就必须对（防止拿着错口令在别人的端点上乱试）
        if (token && !sameToken(token, p.token)) {
            room.sec.badToken++;
            securityDrop(room, from, 'JOIN 口令不对', now);
            return;
        }
        p.seen = now;
        p.local = clean(f[3], 32) || p.local;
        if (f[4]) p.nick = clean(f[4], 24) || p.nick;
    }
    room.full = room.players.size >= room.size;
    if (!isNew)
    {
        // 每秒的 JOIN 只当保活；SHOST 每 3 秒补一次（UDP 丢了也不会一直不知道自己的编号 / 口令）
        if (rejoin || now - (p.hostAt || 0) > 3000) {
            p.hostAt = now;
            send(serverRoomHost(room, p), from);
            if (room.kind === 'mp') send(`${WS}|SMHOST|${room.matchHost || 0}`, from);
            if (rejoin) serverRoomIntros(room);     // 端点变了，别的玩家也要拿到新地址
        }
        return;
    }
    p.hostAt = now;
    send(serverRoomHost(room, p), from);
    if (room.kind === 'mp') send(`${WS}|SMHOST|${room.matchHost || 0}`, from);
    send(`${WS}|SRULES|${room.rules}`, from);
    send(`${WS}|SROLE|client|${room.kind === '1v1' && p.pid === 1 ? 1 : 0}`, from);
    sendServerRoomRoster(room);
    serverRoomIntros(room);
    serverRoomStart(room);
    if (room.match) sendServerRoomMpm(room);
}

function serverRoomChat(room, from, token, text, size, now) {
    const p = serverRoomAuth(room, from, token, 'chat', size, now);
    if (!p) return;
    const msg = `${WS}|SCHAT|${p.pid}|${clean(p.nick, 24) || '玩家' + p.pid}|${clean(text, 200)}`;
    for (const q of room.players.values()) if (q !== p) send(msg, q.ep);
}

function serverRoomState(room, from, text, now) {
    // 头：4N|SSTATE|<编号>|<会话口令>\n<原状态包>（旧客户端没有第 4 段，会被当没口令丢掉）
    const nl = text.indexOf('\n');
    if (nl < 0) return;
    const head = text.slice(0, nl).split('|');
    const p = serverRoomAuth(room, from, head[3], 'state', Buffer.byteLength(text), now);
    if (!p) return;
    // 多人房看对局主机 SSTATE 正文里的 mpm=<状态>:... 记 room.mpState，mpx=<模式> 记 room.mpMode / room.mpTeams
    if (room.kind === 'mp' && p.pid === room.matchHost) {
        const body = text.slice(nl + 1);
        const m = body.match(/(?:^|\n)mpm=([a-zA-Z0-9_]+):/);
        if (m) room.mpState = m[1];
        // 游戏发 mpx=<玩法>:<分队 0/1>:<增益>:<围攻>（game_multi.lua 状态包）
        const mx = body.match(/(?:^|\n)mpx=([a-z]+):(\d)/);
        if (mx) { room.mpMode = mx[1]; room.mpTeams = mx[2] === '1'; }
    }
    if (!room.watchers || room.watchers.size === 0) return;
    let body = text.slice(nl + 1);
    const src = room.kind === '1v1' ? (p.pid === 1 ? 'h' : 'c') : String(p.pid);
    const sb = [];
    for (const raw of body.split('\n')) {
        const line = raw.trimEnd();
        if (!line || line.startsWith('src=')) continue;
        sb.push(line);
    }
    body = sb.join('\n') + '\n';
    const pkt = `${WP}W|${room.id}\n${body}src=${src}\n`;
    for (const w of room.watchers.keys()) send(pkt, w);
}

function serverRoomRelay(room, from, text, now) {
    // 头：4N|SRLY|<对方编号>|<会话口令>\n<原状态包>
    const nl = text.indexOf('\n');
    if (nl < 0) return;
    const head = text.slice(0, nl).split('|');
    const p = serverRoomAuth(room, from, head[3], 'relay', Buffer.byteLength(text), now);
    if (!p) return;
    if (!RELAY_MATCH) { send(`${WS}|ERR|${room.id}|norelay`, from); return; }
    const q = room.players.get(Number(head[2]));
    if (!q) return;
    q.seen = now;
    send(`${WS}|SRELAYIN|${p.pid}\n${text.slice(nl + 1)}`, q.ep);
}

function serverRoomMpm(room) {
    const m = room.match;
    if (!m) return '';
    let remain = m.tl;
    if (m.state === 'fight') remain = Math.max(0, Math.floor(m.tl - (Date.now() - m.at) / 1000));
    else if (m.state === 'cd') remain = m.tl;
    return `${m.state}:${m.mid}:${m.lives}:${m.tl}:${remain}:${m.parts.join(',')}:${m.rank.join(',')}`;
}

function sendServerRoomMpm(room) {
    if (!room.match) return;
    const text = `${WS}|SMPM|${serverRoomMpm(room)}`;
    for (const p of room.players.values()) send(text, p.ep);
    const scores = room.match.parts.map((pid) => `${pid}:${(room.match.scores[pid] || 0)}`).join(',');
    const st = `${WS}|SSCORE|${scores}`;
    for (const p of room.players.values()) send(st, p.ep);
}

function serverRoomStart(room) {
    const now = Date.now();
    const ps = [...room.players.values()].sort((a, b) => a.pid - b.pid);
    if (ps.length < room.size) return;
    if (room.kind === '1v1') {
        if (room.started) return;
        room.started = now;
        room.full = true;
        for (const p of ps) {
            send(`${WS}|SRULES|${room.rules}`, p.ep);
            send(`${WS}|SROLE|client|${p.pid === 1 ? 1 : 0}`, p.ep);
        }
        log(`[room] ${room.id} 1v1 两人到齐，规则由服务器下发，${ps[0].pid} 当对局主机`);
        return;
    }
    // 多人服务器房交给第一位玩家当对局主机：不建 room.match、不发 SMPM / SSCORE
    if (isPlayerMatchHost(room)) return;
    if (room.match) return;
    room.nextMid++;
    room.match = {
        state: 'cd', mid: room.nextMid, at: now, lives: 1, tl: room.tl,
        parts: ps.map((p) => p.pid), rank: [], scores: {}, deaths: {},
        alive: new Set(ps.map((p) => p.pid)), lastMpm: 0,
    };
    for (const p of ps) { p.dead = 0; p.scored = 0; p.alive = true; p.deathAt = 0; p.claimBy = null; p.score = 0; }
    log(`[room] ${room.id} 多人局 ${room.match.mid} 开始（${ps.length} 人：${room.match.parts.join(',')}）`);
    sendServerRoomMpm(room);
}

function serverRoomEnd(room, why) {
    const m = room.match;
    if (!m || m.state === 'end') return;
    m.state = 'end';
    m.at = Date.now();
    const alive = [...m.alive].sort((a, b) => (m.scores[b] || 0) - (m.scores[a] || 0));
    const dead = m.parts.filter((pid) => !m.alive.has(pid)).sort((a, b) => (room.players.get(b)?.deathAt || 0) - (room.players.get(a)?.deathAt || 0));
    m.rank = alive.concat(dead);
    log(`[room] ${room.id} 多人局 ${m.mid} 结束（${why}）：排名 ${m.rank.join(',')}，比分 ${JSON.stringify(m.scores)}`);
    sendServerRoomMpm(room);
}

function serverRoomKill(room, attacker, victim, now) {
    const m = room.match;
    if (!m || m.state !== 'fight') return false;
    const v = room.players.get(victim);
    if (!v || !m.alive.has(victim) || room.players.get(attacker) == null || attacker === victim) return false;
    m.scores[attacker] = (m.scores[attacker] || 0) + 1;
    m.deaths[victim] = (m.deaths[victim] || 0) + 1;
    v.scored = (v.scored || 0) + 1;      // 这次死亡已经计过分，后面重复的 ko= 不再加
    m.alive.delete(victim);
    v.alive = false;
    v.deathAt = now;
    v.claimBy = null;
    log(`[room] ${room.id} 击杀：${attacker} → ${victim}（比分 ${JSON.stringify(m.scores)}）`);
    if (m.alive.size <= 1) serverRoomEnd(room, '只剩 ' + m.alive.size + ' 人');
    return true;
}

// 双方上报交叉核对：杀的人报 ko=死者，死者自己报 dead=次数；两边都有才计分。
// 头：4N|SREPORT|<编号>|<会话口令>|<k=v;…>
function serverRoomReport(room, from, f, now) {
    const p = serverRoomAuth(room, from, f[3], 'report', Buffer.byteLength(f.join('|')), now);
    if (!p) return;
    const fld = {};
    for (const raw of String(f[4] || '').split(';')) {
        const eq = raw.indexOf('=');
        if (eq > 0) fld[raw.slice(0, eq)] = raw.slice(eq + 1);
    }
    if (fld.x !== undefined && fld.y !== undefined && fld.z !== undefined) {
        const x = Number(fld.x), y = Number(fld.y), z = Number(fld.z);
        if ([x, y, z].every(Number.isFinite)) p.pos = { x, y, z };
    }
    // 多人服务器房交给第一位玩家当对局主机：对多人房不再计分 / 判道具（位置 x/y/z 照收）
    if (isPlayerMatchHost(room)) return;
    const m = room.match;
    if (fld.dead !== undefined) {
        const d = Math.max(0, Math.min(999, Number(fld.dead) || 0));
        if (d > p.dead) {
            p.dead = d;
            if (m && m.state === 'fight') {
                if (p.claimBy && now - p.claimBy.at <= 8000 && m.alive.has(p.pid)) {
                    serverRoomKill(room, p.claimBy.pid, p.pid, now);
                    p.claimBy = null;
                } else {
                    m.alive.delete(p.pid);
                    p.alive = false;
                    p.deathAt = now;
                    if (m.alive.size <= 1) serverRoomEnd(room, '只剩 ' + m.alive.size + ' 人');
                }
            }
        }
    }
    if (fld.ko !== undefined && m && m.state === 'fight') {
        const victim = Number(fld.ko);
        const v = room.players.get(victim);
        if (v && victim !== p.pid) {
            if (v.dead > (v.scored || 0) && v.dead > 0) {
                // 死者先报了 dead=、凶手后报 ko=：也算（两边都上报了才计分）
                if (m.alive.has(victim)) {
                    serverRoomKill(room, p.pid, victim, now);
                } else if (v.deathAt && now - v.deathAt <= 8000) {
                    m.scores[p.pid] = (m.scores[p.pid] || 0) + 1;
                    v.scored = (v.scored || 0) + 1;
                    log(`[room] ${room.id} 补记击杀：${p.pid} → ${victim}（比分 ${JSON.stringify(m.scores)}）`);
                }
            } else if (m.alive.has(victim)) {
                v.claimBy = { pid: p.pid, at: now };       // 等死者自己上报 dead= 再算
            }
        }
    }
    if (fld.pick !== undefined) {
        if (!takeToken(room, from, 'pick', now)) { rateDrop(room, from, now); return; }     // 捡道具单独限速
        serverRoomPick(room, p, clean(fld.pick, 16), now);
    }
}

function serverRoomPick(room, p, prop, now) {
    if (!prop || p.lastPick === prop) return;
    p.lastPick = prop;
    const at = room.props.get(prop);
    if (!at) { send(`${WS}|SPICKERR|${prop}|noprop`, p.ep); return; }
    if (room.taken.has(prop)) { send(`${WS}|SPICKERR|${prop}|taken`, p.ep); return; }
    if (!p.pos) { send(`${WS}|SPICKERR|${prop}|nopos`, p.ep); return; }
    const d = Math.hypot(p.pos.x - at.x, p.pos.y - at.y, p.pos.z - at.z);
    if (d > room.pickRange) { send(`${WS}|SPICKERR|${prop}|far`, p.ep); return; }
    room.taken.set(prop, p.pid);
    const msg = `${WS}|SPICKED|${prop}|${p.pid}|${clean(p.nick, 24) || '玩家' + p.pid}`;
    for (const q of room.players.values()) send(msg, q.ep);
    log(`[room] ${room.id} 捡道具 ${prop} → ${p.pid}（距离 ${d.toFixed(1)}）`);
}

function serverRoomDrop(room, p, why) {
    if (!room.players.delete(p.pid)) return;
    log(`[room] ${room.id} 玩家 ${p.pid} 离开（${why}）`);
    updateServerRoomMatchHost(room, why || '离开');
    room.full = room.players.size >= room.size;
    sendServerRoomRoster(room);
    for (const q of room.players.values()) send(`${WS}|SLEFT|${p.pid}`, q.ep);
    if (room.match) {
        room.match.parts = room.match.parts.filter((x) => x !== p.pid);
        room.match.alive.delete(p.pid);
        if (room.match.state === 'fight' && room.match.alive.size <= 1) serverRoomEnd(room, '有人掉线');
        else sendServerRoomMpm(room);
    }
    if (room.players.size < 2) { room.started = 0; room.pairs.clear(); room.taken.clear(); }
}

function serverRoomTick(now) {
    const room = serverRoom;
    if (!room) return;
    watchCount(room, now);
    // 清理过期的临时拉黑 / 令牌桶 / 计数（不影响仍在用的端点）
    for (const [key, until] of room.bans) if (now >= until) room.bans.delete(key);
    for (const [key, b] of room.rate) if (now - b.at > 60_000) room.rate.delete(key);
    for (const [key, o] of room.over) if (now - o.win > S_BAN_WINDOW * 1000 && now >= (o.until || 0)) room.over.delete(key);
    for (const [key, e] of room.secLog) if (now - e.at > 600_000) room.secLog.delete(key);
    for (const p of [...room.players.values()]) if (now - p.seen > 7000) serverRoomDrop(room, p, '7 秒没上报');
    room.full = room.players.size >= room.size;
    if (room.kind === 'mp' && room.match) {
        const m = room.match;
        if (m.state === 'cd' && now - m.at >= 3000) { m.state = 'fight'; m.at = now; log(`[room] ${room.id} 多人局 ${m.mid} 开打`); sendServerRoomMpm(room); }
        else if (m.state === 'fight') {
            if (now - m.at >= m.tl * 1000) serverRoomEnd(room, '时间到');
            else if (m.alive.size <= 1) serverRoomEnd(room, '只剩 ' + m.alive.size + ' 人');
            else if (now - m.lastMpm >= 1000) { m.lastMpm = now; sendServerRoomMpm(room); }
        } else if (m.state === 'end' && now - m.at > 8000) {
            room.match = null;
            room.started = 0;
            room.pairs.clear();
            room.taken.clear();
            for (const p of room.players.values()) { p.lastPick = ''; p.dead = 0; p.scored = 0; p.claimBy = null; }
            if (room.players.size >= room.size) serverRoomStart(room);
        }
    }
    if (room.players.size < 2) { room.started = 0; if (!room.match) { room.pairs.clear(); room.taken.clear(); } }
}



// 双栈。默认一个 socket 听 [::]，IPv4 / IPv6 都收（ipv6Only: false）；系统开不了 IPv6 时退回只听 0.0.0.0。
// --host 可以写多个（逗号分开或写多次），每个地址一个 socket：
// --host 0.0.0.0 只听 IPv4（和以前一字不差）
// --host 0.0.0.0,2001:db8::5 IPv4 + 一个指定的 IPv6 地址。机器有好几个公网 IPv6 时要这样写，并让域名的 AAAA 指向这个地址：
// 听 [::] 的 socket 回包时源地址由系统挑，可能不是玩家发过去的那个，玩家的路由器 / 防火墙会把回包当陌生包丢掉
// 回包从收到对方的那个 socket 出去（同一族开了好几个 socket 时按来源记着）
/** @type {{sock: import('node:dgram').Socket, host: string, kind: 4|6|46}[]} */
const socks = [];
const lastIn = new Map();          // 端点 → [socket, 时间]（同一族有好几个 socket 才记）
let multiV6 = false;
function sockFor(to, fam) {
    if (multiV6 && fam === 6) { const v = lastIn.get(to); if (v) return v[0]; }
    return socks.find((s) => s.kind === fam) || socks.find((s) => s.kind === 46) || null;
}
let ranked = null;
if (RANKED_FILE) {
    try {
        // 排位模块不在 4net 里，由游戏自己提供；默认还是和本文件同目录（线上部署就是这样放的），--ranked-module 可指定别处
        const rmod = arg('--ranked-module', process.env.RANKED_MODULE || '');
        const { createRanked } = await import(rmod ? (await import('node:url')).pathToFileURL(path.resolve(rmod)).href : WIRE_DEFAULTS.ranked);
        ranked = createRanked({ file: RANKED_FILE, log, send, webDir: arg('--web', process.env.RANKED_WEB || ''), cfgFile: arg('--ranked-cfg', process.env.RANKED_CFG || '') });
    } catch (e) {
        console.error(`[server] 给了 --ranked 但加载不了排位模块（默认是和本文件同目录的 ${WIRE_DEFAULTS.ranked}，或用 --ranked-module 指定）：${e.message}`);
        process.exit(1);
    }
}


// 数值表：读一次，之后每 5 秒看文件改没改
const cfg = { text: '', hash: '-', chunks: [] };
function fnv(s) {
    let h = 0x811c9dc5;
    for (const b of Buffer.from(s, 'utf8')) { h ^= b; h = Math.imul(h, 0x01000193) >>> 0; }
    return h.toString(16).padStart(8, '0');
}
function loadCfg() {
    let t;
    try { t = fs.readFileSync(CFG_FILE, 'utf8').replace(/^\uFEFF/, '').trim(); } catch (e) { console.error(`[cfg] 读不了 ${CFG_FILE}：${e.message}`); return; }
    if (!t.startsWith('v=') || /[\r\n]/.test(t)) { console.error(`[cfg] ${CFG_FILE} 不是一行数值表（要 v= 开头），不用`); return; }
    if (t === cfg.text) return;
    const buf = Buffer.from(t, 'utf8'), chunks = [];
    // 按字节切，但别切在 UTF-8 多字节字符中间（数值表本来全是 ASCII，保险）
    let i = 0;
    while (i < buf.length) {
        let j = Math.min(i + 900, buf.length);
        while (j < buf.length && (buf[j] & 0xc0) === 0x80) j--;
        chunks.push(buf.subarray(i, j).toString('utf8'));
        i = j;
    }
    Object.assign(cfg, { text: t, hash: fnv(t), chunks });
    console.log(`[cfg] 数值表 ${cfg.hash}（${buf.length} 字节，${chunks.length} 块）`);
}
if (CFG_FILE) {
    loadCfg();
    fs.watchFile(CFG_FILE, { interval: 5000 }, loadCfg);
}

// 排位封禁名单：一行一个排位 pid（0.34 起不认平台账号 ID）
let bans = new Set();
function loadBans() {
    let t = '';
    try { t = fs.readFileSync(BANS_FILE, 'utf8'); } catch (e) { console.error(`[bans] 读不了 ${BANS_FILE}：${e.message}`); return; }
    bans = new Set(t.split('\n').map((l) => l.replace(/#.*/, '').trim()).filter(Boolean));
    console.log(`[bans] 封禁名单 ${bans.size} 条`);
}
if (BANS_FILE) {
    loadBans();
    fs.watchFile(BANS_FILE, { interval: 5000 }, loadBans);
}
const banned = (...ids) => ids.some((x) => x && bans.has(x));


// 控制包标记 WS 和别名 WALIAS（WIRE_DEFAULTS.alias / --wire-alias，空 = 不认）双认；内部一律按 WS 处理，回包用对方来时的标记。
// 记谁用的别名（按 ip:port，10 分钟没来就忘；上限 5000 条）
const wireAlias = new Map();
function noteWire(from, isAlias, now) {
    if (isAlias) wireAlias.set(from, now); else if (wireAlias.has(from)) wireAlias.delete(from);
    if (wireAlias.size > 5000) for (const [k, t] of wireAlias) if (now - t > 600_000) wireAlias.delete(k);
}
function send(text, to) {
    const [host, port] = splitEp(to);
    if (typeof text === 'string' && text.startsWith(`${WS}|`) && wireAlias.has(to)) text = WALIAS + '|' + text.slice(WS.length + 1);     // 按标记长度切，别写死
    const fam = host.includes(':') ? 6 : 4;
    const s = sockFor(to, fam);
    if (!s) { stats.sendErr++; return; }     // 这一族没有能发的 socket（比如只开了 IPv4）
    // 双栈 socket 发 IPv4 要写成 ::ffff:a.b.c.d（直接写 a.b.c.d 是 EINVAL）。带回调：发送出错只计数，不走 socket 的 'error'（那里会退出进程）
    s.sock.send(Buffer.isBuffer(text) ? text : Buffer.from(text, 'utf8'), port, fam === 4 && s.kind !== 4 ? '::ffff:' + host : host, sendDone);
}
const sendDone = (err) => { if (err) stats.sendErr++; };

function mpTagInMatch(tag) {
    if (!tag) return false;
    return String(tag).split(';').some((p) => p === 'st=cd' || p === 'st=fight');
}

// "a.b.c.d:端口" / "[IPv6]:端口" → [地址（不带方括号）, 端口]
function splitEp(s) {
    s = String(s);
    if (s[0] === '[') {
        const rb = s.indexOf(']');
        return rb < 0 ? [s.slice(1), NaN] : [s.slice(1, rb), Number(s.slice(rb + 2))];
    }
    const i = s.lastIndexOf(':');
    return [s.slice(0, i), Number(s.slice(i + 1))];
}

// "域名或地址[:端口]"（--upstream 用）→ [主机, 端口]：[v6]:端口、裸 IPv6（多个冒号，不带端口）、a.b.c.d[:端口]、域名[:端口]
function splitHostPort(s, defPort) {
    s = String(s).trim();
    if (s[0] === '[') { const [h, p] = splitEp(s); return [h, Number.isFinite(p) && p > 0 ? p : defPort]; }
    const n = s.split(':').length - 1;
    if (n === 1) { const [h, p] = splitEp(s); return [h, Number.isFinite(p) && p > 0 ? p : defPort]; }
    return [s, defPort];
}

// 中转会话里某一端换了公网端口（NAT 重新映射；校园网这类大 NAT 很常见）：以前只认登记时的"IP:端口"，
// 换了端口的包一律丢掉，结果那一端只过得去第一个包。现在会话号对、IP 只和其中一端对得上，就认作那一端并更新端点。
// 两端同一个公网 IP（分不清是谁）或 IP 都对不上，还是只认原来的端点。
const ipOf = (e) => splitEp(e)[0];
function sideOf(s, from) {
    if (from === s.a) return 'a';
    if (from === s.b) return 'b';
    const ip = ipOf(from), ia = ipOf(s.a) === ip, ib = ipOf(s.b) === ip;
    if (ia === ib) return null;
    const side = ia ? 'a' : 'b';
    s.rebinds = (s.rebinds || 0) + 1;
    if (s.rebinds <= 5) log(`[relay] 会话 ${s.sid} ${side === 'a' ? '主机' : '客机'}换了端口（${ip16(from)}）`);     // 0.34 日志不写完整地址
    s[side] = from;
    stats.rebound++;
    ctr(s)[side === 'a' ? 'rebA' : 'rebB']++;
    return side;
}

function onControl(f, from, text) {
    const now = Date.now();
    switch (f[1]) {
        case 'PING':
            send(`${WS}|PONG|${from}`, from);
            return;
        case 'CFGQ': {     // 数值表（0.34 评审：整表几 KB，按源 IP 限速防反射放大）
            if (!rateOk(from, 'cfgq', 5_000, now)) { stats.dropped++; return; }
            if (!cfg.chunks.length) { send(`${WS}|CFG|-|0|0|`, from); return; }
            if (clean(f[2], 16) === cfg.hash) { send(`${WS}|CFG|${cfg.hash}|0|0|`, from); return; }
            cfg.chunks.forEach((c, k) => send(`${WS}|CFG|${cfg.hash}|${k + 1}|${cfg.chunks.length}|${c}`, from));
            return;
        }
        case 'REG': {
            const key = clean(f[2], 64);
            if (key.length < 8) return;
            const rk = f[8] === '1', pid = clean(f[9], 16);
            if (rk && !ranked) { send(`${WS}|ERR|-|noranked`, from); return; }
            if (rk && !ranked.known(pid)) { send(`${WS}|ERR|-|unknown`, from); return; }
            if (rk && banned(pid)) { send(`${WS}|ERR|-|banned`, from); return; }     // （0.34 只按 pid）
            let id = byKey.get(key);
            let room = id && rooms.get(id);
            if (!room) {
                if (rooms.size >= MAX_ROOMS) return;
                do id = newId(6); while (rooms.has(id));
                room = { id, key, seen: now };
                rooms.set(id, room);
                byKey.set(key, id);
                log(`[room] 新房间 ${id} 主机 ${ip16(from)} 名字 ${clean(f[3], 32)}`);     // 0.34 只写 IP 前两段
            }
            room.name = clean(f[3], 32) || '?';
            room.map = clean(f[4], 48);
            const mpMax = Number(clean(f[16], 8)) || 0;
            room.mpMax = mpMax > 0 ? mpMax : 0;
            if (room.mpMax > 0) {
                const cur = Number(clean(f[17], 8));
                room.mpCur = Number.isFinite(cur) && cur > 0 ? cur : 1;
                room.mpTag = clean(f[18], 128);
                room.full = f[5] === '1' || (room.mpCur >= room.mpMax);
            } else {
                room.mpCur = 0;
                room.mpTag = '';
                room.full = f[5] === '1';
            }
            // 这个房间的会话里主机端点也跟着换（心跳带主机密钥，就是主机本人；中转里已经换过的也一并改成最新的）
            for (const s of sessions.values()) if (s.room === id && s.a !== from) s.a = from;
            room.host = from;                       // 主机换了公网端口（NAT 重新映射）也跟着更新
            if (room.hostAlt && famOf(room.hostAlt) === famOf(from)) room.hostAlt = '';     // 主机换了登记用的地址族：原来记的另一族作废
            room.hostLocal = clean(f[6], 32);
            room.noRelay = f[7] === '0';            // 主机在设置里没允许中转
            room.ranked = rk;                       // 排位排位房间
            room.pid = rk ? pid : '';
            room.bridgeRoom = f[15] === '1';         // 0.34 第 16 段 = 房主开了"对局走桥接平台"（排位 0.34 起也默认直连，不再隐含）
            // 第 16 段 = 2：直连失败时走桥接。客机照常打洞直连；客机也带了桥接 ID 时互相介绍，直连不通再经桥接连。
            // 客机没带桥接 ID 也能进（只走直连）。旧服务端不认 2 = 普通直连房；旧客户端只认列表第 11 列 = 1，看到 2 当普通房
            room.bridgeFallback = f[15] === '2';
            room.bridge = room.bridgeRoom || room.bridgeFallback ? bridgeIdOf(f[10]) : '';   // 桥接平台房才记主机的平台账号 ID（内存里介绍完即弃，不落盘； / 总原则 3）
            room.watch = f[11] === '1' && !rk;         // 主机认观战（排位房间不给看）
            room.aiFight = f[13] === '1';           // 第 14 段 = 主机在和本地 AI 对打（列表第 9 列）
            room.bh = clean(f[14], 16);             // 第 15 段 = 主机标记（列表第 10 列）
            room.maxWatch = Math.min(MAX_WATCH, Number.isFinite(Number(f[12])) && f[12] !== undefined && f[12] !== '' ? Number(f[12]) : MAX_WATCH);   // 第 13 段 = 主机设的上限
            delete room.hostDeadAt;
            room.seen = now;
            send(regok(room, id, from, now), from);
            queueTick(room, now);
            return;
        }
        case 'UNREG': {
            const id = byKey.get(clean(f[2], 64));
            const room = id ? rooms.get(id) : null;
            if (!room) return;
            // 房里还有成员才等 REHOST；房主一个人开的房直接删（不然列表里留 10 秒、点进去连的是走了的人）
            const hasMembers = [...sessions.values()].some((x) => x.room === id);
            if (!room.hosted && room.mpMax > 0 && hasMembers) {
                room.hostDeadAt = Date.now();
                room.seen = 0;     // 标记旧房主已注销：REHOST 立即可接管，期间靠 hostDeadAt 在 TTL 内保活
                log(`[room] ${id} 多人房原房主注销，等待成员 REHOST`);
            } else {
                dropRoom(id, '主机注销');
            }
            return;
        }
        case 'REHOST': {
            const id = clean(f[2], 16).toUpperCase();
            const oldSid = clean(f[3], 16);
            const newKey = clean(f[4], 64);
            const localAddr = clean(f[5], 32);
            if (!id || !oldSid || newKey.length < 8) return;
            const room = rooms.get(id);
            if (!room) { send(`${WS}|ERR|${id}|nofound`, from); return; }
            if (room.hosted) return;
            if (room.seen > 0 && (now - room.seen) <= 6000) {
                send(`${WS}|ERR|${id}|hostalive`, from);
                return;
            }
            let matchSid = null;
            for (const [sidKey, s] of sessions) {
                if (s.room === id && s.sid === oldSid) {
                    matchSid = sidKey;
                    break;
                }
            }
            if (!matchSid) { send(`${WS}|ERR|${id}|auth`, from); return; }

            if (room.key) byKey.delete(room.key);
            room.key = newKey;
            byKey.set(newKey, id);
            room.host = from;
            if (localAddr) room.hostLocal = localAddr;
            delete room.hostDeadAt;
            room.seen = now;

            sessions.delete(matchSid);

            for (const s of sessions.values()) {
                if (s.room === id && s.b !== from) s.a = from;
            }

            log(`[room] 换房主 房间 ${id} 新主机 ${ip16(from)}`);
            send(`${WS}|REHOSTOK|${id}|${from}`, from);
            return;
        }
        case 'LIST': {
            // 自己的房间排前面，再是别的服务器的；各自未满的在前； 排位开的房间排最前
            const title = (r) => (r.ranked && ranked ? ranked.titleOf(r.pid) : '');
            const mpInfo = (r) => {
                if (r.hosted && r.kind === 'mp') {
                    const cur = r.players ? r.players.size : 0;
                    return `${cur}/${r.size};k=srv;m=${r.mpMode || 'elim'};tm=${r.mpTeams ? 1 : 0};st=${r.mpState || 'idle'}`;
                }
                if (r.mpMax > 0) {
                    return `${r.mpCur || 1}/${r.mpMax}${r.mpTag ? ';' + r.mpTag : ''}`;
                }
                return '';
            };
            const order = (x, y) => Number(!x.title) - Number(!y.title) || Number(x.full) - Number(y.full) || y.seen - x.seen;
            // 玩家开的多人房：房主已注销 / 6 秒没心跳（等成员 REHOST 中）先不列，免得新人连到走了的房主
            const waitingRehost = (r) => !r.hosted && r.mpMax > 0 && (r.hostDeadAt || (r.seen > 0 && now - r.seen > 6000));
            const own = [...rooms.values()].filter((r) => !waitingRehost(r)).map((r) => ({ ...r, home: '', title: title(r) })).sort(order);
            // LIST|code：手输房间号先查连接策略，不受普通列表前 40 间截断影响；不改变普通 LIST。
            const wanted = clean(f[2], 16).toUpperCase();
            const all = own.concat([...remote.values()].sort(order));
            const list = (wanted ? all.filter((r) => r.id === wanted) : all).slice(0, MAX_LIST);
            // 第 8 列 = 能观战（主机认观战、这台开了中转、是这台自己的房间）； 第 11 列 2 = 直连失败时走桥接； 第 12 列 = 多人信息
            send(`${WS}|ROOMS\n` + list.map((r) => `${r.id}\t${r.name}\t${r.map}\t${r.full ? 1 : 0}\t${r.home}\t${r.ranked ? 1 : 0}\t${r.title || ''}\t${r.watch && (RELAY_WATCH || r.hosted) && !r.home ? 1 : 0}\t${r.aiFight ? 1 : 0}\t${r.bh || ''}\t${r.bridgeRoom ? 1 : r.bridgeFallback ? 2 : 0}\t${mpInfo(r)}`).join('\n'), from);     // 0.34 第 11 列 = 对局走桥接平台
            return;
        }
        case 'WATCH': {
            const id = clean(f[2], 16).toUpperCase();
            const room = rooms.get(id);
            if (!room) { send(`${WS}|ERR|${id}|nofound`, from); return; }
            if (room.ranked) { send(`${WS}|ERR|${id}|ranked`, from); return; }
            if (!room.watch) { send(`${WS}|ERR|${id}|nowatch`, from); return; }
            if (!RELAY_WATCH && !room.hosted) { send(`${WS}|ERR|${id}|norelay`, from); return; }      // 服务器自己的房不收上传，不靠 --relay 也能看
            room.watchers ??= new Map();
            watchCount(room, now);
            const w = room.watchers.get(from);
            if (!w) {
                if (room.watchers.size >= (room.maxWatch ?? MAX_WATCH)) { send(`${WS}|ERR|${id}|watchfull`, from); return; }
                room.watchers.set(from, { seen: now, down: f[3] === 'down', noq: f[4] === 'noq', dz: f[5] === 'dz' });
                log(`[watch] ${ip16(from)} 观战房间 ${id}${f[3] === 'down' ? '（刚下场）' : ''}${f[4] === 'noq' ? '（只观战）' : ''}`);
            } else { w.seen = now; w.noq = f[4] === 'noq'; w.dz = f[5] === 'dz'; if (f[3] === 'up') w.down = false; }     // 观战者切回了排队； 会不会拼省流包
            // 观战者都会不会拼变了（来了个旧版 / 旧版走了在 watchCount 里）、 或者来了个新观战者（人数变了，
            // 主机要发一次全量给新来的）：马上告诉主机，不等它下次心跳
            const allDz = allWatchDz(room);
            if ((!w || allDz !== room.lastAllDz) && room.host) send(regok(room, id, room.host, now), room.host);
            const queue = [...room.watchers].filter(([, v]) => !v.noq).map(([k]) => k);
            const pos = queue.indexOf(from) + 1;
            send(`${WS}|WATCHOK|${id}|${room.watchers.size}|${pos}`, from);
            if (room.reserve?.ep === from && now <= room.reserve.until) send(`${WS}|YOURTURN|${id}|${room.reserve.token}`, from);
            return;
        }
        case 'HOSTDOWN': case 'HOSTUP': {
            const id = byKey.get(clean(f[2], 64));
            const room = id && rooms.get(id);
            if (!room || room.host !== from || !RELAY_WATCH) return;
            if (f[1] === 'HOSTUP') {
                if (room.second) { send(`${WS}|SECOND|${id}|0`, room.second); log(`[watch] 房间 ${id} 主机回来打，第二位 ${ip16(room.second)} 回去观战`); }
                room.second = null;
                return;
            }
            if (room.second && room.watchers?.has(room.second)) { send(`${WS}|SECOND|${id}|1`, room.second); return; }
            watchCount(room, now);
            const head = [...(room.watchers ?? [])].find(([, v]) => !v.down && !v.noq && now - v.seen <= WATCH_TTL);
            if (!head) return;
            room.second = head[0];
            for (const v of room.watchers.values()) v.down = false;
            log(`[watch] 房间 ${id} 主机下场，第二位 ${ip16(room.second)}`);
            send(`${WS}|SECOND|${id}|1`, room.second);
            return;
        }
        case 'UNWATCH': {
            const room = rooms.get(clean(f[2], 16).toUpperCase());
            if (room?.watchers?.delete(from)) log(`[watch] ${ip16(from)} 不看房间 ${room.id} 了`);
            return;
        }
        case 'PUSHOK': {
            const u = upstreamAt(from);
            if (u && u.self !== clean(f[2], 64)) { u.self = clean(f[2], 64); log(`[upstream] ${u.addr} 看到的本机地址 ${u.self}`); }
            return;
        }
        case 'JOIN': {
            const id = clean(f[2], 16).toUpperCase();
            const room = rooms.get(id);
            if (!room) { send(`${WS}|ERR|${id}|nofound`, from); return; }
            if (room.hosted) { serverRoomJoin(room, from, f, now); return; }      // 服务器自己开的房
            const cpid = clean(f[4], 16);
            let cbridge = bridgeIdOf(f[5]);
            // 轮到队首上场的这段时间，只放拿着口令的（队首）进来
            const rs = room.reserve;
            if (rs && now <= rs.until && clean(f[6], 16) !== rs.token
                && ![...sessions.values()].some((x) => x.room === id && x.b === from)) { send(`${WS}|ERR|${id}|full`, from); return; }
            if (rs && clean(f[6], 16) === rs.token) {
                log(`[watch] 房间 ${id} 队首 ${ip16(rs.ep)} 上场（${ip16(from)}）`);
                room.watchers?.delete(rs.ep);
                for (const v of room.watchers?.values() ?? []) v.down = false;
                room.reserve = null;
                room.full = false;
            }
            if (room.ranked && !(ranked && ranked.known(cpid) && cpid !== room.pid)) { send(`${WS}|ERR|${id}|ranked`, from); return; }
            if (room.ranked && banned(cpid)) { send(`${WS}|ERR|${id}|banned`, from); return; }     // （0.34 只按 pid）
            // 0.34 对局走桥接平台的房：客机也要带平台账号 ID（没带 = 没开桥接平台 / 没开"对局走桥接平台"）；不是桥接平台房就不管客机带没带（不介绍、不记）
            if (room.bridgeRoom && !cbridge) { send(`${WS}|ERR|${id}|needsteam`, from); return; }
            if (!room.bridgeRoom && !room.bridgeFallback) cbridge = '';
            // 同一个客机端点重发 JOIN（每次直连重试都会发）沿用原会话号
            let s = [...sessions.values()].find((x) => x.room === id && x.b === from && x.a === room.host);
            if (!s) {
                // 多人房对局中也能进（以前 mpTagInMatch 就回 inmatch，连对决的观众也被挡）
                if (room.full) { send(`${WS}|ERR|${id}|full`, from); return; }
                s = { sid: newId(10), room: id, a: room.host, b: from, relay: false, seen: now, rate: {} };
                room.hadPeer = true;
                sessions.set(s.sid, s);
                log(`[join] ${ip16(from)} → 房间 ${id}（主机 ${ip16(room.host)}），会话 ${s.sid}`);
            }
            s.bLocal = clean(f[3], 32);
            s.seen = now;
            if (room.ranked) ranked.session(s.sid, room.pid, cpid);
            s.bBridge = cbridge;
            // 第 7 段 = 对方的平台账号 ID（排位房间才有；旧版联机程序只看前 6 段）
            // 0.34 评审：主机的平台账号 ID只给自己也报了平台账号 ID的客机，同一来源 IP 对同一房间 30 秒一次（外人拿 LIST 扫桥接平台房批量收割主机平台账号 ID的成本）
            // 同 NAT 多成员共用固定的 IP / 房间预算（最多 16 次 / 30 秒），不把客机可控 ID 放进限流 key。
            // 同一会话重发 JOIN 沿用介绍；旧版 1v1 / 排位仍是每 IP / 房间 30 秒一次。
            const mpBridge = room.mpMax >= 2 && room.bridgeRoom;
            const introBudget = mpBridge ? Math.min(16, room.mpMax) : 1;
            const giveBridge = room.bridge && cbridge && ((mpBridge && s.bridgeGiven === cbridge)
                || rateOk(from, 'peer:' + id, 30_000, now, introBudget));
            if (mpBridge && giveBridge) s.bridgeGiven = cbridge;
            if (room.bridgeRoom && room.bridge && !giveBridge) { send(`${WS}|ERR|${id}|needsteam`, from); sessions.delete(s.sid); return; }     // 直连失败走桥接的房：没给成也照常直连
            // 双栈：两边都可能从另一族报过地址（ALT）。第 5 段先给对方那一族的地址，第 8 段给剩下那一族（客户端两个都打洞）
            const [hMain, hOther] = introAddrs(room.host, liveAlt(room.hostAlt, room.hostAltSeen, now), from);
            const [cMain, cOther] = introAddrs(from, liveAlt(s.bAlt, s.bAltSeen, now), room.host);
            send(peerMsg(id, s.sid, hMain, room.hostLocal, giveBridge ? room.bridge : '', hOther), from);
            send(peerMsg(id, s.sid, cMain, s.bLocal, cbridge, cOther), room.host);
            return;
        }
        case 'ALT': {
            // 双栈客户端从另一族再报一次自己（和服务器说话用的那一族之外的那个）：
            // 主机 → 4N|ALT|h|<密钥> 每次心跳一起发；客机 → 4N|ALT|c|<会话号> 拿到 PEER 后发
            // ← 4N|ALTOK|<h/c>|<服务器看到的这个地址>。同一族的不算（那不是"另一族"）；旧服务端不认 ALT，丢掉，客户端照旧
            if (f[2] === 'h') {
                const id = byKey.get(clean(f[3], 64));
                const room = id && rooms.get(id);
                if (!room || room.hosted || !room.host || famOf(from) === famOf(room.host)) return;
                if (room.hostAlt !== from) log(`[room] ${id} 主机另一族地址（IPv${famOf(from)}）${ip16(from)}`);
                room.hostAlt = from;
                room.hostAltSeen = now;
                send(`${WS}|ALTOK|h|${from}`, from);
                return;
            }
            if (f[2] === 'c') {
                const s = sessions.get(clean(f[3], 16));
                const room = s && rooms.get(s.room);
                if (!room || room.hosted || famOf(from) === famOf(s.b)) return;
                s.seen = now;
                send(`${WS}|ALTOK|c|${from}`, from);
                const changed = s.bAlt !== from || !liveAlt(s.bAlt, s.bAltSeen, now);
                s.bAlt = from;
                s.bAltSeen = now;
                if (!changed) return;
                log(`[join] 会话 ${s.sid} 客机另一族地址（IPv${famOf(from)}）${ip16(from)}`);
                // 告诉主机（同一个会话再发一次 PEER，多一个打洞候选；旧主机只看前 7 段，等于重发一次）
                const [cMain, cOther] = introAddrs(s.b, from, room.host);
                send(peerMsg(room.id, s.sid, cMain, s.bLocal, s.bBridge || '', cOther), room.host);
            }
            return;
        }
        case 'RELAY': {
            const s = sessions.get(clean(f[2], 16));
            if (!s || !sideOf(s, from)) { send(`${WS}|ERR|${clean(f[2], 16)}|nosession`, from); return; }
            const room = rooms.get(s.room);
            if (room && room.mpMax > 0) { s.seen = now; send(`${WS}|ERR|${s.sid}|norelay`, from); return; }
            if (!RELAY_MATCH) { s.seen = now; send(`${WS}|ERR|${s.sid}|norelay`, from); return; }
            if (room?.noRelay) { s.seen = now; send(`${WS}|ERR|${s.sid}|hostnorelay`, from); return; }
            if (!s.relay) log(`[relay] 会话 ${s.sid} 改走中转（${ip16(s.a)} ⇄ ${ip16(s.b)}）`);
            if (!s.relay) note(`[relay-diag] 会话 ${s.sid} 房间 ${s.room} 改走中转（${from === s.a ? '主机' : '客机'}先请求）`);
            s.relay = true;
            s.seen = now;
            send(`${WS}|RELAYOK|${s.sid}`, from);
            send(`${WS}|RELAYON|${s.sid}`, from === s.a ? s.b : s.a);
            return;
        }
        case 'SREPORT': {      // 服务器房：玩家低频上报（校验 / 计分 / 捡道具用； 头里带会话口令）
            if (serverRoom) serverRoomReport(serverRoom, from, f, now);
            return;
        }
        case 'SCHAT': {        // 服务器房：聊天由服务器广播（第 3 段 = 会话口令）
            if (serverRoom) serverRoomChat(serverRoom, from, clean(f[2], 32), f.slice(3).join('|'), Buffer.byteLength(text), now);
            return;
        }
        case 'SRELAY': {       // 服务器房：直连不通，请求服务器替这一对中转（第 4 段 = 会话口令）
            const room = serverRoom;
            const p = room && serverRoomAuth(room, from, clean(f[3], 32), 'srelay', Buffer.byteLength(text), now);
            if (!room || !p) return;
            const to = Number(clean(f[2], 8));
            if (!room.players.has(to)) { send(`${WS}|ERR|${room.id}|nofound`, from); return; }
            if (!RELAY_MATCH) { send(`${WS}|ERR|${room.id}|norelay`, from); return; }
            p.relayTo = to;
            send(`${WS}|SRELAYOK|${to}`, from);
            log(`[room] ${room.id} 服务器中转：${p.pid} → ${to}`);
            return;
        }
        case 'SLEAVE': {
            const room = serverRoom;
            const p = room && serverRoomAuth(room, from, clean(f[2], 32), 'srelay', Buffer.byteLength(text), now);
            if (room && p) serverRoomDrop(room, p, '主动离开');
            return;
        }
        default:
            if (ranked && f[1]?.[0] === 'R' && ranked.onControl(f, from)) return;
            stats.dropped++;
    }
}

// 4NR|<会话号>\n<状态包>：按来源转给另一方。只转发会话里登记过的两个端点之间的包
function onRelay(buf, from) {
    const nl = buf.indexOf(10);
    if (nl < 0 || nl > 40) { stats.dropped++; return; }
    const s = sessions.get(buf.toString('utf8', FWD_LEN, nl));
    if (!s) { stats.dropped++; return; }
    const room = rooms.get(s.room);
    if (room && room.mpMax > 0) { stats.dropped++; return; }     // 多人房一律直连，不走中转
    if (!s.relay) { stats.dropped++; ctr(s).early++; return; }
    const side = sideOf(s, from);           // 端口换了也认（按会话号 + IP）
    if (!side) {
        stats.dropped++;
        const c = ctr(s);
        c.unk++;
        if (ip16(from) === ip16(s.a)) c.unkA++;
        else if (ip16(from) === ip16(s.b)) c.unkB++;
        return;
    }
    const to = side === 'a' ? s.b : s.a;
    const now = Date.now();
    const sec = Math.floor(now / 1000);
    const r = s.rate[from] ?? (s.rate[from] = { sec, n: 0 });
    if (r.sec !== sec) { r.sec = sec; r.n = 0; }
    if (++r.n > RELAY_RATE) { stats.dropped++; ctr(s).rate++; return; }
    s.seen = now;
    stats.relayed++;
    ctr(s)[side === 'a' ? 'ab' : 'ba']++;
    send(buf, to);
}

// 观战人数（顺带移出 6 秒没保活的）
// 现在的观战者都会拼省流观战包（WATCH 第 6 段 dz）
function allWatchDz(room) {
    return !!room.watchers && room.watchers.size > 0 && [...room.watchers.values()].every((v) => v.dz);
}

// 主机的 REGOK：房间号 / 主机公网地址 / 观战人数 / 有没有第二位 / 观战者都会拼省流包（旧主机不看第 7 段）
function regok(room, id, hostAddr, now) {
    const nw = watchCount(room, now);
    room.lastAllDz = allWatchDz(room);
    return `${WS}|REGOK|${id}|${hostAddr}|${nw}|${room.second && room.watchers?.has(room.second) ? 1 : 0}|${room.lastAllDz ? 1 : 0}`;
}

// PEER：第 7 段 = 桥接 ID（没有就空着），第 8 段 = 对方另一族的地址（没有就不带这段；旧客户端只看前 7 段）
function peerMsg(id, sid, main, local, bridge, other) {
    return `${WS}|PEER|${id}|${sid}|${main}|${local}` + (other ? `|${bridge || ''}|${other}` : bridge ? `|${bridge}` : '');
}
// 介绍一端给对方：对方那一族的地址放前面（第 5 段），另一个放第 8 段
function introAddrs(main, alt, toward) {
    if (alt && famOf(alt) !== famOf(main) && famOf(alt) === famOf(toward)) return [alt, main];
    return [main, alt || ''];
}
const liveAlt = (a, seen, now) => (a && now - (seen || 0) <= ROOM_TTL ? a : '');

// 0.34 评审：按来源 IP + 用途限速（STATUS / CFGQ 反射放大、桥接平台房介绍收割）。表每分钟清一次过期项
const rateTab = new Map();
let rateSweep = 0;
function rateOk(from, what, everyMs, now, budget = 1) {
    const ip = from.lastIndexOf(':') > 0 ? ipOf(from) : from;     // [IPv6]:端口 也按地址算
    const k = ip + '|' + what;
    if (now - rateSweep > 60_000) { rateSweep = now; for (const [kk, t] of rateTab) if (now - t.at > 120_000) rateTab.delete(kk); }
    let window = rateTab.get(k);
    if (!window || now - window.at >= everyMs) { window = { at: now, used: 0 }; rateTab.set(k, window); }
    if (window.used >= budget) return false;
    window.used++;
    return true;
}

function watchCount(room, now) {
    if (!room.watchers) return 0;
    for (const [w, v] of room.watchers) if (now - v.seen > WATCH_TTL) { room.watchers.delete(w); if (room.second === w) room.second = null; log(`[watch] ${w} 观战超时`); }
    return room.watchers.size;
}

// 主机心跳时看一次：有过对手、现在没满、有人排队 → 叫队首（跳过刚下场的）。满了就取消（多人房不用）
function queueTick(room, now) {
    if (room.mpMax > 0 || !room.watch || !room.watchers?.size) { room.reserve = null; return; }
    if (room.full) { room.hadPeer = true; room.reserve = null; return; }
    if (!room.hadPeer) return;
    if (!room.reserve || now > room.reserve.until) {
        const head = [...room.watchers].find(([, v]) => !v.down && !v.noq && now - v.seen <= WATCH_TTL);
        if (!head) { room.reserve = null; return; }
        room.reserve = { ep: head[0], token: newId(8), until: now + 15_000 };
        log(`[watch] 房间 ${room.id} 没满，叫队首 ${ip16(head[0])} 上场`);
    }
    send(`${WS}|YOURTURN|${room.id}|${room.reserve.token}`, room.reserve.ep);
}

// 4NW|<房间号>\n<包>：主机上传的观战包，原样发给这个房间的每个观战者。只认这个房间登记的主机端点
function onWatchUp(buf, from) {
    const nl = buf.indexOf(10);
    if (nl < 0 || nl > 24) { stats.dropped++; return; }
    const room = rooms.get(buf.toString('utf8', FWD_LEN, nl));
    if (!room || room.host !== from || !room.watchers || room.watchers.size === 0 || !RELAY_WATCH) { stats.dropped++; return; }
    const sec = Math.floor(Date.now() / 1000);
    const r = room.wrate ?? (room.wrate = { sec, n: 0 });
    if (r.sec !== sec) { r.sec = sec; r.n = 0; }
    if (++r.n > WATCH_RATE) { stats.dropped++; return; }
    // 省流包（包里有 dz=1 一行）只发给会拼的观战者：旧版观战者刚进来、主机还没收到 REGOK 改发完整包的那一小会儿，宁可少收几包也不收拼不了的
    const dz = buf.includes('\ndz=1\n');
    for (const [w, v] of room.watchers) { if (w === room.second || (dz && !v.dz)) continue; stats.relayed++; send(buf, w); }
}

// 主机下场时第二位选手和主机之间的包：4NV（第二位 → 主机）、4NU（主机 → 第二位）
function onSecond(buf, from, up) {
    const nl = buf.indexOf(10);
    if (nl < 0 || nl > 24) { stats.dropped++; return; }
    const room = rooms.get(buf.toString('utf8', FWD_LEN, nl));
    if (!room || !room.second || !RELAY_MATCH) { stats.dropped++; return; }     // 0.34 评审：这是对局数据（第二位 ⇄ 主机），归对局中转管，不归观战
    if (up ? from !== room.second : from !== room.host) { stats.dropped++; return; }
    const sec = Math.floor(Date.now() / 1000);
    const r = room.srate ?? (room.srate = { sec, n: 0 });
    if (r.sec !== sec) { r.sec = sec; r.n = 0; }
    if (++r.n > RELAY_RATE * 2) { stats.dropped++; return; }
    if (up) { const w = room.watchers?.get(from); if (w) w.seen = Date.now(); }
    stats.relayed++;
    send(buf, up ? room.host : room.second);
}

function dropRoom(id, why) {
    const room = rooms.get(id);
    if (!room) return;
    rooms.delete(id);
    byKey.delete(room.key);
    log(`[room] 删除房间 ${id}（${why}）`);
}

function upstreamAt(from) {
    for (const u of upstreams.values()) if (u.ep === from) return u;
    return null;
}

// 别的服务器推来的房间：所在服务器 = 来源地址
function onPush(lines, from) {
    // 评审提过『只收配置过的上游』——不行：PUSH 是下游推给上游、上游不配下游（文件头 的设计），限制了互通就断。假房注入靠 MAX_REMOTE_PER_SOURCE 兜底，记在
    const now = Date.now();
    let have = 0;
    for (const r of remote.values()) if (r.via === from) have++;
    for (const line of lines) {
        const p = line.split('\t');
        if (p.length < 4) continue;
        const id = clean(p[0], 16).toUpperCase();
        const key = `${from}|${id}`;
        if (!remote.has(key)) { if (have >= MAX_REMOTE_PER_SOURCE) break; have++; }
        remote.set(key, { id, name: clean(p[1], 32) || '?', map: clean(p[2], 48), full: p[3] === '1', home: from, via: from, seen: now });
    }
    send(`${WS}|PUSHOK|${from}`, from);
}

// 从上游拉来的列表：所在服务器为空 = 就是那台上游；跳过所在服务器是本机的（是我们推过去的）
function onUpstreamRooms(u, lines) {
    const now = Date.now();
    let n = 0;
    for (const line of lines) {
        const p = line.split('\t');
        if (p.length < 4) continue;
        const home = clean(p[4], 64) || u.ep;
        if (home === u.self || n >= MAX_REMOTE_PER_SOURCE) continue;
        const id = clean(p[0], 16).toUpperCase();
        remote.set(`${home}|${id}`, { id, name: clean(p[1], 32) || '?', map: clean(p[2], 48), full: p[3] === '1', home, via: u.ep, seen: now });
        n++;
    }
}

function upstreamTick() {
    const now = Date.now();
    for (const u of upstreams.values()) {
        if (!u.ep || now - u.lookedUp > 60_000) {
            u.lookedUp = now;
            const [host, port] = splitHostPort(u.addr, 27020);
            // 先找 IPv4（和以前一样）；没有 IPv4、这台又开了 IPv6 才用 IPv6
            dns.lookup(host, { all: true }, (err, addrs) => {
                const a = !err && (addrs.find((x) => x.family === 4) || (sockFor('', 6) ? addrs.find((x) => x.family === 6) : null));
                if (!a) { log(`[upstream] 解析不了 ${u.addr}：${err ? err.message : '没有能用的地址'}`); return; }
                const e = fmtEp(normAddr(a.address), port);
                if (u.ep !== e) log(`[upstream] ${u.addr} = ${e}`);
                u.ep = e;
            });
        }
        if (!u.ep) continue;
        const own = [...rooms.values()].filter((r) => !r.ranked);
        if (own.length === 0) send(`${WS}|PUSH`, u.ep);      // 没房间也推一次空的：拿 PUSHOK 知道自己的公网地址
        for (let i = 0; i < own.length; i += PUSH_CHUNK) {
            send(`${WS}|PUSH\n` + own.slice(i, i + PUSH_CHUNK).map((r) => `${r.id}\t${r.name}\t${r.map}\t${r.full ? 1 : 0}`).join('\n'), u.ep);
        }
        send(`${WS}|LIST`, u.ep);
    }
}

function onMessage(buf, rinfo, rs) {
    stats.rx++;
    const from = ep(rinfo);
    if (multiV6 && rs.kind !== 4 && famOf(from) === 6) {     // 同一族好几个 socket：记着从哪个收到的，回包从它出去
        const now = Date.now();
        lastIn.set(from, [rs, now]);
        if (lastIn.size > 20000) for (const [k, v] of lastIn) if (now - v[1] > 600_000) lastIn.delete(k);
    }
    const up = upstreams.size > 0 ? upstreamAt(from) : null;
    // 上游回的列表可能比一个普通包大（40 个房间）；其余来源超长的一律丢
    // 观战 / 中转 / 第二位转发的是完整状态包（实测 2.4–2.6 KB），以前一律按 1400 丢 = 服务器大厅观战、中转对局全收不到；
    // 这四种转发包放宽到 MAX_FWD，控制包仍按 MAX_PACKET
    if (buf.length > MAX_PACKET && !up && !(buf.length <= MAX_FWD && FWD_HEADS.has(buf.toString('latin1', 0, FWD_LEN)))) { stats.dropped++; return; }
    if (buf.length > FWD_LEN && buf.toString('latin1', 0, FWD_LEN) === `${WP}R|`) { onRelay(buf, from); return; }
    if (buf.length > FWD_LEN && buf.toString('latin1', 0, FWD_LEN) === `${WP}W|`) { onWatchUp(buf, from); return; }
    if (buf.length > FWD_LEN && buf.toString('latin1', 0, FWD_LEN) === `${WP}V|`) { onSecond(buf, from, true); return; }
    if (buf.length > FWD_LEN && buf.toString('latin1', 0, FWD_LEN) === `${WP}U|`) { onSecond(buf, from, false); return; }
    if (buf.length > SSTATE.length && buf.toString('latin1', 0, SSTATE.length) === SSTATE) { if (serverRoom) serverRoomState(serverRoom, from, buf.toString('utf8'), Date.now()); return; }     // 观战转发（带状态包原文； 带会话口令）
    if (buf.length > SRLY.length && buf.toString('latin1', 0, SRLY.length) === SRLY) { if (serverRoom) serverRoomRelay(serverRoom, from, buf.toString('utf8'), Date.now()); return; }        // 服务器中转（带会话口令）
    let text = buf.toString('utf8');
    const isAlias = WALIAS !== '' && WALIAS !== WS && text.startsWith(WALIAS + '|');
    if (isAlias) text = `${WS}|` + text.slice(WALIAS.length + 1);     // 别名：内部按 WS 处理
    if (!text.startsWith(`${WS}|`)) { stats.dropped++; return; }
    noteWire(from, isAlias, Date.now());
    try {
        if (text.startsWith(`${WS}|PUSH\n`) || text === `${WS}|PUSH`) { onPush(text.split('\n').slice(1), from); return; }
        if (text.startsWith(`${WS}|ROOMS`)) { if (up) onUpstreamRooms(up, text.split('\n').slice(1)); return; }
        onControl(text.split('|'), from, text);
    } catch (e) { log('[err]', e); }
}

setInterval(() => {
    const now = Date.now();
    for (const r of rooms.values()) if (!r.hosted && now - Math.max(r.seen, r.hostDeadAt || 0) > ROOM_TTL) dropRoom(r.id, '心跳超时');
    for (const s of sessions.values()) {
        if (now - s.seen > SESSION_TTL) {
            sessions.delete(s.sid);
            log(`[session] 会话 ${s.sid} 超时删除`);
            if (s.ctr) relaySummary(s, '结束');
        } else if (s.relay) relaySummary(s, '定时');   // 中转中每 2 秒看一次，有变化才写
    }
    for (const [k, r] of remote) if (now - r.seen > ROOM_TTL) remote.delete(k);
    if (ranked) ranked.tick();
}, 2000).unref();

if (upstreams.size > 0) {
    setInterval(upstreamTick, 2000).unref();
    setTimeout(upstreamTick, 200);
}

setInterval(() => {
    log(`[stat] 房间 ${rooms.size}（别的服务器的 ${remote.size}） 会话 ${sessions.size} 收包 ${stats.rx} 转发 ${stats.relayed} 丢弃 ${stats.dropped} 换端口 ${stats.rebound}${stats.sendErr ? ' 发送失败 ' + stats.sendErr : ''}`);
}, 60_000).unref();

if (ROOM_KIND) {
    serverRoom = createServerRoom();
    setInterval(() => serverRoomTick(Date.now()), 500).unref();      // 服务器房：0.5 秒看一次计时 / 掉线 / 开打
}

// 开 socket：每个 --host 一个。默认 :: 开不了（系统关了 IPv6）就退回 0.0.0.0（只有 IPv4，和以前一样）
function bindOne(host) {
    return new Promise((resolve, reject) => {
        const v6 = host.includes(':');
        const kind = !v6 ? 4 : host === '::' ? 46 : 6;
        let s;
        try { s = dgram.createSocket(v6 ? { type: 'udp6', ipv6Only: kind === 6 } : 'udp4'); } catch (e) { reject(e); return; }
        const fail = (e) => { try { s.close(); } catch { /* 已关 */ } reject(e); };
        s.once('error', fail);
        s.bind(PORT, host, () => {
            s.off('error', fail);
            const rs = { sock: s, host, kind };
            s.on('message', (buf, rinfo) => onMessage(buf, rinfo, rs));
            s.on('error', (e) => { console.error(`[server] socket（${host}）出错：`, e.message); process.exit(1); });
            resolve(rs);
        });
    });
}
for (const h of HOSTS) {
    try { socks.push(await bindOne(h)); }
    catch (e) {
        if (h === '::' && !HOST_GIVEN) {
            console.error(`[server] 开不了 IPv6（${e.code || e.message}），只听 IPv4`);
            try { socks.push(await bindOne('0.0.0.0')); continue; } catch (e2) { e = e2; }
        }
        console.error(`[server] 开不了 UDP ${h}:${PORT}：${e.message}`);
        process.exit(1);
    }
}
multiV6 = socks.filter((s) => s.kind !== 4).length > 1;
{
    const where = socks.map((s) => `${fmtEp(s.host, s.sock.address().port)}${s.kind === 46 ? '（IPv4 + IPv6）' : ''}`).join('、');
    console.log(`[server] 4net 大厅服务器已启动：UDP ${where}`
        + (RELAY_MATCH ? '；对局中转开' : '；对局中转关') + (RELAY_WATCH ? '；观战转发开' : '；观战转发关（--relay 两个都开，--relay-watch 只开观战）')
        + (ranked ? `；排位开（${RANKED_FILE}）` : '')
        + (serverRoom ? `；服务器自己开房 ${serverRoom.id}（${serverRoom.kind === 'mp' ? serverRoom.size + ' 人混战' : '1v1'}）` : '')
        + (BANS_FILE ? `；排位封禁名单（${BANS_FILE}）` : '')
        + (upstreams.size ? `；互通上游 ${[...upstreams.keys()].join(', ')}` : ''));
}

for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { if (ranked) ranked.flush(); for (const x of socks) try { x.sock.close(); } catch { /* 已关 */ } process.exit(0); });
