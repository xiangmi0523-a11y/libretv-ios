'use strict';
// 用法：node --jitless nodejs/test/fetch-shim.test.js   （jitless 模拟 iOS 环境）
const assert = require('assert');
// 访问 Request/Headers 全局会让 Node 加载内置 undici，它在 jitless 下异步报 wasm 缺失；
// 与 main.js 一样忽略这条，确认我们的实现不依赖它。
process.on('unhandledRejection', (e) => { if (!(e && /WebAssembly/.test(String(e.message)))) { console.error(e); process.exit(1); } });
const http = require('http');
const zlib = require('zlib');
const path = require('path');
const { fetch, Agent, buildConnector } = require(path.join(__dirname, '..', 'fetch-shim.js'));

const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/json') { res.setHeader('content-type', 'application/json'); return res.end(JSON.stringify({ ok: true, ua: req.headers['user-agent'] })); }
  if (u.pathname === '/gzip') { res.setHeader('content-encoding', 'gzip'); return res.end(zlib.gzipSync('hello gzip')); }
  if (u.pathname === '/br') { res.setHeader('content-encoding', 'br'); return res.end(zlib.brotliCompressSync('hello br')); }
  if (u.pathname === '/deflate') { res.setHeader('content-encoding', 'deflate'); return res.end(zlib.deflateSync('hello deflate')); }
  if (u.pathname === '/rawdeflate') { res.setHeader('content-encoding', 'deflate'); return res.end(zlib.deflateRawSync('hello raw')); }
  if (u.pathname === '/redir') { res.statusCode = 302; res.setHeader('location', '/json'); return res.end(); }
  if (u.pathname === '/post') { let b = ''; req.on('data', (c) => (b += c)); req.on('end', () => res.end(req.method + ':' + b + ':' + req.headers['content-type'])); return; }
  if (u.pathname === '/slow') { setTimeout(() => res.end('late'), 2000); return; }
  if (u.pathname === '/stream') { res.write('a'); setTimeout(() => { res.write('b'); res.end('c'); }, 100); return; }
  if (u.pathname === '/204') { res.statusCode = 204; return res.end(); }
  res.statusCode = 404; res.end('nope');
});

(async () => {
  await new Promise((r) => server.listen(0, r)); // 双栈监听，localhost 解析到 ::1 或 127.0.0.1 都能连
  const base = 'http://127.0.0.1:' + server.address().port;
  let r = await fetch(base + '/json');
  assert.strictEqual(r.status, 200);
  assert.deepStrictEqual((await r.json()).ok, true);
  assert.strictEqual(await (await fetch(base + '/gzip')).text(), 'hello gzip');
  assert.strictEqual(await (await fetch(base + '/br')).text(), 'hello br');
  assert.strictEqual(await (await fetch(base + '/deflate')).text(), 'hello deflate');
  assert.strictEqual(await (await fetch(base + '/rawdeflate')).text(), 'hello raw');
  r = await fetch(base + '/redir');
  assert.strictEqual(r.status, 200); assert.strictEqual(r.redirected, true); assert.ok(r.url.endsWith('/json'));
  r = await fetch(base + '/redir', { redirect: 'manual' });
  assert.strictEqual(r.status, 302); assert.strictEqual(r.headers.get('location'), '/json');
  await assert.rejects(fetch(base + '/redir', { redirect: 'error' }), TypeError);
  assert.strictEqual(await (await fetch(base + '/post', { method: 'POST', body: 'x=1' })).text(), 'POST:x=1:text/plain;charset=UTF-8');
  assert.strictEqual(await (await fetch(base + '/post', { method: 'POST', body: new URLSearchParams({ a: 'b' }) })).text(), 'POST:a=b:application/x-www-form-urlencoded;charset=UTF-8');
  assert.strictEqual(await (await fetch(base + '/stream')).text(), 'abc');
  r = await fetch(base + '/204'); assert.strictEqual(r.status, 204); assert.strictEqual(await r.text(), '');
  assert.strictEqual((await fetch(base + '/missing')).status, 404);
  await assert.rejects(fetch(base + '/slow', { signal: AbortSignal.timeout(200) }), (e) => e.name === 'TimeoutError' || e.name === 'AbortError');
  await assert.rejects(fetch('http://127.0.0.1:1/'), (e) => e instanceof TypeError && e.message === 'fetch failed' && !!e.cause);
  // 连接级 SSRF：connector 拦截时应以 fetch failed + cause.code 抛出
  const blocking = new Agent({ connect: (opts, cb) => cb(Object.assign(new Error('blocked ' + opts.hostname), { code: 'ERR_SSRF_BLOCKED' }), null) });
  await assert.rejects(fetch(base + '/json', { dispatcher: blocking }), (e) => !!e.cause && e.cause.code === 'ERR_SSRF_BLOCKED');
  // 自定义 lookup 的 connector 能正常出网
  let looked = 0;
  const conn = buildConnector({ lookup: (h, o, cb) => { looked++; require('dns').lookup(h, o, cb); } });
  const allow = new Agent({ connect: conn });
  r = await fetch('http://localhost:' + server.address().port + '/json', { dispatcher: allow });
  assert.strictEqual(r.status, 200); assert.ok(looked >= 1);
  console.log('fetch-shim: all tests passed', typeof WebAssembly === 'undefined' ? '(jitless, no WebAssembly)' : '');
  server.close();
})().catch((e) => { console.error(e); process.exit(1); });
