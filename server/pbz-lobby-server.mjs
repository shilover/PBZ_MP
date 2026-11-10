// PBZ_MP 服务器大厅（docs/HANDOVER.md §47）：房间登记 / 列表 + UDP 打洞介绍 + 直连不通时的中转。
// 只用 Node 自带的 dgram，一个 UDP 端口干全部的事；不存盘，重启后房间由主机的心跳（每 2 秒一次）自己补回来。
// 许可证 AGPL-3.0（见 server/LICENSE），不提供任何担保。架这台服务器的人是服务运营者，自己负责当地合规（server/README.md）。
//
//   node server/pbz-lobby-server.mjs [--port 27020] [--host 0.0.0.0] [--relay] [--quiet] [--upstream 域名或IP:端口 …]
//   环境变量 PORT / HOST / RELAY=1 也行。--upstream 可以写多个（HANDOVER §50 服务器互通）。
//   --relay：打洞不通时替双方转发状态包。默认关：中转是服务器几乎全部的带宽（每对玩家约 50 KB/秒），
//   关着时服务器只登记房间、介绍地址，客机请求中转会收到 ERR …|norelay。
//
// 协议（文本，一个 UDP 包一条；字段用 | 分开，服务器收到的字段里的 | \t \n 都会被替换掉）：
//   主机 → PBZS|REG|<密钥>|<名字>|<地图>|<已满 0/1>|<局域网地址 IP:端口>|<允许中转 0/1>[|<排位 0/1>|<主机 pid>]   每 2 秒；10 秒没收到就删房间
//        （第 7 段旧版联机程序不发，当允许；主机发 0 时这个房间的会话一律不中转。第 8、9 段 = 武林盟主排位房间，HANDOVER §110：
//         服务器没开 --ranked → ERR|-|noranked，主机 pid 没登记 → ERR|-|unknown，都不登记；
//         §135 第 10 段 = 主机的 SteamID：排位对局只走 Steam，服务器只管登记 / 介绍 / 记分，不打洞、不中转）
//        ← PBZS|REGOK|<房间号>|<你的公网地址>
//   主机 → PBZS|UNREG|<密钥>
//   任何 → PBZS|LIST                     ← PBZS|ROOMS\n<房间号>\t<名字>\t<地图>\t<已满>\t<所在服务器>\t<排位 0/1>\t<称号>\n…（最多 40 个；
//                                           所在服务器为空 = 就是这台，否则是别的服务器的 IP:端口，加入要去那台；盟主开的房间排最前）
//   任何 → PBZS|PING                     ← PBZS|PONG|<你的公网地址>
//   客机 → PBZS|JOIN|<房间号>|<局域网地址>[|<客机 pid>|<客机 SteamID>]  → 客机 PBZS|PEER|<房间号>|<会话号>|<主机公网>|<主机局域网>
//                                         → 主机 PBZS|PEER|<房间号>|<会话号>|<客机公网>|<客机局域网>
//                                         ← 出错 PBZS|ERR|<房间号>|nofound / full / ranked（排位房间，客机没带登记过的 pid）
//                                           / needsteam（排位房间走 Steam，客机没带 SteamID）/ oldhost（主机是旧版、没带 SteamID）
//                                         排位房间的 PEER 多第 7 段 = 对方的 SteamID（§135）
//   客机 → PBZS|RELAY|<会话号>             ← PBZS|RELAYOK|<会话号>；同时发给主机 PBZS|RELAYON|<会话号>
//                                         ← 没开 --relay 时 PBZS|ERR|<会话号>|norelay；主机不允许中转时 …|hostnorelay
//   双方 → PBZR|<会话号>\n<原样的状态包>    服务器按来源转给会话的另一方（包原样转发，带着这个头）
//   §141 观战（要开 --relay；主机 REG 第 12 段 = 1 表示认观战，列表第 8 列 = 能观战）：
//   观战者 → PBZS|WATCH|<房间号>           每 2 秒（保活）  ← PBZS|WATCHOK|<房间号>|<观战人数>
//                                         ← 出错 PBZS|ERR|<房间号>|nofound / nowatch（主机是旧版）/ ranked / norelay / watchfull
//   观战者 → PBZS|UNWATCH|<房间号>
//   主机   → PBZW|<房间号>\n<签过名的状态包（带 src=h / src=c）>   服务器原样（带着这个头）发给这个房间每个观战者；没人观战时主机不发
//   主机的 REGOK 第 5 段 = 现在的观战人数（主机靠它决定发不发）
//   §141.7 排队：观战者按先来后到排队（WATCHOK 第 5 段 = 排第几；WATCH 第 4 段 = down 表示"刚下场的"，先不叫它上场；
//   第 5 段 = noq 表示只观战、不排队：不叫它上场、不挑它当第二位、排第几报 0）。
//   房间有过对手、现在没满（对手走了 / 被主机换下）→ 服务器给队首发 PBZS|YOURTURN|<房间号>|<口令>（15 秒内每 2 秒重发），
//   这段时间别人 JOIN 一律 full，队首拿口令 JOIN（第 7 段）才放行
//   §141.8 主机下场（第二位选手经服务器转发）：主机 → PBZS|HOSTDOWN|<密钥>：服务器挑队首（跳过刚下场的）当第二位，
//   给它发 PBZS|SECOND|<房间号>|1；主机 → PBZS|HOSTUP|<密钥>：取消，给第二位发 PBZS|SECOND|<房间号>|0（回去观战）。
//   主机的 REGOK 第 6 段 = 有没有第二位。第二位 → PBZV|<房间号>\n<包> 服务器转给主机；主机 → PBZU|<房间号>\n<包> 服务器转给第二位。
//   第二位不再收观战包（PBZW）
// 主机 / 客机的 REG、JOIN、PBZR 都从各自的"游戏 UDP 端口"发出，这样服务器看到的就是 NAT 给游戏端口分配的公网地址，
// 告诉对方后双方往这个地址互发包（打洞）。打洞不通时客机发 RELAY，之后两边的状态包都经服务器转发。
//
// 服务器互通（只要一边配置）：A 用 --upstream 指向 B，A 每 2 秒
//   → B  PBZS|PUSH\n<房间号>\t<名字>\t<地图>\t<已满>\n…   只推 A 自己登记的房间（每包最多 6 个）；B 不用配 A：像收主机登记一样收下，
//                                                       所在服务器 = 包的来源地址，10 秒没再推就删
//      ← PBZS|PUSHOK|<A 的公网地址>                       A 由此知道 B 眼里的自己是谁
//   → B  PBZS|LIST，像客户端一样拿 B 的列表（B 自己的 + 别人推给 B 的），跳过所在服务器是 A 自己的，存下来 10 秒
// 两边的玩家都能看到对方的房间；加入别的服务器的房间时，客机直接去那台服务器 JOIN（主机的 NAT 口子只开给它自己那台）。
// 排位房间不推（排位只在本服务器内算）。
//
// --ranked <数据文件>：开武林盟主排位（账号、上报、Elo、排行榜；协议见 pbz-ranked.mjs 文件头，HANDOVER §110）。
// --web <目录>：再把排行榜 + 武器 / 招式统计写成静态网页（index.html + ranked.json，每分钟有变化才写，§110.11）。
// --cfg <文件>：数值表（标准数值基准 + 武器平衡，一行，客户端 tools/cfg_export.py 导出；HANDOVER §158）。文件改了自动重读（5 秒看一次）。
//   任何 → PBZS|CFGQ|<我有的哈希或 ->   ← PBZS|CFG|<哈希>|<第几块>|<共几块>|<内容>（每块 ≤ 900 字节，内容里本来就有 |，客户端只按前 5 个 | 切）
//                                       ← 已经是最新：PBZS|CFG|<哈希>|0|0|     没给 --cfg：PBZS|CFG|-|0|0|
// pbz-ranked.mjs 只在给了 --ranked 时才加载：没有这个文件、不加 --ranked，服务器照常跑（排位不公开源码，不随发布包分发）。
//
// §174 举报 / 封禁（HANDOVER §174）：
//   REG 第 15 段 = 主机标记（主机安装号的哈希），列表第 10 列原样给出：客户端据此不列自己拉黑的人开的房。
//   --reports <文件>：收举报，一行一条 JSON 追加到这个文件（不给就不收，回 RPTERR …|off）。
//     任何 → PBZS|REPORT|<随机号>|<键=值，Tab 分开>   ← PBZS|RPTOK|<随机号> / PBZS|RPTERR|<随机号>|off / rate / bad
//     键：ru / rsh / rnm / rpid / rv = 举报人的安装号 / Steam 哈希 / 昵称 / 排位 pid / 版本；tu / tsh / tsid / tnm / tpid / tv = 被举报人的；
//     mode / room / mt（对局状态）/ dur（连着几秒）/ ago（几秒前断的）/ why（原因，逗号分开）/ note（附言）。只记，不自动封。
//     同一个来源 IP 10 分钟最多 6 条；同一个随机号只记一次（客户端没收到回执会重发）。
//   node pbz-lobby-server.mjs --dump-reports <文件> [--all]：按被举报人汇总打印后退出（--all 把每一条都列出来）；
//     §181 后面再打一段"可疑排名"（同目录 evidence/ 里的对局数据，每人一行 + 最可疑 3 条明细，只出报告不自动封）。
//   §181 举报附带的对局数据（客户端房间设置"作弊数据采样"开着才有）：举报收下后
//     任何 → PBZS|EVID|<举报随机号>|<片号>/<总片数>|<gzip 后 Base64>（最多 8 片，每片 ≤ 1000 字节）  ← 拼齐写好 PBZS|EVOK|<随机号>
//     写 <举报文件同目录>/evidence/<日期>.jsonl，一行一份；丢片不写；90 天前的每天清掉（--bans 里的人的留着）。
//   §202 --cheat-rules <配置文件>（要同时给 --reports）：收齐举报附带的对局数据后按配置判定，武林盟主的对局判定作弊可以作废、退分。
//     判定模块 pbz-verdict.mjs 和排位一样不随发布包分发；没有这个文件就别加这个参数。
//   --bans <文件>：武林盟主封禁名单（手动维护，改了自动重读）。一行一个排位 pid 或 SteamID（# 后面是注释）；
//     名单里的人登记排位房间 / 加入排位房间都回 ERR …|banned。普通房间不管。
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
const PORT = Number(arg('--port', process.env.PORT || 27020));
const HOST = arg('--host', process.env.HOST || '0.0.0.0');
const QUIET = process.argv.includes('--quiet');
const RELAY = process.argv.includes('--relay') || process.env.RELAY === '1';
const RANKED_FILE = arg('--ranked', process.env.RANKED || '');
const CFG_FILE = arg('--cfg', process.env.PBZ_CFG || '');
const REPORTS_FILE = arg('--reports', process.env.PBZ_REPORTS || '');
const BANS_FILE = arg('--bans', process.env.PBZ_BANS || '');
const CHEAT_RULES = arg('--cheat-rules', process.env.PBZ_CHEAT_RULES || '');      // §202
const UPSTREAMS =process.argv.flatMap((a, i) => (a === '--upstream' && process.argv[i + 1] ? [process.argv[i + 1]] : []));

