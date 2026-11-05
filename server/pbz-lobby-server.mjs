// PBZ_MP 服务器大厅（docs/HANDOVER.md §47）：房间登记 / 列表 + UDP 打洞介绍 + 直连不通时的中转。
// 只用 Node 自带的 dgram，一个 UDP 端口干全部的事；不存盘，重启后房间由主机的心跳（每 2 秒一次）自己补回来。
// 许可证 GPL-3.0（见 LICENSE），不提供任何担保。架这台服务器的人是服务运营者，自己负责当地合规（server/README.md）。
//
//   node server/pbz-lobby-server.mjs [--port 27020] [--host 0.0.0.0] [--relay] [--quiet] [--upstream 域名或IP:端口 …]
//   环境变量 PORT / HOST / RELAY=1 也行。--upstream 可以写多个（HANDOVER §50 服务器互通）。
//   --relay：打洞不通时替双方转发状态包。默认关：中转是服务器几乎全部的带宽（每对玩家约 50 KB/秒），
//   关着时服务器只登记房间、介绍地址，客机请求中转会收到 ERR …|norelay。
//
// 协议（文本，一个 UDP 包一条；字段用 | 分开，服务器收到的字段里的 | \t \n 都会被替换掉）：
//   主机 → PBZS|REG|<密钥>|<名字>|<地图>|<已满 0/1>|<局域网地址 IP:端口>|<允许中转 0/1>   每 2 秒；10 秒没收到就删房间
//        （最后一段旧版联机程序不发，当允许；主机发 0 时这个房间的会话一律不中转）
//        ← PBZS|REGOK|<房间号>|<你的公网地址>
//   主机 → PBZS|UNREG|<密钥>
//   任何 → PBZS|LIST                     ← PBZS|ROOMS\n<房间号>\t<名字>\t<地图>\t<已满>\t<所在服务器>\n…（最多 40 个；
//                                           所在服务器为空 = 就是这台，否则是别的服务器的 IP:端口，加入要去那台）
//   任何 → PBZS|PING                     ← PBZS|PONG|<你的公网地址>
//   客机 → PBZS|JOIN|<房间号>|<局域网地址>  → 客机 PBZS|PEER|<房间号>|<会话号>|<主机公网>|<主机局域网>
//                                         → 主机 PBZS|PEER|<房间号>|<会话号>|<客机公网>|<客机局域网>
//                                         ← 出错 PBZS|ERR|<房间号>|nofound / full
//   客机 → PBZS|RELAY|<会话号>             ← PBZS|RELAYOK|<会话号>；同时发给主机 PBZS|RELAYON|<会话号>
//                                         ← 没开 --relay 时 PBZS|ERR|<会话号>|norelay；主机不允许中转时 …|hostnorelay
//   双方 → PBZR|<会话号>\n<原样的状态包>    服务器按来源转给会话的另一方（包原样转发，带着这个头）
// 主机 / 客机的 REG、JOIN、PBZR 都从各自的"游戏 UDP 端口"发出，这样服务器看到的就是 NAT 给游戏端口分配的公网地址，
// 告诉对方后双方往这个地址互发包（打洞）。打洞不通时客机发 RELAY，之后两边的状态包都经服务器转发。
//
// 服务器互通（只要一边配置）：A 用 --upstream 指向 B，A 每 2 秒
//   → B  PBZS|PUSH\n<房间号>\t<名字>\t<地图>\t<已满>\n…   只推 A 自己登记的房间（每包最多 6 个）；B 不用配 A：像收主机登记一样收下，
//                                                       所在服务器 = 包的来源地址，10 秒没再推就删
//      ← PBZS|PUSHOK|<A 的公网地址>                       A 由此知道 B 眼里的自己是谁
//   → B  PBZS|LIST，像客户端一样拿 B 的列表（B 自己的 + 别人推给 B 的），跳过所在服务器是 A 自己的，存下来 10 秒
// 两边的玩家都能看到对方的房间；加入别的服务器的房间时，客机直接去那台服务器 JOIN（主机的 NAT 口子只开给它自己那台）。
import dgram from 'node:dgram';
import crypto from 'node:crypto';
import dns from 'node:dns';

