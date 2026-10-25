#!/bin/bash
# End-to-end test on a throwaway kind cluster:
#   1. quick start: install.sh from this checkout, log in as bigred / bigred
#   2. multi-user:  kubectl apply -k manifests/multi-user, log in as alice and bob,
#                   and check that bigred is no longer accepted
# Logins go through the xrdp login screen with FreeRDP (see client/).
#
# Needs podman, kind and kubectl. Settings (environment variables):
#   E2E_IMAGE  image to test; default builds images/rdp-firefox (SESSION_SHARE=1) and loads it into kind
#   E2E_KEEP   1 keeps the cluster afterwards (default: delete it)
# Screenshots and client logs go to test/e2e/out/.
set -u

root=$(cd "$(dirname "$0")/../.." && pwd)
here=$root/test/e2e
out=$here/out
cluster=rdp-e2e
port=33389
client=localhost/rdp-firefox-e2e-client:latest
export KUBECONFIG=$here/out/kubeconfig
command -v docker >/dev/null || export KIND_EXPERIMENTAL_PROVIDER=podman

fail=0
pass() { printf 'PASS  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }
say() { printf '\n==> %s\n' "$*"; }

cleanup() {
  podman rm -f -t 0 e2e-bigred e2e-alice e2e-bob e2e-old >/dev/null 2>&1
  [ -z "${pf:-}" ] || kill "$pf" 2>/dev/null
  if [ "${E2E_KEEP:-0}" = 1 ]; then
    echo "cluster kept: KUBECONFIG=$KUBECONFIG kind delete cluster --name $cluster"
  else
    # kind's podman provider leaves the nodes' anonymous volumes (GBs each) behind
    local vols="" n
    for n in $(kind get nodes --name "$cluster" 2>/dev/null); do
      vols="$vols $(podman inspect "$n" --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' 2>/dev/null)"
    done
    kind delete cluster --name "$cluster" >/dev/null 2>&1
    [ -z "${vols// /}" ] || podman volume rm -f $vols >/dev/null 2>&1
  fi
}
trap cleanup EXIT

forward() {   # (re)start a port-forward to the Service on 127.0.0.1:$port
  [ -z "${pf:-}" ] || kill "$pf" 2>/dev/null
  kubectl -n web-workspace port-forward svc/firefox-rdp $port:3389 >/dev/null 2>&1 &
  pf=$!
  sleep 3
}

display=90
login() {     # login <name> <user> <password>
  display=$((display + 1))
  podman rm -f -t 0 "e2e-$1" >/dev/null 2>&1
  podman run -d --name "e2e-$1" --network host -v "$out:/out:Z" "$client" \
    127.0.0.1:$port "$2" "$3" "$1" ":$display" >/dev/null
}

xorg_users() {
  kubectl -n web-workspace exec deploy/firefox-rdp -- ps -o user,args \
    | awk '$2 ~ /Xorg$/ {print $1}' | sort | paste -sd ' '
}

expect_sessions() {   # expect_sessions "<sorted users>" <label>
  local got="" i
  for i in $(seq 30); do
    got=$(xorg_users)
    [ "$got" = "$1" ] && break
    sleep 2
  done
  if [ "$got" = "$1" ]; then pass "$2 (sessions: $got)"; else bad "$2 (expected: $1, got: ${got:-none})"; fi
}

mkdir -p "$out"
rm -f "$out"/*.png "$out"/*.log

say "Building the test client"
podman build -q -t "$client" "$here/client" >/dev/null || { bad "client image build"; exit 1; }

image=${E2E_IMAGE:-}
if [ -z "$image" ]; then
  say "Building images/rdp-firefox"
  image=localhost/alpine-firefox-rdp:e2e
  podman build -q --build-arg SESSION_SHARE=1 -t "$image" "$root/images/rdp-firefox" >/dev/null \
    || { bad "image build"; exit 1; }
fi

say "Creating kind cluster $cluster"
kind create cluster --name "$cluster" --kubeconfig "$KUBECONFIG" --config - <<'EOF' || { bad "kind create"; exit 1; }
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
EOF
if [ -z "${E2E_IMAGE:-}" ]; then
  podman save "$image" -o "$out/image.tar" && kind load image-archive "$out/image.tar" --name "$cluster"
  rm -f "$out/image.tar"
fi

say "1. Quick start (install.sh)"
if RDP_FIREFOX_RAW="file://$root" RDP_FIREFOX_IMAGE="$image" bash "$root/install.sh"; then
  pass "install.sh"
else
  bad "install.sh"; exit 1
fi
forward
login bigred bigred bigred
expect_sessions "bigred" "quick start: bigred / bigred logs in"
podman rm -f -t 0 e2e-bigred >/dev/null

say "2. Multi-user (manifests/multi-user)"
overlay=$out/overlay   # kustomize only accepts relative paths to a base
mkdir -p "$overlay"
cat > "$overlay/kustomization.yaml" <<EOF
resources:
- ../../../../manifests/multi-user
images:
- name: ghcr.io/braveantony/rdp-firefox
  newName: ${image%:*}
  newTag: ${image##*:}
EOF
kubectl apply -k "$overlay" && kubectl -n web-workspace rollout status deploy/firefox-rdp --timeout=600s \
  && pass "kubectl apply -k manifests/multi-user" || bad "kubectl apply -k manifests/multi-user"
rm -rf "$overlay"
forward
login alice alice ChangeMe-alice
login bob bob ChangeMe-bob
login old bigred bigred
expect_sessions "alice bob" "multi-user: alice and bob log in, bigred is rejected"

echo
if [ $fail = 0 ]; then echo "ALL PASSED"; else echo "SOME CHECKS FAILED (see $out)"; fi
exit $fail
