#!/bin/zsh
# 构建 + 签名 + 安装到 ~/Applications/拾藏.app
# 用法：scripts/build.sh [--open]     （--open：装好后立刻打开）
# 签名：钥匙串里有名为 $SHICANG_SIGN_ID（默认 "Shicang Local Signing"）的代码签名证书就用它（每次构建签名身份不变），
#       没有就用 ad-hoc 签名（-），本机自用一样能跑。
set -euo pipefail
ROOT=${0:A:h:h}
OPEN=${1:-}
cd $ROOT/App
/usr/bin/python3 $ROOT/scripts/make_icon.py >/dev/null
xcodegen generate --quiet
xcodebuild -project Shicang.xcodeproj -scheme Shicang -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath $ROOT/build/DerivedData CODE_SIGNING_ALLOWED=NO -quiet build 2>&1 | grep -v "^$" | grep -vE "appintentsmetadataprocessor|Metadata extraction skipped" || true
SRC=$ROOT/build/DerivedData/Build/Products/Release/Shicang.app
[[ -x $SRC/Contents/MacOS/Shicang ]] || { echo "构建失败：没有产物"; exit 1; }
STAGE=$ROOT/build/stage/拾藏.app
rm -rf $ROOT/build/stage; mkdir -p $ROOT/build/stage $ROOT/build/jobs
ditto $SRC $STAGE
DEST=$HOME/Applications/拾藏.app
SIGN_ID=${SHICANG_SIGN_ID:-Shicang Local Signing}
cat > $ROOT/build/jobs/install.sh <<JOB
set -e
SIGN="$SIGN_ID"
if ! security find-identity -p codesigning | grep -qF "\"\$SIGN\""; then
  echo "没找到签名证书「\$SIGN」，改用 ad-hoc 签名"; SIGN=-
fi
codesign --force --deep --sign "\$SIGN" --timestamp=none "$STAGE"
codesign --verify --strict --deep "$STAGE" && echo "签名校验 OK"
codesign -dv "$STAGE" 2>&1 | grep -E "^Identifier|^Authority|^CDHash"
# 关掉正在运行的旧版（只认 ~/Applications/拾藏.app 里的可执行文件，按 PID）
for pid in \$(pgrep -f "$DEST/Contents/MacOS/Shicang" || true); do kill \$pid; echo "已退出旧版 pid=\$pid"; done
for i in {1..40}; do pgrep -f "$DEST/Contents/MacOS/Shicang" >/dev/null || break; /bin/sleep 0.1; done
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$STAGE" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
echo "已安装 $DEST"
if [[ "$OPEN" == "--open" ]]; then /bin/sleep 0.3; open "$DEST" && echo "已打开"; fi
JOB
$ROOT/scripts/aqua-run.sh install $ROOT/build/jobs/install.sh 90
