#!/usr/bin/env bash
# 构建 LibreTV（Next.js standalone）并组装成 App 内置的 nodejs-project。
# 用法：scripts/build-node-bundle.sh   （在仓库根目录执行，需要 Node 20+ 与 npm）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/libretv"
OUT="$ROOT/ios/nodejs-project"

cd "$SRC"
npm ci --no-audit --no-fund

# IOS_BUILD=1：next.config.ts 把 undici 别名到 nodejs/fetch-shim.js（iOS 上没有 WebAssembly）
IOS_BUILD=1 \
IOS_UNDICI_SHIM="$ROOT/nodejs/fetch-shim.js" \
DOCKER_BUILD=1 \
NEXT_TELEMETRY_DISABLED=1 \
npm run build

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R .next/standalone/. "$OUT/"
cp -R public "$OUT/public"
mkdir -p "$OUT/.next"
cp -R .next/static "$OUT/.next/static"
cp "$ROOT/nodejs/main.js" "$ROOT/nodejs/fetch-shim.js" "$OUT/"

# 与上游 release-standalone 相同：去掉平台相关的 sharp，删掉任何 .env
rm -rf "$OUT/node_modules/sharp" "$OUT/node_modules/@img"
rm -f "$OUT"/.env "$OUT"/.env.*
# Next 的构建缓存不需要进 App
rm -rf "$OUT/.next/cache"

if find "$OUT" -name '*.node' | grep -q .; then
  echo "::error::产物里有原生模块（.node），iOS 上无法加载："
  find "$OUT" -name '*.node'
  exit 1
fi
if grep -l "WebAssembly" "$OUT"/.next/server/chunks/*.js 2>/dev/null | grep -q .; then
  echo "::error::服务端代码里仍有 WebAssembly 引用（undici 别名未生效？）"
  grep -l "WebAssembly" "$OUT"/.next/server/chunks/*.js
  exit 1
fi
test -f "$OUT/.next/BUILD_ID"
test -f "$OUT/server.js"

# App 用这个标记判断是否需要把内置服务复制到可写目录
echo "$(cat "$OUT/.next/BUILD_ID")-$(date -u +%Y%m%d%H%M%S)" > "$OUT/.bundle-id"

echo "nodejs-project 已生成：$(du -sh "$OUT" | cut -f1)"
