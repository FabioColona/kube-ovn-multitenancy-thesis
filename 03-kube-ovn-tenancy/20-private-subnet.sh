#!/bin/bash
# 20-private-subnet.sh — test: does a private subnet isolate a tenant in both directions?
#
# What it does : with the pods of 10-apply-tenants.sh, probes (ping + TCP 8080, REPETITIONS times each):
#                inside the tenant, between the two tenants, and between each tenant and the default subnet,
#                in both directions. Expected: only traffic inside the same private subnet is open.
# Environment  : cluster with the tenants of 10-apply-tenants.sh
# Changes      : READ-ONLY on the cluster (only runs ping and nc inside the test pods)
# Requires     : bash >= 4, kubectl
# Usage        : ./20-private-subnet.sh        (REPETITIONS=1 ./20-private-subnet.sh for a quick run)
# Variables    : NS_T, NS_U, NS_SHARED, REPETITIONS (from config.env)
# Duration     : about 2 minutes with 5 repetitions
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (isolation with private subnets)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-tenancy.sh"
set -uo pipefail

need_cluster
T1="$(pod_ip "$NS_T" t1)"; T2="$(pod_ip "$NS_T" t2)"; U1="$(pod_ip "$NS_U" u1)"; D1="$(pod_ip "$NS_SHARED" d1)"
[ -n "$T1" ] && [ -n "$T2" ] && [ -n "$U1" ] && [ -n "$D1" ] || die "test pods not found: run ./10-apply-tenants.sh first"
echo "t1=$T1  t2=$T2  u1=$U1  d1=$D1  ($REPETITIONS repetitions per row)"

sec "Probing"
check_probe "t1 -> t2  (same tenant)"           open    "$NS_T"      t1 "$T2"
check_probe "t2 -> t1  (same tenant)"           open    "$NS_T"      t2 "$T1"
check_probe "u1 -> u1  (control: u1 runs and its server listens)" open "$NS_U" u1 "$U1"
check_probe "t1 -> u1  (tenant t to u)"         blocked "$NS_T"      t1 "$U1"
check_probe "u1 -> t1  (tenant u to t)"         blocked "$NS_U"      u1 "$T1"
check_probe "d1 -> t1  (default to tenant t)"   blocked "$NS_SHARED" d1 "$T1"
check_probe "d1 -> u1  (default to tenant u)"   blocked "$NS_SHARED" d1 "$U1"
check_probe "t1 -> d1  (tenant t to default)"   blocked "$NS_T"      t1 "$D1"
check_probe "u1 -> d1  (tenant u to default)"   blocked "$NS_U"      u1 "$D1"
table
