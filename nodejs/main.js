'use strict';
/*
 * LibreTV iOS 启动器（运行在 App 内置的 nodejs-mobile 里）。
 *
 * 1. 只监听 127.0.0.1，不对局域网开放；
 * 2. 启动 Next.js standalone 产物（server.js，原样来自 LibreTV 上游构建）；
 * 3. iOS 在 App 挂起后可能回收监听 socket（Apple TN2277），
 *    这里用看门狗定时自检，发现端口失效就重新 listen，保证切回前台后继续可用。
 */
const http = require('http');
const path = require('path');

const PORT = parseInt(process.env.PORT, 10) || 38080;
const HOST = process.env.HOSTNAME || '127.0.0.1';
process.env.PORT = String(PORT);
process.env.HOSTNAME = HOST;

// jitless 下没有 WebAssembly，Node 自带 fetch（undici/llhttp-wasm）不可用，换成 http/https 实现
const fetchShim = require('./fetch-shim.js');
globalThis.fetch = fetchShim.fetch;

// nodejs-mobile 是 Node 18，补上服务端代码用到的 AbortSignal.any（Node 20+ 才有）
if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.any !== 'function') {
  AbortSignal.any = function any(signals) {
    const controller = new AbortController();
    for (const s of signals) {
      if (!s) continue;
      if (s.aborted) { controller.abort(s.reason); return controller.signal; }
    }
    const onAbort = (ev) => {
      const s = ev && ev.target;
      controller.abort(s ? s.reason : undefined);
      for (const x of signals) if (x) x.removeEventListener('abort', onAbort);
    };
    for (const s of signals) if (s) s.addEventListener('abort', onAbort, { once: true });
    return controller.signal;
  };
}

// 双栈网络下优先能连通的地址族（Node 18.18+）
try { require('net').setDefaultAutoSelectFamily(true); } catch (_) { /* 旧版本忽略 */ }

let mainServer = null;
const origCreateServer = http.createServer;
http.createServer = function patchedCreateServer(...args) {
  const srv = origCreateServer.apply(this, args);
  if (!mainServer) mainServer = srv;
  return srv;
};

process.on('uncaughtException', (err) => {
  console.error('[libretv-ios] uncaughtException', err && err.stack ? err.stack : err);
});
process.on('unhandledRejection', (err) => {
  console.error('[libretv-ios] unhandledRejection', err && err.stack ? err.stack : err);
});

require(path.join(__dirname, 'server.js'));

let failures = 0;
let relistening = false;

function selfCheck() {
  if (!mainServer || relistening) return;
  const req = http.get({ host: HOST, port: PORT, path: '/api/status', timeout: 4000, agent: false }, (res) => {
    res.resume();
    failures = 0;
  });
  req.on('timeout', () => req.destroy(new Error('timeout')));
  req.on('error', (err) => {
    // 超时多半只是忙（jitless 下渲染较慢），只有连接级错误才算端口失效
    if (err && err.message === 'timeout') return;
    failures += 1;
    if (failures >= 2) relisten(err);
  });
}

function relisten(reason) {
  relistening = true;
  failures = 0;
  console.warn('[libretv-ios] listener looks dead, re-listening:', reason && reason.code);
  try { mainServer.close(); } catch (_) { /* socket 已被系统回收 */ }
  setTimeout(() => {
    try {
      mainServer.listen(PORT, HOST, () => {
        console.log('[libretv-ios] re-listened on', HOST + ':' + PORT);
        relistening = false;
      });
      mainServer.once('error', (e) => {
        console.error('[libretv-ios] re-listen failed', e && e.code);
        relistening = false;
      });
    } catch (e) {
      console.error('[libretv-ios] re-listen threw', e);
      relistening = false;
    }
  }, 300);
}

setInterval(selfCheck, 3000);
