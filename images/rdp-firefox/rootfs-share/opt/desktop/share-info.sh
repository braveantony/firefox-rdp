#!/bin/bash
# Show this session's share PINs (written by session-share.sh); bound to Ctrl+Alt+S
[ -r "${SHARE_INFO:-}" ] || exit 0
exec yad --title="分享這個 session" --text="$(cat "$SHARE_INFO")" \
  --button="關閉:0" --center --borders=16 --fixed
