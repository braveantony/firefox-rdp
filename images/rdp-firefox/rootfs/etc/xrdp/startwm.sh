#!/bin/bash
# Run by xrdp-sesman as the logged-in account for every RDP connection. sesman uses
# Policy=Separate, so each connection has its own display; this script gives
# it its own HOME, runtime dir and D-Bus so concurrent users of the same
# account never share a Firefox profile. Everything is removed on exit.
set -u
export LANG=zh_TW.UTF-8 LC_ALL=zh_TW.UTF-8 TZ=Asia/Taipei
export NO_AT_BRIDGE=1 GDK_BACKEND=x11 MOZ_ENABLE_WAYLAND=0
# Chinese input happens in the session (fcitx5 + chewing): xrdp drops the
# Unicode characters a client-side input method sends
export GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx XMODIFIERS=@im=fcitx

# sesman sets DISPLAY=:N.0; the socket is /tmp/.X11-unix/XN
dnum=${DISPLAY#*:}
dnum=${dnum%%.*}

# sesman wrote this display's cookie to the real home; keep using it
export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"

# Keyed by display and UID: a stale directory left by another account on the
# same display number (sticky /tmp/sess) can never block this session
S="/tmp/sess/$dnum.$(id -u)"
rm -rf "$S"
# Private to this account: it holds the share PINs, and other accounts may be
# logged in to the same pod (mkdir -p would leave $S itself world-readable)
umask 077
mkdir -m 700 "$S"
mkdir -m 700 "$S/home" "$S/run"
cp -R /etc/skel/. "$S/home"/
export HOME="$S/home" XDG_RUNTIME_DIR="$S/run"
cd "$HOME"

eval "$(dbus-launch --sh-syntax)"

cleanup() {
  kill "$DBUS_SESSION_BUS_PID" 2>/dev/null
  pkill -TERM -P $$ 2>/dev/null
  rm -rf "$S"
}
trap cleanup EXIT
trap 'exit 143' TERM HUP INT

# -share image only: share this session over VNC with control/view-only PINs
if [ -f /opt/desktop/session-share.sh ]; then
  . /opt/desktop/session-share.sh
fi

openbox &
# Started before Firefox so GTK finds it; Ctrl+Space or left Shift toggles 注音
fcitx5 >/dev/null 2>&1 &

if [ -n "${SHARE_INFO:-}" ]; then
  (sleep 2; /opt/desktop/share-info.sh) &
fi

# Reopen Firefox if the user closes it, until this session's X server is gone
while [ -S "/tmp/.X11-unix/X${dnum}" ]; do
  firefox --new-instance about:blank &
  wait $!
  sleep 1
done
