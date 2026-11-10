#!/bin/bash
# 33-vpc-transit.sh — test: can two tenants, each peered with the default VPC, end up talking through it?
#
# What it does : peers vpc-t and vpc-u with ovn-cluster (and opens each one to the default subnet), then:
#                step 1, no route between the tenants: expected closed between them, open to the default subnet;
#                step 2, ONE route per side towards the other tenant: expected OPEN (ovn-cluster becomes a transit router
#                        although nobody asked for it);
#                step 3, two drop policies at 29800 on ovn-cluster: expected closed between the tenants, still open
#                        to the default subnet.
# Environment  : cluster with the tenants (10-apply-tenants.sh) and the VPCs (30-apply-vpcs.sh)
# Changes      : PATCHES vpc-t, vpc-u and ovn-cluster; everything is restored at the end, also if interrupted
# Requires     : bash >= 4, kubectl (with the kubectl-ko plugin installed by Kube-OVN)
# Usage        : ./33-vpc-transit.sh        (REPETITIONS=1 ./33-vpc-transit.sh for a quick run)
# Variables    : NS_SHARED, NS_VT, NS_VU, VPC_T, VPC_U, REPETITIONS, SETTLE_SECONDS (from config.env)
# Duration     : about 5 minutes with 5 repetitions
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (transit between tenants through the default VPC)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-tenancy.sh"
set -uo pipefail

need_cluster
kubectl ko nbctl show >/dev/null 2>&1 || die "the kubectl-ko plugin is not available (installed by Kube-OVN in /usr/local/bin)"
CT="$(pod_ip "$NS_VT" c-t)"; CU="$(pod_ip "$NS_VU" c-u)"; D1="$(pod_ip "$NS_SHARED" d1)"
[ -n "$CT" ] && [ -n "$CU" ] && [ -n "$D1" ] || die "test pods not found: run ./10-apply-tenants.sh and ./30-apply-vpcs.sh first"

restore() {
  kubectl patch vpc "$VPC_T" --type merge -p '{"spec":{"vpcPeerings":null,"staticRoutes":null}}' >/dev/null 2>&1
  kubectl patch vpc "$VPC_U" --type merge -p '{"spec":{"vpcPeerings":null,"staticRoutes":null}}' >/dev/null 2>&1
  kubectl patch vpc ovn-cluster --type merge -p '{"spec":{"vpcPeerings":null,"staticRoutes":null,"policyRoutes":null}}' >/dev/null 2>&1
}
trap restore EXIT
restore; sleep 5
patch() { kubectl patch vpc "$1" --type merge --patch-file "$HERE/manifests/$2" >/dev/null || die "cannot patch $1 with $2"; }
echo "c-t=$CT  c-u=$CU  d1=$D1  ($REPETITIONS repetitions per row)"

sec "Step 1: both tenants peered with ovn-cluster, no route between them"
patch "$VPC_T" 52-vpc-t-peering-patch.yaml
patch "$VPC_U" 56-vpc-u-peering-patch.yaml
patch ovn-cluster 57-ovn-cluster-two-peerings-patch.yaml
patch ovn-cluster 58-ovn-cluster-allow-both-policy.yaml
info "waiting for the routes and the connectivity to the default subnet (up to 60 s)"
waitf 30 2 route_listed ovn-cluster "10.91.0.0/24" || warn "route to 10.91.0.0/24 not listed after 60 s"
wait_flow ok 60 "$NS_VT" c-t "$D1" ping || warn "c-t cannot reach d1 after 60 s"
wait_flow ok 60 "$NS_VU" c-u "$D1" ping || warn "c-u cannot reach d1 after 60 s"
sleep "$SETTLE_SECONDS"
check_probe "no mutual route: c-t -> d1" open    "$NS_VT" c-t "$D1"
check_probe "no mutual route: c-u -> d1" open    "$NS_VU" c-u "$D1"
check_probe "no mutual route: c-t -> c-u" blocked "$NS_VT" c-t "$CU"
check_probe "no mutual route: c-u -> c-t" blocked "$NS_VU" c-u "$CT"

sec "Step 2: one route per side towards the other tenant"
patch "$VPC_T" 59-vpc-t-transit-routes-patch.yaml
patch "$VPC_U" 60-vpc-u-transit-routes-patch.yaml
wait_flow ok 60 "$NS_VT" c-t "$CU" ping || warn "c-t cannot reach c-u after 60 s"
check_probe "mutual routes: c-t -> c-u" open "$NS_VT" c-t "$CU"
check_probe "mutual routes: c-u -> c-t" open "$NS_VU" c-u "$CT"

sec "Step 3: drop policies at 29800 on ovn-cluster"
patch ovn-cluster 61-ovn-cluster-block-transit-patch.yaml
wait_flow blocked 60 "$NS_VT" c-t "$CU" ping || warn "c-t still reaches c-u after 60 s"
check_probe "drop 29800: c-t -> c-u" blocked "$NS_VT" c-t "$CU"
check_probe "drop 29800: c-u -> c-t" blocked "$NS_VU" c-u "$CT"
check_probe "drop 29800: c-t -> d1"  open    "$NS_VT" c-t "$D1"
check_probe "drop 29800: c-u -> d1"  open    "$NS_VU" c-u "$D1"
table
