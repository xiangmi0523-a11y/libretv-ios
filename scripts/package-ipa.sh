#!/usr/bin/env bash
# 把未签名的 LibreTV.app 打成 IPA，并检查结构（供全能签等自签工具安装）。
# 用法：scripts/package-ipa.sh path/to/LibreTV.app dist/LibreTV.ipa
set -euo pipefail

APP="${1:?app path}"
IPA="${2:?ipa path}"
fail() { echo "::error::$1"; exit 1; }

echo "== 检查 App 结构"
test -x "$APP/LibreTV" || fail "缺少主程序"
lipo -info "$APP/LibreTV"
lipo -info "$APP/LibreTV" | grep -q arm64 || fail "主程序不是 arm64"
test -f "$APP/Frameworks/NodeMobile.framework/NodeMobile" || fail "没有内嵌 NodeMobile.framework"
lipo -info "$APP/Frameworks/NodeMobile.framework/NodeMobile"
otool -L "$APP/LibreTV" | grep -q "@rpath/NodeMobile.framework/NodeMobile" || fail "主程序没有链接 NodeMobile"
for f in nodejs-project/main.js nodejs-project/fetch-shim.js nodejs-project/server.js nodejs-project/.next/BUILD_ID \
         nodejs-project/.bundle-id nodejs-project/node_modules/next/package.json nodejs-project/public/favicon.ico; do
  test -e "$APP/$f" || fail "缺少 $f"
done
test -d "$APP/nodejs-project/.next/static" || fail "缺少前端静态资源"
if find "$APP/nodejs-project" -name '*.node' | grep -q .; then fail "包含原生 .node 模块"; fi

echo "== Info.plist"
P="$APP/Info.plist"
for k in CFBundleIdentifier CFBundleDisplayName CFBundleShortVersionString CFBundleVersion MinimumOSVersion; do
  printf '  %-28s %s\n' "$k" "$(plutil -extract "$k" raw "$P")"
done
[ "$(plutil -extract NSAppTransportSecurity.NSAllowsArbitraryLoads raw "$P")" = "true" ] || fail "ATS 未放开（视频源多为 http）"
[ "$(plutil -extract NSAppTransportSecurity.NSAllowsLocalNetworking raw "$P")" = "true" ] || fail "未允许访问本机服务"
plutil -extract UIBackgroundModes json -o - "$P" | grep -q audio || fail "缺少后台音频"
plutil -extract UISupportedInterfaceOrientations json -o - "$P" | grep -q LandscapeLeft || fail "不支持横屏"
plutil -extract UIApplicationSceneManifest json -o - "$P" >/dev/null || fail "缺少 Scene 配置"
test -f "$APP/Assets.car" || fail "缺少资源目录（图标）"
plutil -extract CFBundleIcons json -o - "$P" | grep -q AppIcon || fail "Info.plist 没有图标"

echo "== 打包"
WORK="$(mktemp -d)"
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
rm -rf "$WORK/Payload/LibreTV.app/_CodeSignature" "$WORK/Payload/LibreTV.app/embedded.mobileprovision"
mkdir -p "$(dirname "$IPA")"
IPA_ABS="$(cd "$(dirname "$IPA")" && pwd)/$(basename "$IPA")"
(cd "$WORK" && zip -qry "$IPA_ABS" Payload)
unzip -l "$IPA_ABS" | grep -q "Payload/LibreTV.app/LibreTV$" || fail "IPA 结构不对"
unzip -l "$IPA_ABS" | grep -q "Payload/LibreTV.app/nodejs-project/.next/BUILD_ID" || fail "IPA 里缺少 .next（隐藏目录被漏掉）"
ls -lh "$IPA_ABS"
shasum -a 256 "$IPA_ABS"
