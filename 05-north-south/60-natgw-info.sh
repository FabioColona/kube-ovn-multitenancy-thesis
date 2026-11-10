#!/bin/bash
# 60-natgw-info.sh — read-only facts for Chapter 6: which iptables back-end the NAT Gateway pod uses, and the iperf3 versions.
#
# What it does : inside the NAT Gateway pod prints "iptables -V", the NAT rules seen by "iptables -t nat -S" and by
#                "iptables-legacy -t nat -S" (the one that shows the SNAT/DNAT rules is the back-end in use); prints the iperf3
#                version on every machine and in the tenant client pod (nprobe). Changes nothing.
# Requires     : the NAT Gateway configured (./30-nat-gateway.sh)
# Usage        : ./60-natgw-info.sh
# Exit code    : 0 always
# In the thesis: Chapter 6 (environment and NAT Gateway implementation)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
P="vpc-nat-gw-$NAT_GW-0"
sec "iptables inside the NAT Gateway pod $P"
for c in "iptables -V" "iptables -t nat -S" "iptables-legacy -t nat -S" "iptables-nft -t nat -S"; do
  echo "--- $c"; rk "$SERVER" "kubectl -n kube-system exec $P -- $c" 2>&1 | head -40
done
sec "iperf3 versions"
for m in $(seq 1 "$(node_n)"); do echo "  machine $m: $(nssh "$m" 'iperf3 --version 2>/dev/null | head -1' | tr -d '\r')"; done
echo "  tenant pod nprobe: $(rk "$SERVER" "kubectl -n $NS_NAT exec nprobe -- iperf3 --version 2>/dev/null | head -1")"
exit 0