const arg = (name, def) => {
    const i = process.argv.indexOf(name);
    return i > 0 && i + 1 < process.argv.length ? process.argv[i + 1] : def;
};
const PORT = Number(arg('--port', process.env.PORT || 27020));
const HOST = arg('--host', process.env.HOST || '0.0.0.0');
const QUIET = process.argv.includes('--quiet');
const RELAY = process.argv.includes('--relay') || process.env.RELAY === '1';
const UPSTREAMS = process.argv.flatMap((a, i) => (a === '--upstream' && process.argv[i + 1] ? [process.argv[i + 1]] : []));

const ROOM_TTL = 10_000;          // 主机 10 秒没心跳就删房间
const SESSION_TTL = 30_000;       // 会话 30 秒没包就删
const MAX_ROOMS = 1000;
const MAX_LIST = 40;
const MAX_PACKET = 1400;
const PUSH_CHUNK = 6;             // 每个 PUSH 包几个房间（中文名字 32 字 ≈ 96 字节，6 个也在 1400 以内）
const MAX_REMOTE_PER_SOURCE = 200;
const RELAY_RATE = 120;           // 每个会话每个方向每秒最多转发多少包（游戏 30 包/秒，留余量）

/** @type {Map<string, {id:string,key:string,name:string,map:string,full:boolean,host:string,hostLocal:string,noRelay?:boolean,seen:number}>} */
const rooms = new Map();          // 房间号 → 房间
const byKey = new Map();          // 主机密钥 → 房间号
/** @type {Map<string, {sid:string,room:string,a:string,b:string,bLocal:string,relay:boolean,seen:number,rate:Object}>} */
const sessions = new Map();       // 会话号 → { a 主机端点, b 客机端点 }
/** @type {Map<string, {id:string,name:string,map:string,full:boolean,home:string,via:string,seen:number}>} */
const remote = new Map();         // "<所在服务器>|<房间号>" → 别的服务器的房间（推过来的 / 从上游拉来的）
/** @type {Map<string, {addr:string, ep:string|null, self:string, lookedUp:number}>} */
const upstreams = new Map(UPSTREAMS.map((a) => [a, { addr: a, ep: null, self: '', lookedUp: 0 }]));
const stats = { rx: 0, relayed: 0, dropped: 0 };

const log = (...a) => { if (!QUIET) console.log(new Date().toISOString().slice(11, 23), ...a); };
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

function send(text, to) {
    const [host, port] = splitEp(to);
    sock.send(Buffer.isBuffer(text) ? text : Buffer.from(text, 'utf8'), port, host);
}

function splitEp(s) {
    const i = s.lastIndexOf(':');
    return [s.slice(0, i), Number(s.slice(i + 1))];
}

