#!/bin/bash
# 39-remove-ovn-gateway.sh — removes what 31-ovn-gateway.sh created (the cluster and the customer network stay).
#
# What it does : deletes the client pod, SNAT rule, OVN EIPs, subnets, VPC, namespace, provider network and VLAN, and removes
#                the gateway label from the nodes. The provider network gives EXT_NIC back to the host.
# Environment  : the cluster of 20-install-cluster.sh
# Changes      : DESTRUCTIVE (only the objects of the OVN Gateway test)
# Requires     : phase 20 done
# Usage        : ./39-remove-ovn-gateway.sh [--yes]
# Variables    : OVNGW_*, NS_OVNGW, EXT_NIC (from config.env)
# Duration     : about 2 minutes
# Exit code    : 0 = removed; 1 = something left; 2 = prerequisite missing
# In the thesis: not cited (support script)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
require_vars OVNGW_VPC OVNGW_SUBNET OVNGW_PROVIDER OVNGW_EXT_SUBNET NS_OVNGW
confirm "This removes the OVN Gateway test objects (VPC $OVNGW_VPC, EIPs, provider network). Continue?"

sec "Removing"
rk "$SERVER" "kubectl delete pods --all -n $NS_OVNGW --ignore-not-found --wait=true --timeout=90s
kubectl delete ovn-snat-rule snat-ovngw --ignore-not-found --wait=true --timeout=60s
kubectl delete ovn-eip eip-ovngw --ignore-not-found --wait=true --timeout=60s
for e in \$(kubectl get ovn-eip -o name 2>/dev/null); do kubectl delete \$e --ignore-not-found --wait=true --timeout=60s; done
kubectl delete subnet $OVNGW_SUBNET --ignore-not-found --wait=true --timeout=90s
kubectl delete vpc $OVNGW_VPC --ignore-not-found --wait=true --timeout=90s
kubectl delete namespace $NS_OVNGW --ignore-not-found --wait=false
kubectl delete subnet $OVNGW_EXT_SUBNET --ignore-not-found --wait=true --timeout=60s
kubectl delete vlan vlan-ext --ignore-not-found
kubectl delete provider-network $OVNGW_PROVIDER --ignore-not-found --wait=true --timeout=120s
kubectl label nodes --all ovn.kubernetes.io/external-gw-" 2>&1 | sed 's/^/  /'

sleep 5
for g in $GATEWAY_NODES; do nssh "$g" "sudo -n ip netns del ovnext 2>/dev/null; true"; done

sec "Checks"
for k in "vpc $OVNGW_VPC" "subnet $OVNGW_SUBNET" "subnet $OVNGW_EXT_SUBNET" "provider-network $OVNGW_PROVIDER" "ovn-eip"; do
  expect "$k removed" 0 "$(rk "$SERVER" "kubectl get $k -o name 2>/dev/null | wc -l" | tr -d ' ')"
done
for g in $GATEWAY_NODES; do
  expect "machine $g: $EXT_NIC back on the host (not in OVS)" yes "$(nssh "$g" "ip link show $EXT_NIC 2>/dev/null | grep -q 'master ovs-system' && echo no || echo yes")"
done
for g in $GATEWAY_NODES; do
  expect "machine $g: namespace ovnext removed" 0 "$(nssh "$g" "sudo -n ip netns list | grep -c '^ovnext'" | tr -d ' ')"
done
table
