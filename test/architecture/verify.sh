#!/bin/bash
# Checks docs/architecture.md against a running deployment: the current kubectl
# context, namespace $NAMESPACE. Each section below is named after the section of
# architecture.md it covers.
#
#   test/architecture/verify.sh [--login USER] [--destructive]
#
# Default: does not change the deployment. Reads settings and state, opens one Web
# terminal tab for a few seconds, and starts one short-lived Pod (deleted afterwards)
# that tries ports 3389, 2200 and 2210 from outside the rdp-firefox Pod.
#   --login USER   also log in over RDP twice as USER with the test client from
#                  test/e2e/client (needs podman), check what starts at login, then
#                  disconnect and check that both desktops are removed after 2 minutes
#                  (adds about 3 minutes, uses 2 of the MAX_SESSIONS desktops). The
#                  password comes from $RDP_PASSWORD, or is asked for; it is passed to
#                  the client on stdin, never on a command line.
#   --destructive  also stop the :2210 ttyd and check that Kubernetes restarts the
#                  container; this closes every desktop in the Pod
#
# Needs kubectl, and a connection from this computer to the nodes (NodePort 30389).
# Settings (environment variables):
#   NAMESPACE     namespace of the deployment (default web-workspace)
#   RDP_HOST      host:port the --login client connects to (default: first node, port 30389)
#   RDP_PASSWORD  password for --login (default: ask)
# Prints PASS, FAIL or SKIP (does not apply here) per check; exits 1 if any check fails.
# --login client logs and screenshots go to test/architecture/out/.
set -u

root=$(cd "$(dirname "$0")/../.." && pwd)
out=$root/test/architecture/out
doc=$root/docs/architecture.md
ns=${NAMESPACE:-web-workspace}
client=localhost/rdp-firefox-e2e-client:latest
# Unique per run, so two runs (or test/e2e) never touch each other's Pods, containers
# or X displays
probe=verify-arch-probe-$$
clients="verify-arch-$$-a verify-arch-$$-b"
xdisp=$((200 + $$ % 50 * 2))

login="" destructive=0
while [ $# -gt 0 ]; do
  case $1 in
    --login) [ $# -ge 2 ] && [ -n "$2" ] || { echo "--login needs USER" >&2; exit 2; }; login=$2; shift 2 ;;
    --destructive) destructive=1; shift ;;
    -h|--help) sed -n '2,/^set -u/{/^set -u/d; s/^# \{0,1\}//; p}' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done
if [ -n "$login" ]; then
  case $login in *:*) echo "--login takes only USER; set RDP_PASSWORD or type it when asked" >&2; exit 2 ;; esac
  pw=${RDP_PASSWORD:-}
  if [ -z "$pw" ]; then
    [ -t 0 ] || { echo "--login: set RDP_PASSWORD (no terminal to ask on)" >&2; exit 2; }
    read -rsp "Password for $login: " pw; echo
  fi
  unset RDP_PASSWORD
fi

