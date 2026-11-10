#!/bin/bash
# 31-vpc-isolation.sh — test: are custom VPCs isolated from each other and from the default VPC, before any peering?
#
# What it does : probes (ping + TCP 8080, REPETITIONS times each) inside vpc-t, between vpc-t and vpc-u, and between
#                the custom VPCs and the default VPC (the default subnet and the private subnet sub-t), both directions.
#                Expected: only traffic inside the same custom subnet is open.
# Environment  : cluster with the tenants of 10-apply-tenants.sh and the VPCs of 30-apply-vpcs.sh
# Changes      : READ-ONLY on the cluster (only runs ping and nc inside the test pods)
# Requires     : bash >= 4, kubectl
# Usage        : ./31-vpc-isolation.sh        (REPETITIONS=1 ./31-vpc-isolation.sh for a quick run)
# Variables    : NS_T, NS_SHARED, NS_VT, NS_VU, REPETITIONS (from config.env)
# Duration     : about 3 minutes with 5 repetitions
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (isolation of custom VPCs)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-tenancy.sh"
set -uo pipefail

need_cluster
CT="$(pod_ip "$NS_VT" c-t)"; CT2="$(pod_ip "$NS_VT" c-t2)"; CU="$(pod_ip "$NS_VU" c-u)"
D1="$(pod_ip "$NS_SHARED" d1)"; T1="$(pod_ip "$NS_T" t1)"
[ -n "$CT" ] && [ -n "$CT2" ] && [ -n "$CU" ] && [ -n "$D1" ] && [ -n "$T1" ] || die "test pods not found: run ./10-apply-tenants.sh and ./30-apply-vpcs.sh first"
kubectl get vpc "$VPC_T" -o jsonpath='{.spec.vpcPeerings}' | grep -q . && die "vpc-t already has a peering: run ./91-remove-vpcs.sh and ./30-apply-vpcs.sh"
echo "c-t=$CT  c-t2=$CT2  c-u=$CU  d1=$D1  t1=$T1  ($REPETITIONS repetitions per row)"

sec "Probing"
check_probe "c-t -> c-t2  (same custom VPC)"           open    "$NS_VT"     c-t  "$CT2"
check_probe "c-t2 -> c-t  (same custom VPC)"           open    "$NS_VT"     c-t2 "$CT"
check_probe "c-t -> c-u   (vpc-t to vpc-u)"            blocked "$NS_VT"     c-t  "$CU"
check_probe "c-u -> c-t   (vpc-u to vpc-t)"            blocked "$NS_VU"     c-u  "$CT"
check_probe "c-t -> d1    (custom to default subnet)"  blocked "$NS_VT"     c-t  "$D1"
check_probe "d1 -> c-t    (default subnet to custom)"  blocked "$NS_SHARED" d1   "$CT"
check_probe "c-t -> t1    (custom to private subnet)"  blocked "$NS_VT"     c-t  "$T1"
check_probe "t1 -> c-t    (private subnet to custom)"  blocked "$NS_T"      t1   "$CT"
table
