#!/bin/bash
# 13-install-cilium.sh — installs a single-node K3s with Cilium, in strict or legacy mode.
#
# What it does : installs K3s without Flannel and policy controller, then the Cilium CLI and Cilium.
#                strict = Cilium replaces kube-proxy (K3s starts with --disable-kube-proxy);
#                legacy = kube-proxy is kept, Cilium only provides the network and the policies.
#                Checks node, Cilium status, kube-proxy replacement mode and the iptables rules.
# Environment  : Linux x86_64 or aarch64 with systemd and Internet access
# Changes      : CHANGES THE MACHINE (installs K3s, Cilium CLI and Cilium; refuses to run if K3s is already there)
# Requires     : bash >= 4, curl, tar, root or sudo (the password is asked once), phase 00 without FAIL
# Usage        : ./13-install-cilium.sh [strict|legacy] [--yes]       (default: CILIUM_MODE from config.env)
# Variables    : K3S_VERSION, CILIUM_VERSION, CILIUM_CLI_VERSION, CILIUM_MODE, CILIUM_KPR_STRICT, POD_CIDR
# Duration     : 5-15 minutes
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing or installation failed
# In the thesis: Section 3.5 (test closed-door, Cilium installation)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
ARGS=(); for a in "$@"; do case "$a" in strict|legacy) CILIUM_MODE_ARG=$a;; *) ARGS+=("$a");; esac; done
parse_common_options "${ARGS[@]+"${ARGS[@]}"}"
load_config "$HERE"
set -uo pipefail
MODE="${CILIUM_MODE_ARG:-${CILIUM_MODE:-strict}}"
case "$MODE" in strict|legacy) ;; *) die "mode must be strict or legacy (got '$MODE')";; esac

need_sudo
k3s_installed && die "K3s is already installed: run ./90-reset.sh first"
require_vars CILIUM_VERSION CILIUM_CLI_VERSION POD_CIDR
case "$(uname -m)" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) die "unsupported architecture $(uname -m)";; esac
confirm "This installs K3s $K3S_VERSION with Cilium $CILIUM_VERSION ($MODE mode) on $(hostname). Continue?"

EXTRA=""; KPR=disabled
if [ "$MODE" = strict ]; then EXTRA="--disable-kube-proxy"; KPR="${CILIUM_KPR_STRICT:-true}"; fi

sec "Installing K3s $K3S_VERSION (no Flannel, no policy controller, $MODE mode, pod CIDR $POD_CIDR)"
if [ -n "${NODE_HOSTNAME:-}" ]; then as_root hostnamectl set-hostname "$NODE_HOSTNAME"; fi
install_k3s "--flannel-backend=none --disable-network-policy $EXTRA --cluster-cidr=$POD_CIDR"
MY_IP=$(hostname -I | awk '{print $1}')
[ -n "$MY_IP" ] || die "cannot find the IP address of this machine"

sec "Installing the Cilium CLI $CILIUM_CLI_VERSION"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -sfL "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${ARCH}.tar.gz" -o "$TMP/cli.tgz" \
  || die "cannot download the Cilium CLI"
as_root tar xzf "$TMP/cli.tgz" -C /usr/local/bin cilium || die "cannot unpack the Cilium CLI"

sec "Installing Cilium $CILIUM_VERSION (kubeProxyReplacement=$KPR, API server $MY_IP:6443)"
cilium install --version "$CILIUM_VERSION" \
  --set operator.replicas=1 --set prometheus.enabled=false --set operator.prometheus.enabled=false \
  --set kubeProxyReplacement="$KPR" --set k8sServiceHost="$MY_IP" --set k8sServicePort=6443 \
  --set ipam.operator.clusterPoolIPv4PodCIDRList="$POD_CIDR" >/dev/null 2> >(grep -v -E 'memcache\.go|warnings\.go' >&2) \
  || die "cilium install failed"
cilium status --wait --wait-duration 8m >/dev/null 2>&1 && CIL=OK || CIL=NotOK

if [ "$MODE" = legacy ]; then
  # The CLI sees no kube-proxy pod (the K3s one is a process) and forces strict: set it back to disabled.
  sec "Legacy mode: switching kube-proxy replacement off"
  kubectl -n kube-system patch cm cilium-config --type merge -p '{"data":{"kube-proxy-replacement":"disabled"}}' >/dev/null
  kubectl -n kube-system rollout restart ds/cilium >/dev/null
  kubectl -n kube-system rollout status ds/cilium --timeout=240s >/dev/null
  sleep 15
  cilium status --wait --wait-duration 5m >/dev/null 2>&1 && CIL=OK || CIL=NotOK
fi
wait_node_ready 300 && NODE=Ready || NODE=NotReady
kubectl get nodes -o wide

sec "Checks"
expect "node status"   Ready "$NODE"
expect "Cilium status" OK    "$CIL"
GOT=$(kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.kube-proxy-replacement}' 2>/dev/null)
if [ "$MODE" = strict ]; then
  case "$GOT" in true|strict) GOT=strict;; esac
  expect "kube-proxy replacement" strict "$GOT"
  expect "kube-proxy rules (KUBE-SVC)" 0 "$(count_rules 'KUBE-SVC')"
else
  case "$GOT" in disabled|false) GOT=disabled;; esac
  expect "kube-proxy replacement" disabled "$GOT"
  [ "$(count_rules 'KUBE-SVC')" -gt 0 ] && R=yes || R=no
  expect "kube-proxy rules (KUBE-SVC) present" yes "$R"
fi
[ "$(count_rules 'CILIUM')" -gt 0 ] && R=yes || R=no
expect "Cilium iptables chains present" yes "$R"
echo "K3s: $(k3s --version | head -1)   Cilium: $CILIUM_VERSION   CLI: $(cilium version --client 2>/dev/null | head -1)"
table