const ROOM_TTL = 10_000;          // 主机 10 秒没心跳就删房间
const SESSION_TTL = 30_000;       // 会话 30 秒没包就删
const MAX_ROOMS = 1000;
const MAX_LIST = 40;
const MAX_PACKET = 1400;
const REPORT_RATE = 6;            // §174 每个来源 IP 每 10 分钟最多几条举报
const REPORT_WINDOW = 600_000;
const REPORT_KEYS = ['ru', 'rsh', 'rnm', 'rpid', 'rv', 'tu', 'tsh', 'tsid', 'tnm', 'tpid', 'tv', 'mode', 'room', 'mt', 'dur', 'ago', 'why', 'note'];
const PUSH_CHUNK = 6;             // 每个 PUSH 包几个房间（中文名字 32 字 ≈ 96 字节，6 个也在 1400 以内）
const MAX_REMOTE_PER_SOURCE = 200;
const RELAY_RATE = 120;           // 每个会话每个方向每秒最多转发多少包（游戏 30 包/秒，留余量）
const MAX_WATCH = 8;              // §141 每个房间最多几个观战者
const WATCH_TTL = 6_000;          // 观战者 6 秒没保活就移出
const WATCH_RATE = 150;           // 主机每秒最多上传多少观战包（两路 × 30 包/秒，留余量）

/** @type {Map<string, {id:string,key:string,name:string,map:string,full:boolean,host:string,hostLocal:string,noRelay?:boolean,seen:number}>} */
const rooms = new Map();          // 房间号 → 房间
const byKey = new Map();          // 主机密钥 → 房间号
/** @type {Map<string, {sid:string,room:string,a:string,b:string,bLocal:string,relay:boolean,seen:number,rate:Object}>} */
const sessions = new Map();       // 会话号 → { a 主机端点, b 客机端点 }
/** @type {Map<string, {id:string,name:string,map:string,full:boolean,home:string,via:string,seen:number}>} */
const remote = new Map();         // "<所在服务器>|<房间号>" → 别的服务器的房间（推过来的 / 从上游拉来的）
/** @type {Map<string, {addr:string, ep:string|null, self:string, lookedUp:number}>} */
const upstreams = new Map(UPSTREAMS.map((a) => [a, { addr: a, ep: null, self: '', lookedUp: 0 }]));
const stats = { rx: 0, relayed: 0, dropped: 0, rebound: 0 };

const log = (...a) => { if (!QUIET) console.log(new Date().toISOString().slice(11, 23), ...a); };
// §133 中转诊断：--quiet 下也写，但只写会话号 / 房间号 / 计数，从不写 IP（中转两个方向各转了多少、为什么丢）
const note = (...a) => console.log(new Date().toISOString().slice(11, 23), ...a);
const ctr = (s) => s.ctr ?? (s.ctr = { ab: 0, ba: 0, early: 0, unk: 0, unkA: 0, unkB: 0, rate: 0, rebA: 0, rebB: 0, logged: '' });
const ip16 = (e) => ipOf(e).split('.').slice(0, 2).join('.');
function relaySummary(s, why) {
    const c = ctr(s);
    const line = `主机→客机 ${c.ab}，客机→主机 ${c.ba}，没开中转前 ${c.early}，认不出 ${c.unk}（像主机 ${c.unkA} / 像客机 ${c.unkB}），限速 ${c.rate}，`
        + `换端口 主机 ${c.rebA} / 客机 ${c.rebB}`;
    if (why !== '定时' || line !== c.logged) note(`[relay-diag] 会话 ${s.sid} 房间 ${s.room} ${why}：${line}`);
    c.logged = line;
}
// §135 SteamID64：17 位数字，7656 开头；别的一律当没有
const steamIdOf = (s) => (/^7656\d{13}$/.test(String(s ?? '').trim()) ? String(s).trim() : '');
const clean = (s, n) => String(s ?? '').replace(/[|\t\r\n]/g, ' ').slice(0, n);
const ep = (r) => `${r.address}:${r.port}`;
const newId = (len) => {
    // 房间号：去掉容易看错的 0 O 1 I L
    const abc = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    let s = '';
    for (const b of crypto.randomBytes(len)) s += abc[b % abc.length];
    return s;
};

