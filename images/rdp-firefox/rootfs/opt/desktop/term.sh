#!/bin/bash
# Spawned by ttyd (as the account or webterm) per browser connection: run the command with
# a throwaway HOME so terminals of different RDP users never share state
set -u
H=$(mktemp -d /tmp/term.XXXXXX)
trap 'rm -rf "$H"' EXIT
cp -R /etc/skel/. "$H"/
export HOME="$H" USER="$(id -un)" LOGNAME="$(id -un)"
cd "$H"
"$@"
