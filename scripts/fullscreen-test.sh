#!/usr/bin/env bash
# 模拟器里验证：hls.js 播放 → 进全屏 → 转横屏后画面仍然在（不是只有声音）。
# 用法：scripts/fullscreen-test.sh path/to/LibreTV.app out-dir
# 依赖：ffmpeg（生成本机测试彩条视频）、python3 + Pillow（分析截图）
set -euo pipefail

APP="${1:?app path}"
OUT="${2:-sim-out}/fullscreen"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="com.xiangmi.libretv"
PORT=8099
mkdir -p "$OUT"

WORK="$(mktemp -d)"
cp "$ROOT/tests/fullscreen/index.html" "$WORK/"
cp "$ROOT/libretv/node_modules/hls.js/dist/hls.min.js" "$WORK/"
mkdir -p "$WORK/hls"
# 60 秒 1280x720 彩条 + 正弦音，切成 HLS
ffmpeg -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=30 -f lavfi -i sine=frequency=440:sample_rate=48000 \
  -t 60 -c:v libx264 -profile:v main -pix_fmt yuv420p -g 60 -c:a aac -b:a 96k \
  -f hls -hls_time 4 -hls_playlist_type vod -hls_segment_filename "$WORK/hls/seg%03d.ts" "$WORK/hls/index.m3u8"

cat > "$WORK/serve.py" <<'PY'
import http.server, sys, functools
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()
    def do_GET(self):
        if self.path.startswith('/report?'):
            sys.stderr.write('REPORT ' + self.path + '\n'); sys.stderr.flush()
            self.send_response(204); self.end_headers(); return
        super().do_GET()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), functools.partial(H, directory=sys.argv[2])).serve_forever()
PY
python3 "$WORK/serve.py" "$PORT" "$WORK" 2> "$OUT/server.log" &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 1

UDID=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys;d=json.load(sys.stdin)["devices"];print([x["udid"] for v in d.values() for x in v if x["state"]=="Booted"][0])')
echo "模拟器: $UDID"

colorful() {
  python3 - "$1" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGB')
im.thumbnail((400, 400))
px = list(im.getdata())
n = sum(1 for r, g, b in px if max(r, g, b) - min(r, g, b) > 60)
print(f"{n / len(px):.3f}")
PY
}

run_mode() {
  local mode="$1" elementfs="$2"
  echo "== 模式 ${mode}（元素全屏=${elementfs}）"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  sleep 2
  local before
  before=$(wc -l < "$OUT/server.log")
  xcrun simctl launch "$UDID" "$BUNDLE_ID" \
    -LTVTestURL "http://127.0.0.1:${PORT}/index.html?mode=${mode}" \
    -LTVTestFullscreen YES -LTVTestElementFullscreen "$elementfs" >/dev/null
  # 等到 App 自动发起全屏（起播约 12 秒后）
  for i in $(seq 1 90); do
    tail -n +"$((before + 1))" "$OUT/server.log" | grep -q "msg=fs-" && break
    sleep 1
  done
  sleep 2
  xcrun simctl io "$UDID" screenshot "$OUT/${mode}-1-fullscreen.png" >/dev/null 2>&1
  # App 在全屏 4 秒后请求横屏
  sleep 8
  xcrun simctl io "$UDID" screenshot "$OUT/${mode}-2-landscape.png" >/dev/null 2>&1
  tail -n +"$((before + 1))" "$OUT/server.log" | sed -e 's/^REPORT \/report?/  · /' | python3 -c 'import sys,urllib.parse;[print(urllib.parse.unquote_plus(l.rstrip())) for l in sys.stdin]'
  local a b
  a=$(colorful "$OUT/${mode}-1-fullscreen.png")
  b=$(colorful "$OUT/${mode}-2-landscape.png")
  echo "  画面彩色像素比例：全屏 ${a}，横屏 $b"
  echo "$mode $a $b" >> "$OUT/result.txt"
}

: > "$OUT/result.txt"
run_mode element YES   # 旧版行为（元素全屏），只做对照
run_mode native NO     # 新版行为（原生视频全屏），必须有画面
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true

read -r _ na nb < <(grep '^native' "$OUT/result.txt")
python3 -c "import sys; sys.exit(0 if float('${nb}') >= 0.08 and float('${na}') >= 0.08 else 1)" \
  && echo "  ✓ 原生全屏 + 横屏有画面" \
  || { echo "::error::原生全屏/横屏后看不到画面（彩色比例 全屏 $na / 横屏 ${nb}）"; exit 1; }
