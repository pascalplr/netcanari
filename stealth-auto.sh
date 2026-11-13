#!/bin/sh
# macOS firewall stealth mode: off only on a trusted network, on everywhere else
# (and whenever in doubt).
# Recognising the network is delegated to canari (`--trusted`), which owns the list
# in ~/.config/canari/trusted. Without canari, stealth mode stays on.
#
# NetCanari runs this script itself each time the Mac moves between a trusted network
# and anywhere else; it can also be run by hand.
#
# Optional hooks, set in ~/.config/canari/config, run on every call:
#   ON_TRUSTED="command"     when the network is trusted (e.g. disconnect the VPN)
#   ON_UNTRUSTED="command"   everywhere else (e.g. connect the VPN)
ON_TRUSTED=""
ON_UNTRUSTED=""
[ -r "$HOME/.config/canari/config" ] && . "$HOME/.config/canari/config"
CANARI="$HOME/.local/bin/canari"
FW=/usr/libexec/ApplicationFirewall/socketfilterfw
LOG="$HOME/Library/Logs/stealth-auto.log"

# 0 = trusted network, 1 = not trusted, 2 = network not ready yet (wait ~10 s at most).
rc=1
i=0
while [ $i -lt 10 ]; do
  "$CANARI" --trusted 2>/dev/null; rc=$?
  [ $rc -eq 2 ] || break
  sleep 1; i=$((i+1))
done
want=on
trusted=no
[ $rc -eq 0 ] && { want=off; trusted=yes; }

case "$("$FW" --getstealthmode 2>/dev/null)" in
  *" on"*)  cur=on ;;
  *" off"*) cur=off ;;
  *)        cur=unknown ;;
esac

hook="$ON_UNTRUSTED"
[ "$trusted" = yes ] && hook="$ON_TRUSTED"

if [ "$1" = "--dry-run" ]; then
  echo "trusted network=$trusted current=$cur wanted=$want hook=${hook:-none}"
  exit 0
fi

status=0
if [ "$cur" != "$want" ]; then
  if sudo -n "$FW" --setstealthmode "$want" >/dev/null 2>&1; then
    res="ok"
  else
    res="FAILED (sudoers rule missing?)"
    status=1
  fi
  echo "$(date '+%F %T') trusted=$trusted stealth $cur -> $want: $res" >> "$LOG"
  [ $status -eq 0 ] || echo "stealth-auto: $res" >&2
fi

if [ -n "$hook" ]; then
  if sh -c "$hook" >/dev/null 2>&1; then res="ok"; else res="FAILED"; status=1; fi
  echo "$(date '+%F %T') trusted=$trusted hook: $res" >> "$LOG"
fi

# Ask the frame to re-evaluate right away.
pkill -USR1 -x canari 2>/dev/null
exit $status
