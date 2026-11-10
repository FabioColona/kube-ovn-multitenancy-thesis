#!/bin/bash
# 40-private-subnets.sh — test: do private subnets isolate tenants on two sites interconnected with OVN-IC?
#
# What it does : tenants T and U have a private subnet on each site. Checks (ping and TCP 8080): the pods of the same
#                tenant reach each other across the sites; T and U do not reach each other (across sites and on the same
#                site); the pods of the default subnet and the pods of the private subnets do not reach each other (both
#                directions, same site and other site). Last, an ACL of the subnet (Subnet.spec.acls) that drops TCP 8080
#                from site A, applied on site B: the port is blocked and ping passes; removed, the port opens again.
# Environment  : the tenants of 21-ic-tenants.sh
# Changes      : adds and removes one ACL on sub-t-b; everything is restored at the end, also if interrupted
# Requires     : bash >= 3.2, ssh
# Usage        : ./40-private-subnets.sh        (REPETITIONS=1 for a quick run)
# Variables    : pod names/addresses and REPETITIONS (from config.env)
# Duration     : about 12 minutes with 5 repetitions
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-ic.sh"
set -uo pipefail

need_ssh_tools
M="$HERE/manifests"
ic_need_tenants
trap 'clear_line; ic_patch b subnet sub-t-b "$M/50-sub-t-b-acl-remove.yaml"' EXIT
ic_patch b subnet sub-t-b "$M/50-sub-t-b-acl-remove.yaml"
echo "($REPETITIONS repetitions per row)"

sec "Same tenant, across the sites"
ic_check "T: t-a (site A) -> t-b (site B)" open a "$NS_T_A" t-a "$IP_T_B"
ic_check "T: t-b (site B) -> t-a (site A)" open b "$NS_T_B" t-b "$IP_T_A"
ic_check "U: u-a (site A) -> u-b (site B)" open a "$NS_U_A" u-a "$IP_U_B"
ic_check "U: u-b (site B) -> u-a (site A)" open b "$NS_U_B" u-b "$IP_U_A"

sec "Tenant T against tenant U"
ic_check "t-a (A) -> u-b (B)" blocked a "$NS_T_A" t-a "$IP_U_B"
ic_check "u-b (B) -> t-a (A)" blocked b "$NS_U_B" u-b "$IP_T_A"
ic_check "t-b (B) -> u-a (A)" blocked b "$NS_T_B" t-b "$IP_U_A"
ic_check "u-a (A) -> t-b (B)" blocked a "$NS_U_A" u-a "$IP_T_B"
ic_check "t-b (B) -> u-b (B), same site" blocked b "$NS_T_B" t-b "$IP_U_B"
ic_check "u-a (A) -> t-a (A), same site" blocked a "$NS_U_A" u-a "$IP_T_A"

sec "Default subnet against private subnets"
ic_check "d-a (A) -> t-a (A), same site" blocked a "$NS_D" d-a "$IP_T_A"
ic_check "d-a (A) -> t-b (B)" blocked a "$NS_D" d-a "$IP_T_B"
ic_check "d-b (B) -> t-b (B), same site" blocked b "$NS_D" d-b "$IP_T_B"
ic_check "d-b (B) -> t-a (A)" blocked b "$NS_D" d-b "$IP_T_A"
ic_check "t-a (A) -> d-a (A), outgoing, same site" blocked a "$NS_T_A" t-a "$IP_D_A"
ic_check "t-a (A) -> d-b (B), outgoing" blocked a "$NS_T_A" t-a "$IP_D_B"
ic_check "t-b (B) -> d-a (A), outgoing" blocked b "$NS_T_B" t-b "$IP_D_A"

sec "ACL of the subnet: drop TCP 8080 from site A, applied on site B"
ic_patch b subnet sub-t-b "$M/49-sub-t-b-acl-drop-8080.yaml" || die "cannot patch sub-t-b"
ic_wait_probe ping-only 60 a "$NS_T_A" t-a "$IP_T_B" || warn "ACL not effective after 1 minute"
ic_check "ACL present: t-a -> t-b (ping passes, 8080 blocked)" ping-only a "$NS_T_A" t-a "$IP_T_B"
ic_patch b subnet sub-t-b "$M/50-sub-t-b-acl-remove.yaml" || die "cannot patch sub-t-b"
ic_wait_probe open 60 a "$NS_T_A" t-a "$IP_T_B" || warn "ACL not removed after 1 minute"
ic_check "ACL removed: t-a -> t-b" open a "$NS_T_A" t-a "$IP_T_B"
table
