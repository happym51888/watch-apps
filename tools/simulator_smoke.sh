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
# The third assertion is weaker than it sounds, and worth stating plainly: a
# non-blank screen is not a correct screen. Kairos passed this check while
# displaying "Keychain unavailable", because an error screen has plenty of
# distinct colours. The screenshots are uploaded on every run precisely so a
# human can look at them; treat a green job as "it did not crash", not as
# "it works".
#
# They are also useful in their own right: App Store Connect wants watch
# screenshots and there is no Mac here to take them by hand.
#
# Usage: tools/simulator_smoke.sh <app-dir> <scheme>
#   e.g. tools/simulator_smoke.sh apps/Kairos KairosWatch

set -euo pipefail

# `set -e` exits on the first failing command and says nothing about which one.
# Run 11 died between "app: ..." and the next echo, printing no reason at all,
# and identifying the line took longer than fixing it would have. A CI script
# that fails invisibly is only marginally better than no CI script.
on_error() {
    local status=$? line=$1
    echo ""
    echo "!! ${BASH_SOURCE[0]##*/} failed at line ${line} (exit ${status})"
    echo "!! command: ${BASH_COMMAND}"
    echo ""
} >&2
trap 'on_error $LINENO' ERR

APP_DIR="${1:?usage: simulator_smoke.sh <app-dir> <scheme>}"
SCHEME="${2:?usage: simulator_smoke.sh <app-dir> <scheme>}"
PROJECT_NAME="$(basename "$APP_DIR")"
OUT_DIR="$(pwd)/screenshots"
DERIVED="$(pwd)/.sim-build/$SCHEME"

mkdir -p "$OUT_DIR"

echo "==> Picking a watchOS simulator"

# Use a device the runner already has. Creating one from the *last* listed
# Apple Watch device type picked an Apple Watch Series 2 (38mm), which
# watchOS 26 refuses with "Incompatible device" — the device type list is not
# ordered by recency and includes hardware no current runtime supports.
# The pre-created devices are by definition runtime-compatible.
UDID="$(xcrun simctl list devices available --json | python3 -c '
import json, sys

data = json.load(sys.stdin)["devices"]
candidates = []
for runtime, devices in data.items():
    if "watchOS" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable"):
            candidates.append((runtime, device["name"], device["udid"]))

# Prefer the newest runtime, then the largest case, which is the closest thing
# to a default modern watch.
candidates.sort(key=lambda c: (c[0], c[1]))
print(candidates[-1][2] if candidates else "")
')"

if [[ -n "$UDID" ]]; then
    CREATED=0
    echo "    reusing pre-created device $UDID"
else
    # Nothing pre-created: build one, pairing the newest runtime with a device
    # type that runtime actually supports.
    read -r RUNTIME DEVICE_TYPE <<< "$(python3 -c '
import json, subprocess

runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "--json"]))["runtimes"]
watch = [r for r in runtimes if r.get("platform") == "watchOS" and r.get("isAvailable")]
if not watch:
    print(" ")
    raise SystemExit
newest = sorted(watch, key=lambda r: r["version"])[-1]
# supportedDeviceTypes is the runtime own list of what it can run.
supported = newest.get("supportedDeviceTypes", [])
supported.sort(key=lambda d: d["name"])
print(newest["identifier"], supported[-1]["identifier"] if supported else "")
')"

    if [[ -z "${RUNTIME:-}" || -z "${DEVICE_TYPE:-}" ]]; then
        echo "No usable watchOS runtime on this runner."
        xcrun simctl list runtimes
        exit 1
    fi

    echo "    runtime: $RUNTIME"
    echo "    device:  $DEVICE_TYPE"
    UDID="$(xcrun simctl create "ci-$SCHEME" "$DEVICE_TYPE" "$RUNTIME")"
    CREATED=1
    echo "    created  $UDID"
fi

cleanup() {
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    # Only delete what this script made; deleting a runner's pre-created
    # device would break the other schemes running in parallel.
    if [[ "${CREATED:-0}" == "1" ]]; then
        xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

xcrun simctl list devices available | grep -A0 "$UDID" || true

xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b

# Ad-hoc signed (CODE_SIGN_IDENTITY=-) rather than unsigned. An unsigned build
# carries no entitlements, and Kairos then fails every keychain call with
# errSecMissingEntitlement (-34018): it launched, rendered, passed this check,
# and displayed "Keychain unavailable" — the app's whole purpose broken, with
# the job green. Ad-hoc signing on a simulator applies the entitlements file
# without needing a team or a provisioning profile, so the vault is exercised
# for real.
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
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY=- \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM="" \
        PROVISIONING_PROFILE_SPECIFIER="" \
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

# Read the identifier out of the built bundle rather than trusting project.yml,
# so a rename that does not reach the binary is caught here. plutil writes its
# complaint to stderr and returns non-zero; capture both so a failure explains
# itself instead of tripping `set -e` in silence.
if ! BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP_PATH/Info.plist" 2>&1)"; then
    echo "Could not read CFBundleIdentifier from $APP_PATH/Info.plist"
    echo "plutil said: $BUNDLE_ID"
    echo "--- Info.plist keys ---"
    plutil -p "$APP_PATH/Info.plist" 2>&1 | head -40 || true
    exit 1
fi
BUNDLE_ID="$(printf '%s' "$BUNDLE_ID" | tr -d '[:space:]')"
# plutil reports some problems on stdout with a zero exit, which would put its
# own error text into the variable and hand it to simctl as an identifier.
if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+\.[A-Za-z0-9.-]+$ ]]; then
    echo "CFBundleIdentifier is not a bundle identifier: '$BUNDLE_ID'"
    echo "--- Info.plist ---"
    plutil -p "$APP_PATH/Info.plist" 2>&1 | head -40 || true
    exit 1
fi
echo "    bundle id: $BUNDLE_ID"

echo "==> Installing and launching"
set -x
xcrun simctl install "$UDID" "$APP_PATH"
set +x

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