// ---- §181 BEGIN 作弊数据：举报附带的对局数据摘要（HANDOVER §181；这一段只用传进来的 fs / zlib / path，tests/test_evidence.mjs 单独拿出来测）
// 客户端举报收下（RPTOK）后另发 PBZS|EVID|<举报随机号>|<片号>/<总片数>|<Base64>（gzip 过的一行 JSON，最多 8 片，每片整包 ≤ 1000 字节）。
// 只认这台服务器最近 10 分钟收下的举报的随机号；拼齐、解压、过滤后写 <举报文件同目录>/evidence/<日期>.jsonl 一行一份（带随机号和被举报人标识），
// 回 PBZS|EVOK|<随机号>；60 秒没拼齐就丢（丢片不写）。每天清 90 天前的文件，--bans 名单里的人（排位 pid / SteamID）那几行留着。
// --dump-reports 多一段"可疑排名"：每份摘要按指标计数，延迟高的整份不进排名；只出报告，不自动封。
const EV_MAX_PIECES = 8, EV_PIECE_MAX = 1000, EV_TTL = 60_000, EV_KEEP_DAYS = 90, EV_MAX_RAW = 65_536, EV_LAT_BAD = 300;
// §181.4 五项 + 两项参考：big ① 单次伤害 > 招表 × 3、cd ② 冷却过短、heal / sh ③ 凭空回血 / 回杀气、tp ④ 瞬移（客户端已扣掉延迟 > 300 ms 的）、
// attr ⑤ 属性超过标准数值的项数；lo 受伤偏少 = 我判定打中、对方回报 hit 但伤害 < 招表 ÷ 3（无敌 / 减伤类修改器，§193 起进排名）。
// 合计 ≥ EV_FLAG 任一项 = 有证据支持。lo 只认 v ≥ 2 的摘要（客户端 §193 起才扣掉延迟高 / 回合结束截断的样本）、标准数值开着或武林盟主
const EV_CATS = ['big', 'cd', 'heal', 'sh', 'tp', 'attr', 'lo'];
const EV_FLAG = { big: 2, cd: 3, heal: 2, sh: 3, tp: 2, attr: 1, lo: 3 };
const EV_LO_X = 1 / 3, EV_LO_CAP = 10, EV_LO_MINV = 2;
const EV_NAME = { big: '伤害超标', cd: '冷却过短', heal: '凭空回血', sh: '凭空回杀气', tp: '瞬移', attr: '属性超标', lo: '受伤偏少' };
const evDirOf = (pathMod, reportsFile) => pathMod.join(pathMod.dirname(pathMod.resolve(reportsFile)), 'evidence');
const evDay = (ms) => new Date(ms).toISOString().slice(0, 10);
const evNum = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
const evStr = (v, n = 64) => String(v ?? '').replace(/[^\w,\-.]/g, '').slice(0, n);
// 摘要过一遍：只留认识的键；数字就是数字，字串只留 [\w,-.]；明细每类最多 10 条、每条最多 8 项
function evClean(o) {
    if (!o || typeof o !== 'object') return null;
    const env = {}, c = {}, d = {};
    for (const [k, v] of Object.entries(o.env || {})) if (/^\w{1,12}$/.test(k)) env[k] = typeof v === 'string' ? evStr(v, 200) : evNum(v);
    for (const k of ['hits', 'std', 'res', 'pk', 'ux', 'healAmt', ...EV_CATS]) c[k] = Math.max(0, evNum(o.c?.[k]) ?? 0);
    for (const k of EV_CATS) {
        const rows = Array.isArray(o.d?.[k]) ? o.d[k].slice(0, 10) : [];
        d[k] = rows.filter(Array.isArray).map((r) => r.slice(0, 8).map((x) => (typeof x === 'string' ? evStr(x) : evNum(x))));
    }
    return { v: evNum(o.v), mv: evStr(o.mv, 16), mid: evNum(o.mid), r: evNum(o.r), dur: evNum(o.dur), sc: evStr(o.sc, 12), env, c, d };
}
function createEvidence({ dir, fs: fsm, zlib: zl, path: pathMod, onWritten = null }) {
    const reports = new Map();    // 随机号 → { row, at }（收下的举报）
    const pend = new Map();       // 随机号 → { n, parts, got, at }
    const done = new Map();       // 随机号 → 时间（写过了，重发的片直接回 EVOK）
    const st = { written: 0, bad: 0, dropped: 0 };
    function noteReport(nonce, row, now) { reports.set(nonce, { row, at: now }); }
    // 一个分片；返回要回的包（字符串）或 null。ctx 原样交给 onWritten（§202：发摘要的地址，只在内存里用）
    function onPiece(f, now, ctx) {
        const nonce = String(f[2] ?? '').slice(0, 16);
        if (!reports.has(nonce)) return null;
        if (done.has(nonce)) return `PBZS|EVOK|${nonce}`;
        const m = /^(\d)\/(\d)$/.exec(String(f[3] ?? ''));
        const data = String(f.slice(4).join('|'));
        if (!m || !/^[A-Za-z0-9+/=]{1,1000}$/.test(data)) return null;
        const i = Number(m[1]), n = Number(m[2]);
        if (n < 1 || n > EV_MAX_PIECES || i < 1 || i > n) return null;
        let p = pend.get(nonce);
        if (!p || p.n !== n) { p = { n, parts: new Array(n).fill(null), got: 0, at: now }; pend.set(nonce, p); }
        if (p.parts[i - 1] === null) { p.parts[i - 1] = data; p.got++; }
        if (p.got < n) return null;
        pend.delete(nonce);
        let ev;
        try {
            const raw = zl.gunzipSync(Buffer.from(p.parts.join(''), 'base64'), { maxOutputLength: EV_MAX_RAW });
            ev = evClean(JSON.parse(raw.toString('utf8')));
        } catch { ev = null; }
        if (!ev) { st.bad++; return null; }
        const row = reports.get(nonce).row || {};
        const line = { t: new Date(now).toISOString(), n: nonce };
        for (const k of ['tu', 'tsh', 'tsid', 'tpid', 'tnm', 'ru', 'rsh']) if (row[k]) line[k] = row[k];
        line.ev = ev;
        try {
            fsm.mkdirSync(dir, { recursive: true });
            fsm.appendFileSync(pathMod.join(dir, `${evDay(now)}.jsonl`), JSON.stringify(line) + '\n');
        } catch (e) { console.error(`[evidence] 写不进 ${dir}：${e.message}`); return null; }
        done.set(nonce, now);
        st.written++;
        if (onWritten) { try { onWritten(line, row, ctx); } catch (e) { console.error(`[evidence] 判定出错：${e.message}`); } }
        return `PBZS|EVOK|${nonce}`;
    }
    function sweep(now) {
        for (const [k, p] of pend) if (now - p.at > EV_TTL) { pend.delete(k); st.dropped++; }
        for (const [k, r] of reports) if (now - r.at > 600_000) reports.delete(k);
        for (const [k, t] of done) if (now - t > 600_000) done.delete(k);
    }
    // 删 90 天前的；被封的人（bansHas(排位 pid / SteamID)）那几行留着
    function cleanOld(now, bansHas) {
        let files = [];
        try { files = fsm.readdirSync(dir); } catch { return 0; }
        const cut = evDay(now - EV_KEEP_DAYS * 86_400_000);
        let removed = 0;
        for (const fn of files) {
            const m = /^(\d{4}-\d{2}-\d{2})\.jsonl$/.exec(fn);
            if (!m || m[1] >= cut) continue;
            const full = pathMod.join(dir, fn);
            let keep = [];
            try {
                keep = fsm.readFileSync(full, 'utf8').split('\n').filter((l) => {
                    try { const o = JSON.parse(l); return bansHas(o.tpid) || bansHas(o.tsid); } catch { return false; }
                });
                if (keep.length) fsm.writeFileSync(full, keep.join('\n') + '\n');
                else fsm.unlinkSync(full);
                removed++;
            } catch (e) { console.error(`[evidence] 清理 ${fn} 失败：${e.message}`); }
        }
        return removed;
    }
    return { noteReport, onPiece, sweep, cleanOld, st, pend };
}
// 一份摘要的指标：延迟高（平均往返 > 300 ms）或没测出往返（lat 为 null）的整份不可信；标准数值没开、也不是武林盟主的不算 ① ⑤ 和 lo；
// v < 2 的旧摘要不算 lo（那时客户端 lo 不扣延迟 / 截断）
function evScore(ev) {
    const e = ev?.env || {}, c = ev?.c || {};
    const lat = evNum(e.lat);
    const s = { trusted: lat !== null && lat <= EV_LAT_BAD, stdOk: e.std === 1 || e.rk === 1, healAmt: c.healAmt || 0 };
    for (const k of EV_CATS) s[k] = c[k] || 0;
    s.loOk = s.stdOk && (evNum(ev?.v) ?? 0) >= EV_LO_MINV;
    if (!s.stdOk) s.big = s.attr = 0;
    if (!s.loOk) s.lo = 0;
    return s;
}
// 一份摘要里最可疑的明细（按"超出阈值几倍"排：伤害 ÷ 3 倍招表、半个技能时长 ÷ 间隔、回血占上限 ÷ 3%、杀气 ÷ 一半、速度 ÷ 30 米/秒、属性 ÷ 1.6 倍基准、
// lo 招表 ÷ 3 ÷ max(回报, 1) 封顶 10——和客户端 CS.score 同一算法）
function evDetails(ev) {
    const out = [], d = ev?.d || {}, sc = evScore(ev);
    const f1 = (x) => (typeof x === 'number' ? Math.round(x * 10) / 10 : x);
    if (sc.stdOk) for (const r of d.big || []) if (r[3] > 0) out.push({ w: r[2] / r[3] / 3, s: `${EV_NAME.big} ${r[1]} ${f1(r[2])}（招表 ${f1(r[3])}，×${f1(r[2] / r[3])}）@${f1(r[0])}s` });
    for (const r of d.cd || []) if (r[2] >= 0 && r[3] > 0) out.push({ w: r[3] / 2 / Math.max(r[2], 50), s: `${EV_NAME.cd} ${r[1]} 间隔 ${f1(r[2])} ms（技能时长 ${f1(r[3])} ms）@${f1(r[0])}s` });
    for (const r of d.heal || []) if (r[3] > 0) out.push({ w: (r[2] - r[1]) / r[3] / 0.03, s: `${EV_NAME.heal} ${f1(r[1])} → ${f1(r[2])}（上限 ${f1(r[3])}）@${f1(r[0])}s` });
    for (const r of d.sh || []) if (r[3] > 0) out.push({ w: (r[2] - r[1]) / r[3] / 0.5, s: `${EV_NAME.sh} ${f1(r[1])} → ${f1(r[2])}（上限 ${f1(r[3])}）@${f1(r[0])}s` });
    for (const r of d.tp || []) if (evNum(r[4]) !== null && r[4] >= 0 && r[4] <= EV_LAT_BAD) out.push({ w: r[3] / 3000, s: `${EV_NAME.tp} ${f1(r[1] / 100)} 米 / ${f1(r[2])} ms（${f1(r[3] / 100)} 米/秒，出招 ${r[5]}，往返 ${r[4] ?? '?'} ms）@${f1(r[0])}s` });
    if (sc.stdOk) for (const r of d.attr || []) if (r[2] > 0) out.push({ w: r[1] / r[2] / 1.6, s: `${EV_NAME.attr} ${r[0]} ${f1(r[1])}（基准 ${f1(r[2])}）` });
    if (sc.loOk) for (const r of d.lo || []) if (evNum(r[2]) !== null && r[2] >= 0 && r[3] > 0 && evNum(r[4]) !== null && r[4] >= 0 && r[4] <= EV_LAT_BAD)
        out.push({ w: Math.min(EV_LO_CAP, r[3] * EV_LO_X / Math.max(r[2], 1)), s: `${EV_NAME.lo} ${r[1]} 对方回报 ${f1(r[2])}（招表 ${f1(r[3])}，×${f1(r[2] / r[3])}，往返 ${r[4]} ms）@${f1(r[0])}s` });
    return out.sort((a, b) => b.w - a.w);
}
// 读 evidence 目录 → 按被举报人汇总（key 和 dumpReports 一样）。同一个举报人对同一个人同一场（mid）举报了几次，
// 摘要只算最后一份（同一场打完后再举报一次，后一份更全）；举报人或 mid 不知道的不去重
function evRank(rows, evLines, key) {
    const people = new Map();
    const get = (k) => {
        if (!people.has(k)) people.set(k, { k, reports: 0, reporters: new Set(), names: new Set(), ev: 0, evBad: 0, dup: 0, sum: Object.fromEntries([...EV_CATS, 'healAmt'].map((x) => [x, 0])), det: [] });
        return people.get(k);
    };
    for (const r of rows) { const p = get(key(r)); p.reports++; p.reporters.add(r.ru || r.rsh || r.ip); if (r.tnm) p.names.add(r.tnm); }
    const uniq = new Map();
    for (const l of evLines) {
        const who = l.ru || l.rsh, mid = evNum(l.ev?.mid);
        const dk = who && mid !== null ? `${key(l)}|${who}|${mid}` : Symbol('ev');
        if (uniq.has(dk)) get(key(l)).dup++;
        uniq.delete(dk);                 // 后来的放到最后（保持读到的先后）
        uniq.set(dk, l);
    }
    for (const l of uniq.values()) {
        const p = get(key(l)), sc = evScore(l.ev);
        if (l.tnm) p.names.add(l.tnm);
        if (!sc.trusted) { p.evBad++; continue; }
        p.ev++;
        for (const x of [...EV_CATS, 'healAmt']) p.sum[x] += sc[x];
        p.det.push(...evDetails(l.ev).slice(0, 3));
    }
    const list = [...people.values()].filter((p) => p.ev + p.evBad > 0);
    for (const p of list) {
        p.flags = Object.entries(EV_FLAG).filter(([x, n]) => p.sum[x] >= n).map(([x]) => x);
        p.det.sort((a, b) => b.w - a.w);
    }
    // 先看举报人数（一个人反复举报刷不上去），再看有没有证据支持、几项、举报条数
    return list.sort((a, b) => b.reporters.size - a.reporters.size || (b.flags.length > 0) - (a.flags.length > 0)
        || b.flags.length - a.flags.length || b.reports - a.reports);
}
function evReadDir(fsm, pathMod, dir) {
    const lines = [];
    let files = [];
    try { files = fsm.readdirSync(dir).filter((f) => /^\d{4}-\d{2}-\d{2}\.jsonl$/.test(f)).sort(); } catch { return lines; }
    for (const f of files) {
        for (const l of fsm.readFileSync(pathMod.join(dir, f), 'utf8').split('\n')) {
            if (!l.trim()) continue;
            try { const o = JSON.parse(l); if (o && o.ev) lines.push(o); } catch { /* 坏行跳过 */ }
        }
    }
    return lines;
}
function evPrintRank(list) {
    console.log(`\n==== 可疑排名（举报附带的对局数据；只出报告，不自动封；按举报人数排；延迟高的整份不算）====`);
    if (!list.length) { console.log('（没有对局数据）'); return; }
    for (const p of list) {
        const s = p.sum;
        console.log(`${p.flags.length ? '★' : ' '} ${p.k}  举报 ${p.reports} 条 / ${p.reporters.size} 人  数据 ${p.ev} 份${p.evBad ? `（另 ${p.evBad} 份延迟高 / 没测出往返没算）` : ''}${p.dup ? `（另 ${p.dup} 份是同一人同一场重复举报）` : ''}`
            + `  ①伤害超标 ${s.big}  ②冷却过短 ${s.cd}  ③回血 ${s.heal}（共 ${Math.round(s.healAmt)}）/ 回杀气 ${s.sh}  ④瞬移 ${s.tp}  ⑤属性超标 ${s.attr}  受伤偏少 ${s.lo}`
            + `  昵称：${[...p.names].slice(0, 3).join(' / ') || '?'}`);
        for (const d of p.det.slice(0, 3)) console.log(`     - ${d.s}`);
    }
}
// ---- §181 END

