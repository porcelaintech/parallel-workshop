#!/bin/sh
set -eu
SOURCE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
INSTALL_ROOT="${BRAINTRUST_INSTALL_ROOT:-$HOME/Library/Application Support/Braintrust/service}"
mkdir -p "$INSTALL_ROOT"
ditto "$SOURCE_DIR" "$INSTALL_ROOT"
chmod +x "$INSTALL_ROOT/launchers/macos/launch.sh"
APP_DIR="${HOME}/Applications"
mkdir -p "$APP_DIR"
COMMAND="$APP_DIR/Braintrust.command"
cat > "$COMMAND" <<EOF
#!/bin/sh
exec "$INSTALL_ROOT/launchers/macos/launch.sh"
EOF
chmod +x "$COMMAND"
if [ -d "$HOME/Desktop" ]; then ln -sfn "$COMMAND" "$HOME/Desktop/智囊.command"; fi
echo "智囊服务已安装：$INSTALL_ROOT"
echo "以后双击 Applications/Braintrust.command 或桌面上的智囊.command 即可打开。"
