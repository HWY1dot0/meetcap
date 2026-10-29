#!/bin/zsh
# 编译 MeetCap.swift 并打包成 ~/Applications/MeetCap.app
set -e
cd "$(dirname "$0")"

# 自己用可 export MEETCAP_BUNDLE_ID=com.<你的名字>.meetcap; 改了 ID 要重新授权麦克风/系统录音
BUNDLE_ID="${MEETCAP_BUNDLE_ID:-com.example.meetcap}"

# audiotap 不进仓库, 源码比二进制新(或缺失)时重编
if [[ audiotap.swift -nt audiotap ]]; then
    swiftc -O audiotap.swift -o audiotap
fi
swiftc -O -parse-as-library MeetCap.swift -o MeetCap

APP=~/Applications/MeetCap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mv MeetCap "$APP/Contents/MacOS/MeetCap"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MeetCap</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>MeetCap</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>录制会议时需要麦克风收取你自己的发言。</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>录制会议时需要抓取系统音频(会议对方的声音)。</string>
</dict>
</plist>
EOF

# 让 app 找到本仓库里的管线脚本(仓库挪了位置就重跑本脚本)
plutil -insert MeetCapScript -string "$PWD/meeting_recorder.py" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"
echo "打包完成: $APP"