// §174 看举报：按被举报人汇总
function dumpReports(file, all) {
    let lines = [];
    try { lines = fs.readFileSync(file, 'utf8').split('\n').filter((l) => l.trim()); } catch (e) { console.error(`读不了 ${file}：${e.message}`); process.exit(1); }
    const rows = [];
    for (const l of lines) { try { rows.push(JSON.parse(l)); } catch { /* 坏行跳过 */ } }
    const key = (r) => (r.tsid ? `steam ${r.tsid}` : r.tpid ? `pid ${r.tpid}` : r.tu ? `uid ${r.tu}` : r.tsh ? `sh ${r.tsh}` : `nm ${r.tnm || '?'}`);
    const groups = new Map();
    for (const r of rows) {
        const k = key(r);
        if (!groups.has(k)) groups.set(k, []);
        groups.get(k).push(r);
    }
    console.log(`共 ${rows.length} 条举报，${groups.size} 个被举报人（${file}）`);
    const sorted = [...groups.entries()].sort((a, b) => b[1].length - a[1].length);
    for (const [k, list] of sorted) {
        const reporters = new Set(list.map((r) => r.ru || r.rsh || r.ip));
        const why = {};
        for (const r of list) for (const w of String(r.why || '').split(',').filter(Boolean)) why[w] = (why[w] || 0) + 1;
        const names = [...new Set(list.map((r) => r.tnm).filter(Boolean))].slice(0, 5).join(' / ');
        const ids = [...new Set(list.flatMap((r) => [r.tu && `uid ${r.tu}`, r.tsh && `sh ${r.tsh}`, r.tsid && `steam ${r.tsid}`, r.tpid && `pid ${r.tpid}`].filter(Boolean)))].join('  ');
        console.log(`\n== ${k}  ${list.length} 条，${reporters.size} 个举报人  昵称：${names || '?'}`);
        console.log(`   标识：${ids}`);
        console.log(`   原因：${Object.entries(why).map(([w, n]) => `${w}×${n}`).join('  ') || '（没选）'}`);
        console.log(`   最近：${list[list.length - 1].t}`);
        for (const r of (all ? list : list.filter((x) => x.note).slice(-3)))
            console.log(`   - ${r.t} ${r.rnm || r.ru || '?'}（${r.mode || '?'}${r.room ? ' 房间 ' + r.room : ''}${r.mt ? ' 对局 ' + r.mt : ''}${r.dur ? ' 连了 ' + r.dur + ' 秒' : ''}）${r.why ? ' [' + r.why + ']' : ''}${r.note ? '：' + r.note : ''}`);
    }
    evPrintRank(evRank(rows, evReadDir(fs, path, evDirOf(path, file)), key));     // §181 可疑排名（举报文件旁边的 evidence/）
}
if (process.argv.includes('--dump-reports')) {
    dumpReports(arg('--dump-reports', REPORTS_FILE || 'pbz-reports.jsonl'), process.argv.includes('--all'));
    process.exit(0);
}

