'use strict';
/*
 * LibreTV iOS：不依赖 WebAssembly 的 fetch / undici 替身。
 *
 * 为什么需要：iOS 禁止 App 使用 JIT，内置的 nodejs-mobile 只能以 --jitless 运行，
 * 此模式下 V8 没有 WebAssembly。Node 自带 fetch 与 undici 包都靠 llhttp 的 wasm
 * 解析 HTTP，一调用就抛 "WebAssembly is not defined"。
 *
 * 这里用 Node 的 http/https 模块实现 LibreTV 服务端用到的那部分接口：
 *   - fetch(input, init)：WHATWG 语义（redirect follow/manual/error、signal、自动解压）
 *   - Agent / buildConnector：给 src/lib/ssrf.ts 的连接级 SSRF 防护用，
 *     连接仍走它自带的 safeLookup 与黑名单校验，防护逻辑原样保留。
 *
 * 构建 iOS 版时，next.config.ts 把 `undici` 别名到本文件；main.js 也用它替换全局 fetch。
 */
const http = require('http');
const https = require('https');
const net = require('net');
const tls = require('tls');
const zlib = require('zlib');
const { Readable } = require('stream');

const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);
const NULL_BODY_STATUSES = new Set([101, 103, 204, 205, 304]);
const MAX_REDIRECTS = 20;

const keepAliveHttp = new http.Agent({ keepAlive: true, maxSockets: 64 });
const keepAliveHttps = new https.Agent({ keepAlive: true, maxSockets: 64 });

function abortError(signal) {
  const reason = signal && signal.reason;
  if (reason !== undefined) return reason;
  try {
    return new DOMException('This operation was aborted', 'AbortError');
  } catch (_) {
    const e = new Error('This operation was aborted');
    e.name = 'AbortError';
    return e;
  }
}

function fetchFailed(cause) {
  const err = new TypeError('fetch failed');
  err.cause = cause;
  return err;
}

/** buildConnector：返回 undici 风格的 connector(opts, cb)，用给定 lookup 建立 TCP/TLS 连接 */
function buildConnector(options) {
  const lookup = options && options.lookup;
  const timeout = (options && options.timeout) || 10000;
  return function connector(opts, cb) {
    const protocol = opts.protocol || 'https:';
    const hostname = String(opts.hostname || '').replace(/^\[+|\]+$/g, '');
    const port = Number(opts.port) || (protocol === 'http:' ? 80 : 443);
    let socket;
    let done = false;
    const finish = (err, s) => {
      if (done) return;
      done = true;
      if (s) s.setTimeout(0);
      cb(err, err ? null : s);
    };
    try {
      if (protocol === 'https:') {
        const servername = opts.servername || (net.isIP(hostname) ? undefined : hostname);
        socket = tls.connect({ host: hostname, port, servername, lookup, autoSelectFamily: true, ALPNProtocols: ['http/1.1'] });
        socket.once('secureConnect', () => finish(null, socket));
      } else {
        socket = net.connect({ host: hostname, port, lookup, autoSelectFamily: true });
        socket.once('connect', () => finish(null, socket));
      }
    } catch (e) {
      return finish(e, null);
    }
    socket.setTimeout(timeout, () => socket.destroy(Object.assign(new Error('Connect Timeout'), { code: 'UND_ERR_CONNECT_TIMEOUT' })));
    socket.once('error', (e) => finish(e, null));
  };
}

/** Agent：只保存 connect 函数，供 fetch 通过 init.dispatcher 使用；不做连接复用 */
class Agent {
  constructor(options) {
    this.connect = options && typeof options.connect === 'function' ? options.connect : buildConnector({});
    this.closed = false;
  }
  close() { this.closed = true; return Promise.resolve(); }
  destroy() { this.closed = true; return Promise.resolve(); }
}

function decodeBody(res, method, status) {
  if (method === 'HEAD' || NULL_BODY_STATUSES.has(status)) {
    res.resume();
    return null;
  }
  const enc = String(res.headers['content-encoding'] || '').toLowerCase().trim();
  let stream = res;
  const onErr = (e) => stream.destroy(e);
  if (enc === 'gzip' || enc === 'x-gzip') {
    stream = res.pipe(zlib.createGunzip({ flush: zlib.constants.Z_SYNC_FLUSH, finishFlush: zlib.constants.Z_SYNC_FLUSH }));
    res.on('error', onErr);
  } else if (enc === 'deflate') {
    // 有的服务器发 raw deflate，有的发 zlib 包装；按首字节判断
    const pass = new (require('stream').PassThrough)();
    let decided = false;
    res.on('data', (chunk) => {
      if (!decided) {
        decided = true;
        const looksZlib = chunk.length > 0 && (chunk[0] & 0x0f) === 8;
        const inflater = looksZlib ? zlib.createInflate() : zlib.createInflateRaw();
        inflater.on('error', (e) => pass.destroy(e));
        inflater.pipe(pass);
        res.pause();
        inflater.write(chunk);
        res.on('data', (c) => inflater.write(c));
        res.on('end', () => inflater.end());
        res.resume();
        return;
      }
    });
    res.on('end', () => { if (!decided) pass.end(); });
    res.on('error', (e) => pass.destroy(e));
    stream = pass;
  } else if (enc === 'br') {
    stream = res.pipe(zlib.createBrotliDecompress());
    res.on('error', onErr);
  }
  return Readable.toWeb(stream);
}

function buildHeaders(rawHeaders) {
  const h = new Headers();
  for (let i = 0; i + 1 < rawHeaders.length; i += 2) {
    try { h.append(rawHeaders[i], rawHeaders[i + 1]); } catch (_) { /* 非法头直接忽略 */ }
  }
  return h;
}

