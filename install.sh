#!/usr/bin/env bash
# rdp-firefox quick start for Kubernetes: one account, bigred / bigred.
#
#   curl -fsSL https://raw.githubusercontent.com/braveantony/rdp-firefox/main/install.sh | bash
#
# For several accounts or your own passwords, use the kustomize overlay in
# deploy/example instead (see README).
#
# Optional, mainly for testing:
#   RDP_FIREFOX_REF    branch or tag of github.com/braveantony/rdp-firefox to deploy (default: main)
#   RDP_FIREFOX_IMAGE  image to run instead of the one in deploy/base
#   RDP_FIREFOX_RAW    where to fetch deploy/base from (default: raw.githubusercontent.com)
#
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

  say "Fetching deploy/base ($ref)"
  mkdir -p "$tmp/base"
  local f
  for f in kustomization.yaml namespace.yaml deployment.yaml service.yaml; do
    curl -fsSL "$raw/deploy/base/$f" -o "$tmp/base/$f" || die "cannot download deploy/base/$f from $raw"
  done

  echo "bigred:bigred" > "$tmp/users.txt"
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

  # Each account list gets a new hashed Secret name; drop the old ones
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
  echo "  On the xrdp login screen keep Session = Xorg and log in as bigred / bigred."
  echo "  More accounts or other passwords: see deploy/example (kustomize) in the repo."
  echo "  Uninstall: kubectl delete namespace $ns"
}

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

main "$@"
