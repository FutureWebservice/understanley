#!/bin/bash
# Builds Understanley.app (native SwiftUI, no Xcode) and a distributable DMG.
# DMG is created with hdiutil (Apple's official tool — most stable/secure).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Understanley"
APP_BUNDLE="$ROOT/$APP_NAME.app"
DMG_PATH="$ROOT/$APP_NAME.dmg"
BIN="$ROOT/.build/release/$APP_NAME"

echo "==> Release build"
swift build -c release

echo "==> Assemble .app bundle"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
# Write PkgInfo (8-byte) — convention for packaged apps.
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Generate the app icon programmatically so it isn't generic. Every step is
# guarded so a machine without Pillow still produces a working (if iconless) app.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
python3 - "$ICONSET" <<'PYICON' || true
import math
import sys

from PIL import Image, ImageDraw

out = sys.argv[1]
W = 1024
SS = 2                      # supersample factor — draw big, downsample for AA
S = W * SS

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# Rounded-square deep-space background with a subtle vertical gradient.
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle(
    [40 * SS, 40 * SS, S - 40 * SS, S - 40 * SS], radius=210 * SS, fill=255
)
bg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(bg)
for y in range(S):
    t = y / S
    gd.line([(0, y), (S, y)], fill=(int(10 + t * 8), int(10 + t * 8), int(14 + t * 12), 255))
img.paste(bg, (0, 0), mask)

d = ImageDraw.Draw(img, "RGBA")

# A knowledge graph: one bright hub, satellites on two rings, edges between them.
GOLD = (212, 165, 116)
CX = CY = S // 2
nodes = [(CX, CY, 62 * SS, 1.0)]
for ring, (count, radius, size, phase) in enumerate(
    [(5, 250 * SS, 34 * SS, -math.pi / 2), (7, 385 * SS, 24 * SS, -math.pi / 2 + 0.45)]
):
    for i in range(count):
        a = phase + i * (2 * math.pi / count)
        nodes.append((CX + math.cos(a) * radius, CY + math.sin(a) * radius, size, 0.85 - ring * 0.2))

# Edges: hub to inner ring, then inner ring outward, then a rim arc.
edges = [(0, i) for i in range(1, 6)]
edges += [(1 + (i % 5), 6 + i) for i in range(7)]
edges += [(1, 2), (2, 3), (3, 4), (4, 5), (5, 1)]
for a, b in edges:
    x1, y1, _, _ = nodes[a]
    x2, y2, _, _ = nodes[b]
    d.line([(x1, y1), (x2, y2)], fill=GOLD + (90,), width=5 * SS)

# Nodes on top, with a faint halo so they read as light rather than discs.
for x, y, r, alpha in nodes:
    d.ellipse([x - r * 1.9, y - r * 1.9, x + r * 1.9, y + r * 1.9], fill=GOLD + (26,))
    d.ellipse([x - r, y - r, x + r, y + r], fill=GOLD + (int(255 * alpha),))

img = img.resize((W, W), Image.LANCZOS)

specs = [(16, 16), (16, 32), (32, 32), (32, 64), (128, 128), (128, 256),
         (256, 256), (256, 512), (512, 512), (512, 1024)]
for label, size in specs:
    img.resize((size, size), Image.LANCZOS).save(f"{out}/icon_{label}.png")
    if label in (16, 32, 128, 256, 512):
        img.resize((label * 2, label * 2), Image.LANCZOS).save(f"{out}/icon_{label}@2x.png")
PYICON
if [ -f "$ICONSET/icon_512.png" ]; then
  if iconutil -c icns -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns" "$ICONSET" 2>/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
  fi
fi

# Ad-hoc signature — deliberate, not an oversight.
#
# A Gatekeeper-clean download needs a Developer ID Application certificate
# (paid Apple Developer Program) plus notarisation, and this project ships
# neither. Ad-hoc still buys the two things that matter locally: the binary
# gets a stable identity so the Keychain will hand it the same items across
# rebuilds, and the hardened runtime is exercised in development rather than
# discovered at release time.
#
# The cost is one extra click for anyone who downloads the DMG. README says so
# plainly rather than letting it look like the app is broken.
echo "==> Ad-hoc codesign (no Developer ID — see README, \"About the signature\")"
codesign --force --deep --options runtime --sign - "$APP_BUNDLE"
codesign --verify --verbose=1 "$APP_BUNDLE" 2>/dev/null || true

echo "==> Create DMG with hdiutil"
rm -f "$DMG_PATH"
STAGING="$(mktemp -d)"
cp -R "$APP_BUNDLE" "$STAGING/"
# Add a soft Applications link so users can drag-to-install
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -fs APFS -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGING"

echo
echo "✅ Done."
echo "   App:  $APP_BUNDLE"
echo "   DMG:  $DMG_PATH"
du -sh "$APP_BUNDLE" "$DMG_PATH"
echo
echo "   Ad-hoc signed. Built here it opens normally; downloaded it is quarantined,"
echo "   so the first launch needs right-click -> Open. See README."
