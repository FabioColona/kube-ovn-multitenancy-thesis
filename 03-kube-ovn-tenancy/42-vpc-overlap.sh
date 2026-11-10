#!/bin/bash
# 42-vpc-overlap.sh — test: can two VPCs use the same address range, and the same pod address?
#
# What it does : creates vpc-o1 and vpc-o2, each with a subnet of 10.95.0.0/24, and a server with the address 10.95.0.10
#                in each; then a subnet of vpc-o1 with 10.80.0.0/24, the CIDR of the tenant subnet sub-t that lives in the
#                default VPC, with a server at 10.80.0.10 and another server at 10.80.0.10 in sub-t. A client next to each
#                server asks the address 10.95.0.10 (or 10.80.0.10) and reads which server answered.
#                Expected: every client reaches the server of its own VPC, never the other one.
# Environment  : cluster with the tenants of 10-apply-tenants.sh (the pod t-dup is added to ns-t)
# Changes      : creates 3 namespaces, 2 VPCs, 3 subnets and 7 pods; all removed at the end, also if interrupted
#                (KEEP=1 leaves them in place)
# Requires     : bash >= 4, kubectl
# Usage        : ./42-vpc-overlap.sh        (REPETITIONS=1 ./42-vpc-overlap.sh for a quick run)
# Variables    : NS_T, NS_O1, NS_O2, NS_O3, VPC_O1, VPC_O2, REPETITIONS, SETTLE_SECONDS (from config.env)
# Duration     : about 3 minutes with 5 repetitions
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (overlapping address ranges between VPCs)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-tenancy.sh"
set -uo pipefail

need_cluster
kubectl get ns "$NS_T" >/dev/null 2>&1 || die "namespace $NS_T not found: run ./10-apply-tenants.sh first"
VPCS="$HERE/manifests/76-overlap-vpcs.yaml"; PODS="$HERE/manifests/77-overlap-pods.yaml"

cleanup() {
  [ "${KEEP:-0}" = 1 ] && return 0
  kubectl delete -f "$PODS" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete -f "$VPCS" --ignore-not-found --wait=false >/dev/null 2>&1
}
trap cleanup EXIT
kubectl delete -f "$PODS" --ignore-not-found --wait=true >/dev/null 2>&1
kubectl delete -f "$VPCS" --ignore-not-found --wait=true >/dev/null 2>&1

sec "Creating the VPCs and subnets"
kubectl apply -f "$VPCS" >/dev/null || die "cannot apply manifests/76-overlap-vpcs.yaml"
info "applied 76-overlap-vpcs.yaml"
wait_bound "$NS_O1" sub-o1 && wait_bound "$NS_O2" sub-o2 && wait_bound "$NS_O3" sub-o3 || die "namespaces not bound to their subnets after 2 minutes"
info "namespaces bound to their subnets"

sec "Creating the pods"
kubectl apply -f "$PODS" >/dev/null || die "cannot apply manifests/77-overlap-pods.yaml"
for spec in "$NS_O1 o1-srv" "$NS_O1 o1-cli" "$NS_O2 o2-srv" "$NS_O2 o2-cli" "$NS_O3 o3-srv" "$NS_O3 o3-cli" "$NS_T t-dup"; do
  # shellcheck disable=SC2086
  set -- $spec
  wait_pod_ready "$1" "$2" || warn "pod $1/$2 not Ready after 3 minutes"
done
sleep "$SETTLE_SECONDS"

sec "Probing"
O1="$(pod_ip "$NS_O1" o1-srv)"; O2="$(pod_ip "$NS_O2" o2-srv)"; O3="$(pod_ip "$NS_O3" o3-srv)"; TD="$(pod_ip "$NS_T" t-dup)"
echo "o1-srv=$O1  o2-srv=$O2  o3-srv=$O3  t-dup=$TD  ($REPETITIONS repetitions per row)"
expect "o1-srv and o2-srv (two custom VPCs) have the same address" yes "$([ -n "$O1" ] && [ "$O1" = "$O2" ] && echo yes || echo no)"
expect "o3-srv (custom VPC) and t-dup (default VPC) have the same address" yes "$([ -n "$O3" ] && [ "$O3" = "$TD" ] && echo yes || echo no)"
check_who "o1-cli -> 10.95.0.10 is answered by"  O1 "$NS_O1" o1-cli 10.95.0.10
check_who "o2-cli -> 10.95.0.10 is answered by"  O2 "$NS_O2" o2-cli 10.95.0.10
check_who "o3-cli -> 10.80.0.10 is answered by"  O3 "$NS_O3" o3-cli 10.80.0.10
check_who "t2 (default VPC) -> 10.80.0.10 is answered by" T "$NS_T" t2 10.80.0.10
table