const sock = dgram.createSocket('udp4');
let ranked = null;
if (RANKED_FILE) {
    try {
        const { createRanked } = await import('./pbz-ranked.mjs');
        ranked = createRanked({ file: RANKED_FILE, log, send, webDir: arg('--web', process.env.RANKED_WEB || ''), cfgFile: arg('--ranked-cfg', process.env.RANKED_CFG || '') });
    } catch (e) {
        console.error(`[server] 给了 --ranked 但加载不了 pbz-ranked.mjs（要和本文件放在同一个目录）：${e.message}`);
        process.exit(1);
    }
}

// §158 数值表：读一次，之后每 5 秒看文件改没改
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

// §174 武林盟主封禁名单：一行一个 pid 或 SteamID
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

// §202 举报判定（pbz-verdict.mjs，不公开）：只在给了 --cheat-rules 时加载
let verdict = null;
if (CHEAT_RULES) {
    if (!REPORTS_FILE) { console.error('[server] --cheat-rules 要和 --reports 一起用'); process.exit(1); }
    try {
        const { createVerdictServer } = await import('./pbz-verdict.mjs');
        verdict = createVerdictServer({ rulesFile: CHEAT_RULES, reportsFile: REPORTS_FILE, rankedFile: RANKED_FILE, ranked, log: note });
    } catch (e) {
        console.error(`[server] 给了 --cheat-rules 但加载不了 pbz-verdict.mjs（要和本文件放在同一个目录）：${e.message}`);
        process.exit(1);
    }
}
// §181 举报附带的对局数据：和举报文件同目录的 evidence/；启动时和每天清一次 90 天前的（被封的人的留着）
const evid = REPORTS_FILE ? createEvidence({ dir: evDirOf(path, REPORTS_FILE), fs, zlib, path,
    onWritten: verdict ? (line, row, ctx) => verdict.onEvidence(line, row, ctx?.ip || '') : null }) : null;
