#!/bin/bash
# 21-subnet-acl.sh — test: does an ACL in Subnet.spec.acls filter one port and leave the rest open?
#
# What it does : with t1 and t2 (same private subnet sub-t) measures TCP 8080 and ping before, during and after
#                an ACL that drops TCP 8080 towards sub-t (manifests/40-subnet-acl-patch.yaml).
#                Expected: TCP 8080 blocked only while the ACL exists; ping always open.
# Environment  : cluster with the tenants of 10-apply-tenants.sh
# Changes      : PATCHES the subnet sub-t (adds then removes spec.acls; removed also if the script is interrupted)
# Requires     : bash >= 4, kubectl
# Usage        : ./21-subnet-acl.sh        (REPETITIONS=1 ./21-subnet-acl.sh for a quick run)
# Variables    : NS_T, SUBNET_T, REPETITIONS (from config.env)
# Duration     : about 2 minutes with 5 repetitions
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (ACL on subnets)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-tenancy.sh"
set -uo pipefail

need_cluster
T1="$(pod_ip "$NS_T" t1)"; T2="$(pod_ip "$NS_T" t2)"
[ -n "$T1" ] && [ -n "$T2" ] || die "test pods not found: run ./10-apply-tenants.sh first"
remove_acl() { kubectl patch subnet "$SUBNET_T" --type merge -p '{"spec":{"acls":null}}' >/dev/null 2>&1; }
trap remove_acl EXIT
remove_acl; wait_flow ok 30 "$NS_T" t2 "$T1" tcp || die "TCP 8080 between t2 and t1 is not open at the start: check the tenants"
echo "t1=$T1  t2=$T2  ($REPETITIONS repetitions per row)"

sec "1. Before the ACL"
check_flow "no ACL: t2 -> t1 TCP 8080" ok "$NS_T" t2 "$T1" tcp
check_flow "no ACL: t2 -> t1 ping"     ok "$NS_T" t2 "$T1" ping

sec "2. ACL: drop TCP 8080 to sub-t"
kubectl patch subnet "$SUBNET_T" --type merge --patch-file "$HERE/manifests/40-subnet-acl-patch.yaml" >/dev/null || die "cannot patch the subnet"
wait_flow blocked 60 "$NS_T" t2 "$T1" tcp || warn "TCP 8080 still open after 60 s: the ACL is not applied"
check_flow "ACL: t2 -> t1 TCP 8080" blocked "$NS_T" t2 "$T1" tcp
check_flow "ACL: t1 -> t2 TCP 8080" blocked "$NS_T" t1 "$T2" tcp
check_flow "ACL: t2 -> t1 ping"     ok      "$NS_T" t2 "$T1" ping

sec "3. ACL removed"
remove_acl
wait_flow ok 60 "$NS_T" t2 "$T1" tcp || warn "TCP 8080 still blocked after 60 s: the ACL is not removed"
check_flow "ACL removed: t2 -> t1 TCP 8080" ok "$NS_T" t2 "$T1" tcp
table
