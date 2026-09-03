#!/bin/bash
#
# Build a watch app for the simulator, install it, launch it, and photograph
# what appears.
#
# This exists because `xcodebuild build` succeeding proves the code compiles
# and nothing more. Every app in this repo could compile perfectly and crash on
# the first line of `App.init`, or launch to a blank screen because a view
# hierarchy throws, and CI would still be green. That is the same silent-failure
# shape the Python validators were written for, one layer up.
#
# So this asserts three things a build cannot:
#
#   1. the app installs onto a watchOS runtime
#   2. it launches and stays alive
#   3. what it draws is not a blank screen
#
# The screenshots are a by-product, and a useful one: App Store Connect wants
# watch screenshots and there is no Mac here to take them by hand.
#
# Usage: tools/simulator_smoke.sh <app-dir> <scheme>
#   e.g. tools/simulator_smoke.sh apps/Kairos KairosWatch

set -euo pipefail

APP_DIR="${1:?usage: simulator_smoke.sh <app-dir> <scheme>}"
SCHEME="${2:?usage: simulator_smoke.sh <app-dir> <scheme>}"
PROJECT_NAME="$(basename "$APP_DIR")"
OUT_DIR="$(pwd)/screenshots"
DERIVED="$(pwd)/.sim-build/$SCHEME"

mkdir -p "$OUT_DIR"

echo "==> Picking a watchOS simulator"
RUNTIME="$(xcrun simctl list runtimes --json \
    | python3 -c 'import json,sys; rs=[r for r in json.load(sys.stdin)["runtimes"] if r.get("platform")=="watchOS" and r.get("isAvailable")]; print(rs[-1]["identifier"] if rs else "")')"
DEVICE_TYPE="$(xcrun simctl list devicetypes --json \
    | python3 -c 'import json,sys; ds=[d for d in json.load(sys.stdin)["devicetypes"] if d.get("productFamily")=="Apple Watch"]; print(ds[-1]["identifier"] if ds else "")')"

if [[ -z "$RUNTIME" || -z "$DEVICE_TYPE" ]]; then
    echo "No watchOS runtime or Apple Watch device type available on this runner."
    echo "Available runtimes:"
    xcrun simctl list runtimes
    exit 1
fi

echo "    runtime: $RUNTIME"
echo "    device:  $DEVICE_TYPE"

# A dedicated device per scheme, so a wedged simulator from a previous scheme
# cannot make the next one look broken.
UDID="$(xcrun simctl create "ci-$SCHEME" "$DEVICE_TYPE" "$RUNTIME")"
echo "    udid:    $UDID"

cleanup() {
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b

echo "==> Building $SCHEME for the simulator"
(
    cd "$APP_DIR"
    xcodegen generate
    xcodebuild build \
        -project "$PROJECT_NAME.xcodeproj" \
        -scheme "$SCHEME" \
        -destination "id=$UDID" \
        -configuration Debug \
        -derivedDataPath "$DERIVED" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        ENABLE_USER_SCRIPT_SANDBOXING=NO \
        > "$OUT_DIR/build-sim-$SCHEME.log" 2>&1 \
        || { echo "Simulator build failed; last 40 lines:"; tail -40 "$OUT_DIR/build-sim-$SCHEME.log"; exit 1; }
)

APP_PATH="$(find "$DERIVED/Build/Products" -maxdepth 2 -name '*.app' -type d | head -1)"
if [[ -z "$APP_PATH" ]]; then
    echo "No .app produced under $DERIVED/Build/Products"
    find "$DERIVED/Build/Products" -maxdepth 3 || true
    exit 1
fi
echo "    app: $APP_PATH"

BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Info.plist")"
echo "    bundle id: $BUNDLE_ID"

echo "==> Installing and launching"
xcrun simctl install "$UDID" "$APP_PATH"

# --terminate-running-process so a stale copy cannot be mistaken for a
# successful launch of the build under test.
LAUNCH_OUTPUT="$(xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" 2>&1)"
echo "    $LAUNCH_OUTPUT"
PID="$(echo "$LAUNCH_OUTPUT" | grep -oE '[0-9]+$' | tail -1 || true)"

