#!/bin/bash
# 54-diag-gateway-machine.sh — read-only diagnosis of one gateway machine: ext0, namespace ovnext, bridge ports, tunnels, BFD.
# Usage: ./54-diag-gateway-machine.sh <machine number>
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
M="${ARGS[0]:?usage: ./54-diag-gateway-machine.sh <machine number>}"
HN="$(nssh "$M" hostname | tr -d '\r')"
F() { grep -v -E "WARNING|post-quantum|openssh|vulnerable|upgraded"; }
echo "=== machine $M ($HN): host side"
nroot "$M" <<'EOS' 2>&1 | F
echo "--- ext0"; ip -d link show ext0 | head -4
echo "--- addresses"; ip -4 -br addr
echo "--- ovnext namespace"; ip netns exec ovnext ip -br addr; ip netns exec ovnext ip route
echo "--- ping fabric from ovnext"; ip netns exec ovnext ping -c2 -W1 172.31.30.1 2>&1 | tail -3
echo "--- ping customer from ovnext"; ip netns exec ovnext ping -c2 -W1 172.31.20.10 2>&1 | tail -3
echo "--- vxlan counters"; ip -s link show ext0 | tail -4
EOS
P=$(rk "$SERVER" "kubectl -n kube-system get pod -l app=ovs --field-selector spec.nodeName=$HN -o jsonpath='{.items[0].metadata.name}'" | F)
echo "=== OVS in pod $P"
rk "$SERVER" "kubectl -n kube-system exec $P -- sh -c 'ovs-vsctl show; echo ---; ovs-vsctl --columns=name,options find interface type=geneve; echo ---; ovs-vsctl get open . external_ids:ovn-encap-ip external_ids:ovn-remote; echo ---; ovs-vsctl port-to-br ext0; ovs-vsctl list-ports br-int | head -30'" 2>&1 | F
echo "=== ovn-controller log tail"
rk "$SERVER" "kubectl -n kube-system exec $P -- sh -c 'tail -15 /var/log/ovn/ovn-controller.log'" 2>&1 | F
