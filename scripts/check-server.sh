#!/usr/bin/env bash
# 对一个正在运行的 LibreTV 本地服务做冒烟检查。
# 用法：scripts/check-server.sh http://127.0.0.1:38080 <PASSWORD>
set -uo pipefail

BASE="${1:?base url}"
PASS="${2:?password}"
JAR="$(mktemp)"
FAIL=0

ok()   { echo "  ✓ $1"; }
bad()  { echo "  ✗ $1"; FAIL=1; }

echo "== 检查 $BASE"

body=$(curl -sS -m 20 "$BASE/api/status") && echo "$body" | grep -q '"version"' && ok "/api/status: $body" || bad "/api/status: ${body:-无响应}"

body=$(curl -sS -m 20 -c "$JAR" -H 'content-type: application/json' -d "{\"password\":\"$PASS\"}" "$BASE/api/auth")
echo "$body" | grep -q '"success":true' && ok "登录" || bad "登录: $body"

code=$(curl -sS -m 60 -b "$JAR" -o /tmp/ltv-home.html -w '%{http_code}' "$BASE/")
[ "$code" = 200 ] && grep -q "LibreTV" /tmp/ltv-home.html && ok "首页 200" || bad "首页: $code"

code=$(curl -sS -m 60 -b "$JAR" -o /dev/null -w '%{http_code}' "$BASE/watch")
[ "$code" = 200 ] && ok "播放页 200" || bad "播放页: $code"

# 服务端出网（全局 fetch → fetch-shim，HTTPS + gzip）
code=$(curl -sS -m 60 -b "$JAR" -o /tmp/ltv-bgm.json -w '%{http_code}' "$BASE/api/bangumi/calendar")
[ "$code" = 200 ] && ok "番剧放送表（服务端 HTTPS 出网）: $(head -c 80 /tmp/ltv-bgm.json)" || bad "番剧放送表: $code $(head -c 200 /tmp/ltv-bgm.json)"

# 通用代理（ssrf.ts 的连接级防护 → undici 别名 → fetch-shim 的 Agent/connector）
target=$(python3 -c 'import urllib.parse;print(urllib.parse.quote("https://www.apple.com/robots.txt", safe=""))')
code=$(curl -sS -m 60 -b "$JAR" -o /tmp/ltv-proxy.txt -w '%{http_code}' "$BASE/api/proxy/$target")
[ "$code" = 200 ] && grep -qi "user-agent" /tmp/ltv-proxy.txt && ok "代理转发（SSRF 防护通道）" || bad "代理转发: $code $(head -c 200 /tmp/ltv-proxy.txt)"

# SSRF 防护仍然有效：代理不能访问本机
target=$(python3 -c 'import urllib.parse;print(urllib.parse.quote("http://127.0.0.1:38080/api/status", safe=""))')
code=$(curl -sS -m 30 -b "$JAR" -o /tmp/ltv-ssrf.txt -w '%{http_code}' "$BASE/api/proxy/$target")
[ "$code" != 200 ] && ok "SSRF 防护拦截本机地址（$code）" || bad "SSRF 防护失效：代理访问到了本机"

# 豆瓣在海外机房可能被限流，只提示不判失败
code=$(curl -sS -m 60 -b "$JAR" -o /tmp/ltv-db.json -w '%{http_code}' "$BASE/api/douban?type=movie&tag=%E7%83%AD%E9%97%A8&page_limit=4&page_start=0")
echo "  · 豆瓣推荐（仅参考）: $code $(head -c 100 /tmp/ltv-db.json)"

rm -f "$JAR"
exit $FAIL
