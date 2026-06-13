#!/bin/bash
# Remove WifiAutoswitch: quit it, delete runtime data, and point out the bits
# macOS won't let a script remove (the Location grant and the signing cert).
set -euo pipefail

echo "Quitting WifiAutoswitch…"
pkill -f "WifiAutoswitch.app/Contents/MacOS/wifi-autoswitch" 2>/dev/null || true

SUPPORT="$HOME/Library/Application Support/wifi-hotspot-autoswitch"
if [ -d "$SUPPORT" ]; then
  rm -rf "$SUPPORT"
  echo "Removed config / state / log ($SUPPORT)."
fi

echo
echo "Manual cleanup (macOS protects these):"
echo "  • Delete the app:   rm -rf /Applications/WifiAutoswitch.app   (or the build/ copy)"
echo "  • Login item:       it unregisters when the app is gone; or toggle it off in the menu first."
echo "  • Location grant:   System Settings → Privacy & Security → Location Services → remove 'WifiAutoswitch'."
echo "  • Signing cert:     Keychain Access → login → delete 'WifiAutoswitch Self-Signed' (optional)."
