#!/bin/bash
# 42-custom-custom.sh — test: custom VPC of one site against custom VPC of the other (double peering).
#
# What it does : vpc-t (site A) and vpc-custom-b (site B) are each peered with the default VPC of their site, and
#                OVN-IC carries the routes between the two default VPCs. Checks: ping and TCP in both directions, TTL 60
#                (four logical routers: vpc-t, ovn-cluster A, ovn-cluster B, vpc-custom-b), the other tenant (vpc-u, no
#                route) is blocked in both directions; removing the return route of vpc-custom-b breaks the path in both
#                directions (the reply is lost), restoring it brings it back.
# Environment  : the tenants of 21-ic-tenants.sh
# Changes      : patches vpc-custom-b once; restored at the end, also if interrupted
# Requires     : bash >= 3.2, ssh
# Usage        : ./42-custom-custom.sh        (REPETITIONS=1 for a quick run)
# Variables    : pod names/addresses and REPETITIONS (from config.env)
# Duration     : about 4 minutes with 5 repetitions
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (double peering)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-ic.sh"
set -uo pipefail

need_ssh_tools
M="$HERE/manifests"
ic_need_tenants
trap 'clear_line; ic_restore_baseline' EXIT
ic_restore_baseline
echo "($REPETITIONS repetitions per row)"

sec "Double peering"
ic_check "c-t (vpc-t, site A) -> pb (vpc-custom-b, site B)" open a "$NS_VT" c-t "$IP_PB"
ic_check "pb (vpc-custom-b, site B) -> c-t (vpc-t, site A)" open b "$NS_VB" pb "$IP_CT"
expect "TTL of the reply c-t -> pb (four routers)" 60 "$(ic_ttl a "$NS_VT" c-t "$IP_PB")"
expect "TTL of the reply pb -> c-t (four routers)" 60 "$(ic_ttl b "$NS_VB" pb "$IP_CT")"
ic_check "control: c-u -> c-u (the pod runs and its server listens)" open a "$NS_VU" c-u "$IP_CU"
ic_check "other tenant: c-u (vpc-u) -> pb" blocked a "$NS_VU" c-u "$IP_PB"
ic_check "other tenant: pb -> c-u (vpc-u)" blocked b "$NS_VB" pb "$IP_CU"

sec "Return route of vpc-custom-b removed"
ic_patch b vpc vpc-custom-b "$M/56-vpc-custom-b-no-route-vpc-t.yaml" || die "cannot patch vpc-custom-b"
ic_wait_probe blocked 60 b "$NS_VB" pb "$IP_CT" || warn "route not removed after 1 minute"
ic_check "no route to 10.90.0.0/24: pb -> c-t" blocked b "$NS_VB" pb "$IP_CT"
ic_check "no route to 10.90.0.0/24: c-t -> pb (the reply is lost)" blocked a "$NS_VT" c-t "$IP_PB"
ic_patch b vpc vpc-custom-b "$M/45-vpc-custom-b-peering.yaml" || die "cannot patch vpc-custom-b"
ic_wait_probe open 60 b "$NS_VB" pb "$IP_CT" || warn "route not restored after 1 minute"
ic_check "route restored: pb -> c-t" open b "$NS_VB" pb "$IP_CT"
ic_check "route restored: c-t -> pb" open a "$NS_VT" c-t "$IP_PB"
table