fail=0
pass() { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fail=1; }
skip() { printf 'SKIP  %s\n' "$*"; }
say()  { printf '\n==> %s\n' "$*"; }
eq()   { if [ "$2" = "$3" ]; then pass "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
ok()   { local msg=$1; shift; if "$@" >/dev/null 2>&1; then pass "$msg"; else bad "$msg"; fi; }

cleanup() {
  [ -z "${bg:-}" ] || kill $bg 2>/dev/null
  podman rm -f -t 0 $clients >/dev/null 2>&1
  kubectl -n "$ns" delete pod "$probe" --ignore-not-found --now --wait=false >/dev/null 2>&1
}
trap cleanup EXIT
trap 'exit 130' INT TERM

k()  { kubectl -n "$ns" "$@"; }
kx() { kubectl -n "$ns" exec "$pod" -c desktop -- "$@"; }
podjp() { k get pod "$pod" -o jsonpath="$1"; }
restarts() { podjp '{.status.containerStatuses[0].restartCount}'; }
pstree() { kx ps -o pid,ppid,user,args; }
listening() { kx netstat -ltn | awk 'NR > 2 {print $4}'; }
# loop_listen <port>: something listens on the port, and only on loopback
loop_listen() {
  local l; l=$(listening | grep -E "[:.]$1\$")
  [ -n "$l" ] && ! grep -vqE '^(127\.0\.0\.1|::1):' <<<"$l"
}
field() { awk -v n="$1" '{print $n}' <<<"$2"; }
# proc <ps output> <ppid or -> <regex>: "pid ppid user" of the first process whose
# command line matches the (extended) regex and whose parent is ppid
proc() {
  pp=$2 re=$3 awk 'NR > 1 { a = $0; sub(/^ *[0-9]+ +[0-9]+ +[^ ]+ +/, "", a)
    if ((ENVIRON["pp"] == "-" || $2 == ENVIRON["pp"]) && a ~ ENVIRON["re"]) { print $1, $2, $3; exit } }' <<<"$1"
}
# nproc <ps output> <ppid> <regex>: how many children of ppid match
nproc() {
  pp=$2 re=$3 awk 'NR > 1 { a = $0; sub(/^ *[0-9]+ +[0-9]+ +[^ ]+ +/, "", a)
    if ($2 == ENVIRON["pp"] && a ~ ENVIRON["re"]) n++ } END { print n + 0 }' <<<"$1"
}
args() { awk -v p="$2" 'NR > 1 && $1 == p { sub(/^ *[0-9]+ +[0-9]+ +[^ ]+ +/, ""); print }' <<<"$1"; }
parent() { awk -v p="$2" 'NR > 1 && $1 == p {print $2}' <<<"$1"; }
# startwm <ps output> <display>: PID of the startwm.sh of that desktop
startwm() { field 1 "$(proc "$1" "$(field 2 "$(proc "$1" - "^/usr/libexec/Xorg :$2 ")")" '/etc/xrdp/startwm[.]sh$')"; }
firefox() { field 1 "$(proc "$1" "$(startwm "$1" "$2")" '^/usr/lib/firefox/firefox --new-instance')"; }
# Display numbers of the running Xorg servers
displays() { kx ps -o args | sed -n 's|^/usr/libexec/Xorg :\([0-9]*\) .*|\1|p' | sort -n | tr '\n' ' '; }
# WebSocket handshake to ttyd (printf format: port, origin)
hs='GET /ws HTTP/1.1\r\nHost: localhost:%s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: tty\r\nOrigin: %s\r\n\r\n'
# ws <port> <origin>: handshake from inside the Pod; prints ttyd's status line
# (empty when ttyd closes the connection without answering)
ws() {
  kx sh -c 'printf "$1" "$2" "$3" | nc -w 1 127.0.0.1 "$2" | sed -n "1s/\r//p"' sh "$hs" "$@"
}
# tab_home <port>: opens a terminal tab (the handshake, then ttyd's first message, the
# terminal size, then the keys "echo HOME=$HOME.", each one WebSocket text frame with
# an all-zero mask), prints the HOME the shell reports and whether it still exists
# while the tab is open and after it closes
tab_home() {
  kx sh -c 'f=/tmp/verify-ws.$$
    { printf "$1" "$2" "http://localhost:$2"; sleep 1
      printf "\201\230\000\000\000\000{\"columns\":80,\"rows\":24}"; sleep 1
      printf "\201\222\000\000\000\000\060echo HOME=\$HOME.\n"; sleep 3; } |
      nc -w 5 127.0.0.1 "$2" > $f &
    sleep 4
    # LC_ALL=C: the frame headers between the text are not valid UTF-8
    h=$(LC_ALL=C sed -n "s|.*HOME=\(/tmp/term[.][A-Za-z0-9]*\)[.].*|\1|p" $f | head -1)
    test -n "$h" && test -d "$h" && open=yes || open=no
    wait; sleep 1; rm -f $f
    test -n "$h" && test ! -e "$h" && gone=yes || gone=no
    echo "${h:-none} $open $gone"' sh "$hs" "$1"
}
# tab_homes <port>: like tab_home for terminals that cannot run commands before a login
# (several accounts); prints how many throwaway homes exist before, during and after
tab_homes() {
  kx sh -c 'n() { ls -d /tmp/term.* 2>/dev/null | wc -l; }
    b=$(n)
    { printf "$1" "$2" "http://localhost:$2"; sleep 1
      printf "\201\230\000\000\000\000{\"columns\":80,\"rows\":24}"; sleep 4; } |
      nc -w 5 127.0.0.1 "$2" >/dev/null &
    sleep 3; d=$(n); wait; sleep 1
    echo $b $d $(n)' sh "$hs" "$1"
}

