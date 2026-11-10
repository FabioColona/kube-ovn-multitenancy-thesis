#!/bin/bash
# 00-preflight.sh — checks whether the lab (two sites and a router) is ready for OVN-IC.
#
# What it does : from this computer, through SSH, checks that the three machines answer, that each site has its address
#                on the expected interface, that each site reaches its router and the other site (so the router
#                forwards), that the router forwards packets (ip_forward), that the pod, service and join CIDRs of
#                the two sites do not overlap, and tells whether K3s is already installed on the sites.
# Environment  : your computer (macOS or Linux) with ssh; the lab described in config.env
# Changes      : READ-ONLY on the machines (the only side effect is the SSH connection kept open for 10 minutes)
# Requires     : bash >= 3.2, ssh, scp; python3 (optional: only for the CIDR overlap check)
# Usage        : ./00-preflight.sh
# Variables    : SITE_A_*, SITE_B_*, ROUTER_* (from config.env)
# Duration     : a few seconds
# Exit code    : 0 = no FAIL; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (multi-site laboratory)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-ic.sh"
set -uo pipefail

need_ssh_tools

sec "1. The machines answer"
for s in a b r; do
  H="$(ssh_to "$s" hostname 2>/dev/null)"
  expect "SSH to $(site_get "$s" HOST):$(site_get "$s" PORT)" yes "$( [ -n "$H" ] && echo yes || echo no )"
  [ -n "$H" ] && info "$s: hostname $H, kernel $(ssh_to "$s" uname -r 2>/dev/null)"
done
if [ "$(printf '%s\n' "${RES_STATUS[@]}" | grep -c FAIL)" -gt 0 ]; then
  table; die "a machine does not answer: check config.env (host, port, user) and that the machines are on"
fi

sec "2. Addresses and paths"
for s in a b; do
  P=SITE_$(echo "$s" | tr a-z A-Z)
  eval "IP=\${${P}_IP} IFACE=\${${P}_IFACE} RIP=\${${P}_ROUTER_IP} NAME=\${${P}_NAME}"
  other=a; [ "$s" = a ] && other=b
  OP=SITE_$(echo "$other" | tr a-z A-Z); eval "OIP=\${${OP}_IP}"
  expect "site $s: $IP on $IFACE" yes "$(ssh_to "$s" "ip -4 -o addr show dev $IFACE 2>/dev/null | grep -q ' $IP/' && echo yes || echo no" | grep -q '^yes' && echo yes || echo no)"
  expect "site $s reaches the third machine ($RIP)" yes "$(ssh_to "$s" "ping -c 2 -W 2 $RIP >/dev/null 2>&1 && echo yes || echo no")"
  expect "site $s reaches site $other ($OIP)" yes "$(ssh_to "$s" "ping -c 2 -W 2 $OIP >/dev/null 2>&1 && echo yes || echo no")"
done
# ip_forward matters only when the sites are in two networks and the third machine routes between them
if [ "$SITE_A_ROUTER_IP" != "$SITE_B_ROUTER_IP" ]; then
  expect "third machine: ip_forward (it routes between the two networks)" 1 "$(ssh_to r 'cat /proc/sys/net/ipv4/ip_forward' 2>/dev/null)"
else
  info "single network: the third machine is not in the path of the packets, ip_forward is not needed"
fi

sec "3. Networks of the two sites"
expect "pod CIDRs do not overlap"     no "$(cidr_overlap "$SITE_A_POD_CIDR" "$SITE_B_POD_CIDR")"
expect "service CIDRs do not overlap" no "$(cidr_overlap "$SITE_A_SVC_CIDR" "$SITE_B_SVC_CIDR")"
expect "join CIDRs do not overlap"    no "$(cidr_overlap "$SITE_A_JOIN_CIDR" "$SITE_B_JOIN_CIDR")"

sec "4. State of the sites"
for s in a b; do
  K="$(ssh_to "$s" 'test -x /usr/local/bin/k3s && echo installed || echo "not installed"' 2>/dev/null)"
  info "site $s: K3s $K"
done
table
