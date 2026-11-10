#!/bin/bash
# 53-gateway-state.sh — prints the gateway chassis priorities, the BFD sessions and the machine holding the router port (read only).
# Usage: ./53-gateway-state.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
rks "$SERVER" <<'EOS' 2>&1 | grep -v -E "WARNING|post-quantum|openssh|vulnerable|upgraded"
N="kubectl -n kube-system exec deploy/ovn-central -c ovn-central --"
echo "--- gateway_chassis (chassis_name priority)"; $N ovn-nbctl --columns=chassis_name,priority list gateway_chassis
echo "--- bfd (dst_ip status)"; $N ovn-nbctl --columns=dst_ip,status,logical_port list bfd
echo "--- chassis (hostname encap ip)"; $N ovn-sbctl --columns=hostname list chassis; $N ovn-sbctl --columns=chassis,ip list encap
echo "--- router port"; $N ovn-sbctl --columns=chassis find port_binding logical_port=cr-ovn-vpc-external
EOS
