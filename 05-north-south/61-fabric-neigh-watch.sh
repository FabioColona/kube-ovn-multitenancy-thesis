#!/bin/bash
# 61-fabric-neigh-watch.sh — records, every half second, what the customer side knows about the addresses of the external
#                            segment (ARP/neighbour table of the "fabric" router) and the MAC address of the NAT Gateway pod.
#
# What it does : for DURATION seconds, on the fabric machine, prints the neighbour entries of the namespace "fabric" for the
#                external segment (address, MAC, state) and, on the server, the MAC address of net1 in the NAT Gateway pod (when
#                the pod exists). Used while the NAT Gateway pod is deleted (./50-gateway-failure.sh natgw pod), to see whether
#                the traffic waits for the old ARP entry of the EIP to expire. Changes nothing.
# Usage        : ./61-fabric-neigh-watch.sh <DURATION seconds> <output file>
# Exit code    : 0 always
# In the thesis: Chapter 6 (NAT Gateway: time after the rules are ready again)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
DUR="${ARGS[0]:-300}"; OUTF="${ARGS[1]:-$HERE/results/neigh-watch-$(date +%Y%m%d-%H%M%S).txt}"
mkdir -p "$(dirname "$OUTF")"
NET="${EXT_CIDR:-172.31.30.0/24}"
# The EIP is NOT the address of net1 of the gateway pod (net1 has its own address plus the EIP): the entry that matters for the
# traffic is the one of the EIP, printed on its own at the start of every line.
EIPIP="$(rk "$SERVER" "kubectl get iptables-eip -o jsonpath='{.items[0].status.ip}'" 2>/dev/null | tr -d '\r')"
info "EIP: ${EIPIP:-unknown}"
( nssh "$FABRIC_NODE" "T0=\$(date +%s); while [ \$(( \$(date +%s) - T0 )) -le $DUR ]; do echo \"\$(date +%s.%N) eip $EIPIP: \$(sudo -n ip netns exec fabric ip -4 neigh show $EIPIP 2>&1 | tr '\n' ' ') neigh: \$(sudo -n ip netns exec fabric ip -4 neigh show to $NET 2>&1 | tr '\n' ';')\"; sleep 0.5; done" > "$OUTF.neigh" 2>&1 ) &
( rk "$SERVER" "T0=\$(date +%s); while [ \$(( \$(date +%s) - T0 )) -le $DUR ]; do echo \"\$(date +%s.%N) pod: \$(kubectl -n kube-system get pod vpc-nat-gw-$NAT_GW-0 -o jsonpath='{.metadata.uid}' 2>/dev/null) mac: \$(kubectl -n kube-system exec vpc-nat-gw-$NAT_GW-0 -- cat /sys/class/net/net1/address 2>/dev/null)\"; sleep 1; done" > "$OUTF.podmac" 2>&1 ) &
wait
info "saved: $OUTF.neigh and $OUTF.podmac"
[ -n "$EIPIP" ] && info "changes of the EIP entry: $(awk '$7=="lladdr"{ if($8!=l){n++; l=$8} } END{print n+0}' "$OUTF.neigh")"
exit 0
