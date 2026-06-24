#!/bin/bash
# popdict 打包脚本
#   bash build.sh            -> 用 adhoc 签名(自己这台 Mac 用,够了)
#   bash build.sh "证书名"   -> 用你在钥匙串里建的自签名证书(更新不丢权限)
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

APP="popdict.app"
BUNDLE_ID="com.yoryon.popdict"
MIN_OS="12.0"
SIGN_IDENTITY="${1:--}"   # 默认 "-" 即 adhoc

echo "==> 1/5 编译 universal 二进制 (arm64 + x86_64)"
swiftc main.swift -target arm64-apple-macos${MIN_OS}  -o /tmp/popdict_arm64 -swift-version 5 -framework AppKit -framework ApplicationServices -O
swiftc main.swift -target x86_64-apple-macos${MIN_OS} -o /tmp/popdict_x86   -swift-version 5 -framework AppKit -framework ApplicationServices -O
lipo -create -output /tmp/popdict_uni /tmp/popdict_arm64 /tmp/popdict_x86
echo "    架构: $(lipo -archs /tmp/popdict_uni)"

echo "==> 2/5 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp /tmp/popdict_uni "$APP/Contents/MacOS/popdict"
chmod +x "$APP/Contents/MacOS/popdict"
[ -f popdict.icns ] && cp popdict.icns "$APP/Contents/Resources/popdict.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>popdict</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>popdict</string>
    <key>CFBundleDisplayName</key><string>popdict 划词翻译</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>${MIN_OS}</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>popdict</string>
    $( [ -f popdict.icns ] && echo "<key>CFBundleIconFile</key><string>popdict.icns</string>" )
</dict>
</plist>
PLIST

echo "==> 3/5 签名 (identity: ${SIGN_IDENTITY})"
codesign --force --deep -s "${SIGN_IDENTITY}" "$APP"
codesign -dvv "$APP" 2>&1 | grep -E 'Identifier|Signature|TeamIdentifier' || true

echo "==> 4/5 制作 dmg"
DMGDIR="$(mktemp -d)"
cp -R "$APP" "$DMGDIR/"
ln -s /Applications "$DMGDIR/Applications"
cat > "$DMGDIR/安装说明.txt" <<'TXT'
popdict 划词翻译 —— 安装 3 步

1) 把左边的 popdict.app 拖到右边的「Applications」文件夹里。
2) 打开「应用程序」,右键点 popdict → 选「打开」→ 再点「打开」(只需这一次,绕过未知开发者拦截)。
   开起来后屏幕右上角菜单栏会出现 🌐 图标。
3) 首次会弹「辅助功能」授权:
   系统设置 → 隐私与安全性 → 辅助功能 → 把 popdict 的开关打开。
   (这是划词监听必需的权限,不开就不会冒泡。)

填 API Key:
   打开「终端」粘贴一行(把 sk-xxx 换成你的 DeepSeek key):
   mkdir -p ~/.config/popdict && echo 'sk-xxx' > ~/.config/popdict/deepseek_key

用法:任意 App 里选中一段文字 → 旁边冒出「🌐 翻译」→ 点它 → 出译文。
   中文→英文,其它语言→简体中文。

排查:菜单栏 🌐 → 看「辅助功能」「API Key」是否都打勾。
   日志在 ~/.config/popdict/popdict.log
TXT

rm -f popdict.dmg
hdiutil create -volname "popdict 划词翻译" -srcfolder "$DMGDIR" -ov -format UDZO popdict.dmg
rm -rf "$DMGDIR"

echo "==> 5/5 完成"
echo "    App: $HERE/$APP"
echo "    DMG: $HERE/popdict.dmg"
