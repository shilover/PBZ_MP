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
import dgram from 'node:dgram';
import crypto from 'node:crypto';
import dns from 'node:dns';
import fs from 'node:fs';

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
const UPSTREAMS =process.argv.flatMap((a, i) => (a === '--upstream' && process.argv[i + 1] ? [process.argv[i + 1]] : []));

const ROOM_TTL = 10_000;          // 主机 10 秒没心跳就删房间
const SESSION_TTL = 30_000;       // 会话 30 秒没包就删
const MAX_ROOMS = 1000;
const MAX_LIST = 40;
const MAX_PACKET = 1400;
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

const sock = dgram.createSocket('udp4');
let ranked = null;
if (RANKED_FILE) {
    try {
        const { createRanked } = await import('./pbz-ranked.mjs');
        ranked = createRanked({ file: RANKED_FILE, log, send, webDir: arg('--web', process.env.RANKED_WEB || '') });
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
            send('PBZS|ROOMS\n' + list.map((r) => `${r.id}\t${r.name}\t${r.map}\t${r.full ? 1 : 0}\t${r.home}\t${r.ranked ? 1 : 0}\t${r.title || ''}\t${r.watch && RELAY && !r.home ? 1 : 0}\t${r.aiFight ? 1 : 0}`).join('\n'), from);
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
    if (ranked) ranked.tick();
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
        + (upstreams.size ? `；互通上游 ${[...upstreams.keys()].join(', ')}` : ''));
});

for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { if (ranked) ranked.flush(); sock.close(); process.exit(0); });
