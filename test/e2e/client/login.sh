#!/bin/bash
# Logs in the way a Windows Remote Desktop user does: connect without credentials,
# fill in the xrdp login screen (Session = Xorg), then stay connected.
#   login.sh <host:port> <user> <password> <screenshot name> <X display>
# Clients run with --network host, which shares X's abstract sockets, so each needs its own display.
set -u
host=$1 user=$2 pass=$3 shot=$4
export DISPLAY=$5
Xvfb "$DISPLAY" -screen 0 1280x800x24 >/dev/null 2>&1 &
sleep 1
xfreerdp3 /v:"$host" /cert:ignore /size:1280x800 /u:"" /p:"" </dev/null >/out/"$shot".log 2>&1 &
sleep 10
# Field positions of the xrdp login screen at 1280x800
xdotool mousemove 680 415 click 1; xdotool type --delay 60 "$user"
xdotool mousemove 680 442 click 1; xdotool type --delay 60 "$pass"
xdotool key Return
sleep 25
xwd -root -silent | magick xwd:- /out/"$shot".png
sleep infinity
