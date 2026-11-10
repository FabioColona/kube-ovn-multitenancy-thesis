#!/bin/bash
# 41-netpol-vpc.sh — test: do Kubernetes NetworkPolicies work for pods of a custom VPC?
#
# What it does : part 1, a policy on the pod d1 of the DEFAULT VPC while the client c-t is in the custom VPC vpc-t,
#                peered with ovn-cluster: deny-all blocks; an ipBlock on the CIDR of vpc-t opens (the real source address
#                is preserved); a namespaceSelector opens only while the namespace of the client carries the label.
#                Part 2, a policy on a pod INSIDE the custom VPC: deny-all blocks the client of the same VPC; a
#                podSelector rule opens only while the client carries the label.
# Environment  : cluster with the tenants (10-apply-tenants.sh) and the VPCs (30-apply-vpcs.sh)
# Changes      : PATCHES vpc-t and ovn-cluster for the peering, creates 5 NetworkPolicies, 3 labels; everything is
#                removed or restored at the end, also if interrupted
# Requires     : bash >= 4, kubectl (with the kubectl-ko plugin installed by Kube-OVN)
# Usage        : ./41-netpol-vpc.sh        (REPETITIONS=1 ./41-netpol-vpc.sh for a quick run)
# Variables    : NS_SHARED, NS_VT, VPC_T, NP_LABEL, REPETITIONS, SETTLE_SECONDS (from config.env)
# Duration     : about 8 minutes with 5 repetitions
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (NetworkPolicy and custom VPC)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-tenancy.sh"
set -uo pipefail

need_cluster
kubectl ko nbctl show >/dev/null 2>&1 || die "the kubectl-ko plugin is not available (installed by Kube-OVN in /usr/local/bin)"
CT="$(pod_ip "$NS_VT" c-t)"; CT2="$(pod_ip "$NS_VT" c-t2)"; D1="$(pod_ip "$NS_SHARED" d1)"
[ -n "$CT" ] && [ -n "$CT2" ] && [ -n "$D1" ] || die "test pods not found: run ./10-apply-tenants.sh and ./30-apply-vpcs.sh first"
M="$HERE/manifests"
NP_KEY="${NP_LABEL%%=*}"

policies_off() {
  local f
  for f in 71-netpol-shared-deny-all 72-netpol-shared-allow-ipblock 73-netpol-shared-allow-namespace \
           74-netpol-vpc-deny-all 75-netpol-vpc-allow-client; do
    kubectl delete -f "$M/$f.yaml" --ignore-not-found >/dev/null 2>&1
  done
}
restore() {
  policies_off
  kubectl label ns "$NS_VT" "$NP_KEY-" >/dev/null 2>&1
  kubectl -n "$NS_VT" label pod c-t role- >/dev/null 2>&1
  kubectl -n "$NS_VT" label pod c-t2 role- >/dev/null 2>&1
  kubectl patch vpc "$VPC_T" --type merge -p '{"spec":{"vpcPeerings":null,"staticRoutes":null}}' >/dev/null 2>&1
  kubectl patch vpc ovn-cluster --type merge -p '{"spec":{"vpcPeerings":null,"staticRoutes":null,"policyRoutes":null}}' >/dev/null 2>&1
}
trap restore EXIT
restore; sleep 5
echo "c-t=$CT  c-t2=$CT2  d1=$D1  ($REPETITIONS repetitions per row)"

# apply <manifest>; settle <expected ok|blocked> <namespace> <pod> <destination>: waits for the traffic to change.
apply() { kubectl apply -f "$M/$1" >/dev/null || die "cannot apply manifests/$1"; }
settle() { wait_flow "$1" 60 "$2" "$3" "$4" ping || warn "traffic $3 -> $4 still not $1 after 60 s"; }

sec "Peering of vpc-t with the default VPC (as in 32-vpc-peering.sh, steps 1 and 2)"
kubectl patch vpc "$VPC_T" --type merge --patch-file "$M/52-vpc-t-peering-patch.yaml" >/dev/null || die "cannot patch $VPC_T"
kubectl patch vpc ovn-cluster --type merge --patch-file "$M/53-ovn-cluster-peering-patch.yaml" >/dev/null || die "cannot patch ovn-cluster"
kubectl patch vpc ovn-cluster --type merge --patch-file "$M/54-ovn-cluster-allow-policy.yaml" >/dev/null || die "cannot patch ovn-cluster"
settle ok "$NS_VT" c-t "$D1"
sleep "$SETTLE_SECONDS"

sec "Part 1: policy on d1 (default VPC), client c-t (custom VPC)"
check_probe "no policy: c-t -> d1" open "$NS_VT" c-t "$D1"
apply 71-netpol-shared-deny-all.yaml;        settle blocked "$NS_VT" c-t "$D1"
check_probe "deny-all: c-t -> d1" blocked "$NS_VT" c-t "$D1"
apply 72-netpol-shared-allow-ipblock.yaml;   settle ok "$NS_VT" c-t "$D1"
check_probe "ipBlock on the CIDR of vpc-t: c-t -> d1" open "$NS_VT" c-t "$D1"
kubectl delete -f "$M/72-netpol-shared-allow-ipblock.yaml" >/dev/null;  settle blocked "$NS_VT" c-t "$D1"
check_probe "ipBlock removed: c-t -> d1" blocked "$NS_VT" c-t "$D1"
apply 73-netpol-shared-allow-namespace.yaml
kubectl label ns "$NS_VT" "$NP_LABEL" --overwrite >/dev/null;  settle ok "$NS_VT" c-t "$D1"
check_probe "namespaceSelector, namespace with the label: c-t -> d1" open "$NS_VT" c-t "$D1"
kubectl label ns "$NS_VT" "$NP_KEY-" >/dev/null;  settle blocked "$NS_VT" c-t "$D1"
check_probe "namespaceSelector, label removed: c-t -> d1" blocked "$NS_VT" c-t "$D1"
policies_off; settle ok "$NS_VT" c-t "$D1"

sec "Part 2: policy on c-t, client c-t2, both inside vpc-t"
kubectl -n "$NS_VT" label pod c-t role=server --overwrite >/dev/null
check_probe "no policy: c-t2 -> c-t" open "$NS_VT" c-t2 "$CT"
apply 74-netpol-vpc-deny-all.yaml;  settle blocked "$NS_VT" c-t2 "$CT"
check_probe "deny-all: c-t2 -> c-t" blocked "$NS_VT" c-t2 "$CT"
apply 75-netpol-vpc-allow-client.yaml
kubectl -n "$NS_VT" label pod c-t2 role=client --overwrite >/dev/null;  settle ok "$NS_VT" c-t2 "$CT"
check_probe "podSelector, client labelled: c-t2 -> c-t" open "$NS_VT" c-t2 "$CT"
kubectl -n "$NS_VT" label pod c-t2 role- >/dev/null;  settle blocked "$NS_VT" c-t2 "$CT"
check_probe "podSelector, label removed: c-t2 -> c-t" blocked "$NS_VT" c-t2 "$CT"
table