if (evid) {
    const clean90 = () => { const n = evid.cleanOld(Date.now(), (x) => !!x && bans.has(x)); if (n) console.log(`[evidence] 清理了 ${n} 个 90 天前的文件`); };
    clean90();
    setInterval(clean90, 86_400_000).unref();
}
// §174 举报：每个来源 IP 的计数、收过的随机号
const reportRate = new Map();     // ip → [时间…]
const reportSeen = new Map();     // 随机号 → 时间
function onReport(f, from) {
    const nonce = clean(f[2], 16);
    if (!nonce) return;
    if (!REPORTS_FILE) { send(`PBZS|RPTERR|${nonce}|off`, from); return; }
    const now = Date.now();
    if (reportSeen.has(nonce)) { send(`PBZS|RPTOK|${nonce}`, from); return; }
    const ip = ipOf(from);
    const times = (reportRate.get(ip) || []).filter((t) => now - t < REPORT_WINDOW);
    if (times.length >= REPORT_RATE) { reportRate.set(ip, times); send(`PBZS|RPTERR|${nonce}|rate`, from); return; }
    const r = { t: new Date(now).toISOString(), ip: ip16(from), n: nonce };      // §181 n = 随机号（evidence 里同一个号对得上）
    for (const part of String(f.slice(3).join(' ')).split('\t')) {
        const eq = part.indexOf('=');
        if (eq <= 0) continue;
        const k = part.slice(0, eq);
        if (REPORT_KEYS.includes(k)) r[k] = clean(part.slice(eq + 1), k === 'note' ? 160 : 64).trim();
    }
    if (!r.tu && !r.tsh && !r.tsid && !r.tnm) { send(`PBZS|RPTERR|${nonce}|bad`, from); return; }
    try { fs.appendFileSync(REPORTS_FILE, JSON.stringify(r) + '\n'); } catch (e) { console.error(`[report] 写不进 ${REPORTS_FILE}：${e.message}`); send(`PBZS|RPTERR|${nonce}|io`, from); return; }
    times.push(now);
    reportRate.set(ip, times);
    reportSeen.set(nonce, now);
    if (evid) evid.noteReport(nonce, r, now);      // §181 这个随机号的对局数据分片之后才收
    send(`PBZS|RPTOK|${nonce}`, from);
    note(`[report] 收到举报：被举报人 ${r.tsid || r.tpid || r.tu || r.tsh || '?'}（${r.mode || '?'}）原因 ${r.why || '-'}`);
}

function send(text, to) {
    const [host, port] = splitEp(to);
    sock.send(Buffer.isBuffer(text) ? text : Buffer.from(text, 'utf8'), port, host);
}

function splitEp(s) {
    const i = s.lastIndexOf(':');
    return [s.slice(0, i), Number(s.slice(i + 1))];
}

// §131 中转会话里某一端换了公网端口（NAT 重新映射；校园网这类大 NAT 很常见）：以前只认登记时的"IP:端口"，
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
    if (s.rebinds <= 5) log(`[relay] 会话 ${s.sid} ${side === 'a' ? '主机' : '客机'}换了端口 ${s[side]} → ${from}`);
    s[side] = from;
    stats.rebound++;
    ctr(s)[side === 'a' ? 'rebA' : 'rebB']++;
    return side;
}

