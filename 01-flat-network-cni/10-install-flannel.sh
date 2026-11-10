#!/bin/bash
# 10-install-flannel.sh — installs a single-node K3s with Flannel and NO policy controller (FLANNEL_POLICY=on: with it).
#
# What it does : installs K3s with its built-in Flannel and the K3s NetworkPolicy controller disabled
#                (--disable-network-policy): NetworkPolicy objects can be created but nothing enforces them.
#                Then checks node, Flannel and absence of enforcement rules.
# Environment  : any Linux machine (x86_64 or aarch64) with systemd and Internet access
# Changes      : CHANGES THE MACHINE (installs K3s, sets KUBECONFIG; refuses to run if K3s is already there)
# Requires     : bash >= 4, curl, root or sudo (the password is asked once), phase 00 without FAIL
# Usage        : ./10-install-flannel.sh [--yes]
# Variables    : K3S_VERSION, NODE_HOSTNAME (from config.env); FLANNEL_POLICY=on keeps the K3s policy controller
#                enabled (control case, test 22-flannel-controller.sh); default off
# Duration     : about 2 minutes
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing or installation failed
# In the thesis: Section 3.5 (test paper-wall, Flannel installation)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
set -uo pipefail

need_sudo
k3s_installed && die "K3s is already installed: run ./90-reset.sh first"
confirm "This installs K3s $K3S_VERSION with Flannel on $(hostname). Continue?"

if [ "${FLANNEL_POLICY:-off}" = on ]; then sec "Installing K3s $K3S_VERSION (Flannel, network policy controller ENABLED)"
else sec "Installing K3s $K3S_VERSION (Flannel, network policy controller disabled)"; fi
if [ -n "${NODE_HOSTNAME:-}" ]; then as_root hostnamectl set-hostname "$NODE_HOSTNAME"; fi
if [ "${FLANNEL_POLICY:-off}" = on ]; then install_k3s ""; else install_k3s "--disable-network-policy"; fi

sec "Waiting for the node"
wait_node_ready 300 && NODE=Ready || NODE=NotReady
kubectl get nodes -o wide

sec "Checks"
expect "node status"                      Ready "$NODE"
# Flannel is embedded in the k3s process (no pod). Its interface appears a few seconds AFTER the node is Ready.
if waitf 60 2 ip link show flannel.1; then
  record "Flannel interface" "flannel.1 present" "flannel.1 present" PASS
else
  record "Flannel interface" "flannel.1 present" "flannel.1 missing" FAIL
fi
# with the controller on, its rules appear only when there are pods and policies: 22-flannel-controller.sh checks them
if [ "${FLANNEL_POLICY:-off}" = on ]; then
  info "KUBE-NWPLCY rules (controller on, checked by 22-flannel-controller.sh): $(count_rules KUBE-NWPLCY)"
else
  expect "policy controller rules (KUBE-NWPLCY)" 0 "$(count_rules KUBE-NWPLCY)"
fi
echo "K3s: $(k3s --version | head -1)"
table
