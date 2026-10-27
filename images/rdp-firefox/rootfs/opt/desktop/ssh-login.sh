#!/bin/bash
# localhost:2210 with several accounts: ssh runs as webterm, which has no
# account on the target, so ask which account to log in as
set -u
target=$1
while :; do
  read -r -p "${target} 的帳號: " user || exit 0
  [[ $user =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$ ]] && break
  echo "帳號只能用英數字、_、.、-"
done
# webterm has no home directory; keep known_hosts in this tab's throwaway HOME
exec /usr/bin/myssh -o UserKnownHostsFile="$HOME/known_hosts" -l "$user" "$target"
