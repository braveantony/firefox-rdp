#!/bin/bash
# Started by tini as root: xrdp-sesman needs root for PAM and to switch to the login user.
# The xrdp listener itself drops to the xrdp user (runtime_user in xrdp.ini).
set -eu
USERS_FILE="${USERS_FILE:-/etc/firefox-rdp/users}"
MAX_SESSIONS="${MAX_SESSIONS:-4}"
SSH_TARGET="${SSH_TARGET:-tkadm.taroko}"

# Login accounts: one "user:password" per line in $USERS_FILE (mounted from a
# Secret; blank lines and # comments ignored), or a single RDP_USER/RDP_PASSWORD
accounts=$(mktemp)
trap 'rm -f "$accounts"' EXIT
if [ -s "$USERS_FILE" ]; then
  grep -vE '^[[:space:]]*(#|$)' "$USERS_FILE" > "$accounts" || true
else
  : "${RDP_PASSWORD:?set RDP_PASSWORD or mount a users file at $USERS_FILE}"
  printf '%s:%s\n' "${RDP_USER:-bigred}" "$RDP_PASSWORD" > "$accounts"
fi
unset RDP_PASSWORD

# Each account gets a fixed UID (1000, 1001, ...) and a home from /etc/skel
users=""
uid=1000
while IFS=: read -r user pass; do
  case "$user" in
    root|xrdp|webterm) echo "[entrypoint] account name not allowed: $user" >&2; exit 1 ;;
  esac
  if ! echo "$user" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'; then
    echo "[entrypoint] invalid account name: $user" >&2
    exit 1
  fi
  if [ -z "$pass" ]; then
    echo "[entrypoint] empty password for account: $user" >&2
    exit 1
  fi
  case " $users " in
    *" $user "*) echo "[entrypoint] duplicate account: $user" >&2; exit 1 ;;
  esac
  id "$user" >/dev/null 2>&1 || adduser -D -u "$uid" -s /bin/bash "$user"
  echo "${user}:${pass}" | chpasswd
  users="$users $user"
  uid=$((uid + 1))
done < "$accounts"
rm -f "$accounts"
set -- $users
if [ $# -eq 0 ]; then
  echo "[entrypoint] no accounts defined in $USERS_FILE" >&2
  exit 1
fi
echo "[entrypoint] accounts: $*"

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

# Per-session homes live under /tmp/sess (see startwm.sh); every account may
# create its own entries, the sticky bit keeps them from touching others'
install -d -m 1777 /tmp/sess
case "$MAX_SESSIONS" in
  ''|*[!0-9]*) echo "[entrypoint] invalid MAX_SESSIONS: $MAX_SESSIONS" >&2; exit 1 ;;
esac
sed -i "s/^MaxSessions=.*/MaxSessions=${MAX_SESSIONS}/" /etc/xrdp/sesman.ini

xrdp-sesman --nodaemon &
xrdp --nodaemon &

# Web terminals: loopback only, one process per browser tab.
# -O rejects WebSocket connections from other origins (web pages in Firefox).
TTYD_OPTS="-W -O -i lo -t fontSize=14 -t scrollback=10000"
SSH_THEME='theme={"foreground":"#ffffff","background":"#000000"}'
if [ $# -eq 1 ]; then
  # One account: both terminals open straight into that account
  uid=$(id -u "$1")
  gid=$(id -g "$1")
  ttyd $TTYD_OPTS -u "$uid" -g "$gid" -p 2200 /opt/desktop/term.sh bash -l &
  ttyd $TTYD_OPTS -u "$uid" -g "$gid" -p 2210 -t "$SSH_THEME" \
    /opt/desktop/term.sh /usr/bin/myssh "$SSH_TARGET" &
else
  # Several accounts share this pod: the bash terminal asks each tab to log in,
  # so nobody gets a shell as someone else; the SSH terminal only runs the ssh
  # client, as an unprivileged account without a password, and asks each tab
  # which account to use on the target
  id webterm >/dev/null 2>&1 || adduser -S -D -H -s /sbin/nologin webterm
  uid=$(id -u webterm)
  gid=$(id -g webterm)
  ttyd $TTYD_OPTS -p 2200 login &
  ttyd $TTYD_OPTS -u "$uid" -g "$gid" -p 2210 -t "$SSH_THEME" \
    /opt/desktop/term.sh /opt/desktop/ssh-login.sh "$SSH_TARGET" &
fi

# Any daemon exiting stops the container so K8s restarts it
wait -n
echo "[entrypoint] a service exited, stopping container" >&2
exit 1
