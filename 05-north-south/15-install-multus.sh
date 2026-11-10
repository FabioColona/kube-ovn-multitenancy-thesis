#!/bin/bash
# 15-install-multus.sh — installs Multus (thick) on the cluster of 20-install-cluster.sh.
#
# What it does : applies the Multus manifest of MULTUS_VERSION, waits for the DaemonSet on every node, checks that the CRD
#                NetworkAttachmentDefinition exists and that the CNI configuration of Kube-OVN is still the primary one.
#                Needed before 30-nat-gateway.sh (the external interface of the gateway is a macvlan attachment).
# Environment  : the cluster of 20-install-cluster.sh; the server needs Internet access (manifest and image)
# Changes      : CHANGES THE CLUSTER (adds the Multus DaemonSet and CRDs; nothing on the machines outside Kubernetes paths)
# Requires     : phase 20 done
# Usage        : ./15-install-multus.sh [--yes]
# Variables    : MULTUS_VERSION, MULTUS_MANIFEST (from config.env)
# Duration     : about 1-2 minutes
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 6 (north-south test bed; versions in the environment record)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
require_vars MULTUS_VERSION MULTUS_MANIFEST CHECK_IMAGE

sec "1. Before installing"
[ "$(rk "$SERVER" "kubectl get nodes --no-headers 2>/dev/null | wc -l" | tr -d ' ')" -ge 1 ] || die "no cluster: run ./20-install-cluster.sh first"
if [ "$(rk "$SERVER" "kubectl get crd network-attachment-definitions.k8s.cni.cncf.io -o name 2>/dev/null | wc -l" | tr -d ' ')" != 0 ]; then
  info "Multus is already installed: only the checks run"
else
  confirm "This installs Multus $MULTUS_VERSION in the cluster. Continue?"
  sec "2. Installing"
  rk "$SERVER" "kubectl apply -f $MULTUS_MANIFEST" 2>&1 | sed 's/^/  /'
  run_spin "waiting for the Multus DaemonSet" "up to 3 minutes" \
    rk "$SERVER" "kubectl -n kube-system rollout status ds/kube-multus-ds --timeout=180s" || warn "rollout not confirmed in 3 minutes"
fi

sec "3. Checks"
NC=0; for i in $CLUSTER_NODES; do NC=$((NC+1)); done
expect "CRD NetworkAttachmentDefinition" 1 "$(rk "$SERVER" "kubectl get crd network-attachment-definitions.k8s.cni.cncf.io -o name 2>/dev/null | wc -l" | tr -d ' ')"
expect "Multus pods Running" "$NC" "$(rk "$SERVER" "kubectl -n kube-system get pods -l app=multus --no-headers 2>/dev/null | awk '\$3==\"Running\"{c++} END{print c+0}'" | tr -d ' ')"
IMG="$(rk "$SERVER" "kubectl -n kube-system get ds kube-multus-ds -o jsonpath='{.spec.template.spec.containers[0].image}'" 2>/dev/null)"
info "Multus image: $IMG"
# the primary CNI must stay Kube-OVN: a new pod gets an address from the pod CIDR
rk "$SERVER" "kubectl delete pod mcheck --ignore-not-found --wait=true >/dev/null 2>&1; kubectl run mcheck --image=$CHECK_IMAGE --restart=Never -- sleep 120 >/dev/null 2>&1; kubectl wait --for=condition=Ready pod/mcheck --timeout=90s >/dev/null 2>&1" 
PIP="$(rk "$SERVER" "kubectl get pod mcheck -o jsonpath='{.status.podIP}'" 2>/dev/null)"
# is the address inside POD_CIDR? (IPv4, integer arithmetic in bash)
ip2n() { local IFS=.; set -- $1; echo $(( ($1<<24) + ($2<<16) + ($3<<8) + $4 )); }
in_cidr() { local n=${2#*/} m; m=$(( n == 0 ? 0 : (0xFFFFFFFF << (32-n)) & 0xFFFFFFFF )); [ $(( $(ip2n "$1") & m )) -eq $(( $(ip2n "${2%/*}") & m )) ]; }
R="no ($PIP)"; [ -n "$PIP" ] && in_cidr "$PIP" "$POD_CIDR" && R=yes
expect "new pod still gets a Kube-OVN address" yes "$R"
rk "$SERVER" "kubectl delete pod mcheck --ignore-not-found --wait=false >/dev/null 2>&1"
table
