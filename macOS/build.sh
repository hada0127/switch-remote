#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app="$PWD/build/switch-remote.app"
# Recreate only this generated app bundle so removed resources cannot linger.
python3 - "$app" <<'PYBUILD'
import pathlib, shutil, sys
app = pathlib.Path(sys.argv[1])
if app.exists(): shutil.rmtree(app)
PYBUILD
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
for resource in "$bin_dir"/*.bundle; do
    [ -d "$resource" ] || continue
    ditto "$resource" "$app/Contents/Resources/$(basename "$resource")"
done
python3 - "$app/Contents/Resources/ControllerBridge" <<'PYCONTROLLER'
import pathlib,shutil,sys
source=pathlib.Path('../controller')
destination=pathlib.Path(sys.argv[1])
shutil.copytree(source,destination,ignore=shutil.ignore_patterns('__pycache__','*.pyc','test_*.py','*.o','vgf-controller','test-protocol','test-auth','test-session','test-serial','sunshine'))
PYCONTROLLER
cp "$bin_dir/GameCapture" "$app/Contents/MacOS/GameCapture"
cp ../build/icons/icon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>GameCapture</string>
<key>CFBundleIdentifier</key><string>net.tarucy.videogamefilter.native</string>
<key>CFBundleName</key><string>switch-remote</string>
<key>CFBundleDisplayName</key><string>switch-remote</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSCameraUsageDescription</key><string>캡처카드에서 스위치 화면을 표시합니다.</string>
<key>NSMicrophoneUsageDescription</key><string>캡처카드에서 게임 소리를 받아 재생합니다.</string>
<key>NSBonjourServices</key><array><string>_vgf-controller._tcp</string></array>
<key>NSLocalNetworkUsageDescription</key><string>라즈베리파이 컨트롤러로 게임패드 입력을 보냅니다.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
identity="${CODE_SIGN_IDENTITY:-Developer ID Application: eunkyu lee (WBL49792F2)}"
codesign --force --sign "$identity" --options runtime --timestamp --entitlements "$PWD/Entitlements.plist" "$app"
codesign --verify --deep --strict "$app"
printf '\nBuilt: %s\n' "$app"