function makeResponse(res, method, url, redirected) {
  let status = res.statusCode || 0;
  if (status < 200 || status > 599) status = status >= 100 && status < 200 ? 200 : 502;
  const body = decodeBody(res, method, status);
  const response = new Response(NULL_BODY_STATUSES.has(status) ? null : body, {
    status,
    statusText: res.statusMessage || '',
    headers: buildHeaders(res.rawHeaders),
  });
  try { Object.defineProperty(response, 'url', { value: url, configurable: true }); } catch (_) {}
  try { Object.defineProperty(response, 'redirected', { value: !!redirected, configurable: true }); } catch (_) {}
  return response;
}

function requestOnce(urlObj, method, headers, body, signal, dispatcher) {
  return new Promise((resolve, reject) => {
    const isHttps = urlObj.protocol === 'https:';
    const lib = isHttps ? https : http;
    const outHeaders = {};
    headers.forEach((v, k) => { outHeaders[k] = v; });
    if (!outHeaders['accept']) outHeaders['accept'] = '*/*';
    if (!outHeaders['accept-language']) outHeaders['accept-language'] = '*';
    if (!outHeaders['accept-encoding']) outHeaders['accept-encoding'] = 'gzip, deflate, br';
    if (!outHeaders['user-agent']) outHeaders['user-agent'] = 'node';
    if (body && outHeaders['content-length'] === undefined) outHeaders['content-length'] = String(body.length);

    const options = {
      protocol: urlObj.protocol,
      hostname: urlObj.hostname.replace(/^\[+|\]+$/g, ''),
      port: urlObj.port || (isHttps ? 443 : 80),
      path: (urlObj.pathname || '/') + (urlObj.search || ''),
      method,
      headers: outHeaders,
      // 域名同时有 IPv4/IPv6 时并行尝试（Happy Eyeballs），避免手机网络 IPv6 不通时卡住
      autoSelectFamily: true,
    };
    if (dispatcher && typeof dispatcher.connect === 'function') {
      // 不设 agent（undefined）时 ClientRequest 才会使用 createConnection；agent:false 会新建默认 Agent
      options.createConnection = (_o, oncreate) => {
        dispatcher.connect(
          { protocol: urlObj.protocol, hostname: options.hostname, port: String(options.port), servername: isHttps && !net.isIP(options.hostname) ? options.hostname : undefined },
          (err, socket) => oncreate(err, socket)
        );
        return undefined;
      };
    } else {
      options.agent = isHttps ? keepAliveHttps : keepAliveHttp;
    }

    let settled = false;
    const req = lib.request(options);
    const onAbort = () => {
      const err = abortError(signal);
      req.destroy(err);
      if (!settled) { settled = true; reject(err); }
    };
    if (signal) {
      if (signal.aborted) return onAbort();
      signal.addEventListener('abort', onAbort, { once: true });
    }
    req.on('response', (res) => {
      if (settled) { res.resume(); return; }
      settled = true;
      if (signal) {
        res.once('close', () => signal.removeEventListener('abort', onAbort));
        signal.addEventListener('abort', () => res.destroy(abortError(signal)), { once: true });
      }
      resolve(res);
    });
    req.on('error', (err) => {
      if (signal) signal.removeEventListener('abort', onAbort);
      if (settled) return;
      settled = true;
      if (signal && signal.aborted) reject(abortError(signal));
      else reject(fetchFailed(err));
    });
    if (body) req.end(body); else req.end();
  });
}

async function fetchShim(input, init) {
  init = init || {};
  const dispatcher = init.dispatcher;
  const reqInit = Object.assign({}, init);
  delete reqInit.dispatcher;
  delete reqInit.signal;
  if (reqInit.body && typeof reqInit.body.getReader === 'function' && !reqInit.duplex) reqInit.duplex = 'half';
  const request = new Request(input, reqInit);
  const signal = init.signal || (input && typeof input === 'object' && input.signal) || null;
  if (signal && signal.aborted) throw abortError(signal);

  let method = request.method.toUpperCase();
  const headers = new Headers(request.headers);
  let body = request.body ? Buffer.from(await request.arrayBuffer()) : null;
  const redirectMode = init.redirect || request.redirect || 'follow';
  let url = new URL(request.url);
  let redirected = false;

  for (let hop = 0; ; hop++) {
    if (url.protocol !== 'http:' && url.protocol !== 'https:') {
      throw fetchFailed(new Error('unsupported protocol ' + url.protocol));
    }
    const res = await requestOnce(url, method, headers, body, signal, dispatcher);
    const status = res.statusCode || 0;
    const location = res.headers.location;
    if (REDIRECT_STATUSES.has(status) && location && redirectMode !== 'manual') {
      res.resume();
      if (redirectMode === 'error') throw fetchFailed(new Error('unexpected redirect'));
      if (hop >= MAX_REDIRECTS) throw fetchFailed(new Error('redirect count exceeded'));
      const next = new URL(location, url);
      if (status === 303 || ((status === 301 || status === 302) && method === 'POST')) {
        if (method !== 'HEAD') method = 'GET';
        body = null;
        ['content-type', 'content-length', 'content-encoding', 'content-language', 'content-location'].forEach((k) => headers.delete(k));
      }
      if (next.origin !== url.origin) {
        headers.delete('authorization');
        headers.delete('cookie');
        headers.delete('proxy-authorization');
      }
      headers.delete('host');
      url = next;
      redirected = true;
      continue;
    }
    return makeResponse(res, method, url.href, redirected);
  }
}

module.exports = { fetch: fetchShim, Agent, buildConnector };
module.exports.default = module.exports;