say "Deployment: context $(kubectl config current-context), namespace $ns"
pod=$(k get pod -l app=firefox-rdp --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$pod" ] || { bad "a running firefox-rdp Pod in $ns"; exit 1; }
echo "Pod: $pod"
node_ips=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
ps_all=$(pstree)

say "architecture.md: 連線路徑"
eq "Service firefox-rdp is a NodePort: 30389 -> port 3389 -> container port rdp" \
  "$(k get svc firefox-rdp -o jsonpath='{.spec.type} {.spec.ports[*].nodePort} {.spec.ports[*].port} {.spec.ports[*].targetPort}')" \
  "NodePort 30389 3389 rdp"
eq "container port rdp is 3389" \
  "$(podjp '{.spec.containers[0].ports[?(@.name=="rdp")].containerPort}')" 3389
eq "the Service sends connections to this Pod, which is ready" \
  "$(k get endpointslice -l kubernetes.io/service-name=firefox-rdp -o jsonpath='{range .items[*].endpoints[*]}{.addresses[*]} {.conditions.ready}{end}')" \
  "$(podjp '{.status.podIP}') true"
eq "any node forwards to the Pod, even one it does not run on (externalTrafficPolicy=Cluster)" \
  "$(k get svc firefox-rdp -o jsonpath='{.spec.externalTrafficPolicy}')" Cluster
for ip in $node_ips; do
  ok "NodePort 30389 answers on node $ip" timeout 3 bash -c "exec 3<>/dev/tcp/$ip/30389"
done

say "architecture.md: Pod 內部"
eq "the Pod has one container, desktop" \
  "$(podjp '{.spec.initContainers[*].name}|{.spec.containers[*].name}')" "|desktop"
eq "the image is the one architecture.md is written for" \
  "$(podjp '{.spec.containers[0].image}')" "$(sed -n 's/^適用映像檔：`\(.*\)`$/\1/p' "$doc")"
eq "PID 1 is tini running entrypoint.sh" \
  "$(field 1 "$(proc "$ps_all" 0 '^/sbin/tini -- /opt/desktop/entrypoint[.]sh$')")" 1
ep=$(field 1 "$(proc "$ps_all" 1 '/opt/desktop/entrypoint[.]sh$')")
sesman=$(field 1 "$(proc "$ps_all" "$ep" '^xrdp-sesman ')")

# Accounts from the users file; ④ and ⑤ depend on how many there are
names=$(kx sh -c "grep -vE '^[[:space:]]*(#|\$)' /etc/firefox-rdp/users | cut -d: -f1")
set -- $names
naccounts=$#
target=$(podjp '{.spec.containers[0].env[?(@.name=="SSH_TARGET")].value}')
target=${target:-tkadm.taroko}
t_re=${target//./[.]}
if [ "$naccounts" -eq 1 ]; then
  bash_re=' -p 2200 /opt/desktop/term[.]sh bash -l$'   bash_user=$1
  ssh_re=" -p 2210 .*/opt/desktop/term[.]sh /usr/bin/myssh $t_re\$" ssh_user=$1
  mode="one account ($1)"
else
  bash_re=' -p 2200 login$'   bash_user=root
  ssh_re=" -p 2210 .*/opt/desktop/term[.]sh /opt/desktop/ssh-login[.]sh $t_re\$" ssh_user=webterm
  mode="$naccounts accounts"
fi
# daemon <label> <regex> <user>: started by entrypoint.sh, running as user
daemon() {
  local p; p=$(proc "$ps_all" "$ep" "$2")
  if [ -z "$p" ]; then bad "$1 is started by entrypoint.sh"; return; fi
  eq "$1 is started by entrypoint.sh and runs as $3" "$(field 3 "$p")" "$3"
}
daemon "① xrdp-sesman" '^xrdp-sesman ' root
daemon "① xrdp" '^xrdp --nodaemon' xrdp
daemon "④ ttyd :2200 ($mode)" "^ttyd -W -O -i lo .*$bash_re" "$bash_user"
daemon "⑤ ttyd :2210 ($mode)" "^ttyd -W -O -i lo .*$ssh_re" "$ssh_user"

ini=$(kx grep -E '^(MaxSessions|Policy|KillDisconnected|DisconnectedTimeLimit)=' /etc/xrdp/sesman.ini)
val() { sed -n "s/^$1=//p" <<<"$ini"; }
max=$(podjp '{.spec.containers[0].env[?(@.name=="MAX_SESSIONS")].value}')
max=${max:-4}
eq "② at most MAX_SESSIONS desktops ($max)" "$(val MaxSessions)" "$max"
eq "② every Xorg login opens its own desktop (Policy=Separate)" "$(val Policy)" Separate
eq "② a disconnected desktop is removed after 2 minutes" \
  "$(val KillDisconnected) $(val DisconnectedTimeLimit)" "true 120"

xini=$(kx cat /etc/xrdp/xrdp.ini)
wrong=""
for n in 10 11 12 13 14 15 16 17 18 19; do
  sec=$(awk -v s="[join$n]" '$0 == s {f = 1; next} /^\[/ {f = 0} f' <<<"$xini")
  case $sec in *lib=libvnc.so*ip=127.0.0.1*port=59$n*) ;; *) wrong="$wrong join$n" ;; esac
