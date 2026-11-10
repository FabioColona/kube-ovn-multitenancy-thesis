#!/bin/bash
# 56-diag-fabric.sh — read-only diagnosis of the fabric machine: tunnels towards the gateways, MAC table of br-priv, ARP of fabric and customer.
# Usage: ./56-diag-fabric.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -o pipefail
ns_setup
F() { grep -v -E "WARNING|post-quantum|openssh|vulnerable|upgraded"; }
echo "=== router port MAC and chassis"
rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-nbctl --columns=name,mac,networks list logical_router_port ovn-vpc-external" 2>&1 | F
rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-sbctl --columns=chassis find port_binding logical_port=cr-ovn-vpc-external" 2>&1 | F
echo "=== fabric machine $FABRIC_NODE"
nroot "$FABRIC_NODE" <<'EOS' 2>&1 | F
for v in $(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -E '^vxg[0-9]+$'); do echo "$v: $(ip -d link show $v | grep -o 'id [0-9]* remote [0-9.]*' | tr '\n' ' ') rx/tx: $(ip -s link show $v | awk 'NR==4{r=$2} NR==6{print r"/"$2}')"; done
echo "--- br-priv MAC table (non-local)"; bridge fdb show br br-priv | grep -v -E "permanent|self" | head -30
echo "--- fabric ns ARP"; ip netns exec fabric ip neigh
echo "--- cust ns ARP"; ip netns exec cust ip neigh
echo "--- fabric ns: ping the SNAT/router addresses"; for a in 172.31.30.103 172.31.30.104; do echo "$a: $(ip netns exec fabric ping -c2 -W1 $a 2>&1 | grep -E 'received|packet loss')"; done
EOS
