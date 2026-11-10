#!/bin/bash
# 32-vpc-peering.sh — test: what does it take for a custom VPC to talk to the default VPC through a peering?
#
# What it does : step 1, peering between vpc-t and ovn-cluster with routes on both sides: expected still closed towards
#                the default subnet (the policy at priority 29000 of the distributed gateway overrides the route).
#                Step 2, adds an allow policy at 29600: expected open both ways, and each side sees the real address
#                of the other (no NAT). Step 3, towards the private subnet sub-t: closed until allowSubnets admits the
#                CIDR of vpc-t. Control: vpc-u, with no peering, stays isolated.
# Environment  : cluster with the tenants (10-apply-tenants.sh) and the VPCs (30-apply-vpcs.sh)
# Changes      : PATCHES vpc-t, ovn-cluster and sub-t; everything is restored at the end, also if interrupted
# Requires     : bash >= 4, kubectl (with the kubectl-ko plugin installed by Kube-OVN)
# Usage        : ./32-vpc-peering.sh        (REPETITIONS=1 ./32-vpc-peering.sh for a quick run)
# Variables    : NS_T, NS_SHARED, NS_VT, NS_VU, VPC_T, SUBNET_T, REPETITIONS, SETTLE_SECONDS (from config.env)
# Duration     : about 4 minutes with 5 repetitions
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (peering between a custom VPC and the default VPC)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-tenancy.sh"
set -uo pipefail

need_cluster
kubectl ko nbctl show >/dev/null 2>&1 || die "the kubectl-ko plugin is not available (installed by Kube-OVN in /usr/local/bin)"
CT="$(pod_ip "$NS_VT" c-t)"; CU="$(pod_ip "$NS_VU" c-u)"; D1="$(pod_ip "$NS_SHARED" d1)"; T1="$(pod_ip "$NS_T" t1)"
[ -n "$CT" ] && [ -n "$CU" ] && [ -n "$D1" ] && [ -n "$T1" ] || die "test pods not found: run ./10-apply-tenants.sh and ./30-apply-vpcs.sh first"

restore() {
  kubectl patch vpc "$VPC_T" --type merge -p '{"spec":{"vpcPeerings":null,"staticRoutes":null}}' >/dev/null 2>&1
  kubectl patch vpc ovn-cluster --type merge -p '{"spec":{"vpcPeerings":null,"staticRoutes":null,"policyRoutes":null}}' >/dev/null 2>&1
  kubectl patch subnet "$SUBNET_T" --type merge -p '{"spec":{"allowSubnets":null}}' >/dev/null 2>&1
}
trap restore EXIT
restore; sleep 5
echo "c-t=$CT  c-u=$CU  d1=$D1  t1=$T1  ($REPETITIONS repetitions per row)"

sec "Step 1: peering and routes, no policy"
kubectl patch vpc "$VPC_T" --type merge --patch-file "$HERE/manifests/52-vpc-t-peering-patch.yaml" >/dev/null || die "cannot patch $VPC_T"
kubectl patch vpc ovn-cluster --type merge --patch-file "$HERE/manifests/53-ovn-cluster-peering-patch.yaml" >/dev/null || die "cannot patch ovn-cluster"
info "waiting for the routes (up to 60 s)"
waitf 30 2 route_listed "$VPC_T" "10.16.0.0/16" && waitf 30 2 route_listed ovn-cluster "10.90.0.0/24" || warn "routes not listed after 60 s"
sleep "$SETTLE_SECONDS"
check_probe "peering, no policy: c-t -> d1" blocked "$NS_VT"     c-t "$D1"
check_probe "peering, no policy: d1 -> c-t" blocked "$NS_SHARED" d1  "$CT"

sec "Step 2: allow policy at priority 29600 on ovn-cluster"
kubectl patch vpc ovn-cluster --type merge --patch-file "$HERE/manifests/54-ovn-cluster-allow-policy.yaml" >/dev/null || die "cannot patch ovn-cluster"
wait_flow ok 60 "$NS_VT" c-t "$D1" ping || warn "c-t still cannot reach d1 after 60 s"
check_probe "allow policy: c-t -> d1" open "$NS_VT"     c-t "$D1"
check_probe "allow policy: d1 -> c-t" open "$NS_SHARED" d1  "$CT"
expect "address d1 sees from c-t" "$CT" "$(seen_source "$NS_VT" c-t "$D1")"
expect "address c-t sees from d1" "$D1" "$(seen_source "$NS_SHARED" d1 "$CT")"
check_probe "control: c-u -> d1 (vpc-u, no peering)" blocked "$NS_VU" c-u "$D1"
check_probe "control: c-u -> c-t (vpc-u to vpc-t)"   blocked "$NS_VU" c-u "$CT"

sec "Step 3: towards the private subnet sub-t"
check_probe "sub-t private: c-t -> t1" blocked "$NS_VT" c-t "$T1"
kubectl patch subnet "$SUBNET_T" --type merge --patch-file "$HERE/manifests/55-sub-t-allow-vpc.yaml" >/dev/null || die "cannot patch $SUBNET_T"
wait_flow ok 60 "$NS_VT" c-t "$T1" ping || warn "c-t still cannot reach t1 after 60 s"
check_probe "allowSubnets has vpc-t: c-t -> t1" open "$NS_VT" c-t "$T1"
expect "address t1 sees from c-t" "$CT" "$(seen_source "$NS_VT" c-t "$T1")"
table