done
eq "① join10..join19 connect over VNC to ③ on 127.0.0.1:5910..5919" "${wrong# }" ""

if [ "$naccounts" -eq 1 ]; then
  read -r h open gone <<<"$(tab_home 2200)"
  ok "④ a terminal tab gets a throwaway HOME ($h), deleted when the tab closes" \
    test "$open $gone" = "yes yes"
else
  read -r b d a <<<"$(tab_homes 2210)"
  ok "⑤ a terminal tab gets a throwaway HOME, deleted when the tab closes ($b -> $d -> $a)" \
    test "$d" = $((b + 1)) -a "$a" = "$b"
fi

say "architecture.md: 其他連線"
for p in 2200 2210; do
  ok "ttyd :$p listens on loopback only" loop_listen $p
  eq "ttyd :$p accepts a WebSocket from http://localhost:$p" \
    "$(ws $p "http://localhost:$p")" "HTTP/1.1 101 Switching Protocols"
  eq "ttyd :$p closes a WebSocket from another site without answering (-O)" \
    "$(ws $p http://evil.example)" ""
done
if [[ $target =~ ^tkadm(\.taroko(\.svc(\..*)?)?)?$ ]]; then
  eq "⑤ ssh to $target uses port 22100 (tkadm.conf)" \
    "$(kx ssh -G "$target" 2>/dev/null | sed -n 's/^port //p')" 22100
  eq "tkadm.conf is readable by every account (644)" \
    "$(kx stat -c %a /etc/ssh/ssh_config.d/tkadm.conf)" 644
  if kx nc -z -w 3 "$target" 22100 >/dev/null 2>&1; then
    pass "⑤ tkadm answers on $target:22100"
  else
    skip "⑤ $target:22100 does not answer (tkadm is deployed separately)"
  fi
else
  skip "⑤ SSH_TARGET is $target, not tkadm: the port 22100 checks do not apply"
fi
vol=$(podjp '{.spec.containers[0].volumeMounts[?(@.mountPath=="/etc/firefox-rdp")].name}')
secret=$(podjp "{.spec.volumes[?(@.name==\"$vol\")].secret.secretName}")
ok "the accounts come from Secret firefox-rdp-users-<hash> ($secret)" \
  grep -Eq '^firefox-rdp-users-[a-z0-9]+$' <<<"$secret"
ok "the Secret is mounted read-only at /etc/firefox-rdp (file users)" \
  kx sh -c 'test -r /etc/firefox-rdp/users && grep -q " /etc/firefox-rdp .*[ ,]ro[ ,]" /proc/mounts'
uid=1000
for u in $names; do
  eq "account $u has UID $uid" "$(kx id -u "$u")" $uid
  uid=$((uid + 1))
done

say "architecture.md: 安全邊界"
eq "no other Service in $ns selects the Pod" \
  "$(k get svc -o jsonpath='{range .items[?(@.spec.selector.app=="firefox-rdp")]}{.metadata.name} {.spec.type} {.spec.ports[*].nodePort};{end}')" \
  "firefox-rdp NodePort 30389;"
eq "no hostNetwork or hostPort" \
  "$(podjp '{.spec.hostNetwork}{.spec.containers[*].ports[*].hostPort}' | sed 's/^false//')" ""
eq "everything but 3389 listens on loopback only" \
  "$(listening | grep -vE '[:.]3389$' | grep -vE '^(127\.0\.0\.1|::1):' | tr '\n' ' ')" ""