function onControl(f, from) {
    const now = Date.now();
    switch (f[1]) {
        case 'PING':
            send(`PBZS|PONG|${from}`, from);
            return;
        case 'CFGQ': {     // §158 数值表
            if (!cfg.chunks.length) { send('PBZS|CFG|-|0|0|', from); return; }
            if (clean(f[2], 16) === cfg.hash) { send(`PBZS|CFG|${cfg.hash}|0|0|`, from); return; }
            cfg.chunks.forEach((c, k) => send(`PBZS|CFG|${cfg.hash}|${k + 1}|${cfg.chunks.length}|${c}`, from));
            return;
        }
        case 'REG': {
            const key = clean(f[2], 64);
            if (key.length < 8) return;
            const rk = f[8] === '1', pid = clean(f[9], 16);
            if (rk && !ranked) { send('PBZS|ERR|-|noranked', from); return; }
            if (rk && !ranked.known(pid)) { send('PBZS|ERR|-|unknown', from); return; }
            if (rk && banned(pid, steamIdOf(f[10]))) { send('PBZS|ERR|-|banned', from); return; }     // §174
            let id = byKey.get(key);
            let room = id && rooms.get(id);
            if (!room) {
                if (rooms.size >= MAX_ROOMS) return;
                do id = newId(6); while (rooms.has(id));
                room = { id, key, seen: now };
                rooms.set(id, room);
                byKey.set(key, id);
                log(`[room] 新房间 ${id} 主机 ${from} 名字 ${clean(f[3], 32)}`);
            }
            room.name = clean(f[3], 32) || '?';
            room.map = clean(f[4], 48);
            room.full = f[5] === '1';
            // §131 这个房间的会话里主机端点也跟着换（心跳带主机密钥，就是主机本人；中转里已经换过的也一并改成最新的）
            for (const s of sessions.values()) if (s.room === id && s.a !== from) s.a = from;
            room.host = from;                       // 主机换了公网端口（NAT 重新映射）也跟着更新
            room.hostLocal = clean(f[6], 32);
            room.noRelay = f[7] === '0';            // 主机在设置里没允许中转（HANDOVER §102）
            room.ranked = rk;                       // §110 武林盟主排位房间
            room.pid = rk ? pid : '';
            room.steam = rk ? steamIdOf(f[10]) : '';   // §135 排位对局走 Steam：主机的 SteamID（旧版联机程序不发 = 空）
            room.watch = f[11] === '1' && !rk;         // §141 主机认观战（排位房间不给看）
            room.aiFight = f[13] === '1';           // §141 第 14 段 = 主机在和本地 AI 对打（列表第 9 列）
            room.bh = clean(f[14], 16);             // §174 第 15 段 = 主机标记（列表第 10 列）
            room.maxWatch = Math.min(MAX_WATCH, Number.isFinite(Number(f[12])) && f[12] !== undefined && f[12] !== '' ? Number(f[12]) : MAX_WATCH);   // 第 13 段 = 主机设的上限
            room.seen = now;
            send(`PBZS|REGOK|${id}|${from}|${watchCount(room, now)}|${room.second && room.watchers?.has(room.second) ? 1 : 0}`, from);
            queueTick(room, now);
            return;
        }
        case 'UNREG': {
            const id = byKey.get(clean(f[2], 64));
            if (id) { dropRoom(id, '主机注销'); }
            return;
        }
        case 'LIST': {
            // 自己的房间排前面，再是别的服务器的；各自未满的在前；§110 武林盟主开的房间排最前
            const title = (r) => (r.ranked && ranked ? ranked.titleOf(r.pid) : '');
            const order = (x, y) => Number(!x.title) - Number(!y.title) || Number(x.full) - Number(y.full) || y.seen - x.seen;
            const own = [...rooms.values()].map((r) => ({ ...r, home: '', title: title(r) })).sort(order);
            const list = own.concat([...remote.values()].sort(order)).slice(0, MAX_LIST);
            // §141 第 8 列 = 能观战（主机认观战、这台开了中转、是这台自己的房间）
            send('PBZS|ROOMS\n' + list.map((r) => `${r.id}\t${r.name}\t${r.map}\t${r.full ? 1 : 0}\t${r.home}\t${r.ranked ? 1 : 0}\t${r.title || ''}\t${r.watch && RELAY && !r.home ? 1 : 0}\t${r.aiFight ? 1 : 0}\t${r.bh || ''}`).join('\n'), from);
            return;
        }
        case 'WATCH': {
            const id = clean(f[2], 16).toUpperCase();
            const room = rooms.get(id);
            if (!room) { send(`PBZS|ERR|${id}|nofound`, from); return; }
            if (room.ranked) { send(`PBZS|ERR|${id}|ranked`, from); return; }
            if (!room.watch) { send(`PBZS|ERR|${id}|nowatch`, from); return; }
            if (!RELAY) { send(`PBZS|ERR|${id}|norelay`, from); return; }
            room.watchers ??= new Map();
            watchCount(room, now);
            const w = room.watchers.get(from);
            if (!w) {
                if (room.watchers.size >= (room.maxWatch ?? MAX_WATCH)) { send(`PBZS|ERR|${id}|watchfull`, from); return; }
                room.watchers.set(from, { seen: now, down: f[3] === 'down', noq: f[4] === 'noq' });
                log(`[watch] ${from} 观战房间 ${id}${f[3] === 'down' ? '（刚下场）' : ''}${f[4] === 'noq' ? '（只观战）' : ''}`);
            } else { w.seen = now; w.noq = f[4] === 'noq'; if (f[3] === 'up') w.down = false; }     // §141 观战者切回了排队
            const queue = [...room.watchers].filter(([, v]) => !v.noq).map(([k]) => k);
            const pos = queue.indexOf(from) + 1;
            send(`PBZS|WATCHOK|${id}|${room.watchers.size}|${pos}`, from);
            if (room.reserve?.ep === from && now <= room.reserve.until) send(`PBZS|YOURTURN|${id}|${room.reserve.token}`, from);
            return;
        }
        case 'HOSTDOWN': case 'HOSTUP': {
            const id = byKey.get(clean(f[2], 64));
            const room = id && rooms.get(id);
            if (!room || room.host !== from || !RELAY) return;
            if (f[1] === 'HOSTUP') {
                if (room.second) { send(`PBZS|SECOND|${id}|0`, room.second); log(`[watch] 房间 ${id} 主机回来打，第二位 ${room.second} 回去观战`); }
                room.second = null;
                return;
            }
            if (room.second && room.watchers?.has(room.second)) { send(`PBZS|SECOND|${id}|1`, room.second); return; }
            watchCount(room, now);
            const head = [...(room.watchers ?? [])].find(([, v]) => !v.down && !v.noq && now - v.seen <= WATCH_TTL);
            if (!head) return;
            room.second = head[0];
            for (const v of room.watchers.values()) v.down = false;
            log(`[watch] 房间 ${id} 主机下场，第二位 ${room.second}`);
            send(`PBZS|SECOND|${id}|1`, room.second);
            return;
        }
        case 'UNWATCH': {
            const room = rooms.get(clean(f[2], 16).toUpperCase());
            if (room?.watchers?.delete(from)) log(`[watch] ${from} 不看房间 ${room.id} 了`);
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
            if (!room) { send(`PBZS|ERR|${id}|nofound`, from); return; }
            const cpid = clean(f[4], 16), csteam = steamIdOf(f[5]);
            // §141.7 轮到队首上场的这段时间，只放拿着口令的（队首）进来
            const rs = room.reserve;
            if (rs && now <= rs.until && clean(f[6], 16) !== rs.token
                && ![...sessions.values()].some((x) => x.room === id && x.b === from)) { send(`PBZS|ERR|${id}|full`, from); return; }
            if (rs && clean(f[6], 16) === rs.token) {
                log(`[watch] 房间 ${id} 队首 ${rs.ep} 上场（${from}）`);
                room.watchers?.delete(rs.ep);
                for (const v of room.watchers?.values() ?? []) v.down = false;
                room.reserve = null;
                room.full = false;
            }
            if (room.ranked && !(ranked && ranked.known(cpid) && cpid !== room.pid)) { send(`PBZS|ERR|${id}|ranked`, from); return; }
            if (room.ranked && banned(cpid, csteam)) { send(`PBZS|ERR|${id}|banned`, from); return; }     // §174
            // §135 排位对局只走 Steam：两边都要有 SteamID（一边是旧版就说清楚，别让客机一直连不上）
            if (room.ranked && !room.steam !== !csteam) { send(`PBZS|ERR|${id}|${room.steam ? 'needsteam' : 'oldhost'}`, from); return; }
            // 同一个客机端点重发 JOIN（每次直连重试都会发）沿用原会话号
            let s = [...sessions.values()].find((x) => x.room === id && x.b === from && x.a === room.host);
            if (!s) {
                if (room.full) { send(`PBZS|ERR|${id}|full`, from); return; }
                s = { sid: newId(10), room: id, a: room.host, b: from, relay: false, seen: now, rate: {} };
                room.hadPeer = true;
                sessions.set(s.sid, s);
                log(`[join] ${from} → 房间 ${id}（主机 ${room.host}），会话 ${s.sid}`);
            }
            s.bLocal = clean(f[3], 32);
            s.seen = now;
            if (room.ranked) ranked.session(s.sid, room.pid, cpid);
            s.bSteam = csteam;
            // §135 第 7 段 = 对方的 SteamID（排位房间才有；旧版联机程序只看前 6 段）
            send(`PBZS|PEER|${id}|${s.sid}|${room.host}|${room.hostLocal}${room.steam ? '|' + room.steam : ''}`, from);
            send(`PBZS|PEER|${id}|${s.sid}|${from}|${s.bLocal}${csteam ? '|' + csteam : ''}`, room.host);
            return;
        }
        case 'REPORT':      // §174
            onReport(f, from);
            return;
        case 'EVID': {      // §181 举报附带的对局数据分片（没开 --reports / 不是刚收下的举报 → 不理）
            const rep = evid && evid.onPiece(f, now, { ip: ipOf(from) });
            if (rep) send(rep, from);
            return;
        }
        case 'RELAY': {
            const s = sessions.get(clean(f[2], 16));
            if (!s || !sideOf(s, from)) { send(`PBZS|ERR|${clean(f[2], 16)}|nosession`, from); return; }
            if (!RELAY) { s.seen = now; send(`PBZS|ERR|${s.sid}|norelay`, from); return; }
            if (rooms.get(s.room)?.noRelay) { s.seen = now; send(`PBZS|ERR|${s.sid}|hostnorelay`, from); return; }
            if (!s.relay) log(`[relay] 会话 ${s.sid} 改走中转（${s.a} ⇄ ${s.b}）`);
            if (!s.relay) note(`[relay-diag] 会话 ${s.sid} 房间 ${s.room} 改走中转（${from === s.a ? '主机' : '客机'}先请求）`);
            s.relay = true;
            s.seen = now;
            send(`PBZS|RELAYOK|${s.sid}`, from);
            send(`PBZS|RELAYON|${s.sid}`, from === s.a ? s.b : s.a);
            return;
        }
        default:
            if (ranked && f[1]?.[0] === 'R' && ranked.onControl(f, from)) return;
            stats.dropped++;
    }
}

