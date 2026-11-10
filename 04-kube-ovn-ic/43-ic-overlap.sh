#!/bin/bash
# 43-ic-overlap.sh — test: what does OVN-IC do with overlapping or more specific prefixes announced by the other site?
#
# What it does : scenario 1: site B creates a subnet with the same CIDR as sub-t-a of site A (10.80.0.0/24): site A
#                learns it and the traffic of the tenant keeps working. Scenario 2: site B creates 10.16.5.0/24, inside
#                the pod CIDR of site A, with a pod that answers SITE-B on 10.16.5.10; site A has a pod with the same
#                address that answers SITE-A. Before site B announces the prefix, a client of the custom VPC of site A
#                reaching 10.16.5.10 gets SITE-A; after, it gets SITE-B: the more specific prefix of the other site wins
#                and there is no check by OVN-IC. A client in the same subnet as the local pod still gets SITE-A (its
#                traffic does not cross the router). Each reading is repeated REPETITIONS times.
# Environment  : the tenants of 21-ic-tenants.sh
# Changes      : creates and deletes two subnets and pods on site B and one pod on site A; removed at the end, also if interrupted
# Requires     : bash >= 3.2, ssh
# Usage        : ./43-ic-overlap.sh        (REPETITIONS=1 for a quick run)
# Variables    : pod names/addresses, IC_TS_NUM and REPETITIONS (from config.env)
# Duration     : about 6 minutes with 5 repetitions
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (overlapping CIDRs between sites)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-ic.sh"
set -uo pipefail

need_ssh_tools
M="$HERE/manifests"
ic_need_tenants
cleanup() {
  clear_line
  ic_delete b "$M/58-overlap-more-specific.yaml"; ic_delete a "$M/59-overlap-victim-site-a.yaml"; ic_delete b "$M/57-overlap-same-cidr.yaml"
  rk b 'kubectl delete subnet sub-ov-b sub-hijack --ignore-not-found >/dev/null 2>&1'
}
trap cleanup EXIT
cleanup
echo "($REPETITIONS repetitions per row)"
learned() { [ "$(ic_routes "$1" "$2")" -ge 1 ]; }

sec "Baseline"
expect "routes learned for 10.80.0.0/24 on site B" "$IC_TS_NUM" "$(ic_routes b 10.80.0.0/24)"
ic_check "t-b -> t-a" open b "$NS_T_B" t-b "$IP_T_A"

sec "Scenario 1: the same CIDR (10.80.0.0/24) announced by site B"
expect "before: site A has no learned route for its own 10.80.0.0/24" 0 "$(ic_routes a 10.80.0.0/24)"
ic_apply b "$M/57-overlap-same-cidr.yaml" || die "cannot create sub-ov-b"
WAIT_MSG="site A learns 10.80.0.0/24" waitf 30 2 learned a 10.80.0.0/24
expect "site A learns 10.80.0.0/24 from site B (routes)" "$IC_TS_NUM" "$(ic_routes a 10.80.0.0/24)"
info "site B, which now owns a subnet with the same CIDR, still has $(ic_routes b 10.80.0.0/24) learned route(s) for 10.80.0.0/24"
ic_check "same CIDR announced twice: t-b -> t-a" open b "$NS_T_B" t-b "$IP_T_A"
ic_check "same CIDR announced twice: u-b -> t-a (other tenant)" blocked b "$NS_U_B" u-b "$IP_T_A"
ic_delete b "$M/57-overlap-same-cidr.yaml"
gone() { [ "$(ic_routes a 10.80.0.0/24)" = 0 ]; }
WAIT_MSG="the route disappears" waitf 30 2 gone
ic_check "subnet removed: t-b -> t-a" open b "$NS_T_B" t-b "$IP_T_A"

sec "Scenario 2: a more specific prefix (10.16.5.0/24 inside 10.16.0.0/16)"
ic_apply a "$M/59-overlap-victim-site-a.yaml" || die "cannot create vic on site A"
run_spin "site A: waiting for vic" "up to 3 minutes" rk a "kubectl -n $NS_D wait --for=condition=Ready pod/vic --timeout=180s" || { tail -5 "$RUN_LOG"; die "vic not ready"; }
vic_answers() { [ "$(ic_who a "$NS_VT" c-t 10.16.5.10)" = SITE-A ]; }
WAIT_MSG="c-t reaches the local pod" waitf 15 2 vic_answers
expect "before the announce: site A has no route for 10.16.5.0/24" 0 "$(ic_routes a 10.16.5.0/24)"
expect "before the announce: c-t (vpc-t, site A) -> 10.16.5.10 is answered by" "SITE-A x$REPETITIONS" "$(ic_who_n a "$NS_VT" c-t 10.16.5.10)"
ic_apply b "$M/58-overlap-more-specific.yaml" || die "cannot create sub-hijack on site B"
run_spin "site B: waiting for att" "up to 3 minutes" rk b "kubectl -n ns-hj wait --for=condition=Ready pod/att --timeout=180s" || { tail -5 "$RUN_LOG"; die "att not ready"; }
WAIT_MSG="site A learns 10.16.5.0/24" waitf 30 2 learned a 10.16.5.0/24
expect "site A learns 10.16.5.0/24 from site B (routes)" "$IC_TS_NUM" "$(ic_routes a 10.16.5.0/24)"
hijacked() { [ "$(ic_who a "$NS_VT" c-t 10.16.5.10)" = SITE-B ]; }
WAIT_MSG="the learned route takes effect" waitf 15 2 hijacked
expect "after the announce: c-t (vpc-t, site A) -> 10.16.5.10 is answered by" "SITE-B x$REPETITIONS" "$(ic_who_n a "$NS_VT" c-t 10.16.5.10)"
expect "after the announce: d-a (same subnet as the local pod) -> 10.16.5.10 is answered by" "SITE-A x$REPETITIONS" "$(ic_who_n a "$NS_D" d-a 10.16.5.10)"
table
