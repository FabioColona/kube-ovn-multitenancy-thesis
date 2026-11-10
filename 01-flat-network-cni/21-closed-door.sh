#!/bin/bash
# 21-closed-door.sh — test "closed-door": Calico and Cilium really enforce L3/L4 policies.
#
# What it does : same scenario as 20-paper-wall.sh (two tenants, three rounds: no policy, default-deny,
#                allow-list). Detects the CNI and data plane (calico, calico-ebpf, cilium-strict,
#                cilium-legacy). Expected: open without policy; with default-deny the flows into tenant-a are
#                blocked (curl exit 28); with the allow-list only tenant-b -> frontend-a passes.
# Environment  : single-node K3s with Calico or Cilium (phases 11-13)
# Changes      : CHANGES THE CLUSTER (creates and deletes the namespaces tenant-a, tenant-b and the pod default/app-default)
# Requires     : bash >= 4, kubectl, Calico or Cilium cluster running, Internet to pull images
# Usage        : ./21-closed-door.sh [--yes]      (CNI_OVERRIDE=<name> to skip the CNI detection)
# Variables    : REPETITIONS (from config.env), PROBE_TIMEOUT, MAX_STABLE_SECS
# Duration     : about 10 minutes for 5 repetitions
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Section 3.5 (test closed-door)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
. "$HERE/lib-cni.sh"
parse_common_options "$@"
load_config "$HERE"
set -uo pipefail

have kubectl || die "kubectl not found: install the cluster first (phases 11-13)"
kubectl get nodes >/dev/null 2>&1 || die "the cluster does not answer: is K3s running? (export KUBECONFIG=/etc/rancher/k3s/k3s.yaml)"
CNI=$(detect_cni); info "CNI detected: $CNI"
case "$CNI" in
  calico|calico-ebpf|cilium-strict|cilium-legacy) ;;
  flannel) die "Flannel enforces nothing: use 20-paper-wall.sh" ;;
  *) die "CNI not recognised: install one with phases 11-13, or set CNI_OVERRIDE" ;;
esac
confirm "This creates and deletes the namespaces tenant-a and tenant-b on this cluster. Continue?"

run_repetitions "$REPETITIONS"

sec "Results (CNI: $CNI, $REPETITIONS repetitions)"
evaluate 1
table
