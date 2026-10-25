# Sourced by startwm.sh in the -share image (needs $dnum and $S).
# Shares this session's display over VNC on 127.0.0.1:59<dnum>; xrdp's join<dnum>
# section connects there. VNC auth: first password = full control, second = view-only.
SHARE_PORT=$((5900 + dnum))
ctrl_pin=$(tr -dc 0-9 </dev/urandom | head -c 6)
view_pin=$(tr -dc 0-9 </dev/urandom | head -c 6)
printf '%s\n%s\n' "$ctrl_pin" "$view_pin" | vncpasswd -f > "$S/vncpasswd"
chmod 600 "$S/vncpasswd"

x0vncserver -display ":$dnum" -rfbport "$SHARE_PORT" -localhost \
  -SecurityTypes VncAuth -rfbauth "$S/vncpasswd" -AlwaysShared \
  > "$S/x0vncserver.log" 2>&1 &

export SHARE_INFO="$S/share.txt"
: > "$SHARE_INFO"
chmod 600 "$SHARE_INFO"   # holds the control PIN; other accounts may share this pod
cat > "$SHARE_INFO" <<SHARE
<b><big>分享這個 session（編號 ${dnum}）</big></b>

其他人用遠端桌面連線到同一台主機，出現 xrdp 登入畫面後：

    1. Session 選 <b>join${dnum}</b>（也可以按 ↓ 鍵切換）
    2. password 填 <b>${ctrl_pin}</b>（可以操作）
    　　　　　　或 <b>${view_pin}</b>（只能看）
    3. 按 OK

分享畫面前請先關閉這個視窗，以免觀看者看到操作 PIN。
之後按 <b>Ctrl+Alt+S</b> 可以再顯示一次。
SHARE
unset ctrl_pin view_pin