# A throwaway Pod on the same node (the image is already there) tries the ports
probe_ok=0
k run "$probe" --image="$(podjp '{.spec.containers[0].image}')" --restart=Never \
  --labels=app=verify-arch-probe \
  --overrides="{\"spec\":{\"nodeName\":\"$(podjp '{.spec.nodeName}')\",\"activeDeadlineSeconds\":900}}" \
  --command -- sleep 900 >/dev/null &&
  k wait --for=condition=Ready "pod/$probe" --timeout=90s >/dev/null && probe_ok=1
pod_ip=$(podjp '{.status.podIP}')
reach() { [ "$probe_ok" = 1 ] && k exec "$probe" -- nc -z -w 3 "$pod_ip" "$1"; }
unreachable() { [ "$probe_ok" = 1 ] && ! reach "$1"; }
ok "another Pod reaches 3389 (control for the next checks)" reach 3389
for p in 2200 2210; do
  ok "another Pod cannot reach ttyd :$p" unreachable $p
done

# check_desktop <display> <user>: ② and ③ as started at login
check_desktop() {
  local d=$1 user=$2 ps_now x sx wm p
  ps_now=$(pstree)
  x=$(proc "$ps_now" - "^/usr/libexec/Xorg :$d ")
  sx=$(field 2 "$x")
  eq "desktop :$d: ② Xorg runs as $user, started by xrdp-sesman through xrdp-sesexec" \
    "$(field 3 "$x") $(args "$ps_now" "$sx") $(parent "$ps_now" "$sx")" "$user xrdp-sesexec $sesman"
  wm=$(proc "$ps_now" "$sx" '/etc/xrdp/startwm[.]sh$')
  eq "desktop :$d: the same xrdp-sesexec runs startwm.sh as $user" "$(field 3 "$wm")" "$user"
  wm=$(field 1 "$wm")
  # name|regex: startwm.sh starts exactly one of each, as the user
  for p in "③ x0vncserver|^x0vncserver -display :$d -rfbport $((5900 + d)) -localhost " \
           'openbox|^openbox$' 'fcitx5|^fcitx5$' 'Firefox|^/usr/lib/firefox/firefox --new-instance'; do
    eq "desktop :$d: startwm.sh starts one ${p%%|*}, as $user" \
      "$(nproc "$ps_now" "$wm" "${p#*|}") $(field 3 "$(proc "$ps_now" "$wm" "${p#*|}")")" "1 $user"
  done
  ok "desktop :$d: ③ VNC port $((5900 + d)) listens on loopback only" loop_listen $((5900 + d))
}

say "Desktops already open"
before=$(displays)
[ -n "$before" ] || skip "nobody is logged in (use --login to check ② and ③)"
for d in $before; do
  # The desktop's account, from its session directory /tmp/sess/<display>.<uid>
  u=$(kx sh -c "ls -d /tmp/sess/$d.* 2>/dev/null | sed 's/.*[.]//' | head -1")
  check_desktop "$d" "$(kx awk -F: -v u="$u" '$3 == u {print $1}' /etc/passwd)"
done

if [ -n "$login" ]; then
  say "Log in twice (--login)"
  set -- $before
  if ! command -v podman >/dev/null; then
    bad "--login needs podman"
  elif [ $(($# + 2)) -gt "$max" ]; then
    skip "--login needs 2 free desktops: $# of $max are in use"
  elif ! { podman image exists "$client" ||
           podman build -q -t "$client" "$root/test/e2e/client" >/dev/null; }; then
    bad "build the test client"
  else
    host=${RDP_HOST:-${node_ips%% *}:30389}
    mkdir -p "$out"
    rm -f "$out"/login-*
    # Like test/e2e/client/login.sh, but the password arrives on stdin
    bg="" n=0
    for c in $clients; do
      shot=login-${c##*-} n=$((n + 1))
      podman run -d --name "$c" --network host -v "$out:/out:Z" --entrypoint sleep "$client" infinity >/dev/null
      printf '%s\n' "$pw" | podman exec -i "$c" bash -c 'read -r pass
        export DISPLAY=$1
        Xvfb "$DISPLAY" -screen 0 1280x800x24 >/dev/null 2>&1 &
        sleep 1
        xfreerdp3 /v:"$2" /cert:ignore /size:1280x800 /u:"" /p:"" </dev/null >/out/"$4".log 2>&1 &
        sleep 10
        xdotool mousemove 680 415 click 1; xdotool type --delay 60 -- "$3"
        xdotool mousemove 680 442 click 1; xdotool type --delay 60 -- "$pass"; unset pass
        xdotool key Return
        sleep 25
        xwd -root -silent | magick xwd:- /out/"$4".png
        wait' sh ":$((xdisp + n))" "$host" "$login" "$shot" >/dev/null 2>&1 &
      bg="$bg $!"
    done
    # Wait until both new desktops run Firefox
    new=""
    for i in $(seq 1 30); do
      sleep 5
      new=$(for d in $(displays); do case " $before " in *" $d "*) ;; *) echo $d ;; esac; done | tr '\n' ' ')
      set -- $new
      [ $# -ge 2 ] || continue
      ps_now=$(pstree)
      [ -n "$(firefox "$ps_now" "$1")" ] && [ -n "$(firefox "$ps_now" "$2")" ] && break
    done
    set -- $new
    eq "logging in twice as $login opens two desktops" "$#" 2
    for d in $new; do check_desktop "$d" "$login"; done

    if [ $# -ge 1 ]; then
      d=$1
      ok "another Pod cannot reach ③ VNC :$((5900 + d)), which is listening" unreachable $((5900 + d))
      rc=$(restarts)
      ff=$(firefox "$(pstree)" "$d")
      kx kill "$ff"
      ff2=""
      for i in $(seq 1 10); do
        sleep 2
        ff2=$(firefox "$(pstree)" "$d")
        [ -n "$ff2" ] && [ "$ff2" != "$ff" ] && break
      done
      ok "closing Firefox on :$d reopens it in the same desktop" test -n "$ff2" -a "$ff2" != "$ff"
      eq "closing Firefox does not restart the container" "$(restarts)" "$rc"

      uid=$(kx id -u "$login")
      ok "the desktops keep their files under /tmp/sess/<display>.$uid" \
        kx sh -c "for d in $new; do test -d /tmp/sess/\$d.$uid || exit 1; done"
      # The client takes its screenshot about 35 seconds after starting
      for i in $(seq 1 12); do
        [ -s "$out/login-a.png" ] && [ -s "$out/login-b.png" ] && break
        sleep 5
      done
      ok "the clients saved screenshots (test/architecture/out/login-a.png, login-b.png)" \
        test -s "$out/login-a.png" -a -s "$out/login-b.png"
      say "Disconnect and wait for the desktops to be removed (about 2 minutes)"
      podman rm -f -t 0 $clients >/dev/null
      t0=$(date +%s) left=$new
      while [ -n "${left// /}" ] && [ $(( $(date +%s) - t0 )) -lt 180 ]; do
        sleep 5
        left=$(for d in $(displays); do case " $new " in *" $d "*) echo $d ;; esac; done | tr '\n' ' ')
      done
      el=$(( $(date +%s) - t0 ))
      ok "the desktops are removed 100-180 seconds after disconnecting (took ${el}s)" \
        test -z "${left// /}" -a "$el" -ge 100 -a "$el" -le 180
      ok "their files and VNC ports are gone" kx sh -c "for d in $new; do
        test ! -e /tmp/sess/\$d.$uid && ! netstat -ltn | grep -q \":59\$d \" || exit 1; done"
    fi
  fi
fi

if [ "$destructive" = 1 ]; then
  say "Container restart (--destructive)"
  echo "Stopping ttyd :2210 in $pod in 5 seconds; this closes every desktop (Ctrl+C to cancel)"
  sleep 5
  rc=$(restarts)
  kx kill "$(field 1 "$(proc "$(pstree)" "$ep" '^ttyd .* -p 2210 ')")"
  for i in $(seq 1 24); do
    sleep 5
    [ "$(restarts)" -gt "$rc" ] && [ "$(podjp '{.status.containerStatuses[0].ready}')" = true ] && break
  done
  eq "a ttyd exiting stops the container and Kubernetes restarts it" "$(restarts)" $((rc + 1))
  eq "the restarted container is ready again" "$(podjp '{.status.containerStatuses[0].ready}')" true
fi

say "Not checked here (check by hand)"
cat <<'EOF'
- join10..join19: the control PIN can operate the desktop, the view-only PIN can only watch
- what a Windows "Remote Desktop Connection" / Mac Windows App user sees after login
  (--login saves screenshots from the FreeRDP client in test/architecture/out/)
- ⑤ asks which account to use on the target (several accounts), and kubectl works on tkadm
- the tkadm kubeconfig never leaves the cluster
EOF

if [ "$fail" = 0 ]; then say "All checks passed"; else say "Some checks FAILED"; fi
exit $fail
