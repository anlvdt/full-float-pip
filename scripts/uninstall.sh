#!/bin/bash
# uninstall.sh — Float Video uninstall script

set -e

echo ""
echo "Float Video — Uninstaller"
echo "=========================="
echo ""

# Remove native app
INSTALL_DIR="$HOME/Library/Application Support/FloatVideo"
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    echo "Removed: $INSTALL_DIR"
else
    echo "Not found: $INSTALL_DIR (skipped)"
fi

# Remove Native Messaging Host manifest
NATIVE_HOST="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.aspect.floatvideo.json"
if [ -f "$NATIVE_HOST" ]; then
    rm "$NATIVE_HOST"
    echo "Removed: $NATIVE_HOST"
else
    echo "Not found: $NATIVE_HOST (skipped)"
fi

echo ""
echo "Uninstall complete!"
echo ""
echo "  Note: The Chrome extension must be removed manually at chrome://extensions"
echo ""
