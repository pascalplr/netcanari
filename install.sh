#!/bin/sh
# Builds and installs NetCanari and stealth-auto.sh for the current user.
# Does not use sudo: the sudoers rule is prepared, installing it is up to you.
set -e
cd "$(dirname "$0")"
BIN="$HOME/.local/bin"
AGENT="$HOME/Library/LaunchAgents/local.canari.plist"
mkdir -p "$BIN" "$HOME/Library/LaunchAgents"

# NetCanari is an app (no Dock icon): macOS only gives the Wi-Fi name to an app
# that is allowed to read the location.
APP="$HOME/Applications/NetCanari.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The icons are embedded in the binary: *.svg -> IconData.swift (not versioned).
{
  printf 'let iconSVG = #"""\n'; cat icon.svg; printf '\n"""#\n'
  printf 'let iconAlertSVG = #"""\n'; cat icon-alert.svg; printf '\n"""#\n'
} > IconData.swift
swiftc -O main.swift IconData.swift -o "$APP/Contents/MacOS/canari"
cp Info.plist "$APP/Contents/Info.plist"

# App icon: rendered by the binary itself, so it keeps its transparent corners.
TMP=$(mktemp -d)
mkdir "$TMP/icon.iconset"
for sz in 16 32 128 256 512; do
  "$APP/Contents/MacOS/canari" --icon-png $sz "$TMP/icon.iconset/icon_${sz}x${sz}.png"
  "$APP/Contents/MacOS/canari" --icon-png $((sz*2)) "$TMP/icon.iconset/icon_${sz}x${sz}@2x.png"
done
iconutil -c icns "$TMP/icon.iconset" -o "$APP/Contents/Resources/icon.icns"
rm -rf "$TMP"

# Ad hoc signature. Do not sign with an "Apple Development" certificate: if it is
# revoked, macOS treats the app as malware and moves it to the Trash. The price:
# macOS may ask for location access again after a rebuild.
codesign --force --sign - "$APP"

# `canari` command: a link to the app's executable.
ln -sf "$APP/Contents/MacOS/canari" "$BIN/canari"
install -m 755 stealth-auto.sh "$BIN/stealth-auto.sh"
sed "s/__USER__/$(id -un)/" stealth-auto.sudoers.template > "$BIN/stealth-auto.sudoers"
visudo -cf "$BIN/stealth-auto.sudoers" >/dev/null

# The LaunchAgent is written by the program itself (same code as the menu option).
"$BIN/canari" --login on

# Restart: bootout is asynchronous, so wait until the old service is gone.
SVC="gui/$(id -u)/local.canari"
launchctl bootout "$SVC" 2>/dev/null || true
i=0
while launchctl print "$SVC" >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "Installed. State: $("$BIN/canari" --status)"
if [ ! -e /etc/sudoers.d/stealth-auto ]; then
  echo "One step left, once:"
  echo "  sudo install -m 0440 -o root -g wheel $BIN/stealth-auto.sudoers /etc/sudoers.d/stealth-auto"
fi
