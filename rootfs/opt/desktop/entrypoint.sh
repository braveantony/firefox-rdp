#!/bin/bash
# Started by tini as root: xrdp-sesman needs root for PAM and to switch to the login user.
# The xrdp listener itself drops to the xrdp user (runtime_user in xrdp.ini).
set -eu
RDP_USER="${RDP_USER:-bigred}"
MAX_SESSIONS="${MAX_SESSIONS:-4}"
SSH_TARGET="${SSH_TARGET:-tkadm.taroko}"
: "${RDP_PASSWORD:?RDP_PASSWORD must be set (from a Secret)}"

case "$RDP_USER" in
  root|xrdp) echo "[entrypoint] RDP_USER must not be $RDP_USER" >&2; exit 1 ;;
esac
if ! echo "$RDP_USER" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'; then
  echo "[entrypoint] invalid RDP_USER: $RDP_USER" >&2
  exit 1
fi

# Login user with a fixed UID; home is populated from /etc/skel (openbox config)
id "$RDP_USER" >/dev/null 2>&1 || adduser -D -u 1000 -s /bin/bash "$RDP_USER"
echo "${RDP_USER}:${RDP_PASSWORD}" | chpasswd
unset RDP_PASSWORD

# Per-pod TLS certificate and RDP RSA keys (the Dockerfile removes the ones
# apk generated at build time); readable by the unprivileged xrdp listener
cd /etc/xrdp
if [ ! -s key.pem ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$(hostname)" \
    -keyout key.pem -out cert.pem 2>/dev/null
fi
[ -s rsakeys.ini ] || xrdp-keygen xrdp rsakeys.ini >/dev/null
chown root:xrdp key.pem cert.pem rsakeys.ini
chmod 640 key.pem cert.pem rsakeys.ini
cd /

rm -rf /run/xrdp/*.pid /tmp/.X*-lock /tmp/.X11-unix/X* /tmp/sess /tmp/term.*

# Per-session homes live under /tmp/sess (see startwm.sh)
install -d -m 700 -o "$RDP_USER" -g "$RDP_USER" /tmp/sess
case "$MAX_SESSIONS" in
  ''|*[!0-9]*) echo "[entrypoint] invalid MAX_SESSIONS: $MAX_SESSIONS" >&2; exit 1 ;;
esac
sed -i "s/^MaxSessions=.*/MaxSessions=${MAX_SESSIONS}/" /etc/xrdp/sesman.ini

xrdp-sesman --nodaemon &
xrdp --nodaemon &

# Web terminals: loopback only, run as RDP_USER, one process per browser tab.
# -O rejects WebSocket connections from other origins (web pages in Firefox).
uid=$(id -u "$RDP_USER")
gid=$(id -g "$RDP_USER")
ttyd -W -O -i lo -u "$uid" -g "$gid" -p 2200 -t fontSize=14 -t scrollback=10000 \
  /opt/desktop/term.sh bash -l &
ttyd -W -O -i lo -u "$uid" -g "$gid" -p 2210 -t fontSize=14 -t scrollback=10000 \
  -t 'theme={"foreground":"#ffffff","background":"#000000"}' \
  /opt/desktop/term.sh /usr/bin/myssh "$SSH_TARGET" &

# Any daemon exiting stops the container so K8s restarts it
wait -n
echo "[entrypoint] a service exited, stopping container" >&2
exit 1