if [[ -z "$PID" ]]; then
    echo "Launch did not report a pid — the app did not start."
    exit 1
fi

# Long enough for SwiftUI to lay out and for anything that crashes on startup
# to have done so.
sleep 12

echo "==> Checking it is still alive"
if xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -q "$BUNDLE_ID"; then
    echo "    still registered with launchd"
else
    # Not fatal by itself: a watchOS app can be suspended once it is no longer
    # frontmost. The screenshot check below is the real verdict.
    echo "    warning: not listed by launchd (may be suspended)"
fi

CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
if compgen -G "$CRASH_DIR/*.ips" > /dev/null; then
    if grep -l "$BUNDLE_ID" "$CRASH_DIR"/*.ips >/dev/null 2>&1; then
        echo "A crash report exists for $BUNDLE_ID:"
        grep -l "$BUNDLE_ID" "$CRASH_DIR"/*.ips | while read -r report; do
            echo "--- $report"
            head -40 "$report"
        done
        exit 1
    fi
fi
echo "    no crash report"

echo "==> Screenshot"
SHOT="$OUT_DIR/$SCHEME.png"
xcrun simctl io "$UDID" screenshot "$SHOT"

python3 - "$SHOT" <<'PY'
import sys, zlib, struct

# Decode the PNG far enough to measure how much of the frame is not one flat
# colour. A crashed or blank app is a uniform screen; a laid-out SwiftUI view
# is not. Written against the standard library so the runner needs no Pillow.
path = sys.argv[1]
data = open(path, "rb").read()
assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"

pos, width, height, idat, bit_depth, colour = 8, 0, 0, b"", 8, 6
while pos < len(data):
    length, kind = struct.unpack(">I4s", data[pos:pos + 8])
    body = data[pos + 8:pos + 8 + length]
    if kind == b"IHDR":
        width, height, bit_depth, colour = struct.unpack(">IIBB", body[:10])
    elif kind == b"IDAT":
        idat += body
    elif kind == b"IEND":
        break
    pos += 12 + length

channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colour]
assert bit_depth == 8, f"unexpected bit depth {bit_depth}"
raw = zlib.decompress(idat)
stride = width * channels

# Undo the per-scanline filters.
out = bytearray()
prev = bytearray(stride)
i = 0
for _ in range(height):
    ftype = raw[i]; i += 1
    line = bytearray(raw[i:i + stride]); i += stride
    if ftype == 1:
        for x in range(channels, stride):
            line[x] = (line[x] + line[x - channels]) & 0xFF
    elif ftype == 2:
        for x in range(stride):
            line[x] = (line[x] + prev[x]) & 0xFF
    elif ftype == 3:
        for x in range(stride):
            left = line[x - channels] if x >= channels else 0
            line[x] = (line[x] + ((left + prev[x]) >> 1)) & 0xFF
    elif ftype == 4:
        for x in range(stride):
            a = line[x - channels] if x >= channels else 0
            b = prev[x]
            c = prev[x - channels] if x >= channels else 0
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[x] = (line[x] + pr) & 0xFF
    out += line
    prev = line

# Count distinct colours on a coarse grid; enough to tell "something rendered"
# from "flat screen" without pulling in an image library.
seen = set()
step = max(1, height // 60)
for y in range(0, height, step):
    row = y * stride
    for x in range(0, width, max(1, width // 60)):
        off = row + x * channels
        seen.add(bytes(out[off:off + 3]))

print(f"    {width}x{height}, {len(seen)} distinct colours sampled")
if len(seen) < 3:
    print("    FAIL: the screen is effectively blank — the app did not render")
    sys.exit(1)
print("    the app rendered something")
PY

echo "==> $SCHEME OK"
