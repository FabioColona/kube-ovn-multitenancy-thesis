#!/bin/bash
# 41-default-custom.sh — test: default VPC and custom VPC on different sites (matrix of all directions).
#
# What it does : sub-t-b admits only 10.80.0.0/24, so the custom VPC of T on site A is blocked; adding 10.90.0.0/24 opens
#                it. Then the matrix: public subnet / private subnet / custom VPC of one site against the other, in both
#                directions, with the routes and allowSubnets of the baseline. Then three steps for a private subnet of
#                site A to reach the custom VPC of site B: the return route (still blocked), the CIDR in allowSubnets
#                (passes; the other tenant stays blocked), and the return routes of the other tenant (the ACLs of its
#                subnets keep blocking it).
# Environment  : the tenants of 21-ic-tenants.sh
# Changes      : patches vpc-t, vpc-custom-b, sub-t-a and sub-t-b; the baseline is restored at the end, also if interrupted
# Requires     : bash >= 3.2, ssh
# Usage        : ./41-default-custom.sh        (REPETITIONS=1 for a quick run)
# Variables    : pod names/addresses and REPETITIONS (from config.env)
# Duration     : about 20 minutes with 5 repetitions
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
trap 'clear_line; ic_restore_baseline' EXIT
ic_restore_baseline
echo "($REPETITIONS repetitions per row)"

sec "Custom VPC of T (site A) towards the private subnet of T (site B)"
ic_check "sub-t-b without 10.90.0.0/24: c-t -> t-b" blocked a "$NS_VT" c-t "$IP_T_B"
ic_patch b subnet sub-t-b "$M/51-sub-t-b-allow-vpc-t.yaml" || die "cannot patch sub-t-b"
ic_wait_probe open 60 a "$NS_VT" c-t "$IP_T_B" || warn "allowSubnets not effective after 1 minute"
ic_check "sub-t-b with 10.90.0.0/24: c-t -> t-b" open a "$NS_VT" c-t "$IP_T_B"

sec "Matrix, site A towards site B"
ic_check "A1 public d-a -> custom pb" open a "$NS_D" d-a "$IP_PB"
ic_check "A2 private t-a (T) -> custom pb: no return route, no allowSubnets" blocked a "$NS_T_A" t-a "$IP_PB"
ic_check "A3 private u-a (U) -> custom pb" blocked a "$NS_U_A" u-a "$IP_PB"
sec "Matrix, site B towards site A"
ic_check "B1 private t-b (T) -> custom c-t" open b "$NS_T_B" t-b "$IP_CT"
ic_check "B2 public d-b -> custom c-t" open b "$NS_D" d-b "$IP_CT"
ic_check "B3 private u-b (U) -> custom c-t" blocked b "$NS_U_B" u-b "$IP_CT"
ic_check "B4 public d-b -> custom c-u (vpc-u has no route to the public subnet of site B)" blocked b "$NS_D" d-b "$IP_CU"
sec "Controls"
ic_check "K1 custom c-t -> public d-b" open a "$NS_VT" c-t "$IP_D_B"
ic_check "K3 custom c-u (U) -> private t-b (T)" blocked a "$NS_VU" c-u "$IP_T_B"
ic_check "K4 custom c-u -> custom pb (no route)" blocked a "$NS_VU" c-u "$IP_PB"
ic_check "K5 custom pb -> custom c-t" open b "$NS_VB" pb "$IP_CT"

sec "Step 2: return route to 10.80.0.0/24 in vpc-custom-b"
ic_patch b vpc vpc-custom-b "$M/52-vpc-custom-b-return-t-a.yaml" || die "cannot patch vpc-custom-b"
WAIT_MSG="the route appears in vpc-custom-b" waitf 15 2 _ic_vpc_route_is b vpc-custom-b 10.80.0.0/24; sleep 4
expect "the return route to 10.80.0.0/24 is in vpc-custom-b" yes "$(ic_vpc_route b vpc-custom-b 10.80.0.0/24)"
ic_check "route present, sub-t-a still without 10.60.0.0/24: t-a -> pb" blocked a "$NS_T_A" t-a "$IP_PB"
sec "Step 3: 10.60.0.0/24 in allowSubnets of sub-t-a"
ic_patch a subnet sub-t-a "$M/53-sub-t-a-allow-custom-b.yaml" || die "cannot patch sub-t-a"
ic_wait_probe open 60 a "$NS_T_A" t-a "$IP_PB" || warn "allowSubnets not effective after 1 minute"
ic_check "route and allowSubnets: t-a (T) -> pb" open a "$NS_T_A" t-a "$IP_PB"
ic_check "same configuration: u-a (U) -> pb" blocked a "$NS_U_A" u-a "$IP_PB"
ic_check "same configuration: d-a -> pb (unchanged)" open a "$NS_D" d-a "$IP_PB"
ic_check "same configuration: pb -> c-t (unchanged)" open b "$NS_VB" pb "$IP_CT"
sec "Step 4: return routes of the other tenant (10.82.0.0/24 in vpc-custom-b, 10.83.0.0/24 in vpc-t)"
ic_patch b vpc vpc-custom-b "$M/54-vpc-custom-b-return-u-a.yaml" || die "cannot patch vpc-custom-b"
ic_patch a vpc vpc-t "$M/55-vpc-t-return-u-b.yaml" || die "cannot patch vpc-t"
WAIT_MSG="the routes appear" waitf 15 2 _ic_vpc_route_is a vpc-t 10.83.0.0/24; sleep 4
expect "the return route to 10.82.0.0/24 is in vpc-custom-b" yes "$(ic_vpc_route b vpc-custom-b 10.82.0.0/24)"
expect "the return route to 10.83.0.0/24 is in vpc-t" yes "$(ic_vpc_route a vpc-t 10.83.0.0/24)"
ic_check "routes present: u-a (U) -> pb, blocked by the ACL of sub-u-a" blocked a "$NS_U_A" u-a "$IP_PB"
ic_check "routes present: u-b (U) -> c-t, blocked by the ACL of sub-u-b" blocked b "$NS_U_B" u-b "$IP_CT"
ic_check "control: t-a (T) -> pb" open a "$NS_T_A" t-a "$IP_PB"
ic_check "control: t-b (T) -> c-t" open b "$NS_T_B" t-b "$IP_CT"
table
