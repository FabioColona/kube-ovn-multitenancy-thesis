#!/bin/bash
# 20-paper-wall.sh — test "paper-wall": with Flannel a NetworkPolicy exists on paper but nothing enforces it.
#
# What it does : creates two tenants and a pod in the default namespace, then sends HTTP requests across them
#                in three rounds (no policy, default-deny, allow-list). With Flannel and the K3s policy
#                controller off, every request must pass, even with a default-deny in place. Also counts the
#                KUBE-NWPLCY rules of the K3s controller before and after applying a policy: must stay 0.
# Environment  : single-node K3s with Flannel (phase 10-install-flannel.sh)
# Changes      : CHANGES THE CLUSTER (creates and deletes the namespaces tenant-a, tenant-b and the pod default/app-default)
# Requires     : bash >= 4, kubectl, root or sudo (password asked once), Flannel cluster running, Internet to pull images
# Usage        : ./20-paper-wall.sh [--yes]      (CNI_OVERRIDE=flannel to skip the CNI detection)
# Variables    : REPETITIONS (from config.env), PROBE_TIMEOUT, MAX_STABLE_SECS
# Duration     : about 10 minutes for 5 repetitions
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Section 3.5 (test paper-wall)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
. "$HERE/lib-cni.sh"
parse_common_options "$@"
load_config "$HERE"
set -uo pipefail

need_sudo
have kubectl || die "kubectl not found: install the cluster first (10-install-flannel.sh)"
kubectl get nodes >/dev/null 2>&1 || die "the cluster does not answer: is K3s running? (export KUBECONFIG=/etc/rancher/k3s/k3s.yaml)"
CNI=$(detect_cni); info "CNI detected: $CNI"
[ "$CNI" = flannel ] || die "this test is for Flannel (detected: $CNI). For Calico or Cilium use 21-closed-door.sh"
confirm "This creates and deletes the namespaces tenant-a and tenant-b on this cluster. Continue?"

NWP_BEFORE=$(count_rules KUBE-NWPLCY); NWP_AFTER_POLICY=0
# Same timing as the control case (22-flannel-controller.sh): the rules are counted 5 s after the policy. If iptables
# cannot be read the value is BLOCKED and the check "= 0" fails instead of passing.
after_deny_hook() {
  local n; sleep 5; n=$(count_rules KUBE-NWPLCY)
  case "$n" in ""|*[!0-9]*) NWP_AFTER_POLICY=$n; return 0;; esac
  case "$NWP_AFTER_POLICY" in ""|*[!0-9]*) return 0;; esac
  [ "$n" -gt "$NWP_AFTER_POLICY" ] && NWP_AFTER_POLICY=$n; return 0
}

run_repetitions "$REPETITIONS"

sec "Results (CNI: flannel, $REPETITIONS repetitions)"
evaluate 0
expect "KUBE-NWPLCY rules before the test"        0 "$NWP_BEFORE"
expect "KUBE-NWPLCY rules after applying a policy" 0 "$NWP_AFTER_POLICY"
table
