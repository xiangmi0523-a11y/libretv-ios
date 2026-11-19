#!/usr/bin/env bash
# 在 iOS 模拟器里装上 App、启动，验证内置的 LibreTV 服务真的在 iOS 上跑起来，并截图。
# 用法：scripts/simulator-test.sh path/to/LibreTV.app out-dir
set -euo pipefail

APP="${1:?app path}"
OUT="${2:-sim-out}"
BUNDLE_ID="com.xiangmi.libretv"
BASE="http://127.0.0.1:38080"
mkdir -p "$OUT"

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys, re
d = json.load(sys.stdin)["devices"]
best = None
for runtime, devs in d.items():
    if "iOS" not in runtime:
        continue
    ver = tuple(int(x) for x in re.findall(r"\d+", runtime.split("iOS")[-1]))
    for dev in devs:
        if dev.get("isAvailable") and dev["name"].startswith("iPhone"):
            key = (ver, "Pro" in dev["name"])
            if best is None or key > best[0]:
                best = (key, dev["udid"], dev["name"], runtime)
print(best[1])
print(best[2] + " / " + best[3], file=sys.stderr)
')
echo "模拟器: $UDID"

xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" "$BUNDLE_ID"

DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)
dump_logs() {
  cp "$DATA/Documents/logs/node.log" "$OUT/node.log" 2>/dev/null || true
  echo "--- node.log（末尾）"; tail -60 "$OUT/node.log" 2>/dev/null || echo "(无)"
}
trap dump_logs EXIT

echo "等待 App 内的本地服务启动…"
ready=0
for i in $(seq 1 180); do
  if curl -sf -m 3 "$BASE/api/status" >/dev/null; then ready=1; echo "服务就绪（${i}s）"; break; fi
  sleep 1
done
[ "$ready" = 1 ] || { echo "::error::App 内服务 180 秒内没有启动"; exit 1; }

# App 首次启动时随机生成本地密码存进 UserDefaults；偏好可能稍后才落盘，多试几次
read_pass() {
  local plist="$DATA/Library/Preferences/$BUNDLE_ID.plist"
  if [ -f "$plist" ]; then
    python3 -c 'import plistlib,sys;print(plistlib.load(open(sys.argv[1],"rb")).get("ltv.local.password",""))' "$plist" 2>/dev/null
    return
  fi
  xcrun simctl spawn "$UDID" defaults read "$plist" ltv.local.password 2>/dev/null || true
}
PASS=""
for i in $(seq 1 60); do
  PASS=$(read_pass)
  [ -n "$PASS" ] && break
  sleep 1
done
[ -n "$PASS" ] || { echo "::error::读不到 App 生成的本地密码"; ls -la "$DATA/Library/Preferences" || true; exit 1; }
"$(dirname "$0")/check-server.sh" "$BASE" "$PASS"

# 等网页渲染完再截图
sleep 20
xcrun simctl io "$UDID" screenshot "$OUT/1-home.png"

# 切到后台（打开系统设置）再切回来，确认服务仍可用
xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null
sleep 25
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
ok=0
for i in $(seq 1 40); do
  if curl -sf -m 3 "$BASE/api/status" >/dev/null; then ok=1; break; fi
  sleep 1
done
[ "$ok" = 1 ] && echo "  ✓ 切后台再回来，服务正常" || { echo "::error::切回前台后服务不可用"; exit 1; }
sleep 5
xcrun simctl io "$UDID" screenshot "$OUT/2-after-resume.png"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" || true
echo "模拟器测试通过"
