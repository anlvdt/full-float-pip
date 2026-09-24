#!/bin/bash
# install.sh — Float Video one-click install script
# Compile Swift native app and configure Chrome Native Messaging

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
NATIVE_APP_DIR="$PROJECT_DIR/native-app"

echo ""
echo "Float Video — Installer"
echo "=========================="
echo ""

# ---- Step 1: Compile Swift app ----
echo "[1/4] Compiling native app..."
cd "$NATIVE_APP_DIR"
swift build -c release 2>&1 | tail -5

BUILD_OUTPUT="$NATIVE_APP_DIR/.build/release/FloatVideo"
if [ ! -f "$BUILD_OUTPUT" ]; then
    echo "Compilation failed! Please check if Xcode Command Line Tools are installed."
    echo "   Run: xcode-select --install"
    exit 1
fi
echo "Compilation successful"

# ---- Step 2: Install executable ----
echo ""
echo "[2/4] Installing executable..."
INSTALL_DIR="$HOME/Library/Application Support/FloatVideo"
mkdir -p "$INSTALL_DIR"
APP_MACOS="$INSTALL_DIR/VibeFloat.app/Contents/MacOS"
mkdir -p "$APP_MACOS"
cp "$BUILD_OUTPUT" "$APP_MACOS/FloatVideo"
cp "$PROJECT_DIR/native-app/Support/Info.plist" "$INSTALL_DIR/VibeFloat.app/Contents/Info.plist"
chmod +x "$APP_MACOS/FloatVideo"
# Launch path must be inside the .app so speech-recognition permission can attach.
ln -sfn "VibeFloat.app/Contents/MacOS/FloatVideo" "$INSTALL_DIR/FloatVideo"
xattr -cr "$INSTALL_DIR/VibeFloat.app" 2>/dev/null || true
codesign --force --sign - --identifier "com.aspect.floatvideo" --timestamp=none "$INSTALL_DIR/VibeFloat.app" 2>/dev/null \
  || codesign --force --sign - "$APP_MACOS/FloatVideo"
echo "Installed and signed: $APP_MACOS/FloatVideo"

# ---- Step 3: Create Native Messaging Host wrapper script ----
echo ""
echo "[3/4] Configuring Native Messaging..."

cat > "$INSTALL_DIR/float_video_host.sh" << HOSTEOF
#!/bin/bash
LOG_DIR="\$HOME/Library/Logs/FloatVideo"
LOG_FILE="\$LOG_DIR/native-host.log"
mkdir -p "\$LOG_DIR"
printf '\n[%s] starting native host pid=%s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$\$" >> "\$LOG_FILE"
exec "$INSTALL_DIR/VibeFloat.app/Contents/MacOS/FloatVideo" --native-messaging 2>>"\$LOG_FILE"
HOSTEOF
chmod +x "$INSTALL_DIR/float_video_host.sh"

# ---- Step 4: Configure Chrome Native Messaging Host ----
NATIVE_HOST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
mkdir -p "$NATIVE_HOST_DIR"

# Get Extension ID
echo ""
echo "[4/4] Configuring extension association..."
echo ""
echo "  Please install the Chrome extension first:"
echo "  1. Open Chrome -> chrome://extensions"
echo "  2. Enable 'Developer mode'"
echo "  3. Click 'Load unpacked'"
echo "  4. Select: $PROJECT_DIR/extension"
echo "  5. Copy the Extension ID (e.g.: abcdefghijklmnopqrstuvwxyz)"
echo ""
read -p "  Enter Chrome Extension ID: " EXT_ID

if [ -z "$EXT_ID" ]; then
    echo ""
    echo "  Extension ID is empty, using wildcard (for development only)"
    echo "  Please re-run this script to configure properly"
    EXT_ID="*"
fi

cat > "$NATIVE_HOST_DIR/com.aspect.floatvideo.json" << EOF
{
  "name": "com.aspect.floatvideo",
  "description": "Float Video native messaging host",
  "path": "$INSTALL_DIR/float_video_host.sh",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://$EXT_ID/"
  ]
}
EOF

echo ""
echo "================================="
echo "Installation complete!"
echo "================================="
echo ""
echo "  Native app: $INSTALL_DIR/FloatVideo"
echo "  Messaging manifest: $NATIVE_HOST_DIR/com.aspect.floatvideo.json"
echo "  Host stderr log: $HOME/Library/Logs/FloatVideo/native-host.log"
echo "  Chrome extension: $PROJECT_DIR/extension"
echo ""
echo "  Usage:"
echo "  1. Open any video site (YouTube, Bilibili, etc.)"
echo "  2. Click the Float Video icon in Chrome toolbar"
echo "  3. Select a video and click 'Float'"
echo "  4. The video will play in a floating window, always on top"
echo ""
echo "  Shortcuts:"
echo "  ESC — Close floating window"
echo "  Drag title bar — Move window"
echo "  Click yellow button — Toggle opacity"
echo ""
