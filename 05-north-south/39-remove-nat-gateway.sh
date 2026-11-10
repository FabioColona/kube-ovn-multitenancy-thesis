#!/bin/bash
# 39-remove-nat-gateway.sh — removes what 30-nat-gateway.sh created (the cluster and the customer network stay).
#
# What it does : deletes the client pod and namespace, the SNAT rule, the EIP, the gateway, the subnets, the VPC and the
#                external network of the gateway. The ConfigMaps ovn-vpc-nat-* in kube-system are not touched.
# Environment  : the cluster of 20-install-cluster.sh
# Changes      : DESTRUCTIVE (only the objects of the NAT Gateway test)
# Requires     : phase 20 done
# Usage        : ./39-remove-nat-gateway.sh [--yes]
# Variables    : NS_NAT, NAT_VPC, NAT_SUBNET, NAT_GW, NAT_EXT_SUBNET (from config.env)
# Duration     : about 1 minute
# Exit code    : 0 = removed; 1 = something left; 2 = prerequisite missing
# In the thesis: not cited (support script)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
confirm "This removes the NAT Gateway test objects (VPC $NAT_VPC, gateway $NAT_GW, EIP, SNAT). Continue?"

sec "Removing"
rk "$SERVER" "kubectl delete pod nprobe -n $NS_NAT --ignore-not-found --wait=true --timeout=60s
kubectl delete iptables-snat-rule snat-nat --ignore-not-found --wait=true --timeout=60s
kubectl delete iptables-eip eip-nat --ignore-not-found --wait=true --timeout=120s
kubectl delete vpc-nat-gw $NAT_GW --ignore-not-found --wait=true --timeout=180s
kubectl -n kube-system delete statefulset vpc-nat-gw-$NAT_GW --ignore-not-found --wait=true --timeout=120s
kubectl -n kube-system delete pod vpc-nat-gw-$NAT_GW-0 --ignore-not-found --wait=true --timeout=120s
kubectl delete subnet $NAT_SUBNET $NAT_EXT_SUBNET --ignore-not-found --wait=true --timeout=90s
kubectl delete vpc $NAT_VPC --ignore-not-found --wait=true --timeout=90s
kubectl delete namespace $NS_NAT --ignore-not-found --wait=false
kubectl -n kube-system delete net-attach-def $NAT_EXT_SUBNET --ignore-not-found" 2>&1 | sed 's/^/  /'

sec "Checks"
for k in "vpc $NAT_VPC" "subnet $NAT_SUBNET" "subnet $NAT_EXT_SUBNET" "vpc-nat-gw $NAT_GW" "iptables-eip eip-nat"; do
  expect "$k removed" 0 "$(rk "$SERVER" "kubectl get $k -o name 2>/dev/null | wc -l" | tr -d ' ')"
done
expect "gateway pod vpc-nat-gw-$NAT_GW-0 removed" 0 "$(rk "$SERVER" "kubectl -n kube-system get pod vpc-nat-gw-$NAT_GW-0 -o name 2>/dev/null | wc -l" | tr -d ' ')"
# the gateway pod holds a macvlan on EXT_NIC: while it exists, EXT_NIC cannot be added to an OVS bridge (31-ovn-gateway.sh)
for g in ${GATEWAY_NODES:-}; do
  expect "machine $g: no macvlan left on ${EXT_NIC:-ext0}" 0 "$(nssh "$g" "ip -d link show type macvlan 2>/dev/null | grep -c 'link ${EXT_NIC:-ext0}'" | tr -d ' ')"
done
table