function onControl(f, from) {
    const now = Date.now();
    switch (f[1]) {
        case 'PING':
            send(`PBZS|PONG|${from}`, from);
            return;
        case 'REG': {
            const key = clean(f[2], 64);
            if (key.length < 8) return;
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
            room.host = from;                       // 主机换了公网端口（NAT 重新映射）也跟着更新
            room.hostLocal = clean(f[6], 32);
            room.noRelay = f[7] === '0';            // 主机在设置里没允许中转（HANDOVER §102）
            room.seen = now;
            send(`PBZS|REGOK|${id}|${from}`, from);
            return;
        }
        case 'UNREG': {
            const id = byKey.get(clean(f[2], 64));
            if (id) { dropRoom(id, '主机注销'); }
            return;
        }
        case 'LIST': {
            // 自己的房间排前面，再是别的服务器的；各自未满的在前
            const order = (x, y) => Number(x.full) - Number(y.full) || y.seen - x.seen;
            const own = [...rooms.values()].sort(order).map((r) => ({ ...r, home: '' }));
            const list = own.concat([...remote.values()].sort(order)).slice(0, MAX_LIST);
            send('PBZS|ROOMS\n' + list.map((r) => `${r.id}\t${r.name}\t${r.map}\t${r.full ? 1 : 0}\t${r.home}`).join('\n'), from);
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
            // 同一个客机端点重发 JOIN（每次直连重试都会发）沿用原会话号
            let s = [...sessions.values()].find((x) => x.room === id && x.b === from && x.a === room.host);
            if (!s) {
                if (room.full) { send(`PBZS|ERR|${id}|full`, from); return; }
                s = { sid: newId(10), room: id, a: room.host, b: from, relay: false, seen: now, rate: {} };
                sessions.set(s.sid, s);
                log(`[join] ${from} → 房间 ${id}（主机 ${room.host}），会话 ${s.sid}`);
            }
            s.bLocal = clean(f[3], 32);
            s.seen = now;
            send(`PBZS|PEER|${id}|${s.sid}|${room.host}|${room.hostLocal}`, from);
            send(`PBZS|PEER|${id}|${s.sid}|${from}|${s.bLocal}`, room.host);
            return;
        }
        case 'RELAY': {
            const s = sessions.get(clean(f[2], 16));
            if (!s || (s.b !== from && s.a !== from)) { send(`PBZS|ERR|${clean(f[2], 16)}|nosession`, from); return; }
            if (!RELAY) { s.seen = now; send(`PBZS|ERR|${s.sid}|norelay`, from); return; }
            if (rooms.get(s.room)?.noRelay) { s.seen = now; send(`PBZS|ERR|${s.sid}|hostnorelay`, from); return; }
            if (!s.relay) log(`[relay] 会话 ${s.sid} 改走中转（${s.a} ⇄ ${s.b}）`);
            s.relay = true;
            s.seen = now;
            send(`PBZS|RELAYOK|${s.sid}`, from);
            send(`PBZS|RELAYON|${s.sid}`, from === s.a ? s.b : s.a);
            return;
        }
        default:
            stats.dropped++;
    }
}

// PBZR|<会话号>\n<状态包>：按来源转给另一方。只转发会话里登记过的两个端点之间的包
function onRelay(buf, from) {
    const nl = buf.indexOf(10);
    if (nl < 0 || nl > 40) { stats.dropped++; return; }
    const s = sessions.get(buf.toString('utf8', 5, nl));
    if (!s || !s.relay) { stats.dropped++; return; }
    const to = from === s.a ? s.b : from === s.b ? s.a : null;
    if (!to) { stats.dropped++; return; }
    const now = Date.now();
    const sec = Math.floor(now / 1000);
    const r = s.rate[from] ?? (s.rate[from] = { sec, n: 0 });
    if (r.sec !== sec) { r.sec = sec; r.n = 0; }
    if (++r.n > RELAY_RATE) { stats.dropped++; return; }
    s.seen = now;
    stats.relayed++;
    send(buf, to);
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
        const own = [...rooms.values()];
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
    for (const s of sessions.values()) if (now - s.seen > SESSION_TTL) { sessions.delete(s.sid); log(`[session] 会话 ${s.sid} 超时删除`); }
    for (const [k, r] of remote) if (now - r.seen > ROOM_TTL) remote.delete(k);
}, 2000).unref();

if (upstreams.size > 0) {
    setInterval(upstreamTick, 2000).unref();
    setTimeout(upstreamTick, 200);
}

setInterval(() => {
    log(`[stat] 房间 ${rooms.size}（别的服务器的 ${remote.size}） 会话 ${sessions.size} 收包 ${stats.rx} 转发 ${stats.relayed} 丢弃 ${stats.dropped}`);
}, 60_000).unref();

sock.bind(PORT, HOST, () => {
    console.log(`[server] PBZ_MP 大厅服务器已启动：UDP ${HOST}:${sock.address().port}`
        + (RELAY ? '；中转开' : '；中转关（--relay 打开）')
        + (upstreams.size ? `；互通上游 ${[...upstreams.keys()].join(', ')}` : ''));
});

for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { sock.close(); process.exit(0); });