// PBZR|<会话号>\n<状态包>：按来源转给另一方。只转发会话里登记过的两个端点之间的包
function onRelay(buf, from) {
    const nl = buf.indexOf(10);
    if (nl < 0 || nl > 40) { stats.dropped++; return; }
    const s = sessions.get(buf.toString('utf8', 5, nl));
    if (!s) { stats.dropped++; return; }
    if (!s.relay) { stats.dropped++; ctr(s).early++; return; }
    const side = sideOf(s, from);           // §131 端口换了也认（按会话号 + IP）
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

// §141 观战人数（顺带移出 6 秒没保活的）
function watchCount(room, now) {
    if (!room.watchers) return 0;
    for (const [w, v] of room.watchers) if (now - v.seen > WATCH_TTL) { room.watchers.delete(w); if (room.second === w) room.second = null; log(`[watch] ${w} 观战超时`); }
    return room.watchers.size;
}

// §141.7 主机心跳时看一次：有过对手、现在没满、有人排队 → 叫队首（跳过刚下场的）。满了就取消
function queueTick(room, now) {
    if (!room.watch || !room.watchers?.size) { room.reserve = null; return; }
    if (room.full) { room.hadPeer = true; room.reserve = null; return; }
    if (!room.hadPeer) return;
    if (!room.reserve || now > room.reserve.until) {
        const head = [...room.watchers].find(([, v]) => !v.down && !v.noq && now - v.seen <= WATCH_TTL);
        if (!head) { room.reserve = null; return; }
        room.reserve = { ep: head[0], token: newId(8), until: now + 15_000 };
        log(`[watch] 房间 ${room.id} 没满，叫队首 ${head[0]} 上场`);
    }
    send(`PBZS|YOURTURN|${room.id}|${room.reserve.token}`, room.reserve.ep);
}

// §141 PBZW|<房间号>\n<包>：主机上传的观战包，原样发给这个房间的每个观战者。只认这个房间登记的主机端点
function onWatchUp(buf, from) {
    const nl = buf.indexOf(10);
    if (nl < 0 || nl > 24) { stats.dropped++; return; }
    const room = rooms.get(buf.toString('utf8', 5, nl));
    if (!room || room.host !== from || !room.watchers || room.watchers.size === 0 || !RELAY) { stats.dropped++; return; }
    const sec = Math.floor(Date.now() / 1000);
    const r = room.wrate ?? (room.wrate = { sec, n: 0 });
    if (r.sec !== sec) { r.sec = sec; r.n = 0; }
    if (++r.n > WATCH_RATE) { stats.dropped++; return; }
    for (const w of room.watchers.keys()) { if (w === room.second) continue; stats.relayed++; send(buf, w); }
}

// §141.8 主机下场时第二位选手和主机之间的包：PBZV（第二位 → 主机）、PBZU（主机 → 第二位）
function onSecond(buf, from, up) {
    const nl = buf.indexOf(10);
    if (nl < 0 || nl > 24) { stats.dropped++; return; }
    const room = rooms.get(buf.toString('utf8', 5, nl));
    if (!room || !room.second || !RELAY) { stats.dropped++; return; }
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
    send(`PBZS|PUSHOK|${from}`, from);
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
            const [host, port] = splitEp(u.addr.includes(':') ? u.addr : `${u.addr}:27020`);
            dns.lookup(host, { family: 4 }, (err, ip) => {
                if (err) { log(`[upstream] 解析不了 ${u.addr}：${err.message}`); return; }
                const e = `${ip}:${port}`;
                if (u.ep !== e) log(`[upstream] ${u.addr} = ${e}`);
                u.ep = e;
            });
        }
        if (!u.ep) continue;
        const own = [...rooms.values()].filter((r) => !r.ranked);
        if (own.length === 0) send('PBZS|PUSH', u.ep);      // 没房间也推一次空的：拿 PUSHOK 知道自己的公网地址
        for (let i = 0; i < own.length; i += PUSH_CHUNK) {
            send('PBZS|PUSH\n' + own.slice(i, i + PUSH_CHUNK).map((r) => `${r.id}\t${r.name}\t${r.map}\t${r.full ? 1 : 0}`).join('\n'), u.ep);
        }
        send('PBZS|LIST', u.ep);
    }
}

sock.on('message', (buf, rinfo) => {
    stats.rx++;
    const from = ep(rinfo);
    const up = upstreams.size > 0 ? upstreamAt(from) : null;
    // 上游回的列表可能比一个普通包大（40 个房间）；其余来源超长的一律丢
    if (buf.length > MAX_PACKET && !up) { stats.dropped++; return; }
    if (buf.length > 5 && buf.toString('latin1', 0, 5) === 'PBZR|') { onRelay(buf, from); return; }
    if (buf.length > 5 && buf.toString('latin1', 0, 5) === 'PBZW|') { onWatchUp(buf, from); return; }
    if (buf.length > 5 && buf.toString('latin1', 0, 5) === 'PBZV|') { onSecond(buf, from, true); return; }
    if (buf.length > 5 && buf.toString('latin1', 0, 5) === 'PBZU|') { onSecond(buf, from, false); return; }
    const text = buf.toString('utf8');
    if (!text.startsWith('PBZS|')) { stats.dropped++; return; }
    try {
        if (text.startsWith('PBZS|PUSH\n') || text === 'PBZS|PUSH') { onPush(text.split('\n').slice(1), from); return; }
        if (text.startsWith('PBZS|ROOMS')) { if (up) onUpstreamRooms(up, text.split('\n').slice(1)); return; }
        onControl(text.split('|'), from);
    } catch (e) { log('[err]', e); }
});

sock.on('error', (e) => { console.error('[server] socket 出错：', e.message); process.exit(1); });

setInterval(() => {
    const now = Date.now();
    for (const r of rooms.values()) if (now - r.seen > ROOM_TTL) dropRoom(r.id, '心跳超时');
    for (const s of sessions.values()) {
        if (now - s.seen > SESSION_TTL) {
            sessions.delete(s.sid);
            log(`[session] 会话 ${s.sid} 超时删除`);
            if (s.ctr) relaySummary(s, '结束');
        } else if (s.relay) relaySummary(s, '定时');   // §133 中转中每 2 秒看一次，有变化才写
    }
    for (const [k, r] of remote) if (now - r.seen > ROOM_TTL) remote.delete(k);
    for (const [k, t] of reportSeen) if (now - t > REPORT_WINDOW) reportSeen.delete(k);     // §174
    for (const [k, ts] of reportRate) if (!ts.some((t) => now - t < REPORT_WINDOW)) reportRate.delete(k);
    if (evid) evid.sweep(now);      // §181 60 秒没拼齐的分片丢掉
    if (ranked) ranked.tick();
    if (verdict) verdict.tick();        // §202 配置热加载、没结算的对局再找、人工撤销
}, 2000).unref();

if (upstreams.size > 0) {
    setInterval(upstreamTick, 2000).unref();
    setTimeout(upstreamTick, 200);
}

setInterval(() => {
    log(`[stat] 房间 ${rooms.size}（别的服务器的 ${remote.size}） 会话 ${sessions.size} 收包 ${stats.rx} 转发 ${stats.relayed} 丢弃 ${stats.dropped} 换端口 ${stats.rebound}`);
}, 60_000).unref();

sock.bind(PORT, HOST, () => {
    console.log(`[server] PBZ_MP 大厅服务器已启动：UDP ${HOST}:${sock.address().port}`
        + (RELAY ? '；中转开' : '；中转关（--relay 打开）')
        + (ranked ? `；武林盟主排位开（${RANKED_FILE}）` : '')
        + (REPORTS_FILE ? `；收举报（${REPORTS_FILE}）` : '')
        + (BANS_FILE ? `；排位封禁名单（${BANS_FILE}）` : '')
        + (verdict ? `；举报判定（${CHEAT_RULES}，${verdict.rules().mode}）` : '')
        + (upstreams.size ? `；互通上游 ${[...upstreams.keys()].join(', ')}` : ''));
});

for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { if (ranked) ranked.flush(); sock.close(); process.exit(0); });
