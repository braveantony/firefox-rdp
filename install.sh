#!/usr/bin/env bash
# rdp-firefox installer for Kubernetes.
#
#   curl -fsSL https://raw.githubusercontent.com/braveantony/rdp-firefox/main/install.sh | bash
#
# Settings (environment variables, all optional):
#   RDP_USERS          accounts as "user:password", separated by spaces or newlines
#   RDP_USERS_FILE     a file with one "user:password" per line (# comments allowed)
#                      Neither set: creates "bigred" with a random password.
#   RDP_FIREFOX_REF    branch or tag of github.com/braveantony/rdp-firefox to deploy (default: main)
#   RDP_FIREFOX_IMAGE  image to run instead of the one in deploy/base
#   RDP_FIREFOX_RAW    where to fetch deploy/base from (default: raw.githubusercontent.com)
#
# Re-running with a different account list updates the Secret and restarts the pod.
# Uninstall: kubectl delete namespace web-workspace
set -euo pipefail

main() {
  local ref=${RDP_FIREFOX_REF:-main}
  local raw=${RDP_FIREFOX_RAW:-https://raw.githubusercontent.com/braveantony/rdp-firefox/$ref}
  local ns=web-workspace

  need kubectl
  need curl
  kubectl version --request-timeout=10s >/dev/null 2>&1 \
    || die "kubectl cannot reach a cluster; check your kubeconfig/context"

  # Global, not local: the EXIT trap runs after main has returned
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  umask 077

  say "Fetching deploy/base ($ref)"
  mkdir -p "$tmp/base"
  local f
  for f in kustomization.yaml namespace.yaml deployment.yaml service.yaml; do
    curl -fsSL "$raw/deploy/base/$f" -o "$tmp/base/$f" || die "cannot download deploy/base/$f from $raw"
  done

  # Account list -> users.txt (never echoed; passwords are printed only if generated here)
  local generated=""
  if [ -n "${RDP_USERS_FILE:-}" ]; then
    [ -r "$RDP_USERS_FILE" ] || die "cannot read RDP_USERS_FILE=$RDP_USERS_FILE"
    grep -vE '^[[:space:]]*(#|$)' "$RDP_USERS_FILE" > "$tmp/users.txt" || true
  elif [ -n "${RDP_USERS:-}" ]; then
    set -f   # split on whitespace only; never glob passwords like "pa*ss"
    printf '%s\n' $RDP_USERS > "$tmp/users.txt"
    set +f
  else
    generated=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)
    printf 'bigred:%s\n' "$generated" > "$tmp/users.txt"
  fi
  check_users "$tmp/users.txt"

  {
    echo "apiVersion: kustomize.config.k8s.io/v1beta1"
    echo "kind: Kustomization"
    echo "namespace: $ns"
    echo "resources:"
    echo "- base"
    echo "secretGenerator:"
    echo "- name: firefox-rdp-users"
    echo "  files:"
    echo "  - users=users.txt"
    if [ -n "${RDP_FIREFOX_IMAGE:-}" ]; then
      # A tag is the part after the last ":" only if it has no "/" (registry ports have one after them)
      local name=$RDP_FIREFOX_IMAGE tag=""
      case "${RDP_FIREFOX_IMAGE##*:}" in
        */*|"$RDP_FIREFOX_IMAGE") ;;
        *) name=${RDP_FIREFOX_IMAGE%:*}; tag=${RDP_FIREFOX_IMAGE##*:} ;;
      esac
      echo "images:"
      echo "- name: ghcr.io/braveantony/rdp-firefox"
      echo "  newName: $name"
      [ -z "$tag" ] || echo "  newTag: $tag"
    fi
  } > "$tmp/kustomization.yaml"

  say "Applying with kustomize"
  kubectl apply -k "$tmp"
  say "Waiting for the pod (the first image pull is about 1 GB)"
  kubectl -n "$ns" rollout status deploy/firefox-rdp --timeout=900s

  # Each account list gets a new hashed Secret name; drop the old ones (they hold old passwords)
  local cur s
  cur=$(kubectl -n "$ns" get deploy firefox-rdp \
    -o jsonpath='{.spec.template.spec.volumes[?(@.name=="users")].secret.secretName}')
  for s in $(kubectl -n "$ns" get secret -o name | grep '^secret/firefox-rdp-users-' || true); do
    [ "$s" = "secret/$cur" ] || kubectl -n "$ns" delete "$s"
  done

  local port ips
  port=$(kubectl -n "$ns" get svc firefox-rdp -o jsonpath='{.spec.ports[0].nodePort}')
  ips=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}')

  echo
  say "rdp-firefox is ready"
  echo "  Connect with Windows Remote Desktop (mstsc) to any node:"
  for f in $ips; do echo "    $f:$port"; done
  echo "  On the xrdp login screen keep Session = Xorg."
  echo "  Accounts: $(cut -d: -f1 "$tmp/users.txt" | paste -sd ' ')"
  if [ -n "$generated" ]; then
    echo "  Generated password for bigred: $generated"
  fi
  echo "  Uninstall: kubectl delete namespace $ns"
}

# Same rules the image enforces at startup, so mistakes fail before deploying
check_users() {
  local file=$1 user pass seen=" " count=0
  while IFS=: read -r user pass; do
    case "$user" in
      root|xrdp|webterm) die "account name not allowed: $user" ;;
    esac
    printf '%s' "$user" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' || die "invalid account name: '$user'"
    [ -n "$pass" ] || die "empty password for account: $user"
    case "$seen" in *" $user "*) die "duplicate account: $user" ;; esac
    seen="$seen$user "
    count=$((count + 1))
  done < "$file"
  [ "$count" -gt 0 ] || die "no accounts given"
}

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

main "$@"
