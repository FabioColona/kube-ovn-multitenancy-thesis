#!/bin/bash
# 22-flannel-controller.sh — control case of test paper-wall: Flannel WITH the K3s NetworkPolicy controller enabled.
#
# What it does : same scenario and rounds as 20-paper-wall.sh (two tenants, no policy, default-deny, allow-list), on a
#                K3s installed with FLANNEL_POLICY=on. Expected: everything open without policies; with the default-deny
#                and the allow-list, the flows that must be blocked are REFUSED (curl exit 7), because the controller
#                rejects the packets with an ICMP port-unreachable instead of dropping them; the allowed ones stay open.
#                Also checks that the controller has written its KUBE-NWPLCY rules once a policy is applied.
# Environment  : single-node K3s with Flannel and the policy controller on (FLANNEL_POLICY=on ./10-install-flannel.sh)
# Changes      : CHANGES THE CLUSTER (creates and deletes the namespaces tenant-a, tenant-b and the pod default/app-default)
# Requires     : bash >= 4, kubectl, root or sudo (password asked once), Flannel cluster running, Internet to pull images
# Usage        : ./22-flannel-controller.sh [--yes]      (CNI_OVERRIDE=flannel to skip the CNI detection)
# Variables    : REPETITIONS (from config.env), PROBE_TIMEOUT, MAX_STABLE_SECS
# Duration     : about 10 minutes for 5 repetitions
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Section 3.5.1 (control case of test paper-wall)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
. "$HERE/lib-cni.sh"
parse_common_options "$@"
load_config "$HERE"
set -uo pipefail

need_sudo
have kubectl || die "kubectl not found: install the cluster first (FLANNEL_POLICY=on ./10-install-flannel.sh)"
kubectl get nodes >/dev/null 2>&1 || die "the cluster does not answer: is K3s running? (export KUBECONFIG=/etc/rancher/k3s/k3s.yaml)"
CNI=$(detect_cni); info "CNI detected: $CNI"
[ "$CNI" = flannel ] || die "this test is for Flannel (detected: $CNI)"
systemctl cat k3s 2>/dev/null | grep -q -- '--disable-network-policy' \
  && die "K3s runs with --disable-network-policy: reinstall with FLANNEL_POLICY=on ./10-install-flannel.sh (or use 20-paper-wall.sh)"
confirm "This creates and deletes the namespaces tenant-a and tenant-b on this cluster. Continue?"

NWP_BEFORE=$(count_rules KUBE-NWPLCY); NWP_AFTER_POLICY=0
info "KUBE-NWPLCY rules before the test: $NWP_BEFORE"
after_deny_hook() { local n; sleep 5; n=$(count_rules KUBE-NWPLCY); case "$n" in ""|*[!0-9]*) NWP_AFTER_POLICY=$n; return 0;; esac; [ "$NWP_AFTER_POLICY" -ge 0 ] 2>/dev/null || return 0; [ "$n" -gt "$NWP_AFTER_POLICY" ] && NWP_AFTER_POLICY=$n; return 0; }

run_repetitions "$REPETITIONS"

sec "Results (CNI: flannel with the K3s policy controller, $REPETITIONS repetitions)"
evaluate 2
record "KUBE-NWPLCY rules after applying a policy (controller active)" ">0" "$NWP_AFTER_POLICY" \
       "$([ "$NWP_AFTER_POLICY" -gt 0 ] 2>/dev/null && echo PASS || echo FAIL)"
info "REJECT rules of the controller (first 5):"
as_root iptables-save 2>/dev/null | grep -E 'KUBE-(NWPLCY|POD-FW).*-j REJECT' | head -5 | sed 's/^/    /'
table
